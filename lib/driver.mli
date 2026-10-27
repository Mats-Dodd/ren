(* The compiler pipeline: what the `ren` tool and the tests call. Each
   function runs the passes it needs, in order. *)

exception Internal_error of { pass : string; message : string }
(** a bug in the compiler: an unexpected exception inside [pass] *)

(* Run [f] as the pass named [name], turning any exception that isn't a
   diagnostic or a panic into an [Internal_error]. ['a] is a type variable:
   [pass] works for a pass that returns any type, and returns that type. *)
val pass : string -> (unit -> 'a) -> 'a
val tokens : file:string -> string -> (Token.t * Loc.t) array
val parse : file:string -> string -> Ast.Parsed.program

(* A program is its entry file and the modules it imports, and theirs.
   A loader gives the source of a module from its path (`billing/stripe`),
   or [None] if there's no such module; the driver never reads a file
   itself. Every function below takes the entry's file and source, and an
   optional loader for the rest; without one, the program is its one
   file. *)
type loader = string -> string option

(* The file the module [path] is in, for a program whose entry is the file
   [entry]: paths start from the entry's folder. *)
val module_file : entry:string -> string -> string

(* The same, for a program in the folder [dir]. *)
val file_in : dir:string -> string -> string

(* The entry module, checked and type-checked against the prelude and what
   it imports, once each module it imports has been. *)
val check : ?load:loader -> file:string -> string -> Ast.Parsed.program

(* Every function of the entry module, by its path, and its inferred type
   scheme, in canonical form. *)
val schemes : ?load:loader -> file:string -> string -> Ty.scheme Path.Map.t

(* What inference found in the entry module: every function's type
   scheme, and the types of its expressions and patterns. *)
val inferred : ?load:loader -> file:string -> string -> Infer.t

(* The entry module's interface (iface.ml): what it would tell a module
   that imports it. *)
val interface : ?load:loader -> file:string -> string -> Iface.t

(* The rest of its summary, the implementation tier (impl.ml): the typed
   Core of its public functions that are generic or higher-order. *)
val implementation : ?load:loader -> file:string -> string -> Impl.t

(* The entry module, checked and lowered to Core, with `$start` if it has
   a `main`. With [lint] (off by default), Core Lint checks every module, and a problem is an
   [Internal_error]; the tests turn it on. The prelude's Core is always
   linted, once, since that costs nothing per program. *)
val core : ?lint:bool -> ?load:loader -> file:string -> string -> Core.program

(* The same, for the whole program: every module in Core, the prelude
   first and the entry last, as [Eval.run] takes them. *)
val linked :
  ?lint:bool -> ?load:loader -> file:string -> string -> Core.program list

(* A release build's program: [linked]'s, with what `$start` reaches
   specialized (specialize.ml), each module checked by Core Lint, and
   what specializing made. [budget] is the most copies of one function. *)
val specialized :
  ?lint:bool ->
  ?load:loader ->
  ?budget:int ->
  file:string ->
  string ->
  Core.program list * Specialize.stats

(* Every function's inferred signature, as `ren types` prints it, for each
   module of the program in the order they're checked (the entry last), by
   module. With [lint], each module is also lowered and linted. *)
val types :
  ?lint:bool ->
  ?load:loader ->
  file:string ->
  string ->
  (string * string list) list

(* A program's tests, checked and lowered with the functions they were
   made (test_items.ml), ready to run (test_runner.ml). *)
type suite = {
  core : Core.program list;  (** the program, the prelude first *)
  files : (string * string * Test_items.test list) list;
      (** each module's file, its path (its home) and its tests, in the order
          the files' names sort in *)
}

(* Every test of the program in the folder [dir] whose modules include
   [roots], each a file and its source: `ren test` on a folder checks
   every module in it, whether another imports it or not. A module that
   has a `main` is checked as the program's entry. With [lint], each
   module is linted too. *)
val suite :
  ?lint:bool -> ?load:loader -> dir:string -> (string * string) list -> suite

(* Check every module, lower each one, link them into one program and run
   its `main`, which is in the entry module, with [args] for the real
   `Os.args`. With [record], each call to the world is written to the
   journal as it's made, and how the run ended after them (`ren run
   --record`); with [trace], each call of an operation is added to it
   (`ren run --trace`). With [release], it runs the program a release
   build compiles, specialized (`ren run --release`), which has to do
   just what the program does. *)
val run :
  ?lint:bool ->
  ?load:loader ->
  ?release:bool ->
  ?args:string list ->
  ?record:Journal.t ->
  ?trace:Trace.t ->
  file:string ->
  string ->
  Value.t

(* `ren replay`: run the program as [run] does, with each call to the
   world answered from [journal], a recording of it (Journal.load),
   strictly: a call that isn't the recording's next, or an end that isn't
   its end, raises [Eval.Went_differently]. Otherwise it ends as the
   recording did. *)
val replay :
  ?lint:bool ->
  ?load:loader ->
  ?trace:Trace.t ->
  journal:Journal.t ->
  file:string ->
  string ->
  Value.t

(* ---- `ren console` (see driver.ml) ---- *)

(* The file a line typed into the console is in, for a message: line [i]
   of the session is its line [i]. *)
val console_file : string

(* What a line gave: its value as it's written, unless the line is a
   `let` or a `var`, or its value is `()`; and its type. What it did to
   the world is shown as it happens. *)
type console_line = { shown : string option; ty : string }

(* Check, and unless [types_only] run, the console session that kept the
   lines [history] and adds the line given, inside the module [home]
   (whose file is [file], with the source [src]) of the program in the
   folder [dir], on the test implementations of the built-ins but those
   [real] names. [journal] is the session's (Journal.session): each call
   to a built-in is shown as it's made, and what a real one gave the
   lines kept is given back to them, not asked again. [line] starts [col]
   columns into what was typed, which a message counts in. Raises what
   checking or running it raised: [Eval.Went_differently], at the line,
   if the session didn't make the calls it kept. *)
val console :
  ?types_only:bool ->
  ?col:int ->
  journal:Journal.t ->
  load:loader ->
  dir:string ->
  home:string ->
  file:string ->
  src:string ->
  real:string list ->
  history:string list ->
  string ->
  console_line

(* `:spec`: the session's lines, each with the value it showed, if it
   showed one, as a test named [name] of the module [home] (its file
   [file], with the source [src]), as it's written, or [None] if no line
   could be kept; and the lines left out, each with its number, its text
   and why: a test sees what an importer sees. An expression's value is
   kept as an `assert`, if one checks and passes when the test is run as
   `ren test` runs it. Raises an error if the module has a test named
   [name] already. *)
val console_spec :
  load:loader ->
  dir:string ->
  home:string ->
  file:string ->
  src:string ->
  name:string ->
  (string * string option) list ->
  string option * (int * string * string) list

val dump_tokens : (Token.t * Loc.t) array -> string

(* The message for an exception a pass raised: a diagnostic, a panic or an
   internal error. [None] for any other exception. [sources] gives the text
   of each file the message can show, by its name (diag.ml). *)
val render_error : sources:(string -> string option) -> exn -> string option

(* The help a panic gives for an `Int` that overflowed: the wrapping
   method instead, called as the source writes the operands,
   `n.wrapping_add(1)`, or [None] if they can't be shown. *)
val wrap_help : sources:(string -> string option) -> Eval.wrap -> string option

(* ---- `ren build` (compiler.md, "Native slice") ---- *)

(* The program, as Mem IR (mem.ml): its modules linked, and what `$start`
   reaches lowered, then checked by Mem Lint, which runs on every build.
   With [lint], Core Lint checks each module first. Code the native slice
   can't compile yet is an error that says so, at that code. Its counting
   is placed by Perceus (rc.ml), or with [~rc:Naive] as to_mem.ml makes
   it, a count at every use and a drop where the scope ends, the
   baseline Perceus is measured against. With [release], it's the
   program specialized ([specialized]), and [made] is given what
   specializing made. *)
type rc = Naive | Perceus

val mem :
  ?lint:bool ->
  ?load:loader ->
  ?release:bool ->
  ?made:(Specialize.stats -> unit) ->
  ?rc:rc ->
  file:string ->
  string ->
  Mem.program

(* The same, as one C file, the runtime in it. [sources] gives the text
   of each file a panic's message can show, by name (diag.ml). In a
   [release] build, each `inout` parameter is a `restrict` pointer, but
   with [~restrict:false] (`--no-restrict`). *)
val native :
  ?lint:bool ->
  ?load:loader ->
  ?release:bool ->
  ?made:(Specialize.stats -> unit) ->
  ?restrict:bool ->
  ?rc:rc ->
  sources:(string -> string option) ->
  file:string ->
  string ->
  string
