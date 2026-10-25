(* Parser: tokens -> AST, by recursive descent.

   Each grammar rule is one function. Precedence comes from which function
   calls which: `orelse` calls `||`, which calls `&&`, which calls `not`,
   which calls comparisons, which call additive, and so on down to primary
   expressions.

     program  := item { NEWLINE item } EOF       (imports come first)
     item     := import | ["pub"] (fn_def | type_def | dep_def)
     import   := "import" IDENT { "/" IDENT } ["." "{" UIDENT, ... "}"]
                 ["as" IDENT]
     fn_def   := "fn" IDENT ["<" UIDENT, ... ">"] "(" param, ... ")"
                 ["->" type] [errors] [uses] "=" body
                                                   (`!` and `uses` may start
                                                    the next line, indented)
     errors   := "!" error { "|" error } ["|" row]
              |  "!" row                          (in a type's body, each
                                                    `|` may start a line)
     uses     := "uses" tyname { "," tyname } ["," row]
              |  "uses" row                       (in a type, a `,` goes on
                                                    only to a dependency or a
                                                    row)
     row      := ".." IDENT                       (a named row: `..e`, `..d`)
     error    := UIDENT ["(" payload, ... ")"]      (a tag)
              |  [IDENT "."] UIDENT                (a named error set)
     payload  := [IDENT ":"] type
     param    := ["inout"] (IDENT | "self") [":" type]
     type_def := "type" UIDENT ["<" UIDENT, ... ">"] "=" type_body [members]
     members  := INDENT op { NEWLINE op } DEDENT
                                                   (or, after an indented
                                                    body, on the lines after
                                                    it: the first line not
                                                    starting with `|` ends
                                                    a sum type's variants)
     dep_def  := "dep" UIDENT "=" INDENT dep_op { NEWLINE dep_op }
                 [NEWLINE op { NEWLINE op }] DEDENT
                                                   (its operations, then its
                                                    members)
     dep_op   := IDENT ":" "fn" fn_type
     op       := ["pub"] fn_def
              |  ["pub"] "let" IDENT [":" type] "=" body
              |  IDENT ["(" param, ... ")"] "=>" body
                                                   (an operator: parsed, but
                                                    reported until stage 9)
     type_body:= "{" field, ... "}"                       (a record)
              |  "opaque" type                           (a type of its own)
              |  errors                                  (a named error set)
              |  ["|"] ctor { "|" ctor }                  (a sum type; may be
                                                            indented, one per line)
     ctor     := UIDENT ["(" field, ... ")"]
     field    := IDENT ":" type
     type     := tyname ["<" type, ... ">"]
              |  tyname uses               (an implementation, and what it
                                             needs; not right after `->`)
              |  "fn" "(" ["inout"] [IDENT ":"] type, ... ")" ["->" type]
                 [errors] [uses]           (the innermost function type's)
              |  "(" type ")"
              |  errors                     (an error set: only `Result`'s
                                             second type argument, resolve.ml)
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
     expr     := or ["orelse" expr]                 (`a orelse b orelse c`
                                                     is `a orelse (b orelse c)`)
     or       := and { "||" and }
     and      := not { "&&" not }
     not      := "not" not | cmp                    (`not a == b` is
                                                     `not (a == b)`)
     cmp      := add [cmp_op add]                   (comparisons don't chain)
     add      := mul { ("+" | "-") mul }
     mul      := unary { ("*" | "/" | "%") unary }
     unary    := "-" unary | "&" unary | postfix
              |  "try" expr | "attempt" expr        (everything to its right)
     postfix  := primary { "." IDENT | "[" expr "]"
                         | "(" expr, ... ")" [lambda] }
                                                    (a trailing lambda is
                                                     the call's last argument)
     primary  := INT | STR | "true" | "false" | "(" ")" | IDENT | "self"
              |  lambda
              |  ctor_ref ["(" con_args ")"] | tyname "{" field_inits "}"
              |  tyname "." IDENT               (a member: `Stack.of`)
              |  "{" field_inits "}" | "(" expr ")" | "[" expr, ... "]"
              |  "if" expr "then" body [[NEWLINE] "else" body]
              |  "with" expr, ... "in" body
              |  "match" expr INDENT arm { NEWLINE arm } DEDENT
              |  "fail" UIDENT ["(" con_args ")"]
     arm      := (pattern | fails) ["if" expr] "=>" body
     fails    := fail_pat { "|" fail_pat }
     fail_pat := "fail" "_" | "fail" UIDENT ["(" pattern, ... ")"]
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
  | STR s -> Printf.sprintf "the string `%s`" (show_str s)
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

(* A name that must start with a lowercase letter: a function's or a
   handler's, which a capital would make look like a type's. *)
let lower_ident p what =
  let id = ident p in
  if is_upper id.name then
    Diag.error id.loc
      ~notes:
        [ "a capitalized name is a type's, a dependency's or a constructor's" ]
      ~help:(Printf.sprintf "write `%s`" (String.uncapitalize_ascii id.name))
      (Printf.sprintf "%s must start with a lowercase letter" what);
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
let parse_tyname ?(what = "a type name") p =
  match (peek p, peek2 p) with
  | IDENT m, DOT when not (is_upper m) ->
      let alias = ident p in
      advance p;
      { tmod = Some alias; tid = upper_ident p what }
  | _ -> { tmod = None; tid = upper_ident p what }

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

(* A function type's `! ...` and `uses ...` belong to the innermost
   function type they can: in `fn f() -> fn() ! Bad`, the `fn()` returned
   can fail with `Bad`. After `->`, a `uses` is the function's, never what
   an implementation it returns needs, which is written in parentheses,
   `-> (Clock uses Os)`; [uses] says whether a type here can take one. *)
let rec parse_ty ?(uses = true) p : ty =
  match peek p with
  | LPAREN ->
      advance p;
      let t = parse_ty p in
      expect p RPAREN;
      t
  | FN ->
      let start = loc p in
      advance p;
      expect p LPAREN;
      let params = sep_list p ~close:RPAREN parse_fn_ty_param in
      let ret =
        if peek p = ARROW then (
          advance p;
          Some (parse_ty ~uses:false p))
        else None
      in
      let errs = if peek p = BANG then Some (parse_errors p) else None in
      let used = if peek p = USES then Some (parse_uses p) else None in
      TyFn (params, ret, errs, used, Loc.span start (last_loc p))
  | BANG when peek2 p = GT || peek2 p = COMMA ->
      (* `Result<Int, !>`: an empty set, a [Result] that can't be [Err] *)
      let l = loc p in
      advance p;
      TyErrors { errs = []; etail = None; eloc = l }
  | BANG -> TyErrors (parse_errors p)
  | _ ->
      let start = loc p in
      let name = parse_tyname p in
      let args =
        if peek p = LT then (
          advance p;
          sep_list p ~close:GT parse_ty)
        else []
      in
      if uses && peek p = USES then (
        (* an implementation, and what it needs: `Clock uses Os` *)
        if args <> [] then
          Diag.error (loc p)
            ~help:"only a dependency's type is followed by `uses`"
            (Printf.sprintf
               "`%s` takes type arguments, so it isn't a dependency, and needs \
                nothing"
               (show_tyname name));
        let u = parse_uses p in
        TyImpl (name, Some u, Loc.span start (last_loc p)))
      else TyName (name, args)

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

(* What a function type or an implementation uses, after `uses`: `Clock,
   store.Users`, and last, a named row, `..d`. [greedy] says a comma always
   goes on with another dependency, as in a signature, where `=` ends the
   list; inside a type, one goes on only if what's after the comma can be
   one, so `fn(f: fn() uses Clock, n: Int)` has two parameters. *)
and parse_uses ?(greedy = false) p : uses =
  let start = loc p in
  expect p USES;
  let continues () =
    match (peek2 p, peek3 p) with
    | DOTDOT, _ -> true
    | IDENT n, _ when is_upper n -> true
    | IDENT _, DOT -> true
    | _ -> false
  in
  let rec items acc =
    if peek p = DOTDOT then (
      let (tail : ident) = parse_row_name p in
      if peek p = COMMA && continues () then
        Diag.error (loc p) ~help:"move it to the end"
          (Printf.sprintf "`..%s` stands for the rest, so it comes last"
             tail.name);
      (List.rev acc, Some tail))
    else
      (* `store.Users`, or bare `Users`: after a module's alias, the error
         for a lowercase name points at the name *)
      let d = parse_tyname ~what:"a dependency's name" p in
      if peek p = COMMA && (greedy || continues ()) then (
        advance p;
        items (d :: acc))
      else (List.rev (d :: acc), None)
  in
  let deps, dtail = items [] in
  { deps; dtail; uloc = Loc.span start (last_loc p) }

(* A named row, `..d`: whatever the closure or implementation it's written
   on fails with or uses, the same wherever the signature names it. *)
and parse_row_name p =
  expect p DOTDOT;
  match peek p with
  | IDENT n when not (is_upper n) -> ident p
  | IDENT n ->
      Diag.error (loc p)
        ~help:(Printf.sprintf "write `..%s`" (String.uncapitalize_ascii n))
        "a named row's name starts with a lowercase letter"
  | _ -> fail_expected p "a row's name, like `..d`"

(* An error set, `! Short(by: Money) | Frozen | Refusal`, which can end in
   a named row, `! Bad | ..e`. With [lines], as in a named set's body
   indented under `type X =`, each `|` may start its own line, like a sum
   type's. *)
and parse_errors ?(lines = false) p : errors =
  let start = loc p in
  expect p BANG;
  let error p =
    match peek p with
    | IDENT _ when at_module_type p -> Set (parse_tyname p)
    | IDENT _ ->
        let tag = upper_ident p "an error tag" in
        if peek p = LPAREN then (
          let paren = loc p in
          advance p;
          let payload = sep_list p ~close:RPAREN parse_payload in
          if payload = [] then
            Diag.error
              (Loc.span paren (last_loc p))
              ~help:(Printf.sprintf "write `%s`" tag.name)
              "a tag without a payload is written without parentheses";
          Tag (tag, payload))
        else Tag (tag, [])
    | _ -> fail_expected p "an error tag"
  in
  let rec loop acc =
    if peek p = DOTDOT then (
      let (tail : ident) = parse_row_name p in
      if peek p = PIPE then
        Diag.error (loc p) ~help:"move it to the end"
          (Printf.sprintf "`..%s` stands for the rest, so it comes last"
             tail.name);
      (List.rev acc, Some tail))
    else
      let e = error p in
      if lines && peek p = NEWLINE && peek2 p = PIPE then advance p;
      if peek p = PIPE then (
        advance p;
        loop (e :: acc))
      else (List.rev (e :: acc), None)
  in
  let errs, etail = loop [] in
  { errs; etail; eloc = Loc.span start (last_loc p) }

(* A payload's field, named for documentation or not: `by: Money`, or
   `Money`. *)
and parse_payload p =
  match (peek p, peek2 p) with
  | IDENT name, COLON when not (is_upper name) ->
      let n = ident p in
      advance p;
      { payload_name = Some n; payload_ty = parse_ty p }
  | _ -> { payload_name = None; payload_ty = parse_ty p }

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
  | BANG -> Errors (parse_errors ~lines:true p)
  | _ -> Ctors (parse_ctors p)

(* ---- patterns ---- *)

(* A pattern that started at [start], with the next node id. *)
let mk_pattern p start pkind =
  p.node <- p.node + 1;
  { pkind; ploc = Loc.span start (last_loc p); pnode = p.node }

let rec parse_pattern p : pattern =
  let start = loc p in
  let finish = mk_pattern p start in
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
  | FAIL ->
      Diag.error (loc p)
        ~help:"match the error in an arm of its own, `fail Tag(...) => ...`"
        "a `fail` pattern can't be inside another pattern"
  | _ -> fail_expected p "a pattern"

(* An arm's pattern: an ordinary one, or `fail` patterns, which match an
   error (errors.md, "Handling: `match`"), one or several combined with
   `|`. *)
let parse_arm_pattern p : pattern =
  let start = loc p in
  let fail_pattern p =
    let finish = mk_pattern p (loc p) in
    expect p FAIL;
    match peek p with
    | IDENT "_" ->
        advance p;
        finish PFail_any
    | IDENT name when is_upper name ->
        let tag = ident p in
        if peek p = LPAREN then (
          advance p;
          let args = sep_list p ~close:RPAREN parse_pattern in
          finish (PFail (tag, args)))
        else finish (PFail (tag, []))
    | IDENT name ->
        (* an error is never a value (errors.md, "Keeping an error") *)
        Diag.error (loc p)
          ~help:
            (Printf.sprintf
               "match each tag, like `fail NotFound`, or keep the whole \
                outcome as a value with `attempt`, and match `Err(%s)`"
               name)
          "a `fail` pattern can't bind the whole error to a name"
    | _ -> fail_expected p "an error tag, or `_`"
  in
  if peek p <> FAIL then parse_pattern p
  else
    let first = fail_pattern p in
    let rec rest acc =
      if peek p = PIPE then (
        advance p;
        if peek p <> FAIL then
          Diag.error (loc p)
            ~help:"start it with `fail` too, or give it an arm of its own"
            (Printf.sprintf
               "this pattern is combined with `fail` patterns, so it has to be \
                one, but it's %s"
               (describe (peek p)));
        rest (fail_pattern p :: acc))
      else List.rev acc
    in
    match rest [ first ] with
    | [ only ] -> only
    | alternatives -> mk_pattern p start (POr alternatives)

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
  let lhs = parse_or p in
  if peek p = ORELSE then (
    advance p;
    let rhs = parse_expr p in
    mk (Binop (Orelse, lhs, rhs)) start p)
  else lhs

and parse_or p = left_assoc [ (PIPEPIPE, Or) ] parse_and p
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
      if peek p = NOT then
        (* `not` binds looser than a comparison: `not a == b` is
           `not (a == b)`, so one can't start a comparison's right side *)
        Diag.error (loc p) ~help:"put it in parentheses: `a == (not b)`"
          "`not` can't start the right side of a comparison";
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
  | (TRY | ATTEMPT) as kw ->
      (* `try` covers every call to its right (errors.md, "Marking"), so it
         takes the whole expression there: `try a() + b()` is
         `try (a() + b())` *)
      let start = loc p in
      advance p;
      let e = parse_expr p in
      mk (if kw = TRY then Try e else Attempt e) start p
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
  | STR s ->
      advance p;
      mk (Str s) start p
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
  | WITH -> parse_with p
  | FN -> parse_lambda p
  | FAIL -> (
      advance p;
      match peek p with
      | IDENT name when is_upper name ->
          let tag = ident p in
          let args =
            if peek p = LPAREN then (
              advance p;
              sep_list p ~close:RPAREN parse_con_arg)
            else []
          in
          mk (Fail (tag, args)) start p
      | IDENT _ ->
          Diag.error (loc p)
            ~help:
              "write a tag, like `fail NotFound`; to fail with the error a \
               `Result` holds, write `try` before it"
            "`fail` takes an error tag, which starts with a capital letter"
      | _ -> fail_expected p "an error tag")
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

(* `with a, b in body`: [a] installed (or wrapped) around `with b in body`,
   so the first item is the outermost. Each [With] numbers the lambda its
   body becomes if its item is a wrapper (ast.ml). *)
and parse_with p =
  let start = loc p in
  expect p WITH;
  let rec items acc =
    let item = parse_expr p in
    if peek p = COMMA then (
      advance p;
      items (item :: acc))
    else List.rev (item :: acc)
  in
  let items = items [] in
  if peek p <> IN then
    Diag.error (loc p)
      ~help:
        "write what it installs, then `in`, then the code it's installed around"
      (Printf.sprintf
         "expected `,` or `in` after what `with` installs, found %s"
         (describe (peek p)));
  advance p;
  let body = parse_body p in
  let rec nest ~start = function
    | [] -> body
    | (item : expr) :: rest ->
        let body = nest ~start:item.loc rest in
        p.node <- p.node + 1;
        let lam = p.node in
        node p (With { item; body; lam }) (Loc.span start body.loc)
  in
  nest ~start items

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
  let arm_pat = parse_arm_pattern p in
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
  let name = lower_ident p "a function's name" in
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
      Some (parse_ty ~uses:false p))
    else None
  in
  let errors =
    if peek p = BANG then Some (parse_errors p)
    else if peek p = NEWLINE && peek2 p = BANG then
      (* as for `uses` below: only an indented line continues *)
      Diag.error ~help:"indent it, so it continues the signature"
        (snd p.toks.(p.i + 1))
        "an error set on a line of its own has to be indented"
    else None
  in
  let uses =
    if peek p = USES then Some (parse_uses ~greedy:true p)
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
    errors;
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
let parse_op ?(dep = false) p ~tname =
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
              errors = None;
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
        | IDENT _ when peek2 p = COLON && dep ->
            Some "a dependency's operations come first, before its members"
        | IDENT _ when peek2 p = COLON ->
            Some "a record's fields go in its braces, `{ ... }`"
        | _ -> None
      in
      Diag.error ?help (loc p)
        (Printf.sprintf "expected %s, found %s" what (describe tok))

(* A type's members, each on its own line, up to the end of the block
   they're in, which is left for the caller to close. *)
let parse_members ?dep p ~tname =
  let rec items acc =
    let acc =
      match parse_op ?dep p ~tname with Some o -> o :: acc | None -> acc
    in
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
  (match (type_body, type_params, type_ops) with
  | Errors _, t :: _, _ ->
      Diag.error t.loc ~help:"remove the type parameters"
        "a named error set can't take type parameters"
  | Errors _, [], o :: _ ->
      Diag.error o.op_fn.name.loc
        ~help:"move it under a type, or to the top level"
        (Printf.sprintf
           "`%s` is an error set, not a type of values, so it has no members"
           tname)
  | _ -> ());
  { type_pub = pub; type_name; type_params; type_body; type_ops }

(* A dependency (deps.md, "Declaring one"): its operations, indented under
   it, then its members, as a sum type lists its variants first.

     pub dep Clock =
       now: fn() -> Time
       sleep: fn(d: Duration)

       pub fn frozen(at: Time) -> Clock = ... *)
let parse_dep p ~pub =
  expect p DEP;
  let type_name = upper_ident p "a dependency's name" in
  let tname = type_name.name in
  if peek p = LT then
    Diag.error (loc p) ~help:"remove them"
      "a dependency can't take type parameters";
  expect p EQ;
  if peek p <> INDENT then
    Diag.error (loc p)
      ~help:
        "put each of its operations on a line of its own, indented under it, \
         like `now: fn() -> Time`"
      (Printf.sprintf "expected the operations of `%s`, found %s" tname
         (describe (peek p)));
  advance p;
  let at_op p =
    match (peek p, peek2 p) with IDENT _, COLON -> true | _ -> false
  in
  let op p =
    let field_name = ident p in
    expect p COLON;
    if peek p <> FN then
      Diag.error (loc p)
        ~help:
          (Printf.sprintf
             "write its type as a function's, like `%s: fn() -> %s`"
             field_name.name
             (match peek p with IDENT t when is_upper t -> t | _ -> "Int"))
        (Printf.sprintf
           "`%s` is an operation, so its type is a function's, but this is %s"
           field_name.name
           (describe (peek p)));
    { field_name; field_ty = parse_ty p }
  in
  if not (at_op p) then
    Diag.error (loc p)
      ~help:
        "list its operations first, like `now: fn() -> Time`, then its members"
      (Printf.sprintf "`%s` has no operations: a dependency lists them first"
         tname);
  let rec ops acc =
    let acc = op p :: acc in
    if
      peek p = NEWLINE
      &&
      (advance p;
       at_op p)
    then ops acc
    else List.rev acc
  in
  let ops = ops [] in
  (* the loop stopped after the line break before a member, if there is one *)
  let members =
    if peek p = DEDENT then [] else parse_members ~dep:true p ~tname
  in
  expect p DEDENT;
  {
    type_pub = pub;
    type_name;
    type_params = [];
    type_body = Dep ops;
    type_ops = members;
  }

(* A handler (deps.md, "Implementations"): a function of its parameters
   that describes a stateful implementation of the dependencies after
   `for`. Its body, indented under it, is its state, `var`s and `let`s,
   then an arm for each operation:

     handler counting_rates(rate: Int) for Rates, RateCalls =
       var calls = 0
       usd_to(_) =>
         calls += 1
         rate
       count() => calls

   Each arm is kept as a lambda (ast.ml, [Handler]). *)
let parse_handler p ~pub =
  let start = loc p in
  expect p HANDLER;
  let name = lower_ident p "a handler's name" in
  if peek p = LT then
    Diag.error (loc p) ~help:"remove them"
      ~notes:
        [
          "a handler's operations have the types its dependencies declare, \
           which can't take type parameters either";
        ]
      "a handler can't take type parameters";
  if peek p <> LPAREN then
    Diag.error (loc p)
      ~help:
        (Printf.sprintf
           "write its parameters, `handler %s() for ...`, even if it has none"
           name.name)
      (Printf.sprintf "expected `(` after the handler's name, found %s"
         (describe (peek p)));
  advance p;
  let params = sep_list p ~close:RPAREN parse_param in
  if peek p <> FOR then
    Diag.error (loc p)
      ~help:
        (Printf.sprintf "say what it implements: `handler %s(...) for Clock =`"
           name.name)
      (Printf.sprintf
         "expected `for` and the dependencies it implements, found %s"
         (describe (peek p)));
  advance p;
  let rec deps acc =
    let d = parse_tyname ~what:"a dependency's name" p in
    if peek p = COMMA then (
      advance p;
      deps (d :: acc))
    else List.rev (d :: acc)
  in
  let deps = deps [] in
  let needs =
    if peek p = USES then Some (parse_uses ~greedy:true p)
    else if peek p = NEWLINE && peek2 p = USES then
      Diag.error ~help:"indent it, so it continues the signature"
        (snd p.toks.(p.i + 1))
        "`uses` on a line of its own has to be indented"
    else None
  in
  let body_start = loc p in
  expect p EQ;
  if peek p <> INDENT then
    Diag.error (loc p)
      ~help:
        "put its state and its operations on lines of their own, indented \
         under it, like `now() => Time.epoch`"
      (Printf.sprintf "expected the body of the handler `%s`, found %s"
         name.name
         (describe (peek p)));
  advance p;
  (* its state, then its arms, each line ended by a line break or the end
     of the block *)
  let next_line () =
    match peek p with
    | NEWLINE ->
        advance p;
        true
    | DEDENT ->
        advance p;
        false
    | _ -> fail_expected p "the end of the line"
  in
  let rec state acc =
    match peek p with
    | LET | VAR ->
        let s = parse_stmt p in
        if next_line () then state (s :: acc) else (List.rev (s :: acc), false)
    | _ -> (List.rev acc, true)
  in
  let state, more = state [] in
  let arm p =
    match (peek p, peek2 p) with
    | IDENT _, LPAREN ->
        let arm_start = loc p in
        let arm_name = ident p in
        advance p;
        let params = sep_list p ~close:RPAREN parse_param in
        expect p FATARROW;
        let body = parse_body p in
        {
          arm_op = Bare arm_name.name;
          arm_name;
          arm_impl = mk (Lambda (params, body)) arm_start p;
        }
    | (LET | VAR), _ ->
        Diag.error (loc p) ~help:"move it above the handler's first operation"
          "a handler's state comes first, before its operations"
    | IDENT n, _ ->
        Diag.error (loc p)
          ~help:(Printf.sprintf "write it as `%s(...) => ...`" n)
          (Printf.sprintf
             "expected an operation's implementation, like `%s(...) => ...`, \
              found %s"
             n
             (describe (peek2 p)))
    | _ -> fail_expected p "an operation's implementation, like `now() => ...`"
  in
  let rec arms acc =
    let a = arm p in
    if next_line () then arms (a :: acc) else List.rev (a :: acc)
  in
  let arms = if more then arms [] else [] in
  let body =
    node p
      (Handler { deps; needs; state; arms })
      (Loc.span body_start (last_loc p))
  in
  {
    pub;
    name;
    tparams = [];
    params;
    ret = None;
    errors = None;
    uses = None;
    body;
    loc = Loc.span start (last_loc p);
  }

let parse_item p =
  p.node <- 0;
  let pub = peek p = PUB in
  if pub then advance p;
  match peek p with
  | FN -> Fn (parse_fn p ~pub)
  | TYPE -> Type (parse_type p ~pub)
  | DEP -> Type (parse_dep p ~pub)
  | HANDLER -> Fn (parse_handler p ~pub)
  | IMPORT when pub ->
      Diag.error (loc p)
        ~help:"remove the `pub`: a module can't pass on what it imports"
        "an import can't be `pub`"
  | IMPORT -> Import (parse_import p)
  | _ ->
      Diag.error (loc p)
        ~help:
          "only imports, and function, type, dependency and handler \
           definitions, can appear at the top level (for now)"
        (Printf.sprintf "expected `fn`, `type`, `dep` or `handler`, found %s"
           (describe (peek p)))

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
    (* a `uses` or `!` there is the rest of a signature that wasn't
       indented *)
    && not (List.mem (peek p) [ NEWLINE; INDENT; DEDENT; USES; BANG ])
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
