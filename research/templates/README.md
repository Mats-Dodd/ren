# Templates

The templates experiment, 2026-10-29: how a library like `sql`, `html`
or `log` sees the holes of an interpolated string, with checks at build
time and no allocation.

**Decided.** The owner took every recommendation in synthesis.md:
candidate C. `"...\{x}"` stays a `Str`; `t"...\{x}"` is a
`Template<H>` that follows the block rule; a signature `let` is the one
build-time mechanism; a hole's kind is a value; `\{x=}` is `x=\{x}`.
Lazy logs use `if log.on(Debug)`, revising stage 12's G2. Raw literals,
`b"..."` and `t"..."` are decided together later. Recorded in
strings.md, "Templates", and foundations.md decision 20 rule 3.

**Files.** synthesis.md is the result. research.md is the prior-art
survey, designs.md the three candidates, programs.md the programs
written against them, perf.md the first measurements, verify.md the
re-run whose numbers the docs quote. perf/ and verify/ hold the C, Rust
and Ren sources, the scripts and the hyperfine results.

**Left out:** the compiled binaries (perf/c, perf/rust, perf/today,
verify/bin). Rebuild them with the scripts.
