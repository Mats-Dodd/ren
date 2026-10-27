(* Blocks (foundations.md): this file is stage 10c's specification.

   Each test's name starts with a tag, `[sN accept]` or `[sN reject]`. N is
   the step of the 10c plan that lands it:

     s2  wrappers and record implementations
     s3  second-class blocks
     s4  lexical lookup
     s5  capture by reference and exclusivity
     s6  while, break, cursors, finally

   Until step N lands, the expect block holds today's output, preceded by
   the comment `(* until sN: today's output *)`, and a comment above the
   program says what the step makes of it. Step N removes the comment and
   promotes the target. A test without that comment shows its target
   already. The exclusivity cases are the rows of the research's table
   (exclusivity.md, "Adversarial table"), by number, and their errors are
   its drafted ones, with "lambda" written "block". *)

open Helpers

(* ---- s2: wrappers are calls, and an implementation is a handler ---- *)

let%expect_test "[s2 reject] a wrapper in a with is called instead" =
  (* an error at `retry(3)`, "`with` installs only handlers", with the
     help `call it: try retry(3) fn() => ...` *)
  run
    {|
fn retry(n: Int, body: fn() -> Int ! Flaky) -> Int ! Flaky =
  match body()
    fail Flaky => if n > 1 then try retry(n - 1, body) else fail Flaky
    v => v

fn main() uses Console =
  let n =
    with retry(3) in
      1
  print(n)
|};
  [%expect
    {|
    error: `with` installs only handlers
      ┌─ test.ren:8:10
    8 │     with retry(3) in
      │          ^^^^^^^^ takes a block
      = `retry` is a function that runs a block, so it's called with the body as one
      help: call it: `try retry(3) fn() => ...`
    |}]

let%expect_test "[s2 reject] a wrapper named in a with beside a handler" =
  (* the same error and help, at `timed`, without `try`: it doesn't fail *)
  run
    {|
fn timed(body: fn() -> Int) -> Int uses Clock =
  let n = try body()
  if Clock.now() == Time.epoch then n else 0

fn main() uses Console =
  let n =
    with timed, Clock.frozen(Time.epoch) in
      5
  print(n)
|};
  [%expect
    {|
    error: `with` installs only handlers
      ┌─ test.ren:7:10
    7 │     with timed, Clock.frozen(Time.epoch) in
      │          ^^^^^ takes a block
      = `timed` is a function that runs a block, so it's called with the body as one
      help: call it: `timed() fn() => ...`
    |}]

let%expect_test "[s2 reject] a record implementation of Clock" =
  (* an error at `Clock { ... }`, "an implementation is a handler", with
     the help to write `handler ... for Clock` *)
  run
    {|
fn stopped(t: Time) -> Clock =
  Clock { now: fn() => t, instant: fn() => Instant.zero, sleep: fn(_) => () }

fn main() uses Console =
  with stopped(Time.epoch) in
    print(Clock.now())
|};
  [%expect
    {|
    error: an implementation of `Clock` is a handler, not a record
      ┌─ test.ren:2:3
    2 │   Clock { now: fn() => t, instant: fn() => Instant.zero, sleep: fn(_) => () }
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a record of `Clock`'s operations
      = a record holds data, and code that's kept, like an implementation's operations, is a handler
      help: write a handler, `handler clock() for Clock`, with an arm for each operation under it, like `now() => t`
    |}]

let%expect_test "[s2 reject] a record implementation written in a with" =
  (* the same error, with the help to write `handler ... for Users` *)
  run
    {|
dep Users =
  get: fn(id: Int) -> Int

fn main() uses Console =
  with Users { get: fn(id) => id * 2 } in
    print(Users.get(4))
|};
  [%expect
    {|
    error: an implementation of `Users` is a handler, not a record
      ┌─ test.ren:5:8
    5 │   with Users { get: fn(id) => id * 2 } in
      │        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a record of `Users`'s operations
      = a record holds data, and code that's kept, like an implementation's operations, is a handler
      help: write a handler, `handler users() for Users`, with the arm `get(id) => id * 2` under it
    |}]

let%expect_test "[s2 accept] a local retry called with a block" =
  run
    {|
fn retry(n: Int, body: fn() -> Int ! Flaky) -> Int ! Flaky =
  match body()
    fail Flaky => if n > 1 then try retry(n - 1, body) else fail Flaky
    v => v

handler flaky(fails: Int) for Source =
  var left = fails
  get() =>
    if left > 0 then
      left -= 1
      fail Flaky
    else 42

dep Source =
  get: fn() -> Int ! Flaky

fn main() uses Console =
  with flaky(2) in
    print(attempt retry(3) fn() => try Source.get())
  with flaky(3) in
    print(attempt retry(3) fn() => try Source.get())
|};
  [%expect {|
    Ok(42)
    Err(Flaky)
    ()
    |}]

(* ---- s3: a block can't escape the call it's passed to ---- *)

let%expect_test "[s3 reject] a record field of a function type" =
  (* target: an error at `fn() -> Int`, "a record can't hold a block",
     with the help to store data, or a handler's description *)
  run
    {|
type Button = { label: Str, on_click: fn() -> Int }

fn main() uses Console =
  let b = Button { label: "ok", on_click: fn() => 1 }
  print(b.label)
|};
  [%expect
    {|
    error: a record can't hold a block
      ┌─ test.ren:1:39
    1 │ type Button = { label: Str, on_click: fn() -> Int }
      │                                       ^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: hold data instead, an enum to `match` on, or a handler's description, and pass the block to the call that runs it
    |}]

let%expect_test "[s3 reject] a record literal holding a block" =
  (* target: an error at the block, "a block can't be stored in a
     record" *)
  run
    {|
type Box<T> = { v: T }

fn main() uses Console =
  let b = Box { v: fn() => 1 }
  print((b.v)())
|};
  [%expect
    {|
    error: a block can't be stored in a record
      ┌─ test.ren:4:20
    4 │   let b = Box { v: fn() => 1 }
      │                    ^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: hold data instead, an enum to `match` on, or a handler's description, and pass the block to the call that runs it
    |}]

let%expect_test "[s3 reject] an array of functions" =
  (* target: an error at `[double, triple]`, "a block can't be stored in
     an array" *)
  run
    {|
fn double(x: Int) -> Int = x * 2
fn triple(x: Int) -> Int = x * 3

fn main() uses Console =
  let fs = [double, triple]
  print(fs[1](2))
|};
  [%expect
    {|
    error: a block can't be stored in an array
      ┌─ test.ren:5:12
    5 │   let fs = [double, triple]
      │            ^^^^^^^^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: store data instead, an enum, and `match` on it where the function is called
    |}]

let%expect_test "[s3 reject] a block in a constructor's payload" =
  (* target: an error at the block, "a block can't be stored in
     `Some`" *)
  run
    {|
fn main() uses Console =
  let o = Some(fn(x) => x + 1)
  match o
    Some(f) => print(f(1))
    None => ()
|};
  [%expect
    {|
    error: a block can't be stored in `Some`
      ┌─ test.ren:2:16
    2 │   let o = Some(fn(x) => x + 1)
      │                ^^^^^^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: hold data instead, and pass the block to the call that runs it
    |}]

let%expect_test "[s3 reject] a function in a tuple" =
  (* target: an error at `double`, "a block can't be stored in a tuple" *)
  run
    {|
fn double(x: Int) -> Int = x * 2

fn main() uses Console =
  let (f, n) = (double, 1)
  print(f(n))
|};
  [%expect
    {|
    error: a block can't be stored in a tuple
      ┌─ test.ren:4:17
    4 │   let (f, n) = (double, 1)
      │                 ^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: pass the block as an argument of its own
    |}]

let%expect_test "[s3 reject] a function's result is a block" =
  (* target: an error at the result type, "a block can't be returned",
     with the help to take the argument too, `fn compose(f, g, x)` *)
  run
    {|
fn compose(f: fn(Int) -> Int, g: fn(Int) -> Int) -> fn(Int) -> Int =
  fn(x) => g(f(x))

fn main() uses Console =
  let h = compose(fn(x) => x + 1, fn(x) => x * 2)
  print(h(3))
|};
  [%expect
    {|
    error: a block can't be returned
      ┌─ test.ren:1:53
    1 │ fn compose(f: fn(Int) -> Int, g: fn(Int) -> Int) -> fn(Int) -> Int =
      │                                                     ^^^^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: take the block's arguments as parameters too, and return what it gives
    |}]

let%expect_test "[s3 reject] an if whose branches are blocks" =
  (* target: an error at the `if`, "a block can only be called or passed
     where it's written" *)
  run
    {|
fn apply(f: fn(Int) -> Int, x: Int) -> Int = try f(x)

fn main() uses Console =
  let c = true
  print(apply(if c then fn(x) => x + 1 else fn(x) => x * 2, 5))
|};
  [%expect
    {|
    error: a block can only be called or passed where it's written
      ┌─ test.ren:5:15
    5 │   print(apply(if c then fn(x) => x + 1 else fn(x) => x * 2, 5))
      │               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: call the block in each branch: `if c then f(x) else g(x)`
    |}]

let%expect_test "[s3 reject] a match whose arms are functions" =
  (* target: an error at the `match`, "`let` binds one block written
     right there" *)
  run
    {|
fn double(x: Int) -> Int = x * 2
fn triple(x: Int) -> Int = x * 3
fn apply(f: fn(Int) -> Int, x: Int) -> Int = try f(x)

fn main() uses Console =
  let n = 1
  let g =
    match n
      0 => double
      _ => triple
  print(apply(g, 5))
|};
  [%expect
    {|
    error: `let` binds one block written right there
      ┌─ test.ren:8:5
    8 │     match n
      │     ^^^^^^^ not a `fn` written here
      = a `let` names one block, so the code it runs is known where it's called
      help: choose inside one block: `let g = fn(x) => if ... then double(x) else triple(x)`
    |}]

let%expect_test "[s3 reject] var holding a block" =
  (* target: an error at the `var`, "a `var` can't hold a block", with
     the help `let f = fn() => ...` *)
  run
    {|
fn main() uses Console =
  var f = fn() => 1
  f = fn() => 2
  print(f())
|};
  [%expect
    {|
    error: a `var` can't hold a block
      ┌─ test.ren:2:7
    2 │   var f = fn() => 1
      │       ^ a block
      = a block lives only as long as the call it's passed to
      help: bind it with `let`: `let f = fn() => ...`
    |}]

let%expect_test "[s3 reject] let of a named function" =
  (* target: an error at `double`, "`let` binds one block written right
     there", with the help to call `double` where it's needed, or write
     `let f = fn(x) => double(x)` *)
  run
    {|
fn double(x: Int) -> Int = x * 2

fn main() uses Console =
  let f = double
  print(f(4))
|};
  [%expect
    {|
    error: `let` binds one block written right there
      ┌─ test.ren:4:11
    4 │   let f = double
      │           ^^^^^^ not a `fn` written here
      = a `let` names one block, so the code it runs is known where it's called
      help: pass `double` where it's needed, or write `let f = fn(x) => double(x)`
    |}]

let%expect_test "[s3 reject] let of an if between two blocks" =
  (* target: an error at the `if`, "`let` binds one block written right
     there" *)
  run
    {|
fn main() uses Console =
  let c = false
  let f = fn(x) => x + 1
  let h = fn(x) => x * 2
  let g = if c then f else h
  print(g(5))
|};
  [%expect
    {|
    error: `let` binds one block written right there
      ┌─ test.ren:5:11
    5 │   let g = if c then f else h
      │           ^^^^^^^^^^^^^^^^^^ not a `fn` written here
      = a `let` names one block, so the code it runs is known where it's called
      help: choose inside one block: `let g = fn(x) => if ... then f(x) else h(x)`
    |}]

let%expect_test "[s3 reject] a block given to a generic parameter" =
  (* target: an error at `double`, "a generic `T` can't be a block": `T`
     could be stored *)
  run
    {|
fn id<T>(x: T) -> T = x
fn double(x: Int) -> Int = x * 2

fn main() uses Console =
  print(id(double)(3))
|};
  [%expect
    {|
    error: a generic `T` can't be a block
      ┌─ test.ren:5:12
    5 │   print(id(double)(3))
      │            ^^^^^^ a block
      = a type variable stands for data, which can be stored or returned
      help: pass a block only to a parameter written `fn(...)`
    |}]

let%expect_test "[s3 reject] printing a function" =
  (* target: the same error, at `double` in `print(double)` *)
  run
    {|
fn double(x: Int) -> Int = x * 2

fn main() uses Console =
  print(double)
|};
  [%expect
    {|
    error: a generic `T` can't be a block
      ┌─ test.ren:4:9
    4 │   print(double)
      │         ^^^^^^ a block
      = a type variable stands for data, which can be stored or returned
      help: pass a block only to a parameter written `fn(...)`
    |}]

let%expect_test "[s3 reject] comparing functions" =
  (* target: an error at `inc == inc`, "a block can only be called or
     passed" *)
  run
    {|
fn inc(x: Int) -> Int = x + 1

fn main() uses Console =
  print(inc == inc)
|};
  [%expect
    {|
    error: a block can only be called or passed, not compared
      ┌─ test.ren:4:9
    4 │   print(inc == inc)
      │         ^^^^^^^^^^ a block
      = a block lives only as long as the call it's passed to
      help: compare what it returns instead
    |}]

let%expect_test "[s3 reject] an associated value holding a block" =
  (* target: an error at the value's type, "an associated value can't
     hold a block" *)
  run
    {|
type Steps = { n: Int }
  let step: fn(Int) -> Int = fn(x) => x + 1

fn main() uses Console =
  print(Steps.step(1))
|};
  [%expect
    {|
    error: an associated value can't hold a block
      ┌─ test.ren:2:13
    2 │   let step: fn(Int) -> Int = fn(x) => x + 1
      │             ^^^^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: make it a function: `fn step(...)`
    |}]

let%expect_test "[s3 reject] a handler parameter of a function type" =
  (* target: an error at `f: fn() -> Int`, "a handler's parameters are
     data", with the help to pass the data, or make the behaviour a
     dependency *)
  run
    {|
dep N =
  get: fn() -> Int

handler h(f: fn() -> Int) for N =
  get() => f()

fn main() uses Console =
  with h(fn() => 3) in
    print(N.get())
|};
  [%expect
    {|
    error: a handler's parameters are data
      ┌─ test.ren:4:11
    4 │ handler h(f: fn() -> Int) for N =
      │           ^^^^^^^^^^^^^^ `f` is a block
      = a handler's description is a value, which can outlive the call that made it
      help: pass the data, or make the behaviour a dependency
    |}]

let%expect_test "[s3 reject] handler state holding a block" =
  (* target: an error at the `var`, "a handler's state can't hold a
     block" *)
  run
    {|
dep N =
  get: fn() -> Int

handler h() for N =
  var k = fn() => 1
  get() => k()

fn main() uses Console =
  with h() in
    print(N.get())
|};
  [%expect
    {|
    error: a handler's state can't hold a block
      ┌─ test.ren:5:7
    5 │   var k = fn() => 1
      │       ^ a block
      = a block lives only as long as the call it's passed to
      help: keep data in the state, and call a function from the operation
    |}]

let%expect_test "[s3 reject] a description's argument holding a block" =
  (* target: an error at the block, "a handler's parameters are data": a
     description is a value, which can outlive the block *)
  run
    {|
dep N =
  get: fn() -> Int

handler holding(v) for N =
  get() => 1

fn main() uses Console =
  with holding(fn() => 2) in
    print(N.get())
|};
  [%expect
    {|
    error: a handler's parameters are data
      ┌─ test.ren:8:16
    8 │   with holding(fn() => 2) in
      │                ^^^^^^^^^ a block
      = a handler's description is a value, which can outlive the call that made it
      help: pass the data, or make the behaviour a dependency
    |}]

let%expect_test "[s3 reject] a block's type naming its dependencies' row" =
  (* target: an error at `..d`, "a block's errors and dependencies aren't
     named", with the help to remove it: a block's dependencies are found
     where it's written *)
  types
    {|
fn each(xs: Array<Int>, f: fn(Int) uses ..d) uses ..d =
  for x in xs
    f(x)

fn main() uses Console = each([1, 2], fn(x) => print(x))
|};
  [%expect
    {|
    error: a block's errors and dependencies aren't named
      ┌─ test.ren:1:43
    1 │ fn each(xs: Array<Int>, f: fn(Int) uses ..d) uses ..d =
      │                                           ^ `..d` names them
      = a block is only called, never kept, so what it fails with and uses is what the call it's passed to does
      help: leave `..d` out of the block's type
    |}]

let%expect_test "[s3 reject] a block's type naming its errors' row" =
  (* target: the same error, at `..e`: a block passes on its errors, so a
     row needn't be named *)
  types
    {|
fn twice(f: fn() -> Int ! ..e) -> Int ! ..e = try f() + try f()

fn main() uses Console = print(twice(fn() => 2))
|};
  [%expect
    {|
    error: a block's errors and dependencies aren't named
      ┌─ test.ren:1:29
    1 │ fn twice(f: fn() -> Int ! ..e) -> Int ! ..e = try f() + try f()
      │                             ^ `..e` names them
      = a block is only called, never kept, so what it fails with and uses is what the call it's passed to does
      help: leave `..e` out of the block's type
    |}]

let%expect_test "[s3 accept] a let bound to a block, then called" =
  run {|
fn main() uses Console =
  let f = fn(x) => x + 1
  print(f(2))
|};
  [%expect {|
    3
    ()
    |}]

let%expect_test "[s3 accept] a named function passed as an argument" =
  run
    {|
fn double(x: Int) -> Int = x * 2

fn main() uses Console =
  print([1, 2, 3].map(double))
|};
  [%expect {|
    [2, 4, 6]
    ()
    |}]

let%expect_test "[s3 accept] a block parameter passed on (row 11)" =
  run
    {|
type Tree =
  | Leaf
  | Node(l: Tree, v: Int, r: Tree)

fn walk(t: Tree, f: fn(Int)) =
  match t
    Leaf => ()
    Node(l, v, r) =>
      try walk(l, f)
      try f(v)
      try walk(r, f)

fn main() uses Console =
  walk(Node(Node(Leaf, 1, Leaf), 2, Node(Leaf, 3, Leaf)), fn(v) => print(v))
|};
  [%expect {|
    1
    2
    3
    ()
    |}]

(* ---- s4: a block's dependencies are found where it's written ---- *)

let%expect_test "[s4 accept] a helper that installs what its block's type lists"
    =
  (* `body`'s type lists `Net`, so `with_fake_net` provides it: the
     handler reaches the block's `Net` calls, and `main` uses only
     `Console`. `with_fake_net`'s type is as written *)
  let src =
    {|
dep Net =
  get: fn(url: Str) -> Str

handler fake_net() for Net =
  get(url) => "fake ".concat(url)

fn with_fake_net(body: fn() uses Net) = with fake_net() in try body()

fn main() uses Console =
  with_fake_net(fn() => print(Net.get("a")))
|}
  in
  types src;
  [%expect
    {|
    dep Net
      get: fn(Str) -> Str
    handler fake_net() for Net
    fn with_fake_net(body: fn() uses Net)
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    fake a
    ()
    |}]

let%expect_test "[s4 accept] a block's Clock is charged where it's written" =
  (* `f`'s type lists nothing, so `at(1)` doesn't handle the block's
     `Clock.now()`: the clock installed where the block is written does,
     and `main` prints `Time(0)` *)
  let src =
    {|
fn at(minutes: Int) -> Clock = Clock.frozen(Time.epoch + Duration.minutes(minutes))

fn run_at(f: fn() -> Time) -> Time = with at(1) in try f()

fn main() uses Console =
  with Clock.frozen(Time.epoch) in
    print(run_at(fn() => Clock.now()))
|}
  in
  types src;
  [%expect
    {|
    fn at(minutes: Int) -> Clock
    fn run_at(f: fn() -> Time) -> Time
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Time(0)
    ()
    |}]

let%expect_test
    "[s4 accept] a wrapper can't handle its block's calls by accident" =
  (* `quietly` installs a console that drops what's written, for its own
     use; the block's `print` still reaches `main`'s, which prints `hi` *)
  run
    {|
handler silent() for Console =
  write(line) => ()
  error(line) => ()

fn quietly(body: fn()) =
  with silent() in
    print("quietly's own line")
    try body()

fn main() uses Console =
  quietly(fn() => print("hi"))
|};
  [%expect {|
    hi
    ()
    |}]

let%expect_test "[s4 accept] next called from a block inside an arm" =
  (* the block is written in the arm, so `next` is the arm's: 5 + 10 +
     15 *)
  run
    {|
dep N =
  get: fn(k: Int) -> Int

handler base() for N =
  get(k) => k

handler summed() over N =
  get(k) => [1, 2, 3].map(fn(i) => next.get(k) * i).sum()

fn main() uses Console =
  with summed() over base() in
    print(N.get(5))
|};
  [%expect {|
    30
    ()
    |}]

let%expect_test
    "[s4 accept] a named function passed as a value uses what's installed \
     where it's used" =
  (* `stamp` is passed where `main`'s frozen clock is installed, so its
     `Clock.now()` is that one's, not the one `apply_at` installs: it
     prints `Time(0)`, and `apply_at` uses nothing *)
  let src =
    {|
fn stamp(x: Int) -> Time uses Clock = Clock.now()

fn apply_at(f: fn(Int) -> Time) -> Time =
  with Clock.frozen(Time.epoch + Duration.minutes(1)) in try f(0)

fn main() uses Console =
  with Clock.frozen(Time.epoch) in
    print(apply_at(stamp))
|}
  in
  types src;
  [%expect
    {|
    fn stamp(x: Int) -> Time uses Clock
    fn apply_at(f: fn(Int) -> Time) -> Time
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Time(0)
    ()
    |}]

let%expect_test "[s4 accept] a block's dependencies are its writer's" =
  (* `each` lists no dependencies for `f`, so it uses none, and the
     block's `print` makes `main` use `Console`: `fn each(xs: Array<Int>,
     f: fn(Int))`, without a row *)
  types
    {|
fn each(xs: Array<Int>, f: fn(Int)) =
  for x in xs
    try f(x)

fn main() uses Console = each([1, 2], fn(x) => print(x))
|};
  [%expect
    {|
    fn each(xs: Array<Int>, f: fn(Int))
    fn main() uses Console
    |}]

let%expect_test
    "[s4 accept] an operation passed as a value, given its dependency" =
  (* `f`'s type lists `Net`, so the block `Net.get` makes is given
     `ask`'s, and `main` uses no `Net` *)
  run
    {|
dep Net =
  get: fn(url: Str) -> Str

handler fake_net() for Net =
  get(url) => "fake ".concat(url)

fn ask(f: fn(Str) -> Str uses Net) -> Str = with fake_net() in try f("a")

fn main() uses Console = print(ask(Net.get))
|};
  [%expect {|
    fake a
    ()
    |}]

let%expect_test "[s4 accept] a let of a block whose written type lists Net" =
  (* the type written on the `let` is where the block is written, so it's
     given `Net` by whoever it's passed to *)
  run
    {|
dep Net =
  get: fn(url: Str) -> Str

handler fake_net() for Net =
  get(url) => "fake ".concat(url)

fn with_fake_net(body: fn() uses Net) = with fake_net() in try body()

fn main() uses Console =
  let b: fn() uses Net = fn() => print(Net.get("let"))
  with_fake_net(b)
|};
  [%expect {|
    fake let
    ()
    |}]

let%expect_test
    "[s4 reject] a block whose type lists less than its callee gives" =
  (* `b`'s and `body`'s types list nothing, so what they use is found where
     they're written: neither can take `Net` from `with_fake_net` *)
  types
    {|
dep Net =
  get: fn(url: Str) -> Str

handler fake_net() for Net =
  get(url) => "fake ".concat(url)

fn with_fake_net(body: fn() uses Net) = with fake_net() in try body()
fn pass_on(body: fn()) = try with_fake_net(body)

fn main() uses Console =
  let b = fn() => print(1)
  with_fake_net(b)
|};
  [%expect
    {|
    error: expected `fn() uses Net`, found `fn()`
      ┌─ test.ren:8:44
    8 │ fn pass_on(body: fn()) = try with_fake_net(body)
      │                                            ^^^^
      = a block is given only the dependencies its type lists, and this one's lists fewer than its callee gives
      help: list them in `body`'s type: `body: fn() uses Net`

    error: expected `fn() uses Net`, found `fn()`
       ┌─ test.ren:12:17
    12 │   with_fake_net(b)
       │                 ^
       = a block is given only the dependencies its type lists, and this one's lists fewer than its callee gives
       help: write its type where it's written: `let b: fn() uses Net = fn ...`
    |}]

(* ---- s5: a block captures by reference, and one rule keeps that
   sound ---- *)

(* The helpers the rows call: [each] calls its block on each item, and the
   others take a place with `&` beside a block. *)
let helpers =
  {|
fn each(xs: Array<Int>, f: fn(Int)) =
  for x in xs
    try f(x)

fn run(f: fn()) = try f()

fn twice(f: fn(), g: fn()) =
  try f()
  try g()

fn bump(inout n: Int) = n += 1

fn bump2(inout a: Int, inout b: Int) =
  a += 1
  b += 1

fn bump_with(inout n: Int, f: fn()) =
  n += 1
  try f()

fn retain(inout xs: Array<Int>, f: fn(Int) -> Bool) =
  var kept: Array<Int> = []
  for x in xs
    if try f(x) then &kept.push(x)
  xs = kept

fn read_with(xs: Array<Int>, f: fn()) uses Console =
  try f()
  print(xs.len())

fn if_else(c: Bool, t: fn(), e: fn()) = if c then try t() else try e()
|}

let%expect_test "[s5 accept] row 1: a block changes an outer var" =
  (* target: prints `6` *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var n = 0
  each([1, 2, 3], fn(x) => n += x)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:28
    35 │   each([1, 2, 3], fn(x) => n += x)
       │                            ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 reject] row 2: a var passed with & and changed by a block"
    =
  (* target: "`n` is changed by this block and passed with `&` to the same
     call", with the help "change `n` in one place: pass the block's
     change as a value, or apply it after the call" *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var n = 0
  bump_with(&n, fn() => n += 1)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:25
    35 │   bump_with(&n, fn() => n += 1)
       │                         ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 reject] row 3: a block reads what the call changes" =
  (* target: "`xs` is read by this block while the call changes it",
     labels "changed for the whole call" and "read here", the note "a
     block runs during the call it's passed to", and the help "read it
     first: `let n = xs.len()`" *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var xs = [1, 2, 3, 4]
  retain(&xs, fn(x) => x < xs.len())
  print(xs)
|}
    );
  (* until s5: today's output *)
  [%expect {|
    [1, 2, 3]
    ()
    |}]

let%expect_test "[s5 reject] row 4: a block changes what the call borrows" =
  (* target: "`xs` is changed by this block while the call reads it": the
     call borrows `xs` without counting it *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var xs = [1, 2]
  read_with(xs, fn() => &xs.push(3))
  print(xs)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `xs`, a variable from outside it
       ┌─ test.ren:35:26
    35 │   read_with(xs, fn() => &xs.push(3))
       │                          ^^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 accept] row 5: a copied Int beside a block that changes it"
    =
  (* target: prints `1` then `1`: the call was given 0 *)
  run
    (helpers
   ^ {|
fn show_then(n: Int, f: fn()) uses Console =
  try f()
  print(n + 1)

fn main() uses Console =
  var n = 0
  show_then(n, fn() => n += 1)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:39:24
    39 │   show_then(n, fn() => n += 1)
       │                        ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 accept] row 6: sibling blocks change the same var" =
  (* target: prints `1` then `0` *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var n = 0
  if_else(true, fn() => n += 1, fn() => n -= 1)
  print(n)
  if_else(false, fn() => n += 1, fn() => n -= 1)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:25
    35 │   if_else(true, fn() => n += 1, fn() => n -= 1)
       │                         ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside

    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:41
    35 │   if_else(true, fn() => n += 1, fn() => n -= 1)
       │                                         ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside

    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:37:26
    37 │   if_else(false, fn() => n += 1, fn() => n -= 1)
       │                          ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside

    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:37:42
    37 │   if_else(false, fn() => n += 1, fn() => n -= 1)
       │                                          ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test
    "[s5 reject] row 8: inside a block, & and a block that changes it" =
  (* target: the error of row 2, inside the outer block *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var n = 0
  run(fn() => bump_with(&n, fn() => n += 1))
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:26
    35 │   run(fn() => bump_with(&n, fn() => n += 1))
       │                          ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside

    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:37
    35 │   run(fn() => bump_with(&n, fn() => n += 1))
       │                                     ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test
    "[s5 reject] row 9: a block parameter's call given a block that calls it" =
  (* rule A. target: an error at the outer `f(...)`'s argument, "a block
     that calls `f` can't be passed to `f`", with the help to write a
     named recursive function *)
  types
    {|
fn rec(f: fn(fn())) =
  try f(fn() =>
    let _ = attempt f(fn() => ())
    ())

fn main() = 1
|};
  (* until s5: today's output *)
  [%expect {|
    fn rec(f: fn(fn()))
    fn main() -> Int
    |}]

let%expect_test
    "[s5 reject] row 10: fix passes a block parameter to its own call" =
  (* rule A. target: an error at `fn(k) => fix(f, k)`, "a block that
     captures `f` can't be passed to `f`", with the help to write it as a
     named recursive function *)
  types
    {|
fn fix(f: fn(fn(Int) -> Int, Int) -> Int, n: Int) -> Int =
  try f(fn(k) =>
    match fix(f, k)
      fail _ => 0
      v => v, n)

fn main() = 1
|};
  (* until s5: today's output *)
  [%expect
    {|
    fn fix(f: fn(fn(Int) -> Int, Int) -> Int, n: Int) -> Int
    fn main() -> Int
    |}]

let%expect_test
    "[s5 accept] row 11: a block parameter passed down changes a var" =
  (* target: prints `6` *)
  run
    {|
type Tree =
  | Leaf
  | Node(l: Tree, v: Int, r: Tree)

fn walk(t: Tree, f: fn(Int)) =
  match t
    Leaf => ()
    Node(l, v, r) =>
      try walk(l, f)
      try f(v)
      try walk(r, f)

fn main() uses Console =
  var total = 0
  walk(Node(Node(Leaf, 1, Leaf), 2, Node(Leaf, 3, Leaf)), fn(v) => total += v)
  print(total)
|};
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `total`, a variable from outside it
       ┌─ test.ren:15:68
    15 │   walk(Node(Node(Leaf, 1, Leaf), 2, Node(Leaf, 3, Leaf)), fn(v) => total += v)
       │                                                                    ^^^^^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 accept] row 12: a block can't reach its callee's variables"
    =
  (* target: prints `1` then `1` *)
  run
    (helpers
   ^ {|
fn inner(inout own: Int, f: fn()) =
  own += 1
  try f()

fn outer(f: fn()) uses Console =
  var own = 0
  inner(&own, f)
  print(own)

fn main() uses Console =
  var n = 0
  outer(fn() => n += 1)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:44:17
    44 │   outer(fn() => n += 1)
       │                 ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 accept] row 13: an inout parameter and a block never alias"
    =
  (* the caller rejects a block that captures `n`, so `g`'s `inout`
     parameter and the block's captures are different places. target:
     prints `1` then `1` *)
  run
    (helpers
   ^ {|
fn h(inout k: Int, f: fn()) =
  k += 1
  try f()

fn g(inout n: Int, f: fn()) = h(&n, f)

fn main() uses Console =
  var n = 0
  var m = 0
  g(&n, fn() => m += 1)
  print(n)
  print(m)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `m`, a variable from outside it
       ┌─ test.ren:42:17
    42 │   g(&n, fn() => m += 1)
       │                 ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test
    "[s5 accept] row 14: one let-bound block passed twice to one call" =
  (* target: prints `2` *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var n = 0
  let f = fn() => n += 1
  twice(f, f)
  print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:35:19
    35 │   let f = fn() => n += 1
       │                   ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 accept] row 15: a block reads a var when it runs" =
  (* target: prints `6` *)
  run
    {|
fn main() uses Console =
  var n = 1
  let f = fn() => n + 1
  n += 5
  print(f())
|};
  (* until s5: today's output *)
  [%expect {|
    2
    ()
    |}]

let%expect_test
    "[s5 accept] row 16: a loop over a snapshot, and a block that pushes" =
  (* target: prints `[1, 2, 1, 2]` *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var xs = [1, 2]
  for x in xs
    run(fn() => &xs.push(x))
  print(xs)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `xs`, a variable from outside it
       ┌─ test.ren:36:18
    36 │     run(fn() => &xs.push(x))
       │                  ^^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s5 reject] row 17: a block reads the array a for & changes" =
  (* target: "`xs` is read by this block while the loop changes it", the
     loop's label "changed for the whole loop" *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var xs = [1, 2]
  for p in &xs
    run(fn() => print(xs.len()))
    p += 1
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: `xs` is being changed by the `for` loop around this
       ┌─ test.ren:36:23
    35 │   for p in &xs
       │            --- the loop changes `xs` here
    36 │     run(fn() => print(xs.len()))
       │                       ^^
       help: inside the loop, use `p`
    |}]

let%expect_test "[s5 accept] row 27: two & on different fields" =
  run
    (helpers
   ^ {|
type R = { a: Int, b: Int }

fn main() uses Console =
  var r = R { a: 1, b: 2 }
  bump2(&r.a, &r.b)
  print(r)
|}
    );
  [%expect {|
    R { a: 2, b: 3 }
    ()
    |}]

let%expect_test "[s5 reject] row 28: & on a record beside one of its fields" =
  (* target: "`r` is passed with `&` while `r.a` is read in the same
     call": a place overlaps its prefixes *)
  run
    (helpers
   ^ {|
type R = { a: Int, b: Int }

fn set_a(inout r: R, n: Int) = r.a = n

fn main() uses Console =
  var r = R { a: 1, b: 2 }
  set_a(&r, r.a)
  print(r)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: this call changes `r`, so no other argument can use it
       ┌─ test.ren:39:13
    39 │   set_a(&r, r.a)
       │             ^^^
       │         -- passed with `&` here
       = an argument passed with `&` has to be the only way the call can reach that value
       = reading part of `r` counts as using it
       help: read it into a `let` before the call, and pass that
    |}]

let%expect_test "[s5 reject] row 29: two & on indices of one array" =
  (* target: "`xs` is passed with `&` twice; indices may be equal", with
     the help `xs.swap(i, j)` *)
  run
    (helpers
   ^ {|
fn main() uses Console =
  var xs = [1, 2, 3]
  let i = 0
  let j = 2
  bump2(&xs[i], &xs[j])
  print(xs)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: `xs` is passed with `&` twice in this call
       ┌─ test.ren:37:17
    37 │   bump2(&xs[i], &xs[j])
       │                 ^^^^^^
       │         ------ passed with `&` here
       = an argument passed with `&` has to be the only way the call can reach that value
    |}]

let%expect_test "[s5 accept] row 30: an argument read before the & starts" =
  run
    {|
fn main() uses Console =
  var xs = [1, 2]
  &xs.push(xs.len())
  print(xs)
|};
  [%expect {|
    [1, 2, 2]
    ()
    |}]

(* A store the arms of rows 31 to 34 go over. *)
let store =
  {|
dep Store =
  load: fn(k: Int) -> Int
  visit: fn(f: fn())

handler base() for Store =
  load(k) => k * 10
  visit(f) => f()

fn update(inout m: Map<Int, Int>, k: Int, f: fn(Int) -> Int) =
  &m.set(k, try f(m.get(k) orelse 0))

fn each_mut(inout xs: Array<Int>, f: fn(Int) -> Int) =
  for x in &xs
    x = try f(x)
|}

let%expect_test
    "[s5 reject] row 31: handler state changed across a dependency call" =
  (* target: "`cache` is changed across a dependency call", the note "other
     tasks can run this handler at a dependency call", and the help "load
     first: `let v = next.load(k)`, then `&cache.set(k, v)`" *)
  run
    (store
   ^ {|
handler cached() over Store =
  var cache: Map<Int, Int> = Map.empty
  load(k) =>
    update(&cache, k, fn(v) => next.load(k))
    cache.get(k) orelse 0
  visit(f) => next.visit(f)

fn main() uses Console =
  with cached() over base() in
    print(Store.load(2))
|}
    );
  (* until s5: today's output *)
  [%expect {|
    20
    ()
    |}]

let%expect_test
    "[s5 accept] row 32: the dependency call is an argument, made before the &"
    =
  run
    (store
   ^ {|
handler cached() over Store =
  var cache: Map<Int, Int> = Map.empty
  load(k) =>
    &cache.set(k, next.load(k))
    cache.get(k) orelse 0
  visit(f) => next.visit(f)

fn main() uses Console =
  with cached() over base() in
    print(Store.load(2))
|}
    );
  [%expect {|
    20
    ()
    |}]

let%expect_test
    "[s5 reject] row 33: a block parameter called while handler state is \
     changed" =
  (* target: "`items` is changed across a call of `f`", the note "`f` can
     run this handler again", and the help to call `f` before or after
     the change *)
  run
    (store
   ^ {|
handler listed() over Store =
  var items = [1, 2]
  load(k) => next.load(k)
  visit(f) =>
    each_mut(&items, fn(i) =>
      f()
      i + 1)

fn main() uses Console =
  with listed() over base() in
    Store.visit(fn() => ())
|}
    );
  (* until s5: today's output *)
  [%expect {| () |}]

let%expect_test
    "[s5 accept] row 34: a block parameter called, then handler state changed" =
  run
    (store
   ^ {|
handler listed() over Store uses Console =
  var items = [1, 2]
  load(k) => items.len()
  visit(f) =>
    f()
    &items.push(1)

fn main() uses Console =
  with listed() over base() in
    Store.visit(fn() => ())
    print(Store.load(0))
|}
    );
  [%expect {|
    3
    ()
    |}]

let%expect_test
    "[s5 accept] row 36: a block changes a var and calls an operation" =
  (* the handler is installed outside the block's var, and holds only
     data, so it can't reach `n`. target: prints `20` *)
  run
    (helpers ^ store
   ^ {|
fn main() uses Console =
  with base() in
    var n = 0
    run(fn() => n += Store.load(2))
    print(n)
|}
    );
  (* until s5: today's output *)
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
       ┌─ test.ren:51:17
    51 │     run(fn() => n += Store.load(2))
       │                 ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

(* ---- s6: while, break, cursors, finally where it's written ---- *)

let%expect_test "[s6 accept] while, and break" =
  (* target: prints `3` *)
  run
    {|
fn main() uses Console =
  var i = 0
  while true
    i += 1
    if i == 3 then break
  print(i)
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: expected the end of the line, found `true`
      ┌─ test.ren:3:9
    3 │   while true
      │         ^^^^
    |}]

let%expect_test "[s6 accept] while whose condition ends it" =
  (* target: prints `[1, 2, 4, 8]` *)
  run
    {|
fn main() uses Console =
  var n = 1
  var seen: Array<Int> = []
  while n < 10
    &seen.push(n)
    n *= 2
  print(seen)
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: expected the end of the line, found `n`
      ┌─ test.ren:4:9
    4 │   while n < 10
      │         ^
    |}]

let%expect_test "[s6 reject] break outside a loop" =
  (* target: "`break` is only inside a loop", with the help to return a
     value instead *)
  run {|
fn main() uses Console =
  print(1)
  break
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: there's no variable named `break`
      ┌─ test.ren:3:3
    3 │   break
      │   ^^^^^
    |}]

let%expect_test "[s6 reject] break inside a block inside a loop" =
  (* target: "a block can't `break` out of the loop it's written in", the
     note "a block runs during the call it's passed to", and the help to
     return a `Bool` and break after the call *)
  run
    {|
fn run(f: fn()) = try f()

fn main() uses Console =
  for x in [1, 2, 3]
    run(fn() => if x == 2 then break)
    print(x)
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: there's no variable named `break`
      ┌─ test.ren:5:32
    5 │     run(fn() => if x == 2 then break)
      │                                ^^^^^
    |}]

let%expect_test "[s6 accept] break in a for over an array" =
  (* target: prints `1` then `2` *)
  run
    {|
fn main() uses Console =
  for x in [1, 2, 3, 4]
    if x == 3 then break
    print(x)
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: there's no variable named `break`
      ┌─ test.ren:3:20
    3 │     if x == 3 then break
      │                    ^^^^^
    |}]

let%expect_test "[s6 accept] break in a for & keeps what was written" =
  (* the element written before the `break` is kept. target: prints `[11,
     12, 3]` *)
  run
    {|
fn main() uses Console =
  var ps = [1, 2, 3]
  for p in &ps
    p += 10
    if p == 12 then break
  print(ps)
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: there's no variable named `break`
      ┌─ test.ren:5:21
    5 │     if p == 12 then break
      │                     ^^^^^
    |}]

(* A cursor: a value with `next(inout self) -> Option<T>`, which owns
   what it goes over. *)
let each_cursor =
  {|
type Each = { xs: Array<Int>, i: Int }
  fn next(inout self) -> Option<Int> =
    if self.i < self.xs.len() then
      self.i += 1
      Some(self.xs[self.i - 1])
    else None
|}

let%expect_test "[s6 accept] the cursor's next, called by hand" =
  run
    (each_cursor
   ^ {|
fn main() uses Console =
  var c = Each { xs: [1, 2], i: 0 }
  print(&c.next())
  print(&c.next())
  print(&c.next())
|}
    );
  [%expect {|
    Some(1)
    Some(2)
    None
    ()
    |}]

let%expect_test "[s6 accept] for & over a cursor, with break, then resumed" =
  (* the cursor keeps its place: take two, then the rest. target: prints
     `1`, `2`, then `3`, `4` *)
  run
    (each_cursor
   ^ {|
fn main() uses Console =
  var c = Each { xs: [1, 2, 3, 4], i: 0 }
  for x in &c
    print(x)
    if x == 2 then break
  for x in &c
    print(x)
|}
    );
  (* until s6: today's output *)
  [%expect
    {|
    error: there's no variable named `break`
       ┌─ test.ren:12:20
    12 │     if x == 2 then break
       │                    ^^^^^
    |}]

let%expect_test "[s6 accept] for over a cursor goes over a copy" =
  (* target: prints `1`, `2`, `3`, then `Each { xs: [1, 2, 3], i: 0 }` *)
  run
    (each_cursor
   ^ {|
fn main() uses Console =
  let c = Each { xs: [1, 2, 3], i: 0 }
  for x in c
    print(x)
  print(c)
|}
    );
  (* until s6: today's output *)
  [%expect
    {|
    error: a `for` loop goes over an `Array`, a `Map` or a `Set`, but this is an `Each`
       ┌─ test.ren:10:12
    10 │   for x in c
       │            ^
    |}]

let%expect_test "[s6 accept] row 37: a block advances a cursor it captures" =
  (* the cursor owns its array, so advancing it touches no other place.
     target: prints `Some(1)` then `Some(2)` *)
  run
    (each_cursor
   ^ {|
fn run(f: fn()) = try f()

fn main() uses Console =
  var c = Each { xs: [1, 2], i: 0 }
  run(fn() => print(&c.next()))
  print(&c.next())
|}
    );
  (* until s6: today's output *)
  [%expect
    {|
    error: a lambda can't change `c`, a variable from outside it
       ┌─ test.ren:12:22
    12 │   run(fn() => print(&c.next()))
       │                      ^
       = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "[s6 accept] a finally before state that fails to start" =
  (* the `finally` covers what comes after it: the state line after it
     fails, so it sees `Err` and runs. target: prints `closed`, then
     `Err(Closed)` *)
  run
    {|
dep N =
  get: fn() -> Int

fn opening(ok: Bool) -> Int ! Closed = if ok then 1 else fail Closed

handler guarded(ok: Bool) for N ! Closed uses Console =
  finally(r) =>
    print("closed")
    try r
  let n = try opening(ok)
  get() => n

fn main() uses Console =
  print(attempt with guarded(false) in N.get())
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: `finally` comes last, after the handler's operations
       ┌─ test.ren:7:3
     7 │   finally(r) =>
       │   ^^^^^^^
    10 │   let n = try opening(ok)
       │   --- this operation comes after it
       help: move `finally` below the handler's last operation
    |}]

let%expect_test "[s6 accept] two finallys run last written first" =
  (* target: prints `second`, `first`, `7` *)
  run
    {|
dep N =
  get: fn() -> Int

handler twice() for N uses Console =
  finally(r) =>
    print("first")
    try r
  finally(r) =>
    print("second")
    try r
  get() => 7

fn main() uses Console =
  print(with twice() in N.get())
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: a handler has one `finally`
      ┌─ test.ren:8:3
    5 │   finally(r) =>
      │   ------- the first is here
    8 │   finally(r) =>
      │   ^^^^^^^
      help: remove one of them
    |}]

let%expect_test "[s6 accept] a finally inside an operation's arm" =
  (* it covers the rest of the arm, which fails: it runs, and the error
     goes on. target: prints `released`, then `Err(Busy)` *)
  run
    {|
dep Pool =
  take: fn() -> Int ! Busy

handler pool() for Pool uses Console =
  take() =>
    finally(r) =>
      print("released")
      try r
    fail Busy

fn main() uses Console =
  with pool() in
    print(attempt Pool.take())
|};
  (* until s6: today's output *)
  [%expect
    {|
    error: expected an expression, found `finally`
      ┌─ test.ren:6:5
    6 │     finally(r) =>
      │     ^^^^^^^
    |}]
