(* Descriptions (foundations.md, decisions 3 to 7, 15 and 17): this file
   is stage 10d's specification, as test_blocks.ml was 10c's.

   Each test's name starts with a tag, `[sN accept]` or `[sN reject]`. N is
   the step of the 10d plan that lands it (compiler.md, "Stage 10d"):

     s1  shifts and literals
     s2  generic dependencies
     s3  descriptions as the only stored code
     s4  dispatch lowered as decision 4 says (bench/build.t tests it)
     s5  `over any` and `retry(n, on: Tags)`
     s6  blocks with `inout` parameters, and slices

   A test still to land runs through [until] (helpers.ml), which holds
   what the step makes of it: [want], the whole output of a program that
   runs, or [says], the lines an error or a panic has to hold. Its
   [%expect] holds today's output after `(until sN)`. When the program
   prints what's wanted, the test fails until it's turned on: written
   plainly, [run src], with the target in its [%expect]. A test without
   [until] shows its target already.

   The friction research/paper-programs.md found that 10d answers is
   here too, each named by its label there: F2, a description that needs
   less where one that needs more is expected; M3, blocks with `inout`
   parameters; M4, shifts and hex literals; M6, slices; and the router of
   server/api.ren, called as methods. *)

open Helpers

(* ---- s1: shifts and literals (decision 15) ---- *)

let%expect_test "[s1 accept] hex, binary and underscored literals" =
  run
    {|
fn main() uses Console =
  print(0xFF)
  print(0x82F6_3B78)
  print(0b1010)
  print(0b1111_0000)
  print(1_000_000)
  print(0xff == 255)
  print(-0x10)
  print(0x7FFF_FFFF_FFFF_FFFF)
  print(-0x8000_0000_0000_0000)
|};
  [%expect {|
    255
    2197175160
    10
    240
    1000000
    true
    -16
    9223372036854775807
    -9223372036854775808
    ()
    |}]

let%expect_test "[s1 accept] shl and shr lose the bits shifted out" =
  (* `shl` wraps at 64 bits, as `*%` does; `shr` is arithmetic on an
     `Int`, so it keeps a negative number's sign *)
  run
    {|
fn main() uses Console =
  print(1.shl(4))
  print(5.shl(0))
  print(0xFF.shr(4))
  print((-8).shr(1))
  print((-1).shr(63))
  print(1.shl(62))
  print(3.shl(62))
  print(1.shl(63))
  print(8.shl(61))
  var k = 0
  var total = 0
  while k < 64
    total = total +% 1.shl(k).shr(k)
    k += 1
  print(total)
|};
  [%expect {|
    16
    5
    15
    -4
    -1
    4611686018427387904
    -4611686018427387904
    -9223372036854775808
    0
    62
    ()
    |}]

let%expect_test "[s1 accept] shl stored into a sized integer wraps at its width" =
  (* the rule `*%` follows: at the top of what's stored into a sized
     integer, it keeps that many bits, and elsewhere 64; and a value read
     from an unsigned type is never negative, so `shr` on it is logical *)
  run
    {|
fn main() uses Console =
  var w: UInt32 = 0x8000_0001
  w = w.shl(1)
  print(w)
  var b: UInt8 = 0b1100_0001
  b = b.shl(2)
  print(b)
  var i: Int32 = 1
  i = i.shl(31)
  print(i)
  let x = w.shl(40)
  print(x)
  var u: UInt32 = 0xFFFF_FFFF
  print(u.shr(28))
|};
  [%expect {|
    2
    4
    -2147483648
    2199023255552
    15
    ()
    |}]

let%expect_test "[s1 accept] a CRC-32C with shifts and hex (M4)" =
  (* kv/crc.ren of the paper programs, which divided by 256 for `shr(8)`;
     the check value from the CRC catalogue *)
  run
    {|
fn table() -> Array<UInt32> =
  var t: Array<UInt32> = []
  for n in 0..256
    var c = n
    for _ in 0..8
      c = if c.bit_and(1) == 1 then c.shr(1).xor(0x82F6_3B78) else c.shr(1)
    &t.push(c)
  t

fn crc32c(data: Array<Int>) -> Int =
  let t = table()
  var c: UInt32 = 0xFFFF_FFFF
  for x in data
    c = t[c.xor(x).bit_and(0xFF)].xor(c.shr(8))
  c.xor(0xFFFF_FFFF)

fn main() uses Console =
  let digits = [0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]
  print(crc32c(digits) == 0xE306_9283)
  print(crc32c(digits))
|};
  [%expect {|
    true
    3808858755
    ()
    |}]

let%expect_test "[s1 reject] a shift by an amount outside 0 to 63 panics" =
  run
    {|
fn main() uses Console =
  let k = 64
  print(1.shl(k))
|};
  [%expect {|
    error: panic: `shl` by 64: a shift is by 0 to 63
      ┌─ test.ren:3:9
    3 │   print(1.shl(k))
      │         ^^^^^^^^
    |}];
  run
    {|
fn main() uses Console =
  let k = -1
  print(16.shr(k))
|};
  [%expect {|
    error: panic: `shr` by -1: a shift is by 0 to 63
      ┌─ test.ren:3:9
    3 │   print(16.shr(k))
      │         ^^^^^^^^^
    |}]

let%expect_test "[s1 reject] a literal shift amount outside 0 to 63" =
  (* an error where it's written, as a literal that doesn't fit is *)
  run {|
fn main() uses Console =
  print(1.shl(64))
|};
  [%expect {|
    error: `shl` by 64 always panics
      ┌─ test.ren:2:15
    2 │   print(1.shl(64))
      │               ^^
      help: a shift is by 0 to 63; to make 0, write `0`
    |}]

let%expect_test "[s1 reject] shl's result stored into a UInt64" =
  (* as a wrapping operator's: `shl` wraps at 64 bits, and half of what
     it makes is negative *)
  run {|
fn main() =
  var h: UInt64 = 1
  h = h.shl(3)
|};
  [%expect {|
    error: a `shl`'s result can't be stored in a `UInt64`
      ┌─ test.ren:3:7
    3 │   h = h.shl(3)
      │       ^^^^^^^^
      = `shl` wraps at `Int`'s 64 bits, and half of what it makes is negative
      = a `UInt64` holds what an `Int` can that isn't negative
      help: keep a 64-bit hash or checksum in an `Int`
    |}]

let%expect_test "[s1 reject] literals that aren't numbers" =
  run {|
fn main() uses Console =
  print(0x)
|};
  [%expect {|
    error: a hex number needs a digit after `0x`
      ┌─ test.ren:2:9
    2 │   print(0x)
      │         ^^
      help: write its digits, `0xFF`
    |}];
  run {|
fn main() uses Console =
  print(0b102)
|};
  [%expect {|
    error: `2` isn't a binary digit
      ┌─ test.ren:2:13
    2 │   print(0b102)
      │             ^
      help: a binary number is written with `0` and `1`, `0b1010`
    |}];
  run {|
fn main() uses Console =
  print(0XFF)
|};
  [%expect {|
    error: a hex number starts with `0x`, in lower case
      ┌─ test.ren:2:9
    2 │   print(0XFF)
      │         ^^
      help: write `0xFF`
    |}]

let%expect_test "[s1 reject] a hex literal past the largest Int" =
  (* a literal is a number, whatever its base, not a pattern of bits *)
  run {|
fn main() uses Console =
  print(0xFFFF_FFFF_FFFF_FFFF)
|};
  [%expect {|
    error: this number is too big to fit in an `Int`
      ┌─ test.ren:2:9
    2 │   print(0xFFFF_FFFF_FFFF_FFFF)
      │         ^^^^^^^^^^^^^^^^^^^^^
      help: the largest `Int` is `0x7FFF_FFFF_FFFF_FFFF`; for all 64 bits set, write `-1`
    |}]

(* ---- s2: generic dependencies (decisions 5 and 6) ---- *)

let log_dep =
  {|
dep Log<T> =
  add: fn(x: T)
  all: fn() -> Array<T>

handler log<T>() for Log<T> =
  var xs: Array<T> = []
  add(x) => &xs.push(x)
  all() => xs
|}

let%expect_test "[s2 accept] one generic handler, installed at two types" =
  (* `Log<Int>` and `Log<Str>` are two dependencies: a call is found by
     its full type, from what it's given or what its result is used as *)
  run
    (log_dep
    ^ {|
fn note(n: Int) uses Log<Int> = Log.add(n * 10)

fn add_all<T>(xs: Array<T>) uses Log<T> =
  for x in xs
    Log.add(x)

fn main() uses Console =
  let ints: Log<Int> = log()
  let strs: Log<Str> = log()
  with ints, strs in
    note(1)
    Log.add("a")
    note(2)
    add_all(["b", "c"])
    add_all([3])
    let is: Array<Int> = Log.all()
    let ss: Array<Str> = Log.all()
    print(is)
    print(ss)
|});
  [%expect {|
    [10, 20, 3]
    ["a", "b", "c"]
    ()
    |}]

let%expect_test "[s2 accept] a with finds a generic handler's type from its body" =
  (* the body uses one `Log`, at `Int`, so that's the one installed *)
  run
    (log_dep
    ^ {|
fn main() uses Console =
  with log() in
    Log.add(1)
    Log.add(2)
    let xs: Array<Int> = Log.all()
    print(xs)
|});
  [%expect {|
    [1, 2]
    ()
    |}]

let chan_dep =
  {|
type Job = { id: Int, size: Int }

dep Chan<T> =
  send: fn(x: T)
  take: fn() -> Option<T>

dep Jobs = Chan<Job>
dep Done = Chan<Job>

handler queue<T>() for Chan<T> =
  var xs: Array<T> = []
  var at = 0
  send(x) => &xs.push(x)
  take() =>
    if at == xs.len() then None
    else
      at += 1
      Some(xs[at - 1])
|}

let%expect_test "[s2 accept] two aliases of one generic, installed with as" =
  (* `Jobs` and `Done` are each `Chan<Job>`'s operations, and each a
     dependency of its own, so one handler is installed as both *)
  run
    (chan_dep
    ^ {|
fn work() -> Int uses Jobs, Done =
  var n = 0
  var going = true
  while going
    match Jobs.take()
      Some(j) =>
        Done.send(Job { id: j.id, size: j.size * 2 })
        n += 1
      None => going = false
  n

fn main() uses Console =
  with queue() as Jobs, queue() as Done in
    Jobs.send(Job { id: 1, size: 5 })
    Jobs.send(Job { id: 2, size: 7 })
    print(work())
    print(Done.take())
    print(Done.take())
    print(Done.take())
    print(Jobs.take())
|});
  [%expect {|
    2
    Some(Job { id: 1, size: 10 })
    Some(Job { id: 2, size: 14 })
    None
    None
    ()
    |}]

let%expect_test "[s2 accept] the signatures of generic dependencies" =
  types
    {|
pub type Job = { id: Int }

pub dep Chan<T> =
  send: fn(x: T)

pub dep Jobs = Chan<Job>

pub handler queue<T>() for Chan<T> =
  var xs: Array<T> = []
  send(x) => &xs.push(x)

pub fn work() uses Jobs = Jobs.send(Job { id: 1 })
fn main() = 1
|};
  [%expect {|
    pub dep Chan<T>
      send: fn(T)
    pub dep Jobs = Chan<Job>
    pub handler queue<T>() for Chan<T>
    pub fn work() uses Jobs
    fn main() -> Int
    |}]

let%expect_test "[s2 accept] a generic handler whose type needs ==" =
  run
    {|
dep Seen<T> =
  saw: fn(x: T) -> Bool

handler seen<T has eq>() for Seen<T> =
  var xs: Array<T> = []
  saw(x) =>
    if xs.includes(x) then true
    else
      &xs.push(x)
      false

fn main() uses Console =
  with seen() in
    print(Seen.saw("a"))
    print(Seen.saw("a"))
    print(Seen.saw("b"))
|};
  [%expect {|
    false
    true
    false
    ()
    |}]

let%expect_test "[s2 reject] an alias is a dependency of its own" =
  (* `uses Jobs` doesn't give `Chan<Job>`: the help says which to call *)
  check_error
    {|
pub type Job = { id: Int }

pub dep Chan<T> =
  send: fn(x: T)

pub dep Jobs = Chan<Job>

pub fn send_one() uses Jobs = Chan.send(Job { id: 1 })
fn main() = 1
|};
  [%expect {|
    error: `send_one` doesn't declare `Chan<Job>`
      ┌─ test.ren:8:8
    8 │ pub fn send_one() uses Jobs = Chan.send(Job { id: 1 })
      │        ^^^^^^^^
      │                               ------------------------ this call uses `Chan<Job>`
      help: `Jobs` is a dependency of its own, with `Chan<Job>`'s operations: call `Jobs.send`, or add `uses Chan<Job>`
    |}]

let%expect_test "[s2 reject] a call that could be either of two instances" =
  check_error
    (log_dep
    ^ {|
fn count() -> Int uses Log<Int>, Log<Str> = Log.all().len()
fn main() = 1
|});
  [%expect {|
    error: which `Log` `Log.all()` calls isn't known: `Log<Int>` or `Log<Str>`
       ┌─ test.ren:10:45
    10 │ fn count() -> Int uses Log<Int>, Log<Str> = Log.all().len()
       │                                             ^^^^^^^^^
       help: say what its result is: `let xs: Array<Int> = Log.all()`
    |}]

let%expect_test "[s2 reject] a type parameter only a function's uses names" =
  check_error
    (log_dep
    ^ {|
fn peek<T>() -> Int uses Log<T> =
  let xs: Array<T> = Log.all()
  xs.len()
fn main() = 1
|});
  [%expect {|
    error: nothing `peek` is given fixes `T`
       ┌─ test.ren:10:9
    10 │ fn peek<T>() -> Int uses Log<T> =
       │         ^
       help: make `T` a parameter's or the result's type, or name the dependency at one type: `uses Log<Int>`
    |}]

let%expect_test "[s2 reject] a with that installs a generic at two types" =
  (* the body uses `Log<Int>` and `Log<Str>`, and `log()` is one of
     them *)
  check_error
    (log_dep
    ^ {|
fn main() =
  with log() in
    Log.add(1)
    Log.add("a")
|});
  [%expect {|
    error: which `Log` `log()` installs isn't known: the body uses `Log<Int>` and `Log<Str>`
       ┌─ test.ren:11:8
    11 │   with log() in
       │        ^^^^^
       help: say which, with a written type: `let l: Log<Int> = log()`, then `with l in`
    |}]

let%expect_test "[s2 reject] a handler's type parameter its dependency doesn't take" =
  (* test_deps.ml's "a handler can't take type parameters" becomes this *)
  check_error
    {|
dep N =
  get: fn() -> Int

handler poly<T>(x: T) for N =
  get() => 1
fn main() = 1
|};
  [%expect {|
    error: `T` isn't a type parameter of `N`
      ┌─ test.ren:4:14
    4 │ handler poly<T>(x: T) for N =
      │              ^
      help: a handler's type parameters are its dependencies': remove `<T>`
    |}]

let%expect_test "[s2 reject] an alias names one instance" =
  check_error
    {|
dep Chan<T> =
  send: fn(x: T)

dep Pipe<T> = Chan<T>
fn main() = 1
|};
  [%expect {|
    error: an alias can't take type parameters
      ┌─ test.ren:4:9
    4 │ dep Pipe<T> = Chan<T>
      │         ^
      help: use `Chan<T>` itself where it's generic, or fix the alias's types: `dep Ints = Chan<Int>`
    |}]

let%expect_test "[s2 reject] as names what the handler implements" =
  check_error
    (chan_dep
    ^ {|
dep Users =
  get: fn(id: Int) -> Int

fn main() =
  with queue() as Users in
    Users.get(1)
|});
  [%expect {|
    error: `queue()` can't be installed as `Users`
       ┌─ test.ren:24:8
    24 │   with queue() as Users in
       │        ^^^^^^^^^^^^^^^^
       help: `queue()` implements `Chan<T>`: install it as `Chan<...>` or as an alias of it
    |}]

(* ---- s3: descriptions as the only stored code (decision 3) ---- *)

let shapes =
  {|
dep Shape =
  area: fn() -> Float

handler circle(r: Float) for Shape =
  area() => 3.0 * r * r

handler square(s: Float) for Shape =
  area() => s * s
|}

let%expect_test "[s3 accept] stateless handlers called as methods" =
  (* foundations.md's example: Ren's answer to `dyn Trait` *)
  until "s3"
    ~want:{|
[3.0, 4.0, 12.0]
19.0
()
|}
    (fun () ->
      run
        (shapes
       ^ {|
fn main() uses Console =
  let shapes: Array<Shape> = [circle(1.0), square(2.0), circle(2.0)]
  print(shapes.map(fn(s) => s.area()))
  print(shapes.map(fn(s) => s.area()).sum())
|}));
  [%expect {|
    (until s3)
    error: `area` is an operation of `Shape`, so it isn't read from a value
       ┌─ test.ren:12:31
    12 │   print(shapes.map(fn(s) => s.area()))
       │                               ^^^^
       = a value of `Shape` is an implementation of it: it's used by installing it, with `with`, and then `Shape.area` calls it
       help: call the installed one: `Shape.area(...)`

    error: `area` is an operation of `Shape`, so it isn't read from a value
       ┌─ test.ren:13:31
    13 │   print(shapes.map(fn(s) => s.area()).sum())
       │                               ^^^^
       = a value of `Shape` is an implementation of it: it's used by installing it, with `with`, and then `Shape.area` calls it
       help: call the installed one: `Shape.area(...)`
    |}]

let%expect_test "[s3 accept] a method call gives the handler what it needs" =
  (* a call `g.greet(...)` installs `g` for the call, as `with g in
     Greeter.greet(...)` does, so its `uses` is the caller's to meet;
     `plain()` needs nothing and fits a slot that may need `Clock` *)
  until "s3"
    ~want:{|
hi ann
ann at Time(0)
()
|}
    (fun () ->
      run
        {|
dep Greeter =
  greet: fn(name: Str) -> Str

handler plain() for Greeter =
  greet(name) => "hi ".concat(name)

handler timed() for Greeter uses Clock =
  greet(name) => name.concat(" at ").concat(show(Clock.now()))

fn main() uses Console =
  let gs: Array<(Greeter uses Clock)> = [plain(), timed()]
  with Clock.frozen(Time.epoch) in
    for g in gs
      print(g.greet("ann"))
|});
  [%expect {|
    (until s3)
    error: `greet` is an operation of `Greeter`, so it isn't read from a value
       ┌─ test.ren:14:15
    14 │       print(g.greet("ann"))
       │               ^^^^^
       = a value of `Greeter` is an implementation of it: it's used by installing it, with `with`, and then `Greeter.greet` calls it
       help: call the installed one: `Greeter.greet(...)`
    |}]

let%expect_test "[s3 accept] a handler with state, called as a method, starts fresh" =
  (* a method call is `with c in Counter.bump()`: its state lives for the
     call (compiler.md, "Stage 10d") *)
  until "s3"
    ~want:{|
1
1
1
2
()
|}
    (fun () ->
      run
        {|
dep Counter =
  bump: fn() -> Int

handler counting() for Counter =
  var n = 0
  bump() =>
    n += 1
    n

fn main() uses Console =
  let c: Counter = counting()
  print(c.bump())
  print(c.bump())
  with c in
    print(Counter.bump())
    print(Counter.bump())
|});
  [%expect {|
    (until s3)
    error: `bump` is an operation of `Counter`, so it isn't read from a value
       ┌─ test.ren:12:11
    12 │   print(c.bump())
       │           ^^^^
       = a value of `Counter` is an implementation of it: it's used by installing it, with `with`, and then `Counter.bump` calls it
       help: call the installed one: `Counter.bump(...)`

    error: `bump` is an operation of `Counter`, so it isn't read from a value
       ┌─ test.ren:13:11
    13 │   print(c.bump())
       │           ^^^^
       = a value of `Counter` is an implementation of it: it's used by installing it, with `with`, and then `Counter.bump` calls it
       help: call the installed one: `Counter.bump(...)`
    |}]

let%expect_test "[s3 accept] an inline handler copies what it captures" =
  (* `body` is copied in when the handler is made, so the later change
     isn't seen, where a block would see it *)
  until "s3"
    ~want:
      {|
/a first
/b: hello
["/c: x", "/c", "/c first"]
()
|}
    (fun () ->
      run
        {|
dep Route =
  handle: fn(path: Str) -> Str

fn page(body: Str) -> Route = handler fn(path) => path.concat(": ").concat(body)

fn main() uses Console =
  var body = "first"
  let r: Route = handler fn(path) => path.concat(" ").concat(body)
  body = "second"
  print(r.handle("/a"))
  print(page("hello").handle("/b"))
  let routes: Array<Route> = [page("x"), handler fn(p) => p, r]
  print(routes.map(fn(x) => x.handle("/c")))
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:4:31
    4 │ fn page(body: Str) -> Route = handler fn(path) => path.concat(": ").concat(body)
      │                               ^^^^^^^

    error: expected an expression, found `handler`
      ┌─ test.ren:8:18
    8 │   let r: Route = handler fn(path) => path.concat(" ").concat(body)
      │                  ^^^^^^^
    |}]

let%expect_test "[s3 accept] an inline handler's dependencies are its caller's" =
  (* a handler, inline or not, uses what's installed where it's installed
     or called, not where it's written; so `stamper` uses nothing, and the
     description it makes needs `Clock` *)
  until "s3"
    ~want:{|
Time(60000)
()
|}
    (fun () ->
      run
        {|
dep Stamp =
  stamp: fn() -> Time

fn stamper() -> (Stamp uses Clock) = handler fn() => Clock.now()

fn main() uses Console =
  let s = stamper()
  with Clock.frozen(Time.epoch + Duration.minutes(1)) in
    print(s.stamp())
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:4:38
    4 │ fn stamper() -> (Stamp uses Clock) = handler fn() => Clock.now()
      │                                      ^^^^^^^
    |}]

let%expect_test "[s3 accept] descriptions kept in a map and a record" =
  until "s3"
    ~want:{|
5
15
10
()
|}
    (fun () ->
      run
        {|
dep Op =
  apply: fn(a: Int, b: Int) -> Int

handler add() for Op =
  apply(a, b) => a + b

handler scaled(k: Int) for Op =
  apply(a, b) => (a + b) * k

type Calc = { name: Str, op: Op }

fn main() uses Console =
  var ops: Map<Str, Op> = Map.empty
  &ops.set("+", add())
  &ops.set("*3", scaled(3))
  for k in ["+", "*3"]
    match ops.get(k)
      Some(o) => print(o.apply(2, 3))
      None => ()
  let c = Calc { name: "double", op: handler fn(a, b) => (a + b) * 2 }
  print(c.op.apply(2, 3))
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
       ┌─ test.ren:20:38
    20 │   let c = Calc { name: "double", op: handler fn(a, b) => (a + b) * 2 }
       │                                      ^^^^^^^
    |}]

let router_files =
  [
    ( "main.ren",
      {|
import api.{Api, Cache, Db}
import router.{Router}

fn respond(rs: Router<(Api uses Cache, Db)>, path: Str) -> Str uses Cache, Db =
  match rs.find(path)
    None => "404"
    Some(r) =>
      match r.handle(path)
        s => s
        fail NotFound => "404"

fn main() uses Console =
  let rs = api.routes()
  with api.mem_db(), api.counter(7) in
    for p in ["/health", "/version", "/accounts/1", "/stats", "/nope"]
      print(respond(rs, p))
|}
    );
    ( "api.ren",
      {|
import router.{Router}

pub dep Api =
  handle: fn(path: Str) -> Str ! NotFound

pub dep Db =
  balance: fn(id: Int) -> Int

pub dep Cache =
  hits: fn() -> Int

pub handler health() for Api =
  handle(_) => "ok"

pub handler account(id: Int) for Api uses Db =
  handle(_) => show(Db.balance(id))

pub handler stats() for Api uses Db, Cache =
  handle(_) => show(Db.balance(1) + Cache.hits())

// what every route may use: `health()` and the inline handler need
// less, and fit (research/paper-programs.md, F2)
pub fn routes() -> Router<(Api uses Cache, Db)> =
  var r: Router<(Api uses Cache, Db)> = Router.empty()
  &r.on("/health", health())
  &r.on("/version", handler fn(_) => "10d")
  &r.on("/accounts/1", account(1))
  &r.on("/stats", stats())
  r

pub handler mem_db() for Db =
  balance(id) => id * 100

pub handler counter(n: Int) for Cache =
  hits() => n
|}
    );
    ( "router.ren",
      {|
pub type Entry<R> = { path: Str, route: R }

pub type Router<R> = opaque { entries: Array<Entry<R>> }
  pub fn empty() -> Router<R> = Router { entries: [] }
  pub fn on(inout self, path: Str, route: R) =
    &self.entries.push(Entry { path: path, route: route })
  pub fn find(self, path: Str) -> Option<R> =
    var found = None
    for e in self.entries
      if e.path == path then found = Some(e.route)
    found
|}
    );
  ]

let%expect_test "[s3 accept] the router: a stored description's uses is an upper bound (F2)" =
  (* research/paper-programs.md's server/api.ren, cut down: each route
     is called as a method, and the table's slot says what any route may
     use. Today a route that needs less is refused, with the help
     `(Api)`, and the message says the opposite of what's happening *)
  until "s3"
    ~want:{|
ok
10d
100
107
404
()
|}
    (fun () -> run_files router_files);
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
       ┌─ api.ren:26:21
    26 │   &r.on("/version", handler fn(_) => "10d")
       │                     ^^^^^^^
    |}]

let%expect_test "[s3 reject] a stored description that needs more than its slot" =
  (* the direction the message says is now the right one, and it names
     what's needed beyond the slot *)
  until "s3"
    ~says:
      [
        "error: expected `Api uses Db`, found `Api uses Clock, Db`";
        "= a stored description's `uses` is the most it may need, and this \
         one needs `Clock` too";
        "help: add it where the type is written: `Array<(Api uses Clock, \
         Db)>`";
      ]
    (fun () ->
      check_error
        {|
dep Api =
  handle: fn(x: Int) -> Int

dep Db =
  get: fn() -> Int

handler timed() for Api uses Clock, Db =
  handle(x) => if Clock.now() == Time.epoch then x else Db.get()

fn main() uses Console =
  let rs: Array<(Api uses Db)> = [timed()]
  print(rs.len())
|});
  [%expect {|
    (until s3)
    error: expected `Api uses Db`, found `Api uses Clock, Db`
       ┌─ test.ren:11:35
    11 │   let rs: Array<(Api uses Db)> = [timed()]
       │                                   ^^^^^^^
       = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
       help: say what it needs where its type is written: `(Api uses Clock, Db)`
    |}]

let%expect_test "[s3 reject] an inline handler for a dependency of several operations" =
  until "s3"
    ~says:
      [
        "error: an inline handler implements a dependency of one operation, \
         and `Users` has 2";
        "help: declare a handler with an arm for each: `handler name() for \
         Users`";
      ]
    (fun () ->
      check_error
        {|
dep Users =
  get: fn(id: Int) -> Int
  count: fn() -> Int

fn main() uses Console =
  let u: Users = handler fn(id) => id
  print(1)
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:6:18
    6 │   let u: Users = handler fn(id) => id
      │                  ^^^^^^^
    |}]

let%expect_test "[s3 reject] an inline handler whose dependency isn't known" =
  until "s3"
    ~says:
      [
        "error: which dependency this inline handler implements isn't known \
         here";
        "help: write the type it's kept as: `let h: D = handler fn(...) => \
         ...`";
      ]
    (fun () ->
      check_error
        {|
fn main() uses Console =
  let h = handler fn(x) => x
  print(1)
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:2:11
    2 │   let h = handler fn(x) => x
      │           ^^^^^^^
    |}]

let%expect_test "[s3 reject] an inline handler can't keep a block" =
  (* what it captures is copied into its description, which is data, as a
     handler's parameters are *)
  until "s3"
    ~says:
      [
        "error: an inline handler's captures are data, and `f` is a block";
        "help: pass the data it needs, or make the behaviour a dependency";
      ]
    (fun () ->
      check_error
        {|
dep Get =
  get: fn() -> Int

fn make(f: fn() -> Int) -> Get = handler fn() => try f()
fn main() = 1
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:4:34
    4 │ fn make(f: fn() -> Int) -> Get = handler fn() => try f()
      │                                  ^^^^^^^
    |}]

let%expect_test "[s3 reject] an inline handler has no next" =
  until "s3"
    ~says:
      [
        "error: an inline handler doesn't go over another, so it has no `next`";
        "help: declare a handler `over Get` to call the one under it";
      ]
    (fun () ->
      check_error
        {|
dep Get =
  get: fn() -> Int

fn main() uses Console =
  let g: Get = handler fn() => next.get() + 1
  print(1)
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `handler`
      ┌─ test.ren:5:16
    5 │   let g: Get = handler fn() => next.get() + 1
      │                ^^^^^^^
    |}]

let%expect_test "[s3 reject] a chain isn't a value" =
  until "s3"
    ~says:
      [
        "error: a chain of handlers isn't a value";
        "help: keep the parts, and write the chain where it's installed: \
         `with cached() over mem() in ...`";
      ]
    (fun () ->
      check_error
        {|
dep Users =
  get: fn(id: Int) -> Int

handler mem() for Users =
  get(id) => id

handler cached() over Users =
  get(id) => next.get(id) + 1

fn main() uses Console =
  let x = cached() over mem()
  with x in print(Users.get(1))
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `over`
       ┌─ test.ren:11:20
    11 │   let x = cached() over mem()
       │                    ^^^^
    |}]

let%expect_test "[s3 reject] a description that can fail to start isn't called" =
  (* a method call installs the description for the call, and one whose
     state can fail to start is installed with `with`, whose errors show *)
  until "s3"
    ~says:
      [
        "error: `s` can fail to start, so it isn't called as a method";
        "help: install it: `with s in Store.get()`";
      ]
    (fun () ->
      check_error
        {|
dep Store =
  get: fn() -> Int

fn start() -> Int ! Down = fail Down

handler opened() for Store ! Down =
  let n = try start()
  get() => n

fn main() =
  let s: Store ! Down = opened()
  let _ = s.get()
|});
  [%expect {|
    (until s3)
    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:12:7
    12 │   let _ = s.get()
       │       ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s3 reject] a description that goes over another isn't called" =
  until "s3"
    ~says:
      [
        "error: `c` goes over another `Users`, so it isn't called as a method";
        "help: install it over one: `with c over Users in Users.get(...)`";
      ]
    (fun () ->
      check_error
        {|
dep Users =
  get: fn(id: Int) -> Int

handler cached() over Users =
  get(id) => next.get(id) + 1

fn main() =
  let c: over Users = cached()
  let _ = c.get(1)
|});
  [%expect {|
    (until s3)
    error: this block ends with a `let`, so it has no value
      ┌─ test.ren:9:7
    9 │   let _ = c.get(1)
      │       ^
      help: add the value this block should produce as its last line
    |}]

(* ---- s5: `over any` and `retry` (decision 7) ---- *)

let users_and_store =
  {|
dep Users =
  get: fn(id: Int) -> Str ! NoUser(id: Int)
  count: fn() -> Int

handler mem_users() for Users =
  get(id) => if id == 1 then "ann" else fail NoUser(id)
  count() => 1

dep Store =
  get: fn(k: Str) -> Int ! Down
  put: fn(k: Str, v: Int) ! Down

handler mem_store() for Store =
  var m: Map<Str, Int> = Map.empty
  get(k) => m.get(k) orelse 0
  put(k, v) => &m.set(k, v)

// every `every`th call fails with `Down`, which every operation of what
// it goes over has to declare
handler down_every(every: Int) over any =
  var n = 0
  call =>
    n += 1
    if n % every == 0 then call.fail(Down) else try call.forward()
|}

let%expect_test "[s5 accept] one logger over any dependency" =
  (* `call.name` is the operation's, as a journal writes it; `call.args`
     and what `call.forward()` gives are opaque, and shown by what the
     compiler derives for each operation *)
  until "s5"
    ~want:
      {|
> Users.count()
< Ok(1)
1
> Users.get(1)
< Ok("ann")
Ok("ann")
> Users.get(2)
< Err(NoUser(2))
Err(NoUser(2))
> Clock.now()
< Ok(Time(0))
Time(0)
> Store.put("a", 7)
< Ok(())
()
|}
    (fun () ->
      run
        (users_and_store
       ^ {|
handler logged() over any uses Console =
  call =>
    Console.write("> ".concat(call.name).concat(show(call.args)))
    let r = attempt call.forward()
    Console.write("< ".concat(show(r)))
    try r

fn main() uses Console =
  with logged() over mem_users() in
    print(Users.count())
    print(attempt Users.get(1))
    print(attempt Users.get(2))
  with logged() over Clock.frozen(Time.epoch) in
    print(Clock.now())
  with logged() over mem_store() in
    let _ = attempt Store.put("a", 7)
|}));
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
       ┌─ test.ren:20:37
    20 │ handler down_every(every: Int) over any =
       │                                     ^^^
       help: write `Any`

    error: a dependency's name must start with a capital letter
       ┌─ test.ren:26:23
    26 │ handler logged() over any uses Console =
       │                       ^^^
       help: write `Any`

    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:41:9
    41 │     let _ = attempt Store.put("a", 7)
       │         ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s5 accept] call.fail injects a declared error" =
  until "s5"
    ~want:
      {|
Ok(())
Ok(1)
Err(Down)
Ok(())
Ok(2)
Err(Down)
()
|}
    (fun () ->
      run
        (users_and_store
       ^ {|
fn main() uses Console =
  with down_every(3) over mem_store() in
    print(attempt Store.put("a", 1))
    print(attempt Store.get("a"))
    print(attempt Store.get("a"))
    print(attempt Store.put("a", 2))
    print(attempt Store.get("a"))
    print(attempt Store.get("b"))
|}));
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
       ┌─ test.ren:20:37
    20 │ handler down_every(every: Int) over any =
       │                                     ^^^
       help: write `Any`
    |}]

let%expect_test "[s5 reject] call.fail with an error an operation doesn't declare" =
  (* checked where it's installed, for each operation of what it goes
     over, since it's specialized for each *)
  until "s5"
    ~says:
      [
        "error: `down_every(2)` can fail with `Down`, which `Users.get` and \
         `Users.count` don't declare";
        "help: install it over a dependency whose every operation can fail \
         with `Down`, or write a handler `over Users`";
      ]
    (fun () ->
      check_error
        (users_and_store
       ^ {|
fn main() uses Console =
  with down_every(2) over mem_users() in
    print(Users.count())
|}));
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
       ┌─ test.ren:20:37
    20 │ handler down_every(every: Int) over any =
       │                                     ^^^
       help: write `Any`
    |}]

let%expect_test "[s5 reject] call.forward() at most once" =
  until "s5"
    ~says:
      [
        "error: `call.forward()` runs the operation under this one, so it's \
         called once at most";
        "help: keep what it gave: `let r = attempt call.forward()`, and \
         `try r` where it's needed";
      ]
    (fun () ->
      check_error
        {|
handler twice() over any =
  call =>
    let _ = attempt call.forward()
    try call.forward()

fn main() = 1
|});
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:1:22
    1 │ handler twice() over any =
      │                      ^^^
      help: write `Any`
    |}]

let%expect_test "[s5 reject] call is only used through" =
  (* as `next` is: it can't be kept, passed or returned, and a block
     can't call `call.forward()`, since that would be a second way to
     call it twice *)
  until "s5"
    ~says:
      [
        "error: `call` can only be used through";
        "help: use `call.forward()`, `call.fail(e)`, `call.name` or \
         `call.args` where they're needed";
      ]
    (fun () ->
      check_error
        {|
handler kept() over any =
  call =>
    let c = call
    try c.forward()

fn main() = 1
|});
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:1:21
    1 │ handler kept() over any =
      │                     ^^^
      help: write `Any`
    |}]

let%expect_test "[s5 reject] call.args can't be taken apart" =
  until "s5"
    ~says:
      [
        "error: `call.args` can only be shown, compared and recorded";
        "help: write a handler `over` the dependency to read its arguments";
      ]
    (fun () ->
      check_error
        {|
handler peek() over any =
  call =>
    let (a, b) = call.args
    try call.forward()

fn main() = 1
|});
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:1:21
    1 │ handler peek() over any =
      │                     ^^^
      help: write `Any`
    |}]

let%expect_test "[s5 reject] an over any handler is installed with over" =
  until "s5"
    ~says:
      [
        "error: `quiet()` goes over another implementation, so it's \
         installed with `over`";
        "help: say what it goes over: `quiet() over Users` for the one \
         installed outside this `with`, or another implementation after \
         `over`";
      ]
    (fun () ->
      check_error
        {|
dep Users =
  get: fn(id: Int) -> Int

handler quiet() over any =
  call => try call.forward()

fn main() =
  with quiet() in
    let _ = Users.get(1)
|});
  [%expect {|
    (until s5)
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:4:22
    4 │ handler quiet() over any =
      │                      ^^^
      help: write `Any`

    error: this block ends with a `let`, so it has no value
      ┌─ test.ren:9:9
    9 │     let _ = Users.get(1)
      │         ^
      help: add the value this block should produce as its last line
    |}]

let source =
  {|
dep Source =
  get: fn() -> Int ! Flaky | Broken

handler flaky(fails: Int) for Source =
  var left = fails
  get() =>
    if left > 0 then
      left -= 1
      fail Flaky
    else 42

handler broken() for Source =
  get() => fail Broken
|}

let%expect_test "[s5 accept] retry tries again only on what it's told" =
  (* the prelude's `retry`, in Ren: after `n` tries the last error
     leaves, any other error leaves at once, and a block is tried once
     however small `n` is *)
  until "s5"
    ~want:
      {|
Ok(42)
Err(Flaky)
Err(Broken)
Err(Flaky)
Err(Broken)
1
Ok(42)
()
|}
    (fun () ->
      run
        (source
       ^ {|
fn fetch(n: Int) -> Int ! Flaky | Broken uses Source =
  try retry(n, on: Flaky) fn() => try Source.get()

fn main() uses Console =
  with flaky(2) in
    print(attempt fetch(3))
  with flaky(3) in
    print(attempt fetch(3))
  with broken() in
    print(attempt fetch(3))
  with flaky(1) in
    print(attempt retry(0, on: Flaky) fn() => try Source.get())
  var tries = 0
  with broken() in
    let r = attempt retry(5, on: Flaky) fn() =>
      tries += 1
      try Source.get()
    print(r)
  print(tries)
  with flaky(2) in
    print(attempt retry(3, on: Flaky | Broken) fn() => try Source.get())
|}));
  [%expect {|
    (until s5)
    error: expected `,` or `)`, found `:`
       ┌─ test.ren:16:18
    16 │   try retry(n, on: Flaky) fn() => try Source.get()
       │                  ^

    error: expected `,` or `)`, found `:`
       ┌─ test.ren:26:30
    26 │     print(attempt retry(0, on: Flaky) fn() => try Source.get())
       │                              ^
    |}]

let%expect_test "[s5 accept] a function of your own that takes Tags" =
  (* `on` is matched with `fail on`, and passed on with `on: on`; a
     `match` that handles it is a `try match`, since which errors it
     names isn't known where it's written *)
  until "s5"
    ~want:{|
Ok(42)
Err(Flaky)
()
|}
    (fun () ->
      run
        (source
       ^ {|
fn twice<T>(on: Tags, body: fn() -> T) -> T =
  try match body()
    fail on => try body()
    v => v

fn main() uses Console =
  with flaky(1) in
    print(attempt twice(on: Flaky) fn() => try Source.get())
  with flaky(2) in
    print(attempt twice(on: Flaky) fn() => try Source.get())
|}));
  [%expect {|
    (until s5)
    error: a `fail` pattern can't bind the whole error to a name
       ┌─ test.ren:17:10
    17 │     fail on => try body()
       │          ^^
       help: match each tag, like `fail NotFound`, or keep the whole outcome as a value with `attempt`, and match `Err(on)`

    error: expected `,` or `)`, found `:`
       ┌─ test.ren:22:27
    22 │     print(attempt twice(on: Flaky) fn() => try Source.get())
       │                           ^
    |}]

let%expect_test "[s5 reject] retry without on" =
  (* `retry(n)` retried any error; now it says which, and the help lists
     what the block can fail with *)
  until "s5"
    ~says:
      [
        "error: `retry` takes `on:`, the errors it tries again";
        "help: name them: `retry(3, on: Broken | Flaky)`";
      ]
    (fun () ->
      check_error
        (source
       ^ {|
fn main() =
  let _ = attempt retry(3) fn() => try Source.get()
|}));
  [%expect {|
    (until s5)
    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:16:7
    16 │   let _ = attempt retry(3) fn() => try Source.get()
       │       ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s5 reject] on names an error the block can't fail with" =
  until "s5"
    ~says:
      [
        "error: `retry` is given `on: Timeout`, and the block can't fail with \
         `Timeout`";
        "help: name what it can fail with: `Broken`, `Flaky`";
      ]
    (fun () ->
      check_error
        (source
       ^ {|
fn main() =
  let _ = attempt retry(3, on: Timeout) fn() => try Source.get()
|}));
  [%expect {|
    (until s5)
    error: expected `,` or `)`, found `:`
       ┌─ test.ren:16:30
    16 │   let _ = attempt retry(3, on: Timeout) fn() => try Source.get()
       │                              ^
    |}]

let%expect_test "[s5 reject] a Tags argument is written with its name" =
  until "s5"
    ~says:
      [
        "error: `on`, the errors `retry` tries again, is written with its \
         name";
        "help: write `on: Flaky`";
      ]
    (fun () ->
      check_error
        (source
       ^ {|
fn main() =
  let _ = attempt retry(3, Flaky) fn() => try Source.get()
|}));
  [%expect {|
    (until s5)
    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:16:7
    16 │   let _ = attempt retry(3, Flaky) fn() => try Source.get()
       │       ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s5 reject] only a Tags parameter is passed by name" =
  until "s5"
    ~says:
      [
        "error: `n` isn't passed by name";
        "help: a name goes only before a parameter of `Tags`: write `3`";
      ]
    (fun () ->
      check_error
        (source
       ^ {|
fn main() =
  let _ = attempt retry(n: 3, on: Flaky) fn() => try Source.get()
|}));
  [%expect {|
    (until s5)
    error: expected `,` or `)`, found `:`
       ┌─ test.ren:16:26
    16 │   let _ = attempt retry(n: 3, on: Flaky) fn() => try Source.get()
       │                          ^
    |}]

(* ---- s6: blocks with `inout` parameters, and slices (decision 17) ---- *)

let%expect_test "[s6 accept] blocks that take inout parameters (M3)" =
  until "s6"
    ~want:{|
(11, 0)
[1, 20, 3]
12
15
()
|}
    (fun () ->
      run
        {|
fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int)) = try f(&a, &b)

fn modify(inout xs: Array<Int>, i: Int, f: fn(&Int)) = try f(&xs[i])

dep Tally =
  change: fn(k: Int, f: fn(&Int))
  get: fn(k: Int) -> Int

// an operation that lends a block one of its counts, as the paper
// programs' `Snapshot.update` would lend its value
handler counts() for Tally =
  var cs = [0, 0, 0]
  change(k, f) =>
    var c = cs[k]
    f(&c)
    cs[k] = c
  get(k) => cs[k]

fn main() uses Console =
  var x = 1
  var y = 10
  both(&x, &y) fn(&a, &b) =>
    a += b
    b = 0
  print((x, y))
  var xs = [1, 2, 3]
  modify(&xs, 1, fn(&n) => n = n * 10)
  print(xs)
  let bump = fn(&n) => n += 1
  bump(&x)
  print(x)
  with counts() in
    Tally.change(1) fn(&c) => c += 5
    Tally.change(1) fn(&c) => c = c * 3
    print(Tally.get(1))
|});
  [%expect {|
    (until s6)
    error: expected a name, found `&`
      ┌─ test.ren:1:43
    1 │ fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int)) = try f(&a, &b)
      │                                           ^

    error: expected a name, found `&`
      ┌─ test.ren:3:47
    3 │ fn modify(inout xs: Array<Int>, i: Int, f: fn(&Int)) = try f(&xs[i])
      │                                               ^

    error: expected a name, found `&`
      ┌─ test.ren:6:28
    6 │   change: fn(k: Int, f: fn(&Int))
      │                            ^

    error: expected a name, found `&`
       ┌─ test.ren:22:19
    22 │   both(&x, &y) fn(&a, &b) =>
       │                   ^
    |}]

let%expect_test "[s6 accept] a function type writes an inout parameter &T" =
  until "s6" ~checks:true
    ~says:[ "f: fn(&Int, &Int)" ]
    (fun () ->
      types
        {|
fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int)) = try f(&a, &b)
fn main() = 1
|});
  [%expect {|
    (until s6)
    error: expected a name, found `&`
      ┌─ test.ren:1:43
    1 │ fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int)) = try f(&a, &b)
      │                                           ^
    |}]

let%expect_test "[s6 reject] a block's inout parameter is written &x" =
  (* test_mut.ml's "blocks can't take inout parameters" becomes this *)
  until "s6"
    ~says:
      [
        "error: a block's parameter that it changes is written `&n`";
        "help: write `fn(&n) => ...`";
      ]
    (fun () ->
      check_error {|
fn main() =
  let f = fn(inout n) => n += 1
  ()
|});
  [%expect {|
    (until s6)
    error: blocks can't take `inout` parameters yet
      ┌─ test.ren:2:20
    2 │   let f = fn(inout n) => n += 1
      │                    ^
      help: use a top-level function for this
    |}]

let%expect_test "[s6 reject] a block can't read what the call it's given to changes" =
  (* exclusivity, unchanged: the receiver `&xs` is a write of `xs` for
     the call, and the block reads it *)
  until "s6"
    ~says:
      [
        "error: `xs` is read by this block while the call changes it";
        "help: read it first: `let item = xs[3]`, and use `item` in the block";
      ]
    (fun () ->
      check_error
        {|
fn main() =
  var xs = [1, 2, 3, 4]
  &xs.split_at(2) fn(&lo, &hi) => lo[0] = xs[3]
|});
  [%expect {|
    (until s6)
    error: expected a name, found `&`
      ┌─ test.ren:3:22
    3 │   &xs.split_at(2) fn(&lo, &hi) => lo[0] = xs[3]
      │                      ^
    |}]

let%expect_test "[s6 accept] slices are values of the type they slice (M6)" =
  until "s6"
    ~want:
      {|
[2, 3, 4, 5]
4
[3, 4]
true
0
true
[70, 8, 9, 10]
[7, 8, 9]
true
()
|}
    (fun () ->
      run
        {|
fn main() uses Console =
  let xs = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
  let mid = xs[2..6]
  print(mid)
  print(mid.len())
  print(mid[1..3])
  print(mid == [2, 3, 4, 5])
  print(xs[4..4].len())
  print(xs[0..xs.len()] == xs)
  var ys = xs[7..10]
  ys[0] = 70
  &ys.push(10)
  print(ys)
  print(xs[7..10])
  print(ys.copy() == ys)
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:3:17
    3 │   let mid = xs[2..6]
      │                 ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}]

let%expect_test "[s6 accept] & on a range changes that range" =
  (* as `&xs[i]` changes an element: what the call leaves in its
     parameter replaces the range, so a longer one moves what follows *)
  until "s6"
    ~want:
      {|
[1, 4, 6, 4, 5]
[1, 4, 0, 6, 4, 5]
[1, 4, 0, 106, 104, 105]
()
|}
    (fun () ->
      run
        {|
fn double(inout ys: Array<Int>) =
  for i in 0..ys.len()
    ys[i] = ys[i] * 2

fn grow(inout ys: Array<Int>) = &ys.push(0)

fn main() uses Console =
  var zs = [1, 2, 3, 4, 5]
  double(&zs[1..3])
  print(zs)
  grow(&zs[0..2])
  print(zs)
  for z in &zs[3..6]
    z = z + 100
  print(zs)
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:9:15
    9 │   double(&zs[1..3])
      │               ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}]

let%expect_test "[s6 accept] split_at gives a block two places of its own" =
  until "s6"
    ~want:
      {|
[6, 8, 10, 12, 100, 6, 7, 8]
6
[6, 8, 0, 10, 12, 100, 6, 7, 8]
()
|}
    (fun () ->
      run
        {|
fn add(inout dst: Array<Int>, src: Array<Int>) =
  for i in 0..dst.len()
    dst[i] = dst[i] + src[i]

fn main() uses Console =
  var ws = [1, 2, 3, 4, 5, 6, 7, 8]
  &ws.split_at(4) fn(&lo, &hi) =>
    add(&lo, hi)
    hi[0] = 100
  print(ws)
  let n = &ws.split_at(2) fn(&lo, &hi) =>
    &lo.push(0)
    hi.len()
  print(n)
  print(ws)
|});
  [%expect {|
    (until s6)
    error: expected a name, found `&`
      ┌─ test.ren:7:22
    7 │   &ws.split_at(4) fn(&lo, &hi) =>
      │                      ^
    |}]

let%expect_test "[s6 accept] Str and Bytes slices" =
  (* a `Str`'s offsets are bytes, as `len` counts them; `split` and `trim`
     give slices of what they're given *)
  until "s6"
    ~want:
      {|
héllo
wörld
6
true
["héllo", "wörld"]
true
3
true
Ok("bcd")
true
()
|}
    (fun () ->
      run
        {|
fn main() uses Console =
  let s = "héllo, wörld"
  print(s[0..6])
  print(s[8..14])
  print(s[8..14].len())
  print(s[0..1] == "h")
  print(s.split(", "))
  print(s.copy() == s)
  let b = "abcdef".bytes()
  print(b[1..4].len())
  print(b[1..4] == "bcd".bytes())
  print(attempt Str.from_utf8(b[1..4]))
  print(b.copy() == b)
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:3:12
    3 │   print(s[0..6])
      │            ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}]

let%expect_test "[s6 reject] slices that panic" =
  until "s6"
    ~says:[ "panic: slice 2 to 5 is out of bounds for an array of length 3" ]
    (fun () ->
      run
        {|
fn main() uses Console =
  let xs = [1, 2, 3]
  let n = 5
  print(xs[2..n])
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:4:13
    4 │   print(xs[2..n])
      │             ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}];
  until "s6"
    ~says:[ "panic: slice 3 to 1 ends before it starts" ]
    (fun () ->
      run
        {|
fn main() uses Console =
  let xs = [1, 2, 3]
  let a = 3
  print(xs[a..1])
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:4:13
    4 │   print(xs[a..1])
      │             ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}];
  until "s6"
    ~says:[ "panic: slice 0 to 2 ends inside a character" ]
    (fun () ->
      run
        {|
fn main() uses Console =
  let s = "héllo"
  print(s[0..2])
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:3:12
    3 │   print(s[0..2])
      │            ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}];
  until "s6"
    ~says:[ "panic: `split_at` 5 is out of bounds for an array of length 3" ]
    (fun () ->
      run
        {|
fn main() uses Console =
  var xs = [1, 2, 3]
  &xs.split_at(5) fn(&lo, &hi) => lo[0] = 0
  print(xs)
|});
  [%expect {|
    (until s6)
    error: expected a name, found `&`
      ┌─ test.ren:3:22
    3 │   &xs.split_at(5) fn(&lo, &hi) => lo[0] = 0
      │                      ^
    |}]

let%expect_test "[s6 reject] two ranges of one array in one call" =
  (* two ranges may overlap, as two indices may, so no rule changes; the
     help says how to change both *)
  until "s6"
    ~says:
      [
        "error: `xs` is passed with `&` twice in this call";
        "help: to change two parts of one array, split it: \
         `&xs.split_at(2) fn(&lo, &hi) => ...`";
      ]
    (fun () ->
      check_error
        {|
fn add(inout dst: Array<Int>, src: Array<Int>) =
  for i in 0..dst.len()
    dst[i] = dst[i] + src[i]

fn both(inout a: Array<Int>, inout b: Array<Int>) =
  add(&a, b)

fn main() =
  var xs = [1, 2, 3, 4]
  both(&xs[0..2], &xs[2..4])
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
       ┌─ test.ren:10:13
    10 │   both(&xs[0..2], &xs[2..4])
       │             ^^
       help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}]

let%expect_test "[s6 reject] Str.slice is a slice now" =
  until "s6"
    ~says:
      [ "error: `Str` has no method named `slice`"; "help: slice it: `s[0..2]`" ]
    (fun () ->
      check_error
        {|
fn main() uses Console =
  let s = "hello"
  print(s.slice(0, 2))
|});
  [%expect {|
    (until s6)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s6 reject] a range is a value only in a for and an index" =
  (* test_collections.ml's range test changes its help to this *)
  until "s6"
    ~says:
      [
        "help: a range is for counting, `for i in 0..n`, and for slicing, \
         `xs[a..b]`";
      ]
    (fun () -> check_error {|
fn main() =
  let r = 0..3
  ()
|});
  [%expect {|
    (until s6)
    error: a range, `a..b`, is written only after a `for`'s `in`: it isn't a value
      ┌─ test.ren:2:12
    2 │   let r = 0..3
      │            ^^
      help: a range is for counting, `for i in 0..n`; to keep some of an array, use `take` and `drop`
    |}]
