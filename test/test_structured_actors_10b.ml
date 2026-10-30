(* The services stage, step 10b: structured actors' second half
   (concurrency.md, "Several keys at once" and "Many cores"; compiler.md,
   "Services stage", "Step 10: structured actors"). A full family evicts
   the oldest-used of 5 sampled actors with no pin and no mail, `Random`
   drawing the sample, and `parts:` is gone; `Docs.at_all(keys)` holds
   several keys for one block, in their order, and inside it `at` of a
   held key doesn't wait while `at` of any other panics. A program run
   with [run] is `ren run`'s, on `Async.single()`, or on a
   `sim.scheduler(seed)` it installs itself; one run with [test] is `ren
   test`'s, on `sim`. *)

open Ren
open Helpers

(* A fresh folder, the current one while [f] runs, with [files] in it,
   for a test that records a journal (as test_actors.ml's). *)
let in_folder files f =
  let dir = Filename.temp_dir "ren_actors_10b" "" in
  List.iter
    (fun (name, text) ->
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
          output_string oc (clean text)))
    files;
  let old = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old) f

let read path = In_channel.with_open_bin path In_channel.input_all
let sources f = try Some (read f) with Sys_error _ -> None

let show_error e =
  match Driver.render_error ~sources e with
  | Some msg -> print_string msg
  | None -> raise e

(* `ren run --record run.journal main.ren`: the journal. *)
let record () =
  let out = open_out_bin "run.journal" in
  let j = Journal.recording ~file:"run.journal" ~out ~program:"main.ren" in
  (try ignore (Driver.run ~lint:true ~record:j ~file:"main.ren" (read "main.ren"))
   with e -> show_error e);
  close_out out;
  read "run.journal"

(* `ren replay` of the journal [file]. *)
let replay file =
  try
    let journal = Journal.load ~file (read file) in
    ignore (Driver.replay ~lint:true ~journal ~file:"main.ren" (read "main.ren"));
    Printf.printf "replayed %d calls\n" journal.made
  with e -> show_error e

(* The lines of a journal that say what a family did, without their
   numbers and tasks: its victims, in order. *)
let family_lines journal =
  String.split_on_char '\n' journal
  |> List.filter_map (fun l ->
         match String.split_on_char ' ' l with
         | _ :: _ :: (("opened" | "made" | "evicted") as w) :: rest ->
             Some (String.concat " " (w :: rest))
         | _ -> None)

(* Accounts, one actor each, that say when they're evicted. *)
let accounts =
  {|
type Account = | Account(n: Int)
dep Balance =
  take: fn(n: Int) -> Int
  give: fn(n: Int)
  read: fn() -> Int
handler balance(a: Account) for Balance uses Console =
  var money = 100
  finally(r) =>
    print("evicted " + show(a) + " with " + show(money))
    try r
  take(n) =>
    money -= n
    n
  give(n) => money += n
  read() => money
dep Accounts = Actors<Account, Balance>
|}

(* The same, saying nothing. *)
let quiet =
  {|
type Account = | Account(n: Int)
dep Balance =
  give: fn(n: Int)
handler quiet(a: Account) for Balance =
  var money = 100
  give(n) => money += n
dep Accounts = Actors<Account, Balance>
|}

(* ---- sampled eviction (K1b) ---- *)

let%expect_test "[s10b accept] of 5 or fewer evictable actors, the oldest-used is evicted, drawing nothing" =
  (* 1, 2 and 3 used, then 1 again: 2 is the oldest-used. With 5 or fewer
     the sample is all of them, so this is exact LRU, and `Random` isn't
     asked (the test's `Random` would panic if it were) *)
  run
    (accounts
   ^ {|
handler never() for Random =
  int(below) => lib_panic("drew " + show(below))

fn main() uses Console =
  with never(), actors(balance, max: 3) as Accounts in
    for n in [1, 2, 3, 1]
      Accounts.at(Account(n)) fn() => Balance.give(n)
    Accounts.at(Account(4)) fn() => Balance.give(4)
    print(Accounts.keys())
|});
  [%expect {|
    evicted Account(2) with 102
    [Account(1), Account(3), Account(4)]
    evicted Account(4) with 104
    evicted Account(3) with 103
    evicted Account(1) with 102
    ()
    |}]

let%expect_test "[s10b accept] of more than 5, the victim is the oldest-used of 5 `Random` samples" =
  (* 7 actors used in order, 0 the oldest; making an 8th samples 5 of the
     7 evictable ones, leaving 2 out, so the victim is 0, 1 or 2: never one
     of the 4 used last. Under 40 seeds' numbers, each of the three *)
  run
    (quiet
   ^ {|
fn victims(seed: Int) -> Array<Int> uses Console =
  var out: Array<Int> = []
  with test_random(seed), actors(quiet, max: 7) as Accounts in
    for n in 0..7
      Accounts.at(Account(n)) fn() => Balance.give(0)
    Accounts.at(Account(7)) fn() => Balance.give(0)
    for n in 0..7
      if not Accounts.keys().includes(Account(n)) then &out.push(n)
  out

fn main() uses Console =
  var seen: Array<Int> = []
  for seed in 0..40
    for v in victims(seed)
      if not seen.includes(v) then &seen.push(v)
  print(seen)
|});
  [%expect {|
    [0, 1, 2]
    ()
    |}]

let%expect_test "[s10b accept] `parts:` is gone" =
  check_error
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance, max: 1000, parts: 2) as Accounts in
    Accounts.at(Account(1)) fn() => Balance.give(1)
|});
  [%expect {|
    error: `actors` has no parameter named `parts`
       ┌─ test.ren:19:35
    19 │   with actors(balance, max: 1000, parts: 2) as Accounts in
       │                                   ^^^^^
       help: its parameters given by name: `max`, `mailbox`, `evict`, `chaos`
    |}]

let%expect_test "[s10b accept] a run that evicts by sampling replays, and its victims are the same at one worker and at `sim`'s two" =
  (* the runtime has `single`, one worker, and `sim`, which stands for
     two (`Async.worker()`); there's no way to ask for four, so this is as
     close as it gets. The same program, one task taking actors beside
     one that asks which worker it's on, recorded on `Async.single()` and
     on `sim.scheduler(seed)` under three seeds, which interleave the two
     tasks differently and put them on either worker. Recording each again
     writes the same bytes (the sample's numbers are the test's
     `Random`'s, from its seed, and the task that evicts draws from a
     stream of its own); the one-worker journal replays (`ren replay`
     runs in `single`'s order, so a `sim` run whose tasks interleave
     without waiting on the world isn't one it follows); and the family's
     lines, what it made and evicted, are the same in all four, since a
     victim depends only on the takes and the sample, not on where or
     beside what they ran *)
  let program ~import runtime =
    (if import then "import sim\n" else "")
    ^ quiet
    ^ {|
fn main() uses Console =
  with |}
    ^ runtime
    ^ {| in
    with test_random(11), actors(quiet, max: 6) as Accounts in
      Async.scope fn(s) =>
        s.spawn fn() =>
          for n in [0, 1, 2, 3, 4, 5, 6, 2, 7, 8, 0, 9, 3, 10, 11, 4]
            Accounts.at(Account(n)) fn() => Balance.give(n)
          print("taken")
        s.spawn fn() =>
          for i in 0..5
            let _ = Async.worker()
            Async.yield()
|}
  in
  let run_on ~import ~replays runtime =
    in_folder
      [ ("main.ren", program ~import runtime) ]
      (fun () ->
        let first = record () in
        if replays then replay "run.journal";
        let again = record () in
        print_endline
          (runtime ^ ": "
          ^ if again = first then "recorded again, the same bytes" else "recorded again, different");
        family_lines first)
  in
  let one = run_on ~import:false ~replays:true "Async.single()" in
  let sims =
    List.map
      (fun seed -> run_on ~import:true ~replays:false (Printf.sprintf "sim.scheduler(%d)" seed))
      [ 1; 5; 9 ]
  in
  print_endline
    (if List.for_all (fun two -> two = one) sims then "the same family lines on each"
     else "different family lines");
  List.iter print_endline one;
  [%expect {|
    taken
    taken
    replayed 1 calls
    taken
    Async.single(): recorded again, the same bytes
    taken
    taken
    sim.scheduler(1): recorded again, the same bytes
    taken
    taken
    sim.scheduler(5): recorded again, the same bytes
    taken
    taken
    sim.scheduler(9): recorded again, the same bytes
    the same family lines on each
    opened accounts
    made accounts[Account(0)]#1
    made accounts[Account(1)]#1
    made accounts[Account(2)]#1
    made accounts[Account(3)]#1
    made accounts[Account(4)]#1
    made accounts[Account(5)]#1
    evicted accounts[Account(0)]#1
    made accounts[Account(6)]#1
    evicted accounts[Account(1)]#1
    made accounts[Account(7)]#1
    evicted accounts[Account(4)]#1
    made accounts[Account(8)]#1
    evicted accounts[Account(5)]#1
    made accounts[Account(0)]#2
    evicted accounts[Account(3)]#1
    made accounts[Account(9)]#1
    evicted accounts[Account(6)]#1
    made accounts[Account(3)]#2
    evicted accounts[Account(2)]#1
    made accounts[Account(10)]#1
    evicted accounts[Account(7)]#1
    made accounts[Account(11)]#1
    evicted accounts[Account(8)]#1
    made accounts[Account(4)]#2
    |}]

(* ---- `at_all` (concurrency.md, "Several keys at once") ---- *)

let%expect_test "[s10b accept] `at_all` moves money between two accounts" =
  run
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance, max: 4) as Accounts in
    let (from, to) = (Account(2), Account(1))
    Accounts.at_all([from, to]) fn() =>
      let m = Accounts.at(from) fn() => Balance.take(30)
      Accounts.at(to) fn() => Balance.give(m)
    print(Accounts.at(from) fn() => Balance.read())
    print(Accounts.at(to) fn() => Balance.read())
    print(Accounts.keys())
|});
  [%expect {|
    70
    130
    [Account(1), Account(2)]
    evicted Account(2) with 70
    evicted Account(1) with 130
    ()
    |}]

let%expect_test "[s10b accept] `at_all` makes its keys in their order, each once, and fails as making one does" =
  run
    {|
type Key = | Key(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<Key, Doc> ! Missing
handler doc(k: Key) for Doc ! Missing uses Console =
  let Key(n) = k
  let _ = if n < 0 then fail Missing else print("made " + show(k))
  poke() => ()

fn main() uses Console, Random =
  with actors(doc, max: 4) as Docs in
    try Docs.at_all([Key(3), Key(1), Key(2), Key(1)]) fn() => ()
    print(Docs.keys())
    print(attempt Docs.at_all([Key(5), Key(-1)]) fn() => print("never"))
    print(Docs.keys())
|};
  [%expect {|
    made Key(1)
    made Key(2)
    made Key(3)
    [Key(1), Key(2), Key(3)]
    Err(Missing)
    [Key(1), Key(2), Key(3)]
    ()
    |}]

let%expect_test "[s10b accept] two `at_all`s over keys of a full family don't wait on each other" =
  (* two keys each, in a family of 2: whichever is second to need a slot
     lets go of what it holds and waits for room for both, so neither
     waits for a slot the other holds, under every schedule *)
  test ~seeds:300
    {|
pub type Key = | Key(n: Int)
pub dep Doc =
  poke: fn()
pub dep Docs = Actors<Key, Doc>
pub handler doc(k: Key) for Doc uses Clock =
  let _ = Clock.sleep(Duration.ms(1))
  poke() => Clock.sleep(Duration.ms(1))

test "both blocks run" =
  with actors(doc, max: 2) as Docs in
    var done = 0
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at_all([Key(1), Key(2)]) fn() =>
        Docs.at(Key(1)) fn() => Doc.poke()
        Docs.at(Key(2)) fn() => Doc.poke()
      s.spawn fn() => Docs.at_all([Key(3), Key(4)]) fn() =>
        Docs.at(Key(4)) fn() => Doc.poke()
        Docs.at(Key(3)) fn() => Doc.poke()
    assert Docs.count() == 2
|};
  [%expect {|
    test.ren
      ✓ both blocks run

    1 passed, each under 300 seeds
    [exit 0]
    |}]

let%expect_test "[s10b reject] `at` of a key `at_all` doesn't hold, hidden in a helper, panics" =
  run_error
    (accounts
   ^ {|
fn give(n: Int) uses Accounts =
  Accounts.at(Account(n)) fn() => Balance.give(1)

fn main() uses Console, Random =
  with actors(balance) as Accounts in
    Accounts.at_all([Account(1), Account(2)]) fn() =>
      give(2)
      give(3)
|});
  [%expect {|
    error: panic: `Accounts` pins an instance its `at_all` block doesn't hold, which could wait for a slot the block holds
       ┌─ test.ren:19:3
    19 │   Accounts.at(Account(n)) fn() => Balance.give(1)
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s10b reject] `at_all` of more keys than the family keeps panics" =
  run_error
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance, max: 2) as Accounts in
    Accounts.at_all([Account(1), Account(2), Account(3)]) fn() => ()
|});
  [%expect {|
    error: panic: `Accounts.at_all` asks for 3 keys of a family that keeps at most 2
       ┌─ test.ren:20:5
    20 │     Accounts.at_all([Account(1), Account(2), Account(3)]) fn() => ()
       │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s10b reject] a post inside `at_all`'s block, to the family it holds" =
  check_error
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance) as Accounts in
    Accounts.at_all([Account(1), Account(2)]) fn() =>
      Accounts.post(Account(1), Balance.Call.Give { n: 1 })
|});
  [%expect {|
    error: `Accounts.post` inside a block of `Accounts.at_all` reaches the family its block holds
       ┌─ test.ren:21:7
    21 │       Accounts.post(Account(1), Balance.Call.Give { n: 1 })
       │       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = a block of `Accounts.at_all` holds `Accounts` until it ends: inside it, only families installed outside `Accounts` can be reached, so every wait points outward
       help: call `Accounts.post` after the block
    |}]

let%expect_test "[s10b reject] `each` inside `at_all`'s block" =
  check_error
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance) as Accounts in
    Accounts.at_all([Account(1)]) fn() =>
      Accounts.each fn() => Balance.give(1)
|});
  [%expect {|
    error: `Accounts.each` inside a block of `Accounts.at_all` could wait for a slot its own block holds
       ┌─ test.ren:21:7
    21 │       Accounts.each fn() => Balance.give(1)
       │       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = `Accounts.at_all` keeps the instance it pins for its block, and making another can wait for room in the family
       help: finish with the first, then call the second
    |}]

let%expect_test "[s10b reject] `at_all` inside a block of `at` of the same family" =
  check_error
    (accounts
   ^ {|
fn main() uses Console, Random =
  with actors(balance) as Accounts in
    Accounts.at(Account(1)) fn() =>
      Accounts.at_all([Account(1), Account(2)]) fn() => ()
|});
  [%expect {|
    error: `Accounts.at_all` inside a block of `Accounts.at` could wait for a slot its own block holds
       ┌─ test.ren:21:7
    21 │       Accounts.at_all([Account(1), Account(2)]) fn() => ()
       │       ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = `Accounts.at` keeps the instance it pins for its block, and making another can wait for room in the family
       help: finish with the first, then call the second
    |}]

let%expect_test "[s10b reject] `at_all` inside a block of `at`, hidden in a helper, panics" =
  run_error
    (accounts
   ^ {|
fn both() uses Accounts =
  Accounts.at_all([Account(1), Account(2)]) fn() => ()

fn main() uses Console, Random =
  with actors(balance) as Accounts in
    Accounts.at(Account(1)) fn() => both()
|});
  [%expect {|
    error: panic: `Accounts` pins one of its instances inside a block that pins another, which could wait for a slot its own block holds
       ┌─ test.ren:19:3
    19 │   Accounts.at_all([Account(1), Account(2)]) fn() => ()
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]
