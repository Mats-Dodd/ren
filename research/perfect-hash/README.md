# Perfect hash and list patterns

The string-match experiment, 2026-10-29: string literal patterns, list
patterns, and lowering a string `match` to a perfect hash.

**Decided.** The owner took every recommendation in synthesis.md: the
five list-pattern rules; prefix and suffix `Str` patterns ship with
literals; the perfect hash is an invisible optimization (decision 20
rule 4), with the compare chosen by build and Lemire's page check, no
padding promise; `keys.index(s)` on a build-time constant `Array<Str>`
lowers to the hash, for any library; no case folding in the language;
a Maranget decision DAG. Patterns and the hash land in foundations.md's
Staging item 7b, libraries in stage 12. Recorded in language.md, "List
patterns and string patterns", and foundations.md item 7b.

**Files.** synthesis.md is the result. results.md is the first run,
verify.md the re-run (its numbers are the ones quoted), the fuzz and
the critique, list-patterns.md the first design note, superseded where
synthesis.md differs. code/ has the generator (gen.ml), the runtime
compare (phrt.h), the bench, the Rust twins, the gperf baselines, the
key sets and results. verify/fuzz/gen_fixed.ml has the emitter fixes.

**Left out:** binaries (`bin/`, `binfix/`, `*.exe`, `*.o`, `*.cmi`,
`*.cmx`); the generated query streams (`*.q`, 53 files, about 20 MB;
gen.ml writes them); and `dl/`, a downloaded clone of a perfect-hash
library.
