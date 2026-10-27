(* Whether a value of a type is copied, rather than counted (copied.ml):
   exclusivity's fact, and a release build's layout's. *)

(* Whether a value of type [t] is copied: a number, a `Bool` or `Unit`,
   or a record, tuple or enum made only of those. [types] finds a type's
   declaration; [seen] are the types the search is inside already. *)
val is :
  types:(Path.t -> Iface.type_decl option) -> ?seen:Ty.ty list -> Ty.ty -> bool
