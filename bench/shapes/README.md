# Stage 12a targets

`test/test_shapes.ml` contains skipped interpreter targets grouped by
`until "s1"` through `until "s8"`. Its `enabled` list is empty. Enabling
a stage runs assertions over actual compiler results. Diagnostic targets
require an error, help, and the named relevant fragments. `Helpers.run`
checks ordinary and release interpretation together. No disabled target
counts as implemented behavior, and no observed output is promoted into a
future target's oracle.

The inventory is 60 gated OCaml groups. The native harness shares all 42
literal runtime sources and their exact expected output, all 23 typed
golden vectors and eight malformed binary vectors directly from that
file; strict counts prevent an extractor change from silently dropping a
target. Negative single-file targets use `Driver.check`, so build-time
assertions and budgets are tested through the check command's semantics.

The source targets cover explicit types/comparison ambiguity/defaults;
build-time dependency order, cycles, errors, budget, world/block refusals
and inferred uses; template forms, eager ordering, block rules, signature
plans/refusals and site metadata; declaration, visibility, direction,
conversion-chain and duplicate-look checks; opaque parse/repr, walk
precedence, dynamic identity, absence and Problem paths/first/all modes;
json defaults, null, strictness, sums, casing, Raw/extra, Value, recursive
Ref, numbers, map keys and depth; CLI positionals/shorts/subcommands,
choices, parsed leaves, did-you-mean/help and dependency Call; prelude
imports; bin scalar/product/sum/recursive/collection/opaque families,
fixed bytes and malformed encodings; and freezing.

`python3 bench/shapes/check.py` reads `stages`. Its enabled differential
targets first match fixed expected output, then compare debug and release
under both RC strategies, ASan/UBSan, tcc and release interpretation.
Every native target must report zero objects live at exit; unknown stderr,
missing native tools, and sanitizer diagnostics fail rather than skip.
Further gated checks inspect static C, measure template allocations for
0/1/4/17/64 dynamic holes, check copy-name stability after adding an earlier
call, and compare `ren explain` with shapes.md's exact table. The freezing
target creates a real temporary project and formats.lock, checks unchanged
input, then separately changes a field, reached conversion and look name.
An unrelated function edit must pass, and a rejected build must leave the
lock file byte-for-byte unchanged.

The OCaml s8 target invokes this same real on-disk fixture with
`REN_SHAPES_CLI_TEST=/absolute/path/to/bench/shapes/check.py`; it fails if
that adapter is missing. `--freeze-only` forces the fixture when invoked
by that enabled test. Native implementation milestones enable s1/s2/s3
for the front-end/build-time/template cases, and s7 for json/bin.

All future Ren sources need validation when their owning step lands;
they cannot be parsed against today's absent syntax. Expected diagnostics
and positional error rendering follow the design and existing printer.
They may be refined only to match the implemented specification, never to
weaken the target. The allocation test consumes each template's actual
hole tuple hash and static part count in a loop, so its consumer does not
simply discard the argument.

The runtime-core stage has not supplied its canonical-bin/hash helper or
journal encoder/golden-vector fixtures yet. Our literal byte vectors
follow its table in compiler.md's “Binary journal”; no second compiler
hash helper or journal encoder is introduced here. Journal-byte
comparison must be connected when that owning implementation lands. A
Layout-in-Array<Look> specimen cannot be executed while 12a explicitly
refuses layout declarations; the unsupported-layout refusal is tested.
The measurements and performance gates live with bench/native's baselines,
not these semantic tests.
