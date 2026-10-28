# A small just

A command runner, like [just](https://github.com/casey/just): a
`justfile` names recipes, each with the recipes it depends on and the
lines it runs. It runs one, after everything it needs, each once, and
stops at the first line that fails. It's the milestone of stage 8: it
reads a file, takes its args and runs programs, all through `Fs`, `Os`
and `Proc`, and its tests run on the test implementations of all three,
with no setup.

```
cd just
ren run main.ren              # the first recipe, `all`
ren run main.ren -- broken    # a recipe that fails: exits with 1
ren types main.ren            # every module's interface
ren test .                    # every module's tests

ren run --record run.journal main.ren -- build   # record a run
ren replay run.journal        # run it again on what was recorded
ren run --trace main.ren      # the calls it made, with their times
```

| File | What's in it |
|---|---|
| `justfile.ren` | `Recipe` and `Justfile`, with `parse`, which fails with `BadLine` or `DuplicateRecipe`, and `recipe`, which fails with `UnknownRecipe` |
| `plan.ren` | `order`: the recipes to run, each after what it depends on, each once; it fails with `UnknownRecipe` or `Cycle` |
| `main.ren` | `main`, which reads the justfile, picks the recipe and runs each line with `sh -c`, showing it on stderr first; its tests, on the fakes |
| `justfile` | a few recipes that `echo`, two that share `base`, and one that fails |
| `tests/build.journal` | a run of `ren run main.ren -- build`, recorded, which a test in `main.ren` replays |

```
all: build test
  echo all done

build: base
  echo building
```

## What to look at

**The signature says what it touches.** `ren types` shows `main` `uses
Console, Fs, Os, Proc`, and nothing else. `Console` is for the line
`run` shows on stderr, with `Console.error`, before it runs it; what the
recipes print appears without it, since a program that `Proc` runs
prints to this one's stdout itself. `run` uses only `Console` and
`Proc`, `plan` and `justfile` use nothing, and the compiler worked all
of that out.

**A string's indices are bytes.** `parse` splits the text on `"\n"`, and
cuts a recipe's line at the offset `index(":")` gives, `t[0..colon]`, a
slice of the line, which shares its bytes. There's no way to land inside a
character: `index` gives where a whole match starts, and a slice that cut
one would panic.
Bytes come in only at the edge: `Fs.read_str` reads them and turns them
into a `Str` with `Str.from_utf8`, which fails with `InvalidUtf8`, so
`main` can.

**Every way it can fail is a tag.** No file is `NoSuchFile(path)`, from
`Fs`, one of the four tags of `FsError`; a recipe that isn't there is `UnknownRecipe(name)`; a line that
exits with anything but 0 is `RecipeFailed(name, code)`. `main` passes
them all on with `try`, so it fails, and the runtime prints `error:
RecipeFailed("broken", 3)` and exits with 1. There's no `Os.exit`. A
program that isn't there would be `NoSuchProgram`, never 127, but `sh`
always is. `run` says it fails with `ProcError`, the prelude's name for
everything `Proc.run` can fail with.

**Each recipe once, in order.** `order` is depth first, and keeps two
lists, `inout`: the recipes it's started and the ones it's done. A recipe
two others depend on is done after the first, so the second skips it,
`done.includes(name)`. One that's started but not done is further up, so
reaching it again is a cycle.

**The recipes are an array.** A justfile has a handful, in the order
they're written, which is what the first one, the default, and the tests
depend on. `recipe` finds one with `find`, and `parse` refuses a second
of one name with `any`. A `Map` by name would keep that order too, but
it would make `parse` check one thing two ways and buys nothing at this
size.

**Tests need no setup.** Each test of `main` gets an empty `mem_fs`, no
args and a `test_proc` that runs nothing, without a `with`. A test that
needs a justfile, args or a program that fails installs them: `with
mem_fs(files(text)), test_os(["test"]) in try main()`. It looks at what
would have run with `TestProc.ran()`, a list of `Command { cmd, args }`,
and at the lines shown on stderr with `TestConsole.errors()`.
A line that fails is a row of `test_proc`'s table, `Exit { command:
sh("echo left"), code: 3 }`; the rest exit with 0. "No justfile" needs
nothing installed at all: the empty `mem_fs` has no file, and `main` fails
with `NoSuchFile`.

**The same program, for real.** `just.t`, next to this folder, runs it on
the real `Fs`, `Os` and `Proc` against `justfile`, and checks what the
recipes print, in order, and how it fails.

## What writing it ran into

- **No `continue` or early return.** A blank line is skipped with `if
  ... then ()`, and `visit` puts what it does in an `else`.
- **No `let` at the top level.** The diamond justfile the tests share is
  a function, `diamond()`.
- **No multi-line strings.** A test's justfile is one literal with `\n`
  in it, which is hard to read as a justfile.
- **A function can't share a module's name.** The tests' `justfile(text)`
  clashed with `import justfile`, and became `files(text)`.
- **A function can't be imported by name,** only a type, so it's
  `plan.order(...)`.
- ~~**No `contains`, `filter` or `map` on arrays.**~~ Stage 9b gave
  arrays `Enumerable`'s methods, so `has` became `includes`, and the
  loops in `recipe` and the duplicate check became `find` and `any`.
  `split(" ")` still gives an empty string between two spaces, which
  `parse` drops by hand.

What stage 9c changed, where a test sees what an importer sees:

- **`plan.ren` cost nothing.** Its private recursive `visit` was already
  tested through `pub fn order`, which is what the tests call.
- **`main` is `pub`, with its whole contract.** The tests call it, so
  its signature spells out nine errors and four dependencies:
  `! FsError | InvalidUtf8 | BadLine(number: Int) | ... uses Fs, Os,
  Proc, Console`. Getting there takes one "can fail with" error per
  error; a help that wrote the whole `!` clause at once would save that.
- **The helpers are test items,** `test fn sh`, `files` and `diamond`,
  which only tests see, and which `ren run` leaves out.
- **`Justfile` is opaque.** `parse` refuses a bad justfile, so it keeps
  a rule, and an open `Justfile` would let anyone make one `parse`
  refuses. Its recipes are read through `recipes()`.

**A real run is a test** (stage 10b). `tests/build.journal` is what
`ren run --record tests/build.journal main.ren -- build` wrote: each call
`main` made to `Fs`, `Os`, `Proc` and `Console`, and what it gave. The
test `a recorded run of build replays` installs `replay` of it, so what
`main` reads and what `sh` exited with come from the journal, and what
it shows on stderr has to be what the recording showed. It needs no
justfile and runs nothing. A change to a line `run` shows fails it with
the two as a diff; record it again if the change is meant.
