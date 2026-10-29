The small just (just/README.md) on the real `Fs`, `Os` and `Proc`: it reads
the `justfile` in the folder it's run from, and runs each line with `sh -c`.
With no args it runs the first recipe, after what it depends on, and `base`,
which two of those depend on, runs once. The recipes run in levels, each
level's at once: `build` and `test` need only `base`, so they run together,
and `test` sleeps first, so `build` has printed by then. What the recipes
print:

  $ cd just
  $ ren run main.ren 2>/dev/null
  base
  building
  built
  testing
  all done

Each line is shown before it runs, as just shows it, on stderr: `test`'s
first line, `sleep 0.5`, is shown while `build` runs, since both run at
once:

  $ ren run main.ren 2>&1 >/dev/null
  echo base
  echo building
  sleep 0.5
  echo built
  echo testing
  echo all done

What follows `--` names the recipe:

  $ ren run main.ren -- test
  echo base
  base
  sleep 0.5
  echo testing
  testing

  $ ren run main.ren -- test 2>/dev/null
  base
  testing

The first line that exits with anything but 0 stops it, and `main` fails
with why, so the process exits with 1; the error came from the task that
ran the recipe, which it says:

  $ ren run main.ren -- broken
  echo base
  base
  echo trying
  trying
  exit 3
  error: RecipeFailed("broken", 3)
    = from the task main/run_all:1
  [1]

And it stops the recipes running beside it: `ci` needs `broken` and `slow`,
one level, and when `broken` fails, `slow`'s `sleep 5` is killed and waited
for, so the run ends at once, and leaves nothing running:

  $ start=$(date +%s)
  $ ren run main.ren -- ci 2>&1 >/dev/null
  echo base
  echo trying
  exec sleep 5
  exit 3
  error: RecipeFailed("broken", 3)
    = from the task main/run_all:1
  [1]
  $ [ $(( $(date +%s) - start )) -lt 4 ] && echo "at once"
  at once

  $ ren run main.ren -- deploy
  error: UnknownRecipe("deploy")
  [1]

  $ cd .. && ren run just/main.ren
  error: NoSuchFile(justfile)
  [1]

Its tests run on the test implementations, with no `with` but where a test
needs a justfile, args, or a program that fails, and one from a journal
of a real run, checked in (below):

  $ ren test just | tail -1 | sed 's/[0-9]*ms$/Nms/'
  21 passed in Nms

`Justfile.parse` refuses a justfile with a bad line or a recipe twice,
so `Justfile` keeps rules and is opaque, read through `recipes()`. With
its fields open, anyone could make one `parse` would refuse:

  $ cp -rL just j1 && perl -0pi -e 's/pub type Justfile = opaque \{/pub type Justfile = {/; s/  pub fn recipes\(self\)[^\n]*\n//' j1/justfile.ren && perl -pi -e 's/j\.recipes\(\)/j.recipes/g' j1/*.ren
  $ ren check j1/main.ren
  error: `Justfile` is open, so `parse` can't refuse to make one
     ┌─ j1/justfile.ren:14:10
  14 │   pub fn parse(text: Str) -> Justfile ! BadLine(number: Int) | DuplicateRecipe(name: Str) =
     │          ^^^^^
     = anyone can make an open type's values without calling `parse`, so what it checks isn't a rule
     help: hide its fields: `pub type Justfile = opaque { recipes: Array<Recipe> }`
  [1]

`ren run --record` writes each call `main` makes to the world, and what
it gave, to a journal, one a line, and how the run ended after them. It
says what it recorded, and that the journal holds what the program read:

  $ cp -rL just rec && chmod -R u+w rec && cd rec
  $ ren run --record build.journal main.ren -- build
  echo base
  base
  echo building
  building
  echo built
  built
  recorded 8 calls to build.journal (Console 3, Fs 1, Os 1, Proc 3)
  warning: build.journal holds everything the program read, files and arguments included: read it before you share it
  $ sed 's/Ok(".*")$/Ok("...")/' build.journal
  # ren journal 2 · main.ren · deps: Console Fs Os Proc
  1 main Fs.read("justfile") → Ok("...")
  2 main Os.args() → ["build"]
  3 main/run_all:0 Console.error("echo base")
  4 main/run_all:0 Proc.run("sh", ["-c", "echo base"]) …
  5 poll main/run_all:0
  6 main/run_all:0 → Ok(0)
  7 main/run_all:1 Console.error("echo building")
  8 main/run_all:1 Proc.run("sh", ["-c", "echo building"]) …
  9 poll main/run_all:1
  10 main/run_all:1 → Ok(0)
  11 main/run_all:1 Console.error("echo built")
  12 main/run_all:1 Proc.run("sh", ["-c", "echo built"]) …
  13 poll main/run_all:1
  14 main/run_all:1 → Ok(0)
  15 main exit 0

Recipes run at once are recorded with the task that made each call, and
the poll that ended each wait, so `ren replay` runs the tasks in the order
they ran, and shows what the run showed, byte for byte, but for the line
that says what it did:

  $ ren run --record all.journal main.ren > /dev/null 2> run.err
  $ ren=$(command -v ren) && PATH=/nowhere "$ren" replay all.journal > /dev/null 2> replay.err
  $ diff run.err replay.err
  7,8c7
  < recorded 14 calls to all.journal (Console 6, Fs 1, Os 1, Proc 6)
  < warning: all.journal holds everything the program read, files and arguments included: read it before you share it
  ---
  > replayed 14 calls: nothing touched the disk, and nothing ran
  [1]
  $ grep -c poll all.journal
  6

So does one where a recipe fails and the one beside it is killed: the
recording says where the killed one saw its cancel, and the replay sees
it there:

  $ ren run --record ci.journal main.ren -- ci > /dev/null 2> run.err
  [1]
  $ grep cancelled ci.journal
  17 main/run_all:2 cancelled
  $ ren=$(command -v ren) && PATH=/nowhere "$ren" replay ci.journal > /dev/null 2> replay.err
  [1]
  $ diff run.err replay.err
  5,6c5
  < recorded 10 calls to ci.journal (Console 4, Fs 1, Os 1, Proc 4)
  < warning: ci.journal holds everything the program read, files and arguments included: read it before you share it
  ---
  > replayed 10 calls, to the error it ended in: nothing touched the disk, and nothing ran
  [1]

`ren replay` runs it again on what the journal says each call gave: with
no justfile, and no `sh` to find, it shows what the run showed, and
nothing runs, so what `sh` printed isn't there:

  $ rm justfile
  $ ren=$(command -v ren) && PATH=/nowhere "$ren" replay build.journal
  echo base
  echo building
  echo built
  replayed 8 calls: nothing touched the disk, and nothing ran

A replay is strict: the first call that isn't the recording's next stops
it, at the call the program made:

  $ perl -pi -e 's/echo built"/echo built!"/ if /^11 /' build.journal
  $ ren replay build.journal
  echo base
  echo building
  error: the replay went differently at call 7 of 8
     ┌─ main.ren:38:5
  38 │     Console.error(line)
     │     ^^^^^^^^^^^^^^^^^^^
     = the recording has: main/run_all:1 Console.error("echo built!")
     = this program made: main/run_all:1 Console.error("echo built")
     help: the code changed since this was recorded; record it again
  [1]
  $ cd ..

`--trace` prints the calls `main` made, once it ends, each with what it
gave (and how long it took, which REN_NO_TIMINGS leaves out):

  $ cd just && REN_NO_TIMINGS=1 ren run --trace main.ren -- test 2>&1 >/dev/null
  echo base
  sleep 0.5
  echo testing
  main
  ├─ Fs.read("justfile")                        → 603 bytes
  ├─ Os.args()                                  → ["test"]
  ├─ main/run_all:0
  │  ├─ Console.error("echo base")
  │  └─ Proc.run("sh", ["-c", "echo base"])     → 0
  └─ main/run_all:1
     ├─ Console.error("sleep 0.5")
     ├─ Proc.run("sh", ["-c", "sleep 0.5"])     → 0
     ├─ Console.error("echo testing")
     └─ Proc.run("sh", ["-c", "echo testing"])  → 0
  $ cd ..

The journal checked in, tests/build.journal, is a test: `replay(file)`
answers what `main` reads from it, and what `main` shows has to be what
the recording showed. A change to what's shown fails with the two as a
diff:

  $ cp -rL just t1 && perl -pi -e 's/Console.error\(line\)/Console.error("> ".concat(line))/' t1/main.ren
  $ REN_NO_TIMINGS=1 ren test t1/main.ren --only recorded --seed 1
  main.ren
    ✗ a recorded run of build replays
  
  ──── a recorded run of build replays ── main.ren:131
      │
  131 │   with replay("tests/build.journal") in
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      the outputs differ from the recording's
      - main/run_all:0 Console.error("echo base")
      - main/run_all:1 Console.error("echo building")
      - main/run_all:1 Console.error("echo built")
      + main/run_all:0 Console.error("> echo base")
      + main/run_all:1 Console.error("> echo building")
      + main/run_all:1 Console.error("> echo built")
      help: if the change is what you meant, record the run again, or edit the journal
  
      seed 1 · rerun: ren test t1/main.ren --only "a recorded" --seed 1
  
  0 passed, 1 failed
  [1]

A run that went wrong becomes a test with `ren test --keep`, which moves
its journal to `tests/` and adds a test that replays it:

  $ cp -rL just t2 && chmod -R u+w t2 && cd t2
  $ ren run --record bug.journal main.ren -- broken 2>/dev/null >/dev/null
  [1]
  $ ren test --keep bug.journal
  moved bug.journal to tests/bug.journal
  added the test "replays bug.journal" to main.ren
  run it with `ren test main.ren --only "replays bug.journal"`: it fails while the program ends as the recording did, and passes once it goes on past there, with the same outputs to there
  $ head -1 tests/bug.journal
  # ren journal 2 · ../main.ren · deps: Console Fs Os Proc
  $ tail -3 main.ren
  test "replays bug.journal" =
    with replay("tests/bug.journal") in
      try main()
  $ rm justfile && REN_NO_TIMINGS=1 ren test main.ren --only "replays bug" --seed 1 | grep error
      error: RecipeFailed("broken", 3)
  $ ren test --keep tests/bug.journal
  error: tests/bug.journal is in the `tests` folder already, where --keep moves a journal
    help: a test replays it with `with replay("tests/bug.journal") in`, then a call of `main`
  [1]
