(* Type inference (see infer.ml). Every type error is reported to the sink,
   and what it returns means nothing if there were any.

   [imports] are the interfaces of the modules it imports (iface.ml), the
   prelude's included, and [reachable] those of every module reachable
   through them, whose types it can meet. [entry], when
   given, is the file of the module the program starts in, which has to
   have a `main`. [tests] are the module's tests, each a function by now
   (test_items.ml): what the runtime installs around each is checked as it
   is for `main`. [bodies] are the functions whose body is a test's,
   which has to be `Unit`. *)

(* What a lookup through a type found, or what else inference decided
   about an expression or pattern that a later pass needs, so it never
   decides it again. *)
type 'l found_ =
  | Function_uses of Path.t
  | Dependency_id of 'l
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string
      (** a constructor, in an expression or a pattern: its type, and its name
      *)
  | Error_tag
      (** a tag inside `Err(...)`, written as a value or matched: one of the
          errors a [Result] holds, not a constructor *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)
  | Installs of { key : 'l; from : Path.t }
      (** a link of a `with`'s item that's an implementation of this dependency,
          a record or a handler's description: what it's installed as, [key],
          with its type arguments, and the dependency it implements, [from],
          which an alias's differs from, `with queue() as Jobs` *)
  | Installs_handler of 'l list
      (** a link that describes a handler of these dependencies, all of which it
          installs *)
  | Calls_op of {
      key : 'l;
      from : Path.t;
      op : string;
      recv : string;
      call : string;
    }
      (** at the [d.op] of [d.op(...)]: an operation called as a method of a
          description, which installs it for the call, as [key], implementing
          [from] (foundations.md, decision 3) *)
  | Inline_op of { dep : Path.t; op : string }
      (** at an inline handler, `handler fn(...) => ...`: the operation of
          [dep] it implements, its only one (foundations.md, decision 3) *)
  | Install_order of int list
      (** at a `with`: the items that install, by their place in it, outermost
          first (handlers.md, "A `with` is a set") *)
  | Handler_facts of {
      forwards : (Path.t * string * Ty.ty) list;
      body_ty : int option;
      any_vars : (int * int * int) option;
      call_vars : (int * int) option;
    }
      (** at a handler: the operations it leaves out, which go to the
          implementation under it, each with its dependency's declared type
          (handlers.md, "`over`"); and if it has a `finally`, the variable that
          stands for the type of the body of a `with` that installs it, which
          its function's own come before, and a [With] passes a descriptor of.
          One `over any` has [any_vars]: the variables of its function's that
          stand for its arm's call's arguments' type and result, and the row
          variable for its errors, which lowering puts each operation's in
          the place of (compiler.md, "`over any` and `retry`"). One with a
          `call` clause has [call_vars]: the variable for the result of the
          call it runs for, and the row variable for its errors, the same way
          (compiler.md, "Services stage", "`D.Call`") *)
  | Handles  (** a `match` that handles errors: one with `fail` arms *)
  | Fail_arm
      (** a `fail` arm's pattern, which matches an error rather than a value *)
  | Unwrap
      (** `try r`, where [r] is a [Result]: what's in it if it's `Ok`, and if
          it's `Err`, its error again *)
  | Block of { name : string; given : 'l list }
      (** a block: a lambda, or a named function or an operation used as a
          value, which lowering makes a lambda written where it's used. Its name
          (Ty.lambda_id), and [given], the dependencies the type of the
          parameter it's passed to lists, which the callee provides: every other
          dependency it uses is found where it's written (foundations.md,
          decision 5) *)
  | Builtin_op
      (** at an operator's own node (Ast.Binop), one the language does itself:
          on [Int]s or [Float]s, a `with numeric` type's, or an opaque type's in
          its own module, on what it's represented as. One that's a method has
          [Method_of] there instead *)
  | Generic_op of string
      (** at an operator's own node, `a + b` on a type variable, or at `T.zero`:
          done by what its type turns out to have of this requirement, `add` *)
  | Tags_given of string list
      (** at `on: A | B`, an argument of a parameter of `Tags`: the tags it
          gives, those of a named error set written out, sorted (compiler.md,
          "`over any` and `retry`") *)
  | Args of Ast.Resolved.expr list
      (** at a call that gives a parameter with a default by name, or leaves
          it out: its arguments in its parameters' order, each one left out
          its default, a literal at a node of its own, whose type is in the
          nodes too (compiler.md, "Stage 11a", "The surface") *)
  | Pulls_block
      (** at a `for` over a block, `for x in try items`: the block, a `fn() ->
          Option<T>`, called each time round until it gives `None` *)
  | Pulled of { what : pulled; name : string }
      (** at a pull argument's own node ([pulled_node]): what's passed to a
          block parameter `fn() -> Option<T>` as `for` takes it, and the name
          of the block Lower makes that pulls it (streams.md, rule 3) *)
  | For_param of int
  | Gen_call of Path.t
  | Gen_step of Path.t
      (** at a call of a handler `for D`'s own node ([for_node]): which of its
          scheme's variables is [D], whose type argument there is the
          implementation it's made for (compiler.md, "Services stage",
          "Stripes") *)

(* A collection, pulled by a snapshot of its elements; or a cursor, by
   calling [next], its method (Infer_env.pulled). *)
and pulled = Snapshot | Cursor of Path.t

(* The node of what the pull argument at a node is pulled by, and of the
   type of the method `next` that a cursor gone over or pulled at a node
   is called through. *)
val pulled_node : int -> int
val next_node : int -> int
val for_node : int -> int

(* What lowering reads: the labels are dependencies with their type
   arguments, in canonical form, numbered as the function's scheme. *)
type found = Ty.label found_

(* Maps keyed by node id (ast.ml). [Map.Make (Int)] is a functor: a module
   that takes a module (here [Int], which says how to compare keys) and
   returns one, a map with that kind of key. Unlike a hash table, a map's
   order is fixed by its keys. *)
module Nodes : Map.S with type key = int

(* An expression or pattern: its type, and what a lookup found there. *)
type node = {
  ty : Ty.ty;
  found : found option;
  narrowed : Path.t list option;
      (** an implementation of several dependencies, narrowed to some of them,
          these, where a written type asks for those *)
  coerce : Sized.coerce option;
      (** a value of a sized type read as what it's stored from, an [Int] or a
          [Float], or one of those stored into a sized type, checked or
          wrapped, or both (sized.ml) *)
  targs : Ty.args option;
      (** a use of a top-level function, a member, an associated value or an
          intrinsic: the type arguments it picked, the n-th for its scheme's
          [Var n] (Ty.args) *)
  needs : (int * string) list;
      (** what the function used there needs of its type arguments: its scheme's
          requirements, [(0, "eq")] for [Var 0] having `==`, sorted. Lowering
          passes a dictionary for each (core.ml, [dict]) *)
}

(* What inference found, in canonical form (ty.ml). A function's scheme and
   its nodes' types number their variables together. *)
type t = {
  schemes : Ty.scheme Path.Map.t;
  generators : Ty.generator Path.Map.t;
  replay_unsafe : Path.t list;
  types : Iface.type_decl list;
      (** each function's type scheme, by its path: a member's is its type's,
          and which member it is (path.ml) *)
  values : Path.t list;
      (** the module's associated values, in the order they're made when the
          program starts: each after every value it uses *)
  nodes : node Nodes.t Path.Map.t;
      (** each function's expressions and patterns, by its path, then node id *)
  in_scope : Path.t list;
      (** the types step 2 of a lookup through a type found (infer_lookup.ml),
          sorted: the import by name of each one is used *)
  opaque_eq : Path.t list;
      (** the module's opaque types that have `==` whatever their type
          arguments, since what each is represented as has no function in it:
          its interface says so, since it hides the representation *)
  opaque : Path.t list;
      (** the opaque types the module sees, its own and those of the modules it
          imports, but the prelude's, sorted: what a handler keeps a resource
          of, which makes it exclusive (Core's [Instance]) *)
}

(* Infer the module [r]'s types, checked against the interfaces [imports]
   and those of everything [reachable]. [entry] is the file of the
   program's entry, which needs a `main`; [tests] are its tests and
   [bodies] the functions whose body is a test's (test_items.ml); and
   [console] is a `ren console` session's function, whose last line's
   value is shown, even a block, with the built-ins it gets the real
   implementation of if it's run: like a test, it runs on the others' test
   implementations (driver.ml). With [sees_all], test code sees the
   whole module, not only what an importer sees (Resolve.program). *)
val program :
  Diag.sink ->
  imports:Iface.t list ->
  reachable:Iface.t list ->
  ?entry:string ->
  ?console:string * string list option ->
  ?sees_all:bool ->
  ?tests:Test_items.test list ->
  ?bodies:string list ->
  Resolve.t ->
  t
