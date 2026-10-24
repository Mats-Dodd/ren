(* The abstract syntax tree: what the parser produces and every later pass
   consumes. Adding a constructor here makes the compiler point at every
   [match] that needs a new case. *)

type ident = { name : string; loc : Loc.t }

(* A type as written: `Int`, `Option<Int>`, `fn(Int) -> Bool`. *)
type ty =
  | TyName of ident * ty list  (** [Int], [Option<Int>] *)
  | TyFn of ty list * ty option * Loc.t
      (** [fn(Int) -> Bool]; with no [->] the function returns [Unit] *)
  | TyInout of ty * Loc.t
      (** [inout Int], a parameter of a function type: [fn(inout Int)] *)

let ty_loc = function
  | TyName (id, _) -> id.loc
  | TyFn (_, _, l) | TyInout (_, l) -> l

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

(* How a parameter is passed: read-only (the default), or [inout], which
   updates the caller's value. *)
type mode = Read | Inout

(* A parameter of a function or lambda; its type may be left out. *)
type param = { pname : ident; pty : ty option; pmode : mode }

type expr = { kind : expr_kind; loc : Loc.t }

and expr_kind =
  | Int of int
  | Bool of bool
  | Unit  (** [()] *)
  | Var of string  (** a local variable, or a top-level function *)
  | Unop of unop * expr
  | Binop of binop * expr * expr
  | If of expr * expr * expr option  (** with no [else], the [if] is [Unit] *)
  | Call of expr * expr list  (** [f(x)], [make()(x)], [handlers.on_click()] *)
  | Lambda of param list * expr  (** [fn(x) => x + 1] *)
  | Block of stmt list * expr  (** statements, then the block's value *)
  | Con of ident * (ident option * expr) list
      (** a constructor: [Pro(5)] or [Pro(seats: 5)] *)
  | Record of ident option * (ident * expr) list
      (** [User { id: 1 }], or [{ id: 1 }] with the type left out *)
  | Field of expr * ident  (** [user.plan] *)
  | Match of expr * arm list
  | Array of expr list  (** [[1, 2, 3]] *)
  | Index of expr * expr  (** [xs[i]] *)
  | Ref of expr
      (** [&scores]: an argument the call changes, or the array a [for] loop
          changes *)
  | Assign of { target : expr; op : binop option; value : expr }
      (** [x = 1], [user.plan = Free], [xs[i] += 1]; the target is a place *)
  | For of { var : ident; iter : expr; body : expr }
      (** [for x in xs], or [for p in &ps] to change each element *)

and arm = { arm_pat : pattern; arm_guard : expr option; arm_body : expr }

and stmt =
  | Let of { name : ident; ty : ty option; value : expr; mut : bool }
      (** [let], or [var] when [mut] *)
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

type fn_def = {
  pub : bool;
  name : ident;
  tparams : ident list;  (** the [T] in [fn id<T>(x: T) -> T] *)
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

let rec show_ty = function
  | TyName (name, []) -> name.name
  | TyName (name, args) ->
      name.name ^ "<" ^ String.concat ", " (List.map show_ty args) ^ ">"
  | TyInout (t, _) -> "inout " ^ show_ty t
  | TyFn (params, ret, _) ->
      let ret = match ret with Some r -> " -> " ^ show_ty r | None -> "" in
      "fn(" ^ String.concat ", " (List.map show_ty params) ^ ")" ^ ret

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
  | Unit -> "()"
  | Var x -> x
  | Unop (Neg, a) -> parens [ "neg"; show_expr a ]
  | Binop (op, a, b) -> parens [ binop_to_string op; show_expr a; show_expr b ]
  | If (c, t, Some f) -> parens [ "if"; show_expr c; show_expr t; show_expr f ]
  | If (c, t, None) -> parens [ "if"; show_expr c; show_expr t ]
  | Call (f, args) -> parens ("call" :: show_expr f :: List.map show_expr args)
  | Lambda (params, body) ->
      parens [ "lambda"; parens (List.map show_param params); show_expr body ]
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
  | Array xs -> parens ("array" :: List.map show_expr xs)
  | Index (a, i) -> parens [ "index"; show_expr a; show_expr i ]
  | Ref a -> parens [ "&"; show_expr a ]
  | Assign { target; op; value } ->
      let op =
        match op with Some o -> binop_to_string o ^ "=" | None -> "="
      in
      parens [ op; show_expr target; show_expr value ]
  | For { var; iter; body } ->
      parens [ "for"; var.name; show_expr iter; show_expr body ]

and show_arm a =
  let guard =
    match a.arm_guard with Some g -> [ "if"; show_expr g ] | None -> []
  in
  parens ((show_pattern a.arm_pat :: guard) @ [ "=>"; show_expr a.arm_body ])

and show_param p =
  let name =
    match p.pmode with Inout -> "inout " ^ p.pname.name | Read -> p.pname.name
  in
  match p.pty with Some t -> name ^ ":" ^ show_ty t | None -> name

and show_stmt = function
  | Let { name; value; mut; _ } ->
      parens [ (if mut then "var" else "let"); name.name; show_expr value ]
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
