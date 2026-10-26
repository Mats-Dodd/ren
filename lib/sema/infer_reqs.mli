(* Requirements (see infer_reqs.ml): whether a type has `eq`, `ord`, an
   operator or an associated value, from its structure, its `key` and
   its members, and deciding what a group's `==`s, `<`s, operators on
   type variables and uses of functions with requirements need. *)

(* The operators that are methods, by their requirement's name: `add`,
   `sub`, `mul`, `div`, `rem` and `neg`. *)
val operators : string list

(* Whether a path is `Int`'s or `Float`'s. *)
val is_number : Path.t -> bool

(* What the type at this path is represented as, if it's `with numeric`. *)
val numeric : Infer_env.env -> Path.t -> Ty.ty option

(* Decide the [Compared] and [Required] constraints among those given,
   once the group's types are known: each variable of a type that has to
   have a requirement needs it (Types.needs), and a type that can't have
   it is reported where it's used or given. *)
val decide : Infer_env.env -> Infer_env.constr list -> unit

(* Whether the module's own opaque type at this path has `eq`: what it's
   represented as, or its key, has no function in it, its type arguments
   aside. Its interface says so, since it hides the representation. *)
val opaque_has_eq : Infer_env.env -> Path.t -> bool

(* Whether the key of the type at this path leads back to it: its type has
   the type in it, or one whose key does, and so on. Such a key is an
   error, and is otherwise treated as though it weren't there. *)
val key_loops : Infer_env.env -> Path.t -> bool
