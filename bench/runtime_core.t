Runtime core step 0. The comparator's own tests run now; the native
milestones are explicitly skipped until their implementations land.
A native compiler refusal is not conformance.

  $ python3 runtime_core/conformance.py --self-test
  conformance harness: 6 tests passed

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
  1

The steps turn these into real invocations of the comparator and the C
harness; remove the matching skip when enabling one. TSan covers two
host threads replying, without implementing a multicore scheduler.

  $ echo 'SKIP c1: trust/foreign/submit diagnostics and help'
  SKIP c1: trust/foreign/submit diagnostics and help
  $ echo 'SKIP c2: binary journal, unchanged text view, cross-build schema replay'
  SKIP c2: binary journal, unchanged text view, cross-build schema replay
  $ echo 'SKIP c3: model C counterexamples with each rule on/off; ASan, UBSan, TSan'
  SKIP c3: model C counterexamples with each rule on/off; ASan, UBSan, TSan
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
