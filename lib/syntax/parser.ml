(* Parser: tokens -> AST, by recursive descent.

   Each grammar rule is one function. Precedence comes from which function
   calls which: `orelse` calls `||`, which calls `&&`, which calls `not`,
   which calls comparisons, which call additive, and so on down to primary
   expressions.

     program  := item { NEWLINE item } EOF       (imports come first)
     item     := import | ["pub"] (fn_def | type_def | dep_def | handler
                                   | group | wiring | service) | test | run
     import   := "import" IDENT { "/" IDENT } ["." "{" UIDENT, ... "}"]
                 ["as" IDENT]
     fn_def   := ["gen"] "fn" IDENT ["<" UIDENT, ... ">"] "(" param, ... ")"
                 ["->" type] [errors] [uses] "=" body
                                                   (`!` and `uses` may start
                                                    the next line, indented)
     errors   := "!" error { "|" error } ["|" row]
              |  "!" row                          (in a type's body, each
                                                    `|` may start a line)
     uses     := "uses" tyname { "," tyname } ["," row]
              |  "uses" row                       (in a type, a `,` goes on
                                                    only to a dependency or a
                                                    row; in a type argument,
                                                    only to a row)
     row      := ".." IDENT                       (a named row: `..e`, `..d`)
     error    := UIDENT ["(" payload, ... ")"]      (a tag)
              |  [IDENT "."] UIDENT                (a named error set)
     payload  := [IDENT ":"] type
     param    := ["inout"] (IDENT | "self") [":" type]
     lparam   := ["&"] IDENT [":" type]             (`&`: one the block
                                                     changes)
              |  ("(" | "{" | UIDENT) pattern [":" type]
                                                    (taken apart, by a pattern
                                                     Exhaust checks always
                                                     matches)
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
     handler  := "handler" IDENT "(" param, ... ")"
                 ("for" tyname, ... | "over" tyname { "&" tyname })
                 [errors] [uses] "=" INDENT { stmt NEWLINE }
                 arm_impl { NEWLINE arm_impl } DEDENT
                                                   (its state, `let`, `var`
                                                    and `finally` lines,
                                                    then its arms)
     arm_impl := IDENT "(" param, ... ")" "=>" body
     test     := "test" STR [uses] "=" body
     group    := "group" IDENT "(" param, ... ")" ["with" witem, ...] "="
                 INDENT test { NEWLINE test } DEDENT
     run      := "group" STR "=" expr               (a call of a group)
     wiring   := "wiring" IDENT ["(" param, ... ")"] "provides" tyname,
                 ... [uses] [errors] "=" witem, ...
                                                   (`wiring` and `provides`
                                                    are words only here; the
                                                    items may go on the line
                                                    after the `=`, indented,
                                                    and on lines after a `,`)
     service  := "service" UIDENT "(" param, ... ")" [uses] [errors] "="
                 INDENT { stmt NEWLINE } ["pub"] fn_def
                 { NEWLINE ["pub"] fn_def } DEDENT
                                                   (its state first, `let`,
                                                    `var` and `finally` lines,
                                                    as a handler's)
                                                   (`service` is a word only
                                                    here; its operations are
                                                    its `pub fn`s)
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
     ctor     := UIDENT                                  (no fields)
              |  UIDENT "(" [IDENT ":"] type ")"         (one field, positional;
                                                           a name documents it)
              |  UIDENT "{" field, ... "}"               (by name)
     field    := IDENT ":" type
     type     := tyname ["<" type, ... ">"]
              |  tyname "." UIDENT ["<" type, ... ">"]
                                            (a variant type, `Order.Placed`;
                                             the arguments are its sum's,
                                             `Tree.Node<Int>`)
              |  ["over"] tyname { "&" tyname } [errors] [uses]
                                            (an implementation, what
                                             installing it can fail with and
                                             what it needs; not right after
                                             `->`)
              |  "fn" "(" ["&"] [IDENT ":"] type, ... ")" ["->" type]
                 [errors] [uses]           (the innermost function type's)
              |  "(" type ")"
              |  "(" type "," type ["," type] ")"   (a tuple's)
              |  errors                     (an error set: only `Result`'s
                                             second type argument, resolve.ml)
     tyname   := [IDENT "."] UIDENT                (`stripe.Client`: another
                                                    module's, after its alias)
     ctor_ref := [tyname "."] UIDENT               (`Red`, `Light.Red`,
                                                    `billing.Plan.Free`)

     body     := INDENT block | line
     block    := stmt { NEWLINE stmt } DEDENT       (last stmt is the value)
     stmt     := ("let" | "var") IDENT [":" type] "=" body
              |  "let" pattern "=" body             (one that always matches:
                                                     Exhaust checks)
              |  "let" pattern "=" line "else" body (one that might not; the
                                                     `else` leaves, Resolve)
              |  "for" [IDENT ","] pattern "in"
                 (expr | expr ".." expr) INDENT block
                                                    (a range only here; the
                                                     IDENT before "," is
                                                     the index, `for i, x`)
              |  "while" expr INDENT block
              |  "finally" "(" param ")" "=>" body  (only in a handler's
                                                     state or an arm, which
                                                     resolve.ml checks)
              |  line
     line     := expr [("=" | "+=" | "-=" | "*=") body]
                                                    (an assignment's target
                                                     must be a place, mut.ml)
     expr     := pipe ["orelse" expr]               (`a orelse b orelse c`
                                                     is `a orelse (b orelse c)`)
     pipe     := or { "|>" step }                   (a chain, language.md §8:
                                                     its head one term, and
                                                     no operator after it)
     step     := ["try" | "attempt"] target ["(" arg, ... ")"] [lambda]
                                                    (a trailing lambda only in
                                                     the last step)
     target   := IDENT | IDENT "." IDENT | tyname "." IDENT
                                                    (a function, `module.f`
                                                     or `Type.f`: Resolve
                                                     decides, and refuses a
                                                     field of a value)
     or       := and { "||" and }
     and      := not { "&&" not }
     not      := "not" not | cmp                    (`not a == b` is
                                                     `not (a == b)`)
     cmp      := add [cmp_op add]                   (comparisons don't chain)
     add      := mul { ("+" | "-") mul }
     mul      := unary { ("*" | "/" | "%") unary }
     unary    := "-" unary | "&" unary | postfix
              |  "try" expr                         (everything to its right,
                                                     up to a `|>`)
              |  "attempt" add                      (stops at a comparison)
              |  "assert" expr
              |  "release" postfix                  (a word only before a
                                                     name on its line: one
                                                     call, in a handler's arm)
     postfix  := primary { "." IDENT | "[" expr "]"
                         | "(" expr, ... ")" [lambda] | lambda }
                                                    (a trailing lambda is
                                                     the call's last argument;
                                                     alone, it's the only one)
     primary  := INT | STR | "true" | "false" | "(" ")" | IDENT | "self"
              |  "break" | "todo"                   (`todo`: any type; panics)
              |  lambda | "handler" lambda      (an inline handler)
              |  ctor_ref ["(" con_args ")"] | tyname "{" field_inits "}"
              |  tyname "{" ".." expr {"," finit} "}"   (an update: the rest
                                                     from the value after `..`)
                                                    (a bare `Name { ... }` is a
                                                     record or a by-name
                                                     constructor: Resolve
                                                     decides)
              |  tyname "." UIDENT "{" [".." expr ","] finit, ... "}"
                                                    (`Shape.Rect { ... }`: a
                                                     by-name constructor)
              |  tyname "." IDENT               (a member: `Stack.of`)
              |  "{" field_inits "}" | "{" ".." expr {"," finit} "}"
              |  "(" expr ")" | "[" expr, ... "]"
              |  "(" expr "," expr ["," expr] ")"   (a tuple)
              |  "if" expr "then" body [[NEWLINE] "else" body]
              |  "with" witem, ... "in" body
     witem    := expr { "over" expr } ["over" tyname { "&" tyname }]
              |  "match" expr INDENT arm { NEWLINE arm } DEDENT
              |  "fail" UIDENT ["(" con_args ")"]
     arm      := (pattern | fails) ["if" expr] "=>" body
     fails    := fail_pat { "|" fail_pat }   (never with `as`)
     fail_pat := "fail" "_" | "fail" UIDENT ["(" pattern, ... ")"]
     lambda   := "fn" "(" lparam, ... ")" "=>" body
                                                   (inside brackets too, the
                                                    lexer opens its block)
     pattern  := alt ["as" IDENT]                  (`as` binds looser than
                                                    `|`: the whole)
     alt      := single { "|" single }
     single   := "_" | IDENT | INT | "-" INT | "true" | "false"
              |  ctor_ref ["(" pattern, ... ")"]   (never `..` in it)
              |  "(" pattern ")"                   (grouping)
              |  "(" pattern "," pattern ["," pattern] ")"
              |  [tyname] "{" fpats "}"            (a record, of the type
                                                    named or matched, or a
                                                    by-name constructor:
                                                    Resolve decides)
              |  tyname "." UIDENT "{" fpats "}"   (a by-name constructor)
     fpats    := fpat {"," fpat} ["," ".."] | ".." | (nothing)
     fpat     := IDENT [":" pattern]               (alone, it binds IDENT)
     finit    := IDENT [":" expr]                  (alone, `IDENT: IDENT`)

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
  mutable tags : string list;
      (** the parameters of the function being parsed written of type `Tags`,
          which `fail on` can name *)
  mutable op_defaults : (int * string * (literal * Loc.t * int)) list ref option;
      (** while an operation's type is parsed, in its dependency's
          declaration, where the defaults of its parameters go ([parse_ty]) *)
  mutable op_params : string list ref option;
      (** and where their names go, as [op_defaults] *)
}

let peek p = fst p.toks.(p.i)
let peek2 p = fst p.toks.(min (p.i + 1) (Array.length p.toks - 1))
let peek3 p = fst p.toks.(min (p.i + 2) (Array.length p.toks - 1))

(* The token [k] after the next one: [peek_at p 1] is [peek2 p]. *)
let peek_at p k = fst p.toks.(min (p.i + k) (Array.length p.toks - 1))
let loc p = snd p.toks.(p.i)
let loc2 p = snd p.toks.(min (p.i + 1) (Array.length p.toks - 1))
let advance p = if p.i < Array.length p.toks - 1 then p.i <- p.i + 1

(* The tokens from [i] to [j], as they're written: a space between two
   only where the source has one. *)
let spelled p i j =
  let b = Buffer.create 32 in
  for k = i to j do
    let t, (l : Loc.t) = p.toks.(k) in
    (if k > i then
       let (pl : Loc.t) = snd p.toks.(k - 1) in
       if pl.stop.line <> l.start.line || pl.stop.col < l.start.col then
         Buffer.add_char b ' ');
    Buffer.add_string b (Token.to_string t)
  done;
  Buffer.contents b

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

(* A node of its own for the method an operator uses (ast.ml, [Binop]). *)
let onode p =
  p.node <- p.node + 1;
  p.node

let describe = function
  | INT n -> Printf.sprintf "the number `%Ld`" n
  | FLOAT f -> Printf.sprintf "the number `%s`" (Token.show_float f)
  | STR s -> Printf.sprintf "the string `%s`" (show_str s)
  | IDENT s -> Printf.sprintf "`%s`" s
  | NEWLINE -> "a new line"
  | INDENT -> "an indented block"
  | DEDENT -> "the end of the block"
  | EOF -> "the end of the file"
  | tok -> Printf.sprintf "`%s`" (Token.to_string tok)

(* The number 2^63, which the lexer reads as [Int64.min_int]: it's an
   `Int` only as `-9223372036854775808`, the smallest one, which [Neg]
   can't make, since `-` of 2^63 is past the largest. Anywhere else it's
   too big. *)
let too_big p =
  Diag.error (loc p) ~help:"the smallest `Int` is `-9223372036854775808`"
    "this number is too big to fit in an `Int`"

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
  | YIELD ->
      (* `Async.yield()` and its operation's declaration keep their name. *)
      let l = loc p in
      advance p;
      { name = "yield"; loc = l }
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

(* A tuple has two parts or three (operators.md, "Tuples"): [loc] is
   where one with [n] is written, and [what] says whether it's a value, a
   type or a pattern. *)
let tuple_size loc n =
  if n < 2 then
    Diag.error loc ~help:"write the value on its own, without a `,`"
      "a tuple has two parts or three, but this has one"
  else if n > 3 then
    Diag.error loc
      ~help:
        "use a record, which names its parts: `type T = { a: A, b: B, ... }`"
      (Printf.sprintf "a tuple has two parts or three, but this has %d" n)

(* ---- types ---- *)

(* A type's name: `Plan`, or `stripe.Client`, with its module's alias in
   front. *)
let parse_tyname ?(what = "a type name") p =
  match (peek p, peek2 p) with
  | IDENT m, DOT when not (is_upper m) ->
      let alias = ident p in
      advance p;
      (match (peek p, peek2 p, peek3 p) with
      | IDENT g, DOT, IDENT "Cursor" when not (is_upper g) ->
          (* `walks.walk.Cursor`: the type generated for another module's
             generator, with only the module in [tmod]. *)
          let name = ident p in
          advance p;
          let cursor = ident p in
          {
            tmod = Some alias;
            tid = { name = name.name ^ ".Cursor"; loc = Loc.span name.loc cursor.loc };
          }
      | _ -> { tmod = Some alias; tid = upper_ident p what })
  | _ -> { tmod = None; tid = upper_ident p what }

(* Is the next thing a type's name with a module in front, `billing.Plan`,
   rather than a variable or a field? *)
let at_module_type p =
  match (peek p, peek2 p, peek3 p) with
  | IDENT m, DOT, IDENT t -> (not (is_upper m)) && is_upper t
  | _ -> false

(* [c], a constructor written after its type, `Doc.Call`, and if a third
   name follows, `Doc.Call.Edit`, that one, a case of the type the first
   two name, a dependency's `D.Call`, whose name is `Doc.Call`
   (compiler.md, "Services stage", "`D.Call`"). *)
let calls_case p (c : ctor_ref) =
  match (c.qual, peek p, peek2 p) with
  | Some t, DOT, IDENT n when is_upper n ->
      advance p;
      let tid = { name = t.tid.name ^ "." ^ c.name.name; loc = Loc.span t.tid.loc c.name.loc } in
      { qual = Some { t with tid }; name = upper_ident p "a constructor name" }
  | _ -> c

(* A constructor: `Red`, or after its type, `Light.Red` or
   `billing.Plan.Free`, or a case of a dependency's calls,
   `Doc.Call.Edit`. *)
let parse_ctor_ref p : ctor_ref =
  if at_module_type p then (
    let t = parse_tyname p in
    expect p DOT;
    calls_case p { qual = Some t; name = upper_ident p "a constructor name" })
  else
    let first = upper_ident p "a constructor name" in
    if peek p = DOT then (
      advance p;
      calls_case p
        {
          qual = Some { tmod = None; tid = first };
          name = upper_ident p "a constructor name";
        })
    else { qual = None; name = first }

(* A default, after its `=`: a literal, a negative number among them;
   or, unless it's a field's, [~field], a variant written bare, `Tree` or
   `Kill.Tree`, with no `(` or `{` after it (compiler.md, "Services stage",
   "The grammar"), whose sum Resolve finds from the parameter's type. Its
   place, and a node of its own, at which inference checks its type. *)
let parse_default ?(field = false) p =
  let at = loc p in
  let neg = peek p = MINUS in
  if neg then advance p;
  let lit =
    match (peek p, neg) with
    | INT n, _ when n <> Int64.min_int ->
        advance p;
        Some (LInt (if neg then Int64.neg n else n))
    | FLOAT f, _ ->
        advance p;
        Some (LFloat (if neg then -.f else f))
    | TRUE, false ->
        advance p;
        Some (LBool true)
    | FALSE, false ->
        advance p;
        Some (LBool false)
    | STR s, false ->
        advance p;
        Some (LStr s)
    | IDENT q, false when is_upper q && not field -> (
        let first = ident p in
        let cqual, cname =
          match (peek p, peek2 p) with
          | DOT, IDENT c when is_upper c ->
              advance p;
              (Some q, ident p)
          | _ -> (None, first)
        in
        match peek p with
        | LPAREN | LBRACE -> None
        | _ -> Some (LCtor { cqual; cname; csum = None }))
    | _ -> None
  in
  match lit with
  | Some l ->
      p.node <- p.node + 1;
      (l, Loc.span at (last_loc p), p.node)
  | None when field ->
      Diag.error at ~help:"give it where it's made instead"
        "a field's default is a literal: a number, a `Bool` or a string"
  | None ->
      Diag.error at ~help:"give it where it's called instead"
        "a parameter's default is a literal, or a variant written bare"

(* A function type's `! ...` and `uses ...` belong to the innermost
   function type they can: in `fn f() -> fn() ! Bad`, the `fn()` returned
   can fail with `Bad`. After `->`, a `uses` is the function's, never what
   an implementation it returns needs, which is written in parentheses,
   `-> (Clock uses Os)`; [uses] says whether a type here can take one.
   [arg] says it's a type argument, `Pair<fn() uses Clock, Int>`, where a
   comma ends the argument rather than going on with the `uses`. *)
let rec parse_ty ?(uses = true) ?(arg = false) p : ty =
  match peek p with
  | LPAREN -> (
      let start = loc p in
      advance p;
      let t = parse_ty p in
      match peek p with
      | COMMA ->
          (* a tuple's type, `(Str, Int)` *)
          advance p;
          let ts = t :: sep_list p ~close:RPAREN parse_ty in
          let l = Loc.span start (last_loc p) in
          tuple_size l (List.length ts);
          TyTuple (ts, l)
      | _ ->
          expect p RPAREN;
          t)
  | FN ->
      let start = loc p in
      advance p;
      expect p LPAREN;
      (* an operation's own parameters may have defaults, which its
         dependency's declaration collects; a function type among them
         can't *)
      let collect = p.op_defaults and names = p.op_params in
      p.op_defaults <- None;
      p.op_params <- None;
      let index = ref (-1) in
      let params =
        sep_list p ~close:RPAREN (fun p ->
            incr index;
            parse_fn_ty_param ?collect ?names ~index:!index p)
      in
      let ret =
        if peek p = ARROW then (
          advance p;
          Some (parse_ty ~uses:false ~arg p))
        else None
      in
      let errs = if peek p = BANG then Some (parse_errors p) else None in
      let used = if peek p = USES then Some (parse_uses ~arg p) else None in
      TyFn (params, ret, errs, used, Loc.span start (last_loc p))
  | BANG when peek2 p = GT || peek2 p = COMMA ->
      (* `Result<Int, !>`: an empty set, a [Result] that can't be [Err] *)
      let l = loc p in
      advance p;
      TyErrors { errs = []; etail = None; eloc = l }
  | BANG -> TyErrors (parse_errors p)
  | OVER ->
      (* an implementation that goes over another: `over Users uses Clock`
         (handlers.md, "`over`") *)
      let start = loc p in
      advance p;
      let rec joined acc =
        let d = parse_dep_ref p in
        if peek p = AMP then (
          advance p;
          joined (d :: acc))
        else List.rev (d :: acc)
      in
      let names = joined [] in
      impl_rest p ~uses ~arg ~start ~over:true names
  | DOTDOT when arg ->
      (* `Box<Clock uses Os, Console, ..d>`: the `uses` ended at the first
         comma, so the row is left on its own *)
      Diag.error (loc p)
        ~help:
          "in a type argument, a `uses` list ends at a comma: to list several \
           dependencies, put the type in parentheses, `Box<(Clock uses Os, \
           Console, ..d)>`"
        "a named row ends a `uses` list, but the list before it ended at a \
         comma"
  | _ ->
      let start = loc p in
      let name = parse_tyname p in
      (* a variant type, `Order.Placed`, its sum's arguments after it,
         `Tree.Node<Int>` (compiler.md, "Data stage", "Variant types") *)
      let variant =
        match (peek p, peek2 p) with
        | DOT, IDENT c when is_upper c ->
            advance p;
            Some (upper_ident p "a variant's name")
        | _ -> None
      in
      let args =
        if peek p = LT then (
          advance p;
          sep_list p ~close:GT (parse_ty ~arg:true))
        else []
      in
      (match (variant, peek p, peek2 p) with
      | None, DOT, IDENT c when is_upper c && args <> [] ->
          Diag.error (loc p)
            ~help:
              (Printf.sprintf "write `%s.%s<%s>`" (show_tyname name) c
                 (String.concat ", " (List.map show_ty args)))
            "a variant type's arguments are its sum's, written after the \
             variant"
      | _ -> ());
      match variant with
      | Some c -> TyVariant (name, c, args)
      | None ->
      if peek p = AMP then
        (* several dependencies, an implementation of each sharing one
           state: `Clock & TestClock`, and what it needs, `uses Os` *)
        let rec joined acc =
          if peek p = AMP then (
            advance p;
            joined (parse_dep_ref p :: acc))
          else List.rev acc
        in
        let names = joined [ { dep = name; dargs = args } ] in
        impl_rest p ~uses ~arg ~start ~over:false names
      else if uses && (peek p = USES || peek p = BANG) then
        (* an implementation, and what installing it can fail with and it
           needs: `Sql ! DbDown uses Os`, `Log<Int> uses Clock`. A type
           that isn't a dependency's is refused by Resolve *)
        impl_rest p ~uses ~arg ~start ~over:false
          [ { dep = name; dargs = args } ]
      else TyName (name, args)

(* A dependency where one is named: its name, `Clock` or `store.Users`,
   and its type arguments, if it's an instance of a generic one,
   `Chan<Int>`. *)
and parse_dep_ref p : tyname dep_ref =
  let dep = parse_tyname ~what:"a dependency's name" p in
  let dargs =
    if peek p = LT then (
      advance p;
      sep_list p ~close:GT (parse_ty ~arg:true))
    else []
  in
  { dep; dargs }

(* The rest of an implementation's type, after its dependencies' names:
   what installing it can fail with, `! DbDown`, and what it needs, `uses
   Os`. Neither is read after `->`, where they're the function's own
   ([uses] is false then). *)
and impl_rest p ~uses ~arg ~start ~over names =
  let errors = if uses && peek p = BANG then Some (parse_errors p) else None in
  let u = if uses && peek p = USES then Some (parse_uses ~arg p) else None in
  TyImpl
    {
      impl_deps = names;
      impl_over = over;
      impl_errors = errors;
      impl_uses = u;
      impl_loc = Loc.span start (last_loc p);
    }

(* A parameter in a function type may be named for documentation, as in
   `fn(id: UserId) -> User`. The name doesn't affect the type. An
   operation's, the [index]th of its type, may have a default, which goes
   in [collect], by its place and name. *)
and parse_fn_ty_param ?collect ?names ~index p =
  let start = loc p in
  (* one the function changes is written as a call passes it, `&Int`
     (compiler.md, "Blocks with `inout` parameters") *)
  let inout = peek p = AMP in
  if inout then advance p;
  let name =
    match (peek p, peek2 p) with
    | IDENT name, COLON when not (is_upper name) ->
        advance p;
        advance p;
        Some name
    | _ -> None
  in
  Option.iter (fun ns -> ns := !ns @ [ Option.value name ~default:"" ]) names;
  if peek p = INOUT then (
    let at = loc p in
    advance p;
    let t = parse_ty p in
    Diag.error at
      ~help:(Printf.sprintf "write `&%s`" (show_ty t))
      "a function type's parameter that it changes is written `&T`");
  let t = parse_ty p in
  let t = if inout then TyInout (t, Loc.span start (last_loc p)) else t in
  (if peek p = EQ then
     match (collect, name) with
     | Some defaults, Some name ->
         advance p;
         defaults := !defaults @ [ (index, name, parse_default p) ]
     | _ ->
         Diag.error (loc p) ~help:"give it where it's called instead"
           "only an operation's named parameter, in its dependency, has a \
            default");
  t

(* What a function type or an implementation uses, after `uses`: `Clock,
   store.Users`, and last, a named row, `..d`. [greedy] says a comma always
   goes on with another dependency, as in a signature, where `=` ends the
   list; inside a type, one goes on only if what's after the comma can be
   one, so `fn(f: fn() uses Clock, n: Int)` has two parameters. In a type
   argument, [arg], a comma goes on only to a named row, which can't be an
   argument: `Pair<fn() uses Clock, Int>` has two arguments, and several
   dependencies there are written in parentheses, `Box<(fn() uses Clock,
   Console)>`. *)
and parse_uses ?(greedy = false) ?(arg = false) p : uses =
  let start = loc p in
  expect p USES;
  let continues () =
    match (peek2 p, peek3 p) with
    | DOTDOT, _ -> true
    | IDENT n, _ when is_upper n -> not arg
    | IDENT _, DOT -> not arg
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
         for a lowercase name points at the name; and a generic one's
         instance, `Log<Int>` *)
      let d = parse_dep_ref p in
      if peek p = AMP then
        Diag.error (loc p)
          ~help:
            (Printf.sprintf "write `%s, ...`: a function uses each of them"
               (show_dep d))
          "in a `uses` list, dependencies are separated by commas";
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
    | LPAREN ->
        (* a lambda's can ([parse_lambda]), but a function's is a name,
           which its signature shows *)
        Diag.error (loc p)
          ~help:
            "name it, `p: (A, B)`, and take it apart in the body: `let (a, b) \
             = p`"
          "only a lambda's parameter can take a tuple apart"
    | _ -> ident p
  in
  (* a block parameter's mode, `f: concurrent fn(T) -> U`: a word there
     and nowhere else, so neither is reserved (compiler.md, "Stage 11a",
     "The surface") *)
  let pblock =
    match (peek p, peek2 p, peek3 p) with
    | COLON, IDENT (("concurrent" | "spawned") as m), next -> (
        match next with
        | FN ->
            advance p;
            advance p;
            if m = "concurrent" then Concurrent else Spawned
        | IDENT _ | LPAREN | AMP | INOUT ->
            Diag.error (loc2 p) ~help:"remove it"
              (Printf.sprintf "`%s` marks a block parameter of a function" m)
        | _ -> Ordinary)
    | _ -> Ordinary
  in
  let pty =
    if pblock <> Ordinary then Some (parse_ty p)
    else if peek p = COLON then (
      advance p;
      Some (parse_ty p))
    else None
  in
  (* a default, `max: Int = 64` or `kill: Kill = Tree`, is a literal or
     a variant written bare (Resolve checks where it may be) *)
  let pdefault =
    if peek p = EQ && pty <> None then (
      advance p;
      Some (parse_default p))
    else None
  in
  { pname; pty; pmode; pblock; pdefault }

let parse_field_decl ?default p =
  let field_name = ident p in
  expect p COLON;
  let field_ty = parse_ty p in
  let field_default_member =
    if peek p = EQ then (
      advance p;
      match default with
      | Some parse -> Some (parse p field_name field_ty)
      | None -> Diag.error (loc p) "a default is not allowed here")
    else None
  in
  {
    field_name;
    field_ty;
    field_default = None;
    field_default_member;
    op_defaults = [];
    op_params = [];
  }

(* A constructor's declaration: `Free`; `Flat(off: Money)` or
   `Flat(Money)`, one field, positional, whose name only documents it; or
   `Rect { w: Int, h: Int }`, by name (compiler.md, "Data stage", "By-name
   variants"). Several fields in parentheses are reported, with the
   declaration by name as the help, and read as that declaration, so the
   rest of the file is still parsed: a positional field's name is the
   one written, or else a letter. *)
let parse_ctor_decl ?default p =
  let start = loc p in
  let ctor_name = upper_ident p "a constructor name" in
  match peek p with
  | LBRACE ->
      advance p;
      let ctor_fields = sep_list p ~close:RBRACE (parse_field_decl ?default:(Option.map (fun f -> f (Some ctor_name.name)) default)) in
      if ctor_fields = [] then
        Diag.error
          (Loc.span start (last_loc p))
          ~help:(Printf.sprintf "write `%s` alone" ctor_name.name)
          "a variant in braces names its fields, but this has none";
      { ctor_name; ctor_fields; ctor_named = true }
  | LPAREN -> (
      advance p;
      (* a field, `off: Money` or `Money`: its name, if written, its type,
         and how the type is written *)
      let field p =
        let label =
          match (peek p, peek2 p) with
          | IDENT n, COLON when not (is_upper n) ->
              let f = ident p in
              advance p;
              Some f
          | _ -> None
        in
        let i = p.i in
        let field_ty = parse_ty p in
        let shown = spelled p i (p.i - 1) in
        (* a default, `Key(n: Int = 16)`, a literal, so `Key` alone is
           `Key(n: 16)` (compiler.md, "Services stage", "The grammar") *)
        let default =
          if peek p = EQ then (
            advance p;
            Some (parse_default ~field:true p))
          else None
        in
        (label, field_ty, shown, default)
      in
      let plain field_name field_ty =
        { field_name; field_ty; field_default = None; field_default_member = None; op_defaults = []; op_params = [] }
      in
      match sep_list p ~close:RPAREN field with
      | [ (label, field_ty, _, field_default) ] ->
          let field_name =
            match label with
            | Some f -> f
            | None -> { name = ""; loc = ctor_name.loc }
          in
          {
            ctor_name;
            ctor_fields = [ { (plain field_name field_ty) with field_default } ];
            ctor_named = false;
          }
      | [] -> { ctor_name; ctor_fields = []; ctor_named = false }
      | fields ->
          (* each unnamed field gets the first letter no field is named *)
          let taken =
            List.filter_map
              (fun (l, _, _, _) -> Option.map (fun (f : ident) -> f.name) l)
              fields
          in
          let letters =
            List.filter
              (fun c -> not (List.mem c taken))
              (List.init 26 (fun i -> String.make 1 (Char.chr (97 + i))))
          in
          let _, named =
            List.fold_left_map
              (fun free (label, field_ty, shown, _) ->
                match (label, free) with
                | Some (f : ident), _ -> (free, (plain f field_ty, shown))
                | None, l :: rest ->
                    ( rest,
                      (plain { name = l; loc = ctor_name.loc } field_ty, shown) )
                | None, [] -> (free, (plain ctor_name field_ty, shown)))
              letters fields
          in
          let written =
            Printf.sprintf "%s { %s }" ctor_name.name
              (String.concat ", "
                 (List.map
                    (fun ((f : field), shown) -> f.field_name.name ^ ": " ^ shown)
                    named))
          in
          let help =
            if List.for_all (fun (l, _, _, _) -> l <> None) fields then
              Printf.sprintf "write `%s`" written
            else Printf.sprintf "give each field a name, in braces: `%s`" written
          in
          Diag.report p.sink
            (Diag.make
               (Loc.span start (last_loc p))
               ~help "a variant with several fields names them, in braces");
          { ctor_name; ctor_fields = List.map fst named; ctor_named = true })
  | _ -> { ctor_name; ctor_fields = []; ctor_named = false }

(* The constructors of a sum type, separated by `|`. When the type is
   indented under `type X =`, each `|` may start its own line. *)
let parse_ctors ?default p =
  if peek p = PIPE then advance p;
  let rec loop acc =
    let c = parse_ctor_decl ?default p in
    if peek p = NEWLINE && peek2 p = PIPE then advance p;
    if peek p = PIPE then (
      advance p;
      loop (c :: acc))
    else List.rev (c :: acc)
  in
  loop []

let parse_type_body ?default ~prelude p =
  match peek p with
  | IDENT "builtin" when prelude ->
      (* a built-in type, whose members follow (ast.ml, [Builtin]) *)
      advance p;
      Builtin
  | LBRACE ->
      advance p;
      Fields (sep_list p ~close:RBRACE (parse_field_decl ?default:(Option.map (fun f -> f None) default)))
  | OPAQUE when peek2 p = LBRACE ->
      (* a record only its module sees as one *)
      advance p;
      advance p;
      let fields = sep_list p ~close:RBRACE (parse_field_decl ?default:(Option.map (fun f -> f None) default)) in
      if peek p = WITH then
        Diag.error (loc p)
          ~help:
            "`with numeric` makes a number of an `Int` or a `Float`: `opaque \
             Int with numeric`"
          "a record can't be `with numeric`";
      Opaque_fields fields
  | OPAQUE ->
      advance p;
      let rep = parse_ty p in
      (* `with numeric` gives it its arithmetic (operators.md, "Number
         types") *)
      let numeric =
        if peek p = WITH then (
          advance p;
          match peek p with
          | IDENT "numeric" ->
              let at = loc p in
              advance p;
              Some at
          | _ ->
              Diag.error (loc p) ~help:"write `opaque Int with numeric`"
                "an opaque type can only be `with numeric`")
        else None
      in
      Opaque { rep; numeric }
  | BANG -> Errors (parse_errors ~lines:true p)
  | _ -> Ctors (parse_ctors ?default p)

(* ---- patterns ---- *)

(* A pattern that started at [start], with the next node id. *)
let mk_pattern p start pkind =
  p.node <- p.node + 1;
  { pkind; ploc = Loc.span start (last_loc p); pnode = p.node }

(* A `Float` isn't a pattern: two floats that print the same can differ,
   so matching one exactly is rarely what's meant. *)
let float_pattern p =
  Diag.error (loc p) ~help:"compare it in a guard: `x if x == 1.5 => ...`"
    "a `Float` can't be a pattern"

(* Is the next thing a record pattern of a type named, `User {` or
   `rows.Row {`, or the thing
   [after] tokens on: after a `let`, 1. *)
let at_record_pattern ?(after = 0) p =
  let at k = peek_at p (after + k) in
  match (at 0, at 1, at 2, at 3) with
  | IDENT t, LBRACE, _, _ -> is_upper t
  | IDENT m, DOT, IDENT t, LBRACE -> (not (is_upper m)) && is_upper t
  | _ -> false

(* A pattern: alternatives joined by `|`, then `as` and a name for the
   whole, which binds looser than `|`: `A | B as x` names what either
   matched (compiler.md, "Data stage", "Or-patterns, `as`"). *)
let rec parse_pattern p : pattern =
  let start = loc p in
  let alt = parse_alternatives p in
  if peek p = AS then (
    advance p;
    match peek p with
    | IDENT name when not (is_upper name) ->
        let x = ident p in
        mk_pattern p start (PAs (alt, x))
    | _ ->
        Diag.error (loc p) ~help:"write `as` and a lowercase name: `... as p`"
          (Printf.sprintf "`as` names the whole of what's matched, but %s isn't a name"
             (describe (peek p))))
  else alt

(* One pattern or several joined by `|`, any of which matches. *)
and parse_alternatives p : pattern =
  let start = loc p in
  let first = parse_single p in
  let rec rest acc =
    if peek p = PIPE then (
      advance p;
      rest (parse_single p :: acc))
    else List.rev acc
  in
  match rest [ first ] with
  | [ only ] -> only
  | alts -> mk_pattern p start (POr alts)

and parse_single p : pattern =
  let start = loc p in
  let finish = mk_pattern p start in
  match peek p with
  | IDENT "_" ->
      advance p;
      finish PWild
  | IDENT _ when at_record_pattern p ->
      (* `User { id, .. }`, `rows.Row { id, .. }`: a record of the type
         named *)
      let t = parse_tyname p in
      finish (PRecord (Some t, parse_fields p))
  | LBRACE -> finish (PRecord (None, parse_fields p))
  | IDENT name when is_upper name || at_module_type p -> (
      let c = parse_ctor_ref p in
      match peek p with
      | LPAREN ->
          advance p;
          (* `..` is a pattern in braces' "the rest", never a positional
             one's *)
          let arg p =
            if peek p = DOTDOT then
              Diag.error (loc p) ~help:"write `_` for each field it leaves out"
                "`..` stands for the fields a pattern in braces leaves out"
            else parse_pattern p
          in
          let args = sep_list p ~close:RPAREN arg in
          finish (PCon (c, args))
      | LBRACE ->
          (* `Shape.Rect { w, .. }`: after its type, always a constructor;
             a bare `Rect { .. }` is read as a record's, above, and Resolve
             decides *)
          finish (PCon_named (c, parse_fields p))
      | _ -> finish (PCon (c, [])))
  | IDENT name ->
      advance p;
      finish (PVar { name; loc = Loc.span start (last_loc p) })
  | INT n when n = Int64.min_int -> too_big p
  | INT n ->
      advance p;
      finish (PInt n)
  | MINUS -> (
      advance p;
      match peek p with
      | INT n ->
          (* for `-9223372036854775808`, [n] is [Int64.min_int], and so is
             its [Int64.neg] *)
          advance p;
          finish (PInt (Int64.neg n))
      | FLOAT _ -> float_pattern p
      | _ -> fail_expected p "a number")
  | FLOAT _ -> float_pattern p
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
  | STR _ | STR_HEAD _ | DOTDOT -> parse_str_pattern p start
  | LBRACKET -> parse_list_pattern p start
  | LPAREN -> (
      advance p;
      let first = parse_pattern p in
      match peek p with
      | RPAREN ->
          (* `(A as x) | B`: in parentheses, one pattern is itself *)
          advance p;
          first
      | COMMA ->
          advance p;
          let ps = first :: sep_list p ~close:RPAREN parse_pattern in
          tuple_size (Loc.span start (last_loc p)) (List.length ps);
          finish (PTuple ps)
      | _ -> fail_expected p "`,` or `)`")
  | _ -> fail_expected p "a pattern"

(* A sequence's rest, at `..`: `..name`, which binds the middle, or `..`
   alone, which ignores it (compiler.md, "Patterns stage", "The
   grammar"). *)
and parse_rest p : ident rest =
  let start = loc p in
  expect p DOTDOT;
  let rname =
    match peek p with
    | IDENT x when (not (is_upper x)) && x <> "_" -> Some (ident p)
    | _ -> None
  in
  { rname; rloc = Loc.span start (last_loc p) }

(* The error for a second rest in one pattern. *)
and two_rests (r : ident rest) =
  Diag.error r.rloc
    ~help:"to cut at a separator, use `split` or `split_once` on the value"
    "a pattern has one `..` at most"

(* A `Str` pattern: string literals side by side, and at most one rest
   among them, `"Bearer " ..token`, `..stem ".json"`, `"<" ..inner ">"`;
   [middle] if its rest was read already. Without a rest it's one
   literal, the pieces joined: `"a" "b"` is `"ab"`. *)
and parse_str_pattern ?middle p start =
  let front = ref [] and back = ref [] and middle = ref middle in
  let rec pieces () =
    match peek p with
    | STR s ->
        let at = loc p in
        advance p;
        let q = mk_pattern p at (PStr s) in
        if !middle = None then front := q :: !front else back := q :: !back;
        pieces ()
    | STR_HEAD _ ->
        Diag.error (loc p)
          ~help:"match the fixed text, and bind the rest with `..name`"
          "a string pattern can't have holes"
    | DOTDOT -> (
        let r = parse_rest p in
        match !middle with
        | Some _ -> two_rests r
        | None ->
            middle := Some r;
            pieces ())
    | IDENT _ | INT _ | FLOAT _ | LPAREN | LBRACKET | LBRACE | TRUE | FALSE ->
        Diag.error (loc p)
          ~help:"bind the middle with `..name`, and test the rest in the arm"
          "the pieces of a string pattern are string literals"
    | _ -> ()
  in
  pieces ();
  let front = List.rev !front and back = List.rev !back in
  match (!middle, front, back) with
  | None, _, _ ->
      let text =
        String.concat ""
          (List.map (fun (q : pattern) -> match q.pkind with PStr s -> s | _ -> "") front)
      in
      mk_pattern p start (PStr text)
  | Some { rname = Some x; rloc }, [], [] ->
      Diag.error rloc
        ~help:(Printf.sprintf "bind it with a name: `%s`" x.name)
        (Printf.sprintf "`..%s` alone is the whole value" x.name)
  | Some { rname = None; rloc }, [], [] ->
      Diag.error rloc ~help:"write `_`" "`..` alone matches anything"
  | Some _, _, _ ->
      mk_pattern p start (PSeq { front; middle = !middle; back; bracketed = false })

(* An `Array` pattern, in brackets: element patterns, and at most one
   rest among them, `[first, ..rest]`, `[..init, last]`, `[a, .., z]`.
   An element is any pattern; one that starts with `..` and goes on with
   a string is a `Str` pattern, `["v" ..n, ..]`'s first is too. *)
and parse_list_pattern p start =
  expect p LBRACKET;
  let front = ref [] and back = ref [] and middle = ref None in
  let element p =
    if peek p = DOTDOT then (
      let at = loc p in
      let r = parse_rest p in
      match (peek p, !middle) with
      | (STR _ | STR_HEAD _), _ ->
          let q = parse_str_pattern ~middle:r p at in
          if !middle = None then front := q :: !front else back := q :: !back
      | _, Some _ -> two_rests r
      | _, None -> middle := Some r)
    else
      let q = parse_pattern p in
      if !middle = None then front := q :: !front else back := q :: !back
  in
  ignore (sep_list p ~close:RBRACKET element);
  let front = List.rev !front and back = List.rev !back in
  (match (!middle, front, back) with
  | Some { rname = Some x; rloc }, [], [] ->
      Diag.error rloc
        ~help:(Printf.sprintf "bind it with a name: `%s`" x.name)
        (Printf.sprintf "`[..%s]` alone is the whole array" x.name)
  | Some { rname = None; rloc }, [], [] ->
      Diag.error rloc ~help:"write `_`" "`..` alone matches anything"
  | _ -> ());
  mk_pattern p start (PSeq { front; middle = !middle; back; bracketed = true })

(* A record pattern's fields, in braces: `{ id, lines: ls, .. }`, each
   `f: p` or `f` alone, which binds `f`, then `..`, last and alone, which
   leaves out the rest. *)
and parse_fields p : fields =
  expect p LBRACE;
  let field p =
    let f = ident p in
    if peek p = COLON then (
      advance p;
      (f, parse_pattern p))
    else (f, mk_pattern p f.loc (PVar f))
  in
  (* the fields, then whether there's a `..` *)
  let rec go acc =
    match peek p with
    | RBRACE ->
        advance p;
        { fpats = List.rev acc; rest = false }
    | DOTDOT -> (
        let at = loc p in
        advance p;
        let written rest =
          show_fields show_pattern { fpats = rest; rest = true }
        in
        match peek p with
        | RBRACE ->
            advance p;
            { fpats = List.rev acc; rest = true }
        | IDENT name when not (is_upper name) ->
            Diag.error (Loc.span at (loc p))
              ~help:
                (Printf.sprintf "bind the whole with `as`: `%s as %s`"
                   (written (List.rev acc)) name)
              "a pattern's `..` stands for the fields it leaves out, so it \
               takes no name"
        | COMMA ->
            (* the fields after it, for the help *)
            advance p;
            let after = sep_list p ~close:RBRACE field in
            Diag.error at
              ~help:
                (Printf.sprintf "move it to the end: `%s`"
                   (written (List.rev acc @ after)))
              "`..` comes last in a pattern"
        | _ -> fail_expected p "`}`")
    | _ -> (
        let f = field p in
        match peek p with
        | COMMA ->
            advance p;
            go (f :: acc)
        | RBRACE -> go (f :: acc)
        | _ -> fail_expected p "`,` or `}`")
  in
  go []

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
    | IDENT n when peek2 p <> LPAREN && List.mem n p.tags ->
        (* `fail on`, a parameter written of type `Tags`, which Resolve
           checks is the prelude's: an error is never a value (errors.md,
           "Keeping an error"), so any other name is an error *)
        finish (PFail_in (ident p))
    | IDENT name ->
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
    let fails =
      match rest [ first ] with
      | [ only ] -> only
      | alternatives -> mk_pattern p start (POr alternatives)
    in
    (if peek p = AS then
       (* an error is never a value (errors.md, "Keeping an error") *)
       let name = match peek2 p with IDENT n -> n | _ -> "e" in
       Diag.error (loc p)
         ~help:
           (Printf.sprintf
              "match each tag, like `fail NotFound`, or keep the whole \
               outcome as a value with `attempt`, and match `Err(%s)`"
              name)
         "a `fail` pattern can't bind the whole error to a name");
    fails

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
    | PLUSPERCENTEQ -> Some (Some Wrap_add)
    | MINUSPERCENTEQ -> Some (Some Wrap_sub)
    | STARPERCENTEQ -> Some (Some Wrap_mul)
    | _ -> None
  in
  match op with
  | None -> e
  | Some op ->
      advance p;
      let value = parse_body p in
      mk (Assign { target = e; op; value; onode = onode p }) start p

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
  | Let_pattern { pat; _ } :: _ ->
      Diag.error pat.ploc
        ~help:"add the value this block should produce as its last line"
        "this block ends with a `let`, so it has no value"
  | Finally f :: _ ->
      Diag.error
        { f.loc with stop = { f.loc.start with col = f.loc.start.col + 7 } }
        ~help:"move it above the lines it should cover"
        "a `finally` covers what comes after it, and nothing does"
  | [] -> assert false (* parse_stmt always returns a statement *)

and parse_stmt p =
  match (peek p, peek2 p) with
  | LET, IDENT x when (not (is_upper x)) && peek3 p <> DOT -> parse_let p
  | LET, (IDENT _ | LPAREN | LBRACE | INT _ | MINUS | TRUE | FALSE | FLOAT _
         | LBRACKET | STR _ | DOTDOT) ->
      (* `let (k, v) = pair`, `let { id, .. } = order`, `let Team(n) = p
         else fail NotTeam`: a pattern, which Exhaust checks always
         matches, or has an `else` if it might not *)
      advance p;
      let pat = parse_pattern p in
      if peek p = COLON then
        Diag.error (loc p)
          ~help:
            (match pat.pkind with
            | PRecord _ -> "write the type on the value, or name it: `let User { id, .. } = u`"
            | _ -> "write the type on the value: `let (a, b): (A, B)` isn't Ren")
          (match pat.pkind with
          | PRecord _ -> "a `let` that takes a record apart has no type written"
          | _ -> "a `let` that takes a tuple apart has no type written");
      expect p EQ;
      let value, else_ = let_value p in
      Let_pattern { pat; value; else_ }
  | VAR, (LPAREN | LBRACE) ->
      Diag.error (loc p)
        ~help:
          "take it apart with `let`, then make a `var` of each part that \
           changes: `var x = a`"
        (if peek2 p = LBRACE then "a `var` can't take a record apart"
         else "a `var` can't take a tuple apart")
  | (LET | VAR), _ -> parse_let p
  | FOR, _ -> Expr (parse_for p)
  | WHILE, _ -> Expr (parse_while p)
  | FINALLY, _ -> parse_finally p
  | _ -> Expr (parse_line p)

(* `let x = e` or `var x = e`, with its type if it's written. A `let x = e
   else ...` is the pattern form's, of a pattern that always matches,
   which Exhaust refuses. *)
and parse_let p =
  let kw = peek p in
  advance p;
  let name = ident p in
  let ty =
    if peek p = COLON then (
      advance p;
      Some (parse_ty p))
    else None
  in
  expect p EQ;
  if kw = LET && ty = None then
    match let_value p with
    | value, None -> Let { name; ty; value; mut = false }
    | value, else_ ->
        let pk = if name.name = "_" then PWild else PVar name in
        p.node <- p.node + 1;
        let pat = { pkind = pk; ploc = name.loc; pnode = p.node } in
        Let_pattern { pat; value; else_ }
  else Let { name; ty; value = parse_body p; mut = kw = VAR }

(* A `let`'s value, and its `else`, if it has one: the value is on the
   `let`'s line and the `else` after it, its body a line or an indented
   block, as an `if`'s is (compiler.md, "Data stage", "`let ... else`").
   An `if` in the value takes its own `else` first. *)
and let_value p =
  if peek p = INDENT then (parse_body p, None)
  else
    let value = parse_line p in
    if peek p = ELSE then (
      advance p;
      (value, Some (parse_body p)))
    else (value, None)

and parse_for p =
  let start = loc p in
  expect p FOR;
  (* a name, or a pattern, which Exhaust checks always matches *)
  let one () =
    match (peek p, peek2 p) with
    | IDENT x, (COMMA | IN) when not (is_upper x) ->
        let l = loc p in
        let x = ident p in
        mk_pattern p l (PVar x)
    | _ -> parse_pattern p
  in
  let first = one () in
  (* `for i, x in xs`: the index, then the element *)
  let index, pat =
    if peek p = COMMA then (
      advance p;
      (match first.pkind with
      | PVar _ | PWild -> ()
      | _ ->
          Diag.error first.ploc
            ~help:
              (Printf.sprintf "write `for i, %s in ...`, the index first"
                 (show_pattern first))
            "the index before the `,` in a `for` is a name, or `_`");
      (Some first, one ()))
    else (None, first)
  in
  expect p IN;
  let iter = parse_orelse p in
  let over =
    match peek p with
    | DOTDOT ->
        (* `0..n`, from the first up to, but not including, the second *)
        advance p;
        (match peek p with
        | EQ ->
            Diag.error (loc p)
              ~help:"write `a..b + 1` for the `Int`s up to and including `b`"
              "there's no `..=`: a range is from the first number up to, but \
               not including, the second"
        | DOT ->
            Diag.error (loc p) ~help:"write `a..b`"
              "a range is written with two dots, `a..b`, from the first number \
               up to, but not including, the second"
        | _ -> ());
        let range = Range (iter, parse_orelse p) in
        (match index with
        | Some i ->
            Diag.error i.ploc
              ~help:
                (Printf.sprintf "write `for %s in ...`: the number is its own index"
                   (show_pattern pat))
              "a range gives only its numbers, with no index beside them"
        | None -> ());
        range
    | _ -> Each iter
  in
  if peek p <> INDENT then
    Diag.error (loc p) ~help:"put the loop's body on the lines below, indented"
      (Printf.sprintf "expected the body of the `for` loop, found %s"
         (describe (peek p)));
  advance p;
  let body = parse_block p in
  mk (For { index; pat; over; body }) start p

(* `while c`, then its body, indented below *)
and parse_while p =
  let start = loc p in
  expect p WHILE;
  let cond = parse_orelse p in
  if peek p <> INDENT then
    Diag.error (loc p) ~help:"put the loop's body on the lines below, indented"
      (Printf.sprintf "expected the body of the `while` loop, found %s"
         (describe (peek p)));
  advance p;
  let body = parse_block p in
  mk (While { cond; body }) start p

(* `finally(r) => ...`: a lambda of one parameter, what the code after it
   ends in (ast.ml, [Finally]) *)
and parse_finally p =
  let at = loc p in
  expect p FINALLY;
  if peek p <> LPAREN then
    Diag.error (loc p) ~help:"write `finally(r) => ...`"
      (Printf.sprintf
         "expected `(` and the result it's given after `finally`, found %s"
         (describe (peek p)));
  advance p;
  let params = sep_list p ~close:RPAREN parse_param in
  expect p FATARROW;
  let body = parse_body p in
  Finally (mk (Lambda (params, body)) at p)

and parse_expr ?(chain = true) p =
  let first = p.i in
  let e = parse_orelse ~chain p in
  if peek p = OVER then chain_not_value p first;
  if peek p = DOTDOT then
    Diag.error (loc p)
      ~help:
        "a range is for counting, `for i in 0..n`, and for slicing, `xs[a..b]`"
      "a range, `a..b`, is written only after a `for`'s `in`, or in an index: \
       it isn't a value";
  e

(* `a over b` where it isn't an item of a `with`, whose first link
   started at token [first]: a chain isn't a value (foundations.md,
   decision 3), so the help writes it where it's installed. *)
and chain_not_value p first =
  let rec links () =
    if peek p = OVER then (
      advance p;
      ignore (parse_orelse p);
      links ())
  in
  links ();
  let last = p.i - 1 in
  Diag.error
    (Loc.span (snd p.toks.(first)) (snd p.toks.(last)))
    ~help:
      (Printf.sprintf
         "keep the parts, and write the chain where it's installed: `with %s \
          in ...`"
         (spelled p first last))
    "a chain of handlers isn't a value"

(* An expression that may be followed by `..`, which only a `for` reads
   ([parse_for]). *)
and parse_orelse ?(chain = true) p =
  let start = loc p in
  let lhs = if chain then parse_pipe p else parse_or p in
  if peek p = ORELSE then (
    advance p;
    let rhs = parse_expr p in
    mk (Binop (Orelse, lhs, rhs, onode p)) start p)
  else lhs

(* A chain, `order |> try validate |> price(d)` (language.md §8): a head,
   then steps, each [x |> f(a)] a [Pipe] whose step calls `f(_, a)`. It
   sits between `orelse` and `||`, so `orelse` may follow a chain and
   applies to its result. The head is one term, so there's no precedence
   to learn: anything that isn't a unary or postfix expression, a `try`,
   an `attempt` or one in parentheses, is refused, as is a binary operator
   after the last step; and `&` is, since a chain passes values. *)
and parse_pipe p =
  let start = loc p in
  let first = p.i in
  let head = parse_or p in
  let head_last = p.i - 1 in
  (* the steps, each with the chain before it as written, for a help *)
  let rec steps subject n =
    if peek p <> PIPEGT then subject
    else
      let before = spelled p first (p.i - 1) in
      advance p;
      let step, block, (text, tsrc, inner) = parse_step p ~subject:before in
      (if n = 0 then
         match head.kind with
         | Binop _ ->
             Diag.error head.loc
               ~help:
                 (Printf.sprintf "put it in parentheses: `(%s) |> %s`"
                    (spelled p first head_last) text)
               "`|>` takes one value on its left"
         | Ref _ ->
             Diag.error
               { head.loc with stop = { head.loc.start with col = head.loc.start.col + 1 } }
               ~help:
                 (Printf.sprintf "call it with `&` directly: `%s`"
                    (amp_call tsrc inner ~subject:(spelled p (first + 1) head_last)))
               "`|>` passes a value, so nothing in a chain can change it"
         | _ -> ());
      let e = mk (Pipe { subject; step }) start p in
      if block && peek p = PIPEGT then
        Diag.error (loc p)
          ~help:
            "name the block first, `let f = fn(x) => ...`, and pass it in the \
             parentheses"
          "only the chain's last step can take a block";
      steps e (n + 1)
  in
  let e = steps head 0 in
  (if e != head then
     match peek p with
     | PLUS | MINUS | STAR | SLASH | PERCENT | PLUSPERCENT | MINUSPERCENT
     | STARPERCENT | EQEQ | NEQ | LT | LE | GT | GE | AMPAMP | PIPEPIPE | DOT
     | LBRACKET ->
         Diag.error (loc p)
           ~help:"put the chain in parentheses, or name it with `let`"
           "a chain ends its expression"
     | _ -> ());
  e

(* One step of a chain, after its `|>`: an optional `try` or `attempt`,
   then a function by name, `f`, `module.f` or `Type.f` (Resolve decides
   which, and refuses a field of a value), then its other arguments in
   parentheses, if it has any, then a trailing block. It's the call
   `f(_, a)`, [Piped] for the value on the left, inside its marker. Also
   whether it has a trailing block, which only the last step may, and, as
   written, the step, its function and its other arguments. [subject] is
   the chain before it as written, for a help. *)
and parse_step p ~subject =
  let start = loc p and first = p.i in
  let mark =
    match peek p with
    | TRY ->
        advance p;
        Some `Try
    | ATTEMPT ->
        advance p;
        Some `Attempt
    | _ -> None
  in
  let amp =
    if peek p = AMP then (
      let l = loc p in
      advance p;
      Some l)
    else None
  in
  let not_a_step at =
    Diag.error at
      ~help:
        "name it first, `let apply_rules = fn(o) => ...`, then `|> \
         apply_rules`"
      "a step is a function by name, not a block"
  in
  let tstart = loc p and tfirst = p.i in
  let target =
    match peek p with
    | IDENT n when at_module_type p || is_upper n -> (
        (* `Type.f` or `module.Type.f`, a member, as [parse_primary] reads
           one; a constructor or a record isn't a step *)
        let e = parse_primary p in
        match e.kind with
        | Var (Item _) | Field ({ kind = Con (_, []); _ }, _) -> e
        | _ -> not_a_step e.loc)
    | IDENT n ->
        advance p;
        let v = mk (Var (Bare n)) tstart p in
        if
          peek p = DOT
          && match peek2 p with IDENT m -> not (is_upper m) | _ -> false
        then (
          advance p;
          let f = ident p in
          mk (Field (v, f)) tstart p)
        else v
    | _ -> not_a_step (loc p)
  in
  let tsrc = spelled p tfirst (p.i - 1) in
  let args, inner =
    if peek p = LPAREN then (
      let open_i = p.i in
      advance p;
      let args = sep_list p ~close:RPAREN parse_call_arg in
      (args, if p.i - 2 > open_i then spelled p (open_i + 1) (p.i - 2) else ""))
    else ([], "")
  in
  Option.iter
    (fun at ->
      Diag.error at
        ~help:
          (Printf.sprintf "call it with `&` directly: `%s`"
             (amp_call tsrc inner ~subject))
        "`|>` passes a value, so nothing in a chain can change it")
    amp;
  let block =
    if peek p = FN then (
      let lam = parse_lambda p in
      (* a block on the step's line whose body is a chain took the rest
         of the chain in, as R's pipe did a lambda's: what's after it was
         meant as steps, and only the last step can take a block *)
      (match lam.kind with
      | Lambda (_, ({ kind = Pipe _ | Binop (Orelse, { kind = Pipe _; _ }, _, _); _ } as body))
        when body.loc.start.line = lam.loc.start.line ->
          Diag.error body.loc
            ~help:
              "name the block first, `let f = fn(x) => ...`, and pass it in \
               the parentheses"
            "only the chain's last step can take a block"
      | _ -> ());
      [ lam ])
    else []
  in
  let text = spelled p first (p.i - 1) in
  let hole = node p Piped target.loc in
  let call = mk (Call (target, (hole :: args) @ block)) tstart p in
  let step =
    match mark with
    | Some `Try -> mk (Try call) start p
    | Some `Attempt -> mk (Attempt call) start p
    | None -> call
  in
  (step, block <> [], (text, tsrc, inner))

(* `f(&x, a)`, the call a step `|> &f(a)` or a head `&x |> f(a)` meant:
   [target] the step's function as written, [inner] its other arguments,
   [subject] what's on the left. *)
and amp_call target inner ~subject =
  Printf.sprintf "%s(&%s%s)" target subject
    (if inner = "" then "" else ", " ^ inner)

and parse_or p = left_assoc [ (PIPEPIPE, Or) ] parse_and p
and parse_and p = left_assoc [ (AMPAMP, And) ] parse_not p

and parse_not p =
  match peek p with
  | NOT ->
      let start = loc p in
      advance p;
      let e = parse_not p in
      mk (Unop (Not, e, onode p)) start p
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
      mk (Binop (op, lhs, rhs, onode p)) start p

(* A left-associative binary level: `a - b - c` parses as `(a - b) - c`. *)
and left_assoc ops next p =
  let start = loc p in
  let rec loop lhs =
    match List.assoc_opt (peek p) ops with
    | Some op ->
        advance p;
        let rhs = next p in
        loop (mk (Binop (op, lhs, rhs, onode p)) start p)
    | None -> lhs
  in
  loop (next p)

and parse_add p =
  left_assoc
    [
      (PLUS, Add);
      (MINUS, Sub);
      (PLUSPERCENT, Wrap_add);
      (MINUSPERCENT, Wrap_sub);
    ]
    parse_mul p

and parse_mul p =
  left_assoc
    [ (STAR, Mul); (SLASH, Div); (PERCENT, Mod); (STARPERCENT, Wrap_mul) ]
    parse_unary p

and parse_unary p =
  match peek p with
  | YIELD ->
      (* Keep the source and its marker intact; Resolve checks which
         generator owns this yield, including a block or cleanup inside it. *)
      let start = loc p in
      advance p;
      let from = peek p = IDENT "from" in
      if from then advance p;
      let value = parse_expr p in
      mk (if from then Yield_from value else Yield value) start p
  | RETURN ->
      let start = loc p in
      advance p;
      let value =
        match peek p with
        | NEWLINE | DEDENT | EOF | ELSE | RPAREN | RBRACKET | RBRACE | COMMA -> None
        | _ -> Some (parse_expr p)
      in
      mk (Return value) start p
  | MINUS -> (
      let start = loc p in
      advance p;
      match (peek p, peek2 p) with
      | INT n, tok
        when n = Int64.min_int && not (List.mem tok [ DOT; LBRACKET; LPAREN ])
        ->
          (* the smallest `Int`, written whole ([too_big]) *)
          advance p;
          mk (Int n) start p
      | _ ->
          let e = parse_unary p in
          mk (Unop (Neg, e, onode p)) start p)
  | AMP ->
      let start = loc p in
      advance p;
      let e = parse_unary p in
      mk (Ref e) start p
  | TRY ->
      (* `try` covers every call to its right (errors.md, "Marking"), so it
         takes the whole expression there: `try a() + b()` is
         `try (a() + b())`; but `|>` ends its reach, so `try order |>
         validate` is `(try order) |> validate`, each step marked on its own
         (language.md §8). Brackets and bodies inside it start afresh:
         `try f(a |> g)` covers the whole call *)
      let start = loc p in
      advance p;
      let e = parse_expr ~chain:false p in
      mk (Try e) start p
  | ATTEMPT ->
      (* `attempt` makes a value, a `Result`, which is usually compared
         next, so it stops at a comparison: `attempt f() == Err(X)` is
         `(attempt f()) == Err(X)`, and `attempt a() + b()` is
         `attempt (a() + b())` *)
      let start = loc p in
      advance p;
      let e = parse_add p in
      mk (Attempt e) start p
  | ASSERT ->
      (* like `try`, it takes the whole expression to its right:
         `assert a == b` checks `a == b` *)
      let start = loc p in
      advance p;
      let e = parse_expr p in
      mk (Assert e) start p
  | IDENT "release" when (match peek2 p with IDENT _ -> true | _ -> false) ->
      (* `release Next.get(id)`: a word only before a name on its line, so
         `release()`, an arm `release() =>` and an operation `release:`
         are the name they've always been. It covers one call, so its
         operand is a postfix expression, and `try release ...` marks it
         through `try`'s *)
      let start = loc p in
      advance p;
      let e = parse_postfix p in
      mk (Release e) start p
  | _ -> parse_postfix p

(* Field access and calls bind tightest: `-user.age` is `-(user.age)`. *)
and parse_postfix p =
  let start = loc p in
  (* Speculate with a private parser: comparison operands may start like
     types, so neither its cursor, node counter nor diagnostics can escape. *)
  let type_args (e : expr) =
    match e.kind with
    | Var _ | Field _ | Con (_, []) ->
        let q = { p with sink = Diag.sink (); op_defaults = None; op_params = None } in
        let adjacent = e.loc.stop = (loc p).start in
        (try
           advance q;
           if peek q = GT then None
           else
             let ts = sep_list q ~close:GT (parse_ty ~arg:true) in
             let boundary =
               match peek q with
               | NEWLINE | DEDENT | EOF | RPAREN | RBRACKET | RBRACE | COMMA
               | THEN | ELSE | FATARROW | DOT -> true
               | _ -> false
             in
             if not (Diag.has_errors q.sink)
                && (peek q = LPAREN || (adjacent && boundary)) then
               Some (q.i, ts)
             else None
         with Diag.Error _ -> None)
    | _ -> None
  in
  let rec loop e =
    match peek p with
    | LT -> (
        match type_args e with
        | Some (i, ts) ->
            p.i <- i;
            loop (mk (Type_apply (e, ts)) start p)
        | None -> e)
    | DOT -> (
        advance p;
        match peek p with
        | INT _ | FLOAT _ ->
            (* `t.0` (and `t.0.1`, which is read as a number) *)
            Diag.error (loc p)
              ~help:
                "take it apart with a pattern, `let (a, b) = t`; if its parts \
                 want names, make it a record"
              "a tuple's parts have no names or numbers"
        | USES ->
            let f : ident = { name = "uses"; loc = loc p } in
            advance p;
            loop (mk (Field (e, f)) start p)
        | FAIL ->
            (* `call.fail(Down)`, in a handler `over any`, which Resolve
               says it's in *)
            let f : ident = { name = "fail"; loc = loc p } in
            advance p;
            loop (mk (Field (e, f)) start p)
        | _ ->
            let f = ident p in
            loop (mk (Field (e, f)) start p))
    | LBRACKET ->
        advance p;
        (* an index, `xs[i]`, or a range of them, `xs[a..b]`, a slice *)
        let first = p.i in
        let i = parse_orelse p in
        if peek p = DOTDOT then (
          advance p;
          let hi = parse_orelse p in
          expect p RBRACKET;
          loop (mk (Slice (e, i, hi)) start p))
        else (
          if peek p = OVER then chain_not_value p first;
          expect p RBRACKET;
          loop (mk (Index (e, i)) start p))
    | LPAREN ->
        advance p;
        let args = sep_list p ~close:RPAREN parse_call_arg in
        (* `twice() fn() =>` passes the lambda as the last argument, so a
           multi-line lambda doesn't have to sit inside the parentheses *)
        let args = if peek p = FN then args @ [ parse_lambda p ] else args in
        loop (mk (Call (e, args)) start p)
    | FN ->
        (* `Async.scope fn(s) => ...`: a call whose one argument is a block
           may leave out its parentheses, when the `fn` is on the line of
           what it calls (compiler.md, "Stage 11a", "The surface") *)
        let lambda = parse_lambda p in
        loop (mk (Call (e, [ lambda ])) start p)
    | _ -> e
  in
  loop (parse_primary p)

(* An argument of a call: an expression, or one passed by its
   parameter's name, `on: Flaky | Broken`, which only a parameter of type
   `Tags` is (compiler.md, "`over any` and `retry`"). What a name is given
   is tags, joined by `|`, if it starts with a tag followed by `|`, `,` or
   `)`; otherwise an expression, `on: on`, which passes one on, or what
   Resolve or inference says can't be passed by name. *)
and parse_call_arg p =
  match (peek p, peek2 p) with
  | IDENT n, COLON when not (is_upper n) ->
      let start = loc p in
      let name = ident p in
      advance p;
      let ends k =
        match fst p.toks.(min (p.i + k) (Array.length p.toks - 1)) with
        | PIPE | COMMA | RPAREN -> true
        | _ -> false
      in
      let tags =
        match peek p with
        | IDENT t when is_upper t -> ends 1
        | IDENT _ -> at_module_type p && ends 3
        | _ -> false
      in
      let value =
        if not tags then parse_expr p
        else
          let tstart = loc p in
          let rec errs acc =
            let e =
              if at_module_type p then Set (parse_tyname p)
              else Tag (upper_ident p "an error tag", [])
            in
            if peek p = PIPE then (
              advance p;
              errs (e :: acc))
            else List.rev (e :: acc)
          in
          let errs = errs [] in
          let eloc = Loc.span tstart (last_loc p) in
          mk (Tag_set { errs; etail = None; eloc }) tstart p
      in
      mk (Named (name, value)) start p
  | _ -> parse_expr p

and parse_primary p =
  let start = loc p in
  match peek p with
  | INT n when n = Int64.min_int -> too_big p
  | INT n ->
      advance p;
      mk (Int n) start p
  | FLOAT f ->
      advance p;
      mk (Float f) start p
  | STR s ->
      advance p;
      mk (Str s) start p
  | BYTES s ->
      (* `b"\r\n"` is `"\r\n".bytes()`, its literal holding the bytes:
         a static owner natively, as a `Str` literal is, since `bytes()`
         is the same value (Ast.bytes_literals) *)
      advance p;
      let lit = mk (Str s) start p in
      let f = mk (Field (lit, { name = "bytes"; loc = lit.loc })) start p in
      mk (Call (f, [])) start p
  | STR_HEAD s ->
      (* an interpolated string: its text, then each hole's expression and
         the text after it (lexer.ml, [lex_string]) *)
      advance p;
      let rec pieces acc =
        let e = parse_expr p in
        match peek p with
        | STR_MID t ->
            advance p;
            pieces (Lit t :: Hole e :: acc)
        | STR_TAIL t ->
            advance p;
            List.rev (Lit t :: Hole e :: acc)
        | _ -> fail_expected p "the `}` that ends the hole"
      in
      let ps = pieces [ Lit s ] in
      mk (Interp ps) start p
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
      | LBRACE -> parse_record p start (Some (`Type t))
      | DOT when
          (match peek2 p with
          | IDENT n -> not (is_upper n)
          | YIELD -> true
          | _ -> false)
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
          (* `Doc.Call.Edit`: a case of a dependency's `D.Call`, whose
             type is named `Doc.Call` (compiler.md, "Services stage",
             "`D.Call`") *)
          let c = calls_case p c in
          match peek p with
          | LPAREN -> con_args p start c
          | LBRACE ->
              (* `Shape.Rect { w: 2, h: 3 }`, a by-name constructor *)
              parse_record p start (Some (`Ctor c))
          | _ -> mk (Con (c, [])) start p)
      | LPAREN when t.tmod <> None ->
          (* `kv.Kv(cfg)`: another module's service installed, a call of
             what it's made, as `kv.f(x)` is (resolve.ml, "Services") *)
          let m = Option.get t.tmod in
          let v = node p (Var (Bare m.name)) m.loc in
          mk (Field (v, t.tid)) start p
      | _ when t.tmod <> None ->
          let m = Option.get t.tmod in
          let v = node p (Var (Bare m.name)) m.loc in
          mk (Field (v, t.tid)) start p
      | LPAREN -> con_args p start { qual = None; name = t.tid }
      | _ -> mk (Con ({ qual = None; name = t.tid }, [])) start p)
  | IDENT name ->
      advance p;
      mk (Var (Bare name)) start p
  | SELF ->
      advance p;
      mk (Var (Bare "self")) start p
  | BREAK ->
      advance p;
      mk Break start p
  | TODO ->
      advance p;
      mk Todo start p
  | LPAREN when peek2 p = RPAREN ->
      advance p;
      advance p;
      mk Unit start p
  | LBRACE -> parse_record p start None
  | LBRACKET ->
      advance p;
      let xs = sep_list p ~close:RBRACKET parse_expr in
      mk (Array xs) start p
  | LPAREN -> (
      advance p;
      let e = parse_expr p in
      match peek p with
      | COMMA ->
          (* a tuple, `(k, v)` *)
          advance p;
          let xs = e :: sep_list p ~close:RPAREN parse_expr in
          tuple_size (Loc.span start (last_loc p)) (List.length xs);
          mk (Tuple xs) start p
      | _ ->
          expect p RPAREN;
          e)
  | IF -> parse_if p
  | MATCH -> parse_match p
  | WITH -> parse_with p
  | FN -> parse_lambda p
  | HANDLER when peek2 p = FN ->
      (* an inline handler, `handler fn(req) => ...` (foundations.md,
         decision 3) *)
      let start = loc p in
      advance p;
      let lam = parse_lambda p in
      mk (Inline_handler lam) start p
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
  let params = sep_list p ~close:RPAREN parse_lambda_param in
  expect p FATARROW;
  let body = parse_body p in
  (* a name bound twice, by two parameters or by parts of tuples, as
     Resolve reports two parameters of one name: here, where there's a
     tuple, since its parts are bound by a `let`, which could have the
     name of a parameter *)
  let rec names (pat : pattern) =
    match pat.pkind with
    | PVar x -> [ x ]
    | PAs (q, x) -> names q @ [ x ]
    | PTuple ps | PCon (_, ps) -> List.concat_map names ps
    | POr (q :: _) -> names q
    | PRecord (_, fs) | PCon_named (_, fs) ->
        List.concat_map (fun (_, q) -> names q) fs.fpats
    | _ -> []
  in
  let bound =
    List.concat_map
      (fun ((param : param), take) ->
        match take with
        | Some (Let_pattern { pat; _ }) -> names pat
        | _ -> [ param.pname ])
      params
  in
  (if List.exists (fun (_, take) -> take <> None) params then
     let seen = Hashtbl.create 8 in
     List.iter
       (fun (x : ident) ->
         match Hashtbl.find_opt seen x.name with
         | Some first ->
             Diag.error x.loc ~help:"rename one of them"
               ~labels:
                 [ (first, Printf.sprintf "the first `%s` is here" x.name) ]
               (Printf.sprintf "there are two parameters named `%s`" x.name)
         | None -> Hashtbl.replace seen x.name x.loc)
       bound);
  (* each tuple is taken apart at the start of the body, first to last *)
  let lets = List.filter_map snd params in
  let body = if lets = [] then body else node p (Block (lets, body)) body.loc in
  mk (Lambda (List.map fst params, body)) start p

(* A lambda's parameter: a name, as a function's is, or a tuple or a
   record taken apart, `fn((k, v)) => ...`, `fn({ qty, .. }) => ...`,
   with or without its type written. A tuple or a record is a parameter with a name no program can write, and a `let` that
   takes it apart at the start of the body, `fn(p) => let (k, v) = p`,
   which is checked and lowered as any `let` is: the parameter, and that
   `let`, if there is one. *)
and parse_lambda_param p =
  match peek p with
  | LPAREN | LBRACE -> lambda_pattern p
  | IDENT x when is_upper x || at_module_type p -> lambda_pattern p
  | AMP ->
      (* `fn(&lo, &hi) => ...`: one the block changes, written as a call
         passes it (compiler.md, "Blocks with `inout` parameters") *)
      advance p;
      let param = parse_param p in
      if param.pmode = Inout then
        Diag.error (loc p) ~help:"write `&` alone"
          "a block's parameter that it changes is written `&n`";
      ({ param with pmode = Inout }, None)
  | INOUT ->
      advance p;
      let name =
        match peek p with IDENT n -> n | SELF -> "self" | _ -> "n"
      in
      Diag.error (loc p)
        ~help:(Printf.sprintf "write `fn(&%s) => ...`" name)
        (Printf.sprintf "a block's parameter that it changes is written `&%s`"
           name)
  | _ -> (parse_param p, None)

(* A lambda's parameter that takes a tuple or a record apart. *)
and lambda_pattern p =
  let pat = parse_pattern p in
  let pty =
    if peek p = COLON then (
      advance p;
      Some (parse_ty p))
    else None
  in
  (* `$` starts no name a program writes, and the pattern's node is
     its own, so no two parameters share a name *)
  let pname = { name = Printf.sprintf "$%d" pat.pnode; loc = pat.ploc } in
  let value = node p (Var (Bare pname.name)) pat.ploc in
  ({ pname; pty; pmode = Read; pblock = Ordinary; pdefault = None },
   Some (Let_pattern { pat; value; else_ = None }))

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

(* A record literal, `User { id: 1 }`, or an update, `{ ..order, status:
   Paid }`: `..` and the value it takes the rest from, first and once,
   then the fields (compiler.md, "Data stage", "The grammar"). [name] is
   what's written before the `{`, if anything: a type, which Resolve may
   find is a by-name constructor, or a constructor after its type,
   `Shape.Rect { ... }`. *)
and parse_record p start name =
  expect p LBRACE;
  (* `..e`, where [at] is the `..`: [e], and how it's written *)
  let rest at =
    advance p;
    match peek p with
    | RBRACE | COMMA ->
        Diag.error at
          ~help:
            "write the value after it, `{ ..o, paid: true }`, or leave it out"
          "`..` in a value takes the rest from another, so it needs one"
    | _ ->
        let i = p.i in
        let e = parse_expr p in
        (e, ".." ^ spelled p i (p.i - 1))
  in
  (* a field, which is never a second `..` *)
  let field ~base p =
    match peek p with
    | DOTDOT -> (
        let at = loc p in
        let _, shown = rest at in
        match base with
        | Some _ ->
            Diag.error
              (Loc.span at (last_loc p))
              ~help:"keep one `..`, and write the other's fields"
              "a record takes the rest from one value"
        | None ->
            Diag.error
              (Loc.span at (last_loc p))
              ~help:(Printf.sprintf "move it to the front: `{ %s, ... }`" shown)
              (Printf.sprintf "`%s` comes first, before the fields" shown))
    | _ -> parse_field_init p
  in
  match peek p with
  | DOTDOT ->
      let base, _ = rest (loc p) in
      let fields =
        match peek p with
        | COMMA ->
            advance p;
            sep_list p ~close:RBRACE (field ~base:(Some base))
        | _ ->
            expect p RBRACE;
            []
      in
      let target =
        match name with
        | Some (`Type t) -> Some (Into_type t)
        | Some (`Ctor c) -> Some (Into_ctor c)
        | None -> None
      in
      mk (Update { target; base; fields }) start p
  | _ -> (
      let fields = sep_list p ~close:RBRACE (field ~base:None) in
      match name with
      | Some (`Ctor c) -> mk (Con_named (c, fields)) start p
      | Some (`Type t) -> mk (Record (Some t, fields)) start p
      | None -> mk (Record (None, fields)) start p)

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
  if peek p = LET then (
    (* the pattern and the value, for the help *)
    let at = loc p in
    advance p;
    let pat = parse_pattern p in
    expect p EQ;
    let value = parse_expr p in
    let shown =
      match value.kind with Var (Bare x) -> x | _ -> "..."
    in
    Diag.error at
      ~help:
        (Printf.sprintf "write a `match`, or `let %s = %s else ...`"
           (show_pattern pat) shown)
      "Ren has no `if let`");
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

(* `with a, b in body`: a set of items, each installed once around the
   body (handlers.md, "A `with` is a set"). An item is an implementation,
   or a chain of them joined by `over`, the top first,
   which can end in the names of the dependencies its bottom goes over,
   `slow_clock(2) over Clock` ([parse_with_item]). *)
and parse_with p =
  let start = loc p in
  expect p WITH;
  let rec items acc =
    let item = parse_with_item p in
    if peek p = COMMA then (
      advance p;
      if peek p = NEWLINE || peek p = DEDENT then
        Diag.error (loc p)
          ~help:
            "indent the next item further than the line the `with` is on, and \
             it goes on with the list"
          "the line ends in `,`, but the next item isn't indented under it";
      items (item :: acc))
    else List.rev (item :: acc)
  in
  let items = items [] in
  if peek p <> IN then
    Diag.error (loc p)
      ~help:
        "write what it installs, then `in`, then the code it's installed around"
      (Printf.sprintf
         "expected `,`, `over`, `as` or `in` after what `with` installs, found \
          %s"
         (describe (peek p)));
  advance p;
  let body = parse_body p in
  node p (With { items; body }) (Loc.span start body.loc)

(* An item of a `with`, or of a group's (ast.ml, [with_item]):

     witem := expr {"over" expr} ["over" deps] ["as" dep]
     deps  := tyname {"&" tyname}
     dep   := tyname ["<" type, ... ">"]

   After `over`, a dependency's name with nothing after it that makes it
   an expression, a `.`, `(` or `{`, is what's installed outside the
   `with`: `over Clock`, `over A & B`. `over Clock.frozen(t)` is an
   implementation. Each link gets a node id of its
   own, for what inference finds it installs. *)
and parse_with_item p : Parsed.with_item =
  let start = loc p in
  let link () =
    let link = parse_orelse p in
    p.node <- p.node + 1;
    { link; knode = p.node }
  in
  (* a dependency's name, `Clock` or `store.Users`, that isn't the start
     of an expression *)
  let at_deps () =
    let after k = fst p.toks.(min (p.i + k) (Array.length p.toks - 1)) in
    let ends = function DOT | LPAREN | LBRACE -> false | _ -> true in
    match (peek p, peek2 p, peek3 p) with
    | IDENT t, next, _ when is_upper t -> ends next
    | IDENT m, DOT, IDENT t when (not (is_upper m)) && is_upper t ->
        ends (after 3)
    | _ -> false
  in
  let rec chain acc =
    if peek p = OVER then (
      advance p;
      if at_deps () then (
        let rec deps acc =
          let d = parse_dep_ref p in
          if peek p = AMP then (
            advance p;
            deps (d :: acc))
          else List.rev (d :: acc)
        in
        let under = deps [] in
        if peek p = OVER then
          Diag.error (loc p)
            ~help:
              "put it under the last implementation, before the dependency's \
               name"
            "nothing goes under what's installed outside the `with`";
        (List.rev acc, under))
      else chain (link () :: acc))
    else (List.rev acc, [])
  in
  let top = link () in
  let chain, under = chain [ top ] in
  (* what it's installed as: `with queue() as Jobs` *)
  let alias =
    if peek p = AS then (
      advance p;
      Some (parse_dep_ref p))
    else None
  in
  { chain; under; alias; iloc = Loc.span start (last_loc p); from = [] }

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

(* A function's or a handler's type parameters, `<T, U>`, each of which
   can say what it needs, `<T has eq, ord>` (operators.md, "Generic
   code"): the parameters, and each one's name with each requirement. *)
let parse_tparams p =
  if peek p = LT then (
    advance p;
    let needs = ref [] in
    let param p =
      let t = upper_ident p "a type parameter" in
      if peek p = IDENT "has" then (
        advance p;
        let rec reqs () =
          needs :=
            !needs @ [ (t.name, lower_ident p "a requirement, like `eq`") ];
          (* a comma goes on with another requirement, unless what's after
             it is a type parameter's name *)
          match (peek p, peek2 p) with
          | COMMA, IDENT n when not (is_upper n) ->
              advance p;
              reqs ()
          | _ -> ()
        in
        reqs ());
      t
    in
    let ts = sep_list p ~close:GT param in
    (ts, !needs))
  else ([], [])

let parse_fn p ~pub =
  let start = loc p in
  let fn_kind =
    (* `gen` remains an ordinary module, function or local name elsewhere. *)
    if peek p = IDENT "gen" then (
      advance p;
      Generator_fn start)
    else Ordinary_fn
  in
  expect p FN;
  let name = lower_ident p "a function's name" in
  let tparams, tneeds = parse_tparams p in
  expect p LPAREN;
  let params = sep_list p ~close:RPAREN parse_param in
  p.tags <-
    List.filter_map
      (fun (q : param) ->
        match q.pty with
        | Some (TyName ({ tmod = None; tid = { name = "Tags"; _ } }, [])) ->
            Some q.pname.name
        | _ -> None)
      params;
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
    fn_kind;
    pub;
    name;
    tparams;
    tneeds;
    params;
    ret;
    errors;
    uses;
    body;
    owner = None;
    overload = 0;
    test = false;
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
  | FN | IDENT "gen" -> Some { op_kind = Op_fn; op_fn = parse_fn p ~pub }
  | TEST ->
      Diag.error (loc p)
        ~help:"declare it at the top level: `test fn name(...)`"
        "a member can't be a test item"
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
              fn_kind = Ordinary_fn;
              pub;
              name;
              tparams = [];
              tneeds = [];
              params = [];
              ret;
              errors = None;
              uses = None;
              body;
              owner = None;
              overload = 0;
              test = false;
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
      (* the old way to write an operator: now it's a method with a
         reserved name, or an associated value (operators.md) *)
      let help =
        match (params, name.name) with
        | [], n -> Printf.sprintf "write `pub let %s: %s = ...`" n tname
        | _, "neg" ->
            Printf.sprintf "write `pub fn neg(self) -> %s = ...`" tname
        | _, n ->
            Printf.sprintf "write `pub fn %s(self, b: %s) -> %s = ...`" n tname
              tname
      in
      Diag.report p.sink
        (Diag.make name.loc ~help
           (if params = [] then "an associated value is written with `let`"
            else "an operator is a method"));
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

(* The members [ops] of the type [type_name], each knowing whose it is,
   and which of the members of its name it is (Ast.fn_def's [overload]). *)
let owned_by type_name ops =
  let rec go seen = function
    | [] -> []
    | o :: rest ->
        let name = o.op_fn.name.name in
        let overload = List.length (List.filter (( = ) name) seen) in
        { o with op_fn = { o.op_fn with owner = Some type_name; overload } }
        :: go (name :: seen) rest
  in
  go [] ops

let parse_type ~prelude p ~pub =
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
  let defaults = ref [] in
  let default case p (field : ident) field_ty =
    let body = parse_expr p in
    let name = "$default:" ^ Option.fold ~none:"" ~some:(fun c -> c ^ ".") case ^ field.name in
    defaults :=
      { op_kind = (if type_params = [] then Op_value else Op_fn);
        op_fn =
          { pub = true; fn_kind = Ordinary_fn; name = { field with name }; tparams = []; tneeds = [];
            params = []; ret = Some field_ty;
            errors = Some { errs = []; etail = None; eloc = field.loc };
            uses = Some { deps = []; dtail = None; uloc = field.loc };
            body; owner = None; overload = 0; test = false; loc = body.loc } }
      :: !defaults;
    name
  in
  let type_body, type_ops =
    if peek p = INDENT then (
      (* the body indented under `type X =`, and its members on the lines
         after it, at the same indentation *)
      advance p;
      let b = parse_type_body ~default ~prelude p in
      let members =
        if peek p = NEWLINE then (
          advance p;
          parse_members p ~tname)
        else []
      in
      expect p DEDENT;
      (b, members))
    else
      let b = parse_type_body ~default ~prelude p in
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
  {
    type_pub = pub;
    type_name;
    type_params;
    type_body;
    type_ops = owned_by type_name (List.rev !defaults @ type_ops);
  }

(* A dependency (deps.md, "Declaring one"): its operations, indented under
   it, then its members, as a sum type lists its variants first. One can
   take type parameters, as a type does; and an alias names an instance of
   another, at its types (compiler.md, "Generic dependencies").

     pub dep Clock =
       now: fn() -> Time
       sleep: fn(d: Duration)

       pub fn frozen(at: Time) -> Clock = ...

     dep Chan<T> =
       send: fn(x: T)

     dep Jobs = Chan<Job> *)
let rec parse_dep ?(prelude = false) p ~pub =
  expect p DEP;
  let type_name = upper_ident p "a dependency's name" in
  (* a generic one's type parameters, `dep Chan<T> =` *)
  let at_params = loc p in
  let type_params =
    if peek p = LT then (
      advance p;
      sep_list p ~close:GT (fun p -> upper_ident p "a type parameter"))
    else []
  in
  expect p EQ;
  if peek p <> INDENT && at_dep_name p then (
    (* an alias, `dep Jobs = Chan<Job>`: a dependency of its own, with the
       operations of the one it names at those types *)
    let target = parse_dep_ref p in
    (* `dep Docs = Actors<DocId, Doc> ! StoreDown`: what making the
       dependency its last type argument names fails with, the errors of
       making an actor, written after the alias as a dependency's are
       (compiler.md, "Services stage", "Actors (step 7)"). It's that
       argument's, an implementation of `Doc` that fails to start so,
       `(Doc ! StoreDown)` *)
    let target =
      if peek p <> BANG then target
      else
        let errs = parse_errors p in
        match List.rev target.dargs with
        | TyName (d, args) :: before ->
            {
              target with
              dargs =
                List.rev
                  (TyImpl
                     {
                       impl_deps = [ { dep = d; dargs = args } ];
                       impl_over = false;
                       impl_errors = Some errs;
                       impl_uses = None;
                       impl_loc = errs.eloc;
                     }
                  :: before);
            }
        | _ ->
            Diag.error errs.eloc
              ~help:
                "give it the dependency it keeps last, `Actors<DocId, Doc> ! \
                 StoreDown`"
              "an alias fails only as making the dependency its last type \
               argument names does"
    in
    if type_params <> [] then
      Diag.error at_params
        ~help:
          (Printf.sprintf
             "use `%s` itself where it's generic, or fix the alias's types: \
              `dep Ints = %s`"
             (show_dep target)
             (show_dep
                {
                  target with
                  dargs =
                    List.map
                      (fun _ ->
                        TyName
                          ( {
                              tmod = None;
                              tid = { type_name with name = "Int" };
                            },
                            [] ))
                      target.dargs;
                }))
        "an alias can't take type parameters";
    {
      type_pub = pub;
      type_name;
      type_params = [];
      type_body = Dep_alias target;
      type_ops = [];
    })
  else parse_dep_ops ~prelude p ~pub ~type_name ~type_params

(* Whether what's next is a dependency's name, `Chan` or `store.Users`,
   which an alias names. *)
and at_dep_name p =
  match (peek p, peek2 p, peek3 p) with
  | IDENT t, _, _ when is_upper t -> true
  | IDENT m, DOT, IDENT t -> (not (is_upper m)) && is_upper t
  | _ -> false

(* A dependency's operations, indented under it, and its members. Only
   the prelude's source writes one with members and no operations, the
   runtime's `Instances`, which nothing installs (compiler.md, "Services
   stage", "The keyed instance family"). *)
and parse_dep_ops ?(prelude = false) p ~pub ~(type_name : ident) ~type_params =
  let tname = type_name.name in
  if peek p <> INDENT then
    Diag.error (loc p)
      ~help:
        "put each of its operations on a line of its own, indented under it, \
         like `now: fn() -> Time`"
      (Printf.sprintf "expected the operations of `%s`, found %s" tname
         (describe (peek p)));
  advance p;
  let at_op p =
    match (peek p, peek2 p) with (IDENT _ | YIELD), COLON -> true | _ -> false
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
    let defaults = ref [] and names = ref [] in
    p.op_defaults <- Some defaults;
    p.op_params <- Some names;
    let field_ty =
      Fun.protect
        ~finally:(fun () ->
          p.op_defaults <- None;
          p.op_params <- None)
        (fun () -> parse_ty p)
    in
    {
      field_name;
      field_ty;
      field_default = None;
      field_default_member = None;
      op_defaults = !defaults;
      op_params = !names;
    }
  in
  let none = prelude && not (at_op p) in
  if not (at_op p || none) then
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
  let ops = if none then [] else ops [] in
  (* the loop stopped after the line break before a member, if there is one *)
  let members =
    if peek p = DEDENT then [] else parse_members ~dep:true p ~tname
  in
  expect p DEDENT;
  {
    type_pub = pub;
    type_name;
    type_params;
    type_body = Dep ops;
    type_ops = owned_by type_name members;
  }

(* A handler (deps.md, "Implementations"): a function of its parameters
   that describes a stateful implementation of the dependencies after
   `for`. Its body, indented under it, is its state, `var`s, `let`s and
   `finally`s, then an arm for each operation:

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
  (* a generic dependency's, `handler queue<T>() for Chan<T>`, each of
     which Resolve checks is one *)
  let tparams, tneeds = parse_tparams p in
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
  if peek p <> FOR && peek p <> OVER then
    Diag.error (loc p)
      ~help:
        (Printf.sprintf
           "say what it implements: `handler %s(...) for Clock =`, or `over \
            Clock` to go in front of another `Clock`"
           name.name)
      (Printf.sprintf
         "expected `for` or `over` and the dependencies it implements, found %s"
         (describe (peek p)));
  (* `for A, B` implements each of them; `over A & B` goes over another
     implementation of them, as a handler of several's type is written;
     `over any` goes over any one dependency (foundations.md, decision 7) *)
  let over = peek p = OVER in
  advance p;
  let any = over && peek p = IDENT "any" in
  if any then advance p;
  let rec deps acc =
    let d = parse_dep_ref p in
    match peek p with
    | COMMA when not over ->
        advance p;
        deps (d :: acc)
    | AMP when over ->
        advance p;
        deps (d :: acc)
    | COMMA ->
        Diag.error (loc p)
          ~help:(Printf.sprintf "write `over %s`" (written " & " (d :: acc)))
          "a handler over several dependencies joins them with `&`, as the \
           type of a handler of several is written"
    | AMP ->
        Diag.error (loc p)
          ~help:(Printf.sprintf "write `for %s`" (written ", " (d :: acc)))
          "after `for`, the dependencies a handler implements are separated by \
           commas"
    | (FOR | OVER) as t ->
        (* `for A over B`: it implements them all, or goes over them all *)
        let all =
          String.concat
            (if over then " & " else ", ")
            (List.rev_map show_dep (d :: acc))
        in
        Diag.error (loc p)
          ~notes:
            [ "a handler is `for` all its dependencies, or `over` all of them" ]
          ~help:
            (Printf.sprintf
               "write `handler %s(...) %s %s`, and another handler `%s %s`"
               name.name
               (if over then "over" else "for")
               all
               (if t = OVER then "over" else "for")
               (match peek2 p with IDENT n -> n | _ -> "the others"))
          (Printf.sprintf
             "a handler %s some dependencies can't also be %s others"
             (if over then "over" else "for")
             (if t = OVER then "over" else "for"))
    | _ -> List.rev (d :: acc)
  (* the dependencies so far, [acc] reversed, and the one after the
     wrong separator, if it's a name, joined by [sep] *)
  and written sep acc =
    let after = match peek2 p with IDENT n -> [ n ] | _ -> [] in
    String.concat sep (List.rev_map show_dep acc @ after)
  in
  let deps = if any then [] else deps [] in
  (* what installing it can fail with, which its state and `finally` can
     (handlers.md, "State that can fail to start") *)
  let fails = if peek p = BANG then Some (parse_errors p) else None in
  let needs =
    if peek p = USES then Some (parse_uses ~greedy:true p)
    else if peek p = NEWLINE && peek2 p = USES then
      Diag.error ~help:"indent it, so it continues the signature"
        (snd p.toks.(p.i + 1))
        "`uses` on a line of its own has to be indented"
    else None
  in
  let body_start = loc p in
  (match peek p with
  | IDENT "forwards" ->
      (* the README's early sketch, `for Users forwards` *)
      Diag.error (loc p)
        ~help:
          (Printf.sprintf
             "declare it `handler %s(...) over %s`: the operations it leaves \
              out go to the one under it, which it calls with `next`"
             name.name
             (String.concat " & " (List.map show_dep deps)))
        "a handler that passes on what it doesn't implement goes `over` it, \
         not `forwards`"
  | _ -> ());
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
    | LET | VAR | FINALLY ->
        let s = parse_stmt p in
        if next_line () then state (s :: acc) else (List.rev (s :: acc), false)
    | _ -> (List.rev acc, true)
  in
  let state, more = state [] in
  let arm p =
    match (peek p, peek2 p) with
    | (IDENT _ | YIELD), (LPAREN | DOT) ->
        let arm_start = loc p in
        (* `Console.write(line) => ...` says which dependency's, where two
           it implements have an operation of that name *)
        let dep =
          if peek2 p = DOT then (
            let d = ident p in
            advance p;
            Some { tmod = None; tid = d })
          else None
        in
        let arm_name = ident p in
        expect p LPAREN;
        let params = sep_list p ~close:RPAREN parse_param in
        expect p FATARROW;
        let body = parse_body p in
        {
          arm_op =
            (match dep with
            | Some d -> Item (d, arm_name)
            | None -> Bare arm_name.name);
          arm_name;
          arm_impl = mk (Lambda (params, body)) arm_start p;
        }
    | (IDENT _ | YIELD), FATARROW ->
        (* `call => ...`, the one arm of a handler `over any`, which runs
           for every operation, and names what it's given (Resolve checks
           it's in one) *)
        let arm_start = loc p in
        let arm_name = ident p in
        expect p FATARROW;
        let body = parse_body p in
        let param =
          { pname = arm_name; pty = None; pmode = Read; pblock = Ordinary; pdefault = None }
        in
        {
          arm_op = Bare arm_name.name;
          arm_name;
          arm_impl = mk (Lambda ([ param ], body)) arm_start p;
        }
    | (LET | VAR), _ ->
        Diag.error (loc p) ~help:"move it above the handler's first operation"
          "a handler's state comes first, before its operations"
    | FINALLY, _ ->
        Diag.error (loc p)
          ~notes:
            [
              "a `finally` covers what comes after it: the state below it, and \
               the body of each `with` that installs the handler";
            ]
          ~help:"move it above the handler's first operation"
          "a handler's `finally` is among its state, before its operations"
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
      (Handler { deps; over; any; fails; needs; state; arms })
      (Loc.span body_start (last_loc p))
  in
  {
    fn_kind = Ordinary_fn;
    pub;
    name;
    tparams;
    tneeds;
    params;
    ret = None;
    errors = None;
    uses = None;
    body;
    owner = None;
    overload = 0;
    test = false;
    loc = Loc.span start (last_loc p);
  }

(* ---- tests ---- *)

(* A test (deps.md, "Tests"): its name, a string, and the built-in
   dependencies whose real implementation it asks for.

     test "the system clock moves" uses Clock =
       body *)
let parse_test p =
  expect p TEST;
  let test_name, test_loc =
    match peek p with
    | STR s ->
        let l = loc p in
        advance p;
        (s, l)
    | PUB ->
        (* `test pub fn`: a public test item is written `pub test fn` *)
        Diag.error (loc p)
          ~help:"write `pub` first: `pub test fn ...`, `pub test handler ...`"
          "`pub` goes before `test`"
    | tok ->
        Diag.error (loc p)
          ~help:"name it with a string, saying what it checks: `test \"...\" =`"
          (Printf.sprintf "expected the test's name, a string, found %s"
             (describe tok))
  in
  let test_uses =
    if peek p = USES then Some (parse_uses ~greedy:true p)
    else if peek p = NEWLINE && peek2 p = USES then
      Diag.error ~help:"indent it, so it continues the test's first line"
        (snd p.toks.(p.i + 1))
        "`uses` on a line of its own has to be indented"
    else None
  in
  if peek p <> EQ then
    Diag.error (loc p) ~help:"write `=`, then the test's body"
      (Printf.sprintf "expected `=` after the test's name, found %s"
         (describe (peek p)));
  advance p;
  let test_body = parse_body p in
  { test_name; test_loc; test_uses; test_body }

(* A group (deps.md, "Groups"): a function of its parameters, whose tests
   each run inside its `with`,

     pub group clock_conforms(c: Clock) with c =
       test "instant never goes backwards" =
         ...

   or a run of one, with its arguments, under a label:

     group "frozen" = clock_conforms(Clock.frozen(Time.epoch)) *)
let parse_group p ~pub =
  expect p GROUP;
  match peek p with
  | STR run_label ->
      let run_loc = loc p in
      if pub then
        Diag.error run_loc
          ~help:"remove the `pub`: a `pub group` is one other modules can run"
          "a group's run can't be `pub`";
      advance p;
      if peek p <> EQ then
        Diag.error (loc p)
          ~help:"write `=`, then the group it runs: `group \"...\" = g(...)`"
          (Printf.sprintf "expected `=` after the group's label, found %s"
             (describe (peek p)));
      advance p;
      let run_call = parse_expr p in
      (match run_call.kind with
      | Call _ -> ()
      | _ ->
          Diag.error run_call.loc
            ~help:"call the group with its arguments: `g(...)`"
            "a group's run calls a group, with the arguments for its tests");
      Testing (Run_group { run_label; run_loc; run_call })
  | _ ->
      let group_name = lower_ident p "a group's name" in
      if peek p <> LPAREN then
        Diag.error (loc p)
          ~help:
            (Printf.sprintf
               "write its parameters, `group %s() =`, even if it has none"
               group_name.name)
          (Printf.sprintf "expected `(` after the group's name, found %s"
             (describe (peek p)));
      advance p;
      let group_params = sep_list p ~close:RPAREN parse_param in
      let group_with =
        if peek p = WITH then (
          advance p;
          let rec items acc =
            let item = parse_with_item p in
            if peek p = COMMA then (
              advance p;
              items (item :: acc))
            else List.rev (item :: acc)
          in
          items [])
        else []
      in
      if peek p <> EQ then
        Diag.error (loc p)
          ~help:
            "write `=`, then its tests, indented under it; `with` before the \
             `=` installs something around each one"
          (Printf.sprintf
             "expected `with` or `=` after the group's parameters, found %s"
             (describe (peek p)));
      advance p;
      if peek p <> INDENT then
        Diag.error (loc p)
          ~help:"put its tests on the lines after it, indented under it"
          (Printf.sprintf "expected the tests of the group `%s`, found %s"
             group_name.name
             (describe (peek p)));
      advance p;
      let test p =
        if peek p <> TEST then
          Diag.error (loc p)
            ~help:"move it out of the group: a group holds only tests"
            (Printf.sprintf "expected a test, `test \"...\" =`, found %s"
               (describe (peek p)));
        parse_test p
      in
      let rec tests acc =
        let t = test p in
        match peek p with
        | NEWLINE ->
            advance p;
            tests (t :: acc)
        | DEDENT ->
            advance p;
            List.rev (t :: acc)
        | _ -> fail_expected p "the end of the line"
      in
      let group_tests = tests [] in
      Testing
        (Group
           {
             group_pub = pub;
             group_name;
             group_params;
             group_with;
             group_tests;
           })

(* A wiring (language.md §5): `wiring live(url: Str) provides Users uses
   Console ! DbDown = pg_db(url), console_audit(), db_users()`. `wiring`
   is a word only at the start of an item, before a name, and `provides`
   only after its parameters, so neither is reserved. Its body is `with`
   items, on the line after the `=` if they're indented under it: code
   that runs around a block stays a function. *)
let parse_wiring p ~pub =
  let start = loc p in
  advance p;
  let wname = lower_ident p "a wiring's name" in
  let wparams =
    if peek p = LPAREN then (
      advance p;
      sep_list p ~close:RPAREN parse_param)
    else []
  in
  if peek p <> IDENT "provides" then
    Diag.error (loc p)
      ~help:"write `provides` and the dependencies the body may call"
      "a wiring says what it provides";
  advance p;
  let rec provides acc =
    let d = parse_dep_ref p in
    if peek p = COMMA then (
      advance p;
      provides (d :: acc))
    else List.rev (d :: acc)
  in
  let provides = provides [] in
  let not_items at =
    Diag.error at
      ~help:
        (Printf.sprintf
           "code that runs around a block stays a function: `fn %s(body: fn() \
            -> T) -> T`"
           wname.name)
      "a wiring's body lists what it installs"
  in
  (* as a handler's signature: what it needs, then what it fails with,
     each of which may start a line of its own, indented *)
  let wuses =
    if peek p = USES then Some (parse_uses ~greedy:true p) else None
  in
  let werrors = if peek p = BANG then Some (parse_errors p) else None in
  let wuses =
    if wuses = None && peek p = USES then Some (parse_uses ~greedy:true p)
    else wuses
  in
  if peek p <> EQ then
    Diag.error (loc p)
      ~help:"write `=`, then what it installs, as a `with` lists it"
      (Printf.sprintf
         "expected `uses`, `!` or `=` after what a wiring provides, found %s"
         (describe (peek p)));
  advance p;
  let indented = peek p = INDENT in
  if indented then advance p;
  (match peek p with
  | LET | VAR | WHILE | FOR | IF | MATCH | WITH -> not_items (loc p)
  | _ -> ());
  let rec items acc =
    let item = parse_with_item p in
    if peek p = COMMA then (
      advance p;
      items (item :: acc))
    else List.rev (item :: acc)
  in
  let witems = items [] in
  if indented then (
    (* a second line that isn't after a `,` is a statement: a body *)
    if peek p = NEWLINE then not_items (loc p);
    if peek p <> DEDENT then fail_expected p "the end of the wiring";
    advance p);
  {
    wpub = pub;
    wname;
    wparams;
    provides;
    wuses;
    werrors;
    witems;
    wloc = Loc.span start (last_loc p);
  }

(* A service (language.md §4): `service Kv(c: ClientCfg) uses Http ! E =`,
   then its members, each a function on a line of its own, indented
   under it. `service` is a word only at the start of an item, before a
   capitalized name, so it isn't reserved. What a member may write is
   Resolve's to check, so a member that writes `uses` is reported with
   the rest (resolve.ml, "Services"). *)
let parse_service p ~pub =
  let start = loc p in
  advance p;
  let sname = upper_ident p "a service's name" in
  if peek p <> LPAREN then
    Diag.error (loc p)
      ~help:
        (Printf.sprintf
           "write its parameters, `service %s() =`, even if it has none"
           sname.name)
      (Printf.sprintf "expected `(` after the service's name, found %s"
         (describe (peek p)));
  advance p;
  let sparams = sep_list p ~close:RPAREN parse_param in
  (* as a handler's signature: what it needs, then what it fails to
     start with, each of which may start a line of its own, indented *)
  let suses =
    if peek p = USES then Some (parse_uses ~greedy:true p) else None
  in
  let serrors = if peek p = BANG then Some (parse_errors p) else None in
  let suses =
    if suses = None && peek p = USES then Some (parse_uses ~greedy:true p)
    else suses
  in
  if peek p <> EQ then
    Diag.error (loc p)
      ~help:"write `=`, then its functions, indented under it"
      (Printf.sprintf
         "expected `uses`, `!` or `=` after a service's parameters, found %s"
         (describe (peek p)));
  advance p;
  if peek p <> INDENT then
    Diag.error (loc p)
      ~help:
        "put each of its functions on a line of its own, indented under it, \
         like `pub fn get(k: Key) -> Str = ...`"
      (Printf.sprintf "expected the functions of the service `%s`, found %s"
         sname.name
         (describe (peek p)));
  advance p;
  (* its state first, `let`s, `var`s and `finally`s, as a handler's *)
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
    | LET | VAR | FINALLY ->
        let st = parse_stmt p in
        if next_line () then state (st :: acc) else (List.rev (st :: acc), false)
    | _ -> (List.rev acc, true)
  in
  let sstate, more = state [] in
  let member p =
    let pub = peek p = PUB in
    if pub then advance p;
    match peek p with
    | FN | IDENT "gen" -> parse_fn p ~pub
    | (LET | VAR | FINALLY) when not pub ->
        Diag.error (loc p)
          ~help:"move it above the service's first function"
          "a service's state comes first, before its functions"
    | _ ->
        Diag.error (loc p)
          ~help:
            "write its operations as `pub fn`s, and the functions they share \
             as `fn`s"
          (Printf.sprintf "expected a function of `%s`, found %s" sname.name
             (describe (peek p)))
  in
  let rec members acc =
    let m = member p in
    if next_line () then members (m :: acc) else List.rev (m :: acc)
  in
  let members = if more then members [] else [] in
  {
    spub = pub;
    sname;
    sparams;
    suses;
    serrors;
    sstate;
    members;
    sloc = Loc.span start (last_loc p);
  }

(* Build roots use the ordinary function tree for expression checking. Their
   item kind survives resolution so lowering keeps them apart from runtime
   functions and legacy associated values. *)
let parse_build_root p ~pub ~assertion =
  let start = loc p in
  advance p;
  let name =
    if assertion then
      { name = Printf.sprintf "$assert:%d:%d" start.start.line start.start.col;
        loc = start }
    else ident p
  in
  let ret =
    if not assertion && peek p = COLON then (
      advance p; Some (parse_ty p))
    else None
  in
  if not assertion then expect p EQ;
  let body = parse_body p in
  let body = if assertion then node p (Assert body) (Loc.span start body.loc) else body in
  { pub; fn_kind = Ordinary_fn; name; tparams = []; tneeds = []; params = []; ret;
    errors = None; uses = None; body; owner = None; overload = 0;
    test = false; loc = Loc.span start (last_loc p) }

let parse_item ~prelude p =
  p.node <- 0;
  let pub = peek p = PUB in
  if pub then advance p;
  match peek p with
  | FN | IDENT "gen" -> Fn (parse_fn p ~pub)
  | LET -> Top_value (parse_build_root p ~pub ~assertion:false)
  | ASSERT when pub ->
      Diag.error (loc p) ~help:"remove `pub`" "a top-level assertion cannot be public"
  | ASSERT -> Top_assert (parse_build_root p ~pub:false ~assertion:true)
  | TYPE -> Type (parse_type ~prelude p ~pub)
  | DEP -> Type (parse_dep ~prelude p ~pub)
  | HANDLER -> Fn (parse_handler p ~pub)
  | GROUP -> parse_group p ~pub
  | IDENT "wiring" when (match peek2 p with IDENT _ -> true | _ -> false) ->
      Wiring (parse_wiring p ~pub)
  | IDENT "service"
    when match peek2 p with IDENT n -> is_upper n | _ -> false ->
      Service (parse_service p ~pub)
  | TEST when peek2 p = FN || peek2 p = IDENT "gen" || peek2 p = HANDLER ->
      (* a test item, `test fn` or `test handler`, which only tests see
         (testing.md, "Test items") *)
      advance p;
      let f = if peek p = HANDLER then parse_handler p ~pub else parse_fn p ~pub in
      Fn { f with test = true }
  | TEST when peek2 p = TYPE || peek2 p = DEP || peek2 p = LET ->
      Diag.error (loc p)
        ~help:"make it an ordinary item; a test sees it if it's `pub`"
        "only a function or a handler can be a test item"
  | TEST when pub ->
      Diag.error (loc p)
        ~help:
          "remove the `pub`: to share tests, put them in a `pub group`, which \
           other modules can run"
        "a test can't be `pub`"
  | TEST -> Testing (Test (parse_test p))
  | IMPORT when pub ->
      Diag.error (loc p)
        ~help:"remove the `pub`: a module can't pass on what it imports"
        "an import can't be `pub`"
  | IMPORT -> Import (parse_import p)
  | _ ->
      Diag.error (loc p)
        ~help:
          "only imports, function, type, dependency and handler definitions, \
           tests and groups can appear at the top level (for now)"
        (Printf.sprintf
           "expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found \
            %s"
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

let parse_program ?(prelude = false) sink toks =
  let p = { toks; i = 0; node = 0; sink; tags = []; op_defaults = None; op_params = None } in
  let rec loop acc =
    if peek p = EOF then List.rev acc
    else
      let start = p.i in
      match
        let item = parse_item ~prelude p in
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

(* One line typed into `ren console` (console.ml): a `let`, a `var` or an
   expression, written as a line of a function's body is, which the
   console adds to the function its session is (driver.ml). Its nodes are
   numbered on from [node], the last one the session's earlier lines used,
   so the whole session numbers them once; the last one this line used is
   returned with it. *)
let parse_session_line sink toks ~node =
  let p = { toks; i = 0; node; sink; tags = []; op_defaults = None; op_params = None } in
  let s = parse_stmt p in
  if peek p = NEWLINE then advance p;
  if peek p <> EOF then fail_expected p "the end of the line";
  (s, p.node)

(* A unit, `()`, at [loc], numbered after [node]: the value of a session
   whose last line is a `let`. *)
let session_unit loc ~node : Parsed.expr = { kind = Unit; loc; node = node + 1 }
