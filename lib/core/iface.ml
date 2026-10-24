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

(* A written type, in canonical form. [params] are the type parameters in
   scope, in order. [resolve] finds the type a name refers to; a name it
   doesn't know has already been reported (check.ml), so it becomes
   [Error]. A function type written in a declaration uses and fails with
   nothing. *)
let rec of_ast ~params ~resolve (t : Ast.ty) : Ty.ty =
  match t with
  | TyName (id, []) when List.mem id.name params ->
      let rec index i = function
        | p :: rest -> if p = id.name then i else index (i + 1) rest
        | [] -> assert false
      in
      Var (index 0 params)
  | TyName (id, args) -> (
      match resolve id.name with
      | Some path -> Con (path, List.map (of_ast ~params ~resolve) args)
      | None -> Error)
  | TyFn (ps, ret, _) ->
      let ret =
        match ret with Some r -> of_ast ~params ~resolve r | None -> Ty.unit
      in
      Fun
        (List.map (of_ast_param ~params ~resolve) ps, ret, Ty.closed, Ty.closed)
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false

and of_ast_param ~params ~resolve = function
  | Ast.TyInout (t, _) -> { mode = Inout; ty = of_ast ~params ~resolve t }
  | t -> Ty.read (of_ast ~params ~resolve t)

let of_type_def ~home ~resolve (td : Ast.type_def) =
  let params = List.map (fun (p : Ast.ident) -> p.name) td.type_params in
  let field (f : Ast.field) =
    { fname = f.field_name.name; fty = of_ast ~params ~resolve f.field_ty }
  in
  let body =
    match td.type_body with
    | Fields fs -> Record (List.map field fs)
    | Ctors cs ->
        Sum
          (List.map
             (fun (c : Ast.ctor) ->
               {
                 cname = c.ctor_name.name;
                 cfields = List.map field c.ctor_fields;
                 cloc = c.ctor_name.loc;
               })
             cs)
  in
  {
    path = Path.make home td.type_name.name;
    params;
    body;
    loc = Some td.type_name.loc;
  }

(* The types module [home] declares, in the order it declares them. A name
   declared twice is an error check.ml reports; here the first declaration
   wins wherever the name is used. *)
let own_types ~home ~imports (prog : Ast.program) =
  let own =
    List.filter_map (function Ast.Type td -> Some td | Fn _ -> None) prog
  in
  let resolve name =
    if List.exists (fun (td : Ast.type_def) -> td.type_name.name = name) own
    then Some (Path.make home name)
    else
      List.find_map
        (fun iface -> Option.map (fun d -> d.path) (find_type iface name))
        imports
  in
  List.map (of_type_def ~home ~resolve) own

(* Every type module [home] can see: its imports' types, then its own. *)
let visible_types ~home ~imports prog =
  List.concat_map (fun iface -> iface.types) imports
  @ own_types ~home ~imports prog

(* The interface of module [home], from its declarations and the type
   scheme inference gave each function. *)
let of_module ~home ~imports (prog : Ast.program) ~schemes =
  {
    home;
    types = own_types ~home ~imports prog;
    values = List.map (fun (vname, scheme) -> { vname; scheme }) schemes;
  }

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
let union a b =
  { home = a.home; types = a.types @ b.types; values = a.values @ b.values }
