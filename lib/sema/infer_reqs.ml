(* Requirements: what a generic function needs of its type parameters
   (compiler.md, "The facts"). `eq`, which `==` and `!=` need, is the only
   one so far.

   A type has `eq` by its structure (operators.md, "Equality, hashing and
   `show`"): `Int`, `Bool`, `Str`, `Bytes` and `Unit` have it, and so do
   arrays, records, sum types, `Option`s, `Result`s and their error sets,
   and opaque types, when everything in them has it. A function doesn't,
   and neither does a type with a function in it. An implementation of a
   dependency, or a handler of several, is its operations, which are
   functions, so neither has it either. A type variable has it if
   whatever it stands for does: one of the group being checked passes the
   requirement on to the function it's in, which then needs it of
   whatever it's given, at every use. A row variable at the end of an
   error set is the same, for every tag it stands for.

   Each `==` and each use of a function that needs something is a
   constraint (Infer_env.compared and Infer_env.required), decided once
   the group's types are known, by the solver: then what a variable
   stands for is known as far as it will be. A use of a function of the
   group needs what its body finds of its type parameters, which is known
   only once every body of the group is, and can add to what another
   function of the group needs: they're decided in rounds, until one
   finds nothing new. *)

open Types
open Infer_env
open Infer_report

(* Whether a type has `eq`: if it does, the variables in it, by id, which
   have to have it too; if not, what in it is a function. *)
type eq = Has of int list | Lacks of lack

and lack =
  | Fn of ty  (** a function type in it *)
  | Decl of Infer_msg.no_eq
      (** a type in it whose declaration has a function in it, whatever its type
          arguments *)

(* Whether the declaration of the type at [p] has a function in it, its
   type arguments aside, which [has] looks into on its own: the field
   that has, if one does. [seen] are the declarations being looked into
   already, so a recursive type is looked into once. An opaque type of
   another module hides what it's represented as, so it's taken to have
   `eq` (compiler.md, "Deviations"). *)
let rec decl_lacks env seen p : Infer_msg.no_eq option =
  match Hashtbl.find_opt env.types p with
  | _ when List.mem p seen -> None
  | None -> None
  | Some td -> (
      let seen = p :: seen in
      (* a record's field, or a constructor's, by its name *)
      let field owner (f : Iface.field) =
        Option.map
          (fun _ -> Infer_msg.Field_function (owner, f.fname))
          (lacks_in env seen f.fty)
      in
      match td.body with
      | Builtin | Errors _ | Opaque None -> None
      | Record fs -> List.find_map (field (env.names p)) fs
      | Sum cs ->
          List.find_map
            (fun (c : Iface.ctor) -> List.find_map (field c.cname) c.cfields)
            cs
      | Opaque (Some rep) -> (
          match lacks_in env seen rep with
          | Some Is_function ->
              (* represented as a function: say which *)
              let pr =
                Ty.printer ~names:env.names
                  { ty = rep; names = []; reqs = []; row_reqs = [] }
              in
              Some (Has_function (Ty.show pr rep))
          | w -> w)
      | Dep _ -> Some (Implementation (env.names p))
      | Handler _ -> Some (Handler (env.names p)))

(* The same for a type as a declaration writes it, its parameters [Var]s,
   which [has] looks into where they're used. *)
and lacks_in env seen (t : Ty.ty) : Infer_msg.no_eq option =
  match t with
  | Fun _ -> Some Is_function
  | Var _ | Error | Uses _ -> None
  | Errors e ->
      List.find_map
        (fun (l : Ty.label) -> List.find_map (lacks_in env seen) l.payload)
        e.labels
  | Con (q, args) -> (
      match decl_lacks env seen q with
      | Some w -> Some w
      | None -> List.find_map (lacks_in env seen) args)

(* Whether [t] has `eq`. An error set's tail, what a function it was
   passed fails with, has it if every tag it stands for does, so it's
   among the variables that have to have it, by its id, which is never a
   type variable's: a function that compares two `attempt g()`s needs it
   of `g`'s errors, at every use (Ty.scheme's [row_reqs]). *)
let rec has env t =
  let all ts =
    List.fold_left
      (fun acc t ->
        match (acc, has env t) with
        | Lacks l, _ | Has _, Lacks l -> Lacks l
        | Has a, Has b -> Has (a @ b))
      (Has []) ts
  in
  match repr t with
  | TVar { contents = Unbound (id, _) } | TSkol (id, _) -> Has [ id ]
  | TVar { contents = Link _ } -> assert false (* [repr] followed it *)
  | TError | TUses _ -> Has []
  | TFun _ as f -> Lacks (Fn f)
  | TErrors e -> (
      let labels, tail = row_parts e in
      match all (List.concat_map (fun (l : label) -> l.payload) labels) with
      | Has ids -> Has (ids @ Option.to_list tail)
      | lacks -> lacks)
  | TCon (p, args) -> (
      match decl_lacks env [] p with
      | Some w -> Lacks (Decl w)
      | None -> all args)

(* Report that [t] has no `==`, at [loc]: [op] compares it there, or the
   function [by] needs it to. *)
let lacking env loc ~op ~by t lack =
  let pr = printer env in
  (* an error set is only ever checked whole for a row variable, the
     errors something given to [by] fails with: its tags are shown *)
  let shown, failed =
    match repr t with
    | TErrors e -> (show_row pr ~prefix:"" ~sep:" | " ~kind:"e" e, true)
    | _ -> (show pr t, false)
  in
  let why : Infer_msg.no_eq =
    match lack with
    | Fn f when f == repr t -> Is_function
    | Fn f -> Has_function (show pr f)
    | Decl w -> w
  in
  report env (Infer_msg.no_eq loc ~shown ~op ~by ~failed why)

(* [t] has `eq`, at [loc]: each variable in it needs it, or it's
   reported. *)
let require env loc ~op ~by t =
  match has env t with
  | Has ids -> List.iter (fun id -> ignore (add_need env.st id "eq")) ids
  | Lacks l -> lacking env loc ~op ~by t l

(* Pass on what [r]'s function needs of each variable, that it hasn't
   yet, to what the use put in its place. Whether it passed on any. A row
   variable stands for an error set's tags, so it's what the use put in
   its place as a set that has to have it. *)
let pass env r =
  let rows = List.map (fun (id, row) -> (id, TErrors row)) r.urows in
  List.fold_left
    (fun did (id, t) ->
      List.fold_left
        (fun did req ->
          if List.mem (id, req) r.udone then did
          else (
            r.udone <- (id, req) :: r.udone;
            (* `eq` is the only requirement so far *)
            let loc = Option.value (List.assoc_opt id r.uat) ~default:r.uloc in
            require env loc ~op:"==" ~by:(Some r.uname) t;
            true))
        did (needs env.st id))
    false (r.uinst @ rows)

(* Decide the group's `==`s and uses of functions with requirements
   ([cs]), once its types are known. Each `==` first, which is what finds
   a requirement in the first place; then each use, in rounds, since what
   one passes on to a type parameter of the group can make another use
   of that function need more. A round passes on only what wasn't, so
   once one passes on nothing, nothing more will be. *)
let decide env cs =
  List.iter
    (function
      | Compared q -> require env q.qloc ~op:q.qop ~by:None q.qty | _ -> ())
    cs;
  let rs = List.filter_map (function Required r -> Some r | _ -> None) cs in
  let rec round () =
    if List.fold_left (fun did r -> pass env r || did) false rs then round ()
  in
  round ()
