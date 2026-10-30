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

let codecs =
  {|
dep Codec =
  cost: fn() -> Float

handler deflate(level: Float) for Codec =
  cost() => 3.0 * level * level

handler lz4(block: Float) for Codec =
  cost() => block * block
|}

let%expect_test "[s3 accept] stateless handlers called as methods" =
  (* codecs a library keeps, each a kind its users may add: a call of one
     as a method is a pure dispatch (foundations.md, decision 3) *)
  run
    (codecs
   ^ {|
fn main() uses Console =
  let codecs: Array<Codec> = [deflate(1.0), lz4(2.0), deflate(2.0)]
  print(codecs.map(fn(c) => c.cost()))
  print(codecs.map(fn(c) => c.cost()).sum())
|});
  [%expect {|
    [3.0, 4.0, 12.0]
    19.0
    ()
    |}]

let%expect_test "[s3 accept] a method call gives the handler what it needs" =
  (* a call `g.greet(...)` installs `g` for the call, as `with g in
     Greeter.greet(...)` does, so its `uses` is the caller's to meet;
     `plain()` needs nothing and fits a slot that may need `Clock` *)
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
|};
  [%expect {|
    hi ann
    ann at Time(0)
    ()
    |}]

let counter =
  {|
dep Counter =
  bump: fn() -> Int

handler counting() for Counter =
  var n = 0
  bump() =>
    n += 1
    n
|}

let%expect_test "[s3 reject] a handler with state isn't called as a method" =
  (* a method call would be `with c in Counter.bump()`, its state living
     for the call, so it would say 1 each time: since the data stage's
     step 6 it's refused, and the help writes the `with` (compiler.md,
     "Data stage", "Descriptions (step 6)") *)
  run
    (counter
   ^ {|
fn main() uses Console =
  let c: Counter = counting()
  print(c.bump())
  print(c.bump())
|});
  [%expect {|
    error: `c` may be a description of `counting`, which keeps state, so it isn't called as a method
       ┌─ test.ren:12:11
    12 │   print(c.bump())
       │           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with c in Counter.bump()`

    error: `c` may be a description of `counting`, which keeps state, so it isn't called as a method
       ┌─ test.ren:13:11
    13 │   print(c.bump())
       │           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with c in Counter.bump()`
    |}]

let%expect_test "[s3 accept] a handler with state, installed, keeps it" =
  run
    (counter
   ^ {|
fn main() uses Console =
  let c: Counter = counting()
  with c in
    print(Counter.bump())
    print(Counter.bump())
|});
  [%expect {|
    1
    2
    ()
    |}]

let%expect_test "[s3 accept] an inline handler copies what it captures" =
  (* `body` is copied in when the handler is made, so the later change
     isn't seen, where a block would see it *)
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
|};
  [%expect {|
    /a first
    /b: hello
    ["/c: x", "/c", "/c first"]
    ()
    |}]

let%expect_test "[s3 accept] an inline handler's dependencies are its caller's" =
  (* a handler, inline or not, uses what's installed where it's installed
     or called, not where it's written; so `stamper` uses nothing, and the
     description it makes needs `Clock` *)
  run
    {|
dep Stamp =
  stamp: fn() -> Time

fn stamper() -> (Stamp uses Clock) = handler fn() => Clock.now()

fn main() uses Console =
  let s = stamper()
  with Clock.frozen(Time.epoch + Duration.minutes(1)) in
    print(s.stamp())
|};
  [%expect {|
    Time(60000)
    ()
    |}]

let%expect_test "[s3 accept] descriptions kept in a map and a record" =
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
|};
  [%expect {|
    5
    15
    10
    ()
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
  run_files router_files;
  [%expect {|
    ok
    10d
    100
    107
    404
    ()
    |}]

let%expect_test "[s3 reject] a stored description that needs more than its slot" =
  (* the direction the message says is now the right one, and it names
     what's needed beyond the slot *)
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
|};
  [%expect {|
    error: expected `Api uses Db`, found `Api uses Clock, Db`
       ┌─ test.ren:11:35
    11 │   let rs: Array<(Api uses Db)> = [timed()]
       │                                   ^^^^^^^
       = a stored description's `uses` is the most it may need, and this one needs `Clock` too
       help: add it where the type is written: `Array<(Api uses Clock, Db)>`
    |}]

let%expect_test "[s3 reject] an inline handler for a dependency of several operations" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int
  count: fn() -> Int

fn main() uses Console =
  let u: Users = handler fn(id) => id
  print(1)
|};
  [%expect {|
    error: an inline handler implements a dependency of one operation, and `Users` has 2
      ┌─ test.ren:6:18
    6 │   let u: Users = handler fn(id) => id
      │                  ^^^^^^^^^^^^^^^^^^^^
      help: declare a handler with an arm for each: `handler name() for Users`
    |}]

let%expect_test "[s3 reject] an inline handler whose dependency isn't known" =
  check_error
    {|
fn main() uses Console =
  let h = handler fn(x) => x
  print(1)
|};
  [%expect {|
    error: which dependency this inline handler implements isn't known here
      ┌─ test.ren:2:11
    2 │   let h = handler fn(x) => x
      │           ^^^^^^^^^^^^^^^^^^
      help: write the type it's kept as: `let h: D = handler fn(...) => ...`
    |}]

let%expect_test "[s3 reject] an inline handler can't keep a block" =
  (* what it captures is copied into its description, which is data, as a
     handler's parameters are *)
  check_error
    {|
dep Get =
  get: fn() -> Int

fn make(f: fn() -> Int) -> Get = handler fn() => try f()
fn main() = 1
|};
  [%expect {|
    error: an inline handler's captures are data, and `f` is a block
      ┌─ test.ren:4:54
    4 │ fn make(f: fn() -> Int) -> Get = handler fn() => try f()
      │                                                      ^
      help: pass the data it needs, or make the behaviour a dependency
    |}]

let%expect_test "[s3 reject] an inline handler has no next" =
  check_error
    {|
dep Get =
  get: fn() -> Int

fn main() uses Console =
  let g: Get = handler fn() => next.get() + 1
  print(1)
|};
  [%expect {|
    error: an inline handler doesn't go over another, so it has no `next`
      ┌─ test.ren:5:32
    5 │   let g: Get = handler fn() => next.get() + 1
      │                                ^^^^
      help: declare a handler `over Get` to call the one under it
    |}]

let%expect_test "[s3 reject] a chain isn't a value" =
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
|};
  [%expect {|
    error: a chain of handlers isn't a value
       ┌─ test.ren:11:11
    11 │   let x = cached() over mem()
       │           ^^^^^^^^^^^^^^^^^^^
       help: keep the parts, and write the chain where it's installed: `with cached() over mem() in ...`
    |}]

let%expect_test "[s3 reject] a description that can fail to start isn't called" =
  (* a method call installs the description for the call, and one whose
     state can fail to start is installed with `with`, whose errors show *)
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
  s.get()
|};
  [%expect {|
    error: `s` can fail to start, so it isn't called as a method
       ┌─ test.ren:12:5
    12 │   s.get()
       │     ^^^
       help: install it: `with s in Store.get()`
    |}]

let%expect_test "[s3 reject] a description that goes over another isn't called" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler cached() over Users =
  get(id) => next.get(id) + 1

fn main() =
  let c: over Users = cached()
  c.get(1)
|};
  [%expect {|
    error: `c` goes over another `Users`, so it isn't called as a method
      ┌─ test.ren:9:5
    9 │   c.get(1)
      │     ^^^
      help: install it over one: `with c over Users in Users.get(...)`
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
    ()
|});
  [%expect {|
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
    |}]

let%expect_test "[s5 accept] call.fail injects a declared error" =
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
|});
  [%expect {|
    Ok(())
    Ok(1)
    Err(Down)
    Ok(())
    Ok(2)
    Err(Down)
    ()
    |}]

let%expect_test "[s5 reject] call.fail with an error an operation doesn't declare" =
  (* checked where it's installed, for each operation of what it goes
     over, since it's specialized for each *)
  check_error
        (users_and_store
       ^ {|
fn main() uses Console =
  with down_every(2) over mem_users() in
    print(Users.count())
|});
  [%expect {|
    error: `down_every(2)` can fail with `Down`, which `Users.get` and `Users.count` don't declare
       ┌─ test.ren:27:8
    27 │   with down_every(2) over mem_users() in
       │        ^^^^^^^^^^^^^
       = an operation fails only with the errors its dependency declares, whatever is installed for it
       help: install it over a dependency whose every operation can fail with `Down`, or write a handler `over Users`
    |}]

let%expect_test "[s5 reject] over any over an operation that takes a block" =
  (* `call.args` would hold the block in a tuple, and a block is never
     held (found in the stage-10d review: Core Lint and native lowering
     failed on it) *)
  check_error
    {|
dep Tally =
  change: fn(k: Int, f: fn(&Int))
  get: fn(k: Int) -> Int

handler counts() for Tally =
  var c = 0
  change(k, f) =>
    var x = c
    f(&x)
    c = x + k
  get(k) => c + k

handler logged() over any uses Console =
  call =>
    Console.write(call.name.concat(show(call.args)))
    try call.forward()

fn main() uses Console =
  with logged() over counts() in
    print(Tally.get(1))
|};
  [%expect {|
    error: `logged()` can't go over `Tally`: `Tally.change` takes a block
       ┌─ test.ren:19:8
    19 │   with logged() over counts() in
       │        ^^^^^^^^
       = `call.args` holds an operation's arguments as a value, and a block is never held in one
       help: write a handler `over Tally`
    |}]

let%expect_test "[s5 reject] over any comparing a result that has no ==" =
  (* the arm's `==` on what `call.forward()` gives is checked against
     each operation's result where it's installed (found in the stage-10d
     review: the interpreter compared two descriptions and stopped) *)
  check_error
    {|
dep Op =
  run: fn(x: Int) -> Int

handler o_add(k: Int) for Op =
  run(x) => x + k

dep Maker =
  make: fn() -> Op

handler mk() for Maker =
  make() => o_add(1)

handler same() over any uses Console =
  call =>
    let r = call.forward()
    print(r == r)
    r

fn main() uses Console =
  with same() over mk() in
    print(Maker.make().run(1))
|};
  [%expect {|
    error: `same()` compares what `call.forward()` gives, and `Maker.make`'s result can't be
       ┌─ test.ren:20:8
    20 │   with same() over mk() in
       │        ^^^^^^
       = `Maker.make` gives `Op`, which has no `==`
       help: show it instead, `show(r)`
    |}]

let%expect_test "[s5 reject] over any comparing over a generic dependency" =
  (* not built: the function made for `Box` would need `==` of its `T`
     (found in the stage-10d review: lowering stopped) *)
  check_error
    {|
dep Box<T> =
  get: fn() -> T

handler cell<T>(v: T) for Box<T> =
  get() => v

handler same() over any uses Console =
  call =>
    let r = call.forward()
    print(r == r)
    r

fn main() uses Console =
  with same() over cell(1) in
    let v: Int = Box.get()
    print(v)
|};
  [%expect {|
    error: `same()` compares what `Box`'s operations take or give
       ┌─ test.ren:14:8
    14 │   with same() over cell(1) in
       │        ^^^^^^
       = a handler `over any` that compares `call.args` or what `call.forward()` gives isn't built yet over a generic dependency
       help: show them instead, `show(call.args)`, or write a handler `over Box`
    |}]

let%expect_test "[s5 reject] call.forward() at most once" =
  check_error
    {|
handler twice() over any =
  call =>
    let _ = attempt call.forward()
    try call.forward()

fn main() = 1
|};
  [%expect {|
    error: `call.forward()` runs the operation under this one, so it's called once at most
      ┌─ test.ren:4:9
    4 │     try call.forward()
      │         ^^^^^^^^^^^^^^
      help: keep what it gave: `let r = attempt call.forward()`, and `try r` where it's needed
    |}]

let%expect_test "[s5 reject] call is only used through" =
  (* as `next` is: it can't be kept, passed or returned, and a block
     can't call `call.forward()`, since that would be a second way to
     call it twice *)
  check_error
    {|
handler kept() over any =
  call =>
    let c = call
    try c.forward()

fn main() = 1
|};
  [%expect {|
    error: `call` can only be used through
      ┌─ test.ren:3:13
    3 │     let c = call
      │             ^^^^
      = `call` is the operation this arm runs for, while it runs, and it can't be kept
      help: use `call.forward()`, `call.fail(e)`, `call.name` or `call.args` where they're needed
    |}]

let%expect_test "[s5 reject] call.args can't be taken apart" =
  check_error
    {|
handler peek() over any =
  call =>
    let (a, b) = call.args
    try call.forward()

fn main() = 1
|};
  [%expect {|
    error: `call.args` can only be shown, compared and recorded
      ┌─ test.ren:3:9
    3 │     let (a, b) = call.args
      │         ^^^^^^
      = the arm runs for every operation of whatever it's installed over, so it's the same arm whatever its arguments and result are
      help: write a handler `over` the dependency to read its arguments
    |}]

let%expect_test "[s5 reject] an over any handler is installed with over" =
  check_error
    {|
dep Users =
  get: fn(id: Int) -> Int

handler quiet() over any =
  call => try call.forward()

fn main() =
  with quiet() in
    let _ = Users.get(1)
    ()
|};
  [%expect {|
    error: `quiet()` goes over another implementation, so it's installed with `over`
      ┌─ test.ren:8:8
    8 │   with quiet() in
      │        ^^^^^^^
      = it goes over whatever it's installed over, and with nothing after `over`, that's nothing
      help: say what it goes over: `quiet() over Users` for the one installed outside this `with`, or another implementation after `over`
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
|});
  [%expect {|
    Ok(42)
    Err(Flaky)
    Err(Broken)
    Err(Flaky)
    Err(Broken)
    1
    Ok(42)
    ()
    |}]

let%expect_test "[s5 accept] a function of your own that takes Tags" =
  (* `on` is matched with `fail on`, and passed on with `on: on`; a
     `match` that handles it is a `try match`, since which errors it
     names isn't known where it's written *)
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
|});
  [%expect {|
    Ok(42)
    Err(Flaky)
    ()
    |}]

let%expect_test "[s5 reject] retry without on" =
  (* `retry(n)` retried any error; now it says which, and the help lists
     what the block can fail with *)
  check_error
        (source
       ^ {|
fn main() =
  with flaky(1) in
    let _ = attempt retry(3) fn() => try Source.get()
    ()
|});
  [%expect {|
    error: `retry` takes `on:`, the errors it tries again
       ┌─ test.ren:17:21
    17 │     let _ = attempt retry(3) fn() => try Source.get()
       │                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       help: name them: `retry(3, on: Broken | Flaky)`
    |}]

let%expect_test "[s5 reject] on names an error the block can't fail with" =
  check_error
        (source
       ^ {|
fn main() =
  with flaky(1) in
    let _ = attempt retry(3, on: Timeout) fn() => try Source.get()
    ()
|});
  [%expect {|
    error: `retry` is given `on: Timeout`, and the block can't fail with `Timeout`
       ┌─ test.ren:17:34
    17 │     let _ = attempt retry(3, on: Timeout) fn() => try Source.get()
       │                                  ^^^^^^^
       help: name what it can fail with: `Broken`, `Flaky`
    |}]

let%expect_test "[s5 reject] a Tags argument is written with its name" =
  check_error
        (source
       ^ {|
fn main() =
  with flaky(1) in
    let _ = attempt retry(3, Flaky) fn() => try Source.get()
    ()
|});
  [%expect {|
    error: `on`, the errors `retry` tries again, is written with its name
       ┌─ test.ren:17:30
    17 │     let _ = attempt retry(3, Flaky) fn() => try Source.get()
       │                              ^^^^^
       = a parameter of `Tags` is the only one passed by name
       help: write `on: Flaky`
    |}]

let%expect_test "[s5 reject] only a Tags parameter is passed by name" =
  check_error
        (source
       ^ {|
fn main() =
  with flaky(1) in
    let _ = attempt retry(n: 3, on: Flaky) fn() => try Source.get()
    ()
|});
  [%expect {|
    error: `n` isn't passed by name
       ┌─ test.ren:17:27
    17 │     let _ = attempt retry(n: 3, on: Flaky) fn() => try Source.get()
       │                           ^
       help: a name goes only before a parameter of `Tags`: write `3`
    |}]

let%expect_test "[s5 reject] Tags is only a function parameter's type" =
  (* a set of tags is given by name at a call, and never a value: a
     block's parameter, a field or a handler's parameter can't be one *)
  check_error
    (source
   ^ {|
fn each(f: fn(Int, Tags) -> Int) -> Int = 1

handler picky(on: Tags) over any =
  call => try call.forward()

fn main() = 1
|});
  [%expect {|
    error: `Tags` is only the type of a function's parameter
       ┌─ test.ren:15:20
    15 │ fn each(f: fn(Int, Tags) -> Int) -> Int = 1
       │                    ^^^^
       = it's a set of error tags, given by name where the function is called, `on: DbDown`, and never a value
       help: write it as the type of a named function's parameter

    error: `Tags` is only the type of a function's parameter
       ┌─ test.ren:17:19
    17 │ handler picky(on: Tags) over any =
       │                   ^^^^
       = it's a set of error tags, given by name where the function is called, `on: DbDown`, and never a value
       help: write it as the type of a named function's parameter
    |}]

let%expect_test "[s5 reject] fail on is an arm's whole pattern" =
  check_error
    (source
   ^ {|
fn twice<T>(on: Tags, body: fn() -> T ! Flaky | Broken) -> T ! Flaky | Broken =
  try match body()
    fail on | fail Broken => try body()
    v => v

fn main() = 1
|});
  [%expect {|
    error: `fail on` is an arm's whole pattern
       ┌─ test.ren:17:5
    17 │     fail on | fail Broken => try body()
       │     ^^^^^^^
       help: give it an arm of its own, `fail on => ...`, and the other errors theirs
    |}]

let%expect_test "[s5 accept] over any over a generic dependency, and types" =
  (* made for `Chan`, given `Chan`'s type argument at each `with`; `ren
     types` says `over any` *)
  let src =
    {|
dep Chan<T> =
  send: fn(x: T)
  count: fn() -> Int

handler mem_chan<T>() for Chan<T> =
  var n = 0
  send(x) => n += 1
  count() => n

handler logged() over any uses Console =
  call =>
    Console.write(call.name.concat(show(call.args)))
    try call.forward()

fn go<T>(x: T) uses Chan<T>, Console =
  Chan.send(x)
  print(Chan.count())

fn main() uses Console =
  with logged() over mem_chan() in
    go(5)
  with logged() over mem_chan() in
    go("a")
|}
  in
  types src;
  [%expect {|
    dep Chan<T>
      send: fn(T)
      count: fn() -> Int
    handler mem_chan<T>() for Chan<T>
    handler logged() over any uses Console
    fn go<T>(x: T) uses Console, Chan<T>
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Chan.send(5)
    Chan.count()
    1
    Chan.send("a")
    Chan.count()
    1
    ()
    |}]

(* ---- s6: blocks with `inout` parameters, and slices (decision 17) ---- *)

let%expect_test "[s6 accept] blocks that take inout parameters (M3)" =
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
|};
  [%expect {|
    (11, 0)
    [1, 20, 3]
    12
    15
    ()
    |}]

let%expect_test "[s6 accept] a function type writes an inout parameter &T" =
  types
    {|
fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int)) = try f(&a, &b)
fn main() = 1
|};
  [%expect {|
    fn both(inout a: Int, inout b: Int, f: fn(&Int, &Int))
    fn main() -> Int
    |}]

let%expect_test "[s6 reject] a block's inout parameter is written &x" =
  (* test_mut.ml's "blocks can't take inout parameters" becomes this *)
  check_error {|
fn main() =
  let f = fn(inout n) => n += 1
  ()
|};
  [%expect {|
    error: a block's parameter that it changes is written `&n`
      ┌─ test.ren:2:20
    2 │   let f = fn(inout n) => n += 1
      │                    ^
      help: write `fn(&n) => ...`
    |}]

let%expect_test "[s6 reject] a block can't read what the call it's given to changes" =
  (* exclusivity, unchanged: the receiver `&xs` is a write of `xs` for
     the call, and the block reads it *)
  check_error
    {|
fn main() =
  var xs = [1, 2, 3, 4]
  &xs.split_at(2) fn(&lo, &hi) => lo[0] = xs[3]
|};
  [%expect {|
    error: `xs` is read by this block while the call changes it
      ┌─ test.ren:3:43
    3 │   &xs.split_at(2) fn(&lo, &hi) => lo[0] = xs[3]
      │                                           ^^^^^ read here
      │    -- changed for the whole call
      = a block runs during the call it's passed to
      help: read it first: `let item = xs[3]`, and use `item` in the block
    |}]

let%expect_test "[s6 accept] slices are values of the type they slice (M6)" =
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
|};
  [%expect {|
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
    |}]

let%expect_test "[s6 accept] & on a range changes that range" =
  (* as `&xs[i]` changes an element: what the call leaves in its
     parameter replaces the range, so a longer one moves what follows *)
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
|};
  [%expect {|
    [1, 4, 6, 4, 5]
    [1, 4, 0, 6, 4, 5]
    [1, 4, 0, 106, 104, 105]
    ()
    |}]

let%expect_test "[s6 accept] split_at gives a block two places of its own" =
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
|};
  [%expect {|
    [6, 8, 10, 12, 100, 6, 7, 8]
    6
    [6, 8, 0, 10, 12, 100, 6, 7, 8]
    ()
    |}]

let%expect_test "[s6 accept] Str and Bytes slices" =
  (* a `Str`'s offsets are bytes, as `len` counts them; `split` and `trim`
     give slices of what they're given *)
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
|};
  [%expect {|
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
    |}]

let%expect_test "[s6 reject] slices that panic" =
  run
    {|
fn main() uses Console =
  let xs = [1, 2, 3]
  let n = 5
  print(xs[2..n])
|};
  [%expect {|
    error: panic: slice 2 to 5 is out of bounds for an array of length 3
      ┌─ test.ren:4:9
    4 │   print(xs[2..n])
      │         ^^^^^^^^
    |}];
  run
    {|
fn main() uses Console =
  let xs = [1, 2, 3]
  let a = 3
  print(xs[a..1])
|};
  [%expect {|
    error: panic: slice 3 to 1 ends before it starts
      ┌─ test.ren:4:9
    4 │   print(xs[a..1])
      │         ^^^^^^^^
    |}];
  run
    {|
fn main() uses Console =
  let s = "héllo"
  print(s[0..2])
|};
  [%expect {|
    error: panic: slice 0 to 2 ends inside a character
      ┌─ test.ren:3:9
    3 │   print(s[0..2])
      │         ^^^^^^^
    |}];
  run
    {|
fn main() uses Console =
  var xs = [1, 2, 3]
  &xs.split_at(5) fn(&lo, &hi) => lo[0] = 0
  print(xs)
|};
  [%expect {|
    error: panic: `split_at` 5 is out of bounds for an array of length 3
      ┌─ test.ren:3:4
    3 │   &xs.split_at(5) fn(&lo, &hi) => lo[0] = 0
      │    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s6 reject] two ranges of one array in one call" =
  (* two ranges may overlap, as two indices may, so no rule changes; the
     help says how to change both *)
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
|};
  [%expect {|
    error: `xs` is passed with `&` twice in this call
       ┌─ test.ren:10:19
    10 │   both(&xs[0..2], &xs[2..4])
       │                   ^^^^^^^^^
       │        --------- passed with `&` here
       = an argument passed with `&` has to be the only way the call can reach that value
       = `xs[0..2]` and `xs[2..4]` may overlap
       help: to change two parts of one array, split it: `&xs.split_at(2) fn(&lo, &hi) => ...`
    |}]

let%expect_test "[s6 reject] Str.slice is a slice now" =
  check_error
    {|
fn main() uses Console =
  let s = "hello"
  print(s.slice(0, 2))
|};
  [%expect {|
    error: `Str` has no method named `slice`
      ┌─ test.ren:3:11
    3 │   print(s.slice(0, 2))
      │           ^^^^^
      help: slice it: `s[0..2]`
    |}]

let%expect_test "[s6 reject] a range is a value only in a for and an index" =
  (* test_collections.ml's range test changes its help to this *)
  check_error {|
fn main() =
  let r = 0..3
  ()
|};
  [%expect {|
    error: a range, `a..b`, is written only after a `for`'s `in`, or in an index: it isn't a value
      ┌─ test.ren:2:12
    2 │   let r = 0..3
      │            ^^
      help: a range is for counting, `for i in 0..n`, and for slicing, `xs[a..b]`
    |}]
