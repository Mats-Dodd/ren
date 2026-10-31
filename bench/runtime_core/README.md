# Runtime core tests

Step 0 runs the comparator self-tests, C source syntax checks, interpreter
fixtures, and unchanged-Core interpreter-adapter checks in
`../runtime_core.t`. Native milestones remain explicitly **SKIP** until
their implementations arrive. Compiler refusals never pass conformance.

## Concrete C protocol tests, pending c3 linkage

`core_protocol.c` has 27 concrete test bodies/traces over `core_hooks.h`.
The header specifies a test-only adapter to the **production** core at
`lib/native/runtime/ren_core_test.c`; that adapter is deliberately absent
in step 0. It must invoke real verbs/frame callbacks and observe actual
ownership/refcount/allocation transitions. The stable observation ledger
must not implement a replacement protocol. Pauses expose precise atomic
boundaries, including MODEL.md's logical competing actors. They do not
introduce a production multicore scheduler.

Coverage includes all MODEL counterexamples: four reference-holding wake
sites, cancel/spurious delivery, retraction alone/with another call/during
stop, until stop before/after the park decision, P4 cancel-side free, both
P3 generation races (including a shielded finally), notify-before-store,
worker park recheck, cancelled-task reply/buffer lease, and take-lock
recheck. Additional bodies cover inline/duplicate/late replies, stop with
a pulled call and during publication, PING/PINGY, the nine host functions,
kill without finally while a driver retains its lent buffer, and two real
pthread host repliers. The header enumerates all 14 rule-removal flags;
17 case/flag pairs must fail their exact intended invariant with the rule
off and pass with it on. A crash or a different assertion is insufficient.

```
python3 bench/runtime_core/core_tests.py --syntax
python3 bench/runtime_core/core_tests.py --run --sanitizers \
  --sources path/to/real/core.c path/to/real/hook_adapter.c path/to/runtime.c
```

The first command checks only C syntax; it does not validate the core.
The second builds rule-on and each rule-off binary, verifies the adapter's
reported compiled flag, and checks invariant diagnostics. ASan/UBSan run
all correct-core cases; TSan runs the two-host-replier case. It returns
77 with an explicit SKIP while the production adapter is absent.
`REN_CORE_TEST_SOURCES` may supply the real source list as a JSON array.
No stub implementation is supplied or accepted as core validation.

## Conformance adapters

```
dune build bench/runtime_core/adapter/interpreter.exe
python3 bench/runtime_core/conformance.py program/main.ren --seed 1 --seeds 1000
python3 bench/runtime_core/conformance.py program/main.ren \
  --test 'original test name' --seed 4702 --seeds 1 --mode release
```

The interpreter adapter invokes `Driver.suite` and `Eval.run_installed`
on **unchanged checked Core**. It never renames/wraps main or transforms
source. Main runs with root `main`, sim/test world dependencies, and real
Console; source tests retain root `test`, the original generated test
function, declared real dependencies and the same seeded Random/scheduler
as `ren test`. The optional `record_order` observer attaches the existing
journal watcher before runtime installation. Its default is false, so
ordinary interpreter entry points retain their behavior. Active adapter
checks compare default/observed outcomes, console, world-call task paths,
panic location and seed, and assert that family order is recorded.

`interpreter.py` launches this test-side executable. `native.py` implements
the planned CLI contract: `ren build --scheduler sim --debug|--release`,
then host flags `--ren-seed` and `--ren-record`. Tests additionally require
`--test-entry` at build time and `--ren-test` at runtime. These native
capabilities are pending c4/c5; today's missing option yields SKIP 77 and
**no journal**, which causes conformance to fail. Genuine compilation
errors retain their failure status. Debug, release, ASan, UBSan, TSan and
tcc modes select their real compiler/instrumentation settings.

Custom adapters remain JSON argv arrays with `{program}`, `{seed}`,
`{journal}` and `{mode}` substitutions, without shell expansion. Missing
journals and timeouts fail. Exit status, stdout, stderr (including panic
location) and journal bytes must match. `--journal-view` accepts a JSON
argv such as `["ren","journal","show","{journal}"]` and reports the
first differing call. Identical text views cannot excuse different binary
bytes. Seven active comparator tests exercise the comparison and adapter
seed loop; their synthetic journals test only the harness.

## Declaration edit tests, pending emitter support

`edit_compare.py` implements the proposed
`ren build --scheduler sim --emit-declarations DIR` manifest contract:
version 1, artifacts `{id,declaration,copy_key,kind,file,reads}` and exact
raw C files. It compares exact bytes and recorded fact hashes; it never
renumbers generated identifiers. Only four explicit link-table artifact
ids are exempt. Seven active comparator tests cover changed bytes,
inliner dependencies, forbidden callee-size coupling, copy-name stability,
exact specializer exceptions and artifact path/link-exemption validation.

```
python3 bench/runtime_core/edit_compare.py --self-test
python3 bench/runtime_core/edit_compare.py bench/runtime_core/edit/generic
python3 bench/runtime_core/edit_compare.py bench/runtime_core/edit/family
```

Each fixture's `edits.json` applies independent mutations from the original
tree, in debug and release. Generic coverage includes recursive coloured
roundtrip copies at two types, an inline helper, a caller not inlining the
roundtrip, source-line insertion, body/frame growth, colour change and
adding an unrelated generic/carry. Family coverage includes setup/finally,
post/drain, a separate family, source-line insertion, dispatch changes,
key-layout changes and a newly shared caller. `invalid_rule3.ren` keeps a
helper-hidden inner-family reach separate from the valid entry.

The specializer's two pre-existing breaks can only be reported through
an explicit artifact/edit/category/before-hash/after-hash exception. Runtime
frame/resume/carry/dispatcher/ABI artifacts can never be waived. No broad
release-fixture exemption exists. Actual compiler manifest emission is
pending; a missing manifest or compilation failure fails the comparator.

## Remaining milestone tests

`test/test_runtime_core.ml` has explicit `until "c1"` through `until "c6"`
gates. C3 gates invoke the concrete C runner. C1 has concrete future
source/headline/help assertions; the other language/journal/task/family/
driver runner obligations remain pending their APIs. Applicable channel
composition, admission/cancellation, independent terminal state, outward
family drain and actor/channel deadlock replay remain c4/c5 obligations;
the four active lifecycle fixtures cover interpreter behavior only.
`inventory.py` discovers 96 services/actor reference test locations for
the eventual native suite; listing them is not native execution.
