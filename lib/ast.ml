(* The abstract syntax tree: what the parser produces and every later pass
   consumes. Adding a constructor here makes the compiler point at every
   [match] that needs a new case. *)

type ident = { name : string; loc : Loc.t }

(* A type as written: `Int`, `Plan`, `Option<Int>`. *)
type ty = { ty_name : ident; ty_args : ty list }
type binop = Add | Sub | Mul | Div | Mod | Eq | Neq | Lt | Le | Gt | Ge
type unop = Neg

(* Patterns, the left-hand side of a `match` arm. *)
type pattern = { pkind : pattern_kind; ploc : Loc.t }

and pattern_kind =
  | PWild  (** [_] *)
  | PVar of string  (** a lowercase name: matches anything, binds it *)
  | PInt of int
  | PBool of bool
  | PCon of ident * pattern list  (** [Free], [Pro(seats)] *)

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
  | Con of ident * (ident option * expr) list
      (** a constructor: [Pro(5)] or [Pro(seats: 5)] *)
  | Record of ident option * (ident * expr) list
      (** [User { id: 1 }], or [{ id: 1 }] with the type left out *)
  | Field of expr * ident  (** [user.plan] *)
  | Match of expr * arm list

and arm = { arm_pat : pattern; arm_guard : expr option; arm_body : expr }

and stmt =
  | Let of { name : ident; ty : ty option; value : expr }
  | Expr of expr

(* Type declarations. *)

type field = { field_name : ident; field_ty : ty }
type ctor = { ctor_name : ident; ctor_fields : field list }

type type_body =
  | Fields of field list  (** a record: [{ id: Int, plan: Plan }] *)
  | Ctors of ctor list  (** a sum type: [| Free | Pro(seats: Int)] *)

type type_def = {
  type_name : ident;
  type_params : ident list;  (** the [T] in [Option<T>] *)
  type_body : type_body;
}

type param = { pname : ident; pty : ty }

type fn_def = {
  name : ident;
  params : param list;
  ret : ty option;
  body : expr;
  loc : Loc.t;
}

type item = Fn of fn_def | Type of type_def
type program = item list

let is_upper name = name <> "" && name.[0] >= 'A' && name.[0] <= 'Z'

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

let parens words = "(" ^ String.concat " " words ^ ")"

let rec show_ty t =
  match t.ty_args with
  | [] -> t.ty_name.name
  | args ->
      t.ty_name.name ^ "<" ^ String.concat ", " (List.map show_ty args) ^ ">"

let rec show_pattern p =
  match p.pkind with
  | PWild -> "_"
  | PVar x -> x
  | PInt n -> string_of_int n
  | PBool b -> string_of_bool b
  | PCon (c, []) -> c.name
  | PCon (c, args) ->
      c.name ^ "(" ^ String.concat ", " (List.map show_pattern args) ^ ")"

let rec show_expr e =
  match e.kind with
  | Int n -> string_of_int n
  | Bool b -> string_of_bool b
  | Var x -> x
  | Unop (Neg, a) -> parens [ "neg"; show_expr a ]
  | Binop (op, a, b) -> parens [ binop_to_string op; show_expr a; show_expr b ]
  | If (c, t, f) -> parens [ "if"; show_expr c; show_expr t; show_expr f ]
  | Call (f, args) -> parens ("call" :: f.name :: List.map show_expr args)
  | Block (stmts, last) ->
      parens (("block" :: List.map show_stmt stmts) @ [ show_expr last ])
  | Con (c, args) ->
      let show_arg = function
        | Some (l : ident), a -> l.name ^ "=" ^ show_expr a
        | None, a -> show_expr a
      in
      parens ("con" :: c.name :: List.map show_arg args)
  | Record (name, fields) ->
      let ty = match name with Some n -> [ n.name ] | None -> [] in
      let show_field ((f : ident), v) = f.name ^ "=" ^ show_expr v in
      parens (("record" :: ty) @ List.map show_field fields)
  | Field (r, f) -> parens [ "."; show_expr r; f.name ]
  | Match (subject, arms) ->
      parens ("match" :: show_expr subject :: List.map show_arm arms)

and show_arm a =
  let guard =
    match a.arm_guard with Some g -> [ "if"; show_expr g ] | None -> []
  in
  parens ((show_pattern a.arm_pat :: guard) @ [ "=>"; show_expr a.arm_body ])

and show_stmt = function
  | Let { name; value; _ } -> parens [ "let"; name.name; show_expr value ]
  | Expr e -> show_expr e

let show_fn f =
  let params = List.map (fun p -> p.pname.name) f.params in
  parens [ "fn"; f.name.name; parens params; show_expr f.body ]

let show_type_def td =
  let name =
    match td.type_params with
    | [] -> td.type_name.name
    | ps ->
        td.type_name.name ^ "<"
        ^ String.concat ", " (List.map (fun (p : ident) -> p.name) ps)
        ^ ">"
  in
  let show_field f = f.field_name.name ^ ":" ^ show_ty f.field_ty in
  let body =
    match td.type_body with
    | Fields fs -> [ parens ("fields" :: List.map show_field fs) ]
    | Ctors cs ->
        List.map
          (fun c ->
            parens (c.ctor_name.name :: List.map show_field c.ctor_fields))
          cs
  in
  parens ("type" :: name :: body)

let show_item = function Fn f -> show_fn f | Type td -> show_type_def td
