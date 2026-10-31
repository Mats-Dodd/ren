(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet. Each such
   function is named by an id (intrinsic.ml), and below are its type and
   where it's listed: everything the passes before the interpreter need
   to know about it. What it does when it runs is the interpreter's half,
   eval/builtins.ml. So adding a built-in means adding its id, an entry
   here, and its implementation there, and the compiler points out any
   [match] that's missing it. *)

(* The file its source is said to be in, which no message can show. *)
let file = "<prelude>"

let source =
  {|
pub type Option<T> =
  | Some(value: T)
  | None

  pub fn is_some(self) -> Bool =
    match self
      Some(_) => true
      None => false
  pub fn unwrap_or(self, d: T) -> T =
    match self
      Some(x) => x
      None => d

pub type Result<T, E> =
  | Ok(value: T)
  | Err(error: E)

// ---- collections (operators.md, "The collection methods") ----
//
// `len`, `push` and `sort` are built into the compiler, as `Map`'s and
// `Set`'s finding by hash is; the rest are written here. A method that
// changes nothing gives a new collection. One that takes a function only
// calls it, so whatever it can fail with and uses, the call can too, and
// one that stops early, `find`, `any` and `all`, calls it no more once it
// knows.

pub type Array<T> = builtin
  // the element at `i`, if there is one: `xs[i]` says it's there, and
  // panics if it isn't; `get` asks
  pub fn get(self, i: Int) -> Option<T> =
    if i >= 0 && i < self.len() then Some(self[i]) else None
  pub fn first(self) -> Option<T> = self.get(0)
  pub fn last(self) -> Option<T> = self.get(self.len() - 1)
  // each element through `f`. If nothing else holds this array and a
  // `U` is kept as a `T` is, each element is replaced where it is, and
  // the array is the new one (Lean's `Array.mapMUnsafe`); otherwise the
  // new array is made with room for them all at once
  pub fn map<U>(self, f: fn(T) -> U) -> Array<U> =
    let into: MapInto<U> = map_into(self)
    match into
      InPlace =>
        var out = self
        for i in 0..out.len()
          out[i] = unsafe_cast(try f(out[i]))
        unsafe_cast(out)
      Fresh => try self.map_fresh(f)
  // `map` into a new array, made with room for every element at once
  fn map_fresh<U>(self, f: fn(T) -> U) -> Array<U> =
    var out: Array<U> = array_reserve(self.len())
    for x in self
      &out.push(try f(x))
    out
  // each element through `f`, which gives an array, all of them joined
  pub fn flat_map<U>(self, f: fn(T) -> Array<U>) -> Array<U> =
    var out: Array<U> = []
    for x in self
      for y in try f(x)
        &out.push(y)
    out
  // the elements `f` is true of
  pub fn select(self, f: fn(T) -> Bool) -> Array<T> =
    var out: Array<T> = []
    for x in self
      if try f(x) then &out.push(x)
    out
  // the elements `f` is false of
  pub fn reject(self, f: fn(T) -> Bool) -> Array<T> =
    var out: Array<T> = []
    for x in self
      if not (try f(x)) then &out.push(x)
    out
  // the first element `f` is true of
  pub fn find(self, f: fn(T) -> Bool) -> Option<T> =
    var found = None
    for x in self
      if not found.is_some() then
        if try f(x) then found = Some(x)
    found
  // where `x` first is
  pub fn index(self, x: T) -> Option<Int> =
    var found = None
    var i = 0
    for y in self
      if not found.is_some() && y == x then found = Some(i)
      i += 1
    found
  // whether `f` is true of any element
  pub fn any(self, f: fn(T) -> Bool) -> Bool =
    var yes = false
    for x in self
      if not yes then
        if try f(x) then yes = true
    yes
  // whether `f` is true of every element
  pub fn all(self, f: fn(T) -> Bool) -> Bool =
    var yes = true
    for x in self
      if yes then
        if not (try f(x)) then yes = false
    yes
  // how many elements `f` is true of
  pub fn count(self, f: fn(T) -> Bool) -> Int =
    var n = 0
    for x in self
      if try f(x) then n += 1
    n
  // whether `x` is in it
  pub fn includes(self, x: T) -> Bool =
    var yes = false
    for y in self
      if y == x then yes = true
    yes
  // `f` on each element, in order: a block that changes a `var` outside
  // it, `xs.each(fn(x) => total += x)`
  pub fn each(self, f: fn(T)) =
    for x in self
      try f(x)
  // `f` over each element in turn, from `init`
  pub fn reduce<A>(self, init: A, f: fn(A, T) -> A) -> A =
    var acc = init
    for x in self
      acc = try f(acc, x)
    acc
  // every element added up, from `T.zero`, in order; but `Float`s, in
  // eight lanes added pairwise, the same on every machine, which a
  // vector unit can do (foundations.md, decision 15; `float_sum`)
  pub fn sum(self) -> T =
    if float_lanes(self) then float_sum(self)
    else
      var total = T.zero
      for x in self
        total = total + x
      total
  // the least element, the first of those equal
  pub fn min(self) -> Option<T> =
    var best = None
    for x in self
      match best
        Some(b) => if x < b then best = Some(x)
        None => best = Some(x)
    best
  // the greatest element, the first of those equal
  pub fn max(self) -> Option<T> =
    var best = None
    for x in self
      match best
        Some(b) => if x > b then best = Some(x)
        None => best = Some(x)
    best
  // the element `f` gives the least of, the first of those equal; `f`
  // is called once for each
  pub fn min_by<K>(self, f: fn(T) -> K) -> Option<T> =
    var best = None
    for x in self
      let k = try f(x)
      match best
        Some((b, _)) => if k < b then best = Some((k, x))
        None => best = Some((k, x))
    match best
      Some((_, x)) => Some(x)
      None => None
  // the element `f` gives the greatest of, the first of those equal
  pub fn max_by<K>(self, f: fn(T) -> K) -> Option<T> =
    var best = None
    for x in self
      let k = try f(x)
      match best
        Some((b, _)) => if k > b then best = Some((k, x))
        None => best = Some((k, x))
    match best
      Some((_, x)) => Some(x)
      None => None
  // in the order of what `f` gives each, called once for each; equal ones
  // stay in the order they were
  pub fn sort_by<K>(self, f: fn(T) -> K) -> Array<T> =
    var keyed: Array<(K, Int)> = []
    for (i, x) in self.with_index()
      &keyed.push((try f(x), i))
    var out: Array<T> = []
    for (_, i) in keyed.sort()
      &out.push(self[i])
    out
  // each thing `f` gives, with the elements that gave it, in order
  pub fn group_by<K>(self, f: fn(T) -> K) -> Map<K, Array<T>> =
    var groups: Map<K, Array<T>> = Map.empty
    for x in self
      let k = try f(x)
      var xs = groups.get(k).unwrap_or([])
      &xs.push(x)
      &groups.set(k, xs)
    groups
  // the elements `f` is true of, and the rest
  pub fn partition(self, f: fn(T) -> Bool) -> (Array<T>, Array<T>) =
    var yes: Array<T> = []
    var no: Array<T> = []
    for x in self
      if try f(x) then &yes.push(x) else &no.push(x)
    (yes, no)
  // each element, with how many times it's there
  pub fn tally(self) -> Map<T, Int> =
    var counts: Map<T, Int> = Map.empty
    for x in self
      &counts.set(x, counts.get(x).unwrap_or(0) + 1)
    counts
  // without repeats, the first of each kept
  pub fn uniq(self) -> Array<T> =
    var seen: Set<T> = Set.empty
    var out: Array<T> = []
    for x in self
      if not seen.includes(x) then
        &seen.add(x)
        &out.push(x)
    out
  // each element with the one at its place in `ys`, as long as both have
  // one: a cursor, `for (x, y) in xs.zip(ys)`, which makes no array of
  // the pairs (`Zip`)
  pub fn zip<U>(self, ys: Array<U>) -> Zip<T, U> = Zip { xs: self, ys: ys, at: 0 }
  // each element with where it is, counting from 0
  pub fn with_index(self) -> Array<(Int, T)> =
    var out: Array<(Int, T)> = []
    for i in 0..self.len()
      &out.push((i, self[i]))
    out
  // the first `n` elements, or all of them if there are fewer
  pub fn take(self, n: Int) -> Array<T> =
    assert n >= 0
    var out: Array<T> = []
    for i in 0..(if n < self.len() then n else self.len())
      &out.push(self[i])
    out
  // all but the first `n` elements
  pub fn drop(self, n: Int) -> Array<T> =
    assert n >= 0
    var out: Array<T> = []
    for i in n..self.len()
      &out.push(self[i])
    out
  // last first
  pub fn reverse(self) -> Array<T> =
    var out: Array<T> = []
    for i in 0..self.len()
      &out.push(self[self.len() - 1 - i])
    out

// Keys and their values, found by the key's hash, in the order each key
// was first set. Besides what's built in, `get`, `set`, `remove`,
// `includes(k)`, `keys`, `values` and `len`, it has `Array`'s methods,
// over its `(k, v)` pairs: those that keep some of them give a `Map`.
pub type Map<K, V> = builtin
  pub let empty: Map<K, V> = map_empty()
  // its pairs, in order, as `for` goes over them
  fn pairs(self) -> Array<(K, V)> =
    var out: Array<(K, V)> = []
    for p in self
      &out.push(p)
    out
  pub fn first(self) -> Option<(K, V)> = self.pairs().first()
  pub fn last(self) -> Option<(K, V)> = self.pairs().last()
  pub fn map<U>(self, f: fn((K, V)) -> U) -> Array<U> = try self.pairs().map(f)
  pub fn flat_map<U>(self, f: fn((K, V)) -> Array<U>) -> Array<U> =
    try self.pairs().flat_map(f)
  pub fn select(self, f: fn((K, V)) -> Bool) -> Map<K, V> =
    Map.of(try self.pairs().select(f))
  pub fn reject(self, f: fn((K, V)) -> Bool) -> Map<K, V> =
    Map.of(try self.pairs().reject(f))
  pub fn find(self, f: fn((K, V)) -> Bool) -> Option<(K, V)> =
    try self.pairs().find(f)
  pub fn any(self, f: fn((K, V)) -> Bool) -> Bool = try self.pairs().any(f)
  pub fn all(self, f: fn((K, V)) -> Bool) -> Bool = try self.pairs().all(f)
  pub fn count(self, f: fn((K, V)) -> Bool) -> Int = try self.pairs().count(f)
  pub fn reduce<A>(self, init: A, f: fn(A, (K, V)) -> A) -> A =
    try self.pairs().reduce(init, f)
  pub fn min(self) -> Option<(K, V)> = self.pairs().min()
  pub fn max(self) -> Option<(K, V)> = self.pairs().max()
  pub fn min_by<B>(self, f: fn((K, V)) -> B) -> Option<(K, V)> =
    try self.pairs().min_by(f)
  pub fn max_by<B>(self, f: fn((K, V)) -> B) -> Option<(K, V)> =
    try self.pairs().max_by(f)
  pub fn sort(self) -> Array<(K, V)> = self.pairs().sort()
  pub fn sort_by<B>(self, f: fn((K, V)) -> B) -> Array<(K, V)> =
    try self.pairs().sort_by(f)
  pub fn group_by<B>(self, f: fn((K, V)) -> B) -> Map<B, Array<(K, V)>> =
    try self.pairs().group_by(f)
  pub fn partition(self, f: fn((K, V)) -> Bool) -> (Map<K, V>, Map<K, V>) =
    let (yes, no) = try self.pairs().partition(f)
    (Map.of(yes), Map.of(no))
  pub fn zip<U>(self, ys: Array<U>) -> Zip<(K, V), U> = self.pairs().zip(ys)
  pub fn with_index(self) -> Array<(Int, (K, V))> = self.pairs().with_index()
  pub fn take(self, n: Int) -> Map<K, V> = Map.of(self.pairs().take(n))
  pub fn drop(self, n: Int) -> Map<K, V> = Map.of(self.pairs().drop(n))
  pub fn reverse(self) -> Map<K, V> = Map.of(self.pairs().reverse())

// Two arrays gone over together, a pair of elements at a time, from `at`,
// as long as both have one: what `xs.zip(ys)` gives, a cursor (stdlib.md,
// "Streams: cursors first"). A `for` over `xs.zip(ys)` itself counts
// along both arrays at once, with no `Zip` made and one bounds check for
// the loop, the shorter length (lower.ml, `zip_loop`)
pub type Zip<T, U> = opaque { xs: Array<T>, ys: Array<U>, at: Int }
  pub fn next(inout self) -> Option<(T, U)> =
    let i = self.at
    if i >= 0 && i < self.xs.len() && i < self.ys.len() then
      self.at += 1
      Some((self.xs[i], self.ys[i]))
    else None
  // and a third array's elements: `xs.zip(ys).zip(zs)` gives `(x, y, z)`s
  pub fn zip<V>(self, zs: Array<V>) -> Zip3<T, U, V> =
    Zip3 { xs: self.xs, ys: self.ys, zs: zs, at: self.at }

// Three arrays gone over together, as `Zip` goes over two
pub type Zip3<T, U, V> = opaque { xs: Array<T>, ys: Array<U>, zs: Array<V>, at: Int }
  pub fn next(inout self) -> Option<(T, U, V)> =
    let i = self.at
    if i >= 0 && i < self.xs.len() && i < self.ys.len() && i < self.zs.len() then
      self.at += 1
      Some((self.xs[i], self.ys[i], self.zs[i]))
    else None

// Each value once, found by its hash, in the order each was first added.
// Besides what's built in, `add`, `remove`, `includes` and `len`, it has
// `Array`'s methods: those that keep some of its members give a `Set`.
pub type Set<T> = builtin
  pub let empty: Set<T> = set_empty()
  // its members, in order, as `for` goes over them
  fn members(self) -> Array<T> =
    var out: Array<T> = []
    for x in self
      &out.push(x)
    out
  pub fn first(self) -> Option<T> = self.members().first()
  pub fn last(self) -> Option<T> = self.members().last()
  pub fn map<U>(self, f: fn(T) -> U) -> Array<U> = try self.members().map(f)
  pub fn flat_map<U>(self, f: fn(T) -> Array<U>) -> Array<U> =
    try self.members().flat_map(f)
  pub fn select(self, f: fn(T) -> Bool) -> Set<T> =
    Set.of(try self.members().select(f))
  pub fn reject(self, f: fn(T) -> Bool) -> Set<T> =
    Set.of(try self.members().reject(f))
  pub fn find(self, f: fn(T) -> Bool) -> Option<T> = try self.members().find(f)
  pub fn any(self, f: fn(T) -> Bool) -> Bool = try self.members().any(f)
  pub fn all(self, f: fn(T) -> Bool) -> Bool = try self.members().all(f)
  pub fn count(self, f: fn(T) -> Bool) -> Int = try self.members().count(f)
  pub fn reduce<A>(self, init: A, f: fn(A, T) -> A) -> A =
    try self.members().reduce(init, f)
  pub fn sum(self) -> T = self.members().sum()
  pub fn min(self) -> Option<T> = self.members().min()
  pub fn max(self) -> Option<T> = self.members().max()
  pub fn min_by<B>(self, f: fn(T) -> B) -> Option<T> = try self.members().min_by(f)
  pub fn max_by<B>(self, f: fn(T) -> B) -> Option<T> = try self.members().max_by(f)
  pub fn sort(self) -> Array<T> = self.members().sort()
  pub fn sort_by<B>(self, f: fn(T) -> B) -> Array<T> = try self.members().sort_by(f)
  pub fn group_by<B>(self, f: fn(T) -> B) -> Map<B, Array<T>> =
    try self.members().group_by(f)
  pub fn partition(self, f: fn(T) -> Bool) -> (Set<T>, Set<T>) =
    let (yes, no) = try self.members().partition(f)
    (Set.of(yes), Set.of(no))
  pub fn zip<U>(self, ys: Array<U>) -> Zip<T, U> = self.members().zip(ys)
  pub fn with_index(self) -> Array<(Int, T)> = self.members().with_index()
  pub fn take(self, n: Int) -> Set<T> = Set.of(self.members().take(n))
  pub fn drop(self, n: Int) -> Set<T> = Set.of(self.members().drop(n))
  pub fn reverse(self) -> Set<T> = Set.of(self.members().reverse())

// ---- strings (strings.md) ----
//
// A `Str` is UTF-8, and its positions and lengths are in bytes. Most of
// its members are built in; these are written here.

pub type Str = builtin
  // whether it has no bytes, which is whether it has no characters
  pub fn is_empty(self) -> Bool = self.byte_len() == 0
  // its characters, each a one-code-point `Str`, a slice of it: a cursor
  // (streams.md, "Data: cursors you keep")
  pub fn chars(self) -> Chars = Chars { s: self, pos: 0 }
  // the rest of strings.md's table (compiler.md, "Bytes stage, part two",
  // step 5), over `index`, `split` and slices, each a slice of this
  // string where it gives one; `Bytes` has the same, meaning the same.
  // whether `t` is in it
  pub fn includes(self, t: Str) -> Bool = self.index(t).is_some()
  // what's after `t`, if it starts with `t`
  pub fn strip_prefix(self, t: Str) -> Option<Str> =
    if self.starts_with(t) then Some(self[t.byte_len()..self.byte_len()]) else None
  // what's before `t`, if it ends with `t`
  pub fn strip_suffix(self, t: Str) -> Option<Str> =
    if self.ends_with(t) then Some(self[0..self.byte_len() - t.byte_len()]) else None
  // what's before the first `sep` and what's after it, if it's there
  pub fn split_once(self, sep: Str) -> Option<(Str, Str)> =
    match self.index(sep)
      Some(i) => Some((self[0..i], self[i + sep.byte_len()..self.byte_len()]))
      None => None
  // its lines: the parts between each `\n`, without a `\r` before it,
  // and no empty one after the last (Rust's `lines`)
  pub fn lines(self) -> Array<Str> =
    var out: Array<Str> = []
    let parts = self.split("\n")
    let last = parts.len() - 1
    for i in 0..last
      let line = parts[i]
      let n = line.byte_len()
      if n > 0 && line.bytes().u8(n - 1) == 13 then &out.push(line[0..n - 1])
      else &out.push(line)
    if not parts[last].is_empty() then &out.push(parts[last])
    out
  // the runs of it between ASCII whitespace, `trim`'s: none empty
  pub fn fields(self) -> Array<Str> =
    var out: Array<Str> = []
    let b = self.bytes()
    var start = -1
    for i in 0..b.len()
      if ascii_space(b.u8(i)) then
        if start >= 0 then
          &out.push(self[start..i])
          start = -1
      else if start < 0 then start = i
    if start >= 0 then &out.push(self[start..b.len()])
    out
  // every `from` in it made `to`, left to right, none overlapping
  pub fn replace(self, from: Str, to: Str) -> Str =
    if from.is_empty() then lib_panic("`replace` needs a string to replace that isn't empty")
    else self.split(from).join(to)

// whether the byte `c` is ASCII whitespace, as `trim` takes it: a space,
// `\t`, `\n`, form feed or `\r` (strings.md, "Characters")
fn ascii_space(c: Int) -> Bool = c == 32 || c == 9 || c == 10 || c == 12 || c == 13

// the characters of `s` from `pos`, each a slice of `s` one code point
// long: what `s.chars()` gives
pub type Chars = opaque { s: Str, pos: Int }
  pub fn next(inout self) -> Option<Str> =
    let i = self.pos
    if i >= self.s.byte_len() then None
    else
      let j = self.s.char_ceil(i + 1)
      self.pos = j
      Some(self.s[i..j])

// ---- bytes: layer 3 of formats.md (compiler.md, "Bytes stage", "Layer
// 3: the API") ----
//
// Reads and writes at an offset, `b.u32_le(at)` and `&b.set_u32_le(at,
// x)`, are built in: a bad offset is a bug, and panics. A cursor reads
// in sequence, and fails with a `FormatError` when the input runs out,
// which a program handles.

// why bytes couldn't be read as what they were asked to be: `need` more
// bytes at `at`; or not a value of the type, `why`, at `at`, in the field
// `path` (layer 3 has no fields, so its path is empty); or a tag no case
// has (layer 2's)
pub type FormatError =
  ! Short(at: Int, need: Int) | Malformed(at: Int, path: Str, why: Str) | UnknownTag(at: Int, tag: Int)

pub type Bytes = builtin
  // a cursor at the start of these bytes, to read them in sequence. Every
  // `at` it reports counts from `from`, where these bytes start in their
  // stream or file (strings.md, "Positions")
  pub fn cursor(self, from: Int = 0) -> ByteCursor = ByteCursor { b: self, pos: 0, base: from }
  // `Str`'s search, split and trim names, meaning the same (compiler.md,
  // "Bytes stage, part two", step 5)
  pub fn includes(self, t: Bytes) -> Bool = self.index(t).is_some()
  pub fn strip_prefix(self, t: Bytes) -> Option<Bytes> =
    if self.starts_with(t) then Some(self[t.len()..self.len()]) else None
  pub fn strip_suffix(self, t: Bytes) -> Option<Bytes> =
    if self.ends_with(t) then Some(self[0..self.len() - t.len()]) else None
  pub fn split_once(self, sep: Bytes) -> Option<(Bytes, Bytes)> =
    match self.index(sep)
      Some(i) => Some((self[0..i], self[i + sep.len()..self.len()]))
      None => None
  pub fn lines(self) -> Array<Bytes> =
    var out: Array<Bytes> = []
    let parts = self.split(Bytes.of([10]))
    let last = parts.len() - 1
    for i in 0..last
      let line = parts[i]
      let n = line.len()
      if n > 0 && line.u8(n - 1) == 13 then &out.push(line[0..n - 1])
      else &out.push(line)
    if parts[last].len() > 0 then &out.push(parts[last])
    out
  pub fn fields(self) -> Array<Bytes> =
    var out: Array<Bytes> = []
    var start = -1
    for i in 0..self.len()
      if ascii_space(self.u8(i)) then
        if start >= 0 then
          &out.push(self[start..i])
          start = -1
      else if start < 0 then start = i
    if start >= 0 then &out.push(self[start..self.len()])
    out
  // every `from` in it made `to`, left to right, none overlapping
  pub fn replace(self, from: Bytes, to: Bytes) -> Bytes =
    if from.len() == 0 then lib_panic("`replace` needs bytes to replace that aren't empty")
    else
      let parts = self.split(from)
      var out = parts[0]
      for i in 1..parts.len()
        out += to
        out += parts[i]
      out

// the 64 bits of `x` as the number they are unsigned, written out: `x`
// if it isn't negative, else 2^64 + `x`, whose last digit is found by
// halving it first, since no `Int` holds it
fn show_unsigned(x: Int) -> Str =
  if x >= 0 then show(x)
  else
    let q = x.shr(1).bit_and(9_223_372_036_854_775_807) / 5
    show(q) + show(x.wrapping_sub(q.wrapping_mul(10)))

// fails with `Short(at, need)`, as a `FormatError`, all of it: each of a
// cursor's reads says it can fail with any, as layer 2's do, so a
// framing loop reads the same at either layer
fn short(at: Int, need: Int) ! FormatError =
  let e: Result<Unit, ! FormatError> = Err(Short(at, need))
  try e

// fails unless `n` bytes are left at `at` of `len`, which is said at
// `base + at`: of a cursor's numbers, not the cursor, which a call would
// count once more
fn room(base: Int, len: Int, at: Int, n: Int) ! FormatError =
  if len - at < n then try short(base + at, n - (len - at)) else ()

// bytes read in sequence from `pos`: what `b.cursor()` gives. It's a
// value, so a copy of one tries a record, and the cursor stays where it
// was if the record isn't all there yet. A read that fails moves it
// nowhere: `Short(at, need)` says where the read began and how many
// more bytes it needs. Each `at` it reports, and `at()`, counts from
// `base`, the `from` it was made with
pub type ByteCursor = opaque { b: Bytes, pos: Int, base: Int }
  // where it is: in the bytes it was made from, counting from `base`
  pub fn at(self) -> Int = self.base + self.pos
  // how many bytes are after it
  pub fn left(self) -> Int = self.b.len() - self.pos
  // those bytes, a slice
  pub fn rest(self) -> Bytes = self.b[self.pos..self.b.len()]
  pub fn u8(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 1 then try short(self.base + at, at + 1 - self.b.len()) else ()
    self.pos = at + 1
    self.b.u8(at)
  pub fn i8(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 1 then try short(self.base + at, at + 1 - self.b.len()) else ()
    self.pos = at + 1
    self.b.i8(at)
  pub fn u16_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 2 then try short(self.base + at, at + 2 - self.b.len()) else ()
    self.pos = at + 2
    self.b.u16_le(at)
  pub fn u16_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 2 then try short(self.base + at, at + 2 - self.b.len()) else ()
    self.pos = at + 2
    self.b.u16_be(at)
  pub fn i16_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 2 then try short(self.base + at, at + 2 - self.b.len()) else ()
    self.pos = at + 2
    self.b.i16_le(at)
  pub fn i16_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 2 then try short(self.base + at, at + 2 - self.b.len()) else ()
    self.pos = at + 2
    self.b.i16_be(at)
  pub fn u32_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 4 then try short(self.base + at, at + 4 - self.b.len()) else ()
    self.pos = at + 4
    self.b.u32_le(at)
  pub fn u32_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 4 then try short(self.base + at, at + 4 - self.b.len()) else ()
    self.pos = at + 4
    self.b.u32_be(at)
  pub fn i32_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 4 then try short(self.base + at, at + 4 - self.b.len()) else ()
    self.pos = at + 4
    self.b.i32_le(at)
  pub fn i32_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 4 then try short(self.base + at, at + 4 - self.b.len()) else ()
    self.pos = at + 4
    self.b.i32_be(at)
  // a `u64` of 2^63 or more isn't an `Int`: `Malformed`, which reading
  // its bits with `i64_le` doesn't fail with
  pub fn u64_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 8 then try short(self.base + at, at + 8 - self.b.len()) else ()
    let x = self.b.i64_le(at)
    if x < 0 then
      fail Malformed(self.base + at, "", show_unsigned(x) + " is more than an `Int` holds")
    else
      self.pos = at + 8
      x
  pub fn u64_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 8 then try short(self.base + at, at + 8 - self.b.len()) else ()
    let x = self.b.i64_be(at)
    if x < 0 then
      fail Malformed(self.base + at, "", show_unsigned(x) + " is more than an `Int` holds")
    else
      self.pos = at + 8
      x
  pub fn i64_le(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 8 then try short(self.base + at, at + 8 - self.b.len()) else ()
    self.pos = at + 8
    self.b.i64_le(at)
  pub fn i64_be(inout self) -> Int ! FormatError =
    let at = self.pos
    if self.b.len() - at < 8 then try short(self.base + at, at + 8 - self.b.len()) else ()
    self.pos = at + 8
    self.b.i64_be(at)
  // a `VarUInt`, LEB128: 7 bits a byte, least first, the top bit set on
  // all but the last, at most 10 bytes, and less than 2^63. A longer form
  // than needed is read, as Go's `binary.Uvarint` reads it. One byte, a
  // number below 128, is read at once
  pub fn varuint(inout self) -> Int ! FormatError =
    let at = self.pos
    if at < self.b.len() && self.b.u8(at) < 128 then
      self.pos = at + 1
      self.b.u8(at)
    else try &self.var_bits(false)
  // a `VarInt`: a `VarUInt`'s bits, zigzag, so every `Int` is one
  pub fn varint(inout self) -> Int ! FormatError =
    let z = try &self.var_bits(true)
    z.shr(1).bit_and(9_223_372_036_854_775_807).xor(0 - z.bit_and(1))
  // the bits of a `VarInt` (`signed`) or a `VarUInt`, and the cursor
  // moved past them
  fn var_bits(inout self, signed: Bool) -> Int ! FormatError =
    let n = self.b.len()
    var i = self.pos
    var z = 0
    var shift = 0
    var more = true
    while more
      if i >= n then try short(self.base + self.pos, 1) else ()
      let v = self.b.u8(i)
      if shift == 63 then
        if v >= 128 then fail Malformed(self.base + self.pos, "", "a `VarUInt` is at most 10 bytes")
        else if signed && v > 1 then
          fail Malformed(self.base + self.pos, "", "a `VarInt` of more than 64 bits is more than an `Int` holds")
        else if not signed && v > 0 then
          fail Malformed(self.base + self.pos, "", "a `VarUInt` of 2^63 or more is more than an `Int` holds")
        else ()
      else ()
      z = z.bit_or(v.bit_and(127).shl(shift))
      shift += 7
      i += 1
      more = v >= 128
    self.pos = i
    z
  // the next `n` bytes, a slice
  pub fn bytes(inout self, n: Int) -> Bytes ! FormatError =
    if n < 0 then lib_panic("a cursor's `bytes` of a negative count") else ()
    try room(self.base, self.b.len(), self.pos, n)
    let s = self.b[self.pos..self.pos + n]
    self.pos += n
    s
  // past the next `n` bytes
  pub fn skip(inout self, n: Int) ! FormatError =
    if n < 0 then lib_panic("a cursor's `skip` of a negative count") else ()
    try room(self.base, self.b.len(), self.pos, n)
    self.pos += n

// ---- time ----
//
// Inside the prelude each is a number of milliseconds. A `Duration` is a
// number of its own (operators.md, "Number types"); a `Time` and an
// `Instant` are moments, so two can be told apart, giving a `Duration`,
// and one moved on by a `Duration`, but not added together.

// how long something takes
pub type Duration = opaque Int with numeric
  pub fn ms(n: Int) -> Duration = n
  pub fn seconds(n: Int) -> Duration = n * 1000
  pub fn minutes(n: Int) -> Duration = n * 60000
  // how many milliseconds it is
  pub fn in_ms(self) -> Int = self

// a moment on the calendar: since the epoch, 1970-01-01 00:00 UTC
pub type Time = opaque Int
  pub let epoch: Time = 0
  pub fn add(self, d: Duration) -> Time = self + d.in_ms()
  pub fn sub(self, t: Time) -> Duration = Duration.ms(self - t)
  pub fn sub(self, d: Duration) -> Time = self - d.in_ms()
  // ordered by when it is
  fn key(self) -> Int = self

// a moment for measuring how long something took, on a clock that never
// goes back: an instant means nothing on its own, only next to another
pub type Instant = opaque Int
  pub let zero: Instant = 0
  pub fn add(self, d: Duration) -> Instant = self + d.in_ms()
  pub fn sub(self, i: Instant) -> Duration = Duration.ms(self - i)
  pub fn sub(self, d: Duration) -> Instant = self - d.in_ms()
  // ordered by when it is
  fn key(self) -> Int = self

// ---- paths ----

// where a file is, as the system writes it: names with `/` between them
pub type Path = opaque Str
  pub fn of(s: Str) -> Path = s
  // `name` inside this path, or `name` itself if it starts at the root
  pub fn join(self, name: Str) -> Path =
    if self == "" || name.starts_with("/") then name
    else
      // a path that ends in `/` has an empty last part
      let parts = self.split("/")
      if parts[parts.len() - 1] == "" then self + name
      else self + "/" + name
  pub fn show(self) -> Str = self

// ---- the built-in dependencies (deps.md, "Built in") ----
//
// The runtime installs each one's `real` around `main`, if `main` uses
// it. It's private: nothing else can install the world.

pub dep Clock =
  now: fn() -> Time
  instant: fn() -> Instant
  sleep: fn(d: Duration)

  // a clock stopped at `at`, that never sleeps
  pub fn frozen(at: Time) -> Clock = frozen_clock(at)
  let real: Clock = real_clock()

handler frozen_clock(at: Time) for Clock =
  now() => at
  instant() => Instant.zero
  sleep(_) => ()

handler real_clock() for Clock =
  now() => clock_now()
  instant() => clock_instant()
  sleep(d) => clock_sleep(d)

pub dep Random =
  // a number from 0 up to, but not including, `below`
  int: fn(below: Int) -> Int

  let real: Random = real_random()

handler real_random() for Random =
  int(below) => random_int(below)

pub dep Console =
  write: fn(line: Str)
  // a line apart from what the program writes: how it's going, or what
  // went wrong
  error: fn(line: Str)

  let real: Console = real_console()

handler real_console() for Console =
  write(line) => console_write(line)
  error(line) => console_error(line)

// what any value shows as, on a line of its own
pub fn print<T>(x: T) uses Console = Console.write(show(x))

// a file: where it is, and what's in it
pub type File = { path: Path, data: Bytes }

// every way the real `Fs` can fail: there's nothing at the path, the
// system won't let this program at it, it's a folder, or something else
// went wrong, which the system gives its reason for
pub type FsError =
  ! NoSuchFile(path: Path) | NotAllowed(path: Path) | IsAFolder(path: Path) | FsFailed(path: Path, reason: Str)

// what the system said to a read or a write, which `fs_checked` turns
// into its value or its error
// how `Array.map` makes its array of `T`s (`map_into`)
type MapInto<T> =
  | InPlace
  | Fresh

type FsOutcome<T> =
  | FsDone(value: T)
  | FsMissing
  | FsDenied
  | FsFolder
  | FsOther(reason: Str)

fn fs_checked<T>(o: FsOutcome<T>, p: Path) -> T ! FsError =
  match o
    FsDone(v) => v
    FsMissing => fail NoSuchFile(p)
    FsDenied => fail NotAllowed(p)
    FsFolder => fail IsAFolder(p)
    FsOther(reason) => fail FsFailed(p, reason)

pub dep Fs =
  read: fn(p: Path) -> Bytes ! FsError
  // makes the file, or replaces what's in it
  write: fn(p: Path, b: Bytes) ! FsError
  exists: fn(p: Path) -> Bool

  // what's in a file, as a string
  pub fn read_str(p: Path) -> Str ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Fs =
    let b = try Fs.read(p)
    try Str.from_utf8(b)
  let real: Fs = real_fs()

handler real_fs() for Fs =
  read(p) => try fs_checked(fs_read(p), p)
  write(p, b) => try fs_checked(fs_write(p, b), p)
  exists(p) => fs_exists(p)

pub dep Os =
  // what `ren run file.ren -- args` was given after the `--`
  args: fn() -> Array<Str>

  let real: Os = real_os()

handler real_os() for Os =
  args() => os_args()

// every way the real `Proc` can fail: there's no such program, the
// system wouldn't start it, with its reason, or it was killed before it
// could exit
pub type ProcError = ! NoSuchProgram(name: Str) | CantRun(name: Str, reason: Str) | Killed(name: Str)

// what became of a program, which `proc_checked` turns into its exit code
// or its error
type ProcOutcome =
  | ProcExited(code: Int)
  | ProcMissing
  | ProcNotStarted(reason: Str)
  | ProcKilled

fn proc_checked(o: ProcOutcome, cmd: Str) -> Int ! ProcError =
  match o
    ProcExited(code) => code
    ProcMissing => fail NoSuchProgram(cmd)
    ProcNotStarted(reason) => fail CantRun(cmd, reason)
    ProcKilled => fail Killed(cmd)

// how a cancelled `Proc.run` kills its program: `Tree`, the program and
// whatever it started, its process group, which it was started in on
// its own; or `Child`, the program alone, which leaves what it started
// running, but keeps it in this program's group, where it can read the
// terminal
pub type Kill = | Tree | Child

pub dep Proc =
  // runs the program `cmd`, found on `PATH` unless it has a `/` in it,
  // with what this program prints to and reads from, and gives back its
  // exit code; cancelled, it kills it as `kill` says
  run: fn(cmd: Str, args: Array<Str>, kill: Kill = Tree) -> Int ! ProcError

  let real: Proc = real_proc()

handler real_proc() for Proc =
  run(cmd, args, kill) => try proc_checked(proc_run(cmd, args, kill), cmd)

// ---- the network (compiler.md, "Stage 11a", "`Net`") ----
//
// A thin layer over TCP: no HTTP, no names looked up, no TLS. The real
// one waits in the scheduler, so other tasks run meanwhile, and a test
// gets `sim.net()`, connections in memory (std_lib.ml).

// where a program listens: a host written as numbers, `127.0.0.1`, and
// a port
pub type Addr = { host: Str, port: Int }

// a socket listening, and a connection, as the runtime numbers them
pub type Listener = opaque Int
pub type Conn = opaque Int

// a signal the program is sent
pub type Signal = opaque Int
  // SIGTERM: asked to stop
  pub let term: Signal = 15
  // SIGINT: control-C
  pub let interrupt: Signal = 2

// every way the network can fail: nothing listens at the address, or
// something does already, the connection is closed, or something else
// went wrong, which the system gives its reason for
pub type NetError = ! Refused(addr: Addr) | InUse(addr: Addr) | Closed | NetFailed(reason: Str)

pub dep Net =
  // listens at `addr`
  listen: fn(addr: Addr) -> Listener ! NetError
  // waits for a connection
  accept: fn(l: Listener) -> Conn ! NetError
  // a connection, or `None` once `stop` has been sent to this program;
  // after `None` the listener is closed, and the tasks of the caller's
  // scopes, the connections in flight, have the cleanup deadline to end
  accept_until: fn(l: Listener, stop: Signal) -> Option<Conn> ! NetError
  // up to `max` bytes, as soon as there are some; none once the other
  // side has closed
  read: fn(c: Conn, max: Int) -> Bytes ! NetError
  // waits until all of `b` is written
  write: fn(c: Conn, b: Bytes) ! NetError
  close: fn(c: Conn)

  let real: Net = real_net()

// what the system said to a call of the network, which `net_checked`
// turns into its value or its error
type NetOutcome<T> =
  | NetDone(value: T)
  | NetRefused
  | NetInUse
  | NetClosed
  | NetOther(reason: Str)

// [addr] is what the call was for; a connection's calls are for none,
// and are never refused or in use
fn net_checked<T>(o: NetOutcome<T>, addr: Addr) -> T ! NetError =
  match o
    NetDone(v) => v
    NetRefused => fail Refused(addr)
    NetInUse => fail InUse(addr)
    NetClosed => fail Closed
    NetOther(reason) => fail NetFailed(reason)

fn nowhere() -> Addr = Addr { host: "", port: 0 }

handler real_net() for Net =
  listen(addr) => try net_checked(net_listen(addr.host, addr.port), addr)
  accept(l) => try net_checked(net_accept(l), nowhere())
  accept_until(l, stop) =>
    let c = try net_checked(net_accept_until(l, stop), nowhere())
    if not c.is_some() then task_drain()
    c
  read(c, max) => try net_checked(net_read(c, max), nowhere())
  write(c, b) => try net_checked(net_write(c, b), nowhere())
  close(c) => net_close(c)

// ---- tasks (async.md; foundations.md, decisions 7 and 9) ----
//
// The runtime is a handler of `Async`, installed around `main` as the
// world is. Its operations are `yield` and `tick`; the functions that
// take blocks are its members, written over the scheduler's intrinsics
// (eval/sched.ml; compiler.md, "Stage 11a").

// what `task_isolate` gives: the body's value, or the message of the
// panic that was made a value
type Isolated<T> =
  | Finished(value: T)
  | PanickedWith(msg: Str)

pub dep Async =
  // let every other task that can run, run first
  yield: fn()
  // return once every task that could run when it was called has run
  // until it waits: the batching point
  tick: fn()

  // runs `body` with a scope its tasks are spawned into, and returns
  // once they've all ended; `spawn` waits while `max` of them run
  pub fn scope<T>(max: Int = 64, body: fn(s: Scope) -> T) -> T uses Async =
    try scope_run(max, body)
  // waits until `cond` holds: only in an operation, whose instance it
  // lets go of meanwhile
  pub fn until(cond: fn() -> Bool) uses Async =
    if not cond() then task_until(cond)
  // `body`, or `Timeout` if it's still running after `d`
  pub fn timeout<T>(d: Duration, body: fn() -> T) -> T ! Timeout uses Async =
    match try task_timeout(d, body)
      Some(v) => v
      None => fail Timeout
  // whichever of `a` and `b` finishes first; the other is cancelled.
  // Neither can fail
  pub fn race<T>(a: concurrent fn() -> T, b: concurrent fn() -> T) -> T uses Async =
    task_race(a, b)
  // `body`, or `Panicked` if it panicked
  pub fn isolate<T>(body: fn() -> T) -> T ! Panicked(msg: Str) uses Async =
    match try task_isolate(body)
      Finished(v) => v
      PanickedWith(msg) => fail Panicked(msg)
  // `f` of each item of `xs`, `max` at once, the results in its order.
  // `xs` takes what `for` takes: a collection, a cursor, `&r` or a block,
  // pulled on this task only when there's room for one more
  pub fn map<T, U>(xs: fn() -> Option<T>, max: Int = 64, f: concurrent fn(x: T) -> U) -> Array<U> uses Async =
    try task_map(xs, max, f)
  // `f` of each item of `xs`, `max` at once, pulled as `map`'s are
  pub fn each<T>(xs: fn() -> Option<T>, max: Int = 64, f: concurrent fn(x: T)) uses Async =
    try task_each(xs, max, f)
  // runs `task` beside `body`: once `body` ends, by returning, failing
  // or being cancelled, `task` is cancelled and waited for. `task` may
  // fail: then `body` is cancelled, and that failure is the call's
  pub fn beside<T>(task: concurrent fn(), body: fn() -> T) -> T uses Async =
    try task_beside(task, body)
  // runs `body` with a scope its background tasks are spawned into as it
  // goes, `bg.spawn`: once `body` ends they're cancelled and waited for,
  // and the first of them to fail cancels `body` and is the call's error
  pub fn background<T>(body: fn(bg: Background<! ..e>) -> T) -> T ! ..e uses Async =
    try task_background(body)
  // `a` and `b` at once
  pub fn both<A, B>(a: concurrent fn() -> A, b: concurrent fn() -> B) -> (A, B) uses Async =
    try task_both(a, b)
  // runs `f` on a task beside `body`, sending what it makes through
  // `Send<T>`, which the call installs for it, at most `cap` ahead of what
  // `body` has taken: `items` gives each in turn, then `None` once `f` has
  // returned, or fails with what `f` failed with. Once `body` ends, by
  // finishing, `break` or a failure, `f` is cancelled and waited for
  pub fn produce<T, R>(cap: Int = 16, f: concurrent fn() uses Send<T>, body: fn(items: fn() -> Option<T>) -> R) -> R uses Async =
    try task_produce(cap, fn(out) => with sends(out) in try f(), fn(i) => try body(fn() => try inbox_take(i)))
  // `f` of each item of `src`, `max` at once, as `map`'s, but given to
  // `body` as they're made, in `src`'s order: `results` gives each, and
  // `src` is pulled, on this task, only when there's room for one more.
  // The tasks live exactly as long as `body`
  pub fn map_pull<T, U, R>(src: fn() -> Option<T>, max: Int = 64, f: concurrent fn(x: T) -> U, body: fn(results: fn() -> Option<U>) -> R) -> R uses Async =
    try task_map_pull(src, max, f, fn(i) => try body(fn() => try inbox_take(i)))
  // the worker the calling task runs on: 0 under `single`; under `sim`,
  // 0 or 1, two virtual workers, each task's drawn from the tape, so
  // routing by worker is found and replayed by a seed
  pub fn worker() -> Int uses Async = async_worker()
  // the runtime on one thread, in real time, with real I/O
  pub fn single() -> Async = single_runtime()
  let real: Async = single_runtime()

// One thread, in `single`'s order, in real time (eval/sched.ml): the
// scheduler's policy for its `with`'s body, and the one before once it
// ends. Natively, where nothing else runs, both operations return at
// once. `sim.scheduler(seed)` is the same over `runtime_sim` (std_lib.ml)
handler single_runtime() for Async =
  let was = runtime_single()
  finally(r) =>
    runtime_leave(was)
    try r
  yield() => async_yield()
  tick() => async_tick()

// what `Async.scope` gives its body: it's passed and called, never kept
// (foundations.md, decision 2, rule D)
pub type Scope = builtin
  // starts `body` as a task of this scope, waiting first while `max`
  // of its tasks run. It gives no handle: the scope owns the task, and
  // waits for it (concurrency.md, "The tree side"). Waiting
  // for two things is `Async.both`, and the first to finish
  // `Async.race`
  pub fn spawn(self, body: spawned fn()) uses Async = task_spawn(self, body)

// what `Async.background` gives its body: a scope whose tasks may fail,
// with the errors `E` says, which are the body's. Passed and called,
// never kept, as `Scope` is. Its `spawn`, `bg.spawn(body)`, is built in:
// `body` runs as a task until the background's body ends
pub type Background<E> = builtin

// what `Async.produce`'s producer sends through, which the call installs
// for it: `send` waits while the consumer has `cap` items still to take
// (streams.md, "Concurrency and time")
pub dep Send<T> =
  send: fn(x: T)

// the end of `Async.produce`'s buffer its producer sends to, and the end
// `produce` and `map_pull` give their body's items from, failing with
// what `E` says (eval.ml)
type Outbox<T> = builtin
type Inbox<T, E> = builtin

// `Send<T>` for `Async.produce`'s producer, into its buffer
handler sends<T>(out: Outbox<T>) for Send<T> uses Async =
  send(x) => outbox_send(out, x)

// ---- the keyed instance family (foundations.md, decision 18) ----
//
// Where instances live is the runtime's, as the scheduler is: a library
// that keeps many of one handler's, `striped` or `actors`, keeps them in
// a family, which makes one for a key, runs a call on one, evicts one
// and lists them, by the rules of decision 18. Which to evict, when, how
// many to keep and how to route are the library's (compiler.md,
// "Services stage", "The keyed instance family").

// a family `Instances.open` made: data, naming it in the runtime, kept
// in the state of the handler that opened it, never an instance
pub type Family<K, D> = builtin

// what `Instances.enter` gives: what making the instance failed with, if
// it did, which `Instances.made` fails with
pub type Pinned<D> = builtin

// what a family counts: its live instances, and those made and evicted
pub type InstanceCounts = { live: Int, made: Int, evicted: Int }

// an evictable instance, as a full family gives it to the library's
// `victim`: its key, and its use stamp, the family's count of takes when
// it was last taken, the smallest the longest ago
pub type Stamped<K> = { key: K, used: Int }

// the runtime's keyed instance family. Nothing installs it and no
// `uses` names it: it's the runtime's, as the scheduler is, and only
// these members reach it. Their waits are those of an operation of the
// handler that opened the family, which is installed outside each call
// that reaches them, and keeps the family's handle in its state
pub dep Instances =
  // a family of the instances `make` describes, one per key, at most
  // `cap` of them live, each key's mailbox holding at most `mailbox`
  // posted calls
  pub fn open<K, D>(make: spawned fn(k: K) -> D, cap: Int, mailbox: Int) -> Family<K, D> =
    family_open(make, cap, mailbox)
  // `c` as one operation of `k`'s instance, made first if it isn't
  // live, the instance kept from eviction meanwhile; waiting while the
  // family is full
  pub fn call<K, D, R>(f: Family<K, D>, k: K, c: Call<D, R, ! ..e>) -> R ! ..e =
    try family_call(f, k, c)
  // `k`'s instance made now, if it isn't live, waiting while the family
  // is full
  pub fn make<K, D>(f: Family<K, D>, k: K) = family_make(f, k)
  // the live keys, in the order they were made
  pub fn keys<K, D>(f: Family<K, D>) -> Array<K> = family_keys(f)
  // the evictable keys, in the order they were made
  pub fn evictable<K, D>(f: Family<K, D>) -> Array<K> = family_evictable(f)
  // evicts `k`'s instance now, running its `finally` on this task, if
  // it's live and evictable: whether it did
  pub fn evict<K, D>(f: Family<K, D>, k: K) -> Bool = family_evict(f, k)
  pub fn counts<K, D>(f: Family<K, D>) -> InstanceCounts = family_counts(f)
  // `body`, with `k`'s instance installed as the dependency it's of,
  // pinned, so it isn't evicted meanwhile: made first if it isn't live,
  // so it fails as making one does. Pinning it takes it, which writes its
  // use stamp. Making one in a full family evicts the key `victim` picks
  // from its evictable ones, given in the order they were made, each with
  // its stamp, running its `finally` on this task; while it picks none,
  // it waits
  pub fn pin<K, D, T>(f: Family<K, (D ! ..e)>, k: K, victim: spawned fn(evictable: Array<Stamped<K>>) -> Option<K>, body: fn() -> T uses D) -> T ! ..e =
    try family_pin(f, k, victim, body)
  // `body` with `k`'s instance installed, pinned, if it's live, without
  // making it or counting as use: whether it was
  pub fn visit<K, D>(f: Family<K, D>, k: K, body: fn() uses D) -> Bool =
    try family_visit(f, k, body)
  // the evictable keys last used at least `d` ago, by the scheduler's
  // clock, in the order they were made
  pub fn idle<K, D>(f: Family<K, D>, d: Duration) -> Array<K> = family_idle(f, d.in_ms())
  // `each` run at each call from outside the family into one of its
  // instances, an operation called through a pinned block, on the
  // calling task, before the call takes the instance: what the library
  // does there, `actors`' chaos
  pub fn at_edge<K, D>(f: Family<K, D>, each: spawned fn()) = family_edge(f, each)
  // `pin` for a block that gives nothing and can't fail, what making the
  // instance failed with kept in what it gives, for `made`: a library's
  // operation pins with it, since its type can't name that error
  pub fn enter<K, D>(f: Family<K, D>, k: K, victim: spawned fn(evictable: Array<Stamped<K>>) -> Option<K>, body: fn() uses D) -> Pinned<D> =
    try family_enter(f, k, victim, body)
  // puts `c` in `k`'s mailbox and returns: a task of the family's runs
  // it, as one operation of `k`'s instance, after those queued before
  // it. The instance is made first if it isn't live, as `enter` makes
  // it, what making it failed with kept in what it gives, for `made`;
  // then it waits for room in `k`'s mailbox, and only there
  pub fn post<K, D>(f: Family<K, D>, k: K, c: Call<D, Unit, !>, victim: spawned fn(evictable: Array<Stamped<K>>) -> Option<K>) -> Pinned<D> =
    family_post(f, k, c, victim)
  // `body` with the instances of `ks` held for it, each key once, in
  // the keys' order, each made first if it isn't live, as `enter` makes
  // it, what making one failed with kept in what it gives, for `made`.
  // No instance is installed for it: inside it, a `pin` of a key it holds
  // is pinned at once, and one of any other key of the family panics. It
  // never waits for room while it holds some of them
  pub fn hold<K, D>(f: Family<K, D>, ks: Array<K>, victim: spawned fn(evictable: Array<Stamped<K>>) -> Option<K>, body: fn()) -> Pinned<D> =
    try family_hold(f, ks, victim, body)
  // fails as making the instance `enter` pinned did, if it failed
  pub fn made<D>(p: Pinned<(D ! ..e)>) ! ..e = try family_made(p)
  // the family's end: what's posted is delivered, then the live
  // instances' `finally`s run, the last made's first; if the `with` that
  // installs the handler that opened it is cancelled, what's running is
  // cancelled, what's queued is dropped, and the `finally`s are given
  // `Err(Cancelled)`
  pub fn close<K, D>(f: Family<K, D>) = family_close(f)

// a call of an operation of whatever dependency `D` implements, which
// gives `R` and fails with `E`: generic code's `D.Call<R ! E>`, what a
// handler `for D`'s `call` clause is given. Made for a dependency, it's
// that one's `D.Call` (compiler.md, "Services stage", "`D.Call`")
pub type Call<D, R, E> = builtin
  // its first argument's hash, by its type's `key`, the same in every
  // run; `None` for an operation of no parameters
  pub fn first_hash(self) -> Option<Int> = call_first_hash(self)
  // two of its results: added (`add` is `+`'s), the larger, the
  // smaller, or joined, an `Array`'s or a `Str`'s. Each panics for a
  // result that can't be
  pub fn sum(self, a: R, b: R) -> R = call_add(self, a, b)
  pub fn max(self, a: R, b: R) -> R = call_max(self, a, b)
  pub fn min(self, a: R, b: R) -> R = call_min(self, a, b)
  pub fn concat(self, a: R, b: R) -> R = call_concat(self, a, b)
  // two of its results folded by `m`'s `call` clause, a merge's, `call(c,
  // a, b) => ...`; `m` has no state
  pub fn fold(self, m: D, a: R, b: R) -> R = call_fold(self, m, a, b)

// an operation of a dependency, as data: its name, how many parameters
// it takes, its result's type as an error writes it, `Int`, and whether
// that adds, orders and joins
pub type Operation = { name: Str, params: Int, gives: Str, adds: Bool, orders: Bool, concats: Bool }

// the operations of the dependency `h` implements, in the order it
// declares them: its declarations as data (decision 20, rule 3)
pub fn operations<D>(h: D) -> Array<Operation> = call_operations(h)

// ---- stripes (foundations.md, decision 18; language.md §11) ----
//
// `striped` keeps a fixed number of instances of one handler, in the
// runtime's family, and map-reduces over them. It's plain Ren over the
// family's dependency, `Async.worker()` and the program's `D.Call`, which
// any library can use (compiler.md, "Services stage", "Stripes").

// how `striped` routes an operation whose first parameter has a key
pub type By =
  // to one of `n` stripes, by the key
  | Key(n: Int = 16)
  // to the stripe of the worker the caller runs on: one under `single`,
  // two under `sim`
  | Worker

// how `striped` folds the results of an operation with no key, which
// runs on every stripe, left to right in stripe order
pub type Fold<D> =
  // none given, which `striped` refuses at its `with` where it's needed
  | Unmerged
  | Sum
  | Max
  | Min
  | Concat
  // a stateless handler of `D` whose `call(c, a, b)` clause folds two
  // stripes' results of the call `c`
  | Custom(m: D)

// the instances of `h`, by stripe, kept by the runtime's family: code
// that uses `D` can't tell one instance serving it from sixteen. An
// operation whose first parameter has a key runs on the stripe `by`
// routes it to; one with none runs on every stripe, each in turn, so what
// they give isn't a snapshot (the split law), folded by `merge`
pub handler striped<D>(h: D, by: By = Key, merge: Fold<D> = Unmerged) for D uses Async =
  // under `Key(n)`, its n stripes, made now, in order; under `Worker`,
  // each worker's, made on its first call
  let n = match by
    Key(k) => k
    Worker => 0
  let _ = stripes_refused(h, by, n, merge)
  let fam = Instances.open(fn(i: Int) => h, if n > 0 then n else 1024, 1)
  let _ = stripes_made(fam, n)
  finally(r) =>
    Instances.close(fam)
    try r
  call(c) =>
    match c.first_hash()
      Some(x) => try Instances.call(fam, stripe(by, x), c)
      None =>
        // every stripe, in order, each called on its own; under `Worker`,
        // the caller's at least
        if by == By.Worker then Instances.make(fam, Async.worker())
        var got = None
        for i in Instances.keys(fam)
          let v = try Instances.call(fam, i, c)
          got = match got
            None => Some(v)
            Some(a) => Some(folded(merge, c, a, v))
        got orelse lib_panic("`striped` has no stripe")

// what `striped` refuses at its `with`, a panic there naming what's
// wrong (decision 20, rule 3: a check a library makes on its arguments,
// at the `with` until stage 12 makes it as the program is built): fewer
// than 1 stripe, and an operation with no key that gives a value, with
// no fold or one that doesn't fit what it gives
fn stripes_refused<D>(h: D, by: By, n: Int, merge: Fold<D>) =
  if by != By.Worker && n < 1 then lib_panic("`striped` keeps at least 1 stripe, not " + show(n))
  for op in operations(h)
    if op.params == 0 && op.gives != "()" then
      let gives = "`" + op.gives + "`"
      match merge
        Unmerged =>
          lib_panic("`" + op.name + "` runs on every stripe and gives " + article(op.gives) + " " + gives + ", so `striped` needs `merge:`")
        Sum =>
          if not op.adds then
            lib_panic("`merge: Sum` adds what `" + op.name + "` gives, and " + article(op.gives) + " " + gives + " isn't a number")
        Max | Min =>
          if not op.orders then
            lib_panic("`merge: " + show(merge) + "` compares what `" + op.name + "` gives, and " + article(op.gives) + " " + gives + " isn't ordered")
        Concat =>
          if not op.concats then
            lib_panic("`merge: Concat` joins what `" + op.name + "` gives, and " + article(op.gives) + " " + gives + " isn't an `Array` or a `Str`")
        Custom(_) => ()

// "a" or "an", before a type's name
fn article(t: Str) -> Str =
  if t.starts_with("A") || t.starts_with("E") || t.starts_with("I") || t.starts_with("O") || t.starts_with("U") then "an" else "a"

// the stripes 0 to `n`, made in order
fn stripes_made<D>(fam: Family<Int, D>, n: Int) =
  for i in 0..n
    Instances.make(fam, i)

// the stripe a key's hash `x` goes to
fn stripe(by: By, x: Int) -> Int =
  match by
    Key(n) => ((x % n) + n) % n
    Worker => Async.worker()

// two stripes' results of the call `c`, folded by `merge`; a `()` is
// folded by any
fn folded<D, R, E>(merge: Fold<D>, c: Call<D, R, E>, a: R, b: R) -> R =
  match merge
    Sum => c.sum(a, b)
    Max => c.max(a, b)
    Min => c.min(a, b)
    Concat => c.concat(a, b)
    Custom(m) => c.fold(m, a, b)
    Unmerged => a

// ---- actors (foundations.md, decision 18; language.md §11) ----
//
// `actors` keeps one instance of a handler per key, made on demand, in
// the runtime's family, evicting the oldest-used of a sample past
// `max:`. It's plain Ren over the family's dependency, `Instances`, as
// any library can be (compiler.md, "Services stage", "Actors (step 7)").

// a family of actors of `D`, one per key `K`, made on demand: what making
// one can fail with is `D`'s, written on an alias of it, `dep Docs =
// Actors<DocId, Doc> ! StoreDown`
pub dep Actors<K, D> =
  // `body` with `k`'s actor installed, pinned, made first if it isn't
  // live: what making it failed with, if it did. `at`'s step
  enter: fn(k: K, body: fn() uses D) -> Pinned<D>
  // `body` with `k`'s actor installed, pinned, if it's live, without
  // making it or counting as use: whether it was. `each`'s step
  visit: fn(k: K, body: fn() uses D) -> Bool
  // the live keys, in the order their actors were made
  keys: fn() -> Array<K>
  // evicts `k`'s actor now, if it's live and nothing pins it, its
  // `finally` run on this task
  evict: fn(k: K)
  // evicts each actor released at least `d` ago that nothing pins
  evict_idle: fn(d: Duration)
  // the live actors, and those made and evicted since the family began
  count: fn() -> Int
  made: fn() -> Int
  evicted: fn() -> Int
  // puts the call `c` in `k`'s mailbox, making its actor first if it
  // isn't live: what making it failed with, if it did. `post`'s step
  send: fn(k: K, c: Call<D, Unit, !>) -> Pinned<D>
  // `body` with the actors of `ks` held, making those that aren't live:
  // what making one failed with, if one did. `at_all`'s step
  hold: fn(ks: Array<K>, body: fn()) -> Pinned<D>

  // installs `k`'s actor as `D` for `body`, making it if it isn't live:
  // what making it fails with is `at`'s. Each operation in `body` takes
  // the actor for one call; the block keeps it from being evicted
  pub fn at<T>(k: K, body: fn() -> T uses D) -> T ! ..e uses Actors<K, (D ! ..e)> =
    var got = None
    let p: Pinned<(D ! ..e)> = Actors.enter(k, fn() => got = Some(family_kept(body)))
    try Instances.made(p)
    match got
      Some(r) => try r
      None => lib_panic("`at`'s block didn't run")
  // `body` with the actors of `ks` held, each made first if it isn't
  // live: what making one fails with is `at_all`'s. It holds them in the
  // keys' order, each key once, so two `at_all`s over the same keys can't
  // wait on each other, and installs none: inside it, `at` of a key it
  // holds doesn't wait, and names which actor `D` means, and `at` of any
  // other key of the family panics (concurrency.md, "Several keys
  // at once"). `Docs.at_all([from, to]) fn() => ...`
  pub fn at_all<T>(ks: Array<K>, body: fn() -> T) -> T ! ..e uses Actors<K, (D ! ..e)> =
    var got = None
    let p: Pinned<(D ! ..e)> = Actors.hold(ks, fn() => got = Some(family_kept(body)))
    try Instances.made(p)
    match got
      Some(r) => try r
      None => lib_panic("`at_all`'s block didn't run")
  // puts one call of `D` in `k`'s mailbox and returns, Erlang's cast:
  // `Docs.post(k, Doc.Call.Edit { op })`. Its arguments are evaluated
  // now; the call is one that gives `()` and can't fail, run later as
  // one operation of `k`'s actor, after the posts this task made to it
  // before. It makes the actor if it isn't live, so what making it fails
  // with is `post`'s, and it's all a post can fail with; then it waits
  // for room in `k`'s mailbox, and only there
  pub fn post(k: K, c: Call<(D ! ..e), Unit, !>) ! ..e uses Actors<K, (D ! ..e)> =
    let p: Pinned<(D ! ..e)> = Actors.send(k, c)
    try Instances.made(p)
  // `body` with each live actor installed in turn, in the order they were
  // made, pinned while it runs: it makes none, and isn't use
  pub fn each(body: fn() uses D) ! ..e uses Actors<K, D> =
    for k in Actors.keys()
      var got = Ok(())
      let _ = Actors.visit(k, fn() => got = family_kept(body))
      try got

// which actor `actors` evicts when the family is full: under `Lru`, the
// oldest-used of a sample of 5, which is sampled LRU (`Lfu` later)
pub type Evict = | Lru

// the actors of `h`, a handler whose one parameter is the key: at most
// `max` live, one that nothing pins and that has no mail evicted to make
// room past it, the oldest-used of 5 such that `Random` samples. Each
// key's mailbox holds at most `mailbox` posts, which a post waits for
// room in. `chaos: true`, a test's, evicts at each call into the family
// the evictable actors `Random` picks
pub handler actors<K, D>(h: spawned fn(k: K) -> D, max: Int = 10000, mailbox: Int = 64, evict: Evict = Lru, chaos: Bool = false) for Actors<K, D> uses Random =
  // the maker written here, so the instances are made with what's
  // installed where `actors` is
  let fam = Instances.open(fn(k: K) => h(k), at_least_one(max), mailbox)
  // chaos at each call into the family: its own operations below, and
  // each operation called through `at`'s block, at the family's edge
  let _ = if chaos then Instances.at_edge(fam, fn() => shake(fam, chaos))
  finally(r) =>
    Instances.close(fam)
    try r
  enter(k, body) =>
    shake(fam, chaos)
    Instances.enter(fam, k, fn(evictable: Array<Stamped<K>>) => victim(evict, evictable), body)
  visit(k, body) =>
    shake(fam, chaos)
    Instances.visit(fam, k, body)
  keys() =>
    shake(fam, chaos)
    Instances.keys(fam)
  evict(k) =>
    shake(fam, chaos)
    let _ = Instances.evict(fam, k)
    ()
  evict_idle(d) =>
    shake(fam, chaos)
    for k in Instances.idle(fam, d)
      let _ = Instances.evict(fam, k)
      ()
  count() => Instances.counts(fam).live
  made() => Instances.counts(fam).made
  evicted() => Instances.counts(fam).evicted
  send(k, c) =>
    shake(fam, chaos)
    Instances.post(fam, k, c, fn(evictable: Array<Stamped<K>>) => victim(evict, evictable))
  hold(ks, body) =>
    shake(fam, chaos)
    Instances.hold(fam, ks, fn(evictable: Array<Stamped<K>>) => victim(evict, evictable), body)

// `max`, which `actors` checks keeps at least 1 actor
fn at_least_one(max: Int) -> Int =
  if max < 1 then lib_panic("`actors` keeps at least 1 actor, not " + show(max))
  max

// the actor to evict: under `Lru`, sampled (experiments/runtime-p2/
// SYNTHESIS.md, K1b), the oldest-used of 5 evictable actors `Random`
// picks, within half a point of exact LRU's hit rate in K1b's traces
fn victim<K>(evict: Evict, evictable: Array<Stamped<K>>) -> Option<K> uses Random =
  match evict
    Lru => oldest(sample(evictable, 5))

// `n` of `xs`, each at most once, that `Random` picks: the first `n` of
// a shuffle, Fisher and Yates'. All of them, drawing nothing, if there
// are `n` or fewer
fn sample<T>(xs: Array<T>, n: Int) -> Array<T> uses Random =
  if xs.len() <= n then xs
  else
    var ys = xs
    for i in 0..n
      let j = i + Random.int(ys.len() - i)
      let y = ys[i]
      ys[i] = ys[j]
      ys[j] = y
    ys[0..n]

// the key of the one of `xs` used longest ago, its stamp the smallest
fn oldest<K>(xs: Array<Stamped<K>>) -> Option<K> =
  var best: Option<Stamped<K>> = None
  for x in xs
    best = match best
      Some(b) if b.used <= x.used => Some(b)
      _ => Some(x)
  match best
    Some(b) => Some(b.key)
    None => None

// under `chaos: true`, evicts each evictable actor `Random` picks, so a
// test finds what lives only in memory (foundations.md, decision 18,
// "`sim` is faithful to the policy")
fn shake<K, D>(fam: Family<K, D>, chaos: Bool) uses Random =
  if chaos then
    for k in Instances.evictable(fam)
      if Random.int(2) == 0 then
        let _ = Instances.evict(fam, k)
        ()

// ---- trying again (handlers.md, "Functions that run a block") ----

// runs `body`, and again while it fails with one of `on`'s errors, up
// to `n` tries in all: any other error leaves at once, after the last
// try its error leaves, and `body` runs at least once
pub fn retry<T>(n: Int, on: Tags, body: fn() -> T) -> T =
  try match body()
    fail on if n > 1 => try retry(n - 1, on: on, body)
    v => v

// ---- what a test gets (deps.md, "Tests") ----
//
// Each test runs with a fresh instance of each of these handlers, unless
// its `uses` asks for the real dependency instead.

pub dep TestClock =
  // move the test clock on, by `d`
  advance: fn(d: Duration)

// a clock that stands still at `at` until it's moved on: by
// `TestClock.advance`, or by sleeping, which takes no time at all
pub handler test_clock(at: Time) for Clock, TestClock =
  var time = at
  var since = Instant.zero
  now() => time
  instant() => since
  sleep(d) =>
    time = time + d
    since = since + d
  advance(d) =>
    time = time + d
    since = since + d

pub dep TestRandom =
  // the seed the test's numbers come from, which `ren test --seed`
  // sets
  seed: fn() -> Int

// numbers that are the same on every run with the same seed
pub handler test_random(seed: Int) for Random, TestRandom =
  var state = seed
  int(below) =>
    // a spawned task draws from a stream of its own, from the seed and
    // its path, so what it draws doesn't depend on the order tasks ran in
    match task_random(seed, below)
      Some(n) => n
      None =>
        state = seeded_next(state)
        seeded_int(state, below)
  seed() => seed

pub dep TestConsole =
  // every line written to `Console` so far, the first first
  output: fn() -> Array<Str>
  // every line given to `Console.error` so far, the first first
  errors: fn() -> Array<Str>

// a console that keeps what's written to it
pub handler test_console() for Console, TestConsole =
  var lines: Array<Str> = []
  var errors: Array<Str> = []
  write(line) => &lines.push(line)
  error(line) => &errors.push(line)
  output() => lines
  errors() => errors

// files kept in memory, starting with `files`. A test gets an empty one,
// and reads back what it wrote through `Fs` itself.
pub handler mem_fs(files: Array<File>) for Fs =
  var kept: Map<Path, Bytes> = Map.of(files.map(fn(f) => (f.path, f.data)))
  read(p) => kept.get(p) orelse fail NoSuchFile(p)
  write(p, b) => &kept.set(p, b)
  exists(p) => kept.includes(p)

// a system whose program was given `args`
pub handler test_os(args: Array<Str>) for Os =
  args() => args

// a program that was run: its name, and what it was given
pub type Command = { cmd: Str, args: Array<Str> }

// what a test `Proc` says `command` exits with
pub type Exit = { command: Command, code: Int }

pub dep TestProc =
  // every program run so far, the first first
  ran: fn() -> Array<Command>

// programs that don't run, but are kept: each exits with the code its
// `Exit` in `exits` gives, or 0 if none does
pub handler test_proc(exits: Array<Exit>) for Proc, TestProc =
  var commands: Array<Command> = []
  run(cmd, args, _) =>
    let c = Command { cmd: cmd, args: args }
    &commands.push(c)
    var code = 0
    for e in exits
      if e.command == c then code = e.code
    code
  ran() => commands

// ---- the journal (handlers.md, "The journal") ----
//
// `ren run --record` puts a recorder over each built-in dependency `main`
// uses, and `ren replay` puts `replaying` in place of them all; a test
// installs one with `replay(file)`, and the console keeps its session
// with recorders too. What a journal holds, and how it's written, is the
// runtime's (journal.ml): a Ren program holds one only as its number.

// a journal the runtime has open
type Journal = opaque Int

// The recorder, over any built-in dependency: each operation gives back
// what a line the console kept was given, if it's one of those, or else
// calls the one under it, and writes down what it gave, with the task
// that called it; a call its task waits in is written in two lines. The
// runtime installs it over each one `main` uses.
handler recorder(j: Journal) over any =
  call =>
    let r = journal_kept(j, call.name, call.args) orelse journal_gave(j, call.name, call.args, attempt call.forward())
    try r

// In place of every built-in dependency: each operation gives back what
// the recording says it gave. When the `with` that installed it ends, a
// test's outputs are compared with the recording's.
handler replaying(j: Journal) for Clock, Random, Console, Fs, Os, Proc, Net =
  finally(r) =>
    journal_outputs(j)
    try r
  now() => journal_answer(j, "Clock.now", ())
  instant() => journal_answer(j, "Clock.instant", ())
  sleep(d) => journal_answer(j, "Clock.sleep", d)
  int(below) => journal_answer(j, "Random.int", below)
  Console.write(line) => journal_answer(j, "Console.write", line)
  error(line) => journal_answer(j, "Console.error", line)
  Fs.read(p) =>
    let r: Result<Bytes, ! FsError> = journal_answer(j, "Fs.read", p)
    try r
  Fs.write(p, b) =>
    let r: Result<Unit, ! FsError> = journal_answer(j, "Fs.write", (p, b))
    try r
  exists(p) => journal_answer(j, "Fs.exists", p)
  args() => journal_answer(j, "Os.args", ())
  run(cmd, args, kill) =>
    let r: Result<Int, ! ProcError> = journal_answer(j, "Proc.run", (cmd, args, kill))
    try r
  listen(addr) =>
    let r: Result<Listener, ! NetError> = journal_answer(j, "Net.listen", addr)
    try r
  accept(l) =>
    let r: Result<Conn, ! NetError> = journal_answer(j, "Net.accept", l)
    try r
  accept_until(l, stop) =>
    let r: Result<Option<Conn>, ! NetError> = journal_answer(j, "Net.accept_until", (l, stop))
    let c = try r
    // the recording's connections in flight had the cleanup deadline
    // from here, as the real `Net`'s do
    if not c.is_some() then task_drain()
    c
  Net.read(c, max) =>
    let r: Result<Bytes, ! NetError> = journal_answer(j, "Net.read", (c, max))
    try r
  Net.write(c, b) =>
    let r: Result<Unit, ! NetError> = journal_answer(j, "Net.write", (c, b))
    try r
  close(c) => journal_answer(j, "Net.close", c)

// A recorded run, `ren run --record tests/run.journal main.ren`, as each
// built-in dependency it holds calls for, for a test (testing.md, "The
// journal is a test"): what the program reads is answered from it, in
// order for each dependency, and what it writes is compared with it when
// the `with` ends, a difference failing the test with a diff. `file` is
// found from the folder of the file the test is in. Its type lists all
// seven; the checker narrows it to those the journal's header names
// (infer_handlers.ml, `replayed`), so the others stay the test's.
pub test fn replay(file: Str) -> Clock & Console & Fs & Net & Os & Proc & Random =
  replaying(journal_load(file))
|}

(* ---- built-in functions ---- *)

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
let scheme_of ?(reqs = []) ty : Ty.scheme =
  let tparams = List.mapi (fun n _ -> Some n) (Ty.own_args ty).tys in
  Ty.canonical { ty; names = []; reqs; row_reqs = []; tparams; modes = []; defaults = [] }

let open_row n : Ty.row = { labels = []; tail = Some n }
let bytes = Ty.Con (Path.prelude "Bytes", [])
let map k v = Ty.Con (Path.prelude "Map", [ k; v ])
let set t = Ty.Con (Path.prelude "Set", [ t ])
let journal = Ty.Con (Path.prelude "Journal", [])
let net_outcome t = Ty.Con (Path.prelude "NetOutcome", [ t ])
let family k d = Ty.Con (Path.prelude "Family", [ k; d ])

(* A library's [victim], `spawned fn(evictable: Array<Stamped<K>>) ->
   Option<K>`, the key [k]'s: it can't fail, and uses what it captured,
   as a `spawned fn` does, so its row is its own, [Some 2]. *)
let victim k =
  Ty.Fun
    ( [ { mode = Read; ty = Ty.Con (Path.prelude "Array", [ Ty.Con (Path.prelude "Stamped", [ k ]) ]) } ],
      Ty.Con (Path.prelude "Option", [ k ]),
      Ty.closed,
      open_row 2 )

(* A call of [d] giving [r], `Call<D, R, E>`, as `Call`'s members take
   it: they don't fail with what it fails with, so its error set is only
   a type variable to them, [Var 2], as the source's `self` writes it. *)
let call d r = Ty.Con (Ty.generic_call, [ d; r; Var 2 ])

(* Each built-in function's type scheme, by its id. Each parameter's mode
   ([inout] or not) is part of the type. A built-in type's method has its
   receiver, `self`, first, and the type's parameters are its scheme's
   first variables, as in any member's (iface.ml). *)
let scheme (x : Intrinsic.t) =
  let open Ty in
  (* most fail with nothing and use nothing: open rows, which any row
     fits *)
  let fn ?reqs params ret =
    scheme_of ?reqs (Fun (params, ret, open_row 0, open_row 1))
  in
  let inout ty = { mode = Inout; ty } in
  (* `split_at` on [self], giving the block's [r]: what the block fails
     with and uses, the call does *)
  let split_at self r =
    let body = Fun ([ inout self; inout self ], r, open_row 0, open_row 1) in
    scheme_of (Fun ([ inout self; read int; read body ], r, open_row 0, open_row 1))
  in
  (* a key, or a member of a set, is found by its hash, with the `==` it
     agrees with: what `hash` of [Var 0] is *)
  let hashed = [ (0, "hash") ] in
  let k = Var 0 and v = Var 1 in
  match x with
  (* fn<T>(T) -> Str, which the interpreter runs itself, since it shows a
     value through its type (eval.ml) *)
  | Show -> fn [ read (Var 0) ] str
  (* fn() -> Int, the real `Clock.now` and `Clock.instant` *)
  | Clock_now | Clock_instant -> fn [] int
  (* fn(Int) *)
  | Clock_sleep -> fn [ read int ] unit
  (* fn(Int) -> Int *)
  | Random_int -> fn [ read int ] int
  (* fn(Int) -> Int: the state after [state] of the test `Random` *)
  | Seeded_next -> fn [ read int ] int
  (* fn(Int, Int) -> Int: a number from 0 below [below], from that state *)
  | Seeded_int -> fn [ read int; read int ] int
  (* fn(Str) *)
  | Console_write -> fn [ read str ] unit
  (* fn(Str), the real `Console.error`: stderr *)
  | Console_error -> fn [ read str ] unit
  (* fn(Str) -> FsOutcome<Bytes>, the real `Fs.read` *)
  | Fs_read -> fn [ read str ] (Con (Path.prelude "FsOutcome", [ bytes ]))
  (* fn(Str, Bytes) -> FsOutcome<Unit>, the real `Fs.write` *)
  | Fs_write ->
      fn [ read str; read bytes ] (Con (Path.prelude "FsOutcome", [ unit ]))
  (* fn(Str) -> Bool *)
  | Fs_exists -> fn [ read str ] bool
  (* fn() -> Array<Str> *)
  | Os_args -> fn [] (array str)
  (* fn(Str, Array<Str>, Kill) -> ProcOutcome, the real `Proc.run` *)
  | Proc_run ->
      fn
        [ read str; read (array str); read (Con (Path.prelude "Kill", [])) ]
        (Con (Path.prelude "ProcOutcome", []))
  (* The real `Net`'s, each giving a [NetOutcome] of what it gives, a
     listener and a connection as their numbers. fn(host: Str, port: Int)
     -> NetOutcome<Int> *)
  | Net_listen -> fn [ read str; read int ] (net_outcome int)
  (* fn(l: Int) -> NetOutcome<Int> *)
  | Net_accept -> fn [ read int ] (net_outcome int)
  (* fn(l: Int, stop: Int) -> NetOutcome<Option<Int>> *)
  | Net_accept_until -> fn [ read int; read int ] (net_outcome (option int))
  (* fn(c: Int, max: Int) -> NetOutcome<Bytes> *)
  | Net_read -> fn [ read int; read int ] (net_outcome bytes)
  (* fn(c: Int, b: Bytes) -> NetOutcome<Unit> *)
  | Net_write -> fn [ read int; read bytes ] (net_outcome unit)
  (* fn(c: Int) *)
  | Net_close -> fn [ read int ] unit
  (* The journal's (handlers.md, "The journal"; journal.ml): each is given
     the call it's for, `Fs.read`, its arguments, [A], one value, a
     tuple of several or `()` for none, and what it gives back, [R]: the
     operation's value, or a [Result] of it if it can fail. Each writes
     or reads them through their types, which it's given as descriptors,
     as `show` is. *)
  (* fn<A, R>(j: Journal, call: Str, args: A) -> Option<R>: what a line
     the console kept was given, if this call is one of its, which isn't
     asked again; recording, the call has begun, and is written once its
     task waits in it, or once it's given back *)
  | Journal_kept -> fn [ read journal; read str; read (Var 0) ] (option (Var 1))
  (* fn<A, R>(j: Journal, call: Str, args: A, result: R) -> R: writes the
     call down, with what it gave, and gives that back *)
  | Journal_gave ->
      fn [ read journal; read str; read (Var 0); read (Var 1) ] (Var 1)
  (* fn<A, R>(j: Journal, call: Str, args: A) -> R: what the recording
     says this call gave *)
  | Journal_answer -> fn [ read journal; read str; read (Var 0) ] (Var 1)
  (* fn(j: Journal): in a test, the outputs compared with the
     recording's, once the body of the `with` has run *)
  | Journal_outputs -> fn [ read journal ] unit
  (* fn(file: Str) -> Journal: the journal in [file], read for a test *)
  | Journal_load -> fn [ read str ] journal
  (* fn<T>(self: Array<T>) -> Int *)
  | Array_len -> fn [ read (array (Var 0)) ] int
  (* fn<T>(inout self: Array<T>, x: T) *)
  | Array_push -> fn [ { mode = Inout; ty = array (Var 0) }; read (Var 0) ] unit
  (* fn<T>(self: Array<T>) -> Array<T>, by `T`'s order, equal ones in the
     order they were *)
  | Array_sort ->
      fn ~reqs:[ (0, "ord") ] [ read (array (Var 0)) ] (array (Var 0))
  (* The prelude's own, which `map` is written with (prelude.ml's
     [caller], [Internal]). *)
  (* fn<T>(n: Int) -> Array<T>: an empty array with room for [n] *)
  | Array_reserve -> fn [ read int ] (array (Var 0))
  (* fn<T, U>(xs: Array<T>) -> MapInto<U>: whether `xs.map` can replace
     each element where it is, giving [xs] back as the new array: nothing
     else holds [xs], and a [U] is kept in an array as a [T] is (Lean's
     `Array.mapMUnsafe`, Init/Data/Array/Basic.lean:766) *)
  | Map_into ->
      fn [ read (array (Var 0)) ] (Con (Path.prelude "MapInto", [ Var 1 ]))
  (* fn<A, B>(x: A) -> B: [x], said to be a [B]. Only `map` calls it, on
     an element of an array [map_into] said keeps a [B] as it keeps an
     [A], and on that array: Lean's `unsafeCast` *)
  | Unsafe_cast -> fn [ read (Var 0) ] (Var 1)
  (* fn<T>(xs: Array<T>) -> Bool: whether `T` is `Float`, whose `sum`
     adds in lanes (foundations.md, decision 15) *)
  | Float_lanes -> fn [ read (array (Var 0)) ] bool
  (* fn<T>(xs: Array<T>) -> T: [xs], whose `T` [float_lanes] said is
     `Float`, added up in eight lanes, element i into lane i % 8, each
     from 0.0, and the lanes added pairwise: ((0 + 1) + (2 + 3)) + ((4 +
     5) + (6 + 7)). The same on every machine, and what a vector unit
     does (nan.ml says which NaN it carries) *)
  | Float_sum -> fn [ read (array (Var 0)) ] (Var 0)
  (* A `Map` and a `Set` keep insertion order (operators.md, "`Map` and
     `Set`"), and find a key by its `hash`. *)
  (* fn<K, V>() -> Map<K, V>, which `Map.empty` is *)
  | Map_empty -> fn [] (map k v)
  (* fn<K, V>(pairs: Array<(K, V)>) -> Map<K, V>: a key given twice has
     the last value, in the first one's place *)
  | Map_of -> fn ~reqs:hashed [ read (array (tuple [ k; v ])) ] (map k v)
  (* fn<K, V>(self: Map<K, V>, k: K) -> Option<V> *)
  | Map_get -> fn ~reqs:hashed [ read (map k v); read k ] (option v)
  (* fn<K, V>(inout self: Map<K, V>, k: K, v: V): a key already there
     keeps its place *)
  | Map_set -> fn ~reqs:hashed [ inout (map k v); read k; read v ] unit
  (* fn<K, V>(inout self: Map<K, V>, k: K), which may not be there *)
  | Map_remove -> fn ~reqs:hashed [ inout (map k v); read k ] unit
  (* fn<K, V>(self: Map<K, V>, k: K) -> Bool *)
  | Map_includes -> fn ~reqs:hashed [ read (map k v); read k ] bool
  (* fn<K, V>(self: Map<K, V>) -> Array<K>, and its values, in order *)
  | Map_keys -> fn [ read (map k v) ] (array k)
  | Map_values -> fn [ read (map k v) ] (array v)
  (* fn<K, V>(self: Map<K, V>) -> Int *)
  | Map_len -> fn [ read (map k v) ] int
  (* fn<T>() -> Set<T>, which `Set.empty` is *)
  | Set_empty -> fn [] (set k)
  (* fn<T>(xs: Array<T>) -> Set<T>, each once, in the first one's place *)
  | Set_of -> fn ~reqs:hashed [ read (array k) ] (set k)
  (* fn<T>(inout self: Set<T>, x: T), and taken out, which may not be
     there *)
  | Set_add | Set_remove -> fn ~reqs:hashed [ inout (set k); read k ] unit
  (* fn<T>(self: Set<T>, x: T) -> Bool *)
  | Set_includes -> fn ~reqs:hashed [ read (set k); read k ] bool
  (* fn<T>(self: Set<T>) -> Int *)
  | Set_len -> fn [ read (set k) ] int
  (* A `Str` is UTF-8, always, and `Bytes` are any bytes at all
     (builtins.ml, "strings and bytes"). *)
  (* fn(self: Str) -> Int, in bytes: a `Str` has no `len`, since a
     reader can't tell bytes from characters (strings.md, "Length and
     indexing") *)
  | Str_byte_len -> fn [ read str ] int
  (* fn(self: Str, s: Str) -> Option<Int>: where [s] first starts *)
  | Str_index ->
      fn [ read str; read str ] (Con (Path.prelude "Option", [ int ]))
  (* fn(self: Str, sep: Str) -> Array<Str>: the parts between each [sep] *)
  | Str_split -> fn [ read str; read str ] (array str)
  (* fn(self: Str) -> Str, without the spaces, tabs and newlines at
     either end *)
  | Str_trim -> fn [ read str ] str
  (* fn(self: Str, prefix: Str) -> Bool *)
  | Str_starts_with -> fn [ read str; read str ] bool
  (* fn(self: Str, s: Str) -> Str: this, then [s], which `+` is, and
     `+=` (strings.md, "Building strings"); and the same for `Bytes` *)
  | Str_add -> fn [ read str; read str ] str
  | Bytes_add -> fn [ read bytes; read bytes ] bytes
  (* fn(self: Str, i: Int) -> Int: the last character boundary at or
     before [i], and the first at or after it, panicking if [i] isn't 0
     to the length (strings.md, "Cutting a character") *)
  | Str_char_floor | Str_char_ceil -> fn [ read str; read int ] int
  (* fn(self: Str) -> Int: the code point of a string of one, panicking
     on any other (strings.md, "Characters") *)
  | Str_code -> fn [ read str ] int
  (* fn(n: Int) -> Str: the string of the one code point [n], panicking
     if it isn't a Unicode scalar value *)
  | Str_of_code -> fn [ read int ] str
  (* fn(self: Array<Str>, sep: Str) -> Str: the strings, with [sep]
     between each two *)
  | Array_join -> fn [ read (array str); read str ] str
  (* fn(self: Str) -> Bytes: its UTF-8 *)
  | Str_bytes -> fn [ read str ] bytes
  (* the rest of strings.md's table (compiler.md, "Bytes stage, part two",
     step 5), `Bytes` with `Str`'s names. fn(self: Str, suffix: Str) ->
     Bool *)
  | Str_ends_with -> fn [ read str; read str ] bool
  (* fn(self: Str) -> Str: `a` to `z` made `A` to `Z`, and nothing else *)
  | Str_ascii_upper -> fn [ read str ] str
  | Bytes_ascii_upper -> fn [ read bytes ] bytes
  (* fn(self: Str, at: Int) -> (Int, Int): the line and column [at] is
     at, from 1, the column in code points, panicking if [at] isn't 0 to
     the length or is inside a character *)
  | Str_line_col ->
      fn [ read str; read int ] (Ty.tuple [ int; int ])
  (* `Str`'s, of `Bytes` *)
  | Bytes_index ->
      fn [ read bytes; read bytes ] (Con (Path.prelude "Option", [ int ]))
  | Bytes_starts_with | Bytes_ends_with -> fn [ read bytes; read bytes ] bool
  | Bytes_split -> fn [ read bytes; read bytes ] (array bytes)
  | Bytes_trim -> fn [ read bytes ] bytes
  (* fn(b: Bytes) -> Str ! InvalidUtf8(at: Int, incomplete: Bool): where
     the first byte that isn't part of a character is, and whether the
     end cut that character off *)
  | Str_from_utf8 ->
      scheme_of
        (Fun
           ( [ read bytes ],
             str,
             { labels = [ { name = "InvalidUtf8"; payload = [ int; bool ] } ]; tail = None },
             open_row 0 ))
  (* fn(b: Bytes) -> Str: U+FFFD for each maximal invalid subpart *)
  | Str_from_utf8_lossy -> fn [ read bytes ] str
  (* fn(self: Bytes) -> Int *)
  | Bytes_len -> fn [ read bytes ] int
  (* fn(self: Bytes, i: Int) -> Int: byte [i], 0 to 255 *)
  | Bytes_at -> fn [ read bytes; read int ] int
  (* fn(xs: Array<Int>) -> Bytes, each 0 to 255 *)
  | Bytes_of -> fn [ read (array int) ] bytes
  (* layer 3 of formats.md (compiler.md, "Bytes stage", "Layer 3: the
     API"): fn(self: Bytes, at: Int) -> Int, the number at [at] of the
     width and order its name says, panicking out of range *)
  | Bytes_read _ -> fn [ read bytes; read int ] int
  (* fn(inout self: Bytes, at: Int, x: Int): [x] written there, panicking
     out of range or if it doesn't fit *)
  | Bytes_write _ -> fn [ inout bytes; read int; read int ] unit
  (* fn(n: Int) -> Bytes: [n] zero bytes *)
  | Bytes_zeros -> fn [ read int ] bytes
  (* fn(inout self: Bytes, at: Int, x: Int) -> Int: [x] written as a
     `VarInt` or a `VarUInt` at [at], how many bytes that took *)
  | Bytes_set_var _ -> fn [ inout bytes; read int; read int ] int
  (* fn(x: Int) -> Int: how many bytes that would take *)
  | Bytes_var_size _ -> fn [ read int ] int
  (* fn(self) -> Self: a value equal to [self] that holds its own buffer,
     not a slice of another's (foundations.md, decision 17); [self] itself
     if it already does *)
  | Array_copy -> fn [ read (array (Var 0)) ] (array (Var 0))
  | Str_copy -> fn [ read str ] str
  | Bytes_copy -> fn [ read bytes ] bytes
  (* fn<R>(inout self, n: Int, body: fn(&Self, &Self) -> R) -> R: [body]
     given `self[0..n]` and `self[n..len]`, each a place of its own,
     after which [self] is the first followed by the second, if it
     returns or fails (compiler.md, "Blocks with `inout` parameters, and
     slices"). Whatever [body] fails with and uses, so does the call.
     Lowering writes it out (lower.ml, [split_at]) *)
  | Array_split_at -> split_at (array (Var 0)) (Var 1)
  | Str_split_at -> split_at str (Var 0)
  | Bytes_split_at -> split_at bytes (Var 0)
  (* fn(self: Int, n: Int) -> Int: wrapping arithmetic at 64 bits,
     instead of panicking (operators.md, "`Int` and `Float`") *)
  | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul ->
      fn [ read int; read int ] int
  (* fn(self: Int) -> Int *)
  | Int_wrapping_neg -> fn [ read int ] int
  (* fn(self: Int, n: Int) -> Int: the bits of the two's complement of
     each, combined, for hashes and checksums (operators.md, "Sized
     integers") *)
  | Int_xor | Int_bit_and | Int_bit_or -> fn [ read int; read int ] int
  (* fn(self: Int, k: Int) -> Int: shifted left, losing the bits shifted
     out, or right, keeping the sign; `k` outside 0 to 63 panics
     (operators.md, "Bits") *)
  | Int_shl | Int_shr -> fn [ read int; read int ] int
  (* fn(self: Int, b: Int) -> Int: the operators, as methods, `n.add(2)`
     is `n + 2` (operators.md, "Operators are methods"); and `-n` *)
  | Int_add | Int_sub | Int_mul | Int_div | Int_rem ->
      fn [ read int; read int ] int
  | Int_neg -> fn [ read int ] int
  (* the same, for a `Float` *)
  | Float_add | Float_sub | Float_mul | Float_div | Float_rem ->
      fn [ read float; read float ] float
  | Float_neg -> fn [ read float ] float
  (* fn(n: Int) -> Float: numbers never convert by themselves *)
  | Float_of -> fn [ read int ] float
  (* fn(self: Float) -> Int: the nearest, half away from zero; and
     toward zero *)
  | Float_round | Float_truncate -> fn [ read float ] int
  (* fn(self: Float) -> Float *)
  | Float_sqrt -> fn [ read float ] float
  (* fn(self: Str) -> Str, with `A` to `Z` made `a` to `z`, and nothing
     else: ASCII only, so the same in every release (strings.md, "The
     `unicode` module"); and the same for `Bytes` *)
  | Str_ascii_lower -> fn [ read str ] str
  | Bytes_ascii_lower -> fn [ read bytes ] bytes
  (* fn<T has hash>(self: T) -> Int: `x.hash()`, the derived hash, with no
     seed, so the same on every run and in every build (walk.ml,
     [fixed_hash]) *)
  | Hash -> fn ~reqs:hashed [ read (Var 0) ] int
  (* fn<T>(items: fn() -> Option<T>) -> Int, and fn<T>(items: fn() ->
     Option<T>, f: fn(T) -> Bool) -> Int: how many items [items] gives,
     and how many of them [f] is true of, failing with and using what
     they do: a cursor's `c.count()` and `c.count(f)`, [items] the cursor
     pulled (Infer_expr.cursor_count), which lowering writes out as a loop
     (lower.ml, [pulled_count]) *)
  | Pulled_count ->
      scheme_of
        (Fun
           ( [ read (Fun ([], Con (Path.prelude "Option", [ Var 0 ]), open_row 0, open_row 1)) ],
             int,
             open_row 0,
             open_row 1 ))
  | Pulled_count_by ->
      scheme_of
        (Fun
           ( [
               read (Fun ([], Con (Path.prelude "Option", [ Var 0 ]), open_row 0, open_row 1));
               read (Fun ([ read (Var 0) ], bool, open_row 0, open_row 1));
             ],
             int,
             open_row 0,
             open_row 1 ))
  (* fn<T>(what: Str) -> T: a panic, saying [what]: how a library's
     handlers refuse what they can't go on from, a send on a closed
     channel (std_lib.ml) *)
  | Lib_panic -> fn [ read str ] (Var 0)
  (* the scheduler's (sched.ml), what `Async.scope`, `Scope` and `Task`'s
     members are written over (compiler.md, "Stage 11a", "Structured
     tasks"). fn<T>(max: Int, body: fn(Scope) -> T) -> T: [body], with a
     new scope, once its tasks have all ended; what [body] fails with and
     uses, the call does *)
  | Scope_run ->
      let scope = Con (Path.prelude "Scope", []) in
      fn
        [ read int; read (Fun ([ read scope ], Var 0, open_row 0, open_row 1)) ]
        (Var 0)
  (* fn(s: Scope, body: fn()): starts [body] as a task of [s] *)
  | Task_spawn ->
      let scope = Con (Path.prelude "Scope", []) in
      fn [ read scope; read (Fun ([], unit, open_row 2, open_row 3)) ] unit
  (* fn(cond: fn() -> Bool): waits until the instance whose operation
     it's in is released with [cond] holding; the caller has checked it
     doesn't hold now (compiler.md, "The rest of `Async`") *)
  | Task_until -> fn [ read (Fun ([], bool, open_row 2, open_row 3)) ] unit
  (* fn(): the arm running lets go of its instance, for the one call a
     `release` covers, and takes it back after, queueing like any caller
     (compiler.md, "Services stage", step 4). Lower writes them around
     the call; neither waits for `Async`, as an operation's call of a
     shared instance doesn't: a task switches at one only when another
     task can reach the instance *)
  | Arm_release | Arm_retake -> fn [] unit
  (* fn<T>(ms: Int, body: fn() -> T) -> Option<T>: [body], under a
     deadline [ms] from now or the one it's under, if that's sooner;
     [None] if the deadline cancelled it. What [body] fails with and
     uses, the call does *)
  | Task_timeout ->
      fn [ read int; read (Fun ([], Var 0, open_row 0, open_row 1)) ] (option (Var 0))
  (* fn<T>(body: fn() -> T) -> Isolated<T>: [body], or the message of a
     panic in it that's made a value *)
  | Task_isolate ->
      fn
        [ read (Fun ([], Var 0, open_row 0, open_row 1)) ]
        (Con (Path.prelude "Isolated", [ Var 0 ]))
  (* fn<T, U>(xs: fn() -> Option<T>, max: Int, f: fn(T) -> U) -> Array<U>:
     [f] of each item [xs] gives as a task, [max] at once, each pulled
     only when there's room for it, the results in order; and the same,
     giving nothing. The first failure, of [xs] or a task, is the call's *)
  | Task_map ->
      fn
        [
          read (Fun ([], option (Var 0), open_row 0, open_row 1));
          read int;
          read (Fun ([ read (Var 0) ], Var 1, open_row 0, open_row 1));
        ]
        (array (Var 1))
  | Task_each ->
      fn
        [
          read (Fun ([], option (Var 0), open_row 0, open_row 1));
          read int;
          read (Fun ([ read (Var 0) ], unit, open_row 0, open_row 1));
        ]
        unit
  (* fn<A, B>(a: fn() -> A, b: fn() -> B) -> (A, B): both as tasks *)
  | Task_both ->
      fn
        [
          read (Fun ([], Var 0, open_row 0, open_row 1));
          read (Fun ([], Var 1, open_row 0, open_row 1));
        ]
        (tuple [ Var 0; Var 1 ])
  (* fn<T>(a: fn() -> T, b: fn() -> T) -> T: both as tasks, the first to
     return the result, the other cancelled; neither can fail *)
  | Task_race ->
      fn
        [
          read (Fun ([], Var 0, open_row 2, open_row 3));
          read (Fun ([], Var 0, open_row 2, open_row 3));
        ]
        (Var 0)
  (* fn<T>(task: fn(), body: fn() -> T) -> T: [body], with [task] a task
     of a scope of its own beside it, cancelled and waited for once
     [body] ends; a failure of [task] cancels [body] and is the call's.
     What either fails with and uses, the call does (compiler.md,
     "Services stage", "Background work") *)
  | Task_beside ->
      fn
        [
          read (Fun ([], unit, open_row 0, open_row 1));
          read (Fun ([], Var 0, open_row 0, open_row 1));
        ]
        (Var 0)
  (* fn<T>(body: fn(bg: Background<! E>) -> T) -> T ! E: the same, the
     tasks [body] spawns with `bg.spawn` beside it. What they fail with is
     the [Background]'s type argument, so [body]'s errors, and the call's *)
  | Task_background ->
      let bg = Con (Path.prelude "Background", [ Errors (open_row 0) ]) in
      fn [ read (Fun ([ read bg ], Var 0, open_row 0, open_row 1)) ] (Var 0)
  (* fn(self: Background<! E>, body: spawned fn() ! E): [body] as a task of
     the background, which may fail with what the background's type says *)
  | Background_spawn ->
      let bg = Con (Path.prelude "Background", [ Errors (open_row 2) ]) in
      {
        (fn [ read bg; read (Fun ([], unit, open_row 2, open_row 3)) ] unit) with
        modes = [ (1, Spawned) ];
      }
  (* fn<T, R>(cap: Int, f: fn(out: Outbox<T>) ! E, body: fn(i: Inbox<T, !
     E>) -> R) -> R: [body], with [f] a task of a scope of its own beside
     it, sending into a buffer of [cap] that [body] takes from, which
     fails with what [f] fails with once it's empty; [f] is cancelled and
     waited for once [body] ends. What [body] fails with and uses, the call
     does (compiler.md, "Services stage", step 5) *)
  | Task_produce ->
      let outbox = Con (Path.prelude "Outbox", [ Var 0 ]) in
      let inbox = Con (Path.prelude "Inbox", [ Var 0; Errors (open_row 2) ]) in
      fn
        [
          read int;
          read (Fun ([ read outbox ], unit, open_row 2, open_row 3));
          read (Fun ([ read inbox ], Var 1, open_row 0, open_row 1));
        ]
        (Var 1)
  (* fn<T, U, R>(src: fn() -> Option<T> ! E, max: Int, f: fn(T) -> U ! E,
     body: fn(i: Inbox<U, ! E>) -> R) -> R: [body], given [f] of each item
     of [src] as it's taken, in [src]'s order, [max] tasks at once, [src]
     pulled as one's taken; the inbox fails with what either fails with *)
  | Task_map_pull ->
      let inbox = Con (Path.prelude "Inbox", [ Var 1; Errors (open_row 2) ]) in
      fn
        [
          read (Fun ([], option (Var 0), open_row 2, open_row 3));
          read int;
          read (Fun ([ read (Var 0) ], Var 1, open_row 2, open_row 3));
          read (Fun ([ read inbox ], Var 2, open_row 0, open_row 1));
        ]
        (Var 2)
  (* fn<T>(out: Outbox<T>, x: T): [x] into the buffer, waiting while it's
     full *)
  | Outbox_send -> fn [ read (Con (Path.prelude "Outbox", [ Var 0 ])); read (Var 0) ] unit
  (* fn<T>(i: Inbox<T, ! E>) -> Option<T> ! E: the next item, waiting
     while there's none yet; [None] once there are no more, or what the
     producer, or the source or a task of `map_pull`, failed with *)
  | Inbox_take ->
      scheme_of
        (Fun
           ( [ read (Con (Path.prelude "Inbox", [ Var 0; Errors (open_row 0) ])) ],
             option (Var 0),
             open_row 0,
             open_row 1 ))
  (* fn(): `single`'s `yield` and `tick` (sched.ml) *)
  | Async_yield | Async_tick -> fn [] unit
  (* The runtime's policy, which its handler sets for its `with`'s body
     (compiler.md, "Runtimes"). fn() -> Int: `single`'s, from now on,
     giving what [runtime_leave] puts back; fn(seed: Int) -> Int: `sim`'s,
     its tape from [seed], in virtual time from 0 *)
  | Runtime_single -> fn [] int
  | Runtime_sim -> fn [ read int ] int
  (* fn(was: Int): the policy before, which [was] says *)
  | Runtime_leave -> fn [ read int ] unit
  (* `sim.clock()`'s (std_lib.ml). fn() -> Int: the scheduler's time, in
     milliseconds, virtual under `sim` *)
  | Sim_time -> fn [] int
  (* fn(ms: Int): waits until the scheduler's time has moved on by
     [ms]; and moves it on by [ms] at once, waking what it passes *)
  | Sim_sleep | Sim_advance -> fn [ read int ] unit
  (* fn(at: Int): at the scheduler's time [at], in milliseconds, the
     instance whose operation the task is in is released, as if an
     operation of it had ended, so an `Async.until` whose condition reads
     the time is checked again then: how `sim.proc()`'s programs take
     time without keeping the instance meanwhile *)
  | Sim_alarm -> fn [ read int ] unit
  (* fn() -> Int: the worker the calling task runs on, `Async.worker()`:
     0 under `single`; under `sim`, 0 or 1, two virtual workers, a task's
     drawn from the tape the first time it asks (sched.ml) *)
  | Async_worker -> fn [] int
  (* The keyed instance family's (family.ml; compiler.md, "Services
     stage", "The keyed instance family"), which `Instances`' members
     call, and nothing else (Core Lint). fn<K, D>(make: fn(k: K) -> D,
     cap: Int, mailbox: Int) -> Family<K, D>: a family whose instances
     [make] describes, by key, at most [cap] of them live *)
  | Family_open ->
      fn
        [
          read (Fun ([ read (Var 0) ], Var 1, open_row 2, open_row 3));
          read int;
          read int;
        ]
        (family (Var 0) (Var 1))
  (* fn<K, D, R>(f: Family<K, D>, k: K, c: Call<D, R, ! E>) -> R ! E: [c]
     run as one operation of [k]'s instance, which is made first if it
     isn't live *)
  | Family_call ->
      scheme_of
        (Fun
           ( [
               read (family (Var 0) (Var 1));
               read (Var 0);
               read (Con (Ty.generic_call, [ Var 1; Var 2; Errors (open_row 0) ]));
             ],
             Var 2,
             open_row 0,
             open_row 1 ))
  (* fn<K, D>(f: Family<K, D>, k: K): [k]'s instance made now, if it
     isn't live *)
  | Family_make -> fn [ read (family (Var 0) (Var 1)); read (Var 0) ] unit
  (* fn<K, D>(f: Family<K, D>) -> Array<K>: the live keys, in the order
     they were made; and those evictable, in the same order *)
  | Family_keys | Family_evictable -> fn [ read (family (Var 0) (Var 1)) ] (array (Var 0))
  (* fn<K, D>(f: Family<K, D>, k: K) -> Bool: [k]'s instance evicted, its
     `finally` run on this task, if it's live and evictable *)
  | Family_evict -> fn [ read (family (Var 0) (Var 1)); read (Var 0) ] bool
  (* fn<K, D>(f: Family<K, D>) -> InstanceCounts *)
  | Family_counts ->
      fn [ read (family (Var 0) (Var 1)) ] (Con (Path.prelude "InstanceCounts", []))
  (* fn<K, D>(f: Family<K, D>): the family's end: its instances' `finally`s
     run, the last made's first *)
  | Family_close -> fn [ read (family (Var 0) (Var 1)) ] unit
  (* fn<K, D, T>(f: Family<K, (D ! E)>, k: K, victim: spawned
     fn(evictable: Array<Stamped<K>>) -> Option<K>, body: fn() -> T uses
     D) -> T ! E: [body] with [k]'s instance installed as the dependency
     [D] is of, pinned, made first if it isn't live, its setup's errors
     [E]; making it in a full family evicts the key [victim] picks from
     the evictable ones, each with its use stamp, or waits while it picks
     none *)
  | Family_pin ->
      let fails = Ty.Impl { deps = [ { dpath = Ty.param_path; dargs = [ Var 1 ] } ]; over = false; needs = Ty.closed; fails = open_row 0 } in
      let uses_d = { Ty.labels = [ Ty.dep_of { dpath = Ty.param_path; dargs = [ Var 1 ] } ]; tail = None } in
      scheme_of
        (Fun
           ( [
               read (family (Var 0) fails);
               read (Var 0);
               read (victim (Var 0));
               read (Fun ([], Var 2, open_row 0, uses_d));
             ],
             Var 2,
             open_row 0,
             open_row 1 ))
  (* fn<K, D>(f: Family<K, D>, k: K, body: fn() uses D) -> Bool: [body]
     with [k]'s instance installed and pinned, if it's live, without
     making it or counting as use; whether it was *)
  | Family_visit ->
      let uses_d = { Ty.labels = [ Ty.dep_of { dpath = Ty.param_path; dargs = [ Var 1 ] } ]; tail = None } in
      scheme_of
        (Fun
           ( [
               read (family (Var 0) (Var 1));
               read (Var 0);
               read (Fun ([], unit, open_row 0, uses_d));
             ],
             bool,
             open_row 0,
             open_row 1 ))
  (* fn<K, D>(f: Family<K, D>, ms: Int) -> Array<K>: the evictable keys
     last used at least [ms] milliseconds ago, by the scheduler's clock,
     in the order they were made *)
  | Family_idle -> fn [ read (family (Var 0) (Var 1)); read int ] (array (Var 0))
  (* fn<K, D>(f: Family<K, D>, each: fn()): [each] run at each call into
     [f] from outside it, an operation of an instance called through a
     pinned block, before it takes the instance *)
  | Family_edge ->
      fn [ read (family (Var 0) (Var 1)); read (Fun ([], unit, Ty.closed, open_row 2)) ] unit
  (* fn<K, D>(f: Family<K, D>, k: K, victim: spawned fn(evictable:
     Array<Stamped<K>>) -> Option<K>, body: fn() uses D) -> Pinned<D>:
     [Family_pin]'s, for a
     block that gives nothing and can't fail, what making the instance
     failed with kept in what it gives rather than failed with, so an
     operation of a library's can pin, whose type can't name what its
     setup fails with *)
  | Family_enter ->
      let uses_d = { Ty.labels = [ Ty.dep_of { dpath = Ty.param_path; dargs = [ Var 1 ] } ]; tail = None } in
      scheme_of
        (Fun
           ( [
               read (family (Var 0) (Var 1));
               read (Var 0);
               read (victim (Var 0));
               read (Fun ([], unit, open_row 0, uses_d));
             ],
             Con (Path.prelude "Pinned", [ Var 1 ]),
             open_row 0,
             open_row 1 ))
  (* fn<K, D>(f: Family<K, D>, k: K, c: Call<D, (), !>, victim: spawned
     fn(evictable: Array<Stamped<K>>) -> Option<K>) -> Pinned<D>: [c] put
     in [k]'s mailbox once
     it has room, its instance made first as [Family_enter]'s is, what
     making it failed with kept in what it gives (compiler.md, "Services
     stage", "Actors (step 7)", "Step 10: structured actors") *)
  | Family_post ->
      scheme_of
        (Fun
           ( [
               read (family (Var 0) (Var 1));
               read (Var 0);
               read (Con (Ty.generic_call, [ Var 1; unit; Errors Ty.closed ]));
               read (victim (Var 0));
             ],
             Con (Path.prelude "Pinned", [ Var 1 ]),
             open_row 0,
             Ty.closed ))
  (* fn<K, D>(f: Family<K, D>, ks: Array<K>, victim: spawned
     fn(evictable: Array<Stamped<K>>) -> Option<K>, body: fn()) ->
     Pinned<D>: [body] with the instances of [ks] held, in the keys'
     order, each made first as [Family_enter]'s is, what making one
     failed with kept in what it gives: `at_all`'s (compiler.md,
     "Services stage", "Step 10: structured actors") *)
  | Family_hold ->
      scheme_of
        (Fun
           ( [
               read (family (Var 0) (Var 1));
               read (array (Var 0));
               read (victim (Var 0));
               read (Fun ([], unit, open_row 0, open_row 1));
             ],
             Con (Path.prelude "Pinned", [ Var 1 ]),
             open_row 0,
             open_row 1 ))
  (* fn<D>(p: Pinned<(D ! E)>) ! E: what making the instance failed with,
     if it did *)
  (* fn<T>(body: fn() -> T ! E uses U) -> Result<T, ! E> uses U: what
     [body] gives, or fails with, kept, how `Actors.at` carries what its
     block gives out of the operation that runs it, whose block can't
     fail, as any library's may: `attempt` of its transparent block,
     which a public function can't write, that it then passes on with
     `try` *)
  | Family_kept ->
      scheme_of
        (Fun
           ( [ read (Fun ([], Var 0, open_row 0, open_row 1)) ],
             Con (Path.prelude "Result", [ Var 0; Errors (open_row 0) ]),
             Ty.closed,
             open_row 1 ))
  | Family_made ->
      let d = Ty.Impl { deps = [ { dpath = Ty.param_path; dargs = [ Var 0 ] } ]; over = false; needs = Ty.closed; fails = open_row 0 } in
      scheme_of (Fun ([ read (Con (Path.prelude "Pinned", [ d ])) ], unit, open_row 0, open_row 1))
  (* `Call`'s members (compiler.md, "Services stage", "`D.Call`"), each
     of a call [c] of [D], giving [R]. fn<D, R>(c: Call<D, R, ! E>) ->
     Option<Int>: its first argument's hash, by its type's `key`, the
     same in every run, or [None] for an operation of no parameters *)
  | Call_first_hash -> fn [ read (call (Var 0) (Var 1)) ] (option int)
  (* fn<D, R>(c: Call<D, R, ! E>, a: R, b: R) -> R: two of its results
     added, the larger, the smaller, or joined, panicking for a result
     that can't be *)
  | Call_add | Call_max | Call_min | Call_concat ->
      fn [ read (call (Var 0) (Var 1)); read (Var 1); read (Var 1) ] (Var 1)
  (* fn<D, R>(c: Call<D, R, ! E>, m: D, a: R, b: R) -> R: two of its
     results folded by [m]'s `call` clause, a merge's *)
  | Call_fold ->
      fn [ read (call (Var 0) (Var 1)); read (Var 0); read (Var 1); read (Var 1) ] (Var 1)
  (* fn<D>(h: D) -> Array<Operation>: the operations of the dependency
     [h] implements, as data *)
  | Call_operations ->
      fn [ read (Var 0) ] (array (Con (Path.prelude "Operation", [])))
  (* fn(seed: Int, below: Int) -> Option<Int>: in a spawned task, a
     number from 0 below [below] from the task's own stream of the test
     `Random` seeded with [seed]; [None] in a root task, which draws from
     the instance's own (compiler.md, "The tape") *)
  | Task_random -> fn [ read int; read int ] (option int)
  (* fn(): the task running has stopped accepting connections, once
     `accept_until` gave `None`: the tasks of the scopes whose bodies it's
     running have the cleanup deadline from now (compiler.md, "Stage 11a",
     "`Net`") *)
  | Task_drain -> fn [] unit

(* The operation of a built-in dependency that [x] is how the real one
   does, if it reaches the world: `fs_read` is `Fs.read`'s. Each is called
   only by its dependency's [real] (Core Lint checks it), so every call
   the program makes to the world is a call of an operation, which the
   journal records (handlers.md, "Recording and replaying"). This is the
   one place that says what reaches the world, and it names every
   intrinsic, so a new one has to be put on one side or the other. *)
let reaches (x : Intrinsic.t) =
  match x with
  | Clock_now -> Some ("Clock", "now")
  | Clock_instant -> Some ("Clock", "instant")
  | Clock_sleep -> Some ("Clock", "sleep")
  | Random_int -> Some ("Random", "int")
  | Console_write -> Some ("Console", "write")
  | Console_error -> Some ("Console", "error")
  | Fs_read -> Some ("Fs", "read")
  | Fs_write -> Some ("Fs", "write")
  | Fs_exists -> Some ("Fs", "exists")
  | Os_args -> Some ("Os", "args")
  | Proc_run -> Some ("Proc", "run")
  | Net_listen -> Some ("Net", "listen")
  | Net_accept -> Some ("Net", "accept")
  | Net_accept_until -> Some ("Net", "accept_until")
  | Net_read -> Some ("Net", "read")
  | Net_write -> Some ("Net", "write")
  | Net_close -> Some ("Net", "close")
  | Seeded_next | Seeded_int | Journal_kept | Journal_gave | Journal_answer
  | Journal_outputs | Journal_load | Map_empty | Set_empty | Array_sort | Map_of
  | Array_reserve | Map_into | Unsafe_cast | Float_lanes | Float_sum | Lib_panic
  | Scope_run | Task_spawn
  | Task_until | Arm_release | Arm_retake | Task_timeout | Task_isolate | Task_map
  | Task_each | Task_both | Task_race | Task_beside | Task_background | Background_spawn
  | Task_produce | Task_map_pull | Outbox_send | Inbox_take | Async_yield
  | Async_tick | Runtime_single | Runtime_sim
  | Runtime_leave | Sim_time | Sim_sleep | Sim_advance | Sim_alarm | Task_random
  | Async_worker | Family_open | Family_call | Family_make | Family_keys | Family_evict | Family_evictable
  | Family_counts | Family_close | Family_pin | Family_visit | Family_idle | Family_edge
  | Family_enter | Family_post | Family_hold | Family_made | Family_kept
  | Call_first_hash | Call_add | Call_max | Call_min
  | Call_concat | Call_fold | Call_operations
  | Task_drain | Map_get | Map_set | Map_remove | Map_includes | Map_keys | Map_values
  | Map_len | Set_of | Set_add | Set_remove | Set_includes | Set_len | Show
  | Array_len | Array_push | Str_byte_len | Str_index | Str_split
  | Str_trim | Str_starts_with | Str_add | Str_bytes | Str_from_utf8 | Str_from_utf8_lossy
  | Bytes_len | Bytes_at | Bytes_of | Array_copy | Str_copy | Bytes_copy
  | Bytes_read _ | Bytes_write _ | Bytes_zeros | Bytes_set_var _ | Bytes_var_size _
  | Array_split_at | Str_split_at | Bytes_split_at | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul
  | Int_wrapping_neg | Int_xor | Int_bit_and | Int_bit_or | Int_shl | Int_shr | Int_add | Int_sub | Int_mul | Int_div | Int_rem | Int_neg
  | Float_add | Float_sub | Float_mul | Float_div | Float_rem | Float_neg
  | Float_of | Float_round | Float_truncate | Float_sqrt | Str_ascii_lower | Bytes_ascii_lower | Bytes_add | Str_char_floor
  | Str_char_ceil | Str_code | Str_of_code | Array_join | Str_ends_with
  | Str_ascii_upper | Str_line_col | Bytes_index | Bytes_starts_with
  | Bytes_ends_with | Bytes_split | Bytes_trim | Bytes_ascii_upper | Hash
  | Pulled_count | Pulled_count_by ->
      None

(* Who can call it. Any program can, unless only the prelude's own
   source can: because it reaches the world, which a program does only
   through a dependency, in the real implementation the runtime installs
   ([World], which [reaches] says); or it's how one of the test
   implementations works ([Test]); or it's the journal's, which the
   runtime puts over the world ([Journal]); or because it's what one of
   the source's values is made with, which a program uses instead:
   `map_empty()` is `Map.empty` ([Value]); or it's how the prelude's own
   `map` works, and unsafe anywhere else ([Internal]). *)
type caller = Any | World | Test | Journal | Value | Internal

let caller (x : Intrinsic.t) =
  match (reaches x, x) with
  | Some _, _ -> World
  | None, (Seeded_next | Seeded_int | Task_random) -> Test
  | ( None,
      ( Journal_kept | Journal_gave | Journal_answer | Journal_outputs
      | Journal_load ) ) ->
      Journal
  | None, (Map_empty | Set_empty) -> Value
  (* what `actors` and `striped` are written with that any library may
     use too, so std has no power a user library lacks (decision 20, rule
     2): a library's panic, and a block's value and error kept, to carry
     them out of an operation whose block can't fail *)
  | None, (Lib_panic | Family_kept) -> Any
  | ( None,
      ( Array_reserve | Map_into | Unsafe_cast | Float_lanes | Float_sum
      | Scope_run | Task_spawn
      | Task_until | Arm_release | Arm_retake | Task_timeout
      | Task_isolate | Task_map
      | Task_each | Task_both | Task_race | Task_beside | Task_background
      | Task_produce | Task_map_pull | Outbox_send | Inbox_take
      | Async_yield | Async_tick
      | Runtime_single | Runtime_sim | Runtime_leave | Sim_time | Sim_sleep
      | Sim_advance | Sim_alarm | Task_drain | Hash | Pulled_count | Pulled_count_by | Async_worker
      | Family_open | Family_call | Family_make | Family_keys | Family_evict | Family_evictable
      | Family_counts | Family_close | Family_pin | Family_visit | Family_idle | Family_edge
      | Family_enter | Family_post | Family_hold | Family_made
      | Call_first_hash | Call_add | Call_max
      | Call_min | Call_concat | Call_fold | Call_operations ) ) ->
      Internal
  | None, _ -> Any

let runtime x = caller x <> Any

(* The keyed instance family's intrinsics, each with the member of the
   prelude's `Instances` that calls it, the only one that may (Core
   Lint; compiler.md, "Services stage", "The keyed instance family"), as
   [reaches] says which real implementation may call the world's. *)
let runtime_of (x : Intrinsic.t) =
  match x with
  | Family_open -> Some ("Instances", "open")
  | Family_call -> Some ("Instances", "call")
  | Family_make -> Some ("Instances", "make")
  | Family_keys -> Some ("Instances", "keys")
  | Family_evict -> Some ("Instances", "evict")
  | Family_evictable -> Some ("Instances", "evictable")
  | Family_counts -> Some ("Instances", "counts")
  | Family_close -> Some ("Instances", "close")
  | Family_pin -> Some ("Instances", "pin")
  | Family_visit -> Some ("Instances", "visit")
  | Family_idle -> Some ("Instances", "idle")
  | Family_edge -> Some ("Instances", "at_edge")
  | Family_enter -> Some ("Instances", "enter")
  | Family_post -> Some ("Instances", "post")
  | Family_hold -> Some ("Instances", "hold")
  | Family_made -> Some ("Instances", "made")
  | _ -> None

(* The built-in functions that aren't a type's members, in the order the
   prelude's interface lists them. *)
let fns : Intrinsic.t list =
  [
    Show;
    Clock_now;
    Clock_instant;
    Clock_sleep;
    Random_int;
    Seeded_next;
    Seeded_int;
    Console_write;
    Console_error;
    Fs_read;
    Fs_write;
    Fs_exists;
    Os_args;
    Proc_run;
    Net_listen;
    Net_accept;
    Net_accept_until;
    Net_read;
    Net_write;
    Net_close;
    Journal_kept;
    Journal_gave;
    Journal_answer;
    Journal_outputs;
    Journal_load;
    Map_empty;
    Set_empty;
    Array_reserve;
    Map_into;
    Unsafe_cast;
    Float_lanes;
    Float_sum;
    Lib_panic;
    Scope_run;
    Task_spawn;
    Task_until;
    Arm_release;
    Arm_retake;
    Task_timeout;
    Task_isolate;
    Task_map;
    Task_each;
    Task_both;
    Task_race;
    Task_beside;
    Task_background;
    Task_produce;
    Task_map_pull;
    Outbox_send;
    Inbox_take;
    Async_yield;
    Async_tick;
    Runtime_single;
    Runtime_sim;
    Runtime_leave;
    Sim_time;
    Sim_sleep;
    Sim_advance;
    Sim_alarm;
    Async_worker;
    Family_open;
    Family_call;
    Family_make;
    Family_keys;
    Family_evict;
    Family_evictable;
    Family_counts;
    Family_close;
    Family_pin;
    Family_visit;
    Family_idle;
    Family_edge;
    Family_enter;
    Family_post;
    Family_hold;
    Family_made;
    Family_kept;
    Call_first_hash;
    Call_add;
    Call_max;
    Call_min;
    Call_concat;
    Call_fold;
    Call_operations;
    Task_random;
    Task_drain;
    Hash;
    Pulled_count;
    Pulled_count_by;
  ]

(* ---- built-in types ----

   A built-in type's methods are built in too, and listed with it: each is
   called with a dot, its receiver its first parameter, `self`. *)

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : Intrinsic.t list;
  functions : Intrinsic.t list;  (** its associated functions, without `self` *)
}

let types =
  let t ?(methods = []) ?(functions = []) ?(arity = 0) name =
    { name; arity; methods; functions }
  in
  (* `Array` before `Str`, whose `len` an old-style `len(xs)` means
     less often (resolve.ml) *)
  [
    t "Int"
      ~methods:
        [
          Int_add;
          Int_sub;
          Int_mul;
          Int_div;
          Int_rem;
          Int_neg;
          Int_wrapping_add;
          Int_wrapping_sub;
          Int_wrapping_mul;
          Int_wrapping_neg;
          Int_xor;
          Int_bit_and;
          Int_bit_or;
          Int_shl;
          Int_shr;
        ];
    t "Float"
      ~methods:
        [
          Float_add;
          Float_sub;
          Float_mul;
          Float_div;
          Float_rem;
          Float_neg;
          Float_round;
          Float_truncate;
          Float_sqrt;
        ]
      ~functions:[ Float_of ];
    t "Bool";
    t "Unit";
  ]
  (* the sized storage types (sized.ml): no members, since arithmetic is
     done in what they're read as *)
  @ List.map (fun k -> t (Sized.name k)) Sized.all
  @ [
    t "Array" ~arity:1
      ~methods:[ Array_len; Array_push; Array_sort; Array_copy; Array_split_at; Array_join ];
    t "Str"
      ~methods:
        [
          Str_byte_len;
          Str_index;
          Str_split;
          Str_trim;
          Str_starts_with;
          Str_add;
          Str_bytes;
          Str_ascii_lower;
          Str_copy;
          Str_split_at;
          Str_char_floor;
          Str_char_ceil;
          Str_code;
          Str_ends_with;
          Str_ascii_upper;
          Str_line_col;
        ]
      ~functions:[ Str_from_utf8; Str_from_utf8_lossy; Str_of_code ];
    t "Bytes"
      ~methods:
        (Intrinsic.
           [
             Bytes_len;
             Bytes_at;
             Bytes_copy;
             Bytes_split_at;
             Bytes_add;
             Bytes_ascii_lower;
             Bytes_index;
             Bytes_starts_with;
             Bytes_ends_with;
             Bytes_split;
             Bytes_trim;
             Bytes_ascii_upper;
           ]
        @ List.map (fun a -> Intrinsic.Bytes_read a) Intrinsic.accesses
        @ List.map (fun a -> Intrinsic.Bytes_write a) Intrinsic.accesses
        @ Intrinsic.[ Bytes_set_var false; Bytes_set_var true ])
      ~functions:Intrinsic.[ Bytes_of; Bytes_zeros; Bytes_var_size false; Bytes_var_size true ];
    (* a set of error tags, given by name at a call, `on: Flaky | Broken`,
       which the function it's given to matches with `fail on`: never a
       value, since each function that takes one is made for each set it's
       given (compiler.md, "`over any` and `retry`") *)
    t "Tags";
    (* a task's scope (stage 11a): its members are the source's. A
       task has no handle (concurrency.md, "The tree side") *)
    t "Scope";
    (* what `Async.background` gives its body, a scope whose tasks may
       fail, with what its type argument, an error set, says (compiler.md,
       "Services stage", "Background work") *)
    t "Background" ~arity:1 ~methods:[ Background_spawn ];
    (* the two ends of `Async.produce`'s buffer, and `map_pull`'s results
       (compiler.md, "Services stage", step 5) *)
    t "Outbox" ~arity:1;
    t "Inbox" ~arity:2;
    (* a keyed instance family's handle, and generic code's `D.Call<R !
       E>`, whose third argument is an error set (compiler.md, "Services
       stage"); their members are the source's *)
    t "Family" ~arity:2;
    (* what `Instances.enter` gives: what making the instance failed
       with, if it did (compiler.md, "Services stage", "Actors (step 7)") *)
    t "Pinned" ~arity:1;
    t "Call" ~arity:3;
    t "Map" ~arity:2
      ~methods:
        [
          Map_get;
          Map_set;
          Map_remove;
          Map_includes;
          Map_keys;
          Map_values;
          Map_len;
        ]
      ~functions:[ Map_of ];
    t "Set" ~arity:1
      ~methods:[ Set_add; Set_remove; Set_includes; Set_len ]
      ~functions:[ Set_of ];
  ]
  (* a tuple's type, of each size up to eight, named by its shape, which no
     program can write (Ty.tuple): a program writes two and three, and an
     operation's arguments, `call.args`, are any of them *)
  @ List.init 8 (fun i ->
        t (match Ty.tuple_path (i + 1) with p -> p.name) ~arity:(i + 1))

(* ---- built-in dependencies ----

   The dependencies the runtime installs around `main`, if it uses them:
   each is declared in [source], with its real implementation, `real`
   (deps.md, "`main`"). *)
let world_deps = [ "Clock"; "Random"; "Console"; "Fs"; "Os"; "Proc"; "Net" ]

(* `Async`, the runtime itself, isn't the world: the journal records
   none of its calls, but the order they made, in its task column, its
   polls and its cancels (journal.ml) *)
let runtime_deps = world_deps @ [ "Async" ]

(* The dependencies a `uses` can name that aren't declared anywhere yet:
   their stages give them operations. *)
let dependencies = [ "Alloc"; "Unsafe" ]

(* Every built-in function, by its path. The map is made once, when the
   compiler starts, and never changes. *)
let by_path =
  let all = fns @ List.concat_map (fun t -> t.methods @ t.functions) types in
  List.fold_left
    (fun m x -> Path.Map.add (Intrinsic.path x) x m)
    Path.Map.empty all

let find p = Path.Map.find_opt p by_path

(* The intrinsic half of the prelude's interface, as the prelude's own
   source sees it, with what reaches the world and what its values are
   made with; [public] is what every other module sees, without them. *)
let intrinsics : Iface.t =
  {
    home = Path.prelude_home;
    replay_unsafe = [];
    types =
      List.map
        (fun (t : builtin_type) : Iface.type_decl ->
          {
            path = Path.prelude t.name;
            params = List.init t.arity (fun i -> "T" ^ string_of_int i);
            body = Builtin;
            members =
              Path.Map.of_list
                (List.mapi
                   (fun onum (okind, x) ->
                     ( Intrinsic.path x,
                       {
                         Iface.oname = Intrinsic.member_name x;
                         onum;
                         opub = true;
                         okind;
                         oscheme = scheme x;
                       } ))
                   (List.map (fun x -> (Iface.Method, x)) t.methods
                   @ List.map (fun x -> (Iface.Function, x)) t.functions));
            numeric = None;
            opaque = false;
            loc = None;
          })
        types;
    values =
      List.map
        (fun x ->
          { Iface.vname = Intrinsic.name x; scheme = scheme x; generator = None; vparams = [] })
        fns;
    tests = [];
    wirings = [];
  }

let public =
  {
    intrinsics with
    values =
      List.filter
        (fun (v : Iface.value) ->
          match find (Path.prelude v.vname) with
          | Some x -> caller x = Any
          | None -> true)
        intrinsics.values;
  }
