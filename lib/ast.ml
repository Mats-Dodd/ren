(* The abstract syntax tree: what the parser produces and every later pass
   consumes. Adding a constructor here makes the compiler point at every
   [match] that needs a new case. *)

type ident = { name : string; loc : Loc.t }

(* Types are just names until Stage 3 (type inference) gives them meaning. *)
type ty = ident
type binop = Add | Sub | Mul | Div | Mod | Eq | Neq | Lt | Le | Gt | Ge
type unop = Neg

type expr = { kind : expr_kind; loc : Loc.t }

and expr_kind =
  | Int of int
  | Bool of bool
  | Var of string
  | Unop of unop * expr
  | Binop of binop * expr * expr
  | If of expr * expr * expr
  | Call of ident * expr list
  | Block of stmt list * expr  (** statements, then the block's value *)

and stmt =
  | Let of { name : ident; ty : ty option; value : expr }
  | Expr of expr

type param = { pname : ident; pty : ty }

type fn_def = {
  name : ident;
  params : param list;
  ret : ty option;
  body : expr;
  loc : Loc.t;
}

type program = fn_def list

(* Printing, as s-expressions, for `ren ast` and tests. *)

let binop_to_string = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Eq -> "=="
  | Neq -> "!="
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="

let rec show_expr e =
  match e.kind with
  | Int n -> string_of_int n
  | Bool b -> string_of_bool b
  | Var x -> x
  | Unop (Neg, a) -> Printf.sprintf "(neg %s)" (show_expr a)
  | Binop (op, a, b) ->
      Printf.sprintf "(%s %s %s)" (binop_to_string op) (show_expr a)
        (show_expr b)
  | If (c, t, f) ->
      Printf.sprintf "(if %s %s %s)" (show_expr c) (show_expr t) (show_expr f)
  | Call (f, args) ->
      String.concat " " ("(call" :: f.name :: List.map show_expr args) ^ ")"
  | Block (stmts, last) ->
      String.concat " "
        (("(block" :: List.map show_stmt stmts) @ [ show_expr last ])
      ^ ")"

and show_stmt = function
  | Let { name; value; _ } ->
      Printf.sprintf "(let %s %s)" name.name (show_expr value)
  | Expr e -> show_expr e

let show_fn f =
  let params = List.map (fun p -> p.pname.name) f.params in
  Printf.sprintf "(fn %s (%s) %s)" f.name.name (String.concat " " params)
    (show_expr f.body)
