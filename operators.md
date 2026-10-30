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

`zero` and `one` are associated values, `pub let zero: Vec = ...`. On
`Int` and `Float` too: `n.add(2)` is `n + 2`, and panics where it does.

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
- **A variant type's are its sum's, borrowed.** `Order.Placed`, a
  variant with named fields as a type of its own (language.md §2,
  "Variant types"), has no `==`, `hash`, order or `show` of its own:
  `p == q` is `Placed { ..p } == Placed { ..q }`, compared without
  wrapping, through `Order`'s `key` if it has one, and `p` shows as the
  `Order` it is, `Placed { id: 1, ... }`. Deriving them from its fields
  would let the two disagree.
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
pub type Order = { id: OrderId, placed: Time, lines: Array<Line> }
  pub fn key(self) -> OrderId = self.id

assert order == { ..order, placed: later }    // the same order, by id
```

A key projects what makes two values the same. It shouldn't normalize:
a key runs on every `==` and every hash, and the value kept isn't the
value compared. A type whose identity needs normalizing, an email or a
username, normalizes once in its constructor and compares bytes after
([strings.md](strings.md#equality-hashing-and-order)).

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

- `Int`, `Float` (a total order, since comparing a `NaN` panics), `Str` (by bytes, which is code point order) and
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
- **It gives the operators, not the methods:** outside its module,
  `m.add(n)` is an error whose help writes `m + n`. Inside, where the
  type is what it's represented as, `Int`'s methods are there too.
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
- **A `NaN` panics where it's observed** (foundations.md, decision 15).
  An operation that has no answer, `0.0 / 0.0`, `inf - inf`,
  `(-1.0).sqrt()`, makes a `NaN`, and arithmetic and stores carry it:
  every `+`, `-`, `*` and `/` given one gives it back. Comparing one
  (`<` and the others, `==`, `!=`, an order or `==` through a value with
  one in it, even where the comparison is decided before it, as
  `Some(nan) == None` is, `sort`), converting one to an `Int` (`round`, `truncate`)
  or a `Str` (`show`, `print`), hashing one, or passing one to a
  dependency's operation panics. So no program acts on a `NaN`, and none
  reaches a handler, the world or the journal; it can't surface three
  functions later as a wrong answer. A `match` can't see one, since
  there are no `Float` patterns. Infinity stays, since it's ordered and
  means something.
- **The panic says where the `NaN` was made:** `` `<` compared a NaN made
  at stats.ren:3:14 ``, in `ren run` and a debug build, which keep that
  in the `NaN`'s payload; a release build says the rest. The checks are
  at the same points in every build.
- **So `Float` has a total order and `hash`.** `sort()`, `min()`,
  `max()`, `Set<Float>` and float map keys just work, and `-0.0 == 0.0`,
  hashed as one.
- **The check is cheap.** Arithmetic isn't checked at all, only where a
  float is observed; checking every operation was 31% of nbody's
  cycles. Code that used `NaN` for "missing" writes `Option<Float>`.
- **`sum` of `Float`s is a fixed tree:** element i into lane i mod 8,
  each lane from 0.0, then the lanes pairwise, ((0 + 1) + (2 + 3)) +
  ((4 + 5) + (6 + 7)). It's the same on every machine and in every
  build, so a journal replays anywhere, and a vector unit adds it.

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
  = help: if wrapping is what you mean, write `n +% 1`
```

## Sized integers

`Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`, `UInt32`, `UInt64` and
`Float32` are types of places: fields, array elements and variables
that keep a number in fewer bits (foundations.md, decision 15). Nothing
is computed in them. Arithmetic is `Int`'s and `Float`'s, so there's one
set of rules for overflow, and no conversions to write:

```ren
type Pixel = { r: UInt8, g: UInt8, b: UInt8, a: UInt8 }

fn fnv(bytes: Array<UInt8>) -> Int =
  var h: UInt32 = 2166136261
  for b in bytes
    h = h.xor(b) *% 16777619
  h
```

- **Reading one gives an `Int`,** a `Float32` a `Float`, the same number.
  `p.r + 1000` is `1255` when `p.r` is `255`, and `bytes[i] * 2` is an
  `Int`. A sized type is never where an expression's type is used: `x ==
  y`, `show(x)` and a generic function's argument all see the `Int`.
- **Storing one checks that it fits,** and panics if it doesn't, as an
  overflow does: `xs[i] = 300` into an `Array<UInt8>` panics with `300
  doesn't fit in a `UInt8`, which holds 0 to 255`. A literal that
  doesn't fit is an error where it's written. Storing is any place an
  `Int` becomes one: a field, an element, a `push`, a `let` or `var`
  with the type written, an argument, a function's result.
- **A `Float32` rounds** to the nearest one when stored, as C's
  `(float)x` does; a finite `Float` too big for one, past about
  3.4e38, panics, since it would become an infinity.
- **A `UInt64` holds 0 to 9223372036854775807,** what an `Int` holds that
  isn't negative, so reading one always gives the same number back. Of
  the three choices for the values above that, this is the one with no
  surprise: reading them as negative `Int`s would make `<` disagree with
  the stored order, and panicking on a read would make every read a
  check. It's for counts, sizes and ids kept in a format that says
  unsigned; a 64-bit hash stays an `Int`, and wraps there.
- **An `inout` place has to be the parameter's type exactly:**
  `bump(&b)` with `b: UInt8` and `bump(inout n: Int)` is an error, since
  the place keeps 8 bits.
- **`len()` and indexes stay `Int`,** so there's no Rust-style
  `as usize`.

### The wrapping operators

`+%`, `-%` and `*%` are `Int`'s `wrapping_add`, `wrapping_sub` and
`wrapping_mul`: they wrap at 64 bits instead of panicking, for hashes,
checksums and random number generators. They bind as `+`, `-` and `*`
do, and `h *%= k` is `h = h *% k`. `Float` has none: it doesn't wrap.

**Stored into a sized integer, a wrapping operator's result wraps at
that type's width** instead of being checked: `h = h *% 16777619` with
`h: UInt32` keeps the low 32 bits. That's the whole rule, and it gives
exactly what wrapping at the narrow width would, since 2^32 divides
2^64: the low 32 bits of a product don't depend on the bits above
them. It applies to the operator at the top of what's stored, `a *% b`,
`a +% b * c`'s `+%`, or a `wrapping_*` method's call, and nothing
else: `h = h.xor(b)` is checked as any store is. Where the result isn't
stored into a sized integer, it wraps at 64 bits: `let x = h *% k` is
an `Int`, wrapped at 64, even when `h` is a `UInt32`. Storing a wrapping
result into a `UInt64` is an error, since half of what wrapping at 64
bits makes is negative; keep a 64-bit hash in an `Int`:

```ren
fn fnv64(bytes: Array<UInt8>) -> Int =
  var h = 1469598103934665603
  for b in bytes
    h = h.xor(b) *% 1099511628211
  h
```

### Bits

`Int`'s `xor`, `bit_and` and `bit_or`, its shifts `shl` and `shr`, and
numbers written in hex and binary are what such code needs besides
(foundations.md, decision 15). A CRC-32C:

```ren
fn table() -> Array<UInt32> =
  var t: Array<UInt32> = []
  for n in 0..256
    var c = n
    for _ in 0..8
      c = if c.bit_and(1) == 1 then c.shr(1).xor(0x82F6_3B78) else c.shr(1)
    &t.push(c)
  t

fn crc32c(t: Array<UInt32>, data: Array<Int>) -> Int =
  var c: UInt32 = 0xFFFF_FFFF
  for x in data
    c = t[c.xor(x).bit_and(0xFF)].xor(c.shr(8))
  c.xor(0xFFFF_FFFF)
```

- **A number can be written in hex or binary,** `0x82F6_3B78`, `0b1010`,
  with the prefix in lower case and its digits in either, and any number
  with underscores after its first digit, `1_000_000`. It's an `Int`,
  never a `Float`, and **a number, not a pattern of bits:** it has to
  fit an `Int` as a decimal one does, so `0xFFFF_FFFF_FFFF_FFFF` is an
  error whose help says the largest is `0x7FFF_FFFF_FFFF_FFFF`, and all
  64 bits set is `-1`. Stored into a sized type, it's checked as any
  literal is.
- **`x.shl(k)` loses the bits shifted out:** it's the low 64 bits of `x`
  times 2^k, so it never overflows, `1.shl(63)` is the smallest `Int`.
  It's a wrapping operation, by the rule above: stored into a sized
  integer it keeps that type's width, `w = w.shl(1)` with `w: UInt32`
  keeps 32 bits, and stored into a `UInt64` it's an error.
- **`x.shr(k)` is `x` divided by 2^k, rounded down:** arithmetic, so a
  negative number keeps its sign, `(-8).shr(1)` is `-4`. It's logical on
  an unsigned type with nothing more, since a value read from one is
  never negative. It can't overflow, and storing it is checked as any
  store is.
- **A shift is by 0 to 63:** any other amount panics, `` `shl` by 64: a
  shift is by 0 to 63 ``, in every build at the call; a literal one is
  an error where it's written. A native build checks with one unsigned
  compare, gone when the amount is a constant.

### How they're kept

The interpreter checks and wraps as above (sized.ml). A native build
keeps an `Array<UInt8>` as bytes, an `Array<Int32>` as 4-byte elements
and so on, and packs a record's sized fields into shared words, as it
packs `Bool`s (compiler.md, "Sized storage").

## The pipe, `|>`

`x |> f(a)` is `f(x, a)`, and `x |> f` is `f(x)`, checked exactly as that
call (language.md §8). It isn't a method: `.` reaches a type's own
vocabulary, and `|>` a step from elsewhere, a function by name, `f`,
`module.f` or `Type.f`, so a workflow reads in the order it happens:

```ren
cart
  |> try validate                          // can reject
  |> order.price(Discounts.for_customer(c))
  |> try place                             // can fail: DbDown
```

- **The value goes first,** matching `self`-first methods. One that
  belongs in another position gets a `let`.
- **Each link is one term,** so there's no precedence to learn: `total +
  fee |> round` asks for parentheses, and so does an operator after a
  chain. `orelse` may follow one, and applies to its result.
- **Values only:** no `&` before the value or a step, and no block as a
  step; a step that's a method of the value's own type is called with
  `.`. Only the last step may take a trailing block.
- **`|>` ends the reach of `try` and `attempt`**, so each step that can
  fail carries its own `try` (errors.md).
- **A line starting with `|>`, or with `.` and a name, indented further
  than its block, continues the line above**, so a chain puts a step on
  each line.

It runs as the call it is, in `ren run` and natively: `let s = x in f(s,
a)`. examples/checkout is language.md's end-to-end program, its checkout a
chain.

## Ranges

`a..b` is the `Int`s from `a` up to, but not including, `b`. There's one
kind: half-open, so `0..xs.len()` is every index, and two ranges that
meet, `0..n` and `n..m`, don't overlap. A range is a `for`'s, and an
index's, which slices (below), not a value: it can't be kept in a `let`
or passed, and it has no methods.

```ren
// the elements after each one, paired with it
for i in 0..xs.len() - 1
  &pairs.push((xs[i], xs[i + 1]))
```

There's no inclusive `..=` (Rust) or `...` (Ruby, where `..` is the
inclusive one): one spelling, and nobody has to remember which it is.

## Conditions are `Bool`

`if`, `&&`, `||` and `not` take a `Bool`, and nothing else. An
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

### Slices

`xs[a..b]`, on an `Array<T>`, a `Str` or `Bytes`, is its elements, or
bytes, from `a` up to, but not including, `b`, a value of the same type
(foundations.md, decision 17): there's no `Slice` type. It panics, in
every build at the same point, if `b` comes before `a` (`slice 3 to 1
ends before it starts`), if the range isn't all in `xs` (`slice 2 to 5
is out of bounds for an array of length 3`), or, on a `Str`, if it cuts
a character (`slice 2 to 3 starts inside a character` on `"héllo"`); `Bytes` never
checks. `Str.slice(a, b)` is gone: `s[a..b]`.

```ren
let mid = xs[2..6]
let name = line[0..colon].trim()
```

A slice is a value like any other: compared, shown, stored and returned
as its type is, and nothing tells it from a copy but its cost. A native
build shares the buffer it was cut from, so making one copies nothing,
and keeps all of that buffer alive while it lives: `xs.copy()`, on each
of the three, gives one a buffer of its own, and costs nothing on a
value that already has one. `split` and `trim` return slices of the
string they're given.

A range is a place too. `f(&xs[a..b])` passes it with `&`: a write of
`xs` for the call, as `&xs[i]` is, and what `f` leaves there replaces
the range, so a range that grew moves what follows. `for x in
&xs[a..b]` changes that range. Two ranges of one array in one call may
overlap, as two indexes may, so `f(&xs[0..2], &xs[2..4])` is an error,
whose help is `split_at`, which gives a block both halves as places of
its own:

```ren
&xs.split_at(n) fn(&lo, &hi) =>
  sort(&lo)
  sort(&hi)
```

When the block returns, or fails, `xs` is `lo` followed by `hi`. A
native build changes the halves in place when nothing else holds `xs`.
`xs[a..b] = ys` is an error: a range is changed through `&`.

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
| `any(f)`, `all(f)`, `count(f)` | whether any, whether all, how many; `count()` with no `f` counts them all, on every receiver, a cursor included |
| `includes(x)` | whether `x` is in it |
| `reduce(init, f)` | `f` over each element, from `init` |
| `sum()`, `min()`, `max()` | needing `add` and `zero`, or an order; `min` and `max` give an `Option` |
| `min_by(f)`, `max_by(f)` | by `f`, `Option<T>` |
| `sort()`, `sort_by(f)` | by the elements' order; or once by `f` |
| `group_by(f)` | a `Map` from each `f(x)` to the elements that gave it |
| `partition(f)` | `(the ones f is true of, the rest)` |
| `tally()` | a `Map` from each element to how many times it's there |
| `uniq()` | without repeats, first ones kept |
| `zip(ys)`, `with_index()` | a cursor of `(x, y)` pairs, as long as the shorter, whose `zip(zs)` gives triples; an array of `(i, x)` |
| `first()`, `last()` | `Option<T>` |
| `take(n)`, `drop(n)`, `reverse()` | |

A `Map` has `get`, `set`, `remove`, `includes(k)`, `keys()`, `values()`
and `len()`, and the methods above over its `(k, v)` pairs, in order:
those that keep some of its pairs, `select`, `reject`, `partition`,
`take`, `drop` and `reverse`, give a `Map`, and the rest an array or a
value. A `Set` has `add`, `remove`, `includes(x)` and `len()`, and the
methods above over its members, the same way, giving a `Set` where a
`Map` gives a `Map`. Neither has `index`, `uniq` or `tally`, which mean
nothing without repeats or places, and a `Map` has no `sum`. A lambda's
parameter can't be a tuple pattern yet, so a function given a `Map`'s
pairs takes one apart inside: `m.select(fn(p) => let (k, v) = p ...)`.

`len`, `push` and `sort` are built into the compiler, as `Map`'s and
`Set`'s hashing is; the rest are written in Ren, in the prelude, under
`pub type Array<T> = builtin`, a declaration only the prelude can write,
which adds members to a built-in type.

- Names that end in `?` in Ruby lose it: `any`, `includes`.
- `Str.find(s)`, from stage 8, is renamed `Str.index(s)`, as `Array.index`
  is: in both, `index` finds where something is, and `find` takes a
  function.
- There's one name for each: no `filter` beside `select`, no `inject`
  beside `reduce`, no `length` or `size` beside `len`. `Str` has
  `byte_len` instead of `len`, not beside it: on `Str`, a name whose
  unit is ambiguous doesn't compile ([strings.md](strings.md#length-and-indexing)).

## How it runs

- **What a function needs of a type parameter is a hidden parameter,** as
  a dependency is: one copy of `sum`, given `Int`'s `add` and `zero`
  where it's called. A `hash` dictionary carries the `==` it agrees
  with, so a `Map` is given both of its keys' as one. The C backend can make a copy for each type later,
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
- A `NaN` panics where it's observed, so `Float` is ordered and hashed.
- Ranges, `a..b`, half-open only.
- Conditions are `Bool`, stated as a rule.
- `Array` and `Map` use `Enumerable`'s names, and `Str.find` becomes
  `Str.index`.

## Done when

**9a:** `Money` in the bank is `opaque Int with numeric`, and `Time`,
`Instant` and `Duration` use operators, so `plus`, `covers`, `before` and
`not_before` are gone. `Email` is equal by its lowercase. `==` on a
function is an error, `0.0 / 0.0` panics where it's shown, `Int` overflow panics at
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
  Instant`; overflow as a bug. **Zig and Swift:** `+%` and `&+`, the
  wrapping operators. **Lean:** a `ByteArray` and a `FloatArray` kept
  unboxed, for `Array<UInt8>`. **C and Java:** a narrow integer is
  widened before arithmetic, here to 64 bits, with no conversions.
- **Swift:** overflow panics in every build.
- **Rust's `ordered_float::NotNan`:** floats with no `NaN` observed, as a
  library type. Ren makes it the only `Float`, checked where a `NaN`
  would be observed rather than where it's made.
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
  a language number type beside `Int` and `Float` when it arrives
  (stage 12). Sized
  integers need none: a literal is an `Int`, checked where it's stored
  into one. There are no user-defined suffixes. Mixing needs no context: `price * 0.08` with a `Decimal`
  price is an error whose help says `0.08d`.
- **Shapes and build time,** for `json` and SQL rows, in
  [shapes.md](shapes.md) rather than `comptime`.
- **Narrow lanes:** a loop over sized elements computed at their width
  where the compiler proves the values fit (foundations.md, decision 15).
- **`Decimal`,** a language number type, its operations described in
  [stdlib.md](stdlib.md).
- **A sorted map,** in std, on a type's order.
- **Slices,** `xs[1..3]`, as values that share their root's buffer
  (foundations.md, decision 17).
- **`ren fmt`,** one format with no options, as `gofmt`, by the C
  backend.
- **`ren api diff`,** to flag a public function whose requirements grew.
