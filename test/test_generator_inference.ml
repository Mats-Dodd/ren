open Helpers

let headlines f =
  let output, raised = captured f in
  String.split_on_char '\n' output
  |> List.iter (fun line ->
      let line = String.trim line in
      if String.starts_with ~prefix:"error:" line then print_endline line);
  Option.iter raise raised

let%expect_test "a recursive ordinary factory resolves a generator next receiver" =
  run {|
gen fn values(n: Int) -> Int =
  if n > 0 then
    var child = again(n - 1)
    match &child.next()
      Some(x) => yield x
      None => ()
  else
    yield 0
fn again(n: Int) = values(n)
fn main() =
  var items = []
  for x in values(2)
    &items.push(x)
  items
|};
  [%expect {| [0] |}]

let%expect_test "a delayed next receiver retains its producer failure row" =
  headlines (fun () -> check_error {|
gen fn values(n: Int) -> Int ! Bad =
  if n > 0 then
    var child = again(n - 1)
    match &child.next()
      Some(x) => yield x
      None => ()
  else
    fail Bad
fn again(n: Int) = values(n)
fn main() = ()
|});
  [%expect {| error: `next` can fail, and nothing handles it |}]

let%expect_test "ordinary next ambiguity is preserved inside a generator SCC" =
  headlines (fun () -> check_error {|
gen fn values(n: Int) -> Int =
  if n > 0 then
    var child = again(n - 1)
    let x = &child.next()
    yield x + 1
  else
    yield 0
fn again(n: Int) =
  for x in values(0)
    ()
  "x".chars()
fn main() = ()
|});
  [%expect {| error: can't tell which type `child` is |}]
