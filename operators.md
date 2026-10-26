# Operators, equality and maps

How a type gets `+` and `<`, what `==` means, and how values become map
keys. It's the roadmap's next stage, operators, derived equality and
hashing, which comes before handlers that wrap and `Async`. The short version is in the README's
[Methods, operators, and equality](README.md#methods-operators-and-equality).

The aim is pragmatic simplicity: one way to do each thing, nothing that
surprises a reader, and nothing that makes the compiler search. Every type
gets equality, hashing, `show` and, where it's obvious, ordering, without
asking. It changes them in one way, `key`. It gets arithmetic in one way,
`with numeric`, or by writing the operator.

It's built in two halves:

- **9a:** operators as methods, `key`, derived `==`, `hash`, ordering and
  `show`, `with numeric`, and the rules for `Int` and `Float`.
- **9b:** tuples, ranges, `Map` and `Set`, and the collection methods,
  which need 9a's `hash` and ordering.

## What it has to do

1. **Nothing is found behind your back.** An operator is found on its left
   side's type, and nowhere else: no instances, no imports that change
   what `+` means, no orphans.
2. **One way.** `key` is the only way to change what equal means, and
   with it ordering and hashing, so the three never disagree. Operators
   are methods. There's one `show`.
3. **No surprises at runtime.** Comparing two functions is a compile
   error, not a panic. Numbers never convert by themselves. Overflow
   panics in every build.
4. **Fast to check.** Every literal has one type and every operator is
   found by its two sides' types, so nothing is inferred by trying
   candidates.

## Operators are methods

An operator is a method with a reserved name. `a + b` is `a.add(b)`:

| Operator | Method |
|---|---|
| `a + b`, `a - b`, `a * b`, `a / b`, `a % b` | `add`, `sub`, `mul`, `div`, `rem` |
| `-a` | `neg` |
| `a == b`, `a != b` | derived, through `key` |
| `a < b`, `a <= b`, `a > b`, `a >= b` | derived, through `key` |

`zero` and `one` are associated values, `pub let zero: Vec = ...`.

```ren
pub type Vec = { x: Int, y: Int }
  pub fn add(self, b: Vec) -> Vec = Vec { x: self.x + b.x, y: self.y + b.y }
  pub fn mul(self, k: Int) -> Vec = Vec { x: self.x * k, y: self.y * k }
  pub let zero: Vec = Vec { x: 0, y: 0 }
```

- **There are no new operator symbols.** The set above is all of them.
- **An operator method can be written once for each type on its right.**
  It's the one place a name is defined more than once, and it's chosen by
  the right side's type, which is always known:

```ren
pub type Time = opaque Int
  pub fn add(self, d: Duration) -> Time = self + d.in_ms()
  pub fn sub(self, t: Time) -> Duration = Duration.ms(self - t)
  pub fn sub(self, d: Duration) -> Time = self - d.in_ms()

let deadline = Clock.now() + Duration.seconds(30)
let waited = Clock.now() - started            // a Duration
```

- **It's found on the left side's type only:**

```
error: `Duration` has no `+` that takes a `Time`
  ┌─ jobs.ren:8:11
  │
8 │   let t = Duration.seconds(5) + now
  │           ^^^^^^^^^^^^^^^^^^^^^^^^^
  │
  = `+` is found on its left side's type, `Duration`
  = help: write it the other way round: `now + Duration.seconds(5)`
```

## Equality, hashing and `show`

`==`, `hash` and `show` are derived for every type, by its structure:

- **A type with a function in it has `==` and `hash` only through its
  `key`.** A function can't be compared, and that's known from the type,
  so comparing one is a compile error, never a runtime panic. A record
  that carries behaviour, a subscriber with a `notify`, says what makes
  two the same with a key, and the error says so. An implementation of a
  dependency, and a handler, is only its operations, so it has none.
- **An opaque type is equal by its representation,** unless it has a
  `key`. That's right for `Money` and `UserId`. A type whose
  representation isn't unique, so that two equal values can be stored
  differently, writes a `key`.
- **One `show`,** used by `print`, interpolation and test output. A type
  can write its own, `pub fn show(self) -> Str`, as `Path` does. A `Str`
  shows as itself at the top, `hello`, and quoted inside something,
  `["hello"]`.
- **The three are one walk over a type,** run over the type descriptors
  stage 10.0 already passes at run time for `show`. A type's shape,
  `T.shape` ([shapes.md](shapes.md)), exposes the same descriptor later,
  rather than a second mechanism.

### `key`

`key` is the one way to change what equal means. Equality, hashing and
ordering all go through it:

```ren
pub type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  pub fn key(self) -> Str = self.lower()

assert Email.of("Ann@Example.com") == Email.of("ann@example.com")
```

There's no writing `eq`, `hash` or `compare` by hand, so they can't
disagree, as Java's `equals` and `hashCode` can.

A key decides `==`, `hash` and order in every module, whether it's `pub`
or not. `pub` only says whether other modules can call `.key()`. So an
opaque type can be ordered without giving its representation away, as
`Instant` is:

```ren
pub type Instant = opaque Int
  fn key(self) -> Int = self    // orders instants; nobody else can read it
```

```
error: `Sub` has no `==`
  ┌─ main.ren:5:9
  │
5 │   print(a == a)
  │         ^^^^^^
  │
  = a type with a function in it has `==` and `hash` only through its `key`
  = the field `notify` of `Sub` has a function in it
  = help: give `Sub` a key, which says what makes two the same: `fn key(self) -> K = ...`
```

### Ordering

`<` and the others come from a type's order, which is derived only where
it's obvious:

- `Int`, `Float` (a total order, since there's no `NaN`), `Str` (by bytes, which is code point order) and
  `Bool`;
- a sum type with no fields, by the order of its variants;
- tuples, element by element;
- anything with a `key`, by its key.

A record, or a sum type with fields, has an order only through its `key`,
so that reordering its fields can't change how a list of it sorts:

```ren
pub type Name = { last: Str, first: Str }
  pub fn key(self) -> (Str, Str) = (self.last, self.first)
```

```
error: `User` can't be sorted: it has no order
  ┌─ users.ren:14:29
   │
14 │   let s = users.values().sort()
   │                          ^^^^^^
   │
   = a record is ordered only by its `key`, so that reordering its fields can't change a sort
   = help: give `User` a key: `fn key(self) -> Time = self.joined`, or sort by one: `.sort_by(fn(u) => u.joined)`
```

`sort_by` sorts once by something else. It isn't a second way to order a
type: `key` says what a type's order is, and `sort_by` asks for another
one, once.

## Number types

`with numeric` gives an opaque number type its arithmetic:

```ren
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n * 100
  pub fn cents(self) -> Int = self

let total = price * 3 + shipping - discount
if total > budget then fail OverBudget(total - budget)
```

- It gives `+`, `-`, negation, `zero`, comparison, and `*` by a plain
  `Int` (or `Float`, for `opaque Float with numeric`).
- **Not `*` of two of them,** which would make `Meters * Meters` a
  `Meters`. Anything else is written by hand, `pub fn mul(self, b: Meters)
  -> Area`.
- **Not `/`.** A division says how it rounds, so it's a method, as
  `Decimal`'s is ([stdlib.md](stdlib.md)).
- **Literals don't convert.** `Money.dollars(5)` and `Money.zero`, never
  `5`: opaque means opaque.

```
error: `Money` has no `*` that takes a `Money`
  ┌─ shop.ren:12:12
   │
12 │   let sq = price * price
   │            ^^^^^^^^^^^^^
   │
   = `with numeric` gives `Money` `*` only by an `Int`, so `Money * Money` isn't a `Money`
   = help: if it's a product, write it on `Money`: `pub fn mul(self, b: Money) -> Area = ...`
```

## Generic code

A function that uses `==`, `<`, `+` or `zero` on a type parameter needs
it, and the compiler works out which. It's never written, on a public
function either:

```ren
pub fn sum<T>(xs: Array<T>) -> T =
  var acc = T.zero
  for x in xs
    acc = acc + x
  acc
```

`ren types` and an editor's hover show it as `sum<T has add, zero>`. A
call with a type that doesn't have it is an error where it's made:

```
error: `Bool` has no `+`, which `sum` needs
  ┌─ main.ren:3:9
  │
3 │   print(sum([true, false]))
  │             ^^^^^^^^^^^^^
  │
  = `sum` adds its elements together (util.ren:4)
```

```
error: `fn(Int) -> Int` has no `==`, which `same` needs
  ┌─ main.ren:5:8
  │
5 │   same(inc, inc)
  │        ^^^
  │
  = a type with a function in it has no `==` or `hash`
```

- **Why public functions don't write it,** when they write `uses` and
  `!`: those say what code does, which is what Ren promises a reader. A
  requirement says only which types can be passed, the compiler checks it
  at every call, and getting it wrong can't do anything at runtime. It's
  the one thing a public signature leaves out.
- **What that costs:** a change to a public function's body can add a
  requirement and break a caller. It changes the module's interface, so
  the build rebuilds whatever imports it, and the error shows there.
- **And what it costs the build:** a module's interface is known only
  once its bodies are checked, so a module that imports it waits for
  that, not just for its signatures. TypeScript went the other way with
  `isolatedDeclarations`, so interfaces can be made without checking
  anything. Ren chooses writing less: requirements on type parameters
  are rare in application code, and modules still check in parallel
  wherever the import graph lets them. It's the one place this design
  gives up build speed.
- `T.zero` reaches a member through a type parameter, which works for
  whatever the function needs of `T`.
- **In generic code, an operator is the one of the same type on both
  sides:** `a + b` with `a: T` needs `add(T, T) -> T`, so a requirement is
  just a name, `has add`. An operator with another type on its right,
  `Time + Duration`, is found only where the types are known. Like
  everything else, the left side's type is known first: types flow left
  to right ([deps.md](deps.md)).

## `Int` and `Float`

- **`Int` is 64 bits,** in the interpreter too, so overflow panics at the
  same point in every build and on every backend. It panics in every
  build, as an out-of-bounds index does. Wrapping is a method,
  `a.wrapping_add(b)`.
- **`/` and `%` round toward zero,** as in C, Go and Rust: `-7 / 2` is
  `-3`. Dividing by zero panics.
- **`Float` is a 64-bit IEEE double.** `1.5` is a `Float` and `1` is an
  `Int`, always: a literal's type is read from its spelling, never from
  where it's used. A `Float` times two is `x * 2.0`, and `x * 2` is an
  error whose help says so.
- **Numbers never convert by themselves:** `Float.of(n)`, `f.round()`,
  `f.truncate()`.
- **There's no `NaN`.** An operation that would make one, `0.0 / 0.0`,
  `inf - inf`, `(-1.0).sqrt()`, panics, as an `Int` overflow does. A
  `NaN` doesn't stop anything: it spreads through what comes after and
  surfaces three functions later as a wrong answer, which is a failure
  nobody sees. Infinity stays, since it's ordered and means something.
- **So `Float` has a total order and `hash`.** `sort()`, `min()`,
  `max()`, `Set<Float>` and float map keys just work, and `-0.0 == 0.0`,
  hashed as one.
- **The check is cheap.** `NaN` is sticky: once made, every `+`, `-`, `*`
  and `/` after it gives `NaN`. So a float is checked only where it
  leaves arithmetic, when it's stored, compared, passed, returned or
  converted, never inside an expression. A float from C is checked where
  it comes in. Code that used `NaN` for "missing" writes
  `Option<Float>`.

```
error: `Int` has no `/` that takes a `Float`
  ┌─ stats.ren:4:14
  │
4 │   let mean = total / 2.0
  │              ^^^^^^^^^^^
  │
  = numbers never convert by themselves
  = help: convert one: `Float.of(total) / 2.0`
```

```
panic: `+` overflowed: 9223372036854775807 + 1
  ┌─ count.ren:7:5
  │
7 │     n + 1
  │     ^^^^^
  │
  = help: if wrapping is what you mean, write `n.wrapping_add(1)`
```

## Ranges

`a..b` is the `Int`s from `a` up to, but not including, `b`. There's one
kind: half-open, so `0..xs.len()` is every index, and two ranges that
meet, `0..n` and `n..m`, don't overlap.

```ren
// the elements after each one, paired with it
for i in 0..xs.len() - 1
  &pairs.push((xs[i], xs[i + 1]))
```

There's no inclusive `..=` (Rust) or `...` (Ruby, where `..` is the
inclusive one): one spelling, and nobody has to remember which it is.

## Conditions are `Bool`

`if`, `while`, `&&`, `||` and `not` take a `Bool`, and nothing else. An
empty array, `0`, `""` and `None` aren't false: `if xs.len() > 0`, not
`if xs`. This was already so. It's written down because every one of
Python, Ruby and JavaScript chose otherwise.

## Tuples

`(a, b)` and `(a, b, c)`: two or three values passed together, taken apart
only by patterns:

```ren
let (k, v) = pair
for (email, u) in users
  print(email)
match Map.of([(1, "a")]).first()
  Some((k, v)) => print(v)
  None => ()
```

There's no `.0` or `.1`. A record names its parts. A tuple is for two or
three things that don't need names, and one that wants them by position
wants a record.

## `Map` and `Set`

```ren
var users: Map<Email, User> = Map.empty
&users.set(u.email, u)
let u = users.get(Email.of("ann@example.com")) orelse fail NoSuchUser
for (email, u) in users
  print(u.name)
let seen = Set.of(["a", "b"])
```

- **A key needs `hash`,** so it's any type without a function in it.
- **They keep insertion order.** Iterating gives what was set first,
  first, so a program's output never depends on a hash seed, and
  simulation replays exactly without maps needing `uses Random`. The seed,
  against keys chosen to collide, is the runtime's own.
- **`m.get(k) -> Option<V>` is the one way to look up,** since a key
  that isn't there is ordinary. There's no `m[k]`.
- **No literal syntax:** `Map.of([(k, v)])`, which leaves `{ }` to
  records.

### Indexing an array

`xs[i]` still panics past the end, and `xs.get(i) -> Option<T>` is for an
index that may not be there. They say different things: `[i]` says it's
there, `get` asks. An index past the end is almost always a bug, and a
default hides it. `xs[i]` is also a place, `xs[i] = v` and
`&xs[i].credit(m)`, which an `Option` can't be.

## The collection methods

`Array` and `Map` take their method names from Ruby's `Enumerable`, the
best-named collection vocabulary there is, so that std doesn't grow
whatever names its first users needed. A method that changes nothing
returns a new collection: `xs.sort()`, not a sorting `&xs`. Once memory
is reused in place (stage 14), sorting an array nothing else holds
doesn't copy it, so there's no second, changing version as Ruby's `sort!`
is.

| Method | What it gives |
|---|---|
| `map(f)`, `flat_map(f)` | each element through `f`; and flattened |
| `select(f)`, `reject(f)` | the elements `f` is true of; and false of |
| `find(f)` | the first element `f` is true of, `Option<T>` |
| `index(x)` | where `x` first is, `Option<Int>` |
| `any(f)`, `all(f)`, `count(f)` | whether any, whether all, how many |
| `includes(x)` | whether `x` is in it |
| `reduce(init, f)` | `f` over each element, from `init` |
| `sum()`, `min()`, `max()` | needing `add` and `zero`, or an order; `min` and `max` give an `Option` |
| `min_by(f)`, `max_by(f)` | by `f`, `Option<T>` |
| `sort()`, `sort_by(f)` | by the elements' order; or once by `f` |
| `group_by(f)` | a `Map` from each `f(x)` to the elements that gave it |
| `partition(f)` | `(the ones f is true of, the rest)` |
| `tally()` | a `Map` from each element to how many times it's there |
| `uniq()` | without repeats, first ones kept |
| `zip(ys)`, `with_index()` | pairs of `(x, y)`; and of `(i, x)` |
| `first()`, `last()` | `Option<T>` |
| `take(n)`, `drop(n)`, `reverse()` | |

A `Map` has `get`, `set`, `remove`, `includes(k)`, `keys()`, `values()`
and `len()`, and the methods above over its `(k, v)` pairs.

- Names that end in `?` in Ruby lose it: `any`, `includes`.
- `Str.find(s)`, from stage 8, is renamed `Str.index(s)`, as `Array.index`
  is: in both, `index` finds where something is, and `find` takes a
  function.
- There's one name for each: no `filter` beside `select`, no `inject`
  beside `reduce`, no `length` or `size` beside `len`.

## How it runs

- **What a function needs of a type parameter is a hidden parameter,** as
  a dependency is: one copy of `sum`, given `Int`'s `add` and `zero`
  where it's called. The C backend can make a copy for each type later,
  as an optimisation that changes nothing.
- **Derived operations are made when they're used,** one structural walk
  over a type, with `key` where a type has one.
- **That walk stays inside the compiler.** `json.decode<T>` and SQL rows
  don't use it: they read a type's shape, `T.shape`, as ordinary Ren
  ([shapes.md](shapes.md)).

## What the README changes

- Operators are methods with reserved names, not `name(a, b) => ...`
  members.
- Ordering isn't derived for every type: a record, or a sum type with
  fields, is ordered by its `key`.
- `opaque Int with numeric` is the spelling.
- Public signatures spell out everything but what they need of a type
  parameter.
- `where T has add` goes: it's inferred.
- Map iteration order is insertion order, not seeded, and the hash seed
  is the runtime's own, which nothing can observe.
- There's no `NaN`, so `Float` is ordered and hashed.
- Ranges, `a..b`, half-open only.
- Conditions are `Bool`, stated as a rule.
- `Array` and `Map` use `Enumerable`'s names, and `Str.find` becomes
  `Str.index`.

## Done when

**9a:** `Money` in the bank is `opaque Int with numeric`, and `Time`,
`Instant` and `Duration` use operators, so `plus`, `covers`, `before` and
`not_before` are gone. `Email` is equal by its lowercase. `==` on a
function is an error, `0.0 / 0.0` panics, `Int` overflow panics at
2^63, and a generic `sum` runs on `Int`, `Float` and `Money`.

**9b:** `Map<Email, User>` works, with `Email` an opaque `Str` keyed by its
lowercase. The bank uses `Money` with `with numeric` and keeps its
accounts in a `Map`; the prices cache is a `Map`; `Time`, `Instant` and
`Duration` use operators; and the examples' workarounds (`plus`, `covers`,
`before`, `not_before`, the hand-written `find`) are gone.

## Borrowed from

- **Ruby and Kotlin:** operators as methods. **Ruby:** `Enumerable`'s
  names, and insertion order.
- **Rust:** an operator chosen by its right side's type, `Instant -
  Instant`; overflow as a bug.
- **Swift:** overflow panics in every build.
- **Rust's `ordered_float::NotNan`:** floats with no `NaN`, as a library
  type. Ren makes it the only `Float`.
- **Roc:** every type has `==` except one with a function in it.
- **Go:** a struct is a map key when its fields can be; numbers convert
  only when asked; `5 * time.Second`.
- **Python:** `sorted(key=...)` and `@dataclass(order=True)`, ordering by
  a key and only when asked; insertion-ordered dicts.

And not: trait search and orphan rules (Haskell, Rust), Rust's
`PartialEq` beside `Eq`, `Debug` beside `Display`, `as` casts, and
derive lists; Ruby's open classes and three equalities; Python's
truthiness and `__radd__`; JavaScript's `==` beside `===`, maps keyed by
identity, and `sort` by strings; Go's random map order, untyped
constants and zero values; Haskell's literals of every number type.

## Deferred

Named here so they aren't forgotten:

- **Lazy iterators.** The collection methods make a new collection each
  time until they arrive.
- **Interpolation and `Shell`,** with the rest of strings, in stage 12,
  where `sql"..."` hands its parts to a library. Interpolation uses
  `show`.
- **Literal suffixes.** A literal's type stays read from its spelling,
  and a closed set of suffixes says the rest: `0.08d` for `Decimal`,
  which moves into the prelude when it arrives (stage 12), and `255u8`
  to `i64` with sized integers (stage 13). There are no user-defined
  suffixes. Mixing needs no context: `price * 0.08` with a `Decimal`
  price is an error whose help says `0.08d`.
- **Shapes and build time,** for `json` and SQL rows, in
  [shapes.md](shapes.md) rather than `comptime`.
- **Sized integers,** `u8` to `i64`, with the C backend. `len()` and
  indexes stay `Int`, so there's no Rust-style `as usize`.
- **`Decimal`,** in std ([stdlib.md](stdlib.md)).
- **A sorted map,** in std, on a type's order.
- **Slices,** `xs[1..3]`, once there's a view that doesn't copy.
- **`ren fmt`,** one format with no options, as `gofmt`, by the C
  backend.
- **`ren api diff`,** to flag a public function whose requirements grew.
