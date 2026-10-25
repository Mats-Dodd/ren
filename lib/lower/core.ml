(* Core: the small, explicitly typed language a checked program is lowered
   to (lower.ml), and that the interpreter runs (eval.ml).

   The surface tree has many ways to say "change something": `x.f += 1`,
   `xs[i] = v`, `f(&x.f)`, `for p in &ps`. Core has one: [Assign] to a
   local variable. Everything else is spelled out with plain operations, a
   record update or an array update that builds a new value, and an
   assignment of it back to the variable. So nothing after lowering needs
   to know what a place is.

   Every node says its type, in canonical form (ty.ml), and keeps the
   location of the code it came from, so a panic can point at it. A local
   is known by its binder's id (numbered per top-level function, as in
   ast.ml; lowering numbers its temporaries after the function's own
   locals). Constructors, record types and fields say which type they
   belong to, which inference found. core_lint.ml checks that all of this
   fits together. *)

type mode = Ty.mode = Read | Inout

(* A local variable. Every use of it carries the same record. *)
type var = { id : int; name : string; ty : Ty.ty }

(* Operations built into the language. Each one's operands are listed in
   the order they're evaluated. *)
type prim =
  | Neg
  | Not  (** on a [Bool] *)
  | Binop of Ast.binop
      (** [==] and [!=] on any two values of the same type, the others on
          [Int]s. Never [&&] or [||]: lowering makes those [If]s, so their right
          side is evaluated only when it's needed *)
  | Length  (** an array's length *)
  | Get_index  (** [xs[i]]: panics if [i] is out of bounds *)
  | Set_index  (** [xs] with element [i] replaced: a new array *)

type param = { mode : mode; var : var }

type expr = { kind : kind; ty : Ty.ty; loc : Loc.t }

and kind =
  | Int of int
  | Bool of bool
  | Unit
  | Local of var
  | Global of Path.t
      (** a top-level function, or a member's, [Stack.push]; [ty] is the type
          it's used at here, an instance of its scheme. A method call,
          [s.push(1)], is a call of its function, with [s] first. *)
  | Global_value of Path.t
      (** an associated value, [Stack.empty], which the program makes once when
          it starts: its function of no parameters, called then. [ty] is an
          instance of its type. *)
  | Intrinsic of string
      (** a function built into the compiler: [print], or a method, [Array.push]
      *)
  | Prim of prim * expr list
  | Let of var * expr * expr  (** [let x = value in body] *)
  | Assign of var * expr  (** the only way anything changes *)
  | If of expr * expr * expr
  | Match of expr * arm list
  | While of expr * expr  (** the condition, then the body *)
  | Seq of expr * expr  (** the first's value is dropped *)
  | Call of expr * arg list
  | Lambda of { params : param list; captures : var list; body : expr }
      (** [captures] are the locals from outside the lambda its body uses, in
          order of id; their values are copied when the lambda is made *)
  | Con of Path.t * string * expr list
      (** a constructor: its type, its name, its fields in order *)
  | Record of Path.t * (string * expr) list  (** in the order written *)
  | Field of expr * Path.t * string  (** [r.f], and the record type of [r] *)
  | Update of expr * string * expr
      (** the record with one field replaced: a new record *)
  | Array of expr list

(* A call's argument. An [inout] argument is always a plain local: the call
   reads it, and writes the parameter's final value back to it. *)
and arg = Value of expr | Ref of var
and arm = { pat : pattern; guard : expr option; body : expr }
and pattern = { pkind : pattern_kind; pty : Ty.ty; ploc : Loc.t }

and pattern_kind =
  | PWild
  | PVar of var
  | PInt of int
  | PBool of bool
  | PCon of Path.t * string * pattern list

type fn_def = {
  path : Path.t;
  params : param list;
  scheme : Ty.scheme;  (** its type, whose variables its nodes' types share *)
  body : expr;
  loc : Loc.t;  (** its name, where it's declared *)
}

(* A module, lowered. [types] are the types it declares. *)
type program = {
  home : string;
  types : Iface.type_decl list;
  fns : fn_def list;
  values : Path.t list;
      (** its associated values, in the order they're made, each after every
          value it uses; each is one of [fns], of no parameters *)
}

(* ---- building ---- *)

let mk kind ty loc = { kind; ty; loc }
let unit loc = mk Unit Ty.unit loc
let local (v : var) loc = mk (Local v) v.ty loc

(* The type of an array's elements. *)
let elem_ty (t : Ty.ty) =
  match t with
  | Con (_, [ elem ]) -> elem
  | _ -> invalid_arg "Core.elem_ty: not an array"

(* ---- printing, as s-expressions, for tests ----

   A list that fits on its line is printed on it. One that doesn't starts
   its line with as many of its items as fit, but never the last one; the
   rest go on lines of their own, indented. *)

type sexp = Atom of string | List of sexp list

let rec flat = function
  | Atom a -> a
  | List xs -> "(" ^ String.concat " " (List.map flat xs) ^ ")"

let width = 78

let rec render col = function
  | List (head :: rest) as x when col + String.length (flat x) > width ->
      let rec first line = function
        | x :: (_ :: _ as more)
          when String.length line + String.length (flat x) + col < width ->
            first (line ^ " " ^ flat x) more
        | items -> (line, items)
      in
      let line, rest = first ("(" ^ flat head) rest in
      let pad = "\n" ^ String.make (col + 2) ' ' in
      line
      ^ String.concat "" (List.map (fun x -> pad ^ render (col + 2) x) rest)
      ^ ")"
  | x -> flat x

let show_var (v : var) = v.name ^ "/" ^ string_of_int v.id

let show_prim = function
  | Neg -> "neg"
  | Not -> "not"
  | Binop op -> Ast.binop_to_string op
  | Length -> "length"
  | Get_index -> "get"
  | Set_index -> "set"

let atom a = Atom a
let var v = Atom (show_var v)

let rec pattern_sexp p =
  match p.pkind with
  | PWild -> Atom "_"
  | PVar v -> var v
  | PInt n -> Atom (string_of_int n)
  | PBool b -> Atom (string_of_bool b)
  | PCon (_, c, []) -> Atom c
  | PCon (_, c, ps) -> List (Atom c :: List.map pattern_sexp ps)

let rec sexp e =
  match e.kind with
  | Int n -> Atom (string_of_int n)
  | Bool b -> Atom (string_of_bool b)
  | Unit -> Atom "()"
  | Local v -> var v
  | Global p | Global_value p -> Atom p.name
  | Intrinsic x -> Atom x
  | Prim (op, args) -> List (Atom (show_prim op) :: List.map sexp args)
  | Let (v, value, body) -> List [ atom "let"; var v; sexp value; sexp body ]
  | Assign (v, value) -> List [ atom "="; var v; sexp value ]
  | If (c, t, f) -> List [ atom "if"; sexp c; sexp t; sexp f ]
  | Match (s, arms) -> List (atom "match" :: sexp s :: List.map arm_sexp arms)
  | While (c, body) -> List [ atom "while"; sexp c; sexp body ]
  | Seq (a, b) -> List [ atom "seq"; sexp a; sexp b ]
  | Call (f, args) ->
      let arg = function
        | Value a -> sexp a
        | Ref v -> Atom ("&" ^ show_var v)
      in
      List (atom "call" :: sexp f :: List.map arg args)
  | Lambda { params; captures; body } ->
      let param p =
        match p.mode with
        | Inout -> Atom ("inout " ^ show_var p.var)
        | Read -> var p.var
      in
      List
        [
          atom "lambda";
          List (List.map param params);
          List (atom "captures" :: List.map var captures);
          sexp body;
        ]
  | Con (_, c, args) -> List (atom "con" :: atom c :: List.map sexp args)
  | Record (_, fields) ->
      List
        (atom "record"
        :: List.map (fun (f, v) -> List [ Atom (f ^ ":"); sexp v ]) fields)
  | Field (r, _, f) -> List [ atom "."; sexp r; atom f ]
  | Update (r, f, v) -> List [ atom "update"; sexp r; Atom (f ^ ":"); sexp v ]
  | Array xs -> List (atom "array" :: List.map sexp xs)

and arm_sexp a =
  let guard =
    match a.guard with Some g -> [ atom "if"; sexp g ] | None -> []
  in
  List ((pattern_sexp a.pat :: guard) @ [ atom "=>"; sexp a.body ])

let show e = render 0 (sexp e)

let show_fn f =
  render 0
    (List
       [
         atom "fn";
         Atom f.path.name;
         List (List.map (fun p -> var p.var) f.params);
         sexp f.body;
       ])
