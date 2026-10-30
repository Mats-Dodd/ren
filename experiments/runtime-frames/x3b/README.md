# X3b: a contended shared instance under `per_core`

X3's server model (8 workers, 16 connection tasks each, one unstriped
memtable), with the shared instance reached in more ways. One `path.c`,
two compilations, as in X3:

- **(a) `server_a`, `-DSUSP`:** the operation call is a scheduling point;
  `handle`, `route_*` and `mt_*` are suspending, in X1's register
  convention.
  - `park`, `handoff`: X3's parking take (CAS, ~1 µs spin, park; `handoff`
    adds the 1 ms hand-off).
  - `p2`: adaptive parking. Spins while the holder's worker is running, up
    to `SPIN_US` (4), then parks; hand-off on; a worker with nothing to run
    spins `IDLE_SPIN_US` (5) before sleeping.
  - `ship` (H): the memtable lives on worker 0, its home. A request on
    another worker pushes its operation as a D.Call record (op, key, value,
    task) onto that worker's SPSC ring to the home and suspends. The home
    drains its rings, up to `BATCH` (16) records per ring per pass, between
    its own tasks, runs the operations directly, and pushes replies on the
    reverse rings, publishing each ring's tail once per pass. A request on
    the home worker calls the operation directly. Workers spin
    `IDLE_SPIN_US` (5) before sleeping.
  - `shipded`: `ship` with the home dedicated (no connections; 7 workers
    serve, 8 threads in all).
  - `move`: the task hops to the home for its `at` block (pushed on the same
    rings once it has suspended), runs the block's operations directly, and
    hops back: two hops a block. `moveded`: the same, with the home
    dedicated.
  - `FAST=1` (with ship, shipded or move): the rings are drained at every
    recv, which is a scheduling point, and a task resumed by a reply or a
    hop runs next.
- **(b) `server_b`:** a thread lock, plain callers: `unfair`
  (`os_unfair_lock`), `spin` (TTAS).

Why per-source SPSC rings rather than one MPSC queue: a push is a slot write
and a release store, with no read-modify-write, and the seven producers
never contend on a shared tail line, which would be the contended word this
design exists to remove. The home polls one tail a source, and a tail's
line only moves when that source pushed. A ring is bounded (64); a full
ring fails the push and the caller waits for room (it never happened: at
most 16 calls are in flight a source).

    build/server_a park|handoff|p2|ship|shipded|move|moveded <workers> <conns/worker> <hold_us> <bg> <secs>
    build/server_b unfair|spin                         <workers> <conns/worker> <hold_us> <bg> <secs>

Environment: `OPS=N` makes a request an `at` block of N operations;
`SHARE_PCT=P` sends only P% of requests to the table and gives the rest
`LOCAL_US` (2) µs of local work; `REQS=N` stops each connection after N
requests; `DISJOINT=1` gives each connection its own keys, so the response
checksum and the final table don't depend on interleaving (the checks).

    ./build.sh
    ./check.sh > results/check-<stamp>.txt   # checksums, ASan+UBSan, TSan
    ./probe_p2.sh                            # P2's SPIN_US x IDLE_SPIN_US on C
    ./measure.sh                             # every scenario, 5 interleaved rounds -> results/raw-*.txt
    ./measure_focus.sh                       # C, M, A4, A16, 7 rounds -> results/focus-*.txt
    ./measure_at.sh                          # `at`: ship vs move, home serving and dedicated -> results/at-*.txt
    ./summarize.py results/<file>.txt        # medians [min..max] over rounds
    ./ratios.py results/<file>.txt C ship unfair ship park   # per-round throughput ratios
    FIELD=remote_req_per_s ./ratios.py results/at-<stamp>.txt A4 move ship

Scenarios (measure.sh): U (1 worker), C (8 x 16, no hold), L (100 µs hold
in put, one background task a worker), M (10% of requests touch the table,
the rest do 2 µs of local work), A4 and A16 (`at` blocks of 4 and 16
operations), W2, W4, W12 (C at 2, 4 and 12 workers).

Latency is a request's, from `next_request` to `respond`, sampled with a
1M-entry reservoir a worker. Results are in RESULTS.md (X3b).
