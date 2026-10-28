(* Core: the small, explicitly typed language a checked program is lowered
   to (lower.ml), and that the interpreter runs (eval.ml).

   The surface tree has many ways to say "change something": `x.f += 1`,
   `xs[i] = v`, `f(&x.f)`, `for p in &ps`. Core has one: [Assign] to a
   local variable. Everything else is spelled out with plain operations, a
   record update or an array update that builds a new value, and an
   assignment of it back to the variable. So nothing after lowering needs
   to know what a place is.

   Every node says its type, in canonical form (ty.ml), and keeps the
   location of the code it came from, so a panic can point at it. A local
   is known by its binder's id (numbered per top-level function, as in
   ast.ml; lowering numbers its temporaries after the function's own
   locals). Constructors, record types and fields say which type they
   belong to, which inference found. core_lint.ml checks that all of this
   fits together.

   Failing is explicit too (errors.md). [Fail] stops with an error, which
   is a value of its own, a [Tag]. A call whose callee's type says it can
   fail passes on whatever the callee fails with, and nothing else does.
   [Handle] is the one place an error is caught, and [Finally] runs
   something on the way out whether the code before it failed or not. So a
   backend that compiles to C can make each function that can fail return
   its error, and check for one after each call that can fail.

   Dependencies are explicit too (deps.md, "How it runs"). Every function
   takes one hidden parameter, its evidence: the vector of the
   implementations installed where it's called, pure ones too, so no two
   places can disagree on what a function takes. Every call passes the
   caller's evidence on, a [With] extends it with an implementation for
   its body, and a [Dep_call] finds its dependency's implementation in it,
   by the dependency's path, never by a name the program spells. A block
   captures the evidence where it's written, as it captures a local, and
   takes from the evidence its caller passes only the dependencies its
   parameter's type lists (foundations.md, decision 5). A [Dep_call]
   through `next` in a handler uses the evidence where the handler was
   installed, which a block in the handler captures too (handlers.md,
   "How it runs").

   So are types, where the running program needs one: to show a value
   (shown.ml). A generic function takes a hidden parameter for each of its
   type variables, holding a descriptor of what it stands for ([desc]),
   and each use of it passes descriptors built from its type arguments, as
   an `assert a == b` keeps one of its sides' type. The interpreter only
   evaluates them: it never works a type out. And so are requirements: a
   generic function that needs `eq` of a type variable takes a hidden
   dictionary parameter for it ([dict]), each use of it passes one built
   from its type arguments, and each [==] compares through one. *)

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

(* Operations built into the language. Each one's operands are listed in
   the order they're evaluated. *)
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
  | Get_index  (** [xs[i]]: panics if [i] is out of bounds *)
  | Entries
      (** a [Map]'s keys and values, as an array of pairs, in the order each key
          was first set: what a `for` goes over *)
  | Members  (** a [Set]'s members, as an array, in order *)
  | Set_index  (** [xs] with element [i] replaced: a new array *)
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

type param = { mode : mode; var : var }

type expr = { kind : kind; ty : Ty.ty; loc : Loc.t }

and kind =
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
  | Instance of { impls : (Path.t * expr) list; finally : expr option }
      (** a handler's instance: an implementation of each of its dependencies,
          in the order they're written, records of lambdas that share the cells
          of one state, and its `finally`, a lambda that shares them too. Of its
          [Handler]'s type, which lists them sorted. The `finally` takes the
          descriptor of the body's type of the `with` that installs it, then its
          outcome, a [Result] of that type, whose variable is the one after its
          handler's function's own, [Var n] (Handler_facts.body_ty), and gives
          what the [With] gives *)
  | Narrowed of Path.t list * expr
      (** a description of a handler of several dependencies, narrowed to some
          of them, where a written type asks for those (deps.md,
          "Implementations"): a [With] or a [With_handler] installs only its
          implementations of those. Of their type ([Ty.impl]), needing what the
          handler does *)
  | With_handler of {
      ev : var;
      outer : var;
      handler : expr;
      deps : Path.t list;
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
      given : Path.t list;
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
  | Field of expr * Path.t * string  (** [r.f], and the record type of [r] *)
  | Update of expr * string * expr
      (** the record with one field replaced: a new record *)
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

(* A call's argument. An [inout] argument is always a plain local: the call
   reads it, and writes the parameter's final value back to it. *)
and arg = Value of expr | Ref of var
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
  | POr of pattern list
      (** any of these; each binds the same variables (the same [var]s) *)

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

(* At the evidence [kev], the implementation of [kdep] is known: an
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
}

(* ---- building ---- *)

let mk kind ty loc = { kind; ty; loc }

(* The type of evidence. Nothing in Ren source has it: its `$` keeps it
   apart from every type a program can name. *)
let evidence_ty = Ty.Con (Path.prelude "$Evidence", [])

(* The evidence a function takes, or a block or a [With] binds. *)
let evidence id = { id; name = "ev"; ty = evidence_ty }

(* The type of a type's descriptor, which, like evidence, no type in Ren
   source can name. *)
let type_ty = Ty.Con (Path.prelude "$Type", [])

(* A function's hidden type parameter for its type variable [n]. Its id is
   negative, apart from every local's, so adding them didn't change how
   any local is numbered. *)
let type_param n = { id = -1 - n; name = "$ty" ^ string_of_int n; ty = type_ty }

(* The hidden type parameters of a function of scheme [s]. *)
let type_params (s : Ty.scheme) =
  List.mapi (fun n _ -> type_param n) (Ty.own_args s.ty).tys

(* The type of a requirement's dictionary ([dict]), which no type in Ren
   source can name either. *)
let dict_ty = Ty.Con (Path.prelude "$Dict", [])

(* The hidden dictionary parameters of a function of scheme [s], one for
   each of its requirements, in order, named after it: [$eq0] for
   [(0, "eq")]. Their ids are negative too, after its hidden type
   parameters'. *)
let dict_params (s : Ty.scheme) =
  let ntys = List.length (Ty.own_args s.ty).tys in
  List.mapi
    (fun j (n, req) ->
      { id = -1 - ntys - j; name = "$" ^ req ^ string_of_int n; ty = dict_ty })
    s.reqs

(* Whether [t] has any of the type variables [Var 0] to [Var (n - 1)] in
   it: one of a function's, if it has [n]. A type in its body can have
   others, which inference left undecided, since nothing depends on them:
   the type of what `Ok` holds in `Err(Gone(1))`, say. *)
let rec has_param n (t : Ty.ty) =
  let row (r : Ty.row) =
    List.exists
      (fun (l : Ty.label) -> List.exists (has_param n) l.payload)
      r.labels
  in
  match t with
  | Var m -> m < n
  | Con (_, args) -> List.exists (has_param n) args
  | Fun (ps, r, e, u) ->
      List.exists (fun (p : Ty.param) -> has_param n p.ty) ps
      || has_param n r || row e || row u
  | Errors r -> row r
  | Impl i -> row i.needs || row i.fails
  | Error -> false

(* The descriptor of [t], a type written in the type variables of a
   function whose hidden type parameters are [tys]: [Var n] is the n-th.
   A type variable inference left undecided is known to be just that: a
   value of its type is shown by its shape alone (shown.ml). *)
let rec describe tys (t : Ty.ty) =
  let row (r : Ty.row) =
    {
      dlabels =
        List.map
          (fun (l : Ty.label) -> (l.name, List.map (describe tys) l.payload))
          r.labels;
      dtail = r.tail;
    }
  in
  match t with
  | _ when not (has_param (List.length tys) t) -> Known t
  | Var n -> Param (List.nth tys n)
  | Con (p, args) -> Applied (p, List.map (describe tys) args)
  | Fun _ ->
      (* a type variable never stands for a block (Core Lint), so no
         function type with one of them in it is described *)
      invalid_arg "Core.describe: a function type with type variables"
  | Errors e -> Errs (row e)
  | Impl _ | Error -> Known t

(* The type variables among [Var 0] to [Var (n - 1)] that [t] has in it,
   each once, in order. *)
let params_in n (t : Ty.ty) =
  let rec go acc (t : Ty.ty) =
    let row acc (r : Ty.row) =
      List.fold_left
        (fun acc (l : Ty.label) -> List.fold_left go acc l.payload)
        acc r.labels
    in
    match t with
    | Var m when m < n -> m :: acc
    | Var _ | Error -> acc
    | Con (_, args) -> List.fold_left go acc args
    | Fun (ps, r, e, u) ->
        row
          (row
             (go
                (List.fold_left (fun acc (p : Ty.param) -> go acc p.ty) acc ps)
                r)
             e)
          u
    | Errors r -> row acc r
    | Impl i -> row (row acc i.needs) i.fails
  in
  List.sort_uniq compare (go [] t)

(* [req]'s dictionary for [t], a type written in the type variables of a
   function of [n] of them, whose own dictionary parameters are [own], by
   the requirement each is for: [Var m]'s is its own, and any other type's
   is derived. Fails with [Not_found] if the function hasn't a requirement
   that takes. *)
let dict_for tys own req (t : Ty.ty) =
  let n = List.length tys in
  match t with
  | Var m when m < n -> Dict_param (List.assoc (m, req) own)
  | _ ->
      let vars = params_in n t in
      Derived
        {
          req;
          dty = t;
          ddesc = describe tys t;
          from = List.filter (fun ((m, _), _) -> List.mem m vars) own;
        }

(* The hidden type parameters a descriptor uses. *)
let rec desc_vars = function
  | Known _ -> []
  | Param v -> [ v ]
  | Applied (_, ds) -> List.concat_map desc_vars ds
  | Errs e -> desc_row_vars e

and desc_row_vars r =
  List.concat_map (fun (_, ds) -> List.concat_map desc_vars ds) r.dlabels

(* The hidden dictionary parameters a dictionary uses, and the hidden type
   parameters its descriptor does. *)
let dict_vars = function
  | Dict_param v -> [ v ]
  | Derived { from; ddesc; _ } -> List.map snd from @ desc_vars ddesc

(* The type of a cell holding a [t] (see [New_cell]). *)
let cell_ty t = Ty.Con (Path.prelude "$Cell", [ t ])
let unit loc = mk Unit Ty.unit loc
let local (v : var) loc = mk (Local v) v.ty loc

(* The type of an array's elements, or of what's in an [Option]. *)
let elem_ty (t : Ty.ty) =
  match t with
  | Con (_, [ elem ]) -> elem
  | _ -> invalid_arg "Core.elem_ty: not an array"

(* Whether calling a function of type [t] can fail: whether its errors
   row has a tag, or may have more than it says. *)
let fails (t : Ty.ty) =
  match t with
  | Fun (_, _, errs, _) -> errs.labels <> [] || errs.tail <> None
  | _ -> false

(* The expressions directly inside [e], in the order they're evaluated (a
   lambda's body, which isn't evaluated where the lambda is made, comes
   last). *)
let children (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Global _
  | Global_value _ | Intrinsic _ | Break ->
      []
  | Prim (_, es)
  | Array es
  | Tuple es
  | Con (_, _, es)
  | Tag (_, es, _)
  | Dep_call { args = es; _ } ->
      es
  | With { impl; body; _ } -> [ impl; body ]
  | With_handler { handler; body; _ } -> [ handler; body ]
  | Instance { impls; finally } -> List.map snd impls @ Option.to_list finally
  | Let (_, a, b)
  | While (a, b)
  | Seq (a, b)
  | Update (a, _, b)
  | Finally (a, b)
  | Assert_equal (a, b, _, _) ->
      [ a; b ]
  | Assign (_, a)
  | Assert a
  | Field (a, _, _)
  | Narrowed (_, a)
  | Fail a
  | Lambda { body = a; _ }
  | Handler { body = a; _ } ->
      [ a ]
  | If (c, t, f) -> [ c; t; f ]
  | Match (s, arms) ->
      s :: List.concat_map (fun a -> Option.to_list a.guard @ [ a.body ]) arms
  | Call (f, args, _) ->
      f :: List.filter_map (function Value a -> Some a | Ref _ -> None) args
  | Record (_, fs) -> List.map snd fs
  | Handle { body; on_value; on_error; _ } -> [ body; on_value; on_error ]

(* Whether running [e] can fail: whether it can reach a [Fail] or a call
   that can fail, that no [Handle] in it catches. A lambda's body runs only
   when it's called, so only the call can fail. *)
let starts_failing (t : Ty.ty) =
  match t with Impl { fails; _ } -> fails.labels <> [] | _ -> false

let rec can_fail (e : expr) =
  match e.kind with
  | Fail _ -> true
  | Call (f, _, _) when fails f.ty -> true
  | Dep_call { fty; _ } when fails fty -> true
  | With { impl; _ } when starts_failing impl.ty -> true
  | With_handler { handler; _ } when starts_failing handler.ty -> true
  | Handle { on_value; on_error; _ } -> can_fail on_value || can_fail on_error
  | Lambda _ | Handler _ -> false
  | _ -> List.exists can_fail (children e)

(* ---- printing, as s-expressions, for tests ----

   A list that fits on its line is printed on it. One that doesn't starts
   its line with as many of its items as fit, but never the last one; the
   rest go on lines of their own, indented. *)

type sexp = Atom of string | List of sexp list

let rec flat = function
  | Atom a -> a
  | List xs -> "(" ^ String.concat " " (List.map flat xs) ^ ")"

let width = 78

let rec render col = function
  | List (head :: rest) as x when col + String.length (flat x) > width ->
      let rec first line = function
        | x :: (_ :: _ as more)
          when String.length line + String.length (flat x) + col < width ->
            first (line ^ " " ^ flat x) more
        | items -> (line, items)
      in
      let line, rest = first ("(" ^ flat head) rest in
      let pad = "\n" ^ String.make (col + 2) ' ' in
      line
      ^ String.concat "" (List.map (fun x -> pad ^ render (col + 2) x) rest)
      ^ ")"
  | x -> flat x

let show_var (v : var) = v.name ^ "/" ^ string_of_int v.id

let show_prim = function
  | Neg -> "neg"
  | Not -> "not"
  | Binop op -> Ast.binop_to_string op
  | Equal _ -> "=="
  | Not_equal _ -> "!="
  | Compare (op, _) -> Ast.binop_to_string op
  | Op (r, _) -> (
      match r with
      | "add" -> "+"
      | "sub" | "neg" -> "-"
      | "mul" -> "*"
      | "div" -> "/"
      | "rem" -> "%"
      | r -> r)
  | Value_of (r, _) -> r
  | Length -> "length"
  | Get_index -> "get"
  | Entries -> "entries"
  | Members -> "members"
  | Set_index -> "set"
  | New_cell -> "cell"
  | Get_cell -> "get-cell"
  | Set_cell -> "set-cell"
  | Widen -> "widen"
  | Narrow -> "narrow"
  | Wrap -> "wrap"

let atom a = Atom a
let var v = Atom (show_var v)

(* What a lambda or handler captures, as printed: its hidden type and
   dictionary parameters aren't, like the descriptors passed to a use,
   since the type arguments a typed print shows say what they are. *)
let shown_captures =
  List.filter (fun (v : var) -> v.ty <> type_ty && v.ty <> dict_ty)

(* What a typed print prints with: [pr] names the function's type
   variables, and [own] are its dictionary parameters, by the requirement
   each is for. *)
type typed = { pr : Ty.printer; own : ((int * string) * var) list }

(* A dictionary, as a typed print shows it: the requirement and the type
   it's for, [(eq Option<T>)], whether it's derived or the function's
   own. *)
let dict_sexp t d =
  let req, ty =
    match d with
    | Derived { req; dty; _ } -> (req, dty)
    | Dict_param v -> (
        match List.find_opt (fun (_, w) -> w = v) t.own with
        | Some ((n, req), _) -> (req, Ty.Var n)
        | None -> ("?", Ty.Error))
  in
  List [ Atom req; Atom (Ty.show t.pr ty) ]

let rec pattern_sexp p =
  match p.pkind with
  | PWild -> Atom "_"
  | PVar v -> var v
  | PInt n -> Atom (Int64.to_string n)
  | PBool b -> Atom (string_of_bool b)
  | PCon (_, c, []) -> Atom c
  | PCon (_, c, ps) -> List (Atom c :: List.map pattern_sexp ps)
  | PTag (t, []) -> List [ atom "tag"; Atom t ]
  | PTag (t, ps) -> List (atom "tag" :: Atom t :: List.map pattern_sexp ps)
  | PTuple ps -> List (atom "tuple" :: List.map pattern_sexp ps)
  | POr ps -> List (atom "or" :: List.map pattern_sexp ps)

(* A use of a top-level function, [name], printed bare; or, by a typed
   print [t], with the type arguments [a] if it has any, as
   [(inst first_or Int)], and the dictionaries [ds] it's given, if any,
   after them. A row argument is its labels and its tail, in braces:
   [{Short | ..e}]. *)
let used t name (a : Ty.args) ds =
  match t with
  | Some ({ pr; _ } as t) when a.tys <> [] || a.rows <> [] ->
      let row r =
        "{" ^ Ty.show_row pr ~prefix:"" ~sep:" | " ~kind:"r" r ^ "}"
      in
      (* `let`s fix the order variables are named in: OCaml evaluates a
         constructor's arguments right to left *)
      let tys = List.map (fun t -> Atom (Ty.show pr t)) a.tys in
      let rows = List.map (fun r -> Atom (row r)) a.rows in
      let ds = List.map (dict_sexp t) ds in
      List ((atom "inst" :: Atom name :: tys) @ rows @ ds)
  | _ -> Atom name

(* [t] is what a typed print prints with, [None] for a plain one. *)
let rec sexp_with t e =
  let sexp = sexp_with t and arm_sexp = arm_sexp_with t in
  (* the dictionary [d], before what's after it, in a typed print only *)
  let dict d rest =
    match t with Some t -> dict_sexp t d :: rest | None -> rest
  in
  match e.kind with
  | Int n -> Atom (Int64.to_string n)
  | Float f -> Atom (Ast.show_float f)
  | Bool b -> Atom (string_of_bool b)
  | Str s -> Atom (Ast.show_str s)
  | Unit -> Atom "()"
  | Local v -> var v
  | Global (p, a, _, ds) -> used t (Path.local p) a ds
  | Global_value (p, a) -> used t (Path.local p) a []
  | Intrinsic (x, a, _, ds) -> used t (Intrinsic.name x) a ds
  | Dep_call { dep; op; ev; next; args; _ } ->
      List
        (atom (if next then "next-call" else "dep-call")
        :: var ev
        :: Atom (Path.full dep ^ "." ^ op)
        :: List.map sexp args)
  | With { ev; outer; dep; impl; body; _ } ->
      List
        [
          atom "with";
          var ev;
          List [ atom "extend"; var outer; Atom (Path.full dep); sexp impl ];
          sexp body;
        ]
  | Handler { ev; captures; body } ->
      List
        [
          atom "handler";
          List (atom "captures" :: List.map var (shown_captures captures));
          var ev;
          sexp body;
        ]
  | Narrowed (ds, h) ->
      List
        ((atom "narrowed" :: List.map (fun d -> Atom (Path.full d)) ds)
        @ [ sexp h ])
  | Instance { impls; finally } ->
      List
        (atom "instance"
         :: List.map
              (fun (d, impl) -> List [ Atom (Path.full d ^ ":"); sexp impl ])
              impls
        @ Option.fold ~none:[]
            ~some:(fun f -> [ List [ atom "finally"; sexp f ] ])
            finally)
  | With_handler { ev; outer; handler; deps; body; _ } ->
      List
        [
          atom "with";
          var ev;
          List
            [
              atom "extend";
              var outer;
              List (List.map (fun d -> Atom (Path.full d)) deps);
              sexp handler;
            ];
          sexp body;
        ]
  | Prim (Value_of (req, d), []) -> (
      (* `T.zero`, typed, is its dictionary, `(zero T)` *)
      match dict d [] with
      | [ shown ] -> shown
      | _ -> List [ Atom req ])
  | Prim
      ( ((Equal d | Not_equal d | Compare (_, d) | Op (_, d) | Value_of (_, d))
         as op),
        args ) ->
      List (Atom (show_prim op) :: dict d (List.map sexp args))
  | Prim (op, args) -> List (Atom (show_prim op) :: List.map sexp args)
  | Let (v, value, body) -> List [ atom "let"; var v; sexp value; sexp body ]
  | Assign (v, value) -> List [ atom "="; var v; sexp value ]
  | If (c, t, f) -> List [ atom "if"; sexp c; sexp t; sexp f ]
  | Match (s, arms) -> List (atom "match" :: sexp s :: List.map arm_sexp arms)
  | While (c, body) -> List [ atom "while"; sexp c; sexp body ]
  | Break -> atom "break"
  | Seq (a, b) -> List [ atom "seq"; sexp a; sexp b ]
  | Call (f, args, ev) ->
      let arg = function
        | Value a -> sexp a
        | Ref v -> Atom ("&" ^ show_var v)
      in
      List (atom "call" :: var ev :: sexp f :: List.map arg args)
  | Lambda { params; ev; outer; given; captures; body; _ } ->
      let param p =
        match p.mode with
        | Inout -> Atom ("inout " ^ show_var p.var)
        | Read -> var p.var
      in
      (* its evidence, as a [With]'s: [outer] with what its caller gives *)
      List
        [
          atom "lambda";
          List (List.map param params);
          List (atom "captures" :: List.map var (shown_captures captures));
          var ev;
          List
            (atom "extend" :: var outer
            :: List.map (fun d -> Atom (Path.full d)) given);
          sexp body;
        ]
  | Con (_, c, args) -> List (atom "con" :: atom c :: List.map sexp args)
  | Record (_, fields) ->
      List
        (atom "record"
        :: List.map (fun (f, v) -> List [ Atom (f ^ ":"); sexp v ]) fields)
  | Field (r, _, f) -> List [ atom "."; sexp r; atom f ]
  | Update (r, f, v) -> List [ atom "update"; sexp r; Atom (f ^ ":"); sexp v ]
  | Array xs -> List (atom "array" :: List.map sexp xs)
  | Tuple xs -> List (atom "tuple" :: List.map sexp xs)
  | Tag (t, args, _) -> List (atom "tag" :: Atom t :: List.map sexp args)
  | Fail a -> List [ atom "fail"; sexp a ]
  | Handle { body; value; on_value; error; on_error } ->
      List
        [
          atom "handle";
          sexp body;
          List [ var value; atom "=>"; sexp on_value ];
          List [ atom "fail"; var error; atom "=>"; sexp on_error ];
        ]
  | Finally (body, after) -> List [ atom "finally"; sexp body; sexp after ]
  | Assert a -> List [ atom "assert"; sexp a ]
  | Assert_equal (a, b, _, d) ->
      List (atom "assert" :: atom "==" :: dict d [ sexp a; sexp b ])

and arm_sexp_with t a =
  let guard =
    match a.guard with Some g -> [ atom "if"; sexp_with t g ] | None -> []
  in
  List ((pattern_sexp a.pat :: guard) @ [ atom "=>"; sexp_with t a.body ])

let sexp e = sexp_with None e
let show e = render 0 (sexp e)

(* A typed print also shows the function's type after its name, whose
   variables its uses' type arguments are written in, with every row
   tail, and what it needs, the dictionaries it takes, if anything:
   [(needs (eq T))]. *)
let fn_sexp ?(types = false) f =
  let t =
    if types then
      Some
        {
          pr = Ty.printer ~show_tail:(fun _ -> true) ~names:Path.full f.scheme;
          own = List.combine f.scheme.reqs f.dicts;
        }
    else None
  in
  let ty =
    match t with
    | Some t ->
        let needs =
          match t.own with
          | [] -> []
          | own ->
              [
                List
                  (atom "needs"
                  :: List.map (fun (_, v) -> dict_sexp t (Dict_param v)) own);
              ]
        in
        [ atom ":"; Atom (Ty.show t.pr f.scheme.ty) ] @ needs
    | None -> []
  in
  List
    ((atom "fn" :: Atom (Path.local f.path) :: ty)
    @ [
        List (List.map (fun p -> var p.var) f.params);
        var f.ev;
        sexp_with t f.body;
      ])

let show_fn ?types f = render 0 (fn_sexp ?types f)
