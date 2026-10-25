(* Errors (errors.md), organised by the seven things error handling has to
   do. Until stage 6.5 lowers error handling these are checked, not run:
   [checked] prints what `ren types` would. *)

open Helpers

(* ---- 1. You can see it ---- *)

let%expect_test "a call that can fail has to be marked" =
  checked
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
  checked
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
  checked
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

let%expect_test "a lambda's body has markers of its own" =
  (* a transparent parameter passes the lambda's errors to the call, so
     both the call and the lambda's own call are marked *)
  checked
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
  checked
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
  checked
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
  checked
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
    |}]

(* ---- 2. You can't ignore it ---- *)

let%expect_test "fail has the type of anything" =
  checked
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
  checked
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
  checked
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
  checked
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

    error: `pub fn transfer` can fail with `Frozen`, but its signature doesn't say so
      ┌─ test.ren:5:8
    5 │ pub fn transfer(inout a: Int, m: Int) =
      │        ^^^^^^^^
    6 │   try debit(&a, m)
      │       ------------ this call can fail with `Frozen`
      = a public function without `!` can't fail, and its body is checked against that
      help: add `! Frozen(Int)` to its signature, or handle it here with `match`

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
  checked
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
  checked
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
  checked
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
    |}]

(* ---- 4. Passing it on costs one word ---- *)

let%expect_test "functions that call each other share their errors" =
  checked
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
  checked
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

let%expect_test "orelse turns an Option into a value or an error" =
  checked
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
  checked
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
  checked
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

let%expect_test "matching a Result handles every error it can hold" =
  checked
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
    |}];
  (* a misspelled tag is a different error, which the `Result` can't hold *)
  checked
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn typo(id: Int) -> Int =
  match attempt load(id)
    Ok(n) => n
    Err(NotFuond(_)) => 0
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
      help: check the spelling: a tag that's written wrong is a different error
    |}]

let%expect_test "an error is a value only inside a Result" =
  checked
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
  checked {|
fn made() = Err(NotFound(1))
fn main() = ()
|};
  [%expect
    {|
    error: an error is kept in a `Result` only by `attempt`
      ┌─ test.ren:1:13
    1 │ fn made() = Err(NotFound(1))
      │             ^^^
      = `Err` holds an error, and an error isn't a value
      help: write `attempt` before the call that fails, `attempt f()`, to keep what it fails with in a `Result`
    |}]

(* ---- 6. Libraries compose ---- *)

let%expect_test "the same tag from two modules is the same error" =
  checked_files
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
pub type Account = { balance: Int, frozen: Bool }
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
  checked_files
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
  checked
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

let%expect_test "a named set is imported like a type" =
  checked_files
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

(* ---- what's written ---- *)

let%expect_test "an error set is a type argument only of Result" =
  checked
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

let%expect_test "running error handling arrives later" =
  run
    {|
fn check(n: Int) = if n < 0 then fail Negative
fn main() = try check(1)
|};
  [%expect
    {|
    error: `fail` is checked, but running it arrives later in stage 6
      ┌─ test.ren:1:34
    1 │ fn check(n: Int) = if n < 0 then fail Negative
      │                                  ^^^^^^^^^^^^^
      = it's checked, and `ren types` shows what it does
    |}]

let%expect_test "ren types shows what a module fails with" =
  checked
    {|
pub type AccountId = opaque Int
pub type Refusal = ! Short(account: AccountId, by: Int) | Frozen(account: AccountId)
pub type TransferError = ! Refusal | NoSuchAccount(account: AccountId) | SameAccount
pub type Account = { id: AccountId, balance: Int, frozen: Bool }
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
    fn main() uses Io
    |}]
