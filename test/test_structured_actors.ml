(* The services stage, step 10a: structured actors (concurrency.md,
   rules 2 to 4; compiler.md, "Services stage", "Step 10: structured
   actors"). There's no mail inside a family, a post waits for room in its
   key's mailbox and only there, an `at` block holds its family (rule 3),
   and a cancelled `with` cancels what its family runs and drops what's
   queued. A program run with [run] is `ren run`'s, on `Async.single()`
   or on a `sim.scheduler(seed)` it installs itself; one run with [test]
   is `ren test`'s, on `sim`. *)

open Helpers

(* ---- rule 2: a post waits for room in its key's mailbox, and only there ---- *)

let%expect_test "[s10 accept] a slow key holds up only its own posters" =
  (* each key's mailbox holds one post; key 1's operation takes 100 ms,
     key 2's none. The poster to key 2 is done at once, while the poster
     to key 1 waits for room in key 1's mailbox, and only there: with one
     bound for the family, it would have held up key 2's too
     (research/structured-actors/MODEL.md, mutant (b)) *)
  run
    {|
import sim

type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log uses Console, Clock =
  put(s) =>
    let Key(n) = k
    if n == 1 then Clock.sleep(Duration.ms(100))
    print(s)

fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), actors(log, mailbox: 1) as Logs in
      Async.scope fn(s) =>
        s.spawn fn() =>
          for i in 0..3
            Logs.post(Key(1), Log.Call.Put { s: "slow " + show(i) })
          print("the slow key's poster is done")
        s.spawn fn() =>
          for i in 0..3
            Logs.post(Key(2), Log.Call.Put { s: "fast " + show(i) })
          print("the fast key's poster is done")
|};
  [%expect {|
    fast 0
    fast 1
    the fast key's poster is done
    fast 2
    slow 0
    the slow key's poster is done
    slow 1
    slow 2
    ()
    |}]

let%expect_test "[s10 accept] a post's making waits for a slot, so a family never goes past `max:`" =
  (* delivery past `max:` is gone (MODEL.md): a key with mail always has
     a live actor, so a post that needs a slot waits for one, here until
     key 1's mail is delivered and it can be evicted *)
  run
    {|
import sim

type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log uses Console, Clock =
  finally(r) =>
    print("evicted " + show(k))
    try r
  put(s) =>
    Clock.sleep(Duration.ms(10))
    print(s + " to " + show(k))

fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), actors(log, max: 1) as Logs in
      Logs.post(Key(1), Log.Call.Put { s: "a" })
      Logs.post(Key(1), Log.Call.Put { s: "b" })
      Logs.post(Key(2), Log.Call.Put { s: "c" })
      print("live " + show(Logs.count()) + ", made " + show(Logs.made()))
|};
  [%expect {|
    a to Key(1)
    b to Key(1)
    evicted Key(1)
    live 1, made 2
    c to Key(2)
    evicted Key(2)
    ()
    |}]

(* ---- rule 3: an `at` block holds its family ---- *)

let families =
  {|
type Key = | Key(n: Int)
dep Inner =
  poke: fn()
dep Outer =
  poke: fn()
dep Inners = Actors<Key, Inner>
dep Outers = Actors<Key, Outer>
handler inner(k: Key) for Inner uses Console =
  poke() => print("inner " + show(k))
handler outer(k: Key) for Outer uses Console =
  poke() => print("outer " + show(k))
|}

let%expect_test "[s10 accept] an `at` block reaches the families installed outside the one it holds" =
  run
    (families
   ^ {|
fn main() uses Console, Random =
  with actors(outer) as Outers in
    with actors(inner) as Inners in
      Inners.at(Key(1)) fn() =>
        Inner.poke()
        Outers.at(Key(2)) fn() => Outer.poke()
        Outers.post(Key(3), Outer.Call.Poke)
|});
  [%expect {|
    inner Key(1)
    outer Key(2)
    outer Key(3)
    ()
    |}]

let%expect_test "[s10 reject] a post to a family installed inside the one an `at` block holds" =
  check_error
    (families
   ^ {|
fn main() uses Console, Random =
  with actors(outer) as Outers in
    with actors(inner) as Inners in
      Outers.at(Key(1)) fn() => Inners.post(Key(2), Inner.Call.Poke)
|});
  [%expect {|
    error: `Inners.post` inside a block of `Outers.at` reaches `Inners`, installed inside `Outers`
       ┌─ test.ren:16:33
    16 │       Outers.at(Key(1)) fn() => Inners.post(Key(2), Inner.Call.Poke)
       │                                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = a block of `Outers.at` holds `Outers` until it ends: inside it, only families installed outside `Outers` can be reached, so every wait points outward
       help: call `Inners.post` after the block, or reach `Inners` first and `Outers` inside its block
    |}]

let%expect_test "[s10 reject] an `at` block of a family the function's caller installed reaches one installed here" =
  (* what the function installs is inside what its callers do *)
  check_error
    (families
   ^ {|
fn go() uses Outers, Console, Random =
  with actors(inner) as Inners in
    Outers.at(Key(1)) fn() => Inners.at(Key(2)) fn() => Inner.poke()

fn main() uses Console, Random =
  with actors(outer) as Outers in go()
|});
  [%expect {|
    error: `Inners.at` inside a block of `Outers.at` reaches `Inners`, installed inside `Outers`
       ┌─ test.ren:15:31
    15 │     Outers.at(Key(1)) fn() => Inners.at(Key(2)) fn() => Inner.poke()
       │                               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = a block of `Outers.at` holds `Outers` until it ends: inside it, only families installed outside `Outers` can be reached, so every wait points outward
       help: call `Inners.at` after the block, or reach `Inners` first and `Outers` inside its block
    |}]

let%expect_test "[s10 reject] a post to the family an `at` block holds, hidden in a helper, panics" =
  (* Infer can't see through `note`, so the family's run-time check says
     it, through the same machinery as `at` inside `at` *)
  run_error
    (families
   ^ {|
fn note(n: Int) uses Inners =
  Inners.post(Key(n), Inner.Call.Poke)

fn main() uses Console, Random =
  with actors(inner) as Inners in
    Inners.at(Key(1)) fn() => note(2)
|});
  [%expect {|
    error: panic: `Inners` is posted to inside a block that pins one of its instances, which could wait for what its own block holds
       ┌─ test.ren:14:3
    14 │   Inners.post(Key(n), Inner.Call.Poke)
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s10 reject] a post to a family installed inside the one an `at` block holds, hidden in a helper, panics" =
  run_error
    (families
   ^ {|
fn note(n: Int) uses Inners =
  Inners.post(Key(n), Inner.Call.Poke)

fn go() uses Outers, Console, Random =
  with actors(inner) as Inners in
    Outers.at(Key(1)) fn() => note(2)

fn main() uses Console, Random =
  with actors(outer) as Outers in go()
|});
  [%expect {|
    error: panic: a block that pins one of `Outers`'s instances posts to `Inners`, installed inside it, which could wait for what the block holds
       ┌─ test.ren:14:3
    14 │   Inners.post(Key(n), Inner.Call.Poke)
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

(* ---- rule 4: a `with` drains as it ends, and a cancelled one cancels ---- *)

let noisy =
  {|
import sim

type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log uses Console, Clock =
  finally(r) =>
    print("finally " + show(k) + " " + show(r))
    try r
  put(s) =>
    print("start " + s)
    Clock.sleep(Duration.ms(100))
    print("end " + s)
|}

let%expect_test "[s10 accept] a cancelled `with` cancels what's running, drops queued mail, and its `finally`s see `Err(Cancelled)`" =
  (* the timeout cancels the `with`'s body at 50 ms: `a` and `c` are
     running, cancelled at their next dependency call, and `b`, queued
     behind `a`, never starts *)
  run
    (noisy
   ^ {|
fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock() in
      let r = attempt Async.timeout(Duration.ms(50)) fn() =>
        with actors(log) as Logs in
          Logs.post(Key(1), Log.Call.Put { s: "a" })
          Logs.post(Key(1), Log.Call.Put { s: "b" })
          Logs.post(Key(2), Log.Call.Put { s: "c" })
          Clock.sleep(Duration.ms(1000))
      print(r)
|});
  [%expect {|
    start c
    start a
    finally Key(2) Err(Cancelled)
    finally Key(1) Err(Cancelled)
    Err(Timeout)
    ()
    |}]

let%expect_test "[s10 accept] a drain isn't shielded: a drain with a limit is the `with` inside `Async.timeout`" =
  (* the body returns at once, and the drain delivers `a`; the timeout
     comes while `b` runs, which is cancelled, and `c` is dropped *)
  run
    (noisy
   ^ {|
fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock() in
      let r = attempt Async.timeout(Duration.ms(150)) fn() =>
        with actors(log) as Logs in
          Logs.post(Key(1), Log.Call.Put { s: "a" })
          Logs.post(Key(1), Log.Call.Put { s: "b" })
          Logs.post(Key(1), Log.Call.Put { s: "c" })
      print(r)
|});
  [%expect {|
    start a
    end a
    start b
    finally Key(1) Err(Cancelled)
    Err(Timeout)
    ()
    |}]

let%expect_test "[s10 accept] a `with` whose body returns drains, and its `finally`s see `Ok`" =
  run
    (noisy
   ^ {|
fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock() in
      with actors(log) as Logs in
        Logs.post(Key(1), Log.Call.Put { s: "a" })
        Logs.post(Key(1), Log.Call.Put { s: "b" })
|});
  [%expect {|
    start a
    end a
    start b
    end b
    finally Key(1) Ok(())
    ()
    |}]
