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
let declared_uses env ~is_value ~tparams ?(named = []) (f : fn_def) =
  match f.uses with
  | _ when is_value f -> Some []
  | Some (u : Resolved.uses) ->
      (* a row it names inside one of them, `Actors<K, (D ! ..e)>`, is its
         signature's *)
      Some (fst (row_parts (written_uses env ~tvars:tparams ~named u)))
  | None when f.pub -> Some []
  | None -> None

(* Whether [f] declares what it uses ([declared_uses]). *)
let declares_uses ~is_value (f : fn_def) = is_value f || f.uses <> None || f.pub

(* Whether the runtime installs the dependency [p] around `main`: one of
   the prelude's built-ins (deps.md, "`main`"). *)
let runtime_dep (p : Path.t) =
  p.home = Path.prelude_home && List.mem p.name Prelude.runtime_deps

(* Why the call [c], which brings in the dependency [dep], does: the
   function it calls calls something inside a `with` of [dep] that uses
   what that function itself does, so it still gets [dep] from outside,
   which [withheld] says (Infer_env.withheld). A block never gets what a
   `with` around its call installs unless its type lists it, so it's no
   reason: what it uses is its writer's (foundations.md, decision 5). *)
let withheld_notes withheld dep (c : call option) =
  match c with
  | Some { callee = Some p; _ } ->
      List.filter_map
        (fun w ->
          if w.hfn = p && same_label w.hdep dep then Some w.hnote else None)
        withheld
  | _ -> []

(* Report each dependency [f]'s body uses that it doesn't declare, at the
   first call that brings it in. [cx] is what checking [f]'s body found.
   That's the first call whose callee had the dependency itself, before
   joining the caller's row; once joined, every open row has everything
   the caller uses. Only if there's none, which happens when the callee is
   in [f]'s group and its uses were found at the join, is it the first
   call whose row has it now. For the program's `main` ([main]), one the
   runtime doesn't install is left to infer_top.ml's [check_main]: adding
   it to `uses` wouldn't help. *)
let check_uses env ~is_value ~withheld ~main (f : fn_def) cx declared =
  let pos (l : Loc.t) = (l.start.line, l.start.col) in
  let calls =
    List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !(cx.calls)
  in
  (* where it's first used, and what that is *)
  let first has = List.find_opt has calls in
  List.iter
    (fun (dep : label) ->
      if
        not
          (has_dep declared dep
          || (main && not (runtime_dep (Ty.dep_path dep.name))))
      then
        let call =
          match first (fun c -> brings c dep) with
          | Some c -> Some c
          | None -> first (fun c -> has_label c.row dep)
        in
        let why = withheld_notes withheld dep call in
        (* a spawn uses `Async`, which a reader may not expect: it waits
           while its scope is full (compiler.md, "Stage 11a", "The two
           holes") *)
        let notes =
          match call with
          | Some { callee = Some p; _ }
            when p.home = Path.prelude_home && p.name = "Scope"
                 && dep.name = Ty.dep_label (Path.prelude "Async") ->
              [
                Printf.sprintf
                  "`s.%s` waits while its scope is full, so it uses `Async`"
                  (Path.short p);
              ]
          | _ -> []
        in
        let op = Option.bind call (fun c -> c.op) in
        let call =
          Option.map
            (fun c -> (c.cloc, if c.needs then Installing else Call_uses))
            call
        in
        (* an alias it declares of this very instance, which is a
           dependency of its own: `uses Jobs` isn't `uses Chan<Job>` *)
        let alias =
          List.find_map
            (fun (d : label) ->
              match
                Iface.alias_of (Hashtbl.find_opt env.types) (Ty.dep_path d.name)
              with
              | Some t
                when Ty.dep_label t.dpath = dep.name
                     && List.length t.dargs = List.length dep.payload
                     && List.for_all2
                          (fun a b ->
                            same_ty
                              (of_ty
                                 ~vars:(fun _ -> TError)
                                 ~tails:(fun _ -> REmpty)
                                 a)
                              b)
                          t.dargs dep.payload ->
                  Some (shown_dep env d, op)
              | _ -> None)
            declared
        in
        let shown = shown_dep env dep in
        report env
          (match Resolve.checked_wiring (Ast.fn_path env.home f) with
          | Some wiring ->
              (* a public wiring's `uses` (resolve.ml, [wiring_fns]): the
                 item that needs it, as the wiring writes it *)
              let item =
                Option.bind
                  (match first (fun c -> brings c dep) with
                  | Some c -> Some c
                  | None -> first (fun c -> has_label c.row dep))
                  (fun c ->
                    Option.map (fun (_, text) -> (c.cloc, text)) (wired_need env c))
              in
              wiring_undeclared f.name.loc ~wiring ~dep:shown ~call:item
                ~written:
                  (match f.uses with Some u -> u.deps <> [] | None -> false)
          | None when Resolve.service_member (Ast.fn_path env.home f) <> None ->
              (* a service's `uses` (resolve.ml, [service_items]) *)
              service_undeclared f
                ~service:(Option.get (Resolve.service_member (Ast.fn_path env.home f)))
                shown call
          | None when is_value f -> value_uses f shown call
          | None -> undeclared_use ~why ~notes ?alias f shown call))
    (sorted_labels cx.uses)

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
      match List.find_opt (fun c -> brings c dep) calls with
      | Some c -> Some c
      | None -> List.find_opt (fun c -> has_label c.row dep) calls
    in
    Option.map
      (fun c -> (c.cloc, if c.needs then Installing else Call_uses))
      call
  in
  (* what it implements, by name: a handler for `Log<T>` can't use any
     `Log` itself *)
  let own =
    List.map
      (fun (d : Ty.dep) -> Ty.dep_label d.dpath)
      (Option.value (Iface.handler_deps f) ~default:[])
  in
  let written =
    match f.body.kind with Handler { needs; _ } -> needs <> None | _ -> false
  in
  List.iter
    (fun (dep : label) ->
      let shown = shown_dep env dep in
      let over = List.exists (fun (l : label) -> l.name = dep.name) n.nover in
      if over then
        (* what it goes over it needs, and reaches with `next`: a call of
           the dependency itself would reach this handler *)
        match List.find_opt (fun c -> brings c dep) calls with
        | Some c ->
            (* the call to write instead: `next(A).get` if another
               dependency it goes over has a `get` too *)
            let next =
              Option.map
                (fun op ->
                  let has p =
                    match Hashtbl.find_opt env.types p with
                    | Some { Iface.body = Dep fs; _ } ->
                        List.exists (fun (d : Iface.field) -> d.fname = op) fs
                    | _ -> false
                  in
                  let deps =
                    Ty.dep_paths
                      (Option.value (Iface.handler_deps f) ~default:[])
                  in
                  ( (if List.length (List.filter has deps) > 1 then
                       sprintf "next(%s).%s" shown op
                     else "next." ^ op),
                    sprintf "%s.%s" shown op ))
                c.op
            in
            report env
              (handler_uses_itself f shown ~over:true ?next
                 (Some (c.cloc, if c.needs then Installing else Call_uses)))
        | None -> ()
      else if List.mem dep.name own then
        report env (handler_uses_itself f shown ~over:false (call_of dep))
      else
        match n.ndeclared with
        | Some _ when Resolve.service_handler (Ast.fn_path env.home f) ->
            (* a service's arms only call its members, each checked
               against the service's `uses` already, where the need is
               reported at the call that brings it in *)
            ()
        | Some declared when not (has_dep declared dep) ->
            report env (undeclared_need ~written f shown (call_of dep))
        | _ -> ())
    (sorted_labels n.nrow);
  if n.ndeclared <> None then close_row n.nrow;
  (* what its state and `finally` fail with is all it fails to start with *)
  if row_skolem n.nfails = None then close_row n.nfails

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
    | Passed c when c.einstall -> Install_fails
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
          (match Resolve.checked_wiring (Ast.fn_path env.home f) with
          | Some wiring ->
              (* a public wiring's `!` (resolve.ml, [wiring_fns]) *)
              wiring_undeclared_error f.name.loc ~wiring
                ~tag:(show_label pr l)
          | None when is_value f ->
              value_fails f ~tag:l.name ~shape:(show_label pr l) from
          | None -> undeclared_error f ~tag:l.name ~shape:(show_label pr l) from))
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

(* A public function's uses stay open, as its interface says: a caller
   adds them to its own. A transparent parameter of a dependency's type
   needs them, so if the body keeps one where what it needs is closed,
   `Box<Clock>`, the function's uses close with it, and the interface
   would be wrong about what the parameter may need. That's reported at
   the parameter. [cx] is what checking [f]'s body found. *)
let check_open_rows env (f : fn_def) cx =
  let uses_closed =
    Option.bind f.uses (fun (u : Resolved.uses) -> u.dtail) = None
    && row_end cx.uses = REmpty
  in
  let blamed =
    List.find_map
      (fun (p : Resolved.param) ->
        match p.pty with
        | Some (TyImpl { impl_deps = ds; impl_uses = None; _ }) when uses_closed
          ->
            let written =
              List.map
                (fun (d : tname dep_ref) ->
                  match d.dep.tref with Named p -> env.names p | Param _ -> "")
                ds
            in
            Some (p, String.concat " & " written)
        | _ -> None)
      f.params
  in
  match blamed with
  | None -> ()
  | Some (p, d) ->
      let name = p.pname.ident.name in
      let kept = if name = "self" then Dep_self d else Dep_param d in
      report env
        (kept_needing_nothing p.pname.ident.loc ~name ~fn:(Ast.fn_name f) kept)

(* Once the group is done, and the uses of named rows have ended the rows
   they're added to (solve.ml), a function that names its own, `uses ..d`
   or `! ..e`, ends its own in it. One that declares what it fails with,
   but not a named row a call of a closure it was passed fails with, is
   reported. [c] is the function, with what checking it found, and
   [is_value] says whether a function is an associated value. *)
let own_rows env ~is_value c =
  let f = c.ffn and cx = c.fcx in
  let own_tail (es : Resolved.errors option) =
    Option.map
      (fun (n : ident) -> n.name)
      (Option.bind es (fun (es : Resolved.errors) -> es.etail))
  and own_dtail (u : Resolved.uses option) =
    Option.map
      (fun (n : ident) -> n.name)
      (Option.bind u (fun (u : Resolved.uses) -> u.dtail))
  in
  let named n =
    match List.assoc_opt n cx.named with
    | Some (RSkol (id, n)) -> Some (id, n)
    | _ -> None
  in
  (match Option.bind (own_dtail f.uses) named with
  | Some (id, n) -> (
      match row_end cx.uses with
      | RVar _ as t ->
          (* a variable still unbound takes any row, so this can't fail *)
          Unify.unify_row env.st t (RSkol (id, n))
      | _ -> ())
  | None -> ());
  let errors = declared_errors env ~is_value ~tparams:cx.tparams f <> None in
  let declared = own_tail f.errors in
  match row_end cx.errs with
  | RSkol (id, n) when errors && declared <> Some n ->
      (* a call of a closure it was passed, which fails with [..n] *)
      let from =
        List.find_map
          (function
            | Passed c when row_tail c.erow = Some id -> Some c.eloc | _ -> None)
          (Option.fold ~none:[] ~some:( ! ) cx.sources)
      in
      report env
        (named_errors_undeclared
           (Option.value from ~default:f.name.loc)
           n ~fn:(Ast.fn_name f))
  | _ -> ()

(* A function that names its own errors' row, `! ..e`, fails with that
   row: its calls of itself do, and a call of a closure that fails with
   [..e] passes on what it can. That's known before the group's markers
   are checked, which need it, and its labels are all there by then. *)
let own_errors env c =
  match
    ( Option.bind c.ffn.errors (fun (es : Resolved.errors) -> es.etail),
      row_end c.fcx.errs )
  with
  | Some (n : ident), (RVar _ as tail) -> (
      match List.assoc_opt n.name c.fcx.named with
      | Some r ->
          (* a variable still unbound takes any row, so this can't fail *)
          Unify.unify_row env.st tail r
      | None -> ())
  | _ -> ()

(* ---- all of it ---- *)

(* The function [c] does what it declares, once its group is solved: it
   uses no more than it declares, a public one's transparent parameters
   keep their rows open, a handler needs no more than it declares
   ([needs] are the group's handlers'), and it fails with exactly what it
   declares, and is seen as failing with that from then on. [withheld]
   says why a function still gets a dependency from outside. *)
let check_declared env ~is_value ~withheld ~needs c =
  let f = c.ffn and cx = c.fcx in
  let path = Ast.fn_path env.home f in
  Option.iter
    (check_uses env ~is_value ~withheld ~main:c.fmain f cx)
    (declared_uses env ~is_value ~tparams:cx.tparams ~named:cx.named f);
  if f.pub && not (is_value f) then check_open_rows env f cx;
  List.iter (fun n -> if n.nself = path then check_needs env f n) needs;
  Option.iter
    (fun declared ->
      check_errors env ~is_value f cx declared;
      as_declared env path cx declared)
    (declared_errors env ~is_value ~tparams:cx.tparams f)
