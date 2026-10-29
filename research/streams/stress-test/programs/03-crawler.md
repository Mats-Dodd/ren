# 3. A crawler: bounded concurrency, ordered results, a timeout per item, a failure policy per page

Read URLs from a sitemap (a lazy source: the sitemap is a file read
line by line), fetch at most 16 at once, 10 s per page, and index the
results **in sitemap order as they become ready** (not after all are
done). Policy per page: 404/410 skip; 5xx and timeouts retry 3 times
then skip; DNS failure stops the whole crawl.

## Ren, per the draft

```ren
type Outcome = | Indexed(url: Url) | Skipped(url: Url, r: Result<Unit, ! Gone | Server(code: Int) | Timeout>)

// Per-page policy: a plain function, one `match`.
fn fetch_page(u: Url) -> Option<Page> uses Web, Clock, Async ! DnsDown | Server(code: Int) | Timeout =
  try match retry(3, on: Server | Timeout) fn() =>
          try Async.timeout(Duration.seconds(10)) fn() => try Web.get(u)
    p => Some(p)
    fail NotFound | fail Gone => None                 // skip
    // DnsDown, and Server/Timeout after 3 tries, pass on

// (a) All results, in order, when the crawl ends. Default vocabulary.
fn crawl_all(sitemap: Path) -> Array<Option<Page>> uses Fs, Web, Clock, Async ! FsError | DnsDown | Server(code: Int) | Timeout =
  try Async.map(sitemap_urls(sitemap), max: 16) fn(u) => try fetch_page(u)

// Hmm: a Server after 3 tries now stops everything. To skip it instead,
// the per-item error must become a value inside the block:
fn crawl_all2(sitemap: Path) -> Array<Result<Option<Page>, ! DnsDown | Server(code: Int) | Timeout>> uses ... =
  try Async.map(sitemap_urls(sitemap), max: 16) fn(u) => attempt fetch_page(u)
  // ...and DnsDown no longer stops the crawl. Need two layers:

fn fetch_or_skip(u: Url) -> Result<Option<Page>, ! Server(code: Int) | Timeout> uses Web, Clock, Async ! DnsDown =
  try match fetch_page(u)
    p => Ok(p)
    fail Server(c) => Err(Server(c))                  // keep as a value
    fail Timeout => Err(Timeout)
    // DnsDown passes on: fatal

// (b) Streaming, in order, as results become ready: the sharp tool.
fn crawl(sitemap: Path) uses Fs, Web, Clock, Async, Index ! FsError | DnsDown | IndexError =
  let results = Async.map_pull(sitemap_urls(sitemap), max: 16) fn(u) => try fetch_or_skip(u)
  for r in try &results                               // `&` on a `let` (see 01, item 4)
    match r
      Ok(Some(page)) => try Index.add(page)
      Ok(None) => ()
      Err(e) => Log.warn("skipped", e)                // can `Err(e)` bind? errors.md says no free errors

// The source: lines of a file, a `gen fn`.
gen fn sitemap_urls(p: Path) -> Url uses Fs ! FsError | BadUrl =
  for line in try &Fs.line_reader(p)
    yield try Url.parse(line.trim())
```

Lines: policy 6 + 6, streaming consumer 7, source 3. 22 in all.

The draft's `Async.produce` form, if `map_pull` is meant to be scoped
the way `produce` is:

```ren
Async.produce(cap: 16, fn(out) =>
    try Async.each(sitemap_urls(sitemap), max: 16) fn(u) => out.send(try fetch_or_skip(u))
  ) fn(results) =>
  for r in try &results ...
```

That loses order (`each` sends as tasks finish), so it isn't a
substitute; `map_pull` is the only ordered-streaming tool.

## Elixir: `Task.async_stream` (the draft's model)

```elixir
def crawl(sitemap) do
  sitemap
  |> File.stream!()
  |> Stream.map(&URI.parse(String.trim(&1)))
  |> Task.async_stream(&fetch_page/1,
       max_concurrency: 16, timeout: 10_000, on_timeout: :kill_task, ordered: true)
  |> Enum.each(fn
       {:ok, {:ok, page}}       -> Index.add(page)
       {:ok, :skip}             -> :ok
       {:ok, {:error, :nxdomain}} -> raise "DNS down"     # fatal: raises out of the stream, linked tasks die
       {:ok, {:error, e}}       -> Logger.warning("skipped #{inspect(e)}")
       {:exit, :timeout}        -> Logger.warning("timeout")
     end)
end

defp fetch_page(u), do: retry(3, fn -> Req.get(u) end) |> classify()
```

## Kotlin Flow

```kotlin
suspend fun crawl(sitemap: Path) = coroutineScope {
    sitemapUrls(sitemap)                                  // Flow<Url>
        .map { u -> async { runCatching { withTimeout(10.seconds) { fetchPage(u) } } } }
        .buffer(16)                                       // 16 in flight, order kept
        .map { it.await() }
        .collect { r ->
            r.onSuccess { p -> p?.let { index.add(it) } }
             .onFailure { e -> if (e is UnknownHostException) throw e else log.warn("skipped", e) }
        }
}
```

Kotlin has no ordered bounded concurrent map; the `async` + `buffer` +
`await` idiom is folklore, and `withTimeout` inside `runCatching`
swallows cancellation unless you're careful.

## Rust

```rust
stream::iter(urls)
    .map(|u| async move { timeout(Duration::from_secs(10), fetch_page(&u)).await })
    .buffered(16)                         // ordered; futures only polled while the consumer polls
    .try_for_each(|r| async { match r { Ok(Ok(Some(p))) => index.add(p).await, /* ... */ } })
    .await?;
```

This is the shape behind Oxide's futurelock: while the body awaits
`index.add`, nobody polls the buffered fetches.

## Comparison

| | Ren | Elixir | Kotlin | Rust |
|---|---|---|---|---|
| lines | 22 | 17 | 11 + policy | 6 + policy |
| bounded by default | `max:` required | `max_concurrency` (default = cores) | manual `buffer` | manual |
| ordered | `map` / `map_pull` | `ordered: true` (default) | idiom | `buffered` |
| per-item timeout | composed inside | option | composed | composed |
| fatal vs skip | in the type, `try match` | runtime pattern + raise | exception type test | `Result` nesting |
| progress while consumer is busy | yes (tasks) | yes | yes | **no** (futurelock) |

**Better in Ren.** The policy is checked: `retry(on: Server | Timeout)`
is checked against `fetch`'s errors, and the type of
`fetch_or_skip` says DNS is fatal and the rest are values. Elixir and
Kotlin decide fatal-vs-skip by runtime pattern. Tasks make progress
while the body indexes, unlike Rust's `buffered`.

**Worse or unclear.**

1. **`map_pull` isn't scoped by syntax, and that breaks two rules.**
   It returns a cursor whose tasks are running. (a) When do they stop?
   At the end of the loop over a temporary, or at the drop of a
   `let`-bound one, i.e. at Perceus's last use: a cancel-and-wait at a
   point not on the page, unlike every other `Async` call. (b) Its block
   is concurrent, and decision 2 says a block passed to a concurrent
   parameter reads its captures "for the call", but the call returned
   at once. "Exclusivity, step by step" says a stage reads its captures
   only at `next`; that's false for a stage whose tasks run *between*
   `next`s. So the body can write a variable a fetch task reads: a data
   race the static check misses. Fix: give `map_pull` the shape
   `produce` has, `Async.map_pull(src, max: 16, fn(u) => ...) fn(results) =>
   for r in try &results ...`, so the scope and the read interval are the
   consumer block. (`merge` in `stream.time`, which "needs tasks", has
   the same problem.)
2. **The sweet spot needs two functions of policy.** "Some errors are
   values, some are fatal" is the normal crawl policy, and it costs a
   second function, `fetch_or_skip`, that re-wraps each tag by hand,
   because `attempt` keeps all errors and `try` keeps none.
   Something like `attempt(on: Server | Timeout) f()` (mirroring
   `retry(on:)`) would make it one line. It's a language question
   beyond streams, but streams of `Result`s are where it bites.
3. **`Async.map`'s limit.** async.md: `map` defaults to `max: 64`;
   the draft: `max:` is required over a cursor. Pick one; required
   reads better here.
4. **What thread pulls the source?** `sitemap_urls`'s `next` uses `Fs`
   and is stepped by `Async.map`'s coordinator. If the source is a
   pipeline whose stage writes a captured `var` (`fn(u) => n += 1`),
   is the source a concurrent parameter (rule B)? It must be pulled on
   the consumer's task only; say so, so it isn't a concurrent block.
5. **BFS crawling (links feed the frontier) doesn't fit** `map` or
   `map_pull`: the source can't take items from the results. It's
   `Async.scope(max: 16)` + a `Seen` dep, as async.md's crawler is, and
   that's fine, but then "results in order" means nothing. Worth saying
   the stream tools are for a known source.
