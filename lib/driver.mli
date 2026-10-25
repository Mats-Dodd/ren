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

(* Every function of the entry module, and its inferred type scheme, in
   canonical form. *)
val schemes : ?load:loader -> file:string -> string -> (string * Ty.scheme) list

(* What inference found in the entry module: every function's type
   scheme, and the types of its expressions and patterns. *)
val inferred : ?load:loader -> file:string -> string -> Infer.t

(* The entry module's interface (iface.ml): what it would tell a module
   that imports it. *)
val interface : ?load:loader -> file:string -> string -> Iface.t

(* The entry module, checked and lowered to Core, with `$start` if it has
   a `main`. With [lint] (off by default), Core Lint checks every module, and a problem is an
   [Internal_error]; the tests turn it on. The prelude's Core is always
   linted, once, since that costs nothing per program. *)
val core : ?lint:bool -> ?load:loader -> file:string -> string -> Core.program

(* The same, for the whole program: every module in Core, the prelude
   first and the entry last, as [Eval.run] takes them. *)
val linked :
  ?lint:bool -> ?load:loader -> file:string -> string -> Core.program list

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
  types : Iface.type_decl list;
      (** every type, the prelude's included, as its own module sees it *)
}

(* Every test of the program in the folder [dir] whose modules include
   [roots], each a file and its source: `ren test` on a folder checks
   every module in it, whether another imports it or not. A module that
   has a `main` is checked as the program's entry. With [lint], each
   module is linted too. *)
val suite :
  ?lint:bool -> ?load:loader -> dir:string -> (string * string) list -> suite

(* Check every module, lower each one, link them into one program and run
   its `main`, which is in the entry module. *)
val run : ?lint:bool -> ?load:loader -> file:string -> string -> Value.t
val dump_tokens : (Token.t * Loc.t) array -> string

(* The message for an exception a pass raised: a diagnostic, a panic or an
   internal error. [None] for any other exception. [sources] gives the text
   of each file the message can show, by its name (diag.ml). *)
val render_error : sources:(string -> string option) -> exn -> string option
