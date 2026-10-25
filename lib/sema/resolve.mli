(* Name resolution (see resolve.ml): what every name in a module refers
   to, found through scope. *)

(* What of one import a module uses, by name; [unused_imports] reports
   the rest. Its fields are only read here, so the type is abstract: other
   modules can hold one but not look inside. *)
type import_use

(* A module, resolved. A record type in an .mli shows its fields, so other
   passes can read them. *)
type t = {
  home : string;  (** the module *)
  prog : Ast.Resolved.program;
  types : Iface.type_decl list;
      (** the types the module declares, in the order it declares them *)
  calls : (string * Path.t list) list;
      (** each function, and the top-level functions its body uses: the members
          written after their type, `Stack.of`, included *)
  methods : (string * Path.t list) list;
      (** each function, and the methods of the module's own types it may call
          with a dot, which inference checks first: for `s.push(1)`, the
          `Stack.push` if `s`'s type is written, `s: Stack<Int>`, and otherwise
          every one named `push`, since which it is is found by inference. A
          method whose signature is written out in full ([Ast.spelled]) is never
          one: its declaration is its type. *)
  scope : (string * Path.t) list;
      (** the types written bare in the module, by name, sorted: the prelude's,
          those imported by name and the module's own *)
  aliases : (string * string) list;
      (** each module it imports, with its alias, in import order *)
  import_uses : import_use list;  (** what of each import the module uses *)
}

(* How the module writes the type [p] in a message or a signature: bare if
   it's in scope, `alias.T` if its module is imported, and otherwise in
   full, `billing/invoice.Invoice`. *)
val type_name : t -> Path.t -> string

(* How the module writes the top-level function or value [p]: bare if
   it's its own or the prelude's, `alias.f` if not, and a member after
   its type, as [type_name] writes that: `Stack.of`. *)
val value_name : t -> Path.t -> string

(* Whether the module can write the type [p] at all: it's in scope, or its
   module is imported. *)
val can_name : t -> Path.t -> bool

(* Report every import the module doesn't use: its alias is never written,
   and neither is any type it imports by name, nor did step 2 of a lookup
   through a type find one ([found], from inference: `Red` can be a
   constructor of an imported `Color`). *)
val unused_imports : Diag.sink -> t -> found:Path.t list -> unit

(* Resolve module [home], which sees the interfaces [imports]: the
   prelude's, and that of every module it imports. Every name
   that doesn't exist, type with the wrong number of arguments and name
   declared twice is reported to the sink. [groups] are the functions
   made for a public group's tests (test_items.ml), each with the group's
   name: their parameters are the group's, in the module's interface. *)
val program :
  Diag.sink ->
  home:string ->
  imports:Iface.t list ->
  ?groups:(string * string) list ->
  Ast.Parsed.program ->
  t
