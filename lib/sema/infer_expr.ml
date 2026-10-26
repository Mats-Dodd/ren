(* Inferring the types of expressions (see infer.ml for the whole pass).

   Inference is bidirectional (module-build.md, "In the compiler"). [infer]
   works out an expression's type from the expression alone. [check] also
   knows the type the expression is expected to have, and passes it down to
   where it helps: into a block's last line, an `if`'s branches and a
   `match`'s arms, to a lambda, which takes its parameters' types from it,
   and to a constructor or record literal, which is found through it. A
   call's arguments are checked left to right against the callee's
   parameter types, so what one argument settles is known to the next.

   Constructors, record fields, record literals without a type name and
   methods called with a dot, `s.push(1)`, are all found through a type, by
   one lookup (Infer_lookup.through_type) in the three steps of
   module-build.md. Nothing waits: a question that can't be answered where
   it's asked is an error that says which annotation would answer it, so
   the result never depends on the order inference happens to learn things
   in. An implementation of several dependencies, `Rates & RateCalls`, is
   narrowed to some of them only where [check]'s expected type is written
   ([narrow]), never where it's a variable inference has solved. Its own
   type is whatever inference knows of it there: types flow left to right,
   as in Rust and TypeScript (deps.md, "Implementations").

   As it goes, inference records every expression's and pattern's type by
   its node id, and what each lookup found. infer_top.ml hands the table on
   in canonical form, for the passes after it.

   This file is the core of it, [check] and [synth]. The rest is split by
   concern, into modules beside it: infer_env.ml has the types they all
   share, infer_report.ml reports a mismatch and explains it,
   infer_written.ml turns written types into the checker's,
   infer_lookup.ml finds things through a type, infer_rows.ml keeps
   track of what code fails with and uses, and infer_handlers.ml checks
   handlers and `with`. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written
open Infer_lookup
open Infer_rows
open Infer_handlers

(* ---- expressions ---- *)

let want_int env use (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int ~notes:[ int_note use ]

let want_bool env use (e : expr) t =
  unify_at env e.loc ~found:t ~expected:bool ~notes:[ bool_note use ]

(* How to explain a mismatch with [expected], the type of a parameter of
   [callee]: when a statement of [callee] threw away a value whose type
   wasn't known, that made it `Unit`, and a `Unit` in [expected] may well be
   that one, which the caller can't see. So the mismatch points back at the
   statement. *)
let forced_why env callee expected =
  let rec has_unit t =
    match repr t with
    | TCon (p, args) -> p = Path.prelude "Unit" || List.exists has_unit args
    | TFun (ps, ret, _, _, _) ->
        List.exists (fun (p : param) -> has_unit p.ty) ps || has_unit ret
    | _ -> false
  in
  match callee with
  | Some c when has_unit expected ->
      let sites =
        List.filter_map
          (fun (f, loc) -> if f = c then Some loc else None)
          env.forced
      in
      let label loc = (loc, forced_unit (Path.local c)) in
      let help = forced_unit_help (Path.local c) in
      if sites = [] then plain
      else
        explain
          ~help:(fun _ _ -> help)
          ~labels:(fun _ _ -> List.map label sites)
          ()
  | _ -> plain

(* [e], of type [t], where a value of type [expected] is wanted, which is
   written: if [e] is an implementation of several dependencies, and
   [expected] one of some of them, it's narrowed to those there, which
   lowering is told. It still describes the same handler, but its other
   dependencies can't be reached through it (deps.md, "Implementations").
   Its type there, or else [t]. [t] is what inference knows of [e]'s type
   by now: a lambda's parameter that a generic's `T` gave a type to
   already is narrowed, one whose type comes later isn't. *)
let narrow env cx (e : expr) t expected =
  match (impl_parts t, impl_parts (reveal env.st expected)) with
  | Some (have, needs), Some (want, _)
    when List.length want < List.length have
         && List.for_all (fun d -> List.mem d have) want ->
      Hashtbl.replace cx.narrowed e.node want;
      impl_type want needs
  | _ -> t

(* Whether [e] is made in branches, which [check] narrows one by one. *)
let branchy (e : expr) =
  match e.kind with Block _ | If (_, _, Some _) | Match _ -> true | _ -> false

(* [e]'s type, from [e] alone. *)
let rec infer env cx (e : expr) : ty =
  let t = synth env cx e in
  Hashtbl.replace cx.nodes e.node t;
  t

(* Check [e] against [expected], explaining a mismatch with [why]. When
   nothing is known about [expected] yet, that's inferring [e] and unifying
   the two. [written] is the type written where [e] is, an annotation or a
   declaration (Infer_written.is_written), usually [expected] itself: an
   implementation of several dependencies is narrowed to what it asks for
   ([narrow]). It's passed down only to the parts of it that are written
   too. *)
and check env cx ?(why = plain) ?written (e : expr) expected =
  let leaf () =
    let t = synth env cx e in
    Hashtbl.replace cx.nodes e.node t;
    let t =
      match written with
      | Some w when impl_parts w <> None ->
          (* one that needs less than what's written will do too *)
          widen env ~loc:e.loc (narrow env cx e t w)
      | Some w -> narrow env cx e t w
      | None -> t
    in
    ignore (unifies env why (result_loc e) ~found:t ~expected)
  in
  let fits () = Hashtbl.replace cx.nodes e.node expected in
  (* the expected type, and what's written of it, go to where the value is
     made *)
  let branches () =
    fits ();
    match e.kind with
    | Block (stmts, last) ->
        List.iter (stmt env cx) stmts;
        check env cx ~why ?written last expected
    | If (c, t, Some f) ->
        want_bool env Condition c (infer env cx c);
        check env cx ~why ?written t expected;
        check env cx ~why ?written f expected
    | Match (subject, arms) ->
        ignore
          (infer_match env cx e.node subject arms
             ~want:(Some (expected, why, written)))
    | _ -> assert false
  in
  match (e.kind, reveal env.st expected) with
  | Con (c, args), _ ->
      let t = infer_con env cx e c args ~written ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Record (name, fields), _ ->
      let t = infer_record env cx e name fields ~written ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  (* a block, an `if` or a `match` passes a written type on to where its
     value is made, even where what's expected is still a variable, the
     payload of a constructor `Option<Rates>` is written for *)
  | (Block _ | If (_, _, Some _) | Match _), TVar _ when written <> None ->
      branches ()
  | _, TVar _ -> leaf ()
  | (Block _ | If (_, _, Some _) | Match _), _ -> branches ()
  | Lambda (params, body), TFun (eps, eret, _, _, _)
    when List.length eps = List.length params
         && List.for_all2
              (fun (p : Resolved.param) (ep : Types.param) -> p.pmode = ep.mode)
              params eps ->
      (* the parameters take their types from where the lambda is going,
         unless they're written; the whole type is unified with the expected
         one at the end, which also checks what the body fails with and
         uses *)
      let ps =
        List.map2
          (fun (p : Resolved.param) ep ->
            if p.pty = None then ep
            else param_type env ~tparams:cx.tparams ~named:cx.named p)
          params eps
      in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      (* numbered before the lambdas in its body, as when it's inferred *)
      let lams = lambda_set env cx e.node in
      bind_params cx params ps;
      check env
        (lambda_cx cx params ps ~errs ~uses)
        body eret
        ?written:
          (match written with
          | Some (TFun (_, r, _, _, _)) when is_written r -> Some r
          | _ -> None)
        ~why:
          (explain ~notes:why.notes ?help:why.help
             ?narrowed_help:why.narrowed_help ~labels:why.labels
             ~msg:lambda_produces ());
      let t = TFun (ps, eret, errs, uses, lams) in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Handler { deps; state; arms; _ }, t
    when match impl_parts t with
         | Some (ds, _) -> ds = List.sort_uniq compare (handler_deps deps)
         | None -> false ->
      (* what it's written to need, and more, which is reported once the
         group is done *)
      fits ();
      let declared = snd (Option.get (impl_parts t)) in
      let labels = fst (row_parts declared) in
      let needs = extend labels (fresh_row env.st) in
      handler core env cx state arms ~needs
        ~declared:(Some (List.map (fun (l : label) -> l.name) labels))
  | Array xs, TCon (p, [ elem ]) when p = Path.prelude "Array" ->
      fits ();
      List.iter
        (fun x ->
          check env cx
            ~why:{ plain with notes = why.notes }
            ?written:
              (match written with
              | Some (TCon (_, [ w ])) when is_written w -> Some w
              | _ -> None)
            x elem)
        xs
  | _ -> leaf ()

(* The type of [e], not yet recorded. *)
and synth env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Bool _ -> bool
  | Str _ -> str
  | Unit -> unit
  | Var x -> lookup env cx ~node:e.node e.loc x
  | Unop (Neg, a) ->
      want_int env (Operator "-") a (infer env cx a);
      int
  | Unop (Not, a) ->
      want_bool env Negated a (infer env cx a);
      bool
  | Binop (op, a, b) -> (
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod | Lt | Le | Gt | Ge ->
          let ta = infer env cx a in
          let tb = infer env cx b in
          want_int env (Operator name) a ta;
          want_int env (Operator name) b tb;
          if List.mem op [ Lt; Le; Gt; Ge ] then bool else int
      | And | Or ->
          want_bool env (Side name) a (infer env cx a);
          want_bool env (Side name) b (infer env cx b);
          bool
      | Orelse ->
          (* the value in the `Option`, or else the right side, which is
             usually a `fail`, whose type is anything *)
          let v = fresh_var env.st in
          unify_at env (result_loc a) ~found:(infer env cx a)
            ~expected:(TCon (option_path, [ v ]))
            ~msg:orelse_left ~help:orelse_left_help;
          check env cx b v
            ~why:
              (explain ~msg:orelse_right
                 ~help:(fun _ _ -> orelse_right_help)
                 ());
          v
      | Eq | Neq ->
          (* the left side says what the right side has to be, and that
             has to have `==`, which is known once the group's types are *)
          let ta = infer env cx a in
          check env cx b ta
            ~why:
              (explain ~msg:(compares name)
                 ~labels:(fun _ x -> [ (a.loc, this_is x) ])
                 ());
          defer env (Compared { qty = ta; qloc = e.loc; qop = name });
          bool)
  | If (c, t, Some f) ->
      want_bool env Condition c (infer env cx c);
      let tt = infer env cx t in
      let else_why =
        explain ~msg:else_branch
          ~labels:(fun _ x -> [ (result_loc t, then_branch x) ])
          ~notes:[ if_branches ] ~narrowed_help:if_produces ()
      in
      check env cx f tt ~why:else_why;
      tt
  | If (c, t, None) ->
      want_bool env Condition c (infer env cx c);
      let ok =
        unifies env
          (explain ~msg:no_else ~help:(fun _ _ -> no_else_help) ())
          (result_loc t) ~found:(infer env cx t) ~expected:unit
      in
      (* if it was meant to produce a value, it isn't a `Unit` *)
      if ok then unit else TError
  | Call (f, args) -> infer_call env cx e f args
  | Lambda (params, body) ->
      let ps =
        List.map (param_type env ~tparams:cx.tparams ~named:cx.named) params
      in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      let lams = lambda_set env cx e.node in
      bind_params cx params ps;
      let tb = infer env (lambda_cx cx params ps ~errs ~uses) body in
      TFun (ps, tb, errs, uses, lams)
  | Block (stmts, last) ->
      List.iter (stmt env cx) stmts;
      infer env cx last
  | Con (c, args) ->
      infer_con env cx e c args ~written:None ~expected:(fresh_var env.st)
  | Record (name, fields) ->
      infer_record env cx e name fields ~written:None
        ~expected:(fresh_var env.st)
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) -> infer_match env cx e.node subject arms ~want:None
  | Array xs -> infer_array env cx xs
  | Index (a, i) ->
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain ~msg:not_indexable ())
          (result_loc a) ~found:(infer env cx a) ~expected:(array elem)
      in
      want_int env Indexing i (infer env cx i);
      if ok then elem else TError
  | Ref ({ kind = Call (f, args); _ } as call) ->
      (* `&s.push(1)`: a method call that changes its receiver *)
      let t = infer_call env cx ~changed:e.loc call f args in
      Hashtbl.replace cx.nodes call.node t;
      t
  | Ref a ->
      (* mut.ml allows `&` only on call arguments, `for` loops and method
         calls; the first two handle it themselves *)
      infer env cx a
  | Assign { target; op; value } ->
      let tt = infer env cx target in
      (match op with
      | Some op ->
          let name = binop_to_string op ^ "=" in
          want_int env (Operator name) target tt;
          want_int env (Operator name) value (infer env cx value)
      | None ->
          (* a place whose type is written narrows what's assigned to it,
             as it does what it's made with *)
          let narrowed_help =
            match target.kind with
            | Var (Local b) when impl_parts tt <> None ->
                Some (assigned_var b.ident.name)
            | _ -> None
          in
          check env cx value tt
            ?written:(if written_place cx target then Some tt else None)
            ~why:(explain ~msg:assigned ?narrowed_help ()));
      unit
  | For { var; iter; body } ->
      let array_of = match iter.kind with Ref a -> a | _ -> iter in
      let ta = infer env cx array_of in
      Hashtbl.replace cx.nodes iter.node ta;
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain ~msg:not_iterable ())
          (result_loc array_of) ~found:ta ~expected:(array elem)
      in
      Hashtbl.replace cx.locals var.id (if ok then elem else TError);
      (* each time round, the body's value is thrown away, as a
         statement's is *)
      dropped env cx (result_of body) (infer env cx body);
      unit
  | Fail (tag, args) ->
      (* the error joins whatever handles the code here, by inclusion, as
         a call's do, so the solver knows what an `attempt` around it
         fails with; a field's name in the payload only documents it *)
      let payload = List.map (fun (_, a) -> infer env cx a) args in
      let l = { name = tag.name; payload; written = unmarked () } in
      include_errors env cx ~loc:e.loc ~here:(This "fail")
        ~sources:(fun () -> sources_of cx)
        ~fix:rename_fail (extend [ l ] REmpty) cx.handler;
      Option.iter (fun s -> s := Failed (e.loc, l) :: !s) cx.sources;
      List.iter (fun m -> if m.mkind <> Mtry then m.failed <- true) cx.markers;
      (* it never produces a value, so it can stand where any type is
         wanted *)
      fresh_var env.st
  | Try ({ kind = Match (subject, arms); _ } as a) when handles arms ->
      (* `try match`: the errors no arm handles are passed on. The arms
         aren't covered by the `try`: a call in one is marked like any
         other *)
      let m = marker env Mtry (keyword e.loc 3) in
      let t = infer_match env cx ~passed:m a.node subject arms ~want:None in
      Hashtbl.replace cx.nodes a.node t;
      t
  | Try a -> (
      let m = marker env Mtry (keyword e.loc 3) in
      (* the `try` around a group's test in a run of it, which needn't
         cover anything: the test may fail with nothing *)
      if e.node = Test_items.passed_on then m.failed <- true;
      let t = infer env { cx with markers = m :: cx.markers } a in
      (match (a.kind, Hashtbl.find_opt cx.found a.node) with
      | Con (_, [ (_, tag) ]), Some (Ctor_of (p, "Err")) when p = result_path ->
          (* `fail` is the way to fail with a tag written in place. A
             `Result` made with `Err` and kept in a `let` is passed on like
             any other (deps.md, "Deviations") *)
          report env (try_err e.loc (env.source tag))
      | _ -> ());
      (* `try r`, where [r] is a [Result]: what's in [r] if it's `Ok`, and
         if it's `Err`, its error again *)
      match reveal env.st t with
      | TCon (p, [ v; errs ]) when p = result_path -> (
          match repr errs with
          | TErrors errs ->
              Hashtbl.replace cx.found e.node Unwraps;
              include_errors env cx ~loc:a.loc ~here:(This "Result")
                ~sources:
                  (sources_later cx ~this:(function
                    | Unwrapped (_, r) -> r == errs
                    | _ -> false))
                ~fix:rename_where_in errs cx.handler;
              m.unwrapped <- errs :: m.unwrapped;
              Option.iter
                (fun s -> s := Unwrapped (a.loc, errs) :: !s)
                cx.sources;
              v
          | _ -> t)
      | t ->
          m.hint <- try_hint env cx a t;
          t)
  | Attempt a ->
      (* the calls it covers fail into its [Result] instead, and so does a
         `fail` *)
      let at = keyword e.loc 7 in
      let m = marker env Mattempt at in
      let kept = fresh_row env.st in
      defer env (Kept (kept, cx.params, Some at));
      let t =
        infer env { cx with handler = kept; markers = [ m ]; sources = None } a
      in
      TCon (result_path, [ t; TErrors kept ])
  | With { item; body; lam } -> with_ core env cx e item body lam
  | Assert a ->
      want_bool env Asserted a (infer env cx a);
      unit
  | Handler { deps; state; arms; _ } ->
      let needs = fresh_row env.st in
      handler core env cx state arms ~needs ~declared:None;
      impl_type (handler_deps deps) needs

(* Whether the place [target], assigned to, has a type that's written: a
   local whose is, a field, by its declaration, or an item of an array
   that's one of these and whose item type is written. *)
and written_place cx (target : expr) =
  match target.kind with
  | Var (Local b) -> Hashtbl.mem cx.written_locals b.id
  | Field _ -> is_written (Hashtbl.find cx.nodes target.node)
  | Index (a, _) -> (
      written_place cx a
      &&
      match Hashtbl.find_opt cx.nodes a.node with
      | Some (TCon (_, [ item ])) -> is_written item
      | _ -> false)
  | _ -> false

(* An array's items, [xs]: the first says what the others have to be. An
   implementation of several dependencies and one of some of them aren't
   the same type, and a written element type would narrow the first to
   the second (deps.md, "Implementations"), so that's what the message
   says to write, in a `let` of [name], if the array is one's value. *)
and infer_array env cx ?(name = "xs") xs =
  let elem = fresh_var env.st in
  (match xs with
  | [] -> ()
  | first :: rest ->
      let t1 = infer env cx first in
      ignore (unifies env plain (result_loc first) ~found:t1 ~expected:elem);
      let joined ds = String.concat " & " (List.map env.names ds) in
      List.iter
        (fun (x : expr) ->
          let why = explain ~msg:element_before () in
          match impl_parts elem with
          | None -> check env cx x elem ~why
          | Some (es, _) -> (
              let t = infer env cx x in
              match impl_parts t with
              | Some (ds, _)
                when ds <> es && List.exists (fun d -> List.mem d es) ds ->
                  let part = List.filter (fun d -> List.mem d es) ds in
                  report env
                    (items_differ (result_loc x) ~this_ty:(joined ds)
                       ~first_loc:(result_loc first) ~first_ty:(joined es) ~name
                       ~part:(joined part))
              | _ ->
                  ignore
                    (unifies env why (result_loc x) ~found:t ~expected:elem)))
        rest);
  array elem

and stmt env cx = function
  | Let { name; ty; value; _ } ->
      Hashtbl.replace cx.binders name.id Let_bound;
      let t =
        match (ty, value.kind) with
        | Some ann, _ ->
            let t =
              convert env ~tvars:cx.tparams ~named:cx.named
                ~row:(fun () -> fresh_row env.st)
                ann
            in
            check env cx ~written:t value t;
            Hashtbl.replace cx.written_locals name.id ();
            t
        | None, Array xs ->
            let t = infer_array env cx ~name:name.ident.name xs in
            Hashtbl.replace cx.nodes value.node t;
            t
        | None, _ -> infer env cx value
      in
      Hashtbl.replace cx.locals name.id t
  | Expr e -> dropped env cx e (infer env cx e)

(* Keep [t], the type of a value [e] throws away, to be checked later
   (see [drop]). *)
and dropped env cx (e : expr) t =
  let rec call (e : expr) = match e.kind with Try a -> call a | _ -> e in
  let callee =
    match (call e).kind with
    | Call (f, _) | Ref { kind = Call (f, _); _ } -> (
        match f.kind with
        | Var x -> Some (short_of x)
        | Field (_, m) -> Some m.name
        | _ -> None)
    | _ -> None
  in
  defer env (Drop { dloc = e.loc; dty = t; callee; dself = cx.self })

(* A call. One with a dot, `x.m(...)`, can be a method call, found through
   [x]'s type: as a field is, by [through_type], except that a method can
   be in a type of any kind, not only a record. [changed] is where the `&`
   is, if it's `&x.m(...)`. *)
and infer_call env cx ?changed ?tr (e : expr) (f : expr) args =
  match f.kind with
  | Field (r, m) -> (
      (* [tr] is the receiver's type, if it's inferred already; one of
         several dependencies' is the one that has [m] *)
      let tr = match tr with Some t -> t | None -> infer env cx r in
      let tr = member_of_several env cx r tr m in
      (* `r.m` is a field holding a function *)
      let field_call () =
        Option.iter
          (fun loc -> report env (not_changed loc ~recv:(env.source r) m.name))
          changed;
        let tf = field_access env cx f r tr m in
        Hashtbl.replace cx.nodes f.node tf;
        apply env cx e ~name:(Some m.name) f tf args
      in
      let nothing () =
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        TError
      in
      match (op_of env tr m.name, reveal env.st tr) with
      | Some (td, o), _ -> method_call env cx ?changed e f r m tr td o args
      | None, TError -> nothing ()
      | None, (TCon (p, _) as t)
        when Option.bind (known_decl env t) (field_in m.name) = None ->
          let td = Hashtbl.find env.types p in
          let shown = show (printer env) tr in
          (match td.body with
          | Dep ops -> report env (op_of_value ~names:env.names m p ops)
          | _ when p.home <> env.home && p.home <> Path.prelude_home ->
              report env (no_public_method m ~shown p)
          | _ ->
              let methods =
                List.filter_map
                  (fun (o : Iface.op) ->
                    if o.okind = Method then Some o.oname else None)
                  (Iface.members td)
              in
              report env
                (no_method m ~shown ~own:(p.home = env.home)
                   ~type_name:(type_name env p) methods));
          nothing ()
      | None, TVar _
        when List.exists (fun td -> op_in m.name td <> None) env.visible -> (
          (* step 2: the one visible type with a field or an item of that
             name *)
          let fits td =
            match (op_in m.name td, field_in m.name td) with
            | Some o, _ -> Some (Some o)
            | None, Some _ -> Some None
            | None, None -> None
          in
          match through_type env ~known:None ~fits with
          | Found (td, Some o) ->
              let t, _ = instance env td in
              unify_at env r.loc ~found:tr ~expected:t;
              method_call env cx ?changed e f r m tr td o args
          | Found (_, None) | Nowhere -> field_call ()
          | Several paths ->
              let what =
                match r.kind with
                | Var x -> Some (Infer_msg.Named (name_of x))
                | _ -> None
              in
              report env
                (several_have_member ~names:env.names r.loc ?what m
                   (List.map (fun p -> (p, member_kind env m.name p)) paths));
              nothing ())
      | None, TVar _
        when not
               (List.exists (fun td -> field_in m.name td <> None) env.visible)
        -> (
          (* it may be a method of a type the module can't name bare *)
          let elsewhere =
            Hashtbl.fold
              (fun p td acc ->
                match op_in m.name td with
                | Some { okind = Method; _ } -> p :: acc
                | _ -> acc)
              env.types []
            |> List.sort compare
          in
          match elsewhere with
          | [] -> field_call ()
          | _ ->
              let what =
                match r.kind with
                | Var x -> Some (Infer_msg.Named (name_of x))
                | _ -> None
              in
              report env
                (no_type_has_method ~names:env.names ~can_name:env.can_name
                   ?what m elsewhere);
              nothing ())
      | None, _ -> field_call ())
  | _ -> call_with env cx e f (infer env cx f) args

(* The call [e] of [f], which isn't a method, once [f]'s type [tf] is
   known. *)
and call_with env cx (e : expr) (f : expr) tf args =
  let name = callee_name f in
  let target =
    match f.kind with
    | Var (Global p) when group_call env p -> Some p
    | _ -> None
  in
  let callee = match f.kind with Var (Global p) -> Some p | _ -> None in
  apply env cx e ~name ?target ?callee f tf args

(* `r.m(args)`, the call [e] of [f], where [m] is the member [o] of
   [r]'s type [td]: a method is called with [r] as its `self`. [tr] is
   [r]'s type. *)
and method_call env cx ?changed (e : expr) (f : expr) r (m : ident) tr td o args
    =
  let recv = env.source r in
  let item = type_name env td.path ^ "." ^ o.oname in
  let nothing () =
    List.iter (fun a -> ignore (infer_arg env cx a)) args;
    TError
  in
  match o.okind with
  | Function | Value ->
      report env (not_a_method m o.okind ~item (List.map env.source args));
      nothing ()
  | Method -> (
      let path = op_path td o in
      if path.home = env.home && not (Hashtbl.mem env.globals path) then
        raise (Unchecked { caller = cx.self; callee = path });
      let tm = lookup env cx ~node:f.node f.loc (Global path) in
      Hashtbl.replace cx.nodes f.node tm;
      Hashtbl.replace cx.found f.node (Method_of path);
      match repr tm with
      | TFun (self :: ps, ret, errs, uses, lams) ->
          blame_args cx f [ (self.ty, r.loc) ];
          (* a dependency's method takes an implementation that needs less
             than its `self` allows, as an argument does *)
          unify_at env r.loc ~found:(widen env ~loc:r.loc tr) ~expected:self.ty;
          (match (self.mode, changed) with
          | Inout, None ->
              report env (needs_amp e.loc ~recv ~call:(env.source e) o.oname)
          | Read, Some loc -> report env (not_changed loc ~recv o.oname)
          | Inout, Some _ | Read, None -> ());
          apply env cx e ~name:(Some o.oname)
            ?target:(if group_call env path then Some path else None)
            ~callee:path
            ~written:(written_params env ~callee:path ~skip:1 tm ps)
            f
            (TFun (ps, ret, errs, uses, lams))
            args
      | _ -> nothing ())

(* What the callee [f] of a call needs of a type argument is blamed on
   the first of its arguments it's in, if one is, given as each one's
   parameter's type and the argument's location, before they're checked
   (Infer_env.required). A method's receiver comes first. *)
and blame_args cx (f : expr) args =
  (* the first argument whose type [is_in] says has it *)
  let blame r is_in vars =
    List.filter_map
      (fun (id, v) ->
        if List.mem_assoc id r.uat then None
        else
          List.find_map
            (fun (t, loc) -> if is_in v t then Some (id, loc) else None)
            args)
      vars
  in
  (* a row variable is in a type if its tail is one of the type's *)
  let row_in r t =
    match row_tail r with Some id -> List.mem id (row_vars t) | None -> false
  in
  Option.iter
    (fun r ->
      r.uat <- r.uat @ blame r mentions r.uinst;
      r.uat <- r.uat @ blame r row_in r.urows)
    (Hashtbl.find_opt cx.required f.node)

(* The call [e] of [f], a function of type [tf]; [name] says which, for
   messages, [target] which function of the group it is, if it's one, and
   [callee] which top-level function it is, if it's one. [written] says
   which of its parameters have a type written, if the caller knows
   better than [tf] (Infer_written.written_params). *)
and apply env cx (e : expr) ~name ?target ?callee ?written (f : expr) tf args =
  let ename = Option.value name ~default:"this" in
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses, _) ->
      let n = List.length ps and given = List.length args in
      if n <> given then (
        (* still check the arguments, for errors of their own *)
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        report env (wrong_arity e.loc name n given);
        TError)
      else (
        blame_args cx f
          (List.map2
             (fun (p : Types.param) (a : expr) -> (p.ty, a.loc))
             ps args);
        let written =
          match written with
          | Some w -> w
          | None -> written_params env ?callee tf ps
        in
        check_args env cx ~name ?callee ~written ps args;
        absorb env cx ~call:e ~ename ~fn:f ?target ?callee errs uses;
        ret)
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         function, whose errors and dependencies are the call's *)
      let ps = List.map (infer_arg env cx) args in
      let ret = fresh_var env.st in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      unify_at env f.loc ~found:tf
        ~expected:(TFun (ps, ret, errs, uses, fresh_row env.st));
      absorb env cx ~call:e ~ename ~fn:f errs uses;
      ret
  | TError ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      TError
  | t ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      report env (not_a_function f.loc name (show (printer env) t));
      TError

(* A call's arguments [args], left to right, each against its parameter's
   type, of [ps]; [name] is the callee, for messages, and [callee] the
   top-level function it is, if it's one. [written] says which of [ps]
   have a type written, where an argument is narrowed to it ([narrow]). *)
and check_args env cx ~name ?callee ~written ps args =
  List.iter2
    (fun ((p : Types.param), written) (a : expr) ->
      (* `f(&s.pop())` passes the call's result: its `&` is the
               receiver's *)
      let passed = changed_receiver a = None in
      match (p.mode, a.kind) with
      | Inout, Ref place when passed ->
          Hashtbl.replace cx.nodes a.node p.ty;
          check env cx place p.ty
      | Inout, Ref call ->
          (* `take(&c.pop())`: the `&` is `c`'s, and the argument is
                   what the call returns *)
          ignore (infer env cx a);
          report env
            (changes_call_result a.loc name ~arg:(env.source a)
               ~call:(env.source call))
      | Inout, _ ->
          let var =
            match a.kind with
            | Var x
            | Field ({ kind = Var x; _ }, _)
            | Index ({ kind = Var x; _ }, _) ->
                Some (name_of x)
            | _ -> None
          in
          ignore (infer env cx a);
          report env (arg_needs_amp a.loc name ~var)
      | Read, Ref place when passed ->
          ignore (infer env cx place);
          report env (arg_not_changed a.loc name)
      | Read, _ -> (
          let why = forced_why env callee p.ty in
          (* a parameter whose type is a variable, a generic's `T`, isn't
             written, however it's solved: the argument is unified with
             it *)
          match if is_written p.ty then impl_parts p.ty else None with
          | Some _ when written && branchy a ->
              (* `run(if b then h1 else h2)`: each branch is narrowed, as
                 under `let x: Rates = if ...` *)
              check env cx ~why ~written:p.ty a p.ty
          | Some _ ->
              (* an implementation that needs less than the parameter
                 allows will do, and where the parameter's type is
                 written, so will one of more dependencies, narrowed to
                 the parameter's *)
              let t = infer env cx a in
              let t = if written then narrow env cx a t p.ty else t in
              ignore
                (unifies env why (result_loc a) ~found:(widen env ~loc:a.loc t)
                   ~expected:p.ty)
          | None ->
              check env cx ~why
                ?written:(if written then Some p.ty else None)
                a p.ty))
    (List.combine ps written) args

(* An argument's type, and whether it's passed with `&`. *)
and infer_arg env cx (a : expr) =
  match a.kind with
  | Ref place when changed_receiver a = None ->
      let t = infer env cx place in
      Hashtbl.replace cx.nodes a.node t;
      { mode = Inout; ty = t }
  | _ -> read (infer env cx a)

(* A constructor applied to [args], where a value of type [expected] is
   wanted. *)
and infer_con env cx (e : expr) (cref : ctor_ref) args ~written ~expected =
  let c = cref.name in
  match find_ctor env cref ~expected with
  | None ->
      List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      TError
  | Some (td, ctor) when td.path = result_path && ctor.cname = "Err" -> (
      match args with
      | [ (_, ({ kind = Con ({ qual = None; name = tag }, payload); _ } as a)) ]
        ->
          (* a tag, written as the error the `Result` holds:
             `Err(Short(a, b))`. It's a value only here, so an error is
             still always inside a `Result`; a payload's names only
             document it, as in a `fail` *)
          Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
          let payload = List.map (fun (_, a) -> (infer env cx a, a)) payload in
          let row = err_row env cx tag payload ~expected in
          Hashtbl.replace cx.nodes a.node (TErrors row);
          Hashtbl.replace cx.found a.node Error_tag;
          TCon (td.path, [ fresh_var env.st; TErrors row ])
      | _ ->
          (* anything else would be an error of its own, outside the
             `Result`. A tag among several arguments, `Err(Neg(1), 2)`,
             is likely meant as one, so only its payload is checked, not
             the tag as a constructor *)
          List.iter
            (fun (_, (a : expr)) ->
              match a.kind with
              | Con ({ qual = None; _ }, payload) ->
                  List.iter (fun (_, a) -> ignore (infer env cx a)) payload
              | _ -> ignore (infer env cx a))
            args;
          report env (err_made c.loc);
          fst (instance env td))
  | Some (td, ctor) ->
      Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
      let t, tvars = instance env td in
      let written = written_args td written in
      if ctor_shape env e.loc c ctor (List.map fst args) then
        List.iter2
          (fun (f : Iface.field) (_, (a : expr)) ->
            check env cx a (field_type env ~tvars f)
              ?written:(written_field env ~tvars written f)
              ~why:(explain ~notes:[ part_of c.name "field" f.fname ] ()))
          ctor.cfields args
      else
        (* still check the arguments, for errors of their own *)
        List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      t

(* What [td]'s parameters are where the type written for a value of it,
   [written], says, if it's written: so a field whose declared type is a
   parameter, `Box<T>`'s `T`, is written where the `Box` is, `let b:
   Box<Users> = Box(h)`, and a handler there is narrowed to it (deps.md,
   "Implementations"). The field is still checked against its type from
   fresh variables, as without it, so only narrowing sees these. *)
and written_args (td : Iface.type_decl) written =
  match written with
  | Some (TCon (p, xs))
    when p = td.path && List.length xs = List.length td.params ->
      Some xs
  | _ -> None

(* The type written for field [f], if it's written: its declared type,
   where [written_args] found what the parameters are, or else [tvars]. *)
and written_field env ~tvars xs (f : Iface.field) =
  let ft = field_type env ~tvars:(Option.value xs ~default:tvars) f in
  if is_written ft then Some ft else None

(* A record literal: `User { ... }`, or `{ ... }` with its type found
   through [expected], or else through its fields. *)
and infer_record env cx (e : expr) name fields ~written ~expected =
  let ids = List.map fst fields in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (f : ident) ->
      match Hashtbl.find_opt seen f.name with
      | Some first -> report env (two_fields f first)
      | None -> Hashtbl.replace seen f.name f.loc)
    ids;
  let given = sorted (List.map (fun (f : ident) -> f.name) ids) in
  let decl =
    match name with
    | Some { tref = Named p; tloc } -> (
        let td = Hashtbl.find env.types p in
        match literal_fields td with
        | Some fs -> Some (td, fs)
        | None ->
            report env (not_a_record ~names:env.names tloc td);
            None)
    | Some { tref = Param _; _ } ->
        (* resolve.ml only resolves a record's name to a declared type *)
        assert false
    | None -> (
        let known =
          Option.bind (known_decl env expected) (fun td ->
              Option.map (fun fs -> (td, fs)) (literal_fields td))
        in
        let fits td =
          match literal_fields td with
          | Some fs when sorted (field_names fs) = given -> Some fs
          | _ -> None
        in
        match through_type env ~known ~fits with
        | Found found -> Some found
        | Nowhere ->
            report env (no_record_fits e.loc);
            None
        | Several paths ->
            report env (several_records_fit ~names:env.names e.loc paths);
            None)
  in
  match decl with
  | None ->
      List.iter (fun (_, v) -> ignore (infer env cx v)) fields;
      TError
  | Some (td, decl) ->
      let t, tvars = instance env td in
      let written = written_args td written in
      (* an implementation gives a dependency's operations *)
      let what = match td.body with Dep _ -> "operation" | _ -> "field" in
      (* a misspelled field is also a missing one; once it's reported, the
         missing ones aren't, as they're likely the same mistake *)
      let unknown = ref false in
      List.iter
        (fun ((f : ident), v) ->
          match
            List.find_opt (fun (d : Iface.field) -> d.fname = f.name) decl
          with
          | Some fd ->
              let ft = field_type env ~tvars fd in
              (* a closure whose errors end in a named row, `! ..e`, could
                 fail with anything, which an operation can't *)
              let named_errors () =
                match v.kind with
                | Var (Local b) -> (
                    match Option.map repr (Hashtbl.find_opt cx.locals b.id) with
                    | Some (TFun (_, _, errs, _, _)) -> (
                        let rec tail r =
                          match repr_row r with
                          | RExtend (_, rest) -> tail rest
                          | RSkol (_, n) -> Some n
                          | _ -> None
                        in
                        match (tail errs, ft) with
                        | Some n, TFun (_, _, declared, _, _) ->
                            let declared =
                              List.map
                                (fun (l : label) -> l.name)
                                (fst (row_parts declared))
                            in
                            Some
                              (named_row_help ~var:b.ident.name ~row:n declared)
                        | _ -> None)
                    | _ -> None)
                | _ -> None
              in
              let ft =
                match (t, ft) with
                | TCon (_, [ TUses needs ]), TFun (ps, r, errs, _, lams) ->
                    (* an operation uses what the implementation needs, and
                       can fail with less than it's declared to: what more
                       it fails with is reported once the group is done *)
                    let declared = fst (row_parts errs) in
                    (* a lambda's is its own until the group is done (see
                       [handler]); a function given by name fails with
                       what it does, which is checked against the
                       operation here *)
                    let open_errs =
                      match v.kind with
                      | Lambda _ -> fresh_row env.st
                      | _ -> extend declared (fresh_row env.st)
                    in
                    defer env
                      (Impl_op
                         {
                           idep = td.path;
                           iop = f.name;
                           ideclared = declared;
                           ierrs = open_errs;
                           ivalue = v;
                           inodes = cx.nodes;
                         });
                    TFun (ps, r, open_errs, needs, lams)
                | _ -> ft
              in
              let help = Option.map (fun h _ _ -> h) (named_errors ()) in
              check env cx v ft
                ?written:(written_field env ~tvars written fd)
                ~why:
                  (explain
                     ~notes:[ part_of (type_name env td.path) what f.name ]
                     ?help ())
          | None ->
              report env (no_such_field ~names:env.names ~what f td.path decl);
              unknown := true;
              ignore (infer env cx v))
        fields;
      let missing =
        List.filter (fun d -> not (List.mem d given)) (field_names decl)
      in
      if missing <> [] && not !unknown then
        report env (missing_fields ~names:env.names e.loc td.path missing);
      t

(* `r.f`: the field is found through [r]'s type ([field_access]), which
   has to be known by now, or be the one record type that has a field
   named [f]. *)
and infer_field env cx (e : expr) r (f : ident) =
  field_access env cx e r (infer env cx r) f

(* A `match`. With [want], every arm is checked against the type it says;
   otherwise the first arm says what the others have to be.

   A `match` with `fail` arms handles what its subject fails with
   (errors.md, "Handling: `match`"), so the calls in the subject are
   marked by the `match`, as they would be by an `attempt`: their errors,
   and a `fail`'s, go to a row of the `match`'s own, which the `fail` arms
   match. The arms are outside it, under the code's own handler. [passed]
   is the `try` of a `try match`, which passes on what no arm handles.
   Which `match`es handle errors, and which arms are `fail` arms, is
   recorded by [node], the `match`'s id, and each arm's pattern's, for
   later passes. *)
and infer_match env cx ?passed node subject arms ~want =
  let ts, errs =
    if handles arms then (
      Hashtbl.replace cx.found node Handles;
      let first = List.find (fun a -> is_fail a.arm_pat) arms in
      let m = marker env Mmatch first.arm_pat.ploc in
      let errs = fresh_row env.st in
      defer env (Kept (errs, cx.params, None));
      let ts =
        infer env
          { cx with handler = errs; markers = [ m ]; sources = None }
          subject
      in
      Option.iter (fun p -> pass_on env cx p subject arms errs) passed;
      (ts, Some errs))
    else (infer env cx subject, None)
  in
  let result, arm_why =
    match want with
    | Some (expected, why, _) -> (expected, fun _ -> why)
    | None ->
        let first = result_loc (List.hd arms).arm_body in
        ( fresh_var env.st,
          fun i ->
            let msg = if i = 0 then None else Some arm_after in
            explain ?msg ~labels:(fun _ x -> [ (first, first_arm x) ]) () )
  in
  List.iteri
    (fun i a ->
      (match errs with
      | Some errs when is_fail a.arm_pat ->
          Hashtbl.replace cx.found a.arm_pat.pnode Fail_arm;
          bind_fail env cx errs a.arm_pat
      | _ -> bind_pattern env cx ts a.arm_pat);
      Option.iter (fun g -> want_bool env Guard g (infer env cx g)) a.arm_guard;
      let written = Option.bind want (fun (_, _, w) -> w) in
      check env cx ~why:(arm_why i) ?written a.arm_body result)
    arms;
  result

(* A `fail` arm's pattern, which matches an error of the set [errs]: a
   tag, destructured, or any of them. Each alternative of `fail A(x) |
   fail B(x)` binds the same names, which have to have one type. *)
and bind_fail env cx errs (p : pattern) =
  Hashtbl.replace cx.nodes p.pnode (TErrors errs);
  match p.pkind with
  | PFail (c, ps) -> tag_pattern env cx ~arm:true p c ps errs
  | PFail_any -> ()
  | POr [] -> ()
  | POr (first :: rest) ->
      bind_fail env cx errs first;
      List.iter
        (fun alt ->
          let before =
            List.map
              (fun (b, loc) -> (b, loc, Hashtbl.find_opt cx.locals b.id))
              (binders alt)
          in
          bind_fail env cx errs alt;
          List.iter
            (fun ((b : binder), loc, t) ->
              match (t, Hashtbl.find_opt cx.locals b.id) with
              | Some first, Some here ->
                  unify_at env loc ~found:here ~expected:first
                    ~msg:(alternative b.ident.name);
                  Hashtbl.replace cx.locals b.id first
              | _ -> ())
            before)
        rest
  | PWild | PVar _ | PInt _ | PBool _ | PCon _ ->
      (* the parser combines only `fail` patterns *)
      bind_pattern env cx TError p

(* Check a pattern against the type of the value it matches, and give the
   variables it binds their types. A constructor is found through that
   type. *)
and bind_pattern env cx t (p : pattern) =
  Hashtbl.replace cx.nodes p.pnode t;
  let check found = unify_at env p.ploc ~found ~expected:t ~msg:pattern_for in
  match (p.pkind, repr t) with
  | PCon ({ qual = None; name = c }, ps), TErrors errs ->
      (* a tag, inside `Err(...)`: one of the errors the [Result] holds *)
      Hashtbl.replace cx.found p.pnode Error_tag;
      tag_pattern env cx p c ps errs
  | PVar b, TErrors _ ->
      (* `Err(e)` would make the error a value of its own *)
      report env (bound_error p.ploc b.ident.name);
      Hashtbl.replace cx.nodes p.pnode TError;
      Hashtbl.replace cx.locals b.id TError
  | pkind, _ -> (
      match pkind with
      | PWild -> ()
      | PVar b -> Hashtbl.replace cx.locals b.id t
      | PInt _ -> check int
      | PBool _ -> check bool
      | PCon (cref, ps) -> (
          let c = cref.name in
          let unknown () = List.iter (bind_pattern env cx TError) ps in
          match find_ctor env cref ~expected:t with
          | None -> unknown ()
          | Some (td, ctor) ->
              Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
              let tc, tvars = instance env td in
              check tc;
              if ctor_shape env p.ploc c ctor (List.map (fun _ -> None) ps) then
                List.iter2
                  (fun fd sub ->
                    bind_pattern env cx (field_type env ~tvars fd) sub)
                  ctor.cfields ps
              else unknown ())
      | PFail _ | PFail_any | POr _ ->
          (* a `fail` pattern is a whole arm's (the parser says so), and
             [infer_match] binds it with [bind_fail] *)
          ())

(* The tag [c] of the error set [errs], destructured by [ps]. A misspelled
   tag is caught here: it isn't one of the errors (errors.md, "Tags are
   structural"). While the set is open, as an `attempt`'s is until its
   group is done, a tag not in it yet is checked then. *)
and tag_pattern env cx ?(arm = false) (p : pattern) (c : ident) ps errs =
  let labels, tail = row_parts errs in
  let bind payload =
    if List.length payload = List.length ps then
      List.iter2 (bind_pattern env cx) payload ps
    else (
      report env (tag_arity p.ploc c (List.length payload) (List.length ps));
      List.iter (bind_pattern env cx TError) ps)
  in
  match (List.find_opt (fun (l : label) -> l.name = c.name) labels, tail) with
  | Some l, _ -> bind l.payload
  | None, None ->
      let pr = printer env in
      report env
        (not_an_error c ~arm
           (List.map (fun (l : label) -> (l.name, show_label pr l)) labels));
      List.iter (bind_pattern env cx TError) ps
  | None, Some _ ->
      let payload = List.map (fun _ -> fresh_var env.st) ps in
      defer env
        (Tag_pattern
           {
             ttag = c;
             tpayload = payload;
             tset = errs;
             tin = cx.params;
             tarm = arm;
             tvalue = false;
           });
      bind payload

(* What infer_handlers.ml calls back, from the functions above (see
   [Infer_handlers.core]). A [let rec] can define a record of its
   functions, as well as the functions themselves. *)
and core = { infer; check; stmt; infer_call; call_with; check_args }
