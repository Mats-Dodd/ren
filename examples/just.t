The small just (just/README.md) on the real `Fs`, `Os` and `Proc`: it reads
the `justfile` in the folder it's run from, and runs each line with `sh -c`.
With no args it runs the first recipe, after what it depends on, and `base`,
which two of those depend on, runs once:

  $ cd just
  $ ren run main.ren
  base
  building
  built
  testing
  all done

What follows `--` names the recipe:

  $ ren run main.ren -- test
  base
  testing

The first line that exits with anything but 0 stops it, and `main` fails
with why, so the process exits with 1:

  $ ren run main.ren -- broken
  base
  trying
  error: RecipeFailed("broken", 3)
  [1]

  $ ren run main.ren -- deploy
  error: UnknownRecipe("deploy")
  [1]

  $ cd .. && ren run just/main.ren
  error: NoSuchFile("justfile")
  [1]

Its tests run on the test implementations, with no `with` but where a test
needs a justfile, args, or a program that fails:

  $ ren test just | tail -1 | sed 's/[0-9]*ms$/Nms/'
  13 passed in Nms
