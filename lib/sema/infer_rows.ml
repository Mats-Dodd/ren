(* Rows and effects (see infer_expr.ml): what a function fails with, `!`,
   and what it uses, `uses`. A call adds its callee's dependencies to its
   caller's, and its errors to whatever marks it: a `try`, an `attempt` or
   a `match` with `fail` arms (errors.md, "Marking"). Errors are added by
   inclusion, so a callee never fails with what its caller does, and an
   implementation's needs are copied to each place it's used. What a row
   learns only once its group is done is left to the constraint solver
   (solve.ml). *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written

(* An open row is unified with another as it is, which is how its tail
   picks up everything the other has. A closed one, like a stored `fn()`'s,
   says only what it has itself: unified as it is, it would close the other
   row too, and then nothing else could be added to it. So it's opened
   first, with a fresh tail. *)
let reopen env r =
  let rec go r =
    match repr_row r with
    | REmpty -> fresh_row env.st
    | RExtend (l, rest) -> RExtend (l, go rest)
    | r -> r
  in
  go r

(* What an implementation needs, [needs], copied for one place it's used
   at [loc] (see [copy]), which [what] says: the same labels, and a tail
   of its own. A closed row is just opened, since it learns nothing more,
   and a named one, `..d`, is kept, since it stands for the same labels
   everywhere. *)
let copy_needs env ~loc ~what needs =
  match (row_skolem needs, row_tail needs) with
  | Some _, _ | _, None -> reopen env needs
  | None, Some _ ->
      let labels = fst (row_parts needs) in
      let copy = extend labels (fresh_row env.st) in
      defer env
        (Copy
           {
             kloc = loc;
             ksrc = needs;
             kdst = copy;
             kwhat = what;
             kpassed = List.map (fun (l : label) -> l.name) labels;
           });
      copy

(* [t], used at [loc], or if it's an implementation, one that may need
   more than it does: where one that needs more is allowed, one that needs
   less will do. *)
let widen env ~loc t =
  match impl_parts t with
  | Some (ds, u) -> impl_type ds (copy_needs env ~loc ~what:Passing u)
  | None -> t

(* Where an error that's already in [row] came from, for a message about
   another shape of it: the first of [sources] that brought it in. *)
let shape_from (sources : source list) name =
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let loc = function
    | Passed c -> c.eloc
    | Failed (l, _) | Unwrapped (l, _) | Unhandled (l, _) -> l
  in
  let has = function
    | Passed c -> List.exists (fun (l : label) -> l.name = name) c.eown
    | Failed (_, l) -> l.name = name
    | Unwrapped (_, r) | Unhandled (_, r) -> List.mem name (row_names r)
  in
  List.find_opt has
    (List.sort (fun a b -> compare (pos (loc a)) (pos (loc b))) sources)
  |> Option.map (function
    | Passed c -> From c.ewritten
    | Failed (l, _) -> On_line ("fail", l.start.line)
    | Unwrapped (l, _) -> On_line ("Result", l.start.line)
    | Unhandled (l, _) -> On_line ("match", l.start.line))

(* What the code [cx] is in has already added to its handler, for a
   message about an error that's there: in the function itself, what adds
   to its errors; in an `attempt` or a lambda, the calls the innermost
   marker has covered so far. If it's none of them, it's what's written in
   the function's signature, or else an earlier call. *)
let sources_of cx =
  match (cx.sources, cx.markers) with
  | Some s, _ -> (!s, Signature)
  | None, m :: _ -> (List.map (fun c -> Passed c) m.covered, Earlier_call)
  | None, [] -> ([], Earlier_call)

(* The same, read when it's needed, which can be once the group is done:
   then it has what's added after the code being checked too, a `fail`
   later in the function, say. [this] is what that code adds itself,
   which isn't where its own errors come from. *)
let sources_later cx ~this () =
  let sources, origin = sources_of cx in
  (List.filter (fun s -> not (this s)) sources, origin)

(* [r]'s labels, without the tags [names], as what's failed with. *)
let without names r =
  extend
    (List.filter_map
       (fun (l : label) ->
         if List.mem l.name names then None else Some (unwritten l))
       (fst (row_parts r)))
    REmpty

(* Report that adding [errs] to a row failed with [failure] (see
   [add_errors]): one of its tags is there with another shape, or the row
   can't fail with them. [before] are the labels the row had. *)
let add_failed env ~loc ~here ~sources:(sources, elsewhere) ~fix ~before errs
    failure =
  match failure with
  | Unify.Two_shapes name ->
      let pr = printer env in
      let shape ls =
        Option.map
          (fun (l : label) -> show_label pr l)
          (List.find_opt (fun (l : label) -> l.name = name) ls)
      in
      let old_from =
        Option.value (shape_from sources name) ~default:elsewhere
      in
      report env
        (two_shapes loc name
           ~old:(old_from, Option.value (shape before) ~default:name)
           ~new_:
             (here, Option.value (shape (fst (row_parts errs))) ~default:name)
           ~help:(fix name))
  | _ ->
      report env
        (cant_fail_here loc ~in_state:env.in_state
           (show_row (printer env) ~prefix:"" ~sep:" | " ~kind:"e" errs))

(* Add [errs], what's new here (a call's, a `fail`'s), to [into]. One error
   with two shapes is reported: [here] says where the new one comes from,
   and [sources] where the old one may have, for the message
   (module-build.md, "Error tags have no home"); [fix] is the help, given
   the tag. [sources] is a function, called only for the message: finding
   them goes through every call the function has made so far, which for
   every call would be quadratic. *)
let add_errors env ~loc ~here ~sources ~fix errs into =
  (* the labels already there, before they're unified with the new ones *)
  let before = fst (row_parts into) in
  (* only [errs]'s labels, with a fresh tail: unified with its own tail,
     [errs] would become [into], and fail with everything [into] does.
     Tried on copies first, so if it fails, nothing changes *)
  let added =
    extend (List.map unwritten (fst (row_parts errs))) (fresh_row env.st)
  in
  match
    Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
        Unify.unify_row st (c.row added) (c.row into))
  with
  | Ok () -> ()
  | Error failure ->
      add_failed env ~loc ~here ~sources:(sources ()) ~fix ~before errs failure

(* Add [errs] to [into] by inclusion (see [inclusion]): its labels now,
   and what it learns later, once the group is done, by the constraint
   solver (solve.ml). [without] are tags it doesn't pass on, and
   [sources] gives the [sources] of [add_errors] when it's called. *)
let include_errors env cx ~loc ~here ~sources ~fix ?without:handled errs into =
  add_errors env ~loc ~here ~sources ~fix
    (match handled with Some names -> without names errs | None -> errs)
    into;
  defer env
    (Include
       {
         iloc = loc;
         isrc = errs;
         idst = into;
         iparams = cx.params;
         ihere = here;
         isources = sources;
         ifix = fix;
         iwithout = Option.value handled ~default:[];
         ipassed = row_names errs;
         ilinked = false;
       })

(* Whether [cx] is the body of the top-level function itself, and not of
   a lambda in it: its errors are the function's own. *)
let in_own_body env cx =
  match Option.map repr (Hashtbl.find_opt env.globals cx.self) with
  | Some (TFun (_, _, errs, _, _)) -> row_tail errs = row_tail cx.errs
  | _ -> false

(* Add [uses], what a call's callee uses, or what an implementation a
   `with` installs needs ([needs]), to the dependencies of the function or
   lambda [cx] is in. A row that ends in a named row, `..d`, has its labels
   added now and the named row once the group is done (see [row_due]). A
   function calling itself inside one of its `with`s gets a copy of what
   it uses (see [copy]): joined as it is, the function's own row would be
   the `with`'s body's, and what the `with` installs would end up in the
   function's `uses`. *)
let rec use_row env cx ~loc ?(needs = false) ?callee uses =
  cx.calls :=
    { cloc = loc; own = row_names uses; row = uses; needs; callee }
    :: !(cx.calls);
  let what = if needs then Installing else Call_uses in
  let joined =
    match row_skolem uses with
    | Some named ->
        defer env
          (Row_due { rloc = loc; rinto = cx.uses; rnamed = named; rwhat = what });
        extend (fst (row_parts uses)) (fresh_row env.st)
    | None
      when callee = Some cx.self
           && row_tail uses <> None
           && row_tail uses <> row_tail cx.uses
           && in_own_body env cx ->
        copy_needs env ~loc ~what uses
    | None -> reopen env uses
  in
  join_uses env ~loc ~what joined cx.uses

(* Join [joined], what's used at [loc], to [into], what the function or
   lambda it's in uses, or say it can't use all of that. [what] says what
   uses it: a call, a `with`.

   The two can already end in the same variable, with labels [into]
   doesn't have: `fn twice(k) = { let a = run(k); a + k() }`, where [run]
   installs `Rates` around its call of [k], so [k] uses `Rates` and
   whatever [run] uses, and [twice] so far only the latter. Unified, they'd
   have to be equal, which they can't be, sharing a tail (unify.ml), but
   all that has to hold is that [into] has what [joined] has. So the labels
   it lacks are added to their tail, and [joined] then holds them twice:
   once as its own, once from the tail. A row can hold a label twice, as
   Koka's can, and for a set of dependencies or errors that means what
   holding it once does (Types.row_parts, Unify.unify_row). A named row,
   `..d`, can't gain a label, so that's still an error. *)
and join_uses env ~loc ~what joined into =
  let labels, tail = row_parts joined in
  match row_end joined with
  | RVar _ as t when tail = row_tail into ->
      let have = row_names into in
      let missing =
        List.filter (fun (l : label) -> not (List.mem l.name have)) labels
      in
      (* a variable still unbound takes any row, so this can't fail *)
      if missing <> [] then
        Unify.unify_row env.st t (extend missing (fresh_row env.st))
  | _ -> (
      (* tried on copies first, so if it fails, nothing changes *)
      match
        Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
            Unify.unify_row st (c.row joined) (c.row into))
      with
      | Ok () -> ()
      | Error _ -> report env (cant_use loc what (dep_names env joined)))

(* A call adds the callee's dependencies to the caller's, and its errors
   to whatever marks it (errors.md, "Marking"): the innermost marker's
   handler, the caller's own errors for a `try` or the `attempt`'s. A call
   no marker covers can't fail: its errors go to a row of their own, which
   has to end up empty once the group is done (solve.ml). [ename] and
   [fn] are the callee, as a message names it and as it's written, and
   [target] the function of the group it calls, if it does. *)
let absorb env cx ~(call : expr) ~ename ~(fn : expr) ?target ?callee errs uses =
  let name_loc = fn.loc in
  use_row env cx ~loc:call.loc ?callee uses;
  let ewritten =
    match call.kind with
    | Call (f, _) | Ref { kind = Call (f, _); _ } ->
        Option.value (env.source f) ~default:ename
    | _ -> ename
  in
  (* a call whose errors are the caller's own brings in nothing itself *)
  let self =
    match (row_tail errs, row_tail cx.errs) with
    | Some a, Some b -> a = b
    | _ -> false
  in
  let own = if self then [] else fst (row_parts errs) in
  let ec =
    {
      eloc = call.loc;
      ename_loc = name_loc;
      ename;
      ewritten;
      eown = own;
      eself = self;
      erow = errs;
      etarget = target;
      eparams = cx.params;
      eselves = cx.selves;
    }
  in
  let sources =
    sources_later cx ~this:(function Passed c -> c == ec | _ -> false)
  in
  let here = From ewritten in
  (* rename the one this call brings in: `fail Timeout(a) => fail
     LockTimeout(a)` *)
  let fix tag =
    let arity =
      match List.find_opt (fun (l : label) -> l.name = tag) own with
      | Some l -> List.length l.payload
      | None -> 0
    in
    rename_call_tag ~call:(env.source call) ~callee:(short_callee fn) ~arity tag
  in
  (* In a public function, a transparent parameter's errors are the
     function's own, passed on to its caller, as its signature says: an
     `attempt` can't keep them as well, nor a `match` handle them *)
  let passed_on =
    List.mem cx.self env.spelled
    && row_tail cx.handler <> row_tail cx.errs
    && row_tail errs <> None
    && List.exists (fun r -> row_tail r = row_tail errs) cx.selves
  in
  match cx.markers with
  | m :: _ when passed_on && m.mkind <> Mtry ->
      report env
        (kept_passed_on call.loc ~name_loc ename ~fn:(Path.short cx.self)
           ~handled:(m.mkind = Mmatch));
      List.iter (fun m -> m.covered <- ec :: m.covered) cx.markers
  | [] ->
      (* the callee's own row, which an inferred parameter's is too: if
         nothing else says it fails, it's closed at the end, and the
         parameter can't fail *)
      defer env (Unmarked (ec, reopen env errs))
  | markers ->
      List.iter (fun m -> m.covered <- ec :: m.covered) markers;
      include_errors env cx ~loc:call.loc ~here ~sources ~fix errs cx.handler;
      Option.iter (fun s -> s := Passed ec :: !s) cx.sources

(* The first [n] characters of [loc], a keyword at its start. *)
let keyword (loc : Loc.t) n =
  { loc with stop = { loc.start with col = loc.start.col + n } }

(* A new marker at [mloc], kept for the checks at the end of the group. *)
let marker env mkind mloc =
  let m =
    { mkind; mloc; covered = []; unwrapped = []; hint = None; failed = false }
  in
  defer env (Marker m);
  m

(* Why a `try` of [a], of type [t], which isn't a [Result], may cover
   nothing: [a] is a [Result] whose type isn't known yet, or `try` covers
   more than it seems to, everything to its right, as in `try r + try r`. *)
let try_hint env cx (a : expr) t =
  let is_result t =
    match reveal env.st t with TCon (p, _) -> p = result_path | _ -> false
  in
  let rec leftmost (e : expr) =
    match e.kind with Binop (_, l, _, _) -> leftmost l | _ -> e
  in
  match (a.kind, reveal env.st t) with
  | Var x, TVar _ -> Some (Maybe_result (name_of x))
  | Binop _, _ -> (
      let l = leftmost a in
      match Hashtbl.find_opt cx.nodes l.node with
      | Some lt when is_result lt ->
          Some (Covers_right (env.source a, env.source l))
      | _ -> None)
  | _ -> None

(* A `fail` pattern, which matches an error rather than a value (errors.md,
   "Handling: `match`"). The parser combines only `fail` patterns with
   `|`. *)
let is_fail (p : pattern) =
  match p.pkind with PFail _ | PFail_any | POr _ -> true | _ -> false

(* Whether a `match` handles errors: whether it has a `fail` arm. *)
let handles arms = List.exists (fun a -> is_fail a.arm_pat) arms

(* The tags a `match`'s arms handle whatever their payload: each in an arm
   without a guard whose payload patterns match anything. [None] if an
   arm is `fail _`, which handles every error. A tag matched only for some
   payloads, `fail Short(_, 0)`, isn't handled: it can still happen. *)
let handled_tags arms =
  let any (p : pattern) =
    match p.pkind with PWild | PVar _ -> true | _ -> false
  in
  let rec tags (p : pattern) =
    match p.pkind with
    | PFail_any -> None
    | PFail (t, ps) -> Some (if List.for_all any ps then [ t.name ] else [])
    | POr ps ->
        List.fold_left
          (fun acc p ->
            match (acc, tags p) with
            | Some a, Some b -> Some (a @ b)
            | _ -> None)
          (Some []) ps
    | _ -> Some []
  in
  List.fold_left
    (fun acc a ->
      match (acc, a.arm_guard) with
      | None, _ -> None
      | acc, Some _ -> acc
      | Some ts, None -> Option.map (( @ ) ts) (tags a.arm_pat))
    (Some []) arms

(* The error set of `Err(tag(payload))`, where a value of type [expected]
   is wanted. Where that's a `Result` whose errors are what something can
   fail with, a function's declared result or what an `attempt` kept, the
   tag has to be one of them, as in a pattern (infer_expr.ml,
   [tag_pattern]): `attempt f() == Err(Shrot)` is an error, not a
   comparison that's always false. An open set is checked when its group
   is done. Anywhere else the tag's set isn't known yet, as when the `Err`
   is on the left of `==`: it starts with no tags, and once the group is
   done the tag is checked against what the set turned out to be, or, if
   it's a set of its own, added to it: `if c then Err(A) else Err(B)`.
   Adding it now would let a kept set it's unified with later gain it. *)
let err_row env cx (tag : ident) args ~expected =
  let payload = List.map fst args in
  let wanted =
    match reveal env.st expected with
    | TCon (p, [ _; errs ]) when p = result_path -> (
        match repr errs with
        | TErrors row -> (
            match row_tail row with
            | None -> Some row
            | Some t when kept env t -> Some row
            | Some _ -> None)
        | _ -> None)
    | _ -> None
  in
  let later row =
    let t =
      {
        ttag = tag;
        tpayload = payload;
        tset = row;
        tin = cx.params;
        tarm = false;
        tvalue = true;
      }
    in
    (* checked with the tags in patterns, unless the solver adds it to a
       set of its own *)
    defer env (Value_tag t);
    row
  in
  match wanted with
  | None -> later (fresh_row env.st)
  | Some row -> (
      let labels, tail = row_parts row in
      match
        (List.find_opt (fun (l : label) -> l.name = tag.name) labels, tail)
      with
      | Some l, _ when List.length l.payload = List.length payload ->
          List.iter2
            (fun (found, (a : expr)) expected ->
              unify_at env (result_loc a) ~found ~expected
                ~msg:(tag_holds tag.name)
                ~notes:[ its_shape (show_label (printer env) l) ])
            args l.payload;
          row
      | Some l, _ ->
          report env
            (tag_arity ~value:true tag.loc tag (List.length l.payload)
               (List.length payload));
          row
      | None, None ->
          let pr = printer env in
          report env
            (not_an_error tag
               (List.map (fun (l : label) -> (l.name, show_label pr l)) labels));
          row
      | None, Some _ -> later row)

(* What the `try` [m] of a `try match` passes on: the errors [errs] of
   [subject] that no arm handles, by inclusion, through a row of their
   own, which [m] fails with. With a `fail _` arm, nothing is left, and
   [m] covers nothing. *)
let pass_on env cx m (subject : expr) arms errs =
  match handled_tags arms with
  | None -> m.hint <- Some All_handled
  | Some names ->
      let rest = fresh_row env.st in
      defer env (Kept (rest, cx.params, None));
      (* what's added to these sources as the rest of the function is
         checked is still there to say where a tag came from *)
      let sources () = sources_of cx in
      include_errors env cx ~loc:subject.loc ~here:(This "match") ~sources
        ~fix:rename_where_in ~without:names errs rest;
      include_errors env cx ~loc:subject.loc ~here:(This "match") ~sources
        ~fix:rename_where_in rest cx.handler;
      m.unwrapped <- rest :: m.unwrapped;
      Option.iter (fun s -> s := Unhandled (subject.loc, rest) :: !s) cx.sources
