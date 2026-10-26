(* Values: what a running Ren program computes. A module of its own, so the
   prelude's built-in functions (builtins.ml) can work on values without
   depending on the interpreter that calls them. *)

(* Variables in scope: an immutable map from a local's binder id (core.ml)
   to a cell holding its value. Map.Make is a functor: a function from a
   module (Int) to a module (Env). *)
module Env = Map.Make (Int)

type t =
  | VInt of int
  | VBool of bool
  | VStr of string  (** UTF-8, always *)
  | VBytes of string  (** any bytes at all *)
  | VUnit
  | VCon of { ty : Path.t; name : string; args : t list }
      (** [Pro(5)]: the type it belongs to, the constructor, its fields *)
  | VRecord of (string * t) list
      (** fields sorted by name, so structural equality ignores field order *)
  | VArray of t array  (** never changed in place: an update copies it *)
  | VClosure of {
      params : int list;  (** the parameters' binder ids *)
      ev : int;  (** its evidence's id: what it's passed where it's called *)
      body : Core.expr;
      env : t ref Env.t;
    }
      (** a lambda, with the variables it captured when it was created, the
          hidden type parameters of the function it's in among them *)
  | VFn of Path.t * Ty.ty list
      (** a top-level function used as a value, with what it's given for its
          hidden type parameters: the types its type variables stand for where
          it was used (core.ml, [desc]) *)
  | VBuiltin of Intrinsic.t * Ty.ty list
      (** a function built into the prelude, [show], with the types its type
          variables stand for, as a [VFn]'s *)
  | VType of Ty.ty
      (** a type's descriptor, built where it's passed (core.ml, [desc]): what a
          hidden type parameter holds. A program never sees one *)
  | VTag of { name : string; args : t list }
      (** an error, [Short(2, 45000)]: its tag and its payload. A program sees
          one only inside a [Result]'s [Err] *)
  | VHandler of handler
      (** a handler, described (core.ml, [Handler]): a value of its dependency's
          type, or of the handler's own *)
  | VInstance of (Path.t * t) list
      (** a handler's instance: an implementation of each of its dependencies *)
  | VCell of t ref
      (** a `var` of a handler's state, shared by its instance's operations *)
  | VEvidence of installed list
      (** evidence (core.ml): what's installed, the innermost first. A program
          never sees one *)

(* A handler's description: its body makes an instance, given the
   evidence [ev] where it's installed, with the variables it captured. *)
and handler = { ev : int; body : Core.expr; env : t ref Env.t }

(* An implementation of the dependency [dep], installed: it runs with the
   evidence [outer], what was installed where it was. *)
and installed = { dep : Path.t; impl : t; outer : installed list }

let rec show = function
  | VInt n -> string_of_int n
  | VBool b -> string_of_bool b
  | VStr s -> Ast.show_str s
  | VBytes b ->
      (* there's no way to write bytes yet, so each one in hex *)
      let hex i = Printf.sprintf " %02x" (Char.code b.[i]) in
      "<bytes" ^ String.concat "" (List.init (String.length b) hex) ^ ">"
  | VUnit -> "()"
  | VCon { name; args = []; _ } | VTag { name; args = [] } -> name
  | VCon { name; args; _ } | VTag { name; args } ->
      name ^ "(" ^ String.concat ", " (List.map show args) ^ ")"
  | VRecord fields ->
      let show_field (f, v) = f ^ ": " ^ show v in
      "{ " ^ String.concat ", " (List.map show_field fields) ^ " }"
  | VArray xs ->
      "[" ^ String.concat ", " (Array.to_list (Array.map show xs)) ^ "]"
  | VClosure _ -> "<fn>"
  | VFn (p, _) -> "<fn " ^ Path.local p ^ ">"
  | VBuiltin (x, _) -> "<fn " ^ Intrinsic.name x ^ ">"
  | VHandler _ -> "<handler>"
  | VInstance _ -> "<instance>"
  | VCell _ -> "<cell>"
  | VEvidence _ -> "<evidence>"
  | VType _ -> "<type>"
