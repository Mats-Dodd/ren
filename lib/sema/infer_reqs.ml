(* Requirements: what a generic function needs of its type parameters
   (compiler.md, "The facts"). `eq`, which `==` and `!=` need; `ord`,
   which `<`, `<=`, `>` and `>=` need; `hash`, which agrees with `eq`;
   `add`, `sub`, `mul`, `div`, `rem` and `neg`, which the operators `+`,
   `-`, `*`, `/`, `%` and `-a` need; and `zero` and `one`, the associated
   values `T.zero` and `T.one` (operators.md, "Generic code").

   A type has `eq` and `hash` by its structure (operators.md, "Equality,
   hashing and `show`"): `Int`, `Float`, `Bool`, `Str`, `Bytes` and `Unit`
   have them, and so do arrays, records, sum types, `Option`s, `Result`s
   and their error sets, and opaque types, when everything in them has
   them. A function doesn't, and neither does a type with a function in
   it. An implementation of a dependency, or a handler of several, is its
   operations, which are functions, so neither has them either. A type
   with a `key` has them if its key's type does: the key is the one way
   to change what equal means, and ordering and hashing go through it
   too.

   A type has `ord` only where its order is obvious: `Int`, `Float`, `Str`
   and `Bool`, a sum type with no fields, by the order of its variants, a
   `with numeric` type, and anything with a `key`, by its key. In its own
   module an opaque type is what it's represented as, so it's ordered as
   that is. A record, or a sum type with fields, is ordered only by its
   key, so that reordering its fields can't change a sort.

   An operator or an associated value is a member with a reserved name
   (operators.md, "Operators are methods"): a type has `add` if it has an
   `add` that takes one of its own and gives one, `fn add(self, b: Vec)
   -> Vec`, and `zero` if it has `let zero: Vec`. That member may need
   something of the type's parameters, which then the type's arguments
   need. `Int` and `Float` have them all, and a `with numeric` type has
   `add`, `sub`, `neg` and `zero` without writing them.

   A type variable has a requirement if whatever it stands for does: one
   of the group being checked passes it on to the function it's in,
   which then needs it of whatever it's given, at every use. A row
   variable at the end of an error set is the same, for every tag it
   stands for.

   Each `==`, `<`, operator on a type variable and `T.zero` is a
   constraint (Infer_env.compared), and so is each use of a function
   that needs something (Infer_env.required), decided once the group's
   types are known, by the solver: then what a variable stands for is
   known as far as it will be. A use of a function of the group needs
   what its body finds of its type parameters, which is known only once
   every body of the group is, and can add to what another function of
   the group needs: they're decided in rounds, until one finds nothing
   new. *)

open Types
open Infer_env
open Infer_report

(* The operators that are methods, by their requirement's name. *)
let operators = Iface.operators

(* Whether a type has a requirement: if it does, the variables in it,
   by id, each with what it has to have too; if not, why not. *)
type has = Has of (int * string) list | Lacks of lack

and lack =
  | Fn of ty  (** a function type in it, which has no `eq` *)
  | Decl of Infer_msg.no_eq
      (** a type in it whose declaration has a function in it, whatever its type
          arguments *)
  | Unordered of Infer_msg.no_ord  (** it has no order *)
  | No_op  (** it has no such operator, or associated value *)

(* ---- what a type's members give it ---- *)

(* Whether the key of the type at [p] leads back to [p]: its type has [p]
   in it, or a type whose key does, and so on. Comparing a [p] would then
   compare a [p] to find out, which never ends, so it's an error (Infer_top
   reports it), and [p] is then taken to have whatever's asked of it, with
   no more said, so nothing here goes round forever, nor does Core Lint or
   the interpreter, which only see a program without errors. [seen] are
   the types looked into. *)
let key_loops env p =
  let rec reaches seen (t : Ty.ty) =
    match t with
    | Con (q, args) ->
        q = p
        || (not (List.mem q !seen))
           &&
           (seen := q :: !seen;
            (* through its key, or, if it hasn't one, one of the
                  module's own opaque types through what it's represented
                  as, which is what it's compared and ordered by *)
            (match Hashtbl.find_opt env.types q with
              | Some td -> (
                  match (Iface.key td, td.body) with
                  | Some (_, k), _ -> reaches seen k
                  | None, Opaque (Rep rep) -> reaches seen rep
                  | None, _ -> false)
              | None -> false)
            || List.exists (reaches seen) args)
    | Fun (ps, r, _, _, _) ->
        List.exists (fun (x : Ty.param) -> reaches seen x.ty) ps
        || reaches seen r
    | Errors e ->
        List.exists
          (fun (l : Ty.label) -> List.exists (reaches seen) l.payload)
          e.labels
    | Var _ | Error | Uses _ | All _ -> false
  in
  match Option.bind (Hashtbl.find_opt env.types p) Iface.key with
  | Some (_, k) -> reaches (ref []) k
  | None -> false

(* The `key` of the type at [p], if it has one: its path, and its type as
   its declaration writes it, the type's parameters [Var]s. *)
let key_of env p = Option.bind (Hashtbl.find_opt env.types p) Iface.key

(* [t], a type as a declaration writes it, with [args] in place of its
   type's parameters. *)
let with_args args (t : Ty.ty) =
  of_ty
    ~vars:(fun n -> Option.value (List.nth_opt args n) ~default:TError)
    ~tails:(fun _ -> REmpty)
    ~lams:(fun _ -> REmpty)
    t

(* What the member at [path] needs of its type's parameters, by their
   place, `[(0, "add")]`. Another module's says so in its interface. One
   of this module's says so once its group is done: one that isn't is
   checked first, by giving the group being checked a call of it, the
   way a dot call of a method not checked yet is (infer_top.ml,
   [program]). One of the group itself needs what it's found to so far. *)
let member_reqs env path (o : Iface.op) =
  let of_args (t : ty) =
    match repr t with
    | TFun (self :: _, _, _, _, _) -> (
        match repr self.ty with
        | TCon (_, args) ->
            List.concat
              (List.mapi
                 (fun i a ->
                   match repr a with
                   | TVar { contents = Unbound (id, _) } | TSkol (id, _) ->
                       List.map (fun r -> (i, r)) (needs env.st id)
                   | _ -> [])
                 args)
        | _ -> [])
    | _ -> []
  in
  if o.okind = Value then []
  else if path.Path.home <> env.home then o.oscheme.reqs
  else
    match (Hashtbl.find_opt env.globals path, env.group) with
    | Some t, _ -> of_args t
    | None, _ when List.mem_assoc path env.group -> []
    | None, (caller, _) :: _ -> raise (Unchecked { caller; callee = path })
    | None, [] -> []

(* The member of the type at [p] that gives it the requirement [req], an
   operator or an associated value, if one does (Iface.provider). *)
let provider env p req =
  Option.bind (Hashtbl.find_opt env.types p) (fun td -> Iface.provider td req)

(* The type at [p] is `with numeric`: what it's represented as. *)
let numeric env p =
  Option.bind (Hashtbl.find_opt env.types p) (fun (td : Iface.type_decl) ->
      td.numeric)

(* What a `with numeric` type has without writing it (operators.md,
   "Number types"). *)
let numeric_gives = [ "add"; "sub"; "neg"; "zero"; "eq"; "hash"; "ord" ]
let int_path = Path.prelude "Int"
let float_path = Path.prelude "Float"
let is_number p = p = int_path || p = float_path

(* ---- `eq` ---- *)

(* Whether the declaration of the type at [p] has a function in it, its
   type arguments aside, which [has] looks into on its own: the field
   that has, if one does. [seen] are the declarations being looked into
   already, so a recursive type is looked into once. An opaque type of
   another module hides what it's represented as, but its interface says
   whether that has a function in it ([Iface.Hidden]). A type with a key
   is compared by it, so it's its key's type that's looked into. *)
let rec decl_lacks env seen p : Infer_msg.no_eq option =
  match (Hashtbl.find_opt env.types p, key_of env p) with
  | _ when List.mem p seen -> None
  | Some _, Some _ when key_loops env p -> None
  | None, _ -> None
  | Some _, Some (_, k) -> lacks_in env (p :: seen) k
  | Some td, None -> (
      let seen = p :: seen in
      (* a record's field, or a constructor's, by its name *)
      let field owner (f : Iface.field) =
        Option.map
          (fun _ -> Infer_msg.Field_function (env.names p, owner, f.fname))
          (lacks_in env seen f.fty)
      in
      match td.body with
      | Builtin | Errors _ | Opaque (Hidden { eq = true }) -> None
      | Opaque (Hidden { eq = false }) -> Some (Opaque_hidden (env.names p))
      | Record fs -> List.find_map (field (env.names p)) fs
      | Sum cs ->
          List.find_map
            (fun (c : Iface.ctor) -> List.find_map (field c.cname) c.cfields)
            cs
      | Opaque (Rep rep) -> (
          match lacks_in env seen rep with
          | Some Is_function ->
              (* represented as a function: say which *)
              let pr =
                Ty.printer ~names:env.names
                  { ty = rep; names = []; reqs = []; row_reqs = [] }
              in
              Some (Has_function (Ty.show pr rep))
          | w -> w)
      | Dep _ -> Some (Implementation (env.names p)))

(* The same for a type as a declaration writes it, its parameters [Var]s,
   which [has] looks into where they're used. *)
and lacks_in env seen (t : Ty.ty) : Infer_msg.no_eq option =
  match t with
  | Fun _ -> Some Is_function
  | Var _ | Error | Uses _ -> None
  | All (ds, _) ->
      Some (Implementation (String.concat " & " (List.map env.names ds)))
  | Errors e ->
      List.find_map
        (fun (l : Ty.label) -> List.find_map (lacks_in env seen) l.payload)
        e.labels
  | Con (q, args) -> (
      match decl_lacks env seen q with
      | Some w -> Some w
      | None -> List.find_map (lacks_in env seen) args)

(* Whether the module's own opaque type at [p] has `eq`, for its
   interface, which hides what it's represented as. *)
let opaque_has_eq env p = decl_lacks env [] p = None

(* ---- any requirement ---- *)

(* Both [a] and [b]: every variable either says has to have what it
   says, or the first's lack. *)
let both a b =
  match (a, b) with
  | Lacks l, _ | Has _, Lacks l -> Lacks l
  | Has a, Has b -> Has (a @ b)

(* Whether [t] has [req]. An error set's tail, what a function it was
   passed fails with, has it if every tag it stands for does, so it's
   among the variables that have to have it, by its id, which is never a
   type variable's: a function that compares two `attempt g()`s needs it
   of `g`'s errors, at every use (Ty.scheme's [row_reqs]). *)
let rec has env req t =
  match repr t with
  | TVar { contents = Unbound (id, _) } | TSkol (id, _) -> Has [ (id, req) ]
  | TVar { contents = Link _ } -> assert false (* [repr] followed it *)
  | TError | TUses _ -> Has []
  | t -> (
      match req with
      | "eq" | "hash" -> has_eq env req t
      | "ord" -> has_ord env t
      | _ -> has_op env req t)

(* [ts] each have [req]. *)
and all env req ts =
  List.fold_left (fun acc t -> both acc (has env req t)) (Has []) ts

(* [req] of the type at [p], given [args], through its key: what its key's
   type has, and what the key needs of the type's arguments. [None] if it
   has no key. *)
and keyed env req p args =
  match key_of env p with
  | None -> None
  | Some _ when key_loops env p -> Some (Has [])
  | Some (path, k) ->
      let needs =
        match
          Option.bind (Hashtbl.find_opt env.types p) (fun td ->
              Iface.find_member td "key")
        with
        | Some o ->
            List.fold_left
              (fun acc (n, r) ->
                both acc
                  (has env r
                     (Option.value (List.nth_opt args n) ~default:TError)))
              (Has []) (member_reqs env path o)
        | None -> Has []
      in
      let of_key =
        match has env req (with_args args k) with
        | Lacks (Unordered _) ->
            (* say it's the key that has no order, not the type *)
            let pr =
              Ty.printer ~names:env.names
                { ty = k; names = []; reqs = []; row_reqs = [] }
            in
            Lacks (Unordered (Unordered_key (env.names p, Ty.show pr k)))
        | h -> h
      in
      Some (both needs of_key)

and has_eq env req t =
  match t with
  | TAll (ds, _) ->
      Lacks
        (Decl (Implementation (String.concat " & " (List.map env.names ds))))
  | TFun _ as f -> Lacks (Fn f)
  | TErrors e -> (
      let labels, tail = row_parts e in
      match
        all env req (List.concat_map (fun (l : label) -> l.payload) labels)
      with
      | Has ids ->
          Has (ids @ List.map (fun id -> (id, req)) (Option.to_list tail))
      | lacks -> lacks)
  | TCon (p, args) -> (
      match keyed env req p args with
      | Some h -> h
      | None -> (
          match decl_lacks env [] p with
          | Some w -> Lacks (Decl w)
          | None -> all env req args))
  | _ -> Has []

and has_ord env t =
  let unordered why = Lacks (Unordered why) in
  match t with
  | TCon (p, args) -> (
      match keyed env "ord" p args with
      | Some h -> h
      | None -> (
          let ordered =
            [ int_path; float_path; Path.prelude "Str"; Path.prelude "Bool" ]
          in
          match Hashtbl.find_opt env.types p with
          | _ when List.mem p ordered || numeric env p <> None -> Has []
          | Some { body = Sum cs; _ }
            when List.for_all (fun (c : Iface.ctor) -> c.cfields = []) cs ->
              Has []
          | Some { body = Sum _; _ } when p.home = Path.prelude_home ->
              unordered (Unordered_prelude (env.names p))
          | Some { body = Sum _; _ } -> unordered (Unordered_sum (env.names p))
          | Some { body = Record _; _ } ->
              unordered (Unordered_record (env.names p))
          | Some { body = Opaque (Rep rep); _ } ->
              (* in its own module, it's what it's represented as *)
              has env "ord" (with_args args rep)
          | Some { body = Opaque (Hidden _); _ } ->
              unordered (Unordered_opaque (env.names p))
          | _ -> unordered Unordered))
  | _ -> unordered Unordered

and has_op env req t =
  match t with
  | TCon (p, _) when is_number p -> Has []
  | TCon (p, _) when numeric env p <> None && List.mem req numeric_gives ->
      Has []
  | TCon (p, args) -> (
      match (provider env p req, Hashtbl.find_opt env.types p) with
      | Some (path, o), _ ->
          List.fold_left
            (fun acc (n, r) ->
              both acc
                (has env r (Option.value (List.nth_opt args n) ~default:TError)))
            (Has []) (member_reqs env path o)
      | None, Some { body = Opaque (Rep rep); _ } ->
          (* in its own module, it's what it's represented as *)
          has env req (with_args args rep)
      | None, _ -> Lacks No_op)
  | _ -> Lacks No_op

(* ---- deciding ---- *)

(* Report that [t] hasn't [req], at [loc]: [op] uses it there, or the
   function [by] needs it to; [uses] says how [by] uses it. *)
let lacking env loc ~req ~op ~by ~uses t lack =
  let pr = printer env in
  (* an error set is only ever checked whole for a row variable, the
     errors something given to [by] fails with: its tags are shown *)
  let shown, failed =
    match repr t with
    | TErrors e -> (show_row pr ~prefix:"" ~sep:" | " ~kind:"e" e, true)
    | _ -> (show pr t, false)
  in
  match lack with
  | Fn _ | Decl _ ->
      let why : Infer_msg.no_eq =
        match lack with
        | Fn f when f == repr t -> Is_function
        | Fn f -> Has_function (show pr f)
        | Decl w -> w
        | Unordered _ | No_op -> assert false
      in
      report env (Infer_msg.no_eq loc ~shown ~op ~by ~failed why)
  | Unordered why -> report env (Infer_msg.no_ord loc ~shown ~op ~by ~uses why)
  | No_op ->
      (* it has [req], but not one that takes its own type: one for
         another type on its right, or a `with numeric` type's `*` *)
      let other =
        match repr t with
        | TCon (p, _) when List.mem req [ "add"; "sub"; "mul"; "div"; "rem" ]
          -> (
            match Hashtbl.find_opt env.types p with
            | Some td ->
                Iface.find_members td req <> []
                || (td.numeric <> None && req = "mul")
            | None -> false)
        | _ -> false
      in
      report env (Infer_msg.no_op ~other loc ~shown ~op ~by ~uses)

(* [t] has [req], at [loc]: each variable in it needs what it has to have,
   or it's reported. The first place a variable is found to need
   something is kept, for a message at a call that gives it a type
   without it (Infer_msg.uses_note). Whether it has it. *)
let require env loc ~req ~op ~by ?uses t =
  match has env req t with
  | Has ids ->
      List.iter (fun (id, r) -> ignore (add_need ~at:loc env.st id r)) ids;
      true
  | Lacks l ->
      lacking env loc ~req ~op ~by ~uses t l;
      false

(* Pass on what [r]'s function needs of each variable, that it hasn't
   yet, to what the use put in its place. Whether it passed on any. A row
   variable stands for an error set's tags, so it's what the use put in
   its place as a set that has to have it. What's put in a variable's
   place that lacks one requirement is reported once, for the first, as
   `sum([true, false])` is, not again for each of the others. *)
let pass env r =
  let rows = List.map (fun (id, row) -> (id, TErrors row)) r.urows in
  List.fold_left
    (fun did (id, t) ->
      let lacked = ref false in
      List.fold_left
        (fun did req ->
          if List.mem (id, req) r.udone then did
          else if !lacked then (
            r.udone <- (id, req) :: r.udone;
            did)
          else (
            r.udone <- (id, req) :: r.udone;
            let loc = Option.value (List.assoc_opt id r.uat) ~default:r.uloc in
            let op = Infer_msg.req_symbol req in
            let uses =
              Infer_msg.uses_note ~f:r.uname ~op
                ~tparam:(Hashtbl.find_opt env.st.hints id)
                ~at:(need_at env.st id req)
            in
            if not (require env loc ~req ~op ~by:(Some r.uname) ~uses t) then
              lacked := true;
            true))
        did (needs env.st id))
    false (r.uinst @ rows)

(* Decide the group's constraints on what's compared, used with an
   operator or reached through a type parameter, and its uses of
   functions with requirements ([cs]), once its types are known. The
   first first, which is what finds a requirement in the first place;
   then each use, in rounds, since what one passes on to a type parameter
   of the group can make another use of that function need more. A round
   passes on only what wasn't, so once one passes on nothing, nothing
   more will be. *)
let decide env cs =
  List.iter
    (function
      | Compared q ->
          ignore (require env q.qloc ~req:q.qreq ~op:q.qop ~by:None q.qty)
      | _ -> ())
    cs;
  let rs = List.filter_map (function Required r -> Some r | _ -> None) cs in
  let rec round () =
    if List.fold_left (fun did r -> pass env r || did) false rs then round ()
  in
  round ()
