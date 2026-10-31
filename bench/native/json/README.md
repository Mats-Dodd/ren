# Stage 12a hand-written baseline

`bench.ren` is an Order decoder written before the shape machinery: a
materialized tokenizer, a string match on keys, and a hand-written encoder.
Its Order follows formats.md's example: opaque OrderId, CustomerId and Money,
Time, an array of Line, Source (a sum), Option<Str>, and Audit. Source has
`parse(Str)`/`repr() -> Str`, so its default walk uses text rather than a
structural tagged object. The later derived Order.v1 must keep this same
representation when comparing its decoder to this baseline. Time is the
existing prelude type (milliseconds internally); the corpus uses Unix
seconds and the hand-written conversion uses Duration.seconds, matching the
intended Time.unix look. Money is encoded in integer cents, matching Money.cents.
OrderId and CustomerId expose integer parse/repr pairs.

The corpus alternates null/non-null notes and Web/Store, varies IDs, and
checks that every decode/encode gives the input byte for byte. It deliberately
uses ASCII strings without escapes, non-negative whole numbers, one line per
order, and every required field. The manual tokenizer rejects escapes; this
baseline makes no claim to be a general JSON implementation. A later derived
decoder must time precisely this corpus and keep separate adversarial tests.
The twins use serde_json and encoding/json on the same typed structure. The
Rust dependency is an explicit exception to the native suite's std-only rule.
Cargo.lock pins the actual resolved versions once the twin is built.

Run inside the repository toolchain shell, with no concurrent builds:

```sh
python3 -I bench/native/json/baseline.py build /tmp/ren-stage12a
python3 -I bench/native/json/baseline.py measure /tmp/ren-stage12a --runs 7
```

This rebuilds the C log-line and HTML-row prototypes and their Rust twins
from research/templates/perf (the sources reviewed by verify.md) against the
current runtime. The C reference still reuses a buffer explicitly; it is a
prototype reference, not a claim that current Ren exposes that buffer API.
SQL is excluded from 12a. All binaries and generated sources stay outside the
checkout. The original compiler is copied as `ren-baseline` for reproducible
before/after comparisons. Keep that output directory intact and use a
separate output directory for the later compiler; `--ren` selects the compiler
for both build and measure modes. `metadata.json` records hardware, versions, source
revision, compiler digest and commands; `samples.jsonl` records each rotated,
interleaved sample and host load; `summary.json` gives medians and min/max.

JSON decode, encode and checked round-trip are measured separately, at one
and twenty passes so process startup and corpus
construction can be subtracted using paired samples. Template runs likewise
include zero operations. Full sequential kernels and `ren check`/release
`ren build` for just, docs and server are timed in the same session. A small
interpreter differential run uses `smoke.ren` (4 orders, 2 passes); twins take
`4 2`. Do not compare these machine's nanoseconds with verify.md's hardware.

At the pre-stage revision, the real Fs and Clock handlers and keyed Actors
families are outside the native slice. Consequently just/docs/server native
builds are recorded with their exact refusal and exit status under
`unavailable_builds`, and their elapsed refusal times are not reported as build
times. Their successful check timings remain usable. These runtime capabilities
belong to the runtime stage; the shape baseline does not replace their handlers.
