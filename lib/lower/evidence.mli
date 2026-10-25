(* Threading evidence (see evidence.ml): the whole program's modules, as
   lowering made them, the prelude first and the entry last, with each
   dependency an explicit parameter, each call of an operation a
   [Dep_call], copies of the functions that need them, and, if the entry
   has a `main`, the function the runtime starts in, [start_name]. *)
val program : Core.program list -> Core.program list

(* `$start`: it installs the real implementation of each built-in
   dependency `main` uses, and calls `main`. *)
val start_name : string
