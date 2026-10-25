(* Inference over a whole module (see infer.ml): the call graph, groups of
   functions that call each other, generalization, transparent parameters,
   and what public functions and `main` have to spell out. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_expr

(* ---- the call graph ---- *)

(* Group functions into strongly connected components of the call graph,
   callees before callers (Tarjan's algorithm, which finishes a component
   only after every component it reaches). [calls] lists the top-level
   functions each function uses, which resolve.ml found. *)
let components ~home ~calls (fns : fn_def list) =
  let by_name = Hashtbl.create 16 in
  List.iter (fun (f : fn_def) -> Hashtbl.replace by_name f.name.name f) fns;
  let callees (f : fn_def) =
    List.assoc f.name.name calls
    |> List.filter_map (fun (p : Path.t) ->
        if p.home = home then Hashtbl.find_opt by_name p.name else None)
  in
  let index = Hashtbl.create 16 and low = Hashtbl.create 16 in
  let stack = ref [] and on_stack = Hashtbl.create 16 in
  let counter = ref 0 and result = ref [] in
  let rec visit (f : fn_def) =
    let v = f.name.name in
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    incr counter;
    stack := f :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter
      (fun (g : fn_def) ->
        let w = g.name.name in
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
            Hashtbl.remove on_stack g.name.name;
            if g.name.name = v then g :: acc else pop (g :: acc)
        | [] -> assert false
      in
      let group = pop [] in
      (* keep source order inside a group, for stable error messages *)
      let pos (g : fn_def) = (g.loc.start.line, g.loc.start.col) in
      result := List.sort (fun a b -> compare (pos a) (pos b)) group :: !result
  in
  List.iter (fun f -> if not (Hashtbl.mem index f.name.name) then visit f) fns;
  List.rev !result

(* ---- transparent parameters ----

   A parameter whose type is written `fn(...)` is transparent: its errors
   and dependencies flow into the caller, so they're never written. That's
   only true if the function just calls it, or passes it straight on to
   another function. Storing it, returning it, or capturing it in a lambda
   that escapes would let it outlive the call. *)

let check_transparent sink (f : fn_def) =
  let fn_params =
    List.filter_map
      (fun (p : Resolved.param) ->
        match p.pty with Some (TyFn _) -> Some p.pname | _ -> None)
      f.params
  in
  List.iter
    (fun (param : binder) ->
      let name = param.ident.name in
      let fail loc what =
        Diag.error loc
          ~notes:
            [
              "a parameter whose type is written `fn(...)` can only be called, \
               or passed straight to another function";
            ]
          ~help:
            (sprintf
               "remove the type from `%s` and let it be inferred, so its \
                errors and dependencies are tracked wherever it goes"
               name)
          (sprintf "`%s` %s, so it isn't transparent" name what)
      in
      let is_param = function Local b -> b.id = param.id | _ -> false in
      (* does [e] use the parameter anywhere? *)
      let rec mentions (e : expr) =
        let any = List.exists mentions in
        match e.kind with
        | Var x -> is_param x
        | Int _ | Bool _ | Unit -> false
        | Unop (_, a) | Field (a, _) | Ref a | Lambda (_, a) -> mentions a
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
      in
      (* [ok]: this position may hold the bare parameter, or a lambda that
         captures it *)
      let rec walk ~ok (e : expr) =
        let walk_all = List.iter (walk ~ok:false) in
        match e.kind with
        | Var x when is_param x ->
            if not ok then fail e.loc "is used as a value here"
        | Int _ | Bool _ | Unit | Var _ -> ()
        | Call (callee, args) ->
            walk ~ok:true callee;
            List.iter (walk ~ok:true) args
        | Lambda (_, body) ->
            if (not ok) && mentions body then
              fail e.loc "is captured by a lambda that outlives the call"
            else walk ~ok:false body
        | Unop (_, a) | Field (a, _) | Ref a -> walk_all [ a ]
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
      in
      Diag.recover sink ~default:() (fun () -> walk ~ok:false f.body))
    fn_params

(* ---- the program ---- *)

(* Infer every function's type, and return each function's type scheme, in
   canonical form. *)
let program sink ~imports ?entry (r : Resolve.t) =
  let st = Types.new_state () in
  let home = r.home in
  let env =
    {
      st;
      sink;
      home;
      types = Hashtbl.create 16;
      ctors = Hashtbl.create 16;
      globals = Hashtbl.create 16;
      deferred = [];
    }
  in
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.globals
            (Path.make iface.home v.vname)
            (of_scheme st v.scheme))
        iface.values)
    imports;
  let fns =
    List.filter_map (function Fn f -> Some f | Type _ -> None) r.prog
  in
  let path (f : fn_def) = Path.make home f.name.name in
  List.iter
    (fun (td : Iface.type_decl) ->
      Hashtbl.replace env.types td.path td;
      match td.body with
      | Sum cs ->
          List.iter
            (fun (c : Iface.ctor) -> Hashtbl.replace env.ctors c.cname (td, c))
            cs
      | Record _ | Builtin -> ())
    (List.concat_map (fun (iface : Iface.t) -> iface.types) imports @ r.types);
  List.iter (check_transparent sink) fns;
  let schemes = Hashtbl.create 16 in
  List.iter
    (fun group ->
      enter_level env.st;
      (* each function's type within the group: its own type parameters
         (as skolems), parameters, result and effects *)
      let setup (f : fn_def) =
        let skolems =
          List.map (fun (t : ident) -> (fresh_id env.st, t.name)) f.tparams
        in
        let tparams = List.map (fun (id, n) -> TSkol (id, n)) skolems in
        let cx =
          {
            locals = Hashtbl.create 16;
            errs = fresh_row env.st;
            uses = fresh_row env.st;
            tparams;
          }
        in
        let ps = List.map (param_type env cx) f.params in
        let ret =
          match f.ret with
          | Some t -> convert ~tvars:tparams ~row:closed t
          | None when f.pub ->
              unit (* a public function without `->` returns Unit *)
          | None -> fresh_var env.st
        in
        Hashtbl.replace env.globals (path f) (TFun (ps, ret, cx.errs, cx.uses));
        (f, skolems, cx, ps, ret)
      in
      let setups = List.map setup group in
      List.iter
        (fun ((f : fn_def), _, cx, ps, ret) ->
          bind_params cx f.params ps;
          let tb = infer env cx f.body in
          let pr = printer env in
          let notes, help =
            match f.ret with
            | Some _ ->
                ( [
                    sprintf "`%s` is declared to return `%s`" f.name.name
                      (show pr ret);
                  ],
                  None )
            | None when f.pub ->
                ( [ "a public function without `->` returns `Unit`" ],
                  Some (sprintf "add `-> %s` to the signature" (show pr tb)) )
            | None -> ([], None)
          in
          unify_at env (result_loc f.body) ~found:tb ~expected:ret ~notes ?help)
        setups;
      resolve_deferred env;
      leave_level env.st;
      List.iter
        (fun ((f : fn_def), skolems, _, _, _) ->
          let mono = Hashtbl.find env.globals (path f) in
          (match
             List.filter
               (fun (id, _) -> not (List.mem_assoc id skolems))
               (Types.skolems mono)
           with
          | (id, t) :: _ ->
              let owner =
                List.find (fun (_, sk, _, _, _) -> List.mem_assoc id sk) setups
              in
              let (o : fn_def), _, _, _, _ = owner in
              let declared =
                List.find (fun (p : ident) -> p.name = t) o.tparams
              in
              ignore
              @@ fail env f.name.loc
                   ~labels:[ (declared.loc, sprintf "`%s` is declared here" t) ]
                   ~notes:
                     [
                       sprintf
                         "`%s` and `%s` call each other, and functions that \
                          call each other are checked at a single type"
                         f.name.name o.name.name;
                     ]
                   ~help:
                     (sprintf
                        "remove the type parameter from `%s`, or break the \
                         cycle"
                        o.name.name)
                   (sprintf
                      "`%s` would have to use `%s`, the type parameter of `%s`"
                      f.name.name t o.name.name)
          | [] -> ());
          let scheme = generalize env.st ~skolems mono in
          Hashtbl.replace env.globals (path f) scheme;
          Hashtbl.replace schemes f.name.name scheme)
        setups;
      (* public functions spell out their full contract *)
      List.iter
        (fun ((f : fn_def), _, _, _, _) ->
          if f.pub then
            match Hashtbl.find schemes f.name.name with
            | TFun (ps, _, _, _) as scheme ->
                List.iter2
                  (fun (p : Resolved.param) (t : Types.param) ->
                    if p.pty = None then (
                      let pr = printer env in
                      reserve pr scheme;
                      let name = p.pname.ident in
                      ignore
                      @@ fail env name.loc
                           ~help:
                             (sprintf "write `%s: %s`" name.name (show pr t.ty))
                           ~notes:
                             [
                               "public functions spell out their full signature";
                             ]
                           (sprintf
                              "the parameter `%s` of the public function `%s` \
                               has no type"
                              name.name f.name.name)))
                  f.params ps
            | _ -> assert false)
        setups)
    (components ~home ~calls:r.calls fns);
  (match
     Option.map
       (fun file ->
         (file, List.find_opt (fun (f : fn_def) -> f.name.name = "main") fns))
       entry
   with
  | None -> ()
  | Some (file, None) ->
      ignore
        (fail env (Loc.point ~file 1 1)
           ~help:"add `fn main() = ...`, which is where the program starts"
           "this program has no `main` function")
  | Some (_, Some f) when f.params <> [] ->
      ignore
        (fail env (List.hd f.params).pname.ident.loc
           ~help:"remove the parameters" "`main` can't take parameters")
  | Some _ -> ());
  List.map
    (fun f -> (f.name.name, to_scheme st (Hashtbl.find schemes f.name.name)))
    fns
