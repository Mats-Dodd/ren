# X3: colouring shared takes as suspending

A server-shaped C model: 8 worker threads, each with a FIFO run queue of
connection tasks; every request is a put or a get (50/50) on one in-memory
table behind one exclusive instance, unstriped. One program, two
compilations of `path.c`:

- **(a) `server_a`, `-DSUSP`:** the take is a scheduling point. `handle`,
  `route_put`, `route_get`, `mt_put` and `mt_get` are suspending-coloured, in
  X1's register convention. The take is a CAS; on contention it spins about
  1 us (`SPIN_US`), then parks the task on the instance's queue. Strategies:
  `park` (a release wakes the first waiter to retry; barging allowed, Go's
  normal mode) and `handoff` (plus Go's rule: a first waiter that has waited
  1 ms gets the instance handed to it).
- **(b) `server_b`:** a thread lock; callers stay plain C. Strategies:
  `unfair` (`os_unfair_lock`, blocks the thread) and `spin` (TTAS spin lock).

`serve` and `recv` are suspending in both (recv reaches a world call; every
8th recv suspends and is answered at once, so a worker interleaves its
tasks). The colour count is by construction; see the header of `path.c`.

    build/server_a park|handoff <workers> <conns/worker> <hold_us> <bg> <secs>
    build/server_b unfair|spin  <workers> <conns/worker> <hold_us> <bg> <secs>

`hold_us` folds a spin of real work into `put`, under the take. `bg=1` adds
one background task a worker (2 us of work, then yield) that never touches
the table. `REQS=N` makes each connection send N requests and stop (for
checks: at one worker every strategy must give the same checksum).
`IDLE_SPIN_US` makes an idle worker poll its queue before sleeping.

    ./build.sh
    ./check.sh                    # checksums, ASan+UBSan, TSan
    ./measure.sh                  # 5 interleaved rounds -> results/raw-*.txt
    ./summarize.py results/raw-<stamp>.txt
    size -m build/path_a.o build/path_b.o
