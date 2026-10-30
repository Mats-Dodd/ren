# X5: static frame-stack sizing, and the spare chunk (X7)

`frames.c` uses X1's convention. A task is one malloc: header plus inline
segment. Frames past the segment go in 4 KiB overflow chunks.

    build/frames_clang park <policy> 100000   # bytes per parked task
    build/frames_clang bound <policy> 5000000 # ns a call at the chunk boundary

Park policies: `today` (segment = the body's frame; read and recv in a 4 KiB
chunk), `static` (segment = the chain's static bound, 192 B, capped at 256),
`static_x` (static, plus one deep inline excursion before parking, so a spare
chunk exists; it's freed at park), `static_xk` (the same, spare kept at park).
The chain is serve -> read -> recv, 64 B frames (32 B header + 32 B locals).
Bytes are reported four ways: the malloc zone's `size_in_use` delta,
`malloc_size` summed over live blocks, and the deltas of `phys_footprint` and
`resident_size`.

Boundary policies: `inseg` (the leaf's frame fits), `free` (just past the
segment; the chunk is freed when it empties), `spare` (one emptied chunk
kept). `frames_gi_clang` inlines the grow and retire paths (`-DGROW_INLINE`).

`fastpath.c` is r2's benchmark, copied, with the plain chain fixed to repeat
its K submits (the old check printed MISMATCH at K > 1) and a `SPARE=1`
switch: `THRASH=1 [SPARE=1] build/fp_clang 1 5000000 1` measures the same
boundary in the prototype's convention (the `ren` column). Under `THRASH`
the `poll_susp` column isn't valid and isn't checked (it assumes its child
sits after the body frame).

    ./build.sh
    ./measure.sh                 # ASan checks, then 5 interleaved rounds
    ./summarize.py results/raw-<stamp>.txt
