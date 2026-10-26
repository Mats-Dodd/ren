(* Looking things up for inference (see infer_lookup.ml): constructors,
   fields and members found through a type, in the three steps of
   module-build.md, and the type of a name. *)

open Infer_env

(* What a lookup through a type found: one type, with what it has, or no
   type, or several, which an error lists. *)
type 'a lookup = Found of 'a | Nowhere | Several of Path.t list

(* Step 1 is [known], what the type known at this point has, if it does;
   step 2 the one visible type that [fits]. *)
val through_type :
  env ->
  known:(Iface.type_decl * 'a) option ->
  fits:(Iface.type_decl -> 'a option) ->
  (Iface.type_decl * 'a) lookup

(* The declaration of a type already known to be a named type. *)
val known_decl : env -> Types.ty -> Iface.type_decl option

(* The constructor written, where a value of type [expected] is wanted.
   Each problem is reported. *)
val find_ctor :
  env ->
  Ast.Resolved.ctor_ref ->
  expected:Types.ty ->
  (Iface.type_decl * Iface.ctor) option

(* Whether a constructor is given as many arguments as it has fields,
   labelled correctly. Each problem is reported. *)
val ctor_shape :
  env -> Loc.t -> Ast.ident -> Iface.ctor -> Ast.ident option list -> bool

(* The fields a literal of a type gives: a record's, or a dependency's
   operations. *)
val literal_fields : Iface.type_decl -> Iface.field list option

(* By name, in a type declaration: a dependency's operation, a member, and
   a record's field. *)
val dep_op_in : string -> Iface.type_decl -> Iface.field option
val op_in : string -> Iface.type_decl -> Iface.op option
val field_in : string -> Iface.type_decl -> Iface.field option

(* What a name is in a type, as an error says it: "a field", "a method",
   ... *)
val member_kind : env -> string -> Path.t -> Iface.op_kind option

(* The member of that name of a type already known, and the function a
   member is: [Stack.push]. *)
val op_of : env -> Types.ty -> string -> (Iface.type_decl * Iface.op) option
val op_path : Iface.type_decl -> Iface.op -> Path.t
val sorted : string list -> string list

(* `r.f`, the expression given, once [r]'s type is known: the field's
   type, or [TError] once a problem is reported. *)
val field_access :
  env ->
  ctx ->
  Ast.Resolved.expr ->
  Ast.Resolved.expr ->
  Types.ty ->
  Ast.ident ->
  Types.ty

(* Whether calling [p] calls a function of the group being checked whose
   errors are known only once the group is done. *)
val group_call : env -> Path.t -> bool

(* A name's type, used at the location given by the expression [node], at
   which it records the type arguments a top-level function's use picked
   (Infer_env.targs). *)
val lookup : env -> ctx -> node:int -> Loc.t -> Ast.name -> Types.ty
