The journal (handlers.md, "The journal"): `ren run --record` writes each
call a program makes to the world, and what it gave, and `ren replay`
runs the program again on what was recorded.

  $ cat > dice.ren <<'END'
  > fn main() uses Clock, Random, Console =
  >   let t = Clock.now()
  >   let roll = Random.int(6)
  >   print(roll)
  >   let xs = [1, 2]
  >   print(xs[roll + 2])
  > END
  $ ren run --record dice.journal dice.ren 2>&1 | sed -e 's/^[0-9]$/N/' -e 's/index [0-9]/index N/'
  N
  recorded 3 calls to dice.journal (Clock 1, Console 1, Random 1)
  warning: dice.journal holds everything the program read, files and arguments included: read it before you share it
  error: panic: index N is out of bounds for an array of length 2
    ┌─ dice.ren:6:9
  6 │   print(xs[roll + 2])
    │         ^^^^^^^^^^^^

A panic is the journal's last entry, and a replay panics again, at the
same place:

  $ sed -e 's/→ [0-9]*$/→ N/' -e 's/index [0-9]/index N/' -e 's/write("[0-9]")/write("N")/' dice.journal
  # ren journal 3 · dice.ren · deps: Clock Console Random
  1 main Clock.now() → N
  2 main Random.int(6) → N
  3 main Console.write("N")
  4 main panic dice.ren:6:9 "index N is out of bounds for an array of length 2"
  $ ren replay dice.journal 2>&1 | sed -e 's/index [0-9]/index N/' -e 's/^[0-9]$/N/'
  N
  replayed 3 calls, to the panic it ended in: nothing touched the disk, and nothing ran
  error: panic: index N is out of bounds for an array of length 2
    ┌─ dice.ren:6:9
  6 │   print(xs[roll + 2])
    │         ^^^^^^^^^^^^

A journal is text, and can be written by hand. What the recording says
a call gave is what the program gets, even a roll of 6, which the real
`Random.int(6)` never gives:

  $ cat > six.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main Random.int(6) → 6
  > 3 main Console.write("6")
  > 4 main panic dice.ren:6:9 "index 8 is out of bounds for an array of length 2"
  > END
  $ ren replay six.journal
  6
  replayed 3 calls, to the panic it ended in: nothing touched the disk, and nothing ran
  error: panic: index 8 is out of bounds for an array of length 2
    ┌─ dice.ren:6:9
  6 │   print(xs[roll + 2])
    │         ^^^^^^^^^^^^
  [1]

A panic inside a call to the world is recorded where the call was made,
and the replay panics at that call:

  $ cat > fire.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main panic dice.ren:3:14 "the dice caught fire"
  > END
  $ ren replay fire.journal
  replayed 1 call, to the panic it ended in: nothing touched the disk, and nothing ran
  error: panic: the dice caught fire
    ┌─ dice.ren:3:14
  3 │   let roll = Random.int(6)
    │              ^^^^^^^^^^^^^
  [1]

A call past the recording's end anywhere else isn't where it panicked:
the program went on past it, and the replay went differently:

  $ cat > early.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main panic dice.ren:2:11 "the clock stopped"
  > END
  $ ren replay early.journal
  error: the program went on past the recording's end, after call 1
    ┌─ dice.ren:3:14
  3 │   let roll = Random.int(6)
    │              ^^^^^^^^^^^^^
    = the recording has: panic at dice.ren:2:11: the clock stopped
    = this program made: Random.int(6)
    help: the code changed since this was recorded; record it again
  [1]

A replay that ends differently from the recording stops, at the
recording's end:

  $ cat > short.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main Random.int(6) → 6
  > 3 main Console.write("6")
  > 4 main exit 0
  > END
  $ ren replay short.journal
  6
  error: the replay went differently after call 3 of 3
    ┌─ short.journal:5:1
  5 │ 4 main exit 0
    │ ^
    = the recording has: the end, `exit 0`
    = this program ended instead, in a panic at dice.ren:6:9: index 8 is out of bounds for an array of length 2
    help: the code changed since this was recorded; record it again
  [1]

  $ cat > out.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main exit 0
  > END
  $ ren replay out.journal
  error: the program went on past the recording's end, after call 1
    ┌─ dice.ren:3:14
  3 │   let roll = Random.int(6)
    │              ^^^^^^^^^^^^^
    = the recording has: the end, `exit 0`
    = this program made: Random.int(6)
    help: the code changed since this was recorded; record it again
  [1]

An entry that can't be read as what its call gives is said at its line:

  $ cat > bad.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now() → 0
  > 2 main Random.int(6) → "six"
  > 3 main exit 0
  > END
  $ ren replay bad.journal
  error: this entry can't be read as an `Int`
    ┌─ bad.journal:3:1
  3 │ 2 main Random.int(6) → "six"
    │ ^
    help: record the run again, or write the value as it's recorded
  [1]

A journal without its last line, how the run ended, was cut short,
so a replay couldn't say whether the run ended as it did:

  $ head -3 bad.journal > cut.journal
  $ ren replay cut.journal
  error: cut.journal doesn't say how the run ended
    ┌─ cut.journal:3:1
  3 │ 2 main Random.int(6) → "six"
    │ ^
    = its last line is how the run ended: `main exit 0`, `main error ...` or `main panic ...`
    help: record the run again, to its end
  [1]

  $ printf 'hello\n' > not.journal
  $ ren replay not.journal
  error: not.journal isn't a journal: it doesn't start as one does
    ┌─ not.journal:1:1
  1 │ hello
    │ ^
    = a journal starts `# ren journal 3 · <program> · deps: <dependencies>`
    help: record one with `ren run --record <file.journal> <file.ren>`
  [1]

  $ sed 's/dice.ren/gone.ren/' six.journal > gone.journal
  $ ren replay gone.journal
  error: the program gone.journal recorded, gone.ren, isn't there: a journal's program is found from the journal's folder
  [1]

  $ ren run --record dice.ren
  error: --record needs the file to write the journal to, like --record run.journal
  [2]
  $ ren run --record nowhere/dice.journal dice.ren
  error: can't write the journal nowhere/dice.journal: there's no folder nowhere
  [1]
  $ ren replay nofile.journal
  error: there's no journal nofile.journal
    help: record one with `ren run --record <file.journal> <file.ren>`
  [1]

A program that doesn't check runs nothing, so nothing is recorded:

  $ echo 'fn main() = 1 + "a"' > wrong.ren
  $ ren run --record wrong.journal wrong.ren 2>/dev/null
  [1]
  $ test -e wrong.journal
  [1]

`--trace` shows the calls to the program's own dependencies too, each
under the call that made it:

  $ cat > greet.ren <<'END'
  > dep Names =
  >   name: fn(id: Int) -> Str
  > 
  > handler console_names() for Names uses Console =
  >   name(id) =>
  >     print(id)
  >     "Ada"
  > 
  > fn main() uses Console =
  >   with console_names() in
  >     Console.write("hello " + Names.name(1))
  > END
  $ REN_NO_TIMINGS=1 ren run --trace greet.ren
  1
  hello Ada
  main
  ├─ Names.name(1)               → "Ada"
  │  └─ Console.write("1")
  └─ Console.write("hello Ada")

`ren test --keep` writes a test that calls `main`, which a test can
only do if it's public:

  $ ren test --keep six.journal
  error: `main` in dice.ren is private, and a test sees what an importer sees
    help: make it `pub fn main()`, so the test can call it
  [1]
  $ ren test --keep nothing.journal
  error: there's no journal nothing.journal
    help: record one with `ren run --record <file.journal> <file.ren>`
  [1]

A failed `assert` is a panic too: the run started, so its journal is
kept, ending in it, and the trace is printed:

  $ cat > sure.ren <<'END'
  > fn main() uses Console =
  >   print("before")
  >   assert 1 == 2
  > END
  $ REN_NO_TIMINGS=1 ren run --record sure.journal --trace sure.ren
  before
  main
  └─ Console.write("before")
  recorded 1 call to sure.journal (Console 1)
  warning: sure.journal holds everything the program read, files and arguments included: read it before you share it
  error: panic: this `assert` failed
    ┌─ sure.ren:3:10
  3 │   assert 1 == 2
    │          ^^^^^^
    = left:  1
    = right: 2
  [1]
  $ cat sure.journal
  # ren journal 3 · sure.ren · deps: Console
  1 main Console.write("before")
  2 main panic sure.ren:3:10 "this `assert` failed"
  $ REN_NO_TIMINGS=1 ren replay sure.journal --trace
  before
  main
  └─ Console.write("before")
  replayed 1 call, to the panic it ended in: nothing touched the disk, and nothing ran
  error: panic: this `assert` failed
    ┌─ sure.ren:3:10
  3 │   assert 1 == 2
    │          ^^^^^^
    = left:  1
    = right: 2
  [1]

The flags of `ren run` come before or after the file, but before `--`:

  $ REN_NO_TIMINGS=1 ren run sure.ren --trace 2>&1 | head -3
  before
  main
  └─ Console.write("before")
  $ ren run sure.ren dice.ren
  error: `ren run` runs one file, and dice.ren is a second
    help: the program's arguments go after `--`, like `ren run main.ren -- dice.ren`
  [2]
  $ ren run --bogus sure.ren 2>&1 | head -1
  error: `ren run` has no option --bogus

A replay runs on the arguments the journal recorded:

  $ ren replay sure.journal -- more
  error: a replay runs on the arguments the journal recorded, so it can't be given others
    help: record the run again with the arguments you want: `ren run --record <file.journal> <file.ren> -- <args>...`
  [2]

An entry for a call whose result the program uses has to say what it
gave:

  $ cat > mute.journal <<'END'
  > # ren journal 3 · dice.ren · deps: Clock Console Random
  > 1 main Clock.now()
  > 2 main exit 0
  > END
  $ ren replay mute.journal
  error: this entry gives nothing back, but the call gives a `Time`
    ┌─ mute.journal:2:1
  2 │ 1 main Clock.now()
    │ ^
    help: record the run again, or write the value as it's recorded
  [1]

`ren test --keep` takes one journal, of a program with a `main`:

  $ ren test --keep six.journal fire.journal
  error: --keep needs the journal to keep, and nothing else, like --keep bug.journal
  [2]
  $ echo 'pub fn f() = 1' > lib.ren
  $ sed 's/dice.ren/lib.ren/' six.journal > lib.journal
  $ ren test --keep lib.journal
  error: lib.ren has no `main` for a test to run
  [1]

A journal's header names the program from the journal's folder, unless
that's more than two folders up, when it's absolute:

  $ mkdir -p a/b/c && ren run --record a/b/near.journal sure.ren > /dev/null 2>&1
  [1]
  $ head -1 a/b/near.journal
  # ren journal 3 · ../../sure.ren · deps: Console
  $ ren run --record a/b/c/far.journal sure.ren > /dev/null 2>&1
  [1]
  $ head -1 a/b/c/far.journal | sed -E 's|· /.+/sure.ren|· /.../sure.ren|'
  # ren journal 3 · /.../sure.ren · deps: Console
  $ ren replay a/b/c/far.journal 2>&1 | head -2
  before
  replayed 1 call, to the panic it ended in: nothing touched the disk, and nothing ran

A journal is version 3 (compiler.md, "Journal version 2" and "Journal
version 3"): each entry
names the task that made it, a call that its task waited in is two
lines, its start, which ends `…`, and what it gave, after the poll that
woke it, and each poll that woke tasks is a line. Here a level of
recipes runs at once, as the `just`'s do, each sleeping a while first, a
tenth of a second apart, so the order they end in is the same each run;
`Proc.run` waits for its program as `Clock.sleep` waits:

  $ cat > recipes.ren <<'END'
  > type Recipe = { line: Str, takes: Int }
  > 
  > fn run(r: Recipe) ! ProcError | Failed(line: Str) uses Proc, Console, Clock =
  >   Console.error(r.line)
  >   Clock.sleep(Duration.ms(r.takes))
  >   let code = try Proc.run("sh", ["-c", r.line])
  >   if code != 0 then fail Failed(r.line)
  >   print("ran " + r.line)
  > 
  > fn main() ! ProcError | Failed(line: Str) uses Proc, Console, Clock, Async, Os =
  >   let slow = Os.args().len() > 0
  >   let level = [
  >     Recipe { line: "true", takes: 300 },
  >     Recipe { line: if slow then "false" else "exit 0", takes: 100 },
  >     Recipe { line: "test 1 = 1", takes: 200 }
  >   ]
  >   try Async.each(level, max: 8) fn(r) => try run(r)
  >   print("all ran")
  > END
  $ ren run --record level.journal recipes.ren > run.out 2>&1
  $ cat level.journal
  # ren journal 3 · recipes.ren · deps: Clock Console Os Proc
  1 main Os.args() → []
  2 main/main:0 Console.error("true")
  3 main/main:0 Clock.sleep(300) …
  4 main/main:1 Console.error("exit 0")
  5 main/main:1 Clock.sleep(100) …
  6 main/main:2 Console.error("test 1 = 1")
  7 main/main:2 Clock.sleep(200) …
  8 poll main/main:1
  9 main/main:1 →
  10 main/main:1 Proc.run("sh", ["-c", "exit 0"], Tree) …
  11 poll main/main:1
  12 main/main:1 → Ok(0)
  13 main/main:1 Console.write("ran exit 0")
  14 poll main/main:2
  15 main/main:2 →
  16 main/main:2 Proc.run("sh", ["-c", "test 1 = 1"], Tree) …
  17 poll main/main:2
  18 main/main:2 → Ok(0)
  19 main/main:2 Console.write("ran test 1 = 1")
  20 poll main/main:0
  21 main/main:0 →
  22 main/main:0 Proc.run("sh", ["-c", "true"], Tree) …
  23 poll main/main:0
  24 main/main:0 → Ok(0)
  25 main/main:0 Console.write("ran true")
  26 main Console.write("all ran")
  27 main exit 0

`ren replay` follows the polls, so its tasks run in the recorded order,
and it prints what the run printed, byte for byte, but its own last
line:

  $ ren replay level.journal > replay.out 2>&1
  $ diff run.out replay.out
  8,9c8
  < recorded 14 calls to level.journal (Clock 3, Console 7, Os 1, Proc 3)
  < warning: level.journal holds everything the program read, files and arguments included: read it before you share it
  ---
  > replayed 14 calls: nothing touched the disk, and nothing ran
  [1]

When a recipe fails, the others are cancelled where they wait, and each
cancel a task saw is a line too; the replay sees them where the
recording did:

  $ ren run --record failed.journal recipes.ren -- slow > run.out 2>&1
  [1]
  $ sed -n '9,16p' failed.journal
  8 poll main/main:1
  9 main/main:1 →
  10 main/main:1 Proc.run("sh", ["-c", "false"], Tree) …
  11 poll main/main:1
  12 main/main:1 → Ok(1)
  13 main/main:0 cancelled
  14 main/main:2 cancelled
  15 main error Failed("false")
  $ ren replay failed.journal > replay.out 2>&1
  [1]
  $ diff run.out replay.out
  4,5c4
  < recorded 8 calls to failed.journal (Clock 3, Console 3, Os 1, Proc 1)
  < warning: failed.journal holds everything the program read, files and arguments included: read it before you share it
  ---
  > replayed 8 calls, to the error it ended in: nothing touched the disk, and nothing ran
  [1]

A replay is strict about the order too: with the first two polls the
other way round, it wakes the tasks in another order, and stops at the
first call's end that isn't the recording's next:

  $ perl -pi -e 's/^8 poll main\/main:1/8 poll main\/main:2/; s/^14 poll main\/main:2/14 poll main\/main:1/' level.journal
  $ ren replay level.journal
  true
  exit 0
  test 1 = 1
  error: the replay went differently at call 8 of 14
    ┌─ recipes.ren:5:3
  5 │   Clock.sleep(Duration.ms(r.takes))
    │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    = the recording has: main/main:1 →, the end of its call
    = this program made: main/main:2 →, the end of its call
    help: the code changed since this was recorded; record it again
  [1]
