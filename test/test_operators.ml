(* Operators, `key`, derived `==` and ordering, and `with numeric`
   (operators.md, stage 9a): an operator is a method with a reserved name,
   found on its left side's type and chosen by its right side's; equality,
   hashing and ordering are derived, and changed only through `key`; and a
   `with numeric` type has its arithmetic without writing it. *)

open Helpers

(* ---- operators are methods ---- *)

let vec =
  {|
pub type Vec = { x: Int, y: Int }
  pub fn add(self, b: Vec) -> Vec = Vec { x: self.x + b.x, y: self.y + b.y }
  pub fn mul(self, k: Int) -> Vec = Vec { x: self.x * k, y: self.y * k }
  pub fn neg(self) -> Vec = Vec { x: -self.x, y: -self.y }
  pub let zero: Vec = Vec { x: 0, y: 0 }
|}

let%expect_test "the spec's Vec: `+`, `*` by an Int, `-v` and `Vec.zero`" =
  run
    (vec
   ^ {|
fn main() uses Console =
  let a = Vec { x: 1, y: 2 }
  print(a + Vec { x: 10, y: 20 })
  print(a * 3)
  print(-a)
  print(Vec.zero + a == a)
  var v = Vec.zero
  v += a
  v += a
  print(v)
  print(a.add(a))
|}
    );
  [%expect
    {|
    Vec { x: 11, y: 22 }
    Vec { x: 3, y: 6 }
    Vec { x: -1, y: -2 }
    true
    Vec { x: 2, y: 4 }
    Vec { x: 2, y: 4 }
    ()
    |}]

let%expect_test "Time's overloads are chosen by the right side's type" =
  run
    {|
fn main() uses Console =
  let start = Time.epoch + Duration.seconds(30)
  let later = start + Duration.minutes(1)
  print(later - start)
  print(later - Duration.seconds(30))
  print(later.sub(start))
  print(later.sub(Duration.ms(1)))
  var t = later
  t -= Duration.seconds(90)
  print(t == Time.epoch)
  print(start < later)
|};
  [%expect
    {|
    Duration(60000)
    Time(60000)
    Duration(60000)
    Time(89999)
    true
    true
    ()
    |}]

let%expect_test "an operator is found on its left side's type only" =
  check_error
    {|
fn main() =
  let now = Time.epoch
  let t = Duration.seconds(5) + now
  let u = Duration.seconds(5) - now
  ()
|};
  [%expect
    {|
    error: `Duration` has no `+` that takes a `Time`
      ┌─ test.ren:3:11
    3 │   let t = Duration.seconds(5) + now
      │           ^^^^^^^^^^^^^^^^^^^^^^^^^
      = `+` is found on its left side's type, `Duration`
      help: write it the other way round: `now + Duration.seconds(5)`

    error: `Duration` has no `-` that takes a `Time`
      ┌─ test.ren:4:11
    4 │   let u = Duration.seconds(5) - now
      │           ^^^^^^^^^^^^^^^^^^^^^^^^^
      = `-` is found on its left side's type, `Duration`
    |}]

let%expect_test "a type with no such operator" =
  check_error {|
fn main() =
  let a = true + false
  let b = "a" + "b"
  ()
|};
  [%expect
    {|
    error: `Bool` has no `+`
      ┌─ test.ren:2:11
    2 │   let a = true + false
      │           ^^^^^^^^^^^^

    error: `Str` has no `+`
      ┌─ test.ren:3:11
    3 │   let b = "a" + "b"
      │           ^^^^^^^^^
      help: join two strings with `a.concat(b)`
    |}]

let%expect_test "two operators that take the same type can't be told apart" =
  check_error
    {|
pub type Span = opaque Int
  pub fn sub(self, d: Duration) -> Span = self - d.in_ms()
  pub fn sub(self, e: Duration) -> Span = self + e.in_ms()
fn main() = ()
|};
  [%expect
    {|
    error: `Span` has two `-` that take a `Duration`
      ┌─ test.ren:3:10
    2 │   pub fn sub(self, d: Duration) -> Span = self - d.in_ms()
      │          --- the first is here
    3 │   pub fn sub(self, e: Duration) -> Span = self + e.in_ms()
      │          ^^^
      help: remove one of them
    |}]

let%expect_test "only an operator can be written more than once" =
  check_error
    {|
type T = { n: Int }
  fn get(self) -> Int = self.n
  fn get(self) -> Int = 0
fn main() = ()
|};
  [%expect
    {|
    error: `T` has two members named `get`
      ┌─ test.ren:3:6
    2 │   fn get(self) -> Int = self.n
      │      --- the first `get` is here
    3 │   fn get(self) -> Int = 0
      │      ^^^
      help: rename one of them
    |}]

let%expect_test "an overloaded operator used before it's checked" =
  (* `main` comes first, so `Tick.add` isn't checked yet when it's
     used: the call graph learns of it, as it does for a dot call *)
  run
    {|
fn main() uses Console =
  let t = Tick.of(1) + Step.of(2)
  print(t + Tick.of(3))
  print(t - Step.of(1))
pub type Tick = { n: Int }
  pub fn of(n: Int) -> Tick = Tick { n }
  pub fn add(self, s: Step) -> Tick = Tick { n: self.n + s.n }
  pub fn add(self, t: Tick) -> Tick = Tick { n: self.n + t.n }
  pub fn sub(self, s: Step) -> Tick = Tick { n: self.n - s.n }
pub type Step = { n: Int }
  pub fn of(n: Int) -> Step = Step { n }
|};
  [%expect {|
    Tick { n: 6 }
    Tick { n: 2 }
    ()
    |}]

let%expect_test "an operator's right side has to be known to choose" =
  check_error {|
fn f(t: Time, x) = t - x
fn main() = ()
|};
  [%expect
    {|
    error: can't tell which `-` of `Time` this is: the right side's type isn't known yet
      ┌─ test.ren:1:20
    1 │ fn f(t: Time, x) = t - x
      │                    ^^^^^
      help: say what the right side is, with a type on the variable it's in
    |}]

let%expect_test "`x op= v` puts back what the operator makes" =
  check_error {|
fn main() =
  var t = Time.epoch
  t -= Time.epoch
  ()
|};
  [%expect
    {|
    error: `t -= Time.epoch` makes a `Duration`, not a `Time`
      ┌─ test.ren:3:3
    3 │   t -= Time.epoch
      │   ^^^^^^^^^^^^^^^
    |}]

(* ---- reserved members ---- *)

let%expect_test "a reserved member's signature is written in full" =
  check_error
    {|
pub type Bag = { items: Array<Int> }
  pub fn add(inout self, b: Bag) -> Bag = b
  pub fn sub(self, b) -> Bag = self
  pub fn mul(self, b: Bag) -> Bag ! Overflow = self
  pub fn show(self) -> Str uses Console = "bag"
  pub fn eq(self, b: Bag) -> Bool = true
  pub fn neg(self, b: Bag) -> Bag = self
  pub let zero = Bag { items: [] }
  fn rem(self, b: Bag) -> Bag = self
  pub let one: Int = 1
pub type V = { x: Int }
  pub fn show(self) -> Int = 1
fn main() = ()
|};
  [%expect
    {|
    error: `add` is reserved for `+`, so it can't change `self`
      ┌─ test.ren:2:10
    2 │   pub fn add(inout self, b: Bag) -> Bag = b
      │          ^^^
      help: write `pub fn add(self, b: Bag) -> Bag = ...`

    error: `sub` is reserved for `-`, so its signature is written in full
      ┌─ test.ren:3:10
    3 │   pub fn sub(self, b) -> Bag = self
      │          ^^^
      help: write `pub fn sub(self, b: Bag) -> Bag = ...`

    error: `mul` is reserved for `*`, so it can't fail
      ┌─ test.ren:4:10
    4 │   pub fn mul(self, b: Bag) -> Bag ! Overflow = self
      │          ^^^
      help: write `pub fn mul(self, b: Bag) -> Bag = ...`

    error: `show` is reserved for how a value is shown, so it can't use a dependency
      ┌─ test.ren:5:10
    5 │   pub fn show(self) -> Str uses Console = "bag"
      │          ^^^^
      help: write `pub fn show(self) -> Str = ...`

    error: `eq` can't be written: what equal means comes from `key`
      ┌─ test.ren:6:10
    6 │   pub fn eq(self, b: Bag) -> Bool = true
      │          ^^
      help: write `fn key(self) -> K = ...`

    error: `neg` is reserved for `-a`, so it takes only `self`
      ┌─ test.ren:7:10
    7 │   pub fn neg(self, b: Bag) -> Bag = self
      │          ^^^
      help: write `pub fn neg(self) -> Bag = ...`

    error: `zero` is reserved for an associated value, so its type is written
      ┌─ test.ren:8:11
    8 │   pub let zero = Bag { items: [] }
      │           ^^^^
      help: write `pub let zero: Bag = ...`

    error: `rem` of the public type `Bag` has to be public
      ┌─ test.ren:9:6
    9 │   fn rem(self, b: Bag) -> Bag = self
      │      ^^^
      = it says what `%` does in every module that uses `Bag`
      help: write `pub fn`

    error: `one` is reserved for an associated value, so it's a `Bag`
       ┌─ test.ren:10:11
    10 │   pub let one: Int = 1
       │           ^^^
       help: write `pub let one: Bag = ...`

    error: `show` is reserved for how a value is shown, so it makes a `Str`
       ┌─ test.ren:12:10
    12 │   pub fn show(self) -> Int = 1
       │          ^^^^
       help: write `pub fn show(self) -> Str = ...`
    |}]

let%expect_test "an operator's body can't fail or use a dependency" =
  check_error
    {|
type Bag = { n: Int }
  fn add(self, b: Bag) -> Bag =
    print("adding")
    Bag { n: self.n + b.n }
  fn key(self) -> Int = try check(self.n)
fn check(n: Int) -> Int =
  if n < 0 then fail Negative(n)
  n
fn main() = ()
|};
  [%expect
    {|
    error: `add` can't use a dependency, but it uses `Console`
      ┌─ test.ren:2:6
    2 │   fn add(self, b: Bag) -> Bag =
      │      ^^^
      = an operator has no `try` in front, so it can't fail or use anything

    error: `key` can't fail, but it can fail with `Negative`
      ┌─ test.ren:5:6
    5 │   fn key(self) -> Int = try check(self.n)
      │      ^^^
      = a key runs wherever two values are compared
    |}]

(* ---- generic code ---- *)

let sum =
  {|
pub fn sum<T>(xs: Array<T>) -> T =
  var acc = T.zero
  for x in xs
    acc = acc + x
  acc
|}

let%expect_test "a generic `sum` needs `add` and `zero` of its `T`" =
  types (sum ^ "fn main() = ()\n");
  [%expect
    {|
    pub fn sum<T has add, zero>(xs: Array<T>) -> T
    fn main()
    |}];
  run
    (sum
   ^ {|
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n * 100

fn main() uses Console =
  print(sum([1, 2]))
  print(sum([1.5, 2.5]))
  print(sum([Money.dollars(1), Money.dollars(2)]))
  print(sum([Duration.seconds(1), Duration.ms(5)]))
|}
    );
  [%expect {|
    3
    4.0
    Money(300)
    Duration(1005)
    ()
    |}]

let%expect_test "a type without what a generic function needs" =
  check_error (sum ^ {|
fn main() =
  let _ = sum([true, false])
  ()
|});
  [%expect
    {|
    error: `Bool` has no `+`, which `sum` needs
      ┌─ test.ren:8:15
    8 │   let _ = sum([true, false])
      │               ^^^^^^^^^^^^^
      = `sum` uses `+` on its `T` (test.ren:4)
    |}]

let%expect_test "a function has no `==`" =
  check_error
    {|
fn same<T>(a: T, b: T) -> Bool = a == b
fn inc(n: Int) -> Int = n + 1
fn main() =
  let _ = same(inc, inc)
  let _ = inc == inc
  ()
|};
  [%expect
    {|
    error: `fn(Int) -> Int` has no `==`, which `same` needs
      ┌─ test.ren:4:16
    4 │   let _ = same(inc, inc)
      │                ^^^
      = a type with a function in it has no `==` or `hash`
      help: give `same` something it can compare, without a function in it

    error: `fn(Int) -> Int` has no `==`
      ┌─ test.ren:5:11
    5 │   let _ = inc == inc
      │           ^^^^^^^^^^
      = a type with a function in it has no `==` or `hash`
      help: a function can't be compared: compare what it returns instead
    |}]

let%expect_test "an unwritten type becomes generic over what it needs" =
  types
    {|
fn twice(x) = x + x
fn negate(x) = -x
fn less(a, b) = a < b
fn inc(x) = x + 1
fn main() = ()
|};
  [%expect
    {|
    fn twice<T has add>(x: T) -> T
    fn negate<T has neg>(x: T) -> T
    fn less<T has ord>(a: T, b: T) -> Bool
    fn inc(x: Int) -> Int
    fn main()
    |}]

let%expect_test "through a type parameter, only `zero` and `one`" =
  check_error {|
fn f<T>(x: T) -> T = T.empty
fn main() = ()
|};
  [%expect
    {|
    error: through a type parameter, only `zero` and `one` can be reached
      ┌─ test.ren:1:24
    1 │ fn f<T>(x: T) -> T = T.empty
      │                        ^^^^^
      = `T` stands for whatever type the function's given
      help: call a function that takes it, or give the function a parameter
    |}]

let%expect_test "`T.one`, and `Int`'s and `Float`'s `zero` and `one`" =
  run
    {|
fn count<T>(xs: Array<T>) -> T =
  var n = T.zero
  for _ in xs
    n = n + T.one
  n
fn main() uses Console =
  print(count([1, 1, 1]))
  print(count([0.5, 0.5]))
  print(Int.zero + Int.one)
  print(Float.one)
|};
  [%expect {|
    3
    2.0
    1
    1.0
    ()
    |}]

let%expect_test "an associated value can't need something of its `T`" =
  check_error
    {|
pub type Box<T> = { v: T }
  pub let start: Box<T> = Box { v: T.zero }
fn main() = ()
|};
  [%expect
    {|
    error: the associated value `Box.start` can't use `zero` of a type parameter
      ┌─ test.ren:2:11
    2 │   pub let start: Box<T> = Box { v: T.zero }
      │           ^^^^^
      = an associated value is made once, before anything says what `T` is
      help: make it a function, which is given its types each time it's called
    |}]

let%expect_test "a type's operator needs of its parameters" =
  run
    {|
pub type Pair<T> = { a: T, b: T }
  pub fn add(self, o: Pair<T>) -> Pair<T> = Pair { a: self.a + o.a, b: self.b + o.b }
  pub fn neg(self) -> Pair<T> = Pair { a: -self.a, b: -self.b }
fn total<T>(xs: Array<T>, start: T) -> T =
  var acc = start
  for x in xs
    acc = acc + x
  acc
fn main() uses Console =
  let p = Pair { a: 1, b: 2 }
  print(total([p, p, p], p))
  print(-Pair { a: 1.5, b: 0.0 })
|};
  [%expect
    {|
    Pair { a: 4, b: 8 }
    Pair { a: -1.5, b: -0.0 }
    ()
    |}]

let%expect_test "operators in Core: through a dictionary, or the language's" =
  core ~types:true
    {|
fn twice<T>(x: T) -> T = x + x
fn less<T>(a: T, b: T) -> Bool = a < b
fn none<T>(x: T) -> T = T.zero
fn main() uses Console =
  print(twice(1))
  print(less("a", "b"))
  print(none(Duration.ms(1)))
|};
  [%expect
    {|
    (fn twice : fn(T) -> T ! ..e uses ..d (needs (add T)) (x/1) ev/2
      (+ (add T) x/1 x/1))
    (fn less : fn(T, T) -> Bool ! ..e uses ..d (needs (ord T)) (a/1 b/2) ev/3
      (< (ord T) a/1 b/2))
    (fn none : fn(T) -> T ! ..e uses ..d (needs (zero T)) (x/1) ev/2 (zero T))
    (fn main : fn() ! ..e uses Console, ..d () ev/1
      (seq
        (call ev/1 (inst print Int {} {..d})
          (call ev/1 (inst twice Int {} {Console | ..d} (add Int)) 1))
        (seq
          (call ev/1 (inst print Bool {} {..d})
            (call ev/1 (inst less Str {} {Console | ..d} (ord Str)) "a" "b"))
          (call ev/1 (inst print Duration {} {..d})
            (call ev/1 (inst none Duration {} {Console | ..d} (zero Duration))
              (call ev/1 (inst Duration.ms {} {Console | ..d}) 1))))))
    (fn $start : fn() ! ..e () ev/1
      (with ev/2 (extend ev/1 Console Console.real)
        (call ev/2 (inst main {..e} {..r}))))
    |}]

(* ---- `key` ---- *)

let email =
  {|
pub type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  pub fn key(self) -> Str = self.lower()
|}

let%expect_test "the spec's Email is equal by its lowercase" =
  run
    (email
   ^ {|
fn main() uses Console =
  let a = Email.of("Ann@Example.com")
  let b = Email.of("ann@example.com")
  assert a == b
  print(a != b)
  print(a != Email.of("bob@example.com"))
  print(Email.of("B") < Email.of("a"))
  print([a])
|}
    );
  [%expect
    {|
    false
    true
    false
    [Email("Ann@Example.com")]
    ()
    |}]

let%expect_test "an error an error set's tail brings in is equal by its key" =
  (* in `same`, nothing says what `Bad` holds but the error itself: it
     carries its payload's types (Core.Tag), so its `Email` goes through
     the key, as it does where the set is written *)
  run
    (email
   ^ {|
  pub fn show(self) -> Str = "<".concat(self).concat(">")
fn same(f, g) = attempt f() == attempt g()
fn shown(f) uses Console = print(attempt f())
fn a() -> Int ! Bad(e: Email) = fail Bad(Email.of("A"))
fn b() -> Int ! Bad(e: Email) = fail Bad(Email.of("a"))
fn main() uses Console =
  print(same(a, b))
  print(attempt a() == attempt b())
  shown(a)
|}
    );
  [%expect {|
    true
    true
    Err(Bad(<A>))
    ()
    |}]

let%expect_test "a key across modules" =
  run_files
    [
      ( "main.ren",
        {|
import email.{Email}
fn main() uses Console =
  print(Email.of("A@B") == Email.of("a@b"))
  print([Email.of("b"), Email.of("A")].len())
|}
      );
      ("email.ren", email);
    ];
  [%expect {|
    true
    2
    ()
    |}]

let%expect_test "a private key orders and compares in every module" =
  (* only its own module can call it: `Instant` means nothing on its own *)
  let files rest =
    [
      ( "main.ren",
        {|
import email.{Email}
fn main() uses Console, Clock =
  let t = Clock.now()
  print(Email.of("b") > Email.of("A"))
  print(t + Duration.seconds(1) > t)
|}
        ^ rest );
      ( "email.ren",
        {|
pub type Email = opaque Str
  pub fn of(s: Str) -> Email = s
  fn key(self) -> Str = self.lower()
|}
      );
    ]
  in
  run_files (files "");
  [%expect {|
    true
    true
    ()
    |}];
  run_files (files "  print(Email.of(\"x\").key())\n  print(t.key())\n");
  [%expect
    {|
    error: `Email` has no public `key`
      ┌─ main.ren:6:23
    6 │   print(Email.of("x").key())
      │                       ^^^
      help: if it's defined in `email`, mark it `pub`

    error: `Time` has no method named `key`
      ┌─ main.ren:7:11
    7 │   print(t.key())
      │           ^^^
      help: its methods: `add`, `sub`
    |}]

let%expect_test "a record is ordered only by its key" =
  check_error
    {|
type User = { name: Str, joined: Int }
fn main() =
  let a = User { name: "a", joined: 1 }
  let _ = a < a
  ()
|};
  [%expect
    {|
    error: `User` has no `<`
      ┌─ test.ren:4:11
    4 │   let _ = a < a
      │           ^^^^^
      = a record is ordered only by its `key`, so that reordering its fields can't change a sort
      help: give `User` a key: `fn key(self) -> K = ...`
    |}];
  run
    {|
type User = { name: Str, joined: Int }
  fn key(self) -> Int = self.joined
type Light =
  | Red
  | Amber
  | Green
fn main() uses Console =
  let a = User { name: "b", joined: 1 }
  let b = User { name: "a", joined: 2 }
  print(a < b)
  print(a == User { name: "c", joined: 1 })
  print(Red < Green)
  print(Green <= Amber)
  print("abc" < "abd")
  print(false < true)
  print(-0.0 == 0.0)
|};
  [%expect
    {|
    true
    true
    true
    false
    true
    true
    true
    ()
    |}]

let%expect_test "a key with a function in it makes `==` an error" =
  check_error
    {|
type F = { f: fn(Int) -> Int }
  fn key(self) -> fn(Int) -> Int = self.f
fn main() =
  let a = F { f: fn(n) => n }
  let _ = a == a
  ()
|};
  [%expect
    {|
    error: `F` has no `==`
      ┌─ test.ren:5:11
    5 │   let _ = a == a
      │           ^^^^^^
      = a type with a function in it has no `==` or `hash`
      = it has `fn(Int) -> Int` in it
      help: compare the parts of it that have no function in them
    |}]

let%expect_test "a key that needs its `T`'s order passes it on" =
  types
    {|
type Box<T> = { v: T, note: Str }
  fn key(self) -> T = self.v
fn first<T>(a: Box<T>, b: Box<T>) -> Bool = a < b
fn main() = ()
|};
  [%expect
    {|
    type Box<T>
      fn key(self) -> T
    fn first<T has ord>(a: Box<T>, b: Box<T>) -> Bool
    fn main()
    |}]

(* ---- `with numeric` ---- *)

let money =
  {|
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n * 100
  pub fn cents(self) -> Int = self
|}

(* In its own module an opaque type is what it's represented as, so the
   spec's examples use it from another *)
let%expect_test "the spec's Money" =
  run_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  let price = Money.dollars(5)
  let shipping = Money.dollars(2)
  let discount = Money.dollars(1)
  let total = price * 3 + shipping - discount
  print(total)
  print(total > Money.dollars(10))
  print(-total)
  print(Money.zero)
  print(total - total == Money.zero)
  var m = Money.zero
  m += total
  m -= Money.dollars(1)
  print(m.cents())
|}
      );
      ("money.ren", money);
    ];
  [%expect
    {|
    Money(1600)
    true
    Money(-1600)
    Money(0)
    true
    1500
    ()
    |}]

let%expect_test "what `with numeric` doesn't give" =
  check_error_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() =
  let price = Money.dollars(5)
  let sq = price * price
  let half = price / 2
  let m: Money = 5
  ()
|}
      );
      ("money.ren", money);
    ];
  [%expect
    {|
    error: `Money` has no `*` that takes a `Money`
      ┌─ main.ren:4:12
    4 │   let sq = price * price
      │            ^^^^^^^^^^^^^
      = `with numeric` gives `Money` `*` only by an `Int`, so `Money * Money` isn't a `Money`
      help: if it's a product, write it on `Money`: `pub fn mul(self, b: Money) -> Area = ...`

    error: `Money` has no `/`
      ┌─ main.ren:5:14
    5 │   let half = price / 2
      │              ^^^^^^^^^
      = `with numeric` gives no `/`: a division says how it rounds
      help: write it on `Money`: `pub fn div(self, n: Int) -> Money = ...`

    error: expected `Money`, found `Int`
      ┌─ main.ren:6:18
    6 │   let m: Money = 5
      │                  ^
      = `Money`'s representation is private to `money`
      help: use a function from `money` to make or read one
    |}]

let%expect_test "`with numeric` is for an opaque number, and gives its own" =
  check_error
    {|
pub type Name = opaque Str with numeric
pub type Money = opaque Int with numeric
  pub fn add(self, b: Money) -> Money = self
  pub let zero: Money = 0
  pub fn key(self) -> Int = self
fn main() = ()
|};
  [%expect
    {|
    error: `with numeric` is for an opaque `Int` or `Float`
      ┌─ test.ren:1:33
    1 │ pub type Name = opaque Str with numeric
      │                                 ^^^^^^^
      help: write it by hand: `pub fn add(self, b: ...)`

    error: `with numeric` gives `Money` its `+` already
      ┌─ test.ren:3:10
    3 │   pub fn add(self, b: Money) -> Money = self
      │          ^^^
      help: remove `add`

    error: `with numeric` gives `Money` its `zero` already
      ┌─ test.ren:4:11
    4 │   pub let zero: Money = 0
      │           ^^^^
      help: remove `zero`

    error: `with numeric` gives `Money` its `==` and its order already
      ┌─ test.ren:5:10
    5 │   pub fn key(self) -> Int = self
      │          ^^^
      help: remove `key`
    |}];
  check_error {|
pub type Odd = opaque Int with sums
fn main() = ()
|};
  [%expect
    {|
    error: an opaque type can only be `with numeric`
      ┌─ test.ren:1:32
    1 │ pub type Odd = opaque Int with sums
      │                                ^^^^
      help: write `opaque Int with numeric`
    |}]

let%expect_test "an opaque Float with numeric, and a `*` it writes" =
  (* inside its module a `Meters` is a `Float`, so `self * b` there is
     two `Float`s *)
  run_files
    [
      ( "main.ren",
        {|
import meters.{Meters}
fn main() uses Console =
  print(Meters.of(1.5) * 2.0 + Meters.of(0.25))
  print(Meters.of(2.0) * Meters.of(3.0))
  print(Meters.of(2.0) * 3.0 < Meters.of(6.5))
|}
      );
      ( "meters.ren",
        {|
pub type Meters = opaque Float with numeric
  pub fn of(f: Float) -> Meters = f
  pub fn mul(self, b: Meters) -> Area = Area.of(self * b)
pub type Area = opaque Float
  pub fn of(f: Float) -> Area = f
|}
      );
    ];
  [%expect {|
    Meters(3.25)
    Area(6.0)
    true
    ()
    |}]

let%expect_test "a numeric type from another module" =
  run_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  let m = Money.dollars(2) * 3 - Money.zero
  print(m)
  print(m > Money.dollars(5))
|}
      );
      ("money.ren", money);
    ];
  [%expect {|
    Money(600)
    true
    ()
    |}];
  types_files
    [
      ("main.ren", {|
import money.{Money}
fn main() = Money.zero
|});
      ("money.ren", money);
    ];
  [%expect
    {|
    -- money
    pub type Money with numeric
      pub fn dollars(n: Int) -> Money
      pub fn cents(self) -> Int

    -- main
    fn main() -> Money
    |}]

let%expect_test "a numeric type overflows as its representation does" =
  run_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  let m = Money.dollars(92233720368547758)
  print(m + m)
|}
      );
      ("money.ren", money);
    ];
  [%expect
    {|
    error: panic: `+` overflowed: 9223372036854775800 + 9223372036854775800
      ┌─ main.ren:4:9
    4 │   print(m + m)
      │         ^^^^^
    |}]

let%expect_test "another module's function says what it needs in its interface"
    =
  types_files
    [
      ("main.ren", {|
import util
fn main() = util.sum([1, 2])
|});
      ("util.ren", sum);
    ];
  [%expect
    {|
    -- util
    pub fn sum<T has add, zero>(xs: Array<T>) -> T

    -- main
    fn main() -> Int
    |}];
  check_error_files
    [
      ("main.ren", {|
import util
fn main() =
  let _ = util.sum(["a"])
  ()
|});
      ("util.ren", sum);
    ];
  [%expect
    {|
    error: `Str` has no `+`, which `sum` needs
      ┌─ main.ren:3:20
    3 │   let _ = util.sum(["a"])
      │                    ^^^^^
      = `sum` uses `+` on its `T`
      help: join two strings with `a.concat(b)`
    |}]

(* ---- found in review ---- *)

(* An operator a type writes is found in its own module too, as in any
   other, and the representation's only where none takes the right side;
   inside the type's own members it's the representation's. *)
let%expect_test "an opaque type's own operator is found in its own module" =
  run
    {|
pub type T2 = opaque Int
  pub fn of(n: Int) -> T2 = n
  pub fn add(self, b: Int) -> T2 = 100
  pub fn add(self, b: Float) -> T2 = self + 7
fn main() uses Console =
  print(T2.of(1) + 2)
  print(T2.of(1) + 2.5)
|};
  [%expect {|
    T2(100)
    T2(8)
    ()
    |}]

let%expect_test "a `with numeric` type's arithmetic in its own module" =
  run
    (money
   ^ {|
fn main() uses Console =
  let price = Money.dollars(5)
  print(price)
  print(price * 3)
  print([price + price])
  print(-price)
|}
    );
  [%expect
    {|
    Money(500)
    Money(1500)
    [Money(1000)]
    Money(-500)
    ()
    |}]

let%expect_test "a key that leads back to its own type is an error" =
  check_error
    {|
type W = { a: Int }
  pub fn key(self) -> W = self
type A = { a: Int }
  pub fn key(self) -> B = B { b: self.a }
type B = { b: Int }
  pub fn key(self) -> Array<A> = [A { a: self.b }]
fn main() =
  let _ = W { a: 1 } == W { a: 1 }
  let _ = A { a: 1 } < A { a: 2 }
  ()
|};
  [%expect
    {|
    error: the key of `W` leads back to `W`
      ┌─ test.ren:2:10
    2 │   pub fn key(self) -> W = self
      │          ^^^
      = two `W`s are compared by their keys, so comparing those would compare `W`s again, and never end
      help: make the key of what's in it, its fields, rather than itself

    error: the key of `A` leads back to `A`
      ┌─ test.ren:4:10
    4 │   pub fn key(self) -> B = B { b: self.a }
      │          ^^^
      = two `A`s are compared by their keys, so comparing those would compare `A`s again, and never end
      help: make the key of what's in it, its fields, rather than itself

    error: the key of `B` leads back to `B`
      ┌─ test.ren:6:10
    6 │   pub fn key(self) -> Array<A> = [A { a: self.b }]
      │          ^^^
      = two `B`s are compared by their keys, so comparing those would compare `B`s again, and never end
      help: make the key of what's in it, its fields, rather than itself
    |}]

let%expect_test "a key whose type has no order" =
  check_error
    {|
pub type In = { a: Int }
pub type P = { a: Int }
  pub fn key(self) -> In = In { a: self.a }
fn main() =
  let _ = P { a: 1 } < P { a: 2 }
  ()
|};
  [%expect
    {|
    error: `P` has no `<`
      ┌─ test.ren:5:11
    5 │   let _ = P { a: 1 } < P { a: 2 }
      │           ^^^^^^^^^^^^^^^^^^^^^^^
      = `P` is ordered by its key, an `In`, which has no order
      help: make `P`'s key something ordered, such as an `Int` or a `Str`
    |}]

let%expect_test "`/` on a numeric Float says to take a Float" =
  check_error_files
    [
      ( "main.ren",
        {|
import meters.{Meters}
fn main() =
  let _ = Meters.of(1.0) / 2.0
  ()
|}
      );
      ( "meters.ren",
        {|
pub type Meters = opaque Float with numeric
  pub fn of(x: Float) -> Meters = x
|}
      );
    ];
  [%expect
    {|
    error: `Meters` has no `/`
      ┌─ main.ren:3:11
    3 │   let _ = Meters.of(1.0) / 2.0
      │           ^^^^^^^^^^^^^^^^^^^^
      = `with numeric` gives no `/`: a division says how it rounds
      help: write it on `Meters`: `pub fn div(self, n: Float) -> Meters = ...`
    |}]

let%expect_test "an overflow's help names a method only an `Int` has" =
  run_error
    {|
fn ad<T>(a: T, b: T) -> T = a + b
fn main() =
  print(ad(9223372036854775807, 1))
|};
  [%expect
    {|
    error: panic: `+` overflowed: 9223372036854775807 + 1
      ┌─ test.ren:1:29
    1 │ fn ad<T>(a: T, b: T) -> T = a + b
      │                             ^^^^^
    |}];
  run_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  print(Money.dollars(92233720368547758) * 2)
|}
      );
      ("money.ren", money);
    ];
  [%expect
    {|
    error: panic: `*` overflowed: 9223372036854775800 * 2
      ┌─ main.ren:3:9
    3 │   print(Money.dollars(92233720368547758) * 2)
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "an overloaded operator can't be named by its type" =
  check_error
    {|
type V = { x: Int }
  pub fn add(self, k: Int) -> V = V { x: self.x + k }
  pub fn add(self, b: V) -> V = V { x: self.x + b.x }
fn main() =
  let g = V.add
  let _ = g(V { x: 1 }, 2)
  ()
|};
  [%expect
    {|
    error: `V.add` can't say which `add` it is
      ┌─ test.ren:5:13
    5 │   let g = V.add
      │             ^^^
      = `V.add` is written for more than one type on its right
      help: write it as an operator, `a + b`, or `a.add(b)`
    |}]

(* ---- what an error says ---- *)

let%expect_test "a type whose operator takes another type, in generic code" =
  check_error
    {|
pub type R = { k: Int }
  pub fn add(self, k: Int) -> R = R { k: self.k + k }
pub fn plus<T>(a: T, b: T) -> T = a + b
fn main() =
  let _ = plus(Time.epoch, Time.epoch)
  let _ = plus(R { k: 1 }, R { k: 2 })
  ()
|};
  [%expect
    {|
    error: `Time` has no `+` that takes a `Time`, which `plus` needs
      ┌─ test.ren:5:16
    5 │   let _ = plus(Time.epoch, Time.epoch)
      │                ^^^^^^^^^^
      = `plus` uses `+` on its `T` (test.ren:3)
      = in generic code, `+` takes the same type on both sides and makes it

    error: `R` has no `+` that takes a `R`, which `plus` needs
      ┌─ test.ren:6:16
    6 │   let _ = plus(R { k: 1 }, R { k: 2 })
      │                ^^^^^^^^^^
      = `plus` uses `+` on its `T` (test.ren:3)
      = in generic code, `+` takes the same type on both sides and makes it
    |}]

let%expect_test "an Int compared with a Float" =
  check_error
    {|
fn f(n: Int, x: Float) -> Bool = n < x
fn main() =
  let _ = 1 == 1.5
  ()
|};
  [%expect
    {|
    error: `<` compares two values of the same type, but this is a `Float` and the left side is an `Int`
      ┌─ test.ren:1:38
    1 │ fn f(n: Int, x: Float) -> Bool = n < x
      │                                      ^
      │                                  - this is an `Int`
      = numbers never convert by themselves
      help: convert one: `Float.of(n) < x`

    error: `==` compares two values of the same type, but this is a `Float` and the left side is an `Int`
      ┌─ test.ren:3:16
    3 │   let _ = 1 == 1.5
      │                ^^^
      │           - this is an `Int`
      = numbers never convert by themselves
      help: write it as a `Float`: `1.0 == 1.5`
    |}]

let%expect_test "a prelude sum type with fields has no order" =
  check_error {|
fn main() =
  let _ = Some(1) < None
  ()
|};
  [%expect
    {|
    error: `Option<Int>` has no `<`
      ┌─ test.ren:2:11
    2 │   let _ = Some(1) < None
      │           ^^^^^^^^^^^^^^
      = a sum type with fields is ordered only by its `key`, and `Option` has none
    |}]

let%expect_test "a numeric type's `*` the other way round" =
  check_error_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() =
  let _ = 3 * Money.dollars(2)
  ()
|}
      );
      ( "money.ren",
        {|
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n
|}
      );
    ];
  [%expect
    {|
    error: `Int` has no `*` that takes a `Money`
      ┌─ main.ren:3:11
    3 │   let _ = 3 * Money.dollars(2)
      │           ^^^^^^^^^^^^^^^^^^^^
      = `*` is found on its left side's type, `Int`
      help: write it the other way round: `Money.dollars(2) * 3`
    |}]

(* ---- an Int's and a Float's operators are methods too ---- *)

let%expect_test "`n.add(2)` is `n + 2`, on an Int and a Float" =
  run
    {|
fn main() uses Console =
  print(3.add(2))
  print(3.sub(5))
  print(4.mul(5))
  print(7.div(2))
  print(7.rem(3))
  print((-3).neg())
  print(2.5.mul(2.0))
  print(1.0.div(4.0))
  print(2.5.neg())
|};
  [%expect
    {|
    5
    -2
    20
    3
    1
    3
    5.0
    0.25
    -2.5
    ()
    |}]

let%expect_test "an Int's method overflows as its operator does" =
  run_error
    {|
fn main() uses Console =
  let n = 9223372036854775807
  print(n.add(1))
|};
  [%expect
    {|
    error: panic: `+` overflowed: 9223372036854775807 + 1
      ┌─ test.ren:3:9
    3 │   print(n.add(1))
      │         ^^^^^^^^
    |}]

let%expect_test "an Int's `div` by zero panics as `/` does" =
  run_error {|
fn main() uses Console =
  let zero = 0
  print(7.div(zero))
|};
  [%expect
    {|
    error: panic: division by zero
      ┌─ test.ren:3:9
    3 │   print(7.div(zero))
      │         ^^^^^^^^^^^
    |}]

let%expect_test "a Float's `div` that has no answer panics as `/` does" =
  run_error {|
fn main() uses Console = print(0.0.div(0.0))
|};
  [%expect
    {|
    error: panic: `/` has no answer here: 0.0 / 0.0
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print(0.0.div(0.0))
      │                                ^^^^^^^^^^^^
    |}]

let%expect_test "an Int's `add` takes an Int" =
  check_error {|
fn main() uses Console = print(1.add(2.0))
|};
  [%expect
    {|
    error: expected `Int`, found `Float`
      ┌─ test.ren:1:38
    1 │ fn main() uses Console = print(1.add(2.0))
      │                                      ^^^
    |}]

(* ---- a literal beside a `with numeric` type ---- *)

let units =
  {|
pub type Money = opaque Int with numeric
  pub fn cents(n: Int) -> Money = n
  pub fn dollars(n: Int) -> Money = n * 100
  pub fn of_count(n: Int) -> Int = n
  fn hidden(n: Int) -> Money = n

pub type Weight = opaque Float with numeric
  pub fn kg(x: Float) -> Weight = x

pub type Score = opaque Int with numeric
|}

let%expect_test "`price + 5` says how to make a `Money` of the 5" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Money}
fn main() uses Console =
  let price = Money.cents(5)
  print(price + 5)
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Money` has no `+` that takes an `Int`
      ┌─ main.ren:4:9
    4 │   print(price + 5)
      │         ^^^^^^^^^
      = `+` is found on its left side's type, `Money`
      help: make a `Money` of it: `price + Money.cents(5)` or `price + Money.dollars(5)`
    |}]

let%expect_test "a comparison with a number says how to make a `Money` of it" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Money}
fn main() uses Console = print(Money.cents(1) < 5)
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `<` compares two values of the same type, but this is an `Int` and the left side is a `Money`
      ┌─ main.ren:2:49
    2 │ fn main() uses Console = print(Money.cents(1) < 5)
      │                                                 ^
      │                                -------------- this is a `Money`
      = `Money`'s representation is private to `units`
      help: make a `Money` of it: `Money.cents(1) < Money.cents(5)` or `Money.cents(1) < Money.dollars(5)`
    |}]

let%expect_test "`5 + price` makes a `Money` of the 5, on the left" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Money}
fn main() uses Console = print(5 + Money.cents(1))
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Int` has no `+` that takes a `Money`
      ┌─ main.ren:2:32
    2 │ fn main() uses Console = print(5 + Money.cents(1))
      │                                ^^^^^^^^^^^^^^^^^^
      = `+` is found on its left side's type, `Int`
      help: make a `Money` of it: `Money.cents(5) + Money.cents(1)` or `Money.dollars(5) + Money.cents(1)`
    |}]

let%expect_test "a `+` that takes nothing makes nothing to check further" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Money}
fn b() -> Money = 5 + Money.cents(1)
fn main() = ()
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Int` has no `+` that takes a `Money`
      ┌─ main.ren:2:19
    2 │ fn b() -> Money = 5 + Money.cents(1)
      │                   ^^^^^^^^^^^^^^^^^^
      = `+` is found on its left side's type, `Int`
      help: make a `Money` of it: `Money.cents(5) + Money.cents(1)` or `Money.dollars(5) + Money.cents(1)`
    |}]

let%expect_test "an `Int` that isn't a literal is made a `Money` too" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Money}
fn add(m: Money, k: Int) -> Money = m + k
fn main() = ()
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Money` has no `+` that takes an `Int`
      ┌─ main.ren:2:37
    2 │ fn add(m: Money, k: Int) -> Money = m + k
      │                                     ^^^^^
      = `+` is found on its left side's type, `Money`
      help: make a `Money` of it: `m + Money.cents(k)` or `m + Money.dollars(k)`
    |}]

let%expect_test "a Float one is made of a Float literal" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Weight}
fn main() uses Console =
  let w = Weight.kg(1.5)
  print(w - 2)
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Weight` has no `-` that takes an `Int`
      ┌─ main.ren:4:9
    4 │   print(w - 2)
      │         ^^^^^
      = `-` is found on its left side's type, `Weight`
      help: make a `Weight` of it: `w - Weight.kg(2.0)`
    |}]

let%expect_test "a type with nothing that makes one gets no help" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Score}
fn next(s: Score) -> Score = s + 1
fn main() = ()
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Score` has no `+` that takes an `Int`
      ┌─ main.ren:2:30
    2 │ fn next(s: Score) -> Score = s + 1
      │                              ^^^^^
      = `+` is found on its left side's type, `Score`
    |}]

let%expect_test "a Float one is scaled by a Float, as a Float is" =
  check_error_files
    [
      ( "main.ren",
        {|
import units.{Weight}
fn main() uses Console =
  let w = Weight.kg(1.5)
  print(w * 2)
|}
      );
      ("units.ren", units);
    ];
  [%expect
    {|
    error: `Weight` has no `*` that takes an `Int`
      ┌─ main.ren:4:9
    4 │   print(w * 2)
      │         ^^^^^
      = numbers never convert by themselves
      help: write it as a `Float`: `w * 2.0`
    |}]

let%expect_test "an Int literal given a Float's method is written as a Float" =
  run_error {|
fn main() uses Console =
  print(1.0.add(2))
|};
  [%expect
    {|
    error: expected `Float`, found `Int`
      ┌─ test.ren:2:17
    2 │   print(1.0.add(2))
      │                 ^
      = numbers never convert by themselves
      help: write it as a `Float`: `2.0`
    |}]

let%expect_test "a `with numeric` type's arithmetic is its operators" =
  check_error_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  let a = Money.cents(1)
  print(a.add(Money.cents(2)))
  print(a.neg())
|}
      );
      ( "money.ren",
        {|
pub type Money = opaque Int with numeric
  pub fn cents(n: Int) -> Money = n
|}
      );
    ];
  [%expect
    {|
    error: `Money` has no method `add`
      ┌─ main.ren:4:11
    4 │   print(a.add(Money.cents(2)))
      │           ^^^
      = `with numeric` gives `Money` the operator `+`, not a method
      help: write the operator: `a + Money.cents(2)`

    error: `Money` has no method `neg`
      ┌─ main.ren:5:11
    5 │   print(a.neg())
      │           ^^^
      = `with numeric` gives `Money` the operator `-`, not a method
      help: write the operator: `-a`
    |}]
