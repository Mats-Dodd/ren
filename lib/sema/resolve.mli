(* Name resolution (see resolve.ml): what every name in a module refers
   to, found through scope. *)

(* A module, resolved. A record type in an .mli shows its fields, so other
   passes can read them. *)
type t = {
  home : string;  (** the module *)
  prog : Ast.Resolved.program;
  types : Iface.type_decl list;
      (** the types the module declares, in the order it declares them *)
  calls : (string * Path.t list) list;
      (** each function, and the top-level functions its body uses *)
}

(* Resolve module [home], which sees the interfaces [imports]. Every name
   that doesn't exist, type with the wrong number of arguments and name
   declared twice is reported to the sink. *)
val program :
  Diag.sink -> home:string -> imports:Iface.t list -> Ast.Parsed.program -> t
