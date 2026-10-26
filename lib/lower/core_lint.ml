(* Core Lint: type-check Core (core.ml) again, from scratch.

   Lowering rewrites a lot (places, loops, temporaries), and a mistake in
   it would show up as the interpreter computing something wrong, far from
   the cause. Lint catches it at the node where it happened instead. It
   checks that every node's type is the one its parts say it has (a use
   of a top-level function's, its scheme's at the type arguments it
   carries), that every local is used inside its scope with the type it
   was bound with, that a lambda captures every local it uses, and that every constructor,
   record and field is in the type it says, and that an error has the
   payload its set says, and that a handler's instance is only ever the
   end of its body. And that the evidence is threaded (core.ml):
   that every call passes the evidence in scope, a lambda's own inside it
   and never one it could have kept from where it was made, and that each
   dependency an operation or a callee uses is one the function it's in
   uses too, or a [With] around it installs. And that each descriptor of
   a type (core.ml, [desc]) describes the type argument it's passed for,
   built only from the hidden type parameters of the function it's in, and
   that each type said to show itself has a `show` method the interpreter
   can call. Which errors code can fail with isn't checked: inference
   has, and Core has no use for them.

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
  installed : Path.t list;  (** what the [With]s around here in it install *)
  ntys : int;  (** how many hidden type parameters the function has *)
}

let show t =
  Ty.show
    (Ty.printer
       ~show_tail:(fun _ -> true)
       ~names:Path.full
       { ty = t; names = []; reqs = [] })
    t

let fail env (loc : Loc.t) msg =
  failwith
    (sprintf "Core Lint: in `%s`, at %s:%d:%d: %s" env.fn loc.file
       loc.start.line loc.start.col msg)

let rec has_error (t : Ty.ty) =
  match t with
  | Error -> true
  | Var _ -> false
  | Con (_, args) -> List.exists has_error args
  | Errors e | Uses e -> row_has_error e
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
  | Uses u -> Uses u
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
      | Some { Iface.body = Opaque (Some rep); _ } ->
          reveal env (subst args rep)
      | _ -> t)
  | Fun _ | Var _ | Errors _ | Uses _ | Error -> t

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
  | Uses a, Uses b ->
      (* an implementation that needs less will do where one that needs
         more is wanted (Infer_rows.widen); where it's used, what it needs
         is copied, with a tail of its own (Infer_rows.copy_needs) *)
      List.for_all (fun l -> List.mem l b.labels) a.labels
      && (a.tail = None || b.tail <> None)
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
    | Errors e, Errors e' | Uses e, Uses e' -> row e e'
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

(* [s], a scheme's type, with the type arguments [a] put in (Ty.args): the
   n-th of [a.tys] for [Var n], and for a row ending in row variable [n],
   the n-th of [a.rows]'s labels added to the row's, ending in its tail.
   A canonical row has each label once, so where both have a label of one
   name, the row's own is kept. *)
let rec apply (a : Ty.args) (s : Ty.ty) : Ty.ty =
  match s with
  | Var n -> List.nth a.tys n
  | Error -> Error
  | Con (p, args) -> Con (p, List.map (apply a) args)
  | Errors e -> Errors (apply_row a e)
  | Uses u -> Uses (apply_row a u)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = apply a p.ty }) ps,
          apply a r,
          apply_row a e,
          apply_row a u )

and apply_row a (r : Ty.row) : Ty.row =
  let labels =
    List.map
      (fun (l : Ty.label) -> { l with payload = List.map (apply a) l.payload })
      r.labels
  in
  match r.tail with
  | None -> { labels; tail = None }
  | Some n ->
      let more : Ty.row = List.nth a.rows n in
      let has (l : Ty.label) =
        List.exists (fun (k : Ty.label) -> k.name = l.name) labels
      in
      {
        labels =
          Ty.sort_labels
            (labels @ List.filter (fun l -> not (has l)) more.labels);
        tail = more.tail;
      }

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
  let expected = apply a s in
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
      (* a dependency's one argument is what its implementation needs *)
      let arity =
        match td.body with Dep _ -> 1 | _ -> List.length td.params
      in
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
  | Record _ | Builtin | Opaque _ | Errors _ | Dep _ | Handler _ ->
      fail env loc (sprintf "`%s` isn't a sum type" td.path.name)

let fields_of env loc (td : Iface.type_decl) =
  match td.body with
  | Record fs | Dep fs -> fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Handler _ ->
      fail env loc (sprintf "`%s` isn't a record" td.path.name)

let field_ty env loc (td : Iface.type_decl) args f =
  match
    List.find_opt (fun (d : Iface.field) -> d.fname = f) (fields_of env loc td)
  with
  | Some d -> subst args d.fty
  | None -> fail env loc (sprintf "`%s` has no field `%s`" td.path.name f)

(* [v] is evidence, which only a function, a lambda or a [With] binds. *)
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

(* The dependency [p], which [what] uses, is in the evidence here: the
   function or lambda being checked uses it, or a [With] around here
   installs it. *)
let available env loc what (p : Path.t) =
  if
    not
      (List.mem (Ty.label (Ty.dep_label p)) env.uses.labels
      || List.mem p env.installed)
  then
    fail env loc
      (sprintf
         "%s uses `%s`, which is neither used here, by `%s`, nor installed" what
         (Path.full p)
         (show (Fun ([], Ty.unit, Ty.closed, env.uses))))

(* The scope inside a function or lambda that takes the evidence [v] and
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
  | Fn (ps, r, e, u) ->
      Fun
        ( List.map
            (fun (mode, d) : Ty.param -> { mode; ty = described env sc loc d })
            ps,
          described env sc loc r,
          row e,
          u )
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

let rec expr env sc (e : expr) =
  let loc = e.loc in
  if has_error e.ty then fail env loc "a node has an error type";
  let is what t = same env loc what e.ty t in
  match e.kind with
  | Int _ -> is "an `Int`" Ty.int
  | Bool _ -> is "a `Bool`" Ty.bool
  | Str _ -> is "a `Str`" Ty.str
  | Unit -> is "`()`" Ty.unit
  | Local v ->
      in_scope env sc loc v;
      is ("`" ^ v.name ^ "`") v.ty
  | Global (p, a, ds) -> (
      descs env sc loc (Path.local p) a ds;
      match Hashtbl.find_opt env.schemes p with
      | Some s -> used env loc (Path.local p) s.ty a e.ty
      | None -> fail env loc (sprintf "there's no function `%s`" (Path.local p))
      )
  | Global_value (p, a) -> (
      match Hashtbl.find_opt env.values p with
      | Some s -> used env loc (Path.local p) s.ty a e.ty
      | None -> fail env loc (sprintf "there's no value `%s`" (Path.local p)))
  | Intrinsic (x, a, ds) ->
      descs env sc loc (Intrinsic.name x) a ds;
      used env loc (Intrinsic.name x) (Prelude.scheme x).ty a e.ty
  | Dep_call { dep = p; op; fty; ev; args } -> (
      (* the operation as declared, using its dependency, and whatever the
         caller does *)
      let declared =
        match (decl env loc p).body with
        | Dep ops -> List.find_opt (fun (o : Iface.field) -> o.fname = op) ops
        | _ -> None
      in
      let what = sprintf "`%s.%s`" p.name op in
      current env loc what ev;
      available env loc what p;
      match declared with
      | Some { fty = Fun (ps, r, errs, _); _ } -> (
          let uses : Ty.row =
            { labels = [ Ty.label (Ty.dep_label p) ]; tail = Some 0 }
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
  | With { ev; outer; dep = p; impl; body } ->
      (match Hashtbl.find_opt env.types p with
      | Some { Iface.body = Dep _; _ } -> ()
      | _ ->
          fail env loc
            (sprintf "`%s` is installed, but isn't a dependency" (Path.full p)));
      let what = sprintf "installing `%s`" p.name in
      current env loc what outer;
      is_evidence env loc what ev;
      expr env sc impl;
      (* what it needs, it needs here *)
      (match impl.ty with
      | Con (q, [ Uses needs ]) when q = p ->
          List.iter
            (fun (l : Ty.label) -> available env loc what (Ty.dep_path l.name))
            needs.labels
      | t ->
          fail env impl.loc
            (sprintf "what's installed has type `%s`, but should be a `%s`"
               (show t) (Path.full p)));
      expr { env with ev = Some ev; installed = p :: env.installed } sc body;
      is "a `With`" body.ty
  | Handler { ev; captures; body } -> (
      List.iter (in_scope env sc loc) captures;
      (* like a lambda's, its body sees only what it captures, and its own
         evidence: what's installed where it's installed *)
      let inner = List.fold_left (fun sc v -> add v sc) Scope.empty captures in
      match e.ty with
      | Con (p, [ Uses needs ]) ->
          (* its dependency's type, or the handler's own *)
          (match (decl env loc p).body with
          | Handler _ | Dep _ -> ()
          | _ ->
              fail env loc
                (sprintf "`%s` isn't a handler or a dependency" (Path.full p)));
          expr (inside env loc "a handler's evidence" ev needs) inner body;
          same env body.loc "a handler's body" body.ty e.ty
      | t -> fail env loc (sprintf "a handler has type `%s`" (show t)))
  | Instance impls -> (
      match e.ty with
      | Con (p, [ Uses needs ]) -> (
          (* a handler of one dependency has that dependency's type *)
          let deps =
            match (decl env loc p).body with
            | Handler deps -> Some deps
            | Dep _ -> Some [ p ]
            | _ -> None
          in
          match deps with
          | Some deps when deps = List.map fst impls ->
              List.iter
                (fun (d, (i : expr)) ->
                  expr env sc i;
                  same env i.loc
                    ("the implementation of `" ^ d.Path.name ^ "`")
                    i.ty
                    (Con (d, [ Uses needs ])))
                impls
          | _ ->
              fail env loc
                (sprintf "an instance doesn't implement what `%s` does"
                   (Path.full p)))
      | t -> fail env loc (sprintf "an instance has type `%s`" (show t)))
  | As_dep (d, h) -> (
      expr env sc h;
      match h.ty with
      | Con (p, [ Uses needs ]) -> (
          match (decl env loc p).body with
          | Handler deps when List.mem d deps ->
              is "a handler taken as one dependency's" (Con (d, [ Uses needs ]))
          | _ ->
              fail env loc
                (sprintf "`%s` isn't a handler of `%s`" (Path.full p)
                   (Path.full d)))
      | t ->
          fail env h.loc
            (sprintf "a handler taken as `%s` has type `%s`" (Path.full d)
               (show t)))
  | With_handler { ev; outer; handler; deps; body } ->
      let what = "installing a handler" in
      current env loc what outer;
      is_evidence env loc what ev;
      expr env sc handler;
      (* what it needs, it needs here *)
      (match handler.ty with
      | Con (p, [ Uses needs ]) -> (
          match (decl env loc p).body with
          | Handler ds when ds = deps ->
              List.iter
                (fun (l : Ty.label) ->
                  available env loc what (Ty.dep_path l.name))
                needs.labels
          | _ ->
              fail env loc
                (sprintf "`%s` doesn't implement what's installed" (Path.full p))
          )
      | t ->
          fail env handler.loc
            (sprintf "what's installed has type `%s`, but should be a handler"
               (show t)));
      expr { env with ev = Some ev; installed = deps @ env.installed } sc body;
      is "a `With`" body.ty
  | Prim (op, args) -> prim env sc e op args
  | Let (v, value, body) ->
      expr env sc value;
      same env loc ("the value of `" ^ v.name ^ "`") value.ty v.ty;
      expr env (add v sc) body;
      is "a `let`" body.ty
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
      expr env sc c;
      expr env sc body;
      same env loc "a `while` condition" c.ty Ty.bool;
      is "a `while`" Ty.unit
  | Seq (a, b) ->
      expr env sc a;
      expr env sc b;
      is "a sequence" b.ty
  | Call (f, args, ev) -> (
      expr env sc f;
      (* every function takes the same: the evidence where it's called *)
      let what =
        match f.kind with
        | Global (p, _, _) -> sprintf "a call of `%s`" (Path.local p)
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
              | Some { Iface.body = Dep _; _ } -> available env loc what p
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
          is "a call" ret
      | t -> fail env loc (sprintf "a call to a `%s`" (show t)))
  | Lambda { params; ev; captures; body } -> (
      List.iter (in_scope env sc loc) captures;
      (* the body sees only what it captures, its parameters, and its own
         evidence: a lambda never keeps the evidence where it's made, which
         isn't a local, so it can't be captured *)
      let inner =
        List.fold_left
          (fun sc (p : param) -> add p.var sc)
          (List.fold_left (fun sc v -> add v sc) Scope.empty captures)
          params
      in
      let uses =
        match reveal env e.ty with Fun (_, _, _, u) -> u | _ -> Ty.closed
      in
      expr (inside env loc "a lambda's evidence" ev uses) inner body;
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
      let td, targs = args_of env loc "a record" p e.ty in
      let declared =
        List.map (fun (d : Iface.field) -> d.fname) (fields_of env loc td)
      in
      if List.sort compare declared <> List.sort compare (List.map fst fields)
      then fail env loc "a record literal doesn't have its type's fields";
      List.iter
        (fun (f, (v : expr)) ->
          expr env sc v;
          let declared = field_ty env loc td targs f in
          (* an implementation's operation uses what it needs *)
          let expected : Ty.ty =
            match (targs, declared, td.body) with
            | [ Uses needs ], Fun (ps, r, errs, _), Dep _ ->
                Fun (ps, r, errs, needs)
            | _ -> declared
          in
          same env v.loc ("the field `" ^ f ^ "`") v.ty expected)
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
  | Tag (t, args) -> (
      List.iter (expr env sc) args;
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
  | Assert_equal (a, b, d) ->
      expr env sc a;
      expr env sc b;
      same env b.loc "the right side of an `Assert_equal`" b.ty a.ty;
      describes env sc loc "what an `Assert_equal` compares" d a.ty;
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
  match (op, args) with
  | Neg, [ a ] ->
      int a;
      is "`-`" Ty.int
  | Not, [ a ] ->
      same env a.loc "an operand" a.ty Ty.bool;
      is "`not`" Ty.bool
  | Binop (And | Or), _ ->
      fail env loc "`&&` or `||` that wasn't lowered to an `if`"
  | Binop Orelse, _ -> fail env loc "an `orelse` that wasn't lowered"
  | Binop (Eq | Neq), [ a; b ] ->
      same env loc "the right side of a comparison" b.ty a.ty;
      is "a comparison" Ty.bool
  | Binop (Add | Sub | Mul | Div | Mod), [ a; b ] ->
      int a;
      int b;
      is "arithmetic" Ty.int
  | Binop (Lt | Le | Gt | Ge), [ a; b ] ->
      int a;
      int b;
      is "a comparison" Ty.bool
  | Length, [ a ] ->
      ignore (elem a);
      is "a length" Ty.int
  | Get_index, [ a; i ] ->
      int i;
      is "an element" (elem a)
  | Set_index, [ a; i; v ] ->
      int i;
      same env v.loc "a new element" v.ty (elem a);
      is "an updated array" a.ty
  | New_cell, [ v ] -> is "a new cell" (cell_ty v.ty)
  | Get_cell, [ c ] -> is "what a cell holds" (held env c)
  | Set_cell, [ c; v ] ->
      same env v.loc "what's put in a cell" v.ty (held env c);
      is "changing a cell" Ty.unit
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

(* An installed handler instance is never a value (compiler.md, "No
   cycles"): an [Instance] is only ever the end of a [Handler]'s body,
   after the [Let]s and statements that make its state, which is where a
   [With] gets it from. Anywhere else, a program could hold one, and a
   handler's state could reach its own instance. *)
let rec instances env (e : expr) =
  match e.kind with
  | Handler { body; _ } -> handler_end env body
  | Instance _ ->
      fail env e.loc "an instance that isn't the end of a handler's body"
  | _ -> List.iter (instances env) (children e)

and handler_end env (e : expr) =
  match e.kind with
  | Let (_, a, b) | Seq (a, b) ->
      instances env a;
      handler_end env b
  | Instance impls -> List.iter (fun (_, i) -> instances env i) impls
  | _ -> fail env e.loc "a handler's body that doesn't end in an instance"

let fn_def env (f : fn_def) =
  let env = { env with fn = Path.local f.path; ntys = List.length f.tys } in
  instances env f.body;
  if f.tys <> type_params f.scheme then
    fail env f.loc
      "its hidden type parameters aren't one for each of its type variables";
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
          (List.fold_left (fun sc v -> add v sc) Scope.empty f.tys)
          f.params
      in
      expr env sc f.body;
      same env f.loc "the body" f.body.ty ret
  | t -> fail env f.loc (sprintf "a function has type `%s`" (show t))

(* The functions and values [e] names, in the order written. *)
let rec globals (e : expr) =
  match e.kind with
  | Global (p, _, _) | Global_value (p, _) -> [ p ]
  | Int _ | Bool _ | Str _ | Unit | Local _ | Intrinsic _ -> []
  | Prim (_, es)
  | Array es
  | Con (_, _, es)
  | Tag (_, es)
  | Dep_call { args = es; _ } ->
      List.concat_map globals es
  | With { impl; body; _ } -> globals impl @ globals body
  | With_handler { handler; body; _ } -> globals handler @ globals body
  | Instance impls -> List.concat_map (fun (_, i) -> globals i) impls
  | Handler { body; _ } -> globals body
  | Let (_, a, b)
  | While (a, b)
  | Seq (a, b)
  | Update (a, _, b)
  | Finally (a, b)
  | Assert_equal (a, b, _) ->
      globals a @ globals b
  | Assign (_, a)
  | Field (a, _, _)
  | Lambda { body = a; _ }
  | Fail a
  | As_dep (_, a)
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

(* Lint module [prog], which sees the interfaces [imports]: every one
   reachable through its imports, since a type from any of them can turn
   up in its code. [linked] are the program's modules, [prog] among them:
   `$start` installs the prelude's real implementations, which no
   interface has. The evidence a function is passed can hold an
   implementation of a dependency its module can't see, too (one declared
   in a module that imports it), so every module's dependencies are known
   here; their other types aren't, since another module's opaque type
   must stay opaque. *)
let program ~imports ~linked (prog : program) =
  let env =
    {
      types = Hashtbl.create 16;
      schemes = Hashtbl.create 16;
      values = Hashtbl.create 16;
      fn = "";
      ev = None;
      uses = Ty.closed;
      installed = [];
      ntys = 0;
    }
  in
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          Hashtbl.replace env.types td.path td;
          Path.Map.iter
            (fun p (o : Iface.op) ->
              Hashtbl.replace
                (if o.okind = Value then env.values else env.schemes)
                p o.oscheme)
            td.members)
        iface.types;
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.schemes (Path.make iface.home v.vname) v.scheme)
        iface.values)
    imports;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          match td.body with
          | Dep _ | Handler _ -> Hashtbl.replace env.types td.path td
          | Record _ | Sum _ | Builtin | Opaque _ | Errors _ -> ())
        m.types)
    linked;
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace env.types td.path td)
    prog.types;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (f : fn_def) ->
          (* an associated value's function has no parameters, and its
             result is the value, which is all the rest of the module sees
             of it *)
          match f.scheme with
          | { ty = Fun ([], t, _, _); _ } as s when List.mem f.path m.values ->
              Hashtbl.replace env.values f.path { s with ty = t }
          | _ -> Hashtbl.replace env.schemes f.path f.scheme)
        m.fns)
    (linked @ [ prog ]);
  value_order prog;
  shows env prog;
  List.iter (fn_def env) prog.fns
