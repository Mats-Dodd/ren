(* What a function declares, checked against what its body was found to
   do once its group is solved (see infer_top.ml): what it uses, what it
   fails with, what a handler needs, and the rows it names. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written

(* ---- what a function declares it uses ---- *)

(* The dependencies [f] declares, sorted: those its `uses` lists, or none
   for a public function without one, or an associated value, which uses
   nothing. A private function without `uses` declares nothing, and
   inference works out what it uses. *)
let declared_uses ~is_value (f : fn_def) =
  match f.uses with
  | _ when is_value f -> Some []
  | Some (u : Resolved.uses) ->
      Some (List.map (fun (l : Ty.label) -> l.name) (Iface.dep_labels u.deps))
  | None when f.pub -> Some []
  | None -> None

(* Whether the runtime installs the dependency [p] around `main`: one of
   the prelude's built-ins (deps.md, "`main`"). *)
let runtime_dep (p : Path.t) =
  p.home = Path.prelude_home && List.mem p.name Prelude.runtime_deps

(* Why the call [c], which brings in the dependency [dep], does: the
   function it calls calls a closure inside a `with` of [dep] that still
   gets it from outside, which [withheld] says (Infer_env.withheld). *)
let withheld_notes withheld dep (c : call option) =
  match c with
  | Some { callee = Some p; _ } ->
      List.filter_map
        (fun w -> if w.hfn = p && w.hdep = dep then Some w.hnote else None)
        withheld
  | _ -> []

(* Report each dependency [f]'s body uses that it doesn't declare, at the
   first call that brings it in. [cx] is what checking [f]'s body found.
   That's the first call whose callee had the dependency itself, before
   joining the caller's row; once joined, every open row has everything
   the caller uses. Only if there's none, which happens when the callee is
   in [f]'s group and its uses were found at the join, is it the first
   call whose row has it now. For the program's `main` ([main]), one the
   runtime doesn't install is left to [check_main]: adding it to `uses`
   wouldn't help. *)
let check_uses env ~is_value ~withheld ~main (f : fn_def) cx declared =
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let calls =
    List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !(cx.calls)
  in
  (* where it's first used, and what that is *)
  let first has = List.find_opt has calls in
  List.iter
    (fun dep ->
      if
        not
          (List.mem dep declared
          || (main && not (runtime_dep (Ty.dep_path dep))))
      then
        let call =
          match first (fun c -> List.mem dep c.own) with
          | Some c -> Some c
          | None -> first (fun c -> List.mem dep (row_names c.row))
        in
        let why = withheld_notes withheld dep call in
        let call =
          Option.map
            (fun c -> (c.cloc, if c.needs then Installing else Call_uses))
            call
        in
        let dep = env.names (Ty.dep_path dep) in
        report env
          (if is_value f then value_uses f dep call
           else undeclared_use ~why f dep call))
    (List.sort_uniq String.compare (row_names cx.uses))

(* What the handler [f] needs, [n]: never a dependency it implements,
   and, if its needs are written (or it's public), only what its `uses`
   lists, as for a function's own ([check_uses]); then that row is
   closed, to be exactly that. *)
let check_needs env (f : fn_def) n =
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let calls =
    List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !(n.ncalls)
  in
  (* the first call that brings in [dep], and what to say about it *)
  let call_of dep =
    let call =
      match List.find_opt (fun c -> List.mem dep c.own) calls with
      | Some c -> Some c
      | None -> List.find_opt (fun c -> List.mem dep (row_names c.row)) calls
    in
    Option.map
      (fun c -> (c.cloc, if c.needs then Installing else Call_uses))
      call
  in
  let own =
    List.map Ty.dep_label (Option.value (Iface.handler_deps f) ~default:[])
  in
  let written =
    match f.body.kind with Handler { needs; _ } -> needs <> None | _ -> false
  in
  List.iter
    (fun dep ->
      let shown = env.names (Ty.dep_path dep) in
      if List.mem dep own then
        report env (handler_uses_itself f shown (call_of dep))
      else
        match n.ndeclared with
        | Some declared when not (List.mem dep declared) ->
            report env (undeclared_need ~written f shown (call_of dep))
        | _ -> ())
    (List.sort_uniq String.compare (row_names n.nrow));
  if n.ndeclared <> None then close_row n.nrow

(* ---- what a function fails with (errors.md) ---- *)

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

(* Check that [f], which declares its errors, [declared], fails with
   exactly those: nothing else, reported at the first place that brings
   it in, and each of them, reported where it's written. [cx] is what
   checking [f]'s body found. *)
let check_errors env ~is_value (f : fn_def) cx declared =
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
    | Passed _ -> Call_fails
    | Failed _ -> Fails
    | Unwrapped _ -> Result_holds
    | Unhandled _ -> Match_leaves
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
          (if is_value f then
             value_fails f ~tag:l.name ~shape:(show_label pr l) from
           else undeclared_error f ~tag:l.name ~shape:(show_label pr l) from))
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

(* ---- named rows (deps.md, "Implementations") ---- *)

(* A public function's own rows stay open, as its interface says: a caller
   adds them to its own. A transparent parameter shares them, so if the
   body keeps one where its type is closed, `Box<fn() -> Int>`, the
   function's rows close with it, and the interface would be wrong about
   what the parameter may do. That's reported at the parameter. [cx] is
   what checking [f]'s body found. *)
let check_open_rows env (f : fn_def) cx =
  let closed r = row_end r = REmpty in
  let errs_closed =
    Option.bind f.errors (fun (es : Resolved.errors) -> es.etail) = None
    && closed cx.errs
  and uses_closed =
    Option.bind f.uses (fun (u : Resolved.uses) -> u.dtail) = None
    && closed cx.uses
  in
  let blamed =
    List.find_map
      (fun (p : Resolved.param) ->
        match p.pty with
        | Some (TyFn (_, _, e, u, _) as t) when not (names_row t) -> (
            let e = errs_closed && e = None and u = uses_closed && u = None in
            match (e, u) with
            | false, false -> None
            | true, false -> Some (p, None, Cant_fail)
            | false, true -> Some (p, None, Cant_use)
            | true, true -> Some (p, None, Cant_fail_or_use))
        | Some (TyImpl ({ tref = Named d; _ }, None, _)) when uses_closed ->
            Some (p, Some d, Cant_need)
        | _ -> None)
      f.params
  in
  match blamed with
  | None -> ()
  | Some (p, dep, closed) ->
      let name = p.pname.ident.name in
      let kept =
        match dep with
        | None -> Fn_param
        | Some d when name = "self" -> Dep_self (env.names d)
        | Some d -> Dep_param (env.names d)
      in
      report env
        (kept_closed p.pname.ident.loc ~name ~fn:(Ast.fn_name f) kept closed)

(* Once the group is done, and the uses of named rows have ended the rows
   they're added to (solve.ml), each function that names its own, `uses
   ..d` or `! ..e`, ends its own in it. One that declares what it fails
   with, but not a named row a call of a closure it was passed fails with,
   is reported. [fns] are the group's functions, each with what checking it
   found and whether it declares what it fails with. *)
let own_named_rows env (fns : (fn_def * ctx * bool) list) =
  let own_tail (es : Resolved.errors option) =
    Option.map
      (fun (n : ident) -> n.name)
      (Option.bind es (fun (es : Resolved.errors) -> es.etail))
  and own_dtail (u : Resolved.uses option) =
    Option.map
      (fun (n : ident) -> n.name)
      (Option.bind u (fun (u : Resolved.uses) -> u.dtail))
  in
  List.iter
    (fun ((f : fn_def), cx, errors) ->
      let named n =
        match List.assoc_opt n cx.named with
        | Some (RSkol (id, n)) -> Some (id, n)
        | _ -> None
      in
      (match Option.bind (own_dtail f.uses) named with
      | Some (id, n) -> (
          match row_end cx.uses with
          | RVar _ as t ->
              (* a variable still unbound takes any row, so this can't
                 fail *)
              Unify.unify_row env.st t (RSkol (id, n))
          | _ -> ())
      | None -> ());
      let declared = own_tail f.errors in
      match row_end cx.errs with
      | RSkol (id, n) when errors && declared <> Some n ->
          (* a call of a closure it was passed, which fails with [..n] *)
          let from =
            List.find_map
              (function
                | Passed c when row_tail c.erow = Some id -> Some c.eloc
                | _ -> None)
              (Option.fold ~none:[] ~some:( ! ) cx.sources)
          in
          report env
            (named_errors_undeclared
               (Option.value from ~default:f.name.loc)
               n ~fn:(Ast.fn_name f))
      | _ -> ())
    fns

(* A function that names its own errors' row, `! ..e`, fails with that
   row: its calls of itself do, and a call of a closure that fails with
   [..e] passes on what it can. That's known before the group's markers
   are checked, which need it, and its labels are all there by then. *)
let own_error_rows env (fns : (fn_def * ctx) list) =
  List.iter
    (fun ((f : fn_def), cx) ->
      match
        ( Option.bind f.errors (fun (es : Resolved.errors) -> es.etail),
          row_end cx.errs )
      with
      | Some (n : ident), (RVar _ as tail) -> (
          match List.assoc_opt n.name cx.named with
          | Some r ->
              (* a variable still unbound takes any row, so this can't
                 fail *)
              Unify.unify_row env.st tail r
          | None -> ())
      | _ -> ())
    fns
