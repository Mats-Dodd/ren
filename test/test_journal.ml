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
  with e -> show_error e

(* `ren test main.ren`. *)
let test () =
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
             timings = false;
           }
         ~sources suite)
  with e -> show_error e

let%expect_test "a recording is the calls, what each gave, and how it ended" =
  in_folder
    [
      ( "main.ren",
        {|
fn main() ! FsError | InvalidUtf8 uses Fs, Os, Console =
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
    # ren journal 1 · main.ren · deps: Console Fs Os
    1 Os.args() → ["x y"]
    2 Fs.write("out.txt", "a\"b\tc\n")
    3 Fs.read("out.txt") → Ok("a\"b\tc\n")
    4 Console.write("a\"b\tc\n")
    5 Console.error("done")
    6 exit 0
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
    # ren journal 1 · main.ren · deps: Fs
    1 Fs.read("nothing") → Err(NoSuchFile("nothing"))
    2 error NoSuchFile("nothing")
    1
    error: panic: index 3 is out of bounds for an array of length 1
      ┌─ main.ren:4:9
    4 │   print(xs[3])
      │         ^^^^^
    # ren journal 1 · main.ren · deps: Console
    1 Console.write("1")
    2 panic main.ren:4:9 "index 3 is out of bounds for an array of length 1"
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
    # ren journal 1 · main.ren · deps: Console Fs
    1 Fs.read("in.bin") → Ok("\xff\x01ok")
    2 Console.write("4")
    3 exit 0
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
pub fn main() ! FsError | InvalidUtf8 uses Fs, Clock, Console =
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
       "# ren journal 1 · main.ren · deps: Clock Console Fs";
       {|1 Fs.read("a") → Ok("one")|};
       {|2 Clock.now() → 10|};
       {|3 Console.write("one")|};
       {|4 Fs.read("b") → Ok("two")|};
       {|5 Clock.now() → 15|};
       {|6 Console.write("two")|};
       {|7 Console.error("done")|};
       {|8 exit 0|};
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
            "# ren journal 1 · main.ren · deps: Clock Console Fs";
            {|1 Fs.read("a") → Ok(<redacted>)|};
            "2 exit 0";
          ] );
    ]
    test;
  in_folder
    [
      ("main.ren", reader ());
      ( "run.journal",
        String.concat "\n"
          [
            "# ren journal 1 · main.ren · deps: Clock Console Fs";
            {|1 Fs.read("a") → Ok(5)|};
            "2 exit 0";
          ] );
    ]
    test;
  [%expect
    {|
    main.ren
      ✗ the recording replays

    ──── the recording replays ── run.journal:2
      │
    2 │ 1 Fs.read("a") → Ok(<redacted>)
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
    2 │ 1 Fs.read("a") → Ok(5)
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
  load "# ren journal 2 · main.ren · deps: Clock\n";
  load "# ren journal 1 · main.ren · deps: Clock\n1 Clock.now( → 5\n";
  load "# ren journal 1 · main.ren · deps: Clock\n1 now() → 5\n";
  load "# ren journal 1 · main.ren · deps: Clock\n1 panic\n";
  [%expect
    {|
    error: run.journal is a journal of version 2, and this ren reads version 1
      ┌─ run.journal:1:1
    1 │ # ren journal 2 · main.ren · deps: Clock
      │ ^
      help: record it again with this ren
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 Clock.now( → 5
      │ ^
      help: a call is written `Dep.op(arguments) → what it gave`, and the last line `exit 0`, `error` and the error, or `panic`, where, and what it said in quotes
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 now() → 5
      │ ^
      help: a call is written `Dep.op(arguments) → what it gave`, and the last line `exit 0`, `error` and the error, or `panic`, where, and what it said in quotes
    error: this line of run.journal isn't a call or how the run ended
      ┌─ run.journal:2:1
    2 │ 1 panic
      │ ^
      help: a call is written `Dep.op(arguments) → what it gave`, and the last line `exit 0`, `error` and the error, or `panic`, where, and what it said in quotes
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
      scheme = { ty = Ty.unit; names = []; reqs = []; row_reqs = [] };
      body;
      test;
      loc;
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
        "# ren journal 1 · main.ren · deps: Console";
        "1 "
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
    # ren journal 1 · main.ren · deps: Console
    1 Console.write("1")
    2 error Broke("two\nlines")
    1
    error: Broke("two\nlines")
    # ren journal 1 · main.ren · deps: Console
    1 panic main.ren:3:3 "a\nb"
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
# ren journal 1 · main.ren · deps: Console
1 Console.write("hi")
2 exit 0
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
# ren journal 1 · main.ren · deps: Console
1 Console.write("hi")
2 exit 0
|}
      );
    ]
    (fun () -> replay "run.journal");
  [%expect
    {|
    error: run.journal recorded a `main` that uses `Console`, and this one uses `Clock` and `Console`
      ┌─ run.journal:1:1
    1 │ # ren journal 1 · main.ren · deps: Console
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
    # ren journal 1 · main.ren · deps: Clock Console
    1 Console.write("1")
    2 panic main.ren:4:9 "index 3 is out of bounds for an array of length 1"
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
