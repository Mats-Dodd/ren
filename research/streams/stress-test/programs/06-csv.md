# 06. Parse a CSV: an error per line as a value, stop on a fatal one, aggregate

The job: read a trades file with a header. A line whose numbers don't
parse is kept as a `BadLine` value and the run goes on. A line with the
wrong number of cells means the file is misaligned: stop. More than 1,000
bad lines: stop. Otherwise total the quantity and notional per symbol.

## Ren, per the draft

```ren
type Trade = { sym: Sym, qty: Int, px: Money }
type BadLine = { line: Int, why: Str }
type Totals = { by_sym: Map<Sym, Money>, rows: Int, bad: Array<BadLine> }

  pub fn absorb(self, r: Result<Trade, BadLine>) -> Totals ! TooManyBad =
    match r
      Ok(t) => { ..self, rows: self.rows + 1, by_sym: self.by_sym.add(t.sym, t.qty * t.px) }
      Err(b) =>
        if self.bad.len() >= 1000 then fail TooManyBad
        { ..self, bad: self.bad.push(b) }

// a cell that doesn't parse is a value; a row of the wrong width is fatal
fn parse_line(n: Int, line: Str, h: Header) -> Result<Trade, BadLine> ! Misaligned =
  let cells = line.split(",")
  if cells.len() != h.width then fail Misaligned(line: n, cells: cells.len())
  match attempt Trade.from_cells(cells, h)
    Ok(t) => Ok(t)
    Err(e) => Err(BadLine { line: n, why: e.show() })

pub fn summarize(path: Path) -> Totals ! FsError | NoHeader | Misaligned | TooManyBad
    uses Fs =
  var lines = Fs.line_reader(path)
  let Some(head) = try &lines.next() else fail NoHeader
  let h = try Header.parse(head)
  try lines.with_index()
    .map(fn((i, l)) => try parse_line(i + 2, l, h))
    .reduce(Totals.empty, fn(t, r) => try t.absorb(r))
```

The same with a `for`, which is what most people would write first:

```ren
  var t = Totals.empty
  for r in try &lines.with_index().map(fn((i, l)) => try parse_line(i + 2, l, h))
    t = try t.absorb(r)
  t
```

About 25 lines with the types, 8 for `summarize` itself.

## Counterparts

**Rust, `csv` crate** (the strongest here: typed rows, the reader owns
the header, and error kinds distinguish a misaligned row):

```rust
fn summarize(path: &Path) -> Result<Totals, Fatal> {
    let mut rdr = csv::Reader::from_path(path)?;            // reads the header
    let mut t = Totals::default();
    for (i, rec) in rdr.deserialize::<Trade>().enumerate() {
        let line = i + 2;
        match rec {
            Ok(tr) => t.add(tr),
            Err(e) => match e.kind() {
                csv::ErrorKind::UnequalLengths { .. } | csv::ErrorKind::Io(_) =>
                    return Err(Fatal::Misaligned(line, e)),
                _ => {
                    if t.bad.len() >= 1000 { return Err(Fatal::TooManyBad) }
                    t.bad.push(BadLine { line, why: e.to_string() });
                }
            },
        }
    }
    Ok(t)
}
```

16 lines. Note `csv::Reader` is flexible=false by default, so
`UnequalLengths` is the misaligned case.

**Elixir, `Stream` + NimbleCSV + `Enum.reduce_while`:**

```elixir
def summarize(path) do
  path
  |> File.stream!()
  |> NimbleCSV.RFC4180.parse_stream()            # drops the header
  |> Stream.with_index(2)
  |> Enum.reduce_while({:ok, %Totals{}}, fn {cells, n}, {:ok, acc} ->
    case parse_line(cells, n) do
      {:ok, t} -> {:cont, {:ok, Totals.add(acc, t)}}
      {:error, :misaligned} -> {:halt, {:error, {:misaligned, n}}}
      {:error, why} when length(acc.bad) >= 1000 -> {:halt, {:error, :too_many_bad}}
      {:error, why} -> {:cont, {:ok, Totals.bad(acc, n, why)}}
    end
  end)
end
```

15 lines. The file is closed when `reduce_while` halts (`Stream.resource`'s
after-fun), which is the cleanup property the draft cites.

## Comparison

- **Length:** Ren 8 lines for the workflow against Rust's 16 and Elixir's
  15, plus a `parse_line` all three need. Ren is the shortest, because
  the fatal/recoverable split lives in the *signature*
  (`-> Result<Trade, BadLine> ! Misaligned`) instead of in a `match` on
  error kinds at the use site. That's the draft's "error to recover from
  per item is a value; a failure ends the stream" rule paying off, and
  it reads better than both.
- **Where Ren reads better:** the error row of `summarize` lists exactly
  how the run can stop; Rust needs a `Fatal` enum and `?` conversions,
  Elixir has none. The fold with a block that can fail (`try
  t.absorb(r)`) ends the stream with the cleanup run, which Elixir needs
  `reduce_while`'s `{:halt, ...}` protocol for.
- **Where Ren reads worse:** the header. `let Some(head) = try
  &lines.next() else fail NoHeader` is fine, but then the rest of the
  file is read by *a pipeline whose receiver is `lines`*, and the draft
  never says whether that pipeline borrows `lines` or takes a copy (see
  below). Rust's reader hides the header entirely.

## What the draft forbids or leaves unclear

1. **Does `lines.with_index()` copy `lines` or borrow it?** A cursor
   method that takes a block "returns a pipeline: a cursor that holds the
   block and the cursor it reads". The receiver is written without `&`,
   so by value semantics the pipeline holds a *copy*. Here that's
   harmless (we never use `lines` again, so Perceus moves it). But
   change the program to stop at a `---` line and read the trailer from
   `lines` afterwards: with a file reader ("keeps its offset as data and
   reads with `pread`, so a copy really is an independent reader")
   `lines` is still right after the header, and the trailer loop rereads
   the body. With a socket cursor ("holds a connection id") the same
   program sees the stream advanced. **The same source text means two
   different things depending on how the cursor's author stored its
   state.** The rule should be that a stage borrows its source cursor
   (`&lines` for the pipeline's lifetime, which is exactly how a block
   captures), or that it consumes it (a use after is an error).
2. **`&` on something that isn't a place.** `for r in try
   &lines.with_index().map(...)` and the draft's own `for a, b in
   &left.map(norm).zip(...)` put `&` on a temporary, but decision 2
   defines `&p` for places. Either `&` on a temporary is allowed (and
   then the "for without & on a cursor is an error" rule is noise for
   every temporary: the copy it guards against can't be observed), or
   the draft must bind every pipeline first. Suggest: the error fires
   only when the cursor is a named place that's used again after the
   loop.
3. **A pipeline bound with `let` and stepped with `&`.** The draft's own
   example, `let errors = r.map(parse)...; for e in try &errors`, steps a
   `let`-bound value in place. Decision 1 says blocks can't be bound with
   `var` and a `let` binds one literal block. A pipeline is a block that
   mutates as it's stepped. One of the rules has to give: pipelines are
   the one block kind that `var` binds, or `for x in &p` is allowed on a
   `let`-bound pipeline because the block-kind value is never observed
   after the loop anyway.
4. **Multi-line method chains have no layout rule.** language.md §8 makes
   a line beginning with `|>` continue the line above; nothing does the
   same for a line beginning with `.`. The draft makes `.` the pipeline
   operator, and every non-trivial pipeline (this one included) wants
   one stage per line. This needs the same lexer rule as `|>`, and the
   same "all or nothing" formatting.
5. **The `try` inside a stage's block and the `try` on the `for`.**
   `.map(fn((i, l)) => try parse_line(...))` marks `Misaligned` inside
   the block, and `for r in try &...` marks it again where `next` is
   called. Both are required by the current rules (a call that can fail
   needs `try`; a `next` that can fail needs `try`). It's consistent with
   `try retry(...) fn() => try x`, so I'd keep it, but the doc should
   show it once so nobody thinks it's a mistake.

## Soundness doubts

- Point 1 is the real one: it's a semantic fork, invisible in the
  source, decided by a cursor author's storage choice. It contradicts
  "nothing found behind your back".
- None in the error model: a stage block that fails ends the stream
  after cleanup, exactly as a failing `next` does, and the error row is
  the union. Good.
