(* Type inference (see infer.ml). Returns each function's signature, as
   `ren types` prints it, in source order. Raises [Diag.Error] on the first
   type error. [file] names the program, for the error when it has no
   `main`. *)
val program : file:string -> Ast.program -> string list
