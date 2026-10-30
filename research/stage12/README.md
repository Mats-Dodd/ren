# Stage 12: a standard library for flottning

Design input, 2026-10-29, for stage 12: the smallest std that
flottning (CLI, server, storage engine) needs.

**Status: design input, decisions partly gaveled.** Some calls were
taken since, in foundations.md decision 20 and in the templates and
perfect-hash experiments (research/templates/, research/perfect-hash/;
the `if log.on(...)` guard revises G2 here). The owner will design
simulation later; nothing here decides it.

**Files.** synthesis.md is the result. grounding.md says what exists,
what's open and what flottning needs, research-http.md and
research-data.md survey prior art, design.md is the proposal, programs-cli-server.md and
programs-storage.md are programs written against it, and the two judge
files review it.
