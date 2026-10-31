# Runtime core test scaffolding

Step 0 runs the conformance comparator's six self-tests and six small
interpreter reference programs in `../runtime_core.t`. The native
milestones in that file and `test/test_runtime_core.ml` say **SKIP**.
They do not reinterpret today's compiler errors as passing native tests.

`test/test_runtime_core.ml` contains concrete negative source programs
for sixteen trust/foreign diagnostics. Its remaining entries describe the
language, journal, C, task, family, channel, edit and driver checks that
the later steps must provide. The `REN_CORE_*_TEST` variables name future
executable runners with `--case <name>`; those runners must reject unknown
cases. They are not implemented in step 0. In particular, **the named C
counterexamples are an inventory, not executable C mutant tests yet**.
Enabling a milestone without its runner fails immediately.

## Conformance comparator

From the repository root:

```
python3 bench/runtime_core/conformance.py --self-test
python3 bench/runtime_core/conformance.py program/main.ren \
  --seed 1 --seeds 1000 --mode debug \
  --interpreter '["/absolute/interpreter-adapter","{program}","{seed}","{journal}"]' \
  --native '["/absolute/native-adapter","{program}","{seed}","{journal}","{mode}"]' \
  --journal-view '["ren","journal","show","{journal}"]'
```

Adapters are necessary until the native sim CLI is implemented. Each
runs the program under sim at the supplied seed and records its journal
to the supplied path. They must return the program's status, stdout and
stderr, keeping build messages elsewhere. Arguments are JSON arrays,
expanded without a shell. Both executions use the same program path,
working directory and journal path. A missing journal or timeout fails.
Matching failures are permitted so panic and deadlock fixtures can be
compared. Exit status, stdout, stderr (including panic location), and
journal bytes must all match. The optional journal view command reports
the first differing line, including its call and id; a binary difference
with identical views still fails. `--mode` is passed to the native
adapter: debug, release, asan, ubsan, tsan or tcc. The harness does not
claim to compile or instrument a binary itself.

The self-tests verify byte differences (including truncation), status,
stdout, stderr, call context, subprocess adaptation, missing journals and
timeouts. Their synthetic data tests only the comparator.

## Fixtures and pending coverage

- `cancel_tree.ren`: a timeout cancels nested descendants and returns only
  after their cleanup.
- `blocked_producer_cancel.ren`: a consumer breaks and producer teardown
  precedes the enclosing call's return, with `cap: 1`.
- `producer_buffered_failure.ren`: admitted values precede producer failure.
- `channel_drain.ren`: closed-channel buffered values are drained in order.
  This does not yet force close to race blocked senders and receivers.
- `edit/generic`: the same generic declaration instantiated at two types.
- `edit/family`: a keyed family and an independent imported module.

For each edit fixture, compile before and after adding an unused function,
changing `unrelated.ren`'s body, and inserting lines before a declaration.
Compare emitted C declaration by declaration, retaining emitted names,
shape hashes, resume sites, signatures and bodies. Changing an unrelated
body may change that declaration only; adding one may add its declarations
only. The runtime and frame-size checks must be enabled when those are
emitted. The source fixtures run now; the native declaration comparator
is still missing.

`python3 bench/runtime_core/inventory.py` discovers the reference family
tests from services s6/s7/s8, services review, actors, and structured actor
stages 10a/10b. It includes rejection tests and the old native refusal;
the future conformance runner must distinguish compile-time refusals,
runtime programs and the obsolete native-capability refusal explicitly.
Listing a source test does not execute its native counterpart.

All MODEL.md condensed counterexamples and mutants have named c3 entries:
the four reference-holding wake sites, deliver after a spurious wake,
retraction alone/with another call/during stop, stop on until and before
park, cancel-side op free, reply/cancel generations, store before notify,
park recheck, cancelled task waiting, and contended-take recheck. C API
assertions, controllable interleavings, rule-removal build flags and
sanitizer builds remain to be written in c3.

The c4/c5 inventory covers channels.md's applicable composition cases:
consumer exit on a full queue; send/receive admission racing cancel;
close with blocked senders/receivers; buffered failure; merge sibling
failure with full terminal storage; named generator scope finalization;
family drain posting outward; actor/channel wait-cycle deadlock and
seed replay; and expand saturation. General selection's competing
receive alternatives remain deferred by channels.md. The native
admission, terminal-state and wait-cycle tests remain to be implemented;
this stage does not silently change interpreter queue behavior.
