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
  $ for d in transfer refresh server crawler just; do spec ../examples/$d; done
  ../examples/transfer: as specified
  ../examples/refresh: as specified
  ../examples/server: as specified
  ../examples/crawler: as specified
  ../examples/just: as specified

Each that has landed passes under a thousand seeds too, its tests' own
and the next 999 (step 5 landed `transfer` and `refresh`, which need
only `sim`'s virtual time; step 7, `server`, on `sim.net()`; step 8,
`crawler`, on `sync`, and the `just`'s recipes at once, folded into
examples/just, on `sim.proc()`):

  $ for d in transfer refresh server crawler just; do (cd ../examples/$d && ren test --seeds 1000 | tail -n 1); done
  4 passed, each under 1000 seeds
  4 passed, each under 1000 seeds
  4 passed, each under 1000 seeds
  3 passed, each under 1000 seeds
  21 passed, each under 1000 seeds

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

The services stage's milestone (compiler.md, "Services stage", "The
tests"; foundations.md, Staging, item 6), in services/ until step 8
moves `docs` to examples/docs, where THE CHECKS run its tests: the
document server, language.md §11's, whose `expected` is what `ren test`
prints there.

  $ spec services/docs
  services/docs: not yet

Then, once step 8 lands: the server's tests, which install its
documents with chaos eviction, `actors(doc, chaos: true)`, pass under a
thousand seeds, `ren test --seeds 1000`; in
services/lost_update, a read and a write in two operations of one actor
inside one `Docs.at` block, `ren test --sim --seeds 200` finds a seed
that loses an edit, and `--seed` with it fails the same way again,
while fixed.ren's one operation passes under a thousand seeds; and in
services/memory, a document kept only in memory passes under a
thousand seeds in a family without chaos, and fails under some seed in
one with `chaos: true`, which `--seed` fails again. There's no `ren
test --chaos`: chaos is a parameter of `actors`.

  $ services_milestone() {
  >   (cd services/docs && ren test --seeds 1000 > /dev/null 2>&1); docs=$?
  >   (cd services/lost_update &&
  >    ren test --sim --seeds 200 --only "two sessions" > seeds.out 2>&1; found=$?
  >    seed=$(sed -n 's/.*rerun: .*--seed \([0-9][0-9]*\).*/\1/p' seeds.out | head -n 1)
  >    ren test --seed "${seed:-0}" --only "two sessions" > again.out 2>&1; again=$?
  >    ren test --seeds 1000 --only "one operation" > /dev/null 2>&1; fixed=$?
  >    [ "$found" = 1 ] && [ -n "$seed" ] && [ "$again" = 1 ] &&
  >      grep -q "two sessions' edits both land" seeds.out &&
  >      [ "$(grep -e 'left:' -e 'right:' seeds.out)" = "$(grep -e 'left:' -e 'right:' again.out)" ] &&
  >      [ "$fixed" = 0 ]; ok=$?; rm -f seeds.out again.out; exit $ok); lost=$?
  >   (cd services/memory &&
  >    ren test --seeds 1000 --only "without chaos" > /dev/null 2>&1; calm=$?
  >    ren test --seeds 200 --only "under chaos" > seeds.out 2>&1; found=$?
  >    seed=$(sed -n 's/.*rerun: .*--seed \([0-9][0-9]*\).*/\1/p' seeds.out | head -n 1)
  >    ren test --seed "${seed:-0}" --only "under chaos" > again.out 2>&1; again=$?
  >    [ "$calm" = 0 ] && [ "$found" = 1 ] && [ -n "$seed" ] && [ "$again" = 1 ]; ok=$?
  >    rm -f seeds.out again.out; exit $ok); memory=$?
  >   if [ "$docs" = 0 ] && [ "$lost" = 0 ] && [ "$memory" = 0 ]
  >   then echo "the services milestone holds"
  >   else echo "the services milestone: not yet"
  >   fi
  > }
  $ services_milestone
  the services milestone: not yet
