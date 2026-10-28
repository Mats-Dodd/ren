(* Sized storage types and the wrapping operators (operators.md, "Sized
   integers"; foundations.md, decision 15): `UInt8` and the rest are the
   types of places, read as `Int` or `Float` and checked when stored
   into; `+%`, `-%` and `*%` wrap, at 64 bits, or at the width of the
   sized type their result is stored into. *)

open Helpers

(* ---- reading and storing ---- *)

let%expect_test "a sized value reads as an Int, and a store checks it fits" =
  run
    {|
type Pixel = { r: UInt8, g: UInt8, b: UInt8, a: UInt8 }

fn main() uses Console =
  var buf: Array<UInt8> = []
  for i in 0..5
    &buf.push(i * 60)
  print(buf)
  let x = buf[4] + 1000
  print(x)
  var p = Pixel { r: 255, g: 0, b: 10, a: 255 }
  p.g += 100
  print(p)
  print(p == Pixel { r: 255, g: 100, b: 10, a: 255 })
  let small: Array<Int8> = [-128, 0, 127]
  print(small.map(fn(v) => v * 2))
  let f: Float32 = 0.1
  print(f)
  let id: UInt64 = 9223372036854775807
  print(id - 1)
|};
  [%expect {|
    [0, 60, 120, 180, 240]
    1240
    Pixel { r: 255, g: 100, b: 10, a: 255 }
    true
    [-256, 0, 254]
    0.10000000149011612
    9223372036854775806
    ()
    |}]

let%expect_test "a generic function keeps a sized array's elements as they are" =
  run
    {|
type Box<T> = { item: T }

fn twice<T>(xs: Array<T>) -> Array<T> =
  var out: Array<T> = []
  for x in xs
    &out.push(x)
    &out.push(x)
  out

fn first<T>(xs: Array<T>) -> Box<T> = Box { item: xs[0] }

fn main() uses Console =
  let xs: Array<Int16> = [-300, 7]
  print(twice(xs))
  print(first(xs))
  print(twice(xs) == [-300, -300, 7, 7])
|};
  [%expect {|
    [-300, -300, 7, 7]
    Box { item: -300 }
    true
    ()
    |}]

(* ---- wrapping ---- *)

let%expect_test "`+%`, `-%` and `*%` wrap Ints at 64 bits" =
  run
    {|
fn main() uses Console =
  let big = 9223372036854775807
  print(big +% 1)
  print(-big -% 2)
  print(big *% 3)
  print(1 +% 2 *% 3)
  var h = 1469598103934665603
  h *%= 1099511628211
  print(h)
|};
  [%expect {|
    -9223372036854775808
    9223372036854775807
    9223372036854775805
    7
    4953163356653287321
    ()
    |}]

let%expect_test "a wrapping operator's result stored into a sized type wraps at its width" =
  run
    {|
fn fnv(bytes: Array<UInt8>) -> Int =
  var h: UInt32 = 2166136261
  for b in bytes
    h = h.xor(b)
    h = h *% 16777619
  h

fn main() uses Console =
  print(fnv([104, 105]))
  var w: Int32 = -5
  w = w *% 1000000000
  print(w)
  var acc: UInt8 = 250
  acc +%= 10
  print(acc)
  let n: Int8 = 100.wrapping_add(100)
  print(n)
|};
  [%expect {|
    1748694682
    -705032704
    4
    -56
    ()
    |}]

(* ---- panics ---- *)

let%expect_test "a store that doesn't fit panics" =
  run_error
    {|
fn main() uses Console =
  var xs: Array<UInt8> = [1, 2, 3]
  xs[2] = xs[2] * 100
  print(xs)
|};
  [%expect {|
    error: panic: 300 doesn't fit in a `UInt8`, which holds 0 to 255
      ┌─ test.ren:3:11
    3 │   xs[2] = xs[2] * 100
      │           ^^^^^^^^^^^
    |}]

let%expect_test "a UInt64 holds no negative number" =
  run_error
    {|
fn main() uses Console =
  var u: Array<UInt64> = [5]
  u[0] = u[0] - 6
|};
  [%expect {|
    error: panic: -1 doesn't fit in a `UInt64`, which holds 0 to 9223372036854775807
      ┌─ test.ren:3:10
    3 │   u[0] = u[0] - 6
      │          ^^^^^^^^
    |}]

let%expect_test "a Float too big for a Float32 panics" =
  run_error
    {|
type R = { f: Float32 }

fn main() uses Console =
  var x = 1.0
  for i in 0..40
    x = x * 10.0
  print(R { f: x })
|};
  [%expect {|
    error: panic: 9999999999999998000000000000000000000000.0 doesn't fit in a `Float32`, which holds up to about 3.4e38
      ┌─ test.ren:7:16
    7 │   print(R { f: x })
      │                ^
    |}]

(* ---- errors ---- *)

let%expect_test "a literal that doesn't fit is an error" =
  check_error {|
fn main() =
  let x: UInt8 = 256
  x
|};
  [%expect {|
    error: `256` doesn't fit in a `UInt8`, which holds 0 to 255
      ┌─ test.ren:2:18
    2 │   let x: UInt8 = 256
      │                  ^^^
      = a sized type keeps a number in fewer bits than an `Int`
      help: give the place a type that holds it, or an `Int`
    |}]

let%expect_test "a wrapping result can't be stored into a UInt64" =
  check_error
    {|
fn main() =
  var h: UInt64 = 1
  h = h *% 3
|};
  [%expect {|
    error: a wrapping operator's result can't be stored in a `UInt64`
      ┌─ test.ren:3:7
    3 │   h = h *% 3
      │       ^^^^^^
      = `*%` wraps at `Int`'s 64 bits, and half of what it makes is negative
      = a `UInt64` holds what an `Int` can that isn't negative
      help: keep a 64-bit hash or checksum in an `Int`
    |}]

let%expect_test "only Int has the wrapping operators" =
  check_error {|
fn main() =
  let x = 1.5 +% 2.0
  x
|};
  [%expect {|
    error: `Float` has no `+%`
      ┌─ test.ren:2:11
    2 │   let x = 1.5 +% 2.0
      │           ^^^^^^^^^^
      = the wrapping operators, `+%`, `-%` and `*%`, are `Int`'s
      help: a `Float` doesn't wrap: use `+`
    |}]

let%expect_test "an `&` place's type has to be the parameter's exactly" =
  check_error
    {|
fn bump(inout n: Int) = n += 1

fn main() =
  var b: UInt8 = 1
  bump(&b)
|};
  [%expect {|
    error: expected `Int`, found `UInt8`
      ┌─ test.ren:5:9
    5 │   bump(&b)
      │         ^
      = an `inout` argument is changed where it's kept, so its type has to be the parameter's exactly
      help: copy it into a `var` of the parameter's type, pass that, and store it back
    |}]

(* ---- the native slice ---- *)

let%expect_test "an array of UInt8s is read a byte at a time, and widened" =
  Test_native.mem_lines ~release:true "ren_test_fnv_1"
    [ "elem"; "wide"; "narrow"; "wrap" ]
    {|
fn fnv(bytes: Array<UInt8>) -> Int =
  var h: UInt32 = 2166136261
  for b in bytes
    h = h.xor(b)
    h = h *% 16777619
  h

fn main() -> Int = fnv([1, 2])
|};
  [%expect {|
    (do (let $narrow/3:UInt32 (narrow:UInt32 2166136261))
    (let h/4:UInt32 $narrow/3)
    (let $elem/16:UInt8 (buf-get:UInt8 $buf/35 $len/33 $i/15))
    (let b/17:UInt8 $elem/16)
    (let $wide/19:Int (widen h/18))
    (let $wide/21:Int (widen b/20))
    (let $xor/22:Int (xor $wide/19 $wide/21))
    (let $narrow/23:UInt32 (narrow:UInt32 $xor/22))
    (set h/4 $narrow/23)
    (let $wide/25:Int (widen h/24))
    (let $wrapping_mul/26:Int (wrapping* $wide/25 16777619))
    (let $wrap/27:UInt32 (wrap:UInt32 $wrapping_mul/26))
    (set h/4 $wrap/27)
    (let $wide/31:Int (widen h/30))
    (return $wide/31)))
    Mem Lint: ok
    |}]

let%expect_test "a release build's small record packs its sized fields into a word" =
  Test_native.mem_lines ~release:true "ren_test_main_1" [ "pack" ]
    {|
type Pixel = { r: UInt8, g: UInt8, b: UInt8, a: UInt8 }

fn main() -> Int =
  var ps: Array<Pixel> = [Pixel { r: 1, g: 2, b: 3, a: 4 }]
  ps[0] = Pixel { r: 5, g: ps[0].g, b: 6, a: 7 }
  ps[0].g + ps[0].a
|};
  [%expect {|
    (let $packed/6:Int
    (pack $narrow/2@0:8 $narrow/3@8:8 $narrow/4@16:8 $narrow/5@24:8))
    (let $struct/7:Struct0 (struct $packed/6))
    (let $packed/13:Int (. $elem/12 0))
    (let g/14:UInt8 (unpack $packed/13@8:8))
    (let $packed/17:Int
    (pack $narrow/10@0:8 g/14@8:8 $narrow/15@16:8 $narrow/16@24:8))
    (let $struct/18:Struct0 (struct $packed/17))
    (let $packed/25:Int (. $elem/24 0))
    (let g/26:UInt8 (unpack $packed/25@8:8))
    (let $packed/30:Int (. $elem/29 0))
    (let a/31:UInt8 (unpack $packed/30@24:8))
    Mem Lint: ok
    |}]
