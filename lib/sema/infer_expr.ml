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

(* What a lookup through a type found. *)
type found =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string  (** a constructor: its type, and its name *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)
  | Installs of Path.t
      (** a `with` whose item is an implementation of this dependency *)
  | Installs_handler of Path.t list
      (** a `with` whose item describes a handler of these dependencies, which
          it makes an instance of *)
  | Wraps  (** a `with` whose item is a wrapper, which its body is passed to *)

(* A call that adds to a function's dependencies, or a `with` that
   installs an implementation, which adds what it needs. [own] are the
   labels the callee's row had just before the call joined it to the
   caller's: what the callee brings in itself. After the join the two rows
   are one, so [row] then also has everything the caller uses. [needs]
   says it's a `with`. *)
type call = {
  cloc : Loc.t;
  own : string list;
  row : row;
  needs : bool;
  callee : Path.t option;  (** the top-level function called, if it's one *)
}

type env = {
  st : Types.state;
  sink : Diag.sink;
  home : string;  (** the module being checked *)
  names : Path.t -> string;
      (** how the module writes each type's name (Resolve.type_name) *)
  can_name : Path.t -> bool;
      (** whether the module can write a type's name at all (Resolve.can_name)
      *)
  source : expr -> string option;
      (** code as the module writes it, for a help that shows it (Ast.source) *)
  types : (Path.t, Iface.type_decl) Hashtbl.t;
      (** every type the module can meet: its own, and the public types of every
          module reachable through its imports (iface.ml) *)
  sets : Iface.sets;  (** the named error sets among them *)
  visible : Iface.type_decl list;
      (** the types it can name bare, sorted by name, which is the order an
          error lists them in: its own, those imported by name, and the
          prelude's *)
  globals : (Path.t, ty) Hashtbl.t;
      (** top-level functions: a type scheme once their group is done *)
  mutable group : (Path.t * (unit -> ty)) list;
      (** the functions of the group being checked, each with a way to make the
          type its declaration gives it *)
  mutable spelled : Path.t list;
      (** those of [group] whose signature is written out in full, every
          parameter's type included: public functions, mostly *)
  mutable joins : join list;  (** most recent first *)
  mutable drops : drop list;
      (** the values the group's statements throw away, most recent first *)
  mutable forced : (Path.t * Loc.t) list;
      (** each statement that threw away a value of a type still unknown, which
          made it `Unit`, with the function it's in: a later mismatch at a call
          of that function points back at it *)
  mutable unmarked : (ecall * row) list;
      (** the group's calls that no marker covers, each with the row its errors
          went to, which has to end up empty *)
  mutable all_markers : marker list;
      (** the group's `try`s, `attempt`s and `match`es with `fail` arms *)
  mutable kept : (row * (string * ty) list) list;
      (** the errors each `attempt` of the group keeps in its [Result], and each
          `match` with `fail` arms handles, each with the parameters of the
          function and lambdas it's in *)
  mutable includes : inclusion list;
      (** each place the group adds one row of errors to another, most recent
          first, finished once the group is done (see [inclusion]) *)
  mutable tag_patterns : tag_pattern list;
      (** tags matched in an error set that was still open *)
  mutable rows_due : row_due list;
      (** the group's uses of a named row (see [row_due]) *)
  mutable impl_ops : impl_op list;
      (** the group's implementations' operations, whose errors are checked once
          it's done (see [impl_op]) *)
  mutable installs : install list;
      (** the group's `with`s that install, innermost first (see [install]) *)
  mutable copies : copy list;
      (** the group's uses of an implementation, each with a copy of what it
          needs (see [copy]) *)
  mutable handler_needs : handler_needs list;
      (** the group's handlers, whose needs are checked once it's done (see
          [handler_needs]) *)
  mutable withheld : withheld list;
      (** the module's functions that call a closure in a `with` that doesn't
          install what the closure uses (see [withheld]) *)
  mutable cant_fail : string option;
      (** why the code being checked can't fail, if it's a handler's state, for
          a message when something in it does *)
  mutable in_scope : Path.t list;
      (** the types step 2 of a lookup found: a type imported by name may be
          used only that way, so this says that its import is used *)
}

(* A tag matched in an error set that was still open: the tag, its
   payload's types, the set, which has to have it once the group is done,
   and the parameters of the function and lambdas it's in. [tarm] says
   whether it's a `fail` arm's, which matches what a call fails with,
   rather than a tag inside `Err(...)`, which matches what a [Result]
   holds, and [tvalue] whether it's not a pattern at all but a tag
   written as a value, `Err(Short(a, b))` ([err_row]). *)
and tag_pattern = {
  ttag : ident;
  tpayload : ty list;
  tset : row;
  tin : (string * ty) list;
  tarm : bool;
  tvalue : bool;
}

(* A call that uses a named row, `f()` for `f: fn() uses ..d`, or a `with`
   that installs an implementation that needs one: the row [rinto] of the
   function or lambda it's in has to end in [rnamed]. Ending a row in one
   would stop it getting any more labels, so that's done once the group is
   done, when it has all of them (infer_top.ml). [rwhat] says what needs
   it, for a message: "this call uses". *)
and row_due = {
  rloc : Loc.t;
  rinto : row;
  rnamed : int * string;
  rwhat : string;
}

(* An operation of an implementation, `usd_to: fn(c) => ...` in a `Rates
   { ... }`: it can fail with fewer errors than its dependency declares,
   never more (deps.md, "Implementations"). Its errors [ierrs] start as
   [ideclared] with room for more, and once the group is done (when it's
   known what its calls fail with), anything more is reported and the room
   closed. [ivalue] is what's given for it, and [inodes] the types of the
   expressions of the function it's in, for a message. *)
and impl_op = {
  idep : Path.t;
  iop : string;
  ideclared : label list;
  ierrs : row;
  ivalue : expr;
  inodes : (int, ty) Hashtbl.t;
}

(* A `with` that installs [wdep], at [wloc]: its body uses [wbody], which
   is what the body's calls use, and that has to be no more than [wdep]
   and what's installed outside, [wouter]. That's an inclusion, not an
   equality: a closure called both in the body and outside it uses what
   the outside does, which is less than the body can. It's settled once
   the group is done (infer_top.ml), when every call of the group knows
   what it uses. *)
and install = {
  wloc : Loc.t;
  wdep : string;
  wbody : row;
  wouter : row;
  wself : Path.t;  (** the function the `with` is in *)
}

(* A place an implementation is used: a `with` installs it, or it's passed
   as a transparent parameter. What it needs, [ksrc], is needed there, in
   [kdst], which starts with its labels and a tail of its own. [ksrc]
   itself isn't joined to [kdst]: one implementation can be used in two
   places, `with h in` and inside it `run(h)` under another `with`, and
   joined to both, the two places would use the same row, so what the
   inner `with` installs would be needed outside it too. The labels [ksrc]
   learns later (from a function of the group, once it's joined) are added
   once the group is done, at [kloc]; [kpassed] are those added so far. *)
and copy = {
  kloc : Loc.t;
  ksrc : row;
  kdst : row;
  kwhat : string;  (** what needs it, for a message: "installing this needs" *)
  mutable kpassed : string list;
}

(* A handler: [nrow] is what its state and arms use, and [ncalls] the
   calls that add to it. That can't be a dependency it implements itself
   (the next one out is `outer`'s, stage 9). If its needs are written,
   `for N uses Console`, or it's public, which needs nothing if it says
   nothing, they're [ndeclared], and [nrow] has to be no more than that.
   It's checked once the group is done, as a function's `uses` is
   (infer_top.ml), and then a written row is closed. *)
and handler_needs = {
  nself : Path.t;
  ndeclared : string list option;
  nrow : row;
  ncalls : call list ref;
}

(* A dependency [hdep] that a closure [hfn] calls inside a `with` of it
   still gets from outside, and why ([hnote]): a message that says its
   callers have to install it explains with this (infer_top.ml). *)
and withheld = { hfn : Path.t; hdep : string; hnote : string }

(* A use of another function of the group being checked. While the group's
   bodies are being checked, each one sees the others only as their
   declarations describe them, so no body learns anything from another
   body of its group, and checking them in another order would find the
   same. Once every body is checked, each use is joined with the type that
   function's own body gave it. *)
and join = { jloc : Loc.t; jname : string; used : ty; target : Path.t }

(* A statement's value, which is thrown away, so it has to be `Unit`: a
   value can't be dropped without a word (errors.md, "Nothing is
   dropped"). It's checked once the group's uses of each other are joined
   ([dropped_values]), since a call of another function of the group
   learns only then what it returns. [callee] names the function, if the
   statement is a call, and [dself] the function the statement is in. *)
and drop = { dloc : Loc.t; dty : ty; callee : string option; dself : Path.t }

(* A call, and the errors its callee can fail with (errors.md, "Marking").
   Whether it can fail at all is known only once its group is done: a
   function of the group learns what it fails with only then. So each
   call is kept, and the markers' rules are checked at the end
   (infer_top.ml). *)
and ecall = {
  eloc : Loc.t;  (** the call *)
  ename_loc : Loc.t;  (** the callee, as written: `acme.debit` *)
  ename : string;  (** the callee, as a message names it: [debit] *)
  ewritten : string;
      (** the callee as it's written, for a message that says where an error
          comes from: [acme.debit] *)
  eown : label list;
      (** what the callee's errors were at the call: what it brings in itself.
          Nothing, if its errors are the caller's own *)
  eself : bool;
      (** whether the callee's errors are the caller's own: a public function's
          transparent parameter, whose row is its function's *)
  erow : row;
      (** the callee's errors, which the call adds to its marker's but never
          becomes: once the group is done, exactly what the callee fails with *)
  etarget : Path.t option;
      (** the callee, if it's a function of the group, whose errors are known
          only once the group is done *)
  eparams : (string * ty) list;
      (** the parameters of the function or lambdas the call is in *)
  eselves : row list;  (** those functions' and lambdas' own errors *)
}

(* A `try`, an `attempt` or a `match` with `fail` arms, and the calls it
   covers: for a `try` or an `attempt`, every call to its right in the
   same expression, and for a `match`, every call in what it matches;
   except inside a lambda, whose body has markers of its own. A [mutable]
   field can be changed in place, which is how each call adds itself. *)
and marker = {
  mkind : marker_kind;
  mloc : Loc.t;  (** the keyword, or a `match`'s first `fail` arm *)
  mutable covered : ecall list;
  mutable unwrapped : row list;
      (** for `try r`: the errors of the [Result] it fails with again; for `try
          match`, the errors no arm handles *)
  mutable hint : string option;
      (** for `try`: a help that explains why it may cover nothing *)
  mutable failed : bool;
      (** for `attempt` and `match`: whether a `fail` is inside it *)
}

and marker_kind = Mtry | Mattempt | Mmatch

(* One row of errors added to another: a call's to its marker's handler,
   or a [Result]'s to the handler of the `try` that fails with it again.
   [isrc] is added to [idst] by inclusion: [idst] gets each of its labels,
   and [isrc] stays as it was, so a callee never fails with what its
   caller does. Labels known at the time are added then; those a row
   learns later (a function of the group, joined at its end) are added
   once the group is done, by [iadd], which reports a tag with two shapes
   at [iloc] ([ipassed] are the names added so far). A row that stands for
   whatever a parameter fails with can't be listed, so [idst] ends in the
   same tail instead ([ilinked], once it does). *)
and inclusion = {
  iloc : Loc.t;
  isrc : row;
  idst : row;
  iparams : (string * ty) list;
      (** the parameters of the function and lambdas where it's added *)
  iadd : row -> unit;
  mutable ipassed : string list;
  mutable ilinked : bool;
}

(* Something that adds to a top-level function's errors: a call its `try`
   passes on, a `fail`, a [Result] it fails with again, or the errors a
   `try match` doesn't handle. A function
   that writes its errors is checked against them (infer_top.ml), with a
   label at the first of these that brings in an error it doesn't
   declare. *)
and source =
  | Passed of ecall
  | Failed of Loc.t * label
  | Unwrapped of Loc.t * row
  | Unhandled of Loc.t * row

(* A dot call that turned out to call [callee], a method of the module
   not checked yet, from [caller]. Which method `s.size()` calls is found
   only by checking it, after the call graph has put the functions in
   order, so the call graph was missing this edge: infer_top.ml adds it
   and checks the module again. *)
exception Unchecked of { caller : string; callee : string }

(* What the expression being inferred can see. *)
type ctx = {
  self : Path.t;  (** the top-level function being checked *)
  locals : (int, ty) Hashtbl.t;
      (** the type of each local of the top-level function, by binder id *)
  nodes : (int, ty) Hashtbl.t;
      (** the type of each expression and pattern of the function, by node id *)
  found : (int, found) Hashtbl.t;  (** what each lookup found, by node id *)
  as_dep : (int, Path.t) Hashtbl.t;
      (** each expression that gives a handler of several dependencies where a
          value of one of their types is wanted, by node id, with that one (see
          [as_one]) *)
  errs : row;  (** the errors of the innermost function or lambda *)
  uses : row;  (** the dependencies of the innermost function or lambda *)
  handler : row;
      (** where a `fail`, and the errors of a call a `try` covers, go: the
          innermost `attempt`'s errors, or else [errs] *)
  markers : marker list;
      (** the markers covering the expression, innermost first: none, outside
          any `try` or `attempt` *)
  params : (string * ty) list;
      (** the parameters of the function and the lambdas the expression is in,
          by name, the innermost's first *)
  selves : row list;
      (** the errors of the function and those lambdas, the innermost's first *)
  sources : source list ref option;
      (** what adds to the top-level function's errors, most recent first, when
          [handler] is them *)
  calls : call list ref;
      (** each call that adds to [uses], most recent first. A [ref] is a mutable
          cell, here shared by every copy of the [ctx] for the same function or
          lambda. *)
  tparams : ty list;  (** what the type parameters in scope stand for *)
  named : (string * row) list;
      (** the rows the function's signature names, `..d`, by name (ast.ml) *)
}

(* ---- reporting ---- *)

let printer env = Types.printer ~names:env.names env.st
let type_name env p = env.names p

(* A name as it's written, for messages. *)
let name_of = function
  | Local b -> b.ident.name
  | Global p | Global_value p -> p.name
  | Intrinsic x -> x
  | Dep_op (p, op) -> p.name ^ "." ^ op

let report env d = Diag.report env.sink d

(* Report an error, and carry on: the code it's about has type [TError]. *)
let fail env ?help ?notes ?labels loc msg =
  report env (Diag.make ?help ?notes ?labels loc msg);
  TError

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_of (e : expr) =
  match e.kind with Block (_, last) -> result_of last | _ -> e

let result_loc (e : expr) = (result_of e).loc

(* How to explain a mismatch with an expected type, passed down along with
   it: [msg] words the error, [help] suggests a fix and [labels] point at
   other code, each given both types printed (the one found, then the one
   expected); [notes] say where the expectation comes from. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
}

let explain ?msg ?(notes = []) ?help ?(labels = fun _ _ -> []) () =
  { msg; notes; help; labels }

let plain = explain ()

(* Unify [found] (what the code has) with [expected] (what it needs), and
   say whether that worked. *)
let unifies env why loc ~found ~expected =
  match Unify.unify env.st found expected with
  | () -> true
  | exception ((Unify.Mismatch | Unify.Two_shapes _) as failure) ->
      let pr = printer env in
      let f = show pr found and x = show pr expected in
      (* two types that print the same differ in a row's tail, which is
         hidden, so show every tail *)
      let pr, f, x =
        if f <> x then (pr, f, x)
        else
          let pr =
            Types.printer ~show_tail:(fun _ -> true) ~names:env.names env.st
          in
          let f = show pr found in
          (pr, f, show pr expected)
      in
      let msg =
        match why.msg with
        | Some m -> m f x
        | None -> sprintf "expected `%s`, found `%s`" x f
      in
      let help = Option.map (fun h -> h f x) why.help in
      let more, help = mismatch_notes ?help ~found ~expected () in
      (* two implementations of one dependency that need different things,
         themselves or inside the types they're part of, `Box<Rates>` *)
      let rec impls found expected =
        match (repr found, repr expected) with
        | (TCon (p, [ TUses _ ]) as t), TCon (q, [ TUses _ ]) when p = q ->
            Some t
        | TCon (p, fs), TCon (q, xs)
          when p = q && List.length fs = List.length xs ->
            List.find_map Fun.id (List.map2 impls fs xs)
        | _ -> None
      in
      let more, help =
        match impls found expected with
        | Some t ->
            (* `uses` after `->` is the function's, so a dependency's own
               is parenthesized; inside `Box<...>` it needs nothing *)
            let f = if t == repr found then sprintf "(%s)" f else f in
            ( more
              @ [
                  "an implementation's type says what it needs, so one that \
                   needs more can't stand in for one that needs less";
                ],
              Some
                (Option.value help
                   ~default:
                     (sprintf
                        "say what it needs where its type is written: `%s`" f))
            )
        | _ -> (more, help)
      in
      (* what's about errors: one tag with two shapes, or a function that
         fails where nothing can *)
      let more, help =
        match (failure, errors_clash found expected) with
        | Unify.Two_shapes name, _ ->
            let shapes =
              List.sort_uniq compare
                (List.map (show_label pr)
                   (labels_named name found @ labels_named name expected))
            in
            ( more
              @ [
                  sprintf
                    "`%s` has two shapes here, %s: a tag is its name and its \
                     payload's types, so these are two errors with one name"
                    name (and_list shapes);
                ],
              Some
                (Option.value help
                   ~default:"give one of them another name, where it fails") )
        | _, Some (extra, []) ->
            ( more
              @ [
                  sprintf
                    "this function can fail with %s, and the type wanted here \
                     can't fail"
                    (and_list (List.map (show_label pr) extra));
                  "a parameter whose type is inferred can fail only if it's \
                   called with `try`";
                ],
              Some
                (Option.value help
                   ~default:
                     "pass its errors on with `try` where it's called, or \
                      handle them inside it with `match`") )
        | _, Some (extra, wanted) ->
            ( more
              @ [
                  sprintf
                    "this function can fail with %s, and the type wanted here \
                     fails only with %s"
                    (and_list (List.map (show_label pr) extra))
                    (and_list (List.map (show_label pr) wanted));
                ],
              Some
                (Option.value help
                   ~default:"handle the others inside it with `match`") )
        | _ -> (more, help)
      in
      (* another module's opaque type can't stand in for what it's
         represented as, or the other way round. [blame] looks for one
         where the two types differ: at the top, inside the same type
         (`Array<UserId>` and `Array<Int>`), or behind one of this module's
         own opaque types, which here is what it's represented as *)
      let foreign t =
        match t with
        | TCon (p, _) -> (
            match Hashtbl.find_opt env.types p with
            | Some { body = Opaque None; _ } -> Some p
            | _ -> None)
        | _ -> None
      in
      let own t =
        match t with
        | TCon (p, _) when Hashtbl.mem env.st.reps p -> Some (reveal env.st t)
        | _ -> None
      in
      let rec blame f x =
        let f = repr f and x = repr x in
        let pairs a b =
          if List.length a = List.length b then
            List.find_map Fun.id (List.map2 blame a b)
          else None
        in
        match (f, x) with
        | TCon (p, a), TCon (q, b) when p = q -> pairs a b
        | _ -> (
            match (foreign f, foreign x, own f, own x) with
            | Some p, _, _, _ | _, Some p, _, _ -> Some p
            | _, _, Some f, _ -> blame f x
            | _, _, _, Some x -> blame f x
            | None, None, None, None -> (
                match (f, x) with
                | TFun (ps, r, _, _), TFun (qs, s, _, _) ->
                    pairs
                      (r :: List.map (fun p -> p.ty) ps)
                      (s :: List.map (fun p -> p.ty) qs)
                | _ -> None))
      in
      let more, help =
        match blame found expected with
        | Some p ->
            let note, h = representation_private p in
            (more @ [ note ], Some (Option.value help ~default:h))
        | None -> (more, help)
      in
      (* a handler of several dependencies where an implementation is
         wanted, at the top or inside the types (`Option<Rates>`): one of
         its own somewhere it wasn't known as it was made (see [as_one]),
         or another one *)
      let rec handler_pair f x =
        match (repr f, repr x) with
        | TCon (h, _), TCon (d, [ TUses _ ]) when h <> d -> (
            match Hashtbl.find_opt env.types h with
            | Some { body = Handler deps; _ } -> Some (h, deps, d)
            | _ -> None)
        | TCon (p, fs), TCon (q, xs)
          when p = q && List.length fs = List.length xs ->
            List.find_map Fun.id (List.map2 handler_pair fs xs)
        | TFun (ps, r, _, _), TFun (qs, r', _, _)
          when List.length ps = List.length qs ->
            List.find_map Fun.id
              (handler_pair r r'
              :: List.map2 (fun p q -> handler_pair p.ty q.ty) ps qs)
        | _ -> None
      in
      let more, help =
        match handler_pair found expected with
        | Some (h, deps, d) when List.mem d deps ->
            let d = type_name env d in
            ( more
              @ [
                  sprintf
                    "`%s` implements %s, so it's taken as just `%s` only where \
                     `%s` is wanted as it's made"
                    (type_name env h)
                    (and_list (List.map (type_name env) deps))
                    d d;
                ],
              Some
                (Option.value help
                   ~default:
                     (sprintf "say so where it's made: `let x: %s = %s(...)`" d
                        (type_name env h))) )
        | Some (h, deps, d) ->
            let d = type_name env d in
            ( more
              @ [
                  sprintf
                    "`%s` is a handler for %s, so what its call describes \
                     implements those, not `%s`"
                    (type_name env h)
                    (and_list (List.map (type_name env) deps))
                    d;
                ],
              Some
                (Option.value help
                   ~default:
                     (sprintf
                        "give an implementation of `%s` here: a `%s { ... }`, \
                         or a handler for `%s`"
                        d d d)) )
        | None -> (more, help)
      in
      ignore
        (fail env ?help ~notes:(why.notes @ more) ~labels:(why.labels f x) loc
           msg);
      false
  | exception Unify.Infinite ->
      let pr = printer env in
      ignore
        (fail env loc
           ~notes:
             [
               sprintf "it would have to be `%s` and `%s` at the same time"
                 (show pr expected) (show pr found);
             ]
           "this value's type would have to contain itself");
      false

let unify_at env ?msg ?notes ?help ?labels loc ~found ~expected =
  let help = Option.map (fun h _ _ -> h) help in
  ignore
    (unifies env (explain ?msg ?notes ?help ?labels ()) loc ~found ~expected)

(* ---- types as written ---- *)

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

(* ---- lookups through a type ----

   Constructors, fields and record literals are found through a type
   (module-build.md, "Found through a type"), in three steps:

   1. if the type is already known at this point, look in its declaration
   2. otherwise, if exactly one visible type has what's being looked for,
      that's the one
   3. otherwise it's an error, which the caller words

   [known] is what step 1 found, if the type was known and has it, and
   [fits] says what a type declaration has. For a constructor, a type that
   is known but doesn't have it falls through to step 2, so the error can
   name both types: `expected a pattern for `Int`, but this one is a
   `Plan``. *)

type 'a lookup = Found of 'a | Nowhere | Several of Path.t list

let through_type env ~known ~fits =
  match known with
  | Some found -> Found found
  | None -> (
      match
        List.filter_map
          (fun (td : Iface.type_decl) ->
            Option.map (fun x -> (td, x)) (fits td))
          env.visible
      with
      | [ (((td : Iface.type_decl), _) as found) ] ->
          if not (List.mem td.path env.in_scope) then
            env.in_scope <- td.path :: env.in_scope;
          Found found
      | [] -> Nowhere
      | several ->
          Several
            (List.map (fun ((td : Iface.type_decl), _) -> td.path) several))

(* The declaration of [t]'s type, if [t] is already known to be a named
   type. In its own module, an opaque type's is its representation's. *)
let known_decl env t =
  match reveal env.st t with
  | TCon (p, _) -> Hashtbl.find_opt env.types p
  | _ -> None

let ctor_in (c : ident) (td : Iface.type_decl) =
  match td.body with
  | Sum cs -> List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) cs
  | Record _ | Builtin | Opaque _ | Errors _ | Dep _ | Handler _ -> None

(* The constructor [c], where a value of type [expected] is wanted. One
   written after its type, `Light.Red`, is looked for there and nowhere
   else; that's how two types that share a constructor's name are told
   apart when nothing else says which. *)
let find_ctor env (c : ctor_ref) ~expected =
  match c.qual with
  | Some { tref = Named p; tloc } -> (
      let td = Hashtbl.find env.types p in
      match ctor_in c.name td with
      | Some k -> Some (td, k)
      | None ->
          report env (not_in_type ~names:env.names tloc c.name td);
          None)
  | Some { tref = Param _; _ } ->
      (* resolve.ml only puts a declared type before a constructor *)
      assert false
  | None -> (
      let c = c.name in
      match known_decl env expected with
      | Some ({ body = Opaque None; _ } as td) ->
          (* another module's opaque type has no constructors here *)
          report env (opaque_private c.loc td);
          None
      | Some ({ body = Sum _; _ } as td) when ctor_in c td = None ->
          (* a sum type is expected, so no other type's constructor would
             do *)
          report env (not_in_type ~names:env.names ~expected:true c.loc c td);
          None
      | decl -> (
          let known =
            Option.bind decl (fun td ->
                Option.map (fun k -> (td, k)) (ctor_in c td))
          in
          match through_type env ~known ~fits:(ctor_in c) with
          | Found found -> Some found
          | Nowhere ->
              (* it may be in a type the module can't name bare, which is
                 only looked in when that type is expected *)
              let elsewhere =
                Hashtbl.fold
                  (fun p td acc ->
                    if ctor_in c td <> None then p :: acc else acc)
                  env.types []
                |> List.sort compare
              in
              report env
                (no_ctor ~names:env.names ~can_name:env.can_name c elsewhere);
              None
          | Several owners ->
              report env (ambiguous_ctor ~names:env.names c owners);
              None))

(* Is [c] given as many arguments as it has fields, labelled correctly?
   Each problem is reported. *)
let ctor_shape env loc (c : ident) (ctor : Iface.ctor) labels =
  let given = List.length labels in
  if List.length ctor.cfields <> given then (
    report env (ctor_arity loc c ctor given);
    false)
  else
    let named = List.filter_map Fun.id labels in
    if named = [] then true
    else if List.length named <> given then (
      report env (some_labels loc c);
      false)
    else
      List.fold_left2
        (fun ok (l : ident) (f : Iface.field) ->
          if l.name <> f.fname then (
            report env (wrong_label l f);
            false)
          else ok)
        true named ctor.cfields

(* The fields a value of [td] can be read with, `r.f`: a record's. *)
let record_fields (td : Iface.type_decl) =
  match td.body with
  | Record fs -> Some fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Dep _ | Handler _ -> None

(* The fields a literal of [td] gives, `T { f: ... }`: a record's, or a
   dependency's operations, which an implementation gives (deps.md,
   "Implementations"). An operation isn't read from one: it's called on
   the dependency, where it's installed. *)
let literal_fields (td : Iface.type_decl) =
  match td.body with
  | Record fs | Dep fs -> Some fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Handler _ -> None

(* The operation [name] of the dependency [td], if it's one. *)
let dep_op_in name (td : Iface.type_decl) =
  match td.body with
  | Dep ops -> List.find_opt (fun (o : Iface.field) -> o.fname = name) ops
  | Record _ | Sum _ | Builtin | Opaque _ | Errors _ | Handler _ -> None

let op_in name (td : Iface.type_decl) =
  List.find_opt (fun (o : Iface.op) -> o.oname = name) td.members

let field_in name (td : Iface.type_decl) =
  Option.bind (record_fields td)
    (List.find_opt (fun (d : Iface.field) -> d.fname = name))

(* What [name] is in the type [p], which has a field or a member of
   that name, as an error says it: "a field", "a method", ... *)
let member_kind env name p =
  match op_in name (Hashtbl.find env.types p) with
  | Some { okind = Method; _ } -> "a method"
  | Some { okind = Function; _ } -> "an associated function"
  | Some { okind = Value; _ } -> "an associated value"
  | None -> "a field"

(* The member [name] of [t]'s type, if [t] is already known to be a
   named type that has one. In its own module, an opaque type is also what
   it's represented as, so an item of that type is found too, if the
   opaque type has none of that name. *)
let rec op_of env t name =
  match repr t with
  | TCon (p, args) -> (
      match Hashtbl.find_opt env.types p with
      | None -> None
      | Some td -> (
          match (op_in name td, Hashtbl.find_opt env.st.reps p) with
          | Some o, _ -> Some (td, o)
          | None, Some rep ->
              op_of env
                (of_ty ~vars:(List.nth args) ~tails:(fun _ -> REmpty) rep)
                name
          | None, None -> None))
  | _ -> None

(* The function a member is: [Stack.push]. *)
let op_path (td : Iface.type_decl) (o : Iface.op) =
  Path.make td.path.home (td.path.name ^ "." ^ o.oname)

let sorted names = List.sort String.compare names

(* ---- expressions ---- *)

(* Whether calling [p] calls a function of the group being checked whose
   errors are known only once the group is done: one whose declaration
   doesn't say everything about it, or the function being checked. *)
let group_call env p =
  List.mem_assoc p env.group && not (List.mem p env.spelled)

(* A name's type. A top-level function's is a fresh instance of its
   scheme, so each use can pick its own types; another function of the
   group being checked has the type its declaration gives it, joined with
   its real type once the group is done (see [join]), unless its
   declaration is all there is to know. *)
let rec lookup env cx loc = function
  | Local b -> Hashtbl.find cx.locals b.id
  | Global_value p -> (
      (* a function of no parameters (ast.ml), whose result is the value *)
      match repr (lookup env cx loc (Global p)) with
      | TFun ([], t, _, _) -> t
      | _ -> TError)
  | Global p when List.mem p env.spelled ->
      (* its declaration says everything about it, so even in its own body
         it's an instance of that, joined with nothing: a use that closes
         its rows, like storing it as a `fn()`, closes only the instance's *)
      (List.assoc p env.group) ()
  | Global p when p <> cx.self && List.mem_assoc p env.group ->
      let used = (List.assoc p env.group) () in
      env.joins <- { jloc = loc; jname = p.name; used; target = p } :: env.joins;
      used
  | Global p -> instantiate env.st (Hashtbl.find env.globals p)
  | Intrinsic x ->
      instantiate env.st (Hashtbl.find env.globals (Path.prelude x))
  | Dep_op (p, op) -> (
      (* the operation as declared, which uses its dependency: a call
         adds it to the caller's `uses` *)
      match Option.bind (Hashtbl.find_opt env.types p) (dep_op_in op) with
      | Some o -> (
          match field_type ~tvars:[] o with
          | TFun (ps, ret, errs, _) ->
              TFun
                (ps, ret, errs, RExtend (dep (Ty.dep_label p), fresh_row env.st))
          | _ -> TError)
      | None -> TError)

let want_int env op (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int
    ~notes:[ sprintf "`%s` works on `Int`s" op ]

let want_bool env what (e : expr) t =
  unify_at env e.loc ~found:t ~expected:bool
    ~notes:[ sprintf "%s has to be a `Bool`" what ]

(* The name of the function [f] a call calls, for messages: "`print`", or
   "this" if it's something else. *)
let callee_name (f : expr) =
  match f.kind with Var x -> sprintf "`%s`" (name_of x) | _ -> "this"

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
      env.copies <-
        {
          kloc = loc;
          ksrc = needs;
          kdst = copy;
          kwhat = what;
          kpassed = List.map (fun (l : label) -> l.name) labels;
        }
        :: env.copies;
      copy

(* [t], used at [loc], or if it's an implementation, one that may need
   more than it does: where one that needs more is allowed, one that needs
   less will do. *)
let widen env ~loc t =
  match repr t with
  | TCon (d, [ TUses u ]) ->
      TCon (d, [ TUses (copy_needs env ~loc ~what:"passing this needs" u) ])
  | t -> t

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
    | Passed c -> sprintf "from `%s`" c.ewritten
    | Failed (l, _) -> sprintf "from the `fail` on line %d" l.start.line
    | Unwrapped (l, _) -> sprintf "from the `Result` on line %d" l.start.line
    | Unhandled (l, _) -> sprintf "from the `match` on line %d" l.start.line)

(* What the code [cx] is in has already added to its handler, for a
   message about an error that's there: in the function itself, what adds
   to its errors; in an `attempt` or a lambda, the calls the innermost
   marker has covered so far. If it's none of them, it's what's written in
   the function's signature, or else an earlier call. *)
let sources_of cx =
  match (cx.sources, cx.markers) with
  | Some s, _ -> (!s, "from the signature")
  | None, m :: _ ->
      (List.map (fun c -> Passed c) m.covered, "from an earlier call")
  | None, [] -> ([], "from an earlier call")

(* Add [errs], what's new here (a call's, a `fail`'s), to [into]. One error
   with two shapes is reported: [here] says where the new one comes from,
   and [sources] where the old one may have, for the message
   (module-build.md, "Error tags have no home"); [fix] is the help, given
   the tag. *)
let add_errors env ~loc ~here ~sources:(sources, elsewhere) ~fix errs into =
  (* the labels already there, before they're unified with the new ones *)
  let before = fst (row_parts into) in
  let new_ = fst (row_parts errs) in
  (* only [errs]'s labels, with a fresh tail: unified with its own tail,
     [errs] would become [into], and fail with everything [into] does *)
  match Unify.unify_row env.st (extend new_ (fresh_row env.st)) into with
  | () -> ()
  | exception Unify.Two_shapes name ->
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
           ~new_:(here, Option.value (shape new_) ~default:name)
           ~help:(fix name))
  | exception (Unify.Mismatch | Unify.Infinite) ->
      ignore
        (fail env loc
           ?notes:(Option.map (fun n -> [ n ]) env.cant_fail)
           ?help:
             (Option.map
                (fun _ ->
                  "handle it here, with `attempt` or a `match` with `fail` \
                   arms, or make the value in an operation instead")
                env.cant_fail)
           (sprintf "this can fail with %s, which isn't allowed here"
              (show_row (printer env) ~prefix:"" ~sep:" | " ~kind:"e" errs)))

(* Add [errs] to [into] by inclusion (see [inclusion]): its labels now,
   with [add] (an [add_errors] waiting for its two rows), and what it
   learns later once the group is done. *)
let include_errors env cx ~loc add errs into =
  add errs into;
  env.includes <-
    {
      iloc = loc;
      isrc = errs;
      idst = into;
      iparams = cx.params;
      iadd = (fun r -> add r into);
      ipassed = row_names errs;
      ilinked = false;
    }
    :: env.includes

(* Whether [cx] is the body of the top-level function itself, and not of
   a lambda in it: its errors are the function's own. *)
let in_own_body env cx =
  match Option.map repr (Hashtbl.find_opt env.globals cx.self) with
  | Some (TFun (_, _, errs, _)) -> row_tail errs = row_tail cx.errs
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
  let what = if needs then "installing this needs" else "this call uses" in
  let joined =
    match row_skolem uses with
    | Some named ->
        env.rows_due <-
          { rloc = loc; rinto = cx.uses; rnamed = named; rwhat = what }
          :: env.rows_due;
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
   uses it: "this call uses". *)
and join_uses env ~loc ~what joined into =
  try Unify.unify_row env.st joined into
  with Unify.Mismatch | Unify.Infinite | Unify.Two_shapes _ ->
    let shown =
      match row_names joined with
      | [] -> "more than what it's in can"
      | ns ->
          and_list (List.map (sprintf "`%s`") ns) ^ ", which what it's in can't"
    in
    ignore
      (fail env loc
         ~notes:
           [
             "a function or lambda uses everything its calls use, and \
              everything the implementations its `with`s install need, and the \
              type of what this is in says it can't use all of that";
           ]
         ~help:
           "say what it uses where its type is written, with `uses`, or leave \
            the type out and let it be inferred"
         (sprintf "%s %s" what shown))

(* A call adds the callee's dependencies to the caller's, and its errors
   to whatever marks it (errors.md, "Marking"): the innermost marker's
   handler, the caller's own errors for a `try` or the `attempt`'s. A call
   no marker covers can't fail: its errors go to a row of their own, which
   has to end up empty once the group is done (infer_top.ml). [ename] and
   [name_loc] are the callee, and [target] the function of the group it
   calls, if it does. *)
let absorb env cx ~(call : expr) ~ename ~name_loc ?target ?callee errs uses =
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
  let sources = sources_of cx in
  let here = sprintf "from `%s`" ewritten in
  (* rename the one this call brings in: `fail Timeout(a) => fail
     LockTimeout(a)` *)
  let fix tag =
    let arity =
      match List.find_opt (fun (l : label) -> l.name = tag) own with
      | Some l -> List.length l.payload
      | None -> 0
    in
    let args =
      match List.init arity (fun i -> String.make 1 "abcdefgh".[i mod 8]) with
      | [] -> ""
      | xs -> "(" ^ String.concat ", " xs ^ ")"
    in
    match env.source call with
    | Some c ->
        sprintf
          "rename one where it comes in: `try match %s` with the arm `fail \
           %s%s => fail %s%s%s`"
          c tag args
          (String.capitalize_ascii (short_name ename))
          tag args
    | None -> "rename one of them where it comes in"
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
        (kept_passed_on call.loc ~name_loc ename ~fn:(short_name cx.self.name)
           ~handled:(m.mkind = Mmatch));
      List.iter (fun m -> m.covered <- ec :: m.covered) cx.markers
  | [] ->
      (* the callee's own row, which an inferred parameter's is too: if
         nothing else says it fails, it's closed at the end, and the
         parameter can't fail *)
      env.unmarked <- (ec, reopen env errs) :: env.unmarked
  | markers ->
      List.iter (fun m -> m.covered <- ec :: m.covered) markers;
      include_errors env cx ~loc:call.loc
        (add_errors env ~loc:call.loc ~here ~sources ~fix)
        errs cx.handler;
      Option.iter (fun s -> s := Passed ec :: !s) cx.sources

(* Inside the function, an `inout` parameter is an ordinary variable. *)
let bind_params cx params ps =
  List.iter2
    (fun (p : Resolved.param) (t : Types.param) ->
      Hashtbl.replace cx.locals p.pname.id t.ty)
    params ps

(* What a lambda's body sees: the lambda's own errors and dependencies,
   and no marker, since the body has markers of its own. *)
let lambda_cx cx (params : Resolved.param list) ps ~errs ~uses =
  {
    cx with
    errs;
    uses;
    calls = ref [];
    handler = errs;
    markers = [];
    params =
      List.map2
        (fun (p : Resolved.param) (t : Types.param) ->
          (p.pname.ident.name, t.ty))
        params ps
      @ cx.params;
    selves = errs :: cx.selves;
    sources = None;
  }

(* The first [n] characters of [loc], a keyword at its start. *)
let keyword (loc : Loc.t) n =
  { loc with stop = { loc.start with col = loc.start.col + n } }

(* A new marker at [mloc], kept for the checks at the end of the group. *)
let marker env mkind mloc =
  let m =
    { mkind; mloc; covered = []; unwrapped = []; hint = None; failed = false }
  in
  env.all_markers <- m :: env.all_markers;
  m

(* Why a `try` of [a], of type [t], which isn't a [Result], may cover
   nothing: [a] is a [Result] whose type isn't known yet, or `try` covers
   more than it seems to, everything to its right, as in `try r + try r`. *)
let try_hint env cx (a : expr) t =
  let is_result t =
    match reveal env.st t with TCon (p, _) -> p = result_path | _ -> false
  in
  let rec leftmost (e : expr) =
    match e.kind with Binop (_, l, _) -> leftmost l | _ -> e
  in
  match (a.kind, reveal env.st t) with
  | Var x, TVar _ ->
      Some
        (sprintf
           "if `%s` is a `Result`, say so where it's declared, as in `%s: \
            Result<Int, ! E>`: `try` fails with a `Result`'s error only once \
            its type is known"
           (name_of x) (name_of x))
  | Binop _, _ -> (
      let l = leftmost a in
      match Hashtbl.find_opt cx.nodes l.node with
      | Some lt when is_result lt ->
          Some
            (sprintf
               "`try` covers everything to its right, so this is `try (%s)`: \
                to fail with the `Result`'s error first, write `(try %s)`"
               (Option.value (env.source a) ~default:"...")
               (Option.value (env.source l) ~default:"..."))
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

(* [r]'s labels, without the tags [names]. *)
let without names r =
  extend
    (List.filter
       (fun (l : label) -> not (List.mem l.name names))
       (fst (row_parts r)))
    REmpty

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
            c.name )
      in
      let help =
        sprintf
          "if `%s` means to drop a value of any type there, write `let _ = ...`"
          c.name
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
          (* `fail` is the one way to fail with a tag written here *)
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
              raise (Unchecked { caller = cx.self.name; callee = path.name });
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
        ~name_loc:f.loc ?target ?callee errs uses;
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
        | Var x -> Some (short_name (name_of x))
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
                  td.members
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
        raise (Unchecked { caller = cx.self.name; callee = path.name });
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
        absorb env cx ~call:e ~ename ~name_loc:f.loc ?target ?callee errs uses;
        ret)
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         function, whose errors and dependencies are the call's *)
      let ps = List.map (infer_arg env cx) args in
      let ret = fresh_var env.st in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      unify_at env f.loc ~found:tf ~expected:(TFun (ps, ret, errs, uses));
      absorb env cx ~call:e ~ename ~name_loc:f.loc errs uses;
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

(* The error set of `Err(tag(payload))`, where a value of type [expected]
   is wanted. Where that's a `Result` whose errors are what something can
   fail with, a function's declared result or what an `attempt` kept, the
   tag has to be one of them, as in a pattern ([tag_pattern]): `attempt
   f() == Err(Shrot)` is an error, not a comparison that's always false.
   An open set is checked when its group is done. Anywhere else the
   tag's set isn't known yet, as when the `Err` is on the left of `==`:
   it starts with no tags, and once the group is done the tag is checked
   against what the set turned out to be, or, if it's a set of its own,
   added to it: `if c then Err(A) else Err(B)`. Adding it now would let a
   kept set it's unified with later gain it. *)
and err_row env cx (tag : ident) args ~expected =
  let payload = List.map fst args in
  let wanted =
    match reveal env.st expected with
    | TCon (p, [ _; errs ]) when p = result_path -> (
        match repr errs with
        | TErrors row -> (
            match row_tail row with
            | None -> Some row
            | Some t
              when List.exists (fun (k, _) -> row_tail k = Some t) env.kept ->
                Some row
            | Some _ -> None)
        | _ -> None)
    | _ -> None
  in
  let later row =
    env.tag_patterns <-
      {
        ttag = tag;
        tpayload = payload;
        tset = row;
        tin = cx.params;
        tarm = false;
        tvalue = true;
      }
      :: env.tag_patterns;
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
                ~msg:(fun f x ->
                  sprintf "this is %s, but `%s` holds %s here" (article f)
                    tag.name (article x))
                ~notes:[ sprintf "it's `%s`" (show_label (printer env) l) ])
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

(* `r.f`: the field is found through [r]'s type, which has to be known by
   now, or be the one record type that has a field named [f]. *)
and infer_field env cx (e : expr) r (f : ident) =
  field_access env cx e r (infer env cx r) f

(* The same, once [r]'s type [tr] is known. A member of [r]'s type
   isn't a field: a method has to be called, and anything else is
   written after the type. *)
and field_access env cx (e : expr) r tr (f : ident) =
  let field_of = field_in f.name in
  match op_of env tr f.name with
  | Some (td, o) ->
      let item = type_name env td.path ^ "." ^ o.oname in
      report env
        (match o.okind with
        | Method ->
            let changes =
              match o.oscheme.ty with
              | Fun ({ mode = Inout; _ } :: _, _, _, _) -> true
              | _ -> false
            in
            method_not_called f ~recv:(env.source r) ~item ~changes
        | Function | Value -> item_not_field f o.okind ~item);
      TError
  | None -> (
      let found (td : Iface.type_decl) fd tvars =
        Hashtbl.replace cx.found e.node (Field_of td.path);
        field_type ~tvars fd
      in
      let needs_record t =
        report env (needs_record f (show (printer env) t));
        TError
      in
      match reveal env.st tr with
      | TError -> TError
      | TCon (p, args) as t -> (
          let td = Hashtbl.find env.types p in
          match (record_fields td, field_of td) with
          | _, Some fd -> found td fd args
          | Some decl, None ->
              report env (no_such_field ~names:env.names f p decl);
              TError
          | None, None when td.body = Opaque None ->
              report env (opaque_private f.loc td);
              TError
          | None, None -> (
              match td.body with
              | Dep ops ->
                  report env (op_of_value ~names:env.names f p ops);
                  TError
              | _ -> needs_record t))
      | TVar _ -> (
          let what =
            match r.kind with
            | Var x -> Some (Infer_msg.Named (name_of x))
            | Call ({ kind = Var (Global p); _ }, _)
              when p <> cx.self && List.mem_assoc p env.group ->
                (* another function of the group, seen only as declared *)
                Some (Group_result p.name)
            | _ -> None
          in
          match through_type env ~known:None ~fits:field_of with
          | Found (td, fd) ->
              let t, tvars = instance env td in
              unify_at env r.loc ~found:tr ~expected:t;
              found td fd tvars
          | Nowhere
            when List.exists (fun td -> op_in f.name td <> None) env.visible
            -> (
              (* not a field, but a member: once [r] is known to have
                 its type, the first case says which kind, and how to use it *)
              match through_type env ~known:None ~fits:(op_in f.name) with
              | Found (td, _) ->
                  let t, _ = instance env td in
                  unify_at env r.loc ~found:tr ~expected:t;
                  field_access env cx e r tr f
              | Nowhere -> TError
              | Several paths ->
                  report env
                    (several_have_member ~names:env.names r.loc ?what f
                       (List.map (fun p -> (p, member_kind env f.name p)) paths));
                  TError)
          | Nowhere ->
              (* it may be in a record type the module can't name bare *)
              let elsewhere =
                Hashtbl.fold
                  (fun p td acc ->
                    if field_of td <> None then p :: acc else acc)
                  env.types []
                |> List.sort compare
              in
              report env
                (no_record_has ~names:env.names ~can_name:env.can_name ?what f
                   elsewhere);
              TError
          | Several paths ->
              report env
                (several_records_have ~names:env.names r.loc ?what f paths);
              TError)
      | t -> needs_record t)

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

(* What the `try` [m] of a `try match` passes on: the errors [errs] of
   [subject] that no arm handles, by inclusion, through a row of their
   own, which [m] fails with. With a `fail _` arm, nothing is left, and
   [m] covers nothing. *)
and pass_on env cx m subject arms errs =
  match handled_tags arms with
  | None ->
      m.hint <-
        Some
          "every error is handled here, so nothing is passed on: remove the \
           `try`"
  | Some names ->
      let rest = fresh_row env.st in
      env.kept <- (rest, cx.params) :: env.kept;
      let add r into =
        add_errors env ~loc:subject.loc ~here:"from this `match`"
          ~sources:(sources_of cx)
          ~fix:(fun _ -> "rename one of them where it comes in")
          r into
      in
      include_errors env cx ~loc:subject.loc
        (fun r into -> add (without names r) into)
        errs rest;
      include_errors env cx ~loc:subject.loc add rest cx.handler;
      m.unwrapped <- rest :: m.unwrapped;
      Option.iter (fun s -> s := Unhandled (subject.loc, rest) :: !s) cx.sources

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

(* The variables a pattern binds, each where it's bound. *)
and binders (p : pattern) =
  match p.pkind with
  | PVar b -> [ (b, p.ploc) ]
  | PCon (_, ps) | PFail (_, ps) -> List.concat_map binders ps
  | POr ps -> List.concat_map binders ps
  | PWild | PInt _ | PBool _ | PFail_any -> []

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
