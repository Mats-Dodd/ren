(* A producer classified as a block never declares a nominal Cursor type. *)

open Helpers

let diagnostics f =
  let out, raised = captured f in
  List.iter (fun line ->
      if String.starts_with ~prefix:"error:" line then print_endline line)
    (String.split_on_char '\n' out);
  Option.iter raise raised

let%expect_test "block cursor annotations cannot enter a public signature" =
  diagnostics (fun () -> check_error {|
pub gen fn values() -> Int uses Console =
  print("work")
  yield 1
pub fn consume(c: values.Cursor) = ()
fn main() = ()
|});
  [%expect {| error: `values` is a block generator and has no cursor type |}]

let%expect_test "importing a module also checks its block cursor annotations" =
  diagnostics (fun () -> check_error_files
    [ "main.ren", {|
import producer
fn main() = producer.visible()
|}; "producer.ren", {|
pub gen fn values() -> Int uses Console =
  print("work")
  yield 1
pub fn consume(c: values.Cursor) = ()
pub fn visible() = ()
|} ]);
  [%expect {| error: `values` is a block generator and has no cursor type |}]

let%expect_test "nested callback annotations cannot name a block cursor" =
  diagnostics (fun () -> check_error {|
gen fn values() -> Int uses Console =
  print("work")
  yield 1
fn main() =
  let consume = fn(c: Array<values.Cursor>) => ()
  ()
|});
  [%expect {| error: `values` is a block generator and has no cursor type |}]

let%expect_test "a pure generator cursor annotation works before its declaration" =
  run {|
fn step(inout c: values.Cursor) -> Option<Int> = &c.next()
gen fn values() -> Int = yield 7
fn main() uses Console =
  var c = values()
  print(step(&c))
|};
  [%expect {|Some(7)
()
|}]
