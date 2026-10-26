(* A handler of several dependencies taken as one of them (deps.md,
   "Implementations"): `test_clock(t)`, a handler for `Clock, TestClock`,
   given where a `Clock` is wanted, describes an implementation of
   `Clock`. Which it's taken as depends on the type wanted, so when that
   isn't known yet as the value is made, it's decided once it is, by the
   constraint solver: then it doesn't matter whether the value comes
   before what says what's wanted or after it, `same(test_clock(t), c)` or
   `same(c, test_clock(t))`. *)

open Ast.Resolved
open Types
open Infer_env
open Infer_report

(* Whether [t] is a handler of several dependencies' own type, named after
   it (Iface.handler_type). *)
let several env t =
  match repr t with
  | TCon (h, [ TUses _ ]) -> (
      match Hashtbl.find_opt env.types h with
      | Some { body = Handler _; _ } -> true
      | _ -> false)
  | _ -> false

(* A value of type [t] taken as one of type [expected]: a handler of
   several dependencies, where a value of one of their types is wanted,
   describes an implementation of that one, which needs what the handler
   does. Its type is then that dependency's, and installing it installs
   only that one. The dependency and that type, if it's taken as one. *)
let as_one env t expected =
  match (repr t, reveal env.st expected) with
  | TCon (h, [ TUses needs ]), TCon (d, [ TUses _ ]) -> (
      match Hashtbl.find_opt env.types h with
      | Some { body = Handler deps; _ } when List.mem d deps ->
          Some (d, TCon (d, [ TUses needs ]))
      | _ -> None)
  | _ -> None

(* The type [e], of type [t], has where a value of type [expected] is
   wanted, which is known: [as_one]'s, which lowering is told, or [t]. *)
let taken_as env cx (e : expr) t expected =
  match as_one env t expected with
  | Some (d, one) ->
      Hashtbl.replace cx.as_dep e.node d;
      one
  | None -> t

(* Decide the coercion [k] (see [Infer_env.coerce]), now that what's
   wanted is known, or will never be: a value of a type still unknown is
   the handler's own. Tried on copies first, so if it fails, that's
   reported, and nothing changes. *)
let coerce env k =
  let found =
    match as_one env k.cfound k.cwanted with
    | Some (d, one) ->
        Hashtbl.replace k.cas_dep k.cvalue.node d;
        one
    | None -> k.cfound
  in
  let c = Unify.copier () in
  match
    Unify.atomically env.st c (fun st (c : Unify.copy) ->
        Unify.unify st (c.ty found) (c.ty k.cwanted))
  with
  | Ok () -> ()
  | Error failure ->
      mismatch env k.cwhy (result_loc k.cvalue) ~found:(c.ty found)
        ~expected:(c.ty k.cwanted) failure

(* [e], of type [t], is given where a value of type [expected] is wanted,
   explained with [why]: unify the two, with [e] taken as one dependency
   if it's a handler of several and one of theirs is wanted. If what's
   wanted isn't known yet, that's left to the solver. *)
let give env cx why (e : expr) t expected =
  match reveal env.st expected with
  | TVar _ when several env t ->
      defer env
        (Coerce
           {
             cvalue = e;
             cfound = t;
             cwanted = expected;
             cwhy = why;
             cas_dep = cx.as_dep;
           })
  | _ ->
      ignore
        (unifies env why (result_loc e)
           ~found:(taken_as env cx e t expected)
           ~expected)

(* What [t] is, where it's about to be looked into: if it's a variable
   that a handler of several dependencies was given to, and nothing has
   said what it is since, that handler's type (Infer_report.settle), so
   whatever is about to be done with it can be. *)
let settle env t =
  match repr t with
  | TVar v -> Infer_report.settle env (fun v' -> v' == v)
  | _ -> ()
