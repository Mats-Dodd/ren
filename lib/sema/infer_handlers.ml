(* Handlers and `with` (see infer_expr.ml; deps.md): a handler's body,
   and a `with` that installs an implementation or wraps its body. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written
open Infer_lookup
open Infer_rows

(* The core of inference, from infer_expr.ml, which a handler's state and
   arms and a `with`'s item and body are checked with. infer_expr.ml calls
   this module, and this module calls those functions back; two OCaml
   files can't each refer to the other, so infer_expr.ml passes them in, in
   a record, as the first argument of [handler] and [with_]. A record
   field's type can have labelled and optional arguments, as a function's
   can. *)
type core = {
  infer : env -> ctx -> expr -> ty;
  check : env -> ctx -> ?why:why -> ?written:ty -> expr -> ty -> unit;
  stmt : env -> ctx -> stmt -> unit;
  infer_call :
    env -> ctx -> ?changed:Loc.t -> ?tr:ty -> expr -> expr -> expr list -> ty;
  call_with : env -> ctx -> expr -> expr -> ty -> expr list -> ty;
  check_args :
    env ->
    ctx ->
    name:string option ->
    ?callee:Path.t ->
    written:bool list ->
    Types.param list ->
    expr list ->
    unit;
}

(* The dependencies a handler of [deps] implements, whose type its body
   gives (Types.impl_type): the dependency's, if it implements one, or the
   type that lists them. *)
let handler_deps (deps : tname list) =
  List.filter_map
    (fun (d : tname) -> match d.tref with Named p -> Some p | Param _ -> None)
    deps

(* A handler's body (ast.ml, [Handler]), the body of its function,
   [cx.self], whose result is the handler's type ([handler_deps]). Its
   state and its arms run where it's installed, not where the function is
   called, so what they use is what the handler needs, [needs], and the
   function itself uses nothing. Its state is made when it's installed,
   which can't fail. Each arm is checked as an implementation's operation
   is ([infer_record]): it uses what the handler needs, and can fail with
   fewer errors than its operation declares, never more. What it needs is
   checked once the group is done, against what's [declared], if anything
   is (see [handler_needs]). *)
let rec handler core env cx state arms ~needs ~declared =
  let hcx = lambda_cx cx [] [] ~errs:REmpty ~uses:needs in
  env.in_state <- true;
  List.iter (core.stmt env hcx) state;
  env.in_state <- false;
  List.iter
    (fun (a : handler_arm) ->
      let op =
        match a.arm_op with
        | Dep_op (p, op) -> (
            match dep_op_in op (Hashtbl.find env.types p) with
            | Some fd -> (
                match field_type env ~tvars:[] fd with
                | TFun (ps, r, errs, _, l) -> Some (p, op, ps, r, errs, l)
                | _ -> None)
            | None -> None)
        | _ -> None
      in
      match (op, a.arm_impl.kind) with
      | Some (p, op, ps, r, errs, l), Lambda (params, body)
        when List.length params = List.length ps ->
          let declared = fst (row_parts errs) in
          (* what it fails with, which is its own until the group is done:
             one of its parameters' errors passed on with `try` ends in
             it, and then can fail with what the operation can *)
          let open_errs = fresh_row env.st in
          defer env
            (Impl_op
               {
                 idep = p;
                 iop = op;
                 ideclared = declared;
                 ierrs = open_errs;
                 ivalue = a.arm_impl;
                 inodes = cx.nodes;
               });
          (* checked as a lambda is, against the operation, but what its
             calls use is what the handler needs, and they're the
             handler's calls, so a message can point at one *)
          let notes = [ part_of (type_name env p) "operation" op ] in
          let why = explain ~notes () in
          (* its result reads as a record implementation's lambda's does *)
          let result_why = explain ~notes ~msg:arm_produces () in
          let qs =
            List.map2
              (fun (q : Resolved.param) eq ->
                if q.pty = None then eq
                else param_type env ~tparams:cx.tparams ~named:cx.named q)
              params ps
          in
          let lams = lambda_set env cx a.arm_impl.node in
          bind_params hcx params qs;
          let acx =
            {
              (lambda_cx hcx params qs ~errs:open_errs ~uses:needs) with
              calls = hcx.calls;
            }
          in
          core.check env acx body r ~why:result_why;
          let t = TFun (qs, r, open_errs, needs, lams) in
          Hashtbl.replace cx.nodes a.arm_impl.node t;
          ignore
            (unifies env why a.arm_impl.loc ~found:t
               ~expected:(TFun (ps, r, open_errs, needs, l)))
      | Some (p, op, ps, _, _, _), Lambda (params, _) ->
          report env
            (arm_arity a.arm_name.loc ~dep:(type_name env p) ~op
               (List.length ps) (List.length params));
          ignore (core.infer env hcx a.arm_impl)
      | _ -> ignore (core.infer env hcx a.arm_impl))
    arms;
  defer env
    (Needs
       {
         nself = cx.self;
         ndeclared = declared;
         nrow = needs;
         ncalls = hcx.calls;
       })

(* `with item in body` (deps.md, "`with`"), the expression [e]. A call
   whose callee takes one more argument than it's given is a wrapper,
   and so is a function of one parameter; anything else is an
   implementation, installed. Which it is is found here, from types, and
   kept for lowering. *)
and with_ core env cx (e : expr) item body lam =
  match item.kind with
  | Call (({ kind = Field (r, m); _ } as f), args) -> (
      let tr = member_of_several env cx r (core.infer env cx r) m in
      (* a method is a wrapper if it takes one more argument, besides its
         `self`, than it's given *)
      let wrapper =
        match op_of env tr m.name with
        | Some (td, ({ okind = Method; _ } as o)) -> (
            let path = op_path td o in
            if path.home = env.home && not (Hashtbl.mem env.globals path) then
              raise (Unchecked { caller = cx.self; callee = path });
            match repr (lookup env cx ~node:f.node f.loc (Global path)) with
            | TFun (self :: ps, ret, errs, uses, l) as tm
              when List.length ps = List.length args + 1 ->
                Some (path, tm, self, TFun (ps, ret, errs, uses, l))
            | _ -> None)
        | _ -> None
      in
      match wrapper with
      | Some (path, tm, self, tf) ->
          Hashtbl.replace cx.nodes f.node tm;
          Hashtbl.replace cx.found f.node (Method_of path);
          unify_at env r.loc ~found:(widen env ~loc:r.loc tr) ~expected:self.ty;
          if self.mode = Inout then
            report env (wrapper_changes_receiver item.loc m.name);
          wrap core env cx e ~call:item ~f ~args
            ?target:(if group_call env path then Some path else None)
            ~callee:path ~skip:1 tf body lam
      | None ->
          let t = core.infer_call env cx ~tr item f args in
          Hashtbl.replace cx.nodes item.node t;
          install core env cx e item t body)
  | Call (f, args) -> (
      let tf = core.infer env cx f in
      (* a handler, or a function that makes an implementation, given too
         few arguments: what's missing isn't its body *)
      let short ps ret =
        List.length ps > List.length args
        && impl_parts (reveal env.st ret) <> None
        &&
        match reveal env.st (List.nth ps (List.length ps - 1)).ty with
        | TFun _ -> false
        | _ -> true
      in
      match reveal env.st tf with
      | TFun (ps, ret, _, _, _) when short ps ret ->
          let name = callee_name f in
          report env
            (with_too_few item.loc name
               ~made:(show (printer env) ret)
               (List.length ps) (List.length args));
          List.iter (fun a -> ignore (core.infer env cx a)) args;
          Hashtbl.replace cx.nodes item.node ret;
          install core env cx e item ret body
      | TFun (ps, _, _, _, _) when List.length ps = List.length args + 1 ->
          wrap core env cx e ~call:item ~f ~args tf body lam
      | _ ->
          let t = core.call_with env cx item f tf args in
          Hashtbl.replace cx.nodes item.node t;
          install core env cx e item t body)
  | _ -> (
      let t = core.infer env cx item in
      match reveal env.st t with
      | TFun ([ _ ], _, _, _, _) ->
          wrap core env cx e ~call:item ~f:item ~args:[] t body lam
      | _ -> install core env cx e item t body)

(* Install [item], of type [t], around [body]: the body uses what it does
   but what's installed, and the `with` uses what the implementation needs
   too. What's installed is what [t] says: each dependency an
   implementation of several lists, sharing one state, or the one an
   implementation, or one narrowed to it, is of (deps.md,
   "Implementations"). If [t] isn't known by now, it can't tell. *)
and install core env cx (e : expr) item t body =
  (* [body], with each of [deps] installed around it, the first outermost *)
  let rec around cx = function
    | [] -> core.infer env cx body
    | d :: rest ->
        let label = Ty.dep_label d in
        (* the body's own row, which the solver relates to the outer one
           once the group is done *)
        let inner = { cx with uses = fresh_row env.st; calls = ref [] } in
        let tb = around inner rest in
        defer env
          (Install
             {
               wloc = item.loc;
               wdep = label;
               wbody = inner.uses;
               wouter = cx.uses;
               wself = cx.self;
             });
        (* the body's calls bring in what they bring in, but [d] *)
        cx.calls :=
          List.map
            (fun c -> { c with own = List.filter (( <> ) label) c.own })
            !(inner.calls)
          @ !(cx.calls);
        tb
  in
  (* what an implementation of [deps] installs, recorded for lowering *)
  let installs deps =
    Hashtbl.replace cx.found e.node
      (match deps with [ d ] -> Installs d | deps -> Installs_handler deps);
    around cx deps
  in
  (* a `with` that can't tell what it installs might have installed what
     its body uses, so that's not passed on: it would be reported as missing
     too, where the function is called. What the body uses *)
  let unknown () =
    let uses = fresh_row env.st in
    ignore (core.infer env { cx with uses; calls = ref [] } body);
    uses
  in
  match reveal env.st t with
  | TError ->
      ignore (unknown ());
      TError
  | TVar _ -> (
      (* a value whose type isn't known yet, a parameter nothing wrote the
         type of, say: it could install one dependency or several, and
         that isn't guessed from what's done with it after *)
      let uses = unknown () in
      match item.kind with
      | Var (Local b) ->
          (* the help writes a type of what its body uses: the
             dependencies the runtime doesn't install around `main`, which
             are more likely what it implements, if there are any, since
             what it implements isn't known *)
          let used = List.map Ty.dep_path (row_names uses) in
          let ty =
            match
              List.filter (fun p -> not (Infer_declared.runtime_dep p)) used
            with
            | [] -> used
            | own -> own
          in
          let ty = String.concat " & " (List.map env.names ty) in
          let var = b.ident.name in
          let fix =
            match Hashtbl.find_opt cx.binders b.id with
            | Some _ when ty = "" -> Some ""
            | Some Own_param ->
                Some
                  (Printf.sprintf "fn %s(%s: %s)" (Path.short cx.self) var ty)
            | Some Lambda_param ->
                Some (Printf.sprintf "fn(%s: %s) => ..." var ty)
            | Some Let_bound -> Some (Printf.sprintf "let %s: %s = ..." var ty)
            | None -> None
          in
          report env (with_unknown item.loc ~var ~fix);
          TError
      | _ ->
          report env (cant_install item.loc Unknown);
          TError)
  | t when impl_parts t <> None ->
      let deps, needs = Option.get (impl_parts t) in
      (* what it needs it needs here, outside: its operations run with
         what's installed where it's installed *)
      use_row env cx ~loc:item.loc ~needs:true
        (copy_needs env ~loc:item.loc ~what:Installing needs);
      installs deps
  | TFun ([], ret, _, _, _) as tf when impl_parts (reveal env.st ret) <> None ->
      (* `with h in`, a handler or a function that makes an
         implementation not called: the body is checked as if it were,
         so what it uses isn't reported as missing too *)
      let src = Option.value (env.source item) ~default:"f" in
      report env (with_uncalled item.loc src (show (printer env) tf));
      installs (fst (Option.get (impl_parts (reveal env.st ret))))
  | t ->
      ignore (unknown ());
      report env (cant_install item.loc (Known (show (printer env) t)));
      TError

(* The wrapper call [call], `retry(3)`, of [f], of type [tf], given
   [args]: [body] is its last argument, a lambda of no parameters, whose
   type is recorded at [lam]. The `with` passes on what the call fails
   with, as `try` would: the body marks its own calls, and the wrapper is
   written to fail with what the body does. [skip] are its callee's
   parameters before [tf]'s, a method's `self`. *)
and wrap core env cx (e : expr) ~call ~f ~args ?target ?callee ?skip tf body lam
    =
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses, _) ->
      Hashtbl.replace cx.found e.node Wraps;
      let name = callee_name f in
      let n = List.length args in
      let firsts = List.filteri (fun i _ -> i < n) ps in
      let last = List.nth ps n in
      let callee =
        match (callee, f.kind) with
        | Some p, _ | None, Var (Global p) -> Some p
        | None, _ -> None
      in
      core.check_args env cx ~name ?callee
        ~written:(written_params env ?callee ?skip tf firsts)
        firsts args;
      outer_changes env body name;
      let berrs = fresh_row env.st and buses = fresh_row env.st in
      let lams = lambda_set env cx lam in
      let bcx = lambda_cx cx [] [] ~errs:berrs ~uses:buses in
      let tb =
        match repr last.ty with
        | TFun ([], r, _, _, _) ->
            core.check env bcx body r;
            r
        | _ -> core.infer env bcx body
      in
      let tl = TFun ([], tb, berrs, buses, lams) in
      Hashtbl.replace cx.nodes lam tl;
      if last.mode = Inout then report env (wrapper_changes_body call.loc name)
      else
        unify_at env call.loc ~found:tl ~expected:last.ty
          ~notes:[ wrapper_body_note ] ~help:(call_outside name)
          ~msg:(wrapper_last name);
      let m =
        {
          mkind = Mtry;
          mloc = keyword e.loc 4;
          covered = [];
          unwrapped = [];
          hint = None;
          failed = false;
        }
      in
      let target =
        match (target, f.kind) with
        | Some p, _ -> Some p
        | None, Var (Global p) when group_call env p -> Some p
        | None, _ -> None
      in
      absorb env
        { cx with markers = m :: cx.markers }
        ~call
        ~ename:(Option.value name ~default:"this")
        ~fn:f ?target ?callee errs uses;
      (* the call's type, unless it's the bare function, `with twice in` *)
      if call != f then Hashtbl.replace cx.nodes call.node ret;
      ret
  | _ -> assert false (* [with_] makes sure it's a function *)

(* A wrapper's body is a lambda, which captures the values of the
   variables it uses when it's made: changing one from outside it would
   change only the lambda's copy, so that's reported, as mut.ml reports it
   in a lambda that's written. [name] is the wrapper. *)
and outer_changes env (body : expr) name =
  let bound = Hashtbl.create 8 in
  let bind (b : binder) = Hashtbl.replace bound b.id () in
  let rec root (e : expr) =
    match e.kind with
    | Var (Local b) -> Some (b, e.loc)
    | Field (r, _) | Index (r, _) -> root r
    | _ -> None
  in
  let changed (place : expr) =
    match root place with
    | Some (b, _) when not (Hashtbl.mem bound b.id) ->
        report env
          (body_changes_outer place.loc ~wrapper:name ~var:b.ident.name)
    | _ -> ()
  in
  let rec walk (e : expr) =
    let all = List.iter walk in
    match e.kind with
    | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ -> ()
    | Lambda _ -> () (* its own changes are mut.ml's *)
    | Assign { target; value; _ } ->
        changed target;
        walk value
    | Ref { kind = Call ({ kind = Field (r, _); _ }, args); _ } ->
        changed r;
        all args
    | Ref a -> changed a
    | For { pat; over; body } ->
        (match over with
        | Each { kind = Ref a; _ } -> changed a
        | Each iter -> walk iter
        | Range (lo, hi) -> all [ lo; hi ]);
        List.iter (fun (b, _) -> bind b) (binders pat);
        walk body
    | Block (stmts, last) ->
        List.iter
          (function
            | Let { name; value; _ } ->
                walk value;
                bind name
            | Let_tuple { pat; value } ->
                walk value;
                List.iter (fun (b, _) -> bind b) (binders pat)
            | Expr e -> walk e)
          stmts;
        walk last
    | Match (s, arms) ->
        walk s;
        List.iter
          (fun (a : arm) ->
            List.iter (fun (b, _) -> bind b) (binders a.arm_pat);
            Option.iter walk a.arm_guard;
            walk a.arm_body)
          arms
    | Unop (_, a, _) | Field (a, _) | Try a | Attempt a | Assert a -> walk a
    | Binop (_, a, b, _) | Index (a, b) -> all [ a; b ]
    | If (c, t, f) -> all (c :: t :: Option.to_list f)
    | Call (f, args) -> all (f :: args)
    | Con (_, args) | Fail (_, args) -> all (List.map snd args)
    | Record (_, fields) -> all (List.map snd fields)
    | Array xs | Tuple xs -> all xs
    | With { item; body; _ } -> all [ item; body ]
    | Handler _ -> () (* only ever a handler's function's body *)
  in
  walk body
