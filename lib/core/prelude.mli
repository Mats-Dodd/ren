(* The prelude (see prelude.ml): what every program can use without
   declaring it. *)

(* The part written in Ren, which the driver checks like any module. *)
val source : string

type builtin_type = { name : string; arity : int  (** type arguments *) }

type builtin_fn = {
  name : string;
  scheme : Ty.scheme;  (** its type scheme *)
  eval : Value.t list -> Value.t * Value.t list;
      (** its result, and the final value of every parameter *)
}

val types : builtin_type list
val fns : builtin_fn list
val find_fn : string -> builtin_fn option
val is_fn : string -> bool

(* The interface of the built-in half: the built-in types and functions.
   The driver joins it to the interface of [source]. *)
val intrinsics : Iface.t
