(* Inference over a whole module (see infer.ml): the call graph, groups of
   functions that call each other, generalization, transparent parameters,
   what public functions and `main` have to spell out, and the canonical
   form of everything inference found. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_expr

(* ---- the call graph ---- *)

(* Group functions into strongly connected components of the call graph,
   callees before callers (Tarjan's algorithm, which finishes a component
   only after every component it reaches). [calls] lists the top-level
   functions each function uses, which resolve.ml found, and the methods
   it calls with a dot, as far as they're known (see [program]). *)
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
  List.iter
    (fun (f : fn_def) -> if not (Hashtbl.mem index f.name.name) then visit f)
    fns;
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
        | Unop (_, a) | Field (a, _) | Ref a | Lambda (_, a) | Try a | Attempt a
          ->
            mentions a
        | Fail (_, args) -> any (List.map snd args)
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
        | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a ->
            walk_all [ a ]
        | Fail (_, args) -> walk_all (List.map snd args)
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

(* ---- what's written ----

   Every type and error set written in the module, visited in source
   order: [ty] sees each type, inner ones too, [errors] each error set,
   and [pattern] each pattern. *)

let walk ~ty ~errors ~pattern (prog : program) =
  let rec ty_ (t : Resolved.ty) =
    ty t;
    match t with
    | TyName (_, args) -> List.iter ty_ args
    | TyFn (ps, ret, errs, _) ->
        List.iter ty_ ps;
        Option.iter ty_ ret;
        Option.iter errors_ errs
    | TyInout (t, _) -> ty_ t
    | TyErrors es -> errors_ es
  and errors_ (es : Resolved.errors) =
    errors es;
    List.iter
      (function
        | Tag (_, ps) ->
            List.iter (fun (p : Resolved.payload) -> ty_ p.payload_ty) ps
        | Set _ -> ())
      es.errs
  in
  let param (p : Resolved.param) = Option.iter ty_ p.pty in
  let rec pattern_ (p : Resolved.pattern) =
    pattern p;
    match p.pkind with
    | PWild | PVar _ | PInt _ | PBool _ | PFail_any -> ()
    | PCon (_, ps) | PFail (_, ps) | POr ps -> List.iter pattern_ ps
  in
  let rec expr (e : expr) =
    let go = List.iter expr in
    match e.kind with
    | Int _ | Bool _ | Unit | Var _ -> ()
    | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a -> expr a
    | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
        go [ a; b ]
    | If (c, t, f) -> go (c :: t :: Option.to_list f)
    | Call (f, args) -> go (f :: args)
    | Lambda (ps, body) ->
        List.iter param ps;
        expr body
    | Block (stmts, last) ->
        List.iter
          (function
            | Let { ty = t; value; _ } ->
                Option.iter ty_ t;
                expr value
            | Expr e -> expr e)
          stmts;
        expr last
    | Con (_, args) | Fail (_, args) -> go (List.map snd args)
    | Record (_, fields) -> go (List.map snd fields)
    | Match (s, arms) ->
        expr s;
        List.iter
          (fun (a : arm) ->
            pattern_ a.arm_pat;
            Option.iter expr a.arm_guard;
            expr a.arm_body)
          arms
    | Array xs -> go xs
    | For { iter; body; _ } -> go [ iter; body ]
  in
  let fn_ (f : fn_def) =
    List.iter param f.params;
    Option.iter ty_ f.ret;
    Option.iter errors_ f.errors;
    expr f.body
  in
  List.iter
    (function
      | Fn f -> fn_ f
      | Type td ->
          let field (fd : Resolved.field) = ty_ fd.field_ty in
          (match td.type_body with
          | Fields fs -> List.iter field fs
          | Ctors cs -> List.iter (fun c -> List.iter field c.ctor_fields) cs
          | Opaque t -> ty_ t
          | Errors es -> errors_ es);
          List.iter (fun (o : op) -> fn_ o.op_fn) td.type_ops
      | Import _ -> ())
    prog

(* The error sets and `Result`s written in the module make sense: an
   error set is a type argument only of `Result`, whose second argument
   is always one, and no set, named sets expanded, has two shapes of one
   tag. [sets] are the named error sets the module can see, and [names]
   says how it writes a type's name. *)
let written_loc : Resolved.ty -> Loc.t = function
  | TyName ({ tloc; _ }, _) -> tloc
  | TyFn (_, _, _, l) | TyInout (_, l) -> l
  | TyErrors es -> es.eloc

let check_written sink ~sets ~names (prog : program) =
  let report = Diag.report sink in
  let result = Path.prelude "Result" in
  let ty (t : Resolved.ty) =
    match t with
    | TyName ({ tref = Named p; _ }, [ _; arg ]) when p = result -> (
        match arg with
        | TyErrors _ -> ()
        | arg ->
            report
              (Diag.make (written_loc arg)
                 ~notes:
                   [
                     "a `Result` holds a value or an error, which `attempt` \
                      keeps there";
                   ]
                 ~help:
                   "write an error set, after `!`: `Result<Int, ! NotFound>`"
                 "`Result`'s second argument is an error set"))
    | TyName ({ tref = Named p; _ }, args) ->
        List.iter
          (function
            | TyErrors (es : Resolved.errors) ->
                report
                  (Diag.make es.eloc
                     ~help:
                       "an error set goes after `!` in a signature or a \
                        function type, or in `Result<T, ! ...>`"
                     (sprintf "`%s` doesn't take an error set" (names p)))
            | _ -> ())
          args
    | TyName _ | TyFn _ | TyInout _ | TyErrors _ -> ()
  in
  let pr = Ty.printer ~names { ty = Error; names = [] } in
  let errors (es : Resolved.errors) =
    let tags = Iface.tags ~sets (Iface.declared_errors ~sets es) in
    let reported = ref [] in
    List.iter
      (fun ((l : Ty.label), via) ->
        match
          List.find_opt
            (fun ((m : Ty.label), _) ->
              m.name = l.name && m.payload <> l.payload)
            tags
        with
        | Some (m, via') when not (List.mem l.name !reported) ->
            reported := l.name :: !reported;
            let from (l : Ty.label) via =
              let where =
                match via with
                | Some (p : Path.t) -> sprintf "from `%s`" (names p)
                | None -> "written here"
              in
              sprintf "%s: `%s`" where (Ty.show_label pr l)
            in
            report
              (Diag.make es.eloc
                 ~notes:
                   [
                     from l via;
                     from m via';
                     "a tag is its name and its payload's types, so these are \
                      two errors with one name";
                   ]
                 ~help:"rename one of them"
                 (sprintf "`%s` has two shapes here" l.name))
        | _ -> ())
      tags
  in
  walk prog ~ty ~errors ~pattern:(fun _ -> ())

(* ---- what a function declares it uses ---- *)

(* The dependencies [f] declares, sorted: those its `uses` lists, or none
   for a public function without one, or an associated value, which uses
   nothing. A private function without `uses` declares nothing, and
   inference works out what it uses. *)
let declared_uses ~is_value (f : fn_def) =
  match f.uses with
  | _ when is_value f -> Some []
  | Some ds ->
      Some
        (List.sort_uniq String.compare
           (List.map (fun (d : ident) -> d.name) ds))
  | None when f.pub -> Some []
  | None -> None

(* Report each dependency [f]'s body uses that it doesn't declare, at the
   first call that brings it in. [cx] is what checking [f]'s body found.
   That's the first call whose callee had the dependency itself, before
   joining the caller's row; once joined, every open row has everything
   the caller uses. Only if there's none, which happens when the callee is
   in [f]'s group and its uses were found at the join, is it the first
   call whose row has it now. *)
let check_uses env ~is_value (f : fn_def) cx declared =
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let calls =
    List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !(cx.calls)
  in
  let first has =
    List.find_map (fun c -> if has c then Some c.cloc else None) calls
  in
  List.iter
    (fun dep ->
      if not (List.mem dep declared) then
        let call =
          match first (fun c -> List.mem dep c.own) with
          | Some loc -> Some loc
          | None -> first (fun c -> List.mem dep (row_names c.row))
        in
        report env
          (if is_value f then value_uses f dep call
           else undeclared_use f dep call))
    (List.sort_uniq String.compare (row_names cx.uses))

(* ---- what a function fails with (errors.md) ---- *)

(* The error rows of a function's transparent parameters, the [params]
   written `fn(...)` without a `!`, given their types [ps]. *)
let transparent_rows (params : Resolved.param list) ps =
  List.concat
    (List.map2
       (fun (p : Resolved.param) (t : Types.param) ->
         match (p.pty, repr t.ty) with
         | Some (TyFn (_, _, None, _)), TFun (_, _, e, _) -> [ e ]
         | _ -> [])
       params ps)

(* The errors [f] declares, as labels: those written after its `!`, named
   sets expanded, or none for a public function without one, or an
   associated value, which can't fail. A private function without `!`
   declares nothing, and inference works out what it fails with. *)
let declared_errors env ~is_value ~tparams (f : fn_def) =
  match f.errors with
  | _ when is_value f -> Some []
  | Some es -> Some (error_labels env ~tvars:tparams es)
  | None when f.pub -> Some []
  | None -> None

(* Does a row ending in [tail] belong to one of [params]? Then it stands
   for whatever the function passed there fails with. *)
let in_params params tail =
  List.exists (fun (_, t) -> List.mem tail (row_vars t)) params

(* Whether the call [c] can fail, now that its group is done: its callee
   fails with something, which for a function of the group is known only
   now, or its errors are those of a function the caller was passed. *)
let can_fail (c : ecall) =
  row_names c.erow <> []
  ||
  match row_tail c.erow with
  | Some t -> in_params c.eparams t
  | None -> false

(* Finish each inclusion of the group (see [Infer_expr.inclusion]), now
   that its functions are joined: add the labels each row learned since,
   until no row learns any more, and end a row that includes a
   parameter's errors in the same tail as that parameter's. *)
let settle_inclusions env =
  let changed = ref true in
  (* a row's tail, the variable at its end *)
  let rec tail r =
    match repr_row r with RExtend (_, rest) -> tail rest | r -> r
  in
  while !changed do
    changed := false;
    List.iter
      (fun (i : inclusion) ->
        let labels, src_tail = row_parts i.isrc in
        (match
           List.filter
             (fun (l : label) -> not (List.mem l.name i.ipassed))
             labels
         with
        | [] -> ()
        | fresh ->
            changed := true;
            i.ipassed <- i.ipassed @ List.map (fun (l : label) -> l.name) fresh;
            i.iadd (extend fresh REmpty));
        match src_tail with
        | Some t when (not i.ilinked) && in_params i.iparams t -> (
            changed := true;
            i.ilinked <- true;
            (* an open row takes on the parameter's tail, and stays what
               it is before it; a closed one, a lambda's whose type is
               written, says what the parameter can fail with *)
            let a, b =
              match row_tail i.idst with
              | Some _ -> (tail i.isrc, tail i.idst)
              | None -> (i.isrc, i.idst)
            in
            try Unify.unify_row env.st a b
            with Unify.Mismatch | Unify.Infinite | Unify.Two_shapes _ ->
              report env
                (Diag.make i.iloc
                   ~help:
                     "write what the function passed can fail with in its \
                      parameter's type, after `!`"
                   "this can fail with whatever a function it was passed fails \
                    with, which isn't allowed here"))
        | _ -> ())
      (List.rev env.includes)
  done;
  env.includes <- []

(* The rules of markers, checked once the group's functions are joined,
   when it's known what each call fails with (errors.md, "Marking"):

   1. each `attempt` keeps exactly what the calls it covers fail with, and
      each `match` with `fail` arms handles exactly that
   2. each tag matched in those errors is one of them
   3. each `try r` of a [Result] fails with what [r] holds, and each
      `try match` with what its arms don't handle
   4. a call no marker covers can't fail
   5. every marker covers something that can fail: a `match`'s `fail`
      arms match something *)
let settle_errors env =
  let pr = printer env in
  settle_inclusions env;
  (* an `attempt` of a call of a function it was passed keeps whatever
     that function fails with: its set stays open, like the function's *)
  List.iter
    (fun (kept, params) ->
      match row_tail kept with
      | Some t when in_params params t -> ()
      | _ -> close_row kept)
    env.kept;
  List.iter
    (fun t ->
      let c = t.ttag and payload = t.tpayload and arm = t.tarm in
      let labels, tail = row_parts t.tset in
      let tags =
        List.map (fun (l : label) -> (l.name, show_label pr l)) labels
      in
      match List.find_opt (fun (l : label) -> l.name = c.name) labels with
      | _ when arm && labels = [] && tail = None ->
          (* a `fail` arm of a `match` whose subject can't fail, which is
             reported once, below *)
          ()
      | Some l when List.length l.payload = List.length payload ->
          List.iter2
            (fun found expected -> unify_at env c.loc ~found ~expected)
            payload l.payload
      | Some l ->
          report env
            (tag_arity c.loc c (List.length l.payload) (List.length payload))
      | None -> (
          (* a set still open holds what a function it was passed fails
             with *)
          match
            Option.bind tail (fun tl ->
                List.find_opt (fun (_, ty) -> List.mem tl (row_vars ty)) t.tin)
          with
          | Some (param, _) -> report env (tag_in_open_set c ~arm ~param tags)
          | None -> report env (not_an_error c ~arm tags)))
    (List.rev env.tag_patterns);
  List.iter
    (fun ((c : ecall), unhandled) ->
      let labels, tail = row_parts unhandled in
      let own t = List.exists (fun e -> row_tail e = Some t) c.eselves in
      match tail with
      | Some t when own t && in_params c.eparams t ->
          (* the call's errors are its caller's own, those of a function
             it was passed *)
          let param, _ =
            List.find (fun (_, ty) -> List.mem t (row_vars ty)) c.eparams
          in
          report env
            (unhandled_param c.eloc ~name_loc:c.ename_loc c.ename param)
      | _ when labels <> [] ->
          report env
            (unhandled_call c.eloc ~name_loc:c.ename_loc c.ename
               (List.map (show_label pr) labels))
      | Some t when own t ->
          (* the caller's own errors, which it doesn't pass on: it fails
             with none, or this is reported where it does *)
          ()
      | _ -> close_row unhandled)
    (List.rev env.unmarked);
  List.iter
    (fun m ->
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
          | Mtry -> covers_nothing m.mloc ?help:m.hint "try"
          | Mattempt -> covers_nothing m.mloc ?help:m.hint "attempt"
          | Mmatch -> cannot_fail_arm m.mloc))
    (List.rev env.all_markers);
  env.kept <- [];
  env.tag_patterns <- [];
  env.unmarked <- [];
  env.all_markers <- []

(* Check that [f], which declares its errors, [declared], fails with
   exactly those: nothing else, reported at the first place that brings
   it in, and each of them, reported where it's written. [cx] is what
   checking [f]'s body found. *)
let check_errors env (f : fn_def) cx declared =
  let pr = printer env in
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let loc = function
    | Passed c -> c.eloc
    | Failed (l, _) | Unwrapped (l, _) | Unhandled (l, _) -> l
  in
  let sources =
    List.sort
      (fun a b -> compare (pos (loc a)) (pos (loc b)))
      (Option.fold ~none:[] ~some:( ! ) cx.sources)
  in
  let is_declared name =
    List.exists (fun (d : label) -> d.name = name) declared
  in
  (* what each source fails with: a call, its callee's errors, unless
     they're [f]'s own *)
  let brings = function
    | Passed c -> if c.eself then [] else row_names c.erow
    | Failed (_, l) -> [ l.name ]
    | Unwrapped (_, r) | Unhandled (_, r) -> row_names r
  in
  let what = function
    | Passed _ -> "this call can fail with"
    | Failed _ -> "this fails with"
    | Unwrapped _ -> "this `Result` holds"
    | Unhandled _ -> "no arm of this `match` handles"
  in
  List.iter
    (fun (l : label) ->
      if not (is_declared l.name) then
        let from =
          match List.find_opt (fun s -> List.mem l.name (brings s)) sources with
          | Some s -> Some (loc s, what s)
          | None -> (
              match
                List.find_opt
                  (function
                    | Passed c -> List.mem l.name (row_names c.erow)
                    | _ -> false)
                  sources
              with
              | Some s -> Some (loc s, what s)
              | None -> None)
        in
        report env
          (undeclared_error f ~tag:l.name ~shape:(show_label pr l) from))
    (List.sort
       (fun (a : label) b -> String.compare a.name b.name)
       (fst (row_parts cx.errs)));
  (* a call of a function [f] was passed can fail with anything, so with
     each of them *)
  let anything =
    List.exists
      (function
        | Passed c -> (
            match row_tail c.erow with
            | Some t -> in_params c.eparams t
            | None -> false)
        | _ -> false)
      sources
  in
  if not anything then
    let actual = List.concat_map brings sources in
    let written =
      match f.errors with
      | None -> []
      | Some es ->
          List.concat_map
            (function
              | Tag ((t : ident), _) -> [ (t.name, t.loc, None) ]
              | Set { tref = Named p; tloc } ->
                  List.map
                    (fun ((l : Ty.label), _) -> (l.name, tloc, Some p))
                    (Iface.tags ~sets:env.sets [ Iface.Set p ])
              | Set { tref = Param _; _ } -> [])
            es.errs
    in
    let seen = ref [] in
    List.iter
      (fun (tag, loc, via) ->
        if not (List.mem tag actual || List.mem tag !seen) then (
          seen := tag :: !seen;
          report env (unused_error f ~tag ~via:(Option.map env.names via) loc)))
      written

(* Once the body of the function at [path] has been reported failing with
   something it doesn't declare, its callers see it failing with what it
   declares, so the one mistake isn't reported again at every call. A
   transparent parameter's row, which is its function's, goes with it. *)
let as_declared env path cx declared =
  let names = List.map (fun (l : label) -> l.name) declared in
  if List.exists (fun n -> not (List.mem n names)) (row_names cx.errs) then
    match repr (Hashtbl.find env.globals path) with
    | TFun (ps, ret, errs, uses) ->
        let errs' = extend declared (fresh_row env.st) in
        let param (p : Types.param) =
          match repr p.ty with
          | TFun (qs, r, e, u)
            when row_tail e <> None && row_tail e = row_tail errs ->
              { p with ty = TFun (qs, r, errs', u) }
          | _ -> p
        in
        Hashtbl.replace env.globals path
          (TFun (List.map param ps, ret, errs', uses))
    | _ -> ()

(* ---- associated values ----

   An associated value is made once, when the program starts, before
   `main` runs: each after every value it uses, through any function it
   calls, so a value never sees one that isn't made yet. Another module's
   values are made before this module's, since the modules are made in
   the order they import each other. *)

(* The module's values in the order they're made, each reported if it
   needs itself to be made. A function's edges are what resolve.ml found
   it uses, and the methods it calls with a dot, which [found] says (the
   context each function was checked in). *)
let value_order env (r : Resolve.t) (fns : fn_def list) ~is_value ~found =
  let home = r.home in
  let edges name =
    let dots =
      match Hashtbl.find_opt found name with
      | Some cx ->
          Hashtbl.fold
            (fun _ f acc ->
              match f with
              | Method_of (p : Path.t) when p.home = home -> p.name :: acc
              | _ -> acc)
            cx.found []
      | None -> []
    in
    List.filter_map
      (fun (p : Path.t) -> if p.home = home then Some p.name else None)
      (List.assoc name r.calls)
    @ dots
    |> List.sort_uniq compare
  in
  let values = List.filter is_value fns in
  let value_named n =
    List.find_opt (fun (f : fn_def) -> f.name.name = n) values
  in
  (* a way from [n] back to [goal], if there is one: the functions and
     values on it, ending with [goal] *)
  let rec back ~seen goal n =
    List.find_map
      (fun m ->
        if m = goal then Some [ m ]
        else if Hashtbl.mem seen m then None
        else (
          Hashtbl.replace seen m ();
          Option.map (fun way -> m :: way) (back ~seen goal m)))
      (edges n)
  in
  (* the values of a cycle already reported, so a cycle is reported once,
     from whichever of its values comes first *)
  let reported = ref [] in
  List.iter
    (fun (v : fn_def) ->
      let n = v.name.name in
      if not (List.mem n !reported) then
        match back ~seen:(Hashtbl.create 8) n n with
        | Some way ->
            let chain = n :: way in
            reported :=
              List.filter (fun m -> value_named m <> None) chain @ !reported;
            report env
              (Diag.make v.name.loc
                 ~notes:
                   [
                     "an associated value is made once, when the program \
                      starts, so it can't need itself to be made";
                   ]
                 ~help:
                   (if way = [ n ] then "make it without using itself"
                    else "make one of them without the other")
                 (sprintf "`%s` is made from itself: %s" n
                    (String.concat " → " chain)))
        | None -> ())
    values;
  (* each value after every one it reaches: a depth-first walk, which adds
     a value once everything it reaches is done *)
  let visited = Hashtbl.create 16 and order = ref [] in
  let rec visit n =
    if not (Hashtbl.mem visited n) then (
      Hashtbl.replace visited n ();
      List.iter visit (edges n);
      if value_named n <> None then order := n :: !order)
  in
  List.iter (fun (v : fn_def) -> visit v.name.name) values;
  List.rev !order

(* ---- the program ---- *)

(* What inference found, in canonical form (ty.ml). *)
module Nodes = Map.Make (Int)

type node = { ty : Ty.ty; found : found option }

type t = {
  schemes : (string * Ty.scheme) list;  (** each function's, in source order *)
  values : string list;
      (** the module's associated values, in the order they're made when the
          program starts: each after every value it uses *)
  nodes : (string * node Nodes.t) list;
      (** each function's expressions and patterns, by node id *)
  in_scope : Path.t list;
      (** the types step 2 of a lookup through a type found, sorted *)
}

(* Infer every function's type, and return each function's type scheme and
   the types of its expressions, in canonical form. [imports] are the
   interfaces of the modules it imports, whose functions it can call, and
   [reachable] those of every module reachable through them, whose types
   it can meet: a field of an imported type can have a type from a module
   this one never imported. [extra] are the dot calls of methods found so
   far that the call graph needs besides [r]'s (see [program]). *)
let check sink ~extra ~imports ~reachable ?entry (r : Resolve.t) =
  let st = Types.new_state () in
  let home = r.home in
  let types = Hashtbl.create 16 in
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace types td.path td)
    (List.concat_map (fun (iface : Iface.t) -> iface.types) reachable @ r.types);
  (* this module's opaque types are what they're represented as, here *)
  List.iter
    (fun (td : Iface.type_decl) ->
      match td.body with
      | Opaque (Some rep) -> Hashtbl.replace st.reps td.path rep
      | _ -> ())
    r.types;
  (* the types step 2 of a lookup through a type looks in: those the
     module can name bare. [r.scope] is sorted by name, and two of its
     types never share one. *)
  let visible = List.map (fun (_, p) -> Hashtbl.find types p) r.scope in
  let env =
    {
      st;
      sink;
      home;
      names = Resolve.type_name r;
      can_name = Resolve.can_name r;
      source =
        Ast.source ~type_name:(Resolve.type_name r)
          ~value_name:(Resolve.value_name r);
      types;
      sets =
        (fun p ->
          match Hashtbl.find_opt types p with
          | Some { body = Errors es; _ } -> Some es
          | _ -> None);
      visible;
      globals = Hashtbl.create 16;
      group = [];
      spelled = [];
      joins = [];
      drops = [];
      forced = [];
      unmarked = [];
      all_markers = [];
      kept = [];
      includes = [];
      tag_patterns = [];
      in_scope = [];
    }
  in
  check_written sink ~sets:env.sets ~names:env.names r.prog;
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.globals
            (Path.make iface.home v.vname)
            (of_scheme st v.scheme))
        iface.values)
    imports;
  (* and the members of every type the module can meet, which it can
     call with a dot; an associated value is a function of no parameters,
     as in its own module (ast.ml) *)
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          List.iter
            (fun (o : Iface.op) ->
              let t = of_scheme st o.oscheme in
              Hashtbl.replace env.globals (op_path td o)
                (if o.okind = Value then TFun ([], t, REmpty, REmpty) else t))
            td.members)
        iface.types)
    reachable;
  (* the module's functions, its types' members included; an associated
     value is checked as a function of no parameters (ast.ml) *)
  let fns = Ast.functions r.prog in
  (* a method whose signature is written out in full has the type its
     declaration gives it, as it does in its interface, even before it's
     checked: a dot call of it needn't come after it (Resolve.t.methods) *)
  List.iter
    (fun (f : fn_def) ->
      match f.params with
      | p :: _ when p.pname.ident.name = "self" && Ast.spelled f ->
          Hashtbl.replace env.globals
            (Path.make home f.name.name)
            (of_scheme st (Iface.signature ~sets:env.sets f))
      | _ -> ())
    fns;
  let values =
    List.concat_map
      (function
        | Type td ->
            List.filter_map
              (fun (o : op) ->
                if o.op_kind = Op_value then Some o.op_fn.name.name else None)
              td.type_ops
        | Fn _ | Import _ -> [])
      r.prog
  in
  let is_value (f : fn_def) = List.mem f.name.name values in
  let path (f : fn_def) = Path.make home f.name.name in
  List.iter (check_transparent sink) fns;
  let schemes = Hashtbl.create 16 in
  let tables = Hashtbl.create 16 in
  List.iter
    (fun group ->
      enter_level env.st;
      (* each function's type within the group: its own type parameters
         (as skolems), parameters, result and effects. [declared] makes the
         type its declaration gives it, which is how the group's other
         functions see it until the group is done. *)
      let setup (f : fn_def) =
        let skolems =
          List.map (fun (t : ident) -> (fresh_id env.st, t.name)) f.tparams
        in
        let tparams = List.map (fun (id, n) -> TSkol (id, n)) skolems in
        let signature () =
          (* a function that declares its dependencies starts with them: its
             body can add to them only through a transparent parameter, whose
             row this is too, and whatever else it adds is reported once the
             group is done. The same goes for its errors. *)
          let errs =
            extend
              (Option.value
                 (declared_errors env ~is_value ~tparams f)
                 ~default:[])
              (fresh_row env.st)
          in
          let uses =
            List.fold_right
              (fun d rest -> RExtend (dep d, rest))
              (Option.value (declared_uses ~is_value f) ~default:[])
              (fresh_row env.st)
          in
          (* A public function's transparent parameter fails with exactly
             its function's errors, as its interface says. A private one's
             gets a row of its own, which a `try` of it joins to the
             function's: an `attempt` of it keeps its errors instead, and
             then the function itself doesn't fail with them. *)
          let ps =
            List.map
              (fun p ->
                let own = if f.pub then errs else fresh_row env.st in
                param_type env ~tparams ~own:(own, uses) p)
              f.params
          in
          let ret =
            match f.ret with
            | Some t -> convert env ~tvars:tparams ~row:closed t
            | None when f.pub && not (is_value f) ->
                unit (* a public function without `->` returns Unit *)
            | None -> fresh_var env.st
          in
          (ps, ret, errs, uses)
        in
        let ps, ret, errs, uses = signature () in
        let cx =
          {
            self = path f;
            locals = Hashtbl.create 16;
            nodes = Hashtbl.create 64;
            found = Hashtbl.create 16;
            errs;
            uses;
            calls = ref [];
            tparams;
            handler = errs;
            markers = [];
            params =
              List.map2
                (fun (p : Resolved.param) (t : Types.param) ->
                  (p.pname.ident.name, t.ty))
                f.params ps;
            (* a transparent parameter's errors are the function's own *)
            selves = errs :: transparent_rows f.params ps;
            sources = Some (ref []);
          }
        in
        Hashtbl.replace env.globals (path f) (TFun (ps, ret, errs, uses));
        let declared () =
          let ps, ret, errs, uses = signature () in
          TFun (ps, ret, errs, uses)
        in
        ((f, skolems, cx, ps, ret), (path f, declared))
      in
      let setups, declared = List.split (List.map setup group) in
      env.group <- declared;
      env.spelled <-
        List.filter_map
          (fun (f : fn_def) -> if Ast.spelled f then Some (path f) else None)
          group;
      List.iter
        (fun ((f : fn_def), _, cx, ps, ret) ->
          bind_params cx f.params ps;
          let why =
            match f.ret with
            | Some _ ->
                explain
                  ~notes:
                    [
                      (if is_value f then
                         sprintf "`%s` is declared to have the type `%s`"
                       else sprintf "`%s` is declared to return `%s`")
                        f.name.name
                        (show (printer env) ret);
                    ]
                  ()
            | None when f.pub && not (is_value f) ->
                explain
                  ~notes:[ "a public function without `->` returns `Unit`" ]
                  ~help:(fun found _ ->
                    sprintf "add `-> %s` to the signature" found)
                  ()
            | None -> plain
          in
          check env cx ~why f.body ret)
        setups;
      (* every use of a function by another of its group, joined with the
         type its own body gave it *)
      List.iter
        (fun j ->
          let msg f x =
            sprintf
              "`%s` is used here as `%s`, but its definition makes it `%s`"
              j.jname f x
          in
          let expected = Hashtbl.find env.globals j.target in
          match (repr j.used, repr expected) with
          | TFun ([], used, _, _), TFun ([], made, _, _)
            when List.exists (fun f -> is_value f && path f = j.target) fns ->
              (* an associated value, a function of no parameters (ast.ml),
                 is used as its result, which is what's shown *)
              unify_at env j.jloc ~found:used ~expected:made ~msg
                ~notes:
                  [
                    "values and functions that need each other are checked at \
                     a single type";
                  ]
          | _ ->
              unify_at env j.jloc ~found:j.used ~expected ~msg
                ~notes:
                  [
                    "functions that call each other are checked at a single \
                     type";
                  ])
        (List.rev env.joins);
      env.joins <- [];
      dropped_values env;
      (* only now, with the group's uses of each other joined, is it known
         everything each function uses and fails with *)
      settle_errors env;
      env.group <- [];
      env.spelled <- [];
      List.iter
        (fun ((f : fn_def), skolems, cx, _, _) ->
          Option.iter
            (check_uses env ~is_value f cx)
            (declared_uses ~is_value f);
          Option.iter
            (fun declared ->
              check_errors env f cx declared;
              as_declared env (path f) cx declared)
            (declared_errors env ~is_value
               ~tparams:(List.map (fun (id, n) -> TSkol (id, n)) skolems)
               f))
        setups;
      leave_level env.st;
      List.iter
        (fun ((f : fn_def), skolems, cx, _, _) ->
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
          Hashtbl.replace schemes f.name.name scheme;
          Hashtbl.replace tables f.name.name cx)
        setups;
      (* public values spell out their type *)
      List.iter
        (fun ((f : fn_def), _, _, _, _) ->
          if f.pub && is_value f && f.ret = None then
            match Hashtbl.find schemes f.name.name with
            | TFun (_, t, _, _) as scheme ->
                let pr = printer env in
                reserve pr scheme;
                ignore
                @@ fail env f.name.loc
                     ~help:
                       (sprintf "write `pub let %s: %s`"
                          (short_name f.name.name) (show pr t))
                     ~notes:[ "public values spell out their type" ]
                     (sprintf "the public value `%s` has no type" f.name.name)
            | _ -> assert false)
        setups;
      (* public functions spell out their full contract *)
      List.iter
        (fun ((f : fn_def), _, _, _, _) ->
          if f.pub && not (is_value f) then
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
    (components ~home
       ~calls:
         (List.map
            (fun (f, calls) ->
              let found =
                List.filter_map
                  (fun (caller, m) ->
                    if caller = f then Some (Path.make home m) else None)
                  extra
              in
              (f, calls @ List.assoc f r.methods @ found))
            r.calls)
       fns);
  let values = value_order env r fns ~is_value ~found:tables in
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
  (* Each function's scheme and node types share one numbering, so a
     variable is the same [Var n] in both. Nodes are converted in order of
     their ids, so the numbering doesn't depend on a hash table's order. *)
  let canonical (f : fn_def) =
    let c = canon st in
    let ty = canon_ty c ~all:false (Hashtbl.find schemes f.name.name) in
    let scheme : Ty.scheme = { ty; names = canon_names c } in
    let cx = Hashtbl.find tables f.name.name in
    let nodes =
      Hashtbl.fold (fun id _ acc -> id :: acc) cx.nodes []
      |> List.sort compare
      |> List.fold_left
           (fun acc id ->
             Nodes.add id
               {
                 ty = canon_ty c ~all:true (Hashtbl.find cx.nodes id);
                 found = Hashtbl.find_opt cx.found id;
               }
               acc)
           Nodes.empty
    in
    ((f.name.name, scheme), (f.name.name, nodes))
  in
  let schemes, nodes = List.split (List.map canonical fns) in
  { schemes; values; nodes; in_scope = List.sort compare env.in_scope }

(* Which method a dot call like `s.size()` calls is found only by checking
   the call, through `s`'s type, but the call graph puts the functions in
   order before anything is checked. So the graph starts with the dot calls
   resolve.ml could tell (Resolve.t.methods), and when checking finds a dot
   call of a method that isn't checked yet, that call is added to the graph
   and the module is checked again, from the start. Each time adds a call
   the graph didn't have, so this ends. Only the calls a function really
   makes join it to a group, so a method that only shares a name with the
   one called changes nothing about the caller's type or its `uses`.

   A try reports to its own sink, and only the last try's errors are kept. *)
let program sink ~imports ~reachable ?entry (r : Resolve.t) =
  let rec go extra =
    let tried = Diag.sink () in
    let keep () = List.iter (Diag.report sink) (List.rev tried.reported) in
    match check tried ~extra ~imports ~reachable ?entry r with
    | t ->
        keep ();
        t
    | exception Infer_expr.Unchecked { caller; callee } ->
        go ((caller, callee) :: extra)
    | exception e ->
        keep ();
        raise e
  in
  go []
