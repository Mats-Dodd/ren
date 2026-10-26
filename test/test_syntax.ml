(* Lexing and parsing: layout tokens, the shape of the tree, syntax
   errors. *)

open Helpers

let%expect_test "layout tokens" =
  tokens {|
fn f() =
  let x = 1
  x
fn g() = 2
|};
  [%expect
    {| FN (IDENT "f") LPAREN RPAREN EQ INDENT LET (IDENT "x") EQ (INT 1) NEWLINE (IDENT "x") DEDENT NEWLINE FN (IDENT "g") LPAREN RPAREN EQ (INT 2) EOF |}]

let%expect_test "precedence and associativity" =
  ast {|
fn main() = 1 + 2 * 3 - -4 / 2 < 10 - 3 - 2
|};
  [%expect
    {| (fn main () (< (- (+ 1 (* 2 3)) (/ (neg 4) 2)) (- (- 10 3) 2))) |}]

let%expect_test "chained comparison" =
  ast {|
fn main() = 1 < 2 < 3
|};
  [%expect
    {|
    error: comparisons can't be chained
      ┌─ test.ren:1:19
    1 │ fn main() = 1 < 2 < 3
      │                   ^
      help: split it into two comparisons
    |}]

let%expect_test "not on a comparison's right side" =
  ast {|
fn f() = true == (not false)
fn g() = true == not false
|};
  [%expect
    {|
    error: `not` can't start the right side of a comparison
      ┌─ test.ren:2:18
    2 │ fn g() = true == not false
      │                  ^^^
      help: put it in parentheses: `a == (not b)`
    |}]

let%expect_test "&&, || and not" =
  tokens {|
fn main() = not a && b || c != d
|};
  [%expect
    {| FN (IDENT "main") LPAREN RPAREN EQ NOT (IDENT "a") AMPAMP (IDENT "b") PIPEPIPE (IDENT "c") NEQ (IDENT "d") EOF |}];
  (* `not` binds below the comparisons and above `&&` *)
  ast {|
fn main() = not a == b && c < d || not e && not not f
|};
  [%expect
    {| (fn main () (|| (&& (not (== a b)) (< c d)) (&& (not e) (not (not f))))) |}]

let%expect_test "not can't be a name" =
  ast {|
fn main() =
  let not = 1
  not
|};
  [%expect
    {|
    error: expected a name, found `not`
      ┌─ test.ren:2:7
    2 │   let not = 1
      │       ^^^
    |}]

let%expect_test "block ending in let" =
  ast {|
fn main() =
  let x = 1
|};
  [%expect
    {|
    error: this block ends with a `let`, so it has no value
      ┌─ test.ren:2:7
    2 │   let x = 1
      │       ^
      help: add the value this block should produce as its last line
    |}]

let%expect_test "bad dedent" =
  ast {|
fn main() =
    let x = 1
  x
|};
  [%expect
    {|
    error: this line's indentation doesn't line up with any enclosing block
      ┌─ test.ren:3:3
    3 │   x
      │   ^
      help: indent it to match the lines above it
    |}]

let%expect_test "ast of a type and a match" =
  ast
    {|
type Shape = | Circle(r: Int) | Square(side: Int)
fn area(s: Shape) -> Int =
  match s
    Circle(r) if r > 0 => 3 * r * r
    Square(n) => n * n
    _ => 0
|};
  [%expect
    {|
    (type Shape (Circle r:Int) (Square side:Int))
    (fn area (s) (match s (Circle(r) if (> r 0) => (* (* 3 r) r)) (Square(n) => (* n n)) (_ => 0)))
    |}]

let%expect_test "ast of lambdas and function types" =
  ast
    {|
fn run(f: fn(Int) -> Bool, g: fn(x: Int)) = f(1)
fn main() =
  let h = fn(x, y: Int) => x + y
  run(fn(n) => n > 0) fn(_) =>
    ()
  h(1, 2)(3)
|};
  [%expect
    {|
    (fn run (f g) (call f 1))
    (fn main () (block (let h (lambda (x y:Int) (+ x y))) (call run (lambda (n) (> n 0)) (lambda (_) ())) (call (call h 1 2) 3)))
    |}]

let%expect_test "lambda parse errors" =
  ast {|
fn main() = fn x => x
|};
  [%expect
    {|
    error: expected `(` to start a lambda, found `x`
      ┌─ test.ren:1:16
    1 │ fn main() = fn x => x
      │                ^
      help: functions are defined at the top level; a lambda is `fn(x) => ...`
    |}]

(* Inside brackets, line breaks are ignored, except in a lambda's body:
   a `=>` that ends the line opens a block, if the next line is indented
   further than the block around the brackets. *)

let%expect_test "a lambda's block inside brackets" =
  tokens {|
fn f() =
  R { g: fn(x) =>
      let y = x
      y
  }
|};
  [%expect
    {| FN (IDENT "f") LPAREN RPAREN EQ INDENT (IDENT "R") LBRACE (IDENT "g") COLON FN LPAREN (IDENT "x") RPAREN FATARROW INDENT LET (IDENT "y") EQ (IDENT "x") NEWLINE (IDENT "y") DEDENT RBRACE DEDENT EOF |}];
  (* in a record's field, a call's argument and an array's element; the
     closing bracket closes the block too *)
  ast
    {|
fn main() =
  let r = R { g: fn(x) =>
      let y = x + 1
      y * 2
  }
  let n = apply(fn(x) =>
      match x
        1 => 10
        _ => 20
    , 1)
  [fn(x) =>
    if x then
      1
    else 2]
|};
  [%expect
    {| (fn main () (block (let r (record R g=(lambda (x) (block (let y (+ x 1)) (* y 2))))) (let n (call apply (lambda (x) (match x (1 => 10) (_ => 20))) 1)) (array (lambda (x) (if x 1 2))))) |}]

let%expect_test "a lambda's body on the next line, not indented further" =
  (* it isn't a block, so the line goes on inside the brackets, as before *)
  ast {|
fn main() =
  apply(fn(x) =>
  x + 1, 2)
|};
  [%expect {| (fn main () (call apply (lambda (x) (+ x 1)) 2)) |}]

let%expect_test "a comma after a lambda's block inside brackets ends it" =
  (* the block ends at the `,`, on its last line, and the brackets go on
     with the next field or argument; a `,` in a `with`'s items inside the
     block goes on with the items *)
  ast
    {|
fn main() =
  let r = R {
    f: fn(x) =>
      x + 1,
    g: 2,
  }
  apply(fn(x) =>
        x + 1,
      9)
  apply(fn(x) =>
      x + 3 , 1)
  apply(fn(x) =>
      let y = x * 2
      y,
    2)
  apply(fn(x) =>
      with a(),
          b() in
        x, 1)
|};
  [%expect
    {| (fn main () (block (let r (record R f=(lambda (x) (+ x 1)) g=2)) (call apply (lambda (x) (+ x 1)) 9) (call apply (lambda (x) (+ x 3)) 1) (call apply (lambda (x) (block (let y (* x 2)) y)) 2) (call apply (lambda (x) (with (call a) (with (call b) x))) 1))) |}]

let%expect_test "a line of a lambda's block indented too little" =
  ast {|
fn main() =
  R { f: fn(x) =>
      let y = x + 1
     y * 2
  }
|};
  [%expect
    {|
    error: this line's indentation doesn't line up with the lambda's body above it
      ┌─ test.ren:4:6
    4 │      y * 2
      │      ^
      help: indent it to match the lines above it; to end the lambda there, start the line with `,` or the closing bracket
    |}]

let%expect_test "a with's items wrap after a comma" =
  ast {|
fn main() =
  with a(),
      b(),
    c() in
    body()
|};
  [%expect
    {| (fn main () (with (call a) (with (call b) (with (call c) (call body))))) |}];
  ast {|
fn main() =
  with a(),
  b() in
    body()
|};
  [%expect
    {|
    error: the line ends in `,`, but the next item isn't indented under it
      ┌─ test.ren:3:3
    3 │   b() in
      │   ^
      help: indent the next item further than the line the `with` is on, and it goes on with the list
    |}];
  (* any line outside brackets that ends in `,` goes on, so a signature's
     `uses` list wraps too *)
  types
    {|
fn f() uses Clock,
    Console = Console.write(show(Clock.now()))
fn main() = ()
|};
  [%expect {|
    fn f() uses Clock, Console
    fn main()
    |}]

let%expect_test "a uses list in a type argument ends at a comma" =
  types
    {|
type Pair<A, B> = { a: A, b: B }
type Box<F> = { f: F }
fn one(p: Pair<fn() -> Int uses Clock, Int>) -> Int uses Clock = p.a() + p.b
fn two(b: Box<(fn() -> Int uses Clock, Console)>) -> Int uses Clock, Console = b.f()
fn row(b: Box<fn() -> Int uses Clock, ..d>) -> Int uses Clock, ..d = b.f()
fn main() = ()
|};
  [%expect
    {|
    fn one(p: Pair<fn() -> Int uses Clock, Int>) -> Int uses Clock
    fn two(b: Box<(fn() -> Int uses Clock, Console)>) -> Int uses Clock, Console
    fn row(b: Box<fn() -> Int uses Clock, ..d>) -> Int uses Clock, ..d
    fn main()
    |}];
  types
    {|
type Box<F> = { f: F }
fn two(b: Box<fn() -> Int uses Clock, Console>) -> Int uses Clock, Console = b.f()
|};
  [%expect
    {|
    error: `Box` takes 1 type argument but was given 2
      ┌─ test.ren:2:11
    2 │ fn two(b: Box<fn() -> Int uses Clock, Console>) -> Int uses Clock, Console = b.f()
      │           ^^^
      help: in a type argument, a `uses` list ends at a comma: to list several dependencies, put the type in parentheses, `Box<(fn() uses Clock, Console)>`
    |}];
  (* a named row after a second dependency *)
  types
    {|
type Box<F> = { f: F }
fn row(b: Box<fn() -> Int uses Clock, Console, ..d>) -> Int uses Clock, Console, ..d = b.f()
|};
  [%expect
    {|
    error: a named row ends a `uses` list, but the list before it ended at a comma
      ┌─ test.ren:2:48
    2 │ fn row(b: Box<fn() -> Int uses Clock, Console, ..d>) -> Int uses Clock, Console, ..d = b.f()
      │                                                ^^
      help: in a type argument, a `uses` list ends at a comma: to list several dependencies, put the type in parentheses, `Box<(fn() uses Clock, Console, ..d)>`
    |}]

(* after a syntax error, parsing picks up at the next top-level item *)

let%expect_test "syntax errors in two functions" =
  ast {|
fn f() = 1 < 2 < 3
fn g() =
  let x = 1 +
  x
fn main() = 1
|};
  [%expect
    {|
    error: comparisons can't be chained
      ┌─ test.ren:1:16
    1 │ fn f() = 1 < 2 < 3
      │                ^
      help: split it into two comparisons

    error: expected an expression, found a new line
      ┌─ test.ren:4:3
    4 │   x
      │   ^
    |}]

(* imports *)

let%expect_test "the four forms of import" =
  ast
    {|
import util
import billing/stripe as pay
import shop/plan.{Plan, User}
import shop/plan.{Plan} as p
fn main() = 1
|};
  [%expect
    {|
    (import util as util)
    (import billing/stripe as pay)
    (import shop/plan (Plan User) as plan)
    (import shop/plan (Plan) as p)
    (fn main () 1)
    |}]

let%expect_test "an import after a function" =
  ast {|
fn main() = 1
import util
|};
  [%expect
    {|
    error: imports go at the top of the file
      ┌─ test.ren:2:1
    2 │ import util
      │ ^^^^^^^^^^^
      help: move it above the file's first function or type
    |}]

let%expect_test "a module's name is snake_case" =
  ast {|
import billing/StripeApi
fn main() = 1
|};
  [%expect
    {|
    error: `StripeApi` can't name a module: module names are snake_case
      ┌─ test.ren:1:16
    1 │ import billing/StripeApi
      │                ^^^^^^^^^
      help: write `stripe_api`, and rename its file or folder to match
    |}]

let%expect_test "an alias is snake_case too" =
  ast {|
import billing/stripe as Pay
fn main() = 1
|};
  [%expect
    {|
    error: `Pay` can't name a module: module names are snake_case
      ┌─ test.ren:1:26
    1 │ import billing/stripe as Pay
      │                          ^^^
      help: write `pay`
    |}]

let%expect_test "only types can be imported by name" =
  ast {|
import billing/stripe.{charge}
fn main() = 1
|};
  [%expect
    {|
    error: only types can be imported by name, and `charge` isn't one
      ┌─ test.ren:1:24
    1 │ import billing/stripe.{charge}
      │                        ^^^^^^
      help: remove it, and write `stripe.charge` where it's used
    |}]

let%expect_test "an import can't be pub" =
  ast {|
pub import util
fn main() = 1
|};
  [%expect
    {|
    error: an import can't be `pub`
      ┌─ test.ren:1:5
    1 │ pub import util
      │     ^^^^^^
      help: remove the `pub`: a module can't pass on what it imports
    |}]

let%expect_test "a type or constructor can be qualified" =
  (* a lowercase name before a capitalized one is a module's alias; a
     capitalized one before another is a type *)
  ast
    {|
type Order = { client: stripe.Client, plans: Array<billing.Plan> }
fn main() =
  let a = Light.Red
  let b = billing.Plan.Pro(seats: 2)
  let c = rows.Row { id: 1 }
  match b
    billing.Plan.Free => Plan.Free
    Plan.Pro(n) => user.plan
|};
  [%expect
    {|
    (type Order (fields client:stripe.Client plans:Array<billing.Plan>))
    (fn main () (block (let a (con Light.Red)) (let b (con billing.Plan.Pro seats=2)) (let c (record rows.Row id=1)) (match b (billing.Plan.Free => (con Plan.Free)) (Plan.Pro(n) => (. user plan)))))
    |}]

let%expect_test "another module's type isn't a value" =
  ast {|
fn main() = billing.Plan
|};
  [%expect
    {|
    error: `billing.Plan` is a type, so it can't be used as a value
      ┌─ test.ren:1:13
    1 │ fn main() = billing.Plan
      │             ^^^^^^^^^^^^
      help: write one of its constructors after it, like `billing.Plan.Name`, or a record, `billing.Plan { ... }`
    |}]

let%expect_test "uses, on the signature's line or the next" =
  ast
    {|
fn f() -> Int uses Console, Clock = 1
pub fn g(x: Int) -> Int
    uses Console =
  x
fn h() = 2
|};
  [%expect
    {|
    (fn f () (uses Console Clock) 1)
    (fn g (x) (uses Console) x)
    (fn h () 2)
    |}]

let%expect_test "uses on the next line has to be indented" =
  ast {|
fn f()
uses Console = print(1)
|};
  [%expect
    {|
    error: `uses` on a line of its own has to be indented
      ┌─ test.ren:2:1
    2 │ uses Console = print(1)
      │ ^^^^
      help: indent it, so it continues the signature
    |}]

let%expect_test "an opaque type" =
  ast {|
pub type UserId = opaque Int
type Ids<T> = opaque Array<T>
|};
  [%expect
    {|
    (pub type UserId (opaque Int))
    (type Ids<T> (opaque Array<T>))
    |}]

(* ---- errors (errors.md) ---- *)

let%expect_test "! is its own token, and != is still one" =
  tokens {|
fn f(a: Int) ! Bad = if a != 1 then fail Bad
|};
  [%expect
    {| FN (IDENT "f") LPAREN (IDENT "a") COLON (IDENT "Int") RPAREN BANG (IDENT "Bad") EQ IF (IDENT "a") NEQ (INT 1) THEN FAIL (IDENT "Bad") EOF |}]

let%expect_test "what a function can fail with, after !" =
  (* after the result, before `uses`, which can still start the next
     line; a payload's fields may be named or not *)
  ast
    {|
pub fn debit(inout a: Int, m: Int) ! Short(account: Int, by: Int) | Frozen(Int) = ()
fn load(id: Int) -> Int ! NotFound uses Console = id
pub fn save(id: Int) -> Int ! Full | bank.Refusal
    uses Console =
  id
type Account = { id: Int }
  pub fn freeze(inout self) ! Frozen(account: Int) = ()
|};
  [%expect
    {|
    (fn debit (a m) (! Short(account: Int, by: Int) | Frozen(Int)) ())
    (fn load (id) (! NotFound) (uses Console) id)
    (fn save (id) (! Full | bank.Refusal) (uses Console) id)
    (type Account (fields id:Int) (members (pub (fn freeze (self) (! Frozen(account: Int)) ()))))
    |}]

let%expect_test "an error set on the signature's next line" =
  (* like `uses`, an indented `!` continues the signature; `!=` doesn't
     start one, and after `=` a `!` opens a named error set's block *)
  ast
    {|
pub fn save(id: Int) -> Int
    ! Full | bank.Refusal
    uses Console =
  id
type Account = { id: Int }
  pub fn freeze(inout self)
      ! Frozen =
    if self.id != 0 then fail Frozen
pub type Refusal =
  ! Short
  | Frozen
|};
  [%expect
    {|
    (fn save (id) (! Full | bank.Refusal) (uses Console) id)
    (type Account (fields id:Int) (members (pub (fn freeze (self) (! Frozen) (if (!= (. self id) 0) (fail Frozen))))))
    (pub type Refusal (! Short | Frozen))
    |}]

let%expect_test "an error set on the next line has to be indented" =
  ast {|
fn f()
! Bad = fail Bad
|};
  [%expect
    {|
    error: an error set on a line of its own has to be indented
      ┌─ test.ren:2:1
    2 │ ! Bad = fail Bad
      │ ^
      help: indent it, so it continues the signature
    |}]

let%expect_test "a function type's errors, and an error set as a type argument"
    =
  (* the `! Bad` after `fn() -> fn()` is the inner function type's *)
  ast
    {|
type Hooks = {
  check: fn(Int) -> Bool ! Bad(Int) | Worse,
  make: fn() -> fn() ! Bad,
  last: Result<Int, ! Short(Int) | Frozen>,
}
|};
  [%expect
    {| (type Hooks (fields check:fn(Int) -> Bool ! Bad(Int) | Worse make:fn() -> fn() ! Bad last:Result<Int, ! Short(Int) | Frozen>)) |}]

let%expect_test "an empty error set, a Result that can't be Err" =
  (* what `ren types` prints for one, so it has to parse back *)
  ast
    {|
fn f(r: Result<Int, !>, xs: Array<Result<Int, !>>) -> Result<Int, !> = r
|};
  [%expect {| (fn f (r xs) r) |}]

let%expect_test "a named error set" =
  (* on one line, or indented under `type X =`, one `|` per line *)
  ast
    {|
pub type Refusal = ! Short(account: Int, by: Int) | Frozen(account: Int)
pub type TransferError =
  ! Refusal
  | NoSuchAccount(account: Int)
  | SameAccount
fn main() = ()
|};
  [%expect
    {|
    (pub type Refusal (! Short(account: Int, by: Int) | Frozen(account: Int)))
    (pub type TransferError (! Refusal | NoSuchAccount(account: Int) | SameAccount))
    (fn main () ())
    |}]

let%expect_test "fail, try, attempt and orelse" =
  (* `try` and `attempt` take everything to their right; `orelse` binds
     below `||`, and groups to the right *)
  ast
    {|
fn f() =
  if bad() then fail Short(1, by: 2)
  let n = try parse(read(p)) + 1
  let r = attempt &acme.transfer(t)
  let x = a || b orelse c orelse fail Missing
  print(not try ok() && done())
  try r
|};
  [%expect
    {| (fn f () (block (if (call bad) (fail Short 1 by=2)) (let n (try (+ (call parse (call read p)) 1))) (let r (attempt (& (call (. acme transfer) t)))) (let x (orelse (|| a b) (orelse c (fail Missing)))) (call print (not (try (&& (call ok) (call done))))) (try r))) |}]

let%expect_test "fail patterns, and try match" =
  ast
    {|
fn f() =
  match transfer(t)
    _ => 0
    fail Short(_, by) => by
    fail NoSuchAccount(_) | fail SameAccount => 1
    fail _ => 2
  try match load(id)
    u => u
    fail NotFound => guest()
|};
  [%expect
    {| (fn f () (block (match (call transfer t) (_ => 0) (fail Short(_, by) => by) (fail NoSuchAccount(_) | fail SameAccount => 1) (fail _ => 2)) (try (match (call load id) (u => u) (fail NotFound => (call guest)))))) |}]

let%expect_test "a fail pattern can't bind the whole error" =
  ast {|
fn f() =
  match g()
    x => x
    fail e => 0
|};
  [%expect
    {|
    error: a `fail` pattern can't bind the whole error to a name
      ┌─ test.ren:4:10
    4 │     fail e => 0
      │          ^
      help: match each tag, like `fail NotFound`, or keep the whole outcome as a value with `attempt`, and match `Err(e)`
    |}]

let%expect_test "fail patterns are whole arms, combined only with each other" =
  ast {|
fn f() =
  match g()
    Some(fail Bad) => 0
|};
  [%expect
    {|
    error: a `fail` pattern can't be inside another pattern
      ┌─ test.ren:3:10
    3 │     Some(fail Bad) => 0
      │          ^^^^
      help: match the error in an arm of its own, `fail Tag(...) => ...`
    |}];
  ast {|
fn f() =
  match g()
    fail Bad | None => 0
|};
  [%expect
    {|
    error: this pattern is combined with `fail` patterns, so it has to be one, but it's `None`
      ┌─ test.ren:3:16
    3 │     fail Bad | None => 0
      │                ^^^^
      help: start it with `fail` too, or give it an arm of its own
    |}]

let%expect_test "fail takes a tag" =
  ast {|
fn f(r: Int) = fail r
|};
  [%expect
    {|
    error: `fail` takes an error tag, which starts with a capital letter
      ┌─ test.ren:1:21
    1 │ fn f(r: Int) = fail r
      │                     ^
      help: write a tag, like `fail NotFound`; to fail with the error a `Result` holds, write `try` before it
    |}];
  ast {|
fn f() ! Bad() = ()
|};
  [%expect
    {|
    error: a tag without a payload is written without parentheses
      ┌─ test.ren:1:13
    1 │ fn f() ! Bad() = ()
      │             ^^
      help: write `Bad`
    |}];
  ast {|
fn f() ! = ()
|};
  [%expect
    {|
    error: expected an error tag, found `=`
      ┌─ test.ren:1:10
    1 │ fn f() ! = ()
      │          ^
    |}]

let%expect_test "a named error set has no type parameters or members" =
  ast {|
type Bad<T> = ! Oops(T)
|};
  [%expect
    {|
    error: a named error set can't take type parameters
      ┌─ test.ren:1:10
    1 │ type Bad<T> = ! Oops(T)
      │          ^
      help: remove the type parameters
    |}];
  ast {|
type Bad = ! Oops
  fn size(self) -> Int = 0
|};
  [%expect
    {|
    error: `Bad` is an error set, not a type of values, so it has no members
      ┌─ test.ren:2:6
    2 │   fn size(self) -> Int = 0
      │      ^^^^
      help: move it under a type, or to the top level
    |}]

let%expect_test "try, fail, attempt and orelse can't be names" =
  ast {|
fn main() =
  let try = 1
  try
|};
  [%expect
    {|
    error: expected a name, found `try`
      ┌─ test.ren:2:7
    2 │   let try = 1
      │       ^^^
    |}]

let%expect_test "string literals and their escapes" =
  tokens {|
fn main() = ["Ren", "a\tb\n", "say \"hi\"", "back\\slash", ""]
|};
  [%expect
    {| FN (IDENT "main") LPAREN RPAREN EQ LBRACKET (STR "Ren") COMMA (STR "a\tb\n") COMMA (STR "say \"hi\"") COMMA (STR "back\\slash") COMMA (STR "") RBRACKET EOF |}];
  ast {|
fn main() = "a\tb" == "say \"hi\"\n"
|};
  [%expect {| (fn main () (== "a\tb" "say \"hi\"\n")) |}]

let%expect_test "a string in an error is written with Ren's escapes" =
  ast {|
fn main() = 1 "café\t"
|};
  [%expect
    {|
    error: expected a new line, found the string `"café\t"`
      ┌─ test.ren:1:15
    1 │ fn main() = 1 "café\t"
      │               ^^^^^^^^^
    |}]

let%expect_test "a string that isn't closed" =
  tokens {|
fn main() = "Ren
|};
  [%expect
    {|
    error: this string isn't closed
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren
      │             ^^^^
      help: close it with `"` on this line; write `\n` for a line break
    |}];
  tokens {|
fn main() = "Ren|};
  [%expect
    {|
    error: this string isn't closed
      ┌─ test.ren:1:13
    1 │ fn main() = "Ren
      │             ^^^^
      help: close it with `"` on this line; write `\n` for a line break
    |}]

let%expect_test "an escape that isn't one" =
  tokens {|
fn main() = "C:\Ren"
|};
  [%expect
    {|
    error: `\R` isn't an escape
      ┌─ test.ren:1:16
    1 │ fn main() = "C:\Ren"
      │                ^^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    |}];
  tokens {|
fn main() = "Ren\
|};
  [%expect
    {|
    error: a `\` at the end of a line escapes nothing
      ┌─ test.ren:1:17
    1 │ fn main() = "Ren\
      │                 ^
      help: the escapes are `\n`, `\t`, `\"` and `\\`, which writes a backslash
    |}]

(* a `Str` is UTF-8, so a literal is too: this one's `é` has lost its
   second byte *)
let%expect_test "a string that isn't UTF-8" =
  tokens "fn main() = \"caf\xc3\"\n";
  [%expect
    {|
    error: this string isn't UTF-8
      ┌─ test.ren:1:13
    1 │ fn main() = "caf�"
      │             ^^^^^^
      help: save the file as UTF-8
    |}]

let%expect_test "code printed for a message keeps a try or attempt to itself" =
  (* trees the parser makes only from parentheses: printed without them,
     the `try` or `attempt` on the right of `*` would take in the `+ 1` *)
  let open Ren in
  let at = Loc.point ~file 1 1 in
  let e kind : Ast.Resolved.expr = { kind; loc = at; node = 0 } in
  let name n = e (Var (Global (Path.make "test" n))) in
  let x = name "x" and one = e (Int 1) in
  let a = e (Call (name "a", [])) in
  let show kind =
    print_endline
      (Option.get
         (Ast.source
            ~type_name:(fun _ -> "")
            ~value_name:(fun (p : Path.t) -> p.name)
            (e kind)))
  in
  show (Binop (Add, e (Binop (Mul, x, e (Attempt a))), one));
  show (Binop (Add, e (Binop (Mul, x, e (Try a))), one));
  show (Binop (Add, e (Binop (Mul, x, e (Unop (Neg, e (Try a))))), one));
  (* and a comparison doesn't end an `attempt`'s reach *)
  show (Binop (Eq, e (Binop (Mul, x, e (Attempt a))), one));
  show (Binop (Add, x, e (Attempt a)));
  [%expect {|
    (x * attempt a()) + 1
    (x * try a()) + 1
    (x * -try a()) + 1
    x * attempt a() == 1
    x + attempt a()
    |}]

let%expect_test "a type joined with `&`, and `&` on an argument" =
  (* a dependency's type joined with `&` is an implementation of each, in
     a parameter, a result and a type argument; a `uses` after `->` is
     still the function's, and `&` before an argument still `inout` *)
  ast
    {|
fn f(h: Rates & RateCalls, o: Option<Clock & TestClock>) -> Rates & RateCalls uses Clock = h
fn g(n: Int) = bump(&n, &xs[0])
|};
  [%expect
    {|
    (fn f (h o) (uses Clock) h)
    (fn g (n) (call bump (& n) (& (index xs 0))))
    |}];
  ast {|
fn f(h: Rates & Box<Int>) = h
|};
  [%expect
    {|
    error: a type joined with `&` is a dependency's, which takes no type arguments
      ┌─ test.ren:1:20
    1 │ fn f(h: Rates & Box<Int>) = h
      │                    ^
      help: only a dependency's type is joined with `&`
    |}];
  ast {|
fn f() uses Rates & RateCalls = 1
|};
  [%expect
    {|
    error: in a `uses` list, dependencies are separated by commas
      ┌─ test.ren:1:19
    1 │ fn f() uses Rates & RateCalls = 1
      │                   ^
      help: write `Rates, ...`: a function uses each of them
    |}]
