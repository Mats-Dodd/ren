# Looks

Design work, 2026-10-29: looks, the per-type and per-field settings a
derived encoding walk reads (renames, versions, routes, statuses, CLI
names), measured against Effect v4 on flottning's API.

**Status: signed off and merged, 2026-10-29.** draft-formats.md and
draft-shapes.md were signed off with the owner's final rulings (looks
for another module's types allowed; lines under a sum look's case
allowed; `lossy` dropped, the generated test checks the wire form is
stable; settings known at build time, checked per call site by a
signature `let`) and merged into [formats.md](../../formats.md) and
[shapes.md](../../shapes.md). The drafts are kept as the record; the
decided docs are the source.

**Files.** synthesis.md is the result. effect-study.md studies Effect
v4, programs.md the programs written both ways, judge.md the review
whose fixes are in the drafts, feasibility.md checks the drafts against
the compiler, and feas/ holds its small `.ren` probes.
