(* Interfaces: what one module tells the modules that use it.

   A module is checked against the interfaces of the modules it imports,
   never their source: the prelude, which every module gets without
   asking, and each module it imports (driver.ml).

   An interface holds a module's public types, with their constructors,
   fields and public members, and the type scheme of each of its
   public functions, all in
   canonical form (ty.ml). Nothing private is in it: a dependent can't
   tell a private name from one that doesn't exist, and changing one can't
   change the interface. It's made from the module's declarations
   ([of_module]), and from one thing inference found in its bodies: what
   each public function needs of its type parameters, which is never
   written. The one thing it holds that a cached interface shouldn't is
   where each type and constructor was declared, so an error can point at
   the declaration it clashes with; those move out when interfaces are
   cached (stage 13). *)

type field = { fname : string; fty : Ty.ty }

(* One of a named error set's errors, as it's declared: a tag, with its
   payload's types, or another named set, which stands for all of its own.
   Only the payload's types are the tag's: its fields' names document it. *)
type error = Tag of string * Ty.ty list | Set of Path.t
type ctor = { cname : string; cfields : field list; cloc : Loc.t }

type body =
  | Builtin  (** built into the compiler, like [Int] *)
  | Record of field list
  | Sum of ctor list
  | Opaque of opaque
      (** an opaque type, [type UserId = opaque Int]: what it's represented as
          ([Int]), which only its own module sees. That module's view of it has
          the representation; its interface hides it, so no other module can
          make one, look inside one or use one as an [Int]. *)
  | Errors of error list
      (** a named error set, [type Refusal = ! Short(by: Money) | Frozen], which
          is no type of values *)
  | Dep of field list
      (** a dependency, [dep Clock = ...]: its operations, each a function type
          that fails with exactly what it's written to fail with, and uses
          nothing. A value of it is an implementation, a record of them *)

(* An opaque type's representation, [Rep], in its own module's view of
   it, or in its interface, [Hidden]: all another module learns of it is
   whether it has `==`, which comparing two needs to know (operators.md,
   "Equality, hashing and `show`"). [eq] is false if what it's
   represented as has a function in it, whatever its type arguments.
   [Hidden of { eq : bool }] is an inline record: a constructor whose
   argument has named fields, matched as [Hidden { eq }]. *)
and opaque = Rep of Ty.ty | Hidden of { eq : bool }

(* A member of a type (ast.ml): a method, which has `self`,
   an associated function, which doesn't, or an associated value. *)
type op_kind = Method | Function | Value

type op = {
  oname : string;  (** as it's written: [push] *)
  onum : int;
      (** its place among its type's members, counting from 0 in source order,
          which messages list them in *)
  opub : bool;
  okind : op_kind;
  oscheme : Ty.scheme;
      (** a function's type scheme, `self` its first parameter if it's a method;
          a value's type. The type's parameters are its first variables' names.
      *)
}

type type_decl = {
  path : Path.t;
  params : string list;
      (** the type parameters' names; field types refer to the [i]th as [Var i]
      *)
  body : body;
  members : op Path.Map.t;
      (** its members, each by its path (path.ml): every item in its own
          module's view of it, only the public ones in its interface *)
  loc : Loc.t option;  (** where it's declared; [None] for a built-in *)
}

type value = { vname : string; scheme : Ty.scheme }

type t = {
  home : string;  (** the module this is the interface of *)
  types : type_decl list;  (** in the order they're declared *)
  values : value list;
}

let find_type iface name =
  List.find_opt (fun d -> d.path.name = name) iface.types

let find_value iface name = List.find_opt (fun v -> v.vname = name) iface.values

(* The member [name] of the type [d], if it has one. *)
let find_member d name = Path.Map.find_opt (Path.member d.path name) d.members

(* The members of [d], in source order. *)
let members d =
  List.sort
    (fun a b -> compare a.onum b.onum)
    (List.map snd (Path.Map.bindings d.members))

(* The members [ops] of the type at [path], each by its own path. *)
let members_of path ops =
  Path.Map.of_list (List.map (fun o -> (Path.member path o.oname, o)) ops)

(* ---- named error sets ---- *)

(* Where to find each named error set's errors, as it declares them, by its
   path: [None] if the path isn't a named set. A module sees its own sets
   and those of every module it can reach ([sets_of]). *)
type sets = Path.t -> error list option

let sets_of (decls : type_decl list) : sets =
 fun p ->
  List.find_map
    (fun d ->
      match d.body with Errors es when d.path = p -> Some es | _ -> None)
    decls

(* Every tag [errs] stand for, in order: a named set stands for all of its
   own, and the sets it includes for theirs. Each tag comes with the named
   set it came through, if any, which a message about it can name. A set is
   expanded once even if it's included twice, and never inside itself
   (resolve.ml reports a set that includes itself). *)
let tags ~sets (errs : error list) =
  let rec go seen via errs =
    List.concat_map
      (function
        | Tag (name, payload) -> [ ({ Ty.name; payload }, via) ]
        | Set p when List.mem p seen -> []
        | Set p -> (
            match sets p with
            | Some es -> go (p :: seen) (Some (Option.value via ~default:p)) es
            | None -> []))
      errs
  in
  go [] None errs

(* The labels of a row for [errs], sorted, each tag once. One with two
   shapes keeps the first; inference reports it (Infer_top). *)
let labels ~sets errs =
  let rec dedup seen = function
    | [] -> []
    | ((l : Ty.label), _) :: rest ->
        if List.mem l.name seen then dedup seen rest
        else l :: dedup (l.name :: seen) rest
  in
  Ty.sort_labels (dedup [] (tags ~sets errs))

(* ---- from a module's declarations ---- *)

(* A written type, once Resolve has said what its names mean, in canonical
   form. A function type written in a declaration uses and fails with
   exactly what it's written to, after `uses` and `!`, and so does an
   implementation, after `uses`: nothing, if nothing's written. [sets]
   says what each named set it names stands for, and [rows] which row
   variable each named row is, `..d`: only a signature names one
   (resolve.ml). *)
let rec of_written ?(rows = fun _ -> None) ~sets (t : Ast.Resolved.ty) : Ty.ty =
  let go = of_written ~rows ~sets in
  match t with
  | TyName ({ tref = Param i; _ }, _) -> Var i
  | TyName ({ tref = Named path; _ }, args) -> Con (path, List.map go args)
  | TyImpl (ds, u, _) -> Ty.impl (dep_paths ds) (written_uses ~rows u)
  | TyFn (ps, ret, errs, u, _) ->
      let ret = match ret with Some r -> go r | None -> Ty.unit in
      Fun
        ( List.map (of_written_param ~rows ~sets) ps,
          ret,
          written_errors ~rows ~sets errs,
          written_uses ~rows u,
          Ty.any_lams )
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false
  | TyErrors es -> Errors (written_errors ~rows ~sets (Some es))

and of_written_param ~rows ~sets = function
  | Ast.TyInout (t, _) -> { mode = Inout; ty = of_written ~rows ~sets t }
  | t -> Ty.read (of_written ~rows ~sets t)

(* The row a written `! ...` or `uses ...` is: its labels, and the named
   row at its end, if there is one. Nothing written is nothing. *)
and written_errors ~rows ~sets (es : Ast.Resolved.errors option) : Ty.row =
  match es with
  | Some es ->
      { labels = of_errors ~sets es; tail = Option.bind es.etail (named rows) }
  | None -> Ty.closed

and written_uses ~rows (u : Ast.Resolved.uses option) : Ty.row =
  match u with
  | Some u ->
      { labels = dep_labels u.deps; tail = Option.bind u.dtail (named rows) }
  | None -> Ty.closed

and named rows (n : Ast.ident) = rows n.name

(* The dependencies a `uses` lists, or that an implementation's type
   joins with `&`. *)
and dep_paths (ds : Ast.tname list) =
  List.filter_map
    (fun (d : Ast.tname) ->
      match d.tref with
      | Named p -> Some p
      | Param _ -> (* resolve.ml only makes a dependency a [Named] *) None)
    ds

(* The labels of the dependencies a `uses` lists, sorted. *)
and dep_labels (ds : Ast.tname list) =
  List.map Ty.label
    (List.sort_uniq String.compare (List.map Ty.dep_label (dep_paths ds)))

(* An error set as written, as declared errors: each tag with its
   payload's types, its fields' names dropped. *)
and declared_errors ~sets (es : Ast.Resolved.errors) =
  List.map
    (function
      | Ast.Tag (t, ps) ->
          Tag
            ( t.name,
              List.map
                (fun (p : Ast.tname Ast.payload) ->
                  of_written ~sets p.payload_ty)
                ps )
      | Set { Ast.tref = Named p; _ } -> Set p
      | Set { tref = Param _; _ } ->
          (* resolve.ml only makes a declared set a [Set] *)
          assert false)
    es.errs

(* The same, as a row's labels: named sets expanded. *)
and of_errors ~sets es = labels ~sets (declared_errors ~sets es)

(* A public function's type scheme, from its signature alone. Its type
   parameters, parameters and result are all written; a public function
   without `->` returns Unit, and a parameter left without a type (an
   error, reported by inference) is [Error].

   A parameter whose type is written `fn(...)`, with no `..e` or `..d`, is
   transparent: what it fails with and uses flows into the function's own
   errors and dependencies, so its rows are the function's: the same row,
   labels and all, which is what inference finds too. So is one whose type
   is a dependency's, `c: Clock`, which is installed: what it needs is
   what the function uses. Rows are open, as they are in every scheme, so
   a caller adds them to its own. Any other function type in the
   signature, like the `fn()` in `f: Option<fn()>`, uses and fails with
   nothing, as in a declaration, and so does one that names a row, `f:
   fn() uses ..d`, but for that row, which is the same wherever the
   signature names it (deps.md, "Implementations"). Inference reads a
   signature the same way (Infer_expr.param_type), and the driver checks
   that the two agree.

   Its dependencies are the ones its `uses` lists, none if it has no
   `uses`, and its errors the ones written after `!`, none if there's no
   `!`, with every named set expanded; inference checks that its body
   uses and fails with exactly those. A parameter that writes what it
   fails with, `f: fn() ! Bad`, fails with just that, so its errors aren't
   the function's own (its dependencies still are), and one that writes
   what it uses, `f: fn() uses Clock`, uses just that. The function's own
   `! ..e` or `uses ..d` names its own row. *)
let signature ~sets (f : Ast.Resolved.fn_def) : Ty.scheme =
  (* row variables: 0 for the errors, 1 for the dependencies, unless the
     signature names them, and after those each named row, the same
     wherever it's named *)
  let own (n : Ast.ident option) number =
    Option.map (fun (n : Ast.ident) -> (n.name, number)) n
  in
  let named =
    ref
      (Option.to_list
         (own
            (Option.bind f.errors (fun (es : Ast.Resolved.errors) -> es.etail))
            0)
      @ Option.to_list
          (own (Option.bind f.uses (fun (u : Ast.Resolved.uses) -> u.dtail)) 1)
      )
  in
  let rows name =
    match List.assoc_opt name !named with
    | Some n -> Some n
    | None ->
        let n = 2 + List.length !named in
        named := !named @ [ (name, n) ];
        Some n
  in
  let errs : Ty.row =
    {
      labels =
        (match f.errors with Some es -> of_errors ~sets es | None -> []);
      tail = Some 0;
    }
  in
  let deps : Ty.row =
    {
      labels =
        (match f.uses with
        | Some (u : Ast.Resolved.uses) -> dep_labels u.deps
        | None -> []);
      tail = Some 1;
    }
  in
  let param (p : Ast.Resolved.param) : Ty.param =
    let ty : Ty.ty =
      match p.pty with
      | Some (TyFn (_, _, written_e, written_u, _) as t)
        when not (Ast.names_row t) -> (
          match of_written ~rows ~sets t with
          | Fun (ps, r, e, u, l) ->
              Fun
                ( ps,
                  r,
                  (if written_e = None then errs else e),
                  (if written_u = None then deps else u),
                  l )
          | _ -> assert false)
      | Some (TyImpl (ds, None, _)) -> Ty.impl (dep_paths ds) deps
      | Some t -> of_written ~rows ~sets t
      | None -> Error
    in
    { mode = p.pmode; ty }
  in
  let ps = List.map param f.params in
  let ret =
    match f.ret with Some t -> of_written ~rows ~sets t | None -> Ty.unit
  in
  Ty.canonical
    {
      ty = Fun (ps, ret, errs, deps, Ty.any_lams);
      names = List.mapi (fun i (t : Ast.ident) -> (i, t.name)) f.tparams;
      reqs = [];
      row_reqs = [];
    }

(* A type declared in module [home]. *)
let of_type_def ~home ~sets (td : Ast.Resolved.type_def) =
  let field (f : Ast.Resolved.field) =
    { fname = f.field_name.name; fty = of_written ~sets f.field_ty }
  in
  let body =
    match td.type_body with
    | Fields fs -> Record (List.map field fs)
    | Ctors cs ->
        Sum
          (List.map
             (fun (c : Ast.tname Ast.ctor) ->
               {
                 cname = c.ctor_name.name;
                 cfields = List.map field c.ctor_fields;
                 cloc = c.ctor_name.loc;
               })
             cs)
    | Opaque t -> Opaque (Rep (of_written ~sets t))
    | Errors es -> Errors (declared_errors ~sets es)
    | Dep ops -> Dep (List.map field ops)
  in
  let op onum (o : Ast.Resolved.op) =
    let f = o.op_fn in
    let okind, oscheme =
      match (o.op_kind, f.params) with
      | Op_value, _ when f.ret = None ->
          (* a public one without a type is an error, which inference
             reports with the type it finds *)
          (Value, { Ty.ty = Error; names = []; reqs = []; row_reqs = [] })
      | Op_value, _ -> (
          (* a function of no parameters, whose result is the value *)
          match signature ~sets f with
          | { ty = Fun ([], t, _, _, _); _ } as s ->
              (Value, Ty.canonical { s with ty = t })
          | _ -> assert false)
      | Op_fn, p :: _ when p.pname.ident.name = "self" ->
          (Method, signature ~sets f)
      | Op_fn, _ -> (Function, signature ~sets f)
    in
    { oname = f.name.name; onum; opub = f.pub; okind; oscheme }
  in
  let path = Path.make home td.type_name.name in
  {
    path;
    params = List.map (fun (p : Ast.ident) -> p.name) td.type_params;
    body;
    members = members_of path (List.mapi op td.type_ops);
    loc = Some td.type_name.loc;
  }

(* The dependencies the handler [f] implements, if it's a `handler`
   (ast.ml): calling it describes an implementation of each, sharing one
   state, of their type, `Rates` for one, `Rates & RateCalls` for several
   (deps.md, "Implementations"). *)
let handler_deps (f : Ast.Resolved.fn_def) =
  match f.body.kind with
  | Handler { deps; _ } -> Some (dep_paths deps)
  | _ -> None

(* The interface of module [home] (module-build.md, "Interface
   summaries"): every public type it declares, with its public members,
   and the signature of every public function. A public one never
   mentions a private one (resolve.ml checks), so a dependent never meets
   a type that isn't in some interface. An opaque type is listed without
   its representation. [sets] are the named error sets it can see.

   All of it comes from declarations but what a public function or member
   needs of its type parameters, which isn't written (operators.md,
   "Generic code"): [needs] gives what inference found, by the function's
   path, as its scheme's [reqs] and [row_reqs]. And whether an opaque type
   has `==` depends on what it's represented as, which the interface
   hides, so [has_eq] says, by the type's path, as inference found it. *)
let of_module ~home ~sets ~needs ~has_eq (prog : Ast.Resolved.program) =
  (* [canonical] keeps a scheme's numbering, and drops what it needs of a
     variable its type hasn't: an associated value's type is its
     function's result, without the rows *)
  let needed path (s : Ty.scheme) =
    match s.ty with
    | Error -> s
    | _ ->
        let reqs, row_reqs = needs path in
        Ty.canonical { s with reqs; row_reqs }
  in
  let public (td : type_decl) =
    let td =
      {
        td with
        members =
          Path.Map.filter_map
            (fun path o ->
              if o.opub then Some { o with oscheme = needed path o.oscheme }
              else None)
            td.members;
      }
    in
    match td.body with
    | Opaque _ -> { td with body = Opaque (Hidden { eq = has_eq td.path }) }
    | _ -> td
  in
  {
    home;
    types =
      List.filter_map
        (function
          | Ast.Type td when td.type_pub ->
              Some (public (of_type_def ~home ~sets td))
          | Type _ | Fn _ | Import _ | Testing _ -> None)
        prog;
    values =
      List.filter_map
        (function
          | Ast.Fn (f : Ast.Resolved.fn_def) when f.pub ->
              let scheme = signature ~sets f in
              Some
                {
                  vname = f.name.name;
                  scheme = needed (Path.make home f.name.name) scheme;
                }
          | _ -> None)
        prog;
  }

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
let union a b =
  { home = a.home; types = a.types @ b.types; values = a.values @ b.values }
