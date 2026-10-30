# Boundary audit against foundations.md decision 20

Scope: foundations.md, language.md, operators.md, errors.md, strings.md, streams.md,
formats.md, shapes.md, stdlib.md, async.md, handlers.md, deps.md, testing.md,
runtime-io.md, README (language, testing, observability, tooling sections). compiler.md
is cited only as evidence of what the decided docs mean (the services-stage spec).

Rules: R1 no media/protocols in the language; R2 std has no powers a user library lacks
(except the world/runtime handlers); R3 language owns declarations-as-data, type rules,
build-time checks through top-level let/assert only, the derived walk and its reserved
names; R4 optimizations are invisible; R5 policy lives with its library; T the toolchain
reads the language, never a library.

The pattern behind most findings: **actors, striped, the journal/trace recorder and
formats grew compiler support for themselves alone.** Three general primitives would
remove most of it: *a call as a value*, *a keyed set of live instances*, and an
explicit, complete list of the runtime's privileged handlers.

---

## A. Real violations

### A1. actors and striped hold instances, which nothing else can (R2)
- foundations.md:921-923, 1228-1230 ("Held instances" given up; "a stripe is never named"),
  foundations.md:928-1065 (decision 18), language.md:587-589 ("The one function that
  installs is addressing"), language.md:1237-1300; compiler.md:10407 (`actors` "in the
  prelude"), 10338-10342 (`Merge<D>` "built in, as `Actors` is").
- Why: the bet says a program never holds an instance. actors keeps a map of live
  instances by key, evicts them, pins them, and runs their `finally`; striped keeps n.
  No user library can write either, so they are std with a power users lack, and they
  aren't world or runtime handlers. A third-party "actors with TTL" or "consistent-hash
  stripes" can't be written.
- Fix (generalize into a primitive): the language/runtime owns **one** primitive, a keyed
  family of live instances of a handler: make on demand, pin for a block, evict one,
  enumerate, a per-key queue of call values (A3), and the static rules that make it sound
  (inner-to-outer waits, `finally` can't fail, no `at` inside `at`). `actors` (bound,
  LRU/LFU, mailbox bound, `evict_idle`) and `striped` (n fixed keys, routing, merge) become
  plain Ren over it. If that's too much for v1, keep them privileged **and add them to
  decision 20's exception by name**, with the reason (they hold instances).

### A2. `Merge<D>`: a dependency the compiler derives for one library (R2, R3, and shapes.md's "no generating types")
- foundations.md:1052-1058; language.md:735-739, 1329-1337; compiler.md:10338-10348
  (Resolve and Infer special-case `Merge<D>`).
- Why: a type generated from another type's declaration, used only by `striped`.
  shapes.md:254-266 rules out generating types and code; this does it, for one library.
- Fix (smallest): `Custom(m)` takes a stateless generic handler `over D` whose
  `call(op, args)` clause folds, the mechanism shapes.md:175-211 already gives every
  library; or drop `Custom` and say a fold the menu lacks is written as an operation
  that returns a `Concat`-able value. Either way `Merge<D>` goes.

### A3. `post`, routing by key and their checks are compile rules for one library (R2, R3)
- foundations.md:980-993 (only `()`-returning, non-failing operations may be posted:
  "a compile error"), 984 (mailbox holds "the enum of `D`'s operations the compiler
  writes"), 1046-1049 (an operation "whose first parameter has a `key`" goes to one
  stripe; `n` with `by: Worker` "is an error"), 1056-1058 (`merge:` missing is a
  compile error), 1010 ("the compiler may meter only operations that post");
  compiler.md:10320-10336 (Infer checks `striped`'s call; `keyed_described` becomes
  `striped_described`; `Sum` on a non-number refused by Infer).
- Why: each is a check or lowering written for `actors`/`striped`, not through a general
  mechanism. runtime-io.md:29 already states the general idea, "a call is a value", and
  shapes.md's `call(op, args)` half-implements it.
- Fix: make **a call as a value** a language primitive, typed by its result and errors
  (`Call<D, R ! E>`, made by `D.op.call(args)` or similar). `post` takes a `Call<D, ()>`
  with no errors: a plain type check, no actors rule. Routing by key reads `args`' first
  `key` through the derived walk. Journal entries, mailboxes, `rpc.client` and
  `over any` all use the same value. Make `by: Worker`/`n` a data-design fix:
  `by: Key(n: 16) | Worker`, so the illegal combination can't be written. `merge:`
  required: a `striped` over a dependency with a keyless value operation takes a
  different constructor, or `merge: Merge` with no `Unmerged` default; either way the
  type says it, not Infer.

### A4. The runtime and toolchain know actors' policies (R5, T)
- foundations.md:1032-1039 (`sim.scheduler(seed, evict: AnyIdle)`; the journal names
  `docs[DocId(7)]#3`), 1086-1091 (the runtime table per library), 1420;
  compiler.md:10901-10903 (`ren test --chaos` opts into `evict: AnyIdle`; `Chaos` is
  `sim`'s type).
- Why: the scheduler takes a parameter whose only meaning is "evict actors"; the journal
  format names a library's families and incarnations; a toolchain flag exists for one
  library's policy.
- Fix: chaos eviction is a parameter of `actors` (or a `Faults`/tape dependency `actors`
  reads), not of `sim.scheduler`; drop `ren test --chaos` (a test installs the
  chaotic family). Instance labels in the journal come from a general rule (an instance is
  labelled by where it's installed plus a key the installing library gives, as tasks are
  by spawn site), so any family library gets them. Keep the runtime table as a statement
  that falls out of decision 10's general rule (exclusion is skipped unless shared), and
  expose `by: Worker`'s need as a scheduler operation (`Async.worker()`) any library can
  call.

### A5. Two privileged recorders, while decision 20 names none (R2, T)
- README.md:998 ("the trace recorder is the one privileged dependency, woven into call
  sites by the compiler"), 915-916 (span metadata extracted at compile time; a
  *recorded* bit in the count word for the tracer), 952-962 (`ren trace pull`,
  `ren replay trace.bin`, `ren profile --request` read the tracer's files);
  handlers.md:633-641 ("The recorder is the one privileged handler ... journal.ml is the
  one place that knows the format"); vs shapes.md:206 and foundations.md:1272
  (recorder/replayer as ordinary `over any`/`call` libraries); runtime-io.md:136-150,
  163 (the journal is part of the runtime).
- Why: decision 20's exception lists `Fs`, `Net`, `Clock`, the scheduler. The docs
  disagree whether the journal is the runtime's or a library, and the README adds a second
  privileged tracer with its own runtime bit and compiler weaving. If it's a library,
  the toolchain reading it violates T.
- Fix: decide once. Recommended: **the journal is the runtime's record** (decision 11
  already says so: polls, scheduler tape, task paths), named in rule 2's exception; the
  recorder over the world's handlers is part of it, so `ren replay`/`ren test --keep`
  read the runtime, not a library. Recording user dependencies, tracing, the flight
  recorder and OTLP are plain Ren over `call` (A3). The README's compile-time extraction
  and *recorded* bit become invisible optimizations of any handler that keeps
  `call.args` (R4), or go. Delete README.md:998's "one privileged dependency".

### A6. `secret` is language syntax for a log/trace policy (R1, R5)
- README.md:921 (`type ApiKey = secret Str` "is never recorded or printed");
  stdlib.md:374 (`db_url: secret Str`).
- Why: a type modifier whose only meaning is a logging/tracing policy.
- Fix (move to std): `Secret<T>`, an opaque std type whose `show`/`repr` redact and
  whose value is reached by `.reveal()`. Since printing, logging and the journal all go
  through the derived walk, redaction needs no compiler rule. The journal's policy
  (record it or not) is the journal's.

### A7. `Decimal`'s `d` literal: language syntax for a std type (R1/R2)
- stdlib.md:167, 184 ("`Decimal` gets the `d` suffix, so it's in the prelude"; "Its
  literals are part of the language"), stdlib.md:430 (stage 12).
- Why: a third-party `BigDecimal` or `Money` can't have literals, and the language names
  one std type's spelling.
- Fix, pick one: (a) make `Decimal` a language number type beside `Int` and `Float`,
  with the stated reason that a literal's type comes from its spelling, which only the
  compiler can do (R3); or (b) a general literal primitive: a type declares a reserved
  `from_literal(text: Str) -> T ! E`, run at build time for literal arguments (the
  top-level mechanism), so `19.99d` is sugar any type can own. (a) is smaller and honest.

### A8. Formats: a byte medium in the language, and decision 20's example describes formats that don't exist (R1)
- foundations.md:1178-1190 (decision 20's example: `customerId = customer`, "a tag is a
  constant ... json makes it a string, http a route", "libraries own spelling");
  vs formats.md:102-266, foundations.md:1093-1136, language.md:1357-1428: a format
  is bytes only: `le`/`be`, `UInt24`, `F32`, `VarUInt` (LEB128), `CStr`,
  zero-terminated and UTF-8 fields, `UInt8 { Leaf = 1 }`; nothing reshapes, nothing is
  medium-neutral, json can't use it.
- Why: as written, formats.md puts one medium (binary layout, with specific encodings
  like LEB128 and C strings) in the language, and decision 20 claims the language has
  none while using formats as its example.
- Fix, pick one and make both docs say it: (a) **keep with a stated reason**: bytes are
  the one medium the language owns, because `Bytes` is a language type and a view's
  promise (checked once, then each field a load) is a type rule only the compiler can
  keep (R3) and an inlined accessor (R4); then rewrite decision 20's example to match,
  and drop the json/http claims; or (b) split `format` into medium-free reshaping (field
  mapping, constants, distinct typed tags, lengths/counts: language) and a field-kind
  vocabulary a library supplies (bytes: `le`, `VarUInt`, `CStr`; json: names, strings).
  (b) is the design decision 20 describes but a large change; (a) is the smallest fix
  that makes the docs true today.

### A9. `call.args` "encoded to and from the journal, by functions the compiler derives" (R3, T)
- foundations.md:420-425; handlers.md:214 (`call.name` "as the journal writes it");
  compiler.md:3644 ("`call.args` can only be shown, compared and recorded").
- Why: the compiler derives encoders for one library's format. shapes.md:188-211 replaces
  this with `call(op, args)` and `args` as the dynamic `Value`, a general primitive.
- Fix: say `call.args` are values the derived walk covers (`show`, `==`, `repr`/`parse`),
  which any encoder uses; the journal is one such encoder. Reconcile decision 7's
  `call.forward()`/`call.args` with shapes.md's `call(op, args)` so there's one mechanism.

### A10. A channel's cursor is derived by the compiler (R2)
- streams.md:444-447; async.md:276 ("`Events.items()` is a cursor the compiler derives").
- Why: a derivation for one std dependency (`Chan<T>`).
- Fix (move to std): declare `items` as a function of `dep Chan<T>` in `sync`, a
  cursor or `gen fn` over `recv`, as `Fs.read_str` is a function of `Fs`
  (deps.md:393, async.md:64-66 already allow functions on a dep).

### A11. `Pool` is generic over exactly two collections by compiler fiat (R2), and the docs disagree
- language.md:1121-1126 ("`Pool` can't be generic over any collection ... the compiler
  handles exactly those two"), 1137-1138 (prelude) vs foundations.md:780-788
  ("Indices are a library").
- Why: a user's `Pool`-like type over their own collection can't be written, and
  foundations says it's a library.
- Fix (move to std): `Pool<T>` is plain Ren over `Table<Slot<T>>` with
  `Slot<T> = { gen: Int, value: Option<T> }`; `Table`'s flattening already puts the
  generation in its own column, which is the whole reason for `Pool<Table<..>>`. Offer an
  `Array`-backed twin as a second library type if a measurement needs it. `Table` itself
  stays in the language (see C).

---

## B. Blurred

### B1. The privileged list is incomplete
- foundations.md:1149-1152 names `Fs`, `Net`, `Clock`, the scheduler. The docs also
  give runtime powers to: `Random`, `Console`, `Os`, `Proc`, `Signal`
  (deps.md:372-447, runtime-io.md:111-125), `Mem.arena()` (foundations.md:567-601),
  `snapshot(v)` "a standard-library handler" that needs QSBR reclamation and a
  copy-out budget from the runtime (foundations.md:615-628), `Alloc`
  (stdlib.md:68), `Async.chunks`/`Async.map` across cores, and the journal (A5).
- Fix: make the exception a complete, closed list: the world (`Fs`, `Net`, `Clock`,
  `Random`, `Console`, `Os`, `Proc`, `Signal`), the runtime (`Async`/scheduler, `Mem`
  with arenas and `snapshot`, `Alloc`, the journal). Rename `snapshot` into the runtime
  (`Mem.snapshot`) or say it's the runtime's; then every other std module is plain Ren.

### B2. The unicode version in the journal, by reachability of one module (R2, T)
- strings.md:229-234.
- Why: the journal header records `unicode`'s table version only if the compiler sees the
  program reach `unicode`: compiler knowledge about one std module.
- Fix (generalize): the journal records a fingerprint of the pinned top-level data a
  program reaches (time zones, Unicode, any library's tables), computed from top-level
  `let`s, which the build already hashes (shapes.md:246). `unicode` gets it for free.

### B3. Stream stages: a std vocabulary with compiler privileges (R2, R4)
- streams.md:166-172 ("a block that the compiler writes where the chain is"), 224-225
  (stage names reserved on any type with `next`), 316-321 (built-in stages fused into the
  push; a user stage pulls), 529-532 (fusing user stages "later").
- Why: built-in stages get push fusion and method syntax on a structural protocol; a
  user's stage gets `|>` and pull. Measured as a small cost (1.01-1.05), so it's mostly
  R4, but it's a std power.
- Fix (keep with a stated reason, and narrow): say the default stages are written as
  `gen fn`s in std, that the compiler's push lowering applies to any one-input `gen fn`
  stage (user or std) when it's built, and that the reserved stage names are the price of
  method syntax on the cursor protocol, which the language owns because `for` needs it.

### B4. Async's checks: by parameter kind, or by `Async.scope`'s name? (R3)
- foundations.md:366-372 (a task can't reach a handler installed inside its scope),
  404-409 (`race`'s branches can't fail), 625-628 (`s.spawn` carries `Async`),
  1306-1309 (rules B-D about "concurrent and spawned parameters").
- Why: the scheduler is privileged code, but rule 3 forbids checks written for one
  library. These are fine if they hang on parameter kinds (spawned, concurrent) and on
  block types (`race` takes `fn() -> T` with no `!`), and only the runtime's functions
  declare spawned parameters.
- Fix: one sentence in decision 7 or 20: Async's checks are checks on spawned/concurrent
  parameter kinds, which only the runtime's functions declare. No new mechanism.

### B5. The reserved names aren't one closed list
- foundations.md:1158-1159 lists `show`, `key`, `parse`, `repr`; `repr` is defined
  nowhere else. testing.md:241-252 adds `arbitrary` ("a reserved member like `key` and
  `show`"); operators.md:36-49 has `add`..`neg`, `zero`, `one`; `hash`; cursors' `next`
  and the stage names (B3).
- Why: a reserved name is a language promise; a test library's hook (`arbitrary`) is
  either part of the derived walk (generation through constructors) or a library's policy.
- Fix: one list in decision 20: the derived walk's names (`show`, `repr`, `parse`, `key`,
  `hash`, `arbitrary` as the walk's generate direction), operator methods, and `next`.
  Define `repr` where `show` is defined, or drop it.

### B6. Library defaults written as language decisions (R5)
- foundations.md:358-361, async.md:82 (`max` 64, "a server writes `max: 10_000`");
  foundations.md:955-956, 1006-1008, 1079-1083 (`max`, `mailbox` 10_000, `parts`,
  "a family is always bounded"); 1046 (`n: Int = 16`); stdlib.md:300 ("ordered iteration
  for determinism") is fine.
- Why: these are std's settings and policies; the decision record should carry only what
  the runtime guarantees (bounded waits, the inner-to-outer rule, fairness).
- Fix: move the numbers and "always bounded" to the std docs for `Async`/`actors`/
  `striped` (their signatures); foundations keeps the guarantees. Low priority.

### B7. Tests get std's fakes by default
- deps.md:372-381, testing.md:88-120 (a test runs on `sim.scheduler`, `sim.clock`,
  `mem_fs`, `test_proc` without installing them).
- Why: the toolchain picks library handlers. Acceptable only because these are the world
  and runtime handlers' test twins (privileged by B1).
- Fix: one sentence: test defaults exist only for privileged dependencies; anything else
  is installed by the test.

---

## C. Correctly placed, worth stating as examples

- **json, toml, cli, SQL rows and `bin` over `T.shape`** (shapes.md:117-166,
  formats.md:452-470): std formats are plain Ren over a general primitive; release
  specializes them to serde's speed (R2, R4). The canonical example for rule 2.
- **`retry(n, on:)` over `Tags`** (compiler.md:3606-3628, foundations.md:398-403):
  retry is ten lines of Ren; `Tags` is a prelude parameter type any function can take,
  checked against the block's errors generally. A model of R3's "general mechanism".
- **`Async.limit`/`sync.limit` and `traced` as `over any`/`call` handlers**
  (shapes.md:198-211, foundations.md:1272): the "built-in, now a library" move done right.
- **`sql"..."`: interpolation a library can intercept** (stdlib.md:386, proposed):
  the right shape for literals and DSLs (see A7(b)).
- **`Table` in the language** (language.md:1019-1044): layout is the compiler's, and
  `Table` means exactly `Array` (R3 and R4 together). Contrast `Pool` (A11).
- **Optimizations that change no meaning** (R4): release specialized for the runtime
  `main` installs (foundations.md:460-463); `Async.map` on every core when its block uses
  nothing (415-416); `Float` sums as a fixed tree in every build (847-853); NaN and
  overflow at the same point in every build (802-804); arenas change cost never meaning
  (570-575); a recursive `yield from` with one depth limit whether pushed or pulled
  (703-705); loop cloning per handler (268-274).
- **World access only through built-ins' real implementations, checked by Core Lint**
  (language.md:522-524, handlers.md:655-659): rule 2's exception enforced mechanically.
- **`lockfree handler`/`Atomic`, `release`, `key`** (foundations.md:497-509, 629-636;
  operators.md:115-158): general primitives with no library in them.
- **Build-time checks through top-level `assert`** (shapes.md:31-77, 213-240;
  formats.md:440-450): `assert PageHeader.disk.size == 32` and
  `assert handle_request.uses <= [...]` are R3's one mechanism.
- **Policies as data and conventions** (language.md:735-739, stdlib.md:206-224): `evict:
  Lru`, `merge: Sum` are ADTs in std; the error-tag rule is a written std convention,
  not a language rule (R5's "written convention").
- **`Str` is UTF-8, and Unicode tables stay out of `Str`** (strings.md:59-71,
  216-240): the type's invariant is the language's; normalization, case and graphemes are
  the `unicode` library's.
- **Middleware as `with`, routes as descriptions or a user ADT** (stdlib.md:198-199,
  language.md:696-717): http needs no language support.
