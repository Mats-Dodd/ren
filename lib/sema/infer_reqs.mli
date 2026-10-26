(* Requirements (see infer_reqs.ml): whether a type has `eq`, derived from
   its structure, and deciding what a group's `==`s and uses of functions
   with requirements need. *)

(* Decide the [Compared] and [Required] constraints among those given,
   once the group's types are known: each variable of a type that has to
   have `eq` needs it (Types.needs), and a type that can't have it is
   reported where it's compared or given. *)
val decide : Infer_env.env -> Infer_env.constr list -> unit
