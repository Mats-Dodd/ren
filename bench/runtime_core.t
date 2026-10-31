Runtime core step 0. The comparator's own tests run now; the native
milestones are explicitly skipped until their implementations land.
A native compiler refusal is not conformance.

  $ python3 runtime_core/conformance.py --self-test
  conformance harness: 7 tests passed

The four reference programs exercise subtree cancellation, full-buffer
producer cancellation, buffered values before failure, and channel drain.
These are interpreter checks; they do not assert native support.

  $ ren run runtime_core/cancel_tree.ren
  Err(Timeout)
  after
  $ ren run runtime_core/blocked_producer_cancel.ren
  0
  producer stopped
  after
  $ ren run runtime_core/producer_buffered_failure.ren
  1
  2
  Err(Broken)
  $ ren run runtime_core/channel_drain.ren
  1
  2

The edit fixtures must remain well-typed before there is native family
support. The actual declaration comparison is pending, including debug
and release, and the specialization exceptions documented in the spec.

  $ ren run runtime_core/edit/generic/main.ren
  1
  42
  kept
  $ ren run runtime_core/edit/family/main.ren
  1
  setup a
  1
  finally a: 3

The unchanged-Core adapter runs the same original test entry twice, once
with the reference defaults and once with the optional order observer.
Both seed choice and panic locations must remain identical. Family order
records must be present in the observed journal.

  $ runtime_core/adapter/interpreter.exe runtime_core/adapter_probe.ren 17 observed.journal --test 'order observation preserves reference' --check-reference-parity
  reference parity: unchanged outcome, console, task paths, panic site and seed
  $ grep -q 'opened\|made\|posted' observed.journal && echo 'family order recorded'
  family order recorded
  $ runtime_core/adapter/interpreter.exe runtime_core/adapter_probe.ren 17 panic.journal --test 'panic site stays in original' --check-reference-parity
  reference parity: unchanged outcome, console, task paths, panic site and seed
  $ grep -q 'panic.*adapter_probe.ren' panic.journal && echo 'original panic location recorded'
  original panic location recorded
  $ python3 runtime_core/edit_compare.py --self-test
  declaration comparator: 7 tests passed; compiler emission pending

The steps turn these into real invocations of the comparator and the C
harness; remove the matching skip when enabling one. TSan covers two
host threads replying, without implementing a multicore scheduler.

  $ echo 'SKIP c1: trust/foreign/submit diagnostics and help'
  SKIP c1: trust/foreign/submit diagnostics and help
  $ echo 'SKIP c2: binary journal, unchanged text view, cross-build schema replay'
  SKIP c2: binary journal, unchanged text view, cross-build schema replay
  $ python3 runtime_core/core_tests.py --syntax
  C protocol traces: syntax checked; production core not linked
  $ python3 runtime_core/core_tests.py --run 2>&1
  SKIP c3: production ren_core_test.c hook adapter is not implemented
  [77]
  $ for mode in debug release asan ubsan tcc; do echo "SKIP c4: $mode native sim journals, tasks and channel composition"; done
  SKIP c4: debug native sim journals, tasks and channel composition
  SKIP c4: release native sim journals, tasks and channel composition
  SKIP c4: asan native sim journals, tasks and channel composition
  SKIP c4: ubsan native sim journals, tasks and channel composition
  SKIP c4: tcc native sim journals, tasks and channel composition
  $ echo 'SKIP c5: services family journals, rule 3, outward drain, actor/channel deadlock replay, edit test'
  SKIP c5: services family journals, rule 3, outward drain, actor/channel deadlock replay, edit test
  $ echo 'SKIP c6: real driver, server, concurrent just, bidirectional replay'
  SKIP c6: real driver, server, concurrent just, bidirectional replay
