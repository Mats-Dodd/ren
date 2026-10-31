# Generators stage tests

`test/test_generators.ml` runs the g1 specimens as ordinary assertions.
The remaining g2, g3 and g5 specimens run through `Helpers.until`; their
required output or diagnostic is separate from the current compact rejection.
When a specimen reaches its target, `until` fails with `Landed`; replace the
staging wrapper with an ordinary assertion and keep the target. Do not
promote away `Landed`.

`bench/generators.t` executes each disabled interpreter specimen and checks
its output, exit status and first diagnostic against `.pending`. This detects a changed rejection,
a crash, and an accidental success; none counts as the specified behavior.
The `stages` file enables g1. Add subsequent steps there as they land,
then update the cram transcript to the strict success messages. Regenerating
a `.pending` file is appropriate only after reviewing the changed rejection.

The fixtures have these roles:

| Fixture | Interpreter gate | Native gate and scope |
|---|---|---|
| `pure` | g1 | g4: copy/fork, storage, repeated clean end, recursive delegation |
| `cursor_show` | g1 | g4: source name and logical state, no frame data or replay-cache details |
| `cursor_eq/hash/ord_*` | g1 expect tests | g4: direct, generic and container refusals with help |
| `lifetime` | g1 | Pulled dependency frame: part two, interpreter only |
| `part_two` | g1 | g4: explicit refusal with runtime-core help |
| `stages` | g2 | g4: pushed chain, zip, user stage and composed pull |
| `lifetime_push` | g2 | g4: normal end, break, return, failure and take cleanup |
| `unique` | g1 | g4: copy captured between resumes keeps its old contents |
| `depth_push`, `depth_pull` | g1 | g4: both report the recursive-call depth panic |
| `cancel_sim` | g1 | Tasks: interpreter only in part one |
| `returns`, `return_with`, `native_refusal` | g1 | Ordinary returns agree in all native modes; dependency callback returns and generators give explicit native refusals |
| `merge_sim`, `expand_sim` | g3 | Interpreter, 1,000 simulation seeds per test |
| `replay` | g3 | Records and replays values and producer cleanup |
| `fs`, `transaction` | g5 | Named dependency frames: interpreter only in part one |
| `fs_push`, `transaction_push` | g5 | g5: pushed dependency generators and resource/transaction cleanup |
| `queues`, `close_sender` | active today | Five queue invariants across 1,000 seeds and defined closed-send panic |

Native cases compare fixed target output, status, all error text, and the
interpreter output in debug Perceus and naive RC builds, release under
ASan/UBSan, and a tcc debug build. Successful binaries must report zero live objects. Fatal depth-panic processes
keep the existing process-exit semantics: their stats are required, and output
and status agree, but no global panic-unwind redesign is implied.
`ren run --release` is also compared, separately from native compilation.
The harness fails if a required compiler is unavailable; it cannot silently
substitute cc for tcc. Runtime statistics and the already documented ASan
stack-switch warning are the only stderr lines filtered.

The OCaml suite additionally specifies all default stages/sinks, inferred vs
publicly declared empty rows (a `pub` function omitting `uses` declares the
empty row), a generator's typed failure kept after end, never-started
transactions, statement vs binding cleanup, named resume, every consumer
exit, diagnostic help, custom cursor recognition, ordinary methods named
`map`, alias vocabulary, lookahead, and capture exclusivity. Two block heads
in one call step a shared cursor sequentially; an explicit inout argument
still conflicts with the pipeline capture for the whole call. Pipeline and
filesystem targets remain staged until their owning steps land.

## Pending internal adapters and remaining coverage

`test/test_generator_contracts.ml` connects its g1 frame adapter to the real
`Generator` implementation. It checks suspended and unstarted cancellation,
independent replay positions, cleanup ownership, projected-place hooks,
consumer depth and declaration-order cleanup. The remaining adapters are
explicitly absent and print "skipped until gN"; their executable assertions
are obligations for the owning steps, not alternative implementations:

- g4: pushed and pulled recursion have the same below/at/above depth limit.
- g5: stale readers return typed Closed after mem_fs and real_fs family end,
  including after a replacement family is opened over the same path.

`Queue_contract` in `test/test_generators.ml` has the same explicit absent
adapter for g3. Its concrete assertions examine actual queue commit events,
operation outcomes, consumed vs abandoned tokens, producer completion before
return, and scheduler-recorded failure order. All six cancellation/close/
merge scenarios run across 1,000 seeds and replay their journals once a real
adapter is supplied. Final token lists alone cannot prove an unobserved
transfer's commit point; that is why this adapter is separate from the five
existing executable queue tests. The source-level cancellation cases do
not claim to observe whether an operation reached its internal wait before
cancellation. The merge source barrier observes every finalizer registered
before requiring one cleanup per source; it does not stand in for the
scheduler's failure-recording event.

These additional checks remain to be written or connected at their step:

- g2: hover/review origin text and lookahead warnings need streams metadata.
  Source diagnostics already reject exposed compiler temporary names.
- g3: consumer failure racing producer failure needs an authoritative
  scheduler trace and recorded replay. The current winner-value assertion
  only proves that admitted values precede the failure delivered to it.
- g4: assert no child-frame allocation from emitted Mem or native stats,
  beyond behavioral recursion tests. Add contained-panic native cleanup
  when the available isolation operation supports it. Part-two task and
  pulled-dependency refusals remain explicit.
- g5: add real-file eviction/reopen and file-descriptor cleanup checks after
  family end. `fs.ren` is a finite tail/resume program; a true follow-at-EOF
  program with Clock and partial lines still needs a deterministic append
  fixture. The Sql fake transaction source and pushed variant are runnable
  targets. Net.frames remains deferred to bytes part two and formats views,
  as the brief permits.

Selection, actor/channel cycles and actor delivery during family drain are
outside this stage's composition scope. Native merge/expand, produce,
map_pull and suspended dependency-frame pull wait for the runtime core.
