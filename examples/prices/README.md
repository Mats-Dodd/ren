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
| `limiter.ren` | `Limiter`, a dependency with one operation, `take`, that fails with `Throttled`; `none`, a handler that lets everything through; `fixed_window`, a handler that lets `limit` calls through in each window of time; `token_bucket`, one that lets a burst through and then one call each time a token comes |
| `cache.ren` | `Prices`, what the program asks; `cached`, a handler over `Prices` that keeps answers for `ttl`, in a `Map` by item, and asks the one under it for the rest; `limited`, one over `Prices` that asks the one under it only past the limiter; tests with a supplier that counts its calls |
| `main.ren` | `catalogue`, the handler for the real `Prices`, slow to answer; the pieces stacked with one `with`, and a test of what it prints |

## What to look at

**Each piece goes over the one under it.** `cached(ttl) over Prices
uses Clock` and `limited() over Prices uses Limiter` each implement
`Prices` by asking another `Prices`, with `next.price(item)`, so `main`
stacks them as it reads:

```
with limiter.fixed_window(2, Duration.seconds(1)),
    cache.cached(Duration.seconds(10)) over cache.limited() over catalogue() in
```

The chain installs one `Prices`; the limiter beside it is what `limited`
needs, and the items of a `with` meet each other's needs whatever order
they're written in. Each piece says what it needs, and the compiler says
which one is missing and where to put it. `main` lists `Clock` only
because the runtime has to install the real one.

**State lives in handlers.** The limiter's window and the cache's
entries are `var`s of a handler, and each `with` gets a fresh instance,
so no test sees another's. The entries are a `Map<Str, Entry>`, so an
ask is one `entries.get(item)`, and an arm's `if` says whether what's
kept is still fresh.

**Tests drive the clock.** `TestClock.advance` moves time on, so expiry
and a new window are tested without waiting, and `main`'s own
`Clock.sleep` takes no time in its test.

## What it ran into

- **Handlers aren't imported by name,** only types are, so they're
  written `limiter.fixed_window` and `cache.cached`.

What stage 9c changed, where a test sees what an importer sees:

- **`counting` is a test item,** `test handler counting()`, which only
  tests see.
- **`Calls` stays `pub`.** Only the tests use it, but only a function or
  a handler can be a test item, so it's part of `cache`'s interface: the
  one place the interface carries scaffolding.
- **`main` is `pub`,** since its test calls it.

What stage 10a changed: the cache used to ask a dependency of its own,
`Supplier`, since a handler couldn't call another implementation of
what it implements. Now `cached` and `limited` go `over Prices`, the
supplier is a plain `Prices`, and `Supplier` is gone.

What stage 10c changed: `catalogue` and `none` were records of
functions, `Prices { price: fn(item) => ... }`. A record can't keep a
block under [foundations.md](../../foundations.md), so each is a
handler, `handler catalogue() for Prices`, and `none` is installed as
`limiter.none()`.
