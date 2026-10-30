# X3c: the hybrid take under `per_core`

X3b's server model (8 workers, 16 connection tasks each, one unstriped
memtable, every 8th recv suspending), with one new way to reach the shared
instance:

- **(HY) `hy`, the hybrid.** A task that wants the instance tries one CAS on
  its word. If it wins, it runs the operation in place on its own core and
  clears the word. If it loses, it ships the operation to the instance's home
  (worker 0) on its worker's SPSC ring and suspends, exactly as H does. The
  home takes the instance by the same word before it runs shipped operations.
  `FAST=1` (drain the rings at every scheduling point, run resumed tasks
  next) and the 5 µs spin before a worker sleeps are on, as for H.
- **`TRY_SPIN_NS=N` (`hy+spin300` at 300 ns):** before shipping, retry the
  CAS for up to N ns, but only while the word says "one in-place taker holds
  it" (not the home, and the home hasn't asked).
- References, unchanged from X3b: `ship` (H, run with `FAST=1`), `park`
  (X3's parking take) and `unfair` (`os_unfair_lock`, plain callers).

## The word and the rules

The word is X3b's lock word: `L_LOCKED`; `L_HOME`, set while the home holds
it; and `L_WAITERS`, read here as PENDING, "the home has records and wants
it".

1. **In place.** A task with nothing in flight to the instance CASes
   `0 -> LOCKED`, runs the operation, and clears `LOCKED` (keeping PENDING).
   Any other state ships.
2. **Ship.** A task that loses the CAS, or **has a call or post to the
   instance still in flight**, pushes the operation on the FIFO ring from its
   core to the home. The home's own tasks push on the home's self ring.
3. **The home.** Before it runs any record, the home takes the instance
   (any state without `LOCKED` -> `LOCKED|HOME`, clearing PENDING). If that
   fails, it sets PENDING and runs none of them. It keeps the instance while
   records keep arriving, and its own tasks then call operations directly.
   It releases when a pass finds every ring empty (`LINGER_US`, default 0,
   can hold it longer; 5 and 50 µs were worse in a probe), and before it
   sleeps.

**Ordering (contract 1: one task's calls to one instance run in the order
made).** Take a task's operations o1, o2, ... in program order.
- If o(i) ran in place, it finished before its call returned, so before
  o(i+1) was made.
- If o(i) was shipped and o(i+1) runs in place, rule 2 says o(i+1) could
  only do so with nothing in flight, so o(i)'s reply or ack, which the home
  sends after running it, had arrived.
- If both were shipped, they're on the same ring, because a task doesn't
  change cores with a call in flight. The ring is FIFO, and the home never
  runs a record before the one ahead of it (rule 3: it runs none until it
  holds the instance).

With synchronous calls the first two cases are trivial, so the model adds
`POST=1`: a shipped put is posted, and the task goes on without waiting, up
to 3 in flight. Rule 2's in-flight clause is what keeps order then.
`HY_BAD=1` drops that clause, and the per-task sequence check catches it.

**No starvation.**
- The home's queue can't be starved by in-place takers. Once the home has
  failed a take it sets PENDING. No `0 -> LOCKED` CAS can succeed after
  that, so at most the current holder (one plain operation) finishes first.
- An in-place taker never waits on the home. On a lost CAS it ships, and
  the FIFO queue is drained at every scheduling point at the home.
- The try-spin only applies while the word is exactly `LOCKED` (one
  in-place holder, no PENDING), and it's bounded.

## Measurements added to X3b's

- **`op_p50/p99/max_us`:** a shared operation's wait, from the call to its
  result (for a post, until the call returns). It's sampled in a 256K
  reservoir per worker.
- **`direct_frac` / `inplace_frac` / `shipped_frac`:** how operations reached
  the instance. Direct means run on the home with no take (H's own tasks,
  or the HY home while it holds).
- **`migs_per_op`:** how often the instance changed cores between
  consecutive operations. A change moves the table's touched lines and the
  word's line. This is the cache-line transfer estimate.
- **`lw_moves_per_op`:** RMWs on the word by a core other than the previous
  one. It's only tracked in (a), since `os_unfair_lock` is opaque.
- **`reorders`:** a per-task sequence number, checked under the instance.
  Any reorder fails the run.

## Running

    build/server_a park|ship|hy|... <workers> <conns/worker> <hold_us> <bg> <secs>
    build/server_b unfair|spin       <workers> <conns/worker> <hold_us> <bg> <secs>

The environment is X3b's (`OPS`, `SHARE_PCT`, `LOCAL_US`, `REQS`,
`DISJOINT`, `FAST`), plus:
- `POST`;
- `TRY_SPIN_NS`;
- `LINGER_US`;
- `STICKY_US`: after a failed take, the home keeps the instance this long
  before it may release;
- `HOLDSTAT=1`: time in-place holds and count those over 20 µs, which mark
  a holder the OS descheduled;
- `HY_BAD`.

Every run also prints each worker's maximum request latency.

    ./build.sh
    ./check.sh > results/check-<stamp>.txt   # checksums vs 1 worker, sequence check, HY_BAD, ASan+UBSan, TSan
    ./measure.sh                             # U, C, L, M1, M10, M50; 7 interleaved rounds -> results/raw-*.txt
    ./measure_c.sh                           # C, 10 rounds: H, HY, HY linger 2 us, HY spin300, lock -> results/c-*.txt
    ./measure_sticky.sh                      # C and M10, 8 rounds: HY spin300 with STICKY_US 0, 20, 100 -> results/sticky-*.txt
    ./summarize.py results/raw-<stamp>.txt   # medians [min..max] over rounds
    ./ratios.py results/raw-<stamp>.txt C hy+fast ship+fast   # per-round ratios
    FIELD=op_p50_us ./ratios.py results/raw-<stamp>.txt M10 hy+fast unfair

The results are in ../RESULTS.md (X3c).
