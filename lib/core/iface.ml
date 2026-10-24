(* Interfaces: what one module tells the modules that use it.

   A module is checked against the interfaces of the modules it imports,
   never their source. Today the only import is the prelude, which every
   program gets without asking (driver.ml).

   An interface holds a module's types, with their constructors and fields,
   and the type scheme of each of its functions, all in canonical form
   (ty.ml). The one thing it holds that a cached interface shouldn't is
   where each type and constructor was declared, so an error can point at
   the declaration it clashes with; those move out when interfaces are
   cached (stage 10). *)

type field = { fname : string; fty : Ty.ty }
type ctor = { cname : string; cfields : field list; cloc : Loc.t }

type body =
  | Builtin  (** built into the compiler, like [Int] *)
  | Record of field list
  | Sum of ctor list

type type_decl = {
  path : Path.t;
  params : string list;
      (** the type parameters' names; field types refer to the [i]th as [Var i]
      *)
  body : body;
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
  in
  {
    path = Path.make home td.type_name.name;
    params = List.map (fun (p : Ast.ident) -> p.name) td.type_params;
    body;
    loc = Some td.type_name.loc;
  }

(* The interface of module [home], from the types it declares and the type
   scheme inference gave each of its functions. *)
let make ~home ~types ~schemes =
  {
    home;
    types;
    values = List.map (fun (vname, scheme) -> { vname; scheme }) schemes;
  }

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
let union a b =
  { home = a.home; types = a.types @ b.types; values = a.values @ b.values }
