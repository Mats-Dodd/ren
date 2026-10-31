open Ren
open Helpers

let contains text part =
  let rec at i = i + String.length part <= String.length text &&
    (String.sub text i (String.length part) = part || at (i + 1)) in
  at 0

let rejects source parts =
  let source = clean source in
  let output, raised = captured (fun () ->
      report source (fun () -> ignore (Driver.check ~file source))) in
  Option.iter raise raised;
  List.iter (fun part -> if not (contains output part) then
      failwith ("missing diagnostic " ^ part ^ ":\n" ^ output)) parts

let%expect_test "a pulled block generator contributes its producer's world reach" =
  rejects {|gen fn watch() -> Int uses Console =
  print("world")
  yield 7
fn consume() -> Int uses Console =
  let cursor = watch()
  cursor().unwrap_or(0)
assert consume.uses <= []
fn main() = ()
|} ["assert failed while building"; "Console"; "consume → watch"];
  [%expect {||}]

let%expect_test "an unpulled frame keeps its body and captured callback latent" =
  run {|gen fn watch() -> Int uses Console =
  print("world")
  yield 7
gen fn apply(body: fn() -> Int uses Console) -> Int uses Console =
  yield try body()
fn discard() -> Int uses Console =
  let cursor = watch()
  let callback = apply(fn() =>
    print("callback")
    3)
  9
assert discard.uses <= []
let DATA = discard()
assert DATA == 9
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "a producer's written upper bound does not become an actual edge" =
  run {|gen fn quiet() -> Int uses Console = yield 7
fn consume() -> Int uses Console =
  let cursor = quiet()
  cursor().unwrap_or(0)
assert consume.uses <= []
let DATA = consume()
assert DATA == 7
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "a block alias retains its captured cursor's producer" =
  rejects {|gen fn watch() -> Int uses Console =
  print("world")
  yield 7
fn consume() -> Int uses Console =
  let cursor = watch()
  let alias = fn() => cursor()
  alias().unwrap_or(0)
assert consume.uses <= []
fn main() = ()
|} ["assert failed while building"; "Console"; "consume → watch"];
  [%expect {||}]

let%expect_test "cursor and callback provenance survives actual helper parameters" =
  rejects {|gen fn watch() -> Int uses Console =
  print("world")
  yield 7
fn pull(cursor: fn() -> Option<Int>) -> Int =
  let item = try cursor()
  item.unwrap_or(0)
fn consume() -> Int uses Console = pull(watch())
assert consume.uses <= []
fn main() = ()
|} ["assert failed while building"; "Console"; "consume → pull → watch"];
  rejects {|gen fn apply(body: fn() -> Int uses Console) -> Int uses Console =
  yield try body()
fn value() -> Int uses Console =
  print("world")
  7
fn consume() -> Int uses Console =
  let cursor = apply(value)
  let item = cursor()
  item.unwrap_or(0)
assert consume.uses <= []
fn main() = ()
|} ["assert failed while building"; "Console"; "consume → apply → value"];
  [%expect {||}]

let%expect_test "a pull-site handler does not replace a block frame's captured evidence" =
  rejects {|gen fn times() -> Time uses Clock = yield Clock.now()
fn consume() -> Time uses Clock =
  let cursor = times()
  with Clock.frozen(Time.epoch) in cursor().unwrap_or(Time.epoch)
assert consume.uses <= []
fn main() = ()
|} ["assert failed while building"; "Clock"; "consume → times"];
  run {|gen fn times() -> Time uses Clock = yield Clock.now()
fn local() -> Time =
  with Clock.frozen(Time.epoch) in
    let cursor = times()
    cursor().unwrap_or(Time.epoch)
assert local.uses <= []
let DATA = local()
assert DATA == Time.epoch
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "nominal cursor steps follow pure producers through forwarding and storage" =
  run {|pub gen fn values() -> Int = yield 7
type Box = { cursor: values.Cursor }
fn make() -> values.Cursor = values()
fn consume() -> Int =
  let box = Box { cursor: make() }
  var cursor = box.cursor
  let item = &cursor.next()
  item.unwrap_or(0)
assert consume.uses <= []
let DATA = consume()
assert DATA == 7
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "producer activation retains concrete generic dependency arguments" =
  run {|dep Store<T> =
  get: fn() -> T
gen fn read<T>() -> T uses Store<T> = yield Store.get()
fn consume() -> Int uses Store<Int> =
  let cursor = read<Int>()
  cursor().unwrap_or(0)
assert consume.uses <= [Store<Int>]
assert consume.uses.includes(Store<Int>)
assert not consume.uses.includes(Store<Str>)
fn main() = ()
|};
  [%expect {| () |}]
