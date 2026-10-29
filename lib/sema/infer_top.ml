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
    | TyImpl { impl_errors; _ } -> Option.iter errors_ impl_errors
    | TyInout (t, _) -> ty_ t
    | TyTuple (ts, _) -> List.iter ty_ ts
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
    | PWild | PVar _ | PInt _ | PBool _ | PFail_any | PFail_in _ -> ()
    | PAs (q, _) -> pattern_ q
    | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps -> List.iter pattern_ ps
    | PRecord (_, fs) | PCon_named (_, fs) ->
        List.iter (fun (_, q) -> pattern_ q) fs.fpats
  in
  let rec expr (e : expr) =
    let go = List.iter expr in
    match e.kind with
    | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break | Tag_set _ -> ()
    | Named (_, a) -> expr a
    | Unop (_, a, _)
    | Field (a, _)
    | Ref a
    | Try a
    | Attempt a
    | Assert a
    | Inline_handler a ->
        expr a
    | While { cond; body } -> go [ cond; body ]
    | Binop (_, a, b, _) | Index (a, b) | Assign { target = a; value = b; _ } ->
        go [ a; b ]
    | Slice (a, lo, hi) -> go [ a; lo; hi ]
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
    | Record (_, fields) | Con_named (_, fields) -> go (List.map snd fields)
    | Update { base; fields; _ } -> go (base :: List.map snd fields)
    | Match (s, arms) ->
        expr s;
        List.iter
          (fun (a : arm) ->
            pattern_ a.arm_pat;
            Option.iter expr a.arm_guard;
            expr a.arm_body)
          arms
    | Array xs | Tuple xs -> go xs
    | For { index; pat; _ } ->
        Option.iter pattern_ index;
        pattern_ pat;
        go (Ast.children e)
    | With { items; body } -> go (with_links items @ [ body ])
  and stmt = function
    | Let { ty = t; value; _ } ->
        Option.iter ty_ t;
        expr value
    | Let_pattern { pat; value; else_ } ->
        pattern_ pat;
        expr value;
        Option.iter expr else_
    | Expr e | Finally e -> expr e
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
          | Fields fs | Opaque_fields fs | Dep fs -> List.iter field fs
          | Ctors cs -> List.iter (fun c -> List.iter field c.ctor_fields) cs
          | Opaque { rep; _ } -> ty_ rep
          | Errors es -> errors_ es
          | Dep_alias _ | Builtin -> ());
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
  | TyFn (_, _, _, _, l)
  | TyImpl { impl_loc = l; _ }
  | TyInout (_, l)
  | TyTuple (_, l) ->
      l
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
    | TyName _ | TyFn _ | TyImpl _ | TyInout _ | TyErrors _ | TyTuple _ -> ()
  in
  let pr =
    Ty.printer ~names { ty = Error; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }
  in
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
   first written: its own, and those of the implementation types in it. *)
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
    | TyFn (ps, ret, _, _, _) ->
        (* a block's own rows are never named (resolve.ml) *)
        List.iter ty ps;
        Option.iter ty ret
    | TyImpl { impl_errors = e; impl_uses = u; _ } ->
        errs e;
        uses u
    | TyInout (t, _) -> ty t
    | TyTuple (ts, _) -> List.iter ty ts
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
         | Some (TyFn (_, _, None, _, _)), TFun (_, _, e, _) -> [ e ]
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
  found : Ty.label found_ option;
  narrowed : Path.t list option;
      (** an implementation of several dependencies, narrowed to some of them,
          these, where a written type asks for those (Infer_expr.narrow) *)
  coerce : Sized.coerce option;
      (** a value read from a sized type as its wide one, or stored into one
          (Infer_expr.read_wide, [check]) *)
  targs : Ty.args option;
      (** a use of a top-level function, a member, an associated value or an
          intrinsic: the type arguments it's used at *)
  needs : (int * string) list;
      (** what the function used there needs of its type arguments, its scheme's
          requirements: a dictionary for each (core.ml) *)
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
  opaque_eq : Path.t list;
      (** the module's opaque types that have `==`, whatever their type
          arguments, in the order they're declared: what each is represented as
          has no function in it *)
  opaque : Path.t list;
      (** the opaque types the module sees, its own and those of the modules it
          imports, but the prelude's, sorted: what a handler keeps a resource
          of, which makes it exclusive (Core's [Instance]) *)
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
    (match
       ( declared_uses env ~is_value:(fun _ -> false) ~tparams:cx.tparams f,
         repr ty )
     with
      | Some ds, _ -> ds
      | None, TFun (_, _, _, u) -> fst (row_parts u)
      | None, _ -> [])
    @ fst (row_parts cx.uses)
  in
  let uses =
    List.fold_left
      (fun acc l -> if has_dep acc l then acc else acc @ [ l ])
      [] uses
  in
  (* an implementation that needs [p] itself would need one installed
     before it, so it isn't one to suggest; a handler of [p] is one *)
  let makes p t =
    match repr t with
    | TFun (ps, ret, _, _) -> (
        match impl_parts ret with
        | Some (ds, needs)
          when List.exists (fun d -> d.dpath = p) ds
               && not (List.mem (Ty.dep_label p) (row_names needs)) ->
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
              let makes = function
                | Ty.Impl { deps = [ q ]; needs; _ } ->
                    q.dpath = p
                    && not
                         (List.exists
                            (fun (l : Ty.label) -> l.name = Ty.dep_label p)
                            needs.labels)
                | _ -> false
              in
              match (o.okind, o.oscheme.ty) with
              | Value, t when makes t -> Some name
              | Function, Fun (ps, t, _, _) when makes t ->
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
    (fun (dep : label) ->
      let p = Ty.dep_path dep.name in
      if not (run.installs p) then
        let d = shown_dep env dep in
        let written =
          Option.bind f.uses (fun (u : Resolved.uses) ->
              Option.map
                (fun (t : tname dep_ref) -> t.dep)
                (List.find_opt
                   (fun (t : tname dep_ref) -> t.dep.tref = Named p)
                   u.deps))
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
            | None when written = None -> first (fun c -> has_label c.row dep)
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
    uses

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
(* What a test's world installs, when it gets the real implementation of
   the built-ins [real] and the test one of the rest: whether it installs
   a dependency, the built-in a dependency controls if that's a real one,
   and the built-ins it gets the test one of. *)
let test_world ~real =
  (* the built-in dependency [c] controls: `Clock` for `TestClock`,
     `Net` for `sim.SimNet` *)
  let control (c : Path.t) =
    List.find_map
      (fun (d, c') -> if c' = Some c then Some d else None)
      Test_items.defaults
  in
  let installs (p : Path.t) =
    (p.home = Path.prelude_home && List.mem_assoc p.name Test_items.defaults)
    ||
    match control p with
    | Some d -> not (List.mem d real)
    | None -> false
  in
  (* the built-in [p] controls, if the test gets the real one *)
  let real_of (p : Path.t) =
    match control p with
    | Some d when List.mem d real -> Some d
    | _ -> None
  in
  (* the built-ins it gets the test implementation of *)
  let faked =
    List.filter_map
      (fun (d, _) -> if List.mem d real then None else Some d)
      Test_items.defaults
  in
  (installs, real_of, faked)

let check_test env r ~fns ~schemes ~withheld (t : Test_items.test) (f : fn_def)
    ty cx =
  let installs, real_of, faked = test_world ~real:t.real in
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

(* A `ren console` session, the function [f] (driver.ml), runs in a
   test's world, with the real implementation of the built-ins [real]. *)
let check_console env r ~fns ~schemes ~withheld ~real (f : fn_def) ty cx =
  let installs, real_of, faked = test_world ~real in
  check_installed env r ~fns ~schemes ~withheld f ty cx
    ~run:{ installs; real_of; kind = Console { real; faked }; at = f.body.loc }

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
      | Opaque (Rep rep) -> Hashtbl.replace st.reps td.path rep
      | _ -> ())
    r.types;
  (* and an alias of a dependency's description is one of what it names *)
  Hashtbl.iter
    (fun p (td : Iface.type_decl) ->
      match td.body with
      | Dep_alias t -> Hashtbl.replace st.aliases p t
      | _ -> ())
    types;
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
    written = Hashtbl.create 16;
    in_state = None;
    in_finally = 0;
    finallies = Hashtbl.create 4;
    finally_rows = [];
    in_scope = [];
    client = false;
    hidden = [];
    anys = Hashtbl.create 4;
    any_skolems = Hashtbl.create 4;
    any_call = None;
    params_of = Hashtbl.create 16;
    defaults_of = Hashtbl.create 16;
    test_reported = Hashtbl.create 4;
  }

(* A function's parameters with defaults, by their places among the
   arguments a call gives: after `self`, for a method. *)
let given_defaults ~method_ ds =
  if method_ then List.map (fun (i, n, l) -> (i - 1, n, l)) ds else ds

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
            (of_scheme env.st v.scheme);
          Hashtbl.replace env.params_of (Path.make iface.home v.vname) v.vparams;
          Hashtbl.replace env.defaults_of
            (Path.make iface.home v.vname)
            v.scheme.defaults)
        (* the test tier too: Resolve lets only tests call it *)
        (iface.values @ iface.tests))
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
              Hashtbl.replace env.defaults_of path
                (given_defaults ~method_:(o.okind = Method) o.oscheme.defaults);
              Hashtbl.replace env.globals path
                (if o.okind = Value then TFun ([], t, REmpty, REmpty) else t))
            td.members)
        iface.types)
    reachable;
  (* a method whose signature is written out in full has the type its
     declaration gives it, as it does in its interface, even before it's
     checked: a dot call of it needn't come after it (Resolve.t.methods).
     Unless it's generic: what it needs of its type parameters is known
     only once its body is checked, so a call of it has to come after
     that, or be in its group (Infer_env.Unchecked) *)
  List.iter
    (fun (f : fn_def) ->
      match f.params with
      | p :: _ when p.pname.ident.name = "self" && Ast.spelled f ->
          let s = Iface.signature ~sets:env.sets f in
          if (Ty.own_args s.ty).tys = [] then
            Hashtbl.replace env.globals (Ast.fn_path env.home f)
              (of_scheme env.st s)
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
      extend
        (Option.value (declared_uses env ~is_value ~tparams f) ~default:[])
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
          param_type env ~tparams ~named ~own:(own, uses)
            ~closed_block:(Iface.closed_blocks (Ast.fn_path env.home f))
            p)
        f.params
    in
    let ret =
      match f.ret with
      | Some (TyImpl { impl_errors = None; _ } as t)
        when Ast.is_handler f && not f.pub -> (
          (* a private handler whose needs are written, but not what it
             fails to start with: that's inferred, as a private function's
             errors are *)
          match convert env ~tvars:tparams ~named ~row:closed t with
          | TImpl i -> TImpl { i with fails = fresh_row env.st }
          | t -> t)
      | Some t -> convert env ~tvars:tparams ~named ~row:closed t
      | None when Ast.is_handler f ->
          (* a handler whose needs aren't written: its type, which lists
             the dependencies it implements (Types.impl_type), needs what
             its body works out, and fails to start with what that does,
             which is known before its body is checked, so the group's
             other functions, and its own arms, can install it *)
          impl_type
            ~over:
              (match f.body.kind with
              | Handler { over; _ } -> over
              | _ -> false)
            ~fails:(fresh_row env.st)
            (match f.body.kind with
            | Handler { any = true; _ } ->
                (* one `over any`, public or not: what its arm fails with
                   itself is inferred, as its type's (Infer_handlers.own_deps) *)
                [
                  {
                    dpath = Ty.any_path;
                    dargs = [ TErrors (fresh_row env.st) ];
                  };
                ]
            | Handler { deps; _ } -> written_deps env ~tvars:tparams deps
            | _ -> [])
            (fresh_row env.st)
      | None when f.pub && not (is_value f) ->
          unit (* a public function without `->` returns Unit *)
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
      binders = Hashtbl.create 8;
      let_blocks = Hashtbl.create 4;
      written_locals = Hashtbl.create 8;
      nodes = Hashtbl.create 64;
      found = Hashtbl.create 16;
      narrowed = Hashtbl.create 4;
      coerced = Hashtbl.create 4;
      targs = Hashtbl.create 16;
      required = Hashtbl.create 4;
      errs;
      uses;
      calls = ref [];
      lambdas = ref 0;
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
      declares = declared_uses env ~is_value ~tparams f;
      later = ref [];
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
  bind_params ~own:true m.cx f.params m.ps;
  (* each default is a literal of its parameter's type, as an argument
     there would be *)
  List.iter2
    (fun (p : Resolved.param) (t : Types.param) ->
      match p.pdefault with
      | Some (lit, loc, node) ->
          let kind : expr_kind =
            match lit with
            | LInt k -> Int k
            | LFloat x -> Float x
            | LBool b -> Bool b
            | LStr s -> Str s
          in
          check env m.cx { kind; loc; node } t.ty
      | None -> ())
    f.params m.ps;
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
          ~help:(fun found _ -> write_result found)
          ()
    | None -> plain
  in
  (match (f.body.kind, m.ret) with
  | Handler _, t when f.ret = None && impl_of t <> None ->
      (* its needs are what its state and arms use *)
      let i = Option.get (impl_of t) in
      handler core env m.cx f.body ~own:i.deps ~needs:i.needs ~fails:i.fails
        ~declared:None;
      Hashtbl.replace m.cx.nodes f.body.node m.ret
  | _ ->
      check env m.cx ~why
        ?written:(if f.ret <> None then Some m.ret else None)
        f.body m.ret);
  (* what waited for the body, in the order it was met *)
  List.iter (fun k -> k ()) (List.rev !(m.cx.later))

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
      close_result_needs mono;
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

(* A member with a reserved name, an operator, `key` or `show`, doesn't
   fail or use a dependency, whatever its body calls: `a + b` has no `try`
   in front, and `==` and `show` run wherever a value is compared or
   shown (resolve.ml, [reserved], checks what's written). *)
let check_reserved env so_far ms =
  List.iter
    (fun m ->
      let f = m.fn in
      let reserved =
        f.owner <> None
        && List.mem f.name.name ("key" :: "show" :: Infer_reqs.operators)
      in
      if reserved then
        match Hashtbl.find so_far.schemes m.cx.self with
        | TFun (_, _, errs, uses) -> (
            match (fst (row_parts errs), fst (row_parts uses)) with
            | l :: _, _ ->
                report env
                  (Infer_msg.reserved_impure f.name.loc ~name:f.name.name
                     ~what:(sprintf "fail, but it can fail with `%s`" l.name))
            | [], l :: _ ->
                report env
                  (Infer_msg.reserved_impure f.name.loc ~name:f.name.name
                     ~what:
                       (sprintf "use a dependency, but it uses `%s`"
                          (env.names (Ty.dep_path l.name))))
            | [], [] -> ())
        | _ -> ())
    ms

(* A type that keeps rules is opaque (module-build.md, "Private unless
   `pub`"). A public record or sum type is open: anyone can build one and
   change its fields. So none of its members, public or private, can
   change it, `inout self`, or refuse to make one: return it, or a value
   with one in it, `(P, Int)`, with errors (an error row that's only a
   transparent parameter's tail isn't any), or, as an associated
   function, return `Option<P>` or `Result<P, E>`, a refusal written as a
   value. It's checked once every member's type is inferred, since a
   private member's errors aren't written. The first such member is
   reported, once per type: the fix, making it opaque, is the same for
   all of them. *)
let check_keeps_rules env so_far (r : Resolve.t) =
  let check (td : type_def) =
    let path = Path.make r.home td.type_name.name in
    let changes (f : fn_def) =
      match f.params with
      | p :: _ -> p.pname.ident.name = "self" && p.pmode = Inout
      | [] -> false
    in
    let is_method (f : fn_def) =
      match f.params with p :: _ -> p.pname.ident.name = "self" | [] -> false
    in
    (* whether a value of [t] holds one of the type: is one, or has one in
       it, `Option<P>`, `(P, Int)` *)
    let rec holds t =
      match repr t with
      | TCon (p, args) -> p = path || List.exists holds args
      | _ -> false
    in
    (* whether [ret] is a refusal written as a value, `Option<P>` or
       `Result<P, ! Bad>`. Only an associated function refuses so: a
       method, `fn pred(self) -> Option<Day>`, is a question about a
       value it's given, not a way to make one. *)
    let refused ret =
      match repr ret with
      | TCon (p, [ ok ]) when p = Path.prelude "Option" -> holds ok
      | TCon (p, [ ok; _ ]) when p = Path.prelude "Result" -> holds ok
      | _ -> false
    in
    let refuses (f : fn_def) =
      match Hashtbl.find_opt so_far.schemes (Ast.fn_path r.home f) with
      | Some (TFun (_, ret, errs, _)) ->
          (holds ret && fst (row_parts errs) <> [])
          || ((not (is_method f)) && refused ret)
      | _ -> false
    in
    let broken =
      List.find_map
        (fun (o : op) ->
          let f = o.op_fn in
          if o.op_kind <> Op_fn then None
          else if changes f then Some (f, `Changes)
          else if refuses f then Some (f, `Refuses)
          else None)
        td.type_ops
    in
    match broken with
    | None -> ()
    | Some (f, how) ->
        let decl = Hashtbl.find env.types path in
        let params =
          match decl.params with
          | [] -> ""
          | ps -> "<" ^ String.concat ", " ps ^ ">"
        in
        let name = td.type_name.name ^ params in
        let record, hide =
          match decl.body with
          | Record fs ->
              (* each field's type as this module writes it, the type's
                 parameters by their names *)
              let pr =
                Ty.printer ~names:env.names
                  {
                    ty = Ty.Error;
                    names = List.mapi (fun i n -> (i, n)) decl.params;
                    reqs = [];
                    row_reqs = [];
                    modes = [];
                    defaults = [];
                  }
              in
              let fields =
                List.map
                  (fun (fd : Iface.field) ->
                    fd.fname ^ ": " ^ Ty.show pr fd.fty)
                  fs
              in
              ( true,
                hide_fields
                  ~written:
                    (sprintf "pub type %s = opaque { %s }" name
                       (String.concat ", " fields)) )
          | _ ->
              let state = td.type_name.name ^ "State" ^ params in
              ( false,
                hide_ctors
                  ~state:(sprintf "type %s = ..." state)
                  ~written:(sprintf "pub type %s = opaque %s" name state) )
        in
        report env
          (keeps_rules f.name.loc ~owner:td.type_name.name ~name:f.name.name
             ~record ~hide how)
  in
  List.iter
    (function
      | Type ({ type_pub = true; type_body = Fields _ | Ctors _; _ } as td) ->
          check td
      | Type _ | Fn _ | Import _ | Testing _ -> ())
    r.prog

(* ---- the client view ---- *)

(* Test code sees the module as an importer does (testing.md, "Tests are
   specifications"): each of its own types as its interface has it, an
   opaque one opaque; a private one with nothing to see in it, and nothing
   to name it by. Each is made once, at
   the start, as [Iface.of_module] makes the interface, with whether it's
   public. A named error set or a dependency is kept as it is: Resolve
   has already stopped test code naming a private one. *)
let client_view env (r : Resolve.t) =
  let public =
    List.filter_map
      (function
        | Type (td : type_def) when td.type_pub ->
            Some (Path.make r.home td.type_name.name)
        | Type _ | Fn _ | Import _ | Testing _ -> None)
      r.prog
  in
  List.map
    (fun (td : Iface.type_decl) ->
      let hidden =
        Iface.Opaque (Hidden { eq = Infer_reqs.opaque_has_eq env td.path })
      in
      if List.mem td.path public then
        (* its private members stay, so a message can say one is private:
           what's not [own] (infer_env.ml) finds only the public ones *)
        ((if td.opaque then { td with body = hidden } else td), true)
      else
        match td.body with
        | Record _ | Sum _ | Opaque _ ->
            ({ td with members = Path.Map.empty; body = hidden }, false)
        | Errors _ | Dep _ | Dep_alias _ | Builtin -> (td, false))
    r.types

(* Run [f] with the module seen through [client] (see [client_view]): its
   own types swapped for theirs, no representation revealed, and only its
   public types visible; then put back as it was. *)
let as_client env client f =
  let mine =
    List.map
      (fun ((td : Iface.type_decl), _) -> Hashtbl.find env.types td.path)
      client
  in
  let reps = Hashtbl.copy env.st.reps and visible = env.visible in
  List.iter
    (fun ((td : Iface.type_decl), _) -> Hashtbl.replace env.types td.path td)
    client;
  Hashtbl.reset env.st.reps;
  env.visible <-
    List.filter_map
      (fun (td : Iface.type_decl) ->
        match
          List.find_opt
            (fun ((c : Iface.type_decl), _) -> c.path = td.path)
            client
        with
        | Some (c, true) -> Some c
        | Some (_, false) -> None
        | None -> Some td)
      visible;
  env.client <- true;
  env.hidden <-
    List.filter_map
      (fun (td, (_, public)) -> if public then None else Some td)
      (List.combine mine client);
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (td : Iface.type_decl) -> Hashtbl.replace env.types td.path td)
        mine;
      Hashtbl.iter (Hashtbl.replace env.st.reps) reps;
      env.visible <- visible;
      env.client <- false;
      env.hidden <- [])
    f

(* Check a group of functions that call each other: each one's body, then
   what that leaves to decide once every body is checked, by the
   constraint solver; then each is generalized. Each body sees the others
   only as their declarations describe them (see [setup]). [values] are
   the module's associated values, and [main] the program's `main`, if
   the module is the program's entry. A group of test code is checked
   seeing the module through [client], unless [sees_all] (see [check]). *)
let rec check_group env ~values ~main ~client ~sees_all so_far group =
  (* a group is all test code or none of it: only test code calls test
     code (resolve.ml), so a group of both would need a call back *)
  match List.partition (fun (f : fn_def) -> f.test) group with
  | _ :: _, _ :: _ ->
      failwith "a group of functions is part test code, part not"
  | _ :: _, [] when (not sees_all) && not env.client ->
      as_client env client (fun () ->
          check_group env ~values ~main ~client ~sees_all so_far group)
  | _ -> check_own_group env ~values ~main so_far group

and check_own_group env ~values ~main so_far group =
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
  check_spelled env ~is_value so_far ms;
  check_reserved env so_far ms

(* A test's body is `Unit`, so one whose value is thrown away, like a
   comparison without its `assert`, is reported, as any other dropped
   value is. Its value is that of the last line, inside the `with` a group
   puts around it. [bodies] are the functions that are tests' bodies. *)
let check_test_body env so_far ~bodies (f : fn_def) =
  let path = Ast.fn_path env.home f in
  if List.mem path bodies then
    let rec last (e : expr) =
      match e.kind with
      | Block (_, l) -> last l
      | With { body; _ } -> last body
      | _ -> e
    in
    (* the last line's own type, which is the test's *)
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
let check_runs env r so_far ?entry ?console ~tests fns =
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
    tests;
  Option.iter
    (fun (name, real) ->
      match (find name, real) with
      | Some f, Some real ->
          let ty, cx = found f in
          check_console env r ~fns ~schemes ~withheld ~real f ty cx
      | _ -> ())
    console

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
  Hashtbl.iter (fun _ t -> close_free_needs t)
    (Hashtbl.find so_far.tables path).nodes;
  (* a use's type arguments (Infer_env.targs), what each variable of the
     callee's scheme stands for, and what the callee needs of them. A
     function of the group being checked is generic now, so what each of
     its variables stands for in the type it was used at is known. *)
  let type_args (u : Infer_env.targs) =
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
    let args : Ty.args =
      {
        tys = List.map (fun (_, t) -> canon_ty c ~all:true t) s.tys;
        rows = List.map (fun (_, r) -> canon_row c ~all:true r) s.rows;
      }
    in
    (* and what the callee needs of each, its scheme's requirements, by
       the variable each is of, as [Ty.canonical] numbers them *)
    let needs =
      List.concat
        (List.mapi
           (fun n (id, _) -> List.map (fun req -> (n, req)) (needs env.st id))
           s.tys)
    in
    (args, needs)
  in
  let ty = canon_ty c ~all:false (Hashtbl.find so_far.schemes path) in
  let scheme : Ty.scheme =
    {
      ty;
      names = canon_names c;
      reqs = canon_reqs c;
      row_reqs = canon_row_reqs c;
      modes = Iface.modes_of f.params;
      defaults = Iface.defaults_of f.params;
    }
  in
  let cx = Hashtbl.find so_far.tables path in
  (* a handler's `finally`: the body's type and its errors' row, skolems
     while it was checked, are variables of the function's now, numbered
     after its own, so lowering knows which the body's type is *)
  (match Hashtbl.find_opt env.finallies path with
  | Some (node, tid, eid) -> (
      (* what's used of the body's value, it can't have: it's any type *)
      (match needs env.st tid with
      | req :: _ -> (
          match need_at env.st tid req with
          | Some loc -> report env (finally_needs loc req ~op:(req_symbol req))
          | None -> ())
      | [] -> ());
      let v = generic_var env.st in
      Hashtbl.replace env.st.skolem_vars tid v;
      Hashtbl.replace env.st.skolem_rows eid (generic_row env.st);
      match (canon_ty c ~all:true v, Hashtbl.find_opt cx.found node) with
      | Var k, Some (Handler_facts f) ->
          Hashtbl.replace cx.found node
            (Handler_facts { f with body_ty = Some k })
      | _ -> ())
  | None -> ());
  (* a handler `over any`: its arm's call's arguments' type and result,
     and its errors' row, skolems while it was checked, are variables of
     the function's now, as a `finally`'s are, which lowering puts each
     operation's in place of (compiler.md, "`over any` and `retry`") *)
  (match Hashtbl.find_opt env.anys path with
  | Some (node, aid, rid, eid) -> (
      (* what's used of them, they can't have but `==`, which lowering
         finds for each operation's *)
      List.iter
        (fun (id, what) ->
          match List.filter (fun r -> r <> "eq") (needs env.st id) with
          | req :: _ -> (
              match need_at env.st id req with
              | Some loc -> report env (any_opaque loc ~what)
              | None -> report env (any_opaque f.name.loc ~what))
          | [] -> ())
        [ (aid, "call.args"); (rid, "call.forward()") ];
      (* its state is shared by every operation's arm, so it can't keep
         either *)
      let rec mentions id (t : ty) =
        match repr t with
        | TSkol (id', _) -> id' = id
        | TVar _ | TError -> false
        | TCon (_, ts) -> List.exists (mentions id) ts
        | TErrors r -> row_mentions id r
        | TImpl i ->
            List.exists
              (fun (d : dep) -> List.exists (mentions id) d.dargs)
              i.deps
        | TFun (ps, r, e, _) ->
            List.exists (fun (p : param) -> mentions id p.ty) ps
            || mentions id r || row_mentions id e
      and row_mentions id r =
        List.exists
          (fun (l : label) -> List.exists (mentions id) l.payload)
          (fst (row_parts r))
      in
      (match f.body.kind with
      | Handler { state; _ } ->
          List.iter
            (function
              | Let { name; _ } -> (
                  match Hashtbl.find_opt cx.locals name.id with
                  | Some t when mentions aid t ->
                      report env
                        (any_kept name.ident.loc ~name:name.ident.name
                           ~what:"call.args")
                  | Some t when mentions rid t ->
                      report env
                        (any_kept name.ident.loc ~name:name.ident.name
                           ~what:"call.forward()")
                  | _ -> ())
              | _ -> ())
            state
      | _ -> ());
      let a = generic_var env.st and r = generic_var env.st in
      let e = generic_row env.st in
      Hashtbl.replace env.st.skolem_vars aid a;
      Hashtbl.replace env.st.skolem_vars rid r;
      Hashtbl.replace env.st.skolem_rows eid e;
      match
        ( canon_ty c ~all:true a,
          canon_ty c ~all:true r,
          (canon_row c ~all:true e).tail,
          Hashtbl.find_opt cx.found node )
      with
      | Var ka, Var kr, Some ke, Some (Handler_facts facts) ->
          Hashtbl.replace cx.found node
            (Handler_facts { facts with any_vars = Some (ka, kr, ke) })
      | _ -> ())
  | None -> (
      (* only a handler `over any` makes one: it's made for what it's
         installed over, so nothing else can give one *)
      match scheme.ty with
      | Fun (_, Impl { deps; _ }, _, _)
        when List.exists Ty.is_any deps ->
          report env (any_returned f.name.loc ~name:(Ast.fn_name f))
      | _ -> ()));
  let ids =
    Hashtbl.fold (fun id _ acc -> id :: acc) cx.nodes [] |> List.sort compare
  in
  let tys =
    List.map (fun id -> canon_ty c ~all:true (Hashtbl.find cx.nodes id)) ids
  in
  (* what a lookup found, its dependencies' type arguments in canonical
     form too *)
  let label (l : label) : Ty.label =
    { name = l.name; payload = List.map (canon_ty c ~all:true) l.payload }
  in
  let found id : Ty.label found_ option =
    Option.map
      (function
        | Installs { key; from } -> Installs { key = label key; from }
        | Installs_handler ls -> Installs_handler (List.map label ls)
        | Calls_op { key; from; op } -> Calls_op { key = label key; from; op }
        | Inline_op o -> Inline_op o
        | Block { name; given } -> Block { name; given = List.map label given }
        | Field_of p -> Field_of p
        | Ctor_of (p, c) -> Ctor_of (p, c)
        | Error_tag -> Error_tag
        | Method_of p -> Method_of p
        | Install_order is -> Install_order is
        | Handler_facts f -> Handler_facts f
        | Handles -> Handles
        | Fail_arm -> Fail_arm
        | Unwrap -> Unwrap
        | Builtin_op -> Builtin_op
        | Generic_op o -> Generic_op o
        | Tags_given ts -> Tags_given ts
        | Args xs -> Args xs)
      (Hashtbl.find_opt cx.found id)
  in
  let nodes =
    List.fold_left2
      (fun acc id ty ->
        let used = Option.map type_args (Hashtbl.find_opt cx.targs id) in
        Nodes.add id
          {
            ty;
            found = found id;
            narrowed = Hashtbl.find_opt cx.narrowed id;
            coerce = Hashtbl.find_opt cx.coerced id;
            targs = Option.map fst used;
            needs = Option.fold ~none:[] ~some:snd used;
          }
          acc)
      Nodes.empty ids tys
  in
  ((path, scheme), (path, nodes))

(* ---- blocks are second-class (foundations.md, "Lambdas are blocks") ----

   A block, a value of a function type, lives only as long as the call
   it's passed to. So a function-typed expression may only be called,
   passed as an argument, or be the value of a `let` that is one block
   written right there, `let f = fn(x) => x + 1`. Anywhere else, in a
   record, a constructor, an array or a tuple, as an `if`'s or a
   `match`'s value, a result, a `var`, a handler's state or a handler's
   argument, or compared, it's an error. Written types are checked before
   inference (resolve.ml, [no_kept_blocks]); this is the walk over what
   inference found, one per function, through each node's type.

   A type variable never stands for a block either: `T` could be stored.
   That's checked over the type arguments each use picked, rather than in
   unification, so the error can say where the block was given.

   As in Effekt, whose blocks are second-class too: its typer keeps a
   block from being returned or stored by checking where each one is
   used (effekt/shared/src/main/scala/effekt/Typer.scala:572-615 and
   1015-1084), rather than with lifetimes.

   A parameter of a dependency's type, `c: Clock`, is transparent: what
   it needs flows into the caller, so it can only be installed, `with c in
   ...`, or passed straight on (deps.md, "Implementations"). The same
   walk checks that, until descriptions replace it (stage 10d). *)

(* Where an expression is, as far as a block in it goes. *)
type place =
  | Callee
  | Arg
  | Handler_arg  (** an argument of a call of one of the module's handlers *)
  | Let_value of string  (** the value of `let name = ...` *)
  | Install  (** an item of a `with` *)
  | Receiver  (** `x` in `x.f` *)
  | Said  (** a block here is reported already, by what it's part of *)
  | Kept of Infer_msg.block_place

(* Whether [t] has a function type in it anywhere. *)
let rec has_fun (t : Ty.ty) =
  match t with
  | Fun _ -> true
  | Con (_, args) -> List.exists has_fun args
  | Errors r ->
      List.exists (fun (l : Ty.label) -> List.exists has_fun l.payload) r.labels
  | Var _ | Impl _ | Error -> false

(* Whether [t] is a scope or a task's handle, blocks too (rule D,
   compiler.md, "Stage 11a", "The checker"), and whether it has one in
   it anywhere. *)
let is_handle (t : Ty.ty) =
  match t with
  | Con (p, []) -> p = Path.prelude "Scope"
  | Con (p, [ _ ]) -> p = Path.prelude "Task"
  | _ -> false

let rec has_handle (t : Ty.ty) =
  is_handle t
  ||
  match t with
  | Con (_, args) -> List.exists has_handle args
  | Fun _ | Errors _ | Var _ | Impl _ | Error -> false

(* Whether a value of type [t] keeps a block: in a type's arguments or
   an error's payload. A function that returns one is reported where
   it's declared. *)
let keeps_block (t : Ty.ty) =
  match t with
  | Con _ | Errors _ -> has_fun t
  | Fun _ | Var _ | Impl _ | Error -> false

(* Whether two places in the source overlap. *)
let overlap (a : Loc.t) (b : Loc.t) =
  let pos (p : Loc.pos) = (p.line, p.col) in
  a.file = b.file
  && compare (pos a.start) (pos b.stop) <= 0
  && compare (pos b.start) (pos a.stop) <= 0

(* Check [f]'s blocks, given [nodes], what inference found of its
   expressions, and [scheme_of], the type scheme of a function it uses,
   if it's known. [handlers] are the module's handlers. A `ren console`
   session's function, [shown], gives its last line's value to be shown,
   which may be a block. [value] says [f] is an associated value. *)
let check_blocks env (r : Resolve.t) ~scheme_of ~handlers ~shown ~value
    (f : fn_def) nodes =
  let ty id =
    match Nodes.find_opt id nodes with Some n -> n.ty | None -> Ty.Error
  in
  let is_block (e : expr) = match ty e.node with Fun _ -> true | _ -> false in
  let found = ref [] and generic = ref [] in
  let say loc d = found := (loc, d) :: !found in
  (* a block given where a type variable of what's used at [e] stands for
     it: the name of that variable, if it's known *)
  let generic_at (e : expr) =
    match Option.bind (Nodes.find_opt e.node nodes) (fun n -> n.targs) with
    | Some (a : Ty.args) -> (
        let rec first i = function
          | t :: rest -> if has_fun t then Some i else first (i + 1) rest
          | [] -> None
        in
        match first 0 a.tys with
        | None -> None
        | Some i ->
            let callee =
              match e.kind with
              | Var (Global p | Global_value p) -> Some p
              | _ -> None
            in
            (* named as `ren types` names it: declared, or T, U, ... in
               the order its type shows them *)
            let name (s : Ty.scheme) =
              let pr = Ty.printer ~names:env.names s in
              Ty.reserve pr s.ty;
              ignore (Ty.show pr s.ty);
              Ty.show pr (Var i)
            in
            Some (Option.map name (Option.bind callee scheme_of)))
    | None -> None
  in
  (* how a scope's or a handle's type is written, for a message *)
  let shown_handle (t : Ty.ty) : Infer_msg.handle =
    match t with
    | Con (_, []) -> Scope_of
    | _ ->
        Handle
          (Ty.show
             (Ty.printer ~names:env.names
                { ty = t; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] })
             t)
  in
  let rec handle_in (t : Ty.ty) =
    if is_handle t then Some t
    else match t with Con (_, args) -> List.find_map handle_in args | _ -> None
  in
  let prelude = env.home = Path.prelude_home in
  let generic_here (e : expr) ~blame =
    match generic_at e with
    | Some tvar ->
        generic := (blame, Infer_msg.generic_block blame ~tvar) :: !generic
    | None -> (
        (* nor for a scope or a task's handle *)
        match Option.bind (Nodes.find_opt e.node nodes) (fun n -> n.targs) with
        | Some (a : Ty.args) when not prelude -> (
            match List.find_map handle_in a.tys with
            | Some h ->
                generic :=
                  ( blame,
                    Infer_msg.handle_kept ~written:false blame (shown_handle h)
                      In_type_arg )
                  :: !generic
            | None -> ())
        | _ -> ())
  in
  (* the parameters of a dependency's type, which are transparent *)
  let dep_params =
    List.filter_map
      (fun (p : Resolved.param) ->
        match p.pty with
        | Some (TyImpl { impl_deps = ds; impl_uses = None; _ })
          when p.pname.ident.name <> "self" ->
            Some
              ( p.pname.id,
                String.concat " & "
                  (List.map (fun (d : Path.t) -> d.name) (Iface.dep_paths ds))
              )
        | _ -> None)
      f.params
  in
  let handler_deps =
    match f.body.kind with
    | Handler { deps; _ } ->
        Some
          (List.filter_map
             (fun (d : tname dep_ref) ->
               match d.dep.tref with Named p -> Some p.name | _ -> None)
             deps)
    | _ -> None
  in
  let escaped = ref [] in
  let dep_param pos (e : expr) =
    match (e.kind, pos) with
    | Var (Local b), (Kept _ | Let_value _ | Said)
      when List.mem_assoc b.id dep_params && not (List.mem b.id !escaped) ->
        escaped := b.id :: !escaped;
        say e.loc
          (Infer_msg.not_transparent e.loc ~name:b.ident.name
             ~dep:(List.assoc b.id dep_params)
             ~handler_deps)
    | _ -> ()
  in
  (* how a block is written where a `let` can't bind it: the function it
     names, and how many parameters that takes *)
  let arity (e : expr) =
    match ty e.node with Fun (ps, _, _, _) -> List.length ps | _ -> 0
  in
  let name_of (e : expr) =
    match e.kind with
    | Var (Local b) -> Some b.ident.name
    | Var (Global p | Global_value p) -> Some (Resolve.value_name r p)
    | Var (Dep_op (p, op)) -> Some (env.names p ^ "." ^ op)
    | Var (Intrinsic x) -> Some (Intrinsic.name x)
    | _ -> None
  in
  (* the blocks an `if` or a `match` chooses between, by name *)
  let chosen (e : expr) =
    let values =
      match e.kind with
      | If (_, t, f) -> t :: Option.to_list f
      | Match (_, arms) -> List.map (fun (a : arm) -> a.arm_body) arms
      | _ -> []
    in
    match List.filter_map name_of values with
    | a :: b :: _ -> (a, b)
    | _ -> ("f", "g")
  in
  (* the block [e] itself, at [pos] *)
  let here pos (e : expr) =
    match (e.kind, pos) with
    | (Block _ | With _ | Call _ | Index _ | Field _ | Try _ | Attempt _), _ ->
        (* its value is said where it's made *)
        ()
    | _, (Said | Callee | Install | Receiver) -> ()
    | (Lambda _ | Var _), Arg -> ()
    | Lambda _, Let_value _ -> ()
    | _, Arg -> say e.loc (Infer_msg.block_kept ~written:false e.loc Branch)
    | _, Let_value name ->
        let how =
          match name_of e with
          | Some f -> Infer_msg.Let_named f
          | None ->
              let f, g = chosen e in
              Infer_msg.Let_chosen (f, g)
        in
        say e.loc (Infer_msg.let_not_literal e.loc ~name ~arity:(arity e) how)
    | _, Handler_arg -> say e.loc (Infer_msg.handler_param_block e.loc)
    | _, Kept place ->
        say e.loc (Infer_msg.block_kept ~written:false e.loc place)
  in
  (* a scope or a task's handle [h], [e], at [pos]: it can be passed, a
     callee's receiver, or the value of a `let`; elsewhere it's kept. What
     an indented block, a `with`, an `if` or a `match` gives is said at
     the part that gives it *)
  let here_handle pos (e : expr) =
    match (handle_in (ty e.node), e.kind, pos) with
    | None, _, _ -> ()
    | Some _, _, _ when prelude || is_block e -> ()
    | Some _, (Block _ | With _ | If _ | Match _), _ -> ()
    | Some _, _, (Said | Callee | Install | Receiver | Arg | Let_value _) -> ()
    | Some h, _, Handler_arg ->
        say e.loc (Infer_msg.handle_kept ~written:false e.loc (shown_handle h) Elsewhere)
    | Some h, _, Kept place ->
        let place =
          (* one inside another type is that type's argument *)
          if is_handle (ty e.node) then place else Infer_msg.In_type_arg
        in
        say e.loc (Infer_msg.handle_kept ~written:false e.loc (shown_handle h) place)
  in
  (* where the block a `with` or an indented block gives is: a `let`
     binds, and a call is given, one written there, so one that would
     run after the `with` has ended, or its lines' `finally`s have run, is
     kept past them *)
  let past pos place =
    match pos with
    | Arg | Callee | Receiver | Let_value _ -> Kept place
    | Handler_arg | Install | Said | Kept _ -> pos
  in
  let rec walk pos (e : expr) =
    let block = is_block e in
    if block then here pos e else here_handle pos e;
    dep_param pos e;
    if pos <> Callee then generic_here e ~blame:e.loc;
    (* what a part that gives this expression's value is at *)
    let carried = if block then Said else Kept Elsewhere in
    let all place = List.iter (walk (Kept place)) in
    match e.kind with
    | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break | Tag_set _ -> ()
    | Named (_, a) -> walk pos a
    | Call (callee, args) ->
        (* a block a type variable of the callee stands for is blamed on
           the argument that gives it *)
        let blame =
          match List.find_opt (fun (a : expr) -> has_fun (ty a.node)) args with
          | Some a -> a.loc
          | None -> callee.loc
        in
        generic_here callee ~blame;
        walk Callee callee;
        (* a handler's parameters are data: one whose type has a block in
           it is reported where it's declared *)
        let arg_place i =
          match callee.kind with
          | Var (Global p) when List.mem p handlers -> (
              match Option.map (fun (s : Ty.scheme) -> s.ty) (scheme_of p) with
              | Some (Fun (ps, _, _, _)) -> (
                  match List.nth_opt ps i with
                  | Some q when has_fun q.ty -> Said
                  | _ -> Handler_arg)
              | _ -> Handler_arg)
          | _ -> Arg
        in
        List.iteri (fun i a -> walk (arg_place i) a) args
    | Lambda (_, body) -> walk (Kept Returned) body
    | Block (stmts, last) ->
        List.iter (stmt ~state:false) stmts;
        walk (if block then past pos Past_lines else Kept Elsewhere) last
    | With { items; body } ->
        List.iter (walk Install) (with_links items);
        walk (if block then past pos Past_with else Kept Elsewhere) body
    | If (c, t, f) ->
        walk (Kept Elsewhere) c;
        List.iter (walk carried) (t :: Option.to_list f)
    | Match (s, arms) ->
        walk (Kept Elsewhere) s;
        List.iter
          (fun (a : arm) ->
            Option.iter (walk (Kept Elsewhere)) a.arm_guard;
            walk carried a.arm_body)
          arms
    | Try a | Attempt a -> walk carried a
    | Binop ((Eq | Neq), a, b, _) when is_block a || is_block b ->
        say e.loc (Infer_msg.block_kept ~written:false e.loc Compared);
        List.iter (walk Said) [ a; b ]
    | Binop (_, a, b, _) -> all Elsewhere [ a; b ]
    | Unop (_, a, _) | Ref a | Assert a | Index (a, _) -> (
        walk (Kept Elsewhere) a;
        match e.kind with Index (_, i) -> walk (Kept Elsewhere) i | _ -> ())
    | Slice (a, lo, hi) -> all Elsewhere [ a; lo; hi ]
    | Field (a, _) -> walk Receiver a
    | Assign { target; value; _ } ->
        (* a `var` or a field that holds a block is reported where it's
           declared *)
        List.iter (walk Said) [ target; value ]
    | Array xs ->
        if List.exists is_block xs then
          say e.loc (Infer_msg.block_kept ~written:false e.loc In_array)
        else if (not prelude) && List.exists (fun (x : expr) -> handle_in (ty x.node) <> None) xs
        then
          say e.loc
            (Infer_msg.handle_kept ~written:false e.loc
               (shown_handle
                  (List.find_map (fun (x : expr) -> handle_in (ty x.node)) xs |> Option.get))
               In_array);
        List.iter (walk Said) xs
    | Tuple xs -> all In_tuple xs
    | Con (c, args) -> all (In_payload c.name.name) (List.map snd args)
    | Con_named (c, fields) -> all (In_payload c.name.name) (List.map snd fields)
    | Record (name, fields) ->
        (* a record of a dependency's operations: inference reports it, as
           a handler to write *)
        let of_dep =
          match (name, ty e.node) with
          | _, Impl _ -> true
          | Some { tref = Named p; _ }, _ -> (
              match Hashtbl.find_opt env.types p with
              | Some { Iface.body = Dep _; _ } -> true
              | _ -> false)
          | _ -> false
        in
        if of_dep then List.iter (walk Said) (List.map snd fields)
        else all In_record (List.map snd fields)
    | Update { base; fields; _ } -> all In_record (base :: List.map snd fields)
    | Fail (_, args) -> all In_error (List.map snd args)
    | For _ | While _ -> all Elsewhere (Ast.children e)
    | Inline_handler l ->
        (* its arm is a block the handler is made of *)
        walk Arg l
    | Handler { state; arms; _ } ->
        List.iter (stmt ~state:true) state;
        (* an arm is a block the handler is made of *)
        List.iter (walk Arg)
          (List.map (fun (a : handler_arm) -> a.arm_impl) arms)
  and stmt ~state = function
    | Let { name; value; mut; _ }
      when (state || mut) && (not prelude) && handle_in (ty value.node) <> None ->
        say name.ident.loc
          (Infer_msg.handle_kept ~written:false name.ident.loc
             (shown_handle (Option.get (handle_in (ty value.node))))
             (if state then In_state else In_var));
        walk Said value
    | Let { name; value; mut; _ } when (state || mut) && is_block value ->
        (* at its name: `var f`, or a handler's `let` or `var` *)
        say name.ident.loc
          (Infer_msg.block_kept ~written:false name.ident.loc
             (if state then In_state else In_var));
        walk Said value
    | Let { name; value; _ } ->
        walk (if state then Kept Elsewhere else Let_value name.ident.name) value
    | Let_pattern { value; else_; _ } ->
        walk (Kept Elsewhere) value;
        Option.iter (walk (Kept Elsewhere)) else_
    | Expr e -> walk (Kept Elsewhere) e
    | Finally f ->
        (* a block the handler, or its arm, is made of *)
        walk Arg f
  in
  walk
    (if shown then Said
     else if value then Kept (In_value f.name.name)
     else Kept Returned)
    f.body;
  (* a handler's parameter whose type inference found has a block in it *)
  (if Ast.is_handler f then
     match
       Option.map
         (fun (s : Ty.scheme) -> s.ty)
         (scheme_of (Ast.fn_path env.home f))
     with
     | Some (Fun (ps, _, _, _)) ->
         List.iter2
           (fun (p : Resolved.param) (q : Ty.param) ->
             if has_fun q.ty then
               let loc = p.pname.ident.loc in
               say loc
                 (Infer_msg.handler_param_block ~name:p.pname.ident.name loc))
           f.params ps
     | _ -> ());
  let found = List.rev !found in
  List.iter (fun (_, d) -> report env d) found;
  (* a block a type variable stands for, where it isn't said already *)
  let generic =
    List.fold_left
      (fun acc (loc, d) ->
        if List.exists (fun (l, _) -> overlap l loc) (found @ acc) then acc
        else acc @ [ (loc, d) ])
      [] (List.rev !generic)
  in
  List.iter (fun (_, d) -> report env d) generic;
  (* and if nothing's said yet, any other expression that keeps one *)
  if found = [] && generic = [] then
    let rec first (e : expr) =
      if keeps_block (ty e.node) then Some e
      else List.find_map first (Ast.children e)
    in
    Option.iter
      (fun (e : expr) -> report env (Infer_msg.generic_block e.loc ~tvar:None))
      (first f.body)

(* Infer every function's type, and return each function's type scheme and
   the types of its expressions, in canonical form. [imports] are the
   interfaces of the modules it imports, whose functions it can call, and
   [reachable] those of every module reachable through them, whose types
   it can meet: a field of an imported type can have a type from a module
   this one never imported. [extra] are the dot calls of methods found so
   far that the call graph needs besides [r]'s (see [program]). With
   [sees_all], test code sees the whole module, as Resolve let it
   (Resolve.program). *)
let check sink ~extra ~imports ~reachable ?entry ?console ~sees_all ~tests
    ~bodies (r : Resolve.t) =
  let env = new_env sink ~reachable r in
  let home = r.home in
  check_written sink ~sets:env.sets ~names:env.names r.prog;
  (* the module's functions, its types' members included; an associated
     value is checked as a function of no parameters (ast.ml) *)
  let fns = Ast.functions r.prog in
  add_globals env ~imports ~reachable fns;
  (* which parameters each function writes a type for, which a call's
     arguments are narrowed to (Infer_written.written_params) *)
  List.iter
    (fun (f : fn_def) ->
      Hashtbl.replace env.written (Ast.fn_path r.home f)
        (List.map (fun (p : Resolved.param) -> p.pty <> None) f.params);
      Hashtbl.replace env.params_of (Ast.fn_path r.home f)
        (List.map (fun (p : Resolved.param) -> p.pname.ident.name) f.params);
      Hashtbl.replace env.defaults_of (Ast.fn_path r.home f)
        (given_defaults
           ~method_:
             (match f.params with
             | p :: _ -> p.pname.ident.name = "self"
             | [] -> false)
           (Iface.defaults_of f.params)))
    fns;
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
  (* a key that leads back to its own type *)
  List.iter
    (function
      | Type td ->
          List.iter
            (fun (o : op) ->
              let p = Path.make home td.type_name.name in
              if o.op_fn.name.name = "key" && Infer_reqs.key_loops env p then
                report env
                  (Infer_msg.key_loops o.op_fn.name.loc ~owner:td.type_name.name))
            td.type_ops
      | Fn _ | Import _ | Testing _ -> ())
    r.prog;
  let so_far =
    { schemes = Hashtbl.create 16; tables = Hashtbl.create 16; withheld = [] }
  in
  let main = Option.map (fun _ -> Path.make home "main") entry in
  let client = client_view env r in
  List.iter
    (check_group env ~values ~main ~client ~sees_all so_far)
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
  check_keeps_rules env so_far r;
  let values = value_order env r fns ~is_value ~found:so_far.tables in
  List.iter
    (check_test_body env so_far ~bodies:(List.map (Path.make home) bodies))
    fns;
  check_runs env r so_far ?entry ?console ~tests fns;
  let schemes, nodes = List.split (List.map (canonical env so_far) fns) in
  (* the type scheme of a function a use names: the module's own, or an
     imported one's, or a member's of a type it can meet *)
  let scheme_of (p : Path.t) =
    match List.assoc_opt p schemes with
    | Some s -> Some s
    | None -> (
        match p.member with
        | None ->
            List.find_map
              (fun (i : Iface.t) ->
                if i.home = p.home then
                  Option.map
                    (fun (v : Iface.value) -> v.scheme)
                    (Iface.find_value i p.name)
                else None)
              imports
        | Some _ ->
            List.find_map
              (fun (i : Iface.t) ->
                List.find_map
                  (fun (td : Iface.type_decl) ->
                    Option.map
                      (fun (o : Iface.op) -> o.oscheme)
                      (Path.Map.find_opt p td.members))
                  i.types)
              reachable)
  in
  let handlers =
    List.filter_map
      (fun (f : fn_def) ->
        if Ast.is_handler f then Some (Ast.fn_path home f) else None)
      fns
  in
  List.iter2
    (fun (f : fn_def) (_, n) ->
      let shown =
        match console with
        | Some (name, _) -> f.name.name = name
        | None -> false
      in
      check_blocks env r ~scheme_of ~handlers ~shown ~value:(is_value f) f n)
    fns nodes;
  (* an associated value is made once, so it's given no dictionaries: a
     value of its type variable is compared by its shape alone (walk.ml),
     but nothing else can be done with one *)
  List.iter2
    (fun (f : fn_def) (path, (s : Ty.scheme)) ->
      match List.filter (fun (_, r) -> r <> "eq" && r <> "hash") s.reqs with
      | (_, req) :: _ when List.mem path values ->
          report env
            (value_needs f.name.loc ~value:(Ast.fn_name f)
               ~what:(Infer_msg.req_symbol req))
      | _ -> ())
    fns schemes;
  {
    schemes = Path.Map.of_list schemes;
    values;
    nodes = Path.Map.of_list nodes;
    in_scope = List.sort compare env.in_scope;
    opaque_eq =
      List.filter_map
        (fun (td : Iface.type_decl) ->
          if td.opaque && Infer_reqs.opaque_has_eq env td.path then Some td.path
          else None)
        r.types;
    opaque =
      List.sort compare
        (Hashtbl.fold
           (fun (p : Path.t) (td : Iface.type_decl) acc ->
             match td.body with
             | _ when p.home = Path.prelude_home -> acc
             | Opaque _ -> p :: acc
             | _ when td.opaque -> p :: acc
             | _ -> acc)
           env.types []);
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
let program sink ~imports ~reachable ?entry ?console ?(sees_all = false)
    ?(tests = []) ?(bodies = []) (r : Resolve.t) =
  let rec go extra =
    let tried = Diag.sink () in
    let keep () = List.iter (Diag.report sink) (List.rev tried.reported) in
    match
      check tried ~extra ~imports ~reachable ?entry ?console ~sees_all ~tests
        ~bodies r
    with
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
