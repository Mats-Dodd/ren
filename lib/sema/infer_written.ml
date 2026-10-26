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
        written = None;
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

let written_uses ~named (u : Resolved.uses) =
  extend
    (List.map dep
       (List.map (fun (l : Ty.label) -> l.name) (Iface.dep_labels u.deps)))
    (named_row ~named u.dtail)

(* Turn a written type into a checker type. [tvars] are what the type
   parameters in scope stand for, in order, and [named] the rows the
   function's signature names (`..d`, ast.ml). [row] makes the rows of
   written function types and implementations that aren't written: fresh
   variables in parameters (a parameter `f: fn()` passes its dependencies
   through to the caller), closed in declarations and return types (a
   stored `fn()` uses nothing). A function type that writes what it fails
   with or uses, `fn() ! Bad` or `fn() uses Clock`, does just that, and one
   that names a row, `fn() uses ..d`, is a closure that's kept: what it
   doesn't write, it doesn't do. *)
let rec convert env ~tvars ?(named = []) ~row (t : Resolved.ty) =
  let go = convert env ~tvars ~named ~row in
  match t with
  | TyName ({ tref = Param i; _ }, _) -> List.nth tvars i
  | TyName ({ tref = Named p; _ }, args) -> TCon (p, List.map go args)
  | TyImpl ({ tref = Named p; _ }, u, _) ->
      TCon
        ( p,
          [
            TUses
              (match u with Some u -> written_uses ~named u | None -> row ());
          ] )
  | TyImpl ({ tref = Param _; _ }, _, _) ->
      (* resolve.ml only makes a dependency a [TyImpl] *)
      assert false
  | TyFn (ps, ret, errs, u, _) ->
      let row = if names_row t then closed else row in
      let go = convert env ~tvars ~named ~row in
      let ret = match ret with Some r -> go r | None -> unit in
      let errs =
        match errs with
        | Some es ->
            extend (error_labels env ~tvars es) (named_row ~named es.etail)
        | None -> row ()
      in
      let uses =
        match u with Some u -> written_uses ~named u | None -> row ()
      in
      TFun (List.map (convert_param env ~tvars ~named ~row) ps, ret, errs, uses)
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false
  | TyErrors es ->
      TErrors (extend (error_labels env ~tvars es) (named_row ~named es.etail))

and convert_param env ~tvars ~named ~row = function
  | TyInout (t, _) -> { mode = Inout; ty = convert env ~tvars ~named ~row t }
  | t -> read (convert env ~tvars ~named ~row t)

and closed () = REmpty

(* A parameter's type: as written, or a fresh variable. [own] are the
   rows a transparent parameter of a top-level function gets: a parameter
   written `fn(...)` is transparent, so what it uses is exactly what its
   function does, and what it fails with is too, once a `try` passes it on
   (infer_top.ml).

   A top-level function's signature is read exactly as its interface reads
   it (Iface.signature), so the body is checked against the type other
   modules will see: any other function type in its parameters, like the
   `fn()` in `f: fn(fn()) -> Int` or in `f: Option<fn()>`, is closed, as it
   is in a declaration. With open rows there, the body could widen them, and
   its type would no longer be the one its signature states. A lambda's
   parameters, which no interface shows, get fresh rows instead.

   A parameter that writes what it fails with, `f: fn() ! Bad`, fails with
   just that, so only its dependencies are its function's; one that writes
   what it uses, `f: fn() uses Clock`, uses just that; and one that names
   a row, `f: fn() uses ..d`, is kept, not only called, so neither of its
   rows is its function's. A parameter of a dependency's type, `c: Clock`,
   is transparent too: what it needs is what its function uses (deps.md,
   "Implementations"). [named] are the rows the signature names. *)
let param_type env ~tparams ?(named = []) ?own (p : Resolved.param) =
  let t =
    match (p.pty, own) with
    | Some (TyFn (_, _, written_e, written_u, _) as t), Some (errs, uses)
      when not (names_row t) -> (
        match convert env ~tvars:tparams ~named ~row:closed t with
        | TFun (ps, ret, e, u) ->
            TFun
              ( ps,
                ret,
                (if written_e = None then errs else e),
                if written_u = None then uses else u )
        | _ -> assert false)
    | Some (TyImpl ({ tref = Named d; _ }, None, _)), Some (_, uses) ->
        TCon (d, [ TUses uses ])
    | Some t, Some _ -> convert env ~tvars:tparams ~named ~row:closed t
    | Some t, None ->
        convert env ~tvars:tparams ~named ~row:(fun () -> fresh_row env.st) t
    | None, _ -> fresh_var env.st
  in
  { mode = p.pmode; ty = t }

let result_path = Path.prelude "Result"
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
  | Dep _ | Handler _ ->
      (* an implementation, or a handler, which needs whatever its
         operations use *)
      (TCon (td.path, [ TUses (fresh_row env.st) ]), tvars)
  | Record _ | Sum _ | Builtin | Opaque _ | Errors _ ->
      (TCon (td.path, tvars), tvars)

(* A field's type, given what the type's parameters stand for. A function
   type written in a declaration uses and fails with nothing. *)
let field_type ~tvars (f : Iface.field) =
  of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty) f.fty
