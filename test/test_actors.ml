(* The services stage, step 7a (compiler.md, "Services stage", "Actors
   (step 7)"): `actors`, plain Ren in the prelude over the keyed instance
   family. test_services.ml's s7 tests are the stage's specification;
   these are the rules of decision 18's list for actors that it leaves to
   a test of their own, and what step 7a found besides. *)

open Ren
open Helpers

(* A fresh folder, the current one while [f] runs, with [files] in it,
   for a test that records a journal (as test_services.ml's). *)
let in_folder files f =
  let dir = Filename.temp_dir "ren_actors" "" in
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

(* `ren run --record run.journal main.ren`, then the journal. *)
let record () =
  let out = open_out_bin "run.journal" in
  let j = Journal.recording ~file:"run.journal" ~out ~program:"main.ren" in
  (try ignore (Driver.run ~lint:true ~record:j ~file:"main.ren" (read "main.ren"))
   with e -> show_error e);
  close_out out;
  print_string (read "run.journal")

(* `ren replay` of the journal [file]. *)
let replay file =
  try
    let journal = Journal.load ~file (read file) in
    ignore (Driver.replay ~lint:true ~journal ~file:"main.ren" (read "main.ren"));
    Printf.printf "replayed %d calls\n" journal.made
  with e -> show_error e

(* A document whose store waits before it answers, and counts how many
   times it was asked to load: so two tasks can ask for one document
   while it's being made. A negative id fails to load. *)
let slow =
  {|
import sim

type DocId = | DocId(n: Int)

dep Store =
  load: fn(id: DocId) -> Str ! StoreDown
  loads: fn() -> Int

handler slow_store() for Store uses Clock =
  var n = 0
  load(id) =>
    n += 1
    Clock.sleep(Duration.ms(10))
    let DocId(k) = id
    if k < 0 then fail StoreDown
    show(k)
  loads() => n

dep Doc =
  text: fn() -> Str

handler doc(id: DocId) for Doc ! StoreDown uses Store =
  let text = try Store.load(id)
  text() => text

dep Docs = Actors<DocId, Doc> ! StoreDown
|}

let%expect_test "those waiting on one key's setup share its error, and the next `at` tries again" =
  run
    (slow
   ^ {|
fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), slow_store(), actors(doc) as Docs in
      Async.scope fn(s) =>
        s.spawn fn() => print(attempt Docs.at(DocId(-1)) fn() => Doc.text())
        s.spawn fn() => print(attempt Docs.at(DocId(-1)) fn() => Doc.text())
      print(Store.loads())
      print(attempt Docs.at(DocId(-1)) fn() => Doc.text())
      print(Store.loads())
|});
  [%expect {|
    Err(StoreDown)
    Err(StoreDown)
    1
    Err(StoreDown)
    2
    ()
    |}]

let%expect_test "a setup that's cancelled is tried again by those waiting for it" =
  run
    (slow
   ^ {|
fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), slow_store(), actors(doc) as Docs in
      Async.scope fn(s) =>
        s.spawn fn() =>
          print(attempt Async.timeout(Duration.ms(5)) fn() => try Docs.at(DocId(1)) fn() => Doc.text())
        s.spawn fn() => print(attempt Docs.at(DocId(1)) fn() => Doc.text())
      print(Store.loads())
      print(Docs.made())
|});
  [%expect {|
    Err(Timeout)
    Ok("1")
    1
    1
    ()
    |}]

(* A document that says when it's evicted. *)
let noisy =
  {|
type DocId = | DocId(n: Int)

dep Doc =
  poke: fn()

handler doc(id: DocId) for Doc uses Console =
  finally(r) =>
    print("evicted " + show(id))
    try r
  poke() => ()

dep Docs = Actors<DocId, Doc>
|}

let%expect_test "`each` isn't use: the actor it visits last isn't the most recently released" =
  (* 1 and 2 made, then 1 used again, so 2 is the least recently
     released; `each` visits 1 and then 2, which would make 1 the least
     recently released if it were use *)
  run
    (noisy
   ^ {|
fn main() uses Console, Random =
  with actors(doc, max: 2) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.at(DocId(2)) fn() => Doc.poke()
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.each fn() => Doc.poke()
    print("making 3")
    Docs.at(DocId(3)) fn() => Doc.poke()
    print("made")
|});
  [%expect {|
    making 3
    evicted DocId(2)
    made
    evicted DocId(3)
    evicted DocId(1)
    ()
    |}]

let%expect_test "the task that makes an actor past `max:` pays for the eviction, its `finally` shielded" =
  (* the evicting task is cancelled while the victim's `finally` waits:
     the `finally` finishes, under the cleanup deadline, and then the
     task sees the cancel *)
  run
    {|
import sim

type DocId = | DocId(n: Int)

dep Doc =
  poke: fn()

handler doc(id: DocId) for Doc uses Console, Clock =
  finally(r) =>
    Clock.sleep(Duration.ms(50))
    print("evicted " + show(id))
    try r
  poke() => ()

dep Docs = Actors<DocId, Doc>

fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock(), actors(doc, max: 1) as Docs in
      Docs.at(DocId(1)) fn() => Doc.poke()
      print(attempt Async.timeout(Duration.ms(10)) fn() => Docs.at(DocId(2)) fn() => Doc.poke())
      print(Docs.count())
|};
  [%expect {|
    evicted DocId(1)
    Err(Timeout)
    1
    evicted DocId(2)
    ()
    |}]

let%expect_test "a journal names the task that pays for an eviction" =
  in_folder
    [
      ( "main.ren",
        noisy
        ^ {|
fn main() uses Console, Async, Random =
  with actors(doc, max: 1) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at(DocId(2)) fn() => Doc.poke()
|}
      );
    ]
    (fun () ->
      record ();
      replay "run.journal");
  [%expect {|
    evicted DocId(1)
    evicted DocId(2)
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened docs
    2 main made docs[DocId(1)]#1
    3 main/main:0 evicted docs[DocId(1)]#1
    4 main/main:0 Console.write("evicted DocId(1)")
    5 main/main:0 made docs[DocId(2)]#1
    6 main Console.write("evicted DocId(2)")
    7 main exit 0
    evicted DocId(1)
    evicted DocId(2)
    replayed 2 calls
    |}]

let%expect_test "a replay that evicts differently goes differently" =
  in_folder
    [
      ( "main.ren",
        noisy
        ^ {|
fn main() uses Console, Random =
  with actors(doc, max: 1) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.at(DocId(2)) fn() => Doc.poke()
|}
      );
    ]
    (fun () ->
      record ();
      (* the same program, keeping both *)
      let src = read "main.ren" in
      let was = "actors(doc, max: 1)" in
      let i =
        let rec find i =
          if String.sub src i (String.length was) = was then i else find (i + 1)
        in
        find 0
      in
      let src =
        String.sub src 0 i ^ "actors(doc, max: 2)"
        ^ String.sub src (i + String.length was)
            (String.length src - i - String.length was)
      in
      Out_channel.with_open_bin "main.ren" (fun oc -> output_string oc src);
      replay "run.journal");
  [%expect {|
    evicted DocId(1)
    evicted DocId(2)
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened docs
    2 main made docs[DocId(1)]#1
    3 main evicted docs[DocId(1)]#1
    4 main Console.write("evicted DocId(1)")
    5 main made docs[DocId(2)]#1
    6 main Console.write("evicted DocId(2)")
    7 main exit 0
    error: the replay went differently at call 1 of 2
       ┌─ main.ren:17:5
    17 │     Docs.at(DocId(2)) fn() => Doc.poke()
       │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = the recording has: main evicted docs[DocId(1)]#1
       = this program made: main made docs[DocId(2)]#1
       help: the code changed since this was recorded; record it again
    |}]

let%expect_test "a family has one cap and no partitions, so the journal opens it by its name alone" =
  (* step 10b: `parts:` left `actors` (concurrency.md, "Many cores") *)
  in_folder
    [
      ( "main.ren",
        noisy
        ^ {|
fn main() uses Console, Random =
  with actors(doc, max: 1000) as Docs in
    with actors(doc, max: 100) as Docs in
      Docs.at(DocId(1)) fn() => Doc.poke()
|}
      );
    ]
    (fun () -> record ());
  [%expect {|
    evicted DocId(1)
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened docs
    2 main opened docs
    3 main made docs[DocId(1)]#1
    4 main Console.write("evicted DocId(1)")
    5 main exit 0
    |}]

let%expect_test "`at` inside `at` hidden in a helper panics where it pins" =
  run_error
    (noisy
   ^ {|
fn poke(n: Int) uses Docs =
  Docs.at(DocId(n)) fn() => Doc.poke()

fn main() uses Console, Random =
  with actors(doc) as Docs in
    Docs.at(DocId(1)) fn() => poke(2)
|});
  [%expect {|
    error: panic: `Docs` pins one of its instances inside a block that pins another, which could wait for a slot its own block holds
       ┌─ test.ren:15:3
    15 │   Docs.at(DocId(n)) fn() => Doc.poke()
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "`at` of a family installed inside the one a block holds, hidden in a helper, panics" =
  (* rule 3's run-time check (step 10a): at the pin, whether or not it
     would wait; it was a panic only where it waited for a slot *)
  run_error
    {|
type Key = | Key(n: Int)
dep Inner =
  poke: fn()
dep Outer =
  poke: fn()
dep Inners = Actors<Key, Inner>
dep Outers = Actors<Key, Outer>
handler inner(k: Key) for Inner =
  poke() => ()
handler outer(k: Key) for Outer =
  poke() => ()

fn poke(n: Int) uses Inners =
  Inners.at(Key(n)) fn() => Inner.poke()

fn main() uses Console, Async, Random =
  with actors(outer, max: 1) as Outers in
    with actors(inner, max: 1) as Inners in
      Async.scope fn(s) =>
        s.spawn fn() =>
          Inners.at(Key(1)) fn() =>
            Async.yield()
            Inner.poke()
        s.spawn fn() => Outers.at(Key(1)) fn() => poke(2)
|};
  [%expect {|
    error: panic: a block that pins one of `Outers`'s instances pins one of `Inners`'s, installed inside it, which could wait for what the block holds
       ┌─ test.ren:14:3
    14 │   Inners.at(Key(n)) fn() => Inner.poke()
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = in the task main/main:1
    |}]

let%expect_test "a handler's maker is given a function's name" =
  check_error
    (noisy
   ^ {|
fn main() uses Console, Random =
  with actors(fn(k: DocId) => doc(k)) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
|});
  [%expect {|
    error: a handler keeps the block it's given here, so it's given a function's name
       ┌─ test.ren:15:15
    15 │   with actors(fn(k: DocId) => doc(k)) as Docs in
       │               ^^^^^^^^^^^^^^^^^^^^^^
       = a handler's description is a value, which can outlive the call that made it, so a block it keeps captures nothing
       help: name a handler, or a function, here: `actors(doc)`
    |}]

let%expect_test "an actor's handler that keeps a block is refused, as any handler's is" =
  check_error
    {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
handler doc(id: DocId, f: fn()) for Doc =
  poke() => f()
|};
  [%expect {|
    error: a handler's parameters are data
      ┌─ test.ren:4:24
    4 │ handler doc(id: DocId, f: fn()) for Doc =
      │                        ^^^^^^^ `f` is a block
      = a handler's description is a value, which can outlive the call that made it
      help: pass the data, or make the behaviour a dependency
    |}]

let%expect_test "an alias says what making one of its family's actors fails with" =
  (* `dep Docs = Actors<DocId, Doc> ! StoreDown` is `Actors<DocId, (Doc !
     StoreDown)>`: what's installed as it fails to start with no more *)
  types
    {|
pub type DocId = | DocId(n: Int)
pub dep Doc =
  poke: fn()
pub dep Docs = Actors<DocId, Doc> ! StoreDown
pub dep Plain = Actors<DocId, Doc>
|};
  [%expect {|
    error: this program has no `main` function
      ┌─ test.ren:1:1
    1 │ pub type DocId = | DocId(n: Int)
      │ ^
      help: add `fn main() = ...`, which is where the program starts
    |}]
