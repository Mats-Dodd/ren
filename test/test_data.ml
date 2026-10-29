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
      help: add an arm for `Rect { .. }`, or a `_ =>` arm for the rest
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
  until "s3"
    ~want:{|
1
3
8
50
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s3)
    error: expected `=>`, found `|`
      ┌─ test.ren:9:12
    9 │     Pro(n) | Team(n) | Enterprise { seats: n, .. } => n
      │            ^
    |}]

let%expect_test "[s3 accept] an or-pattern nested inside a constructor" =
  until "s3"
    ~want:{|
true
false
false
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s3)
    error: expected `,` or `)`, found `|`
      ┌─ test.ren:9:17
    9 │     Some(Pro(_) | Team(_)) => true
      │                 ^
    |}]

let%expect_test "[s3 accept] `as` binds the whole of what a pattern matched" =
  (* it binds looser than `|`: `A | B as x` names the whole *)
  until "s3"
    ~want:{|
Team(9)
Some(Pro(2))
Free
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s3)
    error: expected `=>`, found `as`
      ┌─ test.ren:9:12
    9 │     Pro(n) as old => if n > 5 then Team(n) else old
      │            ^^

    error: expected `,` or `)`, found `as`
       ┌─ test.ren:16:17
    16 │     Some(Pro(_) as inner) as whole => print(whole)
       │                 ^^
    |}]

let%expect_test "[s3 accept] `let ... else` that fails" =
  until "s3"
    ~want:{|
Ok(6)
Err(NotTeam)
()
|}
    (fun () ->
      run
        (plan_types
       ^ {|
fn team_seats(p: Plan) -> Int ! NotTeam =
  let Team(n) = p else fail NotTeam
  n

fn main() uses Console =
  print(attempt team_seats(Team(6)))
  print(attempt team_seats(Free))
|}));
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Team(n)` might not
      ┌─ test.ren:8:7
    8 │   let Team(n) = p else fail NotTeam
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

let%expect_test "[s3 accept] `let ... else` that breaks, and a by-name pattern" =
  until "s3"
    ~want:{|
5
Ok(51)
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Team(s)` might not
       ┌─ test.ren:10:9
    10 │     let Team(s) = p else break
       │         ^^^^^^^
       help: take it apart with a `match`, which says what happens when it doesn't match

    error: expected the end of the line, found `else`
       ┌─ test.ren:15:42
    15 │   let Enterprise { seats, contract } = p else fail NotEnterprise
       │                                          ^^^^
    |}]

let%expect_test "[s3 accept] `let ... else` whose else is a block or an `if` that leaves" =
  until "s3"
    ~want:{|
said
Err(Missing)
Err(Small)
()
|}
    (fun () ->
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
|});
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(n)` might not
      ┌─ test.ren:2:7
    2 │   let Some(n) = o else
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

let%expect_test "[s3 accept] a `let` takes apart a type of one variant" =
  (* it always matches, so it needs no `else` *)
  until "s3"
    ~want:{|
3
()
|}
    (fun () ->
      run
        {|
type Meters =
  | Meters(Int)

fn main() uses Console =
  let Meters(n) = Meters(3)
  print(n)
|});
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Meters(n)` might not
      ┌─ test.ren:5:7
    5 │   let Meters(n) = Meters(3)
      │       ^^^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
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
  until "s3"
    ~says:
      [
        "error: `n` is bound in `Pro(n)` but not in `Free`";
        "help: bind the same names in every alternative";
      ]
    (fun () ->
      check_error
        (plan_types
       ^ {|
fn f(p: Plan) -> Int =
  match p
    Pro(n) | Free => n
    _ => 0
fn main() = ()
|}));
  [%expect {|
    (until s3)
    error: expected `=>`, found `|`
      ┌─ test.ren:9:12
    9 │     Pro(n) | Free => n
      │            ^
    |}]

let%expect_test "[s3 reject] a name bound to two types by two alternatives" =
  until "s3"
    ~says:
      [
        "error: `n` is an `Int` in `A(n)`, but a `Str` in `B(n)`";
        "help: bind it to one type in every alternative";
      ]
    (fun () ->
      check_error
        {|
type T =
  | A(Int)
  | B(Str)

fn f(t: T) -> Int =
  match t
    A(n) | B(n) => 0
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: expected `=>`, found `|`
      ┌─ test.ren:7:10
    7 │     A(n) | B(n) => 0
      │          ^
    |}]

let%expect_test "[s3 reject] an alternative that never matches" =
  until "s3"
    ~says:
      [
        "error: this alternative never matches";
        "help: the alternatives before it, or the arms above, already match \
         all of it";
      ]
    (fun () ->
      check_error
        (plan_types
       ^ {|
fn f(p: Plan) -> Int =
  match p
    Pro(_) | Pro(_) => 1
    _ => 0
fn main() = ()
|}));
  [%expect {|
    (until s3)
    error: expected `=>`, found `|`
      ┌─ test.ren:9:12
    9 │     Pro(_) | Pro(_) => 1
      │            ^
    |}]

let%expect_test "[s3 reject] the `else` of a `let ... else` has to leave" =
  until "s3"
    ~says:
      [
        "error: the `else` of a `let ... else` has to leave";
        "help: end it with `fail`, `break` or `todo`";
      ]
    (fun () ->
      check_error
        {|
fn f(o: Option<Int>) -> Int =
  let Some(n) = o else 0
  n
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(n)` might not
      ┌─ test.ren:2:7
    2 │   let Some(n) = o else 0
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

let%expect_test "[s3 reject] a `let ... else` whose pattern always matches" =
  until "s3"
    ~says:
      [
        "error: this pattern always matches, so the `else` never runs";
        "help: remove the `else`";
      ]
    (fun () ->
      check_error
        {|
fn f(p: (Int, Int)) -> Int ! Never =
  let (a, b) = p else fail Never
  a + b
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `else`
      ┌─ test.ren:2:18
    2 │   let (a, b) = p else fail Never
      │                  ^^^^
    |}]

let%expect_test "[s3 reject] a `let` whose pattern might not match needs an `else`" =
  until "s3"
    ~says:
      [
        "error: `Some(n)` might not match, so this `let` needs an `else`";
        "help: add one that leaves, `let Some(n) = o else fail ...`, or use a \
         `match`";
      ]
    (fun () ->
      check_error {|
fn f(o: Option<Int>) -> Int =
  let Some(n) = o
  n
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(n)` might not
      ┌─ test.ren:2:7
    2 │   let Some(n) = o
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

let%expect_test "[s3 reject] a `for` takes apart only what always matches" =
  until "s3"
    ~says:
      [
        "error: a `for` takes apart only what always matches, but `Some(n)` \
         might not";
        "help: take it apart with a `match`, which says what happens when it \
         doesn't match";
      ]
    (fun () ->
      check_error
        {|
fn f(xs: Array<Option<Int>>) -> Int =
  var t = 0
  for Some(n) in xs
    t += n
  t
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: expected `in`, found `(`
      ┌─ test.ren:3:11
    3 │   for Some(n) in xs
      │           ^
    |}]

let%expect_test "[s3 reject] Ren has no `if let`" =
  until "s3"
    ~says:
      [
        "error: Ren has no `if let`";
        "help: write a `match`, or `let Some(n) = o else ...`";
      ]
    (fun () ->
      check_error
        {|
fn f(o: Option<Int>) -> Int =
  if let Some(n) = o then n else 0
fn main() = ()
|});
  [%expect {|
    (until s3)
    error: expected an expression, found `let`
      ┌─ test.ren:2:6
    2 │   if let Some(n) = o then n else 0
      │      ^^^
    |}]

let%expect_test "[s3 reject] a `fail` pattern isn't bound with `as`" =
  until "s3"
    ~says:
      [
        "error: a `fail` pattern can't bind the whole error to a name";
        "help: match each tag, like `fail NotFound`, or keep the whole outcome \
         as a value with `attempt`, and match `Err(e)`";
      ]
    (fun () ->
      check_error
        {|
fn take(n: Int) -> Int ! Short(Int) = if n > 3 then fail Short(n) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(_) as e => print(0)
|});
  [%expect {|
    (until s3)
    error: expected `=>`, found `as`
      ┌─ test.ren:6:19
    6 │     fail Short(_) as e => print(0)
      │                   ^^
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
  until "s4"
    ~want:
      {|
fn place(d: Order.Draft, id: Int) -> Order
fn ship(p: Order.Placed, tracking: Str) -> Order
fn step(o: Order) -> Order
fn main()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:6:18
    6 │ fn place(d: Order.Draft, id: Int) -> Order =
      │                  ^

    error: expected `,` or `)`, found `.`
      ┌─ test.ren:9:17
    9 │ fn ship(p: Order.Placed, tracking: Str) -> Order = Shipped { id: p.id, tracking }
      │                 ^

    error: expected `=>`, found `as`
       ┌─ test.ren:13:18
    13 │     Draft { .. } as d => place(d, 1)
       │                  ^^
    |}]

let%expect_test "[s4 accept] a variant type is a record: fields, patterns and update" =
  until "s4"
    ~want:
      {|
7
[1, 2]
Placed { id: 7, lines: [1, 2], total: 30 }
Placed { id: 7, lines: [1, 2], total: 99 }
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s4)
    error: expected `=>`, found `as`
      ┌─ test.ren:8:19
    8 │     Placed { .. } as p =>
      │                   ^^
    |}]

let%expect_test "[s4 accept] back to the sum with `Placed { ..p }`" =
  until "s4"
    ~want:
      {|
fn back(p: Order.Placed) -> Order
fn bumped(p: Order.Placed) -> Order
fn main()
|}
    (fun () ->
      types
        (order_sum
       ^ {|
fn back(p: Order.Placed) -> Order = Placed { ..p }
fn bumped(p: Order.Placed) -> Order = Placed { ..p, total: p.total + 1 }
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:6:17
    6 │ fn back(p: Order.Placed) -> Order = Placed { ..p }
      │                 ^

    error: expected `,` or `)`, found `.`
      ┌─ test.ren:7:19
    7 │ fn bumped(p: Order.Placed) -> Order = Placed { ..p, total: p.total + 1 }
      │                   ^
    |}]

let%expect_test "[s4 accept] a variant type goes anywhere: returned, stored, passed" =
  until "s4"
    ~want:{|
2
Some(Placed { id: 1, lines: [], total: 4 })
Box { p: Placed { id: 2, lines: [], total: 5 } }
()
|}
    (fun () ->
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
|}));
  [%expect {|
    (until s4)
    error: expected `,` or `}`, found `.`
      ┌─ test.ren:6:22
    6 │ type Box = { p: Order.Placed }
      │                      ^

    error: expected `,` or `>`, found `.`
      ┌─ test.ren:8:36
    8 │ fn placed(o: Order) -> Option<Order.Placed> =
      │                                    ^

    error: expected `,` or `>`, found `.`
       ┌─ test.ren:14:22
    14 │   var ps: Array<Order.Placed> = []
       │                      ^
    |}]

let%expect_test "[s4 accept] a variant type's `==`, order, `hash` and `show` are its sum's" =
  (* `Order`'s `key` is its id, so two placed orders of one id are equal
     as `Order.Placed` too (language.md §2, "Derived operations are
     borrowed") *)
  until "s4"
    ~want:{|
true
true
1
Placed { id: 1, total: 2 }
()
|}
    (fun () ->
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
|});
  [%expect {|
    (until s4)
    error: expected `=`, found `.`
       ┌─ test.ren:10:29
    10 │ fn placed(o: Order) -> Order.Placed =
       │                             ^
    |}]

let%expect_test "[s4 accept] a generic sum's variant type" =
  until "s4"
    ~want:
      {|
fn left<T>(n: Tree.Node<T>) -> Tree<T>
fn main()
|}
    (fun () ->
      types
        {|
type Tree<T> =
  | Leaf
  | Node { left: Tree<T>, value: T, right: Tree<T> }

fn left<T>(n: Tree.Node<T>) -> Tree<T> = n.left
fn main() = ()
|});
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:5:19
    5 │ fn left<T>(n: Tree.Node<T>) -> Tree<T> = n.left
      │                   ^
    |}]

let%expect_test "[s4 accept] an or-pattern of several variants binds the sum" =
  until "s4"
    ~want:{|
fn id(o: Order) -> Int
fn main()
|}
    (fun () ->
      types
        (order_sum
       ^ {|
fn id(o: Order) -> Int =
  match o
    Placed { .. } | Shipped { .. } as s => same(s)
    Draft { .. } => 0

fn same(o: Order) -> Int = 1
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: expected `=>`, found `|`
      ┌─ test.ren:8:19
    8 │     Placed { .. } | Shipped { .. } as s => same(s)
      │                   ^
    |}]

let%expect_test "[s4 reject] a constructor builds the sum, not its variant type" =
  until "s4"
    ~says:
      [
        "error: expected `Order.Placed`, found `Order`";
        "= a constructor always builds the sum; a variant type is bound by a \
         pattern's `as`";
        "help: `Order.Placed` is one variant of `Order`: match it and bind \
         that with `as`, `Placed { .. } as p`";
      ]
    (fun () ->
      check_error
        (order_sum
       ^ {|
fn make() -> Order.Placed = Placed { id: 1, lines: [], total: 0 }
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: expected `=`, found `.`
      ┌─ test.ren:6:19
    6 │ fn make() -> Order.Placed = Placed { id: 1, lines: [], total: 0 }
      │                   ^
    |}]

let%expect_test "[s4 reject] a variant type isn't its sum" =
  until "s4"
    ~says:
      [
        "error: expected `Order`, found `Order.Placed`";
        "help: make it the sum: `Placed { ..p }`";
      ]
    (fun () ->
      check_error
        (order_sum
       ^ {|
fn total(o: Order) -> Int = 0
fn f(p: Order.Placed) -> Int = total(p)
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:7:14
    7 │ fn f(p: Order.Placed) -> Int = total(p)
      │              ^
    |}]

let%expect_test "[s4 reject] a positional variant has no type of its own" =
  until "s4"
    ~says:
      [
        "error: `Discount.Flat` isn't a type: only a variant with named fields \
         has one";
        "help: take its field out where it's matched, `Flat(off) => ...`";
      ]
    (fun () ->
      check_error
        {|
type Discount =
  | NoDiscount
  | Flat(off: Int)

fn f(d: Discount.Flat) -> Int = 0
fn main() = ()
|});
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:5:17
    5 │ fn f(d: Discount.Flat) -> Int = 0
      │                 ^
    |}]

let%expect_test "[s4 reject] a variant type names a variant its sum has" =
  until "s4"
    ~says:
      [ "error: `Order` has no variant `Placd`"; "help: did you mean `Placed`?" ]
    (fun () ->
      check_error (order_sum ^ {|
fn f(p: Order.Placd) -> Int = 0
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:6:14
    6 │ fn f(p: Order.Placd) -> Int = 0
      │              ^
    |}]

let%expect_test "[s4 reject] only a sum type has variants" =
  until "s4"
    ~says:
      [
        "error: `User` isn't a sum type, so it has no variants";
        "help: a variant type is one of a sum's, like `Order.Placed`";
      ]
    (fun () ->
      check_error
        {|
type User = { id: Int }
fn f(u: User.Admin) -> Int = 0
fn main() = ()
|});
  [%expect {|
    (until s4)
    error: expected `,` or `)`, found `.`
      ┌─ test.ren:2:13
    2 │ fn f(u: User.Admin) -> Int = 0
      │             ^
    |}]

let%expect_test "[s4 reject] `..` doesn't take the rest from a sum" =
  until "s4"
    ~says:
      [
        "error: `..o` takes the rest from a record, but `o` is an `Order`, a \
         sum type";
        "help: match it, and take the rest from the variant: `Placed { .. } as \
         p => Placed { ..p, ... }`";
      ]
    (fun () ->
      check_error
        (order_sum
       ^ {|
fn f(o: Order) -> Order = Placed { ..o, total: 0 }
fn main() = ()
|}));
  [%expect {|
    (until s4)
    error: `..o` takes the rest from a record, but `o` is an `Order`
      ┌─ test.ren:6:38
    6 │ fn f(o: Order) -> Order = Placed { ..o, total: 0 }
      │                                      ^
      help: write every field, without `..`
    |}]

let%expect_test "[s4 reject] a variant type has no methods of its own" =
  until "s4"
    ~says:
      [
        "error: `Order.Placed` has no methods of its own";
        "help: call it on the sum: `Placed { ..p }.size()`";
      ]
    (fun () ->
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
|});
  [%expect {|
    (until s4)
    error: expected `=>`, found `as`
      ┌─ test.ren:9:19
    9 │     Placed { .. } as p => p.size()
      │                   ^^
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
  until "s5"
    ~says:
      [
        "error: `Shape` is a sum type; only `Ring` has `r`";
        "help: take it from `Ring` with a `match`:";
        "match s";
        "Ring { r, .. } => r";
        "_ => todo";
      ]
    (fun () -> check_error (shapes ^ {|
fn f(s: Shape) -> Int = s.r
fn main() = ()
|}));
  [%expect {|
    (until s5)
    error: `.r` needs a record, but this is a `Shape`
      ┌─ test.ren:7:27
    7 │ fn f(s: Shape) -> Int = s.r
      │                           ^
    |}]

let%expect_test "[s5 reject] a field two variants have" =
  until "s5"
    ~says:
      [
        "error: `Shape` is a sum type; only `Rect`, `Frame` and `Ring` have `id`";
        "help: take it from them with a `match`:";
        "Rect { id, .. } | Frame { id, .. } | Ring { id, .. } => id";
        "_ => todo";
      ]
    (fun () -> check_error (shapes ^ {|
fn f(s: Shape) -> Int = s.id
fn main() = ()
|}));
  [%expect {|
    (until s5)
    error: `.id` needs a record, but this is a `Shape`
      ┌─ test.ren:7:27
    7 │ fn f(s: Shape) -> Int = s.id
      │                           ^^
    |}]

let%expect_test "[s5 reject] a field every variant has: hoist it" =
  until "s5"
    ~says:
      [
        "error: every variant of `Shape` has `id`, but a sum type has no fields";
        "help: hoist it into a record, `type Shape = { id: Int, kind: \
         ShapeKind }`, or write a method that matches each variant";
      ]
    (fun () ->
      check_error
        {|
type Shape =
  | Rect { id: Int, w: Int, h: Int }
  | Ring { id: Int, r: Int }

fn f(s: Shape) -> Int = s.id
fn main() = ()
|});
  [%expect {|
    (until s5)
    error: `.id` needs a record, but this is a `Shape`
      ┌─ test.ren:5:27
    5 │ fn f(s: Shape) -> Int = s.id
      │                           ^^
    |}]

let%expect_test "[s5 reject] a `match` that misses cases prints the arms to paste" =
  until "s5"
    ~says:
      [
        "error: this `match` doesn't handle every `Option`";
        "help: add the missing arms, or a `_ =>` arm for the rest:";
        "Some(Closed) => todo";
      ]
    (fun () ->
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
|});
  [%expect {|
    (until s5)
    error: this `match` doesn't handle every `Option`
      ┌─ test.ren:6:3
    6 │   match d
      │   ^^^^^
      = missing: Some(Closed)
      help: add an arm for `Some(Closed)`, or a `_ =>` arm for the rest
    |}]

let%expect_test "[s5 reject] the arms to paste, by name, and the rest" =
  (* three are printed; if more may be missing, a `_` arm after them *)
  until "s5"
    ~says:
      [
        "help: add the missing arms, or a `_ =>` arm for the rest:";
        "Rect { .. } => todo";
        "Frame { .. } => todo";
        "Ring { .. } => todo";
      ]
    (fun () ->
      check_error (shapes ^ {|
fn f(s: Shape) -> Int =
  match s
    Dot => 0
fn main() = ()
|}));
  [%expect {|
    (until s5)
    error: this `match` doesn't handle every `Shape`
      ┌─ test.ren:8:3
    8 │   match s
      │   ^^^^^
      = missing: Rect { .. }, Frame { .. }, Ring { .. }
      help: add an arm for `Rect { .. }`, or a `_ =>` arm for the rest
    |}]

let%expect_test "[s5 reject] a missing error is a `fail` arm to paste" =
  until "s5"
    ~says:
      [
        "help: add the missing arms, or a `fail _ =>` arm for the rest, or pass \
         them on with `try match`:";
        "fail Late(_) => todo";
      ]
    (fun () ->
      check_error
        {|
fn take(n: Int) -> Int ! Short(Int) | Late(Int) =
  if n > 3 then fail Short(n) else if n < 0 then fail Late(n) else n

fn main() uses Console =
  match take(5)
    n => print(n)
    fail Short(x) => print(x)
|});
  [%expect {|
    (until s5)
    error: this `match` doesn't handle every error it can fail with
      ┌─ test.ren:5:3
    5 │   match take(5)
      │   ^^^^^
      = missing: fail Late(_)
      help: add an arm for `fail Late(_)`, or a `fail _ =>` arm for the rest, or pass them on with `try match`
    |}]

let%expect_test "[s5 accept] `todo` has any type, and panics where it's reached" =
  until "s5"
    ~says:[ "panic: reached a `todo`" ]
    (fun () ->
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
|});
  [%expect {|
    (until s5)
    error: there's no variable named `todo`
      ┌─ test.ren:8:14
    8 │     Green => todo
      │              ^^^^
    |}]

let%expect_test "[s5 accept] `todo` leaves a `let ... else`" =
  until "s5"
    ~want:{|
fn first(o: Option<Int>) -> Int
fn main()
|}
    (fun () ->
      types
        {|
fn first(o: Option<Int>) -> Int =
  let Some(n) = o else todo
  n

fn main() = ()
|});
  [%expect {|
    (until s5)
    error: a `let` takes apart only a tuple or a record, of names and `_`, which always matches, but `Some(n)` might not
      ┌─ test.ren:2:7
    2 │   let Some(n) = o else todo
      │       ^^^^^^^
      help: take it apart with a `match`, which says what happens when it doesn't match
    |}]

(* ---- s6: descriptions, an operation called only on a stateless one ---- *)

let%expect_test "[s6 reject] a stateful handler's description isn't called as a method" =
  (* language.md's trap: each call started `counter` fresh, so it printed
     1 and 1. The check is the linked program's (compiler.md, "Data
     stage", step 6), so it's `ren run`'s *)
  until "s6"
    ~says:
      [
        "error: `c` may be a description of `counter`, which keeps state, so \
         it isn't called as a method";
        "help: install it: `with c in Area.area()`";
      ]
    (fun () ->
      run
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
|});
  [%expect {|
    (until s6)
    1
    1
    ()
    |}]

let%expect_test "[s6 reject] a handler with a `finally` isn't called as a method" =
  until "s6"
    ~says:
      [
        "error: `l` may be a description of `logged`, which has a `finally`, \
         so it isn't called as a method";
        "help: install it: `with l in Area.area()`";
      ]
    (fun () ->
      run
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
|});
  [%expect {|
    (until s6)
    done
    1
    ()
    |}]

let%expect_test "[s6 reject] any handler a description may be counts" =
  (* the closed world: a stored `Area` may be any handler of `Area` whose
     description the program makes as a value *)
  until "s6"
    ~says:
      [
        "error: `a` may be a description of `counter`, which keeps state, so \
         it isn't called as a method";
        "help: install it: `with a in Area.area()`";
      ]
    (fun () ->
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

fn total(xs: Array<Area>) -> Int =
  var t = 0
  for a in xs
    t += a.area()
  t

fn main() uses Console =
  print(total([square(2), counter()]))
|});
  [%expect {|
    (until s6)
    5
    ()
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
    Area.area()
    print(Area.area())
|};
  [%expect {|
    error: `area` returns `Int`, and this throws it away
       ┌─ test.ren:20:5
    20 │     Area.area()
       │     ^^^^^^^^^^^
       help: use it, or write `let _ = ...` if you mean to drop it
    |}]

(* ---- the program of language.md's "A program, end to end", without
   `|>` and wirings: domain types by name, a policy that's data, an
   opaque `Order`, the services the workflow needs, a `try` on each step
   that can fail, and a test handler made of data. It needs steps 1 to
   3 ---- *)

let%expect_test "[s3 accept] a program, end to end" =
  until "s3"
    ~want:
      {|
test.ren
  ✓ a flat discount comes off the total
  ✓ an amount under the minimum gets nothing off
  ✓ an abandoned cart is refused

3 passed
[exit 0]
|}
    (fun () ->
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
|});
  [%expect {|
    (until s3)
    error: expected the end of the line, found `else`
       ┌─ test.ren:34:33
    34 │   let Open { lines, .. } = cart else fail Empty
       │                                 ^^^^
    |}]
