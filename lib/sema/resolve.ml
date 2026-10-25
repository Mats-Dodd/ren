(* Name resolution: the pass that finds everything found through scope
   (module-build.md, "In the compiler"). It runs right after parsing, and
   turns the parser's tree, where a name is the string that was written,
   into the resolved tree (ast.ml), where it says what it refers to:

   - a variable or function used as a value is a local (a [binder], shared
     by every use of it), a top-level function (a [Path.t]), or a function
     built into the compiler. A function of another module is written with
     that module's alias in front, `util.double`, and only its public
     functions can be: Resolve sees the module's interface, not its source.
     The prelude's functions, and the module's own, are written bare.
   - a type's name is a declared type (a [Path.t]), or one of the type
     parameters in scope

   Along the way it reports every name that doesn't exist, types given the
   wrong number of arguments, and names declared twice. Later passes never
   look a name up: inference reads a binder's id, mut.ml its kind.

   Constructors and record fields aren't found here: they're found through
   a type (infer_expr.ml). For now, though, no two types can have a
   constructor with the same name, and that's checked here.

   Each problem is reported to the sink (diag.ml), and resolution carries
   on: a name that doesn't exist resolves to something harmless, since the
   driver stops after this pass if it reported anything. *)

open Ast
module Env = Map.Make (String)

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"

type t = {
  home : string;
  prog : Resolved.program;
  types : Iface.type_decl list;
      (** the types the module declares, in the order it declares them *)
  calls : (string * Path.t list) list;
      (** each function, and the top-level functions its body uses *)
}

type env = {
  sink : Diag.sink;
  home : string;
  types : (string, Path.t * int) Hashtbl.t;
      (** every type in scope, with how many type arguments it takes *)
  values : (string, name) Hashtbl.t;  (** every top-level function in scope *)
  modules : Iface.t Env.t;  (** each imported module, by its alias *)
}

(* What one expression can see. [fn] is shared by the whole top-level
   function: a record with [mutable] fields is the same record in every
   copy of the [scope] that holds it. *)
type scope = {
  locals : binder Env.t;
  tparams : string list;  (** the type parameters in scope, in order *)
  depth : int;  (** how many lambdas deep *)
  fn : fn_state;
}

and fn_state = {
  mutable last_id : int;  (** the last binder id handed out *)
  mutable calls : Path.t list;
}

let report env ?help ?labels loc msg =
  Diag.report env.sink (Diag.make ?help ?labels loc msg)

let no_duplicates env what (ids : ident list) =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (id : ident) ->
      match Hashtbl.find_opt seen id.name with
      | Some first ->
          report env id.loc ~help:"rename one of them"
            ~labels:[ (first, sprintf "the first `%s` is here" id.name) ]
            (sprintf "there are two %s named `%s`" what id.name)
      | None -> Hashtbl.replace seen id.name id.loc)
    ids

let bind sc (id : ident) bound =
  sc.fn.last_id <- sc.fn.last_id + 1;
  let b = { id = sc.fn.last_id; ident = id; bound; depth = sc.depth } in
  (b, { sc with locals = Env.add id.name b sc.locals })

(* ---- types ---- *)

let rec index_of x i = function
  | y :: rest -> if x = y then Some i else index_of x (i + 1) rest
  | [] -> None

(* A written type, with its names resolved. [params] are the type
   parameters in scope, like the `T` in `Option<T>`. A type with an error
   is reported once, and its arguments aren't looked at. *)
let rec ty env ~params (t : Parsed.ty) : Resolved.ty =
  match t with
  | TyFn (ps, ret, l) ->
      TyFn (List.map (ty env ~params) ps, Option.map (ty env ~params) ret, l)
  | TyInout (t, l) -> TyInout (ty env ~params t, l)
  | TyName (id, args) -> (
      let named tref = { tref; tloc = id.loc } in
      let given = List.length args in
      let found =
        match index_of id.name 0 params with
        | Some i -> Some (Param i, 0)
        | None ->
            Option.map
              (fun (p, n) -> (Named p, n))
              (Hashtbl.find_opt env.types id.name)
      in
      match found with
      | None ->
          report env id.loc (sprintf "there's no type named `%s`" id.name);
          TyName (named (Named (Path.make env.home id.name)), [])
      | Some (tref, n) when n <> given ->
          report env id.loc
            (sprintf "`%s` takes %d type argument%s but was given %d" id.name n
               (plural n) given);
          TyName (named tref, [])
      | Some (tref, _) -> TyName (named tref, List.map (ty env ~params) args))

let ty_opt env ~params = Option.map (ty env ~params)

let param env sc bound (p : Parsed.param) : Resolved.param * scope =
  let pty = ty_opt env ~params:sc.tparams p.pty in
  let b, sc = bind sc p.pname bound in
  ({ pname = b; pty; pmode = p.pmode }, sc)

let params env sc bound ps =
  let ps, sc =
    List.fold_left
      (fun (acc, sc) (p : Parsed.param) ->
        let p, sc = param env sc (bound p) p in
        (p :: acc, sc))
      ([], sc) ps
  in
  (List.rev ps, sc)

(* ---- expressions ---- *)

(* The public function [f] of the imported module [iface], written
   `alias.f`. A private function isn't in the interface, so it can't be
   told apart from one that doesn't exist. *)
let qualified env sc (iface : Iface.t) (f : ident) =
  let p = Path.make iface.home f.name in
  if Iface.find_value iface f.name = None then
    report env f.loc ~help:"if it's defined there, mark it `pub`"
      (sprintf "`%s` has no public `%s`" iface.home f.name)
  else sc.fn.calls <- p :: sc.fn.calls;
  Global p

(* What the name [x] refers to. [what] words the error when it's nothing:
   "variable", or "function" for the name being called. *)
let lookup env sc loc ~what x =
  match Env.find_opt x sc.locals with
  | Some b -> Local b
  | None -> (
      match Hashtbl.find_opt env.values x with
      | Some (Global p as name) ->
          sc.fn.calls <- p :: sc.fn.calls;
          name
      | Some name -> name
      | None ->
          report env loc (sprintf "there's no %s named `%s`" what x);
          Global (Path.make env.home x))

(* The variables a pattern binds, left to right, so that `P(x, x)` can be
   reported: otherwise the second `x` would quietly hide the first. *)
let rec pattern_vars (p : Parsed.pattern) =
  match p.pkind with
  | PWild | PInt _ | PBool _ -> []
  | PVar x -> [ x ]
  | PCon (_, ps) -> List.concat_map pattern_vars ps

let rec pattern sc (p : Parsed.pattern) : Resolved.pattern * scope =
  let kind, sc =
    match p.pkind with
    | PWild -> (PWild, sc)
    | PInt n -> (PInt n, sc)
    | PBool b -> (PBool b, sc)
    | PVar x ->
        let b, sc = bind sc x By_pattern in
        (PVar b, sc)
    | PCon (c, ps) ->
        let ps, sc =
          List.fold_left
            (fun (acc, sc) p ->
              let p, sc = pattern sc p in
              (p :: acc, sc))
            ([], sc) ps
        in
        (PCon (c, List.rev ps), sc)
  in
  ({ pkind = kind; ploc = p.ploc; pnode = p.pnode }, sc)

let rec expr env sc (e : Parsed.expr) : Resolved.expr =
  let go = expr env sc in
  let kind : Resolved.expr_kind =
    match e.kind with
    | Int n -> Int n
    | Bool b -> Bool b
    | Unit -> Unit
    | Var x -> Var (lookup env sc e.loc ~what:"variable" x)
    | Unop (op, a) -> Unop (op, go a)
    | Binop (op, a, b) ->
        let a = go a in
        Binop (op, a, go b)
    | If (c, t, f) ->
        let c = go c in
        let t = go t in
        If (c, t, Option.map go f)
    | Call (f, args) ->
        let f =
          match f.kind with
          | Var x ->
              {
                kind = Var (lookup env sc f.loc ~what:"function" x);
                loc = f.loc;
                node = f.node;
              }
          | _ -> go f
        in
        Call (f, List.map go args)
    | Lambda (ps, body) ->
        no_duplicates env "parameters"
          (List.map (fun (p : Parsed.param) -> p.pname) ps);
        let ps, inner =
          (* an `inout` lambda parameter is an error (mut.ml), but binding it
             as one keeps its uses from being reported a second time *)
          params env
            { sc with depth = sc.depth + 1 }
            (fun (p : Parsed.param) ->
              if p.pmode = Inout then By_inout else By_lambda)
            ps
        in
        Lambda (ps, expr env inner body)
    | Block (stmts, last) ->
        let stmts, sc =
          List.fold_left
            (fun (acc, sc) (s : Parsed.stmt) ->
              match s with
              | Let { name; ty = t; value; mut } ->
                  let value = expr env sc value in
                  let t = ty_opt env ~params:sc.tparams t in
                  let b, sc = bind sc name (if mut then By_var else By_let) in
                  (Let { name = b; ty = t; value; mut } :: acc, sc)
              | Expr e -> (Expr (expr env sc e) :: acc, sc))
            ([], sc) stmts
        in
        Block (List.rev stmts, expr env sc last)
    | Con (c, args) -> Con (c, List.map (fun (l, a) -> (l, go a)) args)
    | Record (name, fields) ->
        let name =
          Option.map
            (fun (tn : ident) ->
              match Hashtbl.find_opt env.types tn.name with
              | Some (p, _) -> { tref = Named p; tloc = tn.loc }
              | None ->
                  report env tn.loc
                    (sprintf "there's no type named `%s`" tn.name);
                  { tref = Named (Path.make env.home tn.name); tloc = tn.loc })
            name
        in
        Record (name, List.map (fun (f, v) -> (f, go v)) fields)
    | Field ({ kind = Var m; _ }, f) when Env.mem m env.modules ->
        Var (qualified env sc (Env.find m env.modules) f)
    | Field (r, f) -> Field (go r, f)
    | Match (subject, arms) ->
        let subject = go subject in
        Match
          ( subject,
            List.map
              (fun (a : Parsed.arm) : Resolved.arm ->
                no_duplicates env "pattern variables" (pattern_vars a.arm_pat);
                let arm_pat, sc = pattern sc a.arm_pat in
                let arm_guard = Option.map (expr env sc) a.arm_guard in
                { arm_pat; arm_guard; arm_body = expr env sc a.arm_body })
              arms )
    | Array xs -> Array (List.map go xs)
    | Index (a, i) ->
        let a = go a in
        Index (a, go i)
    | Ref a -> Ref (go a)
    | Assign { target; op; value } ->
        let target = go target in
        Assign { target; op; value = go value }
    | For { var; iter; body } ->
        let bound =
          match iter.kind with Ref _ -> By_ref_loop | _ -> By_loop
        in
        let iter = go iter in
        let b, inner = bind sc var bound in
        For { var = b; iter; body = expr env inner body }
  in
  { kind; loc = e.loc; node = e.node }

(* ---- declarations ---- *)

let type_def env (td : Parsed.type_def) : Resolved.type_def =
  no_duplicates env "type parameters" td.type_params;
  let no_duplicate_fields (fs : Parsed.field list) =
    no_duplicates env "fields"
      (List.map (fun (f : Parsed.field) -> f.field_name) fs)
  in
  (match td.type_body with
  | Fields fs -> no_duplicate_fields fs
  | Ctors cs ->
      List.iter (fun (c : ident ctor) -> no_duplicate_fields c.ctor_fields) cs);
  let params = List.map (fun (p : ident) -> p.name) td.type_params in
  let field (f : Parsed.field) : Resolved.field =
    { field_name = f.field_name; field_ty = ty env ~params f.field_ty }
  in
  let type_body : tname type_body =
    match td.type_body with
    | Fields fs -> Fields (List.map field fs)
    | Ctors cs ->
        Ctors
          (List.map
             (fun (c : ident ctor) : tname ctor ->
               {
                 ctor_name = c.ctor_name;
                 ctor_fields = List.map field c.ctor_fields;
               })
             cs)
  in
  { td with type_body }

let fn_def env (f : Parsed.fn_def) : Resolved.fn_def * Path.t list =
  no_duplicates env "type parameters" f.tparams;
  List.iter
    (fun (t : ident) ->
      if Hashtbl.mem env.types t.name then
        report env t.loc ~help:"choose another name"
          (sprintf "`%s` is already the name of a type" t.name))
    f.tparams;
  no_duplicates env "parameters"
    (List.map (fun (p : Parsed.param) -> p.pname) f.params);
  let sc =
    {
      locals = Env.empty;
      tparams = List.map (fun (t : ident) -> t.name) f.tparams;
      depth = 0;
      fn = { last_id = 0; calls = [] };
    }
  in
  let ps, inner =
    params env sc
      (fun p -> match p.pmode with Inout -> By_inout | Read -> By_param)
      f.params
  in
  let ret = ty_opt env ~params:sc.tparams f.ret in
  let body = expr env inner f.body in
  ({ f with params = ps; ret; body }, List.sort_uniq compare sc.fn.calls)

(* ---- what a public declaration can mention ----

   A public function's signature and a public type's fields are part of
   the module's interface, and the interface holds no private types
   (iface.ml). A dependent can't do anything with a type it can't see, so
   neither can mention one. [private_] holds the module's private types,
   by name, with where each is declared. *)

(* Every type named in [t], with where it's named, left to right. *)
let rec named_in (t : Resolved.ty) =
  match t with
  | TyName ({ tref = Named p; tloc }, args) ->
      (p, tloc) :: List.concat_map named_in args
  | TyName ({ tref = Param _; _ }, args) -> List.concat_map named_in args
  | TyFn (ps, ret, _) ->
      List.concat_map named_in ps @ Option.fold ~none:[] ~some:named_in ret
  | TyInout (t, _) -> named_in t

(* Report each private type in [t]. [whole] words the error when [t] is
   that type, [inside] when it's somewhere in [t]. *)
let no_private env ~private_ ~whole ~inside (t : Resolved.ty) =
  let is_whole p =
    match t with TyName ({ tref = Named q; _ }, _) -> p = q | _ -> false
  in
  List.iter
    (fun ((p : Path.t), loc) ->
      if p.home = env.home then
        match Hashtbl.find_opt private_ p.name with
        | Some decl ->
            report env loc
              ~help:(sprintf "mark `%s` `pub`" p.name)
              ~labels:
                [
                  (decl, sprintf "`%s` is declared here, without `pub`" p.name);
                ]
              (sprintf "%s, which is private to this module"
                 (if is_whole p then whole p.name else inside p.name))
        | None -> ())
    (named_in t)

let no_leaks env ~private_ (items : Resolved.program) =
  List.iter
    (function
      | Fn (f : Resolved.fn_def) when f.pub ->
          let check ~verb t =
            no_private env ~private_ t
              ~whole:(sprintf "`pub fn %s` %s `%s`" f.name.name verb)
              ~inside:
                (sprintf "`pub fn %s`'s signature mentions `%s`" f.name.name)
          in
          List.iter
            (fun (p : Resolved.param) ->
              Option.iter (check ~verb:"takes") p.pty)
            f.params;
          Option.iter (check ~verb:"returns") f.ret
      | Type (td : Resolved.type_def) when td.type_pub -> (
          let t = td.type_name.name in
          let field (fd : Resolved.field) =
            no_private env ~private_ fd.field_ty
              ~whole:(sprintf "`pub type %s` has a field of type `%s`" t)
              ~inside:
                (sprintf "`pub type %s`'s field `%s` mentions `%s`" t
                   fd.field_name.name)
          in
          let ctor (c : tname ctor) (fd : Resolved.field) =
            let c = c.ctor_name.name in
            no_private env ~private_ fd.field_ty
              ~whole:(sprintf "`pub type %s`'s constructor `%s` holds `%s`" t c)
              ~inside:
                (sprintf "`pub type %s`'s constructor `%s` mentions `%s`" t c)
          in
          match td.type_body with
          | Fields fs -> List.iter field fs
          | Ctors cs -> List.iter (fun c -> List.iter (ctor c) c.ctor_fields) cs
          )
      | Fn _ | Type _ | Import _ -> ())
    items

(* Constructor names are unique across every type the module sees, its
   imports' included: a constructor is found through its type
   (infer_expr.ml), but for now it can also be found by its name alone.
   Stage 5 lets two types share a name, and drops this check. *)
let unique_ctors env imported own =
  let seen = Hashtbl.create 16 in
  let declare report_it (td : Iface.type_decl) =
    match td.body with
    | Record _ | Builtin -> ()
    | Sum cs ->
        List.iter
          (fun (c : Iface.ctor) ->
            match Hashtbl.find_opt seen c.cname with
            | Some ((first : Iface.ctor), (owner : Iface.type_decl))
              when report_it ->
                report env c.cloc
                  ~help:"constructor names must be unique across all types"
                  ~labels:
                    [
                      ( first.cloc,
                        sprintf "the first `%s` is here, in `%s`" c.cname
                          owner.path.name );
                    ]
                  (sprintf "there are two constructors named `%s`" c.cname)
            | Some _ -> ()
            | None -> Hashtbl.replace seen c.cname (c, td))
          cs
  in
  List.iter (declare false) imported;
  List.iter (declare true) own

let program sink ~home ~imports (prog : Parsed.program) =
  (* each import, by its alias; the driver passes the interface of every
     module the program imports *)
  let modules =
    List.fold_left
      (fun acc -> function
        | Import (i : import) ->
            Env.add i.alias.name
              (List.find (fun (m : Iface.t) -> m.home = i.path) imports)
              acc
        | Fn _ | Type _ -> acc)
      Env.empty prog
  in
  let env =
    {
      sink;
      home;
      types = Hashtbl.create 16;
      values = Hashtbl.create 16;
      modules;
    }
  in
  (* what's in scope bare: the prelude, which every module imports
     without asking, and the module's own names. Another module's are
     written with its alias. *)
  let prelude =
    List.filter (fun (m : Iface.t) -> m.home = Path.prelude_home) imports
  in
  (* the types in scope: the prelude's, then this module's own, so types
     can refer to types declared further down the file *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (d : Iface.type_decl) ->
          Hashtbl.replace env.types d.path.name (d.path, List.length d.params))
        iface.types)
    prelude;
  let imported_type name =
    List.find_map (fun iface -> Iface.find_type iface name) prelude
  in
  let first_local = Hashtbl.create 16 in
  List.iter
    (function
      | Type (td : Parsed.type_def) -> (
          let name = td.type_name in
          match
            (imported_type name.name, Hashtbl.find_opt first_local name.name)
          with
          | Some { body = Builtin; _ }, _ ->
              report env name.loc ~help:"choose another name"
                (sprintf "`%s` is a built-in type" name.name)
          | Some { loc = first; _ }, _ ->
              report env name.loc ~help:"rename one of them"
                ~labels:
                  (List.map
                     (fun l -> (l, sprintf "the first `%s` is here" name.name))
                     (Option.to_list first))
                (sprintf "there are two types named `%s`" name.name)
          | None, Some first ->
              report env name.loc ~help:"rename one of them"
                ~labels:[ (first, sprintf "the first `%s` is here" name.name) ]
                (sprintf "there are two types named `%s`" name.name)
          | None, None ->
              Hashtbl.replace first_local name.name name.loc;
              Hashtbl.replace env.types name.name
                (Path.make home name.name, List.length td.type_params))
      | Fn _ | Import _ -> ())
    prog;
  (* the functions in scope: the prelude's, then this module's own *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          let name =
            if iface.home = Path.prelude_home && Prelude.find_fn v.vname <> None
            then Intrinsic v.vname
            else Global (Path.make iface.home v.vname)
          in
          Hashtbl.replace env.values v.vname name)
        iface.values)
    prelude;
  let fns =
    List.filter_map
      (function Fn (f : Parsed.fn_def) -> Some f | Type _ | Import _ -> None)
      prog
  in
  no_duplicates env "functions"
    (List.map (fun (f : Parsed.fn_def) -> f.name) fns);
  List.iter
    (fun (f : Parsed.fn_def) ->
      if Hashtbl.mem env.values f.name.name then
        report env f.name.loc ~help:"choose another name"
          (sprintf "`%s` is already a function in the prelude" f.name.name))
    fns;
  List.iter
    (fun (f : Parsed.fn_def) ->
      Hashtbl.replace env.values f.name.name
        (Global (Path.make home f.name.name)))
    fns;
  let items, calls =
    List.split
      (List.map
         (function
           | Type td -> (Type (type_def env td), None)
           | Fn f ->
               let f', calls = fn_def env f in
               (Fn f', Some (f.name.name, calls))
           | Import i -> (Import i, None))
         prog)
  in
  let private_ = Hashtbl.create 8 in
  List.iter
    (function
      | Type (td : Resolved.type_def) when not td.type_pub ->
          Hashtbl.replace private_ td.type_name.name td.type_name.loc
      | Fn _ | Type _ | Import _ -> ())
    items;
  no_leaks env ~private_ items;
  let types =
    List.filter_map
      (function
        | Type td -> Some (Iface.of_type_def ~home td) | Fn _ | Import _ -> None)
      items
  in
  unique_ctors env
    (List.concat_map (fun (i : Iface.t) -> i.types) imports)
    types;
  { home; prog = items; types; calls = List.filter_map Fun.id calls }
