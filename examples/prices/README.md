# Prices

A price lookup in front of a supplier that's slow and answers only so
often. A rate limiter keeps the asks under the supplier's limit, and a
cache keeps each answer for a while so most asks never reach it. It was
written after stage 7 to try dependencies, handlers and tests on
something new.

```
ren run prices/main.ren    # what it prints is commented in main.ren
ren test prices            # every module's tests
```

| File | What's in it |
|---|---|
| `limiter.ren` | `Limiter`, a dependency with one operation, `take`, that fails with `Throttled`; `Limiter.none`; `fixed_window`, a handler that lets `limit` calls through in each window of time; `token_bucket`, one that lets a burst through and then one call each time a token comes |
| `cache.ren` | `Supplier`, where prices come from; `Prices`, what the program asks; `cached`, a handler for `Prices` that keeps answers for `ttl` and asks the supplier past the limiter; tests with a supplier that counts its calls |
| `main.ren` | a slow supplier, the three pieces stacked with one `with`, and a test of what it prints |

## What to look at

**Each piece says what it needs.** `cached` is `for Prices uses
Supplier, Limiter, Clock`, so a `with` that installs it has to install
those three further out, and the compiler says which one is missing and
where to put it. `main` lists `Clock` only because the runtime has to
install the real one.

**State lives in handlers.** The limiter's window and the cache's
entries are `var`s of a handler, and each `with` gets a fresh instance,
so no test sees another's.

**Tests drive the clock.** `TestClock.advance` moves time on, so expiry
and a new window are tested without waiting, and `main`'s own
`Clock.sleep` takes no time in its test.

## What it ran into

- **The cache can't sit in front of another `Prices`.** A handler can't
  call the dependency it implements until `outer` (stage 10), so the
  backend has to be a dependency of its own, `Supplier`, with the same
  operation under another name.
- **Handlers aren't imported by name,** only types are, so they're
  written `limiter.fixed_window` and `cache.cached`.
