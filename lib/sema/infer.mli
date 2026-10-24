(* Type inference (see infer.ml). Returns each function's signature, as
   `ren types` prints it, in source order. Every type error is reported to
   the sink, and the signatures mean nothing if there were any. [file]
   names the program, for the error when it has no `main`. *)
val program : Diag.sink -> file:string -> Ast.program -> string list
