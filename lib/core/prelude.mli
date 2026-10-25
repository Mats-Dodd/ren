(* The prelude (see prelude.ml): what every program can use without
   declaring it. *)

(* The part written in Ren, which the driver checks like any module, and
   the file it's said to be in. *)
val source : string
val file : string

type builtin_fn = {
  name : string;
  scheme : Ty.scheme;  (** its type scheme *)
  eval : Value.t list -> Value.t * Value.t list;
      (** its result, and the final value of every parameter *)
  runtime : bool;
      (** whether it reaches the world: only the prelude's source can call it *)
}

(* Raised by a built-in function that panics, with what to say. *)
exception Panic of string

(* Raised by a built-in function that fails, with its error. *)
exception Fail of Value.t

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : builtin_fn list;  (** its built-in methods: [Array]'s [push] *)
  functions : builtin_fn list;
      (** its built-in associated functions: [Str]'s [from_utf8] *)
}

val types : builtin_type list

(* The built-in dependencies the runtime installs around `main`: [Clock],
   [Random] and [Console]. Each one's real implementation is its private
   associated value [real]. *)
val runtime_deps : string list

(* The dependencies a `uses` can name that aren't declared yet: [Net], ... *)
val dependencies : string list
val fns : builtin_fn list

(* A built-in function by the name its path has: [print], or a built-in
   method after its type, [Array.push]. *)
val find_fn : string -> builtin_fn option

(* The interface of the built-in half: the built-in types and functions, as
   [source] sees them. *)
val intrinsics : Iface.t

(* The same, as every other module sees it, without the functions that
   reach the world. The driver joins it to the interface of [source]. *)
val public : Iface.t
