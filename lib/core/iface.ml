(* Interfaces: what one module tells the modules that use it.

   A module is checked against the interfaces of the modules it imports,
   never their source: the prelude, which every module gets without
   asking, and each module it imports (driver.ml).

   An interface holds a module's public types, with their constructors,
   fields and public members, and the type scheme of each of its
   public functions, all in
   canonical form (ty.ml). Nothing private is in it: a dependent can't
   tell a private name from one that doesn't exist, and changing one can't
   change the interface. It's made from the module's declarations alone
   ([of_module]), never from its bodies. The one thing it holds that a cached interface shouldn't is
   where each type and constructor was declared, so an error can point at
   the declaration it clashes with; those move out when interfaces are
   cached (stage 10). *)

type field = { fname : string; fty : Ty.ty }
type ctor = { cname : string; cfields : field list; cloc : Loc.t }

type body =
  | Builtin  (** built into the compiler, like [Int] *)
  | Record of field list
  | Sum of ctor list
  | Opaque of Ty.ty option
      (** an opaque type, [type UserId = opaque Int]: what it's represented as
          ([Int]), which only its own module sees. That module's view of it has
          [Some] representation; its interface has [None], so no other module
          can make one, look inside one or use one as an [Int]. *)

(* A member of a type (ast.ml): a method, which has `self`,
   an associated function, which doesn't, or an associated value. *)
type op_kind = Method | Function | Value

type op = {
  oname : string;  (** as it's written: [push] *)
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
  members : op list;
      (** its members, in source order: every item in its own module's view of
          it, only the public ones in its interface *)
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

(* ---- from a module's declarations ---- *)

(* A written type, once Resolve has said what its names mean, in canonical
   form. A function type written in a declaration uses and fails with
   nothing. *)
let rec of_written (t : Ast.Resolved.ty) : Ty.ty =
  match t with
  | TyName ({ tref = Param i; _ }, _) -> Var i
  | TyName ({ tref = Named path; _ }, args) ->
      Con (path, List.map of_written args)
  | TyFn (ps, ret, _) ->
      let ret = match ret with Some r -> of_written r | None -> Ty.unit in
      Fun (List.map of_written_param ps, ret, Ty.closed, Ty.closed)
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false

and of_written_param = function
  | Ast.TyInout (t, _) -> { mode = Inout; ty = of_written t }
  | t -> Ty.read (of_written t)

(* A public function's type scheme, from its signature alone. Its type
   parameters, parameters and result are all written; a public function
   without `->` returns Unit, and a parameter left without a type (an
   error, reported by inference) is [Error].

   A parameter whose type is written `fn(...)`, with no `..e` or `..d`, is
   transparent: what it fails with and uses flows into the function's own
   errors and dependencies, so its rows are the function's: the same row,
   labels and all, which is what inference finds too. Rows are open,
   as they are in every scheme, so a caller adds them to its own. Any other
   function type in the signature, like the `fn()` in `f: Option<fn()>`,
   uses and fails with nothing, as in a declaration. Inference reads a
   signature the same way (Infer_expr.param_type), and the driver checks
   that the two agree.

   Its dependencies are the ones its `uses` lists, none if it has no
   `uses`; inference checks that its body uses nothing else. *)
let signature (f : Ast.Resolved.fn_def) : Ty.scheme =
  (* row variables: 0 for the errors, 1 for the dependencies *)
  let errs : Ty.row = { labels = []; tail = Some 0 } in
  let uses =
    List.map (fun (d : Ast.ident) -> d.name) (Option.value f.uses ~default:[])
  in
  let deps : Ty.row =
    { labels = List.sort_uniq String.compare uses; tail = Some 1 }
  in
  let param (p : Ast.Resolved.param) : Ty.param =
    let ty : Ty.ty =
      match p.pty with
      | Some (TyFn _ as t) -> (
          match of_written t with
          | Fun (ps, r, _, _) -> Fun (ps, r, errs, deps)
          | _ -> assert false)
      | Some t -> of_written t
      | None -> Error
    in
    { mode = p.pmode; ty }
  in
  let ret = match f.ret with Some t -> of_written t | None -> Ty.unit in
  Ty.canonical
    {
      ty = Fun (List.map param f.params, ret, errs, deps);
      names = List.mapi (fun i (t : Ast.ident) -> (i, t.name)) f.tparams;
    }

(* A type declared in module [home]. *)
let of_type_def ~home (td : Ast.Resolved.type_def) =
  let field (f : Ast.Resolved.field) =
    { fname = f.field_name.name; fty = of_written f.field_ty }
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
    | Opaque t -> Opaque (Some (of_written t))
  in
  let op (o : Ast.Resolved.op) =
    let f = o.op_fn in
    let okind, oscheme =
      match (o.op_kind, f.params) with
      | Op_value, _ when f.ret = None ->
          (* a public one without a type is an error, which inference
             reports with the type it finds *)
          (Value, { Ty.ty = Error; names = [] })
      | Op_value, _ -> (
          (* a function of no parameters, whose result is the value *)
          match signature f with
          | { ty = Fun ([], t, _, _); names } ->
              (Value, Ty.canonical { ty = t; names })
          | _ -> assert false)
      | Op_fn, p :: _ when p.pname.ident.name = "self" -> (Method, signature f)
      | Op_fn, _ -> (Function, signature f)
    in
    { oname = Ast.short_name f.name.name; opub = f.pub; okind; oscheme }
  in
  {
    path = Path.make home td.type_name.name;
    params = List.map (fun (p : Ast.ident) -> p.name) td.type_params;
    body;
    members = List.map op td.type_ops;
    loc = Some td.type_name.loc;
  }

(* The interface of module [home], from its declarations alone, never its
   bodies (module-build.md, "Interface summaries"): every public type it
   declares, with its public members, and the signature of every
   public function. A public one
   never mentions a private one (resolve.ml checks), so a dependent never
   meets a type that isn't in some interface. An opaque type is listed
   without its representation. *)
let of_module ~home (prog : Ast.Resolved.program) =
  let public (td : type_decl) =
    let td = { td with members = List.filter (fun o -> o.opub) td.members } in
    match td.body with Opaque _ -> { td with body = Opaque None } | _ -> td
  in
  {
    home;
    types =
      List.filter_map
        (function
          | Ast.Type td when td.type_pub -> Some (public (of_type_def ~home td))
          | Type _ | Fn _ | Import _ -> None)
        prog;
    values =
      List.filter_map
        (function
          | Ast.Fn (f : Ast.Resolved.fn_def) when f.pub ->
              Some { vname = f.name.name; scheme = signature f }
          | _ -> None)
        prog;
  }

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
let union a b =
  { home = a.home; types = a.types @ b.types; values = a.values @ b.values }
