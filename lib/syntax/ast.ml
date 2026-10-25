(* The abstract syntax tree: what the parser produces and every later pass
   consumes. Adding a constructor here makes the compiler point at every
   [match] that needs a new case. *)

type ident = { name : string; loc : Loc.t }

(* The tree comes in two versions, built from the same type definitions:
   the parser's, where every name is the string that was written, and
   Resolve's (resolve.ml), where every name says what it refers to. The
   type parameters say which: ['v] is a variable or function being used,
   ['b] a name being bound (by a `let`, a parameter, a loop or a pattern),
   and ['t] a type's name. [Parsed] and [Resolved] at the bottom of this
   file name the two versions.

   A type with parameters, like [('v, 'b, 't) expr], is a family of types,
   one for each choice of them; [List] works the same way, as ['a list]. *)

(* A type as written: `Int`, `Option<Int>`, `fn(Int) -> Bool`. *)
type 't ty =
  | TyName of 't * 't ty list  (** [Int], [Option<Int>] *)
  | TyFn of 't ty list * 't ty option * Loc.t
      (** [fn(Int) -> Bool]; with no [->] the function returns [Unit] *)
  | TyInout of 't ty * Loc.t
      (** [inout Int], a parameter of a function type: [fn(inout Int)] *)

type binop = Add | Sub | Mul | Div | Mod | Eq | Neq | Lt | Le | Gt | Ge
type unop = Neg

(* Patterns, the left-hand side of a `match` arm. [pnode] numbers it along
   with the expressions of its function (see [expr] below). *)
type 'b pattern = { pkind : 'b pattern_kind; ploc : Loc.t; pnode : int }

and 'b pattern_kind =
  | PWild  (** [_] *)
  | PVar of 'b  (** a lowercase name: matches anything, binds it *)
  | PInt of int
  | PBool of bool
  | PCon of ident * 'b pattern list  (** [Free], [Pro(seats)] *)

(* How a parameter is passed: read-only (the default), or [inout], which
   updates the caller's value. *)
type mode = Read | Inout

(* A parameter of a function or lambda; its type may be left out. *)
type ('b, 't) param = { pname : 'b; pty : 't ty option; pmode : mode }

(* [node] numbers the expressions and patterns of one top-level function,
   so later passes can say things about a particular expression. *)
type ('v, 'b, 't) expr = {
  kind : ('v, 'b, 't) expr_kind;
  loc : Loc.t;
  node : int;
}

and ('v, 'b, 't) expr_kind =
  | Int of int
  | Bool of bool
  | Unit  (** [()] *)
  | Var of 'v  (** a local variable, or a top-level function *)
  | Unop of unop * ('v, 'b, 't) expr
  | Binop of binop * ('v, 'b, 't) expr * ('v, 'b, 't) expr
  | If of ('v, 'b, 't) expr * ('v, 'b, 't) expr * ('v, 'b, 't) expr option
      (** with no [else], the [if] is [Unit] *)
  | Call of ('v, 'b, 't) expr * ('v, 'b, 't) expr list
      (** [f(x)], [make()(x)], [handlers.on_click()] *)
  | Lambda of ('b, 't) param list * ('v, 'b, 't) expr  (** [fn(x) => x + 1] *)
  | Block of ('v, 'b, 't) stmt list * ('v, 'b, 't) expr
      (** statements, then the block's value *)
  | Con of ident * (ident option * ('v, 'b, 't) expr) list
      (** a constructor: [Pro(5)] or [Pro(seats: 5)] *)
  | Record of 't option * (ident * ('v, 'b, 't) expr) list
      (** [User { id: 1 }], or [{ id: 1 }] with the type left out *)
  | Field of ('v, 'b, 't) expr * ident  (** [user.plan] *)
  | Match of ('v, 'b, 't) expr * ('v, 'b, 't) arm list
  | Array of ('v, 'b, 't) expr list  (** [[1, 2, 3]] *)
  | Index of ('v, 'b, 't) expr * ('v, 'b, 't) expr  (** [xs[i]] *)
  | Ref of ('v, 'b, 't) expr
      (** [&scores]: an argument the call changes, or the array a [for] loop
          changes *)
  | Assign of {
      target : ('v, 'b, 't) expr;
      op : binop option;
      value : ('v, 'b, 't) expr;
    }  (** [x = 1], [user.plan = Free], [xs[i] += 1]; the target is a place *)
  | For of { var : 'b; iter : ('v, 'b, 't) expr; body : ('v, 'b, 't) expr }
      (** [for x in xs], or [for p in &ps] to change each element *)

and ('v, 'b, 't) arm = {
  arm_pat : 'b pattern;
  arm_guard : ('v, 'b, 't) expr option;
  arm_body : ('v, 'b, 't) expr;
}

and ('v, 'b, 't) stmt =
  | Let of {
      name : 'b;
      ty : 't ty option;
      value : ('v, 'b, 't) expr;
      mut : bool;
    }  (** [let], or [var] when [mut] *)
  | Expr of ('v, 'b, 't) expr

(* Type declarations. *)

type 't field = { field_name : ident; field_ty : 't ty }
type 't ctor = { ctor_name : ident; ctor_fields : 't field list }

type 't type_body =
  | Fields of 't field list  (** a record: [{ id: Int, plan: Plan }] *)
  | Ctors of 't ctor list  (** a sum type: [| Free | Pro(seats: Int)] *)

type 't type_def = {
  type_name : ident;
  type_params : ident list;  (** the [T] in [Option<T>] *)
  type_body : 't type_body;
}

type ('v, 'b, 't) fn_def = {
  pub : bool;
  name : ident;
  tparams : ident list;  (** the [T] in [fn id<T>(x: T) -> T] *)
  params : ('b, 't) param list;
  ret : 't ty option;
  body : ('v, 'b, 't) expr;
  loc : Loc.t;
}

(* An import, at the top of a file: `import billing/stripe`,
   `import billing/stripe as pay`, `import shop/plan.{Plan, User}`. Its
   names are only strings and locations, so it's the same in both versions
   of the tree. *)
type import = {
  segments : ident list;  (** [billing], [stripe] *)
  path : string;  (** the module: [billing/stripe] *)
  path_loc : Loc.t;  (** where the module's path is written *)
  alias : ident;
      (** what the module is called here: the name after [as], or else the
          path's last segment *)
  names : ident list;
      (** the types imported by name: the [Plan] in [.{Plan}] *)
  iloc : Loc.t;  (** the whole import *)
}

type ('v, 'b, 't) item =
  | Fn of ('v, 'b, 't) fn_def
  | Type of 't type_def
  | Import of import

type ('v, 'b, 't) program = ('v, 'b, 't) item list

(* ---- names, once resolved ----

   What Resolve (resolve.ml) finds each name refers to. *)

(* A local name: a variable, a parameter, a loop variable or a name bound
   by a pattern. [id] tells it apart from every other local of the same
   top-level function, even one with the same name. *)
type binder = {
  id : int;  (** numbered per top-level function *)
  ident : ident;  (** the name, where it's bound *)
  bound : bound;
  depth : int;  (** how many lambdas deep it's bound *)
}

and bound =
  | By_let
  | By_var
  | By_param  (** a parameter of a top-level function *)
  | By_inout  (** an [inout] parameter *)
  | By_lambda  (** a lambda's parameter *)
  | By_loop  (** [x] in [for x in xs] *)
  | By_ref_loop  (** [p] in [for p in &ps], which changes each element *)
  | By_pattern

(* A name used as a value. *)
type name =
  | Local of binder
  | Global of Path.t  (** a top-level function *)
  | Intrinsic of string  (** a function built into the compiler: [print] *)

(* A type's name: a declared type, or the [i]th type parameter in scope
   (of the type being declared, or of the function). *)
type tname = { tref : tref; tloc : Loc.t }
and tref = Named of Path.t | Param of int

module Parsed = struct
  type nonrec ty = ident ty
  type nonrec pattern = ident pattern
  type nonrec param = (ident, ident) param
  type nonrec expr = (string, ident, ident) expr
  type nonrec expr_kind = (string, ident, ident) expr_kind
  type nonrec arm = (string, ident, ident) arm
  type nonrec stmt = (string, ident, ident) stmt
  type nonrec field = ident field
  type nonrec type_def = ident type_def
  type nonrec fn_def = (string, ident, ident) fn_def
  type nonrec item = (string, ident, ident) item
  type nonrec program = (string, ident, ident) program
end

module Resolved = struct
  type nonrec ty = tname ty
  type nonrec pattern = binder pattern
  type nonrec param = (binder, tname) param
  type nonrec expr = (name, binder, tname) expr
  type nonrec expr_kind = (name, binder, tname) expr_kind
  type nonrec arm = (name, binder, tname) arm
  type nonrec stmt = (name, binder, tname) stmt
  type nonrec field = tname field
  type nonrec type_def = tname type_def
  type nonrec fn_def = (name, binder, tname) fn_def
  type nonrec item = (name, binder, tname) item
  type nonrec program = (name, binder, tname) program
end

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

open Parsed

let rec show_ty : ty -> string = function
  | TyName (name, []) -> name.name
  | TyName (name, args) ->
      name.name ^ "<" ^ String.concat ", " (List.map show_ty args) ^ ">"
  | TyInout (t, _) -> "inout " ^ show_ty t
  | TyFn (params, ret, _) ->
      let ret = match ret with Some r -> " -> " ^ show_ty r | None -> "" in
      "fn(" ^ String.concat ", " (List.map show_ty params) ^ ")" ^ ret

let rec show_pattern (p : pattern) =
  match p.pkind with
  | PWild -> "_"
  | PVar x -> x.name
  | PInt n -> string_of_int n
  | PBool b -> string_of_bool b
  | PCon (c, []) -> c.name
  | PCon (c, args) ->
      c.name ^ "(" ^ String.concat ", " (List.map show_pattern args) ^ ")"

let rec show_expr (e : expr) =
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

and show_arm (a : arm) =
  let guard =
    match a.arm_guard with Some g -> [ "if"; show_expr g ] | None -> []
  in
  parens ((show_pattern a.arm_pat :: guard) @ [ "=>"; show_expr a.arm_body ])

and show_param (p : param) =
  let name =
    match p.pmode with Inout -> "inout " ^ p.pname.name | Read -> p.pname.name
  in
  match p.pty with Some t -> name ^ ":" ^ show_ty t | None -> name

and show_stmt : stmt -> string = function
  | Let { name; value; mut; _ } ->
      parens [ (if mut then "var" else "let"); name.name; show_expr value ]
  | Expr e -> show_expr e

let show_fn (f : fn_def) =
  let params = List.map (fun (p : param) -> p.pname.name) f.params in
  parens [ "fn"; f.name.name; parens params; show_expr f.body ]

let show_type_def (td : type_def) =
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

let show_import (i : import) =
  let names =
    match i.names with
    | [] -> []
    | ns -> [ parens (List.map (fun (n : ident) -> n.name) ns) ]
  in
  parens (("import" :: i.path :: names) @ [ "as"; i.alias.name ])

let show_item : item -> string = function
  | Fn f -> show_fn f
  | Type td -> show_type_def td
  | Import i -> show_import i
