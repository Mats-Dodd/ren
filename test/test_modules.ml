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
