(* Generator facts survive until the SCC's rows have their final labels.
   The early phase connects already-inferred step projections; the late
   phase chooses the representation without inferring any new code. *)

open Ast
open Types
open Infer_env
open Infer_report

let rec holds_with held (e : Resolved.expr) =
  match e.kind with
  | Yield _ | Yield_from _ -> held
  | Lambda _ | Handler _ -> false
  | With { items; body } ->
      List.exists (holds_with held) (with_links items) || holds_with true body
  | _ -> List.exists (holds_with held) (Ast.children e)

let rec pending t =
  match repr t with
  | TGen _ -> true
  | TCon (_, args) | TVariant (_, _, args) -> List.exists pending args
  | TFun (ps, r, e, u) ->
      List.exists pending (r :: param_tys ps) || pending_row e || pending_row u
  | TErrors r -> pending_row r
  | TImpl i ->
      List.exists (fun d -> List.exists pending d.dargs) i.deps
      || pending_row i.needs || pending_row i.fails
  | TVar _ | TSkol _ | TError -> false
and pending_row r =
  List.exists (fun (l : label) -> List.exists pending l.payload) (fst (row_parts r))

let pending_requirement = function
  | Compared q -> pending q.qty
  | Required r ->
      List.exists (fun (_, t) -> pending t) r.uinst
      || List.exists (fun (_, r) -> pending_row r) r.urows
  | _ -> false

let rec has_block t =
  match repr t with
  | TFun _ -> true
  | TCon (p, _) when p = Path.prelude "Scope" || p = Path.prelude "Background" -> true
  | TCon (_, args) | TVariant (_, _, args) -> List.exists has_block args
  | TErrors r ->
      List.exists (fun (l : label) -> List.exists has_block l.payload) (fst (row_parts r))
  | TGen _ -> false
  | TVar _ | TSkol _ | TImpl _ | TError -> false

let early env =
  let work = List.rev env.generator_early in
  env.generator_early <- [];
  List.iter (fun f -> f ()) work

let signature_for_cursor env p =
  Hashtbl.fold (fun _ (g : Ty.generator) found ->
      if g.cursor_path = p then Some g else found) env.generator_signatures None

(* Resolve introduces source cursor names before it can know which producers
   are blocks. Once classification is final, those names must be rejected in
   annotations too, including ones on unused parameters or unreachable code. *)
let validate_annotations env fns =
  let named (n : Ast.tname) =
    match n.tref with
    | Named p when Ty.is_generator_cursor p ->
        (match signature_for_cursor env p with
        | Some { kind = Ty.Block_gen; path; _ } ->
            report env (Diag.make n.tloc
                ~help:"use a `fn() -> Option<T>` block type, or let its type be inferred"
                (Printf.sprintf "`%s` is a block generator and has no cursor type"
                   (env.names path)))
        | _ -> ())
    | _ -> ()
  in
  let rec ty = function
    | TyName (n, args) | TyVariant (n, _, args) -> named n; List.iter ty args
    | TyFn (ps, ret, errs, uses, _) ->
        List.iter ty ps; Option.iter ty ret;
        Option.iter errors errs; Option.iter uses_ uses
    | TyImpl i ->
        List.iter dependency i.impl_deps;
        Option.iter errors i.impl_errors; Option.iter uses_ i.impl_uses
    | TyInout (t, _) -> ty t
    | TyErrors es -> errors es
    | TyTuple (ts, _) -> List.iter ty ts
  and errors es = List.iter (function
    | Tag (_, ps) -> List.iter (fun p -> ty p.payload_ty) ps
    | Set n -> named n) es.errs
  and dependency d = named d.dep; List.iter ty d.dargs
  and uses_ u = List.iter dependency u.deps in
  let params ps = List.iter (fun (p : Resolved.param) -> Option.iter ty p.pty) ps in
  let statement = function Let { ty = Some t; _ } -> ty t | _ -> () in
  let rec expr (e : Resolved.expr) =
    (match e.kind with
    | Lambda (ps, _) -> params ps
    | Block (stmts, _) | Handler { state = stmts; _ } -> List.iter statement stmts
    | _ -> ());
    List.iter expr (Ast.children e)
  in
  List.iter (fun (f : Resolved.fn_def) ->
      params f.params; Option.iter ty f.ret;
      Option.iter errors f.errors; Option.iter uses_ f.uses;
      expr f.body) fns

let producer_of_cursor p =
  let name = Ty.generator_cursor_name p in
  Path.make p.Path.home (String.sub name 0 (String.length name - 7))

let rec expand_canonical env (t : Ty.ty) =
  let go = expand_canonical env in
  match t with
  | Con (p, args) ->
      let t = Ty.Con (p, List.map go args) in
      if Ty.is_generator_cursor p then
        (match signature_for_cursor env p with
        | Some g when List.length args = Ty.generator_cursor_arity p ->
            Option.value (Ty.expand_generator_cursor g t) ~default:t
        | _ -> t)
      else t
  | Variant (p, c, args) -> Variant (p, c, List.map go args)
  | Fun (ps, ret, errs, uses) ->
      Fun (List.map (fun (p : Ty.param) -> {p with ty = go p.ty}) ps,
           go ret, expand_row env errs, expand_row env uses)
  | Errors r -> Errors (expand_row env r)
  | Impl i -> Impl {i with
      deps = List.map (fun (d : Ty.dep) -> {d with dargs = List.map go d.dargs}) i.deps;
      needs = expand_row env i.needs; fails = expand_row env i.fails}
  | Var _ | Error -> t
and expand_row env (r : Ty.row) =
  {r with labels = List.map (fun (l : Ty.label) ->
      {l with payload = List.map (expand_canonical env) l.payload}) r.labels}

let expand_declarations env =
  let field (f : Iface.field) = {f with fty = expand_canonical env f.fty} in
  let updates = Hashtbl.fold (fun p (td : Iface.type_decl) acc ->
      let body = match td.body with
        | Record fs -> Iface.Record (List.map field fs)
        | Sum cs -> Sum (List.map (fun (c : Iface.ctor) ->
            {c with cfields = List.map field c.cfields}) cs)
        | Opaque (Rep t) -> Opaque (Rep (expand_canonical env t))
        | Dep fs -> Dep (List.map field fs)
        | Dep_alias d -> Dep_alias {d with dargs = List.map (expand_canonical env) d.dargs}
        | Errors es -> Errors (List.map (function
            | Iface.Tag (name, payload) -> Iface.Tag (name, List.map (expand_canonical env) payload)
            | Iface.Set p -> Iface.Set p) es)
        | body -> body in
      let members = Path.Map.map (fun (o : Iface.op) ->
          {o with oscheme = {o.oscheme with ty = expand_canonical env o.oscheme.ty}}) td.members in
      (p, {td with body; members}) :: acc) env.types [] in
  List.iter (fun (p, (td : Iface.type_decl)) ->
      Hashtbl.replace env.types p td;
      (match td.body with
      | Opaque (Rep rep) when p.home = env.home -> Hashtbl.replace env.st.reps p rep
      | Dep_alias d -> Hashtbl.replace env.st.aliases p d
      | _ -> ())) updates;
  env.visible <- List.map (fun (td : Iface.type_decl) ->
        Option.value (Hashtbl.find_opt env.types td.path) ~default:td) env.visible

let validate_declarations env declarations =
  let rec valid (t : Ty.ty) =
    let all = List.for_all valid in
    match t with
    | Con (p, args) when Ty.is_generator_cursor p ->
        (match signature_for_cursor env p with
        | Some g when g.kind = Ty.Value_gen ->
            List.length args = List.length g.cursor_args
            && Ty.generator_instance g t <> None && all args
        | _ -> false)
    | Con (_, args) | Variant (_, _, args) -> all args
    | Fun (ps, ret, errs, uses) -> all (ret :: List.map (fun (p : Ty.param) -> p.ty) ps)
        && row errs && row uses
    | Errors r -> row r
    | Impl i -> List.for_all (fun (d : Ty.dep) -> all d.dargs) i.deps && row i.needs && row i.fails
    | Var _ | Error -> true
  and row (r : Ty.row) = List.for_all (fun (l : Ty.label) -> List.for_all valid l.payload) r.labels in
  List.iter (fun (original : Iface.type_decl) ->
      let td = Hashtbl.find env.types original.path in
      let field (f : Iface.field) = valid f.fty in
      let okay = match td.body with
        | Record fs | Dep fs -> List.for_all field fs
        | Sum cs -> List.for_all (fun (c : Iface.ctor) -> List.for_all field c.cfields) cs
        | Opaque (Rep t) -> valid t
        | Dep_alias d -> List.for_all valid d.dargs
        | Errors es -> List.for_all (function
            | Iface.Tag (_, payload) -> List.for_all valid payload
            | Iface.Set _ -> true) es
        | _ -> true in
      if not okay then report env (Diag.make
          (Option.value td.loc ~default:(Loc.point ~file:env.home 1 1))
          ~help:"declare and supply the generator's type parameters, or infer the cursor in a generic field"
          "this cursor field leaves its item or errors unspecified, or names a block generator")) declarations

let expand_inferred env t =
  match repr t with
  | TCon (p, args) when Ty.is_generator_cursor p
      && List.length args = Ty.generator_cursor_arity p -> (
      match signature_for_cursor env p with
      | Some g ->
          let abstract = Ty.Con (p, List.mapi (fun i _ -> Ty.Var i) args) in
          (match Ty.expand_generator_cursor g abstract with
          | Some expanded ->
              of_ty ~vars:(List.nth args) ~tails:(fun _ -> REmpty) expanded
          | None -> t)
      | None -> t)
  | _ -> t

(* A stream's item and errors can be connected before choosing cursor or
   block. An ordinary same-SCC caller may still have a result variable;
   its Join will reveal the generator before the early phase runs. *)
let projection env cx loc actual =
  let item = fresh_var env.st and errors = fresh_row env.st in
  let connect () =
    match repr (expand_inferred env actual) with
    | TGen g ->
        unify_at env loc ~found:item ~expected:g.gitem;
        Unify.unify_row env.st errors g.gerrors
    | TCon (p, args) when Ty.is_generator_cursor p -> (
        match List.rev args with
        | TErrors e :: t :: _ when List.length args > Ty.generator_cursor_arity p ->
            unify_at env loc ~found:item ~expected:t;
            Unify.unify_row env.st errors e
        | _ ->
            let producer = producer_of_cursor p in
            (match Hashtbl.find_opt env.generators producer with
            | Some d ->
                let prefix = List.filteri (fun i _ -> i < List.length args) d.gen_type.gargs in
                let tys = List.filter_map (fun (formal, actual) ->
                    match repr formal with
                    | TSkol (id, _) | TVar {contents = Unbound (id, _)} -> Some (id, actual)
                    | _ -> None) (List.combine prefix args) in
                let g = match replace {tys; rows = []} (TGen d.gen_type) with
                  | TGen g -> g
                  | _ -> d.gen_type in
                unify_at env loc ~found:item ~expected:g.gitem;
                Unify.unify_row env.st errors g.gerrors
            | None when p.home = env.home -> raise (Unchecked {caller = cx.self; callee = producer})
            | None -> report env (Diag.make loc "this cursor's item or errors are unspecified")))
    | TFun ([], ret, errs, _) ->
        unify_at env loc ~found:ret
          ~expected:(TCon (Path.prelude "Option", [item]));
        Unify.unify_row env.st errors errs
    | TCon (p, [t]) when p = Path.prelude "Array" || p = Path.prelude "Set" ->
        unify_at env loc ~found:item ~expected:t;
        Unify.unify_row env.st errors REmpty
    | TCon (p, [k; v]) when p = Path.prelude "Map" ->
        unify_at env loc ~found:item ~expected:(TCon (Ty.tuple_path 2, [k; v]));
        Unify.unify_row env.st errors REmpty
    | TVar _ ->
        unify_at env loc ~found:actual ~expected:(array item);
        Unify.unify_row env.st errors REmpty
    | TError -> ()
    | _ -> report env (Diag.make loc ~help:"give a cursor or a `fn() -> Option<T>` block"
                        "this value is not a stream")
  in
  (match repr actual with
  | TVar _ -> env.generator_early <- connect :: env.generator_early
  | _ -> connect ());
  ignore cx;
  (item, errors)

let finish env =
  Generator_replay.update env;
  let definitions = Hashtbl.fold (fun _ g acc ->
      if !(g.gen_type.gkind) = None then g :: acc else acc) env.generators [] in
  let definitions = List.sort (fun a b ->
      compare a.gen_type.gpath b.gen_type.gpath) definitions in
  let rec retained () =
    let changed = ref false in
    List.iter (fun d ->
        if not d.gen_with && Generator_retention.holds env d then (
          d.gen_with <- true;
          changed := true)) definitions;
    if !changed then retained ()
  in
  retained ();
  let effects d =
    let g = d.gen_type in
    let params = List.map (fun (p : Types.param) -> ("", p.ty)) d.gen_params in
    if row_skolem g.guses = None
       && not (Option.fold ~none:false ~some:(in_params params) (row_tail g.guses))
    then close_row g.guses;
    fst (row_parts g.guses) <> [] || row_tail g.guses <> None
    || d.gen_with || d.gen_unsafe
    || List.exists (fun (p : Types.param) -> p.mode = Inout) d.gen_params
  in
  let rec classify todo =
    let ready, waiting = List.partition (fun d ->
        effects d || not (List.exists (fun (p : Types.param) -> pending p.ty) d.gen_params)) todo in
    List.iter (fun d ->
        let block = effects d || List.exists (fun (p : Types.param) -> has_block p.ty) d.gen_params in
        d.gen_type.gkind := Some (if block then Ty.Block_gen else Ty.Value_gen)) ready;
    match waiting, ready with
    | [], _ -> ()
    | _, [] -> List.iter (fun d -> d.gen_type.gkind := Some Ty.Block_gen) waiting
    | _, _ -> classify waiting
  in
  classify definitions;
  List.iter (fun d ->
      let g = d.gen_type in
      let params = List.map (fun (p : Types.param) -> ("", p.ty)) d.gen_params in
      if !(g.gkind) = Some Ty.Value_gen && row_skolem g.gerrors = None
         && not (Option.fold ~none:false ~some:(in_params params) (row_tail g.gerrors))
      then close_row g.gerrors) definitions;
  let equations = List.rev env.st.generator_equalities in
  env.st.generator_equalities <- [];
  List.iter (fun (a, b) ->
      let loc = match definitions with d :: _ -> d.gen_fn.name.loc | [] -> Loc.point ~file:env.home 1 1 in
      unify_at env loc ~found:a ~expected:b) equations;
  let work = List.rev env.generator_late in
  env.generator_late <- [];
  List.iter (fun f -> f ()) work
