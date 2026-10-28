(* Handlers and `with` (see infer_expr.ml; deps.md): a handler's body,
   and a `with` that installs implementations around its body. *)

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

(* What a link of a `with`'s item is ([classify]): an implementation, or
   something that isn't one, reported, or reported once what the `with`'s
   body uses is known. *)
type link = Implementation of with_link * impl | Broken of (row -> unit)

(* An item of a `with`, checked as a chain ([with_]): by its place in the
   `with`, what it installs, each link with its implementation, top first,
   or nothing, since something's wrong. *)
type item =
  | Installs_item of {
      idx : int;
      it : with_item;
      links : (with_link * impl) list;
      installs : (label * Path.t) list;
          (** what it's installed as, each with the dependency it implements
              ([Infer_env.Installs]) *)
    }
  | Bad_item of int

let sprintf = Printf.sprintf

(* The dependencies a handler of [deps] implements, whose type its body
   gives (Types.impl_type): the dependency's, if it implements one, or the
   type that lists them. *)
let handler_deps env cx (deps : tname dep_ref list) =
  written_deps env ~tvars:cx.tparams deps

(* The same, for a handler whose type is made here: one `over any` lists
   the dependency that stands for whichever it's installed over, whose
   one type argument is the tags its arm fails with itself, a row of its
   own, which its arm's errors decide once its group is done (Ty.any_path;
   compiler.md, "`over any` and `retry`"). *)
let own_deps env cx ~any (deps : tname dep_ref list) =
  if any then
    [ { dpath = Ty.any_path; dargs = [ TErrors (fresh_row env.st) ] } ]
  else handler_deps env cx deps

(* The tags the arm of a handler `over any` fails with itself, if [own],
   what its type lists, is a handler `over any`'s (see [own_deps]). *)
let any_tags (own : dep list) =
  match own with
  | [ { dpath; dargs = [ t ] } ] when dpath = Ty.any_path -> (
      match repr t with TErrors r -> Some r | _ -> None)
  | _ -> None

(* A handler's body (ast.ml, [Handler]), the body of its function,
   [cx.self], whose result is the handler's type ([handler_deps]). Its
   state, `finally`s and arms run where it's installed, not where the
   function is called, so what they use is what the handler needs,
   [needs], and the function itself uses nothing. One declared [over] its
   dependencies needs them too: the one under it, which `next` reaches.
   Its state is made when it's installed, and what that and its `finally`
   fail with is what installing it can fail with, [fails] (handlers.md,
   "State that can fail to start"). Each arm is checked as an
   implementation's operation is ([infer_record]): it uses what the
   handler needs, and can fail with fewer errors than its operation
   declares, never more. What it needs is checked once the group is done,
   against what's [declared], if anything is (see [handler_needs]). *)
let rec handler core env cx (h : expr) ~own ~needs ~fails ~declared =
  match h.kind with
  | Handler { over; state; arms; _ } ->
      handler_parts core env cx ~node:h.node ~loc:h.loc ~own ~over ~fails state
        arms ~needs ~declared
  | _ -> assert false

(* [own] is what it implements, as its type lists it ([own_deps]). *)
and handler_parts core env cx ~node ~loc ~own ~over ~fails state arms ~needs
    ~declared =
  let tags = any_tags own in
  let own = if tags <> None then [] else own in
  let paths = List.map (fun d -> d.dpath) own in
  (* the operations one over its dependencies leaves out, which lowering
     makes calls of the one under it *)
  let forwards =
    if not over then []
    else
      List.concat_map
        (fun p ->
          match Hashtbl.find_opt env.types p with
          | Some { body = Dep fields; _ } ->
              List.filter_map
                (fun (f : Iface.field) ->
                  if
                    List.exists
                      (fun (a : handler_arm) -> a.arm_op = Dep_op (p, f.fname))
                      arms
                  then None
                  else Some (p, f.fname, f.fty))
                fields
          | _ -> [])
        paths
  in
  Hashtbl.replace cx.found node (Handler_facts { forwards; body_ty = None; any_vars = None });
  (* its state, arms and `finally` run while an operation does, or as
     one, so they can call `next` *)
  let hcx = lambda_cx cx [] [] ~errs:fails ~uses:needs in
  (* what a message says the handler is, if its state or `finally` fails
     with what it doesn't say it can *)
  let in_state =
    let name = Path.short cx.self in
    Some
      ( (if List.mem cx.self env.spelled then sprintf "`pub handler %s`" name
         else sprintf "`handler %s`" name),
        if tags <> None then "over any"
        else if over then "over " ^ shown_deps env own
        else
          "for "
          ^ String.concat ", " (List.map (fun d -> shown_deps env [ d ]) own) )
  in
  List.iter
    (fun (s : stmt) ->
      env.in_state <- in_state;
      match s with
      | Finally f -> finally_ core env cx hcx ~node ~in_state ~fails ~needs f
      | s -> core.stmt env hcx s)
    state;
  env.in_state <- None;
  List.iter
    (fun (a : handler_arm) ->
      let op =
        match a.arm_op with
        | Dep_op (p, op) -> (
            match dep_op_in env op (Hashtbl.find env.types p) with
            | Some fd -> (
                (* a generic one's operation at the handler's types, `T`
                   in `for Log<T>` *)
                let tvars =
                  match List.find_opt (fun d -> d.dpath = p) own with
                  | Some d -> d.dargs
                  | None -> []
                in
                match field_type ~tvars fd with
                | TFun (ps, r, errs, _) -> Some (p, op, ps, r, errs)
                | _ -> None)
            | None -> None)
        | _ -> None
      in
      match (op, a.arm_impl.kind, tags) with
      | _, Lambda ([], body), Some tags when a.arm_op = Call_op "any" ->
          any_arm core env cx hcx ~node ~needs ~tags a.arm_impl body
      | Some (p, op, ps, r, errs), Lambda (params, body), _
        when List.length params = List.length ps ->
          arm core env cx hcx ~needs ~dep:p ~op ~ps ~r ~errs a.arm_impl params
            body
      | Some (p, op, ps, _, _), Lambda (params, _), _ ->
          report env
            (arm_arity a.arm_name.loc ~dep:(type_name env p) ~op
               (List.length ps) (List.length params));
          ignore (core.infer env hcx a.arm_impl)
      | _ -> ignore (core.infer env hcx a.arm_impl))
    arms;
  (* what it goes over it needs too, added only now: a call made before
     that brings it in, `Users.get` in an arm, names it itself, so
     [check_needs] can tell it from a call that only got it
     from sharing the handler's row *)
  if over && own <> [] then
    join_uses env ~loc ~what:Installing
      (extend (List.map dep_of own) (fresh_row env.st))
      needs;
  defer env
    (Needs
       {
         nself = cx.self;
         nover = (if over then List.map dep_of own else []);
         nfails = fails;
         ndeclared = declared;
         nrow = needs;
         ncalls = hcx.calls;
       })

(* The arm of a handler `over any`, `call => body`, the lambda [impl] of
   no parameters, in a handler whose context is [hcx] and whose needs are
   [needs]: checked once, for an operation in general (compiler.md, "`over
   any` and `retry`"). The call's arguments' type and its result are
   skolems, and its errors a row the arm can't name, so it can only pass
   them on; they become variables of the handler's function's when it's
   put in canonical form, as a `finally`'s do, and lowering puts each
   operation's in their place. What the arm fails with itself,
   `call.fail(Down)`, is [tags], which its type lists, so a `with` that
   installs it over a dependency can check every operation declares
   them. *)
and any_arm core env cx hcx ~node ~needs ~tags (impl : expr) body =
  let aid = fresh_id env.st and rid = fresh_id env.st in
  let eid = fresh_id env.st in
  let args = TSkol (aid, "call.args") and res = TSkol (rid, "call.result") in
  Hashtbl.replace env.any_skolems aid "call.args";
  Hashtbl.replace env.any_skolems rid "call.forward()";
  Hashtbl.replace env.anys cx.self (node, aid, rid, eid);
  let open_errs = fresh_row env.st in
  defer env (Any_arm { aerrs = open_errs; atags = tags });
  name_lambda cx impl.node;
  let acx =
    { (lambda_cx hcx [] [] ~errs:open_errs ~uses:needs) with calls = hcx.calls }
  in
  let around = env.any_call in
  env.any_call <- Some (args, res, RSkol (eid, "call.errors"));
  core.check env acx body res;
  env.any_call <- around;
  Hashtbl.replace cx.nodes impl.node (TFun ([], res, open_errs, needs))

(* An arm, the lambda [impl] of [params] and [body], of the operation
   [op] of [dep], whose parameters are [ps], result [r] and errors
   [errs], at the handler's types, in a handler whose context is [hcx]
   and whose needs are [needs]. *)
and arm core env cx hcx ~needs ~dep:p ~op ~ps ~r ~errs (impl : expr) params
    body =
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
         ivalue = impl;
         inodes = cx.nodes;
       });
  (* checked as a lambda is, against the operation, but what its
     calls use is what the handler needs, and they're the
     handler's calls, so a message can point at one *)
  let notes = [ part_of (type_name env p) "operation" op ] in
  let why = explain ~notes () in
  let result_why = explain ~notes ~msg:arm_produces () in
  let qs =
    List.map2
      (fun (q : Resolved.param) eq ->
        if q.pty = None then eq
        else param_type env ~tparams:cx.tparams ~named:cx.named q)
      params ps
  in
  name_lambda cx impl.node;
  bind_params hcx params qs;
  let acx =
    {
      (lambda_cx hcx params qs ~errs:open_errs ~uses:needs) with
      calls = hcx.calls;
    }
  in
  core.check env acx body r ~why:result_why;
  let t = TFun (qs, r, open_errs, needs) in
  Hashtbl.replace cx.nodes impl.node t;
  ignore
    (unifies env why impl.loc ~found:t
       ~expected:(TFun (ps, r, open_errs, needs)))

(* An inline handler, [e], `handler fn(...) => ...`, whose arm is the
   lambda [lam], where a description of [d] is wanted (foundations.md,
   decision 3): its dependency has one operation, whose parameters it
   takes and whose result and errors it's checked against, as any arm is.
   What it uses is its handler's, a row of its own, found where it's
   installed or called: none of it is the code's around it, so a function
   that makes one uses nothing. That row is open, as a call's description
   is (Infer_expr.made), so it fits any slot that needs at least as much.
   It can't fail to start, and has no `next`. What it reads from around
   it, it captures, by copy, when it's made: data, never a block. Its
   type, or [TError] once something's reported. *)
and inline_handler core env cx (e : expr) (lam : expr) (d : dep) =
  let shown = shown_deps env [ d ] in
  let td = Hashtbl.find env.types d.dpath in
  let ops =
    Option.value ~default:[]
      (Iface.dep_fields
         (Hashtbl.find_opt env.types)
         {
           Ty.dpath = d.dpath;
           dargs = List.mapi (fun i _ -> Ty.Var i) td.params;
         })
  in
  (* `next`, which Resolve left for this to say (Resolve.no_next) *)
  let rec next_in (x : expr) =
    match x.kind with
    | Var (Global p) when p = Path.make env.home "next" -> Some x.loc
    | _ -> List.find_map next_in (Ast.children x)
  in
  match (ops, lam.kind, next_in lam) with
  | _, _, Some loc ->
      report env (inline_next loc ~dep:shown);
      TError
  | [ o ], Lambda (params, body), None -> (
      match field_type ~tvars:d.dargs o with
      | TFun (ps, r, errs, _) when List.length ps = List.length params ->
          let needs = fresh_row env.st in
          let hcx = lambda_cx cx [] [] ~errs:REmpty ~uses:needs in
          arm core env cx hcx ~needs ~dep:d.dpath ~op:o.fname ~ps ~r ~errs lam
            params body;
          (* what it captures: the locals it reads that it doesn't bind *)
          let own = Ast.bound_in lam in
          let seen = Hashtbl.create 8 in
          let rec captures (x : expr) =
            (match x.kind with
            | Var (Local b)
              when (not (List.mem b.id own)) && not (Hashtbl.mem seen b.id) ->
                Hashtbl.replace seen b.id ();
                (match
                   Option.map (reveal env.st) (Hashtbl.find_opt cx.locals b.id)
                 with
                | Some (TFun _) ->
                    report env (inline_block x.loc b.ident.name)
                | _ -> ())
            | _ -> ());
            List.iter captures (Ast.children x)
          in
          captures body;
          Hashtbl.replace cx.found e.node
            (Inline_op { dep = d.dpath; op = o.fname });
          TImpl { deps = [ d ]; over = false; needs; fails = REmpty }
      | TFun (ps, _, _, _) ->
          report env
            (inline_arity lam.loc ~dep:shown ~op:o.fname (List.length ps)
               (List.length params));
          TError
      | _ -> TError)
  | ops, _, None ->
      report env (inline_several e.loc ~dep:shown (List.length ops));
      TError

(* A `finally(r) => ...` among a handler's state (handlers.md, "When a
   `with` ends"), [fin], checked where it's written, in [hcx]: [r] is what
   the state after it and the body of a `with` that installs it end in, a
   `Result<T, ! ..e>` of a type and errors that are any a `with` that
   installs it has, so it can only give back the value or fail. What it
   fails with itself is what installing the handler can fail with,
   [fails]: what it passes on of the body's, `try r`, the `with` fails with
   already, and the state's, that installing does. The two are skolems,
   which become variables of the handler's function's when it's put in
   canonical form, numbered after its own (Infer_top.canonical), so
   lowering can describe the body's type to it. Every `finally` of a
   handler shares them: each gives the value of the same body. *)
and finally_ core env cx hcx ~node ~in_state ~fails ~needs (fin : expr) =
  match fin.kind with
  | Lambda ([ p ], body) ->
      let tid, eid =
        match Hashtbl.find_opt env.finallies cx.self with
        | Some (_, tid, eid) -> (tid, eid)
        | None ->
            let tid = fresh_id env.st and eid = fresh_id env.st in
            env.finally_rows <- eid :: env.finally_rows;
            Hashtbl.replace env.finallies cx.self (node, tid, eid);
            (tid, eid)
      in
      let t = TSkol (tid, "T") in
      (* the body's errors, and `Cancelled`, which a cancelled body gives
         it (compiler.md, "Stage 11a", "Cancellation") *)
      let rt =
        TCon (result_path, [ t; TErrors (RExtend (cancelled (), RSkol (eid, "e"))) ])
      in
      let qs = [ { mode = Read; ty = rt } ] in
      name_lambda cx fin.node;
      bind_params hcx [ p ] qs;
      let fcx =
        {
          (lambda_cx hcx [ p ] qs ~errs:fails ~uses:needs) with
          calls = hcx.calls;
        }
      in
      env.in_state <- in_state;
      env.in_finally <- env.in_finally + 1;
      let r = p.pname.ident.name in
      core.check env fcx body t
        ~why:
          (explain
             ~notes:[ finally_produces_note r ]
             ~help:(fun _ _ -> finally_produces_help r)
             ~msg:(finally_produces ~result:(show (printer env) rt) r)
             ~type_params:false ());
      env.in_finally <- env.in_finally - 1;
      env.in_state <- None;
      Hashtbl.replace cx.nodes fin.node (TFun (qs, t, fails, needs))
  | Lambda (ps, _) ->
      report env (finally_params fin.loc (List.length ps));
      ignore (core.infer env hcx fin)
  | _ -> ignore (core.infer env hcx fin)

(* ---- `with` (handlers.md, "A `with` is a set") ---- *)

(* What a link of a `with`'s item is, found from its type in the context
   outside the `with`, where it's made. A wrapper, a function that takes a
   block, is called instead: `try retry(3) fn() => ...` ([wrapper]). *)
and classify core env cx (lk : with_link) : link =
  let item = lk.link in
  (* an implementation, if [t] is one *)
  let impl t =
    match reveal env.st t with
    | TError -> Broken (fun _ -> ())
    | TVar _ -> (
        (* a value whose type isn't known yet, a parameter nothing wrote
           the type of, say: it could install one dependency or several,
           and that isn't guessed from what's done with it after. What
           the body uses helps say what to write *)
        match item.kind with
        | Var (Local b) ->
            Broken
              (fun uses ->
                (* the help writes a type of what its body uses: the
                   dependencies the runtime doesn't install around `main`,
                   which are more likely what it implements, if there are
                   any, since what it implements isn't known *)
                let used = List.map Ty.dep_path (row_names uses) in
                let used = List.sort_uniq compare used in
                let ty =
                  match
                    List.filter
                      (fun p -> not (Infer_declared.runtime_dep p))
                      used
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
                      Some (sprintf "fn %s(%s: %s)" (Path.short cx.self) var ty)
                  | Some Lambda_param ->
                      Some (sprintf "fn(%s: %s) => ..." var ty)
                  | Some Let_bound -> Some (sprintf "let %s: %s = ..." var ty)
                  | None -> None
                in
                report env (with_unknown item.loc ~var ~fix))
        | _ ->
            report env (cant_install item.loc Unknown);
            Broken (fun _ -> ()))
    | t when impl_of t <> None -> Implementation (lk, Option.get (impl_of t))
    | TFun ([], ret, _, _) as tf when impl_of (reveal env.st ret) <> None ->
        (* `with h in`, a handler or a function that makes an
           implementation not called: the body is checked as if it were,
           so what it uses isn't reported as missing too *)
        let src = Option.value (env.source item) ~default:"f" in
        report env (with_uncalled item.loc src (show (printer env) tf));
        let i = Option.get (impl_of (reveal env.st ret)) in
        Implementation (lk, { i with needs = fresh_row env.st; fails = REmpty })
    | t ->
        report env (cant_install item.loc (Known (show (printer env) t)));
        Broken (fun _ -> ())
  in
  match item.kind with
  | Call (({ kind = Field (r, m); _ } as f), args) -> (
      let tr = member_of_several env cx r (core.infer env cx r) m in
      (* a method that takes one more argument, besides its `self`, than
         it's given, a block, is a wrapper *)
      let takes =
        match op_of env tr m.name with
        | Some (td, ({ okind = Method; _ } as o)) -> (
            let path = op_path td o in
            if path.home = env.home && not (Hashtbl.mem env.globals path) then
              raise (Unchecked { caller = cx.self; callee = path });
            match repr (lookup env cx ~node:f.node f.loc (Global path)) with
            | TFun (_ :: ps, _, errs, _) when takes_block env ps args ->
                Some (ps, errs)
            | _ -> None)
        | _ -> None
      in
      match takes with
      | Some (ps, errs) -> wrapper core env cx item args ps errs
      | None ->
          let t = core.infer_call env cx ~tr item f args in
          Hashtbl.replace cx.nodes item.node t;
          impl t)
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
      | TFun (ps, ret, _, _) when short ps ret ->
          let name = callee_name f in
          report env
            (with_too_few item.loc name
               ~made:(show (printer env) ret)
               (List.length ps) (List.length args));
          List.iter (fun a -> ignore (core.infer env cx a)) args;
          Hashtbl.replace cx.nodes item.node ret;
          impl ret
      | TFun (ps, _, errs, _) when takes_block env ps args ->
          wrapper core env cx item args ps errs
      | _ ->
          let t = core.call_with env cx item f tf args in
          Hashtbl.replace cx.nodes item.node t;
          replayed cx item (impl t))
  | _ -> (
      let t = core.infer env cx item in
      match reveal env.st t with
      | TFun (ps, _, errs, _) when takes_block env ps [] ->
          wrapper core env cx item [] ps errs
      | _ -> impl t)

(* Whether a function of parameters [ps], given [args], takes one more
   argument than it's given, a block: then it's a wrapper, which `with`
   doesn't install. *)
and takes_block env (ps : Types.param list) args =
  (* a parameter of `Tags` is given by name, `on: Flaky`, or not at all *)
  let tags (p : Types.param) =
    match repr p.ty with TCon (q, []) -> q = tags_path | _ -> false
  in
  let named (a : expr) = match a.kind with Named _ -> true | _ -> false in
  List.length (List.filter (fun p -> not (tags p)) ps)
  = List.length (List.filter (fun a -> not (named a)) args) + 1
  &&
  match reveal env.st (List.nth ps (List.length ps - 1)).ty with
  | TFun _ -> true
  | _ -> false

(* The wrapper [item], `retry(3)`, given [args], whose callee takes
   parameters [ps] and fails with [errs]: `with` installs only handlers,
   so the help calls it, with the body as a block, `try retry(3) fn() =>
   ...`, and `try` only if it can fail. *)
and wrapper core env cx (item : expr) args ps errs =
  List.iter (fun a -> ignore (core.infer env cx a)) args;
  let src = Option.value (env.source item) ~default:"f" in
  let call = match item.kind with Call _ -> src | _ -> src ^ "()" in
  (* a parameter of `Tags` not given is, by name, `retry(3, on: ...)` *)
  let call =
    let missing =
      List.filter
        (fun (p : Types.param) ->
          match repr p.ty with TCon (q, []) -> q = tags_path | _ -> false)
        ps
    in
    let named (a : expr) = match a.kind with Named _ -> true | _ -> false in
    if missing = [] || List.exists named args then call
    else
      match String.rindex_opt call ')' with
      | Some i ->
          let before = String.sub call 0 i in
          let sep = if args = [] then "" else ", " in
          before ^ sep ^ "on: ...)"
      | None -> call
  in
  let block =
    match reveal env.st (List.nth ps (List.length ps - 1)).ty with
    | TFun (qs, _, _, _) ->
        "fn(" ^ String.concat ", " (List.map (fun _ -> "_") qs) ^ ") => ..."
    | _ -> "fn() => ..."
  in
  let fails = fst (row_parts errs) <> [] in
  let name =
    match item.kind with
    | Call ({ kind = Field (_, m); _ }, _) -> Some m.name
    | Call (f, _) -> callee_name f
    | _ -> Some src
  in
  report env
    (wrapper_in_with item.loc name
       ((if fails then "try " else "") ^ call ^ " " ^ block));
  Broken (fun _ -> ())

(* `replay("tests/run.journal")`, the link [item] (handlers.md, "A journal
   as a test fixture"): an implementation of only the built-in
   dependencies its journal's header names, read now, from the folder of
   the file the test is in, as the test will. So the others are still the
   test's, and another item of the `with` can install them. It's narrowed
   to those, as a handler is where a written type asks for some of what it
   implements. A journal that isn't there, or can't be read, is said when
   the test runs. *)
and replayed cx (item : expr) link =
  match (item.kind, link) with
  | ( Call ({ kind = Var (Global p); _ }, [ { kind = Str file; _ } ]),
      Implementation (lk, i) )
    when p = Path.prelude "replay" -> (
      let path =
        if Filename.is_relative file then
          Filename.concat (Filename.dirname item.loc.file) file
        else file
      in
      match Journal.header_at path with
      | Some h ->
          let want =
            List.filter (fun (d : dep) -> List.mem d.dpath.name h.deps) i.deps
          in
          if want = [] || List.length want = List.length i.deps then link
          else (
            Hashtbl.replace cx.narrowed item.node
              (List.map (fun d -> d.dpath) want);
            Implementation (lk, { i with deps = want }))
      | None -> link)
  | _ -> link

(* `with a, b over c in body`, the expression [e] (handlers.md, "A `with`
   is a set"). Each link of each item is made here, outside the `with`, and
   what it is is found from its type ([classify]): an implementation,
   installed. An item that's a chain,
   `cached(ttl) over counted() over pg(pool)`, installs what its bottom
   does, each link above in place of what it goes over; the bottom can go
   over what's installed outside, `over Users`. Each dependency is
   installed once, and the items are installed in an order worked out
   from what each needs, so an item's needs are met by the others first.
   That order, and what each link is, are recorded for lowering. The
   `with` fails with what installing each link can. *)
and with_ core env cx (e : expr) (items : with_item list) body =
  let kw = keyword e.loc 4 in
  let src (x : expr) = Option.value (env.source x) ~default:"this" in
  let shown deps = shown_deps env deps in
  let paths (ds : dep list) = List.map (fun d -> d.dpath) ds in
  let checked =
    List.mapi
      (fun idx (it : with_item) ->
        (idx, it, List.map (classify core env cx) it.chain))
      items
  in
  let under_loc (it : with_item) =
    match it.under with
    | [] -> it.iloc
    | (d : tname dep_ref) :: rest ->
        Loc.span d.dep.tloc
          (List.fold_left
             (fun _ (d : tname dep_ref) -> d.dep.tloc)
             d.dep.tloc rest)
  in
  (* each item, checked as a chain: what it installs, or nothing, if
     something's wrong *)
  let laters = ref [] in
  let sorted =
    List.filter_map
      (fun (idx, (it : with_item), links) ->
        if List.exists (function Broken _ -> true | _ -> false) links then (
          List.iter
            (function Broken later -> laters := later :: !laters | _ -> ())
            links;
          Some (Bad_item idx))
        else
          let impls =
            List.filter_map
              (function Implementation (lk, i) -> Some (lk, i) | _ -> None)
              links
          in
          match any_links env cx it impls ~src ~laters with
          | None -> Some (Bad_item idx)
          | Some impls ->
          let name (lk : with_link) =
            match lk.link.kind with
            | Call (f, _) -> (
                match callee_name f with Some n -> n | None -> src lk.link)
            | _ -> src lk.link
          in
          (* a parameter whose type is written, `w: Users`, which
                     says whether it goes over another *)
          let param (lk : with_link) =
            match lk.link.kind with
            | Var (Local b) ->
                Hashtbl.mem cx.written_locals b.id
                && Hashtbl.find_opt cx.binders b.id <> Some Let_bound
            | _ -> false
          in
          (* a generic link goes over one at its own types: `limit()`
             over `queue()` makes them both `Chan<α>`, or over the
             installed `Chan<Int>` *)
          let same_args (ai : impl) (deps : dep list) =
            List.for_all
              (fun (d : dep) ->
                match
                  List.find_opt (fun (e : dep) -> e.dpath = d.dpath) deps
                with
                | Some e when List.length e.dargs = List.length d.dargs -> (
                    try
                      List.iter2 (Unify.unify env.st) d.dargs e.dargs;
                      true
                    with Unify.Mismatch | Unify.Infinite -> false)
                | Some _ -> false
                | None -> true)
              ai.deps
          in
          let rec fits = function
            | ((a : with_link), (ai : impl)) :: ((b, bi) :: _ as rest) ->
                if not ai.over then (
                  report env
                    (not_over ~param:(param a) a.link.loc ~link:(src a.link)
                       ~name:(name a) ~deps:(shown ai.deps) ~uloc:b.link.loc);
                  false)
                else if
                  not
                    (List.for_all
                       (fun d -> List.mem d (paths bi.deps))
                       (paths ai.deps))
                then (
                  report env
                    (not_one_under b.link.loc ~link:(src a.link)
                       ~deps:(shown ai.deps) ~under:(src b.link));
                  false)
                else if not (same_args ai bi.deps) then (
                  report env
                    (not_one_under b.link.loc ~link:(src a.link)
                       ~deps:(shown ai.deps) ~under:(src b.link));
                  false)
                else fits rest
            | [ (b, bi) ] -> (
                let under = List.sort_uniq compare (Iface.dep_paths it.under) in
                let bdeps = paths bi.deps in
                match under with
                | [] when bi.over ->
                    report env
                      (over_nothing b.link.loc ~link:(src b.link)
                         ~deps:(shown bi.deps));
                    false
                | [] -> true
                | _ when not bi.over ->
                    report env
                      (not_over ~param:(param b) b.link.loc ~link:(src b.link)
                         ~name:(name b) ~deps:(shown bi.deps)
                         ~uloc:(under_loc it));
                    false
                | under
                  when under = bdeps
                       && not
                            (same_args bi
                               (Infer_written.written_deps env ~tvars:cx.tparams
                                  it.under)) ->
                    report env
                      (not_one_under (under_loc it) ~link:(src b.link)
                         ~deps:(shown bi.deps)
                         ~under:
                           ("over "
                           ^ String.concat " & "
                               (List.map
                                  (fun (d : dep) -> shown [ d ])
                                  (Infer_written.written_deps env
                                     ~tvars:cx.tparams it.under))));
                    false
                | under
                  when List.for_all (fun d -> List.mem d bdeps) under
                       && under <> bdeps ->
                    (* `h() over A`, for an `h` over `A & B` *)
                    report env
                      (over_some (under_loc it) ~link:(src b.link)
                         ~deps:(List.map env.names bdeps)
                         ~named:(List.map env.names under));
                    false
                | under when under <> bdeps ->
                    report env
                      (not_one_under (under_loc it) ~link:(src b.link)
                         ~deps:(shown bi.deps)
                         ~under:
                           ("over "
                           ^ String.concat " & " (List.map env.names under)));
                    false
                | _ -> true)
            | [] -> false
          in
          if fits impls then
            let bottom = snd (List.nth impls (List.length impls - 1)) in
            match it.alias with
            | None ->
                Some
                  (Installs_item
                     {
                       idx;
                       it;
                       links = impls;
                       installs =
                         List.map (fun d -> (dep_of d, d.dpath)) bottom.deps;
                     })
            | Some a -> (
                match installed_as env cx it impls a with
                | Some key ->
                    Some
                      (Installs_item
                         { idx; it; links = impls; installs = [ key ] })
                | None -> Some (Bad_item idx))
          else Some (Bad_item idx))
      checked
  in
  (* each dependency installed once *)
  let ok =
    ref (not (List.exists (function Bad_item _ -> true | _ -> false) sorted))
  in
  let seen = ref [] in
  List.iter
    (function
      | Installs_item { it; installs; _ } -> (
          let installs = List.map fst installs in
          (* the first item each of its dependencies is installed by, if
             one is; reported once, at the first such item. A `with` is a
             set of labels: `Log<Int>` beside `Log<Str>` is two *)
          let twice =
            List.filter_map
              (fun d ->
                Option.map
                  (fun (_, first) -> (d, first))
                  (List.find_opt (fun (l, _) -> same_label l d) !seen))
              installs
          in
          List.iter (fun d -> seen := (d, (it, installs)) :: !seen) installs;
          match twice with
          | (_, ((first : with_item), all)) :: _ ->
              ok := false;
              let deps =
                List.filter_map
                  (fun (d, (f, _)) -> if f == first then Some d else None)
                  twice
              in
              (* if one goes over what's outside, it can go over the
                 other instead: one chain of the two *)
              let written (top : with_item) (bottom : with_item) =
                String.concat " over "
                  (List.map (fun (lk : with_link) -> src lk.link) top.chain
                  @ List.map (fun (lk : with_link) -> src lk.link) bottom.chain
                  @
                  match bottom.under with
                  | [] -> []
                  | u ->
                      [
                        String.concat " & "
                          (List.map
                             (fun (d : tname dep_ref) ->
                               match d.dep.tref with
                               | Named p -> env.names p
                               | Param _ -> "")
                             u);
                      ])
              in
              let chain =
                if first.under <> [] then Some (written first it)
                else if it.under <> [] then Some (written it first)
                else None
              in
              let names ls = List.map (shown_dep env) ls in
              report env
                (installed_twice it.iloc ~deps:(names deps) ~first:first.iloc
                   ~chain
                   ~all:
                     (if List.length all > 1 then
                        Some (String.concat " & " (names all))
                      else None))
          | [] -> ())
      | _ -> ())
    sorted;
  let installs =
    List.filter_map
      (function
        | Installs_item { idx; it; links; installs } ->
            Some (idx, it, links, installs)
        | _ -> None)
      sorted
  in
  let order = if !ok then install_order env ~src installs else None in
  match order with
  | None ->
      (* what the body uses isn't passed on: something that isn't installed
       might have installed it, and it would be reported as missing too *)
      let uses = fresh_row env.st in
      ignore (core.infer env { cx with uses; calls = ref [] } body);
      List.iter (fun later -> later uses) (List.rev !laters);
      TError
  | Some order ->
      Hashtbl.replace cx.found e.node
        (Install_order (List.map (fun (idx, _, _, _) -> idx) order));
      (* what installing each link fails with is a call's errors, which
         the markers around the `with` cover: `try with`, `attempt with`,
         or a `match` of the `with` with `fail` arms (compiler.md, "Stage
         11a", "`try with`"). Unmarked, it's reported at the keyword *)
      List.iter
        (fun (_, _, links, _) ->
          List.iter
            (fun ((lk : with_link), (i : impl)) ->
              absorb env cx ~call:lk.link ~ename:(src lk.link)
                ~fn:{ lk.link with loc = kw } ~install:true i.fails REmpty)
            links)
        order;
      (* and only that: a call in the body is a place the code can stop,
         marked where it is *)
      let cx = { cx with markers = [] } in
      (* each item around the ones after it, each chain's bottom outermost *)
      let rec nest cx = function
        | [] -> core.infer env cx body
        | (_, _, links, keys) :: rest ->
            let rec chain cx = function
              | [] -> nest cx rest
              | ((lk : with_link), (i : impl)) :: above ->
                  install env cx lk i ~keys (fun cx -> chain cx above)
            in
            chain cx (List.rev links)
      in
      nest cx order

(* The links [impls] of the item [it], top first, with each handler `over
   any` among them made an implementation of what it's installed over
   (compiler.md, "`over any` and `retry`"): the dependency of the link
   under it, or of the one it's installed over outside, `over Users`,
   which is one. It's installed where it's made, `with logged() over
   ...`, since it's made for that dependency, and what it fails with
   itself, every operation of that one declares. [None] once something's
   reported, or will be, once the body says what it uses, which the help
   names ([laters]). *)
and any_links env cx (it : with_item) impls ~src ~laters =
  let ok = ref true in
  let fail () = ok := false in
  let link (lk : with_link) = src lk.link in
  (* each of [tags] is declared, with its shape, by every operation of
     [d] *)
  let declared (lk : with_link) tags (d : dep) =
    let ops =
      Option.value ~default:[]
        (Iface.dep_fields (Hashtbl.find_opt env.types)
           {
             Ty.dpath = d.dpath;
             dargs = List.mapi (fun i _ -> Ty.Var i) d.dargs;
           })
    in
    let has (op : Iface.field) (l : label) =
      match field_type ~tvars:d.dargs op with
      | TFun (_, _, errs, _) -> (
          match
            List.find_opt (fun (o : label) -> o.name = l.name)
              (fst (row_parts errs))
          with
          | Some o when List.length o.payload = List.length l.payload ->
              Result.is_ok
                (Unify.atomically env.st (Unify.copier ())
                   (fun st (c : Unify.copy) ->
                     List.iter2
                       (fun a b -> Unify.unify st (c.ty a) (c.ty b))
                       o.payload l.payload))
          | _ -> false)
      | _ -> false
    in
    match
      List.find_map
        (fun (l : label) ->
          match List.filter (fun op -> not (has op l)) ops with
          | [] -> None
          | missing -> Some (l, missing))
        (sorted_labels tags)
    with
    | None -> ()
    | Some (l, missing) ->
        fail ();
        report env
          (any_undeclared lk.link.loc ~link:(link lk) ~tag:l.name
             ~dep:(env.names d.dpath)
             ~missing:(List.map (fun (o : Iface.field) -> o.fname) missing))
  in
  (* no operation of [d] takes a block: `call.args` holds an operation's
     arguments as a value, and a block is never held in one (foundations.md,
     decision 1) *)
  let no_blocks (lk : with_link) (d : dep) =
    let ops =
      Option.value ~default:[]
        (Iface.dep_fields (Hashtbl.find_opt env.types)
           {
             Ty.dpath = d.dpath;
             dargs = List.mapi (fun i _ -> Ty.Var i) d.dargs;
           })
    in
    let takes_block (op : Iface.field) =
      match field_type ~tvars:d.dargs op with
      | TFun (params, _, _, _) ->
          List.exists
            (fun (p : param) ->
              match repr p.ty with TFun _ -> true | _ -> false)
            params
      | _ -> false
    in
    match List.find_opt takes_block ops with
    | None -> ()
    | Some op ->
        fail ();
        report env
          (any_block_arg lk.link.loc ~link:(link lk)
             ~dep:(env.names d.dpath) ~op:op.fname)
  in
  (* what the arm needs of `call.args` or of what `call.forward()` gives,
     `==`, which every operation of [d] has to allow of its arguments or
     its result (found in the stage-10d review: `==` on a description,
     which has none, reached the interpreter, and over a generic
     dependency, lowering). Only a handler of this module's is known
     here (Infer_env, [anys]); one imported isn't checked. *)
  let compared (lk : with_link) (d : dep) =
    let hidden =
      match lk.link.kind with
      | Call ({ kind = Var (Global h); _ }, _) -> (
          match Hashtbl.find_opt env.anys h with
          | Some (_, aid, rid, _) ->
              List.map (fun r -> ("takes", r)) (needs env.st aid)
              @ List.map (fun r -> ("gives", r)) (needs env.st rid)
          | None -> [])
      | _ -> []
    in
    if hidden <> [] then
      if d.dargs <> [] then (
        fail ();
        report env
          (any_compared_generic lk.link.loc ~link:(link lk)
             ~dep:(env.names d.dpath)))
      else
        let ops =
          Option.value ~default:[]
            (Iface.dep_fields (Hashtbl.find_opt env.types)
               { Ty.dpath = d.dpath; dargs = [] })
        in
        let lacking =
          List.find_map
            (fun (op : Iface.field) ->
              match field_type ~tvars:[] op with
              | TFun (ps, r, _, _) ->
                  let parts =
                    List.map (fun (p : param) -> ("takes", p.ty)) ps
                    @ [ ("gives", r) ]
                  in
                  List.find_map
                    (fun (what, req) ->
                      List.find_map
                        (fun (w, t) ->
                          if w = what && Infer_reqs.lacks env req t then
                            Some (op.fname, req, what, t)
                          else None)
                        parts)
                    (List.sort_uniq compare hidden)
              | _ -> None)
            ops
        in
        match lacking with
        | None -> ()
        | Some (op, req, what, t) ->
            fail ();
            report env
              (any_lacks lk.link.loc ~link:(link lk)
                 ~op:(env.names d.dpath ^ "." ^ op)
                 ~what ~req
                 ~ty:(show (printer env) t))
  in
  let rec go below = function
    | [] -> []
    | ((lk : with_link), (i : impl)) :: above -> (
        match any_tags i.deps with
        | None -> (lk, i) :: go (Some i.deps) above
        | Some tags -> (
            let several under ds =
              fail ();
              report env
                (any_over_several lk.link.loc ~link:(link lk) ~under
                   ~deps:(List.map (fun d -> env.names d.dpath) ds))
            in
            let d =
              match below with
              | Some [ d ] -> Some d
              | Some ds ->
                  several "the implementation under it" ds;
                  None
              | None -> (
                  match written_deps env ~tvars:cx.tparams it.under with
                  | [ d ] -> Some d
                  | [] ->
                      fail ();
                      laters :=
                        (fun uses ->
                          let used =
                            List.sort_uniq compare
                              (List.map Ty.dep_path (row_names uses))
                          in
                          let used =
                            match
                              List.filter
                                (fun p -> not (Infer_declared.runtime_dep p))
                                used
                            with
                            | [] -> used
                            | own -> own
                          in
                          report env
                            (any_over_nothing lk.link.loc ~link:(link lk)
                               ~dep:
                                 (match used with
                                 | p :: _ -> env.names p
                                 | [] -> "Clock")))
                        :: !laters;
                      None
                  | ds ->
                      several "what it's installed over" ds;
                      None)
            in
            match d with
            | None -> (lk, i) :: go None above
            | Some d ->
                (match lk.link.kind with
                | Call ({ kind = Var (Global _); _ }, _) -> ()
                | _ ->
                    fail ();
                    report env (any_not_made_here lk.link.loc ~link:(link lk)));
                declared lk tags d;
                no_blocks lk d;
                compared lk d;
                let i =
                  { i with deps = [ d ]; needs = extend [ dep_of d ] i.needs }
                in
                (lk, i) :: go (Some [ d ]) above))
  in
  let made = List.rev (go None (List.rev impls)) in
  if !ok then Some made else None

(* The order to install a `with`'s [items] in, outermost first: one that
   installs what another needs goes around it, and otherwise the one whose
   first dependency, by name, comes first does, so the order is the set's,
   never how they're written. Two that each need the other are reported,
   and there's no order. *)
and install_order env ~src items =
  (* by name: an item's needs are met by whatever installs a dependency
     of that name *)
  let labels deps =
    List.sort_uniq compare (List.map (fun ((l : label), _) -> l.name) deps)
  in
  let needs_of (_, _, links, installs) =
    let own = labels installs in
    List.sort_uniq compare
      (List.concat_map (fun (_, (i : impl)) -> row_names i.needs) links)
    |> List.filter (fun l -> not (List.mem l own))
  in
  let provider l =
    List.find_opt
      (fun (_, _, _, installs) -> List.mem l (labels installs))
      items
  in
  let key (_, _, _, installs) = labels installs in
  let before a b =
    (* what [a] needs that [b] installs *)
    List.filter
      (fun l -> match provider l with Some p -> p == b | None -> false)
      (needs_of a)
  in
  let rec go placed remaining =
    match remaining with
    | [] -> Some (List.rev placed)
    | _ -> (
        let ready =
          List.filter
            (fun a ->
              List.for_all (fun b -> b == a || before a b = []) remaining)
            remaining
        in
        match ready with
        | [] ->
            (* a cycle: reported once, at two items of it *)
            let a = List.hd remaining in
            let b = List.find (fun b -> b != a && before a b <> []) remaining in
            let b =
              Option.value ~default:b
                (List.find_opt
                   (fun b -> b != a && before a b <> [] && before b a <> [])
                   remaining)
            in
            let top (_, _, links, _) = src (fst (List.hd links)).link in
            let iloc (_, (it : with_item), _, _) = it.iloc in
            let first l = env.names (Ty.dep_path (List.hd l)) in
            let b_needs = before b a in
            report env
              (needs_each_other (iloc a) ~a:(top a)
                 ~a_needs:(first (before a b))
                 ~bloc:(iloc b) ~b:(top b)
                 ~b_needs:(if b_needs = [] then "?" else first b_needs));
            None
        | r :: rest ->
            let pick =
              List.fold_left
                (fun best x ->
                  if compare (key x) (key best) < 0 then x else best)
                r rest
            in
            go (pick :: placed) (List.filter (fun x -> x != pick) remaining))
  in
  go [] items

(* Install [i], the implementation the link [lk] is, around what [inner]
   checks: [inner] uses what it does but what's installed, and the `with`
   uses what the implementation needs too, here, outside it: its operations
   run with what's installed where it's installed. What's installed is
   each dependency [i] lists, sharing one state, or the one it is
   (deps.md, "Implementations"). *)
and install env cx (lk : with_link) (i : impl) ~keys inner =
  let loc = lk.link.loc in
  let src = Option.value (env.source lk.link) ~default:"this" in
  use_row env cx ~loc ~needs:true (copy_needs env ~loc ~what:Installing i.needs);
  (* its kind is recorded at a node of its own, which needs a type *)
  Hashtbl.replace cx.nodes lk.knode (TImpl i);
  (* a link above the bottom of a chain is installed as what it goes
     over, the bottom's keys, which an alias names only at the bottom *)
  let keys =
    if List.length keys = List.length i.deps then keys
    else List.map (fun d -> (dep_of d, d.dpath)) i.deps
  in
  Hashtbl.replace cx.found lk.knode
    (match keys with
    | [ (key, from) ] -> Installs { key; from }
    | keys -> Installs_handler (List.map fst keys));
  (* [inner], with each of [deps] installed around it, the first outermost *)
  let rec around cx = function
    | [] -> inner cx
    | (label, _) :: rest ->
        (* the body's own row, which the solver relates to the outer one
           once the group is done *)
        let inside = { cx with uses = fresh_row env.st; calls = ref [] } in
        let tb = around inside rest in
        defer env
          (Install
             {
               wloc = loc;
               wdeps = [ label ];
               wbody = inside.uses;
               wouter = cx.uses;
               wself = cx.self;
               wblock = false;
               wsrc = src;
             });
        (* the body's calls bring in what they bring in, but [d] *)
        cx.calls :=
          List.map
            (fun c -> { c with own = without_labels [ label ] c.own })
            !(inside.calls)
          @ !(cx.calls);
        tb
  in
  around cx keys

(* What the item [it], a chain of [links], is installed as, written after
   `as`, [a]: an alias of an instance of the dependency it implements,
   `with queue() as Jobs`, or that instance written out, `as Chan<Int>`,
   whose type arguments its own are unified with; with the dependency it
   implements. Anything else is reported, and gives [None] (compiler.md,
   "Generic dependencies"). *)
and installed_as env cx (it : with_item) links (a : tname dep_ref) =
  let lk, bottom = List.nth links (List.length links - 1) in
  let src = Option.value (env.source lk.link) ~default:"this" in
  let declared (p : Path.t) =
    match Hashtbl.find_opt env.types p with
    | Some td when td.params <> [] ->
        env.names p ^ "<" ^ String.concat ", " td.params ^ ">"
    | _ -> env.names p
  in
  let as_ = shown_deps env (written_deps env ~tvars:cx.tparams [ a ]) in
  let wanted =
    match a.dep.tref with
    | Named p -> (
        match Iface.alias_of (Hashtbl.find_opt env.types) p with
        | Some t ->
            (* an alias: what it names, as a checker type *)
            Some
              ( dep (Ty.dep_label p),
                {
                  dpath = t.dpath;
                  dargs =
                    List.map
                      (of_ty ~vars:(fun _ -> TError) ~tails:(fun _ -> REmpty))
                      t.dargs;
                } )
        | None -> (
            match written_deps env ~tvars:cx.tparams [ a ] with
            | [ d ] -> Some (dep_of d, d)
            | _ -> None))
    | Param _ -> None
  in
  match (bottom.deps, wanted) with
  | _, _ when List.length links > 1 || it.under <> [] ->
      report env (as_on_chain it.iloc ~link:src);
      None
  | [ d ], Some (key, target)
    when d.dpath = target.dpath
         && List.length d.dargs = List.length target.dargs -> (
      match
        Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
            List.iter2
              (fun x y -> Unify.unify st (c.ty x) (c.ty y))
              d.dargs target.dargs)
      with
      | Ok () -> Some (key, d.dpath)
      | Error _ ->
          report env
            (installed_as_wrong it.iloc ~link:src ~as_
               ~implements:(declared d.dpath));
          None)
  | ds, _ ->
      report env
        (installed_as_wrong it.iloc ~link:src ~as_
           ~implements:
             (String.concat " & " (List.map (fun d -> declared d.dpath) ds)));
      None
