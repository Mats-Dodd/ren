# K3, marking

Decides decision 10's open question (foundations.md, "Whether a shared
handler's state is marked is open"): is a shared handler's state marked
shared, or only what crosses its edge? Staging item 6, phase one of the
many-cores experiments. **Prediction:** at the edge does 3x the
operations a second at 8 workers.

## What's modelled

One actor, a handler instance: a lock plus state

    var subs: Array<Sub>   // Sub = { id: Int, name: String }
    var text: Rope         // an array of --chunks strings of --chunk-bytes

and one operation, `edit(sub, at, delta)`: `subs.push(sub)` (cleared when
it reaches `--subs-cap`, so it stays bounded) and `text.apply`, a one-byte
change to one chunk. Each caller builds its `Sub` (two objects), takes the
instance for the call, runs the operation where it is, and lets go:
decision 10's "an operation keeps its instance until it returns", decision
18's "no home core". 1 to 16 workers call it, each a thread.

**C (`c/k3.c`) is the runtime model** of compiler.md "The runtime model",
written out by hand as the compiler would emit it:

- 8-byte header, 32-bit count: >0 local and plain, <0 shared and atomic
  (Lean's encoding, as `ren_rt.h` under `-DREN_RC_SHARED`), 0 immortal.
- Rule U: change in place only at a local count of 1; a shared object is
  never unique, so a change copies it, counting each element it holds.
- Rule M: `mark_shared` negates counts through everything reachable,
  stopping at what's already marked (`ren_mark_shared`).
- Rule H: a heap per thread, size classes in words, 1 MiB chunks naming
  their owner; a free from another thread goes on the owner's atomic
  remote list (mimalloc's delayed free), drained on its slow path.
- `shared`: everything the operation stores into the instance is marked:
  each push copies `subs` (atomic increment per element, then the old
  array's drop decrements each atomically), each edit copies the rope
  (same) and the chunk.
- `edge`: the state keeps plain counts, since only the holder reaches it;
  only the argument it keeps, the `Sub`, is marked. Push and edit are in
  place. The `Sub`s are still dropped atomically when `subs` clears.

**Rust (`rust/`) is what Rust gives** for the same two designs, as a cross
check: `shared` is persistent data behind `Arc` that's never changed in
place (no `make_mut`: Ren's "never unique"); `edge` is `Mutex<State>` with
plain `Vec`s in place (`Mutex<T>` needs only `T: Send`). `Sub` is an `Arc`
in both. System allocator.

**Locks:** C `--lock unfair` (os_unfair_lock: parks, lets a running
thread barge, as decision 10 allows) or `spin` (test-and-test-and-set);
Rust `--lock mutex` (std) or `spin`. Ren's fair-not-FIFO queue is P3's
subject, not this one's.

**Cores:** every thread asks for `QOS_CLASS_USER_INTERACTIVE`
(`pthread_set_qos_class_self_np`), which keeps up to 12 on performance
cores; at 13 to 16 workers some must run on efficiency cores. macOS has
no pinning.

## Checks (every run, `ok=1`)

The instance's op, push and id-sum counters equal the workers'; `subs`
has the length the op count implies; every text byte equals its initial
value plus every worker's deltas; in `shared` the stored state is marked,
in `edge` it has count 1; after the state is dropped, allocations equal
frees (no leak). With `--ops` (fixed work) the final text and counters
give a digest that's the same for both variants and both languages;
`--quick` compares them, and runs the C under ThreadSanitizer.

## Running

    ./build.sh            # bin/k3-c, bin/k3-c-tsan, bin/k3-rust
    ./run.sh --quick      # a few seconds; correctness only, not timing
    ./run.sh              # full: REPS=7 MS=1000, 1 2 4 8 12 16 workers

Full mode prints one line per configuration, e.g.

    k3 impl=c variant=edge lock=unfair workers=8 reps=7 ms=1000 ... ops_s_median=... ops_s_min=... ops_s_max=... p50_ns=... p99_ns=... remote_frees_per_op=... digest=0 ok=1

`ops_s_*` are over repetitions; `p50_ns`/`p99_ns` are the median over
repetitions of each repetition's percentile of the take-run-let-go time,
sampled every 16th operation with `mach_absolute_time` (41.7 ns ticks, so
values under ~100 ns are coarse). The answer to K3 is
`ops_s_median(edge) / ops_s_median(shared)` at workers=8, per lock.
Knobs: `--subs-cap`, `--chunks`, `--chunk-bytes` (the copy sizes the
shared variant pays), `--think N` (a spin loop outside the instance).

## Fidelity: what's uncertain

- The shared variant's cost is mostly O(len) copying from rule U, not the
  atomics; it scales with `--subs-cap` and `--chunks`, so the ratio is a
  function of state size. The defaults (32 subs, 16 chunks of 64 bytes)
  are a guess at "a small document actor".
- The copy-on-write here is naive Perceus: copy, count every element, drop
  the old. A compiler that moves elements out of a dying shared array
  (count -1, last reference) could skip half the atomics; Ren doesn't.
- `mark_shared` uses a fixed stack; the runtime mallocs one per call, so
  the shared variant is slightly flattered.
- Under contention throughput is dominated by lock handoff: os_unfair_lock
  lets the releasing thread take it again (p50 near 40 ns, p99 tens of
  µs), which isn't decision 10's bounded fairness.
- Rust's `shared` uses two allocations per `Arc<Vec>` and libmalloc; it
  shows what Rust gives, not Ren's allocator.
