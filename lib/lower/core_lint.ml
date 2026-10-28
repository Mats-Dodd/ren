(* Core Lint: type-check Core (core.ml) again, from scratch.

   Lowering rewrites a lot (places, loops, temporaries), and a mistake in
   it would show up as the interpreter computing something wrong, far from
   the cause. Lint catches it at the node where it happened instead. It
   checks that every node's type is the one its parts say it has (a use
   of a top-level function's, its scheme's at the type arguments it
   carries), that every local is used inside its scope with the type it
   was bound with, that a block captures every local it uses, and that every constructor,
   record and field is in the type it says, and that an error has the
   payload its set says, and that a handler's instance is only ever the
   end of its body. And that the evidence is threaded (core.ml):
   that every call passes the evidence in scope, a block's own inside it,
   which is the evidence where it's written, which it captures as a local,
   with what its type lists given by its caller; a call through `next`
   uses its handler's evidence, which a block in the handler captures too;
   and that each dependency an operation or a callee uses is one the
   function it's in uses too, or a [With] around it installs, or, inside a
   block, its caller gives it: a block is checked where it's written
   (foundations.md, decision 5). And that each descriptor of
   a type (core.ml, [desc]) describes the type argument it's passed for,
   built only from the hidden type parameters of the function it's in;
   that each function takes a dictionary for each of its requirements
   (core.ml, [dict]), and each use of one passes one for each, for the
   type argument it's on, as does each [==], built only from the
   function's own dictionaries and derived only for a type that has what
   it's derived for; and that each type said to show itself has a `show`
   method the interpreter can call. And that blocks are second-class
   (foundations.md): a value of a function type is only a call's callee,
   a call's argument, or a `let`'s value, but for the operations of a
   handler's instance, and no type argument, nor any type's argument, is
   a function type, since a type variable never stands for a block. And
   that a [Break] is inside a [While], never leaving a block, a handler or
   a [With]'s body for one. Which errors code can fail with isn't checked: inference has, and Core has
   no use for them.

   Lint finding anything is a bug in the compiler, never in the program,
   so it fails with an exception, which the driver reports as an internal
   compiler error. The tests run it on every program (driver.ml). *)

open Core
module Scope = Map.Make (Int)

let sprintf = Printf.sprintf

type env = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
  schemes : (Path.t, Ty.scheme) Hashtbl.t;
      (** every top-level function, and every function among a type's members *)
  values : (Path.t, Ty.scheme) Hashtbl.t;
      (** every associated value's type, as a scheme *)
  fn : string;  (** the function being checked *)
  ev : var option;  (** the evidence in scope, the innermost *)
  uses : Ty.row;  (** what the function or lambda being checked uses *)
  installed : Ty.label list;
      (** what the [With]s around here in it install, each a dependency at its
          type arguments *)
  handler : (var * Ty.row) option;
      (** in a handler, its evidence and what it needs: a call through `next`
          finds what it's over there, and a block in it captures that *)
  ntys : int;  (** how many hidden type parameters the function has *)
  body_ty : var option;
      (** in a handler's `finally`, its hidden parameter that holds the
          descriptor of the `with`'s body's type, [Var ntys - 1] there *)
  own : ((int * string) * var) list;
      (** the function's hidden dictionary parameters, by the requirement each
          is for *)
  in_loop : bool;
      (** whether a [Break] here leaves a [While]: one is around it, in the same
          function or block, and not around a [With] it's in *)
}

let show t =
  Ty.show
    (Ty.printer
       ~show_tail:(fun _ -> true)
       ~names:Path.full
       { ty = t; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] })
    t

(* A dependency's label, as its type is written, `Log<Int>`. *)
let show_dep (l : Ty.label) =
  Ty.show_dep
    (Ty.printer ~names:Path.full
       { ty = Error; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] })
    (Ty.of_label l)

let fail env (loc : Loc.t) msg =
  failwith
    (sprintf "Core Lint: in `%s`, at %s:%d:%d: %s" env.fn loc.file
       loc.start.line loc.start.col msg)

let rec has_error (t : Ty.ty) =
  match t with
  | Error -> true
  | Var _ -> false
  | Con (_, args) -> List.exists has_error args
  | Errors e -> row_has_error e
  | Impl i -> row_has_error i.fails
  | Fun (ps, r, e, _) ->
      List.exists (fun (p : Ty.param) -> has_error p.ty) ps
      || has_error r || row_has_error e

and row_has_error (r : Ty.row) =
  List.exists (fun (l : Ty.label) -> List.exists has_error l.payload) r.labels

(* A declaration's field type, given what its type parameters stand for. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> List.nth args i
  | Error -> Error
  | Con (p, a) -> Con (p, List.map (subst args) a)
  | Errors e -> Errors (subst_row args e)
  | Impl i ->
      Impl
        {
          i with
          deps =
            List.map
              (fun (d : Ty.dep) ->
                { d with dargs = List.map (subst args) d.dargs })
              i.deps;
          needs = subst_row args i.needs;
          fails = subst_row args i.fails;
        }
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst args p.ty }) ps,
          subst args r,
          subst_row args e,
          u )

and subst_row args (r : Ty.row) =
  {
    r with
    labels =
      List.map
        (fun (l : Ty.label) ->
          { l with payload = List.map (subst args) l.payload })
        r.labels;
  }

(* In its own module, an opaque type is its representation (iface.ml), so
   `UserId` and `Int` are the same type there. [reveal] replaces an opaque
   type of the module being linted with what it's represented as, until
   [t] is some other type; resolve.ml makes sure that ends. Another
   module's opaque type has no representation here, and stays as it is,
   and so does any other type: physically the same value, which [==]
   tests. *)
let rec reveal env (t : Ty.ty) : Ty.ty =
  match t with
  | Con (p, args) -> (
      match Hashtbl.find_opt env.types p with
      | Some { Iface.body = Opaque (Rep rep); _ } -> reveal env (subst args rep)
      | _ -> t)
  | Fun _ | Var _ | Errors _ | Impl _ | Error -> t

(* An implementation that needs [a] will do where one that needs [b] is
   wanted, if it needs no more (Infer_rows.widen); where it's used, what
   it needs is copied, with a tail of its own (Infer_rows.copy_needs). *)
let needs_within (a : Ty.row) (b : Ty.row) =
  List.for_all (fun l -> List.mem l b.labels) a.labels
  && (a.tail = None || b.tail <> None)

(* Are [a] and [b] the same type, once opaque types are revealed where they
   differ? An implementation [a] may need less than [b]. *)
let rec equal env (a : Ty.ty) (b : Ty.ty) =
  match (a, b) with
  | Con (p, xs), Con (q, ys)
    when p = q
         && List.length xs = List.length ys
         && List.for_all2 (equal env) xs ys ->
      true
  | Fun (ps, r, e, u), Fun (qs, r', e', u') when List.length ps = List.length qs
    ->
      List.for_all2
        (fun (p : Ty.param) (q : Ty.param) ->
          p.mode = q.mode && equal env p.ty q.ty)
        ps qs
      && equal env r r' && e = e' && u = u'
  | Impl i, Impl j
    when Ty.dep_paths i.deps = Ty.dep_paths j.deps
         && List.for_all2
              (fun (a : Ty.dep) (b : Ty.dep) ->
                List.length a.dargs = List.length b.dargs
                && List.for_all2 (equal env) a.dargs b.dargs)
              i.deps j.deps
         && i.over = j.over ->
      (* and fails to be installed with no more *)
      needs_within i.needs j.needs && needs_within i.fails j.fails
  | _ ->
      let a' = reveal env a and b' = reveal env b in
      if a' == a && b' == b then a = b else equal env a' b'

let same env loc what (found : Ty.ty) (expected : Ty.ty) =
  if not (equal env found expected) then
    fail env loc
      (sprintf "%s has type `%s`, but should have `%s`" what (show found)
         (show expected))

(* Is [t] what [s] (a scheme's type) becomes for some choice of its type
   and row variables? A row variable can stand for more labels, and a tail. *)
let instance_of env (s : Ty.ty) (t : Ty.ty) =
  let tys = Hashtbl.create 8 and rows = Hashtbl.create 8 in
  let bound table same n x =
    match Hashtbl.find_opt table n with
    | Some y -> same x y
    | None ->
        Hashtbl.add table n x;
        true
  in
  let rec go (s : Ty.ty) (t : Ty.ty) =
    match (s, t) with
    | Var n, _ -> bound tys (equal env) n t
    | Con (p, a), Con (q, b)
      when p = q && List.length a = List.length b && List.for_all2 go a b ->
        true
    | Fun (ps, r, e, u), Fun (qs, r', e', u')
      when List.length ps = List.length qs ->
        List.for_all2
          (fun (p : Ty.param) (q : Ty.param) -> p.mode = q.mode && go p.ty q.ty)
          ps qs
        && go r r' && row e e' && row u u'
    | Errors e, Errors e' -> row e e'
    | Impl i, Impl j
      when Ty.dep_paths i.deps = Ty.dep_paths j.deps && i.over = j.over ->
        List.for_all2
          (fun (a : Ty.dep) (b : Ty.dep) ->
            List.length a.dargs = List.length b.dargs
            && List.for_all2 go a.dargs b.dargs)
          i.deps j.deps
        && row i.needs j.needs && row i.fails j.fails
    | _ ->
        let s' = reveal env s and t' = reveal env t in
        if s' == s && t' == t then false else go s' t'
  and row (s : Ty.row) (t : Ty.row) =
    let extra = List.filter (fun l -> not (List.mem l s.labels)) t.labels in
    List.for_all (fun l -> List.mem l t.labels) s.labels
    &&
    match s.tail with
    | None -> extra = [] && t.tail = None
    | Some n ->
        (* a canonical row has each label once, so the row variable may
           stand for a label [s] has too: it stands for at least [extra],
           and at most [t]'s labels, wherever it is *)
        let fits (extra', labels', tail') =
          tail' = t.tail
          && List.for_all (fun l -> List.mem l t.labels) extra'
          && List.for_all (fun l -> List.mem l labels') extra
        in
        let seen = Option.value (Hashtbl.find_opt rows n) ~default:[] in
        List.for_all fits seen
        &&
        (Hashtbl.replace rows n ((extra, t.labels, t.tail) :: seen);
         true)
  in
  go s t

(* A use of [name], whose scheme's type is [s], at the type arguments [a]:
   there's one for each of [s]'s variables, none of them an error, and the
   use's type [t] is [s] with them put in. Inference picked them where it
   found [t] (Infer.node), so this checks the two agree. *)
let used env loc name (s : Ty.ty) (a : Ty.args) (t : Ty.ty) =
  let own = Ty.own_args s in
  let ntys = List.length a.tys and nrows = List.length a.rows in
  if ntys <> List.length own.tys || nrows <> List.length own.rows then
    fail env loc
      (sprintf
         "`%s` is given %d type and %d row arguments, but `%s` has %d type and \
          %d row variables"
         name ntys nrows (show s) (List.length own.tys) (List.length own.rows));
  if List.exists has_error a.tys || List.exists row_has_error a.rows then
    fail env loc (sprintf "`%s` is given an error type as a type argument" name);
  let expected = Ty.apply a s in
  if not (equal env t expected) then
    fail env loc
      (sprintf "`%s` is used at `%s`, but its type arguments make it `%s`" name
         (show t) (show expected))

let decl env loc p =
  match Hashtbl.find_opt env.types p with
  | Some td -> td
  | None -> fail env loc (sprintf "there's no type `%s`" (Path.full p))

(* [t] as an instance of the type declared at [p]: its type arguments. *)
let args_of env loc what p (t : Ty.ty) =
  match reveal env t with
  | Con (q, args) when q = p ->
      let td = decl env loc p in
      let arity = List.length td.params in
      if List.length args <> arity then
        fail env loc (sprintf "%s has the wrong number of type arguments" what);
      (td, args)
  | _ ->
      fail env loc
        (sprintf "%s has type `%s`, but should be a `%s`" what (show t)
           (Path.full p))

let ctor_of env loc (td : Iface.type_decl) c =
  match td.body with
  | Sum cs -> (
      match List.find_opt (fun (k : Iface.ctor) -> k.cname = c) cs with
      | Some k -> k
      | None ->
          fail env loc (sprintf "`%s` has no constructor `%s`" td.path.name c))
  | Record _ | Builtin | Opaque _ | Errors _ | Dep _ | Dep_alias _ ->
      fail env loc (sprintf "`%s` isn't a sum type" td.path.name)

let fields_of env loc (td : Iface.type_decl) =
  match td.body with
  | Record fs | Dep fs -> fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Dep_alias _ ->
      fail env loc (sprintf "`%s` isn't a record" td.path.name)

(* The operations of the dependency [d], at its type arguments, an alias's
   those of the one it names (Iface.dep_fields). *)
let dep_fields env loc (d : Ty.dep) =
  match Iface.dep_fields (Hashtbl.find_opt env.types) d with
  | Some fs -> fs
  | None ->
      fail env loc
        (sprintf "`%s` isn't a dependency that takes %d type arguments"
           (Path.full d.dpath) (List.length d.dargs))

let field_ty env loc (td : Iface.type_decl) args f =
  match
    List.find_opt (fun (d : Iface.field) -> d.fname = f) (fields_of env loc td)
  with
  | Some d -> subst args d.fty
  | None -> fail env loc (sprintf "`%s` has no field `%s`" td.path.name f)

(* [v] is evidence, which only a function, a block, a handler or a [With]
   binds: a local a block can capture, but never a value. *)
let is_evidence env loc what (v : var) =
  if v.ty <> evidence_ty then
    fail env loc
      (sprintf "%s `%s` (%d) has type `%s`, but should be evidence" what v.name
         v.id (show v.ty))

(* [v], which [what] is given, is the evidence in scope here. *)
let current env loc what (v : var) =
  match env.ev with
  | Some w when w = v -> ()
  | Some w ->
      fail env loc
        (sprintf "%s is given `%s` (%d), but the evidence in scope is `%s` (%d)"
           what v.name v.id w.name w.id)
  | None ->
      fail env loc (sprintf "%s is given evidence outside a function" what)

(* The dependency [l], at its type arguments, which [what] uses, is in
   the evidence here: the function or lambda being checked uses it, or a
   [With] around here installs it. *)
let available env loc what (l : Ty.label) =
  if
    not
      (List.exists (Ty.same_label l) env.uses.labels
      || List.exists (Ty.same_label l) env.installed)
  then
    fail env loc
      (sprintf
         "%s uses `%s`, which is neither used here, by `%s`, nor installed" what
         (show_dep l)
         (show (Fun ([], Ty.unit, Ty.closed, env.uses))))

(* The scope inside a function or handler that takes the evidence [v] and
   uses [uses]: nothing installed yet. *)
let inside env loc what (v : var) (uses : Ty.row) =
  is_evidence env loc what v;
  { env with ev = Some v; uses; installed = [] }

let in_scope env sc loc (v : var) =
  match Scope.find_opt v.id sc with
  | Some w when w = v -> ()
  | Some (w : var) ->
      fail env loc
        (sprintf "`%s` (%d) is used as `%s`, but was bound as `%s`" v.name v.id
           (show v.ty) (show w.ty))
  | None ->
      fail env loc (sprintf "`%s` (%d) is used outside its scope" v.name v.id)

let add (v : var) sc = Scope.add v.id v sc

(* The type [d] describes (core.ml, [desc]), in the type variables of the
   function being checked: each hidden type parameter it's built from is
   in scope, and is the function's own for [Var n], and a [Known] type has
   no type variables in it. *)
let rec described env sc loc (d : desc) : Ty.ty =
  let row r : Ty.row =
    {
      labels =
        List.map
          (fun (name, ds) ->
            ({ name; payload = List.map (described env sc loc) ds } : Ty.label))
          r.dlabels;
      tail = r.dtail;
    }
  in
  match d with
  | Known t ->
      if has_param env.ntys t then
        fail env loc
          (sprintf
             "the descriptor of `%s`, which has the function's type variables, \
              is known"
             (show t));
      t
  | Param v when Some v = env.body_ty ->
      in_scope env sc loc v;
      Var (env.ntys - 1)
  | Param v ->
      in_scope env sc loc v;
      let n = -1 - v.id in
      if n < 0 || n >= env.ntys || v <> type_param n then
        fail env loc
          (sprintf
             "a descriptor is built from `%s` (%d), which isn't a hidden type \
              parameter of `%s`"
             v.name v.id env.fn);
      Var n
  | Applied (p, ds) -> Con (p, List.map (described env sc loc) ds)
  | Errs e -> Errors (row e)

(* [d] describes [t], which [what] has. *)
and describes env sc loc what d (t : Ty.ty) =
  let found = described env sc loc d in
  if found <> t then
    fail env loc
      (sprintf "%s is described as `%s`, but is `%s`" what (show found) (show t))

(* [ds] are the descriptors of the type arguments [a] of a use of [name]:
   one for each, which describes it. *)
and descs env sc loc name (a : Ty.args) ds =
  if List.length ds <> List.length a.tys then
    fail env loc
      (sprintf "`%s` is given %d type arguments, but %d descriptors" name
         (List.length a.tys) (List.length ds));
  List.iteri
    (fun i (d, t) ->
      describes env sc loc (sprintf "type argument %d of `%s`" (i + 1) name) d t)
    (List.combine ds a.tys)

(* Whether [t] has the requirement [req], as inference decides it
   (infer_reqs.ml). A type variable is taken to have it: one of the
   function's has a dictionary of its own. [seen] are the declarations
   being looked into for `eq`, so a recursive one is looked into once. *)
let rec has_req env req (t : Ty.ty) =
  match t with
  | Var _ | Error -> true
  | _ -> (
      match req with
      | "eq" | "hash" -> has_eq env [] t
      | "ord" -> has_ord env t
      | _ -> has_op env req t)

(* [p]'s `key`'s type, given [args], if [p] has a key: equal, hashed and
   ordered by that. *)
and key_ty env p args =
  Option.bind (Hashtbl.find_opt env.types p) (fun td ->
      Option.map (fun (_, k) -> subst args k) (Iface.key td))

(* `eq`, and `hash`, which agrees with it: by its key, if it has one, and
   otherwise by its structure. A function hasn't it, nor an
   implementation of a dependency or a handler of several, nor a type
   with one in it. *)
and has_eq env seen (t : Ty.ty) =
  let row (r : Ty.row) =
    List.for_all
      (fun (l : Ty.label) -> List.for_all (has_eq env seen) l.payload)
      r.labels
  in
  match t with
  | Fun _ -> false
  | Var _ | Error -> true
  | Impl _ -> false
  | Errors r -> row r
  | Con (p, args) -> (
      match key_ty env p args with
      | Some k -> has_eq env seen k
      | None ->
          List.for_all (has_eq env seen) args
          && (List.mem p seen
             ||
             let field (f : Iface.field) = has_eq env (p :: seen) f.fty in
             match Hashtbl.find_opt env.types p with
             | None -> true
             | Some td -> (
                 match td.body with
                 | Builtin | Errors _ -> true
                 | Opaque (Hidden { eq }) -> eq
                 | Record fs -> List.for_all field fs
                 | Sum cs ->
                     List.for_all
                       (fun (c : Iface.ctor) -> List.for_all field c.cfields)
                       cs
                 | Opaque (Rep rep) -> has_eq env (p :: seen) rep
                 | Dep _ | Dep_alias _ -> false)))

(* An order: a number's, a `Str`'s or a `Bool`'s, a sum type's with no
   fields, a tuple's whose parts have one, a `with numeric` type's, or by
   its key; and in its own module an opaque type's representation's. *)
and has_ord env (t : Ty.ty) =
  match t with
  | Var _ | Error -> true
  | Con (p, args) when Ty.is_tuple p -> List.for_all (has_ord env) args
  | Con (p, args) -> (
      match (key_ty env p args, Hashtbl.find_opt env.types p) with
      | Some k, _ -> has_req env "ord" k
      | None, _ when List.mem t [ Ty.int; Ty.float; Ty.str; Ty.bool ] -> true
      | None, _ when Sized.of_ty t <> None -> true
      | None, Some { numeric = Some _; _ } -> true
      | None, Some { body = Sum cs; _ } ->
          List.for_all (fun (c : Iface.ctor) -> c.cfields = []) cs
      | None, Some { body = Opaque (Rep rep); _ } ->
          has_req env "ord" (subst args rep)
      | _ -> false)
  | _ -> false

(* An operator or an associated value: a number's, a member that gives
   it (Iface.provider), what a `with numeric` type has without writing
   it, or in its own module an opaque type's representation's. *)
and has_op env req (t : Ty.ty) =
  match t with
  | Var _ | Error -> true
  | _ when t = Ty.int || t = Ty.float -> true
  | Con (p, args) -> (
      match Hashtbl.find_opt env.types p with
      | Some td when Iface.provider td req <> None -> true
      | Some { numeric = Some _; _ }
        when List.mem req [ "add"; "sub"; "neg"; "zero" ] ->
          true
      | Some { body = Opaque (Rep rep); _ } -> has_req env req (subst args rep)
      | _ -> false)
  | _ -> false

(* The requirement a dictionary (core.ml, [dict]) is for, and the type, in
   the type variables of the function being checked: one of its own
   dictionary parameters, in scope, or one derived for a type that isn't
   one of its type variables and has what it's derived for, built from the
   function's own dictionaries for each of its type variables in it. *)
let dict_of env sc loc (d : dict) =
  let own (v : var) =
    in_scope env sc loc v;
    match List.find_opt (fun (_, w) -> w = v) env.own with
    | Some (r, _) -> r
    | None ->
        fail env loc
          (sprintf
             "a dictionary is built from `%s` (%d), which isn't a hidden \
              dictionary parameter of `%s`"
             v.name v.id env.fn)
  in
  match d with
  | Dict_param v ->
      let n, req = own v in
      (req, Ty.Var n)
  | Derived { req; dty; ddesc; from } ->
      (match dty with
      | Var n when n < env.ntys ->
          fail env loc
            (sprintf "a dictionary for `%s` is derived, not the function's own"
               (show dty))
      | _ -> ());
      if not (List.mem req Iface.requirements) then
        fail env loc
          (sprintf "a dictionary for `%s`, which isn't a requirement" req);
      if not (has_req env req dty) then
        fail env loc (sprintf "`%s` has no `%s` to derive" (show dty) req);
      describes env sc loc
        (sprintf "the dictionary for `%s`" (show dty))
        ddesc dty;
      if
        not
          (List.for_all
             (fun ((n, _), _) -> List.mem n (params_in env.ntys dty))
             from)
      then
        fail env loc
          (sprintf
             "the dictionary for `%s` is built from a dictionary for a type \
              variable not in it"
             (show dty));
      List.iter
        (fun (n, v) ->
          if own v <> n then
            fail env loc
              (sprintf "the dictionary for `%s` is built from `%s`, for another"
                 (show dty) v.name))
        from;
      (req, dty)

(* [d] is [req]'s dictionary for [t], which [what] needs. *)
let gives env sc loc what d req (t : Ty.ty) =
  let r, found = dict_of env sc loc d in
  if r <> req || found <> t then
    fail env loc
      (sprintf "%s is given the `%s` dictionary of `%s`, but needs `%s` of `%s`"
         what r (show found) req (show t))

(* [ds] are the dictionaries a use of [name], of scheme [s], at the type
   arguments [a] is given: one for each of its requirements, for the type
   argument it's on. *)
let dicts env sc loc name (s : Ty.scheme) (a : Ty.args) ds =
  if List.length ds <> List.length s.reqs then
    fail env loc
      (sprintf "`%s` has %d requirements, but is given %d dictionaries" name
         (List.length s.reqs) (List.length ds));
  List.iter2
    (fun (n, req) d ->
      match List.nth_opt a.tys n with
      | Some t -> gives env sc loc (sprintf "`%s`" name) d req t
      | None ->
          fail env loc (sprintf "`%s` needs something of a type it hasn't" name))
    s.reqs ds

let rec expr env sc (e : expr) =
  let loc = e.loc in
  if has_error e.ty then fail env loc "a node has an error type";
  let is what t = same env loc what e.ty t in
  match e.kind with
  | Int _ -> is "an `Int`" Ty.int
  | Float _ -> is "a `Float`" Ty.float
  | Bool _ -> is "a `Bool`" Ty.bool
  | Str _ -> is "a `Str`" Ty.str
  | Unit -> is "`()`" Ty.unit
  | Local v ->
      in_scope env sc loc v;
      if v.ty = evidence_ty then
        fail env loc
          (sprintf "the evidence `%s` (%d) used as a value" v.name v.id);
      is ("`" ^ v.name ^ "`") v.ty
  | Global (p, a, ds, dicts_given) -> (
      descs env sc loc (Path.local p) a ds;
      match Hashtbl.find_opt env.schemes p with
      | Some s ->
          used env loc (Path.local p) s.ty a e.ty;
          dicts env sc loc (Path.local p) s a dicts_given
      | None -> fail env loc (sprintf "there's no function `%s`" (Path.local p))
      )
  | Global_value (p, a) -> (
      match Hashtbl.find_opt env.values p with
      | Some s -> used env loc (Path.local p) s.ty a e.ty
      | None -> fail env loc (sprintf "there's no value `%s`" (Path.local p)))
  | Intrinsic (x, a, ds, dicts_given) ->
      descs env sc loc (Intrinsic.name x) a ds;
      let s = Prelude.scheme x in
      used env loc (Intrinsic.name x) s.ty a e.ty;
      dicts env sc loc (Intrinsic.name x) s a dicts_given
  | Dep_call { dep = p; dargs; op; fty; ev; next; args } -> (
      (* the operation as declared, at the type arguments its descriptors
         describe, using its dependency at those, and whatever the caller
         does *)
      let d : Ty.dep =
        { dpath = p; dargs = List.map (described env sc loc) dargs }
      in
      let label = Ty.dep_of d in
      let declared =
        List.find_opt
          (fun (o : Iface.field) -> o.fname = op)
          (dep_fields env loc d)
      in
      let what = sprintf "`%s.%s`" p.name op in
      (if not next then (
         current env loc what ev;
         available env loc what label)
       else
         (* through `next`: the evidence of the handler it's in, kept by
            each lambda between, which the handler needs [p] in *)
         match env.handler with
         | Some (v, needs) when v = ev ->
             in_scope env sc loc ev;
             if not (List.exists (Ty.same_label label) needs.labels) then
               fail env loc
                 (sprintf "%s through `next`, but its handler doesn't need `%s`"
                    what (show_dep label))
         | _ ->
             fail env loc
               (sprintf "%s through `next` isn't given its handler's evidence"
                  what));
      match declared with
      | Some { fty = Fun (ps, r, errs, _); _ } -> (
          (* through `next`, its handler's evidence has [p], so the
             caller's needn't *)
          let uses : Ty.row =
            if next then { labels = []; tail = Some 0 }
            else { labels = [ label ]; tail = Some 0 }
          in
          if not (instance_of env (Fun (ps, r, errs, uses)) fty) then
            fail env loc
              (sprintf "`%s.%s` is used at `%s`, which isn't its type, `%s`"
                 p.name op (show fty)
                 (show (Fun (ps, r, errs, uses))));
          match fty with
          | Fun (ps, ret, _, _) when List.length ps = List.length args ->
              List.iter2
                (fun (p : Ty.param) (a : expr) ->
                  expr env sc a;
                  same env a.loc "an argument" a.ty p.ty)
                ps args;
              is "a call" ret
          | _ ->
              fail env loc
                (sprintf "`%s.%s` is given the wrong number of arguments" p.name
                   op))
      | _ -> fail env loc (sprintf "`%s` has no operation `%s`" p.name op))
  | With { ev; outer; dep = p; dargs; from; impl; desc; body } ->
      let d : Ty.dep =
        { dpath = p; dargs = List.map (described env sc loc) dargs }
      in
      if not (Iface.is_dep (Hashtbl.find_opt env.types) p) then
        fail env loc
          (sprintf "`%s` is installed, but isn't a dependency" (Path.full p));
      let what = sprintf "installing `%s`" p.name in
      current env loc what outer;
      is_evidence env loc what ev;
      expr env sc impl;
      (* it implements [from] at the types [d] says: [d] itself, or what
         [d], an alias, names; and what it needs, it needs here *)
      let implemented =
        if from = p then d
        else
          match Iface.alias_of (Hashtbl.find_opt env.types) p with
          | Some t when t.dpath = from && dargs = [] -> t
          | _ ->
              fail env loc
                (sprintf "`%s` is installed as `%s`, which isn't an alias of it"
                   (Path.full from) (Path.full p))
      in
      (* a description of an alias is one of the instance it names
         (Unify), so either can be installed as the other *)
      let named (d : Ty.dep) =
        match Iface.alias_of (Hashtbl.find_opt env.types) d.dpath with
        | Some t when d.dargs = [] -> t
        | _ -> d
      in
      (match impl.ty with
      | Impl { deps = [ q ]; needs; _ } when named q = named implemented ->
          List.iter (available env loc what) needs.labels
      | t ->
          fail env impl.loc
            (sprintf "what's installed has type `%s`, but should be a `%s`"
               (show t)
               (show_dep (Ty.dep_of implemented))));
      expr
        {
          env with
          ev = Some ev;
          installed = Ty.dep_of d :: env.installed;
          in_loop = false;
        }
        (add ev sc) body;
      (* a `finally` is given what its body is *)
      describes env sc loc "the body of a `With`" desc body.ty;
      is "a `With`" body.ty
  | Handler { ev; captures; body } -> (
      List.iter (in_scope env sc loc) captures;
      (* like a lambda's, its body sees only what it captures, and its own
         evidence: what's installed where it's installed *)
      let inner = List.fold_left (fun sc v -> add v sc) Scope.empty captures in
      match Ty.impl_parts e.ty with
      | Some (ds, needs) ->
          (* its dependency's type, or the type that lists them *)
          List.iter (fun (d : Ty.dep) -> ignore (dep_fields env loc d)) ds;
          (* its evidence is in scope, for its operations and `finally`,
             which call through `next`, to keep *)
          expr
            {
              (inside env loc "a handler's evidence" ev needs) with
              handler = Some (ev, needs);
              in_loop = false;
            }
            (add ev inner) body;
          same env body.loc "a handler's body" body.ty e.ty
      | None -> fail env loc (sprintf "a handler has type `%s`" (show e.ty)))
  | Instance { impls; finally; _ } -> (
      Option.iter (finally_ env sc) finally;
      match Ty.impl_parts e.ty with
      | Some (ds, needs)
        when List.sort compare (List.map fst impls) = Ty.dep_paths ds
             && List.length impls = List.length ds ->
          (* in the order they're written, an implementation of each of
             the dependencies its type lists, which it keeps sorted *)
          List.iter
            (fun (p, (i : expr)) ->
              let d = List.find (fun (d : Ty.dep) -> d.dpath = p) ds in
              (* a record of its operations, each a lambda *)
              (match i.kind with
              | Record (q, fs) when q = p ->
                  List.iter
                    (fun (_, (f : expr)) ->
                      match f.kind with
                      | Lambda _ -> ()
                      | _ -> fail env f.loc "an operation that isn't a lambda")
                    fs;
                  operations env sc i.loc d needs fs
              | _ -> fail env i.loc "an implementation that isn't a record");
              same env i.loc
                ("the implementation of `" ^ p.Path.name ^ "`")
                i.ty (Ty.impl [ d ] needs))
            impls
      | Some _ ->
          fail env loc
            (sprintf "an instance doesn't implement what `%s` does" (show e.ty))
      | None -> fail env loc (sprintf "an instance has type `%s`" (show e.ty)))
  | Narrowed (ds, h) -> (
      expr env sc h;
      match Ty.impl_parts h.ty with
      | Some (all, needs)
        when List.length ds < List.length all
             && List.for_all (fun d -> List.mem d (Ty.dep_paths all)) ds ->
          is "a handler narrowed to some of its dependencies"
            (Ty.impl
               (List.filter (fun (d : Ty.dep) -> List.mem d.dpath ds) all)
               needs)
      | Some _ ->
          fail env loc
            (sprintf "`%s` can't be narrowed to `%s`" (show h.ty)
               (String.concat " & " (List.map Path.full ds)))
      | None ->
          fail env h.loc
            (sprintf "a handler narrowed to `%s` has type `%s`"
               (String.concat " & " (List.map Path.full ds))
               (show h.ty)))
  | With_handler { ev; outer; handler; deps; desc; body } ->
      let what = "installing a handler" in
      current env loc what outer;
      is_evidence env loc what ev;
      expr env sc handler;
      (* each key installs the instance's implementation of a dependency
         its type lists, at the types that says, or as an alias of it:
         every one it lists, once; and what it needs, it needs here *)
      let keys =
        List.map
          (fun ((k : dkey), from) ->
            ( ({
                 dpath = k.kpath;
                 dargs = List.map (described env sc loc) k.kargs;
               }
                : Ty.dep),
              from ))
          deps
      in
      (match handler.ty with
      | Impl { deps = ds; needs; _ }
        when List.sort compare (List.map snd keys) = Ty.dep_paths ds
             && List.length ds > 1 ->
          List.iter
            (fun ((k : Ty.dep), from) ->
              let d = List.find (fun (d : Ty.dep) -> d.dpath = from) ds in
              let named =
                if k.dpath = from then k
                else
                  match Iface.alias_of (Hashtbl.find_opt env.types) k.dpath with
                  | Some t when k.dargs = [] -> t
                  | _ -> k
              in
              if named <> d then
                fail env loc
                  (sprintf "`%s` is installed as `%s`"
                     (show_dep (Ty.dep_of d))
                     (show_dep (Ty.dep_of k))))
            keys;
          List.iter (available env loc what) needs.labels
      | t ->
          fail env handler.loc
            (sprintf "what's installed has type `%s`, but should be `%s`"
               (show t)
               (String.concat " & "
                  (List.map (fun (k, _) -> show_dep (Ty.dep_of k)) keys))));
      expr
        {
          env with
          ev = Some ev;
          installed = List.map (fun (k, _) -> Ty.dep_of k) keys @ env.installed;
          in_loop = false;
        }
        (add ev sc) body;
      describes env sc loc "the body of a `With`" desc body.ty;
      is "a `With`" body.ty
  | Prim (op, args) -> prim env sc e op args
  | Let (v, value, body) ->
      expr env sc value;
      same env loc ("the value of `" ^ v.name ^ "`") value.ty v.ty;
      expr env (add v sc) body;
      is "a `let`" body.ty
  | Covered { body; result; after } ->
      (* what an arm's `finally` is given: a [Result] of what it covers,
         whose errors have `Cancelled`, which a cancelled body gives it *)
      expr env sc body;
      same env loc "what a `finally` is given" body.ty result.ty;
      (match result.ty with
      | Con (p, [ _; Errors row ])
        when p = Path.prelude "Result"
             && List.exists
                  (fun (l : Ty.label) -> l.name = "Cancelled" && l.payload = [])
                  row.labels ->
          ()
      | t ->
          fail env loc
            (sprintf
               "a `finally` given `%s`, not a `Result` whose errors have \
                `Cancelled`"
               (show t)));
      expr env (add result sc) after;
      is "a `finally`" after.ty
  | Assign (v, value) ->
      in_scope env sc loc v;
      expr env sc value;
      same env loc ("what's assigned to `" ^ v.name ^ "`") value.ty v.ty;
      is "an assignment" Ty.unit
  | If (c, t, f) ->
      List.iter (expr env sc) [ c; t; f ];
      same env loc "an `if` condition" c.ty Ty.bool;
      same env loc "the `then` branch" t.ty e.ty;
      same env loc "the `else` branch" f.ty e.ty
  | Match (s, arms) ->
      expr env sc s;
      List.iter
        (fun a ->
          let sc = pattern env sc a.pat s.ty in
          Option.iter
            (fun (g : expr) ->
              expr env sc g;
              same env g.loc "a guard" g.ty Ty.bool)
            a.guard;
          expr env sc a.body;
          same env a.body.loc "an arm" a.body.ty e.ty)
        arms
  | While (c, body) ->
      let env = { env with in_loop = true } in
      expr env sc c;
      expr env sc body;
      same env loc "a `while` condition" c.ty Ty.bool;
      is "a `while`" Ty.unit
  | Break ->
      (* of any type, since it never ends *)
      if not env.in_loop then
        fail env loc
          "a `Break` outside a `While`, or leaving a block, a handler or a \
           `With`"
  | Seq (a, b) ->
      expr env sc a;
      expr env sc b;
      is "a sequence" b.ty
  | Call (f, args, ev) -> (
      expr env sc f;
      (* every function takes the same: the evidence where it's called *)
      let what =
        match f.kind with
        | Global (p, _, _, _) -> sprintf "a call of `%s`" (Path.local p)
        | _ -> "a call"
      in
      current env loc what ev;
      match reveal env f.ty with
      | Fun (ps, ret, _, uses) ->
          (* what it uses is in the evidence it's passed: each dependency
             declared, that is, which has implementations *)
          List.iter
            (fun (l : Ty.label) ->
              let p = Ty.dep_path l.name in
              match Hashtbl.find_opt env.types p with
              | Some { Iface.body = Dep _ | Dep_alias _; _ } ->
                  available env loc what l
              | _ -> ())
            uses.labels;
          if List.length ps <> List.length args then
            fail env loc "a call has the wrong number of arguments";
          List.iter2
            (fun (p : Ty.param) a ->
              match (p.mode, a) with
              | Read, Value a ->
                  expr env sc a;
                  same env a.loc "an argument" a.ty p.ty
              | Inout, Ref v ->
                  in_scope env sc loc v;
                  same env loc "an `inout` argument" v.ty p.ty
              | Read, Ref _ ->
                  fail env loc "a read argument is passed as `inout`"
              | Inout, Value _ ->
                  fail env loc "an `inout` argument isn't a local")
            ps args;
          (* what it gives fits the call's type: a handler's description
             there may say it needs more than its handler does, since a
             stored description's `uses` is an upper bound (foundations.md,
             decision 3; Infer_expr.made) *)
          same env loc "what a call gives" ret e.ty
      | t -> fail env loc (sprintf "a call to a `%s`" (show t)))
  | Lambda { params; ev; outer; given; captures; body; _ } -> (
      (* a block captures the evidence where it's written, as a local *)
      let what = "a block" in
      current env loc what outer;
      if not (List.mem outer captures) then
        fail env loc "a block doesn't capture the evidence where it's written";
      List.iter (in_scope env sc loc) captures;
      is_evidence env loc "a block's evidence" ev;
      (* what it's given is what its type lists, which its callee provides *)
      let uses =
        match reveal env e.ty with Fun (_, _, _, u) -> u | _ -> Ty.closed
      in
      let given_labels =
        List.map
          (fun (k : dkey) ->
            Ty.dep_of
              {
                dpath = k.kpath;
                dargs = List.map (described env sc loc) k.kargs;
              })
          given
      in
      List.iter
        (fun l ->
          if not (List.exists (Ty.same_label l) uses.labels) then
            fail env loc
              (sprintf "a block is given `%s`, which its type doesn't list"
                 (show_dep l)))
        given_labels;
      (* the body sees only what it captures, its parameters, and its own
         evidence; and it's checked where it's written: it uses what's used
         or installed here, and what it's given *)
      let inner =
        List.fold_left
          (fun sc (p : param) -> add p.var sc)
          (List.fold_left (fun sc v -> add v sc) Scope.empty (ev :: captures))
          params
      in
      expr
        {
          env with
          ev = Some ev;
          uses = { env.uses with labels = env.uses.labels @ given_labels };
          in_loop = false;
        }
        inner body;
      match reveal env e.ty with
      | Fun (ps, ret, _, _) when List.length ps = List.length params ->
          List.iter2
            (fun (p : Ty.param) (q : param) ->
              if p.mode <> q.mode then fail env loc "a lambda parameter's mode";
              same env loc ("the parameter `" ^ q.var.name ^ "`") q.var.ty p.ty)
            ps params;
          same env body.loc "a lambda's body" body.ty ret
      | t -> fail env loc (sprintf "a lambda has type `%s`" (show t)))
  | Con (p, c, args) ->
      let td, targs = args_of env loc "a constructor" p e.ty in
      let k = ctor_of env loc td c in
      if List.length k.cfields <> List.length args then
        fail env loc (sprintf "`%s` is given the wrong number of fields" c);
      List.iter2
        (fun (f : Iface.field) (a : expr) ->
          expr env sc a;
          same env a.loc
            ("the field `" ^ f.fname ^ "`")
            a.ty (subst targs f.fty))
        k.cfields args
  | Record (p, fields) ->
      (* a record of a dependency's operations is an implementation of
         it, whose type says what it needs: only ever a handler's
         instance's ([Instance]), never a value of the program *)
      (match e.ty with
      | Impl _ ->
          fail env loc
            "a record of a dependency's operations outside a handler's instance"
      | _ -> ());
      let td, targs = args_of env loc "a record" p e.ty in
      let declared =
        List.map (fun (d : Iface.field) -> d.fname) (fields_of env loc td)
      in
      if List.sort compare declared <> List.sort compare (List.map fst fields)
      then fail env loc "a record literal doesn't have its type's fields";
      List.iter
        (fun (f, (v : expr)) ->
          expr env sc v;
          same env v.loc
            ("the field `" ^ f ^ "`")
            v.ty
            (field_ty env loc td targs f))
        fields
  | Field (r, p, f) ->
      expr env sc r;
      let td, targs = args_of env loc "a field's record" p r.ty in
      is ("the field `" ^ f ^ "`") (field_ty env loc td targs f)
  | Update (r, f, v) -> (
      expr env sc r;
      expr env sc v;
      match reveal env r.ty with
      | Con (p, _) ->
          let td, targs = args_of env loc "an updated record" p r.ty in
          same env loc
            ("the field `" ^ f ^ "`")
            v.ty
            (field_ty env loc td targs f);
          is "an update" r.ty
      | t -> fail env loc (sprintf "an update of a `%s`" (show t)))
  | Array xs -> (
      List.iter (expr env sc) xs;
      match reveal env e.ty with
      | Con (p, [ elem ]) when p = Path.prelude "Array" ->
          List.iter (fun (x : expr) -> same env x.loc "an element" x.ty elem) xs
      | t -> fail env loc (sprintf "an array literal has type `%s`" (show t)))
  | Tuple xs -> (
      List.iter (expr env sc) xs;
      match reveal env e.ty with
      | Con (p, parts)
        when xs <> []
             && p = Ty.tuple_path (List.length xs)
             && List.length parts = List.length xs ->
          List.iter2
            (fun (x : expr) part -> same env x.loc "a tuple's part" x.ty part)
            xs parts
      | t ->
          fail env loc
            (sprintf "a tuple of %d has type `%s`" (List.length xs) (show t)))
  | Tag (t, args, ds) -> (
      List.iter (expr env sc) args;
      if List.length ds <> List.length args then
        fail env loc
          (sprintf "the error `%s` has %d values, but %d descriptors" t
             (List.length args) (List.length ds));
      List.iter2
        (fun d (a : expr) ->
          describes env sc a.loc (sprintf "a value of the error `%s`" t) d a.ty)
        ds args;
      (* a set that has it: just it, after `fail`, or all of the set its
         `Err(...)` holds *)
      let label : Ty.label =
        { name = t; payload = List.map (fun a -> a.ty) args }
      in
      match reveal env e.ty with
      | Errors row
        when List.exists
               (fun (l : Ty.label) ->
                 l.name = t
                 && List.length l.payload = List.length label.payload
                 && List.for_all2 (equal env) l.payload label.payload)
               row.labels ->
          ()
      | t' ->
          fail env loc
            (sprintf "the error `%s` has type `%s`, which doesn't have it" t
               (show t')))
  | Fail a ->
      expr env sc a;
      ignore (errors_of env a.loc "what `fail` fails with" a.ty)
  | Handle { body; value; on_value; error; on_error } ->
      expr env sc body;
      same env loc "a handled value" value.ty body.ty;
      ignore (errors_of env loc "a handled error" error.ty);
      expr env (add value sc) on_value;
      expr env (add error sc) on_error;
      same env on_value.loc "what a `Handle` gives a value" on_value.ty e.ty;
      same env on_error.loc "what a `Handle` gives an error" on_error.ty e.ty
  | Finally (body, after) ->
      expr env sc body;
      expr env sc after;
      same env after.loc "what runs after a `Finally`" after.ty Ty.unit;
      is "a `Finally`" body.ty
  | Assert a ->
      expr env sc a;
      same env a.loc "what an `Assert` checks" a.ty Ty.bool;
      is "an `Assert`" Ty.unit
  | Assert_equal (a, b, d, dict) ->
      expr env sc a;
      expr env sc b;
      same env b.loc "the right side of an `Assert_equal`" b.ty a.ty;
      describes env sc loc "what an `Assert_equal` compares" d a.ty;
      gives env sc loc "an `Assert_equal`" dict "eq" a.ty;
      is "an `Assert_equal`" Ty.unit

(* The error set an error of type [t] is in. *)
and errors_of env loc what (t : Ty.ty) =
  match t with
  | Errors row -> row
  | t ->
      fail env loc
        (sprintf "%s has type `%s`, which isn't an error set" what (show t))

and prim env sc (e : expr) op args =
  let loc = e.loc in
  List.iter (expr env sc) args;
  let is what t = same env loc what e.ty t in
  let int (a : expr) = same env a.loc "an operand" a.ty Ty.int in
  let elem (a : expr) =
    match reveal env a.ty with
    | Con (p, [ t ]) when p = Path.prelude "Array" -> t
    | t -> fail env loc (sprintf "an array operation on a `%s`" (show t))
  in
  (* what can be sliced: an [Array], a [Str] or [Bytes] *)
  let sliced (a : expr) =
    match reveal env a.ty with
    | Con (p, [ _ ]) when p = Path.prelude "Array" -> ()
    | Con (p, []) when p = Path.prelude "Str" || p = Path.prelude "Bytes" -> ()
    | t -> fail env loc (sprintf "a slice of a `%s`" (show t))
  in
  (* a number, an [Int] or a [Float], once revealed, or a `with numeric`
     type, and what it's represented as: the language's own operators are
     on those *)
  let number (a : expr) =
    match reveal env a.ty with
    | t when t = Ty.int || t = Ty.float -> t
    | Con (p, []) as t -> (
        match Hashtbl.find_opt env.types p with
        | Some { numeric = Some _; _ } -> t
        | _ -> fail env a.loc (sprintf "arithmetic on a `%s`" (show a.ty)))
    | _ -> fail env a.loc (sprintf "arithmetic on a `%s`" (show a.ty))
  in
  let rep_of (t : Ty.ty) =
    match t with
    | Con (p, []) -> (
        match Hashtbl.find_opt env.types p with
        | Some { numeric = Some rep; _ } -> rep
        | _ -> t)
    | _ -> t
  in
  let plain (a : expr) =
    let t = number a in
    if t <> Ty.int && t <> Ty.float then
      fail env a.loc
        (sprintf "`%s` on a `%s`, which hasn't it" (show_prim op) (show a.ty))
  in
  match (op, args) with
  | Neg, [ a ] ->
      ignore (number a);
      is "`-`" a.ty
  | Not, [ a ] ->
      same env a.loc "an operand" a.ty Ty.bool;
      is "`not`" Ty.bool
  | Binop (And | Or), _ ->
      fail env loc "`&&` or `||` that wasn't lowered to an `if`"
  | Binop Orelse, _ -> fail env loc "an `orelse` that wasn't lowered"
  | Binop (Eq | Neq), _ ->
      fail env loc "`==` or `!=` without the dictionary it compares by"
  | (Equal d | Not_equal d), [ a; b ] ->
      same env loc "the right side of a comparison" b.ty a.ty;
      gives env sc loc "a comparison" d "eq" a.ty;
      is "a comparison" Ty.bool
  | Binop (Add | Sub), [ a; b ] ->
      ignore (number a);
      same env b.loc "the right side of arithmetic" b.ty a.ty;
      is "arithmetic" a.ty
  | Binop Mul, [ a; b ] ->
      (* a `with numeric` type's `*` is by what it's represented as *)
      let t = number a in
      same env b.loc "the right side of `*`" b.ty (rep_of t);
      is "arithmetic" a.ty
  | Binop (Div | Mod), [ a; b ] ->
      plain a;
      same env b.loc "the right side of arithmetic" b.ty a.ty;
      is "arithmetic" a.ty
  | Binop (Lt | Le | Gt | Ge), [ a; b ] ->
      plain a;
      same env b.loc "the right side of a comparison" b.ty a.ty;
      is "a comparison" Ty.bool
  | Compare (_, d), [ a; b ] ->
      same env b.loc "the right side of a comparison" b.ty a.ty;
      gives env sc loc "a comparison" d "ord" a.ty;
      is "a comparison" Ty.bool
  | Op (req, d), a :: rest when List.length rest = if req = "neg" then 0 else 1
    ->
      if not (List.mem req Iface.operators) then
        fail env loc (sprintf "`%s` isn't an operator" req);
      List.iter
        (fun (b : expr) ->
          same env b.loc "the right side of an operator" b.ty a.ty)
        rest;
      gives env sc loc "an operator" d req a.ty;
      is "an operator" a.ty
  | Value_of (req, d), [] ->
      if req <> "zero" && req <> "one" then
        fail env loc (sprintf "`%s` isn't an associated value" req);
      gives env sc loc "an associated value" d req e.ty
  | Length, [ a ] ->
      ignore (elem a);
      is "a length" Ty.int
  | Get_index _, [ a; i ] ->
      int i;
      is "an element" (elem a)
  | Entries, [ m ] -> (
      match reveal env m.ty with
      | Con (p, [ k; v ]) when p = Path.prelude "Map" ->
          is "a map's entries" (Ty.array (Ty.tuple [ k; v ]))
      | t -> fail env loc (sprintf "a map's entries of a `%s`" (show t)))
  | Members, [ s ] -> (
      match reveal env s.ty with
      | Con (p, [ t ]) when p = Path.prelude "Set" ->
          is "a set's members" (Ty.array t)
      | t -> fail env loc (sprintf "a set's members of a `%s`" (show t)))
  | Set_index _, [ a; i; v ] ->
      int i;
      same env v.loc "a new element" v.ty (elem a);
      is "an updated array" a.ty
  | Slice Range, [ a; i; j ] ->
      int i;
      int j;
      sliced a;
      is "a slice" a.ty
  | Slice Before, [ a; n ] ->
      int n;
      sliced a;
      is "a half" a.ty
  | Slice After, [ a; n; lo ] ->
      int n;
      sliced a;
      same env lo.loc "the first half" lo.ty a.ty;
      is "a half" a.ty
  | Splice, [ a; i; j; b ] ->
      int i;
      int j;
      sliced a;
      same env b.loc "what replaces a range" b.ty a.ty;
      is "a spliced array" a.ty
  | Join, [ a; b ] ->
      sliced a;
      same env b.loc "the second half" b.ty a.ty;
      is "two halves joined" a.ty
  | Vacant, [ a ] -> is "a place lent out" a.ty
  | New_cell, [ v ] -> is "a new cell" (cell_ty v.ty)
  | Get_cell, [ c ] -> is "what a cell holds" (held env c)
  | Set_cell, [ c; v ] ->
      same env v.loc "what's put in a cell" v.ty (held env c);
      is "changing a cell" Ty.unit
  (* a sized type's value, read as its wide type, and stored from it,
     checked or wrapped (sized.ml) *)
  | Widen, [ a ] -> (
      match Sized.of_ty a.ty with
      | Some k -> is "a sized value read" (Sized.wide k)
      | None -> fail env loc (sprintf "`widen` of a `%s`" (show a.ty)))
  | (Narrow | Wrap), [ a ] -> (
      match Sized.of_ty e.ty with
      | Some k when op = Wrap && not (Sized.wraps k) ->
          fail env loc (sprintf "`wrap` into a `%s`" (show e.ty))
      | Some k -> same env a.loc "what's stored" a.ty (Sized.wide k)
      | None -> fail env loc (sprintf "`%s` into a `%s`" (show_prim op) (show e.ty)))
  | Nan_check _, [ a ] -> is "a value checked for a NaN" a.ty
  | Tag_in _, [ a ] -> (
      match a.ty with
      | Errors _ -> is "whether an error has a tag" Ty.bool
      | t -> fail env loc (sprintf "`tag-in` of a `%s`, which isn't an error" (show t)))
  | _ ->
      fail env loc ("`" ^ show_prim op ^ "` with the wrong number of operands")

(* The type of what the cell [c] holds. *)
and held env (c : expr) =
  match c.ty with
  | Con (p, [ t ]) when p = Path.prelude "$Cell" -> t
  | t -> fail env c.loc (sprintf "a cell operation on a `%s`" (show t))

(* Check [p] against the type [t] of what it matches; the scope it binds. *)
and pattern env sc (p : pattern) t =
  let loc = p.ploc in
  (* as for an expression; a tag's subpattern whose payload isn't known
     is checked only against itself, below *)
  if has_error p.pty then fail env loc "a pattern has an error type";
  same env loc "a pattern" p.pty t;
  match p.pkind with
  | PWild -> sc
  | PVar v ->
      same env loc ("the pattern variable `" ^ v.name ^ "`") v.ty t;
      add v sc
  | PInt _ ->
      same env loc "an `Int` pattern" t Ty.int;
      sc
  | PBool _ ->
      same env loc "a `Bool` pattern" t Ty.bool;
      sc
  | PCon (path, c, ps) ->
      let td, targs = args_of env loc "a constructor pattern" path t in
      let k = ctor_of env loc td c in
      if List.length k.cfields <> List.length ps then
        fail env loc (sprintf "`%s` has the wrong number of subpatterns" c);
      List.fold_left2
        (fun sc (f : Iface.field) sub -> pattern env sc sub (subst targs f.fty))
        sc k.cfields ps
  | PTag (tag, ps) -> (
      let row = errors_of env loc "a tag pattern" t in
      match List.find_opt (fun (l : Ty.label) -> l.name = tag) row.labels with
      | Some l when List.length l.payload = List.length ps ->
          List.fold_left2 (fun sc t sub -> pattern env sc sub t) sc l.payload ps
      | Some _ ->
          fail env loc (sprintf "`%s` has the wrong number of subpatterns" tag)
      | None when row.tail <> None ->
          (* a set that may hold more: its payload isn't known here *)
          List.fold_left (fun sc sub -> pattern env sc sub sub.pty) sc ps
      | None ->
          fail env loc (sprintf "`%s` isn't in the set it's matched in" tag))
  | PTuple ps -> (
      match reveal env t with
      | Con (p, parts)
        when p = Ty.tuple_path (List.length ps)
             && List.length parts = List.length ps ->
          List.fold_left2
            (fun sc part sub -> pattern env sc sub part)
            sc parts ps
      | t' ->
          fail env loc
            (sprintf "a tuple pattern of %d matches a `%s`" (List.length ps)
               (show t')))
  | POr [] -> fail env loc "an or-pattern of nothing"
  | POr (first :: rest) ->
      let first_sc = pattern env sc first t in
      let names sc = List.map fst (Scope.bindings sc) in
      List.iter
        (fun alt ->
          if names (pattern env sc alt t) <> names first_sc then
            fail env alt.ploc
              "the alternatives of an or-pattern bind different variables")
        rest;
      first_sc

(* The operations [fs] of a handler's instance's implementation of [p],
   which needs [needs]: one for each the dependency declares, each of its
   declared type, using what the implementation needs. *)
and operations env sc loc (d : Ty.dep) needs fs =
  let ops = dep_fields env loc d in
  let declared = List.map (fun (o : Iface.field) -> o.fname) ops in
  if List.sort compare declared <> List.sort compare (List.map fst fs) then
    fail env loc "an implementation doesn't have its dependency's operations";
  List.iter
    (fun (f, (v : expr)) ->
      expr env sc v;
      let expected : Ty.ty =
        match (List.find (fun (o : Iface.field) -> o.fname = f) ops).fty with
        | Fun (ps, r, errs, _) -> Fun (ps, r, errs, needs)
        | t -> t
      in
      same env v.loc ("the operation `" ^ f ^ "`") v.ty expected)
    fs

(* An installed handler instance is never a value (compiler.md, "No
   cycles"): an [Instance] is only ever the end of a [Handler]'s body,
   after the [Let]s and statements that make its state, and the [Handle]
   around the state after a `finally`, which is where a [With] gets it
   from. Anywhere else, a program could hold one, and a
   handler's state could reach its own instance. *)

(* A handler's `finally` (core.ml, [Instance]): a lambda that takes the
   descriptor of the `with`'s body's type, which is the variable after its
   handler's function's own, then the body's outcome, a [Result] of it, and
   gives a value of it. *)
and finally_ env sc (f : expr) =
  let k = env.ntys in
  match f.kind with
  | Lambda { params = [ d; r ]; _ } -> (
      if d.var.ty <> type_ty then
        fail env f.loc "a `finally`'s first parameter isn't a descriptor";
      match (r.var.ty, f.ty) with
      | Con (p, [ Var n; Errors _ ]), Fun (_, Var m, _, _)
        when p = Path.prelude "Result" && n = k && m = k ->
          expr { env with ntys = k + 1; body_ty = Some d.var } sc f
      | t, _ ->
          fail env f.loc
            (sprintf "a `finally` is given `%s`, not its body's result" (show t))
      )
  | _ -> fail env f.loc "a `finally` that isn't a lambda"

let rec instances env (e : expr) =
  match e.kind with
  | Handler { body; _ } -> handler_end env body
  | Instance _ ->
      fail env e.loc "an instance that isn't the end of a handler's body"
  | _ -> List.iter (instances env) (children e)

and handler_end env (e : expr) =
  match e.kind with
  | Let (_, a, b) | Covered { body = a; after = b; _ } | Seq (a, b) ->
      instances env a;
      handler_end env b
  | Handle { body; value; on_value = { kind = Local v; _ }; on_error; _ }
    when v = value ->
      (* the state after a `finally`, which is given what that fails to
         start with (lower.ml), and then fails with it *)
      handler_end env body;
      instances env on_error
  | Instance { impls; finally; _ } ->
      List.iter (fun (_, i) -> instances env i) impls;
      Option.iter (instances env) finally
  | _ -> fail env e.loc "a handler's body that doesn't end in an instance"

(* Blocks are second-class (foundations.md): inference checked that a
   value of a function type is only called, passed as an argument, or
   bound by a `let` (Infer_top.check_blocks), and lowering mustn't make
   one anywhere else, a result, a record's field, an array's element. An
   operation of a handler's instance is the exception: the instance's
   records of operations are how a handler is built, and never leave it.
   As in Effekt, whose typer checks where each block is used
   (effekt/shared/src/main/scala/effekt/Typer.scala:572-615 and
   1015-1084). [allowed] says whether [e] is in one of those places. *)
let rec blocks env allowed (e : expr) =
  (match e.ty with
  | Fun _ when not allowed ->
      fail env e.loc
        "a block that isn't called, passed, or the value of a `let`"
  | _ -> ());
  match e.kind with
  | Call (callee, args, _) ->
      blocks env true callee;
      List.iter (function Value a -> blocks env true a | Ref _ -> ()) args
  | Dep_call { args; _ } -> List.iter (blocks env true) args
  | Let (_, value, body) ->
      blocks env true value;
      blocks env false body
  | Covered { body; after; _ } ->
      blocks env false body;
      blocks env false after
  | Instance { impls; finally; _ } ->
      List.iter
        (fun (_, (i : expr)) ->
          match i.kind with
          | Record (_, ops) -> List.iter (fun (_, o) -> blocks env true o) ops
          | _ -> blocks env false i)
        impls;
      Option.iter (blocks env true) finally
  | _ -> List.iter (blocks env false) (children e)

(* Whether there's a function type in [t] (or in an error's payload). *)
let rec has_fun (t : Ty.ty) =
  match t with
  | Fun _ -> true
  | Con (_, ts) -> List.exists has_fun ts
  | Errors r -> row_has_fun r
  | Var _ | Impl _ | Error -> false

and row_has_fun (r : Ty.row) =
  List.exists (fun (l : Ty.label) -> List.exists has_fun l.payload) r.labels

(* Whether there's a function type in [t] somewhere other than where a
   block can be: a type's argument, or an error's payload. A function
   type's own parameters are where blocks are passed. *)
let rec fun_inside (t : Ty.ty) =
  match t with
  | Con (_, ts) -> List.exists has_fun ts
  | Errors r -> row_has_fun r
  | Fun (ps, ret, errs, _) ->
      List.exists (fun (p : Ty.param) -> fun_inside p.ty) ps
      || fun_inside ret || row_has_fun errs
  | Var _ | Impl _ | Error -> false

(* A type variable never stands for a block, since `T` could be stored:
   no type argument a use picked has a function type in it, and no
   expression's type has one inside another type, `Option<fn()>`. *)
let rec no_fun_args env (e : expr) =
  let args what (a : Ty.args) =
    if List.exists has_fun a.tys || List.exists row_has_fun a.rows then
      fail env e.loc
        (sprintf "`%s` is given a block's type as a type argument" what)
  in
  (match e.kind with
  | Global (p, a, _, _) | Global_value (p, a) -> args (Path.local p) a
  | Intrinsic (i, a, _, _) -> args (Intrinsic.name i) a
  | _ -> ());
  if fun_inside e.ty then
    fail env e.loc (sprintf "a block inside the type `%s`" (show e.ty));
  List.iter (no_fun_args env) (children e)

(* A scope and a task's handle are blocks too (foundations.md, decision
   2, rule D): never inside another type, a type argument a use picked
   among them, so never in a constructor, a record, a tuple or an array;
   and never a function's result but the prelude's `Scope.start`, which
   makes one. Inference checked it (Infer_top.check_blocks). *)
let is_handle (t : Ty.ty) =
  match t with
  | Con (p, []) -> p = Path.prelude "Scope"
  | Con (p, [ _ ]) -> p = Path.prelude "Task"
  | _ -> false

let rec has_handle (t : Ty.ty) =
  is_handle t
  ||
  match t with
  | Con (_, ts) -> List.exists has_handle ts
  | Fun (ps, ret, _, _) ->
      List.exists (fun (p : Ty.param) -> has_handle p.ty) ps || has_handle ret
  | Errors _ | Var _ | Impl _ | Error -> false

(* a handle somewhere other than where one can be: a function type's
   parameter, or what it gives, which [fn_def] checks *)
let rec handle_inside (t : Ty.ty) =
  match t with
  | Con (_, ts) -> List.exists has_handle ts
  | Fun (ps, ret, _, _) ->
      List.exists (fun (p : Ty.param) -> handle_inside p.ty) ps || handle_inside ret
  | Errors _ | Var _ | Impl _ | Error -> false

let rec no_kept_handles env ~prelude (e : expr) =
  let args what (a : Ty.args) =
    (* the prelude's own members make and take them, through intrinsics *)
    if (not prelude) && List.exists has_handle a.tys then
      fail env e.loc
        (sprintf "`%s` is given a scope's or a task's type as a type argument"
           what)
  in
  (match e.kind with
  | Global (p, a, _, _) | Global_value (p, a) -> args (Path.local p) a
  | Intrinsic (i, a, _, _) -> args (Intrinsic.name i) a
  | _ -> ());
  if handle_inside e.ty then
    fail env e.loc (sprintf "a scope or a task's handle inside `%s`" (show e.ty));
  List.iter (no_kept_handles env ~prelude) (children e)

(* No code reached from a call with an empty row runs a scheduling point
   (compiler.md, "Stage 11a", "The two holes"): each intrinsic that can
   wait for another task is called only by the prelude's own functions
   whose rows have `Async`, so a call that can reach one has `Async` in
   its row too; or by the prelude's handlers of `Async`, the runtime,
   whose arms run only when an operation of `Async` is called, which
   needs it in the caller's row. *)
let waits_only_with_async env (f : fn_def) =
  let async = Path.prelude "Async" in
  let has_async =
    match f.scheme.ty with
    | Fun (_, _, _, uses) ->
        List.exists
          (fun (l : Ty.label) -> l.name = Ty.dep_label async)
          uses.labels
    | _ -> false
  in
  let runtime =
    match f.scheme.ty with
    | Fun (_, Impl i, _, _) -> List.mem async (Ty.dep_paths i.deps)
    | _ -> false
  in
  let has_async = has_async || runtime in
  let rec go (e : expr) =
    (match e.kind with
    | Intrinsic (x, _, _, _)
      when Intrinsic.waits x
           && not (f.path.home = Path.prelude_home && has_async) ->
        fail env e.loc
          (sprintf "`%s` can wait, and is called where `Async` isn't used"
             (Intrinsic.name x))
    | _ -> ());
    List.iter go (children e)
  in
  go f.body

let fn_def env (f : fn_def) =
  let env = { env with fn = Path.local f.path; ntys = List.length f.tys } in
  no_kept_handles env ~prelude:(f.path.home = Path.prelude_home) f.body;
  waits_only_with_async env f;
  (match f.scheme.ty with
  | Fun (_, ret, _, _) when is_handle ret && f.path.home <> Path.prelude_home ->
      fail env f.loc "a function gives a scope or a task's handle"
  | _ -> ());
  instances env f.body;
  (* each index marked in bounds is, by what its loop shows (bounds.ml) *)
  Option.iter
    (fun (e : expr) ->
      fail env e.loc "an index marked in bounds that its loop doesn't keep so")
    (Bounds.verify f.body);
  blocks env false f.body;
  no_fun_args env f.body;
  if f.tys <> type_params f.scheme then
    fail env f.loc
      "its hidden type parameters aren't one for each of its type variables";
  if f.dicts <> dict_params f.scheme then
    fail env f.loc
      "its hidden dictionary parameters aren't one for each of its requirements";
  let env = { env with own = List.combine f.scheme.reqs f.dicts } in
  match f.scheme.ty with
  | Fun (ps, ret, _, uses) when List.length ps = List.length f.params ->
      let env = inside env f.loc "the function's evidence" f.ev uses in
      List.iter2
        (fun (p : Ty.param) (q : param) ->
          if p.mode <> q.mode then fail env f.loc "a parameter's mode";
          same env f.loc ("the parameter `" ^ q.var.name ^ "`") q.var.ty p.ty)
        ps f.params;
      let sc =
        List.fold_left
          (fun sc (p : param) -> add p.var sc)
          (List.fold_left
             (fun sc v -> add v sc)
             Scope.empty
             ((f.ev :: f.tys) @ f.dicts))
          f.params
      in
      expr env sc f.body;
      same env f.loc "the body" f.body.ty ret
  | t -> fail env f.loc (sprintf "a function has type `%s`" (show t))

(* The functions and values [e] names, in the order written. *)
let rec globals (e : expr) =
  match e.kind with
  | Global (p, _, _, _) | Global_value (p, _) -> [ p ]
  | Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Intrinsic _ | Break ->
      []
  | Prim (_, es)
  | Array es
  | Tuple es
  | Con (_, _, es)
  | Tag (_, es, _)
  | Dep_call { args = es; _ } ->
      List.concat_map globals es
  | With { impl; body; _ } -> globals impl @ globals body
  | With_handler { handler; body; _ } -> globals handler @ globals body
  | Instance { impls; finally; _ } ->
      List.concat_map (fun (_, i) -> globals i) impls
      @ Option.fold ~none:[] ~some:globals finally
  | Handler { body; _ } -> globals body
  | Let (_, a, b)
  | Covered { body = a; after = b; _ }
  | While (a, b)
  | Seq (a, b)
  | Update (a, _, b)
  | Finally (a, b)
  | Assert_equal (a, b, _, _) ->
      globals a @ globals b
  | Assign (_, a)
  | Field (a, _, _)
  | Lambda { body = a; _ }
  | Fail a
  | Narrowed (_, a)
  | Assert a ->
      globals a
  | Handle { body; on_value; on_error; _ } ->
      globals body @ globals on_value @ globals on_error
  | If (c, t, f) -> globals c @ globals t @ globals f
  | Match (s, arms) ->
      globals s
      @ List.concat_map
          (fun a -> Option.fold ~none:[] ~some:globals a.guard @ globals a.body)
          arms
  | Call (f, args, _) ->
      globals f
      @ List.concat_map (function Value a -> globals a | Ref _ -> []) args
  | Record (_, fs) -> List.concat_map (fun (_, a) -> globals a) fs

(* Every value in [prog.values] comes after each of the module's values it
   reaches, through the module's functions it calls: those are made first,
   when the program starts. A lambda's body is followed too, as inference
   does. *)
let value_order (prog : program) =
  (* each function's body by its path, found once rather than by a walk
     of every function each time; folded from the right, so the first of
     two with one path is the one kept, as [List.find_opt] would *)
  let bodies =
    List.fold_right
      (fun (f : fn_def) m -> Path.Map.add f.path f.body m)
      prog.fns Path.Map.empty
  in
  let body p = Path.Map.find_opt p bodies in
  let rec walk ~seen ~made v p =
    if not (Hashtbl.mem seen p) then (
      Hashtbl.replace seen p ();
      if p <> v && List.mem p prog.values && not (List.mem p made) then
        failwith
          (sprintf
             "Core Lint: the value `%s` is made before `%s`, which it uses"
             (Path.local v) (Path.local p));
      Option.iter
        (fun b -> List.iter (walk ~seen ~made v) (globals b))
        (if p = v || not (List.mem p prog.values) then body p else None))
  in
  ignore
    (List.fold_left
       (fun made v ->
         walk ~seen:(Hashtbl.create 8) ~made v v;
         v :: made)
       [] prog.values)

(* Each type [prog] says shows its values through its own `show` method
   is one it declares, and that method one of its functions, of the type
   the interpreter calls it at: taking only a value of the type, with the
   type's parameters as its type variables, in order, and giving a `Str`
   without failing or using anything. *)
let shows env (prog : program) =
  List.iter
    (fun (p, m) ->
      let env = { env with fn = Path.local m } in
      match
        ( List.find_opt (fun (d : Iface.type_decl) -> d.path = p) prog.types,
          List.find_opt (fun (f : fn_def) -> f.path = m) prog.fns )
      with
      | Some d, Some f -> (
          let own = List.init (List.length d.params) (fun n -> Ty.Var n) in
          match f.scheme.ty with
          | Fun ([ { mode = Read; ty = Con (q, args) } ], ret, errs, uses)
            when q = p && args = own && ret = Ty.str && errs.labels = []
                 && uses.labels = [] ->
              ()
          | t ->
              fail env f.loc
                (sprintf "`%s` shows a `%s`, but has type `%s`" (Path.local m)
                   (Path.full p) (show t)))
      | None, _ ->
          failwith
            (sprintf
               "Core Lint: `%s` is said to show `%s`, which isn't declared here"
               (Path.local m) (Path.full p))
      | _, None ->
          failwith
            (sprintf
               "Core Lint: `%s` is said to show `%s`, but isn't a function here"
               (Path.local m) (Path.full p)))
    prog.shows

(* Each type [prog] says has a `key` is one it declares, and its key one
   of its functions, of the type the interpreter calls it at: taking only
   a value of the type, with the type's parameters as its type variables,
   in order, without failing or using anything. And each type it says
   has an operator or an associated value through a member, `add` or
   `zero`, has that member: an operator that takes one or two of the type
   and gives one, without failing or using anything, or a value of the
   type, made before anything uses it. *)
let keys_and_ops env (prog : program) =
  let decl what (p : Path.t) =
    match
      List.find_opt (fun (d : Iface.type_decl) -> d.path = p) prog.types
    with
    | Some d -> List.init (List.length d.params) (fun n -> Ty.Var n)
    | None ->
        failwith
          (sprintf "Core Lint: `%s` is said to have %s, but isn't declared here"
             (Path.full p) what)
  in
  let fn what (m : Path.t) =
    match List.find_opt (fun (f : fn_def) -> f.path = m) prog.fns with
    | Some f -> f
    | None ->
        failwith
          (sprintf "Core Lint: %s, `%s`, isn't a function here" what
             (Path.local m))
  in
  let pure (t : Ty.ty) =
    match t with
    | Fun (ps, ret, errs, uses) when errs.labels = [] && uses.labels = [] ->
        Some (List.map (fun (p : Ty.param) -> p.ty) ps, ret)
    | _ -> None
  in
  List.iter
    (fun (p, m) ->
      let own = decl "a key" p in
      let f = fn "a key" m in
      match pure f.scheme.ty with
      | Some ([ Con (q, args) ], _) when q = p && args = own -> ()
      | _ ->
          fail
            { env with fn = Path.local m }
            f.loc
            (sprintf "`%s` is the key of `%s`, but has type `%s`" (Path.local m)
               (Path.full p) (show f.scheme.ty)))
    prog.keys;
  List.iter
    (fun ((p, req), m) ->
      let own = decl ("`" ^ req ^ "`") p in
      let self = Ty.Con (p, own) in
      let f = fn ("its `" ^ req ^ "`") m in
      let fits =
        match (req, pure f.scheme.ty) with
        | ("zero" | "one"), _ -> (
            (* a value is made by a function of no parameters *)
            List.mem m prog.values
            &&
            match f.scheme.ty with
            | Fun ([], r, _, _) -> r = self
            | _ -> false)
        | "neg", Some ([ a ], r) -> a = self && r = self
        | _, Some ([ a; b ], r) -> a = self && b = self && r = self
        | _ -> false
      in
      if not (List.mem req Iface.requirements && fits) then
        fail
          { env with fn = Path.local m }
          f.loc
          (sprintf "`%s` gives `%s` its `%s`, but has type `%s`" (Path.local m)
             (Path.full p) req (show f.scheme.ty)))
    prog.ops

(* Only test code calls a test function (ast.ml, [fn_def.test]): so
   `ren run`, which leaves test functions out, leaves out nothing it
   runs. Resolve reports a call of a test item from other code, so this
   holds whatever's written. [tests] are the program's test functions. *)
let test_code ~tests (prog : program) =
  List.iter
    (fun (f : fn_def) ->
      if not f.test then
        match List.find_opt (Hashtbl.mem tests) (globals f.body) with
        | Some g ->
            failwith
              (sprintf
                 "Core Lint: in `%s`, at %s:%d:%d: it isn't test code, but \
                  uses the test function `%s`"
                 (Path.local f.path) f.loc.file f.loc.start.line f.loc.start.col
                 (Path.local g))
        | None -> ())
    prog.fns

(* Every intrinsic that reaches the world (Prelude.reaches) is called
   only by the real implementation of the dependency it's an operation
   of, `fs_read` by `real_fs`, the prelude's handler that `Fs.real`
   describes: so every call a program makes to the world
   is a call of an operation, which the journal records (handlers.md,
   "Recording and replaying"). And a journal's file is read only for a
   test, by `replay`, so `ren run` reads nothing but through a
   dependency. The prelude is linted whenever it's loaded, so every run
   of the tests checks it. *)
let world (prog : program) =
  List.iter
    (fun (f : fn_def) ->
      let wrong (e : expr) msg =
        failwith
          (sprintf "Core Lint: in `%s`, at %s:%d:%d: %s" (Path.local f.path)
             e.loc.file e.loc.start.line e.loc.start.col msg)
      in
      let rec go (e : expr) =
        (match e.kind with
        | Intrinsic (x, _, _, _) -> (
            match Prelude.reaches x with
            | Some (dep, _)
              when f.path <> Path.prelude ("real_" ^ String.lowercase_ascii dep)
              ->
                wrong e
                  (sprintf
                     "`%s` reaches the world, so only `%s.real` can call it"
                     (Intrinsic.name x) dep)
            | _ when x = Journal_load && not f.test ->
                wrong e
                  "`journal_load` reads a file, so only test code can call it"
            | _ -> ())
        | _ -> ());
        List.iter go (Core.children e)
      in
      go f.body)
    prog.fns

(* What a release build's specialization (specialize.ml) says, checked
   against the code: a parameter that's a cell, a known handler's state,
   is only a function's the specializer made; at each [With] whose
   handler is known ([fn_def.known]), the handler is the one written
   there, and no call of one of its operations goes through the evidence;
   a direct call of an operation ([Lifted_op]) is where the handler it's
   of is known, and a call of a function that knows a handler is where
   the same one is known: the shape a function was specialized for is
   the one each of its callers has. *)
let specialized ~(fns : (Path.t, fn_def) Hashtbl.t) (f : fn_def) =
  let env_fail (loc : Loc.t) msg =
    failwith
      (sprintf "Core Lint: in `%s`, at %s:%d:%d: %s" (Path.local f.path)
         loc.file loc.start.line loc.start.col msg)
  in
  let is_cell (t : Ty.ty) =
    match (t, cell_ty Ty.unit) with
    | Con (p, [ _ ]), Con (c, _) -> p = c
    | _ -> false
  in
  if f.origin = Written then
    List.iter
      (fun (p : param) ->
        if is_cell p.var.ty then
          env_fail f.loc
            (sprintf "the parameter `%s` is a cell, in a function as written"
               p.var.name))
      f.params;
  let known_in (g : fn_def) (ev : var) =
    List.filter (fun (k : known) -> k.kev.id = ev.id) g.known
  in
  let known_at = known_in f in
  let shape ks =
    List.sort compare (List.map (fun (k : known) -> (k.kdep, k.khandler)) ks)
  in
  let rec go (e : expr) =
    (match e.kind with
    | Call ({ kind = Global (p, _, _, _); _ }, _, cev) -> (
        match Hashtbl.find_opt fns p with
        | Some g ->
            (match g.origin with
            | Lifted_op { dep; handler; op } ->
                if
                  not
                    (List.exists
                       (fun (k : known) -> k.kdep = dep && k.khandler = handler)
                       (known_at cev))
                then
                  env_fail e.loc
                    (sprintf
                       "a direct call of `%s`, where `%s`'s handler isn't \
                        known to be `%s`"
                       op (Path.local dep) (Path.local handler))
            | Written | Copy _ | Lifted_block _ -> ());
            let theirs = shape (known_in g g.ev) in
            if
              theirs <> []
              && not
                   (List.for_all
                      (fun k -> List.mem k (shape (known_at cev)))
                      theirs)
            then
              env_fail e.loc
                (sprintf
                   "a call of `%s`, which knows a handler this call doesn't"
                   (Path.local p))
        | None -> ())
    | Dep_call { dep; ev; next = false; op; _ }
      when List.exists (fun (k : known) -> k.kdep = dep) (known_at ev) ->
        env_fail e.loc
          (sprintf
             "`%s.%s` called through the evidence, where its handler is known"
             (Path.local dep) op)
    | With { ev; dep; impl; _ }
      when List.exists (fun (k : known) -> k.kdep = dep) (known_at ev) -> (
        match impl.kind with
        | Handler _ -> ()
        | _ ->
            env_fail e.loc
              (sprintf
                 "a `with` of a known `%s` handler that isn't written there"
                 (Path.local dep)))
    | _ -> ());
    List.iter go (children e)
  in
  go f.body

(* What linting every module of a program shares, made once for all of
   them (whole program, below): what each sees of the rest, and the
   program's test functions and functions by path. Made again for each
   module, as it was, these were O(modules × functions), which was 96% of
   a 500,000-line program's release build (compiler.md, "Native slice",
   step 9). *)
type whole = {
  base : env;
      (** its tables: the interfaces [everyone] sees, then each module's
          dependencies, then each function's scheme, if no interface has it *)
  deps : (Path.t, Iface.type_decl) Hashtbl.t;  (** each module's dependencies *)
  tests : (Path.t, unit) Hashtbl.t;
  fns : (Path.t, fn_def) Hashtbl.t;
}

(* Each interface's types, members and values, in [env]'s tables, by
   [put_type] and [put], each [Hashtbl.replace] or [Hashtbl.add]: two
   arguments, since the tables hold different things, and a function
   passed as an argument has one type wherever it's used. *)
let add_ifaces env put_type put (ifaces : Iface.t list) =
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          put_type env.types td.path td;
          Path.Map.iter
            (fun p (o : Iface.op) ->
              put
                (if o.okind = Value then env.values else env.schemes)
                p o.oscheme)
            td.members)
        iface.types;
      List.iter
        (fun (v : Iface.value) ->
          put env.schemes (Path.make iface.home v.vname) v.scheme)
        (iface.values @ iface.tests))
    ifaces

(* The table a function's scheme is in, and the scheme: an associated
   value's function has no parameters, and its result is the value, which
   is all the rest of the module sees of it. *)
let scheme_entry env (m : program) (f : fn_def) =
  match f.scheme with
  | { ty = Fun ([], t, _, _); _ } as s when List.mem f.path m.values ->
      (env.values, { s with ty = t })
  | s -> (env.schemes, s)

let whole ~everyone (linked : program list) =
  let base =
    {
      types = Hashtbl.create 256;
      schemes = Hashtbl.create 1024;
      values = Hashtbl.create 64;
      fn = "";
      ev = None;
      handler = None;
      uses = Ty.closed;
      installed = [];
      ntys = 0;
      body_ty = None;
      own = [];
      in_loop = false;
    }
  in
  add_ifaces base Hashtbl.replace Hashtbl.replace everyone;
  let deps = Hashtbl.create 16 in
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          match td.body with
          | Dep _ | Dep_alias _ ->
              Hashtbl.replace deps td.path td;
              Hashtbl.replace base.types td.path td
          | Record _ | Sum _ | Builtin | Opaque _ | Errors _ -> ())
        m.types)
    linked;
  (* another module's function is used as its interface states it, if it
     has one; a module's own functions are added over these for it *)
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (f : fn_def) ->
          let table, s = scheme_entry base m f in
          if not (Hashtbl.mem table f.path) then Hashtbl.replace table f.path s)
        m.fns)
    linked;
  let tests = Hashtbl.create 16 and fns = Hashtbl.create 1024 in
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (f : fn_def) ->
          if f.test then Hashtbl.replace tests f.path ();
          Hashtbl.replace fns f.path f)
        m.fns)
    linked;
  { base; deps; tests; fns }

(* Lint module [prog] of the program [w] was made from, which sees the
   interfaces [imports]: every one reachable through its imports, since a
   type from any of them can turn up in its code. The program's modules
   are known too: `$start` installs the prelude's real implementations,
   which no interface has. The evidence a function is passed can hold an
   implementation of a dependency its module can't see, too (one declared
   in a module that imports it), so every module's dependencies are known
   here; their other types aren't, since another module's opaque type
   must stay opaque.

   What [prog] sees on top of what every module does, its imports, its
   own types and its own functions, is added over [w]'s tables with
   [Hashtbl.add], which hides what was there, and taken out after with
   [Hashtbl.remove], which shows it again: so each module is checked
   seeing what it saw when its tables were made for it alone, in the
   order they were (imports, then the program's dependencies, then its
   types, then its functions over any interface's), at the cost of what
   it adds. *)
let lint_module w ~imports (prog : program) =
  let env = w.base in
  let added = ref [] in
  let put table k v =
    Hashtbl.add table k v;
    added := (fun () -> Hashtbl.remove table k) :: !added
  and put_type table k v =
    Hashtbl.add table k v;
    added := (fun () -> Hashtbl.remove table k) :: !added
  in
  Fun.protect
    ~finally:(fun () -> List.iter (fun undo -> undo ()) !added)
    (fun () ->
      add_ifaces env put_type put imports;
      (* a dependency an import declares is the program's own declaration
         of it, which was added after the imports *)
      List.iter
        (fun (iface : Iface.t) ->
          List.iter
            (fun (td : Iface.type_decl) ->
              match Hashtbl.find_opt w.deps td.path with
              | Some d -> put_type env.types td.path d
              | None -> ())
            iface.types)
        imports;
      List.iter
        (fun (td : Iface.type_decl) -> put_type env.types td.path td)
        prog.types;
      List.iter
        (fun (f : fn_def) ->
          let table, s = scheme_entry env prog f in
          put table f.path s)
        prog.fns;
      value_order prog;
      test_code ~tests:w.tests prog;
      world prog;
      shows env prog;
      keys_and_ops env prog;
      List.iter (fn_def env) prog.fns;
      List.iter (specialized ~fns:w.fns) prog.fns)

let program ~imports ~linked (prog : program) =
  lint_module (whole ~everyone:[] (linked @ [ prog ])) ~imports prog

let programs ?(everyone = []) ~imports (linked : program list) =
  let w = whole ~everyone linked in
  List.iter2 (fun imports m -> lint_module w ~imports m) imports linked
