(* Stage 12a's field defaults: declaration scope, generic values, omissions,
   and the order of explicit fields. Helpers also checks release evaluation. *)
open Helpers

let%expect_test "record defaults are full pure expressions" =
  run
    {|type Source = Web | Disk
type Audit = { count: Int }
  let none: Audit = Audit { count: 0 }
type Cfg = { port: Int = base() + 80, source: Source = Web,
              audit: Audit = Audit.none, name: Str }
fn base() -> Int = 8000
fn main() uses Console =
  let cfg: Cfg = { name: "local" }
  print(cfg)
  print(Cfg { port: 42, name: "custom" })
  let copy = { ..cfg, name: "remote" }
  let { port, .. } = copy
  print(port)
|};
  [%expect {|
    Cfg { port: 8080, source: Web, audit: Audit { count: 0 }, name: "local" }
    Cfg { port: 42, source: Web, audit: Audit { count: 0 }, name: "custom" }
    8080
    ()
    |}]

let%expect_test "by-name constructors fill omitted defaults" =
  run
    {|type Mode = Empty | Ready { code: Int = 40 + 2, name: Str = "ready" }
fn main() uses Console =
  print(Ready {})
  print(Ready { name: "explicit" })
  match Ready {}
    Ready { code, .. } => print(code)
    Empty => print(0)
|};
  [%expect {|
    Ready { code: 42, name: "ready" }
    Ready { code: 42, name: "explicit" }
    42
    ()
    |}]

let%expect_test "explicit fields run once in source order" =
  run
    {|type Row = { a: Int = 1, b: Int, c: Int }
fn said(n: Int) -> Int uses Console =
  print(n)
  n
fn main() uses Console =
  print(Row { c: said(3), b: said(2) })
|};
  [%expect {|
    3
    2
    Row { a: 1, b: 2, c: 3 }
    ()
    |}]

let%expect_test "generic defaults keep canonical arguments" =
  run
    {|type Pair<T, U> = { first: T, second: Option<U> = None,
                       spare: Option<T> = None }
fn main() uses Console =
  let p: Pair<Int, Str> = { first: 7 }
  let q: Pair<Str, Int> = { first: "seven", second: Some(3) }
  print(p)
  print(q)
|};
  [%expect {|
    Pair { first: 7, second: None, spare: None }
    Pair { first: "seven", second: Some(3), spare: None }
    ()
    |}]

let%expect_test "imported defaults retain declaration scope" =
  run_files
    [ ("main.ren", {|import config.{Config}
fn seed() -> Int = 99
fn main() = Config { name: "import" }
|});
      ("config.ren", {|pub type Config = { value: Int = seed(), name: Str }
fn seed() -> Int = 42
|}) ];
  [%expect {| { name: "import", value: 42 } |}]

let%expect_test "generic defaults cross an interface" =
  run_files
    [ ("main.ren", {|import box.{Box}
fn main() uses Console =
  let one: Box<Int, Str> = { item: 1 }
  let two: Box<Str, Int> = { item: "two", flag: Some(2) }
  print(one)
  print(two)
|});
      ("box.ren", {|pub type Box<A, B> = { item: A, flag: Option<B> = None }
|}) ];
  [%expect {|
    Box { item: 1, flag: None }
    Box { item: "two", flag: Some(2) }
    ()
    |}]

let%expect_test "defaults do not make fields optional in patterns" =
  run
    {|type Cfg = { count: Int = 3, name: Str = "ok" }
fn main() =
  let Cfg { count, .. } = Cfg {}
  count
|};
  [%expect {| 3 |}]

let%expect_test "a missing field still needs a default" =
  run
    {|type Cfg = { count: Int = 3, name: Str }
fn main() = Cfg {}
|};
  [%expect {|
    error: this `Cfg` is missing `name`
      ┌─ test.ren:2:13
    2 │ fn main() = Cfg {}
      │             ^^^^^^
      help: give it a value too, like `name: ...`
    |}]

let%expect_test "a field default is pure and data" =
  run
    {|type Cfg = { count: Int = noisy() }
fn noisy() -> Int uses Console =
  print("no")
  1
fn main() = Cfg {}
|};
  [%expect {|
    error: the default for `count` must be pure, but uses `Console`
      ┌─ test.ren:1:14
    1 │ type Cfg = { count: Int = noisy() }
      │              ^^^^^
      │                           ------- this call uses `Console`
      = a field default holds pure data, known while building
      help: use pure data, or require `count` at construction
    |}]

let%expect_test "a field default cannot hold a block" =
  run
    {|type Cfg = { callback: fn() -> Int = fn() => 1 }
fn main() = Cfg {}
|};
  [%expect {|
    error: a record can't hold a block
      ┌─ test.ren:1:24
    1 │ type Cfg = { callback: fn() -> Int = fn() => 1 }
      │                        ^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: hold data instead, an enum to `match` on, or a handler's description, and pass the block to the call that runs it

    error: a field default can't hold a block
      ┌─ test.ren:1:24
    1 │ type Cfg = { callback: fn() -> Int = fn() => 1 }
      │                        ^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: hold pure data in the field, and pass the block to the call that runs it
    |}]

let%expect_test "field default dependencies are ordered" =
  run
    {|type Outer = { inner: Inner = Inner {} }
type Inner = { value: Int = 42 }
fn main() = Outer {}
|};
  [%expect {| { inner: { value: 42 } } |}]

let%expect_test "a cycle through defaults is refused" =
  run
    {|type Loop = { items: Array<Loop> = [Loop {}] }
fn main() = Loop {}
|};
  [%expect {|
    error: `Loop.$default:items` is made from itself: Loop.$default:items → Loop.$default:items
      ┌─ test.ren:1:15
    1 │ type Loop = { items: Array<Loop> = [Loop {}] }
      │               ^^^^^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make it without using itself
    |}]

let%expect_test "a generic field default is transitively pure" =
  run
    {|type Cfg<T> = { item: T, count: Int = noisy() }
fn noisy() -> Int = indirectly()
fn indirectly() -> Int uses Console =
  print("no")
  1
fn main() = Cfg { item: 2 }
|};
  [%expect {|
    error: the default for `count` must be pure, but uses `Console`
      ┌─ test.ren:1:26
    1 │ type Cfg<T> = { item: T, count: Int = noisy() }
      │                          ^^^^^
      │                                       ------- this call uses `Console`
      = a field default holds pure data, known while building
      help: use pure data, or require `count` at construction
    |}]

let%expect_test "a generic field default cannot fail" =
  run
    {|type Cfg<T> = { item: T, count: Int = try missing() }
fn missing() -> Int ! Missing = fail Missing
fn main() = Cfg { item: 2 }
|};
  [%expect {|
    error: the default for `count` can fail with `Missing`
      ┌─ test.ren:1:26
    1 │ type Cfg<T> = { item: T, count: Int = try missing() }
      │                          ^^^^^
      │                                           --------- this call can fail with `Missing`
      = a field default holds pure data, known while building
      help: handle the error here with `match`, or require the field at construction
    |}]

let%expect_test "a generic field default cannot return a block" =
  run
    {|type Cfg<T> = { item: T, callback: fn() -> Int = fn() => 1 }
fn main() = Cfg { item: 2 }
|};
  [%expect {|
    error: a record can't hold a block
      ┌─ test.ren:1:36
    1 │ type Cfg<T> = { item: T, callback: fn() -> Int = fn() => 1 }
      │                                    ^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: hold data instead, an enum to `match` on, or a handler's description, and pass the block to the call that runs it

    error: a field default can't hold a block
      ┌─ test.ren:1:36
    1 │ type Cfg<T> = { item: T, callback: fn() -> Int = fn() => 1 }
      │                                    ^^^^^^^^^^^ a block's type
      = a block lives only as long as the call it's passed to
      help: hold pure data in the field, and pass the block to the call that runs it
    |}]

let%expect_test "a recursive generic default is data" =
  run
    {|type Node<T> = { value: T, next: Option<Node<T>> = None }
fn main() = Node { value: 3 }
|};
  [%expect {| { next: None, value: 3 } |}]
