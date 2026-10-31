# Stage 12a baseline samples

`summary.json` is the reported result: seven accepted complete paired rounds.
`initial/` retains the complete original run, including its discarded round 0;
`replacement/` retains one clean replacement round. Neither original run is
edited. Warmup rounds have negative round numbers and are excluded.

A local `dune build` overlapped original measured round 0. The reported
compiler artifacts were written at 04:04:30.858–04:04:31.038 UTC on 2026-10-31;
the conservative exclusion interval is 04:04:20–04:05:07 UTC. Original round 0
spans 04:04:08.724–04:05:10.388 UTC. Its entire set of paired samples is
excluded, including samples outside the short actual build interval. Original
rounds 1–6 and one clean replacement round are used. `exclusion.json` records
this selection, and the summary retains accepted-round lineage.

Recompute the reported summary from these raw artifacts, from the repo root:

```sh
python3 -I bench/native/json/summarize.py \
  bench/native/json/results/initial bench/native/json/results/replacement \
  --exclude-primary-round 0 --output bench/native/json/results/summary.json
```

For a new measurement, build the binaries with baseline.py, then run its
measure subcommand. `--results` saves an independent run without overwriting
another run's samples. Every measured process records host load, exit status,
stdout, stderr and elapsed seconds. Native example build refusals are retained
in `unavailable_builds`; their refusal time is not a build-time baseline.
