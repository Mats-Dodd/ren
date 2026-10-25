(* Parser: tokens -> AST, by recursive descent.

   Each grammar rule is one function. Precedence comes from which function
   calls which: `||` calls `&&`, which calls `not`, which calls comparisons,
   which call additive, and so on down to primary expressions.

     program  := item { NEWLINE item } EOF       (imports come first)
     item     := import | ["pub"] (fn_def | type_def)
     import   := "import" IDENT { "/" IDENT } ["." "{" UIDENT, ... "}"]
                 ["as" IDENT]
     fn_def   := "fn" IDENT ["<" UIDENT, ... ">"] "(" param, ... ")"
                 ["->" type] ["uses" UIDENT, ...] "=" body
                                                   (`uses` may start the
                                                    next line, indented)
     param    := ["inout"] (IDENT | "self") [":" type]
     type_def := "type" UIDENT ["<" UIDENT, ... ">"] "=" type_body [members]
     members  := INDENT op { NEWLINE op } DEDENT
                                                   (or, after an indented
                                                    body, on the lines after
                                                    it: the first line not
                                                    starting with `|` ends
                                                    a sum type's variants)
     op       := ["pub"] fn_def
              |  ["pub"] "let" IDENT [":" type] "=" body
              |  IDENT ["(" param, ... ")"] "=>" body
                                                   (an operator: parsed, but
                                                    reported until stage 9)
     type_body:= "{" field, ... "}"                       (a record)
              |  "opaque" type                           (a type of its own)
              |  ["|"] ctor { "|" ctor }                  (a sum type; may be
                                                            indented, one per line)
     ctor     := UIDENT ["(" field, ... ")"]
     field    := IDENT ":" type
     type     := tyname ["<" type, ... ">"]
              |  "fn" "(" ["inout"] [IDENT ":"] type, ... ")" ["->" type]
     tyname   := [IDENT "."] UIDENT                (`stripe.Client`: another
                                                    module's, after its alias)
     ctor_ref := [tyname "."] UIDENT               (`Red`, `Light.Red`,
                                                    `billing.Plan.Free`)

     body     := INDENT block | line
     block    := stmt { NEWLINE stmt } DEDENT       (last stmt is the value)
     stmt     := ("let" | "var") IDENT [":" type] "=" body
              |  "for" IDENT "in" expr INDENT block
              |  line
     line     := expr [("=" | "+=" | "-=" | "*=") body]
                                                    (an assignment's target
                                                     must be a place, mut.ml)
     expr     := and { "||" and }
     and      := not { "&&" not }
     not      := "not" not | cmp                    (`not a == b` is
                                                     `not (a == b)`)
     cmp      := add [cmp_op add]                   (comparisons don't chain)
     add      := mul { ("+" | "-") mul }
     mul      := unary { ("*" | "/" | "%") unary }
     unary    := "-" unary | "&" unary | postfix
     postfix  := primary { "." IDENT | "[" expr "]"
                         | "(" expr, ... ")" [lambda] }
                                                    (a trailing lambda is
                                                     the call's last argument)
     primary  := INT | "true" | "false" | "(" ")" | IDENT | "self" | lambda
              |  ctor_ref ["(" con_args ")"] | tyname "{" field_inits "}"
              |  tyname "." IDENT               (a member: `Stack.of`)
              |  "{" field_inits "}" | "(" expr ")" | "[" expr, ... "]"
              |  "if" expr "then" body [[NEWLINE] "else" body]
              |  "match" expr INDENT arm { NEWLINE arm } DEDENT
     arm      := pattern ["if" expr] "=>" body
     lambda   := "fn" "(" param, ... ")" "=>" body
     pattern  := "_" | IDENT | INT | "-" INT | "true" | "false"
              |  ctor_ref ["(" pattern, ... ")"]

   UIDENT is an IDENT starting with a capital letter: types and constructors
   are capitalized, variables, functions and modules are not. That's how
   `billing.Plan` (a module's type) is told apart from `user.plan` (a
   field) without looking anything up (module-build.md, "Naming is
   enforced"). *)

open Ast
open Ast.Parsed
open Token

(* [node] is the last node id handed out in the current top-level item, to
   an expression or a pattern. [sink] collects the errors parsing can carry
   on after (diag.ml). *)
type t = {
  toks : (Token.t * Loc.t) array;
  mutable i : int;
  mutable node : int;
  sink : Diag.sink;
}

let peek p = fst p.toks.(p.i)
let peek2 p = fst p.toks.(min (p.i + 1) (Array.length p.toks - 1))
let peek3 p = fst p.toks.(min (p.i + 2) (Array.length p.toks - 1))
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
  | SELF ->
      Diag.error (loc p) ~help:"choose another name"
        "`self` is reserved for the first parameter of a method"
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

(* A type's name: `Plan`, or `stripe.Client`, with its module's alias in
   front. *)
let parse_tyname p =
  match (peek p, peek2 p) with
  | IDENT m, DOT when not (is_upper m) ->
      let alias = ident p in
      advance p;
      { tmod = Some alias; tid = upper_ident p "a type name" }
  | _ -> { tmod = None; tid = upper_ident p "a type name" }

(* Is the next thing a type's name with a module in front, `billing.Plan`,
   rather than a variable or a field? *)
let at_module_type p =
  match (peek p, peek2 p, peek3 p) with
  | IDENT m, DOT, IDENT t -> (not (is_upper m)) && is_upper t
  | _ -> false

(* A constructor: `Red`, or after its type, `Light.Red` or
   `billing.Plan.Free`. *)
let parse_ctor_ref p : ctor_ref =
  if at_module_type p then (
    let t = parse_tyname p in
    expect p DOT;
    { qual = Some t; name = upper_ident p "a constructor name" })
  else
    let first = upper_ident p "a constructor name" in
    if peek p = DOT then (
      advance p;
      {
        qual = Some { tmod = None; tid = first };
        name = upper_ident p "a constructor name";
      })
    else { qual = None; name = first }

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
      let name = parse_tyname p in
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
  let pname =
    match peek p with
    | SELF ->
        (* Resolve checks that it's a method's first parameter *)
        let l = loc p in
        advance p;
        { name = "self"; loc = l }
    | _ -> ident p
  in
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
  match peek p with
  | LBRACE ->
      advance p;
      Fields (sep_list p ~close:RBRACE parse_field_decl)
  | OPAQUE ->
      advance p;
      Opaque (parse_ty p)
  | _ -> Ctors (parse_ctors p)

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
  | IDENT name when is_upper name || at_module_type p ->
      let c = parse_ctor_ref p in
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

and parse_expr p = left_assoc [ (PIPEPIPE, Or) ] parse_and p
and parse_and p = left_assoc [ (AMPAMP, And) ] parse_not p

and parse_not p =
  match peek p with
  | NOT ->
      let start = loc p in
      advance p;
      let e = parse_not p in
      mk (Unop (Not, e)) start p
  | _ -> parse_cmp p

and parse_cmp p =
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
  | IDENT name when at_module_type p || is_upper name -> (
      (* `billing.Plan.Free` and `Plan.Free` are constructors, and
         `rows.Row { ... }` and `Row { ... }` records *)
      let t = parse_tyname p in
      match peek p with
      | LBRACE ->
          advance p;
          let fields = sep_list p ~close:RBRACE parse_field_init in
          mk (Record (Some t, fields)) start p
      | DOT when match peek2 p with IDENT n -> not (is_upper n) | _ -> false
        -> (
          (* `stack.Stack.empty`: a member of the type. Without
             the module, `Stack.of` could be one too, or `Admin.rank` a
             method of the constructor `Admin`: it's read as the second, and
             Resolve, which knows which names are types, decides. *)
          advance p;
          let f = ident p in
          match t.tmod with
          | Some _ -> mk (Var (Item (t, f))) start p
          | None ->
              let c =
                node p (Con ({ qual = None; name = t.tid }, [])) t.tid.loc
              in
              mk (Field (c, f)) start p)
      | DOT when match peek2 p with IDENT n -> is_upper n | _ -> false -> (
          advance p;
          let c =
            { qual = Some t; name = upper_ident p "a constructor name" }
          in
          match peek p with
          | LPAREN -> con_args p start c
          | _ -> mk (Con (c, [])) start p)
      | _ when t.tmod <> None ->
          Diag.error
            (Loc.span start (last_loc p))
            ~help:
              (Printf.sprintf
                 "write one of its constructors after it, like `%s.Name`, or a \
                  record, `%s { ... }`"
                 (show_tyname t) (show_tyname t))
            (Printf.sprintf "`%s` is a type, so it can't be used as a value"
               (show_tyname t))
      | LPAREN -> con_args p start { qual = None; name = t.tid }
      | _ -> mk (Con ({ qual = None; name = t.tid }, [])) start p)
  | IDENT name ->
      advance p;
      mk (Var (Bare name)) start p
  | SELF ->
      advance p;
      mk (Var (Bare "self")) start p
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

(* A constructor's arguments, in parentheses. *)
and con_args p start c =
  expect p LPAREN;
  let args = sep_list p ~close:RPAREN parse_con_arg in
  mk (Con (c, args)) start p

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
  else (f, node p (Var (Bare f.name)) f.loc)

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

(* [name] in snake_case: `UserId` is `user_id`. *)
let snake_case name =
  let b = Buffer.create (String.length name + 4) in
  String.iteri
    (fun i c ->
      if c >= 'A' && c <= 'Z' then (
        if i > 0 && name.[i - 1] <> '_' then Buffer.add_char b '_';
        Buffer.add_char b (Char.lowercase_ascii c))
      else Buffer.add_char b c)
    name;
  Buffer.contents b

(* A name that's part of a module's path, or a module's alias: snake_case,
   like the file it names. [file] says whether it's a file or folder's
   name, which then has to change too. *)
let module_ident p ~file =
  let id = ident p in
  if snake_case id.name <> id.name then
    Diag.error id.loc
      ~help:
        (Printf.sprintf "write `%s`%s" (snake_case id.name)
           (if file then ", and rename its file or folder to match" else ""))
      (Printf.sprintf "`%s` can't name a module: module names are snake_case"
         id.name);
  id

let parse_import p =
  let start = loc p in
  expect p IMPORT;
  let rec segments acc =
    let seg = module_ident p ~file:true in
    if peek p = SLASH then (
      advance p;
      segments (seg :: acc))
    else List.rev (seg :: acc)
  in
  let segments = segments [] in
  let last = List.nth segments (List.length segments - 1) in
  let path_loc = Loc.span (List.hd segments).loc last.loc in
  let names =
    if peek p = DOT then (
      advance p;
      let brace = loc p in
      expect p LBRACE;
      let names =
        sep_list p ~close:RBRACE (fun p ->
            let id = ident p in
            if not (is_upper id.name) then
              Diag.error id.loc
                ~help:
                  (Printf.sprintf "remove it, and write `%s.%s` where it's used"
                     last.name id.name)
                (Printf.sprintf
                   "only types can be imported by name, and `%s` isn't one"
                   id.name);
            id)
      in
      if names = [] then
        Diag.error
          (Loc.span brace (last_loc p))
          ~help:"remove the `.{}`" "this imports nothing by name";
      names)
    else []
  in
  let alias =
    if peek p = AS then (
      advance p;
      module_ident p ~file:false)
    else last
  in
  {
    segments;
    path = String.concat "/" (List.map (fun (s : ident) -> s.name) segments);
    path_loc;
    alias;
    names;
    iloc = Loc.span start (last_loc p);
  }

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
  let uses =
    if peek p = USES then (
      advance p;
      let rec deps acc =
        let d = upper_ident p "a dependency's name" in
        if peek p = COMMA then (
          advance p;
          deps (d :: acc))
        else List.rev (d :: acc)
      in
      Some (deps []))
    else if peek p = NEWLINE && peek2 p = USES then
      (* the lexer continues the signature only on an indented line *)
      Diag.error ~help:"indent it, so it continues the signature"
        (snd p.toks.(p.i + 1))
        "`uses` on a line of its own has to be indented"
    else None
  in
  expect p EQ;
  let body = parse_body p in
  {
    pub;
    name;
    tparams;
    params;
    ret;
    uses;
    body;
    loc = Loc.span start (last_loc p);
  }

(* ---- types' members ---- *)

(* A line left over from when a type's members were written in an `ops`
   block. *)
let no_ops_block p =
  if peek p = IDENT "ops" && peek2 p = EQ then
    Diag.error (loc p)
      ~help:"delete this line and indent what was under it one level less"
      "`ops =` is gone: a type's methods go directly under it"

(* One of the type [tname]'s members, or [None] for an operator, which is
   reported: the syntax is reserved, but what operators mean arrives in
   stage 9. *)
let parse_op p ~tname =
  no_ops_block p;
  let pub = peek p = PUB in
  if pub then advance p;
  match peek p with
  | FN -> Some { op_kind = Op_fn; op_fn = parse_fn p ~pub }
  | LET ->
      let start = loc p in
      advance p;
      let name = ident p in
      let ret =
        if peek p = COLON then (
          advance p;
          Some (parse_ty p))
        else None
      in
      expect p EQ;
      let body = parse_body p in
      Some
        {
          op_kind = Op_value;
          op_fn =
            {
              pub;
              name;
              tparams = [];
              params = [];
              ret;
              uses = None;
              body;
              loc = Loc.span start (last_loc p);
            };
        }
  | VAR ->
      Diag.error (loc p) ~help:"write `let`"
        "an associated value can't be a `var`: it's made once, and never \
         changes"
  | IDENT _ when peek2 p = LPAREN || peek2 p = FATARROW ->
      let name = ident p in
      let params =
        if peek p = LPAREN then (
          advance p;
          sep_list p ~close:RPAREN parse_param)
        else []
      in
      expect p FATARROW;
      ignore (parse_body p);
      Diag.report p.sink
        (Diag.make name.loc
           ~help:
             (if params = [] then
                Printf.sprintf
                  "for now, write an associated value: `let %s = ...`" name.name
              else
                Printf.sprintf
                  "for now, write a method: `fn %s(self, ...) = ...`" name.name)
           (Printf.sprintf "operators like `%s` arrive in stage 9" name.name));
      None
  | tok ->
      let what =
        Printf.sprintf "`fn`, `let` or an operator, in `%s`'s members" tname
      in
      let help =
        match tok with
        | IDENT c when is_upper c ->
            Some "a variant starts with `|`, and the variants come first"
        | _ -> None
      in
      Diag.error ?help (loc p)
        (Printf.sprintf "expected %s, found %s" what (describe tok))

(* A type's members, each on its own line, up to the end of the block
   they're in, which is left for the caller to close. *)
let parse_members p ~tname =
  let rec items acc =
    let acc = match parse_op p ~tname with Some o -> o :: acc | None -> acc in
    match peek p with
    | NEWLINE ->
        advance p;
        items acc
    | DEDENT -> List.rev acc
    | _ -> fail_expected p "the end of the line"
  in
  items []

let parse_type p ~pub =
  expect p TYPE;
  let type_name = upper_ident p "a type name" in
  let type_params =
    if peek p = LT then (
      advance p;
      sep_list p ~close:GT (fun p -> upper_ident p "a type parameter"))
    else []
  in
  expect p EQ;
  let tname = type_name.name in
  let type_body, type_ops =
    if peek p = INDENT then (
      (* the body indented under `type X =`, and its members on the lines
         after it, at the same indentation *)
      advance p;
      let b = parse_type_body p in
      let members =
        if peek p = NEWLINE then (
          advance p;
          parse_members p ~tname)
        else []
      in
      expect p DEDENT;
      (b, members))
    else
      let b = parse_type_body p in
      if peek p = INDENT then (
        (* the members indented under a one-line body *)
        advance p;
        let members = parse_members p ~tname in
        expect p DEDENT;
        (b, members))
      else (b, [])
  in
  { type_pub = pub; type_name; type_params; type_body; type_ops }

let parse_item p =
  p.node <- 0;
  let pub = peek p = PUB in
  if pub then advance p;
  match peek p with
  | FN -> Fn (parse_fn p ~pub)
  | TYPE -> Type (parse_type p ~pub)
  | IMPORT when pub ->
      Diag.error (loc p)
        ~help:"remove the `pub`: a module can't pass on what it imports"
        "an import can't be `pub`"
  | IMPORT -> Import (parse_import p)
  | _ ->
      Diag.error (loc p)
        ~help:
          "only imports, and function and type definitions, can appear at the \
           top level (for now)"
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
    (* a `uses` there is the rest of a signature that wasn't indented *)
    && not (List.mem (peek p) [ NEWLINE; INDENT; DEDENT; USES ])
  in
  if p.i = start || not (at_item p) then (
    advance p;
    while peek p <> EOF && not (at_item p) do
      advance p
    done)

let parse_program sink toks =
  let p = { toks; i = 0; node = 0; sink } in
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
      | Import i as item ->
          (* a reader finds everything a module uses at its top *)
          if List.exists (function Import _ -> false | _ -> true) acc then
            Diag.report sink
              (Diag.make i.iloc
                 ~help:"move it above the file's first function or type"
                 "imports go at the top of the file");
          loop (item :: acc)
      | item -> loop (item :: acc)
      | exception Diag.Error d ->
          Diag.report sink d;
          skip_to_item p ~start;
          loop acc
  in
  loop []
