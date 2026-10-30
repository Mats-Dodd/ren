# Runtime phase 2: the single runtime's task switch

What a task switch costs under `Async.single()`, built the way release would
emit it, against Go at `GOMAXPROCS=1`, tokio's current_thread runtime, and a
hand-written C floor. Built and checked; not yet measured (only smoke runs).

## The representation: stackless frames

Decision 12 already chooses it. Only a function whose `uses` reaches a
dependency can suspend, so only those get frames off the native stack. Each
task allocates them from a stack-like bump allocator, as Swift does. Release
inlines small child frames when it knows their sizes. So:

- **A function that can suspend is a state machine.** Its frame holds a
  resume pointer, a parent pointer, a state number and its live locals. A
  suspension stores the state and returns `SUSPEND` up the C stack. The
  scheduler resumes the innermost frame; a frame that finishes resumes its
  parent.
- **A call to such a function** pushes the child's frame and calls it
  directly. If the child finishes without suspending, the caller pops it and
  goes on. No scheduler is involved.
- **A task is one heap object:** a 96-byte header and an inline first
  segment of its frame stack. Release sizes the segment to the deepest frame
  chain it can see. Deeper or unknown recursion grows the stack in 4 KiB
  chunks, freed as frames pop (`--check` runs depth 1,000 across a yield).
- **The header holds** the run-queue link, the top frame, the bump pointer
  and limit, the overflow chunk, the scope, the joiner, the `until`
  condition, the task's current heap (compiler.md's "one current heap a
  task", one store a switch), the result and flags.

Stacks (Go's model) were not prototyped. Decision 12 rules them out, and
Go's own numbers below show their cost: 2 KiB or more a task.

## The single runtime, as modelled

- No atomics and no locks. The run queue is an intrusive FIFO.
- An instance has a plain `held` byte and a FIFO of waiters. The byte is
  asserted never to conflict (no op here suspends while holding it). Release
  could drop it for handlers whose ops never suspend holding the instance.
- `Async.until(cond)` with a false condition releases the instance and
  queues the task with its condition. A release resumes the **first** waiter
  whose condition holds and hands it the instance (decision 7). The woken
  task needs no re-check.
- **A release after a section that wrote nothing makes no wake check.**
  Conditions read only the handler's state, so nothing can have become
  true. The first build scanned on every park: 100k parks took 15 s (O(n²)).
  This rule is load-bearing, and the compiler can see it.
- Scopes count live tasks against `max:`. `spawn` past the limit parks the
  spawner (`spawn_batch` at max 64 exercises it). The scope's end parks
  until the count is 0.
- Ren's heap is per-thread size-class free lists over 64 KiB slabs.
  `heap_allocs` counts objects; `sys_allocs` counts mallocs.

**Not modelled, so real Ren pays more:** polling the world's event source
between switches, timers, the journal (decision 11: every runtime journals
the same events), cancellation beyond a flag, and `finally`. The ren_c
number is the target codegen's floor, not a promise.

**A design question the build raised:** a release still scans every waiter
whose condition is false. Many waiters with different conditions on one
instance make a release O(waiters). Options: group waiters by condition
code, or let a handler key its waits. The benchmarks here don't hit it.

## Variants

| binary | what it models |
|---|---|
| `build/ren_c` | Ren's single runtime as release would emit it. `pingpong` inlines the channel's put and get into the task's frame (a known handler). `pingpong_nested` pushes them as child frames (a debug build, or an op not inlined). |
| `build/raw_c` | The floor: hand-written state machines. A task is a 40-byte struct with a fixed step function. A wait is one pointer on the thing waited for. No frames, scopes, conditions or heap pointer. |
| `build/switch_go` | Go 1.27, `GOMAXPROCS=1`: goroutines, buffered channels of 1, `sync.WaitGroup`, `sync.Mutex`, a channel as the scope's semaphore. |
| `build/switch_rust` | tokio 1.53, current_thread with a `LocalSet`: `spawn_local`, `mpsc::channel(1)`, `Notify`, `Semaphore`. `pingpong_local` uses a hand-written `!Send` one-slot channel (`Cell` + `Waker`), the closest Rust analogue of Ren's single runtime. |
| `build/*_asan` | ren_c and raw_c under AddressSanitizer and UBSan, for `--check` only. No variant uses threads, so there is no ThreadSanitizer build. |

## Benchmarks

1. **pingpong** (n = 1M): two tasks, two one-slot channels. A puts `i` on
   `ping` and takes from `pong`; B takes from `ping` and puts `v+1` on
   `pong`. **ns per round trip** (two switches). Check: A's sum is
   n(n+1)/2.
2. **spawn_join** (n = 1M): `Async.scope fn(s) => s.spawn(fn() => ()).join()`
   in a loop. **ns per spawn+join**. Check: the join results sum to n.
   **spawn_batch** (n = 1M, max 64 and 1,000): spawn n empty tasks into one
   limited scope; the scope's end waits. **ns per task.** Check: n ran.
3. **park** (n = 100k): spawn n tasks, each `Async.until(gate.open)`;
   `Async.tick()`; open the gate; wait for all. `ns_per_op` is **wake ns
   per task**; `extra_ns` is spawn+park ns per task; `bytes_per_task` is
   the in-process view (Ren heap bytes, Go `StackInuse+HeapInuse`, Rust's
   allocator's live bytes); `ext_fp_per_task` is the same for all four,
   from `/usr/bin/time -l` (peak footprint at n minus at n=1, over n).
   Check: every task counted once, no waiter left.
4. **fanout** (n = 1,000): spawn 1,000 tasks, each doing 10 adds on one
   counter instance, and wait. **ns per op**, spawn included (`extra_ns`
   is ns per task). **fanout_yield** adds `Async.yield()` after each op,
   so it is 10,000 switches. Check: the counter equals
   10·n(n-1)/2 + 45n.

ren_c also checks, for every run, that no take conflicted and that the heap
holds the same bytes after the run as before (no task or chunk leaked).

## Why each comparison is fair

- **Same programs, same checks.** Every variant runs the same four
  programs with the same arithmetic and checksum.
- **Each twin is what its users write.** Go's fan-out takes a
  `sync.Mutex`, because Go can preempt at one P and the code must lock.
  That's Go's real price, and the reason Ren's single runtime can drop
  the lock. tokio's tasks keep their atomics (task state, wakers) even on
  one thread; `pingpong_local` removes only the channel's.
- **Same scope semantics.** A spawn limit is a semaphore in Go and tokio,
  as errgroup's `SetLimit` and tokio's `Semaphore` are used. The scope's
  end is one wait in all four (a counter and one wakeup, not n joins).
- **Same allocator class where possible.** Ren and raw C use free lists,
  the same model. Go uses its own allocator and GC. Rust uses the system
  malloc, counted by a global allocator: that's tokio's default.
- **Known unfairness.** ren_c is hand-lowered, not compiled from Ren. It
  omits I/O polling, timers and the journal (above). Go's GC and sysmon
  run on other threads. tokio's coop budget forces a yield every 128
  channel ops, which is its real behaviour.

## Predictions (written before the full measurement)

Two numbers were seen before this was written: one ren_c sanity run
(n = 100k, 3 reps) and the smoke run below (n/1000, 1 rep). Neither is a
measurement. The predictions are what I expect from the designs.

| bench | ren_c | raw_c | Go, 1 P | tokio | tokio local |
|---|---|---|---|---|---|
| pingpong, ns a round trip | 12–25 | 5–12 | 150–300 | 150–300 | 80–160 |
| pingpong_nested | 25–45 | | | | |
| spawn_join, ns | 10–20 | 5–10 | 200–350 | 150–300 | |
| spawn_batch max 64, ns a task | 6–12 | 4–8 | 250–400 | 120–250 | |
| spawn_batch max 1,000 | 8–20 | 4–8 | 300–600 | 150–300 | |
| park, bytes a task | 128 | 40 | 2,500–3,500 | 250–350 | |
| park, wake ns a task | 5–15 | 2–5 | 150–300 | 60–150 | |
| park, spawn+park ns a task | 15–30 | 5–10 | 300–700 | 150–350 | |
| fanout, ns an op | 1.5–3 | 0.5–1.5 | 15–35 | 10–25 | |
| fanout_yield, ns an op | 3–6 | 1.5–3 | 25–50 | 15–35 | |

In words:

- **Ren's switch costs 6–12 ns,** within 2–3× of the hand-written floor and
  about 10× under Go and tokio. Ren's switch is a return and an indirect
  call; Go saves and restores registers and goes through `gopark`; tokio
  goes through wakers, task-state atomics and its queue.
- **A non-inlined child frame about doubles a round trip** (pingpong_nested
  against pingpong). So release's inlining of known ops matters for
  switch-heavy code.
- **A parked task costs 128 bytes in Ren,** about 20× less than a goroutine
  and about half a tokio task. 100k parked tasks are 12.8 MB in Ren and
  over 250 MB in Go.
- **spawn+join is about one heap free-list hit and two switches.** It's
  10–20× cheaper than Go or tokio, which allocate more and touch atomics.
- **The fan-out is dominated by spawning,** not the ops: ~17 ns a task in
  Ren against 150–350 ns elsewhere. Go also pays an uncontended mutex
  per op.
- **What would falsify the design:** ren_c more than 3× raw_c on pingpong
  or park wake, or a parked task above 256 bytes.

## How to run

```sh
cd /Users/matthewdodd/Documents/code/ren/experiments/runtime-p2/switch
./build.sh                # clang -O2, go build, cargo --release --offline, ASan builds
./measure.sh --check      # every binary's --check, ASan/UBSan included; prints ALL CHECKS ok
./measure.sh --smoke      # every config at n/1000, 1 rep (~1 s total)
./measure.sh              # the full run, one config at a time -> results/measure-<ts>.txt
```

`measure.sh` waits for the 1-minute load average to fall to 4 or below
before each run (up to 5 min), and records the load on the line. It sets
`GOMAXPROCS=1`. The full run's commands, in order (each prints one line):

```sh
for b in ren_c raw_c switch_go switch_rust; do ./build/$b --bench pingpong --n 1000000 --reps 7; done
./build/ren_c --bench pingpong_nested --n 1000000 --reps 7
./build/switch_rust --bench pingpong_local --n 1000000 --reps 7
for b in ren_c raw_c switch_go switch_rust; do ./build/$b --bench spawn_join --n 1000000 --reps 7; done
for m in 64 1000; do for b in ren_c raw_c switch_go switch_rust; do
  ./build/$b --bench spawn_batch --n 1000000 --reps 7 --max $m; done; done
for b in ren_c raw_c switch_go switch_rust; do ./build/$b --bench park --n 100000 --reps 5; done
for f in fanout fanout_yield; do for b in ren_c raw_c switch_go switch_rust; do
  ./build/$b --bench $f --n 1000 --reps 63; done; done
```

Each is wrapped in `/usr/bin/time -l` for the peak footprint; park runs
again at `--n 1 --reps 1` for the baseline. Each line's fields:
`ns_per_op` (median over reps), `min_ns_per_op`, `extra_ns`,
`heap_allocs_per_op` (Ren/raw: heap objects; Go: `Mallocs`; Rust:
allocator calls), `sys_allocs_per_op` (mallocs), `bytes_per_task`,
`peak_footprint`, `load`, `ext_fp_per_task` (park), `check=ok|FAIL`.

Zig isn't installed, so there is no Zig twin.
