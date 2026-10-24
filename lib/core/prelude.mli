(* The prelude (see prelude.ml): what every program can use without
   declaring it. *)

(* The part written in Ren, which the driver parses. *)
val source : string

type builtin_type = { name : string; arity : int  (** type arguments *) }

type builtin_fn = {
  name : string;
  scheme : Types.state -> Types.ty;
      (** its type scheme, with generic variables from the given state *)
  eval : Value.t list -> Value.t * Value.t list;
      (** its result, and the final value of every parameter *)
}

val types : builtin_type list
val fns : builtin_fn list
val find_type : string -> builtin_type option
val find_fn : string -> builtin_fn option
val is_type : string -> bool
val is_fn : string -> bool
