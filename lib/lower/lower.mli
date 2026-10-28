(* Lowering (see lower.ml): a resolved, type-checked module, in Core. It
   reads the types and lookups inference found ([Infer.t]), and expects a
   module that passed every check. *)

(* A function made for what a use of it is given (compiler.md, "`over
   any` and `retry`"): a handler `over any`, for the dependency at the
   second path, or a function with parameters of `Tags`, for the tags
   each is given. It isn't lowered as it's written: [program] leaves it
   out, and lists each request its module makes, which the driver makes
   with [made], in the module that declares the function, once each,
   with the requests that makes in turn. [types] finds each type of the
   program by its path. *)
type request = Any_for of Path.t * Path.t | Tags_for of Path.t * string list list

val program : Resolve.t -> Infer.t -> Core.program * request list

val made :
  types:(Path.t -> Iface.type_decl option) ->
  Resolve.t ->
  Infer.t ->
  request ->
  Core.fn_def * request list

(* The path of the function made for a request: `recorder$Clock`. *)
val made_path : request -> Path.t

(* What the runtime runs, given the entry's `main`: a function named
   [start_name] that installs the real implementation of each built-in
   dependency `main` uses, and calls it (deps.md, "`main`"). *)
val start : Core.fn_def -> Core.fn_def
val start_name : string

(* The built-in dependencies a `main` uses, which the runtime installs
   around it. *)
val main_uses : Core.fn_def -> Path.t list

(* The locals [e] uses but doesn't bind, in order of id: what a block
   whose body is [e] captures, but for its own parameters and evidence. *)
val free : Core.expr -> Core.var list
