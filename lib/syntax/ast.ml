(* The abstract syntax tree: what the parser produces and every later pass
   consumes. Adding a constructor here makes the compiler point at every
   [match] that needs a new case. *)

type ident = { name : string; loc : Loc.t }

(* The tree comes in two versions, built from the same type definitions:
   the parser's, where every name is the string that was written, and
   Resolve's (resolve.ml), where every name says what it refers to. The
   type parameters say which: ['v] is a variable or function being used,
   ['b] a name being bound (by a `let`, a parameter, a loop or a pattern),
   and ['t] a type's name. [Parsed] and [Resolved] at the bottom of this
   file name the two versions.

   A type with parameters, like [('v, 'b, 't) expr], is a family of types,
   one for each choice of them; [List] works the same way, as ['a list]. *)

(* A type's name as the parser read it: `Plan`, or `stripe.Client`, a type
   of another module, with that module's alias in front. *)
type tyname = {
  tmod : ident option;  (** the module's alias, if one is written *)
  tid : ident;  (** the type's own name *)
}

(* A name used as a value, as the parser read it: a bare name, `x` or
   `double`, or a member of a type written after its type,
   `Stack.of` or `stack.Stack.of`. Resolve finds the type through scope,
   and the item in its declaration. *)
type vname = Bare of string | Item of tyname * ident

(* A type as written: `Int`, `Option<Int>`, `fn(Int) -> Bool`. *)
type 't ty =
  | TyName of 't * 't ty list  (** [Int], [Option<Int>] *)
  | TyFn of
      't ty list * 't ty option * 't errors option * 't uses option * Loc.t
      (** [fn(Int) -> Bool], and what it can fail with and uses,
          [fn(Int) -> Bool ! Bad uses Clock]; with no [->] the function returns
          [Unit] *)
  | TyImpl of {
      impl_deps : 't dep_ref list;
      impl_over : bool;
      impl_errors : 't errors option;
      impl_uses : 't uses option;
      impl_loc : Loc.t;
    }
      (** a dependency's type, whose values are implementations, and what one
          needs (deps.md, "Implementations"): [Clock uses Os]; or several joined
          with `&`, as written, an implementation of each sharing one state,
          [Clock & TestClock]. The list is never empty. The parser reads [Clock]
          alone as a [TyName], which Resolve makes a [TyImpl] with no [uses].
          [impl_over] says it goes over another implementation of them,
          [over Users] (handlers.md, "`over`"), and [impl_errors] what
          installing one can fail with, [Sql ! DbDown]: what its state and its
          `finally` fail with (handlers.md, "State that can fail to start") *)
  | TyInout of 't ty * Loc.t
      (** [&Int], a parameter of a function type that the function changes,
          [fn(&Int)], as a call passes it *)
  | TyErrors of 't errors
      (** [! Short | Frozen], an error set as a type argument, which only
          [Result<T, ! ...>] takes (errors.md, "Keeping an error") *)
  | TyTuple of 't ty list * Loc.t
      (** [(Str, Int)]: a tuple's type, of two or three (operators.md, "Tuples")
      *)
  | TyVariant of 't * ident * 't ty list
      (** [Order.Placed], a variant type: the sum, the variant's name and the
          sum's type arguments, written after the variant, [Tree.Node<Int>]
          (compiler.md, "Data stage", "Variant types") *)

(* What a function can fail with, written after `!` (errors.md):

     ! Short(account: AccountId, by: Money) | Frozen(AccountId) | Refusal

   Each error is a tag, with an optional payload, or a named error set,
   `type Refusal = ! ...`, which stands for all of its tags. Tags are
   structural: they aren't declared anywhere, so a tag resolves to nothing,
   only the types in its payload do. The parser reads a bare name, like
   `Refusal` or `Frozen`, as a tag; Resolve makes it the set when a named
   error set of that name is in scope. A name written after a module,
   `bank.Refusal`, is always a set. *)
and 't errors = {
  errs : 't error list;
  etail : ident option;
      (** a named row at the end, [..e]: whatever the function, or the
          implementation, it's in fails with (see [uses]) *)
  eloc : Loc.t;
}

and 't error =
  | Tag of ident * 't payload list
      (** [Short(account: AccountId, by: Money)]; [Frozen] has no payload *)
  | Set of 't  (** a named error set: [Refusal], [bank.Refusal] *)

(* A payload's field: its name is optional, and only documents it. A tag is
   its name and its payload's types, in order. *)
and 't payload = { payload_name : ident option; payload_ty : 't ty }

(* What a function, a function type or an implementation uses, after
   `uses`: dependencies, `Clock, store.Users`, and at the end, a named row,
   `..d`. A signature names a row where an implementation is kept rather
   than only installed: `c: Clock uses ..d` stands for whatever `c` needs,
   and every `..d` in the signature for the same (deps.md,
   "Implementations"). An error set names one the same way, `! ..e`. A
   block's type never names one: a block is only called, so what it does
   is what the call it's passed to does (resolve.ml). *)
and 't uses = { deps : 't dep_ref list; dtail : ident option; uloc : Loc.t }

(* A dependency where one is named, in a `uses`, an implementation's type,
   after a handler's `for` or a `with`'s `as`: [Clock], [store.Users], or
   an instance of a generic one, its type arguments written, [Chan<Int>]
   (foundations.md, decision 6). *)
and 't dep_ref = { dep : 't; dargs : 't ty list }

(* [And] and [Or] are `&&` and `||`, which evaluate their right side only
   when the left doesn't already decide the answer (lower.ml makes them
   `if`s). [Orelse] is `x orelse e`: the value in the `Option` [x], or else
   [e], which is evaluated only if [x] is `None`, and is usually a `fail`.
   [Wrap_add], [Wrap_sub] and [Wrap_mul] are `+%`, `-%` and `*%`, `Int`'s
   wrapping arithmetic (sized.ml). *)
type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
  | Wrap_add
  | Wrap_sub
  | Wrap_mul
  | Eq
  | Neq
  | Lt
  | Le
  | Gt
  | Ge
  | And
  | Or
  | Orelse

(* [Neg] is `-x`, [Not] is `not b`. *)
type unop = Neg | Not

(* A constructor as written: `Red` alone, or after the type it's in,
   `Light.Red`, which can have its module in front, `billing.Plan.Free`.
   Resolve finds the type, if one is written; the constructor itself is
   found through it, by inference (module-build.md, "Found through a
   type"). *)
type 't ctor_ref = {
  qual : 't option;  (** the type, if written *)
  name : ident;  (** the constructor's name *)
}

(* Patterns, the left-hand side of a `match` arm. [pnode] numbers it along
   with the expressions of its function (see [expr] below). *)
type ('b, 't) pattern = {
  pkind : ('b, 't) pattern_kind;
  ploc : Loc.t;
  pnode : int;
}

and ('b, 't) pattern_kind =
  | PWild  (** [_] *)
  | PVar of 'b  (** a lowercase name: matches anything, binds it *)
  | PInt of Int64.t
  | PBool of bool
  | PCon of 't ctor_ref * ('b, 't) pattern list
      (** [Free], [Pro(seats)], [Plan.Free] *)
  | PCon_named of 't ctor_ref * ('b, 't) fields
      (** [Shape.Rect { w, .. }]: a by-name constructor, its fields named
          (compiler.md, "Data stage", "By-name variants"). The parser makes
          one only of a constructor written after its type; [Rect { w, .. }]
          is a [PRecord] until Resolve finds [Rect] isn't a type *)
  | PFail of ident * ('b, 't) pattern list
      (** [fail Short(_, by)]: an error, destructured. A `fail` pattern is a
          whole arm's, never part of another pattern *)
  | PFail_any  (** [fail _]: any error *)
  | POr of ('b, 't) pattern list
      (** [Pro(n) | Team(n)], [fail Short(_, _) | fail Frozen(_)]: any of
          them, each binding the same names (compiler.md, "Data stage",
          "Or-patterns"). `fail` patterns combine only with each other *)
  | PAs of ('b, 't) pattern * 'b
      (** [Pro(n) as old]: what the pattern matches, the whole of it bound
          to the name too. It binds looser than `|`: [A | B as x] names the
          whole. Never of a `fail` pattern *)
  | PTuple of ('b, 't) pattern list
      (** [(k, v)]: a tuple of two or three, taken apart *)
  | PRecord of 't option * ('b, 't) fields
      (** [{ id, lines: ls, .. }], a record of the type matched, or [User {
          id, .. }], of the type named (compiler.md, "Data stage", "Record
          patterns") *)
  | PFail_in of 'b
      (** [fail on], where [on] is a parameter of type `Tags`: an error whose
          tag is one of those it was given, binding nothing (compiler.md,
          "`over any` and `retry`"). The parser reads it as a [PFail] of no
          payload, which Resolve makes this when [on] is such a parameter *)

(* A record pattern's fields, in the order written: each a name and its
   pattern, a punned one, `{ id }`, a [PVar] of its name; and whether it
   ends in `..`, which leaves out the rest. *)
and ('b, 't) fields = {
  fpats : (ident * ('b, 't) pattern) list;
  rest : bool;
}

(* How a parameter is passed: read-only (the default), or [inout], which
   updates the caller's value. *)
type mode = Read | Inout

(* How a block parameter's block may run (foundations.md, decision 2,
   rule B): only during the call, on the caller's task, the default;
   [Concurrent], on several tasks at once during the call, `f: concurrent
   fn(T) -> U`; or [Spawned], as a task until its scope ends, `body:
   spawned fn()`. Written only on a named function's block parameter. *)
type block_mode = Ordinary | Concurrent | Spawned

(* A parameter's default, `max: Int = 64`: a literal, a negative number
   among them (compiler.md, "Stage 11a", "The surface"). A call may leave
   the parameter out, and Lower fills it in. *)
type literal = LInt of Int64.t | LFloat of float | LBool of bool | LStr of string

(* A parameter of a function or lambda; its type may be left out. Its
   default, if it has one, is the literal, where it's written, and a node
   of its own (an [expr]'s [node]), at which its type is checked. *)
type ('b, 't) param = {
  pname : 'b;
  pty : 't ty option;
  pmode : mode;
  pblock : block_mode;
  pdefault : (literal * Loc.t * int) option;
}

(* [node] numbers the expressions and patterns of one top-level function,
   so later passes can say things about a particular expression. *)
type ('v, 'b, 't) expr = {
  kind : ('v, 'b, 't) expr_kind;
  loc : Loc.t;
  node : int;
}

and ('v, 'b, 't) expr_kind =
  | Int of Int64.t
  | Float of float  (** [1.5]: a literal's spelling says its type *)
  | Bool of bool
  | Str of string  (** ["Ren"], its escapes undone *)
  | Interp of ('v, 'b, 't) piece list
      (** an interpolated string, the text and holes of `"jobs/\{job}"` in
          order: each hole goes through its type's `show`, and the pieces are
          joined with `+`, left to right (lower.ml; strings.md, "Building
          strings") *)
  | Unit  (** [()] *)
  | Var of 'v
      (** a local variable, a top-level function, or a member written after its
          type, [Stack.of] *)
  | Unop of unop * ('v, 'b, 't) expr * int
  | Binop of binop * ('v, 'b, 't) expr * ('v, 'b, 't) expr * int
      (** [a + b]. An operator is a method of its left side's type, `a.add(b)`
          (operators.md), and the [int] numbers that method's use, as a node of
          its own, as a [with_link]'s [knode] does: what inference found it to
          be, and the type it's used at, are recorded there. [-a] is [Unop]'s *)
  | If of ('v, 'b, 't) expr * ('v, 'b, 't) expr * ('v, 'b, 't) expr option
      (** with no [else], the [if] is [Unit] *)
  | Call of ('v, 'b, 't) expr * ('v, 'b, 't) expr list
      (** [f(x)], [make()(x)], [handlers.on_click()] *)
  | Lambda of ('b, 't) param list * ('v, 'b, 't) expr  (** [fn(x) => x + 1] *)
  | Block of ('v, 'b, 't) stmt list * ('v, 'b, 't) expr
      (** statements, then the block's value *)
  | Con of 't ctor_ref * (ident option * ('v, 'b, 't) expr) list
      (** a constructor: [Pro(5)] or [Plan.Pro(5)]; [Pro(seats: 5)] parses,
          and inference refuses it *)
  | Con_named of 't ctor_ref * (ident * ('v, 'b, 't) expr) list
      (** a by-name constructor, [Shape.Rect { w: 2, h: 3 }], its fields in
          the order written, punned or not, as a record literal's. The parser
          makes one only of a constructor written after its type; [Rect { w:
          2, h: 3 }] is a [Record] until Resolve finds [Rect] isn't a type
          (compiler.md, "Data stage", "By-name variants") *)
  | Record of 't option * (ident * ('v, 'b, 't) expr) list
      (** [User { id: 1 }], [rows.Row { id: 1 }], or [{ id: 1 }] with the type
          left out *)
  | Update of {
      target : 't target option;
      base : ('v, 'b, 't) expr;
      fields : (ident * ('v, 'b, 't) expr) list;
    }
      (** [{ ..order, status: Paid }]: a record with these fields, each given
          one in the order written, punned or not, and the rest taken from
          [base]. Its type is [target]'s, [Shipped { ..p, carrier }], or else
          the base's (compiler.md, "Data stage", "Record update") *)
  | Field of ('v, 'b, 't) expr * ident  (** [user.plan] *)
  | Match of ('v, 'b, 't) expr * ('v, 'b, 't) arm list
  | Array of ('v, 'b, 't) expr list  (** [[1, 2, 3]] *)
  | Tuple of ('v, 'b, 't) expr list
      (** [(k, v)]: two or three values passed together, taken apart only by
          patterns (operators.md, "Tuples") *)
  | Index of ('v, 'b, 't) expr * ('v, 'b, 't) expr  (** [xs[i]] *)
  | Slice of ('v, 'b, 't) expr * ('v, 'b, 't) expr * ('v, 'b, 't) expr
      (** [xs[a..b]]: the elements of an [Array], or the bytes of a [Str] or
          [Bytes], from [a] up to, but not including, [b], a value of the same
          type (foundations.md, decision 17). After [&], a place: that range of
          the array, which the call replaces *)
  | Ref of ('v, 'b, 't) expr
      (** [&scores]: an argument the call changes, or the array a [for] loop
          changes; or, before a method call, [&s.push(1)], the receiver the call
          changes (see [changed_receiver]) *)
  | Assign of {
      target : ('v, 'b, 't) expr;
      op : binop option;
      value : ('v, 'b, 't) expr;
      onode : int;  (** the method [op] uses, as [Binop]'s *)
    }  (** [x = 1], [user.plan = Free], [xs[i] += 1]; the target is a place *)
  | For of {
      index : ('b, 't) pattern option;
          (** [i] in [for i, x in xs]: where each element is, counting from 0,
              a name or [_] *)
      pat : ('b, 't) pattern;
          (** a name, [x], or a tuple taken apart, [(k, v)] *)
      over : ('v, 'b, 't) over;
      body : ('v, 'b, 't) expr;
    }
      (** [for x in xs], [for (k, v) in m], [for i in 0..n], or [for p in &ps]
          to change each element, and [for i, x in xs] or [for i, p in &ps]
          with each one's index too; or [for x in &c] over a cursor, a value
          whose type has [next(inout self) -> Option<T>], which advances [c]
          itself, and [for x in c], which advances a copy *)
  | While of { cond : ('v, 'b, 't) expr; body : ('v, 'b, 't) expr }
      (** [while c] and its body, indented below: the body runs again while [c]
          holds *)
  | Break
      (** [break]: leaves the innermost `while` or `for` it's written in, never
          a block's (resolve.ml) *)
  | Todo
      (** [todo]: code still to write, of any type, which panics where it's
          reached, "reached a `todo`"; what a `match`'s missing arms are
          printed with (compiler.md, "Data stage") *)
  | Fail of ident * (ident option * ('v, 'b, 't) expr) list
      (** [fail Short(self.id, by)]: stop with that error. A tag isn't a value,
          so it's only ever written here, after `!`, in a pattern, and as the
          error an `Err(...)` holds, where it's a [Con] that inference tells
          apart (infer_rows.ml, [err_row]) *)
  | Try of ('v, 'b, 't) expr
      (** [try e]: pass on the errors of every call in [e]. [try match] is a
          [Try] of a [Match] *)
  | Attempt of ('v, 'b, 't) expr  (** [attempt e]: its outcome, as a [Result] *)
  | Pipe of { subject : ('v, 'b, 't) expr; step : ('v, 'b, 't) expr }
      (** [order |> try validate]: one link of a chain (language.md §8), its
          [subject] the chain before it, so a chain of three is two nested
          [Pipe]s. [step] is the step's call with a [Piped] for its first
          argument, `validate(_)`, inside the step's own [Try] or [Attempt]
          if it's marked: [x |> f(a)] is [f(x, a)], checked as that call,
          but [subject] is evaluated first, with markers of its own, and
          the step's marker covers only the step's call (compiler.md,
          "Services stage", "The pipe (step 1)") *)
  | Piped
      (** the value of the [Pipe]'s subject, the first argument of its step's
          call: only ever there *)
  | With of { items : ('v, 'b, 't) with_item list; body : ('v, 'b, 't) expr }
      (** [with a, b in body] (deps.md, "`with`"): a set of items, each
          installed once around [body], in an order inference works out
          (handlers.md, "A `with` is a set"). An item is an implementation; a
          wrapper, like `retry(3)`, is called instead, `try retry(3) fn() =>
          body` *)
  | Handler of {
      deps : 't dep_ref list;
          (** the dependencies after `for`, or after `over`, in order *)
      over : bool;
          (** declared `over` them, in front of another implementation of them,
              which it reaches with `next` (handlers.md, "`over`") *)
      any : bool;
          (** declared `over any`: [deps] is empty, and its one arm, `call =>
              body`, runs for every operation of whatever dependency it's
              installed over (foundations.md, decision 7) *)
      fails : 't errors option;
          (** what installing it is written to fail with, after `!`: what its
              state and its `finally` can fail with *)
      needs : 't uses option;
          (** what it's written to need, after the `for` list's `uses` *)
      state : ('v, 'b, 't) stmt list;
          (** its `var`s and `let`s, and its `finally`s ([Finally]) *)
      arms : ('v, 'b, 't) handler_arm list;
    }
      (** a handler's body (deps.md, "Implementations"), the whole body of the
          function a `handler` declaration is (see [is_handler]): its state,
          then an arm for each operation of each dependency it implements.
          Calling the function describes the handler, and each `with` that
          installs it makes a fresh instance, running [state] then *)
  | Inline_handler of ('v, 'b, 't) expr
      (** [handler fn(req) => respond(req, body)]: a handler for a dependency of
          one operation, its arm the [Lambda] it holds, which captures what it
          reads by copy (foundations.md, decision 3). Which dependency is found
          from where it's written; lowering lifts it to a handler declared at
          the top of its module (lower.ml) *)
  | Assert of ('v, 'b, 't) expr
      (** [assert e]: a panic if [e] is false, which shows both sides of an
          [a == b] (deps.md, "`assert`") *)
  | Named of ident * ('v, 'b, 't) expr
      (** [on: Flaky], an argument of a call passed by its parameter's name,
          which only a parameter of type `Tags` is (compiler.md, "`over any`
          and `retry`"). Only ever an argument of a [Call] *)
  | Tag_set of 't errors
      (** [Flaky | Broken], the tags a `Tags` argument is given: tag names,
          without payloads, or named error sets. Only ever a [Named]'s value *)

(* A piece of an interpolated string: text, its escapes undone, or a
   hole's expression. *)
and ('v, 'b, 't) piece = Lit of string | Hole of ('v, 'b, 't) expr

(* What an update builds, when it's written: the record type named, or a
   by-name constructor, [Placed { ..draft, id }], which builds its sum. *)
and 't target = Into_type of 't | Into_ctor of 't ctor_ref

(* An item of a `with`: an implementation, or a chain of them joined by
   `over`, [chain], the top first, each over the next:
   `cached(ttl) over counted() over pg_users(pool)`. [under] are the
   dependencies the bottom goes over when the chain ends in their names,
   `slow_clock(2) over Clock`: whatever implements them outside the `with`
   (handlers.md, "Installing one"); otherwise []. *)
and ('v, 'b, 't) with_item = {
  chain : ('v, 'b, 't) with_link list;
  under : 't dep_ref list;
  alias : 't dep_ref option;
      (** what it's installed as, after `as`: an alias of the dependency it
          implements, `with queue() as Jobs`, or that dependency written out,
          `as Chan<Int>` (compiler.md, "Generic dependencies") *)
  iloc : Loc.t;  (** the whole item *)
  from : via list;
      (** the wirings it was flattened from, innermost first, the last the
          one the `with` names: [] as parsed, and for every item a `with`
          writes itself (resolve.ml, "Wirings"). What the `with` calls is a
          function Resolve made of the item's link, `live$1(url)`, which
          inference shows as the wiring writes it, `pg_db(url)` *)
}

(* One wiring an item came through (language.md §5): its name, as written
   where it's listed, `live` or `app.live`, where it's declared, and what
   it provides, which is all a `with`'s body may call of what it
   installs. *)
and via = { wiring : string; declared : Loc.t; provides : Path.t list }

(* One implementation of an item's chain, [link]; [knode] is the node
   inference records what it installs at. *)
and ('v, 'b, 't) with_link = { link : ('v, 'b, 't) expr; knode : int }

(* An arm of a handler, `usd_to(c) => ...`: [arm_op] is the operation, a
   bare name as parsed and a [Dep_op] once resolved, and [arm_impl] the
   lambda that implements it, which can change the handler's state. *)
and ('v, 'b, 't) handler_arm = {
  arm_op : 'v;
  arm_name : ident;
  arm_impl : ('v, 'b, 't) expr;
}

and ('v, 'b, 't) arm = {
  arm_pat : ('b, 't) pattern;
  arm_guard : ('v, 'b, 't) expr option;
  arm_body : ('v, 'b, 't) expr;
}

(* What a [for] loop goes over: each element of an array, a [Map] or a
   [Set], or the [Int]s of a range, [0..n], from the first up to, but not
   including, the second (operators.md, "Ranges"). A range is written only
   here: it isn't a value. *)
and ('v, 'b, 't) over =
  | Each of ('v, 'b, 't) expr
  | Range of ('v, 'b, 't) expr * ('v, 'b, 't) expr

and ('v, 'b, 't) stmt =
  | Let of {
      name : 'b;
      ty : 't ty option;
      value : ('v, 'b, 't) expr;
      mut : bool;
    }  (** [let], or [var] when [mut] *)
  | Let_pattern of {
      pat : ('b, 't) pattern;
      value : ('v, 'b, 't) expr;
      else_ : ('v, 'b, 't) expr option;
    }
      (** [let (k, v) = pair], [let { id, .. } = order]: taken apart by a
          pattern that always matches; or, with [else_], [let Team(n) = p
          else fail NotTeam], by one that might not, the [else_] run, and
          leaving, when it doesn't (compiler.md, "Data stage", "`let ...
          else`"). Exhaust checks which *)
  | Expr of ('v, 'b, 't) expr
  | Finally of ('v, 'b, 't) expr
      (** [finally(r) => ...], a lambda of one parameter: it covers what comes
          after it: it's given what that ends in, `Ok` of its value or `Err` of
          its error, and gives the value in its place (handlers.md,
          "`finally`"). Only among a handler's state, where it covers the state
          after it and the body of each `with` that installs it, or among the
          statements of an operation's arm, where it covers the rest of the arm
          (resolve.ml) *)

(* Type declarations. *)

type 't field = { field_name : ident; field_ty : 't ty }
(* A constructor as it's declared: [Free], [Flat(off: Money)] or
   [Flat(Money)], with one field, positional, whose name, if written, only
   documents it (an unwritten one is [""]); or [Rect { w: Int, h: Int }],
   by name, [ctor_named] (compiler.md, "Data stage", "By-name variants"). *)
type 't ctor = {
  ctor_name : ident;
  ctor_fields : 't field list;
  ctor_named : bool;
}

type 't type_body =
  | Fields of 't field list  (** a record: [{ id: Int, plan: Plan }] *)
  | Ctors of 't ctor list  (** a sum type: [| Free | Pro(seats: Int)] *)
  | Opaque of { rep : 't ty; numeric : Loc.t option }
      (** [opaque Int]: a type of its own, represented as the type written,
          which only its module can see *)
  | Opaque_fields of 't field list
      (** [opaque { id: Int, balance: Money }]: a record only its module can see
          as one, to make, read and change (module-build.md, "Private unless
          `pub`"); anywhere else it's opaque *)
  | Errors of 't errors
      (** [! Short(by: Money) | Frozen]: a named error set. It isn't a type of
          values: it's only written after `!` *)
  | Dep of 't field list
      (** a dependency's operations, [now: fn() -> Time], each a function type
          (deps.md, "Declaring one"). A value of the type is an implementation,
          a record of them *)
  | Dep_alias of 't dep_ref
      (** [dep Jobs = Chan<Job>]: a dependency of its own, with the operations
          of the one it names, at the types it gives (compiler.md, "Generic
          dependencies"). It takes no type parameters *)
  | Builtin
      (** [builtin]: a type built into the compiler, [Array<T>], whose members
          written here join its built-in ones. Only the prelude's source can
          write one (Parser.parse_program's [prelude]) *)

type ('v, 'b, 't) fn_def = {
  pub : bool;
  name : ident;
  tparams : ident list;  (** the [T] in [fn id<T>(x: T) -> T] *)
  tneeds : (string * ident) list;
      (** what's written that a type parameter needs, after its name,
          [T has eq]: the parameter's name, and each requirement. A function's
          are found in its body, so they needn't be written; a handler's of a
          generic dependency say so where they're declared *)
  params : ('b, 't) param list;
  ret : 't ty option;
  errors : 't errors option;  (** what it can fail with, after `!` *)
  uses : 't uses option;
      (** the dependencies after `uses`, if it's written: [Clock], or another
          module's, [store.Users] *)
  body : ('v, 'b, 't) expr;
  owner : ident option;
      (** the type it's a member of, [Stack] for [push]; [None] for a top-level
          function *)
  overload : int;
      (** which of its type's members of its name it is, counting from 0 in
          source order: an operator can be written once for each type on its
          right, `sub(self, t: Time)` and `sub(self, d: Duration)`, and nothing
          else more than once (operators.md). 0 for anything else *)
  test : bool;
      (** test code: a test item, [test fn], or a function made of a test, a
          group or a group's run (test_items.ml). It sees only what an importer
          sees, only test code can call it, and `ren run` leaves it out *)
  loc : Loc.t;
}

(* A member of a type (module-build.md, "Methods and operators
   live on the type"):

     pub type Stack<T> = opaque { items: Array<T> }
       pub fn push(inout self, x: T) = &self.items.push(x)
       pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
       pub let empty: Stack<T> = Stack { items: [] }

   A function whose first parameter is `self` is a method; one without is
   an associated function, `Stack.of(...)`. An associated value, `let`, is
   kept as a function of no parameters whose body is the value, so every
   pass checks it as one; only [op_kind] tells them apart.

   The parser names each item as it's written, `push`, and gives it its
   type as its [owner], so its path ([fn_path]) is a member's (path.ml),
   which passes after it know apart from a top-level `push`. Resolve puts
   the type's parameters first in its [tparams], and gives `self` its
   type, `Stack<T>`. *)
type op_kind = Op_fn | Op_value
type ('v, 'b, 't) op = { op_kind : op_kind; op_fn : ('v, 'b, 't) fn_def }

type ('v, 'b, 't) type_def = {
  type_pub : bool;  (** [pub type ...]: other modules can use it *)
  type_name : ident;
  type_params : ident list;  (** the [T] in [Option<T>] *)
  type_body : 't type_body;
  type_ops : ('v, 'b, 't) op list;  (** its members, in source order *)
}

(* An import, at the top of a file: `import billing/stripe`,
   `import billing/stripe as pay`, `import shop/plan.{Plan, User}`. Its
   names are only strings and locations, so it's the same in both versions
   of the tree. *)
type import = {
  segments : ident list;  (** [billing], [stripe] *)
  path : string;  (** the module: [billing/stripe] *)
  path_loc : Loc.t;  (** where the module's path is written *)
  alias : ident;
      (** what the module is called here: the name after [as], or else the
          path's last segment *)
  names : ident list;
      (** the types imported by name: the [Plan] in [.{Plan}] *)
  iloc : Loc.t;  (** the whole import *)
}

(* Tests (deps.md, "Tests"), which sit next to the code they test:

     test "a deposit is stamped" uses Clock =
       body

     pub group clock_conforms(c: Clock) with c =
       test "instant never goes backwards" =
         ...

     group "frozen" = clock_conforms(Clock.frozen(Time.epoch))

   A test's `uses` lists the built-in dependencies it gets the real
   implementation of, rather than the test one. A group is a function of
   its parameters whose tests each run inside its `with`, and a group's
   run, `group "label" = g(args)`, runs each of them with those arguments.
   None of them reaches Resolve: Test_items makes each into ordinary
   functions first (test_items.ml). *)
type ('v, 'b, 't) test_def = {
  test_name : string;
  test_loc : Loc.t;  (** where its name is written *)
  test_uses : 't uses option;
  test_body : ('v, 'b, 't) expr;
}

type ('v, 'b, 't) testing =
  | Test of ('v, 'b, 't) test_def
  | Group of {
      group_pub : bool;
      group_name : ident;
      group_params : ('b, 't) param list;
      group_with : ('v, 'b, 't) with_item list;
          (** installed around each test, as a `with`'s items are *)
      group_tests : ('v, 'b, 't) test_def list;
    }
  | Run_group of {
      run_label : string;
      run_loc : Loc.t;  (** where its label is written *)
      run_call : ('v, 'b, 't) expr;  (** [g(args)] *)
    }

(* A wiring (language.md §5): a named set of `with` items, which a `with`
   lists by name, flattened there into its items:

     pub wiring live(url: Str) provides Users uses Console ! DbDown =
       pg_db(url), console_audit(), db_users()

   [provides] is all the body of a `with` that lists it may call of what
   it installs; [wuses] and [werrors] are what it needs from outside and
   fails to start with, written for a `pub` one. None reaches inference:
   Resolve makes each a function for each link of its items, and one its
   own `with` is checked in (resolve.ml, "Wirings"). *)
type ('v, 'b, 't) wiring_def = {
  wpub : bool;
  wname : ident;
  wparams : ('b, 't) param list;
  provides : 't dep_ref list;
  wuses : 't uses option;
  werrors : 't errors option;
  witems : ('v, 'b, 't) with_item list;
  wloc : Loc.t;  (** the whole declaration *)
}

type ('v, 'b, 't) item =
  | Fn of ('v, 'b, 't) fn_def
  | Type of ('v, 'b, 't) type_def
  | Import of import
  | Testing of ('v, 'b, 't) testing
  | Wiring of ('v, 'b, 't) wiring_def
      (** only as parsed: Resolve makes each functions (see [wiring_def]) *)

type ('v, 'b, 't) program = ('v, 'b, 't) item list

(* Every function of a program, its types' members
   included, in source order. *)
let functions (prog : ('v, 'b, 't) program) =
  List.concat_map
    (function
      | Fn f -> [ f ]
      | Type td -> List.map (fun o -> o.op_fn) td.type_ops
      | Import _ | Testing _ | Wiring _ -> [])
    prog

(* The path of [f], declared in module [home]: a member's is its type's,
   and which member it is (path.ml). *)
let fn_path home (f : ('v, 'b, 't) fn_def) =
  match f.owner with
  | Some t -> Path.member_n (Path.make home t.name) f.name.name f.overload
  | None -> Path.make home f.name.name

(* How [f] is written in its own module, for a message: `Stack.push` for a
   member, after its type. *)
let fn_name (f : ('v, 'b, 't) fn_def) =
  match f.owner with
  | Some t -> t.name ^ "." ^ f.name.name
  | None -> f.name.name

(* Whether [f]'s signature is written out in full, so that its declaration
   says everything about its type: it's public, so no `->` means Unit and
   no `uses` means none, and every parameter has a type (once resolved, a
   method's `self` has its type's). *)
let spelled (f : ('v, 'b, 't) fn_def) =
  f.pub && List.for_all (fun p -> p.pty <> None) f.params

(* Whether [f] is a `handler` declaration: a function of its parameters
   whose body is a [Handler], and whose result describes the handler,
   `counting_rates(r)`. Its type is its dependency's, if it implements one,
   or the type that lists them, `Rates & RateCalls`, if it implements
   several. *)
let is_handler (f : ('v, 'b, 't) fn_def) =
  match f.body.kind with Handler _ -> true | _ -> false

(* `&s.push(1)`: a method call whose `&` marks the receiver it changes,
   as opposed to `&xs`, a place passed `inout`. A call's result is never a
   place, so the two can't be confused (module-build.md, "Methods and
   operators live on the type"); mut.ml makes sure the call is one with a
   receiver, `x.m(...)`. *)
let changed_receiver (e : ('v, 'b, 't) expr) =
  match e.kind with
  | Ref ({ kind = Call _; _ } as call) -> Some call
  | _ -> None

(* The implementations of a `with`'s items, in source order. *)
let with_links items =
  List.concat_map (fun i -> List.map (fun l -> l.link) i.chain) items

(* The character literals, `'é'`, by where each is, as each is written:
   an [Int] to everything after the lexer (lexer.ml, [lex_char]), but a
   non-ASCII one can't be stored in a `UInt8` (Infer_expr.stored), and
   code shown in a help is shown as written ([source]). The lexer forgets
   a file's when it reads the file again. *)
let char_literals : (Loc.t, string) Hashtbl.t = Hashtbl.create 16

(* The holes' expressions among an interpolated string's pieces. *)
let holes ps = List.filter_map (function Hole e -> Some e | Lit _ -> None) ps

(* The expressions directly inside [e], in source order: a statement's
   value (and a `let ... else`'s `else`), a guard and an arm's body, a
   handler's state and arms too. *)
let children (e : ('v, 'b, 't) expr) =
  let stmt = function
    | Let { value; _ } -> [ value ]
    | Let_pattern { value; else_; _ } -> value :: Option.to_list else_
    | Expr e | Finally e -> [ e ]
  in
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break | Todo | Tag_set _
  | Piped ->
      []
  | Interp ps -> holes ps
  | Unop (_, a, _)
  | Field (a, _)
  | Ref a
  | Lambda (_, a)
  | Inline_handler a
  | Named (_, a)
  | Try a
  | Attempt a
  | Assert a ->
      [ a ]
  | Binop (_, a, b, _)
  | Index (a, b)
  | Assign { target = a; value = b; _ }
  | Pipe { subject = a; step = b } ->
      [ a; b ]
  | Slice (a, lo, hi) -> [ a; lo; hi ]
  | If (c, t, f) -> c :: t :: Option.to_list f
  | Call (f, args) -> f :: args
  | Array xs | Tuple xs -> xs
  | For { over = Each iter; body; _ } -> [ iter; body ]
  | For { over = Range (lo, hi); body; _ } -> [ lo; hi; body ]
  | While { cond; body } -> [ cond; body ]
  | Con (_, args) | Fail (_, args) -> List.map snd args
  | Record (_, fields) | Con_named (_, fields) -> List.map snd fields
  | Update { base; fields; _ } -> base :: List.map snd fields
  | Block (stmts, last) -> List.concat_map stmt stmts @ [ last ]
  | Match (s, arms) ->
      s
      :: List.concat_map
           (fun a -> Option.to_list a.arm_guard @ [ a.arm_body ])
           arms
  | With { items; body } -> with_links items @ [ body ]
  | Handler { state; arms; _ } ->
      List.concat_map stmt state @ List.map (fun a -> a.arm_impl) arms

(* ---- names, once resolved ----

   What Resolve (resolve.ml) finds each name refers to. *)

(* A local name: a variable, a parameter, a loop variable or a name bound
   by a pattern. [id] tells it apart from every other local of the same
   top-level function, even one with the same name. *)
type binder = {
  id : int;  (** numbered per top-level function *)
  ident : ident;  (** the name, where it's bound *)
  bound : bound;
  depth : int;  (** how many lambdas deep it's bound *)
}

and bound =
  | By_let
  | By_var
  | By_param  (** a parameter of a top-level function *)
  | By_inout  (** an [inout] parameter *)
  | By_lambda  (** a lambda's parameter *)
  | By_loop  (** [x] in [for x in xs] *)
  | By_index  (** [i] in [for i, x in xs], where each element is *)
  | By_ref_loop  (** [p] in [for p in &ps], which changes each element *)
  | By_pattern

(* A type's name: a declared type, or the [i]th type parameter in scope
   (of the type being declared, or of the function). *)
type tname = { tref : tref; tloc : Loc.t }
and tref = Named of Path.t | Param of int

(* A name used as a value. *)
type name =
  | Local of binder
  | Global of Path.t
      (** a top-level function, or a function among a type's members:
          [Stack.push] *)
  | Global_value of Path.t
      (** an associated value, [Stack.empty]: made once, when the program starts
      *)
  | Intrinsic of Intrinsic.t
      (** a function built into the compiler: [show], or a method, [Array.push]
      *)
  | Dep_op of Path.t * string
      (** an operation of the dependency at the path, [Clock.now]: calling it
          calls the implementation installed where it's called *)
  | Next_op of Path.t * string
      (** inside a handler declared `over` the dependency at the path, an
          operation of the implementation it's over, [next.get]: only ever
          called (handlers.md, "`next`") *)
  | Call_op of string
      (** inside the arm of a handler `over any`, what its call is used
          through: ["forward"], only ever called, `call.forward()`; ["args"]
          and ["name"], `call.args` and `call.name` (compiler.md, "`over any`
          and `retry`") *)
  | Assoc_value of tref * string
      (** [zero] or [one] of a type that has it without declaring it: of a type
          parameter, [T.zero], whatever the function's given for [T] has
          (operators.md, "Generic code"); of [Int] or [Float]; or a `with
          numeric` type's [zero] *)

(* A record pattern's fields as they're written, [show] writing each
   field's pattern, and a punned one alone: `{ id, lines: ls, .. }`. *)
let show_fields show (fs : ('b, 't) fields) =
  let field ((f : ident), q) =
    let shown = show q in
    if shown = f.name then f.name else f.name ^ ": " ^ shown
  in
  "{ "
  ^ String.concat ", "
      (List.map field fs.fpats @ if fs.rest then [ ".." ] else [])
  ^ " }"

(* An alternative of an or-pattern as it's written, [show] writing it: in
   parentheses if it's an `as`, which would otherwise name the whole. *)
let or_alt show (p : ('b, 't) pattern) =
  match p.pkind with PAs _ -> "(" ^ show p ^ ")" | _ -> show p

module Parsed = struct
  type nonrec ty = tyname ty
  type nonrec errors = tyname errors
  type nonrec uses = tyname uses
  type nonrec error = tyname error
  type nonrec payload = tyname payload
  type nonrec ctor_ref = tyname ctor_ref
  type nonrec pattern = (ident, tyname) pattern
  type nonrec fields = (ident, tyname) fields
  type nonrec param = (ident, tyname) param
  type nonrec expr = (vname, ident, tyname) expr
  type nonrec expr_kind = (vname, ident, tyname) expr_kind
  type nonrec arm = (vname, ident, tyname) arm
  type nonrec handler_arm = (vname, ident, tyname) handler_arm
  type nonrec with_item = (vname, ident, tyname) with_item
  type nonrec with_link = (vname, ident, tyname) with_link
  type nonrec stmt = (vname, ident, tyname) stmt
  type nonrec over = (vname, ident, tyname) over
  type nonrec field = tyname field
  type nonrec ctor = tyname ctor
  type nonrec op = (vname, ident, tyname) op
  type nonrec type_def = (vname, ident, tyname) type_def
  type nonrec fn_def = (vname, ident, tyname) fn_def
  type nonrec item = (vname, ident, tyname) item
  type nonrec test_def = (vname, ident, tyname) test_def
  type nonrec testing = (vname, ident, tyname) testing
  type nonrec wiring_def = (vname, ident, tyname) wiring_def
  type nonrec program = (vname, ident, tyname) program
end

module Resolved = struct
  type nonrec ty = tname ty
  type nonrec errors = tname errors
  type nonrec uses = tname uses
  type nonrec error = tname error
  type nonrec payload = tname payload
  type nonrec ctor_ref = tname ctor_ref
  type nonrec pattern = (binder, tname) pattern
  type nonrec fields = (binder, tname) fields
  type nonrec param = (binder, tname) param
  type nonrec expr = (name, binder, tname) expr
  type nonrec expr_kind = (name, binder, tname) expr_kind
  type nonrec arm = (name, binder, tname) arm
  type nonrec handler_arm = (name, binder, tname) handler_arm
  type nonrec with_item = (name, binder, tname) with_item
  type nonrec with_link = (name, binder, tname) with_link
  type nonrec stmt = (name, binder, tname) stmt
  type nonrec over = (name, binder, tname) over
  type nonrec field = tname field
  type nonrec ctor = tname ctor
  type nonrec op = (name, binder, tname) op
  type nonrec type_def = (name, binder, tname) type_def
  type nonrec fn_def = (name, binder, tname) fn_def
  type nonrec item = (name, binder, tname) item
  type nonrec wiring_def = (name, binder, tname) wiring_def
  type nonrec program = (name, binder, tname) program
end

let is_upper name = name <> "" && name.[0] >= 'A' && name.[0] <= 'Z'

(* Printing, as s-expressions, for `ren ast` and tests. *)

let binop_to_string = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Wrap_add -> "+%"
  | Wrap_sub -> "-%"
  | Wrap_mul -> "*%"
  | Eq -> "=="
  | Neq -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | And -> "&&"
  | Or -> "||"
  | Orelse -> "orelse"

(* The method an arithmetic operator is, `+` is `add` (operators.md,
   "Operators are methods"), and the requirement it makes of a type
   variable; [None] for the rest, which aren't methods. `-a` is `neg`. *)
let binop_method = function
  | Add -> Some "add"
  | Sub -> Some "sub"
  | Mul -> Some "mul"
  | Div -> Some "div"
  | Mod -> Some "rem"
  | Wrap_add | Wrap_sub | Wrap_mul | Eq | Neq | Lt | Le | Gt | Ge | And | Or
  | Orelse ->
      None

(* Whether [op] is a wrapping operator, `+%`, `-%` or `*%`: `Int`'s
   arithmetic modulo 2^64, whose result stored into a sized integer wraps
   to its width (sized.ml) *)
let is_wrapping = function Wrap_add | Wrap_sub | Wrap_mul -> true | _ -> false

(* The method a wrapping operator is: `+%` is `Int.wrapping_add`. *)
let wrapping_method = function
  | Wrap_add -> Some "wrapping_add"
  | Wrap_sub -> Some "wrapping_sub"
  | Wrap_mul -> Some "wrapping_mul"
  | _ -> None

let parens words = "(" ^ String.concat " " words ^ ")"

(* A string as it's written, in quotes, with its escapes (token.ml). *)
let show_str = Token.show_str
let show_float = Token.show_float

open Parsed

let show_tyname (t : tyname) =
  match t.tmod with Some m -> m.name ^ "." ^ t.tid.name | None -> t.tid.name

let show_ctor_ref (c : ctor_ref) =
  match c.qual with
  | Some t -> show_tyname t ^ "." ^ c.name.name
  | None -> c.name.name

(* A literal, as it's written. *)
let show_literal = function
  | LInt n -> Int64.to_string n
  | LFloat f ->
      (* the shortest spelling that reads back as [f], with a point *)
      let short = Printf.sprintf "%g" f in
      let s =
        if float_of_string short = f then short else Printf.sprintf "%.17g" f
      in
      if String.exists (fun c -> c = '.' || c = 'e' || c = 'n' || c = 'i') s
      then s
      else s ^ ".0"
  | LBool b -> string_of_bool b
  | LStr s -> Printf.sprintf "%S" s

let rec show_ty : ty -> string = function
  | TyName (name, []) -> show_tyname name
  | TyName (name, args) ->
      (* in a type argument, a `uses` list ends at a comma, so one of
         several dependencies is in parentheses *)
      let arg = function
        | TyFn (_, _, _, Some u, _) as t when List.length u.deps > 1 ->
            "(" ^ show_ty t ^ ")"
        | t -> show_ty t
      in
      show_tyname name ^ "<" ^ String.concat ", " (List.map arg args) ^ ">"
  | TyInout (t, _) -> "&" ^ show_ty t
  | TyFn (params, ret, errs, uses, _) ->
      let ret = match ret with Some r -> " -> " ^ show_ty r | None -> "" in
      let errs =
        match errs with Some es -> " " ^ show_errors es | None -> ""
      in
      let uses = match uses with Some u -> " " ^ show_uses u | None -> "" in
      "fn("
      ^ String.concat ", " (List.map show_ty params)
      ^ ")" ^ ret ^ errs ^ uses
  | TyImpl { impl_deps; impl_over; impl_errors; impl_uses; _ } -> (
      let names = (if impl_over then "over " else "") ^ show_joined impl_deps in
      let errs =
        match impl_errors with Some es -> [ show_errors es ] | None -> []
      in
      let uses =
        match impl_uses with Some u -> [ show_uses u ] | None -> []
      in
      match errs @ uses with
      | [] -> names
      | rest -> "(" ^ String.concat " " (names :: rest) ^ ")")
  | TyErrors es -> show_errors es
  | TyTuple (ts, _) -> "(" ^ String.concat ", " (List.map show_ty ts) ^ ")"
  | TyVariant (name, c, []) -> show_tyname name ^ "." ^ c.name
  | TyVariant (name, c, args) ->
      show_tyname name ^ "." ^ c.name ^ "<"
      ^ String.concat ", " (List.map show_ty args)
      ^ ">"

(* `Clock & TestClock` *)
and show_joined deps = String.concat " & " (List.map show_dep deps)

(* `Clock`, or `Chan<Int>` *)
and show_dep (d : tyname dep_ref) =
  match d.dargs with
  | [] -> show_tyname d.dep
  | args ->
      show_tyname d.dep ^ "<" ^ String.concat ", " (List.map show_ty args) ^ ">"

(* `uses Clock, ..d` *)
and show_uses (u : uses) =
  let tail = match u.dtail with Some t -> [ ".." ^ t.name ] | None -> [] in
  "uses " ^ String.concat ", " (List.map show_dep u.deps @ tail)

(* An error set as it's written: `! Short(by: Money) | Frozen`. *)
and show_errors (es : errors) =
  let payload p =
    match p.payload_name with
    | Some n -> n.name ^ ": " ^ show_ty p.payload_ty
    | None -> show_ty p.payload_ty
  in
  let error = function
    | Tag (t, []) -> t.name
    | Tag (t, ps) ->
        t.name ^ "(" ^ String.concat ", " (List.map payload ps) ^ ")"
    | Set s -> show_tyname s
  in
  let tail = match es.etail with Some t -> [ ".." ^ t.name ] | None -> [] in
  "! " ^ String.concat " | " (List.map error es.errs @ tail)

let rec show_pattern (p : pattern) =
  match p.pkind with
  | PWild -> "_"
  | PVar x -> x.name
  | PInt n -> Int64.to_string n
  | PBool b -> string_of_bool b
  | PCon (c, []) -> show_ctor_ref c
  | PCon (c, args) ->
      show_ctor_ref c ^ "("
      ^ String.concat ", " (List.map show_pattern args)
      ^ ")"
  | PFail (t, []) -> "fail " ^ t.name
  | PFail (t, args) ->
      "fail " ^ t.name ^ "("
      ^ String.concat ", " (List.map show_pattern args)
      ^ ")"
  | PFail_any -> "fail _"
  | PFail_in t -> "fail " ^ t.name
  | POr ps -> String.concat " | " (List.map (or_alt show_pattern) ps)
  | PAs (q, x) -> show_pattern q ^ " as " ^ x.name
  | PTuple ps -> "(" ^ String.concat ", " (List.map show_pattern ps) ^ ")"
  | PRecord (name, fs) ->
      let name = match name with Some t -> show_tyname t ^ " " | None -> "" in
      name ^ show_fields show_pattern fs
  | PCon_named (c, fs) -> show_ctor_ref c ^ " " ^ show_fields show_pattern fs

let rec show_expr (e : expr) =
  match e.kind with
  | Int n -> Int64.to_string n
  | Float f -> show_float f
  | Bool b -> string_of_bool b
  | Str s -> show_str s
  | Interp ps ->
      parens
        ("interp"
        :: List.map (function Lit t -> show_str t | Hole e -> show_expr e) ps)
  | Unit -> "()"
  | Var (Bare x) -> x
  | Var (Item (t, f)) -> show_tyname t ^ "." ^ f.name
  | Unop (Neg, a, _) -> parens [ "neg"; show_expr a ]
  | Unop (Not, a, _) -> parens [ "not"; show_expr a ]
  | Binop (op, a, b, _) ->
      parens [ binop_to_string op; show_expr a; show_expr b ]
  | If (c, t, Some f) -> parens [ "if"; show_expr c; show_expr t; show_expr f ]
  | If (c, t, None) -> parens [ "if"; show_expr c; show_expr t ]
  | Call (f, args) -> parens ("call" :: show_expr f :: List.map show_expr args)
  | Lambda (params, body) ->
      parens [ "lambda"; parens (List.map show_param params); show_expr body ]
  | Block (stmts, last) ->
      parens (("block" :: List.map show_stmt stmts) @ [ show_expr last ])
  | Con (c, args) ->
      let show_arg = function
        | Some (l : ident), a -> l.name ^ "=" ^ show_expr a
        | None, a -> show_expr a
      in
      parens ("con" :: show_ctor_ref c :: List.map show_arg args)
  | Record (name, fields) ->
      let ty = match name with Some n -> [ show_tyname n ] | None -> [] in
      let show_field ((f : ident), v) = f.name ^ "=" ^ show_expr v in
      parens (("record" :: ty) @ List.map show_field fields)
  | Con_named (c, fields) ->
      let show_field ((f : ident), v) = f.name ^ "=" ^ show_expr v in
      parens ("con" :: show_ctor_ref c :: "{}" :: List.map show_field fields)
  | Update { target; base; fields } ->
      let ty =
        match target with
        | Some (Into_type n) -> [ show_tyname n ]
        | Some (Into_ctor c) -> [ show_ctor_ref c ]
        | None -> []
      in
      let show_field ((f : ident), v) = f.name ^ "=" ^ show_expr v in
      parens
        (("update" :: ty) @ (".." ^ show_expr base) :: List.map show_field fields)
  | Field (r, f) -> parens [ "."; show_expr r; f.name ]
  | Match (subject, arms) ->
      parens ("match" :: show_expr subject :: List.map show_arm arms)
  | Array xs -> parens ("array" :: List.map show_expr xs)
  | Tuple xs -> parens ("tuple" :: List.map show_expr xs)
  | Index (a, i) -> parens [ "index"; show_expr a; show_expr i ]
  | Slice (a, lo, hi) -> parens [ "slice"; show_expr a; show_expr lo; show_expr hi ]
  | Ref a -> parens [ "&"; show_expr a ]
  | Assign { target; op; value; _ } ->
      let op =
        match op with Some o -> binop_to_string o ^ "=" | None -> "="
      in
      parens [ op; show_expr target; show_expr value ]
  | For { index; pat; over = Each iter; body } ->
      parens
        ([ "for" ]
        @ Option.to_list (Option.map show_pattern index)
        @ [ show_pattern pat; show_expr iter; show_expr body ])
  | For { pat; over = Range (lo, hi); body; _ } ->
      parens
        [
          "for";
          show_pattern pat;
          parens [ ".."; show_expr lo; show_expr hi ];
          show_expr body;
        ]
  | While { cond; body } -> parens [ "while"; show_expr cond; show_expr body ]
  | Break -> "break"
  | Todo -> "todo"
  | Fail (t, args) ->
      let show_arg = function
        | Some (l : ident), a -> l.name ^ "=" ^ show_expr a
        | None, a -> show_expr a
      in
      parens ("fail" :: t.name :: List.map show_arg args)
  | Try a -> parens [ "try"; show_expr a ]
  | Attempt a -> parens [ "attempt"; show_expr a ]
  | Pipe { subject; step } -> parens [ "|>"; show_expr subject; show_expr step ]
  | Piped -> "_"
  | Assert a -> parens [ "assert"; show_expr a ]
  | Inline_handler a -> parens [ "handler"; show_expr a ]
  | Named (n, a) -> parens [ n.name ^ ":"; show_expr a ]
  | Tag_set es -> parens [ "tags"; show_errors es ]
  | With { items; body } ->
      (* an item of one implementation is itself, and a chain is
         `(over top ... bottom)`, ending in `(deps Clock)` if it goes over
         what's installed outside *)
      parens (("with" :: List.map show_with_item items) @ [ show_expr body ])
  | Handler { deps; over; any; fails; needs; state; arms } ->
      let fails =
        match fails with Some es -> [ parens [ show_errors es ] ] | None -> []
      in
      let needs =
        match needs with Some u -> [ parens [ show_uses u ] ] | None -> []
      in
      parens
        ("handler"
         :: parens
              ((if over then "over" else "for")
              :: (if any then [ "any" ] else List.map show_dep deps))
         :: fails
        @ needs @ List.map show_stmt state
        @ List.map
            (fun (a : handler_arm) ->
              let name =
                match a.arm_op with
                | Item (d, op) -> show_tyname d ^ "." ^ op.name
                | Bare op -> op
              in
              parens [ name; show_expr a.arm_impl ])
            arms)

(* An item of one implementation is itself, and a chain is `(over top ...
   bottom)`, ending in `(deps Clock)` if it goes over what's installed
   outside the `with`. *)
and show_with_item (i : with_item) =
  let links = List.map (fun l -> show_expr l.link) i.chain in
  let under =
    match i.under with
    | [] -> []
    | ds -> [ parens ("deps" :: List.map show_dep ds) ]
  in
  let item =
    match links @ under with [ one ] -> one | all -> parens ("over" :: all)
  in
  match i.alias with
  | Some d -> parens [ "as"; item; show_dep d ]
  | None -> item

and show_arm (a : arm) =
  let guard =
    match a.arm_guard with Some g -> [ "if"; show_expr g ] | None -> []
  in
  parens ((show_pattern a.arm_pat :: guard) @ [ "=>"; show_expr a.arm_body ])

and show_param (p : param) =
  let name =
    match p.pmode with Inout -> "inout " ^ p.pname.name | Read -> p.pname.name
  in
  let block =
    match p.pblock with
    | Ordinary -> ""
    | Concurrent -> "concurrent "
    | Spawned -> "spawned "
  in
  let default =
    match p.pdefault with
    | Some (l, _, _) -> "=" ^ show_literal l
    | None -> ""
  in
  match p.pty with
  | Some t -> name ^ ":" ^ block ^ show_ty t ^ default
  | None -> name ^ default

and show_stmt : stmt -> string = function
  | Let { name; value; mut; _ } ->
      parens [ (if mut then "var" else "let"); name.name; show_expr value ]
  | Let_pattern { pat; value; else_ = None } ->
      parens [ "let"; show_pattern pat; show_expr value ]
  | Let_pattern { pat; value; else_ = Some e } ->
      parens [ "let"; show_pattern pat; show_expr value; "else"; show_expr e ]
  | Expr e -> show_expr e
  | Finally f -> parens [ "finally"; show_expr f ]

let show_fn (f : fn_def) =
  let params = List.map (fun (p : param) -> p.pname.name) f.params in
  let errors =
    match f.errors with Some es -> [ parens [ show_errors es ] ] | None -> []
  in
  let uses =
    match f.uses with
    | Some u ->
        let tail =
          match u.dtail with Some t -> [ ".." ^ t.name ] | None -> []
        in
        [ parens (("uses" :: List.map show_dep u.deps) @ tail) ]
    | None -> []
  in
  (* a test item, `test fn` *)
  let fn = if f.test then [ "test"; "fn" ] else [ "fn" ] in
  parens
    ((fn @ [ f.name.name; parens params ] @ errors @ uses)
    @ [ show_expr f.body ])

let show_type_def (td : type_def) =
  let name =
    match td.type_params with
    | [] -> td.type_name.name
    | ps ->
        td.type_name.name ^ "<"
        ^ String.concat ", " (List.map (fun (p : ident) -> p.name) ps)
        ^ ">"
  in
  let show_field f =
    (* a positional field's name, if it isn't written, is [""] *)
    if f.field_name.name = "" then show_ty f.field_ty
    else f.field_name.name ^ ":" ^ show_ty f.field_ty
  in
  let body =
    match td.type_body with
    | Fields fs -> [ parens ("fields" :: List.map show_field fs) ]
    | Ctors cs ->
        List.map
          (fun c ->
            parens
              (c.ctor_name.name
               :: ((if c.ctor_named then [ "{}" ] else [])
                  @ List.map show_field c.ctor_fields)))
          cs
    | Opaque { rep; numeric = None } -> [ parens [ "opaque"; show_ty rep ] ]
    | Opaque { rep; numeric = Some _ } ->
        [ parens [ "opaque"; show_ty rep; "numeric" ] ]
    | Opaque_fields fs ->
        [ parens [ "opaque"; parens ("fields" :: List.map show_field fs) ] ]
    | Errors es -> [ parens [ show_errors es ] ]
    | Dep ops -> [ parens ("ops" :: List.map show_field ops) ]
    | Dep_alias d -> [ parens [ "alias"; show_dep d ] ]
    | Builtin -> [ "builtin" ]
  in
  let show_op (o : op) =
    let f = o.op_fn in
    let pub = if f.pub then [ "pub" ] else [] in
    match o.op_kind with
    | Op_fn -> parens (pub @ [ show_fn f ])
    | Op_value -> parens (pub @ [ "let"; f.name.name; show_expr f.body ])
  in
  let members =
    match td.type_ops with
    | [] -> []
    | os -> [ parens ("members" :: List.map show_op os) ]
  in
  let keyword =
    match td.type_body with Dep _ | Dep_alias _ -> "dep" | _ -> "type"
  in
  parens
    ((if td.type_pub then [ "pub" ] else [])
    @ (keyword :: name :: body) @ members)

let show_import (i : import) =
  let names =
    match i.names with
    | [] -> []
    | ns -> [ parens (List.map (fun (n : ident) -> n.name) ns) ]
  in
  parens (("import" :: i.path :: names) @ [ "as"; i.alias.name ])

let show_test (t : test_def) =
  let uses =
    match t.test_uses with Some u -> [ parens [ show_uses u ] ] | None -> []
  in
  parens
    ((("test" :: [ show_str t.test_name ]) @ uses) @ [ show_expr t.test_body ])

let show_item : item -> string = function
  | Fn f -> show_fn f
  | Type td -> show_type_def td
  | Import i -> show_import i
  | Testing (Test t) -> show_test t
  | Testing (Group g) ->
      let with_ =
        match g.group_with with
        | [] -> []
        | items -> [ parens ("with" :: List.map show_with_item items) ]
      in
      parens
        ((if g.group_pub then [ "pub" ] else [])
        @ [
            "group";
            g.group_name.name;
            parens (List.map show_param g.group_params);
          ]
        @ with_
        @ List.map show_test g.group_tests)
  | Testing (Run_group r) ->
      parens [ "group"; show_str r.run_label; show_expr r.run_call ]
  | Wiring w ->
      let uses =
        match w.wuses with Some u -> [ parens [ show_uses u ] ] | None -> []
      in
      let errors =
        match w.werrors with
        | Some es -> [ parens [ show_errors es ] ]
        | None -> []
      in
      parens
        ((if w.wpub then [ "pub" ] else [])
        @ [
            "wiring";
            w.wname.name;
            parens (List.map show_param w.wparams);
            parens ("provides" :: List.map show_dep w.provides);
          ]
        @ uses @ errors
        @ List.map show_with_item w.witems)

(* ---- code as it's written, for messages ----

   A help that says "write `&s.push(1)`" shows code the way it's written,
   not as an s-expression. [source] prints a resolved expression back as
   source, for the kinds of expression a help needs: names, literals,
   operators, calls, fields, indices, constructors and records. Anything
   else, like a `match` or a block, isn't worth printing in one line, and
   gives [None], so the message can say "this" instead. [type_name] and
   [value_name] say how the module writes a type's name and a top-level
   name (Resolve.type_name, Resolve.value_name). *)

(* How tightly an operator binds: an operand that binds more loosely needs
   parentheses. `orelse` binds loosest, at 0, so `a || b orelse c` is
   `(a || b) orelse c`. `not` binds between `&&` and the comparisons, at 3,
   so `not a == b` is `not (a == b)`; `-` binds tightest, at 7. `try`
   and `fail` take everything to their right, so they need parentheses
   only on an operator's left. `attempt` takes what's to its right up to
   a comparison, so it needs them on the left of `+` and tighter, and a
   comparison inside it needs them too. *)
let precedence = function
  | Orelse -> 0
  | Or -> 1
  | And -> 2
  | Eq | Neq | Lt | Le | Gt | Ge -> 4
  | Add | Sub | Wrap_add | Wrap_sub -> 5
  | Mul | Div | Mod | Wrap_mul -> 6

(* The binders [e] binds itself, by id, at any depth: its lambdas'
   parameters, its `let`s, its loops' variables and its patterns. *)
let bound_in (e : Resolved.expr) =
  let ids = ref [] in
  let see (b : binder) = ids := b.id :: !ids in
  let rec pat (p : Resolved.pattern) =
    match p.pkind with
    | PVar b -> see b
    | PAs (q, b) ->
        pat q;
        see b
    | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps -> List.iter pat ps
    | PRecord (_, fs) | PCon_named (_, fs) ->
        List.iter (fun (_, q) -> pat q) fs.fpats
    | PWild | PInt _ | PBool _ | PFail_any | PFail_in _ -> ()
  in
  let rec go (e : Resolved.expr) =
    (match e.kind with
    | Lambda (ps, _) -> List.iter (fun (p : Resolved.param) -> see p.pname) ps
    | Block (stmts, _) ->
        List.iter
          (function
            | Let { name; _ } -> see name
            | Let_pattern { pat = p; _ } -> pat p
            | Expr _ | Finally _ -> ())
          stmts
    | For { index; pat = p; _ } ->
        Option.iter pat index;
        pat p
    | Match (_, arms) -> List.iter (fun a -> pat a.arm_pat) arms
    | _ -> ());
    List.iter go (children e)
  in
  go e;
  !ids

let source ~type_name ~value_name (e : Resolved.expr) =
  (* [exception Exit] is raised by anything that isn't printed, and caught
     once, at the top *)
  let rec go (e : Resolved.expr) =
    match e.kind with
    | Int _ when Hashtbl.mem char_literals e.loc -> Hashtbl.find char_literals e.loc
    | Int n -> Int64.to_string n
    | Float f -> show_float f
    | Bool b -> string_of_bool b
    | Str s -> show_str s
    | Interp ps ->
        (* each piece's text as it's written, without its quotes *)
        let text t =
          let q = show_str t in
          String.sub q 1 (String.length q - 2)
        in
        "\""
        ^ String.concat ""
            (List.map (function Lit t -> text t | Hole e -> "\\{" ^ go e ^ "}") ps)
        ^ "\""
    | Unit -> "()"
    | Todo -> "todo"
    | Var (Local b) -> b.ident.name
    | Var (Global p | Global_value p) -> value_name p
    | Var (Intrinsic x) -> Intrinsic.name x
    | Var (Dep_op (p, op)) -> type_name p ^ "." ^ op
    | Var (Next_op (_, op)) -> "next." ^ op
    | Var (Call_op "forward") -> "call.forward"
    | Var (Call_op x) -> "call." ^ x
    | Named (n, a) -> n.name ^ ": " ^ go a
    | Tag_set es ->
        String.concat " | "
          (List.map
             (function
               | Tag (t, _) -> t.name
               | Set { tref = Named p; _ } -> type_name p
               | Set { tref = Param _; _ } -> raise Exit)
             es.errs)
    | Var (Assoc_value (Named p, v)) -> type_name p ^ "." ^ v
    | Var (Assoc_value (Param _, _)) -> raise Exit
    | Unop (Neg, a, _) -> "-" ^ operand 7 a
    | Unop (Not, a, _) -> "not " ^ operand 3 a
    | Binop (Orelse, a, b, _) ->
        (* it groups to the right: `a orelse b orelse c` tries `a`, then `b` *)
        left 1 a ^ " orelse " ^ operand 0 b
    | Binop (op, a, b, _) ->
        let n = precedence op in
        left n a ^ " " ^ binop_to_string op ^ " " ^ operand (n + 1) b
    | Try a -> "try " ^ go a
    | Attempt a -> "attempt " ^ operand 5 a
    | Pipe { subject; step } ->
        (* the step as written: its marker, then the call without the
           subject, and without parentheses if it has no other argument *)
        let rec step_src (s : Resolved.expr) =
          match s.kind with
          | Try c -> "try " ^ step_src c
          | Attempt c -> "attempt " ^ step_src c
          | Call (f, { kind = Piped; _ } :: []) -> left 8 f
          | Call (f, { kind = Piped; _ } :: rest) ->
              left 8 f ^ "(" ^ list rest ^ ")"
          | _ -> raise Exit
        in
        let subject =
          match subject.kind with
          | Binop _ -> "(" ^ go subject ^ ")"
          | _ -> go subject
        in
        subject ^ " |> " ^ step_src step
    | Assert a -> "assert " ^ go a
    | Fail (t, []) -> "fail " ^ t.name
    | Fail (t, args) -> "fail " ^ t.name ^ "(" ^ con_args args ^ ")"
    | Call (f, args) -> left 8 f ^ "(" ^ list args ^ ")"
    | Field (r, f) -> left 8 r ^ "." ^ f.name
    | Index (a, i) -> left 8 a ^ "[" ^ go i ^ "]"
    | Slice (a, lo, hi) -> left 8 a ^ "[" ^ go lo ^ ".." ^ go hi ^ "]"
    | Array xs -> "[" ^ list xs ^ "]"
    | Tuple xs -> "(" ^ list xs ^ ")"
    | Ref a -> "&" ^ go a
    | Con (c, []) -> ctor c
    | Con (c, args) -> ctor c ^ "(" ^ con_args args ^ ")"
    | Record (t, fields) ->
        let t =
          match t with
          | Some { tref = Named p; _ } -> type_name p ^ " "
          | Some { tref = Param _; _ } | None -> ""
        in
        t ^ "{ "
        ^ String.concat ", "
            (List.map (fun ((f : ident), v) -> f.name ^ ": " ^ go v) fields)
        ^ " }"
    | Con_named (c, fields) ->
        ctor c ^ " { "
        ^ String.concat ", " (List.map named fields)
        ^ " }"
    | Update { target; base; fields } ->
        let t =
          match target with
          | Some (Into_type { tref = Named p; _ }) -> type_name p ^ " "
          | Some (Into_ctor c) -> ctor c ^ " "
          | Some (Into_type { tref = Param _; _ }) | None -> ""
        in
        t ^ "{ .." ^ go base
        ^ String.concat ""
            (List.map (fun ((f : ident), v) -> ", " ^ f.name ^ ": " ^ go v) fields)
        ^ " }"
    | If _ | Lambda _ | Block _ | Match _ | Assign _ | For _ | While _ | Break
    | With _ | Handler _ | Inline_handler _ | Piped ->
        raise Exit
  and operand n (a : Resolved.expr) =
    match a.kind with
    | Binop (op, _, _, _) when precedence op < n -> "(" ^ go a ^ ")"
    (* a chain ends its expression: only `orelse` may follow one bare *)
    | Pipe _ when n > 1 -> "(" ^ go a ^ ")"
    | Unop (Not, _, _) when 3 < n -> "(" ^ go a ^ ")"
    | _ -> go a
  (* an operator's left operand, or what a call, field or index is of
     (at 8, tighter than any operator): a `try` it ends in would otherwise
     take everything after it in, and an `attempt` everything up to a
     comparison, as in `(x * attempt a()) + 1` *)
  and left n (a : Resolved.expr) =
    if ends_open n n a then "(" ^ go a ^ ")" else operand n a
  (* whether [a], printed as an operand where [at] binds, ends in a `try`
     or `attempt` that would take in what comes after it, where [n] binds:
     its last operand, unless that's in parentheses of its own *)
  and ends_open n at (a : Resolved.expr) =
    match a.kind with
    | Try _ -> true
    | Attempt _ -> n > 4
    | Binop (Orelse, _, b, _) when 0 >= at -> ends_open n 0 b
    | Binop (op, _, b, _) when precedence op >= at ->
        ends_open n (precedence op + 1) b
    | Unop (Neg, b, _) -> ends_open n 7 b
    | Unop (Not, b, _) when 3 >= at -> ends_open n 3 b
    | _ -> false
  and list xs = String.concat ", " (List.map go xs)
  (* a by-name constructor's field, punned where its value is a local of
     its name *)
  and named ((f : ident), (v : Resolved.expr)) =
    match v.kind with
    | Var (Local b) when b.ident.name = f.name -> f.name
    | _ -> f.name ^ ": " ^ go v
  and con_args args =
    let arg = function
      | Some (l : ident), a -> l.name ^ ": " ^ go a
      | None, a -> go a
    in
    String.concat ", " (List.map arg args)
  and ctor (c : Resolved.ctor_ref) =
    match c.qual with
    | Some { tref = Named p; _ } -> type_name p ^ "." ^ c.name.name
    | Some { tref = Param _; _ } | None -> c.name.name
  in
  try Some (go e) with Exit -> None

(* A resolved pattern as it's written, for messages: [type_name] writes a
   type's name. *)
let rec pattern_source ~type_name (p : Resolved.pattern) =
  let go = pattern_source ~type_name in
  let ctor (c : Resolved.ctor_ref) =
    match c.qual with
    | Some { tref = Named t; _ } -> type_name t ^ "." ^ c.name.name
    | Some { tref = Param _; _ } | None -> c.name.name
  in
  let args ps = "(" ^ String.concat ", " (List.map go ps) ^ ")" in
  match p.pkind with
  | PWild -> "_"
  | PVar b -> b.ident.name
  | PInt n -> Int64.to_string n
  | PBool b -> string_of_bool b
  | PCon (c, []) -> ctor c
  | PCon (c, ps) -> ctor c ^ args ps
  | PFail (t, []) -> "fail " ^ t.name
  | PFail (t, ps) -> "fail " ^ t.name ^ args ps
  | PFail_any -> "fail _"
  | PFail_in b -> "fail " ^ b.ident.name
  | POr ps -> String.concat " | " (List.map (or_alt go) ps)
  | PAs (q, b) -> go q ^ " as " ^ b.ident.name
  | PTuple ps -> args ps
  | PRecord (t, fs) ->
      (match t with
      | Some { tref = Named t; _ } -> type_name t ^ " "
      | Some { tref = Param _; _ } | None -> "")
      ^ show_fields go fs
  | PCon_named (c, fs) -> ctor c ^ " " ^ show_fields go fs
