(* Parser: tokens -> AST, by recursive descent.

   Each grammar rule is one function. Precedence comes from which function
   calls which: comparisons call additive, which calls multiplicative, and so
   on down to primary expressions.

     program  := item { NEWLINE item } EOF
     item     := ["pub"] (fn_def | type_def)
     fn_def   := "fn" IDENT ["<" UIDENT, ... ">"] "(" param, ... ")"
                 ["->" type] "=" body
     param    := ["inout"] IDENT [":" type]
     type_def := "type" UIDENT ["<" UIDENT, ... ">"] "=" type_body
     type_body:= "{" field, ... "}"                       (a record)
              |  ["|"] ctor { "|" ctor }                  (a sum type; may be
                                                            indented, one per line)
     ctor     := UIDENT ["(" field, ... ")"]
     field    := IDENT ":" type
     type     := UIDENT ["<" type, ... ">"]
              |  "fn" "(" ["inout"] [IDENT ":"] type, ... ")" ["->" type]

     body     := INDENT block | line
     block    := stmt { NEWLINE stmt } DEDENT       (last stmt is the value)
     stmt     := ("let" | "var") IDENT [":" type] "=" body
              |  "for" IDENT "in" expr INDENT block
              |  line
     line     := expr [("=" | "+=" | "-=" | "*=") body]
                                                    (an assignment's target
                                                     must be a place, mut.ml)
     expr     := add [cmp_op add]                   (comparisons don't chain)
     add      := mul { ("+" | "-") mul }
     mul      := unary { ("*" | "/" | "%") unary }
     unary    := "-" unary | "&" unary | postfix
     postfix  := primary { "." IDENT | "[" expr "]"
                         | "(" expr, ... ")" [lambda] }
                                                    (a trailing lambda is
                                                     the call's last argument)
     primary  := INT | "true" | "false" | "(" ")" | IDENT | lambda
              |  UIDENT ["(" con_args ")" | "{" field_inits "}"]
              |  "{" field_inits "}" | "(" expr ")" | "[" expr, ... "]"
              |  "if" expr "then" body [[NEWLINE] "else" body]
              |  "match" expr INDENT arm { NEWLINE arm } DEDENT
     arm      := pattern ["if" expr] "=>" body
     lambda   := "fn" "(" param, ... ")" "=>" body
     pattern  := "_" | IDENT | INT | "-" INT | "true" | "false"
              |  UIDENT ["(" pattern, ... ")"]

   UIDENT is an IDENT starting with a capital letter: types and constructors
   are capitalized, variables and functions are not. *)

open Ast
open Ast.Parsed
open Token

(* [node] is the last node id handed out in the current top-level item, to
   an expression or a pattern. *)
type t = { toks : (Token.t * Loc.t) array; mutable i : int; mutable node : int }

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

(* An expression, with the next node id. *)
let node p kind loc : expr =
  p.node <- p.node + 1;
  { kind; loc; node = p.node }

let mk kind start p = node p kind (Loc.span start (last_loc p))

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

(* A name that must be capitalized: a type, type parameter or constructor. *)
let upper_ident p what =
  let id = ident p in
  if not (is_upper id.name) then
    Diag.error id.loc
      ~help:(Printf.sprintf "write `%s`" (String.capitalize_ascii id.name))
      (Printf.sprintf "%s must start with a capital letter" what);
  id

(* Items separated by commas, up to and including [close]. A trailing comma
   is allowed. *)
let sep_list p ~close item =
  let rec loop acc =
    if peek p = close then (
      advance p;
      List.rev acc)
    else
      let x = item p in
      if peek p = COMMA then (
        advance p;
        loop (x :: acc))
      else if peek p = close then (
        advance p;
        List.rev (x :: acc))
      else fail_expected p ("`,` or " ^ describe close)
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

(* ---- types ---- *)

let rec parse_ty p : ty =
  match peek p with
  | FN ->
      let start = loc p in
      advance p;
      expect p LPAREN;
      let params = sep_list p ~close:RPAREN parse_fn_ty_param in
      let ret =
        if peek p = ARROW then (
          advance p;
          Some (parse_ty p))
        else None
      in
      TyFn (params, ret, Loc.span start (last_loc p))
  | _ ->
      let name = upper_ident p "a type name" in
      let args =
        if peek p = LT then (
          advance p;
          sep_list p ~close:GT parse_ty)
        else []
      in
      TyName (name, args)

(* A parameter in a function type may be named for documentation, as in
   `fn(id: UserId) -> User`. The name doesn't affect the type. *)
and parse_fn_ty_param p =
  let start = loc p in
  let inout = peek p = INOUT in
  if inout then advance p;
  (match (peek p, peek2 p) with
  | IDENT name, COLON when not (is_upper name) ->
      advance p;
      advance p
  | _ -> ());
  let t = parse_ty p in
  if inout then TyInout (t, Loc.span start (last_loc p)) else t

let parse_param p : param =
  let pmode =
    if peek p = INOUT then (
      advance p;
      Inout)
    else Read
  in
  let pname = ident p in
  let pty =
    if peek p = COLON then (
      advance p;
      Some (parse_ty p))
    else None
  in
  { pname; pty; pmode }

let parse_field_decl p =
  let field_name = ident p in
  expect p COLON;
  { field_name; field_ty = parse_ty p }

let parse_ctor_decl p =
  let ctor_name = upper_ident p "a constructor name" in
  let ctor_fields =
    if peek p = LPAREN then (
      advance p;
      sep_list p ~close:RPAREN parse_field_decl)
    else []
  in
  { ctor_name; ctor_fields }

(* The constructors of a sum type, separated by `|`. When the type is
   indented under `type X =`, each `|` may start its own line. *)
let parse_ctors p =
  if peek p = PIPE then advance p;
  let rec loop acc =
    let c = parse_ctor_decl p in
    if peek p = NEWLINE && peek2 p = PIPE then advance p;
    if peek p = PIPE then (
      advance p;
      loop (c :: acc))
    else List.rev (c :: acc)
  in
  loop []

let parse_type_body p =
  if peek p = LBRACE then (
    advance p;
    Fields (sep_list p ~close:RBRACE parse_field_decl))
  else Ctors (parse_ctors p)

let parse_type p =
  expect p TYPE;
  let type_name = upper_ident p "a type name" in
  let type_params =
    if peek p = LT then (
      advance p;
      sep_list p ~close:GT (fun p -> upper_ident p "a type parameter"))
    else []
  in
  expect p EQ;
  let type_body =
    if peek p = INDENT then (
      advance p;
      let b = parse_type_body p in
      expect p DEDENT;
      b)
    else parse_type_body p
  in
  { type_name; type_params; type_body }

(* ---- patterns ---- *)

let rec parse_pattern p : pattern =
  let start = loc p in
  let finish pkind =
    p.node <- p.node + 1;
    { pkind; ploc = Loc.span start (last_loc p); pnode = p.node }
  in
  match peek p with
  | IDENT "_" ->
      advance p;
      finish PWild
  | IDENT name when is_upper name ->
      let c = ident p in
      if peek p = LPAREN then (
        advance p;
        let args = sep_list p ~close:RPAREN parse_pattern in
        finish (PCon (c, args)))
      else finish (PCon (c, []))
  | IDENT name ->
      advance p;
      finish (PVar { name; loc = Loc.span start (last_loc p) })
  | INT n ->
      advance p;
      finish (PInt n)
  | MINUS -> (
      advance p;
      match peek p with
      | INT n ->
          advance p;
          finish (PInt (-n))
      | _ -> fail_expected p "a number")
  | TRUE ->
      advance p;
      finish (PBool true)
  | FALSE ->
      advance p;
      finish (PBool false)
  | _ -> fail_expected p "a pattern"

(* ---- expressions ---- *)

let rec parse_body p =
  if peek p = INDENT then (
    advance p;
    parse_block p)
  else parse_line p

(* An expression, or an assignment to one: `x = 1`, `xs[i] += 1`. *)
and parse_line p =
  let start = loc p in
  let e = parse_expr p in
  let op =
    match peek p with
    | EQ -> Some None
    | PLUSEQ -> Some (Some Add)
    | MINUSEQ -> Some (Some Sub)
    | STAREQ -> Some (Some Mul)
    | _ -> None
  in
  match op with
  | None -> e
  | Some op ->
      advance p;
      let value = parse_body p in
      mk (Assign { target = e; op; value }) start p

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
      node p (Block (List.rev rest, last)) (Loc.span start last.loc)
  | Let { name; mut; _ } :: _ ->
      Diag.error name.loc
        ~help:"add the value this block should produce as its last line"
        (Printf.sprintf "this block ends with a `%s`, so it has no value"
           (if mut then "var" else "let"))
  | [] -> assert false (* parse_stmt always returns a statement *)

and parse_stmt p =
  match peek p with
  | (LET | VAR) as kw ->
      advance p;
      let name = ident p in
      let ty =
        if peek p = COLON then (
          advance p;
          Some (parse_ty p))
        else None
      in
      expect p EQ;
      Let { name; ty; value = parse_body p; mut = kw = VAR }
  | FOR -> Expr (parse_for p)
  | _ -> Expr (parse_line p)

and parse_for p =
  let start = loc p in
  expect p FOR;
  let var = ident p in
  expect p IN;
  let iter = parse_expr p in
  if peek p <> INDENT then
    Diag.error (loc p) ~help:"put the loop's body on the lines below, indented"
      (Printf.sprintf "expected the body of the `for` loop, found %s"
         (describe (peek p)));
  advance p;
  let body = parse_block p in
  mk (For { var; iter; body }) start p

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
  | AMP ->
      let start = loc p in
      advance p;
      let e = parse_unary p in
      mk (Ref e) start p
  | _ -> parse_postfix p

(* Field access and calls bind tightest: `-user.age` is `-(user.age)`. *)
and parse_postfix p =
  let start = loc p in
  let rec loop e =
    match peek p with
    | DOT ->
        advance p;
        let f = ident p in
        loop (mk (Field (e, f)) start p)
    | LBRACKET ->
        advance p;
        let i = parse_expr p in
        expect p RBRACKET;
        loop (mk (Index (e, i)) start p)
    | LPAREN ->
        advance p;
        let args = sep_list p ~close:RPAREN parse_expr in
        (* `twice() fn() =>` passes the lambda as the last argument, so a
           multi-line lambda doesn't have to sit inside the parentheses *)
        let args = if peek p = FN then args @ [ parse_lambda p ] else args in
        loop (mk (Call (e, args)) start p)
    | _ -> e
  in
  loop (parse_primary p)

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
  | IDENT name when is_upper name -> (
      let c = ident p in
      match peek p with
      | LPAREN ->
          advance p;
          let args = sep_list p ~close:RPAREN parse_con_arg in
          mk (Con (c, args)) start p
      | LBRACE ->
          advance p;
          let fields = sep_list p ~close:RBRACE parse_field_init in
          mk (Record (Some c, fields)) start p
      | _ -> mk (Con (c, [])) start p)
  | IDENT name ->
      advance p;
      mk (Var name) start p
  | LPAREN when peek2 p = RPAREN ->
      advance p;
      advance p;
      mk Unit start p
  | LBRACE ->
      advance p;
      let fields = sep_list p ~close:RBRACE parse_field_init in
      mk (Record (None, fields)) start p
  | LBRACKET ->
      advance p;
      let xs = sep_list p ~close:RBRACKET parse_expr in
      mk (Array xs) start p
  | LPAREN ->
      advance p;
      let e = parse_expr p in
      expect p RPAREN;
      e
  | IF -> parse_if p
  | MATCH -> parse_match p
  | FN -> parse_lambda p
  | _ -> fail_expected p "an expression"

and parse_lambda p =
  let start = loc p in
  expect p FN;
  if peek p <> LPAREN then
    Diag.error (loc p)
      ~help:"functions are defined at the top level; a lambda is `fn(x) => ...`"
      (Printf.sprintf "expected `(` to start a lambda, found %s"
         (describe (peek p)));
  advance p;
  let params = sep_list p ~close:RPAREN parse_param in
  expect p FATARROW;
  let body = parse_body p in
  mk (Lambda (params, body)) start p

(* A constructor argument, optionally labelled: `5` or `seats: 5`. *)
and parse_con_arg p =
  match (peek p, peek2 p) with
  | IDENT _, COLON ->
      let label = ident p in
      advance p;
      (Some label, parse_expr p)
  | _ -> (None, parse_expr p)

(* A field in a record literal: `id: 1`, or just `id` meaning `id: id`. *)
and parse_field_init p =
  let f = ident p in
  if peek p = COLON then (
    advance p;
    (f, parse_expr p))
  else (f, node p (Var f.name) f.loc)

and parse_if p =
  let start = loc p in
  expect p IF;
  let cond = parse_expr p in
  expect p THEN;
  let then_ = parse_body p in
  (* `else` may start its own line after an indented `then` block *)
  if peek p = NEWLINE && peek2 p = ELSE then advance p;
  let else_ =
    if peek p = ELSE then (
      advance p;
      Some (parse_body p))
    else None
  in
  mk (If (cond, then_, else_)) start p

and parse_match p =
  let start = loc p in
  expect p MATCH;
  let subject = parse_expr p in
  if peek p <> INDENT then
    Diag.error (loc p)
      ~help:"put each arm on its own line, indented under the `match`"
      (Printf.sprintf "expected the arms of the `match`, found %s"
         (describe (peek p)));
  advance p;
  let rec arms acc =
    let a = parse_arm p in
    match peek p with
    | NEWLINE ->
        advance p;
        arms (a :: acc)
    | DEDENT ->
        advance p;
        List.rev (a :: acc)
    | _ -> fail_expected p "the end of the line"
  in
  let arms = arms [] in
  mk (Match (subject, arms)) start p

and parse_arm p =
  let arm_pat = parse_pattern p in
  let arm_guard =
    if peek p = IF then (
      advance p;
      Some (parse_expr p))
    else None
  in
  expect p FATARROW;
  { arm_pat; arm_guard; arm_body = parse_body p }

(* ---- items ---- *)

let parse_fn p ~pub =
  let start = loc p in
  expect p FN;
  let name = ident p in
  let tparams =
    if peek p = LT then (
      advance p;
      sep_list p ~close:GT (fun p -> upper_ident p "a type parameter"))
    else []
  in
  expect p LPAREN;
  let params = sep_list p ~close:RPAREN parse_param in
  let ret =
    if peek p = ARROW then (
      advance p;
      Some (parse_ty p))
    else None
  in
  expect p EQ;
  let body = parse_body p in
  { pub; name; tparams; params; ret; body; loc = Loc.span start (last_loc p) }

let parse_item p =
  p.node <- 0;
  let pub = peek p = PUB in
  if pub then advance p;
  match peek p with
  | FN -> Fn (parse_fn p ~pub)
  | TYPE -> Type (parse_type p)
  | _ ->
      Diag.error (loc p)
        ~help:
          "only function and type definitions can appear at the top level (for \
           now)"
        (Printf.sprintf "expected `fn` or `type`, found %s" (describe (peek p)))

(* After a syntax error, skip to where the next top-level item starts: a
   line beginning in the first column. Nothing inside an item starts there,
   since its body is indented, so parsing can pick up cleanly from it.
   [start] is where the broken item began; if the error was found at the
   start of the next item, that item is kept. *)
let skip_to_item p ~start =
  let at_item p =
    p.i > 0
    && fst p.toks.(p.i - 1) = NEWLINE
    && (loc p).start.col = 1
    && not (List.mem (peek p) [ NEWLINE; INDENT; DEDENT ])
  in
  if p.i = start || not (at_item p) then (
    advance p;
    while peek p <> EOF && not (at_item p) do
      advance p
    done)

let parse_program sink toks =
  let p = { toks; i = 0; node = 0 } in
  let rec loop acc =
    if peek p = EOF then List.rev acc
    else
      let start = p.i in
      match
        let item = parse_item p in
        if peek p = NEWLINE then advance p
        else if peek p <> EOF then fail_expected p "a new line";
        item
      with
      | item -> loop (item :: acc)
      | exception Diag.Error d ->
          Diag.report sink d;
          skip_to_item p ~start;
          loop acc
  in
  loop []
