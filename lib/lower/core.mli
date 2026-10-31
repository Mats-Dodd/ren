(* Core: the small, explicitly typed language a checked program is lowered
   to (lower.ml), and that the interpreter runs (eval.ml); see core.ml.

   Core has one way to change something, [Assign] to a local variable.
   Every node says its type, in canonical form (ty.ml), and keeps the
   location of the code it came from. Failing is explicit: [Fail],
   [Handle] and [Finally], and a call fails only if its callee's type says
   it can. So is the evidence every function takes and every block
   captures, and the
   descriptors of types a generic function takes, to show a value of one
   of its type variables by, and the dictionaries of what it needs of
   them, to compare two by. Core Lint (core_lint.ml) checks that all of
   this fits together. *)

type mode = Ty.mode = Read | Inout

(* A local variable. Every use of it carries the same record. *)
type var = { id : int; name : string; ty : Ty.ty }

(* A type as the running program knows it: what a generic function is
   given for each of its type variables, as a hidden parameter, so it can
   show a value of that type (shown.ml) without working the type out. A
   descriptor is built where it's passed, from what's known there: a type
   with none of the function's type variables in it is [Known], and one of
   them is what the function was itself given for it, the way a
   requirement's dictionary will be (compiler.md, "Specialization"). A
   function type has none: a type variable never stands for a block, so
   no type argument is one (Core Lint checks it). *)
type desc =
  | Known of Ty.ty
      (** a type with none of the function's type variables in it, though maybe
          one inference left undecided (see [has_param]) *)
  | Param of var
      (** what one of the function's type variables stands for: the hidden type
          parameter it was given that in (see [fn_def]) *)
  | Applied of Path.t * desc list
      (** a named type, given its arguments: [Option<T>] *)
  | Applied_variant of Path.t * string * desc list
      (** a variant type of a generic sum, given the sum's arguments:
          [Tree.Node<T>] *)
  | Errs of desc_row  (** an error set as a type argument *)

(* An error row's tags, each with its payload, and its tail (Ty.row). *)
and desc_row = { dlabels : (string * desc list) list; dtail : int option }

(* A requirement's dictionary: how a type does what a function needs of
   one of its type variables, `eq` for `==` (compiler.md,
   "Specialization"). A generic function with requirements takes one for
   each, as hidden parameters, and each use of it passes one built from its
   type arguments, as a descriptor is built ([desc]): one of the caller's
   own type variables is the dictionary the caller was itself given for
   it, and any other type's is derived from its structure, given those of
   the caller's type variables in it. Each [==] in a function is done by
   the dictionary of what it compares too. *)
type dict =
  | Dict_param of var
      (** one of the function's own hidden dictionary parameters (see [fn_def]):
          what it was given for one of its requirements *)
  | Derived of {
      req : string;
      dty : Ty.ty;
      ddesc : desc;
      from : ((int * string) * var) list;
    }
      (** [req] of [dty], a type that isn't one of the function's type
          variables, from its structure, its `key` and its members (Infer_reqs):
          [ddesc] describes [dty], so the walk can call a member of a generic
          type with what its parameters stand for, and [from] has the function's
          own dictionary parameters for its type variables in [dty], by the
          variable and the requirement each is for, which is what it can be
          derived from. A type variable inference left undecided has no
          dictionary: no value of its type is ever made *)

(* A dependency as evidence finds it: its path and the descriptors of its
   type arguments, a generic one's instance, `Log<T>`. *)
type dkey = { kpath : Path.t; kargs : desc list }

(* Operations built into the language. Each one's operands are listed in
   the order they're evaluated. *)
(* Whether an index into an array is checked, or proved in bounds
   (bounds.ml): [In_bounds] only where the loop it's in counts [i] up from
   0 or more to below the array's length, which nothing in the loop
   changes. Core Lint checks each one again (Bounds.verify); the
   interpreter checks it anyway, and a native build doesn't. *)
type bounds = Checked | In_bounds

(* Which part a [Slice] is: a range, or a half of a `split_at`. *)
type slicing = Range | Before | After

type prim =
  | Neg
  | Not  (** on a [Bool] *)
  | Binop of Ast.binop
      (** the language's own operator: on [Int]s or [Float]s, or a `with
          numeric` type's, `+` and `-` of two, `*` by what it's represented as
          (operators.md, "Number types"). Never [&&] or [||]: lowering makes
          those [If]s, so their right side is evaluated only when it's needed;
          and never [==] or [!=], which are [Equal] and [Not_equal] *)
  | Equal of dict
      (** [==] on two values of the same type, through that type's `eq`
          dictionary *)
  | Not_equal of dict  (** [!=], the same way *)
  | Compare of Ast.binop * dict
      (** [<], [<=], [>] or [>=] on two values of the same type, through its
          `ord` dictionary: what isn't an [Int] or a [Float], which [Binop]
          compares *)
  | Op of string * dict
      (** an operator on a type variable's values, `add` for `+`, through the
          dictionary of that requirement: two operands, or one for `neg` *)
  | Value_of of string * dict
      (** `zero` or `one` of a type, through that requirement's dictionary: no
          operands *)
  | Length  (** an array's length *)
  | Get_index of bounds  (** [xs[i]]: panics if [i] is out of bounds *)
  | Byte_at of bounds
      (** [b.at(i)], a `Bytes`' byte at [i], 0 to 255: what bounds.ml makes of
          a call of `Bytes.at` it proves in bounds, [In_bounds]. Panics, as the
          call does, if [i] is out of bounds *)
  | Step
      (** [i + 1] of an [Int] local [i] that can't overflow, which bounds.ml
          made of the step of a loop, the last thing a pass does, after its
          test that [i] is below some [Int], with nothing else changing [i]:
          so [i + 1] is at most that [Int]. Core Lint checks each again
          (Bounds.verify) *)
  | Entries
      (** a [Map]'s keys and values, as an array of pairs, in the order each key
          was first set: what a `for` goes over *)
  | Members  (** a [Set]'s members, as an array, in order *)
  | Set_index of bounds
      (** [xs] with element [i] replaced: a new array; panics if [i] is out of
          bounds *)
  | Slice of slicing
      (** part of an [Array], a [Str] or [Bytes], of the same type
          (foundations.md, decision 17): with [Range], [xs[a..b]], from [a] up
          to, but not including, [b], of operands [xs; a; b]; with [Before],
          of operands [xs; n], and [After], of operands [xs; n; lo], the
          halves of `xs.split_at(n)`, [xs[0..n]] and [xs[n..len]], [lo] the
          [Before] just made, which a native build lends [After]'s
          exclusivity through (ren_rt.c, "slices"). [Range] and [Before]
          panic where the range isn't in [xs], or, for a [Str], cuts a
          character; [After] comes right after its [Before], which has
          checked [n] *)
  | Splice
      (** [xs] with its range from [a] up to [b] replaced by [ys], of operands
          [xs; a; b; ys], which may be longer or shorter: what `&xs[a..b]` writes
          back. Its range is the one a [Slice] of [xs] read, so it's in [xs] *)
  | Join  (** [lo] followed by [hi]: what a `split_at` writes back *)
  | Vacant
      (** what a place holds while a `split_at` has lent its value out, of
          operand [xs], the value read from it, and of its type: nothing reads
          it, since the call writes the place (excl.ml), and the place is
          written again after. The interpreter keeps [xs] there; a native
          build a scalar, so the halves are all that hold [xs] and can be
          changed in place (ren_rt.c, "slices") *)
  | New_cell
      (** a new cell holding a value: a `var` of a handler's state, which its
          instance's operations share (see [Handler]). Nothing else holds a
          cell, and a program never sees one *)
  | Get_cell  (** what a cell holds *)
  | Set_cell  (** change what a cell holds, to the second operand *)
  | Widen
      (** a value of a sized type, `UInt8`, as its wide type, `Int` or `Float`,
          the same number: how a field, an element or a variable of one is read
          (sized.ml) *)
  | Narrow
      (** an `Int` or a `Float` as a value of the sized type that's this [Prim]'s
          type: panics if it doesn't fit. How one is stored *)
  | Wrap
      (** an `Int` as a value of the sized integer type that's this [Prim]'s
          type, its low bits: how a wrapping operator's result is stored *)
  | Nan_check of string
      (** its operand, the same, after panicking if a NaN is anywhere in it:
          what an operation of a dependency, named, `Log.put`, is given
          (nan.ml). Its type is its operand's *)
  | Tag_in of string list
      (** whether its operand, an error, has one of these tags: what a `fail
          on` arm matches, `on` being a parameter of `Tags` (compiler.md,
          "`over any` and `retry`"), in a function made for the tags it's
          given. A [Bool] *)

type ownership = Copy_value | Adopt_value | Snapshot_value
    (** [Snapshot_value] keeps independent logical positions for an implicit
        collection snapshot; it owns no cleanup until an item is copied out. *)
type assignment = Replace_value | Advance_value

type param = { mode : mode; var : var }

type expr = { kind : kind; ty : Ty.ty; loc : Loc.t }

and kind =
  | Return of Path.t * expr
      (** return to this function, through every intervening cleanup *)
  | Gen_create of {
      producer : Path.t;
      type_args : Ty.args;
      args : arg list;
      places : gen_place list;
      tys : desc list;
      dicts : dict list;
      ev : var;
    }
      (** create a checked producer's frame; creation does not run its body *)
  | Yield of expr
  | Yield_from of { pull : expr; adapter : bool }
      (** [adapter] is true only for a compiler-built protocol lambda: applying
          that immediate wrapper does not add a logical call-depth level *)
  | Gen_step of { cursor : var; ev : var; errors : Ty.row; uses : Ty.row }
  | Gen_close of expr
  | Source_view of { retained : bool; value : expr }
      (** provenance for a pattern source only; this does not construct data *)
  | Pattern_scope of {
      owner : var;
      receiving : var;
      binding : var option;
          (** the spelling of an ignored [Let], for printing and native erasure;
              this is not a runtime or pattern binding *)
      source : expr;
      pat : pattern;
      on_match : expr;
      on_else : expr option;
    }
      (** evaluate the source once in its statement registry, transfer matched
          binders to [receiving], close discarded leaves, then run [on_match];
          an else runs inside the statement registry before leaving it *)
  | Instance_scope of { owner : var; body : expr }
      (** a registry transferred to the installed instance until its with ends *)
  | Cleanup_scope of { owner : var; body : expr }
      (** bind a lexical cleanup registry; detach the anonymous result before
          closing its current and retired tokens in reverse registration order *)
  | Own of { owner : var; mode : ownership; value : expr; desc : desc }
      (** recursively fork a source copy, or adopt an anonymous result, into
          this lexical registry; descriptors include opaque and generic leaves *)
  | Owned_assign of { target : var; value : expr; mode : assignment }
      (** the target cell retains its original root owner through inout calls;
          replacement retires displaced leaves, advancement updates their state *)
  | Owner_alias of { target : var; root : var; body : expr }
      (** a projected inout temporary borrows its root's owner capability *)
  | Int of Int64.t
  | Float of float
  | Bool of bool
  | Str of string
  | Unit
  | Local of var
  | Global of Path.t * Ty.args * desc list * dict list
      (** a top-level function, or a member's, [Stack.push], and the type
          arguments it's used at (Ty.args): [ty] is its scheme with them put in.
          They're on the use, not on a [Call], since a function can be used
          without being called, `let f = id`. A method call, [s.push(1)], is a
          call of its function, with [s] first. The [desc]s describe the types
          of the type arguments, one each, and are what it's passed for its
          hidden type parameters. The [dict]s are what it's passed for its
          hidden dictionary parameters: one for each of its scheme's
          requirements, in order, for the type argument it's on *)
  | Global_value of Path.t * Ty.args
      (** an associated value, [Stack.empty], which the program makes once when
          it starts: its function of no parameters, called then. [ty] is its
          type with the type arguments put in. Being made once, it's given no
          descriptors or dictionaries: what its type variables stand for isn't
          known when it's made *)
  | Intrinsic of Intrinsic.t * Ty.args * desc list * dict list
      (** a function built into the compiler: [show], or a method, [Array.push],
          and the type arguments it's used at, their descriptors and the
          dictionaries for its requirements, as a [Global]'s: [Map.get] needs
          `hash` of its keys' type *)
  | Dep_call of {
      dep : Path.t;
      dargs : desc list;  (** [dep]'s type arguments, if it's generic *)
      op : string;
      fty : Ty.ty;  (** the operation's type, at this call *)
      ev : var;  (** the evidence it finds [dep]'s implementation in *)
      next : bool;
          (** a call through `next`: [ev] is then the evidence of the [Handler]
              it's in, where it was installed, so the innermost [dep] in it is
              the one the handler is over. A block in the handler captures that
              evidence, as it captures the evidence where it's written *)
      args : expr list;
    }
      (** [Clock.now()]: a call of an operation of the innermost implementation
          of [dep] in [ev], which runs with the evidence that implementation was
          installed with. Kept apart from other calls, so what was called, with
          what, can be recorded (the journal, stage 10b). Never with `&` *)
  | With of {
      ev : var;
      outer : var;
      dep : Path.t;
      dargs : desc list;  (** [dep]'s type arguments, if it's generic *)
      from : Path.t;
          (** the dependency of [impl]'s that's installed: [dep], or for an
              alias, the one it's an alias of *)
      impl : expr;
      desc : desc;
      body : expr;
    }
      (** [body], with the evidence [ev]: [outer], the evidence here, with
          [impl] installed for [dep] on top. [impl] is a value of [dep]'s type:
          a record, installed as it is, or a handler's description, of which a
          fresh instance is made with [outer], and its implementation of [dep]
          installed. Either keeps [outer], which its operations run with. Making
          the instance can fail, as the implementation's type says (Ty.impl). If
          the instance has a `finally`, it's given [body]'s outcome, `Ok` of its
          value or `Err` of its error, and [desc], which describes [body]'s
          type, and what it gives is the [With]'s. The runtime's installs around
          `main` are these *)
  | Handler of { ev : var; captures : var list; body : expr }
      (** a handler, described: what calling a `handler` declaration gives. Like
          a lambda of no parameters it keeps [captures], and its [body] runs
          with the evidence [ev] it's given, each time a [With] or a
          [With_handler] installs it: it makes the handler's state, each `var`
          in a cell, and ends in an [Instance]. Its type is its dependency's, if
          it implements one, or else the type that lists them, either needing
          what its operations use *)
  | Instance of {
      impls : (Path.t * expr) list;
      finally : expr option;
      exclusive : bool;
    }
      (** a handler's instance: an implementation of each of its dependencies,
          in the order they're written, records of lambdas that share the cells
          of one state, and its `finally`, a lambda that shares them too. Of its
          [Handler]'s type, which lists them sorted. The `finally` takes the
          descriptor of the body's type of the `with` that installs it, then its
          outcome, a [Result] of that type, whose variable is the one after its
          handler's function's own, [Var n] (Handler_facts.body_ty), and gives
          what the [With] gives. [exclusive] says its operations need to
          keep it from each other's tasks, once a spawned task can reach it:
          its state has a `var`, or a `let` or parameter of an opaque type of
          the program's (compiler.md, "Operations that don't interleave") *)
  | Narrowed of Path.t list * expr
      (** a description of a handler of several dependencies, narrowed to some
          of them, where a written type asks for those: a [With] or a
          [With_handler] installs only its implementations of those. Of their
          type ([Ty.impl]), needing what the handler does *)
  | With_handler of {
      ev : var;
      outer : var;
      handler : expr;
      deps : (dkey * Path.t) list;
          (** each key installed, with the instance's implementation of the path
          *)
      desc : desc;
      body : expr;
    }
      (** [body], with the evidence [ev]: [outer] with a fresh instance of
          [handler], made with [outer], installed on top, for each of [deps].
          Those are what [handler]'s type lists, sorted: the instance may
          implement more, if it was narrowed ([Narrowed]), which aren't
          installed. The instance's implementations all keep [outer], which
          their operations run with. Its `finally`, if it has one, runs as a
          [With]'s does *)
  | Prim of prim * expr list
  | Let of var * expr * expr  (** [let x = value in body] *)
  | Assign of var * expr  (** the only way anything changes *)
  | If of expr * expr * expr
  | Match of expr * arm list
  | While of expr * expr  (** the condition, then the body *)
  | Break
      (** leave the innermost [While] around it, which is in the same function
          or block, never outside a [Lambda], a [Handler] or a [With]'s body
          (Core Lint); of any type, since it never ends. A [Finally] it leaves
          runs its [after] first *)
  | Seq of expr * expr  (** the first's value is dropped *)
  | Call of expr * arg list * var
      (** the callee, its arguments, and the evidence it's passed: always the
          caller's own, the innermost in scope *)
  | Lambda of {
      name : string;
      params : param list;
      ev : var;
      outer : var;
      given : dkey list;
      captures : var list;
      body : expr;
    }
      (** a block. [captures] are the locals from outside it its body uses, in
          order of id, and [outer], the evidence where it's written, among them;
          it shares their cells, capturing them by reference. Its body runs with
          the evidence [ev]: [outer], with the implementations of [given] in the
          evidence its caller passes put on top (foundations.md, decision 5).
          [given] are the dependencies the type of the parameter it's passed to
          lists, which the callee provides, sorted; usually none, and then [ev]
          is [outer]. [name] is its name, for printing and for the code a
          release build specializes for it: one written in the program's
          (Ty.lambda_id), which a named function or an operation used as a
          value, a block that calls it, gets too; or, for an operation a handler
          leaves to the one under it, the operation's path *)
  | Con of Path.t * string * expr list
      (** a constructor: its type, its name, its fields in order *)
  | Record of Path.t * (string * expr) list  (** in the order written *)
  | Field of expr * Path.t * string
      (** [r.f], and the record type of [r]; or the sum type, when [r] is a
          value of one of its variant types, [Order.Placed], a field read at a
          known constructor *)
  | Update of expr * string * expr
      (** the record with one field replaced: a new record; or a new value of
          [r]'s variant type *)
  | Of_variant of expr
      (** a value of a variant type, [Order.Placed], as its sum, [Order]: the
          same value, so no code (compiler.md, "Data stage", "Variant types").
          What [Placed { ..p }] with nothing else given is *)
  | Array of expr list
  | Tuple of expr list  (** [(k, v)]: two parts, or three *)
  | Tag of string * expr list * desc list
      (** an error, [Short(id, 5)]: its tag, its payload in order, and the
          descriptor of each of the payload's types. Its type is [Errors] of the
          one tag, or of a set that has it. An error is a value only in Core,
          which raises one with [Fail] and catches one with [Handle]. The error
          carries its payload's types at runtime: an error a row variable's tail
          brings into a set is one nothing else says the type of, and `==`,
          `hash` and `show` go through those types' keys and members (walk.ml)
      *)
  | Fail of expr  (** stop with this error; of any type, since it never ends *)
  | Handle of {
      body : expr;
      value : var;
      on_value : expr;
      error : var;
      on_error : expr;
    }
      (** run [body]. If it ends, its value is [value], and the [Handle] is
          [on_value]; if it fails, its error is [error] (of an [Errors] type),
          and the [Handle] is [on_error]. Neither of those is handled here: what
          they fail with goes on *)
  | Assert of expr
      (** panic if this [Bool] is false: `assert e` (deps.md, "`assert`"). A
          [Unit] *)
  | Assert_equal of expr * expr * desc * dict
      (** panic if these two, of the same type, differ, showing both: `assert a
          == b`, compared through the `eq` dictionary of their type and shown
          through its descriptor. A [Unit] *)
  | Finally of expr * expr
      (** [body], then [after], a [Unit], which runs whether [body] fails or
          not, and doesn't change what [body] did: its value, or its error,
          which goes on once [after] has run. Lowering writes a place passed
          with `&` back to it in [after], so a call that fails still changes it
      *)
  | Covered of { body : expr; result : var; after : expr; return_target : Path.t option }
      (** an arm's `finally` (handlers.md, "`finally`"): [body], what it covers,
          as `attempt` keeps it, a [Result] of what it ends in, bound to
          [result], then [after], whose value is the node's. It's [Let] but
          for a task that's cancelled in [body] (compiler.md, "Stage 11a",
          "Cancellation"): then [result] is `Err(Cancelled)`, [after] runs
          shielded, and the cancel goes on once it has, what it gave thrown
          away. So [result]'s errors have `Cancelled` too. Natively, where
          nothing is cancelled, it's that [Let] *)

(* A call's argument. An [inout] argument is always a plain local: the call
   reads it, and writes the parameter's final value back to it. *)
and arg = Value of expr | Ref of var
and gen_place = { param : var; root : var; read : expr; write : expr }
    (** a frozen projected inout argument: refresh [param] from its original
        root before each active step, then write it back on every suspension
        and exit; neither callback runs at factory return or a terminal step *)
and arm = { pat : pattern; guard : expr option; body : expr }
and pattern = { pkind : pattern_kind; pty : Ty.ty; ploc : Loc.t }

and pattern_kind =
  | PWild
  | PVar of var
  | PInt of Int64.t
  | PBool of bool
  | PCon of Path.t * string * pattern list
  | PTag of string * pattern list  (** an error with this tag, destructured *)
  | PTuple of pattern list  (** [(k, v)]: a tuple, taken apart *)
  | PRecord of Path.t * pattern list
      (** [{ id, .. }]: a record of this type, taken apart, a pattern for each
          of its fields in declaration order, [PWild] for one the pattern
          leaves out *)
  | POr of pattern list
      (** any of these; each binds the same variables (the same [var]s) *)
  | PAs of pattern * var
      (** [p as x]: what [p] matches, the whole bound to [x] too (compiler.md,
          "Data stage", "`as`") *)
  | PStr of string  (** ["GET"]: a `Str` equal to it *)
  | PStr_rest of { prefix : string; rest : var option; suffix : string }
      (** ["Bearer " ..token]: a `Str` that starts with [prefix] and ends
          with [suffix], at least as long as the two, [rest] bound to the
          slice between them, if it's named (compiler.md, "Patterns
          stage") *)
  | PArray of { front : pattern list; rest : rest; back : pattern list }
      (** [[first, ..rest]]: an `Array` of the length [front] and [back]
          have between them, or with a [rest], at least that long, its
          middle bound to a slice of it if it's named *)

(* An array pattern's rest: none, a fixed length; or `..`, bound or
   not. *)
and rest = No_rest | Rest of var option

(* Where a function came from. The specializer makes the others, each
   from what the program wrote (specialize.ml). *)
type origin =
  | Written  (** lowered from the program *)
  | Copy of Path.t
      (** a copy of this function, specialized for the types, blocks and
          handlers a call gives it *)
  | Lifted_block of string
      (** a block, by its name (Lambda's [name]), lifted out of the function
          it's written in: its captures are parameters before its own *)
  | Lifted_op of { dep : Path.t; handler : Path.t; op : string }
      (** the operation [op] of [handler]'s implementation of [dep], lifted: the
          handler's state, its cells and what it keeps, are parameters before
          the operation's own. Called directly where that handler is known to be
          installed ([known]) *)

(* At the evidence [kev], the implementation of [kdep], a dependency that
   isn't generic, is known: an
   instance of the handler [khandler], whose state is in the frame of
   the [With] that installed it, so a call of one of its operations is a
   direct call of the operation, lifted ([Lifted_op]), and the [With]
   installs nothing in a native build. *)
type known = { kev : var; kdep : Path.t; khandler : Path.t }

type fn_def = {
  path : Path.t;
  params : param list;
  ev : var;  (** its evidence, the hidden parameter every function takes *)
  tys : var list;
      (** its hidden type parameters, one for each of its scheme's type
          variables: the n-th holds the descriptor of what [Var n] stands for
          ([desc]), and is the local [type_param n] *)
  dicts : var list;
      (** its hidden dictionary parameters, one for each of its scheme's
          requirements, in order: the j-th, for [(n, req)], holds [req]'s
          dictionary for what [Var n] stands for ([dict]), and is the local
          [dict_params]'s j-th *)
  generator : Ty.generator option;
      (** a producer has a Unit body; its callable scheme describes creation *)
  scheme : Ty.scheme;  (** its type, whose variables its nodes' types share *)
  body : expr;
  test : bool;
      (** test code (ast.ml): a test item, or a function made of a test. Only
          test code calls one, which Lint checks, so `ren run` leaves them out
      *)
  loc : Loc.t;  (** its name, where it's declared *)
  origin : origin;
      (** where it came from: lowered from what's written, or made by a release
          build's specializer (specialize.ml) *)
  known : known list;
      (** the evidence in it whose implementation of a dependency is known, by
          the variable: its own, a [With]'s or a block's. Only the specializer
          knows any (compiler.md, "Specialization") *)
}

(* A method call on a description, `c.area()` (compiler.md, "Data
   stage", "Descriptions"): lowered as the [With] that installs [c] for
   the call, at [mloc], so it's recorded beside, for Stateless, which
   refuses one that may reach a handler with state. *)
type method_call = {
  mdep : Path.t;  (** the dependency whose operation it calls *)
  mrecv : string;  (** the receiver, as written, `c` *)
  mcall : string;
      (** the `with` that makes the call, as the help writes it, `with c in
          Area.area()` *)
  mloc : Loc.t;  (** the [With]'s *)
  mop : Loc.t;  (** the operation's name, where the error points *)
}

(* A module, lowered. [types] are the types it declares. *)
type program = {
  home : string;
  types : Iface.type_decl list;
  fns : fn_def list;
  values : Path.t list;
      (** its associated values, in the order they're made, each after every
          value it uses; each is one of [fns], of no parameters *)
  shows : (Path.t * Path.t) list;
      (** the types it declares that show their values through a `show` method
          of their own (shown.ml), each with that method's function, which takes
          only a value of the type, with the type's parameters as its type
          variables, in order, and gives a [Str] without failing or using a
          dependency *)
  keys : (Path.t * Path.t) list;
      (** the types it declares that have a `key`, each with that method's
          function, which takes only a value of the type, with the type's
          parameters as its type variables, in order, without failing or using a
          dependency: what it's equal, hashed and ordered by *)
  ops : ((Path.t * string) * Path.t) list;
      (** the types it declares that have an operator or an associated value for
          a requirement, `add` or `zero`, by the type and the requirement, each
          with the member that gives it: an operator that takes one of the type
          and gives one, or a value of the type (Infer_reqs) *)
  method_calls : method_call list;
      (** each method call on a description in its functions, in no order *)
}

(* ---- building ---- *)

(* A node of this kind and type, from the code at this location. *)
val mk : kind -> Ty.ty -> Loc.t -> expr

(* The type of evidence, which no type in Ren source can name. *)
val evidence_ty : Ty.ty

(* A lexical generator cleanup registry, inaccessible from source. *)
val owner_ty : Ty.ty

(* The evidence a function takes, or a block or a [With] binds, as the
   local with this id. *)
val evidence : int -> var

(* The type of a type's descriptor ([desc]), which no type in Ren source
   can name either. *)
val type_ty : Ty.ty

(* A function's hidden type parameter for its type variable [n], a local
   of [type_ty] whose id, [-1 - n], is apart from every other local's. *)
val type_param : int -> var

(* The hidden type parameters of a function of this scheme, in order. *)
val type_params : Ty.scheme -> var list

(* Whether a type has any of a function's [n] type variables in it,
   [Var 0] to [Var (n - 1)]. Any other is one inference left undecided. *)
val has_param : int -> Ty.ty -> bool

(* The descriptor of a type written in the type variables of a function
   whose hidden type parameters are these: [Var n] is the n-th. *)
val describe : var list -> Ty.ty -> desc

(* The hidden type parameters a descriptor uses. *)
val desc_vars : desc -> var list

(* The key of a dependency of a type written in the type variables of a
   function whose hidden type parameters are given, and the hidden type
   parameters a key uses. *)
val key_of : var list -> Ty.dep -> dkey
val key_vars : dkey -> var list

(* A descriptor, and a dependency's key, as a print shows them: `Log<Int>`,
   or for one that isn't generic, its path. *)
val show_desc : desc -> string
val show_key : Path.t -> desc list -> string

(* The type of a requirement's dictionary ([dict]), which no type in Ren
   source can name either. *)
val dict_ty : Ty.ty

(* The hidden dictionary parameters of a function of this scheme, one for
   each of its requirements, in order: [$eq0] for [(0, "eq")]. Their ids
   are negative, after its hidden type parameters'. *)
val dict_params : Ty.scheme -> var list

(* The type variables among a function's [n], [Var 0] to [Var (n - 1)],
   that a type has in it, each once, in order. *)
val params_in : int -> Ty.ty -> int list

(* [dict_for tys own req t] is [req]'s dictionary for [t], a type written
   in the type variables of a function whose hidden type parameters are
   [tys], and whose own dictionary parameters are [own], by the
   requirement each is for: [Var m]'s is its own, and any other type's is
   derived, from what it's given for the type variables in it. Fails with
   [Not_found] if the function hasn't a requirement that takes. *)
val dict_for :
  var list -> ((int * string) * var) list -> string -> Ty.ty -> dict

(* The hidden dictionary parameters a dictionary uses, and the hidden type
   parameters its descriptor does. *)
val dict_vars : dict -> var list

(* The type of a cell holding a value of this type (see [New_cell]). *)
val cell_ty : Ty.ty -> Ty.ty

(* [()], and a use of a local, of its type. *)
val unit : Loc.t -> expr
val local : var -> Loc.t -> expr

(* The type of an array's elements, or of what's in an [Option]. Fails with
   [Invalid_argument] for any other type. *)
val elem_ty : Ty.ty -> Ty.ty

(* Whether calling a function of this type can fail: whether its errors
   row has a tag, or may have more than it says. *)
val fails : Ty.ty -> bool

(* The expressions directly inside one, in the order they're evaluated,
   a lambda's or handler's body last. *)
val children : expr -> expr list

(* Whether running an expression can fail: whether it can reach a [Fail]
   or a call that can fail that no [Handle] in it catches. A lambda's
   body fails only when it's called. *)
val can_fail : expr -> bool

(* Whether a handler's body, or part of one, ends in its [Instance]: one
   in its [Let]s', [Seq]s' and [Covered]s' last part, a [Handle]'s body or
   an arm of a [Match]. The state's `let PATTERN = value` is a [Match]
   whose arm that binds it is the rest of the state; with an `else`, its
   other arm leaves, and ends in none (lower.ml, [take_apart]). *)
val ends_in_instance : expr -> bool

(* Whether evaluating it can stop at a cancel (compiler.md, "Stage 11a",
   "Cancellation"): it makes a call, a dependency's or a function's, or
   installs something, which can reach a dependency call or a wait. *)
val can_stop : expr -> bool

(* ---- printing, as s-expressions, for tests ---- *)

type sexp = Atom of string | List of sexp list

(* An s-expression, starting at this column: a list that fits on its line
   is printed on it, and one that doesn't goes on over several, indented. *)
val render : int -> sexp -> string

(* A primitive's name, as printed: [neg], [get], [==]. *)
val show_prim : prim -> string

(* An expression, or a function, as an s-expression, and printed. A local
   prints as its name and binder id, [x/3]. *)
val sexp : expr -> sexp
val show : expr -> string

(* [types] prints a function typed: its type after its name, and what it
   needs, [(needs (eq T))], if anything; each use of a top-level function
   that has type arguments with them, as [(inst first_or Int)], a row
   argument in braces, [{Short | ..e}], and the dictionaries it's given
   after them; and the dictionary each [==] compares with, [(== (eq Int) a
   b)]. A plain print, the default, shows none of these. *)
(* [ownership] shows the lexical cleanup registries and source copy/adopt
   boundaries; the default keeps existing Core prints concise. *)
val fn_sexp : ?types:bool -> ?ownership:bool -> fn_def -> sexp
val show_fn : ?types:bool -> ?ownership:bool -> fn_def -> string

(* A string or array pattern's kind with each of its pieces mapped by
   [pat] and its rest's variable by [var], left to right; any other kind
   as it is. For the passes that walk patterns. *)
val map_seq :
  pat:(pattern -> pattern) -> var:(var -> var) -> pattern_kind -> pattern_kind

(* The pieces of an array pattern, in order; none of any other. *)
val seq_pieces : pattern_kind -> pattern list

(* The variable a string or array pattern's rest is bound to. *)
val seq_rest : pattern_kind -> var list
