(* Programs of several modules: loading the import graph, checking each
   module against what it imports, and running them as one program. Each
   test's files are listed by name, the entry first. *)

open Helpers

let%expect_test "a function of another module, called through its alias" =
  run_files
    [
      ("main.ren", {|
import util
fn main() = util.double(2)
|});
      ("util.ren", {|
pub fn double(n: Int) -> Int = n * 2
|});
    ];
  [%expect {| 4 |}]

let%expect_test "modules in folders, and an alias" =
  run_files
    [
      ( "main.ren",
        {|
import billing/stripe as pay
import util
fn main() = util.double(pay.charge(5))
|}
      );
      ("util.ren", {|
pub fn double(n: Int) -> Int = n * 2
|});
      ( "billing/stripe.ren",
        {|
import util
pub fn charge(n: Int) -> Int = util.double(n) + fee()
fn fee() = 1
|}
      );
    ];
  [%expect {| 22 |}]

let%expect_test "every module's types, in the order they're checked" =
  (* a module imported twice is loaded once, before both *)
  types_files
    [
      ("main.ren", {|
import a
import b
fn main() = a.one() + b.two()
|});
      ("a.ren", {|
import base
pub fn one() -> Int = base.zero() + 1
|});
      ( "b.ren",
        {|
import base
pub fn two() -> Int = base.zero() + 2
fn id(x) = x
|} );
      ("base.ren", {|
pub fn zero() -> Int = 0
|});
    ];
  [%expect
    {|
    -- base
    pub fn zero() -> Int

    -- a
    pub fn one() -> Int

    -- b
    pub fn two() -> Int
    fn id<T>(x: T) -> T

    -- main
    fn main() -> Int
    |}]

let%expect_test "an import cycle" =
  check_error_files
    [
      ("main.ren", {|
import billing/stripe
fn main() = 1
|});
      ("billing/stripe.ren", {|
import billing/invoice
pub fn f() = 1
|});
      ("billing/invoice.ren", {|
import billing/stripe
pub fn g() = 1
|});
    ];
  [%expect
    {|
    error: import cycle: billing/stripe → billing/invoice → billing/stripe
      ┌─ billing/invoice.ren:1:1
    1 │ import billing/stripe
      │ ^^^^^^^^^^^^^^^^^^^^^
      ┌─ billing/stripe.ren:1:1
    1 │ import billing/invoice
      │ ---------------------- `billing/stripe` imports `billing/invoice` here
      help: move what both modules need into a third module that both can import
    |}]

let%expect_test "a cycle through the entry" =
  run_files
    [
      ("main.ren", {|
import util
fn main() = 1
|});
      ("util.ren", {|
import main
pub fn f() = 1
|});
    ];
  [%expect
    {|
    error: import cycle: main → util → main
      ┌─ util.ren:1:1
    1 │ import main
      │ ^^^^^^^^^^^
      ┌─ main.ren:1:1
    1 │ import util
      │ ----------- `main` imports `util` here
      help: move what both modules need into a third module that both can import
    |}]

let%expect_test "a module that imports itself" =
  run_files
    [
      ("main.ren", {|
import util
fn main() = 1
|});
      ("util.ren", {|
import util
pub fn f() = 1
|});
    ];
  [%expect
    {|
    error: import cycle: util → util
      ┌─ util.ren:1:1
    1 │ import util
      │ ^^^^^^^^^^^
      help: remove it: a module's own names are in scope without importing it
    |}]

let%expect_test "a module that doesn't exist" =
  run_files [ ("main.ren", {|
import billing/strip
fn main() = 1
|}) ];
  [%expect
    {|
    error: there's no module `billing/strip`
      ┌─ main.ren:1:8
    1 │ import billing/strip
      │        ^^^^^^^^^^^^^
      = it would be the file `billing/strip.ren`
      help: check the module's name, or create its file
    |}]

let%expect_test "the prelude can't be imported" =
  run_files [ ("main.ren", {|
import prelude
fn main() = 1
|}) ];
  [%expect
    {|
    error: `prelude` is always imported, so it can't be imported again
      ┌─ main.ren:1:8
    1 │ import prelude
      │        ^^^^^^^
      help: remove this import
    |}]

let%expect_test "two imports with the same alias" =
  run_files
    [
      ("main.ren", {|
import billing/util
import util
fn main() = 1
|});
      ("util.ren", {|
pub fn f() = 1
|});
      ("billing/util.ren", {|
pub fn f() = 1
|});
    ];
  [%expect
    {|
    error: there are two imports named `util`
      ┌─ main.ren:2:8
    1 │ import billing/util
      │                ---- the first `util` is here
    2 │ import util
      │        ^^^^
      help: import one of them `as` something else
    |}]

let%expect_test "an error in an imported module points into its file" =
  run_files
    [
      ("main.ren", {|
import util
fn main() = util.double(2)
|});
      ("util.ren", {|
pub fn double(n: Int) -> Int = n * true
|});
    ];
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ util.ren:1:36
    1 │ pub fn double(n: Int) -> Int = n * true
      │                                    ^^^^
      = `*` works on `Int`s
    |}]

let%expect_test "only a public function can be called from another module" =
  run_files
    [
      ("main.ren", {|
import util
fn main() = util.helper()
|});
      ("util.ren", {|
fn helper() = 1
|});
    ];
  [%expect
    {|
    error: `util` has no public `helper`
      ┌─ main.ren:2:18
    2 │ fn main() = util.helper()
      │                  ^^^^^^
      help: if it's defined there, mark it `pub`
    |}]

let%expect_test "a missing use is blamed on the call that has it" =
  run_files
    [
      ( "main.ren",
        {|
import lib
pub fn go() =
  let a = lib.quiet(1)
  lib.say(a)
fn main() = go()
|}
      );
      ( "lib.ren",
        {|
pub fn quiet(n: Int) -> Int = n
pub fn say(n: Int) uses Console = print(n)
|}
      );
    ];
  [%expect
    {|
    error: `go` doesn't declare `Console`
      ┌─ main.ren:2:8
    2 │ pub fn go() =
      │        ^^
    4 │   lib.say(a)
      │   ---------- this call uses `Console`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Console`
    |}]

let%expect_test "another module's function is written with its alias" =
  run_files
    [
      ( "main.ren",
        {|
import billing/stripe
import util
fn main() = charge(1) + stripe.charge(2)
|}
      );
      ("billing/stripe.ren", {|
pub fn charge(n: Int) -> Int = n
|});
      ("util.ren", {|
pub fn charge(n: Int) -> Int = n
|});
    ];
  [%expect
    {|
    error: `charge` isn't defined here
      ┌─ main.ren:3:13
    3 │ fn main() = charge(1) + stripe.charge(2)
      │             ^^^^^^
      help: write `stripe.charge` or `util.charge`
    |}]

let%expect_test "a local can't have an imported module's name" =
  run_files
    [
      ( "main.ren",
        {|
import billing/stripe
fn main() =
  let stripe = 1
  let f = fn(util) => util
  stripe.charge(stripe)
|}
      );
      ("billing/stripe.ren", {|
pub fn charge(n: Int) -> Int = n
|});
    ];
  [%expect
    {|
    error: `stripe` is the name of an imported module
      ┌─ main.ren:3:7
    1 │ import billing/stripe
      │                ------ `stripe` is imported here
    3 │   let stripe = 1
      │       ^^^^^^
      help: rename it, or import the module `as` something else
    |}]

let%expect_test "nor can a function" =
  run_files
    [
      ( "main.ren",
        {|
import util as helpers
fn helpers() = 1
fn main() = helpers.f()
|} );
      ("util.ren", {|
pub fn f() -> Int = 1
|});
    ];
  [%expect
    {|
    error: `helpers` is the name of an imported module
      ┌─ main.ren:2:4
    1 │ import util as helpers
      │                ------- `helpers` is imported here
    2 │ fn helpers() = 1
      │    ^^^^^^^
      help: rename it, or import the module `as` something else
    |}]

let%expect_test "main is the entry module's" =
  run_files
    [
      ("main.ren", {|
import util
fn start() = util.main()
|});
      ("util.ren", {|
pub fn main() -> Int = 1
|});
    ];
  [%expect
    {|
    error: this program has no `main` function
      ┌─ main.ren:1:1
    1 │ import util
      │ ^
      help: add `fn main() = ...`, which is where the program starts
    |}]

(* ---- what a public declaration can mention ---- *)

let%expect_test "a public function can't mention a private type" =
  run
    {|
type Row = { id: Int }
pub fn load(id: Int) -> Row = Row { id: id }
pub fn ids(rows: Array<Row>) -> Int = rows.len()
fn main() = load(1).id
|};
  [%expect
    {|
    error: `pub fn load` returns `Row`, which is private to this module
      ┌─ test.ren:2:25
    1 │ type Row = { id: Int }
      │      --- `Row` is declared here, without `pub`
    2 │ pub fn load(id: Int) -> Row = Row { id: id }
      │                         ^^^
      help: mark `Row` `pub`

    error: `pub fn ids`'s signature mentions `Row`, which is private to this module
      ┌─ test.ren:3:24
    1 │ type Row = { id: Int }
      │      --- `Row` is declared here, without `pub`
    3 │ pub fn ids(rows: Array<Row>) -> Int = rows.len()
      │                        ^^^
      help: mark `Row` `pub`
    |}]

let%expect_test "a public type can't have a field of a private type" =
  run
    {|
type Row = { id: Int }
pub type Table = { first: Row, rest: Array<Row> }
pub type Cell =
  | Empty
  | Full(row: Row)
fn main() = 1
|};
  [%expect
    {|
    error: `pub type Table` has a field of type `Row`, which is private to this module
      ┌─ test.ren:2:27
    1 │ type Row = { id: Int }
      │      --- `Row` is declared here, without `pub`
    2 │ pub type Table = { first: Row, rest: Array<Row> }
      │                           ^^^
      help: mark `Row` `pub`

    error: `pub type Table`'s field `rest` mentions `Row`, which is private to this module
      ┌─ test.ren:2:44
    1 │ type Row = { id: Int }
      │      --- `Row` is declared here, without `pub`
    2 │ pub type Table = { first: Row, rest: Array<Row> }
      │                                            ^^^
      help: mark `Row` `pub`

    error: `pub type Cell`'s constructor `Full` holds `Row`, which is private to this module
      ┌─ test.ren:5:15
    1 │ type Row = { id: Int }
      │      --- `Row` is declared here, without `pub`
    5 │   | Full(row: Row)
      │               ^^^
      help: mark `Row` `pub`
    |}]

let%expect_test "a private declaration can mention anything" =
  run
    {|
type Row = { id: Int }
type Table = { first: Row }
fn load(id: Int) -> Row = Row { id: id }
pub fn count(n: Int) -> Int = n
fn main() = Table { first: load(count(1)) }.first.id
|};
  [%expect {| 1 |}]

let%expect_test "a public type's fields can be read in another module" =
  run_files
    [
      ("main.ren", {|
import rows
fn main() = rows.load(4).id
|});
      ( "rows.ren",
        {|
pub type Row = { id: Int }
pub fn load(id: Int) -> Row = Row { id: id }
|}
      );
    ];
  [%expect {| 4 |}]

(* ---- imports ---- *)

let rows =
  ( "rows.ren",
    {|
pub type Row = { id: Int }
pub type Table = { first: Row }
pub fn load(id: Int) -> Row = Row { id: id }
|}
  )

let%expect_test "a type imported by name is written bare" =
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row}
fn id(r: Row) -> Int = r.id
fn main() = id(Row { id: 3 }) + id(rows.load(4))
|}
      );
      rows;
    ];
  [%expect {| 7 |}]

let%expect_test "an import nothing uses" =
  run_files
    [ ("main.ren", {|
import rows
import rows as other
fn main() = 1
|}); rows ];
  [%expect
    {|
    error: `rows` is imported but never used
      ┌─ main.ren:1:1
    1 │ import rows
      │ ^^^^^^^^^^^
      help: remove it

    error: `rows` is imported but never used
      ┌─ main.ren:2:1
    2 │ import rows as other
      │ ^^^^^^^^^^^^^^^^^^^^
      help: remove it
    |}]

let%expect_test "a type imported by name that nothing uses" =
  run_files
    [
      ("main.ren", {|
import rows.{Row, Table}
fn main() = rows.load(1).id
|});
      rows;
    ];
  [%expect
    {|
    error: `Row` is imported but never used
      ┌─ main.ren:1:14
    1 │ import rows.{Row, Table}
      │              ^^^
      help: remove it

    error: `Table` is imported but never used
      ┌─ main.ren:1:19
    1 │ import rows.{Row, Table}
      │                   ^^^^^
      help: remove it
    |}];
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row} as r
fn id(x: Row) -> Int = x.id
fn main() = id(Row { id: 1 })
|}
      );
      rows;
    ];
  [%expect
    {|
    error: `r` is never used
      ┌─ main.ren:1:22
    1 │ import rows.{Row} as r
      │                      ^
      help: remove the `as r`
    |}];
  run_files [ ("main.ren", {|
import rows.{Row, Table}
fn main() = 1
|}); rows ];
  [%expect
    {|
    error: `rows` is imported but never used
      ┌─ main.ren:1:1
    1 │ import rows.{Row, Table}
      │ ^^^^^^^^^^^^^^^^^^^^^^^^
      help: remove it
    |}]

let%expect_test "only a public type can be imported by name" =
  run_files
    [
      ("main.ren", {|
import util.{Secret}
fn main() = util.f()
|});
      ("util.ren", {|
type Secret = { x: Int }
pub fn f() -> Int = 1
|});
    ];
  [%expect
    {|
    error: `util` has no public type `Secret`
      ┌─ main.ren:1:14
    1 │ import util.{Secret}
      │              ^^^^^^
      help: if it's defined there, mark it `pub`
    |}]

let%expect_test "a type imported by name can't share a name" =
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row}
import other.{Row}
type Row = { x: Int }
fn main(r: Row) = 1
|}
      );
      rows;
      ("other.ren", {|
pub type Row = { y: Int }
|});
    ];
  [%expect
    {|
    error: there are two types imported as `Row`
      ┌─ main.ren:2:15
    1 │ import rows.{Row}
      │              --- the first `Row` is here
    2 │ import other.{Row}
      │               ^^^
      help: import only one of them by name

    error: `Row` is already the name of an imported type
      ┌─ main.ren:3:6
    1 │ import rows.{Row}
      │              --- `Row` is imported here
    3 │ type Row = { x: Int }
      │      ^^^
      help: rename it, or stop importing `Row` by name
    |}]

(* ---- types across modules ---- *)

let%expect_test "a type written with its module's alias" =
  run_files
    [
      ( "main.ren",
        {|
import rows
fn first(t: rows.Table) -> rows.Row = t.first
fn main() = first(rows.Table { first: rows.load(5) }).id
|}
      );
      rows;
    ];
  [%expect {| 5 |}]

let%expect_test "a type written with an alias that isn't imported" =
  run_files
    [
      ( "main.ren",
        {|
import rows
fn f(r: rws.Row) -> rows.Secret = r
fn main() = 1
|} );
      rows;
    ];
  [%expect
    {|
    error: there's no module imported as `rws`
      ┌─ main.ren:2:9
    2 │ fn f(r: rws.Row) -> rows.Secret = r
      │         ^^^
      help: import it at the top of the file, like `import rws`

    error: `rows` has no public type `Secret`
      ┌─ main.ren:2:26
    2 │ fn f(r: rws.Row) -> rows.Secret = r
      │                          ^^^^^^
      help: if it's defined there, mark it `pub`
    |}]

(* a field of a type from a module main never imported is still
   readable: the type is found through the value *)
let orders =
  [
    ( "main.ren",
      {|
import orders
fn latest() = orders.latest()
fn main() = latest().total
|}
    );
    ( "orders.ren",
      {|
import billing/invoice
pub fn latest() -> invoice.Invoice = invoice.make(7)
|}
    );
    ( "billing/invoice.ren",
      {|
pub type Invoice = { total: Int, plan: Plan }
pub type Plan = Free | Pro(seats: Int)
pub fn make(total: Int) -> Invoice = Invoice { total: total, plan: Pro(seats: 2) }
|}
    );
  ]

let%expect_test "a field of a type whose module isn't imported" =
  run_files orders;
  [%expect {| 7 |}];
  (* each module writes a type the shortest way it can *)
  types_files orders;
  [%expect
    {|
    -- billing/invoice
    pub fn make(total: Int) -> Invoice

    -- orders
    pub fn latest() -> invoice.Invoice

    -- main
    fn latest() -> billing/invoice.Invoice
    fn main() -> Int
    |}]

let billing = ("billing.ren", {|
pub type Plan = Free | Pro(seats: Int)
|})

let%expect_test "a constructor is found through the type it's expected to be" =
  (* `Free` works wherever a `billing.Plan` is expected, though `Plan`
     isn't imported by name; so does the full `billing.Plan.Free` *)
  run_files
    [
      ( "main.ren",
        {|
import billing
fn price(p: billing.Plan) -> Int =
  match p
    Free => 0
    billing.Plan.Pro(seats) => seats * 10
fn main() = price(Pro(seats: 3)) + price(billing.Plan.Free)
|}
      );
      billing;
    ];
  [%expect {| 30 |}];
  (* this module's own `Free` is the only one it can name bare *)
  run_files
    [
      ( "main.ren",
        {|
import billing
type Tier = Free | Paid
fn tier(t: Tier) -> Int = match t
  Free => 0
  Paid => 1
fn price(p: billing.Plan) -> Int = 5
fn main() = tier(Free) + price(Free) + tier(Paid)
|}
      );
      billing;
    ];
  [%expect {| 6 |}];
  run_files
    [
      ( "main.ren",
        {|
import billing
fn free() -> billing.Plan = billing.Plan.Free
fn main() = print(Free)
|}
      );
      billing;
    ];
  [%expect
    {|
    error: no type in scope here has a constructor named `Free`
      ┌─ main.ren:3:19
    3 │ fn main() = print(Free)
      │                   ^^^^
      help: write `billing.Plan.Free`, naming its type
    |}]

let%expect_test "exhaustiveness on another module's type" =
  run_files
    [
      ( "main.ren",
        {|
import billing
fn price(p: billing.Plan) -> Int =
  match p
    Free => 0
fn main() = price(Free)
|}
      );
      billing;
    ];
  [%expect
    {|
    error: this `match` doesn't handle every `billing.Plan`
      ┌─ main.ren:3:3
    3 │   match p
      │   ^^^^^
      = missing: Pro(_)
      help: add an arm for `Pro(_)`, or a `_ =>` arm for the rest
    |}]

let%expect_test "a type written with its alias doesn't use its name" =
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row}
fn id(r: rows.Row) -> Int = r.id
fn main() = id(rows.load(2))
|}
      );
      rows;
    ];
  [%expect
    {|
    error: `Row` is imported but never used
      ┌─ main.ren:1:14
    1 │ import rows.{Row}
      │              ^^^
      help: remove it
    |}]

(* `Red`, `Free`, `{ id: ... }` and `.id` can each be found through a type
   imported by name, in step 2 of a lookup through a type: then the import
   is used, though its name is never written *)
let%expect_test "a type imported by name is used through what it has" =
  run_files
    [
      ("main.ren", {|
import colors.{Color}
fn main() = print(Red)
|});
      ("colors.ren", {|
pub type Color = Red | Green
|});
    ];
  [%expect {|
    Red
    ()
    |}];
  run_files
    [
      ( "main.ren",
        {|
import billing.{Plan}
fn main() =
  let p = Free
  match p
    Free => 0
    Pro(seats) => seats
|}
      );
      billing;
    ];
  [%expect {| 0 |}];
  run_files
    [
      ( "main.ren",
        {|
import rows.{Row}
fn id(r) = r.id
fn main() = id(rows.load(2)) + { id: 3 }.id
|}
      );
      rows;
    ];
  [%expect {| 5 |}];
  (* found through a type that was already known, it isn't *)
  run_files
    [
      ( "main.ren",
        {|
import billing.{Plan}
type Tier = Free | Paid
fn tier(t: Tier) -> Int = 1
fn main() = tier(Free) + billing.price()
|}
      );
      ( "billing.ren",
        {|
pub type Plan = Free | Pro(seats: Int)
pub fn price() -> Int = 2
|}
      );
    ];
  [%expect
    {|
    error: `Plan` is imported but never used
      ┌─ main.ren:1:17
    1 │ import billing.{Plan}
      │                 ^^^^
      help: remove it
    |}]

(* a type of a module that isn't imported can't be written, so the help
   says to import it first *)
let%expect_test "found through a type whose module isn't imported" =
  let main src = ("main.ren", src) :: List.tl orders in
  run_files
    (main
       {|
import orders
fn main() =
  let p = if true then Free else orders.latest().plan
  1
|});
  [%expect
    {|
    error: no type in scope here has a constructor named `Free`
      ┌─ main.ren:3:24
    3 │   let p = if true then Free else orders.latest().plan
      │                        ^^^^
      help: import `billing/invoice`, then write `invoice.Plan.Free`, naming its type
    |}];
  run_files
    (main
       {|
import orders
fn seats(i) = i.plan
fn main() = 1 + orders.latest().total
|});
  [%expect
    {|
    error: no record type in scope here has a field named `plan`
      ┌─ main.ren:2:17
    2 │ fn seats(i) = i.plan
      │                 ^^^^
      = `plan` is a field of `billing/invoice.Invoice`
      = a field is found through its record's type, which has to be known where the field is used
      help: import `billing/invoice`, then annotate `i` where it's defined, like `i: invoice.Invoice`
    |}];
  (* imported, it can be written with its alias *)
  run_files
    (main
       {|
import billing/invoice
fn seats(i) = i.plan
fn main() = invoice.make(1).total
|});
  [%expect
    {|
    error: no record type in scope here has a field named `plan`
      ┌─ main.ren:2:17
    2 │ fn seats(i) = i.plan
      │                 ^^^^
      = `plan` is a field of `invoice.Invoice`
      = a field is found through its record's type, which has to be known where the field is used
      help: annotate `i` where it's defined, like `i: invoice.Invoice`
    |}]

let%expect_test "a constructor the expected type doesn't have" =
  run_files
    [
      ( "main.ren",
        {|
import billing
type Plan = Gold | Silver
fn main() =
  let x: billing.Plan = Gold
  let y: Plan = Silver
  1
|}
      );
      billing;
    ];
  [%expect
    {|
    error: `billing.Plan` has no constructor named `Gold`
      ┌─ main.ren:4:25
    4 │   let x: billing.Plan = Gold
      │                         ^^^^
      = a `billing.Plan` is expected here
      help: its constructors: `Free`, `Pro`
    |}]

let%expect_test "editing a body leaves the interface as it was" =
  (* the interface comes from declarations (module-build.md, "Interface
     summaries"), so changing what a function's body does, even what it
     uses, can't change what dependents see *)
  let iface src =
    let src = clean src in
    let i = Ren.Driver.interface ~file src in
    List.iter
      (fun (v : Ren.Iface.value) ->
        let pr = Ren.Ty.printer ~names:Ren.Path.full v.scheme in
        Printf.printf "%s: %s\n" v.vname (Ren.Ty.show pr v.scheme.ty))
      i.values;
    i
  in
  let before =
    iface
      {|
pub type Row = { id: Int }
pub fn load(id: Int) -> Row
    uses Console =
  let n = helper(id)
  Row { id: n }
fn helper(n) = n
fn main() = load(1)
|}
  in
  let after =
    iface
      {|
pub type Row = { id: Int }
pub fn load(id: Int) -> Row
    uses Console =
  print(id)
  Row { id: helper(id) }
fn helper(n) = n * 2 + 1
fn main() = load(1)
|}
  in
  print_endline (if before = after then "the same" else "different");
  [%expect
    {|
    load: fn(Int) -> test.Row uses Console
    load: fn(Int) -> test.Row uses Console
    the same
    |}]

let%expect_test "editing a body changes the interface only by what it needs" =
  (* the one thing the interface takes from a body is what a public
     function needs of its type parameters, which isn't written
     (module-build.md, "Interface summaries"): an edit that keeps it keeps
     the interface, and one that changes it is seen by dependents *)
  let iface src =
    let i = Ren.Driver.interface ~file (src ^ "\nfn main() = 1\n") in
    List.iter
      (fun (v : Ren.Iface.value) ->
        print_endline
          (Ren.Ty.signature ~names:Ren.Path.full ~pub:true ~name:v.vname
             ~params:[ "a"; "b" ] v.scheme))
      i.values;
    i
  in
  let compares = iface "pub fn same<T>(a: T, b: T) -> Bool = a == b" in
  let swapped = iface "pub fn same<T>(a: T, b: T) -> Bool = b == a" in
  let not_any = iface "pub fn same<T>(a: T, b: T) -> Bool = true" in
  print_endline (if compares = swapped then "the same" else "different");
  print_endline (if compares = not_any then "the same" else "different");
  [%expect
    {|
    pub fn same<T has eq>(a: T, b: T) -> Bool
    pub fn same<T has eq>(a: T, b: T) -> Bool
    pub fn same<T>(a: T, b: T) -> Bool
    the same
    different
    |}]

let%expect_test "lambda sets don't change an interface" =
  (* which lambdas flow where is inference's, found from bodies, so an
     interface leaves it out (Ty.forget_lams): `pick` returns one of what
     it's given, and `first` one of its own, but each states a function
     type with a set of its own, as written, and editing which lambda a
     body makes or passes keeps the interface the same *)
  let iface src = Ren.Driver.interface ~file (src ^ "\nfn main() = 1\n") in
  let picks =
    iface
      {|
pub fn pick(c: Bool, f: fn() -> Int ! ..e, g: fn() -> Int ! ..e) -> fn() -> Int ! ..e =
  if c then f else g
pub fn first() -> fn(Int) -> Int = fn(x) => x
|}
  in
  let edited =
    iface
      {|
pub fn pick(c: Bool, f: fn() -> Int ! ..e, g: fn() -> Int ! ..e) -> fn() -> Int ! ..e =
  if c then g else if c then fn() => 1 else f
pub fn first() -> fn(Int) -> Int = if true then fn(x) => x + 1 else fn(x) => x
|}
  in
  List.iter
    (fun (v : Ren.Iface.value) ->
      print_endline
        (Ren.Core.render 0
           (Atom
              (Ren.Ty.show
                 (Ren.Ty.printer ~show_lams:true ~names:Ren.Path.full v.scheme)
                 v.scheme.ty))))
    picks.values;
  print_endline (if picks = edited then "the same" else "different");
  [%expect
    {|
    fn(Bool, fn() -> Int [..l0], fn() -> Int [..l1]) -> (fn() -> Int [..l2]) [..l3]
    fn() -> (fn(Int) -> Int [..l0]) [..l1]
    the same
    |}]

let%expect_test
    "another module's function, given lambdas, is linted by its interface" =
  (* `main` uses `pick` at its interface's type, whose sets are each its
     own, and Core Lint checks the use against that, not `pick`'s own
     scheme, whose three sets are one *)
  core_files ~lams:true
    [
      ( "main.ren",
        {|
import util
fn one() -> Int = 1
fn main() =
  let f = util.pick(true, one, fn() => 2)
  f()
|}
      );
      ( "util.ren",
        {|
pub fn pick(c: Bool, f: fn() -> Int ! ..e, g: fn() -> Int ! ..e) -> fn() -> Int ! ..e =
  if c then f else g
|}
      );
    ];
  [%expect
    {|
    -- util
    (fn pick :
      fn(Bool, fn() -> Int ! ..e [..l0], fn() -> Int ! ..e [..l0]) -> (fn() -> Int ! ..e [..l0]) ! ..e2 uses ..d [..l1]
      (c/1 f/2 g/3)
      ev/4
      (:
        (if c/1 (: f/2 fn() -> Int ! ..e [..l0]) (: g/3 fn() -> Int ! ..e [..l0]))
        fn() -> Int ! ..e [..l0]))

    -- main
    (fn one : fn() -> Int ! ..e uses ..d [..l0] () ev/1 1)
    (fn main : fn() -> Int ! ..e uses ..d [..l0] () ev/1
      (let f/2
        (:
          (call ev/1
            (inst pick {} {} {..d} [main.one | ..l1] [main.main#1 | ..l2] [..l3]
              [util.pick | ..l4])
            true
            (inst one {} {} [main.one | ..l1])
            (lambda main.main#1 : fn() -> Int [main.main#1 | ..l2] () (captures)
              ev/3
              2))
          fn() -> Int [..l3])
        (call ev/1 (: f/2 fn() -> Int [..l3]))))
    (fn $start : fn() -> Int ! ..e [..l0] () ev/1
      (call ev/1 (inst main {..e} {..r} [main.main | ..l0])))
    |}]

let%expect_test "another module's generic function compares what it's given" =
  (* `same` needs `eq` of `T`, which its interface says, so `main` passes
     it `Int`'s dictionary; with a function it's refused at `main`'s call
     (test_infer.ml, "another module's function needs what it needs") *)
  run_files
    [
      ( "main.ren",
        {|
import util
fn main() = util.same(1, 1) && util.same(1, 2) == false && util.same([1], [1])
|}
      );
      ("util.ren", {|
pub fn same<T>(a: T, b: T) -> Bool = a == b
|});
    ];
  [%expect {| true |}]

let%expect_test "what the implementation tier records" =
  (* only public functions and members, and of those only the ones the
     specializer will copy into callers: a generic one, `same`, or a
     member of a generic type, `Box.get` and `Box.size`, or one given a
     function, `twice` (module-build.md, "Interface summaries"). Not
     `add`, nor the private `pick` *)
  let src =
    {|
pub fn same<T>(a: T, b: T) -> Bool = a == b
pub fn twice(f: fn(Int) -> Int, x: Int) -> Int = try f(try f(x))
pub fn add(a: Int, b: Int) -> Int = a + b
fn pick<T>(a: T, b: T) -> T = a
pub type Box<T> = { v: T }
  pub fn get(self) -> T = self.v
  pub fn size(self) -> Int = 1
fn main() = add(1, 2)
|}
  in
  let impl src = Ren.Driver.implementation ~file (clean src) in
  print_endline (Ren.Impl.show (impl src));
  (* it has no source locations, so moving the code doesn't change it *)
  print_endline
    (if impl src = impl ("\n\n" ^ src) then "the same" else "different");
  [%expect
    {|
    (fn Box.get : fn(test.Box<T>) -> T ! ..e uses ..d (self/1) ev/2 (. self/1 v))
    (fn Box.size : fn(test.Box<T>) -> Int ! ..e uses ..d (self/1) ev/2 1)
    (fn same : fn(T, T) -> Bool ! ..e uses ..d (needs (eq T)) (a/1 b/2) ev/3
      (== (eq T) a/1 b/2))
    (fn twice : fn((fn(Int) -> Int ! ..e uses ..d), Int) -> Int ! ..e uses ..d
      (f/1 x/2)
      ev/3
      (call ev/3 f/1 (call ev/3 f/1 x/2)))
    the same
    |}]

(* ---- opaque types ---- *)

let users =
  ( "users.ren",
    {|
pub type UserId = opaque Int
pub fn make(n: Int) -> UserId = n
pub fn next(id: UserId) -> UserId = id + 1
pub fn raw(id: UserId) -> Int = id
type Secret = { code: Int }
pub type Token = opaque Secret
pub fn token(n: Int) -> Token = { code: n }
pub fn code(t: Token) -> Int = t.code
type Mode = On | Off
pub type Switch = opaque Mode
pub fn on() -> Switch = On
pub fn is_on(s: Switch) -> Bool =
  match s
    On => true
    Off => false
|}
  )

let%expect_test "inside its module, an opaque type is its representation" =
  (* at run time a `UserId` is just the `Int` *)
  run_files
    [
      ( "main.ren",
        {|
import users
fn main() =
  let id = users.next(users.make(41))
  print(users.raw(id))
  print(users.code(users.token(7)))
  users.is_on(users.on())
|}
      );
      users;
    ];
  [%expect {|
    42
    7
    true
    |}]

let%expect_test "an opaque type's interface hides its representation" =
  let src = clean (snd users) ^ "fn main() = 1\n" in
  let i = Ren.Driver.interface ~file:"users.ren" src in
  List.iter
    (fun (td : Ren.Iface.type_decl) ->
      Printf.printf "%s: %s\n" td.path.name
        (match td.body with
        | Opaque (Hidden { eq = true }) -> "opaque"
        | Opaque (Hidden { eq = false }) -> "opaque, without `==`"
        | Opaque (Rep _) -> "opaque, with its representation"
        | Record _ -> "a record"
        | Sum _ -> "a sum type"
        | Builtin -> "built in"
        | Errors _ -> "an error set"
        | Dep _ -> "a dependency"
        | Handler _ -> "a handler"))
    i.types;
  [%expect {|
    UserId: opaque
    Token: opaque
    Switch: opaque
    |}]

let%expect_test "an opaque type's interface says whether it has ==" =
  (* the representation is hidden, but another module comparing two needs
     to know if they'd meet a function *)
  let src =
    clean
      {|
pub type Id = opaque Int
pub type F = opaque fn(Int) -> Int
pub type Box<T> = opaque Array<T>
pub type Held = opaque Box<F>
fn main() = 1
|}
  in
  let i = Ren.Driver.interface ~file:"a.ren" src in
  List.iter
    (fun (td : Ren.Iface.type_decl) ->
      match td.body with
      | Opaque (Hidden { eq }) -> Printf.printf "%s: %b\n" td.path.name eq
      | _ -> ())
    i.types;
  [%expect {|
    Id: true
    F: false
    Box: true
    Held: false
    |}]

let%expect_test "outside its module, an opaque type can't be looked inside" =
  run_files
    [
      ( "main.ren",
        {|
import users
fn main() =
  let n: Int = users.make(1)
  let m = users.make(1) + 1
  let x: users.UserId = 5
  let c = users.token(1).code
  let t = users.Token { code: 1 }
  let s = users.Switch.On
  match users.on()
    On => 1
    _ => 0
|}
      );
      users;
    ];
  [%expect
    {|
    error: expected `Int`, found `users.UserId`
      ┌─ main.ren:3:16
    3 │   let n: Int = users.make(1)
      │                ^^^^^^^^^^^^^
      = `UserId`'s representation is private to `users`
      help: use a function from `users` to make or read one

    error: expected `Int`, found `users.UserId`
      ┌─ main.ren:4:11
    4 │   let m = users.make(1) + 1
      │           ^^^^^^^^^^^^^
      = `+` works on `Int`s
      = `UserId`'s representation is private to `users`
      help: use a function from `users` to make or read one

    error: expected `users.UserId`, found `Int`
      ┌─ main.ren:5:25
    5 │   let x: users.UserId = 5
      │                         ^
      = `UserId`'s representation is private to `users`
      help: use a function from `users` to make or read one

    error: `Token`'s representation is private to `users`
      ┌─ main.ren:6:26
    6 │   let c = users.token(1).code
      │                          ^^^^
      help: use a function from `users` to make or read one

    error: `Token`'s representation is private to `users`
      ┌─ main.ren:7:11
    7 │   let t = users.Token { code: 1 }
      │           ^^^^^^^^^^^
      help: use a function from `users` to make or read one

    error: `Switch`'s representation is private to `users`
      ┌─ main.ren:8:11
    8 │   let s = users.Switch.On
      │           ^^^^^^^^^^^^^^^
      help: use a function from `users` to make or read one

    error: `Switch`'s representation is private to `users`
       ┌─ main.ren:10:5
    10 │     On => 1
       │     ^^
       help: use a function from `users` to make or read one
    |}]

let%expect_test "another module's opaque type, inside a type or behind one" =
  (* the note is there wherever the other module's opaque type is: inside
     an `Array`, or as what one of this module's opaque types is *)
  run_files
    [
      ( "main.ren",
        {|
import users.{UserId}
type Ids = opaque UserId
fn ids(a: Array<UserId>) = a
fn bad() -> Ids = 3
fn main() =
  let xs: Array<Int> = [1]
  let _ = ids(xs)
  bad()
|}
      );
      users;
    ];
  [%expect
    {|
    error: expected `Ids`, found `Int`
      ┌─ main.ren:4:19
    4 │ fn bad() -> Ids = 3
      │                   ^
      = `bad` is declared to return `Ids`
      = `UserId`'s representation is private to `users`
      help: use a function from `users` to make or read one

    error: expected `Array<UserId>`, found `Array<Int>`
      ┌─ main.ren:7:15
    7 │   let _ = ids(xs)
      │               ^^
      = `UserId`'s representation is private to `users`
      help: use a function from `users` to make or read one
    |}]

let%expect_test "an opaque type isn't a record or a sum type, even inside" =
  run
    {|
type Secret = { code: Int }
type Token = opaque Secret
type Mode = On | Off
type Switch = opaque Mode
type Amount = opaque Int
fn main() =
  let t = Token { code: 1 }
  let a = Amount { cents: 1 }
  Switch.On
|};
  [%expect
    {|
    error: `Token` is opaque, so it has no fields of its own
      ┌─ test.ren:7:11
    7 │   let t = Token { code: 1 }
      │           ^^^^^
      help: here a `Token` is a `Secret`, so write one of those instead

    error: `Amount` is opaque, so it has no fields of its own
      ┌─ test.ren:8:11
    8 │   let a = Amount { cents: 1 }
      │           ^^^^^^
      help: here an `Amount` is an `Int`, so write one of those instead

    error: `Switch` is opaque, so it has no constructors of its own
      ┌─ test.ren:9:3
    9 │   Switch.On
      │   ^^^^^^^^^
      help: here a `Switch` is a `Mode`, so write one of those instead
    |}]

let%expect_test "an opaque type can't be represented as itself" =
  run
    {|
type A = opaque B
type B = opaque A
type C = opaque Option<C>
type D = opaque E
type E = opaque F
type F = opaque D
fn main() = 1
|};
  [%expect
    {|
    error: `A` is represented as itself: A → B → A
      ┌─ test.ren:1:6
    1 │ type A = opaque B
      │      ^
      help: represent one of them as a type that isn't opaque

    error: `D` is represented as itself: D → E → F → D
      ┌─ test.ren:4:6
    4 │ type D = opaque E
      │      ^
      help: represent one of them as a type that isn't opaque
    |}]
