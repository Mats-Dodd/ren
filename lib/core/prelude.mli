(* The prelude (see prelude.ml): what every program can use without
   declaring it. *)

(* The part written in Ren, which the driver checks like any module. *)
val source : string

type builtin_fn = {
  name : string;
  scheme : Ty.scheme;  (** its type scheme *)
  eval : Value.t list -> Value.t * Value.t list;
      (** its result, and the final value of every parameter *)
}

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : builtin_fn list;  (** its built-in methods: [Array]'s [push] *)
}

val types : builtin_type list

(* The dependencies a function can list in its `uses`: [Io], [Net], ... *)
val dependencies : string list
val fns : builtin_fn list

(* A built-in function by the name its path has: [print], or a built-in
   method after its type, [Array.push]. *)
val find_fn : string -> builtin_fn option

(* The interface of the built-in half: the built-in types and functions.
   The driver joins it to the interface of [source]. *)
val intrinsics : Iface.t
