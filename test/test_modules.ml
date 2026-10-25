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
  run_files
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
pub fn ids(rows: Array<Row>) -> Int = len(rows)
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
    3 │ pub fn ids(rows: Array<Row>) -> Int = len(rows)
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
