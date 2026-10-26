(* Inference over a whole module (see infer.ml): the call graph, groups of
   functions that call each other, generalization, transparent parameters,
   what public functions and `main` have to spell out, and the canonical
   form of everything inference found. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written
open Infer_handlers
open Infer_declared
open Infer_expr

(* ---- the call graph ---- *)

(* Group functions into strongly connected components of the call graph,
   callees before callers (Tarjan's algorithm, which finishes a component
   only after every component it reaches). [calls] lists the top-level
   functions each function uses, which resolve.ml found, and the methods
   it calls with a dot, as far as they're known (see [program]). *)
let components ~home ~calls (fns : fn_def list) =
  let path = Ast.fn_path home in
  let by_path = Hashtbl.create 16 in
  List.iter (fun (f : fn_def) -> Hashtbl.replace by_path (path f) f) fns;
  let callees (f : fn_def) =
    Path.Map.find (path f) calls |> List.filter_map (Hashtbl.find_opt by_path)
  in
  let index = Hashtbl.create 16 and low = Hashtbl.create 16 in
  let stack = ref [] and on_stack = Hashtbl.create 16 in
  let counter = ref 0 and result = ref [] in
  let rec visit (f : fn_def) =
    let v = path f in
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    incr counter;
    stack := f :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter
      (fun (g : fn_def) ->
        let w = path g in
        if not (Hashtbl.mem index w) then (
          visit g;
          Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w)))
        else if Hashtbl.mem on_stack w then
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (callees f);
    if Hashtbl.find low v = Hashtbl.find index v then
      let rec pop acc =
        match !stack with
        | g :: rest ->
            stack := rest;
            Hashtbl.remove on_stack (path g);
            if path g = v then g :: acc else pop (g :: acc)
        | [] -> assert false
      in
      let group = pop [] in
      (* keep source order inside a group, for stable error messages *)
      let pos (g : fn_def) = (g.loc.start.line, g.loc.start.col) in
      result := List.sort (fun a b -> compare (pos a) (pos b)) group :: !result
  in
  List.iter
    (fun (f : fn_def) -> if not (Hashtbl.mem index (path f)) then visit f)
    fns;
  List.rev !result

(* ---- transparent parameters ----

   A parameter whose type is written `fn(...)` is transparent: its errors
   and dependencies flow into the caller, so they're never written. That's
   only true if the function just calls it, or passes it straight on to
   another function. Storing it, returning it, or capturing it in a lambda
   that escapes would let it outlive the call. One that names a row,
   `f: fn() uses ..d`, is a closure that can be kept.

   A parameter of a dependency's type, `c: Clock`, is transparent the same
   way: what it needs flows into the caller, so it can only be installed,
   `with c in ...`, or passed straight on (deps.md, "Implementations"). *)

let check_transparent sink (f : fn_def) =
  let params =
    List.filter_map
      (fun (p : Resolved.param) ->
        match p.pty with
        | Some (TyFn _ as t) when not (names_row t) -> Some (p.pname, None)
        | Some (TyImpl ({ tref = Named d; _ }, None, _))
          when p.pname.ident.name <> "self" ->
            Some (p.pname, Some d)
        | _ -> None)
      f.params
  in
  List.iter
    (fun ((param : binder), dep) ->
      let name = param.ident.name in
      let fail loc escape =
        let handler_deps =
          match f.body.kind with
          | Handler { deps; _ } ->
              Some
                (List.filter_map
                   (fun (d : tname) ->
                     match d.tref with Named p -> Some p.name | _ -> None)
                   deps)
          | _ -> None
        in
        let dep = Option.map (fun (d : Path.t) -> d.name) dep in
        raise (Diag.Error (not_transparent loc ~name ~dep ~handler_deps escape))
      in
      let is_param = function Local b -> b.id = param.id | _ -> false in
      (* does [e] use the parameter anywhere? *)
      let rec mentions (e : expr) =
        let any = List.exists mentions in
        match e.kind with
        | Var x -> is_param x
        | Int _ | Bool _ | Str _ | Unit -> false
        | Unop (_, a)
        | Field (a, _)
        | Ref a
        | Lambda (_, a)
        | Try a
        | Attempt a
        | Assert a ->
            mentions a
        | Fail (_, args) -> any (List.map snd args)
        | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ }
          ->
            any [ a; b ]
        | If (c, t, f) -> any (c :: t :: Option.to_list f)
        | Array xs -> any xs
        | For { iter; body; _ } -> any [ iter; body ]
        | Call (f, args) -> any (f :: args)
        | Con (_, args) -> any (List.map snd args)
        | Record (_, fields) -> any (List.map snd fields)
        | Block (stmts, last) ->
            any
              (List.map
                 (function Let { value; _ } -> value | Expr e -> e)
                 stmts
              @ [ last ])
        | Match (s, arms) ->
            any
              (s
              :: List.concat_map
                   (fun (a : arm) ->
                     Option.to_list a.arm_guard @ [ a.arm_body ])
                   arms)
        | With { item; body; _ } -> any [ item; body ]
        | Handler { state; arms; _ } ->
            any
              (List.map
                 (function Let { value; _ } -> value | Expr e -> e)
                 state
              @ List.map (fun (a : handler_arm) -> a.arm_impl) arms)
      in
      (* [ok]: this position may hold the bare parameter, or a lambda that
         captures it *)
      let rec walk ~ok (e : expr) =
        let walk_all = List.iter (walk ~ok:false) in
        match e.kind with
        | Var x when is_param x -> if not ok then fail e.loc As_value
        | Field ({ kind = Var x; _ }, _) when is_param x && dep <> None ->
            (* `c.now()`: inference reports it isn't how an operation is
               called *)
            ()
        | Int _ | Bool _ | Str _ | Unit | Var _ -> ()
        | Call (callee, args) ->
            walk ~ok:true callee;
            List.iter (walk ~ok:true) args
        | Lambda (_, body) ->
            if (not ok) && mentions body then fail e.loc Captured
            else walk ~ok:false body
        | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a | Assert a ->
            walk_all [ a ]
        | Fail (_, args) -> walk_all (List.map snd args)
        | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ }
          ->
            walk_all [ a; b ]
        | If (c, t, f) -> walk_all (c :: t :: Option.to_list f)
        | Array xs -> walk_all xs
        | For { iter; body; _ } -> walk_all [ iter; body ]
        | Con (_, args) -> walk_all (List.map snd args)
        | Record (_, fields) -> walk_all (List.map snd fields)
        | Block (stmts, last) ->
            List.iter
              (function
                | Let { value; _ } -> walk ~ok:false value
                | Expr e -> walk ~ok:false e)
              stmts;
            walk ~ok:false last
        | Match (s, arms) ->
            walk ~ok:false s;
            List.iter
              (fun (a : arm) ->
                Option.iter (walk ~ok:false) a.arm_guard;
                walk ~ok:false a.arm_body)
              arms
        | With { item; body; _ } ->
            (* an item is installed, or called with the body *)
            walk ~ok:true item;
            walk ~ok:false body
        | Handler { state; arms; _ } ->
            (* its state and arms are kept by each instance *)
            List.iter
              (function
                | Let { value; _ } -> walk ~ok:false value
                | Expr e -> walk ~ok:false e)
              state;
            List.iter
              (fun (a : handler_arm) ->
                match a.arm_impl.kind with
                | Lambda (_, body) when mentions body ->
                    (* an arm keeps it as a lambda would, but there's no
                       lambda written: point at where the arm uses it *)
                    let rec use (e : expr) =
                      match e.kind with
                      | Var x when is_param x -> Some e.loc
                      | _ -> List.find_map use (Ast.children e)
                    in
                    fail
                      (Option.value (use body) ~default:a.arm_impl.loc)
                      Kept_by_handler
                | _ -> walk ~ok:false a.arm_impl)
              arms
      in
      Diag.recover sink ~default:() (fun () -> walk ~ok:false f.body))
    params

(* ---- what's written ----

   Every type and error set written in the module, visited in source
   order: [ty] sees each type, inner ones too, [errors] each error set,
   and [pattern] each pattern. *)

let walk ~ty ~errors ~pattern (prog : program) =
  let rec ty_ (t : Resolved.ty) =
    ty t;
    match t with
    | TyName (_, args) -> List.iter ty_ args
    | TyFn (ps, ret, errs, _, _) ->
        List.iter ty_ ps;
        Option.iter ty_ ret;
        Option.iter errors_ errs
    | TyImpl _ -> ()
    | TyInout (t, _) -> ty_ t
    | TyErrors es -> errors_ es
  and errors_ (es : Resolved.errors) =
    errors es;
    List.iter
      (function
        | Tag (_, ps) ->
            List.iter (fun (p : Resolved.payload) -> ty_ p.payload_ty) ps
        | Set _ -> ())
      es.errs
  in
  let param (p : Resolved.param) = Option.iter ty_ p.pty in
  let rec pattern_ (p : Resolved.pattern) =
    pattern p;
    match p.pkind with
    | PWild | PVar _ | PInt _ | PBool _ | PFail_any -> ()
    | PCon (_, ps) | PFail (_, ps) | POr ps -> List.iter pattern_ ps
  in
  let rec expr (e : expr) =
    let go = List.iter expr in
    match e.kind with
    | Int _ | Bool _ | Str _ | Unit | Var _ -> ()
    | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a | Assert a ->
        expr a
    | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
        go [ a; b ]
    | If (c, t, f) -> go (c :: t :: Option.to_list f)
    | Call (f, args) -> go (f :: args)
    | Lambda (ps, body) ->
        List.iter param ps;
        expr body
    | Block (stmts, last) ->
        List.iter stmt stmts;
        expr last
    | Handler { state; arms; _ } ->
        List.iter stmt state;
        go (List.map (fun (a : handler_arm) -> a.arm_impl) arms)
    | Con (_, args) | Fail (_, args) -> go (List.map snd args)
    | Record (_, fields) -> go (List.map snd fields)
    | Match (s, arms) ->
        expr s;
        List.iter
          (fun (a : arm) ->
            pattern_ a.arm_pat;
            Option.iter expr a.arm_guard;
            expr a.arm_body)
          arms
    | Array xs -> go xs
    | For { iter; body; _ } -> go [ iter; body ]
    | With { item; body; _ } -> go [ item; body ]
  and stmt = function
    | Let { ty = t; value; _ } ->
        Option.iter ty_ t;
        expr value
    | Expr e -> expr e
  in
  let fn_ (f : fn_def) =
    List.iter param f.params;
    Option.iter ty_ f.ret;
    Option.iter errors_ f.errors;
    expr f.body
  in
  List.iter
    (function
      | Fn f -> fn_ f
      | Type td ->
          let field (fd : Resolved.field) = ty_ fd.field_ty in
          (match td.type_body with
          | Fields fs | Dep fs -> List.iter field fs
          | Ctors cs -> List.iter (fun c -> List.iter field c.ctor_fields) cs
          | Opaque t -> ty_ t
          | Errors es -> errors_ es);
          List.iter (fun (o : op) -> fn_ o.op_fn) td.type_ops
      | Import _ | Testing _ -> ())
    prog

(* The error sets and `Result`s written in the module make sense: an
   error set is a type argument only of `Result`, whose second argument
   is always one, and no set, named sets expanded, has two shapes of one
   tag. [sets] are the named error sets the module can see, and [names]
   says how it writes a type's name. *)
let written_loc : Resolved.ty -> Loc.t = function
  | TyName ({ tloc; _ }, _) -> tloc
  | TyFn (_, _, _, _, l) | TyImpl (_, _, l) | TyInout (_, l) -> l
  | TyErrors es -> es.eloc

let check_written sink ~sets ~names (prog : program) =
  let report = Diag.report sink in
  let result = Path.prelude "Result" in
  let ty (t : Resolved.ty) =
    match t with
    | TyName ({ tref = Named p; _ }, [ _; arg ]) when p = result -> (
        match arg with
        | TyErrors _ -> ()
        | arg -> report (result_needs_set (written_loc arg)))
    | TyName ({ tref = Named p; _ }, args) ->
        List.iter
          (function
            | TyErrors (es : Resolved.errors) ->
                report (set_not_taken es.eloc (names p))
            | _ -> ())
          args
    | TyName _ | TyFn _ | TyImpl _ | TyInout _ | TyErrors _ -> ()
  in
  let pr = Ty.printer ~names { ty = Error; names = []; reqs = [] } in
  let errors (es : Resolved.errors) =
    let tags = Iface.tags ~sets (Iface.declared_errors ~sets es) in
    let reported = ref [] in
    List.iter
      (fun ((l : Ty.label), via) ->
        match
          List.find_opt
            (fun ((m : Ty.label), _) ->
              m.name = l.name && m.payload <> l.payload)
            tags
        with
        | Some (m, via') when not (List.mem l.name !reported) ->
            reported := l.name :: !reported;
            let from (l : Ty.label) via =
              ( (match via with
                | Some (p : Path.t) -> From (names p)
                | None -> Written_here),
                Ty.show_label pr l )
            in
            report
              (two_shapes es.eloc l.name ~old:(from l via) ~new_:(from m via')
                 ~help:rename_one)
        | _ -> ())
      tags
  in
  walk prog ~ty ~errors ~pattern:(fun _ -> ())

(* ---- a function's signature ---- *)

(* The rows [f]'s signature names, `..d`, each once, in the order they're
   first written. *)
let rows_named (f : fn_def) =
  let found = ref [] in
  let name (n : ident option) =
    Option.iter
      (fun (n : ident) ->
        if not (List.mem n.name !found) then found := !found @ [ n.name ])
      n
  in
  let errs (es : Resolved.errors option) =
    name (Option.bind es (fun (es : Resolved.errors) -> es.etail))
  and uses (u : Resolved.uses option) =
    name (Option.bind u (fun (u : Resolved.uses) -> u.dtail))
  in
  let rec ty (t : Resolved.ty) =
    match t with
    | TyName (_, args) -> List.iter ty args
    | TyFn (ps, ret, e, u, _) ->
        List.iter ty ps;
        Option.iter ty ret;
        errs e;
        uses u
    | TyImpl (_, u, _) -> uses u
    | TyInout (t, _) -> ty t
    | TyErrors es -> errs (Some es)
  in
  List.iter (fun (p : Resolved.param) -> Option.iter ty p.pty) f.params;
  Option.iter ty f.ret;
  errs f.errors;
  uses f.uses;
  !found

(* The error rows of a function's transparent parameters, the [params]
   written `fn(...)` without a `!`, given their types [ps]. *)
let transparent_rows (params : Resolved.param list) ps =
  List.concat
    (List.map2
       (fun (p : Resolved.param) (t : Types.param) ->
         match (p.pty, repr t.ty) with
         | Some (TyFn (_, _, None, _, _) as w), TFun (_, _, e, _)
           when not (names_row w) ->
             [ e ]
         | _ -> [])
       params ps)

(* ---- associated values ----

   An associated value is made once, when the program starts, before
   `main` runs: each after every value it uses, through any function it
   calls, so a value never sees one that isn't made yet. Another module's
   values are made before this module's, since the modules are made in
   the order they import each other. *)

(* The module's values in the order they're made, each reported if it
   needs itself to be made. A function's edges are what resolve.ml found
   it uses, and the methods it calls with a dot, which [found] says (the
   context each function was checked in). *)
let value_order env (r : Resolve.t) (fns : fn_def list) ~is_value ~found =
  let home = r.home in
  let edges p =
    let dots =
      match Hashtbl.find_opt found p with
      | Some cx ->
          Hashtbl.fold
            (fun _ f acc ->
              match f with
              | Method_of (q : Path.t) when q.home = home -> q :: acc
              | _ -> acc)
            cx.found []
      | None -> []
    in
    List.filter (fun (q : Path.t) -> q.home = home) (Path.Map.find p r.calls)
    @ dots
    |> List.sort_uniq compare
  in
  let values = List.filter is_value fns in
  let value_named p =
    List.find_opt (fun (f : fn_def) -> Ast.fn_path home f = p) values
  in
  (* a way from [n] back to [goal], if there is one: the functions and
     values on it, ending with [goal] *)
  let rec back ~seen goal n =
    List.find_map
      (fun m ->
        if m = goal then Some [ m ]
        else if Hashtbl.mem seen m then None
        else (
          Hashtbl.replace seen m ();
          Option.map (fun way -> m :: way) (back ~seen goal m)))
      (edges n)
  in
  (* the values of a cycle already reported, so a cycle is reported once,
     from whichever of its values comes first *)
  let reported = ref [] in
  List.iter
    (fun (v : fn_def) ->
      let n = Ast.fn_path home v in
      if not (List.mem n !reported) then
        match back ~seen:(Hashtbl.create 8) n n with
        | Some way ->
            let chain = n :: way in
            reported :=
              List.filter (fun m -> value_named m <> None) chain @ !reported;
            report env
              (made_from_itself v.name.loc (Path.local n)
                 (List.map Path.local chain))
        | None -> ())
    values;
  (* each value after every one it reaches: a depth-first walk, which adds
     a value once everything it reaches is done *)
  let visited = Hashtbl.create 16 and order = ref [] in
  let rec visit n =
    if not (Hashtbl.mem visited n) then (
      Hashtbl.replace visited n ();
      List.iter visit (edges n);
      if value_named n <> None then order := n :: !order)
  in
  List.iter (fun (v : fn_def) -> visit (Ast.fn_path home v)) values;
  List.rev !order

(* ---- the program ---- *)

(* What inference found, in canonical form (ty.ml). *)
module Nodes = Map.Make (Int)

type node = {
  ty : Ty.ty;
  found : found option;
  as_dep : Path.t option;
      (** a handler of several dependencies, where one of them is wanted: that
          one, which it's taken as a description of (Infer_coerce.as_one) *)
  targs : Ty.args option;
      (** a use of a top-level function, a member, an associated value or an
          intrinsic: the type arguments it's used at *)
}

type t = {
  schemes : Ty.scheme Path.Map.t;  (** each function's, by its path *)
  values : Path.t list;
      (** the module's associated values, in the order they're made when the
          program starts: each after every value it uses *)
  nodes : node Nodes.t Path.Map.t;
      (** each function's expressions and patterns, by its path, then node id *)
  in_scope : Path.t list;
      (** the types step 2 of a lookup through a type found, sorted *)
}

(* ---- what's installed around `main`, and around a test ---- *)

(* What the runtime installs around a function it calls: `main`, or a
   test. *)
type runner = {
  installs : Path.t -> bool;  (** whether it installs this dependency *)
  real_of : Path.t -> string option;
      (** the built-in this dependency controls the test one of, if the test
          gets the real one, which it can't control *)
  kind : Infer_msg.runner;  (** which it is, for the error *)
  at : Loc.t;  (** where the error points, if no `uses` lists it *)
}

(* The runtime installs exactly what [run] says around [f], so any other
   dependency it uses is reported: where its `uses` lists it, or at
   [run.at], with a label at the first call that uses it. [ty] is [f]'s
   type, and [cx] what checking its body found. The help shows how to
   install one, with a function that makes an implementation if there is
   one: one of the module's own functions, [fns], whose type [schemes]
   has, or a member of the dependency. *)
let check_installed env (r : Resolve.t) ~fns ~schemes ~withheld ~run
    (f : fn_def) ty cx =
  (* what it lists, if it lists any, and what its body uses: [check_uses]
     leaves a dependency the runtime doesn't install to this *)
  let uses =
    (match (declared_uses ~is_value:(fun _ -> false) f, repr ty) with
      | Some ds, _ -> ds
      | None, TFun (_, _, _, u) -> row_names u
      | None, _ -> [])
    @ row_names cx.uses
  in
  (* an implementation that needs [p] itself would need one installed
     before it, so it isn't one to suggest; a handler of [p] is one *)
  let makes p t =
    let implements q =
      q = p
      ||
      match Hashtbl.find_opt env.types q with
      | Some { body = Handler deps; _ } -> List.mem p deps
      | _ -> false
    in
    match repr t with
    | TFun (ps, ret, _, _) -> (
        match repr ret with
        | TCon (q, [ TUses needs ])
          when implements q && not (List.mem (Ty.dep_label p) (row_names needs))
          ->
            Some (List.length ps)
        | _ -> None)
    | _ -> None
  in
  (* the module's associated values, which aren't called *)
  let values =
    List.concat_map
      (function
        | Type (td : type_def) ->
            List.filter_map
              (fun (o : op) ->
                if o.op_kind = Op_value then Some (Ast.fn_path r.home o.op_fn)
                else None)
              td.type_ops
        | Fn _ | Import _ | Testing _ -> [])
      r.prog
  in
  (* a function that makes an implementation of [p] *)
  let maker (p : Path.t) =
    let own =
      List.find_map
        (fun (g : fn_def) ->
          let is_method =
            match g.params with
            | q :: _ -> q.pname.ident.name = "self"
            | [] -> false
          in
          (* nor `main`, nor what a test was made *)
          let path = Ast.fn_path env.home g in
          if
            is_method
            || path = Path.make env.home "main"
            || String.contains g.name.name '$'
          then None
          else
            Option.bind (Hashtbl.find_opt schemes path) (fun t ->
                Option.map
                  (fun n ->
                    let name = Resolve.value_name r path in
                    if List.mem path values then name else call_written name n)
                  (makes p t)))
        fns
    in
    let member () =
      Option.bind (Hashtbl.find_opt env.types p) (fun (td : Iface.type_decl) ->
          List.find_map
            (fun (o : Iface.op) ->
              let name = env.names p ^ "." ^ o.oname in
              let itself = function
                | [ Ty.Uses u ] ->
                    List.exists
                      (fun (l : Ty.label) -> l.name = Ty.dep_label p)
                      u.labels
                | _ -> false
              in
              match (o.okind, o.oscheme.ty) with
              | Value, Con (q, args) when q = p && not (itself args) ->
                  Some name
              | Function, Fun (ps, Con (q, args), _, _)
                when q = p && not (itself args) ->
                  Some (call_written name (List.length ps))
              | _ -> None)
            (if p.home = env.home then [] else Iface.members td))
    in
    match own with Some m -> Some m | None -> member ()
  in
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let calls =
    List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !(cx.calls)
  in
  List.iter
    (fun dep ->
      let p = Ty.dep_path dep in
      if not (run.installs p) then
        let d = env.names p in
        let written =
          Option.bind f.uses (fun (u : Resolved.uses) ->
              List.find_opt (fun (t : tname) -> t.tref = Named p) u.deps)
        in
        (* the call that needs it: the first that brings it in itself, as
           in [check_uses]. Once `main`'s uses are joined every call's row
           has what it lists, so for one it lists, only a call that brings
           it in itself is that. *)
        let needs =
          let first has = List.find_opt has calls in
          match
            match first (fun c -> brings c dep) with
            | Some c -> Some c
            | None when written = None ->
                first (fun c -> List.mem dep (row_names c.row))
            | None -> None
          with
          | Some c ->
              ( [ (c.cloc, if c.needs then Installing else Call_uses) ],
                withheld_notes withheld dep (Some c) )
          | None -> ([], [])
        in
        let needs, why = needs in
        let loc = match written with Some t -> t.tloc | None -> run.at in
        report env
          (not_installed loc run.kind ~dep:d ~short:p.name ~real:(run.real_of p)
             ~maker:(maker p) ~declared:(Hashtbl.mem env.types p) ~needs ~why))
    (List.sort_uniq String.compare uses)

(* The runtime installs exactly the built-in dependencies `main` uses, as
   the outermost implementations (deps.md, "`main`"). *)
let check_main env r ~fns ~schemes ~withheld (f : fn_def) ty cx =
  check_installed env r ~fns ~schemes ~withheld f ty cx
    ~run:
      {
        installs = runtime_dep;
        real_of = (fun _ -> None);
        kind = Main Prelude.runtime_deps;
        at = f.name.loc;
      }

(* A test gets the test implementation of each built-in dependency, and
   the dependency that controls it, unless it gets the real one (deps.md,
   "Tests"): [t] says which, and [f] is its function (test_items.ml). *)
let check_test env r ~fns ~schemes ~withheld (t : Test_items.test) (f : fn_def)
    ty cx =
  (* the built-in dependency the prelude's [c] controls: `Clock` for
     `TestClock` *)
  let control c =
    List.find_map
      (fun (d, c') -> if c' = Some c then Some d else None)
      Test_items.defaults
  in
  let installs (p : Path.t) =
    p.home = Path.prelude_home
    && (List.mem_assoc p.name Test_items.defaults
       ||
       match control p.name with
       | Some d -> not (List.mem d t.real)
       | None -> false)
  in
  (* the built-in [p] controls, if the test gets the real one *)
  let real_of (p : Path.t) =
    match control p.name with
    | Some d when p.home = Path.prelude_home && List.mem d t.real -> Some d
    | _ -> None
  in
  (* the built-ins it gets the test implementation of *)
  let faked =
    List.filter_map
      (fun (d, _) -> if List.mem d t.real then None else Some d)
      Test_items.defaults
  in
  check_installed env r ~fns ~schemes ~withheld f ty cx
    ~run:
      {
        installs;
        real_of;
        kind =
          Test
            {
              name = Ast.show_str (Test_items.full_name t);
              real = t.real;
              faked;
              group = t.group;
            };
        at = t.loc;
      }

(* What a public function without `->` would write as its result, which
   is [found], printed with [pr]. A handler of several dependencies has a
   type of its own, named after it, `counting_rates uses Clock`, which
   can't be written: if one is in [found], the first by name, it's written
   as the first dependency it implements. *)
let result_help env pr found =
  let rec handlers t =
    match repr t with
    | TCon (p, args) ->
        (match Hashtbl.find_opt env.types p with
          | Some { body = Handler deps; _ } -> [ (type_name env p, deps) ]
          | _ -> [])
        @ List.concat_map handlers args
    | TFun (ps, r, e, u) ->
        List.concat_map handlers (r :: param_tys ps) @ in_row e @ in_row u
    | TErrors r | TUses r -> in_row r
    | TVar _ | TSkol _ | TError -> []
  and in_row r =
    List.concat_map
      (fun (l : label) -> List.concat_map handlers l.payload)
      (fst (row_parts r))
  in
  match List.sort compare (handlers found) with
  | (h, d :: _) :: _ -> (
      match repr found with
      | TCon (p, _) when type_name env p = h -> Say_dep (type_name env d)
      | _ ->
          (* [found] with [h] written as [d] everywhere *)
          let rec rename t =
            match repr t with
            | TCon (p, args) ->
                TCon
                  ((if type_name env p = h then d else p), List.map rename args)
            | TFun (ps, r, e, u) ->
                TFun
                  ( List.map
                      (fun (p : Types.param) -> { p with ty = rename p.ty })
                      ps,
                    rename r,
                    rename_row e,
                    rename_row u )
            | TErrors r -> TErrors (rename_row r)
            | TUses r -> TUses (rename_row r)
            | t -> t
          and rename_row r =
            match repr_row r with
            | RExtend (l, rest) ->
                RExtend
                  ( { l with payload = List.map rename l.payload },
                    rename_row rest )
            | r -> r
          in
          Say_dep_inside { handler = h; written = show pr (rename found) })
  | _ -> Write_found

(* ---- checking the module ---- *)

(* The environment the module [r] is checked in (Infer_env.env), with
   every type it can meet: its own, and those of [reachable], the
   interfaces of every module reachable through its imports. *)
let new_env sink ~reachable (r : Resolve.t) =
  let st = Types.new_state () in
  let types = Hashtbl.create 16 in
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace types td.path td)
    (List.concat_map (fun (iface : Iface.t) -> iface.types) reachable @ r.types);
  (* this module's opaque types are what they're represented as, here *)
  List.iter
    (fun (td : Iface.type_decl) ->
      match td.body with
      | Opaque (Some rep) -> Hashtbl.replace st.reps td.path rep
      | _ -> ())
    r.types;
  (* the types step 2 of a lookup through a type looks in: those the
     module can name bare. [r.scope] is sorted by name, and two of its
     types never share one. *)
  let visible = List.map (fun (_, p) -> Hashtbl.find types p) r.scope in
  {
    st;
    sink;
    home = r.home;
    names = Resolve.type_name r;
    can_name = Resolve.can_name r;
    source =
      Ast.source ~type_name:(Resolve.type_name r)
        ~value_name:(Resolve.value_name r);
    types;
    sets =
      (fun p ->
        match Hashtbl.find_opt types p with
        | Some { body = Errors es; _ } -> Some es
        | _ -> None);
    visible;
    globals = Hashtbl.create 16;
    group = [];
    spelled = [];
    pending = [];
    forced = [];
    in_state = false;
    in_scope = [];
  }

(* The types of what the module can call before any of its own functions
   is checked: the functions of [imports], the interfaces of the modules
   it imports, and the members of every type of [reachable]; and those of
   its own methods, among [fns], whose signatures are written out in
   full. *)
let add_globals env ~imports ~reachable fns =
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.globals
            (Path.make iface.home v.vname)
            (of_scheme env.st v.scheme))
        iface.values)
    imports;
  (* the members of every type the module can meet, which it can call
     with a dot; an associated value is a function of no parameters, as in
     its own module (ast.ml) *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          Path.Map.iter
            (fun path (o : Iface.op) ->
              let t = of_scheme env.st o.oscheme in
              Hashtbl.replace env.globals path
                (if o.okind = Value then TFun ([], t, REmpty, REmpty) else t))
            td.members)
        iface.types)
    reachable;
  (* a method whose signature is written out in full has the type its
     declaration gives it, as it does in its interface, even before it's
     checked: a dot call of it needn't come after it (Resolve.t.methods) *)
  List.iter
    (fun (f : fn_def) ->
      match f.params with
      | p :: _ when p.pname.ident.name = "self" && Ast.spelled f ->
          Hashtbl.replace env.globals (Ast.fn_path env.home f)
            (of_scheme env.st (Iface.signature ~sets:env.sets f))
      | _ -> ())
    fns

(* A function of the group being checked, [fn]: its type parameters, as
   skolems, what checking its body finds, [cx], and the types of its
   parameters and result. *)
type member = {
  fn : fn_def;
  skolems : (int * string) list;
  cx : ctx;
  ps : Types.param list;
  ret : ty;
}

(* What checking the module has found so far: each function's type
   scheme, and what checking its body found, by its path, and why each
   function still gets a dependency from outside, which the solver finds
   (Infer_env.withheld). A [mutable] field can be changed in place. *)
type so_far = {
  schemes : (Path.t, ty) Hashtbl.t;
  tables : (Path.t, ctx) Hashtbl.t;
  mutable withheld : withheld list;
}

(* [f]'s type within its group: its own type parameters (as skolems),
   parameters, result and effects, and the context its body is checked
   in. With it, a way to make the type its declaration gives it, which is
   how the group's other functions see it until the group is done.
   [is_value] says whether a function is an associated value. *)
let setup env ~is_value (f : fn_def) =
  let skolems =
    List.map (fun (t : ident) -> (fresh_id env.st, t.name)) f.tparams
  in
  let tparams = List.map (fun (id, n) -> TSkol (id, n)) skolems in
  (* the rows its signature names, which, like its type parameters, are
     equal only to themselves while it's checked *)
  let row_skolems = List.map (fun n -> (fresh_id env.st, n)) (rows_named f) in
  let named = List.map (fun (id, n) -> (n, RSkol (id, n))) row_skolems in
  let signature ~seen () =
    (* a function that declares its dependencies starts with them: its
       body can add to them only through a transparent parameter, whose
       row this is too, and whatever else it adds is reported once the
       group is done. The same goes for its errors. A row it names, `!
       ..e`, is its own row's end once the group is done: [seen] makes the
       type the group's other functions see, which ends in it already. *)
    let tail (n : ident option) =
      match Option.bind n (fun (n : ident) -> List.assoc_opt n.name named) with
      | Some r when seen -> r
      | _ -> fresh_row env.st
    in
    let errs =
      extend
        (Option.value (declared_errors env ~is_value ~tparams f) ~default:[])
        (tail (Option.bind f.errors (fun (es : Resolved.errors) -> es.etail)))
    in
    let uses =
      List.fold_right
        (fun d rest -> RExtend (dep d, rest))
        (Option.value (declared_uses ~is_value f) ~default:[])
        (tail (Option.bind f.uses (fun (u : Resolved.uses) -> u.dtail)))
    in
    (* A public function's transparent parameter fails with exactly its
       function's errors, as its interface says. A private one's gets a
       row of its own, which a `try` of it joins to the function's: an
       `attempt` of it keeps its errors instead, and then the function
       itself doesn't fail with them. *)
    let ps =
      List.map
        (fun p ->
          let own = if f.pub then errs else fresh_row env.st in
          param_type env ~tparams ~named ~own:(own, uses) p)
        f.params
    in
    let ret =
      match f.ret with
      | Some t -> convert env ~tvars:tparams ~named ~row:closed t
      | None when f.pub && not (is_value f) ->
          unit (* a public function without `->` returns Unit *)
      | None when Ast.is_handler f ->
          (* a handler whose needs aren't written: its type, its
             dependency's or its own (Iface.handler_type), needs what its
             body works out, which is known before its body is checked, so
             the group's other functions, and its own arms, can install
             it *)
          TCon
            ( Option.get (Iface.handler_type ~home:env.home f),
              [ TUses (fresh_row env.st) ] )
      | None -> fresh_var env.st
    in
    (ps, ret, errs, uses)
  in
  let path = Ast.fn_path env.home f in
  let ps, ret, errs, uses = signature ~seen:false () in
  let cx =
    {
      self = path;
      locals = Hashtbl.create 16;
      nodes = Hashtbl.create 64;
      found = Hashtbl.create 16;
      as_dep = Hashtbl.create 4;
      targs = Hashtbl.create 16;
      errs;
      uses;
      calls = ref [];
      tparams;
      handler = errs;
      markers = [];
      params =
        List.map2
          (fun (p : Resolved.param) (t : Types.param) ->
            (p.pname.ident.name, t.ty))
          f.params ps;
      (* a transparent parameter's errors are the function's own *)
      selves = errs :: transparent_rows f.params ps;
      sources = Some (ref []);
      named;
    }
  in
  Hashtbl.replace env.globals path (TFun (ps, ret, errs, uses));
  let declared () =
    let ps, ret, errs, uses = signature ~seen:true () in
    TFun (ps, ret, errs, uses)
  in
  (* its errors and uses, if it names the row each ends in, `! ..e`, and
     they don't end in it yet: the variable each ends in, and the named
     row's skolem *)
  let ends () =
    List.filter_map
      (fun (r, n) ->
        match
          (repr_row (row_end r), Option.map (fun (n : ident) -> n.name) n)
        with
        | RVar { contents = RUnbound (v, _) }, Some n ->
            Option.map
              (fun (id, _) -> (v, id))
              (List.find_opt (fun (_, n') -> n' = n) row_skolems)
        | _ -> None)
      [
        (errs, Option.bind f.errors (fun (es : Resolved.errors) -> es.etail));
        (uses, Option.bind f.uses (fun (u : Resolved.uses) -> u.dtail));
      ]
  in
  ( { fn = f; skolems; cx; ps; ret },
    ( path,
      {
        declared;
        gparams = List.map fst skolems;
        grows = List.map fst row_skolems;
        gends = ends;
      } ) )

(* Check the body of [m], a function of the group, against its result. *)
let check_body env ~is_value m =
  let f = m.fn in
  bind_params m.cx f.params m.ps;
  let why =
    match f.ret with
    | Some _ ->
        explain
          ~notes:
            [
              declared_type ~value:(is_value f) (Ast.fn_name f)
                (show (printer env) m.ret);
            ]
          ()
    | None when f.pub && not (is_value f) ->
        explain ~notes:[ returns_unit ]
          ~help_of:(fun pr found ->
            write_result (show pr found) (result_help env pr found))
          ()
    | None -> plain
  in
  match (f.body.kind, m.ret) with
  | Handler { state; arms; _ }, TCon (_, [ TUses needs ]) when f.ret = None ->
      (* its needs are what its state and arms use *)
      handler core env m.cx state arms ~needs ~declared:None;
      Hashtbl.replace m.cx.nodes f.body.node m.ret
  | _ -> check env m.cx ~why f.body m.ret

(* Generalize each function of the group [ms], once it's solved, into its
   type scheme. A function whose type holds another's type parameter, one
   of the group whose signature names it, is reported. *)
let generalize_group env so_far ms =
  List.iter
    (fun m ->
      let f = m.fn and path = m.cx.self in
      let mono = Hashtbl.find env.globals path in
      (match
         List.filter
           (fun (id, _) -> not (List.mem_assoc id m.skolems))
           (Types.skolems mono)
       with
      | (id, t) :: _ ->
          let o = (List.find (fun o -> List.mem_assoc id o.skolems) ms).fn in
          let declared = List.find (fun (p : ident) -> p.name = t) o.tparams in
          report env
            (others_param f.name.loc ~fn:(Ast.fn_name f) ~other:(Ast.fn_name o)
               ~param:t ~declared:declared.loc)
      | [] -> ());
      let row_skolems =
        List.filter_map
          (function _, RSkol (id, n) -> Some (id, n) | _ -> None)
          m.cx.named
      in
      let scheme = generalize env.st ~skolems:m.skolems ~row_skolems mono in
      Hashtbl.replace env.globals path scheme;
      Hashtbl.replace so_far.schemes path scheme;
      Hashtbl.replace so_far.tables path m.cx)
    ms

(* A public function of [ms] spells out its full contract, and a public
   value its type. *)
let check_spelled env ~is_value so_far ms =
  List.iter
    (fun m ->
      let f = m.fn in
      if f.pub && is_value f && f.ret = None then
        match Hashtbl.find so_far.schemes m.cx.self with
        | TFun (_, t, _, _) as scheme ->
            let pr = printer env in
            reserve pr scheme;
            report env
              (untyped_value f.name.loc ~name:f.name.name ~fn:(Ast.fn_name f)
                 (show pr t))
        | _ -> assert false)
    ms;
  List.iter
    (fun m ->
      let f = m.fn in
      if f.pub && not (is_value f) then
        match Hashtbl.find so_far.schemes m.cx.self with
        | TFun (ps, _, _, _) as scheme ->
            List.iter2
              (fun (p : Resolved.param) (t : Types.param) ->
                if p.pty = None then (
                  let pr = printer env in
                  reserve pr scheme;
                  let name = p.pname.ident in
                  report env
                    (untyped_param name.loc ~name:name.name ~fn:(Ast.fn_name f)
                       (show pr t.ty))))
              f.params ps
        | _ -> assert false)
    ms

(* Check a group of functions that call each other: each one's body, then
   what that leaves to decide once every body is checked, by the
   constraint solver; then each is generalized. Each body sees the others
   only as their declarations describe them (see [setup]). [values] are
   the module's associated values, and [main] the program's `main`, if
   the module is the program's entry. *)
let check_group env ~values ~main so_far group =
  let is_value_path p = List.mem p values in
  let is_value f = is_value_path (Ast.fn_path env.home f) in
  enter_level env.st;
  let ms, declared = List.split (List.map (setup env ~is_value) group) in
  env.group <- declared;
  env.spelled <-
    List.filter_map
      (fun (f : fn_def) ->
        if Ast.spelled f then Some (Ast.fn_path env.home f) else None)
      group;
  List.iter (check_body env ~is_value) ms;
  (* what each function names and declares, which holds of what its body
     does once the group's other constraints are decided *)
  List.iter
    (fun m ->
      let c = { ffn = m.fn; fcx = m.cx; fmain = main = Some m.cx.self } in
      List.iter (defer env) [ Own_errors c; Own_rows c; Declared c ])
    ms;
  so_far.withheld <-
    so_far.withheld
    @ Solve.solve env ~is_value:is_value_path ~withheld:so_far.withheld;
  env.group <- [];
  env.spelled <- [];
  leave_level env.st;
  generalize_group env so_far ms;
  check_spelled env ~is_value so_far ms

(* A test's body is `Unit`, so one whose value is thrown away, like a
   comparison without its `assert`, is reported, as any other dropped
   value is. Its value is that of the last line, inside the `with` a group
   wraps it in. [bodies] are the functions that are tests' bodies. *)
let check_test_body env so_far ~bodies (f : fn_def) =
  let path = Ast.fn_path env.home f in
  if List.mem path bodies then
    let rec last (e : expr) =
      match e.kind with
      | Block (_, l) -> last l
      | With { body; _ } -> last body
      | _ -> e
    in
    (* the last line's own type: a wrapper's `with` around it has the
       wrapper's result, which is reported where it's wrong *)
    let own =
      Option.bind (Hashtbl.find_opt so_far.tables path) (fun cx ->
          Hashtbl.find_opt cx.nodes (last f.body).node)
    in
    match (own, repr (Hashtbl.find so_far.schemes path)) with
    | Some ret, _ | None, TFun (_, ret, _, _) ->
        unify_at env (last f.body).loc ~found:ret ~expected:unit ~msg:test_body
          ~notes:[ test_passes ]
          ~help:(test_body_help ~is_bool:(repr ret = bool))
    | _ -> ()

(* What the runtime installs around what it runs: the program's `main`,
   if the module is the program's entry, the file [entry], and each of
   [tests]. *)
let check_runs env r so_far ?entry ~tests fns =
  let find name =
    List.find_opt
      (fun (f : fn_def) -> Ast.fn_path env.home f = Path.make env.home name)
      fns
  in
  let found (f : fn_def) =
    let path = Ast.fn_path env.home f in
    (Hashtbl.find so_far.schemes path, Hashtbl.find so_far.tables path)
  in
  let schemes = so_far.schemes and withheld = so_far.withheld in
  (match Option.map (fun file -> (file, find "main")) entry with
  | None -> ()
  | Some (file, None) -> report env (no_main (Loc.point ~file 1 1))
  | Some (_, Some f) when f.params <> [] ->
      report env (main_params (List.hd f.params).pname.ident.loc)
  | Some (_, Some f) ->
      let ty, cx = found f in
      check_main env r ~fns ~schemes ~withheld f ty cx);
  List.iter
    (fun (t : Test_items.test) ->
      match find t.fn with
      | Some f ->
          let ty, cx = found f in
          check_test env r ~fns ~schemes ~withheld t f ty cx
      | None -> ())
    tests

(* What inference found of [f], in canonical form: its scheme, and its
   nodes. Its scheme and node types share one numbering, so a variable is
   the same [Var n] in both, and so do the type arguments its uses pick.
   Nodes are converted in order of their ids, so the numbering doesn't
   depend on a hash table's order, and their type arguments after all
   their types, so those number variables just as they did before there
   were type arguments. *)
let canonical env so_far (f : fn_def) =
  let path = Ast.fn_path env.home f in
  let c = canon env.st in
  (* a use's type arguments (Infer_env.targs), what each variable of the
     callee's scheme stands for. A function of the group being checked is
     generic now, so what each of its variables stands for in the type it
     was used at is known. *)
  let type_args (u : Infer_env.targs) : Ty.args =
    let s =
      match u.tpicked with
      | Fresh s -> s
      | Group t -> (
          let scheme = Hashtbl.find env.globals u.tcallee in
          let s = matching env.st scheme t in
          match repr scheme with
          | TFun ([], r, _, _) when u.tvalue -> restrict s (generics r)
          | _ -> s)
    in
    {
      tys = List.map (fun (_, t) -> canon_ty c ~all:true t) s.tys;
      rows = List.map (fun (_, r) -> canon_row c ~all:true r) s.rows;
    }
  in
  let ty = canon_ty c ~all:false (Hashtbl.find so_far.schemes path) in
  let scheme : Ty.scheme = { ty; names = canon_names c; reqs = [] } in
  let cx = Hashtbl.find so_far.tables path in
  let ids =
    Hashtbl.fold (fun id _ acc -> id :: acc) cx.nodes [] |> List.sort compare
  in
  let tys =
    List.map (fun id -> canon_ty c ~all:true (Hashtbl.find cx.nodes id)) ids
  in
  let nodes =
    List.fold_left2
      (fun acc id ty ->
        Nodes.add id
          {
            ty;
            found = Hashtbl.find_opt cx.found id;
            as_dep = Hashtbl.find_opt cx.as_dep id;
            targs = Option.map type_args (Hashtbl.find_opt cx.targs id);
          }
          acc)
      Nodes.empty ids tys
  in
  ((path, scheme), (path, nodes))

(* Infer every function's type, and return each function's type scheme and
   the types of its expressions, in canonical form. [imports] are the
   interfaces of the modules it imports, whose functions it can call, and
   [reachable] those of every module reachable through them, whose types
   it can meet: a field of an imported type can have a type from a module
   this one never imported. [extra] are the dot calls of methods found so
   far that the call graph needs besides [r]'s (see [program]). *)
let check sink ~extra ~imports ~reachable ?entry ~tests ~bodies (r : Resolve.t)
    =
  let env = new_env sink ~reachable r in
  let home = r.home in
  check_written sink ~sets:env.sets ~names:env.names r.prog;
  (* the module's functions, its types' members included; an associated
     value is checked as a function of no parameters (ast.ml) *)
  let fns = Ast.functions r.prog in
  add_globals env ~imports ~reachable fns;
  let values =
    List.concat_map
      (function
        | Type td ->
            List.filter_map
              (fun (o : op) ->
                if o.op_kind = Op_value then Some (Ast.fn_path home o.op_fn)
                else None)
              td.type_ops
        | Fn _ | Import _ | Testing _ -> [])
      r.prog
  in
  let is_value (f : fn_def) = List.mem (Ast.fn_path home f) values in
  List.iter (check_transparent sink) fns;
  let so_far =
    { schemes = Hashtbl.create 16; tables = Hashtbl.create 16; withheld = [] }
  in
  let main = Option.map (fun _ -> Path.make home "main") entry in
  List.iter
    (check_group env ~values ~main so_far)
    (components ~home
       ~calls:
         (Path.Map.mapi
            (fun f calls ->
              let found =
                List.filter_map
                  (fun (caller, m) -> if caller = f then Some m else None)
                  extra
              in
              calls @ Path.Map.find f r.methods @ found)
            r.calls)
       fns);
  let values = value_order env r fns ~is_value ~found:so_far.tables in
  List.iter
    (check_test_body env so_far ~bodies:(List.map (Path.make home) bodies))
    fns;
  check_runs env r so_far ?entry ~tests fns;
  let schemes, nodes = List.split (List.map (canonical env so_far) fns) in
  {
    schemes = Path.Map.of_list schemes;
    values;
    nodes = Path.Map.of_list nodes;
    in_scope = List.sort compare env.in_scope;
  }

(* Which method a dot call like `s.size()` calls is found only by checking
   the call, through `s`'s type, but the call graph puts the functions in
   order before anything is checked. So the graph starts with the dot calls
   resolve.ml could tell (Resolve.t.methods), and when checking finds a dot
   call of a method that isn't checked yet, that call is added to the graph
   and the module is checked again, from the start. Each time adds a call
   the graph didn't have, so this ends. Only the calls a function really
   makes join it to a group, so a method that only shares a name with the
   one called changes nothing about the caller's type or its `uses`.

   A try reports to its own sink, and only the last try's errors are kept. *)
let program sink ~imports ~reachable ?entry ?(tests = []) ?(bodies = [])
    (r : Resolve.t) =
  let rec go extra =
    let tried = Diag.sink () in
    let keep () = List.iter (Diag.report sink) (List.rev tried.reported) in
    match check tried ~extra ~imports ~reachable ?entry ~tests ~bodies r with
    | t ->
        keep ();
        t
    | exception Infer_env.Unchecked { caller; callee } ->
        go ((caller, callee) :: extra)
    | exception e ->
        keep ();
        raise e
  in
  go []
