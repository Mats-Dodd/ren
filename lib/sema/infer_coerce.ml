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

(* A handler of several dependencies' type: that handler, its
   dependencies, and what it needs. *)
let handler_of env t =
  match repr t with
  | TCon (h, [ TUses needs ]) -> (
      match Hashtbl.find_opt env.types h with
      | Some { body = Handler deps; _ } -> Some (h, deps, needs)
      | _ -> None)
  | _ -> None

(* If [t] is a variable that a handler of several dependencies was given
   to, and nothing has said what it is since: that handler, its
   dependencies, and what it needs. The first handler given to it is the
   one, as for [settle]. With [said], also if something has said it's one
   of those dependencies since, but the solver hasn't taken the handler
   as it yet. *)
let given ?(said = false) env t =
  let t = repr t in
  match t with
  | TVar _ ->
      (* the variable's watch knows (Unify.watch), so a value used many
         times costs no more each time *)
      Option.bind (Unify.first_given env.st t) (handler_of env)
  | TCon (d, [ TUses _ ]) when said ->
      (* this looks through the group's constraints, for a coercion of a
         variable that has become [t], which [==] says is the same type in
         memory. Only a value taken as two dependencies gets here, which is
         an error, so it's looked for once for each error *)
      List.find_map
        (function
          | Coerce { cwanted; cfound; _ } when repr cwanted == t -> (
              match handler_of env cfound with
              | Some (h, deps, needs) when List.mem d deps ->
                  Some (h, deps, needs)
              | _ -> None)
          | _ -> None)
        (List.rev env.pending)
  | _ -> None

(* The same, without the handler. *)
let pending env t =
  Option.map (fun (_, deps, needs) -> (deps, needs)) (given env t)

(* The type [e], of type [t], has where a value of type [expected] is
   wanted, which is known, explained with [why]: [as_one]'s, which
   lowering is told, or [t]. If [t] is a variable a handler of several
   dependencies was given to, and one of them is wanted, it's that one
   here, needing what the handler needs, and what it needs is then copied
   where it's passed, as for a handler whose type was known
   (Infer_rows.widen). The variable itself is left open: another use of
   the same value can take it as another of the handler's dependencies, or
   install them all with `with`. Whether [e] is taken as that one, or is
   it already, or can't be, is decided by the solver once the variable is
   ([coerce]), which comes after, since the handler was given to it
   first. That's so, too, if something has already said it's another of
   them, so the message is the same whichever came first. Unified with
   what's wanted as it is, the variable would need what the parameter's
   function uses, and in a `with` of it, around the call, that's what the
   `with`'s body uses. *)
let taken_as env cx why (e : expr) t expected =
  match as_one env t expected with
  | Some (d, one) ->
      Hashtbl.replace cx.as_dep e.node d;
      one
  | None -> (
      (* only a variable a handler was given to, or another dependency
         something said it was, can be one, where a dependency is wanted;
         [given] is looked for only then, since it looks through the
         group's constraints *)
      let wanted = reveal env.st expected in
      let handler =
        match (repr t, wanted) with
        | TVar _, TCon (_, [ TUses _ ]) -> given ~said:true env t
        | TCon (o, [ TUses _ ]), TCon (d, [ TUses _ ]) when o <> d ->
            given ~said:true env t
        | _ -> None
      in
      match (handler, wanted) with
      | Some (h, deps, needs), TCon (d, [ TUses _ ]) when List.mem d deps ->
          let one = TCon (d, [ TUses needs ]) in
          defer env
            (Coerce
               {
                 cvalue = e;
                 cfound = t;
                 cwanted = one;
                 cwhy = why;
                 cas_dep = cx.as_dep;
                 cof = Some h;
               });
          one
      | _ -> t)

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
  | Error failure -> (
      let report behind =
        mismatch env k.cwhy (result_loc k.cvalue) ~behind ~found:(c.ty found)
          ~expected:(c.ty k.cwanted) failure
      in
      match (k.cof, repr found) with
      | None, _ -> report []
      | Some h, TCon (other, [ TUses _ ]) -> (
          match Hashtbl.find_opt env.types h with
          | Some { body = Handler deps; _ } when List.mem other deps ->
              (* something else took the value as another of the
                 handler's dependencies *)
              report
                [
                  Taken_elsewhere
                    {
                      handler = type_name env h;
                      deps = List.map (type_name env) deps;
                      other = type_name env other;
                    };
                ]
          | _ ->
              (* another handler given to the variable too, which the
                 variable's own coercion, decided first, reported *)
              ())
      | Some _, _ ->
          (* the variable became what no handler is, which was reported
             where that was said (Unify.watch) *)
          ())

(* [e], of type [t], is given where a value of type [expected] is wanted,
   explained with [why]: unify the two, with [e] taken as one dependency
   if it's a handler of several and one of theirs is wanted. If what's
   wanted isn't known yet, that's left to the solver. *)
let give env cx why (e : expr) t expected =
  match reveal env.st expected with
  | TVar _ when several env t ->
      (match repr t with
      | TCon (h, _) -> (
          match Hashtbl.find_opt env.types h with
          | Some { body = Handler deps; _ } ->
              Unify.watch env.st expected ~handler:t (h :: deps)
          | _ -> ())
      | _ -> ());
      defer env
        (Coerce
           {
             cvalue = e;
             cfound = t;
             cwanted = expected;
             cwhy = why;
             cas_dep = cx.as_dep;
             cof = None;
           })
  | _ ->
      ignore
        (unifies env why (result_loc e)
           ~found:(taken_as env cx why e t expected)
           ~expected)

(* What [t] is, where it's about to be looked into: if it's a variable
   that a handler of several dependencies was given to, and nothing has
   said what it is since, that handler's type (Infer_report.settle), so
   whatever is about to be done with it can be. Its coercion is left to
   the solver, which then finds it's that already. *)
let settle env t =
  match Unify.first_given env.st t with
  | Some handler ->
      (* a variable still unbound takes any type that doesn't hold it, and
         a handler's type holds only what it needs *)
      Unify.unify env.st t handler
  | None -> ()

(* The same as [settle], where a member or a field is about to be looked
   up in [t]: if just one of the handler's dependencies has it, [has] says,
   it's that one that's wanted, since the handler's own type has neither
   and the others don't have this one. Then whatever says what's wanted,
   before or after, has to agree. *)
let settle_for_member env t ~has =
  match pending env t with
  | Some (deps, needs) -> (
      match List.filter (fun d -> has (TCon (d, [ TUses needs ]))) deps with
      | [ d ] ->
          (* a variable still unbound takes any type that doesn't hold it *)
          Unify.unify env.st t (TCon (d, [ TUses needs ]))
      | _ -> settle env t)
  | None -> settle env t

(* What a `with` of a handler given before what's wanted was known
   installs, now that that's decided ([coerce]): just the one of its
   dependencies it's taken as, or else all of them. Lowering is told
   which, and each of the `with`s [o.owiths] knows if it installs. *)
let installs (o : install_one_of) =
  Hashtbl.replace o.ofound o.onode
    (match repr o.oty with
    | TCon (d, _) when List.mem d o.odeps -> Installs d
    | _ -> Installs_handler o.odeps);
  List.map
    (fun (d, w) -> { w with winstalls = installs_dep o.oty o.odeps d })
    o.owiths
