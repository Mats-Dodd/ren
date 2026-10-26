(* What inference of expressions works with (infer_expr.ml and the
   modules beside it): the environment of the module being checked, with
   the constraints each group of functions leaves for the solver
   (solve.ml) to decide once the group is done, and the context of the
   expression being inferred.
   These types are shared by every part of the pass, so they're kept apart
   from any one of them. There's no .mli: it would only repeat them. *)

open Ast
open Ast.Resolved
open Types

(* What a lookup through a type found, or what else inference decided
   about an expression or pattern that a later pass needs, so it never
   decides it again (compiler.md, "What it has to do"). *)
type found =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string  (** a constructor: its type, and its name *)
  | Error_tag
      (** a tag inside `Err(...)`, written as a value or matched: one of the
          errors a [Result] holds, not a constructor *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)
  | Installs of Path.t
      (** a `with` whose item is an implementation of this dependency *)
  | Installs_handler of Path.t list
      (** a `with` whose item describes a handler of these dependencies, which
          it makes an instance of *)
  | Wraps  (** a `with` whose item is a wrapper, which its body is passed to *)
  | Handles  (** a `match` that handles errors: one with `fail` arms *)
  | Fail_arm
      (** a `fail` arm's pattern, which matches an error rather than a value *)
  | Unwraps
      (** `try r`, where [r] is a [Result]: what's in it if it's `Ok`, and if
          it's `Err`, its error again *)

(* The type arguments a use of a top-level function, a member, an
   associated value or an intrinsic picked, by the generic variables of
   [tcallee]'s scheme (Types.subst). An associated value ([tvalue]) is used
   as its result, so its type arguments are only those of the result's
   type. *)
type targs = { tcallee : Path.t; tvalue : bool; tpicked : picked }

and picked =
  | Fresh of Types.subst
      (** the variables [instantiate] put in their place: only those of the
          result's type, for a value *)
  | Group of ty
      (** a function of the group being checked, used at this type: its
          declaration's, or its own. Its variables are generic only once the
          group is done, and then what each stands for in this type is its type
          argument (Types.matching, infer_top.ml) *)

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

(* How to explain a mismatch with an expected type (Infer_report.why,
   where it's described): kept here, since a constraint can carry one. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  help_of : (Types.printer -> Types.ty -> string) option;
  labels : string -> string -> (Loc.t * string) list;
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
  mutable pending : constr list;
      (** what has to hold of the group's types and rows, which the constraint
          solver (solve.ml) decides once its bodies are checked, most recent
          first *)
  mutable forced : (Path.t * Loc.t) list;
      (** each statement that threw away a value of a type still unknown, which
          the solver made `Unit`, with the function it's in: a later mismatch at
          a call of that function points back at it *)
  mutable in_state : bool;
      (** whether the code being checked is a handler's state, which can't fail,
          for a message when something in it does *)
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
   done, when it has all of them, by the solver. [rwhat] says what needs
   it, for a message: a call, a `with`. *)
and row_due = {
  rloc : Loc.t;
  rinto : row;
  rnamed : int * string;
  rwhat : Infer_msg.user;
}

(* An operation of an implementation, `usd_to: fn(c) => ...` in a `Rates
   { ... }`: it can fail with fewer errors than its dependency declares,
   never more (deps.md, "Implementations"). Its errors [ierrs] start as
   [ideclared] with room for more, and once the group is done (when it's
   known what its calls fail with), anything more is reported and the room
   closed, by the solver. [ivalue] is what's given for it, and [inodes]
   the types of the expressions of the function it's in, for a message. *)
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
   the outside does, which is less than the body can. It's decided once
   the group is done, by the solver, when every call of the group knows
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
   once the group is done, by the solver, at [kloc]; [kpassed] are those
   added so far. *)
and copy = {
  kloc : Loc.t;
  ksrc : row;
  kdst : row;
  kwhat : Infer_msg.user;  (** what needs it, for a message: a `with` *)
  mutable kpassed : string list;
}

(* A handler: [nrow] is what its state and arms use, and [ncalls] the
   calls that add to it. That can't be a dependency it implements itself
   (the next one out is `outer`'s, stage 10). If its needs are written,
   `for N uses Console`, or it's public, which needs nothing if it says
   nothing, they're [ndeclared], and [nrow] has to be no more than that.
   It's checked once the group is done, with its function's `uses`, by the
   solver, and then a written row is closed. *)
and handler_needs = {
  nself : Path.t;
  ndeclared : string list option;
  nrow : row;
  ncalls : call list ref;
}

(* A dependency [hdep] that a function [hfn] calls inside a `with` of it
   still gets from outside, and why ([hnote]), which the solver finds as
   it decides what each `with` installs: a message that says its callers
   have to install it explains with this (infer_declared.ml). *)
and withheld = { hfn : Path.t; hdep : string; hnote : Infer_msg.withheld }

(* Something that has to hold of the group's types and rows, which can be
   decided only once every body of the group is checked: a constraint. Each
   carries where it comes from and what a message about it needs, and the
   solver (solve.ml) decides them all together, once the group is done
   (compiler.md, "The constraint solver"). *)
and constr =
  | Join of join  (** a use of a function of the group is its type *)
  | Drop of drop  (** a value thrown away is `Unit` *)
  | Value_tag of tag_pattern
      (** a tag written as a value, `Err(Right)`, is in its error set, if the
          set is one of its own *)
  | Include of inclusion  (** one row of errors is in another *)
  | Kept of row * (string * ty) list
      (** the errors an `attempt` keeps in its [Result], or a `match` with
          `fail` arms handles, with the parameters of the function and lambdas
          it's in: it holds no more than what it has once the group's error sets
          have all their tags *)
  | Tag_pattern of tag_pattern
      (** a tag matched in an error set that was still open is one of its tags
      *)
  | Unmarked of ecall * row
      (** a call that no marker covers can't fail: the row its errors went to
          ends up empty *)
  | Marker of marker
      (** a `try`, an `attempt` or a `match` with `fail` arms covers something
          that can fail *)
  | Copy of copy
      (** what an implementation needs is needed where it's used: what it learns
          later as well *)
  | Install of install
      (** a `with` that installs: its body uses no more than what it installs
          and what's installed outside it *)
  | Impl_op of impl_op
      (** an implementation's operation fails with no more than its dependency
          declares *)
  | Row_due of row_due  (** a row that a named row is added to ends in it *)
  | Own_errors of checked
      (** a function that names its own errors' row, `! ..e`, fails with it *)
  | Own_rows of checked
      (** a function that names its own `uses` row ends it in that, and one that
          declares its errors names the row a closure it calls fails with *)
  | Declared of checked
      (** a function does what it declares: it uses, and fails with, no more *)
  | Needs of handler_needs
      (** a handler needs no more than it declares, and not itself *)
  | Coerce of coerce
      (** a handler of several dependencies is taken as one of them where a
          value of its type is wanted *)

(* A value [cvalue] of type [cfound], a handler of several dependencies,
   given where a value of type [cwanted] is wanted, which wasn't known
   yet: whether it's one of those dependencies, which the handler is then
   taken as (Infer_coerce.as_one), or something else, which the handler's
   own type has to be, is decided once it's known, so it doesn't depend on
   which came first. [cas_dep] is where that's recorded, by node id, and
   [cwhy] explains a mismatch. *)
and coerce = {
  cvalue : expr;
  cfound : ty;
  cwanted : ty;
  cwhy : why;
  cas_dep : (int, Path.t) Hashtbl.t;
}

(* A function of the group, [ffn], and what checking its body found,
   [fcx]. Once the group's other constraints are decided, the rows it names
   are its own rows' ends, and what it declares it uses and fails with is
   checked against what its body does (infer_declared.ml). [fmain] says
   it's the program's `main`, a dependency of which that the runtime
   doesn't install is reported once every group is done (infer_top.ml). *)
and checked = { ffn : fn_def; fcx : ctx; fmain : bool }

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
   (by the solver), since a call of another function of the group
   learns only then what it returns. [callee] names the function, if the
   statement is a call, and [dself] the function the statement is in. *)
and drop = { dloc : Loc.t; dty : ty; callee : string option; dself : Path.t }

(* A call, and the errors its callee can fail with (errors.md, "Marking").
   Whether it can fail at all is known only once its group is done: a
   function of the group learns what it fails with only then. So each
   call is kept, and the markers' rules are checked at the end, by the
   solver. *)
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
  mutable hint : Infer_msg.try_hint option;
      (** for `try`: why it may cover nothing, for a help *)
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
   once the group is done, by the solver, which reports a tag with two
   shapes at [iloc] ([ipassed] are the names added so far). A row that
   stands for whatever a parameter fails with can't be listed, so [idst]
   ends in the same tail instead ([ilinked], once it does). *)
and inclusion = {
  iloc : Loc.t;
  isrc : row;
  idst : row;
  iparams : (string * ty) list;
      (** the parameters of the function and lambdas where it's added *)
  iwithout : string list;
      (** tags [isrc] has that aren't added: those a `try match` handles *)
  ihere : Infer_msg.origin;
      (** where a tag that comes in comes from, for a message about two shapes
          of it (Infer_rows.add_errors) *)
  isources : unit -> source list * Infer_msg.origin;
      (** where the one already there may have come from, for the same message
      *)
  ifix : string -> string;  (** the help for that message, given the tag *)
  mutable ipassed : string list;
  mutable ilinked : bool;
}

(* Something that adds to a top-level function's errors: a call its `try`
   passes on, a `fail`, a [Result] it fails with again, or the errors a
   `try match` doesn't handle. A function that writes its errors is
   checked against them (infer_declared.ml), with a label at the first of
   these that brings in an error it doesn't declare. *)
and source =
  | Passed of ecall
  | Failed of Loc.t * label
  | Unwrapped of Loc.t * row
  | Unhandled of Loc.t * row

(* What the expression being inferred can see. *)
and ctx = {
  self : Path.t;  (** the top-level function being checked *)
  locals : (int, ty) Hashtbl.t;
      (** the type of each local of the top-level function, by binder id *)
  nodes : (int, ty) Hashtbl.t;
      (** the type of each expression and pattern of the function, by node id *)
  found : (int, found) Hashtbl.t;  (** what each lookup found, by node id *)
  as_dep : (int, Path.t) Hashtbl.t;
      (** each expression that gives a handler of several dependencies where a
          value of one of their types is wanted, by node id, with that one
          (Infer_coerce.as_one) *)
  targs : (int, targs) Hashtbl.t;
      (** the type arguments of each use of a top-level function, by node id *)
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

(* A dot call that turned out to call [callee], a method of the module
   not checked yet, from [caller]. Which method `s.size()` calls is found
   only by checking it, after the call graph has put the functions in
   order, so the call graph was missing this edge: infer_top.ml adds it
   and checks the module again. *)
exception Unchecked of { caller : Path.t; callee : Path.t }

(* Does a row ending in [tail] belong to one of [params]? Then it stands
   for whatever the function passed there fails with. *)
let in_params params tail =
  List.exists (fun (_, t) -> List.mem tail (row_vars t)) params

(* The variable or named row [r] ends in, or [REmpty]. *)
let rec row_end r =
  match repr_row r with RExtend (_, rest) -> row_end rest | r -> r

(* Leave [c] for the solver, once the group is done. *)
let defer env c = env.pending <- c :: env.pending

(* Whether the error set ending in [tail] is one an `attempt` of the group
   keeps, or a `match` handles, of those met so far. *)
let kept env tail =
  List.exists
    (function Kept (k, _) -> row_tail k = Some tail | _ -> false)
    env.pending

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
