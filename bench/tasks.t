Stage 11a's programs (compiler.md, "Stage 11a", "The tests"), one
folder each under 11a/tasks/: the five programs of async.md, the `just`'s
concurrent part, and the milestone. Each `expected` holds what `ren
test` prints there and how it exits. Until its step lands a program
isn't as specified; the step that lands one changes its line here to
say so, moves its folder to examples/, where THE CHECKS run its tests
from then on, and adds it to a loop after this one that runs them
under a thousand seeds, `ren test --seeds 1000`, which have to pass
too.

  $ export REN_NO_TIMINGS=1
  $ spec() {
  >   (cd "$1" && { ren test > spec.out 2>&1; echo "exit $?" >> spec.out; } &&
  >    if cmp -s spec.out expected
  >    then echo "$1: as specified"
  >    else echo "$1: not yet"
  >    fi
  >    rm -f spec.out)
  > }
  $ for d in server crawler just; do spec 11a/tasks/$d; done
  11a/tasks/server: not yet
  11a/tasks/crawler: not yet
  11a/tasks/just: not yet
  $ for d in transfer refresh; do spec ../examples/$d; done
  ../examples/transfer: as specified
  ../examples/refresh: as specified

Each that has landed passes under a thousand seeds too, its tests' own
and the next 999 (step 5 landed `transfer` and `refresh`, which need
only `sim`'s virtual time):

  $ for d in transfer refresh; do (cd ../examples/$d && ren test --seeds 1000 | tail -n 1); done
  4 passed, each under 1000 seeds
  4 passed, each under 1000 seeds

The milestone (README, "Roadmap", 11a): in 11a/tasks/lost_update, `ren test
--sim --seeds 200` finds a seed under which one of two deposits is
lost, so the test fails, and says which; `ren test --seed` with that
seed fails the same way again, with the same values; and the same
account with one operation, `add`, and the README's `cached`, pass
under a thousand seeds.

  $ milestone() {
  >   (cd 11a/tasks/lost_update &&
  >    ren test --sim --seeds 200 --only "two deposits" > seeds.out 2>&1; found=$?
  >    seed=$(sed -n 's/.*rerun: .*--seed \([0-9][0-9]*\).*/\1/p' seeds.out | head -n 1)
  >    ren test --seed "${seed:-0}" --only "two deposits" > again.out 2>&1; again=$?
  >    ren test --seeds 1000 --only "two adds" > /dev/null 2>&1; fixed=$?
  >    ren test --seeds 1000 --only "a save is never undone" > /dev/null 2>&1; cached=$?
  >    if [ "$found" = 1 ] && [ -n "$seed" ] && [ "$again" = 1 ] &&
  >       grep -q 'two deposits both land' seeds.out &&
  >       [ "$(grep -e 'left:' -e 'right:' seeds.out)" = "$(grep -e 'left:' -e 'right:' again.out)" ] &&
  >       [ "$fixed" = 0 ] && [ "$cached" = 0 ]
  >    then echo "the milestone holds"
  >    else echo "the milestone: not yet"
  >    fi
  >    rm -f seeds.out again.out)
  > }
  $ milestone
  the milestone holds

A version 1 journal is refused once journals are version 2 (step 6),
with a help that says how to record it again. 11a/tasks/journal/v1.journal
was recorded by `ren run --record v1.journal hello.ren -- a b` before
11a.

  $ (cd 11a/tasks/journal && { ren replay v1.journal > spec.out 2>&1; echo "exit $?" >> spec.out; } &&
  >  if cmp -s spec.out v1.expected; then echo "v1.journal: as specified"; else echo "v1.journal: not yet"; fi;
  >  rm -f spec.out)
  v1.journal: as specified
