(* Types as a module writes them, turned into the checker's types (see
   infer_expr.ml): annotations, parameters and signatures, and a type
   declaration's fields, at fresh types for its parameters. *)

open Ast
open Types
open Infer_env

(* The labels of a written error set, after `!`: each named set
   expanded, and each payload's type a checker type. [tvars] are what the
   type parameters in scope stand for. *)
let error_labels env ~tvars (es : Resolved.errors) =
  List.map
    (fun (l : Ty.label) ->
      {
        name = l.name;
        payload =
          List.map
            (of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty))
            l.payload;
        dep = false;
        written = unmarked ();
      })
    (Iface.of_errors ~sets:env.sets es)

(* The row a written `uses` lists, ending in the row it names, if it
   names one: one of [named], the rows the signature names, as [RSkol]s. *)
let named_row ~named (n : ident option) =
  match n with
  | Some n -> (
      match List.assoc_opt n.name named with
      | Some r -> r
      | None -> REmpty (* resolve.ml reported it *))
  | None -> REmpty

(* The dependencies a `uses` lists or an implementation's type joins, with
   their type arguments as checker types. *)
let written_deps env ~tvars (ds : tname dep_ref list) =
  List.map
    (fun (d : Ty.dep) ->
      {
        dpath = d.dpath;
        dargs =
          List.map
            (of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty))
            d.dargs;
      })
    (Iface.deps_of ~sets:env.sets ds)

let written_uses env ~tvars ~named (u : Resolved.uses) =
  let rec once = function
    | [] -> []
    | l :: rest -> l :: once (List.filter (fun k -> not (same_label k l)) rest)
  in
  extend
    (once (List.map dep_of (written_deps env ~tvars u.deps)))
    (named_row ~named u.dtail)

(* Turn a written type into a checker type. [tvars] are what the type
   parameters in scope stand for, in order, and [named] the rows the
   function's signature names (`..d`, ast.ml). [row] makes the rows of
   written function types' errors and implementations' needs that aren't
   written: fresh variables in a lambda's parameters, closed elsewhere, as
   in a dependency's operation. A function type uses just what it lists,
   none if it lists none: those are what its callee provides, and a block
   finds any other where it's written (foundations.md, decision 5). One
   that writes what it fails with, `fn() ! Bad`, does just that. *)
let rec convert env ~tvars ?(named = []) ~row (t : Resolved.ty) =
  let go = convert env ~tvars ~named ~row in
  match t with
  | TyName ({ tref = Param i; _ }, _) -> List.nth tvars i
  | TyName ({ tref = Named p; _ }, args) -> TCon (p, List.map go args)
  | TyImpl { impl_deps = ds; impl_over = over; impl_errors; impl_uses; _ } ->
      let deps = written_deps env ~tvars ds in
      (* what it can fail to start with is what's written, or nothing *)
      let fails =
        match impl_errors with
        | Some es ->
            extend (error_labels env ~tvars es) (named_row ~named es.etail)
        | None -> REmpty
      in
      impl_type ~over ~fails deps
        (match impl_uses with
        | Some u ->
            (* one over a dependency needs it too, the one under it *)
            let extra =
              if over then
                List.filter
                  (fun (d : tname dep_ref) ->
                    not
                      (List.mem d.dep.tref
                         (List.map
                            (fun (u : tname dep_ref) -> u.dep.tref)
                            u.deps)))
                  ds
              else []
            in
            written_uses env ~tvars ~named { u with deps = u.deps @ extra }
        | None when over ->
            (* it needs the one under it *)
            extend (List.map dep_of deps) (row ())
        | None -> row ())
  | TyFn (ps, ret, errs, u, _) ->
      let ret = match ret with Some r -> go r | None -> unit in
      let errs =
        match errs with
        | Some es ->
            extend (error_labels env ~tvars es) (named_row ~named es.etail)
        | None -> row ()
      in
      let uses =
        match u with
        | Some u -> written_uses env ~tvars ~named u
        | None -> REmpty
      in
      TFun (List.map (convert_param env ~tvars ~named ~row) ps, ret, errs, uses)
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false
  | TyErrors es ->
      TErrors (extend (error_labels env ~tvars es) (named_row ~named es.etail))
  | TyTuple (ts, _) -> TCon (Ty.tuple_path (List.length ts), List.map go ts)

and convert_param env ~tvars ~named ~row = function
  | TyInout (t, _) -> { mode = Inout; ty = convert env ~tvars ~named ~row t }
  | t -> read (convert env ~tvars ~named ~row t)

and closed () = REmpty

(* A parameter's type: as written, or a fresh variable. [own] are the
   rows a transparent parameter of a top-level function gets: a parameter
   written `fn(...)` is a block, which fails with what its function does,
   once a `try` passes it on (infer_top.ml), and uses exactly the
   dependencies its type lists, which its function provides: none, if it
   lists none.

   A top-level function's signature is read exactly as its interface reads
   it (Iface.signature), so the body is checked against the type other
   modules will see: any other function type in its parameters, like the
   `fn()` in `f: fn(fn()) -> Int` or in `f: Option<fn()>`, is closed, as it
   is in a declaration. With open rows there, the body could widen them, and
   its type would no longer be the one its signature states. A lambda's
   parameters, which no interface shows, get fresh rows instead.

   A parameter that writes what it fails with, `f: fn() ! Bad`, fails with
   just that. A block's type never names a row (resolve.ml). A parameter
   of a dependency's type, `c: Clock`, is transparent: what it needs is
   what its function uses (deps.md, "Implementations"). [named] are the
   rows the signature names. *)
let param_type env ~tparams ?(named = []) ?own ?(closed_block = false)
    (p : Resolved.param) =
  (* a block that can't fail: a spawned one, or one of `Async.race`'s
     (Iface.closed_blocks) *)
  let cant_fail = closed_block || p.pblock = Spawned in
  let t =
    match (p.pty, own) with
    | Some (TyFn (_, _, written_e, _, _) as t), Some (errs, _) -> (
        match convert env ~tvars:tparams ~named ~row:closed t with
        | TFun (ps, ret, e, u) ->
            TFun (ps, ret, (if written_e = None && not cant_fail then errs else e), u)
        | _ -> assert false)
    | ( Some
          (TyImpl
             {
               impl_deps = ds;
               impl_over = over;
               impl_uses = None;
               impl_errors;
               _;
             }),
        Some (_, uses) ) ->
        (* a transparent one: it needs what its function uses, and can fail
           to start with what's written, if anything. One that goes over
           its dependencies needs them too, as Iface.over_needs says, met
           by what it's installed over, not by its function's caller *)
        let deps = written_deps env ~tvars:tparams ds in
        let fails =
          match impl_errors with
          | Some _ -> (
              match
                convert env ~tvars:tparams ~named ~row:closed (Option.get p.pty)
              with
              | TImpl i -> i.fails
              | _ -> REmpty)
          | None -> REmpty
        in
        let needs = if over then extend (List.map dep_of deps) uses else uses in
        impl_type ~over ~fails deps needs
    | Some t, Some _ -> convert env ~tvars:tparams ~named ~row:closed t
    | Some t, None ->
        convert env ~tvars:tparams ~named ~row:(fun () -> fresh_row env.st) t
    | None, _ -> fresh_var env.st
  in
  { mode = p.pmode; ty = t }

let result_path = Path.prelude "Result"

(* The prelude's `Tags`, a set of error tags given by name at a call
   (compiler.md, "`over any` and `retry`"). *)
let tags_path = Path.prelude "Tags"
let option_path = Path.prelude "Option"

(* Fresh variables for a type declaration's parameters: `Option<T>` used
   once can be an `Option<Int>`, and elsewhere an `Option<Bool>`. *)
let instance env (td : Iface.type_decl) =
  let tvars = List.map (fun _ -> fresh_var env.st) td.params in
  (* a [Result]'s second argument is always an error set *)
  let tvars =
    if td.path = result_path then
      List.mapi
        (fun i t -> if i = 1 then TErrors (fresh_row env.st) else t)
        tvars
    else tvars
  in
  match td.body with
  | Dep _ | Dep_alias _ ->
      (* an implementation, which needs whatever its operations use *)
      ( impl_type [ { dpath = td.path; dargs = tvars } ] (fresh_row env.st),
        tvars )
  | Record _ | Sum _ | Builtin | Opaque _ | Errors _ ->
      (TCon (td.path, tvars), tvars)

(* Whether [t], the type of a parameter or a field as it was made from a
   declaration or a scheme, is written there: not a variable, which stands
   for a type inference finds, a generic one's or one nothing wrote. Only
   a written type narrows an implementation of several dependencies to
   some of them (Infer_expr.narrow). The variable itself is looked at, not
   what it's been linked to: a generic's `T` that an earlier argument
   solved still isn't written. *)
let is_written t = match t with TVar _ -> false | _ -> true

(* Which of [ps], the parameters of a call's callee, of type [tf], have a
   type written: the callee's type isn't a variable, nor is the
   parameter's, and if it's one of the module's functions, [callee], its
   declaration writes that parameter's type ([env.written]), which a
   scheme alone doesn't say. [skip] are the parameters before [ps] that
   aren't among them, a method's `self`. *)
let written_params env ?callee ?(skip = 0) tf (ps : param list) =
  let declared i =
    match Option.bind callee (Hashtbl.find_opt env.written) with
    | Some ws -> Option.value (List.nth_opt ws (i + skip)) ~default:false
    | None -> true
  in
  List.mapi
    (fun i (p : param) -> is_written tf && declared i && is_written p.ty)
    ps

(* A field's type, given what the type's parameters stand for. A function
   type written in a declaration uses and fails with nothing. *)
let field_type ~tvars (f : Iface.field) =
  of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty) f.fty
