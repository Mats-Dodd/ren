(* Interfaces: what one module tells the modules that use it.

   A module is checked against the interfaces of the modules it imports,
   never their source. Today the only import is the prelude, which every
   program gets without asking (driver.ml).

   An interface holds a module's types, with their constructors and fields,
   and the type scheme of each of its public functions, all in canonical
   form (ty.ml). It's made from the module's declarations alone
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

(* A public function's type scheme, from its signature alone. Its type
   parameters, parameters and result are all written; a public function
   without `->` returns Unit, and a parameter left without a type (an
   error, reported by inference) is [Error].

   A parameter whose type is written `fn(...)`, with no `..e` or `..d`, is
   transparent: what it fails with and uses flows into the function's own
   errors and dependencies, so its rows are the function's. Rows are open,
   as they are in every scheme, so a caller adds them to its own.

   [uses] are the dependencies the function uses. Ren has no way to write
   them in a signature yet, so they come from inference for now. *)
let signature ~uses (f : Ast.Resolved.fn_def) : Ty.scheme =
  (* row variables: 0 for the errors, 1 for the dependencies *)
  let errs : Ty.row = { labels = []; tail = Some 0 } in
  let deps : Ty.row = { labels = []; tail = Some 1 } in
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
      ty =
        Fun
          ( List.map param f.params,
            ret,
            errs,
            { labels = List.sort_uniq String.compare uses; tail = Some 1 } );
      names = List.mapi (fun i (t : Ast.ident) -> (i, t.name)) f.tparams;
    }

(* The interface of module [home], from its declarations alone, never its
   bodies (module-build.md, "Interface summaries"): every type it declares,
   and the signature of every public function. [uses] gives the
   dependencies of each public function, which can't be written yet. *)
let of_module ~home ~uses (prog : Ast.Resolved.program) =
  {
    home;
    types =
      List.filter_map
        (function Ast.Type td -> Some (of_type_def ~home td) | Fn _ -> None)
        prog;
    values =
      List.filter_map
        (function
          | Ast.Fn (f : Ast.Resolved.fn_def) when f.pub ->
              Some
                {
                  vname = f.name.name;
                  scheme = signature ~uses:(uses f.name.name) f;
                }
          | _ -> None)
        prog;
  }

(* Two interfaces of the same module as one: the prelude is part Ren
   source, part built into the compiler. *)
let union a b =
  { home = a.home; types = a.types @ b.types; values = a.values @ b.values }
