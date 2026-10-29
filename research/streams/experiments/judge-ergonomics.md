# Judge: ergonomics of the amended streams design

Lens: a working programmer who reads and writes these programs every day
and also knows Kotlin, C#, Go and Rust. Inputs: e1-programs.md (13
programs on paper), e2-prototype.md (the interpreter spike), and
e4-composition.md (the audit), plus amendments.md. Group A is taken as
decided.

## Verdict in one paragraph

Group A holds up for a working programmer. E1 wrote 13 programs with no
exceptions: 7 read better than the best twin, 5 about the same, and 1
worse. E2 confirmed that every unsound program is rejected by an
existing check, quoting the messages. The everyday cost lies elsewhere,
in three places:
- **Use sites that don't show consumption.** This is decision 3.
- **The commonest loop leaks.** `for l in try Fs.line_reader(p)`
  followed by `break` holds the file open until the handler ends.
- **One idiom is safe for data and silently fatal for code.**
  `Async.timeout(d) fn() => <step>`.

None of these needs a new mechanism. Each needs one decision, and the
four calls below where I differ from the amendments or from E4 all
address them.

## Decision 3: how a named effectful generator is spelled

**Recommendation: (c) `let g = follow(p)`, with `&g` wherever it is
stepped** (`for l in try &g`, `&g.take(20)`, `try &g.next()`, and
passing it to a pull parameter). I rank (c) first, (a) second and (b)
third. Confidence: **medium (about 60%)**.

Why, from the evidence:
- **Use sites need `&` to show consumption.** E1 tallied (b) 4 and (a)
  2, and every win for (b) was at a use site. Program 13 gives the
  sharpest case. Under "one vocabulary, two receivers", `xs.take(20)` on
  an array consumes nothing. Under (a), `rs.take(20)` on a named
  pipeline consumes, and the text is identical. With `&`, the reading
  rule becomes "a name without `&` is never consumed", for every
  receiver. Program 09's `&errs.count()` is the same point.
- **Rebinding must be impossible.** Both wins for (a) were about
  rebinding: under `var`, `g = follow(q)` would close a file or roll back
  a transaction at an `=`, which is cleanup at a drop. `let` rules that
  out, and so does (c).
- **(c) needs one error, where (a) needs two.** Under (a) there are two
  errors: a missing `&` on a named data cursor, and an extra `&` on a
  named block ("a block never takes `&`"). So the writer has to know
  what kind of stream sits behind a name before writing a `for`. Under
  (c) there is one rule: a named stream is stepped with `&`, and a
  temporary isn't. The kind shows only where the name is bound: `var`
  means data you can keep, `let` means code that lives in this scope. A
  fix-it covers that one line. Swapping `Fs.line_reader` for
  `gz_lines` (program 06) then changes one keyword.
- **Seam 2 gets simpler.** A named stream goes to a pull parameter as
  `&name`, whatever its kind.
- **It needs no second meaning for `&`, if stated well.** E2 lowers a
  pipeline to a hidden `var $frame`, or `var $taken` for a chain.
  `&g` is `&` on the state `g` names, which is decision 2's "a place
  being changed". The name can't be rebound, and its state changes.

Strongest objection (E4): `&` on a `let` is exactly what the draft was
marked down for. Under (a), `&` keeps meaning only "a data place", and
(a) is what falls out with no new sentence. It also changes the wording
of decided A1's example from `for e in try errors` to
`for e in try &errors`. Block parameters change too
(`for row in try &rows`). Answer: it's one sentence in decision 2, and it
removes an error class. If the owner wants `&` kept to data places
only, take (a). Don't take (b): a `var` you can't assign is a special
case.

A detail for (c): `&g.next()` steps any named stream by hand, and `g()`
stays legal because `g` is a block. That gives two spellings for
pipelines but one across all streams. Docs and fix-its should use
`&g.next()`.

## Decisions 4–14

| # | Recommendation | Reason from the evidence | Strongest objection | Conf. |
|---|---|---|---|---|
| 4 | **`Err(Cancelled)`** on abandonment | 07: `first_big`'s `find` rolls back with no code; E2 g4/g5 ran it. It matches C# and Go, and errors.md already says only `finally` sees `Cancelled`. Apply E4 seam 9: a `finally`'s result after abandonment is discarded, as for a cancelled task. | A generator that *writes* (marks rows exported) and is cut by `.take(10)` rolls back writes for items the consumer did see. That's correct, but surprising: document it with 07. A failed rollback after `break` goes unreported. | high |
| 5 | **Ends. A later step panics, it doesn't return `None`.** | "Ends" falls out of unwinding. The trap: once `next(within:)` is dropped (seam 7), `Async.timeout(d) fn() => &r.next()` is safe on a data reader but kills a pipeline. Under the amendment, the next step then returns `None`, so a stream you can't read from looks like a clean EOF, and you lose data silently. Only a caught timeout followed by another step can observe it, and that is a bug, so make it loud. Add a `ren review` warning for a pipeline stepped inside an `Async.timeout` or race block. | A panic is a new outcome for `next`. The typed `Ended` in every row is worse. `None` is quieter but loses data silently. | medium |
| 6 | **`max:` defaults to 64** | It already says so in decision 7 and async.md; program 03 wrote `max: 16` and read fine. One rule per call. | A default of 64 on an HTTP fan-out can hammer a small server. Elixir defaults to the scheduler count. | high |
| 7 | **The time operators take a channel receiver** | Program 08 stays one line and is cancel-safe with no hidden task. A generator source goes through `Async.produce`, so the task shows on the page. **Caveat on E4's widening** ("any data cursor whose `next` is one operation"): a reader like `Net.frames` makes several `Net.read`s inside one `next`. It is cancel-safe only if `inout self` is updated in place before each suspension. State that, or keep the operators to channels. | Debouncing a generator costs an indent and a `produce`, where Kotlin hides a coroutine. | medium-high |
| 8 | **Push and eager fusion, now** | "Extracting a helper changed the cost" (05, 09) is the most ordinary edit there is. E2's `for`-over-chain rewrite compiled natively for free. Leaving it for later teaches a second, faster spelling. | Compiler lines (E2 puts the whole feature at 1,300–1,900). | high |
| 9 | **An installed `Send<T>`** | Decision 5. Program 10's B2 reads fine. No held channel value. | `Send.send(x)` stutters, and two nested producers of the same `T` would be ambiguous. That's rare: the inner one shadows, as handlers do. | medium-high |
| 10 | **A recursive `yield from` pulls at first**, with E4's invariant: when push takes recursion, it goes on the task's frame allocator, never the native stack | Pull is O(depth) per item, which programmers won't notice at directory depths (05). A stack overflow that happens only when pushed would be a difference in meaning. | Kotlin's `emitAll` is O(1) per item at any depth. | high |
| 11 | **Narrow decision 2's row** | The copy-out-and-back dance in 09 (`var r = open.get(c)` … `&open.set(c, r)`) and 10 (`replica`) is the ugliest code in the set. It hits every actor that keeps a reader. Under decision 10, a dependency call can't re-enter this handler. | It changes foundations, so it needs a soundness re-check, not just my reading. | medium |
| 12 | **A leased chunk is an ordinary root: debug report, plus a runtime copy-out under pool pressure** (E4) | The programs' `.copy()`s (02, 12) are the one thing E1 lists against Ren on framing, and a provenance analysis exists for no other value. Positions are value-relative, so a move is invisible. | strings.md, decided today, says "compile error". This reverses a decided sentence. The move must happen at a safepoint, and work when several slices share the root (they must reach the bytes through the root's header). | medium |
| 13 | **One-shot fibers, and replay for pure copies** | E2 ran it in 118 lines (OCaml 5 effects). | Replay copies cost O(position). The backtracking lexer in 11 (`let saved = p`) becomes quadratic in the interpreter. Fine for dev, but the native backend must copy frames, not replay. | high |
| 14a | `if` between pipelines is an error, with "choose inside one block" | E2: `Let_chosen` fires today | — | high |
| 14b | Stage names are reserved, with E4's renames (`skip`→`drop`, `chunks(n)`→`batch(n)`, `split_lines`→`lines`) | E2: the collision is real (test_ops `&b.take(..)`) | `count()` against `count(f)`: don't make people write `count(fn(_) => true)`. Make the predicate optional, once, for the whole vocabulary. | high |
| 14c | Document lookahead loss, **and add a `ren review` warning** | 09: `collapse(&r..).take(n)` silently drops an entry on every page. The compiler knows which stages look ahead. | Warning noise on local, one-shot uses. Warn only when the head is a stored or `&`-held reader. | medium-high |
| 14d | An N-way merge uses data readers | No program needed more | — | high |

## What the experiments show is wrong

1. **"About 450 lines" (amendments §1, §4.13) is wrong for the feature.**
   It's the generator runtime alone. E2's honest figure for the whole
   interpreter path is about 1,300–1,900 lines. The ranking against the
   alternative still holds.
2. **The second fix-it for a bare `r.map(f)`** ("`let c = r` then
   `&c.map(f)` steps a copy") brings back program 06's trap: it forks a
   file reader but consumes a socket. Drop it from the message, or adopt
   E4 seam 4 (the service checks the reader's offset, so a stale copy
   fails with a typed error).
3. **The "pure" in decided A2 has to mean the *inferred* row.** E2's
   `sneaky` declared no `uses`, called `print`, became a value cursor and
   ran. A stored value cursor could then replay outside its `with`.
   State it in the decision: "pure" is the inferred row, not the
   written one.
4. **E4's restatement of A2 isn't equivalent to it.** E4's version is "a
   frame that holds only data is data". Program 11's `tokens` is pure
   and takes only a `Str`, so it is a value cursor under the decided
   signature rule. Its frame, though, holds the `semis` pipeline across
   `yield`s, so it's block-kind under E4. E1's best compositional finding
   (wrap a pipeline in a pure `gen fn` and it's storable and copyable
   again) exists only under the signature rule. **Keep the decided
   signature rule.** Don't adopt E4's wording. The cost is the
   compiler's: a copied frame must copy nested composed frames
   relatively, which the amendments already require for value cursors.
5. **A value cursor where a block is expected doesn't fall out.** E2:
   "expected `fn() -> Option<Int>`, found `Gen<Int>`". E1's
   `semis(lex(src))` depends on it. Adopt E4 seam 2 ("what `for` takes,
   a pull parameter takes"). Under decision 3 (c), that rule is simply
   "a named stream goes as `&name`, a temporary as itself".
6. **Data readers have no prompt close.** For files, `for l in try
   Fs.line_reader(p)` plus `break` leaks a descriptor until the handler
   ends. E4's fd cache (a reader holds a path and an offset) fixes
   files. It doesn't fix `Db.rows`, whose server-side cursor can't be
   reopened, or sockets. The fix that matches A2 is E1's: the library
   ships the use-here form as a generator with a `finally`
   (`Fs.lines`, `Db.query`) and the keep form as data (`line_reader`,
   `Db.reader`). That's A2's code/data split, followed by the library.
   `ren review` should suggest the use-here form when a data reader is
   a temporary. Watch out for path-based reopening: rotated or deleted
   files need the inode in the incarnation.
7. **"Two `&r` heads in one call conflict" is new, not existing.** E2:
   `both(&r.take(2), &r.take(2))` compiles today. Keep the rule, and
   state it as decision 2's own two-`&`-on-one-place rule, since the
   heads are spelled `&r`.
8. **Not yet shown:** closing a *named* pipeline at its scope's end, or
   on failure or cancel, and the re-check on resume. Decision 3's
   argument and FIN rest on the first one. Build it before freezing.
   Error messages that say `$frame45` and `$taken28` need to say "the
   pipeline's state".

Nothing shows group A itself to be wrong.

## Smaller ergonomic notes

- **User stages can't be dotted** (11, the one program that reads worse
  than its twin). `|>` already exists for steps from elsewhere. Confirm
  that `lex(src) |> semis` takes a temporary pipeline as the first
  argument, and that a `.stage` line may follow a `|>` link. That needs
  no extension methods.
- Add `Str.Chars.at()` and `frames.at()`. They remove the lexer's
  byte-counting and explain the hand-stepped `while` in 12. The rest of
  E1's PROPOSAL list is library names. Take them.
- Add `merge_by` to the default set (04).
