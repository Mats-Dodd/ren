(* The journal (handlers.md, "The journal"; journal.ml): recording a run,
   replaying it strictly, and a journal as a test fixture, `replay(file)`.
   A journal is a file, so these run in a folder of their own, made fresh
   for each test, with the program and its journals in it. *)

open Ren
open Helpers

(* A fresh folder, the current one while [f] runs: messages name files
   from it, as they would from wherever `ren` is run. *)
let in_folder files f =
  let dir = Filename.temp_dir "ren_journal" "" in
  List.iter
    (fun (name, text) ->
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
          output_string oc (clean text)))
    files;
  let old = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old) f

let read path = In_channel.with_open_bin path In_channel.input_all

(* What a message can show: any file in the folder. *)
let sources f = try Some (read f) with Sys_error _ -> None

let show_error e =
  match Driver.render_error ~sources e with
  | Some msg -> print_string msg
  | None -> raise e

(* `ren run --record run.journal main.ren`, then the journal. *)
let record ?(args = []) () =
  let out = open_out_bin "run.journal" in
  let j = Journal.recording ~file:"run.journal" ~out ~program:"main.ren" in
  (try
     ignore
       (Driver.run ~lint:true ~args ~record:j ~file:"main.ren" (read "main.ren"))
   with e -> show_error e);
  close_out out;
  print_string (read "run.journal")

(* `ren replay` of the journal [file]. *)
let replay file =
  try
    let journal = Journal.load ~file (read file) in
    ignore
      (Driver.replay ~lint:true ~journal ~file:"main.ren" (read "main.ren"));
    Printf.printf "replayed %d calls\n" journal.made
  with
  | Journal.Version_1 { file; program } ->
      (* as `ren replay` says it (main.ml) *)
      let said, note, help = Journal.version_1_said ~file ~program in
      Printf.printf "error: %s\n  = %s\n  help: %s\n" said note help
  | e -> show_error e

(* `ren test main.ren`, each test under [seeds] seeds from 1. *)
let test ?(seeds = 1) () =
  try
    let suite =
      Driver.suite ~lint:true ~dir:"." [ ("main.ren", read "main.ren") ]
    in
    ignore
      (Test_runner.run
         ~opts:
           {
             path = "main.ren";
             dir = ".";
             only = None;
             exact = false;
             seed = Some 1;
             list = false;
             seeds;
             timings = false;
           }
         ~sources suite)
  with e -> show_error e

let%expect_test "a recording is the calls, what each gave, and how it ended" =
  in_folder
    [
      ( "main.ren",
        {|
fn main() ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Fs, Os, Console =
  let args = Os.args()
  try Fs.write(Path.of("out.txt"), "a\"b\tc\n".bytes())
  let text = try Fs.read_str(Path.of("out.txt"))
  Console.write(text)
  Console.error("done")
|}
      );
    ]
    (fun () -> record ~args:[ "x y" ] ());
  [%expect
    {|
    a"b	c

    done
    # ren journal 2 · main.ren · deps: Console Fs Os
    1 main Os.args() → ["x y"]
    2 main Fs.write("out.txt", "a\"b\tc\n")
    3 main Fs.read("out.txt") → Ok("a\"b\tc\n")
    4 main Console.write("a\"b\tc\n")
    5 main Console.error("done")
    6 main exit 0
    |}]

let%expect_test "a run that fails, or panics, ends its journal so" =
  in_folder
    [
      ( "main.ren",
        {|
fn main() ! FsError uses Fs =
  let b = try Fs.read(Path.of("nothing"))
  ()
|}
      );
    ]
    (fun () -> record ());
  in_folder
    [
      ( "main.ren",
        {|
fn main() uses Console =
  print(1)
  let xs = [1]
  print(xs[3])
|}
      );
    ]
    (fun () -> record ());
  [%expect
    {|
    error: NoSuchFile(nothing)
    # ren journal 2 · main.ren · deps: Fs
    1 main Fs.read("nothing") → Err(NoSuchFile("nothing"))
    2 main error NoSuchFile("nothing")
    1
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ main.ren:4:9
    4 │   print(xs[3])
      │         ^^^^^
    # ren journal 2 · main.ren · deps: Console
    1 main Console.write("1")
    2 main panic main.ren:4:9 "index 3 is out of bounds for an array of length 1"
    |}]

let%expect_test "bytes that aren't UTF-8 are written with \\x, and read back" =
  in_folder
    [
      ( "main.ren",
        {|
fn main() ! FsError uses Fs, Console =
  let b = try Fs.read(Path.of("in.bin"))
  print(b.len())
|}
      );
      ("in.bin", "\n\xff\x01ok");
    ]
    (fun () ->
      record ();
      Sys.remove "in.bin";
      replay "run.journal");
  [%expect
    {|
    4
    # ren journal 2 · main.ren · deps: Console Fs
    1 main Fs.read("in.bin") → Ok("\xff\x01ok")
    2 main Console.write("4")
    3 main exit 0
    4
    replayed 2 calls
    |}]

(* ---- a journal as a test fixture ---- *)

(* A program that reads two files, [first] and [second], and the time
   between, and writes what it read, with a test that replays a
   recording of it. *)
let reader ?(second = "b") ?(done_ = "done") () =
  Printf.sprintf
    {|
pub fn main() ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Fs, Clock, Console =
  let a = try Fs.read_str(Path.of("a"))
  let t = Clock.now()
  Console.write(a)
  let b = try Fs.read_str(Path.of(%S))
  let u = Clock.now()
  Console.write(b)
  Console.error(%S)

test "the recording replays" =
  with replay("run.journal") in
    try main()
|}
    second done_

(* A recording of [reader]: the clock and the files, in the order they
   were called, though in a test each dependency's calls are answered in
   order on their own. *)
let reader_journal ?(calls = []) () =
  String.concat "\n"
    ([
       "# ren journal 2 · main.ren · deps: Clock Console Fs";
       {|1 main Fs.read("a") → Ok("one")|};
       {|2 main Clock.now() → 10|};
       {|3 main Console.write("one")|};
       {|4 main Fs.read("b") → Ok("two")|};
       {|5 main Clock.now() → 15|};
       {|6 main Console.write("two")|};
       {|7 main Console.error("done")|};
       {|8 main exit 0|};
     ]
    |> List.filter (fun l ->
        not
          (List.exists (fun c -> String.starts_with ~prefix:(c ^ " ") l) calls))
    )
  ^ "\n"

let%expect_test "a replay in a test answers inputs and compares outputs" =
  in_folder [ ("main.ren", reader ()); ("run.journal", reader_journal ()) ] test;
  [%expect {|
    main.ren
      ✓ the recording replays

    1 passed
    |}]

let%expect_test "a test whose outputs differ fails with a diff" =
  in_folder
    [
      ("main.ren", reader ~done_:"all done" ());
      ("run.journal", reader_journal ());
    ]
    test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:11
       │
    11 │   with replay("run.journal") in
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       the outputs differ from the recording's
         Console.write("one")
         Console.write("two")
       - Console.error("done")
       + Console.error("all done")
       help: if the change is what you meant, record the run again, or edit the journal

       seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "a test that reads what the recording didn't stops there" =
  in_folder
    [ ("main.ren", reader ~second:"c" ()); ("run.journal", reader_journal ()) ]
    test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:5
      │
    5 │   let b = try Fs.read_str(Path.of("c"))
      │               ^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      this isn't the call to `Fs` the recording has next
      = the recording has: Fs.read("b")
      = this program made: Fs.read("c")
      help: the code changed since this was recorded: record it again, or edit the journal

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "a test that reads more than the recording did stops there" =
  in_folder
    [
      ("main.ren", reader ()); ("run.journal", reader_journal ~calls:[ "4" ] ());
    ]
    test;
  in_folder
    [
      ("main.ren", reader ());
      ("run.journal", reader_journal ~calls:[ "2"; "5" ] ());
    ]
    test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:5
      │
    5 │   let b = try Fs.read_str(Path.of("b"))
      │               ^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      the recording has no more calls to `Fs`
      = this program made: Fs.read("b")
      help: the code changed since this was recorded: record it again, or edit the journal

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:3
      │
    3 │   let t = Clock.now()
      │           ^^^^^^^^^^^
      │
      the recording has no calls to `Clock`
      = this program made: Clock.now()
      help: the code changed since this was recorded: record it again, or edit the journal

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "a journal that isn't there is a panic" =
  in_folder [ ("main.ren", reader ()) ] test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:11
       │
    11 │   with replay("run.journal") in
       │        ^^^^^^^^^^^^^^^^^^^^^
       │
       panic: there's no journal at run.journal

       seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "an entry that can't be read fails the test, at its line" =
  in_folder
    [
      ("main.ren", reader ());
      ( "run.journal",
        String.concat "\n"
          [
            "# ren journal 2 · main.ren · deps: Clock Console Fs";
            {|1 main Fs.read("a") → Ok(<redacted>)|};
            "2 main exit 0";
          ] );
    ]
    test;
  in_folder
    [
      ("main.ren", reader ());
      ( "run.journal",
        String.concat "\n"
          [
            "# ren journal 2 · main.ren · deps: Clock Console Fs";
            {|1 main Fs.read("a") → Ok(5)|};
            "2 main exit 0";
          ] );
    ]
    test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── run.journal:2
      │
    2 │ 1 main Fs.read("a") → Ok(<redacted>)
      │ ^
      │
      error: what this call gave was left out when it was recorded, so it can't be given back
      help: record the run again, or write the value as it's recorded

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    main.ren
      ✗ the recording replays

    ──── the recording replays ── run.journal:2
      │
    2 │ 1 main Fs.read("a") → Ok(5)
      │ ^
      │
      error: this entry can't be read as a `Result<Bytes, ! FsFailed(Path, Str) | IsAFolder(Path) | NoSuchFile(Path) | NotAllowed(Path)>`
      help: record the run again, or write the value as it's recorded

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "`replay` is test code" =
  run {|
fn main() =
  with replay("run.journal") in
    ()
|};
  [%expect
    {|
    error: `replay` is a test item, so only a test can use it
      ┌─ test.ren:2:8
    2 │   with replay("run.journal") in
      │        ^^^^^^
      = the prelude has it for tests only, and `ren run` leaves it out
      help: call it from a test; outside one, `ren replay <file.journal>` replays a recording
    |}]

(* ---- reading a journal ---- *)

let%expect_test "a journal's lines that can't be read are said at their line" =
  let load text =
    try ignore (Journal.load ~file:"run.journal" (clean text))
    with e ->
      Option.iter print_string
        (Driver.render_error ~sources:(fun _ -> Some (clean text)) e)
  in
  load "# ren journal 3 · main.ren · deps: Clock\n";
  load "# ren journal 2 · main.ren · deps: Clock\n1 main Clock.now( → 5\n";
  load "# ren journal 2 · main.ren · deps: Clock\n1 main now() → 5\n";
  load "# ren journal 2 · main.ren · deps: Clock\n1 main panic\n";
  (* a version 1 line, which names no task *)
  load "# ren journal 2 · main.ren · deps: Clock\n1 Clock.now() → 5\n";
  (* what a call gave, with no call waiting for it *)
  load "# ren journal 2 · main.ren · deps: Clock\n1 main → 5\n2 main exit 0\n";
  (* a call while its task waits in another *)
  load
    "# ren journal 2 · main.ren · deps: Clock\n\
     1 main Clock.sleep(5) …\n\
     2 main Clock.now() → 5\n\
     3 main exit 0\n";
  [%expect
    {|
    error: run.journal is a journal of version 3, and this ren reads version 2
      ┌─ run.journal:1:1
    1 │ # ren journal 3 · main.ren · deps: Clock
      │ ^
      help: record it again with this ren
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 main Clock.now( → 5
      │ ^
      help: a call is written `task Dep.op(arguments) → what it gave`, and the last line `main exit 0`, `main error` and the error, or `main panic`, where, and what it said in quotes
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 main now() → 5
      │ ^
      help: a call is written `task Dep.op(arguments) → what it gave`, and the last line `main exit 0`, `main error` and the error, or `main panic`, where, and what it said in quotes
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 main panic
      │ ^
      help: a call is written `task Dep.op(arguments) → what it gave`, and the last line `main exit 0`, `main error` and the error, or `main panic`, where, and what it said in quotes
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 Clock.now() → 5
      │ ^
      help: a call is written `task Dep.op(arguments) → what it gave`, and the last line `main exit 0`, `main error` and the error, or `main panic`, where, and what it said in quotes
    error: main isn't waiting in a call here
      ┌─ run.journal:2:1
    2 │ 1 main → 5
      │ ^
      help: a line `task → what it gave` ends the task's call that waits, whose first line ends `…`
    error: main makes this call while it waits in another
      ┌─ run.journal:3:1
    3 │ 2 main Clock.now() → 5
      │ ^
      help: a task's call that waits ends before its next one
    |}]

let%expect_test "the diff of a test's outputs" =
  List.iter print_endline
    (Journal.diff
       [ "a"; "b"; "c"; "d"; "e"; "f"; "g"; "h" ]
       [ "a"; "b"; "c"; "x"; "e"; "f"; "g"; "h"; "i" ]);
  [%expect
    {|
      b
      c
    - d
    + x
      e
      f
      g
      h
    + i
    |}]

(* ---- the audit (handlers.md, "Recording and replaying") ---- *)

let%expect_test "each intrinsic that reaches the world is an operation's" =
  List.iter
    (fun x ->
      match Prelude.reaches x with
      | Some (dep, op) ->
          Printf.printf "%-14s %s.%s, only in %s.real\n" (Intrinsic.name x) dep
            op dep
      | None -> ())
    Prelude.fns;
  [%expect
    {|
    clock_now      Clock.now, only in Clock.real
    clock_instant  Clock.instant, only in Clock.real
    clock_sleep    Clock.sleep, only in Clock.real
    random_int     Random.int, only in Random.real
    console_write  Console.write, only in Console.real
    console_error  Console.error, only in Console.real
    fs_read        Fs.read, only in Fs.real
    fs_write       Fs.write, only in Fs.real
    fs_exists      Fs.exists, only in Fs.real
    os_args        Os.args, only in Os.real
    proc_run       Proc.run, only in Proc.real
    net_listen     Net.listen, only in Net.real
    net_accept     Net.accept, only in Net.real
    net_accept_until Net.accept_until, only in Net.real
    net_read       Net.read, only in Net.real
    net_write      Net.write, only in Net.real
    net_close      Net.close, only in Net.real
    |}]

let%expect_test "Core Lint refuses the world reached from anywhere else" =
  let loc = Loc.point ~file 1 1 in
  let call x : Core.expr =
    Core.mk (Intrinsic (x, { tys = []; rows = [] }, [], [])) Ty.unit loc
  in
  let fn path ~test body : Core.fn_def =
    {
      path;
      params = [];
      ev = Core.evidence 2;
      tys = [];
      dicts = [];
      scheme = { ty = Ty.unit; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] };
      body;
      test;
      loc;
      origin = Written;
      known = [];
    }
  in
  let lint fns =
    try
      Core_lint.world
        {
          home = "test";
          types = [];
          fns;
          values = [];
          shows = [];
          keys = [];
          ops = [];
          method_calls = [];
        };
      print_endline "fine"
    with Failure msg -> print_endline msg
  in
  lint [ fn (Path.make "test" "main") ~test:false (call Clock_now) ];
  (* `Clock.real` is `real_clock()`, so the world is reached from the
     handler's arms *)
  lint [ fn (Path.prelude "real_clock") ~test:false (call Clock_now) ];
  lint [ fn (Path.prelude "real_fs") ~test:false (call Clock_now) ];
  lint [ fn (Path.make "test" "main") ~test:false (call Journal_load) ];
  lint [ fn (Path.make "test" "t") ~test:true (call Journal_load) ];
  [%expect
    {|
    Core Lint: in `main`, at test.ren:1:1: `clock_now` reaches the world, so only `Clock.real` can call it
    fine
    Core Lint: in `real_fs`, at test.ren:1:1: `clock_now` reaches the world, so only `Clock.real` can call it
    Core Lint: in `main`, at test.ren:1:1: `journal_load` reads a file, so only test code can call it
    fine
    |}]

(* a value is written so it reads back as itself: a `Float` too, `nan`
   and the infinities included *)
let%expect_test "a float reads back as it was written" =
  let types = Hashtbl.create 1 and float = Ty.Con (Path.prelude "Float", []) in
  List.iter
    (fun f ->
      let text = Journal.write types float (VFloat f) in
      match Journal.read_all types float text with
      | VFloat g when Float.equal f g -> print_endline (text ^ " reads back")
      | _ -> print_endline (text ^ " doesn't"))
    [ 1.5; -0.25; 1.25e-7; Float.infinity; Float.neg_infinity; Float.nan ];
  [%expect
    {|
    1.5 reads back
    -0.25 reads back
    0.000000125 reads back
    inf reads back
    -inf reads back
    nan reads back
    |}]

(* ---- how a run ended ---- *)

let%expect_test "an error or a panic with a newline in it stays on its line" =
  in_folder
    [
      ( "main.ren",
        {|
fn main() ! Broke(Str) uses Console =
  print(1)
  fail Broke("two\nlines")
|}
      );
    ]
    (fun () ->
      record ();
      replay "run.journal");
  let text =
    String.concat "\n"
      [
        "# ren journal 2 · main.ren · deps: Console";
        "1 main "
        ^ Journal.ending_text (Panicked { at = "main.ren:3:3"; msg = "a\nb" });
      ]
  in
  print_endline text;
  (match (Journal.load ~file:"run.journal" text).ending with
  | Some (Panicked { msg; _ }, _) -> print_endline ("read back: " ^ msg)
  | _ -> print_endline "not read back");
  [%expect
    {|
    1
    error: Broke("two\nlines")
    # ren journal 2 · main.ren · deps: Console
    1 main Console.write("1")
    2 main error Broke("two\nlines")
    1
    error: Broke("two\nlines")
    # ren journal 2 · main.ren · deps: Console
    1 main panic main.ren:3:3 "a\nb"
    read back: a
    b
    |}]

(* ---- what `replay` implements ---- *)

let%expect_test "`replay` implements only what the journal holds calls for" =
  in_folder
    [
      ( "main.ren",
        {|
pub fn main() uses Console =
  print("hi")

test "the rest are the test's" =
  with replay("run.journal"), mem_fs([]) in
    main()
    assert Clock.now() == Time.epoch
    assert Fs.exists(Path.of("x")) == false
|}
      );
      ( "run.journal",
        {|
# ren journal 2 · main.ren · deps: Console
1 main Console.write("hi")
2 main exit 0
|}
      );
    ]
    test;
  [%expect {|
    main.ren
      ✓ the rest are the test's

    1 passed
    |}]

let%expect_test "a replay of a journal of other dependencies is refused" =
  in_folder
    [
      ("main.ren", {|
fn main() uses Console, Clock =
  print("hi")
|});
      ( "run.journal",
        {|
# ren journal 2 · main.ren · deps: Console
1 main Console.write("hi")
2 main exit 0
|}
      );
    ]
    (fun () -> replay "run.journal");
  [%expect
    {|
    error: run.journal recorded a `main` that uses `Console`, and this one uses `Clock` and `Console`
      ┌─ run.journal:1:1
    1 │ # ren journal 2 · main.ren · deps: Console
      │ ^
      help: the code changed since this was recorded; record it again
    |}]

(* ---- a bug's recording as a test ---- *)

(* A program with a bug, an index past the end, at [at], which [first]
   prints before, and a test of its recording. *)
let buggy ?(first = "1") at =
  Printf.sprintf
    {|
pub fn main() ! Late uses Console, Clock =
  print(%s)
  let xs = [1]
  print(xs[%d])
  let t = Clock.now()
  if t > Time.epoch then fail Late
  print(2)

test "replays the bug" =
  with replay("run.journal") in
    try main()
|}
    first at

let%expect_test "a test of a bug's recording passes once the bug is fixed" =
  in_folder
    [ ("main.ren", buggy 3) ]
    (fun () ->
      record ();
      test ();
      (* fixed: it goes on past where the recording ended *)
      Out_channel.with_open_bin "main.ren" (fun oc ->
          output_string oc (clean (buggy 0)));
      test ();
      (* "fixed", but what it printed before the bug changed *)
      Out_channel.with_open_bin "main.ren" (fun oc ->
          output_string oc (clean (buggy ~first:"0" 0)));
      test ());
  [%expect
    {|
    1
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ main.ren:4:9
    4 │   print(xs[3])
      │         ^^^^^
    # ren journal 2 · main.ren · deps: Clock Console
    1 main Console.write("1")
    2 main panic main.ren:4:9 "index 3 is out of bounds for an array of length 1"
    main.ren
      ✗ replays the bug

    ──── replays the bug ── main.ren:4
      │
    4 │   print(xs[3])
      │         ^^^^^
      │
      panic: index 3 is out of bounds for an array of length 1

      seed 1 · rerun: ren test main.ren --only "replays the" --seed 1

    0 passed, 1 failed
    main.ren
      ✓ replays the bug

    1 passed
    main.ren
      ✗ replays the bug

    ──── replays the bug ── main.ren:5
      │
    5 │   let t = Clock.now()
      │           ^^^^^^^^^^^
      │
      the outputs differ from the recording's
      - Console.write("1")
      + Console.write("0")
      help: if the change is what you meant, record the run again, or edit the journal

      seed 1 · rerun: ren test main.ren --only "replays the" --seed 1

    0 passed, 1 failed
    |}]

(* ---- tasks: journal version 2 ---- *)

(* [s] cut at each [sep]. *)
let split_on sep s =
  let n = String.length sep in
  let rec go from i acc =
    if i + n > String.length s then List.rev (String.sub s from (String.length s - from) :: acc)
    else if String.sub s i n = sep then go (i + n) (i + n) (String.sub s from (i - from) :: acc)
    else go from (i + 1) acc
  in
  go 0 0 []

(* Two tasks that sleep, the second for less time, so it wakes first. *)
let sleepers =
  {|
fn work(name: Str, ms: Int) uses Console, Clock =
  Console.error(name)
  Clock.sleep(Duration.ms(ms))
  print(name)

pub fn main() uses Console, Clock, Async =
  Async.scope fn(s) =>
    s.spawn fn() => work("slow", 40)
    s.spawn fn() => work("fast", 5)
  print("done")

test "the recording replays" =
  with replay("run.journal") in
    main()
|}

let%expect_test "each entry names its task, and a call that waits is two lines" =
  in_folder [ ("main.ren", sleepers) ] (fun () ->
      record ();
      replay "run.journal");
  [%expect
    {|
    slow
    fast
    fast
    slow
    done
    # ren journal 2 · main.ren · deps: Clock Console
    1 main/main:0 Console.error("slow")
    2 main/main:0 Clock.sleep(40) …
    3 main/main:1 Console.error("fast")
    4 main/main:1 Clock.sleep(5) …
    5 poll main/main:1
    6 main/main:1 →
    7 main/main:1 Console.write("fast")
    8 poll main/main:0
    9 main/main:0 →
    10 main/main:0 Console.write("slow")
    11 main Console.write("done")
    12 main exit 0
    slow
    fast
    fast
    slow
    done
    replayed 7 calls
    |}]

(* the same run, but with its polls the other way round *)
let swapped =
  {|# ren journal 2 · main.ren · deps: Clock Console
1 main/main:0 Console.error("slow")
2 main/main:0 Clock.sleep(40) …
3 main/main:1 Console.error("fast")
4 main/main:1 Clock.sleep(5) …
5 poll main/main:0
6 main/main:0 →
7 main/main:0 Console.write("slow")
8 poll main/main:1
9 main/main:1 →
10 main/main:1 Console.write("fast")
11 main Console.write("done")
12 main exit 0
|}

let%expect_test "a replay follows the recording's polls, not the clock" =
  in_folder [ ("main.ren", sleepers); ("run.journal", swapped) ] (fun () ->
      replay "run.journal");
  [%expect
    {|
    slow
    fast
    slow
    fast
    done
    replayed 7 calls
    |}]

let%expect_test "a poll that wakes a task that isn't waiting went differently" =
  let text =
    String.concat "\n"
      (List.map
         (fun l -> if l = "8 poll main/main:1" then "8 poll main/main:0" else l)
         (String.split_on_char '\n' swapped))
  in
  in_folder [ ("main.ren", sleepers); ("run.journal", text) ] (fun () ->
      replay "run.journal");
  [%expect
    {|
    slow
    fast
    slow
    error: the replay went differently at call 6 of 7
      ┌─ run.journal:9:1
    9 │ 8 poll main/main:0
      │ ^
      = the recording has: poll main/main:0
      = this program has: main/main:0 waiting for nothing a poll ends
      help: the code changed since this was recorded; record it again
    |}]

let%expect_test "a replay that makes a call of another task went differently" =
  let text =
    String.concat "\n"
      (List.map
         (fun l ->
           if l = "1 main/main:0 Console.error(\"slow\")" then
             "1 main/main:1 Console.error(\"slow\")"
           else l)
         (String.split_on_char '\n' swapped))
  in
  in_folder [ ("main.ren", sleepers); ("run.journal", text) ] (fun () ->
      replay "run.journal");
  [%expect
    {|
    error: the replay went differently at call 1 of 7
      ┌─ main.ren:2:3
    2 │   Console.error(name)
      │   ^^^^^^^^^^^^^^^^^^^
      = the recording has: main/main:1 Console.error("slow")
      = this program made: main/main:0 Console.error("slow")
      help: the code changed since this was recorded; record it again
    |}]

let%expect_test "a test of the recording follows its order, and keys answers by task" =
  in_folder [ ("main.ren", sleepers); ("run.journal", swapped) ] (fun () ->
      test ~seeds:100 ());
  [%expect {|
    main.ren
      ✓ the recording replays

    1 passed, each under 100 seeds
    |}]

let%expect_test "a test's outputs are compared task by task" =
  in_folder
    [
      ( "main.ren",
        String.concat "print(name.concat(\"!\"))" (split_on "print(name)" sleepers)
      );
      ("run.journal", swapped);
    ]
    test;
  [%expect {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:13
       │
    13 │   with replay("run.journal") in
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       the outputs differ from the recording's
         main/main:0 Console.error("slow")
         main/main:0 Clock.sleep(40)
       - main/main:0 Console.write("slow")
       + main/main:0 Console.write("slow!")
         main/main:1 Console.error("fast")
         main/main:1 Clock.sleep(5)
       - main/main:1 Console.write("fast")
       + main/main:1 Console.write("fast!")
         Console.write("done")
       help: if the change is what you meant, record the run again, or edit the journal

       seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

(* Two tasks that take turns at a counter: which gets 1 depends only on
   the order they ran in. *)
let turns journal =
  {|
dep Count =
  bump: fn() -> Int

handler counter() for Count =
  var n = 0
  bump() =>
    n = n + 1
    n

fn turn(name: Str) uses Console, Count =
  Console.error(name)
  print((name, Count.bump()))

pub fn main() uses Console, Async =
  with counter() in
    Async.scope fn(s) =>
      s.spawn fn() => turn("a")
      s.spawn fn() => turn("b")

test "the recording replays" =
  with replay("|} ^ journal ^ {|") in
    main()
|}

let%expect_test "a test runs in the recorded order while it can" =
  in_folder [ ("main.ren", turns "run.journal") ] (fun () ->
      record ();
      test ~seeds:300 ());
  [%expect {|
    a
    ("a", 1)
    b
    ("b", 2)
    # ren journal 2 · main.ren · deps: Console
    1 main/main:0 Console.error("a")
    2 main/main:0 Console.write("(\"a\", 1)")
    3 main/main:1 Console.error("b")
    4 main/main:1 Console.write("(\"b\", 2)")
    5 main exit 0
    main.ren
      ✓ the recording replays

    1 passed, each under 300 seeds
    |}]

let%expect_test "then the seeded tape takes over" =
  (* `b` went first here, which `single`'s order never does, so the order
     isn't the recording's from its first call, and each seed's is its
     own: some pass, and some fail *)
  let journal =
    {|# ren journal 2 · main.ren · deps: Console
1 main/main:1 Console.error("b")
2 main/main:1 Console.write("(\"b\", 1)")
3 main/main:0 Console.error("a")
4 main/main:0 Console.write("(\"a\", 2)")
5 main exit 0
|}
  in
  in_folder [ ("main.ren", turns "b.journal"); ("b.journal", journal) ] (fun () ->
      test ~seeds:300 ());
  [%expect {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── main.ren:21
       │
    21 │   with replay("b.journal") in
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       the outputs differ from the recording's
         main/main:1 Console.error("b")
       - main/main:1 Console.write("(\"b\", 1)")
       + main/main:1 Console.write("(\"b\", 2)")
         main/main:0 Console.error("a")
       - main/main:0 Console.write("(\"a\", 2)")
       + main/main:0 Console.write("(\"a\", 1)")
       help: if the change is what you meant, record the run again, or edit the journal

       seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    |}]

let%expect_test "a timeout's cancel, and a failure while cancelled, are recorded" =
  in_folder
    [
      ( "main.ren",
        {|
// the margins are wide, since a real timer can wake tens of
// milliseconds late (macOS coalesces them): a's nap ends in its own
// poll, well before the timeout's
fn nap(name: Str, ms: Int) uses Console, Clock, Async =
  let r = attempt Async.timeout(Duration.ms(200)) fn() =>
    Clock.sleep(Duration.ms(ms))
  match r
    Ok(_) => print(name.concat(" in time"))
    Err(_) => print(name.concat(" late"))

fn fails(ms: Int) ! Broke uses Clock =
  Clock.sleep(Duration.ms(ms))
  fail Broke

fn main() ! Broke uses Console, Clock, Async =
  let _ = Async.both(fn() => nap("a", 5), fn() => nap("b", 2000))
  let _ = try Async.both(fn() => try fails(5), fn() => try fails(5))
  print("not reached")
|} );
    ]
    (fun () ->
      record ();
      replay "run.journal");
  [%expect {|
    a in time
    b late
    warning: main/main:3 failed too, with `Broke`, while it was being cancelled
    error: Broke
      = from the task main/main:2
    # ren journal 2 · main.ren · deps: Clock Console
    1 main/main:0 Clock.sleep(5) …
    2 main/main:1 Clock.sleep(2000) …
    3 poll main/main:0
    4 main/main:0 →
    5 main/main:0 Console.write("a in time")
    6 poll main/main:1
    7 main/main:1 cancelled
    8 main/main:1 Console.write("b late")
    9 main/main:2 Clock.sleep(5) …
    10 main/main:3 Clock.sleep(5) …
    11 poll main/main:2 main/main:3
    12 main/main:2 →
    13 main/main:3 →
    # warning: main/main:3 failed too, with `Broke`, while it was being cancelled
    14 main error Broke
    a in time
    b late
    warning: main/main:3 failed too, with `Broke`, while it was being cancelled
    error: Broke
      = from the task main/main:2
    |}]

let%expect_test "a version 1 journal is refused" =
  in_folder
    [
      ("main.ren", reader ());
      ( "run.journal",
        "# ren journal 1 · main.ren · deps: Clock Console Fs\n1 exit 0\n" );
    ]
    (fun () ->
      test ();
      replay "run.journal");
  [%expect {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── run.journal:1
      │
    1 │ # ren journal 1 · main.ren · deps: Clock Console Fs
      │ ^
      │
      error: `run.journal` is a version 1 journal, which this `ren` doesn't read
      help: record it again: `ren run --record run.journal main.ren`

      seed 1 · rerun: ren test main.ren --only "the recording" --seed 1

    0 passed, 1 failed
    error: `run.journal` is a version 1 journal, which this `ren` doesn't read
      = version 2 names the task that made each call
      help: record it again: `ren run --record run.journal main.ren`
    |}]
