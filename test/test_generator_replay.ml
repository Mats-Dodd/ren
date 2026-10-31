open Helpers

let blocks files names =
  let _, file, src, load = program files in
  let inferred = Ren.Driver.inferred ~load ~file (src ^ "\nfn main() = ()\n") in
  List.iter (fun name ->
      let _, (g : Ren.Ty.generator) = Ren.Path.Map.bindings inferred.generators
        |> List.find (fun ((path : Ren.Path.t), _) -> path.name = name) in
      assert (g.kind = Ren.Ty.Block_gen);
      assert g.replay_unsafe;
      assert (g.uses = Ren.Ty.closed);
      assert (not g.holds_instance);
      print_endline (name ^ ": ambient block")) names

let sampled = {|gen fn sampled() -> Int =
  let n = with test_random(17) in Random.int(1000000)
  yield n
  yield n
|}

let%expect_test "a completed task-local random handler does not make a replayable cursor" =
  blocks ["main.ren", sampled] ["sampled"];
  run (sampled ^ {|
fn main() uses Console =
  let g = sampled()
  let first = g()
  assert g() == first
  assert g() == None
  print("sample is retained without replay")
|});
  [%expect {|
    sampled: ambient block
    sample is retained without replay
    ()
    |}]

let%expect_test "a completed runtime installation does not make a replayable cursor" =
  blocks ["main.ren", {|import sim
gen fn installed() -> Int =
  let _ = with sim.scheduler(17) in ()
  yield 1
  yield 2
|}] ["installed"];
  [%expect {| installed: ambient block |}]

let%expect_test "ambient behavior propagates through ordinary imported helpers and delegation" =
  blocks [
    "main.ren", {|import samples
gen fn child() -> Int =
  let n = samples.sample()
  yield n
  yield n
gen fn parent() -> Int = yield from child()
|};
    "samples.ren", {|pub fn sample() -> Int =
  with test_random(17) in Random.int(1000000)
|}
  ] ["child"; "parent"];
  [%expect {|
    child: ambient block
    parent: ambient block
    |}]

let%expect_test "an imported opaque value cannot hide ambient private display code" =
  blocks [
    "main.ren", {|import samples
gen fn revealed() -> Str =
  let value = samples.make()
  yield show(value)
|};
    "samples.ren", {|type Secret = { value: Int }
  fn show(self) -> Str =
    let n = with test_random(17) in Random.int(1000000)
    show(n)

pub type Sample = opaque Secret
pub fn make() -> Sample = { value: 0 }
|}
  ] ["revealed"];
  [%expect {| revealed: ambient block |}]

let%expect_test "public records retain ambient show and private key dispatch summaries" =
  blocks [
    "main.ren", {|import samples
gen fn displayed() -> Str = yield show(samples.displayed())
gen fn keyed() -> Str = yield show(samples.keyed().hash())
|};
    "samples.ren", {|pub type Displayed = { value: Int }
  pub fn show(self) -> Str =
    let n = with test_random(17) in Random.int(1000000)
    show(n)
pub type Keyed = { value: Int }
  fn key(self) -> Int =
    with test_random(17) in Random.int(1000000)
pub fn displayed() -> Displayed = { value: 0 }
pub fn keyed() -> Keyed = { value: 0 }
|}
  ] ["displayed"; "keyed"];
  [%expect {|
    displayed: ambient block
    keyed: ambient block
    |}]
