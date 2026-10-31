(* Generators stage (briefs/stage-generators.md).

   The g1 specimens are ordinary assertions. Later specimens execute today
   through Helpers.until, which keeps the required output or diagnostic and
   fails when it lands, forcing the owning step to activate the assertion.
   A rejected specimen is not evidence that its eventual behavior works.
   See bench/generators/README.md
   for the differential native matrix and the explicitly deferred contracts.

   Keep diagnostics compact here: their headline, explanation and help are
   the contract; source spans are settled when each step lands. *)

open Helpers

let compact f =
  let out, raised = captured f in
  let lines = String.split_on_char '\n' out in
  let diagnostic = List.exists (String.starts_with ~prefix:"error:") lines in
  let hidden name =
    let rec at i =
      i + String.length name <= String.length out &&
      (String.sub out i (String.length name) = name || at (i + 1))
    in
    at 0
  in
  if diagnostic && List.exists hidden [ "$frame"; "$taken"; "$gen" ] then
    failwith "generator diagnostic exposes a compiler temporary";
  if diagnostic then
    List.iter
      (fun line ->
        let line = String.trim line in
        if List.exists (fun p -> String.starts_with ~prefix:p line)
             [ "error:"; "help:"; "= "; "`" ]
        then print_endline line
        else if String.starts_with ~prefix:"│" line then (
          let start = ref (String.length "│") in
          while !start < String.length line &&
                List.mem line.[!start] [ ' '; '^'; '-' ] do
            incr start
          done;
          if !start < String.length line then
            print_endline (String.sub line !start (String.length line - !start))))
      lines
  else print_string out;
  Option.iter raise raised

let guarded =
  {|gen fn guarded(label: Str, n: Int) -> Int uses Console =
  finally(r) =>
    print((label, r))
    try r
  for i in 0..n
    yield i

|}

let pure =
  {|gen fn numbers(n: Int) -> Int =
  for i in 0..n
    yield i

|}

let%expect_test "[g1] temporary and named frames complete once" =
  compact (fun () -> run (guarded ^ {|fn main() uses Console =
  for x in guarded("temporary", 2)
    print(x)
  let g = guarded("named", 1)
  print(g())
  print(g())
  print(g())
  print("scope ends")
|}));
  [%expect {|0
1
("temporary", Ok(()))
Some(0)
("named", Ok(()))
None
None
scope ends
()
|}]

let%expect_test "[g1] temporary break cancels before next statement" =
  compact (fun () -> run (guarded ^ {|fn main() uses Console =
  for x in guarded("temporary", 3)
    print(x)
    break
  print("after")
|}));
  [%expect {|0
("temporary", Err(Cancelled))
after
()
|}]

let%expect_test "[g1] named break resumes and cancellation waits for binding scope" =
  compact (fun () -> run (guarded ^ {|fn consume() uses Console =
  let g = guarded("named", 5)
  for x in g
    print(x)
    break
  print("between")
  for x in g
    print(x)
    break
  print("leaving")

fn main() uses Console =
  consume()
  print("after")
|}));
  [%expect {|0
between
1
leaving
("named", Err(Cancelled))
after
()
|}]

let%expect_test "[g1] temporary consumer return unwinds frame" =
  compact (fun () -> run (guarded ^ {|fn consume() -> Int uses Console =
  for x in guarded("g", 3)
    return x + 7
  99

fn main() uses Console = print(consume())
|}));
  [%expect {|("g", Err(Cancelled))
7
()
|}]

let%expect_test "[g1] temporary consumer failure is abandonment" =
  compact (fun () -> run (guarded ^ {|fn consume() ! ConsumerBad uses Console =
  for x in guarded("g", 3)
    fail ConsumerBad

fn main() uses Console = print(attempt consume())
|}));
  [%expect {|("g", Err(Cancelled))
Err(ConsumerBad)
()
|}]

let%expect_test "[g1] temporary contained panic finalizes once" =
  compact (fun () -> run (guarded ^ {|fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    for x in guarded("g", 3)
      let xs = [0]
      print(xs[4])
  match result
    Ok(_) => print(false)
    Err(_) => print(true)
|}));
  [%expect {|("g", Err(Cancelled))
true
()
|}]

let%expect_test "[g1] named consumer return unwinds frame" =
  compact (fun () -> run (guarded ^ {|fn consume() -> Int uses Console =
  let g = guarded("g", 3)
  for x in g
    return x + 7
  99

fn main() uses Console = print(consume())
|}));
  [%expect {|("g", Err(Cancelled))
7
()
|}]

let%expect_test "[g1] named consumer failure is abandonment" =
  compact (fun () -> run (guarded ^ {|fn consume() ! ConsumerBad uses Console =
  let g = guarded("g", 3)
  for x in g
    fail ConsumerBad

fn main() uses Console = print(attempt consume())
|}));
  [%expect {|("g", Err(Cancelled))
Err(ConsumerBad)
()
|}]

let%expect_test "[g1] named contained panic finalizes once" =
  compact (fun () -> run (guarded ^ {|fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    let g = guarded("g", 3)
    for x in g
      let xs = [0]
      print(xs[4])
  match result
    Ok(_) => print(false)
    Err(_) => print(true)
|}));
  [%expect {|("g", Err(Cancelled))
true
()
|}]

let%expect_test "[g1] generator explicit return is Ok and ends once" =
  compact (fun () -> run ({|gen fn once() -> Int uses Console =
  finally(r) =>
    print(r)
    try r
  yield 4
  return
  yield 99

fn main() uses Console =
  let g = once()
  print(g())
  print(g())
  print(g())
|}));
  [%expect {|Some(4)
Ok(())
None
None
()
|}]

let%expect_test "[g1] typed failure is kept and cleanup does not run twice" =
  compact (fun () -> run ({|gen fn broken() -> Int ! Bad(at: Int) uses Console =
  finally(r) =>
    print(r)
    try r
  yield 7
  fail Bad(8)

fn main() uses Console =
  let g = broken()
  print(attempt g())
  print(attempt g())
  print(attempt g())
|}));
  [%expect {|Ok(Some(7))
Err(Bad(8))
Err(Bad(8))
Err(Bad(8))
()
|}]

let%expect_test "[g1] never stepped means no BEGIN and no cleanup" =
  compact (fun () -> run ({|dep Tx =
  row: fn() -> Int

handler transaction() for Tx uses Console =
  let start = print("BEGIN")
  finally(r) =>
    print(r)
    try r
  row() => 9

gen fn rows() -> Int uses Console =
  with transaction() in
    yield Tx.row()

fn main() uses Console =
  let never = rows()
  print("before first step")
  let live = rows()
  print(live())
  print("scope ends")
|}));
  [%expect {|before first step
BEGIN
Some(9)
scope ends
Err(Cancelled)
()
|}]

let%expect_test "[g1] frames close in reverse order before surrounding with" =
  compact (fun () -> run (guarded ^ {|fn main() uses Console =
  let a = guarded("a", 2)
  print(a())
  let b = guarded("b", 2)
  print(b())
|}));
  [%expect {|Some(0)
Some(0)
("b", Err(Cancelled))
("a", Err(Cancelled))
()
|}]

let%expect_test "[g1] data cursor copy is an honest fork and can be stored and returned" =
  compact (fun () -> run (pure ^ {|type Saved = { rest: numbers.Cursor }

fn make() -> numbers.Cursor = numbers(4)

fn main() uses Console =
  var a = make()
  print(&a.next())
  let saved = Saved { rest: a }
  var b = saved.rest
  print(&b.next())
  print(&b.next())
  print(&a.next())
  print(&a.next())
  print(&a.next())
  print(&a.next())
  print(&b.next())
|}));
  [%expect {|Some(0)
Some(1)
Some(2)
Some(1)
Some(2)
Some(3)
None
Some(3)
()
|}]

let%expect_test "[g1] recursive yield from and failing child use the caller task" =
  compact (fun () -> run ({|gen fn walk(n: Int) -> Int ! Bad =
  if n < 0 then fail Bad
  if n > 0 then yield from try walk(n - 1)
  yield n

fn consume(n: Int) ! Bad uses Console =
  for x in try walk(n)
    print(x)

fn main() uses Console =
  print(attempt consume(2))
  print(attempt consume(-1))
|}));
  [%expect {|0
1
2
Ok(())
Err(Bad)
()
|}]

let%expect_test "[g1] inferred dependency row makes a generator nonstorable" =
  compact (fun () -> check_error ({|gen fn sneaky() -> Int =
  print("effect")
  yield 1

type Box<T> = { value: T }
fn main() =
  let b = Box { value: sneaky() }
  ()
|}));
  [%expect {|
    error: `sneaky()` uses `Console`, so its stream lives in this scope
    a block, which can't be stored
    = a generator that uses a dependency runs in its caller's frame
    help: to keep a position, keep a reader, which is data
    |}]

let%expect_test "[g1] effectful generator cannot be returned" =
  compact (fun () -> check_error ({|gen fn rows() -> Int uses Console =
  print("row")
  yield 1

fn later() = rows()
fn main() = ()
|}));
  [%expect {|
    error: `rows()` uses `Console`, so its stream lives in this scope
    a block, which can't be returned
    = a generator that uses a dependency runs in its caller's frame
    help: to keep a position, keep a reader, which is data
    |}]

let%expect_test "[g1] yield outside generator" =
  compact (fun () -> check_error ({|fn main() =
  yield 1
|}));
  [%expect {|
    error: `yield` is only allowed in a `gen fn`
    help: mark this function `gen fn`, or return a value
    |}]

let%expect_test "[g1] yield inside a literal block has the operation help" =
  compact (fun () -> check_error ({|gen fn rows() -> Int uses Async =
  Async.scope fn(s) =>
    yield 1

fn main() = ()
|}));
  [%expect {|
    error: `yield` inside a block
    = the generator would stop here with a block's scope open in its consumer
    help: time the step where it's consumed, or put the producer on a task: `Async.produce(cap: 1, fn() => ...)`
    |}]

let%expect_test "[g1] yield in finally is forbidden" =
  compact (fun () -> check_error ({|gen fn rows() -> Int =
  finally(r) =>
    yield 2
    try r
  yield 1

fn main() = ()
|}));
  [%expect {|
    error: `yield` isn't allowed in a `finally`
    help: yield from the generator body before cleanup
    |}]

let%expect_test "[g1] for must handle next failure with try" =
  compact (fun () -> check_error ({|gen fn rows() -> Int ! Bad =
  yield 1
  fail Bad

fn main() uses Console =
  for row in rows()
    print(row)
|}));
  [%expect {|
    error: `next` can fail, and nothing handles it
    it can fail with Bad, from `rows()`
    help: for row in try rows()
    |}]

let%expect_test "[g2] every transforming stage runs lazily on a value cursor" =
  until "g2" ~want:{|[0, 8, 12]
[2, 3, 4]
[(0, 0), (1, 10), (2, 1), (3, 11), (4, 2), (5, 12)]
[0, 1, 3, 6]
[1, 2, 1]
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|fn main() uses Console =
  print(numbers(8).map(fn(x) => x * 2).select(fn(x) => x % 4 == 0).reject(fn(x) => x == 4).to_array())
  print(numbers(6).drop_while(fn(x) => x < 2).take_while(fn(x) => x < 5).to_array())
  print(numbers(3).flat_map(fn(x) => [x, x + 10]).with_index().to_array())
  print(numbers(4).scan(0, fn(a, x) => a + x).to_array())
  print([1, 1, 2, 2, 1].cursor().dedup_by(fn(x) => x).to_array())
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `map`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `drop_while`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `flat_map`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `scan`
    help: its methods: `next`
    error: `Array<Int>` has no method named `cursor`
    help: its methods: `len`, `push`, `sort`, `copy`, `split_at`, `join`, `get`, `first`, `last`, `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `each`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `take`, `drop`, `reverse`
    |}]

let%expect_test "[g2] every shaping stage including end flush" =
  until "g2" ~want:{|[1, 2, 3]
[[0, 1], [2, 3], [4]]
[[0, 1], [2, 3], [4]]
[[0, 1], [1, 2], [2, 3]]
[(0, 0), (1, 1)]
[1, 2, 3, 4, 5]
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|fn main() uses Console =
  print(numbers(7).drop(1).take(3).to_array())
  print(numbers(5).batch(2).to_array())
  print(numbers(5).batch_while(fn(a, b) => a / 2 == b / 2).to_array())
  print(numbers(4).windows(2).to_array())
  print(numbers(3).zip(numbers(2)).to_array())
  print([1, 3, 5].cursor().merge_by([2, 4].cursor(), fn(x) => x).to_array())
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `drop`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `batch`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `batch_while`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `windows`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `zip`
    help: its methods: `next`
    error: `Array<Int>` has no method named `cursor`
    help: its methods: `len`, `push`, `sort`, `copy`, `split_at`, `join`, `get`, `first`, `last`, `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `each`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `take`, `drop`, `reverse`
    error: `Array<Int>` has no method named `cursor`
    help: its methods: `len`, `push`, `sort`, `copy`, `split_at`, `join`, `get`, `first`, `last`, `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `each`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `take`, `drop`, `reverse`
    |}]

let%expect_test "[g2] every sink including empty and predicate-free count" =
  until "g2" ~want:{|10
16
5
3
true
true
Some(3)
None
Some(0)
Some(0)
Some(4)
[]
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|fn main() uses Console =
  print(numbers(5).sum())
  print(numbers(4).reduce(10, fn(a, x) => a + x))
  print(numbers(5).count())
  print(numbers(5).count(fn(x) => x % 2 == 0))
  print(numbers(5).any(fn(x) => x == 3))
  print(numbers(5).all(fn(x) => x < 5))
  print(numbers(5).find(fn(x) => x > 2))
  print(numbers(0).first())
  print(numbers(5).first())
  print(numbers(5).min())
  print(numbers(5).max())
  print(numbers(0).to_array())
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `sum`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `reduce`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `any`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `all`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `find`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `first`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `first`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `min`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `max`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `to_array`
    help: its methods: `next`
    |}]

let%expect_test "[g2] let bound pipeline steps its source between calls" =
  until "g2" ~want:{|Some(0)
Some(1)
Some(2)
None
10
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|fn consume(src: fn() -> Option<Int>) -> Int =
  var total = 0
  for x in try src
    total += x
  total

fn main() uses Console =
  var r = numbers(6)
  var limit = 10
  let p = &r.select(fn(x) => x < limit)
  print(p())
  print(&r.next())
  limit = 3
  print(p())
  print(p())
  print(consume(numbers(4).map(fn(x) => x + 1)))
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `select`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `map`
    help: its methods: `next`
    |}]

let%expect_test "[g2] lookahead remains consumed after break" =
  until "g2" ~want:{|0
1
Some(3)
[0, 1, 2]
Some(3)
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|fn main() uses Console =
  var r = numbers(6)
  for x in &r.take_while(fn(x) => x < 2)
    print(x)
  print(&r.next())
  var s = numbers(6)
  for window in &s.windows(3)
    print(window)
    break
  print(&s.next())
|})));
  [%expect {|
    (until g2)
    error: `&` needs a variable it can change
    help: only a variable, or a field or element of one, can be changed
    error: `&` needs a variable it can change
    help: only a variable, or a field or element of one, can be changed
    |}]

let%expect_test "[g2] continuation lines preserve eager and lazy receivers" =
  until "g2" ~want:{|7
12
12
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|type Ordinary = { n: Int }
  pub fn map(self, n: Int) -> Int = self.n + n

fn main() uses Console =
  print(Ordinary { n: 3 }.map(4))
  print([0, 1, 2, 3].select(fn(x) => x > 0).map(fn(x) => x * 2).sum())
  print(numbers(4)
    .select(fn(x) => x > 0)
    .map(fn(x) => x * 2)
    .sum())
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `select`
    help: its methods: `next`
    |}]

let%expect_test "[g2] take and find abandon temporary generators" =
  until "g2" ~want:{|("take", Err(Cancelled))
[0]
("find", Err(Cancelled))
Some(2)
()
|} (fun () ->
      compact (fun () -> run (guarded ^ {|fn main() uses Console =
  print(guarded("take", 5).take(1).to_array())
  print(guarded("find", 5).find(fn(x) => x == 2))
|})));
  [%expect {|
    (until g2)
    error: `.take` needs a record, but this is a `fn() -> Option<Int>`
    error: `.find` needs a record, but this is a `fn() -> Option<Int>`
    |}]

let%expect_test "[g2] missing ampersand names the user cursor" =
  until "g2" ~says:[ "a pipeline steps a named cursor in place"; "help:"; "&r.select" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn main() =
  var r = numbers(4)
  let errs = r.select(fn(x) => x > 0)
  ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `select`
    help: its methods: `next`
    |}]

let%expect_test "[g2] pipeline chosen by if gives one-stage help" =
  until "g2" ~says:[ "`let` binds one pipeline written right there"; "help: choose inside one stage" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn main() =
  var r = numbers(4)
  let all = true
  let rows = if all then &r.select(fn(x) => true) else &r.select(fn(x) => x > 1)
  ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `select`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `select`
    help: its methods: `next`
    |}]

let%expect_test "[g2] pipeline cannot be stored" =
  until "g2" ~says:[ "stored"; "help:"; "`gen fn`" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|type Box<T> = { value: T }
fn main() =
  let b = Box { value: numbers(4).take(2) }
  ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `take`
    help: its methods: `next`
    |}]

let%expect_test "[g2] pipeline cannot be returned" =
  until "g2" ~says:[ "returned"; "help:"; "`gen fn`" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn later() = numbers(4).take(2)
fn main() = ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `take`
    help: its methods: `next`
    |}]

let%expect_test "[g2] cursor stage names are reserved by type" =
  until "g2" ~says:[ "`map` is a stream stage on a type with `next`"; "help:"; "gen fn" ] (fun () ->
      compact (fun () -> check_error ({|type Cursor = { at: Int }
  pub fn next(inout self) -> Option<Int> = None
  pub fn map(self, x: Int) -> Int = x

fn main() = ()
|})));
  [%expect {|
    (until g2)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[g2] filter suggests select" =
  until "g2" ~says:[ "`filter`"; "help:"; ".select(" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn main() =
  let p = numbers(4).filter(fn(x) => true)
  ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `filter`
    help: its methods: `next`
    |}]

let%expect_test "[g2] skip suggests drop" =
  until "g2" ~says:[ "`skip`"; "help:"; ".drop(" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn main() =
  let p = numbers(4).skip(2)
  ()
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `skip`
    help: its methods: `next`
    |}]

let%expect_test "[g2] two pipeline blocks in one call step their shared cursor in order" =
  until "g2" ~want:{|Some(0)
Some(1)
None
None
Some(2)
()
|} (fun () ->
      compact (fun () -> run (pure ^ {|
fn both(a: fn() -> Option<Int>, b: fn() -> Option<Int>) uses Console =
  print(try a())
  print(try b())
  print(try a())
  print(try b())

fn main() uses Console =
  var r = numbers(4)
  both(&r.take(1), &r.take(1))
  print(&r.next())
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `take`
    help: its methods: `next`
    error: `numbers.Cursor` has no method named `take`
    help: its methods: `next`
    |}]

let%expect_test "[g2] stage failure diagnostic names map and the loop try" =
  until "g2" ~says:[ "`next` can fail"; "BadLine"; "map"; "help:"; "for x in try" ] (fun () ->
      compact (fun () -> check_error (pure ^ {|fn parse(x: Int) -> Int ! BadLine =
  if x == 2 then fail BadLine
  x

fn main() uses Console =
  for x in numbers(4).map(fn(x) => try parse(x))
    print(x)
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `map`
    help: its methods: `next`
    |}]

let%expect_test "[g1] held inout rechecks uniqueness after every yield" =
  compact (fun () -> run ({|gen fn change(inout xs: Array<Int>) -> Int =
  &xs.push(1)
  yield xs.len()
  &xs.push(2)
  yield xs.len()

fn main() uses Console =
  var xs = [0]
  let g = change(&xs)
  print(g())
  let copy = xs
  print(g())
  print(copy)
  print(xs)
|}));
  [%expect {|Some(2)
Some(3)
[0, 1]
[0, 1, 2]
()
|}]

let%expect_test "[g1] recursive yield from has the call depth limit pushed" =
  compact (fun () -> run_error ({|gen fn down(n: Int) -> Int =
  if n > 0 then yield from down(n - 1)
  yield n

fn main() uses Console =
  for x in down(100001)
    print(x)
|}));
  [%expect {|
    error: panic: the stack overflowed: a function called itself too deeply
    |}]

let%expect_test "[g1] recursive yield from has the call depth limit pulled" =
  compact (fun () -> run_error ({|gen fn down(n: Int) -> Int =
  if n > 0 then yield from down(n - 1)
  yield n

fn main() uses Console =
  var g = down(100001)
  print(&g.next())
|}));
  [%expect {|
    error: panic: the stack overflowed: a function called itself too deeply
    |}]

let%expect_test "[g5] Fs reader resumes after break and copies its offset" =
  until "g5" ~want:{|a
---
Some("b")
Some("b")
c
()
|} (fun () ->
      compact (fun () -> run ({|fn main() =
  let p = Path.of("log")
  with mem_fs([File { path: p, data: "a\n---\nb\nc\n".bytes() }]) in
    var r = Fs.line_reader(p)
    for line in try &r
      print(line)
      if line == "---" then break
    var copy = r
    print(try &r.next())
    print(try &copy.next())
    for line in try &r
      print(line)
|})));
  [%expect {|
    (until g5)
    error: `Fs` has no operation or member named `line_reader`
    help: its operations: `read`, `write`, `exists`; its members: `read_str`
    |}]

let%expect_test "[g5] small Fs family reopens an evicted file at its saved offset" =
  until "g5" ~want:{|Some("a0")
Some("b0")
Some("a1")
()
|} (fun () ->
      compact (fun () -> run ({|fn main() =
  let a = Path.of("a")
  let b = Path.of("b")
  with mem_fs([File { path: a, data: "a0\na1\n".bytes() }, File { path: b, data: "b0\n".bytes() }], max: 1) in
    var r = Fs.line_reader(a)
    var s = Fs.line_reader(b)
    print(try &r.next())
    print(try &s.next())
    print(try &r.next())
|})));
  [%expect {|
    (until g5)
    error: `Fs` has no operation or member named `line_reader`
    help: its operations: `read`, `write`, `exists`; its members: `read_str`
    error: `Fs` has no operation or member named `line_reader`
    help: its operations: `read`, `write`, `exists`; its members: `read_str`
    |}]

let%expect_test "[g5] reader cannot escape installing with and names dependency" =
  until "g5" ~says:[ "leave the `with` that installs `Fs`" ] (fun () ->
      compact (fun () -> check_error ({|fn main() =
  let escaped = with mem_fs([]) in
    Fs.line_reader(Path.of("log"))
  ()
|})));
  [%expect {|
    (until g5)
    error: `Fs` has no operation or member named `line_reader`
    help: its operations: `read`, `write`, `exists`; its members: `read_str`
    |}]

let%expect_test "[g1] public omitted uses declares an empty row and yields data" =
  compact (fun () -> run ({|pub gen fn declared(n: Int) -> Int =
  for i in 0..n
    yield i

type Box = { value: declared.Cursor }
fn make() -> declared.Cursor = declared(2)

fn main() uses Console =
  let boxed = Box { value: make() }
  var c = boxed.value
  print(&c.next())
  print(&c.next())
  print(&c.next())
|}));
  [%expect {|Some(0)
Some(1)
None
()
|}]

let%expect_test "[g1] public empty row rejects an undeclared dependency" =
  compact (fun () -> check_error ({|pub gen fn sneaky() -> Int =
  print("effect")
  yield 1

fn main() = ()
|}));
  [%expect {|
    error: `sneaky` doesn't declare `Console`
    this call uses `Console`
    = a public function without `uses` uses nothing, and its body is checked against that
    help: add `uses Console`
    |}]

let%expect_test "[g2] pipeline capture conflicts with an explicit mutation for the call" =
  until "g2" ~says:[ "`r`"; "while the call changes it"; "help:" ] (fun () ->
      compact (fun () -> check_error ({|gen fn numbers(n: Int) -> Int =
  for i in 0..n
    yield i

fn consume(src: fn() -> Option<Int>, inout r: numbers.Cursor) =
  let _ = try src()
  let _ = &r.next()
  ()

fn main() =
  var r = numbers(4)
  consume(&r.take(2), &r)
|})));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `take`
    help: its methods: `next`
    |}]

let%expect_test "[g2] custom cursor chains are recognized by next type" =
  until "g2" ~want:{|[6, 8]
()
|} (fun () ->
      compact (fun () -> run ({|type Counter = { at: Int }
  pub fn next(inout self) -> Option<Int> =
    if self.at == 4 then None
    else
      self.at += 1
      Some(self.at)

fn main() uses Console =
  var c = Counter { at: 0 }
  print(&c.map(fn(x) => x * 2).select(fn(x) => x > 4).to_array())
|})));
  [%expect {|
    (until g2)
    error: `&` needs something it can change, but this is a new value
    help: put it in a `var` first
    |}]

let%expect_test "[g1] cancel_sim across 1000 simulation seeds" =
  compact (fun () -> test ~seeds:1000 ({|pub dep State =
  ready: fn()
  wait_started: fn()
  park: fn()
  ended: fn(cancelled: Bool)
  results: fn() -> Array<Bool>

pub handler state() for State uses Async =
  var begun = false
  var ends: Array<Bool> = []
  ready() => begun = true
  wait_started() => Async.until fn() => begun
  park() => Async.until fn() => false
  ended(cancelled) => &ends.push(cancelled)
  results() => ends

pub gen fn slow(mid_step: Bool) -> Int uses Async, State =
  finally(r) =>
    match r
      Err(Cancelled) => State.ended(true)
      _ => State.ended(false)
    try r
  yield 0
  if mid_step then
    State.ready()
    State.park()
  yield 1

pub fn worker(named: Bool, mid_step: Bool) uses Async, State =
  if named then
    let g = slow(mid_step)
    for x in g
      if mid_step then ()
      else
        State.ready()
        State.park()
  else
    for x in slow(mid_step)
      if mid_step then ()
      else
        State.ready()
        State.park()

test "cancel temporary/named during body/step finalizes exactly once" =
  for named in [false, true]
    for mid_step in [false, true]
      with state() in
        Async.beside(fn() => worker(named, mid_step)) fn() =>
          State.wait_started()
        assert State.results() == [true]
|}));
  [%expect {|test.ren
  ✓ cancel temporary/named during body/step finalizes exactly once

1 passed, each under 1000 seeds
[exit 0]
|}]

let%expect_test "[g3] merge_sim across 1000 simulation seeds" =
  until "g3" ~want:{|test.ren
  ✓ consumer departure cancels every producer and waits for cleanup
  ✓ failure follows the winner value and every started sibling ends
  ✓ produce early exit waits for producer cleanup
  ✓ a producer failure follows every buffered value
  ✓ cancelling a receive leaves the later token unconsumed
  ✓ cancelling a send with a full queue preserves the admitted token
  ✓ close wakes receivers and all observe the terminal state

7 passed, each under 1000 seeds
[exit 0]
|} (fun () ->
      compact (fun () -> test ~seeds:1000 ({|import sync.{Chan}

pub dep Audit =
  start: fn(id: Int)
  expect: fn(n: Int)
  wait_ready: fn()
  stop: fn(id: Int)
  stopped: fn() -> Array<Int>

pub handler audit() for Audit uses Async =
  var begun: Array<Int> = []
  var expected = 0
  var ended: Array<Int> = []
  start(id) => &begun.push(id)
  expect(n) => expected = n
  wait_ready() => Async.until fn() => begun.len() >= expected
  stop(id) => &ended.push(id)
  stopped() => ended

pub dep Lifetime =
  touch: fn()

pub handler producer_lifetime() for Lifetime uses Audit =
  finally(r) =>
    Audit.stop(1)
    try r
  touch() => ()

pub gen fn source(id: Int, n: Int) -> Int uses Audit, Async =
  finally(r) =>
    Audit.stop(id)
    try r
  Audit.start(id)
  Audit.wait_ready()
  for i in 0..n
    Async.yield()
    yield id * 100 + i

pub gen fn broken(id: Int) -> Int ! Broken(id: Int) uses Audit, Async =
  finally(r) =>
    Audit.stop(id)
    try r
  Audit.start(id)
  Audit.wait_ready()
  yield id * 100
  Async.yield()
  fail Broken(id)

pub fn failing_merge(inout got: Array<Int>) ! Broken(id: Int) uses Async, Audit =
  try Async.merge(broken(1), broken(2), source(3, 100), cap: 1) fn(items) =>
    for x in try items
      &got.push(x)
      Async.yield()

pub dep Events = Chan<Int>

// A send/receive that returns owns the transfer; a cancelled operation
// cannot be retried as if it had returned. Tokens make duplicates visible.

test "consumer departure cancels every producer and waits for cleanup" =
  with audit() in
    Audit.expect(2)
    Async.merge(source(1, 100), source(2, 100), cap: 1) fn(items) =>
      for x in items
        Async.yield()
        break
    let ended = Audit.stopped()
    assert ended.count(fn(x) => x == 1) == 1
    assert ended.count(fn(x) => x == 2) == 1

test "failure follows the winner value and every started sibling ends" =
  with audit() in
    Audit.expect(3)
    var got: Array<Int> = []
    let result = attempt failing_merge(&got)
    match result
      Err(Broken(winner)) =>
        assert got.count(fn(x) => x == winner * 100) == 1
      Ok(_) => assert false
    for id in [1, 2, 3]
      assert Audit.stopped().count(fn(x) => x == id) == 1
    // A source's items preserve order, though sources can interleave.
    let thirds = got.select(fn(x) => x >= 300)
    for i in 0..thirds.len()
      assert thirds[i] == 300 + i

test "produce early exit waits for producer cleanup" =
  with audit() in
    Async.produce(cap: 1, fn() =>
      with producer_lifetime() in
        for i in 0..100
          Send.send(i)) fn(items) =>
      for x in items
        Async.yield()
        break
    assert Audit.stopped() == [1]

test "a producer failure follows every buffered value" =
  var got: Array<Int> = []
  let result = attempt Async.produce(cap: 3, fn() =>
    Send.send(11)
    Send.send(12)
    fail BufferedBad) fn(items) =>
    for x in try items
      Async.yield()
      &got.push(x)
  assert got == [11, 12]
  assert result == Err(BufferedBad)

test "cancelling a receive leaves the later token unconsumed" =
  with sync.channel(1) as Events in
    Async.beside(fn() =>
      let ignored = Events.recv()
      ()) fn() => Async.yield()
    Events.send(7)
    Events.close()
    assert Events.recv() == Some(7)
    assert Events.recv() == None

test "cancelling a send with a full queue preserves the admitted token" =
  with sync.channel(1) as Events in
    Events.send(1)
    Async.beside(fn() => Events.send(2)) fn() => Async.yield()
    Events.close()
    assert Events.recv() == Some(1)
    assert Events.recv() == None

test "close wakes receivers and all observe the terminal state" =
  with sync.channel(1) as Events in
    let (a, (b, closed)) = Async.both(
      fn() => Events.recv(),
      fn() => Async.both(fn() => Events.recv(), fn() => Events.close()))
    assert a == None
    assert b == None

|})));
  [%expect {|
    (until g3)
    error: `Async` has no operation or member named `merge`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `merge`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    |}]

let%expect_test "[g3] expand_sim across 1000 simulation seeds" =
  until "g3" ~want:{|test.ren
  ✓ all workers returning children progresses without blocked enqueue
  ✓ expand keeps duplicate children and roots
  ✓ an empty frontier returns only after workers end
  ✓ worker failure cancels and awaits every running sibling
  ✓ one worker traverses the frontier depth first

5 passed, each under 1000 seeds
[exit 0]
|} (fun () ->
      compact (fun () -> test ~seeds:1000 ({|pub dep Work =
  enter: fn()
  leave: fn()
  seen: fn(x: Int)
  result: fn() -> (Int, Int, Array<Int>)
  park: fn()

pub handler work() for Work uses Async =
  var active = 0
  var peak = 0
  var values: Array<Int> = []
  enter() =>
    active += 1
    if active > peak then peak = active
  leave() => active -= 1
  seen(x) => &values.push(x)
  result() => (active, peak, values)
  park() => Async.until fn() => false

pub dep Worker =
  touch: fn()

pub handler worker() for Worker uses Work =
  let entered = Work.enter()
  finally(r) =>
    Work.leave()
    try r
  touch() => ()

pub fn children(n: Int) -> Array<Int> uses Work, Async =
  with worker() in
    Async.yield()
    Work.seen(n)
    if n < 7 then [n * 2, n * 2 + 1] else []

test "all workers returning children progresses without blocked enqueue" =
  with work() in
    Async.expand([1], max: 2) fn(n) => children(n)
    let (active, peak, seen) = Work.result()
    assert active == 0
    assert peak <= 2
    assert seen.len() == 13
    for n in 1..14
      assert seen.count(fn(x) => x == n) == 1

test "expand keeps duplicate children and roots" =
  with work() in
    Async.expand([7, 7], max: 2) fn(n) => children(n)
    let (active, peak, seen) = Work.result()
    assert active == 0
    assert seen == [7, 7]

test "an empty frontier returns only after workers end" =
  with work() in
    Async.expand([7, 8, 9], max: 2) fn(n) =>
      with worker() in
        Async.yield()
        Work.seen(n)
        []
    let (active, peak, seen) = Work.result()
    assert active == 0
    assert seen.len() == 3
    assert peak <= 2

test "worker failure cancels and awaits every running sibling" =
  with work() in
    let result = attempt Async.expand([1, 2, 3], max: 2) fn(n) =>
      with worker() in
        Async.yield()
        if n == 1 then fail ExpandBad
        Work.park()
        []
    assert result == Err(ExpandBad)
    let (active, peak, seen) = Work.result()
    assert active == 0
    assert peak <= 2

test "one worker traverses the frontier depth first" =
  with work() in
    Async.expand([1], max: 1) fn(n) =>
      Work.seen(n)
      if n == 1 then [2, 3]
      else if n == 2 then [4, 5]
      else []
    let (active, peak, seen) = Work.result()
    assert active == 0
    assert seen == [1, 2, 4, 5, 3] || seen == [1, 2, 5, 4, 3] || seen == [1, 3, 2, 4, 5] || seen == [1, 3, 2, 5, 4]
|})));
  [%expect {|
    (until g3)
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    |}]

(* Driver.replay checks call order and arguments as well as final output. *)
let replay_matches src =
  let src = clean src in
  let path = Filename.temp_file "ren_generators" ".journal" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () ->
      let recorded, raised = captured (fun () ->
          Out_channel.with_open_bin path (fun out ->
              let journal = Ren.Journal.recording ~file:path ~out ~program:file in
              report src (fun () ->
                  ignore (Ren.Driver.run ~lint:true ~record:journal ~file src)))) in
      Option.iter raise raised;
      if String.starts_with ~prefix:"error:" recorded then print_string recorded
      else
        let journal = Ren.Journal.load ~file:path
            (In_channel.with_open_bin path In_channel.input_all) in
        let replayed, raised = captured (fun () ->
            report src (fun () ->
                ignore (Ren.Driver.replay ~lint:true ~journal ~file src))) in
        Option.iter raise raised;
        if recorded <> replayed then failwith "generator journal changed output";
        print_endline "recorded and replayed the same values and cleanup")

let%expect_test "[g3] merge and expand journal replay includes cancellation and finalization" =
  until "g3" ~want:{|recorded and replayed the same values and cleanup
|} (fun () ->
      compact (fun () -> replay_matches ({|import sim

gen fn source(base: Int) -> Int uses Async, Console =
  finally(r) =>
    print((base, r))
    try r
  for i in 0..3
    Async.yield()
    yield base + i

fn main() uses Console =
  with sim.scheduler(17) in
    Async.merge(source(10), source(20), cap: 1) fn(items) =>
      for x in items
        print(x)
        if x == 11 then break
    Async.expand([1], max: 2) fn(n) =>
      print(n)
      if n < 3 then [n + 1] else []
|})));
  [%expect {|
    (until g3)
    error: `Async` has no operation or member named `merge`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    error: `Async` has no operation or member named `expand`
    help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `beside`, `background`, `both`, `produce`, `map_pull`, `worker`, `single`
    |}]

let%expect_test "[g1] a with held open makes the frame a block despite an empty inferred row" =
  compact (fun () -> check_error {|
dep Value =
  get: fn() -> Int
handler value() for Value =
  get() => 3

gen fn held() -> Int =
  with value() in
    yield Value.get()

type Box<T> = { value: T }
fn main() =
  let b = Box { value: held() }
  ()
|});
  [%expect {|
    error: `held()` is a block, so its stream lives in this scope
    a block, which can't be stored
    = this generator retains a dependency instance across a yield
    help: to keep a position, keep a reader, which is data
    |}]

let%expect_test "[g1] a block parameter makes the frame a block without dependencies" =
  compact (fun () -> check_error {|
gen fn apply(f: fn() -> Int) -> Int =
  yield f()

type Box<T> = { value: T }
fn main() =
  let b = Box { value: apply(fn() => 3) }
  ()
|});
  [%expect {|
    error: `f` can fail, and nothing handles it
    it can fail with whatever the function passed as `f` fails with
    help: pass the errors on with `try`, or handle them with `match`
    error: `apply(...)` is a block, so its stream lives in this scope
    a block, which can't be stored
    = a generator that uses a dependency runs in its caller's frame
    help: to keep a position, keep a reader, which is data
    |}]

let%expect_test "[g1] inout makes the frame a block without dependencies" =
  compact (fun () -> check_error {|
gen fn change(inout xs: Array<Int>) -> Int =
  &xs.push(1)
  yield xs.len()

type Box<T> = { value: T }
fn main() =
  var xs = [0]
  let b = Box { value: change(&xs) }
  ()
|});
  [%expect {|
    error: `change(&xs)` is a block, so its stream lives in this scope
    a block, which can't be stored
    = a generator that uses a dependency runs in its caller's frame
    help: to keep a position, keep a reader, which is data
    |}]

let%expect_test "[g1] an error row alone is data and failed copies keep the same error" =
  compact (fun () -> run {|
gen fn broken() -> Int ! Bad(at: Int) =
  yield 1
  fail Bad(9)

fn main() uses Console =
  var a = broken()
  print(attempt &a.next())
  var b = a
  print(attempt &a.next())
  print(attempt &b.next())
  print(attempt &a.next())
  print(attempt &b.next())
|});
  [%expect {|Ok(Some(1))
Err(Bad(9))
Err(Bad(9))
Err(Bad(9))
Err(Bad(9))
()
|}]

let%expect_test "[g1] a finally not yet reached never runs" =
  compact (fun () -> run {|
gen fn late() -> Int uses Console =
  print("started")
  yield 0
  finally(r) =>
    print("unreached cleanup")
    try r
  yield 1

fn main() uses Console =
  let never = late()
  let g = late()
  print(g())
  print("leaving")
|});
  [%expect {|started
Some(0)
leaving
()
|}]

let%expect_test "[g1] failing yield from requires its own try" =
  compact (fun () -> check_error {|
gen fn broken() -> Int ! Bad = fail Bad
gen fn parent() -> Int =
  yield from broken()
fn main() = ()
|});
  [%expect {|
    error: this `yield from` can fail, and nothing handles it
    it can fail with Bad, from `broken()`
    help: yield from try broken()
    |}]
let%expect_test "[g1] yield item type explains the item annotation" =
  compact (fun () -> check_error {|gen fn values() -> Int =
  yield "wrong"
fn main() = ()
|});
  [%expect {|
    error: this generator yields `Int`, but this `yield` gives `Str`
    help: yield an item of the declared type, or change the generator's item type
    |}]

let%expect_test "[g1] yield from rejects a non-pull operand" =
  compact (fun () -> check_error {|gen fn values() -> Int =
  yield from 7
fn main() = ()
|});
  [%expect {|
    error: `yield from` takes what `for` takes, but this is an `Int`
    help: give it a cursor, collection, or a block that returns `Option`
    |}]

let%expect_test "[g1] generator return cannot carry a value" =
  compact (fun () -> check_error {|gen fn values() -> Int =
  return 3
fn main() = ()
|});
  [%expect {|
    error: a generator returns no value; it yields items
    help: use `yield value` to give an item, or `return` to end the generator
    |}]

let%expect_test "[g1] return does not cross a literal block" =
  compact (fun () -> check_error {|gen fn values() -> Int =
  let choose = fn() => return
  choose()
  yield 1
fn main() = ()
|});
  [%expect {|
    error: `return` can't leave this block
    help: return the block's value and make the decision in its caller
    |}]

let%expect_test "[g1] mutable effectful generator binding suggests let" =
  compact (fun () -> check_error {|gen fn values() -> Int uses Console =
  print("value")
  yield 1
fn main() =
  var g = values()
  ()
|});
  [%expect {|
    error: a block can't be bound with `var`
    help: bind this block with `let`: `let g = values()`
    |}]

let%expect_test "[g1] block frame alias is not made at the binding" =
  compact (fun () -> check_error {|gen fn values() -> Int uses Console =
  print("value")
  yield 1
fn main() =
  let g = values()
  let alias = g
  ()
|});
  [%expect {|
    error: `let` binds one block written right there
    not a `fn` written here
    = a `let` names one block, so the code it runs is known where it's called
    help: pass `g` where it's needed, or write `let alias = fn() => g()`
    |}]

let%expect_test "[g1] ampersand does not apply to an effectful generator block" =
  compact (fun () -> check_error {|gen fn values() -> Int uses Console =
  print("value")
  yield 1
fn main() =
  let g = values()
  for x in &g
    ()
|});
  [%expect {|
    error: a block never takes `&`
    help: step the block with `g()`, or pass it without `&`
    error: a block can only be called or passed where it's written
    a block
    = a block lives only as long as the call it's passed to
    help: call it here, or pass it straight to a function
    |}]

let%expect_test "[g2] pipeline step cannot be raced from outside" =
  until "g2" ~says:[ "a pipeline isn't one operation and can't be raced"; "help: time a reader"; "Async.produce" ] (fun () ->
      compact (fun () -> check_error {|gen fn numbers() -> Int =
  yield 1
fn main() uses Console, Async, Clock =
  var r = numbers()
  let p = &r.map(fn(x) => x)
  print(attempt Async.timeout(Duration.ms(1), fn() => p()))
|}));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `map`
    help: its methods: `next`
    |}]

let%expect_test "[g2] pipeline cannot step its cursor concurrently" =
  until "g2" ~says:[ "`r`"; "several tasks at once"; "help:" ] (fun () ->
      compact (fun () -> check_error {|gen fn numbers() -> Int =
  yield 1
fn main() uses Console, Async =
  var r = numbers()
  let p = &r.map(fn(x) => x)
  Async.each([1, 2]) fn(_) => print(p())
|}));
  [%expect {|
    (until g2)
    error: `numbers.Cursor` has no method named `map`
    help: its methods: `next`
    |}]

let%expect_test "[g1] same-SCC row propagation sees indirect Console use" =
  compact (fun () -> check_error {|gen fn sneaky(n: Int) -> Int =
  if n > 0 then helper(n - 1)
  yield n
fn helper(n: Int) =
  if n > 0 then
    for x in sneaky(n - 1)
      print(x)
  else print("effect")
type Box<T> = { value: T }
fn main() =
  let saved = Box { value: sneaky(2) }
  ()
|});
  [%expect {|
    error: `sneaky(2)` uses `Console`, so its stream lives in this scope
    a block, which can't be stored
    = a generator that uses a dependency runs in its caller's frame
    help: to keep a position, keep a reader, which is data
    |}]


(* No queue implementation is simulated here. The owning step supplies an
   adapter to real sim/journal events; these checks then validate the same
   transfer trace before and after replay. A None adapter is an explicit skip. *)
module Queue_contract = struct
  type scenario =
    | Cancel_send_ready
    | Cancel_receive_ready
    | Close_full_with_waiters
    | Close_empty_with_waiters
    | Consumer_leaves_full_queue
    | Merge_failure_with_blocked_siblings

  type event =
    | Send_attempt of int
    | Send_committed of int
    | Send_cancelled_before_commit of int
    | Send_closed of int
    | Receive_attempt of int
    | Receive_committed of int * int
    | Receive_cancelled_before_commit of int
    | Receive_closed of int
    | Abandoned of int
    | Producer_started of int
    | Producer_ended of int
    | Producer_failure_recorded of int
    | Stream_failed of int
    | Call_returned

  type recording = { events : event list; journal : string }

  module type Adapter = sig
    (* Values and operation ids are unique within a run. These are actual
       queue commit/cleanup observations, not inferred from final output. *)
    val run : seed:int -> scenario -> recording
    val replay : journal:string -> event list
  end

  let adapter : (module Adapter) option = None

  let check scenario events =
    let sends = Hashtbl.create 16 and send_outcomes = Hashtbl.create 16 in
    let receives = Hashtbl.create 16 and receive_outcomes = Hashtbl.create 16 in
    let committed = Hashtbl.create 16 in
    let consumed = Hashtbl.create 16 and abandoned = Hashtbl.create 16 in
    let producers = Hashtbl.create 8 and ended = Hashtbl.create 8 in
    let first_failure = ref None and returned = ref false in
    let once table id =
      assert (not (Hashtbl.mem table id));
      Hashtbl.add table id ()
    in
    let outcome attempts outcomes id =
      assert (Hashtbl.mem attempts id);
      once outcomes id
    in
    let all_outcomes attempts outcomes =
      Hashtbl.iter (fun id () -> assert (Hashtbl.mem outcomes id)) attempts
    in
    List.iter
      (fun event ->
        assert (not !returned);
        match event with
        | Send_attempt id -> once sends id
        | Send_committed id ->
            outcome sends send_outcomes id;
            once committed id
        | Send_cancelled_before_commit id | Send_closed id ->
            outcome sends send_outcomes id;
            assert (not (Hashtbl.mem committed id))
        | Receive_attempt id -> once receives id
        | Receive_committed (id, token) ->
            outcome receives receive_outcomes id;
            assert (Hashtbl.mem committed token);
            assert (not (Hashtbl.mem abandoned token));
            once consumed token
        | Receive_cancelled_before_commit id | Receive_closed id ->
            outcome receives receive_outcomes id
        | Abandoned token ->
            assert (Hashtbl.mem committed token);
            assert (not (Hashtbl.mem consumed token));
            once abandoned token
        | Producer_started id -> once producers id
        | Producer_ended id ->
            assert (Hashtbl.mem producers id);
            once ended id
        | Producer_failure_recorded id ->
            assert (Hashtbl.mem producers id);
            if !first_failure = None then first_failure := Some id
        | Stream_failed id ->
            assert (!first_failure = Some id);
            (* Accepted values precede the source failure. A consumer that
               exits instead owns explicit Abandoned observations. *)
            Hashtbl.iter
              (fun token () -> assert (Hashtbl.mem consumed token)) committed
        | Call_returned ->
            all_outcomes sends send_outcomes;
            all_outcomes receives receive_outcomes;
            all_outcomes producers ended;
            Hashtbl.iter
              (fun token () ->
                assert (Hashtbl.mem consumed token <> Hashtbl.mem abandoned token))
              committed;
            returned := true)
      events;
    assert !returned;
    let has predicate = List.exists predicate events in
    (match scenario with
    | Cancel_send_ready ->
        assert (Hashtbl.length sends > 0);
        assert (has (function Send_committed _ | Send_cancelled_before_commit _ -> true | _ -> false))
    | Cancel_receive_ready ->
        assert (Hashtbl.length committed > 0);
        assert (Hashtbl.length receives > 0)
    | Close_full_with_waiters ->
        assert (Hashtbl.length sends >= 2);
        assert (Hashtbl.length committed > 0);
        assert (has (function Send_closed _ -> true | _ -> false));
        assert (Hashtbl.length consumed > 0)
    | Close_empty_with_waiters ->
        assert (Hashtbl.length receives >= 2);
        assert (has (function Receive_closed _ -> true | _ -> false))
    | Consumer_leaves_full_queue ->
        assert (Hashtbl.length producers > 0);
        assert (Hashtbl.length abandoned > 0)
    | Merge_failure_with_blocked_siblings ->
        assert (Hashtbl.length producers >= 2);
        assert (!first_failure <> None);
        assert (has (function Stream_failed _ -> true | _ -> false)))
end

let%expect_test "[g3] real queue admission, close and cancellation traces replay across seeds" =
  (match Queue_contract.adapter with
  | None -> print_endline "skipped until g3: real queue commit-event adapter"
  | Some (module Q) ->
      for seed = 0 to 999 do
        List.iter
          (fun scenario ->
            let run = Q.run ~seed scenario in
            Queue_contract.check scenario run.events;
            let replayed = Q.replay ~journal:run.journal in
            Queue_contract.check scenario replayed;
            assert (run.events = replayed))
          Queue_contract.
            [ Cancel_send_ready; Cancel_receive_ready; Close_full_with_waiters;
              Close_empty_with_waiters; Consumer_leaves_full_queue;
              Merge_failure_with_blocked_siblings ]
      done;
      print_endline "queue commits, cleanup and failure order replayed across 1000 seeds");
  [%expect {| skipped until g3: real queue commit-event adapter |}]
let%expect_test "[g1] cursor_eq_direct refuses derived cursor equality" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console =
  print(values(1) == values(1))
|});
  [%expect {|
    error: generator cursor `values.Cursor` has no equality
    = this uses `==` on the cursor position
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_eq_generic refuses derived cursor equality" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn same<T>(a: T, b: T) -> Bool = a == b
fn main() uses Console = print(same(values(1), values(1)))
|});
  [%expect {|
    error: generator cursor `values.Cursor` has no equality, which `same` needs
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_eq_container refuses derived cursor equality" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console = print([values(1)] == [values(1)])
|});
  [%expect {|
    error: `Array<values.Cursor>`, which contains generator cursor `values.Cursor`, has no equality
    = this uses `==` on the cursor position
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_hash_direct refuses derived cursor hash" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console = print(values(1).hash())
|});
  [%expect {|
    error: generator cursor `values.Cursor` has no hash, which `hash_of` needs
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_hash_generic refuses derived cursor hash" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn hash<T>(value: T) -> Int = value.hash()
fn main() uses Console = print(hash(values(1)))
|});
  [%expect {|
    error: generator cursor `values.Cursor` has no hash, which `hash` needs
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_hash_container refuses derived cursor hash" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console = print([values(1)].hash())
|});
  [%expect {|
    error: `Array<values.Cursor>`, which contains generator cursor `values.Cursor`, has no hash, which `hash_of` needs
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_ord_direct refuses derived cursor order" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console = print(values(1) < values(2))
|});
  [%expect {|
    error: `values.Cursor` has no `<`
    = generator cursor `values.Cursor` has no order
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_ord_generic refuses derived cursor order" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn before<T>(a: T, b: T) -> Bool = a < b
fn main() uses Console = print(before(values(1), values(2)))
|});
  [%expect {|
    error: `values.Cursor` has no `<`, which `before` needs
    = `before` uses `<` on its `T` (test.ren:4)
    = generator cursor `values.Cursor` has no order
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor_ord_container refuses derived cursor order" =
  compact (fun () -> check_error {|gen fn values(secret: Int) -> Int =
  yield secret

fn main() uses Console = print([values(2), values(1)].sort())
|});
  [%expect {|
    error: `values.Cursor` has no `<`, which `Array.sort` needs
    = `Array.sort` uses `<` on what it's given here
    = generator cursor `values.Cursor` has no order
    = or use `sort_by`, which sorts by what a function gives each
    help: compare the yielded data, or use a separate data key
    |}]

let%expect_test "[g1] cursor display is logical state without stepping or disclosing frame data" =
  compact (fun () -> run {|gen fn values(secret: Int) -> Int ! Bad(secret: Int) =
  yield secret
  fail Bad(secret)

gen fn one(secret: Int) -> Int =
  yield secret

fn main() uses Console =
  var a = values(12345)
  print(a)
  let _ = attempt &a.next()
  var copy = a
  print(a)
  let _ = attempt &a.next()
  print(a)
  print(copy)
  let _ = attempt &copy.next()
  print(copy)
  var returned = one(67890)
  print(returned)
  let _ = &returned.next()
  let _ = &returned.next()
  print(returned)
|});
  [%expect {|values.Cursor(<unstarted>)
values.Cursor(<suspended>)
values.Cursor(<failed>)
values.Cursor(<suspended>)
values.Cursor(<failed>)
one.Cursor(<unstarted>)
one.Cursor(<returned>)
()
|}]

(* An empty dependency row does not make abandonment invisible: this pure
   finalizer panics only when cancelled. Consumers can therefore observe
   cleanup scope and copy ownership without turning the generator into a
   dependency-using block. *)
let pure_cleanup =
  {|gen fn guarded_data() -> Int =
  finally(r) =>
    match r
      Err(Cancelled) =>
        let xs = [0]
        let _ = xs[5]
        try r
      _ => try r
  yield 1
  yield 2

|}

let%expect_test "[g1] copying a suspended pure cursor closes the fork even when never resumed" =
  compact (fun () -> run (pure_cleanup ^ {|fn main() uses Console, Async =
  var original = guarded_data()
  print(&original.next())
  print(attempt Async.isolate fn() =>
    let fork = original
    print("fork scope ends")
    ())
  print(&original.next())
  print(&original.next())
|}));
  [%expect {|Some(1)
fork scope ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
Some(2)
None
()
|}]

let%expect_test "[g1] read and generic parameters borrow existing cleanup tokens" =
  compact (fun () -> run (pure_cleanup ^ {|fn read(c: guarded_data.Cursor) -> Str = show(c)
fn generic<T>(value: T) -> Str = show(value)

fn main() uses Console, Async =
  var original = guarded_data()
  print(&original.next())
  print(attempt Async.isolate fn() =>
    print(read(original))
    print(generic(original))
    print("read calls returned"))
  print(&original.next())
  print(&original.next())
|}));
  [%expect {|Some(1)
guarded_data.Cursor(<suspended>)
guarded_data.Cursor(<suspended>)
read calls returned
Ok(())
Some(2)
None
()
|}]

let%expect_test "[g1] anonymous function results are adopted without a helper-scope close" =
  compact (fun () -> run (pure_cleanup ^ {|fn make() -> guarded_data.Cursor = guarded_data()

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var received = make()
    print("factory returned")
    print(&received.next())
    print(&received.next())
    print(&received.next()))
|}));
  [%expect {|factory returned
Some(1)
Some(2)
None
Ok(())
()
|}]

let%expect_test "[g1] returning a named suspended cursor closes the original in the callee" =
  compact (fun () -> run (pure_cleanup ^ {|fn make() -> guarded_data.Cursor =
  var local = guarded_data()
  let _ = &local.next()
  print("returning local")
  local

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    let received = make()
    print("unreached after callee close"))
|}));
  [%expect {|returning local
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] named generic opaque array and option copies close at their owner scope" =
  compact (fun () -> run (pure_cleanup ^ {|type Hidden<T> = opaque { value: T }
  pub fn of(value: T) -> Hidden<T> uses Console =
    print("hidden helper returns")
    Hidden { value }

type Box<T> = { value: T }
fn box<T>(value: T) -> Box<T> uses Console =
  print("box helper returns")
  Box { value }

fn main() uses Console, Async =
  var original = guarded_data()
  let _ = &original.next()
  print(attempt Async.isolate fn() =>
    let array = [Some(original)]
    let hidden = Hidden.of(array)
    let container = box(hidden)
    print("container adopted"))
  print(&original.next())
  print(&original.next())
|}));
  [%expect {|hidden helper returns
box helper returns
container adopted
Err(Panicked("index 5 is out of bounds for an array of length 1"))
Some(2)
None
()
|}]

let%expect_test "[g1] empty array roots keep their owner through generic inout helpers" =
  compact (fun () -> run (pure_cleanup ^ {|fn insert<T>(inout target: Array<T>, value: T) = &target.push(value)
fn relay<T>(inout target: Array<T>, value: T) = insert(&target, value)

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var roots: Array<guarded_data.Cursor> = []
    var original = guarded_data()
    let _ = &original.next()
    relay(&roots, original)
    print("array helper returned")
    let _ = &original.next()
    let _ = &original.next()
    print("array owner ends"))
|}));
  [%expect {|array helper returned
array owner ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] empty map roots keep their owner through generic inout helpers" =
  compact (fun () -> run (pure_cleanup ^ {|fn insert<T>(inout target: Map<Str, T>, value: T) = &target.set("entry", value)
fn relay<T>(inout target: Map<Str, T>, value: T) = insert(&target, value)

fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    var roots: Map<Str, guarded_data.Cursor> = Map.empty
    var original = guarded_data()
    let _ = &original.next()
    relay(&roots, original)
    print("map helper returned")
    let _ = &original.next()
    let _ = &original.next()
    print("map owner ends")
  print(result)
|}));
  [%expect {|map helper returned
map owner ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] replacement retires the displaced frame until its original scope ends" =
  compact (fun () -> run (pure_cleanup ^ {|fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var current = guarded_data()
    let _ = &current.next()
    current = guarded_data()
    print("replacement completed")
    print("binding scope ends"))
|}));
  [%expect {|replacement completed
binding scope ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] container removal retires leaves to the root owner rather than the helper" =
  compact (fun () -> run (pure_cleanup ^ {|fn clear<T>(inout target: Array<T>) = target = []

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var roots: Array<guarded_data.Cursor> = []
    var original = guarded_data()
    let _ = &original.next()
    &roots.push(original)
    let _ = &original.next()
    let _ = &original.next()
    clear(&roots)
    print("clear helper returned")
    print("root owner ends"))
|}));
  [%expect {|clear helper returned
root owner ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] stepping updates one token and leaves no abandoned prior positions" =
  compact (fun () -> run (pure_cleanup ^ {|fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var cursor = guarded_data()
    print(&cursor.next())
    print(&cursor.next())
    print(&cursor.next())
    print(&cursor.next())
    print("drained scope ends"))
|}));
  [%expect {|Some(1)
Some(2)
None
None
drained scope ends
Ok(())
()
|}]

let%expect_test "[g1] handler state owns inserted cursor leaves until its with ends" =
  compact (fun () -> run (pure_cleanup ^ {|dep Vault =
  put: fn(value: guarded_data.Cursor)

handler vault() for Vault =
  var saved: Option<guarded_data.Cursor> = None
  put(value) => saved = Some(value)

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var original = guarded_data()
    let _ = &original.next()
    with vault() in
      Vault.put(original)
      print("operation returned")
      let _ = &original.next()
      let _ = &original.next()
      print("with ends")
    print("unreached after with"))
|}));
  [%expect {|operation returned
with ends
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] a contained body panic wins over an abandonment cleanup panic" =
  compact (fun () -> run (pure_cleanup ^ {|fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    var cursor = guarded_data()
    let _ = &cursor.next()
    let body = [0]
    print(body[9]))
|}));
  [%expect {|Err(Panicked("index 9 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] data arguments evaluate once at creation even when copied and replayed" =
  compact (fun () -> run ({|gen fn values(n: Int) -> Int =
  yield n
  yield n + 1

fn argument() -> Int uses Console =
  print("argument evaluated")
  8

fn main() uses Console =
  var first = values(argument())
  var second = first
  print(&first.next())
  print(&second.next())
  print(&second.next())
  print(&first.next())
|}));
  [%expect {|argument evaluated
Some(8)
Some(8)
Some(9)
Some(9)
()
|}]

let%expect_test "[g1] dependency evidence comes from creation rather than the stepping with" =
  compact (fun () -> run ({|dep Value =
  get: fn() -> Int
handler value(n: Int) for Value =
  get() => n

gen fn values() -> Int uses Value =
  yield Value.get()
  yield Value.get()

fn main() uses Console =
  with value(1) in
    let cursor = values()
    with value(2) in
      print(cursor())
    print(cursor())
    print(cursor())
|}));
  [%expect {|Some(1)
Some(1)
None
()
|}]

let%expect_test "[g1] an Int return through a Unit with and loop keeps cancellation typed" =
  compact (fun () -> run {|
dep Guard =
  touch: fn()

handler guard() for Guard uses Console =
  finally(r) =>
    print(r)
    try r
  touch() => ()

fn choose() -> Int uses Console =
  for x in [1]
    with guard() in
      return 7
    print("unreached after return")
  99

fn main() uses Console = print(choose())
|});
  [%expect {|
    Err(Cancelled)
    7
    ()
    |}]

let%expect_test "[g1] anonymous read arguments close at caller statement end after all helpers return" =
  compact (fun () -> run (pure_cleanup ^ {|type Hidden<T> = opaque { value: T }
  pub fn of(value: T) -> Hidden<T> uses Console =
    print("hidden helper returns")
    Hidden { value }

type Box<T> = { value: T }
fn box<T>(value: T) -> Box<T> uses Console =
  print("box helper returns")
  Box { value }

fn main() uses Console, Async =
  var original = guarded_data()
  let _ = &original.next()
  print(attempt Async.isolate fn() =>
    print("before anonymous call")
    let container = box(Hidden.of([Some(original)]))
    print("unreached after temporary close"))
  print(&original.next())
  print(&original.next())
|}));
  [%expect {|before anonymous call
hidden helper returns
box helper returns
Err(Panicked("index 5 is out of bounds for an array of length 1"))
Some(2)
None
()
|}]

let%expect_test "[g1] a generator factory neither runs nor handles its body's first failure" =
  compact (fun () -> run {|
gen fn broken() -> Int ! Bad = fail Bad

fn main() uses Console =
  var cursor = broken()
  print("created")
  print(attempt &cursor.next())
  print(attempt &cursor.next())
|});
  [%expect {|created
Err(Bad)
Err(Bad)
()
|}]

let%expect_test "[g1] a generator declaration belongs at top level" =
  compact (fun () -> check_error {|
type Group = { n: Int }
  gen fn items(self) -> Int =
    yield self.n

fn main() = ()
|});
  [%expect {|
    error: a generator is a top-level function
    help: move this `gen fn` out of the type
    |}]

let imported_values =
  [ "main.ren", {|
import producer

type Saved = { cursor: producer.values.Cursor<Int> }

fn main() uses Console =
  var original = producer.values([10, 20])
  print(attempt &original.next())
  let saved = Saved { cursor: original }
  var copy = saved.cursor
  print(attempt &copy.next())
  print(attempt &original.next())
  print(attempt &original.next())
  print(attempt &copy.next())
  var empty: producer.values.Cursor<Int> = producer.values([])
  print(attempt &empty.next())
  print(attempt &empty.next())
|};
    "producer.ren", {|
pub gen fn values<T>(xs: Array<T>) -> T ! NoValue =
  if xs.len() == 0 then fail NoValue
  for x in xs
    yield x
|} ]

let%expect_test "[g1] imported generic cursors keep item and step errors behind user type arguments" =
  compact (fun () -> run_files imported_values);
  [%expect {|Ok(Some(10))
Ok(Some(20))
Ok(Some(20))
Ok(None)
Ok(None)
Err(NoValue)
Err(NoValue)
()
|}]

let%expect_test "[g1] imported generator signatures report items and step rows" =
  compact (fun () -> types_files imported_values);
  [%expect {|
    -- producer
    pub gen fn values<T>(xs: Array<T>) -> T ! NoValue

    -- main
    fn main() uses Console
    |}]

let%expect_test "[g1] an imported cursor exposes only its generator's user type parameter count" =
  compact (fun () -> check_error_files
      [ "main.ren", {|
import producer
fn consume(c: producer.values.Cursor<Int, Str>) = ()
fn main() = ()
|}; "producer.ren", {|
pub gen fn values<T>(xs: Array<T>) -> T =
  for x in xs
    yield x
|} ]);
  [%expect {|
    error: `producer.values.Cursor` takes 1 type argument but was given 2
    help: give `producer.values.Cursor` 1 type argument, matching its generator's declaration
    |}]

let%expect_test "[g1] an imported private producer does not export its cursor type" =
  compact (fun () -> check_error_files
      [ "main.ren", {|
import producer
fn consume(c: producer.secret.Cursor) = ()
fn main() = ()
|}; "producer.ren", {|
gen fn secret() -> Int = yield 1
pub fn visible() -> Int = 1
|} ]);
  [%expect {|
    error: `producer` has no public type `secret.Cursor`
    help: if it's defined there, mark it `pub`
    |}]

let%expect_test "[g1] an imported block generator captures its creation-site dependency" =
  compact (fun () -> run_files
    [ "main.ren", {|
import producer

handler value(n: Int) for producer.Value =
  get() => n

fn main() uses Console =
  with value(1) in
    let cursor = producer.values()
    with value(2) in
      print(cursor())
    print(cursor())
    print(cursor())
|}; "producer.ren", {|
pub dep Value =
  get: fn() -> Int

pub gen fn values() -> Int uses Value =
  yield Value.get()
  yield Value.get()
|} ]);
  [%expect {|Some(1)
Some(1)
None
()
|}]

let%expect_test "[g1] a paused internal with is not the consumer task context" =
  compact (fun () -> run {|
dep Value =
  get: fn() -> Int

handler value(n: Int) for Value =
  get() => n

gen fn held() -> Int =
  with value(2) in
    yield Value.get()
    yield Value.get()

fn main() uses Console, Async =
  with value(1) in
    let cursor = held()
    print(cursor())
    print(Async.both(fn() => Value.get(), fn() => Value.get()))
    with value(3) in
      print(cursor())
      print(Value.get())
    print(cursor())
    print(Value.get())
|});
  [%expect {|Some(2)
(1, 1)
Some(2)
3
None
1
()
|}]

let%expect_test "[g1] a projected inout argument freezes its index and refreshes the root at steps and cleanup" =
  compact (fun () -> run {|
gen fn bump(inout value: Int) -> Int =
  finally(r) =>
    value += 10
    try r
  value += 1
  yield value
  value += 2
  yield value

fn consume(inout values: Array<Int>) uses Console =
  var index = 0
  let cursor = bump(&values[index])
  index = 1
  print(cursor())
  print(values)
  values[0] = 20
  values[1] = 100
  print(cursor())
  print(values)
  values[0] = 30

fn main() uses Console =
  var values = [1, 10]
  consume(&values)
  print(values)
|});
  [%expect {|Some(2)
[2, 10]
Some(22)
[22, 100]
[40, 100]
()
|}]

let%expect_test "[g1] a with completed before yielding does not make the cursor a block" =
  compact (fun () -> run {|
dep Value =
  get: fn() -> Int

handler value() for Value =
  get() => 4

gen fn clean() -> Int =
  let n = with value() in Value.get()
  yield n

type Saved = { cursor: clean.Cursor }

fn main() uses Console =
  let saved = Saved { cursor: clean() }
  var cursor = saved.cursor
  print(&cursor.next())
  print(&cursor.next())
|});
  [%expect {|Some(4)
None
()
|}]

let%expect_test "[g1] closing an unstarted outer frame closes its captured data copies without running its body" =
  compact (fun () -> run (pure_cleanup ^ {|
gen fn holds(input: guarded_data.Cursor) -> Int =
  let forbidden = [0]
  let _ = forbidden[9]
  yield 99
  var cursor = input
  for x in &cursor
    yield x

fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    var original = guarded_data()
    let _ = &original.next()
    let outer = holds(original)
    let _ = &original.next()
    let _ = &original.next()
    print("outer body was never stepped")
  print(result)
|}));
  [%expect {|outer body was never stepped
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] discarding a yielded cursor closes the item at the step statement" =
  compact (fun () -> run (pure_cleanup ^ {|
gen fn emit() -> guarded_data.Cursor =
  var inner = guarded_data()
  let _ = &inner.next()
  yield inner

fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    var outer = emit()
    print("before discarded item")
    let _ = &outer.next()
    print("unreached after discarded item")
  print(result)
|}));
  [%expect {|before discarded item
Err(Panicked("index 5 is out of bounds for an array of length 1"))
()
|}]

let%expect_test "[g1] an unstarted projected frame never writes its saved leaf back" =
  compact (fun () -> run {|
gen fn change(inout value: Int) -> Int =
  finally(r) =>
    value += 100
    try r
  value += 1
  yield value

fn index() -> Int uses Console =
  print("index evaluated")
  0

fn make(inout values: Array<Int>) uses Console =
  let cursor = change(&values[index()])
  values[0] = 50
  print("bound without stepping")

fn main() uses Console =
  var values = [1]
  make(&values)
  print(values)
|});
  [%expect {|index evaluated
bound without stepping
[50]
()
|}]

let%expect_test "[g1] overlapping as-pattern binders own independent cursor positions" =
  compact (fun () -> run (pure_cleanup ^ {|
fn main() uses Console, Async =
  let result = attempt Async.isolate fn() =>
    let Some(first) as all = Some(guarded_data()) else fail Missing
    var left = first
    print(&left.next())
    let Some(other) = all else fail Missing
    var right = other
    print(&right.next())
    print(&left.next())
    print(&left.next())
    print(&right.next())
    print(&right.next())
    print("independent aliases finished")
  print(result)
|}));
  [%expect {|Some(1)
Some(1)
Some(2)
None
Some(2)
None
independent aliases finished
Ok(())
()
|}]

let%expect_test "[g1] specializing a pull consumer preserves an effectful generator's closed step row" =
  run {|
gen fn rows() -> Int uses Console =
  print("first step")
  yield 1

fn consume(src: fn() -> Option<Int>) -> Int =
  var total = 0
  for x in try src
    total += x
  total

fn main() uses Console = print(consume(rows()))
|};
  [%expect {|
    first step
    1
    ()
    |}]
