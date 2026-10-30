# P1, the cost of a hop

Phase one of the many-cores experiments (foundations.md, Staging). One
task and one handler instance, with operations doing 0, 10, 100, 1,000
and 10,000 ns of work. The question is what it costs to reach the
instance.

**Prediction:** taking the instance and running costs 5 to 20 ns more
than a plain call. A hop to a home core costs about 300 ns when the home
core spins and about 2 µs when it's parked.

## What's modelled, and how it maps to Ren

- **The instance** is a 128-byte-aligned struct (one Apple cache line)
  holding a 32-bit lock word and the handler's state: a `u64` `var`, plus
  counters used for checking.
- **The operation** (`op_run`, never inlined, as an operation reached
  through evidence wouldn't be) runs `iters` dependent mix steps
  (`s ^= s>>29; s *= K`) on the state and writes it back. `iters` is
  calibrated at start-up to the target number of nanoseconds and printed
  on every line.
- **`call`:** the instance isn't shared. Decision 10 skips the exclusion
  unless spawning a task marked the handler, so the operation is a plain
  call.
- **`take`:** the instance is shared, and the operation takes it for
  one call (decision 10). A CAS takes the lock word from 0 to 1 with
  acquire ordering, and a swap to 0 with release ordering lets go. A
  waiter parks on the word with the ulock (`os_sync_wait_on_address`).
  The fast path is inlined at the call site, as the compiler would emit
  it. The slow path is never taken here (there's one task), and it's
  counted to check that.
- **`hop_*`:** the instance lives on a home core, and only that core
  runs its operations, so no lock is taken. An operation is a message in
  the caller's frame (in Ren, the task frame), pushed onto the home
  core's queue (Vyukov's intrusive MPSC queue, which Ren's scheduler
  would also need). The home core runs the operation and writes the
  result into the message.
  - `hop_spin`: the home core spins on an empty queue, and the caller
    spins on the reply.
  - `hop_park`: the home core parks on the ulock as soon as its queue
    is empty. The caller sees the sleeping flag, wakes it, and spins on
    the reply. The flag uses Dekker-style seq_cst.
  - `hop_park_cold`: `hop_park` with a 50 µs untimed idle gap before
    each operation, so the home core is really asleep when the message
    arrives. **This is the case the "2 µs parked" prediction is
    about.** Back-to-back `hop_park` often catches the home core before
    it sleeps.
  - `hop_park_both`: the caller also parks on the ulock for its reply.
    This is a worker that has no other task to run.
  - `hop_condvar`: `hop_park_both` with a pthread mutex and condvar for
    both sleeps, as a reference point.
- **QoS:** both threads run at `QOS_CLASS_USER_INTERACTIVE` (set with
  `pthread_set_qos_class_self_np` and `pthread_attr_set_qos_class_np`).
  This only steers them toward P cores. macOS has no pinning, so the
  home core and the caller may share a cluster or not, and can migrate.
- The C (`c/p1.c`) and the Rust (`rust/src/main.rs`) versions match
  variant for variant. The Rust uses std only, and declares the ulock,
  QoS and `mach_absolute_time` calls itself.

## Output

`./run.sh` runs a full pass (11 repetitions by default, or
`--reps N`), C then Rust, and prints one line per configuration:

```
P1 lang=c variant=take work_ns=100 iters=52 workers=1 reps=11 median_ns=.. overhead_ns=.. p50_ns=.. p99_ns=.. qos=user_interactive
```

- `median_ns` is the median over repetitions of a batch's mean time per
  operation (about 20 ms of back-to-back operations per batch).
- `overhead_ns` is `median_ns` minus `call`'s at the same work.
- `p50_ns` and `p99_ns` are percentiles of individually timed operations,
  up to 10,000 a repetition. The timer ticks every 41.67 ns, so they're
  only meaningful for the hops.
- `workers` is 1: one calling task. The hops' home core is an extra
  thread.

`./run.sh --quick` is a smoke run. It runs `--check` in both languages
(every variant must reach the same state at fixed `iters=7` and 1,000
operations, and C and Rust must print the same state), the C under
ThreadSanitizer in `--check` and `--quick` mode, and then both languages
at 3 short repetitions.

In every configuration, the final state must equal a plain replay of
the same number of operations, and `ops`, the home core's `handled`
count and the slow-path count must all add up. A failure is printed to
stderr and gives a non-zero exit.

## Status

Built and smoke-tested only. The C and Rust checks agree
(`state=61001fdfc6fb1de2`), and TSan is clean. The timed run is left to
the serial measurement agent. The quick numbers were taken with other
agents loading the machine, so they're only indicative:

| Variant | Quick result |
|---|---|
| `take` over `call` | about 0.5 to 1 ns |
| `hop_spin` | about 250 to 330 ns |
| back-to-back `hop_park` | about 500 ns |
| `hop_park_cold` | about 6.7 to 9.7 µs |
| `hop_park_both` and `hop_condvar` | about 4 to 5 µs |

## Fidelity: what's uncertain

- **`take` is the best case.** The lock word stays in this core's L1 in
  exclusive state, and in the batch loop out-of-order execution can
  overlap the CAS and the swap with the previous and next operation. A
  shared instance that tasks on different workers take in turn would
  move its line between cores on every take, costing about 100 ns or
  more. That's P2's and P3's subject, not this one's. The 0 ns row shows
  the raw cost of the atomics.
- **"Parked" depends on the policy.** Ren's worker would probably spin
  briefly before parking, as Go's does. Here the home core parks at
  once, so `hop_park_cold` is the worst case and `hop_spin` is the best.
  A spin-then-park home core falls between them, depending on its spin
  budget. That isn't modelled.
- **The caller isn't a task.** In Ren, the calling task would park and
  its worker would run another task. With one task, the worker either
  spins (`hop_park`) or sleeps (`hop_park_both`). Neither variant counts
  the cost of a task switch on the caller's side (saving and restoring a
  task frame), which would add tens of ns.
- **Wake-up latency on macOS is dominated by the scheduler.** It
  includes waking an idle P core from a low-power state, and moves by
  microseconds with system load and with which cluster the thread lands
  on. Run the full mode alone.
- **No hand-off of the result object.** The result is a `u64`. A real
  hop returning an object would mark it shared or move it (rule M or J),
  adding about 3 ns an object.
- Rust wasn't run under TSan, which needs nightly. Its synchronization
  is the same protocol as the C version, which TSan checked.
