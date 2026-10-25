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
  | TyImpl of 't * 't uses option * Loc.t
      (** a dependency's type, whose values are implementations, and what one
          needs (deps.md, "Implementations"): [Clock uses Os]. The parser reads
          [Clock] alone as a [TyName], which Resolve makes a [TyImpl] with no
          [uses] *)
  | TyInout of 't ty * Loc.t
      (** [inout Int], a parameter of a function type: [fn(inout Int)] *)
  | TyErrors of 't errors
      (** [! Short | Frozen], an error set as a type argument, which only
          [Result<T, ! ...>] takes (errors.md, "Keeping an error") *)

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
      (** a named row at the end, [..e]: whatever the closure it's in fails with
          (see [uses]) *)
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
   `..d`. A signature names a row where a closure or an implementation is
   kept rather than only called: `f: fn() uses ..d` stands for whatever
   `f` uses, and every `..d` in the signature for the same (deps.md,
   "Implementations"). An error set names one the same way, `! ..e`. *)
and 't uses = { deps : 't list; dtail : ident option; uloc : Loc.t }

(* [And] and [Or] are `&&` and `||`, which evaluate their right side only
   when the left doesn't already decide the answer (lower.ml makes them
   `if`s). [Orelse] is `x orelse e`: the value in the `Option` [x], or else
   [e], which is evaluated only if [x] is `None`, and is usually a `fail`. *)
type binop =
  | Add
  | Sub
  | Mul
  | Div
  | Mod
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
  | PInt of int
  | PBool of bool
  | PCon of 't ctor_ref * ('b, 't) pattern list
      (** [Free], [Pro(seats)], [Plan.Free] *)
  | PFail of ident * ('b, 't) pattern list
      (** [fail Short(_, by)]: an error, destructured. A `fail` pattern is a
          whole arm's, never part of another pattern *)
  | PFail_any  (** [fail _]: any error *)
  | POr of ('b, 't) pattern list
      (** [fail Short(_, _) | fail Frozen(_)]: any of them. So far only `fail`
          patterns are combined, and each binds the same names *)

(* How a parameter is passed: read-only (the default), or [inout], which
   updates the caller's value. *)
type mode = Read | Inout

(* A parameter of a function or lambda; its type may be left out. *)
type ('b, 't) param = { pname : 'b; pty : 't ty option; pmode : mode }

(* [node] numbers the expressions and patterns of one top-level function,
   so later passes can say things about a particular expression. *)
type ('v, 'b, 't) expr = {
  kind : ('v, 'b, 't) expr_kind;
  loc : Loc.t;
  node : int;
}

and ('v, 'b, 't) expr_kind =
  | Int of int
  | Bool of bool
  | Str of string  (** ["Ren"], its escapes undone *)
  | Unit  (** [()] *)
  | Var of 'v
      (** a local variable, a top-level function, or a member written after its
          type, [Stack.of] *)
  | Unop of unop * ('v, 'b, 't) expr
  | Binop of binop * ('v, 'b, 't) expr * ('v, 'b, 't) expr
  | If of ('v, 'b, 't) expr * ('v, 'b, 't) expr * ('v, 'b, 't) expr option
      (** with no [else], the [if] is [Unit] *)
  | Call of ('v, 'b, 't) expr * ('v, 'b, 't) expr list
      (** [f(x)], [make()(x)], [handlers.on_click()] *)
  | Lambda of ('b, 't) param list * ('v, 'b, 't) expr  (** [fn(x) => x + 1] *)
  | Block of ('v, 'b, 't) stmt list * ('v, 'b, 't) expr
      (** statements, then the block's value *)
  | Con of 't ctor_ref * (ident option * ('v, 'b, 't) expr) list
      (** a constructor: [Pro(5)], [Pro(seats: 5)] or [Plan.Pro(5)] *)
  | Record of 't option * (ident * ('v, 'b, 't) expr) list
      (** [User { id: 1 }], [rows.Row { id: 1 }], or [{ id: 1 }] with the type
          left out *)
  | Field of ('v, 'b, 't) expr * ident  (** [user.plan] *)
  | Match of ('v, 'b, 't) expr * ('v, 'b, 't) arm list
  | Array of ('v, 'b, 't) expr list  (** [[1, 2, 3]] *)
  | Index of ('v, 'b, 't) expr * ('v, 'b, 't) expr  (** [xs[i]] *)
  | Ref of ('v, 'b, 't) expr
      (** [&scores]: an argument the call changes, or the array a [for] loop
          changes; or, before a method call, [&s.push(1)], the receiver the call
          changes (see [changed_receiver]) *)
  | Assign of {
      target : ('v, 'b, 't) expr;
      op : binop option;
      value : ('v, 'b, 't) expr;
    }  (** [x = 1], [user.plan = Free], [xs[i] += 1]; the target is a place *)
  | For of { var : 'b; iter : ('v, 'b, 't) expr; body : ('v, 'b, 't) expr }
      (** [for x in xs], or [for p in &ps] to change each element *)
  | Fail of ident * (ident option * ('v, 'b, 't) expr) list
      (** [fail Short(self.id, by)]: stop with that error. A tag isn't a value,
          so it's only ever written here, after `!` and in a pattern *)
  | Try of ('v, 'b, 't) expr
      (** [try e]: pass on the errors of every call in [e]. [try match] is a
          [Try] of a [Match] *)
  | Attempt of ('v, 'b, 't) expr  (** [attempt e]: its outcome, as a [Result] *)
  | With of { item : ('v, 'b, 't) expr; body : ('v, 'b, 't) expr; lam : int }
      (** [with item in body] (deps.md, "`with`"): [item] is an implementation,
          installed around [body], or a wrapper, a call missing its last
          argument, which is [body] as a lambda: `with retry(3) in body` is
          `retry(3, fn() => body)`. [lam] numbers that lambda, as a node of its
          own. `with a, b in body` is [a] around `with b in body` *)
  | Handler of {
      deps : 't list;  (** the dependencies after `for`, in order *)
      needs : 't uses option;
          (** what it's written to need, after the `for` list's `uses` *)
      state : ('v, 'b, 't) stmt list;  (** its `var`s and `let`s *)
      arms : ('v, 'b, 't) handler_arm list;
    }
      (** a handler's body (deps.md, "Implementations"), the whole body of the
          function a `handler` declaration is (see [is_handler]): its state,
          then an arm for each operation of each dependency it implements.
          Calling the function describes the handler, and each `with` that
          installs it makes a fresh instance, running [state] then *)
  | Assert of ('v, 'b, 't) expr
      (** [assert e]: a panic if [e] is false, which shows both sides of an
          [a == b] (deps.md, "`assert`") *)

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

and ('v, 'b, 't) stmt =
  | Let of {
      name : 'b;
      ty : 't ty option;
      value : ('v, 'b, 't) expr;
      mut : bool;
    }  (** [let], or [var] when [mut] *)
  | Expr of ('v, 'b, 't) expr

(* Type declarations. *)

type 't field = { field_name : ident; field_ty : 't ty }
type 't ctor = { ctor_name : ident; ctor_fields : 't field list }

type 't type_body =
  | Fields of 't field list  (** a record: [{ id: Int, plan: Plan }] *)
  | Ctors of 't ctor list  (** a sum type: [| Free | Pro(seats: Int)] *)
  | Opaque of 't ty
      (** [opaque Int]: a type of its own, represented as the type written,
          which only its module can see *)
  | Errors of 't errors
      (** [! Short(by: Money) | Frozen]: a named error set. It isn't a type of
          values: it's only written after `!` *)
  | Dep of 't field list
      (** a dependency's operations, [now: fn() -> Time], each a function type
          (deps.md, "Declaring one"). A value of the type is an implementation,
          a record of them *)

type ('v, 'b, 't) fn_def = {
  pub : bool;
  name : ident;
  tparams : ident list;  (** the [T] in [fn id<T>(x: T) -> T] *)
  params : ('b, 't) param list;
  ret : 't ty option;
  errors : 't errors option;  (** what it can fail with, after `!` *)
  uses : 't uses option;
      (** the dependencies after `uses`, if it's written: [Clock], or another
          module's, [store.Users] *)
  body : ('v, 'b, 't) expr;
  loc : Loc.t;
}

(* A member of a type (module-build.md, "Methods and operators
   live on the type"):

     pub type Stack<T> = { items: Array<T> }
       pub fn push(inout self, x: T) = &self.items.push(x)
       pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
       pub let empty: Stack<T> = Stack { items: [] }

   A function whose first parameter is `self` is a method; one without is
   an associated function, `Stack.of(...)`. An associated value, `let`, is
   kept as a function of no parameters whose body is the value, so every
   pass checks it as one; only [op_kind] tells them apart.

   The parser names each item as it's written, `push`. Resolve gives it
   its type's name in front, `Stack.push`, its path's name in the module
   (path.ml), so passes after it know it apart from a top-level `push`;
   and it puts the type's parameters first in its [tparams], and gives
   `self` its type, `Stack<T>`. *)
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
      group_with : ('v, 'b, 't) expr list;
          (** installed around each test, outermost first *)
      group_tests : ('v, 'b, 't) test_def list;
    }
  | Run_group of {
      run_label : string;
      run_loc : Loc.t;  (** where its label is written *)
      run_call : ('v, 'b, 't) expr;  (** [g(args)] *)
    }

type ('v, 'b, 't) item =
  | Fn of ('v, 'b, 't) fn_def
  | Type of ('v, 'b, 't) type_def
  | Import of import
  | Testing of ('v, 'b, 't) testing

type ('v, 'b, 't) program = ('v, 'b, 't) item list

(* Every function of a program, its types' members
   included, in source order. *)
let functions (prog : ('v, 'b, 't) program) =
  List.concat_map
    (function
      | Fn f -> [ f ]
      | Type td -> List.map (fun o -> o.op_fn) td.type_ops
      | Import _ | Testing _ -> [])
    prog

(* Whether [f]'s signature is written out in full, so that its declaration
   says everything about its type: it's public, so no `->` means Unit and
   no `uses` means none, and every parameter has a type (once resolved, a
   method's `self` has its type's). *)
let spelled (f : ('v, 'b, 't) fn_def) =
  f.pub && List.for_all (fun p -> p.pty <> None) f.params

(* Whether [f] is a `handler` declaration: a function of its parameters
   whose body is a [Handler], and whose result describes the handler,
   `counting_rates(r)`. Its type is its dependency's, if it implements one;
   one of several has a type of its own, named after it, which can't be
   written, since a type's name starts with a capital (Iface.handler_type).
*)
let is_handler (f : ('v, 'b, 't) fn_def) =
  match f.body.kind with Handler _ -> true | _ -> false

(* Whether a function type names a row of its own, `fn() ! ..e` or
   `fn() uses ..d`: then it's a closure that can be kept, not only called,
   and what it doesn't name or list it doesn't do (deps.md,
   "Implementations"). *)
let names_row (t : 't ty) =
  match t with
  | TyFn (_, _, e, u, _) ->
      Option.bind e (fun e -> e.etail) <> None
      || Option.bind u (fun u -> u.dtail) <> None
  | TyName _ | TyImpl _ | TyInout _ | TyErrors _ -> false

(* `&s.push(1)`: a method call whose `&` marks the receiver it changes,
   as opposed to `&xs`, a place passed `inout`. A call's result is never a
   place, so the two can't be confused (module-build.md, "Methods and
   operators live on the type"); mut.ml makes sure the call is one with a
   receiver, `x.m(...)`. *)
let changed_receiver (e : ('v, 'b, 't) expr) =
  match e.kind with
  | Ref ({ kind = Call _; _ } as call) -> Some call
  | _ -> None

(* The expressions directly inside [e], in source order: a statement's
   value, a guard and an arm's body, a handler's state and arms too. *)
let children (e : ('v, 'b, 't) expr) =
  let stmt = function Let { value; _ } -> value | Expr e -> e in
  match e.kind with
  | Int _ | Bool _ | Str _ | Unit | Var _ -> []
  | Unop (_, a)
  | Field (a, _)
  | Ref a
  | Lambda (_, a)
  | Try a
  | Attempt a
  | Assert a ->
      [ a ]
  | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
      [ a; b ]
  | If (c, t, f) -> c :: t :: Option.to_list f
  | Call (f, args) -> f :: args
  | Array xs -> xs
  | For { iter; body; _ } -> [ iter; body ]
  | Con (_, args) | Fail (_, args) -> List.map snd args
  | Record (_, fields) -> List.map snd fields
  | Block (stmts, last) -> List.map stmt stmts @ [ last ]
  | Match (s, arms) ->
      s
      :: List.concat_map
           (fun a -> Option.to_list a.arm_guard @ [ a.arm_body ])
           arms
  | With { item; body; _ } -> [ item; body ]
  | Handler { state; arms; _ } ->
      List.map stmt state @ List.map (fun a -> a.arm_impl) arms

(* A member's name as it's written: `push` for `Stack.push`. *)
let short_name name =
  match String.rindex_opt name '.' with
  | Some i -> String.sub name (i + 1) (String.length name - i - 1)
  | None -> name

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
  | By_ref_loop  (** [p] in [for p in &ps], which changes each element *)
  | By_pattern

(* A name used as a value. *)
type name =
  | Local of binder
  | Global of Path.t
      (** a top-level function, or a function among a type's members:
          [Stack.push] *)
  | Global_value of Path.t
      (** an associated value, [Stack.empty]: made once, when the program starts
      *)
  | Intrinsic of string
      (** a function built into the compiler: [print], or a method, [Array.push]
      *)
  | Dep_op of Path.t * string
      (** an operation of the dependency at the path, [Clock.now]: calling it
          calls the implementation installed where it's called *)

(* A type's name: a declared type, or the [i]th type parameter in scope
   (of the type being declared, or of the function). *)
type tname = { tref : tref; tloc : Loc.t }
and tref = Named of Path.t | Param of int

module Parsed = struct
  type nonrec ty = tyname ty
  type nonrec errors = tyname errors
  type nonrec uses = tyname uses
  type nonrec error = tyname error
  type nonrec payload = tyname payload
  type nonrec ctor_ref = tyname ctor_ref
  type nonrec pattern = (ident, tyname) pattern
  type nonrec param = (ident, tyname) param
  type nonrec expr = (vname, ident, tyname) expr
  type nonrec expr_kind = (vname, ident, tyname) expr_kind
  type nonrec arm = (vname, ident, tyname) arm
  type nonrec handler_arm = (vname, ident, tyname) handler_arm
  type nonrec stmt = (vname, ident, tyname) stmt
  type nonrec field = tyname field
  type nonrec ctor = tyname ctor
  type nonrec op = (vname, ident, tyname) op
  type nonrec type_def = (vname, ident, tyname) type_def
  type nonrec fn_def = (vname, ident, tyname) fn_def
  type nonrec item = (vname, ident, tyname) item
  type nonrec test_def = (vname, ident, tyname) test_def
  type nonrec testing = (vname, ident, tyname) testing
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
  type nonrec param = (binder, tname) param
  type nonrec expr = (name, binder, tname) expr
  type nonrec expr_kind = (name, binder, tname) expr_kind
  type nonrec arm = (name, binder, tname) arm
  type nonrec handler_arm = (name, binder, tname) handler_arm
  type nonrec stmt = (name, binder, tname) stmt
  type nonrec field = tname field
  type nonrec ctor = tname ctor
  type nonrec op = (name, binder, tname) op
  type nonrec type_def = (name, binder, tname) type_def
  type nonrec fn_def = (name, binder, tname) fn_def
  type nonrec item = (name, binder, tname) item
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
  | Eq -> "=="
  | Neq -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | And -> "&&"
  | Or -> "||"
  | Orelse -> "orelse"

let parens words = "(" ^ String.concat " " words ^ ")"

(* A string as it's written, in quotes, with its escapes (token.ml). *)
let show_str = Token.show_str

open Parsed

let show_tyname (t : tyname) =
  match t.tmod with Some m -> m.name ^ "." ^ t.tid.name | None -> t.tid.name

let show_ctor_ref (c : ctor_ref) =
  match c.qual with
  | Some t -> show_tyname t ^ "." ^ c.name.name
  | None -> c.name.name

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
  | TyInout (t, _) -> "inout " ^ show_ty t
  | TyFn (params, ret, errs, uses, _) ->
      let ret = match ret with Some r -> " -> " ^ show_ty r | None -> "" in
      let errs =
        match errs with Some es -> " " ^ show_errors es | None -> ""
      in
      let uses = match uses with Some u -> " " ^ show_uses u | None -> "" in
      "fn("
      ^ String.concat ", " (List.map show_ty params)
      ^ ")" ^ ret ^ errs ^ uses
  | TyImpl (name, Some u, _) -> "(" ^ show_tyname name ^ " " ^ show_uses u ^ ")"
  | TyImpl (name, None, _) -> show_tyname name
  | TyErrors es -> show_errors es

(* `uses Clock, ..d` *)
and show_uses (u : uses) =
  let tail = match u.dtail with Some t -> [ ".." ^ t.name ] | None -> [] in
  "uses " ^ String.concat ", " (List.map show_tyname u.deps @ tail)

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
  | PInt n -> string_of_int n
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
  | POr ps -> String.concat " | " (List.map show_pattern ps)

let rec show_expr (e : expr) =
  match e.kind with
  | Int n -> string_of_int n
  | Bool b -> string_of_bool b
  | Str s -> show_str s
  | Unit -> "()"
  | Var (Bare x) -> x
  | Var (Item (t, f)) -> show_tyname t ^ "." ^ f.name
  | Unop (Neg, a) -> parens [ "neg"; show_expr a ]
  | Unop (Not, a) -> parens [ "not"; show_expr a ]
  | Binop (op, a, b) -> parens [ binop_to_string op; show_expr a; show_expr b ]
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
  | Field (r, f) -> parens [ "."; show_expr r; f.name ]
  | Match (subject, arms) ->
      parens ("match" :: show_expr subject :: List.map show_arm arms)
  | Array xs -> parens ("array" :: List.map show_expr xs)
  | Index (a, i) -> parens [ "index"; show_expr a; show_expr i ]
  | Ref a -> parens [ "&"; show_expr a ]
  | Assign { target; op; value } ->
      let op =
        match op with Some o -> binop_to_string o ^ "=" | None -> "="
      in
      parens [ op; show_expr target; show_expr value ]
  | For { var; iter; body } ->
      parens [ "for"; var.name; show_expr iter; show_expr body ]
  | Fail (t, args) ->
      let show_arg = function
        | Some (l : ident), a -> l.name ^ "=" ^ show_expr a
        | None, a -> show_expr a
      in
      parens ("fail" :: t.name :: List.map show_arg args)
  | Try a -> parens [ "try"; show_expr a ]
  | Attempt a -> parens [ "attempt"; show_expr a ]
  | Assert a -> parens [ "assert"; show_expr a ]
  | With { item; body; _ } -> parens [ "with"; show_expr item; show_expr body ]
  | Handler { deps; needs; state; arms } ->
      let needs =
        match needs with Some u -> [ parens [ show_uses u ] ] | None -> []
      in
      parens
        (("handler" :: parens ("for" :: List.map show_tyname deps) :: needs)
        @ List.map show_stmt state
        @ List.map
            (fun (a : handler_arm) ->
              parens [ a.arm_name.name; show_expr a.arm_impl ])
            arms)

and show_arm (a : arm) =
  let guard =
    match a.arm_guard with Some g -> [ "if"; show_expr g ] | None -> []
  in
  parens ((show_pattern a.arm_pat :: guard) @ [ "=>"; show_expr a.arm_body ])

and show_param (p : param) =
  let name =
    match p.pmode with Inout -> "inout " ^ p.pname.name | Read -> p.pname.name
  in
  match p.pty with Some t -> name ^ ":" ^ show_ty t | None -> name

and show_stmt : stmt -> string = function
  | Let { name; value; mut; _ } ->
      parens [ (if mut then "var" else "let"); name.name; show_expr value ]
  | Expr e -> show_expr e

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
        [ parens (("uses" :: List.map show_tyname u.deps) @ tail) ]
    | None -> []
  in
  parens
    (([ "fn"; f.name.name; parens params ] @ errors @ uses)
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
  let show_field f = f.field_name.name ^ ":" ^ show_ty f.field_ty in
  let body =
    match td.type_body with
    | Fields fs -> [ parens ("fields" :: List.map show_field fs) ]
    | Ctors cs ->
        List.map
          (fun c ->
            parens (c.ctor_name.name :: List.map show_field c.ctor_fields))
          cs
    | Opaque t -> [ parens [ "opaque"; show_ty t ] ]
    | Errors es -> [ parens [ show_errors es ] ]
    | Dep ops -> [ parens ("ops" :: List.map show_field ops) ]
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
  let keyword = match td.type_body with Dep _ -> "dep" | _ -> "type" in
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
        | items -> [ parens ("with" :: List.map show_expr items) ]
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
   so `not a == b` is `not (a == b)`; `-` binds tightest, at 7. `try`,
   `attempt` and `fail` take everything to their right, so they need
   parentheses only on an operator's left. *)
let precedence = function
  | Orelse -> 0
  | Or -> 1
  | And -> 2
  | Eq | Neq | Lt | Le | Gt | Ge -> 4
  | Add | Sub -> 5
  | Mul | Div | Mod -> 6

let source ~type_name ~value_name (e : Resolved.expr) =
  (* [exception Exit] is raised by anything that isn't printed, and caught
     once, at the top *)
  let rec go (e : Resolved.expr) =
    match e.kind with
    | Int n -> string_of_int n
    | Bool b -> string_of_bool b
    | Str s -> show_str s
    | Unit -> "()"
    | Var (Local b) -> b.ident.name
    | Var (Global p | Global_value p) -> value_name p
    | Var (Intrinsic x) -> x
    | Var (Dep_op (p, op)) -> type_name p ^ "." ^ op
    | Unop (Neg, a) -> "-" ^ operand 7 a
    | Unop (Not, a) -> "not " ^ operand 3 a
    | Binop (Orelse, a, b) ->
        (* it groups to the right: `a orelse b orelse c` tries `a`, then `b` *)
        left 1 a ^ " orelse " ^ operand 0 b
    | Binop (op, a, b) ->
        let n = precedence op in
        left n a ^ " " ^ binop_to_string op ^ " " ^ operand (n + 1) b
    | Try a -> "try " ^ go a
    | Attempt a -> "attempt " ^ go a
    | Assert a -> "assert " ^ go a
    | Fail (t, []) -> "fail " ^ t.name
    | Fail (t, args) -> "fail " ^ t.name ^ "(" ^ con_args args ^ ")"
    | Call (f, args) -> left 8 f ^ "(" ^ list args ^ ")"
    | Field (r, f) -> left 8 r ^ "." ^ f.name
    | Index (a, i) -> left 8 a ^ "[" ^ go i ^ "]"
    | Array xs -> "[" ^ list xs ^ "]"
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
    | If _ | Lambda _ | Block _ | Match _ | Assign _ | For _ | With _
    | Handler _ ->
        raise Exit
  and operand n (a : Resolved.expr) =
    match a.kind with
    | Binop (op, _, _) when precedence op < n -> "(" ^ go a ^ ")"
    | Unop (Not, _) when 3 < n -> "(" ^ go a ^ ")"
    | _ -> go a
  (* an operator's left operand, or what a call, field or index is of
     (at 8, tighter than any operator): `try` would otherwise take
     everything after it in *)
  and left n (a : Resolved.expr) =
    match a.kind with Try _ | Attempt _ -> "(" ^ go a ^ ")" | _ -> operand n a
  and list xs = String.concat ", " (List.map go xs)
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
