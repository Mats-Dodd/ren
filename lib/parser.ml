(* Parser: tokens -> AST, by recursive descent.

   Each grammar rule is one function. Precedence comes from which function
   calls which: comparisons call additive, which calls multiplicative, and so
   on down to primary expressions.

     program := fn_def { NEWLINE fn_def } EOF
     fn_def  := ["pub"] "fn" IDENT "(" params ")" ["->" type] "=" body
     body    := INDENT block | expr
     block   := stmt { NEWLINE stmt } DEDENT       (last stmt is the value)
     stmt    := "let" IDENT [":" type] "=" body | expr
     expr    := add [cmp_op add]                   (comparisons don't chain)
     add     := mul { ("+" | "-") mul }
     mul     := unary { ("*" | "/" | "%") unary }
     unary   := "-" unary | primary
     primary := INT | "true" | "false" | IDENT ["(" args ")"]
              | "(" expr ")" | "if" expr "then" body [NEWLINE] "else" body *)

open Ast
open Token

type t = { toks : (Token.t * Loc.t) array; mutable i : int }

let peek p = fst p.toks.(p.i)
let peek2 p = fst p.toks.(min (p.i + 1) (Array.length p.toks - 1))
let loc p = snd p.toks.(p.i)
let advance p = if p.i < Array.length p.toks - 1 then p.i <- p.i + 1

(* Location of the last real token consumed, skipping layout tokens, so a
   node's span ends where its code ends rather than at the next line. *)
let last_loc p =
  let rec back j =
    match fst p.toks.(j) with
    | (NEWLINE | INDENT | DEDENT) when j > 0 -> back (j - 1)
    | _ -> snd p.toks.(j)
  in
  back (max 0 (p.i - 1))

let mk kind start p = { kind; loc = Loc.span start (last_loc p) }

let describe = function
  | INT n -> Printf.sprintf "the number `%d`" n
  | IDENT s -> Printf.sprintf "`%s`" s
  | NEWLINE -> "a new line"
  | INDENT -> "an indented block"
  | DEDENT -> "the end of the block"
  | EOF -> "the end of the file"
  | tok -> Printf.sprintf "`%s`" (Token.to_string tok)

let fail_expected p what =
  Diag.error (loc p)
    (Printf.sprintf "expected %s, found %s" what (describe (peek p)))

let expect p tok =
  if peek p = tok then advance p else fail_expected p (describe tok)

let ident p =
  match peek p with
  | IDENT name ->
      let l = loc p in
      advance p;
      { name; loc = l }
  | _ -> fail_expected p "a name"

(* Items separated by commas, up to and including the closing `)`. A trailing
   comma is allowed. *)
let comma_list p item =
  let rec loop acc =
    if peek p = RPAREN then (
      advance p;
      List.rev acc)
    else
      let x = item p in
      match peek p with
      | COMMA ->
          advance p;
          loop (x :: acc)
      | RPAREN ->
          advance p;
          List.rev (x :: acc)
      | _ -> fail_expected p "`,` or `)`"
  in
  loop []

let cmp_op = function
  | EQEQ -> Some Eq
  | NEQ -> Some Neq
  | LT -> Some Lt
  | LE -> Some Le
  | GT -> Some Gt
  | GE -> Some Ge
  | _ -> None

let rec parse_body p =
  if peek p = INDENT then (
    advance p;
    parse_block p)
  else parse_expr p

and parse_block p =
  let start = loc p in
  let rec stmts acc =
    let s = parse_stmt p in
    match peek p with
    | NEWLINE ->
        advance p;
        stmts (s :: acc)
    | DEDENT ->
        advance p;
        s :: acc (* reversed: last statement first *)
    | _ -> fail_expected p "the end of the line"
  in
  match stmts [] with
  | [ Expr e ] -> e
  | Expr last :: rest ->
      { kind = Block (List.rev rest, last); loc = Loc.span start last.loc }
  | Let { name; _ } :: _ ->
      Diag.error name.loc
        ~help:"add the value this block should produce as its last line"
        "this block ends with a `let`, so it has no value"
  | [] -> assert false (* parse_stmt always returns a statement *)

and parse_stmt p =
  match peek p with
  | LET ->
      advance p;
      let name = ident p in
      let ty =
        if peek p = COLON then (
          advance p;
          Some (ident p))
        else None
      in
      expect p EQ;
      Let { name; ty; value = parse_body p }
  | _ -> Expr (parse_expr p)

and parse_expr p =
  let start = loc p in
  let lhs = parse_add p in
  match cmp_op (peek p) with
  | None -> lhs
  | Some op ->
      advance p;
      let rhs = parse_add p in
      if cmp_op (peek p) <> None then
        Diag.error (loc p) ~help:"split it into two comparisons"
          "comparisons can't be chained";
      mk (Binop (op, lhs, rhs)) start p

(* A left-associative binary level: `a - b - c` parses as `(a - b) - c`. *)
and left_assoc ops next p =
  let start = loc p in
  let rec loop lhs =
    match List.assoc_opt (peek p) ops with
    | Some op ->
        advance p;
        let rhs = next p in
        loop (mk (Binop (op, lhs, rhs)) start p)
    | None -> lhs
  in
  loop (next p)

and parse_add p = left_assoc [ (PLUS, Add); (MINUS, Sub) ] parse_mul p

and parse_mul p =
  left_assoc [ (STAR, Mul); (SLASH, Div); (PERCENT, Mod) ] parse_unary p

and parse_unary p =
  match peek p with
  | MINUS ->
      let start = loc p in
      advance p;
      let e = parse_unary p in
      mk (Unop (Neg, e)) start p
  | _ -> parse_primary p

and parse_primary p =
  let start = loc p in
  match peek p with
  | INT n ->
      advance p;
      mk (Int n) start p
  | TRUE ->
      advance p;
      mk (Bool true) start p
  | FALSE ->
      advance p;
      mk (Bool false) start p
  | IDENT _ ->
      let name = ident p in
      if peek p = LPAREN then (
        advance p;
        let args = comma_list p parse_expr in
        mk (Call (name, args)) start p)
      else mk (Var name.name) start p
  | LPAREN ->
      advance p;
      let e = parse_expr p in
      expect p RPAREN;
      e
  | IF -> parse_if p
  | _ -> fail_expected p "an expression"

and parse_if p =
  let start = loc p in
  expect p IF;
  let cond = parse_expr p in
  expect p THEN;
  let then_ = parse_body p in
  (* `else` may start its own line after an indented `then` block *)
  if peek p = NEWLINE && peek2 p = ELSE then advance p;
  if peek p <> ELSE then
    Diag.error start
      ~help:
        "add an `else` branch: `if` produces a value, so both branches are \
         needed"
      "this `if` has no `else`";
  advance p;
  let else_ = parse_body p in
  mk (If (cond, then_, else_)) start p

let parse_param p =
  let pname = ident p in
  expect p COLON;
  { pname; pty = ident p }

let parse_fn p =
  let start = loc p in
  if peek p = PUB then advance p;
  if peek p <> FN then
    Diag.error (loc p)
      ~help:"only function definitions can appear at the top level (for now)"
      (Printf.sprintf "expected `fn`, found %s" (describe (peek p)));
  advance p;
  let name = ident p in
  expect p LPAREN;
  let params = comma_list p parse_param in
  let ret =
    if peek p = ARROW then (
      advance p;
      Some (ident p))
    else None
  in
  expect p EQ;
  let body = parse_body p in
  { name; params; ret; body; loc = Loc.span start (last_loc p) }

let parse_program toks =
  let p = { toks; i = 0 } in
  let rec loop acc =
    if peek p = EOF then List.rev acc
    else
      let f = parse_fn p in
      if peek p = NEWLINE then advance p
      else if peek p <> EOF then fail_expected p "a new line";
      loop (f :: acc)
  in
  loop []
