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
      installs : Path.t list;
    }
  | Bad_item of int

let sprintf = Printf.sprintf

(* The dependencies a handler of [deps] implements, whose type its body
   gives (Types.impl_type): the dependency's, if it implements one, or the
   type that lists them. *)
let handler_deps (deps : tname list) =
  List.filter_map
    (fun (d : tname) -> match d.tref with Named p -> Some p | Param _ -> None)
    deps

(* A handler's body (ast.ml, [Handler]), the body of its function,
   [cx.self], whose result is the handler's type ([handler_deps]). Its
   state, arms and `finally` run where it's installed, not where the
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
let rec handler core env cx (h : expr) ~needs ~fails ~declared =
  match h.kind with
  | Handler { deps; over; state; arms; finally; _ } ->
      handler_parts core env cx ~node:h.node ~loc:h.loc ~deps ~over ~fails state
        arms finally ~needs ~declared
  | _ -> assert false

and handler_parts core env cx ~node ~loc ~deps ~over ~fails state arms finally
    ~needs ~declared =
  let own = handler_deps deps in
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
        own
  in
  Hashtbl.replace cx.found node (Handler_facts { forwards; body_ty = None });
  (* its state, arms and `finally` run while an operation does, or as
     one, so they can call `next` *)
  let hcx =
    { (lambda_cx cx [] [] ~errs:fails ~uses:needs) with next_at = Next_ok }
  in
  (* what a message says the handler is, if its state or `finally` fails
     with what it doesn't say it can *)
  let in_state =
    let name = Path.short cx.self in
    Some
      ( (if List.mem cx.self env.spelled then sprintf "`pub handler %s`" name
         else sprintf "`handler %s`" name),
        if over then "over " ^ String.concat " & " (List.map env.names own)
        else "for " ^ String.concat ", " (List.map env.names own) )
  in
  env.in_state <- in_state;
  List.iter (core.stmt env hcx) state;
  env.in_state <- None;
  List.iter
    (fun (a : handler_arm) ->
      let op =
        match a.arm_op with
        | Dep_op (p, op) -> (
            match dep_op_in op (Hashtbl.find env.types p) with
            | Some fd -> (
                match field_type ~tvars:[] fd with
                | TFun (ps, r, errs, _) -> Some (p, op, ps, r, errs)
                | _ -> None)
            | None -> None)
        | _ -> None
      in
      match (op, a.arm_impl.kind) with
      | Some (p, op, ps, r, errs), Lambda (params, body)
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
          let result_why = explain ~notes ~msg:arm_produces () in
          let qs =
            List.map2
              (fun (q : Resolved.param) eq ->
                if q.pty = None then eq
                else param_type env ~tparams:cx.tparams ~named:cx.named q)
              params ps
          in
          name_lambda cx a.arm_impl.node;
          bind_params hcx params qs;
          let acx =
            {
              (lambda_cx hcx params qs ~errs:open_errs ~uses:needs) with
              calls = hcx.calls;
              next_at = Next_ok;
            }
          in
          core.check env acx body r ~why:result_why;
          let t = TFun (qs, r, open_errs, needs) in
          Hashtbl.replace cx.nodes a.arm_impl.node t;
          ignore
            (unifies env why a.arm_impl.loc ~found:t
               ~expected:(TFun (ps, r, open_errs, needs)))
      | Some (p, op, ps, _, _), Lambda (params, _) ->
          report env
            (arm_arity a.arm_name.loc ~dep:(type_name env p) ~op
               (List.length ps) (List.length params));
          ignore (core.infer env hcx a.arm_impl)
      | _ -> ignore (core.infer env hcx a.arm_impl))
    arms;
  Option.iter (finally_ core env cx hcx ~node ~in_state ~fails ~needs) finally;
  (* what it goes over it needs too, added only now: a call made before
     that brings it in, `Users.get` in an arm, names it itself, so
     [check_needs] can tell it from a call of a lambda that only got it
     from sharing the handler's row *)
  if over then
    join_uses env ~loc ~what:Installing
      (extend (List.map (fun p -> dep (Ty.dep_label p)) own) (fresh_row env.st))
      needs;
  defer env
    (Needs
       {
         nself = cx.self;
         nover = (if over then List.map Ty.dep_label own else []);
         nfails = fails;
         ndeclared = declared;
         nrow = needs;
         ncalls = hcx.calls;
       })

(* A handler's `finally(r) => ...` (handlers.md, "When a `with` ends"),
   [fin], checked beside its state, in [hcx]: [r] is the body's result,
   a `Result<T, ! ..e>` of a type and errors that are any a `with` that
   installs it has, so it can only give back the value or fail. What it
   fails with itself is what installing the handler can fail with,
   [fails]: what it passes on of the body's, `try r`, the `with` fails with
   already. The two are skolems, which become variables of the handler's
   function's when it's put in canonical form, numbered after its own
   (Infer_top.canonical), so lowering can describe the body's type to it. *)
and finally_ core env cx hcx ~node ~in_state ~fails ~needs (fin : expr) =
  match fin.kind with
  | Lambda ([ p ], body) ->
      let tid = fresh_id env.st and eid = fresh_id env.st in
      let t = TSkol (tid, "T") in
      let rt = TCon (result_path, [ t; TErrors (RSkol (eid, "e")) ]) in
      env.finally_rows <- eid :: env.finally_rows;
      Hashtbl.replace env.finallies cx.self (node, tid, eid);
      let qs = [ { mode = Read; ty = rt } ] in
      name_lambda cx fin.node;
      bind_params hcx [ p ] qs;
      let fcx =
        {
          (lambda_cx hcx [ p ] qs ~errs:fails ~uses:needs) with
          calls = hcx.calls;
          next_at = Next_ok;
        }
      in
      env.in_state <- in_state;
      let r = p.pname.ident.name in
      core.check env fcx body t
        ~why:
          (explain
             ~notes:[ finally_produces_note r ]
             ~help:(fun _ _ -> finally_produces_help r)
             ~msg:(finally_produces ~result:(show (printer env) rt) r)
             ~type_params:false ());
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
  List.length ps = List.length args + 1
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
            List.filter (fun (d : Path.t) -> List.mem d.name h.deps) i.deps
          in
          if want = [] || List.length want = List.length i.deps then link
          else (
            Hashtbl.replace cx.narrowed item.node want;
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
  let shown deps = String.concat " & " (List.map env.names deps) in
  let checked =
    List.mapi
      (fun idx (it : with_item) ->
        (idx, it, List.map (classify core env cx) it.chain))
      items
  in
  let under_loc (it : with_item) =
    match it.under with
    | [] -> it.iloc
    | (d : tname) :: rest ->
        Loc.span d.tloc
          (List.fold_left (fun _ (d : tname) -> d.tloc) d.tloc rest)
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
          let rec fits = function
            | ((a : with_link), (ai : impl)) :: ((b, bi) :: _ as rest) ->
                if not ai.over then (
                  report env
                    (not_over ~param:(param a) a.link.loc ~link:(src a.link)
                       ~name:(name a) ~deps:(shown ai.deps) ~uloc:b.link.loc);
                  false)
                else if not (List.for_all (fun d -> List.mem d bi.deps) ai.deps)
                then (
                  report env
                    (not_one_under b.link.loc ~link:(src a.link)
                       ~deps:(shown ai.deps) ~under:(src b.link));
                  false)
                else fits rest
            | [ (b, bi) ] -> (
                let under = List.sort_uniq compare (Iface.dep_paths it.under) in
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
                  when List.for_all (fun d -> List.mem d bi.deps) under
                       && under <> bi.deps ->
                    (* `h() over A`, for an `h` over `A & B` *)
                    report env
                      (over_some (under_loc it) ~link:(src b.link)
                         ~deps:(List.map env.names bi.deps)
                         ~named:(List.map env.names under));
                    false
                | under when under <> bi.deps ->
                    report env
                      (not_one_under (under_loc it) ~link:(src b.link)
                         ~deps:(shown bi.deps)
                         ~under:("over " ^ shown under));
                    false
                | _ -> true)
            | [] -> false
          in
          if fits impls then
            let bottom = snd (List.nth impls (List.length impls - 1)) in
            Some
              (Installs_item { idx; it; links = impls; installs = bottom.deps })
          else Some (Bad_item idx))
      checked
  in
  (* each dependency installed once *)
  let ok =
    ref (not (List.exists (function Bad_item _ -> true | _ -> false) sorted))
  in
  let seen = Hashtbl.create 8 in
  List.iter
    (function
      | Installs_item { it; installs; _ } -> (
          (* the first item each of its dependencies is installed by, if
             one is; reported once, at the first such item *)
          let twice =
            List.filter_map
              (fun d ->
                Option.map (fun first -> (d, first)) (Hashtbl.find_opt seen d))
              installs
          in
          List.iter (fun d -> Hashtbl.replace seen d (it, installs)) installs;
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
                  | u -> [ shown (Iface.dep_paths u) ])
              in
              let chain =
                if first.under <> [] then Some (written first it)
                else if it.under <> [] then Some (written it first)
                else None
              in
              report env
                (installed_twice it.iloc ~deps:(List.map env.names deps)
                   ~first:first.iloc ~chain
                   ~all:(if List.length all > 1 then Some (shown all) else None))
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
      (* what installing each link fails with, the `with` fails with, as a
       `try` would pass it on *)
      let m =
        {
          mkind = Mtry;
          mloc = kw;
          covered = [];
          unwrapped = [];
          hint = None;
          failed = false;
        }
      in
      List.iter
        (fun (_, _, links, _) ->
          List.iter
            (fun ((lk : with_link), (i : impl)) ->
              absorb env
                { cx with markers = m :: cx.markers }
                ~call:lk.link ~ename:(src lk.link) ~fn:lk.link ~install:true
                i.fails REmpty)
            links)
        order;
      (* each item around the ones after it, each chain's bottom outermost *)
      let rec nest cx = function
        | [] -> core.infer env cx body
        | (_, _, links, _) :: rest ->
            let rec chain cx = function
              | [] -> nest cx rest
              | ((lk : with_link), (i : impl)) :: above ->
                  install env cx lk i (fun cx -> chain cx above)
            in
            chain cx (List.rev links)
      in
      nest cx order

(* The order to install a `with`'s [items] in, outermost first: one that
   installs what another needs goes around it, and otherwise the one whose
   first dependency, by name, comes first does, so the order is the set's,
   never how they're written. Two that each need the other are reported,
   and there's no order. *)
and install_order env ~src items =
  let labels deps = List.sort compare (List.map Ty.dep_label deps) in
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
and install env cx (lk : with_link) (i : impl) inner =
  let loc = lk.link.loc in
  use_row env cx ~loc ~needs:true (copy_needs env ~loc ~what:Installing i.needs);
  (* its kind is recorded at a node of its own, which needs a type *)
  Hashtbl.replace cx.nodes lk.knode (TImpl i);
  Hashtbl.replace cx.found lk.knode
    (match i.deps with [ d ] -> Installs d | deps -> Installs_handler deps);
  (* [inner], with each of [deps] installed around it, the first outermost *)
  let rec around cx = function
    | [] -> inner cx
    | d :: rest ->
        let label = Ty.dep_label d in
        (* the body's own row, which the solver relates to the outer one
           once the group is done *)
        let inside = { cx with uses = fresh_row env.st; calls = ref [] } in
        let tb = around inside rest in
        defer env
          (Install
             {
               wloc = loc;
               wdep = label;
               wbody = inside.uses;
               wouter = cx.uses;
               wself = cx.self;
             });
        (* the body's calls bring in what they bring in, but [d] *)
        cx.calls :=
          List.map
            (fun c -> { c with own = List.filter (( <> ) label) c.own })
            !(inside.calls)
          @ !(cx.calls);
        tb
  in
  around cx i.deps
