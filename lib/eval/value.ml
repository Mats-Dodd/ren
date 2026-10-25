(* Values: what a running Ren program computes. A module of its own, so the
   prelude's built-in functions (prelude.ml) can work on values without
   depending on the interpreter that calls them. *)

(* Variables in scope: an immutable map from a local's binder id (core.ml)
   to a cell holding its value. Map.Make is a functor: a function from a
   module (Int) to a module (Env). *)
module Env = Map.Make (Int)

type t =
  | VInt of int
  | VBool of bool
  | VUnit
  | VCon of { ty : Path.t; name : string; args : t list }
      (** [Pro(5)]: the type it belongs to, the constructor, its fields *)
  | VRecord of (string * t) list
      (** fields sorted by name, so structural equality ignores field order *)
  | VArray of t array  (** never changed in place: an update copies it *)
  | VClosure of {
      params : int list;  (** the parameters' binder ids *)
      body : Core.expr;
      env : t ref Env.t;
    }  (** a lambda, with the variables it captured when it was created *)
  | VFn of Path.t  (** a top-level function used as a value *)
  | VBuiltin of string  (** a function built into the prelude: [print] *)

let rec show = function
  | VInt n -> string_of_int n
  | VBool b -> string_of_bool b
  | VUnit -> "()"
  | VCon { name; args = []; _ } -> name
  | VCon { name; args; _ } ->
      name ^ "(" ^ String.concat ", " (List.map show args) ^ ")"
  | VRecord fields ->
      let show_field (f, v) = f ^ ": " ^ show v in
      "{ " ^ String.concat ", " (List.map show_field fields) ^ " }"
  | VArray xs ->
      "[" ^ String.concat ", " (Array.to_list (Array.map show xs)) ^ "]"
  | VClosure _ -> "<fn>"
  | VFn p -> "<fn " ^ p.name ^ ">"
  | VBuiltin name -> "<fn " ^ name ^ ">"
