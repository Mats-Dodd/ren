(* Generator frame construction and stepping have different access
   intervals. Check the source programs, without running their frames. *)
open Ren

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let check ?reject name src =
  let file = "generator-excl.ren" in
  match Driver.check ~file src with
  | _ ->
      if reject <> None then failwith (name ^ ": accepted an overlapping access");
      print_endline (name ^ ": accepted")
  | exception error -> (
      match (reject, Driver.render_error ~sources:(fun _ -> Some src) error) with
      | Some part, Some text when contains text part ->
          print_endline (name ^ ": rejected overlap")
      | _, Some text -> failwith (name ^ ": " ^ text)
      | _ -> raise error)

let producers =
  {|gen fn produce(inout n: Int) -> Int =
  n += 1
  yield n

gen fn array_step(inout xs: Array<Int>) -> Int =
  &xs.push(9)
  yield xs.len()

gen fn copied_arg(inout xs: Array<Int>, before: Array<Int>) -> Int =
  &xs.push(9)
  yield before.len()

gen fn callback(src: fn() -> Int) -> Int =
  yield try src()

fn consume(src: fn() -> Option<Int>, inout n: Int) =
  let _ = try src()
  n += 1

fn paired(a: fn() -> Option<Int>, b: fn() -> Option<Int>) =
  let _ = try a()
  let _ = try b()
  ()

|}

let%expect_test "[g1] retained generator places activate per step or receiving call" =
  check "before and between steps"
    (producers ^ {|fn main() uses Console =
  var n = 0
  let g = produce(&n)
  n += 1
  let _ = g()
  n += 1
  let _ = g()
  print(n)
|});
  check ~reject:"by this block" "named frame passed for a call"
    (producers ^ {|fn main() uses Console =
  var n = 0
  let g = produce(&n)
  consume(g, &n)
  print(n)
|});
  check ~reject:"by this block" "temporary frame passed for a call"
    (producers ^ {|fn main() uses Console =
  var n = 0
  consume(produce(&n), &n)
  print(n)
|});
  check "two sibling frames"
    (producers ^ {|fn main() uses Console =
  var n = 0
  paired(produce(&n), produce(&n))
  print(n)
|});
  [%expect {|
    before and between steps: accepted
    named frame passed for a call: rejected overlap
    temporary frame passed for a call: rejected overlap
    two sibling frames: accepted
    |}]

let%expect_test "[g1] factories retain blocks and reject overlapping inout arguments" =
  check ~reject:"by this block" "retained callback"
    (producers ^ {|fn main() uses Console =
  var n = 0
  let g = callback(fn() =>
    n += 1
    n)
  consume(g, &n)
  print(n)
|});
  check ~reject:"passed with `&` twice" "same place twice in one frame"
    (producers ^ {|gen fn twice(inout a: Int, inout b: Int) -> Int =
  a += 1
  b += 1
  yield a + b
fn main() uses Console =
  var n = 0
  let g = twice(&n, &n)
  print(n)
|});
  check "copied data is independent of retained place"
    (producers ^ {|fn main() uses Console =
  var xs = [1, 2]
  let g = copied_arg(&xs, xs)
  let _ = g()
  print(xs)
|});
  [%expect {|
    retained callback: rejected overlap
    same place twice in one frame: rejected overlap
    copied data is independent of retained place: accepted
    |}]

let%expect_test "[g1] a loop can construct a frame but cannot step an overlapping one" =
  check "unstepped frame inside a loop"
    (producers ^ {|fn main() uses Console =
  var xs = [1, 2]
  for x in &xs
    let g = array_step(&xs)
    x += 1
  print(xs)
|});
  check ~reject:"while the loop changes it" "step during an overlapping loop"
    (producers ^ {|fn main() uses Console =
  var xs = [1, 2]
  let g = array_step(&xs)
  for x in &xs
    let _ = g()
    x += 1
  print(xs)
|});
  check ~reject:"for` loop" "data arguments are read at construction"
    (producers ^ {|fn main() uses Console =
  var xs = [1, 2]
  for x in &xs
    let g = copied_arg(&xs, xs)
    x += 1
  print(xs)
|});
  [%expect {|
    unstepped frame inside a loop: accepted
    step during an overlapping loop: rejected overlap
    data arguments are read at construction: rejected overlap
    |}]

let%expect_test "[g1] a generator's own frame is a mutable capture" =
  let prefix =
    {|gen fn effectful() -> Int uses Console =
  print("step")
  yield 1
pub fn concurrent_use(src: concurrent fn() -> Option<Int>) =
  let _ = try src()
  ()
|}
  in
  check ~reject:"frame can't be shared" "named frame across tasks"
    (prefix ^ {|fn main() uses Console =
  let g = effectful()
  concurrent_use(g)
|});
  check ~reject:"frame can't be shared" "temporary frame across tasks"
    (prefix ^ {|fn main() uses Console =
  concurrent_use(effectful())
|});
  check "fresh frame in each task"
    (prefix ^ {|fn main() uses Console =
  concurrent_use(fn() =>
    let g = effectful()
    g())
|});
  [%expect {|
    named frame across tasks: rejected overlap
    temporary frame across tasks: rejected overlap
    fresh frame in each task: accepted
    |}]

let%expect_test "[g1] delegation activates a local pull block's captures" =
  check ~reject:"while the loop changes it" "yield from a captured local block"
    {|gen fn delegated() -> Int =
  var xs = [1, 2]
  let pull = fn() => Some(xs.len())
  for x in &xs
    yield from pull
fn main() = ()
|};
  [%expect {|
    yield from a captured local block: rejected overlap
    |}]

let%expect_test "[g1] a pulled value cursor cannot be shared across tasks" =
  let prefix =
    {|gen fn pure() -> Int = yield 1
pub fn concurrent_use(src: concurrent fn() -> Option<Int>) =
  let _ = try src()
  ()
|}
  in
  check ~reject:"state can't be shared" "a named cursor pull adapter"
    (prefix ^ {|fn main() =
  var r = pure()
  concurrent_use(&r)
|});
  check ~reject:"state can't be shared" "a temporary cursor pull adapter"
    (prefix ^ {|fn main() = concurrent_use(pure())
|});
  [%expect {|
    a named cursor pull adapter: rejected overlap
    a temporary cursor pull adapter: rejected overlap
    |}]
