(* The constraint solver (compiler.md, "The constraint solver"). Checking
   a group's bodies leaves constraints, things that have to hold of its
   types and rows but can be decided only once every body is checked
   (Infer_env.constr). The solver decides them, once the group is done.

   The solver decides every constraint of one kind before it starts the
   next ([solve]): a later kind reads what an earlier one decides. Within
   a kind, it takes them in the order they were met. Most are decided
   once; an inclusion, or a copy of what an implementation needs, is
   decided again whenever the row it adds from has gained a label, until
   none has: a worklist, which ends because rows only ever gain labels,
   and each has finitely many to gain.

   A constraint that fails is reported, and changes nothing: it's tried on
   copies of its types first (Unify.atomically), so a unification that
   fails partway doesn't leave half its changes for the next constraint
   to trip over. *)

open Types
open Infer_msg
open Infer_env
open Infer_report

(* ---- deciding one ---- *)

(* Unify [found] with [expected], as [Infer_report.unify_at] does, but
   changing nothing if that fails: the mismatch is reported as far as the
   copies got, which is what it would have said unifying the types
   themselves. *)
let equal env ?msg ?notes ?help ?narrowed_help loc ~found ~expected =
  let c = Unify.copier () in
  match
    Unify.atomically env.st c (fun st (c : Unify.copy) ->
        Unify.unify st (c.ty found) (c.ty expected))
  with
  | Ok () -> ()
  | Error failure ->
      let help = Option.map (fun h _ _ -> h) help in
      mismatch env
        (explain ?msg ?notes ?help ?narrowed_help ())
        loc ~found:(c.ty found) ~expected:(c.ty expected) failure

(* A use of another function of the group is the type that function's
   own body gave it (see [Infer_env.join]), with what the use put in place
   of its type parameters and named rows. A row of its own that ends in one
   of those once the group is done, `! ..e`, ends in what the use put
   there, as it will. *)
let join env ~is_value j =
  let msg = used_as j.jname in
  let g = List.assoc j.target env.group in
  let ends =
    List.map (fun (v, named) -> (v, List.assoc named j.jinst.rows)) (g.gends ())
  in
  let expected =
    replace
      { j.jinst with rows = j.jinst.rows @ ends }
      (Hashtbl.find env.globals j.target)
  in
  match (repr j.used, repr expected) with
  | TFun ([], used, _, _), TFun ([], made, _, _) when is_value j.target ->
      (* an associated value, a function of no parameters (ast.ml), is
         used as its result, which is what's shown *)
      equal env j.jloc ~found:used ~expected:made ~msg
        ~notes:[ group_type ~values:true ]
  | used, made ->
      (* a call of it isn't narrowed, as its result isn't written there
         (Infer_expr.narrow), so that's what to write, if that's where the
         two differ; or else the parameter's type, which an argument is
         narrowed to once it's written (Infer_written.written_params) *)
      let deps t = Option.map fst (impl_parts t) in
      let at =
        match (used, made) with
        | TFun (ps, r, _, _), TFun (qs, r', _, _)
          when deps r = deps r' && List.length ps = List.length qs ->
            List.find_mapi
              (fun i ((p : param), (q : param)) ->
                if deps p.ty <> deps q.ty then Some i else None)
              (List.combine ps qs)
        | _ -> None
      in
      equal env j.jloc ~found:j.used ~expected ~msg
        ~notes:[ group_type ~values:false ]
        ~narrowed_help:
          (match at with
          | Some i -> write_group_param j.jname (i + 1)
          | None -> write_group_result j.jname)

(* A value thrown away is `Unit` (see [Infer_env.drop]). One whose type is
   still unknown, like the result of calling a parameter, becomes `Unit`,
   and is kept in [forced]. *)
let drop env d =
  (match repr d.dty with
  | TVar _ -> env.forced <- (d.dself, d.dloc) :: env.forced
  | _ -> ());
  (* an implementation, or a handler's description, which a handler's
     call makes: it's for installing *)
  let implementation = impl_parts d.dty <> None in
  equal env d.dloc ~found:d.dty ~expected:unit
    ~msg:(thrown_away ~callee:d.callee ~implementation)
    ~help:(thrown_away_help ~implementation)

(* A tag written as a value, `Err(Right)`, goes in its set if the set is
   one of its own, not what an `attempt` kept or a parameter fails with:
   `if c then Err(Left(1)) else Err(Right)` holds both
   ([Infer_rows.err_row]). Whether it went in: if not, it's checked with
   the tags in patterns, once the kept sets, [kept], are closed. *)
let value_tag env ~kept t =
  let kept tl = List.exists (fun k -> row_tail k = Some tl) kept in
  let labels, tail = row_parts t.tset in
  match tail with
  | Some tl
    when (not (kept tl))
         && (not (in_params t.tin tl))
         && not (List.exists (fun (l : label) -> l.name = t.ttag.name) labels)
    -> (
      (* marked as written, so a kept set it meets in a later group is
         known to have it from here (see [written_kept]) *)
      let l =
        {
          name = t.ttag.name;
          payload = t.tpayload;
          dep = false;
          written = ref (Mark (Some t.ttag.loc));
        }
      in
      (* a named row can't learn a tag: it's checked with the patterns,
         and isn't one of the errors *)
      match
        Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
            Unify.unify_row st (c.row t.tset) (extend [ l ] (fresh_row st)))
      with
      | Ok () -> true
      | Error _ -> false)
  | _ -> false

(* Whether the inclusion [i] has anything to do: labels its source has
   that it hasn't added, or a source that stands for what a parameter
   fails with, which isn't linked yet. Rows only gain labels, so once it
   has, it has until it does it. *)
let awake i =
  let labels, src_tail = row_parts i.isrc in
  List.exists (fun (l : label) -> not (List.mem l.name i.ipassed)) labels
  ||
  match src_tail with
  | Some t -> (not i.ilinked) && in_params i.iparams t
  | None -> false

(* Add [r]'s labels to [i]'s destination, as [Infer_rows.add_errors]
   does, but changing nothing if that fails. *)
let add env i r =
  let errs = Infer_rows.without i.iwithout r in
  let c = Unify.copier () in
  (* the labels already there, as the message shows them *)
  let before = fst (row_parts (c.row i.idst)) in
  match
    Unify.atomically env.st c (fun st (c : Unify.copy) ->
        Unify.unify_row st
          (extend (fst (row_parts (c.row errs))) (fresh_row st))
          (c.row i.idst))
  with
  | Ok () -> ()
  | Error failure ->
      Infer_rows.add_failed env ~loc:i.iloc ~here:i.ihere
        ~sources:(i.isources ()) ~fix:i.ifix ~before (c.row errs) failure

(* Do what the inclusion [i] has to do (see [Infer_env.inclusion]): add
   the labels its source has learned since, and end a destination that
   includes a parameter's errors in the same tail as that parameter's.
   Whether it did anything, which may have woken others. *)
let include_ env i =
  let labels, src_tail = row_parts i.isrc in
  let added =
    match
      List.filter (fun (l : label) -> not (List.mem l.name i.ipassed)) labels
    with
    | [] -> false
    | fresh ->
        i.ipassed <- i.ipassed @ List.map (fun (l : label) -> l.name) fresh;
        add env i (extend fresh REmpty);
        true
  in
  (* a named row, `call.forward()`'s errors in a handler `over any`, is
     passed on as a parameter's is *)
  let named = match row_end i.isrc with RSkol _ -> true | _ -> false in
  match src_tail with
  | Some t when (not i.ilinked) && (named || in_params i.iparams t) ->
      (i.ilinked <- true;
       (* an open row takes on the parameter's tail, and stays what it is
         before it; a closed one, a lambda's whose type is written, says
         what the parameter can fail with *)
       let a, b =
         match row_tail i.idst with
         | Some _ -> (row_end i.isrc, row_end i.idst)
         | None -> (i.isrc, i.idst)
       in
       match
         Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
             Unify.unify_row st (c.row a) (c.row b))
       with
       | Ok () -> ()
       | Error _ -> report env (param_fails_here i.iloc));
      true
  | _ -> added

(* Whether the copy [k] of what an implementation needs (see
   [Infer_env.copy]) has anything to do: labels its source has learned
   since it last added them. *)
let copy_awake k =
  List.exists
    (fun (l : label) -> not (has_dep k.kpassed l))
    (fst (row_parts k.ksrc))

(* Add to the copy [k] the labels its source has learned since, or say
   the place it's used can't use them. Whether it added any. *)
let copy env k =
  match
    List.filter
      (fun (l : label) -> not (has_dep k.kpassed l))
      (fst (row_parts k.ksrc))
  with
  | [] -> false
  | fresh ->
      k.kpassed <- k.kpassed @ fresh;
      let joined = extend fresh (fresh_row env.st) in
      (match
         Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
             Unify.unify_row st (c.row joined) (c.row k.kdst))
       with
      | Ok () -> ()
      | Error _ -> report env (cant_use k.kloc k.kwhat (dep_names env joined)));
      true

(* ---- what a `with` installs (deps.md, "`with`") ---- *)

(* A `with` that installs, or a block (see [Infer_env.install]): its body
   uses no more than what it installs, or what the block's parameter's
   type lists, and what's installed outside it, where it's written. Inner
   ones are decided first, since what their bodies use is part of what the
   outer ones' do. Each body's labels but those installed are added to the
   outer row. If the body's row is the outer one already, as for another
   function of the group that calls this one back, that's all. (A function
   calling itself gets a copy of its own row, Infer_rows.use_row.) A row
   still open at the end of the body's, another function of the group's
   before it's done, ends the outer row too, so what it learns later is
   outside as well. A block parameter's row is closed, so a block never
   reaches what a `with` installs unless its type lists it (foundations.md,
   decision 5). What it adds to the outer row is tried on copies first, so
   if it can't, that's reported and nothing changes.

   It returns why the function it's in still gets what a `with` installs
   from outside, if it does, and the uses of a named row it makes, which
   are decided with the others, last. *)
let install env w =
  (* an item at open types, `with log() in`, is the body's one use of
     its dependency (compiler.md, "Generic dependencies"). One the body
     uses at several is reported, and then the body's uses of it aren't
     reported again as uses nothing installs. *)
  let unknown = ref [] in
  List.iter
    (fun (d : label) ->
      if Unify.open_args d then
        let uses =
          List.filter
            (fun (l : label) -> l.name = d.name && not (same_label l d))
            (fst (row_parts w.wbody))
        in
        let fix (l : label) =
          ignore
            (Unify.atomically env.st (Unify.copier ())
               (fun st (c : Unify.copy) ->
                 List.iter2
                   (fun a b -> Unify.unify st (c.ty a) (c.ty b))
                   d.payload l.payload))
        in
        match uses with
        | [ l ] -> fix l
        | [] ->
            (* nothing uses it: it's installed at `Unit`, which nothing
               can tell from another type *)
            fix { d with payload = List.map (fun _ -> unit) d.payload }
        | ls ->
            unknown := d.name :: !unknown;
            report env
              (which_installed w.wloc
                 ~dep:(env.names (Ty.dep_path d.name))
                 ~src:w.wsrc
                 ~uses:
                   (List.map (shown_dep env) (sorted_labels (extend ls REmpty)))))
    w.wdeps;
  let labels, tail = row_parts w.wbody in
  let rest =
    List.filter
      (fun (l : label) -> not (List.mem l.name !unknown))
      (without_labels w.wdeps labels)
  in
  (* add [r] to what's outside: whether it could *)
  let into r =
    Result.is_ok
      (Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
           Unify.unify_row st (c.row r) (c.row w.wouter)))
  in
  let same_row = tail <> None && tail = row_tail w.wouter in
  let withheld, due, ok =
    match row_end w.wbody with
    | _ when same_row ->
        (* the same row: everything it uses but [wdeps] is outside too, which
           for a `with` is worth a note *)
        ( List.map
            (fun d ->
              (d, Same_row { fn = Path.local w.wself; dep = shown_dep env d }))
            (if w.wblock then [] else w.wdeps),
          None,
          List.for_all (fun (l : label) -> has_label w.wouter l) rest )
    | RSkol (id, n) ->
        (* a named row: what's outside ends in it too *)
        let due =
          {
            rloc = w.wloc;
            rinto = w.wouter;
            rnamed = (id, n);
            rwhat = With_body;
          }
        in
        ([], Some due, into (extend rest (fresh_row env.st)))
    | RVar _ as t -> ([], None, into (extend rest t))
    | REmpty | RExtend _ -> ([], None, into (extend rest (fresh_row env.st)))
  in
  if not ok then
    report env
      (with_body_uses w.wloc ~block:w.wblock ~same_row
         (List.map (shown_dep env) rest));
  (List.map (fun (hdep, hnote) -> { hfn = w.wself; hdep; hnote }) withheld, due)

(* A call of a generic dependency's operation whose instance was open when
   it was made (see [Infer_env.instance]): joined to what the function or
   lambda it's in uses, once it's known which instance it is. If it's
   open still, the function's declared `uses` says, if it lists exactly
   one of that dependency; a function that declares none can leave it to
   its callers only if what it's given fixes it, a generic one's
   parameter. Otherwise, which it is isn't known, and that's reported. *)
let instance env x =
  let l = x.xlabel in
  let fixed_by_params () =
    match Option.map repr (Hashtbl.find_opt env.globals x.xself) with
    | Some (TFun (ps, ret, _, _)) ->
        let rec vars t =
          match repr t with
          | TVar { contents = Unbound (id, _) } -> [ id ]
          | TCon (_, args) -> List.concat_map vars args
          | _ -> []
        in
        let given =
          List.concat_map (fun (p : Types.param) -> vars p.ty) ps @ vars ret
        in
        List.for_all
          (fun id -> List.mem id given)
          (List.concat_map vars l.payload)
    | _ -> false
  in
  let unknown candidates =
    report env
      (which_instance x.xloc
         ~dep:(env.names (Ty.dep_path l.name))
         ~call:x.xcall
         ~candidates:(List.map (shown_dep env) candidates));
    false
  in
  let joins =
    if not (Unify.open_args l) then true
    else
      match x.xdeclared with
      | Some declared -> (
          match List.filter (fun (d : label) -> d.name = l.name) declared with
          | [ d ] ->
              Result.is_ok
                (Unify.atomically env.st (Unify.copier ())
                   (fun st (c : Unify.copy) ->
                     List.iter2
                       (fun a b -> Unify.unify st (c.ty a) (c.ty b))
                       l.payload d.payload))
          | [] -> true (* reported as a use it doesn't declare *)
          | several -> unknown several)
      | None -> (
          (* the one instance of its name already used where it's called,
             if there's one, as unification would pick ([Unify.unify_row]) *)
          match
            List.filter
              (fun (k : label) -> k.name = l.name && not (Unify.open_args k))
              (fst (row_parts x.xinto))
          with
          | [ _ ] -> true
          | _ when fixed_by_params () -> true
          | several -> unknown several)
  in
  if joins then
    Infer_rows.join_uses env ~loc:x.xloc ~what:x.xwhat
      (extend [ l ] (fresh_row env.st))
      x.xinto

(* ---- the rules of markers ----

   Checked once the group's functions are joined, when it's known what
   each call fails with (errors.md, "Marking"):

   1. each `attempt` keeps exactly what the calls it covers fail with, and
      each `match` with `fail` arms handles exactly that
   2. each tag matched in those errors is one of them
   3. each `try r` of a [Result] fails with what [r] holds, and each
      `try match` with what its arms don't handle
   4. a call no marker covers can't fail
   5. every marker covers something that can fail: a `match`'s `fail`
      arms match something

   The first three are inclusions and the kept sets closed after them, and
   the tags matched checked against them; the last two read the result. *)

(* An `attempt`'s set, or a `match`'s with `fail` arms, holds what the
   calls it covers fail with, and nothing more: it's closed, so a tag
   matched in it later is checked against exactly that. One of a call of a
   function it was passed keeps whatever that function fails with, so it
   stays open, like the function's. *)
let kept (k, params, _) =
  match row_tail k with
  | Some t when in_params params t -> ()
  | _ -> close_row k

(* What an `attempt` keeps holds no tag written inside `Err` that no call
   it covers fails with (errors.md, "Keeping an error"). In its own group
   such a tag is checked where it meets the kept set ([value_tag]), but a
   set of them from an earlier group is a type like any other by then, and
   meeting it gave the kept set its tags: those are marked as written
   ([Types.label]), so the ones none of its calls fail with are reported
   here. A declared `Result`'s tags aren't marked, and a tag unified with
   one isn't either ([Types.join_marks]), so a kept set can still take
   those, whichever it met first. [into] are the group's inclusions, by which the calls and
   `fail`s add what they fail with. A `match`'s set, which no value holds,
   has no [at]. *)
let written_kept env ~into (k, _, at) =
  let labels = fst (row_parts k) in
  match at with
  | Some at when List.exists (fun l -> written_at l <> None) labels -> (
      (* what the calls fail with, looked for only here, since it goes
         through all the group's inclusions: those into this very row,
         the one the `attempt` made ([==]), not another that's equal *)
      let fails =
        List.concat_map
          (fun i ->
            if i.idst == k then
              List.filter
                (fun n -> not (List.mem n i.iwithout))
                (row_names i.isrc)
            else [])
          into
      in
      match
        List.filter_map
          (fun (l : label) ->
            match written_at l with
            | Some w when not (List.mem l.name fails) -> Some (l.name, w)
            | _ -> None)
          labels
      with
      | [] -> ()
      | extra ->
          let shown = List.map (show_label (printer env)) in
          (* it's closed, as the set it met is, so it holds what that
             holds *)
          report env
            (kept_written at ~extra ~written:(shown labels)
               ~fails:
                 (shown
                    (List.filter
                       (fun (l : label) -> List.mem l.name fails)
                       labels))))
  | _ -> ()

(* A tag matched in a set that was still open (see [Infer_env.tag_pattern])
   is one of its tags, with as many payloads; or else it's a tag written
   as a value that didn't go in a set of its own. *)
let tag_pattern env t =
  let pr = printer env in
  let c = t.ttag and payload = t.tpayload and arm = t.tarm in
  let labels, tail = row_parts t.tset in
  let tags = List.map (fun (l : label) -> (l.name, show_label pr l)) labels in
  match List.find_opt (fun (l : label) -> l.name = c.name) labels with
  | _ when arm && labels = [] && tail = None ->
      (* a `fail` arm of a `match` whose subject can't fail, which is
         reported once, with the markers ([marker]) *)
      ()
  | Some l when List.length l.payload = List.length payload -> (
      (* all the payloads, or none: if one doesn't fit, nothing changes,
         and each that doesn't is reported, as unifying them one by one
         on the same copies finds *)
      let unify_all st (k : Unify.copy) =
        List.iter2
          (fun found expected -> Unify.unify st (k.ty found) (k.ty expected))
          payload l.payload
      in
      match Unify.atomically env.st (Unify.copier ()) unify_all with
      | Ok () -> ()
      | Error _ ->
          (* a state of its own, as [Unify.atomically] makes, so the new
             variables don't count *)
          let k = Unify.copier ()
          and st = { env.st with level = env.st.level } in
          List.iter2
            (fun found expected ->
              match Unify.unify st (k.ty found) (k.ty expected) with
              | () -> ()
              | exception
                  ((Unify.Mismatch | Unify.Two_shapes _ | Unify.Infinite) as
                   failure) ->
                  mismatch env plain c.loc ~found:(k.ty found)
                    ~expected:(k.ty expected) failure)
            payload l.payload)
  | Some l ->
      report env
        (tag_arity ~value:t.tvalue c.loc c (List.length l.payload)
           (List.length payload))
  | None -> (
      (* a set still open holds what a function it was passed fails with *)
      match
        Option.bind tail (fun tl ->
            List.find_opt (fun (_, ty) -> List.mem tl (row_vars ty)) t.tin)
      with
      | Some (param, _)
        when match row_skolem t.tset with
             | Some (id, _) -> List.mem id env.finally_rows
             | None -> false ->
          (* a `finally`'s result: the `with`'s body's errors *)
          report env (tag_in_body_error c ~arm ~r:param)
      | Some (param, _) ->
          report env (tag_in_open_set c ~arm ~value:t.tvalue ~param tags)
      | None -> report env (not_an_error c ~arm tags))

(* Whether the call [c] can fail, now that its group is done: its callee
   fails with something, which for a function of the group is known only
   now, or its errors are those of a function the caller was passed. *)
let can_fail (c : ecall) =
  row_names c.erow <> []
  ||
  match (row_tail c.erow, row_end c.erow) with
  (* a named row, `call.forward()`'s in a handler `over any`, is
     errors it can't name *)
  | _, RSkol _ -> true
  | Some t, _ -> in_params c.eparams t
  | None, _ -> false

(* A call no marker covers can't fail (errors.md, "Marking"): what it
   fails with went to [unhandled], a row of its own, which ends up empty
   unless it's reported. *)
let unmarked env (c : ecall) unhandled =
  let labels, tail = row_parts unhandled in
  let own t = List.exists (fun e -> row_tail e = Some t) c.eselves in
  match tail with
  | Some t when own t && in_params c.eparams t ->
      (* the call's errors are its caller's own, those of a function it
         was passed *)
      let param, _ =
        List.find (fun (_, ty) -> List.mem t (row_vars ty)) c.eparams
      in
      report env (unhandled_param c.eloc ~name_loc:c.ename_loc c.ename param)
  | _ when labels <> [] && c.einstall ->
      report env
        (unhandled_install c.ename_loc c.ename
           (List.map (show_label (printer env)) labels))
  | _ when labels <> [] ->
      report env
        (unhandled_call c.eloc ~name_loc:c.ename_loc c.ename
           (List.map (show_label (printer env)) labels))
  | Some t when own t ->
      (* the caller's own errors, which it doesn't pass on: it fails with
         none, or this is reported where it does *)
      ()
  | _ -> close_row unhandled

(* Every marker covers something that can fail, and a `match`'s `fail`
   arms match something (errors.md, "Marking"). *)
let marker env m =
  if
    not
      (m.failed
      || List.exists can_fail m.covered
      || List.exists
           (fun r -> row_names r <> [] || row_tail r <> None)
           m.unwrapped)
  then
    report env
      (match m.mkind with
      | Mtry -> covers_nothing m.mloc ?hint:m.hint "try"
      | Mattempt -> covers_nothing m.mloc ?hint:m.hint "attempt"
      | Mmatch | Mmatch_on -> cannot_fail_arm m.mloc)

(* ---- what an operation fails with (deps.md, "Implementations") ---- *)

(* Report that the operation [o] (see [Infer_env.impl_op]) fails with
   [extra], errors its dependency doesn't declare, where it's given. *)
let fails_more env o extra =
  let pr = printer env in
  let op = env.names o.idep ^ "." ^ o.iop in
  (* where it fails: the first call or `fail` in the lambda's body
     that brings in one of [extra] (a `try`'s call with its
     `try`), or else the whole body, or what's given if it isn't a
     lambda *)
  let brings (f : Ast.Resolved.expr) =
    match Option.map repr (Hashtbl.find_opt o.inodes f.node) with
    | Some (TFun (_, _, errs, _)) ->
        List.exists (fun (l : label) -> List.mem l.name (row_names errs)) extra
    | _ -> false
  in
  let rec site (e : Ast.Resolved.expr) =
    match e.kind with
    | Try { kind = Call (f, _); _ } when brings f -> Some e
    | Call (f, _) when brings f -> Some e
    | Fail (t, _) when List.exists (fun (l : label) -> l.name = t.name) extra ->
        Some e
    (* a lambda's calls are its own, and `attempt` keeps them *)
    | Lambda _ | Attempt _ -> None
    | _ -> List.find_map site (Ast.children e)
  in
  let body =
    match o.ivalue.kind with
    | Lambda (_, b) -> Option.value (site b) ~default:b
    | _ -> o.ivalue
  in
  let fix =
    match (body.kind, extra, o.ideclared) with
    | Try ({ kind = Call (f, _); _ } as call), [ l ], d :: _ ->
        (* `try match` passes on what the arms don't handle, if the
           call fails with more. A function's row is open where it's
           called, room for errors it never has, so only a named row
           at its end, whatever a closure fails with, is more *)
        let more =
          match Option.map repr (Hashtbl.find_opt o.inodes f.node) with
          | Some (TFun (_, _, errs, _)) -> (
              List.exists (fun n -> n <> l.name) (row_names errs)
              || match row_end errs with RSkol _ -> true | _ -> false)
          | _ -> true
        in
        Map_call
          { try_ = more; call = env.source call; tag = l.name; into = d.name }
    | Fail _, _, [] -> Give_value
    | Fail _, _, d :: _ -> Fail_instead d.name
    | _, _, [] -> Handle_inside
    | _, _, d :: _ -> Map_inside d.name
  in
  report env
    (impl_fails_more body.loc ~op
       ~shown:(and_list (List.map (show_label pr) extra))
       ~declared:(List.map (fun (l : label) -> l.name) o.ideclared)
       fix)

(* An operation an implementation gives fails with no more than its
   dependency declares: anything more is reported, and then it fails with
   exactly what it's found to. It's what the operation declares, whose
   errors' payloads it has to agree with, and no more. A row still open may
   be a parameter's, `try f()`, which then can fail with what the
   operation can, not with nothing. One already closed with fewer errors
   than declared is fine as it is: an operation can fail with less. *)
let impl_op env o =
  let pr = printer env in
  let declared n = List.exists (fun (l : label) -> l.name = n) o.ideclared in
  (match
     List.filter
       (fun (l : label) -> not (declared l.name))
       (fst (row_parts o.ierrs))
   with
  | [] -> ()
  | extra -> fails_more env o extra);
  (match
     Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
         Unify.unify_row st (c.row o.ierrs) (extend o.ideclared REmpty))
   with
  | Ok () -> ()
  | Error (Unify.Two_shapes name) ->
      (* the `fail` of it, if it's one *)
      let rec at (e : Ast.Resolved.expr) =
        match e.kind with
        | Fail (t, _) when t.name = name -> Some e.loc
        | (Lambda _ | Attempt _) when e != o.ivalue -> None
        | _ -> List.find_map at (Ast.children e)
      in
      report env
        (impl_other_shape
           (Option.value (at o.ivalue) ~default:o.ivalue.loc)
           ~op:(env.names o.idep ^ "." ^ o.iop)
           ~tag:name
           ~shape:
             (show_label pr
                (List.find (fun (l : label) -> l.name = name) o.ideclared)))
  | Error _ -> (
      match row_skolem o.ierrs with
      | Some (_, n) ->
          report env
            (impl_fails_named o.ivalue.loc
               ~op:(env.names o.idep ^ "." ^ o.iop)
               ~declared:(List.map (fun (l : label) -> l.name) o.ideclared)
               n)
      | None ->
          (* a row already closed with fewer errors than declared is fine,
             and one with more was reported by [fails_more] *)
          ()));
  close_row o.ierrs

(* ---- named rows (deps.md, "Implementations") ---- *)

(* `uses Clock, ..d`, what [f] would write to use [n] as well. *)
let uses_with env (f : Ast.Resolved.fn_def) n =
  let deps =
    match f.uses with
    | Some u ->
        List.filter_map
          (fun (d : Ast.tname Ast.dep_ref) ->
            match d.dep.tref with
            | Named p -> Some (env.names p)
            | Param _ -> None)
          u.deps
    | None -> []
  in
  uses_written deps n

(* What the function [f] names its own `uses` row, `..d`, if it does. *)
let own_dtail (f : Ast.Resolved.fn_def) =
  Option.map
    (fun (n : Ast.ident) -> n.name)
    (Option.bind f.uses (fun (u : Ast.Resolved.uses) -> u.dtail))

(* Each use of a named row (see [Infer_env.row_due]) ends the row it's
   added to in that row. A row can end in only one, and only a row still
   open can end in one; and a function that declares what it uses has to
   name the row, or it would use more than it says. Those are reported
   first, and the rest are ended after, in the order they were met: ending
   one before would hide what a function doesn't declare. [declaring] are
   the group's functions that declare what they use, by the variable their
   row ends in. *)
let rows_due env ~declaring ds =
  (* a row can end in only one named row *)
  let two d other =
    report env (two_named_rows d.rloc d.rwhat ~other (snd d.rnamed))
  in
  let later =
    List.filter
      (fun d ->
        let id, n = d.rnamed in
        match row_end d.rinto with
        | RSkol (id', _) when id' = id -> false
        | RSkol (_, other) ->
            two d other;
            false
        | RVar _ -> (
            match
              Option.bind (row_tail d.rinto) (fun t ->
                  List.assoc_opt t declaring)
            with
            | Some f when own_dtail f <> Some n ->
                report env
                  (named_row_undeclared d.rloc d.rwhat n ~fn:(Ast.fn_name f)
                     ~other:(own_dtail f) ~uses:(uses_with env f n));
                false
            | _ -> true)
        | REmpty | RExtend _ ->
            report env (named_row_not_allowed d.rloc d.rwhat n);
            false)
      ds
  in
  List.iter
    (fun d ->
      let id, n = d.rnamed in
      match row_end d.rinto with
      | RSkol (id', _) when id' = id -> ()
      | RSkol (_, other) -> two d other
      | RVar _ as tail ->
          (* a variable still unbound takes any row, so this can't fail *)
          Unify.unify_row env.st tail (RSkol (id, n))
      | REmpty | RExtend _ ->
          report env (named_row_not_allowed d.rloc d.rwhat n))
    later

(* ---- the worklist ---- *)

(* Decide [items], in the order they were met, until none is [awake]:
   [decide] does one, and says whether it did anything. Doing one can wake
   others, any whose source gained a label. Each round goes through those
   still to do in order, and the next round takes those that are awake
   once it's done, until a round does nothing. Looking for them after
   every one done, not once a round, was quadratic: a group of thousands
   of `try f(i)` took seconds. *)
let worklist ~awake ~decide items =
  let rec round todo =
    (* whether any did something: [List.fold_left] carries it through *)
    let did = List.fold_left (fun did i -> decide i || did) false todo in
    if did then
      match List.filter awake items with [] -> () | todo -> round todo
  in
  round items

(* The copies among [cs]. *)
let copies cs = List.filter_map (function Copy k -> Some k | _ -> None) cs

(* The copies [ks], decided until none has anything to add. *)
let copies_of env ks = worklist ~awake:copy_awake ~decide:(copy env) ks

(* The `with`s and blocks among [cs], each once the copies of what an
   implementation needs, [copies], are up to date, since what its body
   uses includes what an implementation used in it needs. Why each
   function of the group still gets a dependency from outside, the first
   reason found for each, and the uses of named rows they make. *)
let installs env ~copies cs =
  let ws = List.filter_map (function Install w -> Some w | _ -> None) cs in
  let withheld, dues =
    List.fold_left
      (fun (withheld, dues) w ->
        copies_of env copies;
        let held, due = install env w in
        (* most recent first, reversed once they're all in *)
        let dues = Option.to_list due @ dues in
        let fresh =
          List.filter
            (fun h ->
              not
                (List.exists
                   (fun h' -> h'.hfn = h.hfn && same_label h'.hdep h.hdep)
                   withheld))
            held
        in
        (withheld @ fresh, dues))
      ([], []) ws
  in
  (withheld, List.rev dues)

(* Decide every pending constraint, and take them off the environment's
   list. [is_value] says whether a function is an associated value, which
   a use joins by its result, and [withheld] why each function of an
   earlier group still gets a dependency from outside. It returns why
   each function of this group does.

   They're decided kind by kind, every one of a kind before the next kind
   starts, and each kind in the order they were met, since a later kind
   reads what an earlier one decides. The uses of the group's functions
   by each other are joined first, since a call of another function of
   the group learns only then what it returns; then a value thrown away is
   checked. What a
   `with` installs is decided next, each `with` once the copies of what
   an implementation needs are up to date, since what its body uses
   includes them. A function that names its own errors' row fails with it
   before the error sets are decided, which need it. A set gets the tags
   written in it before what it includes from other sets, so a tag of two
   shapes is blamed on the inclusion. A kept set is closed once it has
   every tag it gets, and only then are the tags matched in a set checked
   against it. The rules of markers read what every set holds, so they're
   checked after them, and so is what an operation fails with, which has
   every error its calls bring in by then; and the requirements, which
   need every type of the group as it will be. A row is ended in a named row
   only once it has every label it gets, since that stops it getting
   more, and a function's own rows after every use of a named row has
   ended the row it's added to. What each function declares is checked
   last, against all of that; a handler's needs with its function's. *)
let solve env ~is_value ~withheld =
  let cs = List.rev env.pending in
  env.pending <- [];
  let is_fn_value f = is_value (Ast.fn_path env.home f) in
  let checked =
    List.filter_map (function Declared c -> Some c | _ -> None) cs
  in
  List.iter (function Join j -> join env ~is_value j | _ -> ()) cs;
  List.iter (function Drop d -> drop env d | _ -> ()) cs;
  List.iter (function Instance x -> instance env x | _ -> ()) cs;
  let ks = copies cs in
  let held, dues = installs env ~copies:ks cs in
  copies_of env ks;
  (* a copy kept where nothing more can be needed, `Box<Rates>`, says the
     implementation needs only what it has: a transparent parameter's
     row closes with it, which Infer_declared.check_open_rows reports *)
  List.iter
    (function
      | Copy k -> if row_end k.kdst = REmpty then close_row k.ksrc | _ -> ())
    cs;
  List.iter
    (function Own_errors c -> Infer_declared.own_errors env c | _ -> ())
    cs;
  let kept_sets =
    List.filter_map
      (function Kept (k, p, at) -> Some (k, p, at) | _ -> None)
      cs
  in
  (* the tags that went in are no longer checked with the patterns *)
  let added =
    List.filter_map
      (function
        | Value_tag t
          when value_tag env ~kept:(List.map (fun (k, _, _) -> k) kept_sets) t
          ->
            Some t
        | _ -> None)
      cs
  in
  let into = List.filter_map (function Include i -> Some i | _ -> None) cs in
  worklist ~awake ~decide:(include_ env) into;
  List.iter (written_kept env ~into) kept_sets;
  List.iter kept kept_sets;
  (* a set the tags written as values went in, one of their own, holds
     those and no more, as a kept set does: `if c then Err(Left(1)) else
     Err(Right)` is `! Left(Int) | Right`, and a set met later, in another
     group, can't add to it *)
  List.iter (fun t -> close_row t.tset) added;
  (* the patterns, and the tags written as values that didn't go in, in
     the order they were met *)
  List.iter
    (function
      | Tag_pattern t -> tag_pattern env t
      | Value_tag t when not (List.memq t added) -> tag_pattern env t
      | _ -> ())
    cs;
  List.iter (function Unmarked (c, r) -> unmarked env c r | _ -> ()) cs;
  List.iter (function Marker m -> marker env m | _ -> ()) cs;
  List.iter (function Impl_op o -> impl_op env o | _ -> ()) cs;
  (* the arm of a handler `over any` fails with what it fails with now:
     its tags are its type's, which a `with` checks *)
  List.iter
    (function
      | Any_arm { aerrs; atags } ->
          let labels = fst (row_parts aerrs) in
          ignore
            (Unify.atomically env.st (Unify.copier ())
               (fun st (c : Unify.copy) ->
                 Unify.unify_row st (c.row atags) (extend labels REmpty)));
          close_row aerrs
      | _ -> ())
    cs;
  (* what's compared, and what's given to a function that compares it,
     once every type of the group is known *)
  Infer_reqs.decide env cs;
  (* the uses of named rows, with those the `with`s made last, given the
     group's functions that declare what they use, by the variable their
     row ends in *)
  rows_due env
    ~declaring:
      (List.filter_map
         (fun c ->
           if Infer_declared.declares_uses ~is_value:is_fn_value c.ffn then
             Option.map (fun t -> (t, c.ffn)) (row_tail c.fcx.uses)
           else None)
         checked)
    (List.filter_map (function Row_due d -> Some d | _ -> None) cs @ dues);
  List.iter
    (function
      | Own_rows c -> Infer_declared.own_rows env ~is_value:is_fn_value c
      | _ -> ())
    cs;
  (* what's checked of the rows as they turned out, in the order met *)
  List.iter (function Later f -> f () | _ -> ()) (List.rev cs);
  let needs = List.filter_map (function Needs n -> Some n | _ -> None) cs in
  List.iter
    (function
      | Declared c ->
          Infer_declared.check_declared env ~is_value:is_fn_value
            ~withheld:(withheld @ held) ~needs c
      | _ -> ())
    cs;
  held
