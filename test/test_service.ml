(* The services stage, step 2b: a service, a dependency and its one
   implementation written once (language.md §4, "A service"; compiler.md,
   "Services stage", "Step 2b: service"). Its tests are here rather than
   in test_services.ml, the stage's specification, since step 2b was
   decided after it was written, and new tests go in new files while
   another step changes that one.

   Each test's name starts with `[s2b accept]` or `[s2b reject]`, as the
   stage's do. A program run with [run] is `ren run`'s, and one run with
   [test] is `ren test`'s. *)

open Helpers

(* The service of language.md §4 in miniature: a parameter its members
   share, a private member they call, `uses` written once. *)
let kv =
  {|
type Cfg = { base: Str, tries: Int }

service Kv(c: Cfg) uses Console =
  pub fn get(k: Str) -> Str ! Missing =
    note("get " + k)
    if k == "" then fail Missing
    c.base + "/" + k
  pub fn tries() -> Int = c.tries
  fn note(s: Str) = print("[" + c.base + "] " + s)
|}

let%expect_test "[s2b accept] a service is installed with its arguments, and called by its name" =
  (* callers see only `Kv`: `sync_all` writes no `uses`, and what `Kv`
     needs, `Console`, is required where it's installed *)
  run
    (kv
   ^ {|
fn sync_all(keys: Array<Str>) =
  for k in keys
    print(attempt Kv.get(k))

fn main() uses Console =
  with Kv(Cfg { base: "kv", tries: 3 }) in
    sync_all(["a", ""])
    print(Kv.tries())
|});
  [%expect {|
    [kv] get a
    Ok("kv/a")
    [kv] get
    Err(Missing)
    3
    ()
    |}]

let%expect_test "[s2b accept] a service is exactly a `dep` and a handler" =
  (* `ren types`: the dependency and the handler, named as the service
     is; its members are the handler's, as a wiring's link functions are
     the wiring's *)
  types (kv ^ {|
fn main() uses Console =
  with Kv(Cfg { base: "kv", tries: 3 }) in print(Kv.tries())
|});
  [%expect {|
    dep Kv
      get: fn(Str) -> Str ! Missing
      tries: fn() -> Int
    handler Kv(c: Cfg) for Kv uses Console
    fn main() uses Console
    |}]

let%expect_test "[s2b accept] members call each other directly, in any order, recursively, and as a chain's steps" =
  run
    {|
service Text(fill: Str) =
  pub fn padded(s: Str, n: Int) -> Str = s |> pad(n) |> close
  fn pad(s: Str, n: Int) -> Str = if n == 0 then s else pad(s + fill, n - 1)
  fn close(s: Str) -> Str = "[" + s + "]"

fn main() =
  with Text(".") in Text.padded("a", 3)
|};
  [%expect {| "[a...]" |}]

let%expect_test "[s2b accept] a private service's needs are inferred, and required where it's installed" =
  check_error
    (kv
   ^ {|
pub fn lookup() -> Int =
  with Kv(Cfg { base: "kv", tries: 3 }) in Kv.tries()

pub fn main() -> Int uses Console = lookup()
|});
  [%expect {|
    error: `lookup` doesn't declare `Console`
       ┌─ test.ren:11:8
    11 │ pub fn lookup() -> Int =
       │        ^^^^^^
    12 │   with Kv(Cfg { base: "kv", tries: 3 }) in Kv.tries()
       │        -------------------------------- installing this needs `Console`
       = a public function without `uses` uses nothing, and its body is checked against that
       help: add `uses Console`
    |}]

let%expect_test "[s2b accept] a test handler replaces a service" =
  (* language.md §4, rule 5: it's still a dependency, so any handler of
     `Kv` replaces it; a test sees what an importer sees, so it's `pub` *)
  test
    {|
pub type Cfg = { base: Str }

pub service Kv(c: Cfg) uses Console =
  pub fn get(k: Str) -> Str =
    print("real " + k)
    c.base + k

pub fn greet(k: Str) -> Str uses Kv = "hi " + Kv.get(k)

test handler fake_kv() for Kv =
  get(k) => "fake " + k

test "the real one" =
  with Kv(Cfg { base: "kv/" }) in assert greet("a") == "hi kv/a"

test "a test handler in its place" =
  with fake_kv() in assert greet("a") == "hi fake a"
|};
  [%expect {|
    test.ren
      ✓ the real one
      ✓ a test handler in its place

    2 passed
    [exit 0]
    |}]

let%expect_test "[s2b accept] a service in a wiring, with what it needs beside it" =
  run
    {|
dep Store =
  read: fn(k: Str) -> Str

handler mem_store() for Store =
  read(k) => "stored " + k

service Kv(prefix: Str) uses Store =
  pub fn get(k: Str) -> Str = Store.read(prefix + k)

wiring live(prefix: Str) provides Kv = Kv(prefix), mem_store()

fn main() =
  with live("kv/") in Kv.get("a")
|};
  [%expect {| "stored kv/a" |}]

let%expect_test "[s2b accept] another module's service, installed as `kv.Kv(...)` or imported by name" =
  run_files
    [
      ( "main.ren",
        {|
import kv.{Kv}

wiring live provides Kv uses Console = kv.Kv(kv.Cfg { base: "w" })

fn main() uses Console =
  with kv.Kv(kv.Cfg { base: "q" }) in print(Kv.get("a"))
  with Kv(kv.Cfg { base: "r" }) in print(Kv.get("b"))
  with live in print(Kv.get("c"))
|} );
      ( "kv.ren",
        {|
pub type Cfg = { base: Str }

pub service Kv(c: Cfg) uses Console =
  pub fn get(k: Str) -> Str =
    log(k)
    c.base + k
  fn log(k: Str) = print("get " + k)
|} );
    ];
  [%expect {|
    get a
    qa
    get b
    rb
    get c
    wc
    ()
    |}]

let%expect_test "[s2b accept] a signature's `uses` is a bound: listing what the body doesn't use is accepted" =
  (* language.md §4, "Two rules": `uses` is the most a function may use;
     its errors are exact *)
  run
    {|
pub fn hello() uses Console, Clock, Random = print("hello")

pub fn main() uses Console, Clock, Random = hello()
|};
  [%expect {|
    hello
    ()
    |}]

let%expect_test "[s2b reject] a member that writes `uses`" =
  check_error
    {|
service Kv(base: Str) uses Clock =
  pub fn get(k: Str) -> Str uses Console =
    print(k)
    base

fn main() = 1
|};
  [%expect {|
    error: `get` shares `Kv`'s `uses`, so it doesn't write its own
      ┌─ test.ren:2:29
    2 │   pub fn get(k: Str) -> Str uses Console =
      │                             ^^^^^^^^^^^^
      = what its functions need is required where `Kv` is installed, so it's written once, on `Kv`
      help: move it to the service's: `service Kv(...) uses Clock, Console`
    |}]

let%expect_test "[s2b reject] a service used as a value" =
  check_error
    {|
service Kv(base: Str) =
  pub fn get(k: Str) -> Str = base + k

fn main() =
  let d = Kv
  1
|};
  [%expect {|
    error: a service isn't a value
      ┌─ test.ren:5:11
    5 │   let d = Kv
      │           ^^
      help: install it, `with Kv(...) in ...`, and call its operations: `Kv.op(...)`
    |}]

let%expect_test "[s2b reject] `S(...)` outside a `with` or a wiring" =
  check_error
    {|
service Kv(base: Str) =
  pub fn get(k: Str) -> Str = base + k

fn main() =
  let d = Kv("x")
  1
|};
  [%expect {|
    error: `Kv(...)` installs a service, so it's written in a `with` or a wiring
      ┌─ test.ren:5:11
    5 │   let d = Kv("x")
      │           ^^^^^^^
      = a `with` item is never a value, so `Kv(...)` there can't be read as a constructor
      help: install it where it's used: `with Kv(...) in ...`
    |}]

let%expect_test "[s2b reject] another module's `kv.Kv(...)` outside a `with`" =
  check_error_files
    [
      ( "main.ren",
        {|
import kv

fn main() =
  let d = kv.Kv("x")
  1
|} );
      ( "kv.ren",
        {|
pub service Kv(base: Str) =
  pub fn get(k: Str) -> Str = base + k
|} );
    ];
  [%expect {|
    error: `kv.Kv(...)` installs a service, so it's written in a `with` or a wiring
      ┌─ main.ren:4:11
    4 │   let d = kv.Kv("x")
      │           ^^^^^
      = a `with` item is never a value, so `kv.Kv(...)` there can't be read as a constructor
      help: install it where it's used: `with kv.Kv(...) in ...`
    |}]

let%expect_test "[s2b reject] a member that calls another through the service's name" =
  check_error
    {|
service Kv(base: Str) =
  pub fn get(k: Str) -> Str = base + k
  pub fn twice(k: Str) -> Str = Kv.get(k) + get(k)

fn main() = 1
|};
  [%expect {|
    error: a function of `Kv` calls another directly
      ┌─ test.ren:3:33
    3 │   pub fn twice(k: Str) -> Str = Kv.get(k) + get(k)
      │                                 ^^^^^^
      = `Kv.get` calls the `Kv` installed where the call is, which isn't this one
      help: call it directly: `get(...)`
    |}]

let%expect_test "[s2b reject] a member passed as a value" =
  check_error
    {|
service Kv(base: Str) =
  pub fn get(k: Str) -> Str = base + k
  pub fn all(ks: Array<Str>) -> Array<Str> = ks.map(get)

fn main() = 1
|};
  [%expect {|
    error: `get` is a function of `Kv`, so it's called, not passed
      ┌─ test.ren:3:53
    3 │   pub fn all(ks: Array<Str>) -> Array<Str> = ks.map(get)
      │                                                     ^^^
      help: call it in a block: `fn(...) => get(...)`
    |}]

let%expect_test "[s2b reject] a public service's member uses what the service doesn't declare" =
  check_error
    {|
pub service Kv(base: Str) uses Clock =
  pub fn get(k: Str) -> Str =
    print(k)
    base

pub fn main() = ()
|};
  [%expect {|
    error: `Kv.get` uses `Console`, which `Kv` doesn't declare
      ┌─ test.ren:2:10
    2 │   pub fn get(k: Str) -> Str =
      │          ^^^
    3 │     print(k)
      │     -------- this call uses `Console`
      = a service's functions share its `uses`, which is what a `with` that installs `Kv` needs
      help: add `Console` to `Kv`'s `uses`
    |}]

let%expect_test "[s2b reject] an operation's signature is written in full" =
  check_error
    {|
service Kv(base: Str) =
  pub fn get(k) -> Str = base

fn main() = 1
|};
  [%expect {|
    error: `get` is an operation of `Kv`, so its parameters have types
      ┌─ test.ren:2:14
    2 │   pub fn get(k) -> Str = base
      │              ^
      help: write its type: `k: T`
    |}]

let%expect_test "[s2b reject] a service with no `pub fn`" =
  check_error
    {|
service Kv(base: Str) =
  fn get(k: Str) -> Str = base

fn main() = 1
|};
  [%expect {|
    error: `Kv` has no operations: a service's operations are its `pub fn`s
      ┌─ test.ren:1:9
    1 │ service Kv(base: Str) =
      │         ^^
      help: mark the functions its callers call `pub fn`
    |}]

(* ---- step 2b (state): a service keeps state in `var`s, sets it up,
   and may fail to start ---- *)

let counter =
  {|
pub type Cfg = { start: Int }

pub service Counter(c: Cfg) uses Console ! Refused =
  var n: Int = c.start
  var log: Array<Str> = []
  let label: Str = try open(c.start)
  finally(r) =>
    print("closing " + label + " at " + show(n))
    try r
  pub fn next() -> Int = bump(1)
  pub fn add(k: Int) -> Int = bump(k)
  pub fn total() -> Int = n
  pub fn history() -> Array<Str> = log
  fn bump(k: Int) -> Int =
    n += 1
    &log.push(label + show(n))
    if k > 1 then bump(k - 1) else n

pub fn open(at: Int) -> Str ! Refused = if at < 0 then fail Refused else "c"
|}

let%expect_test "[s2b accept] a service keeps state in `var`s, which its functions read and write as they call each other" =
  (* `add(3)` is three calls of `bump`, recursively, each changing `n`
     and `log`, then `total()` reads them: one instance, kept by each
     operation until it returns *)
  run
    (counter
   ^ {|
pub fn main() ! Refused uses Console =
  try with Counter(Cfg { start: 10 }) in
    print(Counter.next())
    print(Counter.add(3))
    print(Counter.total())
    print(Counter.history())
|});
  [%expect {|
    11
    14
    14
    ["c11", "c12", "c13", "c14"]
    closing c at 14
    ()
    |}]

let%expect_test "[s2b accept] a service's setup fails with its `! E`, installed with `try with`" =
  run
    (counter
   ^ {|
pub fn main() uses Console =
  print(attempt (with Counter(Cfg { start: -1 }) in Counter.total()))
|});
  [%expect {|
    Err(Refused)
    ()
    |}]

let%expect_test "[s2b accept] a test handler still replaces a service that keeps state" =
  test
    (counter
   ^ {|
pub fn twice() -> Int uses Counter =
  let _ = Counter.next()
  Counter.next()

test handler fixed() for Counter =
  next() => 7
  add(k) => k
  total() => 0
  history() => []

test "the real one counts" =
  try with Counter(Cfg { start: 0 }) in assert twice() == 2

test "a test handler in its place" =
  with fixed() in assert twice() == 7
|});
  [%expect {|
    test.ren
      ✓ the real one counts
      ✓ a test handler in its place

    2 passed
    [exit 0]
    |}]

let%expect_test "[s2b accept] a block in a member calls another member with the state" =
  run
    {|
service Tally() =
  var n = 0
  var seen: Array<Str> = []
  pub fn add_all(ks: Array<Str>) -> Int =
    ks.each fn(k) => add(k)
    n
  pub fn names() -> Array<Str> = seen
  fn add(k: Str) =
    n += 1
    &seen.push(k)

fn main() =
  with Tally() in
    let a = Tally.add_all(["x", "y"])
    (a, Tally.names())
|};
  [%expect {| (2, ["x", "y"]) |}]

let%expect_test "[s2b reject] a service's state without its type" =
  check_error
    {|
service Kv(start: Int) =
  var n = start
  pub fn get() -> Int = n

fn main() = 1
|};
  [%expect {|
    error: `n` is `Kv`'s state, so its type is written
      ┌─ test.ren:2:7
    2 │   var n = start
      │       ^
      = each of `Kv`'s functions is given its state, as a parameter, and a parameter's type is written
      help: write it: `var n: T = ...`
    |}]

let%expect_test "[s2b reject] a service's state calling its functions" =
  check_error
    {|
service Kv() =
  let m: Int = start()
  pub fn get() -> Int = m
  fn start() -> Int = 1

fn main() = 1
|};
  [%expect {|
    error: `start` is a function of `Kv`, which its state can't call
      ┌─ test.ren:2:16
    2 │   let m: Int = start()
      │                ^^^^^
      = `Kv`'s functions are given its state, which is still being set up here
      help: set it up here, or with a function outside the service
    |}]

let%expect_test "[s2b reject] a service's state after its functions" =
  check_error
    {|
service Kv() =
  pub fn get() -> Int = 1
  var n = 0

fn main() = 1
|};
  [%expect {|
    error: a service's state comes first, before its functions
      ┌─ test.ren:3:3
    3 │   var n = 0
      │   ^^^
      help: move it above the service's first function
    |}]
