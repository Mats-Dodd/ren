(* Errors (errors.md), organised by the seven things error handling has to
   do, then what running it does. [types] prints what `ren types` would,
   once the program has also lowered and passed Core Lint. *)

open Helpers

(* ---- 1. You can see it ---- *)

let%expect_test "a call that can fail has to be marked" =
  check_error
    {|
type Account = { balance: Int }
  fn debit(inout self, m: Int) =
    if self.balance < m then fail Short(m - self.balance)
    self.balance = self.balance - m
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn main() =
  var a = Account { balance: 5 }
  &a.debit(3)
  let n = load(1)
  ()
|};
  [%expect
    {|
    error: `debit` can fail, and nothing handles it
      ┌─ test.ren:8:4
    8 │   &a.debit(3)
      │    ^^^^^^^^^^
      │    ------- it can fail with `Short(Int)`
      help: pass the errors on with `try`, or handle them with `match`

    error: `load` can fail, and nothing handles it
      ┌─ test.ren:9:11
    9 │   let n = load(1)
      │           ^^^^^^^
      │           ---- it can fail with `NotFound(Int)`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "try covers every call to its right" =
  types
    {|
fn read(path: Int) -> Int = if path < 0 then fail Unreadable else path
fn parse(n: Int) -> Int = if n > 9 then fail TooBig(n) else n
fn size(xs: Array<Int>) -> Int = xs.len()
fn total(path: Int) = try parse(read(path)) + 1
fn count(xs: Array<Int>) = try size(xs) + parse(1)
fn main() = ()
|};
  [%expect
    {|
    fn read(path: Int) -> Int ! Unreadable
    fn parse(n: Int) -> Int ! TooBig(Int)
    fn size(xs: Array<Int>) -> Int
    fn total(path: Int) -> Int ! TooBig(Int) | Unreadable
    fn count(xs: Array<Int>) -> Int ! TooBig(Int)
    fn main()
    |}]

let%expect_test "a marker that covers nothing that can fail" =
  check_error
    {|
fn double(n: Int) -> Int = n * 2
fn twice(n: Int) = try double(n)
fn kept(n: Int) = attempt double(n)
fn sum(n: Int) = try n + 1
fn kept_fail(n: Int) = attempt (if n > 0 then fail Big else n)
fn main() = ()
|};
  [%expect
    {|
    error: nothing here can fail
      ┌─ test.ren:2:20
    2 │ fn twice(n: Int) = try double(n)
      │                    ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `try`

    error: nothing here can fail
      ┌─ test.ren:3:19
    3 │ fn kept(n: Int) = attempt double(n)
      │                   ^^^^^^^
      = `attempt` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `attempt`

    error: nothing here can fail
      ┌─ test.ren:4:18
    4 │ fn sum(n: Int) = try n + 1
      │                  ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `try`
    |}]

let%expect_test "a call marked again can fail again" =
  (* each call adds its callee's errors to its marker's, and the callee's
     own errors stay what they were, so the second call brings them in
     too *)
  types
    {|
fn twice(n: Int) -> Int =
  let h = fn() => if n > 0 then fail Q else 1
  let x = try h()
  let y = try h()
  x + y
fn then_kept(n: Int) =
  let h = fn() => if n > 0 then fail Q else 1
  let x = try h()
  attempt h()
fn main() = ()
|};
  [%expect
    {|
    fn twice(n: Int) -> Int ! Q
    fn then_kept(n: Int) -> Result<Int, ! Q> ! Q
    fn main()
    |}]

let%expect_test "a try of a Result has to know it's a Result" =
  (* `try` fails with a `Result`'s error only once its type is known, and
     it covers everything to its right *)
  types
    {|
fn unknown(r) -> Int = try r
fn both(r: Result<Int, ! A>) -> Int = try r + try r
fn main() = ()
|};
  [%expect
    {|
    error: nothing here can fail
      ┌─ test.ren:1:24
    1 │ fn unknown(r) -> Int = try r
      │                        ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: if `r` is a `Result`, say so where it's declared, as in `r: Result<Int, ! E>`: `try` fails with a `Result`'s error only once its type is known

    error: nothing here can fail
      ┌─ test.ren:2:39
    2 │ fn both(r: Result<Int, ! A>) -> Int = try r + try r
      │                                       ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: `try` covers everything to its right, so this is `try (r + try r)`: to fail with the `Result`'s error first, write `(try r)`

    error: `Result<Int, ! A>` has no `+`
      ┌─ test.ren:2:43
    2 │ fn both(r: Result<Int, ! A>) -> Int = try r + try r
      │                                           ^^^^^^^^^
    |}]

let%expect_test "a lambda's body has markers of its own" =
  (* a transparent parameter passes the lambda's errors to the call, so
     both the call and the lambda's own call are marked *)
  types
    {|
fn validate(x: Int) -> Int = if x < 0 then fail Negative(x) else x
fn map(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> =
  var out = []
  for x in xs
    &out.push(try f(x))
  out
fn all(xs: Array<Int>) = try map(xs, fn(x) => try validate(x))
fn inner(xs: Array<Int>) = try map(xs, fn(x) => validate(x))
fn main() = ()
|};
  [%expect
    {|
    error: nothing here can fail
      ┌─ test.ren:8:28
    8 │ fn inner(xs: Array<Int>) = try map(xs, fn(x) => validate(x))
      │                            ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `try`

    error: `validate` can fail, and nothing handles it
      ┌─ test.ren:8:49
    8 │ fn inner(xs: Array<Int>) = try map(xs, fn(x) => validate(x))
      │                                                 ^^^^^^^^^^^
      │                                                 -------- it can fail with `Negative(Int)`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "calling a transparent parameter can fail" =
  (* with whatever the caller passes, so it's marked *)
  types
    {|
pub fn each(xs: Array<Int>, f: fn(Int)) =
  for x in xs
    f(x)
fn twice(f: fn()) =
  try f()
  twice_more(f)
fn twice_more(f: fn()) = try f()
fn main() = ()
|};
  [%expect
    {|
    error: `f` can fail, and nothing handles it
      ┌─ test.ren:3:5
    3 │     f(x)
      │     ^^^^
      │     - it can fail with whatever the function passed as `f` fails with
      help: pass the errors on with `try`, or handle them with `match`

    error: `twice_more` can fail, and nothing handles it
      ┌─ test.ren:6:3
    6 │   twice_more(f)
      │   ^^^^^^^^^^^^^
      │   ---------- it can fail with whatever the function passed as `f` fails with
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "an inferred parameter called without a marker can't fail" =
  types
    {|
fn apply(f) = f()
fn passed(f) = try f()
fn ok() = apply(fn() => 1)
fn passes() = try passed(fn() => fail Oops)
fn main() = ()
|};
  [%expect
    {|
    fn apply<T>(f: fn() -> T) -> T
    fn passed<T>(f: fn() -> T) -> T
    fn ok() -> Int
    fn passes<T>() -> T ! Oops
    fn main()
    |}];
  types
    {|
fn apply(f) = f()
fn bad() = apply(fn() => fail Oops)
fn main() = ()
|};
  [%expect
    {|
    error: expected `fn() -> _`, found `fn() -> _ ! Oops`
      ┌─ test.ren:2:18
    2 │ fn bad() = apply(fn() => fail Oops)
      │                  ^^^^^^^^^^^^^^^^^
      = this function can fail with `Oops`, and the type wanted here can't fail
      = a parameter whose type is inferred can fail only if it's called with `try`
      help: pass its errors on with `try` where it's called, or handle them inside it with `match`
    |}]

(* ---- 2. You can't ignore it ---- *)

let%expect_test "fail has the type of anything" =
  types
    {|
fn check(n: Int) =
  if n < 0 then fail Negative(n)
  ()
fn positive(n: Int) -> Int = if n > 0 then n else fail NotPositive
fn pick(n: Int) -> Bool =
  match n
    0 => fail Zero
    _ => true
fn main() = ()
|};
  [%expect
    {|
    fn check(n: Int) ! Negative(Int)
    fn positive(n: Int) -> Int ! NotPositive
    fn pick(n: Int) -> Bool ! Zero
    fn main()
    |}]

let%expect_test "a value passed on with try is still a value" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn main() =
  try load(1)
  let _ = try load(2)
  ()
|};
  [%expect
    {|
    error: `load` returns `Int`, and this throws it away
      ┌─ test.ren:3:3
    3 │   try load(1)
      │   ^^^^^^^^^^^
      help: use it, or write `let _ = ...` if you mean to drop it
    |}]

(* ---- 3. The signature is exact ---- *)

let%expect_test "a public function writes its errors after !" =
  types
    {|
pub type Refusal = ! Short(account: Int, by: Int) | Frozen(account: Int)
pub type TransferError = ! Refusal | SameAccount
pub fn debit(inout a: Int, m: Int) ! Refusal =
  if a < 0 then fail Frozen(a)
  if a < m then fail Short(a, m - a)
  a = a - m
pub fn transfer(inout a: Int, inout b: Int, m: Int) ! TransferError =
  if m == 0 then fail SameAccount
  try debit(&a, m)
  b = b + m
fn main() = ()
|};
  [%expect
    {|
    pub type Refusal = ! Short(Int, Int) | Frozen(Int)
    pub type TransferError = ! Refusal | SameAccount
    pub fn debit(inout a: Int, m: Int) ! Frozen(Int) | Short(Int, Int)
    pub fn transfer(inout a: Int, inout b: Int, m: Int) ! Frozen(Int) | SameAccount | Short(Int, Int)
    fn main()
    |}]

let%expect_test "a public function can't fail with what it doesn't declare" =
  types
    {|
pub fn debit(inout a: Int, m: Int) ! Short(Int) =
  if a < 0 then fail Frozen(a)
  if a < m then fail Short(m - a)
  a = a - m
pub fn transfer(inout a: Int, m: Int) =
  try debit(&a, m)
fn main() = ()
|};
  [%expect
    {|
    error: `pub fn debit` can fail with `Frozen`, but its signature doesn't say so
      ┌─ test.ren:1:8
    1 │ pub fn debit(inout a: Int, m: Int) ! Short(Int) =
      │        ^^^^^
    2 │   if a < 0 then fail Frozen(a)
      │                 -------------- this fails with `Frozen`
      = `debit` can only fail with what's after its `!`
      help: add `Frozen(Int)` after `!`, or handle it here with `match`

    error: `pub fn transfer` can fail with `Short`, but its signature doesn't say so
      ┌─ test.ren:5:8
    5 │ pub fn transfer(inout a: Int, m: Int) =
      │        ^^^^^^^^
    6 │   try debit(&a, m)
      │       ------------ this call can fail with `Short`
      = a public function without `!` can't fail, and its body is checked against that
      help: add `! Short(Int)` to its signature, or handle it here with `match`
    |}]

let%expect_test "a public function can't declare what it can't fail with" =
  types
    {|
pub type Refusal = ! Short(by: Int) | Frozen
pub fn credit(inout a: Int, m: Int) ! Refusal =
  if a < 0 then fail Frozen
  a = a + m
pub fn check(a: Int) ! Negative | Odd =
  if a < 0 then fail Negative
fn main() = ()
|};
  [%expect
    {|
    error: `pub fn credit` says it can fail with `Short`, but nothing in it can
      ┌─ test.ren:2:39
    2 │ pub fn credit(inout a: Int, m: Int) ! Refusal =
      │                                       ^^^^^^^
      = `Short` is in `Refusal`
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: write the errors it can fail with in place of `Refusal`

    error: `pub fn check` says it can fail with `Odd`, but nothing in it can
      ┌─ test.ren:5:35
    5 │ pub fn check(a: Int) ! Negative | Odd =
      │                                   ^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Odd` from after `!`
    |}]

let%expect_test
    "a private function's errors are inferred, or checked if written" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn twice(id: Int) -> Int = try load(id) + load(id + 1)
fn declared(id: Int) -> Int ! NotFound(Int) = try load(id)
fn wrong(id: Int) -> Int ! Missing = try load(id)
fn main() = ()
|};
  [%expect
    {|
    error: `fn wrong` can fail with `NotFound`, but its signature doesn't say so
      ┌─ test.ren:4:4
    4 │ fn wrong(id: Int) -> Int ! Missing = try load(id)
      │    ^^^^^
      │                                          -------- this call can fail with `NotFound`
      = `wrong` can only fail with what's after its `!`
      help: add `NotFound(Int)` after `!`, or handle it here with `match`

    error: `fn wrong` says it can fail with `Missing`, but nothing in it can
      ┌─ test.ren:4:28
    4 │ fn wrong(id: Int) -> Int ! Missing = try load(id)
      │                            ^^^^^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Missing` from after `!`
    |}]

let%expect_test "a function type writes what it fails with" =
  types
    {|
fn run(f: fn(Int) -> Int ! Bad, x: Int) -> Int = try f(x)
fn ok() = try run(fn(x) => if x < 0 then fail Bad else x, 1)
fn other() = try run(fn(x) => if x < 0 then fail Worse else x, 1)
fn main() = ()
|};
  [%expect
    {|
    error: expected `fn(Int) -> Int ! Bad`, found `fn(Int) -> Int ! Worse`
      ┌─ test.ren:3:22
    3 │ fn other() = try run(fn(x) => if x < 0 then fail Worse else x, 1)
      │                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = this function can fail with `Worse`, and the type wanted here fails only with `Bad`
      help: handle the others inside it with `match`
    |}]

let%expect_test "a transparent parameter is printed as it's written" =
  (* its rows are its function's, so `f: fn(Int) ! Bad` would say
     something else: that `f` fails with exactly `Bad` *)
  types_files
    [
      ( "main.ren",
        {|
import lib
fn a(xs: Array<Int>) = try lib.each(xs, fn(x) => if x > 0 then fail Pos(x))
fn main() = ()
|}
      );
      ( "lib.ren",
        {|
pub fn each(xs: Array<Int>, f: fn(Int)) ! Bad uses Console =
  if xs.len() == 0 then fail Bad
  print(1)
  for x in xs
    try f(x)
|}
      );
    ];
  [%expect
    {|
    -- lib
    pub fn each(xs: Array<Int>, f: fn(Int)) ! Bad uses Console

    -- main
    fn a(xs: Array<Int>) ! Bad | Pos(Int) uses Console
    fn main()
    |}]

(* ---- 4. Passing it on costs one word ---- *)

let%expect_test "functions that call each other share their errors" =
  types
    {|
fn ping(n: Int) -> Int = if n == 0 then fail Done else try pong(n - 1)
fn pong(n: Int) -> Int = try ping(n)
fn main() = ()
|};
  [%expect
    {|
    fn ping(n: Int) -> Int ! Done
    fn pong(n: Int) -> Int ! Done
    fn main()
    |}];
  types
    {|
fn ping(n: Int) -> Int = if n == 0 then fail Done else pong(n - 1)
fn pong(n: Int) -> Int = try ping(n)
fn main() = ()
|};
  [%expect
    {|
    error: `pong` can fail, and nothing handles it
      ┌─ test.ren:1:56
    1 │ fn ping(n: Int) -> Int = if n == 0 then fail Done else pong(n - 1)
      │                                                        ^^^^^^^^^^^
      │                                                        ---- it can fail with `Done`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "an attempt of a function that calls back keeps its errors" =
  (* `a` keeps what `b` fails with in a `Result`, so it doesn't fail with
     them, though `b` fails with what `a` does *)
  types
    {|
fn a(n: Int) -> Int ! X =
  if n == 0 then fail X
  let r = attempt b(n - 1)
  match r
    Ok(v) => v
    Err(X) => 0
    Err(Y) => 1
fn b(n: Int) -> Int =
  if n == 5 then fail Y
  try a(n)
fn c(n: Int) -> Int =
  if n == 0 then fail X
  match attempt d(n - 1)
    Ok(v) => v
    Err(X) => 0
    Err(Y) => 1
fn d(n: Int) -> Int =
  if n == 5 then fail Y
  try c(n)
pub fn pu() -> Int ! X = try c(1)
fn main() = ()
|};
  [%expect
    {|
    fn a(n: Int) -> Int ! X
    fn b(n: Int) -> Int ! X | Y
    fn c(n: Int) -> Int ! X
    fn d(n: Int) -> Int ! X | Y
    pub fn pu() -> Int ! X
    fn main()
    |}]

let%expect_test "attempt stops at a comparison" =
  (* it takes what's to its right up to a comparison, so its `Result` can
     be compared: `attempt f() == x` is `(attempt f()) == x` *)
  run
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn main() =
  let ok = attempt load(4)
  print(attempt load(4) == ok)
  print(attempt load(4) != attempt load(5))
  print(attempt load(1) + load(2))
  print(attempt load(4) == ok && true)
|};
  [%expect {|
    true
    true
    Ok(3)
    true
    ()
    |}]

let%expect_test "orelse turns an Option into a value or an error" =
  types
    {|
fn find(xs: Array<Int>, x: Int) -> Option<Int> =
  if xs.len() > x then Some(x) else None
fn get(xs: Array<Int>) -> Int = find(xs, 1) orelse fail NotFound(1)
fn or_zero(xs: Array<Int>) -> Int = find(xs, 1) orelse 0
fn chain(xs: Array<Int>) -> Int = find(xs, 1) orelse find(xs, 2) orelse 0
fn main() = ()
|};
  [%expect
    {|
    fn find(xs: Array<Int>, x: Int) -> Option<Int>
    fn get(xs: Array<Int>) -> Int ! NotFound(Int)
    fn or_zero(xs: Array<Int>) -> Int
    fn chain(xs: Array<Int>) -> Int
    fn main()
    |}];
  types
    {|
fn wrong(n: Int) -> Int = n orelse 0
fn other(o: Option<Int>) -> Int = o orelse true
fn main() = ()
|};
  [%expect
    {|
    error: `orelse` takes an `Option` on its left, but this is an `Int`
      ┌─ test.ren:1:27
    1 │ fn wrong(n: Int) -> Int = n orelse 0
      │                           ^
      help: `x orelse y` is the value in the `Option` `x`, or else `y`

    error: this is a `Bool`, but the `Option` on the left of `orelse` holds an `Int`
      ┌─ test.ren:2:44
    2 │ fn other(o: Option<Int>) -> Int = o orelse true
      │                                            ^^^^
      help: give a value of that type, or `fail` with an error
    |}]

(* ---- 5. Handling is precise and stays checked ---- *)

let%expect_test "attempt keeps the outcome in a Result" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn big(id: Int) -> Int =
  let n = try load(id)
  if n > 9 then fail TooBig
  n
fn kept(id: Int) = attempt big(id)
fn again(id: Int) -> Int =
  let r = attempt big(id)
  try r
fn given(r: Result<Int, ! NotFound(Int) | Gone>) -> Int = try r
fn main() = ()
|};
  [%expect
    {|
    fn load(id: Int) -> Int ! NotFound(Int)
    fn big(id: Int) -> Int ! NotFound(Int) | TooBig
    fn kept(id: Int) -> Result<Int, ! NotFound(Int) | TooBig>
    fn again(id: Int) -> Int ! NotFound(Int) | TooBig
    fn given(r: Result<Int, ! Gone | NotFound(Int)>) -> Int ! Gone | NotFound(Int)
    fn main()
    |}]

let%expect_test "attempt keeps what a passed function fails with" =
  (* its `Result` keeps the passed function's open set, and the function
     itself doesn't fail *)
  types
    {|
fn wrap(g: fn() -> Int) = attempt g()
fn w(f) = attempt f()
fn both(g: fn()) =
  try g()
  let r = attempt g()
  r
fn bad() -> Int = fail B
fn use() = wrap(fn() => fail Q)
fn use2() = w(bad)
fn main() = ()
|};
  [%expect
    {|
    fn wrap(g: fn() -> Int) -> Result<Int, ! ..e>
    fn w<T>(f: fn() -> T) -> Result<T, ! ..e>
    fn both(g: fn()) -> Result<Unit, ! ..e> ! ..e
    fn bad() -> Int ! B
    fn use() -> Result<Int, ! Q>
    fn use2() -> Result<Int, ! B>
    fn main()
    |}];
  (* a public function's transparent parameter fails with the function's
     own errors, as its signature says, so they're passed on *)
  types
    {|
pub fn wrap(g: fn() -> Int) -> Result<Int, ! Mine> = attempt g()
fn main() = ()
|};
  [%expect
    {|
    error: `attempt` can't keep what `g` fails with here
      ┌─ test.ren:1:62
    1 │ pub fn wrap(g: fn() -> Int) -> Result<Int, ! Mine> = attempt g()
      │                                                              ^^^
      │                                                              - its type is written `fn(...)`, so what it fails with is passed on to whoever calls `wrap`
      = a transparent parameter's errors are its function's own, which its signature says it passes on
      help: to keep them, write what it fails with where `g`'s type is written, as in `g: fn() ! Bad`, or pass them on with `try`
    |}]

let%expect_test "attempt keeps only what its call fails with" =
  (* the function's own errors aren't the callee's, so a `Result` doesn't
     hold them *)
  types
    {|
fn local(n: Int) =
  let h = fn() => if n > 0 then fail Q else 1
  if n == 3 then fail Other
  let r = attempt h()
  let x = try h()
  r
fn passed(g: fn() -> Int, n: Int) =
  if n == 0 then fail Z
  let a = try g()
  attempt g()
fn again(g: fn() -> Int) -> Int =
  let r = attempt g()
  try r
fn exact(n: Int) -> Int =
  let h = fn() => if n > 0 then fail Q else 1
  if n == 3 then fail Other
  let x = try h()
  match attempt h()
    Ok(v) => v + x
    Err(Q) => 0
fn main() = ()
|};
  [%expect
    {|
    fn local(n: Int) -> Result<Int, ! Q> ! Other | Q
    fn passed(g: fn() -> Int, n: Int) -> Result<Int, ! ..e> ! Z | ..e
    fn again(g: fn() -> Int) -> Int
    fn exact(n: Int) -> Int ! Other | Q
    fn main()
    |}]

let%expect_test "a tag can't be matched in a passed function's errors" =
  types
    {|
fn w(g: fn() -> Int) -> Int =
  match attempt g()
    Ok(v) => v
    Err(Bad) => 0
    Err(_) => 1
fn main() = ()
|};
  [%expect
    {|
    error: `Bad` can't be matched here, because the errors this holds aren't known
      ┌─ test.ren:4:9
    4 │     Err(Bad) => 0
      │         ^^^
      = this holds whatever the function passed as `g` fails with, which could be anything
      help: match those with `Err(_)`, or write the errors `g` can fail with in its type, after `!`
    |}];
  (* nor written as a value there *)
  types
    {|
fn w(g: fn() -> Int) -> Bool = attempt g() == Err(Bad)
fn main() = ()
|};
  [%expect
    {|
    error: `Bad` can't be written here, because the errors this holds aren't known
      ┌─ test.ren:1:51
    1 │ fn w(g: fn() -> Int) -> Bool = attempt g() == Err(Bad)
      │                                                   ^^^
      = this holds whatever the function passed as `g` fails with, which could be anything
      help: write the errors `g` can fail with in its type, after `!`, or `match` on this with an `Err(_)` arm
    |}]

let%expect_test "matching a Result handles every error it can hold" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn big(id: Int) -> Int =
  let n = try load(id)
  if n > 9 then fail TooBig
  n
fn all(id: Int) -> Int =
  match attempt big(id)
    Ok(n) => n
    Err(NotFound(id)) => id
    Err(TooBig) => 9
fn some(id: Int) -> Int =
  match attempt big(id)
    Ok(n) => n
    Err(NotFound(_)) => 0
fn none(id: Int) -> Int =
  match attempt big(id)
    Ok(n) => n
fn main() = ()
|};
  [%expect
    {|
    error: this `match` doesn't handle every `Result`
       ┌─ test.ren:12:3
    12 │   match attempt big(id)
       │   ^^^^^
       = missing: Err(TooBig)
       help: add an arm for `Err(TooBig)`, or a `_ =>` arm for the rest

    error: this `match` doesn't handle every `Result`
       ┌─ test.ren:16:3
    16 │   match attempt big(id)
       │   ^^^^^
       = missing: Err(NotFound(_)), Err(TooBig)
       help: add an arm for `Err(NotFound(_))`, or a `_ =>` arm for the rest
    |}];
  (* a misspelled tag is a different error, which the `Result` can't hold *)
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn typo(id: Int) -> Int =
  match attempt load(id)
    Ok(n) => n
    Err(NotFuond(_)) => 0
    Err(_) => 1
fn swapped(r: Result<Int, ! A(Int) | Big>) -> Int =
  match r
    Ok(v) => v
    Err(Bgi) => 0
    Err(_) => 1
fn main() = ()
|};
  [%expect
    {|
    error: `NotFuond` isn't one of the errors this can hold
      ┌─ test.ren:5:9
    5 │     Err(NotFuond(_)) => 0
      │         ^^^^^^^^
      = it can hold `NotFound(Int)`
      help: did you mean `NotFound`? A tag that's written wrong is a different error

    error: `Bgi` isn't one of the errors this can hold
       ┌─ test.ren:10:9
    10 │     Err(Bgi) => 0
       │         ^^^
       = it can hold `A(Int)` and `Big`
       help: did you mean `Big`? A tag that's written wrong is a different error
    |}]

let%expect_test "an error is a value only inside a Result" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn whole(id: Int) -> Int =
  match attempt load(id)
    Ok(n) => n
    Err(e) => 0
fn main() = ()
|};
  [%expect
    {|
    error: `e` would hold an error, which isn't a value
      ┌─ test.ren:5:9
    5 │     Err(e) => 0
      │         ^
      = an error is a value only inside the `Result` that holds it
      help: match its tags, like `Err(NotFound(id))`, or ignore it with `Err(_)`
    |}];
  (* a `Result` made with `Ok` holds an error set too *)
  types
    {|
fn ok() = Ok(1)
fn same<T>(a: T, b: T) = ()
fn whole() =
  match ok()
    Ok(n) => ()
    Err(x) => same(x, 5)
fn main() = ()
|};
  [%expect
    {|
    error: `x` would hold an error, which isn't a value
      ┌─ test.ren:6:9
    6 │     Err(x) => same(x, 5)
      │         ^
      = an error is a value only inside the `Result` that holds it
      help: match its tags, like `Err(NotFound(id))`, or ignore it with `Err(_)`
    |}];
  types {|
fn ok() = Ok(1)
fn main() = ()
|};
  [%expect {|
    fn ok() -> Result<Int, !>
    fn main()
    |}];
  types {|
fn made() = Err(NotFound(1))
fn main() = ()
|};
  [%expect
    {|
    fn made<T>() -> Result<T, ! NotFound(Int)>
    fn main()
    |}]

let%expect_test "an error is written as its tag inside Err" =
  (* so a kept outcome can be compared, and a test shows what came back *)
  run
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else if id < 0 then fail Negative else id
fn pick(c: Bool) = if c then Err(Left(1)) else Err(Right)
pub fn sure() -> Result<Int, ! Gone(Int)> = Err(Gone(1))
fn main() =
  print(attempt load(0) == Err(NotFound(0)))
  print(attempt load(0) != Err(NotFound(1)))
  print(attempt load(-1) == Err(Negative))
  print([pick(true), pick(false)])
  print(sure())
  match pick(true)
    Err(Left(n)) => print(n)
    _ => ()
|};
  [%expect
    {|
    true
    true
    true
    [Err(Left(1)), Err(Right)]
    Err(Gone(1))
    1
    ()
    |}];
  types
    {|
fn pick(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn main() = ()
|};
  [%expect
    {|
    fn pick<T>(c: Bool) -> Result<T, ! Left(Int) | Right>
    fn main()
    |}];
  test
    {|
pub fn load(id: Int) -> Int ! NotFound(id: Int) = if id == 0 then fail NotFound(id) else id

test "a refusal shows what came back" =
  assert attempt load(3) == Err(NotFound(3))
|};
  [%expect
    {|
    test.ren
      ✗ a refusal shows what came back

    ──── a refusal shows what came back ── test.ren:4
      │
    4 │   assert attempt load(3) == Err(NotFound(3))
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  Ok(3)
      right: Err(NotFound(3))
             ^ differs here

      seed 6361 · rerun: ren test test.ren --only "a refusal" --seed 6361

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test
    "a set of tags written inside Err is closed after its group (B5)" =
  (* [mk2]'s set is its own, made of the two tags: once its group is done
     it holds those and no more, as `ren types` says, and as its type in
     Core says, with no tail. So a `match` with exactly those arms
     handles every `Result` it returns *)
  let src =
    {|
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn pick(c: Bool) -> Int =
  match mk2(c)
    Ok(_) => 0
    Err(Left(n)) => n
    Err(Right) => 2
fn main() =
  print(pick(true))
  print(pick(false))
|}
  in
  types src;
  run src;
  core ~types:true
    {|
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn main() = ()
|};
  [%expect
    {|
    fn mk2<T>(c: Bool) -> Result<T, ! Left(Int) | Right>
    fn pick(c: Bool) -> Int
    fn main() uses Console
    1
    2
    ()
    (fn mk2 : fn(Bool) -> Result<T, ! Left(Int) | Right> ! ..e uses ..d (c/1) ev/2
      (if c/1 (con Err (tag Left 1)) (con Err (tag Right))))
    (fn main : fn() ! ..e uses ..d () ev/1 ())
    (fn $start : fn() ! ..e () ev/1 (call ev/1 (inst main {..e} {..r})))
    |}];
  (* and a set met in a later group can't add to it: a kept set that
     holds another tag isn't the same type, and nor is a tag written in
     another `Err` *)
  check_error
    {|
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn g() -> Int ! Oops = fail Oops
fn same() -> Bool = mk2(true) == attempt g()
fn mk3(c: Bool) = if c then mk2(c) else Err(Third)
fn main() = ()
|};
  [%expect
    {|
    error: `==` compares two values of the same type, but this is a `Result<Int, ! Oops>` and the left side is a `Result<Int, ! Left(Int) | Right>`
      ┌─ test.ren:3:34
    3 │ fn same() -> Bool = mk2(true) == attempt g()
      │                                  ^^^^^^^^^^^
      │                     --------- this is a `Result<Int, ! Left(Int) | Right>`
      = a `Result` can hold `Oops` here, and the other only `Left(Int)` and `Right`: what one can hold is fixed once what made it is checked, so neither stands for the other
      help: use `Result`s that can hold the same errors here, or `match` on one instead

    error: `Third` isn't one of the errors this can hold
      ┌─ test.ren:4:45
    4 │ fn mk3(c: Bool) = if c then mk2(c) else Err(Third)
      │                                             ^^^^^
      = it can hold `Left(Int)` and `Right`
      help: check the spelling: a tag that's written wrong is a different error
    |}]

let%expect_test "a kept set doesn't take tags written in an earlier group (B5)"
    =
  (* [mk2]'s set is a type by the time [kept] is checked, but its tags
     are still ones written in `Err`: the `attempt`'s set can't take
     `Right` from it, which `g` doesn't fail with, as it couldn't from an
     `Err(Right)` written in [kept] itself. So too through a function that
     passes [mk2]'s `Result` on, and through a generic one *)
  check_error
    {|
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn g() -> Int ! Left(Int) = fail Left(2)
fn kept(c: Bool) = if c then mk2(c) else attempt g()
fn mk4(c: Bool) = mk2(c)
fn passed(c: Bool) = if c then attempt g() else mk4(c)
fn pick<T>(c: Bool, a: T, b: T) -> T = if c then a else b
fn generic(c: Bool) = pick(c, mk2(c), attempt g())
fn main() = ()
|};
  [%expect
    {|
    error: this `attempt` can't keep `Right`: nothing it covers fails with it
      ┌─ test.ren:3:42
    1 │ fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
      │                                                   ----- `Right` is written here, in a `Result` that holds exactly the tags written in it
    3 │ fn kept(c: Bool) = if c then mk2(c) else attempt g()
      │                                          ^^^^^^^
      = its `Result` is used as one made with `Err`, which holds `Left(Int)` and `Right`, but what an `attempt` keeps is what the calls it covers fail with, `Left(Int)`, and nothing more
      help: keep the two `Result`s apart, or write the type of the function that makes the one with `Err`, with `! Left(Int) | Right` in its `Result`: what an `attempt` keeps can be a declared `Result`, which can hold more

    error: this `attempt` can't keep `Right`: nothing it covers fails with it
      ┌─ test.ren:5:32
    1 │ fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
      │                                                   ----- `Right` is written here, in a `Result` that holds exactly the tags written in it
    5 │ fn passed(c: Bool) = if c then attempt g() else mk4(c)
      │                                ^^^^^^^
      = its `Result` is used as one made with `Err`, which holds `Left(Int)` and `Right`, but what an `attempt` keeps is what the calls it covers fail with, `Left(Int)`, and nothing more
      help: keep the two `Result`s apart, or write the type of the function that makes the one with `Err`, with `! Left(Int) | Right` in its `Result`: what an `attempt` keeps can be a declared `Result`, which can hold more

    error: this `attempt` can't keep `Right`: nothing it covers fails with it
      ┌─ test.ren:7:39
    1 │ fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
      │                                                   ----- `Right` is written here, in a `Result` that holds exactly the tags written in it
    7 │ fn generic(c: Bool) = pick(c, mk2(c), attempt g())
      │                                       ^^^^^^^
      = its `Result` is used as one made with `Err`, which holds `Left(Int)` and `Right`, but what an `attempt` keeps is what the calls it covers fail with, `Left(Int)`, and nothing more
      help: keep the two `Result`s apart, or write the type of the function that makes the one with `Err`, with `! Left(Int) | Right` in its `Result`: what an `attempt` keeps can be a declared `Result`, which can hold more
    |}]

let%expect_test "a kept set doesn't take tags written in another module (B5)" =
  (* a public function declares its type, so a set of tags written in
     `Err` never leaves its module: here the `Result`s meet in a generic
     function of another one, which can't make the kept set take them *)
  check_error_files
    [
      ( "main.ren",
        {|
import util
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn kept(c: Bool) = util.pick(c, mk2(c), attempt util.g())
fn main() = ()
|}
      );
      ( "util.ren",
        {|
pub fn g() -> Int ! Left(Int) = fail Left(2)
pub fn pick<T>(c: Bool, a: T, b: T) -> T = if c then a else b
|}
      );
    ];
  [%expect
    {|
    error: this `attempt` can't keep `Right`: nothing it covers fails with it
      ┌─ main.ren:3:41
    2 │ fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
      │                                                   ----- `Right` is written here, in a `Result` that holds exactly the tags written in it
    3 │ fn kept(c: Bool) = util.pick(c, mk2(c), attempt util.g())
      │                                         ^^^^^^^
      = its `Result` is used as one made with `Err`, which holds `Left(Int)` and `Right`, but what an `attempt` keeps is what the calls it covers fail with, `Left(Int)`, and nothing more
      help: keep the two `Result`s apart, or write the type of the function that makes the one with `Err`, with `! Left(Int) | Right` in its `Result`: what an `attempt` keeps can be a declared `Result`, which can hold more
    |}]

let%expect_test "a kept set takes a declared Result's tags (B5)" =
  (* a declared `Result` says what it can hold, more than a call fails
     with if it likes, so a kept set can be one: as a parameter's type,
     as a function's result, here or in another module, and where the
     type of what's made with `Err` is said *)
  run_files
    [
      ( "main.ren",
        {|
import util
fn mk2<T>(c: Bool) -> Result<T, ! Left(Int) | Right> =
  if c then Err(Left(1)) else Err(Right)
fn kept(c: Bool) = if c then mk2(c) else attempt util.g()
fn there(c: Bool) = if c then util.made(c) else attempt util.g()
fn worth_trying(r: Result<Int, ! Left(Int) | Right>) -> Bool =
  match r
    Ok(_) => false
    Err(Left(_)) => true
    Err(Right) => false
fn main() =
  print([kept(true), kept(false), there(false)])
  print(worth_trying(attempt util.g()))
|}
      );
      ( "util.ren",
        {|
pub fn g() -> Int ! Left(Int) = fail Left(2)
pub fn made(c: Bool) -> Result<Int, ! Left(Int) | Right> =
  if c then Err(Left(1)) else Err(Right)
|}
      );
    ];
  [%expect
    {|
    [Err(Left(1)), Err(Left(2)), Err(Left(2))]
    true
    ()
    |}]

let%expect_test "a kept set equal to a declared Result too takes its tags (B5)"
    =
  (* the `attempt`'s set is equal both to [mk2]'s, of tags written in
     `Err`, and to [h]'s declared one, so it can hold `Right`, as it could
     with the `Err`s written in place: whichever it meets first, and
     whether it meets the declared one itself or through another `Result`
     that has *)
  run
    {|
fn mk2(c: Bool) = if c then Err(Left(1)) else Err(Right)
fn g() -> Int ! Left(Int) = fail Left(2)
fn h(r: Result<Int, ! Left(Int) | Right>) -> Bool =
  match r
    Err(Right) => true
    _ => false
fn declared_last(c: Bool) =
  let r = if c then mk2(c) else attempt g()
  h(r)
fn declared_first(c: Bool) =
  let k = attempt g()
  let x = h(k)
  let r = if c then k else mk2(c)
  x
fn through_another(c: Bool) =
  let k = attempt g()
  let a = mk2(c)
  let b = mk2(c)
  let r = if c then a else b
  let s = if c then k else a
  h(b)
fn main() =
  print([declared_last(false), declared_first(false), through_another(false)])
|};
  [%expect {|
    [false, false, true]
    ()
    |}]

let%expect_test "a tag inside Err has to be one the Result can hold" =
  (* compared with what an `attempt` kept, or given where a declared
     `Result` is wanted, it's checked as a tag in a pattern is *)
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
pub fn sure() -> Result<Int, ! Gone(Int)> = Err(Gon(1))
fn main() =
  let _ = attempt load(0) == Err(NotFund(0))
  let _ = attempt load(0) == Err(NotFound("x"))
  let _ = attempt load(0) == Err(NotFound(0, 1))
  ()
|};
  [%expect
    {|
    error: `Gon` isn't one of the errors this can hold
      ┌─ test.ren:2:49
    2 │ pub fn sure() -> Result<Int, ! Gone(Int)> = Err(Gon(1))
      │                                                 ^^^
      = it can hold `Gone(Int)`
      help: did you mean `Gone`? A tag that's written wrong is a different error

    error: `NotFund` isn't one of the errors this can hold
      ┌─ test.ren:4:34
    4 │   let _ = attempt load(0) == Err(NotFund(0))
      │                                  ^^^^^^^
      = it can hold `NotFound(Int)`
      help: did you mean `NotFound`? A tag that's written wrong is a different error

    error: this is a `Str`, but `NotFound` holds an `Int` here
      ┌─ test.ren:5:43
    5 │   let _ = attempt load(0) == Err(NotFound("x"))
      │                                           ^^^
      = it's `NotFound(Int)`

    error: `NotFound`'s payload has 1 value, but this tag has 2
      ┌─ test.ren:6:34
    6 │   let _ = attempt load(0) == Err(NotFound(0, 1))
      │                                  ^^^^^^^^
    |}];
  (* whichever side of `==` it's on, through a `let` or inside another
     value, so a kept set never gains a tag no call fails with *)
  types
    {|
fn f(n: Int) -> Int = if n < 0 then fail Neg(n) else n
fn p() =
  let r = attempt f(-1)
  if Err(Nope) == r then print("no") else print("yes")
  r
fn q() = assert Err(Nge(-1)) == attempt f(-1)
fn s() =
  let r = attempt f(-1)
  let e = Err(Nope)
  assert r == e
  match r
    Ok(_) => ()
    Err(Neg(_)) => ()
fn t() = Some(attempt f(-1)) == Some(Err(Nge(-1)))
fn main() = ()
|};
  [%expect
    {|
    error: `Nope` isn't one of the errors this can hold
      ┌─ test.ren:4:10
    4 │   if Err(Nope) == r then print("no") else print("yes")
      │          ^^^^
      = it can hold `Neg(Int)`
      help: check the spelling: a tag that's written wrong is a different error

    error: `Nge` isn't one of the errors this can hold
      ┌─ test.ren:6:21
    6 │ fn q() = assert Err(Nge(-1)) == attempt f(-1)
      │                     ^^^
      = it can hold `Neg(Int)`
      help: did you mean `Neg`? A tag that's written wrong is a different error

    error: `Nope` isn't one of the errors this can hold
      ┌─ test.ren:9:15
    9 │   let e = Err(Nope)
      │               ^^^^
      = it can hold `Neg(Int)`
      help: check the spelling: a tag that's written wrong is a different error

    error: `Nge` isn't one of the errors this can hold
       ┌─ test.ren:14:42
    14 │ fn t() = Some(attempt f(-1)) == Some(Err(Nge(-1)))
       │                                          ^^^
       = it can hold `Neg(Int)`
       help: did you mean `Neg`? A tag that's written wrong is a different error
    |}];
  (* a tag that is one of them, written anywhere, is checked the same
     way; a set of its own gets every tag written in it, which `try`
     fails with *)
  types
    {|
fn f(n: Int) -> Int = if n < 0 then fail Neg(n) else n
fn ok() =
  let r = attempt f(-1)
  assert Err(Neg(-1)) == r
  let e = Err(Neg(-1))
  assert r == e
fn again() -> Int =
  let r = if true then Err(Gone(1)) else Err(Gone(2))
  try r
fn made() = Err(Gone(3))
fn passed() -> Int = try made()
fn tagged() = Err(Some(1))
fn main() = ()
|};
  [%expect
    {|
    fn f(n: Int) -> Int ! Neg(Int)
    fn ok()
    fn again() -> Int ! Gone(Int)
    fn made<T>() -> Result<T, ! Gone(Int)>
    fn passed() -> Int ! Gone(Int)
    fn tagged<T>() -> Result<T, ! Some(Int)>
    fn main()
    |}];
  (* `try` passes on what a `Result` made with `Err` holds, as it does any
     `Result`'s (deps.md, "Deviations"), and a name inside `Err` is a tag
     even where a type has a constructor of that name *)
  run
    {|
type Shape = Bad(n: Int) | Good
fn main() ! Gone(Int) =
  print(Bad(2))
  print(Err(Bad(1)))
  let r = Err(Gone(1))
  try r
|};
  [%expect {|
    Bad(2)
    Err(Bad(1))
    error: Gone(1)
    |}];
  (* anything else inside `Err` would be an error on its own, and a tag
     among several arguments is only reported once *)
  types
    {|
fn main() =
  let x = 3
  let _ = Err(x)
  let _ = Err(Neg(-1), 2)
  ()
|};
  [%expect
    {|
    error: `Err` holds an error, written as its tag
      ┌─ test.ren:3:11
    3 │   let _ = Err(x)
      │           ^^^
      = an error isn't a value on its own: `Err` holds one written as its tag, or one that `attempt` kept
      help: write the tag inside it, `Err(NotFound(id))`, or keep what a call fails with: `attempt f()`

    error: `Err` holds an error, written as its tag
      ┌─ test.ren:4:11
    4 │   let _ = Err(Neg(-1), 2)
      │           ^^^
      = an error isn't a value on its own: `Err` holds one written as its tag, or one that `attempt` kept
      help: write the tag inside it, `Err(NotFound(id))`, or keep what a call fails with: `attempt f()`
    |}];
  (* and `fail` is the way to fail with one written in place *)
  types {|
fn f() -> Int = try Err(Gone(1))
fn main() = ()
|};
  [%expect
    {|
    error: this `try` fails with the error it's given
      ┌─ test.ren:1:17
    1 │ fn f() -> Int = try Err(Gone(1))
      │                 ^^^^^^^^^^^^^^^^
      = `try` passes on an error a `Result` already holds; `fail` is the way to fail with one written in place
      help: write `fail Gone(1)`
    |}]

let%expect_test "match handles a call's errors with fail arms" =
  (* a `fail` arm destructures a payload, and can fail with another tag,
     which is how one error becomes another *)
  types
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound(id)
  if id > 9 then fail TooBig(id, 9)
  id
fn all(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(_) => 0
    fail TooBig(_, max) => max
fn translated(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(_) | fail TooBig(_, _) => fail Unavailable
fn either(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(x) | fail TooBig(x, _) => x
fn inside(n: Int) -> Int =
  match (if n > 0 then fail Big else n)
    m => m
    fail Big => 0
fn kept(id: Int) =
  attempt match load(id)
    n => n
    fail NotFound(_) => fail Gone
    fail TooBig(_, _) => 9
fn main() = ()
|};
  [%expect
    {|
    fn load(id: Int) -> Int ! NotFound(Int) | TooBig(Int, Int)
    fn all(id: Int) -> Int
    fn translated(id: Int) -> Int ! Unavailable
    fn either(id: Int) -> Int
    fn inside(n: Int) -> Int
    fn kept(id: Int) -> Result<Int, ! Gone>
    fn main()
    |}]

let%expect_test "a match handles what a function of its group fails with" =
  (* what [d] fails with is known only once the group is done, and the
     match is checked against it then *)
  types
    {|
fn c(n: Int) -> Int =
  if n == 0 then fail Zero
  if n == 1 then fail One
  match d(n - 1)
    m => m
    fail Zero => 0
fn d(n: Int) -> Int = try c(n)
fn main() = ()
|};
  [%expect
    {|
    error: this `match` doesn't handle every error it can fail with
      ┌─ test.ren:4:3
    4 │   match d(n - 1)
      │   ^^^^^
      = missing: fail One
      help: add an arm for `fail One`, or a `fail _ =>` arm for the rest, or pass them on with `try match`
    |}]

let%expect_test "an or-pattern's names have one type" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else if id > 9 then fail Bad(id > 99) else id
fn either(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(x) | fail Bad(x) => 0
fn main() = ()
|};
  [%expect
    {|
    error: `x` is a `Bool` here, but an `Int` in the first alternative
      ┌─ test.ren:5:33
    5 │     fail NotFound(x) | fail Bad(x) => 0
      │                                 ^
    |}]

let%expect_test "a match handles every value and every error" =
  types
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound(id)
  if id > 9 then fail TooBig(id, 9)
  id
fn some(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(_) => 0
fn wild(id: Int) -> Int =
  match load(id)
    _ => 0
    fail NotFound(_) => 0
fn no_value(id: Int) -> Int =
  match load(id)
    fail _ => 0
fn partly(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(0) => 0
    fail TooBig(_, _) => 0
fn any(id: Int) -> Int =
  match load(id)
    n => n
    fail _ => 0
fn main() = ()
|};
  [%expect
    {|
    error: this `match` doesn't handle every error it can fail with
      ┌─ test.ren:6:3
    6 │   match load(id)
      │   ^^^^^
      = missing: fail TooBig(_, _)
      help: add an arm for `fail TooBig(_, _)`, or a `fail _ =>` arm for the rest, or pass them on with `try match`

    error: this `match` doesn't handle every error it can fail with
       ┌─ test.ren:10:3
    10 │   match load(id)
       │   ^^^^^
       = missing: fail TooBig(_, _)
       help: add an arm for `fail TooBig(_, _)`, or a `fail _ =>` arm for the rest, or pass them on with `try match`

    error: this `match` doesn't handle every `Int`
       ┌─ test.ren:14:3
    14 │   match load(id)
       │   ^^^^^
       = missing: _
       help: add a `_ =>` arm to cover the remaining values

    error: this `match` doesn't handle every error it can fail with
       ┌─ test.ren:17:3
    17 │   match load(id)
       │   ^^^^^
       = missing: fail NotFound(_)
       help: add an arm for `fail NotFound(_)`, or a `fail _ =>` arm for the rest, or pass them on with `try match`
    |}];
  (* an arm after `fail _` can never match an error *)
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn late(id: Int) -> Int =
  match load(id)
    n => n
    fail _ => 0
    fail NotFound(_) => 1
fn main() = ()
|};
  [%expect
    {|
    error: this arm can never match
      ┌─ test.ren:6:5
    6 │     fail NotFound(_) => 1
      │     ^^^^^^^^^^^^^^^^
      help: the arms above already match everything this one does
    |}]

let%expect_test "a fail arm matches an error the call can fail with" =
  types
    {|
fn double(n: Int) -> Int = n * 2
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn never(n: Int) -> Int =
  match double(n)
    m => m
    fail _ => 0
fn never_tag(n: Int) -> Int =
  match double(n)
    m => m
    fail Big => 0
fn typo(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFuond(_) => 0
    fail _ => 1
fn short(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound => 0
fn main() = ()
|};
  [%expect
    {|
    error: nothing here can fail, so this `fail` arm can never match
      ┌─ test.ren:6:5
    6 │     fail _ => 0
      │     ^^^^^^
      = a `fail` arm matches an error of what the `match` looks at
      help: remove the `fail` arms

    error: nothing here can fail, so this `fail` arm can never match
       ┌─ test.ren:10:5
    10 │     fail Big => 0
       │     ^^^^^^^^
       = a `fail` arm matches an error of what the `match` looks at
       help: remove the `fail` arms

    error: `NotFuond` isn't one of the errors this can fail with
       ┌─ test.ren:14:10
    14 │     fail NotFuond(_) => 0
       │          ^^^^^^^^
       = it can fail with `NotFound(Int)`
       help: did you mean `NotFound`? A tag that's written wrong is a different error

    error: `NotFound`'s payload has 1 value, but this pattern has 0
       ┌─ test.ren:19:5
    19 │     fail NotFound => 0
       │     ^^^^^^^^^^^^^
    |}]

let%expect_test "a fail pattern never binds a whole error" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn whole(id: Int) -> Int =
  match load(id)
    n => n
    fail e => 0
fn main() = ()
|};
  [%expect
    {|
    error: a `fail` pattern can't bind the whole error to a name
      ┌─ test.ren:5:10
    5 │     fail e => 0
      │          ^
      help: match each tag, like `fail NotFound`, or keep the whole outcome as a value with `attempt`, and match `Err(e)`
    |}]

let%expect_test "try match passes on what no arm handles" =
  types
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound(id)
  if id > 9 then fail TooBig(id, 9)
  id
fn guest() -> Int = 0
fn user(id: Int) -> Int =
  try match load(id)
    u => u
    fail NotFound(_) => guest()
fn partly(id: Int) -> Int =
  try match load(id)
    u => u
    fail NotFound(0) => 0
fn renamed(id: Int) -> Int =
  try match load(id)
    u => u
    fail TooBig(_, _) => fail Big
fn main() = ()
|};
  [%expect
    {|
    fn load(id: Int) -> Int ! NotFound(Int) | TooBig(Int, Int)
    fn guest() -> Int
    fn user(id: Int) -> Int ! TooBig(Int, Int)
    fn partly(id: Int) -> Int ! NotFound(Int) | TooBig(Int, Int)
    fn renamed(id: Int) -> Int ! Big | NotFound(Int)
    fn main()
    |}];
  (* with every error handled, there's nothing to pass on *)
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn all(id: Int) -> Int =
  try match load(id)
    u => u
    fail _ => 0
fn each(id: Int) -> Int =
  try match load(id)
    u => u
    fail NotFound(_) => 0
fn main() = ()
|};
  [%expect
    {|
    error: nothing here can fail
      ┌─ test.ren:3:3
    3 │   try match load(id)
      │   ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: every error is handled here, so nothing is passed on: remove the `try`

    error: nothing here can fail
      ┌─ test.ren:7:3
    7 │   try match load(id)
      │   ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `try`
    |}];
  (* a public function declares what its `try match` passes on *)
  types
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound(id)
  if id > 9 then fail TooBig(id, 9)
  id
pub fn user(id: Int) -> Int =
  try match load(id)
    u => u
    fail NotFound(_) => 0
fn main() = ()
|};
  [%expect
    {|
    error: `pub fn user` can fail with `TooBig`, but its signature doesn't say so
      ┌─ test.ren:5:8
    5 │ pub fn user(id: Int) -> Int =
      │        ^^^^
    6 │   try match load(id)
      │             -------- no arm of this `match` handles `TooBig`
      = a public function without `!` can't fail, and its body is checked against that
      help: add `! TooBig(Int, Int)` to its signature, or handle it here with `match`
    |}]

let%expect_test "a call in an arm is marked like any other" =
  types
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn again(id: Int) -> Int =
  match load(id)
    u => u
    fail NotFound(_) => load(1)
fn passed(id: Int) -> Int =
  match load(id)
    u => u
    fail NotFound(_) => try load(1)
fn main() = ()
|};
  [%expect
    {|
    error: `load` can fail, and nothing handles it
      ┌─ test.ren:5:25
    5 │     fail NotFound(_) => load(1)
      │                         ^^^^^^^
      │                         ---- it can fail with `NotFound(Int)`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "matching what a passed function fails with" =
  (* its errors aren't known, so only `fail _` handles them *)
  types
    {|
fn each(g: fn() -> Int) -> Int =
  match g()
    n => n
    fail _ => 0
fn named(g: fn() -> Int) -> Int =
  match g()
    n => n
    fail Bad => 0
fn main() = print(each(fn() => 1))
|};
  [%expect
    {|
    error: `Bad` can't be matched here, because the errors this can fail with aren't known
      ┌─ test.ren:8:10
    8 │     fail Bad => 0
      │          ^^^
      = this can fail with whatever the function passed as `g` fails with, which could be anything
      help: match those with `fail _`, or write the errors `g` can fail with in its type, after `!`
    |}];
  types
    {|
fn guarded(g: fn() -> Int, b: Bool) -> Int =
  match g()
    n => n
    fail _ if b => 0
fn main() = ()
|};
  [%expect
    {|
    error: this `match` doesn't handle every error it can fail with
      ┌─ test.ren:2:3
    2 │   match g()
      │   ^^^^^
      = missing: fail _
      = arms with an `if` guard don't count, since the guard may be false
      = it can fail with whatever a function it was passed fails with, so only `fail _` matches all of it
      help: add a `fail _ =>` arm, or pass the errors on with `try match`
    |}];
  (* a public function passes them on, as its signature says *)
  types
    {|
pub fn each(g: fn() -> Int) -> Int =
  match g()
    n => n
    fail _ => 0
fn main() = ()
|};
  [%expect
    {|
    error: `match` can't handle what `g` fails with here
      ┌─ test.ren:2:9
    2 │   match g()
      │         ^^^
      │         - its type is written `fn(...)`, so what it fails with is passed on to whoever calls `each`
      = a transparent parameter's errors are its function's own, which its signature says it passes on
      help: to handle them, write what it fails with where `g`'s type is written, as in `g: fn() ! Bad`, or pass them on with `try`
    |}]

(* ---- 6. Libraries compose ---- *)

let%expect_test "the same tag from two modules is the same error" =
  types_files
    [
      ( "main.ren",
        {|
import bank
import http
fn pay(inout a: bank.Account) = try &a.debit(5)
fn both(inout a: bank.Account) =
  try &a.debit(5)
  try http.fetch(2)
fn each(xs: Array<Int>) = try bank.each(xs, fn(x) => try http.fetch(x))
fn main() = ()
|}
      );
      ( "bank.ren",
        {|
pub type Refusal = ! Short(by: Int) | Frozen
pub type Account = opaque { balance: Int, frozen: Bool }
  pub fn debit(inout self, m: Int) ! Refusal =
    if self.frozen then fail Frozen
    if self.balance < m then fail Short(m - self.balance)
    self.balance = self.balance - m
pub fn each(xs: Array<Int>, f: fn(Int)) =
  for x in xs
    try f(x)
|}
      );
      ( "http.ren",
        {|
pub fn fetch(n: Int) ! Short(Int) | Timeout(ms: Int) =
  if n < 0 then fail Timeout(n)
  if n > 9 then fail Short(n)
|}
      );
    ];
  [%expect
    {|
    -- bank
    pub type Refusal = ! Short(Int) | Frozen
    pub type Account
      pub fn debit(inout self, m: Int) ! Frozen | Short(Int)
    pub fn each(xs: Array<Int>, f: fn(Int))

    -- http
    pub fn fetch(n: Int) ! Short(Int) | Timeout(Int)

    -- main
    fn pay(inout a: bank.Account) ! Frozen | Short(Int)
    fn both(inout a: bank.Account) ! Frozen | Short(Int) | Timeout(Int)
    fn each(xs: Array<Int>) ! Short(Int) | Timeout(Int)
    fn main()
    |}]

let%expect_test "one error set can't hold two shapes of a tag" =
  types_files
    [
      ( "main.ren",
        {|
import http
import mutex
fn both() =
  try http.fetch(2)
  try mutex.lock()
fn main() = ()
|}
      );
      ("mutex.ren", {|
pub fn lock() ! Timeout = fail Timeout
|});
      ( "http.ren",
        {|
pub fn fetch(n: Int) ! Timeout(ms: Int) = fail Timeout(n)
|} );
    ];
  [%expect
    {|
    error: `Timeout` has two shapes here
      ┌─ main.ren:5:7
    5 │   try mutex.lock()
      │       ^^^^^^^^^^^^
      = from `http.fetch`: `Timeout(Int)`
      = from `mutex.lock`: `Timeout`
      = a tag is its name and its payload's types, so these are two errors with one name
      help: rename one where it comes in: `try match mutex.lock()` with the arm `fail Timeout => fail LockTimeout`
    |}];
  types
    {|
type Slow = ! Timeout(Int)
type Late = ! Slow | Timeout
fn check(x: Int) ! Short(Int) = if x < 0 then fail Short(true)
fn main() = ()
|};
  [%expect
    {|
    error: `Timeout` has two shapes here
      ┌─ test.ren:2:13
    2 │ type Late = ! Slow | Timeout
      │             ^^^^^^^^^^^^^^^^
      = from `Slow`: `Timeout(Int)`
      = written here: `Timeout`
      = a tag is its name and its payload's types, so these are two errors with one name
      help: rename one of them

    error: `Short` has two shapes here
      ┌─ test.ren:3:47
    3 │ fn check(x: Int) ! Short(Int) = if x < 0 then fail Short(true)
      │                                               ^^^^^^^^^^^^^^^^
      = from the signature: `Short(Int)`
      = from this `fail`: `Short(Bool)`
      = a tag is its name and its payload's types, so these are two errors with one name
      help: give one of them another name
    |}]

let%expect_test "a tag of two shapes, learned once the group is done" =
  (* what [a] and [b] fail with is known only once their group is: the
     constraint solver adds each to the other's, and finds the clash. The
     `Bad(Int)` in [a] is its `fail`'s, though that comes after the `try` *)
  check_error
    {|
fn a(n: Int) -> Int = if n > 0 then try b(n - 1) else fail Bad(1)
fn b(n: Int) -> Int =
  if n > 2 then fail Bad(true)
  try a(n)
fn main() = ()
|};
  [%expect
    {|
    error: `Bad` has two shapes here
      ┌─ test.ren:1:41
    1 │ fn a(n: Int) -> Int = if n > 0 then try b(n - 1) else fail Bad(1)
      │                                         ^^^^^^^^
      = from the `fail` on line 1: `Bad(Int)`
      = from `b`: `Bad(Bool)`
      = a tag is its name and its payload's types, so these are two errors with one name
      help: rename one where it comes in: `try match b(n - 1)` with the arm `fail Bad => fail BBad`

    error: `Bad` has two shapes here
      ┌─ test.ren:4:7
    4 │   try a(n)
      │       ^^^^
      = from the `fail` on line 3: `Bad(Bool)`
      = from `a`: `Bad(Int)`
      = a tag is its name and its payload's types, so these are two errors with one name
      help: rename one where it comes in: `try match a(n)` with the arm `fail Bad => fail ABad`
    |}]

let%expect_test "a function passed where its tag has another shape" =
  types
    {|
pub fn each(xs: Array<Int>, f: fn(Int)) ! Bad =
  if xs.len() == 0 then fail Bad
  for x in xs
    try f(x)
fn a(xs: Array<Int>) = try each(xs, fn(x) => if x > 0 then fail Bad(x))
fn main() = ()
|};
  [%expect
    {|
    error: expected `fn(Int) ! Bad`, found `fn(Int) ! Bad(Int)`
      ┌─ test.ren:5:37
    5 │ fn a(xs: Array<Int>) = try each(xs, fn(x) => if x > 0 then fail Bad(x))
      │                                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = `Bad` has two shapes here, `Bad` and `Bad(Int)`: a tag is its name and its payload's types, so these are two errors with one name
      help: give one of them another name, where it fails
    |}]

let%expect_test "a named set is imported like a type" =
  types_files
    [
      ( "main.ren",
        {|
import bank.{Refusal}
pub fn pay(inout a: Int) ! Refusal | Late =
  if a < 0 then fail Late
  try bank.debit(&a, 5)
fn main() = ()
|}
      );
      ( "bank.ren",
        {|
pub type Refusal = ! Short(by: Int) | Frozen
pub fn debit(inout a: Int, m: Int) ! Refusal =
  if a < 0 then fail Frozen
  if a < m then fail Short(m - a)
  a = a - m
|}
      );
    ];
  [%expect
    {|
    -- bank
    pub type Refusal = ! Short(Int) | Frozen
    pub fn debit(inout a: Int, m: Int) ! Frozen | Short(Int)

    -- main
    pub fn pay(inout a: Int) ! Frozen | Late | Short(Int)
    fn main()
    |}]

(* ---- 7. Bugs aren't errors ---- *)

let%expect_test "an index out of bounds panics, and isn't an error" =
  types
    {|
fn third(xs: Array<Int>) -> Int = xs[2]
fn main() = print(attempt third([1]))
|};
  [%expect
    {|
    error: nothing here can fail
      ┌─ test.ren:2:19
    2 │ fn main() = print(attempt third([1]))
      │                   ^^^^^^^
      = `attempt` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `attempt`
    |}];
  run
    {|
fn third(xs: Array<Int>) -> Int = xs[2]
fn main() =
  print(third([1, 2, 3]))
  print(third([1]))
|};
  [%expect
    {|
    3
    error: panic: index 2 is out of bounds for an array of length 1
      ┌─ test.ren:1:35
    1 │ fn third(xs: Array<Int>) -> Int = xs[2]
      │                                   ^^^^^
    |}]

(* ---- what's written ---- *)

let%expect_test "an error set is a type argument only of Result" =
  types
    {|
fn first(r: Result<Int, Int>, s: Option<! Bad>) = ()
fn main() = ()
|};
  [%expect
    {|
    error: `Result`'s second argument is an error set
      ┌─ test.ren:1:25
    1 │ fn first(r: Result<Int, Int>, s: Option<! Bad>) = ()
      │                         ^^^
      = a `Result` holds a value or an error, which `attempt` keeps there
      help: write an error set, after `!`: `Result<Int, ! NotFound>`

    error: `Option` doesn't take an error set
      ┌─ test.ren:1:41
    1 │ fn first(r: Result<Int, Int>, s: Option<! Bad>) = ()
      │                                         ^^^^^
      help: an error set goes after `!` in a signature or a function type, or in `Result<T, ! ...>`
    |}]

let%expect_test "fail names a tag, not a set" =
  types
    {|
type Refusal = ! Short(Int) | Frozen
fn f() = fail Refusal
fn g() ! Short(Int) | Short = ()
fn main() = ()
|};
  [%expect
    {|
    error: `Refusal` is an error set, not a tag
      ┌─ test.ren:2:15
    2 │ fn f() = fail Refusal
      │               ^^^^^^^
      = an error set holds the tags a function can fail with, and `fail` fails with one of them
      help: fail with one of its tags

    error: `Short` has two shapes in this error set
      ┌─ test.ren:3:23
    3 │ fn g() ! Short(Int) | Short = ()
      │                       ^^^^^
      │          ----- `Short(Int)` is here
      = a tag is its name and its payload's types, so these are two errors with one name
      help: give one of them another name
    |}]

(* ---- running it ---- *)

let%expect_test "fail stops a function, and try passes its error on" =
  run
    {|
fn check(n: Int) -> Int = if n < 0 then fail Negative(n) else n
fn twice(n: Int) -> Int = try check(n) + try check(n)
fn main() =
  print(attempt twice(2))
  print(attempt twice(-3))
|};
  [%expect {|
    Ok(4)
    Err(Negative(-3))
    ()
    |}]

let%expect_test "main fails with an error nothing handles" =
  run
    {|
fn freeze(id: Int) = fail Frozen(id)
fn main() =
  print(1)
  try freeze(3)
  print(2)
|};
  [%expect {|
    1
    error: Frozen(3)
    |}]

let%expect_test "match handles a call's errors with fail arms" =
  run
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound
  if id > 9 then fail TooBig(id, 9)
  id
fn describe(id: Int) -> Int =
  match load(id)
    1 => 100
    n => n
    fail NotFound => -1
    fail TooBig(n, max) => n - max
fn any(id: Int) -> Int =
  match load(id)
    n => n
    fail _ => 0
fn either(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound | fail TooBig(_, _) => -2
fn main() =
  print([describe(1), describe(5), describe(0), describe(12)])
  print([any(4), any(0), either(4), either(0), either(10)])
|};
  [%expect {|
    [100, 5, -1, 3]
    [4, 0, 4, -2, -2]
    ()
    |}]

let%expect_test "an arm runs outside what its match handles" =
  (* an arm that fails, failing with another error, isn't handled by its own
     `match`: the error goes on *)
  run
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn renamed(id: Int) -> Int =
  match load(id)
    n => if n > 5 then fail Big else n
    fail NotFound(_) => fail Missing
fn main() =
  print(attempt renamed(1))
  print(attempt renamed(7))
  print(attempt renamed(0))
|};
  [%expect {|
    Ok(1)
    Err(Big)
    Err(Missing)
    ()
    |}]

let%expect_test "try match handles some errors and passes the rest on" =
  run
    {|
fn load(id: Int) -> Int =
  if id == 0 then fail NotFound(id)
  if id > 9 then fail TooBig(id, 9)
  id
fn user(id: Int) -> Int =
  try match load(id)
    u => u
    fail NotFound(_) => 0
fn partly(id: Int) -> Int =
  try match load(id)
    u => u
    fail TooBig(_, 10) => 10
fn main() =
  print([attempt user(3), attempt user(0), attempt user(12)])
  print([attempt partly(10), attempt partly(11)])
|};
  [%expect
    {|
    [Ok(3), Ok(0), Err(TooBig(12, 9))]
    [Err(TooBig(10, 9)), Err(TooBig(11, 9))]
    ()
    |}]

let%expect_test "attempt keeps the outcome, and try fails with it again" =
  run
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn later(r: Result<Int, ! NotFound(Int)>) -> Int = (try r) + 1
fn worth_retrying(r: Result<Int, ! NotFound(Int) | Busy>) -> Bool =
  match r
    Ok(_) => false
    Err(Busy) => true
    Err(NotFound(_)) => false
fn busy() -> Int = fail Busy
fn main() =
  let ok = attempt load(4)
  let err = attempt load(0)
  print([ok, err])
  print([attempt later(ok), attempt later(err)])
  print(ok == attempt load(4))
  print(worth_retrying(attempt busy()))
|};
  [%expect
    {|
    [Ok(4), Err(NotFound(0))]
    [Ok(5), Err(NotFound(0))]
    true
    true
    ()
    |}]

let%expect_test "orelse turns an Option into a value or an error" =
  run
    {|
fn find(xs: Array<Int>, x: Int) -> Option<Int> =
  var found = None
  var i = 0
  for y in xs
    if y == x then found = Some(i)
    i += 1
  found
fn index(xs: Array<Int>, x: Int) -> Int = find(xs, x) orelse fail Missing(x)
fn main() =
  let xs = [5, 6, 7]
  print([attempt index(xs, 6), attempt index(xs, 9)])
  print(find(xs, 9) orelse -1)
|};
  [%expect {|
    [Ok(1), Err(Missing(9))]
    -1
    ()
    |}]

let%expect_test "a call that fails keeps what it changed through &" =
  (* failing doesn't roll back an `&` argument: whatever the call changed
     before it failed stays changed, however the argument was passed *)
  run
    {|
type Log = { items: Array<Int> }
  fn record(inout self, x: Int) =
    &self.items.push(x)
    if x < 0 then fail Negative(x)
fn push_then_fail(inout xs: Array<Int>, x: Int) =
  &xs.push(x)
  fail Full
fn main() =
  var xs = [1]
  let r = attempt push_then_fail(&xs, 2)
  print(r)
  print(xs)
  var logs = [Log { items: [] }]
  print(attempt &logs[0].record(-1))
  print(logs[0].items)
  var all = [Log { items: [] }, Log { items: [] }]
  print(attempt add_all(&all, -5))
  print(all)
fn add_all(inout logs: Array<Log>, x: Int) =
  for l in &logs
    try &l.record(x)
|};
  [%expect
    {|
    Err(Full)
    [1, 2]
    Err(Negative(-1))
    [-1]
    Err(Negative(-5))
    [Log { items: [-5] }, Log { items: [] }]
    ()
    |}]

let%expect_test "a lambda's errors pass through the call it's passed to" =
  run
    {|
fn each(xs: Array<Int>, f) =
  for x in xs
    try f(x)
fn validate(x: Int) = if x > 2 then fail TooBig(x)
fn main() =
  print(attempt each([1, 2], fn(x) => try validate(x)))
  print(attempt each([1, 2, 3, 4], fn(x) => try validate(x)))
|};
  [%expect {|
    Ok(())
    Err(TooBig(3))
    ()
    |}]

let%expect_test "&& doesn't run its right side when the left decides" =
  run
    {|
fn bad() -> Bool = fail Ran
fn main() =
  print(attempt (false && try bad()))
  print(attempt (true || try bad()))
  print(attempt (true && try bad()))
|};
  [%expect {|
    Ok(false)
    Ok(true)
    Err(Ran)
    ()
    |}]

let%expect_test "ren types shows what a module fails with" =
  types
    {|
pub type AccountId = opaque Int
pub type Refusal = ! Short(account: AccountId, by: Int) | Frozen(account: AccountId)
pub type TransferError = ! Refusal | NoSuchAccount(account: AccountId) | SameAccount
pub type Account = opaque { id: AccountId, balance: Int, frozen: Bool }
  pub fn debit(inout self, m: Int) ! Refusal =
    if self.frozen then fail Frozen(self.id)
    if self.balance < m then fail Short(self.id, m - self.balance)
    self.balance = self.balance - m
pub fn find(xs: Array<Account>, id: AccountId) -> Int ! NoSuchAccount(AccountId) =
  first(xs, id) orelse fail NoSuchAccount(id)
fn first(xs: Array<Account>, id: AccountId) -> Option<Int> =
  if id < xs.len() then Some(id) else None
pub fn transfer(inout xs: Array<Account>, from: AccountId, to: AccountId, m: Int) ! TransferError =
  if from == to then fail SameAccount
  let i = try find(xs, from)
  try &xs[i].debit(m)
fn outcome(inout xs: Array<Account>) = attempt transfer(&xs, 0, 1, 5)
fn worth_retrying(r: Result<Unit, ! TransferError>) -> Bool =
  match r
    Ok(_) => false
    Err(Short(_, _)) => true
    Err(Frozen(_)) => false
    Err(NoSuchAccount(_)) => false
    Err(SameAccount) => false
fn main() =
  var xs = []
  print(worth_retrying(outcome(&xs)))
|};
  [%expect
    {|
    pub type Refusal = ! Short(AccountId, Int) | Frozen(AccountId)
    pub type TransferError = ! Refusal | NoSuchAccount(AccountId) | SameAccount
    pub type Account
      pub fn debit(inout self, m: Int) ! Frozen(AccountId) | Short(AccountId, Int)
    pub fn find(xs: Array<Account>, id: AccountId) -> Int ! NoSuchAccount(AccountId)
    fn first(xs: Array<Account>, id: AccountId) -> Option<Int>
    pub fn transfer(inout xs: Array<Account>, from: AccountId, to: AccountId, m: Int) ! Frozen(AccountId) | NoSuchAccount(AccountId) | SameAccount | Short(AccountId, Int)
    fn outcome(inout xs: Array<Account>) -> Result<Unit, ! Frozen(AccountId) | NoSuchAccount(AccountId) | SameAccount | Short(AccountId, Int)>
    fn worth_retrying(r: Result<Unit, ! Frozen(AccountId) | NoSuchAccount(AccountId) | SameAccount | Short(AccountId, Int)>) -> Bool
    fn main() uses Console
    |}]

let%expect_test "an associated value can't fail" =
  types
    {|
type T = { a: Int }
  pub let one: T = fail Missing(1)
  let two: T = T { a: try parse(2) }
fn parse(n: Int) -> Int ! Bad = if n < 0 then fail Bad else n
fn main() = ()
|};
  [%expect
    {|
    error: the associated value `T.one` can fail with `Missing`
      ┌─ test.ren:2:11
    2 │   pub let one: T = fail Missing(1)
      │           ^^^
      │                    --------------- this fails with `Missing`
      = an associated value is made once, when the program starts, so nothing could handle an error it failed with
      help: handle it here with `match`, or make it an associated function, `fn one() ! Missing(Int) = ...`

    error: the associated value `T.two` can fail with `Bad`
      ┌─ test.ren:3:7
    3 │   let two: T = T { a: try parse(2) }
      │       ^^^
      │                           -------- this call can fail with `Bad`
      = an associated value is made once, when the program starts, so nothing could handle an error it failed with
      help: handle it here with `match`, or make it an associated function, `fn two() ! Bad = ...`
    |}]
