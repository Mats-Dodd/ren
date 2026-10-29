(* The bytes stage's specification in the interpreter (compiler.md, "Bytes
   stage", "The tests"): what bench/bytes.t's programs don't say, the
   whole of a panic's message with its help, the errors that refuse
   layer 3 used wrongly, and `x.hash()`'s values.

     b2  layer 3: reads and writes at an offset, the cursor, `VarUInt`
     b3  `Map` and `Set` natively, and `x.hash()`

   A test still to land runs through [until] (helpers.ml), as
   test_tasks.ml's do: [want] is the whole output of a program that runs,
   [says] the lines an error or a panic has to hold. Its [%expect] holds
   today's output after `(until bN)`. When the program prints what's
   wanted, the test fails until the step turns it on: written plainly,
   with the target in its [%expect]. *)

open Helpers

(* ---- b1: string and byte speed ----

   What step 1 proves, and Core Lint proves again (bounds.ml): reads of a
   `Bytes` in bounds where a loop's count, or a test that held, keeps them
   so, and a loop's step that can't overflow. bench/bytes.t's `proofs`
   programs run them, and those it leaves checked, in every build. *)

let%expect_test "[b1] a byte read at a count, or below a test that held, is proved; the step too" =
  core
    {|
fn count(b: Bytes) -> Int =
  var t = 0
  for i in 0..b.len()
    t += b.at(i)
  t

fn digits(b: Bytes, from: Int) -> Int =
  let n = b.len()
  var j = from
  var k = 0
  while k < n && b.at(k) >= 48
    k += 1
  while j < n && b.at(j) >= 48
    j += 1
  j + k

fn main() = ()
|};
  [%expect {|
    (fn count (b/1) ev/2
      (let t/3 0
        (seq
          (let $i/4 0
            (let $stop/5 (call ev/2 Bytes.len b/1)
              (while (< $i/4 $stop/5)
                (let i/6 $i/4
                  (seq (let $v/7 (byte-at-in b/1 i/6) (= t/3 (+ t/3 $v/7)))
                    (= $i/4 (step $i/4)))))))
          t/3)))
    (fn digits (b/1 from/2) ev/3
      (let n/4 (call ev/3 Bytes.len b/1)
        (let j/5 from/2
          (let k/6 0
            (seq
              (while (if (< k/6 n/4) (>= (byte-at-in b/1 k/6) 48) false)
                (= k/6 (step k/6)))
              (seq
                (while (if (< j/5 n/4) (>= (call ev/3 Bytes.at b/1 j/5) 48) false)
                  (= j/5 (step j/5)))
                (+ j/5 k/6)))))))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

(* A step or a read marked by hand where nothing proves it, as a pass
   that moved one out of its loop would leave it, is a bug Core Lint
   catches. *)
let%expect_test "[b1] Core Lint rejects a step, or a byte read, marked where it isn't proved" =
  let open Ren.Core in
  let check src (mark : expr -> expr) =
    let src = clean src in
    let rec go (e : expr) =
      let e = mark e in
      { e with kind = Ren.Bounds.map go e }
    in
    report src (fun () ->
        let linked = Ren.Driver.linked ~file src in
        let entry = List.nth linked (List.length linked - 1) in
        let entry =
          { entry with fns = List.map (fun (f : fn_def) -> { f with body = go f.body }) entry.fns }
        in
        Ren.Driver.pass "lint" (fun () -> Ren.Core_lint.program ~imports:[] ~linked entry);
        print_endline "ok")
  in
  (* `i <= n` holds at the largest `Int` too, so `i + 1` may overflow *)
  check
    {|
fn upto(n: Int) -> Int =
  var i = 0
  while i <= n
    i += 1
  i
fn main() = ()
|}
    (fun e ->
      match e.kind with
      | Assign (i, ({ kind = Prim (Binop Add, [ { kind = Local _; _ } as l; _ ]); _ } as v)) ->
          { e with kind = Assign (i, { v with kind = Prim (Step, [ l ]) }) }
      | _ -> e);
  check
    {|
fn first(b: Bytes, i: Int) -> Int = b.at(i)
fn main() = ()
|}
    (fun e ->
      match e.kind with
      | Call ({ kind = Intrinsic (Bytes_at, _, _, _); _ }, [ Value b; Value i ], _) ->
          { e with kind = Prim (Byte_at In_bounds, [ b; i ]) }
      | _ -> e);
  [%expect {|
    internal compiler error in lint: Failure("Core Lint: in `upto`, at test.ren:4:5: an index marked in bounds, or a step marked as not overflowing, that its loop doesn't keep so")
      = this is a bug in the Ren compiler, not in your program
    internal compiler error in lint: Failure("Core Lint: in `first`, at test.ren:1:37: an index marked in bounds, or a step marked as not overflowing, that its loop doesn't keep so")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* ---- b2: layer 3 ---- *)

let%expect_test "[b2] a read past the end panics with the offset, the width and the length" =
  run_error
    {|
fn main() uses Console =
  let b = Bytes.of([1, 2, 3, 4, 5, 6, 7, 8])
  print(b.u32_le(5))
|};
  [%expect {|
    error: panic: 4 bytes at 5 are out of bounds for bytes of length 8
      ┌─ test.ren:3:9
    3 │   print(b.u32_le(5))
      │         ^^^^^^^^^^^
    |}]

let%expect_test "[b2] a one-byte read past the end panics as `at` does" =
  run_error
    {|
fn main() uses Console =
  let b = Bytes.of([1, 2, 3, 4, 5, 6, 7, 8])
  print(b.u8(8))
|};
  [%expect {|
    error: panic: index 8 is out of bounds for bytes of length 8
      ┌─ test.ren:3:9
    3 │   print(b.u8(8))
      │         ^^^^^^^
    |}]

let%expect_test "[b2] `u64_le` of 2^63 or more panics, and says to read its bits with `i64_le`" =
  run_error
    {|
fn main() uses Console =
  let b = Bytes.of([255, 255, 255, 255, 255, 255, 255, 255])
  print(b.u64_le(0))
|};
  [%expect {|
    error: panic: `u64_le` at 0 read 18446744073709551615, which is more than an `Int` holds
      ┌─ test.ren:3:9
    3 │   print(b.u64_le(0))
      │         ^^^^^^^^^^^
      help: read its bits as an `Int` with `i64_le`
    |}]

let%expect_test "[b2] a write that doesn't fit panics as a store into a sized integer does" =
  run_error
    {|
fn main() uses Console =
  var b = Bytes.zeros(4)
  &b.set_u32_be(0, -1)
  print(b)
|};
  [%expect {|
    error: panic: -1 doesn't fit in a `UInt32`, which holds 0 to 4294967295
      ┌─ test.ren:3:4
    3 │   &b.set_u32_be(0, -1)
      │    ^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[b2] a write changes a `var`, through `&`" =
  check_error
    {|
fn main() uses Console =
  var b = Bytes.zeros(4)
  b.set_u8(0, 1)
  print(b)
|};
  [%expect {|
    error: `set_u8` changes `b`, so the call needs `&`
      ┌─ test.ren:3:3
    3 │   b.set_u8(0, 1)
      │   ^^^^^^^^^^^^^^
      = `&` shows at the call that `b` is changed
      help: write `&b.set_u8(0, 1)`
    |}]

let%expect_test "[b2] the cursor's reads fail with `FormatError`, which a caller has to handle" =
  run
    {|
fn two(inout c: ByteCursor) -> Int ! FormatError = try &c.u16_le()
fn main() uses Console =
  var c = Bytes.of([1, 2, 3]).cursor()
  print(attempt two(&c))
  print(attempt two(&c))
  print(c.at())
|};
  [%expect {|
    Ok(513)
    Err(Short(2, 1))
    2
    ()
    |}]

(* ---- b3: `x.hash()` ---- *)

let%expect_test "[b3] `x.hash()` is the derived hash, unseeded, agreeing with `==`" =
  run
    {|
type P = { x: Int, y: Int }
pub type Name = opaque Str
  pub fn of(s: Str) -> Name = s
  pub fn key(self) -> Str = self.lower()
fn main() uses Console =
  print(P { x: 1, y: 2 }.hash() == P { x: 1, y: 2 }.hash())
  print(Name.of("Ann").hash() == Name.of("ANN").hash())
  print((1, 2).hash() == (2, 1).hash())
  print(Map.of([(1, 2), (3, 4)]).hash() == Map.of([(3, 4), (1, 2)]).hash())
|};
  [%expect {|
    true
    true
    false
    true
    ()
    |}]
