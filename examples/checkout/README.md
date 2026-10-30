# Checkout

language.md's "A program, end to end", running: a domain of data and the
rules it keeps, a workflow written as a chain with a `try` on each step
that can fail, the services it needs as dependencies, and tests built
from data, nothing mocked by hand. It was written for the services
stage's first step, the pipe (compiler.md, "Services stage").

```
ren run checkout/main.ren    # what it prints is commented in main.ren
ren test checkout            # its tests
```

| File | What's in it |
|---|---|
| `order.ren` | the domain: `Money`, `Line`, `Cart`, `Discount`, a policy that's data, and `Order`, whose total is a rule it keeps, made by `price` |
| `checkout.ren` | `Orders` and `Discounts`, the services a checkout needs, and `checkout`, the workflow |
| `main.ren` | the composition root, its handlers, and the tests |

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
doesn't know whether orders are kept in memory or in a database: `main`
installs them with a `with`, and each test its own, from data:
`fixed(Flat(Money.dollars(5)))` is a discount handed to a handler.
language.md names that composition root as a wiring, which the stage's
next step builds; until then it's the `with` it flattens to.
