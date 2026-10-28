(* A NaN (foundations.md, decision 15; nan.ml): arithmetic and stores
   carry it, and where a program observes it, it panics, saying where it
   was made. build.t runs the same programs built, debug and release, and
   checks they say the same. *)

open Helpers

let%expect_test "arithmetic carries a NaN, and comparing it panics" =
  run_error
    {|
fn main() uses Console =
  let z = 0.0
  let a = z / z
  let b = a * 2.0 + 1.0
  print(1.0 < 2.0)
  print(b < 1.0)
|};
  [%expect {|
    true
    error: panic: `<` compared a NaN made at test.ren:3:11
      ┌─ test.ren:6:9
    6 │   print(b < 1.0)
      │         ^^^^^^^
    |}]

let%expect_test "`==` and `!=` on a NaN panic, through a value too" =
  run_error {|
fn main() uses Console =
  let z = 0.0
  print([1.0, z / z] == [1.0, 2.0])
|};
  run_error {|
fn main() uses Console =
  let z = 0.0
  print(z / z != 1.0)
|};
  [%expect {|
    error: panic: `==` compared a NaN made at test.ren:3:15
      ┌─ test.ren:3:9
    3 │   print([1.0, z / z] == [1.0, 2.0])
      │         ^^^^^^^^^^^^^^^^^^^^^^^^^^
    error: panic: `!=` compared a NaN made at test.ren:3:9
      ┌─ test.ren:3:9
    3 │   print(z / z != 1.0)
      │         ^^^^^^^^^^^^
    |}]

let%expect_test "an order through `sort` panics on one" =
  run_error {|
fn main() uses Console =
  let z = 0.0
  print([2.0, z / z, 1.0].sort().len())
|};
  [%expect {|
    error: panic: `sort` compared a NaN made at test.ren:3:15
      ┌─ test.ren:3:9
    3 │   print([2.0, z / z, 1.0].sort().len())
      │         ^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "`show`, `round`, `truncate` and hashing panic on one" =
  run_error {|
fn main() uses Console =
  let z = 0.0
  let xs = [1.0, (0.0 - 1.0).sqrt()]
  print(xs.len())
  print(xs)
|};
  run_error {|
fn main() uses Console = print((0.0 / 0.0).round())
|};
  run_error {|
fn main() uses Console = print((0.0 / 0.0).truncate())
|};
  run_error {|
fn main() uses Console = print([1.0, 0.0 / 0.0].tally().len())
|};
  [%expect {|
    2
    error: panic: `show` of a NaN made at test.ren:3:18
      ┌─ test.ren:5:3
    5 │   print(xs)
      │   ^^^^^^^^^
    error: panic: `round` of a NaN made at test.ren:1:33
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print((0.0 / 0.0).round())
      │                                ^^^^^^^^^^^^^^^^^^^
    error: panic: `truncate` of a NaN made at test.ren:1:33
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print((0.0 / 0.0).truncate())
      │                                ^^^^^^^^^^^^^^^^^^^^^^
    error: panic: `hash` of a NaN made at test.ren:1:38
      ┌─ test.ren:1:32
    1 │ fn main() uses Console = print([1.0, 0.0 / 0.0].tally().len())
      │                                ^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "a dependency's operation is never given one" =
  run_error
    {|
dep Sink =
  put: fn(x: Float)

handler ignoring() for Sink =
  put(_) => ()

fn main() uses Console =
  let z = 0.0
  with ignoring() in Sink.put(z / z)
  print("not reached")
|};
  [%expect {|
    error: panic: `Sink.put` was given a NaN made at test.ren:9:31
      ┌─ test.ren:9:31
    9 │   with ignoring() in Sink.put(z / z)
      │                               ^^^^^
    |}]

let%expect_test "a NaN keeps where it was made through a Float32 and a sum" =
  run_error
    {|
fn main() uses Console =
  let z = 0.0
  var fs: Array<Float32> = [0.5, 1.0]
  fs[1] = z / z
  let xs = [1.0, 2.0, fs[1], 3.0]
  print(xs.sum() > 0.0)
|};
  [%expect {|
    error: panic: `>` compared a NaN made at test.ren:4:11
      ┌─ test.ren:6:9
    6 │   print(xs.sum() > 0.0)
      │         ^^^^^^^^^^^^^^
    |}]

let%expect_test "the first NaN an operation is given is the one it gives" =
  run_error
    {|
fn main() uses Console =
  let z = 0.0
  let a = z / z
  let b = (0.0 - 1.0).sqrt()
  print(b + a > 0.0)
|};
  [%expect {|
    error: panic: `>` compared a NaN made at test.ren:4:11
      ┌─ test.ren:5:9
    5 │   print(b + a > 0.0)
      │         ^^^^^^^^^^^
    |}]

let%expect_test "`sum` of `Float`s adds in eight lanes, whatever the order" =
  run
    {|
fn main() uses Console =
  print([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0].sum())
  print([1.0, 100000000000000000000.0, 1.0, -100000000000000000000.0].sum())
  let e: Array<Float> = []
  print(e.sum())
  print([1, 2, 3].sum())
|};
  [%expect {|
    5.5
    0.0
    0.0
    6
    ()
    |}]
