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
   one lookup ([through_type]) in the three steps of module-build.md.
   Nothing waits: a question that can't be answered where it's asked is an
   error that says which annotation would answer it, so the result never
   depends on the order inference happens to learn things in.

   As it goes, inference records every expression's and pattern's type by
   its node id, and what each lookup found. infer_top.ml hands the table on
   in canonical form, for the passes after it. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written
open Infer_lookup
open Infer_rows

(* ---- expressions ---- *)

let want_int env op (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int
    ~notes:[ sprintf "`%s` works on `Int`s" op ]

let want_bool env what (e : expr) t =
  unify_at env e.loc ~found:t ~expected:bool
    ~notes:[ sprintf "%s has to be a `Bool`" what ]

(* How to explain a mismatch with [expected], the type of a parameter of
   [callee]: when a statement of [callee] threw away a value whose type
   wasn't known, that made it `Unit`, and a `Unit` in [expected] may well be
   that one, which the caller can't see. So the mismatch points back at the
   statement. *)
let forced_why env callee expected =
  let rec has_unit t =
    match repr t with
    | TCon (p, args) -> p = Path.prelude "Unit" || List.exists has_unit args
    | TFun (ps, ret, _, _) ->
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
      let label loc =
        ( loc,
          sprintf
            "`%s` throws this value away, and its type wasn't known, so it was \
             taken to be `Unit`"
            (Path.local c) )
      in
      let help =
        sprintf
          "if `%s` means to drop a value of any type there, write `let _ = ...`"
          (Path.local c)
      in
      if sites = [] then plain
      else
        explain
          ~help:(fun _ _ -> help)
          ~labels:(fun _ _ -> List.map label sites)
          ()
  | _ -> plain

(* The type the body of a handler of [deps] gives, the handler [cx.self]'s
   (Iface.handler_type): the dependency's, if it implements one, or its
   own, named after it. *)
let handler_type cx (deps : tname list) =
  match deps with [ { tref = Named p; _ } ] -> p | _ -> cx.self

(* A value of type [t] taken as one of type [expected]: a handler of
   several dependencies, `test_clock(t)` for `Clock, TestClock`, where a
   value of one of their types is wanted, `Clock`, describes an
   implementation of that one, which needs what the handler does. Its
   type is then that dependency's, and installing it installs only that
   one (deps.md, "Implementations"). Only where the type wanted is known
   as the value is made: anywhere else it's the handler's own. *)
let as_one env t expected =
  match (repr t, reveal env.st expected) with
  | TCon (h, [ TUses needs ]), TCon (d, [ TUses _ ]) -> (
      match Hashtbl.find_opt env.types h with
      | Some { body = Handler deps; _ } when List.mem d deps ->
          Some (d, TCon (d, [ TUses needs ]))
      | _ -> None)
  | _ -> None

(* The type [e], of type [t], has where a value of type [expected] is
   wanted: [as_one]'s, which lowering is told, or [t]. *)
let taken_as env cx (e : expr) t expected =
  match as_one env t expected with
  | Some (d, one) ->
      Hashtbl.replace cx.as_dep e.node d;
      one
  | None -> t

(* What the parameters [tvars] of [td], a type being made, stand for
   where a value of type [expected] is wanted, as far as they're
   implementations: in an `Option<Rates>`, the `T` of `Some(...)` is a
   `Rates`, so a handler of several dependencies given there is taken as
   that one ([as_one]). The rest is unified once the value is made, so a
   mismatch is still reported at the whole value. *)
let hint env (td : Iface.type_decl) tvars expected =
  match reveal env.st expected with
  | TCon (p, xs) when p = td.path && List.length xs = List.length tvars ->
      List.iter2
        (fun v x ->
          match reveal env.st x with
          | TCon (d, [ TUses _ ]) ->
              (* what it needs is left to the whole value's unification
                 too, which says where the type wanted is written *)
              Unify.unify env.st v (TCon (d, [ TUses (fresh_row env.st) ]))
          | _ -> ())
        tvars xs
  | _ -> ()

(* [e]'s type, from [e] alone. *)
let rec infer env cx (e : expr) : ty =
  let t = synth env cx e in
  Hashtbl.replace cx.nodes e.node t;
  t

(* Check [e] against [expected], explaining a mismatch with [why]. When
   nothing is known about [expected] yet, that's inferring [e] and unifying
   the two. *)
and check env cx ?(why = plain) (e : expr) expected =
  let leaf () =
    let t = synth env cx e in
    Hashtbl.replace cx.nodes e.node t;
    ignore
      (unifies env why (result_loc e)
         ~found:(taken_as env cx e t expected)
         ~expected)
  in
  let fits () = Hashtbl.replace cx.nodes e.node expected in
  match (e.kind, reveal env.st expected) with
  | _, TVar _ -> leaf ()
  | Block (stmts, last), _ ->
      fits ();
      List.iter (stmt env cx) stmts;
      check env cx ~why last expected
  | If (c, t, Some f), _ ->
      fits ();
      want_bool env "an `if` condition" c (infer env cx c);
      check env cx ~why t expected;
      check env cx ~why f expected
  | Match (subject, arms), _ ->
      fits ();
      ignore (infer_match env cx subject arms ~want:(Some (expected, why)))
  | Lambda (params, body), TFun (eps, eret, _, _)
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
      bind_params cx params ps;
      check env
        (lambda_cx cx params ps ~errs ~uses)
        body eret
        ~why:
          (explain ~notes:why.notes ?help:why.help ~labels:why.labels
             ~msg:(fun f x ->
               sprintf "this lambda produces %s, but it has to produce %s"
                 (article f) (article x))
             ());
      let t = TFun (ps, eret, errs, uses) in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Con (c, args), _ ->
      let t = infer_con env cx e c args ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Record (name, fields), _ ->
      let t = infer_record env cx e name fields ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Handler { deps; state; arms; _ }, TCon (p, [ TUses declared ])
    when p = handler_type cx deps ->
      (* what it's written to need, and more, which is reported once the
         group is done *)
      fits ();
      let labels = fst (row_parts declared) in
      let needs = extend labels (fresh_row env.st) in
      handler env cx state arms ~needs
        ~declared:(Some (List.map (fun (l : label) -> l.name) labels))
  | Array xs, TCon (p, [ elem ]) when p = Path.prelude "Array" ->
      fits ();
      List.iter
        (fun x -> check env cx ~why:{ plain with notes = why.notes } x elem)
        xs
  | _ -> leaf ()

(* The type of [e], not yet recorded. *)
and synth env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Bool _ -> bool
  | Str _ -> str
  | Unit -> unit
  | Var x -> lookup env cx e.loc x
  | Unop (Neg, a) ->
      want_int env "-" a (infer env cx a);
      int
  | Unop (Not, a) ->
      want_bool env "what `not` is applied to" a (infer env cx a);
      bool
  | Binop (op, a, b) -> (
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod | Lt | Le | Gt | Ge ->
          let ta = infer env cx a in
          let tb = infer env cx b in
          want_int env name a ta;
          want_int env name b tb;
          if List.mem op [ Lt; Le; Gt; Ge ] then bool else int
      | And | Or ->
          let what = sprintf "each side of `%s`" name in
          want_bool env what a (infer env cx a);
          want_bool env what b (infer env cx b);
          bool
      | Orelse ->
          (* the value in the `Option`, or else the right side, which is
             usually a `fail`, whose type is anything *)
          let v = fresh_var env.st in
          unify_at env (result_loc a) ~found:(infer env cx a)
            ~expected:(TCon (option_path, [ v ]))
            ~msg:(fun f _ ->
              sprintf "`orelse` takes an `Option` on its left, but this is %s"
                (article f))
            ~help:"`x orelse y` is the value in the `Option` `x`, or else `y`";
          check env cx b v
            ~why:
              (explain
                 ~msg:(fun f x ->
                   sprintf
                     "this is %s, but the `Option` on the left of `orelse` \
                      holds %s"
                     (article f) (article x))
                 ~help:(fun _ _ ->
                   "give a value of that type, or `fail` with an error")
                 ());
          v
      | Eq | Neq ->
          (* the left side says what the right side has to be *)
          let ta = infer env cx a in
          check env cx b ta
            ~why:
              (explain
                 ~msg:(fun f x ->
                   sprintf
                     "`%s` compares two values of the same type, but this is \
                      %s and the left side is %s"
                     name (article f) (article x))
                 ~labels:(fun _ x ->
                   [ (a.loc, sprintf "this is %s" (article x)) ])
                 ());
          bool)
  | If (c, t, Some f) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let tt = infer env cx t in
      check env cx f tt
        ~why:
          (explain
             ~msg:(fun f x ->
               sprintf "this `else` branch is %s, but the `then` branch is %s"
                 (article f) (article x))
             ~labels:(fun _ x ->
               [ (result_loc t, sprintf "the `then` branch is %s" (article x)) ])
             ~notes:[ "both branches of an `if` have to produce the same type" ]
             ());
      tt
  | If (c, t, None) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "this `if` has no `else`, so it can't produce %s"
                 (article f))
             ~help:(fun _ _ ->
               "add an `else` branch for when the condition is false")
             ())
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
      bind_params cx params ps;
      let tb = infer env (lambda_cx cx params ps ~errs ~uses) body in
      TFun (ps, tb, errs, uses)
  | Block (stmts, last) ->
      List.iter (stmt env cx) stmts;
      infer env cx last
  | Con (c, args) -> infer_con env cx e c args ~expected:(fresh_var env.st)
  | Record (name, fields) ->
      infer_record env cx e name fields ~expected:(fresh_var env.st)
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) -> infer_match env cx subject arms ~want:None
  | Array xs ->
      (* the first element says what the others have to be. One that's a
         handler of several dependencies waits for one that isn't, which
         may be an implementation of one of them, `[counting_rates(1),
         Rates { ... }]`: then it's taken as that one ([as_one]) *)
      let elem = fresh_var env.st in
      let several t =
        match repr t with
        | TCon (h, [ TUses _ ]) -> (
            match Hashtbl.find_opt env.types h with
            | Some { body = Handler _; _ } -> true
            | _ -> false)
        | _ -> false
      in
      let waiting =
        List.fold_left
          (fun waiting (x : expr) ->
            match repr elem with
            | TVar _ ->
                let t = infer env cx x in
                if several t then (x, t) :: waiting
                else (
                  ignore
                    (unifies env plain (result_loc x) ~found:t ~expected:elem);
                  waiting)
            | _ ->
                check env cx x elem
                  ~why:
                    (explain
                       ~msg:(fun f x ->
                         sprintf
                           "this element is %s, but the elements before it are \
                            %s"
                           (article f) (article x))
                       ());
                waiting)
          [] xs
      in
      List.iter
        (fun ((x : expr), t) ->
          ignore
            (unifies env
               (explain
                  ~msg:(fun f x ->
                    sprintf "this element is %s, but the others are %s"
                      (article f) (article x))
                  ())
               (result_loc x) ~found:(taken_as env cx x t elem) ~expected:elem))
        (List.rev waiting);
      array elem
  | Index (a, i) ->
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "only an `Array` can be indexed, but this is %s"
                 (article f))
             ())
          (result_loc a) ~found:(infer env cx a) ~expected:(array elem)
      in
      want_int env "an index" i (infer env cx i);
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
          want_int env name target tt;
          want_int env name value (infer env cx value)
      | None ->
          check env cx value tt
            ~why:
              (explain
                 ~msg:(fun f x ->
                   sprintf "this is %s, but it's being assigned to %s"
                     (article f) (article x))
                 ()));
      unit
  | For { var; iter; body } ->
      let array_of = match iter.kind with Ref a -> a | _ -> iter in
      let ta = infer env cx array_of in
      Hashtbl.replace cx.nodes iter.node ta;
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "a `for` loop goes over an `Array`, but this is %s"
                 (article f))
             ())
          (result_loc array_of) ~found:ta ~expected:(array elem)
      in
      Hashtbl.replace cx.locals var.id (if ok then elem else TError);
      (* each time round, the body's value is thrown away, as a
         statement's is *)
      dropped env cx (result_of body) (infer env cx body);
      unit
  | Fail (tag, args) ->
      (* the error joins whatever handles the code here; a field's name in
         the payload only documents it *)
      let payload = List.map (fun (_, a) -> infer env cx a) args in
      let l = { name = tag.name; payload } in
      add_errors env ~loc:e.loc ~here:"from this `fail`"
        ~sources:(sources_of cx)
        ~fix:(fun _ -> "give one of them another name")
        (extend [ l ] REmpty) cx.handler;
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
      let t = infer_match env cx ~passed:m subject arms ~want:None in
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
          report env
            (try_err e.loc (Option.value (env.source tag) ~default:"..."))
      | _ -> ());
      (* `try r`, where [r] is a [Result]: what's in [r] if it's `Ok`, and
         if it's `Err`, its error again *)
      match reveal env.st t with
      | TCon (p, [ v; errs ]) when p = result_path -> (
          match repr errs with
          | TErrors errs ->
              include_errors env cx ~loc:a.loc
                (add_errors env ~loc:a.loc ~here:"from this `Result`"
                   ~sources:(sources_of cx) ~fix:(fun _ ->
                     "rename one of them where it comes in"))
                errs cx.handler;
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
      let m = marker env Mattempt (keyword e.loc 7) in
      let kept = fresh_row env.st in
      env.kept <- (kept, cx.params) :: env.kept;
      let t =
        infer env { cx with handler = kept; markers = [ m ]; sources = None } a
      in
      TCon (result_path, [ t; TErrors kept ])
  | With { item; body; lam } -> with_ env cx e item body lam
  | Assert a ->
      want_bool env "what an `assert` checks" a (infer env cx a);
      unit
  | Handler { deps; state; arms; _ } ->
      let needs = fresh_row env.st in
      handler env cx state arms ~needs ~declared:None;
      TCon (handler_type cx deps, [ TUses needs ])

(* A handler's body (ast.ml, [Handler]), the body of its function,
   [cx.self], whose result is the handler's type ([handler_type]). Its
   state and its arms run where it's installed, not where the function is
   called, so what they use is what the handler needs, [needs], and the
   function itself uses nothing. Its state is made when it's installed,
   which can't fail. Each arm is checked as an implementation's operation
   is ([infer_record]): it uses what the handler needs, and can fail with
   fewer errors than its operation declares, never more. What it needs is
   checked once the group is done, against what's [declared], if anything
   is (see [handler_needs]). *)
and handler env cx state arms ~needs ~declared =
  let hcx = lambda_cx cx [] [] ~errs:REmpty ~uses:needs in
  env.cant_fail <-
    Some
      "a handler's state is made where a `with` installs it, which can't fail";
  List.iter (stmt env hcx) state;
  env.cant_fail <- None;
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
          env.impl_ops <-
            {
              idep = p;
              iop = op;
              ideclared = declared;
              ierrs = open_errs;
              ivalue = a.arm_impl;
              inodes = cx.nodes;
            }
            :: env.impl_ops;
          (* checked as a lambda is, against the operation, but what its
             calls use is what the handler needs, and they're the
             handler's calls, so a message can point at one *)
          let notes =
            [ sprintf "`%s`'s operation `%s`" (type_name env p) op ]
          in
          let why = explain ~notes () in
          (* its result reads as a record implementation's lambda's does *)
          let result_why =
            explain ~notes
              ~msg:(fun f x ->
                sprintf "this arm produces %s, but it has to produce %s"
                  (article f) (article x))
              ()
          in
          let qs =
            List.map2
              (fun (q : Resolved.param) eq ->
                if q.pty = None then eq
                else param_type env ~tparams:cx.tparams ~named:cx.named q)
              params ps
          in
          bind_params hcx params qs;
          let acx =
            {
              (lambda_cx hcx params qs ~errs:open_errs ~uses:needs) with
              calls = hcx.calls;
            }
          in
          check env acx body r ~why:result_why;
          let t = TFun (qs, r, open_errs, needs) in
          Hashtbl.replace cx.nodes a.arm_impl.node t;
          ignore
            (unifies env why a.arm_impl.loc ~found:t
               ~expected:(TFun (ps, r, open_errs, needs)))
      | Some (p, op, ps, _, _), Lambda (params, _) ->
          let n = List.length ps in
          report env
            (Diag.make a.arm_name.loc
               ~help:
                 (sprintf "give it %d parameter%s, one for each argument" n
                    (if n = 1 then "" else "s"))
               (sprintf
                  "`%s.%s` takes %d argument%s, but this has %d parameter%s"
                  (type_name env p) op n
                  (if n = 1 then "" else "s")
                  (List.length params)
                  (if List.length params = 1 then "" else "s")));
          ignore (infer env hcx a.arm_impl)
      | _ -> ignore (infer env hcx a.arm_impl))
    arms;
  env.handler_needs <-
    { nself = cx.self; ndeclared = declared; nrow = needs; ncalls = hcx.calls }
    :: env.handler_needs

(* `with item in body` (deps.md, "`with`"), the expression [e]. A call
   whose callee takes one more argument than it's given is a wrapper,
   and so is a function of one parameter; anything else is an
   implementation, installed. Which it is is found here, from types, and
   kept for lowering. *)
and with_ env cx (e : expr) item body lam =
  match item.kind with
  | Call (({ kind = Field (r, m); _ } as f), args) -> (
      let tr = infer env cx r in
      (* a method is a wrapper if it takes one more argument, besides its
         `self`, than it's given *)
      let wrapper =
        match op_of env tr m.name with
        | Some (td, ({ okind = Method; _ } as o)) -> (
            let path = op_path td o in
            if path.home = env.home && not (Hashtbl.mem env.globals path) then
              raise (Unchecked { caller = cx.self; callee = path });
            match repr (lookup env cx f.loc (Global path)) with
            | TFun (self :: ps, ret, errs, uses) as tm
              when List.length ps = List.length args + 1 ->
                Some (path, tm, self, TFun (ps, ret, errs, uses))
            | _ -> None)
        | _ -> None
      in
      match wrapper with
      | Some (path, tm, self, tf) ->
          Hashtbl.replace cx.nodes f.node tm;
          Hashtbl.replace cx.found f.node (Method_of path);
          unify_at env r.loc ~found:(widen env ~loc:r.loc tr) ~expected:self.ty;
          if self.mode = Inout then
            report env
              (Diag.make item.loc
                 ~notes:
                   [
                     "`with r.w(a) in body` calls `r.w(a, fn() => body)`, and \
                      a `with`'s item can't change what it's called on";
                   ]
                 ~help:
                   (sprintf
                      "call `%s` outside the `with`, with all its arguments"
                      m.name)
                 (sprintf "`%s` changes its receiver, so it can't wrap a body"
                    m.name));
          wrap env cx e ~call:item ~f ~args
            ?target:(if group_call env path then Some path else None)
            ~callee:path tf body lam
      | None ->
          let t = infer_call env cx ~tr item f args in
          Hashtbl.replace cx.nodes item.node t;
          install env cx e item t body)
  | Call (f, args) -> (
      let tf = infer env cx f in
      (* a handler, or a function that makes an implementation, given too
         few arguments: what's missing isn't its body *)
      let short ps ret =
        List.length ps > List.length args
        && (match reveal env.st ret with
          | TCon (_, [ TUses _ ]) -> true
          | _ -> false)
        &&
        match reveal env.st (List.nth ps (List.length ps - 1)).ty with
        | TFun _ -> false
        | _ -> true
      in
      match reveal env.st tf with
      | TFun (ps, ret, _, _) when short ps ret ->
          let name = callee_name f in
          let n = List.length ps in
          report env
            (Diag.make item.loc
               ~notes:
                 [
                   sprintf
                     "%s makes an implementation, `%s`, which `with` installs \
                      once it's called with all its arguments"
                     name
                     (show (printer env) ret);
                 ]
               ~help:(sprintf "give %s all its arguments" name)
               (sprintf "%s takes %d argument%s but was given %d" name n
                  (if n = 1 then "" else "s")
                  (List.length args)));
          List.iter (fun a -> ignore (infer env cx a)) args;
          Hashtbl.replace cx.nodes item.node ret;
          install env cx e item ret body
      | TFun (ps, _, _, _) when List.length ps = List.length args + 1 ->
          wrap env cx e ~call:item ~f ~args tf body lam
      | _ ->
          let t = call_with env cx item f tf args in
          Hashtbl.replace cx.nodes item.node t;
          install env cx e item t body)
  | _ -> (
      let t = infer env cx item in
      match reveal env.st t with
      | TFun ([ _ ], _, _, _) ->
          wrap env cx e ~call:item ~f:item ~args:[] t body lam
      | _ -> install env cx e item t body)

(* Install [item], of type [t], around [body]: the body uses what it does
   but the dependency installed, and the `with` uses what the
   implementation needs too. *)
and install env cx (e : expr) item t body =
  (* [body], with each of [deps] installed around it, the first outermost *)
  let rec around cx = function
    | [] -> infer env cx body
    | d :: rest ->
        let label = Ty.dep_label d in
        (* the body's own row, which [settle_installs] relates to the outer
           one once the group is done *)
        let inner = { cx with uses = fresh_row env.st; calls = ref [] } in
        let tb = around inner rest in
        env.installs <-
          {
            wloc = item.loc;
            wdep = label;
            wbody = inner.uses;
            wouter = cx.uses;
            wself = cx.self;
          }
          :: env.installs;
        (* the body's calls bring in what they bring in, but [d] *)
        cx.calls :=
          List.map
            (fun c -> { c with own = List.filter (( <> ) label) c.own })
            !(inner.calls)
          @ !(cx.calls);
        tb
  in
  (* what an implementation of [d] installs: a handler's instance, each
     of its dependencies *)
  let installs d =
    match Hashtbl.find_opt env.types d with
    | Some { body = Handler deps; _ } ->
        Hashtbl.replace cx.found e.node (Installs_handler deps);
        deps
    | _ ->
        Hashtbl.replace cx.found e.node (Installs d);
        [ d ]
  in
  (* a `with` that can't tell what it installs might have installed what
     its body uses, so that's not passed on: it would be reported as missing
     too, where the function is called *)
  let unknown () =
    ignore (infer env { cx with uses = fresh_row env.st; calls = ref [] } body)
  in
  match reveal env.st t with
  | TCon (d, [ TUses needs ]) ->
      (* what it needs it needs here, outside: its operations run with what's
         installed where it's installed *)
      use_row env cx ~loc:item.loc ~needs:true
        (copy_needs env ~loc:item.loc ~what:"installing this needs" needs);
      around cx (installs d)
  | TFun ([], ret, _, _) as tf
    when match reveal env.st ret with
         | TCon (_, [ TUses _ ]) -> true
         | _ -> false -> (
      (* `with h in`, a handler or a function that makes an implementation
         not called: the body is checked as if it were, so what it uses
         isn't reported as missing too *)
      let src = Option.value (env.source item) ~default:"f" in
      report env
        (Diag.make item.loc
           ~notes:
             [
               sprintf
                 "`with` installs an implementation, and `%s` makes one when \
                  it's called"
                 src;
             ]
           ~help:(sprintf "call it: `with %s() in ...`" src)
           (sprintf "`with` installs an implementation, but this is %s"
              (article (show (printer env) tf))));
      match reveal env.st ret with
      | TCon (d, _) -> around cx (installs d)
      | _ -> TError)
  | TError ->
      unknown ();
      TError
  | t ->
      unknown ();
      let shown = show (printer env) t in
      let is_var = match t with TVar _ -> true | _ -> false in
      fail env item.loc
        ~notes:
          [
            "`with` installs an implementation of a dependency around its \
             body, or passes its body to a wrapper, a function whose last \
             parameter is the body";
          ]
        ~help:
          (match item.kind with
          | Var (Local b) when is_var ->
              sprintf "say what it is where it's declared, like `%s: Clock`"
                b.ident.name
          | _ when is_var ->
              "install something whose type is known here, like \
               `Clock.frozen(t)`, or a handler's call"
          | _ ->
              "give it an implementation, like `Clock.frozen(t)`, or a \
               wrapper's call without its last argument, like `retry(3)`")
        (if is_var then
           "`with` can't tell what this installs: its type isn't known here"
         else
           sprintf
             "`with` installs an implementation, or wraps its body, but this \
              is %s"
             (article shown))

(* The wrapper call [call], `retry(3)`, of [f], of type [tf], given
   [args]: [body] is its last argument, a lambda of no parameters, whose
   type is recorded at [lam]. The `with` passes on what the call fails
   with, as `try` would: the body marks its own calls, and the wrapper is
   written to fail with what the body does. *)
and wrap env cx (e : expr) ~call ~f ~args ?target ?callee tf body lam =
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses) ->
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
      check_args env cx ~name ?callee firsts args;
      outer_changes env body name;
      let berrs = fresh_row env.st and buses = fresh_row env.st in
      let bcx = lambda_cx cx [] [] ~errs:berrs ~uses:buses in
      let tb =
        match repr last.ty with
        | TFun ([], r, _, _) ->
            check env bcx body r;
            r
        | _ -> infer env bcx body
      in
      let tl = TFun ([], tb, berrs, buses) in
      Hashtbl.replace cx.nodes lam tl;
      if last.mode = Inout then
        ignore
          (fail env call.loc
             ~notes:
               [
                 "`with w(a) in body` calls `w(a, fn() => body)`, and a lambda \
                  isn't a place to change";
               ]
             ~help:
               (sprintf "call %s outside the `with`, with all its arguments"
                  name)
             (sprintf "%s changes its last argument, so it can't take a body"
                name))
      else
        unify_at env call.loc ~found:tl ~expected:last.ty
          ~notes:
            [
              "`with w(a) in body` calls `w(a, fn() => body)`, so the \
               wrapper's last parameter is a function of no parameters";
            ]
          ~help:
            (sprintf "call %s outside the `with`, with all its arguments" name)
          ~msg:(fun _ x ->
            sprintf
              "%s's last parameter is %s, but a `with` passes it its body, a \
               `fn()`"
              name (article x));
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
        ~ename:(String.concat "" (String.split_on_char '`' name))
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
          (Diag.make place.loc
             ~notes:
               [
                 sprintf
                   "`with` passes its body to %s as a lambda, `fn() => ...`, \
                    which captures the values of the variables it uses when \
                    it's made, so changing them would have no effect outside"
                   name;
               ]
             ~help:"give the body's result back as its value instead"
             (sprintf
                "the body of this `with` can't change `%s`, a variable from \
                 outside it"
                b.ident.name))
    | _ -> ()
  in
  let rec walk (e : expr) =
    let all = List.iter walk in
    match e.kind with
    | Int _ | Bool _ | Str _ | Unit | Var _ -> ()
    | Lambda _ -> () (* its own changes are mut.ml's *)
    | Assign { target; value; _ } ->
        changed target;
        walk value
    | Ref { kind = Call ({ kind = Field (r, _); _ }, args); _ } ->
        changed r;
        all args
    | Ref a -> changed a
    | For { var; iter; body } ->
        (match iter.kind with Ref a -> changed a | _ -> walk iter);
        bind var;
        walk body
    | Block (stmts, last) ->
        List.iter
          (function
            | Let { name; value; _ } ->
                walk value;
                bind name
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
    | Unop (_, a) | Field (a, _) | Try a | Attempt a | Assert a -> walk a
    | Binop (_, a, b) | Index (a, b) -> all [ a; b ]
    | If (c, t, f) -> all (c :: t :: Option.to_list f)
    | Call (f, args) -> all (f :: args)
    | Con (_, args) | Fail (_, args) -> all (List.map snd args)
    | Record (_, fields) -> all (List.map snd fields)
    | Array xs -> all xs
    | With { item; body; _ } -> all [ item; body ]
    | Handler _ -> () (* only ever a handler's function's body *)
  in
  walk body

and stmt env cx = function
  | Let { name; ty; value; _ } ->
      let t =
        match ty with
        | Some ann ->
            let t =
              convert env ~tvars:cx.tparams ~named:cx.named
                ~row:(fun () -> fresh_row env.st)
                ann
            in
            check env cx value t;
            t
        | None -> infer env cx value
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
  env.drops <- { dloc = e.loc; dty = t; callee; dself = cx.self } :: env.drops

(* A call. One with a dot, `x.m(...)`, can be a method call, found through
   [x]'s type: as a field is, by [through_type], except that a method can
   be in a type of any kind, not only a record. [changed] is where the `&`
   is, if it's `&x.m(...)`. *)
and infer_call env cx ?changed ?tr (e : expr) (f : expr) args =
  match f.kind with
  | Field (r, m) -> (
      (* [tr] is the receiver's type, if it's inferred already *)
      let tr = match tr with Some t -> t | None -> infer env cx r in
      (* `r.m` is a field holding a function *)
      let field_call () =
        Option.iter
          (fun loc -> report env (not_changed loc ~recv:(env.source r) m.name))
          changed;
        let tf = field_access env cx f r tr m in
        Hashtbl.replace cx.nodes f.node tf;
        apply env cx e ~name:(sprintf "`%s`" m.name) f tf args
      in
      let nothing () =
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        TError
      in
      match (op_of env tr m.name, reveal env.st tr) with
      | Some (td, o), _ -> method_call env cx ?changed e f r m tr td o args
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
      let fix =
        match (o.okind, List.map env.source args) with
        | Value, _ -> item
        | _, shown when List.for_all Option.is_some shown ->
            item ^ "(" ^ String.concat ", " (List.filter_map Fun.id shown) ^ ")"
        | _ -> item ^ "(...)"
      in
      report env (not_a_method m o.okind ~fix);
      nothing ()
  | Method -> (
      let path = op_path td o in
      if path.home = env.home && not (Hashtbl.mem env.globals path) then
        raise (Unchecked { caller = cx.self; callee = path });
      let tm = lookup env cx f.loc (Global path) in
      Hashtbl.replace cx.nodes f.node tm;
      Hashtbl.replace cx.found f.node (Method_of path);
      match repr tm with
      | TFun (self :: ps, ret, errs, uses) ->
          (* a dependency's method takes an implementation that needs less
             than its `self` allows, as an argument does *)
          unify_at env r.loc ~found:(widen env ~loc:r.loc tr) ~expected:self.ty;
          (match (self.mode, changed) with
          | Inout, None ->
              report env (needs_amp e.loc ~recv ~call:(env.source e) o.oname)
          | Read, Some loc -> report env (not_changed loc ~recv o.oname)
          | Inout, Some _ | Read, None -> ());
          apply env cx e ~name:(sprintf "`%s`" o.oname)
            ?target:(if group_call env path then Some path else None)
            ~callee:path f
            (TFun (ps, ret, errs, uses))
            args
      | _ -> nothing ())

(* The call [e] of [f], a function of type [tf]; [name] says which, for
   messages, [target] which function of the group it is, if it's one, and
   [callee] which top-level function it is, if it's one. *)
and apply env cx (e : expr) ~name ?target ?callee (f : expr) tf args =
  let ename = String.concat "" (String.split_on_char '`' name) in
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses) ->
      let n = List.length ps and given = List.length args in
      if n <> given then (
        (* still check the arguments, for errors of their own *)
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        fail env e.loc
          (sprintf "%s takes %d argument%s but was given %d" name n (plural n)
             given))
      else (
        check_args env cx ~name ?callee ps args;
        absorb env cx ~call:e ~ename ~fn:f ?target ?callee errs uses;
        ret)
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         function, whose errors and dependencies are the call's *)
      let ps = List.map (infer_arg env cx) args in
      let ret = fresh_var env.st in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      unify_at env f.loc ~found:tf ~expected:(TFun (ps, ret, errs, uses));
      absorb env cx ~call:e ~ename ~fn:f errs uses;
      ret
  | TError ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      TError
  | t ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      fail env f.loc
        (sprintf "%s is %s, not a function" name
           (article (show (printer env) t)))

(* A call's arguments [args], left to right, each against its parameter's
   type, of [ps]; [name] is the callee, for messages, and [callee] the
   top-level function it is, if it's one. *)
and check_args env cx ~name ?callee ps args =
  List.iter2
    (fun (p : Types.param) (a : expr) ->
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
          ignore
            (fail env a.loc ~help:"put it in a `var` first, and pass that"
               ~notes:
                 [
                   sprintf
                     "the `&` in `%s` marks the receiver the call changes, not \
                      the argument"
                     (Option.value (env.source a) ~default:"&x.m()");
                 ]
               (sprintf
                  "%s changes this argument, but %s is a call's result, not \
                   something it can change"
                  name
                  (match env.source call with
                  | Some c -> sprintf "`%s`" c
                  | None -> "it")))
      | Inout, _ ->
          let help =
            match a.kind with
            | Var x
            | Field ({ kind = Var x; _ }, _)
            | Index ({ kind = Var x; _ }, _) ->
                sprintf "write `&` before it, as in `&%s`" (name_of x)
            | _ -> "pass a variable, marked with `&`"
          in
          ignore (infer env cx a);
          ignore
            (fail env a.loc ~help
               ~notes:[ "`&` shows at the call that the argument is changed" ]
               (sprintf "%s changes this argument, so it needs `&`" name))
      | Read, Ref place when passed ->
          ignore (infer env cx place);
          ignore
            (fail env a.loc ~help:"remove the `&`"
               ~notes:
                 [
                   "`&` marks an argument the call changes: an `inout` \
                    parameter";
                 ]
               (sprintf "%s doesn't change this argument" name))
      | Read, _ -> (
          let why = forced_why env callee p.ty in
          match repr p.ty with
          | TCon (_, [ TUses _ ]) ->
              (* an implementation that needs less than the parameter
                 allows will do, and so will a handler of several
                 dependencies, one of them the parameter's *)
              let t = taken_as env cx a (infer env cx a) p.ty in
              ignore
                (unifies env why (result_loc a) ~found:(widen env ~loc:a.loc t)
                   ~expected:p.ty)
          | _ -> check env cx ~why a p.ty))
    ps args

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
and infer_con env cx (e : expr) (cref : ctor_ref) args ~expected =
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
      hint env td tvars expected;
      if ctor_shape env e.loc c ctor (List.map fst args) then
        List.iter2
          (fun (f : Iface.field) (_, (a : expr)) ->
            check env cx a (field_type ~tvars f)
              ~why:
                (explain
                   ~notes:[ sprintf "`%s`'s field `%s`" c.name f.fname ]
                   ()))
          ctor.cfields args
      else
        (* still check the arguments, for errors of their own *)
        List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      t

(* A record literal: `User { ... }`, or `{ ... }` with its type found
   through [expected], or else through its fields. *)
and infer_record env cx (e : expr) name fields ~expected =
  let ids = List.map fst fields in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (f : ident) ->
      match Hashtbl.find_opt seen f.name with
      | Some first ->
          report env
            (Diag.make f.loc ~help:"remove one of them"
               ~labels:[ (first, sprintf "the first `%s` is here" f.name) ]
               (sprintf "there are two fields named `%s`" f.name))
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
      hint env td tvars expected;
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
              let ft = field_type ~tvars fd in
              (* a closure whose errors end in a named row, `! ..e`, could
                 fail with anything, which an operation can't *)
              let named_errors () =
                match v.kind with
                | Var (Local b) -> (
                    match Option.map repr (Hashtbl.find_opt cx.locals b.id) with
                    | Some (TFun (_, _, errs, _)) -> (
                        let rec tail r =
                          match repr_row r with
                          | RExtend (_, rest) -> tail rest
                          | RSkol (_, n) -> Some n
                          | _ -> None
                        in
                        match (tail errs, ft) with
                        | Some n, TFun (_, _, declared, _) ->
                            let declared =
                              List.map
                                (fun (l : label) -> l.name)
                                (fst (row_parts declared))
                            in
                            Some
                              (sprintf
                                 "`%s` can fail with anything `..%s` stands \
                                  for%s: write %s in place of `! ..%s`"
                                 b.ident.name n
                                 (match declared with
                                 | [] -> ", and the operation can't fail"
                                 | ds ->
                                     ", and the operation only with "
                                     ^ and_list ds)
                                 (match declared with
                                 | [] -> "nothing"
                                 | ds ->
                                     sprintf "`! %s`" (String.concat " | " ds))
                                 n)
                        | _ -> None)
                    | _ -> None)
                | _ -> None
              in
              let ft =
                match (t, ft) with
                | TCon (_, [ TUses needs ]), TFun (ps, r, errs, _) ->
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
                    env.impl_ops <-
                      {
                        idep = td.path;
                        iop = f.name;
                        ideclared = declared;
                        ierrs = open_errs;
                        ivalue = v;
                        inodes = cx.nodes;
                      }
                      :: env.impl_ops;
                    TFun (ps, r, open_errs, needs)
                | _ -> ft
              in
              let help = Option.map (fun h _ _ -> h) (named_errors ()) in
              check env cx v ft
                ~why:
                  (explain
                     ~notes:
                       [
                         sprintf "`%s`'s %s `%s`" (type_name env td.path) what
                           f.name;
                       ]
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
   is the `try` of a `try match`, which passes on what no arm handles. *)
and infer_match env cx ?passed subject arms ~want =
  let ts, errs =
    if handles arms then (
      let first = List.find (fun a -> is_fail a.arm_pat) arms in
      let m = marker env Mmatch first.arm_pat.ploc in
      let errs = fresh_row env.st in
      env.kept <- (errs, cx.params) :: env.kept;
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
    | Some (expected, why) -> (expected, fun _ -> why)
    | None ->
        let first = result_loc (List.hd arms).arm_body in
        ( fresh_var env.st,
          fun i ->
            let msg =
              if i = 0 then None
              else
                Some
                  (fun f x ->
                    sprintf "this arm is %s, but the arms above it are %s"
                      (article f) (article x))
            in
            explain ?msg
              ~labels:(fun _ x ->
                [ (first, sprintf "the first arm is %s" (article x)) ])
              () )
  in
  List.iteri
    (fun i a ->
      (match errs with
      | Some errs when is_fail a.arm_pat -> bind_fail env cx errs a.arm_pat
      | _ -> bind_pattern env cx ts a.arm_pat);
      Option.iter
        (fun g -> want_bool env "a guard" g (infer env cx g))
        a.arm_guard;
      check env cx ~why:(arm_why i) a.arm_body result)
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
                  unify_at env loc ~found:here ~expected:first ~msg:(fun f x ->
                      sprintf "`%s` is %s here, but %s in the first alternative"
                        b.ident.name (article f) (article x));
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
  let check found =
    unify_at env p.ploc ~found ~expected:t ~msg:(fun f x ->
        sprintf "expected a pattern for `%s`, but this one is %s" x (article f))
  in
  match (p.pkind, repr t) with
  | PCon ({ qual = None; name = c }, ps), TErrors errs ->
      (* a tag, inside `Err(...)`: one of the errors the [Result] holds *)
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
                  (fun fd sub -> bind_pattern env cx (field_type ~tvars fd) sub)
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
      env.tag_patterns <-
        {
          ttag = c;
          tpayload = payload;
          tset = errs;
          tin = cx.params;
          tarm = arm;
          tvalue = false;
        }
        :: env.tag_patterns;
      bind payload

(* Check every value the group threw away is `Unit` (see [drop]). One whose
   type is still unknown, like the result of calling a parameter, becomes
   `Unit`, and is kept in [forced]. *)
let dropped_values env =
  List.iter
    (fun d ->
      (match repr d.dty with
      | TVar _ -> env.forced <- (d.dself, d.dloc) :: env.forced
      | _ -> ());
      (* an implementation, or a handler's description, which a handler's
         call makes: it's for installing *)
      let implementation =
        match repr d.dty with TCon (_, [ TUses _ ]) -> true | _ -> false
      in
      unify_at env d.dloc ~found:d.dty ~expected:unit
        ~msg:(fun f _ ->
          match d.callee with
          | Some name when implementation ->
              sprintf "`%s` makes `%s`, and this throws it away" name f
          | Some name ->
              sprintf "`%s` returns `%s`, and this throws it away" name f
          | None -> sprintf "this is %s, and it's thrown away" (article f))
        ~help:
          (if implementation then
             "install it with `with`, or write `let _ = ...` if you mean to \
              drop it"
           else "use it, or write `let _ = ...` if you mean to drop it"))
    (List.rev env.drops);
  env.drops <- []
