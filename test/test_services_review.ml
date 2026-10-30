(* The services stage, step 9: the soundness review (compiler.md,
   "Services stage", "Step 9, soundness"). Adversarial programs that
   found something, each fixed, as regressions: wirings, the keyed
   instance family's one instance per key, a family's handle kept in
   its handler, chaos at the family's edge, and what a native build
   says first. A program run with [run] is `ren run`'s, and one run with
   [test] is `ren test`'s. *)

open Ren
open Helpers

let users =
  {|
dep Db =
  get: fn(id: Int) -> Str
dep Audit =
  note: fn(s: Str)
dep Users =
  name: fn(id: Int) -> Str

handler mem_db() for Db =
  get(id) => "ann" + show(id)

handler console_audit() for Audit uses Console =
  note(s) => print("audit: " + s)

handler db_users() for Users uses Db, Audit =
  name(id) =>
    Audit.note(show(id))
    Db.get(id)
|}

let%expect_test "[s9 reject] a wiring listed twice installs each of its items twice" =
  (* it was taken for a problem among one wiring's items, reported at
     its own `with` and so nowhere, and lowering failed *)
  check_error
    (users
   ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with live, live in print(Users.name(1))
|});
  [%expect {|
    error: this `with` installs `Db` twice: `mem_db()` here, and `mem_db()` in `live` (test.ren:19)
       ┌─ test.ren:22:14
    22 │   with live, live in print(Users.name(1))
       │              ^^^^ and again here
       │        ---- `live` installs `Db` here
       = a wiring is flattened where it's listed: its items are the `with`'s
       help: use a smaller wiring that leaves `Db` out, or remove one

    error: this `with` installs `Audit` twice: `console_audit()` here, and `console_audit()` in `live` (test.ren:19)
       ┌─ test.ren:22:14
    22 │   with live, live in print(Users.name(1))
       │              ^^^^ and again here
       │        ---- `live` installs `Audit` here
       = a wiring is flattened where it's listed: its items are the `with`'s
       help: use a smaller wiring that leaves `Audit` out, or remove one

    error: this `with` installs `Users` twice: `db_users()` here, and `db_users()` in `live` (test.ren:19)
       ┌─ test.ren:22:14
    22 │   with live, live in print(Users.name(1))
       │              ^^^^ and again here
       │        ---- `live` installs `Users` here
       = a wiring is flattened where it's listed: its items are the `with`'s
       help: use a smaller wiring that leaves `Users` out, or remove one
    |}]

let%expect_test "[s9 reject] the body calls a function of its own recursive group that uses what the wiring hides" =
  (* `g`'s row isn't known where `f`'s body calls it: what it brings in
     is found once the group's bodies are checked *)
  check_error
    (users
   ^ {|
handler outer_db() for Db =
  get(id) => "outer" + show(id)

wiring live provides Users = mem_db(), console_audit(), db_users()

fn f(n: Int) -> Str =
  if n == 0 then "x" else
    with live in
      print(g(0))
      "y"

fn g(n: Int) -> Str = if n == 0 then Db.get(1) else f(n - 1)

fn main() uses Console =
  with outer_db(), console_audit() in print(f(2))
|});
  [%expect {|
    error: `live` installs `Db` but doesn't provide it
       ┌─ test.ren:27:13
    27 │       print(g(0))
       │             ^^^^
       = a wiring's items meet each other, but what's listed beside it and the body see only what its `provides` says
       help: add `Db` to `live`'s `provides`, or install your own inside: `with mem_db() in`
    |}]

let%expect_test "[s9 accept] the body calls a function of its own recursive group that doesn't" =
  run
    (users
   ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn f(n: Int) -> Str =
  if n == 0 then "x" else
    with live in
      print(g(0))
      print(Users.name(1))
      "y"

fn g(n: Int) -> Str = if n == 0 then "g" else f(n - 1)

fn main() uses Console =
  with mem_db(), console_audit(), db_users() in print(f(2))
|});
  [%expect {|
    g
    audit: 1
    ann1
    y
    ()
    |}]

let%expect_test "[s9 reject] a wiring's own errors are said as the wiring's, not its function's" =
  check_error
    {|
dep Db =
  get: fn() -> Int
handler mem_db() for Db =
  get() => 1
pub wiring live() provides Db ! DbDown = mem_db()

fn main() = 1
|};
  [%expect {|
    error: `wiring live` says it can fail with `DbDown`, but nothing in it can
      ┌─ test.ren:5:33
    5 │ pub wiring live() provides Db ! DbDown = mem_db()
      │                                 ^^^^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `DbDown` from after `!`
    |}]

(* ---- the keyed instance family: one instance per key ---- *)

let%expect_test "[s9 accept] a key whose `finally` is running is made again only once it's over" =
  (* 1 is evicted to make room for 2 and its `finally` waits; a post to
     1 and an `at` of 1 meanwhile wait for it, rather than make a second
     life of 1 beside the first, whose setup would read what the first's
     `finally` is still writing *)
  run
    {|
import sim

type DocId = | DocId(n: Int)

dep Doc =
  poke: fn(s: Str)
  get: fn() -> Str

handler doc(id: DocId) for Doc uses Console, Clock =
  let DocId(k) = id
  let _ = print("making " + show(k))
  let _ = Clock.sleep(Duration.ms(20))
  let _ = print("made " + show(k))
  var log = ""
  finally(r) =>
    print("finally " + show(k) + " start, log " + log)
    Clock.sleep(Duration.ms(30))
    print("finally " + show(k) + " end")
    try r
  poke(s) =>
    log = log + s
  get() => log

dep Docs = Actors<DocId, Doc>

fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), actors(doc, max: 1) as Docs in
      Async.scope fn(s) =>
        s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.poke("a")
        s.spawn fn() =>
          Clock.sleep(Duration.ms(5))
          Docs.at(DocId(2)) fn() => Doc.poke("b")
        s.spawn fn() =>
          Clock.sleep(Duration.ms(25))
          Docs.post(DocId(1), Doc.Call.Poke { s: "p" })
        s.spawn fn() =>
          Clock.sleep(Duration.ms(26))
          print("at 1: " + Docs.at(DocId(1)) fn() => Doc.get())
      print("count " + show(Docs.count()) + " made " + show(Docs.made()))
|};
  [%expect {|
    making 1
    made 1
    finally 1 start, log a
    finally 1 end
    making 2
    making 1
    made 1
    made 2
    at 1:
    count 2 made 3
    finally 1 start, log p
    finally 1 end
    finally 2 start, log b
    finally 2 end
    ()
    |}]

let%expect_test "[s9 reject] an instance's `finally` that posts to its own key panics, not hangs" =
  run_error
    {|
type DocId = | DocId(n: Int)

dep Doc =
  poke: fn()

handler doc(id: DocId) for Doc uses Console, Docs =
  finally(r) =>
    print("finally " + show(id))
    Docs.post(id, Doc.Call.Poke)
    try r
  poke() => print("poked " + show(id))

dep Docs = Actors<DocId, Doc>

fn main() uses Console, Random =
  with actors(doc, max: 1) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.at(DocId(2)) fn() => Doc.poke()
|};
  [%expect {|
    poked DocId(1)
    finally DocId(1)
    error: panic: `docs[DocId(1)]#1`'s `finally` asks for the instance it ends, which is made again only once it's over
      ┌─ test.ren:9:5
    9 │     Docs.post(id, Doc.Call.Poke)
      │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

(* ---- a family's handle stays in the handler that opened it ---- *)

let shard =
  {|
type Shard = | A | B

dep Count =
  add: fn(n: Int)

handler count(s: Shard) for Count =
  add(k) => ()
|}

let%expect_test "[s9 reject] an operation that gives a family's handle" =
  (* given out, a function with no `uses` could evict through it, running
     an instance's `finally` *)
  check_error
    (shard
   ^ {|
dep Shards =
  handle: fn() -> Family<Shard, Count>

handler shards() for Shards =
  let fam = Instances.open(count, 1, 2, 16)
  finally(r) =>
    Instances.close(fam)
    try r
  handle() => fam
|});
  [%expect {|
    error: a dependency's operation can't take or give a family's handle
       ┌─ test.ren:10:19
    10 │   handle: fn() -> Family<Shard, Count>
       │                   ^^^^^^ a family's handle
       = a family's handle is good only in the state of the handler that opened it: its waits and its instances' `finally`s are that handler's operations'
       help: keep it in the handler's state, and give what its instances give instead
    |}]

let%expect_test "[s9 reject] a family's handle as a dependency's type argument, or a handler's parameter" =
  check_error
    ("import sync\n" ^ shard
   ^ {|
dep Fams = sync.Chan<Option<Family<Shard, Count>>>

handler keeper(f: Family<Shard, Count>) for Count =
  add(k) => ()

fn send(f: Family<Shard, Count>) uses sync.Chan<Family<Shard, Count>> = ()
|});
  [%expect {|
    error: a dependency's type argument can't be a family's handle
       ┌─ test.ren:11:29
    11 │ dep Fams = sync.Chan<Option<Family<Shard, Count>>>
       │                             ^^^^^^ a family's handle
       = a family's handle is good only in the state of the handler that opened it: its waits and its instances' `finally`s are that handler's operations'
       help: keep it in the handler's state, and give what its instances give instead

    error: a handler's parameters are data, and a family's handle isn't
       ┌─ test.ren:13:19
    13 │ handler keeper(f: Family<Shard, Count>) for Count =
       │                   ^^^^^^ a family's handle
       = a family's handle is good only in the state of the handler that opened it: its waits and its instances' `finally`s are that handler's operations'
       help: keep it in the handler's state, and give what its instances give instead

    error: a dependency's type argument can't be a family's handle
       ┌─ test.ren:16:49
    16 │ fn send(f: Family<Shard, Count>) uses sync.Chan<Family<Shard, Count>> = ()
       │                                                 ^^^^^^ a family's handle
       = a family's handle is good only in the state of the handler that opened it: its waits and its instances' `finally`s are that handler's operations'
       help: keep it in the handler's state, and give what its instances give instead
    |}]

(* ---- chaos at each call into the family ---- *)

let%expect_test "[s9 accept] chaos evicts at an operation called through `at`, not only at `at`" =
  (* under this seed the `at` of 2 evicts nothing, and one of the ten
     operations in its block evicts 1 *)
  test ~seed:3
    {|
pub type DocId = | DocId(n: Int)

pub dep Doc =
  poke: fn()

pub handler doc(id: DocId) for Doc =
  poke() => ()

pub dep Docs = Actors<DocId, Doc>

test "chaos evicts at an operation called through `at`" =
  with actors(doc, chaos: true) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    var before = 0
    Docs.at(DocId(2)) fn() =>
      before = Docs.evicted()
      for i in 0..10
        Doc.poke()
    assert before == 0
    assert Docs.evicted() == 1
|};
  [%expect {|
    test.ren
      ✓ chaos evicts at an operation called through `at`

    1 passed
    [exit 0]
    |}]

(* ---- native ---- *)

let%expect_test "[s9 reject] natively, a program of actors is refused at `actors`, before the real `Random`" =
  let src =
    clean
      {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
handler doc(id: DocId) for Doc =
  poke() => ()
dep Docs = Actors<DocId, Doc>
fn main() uses Console, Random =
  with actors(doc) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
|}
  in
  report src (fun () -> ignore (Driver.mem ~lint:true ~file src));
  [%expect {|
    error: `actors` uses the keyed instance family, which isn't native yet
      ┌─ test.ren:8:8
    8 │   with actors(doc) as Docs in
      │        ^^^^^^^^^^^
      help: run it with `ren run`
    |}]
