(* The services stage, step 6 (compiler.md, "Services stage", "`D.Call`"
   and "Stripes"): a call as a typed value, `D.Call`, which the compiler
   writes for each dependency whose operations are all data, and the
   `call` clause a handler writes beside its operations. test_services.ml
   is the stage's specification; these are what step 6 found besides. *)

open Helpers

let seen =
  {|
dep Seen =
  see: fn(path: Str)
  all: fn() -> Array<Str>
  count: fn() -> Int
|}

let%expect_test "a call is a value: built, matched, compared and shown" =
  run
    (seen
   ^ {|
fn main() uses Console =
  let c = Seen.Call.See { path: "/a" }
  let d: Seen.Call = Seen.Call.All
  print(c)
  print(d)
  print(c == d)
  print(c == Seen.Call.See { path: "/a" })
  match c
    See { path } => print(path)
    All | Count => print("none")
|});
  [%expect {|
    See { path: "/a" }
    All
    false
    true
    /a
    ()
    |}]

let%expect_test "a `call` clause runs for each operation the handler doesn't write" =
  run
    (seen
   ^ {|
handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  call(c) =>
    match c
      All => paths
      Count => paths.len()
      See { .. } => ()

fn main() uses Console =
  with seen() in
    Seen.see("/a")
    Seen.see("/b")
    print(Seen.all())
    print(Seen.count())
|});
  [%expect {|
    ["/a", "/b"]
    2
    ()
    |}]

let hits =
  {|
dep Hits =
  hit: fn(path: Str)
  total: fn() -> Int

handler counter() for Hits =
  var n = 0
  hit(_) => n += 1
  total() => n
|}

let%expect_test "a handler `for D`, over a family of one instance, made for the dependency it's given" =
  run
    (hits
   ^ {|
handler one<D>(h: D) for D uses Async =
  let fam = Instances.open(fn(i: Int) => h, 1, 1, 1)
  finally(r) =>
    Instances.close(fam)
    try r
  call(c) => try Instances.call(fam, 0, c)

fn main() uses Console, Async =
  with one(counter()) in
    Hits.hit("/a")
    Hits.hit("/b")
    print(Hits.total())
|});
  [%expect {|
    2
    ()
    |}]

let%expect_test "a handler `for D`'s signature" =
  types
    (hits
   ^ {|
pub handler one<D>(h: D) for D uses Async =
  let fam = Instances.open(fn(i: Int) => h, 1, 1, 1)
  call(c) => try Instances.call(fam, 0, c)

fn main() = ()
|});
  [%expect {|
    dep Hits
      hit: fn(Str)
      total: fn() -> Int
    handler counter() for Hits
    pub handler one<D>(h: D) for D uses Async
    fn main()
    |}]

let%expect_test "a merge's `call` clause folds two results of a call, refined to its case's in each arm" =
  (* a library over the family, of two instances, which folds what a call
     with no argument gives with `c.fold(m, a, b)`: `striped`'s `Custom` *)
  run
    (seen
   ^ {|
handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  all() => paths
  count() => paths.len()

handler longest() for Seen =
  call(c: Seen.Call, a, b) =>
    match c
      All => if a.len() >= b.len() then a else b
      Count => a + b
      See { .. } => a

handler both<D>(h: D, m: D) for D uses Async =
  let fam = Instances.open(fn(i: Int) => h, 1, 2, 1)
  finally(r) =>
    Instances.close(fam)
    try r
  call(c) =>
    match c.first_hash()
      Some(x) => try Instances.call(fam, if x % 2 == 0 then 0 else 1, c)
      None => c.fold(m, try Instances.call(fam, 0, c), try Instances.call(fam, 1, c))

fn main() uses Console, Async =
  with both(seen(), longest()) in
    Seen.see("/a")
    Seen.see("/b")
    Seen.see("/c")
    print(Seen.all())
    print(Seen.count())
|});
  [%expect {|
    ["/a", "/c"]
    3
    ()
    |}]

let%expect_test "`Async.worker()`: 0 under `single`" =
  run {|
fn main() uses Console, Async =
  print(Async.worker())
  Async.scope fn(s) =>
    s.spawn(fn() => print(Async.worker()))
|};
  [%expect {|
    0
    0
    ()
    |}]

let%expect_test "`Async.worker()`: one of two virtual workers under `sim`, the same for a task each time" =
  test ~seeds:50
    {|
test "a worker is 0 or 1, and stays" =
  Async.scope fn(s) =>
    for _ in 0..4
      s.spawn fn() =>
        let w = Async.worker()
        assert w == 0 || w == 1
        Async.yield()
        assert Async.worker() == w
|};
  [%expect {|
    test.ren
      ✓ a worker is 0 or 1, and stays

    1 passed, each under 50 seeds
    [exit 0]
    |}]

let%expect_test "a call built with its case's name, after `D.Call`" =
  run
    {|
dep Doc =
  edit: fn(op: Str, at: Int) -> Int
  join: fn(c: Int)

fn main() uses Console =
  let c = Doc.Call.Edit { op: "a", at: 2 }
  match c
    Doc.Call.Edit { op, at } => print(op + show(at))
    Doc.Call.Join { .. } => print("join")
|};
  [%expect {|
    a2
    ()
    |}]

let%expect_test "[reject] `D.Call` of a dependency whose operations aren't all data" =
  check_error
    {|
dep Docs =
  edit: fn(op: Str)
  each: fn(body: fn())

fn f(c: Docs.Call) = ()

fn main() = ()
|};
  [%expect {|
    error: `Docs.Call` needs every operation of `Docs` to be data, and `each` takes a block
      ┌─ test.ren:5:9
    5 │ fn f(c: Docs.Call) = ()
      │         ^^^^^^^^^
      help: a call is a value only where every argument and result is data: no block, and no argument the operation changes
    |}]

let%expect_test "[reject] a `call` clause that fails with what its call can't" =
  check_error
    (seen
   ^ {|
handler seen() for Seen =
  see(p) => ()
  call(c) => fail Oops

fn main() = ()
|});
  [%expect {|
    error: the `call` clause can fail with `Oops`, which its call can't
      ┌─ test.ren:8:3
    8 │   call(c) => fail Oops
      │   ^^^^^^^^^^^^^^^^^^^^
      = it runs for each operation it isn't written for, and fails with at most what that one can
      help: handle it inside the clause
    |}]

let%expect_test "[reject] a handler's state that keeps a call's result" =
  check_error
    (seen
   ^ {|
handler last() for Seen =
  var kept = None
  see(p) => ()
  call(c) =>
    match c
      All =>
        let r: Array<Str> = []
        r
      Count => 0
      See { .. } => ()

handler keeps<D>(h: D) for D uses Async =
  var kept = None
  let fam = Instances.open(fn(i: Int) => h, 1, 1, 1)
  call(c) =>
    let r = try Instances.call(fam, 0, c)
    kept = Some(r)
    r

fn main() = ()
|});
  [%expect {|
    error: `kept` keeps the result of a call, which only lasts the call
       ┌─ test.ren:18:7
    18 │   var kept = None
       │       ^^^^
       = the `call` clause runs for each operation, whose result is a type of its own, and the state is shared by them all
       help: keep something derived from it instead, `show(...)` of it
    |}]

let%expect_test "[reject] a handler `for D` writes one arm, its `call` clause" =
  check_error
    (seen
   ^ {|
handler one<D>(h: D) for D =
  see(p) => ()
  call(c) => todo

fn main() = ()
|});
  [%expect {|
    error: `one` is a handler for `D`, so its one arm is `call(c) => ...`
      ┌─ test.ren:7:3
    7 │   see(p) => ()
      │   ^^^
      = it implements whatever dependency `D` is, whose operations aren't known here
      help: write one arm, its `call` clause: `call(c) => ...`
    |}]

let%expect_test "[reject] a handler `for D` given what isn't a dependency whose operations are data" =
  check_error
    {|
dep Docs =
  each: fn(body: fn())

handler docs() for Docs =
  each(body) => body()

handler one<D>(h: D) for D uses Async =
  let fam = Instances.open(fn(i: Int) => h, 1, 1, 1)
  call(c) => try Instances.call(fam, 0, c)

fn main() uses Async =
  with one(docs()) in Docs.each(fn() => ())
|};
  [%expect {|
    error: `Docs.Call` needs every operation of `Docs` to be data
       ┌─ test.ren:12:12
    12 │   with one(docs()) in Docs.each(fn() => ())
       │            ^^^^^^
       help: a call is a value only where every argument and result is data: no block, and no argument the operation changes
    |}]

let%expect_test "[reject] the keyed instance family's intrinsics are `Instances`'" =
  check_error
    {|
fn main() uses Console =
  print(family_keys(1))
|};
  [%expect {|
    error: there's no function named `family_keys`
      ┌─ test.ren:2:9
    2 │   print(family_keys(1))
      │         ^^^^^^^^^^^
    |}]

(* ---- step 6b: `striped`, plain Ren in the prelude over the family ---- *)

let%expect_test "language.md §11's `striped` lines, as written" =
  (* stand-ins for what §11 leaves out: `serve`, `sessions`, `books` and
     their merge, a `Table` an `Array`; and `expire` takes no `now`, since
     an operation with a first parameter goes to one stripe by it
     (compiler.md, "Where this stage may differ") *)
  run
    {|
dep Hits =
  hit: fn(path: Path)
  total: fn() -> Int

handler counter() for Hits =
  var n = 0
  hit(_) => n += 1
  total() => n

dep Sessions =
  touch: fn(id: Int, now: Int)
  expire: fn() -> Array<Int>

type Session = { id: Int, last_seen: Int }

handler mem_sessions(ttl: Int) for Sessions =
  var all: Array<Session> = []
  touch(id, now) => &all.push(Session { id: id, last_seen: now })
  expire() =>                                 // sweeps one column, `last_seen`
    all.select(fn(s) => s.last_seen < ttl).map(fn(s) => s.id)

dep Books =
  put: fn(id: Int, price: Int)
  best: fn() -> Int

handler books() for Books =
  var best = 0
  put(_, price) => if price > best then best = price
  best() => best

// the rare kind the menu lacks: the larger, as `Max` would, written out
handler book_merge() for Books =
  call(c: Books.Call, a, b) =>
    match c
      Best => if a > b then a else b
      Put { .. } => a

fn serve() uses Hits, Console =
  for p in ["/a", "/b", "/c"]
    Hits.hit(Path.of(p))
  print(Hits.total())

fn main() uses Console, Async =
  with striped(counter(), by: Worker, merge: Sum) in serve()
  let ttl = 35
  with striped(mem_sessions(ttl), merge: Concat) in
    for id in 0..5
      Sessions.touch(id, id * 10)
    print(Sessions.expire().sort())
  with striped(books(), by: Key(n: 64), merge: Custom(book_merge())) in
    for id in 0..20
      Books.put(id, (id * 7) % 23)
    print(Books.best())
|};
  [%expect {|
    3
    [0, 1, 2, 3]
    22
    ()
    |}]

let%expect_test "a keyless call runs on every stripe, folded left to right in stripe order" =
  run
    {|
dep Log =
  put: fn(key: Int, s: Str)
  all: fn() -> Str
  firsts: fn() -> Array<Str>

handler log() for Log =
  var s = ""
  var first: Array<Str> = []
  put(_, x) =>
    s = s + x
    if first.len() == 0 then &first.push(x)
  all() => s
  firsts() => first

// the earlier stripe's, so the fold's order shows
handler earlier() for Log =
  call(c, a, b) => a

fn main() uses Console, Async =
  with striped(log(), by: Key(n: 3), merge: Concat) in
    for i in 0..9
      Log.put(i, show(i))
    print(Log.all())
    print(Log.firsts())
  with striped(log(), by: Key(n: 3), merge: Custom(earlier())) in
    for i in 0..9
      Log.put(i, show(i))
    print(Log.firsts())
  // under `single`, one worker, so one stripe
  with striped(log(), by: Worker, merge: Concat) in
    for i in 0..4
      Log.put(i, show(i))
    print(Log.all())
|};
  [%expect {|
    127805634
    ["1", "0", "3"]
    ["1"]
    0123
    ()
    |}]
