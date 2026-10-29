# T1: closing a named pipeline at the end of its scope

Worktree: `/Users/matthewdodd/Documents/code/ren/.claude/worktrees/wf_350e7dc3-1f2-2`. Nothing is committed.

Files:
- Diff, scope end only: `/private/tmp/claude-501/-Users-matthewdodd-Documents-code-ren/613acdec-6ba7-49dc-9177-3b2453c0c17a/scratchpad/open-items/t1/scope-end.diff`
- Whole worktree (prototype plus this): `.../open-items/t1/prototype-plus-scope-end.diff`
- Tests: `.../open-items/t1/*.ren`. `run.sh` runs them, and `results.txt` holds every output.

## Verdict

**Rule 5 holds in the interpreter, and building it took 23 lines.** Every exit the task listed closes the frame, apart from `return`, which isn't in the compiler (see below). In every case, `finally(r)` sees what streams.md says it should.

## How it was built

- **lower.ml (+17).** In the prototype, every effectful generator's frame is already a hidden `var $frame = $gen_frame()`. The prototype hoists it into the block that holds the statement, so its scope is the `let`'s scope. Lowering now wraps the rest of that block in core `Finally(rest, $gen_close(&$frame))`. Every exit already runs through core `Finally`: falling off the end, `break` (`Broke`), failure (`Failed`) and cancel (`Sched.Cancelled`). Closing a frame that's over, or was never started, does nothing. Nothing about this is specific to the interpreter: it's the node a native lowering would see too.
- **eval.ml (+6).** Core `Finally` didn't run on a panic that was contained. The `with` teardown code (`ending`) already did. Core `Finally` now runs its `after` on a contained panic too, throwing away what that `after` fails with. This also affects the `&` write-backs that core `Finally` carries: they now run on a contained panic, as a `with` teardown does.

## Tests (each prints the order of events)

| Test | Exit | What `finally(r)` sees |
|---|---|---|
| fall | falls off the end after a `break` | `Err(Cancelled)`, after "still in scope". It sees `Ok(())` when the loop ran the generator to its end |
| outer_break | `break` out of a `for` around the `let` | `Err(Cancelled)` each round, both at the end of the round's body and on the `break` |
| fails | a later `try boom()` fails | `Err(Cancelled)`, then `attempt` gets `Err(Bad)` |
| resume | two loops over the same `g` (`sections`) | drained: `Ok(())` when it finishes, and nothing at scope end. Left open: `Err(Cancelled)` at scope end |
| unstepped | never stepped | **nothing runs.** A generator stepped only up to a `yield` before its `finally` also runs nothing |
| nested | if-scope, loop body, two in one scope | inner first; per round of the loop; `b` before `a` |
| with_tx | `preview_then_export` | declined: `ROLLBACK Err(Cancelled)`; confirmed: `COMMIT` when it finishes |
| gen_fails | the generator fails | `Err(Bad)` once; scope end finds it over |
| temp_fails | failure inside a `for` over a temporary | closed with `Err(Cancelled)` (before this change it stayed suspended), then the named one |
| cancel | task cancelled while the consumer sleeps | `Err(Cancelled)`, shielded, and `join` gives `None` |
| cancel_mid_step | task cancelled while the generator sleeps inside a step | `Err(Cancelled)` once: the cancel unwinds its own frame, and scope end finds it over |
| panic | `Async.isolate` contains a panic | `Err(Cancelled)` (this needed the eval.ml change) |

Before this change, fall, fails and the with_tx case where the user declines never ran the generator's `finally`.

The prototype's s2 programs give the same output as `results.txt`. `dune test` shows only the three diffs that were there before: the test_ops stage-name collision, plus two journal timing flakes.

## Decisions taken, and design questions the build raised

1. **A generator that was never stepped runs no `finally`.** A `finally` covers what comes after the point it's written (foundations, decision 7). An unstarted body hasn't reached it, any more than a `with` whose setup never ran has anything to tear down. streams.md's own transaction example says "BEGIN at the first step". The same reasoning covers a generator stepped only up to a `yield` that comes before its `finally`. *Suggest one sentence in Stopping: "a frame never stepped has nothing to close."*
2. **When the scope ends after part of the stream was used, `r` is `Err(Cancelled)`.** That's abandonment, and it holds even when the consumer is leaving because of its own error (`fails`). The generator never sees the consumer's `Err(Bad)`. That's right: the error isn't the generator's, and C# and Go behave the same way. The consumer's `with` sees `Err(Bad)` while the generator sees `Cancelled`. That asymmetry is intended, but worth one line in errors.md.
3. **Order: frames close in reverse of the order they were made, like `with` teardown.** It falls out of nesting. A temporary's frame is hoisted just before its statement. It closes at the statement's end on a normal exit, and on a failure or an outer `break` it closes as the block unwinds. Either way it closes before anything named earlier, so the reverse order holds for temporaries too. Nothing needed deciding.
4. **How this interacts with `with`.** A generator named inside a consumer's `with` closes before that `with` tears down. One named outside it and stepped inside it outlives the `with`, and closes after the teardown. Decision 5 (dependencies are found where the frame is made) means the outlived generator can't hold the inner `with`'s dependency, so nothing is left dangling. A `with` inside the generator (a transaction) rolls back at the consumer's scope end.
5. **`return` isn't in the compiler,** so the early-return case is tested through a `try` failure, which unwinds the same way. When `return` is built, it has to leave through core `Finally`, as an exception or a control value, and not as a jump past it. The same applies to `return` inside a gen fn.
6. **Two parts of streams.md are not built yet:**
   - Stepping a generator that was cancelled should panic. Today it gives `None`.
   - The uniqueness re-check on resume.
   Neither blocks the `let` spelling.
7. **Native:** the closing is a core `Finally`, which the native backend already lowers. The open questions there are gen fns themselves, and whether a contained panic runs native `Finally`s.
