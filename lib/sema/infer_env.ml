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
type 'l found_ =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string  (** a constructor: its type, and its name *)
  | Error_tag
      (** a tag inside `Err(...)`, written as a value or matched: one of the
          errors a [Result] holds, not a constructor *)
  | Method_of of Path.t
      (** a method called with a dot, at the [x.m] of [x.m(...)]: the method's
          function, [Stack.push] *)
  | Installs of { key : 'l; from : Path.t }
      (** a link of a `with`'s item that's an implementation of this dependency:
          what it's installed as, [key], its type arguments as inference found
          them, and the dependency it implements, [from], which differs from
          [key]'s for one installed as an alias, `with queue() as Jobs` *)
  | Installs_handler of 'l list
      (** a link that describes a handler of these dependencies, which it makes
          an instance of *)
  | Calls_op of {
      key : 'l;
      from : Path.t;
      op : string;
      recv : string;
      call : string;
    }
      (** at the [d.op] of [d.op(...)]: an operation called as a method of a
          description, which installs it for the call, as [key], implementing
          [from] (foundations.md, decision 3); [recv] is [d] as written and
          [call] the `with` that would make the call, as code to paste, `with
          d in Area.area()`, for the error that refuses one of a handler with
          state (stateless.ml) *)
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
          its function's own come before, and a [With] passes a descriptor of *)
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
      (** at an operator's own node (Ast.Binop), an operator the language does
          itself: on [Int]s or [Float]s, a `with numeric` type's, or an opaque
          type's, in its own module, on what it's represented as. Where it's a
          method, the operator's node has [Method_of] instead *)
  | Generic_op of string
      (** at an operator's own node, `a + b` on a type variable, or at an
          associated value's, `T.zero`: done by whatever its type turns out to
          have of this requirement, `add` *)
  | Tags_given of string list
      (** at `on: A | B`: the tags it gives, sorted (Infer.Tags_given) *)
  | Args of expr list
      (** at a call that gives a parameter with a default by name, or leaves
          it out: its arguments in its parameters' order, each left out its
          default, a literal at a node of its own ([default_node]), so Lower
          never sees a default (compiler.md, "Stage 11a", "The surface") *)
  | Pulls_block
      (** at a `for` over a block, `for x in try items`: the block, a `fn() ->
          Option<T>`, is called each time round until it gives `None`
          (compiler.md, "Services stage", step 5) *)
  | Pulled of { what : pulled; name : string }
      (** at a pull argument's own node ([pulled_node]): what's passed to a
          block parameter `fn() -> Option<T>` as `for` takes it, which
          Lower makes the block that pulls it, named [name] as a lambda is
          (streams.md, rule 3) *)
  | For_param of int
  | Gen_call of Path.t
  | Gen_step of Path.t
      (** at a call of a handler `for D`'s own node ([for_node]): which of its
          scheme's variables is [D], whose type argument there is the
          implementation it's made for (compiler.md, "Services stage",
          "Stripes") *)

(* What a pull argument is: a collection, pulled by a snapshot of it, its
   elements, a `Map`'s entries or a `Set`'s members, in order; or a
   cursor, [next] its method, pulled by calling it: a temporary, as
   itself, or a named one passed `&r`, in its place. *)
and pulled = Snapshot | Cursor of Path.t

(* The node of the default a call [node] leaves out, its parameter [i]'s:
   one no expression has, since the parser numbers them from 1. *)
let default_node node i = -((node * 256) + i + 1)

(* The node of what the pull argument at [node] is pulled by, and of the
   type of the method `next` a cursor at [node] is pulled by, at the
   type it's used at, `for` or a pull argument: nodes no expression has,
   far below every default's ([default_node]). *)
let pulled_node node = min_int + (node * 4)
let next_node node = min_int + (node * 4) + 1
let for_node node = min_int + (node * 4) + 2

(* A default, [lit], as the expression a call that leaves it out is
   given, at [loc]: a literal, or a variant written bare, a constructor of
   the sum Resolve found for it, given no fields, so those with defaults
   are filled in as anywhere ([Infer_expr.infer_con]). *)
let literal_kind (lit : literal) loc : expr_kind =
  match lit with
  | LInt k -> Int k
  | LFloat x -> Float x
  | LBool b -> Bool b
  | LStr s -> Str s
  | LCtor { csum; cname; _ } ->
      Con
        ( {
            qual = Option.map (fun p -> { tref = Named p; tloc = loc }) csum;
            name = { cname with loc };
          },
          [] )

(* A record/by-name field's expression default uses a hidden member in its
   declaration's scope. Positional fields retain their literal defaults. *)
let field_default_kind (f : Iface.field) loc ~node =
  match (f.fdefault_member, f.fdefault) with
  | Some (Value_default p), _ -> Some (Var (Global_value p))
  | Some (Function_default p), _ ->
      Some (Call ({ kind = Var (Global p); loc; node = min_int / 2 + node }, []))
  | None, Some lit -> Some (literal_kind lit loc)
  | None, None -> None

(* What inference keeps of it, while a group is checked: its labels are
   the checker's, whose type arguments it may still learn. *)
type found = label found_

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
  own : label list;
  row : row;
  needs : bool;
  callee : Path.t option;  (** the top-level function called, if it's one *)
  op : string option;
      (** the operation called, if it's a dependency's, `Users.get(1)` *)
}

(* How to explain a mismatch with an expected type (Infer_report.why,
   where it's described): kept here, since a constraint can carry one. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  narrowed_help : (string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
  type_params : bool;
  inside : string -> string;
  alone : bool;
      (** its words are the whole message: what the mismatch itself would add,
          a note on what can fail, isn't *)
  produces : (string -> string -> string) option;
      (** for a lambda: how to word its body giving the wrong type, given what
          it gives and what it has to, if not as any lambda's is *)
}

(* A `call` clause being checked, `call(c) => ...` or a merge's `call(c,
   a, b) => ...`, in a handler of one dependency (compiler.md, "Services
   stage", "`D.Call`"): the binder of its call, [c], and the skolem [rid]
   that stands for the result of the operation it's a call of, which a
   `match` on [c] refines in each arm to that case's operation's, [cases],
   by the case's name, since a case is a call of that operation and of no
   other. *)
type clause = { cbinder : int; rid : int; cases : (string * ty) list }

type generator_def = {
  gen_fn : fn_def;
  gen_type : Types.generator;
  gen_params : Types.param list;
  gen_nodes : (int, Types.ty) Hashtbl.t;
  gen_facts : (int, found) Hashtbl.t;
  mutable gen_with : bool;
  mutable gen_unsafe : bool;
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
  mutable visible : Iface.type_decl list;
      (** the types it can name bare, sorted by name, which is the order an
          error lists them in: its own, those imported by name, and the
          prelude's *)
  globals : (Path.t, ty) Hashtbl.t;
  generators : (Path.t, generator_def) Hashtbl.t;
  generator_signatures : (Path.t, Ty.generator) Hashtbl.t;
  replay_defs : (Path.t, replay_def) Hashtbl.t;
      (** Typed bodies from checked groups and the current SCC, retained for
          the private replay-safety summary before choosing generator kinds. *)
  replay_unsafe : (Path.t, unit) Hashtbl.t;
      (** Callable and member paths that reach ambient state, unknown handler
          code or unresolved user dispatch. This never changes source rows. *)
  mutable generator_early : (unit -> unit) list;
  mutable generator_late : (unit -> unit) list;
      (** top-level functions: a type scheme once their group is done *)
  type_params : (Path.t, int option list) Hashtbl.t;
      (** declared type parameters, in order, mapped to canonical variables *)
  written : (Path.t, bool list) Hashtbl.t;
      (** which of each of the module's functions' parameters have a type
          written: only there is an argument narrowed to what it asks for
          (Infer_expr.narrow), not where its type was inferred *)
  mutable group : (Path.t * group_fn) list;
      (** the functions of the group being checked, each with what its
          declaration says of it *)
  mutable hidden_calls : (call * label * string * string) list;
      (** calls of a function of [group] in the body of a `with` whose wiring
          hides the label, each with the wiring and the item that installs
          it: whether the callee brings the label in is known only once
          every body of the group is checked ([Infer_top]'s
          [check_hidden_calls]) *)
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
  mutable in_state : (string * string) option;
      (** whether the code being checked is a handler's state or `finally`, what
          a `with` that installs it fails with: the handler, `pub handler h`,
          and what's after its name, `over Sql`, for a message when something
          there fails with what it doesn't say *)
  finallies : (Path.t, int * int * int) Hashtbl.t;
      (** each handler's `finally`, by its handler's function: the handler's
          node, and the skolems of the body's type and its errors' row, which
          become variables of the function's when it's put in canonical form *)
  mutable in_finally : int;
      (** how many `finally`s deep the code being checked is: only in one
          can `fail Cancelled` be written, which goes on with a cancel
          (compiler.md, "Stage 11a", "Cancellation") *)
  mutable finally_rows : int list;
      (** the skolems of the rows a `finally`'s body's errors are: `try r`
          passes those on, but they're the `with`'s body's already *)
  mutable in_scope : Path.t list;
      (** the types step 2 of a lookup found: a type imported by name may be
          used only that way, so this says that its import is used *)
  mutable client : bool;
      (** whether the group being checked is test code, which sees the module as
          an importer does (testing.md, "Tests are specifications"): its private
          items aren't there, and its opaque types are opaque *)
  mutable hidden : Iface.type_decl list;
      (** while [client], the module's private types as it declares them, which
          test code can't see: a message names what it reached for *)
  anys : (Path.t, int * int * int * int) Hashtbl.t;
      (** each handler `over any`, by its function: its body's node, and the
          skolems of the arguments' type, the result's and the errors' row of
          the operation it runs for, which become variables of the function's
          when it's put in canonical form, as a `finally`'s do, so lowering
          can put each operation's in their place (compiler.md, "`over any`
          and `retry`") *)
  any_skolems : (int, string) Hashtbl.t;
      (** those skolems, by id, each with what it is as the arm writes it,
          `call.args`, for a message *)
  mutable any_call : (ty * ty * row) option;
      (** while an arm `over any` is checked: `call.args`'s type, the
          result's, and the errors' row, `call.forward()`'s *)
  clauses : (Path.t, int * int * int) Hashtbl.t;
      (** each handler with a `call` clause, by its function: its body's node,
          and the skolems of the result and the errors' row of the call it
          runs for, which become variables of the function's as an `over
          any`'s do (compiler.md, "Services stage", "`D.Call`") *)
  mutable clause : clause option;
      (** while a `call` clause of a handler of one dependency is checked,
          what a `match` on its call refines ([clause]) *)
  params_of : (Path.t, string list) Hashtbl.t;
  defaults_of : (Path.t, (int * string * Ast.literal) list) Hashtbl.t;
      (** each function's parameters with defaults, by its path, each by its
          place among the arguments a call gives (after `self`, for a
          method), its name and its literal *)
      (** each top-level function's parameters' names, by its path, which a
          message about an argument passed by name names *)
  through : (int * Loc.t, Path.t) Hashtbl.t;
      (** each member function of a dependency called through an alias of it,
          `Events.items()`, by the node of the member as written, with the
          alias (Resolve.through) *)
  pulled_calls : (int, unit) Hashtbl.t;
      (** the calls being checked that are pulled where they're written: a
          `for`'s subject, or a pull argument. Each is added while it's
          inferred, and taken out after *)
  wired_from : (Path.t, Ast.via list * string) Hashtbl.t;
      (** each function a wiring's link was made into (resolve.ml, "Wirings")
          that a `with` of the module calls, with the wirings its item came
          through and how it's written there: a message about what it needs
          names them *)
  test_reported : (Path.t, unit) Hashtbl.t;
      (** what test code has reached for that it can't see, which is reported at
          the first use of each only: the module's own opaque types, whose
          representation it used, by their paths, and its private methods, by
          theirs *)
  mutable pinned_by : (Path.t * string * bool) list;
      (** the keyed instance families the blocks being checked are pinned
          by, innermost first: each by the dependency its library is
          installed as, `Docs`, with the call that pins it, as written,
          `Docs.at` (compiler.md, "Services stage", "Actors (step 7)"),
          and whether it's `at_all`'s, inside which `at` of its family is
          checked by key at run time *)
  mutable in_sight : label list;
      (** what the `with`s around the code being checked, in its own
          function, install, innermost first, in the order they're
          installed: what rule 3 reads to tell a family installed inside
          another (compiler.md, "Step 10: structured actors") *)
  pin_ops : (Path.t * string, reach) Hashtbl.t;
      (** the module's operations an arm of which pins an instance of a
          family for a block, `Shards.at`, or posts to one, `Shards.send`
          ([pinning_ops]) *)
}

and replay_def = {
  replay_fn : fn_def;
  replay_nodes : (int, Types.ty) Hashtbl.t;
  replay_facts : (int, found) Hashtbl.t;
  replay_required : (int, required) Hashtbl.t;
}

(* How a call reaches a keyed instance family: pinning one of its
   instances for a block, `Docs.at`, or posting to it, `Docs.post`. *)
and reach = Pins | Posts

(* A function of the group being checked, as the group's functions see
   it until the group is done (infer_top.ml, [setup]). Its type parameters
   and the rows it names are generic in what its declaration says, so each
   use has fresh variables in their place (Infer_lookup.own_instance), and
   so does its own type, where a use is joined with it (solve.ml). *)
and group_fn = {
  declared : unit -> ty;
      (** a way to make the type its declaration gives it, with its type
          parameters and the rows it names as skolems *)
  gparams : int list;  (** its type parameters' skolems, by id *)
  grows : int list;  (** the skolems of the rows it names, by id *)
  gends : unit -> (int * int) list;
      (** its own rows that end in a row it names once the group is done, `!
          ..e`, but don't yet: the variable each ends in now, by id, and the
          named row's skolem's id *)
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

(* A call that uses a named row, a function's own `uses ..d`, or a `with`
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

(* An operation of a handler, its arm `usd_to(c) => ...`: it can fail with fewer errors than its dependency declares,
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

(* A `with` that installs [wdeps], at [wloc], or a block whose
   parameter's type lists [wdeps]: its body uses [wbody], which is what
   the body's calls use, and that has to be no more than [wdeps] and what's
   installed outside, [wouter], where the `with` or the block is written.
   That's an inclusion, not an equality: the body's row learns what its
   calls use, and only what isn't in [wdeps] goes outside. It's decided once
   the group is done, by the solver, when every call of the group knows
   what it uses. *)
and install = {
  wloc : Loc.t;
  wdeps : label list;
  wbody : row;
  wouter : row;
  wself : Path.t;  (** the function the `with` or the block is in *)
  wblock : bool;  (** whether it's a block's, for a message *)
  wsrc : string;
      (** what installs it, as it's written, `log()`, for a message about
          which instance of a generic dependency it installs *)
}

(* A call of a generic dependency's operation, `Log.all()` at [xloc],
   whose instance, [xlabel], `Log<α>`, still had open type arguments when
   it was made: it's joined to [xinto], what the function or lambda it's
   in uses, once the group's other uses are joined and what each value is
   used as is known, by the solver. If it's open still, the function's
   declared `uses`, [xdeclared], says which, if it lists exactly one of
   that dependency; otherwise it's an error, unless the function is given
   what fixes it, a generic function's parameter (compiler.md, "Generic
   dependencies"). [xcall] is the call as it's written, for a message. *)
and instance = {
  xloc : Loc.t;
  xlabel : label;
  xinto : row;
  xcall : string;
  xdeclared : label list option;
  xself : Path.t;
  xwhat : Infer_msg.user;
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
  mutable kpassed : label list;
}

(* A handler: [nrow] is what its state and arms use, and [ncalls] the
   calls that add to it. That can't be a dependency it implements itself,
   unless it goes over it, [nover], and reaches the one under it with
   `next` (handlers.md, "`over`"). If its needs are written,
   `for N uses Console`, or it's public, which needs nothing if it says
   nothing, they're [ndeclared], and [nrow] has to be no more than that.
   It's checked once the group is done, with its function's `uses`, by the
   solver, and then a written row is closed. *)
and handler_needs = {
  nself : Path.t;
  nover : label list;
  nfails : row;
      (** what its state and `finally` fail with, which is all it can fail to
          start with once the group is done *)
  ndeclared : label list option;
  nrow : row;
  ncalls : call list ref;
}

(* A dependency [hdep] that a function [hfn] calls inside a `with` of it
   still gets from outside, and why ([hnote]), which the solver finds as
   it decides what each `with` installs: a message that says its callers
   have to install it explains with this (infer_declared.ml). *)
and withheld = { hfn : Path.t; hdep : label; hnote : Infer_msg.withheld }

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
  | Kept of row * (string * ty) list * Loc.t option
      (** the errors an `attempt` keeps in its [Result], or a `match` with
          `fail` arms handles, with the parameters of the function and lambdas
          it's in: it holds no more than what it has once the group's error sets
          have all their tags. For an `attempt`, where its keyword is: its
          [Result] is a value, which can meet a set of tags written in `Err` *)
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
  | Instance of instance
      (** a call of a generic dependency's operation whose type arguments the
          call didn't fix: which instance it uses *)
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
  | Compared of compared
      (** the type `==`, `<` or an operator is used on has what it needs *)
  | Required of required
      (** a use of a function that needs something of its type parameters: what
          it puts in their place has it *)
  | Any_arm of { aerrs : row; atags : row }
      (** the arm of a handler `over any`, which fails with [aerrs]: what it
          fails with itself, `call.fail(Down)`, its tags, are [atags], which
          its type lists, and which each `with` that installs it checks
          (compiler.md, "`over any` and `retry`") *)
  | Later of (unit -> unit)
      (** a check of what the group's rows turned out to be, once they're all
          decided: the tags a call's `on:` gives *)

(* `a == b`, `a < b`, `a + b` on a type parameter, or `T.zero`, at
   [qloc]: [qty], the type of both sides, has to have the requirement
   [qreq], `eq`, `ord`, `add` or `zero` (operators.md). It's decided once
   the group's types are known, by the solver: a type variable of the
   group then passes the requirement on to the function it's in, which
   needs it of whatever it's given (Infer_reqs). [qop] is the operator, or
   the associated value, as it's written, for a message. *)
and compared = { qty : ty; qloc : Loc.t; qop : string; qreq : string }

(* A use, at [uloc], of the function [uname], which may need something of
   its type parameters, `eq` of its `T`: whatever the use put in their
   place has to have it. [uinst] is what it put there, by the id of the
   variable each replaced, a generic variable of an earlier group's
   function or another module's, or a type parameter of a function of the
   group, whose needs are known only once the group's bodies are, so the
   solver decides them all together. A call points at the argument each
   is passed in, [uat], as the message's location. [urows] are the same
   for its row variables, which can need what a type variable can of the
   tags they stand for. [udone] are the requirements passed on so far, by
   the variable's id. *)
and required = {
  uname : string;
  uloc : Loc.t;
  uinst : (int * ty) list;
  urows : (int * row) list;
  mutable uat : (int * Loc.t) list;
  mutable udone : (int * string) list;
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
   function's own body gave it. The type parameters its declaration names,
   and the rows, it works for whatever they are, so each use has fresh
   variables in their place, there and in what it's joined with. *)
and join = {
  jloc : Loc.t;
  jname : string;
  used : ty;
  target : Path.t;
  jinst : Types.subst;
      (** what the use put in place of the function's type parameters and named
          rows (Infer_lookup.own_instance), which its own type is joined at too
      *)
}

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
  einstall : bool;
      (** whether it's installing a `with`'s item, which can fail to start
          (handlers.md, "State that can fail to start"), not a call *)
  estep : bool;
  estream : (string * string) option;
      (** whether it's a chain's step, `|> validate`, which carries its own
          marker or none (language.md §8, "`try` on each step") *)
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
  mutable chain_head : (string * (unit -> string)) option;
      (** for a `try` or an `attempt` that is a chain's head, `try order |>
          validate`, which `|>` stops: what it covers, as written, and the
          chain with a `try` on each step that can fail, once that's known,
          for the message that says so (language.md §8) *)
}

and marker_kind =
  | Mtry
  | Mattempt
  | Mmatch
  | Mmatch_on
      (** a `match` whose `fail` arms are all `fail on`, of a parameter of
          `Tags`: it handles nothing it can name, so what it's given by a
          parameter, a public function's own errors, it can still take *)

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

(* How a local is bound, if not by a pattern: as a parameter of the
   top-level function, or of a lambda in it, or by a `let`. *)
and bound_by = Own_param | Lambda_param | Let_bound

(* What the expression being inferred can see. *)
and ctx = {
  self : Path.t;  (** the top-level function being checked *)
  locals : (int, ty) Hashtbl.t;
      (** the type of each local of the top-level function, by binder id *)
  binders : (int, bound_by) Hashtbl.t;
      (** which locals are parameters, or are bound by a `let`, by binder id,
          and not by a pattern: a message says where to write one's type *)
  let_blocks : (int, call list ref) Hashtbl.t;
      (** the calls in the body of each local bound by a `let` to a lambda,
          by binder id: passed to an operation, it brings in only what its
          parameter's type lists (Infer_expr.op_block) *)
  written_locals : (int, unit) Hashtbl.t;
      (** the locals whose type is written, a parameter's or a `let`'s or
          `var`'s, by binder id: assigning one narrows the value to it
          (Infer_expr.narrow) *)
  nodes : (int, ty) Hashtbl.t;
      (** the type of each expression and pattern of the function, by node id *)
  found : (int, found) Hashtbl.t;  (** what each lookup found, by node id *)
  narrowed : (int, Path.t list) Hashtbl.t;
  coerced : (int, Sized.coerce) Hashtbl.t;
      (** each expression, by node id, whose value is read from a sized type as
          its wide one, or stored into one, or both (Infer_expr.read_wide) *)
      (** each expression, by node id, whose value, an implementation of several
          dependencies, is narrowed to some of them, these, where a written type
          asks for those (Infer_expr.narrow) *)
  targs : (int, targs) Hashtbl.t;
      (** the type arguments of each use of a top-level function, by node id *)
  explicit_args : (int, int * (Loc.t * ty) list) Hashtbl.t;
      (** written type arguments awaiting the callee's lookup; methods seed
          these before checking value arguments, just as named functions do *)
  required : (int, required) Hashtbl.t;
      (** what each use of a top-level function needs of its type arguments, by
          node id, so a call of it can say which argument each is in *)
  errs : row;  (** the errors of the innermost function or lambda *)
  return_ty : ty;
  generator_item : ty option;
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
  lambdas : int ref;
      (** how many lambdas of the top-level function have been met, which names
          each one (Ty.lambda_id): shared by every copy of the [ctx] for the
          function, its lambdas' included *)
  tparams : ty list;  (** what the type parameters in scope stand for *)
  named : (string * row) list;
      (** the rows the function's signature names, `..d`, by name (ast.ml) *)
  declares : label list option;
      (** the dependencies the top-level function declares it uses, if it
          declares them (Infer_declared.declared_uses) *)
  later : (unit -> unit) list ref;
      (** what's checked once the function's body is, most recent first: an
          inline handler whose dependency wasn't known where it was met, which
          what came after may say (Infer_expr, [inline]) *)
}

(* A dot call that turned out to call [callee], a method of the module
   not checked yet, from [caller]. Which method `s.size()` calls is found
   only by checking it, after the call graph has put the functions in
   order, so the call graph was missing this edge: infer_top.ml adds it
   and checks the module again. *)
exception Unchecked of { caller : Path.t; callee : Path.t }

(* Whether the code being checked sees the type [p] as its own module
   does: its private members, and an opaque type's representation. Test
   code sees its own module's as an importer does ([env.client]). *)
let own env (p : Path.t) = p.home = env.home && not env.client

(* Whether [td] is the module's own type, seen by a test as an importer
   sees it: a message then says so. *)
let tested env (td : Iface.type_decl) = env.client && td.path.home = env.home

(* Does a row ending in [tail] belong to one of [params]? Then it stands
   for whatever the function passed there fails with. *)
let in_params params tail =
  List.exists (fun (_, t) -> List.mem tail (row_vars t)) params

(* The variable or named row [r] ends in, or [REmpty]. *)
let rec row_end r =
  match repr_row r with RExtend (_, rest) -> row_end rest | r -> r

(* A dependency's label as the module writes its type, `Chan<Int>`. *)
let shown_dep env (l : label) =
  show_dep (Types.printer ~names:env.names env.st) l

(* Dependencies an implementation implements, joined as its type joins
   them, `Clock & Chan<Int>`. *)
let shown_deps env ds =
  String.concat " & " (List.map (fun d -> shown_dep env (dep_of d)) ds)

(* The dependencies of the row [r], as the module names them. *)
let dep_names env r = List.map (shown_dep env) (sorted_labels r)

(* Whether [l] is one of [ls]. *)
let has_dep ls l = List.exists (same_label l) ls

(* Whether the call [c] brings in [dep] itself: it had it before the
   join, and no `with` around it installs it. *)
let brings c dep = has_dep c.own dep

(* If the `with` item [c] installs was flattened from a wiring: the
   innermost wiring it came through, and how it's written there. *)
let wired_need env (c : call) =
  match c.callee with
  | Some p -> (
      match Hashtbl.find_opt env.wired_from p with
      | Some (via :: _, text) -> Some (via, text)
      | _ -> None)
  | None -> None

(* Name the block at [node]: the next of the function it's in
   (Ty.lambda_id), recorded at [node] for lowering, which gives the
   block's code that name, with [given], the dependencies its callee
   provides (see [Block]). *)
let name_lambda ?(given = []) cx node =
  incr cx.lambdas;
  Hashtbl.replace cx.found node
    (Block { name = Ty.lambda_id cx.self !(cx.lambdas); given })

(* Leave [c] for the solver, once the group is done. *)
let defer env c = env.pending <- c :: env.pending

(* Whether the error set ending in [tail] is one an `attempt` of the group
   keeps, or a `match` handles, of those met so far. *)
let kept env tail =
  List.exists
    (function Kept (k, _, _) -> row_tail k = Some tail | _ -> false)
    env.pending

(* Inside the function, an `inout` parameter is an ordinary variable.
   [own] says they're the top-level function's own, not a lambda's. *)
let bind_params ?(own = false) cx params ps =
  List.iter2
    (fun (p : Resolved.param) (t : Types.param) ->
      Hashtbl.replace cx.locals p.pname.id t.ty;
      Hashtbl.replace cx.binders p.pname.id
        (if own then Own_param else Lambda_param);
      if p.pty <> None then Hashtbl.replace cx.written_locals p.pname.id ())
    params ps

(* What a lambda's body sees: the lambda's own errors and dependencies,
   and no marker, since the body has markers of its own. Its calls are its
   own too: a block's are added to its writer's once its body is checked
   (Infer_expr.block_uses), and an arm's or a `finally`'s are its
   handler's. *)
let lambda_cx cx (params : Resolved.param list) ps ~errs ~uses =
  {
    cx with
    errs;
    generator_item = None;
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
