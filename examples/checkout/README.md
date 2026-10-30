# Checkout

language.md's "A program, end to end", running: a domain of data and the
rules it keeps, a workflow written as a chain with a `try` on each step
that can fail, the services it needs as dependencies, and tests built
from data, nothing mocked by hand. It was written for the services
stage's first step, the pipe, and named its composition root a wiring in
the second (compiler.md, "Services stage").

```
ren run checkout/main.ren -- pg://localhost/shop    # what it prints is commented in main.ren
ren test checkout                                    # its tests
ren explain-wiring live checkout/main.ren            # the order `live` is installed in
```

| File | What's in it |
|---|---|
| `order.ren` | the domain: `Money`, `Line`, `Cart`, `Discount`, a policy that's data, and `Order`, whose total is a rule it keeps, made by `price` |
| `checkout.ren` | `Orders` and `Discounts`, the services a checkout needs, and `checkout`, the workflow |
| `pg.ren` | `Pg` and `pool(url)`, a stand-in for a Postgres client: a pool that can't connect to anything but a `pg://` URL, whose tables are kept in memory |
| `main.ren` | the composition root, `live`, a wiring; its handlers, `sql_orders` and `discounts_from_db` over the pool, and those the tests build from data; and the tests |

## What to look at

**`.` and `|>` say where code lives.** `o.total()` is what an `Order`
knows about itself; `|> try place` is a step from elsewhere. `x |> f(a)`
is `f(x, a)`, checked as that call: `|> order.price(d)` calls the
`order` module's `price` with the lines `validate` gave.

**The `try`s are the workflow's failure points, on the page.** `|>` ends
a `try`'s reach, so `validate` and `place` each carry their own, and
`price`, which can't fail, carries none. A step that can fail without
its `try` is an error, and so is a `try` on one that can't.

**`uses Orders, Discounts` is the workflow's whole list of needs.** It
doesn't know the real `Orders` needs Postgres. `main` installs the
services with `live`, a wiring (language.md §5):

```ren
pub wiring live(url: Str) provides Orders, Discounts uses Net ! DbDown =
  pg.pool(url), sql_orders(), discounts_from_db()
```

A `with` that lists `live` installs its three items, one set, in the
order the compiler finds: the pool first, since the other two need it.
Its body sees only what `live` provides, so a body calling `Pg.insert`
is an error, "`live` installs `Pg` but doesn't provide it". It needs the
network from outside, and can fail to start, a URL the pool can't
connect to, so `main` installs it with `try with`. language.md's `main`
serves `routes` over HTTP, which Ren can't yet, so this one's `serve`
answers three requests; and it says it can fail with `DbDown`, since a
public function's errors are written.

Each test installs its own services, from data:
`fixed(Flat(Money.dollars(5)))` is a discount handed to a handler. One
installs `live` itself, `with live("pg://test") in`: the built-ins get
their test implementations in a test, so nothing is replaced.
