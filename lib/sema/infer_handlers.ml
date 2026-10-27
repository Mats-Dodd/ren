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

(* What a link of a `with`'s item is ([classify]): an implementation, a
   wrapper, which is given the context it's called in and what checks
   what's inside it, or something that isn't either, reported, or reported
   once what the `with`'s body uses is known. *)
type link =
  | Implementation of with_link * impl
  | Wrapper of with_link * (ctx -> (ctx -> ty option -> ty) -> ty)
  | Broken of (row -> unit)

(* An item of a `with`, checked as a chain ([with_]): by its place in the
   `with`, what it installs, each link with its implementation, top first,
   or the wrappers it is, or neither, since something's wrong. *)
type item =
  | Installs_item of {
      idx : int;
      it : with_item;
      links : (with_link * impl) list;
      installs : Path.t list;
    }
  | Wraps_item of
      int
      * with_item
      * (with_link * (ctx -> (ctx -> ty option -> ty) -> ty)) list
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
                 ineeds = None;
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
              next_at = Next_ok;
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
      let lams = lambda_set env cx fin.node in
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
      Hashtbl.replace cx.nodes fin.node (TFun (qs, t, fails, needs, lams))
  | Lambda (ps, _) ->
      report env (finally_params fin.loc (List.length ps));
      ignore (core.infer env hcx fin)
  | _ -> ignore (core.infer env hcx fin)

(* ---- `with` (handlers.md, "A `with` is a set") ---- *)

(* What a link of a `with`'s item is, found from its type in the context
   outside the `with`, where it's made. *)
and classify core env cx ~kw ~body (lk : with_link) : link =
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
    | TFun ([], ret, _, _, _) as tf when impl_of (reveal env.st ret) <> None ->
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
          Wrapper
            ( lk,
              fun cx inner ->
                wrap core env cx ~kw ~lk ~call:item ~f ~args
                  ?target:(if group_call env path then Some path else None)
                  ~callee:path ~skip:1 ~body tf inner )
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
      | TFun (ps, ret, _, _, _) when short ps ret ->
          let name = callee_name f in
          report env
            (with_too_few item.loc name
               ~made:(show (printer env) ret)
               (List.length ps) (List.length args));
          List.iter (fun a -> ignore (core.infer env cx a)) args;
          Hashtbl.replace cx.nodes item.node ret;
          impl ret
      | TFun (ps, _, _, _, _) when List.length ps = List.length args + 1 ->
          Wrapper
            ( lk,
              fun cx inner ->
                wrap core env cx ~kw ~lk ~call:item ~f ~args ~body tf inner )
      | _ ->
          let t = core.call_with env cx item f tf args in
          Hashtbl.replace cx.nodes item.node t;
          impl t)
  | _ -> (
      let t = core.infer env cx item in
      match reveal env.st t with
      | TFun ([ _ ], _, _, _, _) ->
          Wrapper
            ( lk,
              fun cx inner ->
                wrap core env cx ~kw ~lk ~call:item ~f:item ~args:[] ~body t
                  inner )
      | _ -> impl t)

(* `with a, b over c in body`, the expression [e] (handlers.md, "A `with`
   is a set"). Each link of each item is made here, outside the `with`, and
   what it is is found from its type ([classify]): an implementation,
   installed, or a wrapper, which wraps the body. An item that's a chain,
   `cached(ttl) over counted() over pg(pool)`, installs what its bottom
   does, each link above in place of what it goes over; the bottom can go
   over what's installed outside, `over Users`. Each dependency is
   installed once, and the items are installed in an order worked out
   from what each needs, so an item's needs are met by the others first;
   the wrappers go inside them all. That order, and what each link is, are
   recorded for lowering. The `with` fails with what installing each link
   can, as it does with what a wrapper fails with. *)
and with_ core env cx (e : expr) (items : with_item list) body =
  let kw = keyword e.loc 4 in
  let src (x : expr) = Option.value (env.source x) ~default:"this" in
  let shown deps = String.concat " & " (List.map env.names deps) in
  let checked =
    List.mapi
      (fun idx (it : with_item) ->
        (idx, it, List.map (classify core env cx ~kw ~body) it.chain))
      items
  in
  let under_loc (it : with_item) =
    match it.under with
    | [] -> it.iloc
    | (d : tname) :: rest ->
        Loc.span d.tloc
          (List.fold_left (fun _ (d : tname) -> d.tloc) d.tloc rest)
  in
  let link_of = function
    | Implementation (lk, _) | Wrapper (lk, _) -> Some lk
    | Broken _ -> None
  in
  let kind_of = function
    | Wrapper _ -> Some A_wrapper
    | Implementation _ -> Some An_implementation
    | Broken _ -> None
  in
  (* each item, checked as a chain: what it installs, or the wrappers it
     is, or nothing, if something's wrong *)
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
          let rec mixed = function
            | a :: (b :: _ as rest) ->
                if kind_of a <> kind_of b then Some (a, b) else mixed rest
            | _ -> None
          in
          match mixed links with
          | Some (a, b) ->
              let a = Option.get (link_of a) and b' = Option.get (link_of b) in
              report env
                (wrong_under b'.link.loc ~link:(src a.link)
                   ~kind:(Option.get (kind_of (List.hd links)))
                   ~under:(src b'.link));
              ignore b;
              Some (Bad_item idx)
          | None -> (
              match links with
              | Wrapper _ :: _ when it.under <> [] ->
                  let top = Option.get (link_of (List.hd (List.rev links))) in
                  report env
                    (wrong_under (under_loc it) ~link:(src top.link)
                       ~kind:A_wrapper
                       ~under:
                         ("over "
                         ^ String.concat " & "
                             (List.map env.names (Iface.dep_paths it.under))));
                  Some (Bad_item idx)
              | Wrapper _ :: _ ->
                  Some
                    (Wraps_item
                       ( idx,
                         it,
                         List.filter_map
                           (function
                             | Wrapper (lk, run) -> Some (lk, run) | _ -> None)
                           links ))
              | _ ->
                  let impls =
                    List.filter_map
                      (function
                        | Implementation (lk, i) -> Some (lk, i) | _ -> None)
                      links
                  in
                  let name (lk : with_link) =
                    match lk.link.kind with
                    | Call (f, _) -> (
                        match callee_name f with
                        | Some n -> n
                        | None -> src lk.link)
                    | _ -> src lk.link
                  in
                  let rec fits = function
                    | ((a : with_link), (ai : impl)) :: ((b, bi) :: _ as rest)
                      ->
                        if not ai.over then (
                          report env
                            (not_over a.link.loc ~link:(src a.link)
                               ~name:(name a) ~deps:(shown ai.deps)
                               ~uloc:b.link.loc);
                          false)
                        else if
                          not
                            (List.for_all (fun d -> List.mem d bi.deps) ai.deps)
                        then (
                          report env
                            (not_one_under b.link.loc ~link:(src a.link)
                               ~deps:(shown ai.deps) ~under:(src b.link));
                          false)
                        else fits rest
                    | [ (b, bi) ] -> (
                        let under =
                          List.sort_uniq compare (Iface.dep_paths it.under)
                        in
                        match under with
                        | [] when bi.over ->
                            report env
                              (over_nothing b.link.loc ~link:(src b.link)
                                 ~deps:(shown bi.deps));
                            false
                        | [] -> true
                        | _ when not bi.over ->
                            report env
                              (not_over b.link.loc ~link:(src b.link)
                                 ~name:(name b) ~deps:(shown bi.deps)
                                 ~uloc:(under_loc it));
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
                      (Installs_item
                         { idx; it; links = impls; installs = bottom.deps })
                  else Some (Bad_item idx)))
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
  (* the wrappers: one item, a chain of them, if they're more than one *)
  let wrappers =
    List.filter_map
      (function Wraps_item (_, it, ws) -> Some (it, ws) | _ -> None)
      sorted
  in
  (match wrappers with
  | (a, (alk, _) :: _) :: (b, (blk, _) :: _) :: _ ->
      ok := false;
      report env
        (wrappers_side_by_side a.iloc ~other:b.iloc ~first:(src alk.link)
           ~second:(src blk.link))
  | _ -> ());
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
      (* the body, inside the wrappers, each wrapping the one after it *)
      let rec through ws cx expected =
        match ws with
        | [] -> (
            match expected with
            | Some r ->
                core.check env cx body r;
                r
            | None -> core.infer env cx body)
        | (_, run) :: rest ->
            let t = run cx (through rest) in
            (match expected with
            | Some r -> unify_at env e.loc ~found:t ~expected:r
            | None -> ());
            t
      in
      let innermost cx =
        match wrappers with
        | (_, ws) :: _ -> through ws cx None
        | [] -> through [] cx None
      in
      (* each item around the ones after it, each chain's bottom outermost *)
      let rec nest cx = function
        | [] -> innermost cx
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

(* The wrapper call [call], `retry(3)`, of [f], of type [tf], given
   [args]: what's inside it, which [inner] checks, given the type it has
   to be if that's known, is its last argument, a lambda of no
   parameters, whose type is recorded at its link's [lam]. The `with`
   passes on what the call fails with, as `try` would: the body marks its
   own calls, and the wrapper is written to fail with what the body does.
   [skip] are its callee's parameters before [tf]'s, a method's `self`. *)
and wrap core env cx ~kw ~(lk : with_link) ~call ~f ~args ?target ?callee ?skip
    ~body tf inner =
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses, _) ->
      Hashtbl.replace cx.nodes lk.knode ret;
      Hashtbl.replace cx.found lk.knode Wraps;
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
      let lams = lambda_set env cx lk.lam in
      let bcx =
        {
          (lambda_cx cx [] [] ~errs:berrs ~uses:buses) with
          next_at =
            (match cx.next_at with Next_ok -> In_wrapped name | at -> at);
        }
      in
      let tb =
        match repr last.ty with
        | TFun ([], r, _, _, _) -> inner bcx (Some r)
        | _ -> inner bcx None
      in
      let tl = TFun ([], tb, berrs, buses, lams) in
      Hashtbl.replace cx.nodes lk.lam tl;
      if last.mode = Inout then report env (wrapper_changes_body call.loc name)
      else
        unify_at env call.loc ~found:tl ~expected:last.ty
          ~notes:[ wrapper_body_note ] ~help:(call_outside name)
          ~msg:(wrapper_last name);
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
  | _ -> assert false (* [classify] makes sure it's a function *)

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
    | With { items; body } -> all (with_links items @ [ body ])
    | Handler _ -> () (* only ever a handler's function's body *)
  in
  walk body
