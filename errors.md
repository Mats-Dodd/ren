# Errors

How a Ren function says it can fail, how a caller sees it, and why it works
this way. This is stage 6 of the [roadmap](README.md#roadmap). The short
version is in the README's [Errors](README.md#4-errors) section.

## What error handling has to do

1. **You can see it.** Every point where code can fail is marked where it
   happens, so you can follow the control flow by reading.
2. **You can't ignore it.** Every failure is either handled or passed on,
   and the compiler checks that.
3. **The signature is exact.** It lists the ways a function can fail, and
   nothing more.
4. **Passing it on costs one word.** No wrapping, converting or glue code.
5. **Handling is precise and stays checked.** You handle what you can deal
   with. When a new kind of failure appears, the compiler points at every
   place that has to decide what to do about it.
6. **Libraries compose.** Code that calls two libraries needs no glue
   between their errors.
7. **Bugs aren't errors.** Out-of-bounds access, a failed `assert`, or
   `unwrap` on `None` panics instead.

Each rule below follows from these.

## Failing

A function lists what it can fail with after `!`. Each error is a **tag**,
with an optional payload, like a constructor:

```ren
pub fn debit(inout self, m: Money, e: Entry) ! Short(account: AccountId, by: Money) | Frozen(account: AccountId) =
  if self.frozen then fail Frozen(self.id)
  if not self.balance.covers(m) then fail Short(self.id, m.minus(self.balance))
  self.balance = self.balance.minus(m)
  &self.statement.push(e)
```

- `fail X` stops the function with the error `X`. It has the type of
  anything, so `if … then fail X` needs no `else`.
- A `pub` function writes its errors out in full, exactly as it writes its
  `uses`. A private function's errors are inferred; it writes nothing.
- A name for a set of tags is declared with `!`, and can include other sets:

```ren
pub type Refusal = ! Short(account: AccountId, by: Money) | Frozen(account: AccountId)
pub type TransferError = ! Refusal | NoSuchAccount(account: AccountId) | SameAccount
```

Signatures are long when a function can fail in many ways. That's
accepted: the signature is the contract, and it's exact.

## Tags are structural

Tags aren't declared and don't belong to a module. `fail NotFound` just
works. Two tags with the same name and the same payload are the same error
wherever they come from, so `Timeout` from two libraries composes with no
glue (rule 6). If one error set would contain two shapes of one tag, that's
an error asking you to rename one ([module-build.md](module-build.md#error-tags-have-no-home)).

**Why not ordinary sum types, like Rust?** Because they make signatures
inexact. If `credit` and `debit` both return `! Refusal`, every caller of
`credit` has to handle `Short`, which can't happen. Programmers then write
`_ =>`, which also swallows the next error anyone adds, and turns off the
exhaustiveness checking you wanted (rules 3 and 5). And code that calls two
libraries needs a wrapper type and a conversion at every call (rules 4
and 6).

**What it costs.** A misspelled tag, `fail NotFuond`, is a new error until
it reaches a `pub` signature or a `match`, which then rejects it and
suggests the right name.

**Tags aren't values.** They appear only after `!`, after `fail`, in a
`match`'s `fail` arms, and inside `Err(...)`, in a pattern or as the error
a `Result` holds. A sum type is never an error, and an error is never a
sum type: to say why something didn't happen as part of a value, use a
sum type, as before. An error held as a value is always inside a
`Result`: the one kept by `attempt` (below), or one written with its tag,
`Err(Short(a, Money.dollars(1)))`, which is what a test compares a kept
one with.

## Marking

Every call that can fail is marked:

| Marker | What it does |
|---|---|
| `try f()` | passes `f`'s errors on to the caller |
| `match f()` with `fail` arms | handles them here |
| `attempt f()` | turns the outcome into a `Result` value |
| `x orelse fail X` | turns an `Option` into an error |

A call that can fail without one of these is an error. So is a marker that
covers nothing that can fail, the same rule as an `&` on a call that changes
nothing, so the markers never drift from what they mark.

`try` covers every call to its right in the same expression, as in Swift:

```ren
print(try acme.statement(bob).len())     // covers statement(); len() can't fail
let n = try parse(read(path)) + 1        // covers read() and parse()
```

`attempt` makes a value, a `Result`, which is usually compared next, so
it covers the calls to its right up to a comparison: `attempt f() == x`
is `(attempt f()) == x`, and `attempt a() + b()` is `attempt (a() + b())`.

## Handling: `match`

Errors are handled with `match`. A `fail` pattern matches an error; any
other pattern matches the value the call returned:

```ren
match &acme.transfer(t)
  _ => print(0)
  fail Short(_, by) => print(by)
  fail Frozen(id) => &acme.unfreeze(id)
  fail NoSuchAccount(_) | fail SameAccount => panic("bad transfer")
```

- The keyword that raises an error is the one that matches it.
- Exhaustiveness covers values and errors together: every error the call
  can fail with needs an arm.
- `_` matches a value, never an error. `fail _` matches any error. So a
  stray `_` can't silently swallow a failure.
- `try match` handles some errors and passes the rest on. The line still
  starts with `try`:

```ren
let user = try match load_full(id)
  u => u
  fail NotFound => guest()
```

- An arm can fail with something else, which is how one error becomes
  another: `fail Short(_, _) | fail Frozen(_) => fail LateRent`.
- A call in an arm that can fail is marked like any other.

There is no `catch`: handling an error is pattern matching, so it's a
`match`.

## Keeping an error: `attempt`

`attempt f()` runs `f` and turns what happened into a value, `Ok(v)` or
`Err(tag)`, instead of acting on it now:

```ren
let r = attempt &acme.transfer(t)      // Result<Unit, ! Refusal | NoSuchAccount(account: AccountId) | SameAccount>
print(r)                               // Err(Short(AccountId(2), Money(45000)))
try r                                  // fail with it again, later
```

(`ren types` writes the unit type `Unit` here, as it does everywhere: an
earlier draft wrote `Result<(), ...>`, but `()` is a value, not a type
name.)

It's for an error that has to outlive the line it happened on: one decided
on later or by another function, outcomes collected from many calls, a test
that checks a call fails, and, in later stages, an error handed to another
task or to the journal.

A test writes the error it expects inside `Err`, by its tag, and compares:

```ren
assert attempt &acme.transfer(t) == Err(Short(a, Money.dollars(1)))
```

Where the `Result` it makes meets one that holds what something can fail
with, what an `attempt` kept or a function's declared result, the tag has
to be one of those errors, as in a pattern, so `Err(Shrot(...))` is an
error rather than a comparison that's never true. That's so on either side
of `==`, through a `let` or inside another value, `Some(Err(...))`, and a
kept set never gains a tag no call fails with. Otherwise it makes a set of
its own: `if c then Err(Left(1)) else Err(Right)` is a
`Result<T, ! Left(Int) | Right>`. Its tags are still ones written in
`Err` wherever the `Result` goes, so with `fn mk2(c: Bool)` returning
that, `if c then mk2(c) else attempt g()` is an error if `g` can't fail
with `Right`, as it would be with the `Err`s written in place. A
declared `Result` is different: its type says what it can hold, more
than any call fails with if it likes, so what an `attempt` keeps can be
one, as in `worth_retrying(attempt busy())` for a `fn
worth_retrying(r: Result<Int, ! NotFound(Int) | Busy>)`, and so can one
equal to both a declared `Result` and one made with `Err`. Only a tag
can go inside `Err`, so an error is never a value outside a `Result`. A
name there is always a tag, as in a pattern, even where a type in scope
has a constructor of that name. `try` passes on what such a `Result`
holds as it does any `Result`'s, so `let r = Err(Gone(1))` then `try
r` fails with `Gone(1)`; `fail` is the way to fail with an error written
in place, and `try Err(X)`, written directly, is an error whose help
says `fail X`.

It's shorthand for `match f()` with `v => Ok(v)` and `fail e => Err(e)`, but
that `match` can't be written: a `fail` pattern destructures a payload and
never binds a whole error to a variable, because that would make an error
a free-floating value. `attempt` is the one way an error becomes a value,
so every error you hold is inside a `Result`, a type you already know.

## Failure and `&`

When a call fails, whatever it changed before failing stays changed. This
is the same in Swift and Rust. A failing call doesn't roll its `&`
arguments back, because that would mean keeping a copy of every one, a
hidden allocation in every call that can fail.

For all-or-nothing, change a copy and keep it only if nothing failed:

```ren
pub fn transfer(inout self, t: Transfer) ! TransferError =
  ...
  var draft = self
  try &draft.accounts[i].debit(t.amount, Sent(t.amount, t.to))
  try &draft.accounts[j].credit(t.amount, Received(t.amount, t.from))
  self = draft
```

The copy is visible, and you choose to pay for it. A `with transaction`
handler can do the same for you later, once a handler can sit `over`
another and reach it through `next` (stage 10, [handlers.md](handlers.md)).

## Nothing is dropped

A statement whose value isn't `()` is an error: a returned value can't be
thrown away without a word. Write `let _ = ...` to drop it on purpose.

## `main`

`main` can fail. If it does, the program prints the error and exits with
status 1:

```
error: Frozen(AccountId(3))
```

## Later

- ~~`..e` on a closure that's stored~~ came in stage 7, with dependency
  types: a stored closure writes `fn() ! ..e uses ..d`
  ([deps.md](deps.md)). A closure passed to a transparent parameter
  passes its errors to the call: `try ts.map(fn(t) => try validate(t))`.
- ~~`with` and handlers~~ came in stage 7 too. A handler in front of
  another, `over` it and calling `next`, comes in stage 10
  ([handlers.md](handlers.md)).
