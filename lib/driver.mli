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

(* The program, checked and type-checked against the prelude. *)
val check : file:string -> string -> Ast.Parsed.program

(* Every function's inferred type scheme, in canonical form. *)
val schemes : file:string -> string -> (string * Ty.scheme) list

(* Every function's inferred signature, as `ren types` prints it. *)
val types : file:string -> string -> string list

(* Check the program, then run it. *)
val run : file:string -> string -> Value.t
val dump_tokens : (Token.t * Loc.t) array -> string

(* The message for an exception a pass raised: a diagnostic, a panic or an
   internal error. [None] for any other exception. *)
val render_error : src:string -> exn -> string option
