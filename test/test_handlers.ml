(* Handlers that wrap (handlers.md, stage 10a): a `with` is a set, `over`
   and `next`, handler state that can fail to start, and `finally`.

   One test for each rule, and one for each error, in the order
   handlers.md gives them. *)

open Helpers

(* Two dependencies that tests install and wrap: [Users], with two
   operations, so a handler over it can leave one out, and [Log], which
   a handler's needs can be met by. *)
let users =
  {|
dep Users =
  get: fn(id: Int) -> Int
  name: fn(id: Int) -> Str

handler base(n: Int) for Users =
  get(id) => id * n
  name(id) => "base"

handler logged(tag: Str) over Users uses Console =
  get(id) =>
    print(tag)
    next.get(id) + 1
|}

(* ---- a `with` is a set ---- *)

let%expect_test "the order of a with's items doesn't matter" =
  run
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler aa() for A =
  a() => 1

handler bb() for B uses A =
  b() => A.a() + 10

fn main() uses Console =
  with aa(), bb() in
    print(B.b())
  with bb(), aa() in
    print(B.b())
|};
  [%expect {|
    11
    11
    ()
    |}]

let%expect_test "an item's needs are met by the others in its with first" =
  run
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler aa(n: Int) for A =
  a() => n

handler bb() for B uses A =
  b() => A.a() + 10

fn main() uses Console =
  with aa(1) in
    with bb(), aa(2) in
      print(B.b())
    with aa(3), bb() in
      print(B.b())
|};
  [%expect {|
    12
    13
    ()
    |}]

let%expect_test "a with inside another can install a dependency again" =
  run
    {|
dep A =
  a: fn() -> Int

handler aa(n: Int) for A =
  a() => n

fn main() uses Console =
  with aa(1) in
    print(A.a())
    with aa(2) in
      print(A.a())
    print(A.a())
|};
  [%expect {|
    1
    2
    1
    ()
    |}]

let%expect_test "what a with installs is made outside it" =
  (* [stamped] reads the clock when it's called: the one outside, not the
     frozen one beside it *)
  run
    {|
dep Stamp =
  at: fn() -> Bool

handler stamp(early: Bool) for Stamp =
  at() => early

fn stamped() -> Stamp =
  let early = Clock.now() == Time.epoch
  stamp(early)

fn main() uses Console =
  with Clock.frozen(Time.epoch) in
    with Clock.frozen(Time.epoch + Duration.seconds(1)), stamped() in
      print(Stamp.at())
|};
  [%expect {|
    true
    ()
    |}]

let%expect_test "installing a dependency twice is an error" =
  check_error
    {|
dep A =
  a: fn() -> Int

handler aa(n: Int) for A =
  a() => n

fn main() -> Int =
  with aa(1), aa(2) in
    A.a()
|};
  [%expect
    {|
    error: this `with` installs `A` twice
      ┌─ test.ren:8:15
    8 │   with aa(1), aa(2) in
      │               ^^^^^ and again here
      │        ----- installs `A`
      = a `with` installs each dependency once, so its order never matters
      help: to put one in front of another, use a handler declared `over A`
    |}]

let%expect_test "a handler of several counts as each of them" =
  check_error
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler both() for A, B =
  a() => 1
  b() => 2

handler bb() for B =
  b() => 3

fn main() -> Int =
  with both(), bb() in
    A.a()
|};
  [%expect
    {|
    error: this `with` installs `B` twice
       ┌─ test.ren:15:16
    15 │   with both(), bb() in
       │                ^^^^ and again here
       │        ------ is a `A & B`
       = a `with` installs each dependency once, so its order never matters
       help: to put one in front of another, use a handler declared `over B`
    |}]

let%expect_test "installing twice where one goes over says to chain them" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler mem_users() for Users =
  get(id) => id

handler plus(n: Int) over Users =
  get(id) => next.get(id) + n

fn main() -> Int =
  with mem_users() in
    with plus(1) over Users, plus(2) over Users in
      Users.get(1)
|};
  [%expect
    {|
    error: this `with` installs `Users` twice
       ┌─ test.ren:12:30
    12 │     with plus(1) over Users, plus(2) over Users in
       │                              ^^^^^^^^^^^^^^^^^^ and again here
       │          ------------------ installs `Users`
       = a `with` installs each dependency once, so its order never matters
       help: put one over the other: `plus(1) over plus(2) over Users`
    |}]

let%expect_test "two items that each need the other are an error" =
  check_error
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler aa() for A uses B =
  a() => B.b()

handler bb() for B uses A =
  b() => A.a()

fn main() -> Int =
  with aa(), bb() in
    A.a()
|};
  [%expect
    {|
    error: `aa()` and `bb()` in this `with` each need what the other installs
       ┌─ test.ren:14:8
    14 │   with aa(), bb() in
       │        ^^^^ needs `B`, which `bb()` installs
       │              ---- needs `A`, which `aa()` installs
       = an item's needs are met by the other items in its `with`, installed around it, so two can't each need the other
       help: install one of them in a `with` around this one
    |}]

(* ---- `over` and `next` ---- *)

let%expect_test "a handler over another leaves operations to the one under it" =
  run
    (users
   ^ {|
fn main() uses Console =
  with logged("a") over base(10) in
    print(Users.get(3))
    print(Users.name(3))
|}
    );
  [%expect {|
    a
    31
    base
    ()
    |}]

let%expect_test
    "next reaches the one under it, in a chain that nests as it reads" =
  run
    (users
   ^ {|
fn main() uses Console =
  with logged("outer") over logged("inner") over base(10) in
    print(Users.get(1))
|}
    );
  [%expect {|
    outer
    inner
    12
    ()
    |}]

let%expect_test "over a dependency's name wraps the one installed outside" =
  run
    (users
   ^ {|
fn main() uses Console =
  with base(2) in
    with logged("a") over Users in
      print(Users.get(1))
    print(Users.get(1))
|}
    );
  [%expect {|
    a
    3
    2
    ()
    |}]

let%expect_test "over Clock wraps the clock outside" =
  run
    {|
handler later(by: Duration) over Clock =
  now() => next.now() + by

fn main() uses Console =
  with Clock.frozen(Time.epoch) in
    with later(Duration.seconds(5)) over Clock in
      print(Clock.now() - Time.epoch)
|};
  [%expect {|
    Duration(5000)
    ()
    |}]

let%expect_test "a chain counts once, and an item beside it gets its top" =
  run
    (users
   ^ {|
dep Report =
  show: fn() -> Int

handler report() for Report uses Users =
  show() => Users.get(1)

fn main() uses Console =
  with report(), logged("top") over base(10) in
    print(Report.show())
|}
    );
  [%expect {|
    top
    11
    ()
    |}]

let%expect_test "a chain whose bottom is a handler of several installs each" =
  run
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler both() for A, B =
  a() => 1
  b() => 2

handler more() over A =
  a() => next.a() + 100

fn main() uses Console =
  with more() over both() in
    print(A.a())
    print(B.b())
|};
  [%expect {|
    101
    2
    ()
    |}]

let%expect_test "over several, next(A) names the one it reaches" =
  run
    {|
dep A =
  get: fn() -> Int
  only_a: fn() -> Int

dep B =
  only_b: fn() -> Int

handler ab() for A, B =
  get() => 1
  only_a() => 2
  only_b() => 4

handler both() over A & B =
  only_a() => next(A).get() + 100
  only_b() => next.only_b() + 10

fn main() uses Console =
  with both() over ab() in
    print(A.only_a())
    print(A.get())
    print(B.only_b())
|};
  [%expect {|
    101
    1
    14
    ()
    |}]

let%expect_test "next works in a handler's state" =
  run
    (users
   ^ {|
handler first() over Users =
  let start = next.get(1)
  get(id) => start

fn main() uses Console =
  with first() over base(7) in
    print(Users.get(5))
|}
    );
  [%expect {|
    7
    ()
    |}]

let%expect_test
    "next is the one under the handler, whatever a with in it installs" =
  run
    {|
dep F =
  one: fn() -> Int

handler base(n: Int) for F =
  one() => n

handler w() over F uses Console =
  finally(r) =>
    with base(60) in print(next.one())
    try r
  one() =>
    let g = next.one()
    (with base(50) in next.one() + 1000) + (with base(70) in g)

fn main() uses Console =
  with w() over base(1) in print(F.one())
|};
  [%expect {|
    1002
    1
    ()
    |}]

let%expect_test "a block in an arm can call next" =
  (* the block is written in the arm, so it finds `next` where the arm
     does, and the one under it calls it while `put` runs: it can't keep
     it (foundations.md, decision 1). 7 + 1 *)
  run
    {|
dep Store =
  put: fn(f: fn() -> Int)
  run: fn() -> Int
  size: fn() -> Int

handler base() for Store =
  var kept = 0
  put(f) => kept = f()
  run() => kept
  size() => 7

handler w() over Store =
  put(f) => next.put(fn() => next.size() + f())

fn main() uses Console =
  with w() over base() in
    Store.put(fn() => 1)
    print(Store.run())
|};
  [%expect {|
    8
    ()
    |}]

let%expect_test "what a block needs of next, the operation can give it" =
  run
    {|
dep Store =
  put: fn(f: fn() -> Int)
  run: fn() -> Int
  size: fn() -> Int

handler base() for Store =
  var kept = 0
  put(f) => kept = f()
  run() => kept
  size() => 7

handler w() over Store =
  put(f) =>
    let n = next.size()
    next.put(fn() => n + f())

fn main() uses Console =
  with w() over base() in
    Store.put(fn() => 1)
    print(Store.run())
|};
  [%expect {|
    8
    ()
    |}]

let%expect_test
    "a parameter over a dependency needs it from what it's installed over" =
  run
    {|
dep A =
  f: fn() -> Int

handler base() for A =
  f() => 1

handler w() over A =
  f() => next.f() + 10

fn inst(h: over A, b: A) -> Int =
  with h over b in
    A.f()

fn main() uses Console =
  print(inst(w(), base()))
|};
  [%expect {|
    11
    ()
    |}]

let%expect_test "a handler's type says it goes over" =
  types
    (users
   ^ {|
pub dep Pub =
  get: fn() -> Int

pub handler wrapped(n: Int) over Pub uses Console =
  get() => next.get() + n

fn make() = logged("x")

fn main() = 1
|}
    );
  [%expect
    {|
    dep Users
      get: fn(Int) -> Int
      name: fn(Int) -> Str
    handler base(n: Int) for Users
    handler logged(tag: Str) over Users uses Console
    pub dep Pub
      get: fn() -> Int
    pub handler wrapped(n: Int) over Pub uses Console
    fn make() -> (over Users uses Console)
    fn main() -> Int
    |}]

let%expect_test "an operation left out is a call of the one under it, in Core" =
  core
    {|
dep N =
  get: fn() -> Int
  put: fn(n: Int)

handler h() over N =
  get() => next.get() + 1

fn main() = 1
|};
  [%expect
    {|
    (fn h () ev/1
      (handler (captures) ev/2
        (instance
          (test.N:
            (record
              (get:
                (lambda () (captures ev/2) ev/3 (extend ev/2)
                  (+ (next-call ev/2 test.N.get) 1)))
              (put:
                (lambda ($x/4) (captures ev/2) ev/5 (extend ev/2)
                  (dep-call ev/5 test.N.put $x/4))))))))
    (fn main () ev/1 1)
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "a handler for a dependency implements every operation" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int
  list: fn() -> Int
  delete: fn(id: Int)

handler fake_users() for Users =
  get(id) => id

fn main() = 1
|};
  [%expect
    {|
    error: `fake_users` doesn't implement `list` or `delete`
      ┌─ test.ren:6:9
    6 │ handler fake_users() for Users =
      │         ^^^^^^^^^^
      = a handler implements every operation, unless it goes `over` another implementation, which then does the rest
      help: write them, or declare it `over Users` if another `Users` should handle them
    |}]

let%expect_test "next can only be called through" =
  check_error
    (users
   ^ {|
handler keeps() over Users =
  get(id) =>
    let below = next
    1

fn main() = 1
|}
    );
  [%expect
    {|
    error: `next` can only be called through
       ┌─ test.ren:16:17
    16 │     let below = next
       │                 ^^^^
       = `next` is the implementation under this one while an operation runs, and it can't be kept
       help: call it where it's needed: `next.get(...)`
    |}]

let%expect_test "next's operation can only be called" =
  check_error
    (users
   ^ {|
handler keeps() over Users =
  get(id) =>
    let f = next.get
    1

fn main() = 1
|}
    );
  [%expect
    {|
    error: `next` can only be called through
       ┌─ test.ren:16:13
    16 │     let f = next.get
       │             ^^^^^^^^
       = `next` is the implementation under this one while an operation runs, and it can't be kept
       help: call it where it's needed: `next.get(...)`
    |}]

let%expect_test "next is only in a handler over a dependency" =
  check_error
    (users
   ^ {|
handler plain() for Users =
  get(id) => next.get(id)
  name(id) => "x"

fn f() = next.get(1)

fn main() = 1
|}
    );
  [%expect
    {|
    error: `next` is only in a handler declared `over` a dependency
       ┌─ test.ren:15:14
    15 │   get(id) => next.get(id)
       │              ^^^^
       help: declare it `handler plain(...) over Users`, to reach the `Users` under it

    error: `next` is only in a handler declared `over` a dependency
       ┌─ test.ren:18:10
    18 │ fn f() = next.get(1)
       │          ^^^^
       help: only a handler declared `over` another implementation has a `next`
    |}]

let%expect_test "next's operation has to be one of what it goes over" =
  check_error
    (users
   ^ {|
handler wrong() over Users =
  get(id) => next.fetch(id)

fn main() = 1
|}
    );
  [%expect
    {|
    error: `Users` has no operation `fetch`
       ┌─ test.ren:15:19
    15 │   get(id) => next.fetch(id)
       │                   ^^^^^
       help: its operations: `get`, `name`
    |}]

let%expect_test "next names one when two have the operation" =
  check_error
    {|
dep A =
  get: fn() -> Int
  only_a: fn() -> Int

dep B =
  get: fn() -> Int

dep C =
  get: fn() -> Int

handler both() over A & B =
  only_a() => next.get()

handler other() over A & B =
  only_a() => next(C).get()

fn main() = 1
|};
  [%expect
    {|
    error: `A` and `B` both have `get`, so `next.get` could be either
       ┌─ test.ren:12:20
    12 │   only_a() => next.get()
       │                    ^^^
       help: say which: `next(A).get(...)`

    error: `other` doesn't go over `C`
       ┌─ test.ren:15:20
    15 │   only_a() => next(C).get()
       │                    ^
       help: name one of what it goes over: `next(A)` or `next(B)`
    |}]

let%expect_test "nothing in a handler over a dependency is named next" =
  check_error
    (users
   ^ {|
handler shadow(next: Int) over Users =
  get(id) => id

fn main() = 1
|}
    );
  [%expect
    {|
    error: `next` is the implementation under this handler, so nothing in it can be named `next`
       ┌─ test.ren:14:16
    14 │ handler shadow(next: Int) over Users =
       │                ^^^^
       help: choose another name
    |}]

let%expect_test "a handler over a dependency doesn't list it in uses" =
  check_error
    (users
   ^ {|
handler twice() over Users uses Users =
  get(id) => next.get(id)

fn main() = 1
|}
    );
  [%expect
    {|
    error: `Users` is what it goes over, so it isn't listed in `uses`
       ┌─ test.ren:14:33
    14 │ handler twice() over Users uses Users =
       │                                 ^^^^^
       help: remove `Users` from its `uses`
    |}]

let%expect_test "a handler over a dependency calls the one under it with next" =
  check_error
    (users
   ^ {|
handler loops() over Users =
  get(id) => Users.get(id)

fn main() = 1
|}
    );
  [%expect
    {|
    error: a handler over `Users` can't use `Users`
       ┌─ test.ren:15:14
    14 │ handler loops() over Users =
       │         ----- `loops` implements `Users`
    15 │   get(id) => Users.get(id)
       │              ^^^^^^^^^^^^^ this call uses `Users`
       = a handler's operations run with what's installed outside its `with`, so `Users` here would be the one under it
       help: call the one under it through `next`: `next.get` for `Users.get`
    |}]

let%expect_test "over several, the help names which next to call" =
  check_error
    {|
dep A =
  get: fn() -> Int
  only_a: fn() -> Int

dep B =
  get: fn() -> Int

handler wrap() over A & B =
  only_a() => A.get()

fn main() = 1
|};
  [%expect
    {|
    error: a handler over `A` can't use `A`
      ┌─ test.ren:9:15
    8 │ handler wrap() over A & B =
      │         ---- `wrap` implements `A`
    9 │   only_a() => A.get()
      │               ^^^^^^^ this call uses `A`
      = a handler's operations run with what's installed outside its `with`, so `A` here would be the one under it
      help: call the one under it through `next`: `next(A).get` for `A.get`
    |}]

let%expect_test "a handler is for all its dependencies or over all of them" =
  check_error
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler h() for A over B =
  a() => 1
|};
  [%expect
    {|
    error: a handler for some dependencies can't also be over others
      ┌─ test.ren:7:19
    7 │ handler h() for A over B =
      │                   ^^^^
      = a handler is `for` all its dependencies, or `over` all of them
      help: write `handler h(...) for A`, and another handler `over B`
    |}];
  check_error
    {|
dep A =
  a: fn() -> Int

dep B =
  b: fn() -> Int

handler h() over A, B =
  a() => next.a()
|};
  [%expect
    {|
    error: a handler over several dependencies joins them with `&`, as the type of a handler of several is written
      ┌─ test.ren:7:19
    7 │ handler h() over A, B =
      │                   ^
      help: write `over A & B`
    |}]

let%expect_test "a handler for a dependency can't use it either" =
  check_error
    (users
   ^ {|
handler loops() for Users =
  get(id) => Users.get(id)
  name(id) => "loops"

fn main() = 1
|}
    );
  [%expect
    {|
    error: a handler for `Users` can't use `Users`
       ┌─ test.ren:15:14
    14 │ handler loops() for Users =
       │         ----- `loops` implements `Users`
    15 │   get(id) => Users.get(id)
       │              ^^^^^^^^^^^^^ this call uses `Users`
       = a handler's operations run with what's installed outside its `with`, so `Users` here would be the one under it
       help: declare it `over Users`, and call the one under it through `next`
    |}]

let%expect_test "a handler over a dependency is installed with over" =
  check_error
    (users ^ {|
fn main() -> Int =
  with logged("a") in
    Users.get(1)
|});
  [%expect
    {|
    error: `logged("a")` goes over a `Users`, so it's installed with `over`
       ┌─ test.ren:15:8
    15 │   with logged("a") in
       │        ^^^^^^^^^^^
       help: say what it goes over: `logged("a") over Users` for the one installed outside this `with`, or another implementation of it after `over`
    |}]

let%expect_test "only a handler over a dependency has something under it" =
  check_error
    (users
   ^ {|
fn main() -> Int =
  with base(1) over base(2) in
    Users.get(1)
|});
  [%expect
    {|
    error: `base(1)` doesn't go over a `Users`, so nothing goes under it
       ┌─ test.ren:15:8
    15 │   with base(1) over base(2) in
       │        ^^^^^^^
       │                     ------- is under it
       = only a handler declared `over` a dependency goes over another implementation of it
       help: install one of them, or declare `base` `over Users`
    |}]

let%expect_test "what's under a handler implements what it goes over" =
  check_error
    (users
   ^ {|
fn main() -> Int uses Console =
  with logged("a") over Clock.frozen(Time.epoch) in
    Users.get(1)
|}
    );
  [%expect
    {|
    error: `logged("a")` goes over a `Users`, and `Clock.frozen(Time.epoch)` isn't one
       ┌─ test.ren:15:25
    15 │   with logged("a") over Clock.frozen(Time.epoch) in
       │                         ^^^^^^^^^^^^^^^^^^^^^^^^
       help: put a `Users` under it
    |}]

(* ---- state that can fail to start ---- *)

let sql =
  {|
pub dep Sql =
  begin: fn() -> Int ! DbDown
  commit: fn(tx: Int) ! DbDown
  rollback: fn(tx: Int)
  get: fn() -> Int
  set: fn(n: Int)

pub handler mem(down: Bool) for Sql uses Console =
  var value = 0
  var kept = 0
  begin() =>
    if down then fail DbDown
    kept = value
    1
  commit(tx) =>
    print("commit")
    if value > 100 then fail DbDown
  rollback(tx) =>
    print("rollback")
    value = kept
  get() => value
  set(n) => value = n

pub handler transaction() over Sql ! DbDown =
  let tx = try next.begin()
  finally(r) =>
    match r
      Ok(v) =>
        try next.commit(tx)
        v
      Err(_) =>
        next.rollback(tx)
        try r
|}

let%expect_test "a with fails with what its handler's state does" =
  run
    (sql
   ^ {|
fn work() -> Int ! DbDown uses Sql, Console =
  try with transaction() over Sql in
    print("body")
    1

fn main() uses Console =
  with mem(true) in
    print(attempt work())
|}
    );
  [%expect {|
    Err(DbDown)
    ()
    |}]

let%expect_test "a pub handler says what it can fail to start with" =
  check_error
    {|
pub dep N =
  get: fn() -> Int

fn bad() -> Int ! Oops = fail Oops

pub handler h() for N =
  var n = try bad()
  get() => n

fn main() = 1
|};
  [%expect
    {|
    error: `pub handler h` doesn't say it can fail with `Oops`
      ┌─ test.ren:7:15
    7 │   var n = try bad()
      │               ^^^^^
      = a `with` that installs it fails with what its state and `finally` fail with
      help: add `! Oops` after `for N`
    |}]

let%expect_test "an implementation that can fail to start is written so" =
  types
    (sql
   ^ {|
fn install(s: over Sql ! DbDown) -> Int ! DbDown uses Sql =
  try with s over Sql in Sql.get()

fn main() uses Console =
  with mem(false) in
    print(attempt install(transaction()))
|}
    );
  [%expect
    {|
    pub dep Sql
      begin: fn() -> Int ! DbDown
      commit: fn(Int) ! DbDown
      rollback: fn(Int)
      get: fn() -> Int
      set: fn(Int)
    pub handler mem(down: Bool) for Sql uses Console
    pub handler transaction() over Sql ! DbDown
    fn install(s: over Sql ! DbDown) -> Int ! DbDown uses Sql
    fn main() uses Console
    |}]

let%expect_test
    "two implementations that differ in failing to start, either way" =
  check_error
    {|
dep L =
  l: fn() -> Int

handler bad() for L ! Boom =
  let x: Int = fail Boom
  l() => x

handler good() for L =
  l() => 1

fn main() uses Console =
  let hs = [bad(), good()]
  let gs = [good(), bad()]
  print(1)
|};
  [%expect
    {|
    error: this element is a `L`, but the elements before it are a `L ! Boom`
       ┌─ test.ren:12:20
    12 │   let hs = [bad(), good()]
       │                    ^^^^^^
       = an implementation's type says what it can fail to start with, so one that can fail can't stand in for one that can't
       help: say it can fail where its type is written: `(L ! Boom)`

    error: this element is a `L ! Boom`, but the elements before it are a `L`
       ┌─ test.ren:13:21
    13 │   let gs = [good(), bad()]
       │                     ^^^^^
       = an implementation's type says what it can fail to start with, so one that can fail can't stand in for one that can't
       help: say it can fail where its type is written: `(L ! Boom)`
    |}]

let%expect_test "one that can fail to start doesn't fit a type that can't" =
  check_error
    (sql
   ^ {|
fn install(s: over Sql) -> Int uses Sql =
  with s over Sql in Sql.get()

fn main() uses Console =
  with mem(false) in
    print(install(transaction()))
|}
    );
  [%expect
    {|
    error: expected `over Sql`, found `over Sql ! DbDown`
       ┌─ test.ren:40:19
    40 │     print(install(transaction()))
       │                   ^^^^^^^^^^^^^
       = an implementation's type says what it can fail to start with, so one that can fail can't stand in for one that can't
       help: say it can fail where its type is written: `(over Sql ! DbDown)`
    |}]

(* ---- `finally` ---- *)

let%expect_test "finally commits, or rolls back and passes the error on" =
  run
    (sql
   ^ {|
fn move(n: Int) -> Int ! DbDown | Short uses Sql =
  try with transaction() over Sql in
    Sql.set(n)
    if n < 0 then fail Short
    n

fn main() uses Console =
  with mem(false) in
    print(attempt move(5))
    print(Sql.get())
    print(attempt move(-1))
    print(Sql.get())
    print(attempt move(500))
    print(Sql.get())
|}
    );
  [%expect
    {|
    commit
    Ok(5)
    5
    rollback
    Err(Short)
    5
    commit
    Err(DbDown)
    500
    ()
    |}]

let%expect_test "finally runs once, and not when the handler didn't start" =
  run
    (sql
   ^ {|
fn move(n: Int) -> Int ! DbDown uses Sql, Console =
  try with transaction() over Sql in
    print("body")
    n

fn main() uses Console =
  with mem(false) in
    print(attempt move(1))
  with mem(true) in
    print(attempt move(1))
|}
    );
  [%expect {|
    body
    commit
    Ok(1)
    Err(DbDown)
    ()
    |}]

let%expect_test "finally doesn't run after a panic" =
  run_error
    {|
dep N =
  get: fn() -> Int

handler base() for N =
  get() => 0

handler noted() over N uses Console =
  finally(r) =>
    print("finally")
    try r

fn main() uses Console =
  with noted() over base() in
    print("body")
    assert 1 == 2
|};
  [%expect
    {|
    body
    error: panic: this `assert` failed
       ┌─ test.ren:15:12
    15 │     assert 1 == 2
       │            ^^^^^^
       = left:  1
       = right: 2
    |}]

let%expect_test "in a chain, the top's finally runs first" =
  run
    {|
dep N =
  get: fn() -> Int

handler base() for N =
  get() => 0

handler noted(tag: Str) over N uses Console =
  finally(r) =>
    print(tag)
    try r

fn main() uses Console =
  print(with noted("top") over noted("bottom") over base() in N.get())
|};
  [%expect {|
    top
    bottom
    0
    ()
    |}]

let%expect_test "finally can show the body's value, through its type" =
  run
    {|
dep N =
  get: fn() -> Int

handler base() for N =
  get() => 0

handler shown() over N uses Console =
  finally(r) =>
    match r
      Ok(v) =>
        print(v)
        v
      Err(_) => try r

fn main() uses Console =
  print(with shown() over base() in "a")
  print(with shown() over base() in (1, true))
|};
  [%expect {|
    a
    a
    (1, true)
    (1, true)
    ()
    |}]

let%expect_test "a with fails with its body's errors and finally's" =
  types
    {|
dep N =
  get: fn() -> Int

handler base() for N =
  get() => 0

handler checked() over N =
  finally(r) =>
    if next.get() > 0 then fail Late
    try r

fn f() uses N =
  try with checked() over N in
    if N.get() < 0 then fail Early
    1

fn main() = 1
|};
  [%expect
    {|
    dep N
      get: fn() -> Int
    handler base() for N
    handler checked() over N ! Late
    fn f() -> Int ! Early | Late uses N
    fn main() -> Int
    |}]

let%expect_test "finally can't compare the body's value" =
  check_error
    {|
dep N =
  get: fn() -> Int

handler cmp() over N =
  finally(r) =>
    match r
      Ok(v) =>
        if v == v then v else v
      Err(_) => try r

fn main() = 1
|};
  [%expect
    {|
    error: `finally` can't compare the body's value
      ┌─ test.ren:8:12
    8 │         if v == v then v else v
      │            ^^^^^^
      = the body's value can be any type, and `finally` has to work for each
      help: give it back as it is, or show it with `print`
    |}]

let%expect_test "finally gives back the body's value" =
  check_error
    {|
dep N =
  get: fn() -> Int

handler wrong() over N =
  finally(r) => 1

fn main() = 1
|};
  [%expect
    {|
    error: `finally` produces an `Int`, but it has to give back the body's value
      ┌─ test.ren:5:17
    5 │   finally(r) => 1
      │                 ^
      = it's given the body's result, `r`, and what it produces is the `with`'s
      help: give back `v` from `Ok(v)`, or fail: `try r`
    |}]

let%expect_test "finally that doesn't give back the body's value" =
  check_error
    {|
dep L =
  l: fn() -> Int

handler h() for L =
  finally(_) => 3
  l() => 1

fn main() = 1
|};
  [%expect
    {|
    error: `finally` produces an `Int`, but it has to give back the body's value
      ┌─ test.ren:5:17
    5 │   finally(_) => 3
      │                 ^
      = it's given the body's result, and what it produces is the `with`'s
      help: name the result, `finally(r) =>`, and give back `v` from `Ok(v)`, or fail: `try r`
    |}]

let%expect_test "finally takes one parameter" =
  check_error
    {|
dep N =
  get: fn() -> Int

handler wrong() over N =
  finally(a, b) => 1

fn main() = 1
|};
  [%expect
    {|
    error: `finally` takes one parameter, the result of what it covers, but this has 2
      ┌─ test.ren:5:3
    5 │   finally(a, b) => 1
      │   ^^^^^^^^^^^^^^^^^^
      help: `finally(r) => ...`
    |}]

let%expect_test "a handler's finally is among its state" =
  (* where it's written says what it covers, so after the operations it
     would cover nothing of the handler's *)
  check_error
    {|
dep N =
  get: fn() -> Int

handler wrong() over N =
  get() => 1
  finally(r) => try r

fn main() = 1
|};
  [%expect
    {|
    error: a handler's `finally` is among its state, before its operations
      ┌─ test.ren:6:3
    6 │   finally(r) => try r
      │   ^^^^^^^
      = a `finally` covers what comes after it: the state below it, and the body of each `with` that installs the handler
      help: move it above the handler's first operation
    |}];
  (* and anywhere but a handler or an arm, it's an error *)
  check_error {|
fn main() =
  finally(r) => try r
  1
|};
  [%expect
    {|
    error: a `finally` is only in a handler: among its state, or in an operation's arm
      ┌─ test.ren:2:3
    2 │   finally(r) => try r
      │   ^^^^^^^
      = it covers what comes after it there: the state below it and the body of each `with` that installs the handler, or the rest of the arm
      help: use `attempt` on what it should cover, and act on the `Result` after
    |}];
  (* last in an arm, it covers nothing *)
  check_error
    {|
dep N =
  get: fn() -> Int

handler h() for N =
  get() =>
    let n = 1
    finally(r) => try r

fn main() = 1
|};
  [%expect
    {|
    error: a `finally` covers what comes after it, and nothing does
      ┌─ test.ren:7:5
    7 │     finally(r) => try r
      │     ^^^^^^^
      help: move it above the lines it should cover
    |}]

let%expect_test "finally in Core" =
  core
    {|
dep N =
  get: fn() -> Int

handler h() over N =
  var n = 0
  finally(r) =>
    n += 1
    try r

fn main() = 1
|};
  [%expect
    {|
    (fn h () ev/1
      (handler (captures) ev/2
        (let n/3 0
          (let $n/4 (cell n/3)
            (instance
              (test.N:
                (record
                  (get:
                    (lambda () (captures ev/2) ev/5 (extend ev/2)
                      (dep-call ev/5 test.N.get)))))
              (finally
                (lambda ($ty/6 $outcome/7) (captures ev/2 $n/4) ev/8 (extend ev/2)
                  (let n/3 (get-cell $n/4)
                    (finally
                      (let r/9 $outcome/7
                        (seq (= n/3 (+ n/3 1))
                          (match r/9 ((Ok $value/10) => $value/10)
                            ((Err $error/11) => (fail $error/11)))))
                      (set-cell $n/4 n/3))))))))))
    (fn main () ev/1 1)
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "finally giving back the body's result names no type parameter"
    =
  check_error
    {|
dep Log =
  note: fn(s: Str)

handler a() for Log =
  finally(r) => r
  note(s) => ()

fn main() = 1
|};
  [%expect
    {|
    error: `finally` gives back the body's result, `r`, but it has to give back its value
      ┌─ test.ren:5:17
    5 │   finally(r) => r
      │                 ^
      = it's given the body's result, `r`, and what it produces is the `with`'s
      help: give back `v` from `Ok(v)`, or fail: `try r`
    |}]

let%expect_test "finally can't match the body's errors" =
  check_error
    {|
dep Log =
  note: fn(s: Str)

handler b() for Log =
  finally(res) =>
    match res
      Ok(v) => v
      Err(Bad) => try res
      Err(_) => try res
  note(s) => ()

fn main() = 1
|};
  [%expect
    {|
    error: `Bad` can't be matched here, because the body's errors aren't known
      ┌─ test.ren:8:11
    8 │       Err(Bad) => try res
      │           ^^^
      = `finally` is given the body's error to pass on, not to look at: it could be whatever the body fails with
      help: match it with `Err(_)`, and pass it on with `try res`
    |}];
  check_error
    {|
dep Log =
  note: fn(s: Str)

handler b() for Log =
  finally(res) =>
    match res
      Ok(v) => v
      Err(e) => try res
  note(s) => ()

fn main() = 1
|};
  [%expect
    {|
    error: `e` would hold the body's error, which isn't a value
      ┌─ test.ren:8:11
    8 │       Err(e) => try res
      │           ^
      = `finally` is given the body's error to pass on, not to look at: it could be whatever the body fails with
      help: match it with `Err(_)`, and pass it on with `try res`
    |}]

let%expect_test "a with whose handler can fail to start isn't a call" =
  check_error
    {|
pub dep Db =
  open: fn() -> Int ! Down
  get: fn(t: Int) -> Int

handler session() over Db =
  let t = try next.open()
  get(x) => next.get(t) + x

pub fn use_it() -> Int uses Db =
  try with session() over Db in
    Db.get(1)

fn main() = 1
|};
  [%expect
    {|
    error: `pub fn use_it` can fail with `Down`, but its signature doesn't say so
       ┌─ test.ren:9:8
     9 │ pub fn use_it() -> Int uses Db =
       │        ^^^^^^
    10 │   try with session() over Db in
       │            --------- installing this can fail with `Down`
       = a public function without `!` can't fail, and its body is checked against that
       help: add `! Down` to its signature, or handle it with a `match` around the `with`, `match with ... in ...`, and an arm `fail Down => ...`
    |}]

let%expect_test "forwards and outer are over and next" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler plus(k: Int) for Users forwards =
  get(id) => id + k

fn main() = 1
|};
  [%expect
    {|
    error: a handler that passes on what it doesn't implement goes `over` it, not `forwards`
      ┌─ test.ren:4:32
    4 │ handler plus(k: Int) for Users forwards =
      │                                ^^^^^^^^
      help: declare it `handler plus(...) over Users`: the operations it leaves out go to the one under it, which it calls with `next`
    |}];
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler plus(k: Int) for Users =
  get(id) => outer.get(id) + k

fn main() = 1
|};
  [%expect
    {|
    error: there's no variable named `outer`
      ┌─ test.ren:5:14
    5 │   get(id) => outer.get(id) + k
      │              ^^^^^
      help: declare it `handler plus(...) over Users`, and call the one under it with `next`: `next.get(...)`
    |}]

let%expect_test
    "an implementation that goes over can't stand in for one that doesn't" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler base() for Users =
  get(id) => id

handler w() over Users =
  get(id) => next.get(id) * 2

fn inst(h: Users) uses Console =
  with h in print(Users.get(3))

fn main() uses Console = inst(w())
|};
  [%expect
    {|
    error: expected `Users uses Console`, found `over Users`
       ┌─ test.ren:13:31
    13 │ fn main() uses Console = inst(w())
       │                               ^^^
       = an `over Users` goes over another `Users`, which it calls with `next`, so it can't stand in for one that doesn't
       help: write `over Users` where its type is written, and install it with `over`
    |}];
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler base() for Users =
  get(id) => id

fn inst(h: over Users) uses Console, Users =
  with h over Users in print(Users.get(3))

fn main() uses Console =
  with base() in inst(base())
|};
  [%expect
    {|
    error: expected `over Users uses Console`, found `Users`
       ┌─ test.ren:11:23
    11 │   with base() in inst(base())
       │                       ^^^^^^
       = a `Users` implements every operation itself, so it can't stand in for an `over Users`, which goes over another
       help: write `Users` where its type is written, or pass a handler declared `over Users`
    |}]

(* the parameter's type is where it says it goes over another *)
let%expect_test "a parameter installed over is told to say so in its type" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

fn run(w: Users) -> Int uses Users =
  with w over Users in
    Users.get(1)

fn main() = ()
|};
  [%expect
    {|
    error: `w` doesn't go over a `Users`, so nothing goes under it
      ┌─ test.ren:5:8
    5 │   with w over Users in
      │        ^
      │               ----- is under it
      = only a handler declared `over` a dependency goes over another implementation of it
      help: say in its type that it goes over one: `w: over Users`
    |}]

let%expect_test "a handler over two installed over one" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int
dep Logs =
  log: fn(s: Str)

handler both() over Users & Logs =
  get(id) => next.get(id) + 1

fn run() -> Int uses Users, Logs =
  with both() over Users in
    Users.get(1)

fn main() = ()
|};
  [%expect
    {|
    error: `both()` goes over `Logs` and `Users`, so it's installed over both
       ┌─ test.ren:10:20
    10 │   with both() over Users in
       │                    ^^^^^ names only `Users`
       help: write `both() over Logs & Users`
    |}]

(* ---- an arm that names its dependency (stage 10b) ---- *)

let%expect_test "an arm can say which dependency's operation it is" =
  run
    {|
dep A =
  x: fn() -> Int

dep B =
  x: fn() -> Int

handler both() for A, B =
  A.x() => 1
  B.x() => 2

fn main() -> Int =
  with both() in
    A.x() * 10 + B.x()
|};
  [%expect {| 12 |}]

let%expect_test "an arm can't name a dependency its handler doesn't implement" =
  check_error
    {|
dep A =
  x: fn() -> Int

dep B =
  x: fn() -> Int

handler just_a() for A =
  B.x() => 1

fn main() = ()
|};
  [%expect
    {|
    error: `just_a` doesn't implement `x`
      ┌─ test.ren:7:9
    7 │ handler just_a() for A =
      │         ^^^^^^
      = a handler implements every operation, unless it goes `over` another implementation, which then does the rest
      help: write them, or declare it `over A` if another `A` should handle them

    error: this handler doesn't implement `B`
      ┌─ test.ren:8:3
    8 │   B.x() => 1
      │   ^
      help: it implements `A`
    |}]

let%expect_test "an arm that names its dependency, parsed" =
  ast {|
handler h() for A, B =
  A.x(n) => n
  y() => 0
|};
  [%expect
    {| (fn h () (handler (for A B) (A.x (lambda (n) n)) (y (lambda () 0)))) |}]
