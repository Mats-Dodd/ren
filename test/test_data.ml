(* The data stage (language.md §2, §3 and §6; foundations.md, decisions 3
   and 14, and Staging, item 5): this file is the stage's specification,
   as test_tasks.ml was 11a's.

   Each test's name starts with a tag, `[sN accept]` or `[sN reject]`. N is
   the step of the data stage that lands it (compiler.md, "Data stage"):

     s1  record update, record patterns and `let { .. } =`
     s2  variants with several fields by name, one field positional
     s3  or-patterns, `as` and `let ... else`
     s4  variant types, `Order.Placed`
     s5  the errors that teach the model, and `todo`
     s6  descriptions: an operation called only on a stateless handler
     s8  the review's fixes (compiler.md, "Step 8, as built")

   Step 7, the layout fixes, changes no output: its programs are
   bench/data's kernels (bench/build.t), and Mem Lint checks them.

   A test still to land runs through [until] (helpers.ml), which holds
   what the step makes of it: [want], the whole output of a program that
   runs, or [says], the lines an error or a panic has to hold, its
   headline and its help. Its [%expect] holds today's output after
   `(until sN)`. When the program prints what's wanted, the test fails
   until it's turned on: written plainly, with the target in its
   [%expect]. A test whose program works already is written plainly, and
   holds what the step mustn't change. *)

open Helpers

(* ---- s1: record update, record patterns, `let { .. } =` ---- *)

let order_types =
  {|
type Line = { sku: Str, qty: Int }
type Order = { id: Int, lines: Array<Line>, total: Int, paid: Bool }
|}

let%expect_test "[s1 accept] record update takes the rest from a record" =
  run
    (order_types
   ^ {|
fn main() uses Console =
  let o = Order { id: 1, lines: [], total: 5, paid: false }
  print({ ..o, paid: true })
  let id = 2
  print(Order { ..o, id })
  print({ ..o })
|});
  [%expect {|
    Order { id: 1, lines: [], total: 5, paid: true }
    Order { id: 2, lines: [], total: 5, paid: false }
    Order { id: 1, lines: [], total: 5, paid: false }
    ()
    |}]

let%expect_test "[s1 accept] the base, then the fields, in the order they're written" =
  (* `..` is evaluated first, once; the fields after it in their order *)
  run
    {|
type P = { x: Int, y: Int, z: Int }

fn said(what: Str, n: Int) -> Int uses Console =
  print(what)
  n

fn base() -> P uses Console =
  print("base")
  P { x: 1, y: 2, z: 3 }

fn main() uses Console =
  print({ ..base(), y: said("y", 20), x: said("x", 10) })
|};
  [%expect {|
    base
    y
    x
    P { x: 10, y: 20, z: 3 }
    ()
    |}]

let%expect_test "[s1 accept] an update of a unique record changes it in place" =
  (* Perceus reuse: the update in the loop allocates nothing new; what
     shows here is only that it's the same value either way *)
  run
    (order_types
   ^ {|
fn main() uses Console =
  var o = Order { id: 1, lines: [], total: 0, paid: false }
  for i in 0..1000
    o = { ..o, total: o.total + i }
  print(o.total)
|});
  [%expect {|
    499500
    ()
    |}]

let%expect_test "[s1 accept] an update's type is its base's" =
  types
    (order_types
   ^ {|
fn paid(o: Order) -> Order = { ..o, paid: true }
fn renamed(l: Line, sku: Str) -> Line = { ..l, sku }
fn main() = ()
|});
  [%expect {|
    fn paid(o: Order) -> Order
    fn renamed(l: Line, sku: Str) -> Line
    fn main()
    |}]

let%expect_test "[s1 accept] an update across record types, the rest taken by name" =
  run
    {|
type Placed = { id: Int, total: Int }
type Shipped = { id: Int, total: Int, carrier: Str }

fn main() uses Console =
  let p = Placed { id: 1, total: 5 }
  print(Shipped { ..p, carrier: "post" })
|};
  [%expect {|
    Shipped { id: 1, total: 5, carrier: "post" }
    ()
    |}]

let%expect_test "[s1 accept] a record pattern in a match, with literals and `..`" =
  run
    (order_types
   ^ {|
fn state(o: Order) -> Str =
  match o
    { paid: true, total, .. } => "paid ".concat(show(total))
    { lines, .. } => "open ".concat(show(lines.len()))

fn main() uses Console =
  let ls = [Line { sku: "a", qty: 1 }, Line { sku: "b", qty: 2 }]
  print(state(Order { id: 1, lines: [], total: 5, paid: true }))
  print(state(Order { id: 2, lines: ls, total: 0, paid: false }))
|});
  [%expect {|
    paid 5
    open 2
    ()
    |}]

let%expect_test "[s1 accept] a named record pattern, renamed and nested" =
  run
    {|
type Pt = { x: Int, y: Int }
type Seg = { from: Pt, to: Pt }

fn rise(s: Seg) -> Str =
  match s
    Seg { from: Pt { y: 0, .. }, to: Pt { y: top, .. } } => show(top)
    _ => "none"

fn main() uses Console =
  print(rise(Seg { from: Pt { x: 0, y: 0 }, to: Pt { x: 1, y: 3 } }))
  print(rise(Seg { from: Pt { x: 0, y: 1 }, to: Pt { x: 1, y: 3 } }))
|};
  [%expect {|
    3
    none
    ()
    |}]

let%expect_test "[s1 accept] `let { .. } =` takes a record apart" =
  (* a `let` only takes apart, so it may leave fields out (compiler.md,
     "Data stage", "Where the data stage may differ from language.md") *)
  run
    (order_types
   ^ {|
fn main() uses Console =
  let o = Order { id: 1, lines: [Line { sku: "a", qty: 2 }], total: 5, paid: false }
  let { id, total } = o
  print(id)
  print(total)
  let { lines: ls, .. } = o
  let { qty: n, .. } = ls[0]
  print(n)
|});
  [%expect {|
    1
    5
    2
    ()
    |}]

let%expect_test "[s1 accept] a record pattern in a `for` and a block's parameter" =
  run
    (order_types
   ^ {|
fn main() uses Console =
  let ls = [Line { sku: "a", qty: 1 }, Line { sku: "b", qty: 2 }]
  var t = 0
  for { qty, .. } in ls
    t += qty
  print(t)
  print(ls.map(fn({ qty, .. }) => qty))
|});
  [%expect {|
    3
    [1, 2]
    ()
    |}]

let%expect_test "[s1 accept] a named record pattern in a `let`, a `for` and a block's parameter" =
  (* the type named, another module's too *)
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row}
fn main() uses Console =
  let r = Row { id: 1, name: "a" }
  let rows.Row { name, .. } = r
  print(name)
  for Row { id, .. } in [r, { ..r, id: 2 }]
    print(id)
  print([r].map(fn(Row { name: n, .. }) => n))
|}
      );
      ("rows.ren", {|
pub type Row = { id: Int, name: Str }
|});
    ];
  [%expect {|
    a
    1
    2
    ["a"]
    ()
    |}]

let%expect_test "[s1 reject] `..` comes first in a record" =
  check_error
    (order_types ^ {|
fn f(o: Order) -> Order = { paid: true, ..o }
fn main() = ()
|});
  [%expect {|
    error: `..o` comes first, before the fields
      ┌─ test.ren:4:41
    4 │ fn f(o: Order) -> Order = { paid: true, ..o }
      │                                         ^^^
      help: move it to the front: `{ ..o, ... }`
    |}]

let%expect_test "[s1 reject] a record takes the rest from one value" =
  check_error
    (order_types
   ^ {|
fn f(a: Order, b: Order) -> Order = { ..a, ..b, paid: true }
fn main() = ()
|});
  [%expect {|
    error: a record takes the rest from one value
      ┌─ test.ren:4:44
    4 │ fn f(a: Order, b: Order) -> Order = { ..a, ..b, paid: true }
      │                                            ^^^
      help: keep one `..`, and write the other's fields
    |}]

let%expect_test "[s1 reject] `..` in a value needs the value it takes the rest from" =
  check_error (order_types ^ {|
fn f() -> Order = { paid: true, .. }
fn main() = ()
|});
  [%expect {|
    error: `..` in a value takes the rest from another, so it needs one
      ┌─ test.ren:4:33
    4 │ fn f() -> Order = { paid: true, .. }
      │                                 ^^
      help: write the value after it, `{ ..o, paid: true }`, or leave it out
    |}]

let%expect_test "[s1 reject] `..` comes last in a pattern" =
  check_error
    (order_types
   ^ {|
fn f(o: Order) -> Int =
  match o
    { .., id } => id
fn main() = ()
|});
  [%expect {|
    error: `..` comes last in a pattern
      ┌─ test.ren:6:7
    6 │     { .., id } => id
      │       ^^
      help: move it to the end: `{ id, .. }`
    |}]

let%expect_test "[s1 reject] a pattern's `..` takes no name" =
  check_error
    (order_types
   ^ {|
fn f(o: Order) -> Int =
  match o
    { id, ..rest } => id
fn main() = ()
|});
  [%expect {|
    error: a pattern's `..` stands for the fields it leaves out, so it takes no name
      ┌─ test.ren:6:11
    6 │     { id, ..rest } => id
      │           ^^^^^^
      help: bind the whole with `as`: `{ id, .. } as rest`
    |}]

let%expect_test "[s1 reject] an update names a field its record doesn't have" =
  check_error
    (order_types ^ {|
fn f(o: Order) -> Order = { ..o, piad: true }
fn main() = ()
|});
  [%expect {|
    error: `Order` has no field named `piad`
      ┌─ test.ren:4:34
    4 │ fn f(o: Order) -> Order = { ..o, piad: true }
      │                                  ^^^^
      help: did you mean `paid`?
    |}]

let%expect_test "[s1 reject] `..` takes the rest from a record" =
  check_error
    (order_types
   ^ {|
fn f(n: Int) -> Order = Order { ..n, paid: true }
fn main() = ()
|});
  [%expect {|
    error: `..n` takes the rest from a record, but `n` is an `Int`
      ┌─ test.ren:4:35
    4 │ fn f(n: Int) -> Order = Order { ..n, paid: true }
      │                                   ^
      help: write every field, without `..`
    |}]

let%expect_test "[s1 reject] an update's base lacks a field the target needs" =
  check_error
    {|
type Placed = { id: Int, total: Int }
type Shipped = { id: Int, total: Int, carrier: Str }
fn f(p: Placed) -> Shipped = Shipped { ..p }
fn main() = ()
|};
  [%expect {|
    error: `Shipped` needs `carrier`, which `..p` doesn't have
      ┌─ test.ren:3:42
    3 │ fn f(p: Placed) -> Shipped = Shipped { ..p }
      │                                          ^
      help: give it: `carrier: ...`
    |}]

let%expect_test "[s1 reject] an update would drop a field of its base" =
  check_error
    {|
type Placed = { id: Int, total: Int }
type Shipped = { id: Int, total: Int, carrier: Str }
fn f(s: Shipped) -> Placed = Placed { ..s }
fn main() = ()
|};
  [%expect {|
    error: `..s` would drop `carrier`: `Placed` has no field `carrier`
      ┌─ test.ren:3:41
    3 │ fn f(s: Shipped) -> Placed = Placed { ..s }
      │                                         ^
      help: name the fields to keep instead of `..s`
    |}]

let%expect_test "[s1 reject] an update's base has a field of another type" =
  check_error
    {|
type A = { id: Int, total: Str }
type B = { id: Int, total: Int }
fn f(a: A) -> B = B { ..a }
fn main() = ()
|};
  [%expect {|
    error: `..a`'s `total` is a `Str`, but `B`'s `total` is an `Int`
      ┌─ test.ren:3:25
    3 │ fn f(a: A) -> B = B { ..a }
      │                         ^
      help: give it: `total: ...`
    |}]

let%expect_test "[s1 reject] a pattern in a match names every field or ends in `..`" =
  check_error
    (order_types
   ^ {|
fn f(o: Order) -> Int =
  match o
    { id, total, paid } => id
fn main() = ()
|});
  [%expect {|
    error: this pattern doesn't name `lines`; add `lines`, or `..` for the rest
      ┌─ test.ren:6:5
    6 │     { id, total, paid } => id
      │     ^^^^^^^^^^^^^^^^^^^
      help: write `{ id, total, paid, .. }` to leave the rest out
    |}]

let%expect_test "[s1 reject] a pattern names a field twice" =
  check_error
    (order_types
   ^ {|
fn f(o: Order) -> Int =
  match o
    { id, id: n, .. } => id + n
fn main() = ()
|});
  [%expect {|
    error: there are two fields named `id`
      ┌─ test.ren:6:11
    6 │     { id, id: n, .. } => id + n
      │           ^^
      │       -- the first `id` is here
      help: remove one of them
    |}]

let%expect_test "[s1 reject] a record pattern matches a record" =
  check_error
    {|
fn f(n: Int) -> Int =
  match n
    { x, .. } => x
fn main() = ()
|};
  [%expect {|
    error: a record pattern matches a record, but this is an `Int`
      ┌─ test.ren:3:5
    3 │     { x, .. } => x
      │     ^^^^^^^^^
      help: take it apart as what it is, or bind it to a name
    |}]

let%expect_test "[s1 reject] an opaque record isn't updated outside its module" =
  check_error_files
    [
      ( "main.ren",
        {|
import order.{Order}
fn main() uses Console =
  let o = Order.make(1)
  print({ ..o, total: 3 })
|}
      );
      ( "order.ren",
        {|
pub type Order = opaque { id: Int, total: Int }
  pub fn make(id: Int) -> Order = Order { id, total: 0 }
|}
      );
    ];
  [%expect {|
    error: `Order`'s representation is private to `order`
      ┌─ main.ren:4:13
    4 │   print({ ..o, total: 3 })
      │             ^
      help: use a function from `order` to make or read one
    |}]

(* ---- s2: by name for several fields, positional for one ---- *)

let shape_types =
  {|
type Shape =
  | Dot
  | Circle(r: Int)
  | Rect { w: Int, h: Int }
|}

let%expect_test "[s2 accept] a variant with several fields is built and matched by name" =
  (* a brace form is a record literal: its fields in any order, punned *)
  run
    (shape_types
   ^ {|
fn area(s: Shape) -> Int =
  match s
    Dot => 0
    Circle(r) => 3 * r * r
    Rect { w, h } => w * h

fn main() uses Console =
  let a = Rect { w: 2, h: 3 }
  let w = 4
  let h = 5
  let b = Rect { h, w }
  print(a)
  print(b)
  print(area(a))
  print(area(b))
  print(Shape.Rect { w: 2, h: 3 } == a)
|});
  [%expect {|
    Rect { w: 2, h: 3 }
    Rect { w: 4, h: 5 }
    6
    20
    true
    ()
    |}]

let%expect_test "[s2 accept] a by-name pattern with `..`, renamed and nested" =
  run
    (shape_types
   ^ {|
fn describe(s: Shape) -> Str =
  match s
    Rect { h: 0, w } => "flat ".concat(show(w))
    Rect { w: width, .. } => show(width)
    _ => "0"

fn main() uses Console =
  print(describe(Rect { w: 4, h: 0 }))
  print(describe(Rect { w: 3, h: 1 }))
  print(describe(Dot))
|});
  [%expect {|
    flat 4
    3
    0
    ()
    |}]

let%expect_test "[s2 accept] a variant with one field is positional, its label documentation" =
  run
    {|
type Discount =
  | NoDiscount
  | Flat(off: Int)

type Route =
  | Health
  | Static(Int)

fn off(d: Discount) -> Int =
  match d
    Flat(o) => o
    NoDiscount => 0

fn main() uses Console =
  print(Flat(5))
  print(off(Flat(5)))
  print(Static(3))
|};
  [%expect {|
    Flat(5)
    5
    Static(3)
    ()
    |}]

let%expect_test "[s2 accept] a variant with one field may name it, in braces" =
  run
    {|
type Order =
  | Draft { lines: Array<Int> }
  | Cancelled

fn count(o: Order) -> Int =
  match o
    Draft { lines } => lines.len()
    Cancelled => 0

fn main() uses Console =
  print(Draft { lines: [1, 2] })
  print(count(Draft { lines: [1, 2] }))
|};
  [%expect {|
    Draft { lines: [1, 2] }
    2
    ()
    |}]

let%expect_test "[s2 accept] a by-name constructor of another module's type" =
  run_files
    [
      ( "main.ren",
        {|
import geo
fn main() uses Console =
  let r = geo.Shape.Rect { w: 1, h: 2 }
  print(r)
  match r
    geo.Shape.Rect { h, .. } => print(h)
    _ => print(0)
|}
      );
      ( "geo.ren",
        {|
pub type Shape =
  | Dot
  | Rect { w: Int, h: Int }
|} );
    ];
  [%expect {|
    Rect { w: 1, h: 2 }
    2
    ()
    |}]

let%expect_test "[s2 accept] error tags stay positional" =
  (* structural, and composed across libraries (errors.md): not variants *)
  run
    {|
fn take(n: Int) -> Int ! Short(account: Int, by: Int) =
  if n > 3 then fail Short(1, n - 3) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(_, by) => print(by)
|};
  [%expect {|
    2
    ()
    |}]

let%expect_test "[s2 reject] a variant with several fields is declared by name" =
  check_error {|
type Shape =
  | Dot
  | Rect(w: Int, h: Int)
fn main() = ()
|};
  [%expect {|
    error: a variant with several fields names them, in braces
      ┌─ test.ren:3:5
    3 │   | Rect(w: Int, h: Int)
      │     ^^^^^^^^^^^^^^^^^^^^
      help: write `Rect { w: Int, h: Int }`
    |}]

let%expect_test "[s2 reject] a variant with several fields, unnamed" =
  check_error {|
type Shape =
  | Dot
  | Rect(Int, Int)
fn main() = ()
|};
  [%expect {|
    error: a variant with several fields names them, in braces
      ┌─ test.ren:3:5
    3 │   | Rect(Int, Int)
      │     ^^^^^^^^^^^^^^
      help: give each field a name, in braces: `Rect { a: Int, b: Int }`
    |}]

let%expect_test "[s2 reject] a variant with named fields isn't built by position" =
  check_error (shape_types ^ {|
fn main() uses Console = print(Rect(2, 3))
|});
  [%expect {|
    error: `Rect` has named fields, so it's built with them
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Rect(2, 3))
      │                                ^^^^^^^^^^
      help: write `Rect { w: 2, h: 3 }`
    |}]

let%expect_test "[s2 reject] a variant with named fields isn't built with labels in parens" =
  check_error
    (shape_types ^ {|
fn main() uses Console = print(Rect(w: 2, h: 3))
|});
  [%expect {|
    error: `Rect` has named fields, so it's built with them
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Rect(w: 2, h: 3))
      │                                ^^^^^^^^^^^^^^^^
      help: write `Rect { w: 2, h: 3 }`
    |}]

let%expect_test "[s2 reject] a variant with named fields isn't matched by position" =
  (* the fix-it: a name that's the field's is punned, `_` is left out *)
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    Rect(w, tall) => w + tall
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: `Rect` has named fields, so it's matched by them
      ┌─ test.ren:8:5
    8 │     Rect(w, tall) => w + tall
      │     ^^^^^^^^^^^^^
      help: write `Rect { w, h: tall }`
    |}]

let%expect_test "[s2 reject] a positional pattern's `_` becomes `..`" =
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    Rect(w, _) => w
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: `Rect` has named fields, so it's matched by them
      ┌─ test.ren:8:5
    8 │     Rect(w, _) => w
      │     ^^^^^^^^^^
      help: write `Rect { w, .. }`
    |}]

let%expect_test "[s2 reject] a variant with one field is built by position" =
  check_error
    (shape_types ^ {|
fn main() uses Console = print(Circle(r: 2))
|});
  [%expect {|
    error: `Circle` has one field, so it's built by position
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Circle(r: 2))
      │                                ^^^^^^^^^^^^
      help: write `Circle(2)`
    |}]

let%expect_test "[s2 reject] a variant with one field isn't built in braces" =
  check_error
    (shape_types ^ {|
fn main() uses Console = print(Circle { r: 2 })
|});
  [%expect {|
    error: `Circle` has one field, so it's built by position
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Circle { r: 2 })
      │                                ^^^^^^^^^^^^^^^
      help: write `Circle(2)`
    |}]

let%expect_test "[s2 reject] a variant with one field isn't matched in braces" =
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    Circle { r } => r
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: `Circle` has one field, so it's matched by position
      ┌─ test.ren:8:5
    8 │     Circle { r } => r
      │     ^^^^^^^^^^^^
      help: write `Circle(r)`
    |}]

let%expect_test "[s2 reject] a by-name pattern that leaves a field out without `..`" =
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    Rect { w } => w
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: this pattern doesn't name `h`; add `h`, or `..` for the rest
      ┌─ test.ren:8:5
    8 │     Rect { w } => w
      │     ^^^^^^^^^^
      help: write `Rect { w, .. }` to leave the rest out
    |}]

let%expect_test "[s2 reject] a by-name constructor missing a field" =
  check_error
    (shape_types ^ {|
fn main() uses Console = print(Rect { w: 2 })
|});
  [%expect {|
    error: this `Rect` is missing `h`
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Rect { w: 2 })
      │                                ^^^^^^^^^^^^^
      help: give it a value too, like `h: ...`
    |}]

let%expect_test "[s2 reject] `..` isn't in a positional pattern" =
  check_error
    {|
fn f(o: Option<Int>) -> Int =
  match o
    Some(..) => 1
    None => 0
fn main() = ()
|};
  [%expect {|
    error: `..` stands for the fields a pattern in braces leaves out
      ┌─ test.ren:3:10
    3 │     Some(..) => 1
      │          ^^
      help: write `_` for each field it leaves out
    |}]

let%expect_test "[s2 reject] a record type and a by-name constructor of one name" =
  check_error
    {|
type Placed = { id: Int, total: Int }
type Order =
  | Draft
  | Placed { id: Int, total: Int }

fn main() uses Console = print(Placed { id: 1, total: 2 })
|};
  [%expect {|
    error: `Placed` is a record type here, and a constructor of `Order` too
      ┌─ test.ren:6:32
    6 │ fn main() uses Console = print(Placed { id: 1, total: 2 })
      │                                ^^^^^^
      help: write `Order.Placed { ... }` for the constructor, or `{ ... }` with the type left out for the record
    |}]

let%expect_test "[s2 reject] a record pattern doesn't match a sum" =
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    { w, .. } => w
fn main() = ()
|});
  [%expect {|
    error: `Shape` is a sum type, so a record pattern doesn't match it
      ┌─ test.ren:8:5
    8 │     { w, .. } => w
      │     ^^^^^^^^^
      help: name the variant: `Rect { w, .. }`
    |}]

let%expect_test "[s2 reject] a missing by-name variant is written as one" =
  check_error
    (shape_types
   ^ {|
fn f(s: Shape) -> Int =
  match s
    Dot => 0
    Circle(r) => r
fn main() = ()
|});
  [%expect {|
    error: this `match` doesn't handle every `Shape`
      ┌─ test.ren:7:3
    7 │   match s
      │   ^^^^^
      = missing: Rect { .. }
      help: add the missing arms, or a `_ =>` arm for the rest:
        Rect { .. } => todo
    |}]

(* ---- s3: or-patterns, `as`, `let ... else` ---- *)

let plan_types =
  {|
type Plan =
  | Free
  | Pro(seats: Int)
  | Team(seats: Int)
  | Enterprise { seats: Int, contract: Int }
|}

let%expect_test "[s3 accept] an or-pattern over constructors binds the same names" =
  run
    (plan_types
   ^ {|
fn seats(p: Plan) -> Int =
  match p
    Pro(n) | Team(n) | Enterprise { seats: n, .. } => n
    Free => 1

fn main() uses Console =
  print(seats(Free))
  print(seats(Pro(3)))
  print(seats(Team(8)))
  print(seats(Enterprise { seats: 50, contract: 1 }))
|});
  [%expect {|
    1
    3
    8
    50
    ()
    |}]

let%expect_test "[s3 accept] an or-pattern nested inside a constructor" =
  run
    (plan_types
   ^ {|
fn paid_option(o: Option<Plan>) -> Bool =
  match o
    Some(Pro(_) | Team(_)) => true
    _ => false

fn main() uses Console =
  print(paid_option(Some(Team(2))))
  print(paid_option(Some(Free)))
  print(paid_option(None))
|});
  [%expect {|
    true
    false
    false
    ()
    |}]

let%expect_test "[s3 accept] `as` binds the whole of what a pattern matched" =
  (* it binds looser than `|`: `A | B as x` names the whole *)
  run
    (plan_types
   ^ {|
fn upgraded(p: Plan) -> Plan =
  match p
    Pro(n) as old => if n > 5 then Team(n) else old
    Free | Team(_) as other => other
    Enterprise { .. } => p

fn main() uses Console =
  print(upgraded(Pro(9)))
  match Some(upgraded(Pro(2)))
    Some(Pro(_) as inner) as whole => print(whole)
    _ => print(0)
  print(upgraded(Free))
|});
  [%expect {|
    Team(9)
    Some(Pro(2))
    Free
    ()
    |}]

let%expect_test "[s3 accept] `let ... else` that fails" =
  run
    (plan_types
   ^ {|
fn team_seats(p: Plan) -> Int ! NotTeam =
  let Team(n) = p else fail NotTeam
  n

fn main() uses Console =
  print(attempt team_seats(Team(6)))
  print(attempt team_seats(Free))
|});
  [%expect {|
    Ok(6)
    Err(NotTeam)
    ()
    |}]

let%expect_test "[s3 accept] `let ... else` that breaks, and a by-name pattern" =
  run
    (plan_types
   ^ {|
fn leading_teams(ps: Array<Plan>) -> Int =
  var n = 0
  for p in ps
    let Team(s) = p else break
    n += s
  n

fn contract(p: Plan) -> Int ! NotEnterprise =
  let Enterprise { seats, contract } = p else fail NotEnterprise
  seats + contract

fn main() uses Console =
  print(leading_teams([Team(2), Team(3), Free, Team(4)]))
  print(attempt contract(Enterprise { seats: 50, contract: 1 }))
|});
  [%expect {|
    5
    Ok(51)
    ()
    |}]

let%expect_test "[s3 accept] `let ... else` whose else is a block or an `if` that leaves" =
  run
    {|
fn first(o: Option<Int>) -> Int ! Missing | Small uses Console =
  let Some(n) = o else
    print("said")
    fail Missing
  let Some(m) = if n > 1 then Some(n) else None else
    if n == 0 then fail Missing else fail Small
  m

fn main() uses Console =
  print(attempt first(None))
  print(attempt first(Some(1)))
|};
  [%expect {|
    said
    Err(Missing)
    Err(Small)
    ()
    |}]

let%expect_test "[s3 accept] a `let` takes apart a type of one variant" =
  (* it always matches, so it needs no `else` *)
  run
    {|
type Meters =
  | Meters(Int)

fn main() uses Console =
  let Meters(n) = Meters(3)
  print(n)
|};
  [%expect {|
    3
    ()
    |}]

let%expect_test "[s3 accept] or-patterns of `fail` keep working" =
  run
    {|
fn take(n: Int) -> Int ! Short(Int) | Late(Int) =
  if n > 3 then fail Short(n) else if n < 0 then fail Late(n) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(x) | fail Late(x) => print(x)
|};
  [%expect {|
    5
    ()
    |}]

let%expect_test "[s3 reject] a name bound in one alternative but not another" =
  check_error
    (plan_types
   ^ {|
fn f(p: Plan) -> Int =
  match p
    Pro(n) | Free => n
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: `n` is bound in `Pro(n)` but not in `Free`
      ┌─ test.ren:9:14
    9 │     Pro(n) | Free => n
      │              ^^^^
      help: bind the same names in every alternative
    |}]

let%expect_test "[s3 reject] a name bound to two types by two alternatives" =
  check_error
    {|
type T =
  | A(Int)
  | B(Str)

fn f(t: T) -> Int =
  match t
    A(n) | B(n) => 0
fn main() = ()
|};
  [%expect {|
    error: `n` is an `Int` in `A(n)`, but a `Str` in `B(n)`
      ┌─ test.ren:7:14
    7 │     A(n) | B(n) => 0
      │              ^
      help: bind it to one type in every alternative
    |}]

let%expect_test "[s3 reject] an alternative that never matches" =
  check_error
    (plan_types
   ^ {|
fn f(p: Plan) -> Int =
  match p
    Pro(_) | Pro(_) => 1
    _ => 0
fn main() = ()
|});
  [%expect {|
    error: this alternative never matches
      ┌─ test.ren:9:14
    9 │     Pro(_) | Pro(_) => 1
      │              ^^^^^^
      help: the alternatives before it, or the arms above, already match all of it
    |}]

let%expect_test "[s3 reject] the `else` of a `let ... else` has to leave" =
  check_error
    {|
fn f(o: Option<Int>) -> Int =
  let Some(n) = o else 0
  n
fn main() = ()
|};
  [%expect {|
    error: the `else` of a `let ... else` has to leave
      ┌─ test.ren:2:24
    2 │   let Some(n) = o else 0
      │                        ^
      help: end it with `fail`, `break` or `todo`
    |}]

let%expect_test "[s3 reject] a `let ... else` whose pattern always matches" =
  check_error
    {|
fn f(p: (Int, Int)) -> Int ! Never =
  let (a, b) = p else fail Never
  a + b
fn main() = ()
|};
  [%expect {|
    error: this pattern always matches, so the `else` never runs
      ┌─ test.ren:2:7
    2 │   let (a, b) = p else fail Never
      │       ^^^^^^
      help: remove the `else`
    |}]

let%expect_test "[s3 reject] a `let` whose pattern might not match needs an `else`" =
  check_error {|
fn f(o: Option<Int>) -> Int =
  let Some(n) = o
  n
fn main() = ()
|};
  [%expect {|
    error: `Some(n)` might not match, so this `let` needs an `else`
      ┌─ test.ren:2:7
    2 │   let Some(n) = o
      │       ^^^^^^^
      help: add one that leaves, `let Some(n) = o else fail ...`, or use a `match`
    |}]

let%expect_test "[s3 reject] a `for` takes apart only what always matches" =
  check_error
    {|
fn f(xs: Array<Option<Int>>) -> Int =
  var t = 0
  for Some(n) in xs
    t += n
  t
fn main() = ()
|};
  [%expect {|
    error: a `for` takes apart only what always matches, but `Some(n)` might not
      ┌─ test.ren:3:7
    3 │   for Some(n) in xs
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

let%expect_test "[s3 reject] Ren has no `if let`" =
  check_error
    {|
fn f(o: Option<Int>) -> Int =
  if let Some(n) = o then n else 0
fn main() = ()
|};
  [%expect {|
    error: Ren has no `if let`
      ┌─ test.ren:2:6
    2 │   if let Some(n) = o then n else 0
      │      ^^^
      help: write a `match`, or `let Some(n) = o else ...`
    |}]

let%expect_test "[s3 reject] a `fail` pattern isn't bound with `as`" =
  check_error
    {|
fn take(n: Int) -> Int ! Short(Int) = if n > 3 then fail Short(n) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(_) as e => print(0)
|};
  [%expect {|
    error: a `fail` pattern can't bind the whole error to a name
      ┌─ test.ren:6:19
    6 │     fail Short(_) as e => print(0)
      │                   ^^
      help: match each tag, like `fail NotFound`, or keep the whole outcome as a value with `attempt`, and match `Err(e)`
    |}]

(* ---- s4: variant types ---- *)

let order_sum =
  {|
type Order =
  | Draft { lines: Array<Int> }
  | Placed { id: Int, lines: Array<Int>, total: Int }
  | Shipped { id: Int, tracking: Str }
|}

let%expect_test "[s4 accept] `as` on a by-name pattern binds its variant type" =
  types
    (order_sum
   ^ {|
fn place(d: Order.Draft, id: Int) -> Order =
  Placed { ..d, id, total: d.lines.sum() }

fn ship(p: Order.Placed, tracking: Str) -> Order = Shipped { id: p.id, tracking }

fn step(o: Order) -> Order =
  match o
    Draft { .. } as d => place(d, 1)
    Placed { .. } as p => ship(p, "t")
    Shipped { .. } => o

fn main() = ()
|});
  [%expect {|
    fn place(d: Order.Draft, id: Int) -> Order
    fn ship(p: Order.Placed, tracking: Str) -> Order
    fn step(o: Order) -> Order
    fn main()
    |}]

let%expect_test "[s4 accept] a variant type is a record: fields, patterns and update" =
  run
    (order_sum
   ^ {|
fn main() uses Console =
  match Placed { id: 7, lines: [1, 2], total: 3 }
    Placed { .. } as p =>
      print(p.id)
      let { lines, .. } = p
      print(lines)
      let q = { ..p, total: 30 }
      print(q)
      var r = q
      r.total = 99
      print(r)
    _ => ()
|});
  [%expect {|
    7
    [1, 2]
    Placed { id: 7, lines: [1, 2], total: 30 }
    Placed { id: 7, lines: [1, 2], total: 99 }
    ()
    |}]

let%expect_test "[s4 accept] back to the sum with `Placed { ..p }`" =
  types
    (order_sum
   ^ {|
fn back(p: Order.Placed) -> Order = Placed { ..p }
fn bumped(p: Order.Placed) -> Order = Placed { ..p, total: p.total + 1 }
fn main() = ()
|});
  [%expect {|
    fn back(p: Order.Placed) -> Order
    fn bumped(p: Order.Placed) -> Order
    fn main()
    |}]

let%expect_test "[s4 accept] a variant type goes anywhere: returned, stored, passed" =
  run
    (order_sum
   ^ {|
type Box = { p: Order.Placed }

fn placed(o: Order) -> Option<Order.Placed> =
  match o
    Placed { .. } as p => Some(p)
    _ => None

fn main() uses Console =
  var ps: Array<Order.Placed> = []
  for o in [Placed { id: 1, lines: [], total: 4 }, Draft { lines: [] }, Placed { id: 2, lines: [], total: 5 }]
    match placed(o)
      Some(p) => &ps.push(p)
      None => ()
  print(ps.len())
  print(placed(Placed { ..ps[0] }))
  print(Box { p: ps[1] })
|});
  [%expect {|
    2
    Some(Placed { id: 1, lines: [], total: 4 })
    Box { p: Placed { id: 2, lines: [], total: 5 } }
    ()
    |}]

let%expect_test "[s4 accept] a variant type's `==`, order, `hash` and `show` are its sum's" =
  (* `Order`'s `key` is its id, so two placed orders of one id are equal
     as `Order.Placed` too (language.md §2, "Derived operations are
     borrowed") *)
  run
    {|
type Order =
  | Draft
  | Placed { id: Int, total: Int }

  fn key(self) -> Int =
    match self
      Placed { id, .. } => id
      Draft => 0

fn placed(o: Order) -> Order.Placed =
  match o
    Placed { .. } as p => p
    Draft => placed(Placed { id: 0, total: 0 })

fn main() uses Console =
  let a = placed(Placed { id: 1, total: 2 })
  let b = placed(Placed { id: 1, total: 3 })
  print(a == b)
  print(a <= b)
  print(Set.of([a, b]).len())
  print(a)
|};
  [%expect {|
    true
    true
    1
    Placed { id: 1, total: 2 }
    ()
    |}]

let%expect_test "[s4 accept] a generic sum's variant type" =
  types
    {|
type Tree<T> =
  | Leaf
  | Node { left: Tree<T>, value: T, right: Tree<T> }

fn left<T>(n: Tree.Node<T>) -> Tree<T> = n.left
fn main() = ()
|};
  [%expect {|
    fn left<T>(n: Tree.Node<T>) -> Tree<T>
    fn main()
    |}]

let%expect_test "[s4 accept] an or-pattern of several variants binds the sum" =
  types
    (order_sum
   ^ {|
fn id(o: Order) -> Int =
  match o
    Placed { .. } | Shipped { .. } as s => if s == o then 1 else 0
    Draft { .. } => 0

fn main() = ()
|});
  [%expect {|
    fn id(o: Order) -> Int
    fn main()
    |}]

let%expect_test "[s4 reject] a constructor builds the sum, not its variant type" =
  check_error
    (order_sum
   ^ {|
fn make() -> Order.Placed = Placed { id: 1, lines: [], total: 0 }
fn main() = ()
|});
  [%expect {|
    error: expected `Order.Placed`, found `Order`
      ┌─ test.ren:6:29
    6 │ fn make() -> Order.Placed = Placed { id: 1, lines: [], total: 0 }
      │                             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = `make` is declared to return `Order.Placed`
      = a constructor always builds the sum; a variant type is bound by a pattern's `as`
      help: `Order.Placed` is one variant of `Order`: match it and bind that with `as`, `Placed { .. } as p`
    |}]

let%expect_test "[s4 reject] a variant type isn't its sum" =
  check_error
    (order_sum
   ^ {|
fn total(o: Order) -> Int = 0
fn f(p: Order.Placed) -> Int = total(p)
fn main() = ()
|});
  [%expect {|
    error: expected `Order`, found `Order.Placed`
      ┌─ test.ren:7:38
    7 │ fn f(p: Order.Placed) -> Int = total(p)
      │                                      ^
      help: make it the sum: `Placed { ..p }`
    |}]

let%expect_test "[s4 reject] a positional variant has no type of its own" =
  check_error
    {|
type Discount =
  | NoDiscount
  | Flat(off: Int)

fn f(d: Discount.Flat) -> Int = 0
fn main() = ()
|};
  [%expect {|
    error: `Discount.Flat` isn't a type: only a variant with named fields has one
      ┌─ test.ren:5:18
    5 │ fn f(d: Discount.Flat) -> Int = 0
      │                  ^^^^
      help: take its field out where it's matched, `Flat(off) => ...`
    |}]

let%expect_test "[s4 reject] a variant type names a variant its sum has" =
  check_error (order_sum ^ {|
fn f(p: Order.Placd) -> Int = 0
fn main() = ()
|});
  [%expect {|
    error: `Order` has no variant `Placd`
      ┌─ test.ren:6:15
    6 │ fn f(p: Order.Placd) -> Int = 0
      │               ^^^^^
      help: did you mean `Placed`?
    |}]

let%expect_test "[s4 reject] only a sum type has variants" =
  check_error
    {|
type User = { id: Int }
fn f(u: User.Admin) -> Int = 0
fn main() = ()
|};
  [%expect {|
    error: `User` isn't a sum type, so it has no variants
      ┌─ test.ren:2:9
    2 │ fn f(u: User.Admin) -> Int = 0
      │         ^^^^
      help: a variant type is one of a sum's, like `Order.Placed`
    |}]

let%expect_test "[s4 reject] `..` doesn't take the rest from a sum" =
  check_error
    (order_sum
   ^ {|
fn f(o: Order) -> Order = Placed { ..o, total: 0 }
fn main() = ()
|});
  [%expect {|
    error: `..o` takes the rest from a record, but `o` is an `Order`, a sum type
      ┌─ test.ren:6:38
    6 │ fn f(o: Order) -> Order = Placed { ..o, total: 0 }
      │                                      ^
      help: match it, and take the rest from the variant: `Placed { .. } as p => Placed { ..p, ... }`
    |}]

let%expect_test "[s4 reject] a variant type has no methods of its own" =
  check_error
    {|
type Order =
  | Draft
  | Placed { id: Int, total: Int }

  pub fn size(self) -> Int = 1

fn f(o: Order) -> Int =
  match o
    Placed { .. } as p => p.size()
    Draft => 0
fn main() = ()
|};
  [%expect {|
    error: `Order.Placed` has no methods of its own
      ┌─ test.ren:9:29
    9 │     Placed { .. } as p => p.size()
      │                             ^^^^
      help: call it on the sum: `Placed { ..p }.size()`
    |}]

let%expect_test "[s4 accept] a variant type in another module's signature" =
  (* a public function of `shop/order` takes and gives variant types of its
     sum, which the importer writes after the module's alias *)
  run_files
    [
      ( "main.ren",
        {|
import shop/order

fn total(p: order.Order.Placed) -> Int = p.total

fn main() uses Console =
  for d in order.drafts([order.Order.Draft { lines: [1, 2] }, order.Order.Shipped { id: 3, tracking: "x" }])
    let p = order.place(d, 7)
    print(total(p))
    print(order.ship(p, "t"))
|} );
      ( "shop/order.ren",
        {|
pub type Order =
  | Draft { lines: Array<Int> }
  | Placed { id: Int, lines: Array<Int>, total: Int }
  | Shipped { id: Int, tracking: Str }

pub fn place(d: Order.Draft, id: Int) -> Order.Placed =
  match Placed { ..d, id, total: d.lines.sum() }
    Placed { .. } as p => p
    _ => place(d, id)

pub fn ship(p: Order.Placed, tracking: Str) -> Order = Shipped { id: p.id, tracking }

pub fn drafts(os: Array<Order>) -> Array<Order.Draft> =
  var ds: Array<Order.Draft> = []
  for o in os
    match o
      Draft { .. } as d => &ds.push(d)
      _ => ()
  ds
|} );
    ];
  [%expect {|
    3
    Shipped { id: 7, tracking: "t" }
    ()
    |}]

let%expect_test "[s4 accept] to the sum and back, and a variant type's own patterns" =
  (* `Placed { ..p }` and a `match` with `as` give back the same value, as
     many times as it's done; a pattern of a variant type's own
     constructor, or of its fields, always matches *)
  run
    (order_sum
   ^ {|
fn round(p: Order.Placed, n: Int) -> Order.Placed =
  if n == 0 then p
  else
    match Placed { ..p }
      Placed { .. } as q => round(q, n - 1)
      _ => p

fn id(p: Order.Placed) -> Int =
  match p
    Placed { id, .. } => id

fn total(p: Order.Placed) -> Int =
  let Placed { total, .. } = p
  total

fn main() uses Console =
  match Placed { id: 4, lines: [1], total: 2 }
    Placed { .. } as p =>
      let q = round(p, 50)
      print(q == p)
      print(id(q) + total(q))
      var ps = [q, { ..q, id: 5 }]
      ps[0] = { ..ps[1], total: 9 }
      print(ps)
    _ => ()
|});
  [%expect {|
    true
    6
    [Placed { id: 5, lines: [1], total: 9 }, Placed { id: 5, lines: [1], total: 2 }]
    ()
    |}]

let%expect_test "[s4 reject] a variant type is always its own variant" =
  check_error
    (order_sum
   ^ {|
fn f(p: Order.Placed) -> Int =
  match p
    Placed { id, .. } => id
    Shipped { id, .. } => id
fn main() = ()
|});
  [%expect {|
    error: an `Order.Placed` is never a `Shipped`, so this pattern never matches
      ┌─ test.ren:9:5
    9 │     Shipped { id, .. } => id
      │     ^^^^^^^^^^^^^^^^^^
      help: a value of a variant type is always that variant: match it as `Placed { .. }`, or match the sum it came from
    |}]

let%expect_test "[s4 reject] a variant type's arguments are written after it" =
  check_error
    {|
type Tree<T> =
  | Leaf
  | Node { left: Tree<T>, value: T, right: Tree<T> }

fn f(n: Tree<Int>.Node) -> Int = n.value
fn main() = ()
|};
  [%expect {|
    error: a variant type's arguments are its sum's, written after the variant
      ┌─ test.ren:5:18
    5 │ fn f(n: Tree<Int>.Node) -> Int = n.value
      │                  ^
      help: write `Tree.Node<Int>`
    |}]

(* ---- s5: the errors that teach the model, and `todo` ---- *)

let shapes =
  {|
type Shape =
  | Dot
  | Rect { id: Int, w: Int, h: Int }
  | Frame { id: Int, w: Int, h: Int, t: Int }
  | Ring { id: Int, r: Int }
|}

let%expect_test "[s5 reject] a field asked of a sum names the variant that has it" =
  check_error (shapes ^ {|
fn f(s: Shape) -> Int = s.r
fn main() = ()
|});
  [%expect {|
    error: `Shape` is a sum type; only `Ring` has `r`
      ┌─ test.ren:7:27
    7 │ fn f(s: Shape) -> Int = s.r
      │                           ^
      help: take it from `Ring` with a `match`:
          match s
            Ring { r, .. } => r
            _ => todo
    |}]

let%expect_test "[s5 reject] a field two variants have" =
  check_error (shapes ^ {|
fn f(s: Shape) -> Int = s.id
fn main() = ()
|});
  [%expect {|
    error: `Shape` is a sum type; only `Rect`, `Frame` and `Ring` have `id`
      ┌─ test.ren:7:27
    7 │ fn f(s: Shape) -> Int = s.id
      │                           ^^
      help: take it from them with a `match`:
          match s
            Rect { id, .. } | Frame { id, .. } | Ring { id, .. } => id
            _ => todo
    |}]

let%expect_test "[s5 reject] a field every variant has: hoist it" =
  check_error
    {|
type Shape =
  | Rect { id: Int, w: Int, h: Int }
  | Ring { id: Int, r: Int }

fn f(s: Shape) -> Int = s.id
fn main() = ()
|};
  [%expect {|
    error: every variant of `Shape` has `id`, but a sum type has no fields
      ┌─ test.ren:5:27
    5 │ fn f(s: Shape) -> Int = s.id
      │                           ^^
      help: hoist it into a record, `type Shape = { id: Int, kind: ShapeKind }`, or write a method that matches each variant
    |}]

let%expect_test "[s5 reject] a `match` that misses cases prints the arms to paste" =
  check_error
    {|
type Door =
  | Open
  | Closed

fn f(d: Option<Door>) -> Int =
  match d
    Some(Open) => 1
    None => 0
fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Option`
      ┌─ test.ren:6:3
    6 │   match d
      │   ^^^^^
      = missing: Some(Closed)
      help: add the missing arms, or a `_ =>` arm for the rest:
        Some(Closed) => todo
    |}]

let%expect_test "[s5 reject] the arms to paste, by name, and the rest" =
  (* three are printed; if more may be missing, a `_` arm after them *)
  check_error (shapes ^ {|
fn f(s: Shape) -> Int =
  match s
    Dot => 0
fn main() = ()
|});
  [%expect {|
    error: this `match` doesn't handle every `Shape`
      ┌─ test.ren:8:3
    8 │   match s
      │   ^^^^^
      = missing: Rect { .. }, Frame { .. }, Ring { .. }
      help: add the missing arms, or a `_ =>` arm for the rest:
        Rect { .. } => todo
        Frame { .. } => todo
        Ring { .. } => todo
    |}]

let%expect_test "[s5 reject] a missing error is a `fail` arm to paste" =
  check_error
    {|
fn take(n: Int) -> Int ! Short(Int) | Late(Int) =
  if n > 3 then fail Short(n) else if n < 0 then fail Late(n) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(x) => print(x)
|};
  [%expect {|
    error: this `match` doesn't handle every error it can fail with
      ┌─ test.ren:5:3
    5 │   match take(5)
      │   ^^^^^
      = missing: fail Late(_)
      help: add the missing arms, or a `fail _ =>` arm for the rest, or pass them on with `try match`:
        fail Late(_) => todo
    |}]

let%expect_test "[s5 accept] `todo` has any type, and panics where it's reached" =
  run_error
    {|
type Light =
  | Red
  | Green

fn next(l: Light) -> Int =
  match l
    Red => 1
    Green => todo

fn main() uses Console =
  print(next(Red))
  print(next(Green))
|};
  [%expect {|
    1
    error: panic: reached a `todo`
      ┌─ test.ren:8:14
    8 │     Green => todo
      │              ^^^^
    |}]

let%expect_test "[s5 accept] `todo` leaves a `let ... else`" =
  types
    {|
fn first(o: Option<Int>) -> Int =
  let Some(n) = o else todo
  n

fn main() = ()
|};
  [%expect {|
    fn first(o: Option<Int>) -> Int
    fn main()
    |}]

let%expect_test "[s5 reject] a positional variant's label is its field" =
  (* at another type, so an arm each *)
  check_error
    {|
type Shape =
  | Ring { id: Int, r: Int }
  | Pin(r: Str)
  | Dot

fn f(s: Shape) -> Int = s.r
fn main() = ()
|};
  [%expect {|
    error: `Shape` is a sum type; only `Ring` and `Pin` have `r`
      ┌─ test.ren:6:27
    6 │ fn f(s: Shape) -> Int = s.r
      │                           ^
      help: take it from them with a `match`:
          match s
            Ring { r, .. } => r
            Pin(r) => r
            _ => todo
    |}]

let%expect_test "[s5 reject] a field every variant has at different types" =
  check_error
    {|
type Key =
  | Num { id: Int }
  | Name { id: Str }

fn f(k: Key) -> Int = k.id
fn main() = ()
|};
  [%expect {|
    error: every variant of `Key` has `id`, but a sum type has no fields
      ┌─ test.ren:5:25
    5 │ fn f(k: Key) -> Int = k.id
      │                         ^^
      help: take it from each with a `match`:
          match k
            Num { id } => id
            Name { id } => id
    |}]

let%expect_test "[s5 reject] a field no variant has keeps today's error" =
  check_error (shapes ^ {|
fn f(s: Shape) -> Int = s.z
fn main() = ()
|});
  [%expect {|
    error: `.z` needs a record, but this is a `Shape`
      ┌─ test.ren:7:27
    7 │ fn f(s: Shape) -> Int = s.z
      │                           ^
    |}]

let%expect_test "[s5 reject] a generic sum's field every variant has: hoist it" =
  check_error
    {|
type Tree<T> =
  | Leaf { id: Int }
  | Node { id: Int, left: Tree<T>, value: T, right: Tree<T> }

fn f(t: Tree<Int>) -> Int = t.id
fn main() = ()
|};
  [%expect {|
    error: every variant of `Tree` has `id`, but a sum type has no fields
      ┌─ test.ren:5:31
    5 │ fn f(t: Tree<Int>) -> Int = t.id
      │                               ^^
      help: hoist it into a record, `type Tree<T> = { id: Int, kind: TreeKind<T> }`, or write a method that matches each variant
    |}]

let%expect_test "[s5 reject] more missing than shown: an arm for the rest" =
  check_error
    {|
type Day =
  | Mon
  | Tue
  | Wed
  | Thu
  | Fri

fn work(d: Day) -> Int =
  if true then
    match d
      Mon => 1
  else 0
fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Day`
       ┌─ test.ren:10:5
    10 │     match d
       │     ^^^^^
       = missing: Tue, Wed, Thu
       help: add the missing arms, or a `_ =>` arm for the rest:
          Tue => todo
          Wed => todo
          Thu => todo
          _ => todo
    |}]

let%expect_test "[s5 reject] a missing arm nested, by name inside a positional one" =
  check_error (shapes ^ {|
fn f(s: Option<(Shape, Bool)>) -> Int =
  match s
    None => 0
    Some((Dot, _)) => 1
    Some((Rect { .. }, _)) => 2
    Some((Frame { .. }, true)) => 3
    Some((Ring { .. }, _)) => 4
fn main() = ()
|});
  [%expect {|
    error: this `match` doesn't handle every `Option`
      ┌─ test.ren:8:3
    8 │   match s
      │   ^^^^^
      = missing: Some((Frame { .. }, false))
      help: add the missing arms, or a `_ =>` arm for the rest:
        Some((Frame { .. }, false)) => todo
    |}]

let%expect_test "[s5 reject] a by-name constructor a record type shadows is written after its sum" =
  check_error
    {|
type Rect = { w: Int, h: Int }
type Shape =
  | Dot
  | Rect { w: Int, h: Int }

fn f(s: Shape) -> Int =
  match s
    Dot => 0
fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Shape`
      ┌─ test.ren:7:3
    7 │   match s
      │   ^^^^^
      = missing: Shape.Rect { .. }
      help: add the missing arms, or a `_ =>` arm for the rest:
        Shape.Rect { .. } => todo
    |}]

let%expect_test "[s5 reject] missing values and errors: an arm each" =
  check_error
    {|
fn take(n: Int) -> Bool ! Short(Int) | Late(Int) =
  if n > 3 then fail Short(n) else if n < 0 then fail Late(n) else n > 1

fn main() uses Console =
  match take(5)
    true => print(1)
    fail Short(x) => print(x)
|};
  [%expect {|
    error: this `match` doesn't handle every value and error
      ┌─ test.ren:5:3
    5 │   match take(5)
      │   ^^^^^
      = missing: false, fail Late(_)
      help: add the missing arms, or a `_ =>` arm for the rest:
        false => todo
        fail Late(_) => todo
    |}]

let%expect_test "[s5 reject] a missing `Err` is each of its tags" =
  check_error
    {|
fn take(n: Int) -> Int ! Short | Late(Int) =
  if n > 3 then fail Short else if n < 0 then fail Late(n) else n

fn main() uses Console =
  match attempt take(5)
    Ok(n) => print(n)
|};
  [%expect {|
    error: this `match` doesn't handle every `Result`
      ┌─ test.ren:5:3
    5 │   match attempt take(5)
      │   ^^^^^
      = missing: Err(Late(_)), Err(Short)
      help: add the missing arms, or a `_ =>` arm for the rest:
        Err(Late(_)) => todo
        Err(Short) => todo
    |}]

let%expect_test "[s5 accept] `todo` stands for a whole function's body, `main`'s too" =
  run_error {|
fn later(n: Int) -> Str = todo

fn main() = todo
|};
  [%expect {|
    error: panic: reached a `todo`
      ┌─ test.ren:3:13
    3 │ fn main() = todo
      │             ^^^^
    |}]

let%expect_test "[s5 reject] `todo` is a keyword, not a name" =
  check_error {|
fn main() =
  let todo = 1
  ()
|};
  [%expect {|
    error: expected a name, found `todo`
      ┌─ test.ren:2:7
    2 │   let todo = 1
      │       ^^^^
    |}]

(* The arms a `match` misses, pasted in as they're printed, at the column
   they're printed at, after its last arm: the program then checks. *)
let pasted src =
  let src = clean src in
  let lines = String.split_on_char '\n' src in
  match Ren.Driver.check ~file src with
  | _ -> print_endline "it checks, with nothing to paste"
  | exception (Ren.Diag.Errors (d :: _) | Ren.Diag.Error d) ->
      let col = Option.value d.code_at ~default:1 in
      let indent l =
        let n = String.length l in
        let rec go i = if i < n && l.[i] = ' ' then go (i + 1) else i in
        if String.trim l = "" then max_int else go 0
      in
      (* the arms are the lines after the `match`'s that are indented as far
         as its arms, or further *)
      let rec after i = function
        | l :: rest when indent l >= col - 1 && indent l <> max_int ->
            after (i + 1) rest
        | _ -> i
      in
      let at = after d.loc.start.line (List.filteri (fun i _ -> i >= d.loc.start.line) lines) in
      let arms = List.map (fun c -> String.make (col - 1) ' ' ^ c) d.code in
      let src' =
        String.concat "\n"
          (List.filteri (fun i _ -> i < at) lines
          @ arms
          @ List.filteri (fun i _ -> i >= at) lines)
      in
      List.iter print_endline arms;
      (match Ren.Driver.check ~file src' with
      | _ -> print_endline "pasted: it checks"
      | exception e ->
          report src' (fun () -> raise e))

let%expect_test "[s5 accept] the arms printed, pasted back in, check" =
  List.iter
    (fun src ->
      pasted src;
      print_endline "--")
    [
      {|
type Door =
  | Open
  | Closed

fn f(d: Option<Door>) -> Int =
  match d
    Some(Open) => 1
    None => 0
fn main() = ()
|};
      shapes ^ {|
fn f(s: Shape) -> Int =
  match s
    Dot => 0
fn main() = ()
|};
      shapes ^ {|
fn f(s: Option<(Shape, Bool)>) -> Int =
  match s
    None => 0
    Some((Dot, _)) => 1
    Some((Rect { .. }, _)) => 2
    Some((Frame { .. }, true)) => 3
    Some((Ring { .. }, _)) => 4
fn main() = ()
|};
      {|
type Day =
  | Mon
  | Tue
  | Wed
  | Thu
  | Fri

fn work(d: Day) -> Int =
  if true then
    match d
      Mon => 1
  else 0
fn main() = ()
|};
      {|
type Rect = { w: Int, h: Int }
type Shape =
  | Dot
  | Rect { w: Int, h: Int }

fn f(s: Shape) -> Int =
  match s
    Dot => 0
fn main() = ()
|};
      {|
type Order = { id: Int, paid: Bool, urgent: Bool }

fn f(o: Order) -> Int =
  match o
    { paid: true, .. } => 1
    { urgent: true, .. } => 2
fn main() = ()
|};
      {|
fn take(n: Int) -> Bool ! Short(Int) | Late(Int) =
  if n > 3 then fail Short(n) else if n < 0 then fail Late(n) else n > 1

fn main() uses Console =
  match take(5)
    true => print(1)
    fail Short(x) => print(x)
|};
      {|
fn take(n: Int) -> Int ! Short | Late(Int) =
  if n > 3 then fail Short else if n < 0 then fail Late(n) else n

fn main() uses Console =
  match attempt take(5)
    Ok(n) => print(n)
|};
      {|
type Plan =
  | Free
  | Pro(Int)

fn f(p: Plan, n: Int) -> Int =
  match (p, n)
    (Free, 0) => 0
    (Pro(_), _) if n > 1 => 1
fn main() = ()
|};
    ];
  [%expect {|
        Some(Closed) => todo
    pasted: it checks
    --
        Rect { .. } => todo
        Frame { .. } => todo
        Ring { .. } => todo
    pasted: it checks
    --
        Some((Frame { .. }, false)) => todo
    pasted: it checks
    --
          Tue => todo
          Wed => todo
          Thu => todo
          _ => todo
    pasted: it checks
    --
        Shape.Rect { .. } => todo
    pasted: it checks
    --
        { paid: false, urgent: false, .. } => todo
    pasted: it checks
    --
        false => todo
        fail Late(_) => todo
    pasted: it checks
    --
        Err(Late(_)) => todo
        Err(Short) => todo
    pasted: it checks
    --
        (Pro(_), _) => todo
        (Free, _) => todo
    pasted: it checks
    --
    |}]

(* The `match` a field asked of a sum writes, pasted in for the field's
   read, as the function's body: the program then checks. [decls] are the
   types, and [f] the function, `fn f(s: Shape) -> Int =` and its body,
   which reads the field. A field every variant has at different types
   gives arms of different types, which no one function returns, so it
   isn't among them. *)
let pasted_match decls f =
  let src = clean (decls ^ f ^ "fn main() = ()\n") in
  match Ren.Driver.check ~file src with
  | _ -> print_endline "it checks, with nothing to paste"
  | exception (Ren.Diag.Errors (d :: _) | Ren.Diag.Error d) ->
      let head = List.hd (String.split_on_char '=' f) ^ "=" in
      let src' =
        clean decls ^ String.trim head ^ "\n"
        ^ String.concat "\n" (List.map (fun l -> "  " ^ l) d.code)
        ^ "\nfn main() = ()\n"
      in
      List.iter print_endline d.code;
      (match Ren.Driver.check ~file src' with
      | _ -> print_endline "pasted: it checks"
      | exception e -> report src' (fun () -> raise e))

let%expect_test "[s5 accept] the `match` a field's error writes, pasted in, checks" =
  let fields =
    {|
type Shape =
  | Dot
  | Rect { id: Int, w: Int, h: Int }
  | Ring { id: Int, r: Int }
  | Pin(r: Int)
|}
  in
  List.iter
    (fun f ->
      pasted_match fields f;
      print_endline "--")
    [
      "fn f(s: Shape) -> Int = s.w\n";
      "fn f(s: Shape) -> Int = s.id\n";
      "fn f(r: Shape) -> Int = r.r\n";
    ];
  [%expect {|
    match s
      Rect { w, .. } => w
      _ => todo
    pasted: it checks
    --
    match s
      Rect { id, .. } | Ring { id, .. } => id
      _ => todo
    pasted: it checks
    --
    match r
      Ring { r, .. } | Pin(r) => r
      _ => todo
    pasted: it checks
    --
    |}]

(* ---- s6: descriptions, an operation called only on a stateless one ---- *)

let%expect_test "[s6 reject] a stateful handler's description isn't called as a method" =
  (* language.md's trap: each call started `counter` fresh, so it printed
     1 and 1. The check is the linked program's (compiler.md, "Data
     stage", step 6), so it's `ren run`'s *)
  run_error
    {|
dep Area =
  area: fn() -> Int

handler counter() for Area =
  var n = 0
  area() =>
    n += 1
    n

fn main() uses Console =
  let c: Area = counter()
  print(c.area())
  print(c.area())
|};
  [%expect {|
    error: `c` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:12:11
    12 │   print(c.area())
       │           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with c in Area.area()`

    error: `c` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:13:11
    13 │   print(c.area())
       │           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with c in Area.area()`
    |}]

let%expect_test "[s6 reject] a handler with a `finally` isn't called as a method" =
  run_error
    {|
dep Area =
  area: fn() -> Int

handler logged() for Area uses Console =
  finally(r) =>
    print("done")
    try r
  area() => 1

fn main() uses Console =
  let l: Area uses Console = logged()
  print(l.area())
|};
  [%expect {|
    error: `l` may be a description of `logged`, which has a `finally`, so it isn't called as a method
       ┌─ test.ren:12:11
    12 │   print(l.area())
       │           ^^^^
       = a call as a method makes a fresh instance, so its `finally` would run at the end of each call
       help: install it: `with l in Area.area()`
    |}]

let%expect_test "[s6 reject] any handler a description may be counts" =
  (* the closed world: a stored `Area` may be any handler of `Area` whose
     description the program makes as a value *)
  run_error
    {|
dep Area =
  area: fn() -> Int

handler square(s: Int) for Area =
  area() => s * s

handler counter() for Area =
  var n = 0
  area() =>
    n += 1
    n

fn total(xs: Array<Area>) -> Int =
  var t = 0
  for a in xs
    t += a.area()
  t

fn main() uses Console =
  print(total([square(2), counter()]))
|};
  [%expect {|
    error: `a` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:16:12
    16 │     t += a.area()
       │            ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with a in Area.area()`
    |}]

let%expect_test "[s6 accept] a stateless handler is still called as a method" =
  run
    {|
dep Area =
  area: fn() -> Int

handler square(s: Int) for Area =
  area() => s * s

fn main() uses Console =
  let xs: Array<Area> = [square(2), square(3)]
  var t = 0
  for a in xs
    t += a.area()
  print(t)
|};
  [%expect {|
    13
    ()
    |}]

let%expect_test "[s6 accept] a stateful handler installed by `with` beside stateless ones called as methods" =
  (* a description `with` installs where it's made never reaches a method
     call, so it doesn't count *)
  run
    {|
dep Area =
  area: fn() -> Int

handler square(s: Int) for Area =
  area() => s * s

handler counter() for Area =
  var n = 0
  area() =>
    n += 1
    n

fn main() uses Console =
  let xs: Array<Area> = [square(2), square(3)]
  var t = 0
  for a in xs
    t += a.area()
  print(t)
  with counter() in
    let _ = Area.area()
    print(Area.area())
|};
  [%expect {|
    13
    2
    ()
    |}]

let area_handlers =
  {|
dep Area =
  area: fn() -> Int

handler square(s: Int) for Area =
  area() => s * s

handler counter() for Area =
  var n = 0
  area() =>
    n += 1
    n
|}

let%expect_test "[s6 accept] a stateful handler bound to a local and only installed" =
  (* `c` is never assigned, and only installed, so the description it
     holds reaches those `with`s alone, and the stored ones called as
     methods can't be it (compiler.md, "Data stage", "Descriptions (step
     6)") *)
  run
    (area_handlers
   ^ {|
fn main() uses Console =
  let c = counter()
  let d = c
  with d in
    print(Area.area())
    print(Area.area())
  let xs: Array<Area> = [square(2), square(3)]
  print(xs.map(fn(a) => a.area()))
  print(square(4).area())
|});
  [%expect {|
    1
    2
    [4, 9]
    16
    ()
    |}]

let%expect_test "[s6 reject] a description called as a method where it's made" =
  run_error (area_handlers ^ {|
fn main() uses Console =
  print(counter().area())
|});
  [%expect {|
    error: `counter()` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:14:19
    14 │   print(counter().area())
       │                   ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with counter() in Area.area()`
    |}]

let%expect_test "[s6 reject] a local that's assigned may hold any description" =
  run_error
    (area_handlers
   ^ {|
fn main() uses Console =
  var a = square(2)
  a = counter()
  print(a.area())
|});
  [%expect {|
    error: `a` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:16:11
    16 │   print(a.area())
       │           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with a in Area.area()`
    |}]

let%expect_test "[s6 reject] a description passed, returned or stored is kept" =
  (* each makes `counter`'s a description that may reach the calls whose
     receivers come from somewhere else: the parameter, the result, the
     field and the handler's own *)
  run_error
    (area_handlers
   ^ {|
type Box = { a: Area }

handler twice(inner: Area) for Area =
  area() => 2 * inner.area()

fn go(a: Area) -> Int = a.area()

fn made() -> Area = counter()

fn main() uses Console =
  print(go(counter()))
  print(made().area())
  let b = Box { a: counter() }
  print(b.a.area())
  with twice(counter()) in
    print(Area.area())
|});
  [%expect {|
    error: `inner` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:16:23
    16 │   area() => 2 * inner.area()
       │                       ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with inner in Area.area()`

    error: `a` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:18:27
    18 │ fn go(a: Area) -> Int = a.area()
       │                           ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with a in Area.area()`

    error: `made()` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:24:16
    24 │   print(made().area())
       │                ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with made() in Area.area()`

    error: `b.a` may be a description of `counter`, which keeps state, so it isn't called as a method
       ┌─ test.ren:26:13
    26 │   print(b.a.area())
       │             ^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with b.a in Area.area()`
    |}]

let%expect_test "[s6 reject] a handler of another module, kept there" =
  (* the closed world: `shapes` stores `counter`'s description, and the
     program's call can be given it *)
  run_files
    [
      ( "main.ren",
        {|
import shapes

fn main() uses Console =
  for a in shapes.all()
    print(a.area())
|} );
      ( "shapes.ren",
        {|
pub dep Area =
  area: fn() -> Int

handler square(s: Int) for Area =
  area() => s * s

handler counter() for Area =
  var n = 0
  area() =>
    n += 1
    n

pub fn all() -> Array<Area> = [square(2), counter()]
|} );
    ];
  [%expect {|
    error: `a` may be a description of `shapes.counter`, which keeps state, so it isn't called as a method
      ┌─ main.ren:5:13
    5 │     print(a.area())
      │             ^^^^
      = a call as a method makes a fresh instance, so its state would start again at each call
      help: install it: `with a in shapes.Area.area()`
    |}]

let%expect_test "[s6 accept] `ren check` of one module doesn't see it" =
  (* which handlers a description may be is the linked program's to say,
     so only `ren run`, `ren test` and `ren build` refuse it *)
  ignore
    (Ren.Driver.check ~file
       (area_handlers
      ^ {|
fn main() uses Console =
  let c: Area = counter()
  print(c.area())
|}));
  print_endline "checks";
  [%expect {| checks |}]

(* ---- the program of language.md's "A program, end to end", without
   `|>` and wirings: domain types by name, a policy that's data, an
   opaque `Order`, the services the workflow needs, a `try` on each step
   that can fail, and a test handler made of data. It needs steps 1 to
   3 ---- *)

let%expect_test "[s3 accept] a program, end to end" =
  test
    {|
// the domain: data, and the rules it keeps
pub type Money = opaque Int with numeric
  pub fn dollars(n: Int) -> Money = n * 100

pub type Line = { sku: Str, qty: Int, price: Money }

pub type Discount =                       // a policy is data
  | NoDiscount
  | Flat(off: Money)
  | OverAmount { min: Money, off: Money }

  pub fn apply(self, m: Money) -> Money =
    match self
      NoDiscount => m
      Flat(off) => m - off
      OverAmount { min, off } => if m < min then m else m - off

pub type Order = opaque { id: Int, lines: Array<Line>, total: Money }
  pub fn total(self) -> Money = self.total     // vocabulary: what an Order knows

pub type Cart =
  | Open { customer: Int, lines: Array<Line> }
  | Abandoned

pub type Receipt = { order: Int, total: Money }

// the services the workflow needs
pub dep Orders =
  save: fn(o: Order) -> Int ! DbDown
pub dep Discounts =
  for_customer: fn(c: Int) -> Discount

fn validate(cart: Cart) -> Array<Line> ! Empty =
  let Open { lines, .. } = cart else fail Empty
  if lines.len() == 0 then fail Empty
  lines

fn price(lines: Array<Line>, d: Discount) -> Money =
  var sum = Money.zero
  for { qty, price, .. } in lines
    sum = sum + price * qty
  d.apply(sum)

fn place(c: Int, lines: Array<Line>, total: Money) -> Receipt ! DbDown uses Orders =
  let order = try Orders.save(Order { id: c, lines, total })
  Receipt { order, total }

// the workflow: a `try` on each step that can fail
pub fn checkout(c: Int, cart: Cart) -> Receipt ! Empty | DbDown uses Orders, Discounts =
  let lines = try validate(cart)
  let total = price(lines, Discounts.for_customer(c))
  try place(c, lines, total)

// a test: services built from data, nothing mocked by hand
test handler mem_orders() for Orders =
  var saved = 0
  save(o) =>
    saved += 1
    saved

test handler fixed(d: Discount) for Discounts =
  for_customer(_) => d

test fn cart_of_20() -> Cart =
  Open { customer: 1, lines: [Line { sku: "tea", qty: 2, price: Money.dollars(10) }] }

test "a flat discount comes off the total" =
  with mem_orders(), fixed(Flat(Money.dollars(5))) in
    let r = try checkout(1, cart_of_20())
    assert r.total == Money.dollars(15)

test "an amount under the minimum gets nothing off" =
  with mem_orders(), fixed(OverAmount { min: Money.dollars(50), off: Money.dollars(5) }) in
    let r = try checkout(1, cart_of_20())
    assert r.total == Money.dollars(20)

test "an abandoned cart is refused" =
  with mem_orders(), fixed(NoDiscount) in
    assert attempt checkout(1, Abandoned) == Err(Empty)
|};
  [%expect {|
    test.ren
      ✓ a flat discount comes off the total
      ✓ an amount under the minimum gets nothing off
      ✓ an abandoned cart is refused

    3 passed
    [exit 0]
    |}]

(* ---- s8: the review's fixes (compiler.md, "Data stage", "Step 8, as
   built") ---- *)

let%expect_test "[s8 accept] a variant type in a dependency's operation, called on a description" =
  run
    {|
type Order =
  | Placed { id: Int, total: Int }
  | Draft

dep Pricing =
  reprice: fn(p: Order.Placed) -> Int

handler fixed() for Pricing =
  reprice(p) => p.total + 1

fn main() uses Console =
  match Placed { id: 1, total: 5 }
    Placed { .. } as p =>
      let d: Pricing = fixed()
      print(d.reprice(p))
      with fixed() in
        print(Pricing.reprice(p))
    Draft => ()
|};
  [%expect {|
    6
    6
    ()
    |}]

let%expect_test "[s8 accept] a generic dependency at a variant type" =
  run
    {|
type Order =
  | Placed { id: Int, total: Int }
  | Draft

dep Store<T> =
  get: fn() -> Option<T>

handler empty<T>() for Store<T> =
  get() => None

handler one(p: Order.Placed) for Store<Order.Placed> =
  get() => Some(p)

fn main() uses Console =
  with empty() in
    let x: Option<Order.Placed> = Store.get()
    print(x)
  match Placed { id: 1, total: 5 }
    Placed { .. } as p =>
      with one(p) in
        let y: Option<Order.Placed> = Store.get()
        print(y)
    Draft => ()
|};
  [%expect {|
    None
    Some(Placed { id: 1, total: 5 })
    ()
    |}]

let%expect_test "[s8 accept] a dependency at a variant type isn't one at its sum" =
  (* the key keeps the variant: `Store.get()` at `Order.Placed` is the
     outer handler's, never the inner `Store<Order>`'s `Draft`, in a
     generic function's key too *)
  run
    {|
type Order =
  | Placed { id: Int, total: Int }
  | Draft

type Tree<T> =
  | Node { left: Tree<T>, item: T, right: Tree<T> }
  | Leaf

dep Store<T> =
  get: fn() -> T

handler giving<T>(v: T) for Store<T> =
  get() => v

fn total() -> Int uses Store<Order.Placed> =
  let p: Order.Placed = Store.get()
  p.total

fn top<T>() -> T uses Store<T> = Store.get()

fn both<T>(n: Tree.Node<T>) -> (T, Tree<T>) =
  let l: Store<Tree<T>> = giving(Leaf)
  with giving(n) in
    with l in
      let m: Tree.Node<T> = top()
      let t: Tree<T> = top()
      (m.item, t)

fn main() uses Console =
  match Placed { id: 1, total: 5 }
    Placed { .. } as p =>
      with giving(p) in
        with giving(Draft) in
          print(total())
          let q: Order.Placed = top()
          print(q.id)
          let o: Order = top()
          print(o)
    Draft => ()
  match Node { left: Leaf, item: 7, right: Leaf }
    Node { .. } as n => print(both(n))
    Leaf => ()
|};
  [%expect {|
    5
    1
    Draft
    (7, Leaf)
    ()
    |}]

let%expect_test "[s8 accept] `let ... else` and other patterns in a handler's state" =
  run
    {|
dep Area =
  area: fn() -> Str

type Shape =
  | Rect { w: Int, h: Int }
  | Dot

handler sized(s: Shape, name: Option<Str>) for Area ! NoName | NotRect uses Console =
  let Some(n) = name else fail NoName
  let Rect { w, h } = s else
    print("not a rect")
    fail NotRect
  let (a, b) = (w * h, n.concat("!"))
  area() => b.concat(show(a))

fn area_of(s: Shape, name: Option<Str>) -> Str uses Console =
  match attempt with sized(s, name) in Area.area()
    Ok(a) => a
    Err(NoName) => "no name"
    Err(NotRect) => "not rect"

fn main() uses Console =
  print(area_of(Rect { w: 2, h: 3 }, Some("r")))
  print(area_of(Dot, Some("d")))
  print(area_of(Dot, None))
|};
  [%expect {|
    r!6
    not a rect
    not rect
    no name
    ()
    |}]

let%expect_test "[s8 reject] a handler's state whose `let ... else` reaches its `todo`" =
  run_error
    {|
dep Area =
  area: fn() -> Str

handler h(o: Option<Str>) for Area =
  let Some(n) = o else todo
  area() => n

fn main() uses Console =
  with h(Some("t")) in
    print(Area.area())
  with h(None) in
    print(Area.area())
|};
  [%expect {|
    t
    error: panic: reached a `todo`
      ┌─ test.ren:5:24
    5 │   let Some(n) = o else todo
      │                        ^^^^
    |}]

let%expect_test "[s8 accept] `let ... else` in a test, and in a test handler's state" =
  test
    {|
pub dep Area =
  area: fn() -> Str

fn main() = ()

test handler fake(o: Option<Str>) for Area =
  let Some(n) = o else todo
  area() => n

test "in a test" =
  let Some(n) = Some(1) else todo
  assert n == 1

test "in a test handler's state" =
  with fake(Some("a")) in
    assert Area.area() == "a"
|};
  [%expect {|
    test.ren
      ✓ in a test
      ✓ in a test handler's state

    2 passed
    [exit 0]
    |}]

let%expect_test "[s8 reject] `todo` called panics before the call" =
  (* the callee is evaluated first, so its arguments never are *)
  run_error
    {|
fn said(n: Int) -> Int uses Console =
  print("never")
  n

fn main() uses Console =
  print("before")
  print(todo(said(1)) + 1)
|};
  [%expect {|
    before
    error: panic: reached a `todo`
      ┌─ test.ren:7:9
    7 │   print(todo(said(1)) + 1)
      │         ^^^^
    |}]

let%expect_test "[s8 accept] an alternative inside another is checked in the alternative it's in" =
  (* `B(s)` in the first alternative matches `(Some(B(2)), 1)`, which
     the second alternative, after it, doesn't take from it *)
  run
    {|
type E =
  | A(Int)
  | B(Int)

fn f(o: (Option<E>, Int)) -> Int =
  match o
    (Some(A(s) | B(s)), 1) | (Some(B(s)), _) => s
    _ => 0

fn main() uses Console =
  print(f((Some(B(2)), 1)))
  print(f((Some(B(3)), 0)))
  print(f((Some(A(4)), 0)))
|};
  [%expect {|
    2
    3
    0
    ()
    |}]

let%expect_test "[s8 reject] an alternative inside another that one before it covers" =
  check_error
    {|
type E =
  | A(Int)
  | B(Int)

fn g(o: Option<E>) -> Int =
  match o
    Some(A(n)) | Some(B(n) | A(n)) => n
    None => 0

fn main() = ()
|};
  [%expect {|
    error: this alternative never matches
      ┌─ test.ren:7:30
    7 │     Some(A(n)) | Some(B(n) | A(n)) => n
      │                              ^^^^
      help: the alternatives before it, or the arms above, already match all of it
    |}]

let%expect_test "[s8 reject] a generic description's `with` is written as its call is" =
  (* `Chan.send(1)`, the dependency's name alone, and where the arguments
     don't fix its type, the type written where the value goes *)
  run_error
    {|
import sync.{Chan}

fn main() uses Console, Async =
  let c: Chan<Int> uses Async = sync.channel(4)
  c.send(1)
  print(c.recv())
|};
  [%expect {|
    error: `c` may be a description of `sync.channel`, which keeps state, so it isn't called as a method
      ┌─ test.ren:5:5
    5 │   c.send(1)
      │     ^^^^
      = a call as a method makes a fresh instance, so its state would start again at each call
      help: install it: `with c in Chan.send(1)`

    error: `c` may be a description of `sync.channel`, which keeps state, so it isn't called as a method
      ┌─ test.ren:6:11
    6 │   print(c.recv())
      │           ^^^^
      = a call as a method makes a fresh instance, so its state would start again at each call
      help: install it: `let recv: Option<Int> = with c in Chan.recv()`
    |}]

let%expect_test "[s8 accept] the generic description's help, pasted in, checks" =
  types
    {|
import sync.{Chan}

fn main() uses Console, Async =
  let c: Chan<Int> uses Async = sync.channel(4)
  with c in Chan.send(1)
  let recv: Option<Int> = with c in Chan.recv()
  print(recv)
|};
  [%expect {| fn main() uses Async, Console |}]

let%expect_test "[s8 reject] an update's target, a record and a constructor, is refused with an update's help" =
  (* left out, an update's target is its base's type *)
  check_error
    {|
type Rect = { w: Int, h: Int }

type Shape =
  | Rect { w: Int, h: Int }
  | Dot

fn f(r: Rect) -> Rect = Rect { ..r, w: 1 }

fn main() = ()
|};
  [%expect {|
    error: `Rect` is a record type here, and a constructor of `Shape` too
      ┌─ test.ren:7:25
    7 │ fn f(r: Rect) -> Rect = Rect { ..r, w: 1 }
      │                         ^^^^
      help: write `Shape.Rect { ..base }` for the constructor, or `{ ..base }` with the type left out for the base's own type
    |}]

let%expect_test "[s8 accept] the update's help, pasted in, checks" =
  types
    {|
type Rect = { w: Int, h: Int }

type Shape =
  | Rect { w: Int, h: Int }
  | Dot

fn f(r: Rect) -> Rect = { ..r, w: 1 }

fn g(s: Shape) -> Shape =
  match s
    Shape.Rect { .. } as q => Shape.Rect { ..q, w: 1 }
    Dot => Dot

fn main() = ()
|};
  [%expect {|
    fn f(r: Rect) -> Rect
    fn g(s: Shape) -> Shape
    fn main()
    |}]

let%expect_test "[s8 accept] a handler given a small record, a tuple and an option" =
  (* natively, a release build keeps their types boxed in its
     description (bench/data/review_state.ren) *)
  run
    {|
dep Area =
  area: fn() -> Str

type Pt = { x: Int, y: Int }

handler at(p: Pt, q: (Str, Int), o: Option<Str>) for Area =
  let { x, y } = p
  let (s, n) = q
  area() => s.concat(show(x + y + n)).concat(o orelse "")

fn main() uses Console =
  let d: Area = at(Pt { x: 1, y: 2 }, ("p", 3), Some("!"))
  print(d.area())
|};
  [%expect {|
    p6!
    ()
    |}]
