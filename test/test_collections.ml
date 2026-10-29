(* Tuples, ranges and the collections (operators.md, stage 9b): a tuple
   is two or three values passed together, taken apart only by patterns;
   a range is counted by a `for`; and `Array`, `Map` and `Set` have
   `Enumerable`'s methods. *)

open Helpers

(* ---- tuples ---- *)

let%expect_test "a tuple is made, passed, taken apart and shown" =
  run
    {|
fn swap(p: (Int, Str)) -> (Str, Int) =
  let (a, b) = p
  (b, a)

fn main() uses Console =
  let t = swap((1, "a"))
  print(t)
  print((1, (true, "x"), 2.5))
  let (s, (n, _)) = (t, (3, ()))
  print(s)
  print(n)
  match (1, Some(2))
    (0, _) => print("zero")
    (n, Some(m)) => print(n + m)
    (_, None) => print("none")
|};
  [%expect
    {|
    ("a", 1)
    (1, (true, "x"), 2.5)
    ("a", 1)
    3
    3
    ()
    |}]

let%expect_test "tuples are equal, hashed and ordered part by part" =
  run
    {|
fn main() uses Console =
  print((1, "b") == (1, "b"))
  print((1, "b") != (1, "c"))
  print((1, "b") < (2, "a"))
  print((1, "b") < (1, "a"))
  print((1, 2, 3) <= (1, 2, 3))
|};
  [%expect {|
    true
    true
    true
    false
    true
    ()
    |}]

let%expect_test "a tuple's type is written, and checked, part by part" =
  types
    {|
pub fn pair<A, B>(a: A, b: B) -> (A, B) = (a, b)
pub fn first<A, B>(p: (A, B)) -> A =
  let (a, _) = p
  a
pub fn three() -> (Int, Str, Bool) = (1, "a", true)
fn main() = ()
|};
  [%expect
    {|
    pub fn pair<A, B>(a: A, b: B) -> (A, B)
    pub fn first<A, B>(p: (A, B)) -> A
    pub fn three() -> (Int, Str, Bool)
    fn main()
    |}];
  check_error
    {|
fn f(p: (Int, Str, Bool)) -> Int =
  let (a, b) = p
  a
fn main() = ()
|};
  [%expect
    {|
    error: expected a pattern for `(Int, Str, Bool)`, but this one is a `(_, _)`
      ┌─ test.ren:2:7
    2 │   let (a, b) = p
      │       ^^^^^^
      help: the tuple has 3 parts, so take it apart with 3: `(a, b, _)`
    |}]

let%expect_test "a tuple has two parts or three, and no `.0`" =
  check_error {|
fn main() =
  let t = (1, 2, 3, 4)
  ()
|};
  [%expect
    {|
    error: a tuple has two parts or three, but this has 4
      ┌─ test.ren:2:11
    2 │   let t = (1, 2, 3, 4)
      │           ^^^^^^^^^^^^
      help: use a record, which names its parts: `type T = { a: A, b: B, ... }`
    |}];
  check_error {|
fn main() =
  let t = (1, 2)
  let x = t.0
  ()
|};
  [%expect
    {|
    error: a tuple's parts have no names or numbers
      ┌─ test.ren:3:13
    3 │   let x = t.0
      │             ^
      help: take it apart with a pattern, `let (a, b) = t`; if its parts want names, make it a record
    |}];
  check_error {|
fn f(t: (Int,)) = ()
|};
  [%expect
    {|
    error: a tuple has two parts or three, but this has one
      ┌─ test.ren:1:9
    1 │ fn f(t: (Int,)) = ()
      │         ^^^^^^
      help: write the value on its own, without a `,`
    |}]

let%expect_test
    "`Some(k, v)` is one field given two: a tuple is in parentheses of its own"
    =
  check_error
    {|
fn main() =
  match Some((1, 2))
    Some(k, v) => ()
    None => ()
|};
  [%expect
    {|
    error: `Some` has 1 field but was given 2
      ┌─ test.ren:3:5
    3 │     Some(k, v) => ()
      │     ^^^^^^^^^^
      help: to give it a tuple, put the tuple in parentheses of its own: `Some((a, b))`
    |}]

let%expect_test "a `match` on a tuple covers each part's cases" =
  check_error
    {|
fn main() =
  match (1, Some(2))
    (_, None) => ()
    (0, Some(_)) => ()
|};
  [%expect
    {|
    error: this `match` doesn't handle every `(Int, Option<Int>)`
      ┌─ test.ren:2:3
    2 │   match (1, Some(2))
      │   ^^^^^
      = missing: (_, Some(_))
      help: add an arm for `(_, Some(_))`, or a `_ =>` arm for the rest
    |}];
  check_error
    {|
fn main() =
  match (true, false)
    (true, _) => ()
    (false, true) => ()
    (false, false) => ()
    (_, _) => ()
|};
  [%expect
    {|
    error: this arm can never match
      ┌─ test.ren:6:5
    6 │     (_, _) => ()
      │     ^^^^^^
      help: the arms above already match everything this one does
    |}]

let%expect_test "a tuple is ordered only if its parts are" =
  check_error
    {|
type User = { n: Int }

fn main() =
  let x = (User { n: 1 }, 2) < (User { n: 2 }, 1)
  ()
|};
  [%expect
    {|
    error: `(User, Int)` has no `<`
      ┌─ test.ren:4:11
    4 │   let x = (User { n: 1 }, 2) < (User { n: 2 }, 1)
      │           ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = a record is ordered only by its `key`, so that reordering its fields can't change a sort
      help: give `User` a key: `fn key(self) -> K = ...`
    |}]

(* ---- taking a tuple apart: `let` and `for` ---- *)

let%expect_test "`let` and `for` take apart only what always matches" =
  check_error {|
fn main() =
  let o = Some(1)
  let Some(x) = o
  ()
|};
  [%expect
    {|
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(x)` might not
      ┌─ test.ren:3:7
    3 │   let Some(x) = o
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}];
  check_error {|
fn main() =
  let (a, Some(b)) = (1, Some(2))
  ()
|};
  [%expect
    {|
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(b)` might not
      ┌─ test.ren:2:11
    2 │   let (a, Some(b)) = (1, Some(2))
      │           ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}];
  check_error {|
fn main() =
  var (a, b) = (1, 2)
  ()
|};
  [%expect
    {|
    error: a `var` can't take a tuple apart
      ┌─ test.ren:2:3
    2 │   var (a, b) = (1, 2)
      │   ^^^
      help: take it apart with `let`, then make a `var` of each part that changes: `var x = a`
    |}];
  check_error
    {|
fn main() =
  var xs = [(1, 2)]
  for (a, b) in &xs
    ()
  ()
|};
  [%expect
    {|
    error: a `for` that changes each element names it, and can't take it apart
      ┌─ test.ren:3:7
    3 │   for (a, b) in &xs
      │       ^^^^^^
      help: write `for x in &xs`, and change `x`; to read its parts, take it apart inside the loop
    |}];
  check_error {|
fn main() =
  let (a, a) = (1, 2)
  ()
|};
  [%expect
    {|
    error: there are two variables named `a`
      ┌─ test.ren:2:11
    2 │   let (a, a) = (1, 2)
      │           ^
      │        - the first `a` is here
      help: rename one of them
    |}]

let%expect_test "`for` takes each element apart" =
  run
    {|
fn main() uses Console =
  var total = 0
  for (n, (w, _)) in [(1, (10, "a")), (2, (20, "b"))]
    total += n * w
  print(total)
|};
  [%expect {|
    50
    ()
    |}]

let%expect_test "taking apart is lowered to a `match` of one arm" =
  core {|
fn f(p: (Int, Str)) -> Str =
  let (_, s) = p
  s
fn main() = ()
|};
  [%expect
    {|
    (fn f (p/1) ev/2 (match p/1 ((tuple _ s/3) => s/3)))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

(* ---- a lambda's parameter taken apart ---- *)

let%expect_test "a lambda's parameter takes a tuple apart" =
  run
    {|
fn main() uses Console =
  let m = Map.of([("a", 1), ("b", 2), ("c", 3)])
  print(m.select(fn((_, v)) => v > 1))
  print(m.map(fn((k, v)) => k.concat(show(v))))
  print(m.any(fn((k, v)) => k == "c" && v == 3))
  print(m.sort_by(fn((_, v)) => -v))
  let ps = [(1, ("x", true)), (2, ("y", false))]
  print(ps.select(fn((_, (_, b))) => b))
  print(ps.map(fn((n, (s, _)): (Int, (Str, Bool))) => s.concat(show(n))))
  let add = fn((a, b)) => a + b
  print(add((1, 2)))
  let f = fn((a, b), c) => a * b + c
  print(f((2, 3), 4))
|};
  [%expect
    {|
    Map.of([("b", 2), ("c", 3)])
    ["a1", "b2", "c3"]
    true
    [("c", 3), ("b", 2), ("a", 1)]
    [(1, ("x", true))]
    ["x1", "y2"]
    3
    10
    ()
    |}]

let%expect_test "a lambda's tuple is lowered as a `let` that takes it apart" =
  core {|
fn main() =
  let f = fn((a, _)) => a
  f((1, 2))
|};
  [%expect
    {|
    (fn main () ev/1
      (let f/2
        (lambda ($3/3) (captures ev/1) ev/4 (extend ev/1)
          (match $3/3 ((tuple a/5 _) => a/5)))
        (call ev/1 f/2 (tuple 1 2))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "only a lambda's parameter takes a tuple apart, and always" =
  check_error {|
fn main() =
  let f = fn((k, Some(v))) => v
  ()
|};
  [%expect
    {|
    error: a lambda's parameter takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(v)` might not
      ┌─ test.ren:2:18
    2 │   let f = fn((k, Some(v))) => v
      │                  ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}];
  check_error {|
fn f((a, b): (Int, Int)) -> Int = a
fn main() = ()
|};
  [%expect
    {|
    error: only a lambda's parameter can take a tuple apart
      ┌─ test.ren:1:6
    1 │ fn f((a, b): (Int, Int)) -> Int = a
      │      ^
      help: name it, `p: (A, B)`, and take it apart in the body: `let (a, b) = p`
    |}];
  check_error {|
fn main() =
  let f = fn((a, b), a) => a
  ()
|};
  [%expect
    {|
    error: there are two parameters named `a`
      ┌─ test.ren:2:22
    2 │   let f = fn((a, b), a) => a
      │                      ^
      │               - the first `a` is here
      help: rename one of them
    |}];
  check_error
    {|
fn main() =
  let m = Map.of([(1, 2)])
  let a = m.select(fn((k, v, w)) => true)
  let b = [1, 2].map(fn((x, y)) => x)
  ()
|};
  [%expect
    {|
    error: expected a pattern for `(Int, Int)`, but this one is a `(_, _, _)`
      ┌─ test.ren:3:23
    3 │   let a = m.select(fn((k, v, w)) => true)
      │                       ^^^^^^^^^
      help: the tuple has 2 parts, so take it apart with 2: `(k, v)`

    error: expected a pattern for `Int`, but this one is a `(_, _)`
      ┌─ test.ren:4:25
    4 │   let b = [1, 2].map(fn((x, y)) => x)
      │                         ^^^^^^
      help: `Int` isn't a tuple, so name it whole instead, like `x`
    |}]

(* ---- ranges ---- *)

let%expect_test "`for i in a..b` counts from `a` up to, but not including, `b`"
    =
  run
    {|
fn main() uses Console =
  let xs = [3, 1, 4]
  for i in 0..xs.len() - 1
    print((xs[i], xs[i + 1]))
  for i in 5..5
    print("never")
  for i in 5..2
    print("never")
  var n = 0
  for i in -2..2
    n += i
  print(n)
|};
  [%expect {|
    (3, 1)
    (1, 4)
    -2
    ()
    |}]

let%expect_test "a range is only a `for`'s, half-open, of `Int`s" =
  check_error {|
fn main() =
  let r = 0..3
  ()
|};
  [%expect
    {|
    error: a range, `a..b`, is written only after a `for`'s `in`, or in an index: it isn't a value
      ┌─ test.ren:2:12
    2 │   let r = 0..3
      │            ^^
      help: a range is for counting, `for i in 0..n`, and for slicing, `xs[a..b]`
    |}];
  check_error {|
fn main() =
  for i in 0..=3
    ()
  ()
|};
  [%expect
    {|
    error: there's no `..=`: a range is from the first number up to, but not including, the second
      ┌─ test.ren:2:15
    2 │   for i in 0..=3
      │               ^
      help: write `a..b + 1` for the `Int`s up to and including `b`
    |}];
  check_error {|
fn main() =
  for i in 0...3
    ()
  ()
|};
  [%expect
    {|
    error: a range is written with two dots, `a..b`, from the first number up to, but not including, the second
      ┌─ test.ren:2:15
    2 │   for i in 0...3
      │               ^
      help: write `a..b`
    |}];
  check_error {|
fn main() =
  for i in 0..2.5
    ()
  ()
|};
  [%expect
    {|
    error: expected `Int`, found `Float`
      ┌─ test.ren:2:15
    2 │   for i in 0..2.5
      │               ^^^
      = a range, `a..b`, counts from one `Int` up to another
    |}]

let%expect_test "a range is a counting `while`" =
  core
    {|
fn f(n: Int) -> Int =
  var t = 0
  for i in 0..n
    t += i
  t
fn main() = ()
|};
  [%expect
    {|
    (fn f (n/1) ev/2
      (let t/3 0
        (seq
          (let $i/4 0
            (let $stop/5 n/1
              (while (< $i/4 $stop/5)
                (let i/6 $i/4 (seq (= t/3 (+ t/3 i/6)) (= $i/4 (+ $i/4 1)))))))
          t/3)))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

(* ---- the collection methods ---- *)

let%expect_test "`Array`'s methods, written in the prelude" =
  run
    {|
type User = { name: Str, age: Int }

fn main() uses Console =
  let xs = [3, 1, 4, 1, 5, 9, 2, 6]
  print(xs.map(fn(x) => x * 2))
  print(xs.flat_map(fn(x) => [x, x]).take(4))
  print((xs.select(fn(x) => x > 2), xs.reject(fn(x) => x > 2)))
  print((xs.find(fn(x) => x > 3), xs.find(fn(x) => x > 9)))
  print((xs.index(1), xs.index(7)))
  print((xs.any(fn(x) => x > 8), xs.all(fn(x) => x > 1), xs.count(fn(x) => x == 1)))
  print(xs.includes(9))
  print(xs.reduce("", fn(s, x) => s.concat(show(x))))
  print((xs.sum(), [1.5, 2.5].sum(), [Duration.ms(5), Duration.ms(6)].sum()))
  print((xs.min(), xs.max(), [0].take(0).min()))
  print((xs.sort(), xs))
  let us = [User { name: "ann", age: 30 }, User { name: "bob", age: 25 }, User { name: "cy", age: 30 }]
  print(us.min_by(fn(u) => u.age))
  print(us.max_by(fn(u) => u.age))
  print(us.sort_by(fn(u) => u.age).map(fn(u) => u.name))
  print(us.group_by(fn(u) => u.age).map(fn(g) =>
    let (age, users) = g
    (age, users.len())))
  print(xs.partition(fn(x) => x % 2 == 0))
  print(xs.tally())
  print(xs.uniq())
  // a cursor, which a `for` goes over
  var zipped: Array<(Int, Str)> = []
  for p in xs.zip(["a", "b"])
    &zipped.push(p)
  print(zipped)
  print(["a", "b"].with_index())
  print((xs.first(), xs.last()))
  print((xs.get(2), xs.get(8), xs.get(-1)))
  print((xs.take(3), xs.drop(6)))
  print((xs.take(100), xs.drop(100)))
  print(xs.reverse())
|};
  [%expect
    {|
    [6, 2, 8, 2, 10, 18, 4, 12]
    [3, 3, 1, 1]
    ([3, 4, 5, 9, 6], [1, 1, 2])
    (Some(4), None)
    (Some(1), None)
    (true, false, 2)
    true
    31415926
    (31, 4.0, Duration(11))
    (Some(1), Some(9), None)
    ([1, 1, 2, 3, 4, 5, 6, 9], [3, 1, 4, 1, 5, 9, 2, 6])
    Some(User { name: "bob", age: 25 })
    Some(User { name: "ann", age: 30 })
    ["bob", "ann", "cy"]
    [(30, 2), (25, 1)]
    ([4, 2, 6], [3, 1, 1, 5, 9])
    Map.of([(3, 1), (1, 2), (4, 1), (5, 1), (9, 1), (2, 1), (6, 1)])
    [3, 1, 4, 5, 9, 2, 6]
    [(3, "a"), (1, "b")]
    [(0, "a"), (1, "b")]
    (Some(3), Some(6))
    (Some(4), None, None)
    ([3, 1, 4], [2, 6])
    ([3, 1, 4, 1, 5, 9, 2, 6], [])
    [6, 2, 9, 5, 1, 4, 1, 3]
    ()
    |}]

let%expect_test
    "a function given to a method fails, and uses, through it; `find` stops \
     calling it once it's found" =
  run
    {|
fn half(x: Int) -> Int ! Odd(Int) =
  if x % 2 == 1 then fail Odd(x) else x / 2

fn halves(xs: Array<Int>) -> Array<Int> ! Odd(Int) = try xs.map(half)

fn main() uses Console =
  print(attempt halves([2, 4]))
  print(attempt halves([2, 3, 5]))
  print(["a", "b", "c"].find(fn(s) =>
    print(s)
    s == "b"))
|};
  [%expect
    {|
    Ok([1, 2])
    Err(Odd(3))
    a
    b
    Some("b")
    ()
    |}]

let%expect_test "`take` and `drop` of a negative number panic" =
  run_error {|
fn main() = [1, 2].take(-1)
|};
  [%expect
    {|
    error: panic: `take` needs `n >= 0`, but `n` is -1
      ┌─ test.ren:1:13
    1 │ fn main() = [1, 2].take(-1)
      │             ^^^^^^^^^^^^^^^
    |}]

let%expect_test "a `Map` keeps its keys in the order each was first set" =
  run
    {|
fn main() uses Console =
  var m: Map<Str, Int> = Map.empty
  &m.set("b", 2)
  &m.set("a", 1)
  &m.set("b", 20)
  print(m)
  print((m.get("b"), m.get("z")))
  print((m.includes("a"), m.len()))
  print((m.keys(), m.values()))
  for (k, v) in m
    print(k.concat(show(v)))
  &m.remove("b")
  &m.remove("z")
  print(m)
  let n = Map.of([(1, "x"), (2, "y"), (1, "z")])
  print(n)
  print(n == Map.of([(2, "y"), (1, "z")]))
  print(n.select(fn(p) =>
    let (k, _) = p
    k > 1))
  print(n.map(fn(p) =>
    let (_, v) = p
    v))
  print((n.first(), n.sort(), n.reverse()))
|};
  [%expect
    {|
    Map.of([("b", 20), ("a", 1)])
    (Some(20), None)
    (true, 2)
    (["b", "a"], [20, 1])
    b20
    a1
    Map.of([("a", 1)])
    Map.of([(1, "z"), (2, "y")])
    true
    Map.of([(2, "y")])
    ["z", "y"]
    (Some((1, "z")), [(1, "z"), (2, "y")], Map.of([(2, "y"), (1, "z")]))
    ()
    |}]

let%expect_test
    "a `Map`'s key is found by its hash and `==`: a key's `key` says which are \
     the same" =
  run
    {|
type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  fn key(self) -> Str = self.lower()

type Account = { owner: Email, n: Int }

fn main() uses Console =
  var m: Map<Email, Int> = Map.empty
  &m.set(Email.of("Ann@Example.com"), 1)
  &m.set(Email.of("ann@example.com"), 2)
  print(m.len())
  print(m.get(Email.of("ANN@example.com")))
  let byOwner = Map.of([(Account { owner: Email.of("a"), n: 1 }, "x")])
  print(byOwner.get(Account { owner: Email.of("A"), n: 1 }))
  let t = Map.of([((1, "a"), 1), ((1, "b"), 2)])
  print(t.get((1, "b")))
|};
  [%expect {|
    1
    Some(2)
    Some("x")
    Some(2)
    ()
    |}]

let%expect_test "a `Set` has each value once, in the order each was first added"
    =
  run
    {|
fn main() uses Console =
  var s = Set.of([3, 1, 3])
  &s.add(2)
  &s.add(1)
  print(s)
  print((s.includes(2), s.includes(5), s.len()))
  for x in s
    print(x)
  &s.remove(3)
  print(s)
  print(s == Set.of([2, 1]))
  print((s.select(fn(x) => x > 1), s.sum()))
  print((s.sort(), s.map(fn(x) => x * 10)))
  let e: Set<Str> = Set.empty
  print(e)
|};
  [%expect
    {|
    Set.of([3, 1, 2])
    (true, false, 3)
    3
    1
    2
    Set.of([1, 2])
    true
    (Set.of([2]), 3)
    ([1, 2], [10, 20])
    Set.of([])
    ()
    |}]

let%expect_test "a key, or a member of a set, has no implementation in it" =
  check_error
    {|
fn main() =
  let m = Map.of([(Clock.frozen(Time.epoch), 2)])
  ()
|};
  [%expect
    {|
    error: `Clock` has no `hash`, which `Map.of` needs
      ┌─ test.ren:2:18
    2 │   let m = Map.of([(Clock.frozen(Time.epoch), 2)])
      │                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = a type with a function in it has no `==` or `hash`
      = an implementation of `Clock` is its operations, which are functions
      help: give `Map.of` something it can hash, without a function in it
    |}];
  check_error
    {|
fn main() =
  let m = Map.of([("a", 1)])
  let x = m < m
  ()
|};
  [%expect
    {|
    error: `Map<Str, Int>` has no `<`
      ┌─ test.ren:3:11
    3 │   let x = m < m
      │           ^^^^^
      = a `Map` keeps the order its keys were added in, but two aren't ordered
    |}]

let%expect_test "there's no `m[k]`: a key may not be there, so it's asked for" =
  check_error
    {|
fn main() =
  let m = Map.of([("a", 1)])
  let x = m["a"]
  ()
|};
  [%expect
    {|
    error: a `Map` isn't indexed with `[]`
      ┌─ test.ren:3:11
    3 │   let x = m["a"]
      │           ^^^^^^
      = a key that isn't there is ordinary, so it's asked for
      help: write `m.get("a")`, which gives an `Option`
    |}]

let%expect_test "a `for` goes over a copy of a map or a set" =
  check_error
    {|
fn main() =
  var m = Map.of([("a", 1)])
  for p in &m
    ()
  ()
|};
  [%expect
    {|
    error: a `for` can't change a map's entries in place
      ┌─ test.ren:3:12
    3 │   for p in &m
      │            ^^
      help: go over a copy, `for (k, v) in m`, and `&m.set(k, ...)` what changes
    |}]

let%expect_test "what has no order is sorted by something it has" =
  check_error
    {|
type User = { n: Int }

fn main() =
  let x = [User { n: 1 }].sort()
  let y = [[1]].max()
  ()
|};
  [%expect
    {|
    error: `User` has no `<`, which `Array.sort` needs
      ┌─ test.ren:4:11
    4 │   let x = [User { n: 1 }].sort()
      │           ^^^^^^^^^^^^^^^
      = `Array.sort` uses `<` on what it's given here
      = a record is ordered only by its `key`, so that reordering its fields can't change a sort
      = or use `sort_by`, which sorts by what a function gives each
      help: give `User` a key: `fn key(self) -> K = ...`

    error: `Array<Int>` has no `<`, which `Array.max` needs
      ┌─ test.ren:5:11
    5 │   let y = [[1]].max()
      │           ^^^^^
      = `Array.max` uses `<` on its `T`
      help: use `max_by`, which compares by what a function gives each
    |}]

(* ---- names Ren doesn't use ---- *)

let%expect_test "a name another language uses says Ren's" =
  check_error
    {|
fn main() =
  let xs = [1, 2]
  let a = xs.filter(fn(x) => x > 1)
  let b = xs.inject(0, fn(s, x) => s + x)
  let c = xs.length()
  let d = xs.size()
  let e = xs.contains(1)
  let f = xs.include(1)
  let g = xs.detect(fn(x) => x > 1)
  let h = xs.collect(fn(x) => x)
  let i = "a:b".find(":")
  let j = Map.of([(1, 2)]).size()
  ()
|};
  [%expect
    {|
    error: `Array<Int>` has no method named `filter`
      ┌─ test.ren:3:14
    3 │   let a = xs.filter(fn(x) => x > 1)
      │              ^^^^^^
      help: Ren calls it `select`

    error: `Array<Int>` has no method named `inject`
      ┌─ test.ren:4:14
    4 │   let b = xs.inject(0, fn(s, x) => s + x)
      │              ^^^^^^
      help: Ren calls it `reduce`

    error: `Array<Int>` has no method named `length`
      ┌─ test.ren:5:14
    5 │   let c = xs.length()
      │              ^^^^^^
      help: Ren calls it `len`

    error: `Array<Int>` has no method named `size`
      ┌─ test.ren:6:14
    6 │   let d = xs.size()
      │              ^^^^
      help: Ren calls it `len`

    error: `Array<Int>` has no method named `contains`
      ┌─ test.ren:7:14
    7 │   let e = xs.contains(1)
      │              ^^^^^^^^
      help: Ren calls it `includes`

    error: `Array<Int>` has no method named `include`
      ┌─ test.ren:8:14
    8 │   let f = xs.include(1)
      │              ^^^^^^^
      help: Ren calls it `includes`

    error: `Array<Int>` has no method named `detect`
      ┌─ test.ren:9:14
    9 │   let g = xs.detect(fn(x) => x > 1)
      │              ^^^^^^
      help: Ren calls it `find`

    error: `Array<Int>` has no method named `collect`
       ┌─ test.ren:10:14
    10 │   let h = xs.collect(fn(x) => x)
       │              ^^^^^^^
       help: Ren calls it `map`

    error: `Str` has no method named `find`
       ┌─ test.ren:11:17
    11 │   let i = "a:b".find(":")
       │                 ^^^^
       help: to find where something is, use `index`; a `find` takes a function

    error: `Map<Int, Int>` has no method named `size`
       ┌─ test.ren:12:28
    12 │   let j = Map.of([(1, 2)]).size()
       │                            ^^^^
       help: Ren calls it `len`
    |}]

let%expect_test "a failed `assert` on two maps leaves out what they share" =
  run_error
    {|
type Account = { id: Int, balance: Int, frozen: Bool }

fn main() =
  let a = Map.of([(1, Account { id: 1, balance: 5, frozen: false }), (2, Account { id: 2, balance: 0, frozen: false })])
  let b = Map.of([(1, Account { id: 1, balance: 5, frozen: false }), (2, Account { id: 2, balance: 7, frozen: false })])
  assert a == a
  assert Set.of([1, 2]) == Set.of([2, 1])
  assert a == b
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:8:10
    8 │   assert a == b
      │          ^^^^^^
      = left:  Map.of([..., (2, Account { ..., balance: 0, ... })])
      = right: Map.of([..., (2, Account { ..., balance: 7, ... })])
    |}];
  run_error {|
fn main() =
  assert Set.of([1, 2, 3]) == Set.of([1, 2, 4])
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:2:10
    2 │   assert Set.of([1, 2, 3]) == Set.of([1, 2, 4])
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = left:  Set.of([..., 3])
      = right: Set.of([..., 4])
    |}];
  run_error
    {|
fn main() =
  assert Map.of([(1, "a")]) == Map.of([(1, "a"), (2, "b")])
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:2:10
    2 │   assert Map.of([(1, "a")]) == Map.of([(1, "a"), (2, "b")])
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = left:  Map.of([...])
      = right: Map.of([..., (2, "b")])
    |}]

(* ---- reviews of 9b ---- *)

let%expect_test "building a collection by `push` is linear, not quadratic" =
  (* each push copied the whole array once, so this took minutes; pushing
     onto the end of an array writes into room its store has spare *)
  run
    {|
fn main() =
  var xs: Array<Int> = []
  for i in 0..100000
    &xs.push(i)
  print(xs.map(fn(x) => x * 2).select(fn(x) => x % 3 == 0).len())
  var m: Map<Int, Int> = Map.empty
  for i in 0..100000
    &m.set(i, i)
  print(m.first())
  print(m.keys().reject(fn(k) => k > 5).last())
|};
  [%expect {|
    33334
    Some((0, 0))
    Some(5)
    ()
    |}]

let%expect_test
    "an array pushed onto is never changed for another that shares it" =
  run
    {|
fn main() =
  var a = [1, 2]
  let b = a
  &a.push(3)
  var c = b
  &c.push(4)
  var d = a
  &a.push(5)
  &d.push(6)
  print(a)
  print(b)
  print(c)
  print(d)
|};
  [%expect
    {|
    [1, 2, 3, 5]
    [1, 2]
    [1, 2, 4]
    [1, 2, 3, 6]
    ()
    |}]

let%expect_test "`take` of a negative count says which call, and why" =
  run_error {|
fn main() =
  let m = Map.of([(1, 2)])
  print(m.drop(-1))
|};
  [%expect
    {|
    error: panic: `drop` needs `n >= 0`, but `n` is -1
      ┌─ test.ren:3:9
    3 │   print(m.drop(-1))
      │         ^^^^^^^^^^
    |}]

let%expect_test "a key with a function in it is given a key, in a `Map` too" =
  check_error
    {|
type Sub = { id: Int, notify: Clock }
fn main() =
  let s = Sub { id: 1, notify: Clock.frozen(Time.epoch) }
  var m: Map<Sub, Int> = Map.empty
  &m.set(s, 1)
  print(Set.of([s]))
|};
  [%expect
    {|
    error: `Sub` has no `hash`, which `Map.set` needs
      ┌─ test.ren:5:10
    5 │   &m.set(s, 1)
      │          ^
      = a type with a function in it has `==` and `hash` only through its `key`
      = the field `notify` of `Sub` has a function in it
      help: give `Sub` a key, which says what makes two the same: `fn key(self) -> K = ...`

    error: `Sub` has no `hash`, which `Set.of` needs
      ┌─ test.ren:6:16
    6 │   print(Set.of([s]))
      │                ^^^
      = a type with a function in it has `==` and `hash` only through its `key`
      = the field `notify` of `Sub` has a function in it
      help: give `Sub` a key, which says what makes two the same: `fn key(self) -> K = ...`
    |}]

let%expect_test "what needs only `hash` says so" =
  check_error
    {|
fn count_all(xs) =
  var m = Map.empty
  for x in xs
    &m.set(x, 1)
  m
fn main() =
  let c = Clock.frozen(Time.epoch)
  print(count_all([c]).len())
|};
  [%expect
    {|
    error: `Clock` has no `hash`, which `count_all` needs
      ┌─ test.ren:8:19
    8 │   print(count_all([c]).len())
      │                   ^^^
      = a type with a function in it has no `==` or `hash`
      = an implementation of `Clock` is its operations, which are functions
      help: give `count_all` something it can hash, without a function in it
    |}]

let%expect_test "`sum` of what has no `+` says what to do instead" =
  check_error
    {|
type P = { x: Int }
fn main() =
  print([true, false].sum())
  print([P { x: 1 }].sum())
|};
  [%expect
    {|
    error: `Bool` has no `+`, which `Array.sum` needs
      ┌─ test.ren:3:9
    3 │   print([true, false].sum())
      │         ^^^^^^^^^^^^^
      = `Array.sum` uses `+` on its `T`
      help: to count those that are `true`, use `count(fn(b) => b)`

    error: `P` has no `+`, which `Array.sum` needs
      ┌─ test.ren:4:9
    4 │   print([P { x: 1 }].sum())
      │         ^^^^^^^^^^^^
      = `Array.sum` uses `+` on its `T`
      help: add up something each one has with `reduce(init, fn(acc, x) => ...)`, or `map` them to numbers first
    |}]

let%expect_test "a condition is a `Bool`, and the help says how to ask" =
  check_error
    {|
fn main() =
  let xs = [1]
  if xs then print(1) else ()
  let o = Some(1)
  if o then print(1) else ()
  if not xs.len() then print(1) else ()
|};
  [%expect
    {|
    error: expected `Bool`, found `Array<Int>`
      ┌─ test.ren:3:6
    3 │   if xs then print(1) else ()
      │      ^^
      = an `if` condition has to be a `Bool`
      help: to ask whether it has anything in it, write `xs.len() > 0`

    error: expected `Bool`, found `Option<Int>`
      ┌─ test.ren:5:6
    5 │   if o then print(1) else ()
      │      ^
      = an `if` condition has to be a `Bool`
      help: to ask whether it holds a value, write `o.is_some()`, or `match` it to use the value

    error: expected `Bool`, found `Int`
      ┌─ test.ren:6:10
    6 │   if not xs.len() then print(1) else ()
      │          ^^^^^^^^
      = what `not` is applied to has to be a `Bool`
    |}]

let%expect_test "a `Set`, a `Map` and `uniq` keep the first of equal keys" =
  run
    {|
type E = opaque Str
  fn key(self) -> Str = self.lower()
  pub fn of(s: Str) -> E = s

fn main() =
  let xs = [E.of("A"), E.of("a")]
  print(Set.of(xs))
  print(xs.uniq())
  print(xs.tally())
  var m: Map<E, Int> = Map.empty
  &m.set(E.of("A"), 1)
  &m.set(E.of("a"), 2)
  print(m)
  print(Map.of([(E.of("A"), 1), (E.of("a"), 2)]).keys())
|};
  [%expect
    {|
    Set.of([E("A")])
    [E("A")]
    Map.of([(E("A"), 2)])
    Map.of([(E("A"), 2)])
    [E("A")]
    ()
    |}]

(* ---- follow-ups to 9b ---- *)

let%expect_test "a `for` that changes a map's entries says so first" =
  check_error
    {|
fn main() =
  var m = Map.of([("a", 1)])
  for (k, v) in &m
    ()
  var s = Set.of([(1, 2)])
  for (a, b) in &s
    ()
  ()
|};
  [%expect
    {|
    error: a `for` can't change a map's entries in place
      ┌─ test.ren:3:17
    3 │   for (k, v) in &m
      │                 ^^
      help: go over a copy, `for (k, v) in m`, and `&m.set(k, ...)` what changes

    error: a `for` can't change a set's members in place
      ┌─ test.ren:6:17
    6 │   for (a, b) in &s
      │                 ^^
      help: go over a copy, `for x in s`, and `&s.add(...)` what changes
    |}]

let%expect_test "`&` on a method that returns a new value is one error" =
  check_error
    {|
fn main() =
  var xs = [3, 1, 2]
  &xs.sort()
  &xs.len()
  ()
|};
  [%expect
    {|
    error: `sort` doesn't change `xs`
      ┌─ test.ren:3:3
    3 │   &xs.sort()
      │   ^^^^^^^^^^
      help: remove the `&`; `sort` returns a new `Array<Int>`, so keep it: `xs = xs.sort()`

    error: `len` doesn't change `xs`
      ┌─ test.ren:4:3
    4 │   &xs.len()
      │   ^^^^^^^^^
      help: remove the `&`, and use the `Int` it returns
    |}]

let%expect_test "a requirement a key lacks is blamed on the key" =
  check_error
    {|
type Sub = { id: Int, notify: Clock }
fn find(m: Map<Sub, Int>, s: Sub) -> Option<Int> = m.get(s)
fn main() = ()
|};
  [%expect
    {|
    error: `Sub` has no `hash`, which `Map.get` needs
      ┌─ test.ren:2:58
    2 │ fn find(m: Map<Sub, Int>, s: Sub) -> Option<Int> = m.get(s)
      │                                                          ^
      = a type with a function in it has `==` and `hash` only through its `key`
      = the field `notify` of `Sub` has a function in it
      help: give `Sub` a key, which says what makes two the same: `fn key(self) -> K = ...`
    |}]

let%expect_test "a tuple pattern that doesn't fit says how to take it apart" =
  check_error
    {|
fn main() =
  let (a, b, c) = (1, 2)
  let (d, e) = 5
  for (f, g) in [1, 2]
    ()
  for (h, i) in [(1, 2, 3)]
    ()
  ()
|};
  [%expect
    {|
    error: expected a pattern for `(Int, Int)`, but this one is a `(_, _, _)`
      ┌─ test.ren:2:7
    2 │   let (a, b, c) = (1, 2)
      │       ^^^^^^^^^
      help: the tuple has 2 parts, so take it apart with 2: `(a, b)`

    error: expected a pattern for `Int`, but this one is a `(_, _)`
      ┌─ test.ren:3:7
    3 │   let (d, e) = 5
      │       ^^^^^^
      help: `Int` isn't a tuple, so name it whole instead, like `x`

    error: expected a pattern for `Int`, but this one is a `(_, _)`
      ┌─ test.ren:4:7
    4 │   for (f, g) in [1, 2]
      │       ^^^^^^
      help: `Int` isn't a tuple, so name it whole instead, like `x`

    error: expected a pattern for `(Int, Int, Int)`, but this one is a `(_, _)`
      ┌─ test.ren:6:7
    6 │   for (h, i) in [(1, 2, 3)]
      │       ^^^^^^
      help: the tuple has 3 parts, so take it apart with 3: `(h, i, _)`
    |}]

let%expect_test "a condition that isn't a `Bool` says how to ask" =
  check_error
    {|
fn main() =
  let s = "x"
  if s then print(1) else ()
  let o = Some(1)
  assert not o
  let m = Map.of([(1, 2)])
  if m then print(1) else ()
|};
  [%expect
    {|
    error: expected `Bool`, found `Str`
      ┌─ test.ren:3:6
    3 │   if s then print(1) else ()
      │      ^
      = an `if` condition has to be a `Bool`
      help: to ask whether it has anything in it, write `s != ""`

    error: expected `Bool`, found `Option<Int>`
      ┌─ test.ren:5:14
    5 │   assert not o
      │              ^
      = what `not` is applied to has to be a `Bool`
      help: to ask whether it holds a value, write `o.is_some()`, or `match` it to use the value

    error: expected `Bool`, found `Map<Int, Int>`
      ┌─ test.ren:7:6
    7 │   if m then print(1) else ()
      │      ^
      = an `if` condition has to be a `Bool`
      help: to ask whether it has anything in it, write `m.len() > 0`
    |}]

let%expect_test "a failed `assert` pairs two maps' keys by `==`" =
  run_error
    {|
type Email = opaque Str
  fn key(self) -> Str = self.lower()
  pub fn of(s: Str) -> Email = s

fn main() =
  let a = Map.of([(Email.of("ANN@x"), 1), (Email.of("bo@x"), 2)])
  let b = Map.of([(Email.of("ann@x"), 1), (Email.of("BO@x"), 3)])
  assert a == b
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:8:10
    8 │   assert a == b
      │          ^^^^^^
      = left:  Map.of([..., (Email("bo@x"), 2)])
      = right: Map.of([..., (Email("BO@x"), 3)])
    |}];
  run_error
    {|
type Email = opaque Str
  fn key(self) -> Str = self.lower()
  pub fn of(s: Str) -> Email = s

fn main() =
  assert Set.of([Email.of("ANN@x"), Email.of("bo@x")]) == Set.of([Email.of("ann@x"), Email.of("cy@x")])
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:6:10
    6 │   assert Set.of([Email.of("ANN@x"), Email.of("bo@x")]) == Set.of([Email.of("ann@x"), Email.of("cy@x")])
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = left:  Set.of([..., Email("bo@x")])
      = right: Set.of([..., Email("cy@x")])
    |}]

let%expect_test "what makes the prelude's values isn't a program's" =
  check_error
    {|
fn main() =
  let m: Map<Int, Int> = map_empty()
  let s: Set<Int> = set_empty()
  ()
|};
  [%expect
    {|
    error: there's no function named `map_empty`
      ┌─ test.ren:2:26
    2 │   let m: Map<Int, Int> = map_empty()
      │                          ^^^^^^^^^

    error: there's no function named `set_empty`
      ┌─ test.ren:3:21
    3 │   let s: Set<Int> = set_empty()
      │                     ^^^^^^^^^
    |}]
