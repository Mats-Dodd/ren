(* The services stage (foundations.md, Staging, item 6; decisions 2, 7,
   10, 11 and 18; language.md §5, §8 and §11; streams.md, "Concurrency
   and time"): this file is the stage's specification, as test_tasks.ml
   was 11a's and test_data.ml the data stage's.

   Each test's name starts with a tag, `[sN accept]` or `[sN reject]`. N is
   the step of the services stage that lands it (compiler.md, "Services
   stage"):

     s1  the pipe, `x |> f(a)`, with `try` and `attempt` on each step, and
         `|>` and `.` continuing a line
     s2  wirings: `wiring name(params) provides Ds = items`, flattened
         where they're used
     s3  background work: the compile error for a task that reaches a
         handler installed inside its scope, `Async.beside` and
         `Async.background`
     s4  `release` on one call; decision 10's deadlock rules; `sim`'s fair
         choice among an instance's waiters; `Proc.run(kill:)`; a default
         that's a variant with no fields
     s5  pull arguments to `Async.each` and `Async.map`, channels as
         dependencies with `items()`, and `Async.produce` with `Send<T>`
     s6  `striped`, which replaces `sync.keyed`
     s7  `actors`, then `post`
     s8  the milestone: the document server in miniature (the whole one
         is bench/services/docs, bench/tasks.t)

   A test still to land runs through [until] (helpers.ml), which holds
   what the step makes of it: [want], the whole output of a program that
   runs, or [says], the lines an error or a panic has to hold, its
   headline and its help. Its [%expect] holds today's output after
   `(until sN)`. When the program prints what's wanted, the test fails
   until it's turned on: written plainly, with the target in its
   [%expect]. A test whose program works already is written plainly, and
   holds what the step mustn't change.

   A program run with [run] is `ren run`'s, on `Async.single()`, whose
   order is fixed, or on a `sim.scheduler(seed)` it installs itself. One
   run with [test] is `ren test`'s, on `sim`, and asserts only what holds
   under every schedule. *)

open Ren
open Helpers

(* A fresh folder, the current one while [f] runs, with [files] in it,
   for a test that records a journal (as test_journal.ml's). *)
let in_folder files f =
  let dir = Filename.temp_dir "ren_services" "" in
  List.iter
    (fun (name, text) ->
      Out_channel.with_open_bin (Filename.concat dir name) (fun oc ->
          output_string oc (clean text)))
    files;
  let old = Sys.getcwd () in
  Sys.chdir dir;
  Fun.protect ~finally:(fun () -> Sys.chdir old) f

let read path = In_channel.with_open_bin path In_channel.input_all
let sources f = try Some (read f) with Sys_error _ -> None

let show_error e =
  match Driver.render_error ~sources e with
  | Some msg -> print_string msg
  | None -> raise e

(* `ren run --record run.journal main.ren`, then the journal. *)
let record () =
  let out = open_out_bin "run.journal" in
  let j = Journal.recording ~file:"run.journal" ~out ~program:"main.ren" in
  (try ignore (Driver.run ~lint:true ~record:j ~file:"main.ren" (read "main.ren"))
   with e -> show_error e);
  close_out out;
  print_string (read "run.journal")

(* `ren replay` of the journal [file]. *)
let replay file =
  try
    let journal = Journal.load ~file (read file) in
    ignore (Driver.replay ~lint:true ~journal ~file:"main.ren" (read "main.ren"));
    Printf.printf "replayed %d calls\n" journal.made
  with e -> show_error e

(* [src] with every top-level type, dependency, handler, function and
   wiring made `pub`: a test sees what an importer sees (testing.md), so a
   program run by [test] makes what its tests use public. *)
let pub_all src =
  String.split_on_char '\n' src
  |> List.map (fun l ->
         if
           List.exists
             (fun p -> String.starts_with ~prefix:p l)
             [ "type "; "dep "; "handler "; "fn "; "wiring " ]
         then "pub " ^ l
         else l)
  |> String.concat "\n"

(* ---- s1: the pipe (language.md §8) ---- *)

let%expect_test "[s1 accept] `x |> f(a)` is `f(x, a)`, to each kind of target" =
  (* a function, an associated function, a function parameter and a
     block bound by `let`, each with and without arguments *)
  run
    {|
type Cart = { items: Array<Int> }
  pub fn of(xs: Array<Int>) -> Cart = Cart { items: xs }

fn total(c: Cart) -> Int =
  var t = 0
  for x in c.items
    t += x
  t

fn scaled(n: Int, by: Int) -> Int = n * by

fn apply(n: Int, f: fn(Int) -> Int) -> Int = n |> try f

fn main() uses Console =
  let double = fn(n: Int) => n * 2
  print([1, 2, 3] |> Cart.of |> total |> scaled(10) |> double)
  print(apply(5, fn(x) => x + 1))
|};
  [%expect {|
    120
    6
    ()
    |}]

let%expect_test "[s1 accept] a vertical chain with a `try` on each step that can fail" =
  (* language.md §8's shape: each line starting with `|>`, indented
     further, continues the one above, and each `try` covers its own step *)
  run
    {|
fn validate(xs: Array<Int>) -> Array<Int> ! Empty =
  if xs == [] then fail Empty
  xs

fn price(xs: Array<Int>, fee: Int) -> Int =
  var t = fee
  for x in xs
    t += x
  t

fn capped(n: Int) -> Int ! TooBig(n: Int) =
  if n > 100 then fail TooBig(n)
  n

fn checkout(xs: Array<Int>) -> Int ! Empty | TooBig(n: Int) =
  xs
    |> try validate
    |> price(1)
    |> try capped

fn main() uses Console =
  print(attempt checkout([5, 6]))
  print(attempt checkout([]))
  print(attempt checkout([500]))
|};
  [%expect {|
    Ok(12)
    Err(Empty)
    Err(TooBig(501))
    ()
    |}]

let%expect_test "[s1 accept] `try` and `attempt` on the head stop at `|>`" =
  (* `try load() |> price(1)` is `(try load()) |> price(1)`, and
     `attempt` likewise: each marks only its own step *)
  run
    {|
fn load(n: Int) -> Int ! Down =
  if n < 0 then fail Down
  n

fn price(n: Int, fee: Int) -> Int = n + fee

fn total() -> Int ! Down = try load(3) |> price(1)

fn main() uses Console =
  print(attempt total())
  print(attempt load(3) |> show |> fn_len)

fn fn_len(s: Str) -> Int = s.bytes().len()
|};
  [%expect {|
    Ok(4)
    5
    ()
    |}]

let%expect_test "[s1 accept] `orelse` follows a chain, and applies to its result" =
  run
    {|
fn first_over(xs: Array<Int>, n: Int) -> Option<Int> =
  var found: Option<Int> = None
  for x in xs
    if found == None && x > n then found = Some(x)
  found

fn main() uses Console =
  print([5, 20, 30] |> first_over(10) orelse 0)
  print([5] |> first_over(10) orelse 0)
|};
  [%expect {|
    20
    0
    ()
    |}]

let%expect_test "[s1 accept] a line starting with `.` continues the one above" =
  (* streams.md's addition to §8: one stage on a line *)
  run
    {|
fn main() uses Console =
  let xs = [1, 2, 3, 4]
  let evens = xs
    .select(fn(x) => x % 2 == 0)
  print(evens)
|};
  [%expect {|
    [2, 4]
    ()
    |}]

let%expect_test "[s1 accept] a statement that starts a line after a chain isn't swallowed" =
  (* a line at the block's own indent, or one starting with a name, is a
     statement of its own: only `|>` and `.` indented further continue *)
  run
    {|
fn inc(n: Int) -> Int = n + 1

fn main() uses Console =
  let a = 1
    |> inc
    |> inc
  print(a)
  print(a |> inc)
|};
  [%expect {|
    3
    4
    ()
    |}]

let%expect_test "[s1 accept] a trailing block in the chain's last step" =
  (* decided after the draft: a trailing block only in the last link *)
  run
    {|
fn each_doubled(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> = try xs.map(f)

fn main() uses Console =
  print([1, 2, 3] |> each_doubled fn(x) => x * 2)
|};
  [%expect {|
    [2, 4, 6]
    ()
    |}]

let%expect_test "[s1 accept] the pipe in the end-to-end program's shape" =
  (* language.md's "A program, end to end", its checkout as a chain *)
  run
    {|
type Discount =
  | NoDiscount
  | Flat(off: Int)
  | OverAmount { min: Int, off: Int }

  pub fn apply(self, m: Int) -> Int =
    match self
      NoDiscount => m
      Flat(off) => m - off
      OverAmount { min, off } => if m < min then m else m - off

type Cart = | Empty_cart | Open { lines: Array<Int> }
type Priced = { total: Int }
type Receipt = { total: Int }

dep Discounts =
  for_customer: fn(c: Int) -> Discount

dep Orders =
  save: fn(p: Priced) -> Int ! DbDown

fn validate(cart: Cart) -> Array<Int> ! Empty =
  let Open { lines } = cart else fail Empty
  lines

fn price(lines: Array<Int>, d: Discount) -> Priced =
  var t = 0
  for l in lines
    t += l
  Priced { total: d.apply(t) }

fn place(p: Priced) -> Receipt ! DbDown uses Orders =
  let _ = try Orders.save(p)
  Receipt { total: p.total }

fn checkout(c: Int, cart: Cart) -> Receipt ! Empty | DbDown uses Orders, Discounts =
  cart
    |> try validate
    |> price(Discounts.for_customer(c))
    |> try place

handler fixed(d: Discount) for Discounts =
  for_customer(_) => d

handler mem_orders() for Orders =
  save(_) => 1

fn main() uses Console =
  with mem_orders(), fixed(Flat(5)) in
    print(attempt checkout(1, Open { lines: [10, 10] }))
    print(attempt checkout(1, Empty_cart))
|};
  [%expect {|
    Ok(Receipt { total: 15 })
    Err(Empty)
    ()
    |}]

let%expect_test "[s1 reject] a step that can fail without its own `try`" =
  check_error
    {|
fn validate(n: Int) -> Int ! Bad = if n < 0 then fail Bad else n
fn main() -> Int ! Bad = 1 |> validate
|};
  [%expect {|
    error: `fn main` says it can fail with `Bad`, but nothing in it can
      ┌─ test.ren:2:20
    2 │ fn main() -> Int ! Bad = 1 |> validate
      │                    ^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Bad` from after `!`

    error: `validate` can fail, and nothing handles it
      ┌─ test.ren:2:31
    2 │ fn main() -> Int ! Bad = 1 |> validate
      │                               ^^^^^^^^
      │                               -------- it can fail with `Bad`
      = in a chain each step that can fail carries its own `try`
      help: write `|> try validate`, or handle it with `match`
    |}]

let%expect_test "[s1 reject] a step that can fail, inside `attempt (...)`, still needs its `try`" =
  check_error
    {|
fn validate(n: Int) -> Int ! Bad = if n < 0 then fail Bad else n
fn inc(n: Int) -> Int = n + 1
fn main() uses Console = print(attempt (1 |> validate |> inc))
|};
  [%expect {|
    error: nothing here can fail
      ┌─ test.ren:3:32
    3 │ fn main() uses Console = print(attempt (1 |> validate |> inc))
      │                                ^^^^^^^
      = `attempt` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `attempt`

    error: `validate` can fail, and nothing handles it
      ┌─ test.ren:3:46
    3 │ fn main() uses Console = print(attempt (1 |> validate |> inc))
      │                                              ^^^^^^^^
      │                                              -------- it can fail with `Bad`
      = in a chain each step that can fail carries its own `try`
      help: write `|> try validate`, or handle it with `match`
    |}]

let%expect_test "[s1 reject] a `try` on a step that can't fail" =
  check_error
    {|
fn price(n: Int) -> Int = n + 1
fn main() -> Int = 1 |> try price
|};
  [%expect {|
    error: nothing here can fail
      ┌─ test.ren:2:25
    2 │ fn main() -> Int = 1 |> try price
      │                         ^^^
      = `try` marks the calls that can fail, so a reader can see where the code can stop
      help: remove the `try`
    |}]

let%expect_test "[s1 reject] `try` on the head covers only the head" =
  check_error
    {|
fn validate(n: Int) -> Int ! Bad = if n < 0 then fail Bad else n
fn place(n: Int) -> Int ! Down = if n < 0 then fail Down else n
fn main() -> Int ! Bad | Down =
  let order = 1
  try order |> validate |> place
|};
  [%expect {|
    error: `fn main` says it can fail with `Bad`, but nothing in it can
      ┌─ test.ren:3:20
    3 │ fn main() -> Int ! Bad | Down =
      │                    ^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Bad` from after `!`

    error: `fn main` says it can fail with `Down`, but nothing in it can
      ┌─ test.ren:3:26
    3 │ fn main() -> Int ! Bad | Down =
      │                          ^^^^
      = a signature lists exactly what a function can fail with, so its callers handle nothing that can't happen
      help: remove `Down` from after `!`

    error: `try` stops at `|>`
      ┌─ test.ren:5:3
    5 │   try order |> validate |> place
      │   ^^^
      = it covers only `order`, which can't fail; each step is marked on its own
      help: `order |> try validate |> try place`

    error: `validate` can fail, and nothing handles it
      ┌─ test.ren:5:16
    5 │   try order |> validate |> place
      │                ^^^^^^^^
      │                -------- it can fail with `Bad`
      = in a chain each step that can fail carries its own `try`
      help: write `|> try validate`, or handle it with `match`

    error: `place` can fail, and nothing handles it
      ┌─ test.ren:5:28
    5 │   try order |> validate |> place
      │                            ^^^^^
      │                            ----- it can fail with `Down`
      = in a chain each step that can fail carries its own `try`
      help: write `|> try place`, or handle it with `match`
    |}]

let%expect_test "[s1 reject] `|>` into the subject's own method" =
  check_error
    {|
fn main() -> Int = [1, 2] |> Array.len
|};
  [%expect {|
    error: `len` is `Array`'s own method, so it's called with `.`
      ┌─ test.ren:1:30
    1 │ fn main() -> Int = [1, 2] |> Array.len
      │                              ^^^^^^^^^
      help: write `(...).len()`, or end the chain with a `let`
    |}]

let%expect_test "[s1 reject] the subject goes first, and the step takes it second" =
  check_error
    {|
type Order = { total: Int }
type Rules = { off: Int }
fn apply(o: Order, r: Rules) -> Int = o.total - r.off
fn main() -> Int =
  let order = Order { total: 5 }
  let rules = Rules { off: 1 }
  rules |> apply(order)
|};
  [%expect {|
    error: `|>` puts `rules` first, but `apply` takes an `Order` there
      ┌─ test.ren:7:12
    7 │   rules |> apply(order)
      │            ^^^^^
      │   ----- `rules` is a `Rules`, which `apply` takes second
      = `|>` always passes its value as the first argument
      help: call it directly: `apply(order, rules)`

    error: expected `Rules`, found `Order`
      ┌─ test.ren:7:18
    7 │   rules |> apply(order)
      │                  ^^^^^
    |}]

let%expect_test "[s1 reject] a mismatched subject that the step doesn't take anywhere" =
  (* the "takes second" line only when another parameter's type matches *)
  check_error
    {|
fn twice(s: Str) -> Str = s.concat(s)
fn main() -> Str =
  let n = 3
  n |> twice
|};
  [%expect {|
    error: `|>` puts `n` first, but `twice` takes a `Str` there
      ┌─ test.ren:4:8
    4 │   n |> twice
      │        ^^^^^
      = `|>` always passes its value as the first argument
      help: call it directly: `twice(...)`
    |}]

let%expect_test "[s1 reject] `&` on the subject" =
  check_error
    {|
fn add(inout cart: Array<Int>, item: Int) = &cart.push(item)
fn main() =
  var cart: Array<Int> = []
  let item = 1
  &cart |> add(item)
|};
  [%expect {|
    error: `|>` passes a value, so nothing in a chain can change it
      ┌─ test.ren:5:3
    5 │   &cart |> add(item)
      │   ^
      help: call it with `&` directly: `add(&cart, item)`
    |}]

let%expect_test "[s1 reject] `&` on a step" =
  check_error
    {|
fn add(inout cart: Array<Int>, item: Int) = &cart.push(item)
fn main() =
  var cart: Array<Int> = []
  cart |> &add(1)
|};
  [%expect {|
    error: `|>` passes a value, so nothing in a chain can change it
      ┌─ test.ren:4:11
    4 │   cart |> &add(1)
      │           ^
      help: call it with `&` directly: `add(&cart, 1)`
    |}]

let%expect_test "[s1 reject] a block as a step" =
  check_error
    {|
fn main() -> Int = 1 |> fn(o) => o + 1
|};
  [%expect {|
    error: a step is a function by name, not a block
      ┌─ test.ren:1:25
    1 │ fn main() -> Int = 1 |> fn(o) => o + 1
      │                         ^^
      help: name it first, `let apply_rules = fn(o) => ...`, then `|> apply_rules`
    |}]

let%expect_test "[s1 reject] a binary operation on the left of `|>`" =
  check_error
    {|
fn round(n: Int) -> Int = n
fn main() -> Int =
  let total = 1
  let fee = 2
  total + fee |> round
|};
  [%expect {|
    error: `|>` takes one value on its left
      ┌─ test.ren:5:3
    5 │   total + fee |> round
      │   ^^^^^^^^^^^
      help: put it in parentheses: `(total + fee) |> round`
    |}]

let%expect_test "[s1 reject] an operator after a chain" =
  check_error
    {|
fn price(n: Int) -> Int = n
fn main() -> Bool =
  let order = 1
  let expected = 1
  order |> price == expected
|};
  [%expect {|
    error: a chain ends its expression
      ┌─ test.ren:5:18
    5 │   order |> price == expected
      │                  ^^
      help: put the chain in parentheses, or name it with `let`
    |}]

let%expect_test "[s1 reject] a trailing block on a step that isn't the last" =
  check_error
    {|
fn each(xs: Array<Int>, f: fn(Int) -> Int) -> Array<Int> = try xs.map(f)
fn count(xs: Array<Int>) -> Int = xs.len()
fn main() -> Int = [1] |> each fn(x) => x |> count
|};
  [%expect {|
    error: only the chain's last step can take a block
      ┌─ test.ren:3:41
    3 │ fn main() -> Int = [1] |> each fn(x) => x |> count
      │                                         ^^^^^^^^^^
      help: name the block first, `let f = fn(x) => ...`, and pass it in the parentheses
    |}]

let%expect_test "[s1 reject] a field of a value as a step" =
  (* a step is a function, a module's or a type's: the parser can't tell
     `o.f` from `m.f`, so Resolve says it *)
  check_error
    {|
type Rules = { apply: Int }
fn main() -> Int =
  let rules = Rules { apply: 1 }
  2 |> rules.apply
|};
  [%expect {|
    error: a step is a function by name, and `rules.apply` is a field of `rules`
      ┌─ test.ren:4:8
    4 │   2 |> rules.apply
      │        ^^^^^^^^^^^
      help: name it first: `let apply = rules.apply`, then `|> apply`
    |}]

(* ---- s2: wirings (language.md §5) ---- *)

let users_deps =
  {|
dep Db =
  get: fn(id: Int) -> Str ! DbDown
dep Audit =
  note: fn(s: Str)
dep Users =
  name: fn(id: Int) -> Str ! DbDown

handler mem_db() for Db =
  get(id) => "ann".concat(show(id))

handler pg_db(url: Str) for Db uses Console =
  get(id) =>
    print("pg ".concat(url))
    "pg".concat(show(id))

handler console_audit() for Audit uses Console =
  note(s) => print("audit: ".concat(s))

handler db_users() for Users uses Db, Audit =
  name(id) =>
    Audit.note(show(id))
    try Db.get(id)
|}

let%expect_test "[s2 accept] a wiring is flattened where it's used" =
  (* `live` names three handlers; the body sees only `Users` *)
  until "s2"
    ~want:{|
audit: 7
pg main
Ok("pg7")
()
|}
    (fun () ->
      run
        (users_deps
       ^ {|
wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()

fn main() uses Console =
  with live("main") in print(attempt Users.name(7))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] an item beside a wiring meets what the wiring installs" =
  (* one set, one instance of each: `counted()` shares `live`'s `Db` *)
  until "s2"
    ~want:{|
counted 1
Ok("ann1")
()
|}
    (fun () ->
      run
        (users_deps
       ^ {|
dep Count =
  hit: fn() -> Str ! DbDown

handler counted() for Count uses Db, Console =
  var n = 0
  hit() =>
    n += 1
    print("counted ".concat(show(n)))
    try Db.get(n)

wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with live, counted() in print(attempt Count.hit())
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:34:1
    34 │ wiring live provides Users = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] wirings combine and nest, and a test splits one" =
  (* language.md §5's "Tests: split the wiring, don't patch it": `core`
     needs `Db`; `live` adds the real one, a test a memory one. A test
     sees what an importer sees, so `core` is `pub` here, its needs
     written *)
  until "s2"
    ~want:{|
test.ren
  ✓ a lookup is audited

1 passed
[exit 0]
|}
    (fun () ->
      test
        (pub_all
         (users_deps
       ^ {|
wiring core provides Users uses Db, Console = console_audit(), db_users()
wiring live(url: Str) provides Users uses Console = core, pg_db(url)

pub fn main() uses Console =
  with live("main") in print(attempt Users.name(1))

test "a lookup is audited" =
  with core, mem_db() in
    assert try Users.name(2) == "ann2"
|})));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:5
    24 │ pub wiring core provides Users uses Db, Console = console_audit(), db_users()
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)

    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:25:5
    25 │ pub wiring live(url: Str) provides Users uses Console = core, pg_db(url)
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] a wiring's parameter can be a description" =
  (* functor-style: `app(db: Db)` installs the `Db` it's given *)
  until "s2"
    ~want:{|
audit: 3
Ok("ann3")
()
|}
    (fun () ->
      run
        (users_deps
       ^ {|
wiring app(db: Db) provides Users = db, console_audit(), db_users()

fn main() uses Console =
  with app(mem_db()) in print(attempt Users.name(3))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring app(db: Db) provides Users = db, console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] a wiring fails to start with its items' errors, installed with `try with`" =
  until "s2"
    ~want:{|
Err(DbDown)
()
|}
    (fun () ->
      run
        (users_deps
       ^ {|
handler down_db() for Db =
  let n = try refuse()
  get(id) => show(n)

fn refuse() -> Int ! DbDown = fail DbDown

wiring live provides Users = down_db(), console_audit(), db_users()

fn go() ! DbDown uses Console =
  try with live in print(try Users.name(1))

fn main() uses Console = print(attempt go())
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:30:1
    30 │ wiring live provides Users = down_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] teardown runs `finally` in reverse install order" =
  until "s2"
    ~want:{|
in body
users done
db done
audit done
()
|}
    (fun () ->
      run
        {|
dep Db =
  get: fn() -> Int
dep Audit =
  note: fn()
dep Users =
  one: fn() -> Int

handler db() for Db uses Console =
  finally(r) =>
    print("db done")
    try r
  get() => 1
handler audit() for Audit uses Console =
  finally(r) =>
    print("audit done")
    try r
  note() => ()
handler users() for Users uses Db, Audit, Console =
  finally(r) =>
    print("users done")
    try r
  one() =>
    Audit.note()
    Db.get()

wiring live provides Users = users(), audit(), db()

fn main() uses Console =
  with live in
    print("in body")
|});
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:26:1
    26 │ wiring live provides Users = users(), audit(), db()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] a plain `with` still exposes everything it installs" =
  until "s2"
    ~want:{|
Ok("ann5")
()
|}
    (fun () ->
      run
        (users_deps
       ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with mem_db() in print(attempt Db.get(5))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] a private wiring's `uses` and `!` are inferred, a `pub` one's written" =
  until "s2" ~checks:true
    ~says:[ "wiring live(url: Str) provides Users uses Console"; "pub wiring core provides Users uses Db" ]
    (fun () ->
      types
        (users_deps
       ^ {|
pub wiring core provides Users uses Db = console_audit(), db_users()
wiring live(url: Str) provides Users = core, pg_db(url)
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:5
    24 │ pub wiring core provides Users uses Db = console_audit(), db_users()
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)

    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:25:1
    25 │ wiring live(url: Str) provides Users = core, pg_db(url)
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 accept] a pub wiring used from another module" =
  until "s2"
    ~want:{|
audit: 4
Ok("ann4")
()
|}
    (fun () ->
      run_files
        [
          ( "main.ren",
            {|
import app

fn main() uses Console =
  with app.live in print(attempt app.Users.name(4))
|} );
          ( "app.ren",
            users_deps
            ^ {|
pub wiring live provides Users uses Console = mem_db(), console_audit(), db_users()
|} );
        ]);
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ app.ren:24:5
    24 │ pub wiring live provides Users uses Console = mem_db(), console_audit(), db_users()
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a missing need" =
  until "s2"
    ~says:
      [
        "error: nothing installs `Db`, which `db_users()` in `live` needs";
        "help: add an item that installs `Db` beside `live`: `with live, mem_db() in`";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live provides Users = console_audit(), db_users()

fn main() uses Console =
  with live in print(attempt Users.name(1))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users = console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a pub wiring's need it doesn't declare" =
  until "s2"
    ~says:
      [
        "error: `live` needs `Db`, which it doesn't declare";
        "help: add it to `uses`: `uses Db`";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
pub wiring live provides Users = console_audit(), db_users()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:5
    24 │ pub wiring live provides Users = console_audit(), db_users()
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a hidden service used" =
  until "s2"
    ~says:
      [
        "error: `live` installs `Db` but doesn't provide it";
        "help: add `Db` to `live`'s `provides`, or install your own inside: `with mem_db() in`";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with live in print(attempt Db.get(1))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a duplicate through flattening" =
  until "s2"
    ~says:
      [
        "error: this `with` installs `Db` twice: `mem_db()` here, and `pg_db(url)` in `live`";
        "help: use a smaller wiring that leaves `Db` out, or remove one";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()

fn main() uses Console =
  with live("x"), mem_db() in print(attempt Users.name(1))
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a cycle through wirings" =
  until "s2"
    ~says:[ "error: `a` lists itself: a → b → a" ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring a provides Users = b, db_users()
wiring b provides Audit = a, console_audit()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring a provides Users = b, db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)

    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:25:1
    25 │ wiring b provides Audit = a, console_audit()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a cycle among the items a wiring flattens" =
  until "s2"
    ~says:
      [
        "error: `ping()` and `pong()` in `both` each need what the other installs";
        "`ping()` → `pong()` → `ping()`";
      ]
    (fun () ->
      check_error
        {|
dep Ping =
  ping: fn()
dep Pong =
  pong: fn()
handler ping() for Ping uses Pong =
  ping() => Pong.pong()
handler pong() for Pong uses Ping =
  pong() => Ping.ping()
wiring both provides Ping = ping(), pong()
fn main() = with both in Ping.ping()
|});
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
      ┌─ test.ren:9:1
    9 │ wiring both provides Ping = ping(), pong()
      │ ^^^^^^
      help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] `provides` names what nothing installs" =
  until "s2"
    ~says:[ "error: `live` provides `Clock`, which nothing in it installs" ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live provides Users, Clock = mem_db(), console_audit(), db_users()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users, Clock = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] an item nothing uses" =
  until "s2"
    ~says:[ "error: `console_audit()` in `live` provides `Audit`, which nothing needs" ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
handler plain_users() for Users uses Db =
  name(id) => try Db.get(id)
wiring live provides Users = mem_db(), console_audit(), plain_users()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:26:1
    26 │ wiring live provides Users = mem_db(), console_audit(), plain_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a wiring used as a value" =
  until "s2"
    ~says:
      [ "error: a wiring isn't a value"; "help: install it: `with live in ...`" ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()
fn main() =
  let w = live
  1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a wiring with no `provides`" =
  until "s2"
    ~says:
      [
        "error: a wiring says what it provides";
        "help: write `provides` and the dependencies the body may call";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live = mem_db(), console_audit(), db_users()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live = mem_db(), console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] a wiring's body is items only" =
  until "s2"
    ~says:
      [
        "error: a wiring's body lists what it installs";
        "help: code that runs around a block stays a function: `fn live(body: fn() -> T) -> T`";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring live provides Users =
  print("starting")
  mem_db()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring live provides Users =
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

let%expect_test "[s2 reject] `provides` names what a nested wiring hides" =
  until "s2"
    ~says:
      [
        "error: `core` installs `Audit` but doesn't provide it";
        "help: add `Audit` to `core`'s `provides`";
      ]
    (fun () ->
      check_error
        (users_deps
       ^ {|
wiring core provides Users = console_audit(), db_users()
wiring live provides Users, Audit = core, mem_db()
fn main() = 1
|}));
  [%expect {|
    (until s2)
    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:24:1
    24 │ wiring core provides Users = console_audit(), db_users()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)

    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:25:1
    25 │ wiring live provides Users, Audit = core, mem_db()
       │ ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)
    |}]

(* ---- s3: background work (decision 7) ---- *)

let ticks_dep =
  {|
dep Ticks =
  tick: fn()

handler ticks() for Ticks uses Console =
  var n = 0
  finally(r) =>
    print("ticks: ".concat(show(n)))
    try r
  tick() => n += 1
|}

let%expect_test "[s3 reject] a task that reaches a handler installed inside its scope" =
  (* what 11a cancelled when the `with`'s body ended is a compile error
     now, whose help opens the scope inside the `with` *)
  until "s3"
    ~says:
      [
        "error: this task can reach `Ticks`, installed inside the scope it's spawned into";
        "help: open the scope inside the `with`: `with ticks() in Async.scope fn(s) => ...`, or run it beside the body with `Async.beside`";
      ]
    (fun () ->
      check_error
        (ticks_dep
       ^ {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    with ticks() in
      s.spawn fn() => Ticks.tick()
|}));
  [%expect {|
    (until s3)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s3 reject] a helper hides which scope is inner: the run time's check" =
  (* `start` is handed the scope from outside the `with`, which only the
     run time can see: a panic at the spawn *)
  until "s3"
    ~says:
      [
        "panic: this task can reach `Ticks`, installed inside the scope it's spawned into";
        "help: open the scope inside the `with`";
      ]
    (fun () ->
      run_error
        (ticks_dep
       ^ {|
fn start(s: Scope) uses Ticks, Async =
  s.spawn fn() => Ticks.tick()

fn main() uses Console, Async =
  Async.scope fn(s) =>
    with ticks() in
      start(s)
|}));
  [%expect {|
    (until s3)
    ticks: 0
    ()
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

let%expect_test "[s3 accept] `Async.beside` cancels its task when the body ends, before the `finally`" =
  until "s3"
    ~want:{|
ticks: 3
after
()
|}
    (fun () ->
      run
        ("import sim\n" ^ ticks_dep
       ^ {|

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      ticking()

fn ticking() uses Console, Async, Clock =
  with ticks() in
    Async.beside(fn() => tick_forever()) fn() =>
      Clock.sleep(Duration.ms(350))
  print("after")

fn tick_forever() uses Ticks, Clock =
  while true
    Clock.sleep(Duration.ms(100))
    Ticks.tick()
|}));
  [%expect {|
    (until s3)
    error: `Async` has no operation or member named `beside`
       ┌─ test.ren:21:11
    21 │     Async.beside(fn() => tick_forever()) fn() =>
       │           ^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s3 accept] a pool's order: the work drains, the background stops, then `finally`" =
  (* decision 7: `with pool() in Async.beside(health) fn() =>
     Async.scope ...` *)
  until "s3"
    ~want:{|
work done
health stopped
pool closed
()
|}
    (fun () ->
      run
        {|
import sim

dep Pool =
  use: fn()
  check: fn()

handler pool() for Pool uses Console =
  finally(r) =>
    print("pool closed")
    try r
  use() => ()
  check() => ()

dep Probe =
  probe: fn()

handler probe() for Probe uses Pool, Console =
  finally(_) => print("health stopped")
  probe() => Pool.check()

fn health() uses Pool, Clock, Console =
  with probe() in
    while true
      Clock.sleep(Duration.ms(10))
      Probe.probe()

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      with pool() in
        Async.beside(fn() => health()) fn() =>
          Async.scope fn(s) =>
            for i in 0..3
              s.spawn fn() =>
                Clock.sleep(Duration.ms(25))
                Pool.use()
          print("work done")
|});
  [%expect {|
    (until s3)
    error: `Async` has no operation or member named `beside`
       ┌─ test.ren:31:15
    31 │         Async.beside(fn() => health()) fn() =>
       │               ^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s3 accept] a background failure cancels the body and is its error" =
  until "s3"
    ~want:{|
body cancelled
Err(LeaseLost)
()
|}
    (fun () ->
      run
        {|
import sim

fn keep_lease() ! LeaseLost uses Clock =
  Clock.sleep(Duration.ms(50))
  fail LeaseLost

dep Watch =
  wait: fn()

handler watch() for Watch uses Clock, Console =
  finally(r) =>
    match r
      Err(Cancelled) => print("body cancelled")
      _ => print("body done")
    try r
  wait() => Clock.sleep(Duration.seconds(10))

fn work() uses Clock, Console =
  with watch() in Watch.wait()

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      print(attempt Async.beside(fn() => try keep_lease()) fn() => work())
|});
  [%expect {|
    (until s3)
    error: `Async` has no operation or member named `beside`
       ┌─ test.ren:24:27
    24 │       print(attempt Async.beside(fn() => try keep_lease()) fn() => work())
       │                           ^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s3 accept] `Async.background`: tasks spawned as the body goes, stopped when it ends" =
  until "s3"
    ~want:{|
body done
ticks: 2
()
|}
    (fun () ->
      run
        ("import sim\n" ^ ticks_dep
       ^ {|

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      with ticks() in
        Async.background fn(bg) =>
          bg.spawn fn() => every(Duration.ms(100))
          bg.spawn fn() => every(Duration.ms(150))
          Clock.sleep(Duration.ms(160))
          print("body done")

fn every(d: Duration) uses Ticks, Clock =
  while true
    Clock.sleep(d)
    Ticks.tick()
|}));
  [%expect {|
    (until s3)
    error: `Async` has no operation or member named `background`
       ┌─ test.ren:18:15
    18 │         Async.background fn(bg) =>
       │               ^^^^^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s3 accept] `Async.background`'s first failure cancels the body" =
  until "s3"
    ~want:{|
Err(Gone)
()
|}
    (fun () ->
      run
        {|
import sim

fn fails_later() ! Gone uses Clock =
  Clock.sleep(Duration.ms(10))
  fail Gone

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      print(attempt Async.background fn(bg) =>
        bg.spawn fn() => try fails_later()
        Clock.sleep(Duration.seconds(5)))
|});
  [%expect {|
    (until s3)
    error: `Async` has no operation or member named `background`
       ┌─ test.ren:10:27
    10 │       print(attempt Async.background fn(bg) =>
       │                           ^^^^^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s3 accept] a scope opened inside the `with` waits for its tasks, as before" =
  (* what the compile error's help says to write; it runs already *)
  run
    (ticks_dep
   ^ {|
fn main() uses Console, Async =
  with ticks() in
    Async.scope fn(s) =>
      s.spawn fn() => Ticks.tick()
      s.spawn fn() => Ticks.tick()
|});
  [%expect {|
    ticks: 2
    ()
    |}]

(* ---- s4: `release`, deadlocks, `sim`'s fair choice, `Proc.run(kill:)` ---- *)

let%expect_test "[s4 accept] `release` with no other task is a plain call" =
  until "s4"
    ~want:{|
1
2
()
|}
    (fun () ->
      run
        {|
dep Next =
  get: fn(id: Int) -> Int
dep Breaker =
  call: fn(id: Int) -> Int

handler next() for Next =
  get(id) => id

handler breaker() for Breaker uses Next =
  var calls = 0
  call(id) =>
    calls += 1
    let v = release Next.get(id)
    v + calls - 1

fn main() uses Console =
  with next(), breaker() in
    print(Breaker.call(1))
    print(Breaker.call(1))
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Next`
       ┌─ test.ren:13:21
    13 │     let v = release Next.get(id)
       │                     ^^^^
    |}]

let%expect_test "[s4 accept] `release` lets other callers in while the call runs" =
  (* the slow call is in `Next.get`, released: the second caller's
     operation runs meanwhile, which it couldn't without `release` *)
  until "s4"
    ~want:{|
fast 2
slow 1
()
|}
    (fun () ->
      run
        {|
dep Next =
  get: fn(id: Int) -> Int
dep Front =
  ask: fn(id: Int) -> Int

handler next() for Next uses Clock =
  get(id) =>
    if id == 1 then Clock.sleep(Duration.ms(100))
    id

handler front() for Front uses Next =
  var asked = 0
  ask(id) =>
    asked += 1
    release Next.get(id)

fn main() uses Console, Async =
  with next(), front() in
    Async.scope fn(s) =>
      s.spawn fn() => print("slow ".concat(show(Front.ask(1))))
      s.spawn fn() => print("fast ".concat(show(Front.ask(2))))
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Next`
       ┌─ test.ren:15:13
    15 │     release Next.get(id)
       │             ^^^^
    |}]

let%expect_test "[s4 accept] state written before a `release` and read after it is the cells'" =
  (* the arm's copies are written back before the call and read again
     after, as `Async.until`'s are: the other caller's change is seen *)
  until "s4"
    ~want:{|
2
()
|}
    (fun () ->
      run
        {|
dep Next =
  get: fn(id: Int) -> Int
dep Front =
  ask: fn(id: Int) -> Int

handler next() for Next uses Clock =
  get(id) =>
    Clock.sleep(Duration.ms(id))
    id

handler front() for Front uses Next =
  var asked = 0
  ask(id) =>
    asked += 1
    let _ = release Next.get(id)
    asked

fn main() uses Console, Async =
  with next(), front() in
    Async.scope fn(s) =>
      s.spawn fn() => print(Front.ask(100))
      s.spawn fn() => Front.ask(1)
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Next`
       ┌─ test.ren:15:21
    15 │     let _ = release Next.get(id)
       │                     ^^^^
    |}]

let%expect_test "[s4 accept] `try release` on a call that can fail" =
  until "s4"
    ~want:{|
Err(Down)
()
|}
    (fun () ->
      run
        {|
dep Next =
  get: fn(id: Int) -> Int ! Down
dep Front =
  ask: fn(id: Int) -> Int ! Down

handler next() for Next =
  get(id) => fail Down

handler front() for Front uses Next =
  ask(id) => try release Next.get(id)

fn main() uses Console =
  with next(), front() in print(attempt Front.ask(1))
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Next`
       ┌─ test.ren:10:26
    10 │   ask(id) => try release Next.get(id)
       │                          ^^^^
    |}]

let%expect_test "[s4 accept] a stale read across `release` is found by a seed, and the fix holds" =
  (* decision 10: `sim` switches tasks at every `release`, so a value read
     from state before one and written after loses an update *)
  until "s4"
    ~says:
      [
        "✗ two counts both land";
        "✓ the fix reads after";
        "1 passed, 1 failed";
      ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
dep Next =
  get: fn() -> Int
dep Count =
  add: fn() -> Int
  bad_add: fn() -> Int
  total: fn() -> Int

handler next() for Next =
  get() => 1

handler count() for Count uses Next =
  var n = 0
  bad_add() =>
    let before = n
    let k = release Next.get()
    n = before + k
    n
  add() =>
    let k = release Next.get()
    n += k
    n
  total() => n

test "two counts both land" =
  with next(), count() in
    Async.scope fn(s) =>
      s.spawn fn() => Count.bad_add()
      s.spawn fn() => Count.bad_add()
    assert Count.total() == 2

test "the fix reads after" =
  with next(), count() in
    Async.scope fn(s) =>
      s.spawn fn() => Count.add()
      s.spawn fn() => Count.add()
    assert Count.total() == 2
|}));
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Next`
       ┌─ test.ren:15:21
    15 │     let k = release Next.get()
       │                     ^^^^
    |}]

let%expect_test "[s4 reject] `release` outside a handler's operation" =
  until "s4"
    ~says:
      [
        "error: `release` lets go of a handler's instance, so it's only written in one of its operations";
        "help: call it without `release`";
      ]
    (fun () ->
      check_error
        {|
dep Next =
  get: fn() -> Int
handler next() for Next =
  get() => 1
fn main() -> Int = with next() in release Next.get()
|});
  [%expect {|
    (until s4)
    error: expected a new line, found `Next`
      ┌─ test.ren:5:43
    5 │ fn main() -> Int = with next() in release Next.get()
      │                                           ^^^^
    |}]

let%expect_test "[s4 reject] `release` on what isn't a dependency's operation" =
  until "s4"
    ~says:
      [
        "error: `release` lets go of the instance for one call of another dependency's operation, and `twice(1)` isn't one";
        "help: write it on the operation's call: `release Next.get(id)`";
      ]
    (fun () ->
      check_error
        {|
dep Front =
  ask: fn() -> Int
fn twice(n: Int) -> Int = n * 2
handler front() for Front =
  ask() => release twice(1)
fn main() = 1
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `twice`
      ┌─ test.ren:5:20
    5 │   ask() => release twice(1)
      │                    ^^^^^
    |}]

let%expect_test "[s4 accept] an actor-shaped handler loops over a reader in its state while it calls another service" =
  (* decision 2's row narrowed to `Async.until`, `release` and block
     parameters: a dependency call holds none of the handler's state *)
  until "s4"
    ~want:{|
3
()
|}
    (fun () ->
      run
        {|
type Reader = { xs: Array<Int>, at: Int }
  pub fn next(inout self) -> Option<Int> =
    if self.at >= self.xs.len() then None
    else
      self.at += 1
      Some(self.xs[self.at - 1])

dep Sink =
  put: fn(x: Int)
dep Pump =
  run: fn() -> Int

handler sink() for Sink =
  put(_) => ()

handler pump() for Pump uses Sink =
  var r = Reader { xs: [1, 2, 3], at: 0 }
  run() =>
    var n = 0
    for x in &r
      Sink.put(x)
      n += 1
    n

fn main() uses Console =
  with sink(), pump() in print(Pump.run())
|});
  [%expect {|
    (until s4)
    error: `r` is changed across a dependency call
       ┌─ test.ren:21:7
    20 │     for x in &r
       │              -- changed for the whole loop
    21 │       Sink.put(x)
       │       ^^^^^^^^^^^ a dependency call
       = a dependency call in an arm counts as a change of the handler's state: at one, `Async.until`, other tasks run the handler
       help: make the dependency call before or after the loop
    |}]

let%expect_test "[s4 accept] state borrowed across `release` is still refused" =
  (* `release` is one of the three in decision 2's row: the state can
     change during it *)
  until "s4"
    ~says:[ "error: `r` is changed across a call that lets go of the handler" ]
    (fun () ->
      check_error
        {|
type Reader = { xs: Array<Int>, at: Int }
  pub fn next(inout self) -> Option<Int> =
    if self.at >= self.xs.len() then None
    else
      self.at += 1
      Some(self.xs[self.at - 1])

dep Sink =
  put: fn(x: Int)
dep Pump =
  run: fn()

handler sink() for Sink =
  put(_) => ()

handler pump() for Pump uses Sink =
  var r = Reader { xs: [1, 2, 3], at: 0 }
  run() =>
    for x in &r
      release Sink.put(x)
|});
  [%expect {|
    (until s4)
    error: expected the end of the line, found `Sink`
       ┌─ test.ren:20:15
    20 │       release Sink.put(x)
       │               ^^^^
    |}]

let%expect_test "[s4 reject] a task taking an instance it already holds panics, not hangs" =
  (* decision 10, built by 11a's step 4 and kept: through a block
     parameter passed on to an operation, which Infer's rule doesn't see,
     it's a panic, not a hang *)
  run_error
        {|
dep Tally =
  change: fn(f: fn())
  read: fn() -> Int

handler tally() for Tally =
  var n = 0
  change(f) => f()
  read() => n

fn pass_on(f: fn()) uses Tally = Tally.change(f)

fn main() uses Console, Async =
  with tally() in
    Async.scope fn(s) =>
      s.spawn fn() => pass_on(fn() => print(Tally.read()))
|};
  [%expect {|
    error: panic: `Tally.read` calls back into the instance its own task is in, so it would wait for itself
       ┌─ test.ren:15:45
    15 │       s.spawn fn() => pass_on(fn() => print(Tally.read()))
       │                                             ^^^^^^^^^^^^
       = in the task main/main:0
       = an operation keeps its instance until it returns, and this task is in one of its operations
       help: a block passed to an operation gets its dependencies only from its parameter's type: call it before the operation, outside the block
    |}]

let%expect_test "[s4 reject] `until`'s deadlock names the instances each parked task holds" =
  (* decision 10's "other waits can still deadlock": an operation of `A`
     calls `B`, whose `until` waits for a task that must go through `A` *)
  until "s4"
    ~says:
      [
        "panic: every task is waiting, and nothing can wake one";
        "holding `A`";
      ]
    (fun () ->
      run_error
        {|
dep A =
  go: fn()
  poke: fn()
dep B =
  wait: fn()
  open: fn()

handler b() for B =
  var opened = false
  wait() => Async.until fn() => opened
  open() => opened = true

handler a() for A uses B =
  var calls = 0
  go() =>
    calls += 1
    B.wait()
  poke() =>
    calls += 1
    B.open()

fn main() uses Async =
  with b(), a() in
    Async.scope fn(s) =>
      s.spawn fn() => A.go()
      s.spawn fn() => A.poke()
|});
  [%expect {|
    (until s4)
    error: panic: every task is waiting, and nothing can wake one
       ┌─ test.ren:24:5
    24 │     Async.scope fn(s) =>
       │     ^^^^^^^^^^^^^^^^^^^^
       = main waits for its scope's tasks at test.ren:24:5
       = main/main:0 waits in `Async.until` at test.ren:10:13
       = main/main:1 waits for `A`, which another task is in at test.ren:26:23
    |}]

let%expect_test "[s4 accept] `sim` chooses fairly among an instance's waiters and arrivals" =
  (* decision 10: the queue is fair, not first in first out, and `sim`
     chooses among the waiters and a caller that arrives as the instance
     is released from its tape. Task 4 arrives just as task 1 lets go,
     after 2 and 3 have queued: first in first out it's never second, and
     under some seed it is *)
  until "s4"
    ~says:[ "✗ a caller arriving as it's released never overtakes the queue" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
dep Gate =
  enter: fn(who: Int, ms: Int)
  second: fn() -> Int

handler gate() for Gate uses Clock =
  var order: Array<Int> = []
  enter(who, ms) =>
    &order.push(who)
    Clock.sleep(Duration.ms(ms))
  second() => order[1]

test "a caller arriving as it's released never overtakes the queue" =
  with gate() in
    Async.scope fn(s) =>
      s.spawn fn() => Gate.enter(1, 10)
      s.spawn fn() =>
        Clock.sleep(Duration.ms(1))
        Gate.enter(2, 0)
      s.spawn fn() =>
        Clock.sleep(Duration.ms(1))
        Gate.enter(3, 0)
      s.spawn fn() =>
        Clock.sleep(Duration.ms(10))
        Gate.enter(4, 0)
    assert Gate.second() != 4
|}));
  [%expect {|
    (until s4)
    test.ren
      ✓ a caller arriving as it's released never overtakes the queue

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s4 accept] a default that's a variant with no fields" =
  (* What's decided 9: `kill: Kill = Tree` *)
  until "s4"
    ~want:{|
Gentle
Hard
()
|}
    (fun () ->
      run
        {|
type Mode = | Gentle | Hard

fn stop(n: Int, how: Mode = Gentle) -> Mode = how

fn main() uses Console =
  print(stop(1))
  print(stop(1, how: Hard))
|});
  [%expect {|
    (until s4)
    error: a parameter's default is a literal: a number, a `Bool` or a string
      ┌─ test.ren:3:29
    3 │ fn stop(n: Int, how: Mode = Gentle) -> Mode = how
      │                             ^^^^^^
      help: give it where it's called instead
    |}]

let%expect_test "[s4 reject] a default that's a variant with fields" =
  until "s4"
    ~says:
      [
        "error: a parameter's default is a literal, or a variant with no fields";
        "help: give it where it's called instead";
      ]
    (fun () ->
      check_error
        {|
type Mode = | Gentle | After(ms: Int)
fn stop(n: Int, how: Mode = After(5)) -> Mode = how
fn main() = 1
|});
  [%expect {|
    (until s4)
    error: a parameter's default is a literal: a number, a `Bool` or a string
      ┌─ test.ren:2:29
    2 │ fn stop(n: Int, how: Mode = After(5)) -> Mode = how
      │                             ^^^^^
      help: give it where it's called instead
    |}]

let%expect_test "[s4 accept] `Proc.run(kill:)`: `sim.proc()` says how each cancelled run was killed" =
  until "s4"
    ~says:[ "✓ a cancelled run is killed with its process group" ]
    (fun () ->
      test
        (pub_all
         {|
import sim.{Run, SimProc}

test "a cancelled run is killed with its process group" =
  with sim.proc([Run { command: Command { cmd: "sleep", args: ["9"] }, code: 0, takes: Duration.seconds(9) }]) in
    let _ = attempt Async.timeout(Duration.ms(5)) fn() =>
      try Proc.run("sleep", ["9"])
    let _ = attempt Async.timeout(Duration.ms(5)) fn() =>
      try Proc.run("sleep", ["9"], kill: Child)
    assert SimProc.killed().len() == 2
    assert SimProc.kills() == [Tree, Child]
|}));
  [%expect {|
    (until s4)
    error: `SimProc` has no public `kills`
       ┌─ test.ren:10:20
    10 │     assert SimProc.kills() == [Tree, Child]
       │                    ^^^^^
       help: if it's defined in `sim`, mark it `pub`
    |}]

(* ---- s5: pull arguments, channels and producers (streams.md) ---- *)

let cursor_type =
  {|
type Count = { at: Int, to: Int }
  pub fn next(inout self) -> Option<Int> =
    if self.at >= self.to then None
    else
      self.at += 1
      Some(self.at)
|}

let%expect_test "[s5 accept] `Async.map` over a temporary cursor keeps order" =
  until "s5"
    ~want:{|
[2, 4, 6]
()
|}
    (fun () ->
      run
        (cursor_type
       ^ {|
fn main() uses Console, Async =
  print(Async.map(Count { at: 0, to: 3 }) fn(x) => x * 2)
|}));
  [%expect {|
    (until s5)
    error: expected `Array<_>`, found `Count`
      ┌─ test.ren:9:19
    9 │   print(Async.map(Count { at: 0, to: 3 }) fn(x) => x * 2)
      │                   ^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s5 accept] `Async.each` over a named cursor, `&r`, which goes on after" =
  until "s5"
    ~want:{|
6
Some(4)
()
|}
    (fun () ->
      run
        (cursor_type
       ^ {|
dep Sum =
  add: fn(x: Int)
  total: fn() -> Int

handler sum() for Sum =
  var t = 0
  add(x) => t += x
  total() => t

fn main() uses Console, Async =
  var r = Count { at: 0, to: 4 }
  with sum() in
    Async.each(&r, max: 2) fn(x) =>
      Sum.add(x)
    print(Sum.total())
  print(r.next())
|}));
  [%expect {|
    (until s5)
    error: `Async.each` doesn't change this argument
       ┌─ test.ren:20:16
    20 │     Async.each(&r, max: 2) fn(x) =>
       │                ^^
       = `&` marks an argument the call changes: an `inout` parameter
       help: remove the `&`

    error: `next` changes `r`, so the call needs `&`
       ┌─ test.ren:23:9
    23 │   print(r.next())
       │         ^^^^^^^^
       = `&` shows at the call that `r` is changed
       help: write `&r.next()`
    |}]

let%expect_test "[s5 accept] `Async.each` over a hand-written block" =
  until "s5"
    ~want:{|
3
()
|}
    (fun () ->
      run
        {|
dep Sum =
  add: fn(x: Int)
  total: fn() -> Int

handler sum() for Sum =
  var t = 0
  add(x) => t += x
  total() => t

dep Src =
  pull: fn() -> Option<Int>

handler src() for Src =
  var n = 0
  pull() =>
    n += 1
    if n > 2 then None else Some(n)

fn main() uses Console, Async =
  with src(), sum() in
    Async.each(fn() => Src.pull()) fn(x) => Sum.add(x)
    print(Sum.total())
|});
  [%expect {|
    (until s5)
    error: expected `Array<_>`, found `fn() -> Option<Int>`
       ┌─ test.ren:21:16
    21 │     Async.each(fn() => Src.pull()) fn(x) => Sum.add(x)
       │                ^^^^^^^^^^^^^^^^^^
       help: use `Async.map` to keep the results, or end the block with `()`
    |}]

let%expect_test "[s5 reject] a named cursor passed to `Async.each` while the block touches it" =
  (* decision 2's new row: `&r` as a pull argument is a write, held for
     the call *)
  until "s5"
    ~says:[ "error: `r` is changed for the whole call" ]
    (fun () ->
      check_error
        (cursor_type
       ^ {|
fn main() uses Async =
  var r = Count { at: 0, to: 4 }
  Async.each(&r) fn(x) =>
    let _ = r.at
    ()
|}));
  [%expect {|
    (until s5)
    error: `Async.each` doesn't change this argument
       ┌─ test.ren:10:14
    10 │   Async.each(&r) fn(x) =>
       │              ^^
       = `&` marks an argument the call changes: an `inout` parameter
       help: remove the `&`
    |}]

let%expect_test "[s5 accept] pulled on the caller's task only when a slot frees" =
  (* `max: 1`: each item is pulled after the one before has ended *)
  until "s5"
    ~want:{|
pulled 1
ran 1
pulled 2
ran 2
pulled 3
()
|}
    (fun () ->
      run
        {|
dep Src =
  pull: fn() -> Option<Int>

handler src() for Src uses Console =
  var n = 0
  pull() =>
    n += 1
    print("pulled ".concat(show(n)))
    if n > 2 then None else Some(n)

fn main() uses Console, Async =
  with src() in
    Async.each(fn() => Src.pull(), max: 1) fn(x) => print("ran ".concat(show(x)))
|});
  [%expect {|
    (until s5)
    error: expected `Array<_>`, found `fn() -> Option<Int>`
       ┌─ test.ren:13:16
    13 │     Async.each(fn() => Src.pull(), max: 1) fn(x) => print("ran ".concat(show(x)))
       │                ^^^^^^^^^^^^^^^^^^
       help: use `Async.map` to keep the results, or end the block with `()`
    |}]

let%expect_test "[s5 accept] a channel is a dependency, and `items()` pulls `recv()`" =
  until "s5"
    ~want:{|
1
2
3
()
|}
    (fun () ->
      run
        {|
import sync.{Chan}

dep Events = Chan<Int>

fn main() uses Console, Async =
  with sync.channel(4) as Events in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Events.send(1)
        Events.send(2)
        Events.send(3)
        Events.close()
      for e in Events.items()
        print(e)
|});
  [%expect {|
    (until s5)
    error: `Events` has no operation or member named `items`
       ┌─ test.ren:13:23
    13 │       for e in Events.items()
       │                       ^^^^^
       help: its operations: `send`, `recv`, `close`
    |}]

let%expect_test "[s5 accept] a channel's `items()` as a pull argument" =
  until "s5"
    ~want:{|
[10, 20]
()
|}
    (fun () ->
      run
        {|
import sync.{Chan}

dep Events = Chan<Int>

fn main() uses Console, Async =
  with sync.channel(4) as Events in
    Events.send(1)
    Events.send(2)
    Events.close()
    print(Async.map(Events.items()) fn(e) => e * 10)
|});
  [%expect {|
    (until s5)
    error: `Events` has no operation or member named `items`
       ┌─ test.ren:10:28
    10 │     print(Async.map(Events.items()) fn(e) => e * 10)
       │                            ^^^^^
       help: its operations: `send`, `recv`, `close`
    |}]

let%expect_test "[s5 reject] `items()` where it isn't pulled" =
  until "s5"
    ~says:
      [
        "error: `Events.items()` is pulled where it's written: in a `for`, or as a pull argument";
        "help: loop over it: `for e in Events.items()`";
      ]
    (fun () ->
      check_error
        {|
import sync.{Chan}
dep Events = Chan<Int>
fn main() uses Events =
  let xs = Events.items()
  ()
|});
  [%expect {|
    (until s5)
    error: `Events` has no operation or member named `items`
      ┌─ test.ren:4:19
    4 │   let xs = Events.items()
      │                   ^^^^^
      help: its operations: `send`, `recv`, `close`
    |}]

let%expect_test "[s5 accept] `Async.produce`: the producer sends through `Send<T>`, the body pulls" =
  until "s5"
    ~want:{|
1
2
3
()
|}
    (fun () ->
      run
        {|
fn count_to(n: Int) uses Send<Int> =
  for i in 1..n + 1
    Send.send(i)

fn main() uses Console, Async =
  Async.produce(cap: 2, fn() => count_to(3)) fn(items) =>
    for x in try items
      print(x)
|});
  [%expect {|
    (until s5)
    error: there's no dependency named `Send`
      ┌─ test.ren:1:26
    1 │ fn count_to(n: Int) uses Send<Int> =
      │                          ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Async` has no operation or member named `produce`
      ┌─ test.ren:6:9
    6 │   Async.produce(cap: 2, fn() => count_to(3)) fn(items) =>
      │         ^^^^^^^
      help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s5 accept] a `break` in `produce`'s body cancels and waits for the producer" =
  until "s5"
    ~want:{|
1
producer stopped
after
()
|}
    (fun () ->
      run
        {|
dep Stopped =
  noted: fn()

handler stopped() for Stopped uses Console =
  finally(_) => print("producer stopped")
  noted() => ()

fn forever() uses Send<Int>, Console =
  with stopped() in
    var i = 0
    while true
      i += 1
      Send.send(i)

fn main() uses Console, Async =
  Async.produce(fn() => forever()) fn(items) =>
    for x in try items
      print(x)
      break
  print("after")
|});
  [%expect {|
    (until s5)
    error: there's no dependency named `Send`
      ┌─ test.ren:8:19
    8 │ fn forever() uses Send<Int>, Console =
      │                   ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `Stopped`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Async` has no operation or member named `produce`
       ┌─ test.ren:16:9
    16 │   Async.produce(fn() => forever()) fn(items) =>
       │         ^^^^^^^
       help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s5 accept] a producer blocked at `cap` makes progress as the consumer takes" =
  until "s5"
    ~says:[ "✓ a slow consumer still gets everything, in order" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
fn many() uses Send<Int> =
  for i in 0..20
    Send.send(i)

test "a slow consumer still gets everything, in order" =
  var got: Array<Int> = []
  Async.produce(cap: 1, fn() => many()) fn(items) =>
    for x in try items
      Async.yield()
      &got.push(x)
  assert got == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
|}));
  [%expect {|
    (until s5)
    error: there's no dependency named `Send`
      ┌─ test.ren:1:20
    1 │ pub fn many() uses Send<Int> =
      │                    ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Async` has no operation or member named `produce`
      ┌─ test.ren:7:9
    7 │   Async.produce(cap: 1, fn() => many()) fn(items) =>
      │         ^^^^^^^
      help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s5 accept] a failure in the producer ends the stream with it" =
  until "s5"
    ~want:{|
1
Err(Broken)
()
|}
    (fun () ->
      run
        {|
fn one_then_fail() ! Broken uses Send<Int> =
  Send.send(1)
  fail Broken

fn consume() ! Broken uses Console, Async =
  Async.produce(fn() => try one_then_fail()) fn(items) =>
    for x in try items
      print(x)

fn main() uses Console, Async = print(attempt consume())
|});
  [%expect {|
    (until s5)
    error: there's no dependency named `Send`
      ┌─ test.ren:1:34
    1 │ fn one_then_fail() ! Broken uses Send<Int> =
      │                                  ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Async` has no operation or member named `produce`
      ┌─ test.ren:6:9
    6 │   Async.produce(fn() => try one_then_fail()) fn(items) =>
      │         ^^^^^^^
      help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

let%expect_test "[s5 accept] `Async.map_pull`: results as a stream, in order" =
  until "s5"
    ~want:{|
[1, 4, 9]
()
|}
    (fun () ->
      run
        {|
fn main() uses Console, Async =
  var out: Array<Int> = []
  Async.map_pull([1, 2, 3], max: 2, fn(x) => x * x) fn(results) =>
    for r in try results
      &out.push(r)
  print(out)
|});
  [%expect {|
    (until s5)
    error: `Async` has no operation or member named `map_pull`
      ┌─ test.ren:3:9
    3 │   Async.map_pull([1, 2, 3], max: 2, fn(x) => x * x) fn(results) =>
      │         ^^^^^^^^
      help: its operations: `yield`, `tick`; its members: `scope`, `until`, `timeout`, `race`, `isolate`, `map`, `each`, `both`, `single`
    |}]

(* ---- s6: `striped` (decision 18, language.md §11) ---- *)

let hits =
  {|
dep Hits =
  hit: fn(path: Str)
  total: fn() -> Int

handler counter() for Hits =
  var n = 0
  hit(_) => n += 1
  total() => n
|}

let%expect_test "[s6 accept] `striped` by key: a keyless operation folded with `merge: Sum`" =
  until "s6"
    ~want:{|
3
()
|}
    (fun () ->
      run
        (hits
       ^ {|
fn main() uses Console =
  with striped(counter(), n: 4, merge: Sum) in
    Hits.hit("/a")
    Hits.hit("/b")
    Hits.hit("/a")
    print(Hits.total())
|}));
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:11:8
    11 │   with striped(counter(), n: 4, merge: Sum) in
       │        ^^^^^^^
    |}]

let%expect_test "[s6 accept] `by: Worker`: a stripe per worker, the merge erasing which" =
  until "s6"
    ~says:[ "✓ every hit is counted, whichever worker it lands on" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         (hits
       ^ {|
test "every hit is counted, whichever worker it lands on" =
  with striped(counter(), by: Worker, merge: Sum) in
    Async.each([1, 2, 3, 4]) fn(_) => Hits.hit("/")
    assert Hits.total() == 4
|})));
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:11:8
    11 │   with striped(counter(), by: Worker, merge: Sum) in
       │        ^^^^^^^
    |}]

let%expect_test "[s6 accept] the split law: a result that depends on routing fails under some seed" =
  (* under `sim` two virtual workers, routing from the tape: `Max` of the
     stripes' counts erases nothing about which stripe a hit went to *)
  until "s6"
    ~says:[ "✗ the busiest stripe saw every hit" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         (hits
       ^ {|
test "the busiest stripe saw every hit" =
  with striped(counter(), by: Worker, merge: Max) in
    Async.each([1, 2, 3, 4]) fn(_) => Hits.hit("/")
    assert Hits.total() == 4
|})));
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:11:8
    11 │   with striped(counter(), by: Worker, merge: Max) in
       │        ^^^^^^^
    |}]

let%expect_test "[s6 accept] a keyless operation that returns `()` broadcasts" =
  until "s6"
    ~want:{|
0
()
|}
    (fun () ->
      run
        {|
dep Hits =
  hit: fn(path: Str)
  reset: fn()
  total: fn() -> Int

handler counter() for Hits =
  var n = 0
  hit(_) => n += 1
  reset() => n = 0
  total() => n

fn main() uses Console =
  with striped(counter(), merge: Sum) in
    Hits.hit("/a")
    Hits.hit("/b")
    Hits.reset()
    print(Hits.total())
|});
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:13:8
    13 │   with striped(counter(), merge: Sum) in
       │        ^^^^^^^
    |}]

let%expect_test "[s6 accept] `merge: Concat` and `Custom(m)`, left to right in stripe order" =
  until "s6"
    ~want:{|
["/a", "/b"]
2
()
|}
    (fun () ->
      run
        {|
dep Seen =
  see: fn(path: Str)
  all: fn() -> Array<Str>

handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  all() => paths

handler longest() for Merge<Seen> =
  all(a, b) => if a.len() >= b.len() then a else b

fn main() uses Console =
  with striped(seen(), n: 1, merge: Concat) in
    Seen.see("/a")
    Seen.see("/b")
    print(Seen.all())
  with striped(seen(), n: 1, merge: Custom(longest())) in
    Seen.see("/a")
    Seen.see("/b")
    print(Seen.all().len())
|});
  [%expect {|
    (until s6)
    error: there's no dependency named `Merge`
       ┌─ test.ren:10:23
    10 │ handler longest() for Merge<Seen> =
       │                       ^^^^^
       = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `Seen`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
       help: use one of those, or declare it with `dep`

    error: there's no function named `striped`
       ┌─ test.ren:14:8
    14 │   with striped(seen(), n: 1, merge: Concat) in
       │        ^^^^^^^

    error: there's no function named `striped`
       ┌─ test.ren:18:8
    18 │   with striped(seen(), n: 1, merge: Custom(longest())) in
       │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] a keyless operation that returns a value, with no `merge:`" =
  until "s6"
    ~says:
      [
        "error: `total` runs on every stripe and gives an `Int`, so `striped` needs `merge:`";
        "help: say how to fold them: `merge: Sum`, `Max`, `Min`, `Concat` or `Custom(m)`";
      ]
    (fun () ->
      check_error
        (hits
       ^ {|
fn main() uses Console =
  with striped(counter()) in print(Hits.total())
|}));
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:11:8
    11 │   with striped(counter()) in print(Hits.total())
       │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] `by: Worker` with `n`" =
  until "s6"
    ~says:
      [
        "error: `by: Worker` gives each worker a stripe, so it takes no `n`";
        "help: remove `n: 4`";
      ]
    (fun () ->
      check_error
        (hits
       ^ {|
fn main() uses Console =
  with striped(counter(), n: 4, by: Worker, merge: Sum) in print(Hits.total())
|}));
  [%expect {|
    (until s6)
    error: there's no function named `striped`
       ┌─ test.ren:11:8
    11 │   with striped(counter(), n: 4, by: Worker, merge: Sum) in print(Hits.total())
       │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] `Custom(m)` with a handler that has state" =
  until "s6"
    ~says:[ "error: `Custom` takes a stateless handler of `Merge<Hits>`" ]
    (fun () ->
      check_error
        (hits
       ^ {|
handler adding() for Merge<Hits> =
  var calls = 0
  total(a, b) =>
    calls += 1
    a + b

fn main() uses Console =
  with striped(counter(), merge: Custom(adding())) in print(Hits.total())
|}));
  [%expect {|
    (until s6)
    error: there's no dependency named `Merge`
       ┌─ test.ren:10:22
    10 │ handler adding() for Merge<Hits> =
       │                      ^^^^^
       = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Hits`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
       help: use one of those, or declare it with `dep`

    error: there's no function named `striped`
       ┌─ test.ren:17:8
    17 │   with striped(counter(), merge: Custom(adding())) in print(Hits.total())
       │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] `merge: Sum` of what isn't a number" =
  until "s6"
    ~says:[ "error: `merge: Sum` adds what `all` gives, and an `Array<Str>` isn't a number" ]
    (fun () ->
      check_error
        {|
dep Seen =
  see: fn(path: Str)
  all: fn() -> Array<Str>
handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  all() => paths
fn main() uses Console =
  with striped(seen(), merge: Sum) in print(Seen.all())
|});
  [%expect {|
    (until s6)
    error: there's no function named `striped`
      ┌─ test.ren:9:8
    9 │   with striped(seen(), merge: Sum) in print(Seen.all())
      │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] `striped` of what isn't a handler's description" =
  until "s6"
    ~says:
      [
        "error: `striped` takes a handler's description, and `16` is an `Int`";
        "help: describe the handler whose instances it keeps: `striped(counter(), merge: Sum)`";
      ]
    (fun () ->
      check_error {|
fn main() uses Console =
  with striped(16) in print(1)
|});
  [%expect {|
    (until s6)
    error: there's no function named `striped`
      ┌─ test.ren:2:8
    2 │   with striped(16) in print(1)
      │        ^^^^^^^
    |}]

let%expect_test "[s6 reject] `sync.keyed` is gone" =
  until "s6"
    ~says:[ "error: `sync` has no `keyed`" ]
    (fun () ->
      check_error
        ("import sync\n" ^ hits
       ^ {|
fn main() uses Console =
  with sync.keyed(4, counter()) in print(Hits.total())
|}));
  [%expect {|
    (until s6)
    raised: Ren_tests.Helpers.No_error("expected an error, but the program checked")
    |}]

(* ---- s7: `actors` (decision 18, language.md §11) ---- *)

(* A document actor and its store, the smallest stand-ins: a document is
   text that grows by appending, and the store keeps the last text saved
   and counts what it was asked. *)
let docs =
  {|
type DocId = | DocId(n: Int)

dep Store =
  load: fn(id: DocId) -> Str ! StoreDown
  save: fn(id: DocId, text: Str) ! StoreDown

handler mem_store() for Store =
  var saved: Map<Int, Str> = Map.empty
  load(id) =>
    let DocId(n) = id
    if n < 0 then fail StoreDown
    saved.get(n) orelse ""
  save(id, text) =>
    let DocId(n) = id
    &saved.set(n, text)

dep Doc =
  edit: fn(s: Str) ! StoreDown
  text: fn() -> Str

handler doc(id: DocId) for Doc uses Store, Console =
  var text = try Store.load(id)
  finally(_) => print("evicted ".concat(show(id)))
  edit(s) =>
    text = text.concat(s)
    try Store.save(id, text)
  text() => text

dep Docs = Actors<DocId, Doc> ! StoreDown
|}

let%expect_test "[s7 accept] `at` makes an actor on demand, and installs it as `D` for its block" =
  until "s7"
    ~want:{|
ab
1
evicted DocId(1)
Ok(())
()
|}
    (fun () ->
      run
        (docs
       ^ {|
fn go() ! StoreDown uses Docs, Console =
  try Docs.at(DocId(1)) fn() =>
    try Doc.edit("a")
    try Doc.edit("b")
    print(Doc.text())
  print(Docs.count())

fn main() uses Console =
  with mem_store(), actors(doc, max: 2) as Docs in print(attempt go())
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 accept] setup's errors are `at`'s, and the next `at` tries again" =
  until "s7"
    ~want:{|
Err(StoreDown)
0
()
|}
    (fun () ->
      run
        (docs
       ^ {|
fn main() uses Console =
  with mem_store(), actors(doc) as Docs in
    print(attempt Docs.at(DocId(-1)) fn() => Doc.text())
    print(Docs.count())
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 accept] past `max:`, the least recently released actor is evicted, its `finally` on the caller's task" =
  until "s7"
    ~want:{|
evicted DocId(1)
2
1
1
evicted DocId(3)
evicted DocId(2)
()
|}
    (fun () ->
      run
        (docs
       ^ {|
fn touch(n: Int) ! StoreDown uses Docs =
  try Docs.at(DocId(n)) fn() => try Doc.edit("x")

fn go() ! StoreDown uses Docs, Console =
  try touch(1)
  try touch(2)
  try touch(3)
  print(Docs.count())
  print(Docs.made() - Docs.count())
  print(Docs.evicted())

fn main() uses Console =
  with mem_store(), actors(doc, max: 2) as Docs in
    match attempt go()
      Ok(_) => ()
      Err(_) => print("failed")
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 accept] an evicted actor made again reads what the store kept" =
  until "s7"
    ~want:{|
evicted DocId(1)
evicted DocId(2)
xy
evicted DocId(1)
()
|}
    (fun () ->
      run
        (docs
       ^ {|
fn go() ! StoreDown uses Docs, Console =
  try Docs.at(DocId(1)) fn() => try Doc.edit("x")
  try Docs.at(DocId(2)) fn() => try Doc.edit("-")
  try Docs.at(DocId(1)) fn() =>
    try Doc.edit("y")
    print(Doc.text())

fn main() uses Console =
  with mem_store(), actors(doc, max: 1) as Docs in
    match attempt go()
      Ok(_) => ()
      Err(_) => print("failed")
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 accept] a pinned actor isn't evicted; the maker waits for one that's evictable" =
  until "s7"
    ~says:[ "✓ the pinned one keeps its text" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         (docs
       ^ {|
test "the pinned one keeps its text" =
  with mem_store(), actors(doc, max: 1) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() =>
        let _ = attempt Docs.at(DocId(1)) fn() =>
          let _ = attempt Doc.edit("a")
          Async.yield()
          assert Doc.text() == "a"
      s.spawn fn() =>
        let _ = attempt Docs.at(DocId(2)) fn() => Doc.text()
|})));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:35
    29 │ pub dep Docs = Actors<DocId, Doc> ! StoreDown
       │                                   ^

    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:35:13
    35 │         let _ = attempt Docs.at(DocId(1)) fn() =>
       │             ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s7 accept] `evict(k)`, `evict_idle(d)` and `each`" =
  until "s7"
    ~want:{|
evicted DocId(1)
1
b
evicted DocId(2)
0
()
|}
    (fun () ->
      run
        (docs
       ^ {|
import sim

fn go() ! StoreDown uses Docs, Console, Clock =
  try Docs.at(DocId(1)) fn() => try Doc.edit("a")
  Clock.sleep(Duration.seconds(10))
  try Docs.at(DocId(2)) fn() => try Doc.edit("b")
  Docs.evict_idle(Duration.seconds(5))
  print(Docs.count())
  Docs.each fn() => print(Doc.text())
  Docs.evict(DocId(2))
  print(Docs.count())

fn main() uses Console =
  with sim.scheduler(1) in
    with sim.clock() in
      with mem_store(), actors(doc) as Docs in
        match attempt go()
          Ok(_) => ()
          Err(_) => print("failed")
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^

    error: imports go at the top of the file
       ┌─ test.ren:31:1
    31 │ import sim
       │ ^^^^^^^^^^
       help: move it above the file's first function or type
    |}]

let%expect_test "[s7 accept] teardown in reverse creation order" =
  until "s7"
    ~want:{|
evicted DocId(3)
evicted DocId(1)
evicted DocId(2)
()
|}
    (fun () ->
      run
        (docs
       ^ {|
fn main() uses Console =
  with mem_store(), actors(doc) as Docs in
    for n in [2, 1, 3]
      let _ = attempt Docs.at(DocId(n)) fn() => Doc.text()
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^

    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:34:11
    34 │       let _ = attempt Docs.at(DocId(n)) fn() => Doc.text()
       │           ^
       help: add the value this block should produce as its last line
    |}]

let%expect_test "[s7 accept] two operations of one actor race; one operation doesn't" =
  (* language.md §11: a read and a write in two operations race *)
  until "s7"
    ~says:[ "✗ two appends by read-then-write both land"; "✓ two appends by one operation both land" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
type DocId = | DocId(n: Int)

dep Doc =
  set: fn(s: Str)
  text: fn() -> Str
  append: fn(s: Str)

handler doc(id: DocId) for Doc =
  var text = ""
  set(s) => text = s
  text() => text
  append(s) => text = text.concat(s)

dep Docs = Actors<DocId, Doc>

test "two appends by read-then-write both land" =
  with actors(doc) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text().concat("a"))
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text().concat("b"))
    Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2

test "two appends by one operation both land" =
  with actors(doc) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("a")
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("b")
    Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2
|}));
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
       ┌─ test.ren:14:16
    14 │ pub dep Docs = Actors<DocId, Doc>
       │                ^^^^^^
       = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
       help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:17:8
    17 │   with actors(doc) as Docs in
       │        ^^^^^^

    error: `Docs` is a type, not a dependency
       ┌─ test.ren:17:23
    17 │   with actors(doc) as Docs in
       │                       ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ test.ren:19:28
    19 │       s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text().concat("a"))
       │                            ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:20:28
    20 │       s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text().concat("b"))
       │                            ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:21:10
    21 │     Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2
       │          ^^
       help: declare it under `type Docs`

    error: there's no function named `actors`
       ┌─ test.ren:24:8
    24 │   with actors(doc) as Docs in
       │        ^^^^^^

    error: `Docs` is a type, not a dependency
       ┌─ test.ren:24:23
    24 │   with actors(doc) as Docs in
       │                       ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ test.ren:26:28
    26 │       s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("a")
       │                            ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:27:28
    27 │       s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("b")
       │                            ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:28:10
    28 │     Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2
       │          ^^
       help: declare it under `type Docs`
    |}]

let%expect_test "[s7 accept] chaos eviction finds what lives only in memory" =
  (* `sim.scheduler(seed, evict: AnyIdle)` evicts any evictable actor at
     any scheduling point: under some seed a document kept only in memory
     loses its text between two `at`s *)
  until "s7"
    ~want:{|
true
()
|}
    (fun () ->
      run
        {|
import sim

type DocId = | DocId(n: Int)

dep Doc =
  append: fn(s: Str)
  text: fn() -> Str

handler doc(id: DocId) for Doc =
  var text = ""
  append(s) => text = text.concat(s)
  text() => text

dep Docs = Actors<DocId, Doc>

fn main() uses Console =
  var lost = false
  for seed in 1..50
    with sim.scheduler(seed, evict: AnyIdle) in
      with actors(doc) as Docs in
        Docs.at(DocId(1)) fn() => Doc.append("a")
        Async.yield()
        Docs.at(DocId(1)) fn() =>
          if Doc.text() != "a" then lost = true
  print(lost)
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
       ┌─ test.ren:14:12
    14 │ dep Docs = Actors<DocId, Doc>
       │            ^^^^^^
       = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
       help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:20:12
    20 │       with actors(doc) as Docs in
       │            ^^^^^^

    error: `Docs` is a type, not a dependency
       ┌─ test.ren:20:27
    20 │       with actors(doc) as Docs in
       │                           ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ test.ren:21:14
    21 │         Docs.at(DocId(1)) fn() => Doc.append("a")
       │              ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:23:14
    23 │         Docs.at(DocId(1)) fn() =>
       │              ^^
       help: declare it under `type Docs`
    |}]

let%expect_test "[s7 reject] `at` inside `at` of the same family" =
  until "s7"
    ~says:
      [
        "error: `Docs.at` inside a block of `Docs.at` could wait for a slot its own block holds";
        "help: finish with the first actor, then `at` the second; or send it a message: `Docs.post(k).op(...)`";
      ]
    (fun () ->
      check_error
        (docs
       ^ {|
fn main() ! StoreDown uses Store, Docs =
  try Docs.at(DocId(1)) fn() =>
    try Docs.at(DocId(2)) fn() => Doc.text()
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 reject] an actor `at`-ing its own family" =
  until "s7"
    ~says:
      [
        "error: `doc` is an actor of `Docs`, so it can only `post` to it";
        "help: send it a message instead: `Docs.post(k).edit(...)`";
      ]
    (fun () ->
      check_error
        {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
handler doc(id: DocId) for Doc uses Docs =
  poke() => Docs.at(DocId(2)) fn() => Doc.poke()
fn main() uses Console =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:12
    4 │ dep Docs = Actors<DocId, Doc>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Docs` is a type, not a dependency
      ┌─ test.ren:5:37
    5 │ handler doc(id: DocId) for Doc uses Docs =
      │                                     ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
      ┌─ test.ren:6:18
    6 │   poke() => Docs.at(DocId(2)) fn() => Doc.poke()
      │                  ^^
      help: declare it under `type Docs`

    error: there's no function named `actors`
      ┌─ test.ren:8:8
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │        ^^^^^^

    error: `Docs` is a type, not a dependency
      ┌─ test.ren:8:23
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │                       ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
      ┌─ test.ren:8:36
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │                                    ^^
      help: declare it under `type Docs`
    |}]

let%expect_test "[s7 reject] an actor's handler takes one parameter, its key" =
  until "s7"
    ~says:
      [
        "error: `actors` makes each actor from its key, so `doc` takes one parameter, a `DocId`";
      ]
    (fun () ->
      check_error
        {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
handler doc(id: DocId, size: Int) for Doc =
  poke() => ()
fn main() =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:12
    4 │ dep Docs = Actors<DocId, Doc>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
      ┌─ test.ren:8:8
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │        ^^^^^^

    error: `Docs` is a type, not a dependency
      ┌─ test.ren:8:23
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │                       ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
      ┌─ test.ren:8:36
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │                                    ^^
      help: declare it under `type Docs`
    |}]

let%expect_test "[s7 reject] setup that fails with what the family doesn't declare" =
  until "s7"
    ~says:
      [
        "error: making a `doc` can fail with `StoreDown`, which `Docs` doesn't declare";
        "help: declare it on the family: `dep Docs = Actors<DocId, Doc> ! StoreDown`";
      ]
    (fun () ->
      check_error
        {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
fn load() -> Int ! StoreDown = 1
handler doc(id: DocId) for Doc =
  let n = try load()
  poke() => ()
fn main() =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:12
    4 │ dep Docs = Actors<DocId, Doc>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:10:8
    10 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
       │        ^^^^^^

    error: `Docs` is a type, not a dependency
       ┌─ test.ren:10:23
    10 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
       │                       ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ test.ren:10:36
    10 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
       │                                    ^^
       help: declare it under `type Docs`
    |}]

let%expect_test "[s7 reject] an actor's `finally` that can fail" =
  until "s7"
    ~says:
      [
        "error: an actor's `finally` can't fail";
        "help: save in the operations, write-through, or flush before the family ends: `Docs.each(fn() => try Doc.flush())`";
      ]
    (fun () ->
      check_error
        {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc> ! StoreDown
fn flush() ! StoreDown = ()
handler doc(id: DocId) for Doc =
  finally(r) =>
    try flush()
    try r
  poke() => ()
fn main() =
  with actors(doc) as Docs in
    match attempt Docs.at(DocId(1)) fn() => Doc.poke()
      _ => ()
|});
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
      ┌─ test.ren:4:31
    4 │ dep Docs = Actors<DocId, Doc> ! StoreDown
      │                               ^
    |}]

let%expect_test "[s7 reject] `Full` where waiting could close a cycle" =
  (* decision 18: a task that pins an actor may wait for a slot only in a
     family installed outside the ones it pins; anywhere else `Full` *)
  until "s7"
    ~says:[ "Err(Full)" ]
    (fun () ->
      run
        {|
type Key = | Key(n: Int)
dep Inner =
  poke: fn()
dep Outer =
  poke: fn()
dep Inners = Actors<Key, Inner>
dep Outers = Actors<Key, Outer>
handler inner(k: Key) for Inner =
  poke() => ()
handler outer(k: Key) for Outer =
  poke() => ()

fn main() uses Console, Async =
  with actors(outer, max: 1) as Outers, actors(inner, max: 1) as Inners in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Inners.at(Key(1)) fn() =>
          Async.yield()
          Inner.poke()
      s.spawn fn() =>
        Outers.at(Key(1)) fn() =>
          print(attempt Inners.at(Key(2)) fn() => Inner.poke())
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:6:14
    6 │ dep Inners = Actors<Key, Inner>
      │              ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Inner`, `Net`, `Os`, `Outer`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no dependency named `Actors`
      ┌─ test.ren:7:14
    7 │ dep Outers = Actors<Key, Outer>
      │              ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Inner`, `Net`, `Os`, `Outer`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:14:8
    14 │   with actors(outer, max: 1) as Outers, actors(inner, max: 1) as Inners in
       │        ^^^^^^

    error: `Outers` is a type, not a dependency
       ┌─ test.ren:14:33
    14 │   with actors(outer, max: 1) as Outers, actors(inner, max: 1) as Inners in
       │                                 ^^^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: there's no function named `actors`
       ┌─ test.ren:14:41
    14 │   with actors(outer, max: 1) as Outers, actors(inner, max: 1) as Inners in
       │                                         ^^^^^^

    error: `Inners` is a type, not a dependency
       ┌─ test.ren:14:66
    14 │   with actors(outer, max: 1) as Outers, actors(inner, max: 1) as Inners in
       │                                                                  ^^^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Inners` has no member named `at`
       ┌─ test.ren:17:16
    17 │         Inners.at(Key(1)) fn() =>
       │                ^^
       help: declare it under `type Inners`

    error: `Outers` has no member named `at`
       ┌─ test.ren:21:16
    21 │         Outers.at(Key(1)) fn() =>
       │                ^^
       help: declare it under `type Outers`

    error: `Inners` has no member named `at`
       ┌─ test.ren:22:32
    22 │           print(attempt Inners.at(Key(2)) fn() => Inner.poke())
       │                                ^^
       help: declare it under `type Inners`
    |}]

let%expect_test "[s7 accept] a journal of a run that evicts and remakes a key names each life, and replays" =
  (* `docs[DocId(1)]#1`, then `#2` once it's made again: version 3's made
     and evicted lines; and `ren replay` of it follows it *)
  until "s7"
    ~says:
      [
        "# ren journal 3";
        "made docs[DocId(1)]#1";
        "evicted docs[DocId(1)]#1";
        "made docs[DocId(1)]#2";
        "replayed";
      ]
    (fun () ->
      in_folder
        [
          ( "main.ren",
            {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
handler doc(id: DocId) for Doc uses Console =
  poke() => print(id)

fn main() uses Console =
  with actors(doc, max: 1) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.at(DocId(2)) fn() => Doc.poke()
    Docs.at(DocId(1)) fn() => Doc.poke()
|}
          );
        ]
        (fun () ->
          record ();
          replay "run.journal"));
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ main.ren:4:12
    4 │ dep Docs = Actors<DocId, Doc>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
      ┌─ main.ren:9:8
    9 │   with actors(doc, max: 1) as Docs in
      │        ^^^^^^

    error: `Docs` is a type, not a dependency
      ┌─ main.ren:9:31
    9 │   with actors(doc, max: 1) as Docs in
      │                               ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ main.ren:10:10
    10 │     Docs.at(DocId(1)) fn() => Doc.poke()
       │          ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ main.ren:11:10
    11 │     Docs.at(DocId(2)) fn() => Doc.poke()
       │          ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ main.ren:12:10
    12 │     Docs.at(DocId(1)) fn() => Doc.poke()
       │          ^^
       help: declare it under `type Docs`
    error: run.journal isn't a journal: it doesn't start as one does
      ┌─ run.journal:1:1
    1 │
      │ ^
      = a journal starts `# ren journal 2 · <program> · deps: <dependencies>`
      help: record one with `ren run --record <file.journal> <file.ren>`
    |}]

(* ---- s7: `post`, Erlang's cast ---- *)

let%expect_test "[s7 accept] a post's arguments are evaluated when it's posted" =
  until "s7"
    ~want:{|
a
()
|}
    (fun () ->
      run
        {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  all: fn() -> Str
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log =
  var text = ""
  put(s) => text = text.concat(s)
  all() => text

fn main() uses Console =
  with actors(log) as Logs in
    var s = "a"
    Logs.post(Key(1)).put(s)
    s = "b"
    Logs.at(Key(1)) fn() => print(Log.all())
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:5:12
    5 │ dep Logs = Actors<Key, Log>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Log`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:12:8
    12 │   with actors(log) as Logs in
       │        ^^^^^^

    error: `Logs` is a type, not a dependency
       ┌─ test.ren:12:23
    12 │   with actors(log) as Logs in
       │                       ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Logs` has no member named `post`
       ┌─ test.ren:14:10
    14 │     Logs.post(Key(1)).put(s)
       │          ^^^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `at`
       ┌─ test.ren:16:10
    16 │     Logs.at(Key(1)) fn() => print(Log.all())
       │          ^^
       help: declare it under `type Logs`
    |}]

let%expect_test "[s7 accept] posts from one task to one actor run in order, each as one operation" =
  until "s7"
    ~says:[ "✓ posts arrive in the order posted" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  all: fn() -> Str
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log =
  var text = ""
  put(s) => text = text.concat(s)
  all() => text

test "posts arrive in the order posted" =
  with actors(log, max: 1) as Logs in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Logs.post(Key(1)).put("a")
        Logs.post(Key(1)).put("b")
        Logs.post(Key(1)).put("c")
      s.spawn fn() => Logs.at(Key(2)) fn() => Log.put("x")
    Async.tick()
    Logs.at(Key(1)) fn() => assert Log.all() == "abc"
|}));
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:5:16
    5 │ pub dep Logs = Actors<Key, Log>
      │                ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Log`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:12:8
    12 │   with actors(log, max: 1) as Logs in
       │        ^^^^^^

    error: `Logs` is a type, not a dependency
       ┌─ test.ren:12:31
    12 │   with actors(log, max: 1) as Logs in
       │                               ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Logs` has no member named `post`
       ┌─ test.ren:15:14
    15 │         Logs.post(Key(1)).put("a")
       │              ^^^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `post`
       ┌─ test.ren:16:14
    16 │         Logs.post(Key(1)).put("b")
       │              ^^^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `post`
       ┌─ test.ren:17:14
    17 │         Logs.post(Key(1)).put("c")
       │              ^^^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `at`
       ┌─ test.ren:18:28
    18 │       s.spawn fn() => Logs.at(Key(2)) fn() => Log.put("x")
       │                            ^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `at`
       ┌─ test.ren:20:10
    20 │     Logs.at(Key(1)) fn() => assert Log.all() == "abc"
       │          ^^
       help: declare it under `type Logs`
    |}]

let%expect_test "[s7 accept] a post makes its actor, so setup's errors are the post's, and nothing is lost" =
  until "s7"
    ~want:{|
Err(StoreDown)
0
()
|}
    (fun () ->
      run
        (docs
       ^ {|
dep Notes = Actors<DocId, Note> ! StoreDown
dep Note =
  touch: fn()
handler note(id: DocId) for Note uses Store =
  let _ = try Store.load(id)
  touch() => ()

fn main() uses Console =
  with mem_store(), actors(note) as Notes in
    print(attempt Notes.post(DocId(-1)).touch())
    print(Notes.count())
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^

    error: expected a new line, found `!`
       ┌─ test.ren:31:33
    31 │ dep Notes = Actors<DocId, Note> ! StoreDown
       │                                 ^
    |}]

let%expect_test "[s7 accept] teardown delivers queued posts before the `finally`s" =
  until "s7"
    ~want:{|
got a
got b
done Key(1)
()
|}
    (fun () ->
      run
        {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log uses Console =
  finally(_) => print("done ".concat(show(k)))
  put(s) => print("got ".concat(s))

fn main() uses Console =
  with actors(log) as Logs in
    Logs.post(Key(1)).put("a")
    Logs.post(Key(1)).put("b")
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:12
    4 │ dep Logs = Actors<Key, Log>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Log`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
       ┌─ test.ren:10:8
    10 │   with actors(log) as Logs in
       │        ^^^^^^

    error: `Logs` is a type, not a dependency
       ┌─ test.ren:10:23
    10 │   with actors(log) as Logs in
       │                       ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Logs` has no member named `post`
       ┌─ test.ren:11:10
    11 │     Logs.post(Key(1)).put("a")
       │          ^^^^
       help: declare it under `type Logs`

    error: `Logs` has no member named `post`
       ┌─ test.ren:12:10
    12 │     Logs.post(Key(1)).put("b")
       │          ^^^^
       help: declare it under `type Logs`
    |}]

let%expect_test "[s7 accept] an actor posts to its own family" =
  until "s7"
    ~want:{|
pong from Key(2)
()
|}
    (fun () ->
      run
        {|
type Key = | Key(n: Int)
dep Peer =
  ping: fn(from: Key)
  pong: fn(from: Key)
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers, Console =
  ping(from) => Peers.post(from).pong(k)
  pong(from) => print("pong from ".concat(show(from)))

fn main() uses Console =
  with actors(peer) as Peers in
    Peers.post(Key(2)).ping(Key(1))
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:5:13
    5 │ dep Peers = Actors<Key, Peer>
      │             ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Peer`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Peers` is a type, not a dependency
      ┌─ test.ren:6:36
    6 │ handler peer(k: Key) for Peer uses Peers, Console =
      │                                    ^^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
      ┌─ test.ren:7:23
    7 │   ping(from) => Peers.post(from).pong(k)
      │                       ^^^^
      help: declare it under `type Peers`

    error: there's no function named `actors`
       ┌─ test.ren:11:8
    11 │   with actors(peer) as Peers in
       │        ^^^^^^

    error: `Peers` is a type, not a dependency
       ┌─ test.ren:11:24
    11 │   with actors(peer) as Peers in
       │                        ^^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
       ┌─ test.ren:12:11
    12 │     Peers.post(Key(2)).ping(Key(1))
       │           ^^^^
       help: declare it under `type Peers`
    |}]

let%expect_test "[s7 reject] posting an operation that returns a value" =
  until "s7"
    ~says:
      [
        "error: `text` gives a `Str`, which a post has nobody to give to";
        "help: use it inside the actor, or call it with `at`: `Docs.at(k) fn() => Doc.text()`";
      ]
    (fun () ->
      check_error
        (docs
       ^ {|
fn main() ! StoreDown uses Store, Docs =
  try Docs.post(DocId(1)).text()
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 reject] posting an operation that can fail" =
  until "s7"
    ~says:
      [
        "error: `edit` can fail with `StoreDown`, which a post has nobody to give to";
        "help: handle it inside the actor, or call it with `at`: `try Docs.at(k) fn() => try Doc.edit(...)`";
      ]
    (fun () ->
      check_error
        (docs
       ^ {|
fn main() ! StoreDown uses Store, Docs =
  try Docs.post(DocId(1)).edit("a")
|}));
  [%expect {|
    (until s7)
    error: expected a new line, found `!`
       ┌─ test.ren:29:31
    29 │ dep Docs = Actors<DocId, Doc> ! StoreDown
       │                               ^
    |}]

let%expect_test "[s7 accept] two actors posting to each other past `mailbox:` don't deadlock while an outside poster waits" =
  until "s7"
    ~says:[ "✓ siblings never wait; the outside does" ]
    (fun () ->
      test ~seeds:200
        (pub_all
         {|
type Key = | Key(n: Int)
dep Peer =
  ping: fn(left: Int)
  noted: fn()
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers =
  ping(left) =>
    let Key(n) = k
    if left > 0 then Peers.post(Key(3 - n)).ping(left - 1)
  noted() => ()

test "siblings never wait; the outside does" =
  with actors(peer, mailbox: 2) as Peers in
    Async.scope fn(s) =>
      s.spawn fn() => Peers.post(Key(1)).ping(3)
      s.spawn fn() =>
        for i in 0..5
          Peers.post(Key(2)).noted()
|}));
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:5:17
    5 │ pub dep Peers = Actors<Key, Peer>
      │                 ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Peer`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Peers` is a type, not a dependency
      ┌─ test.ren:6:40
    6 │ pub handler peer(k: Key) for Peer uses Peers =
      │                                        ^^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
      ┌─ test.ren:9:28
    9 │     if left > 0 then Peers.post(Key(3 - n)).ping(left - 1)
      │                            ^^^^
      help: declare it under `type Peers`

    error: there's no function named `actors`
       ┌─ test.ren:13:8
    13 │   with actors(peer, mailbox: 2) as Peers in
       │        ^^^^^^

    error: `Peers` is a type, not a dependency
       ┌─ test.ren:13:36
    13 │   with actors(peer, mailbox: 2) as Peers in
       │                                    ^^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
       ┌─ test.ren:15:29
    15 │       s.spawn fn() => Peers.post(Key(1)).ping(3)
       │                             ^^^^
       help: declare it under `type Peers`

    error: `Peers` has no member named `post`
       ┌─ test.ren:18:17
    18 │           Peers.post(Key(2)).noted()
       │                 ^^^^
       help: declare it under `type Peers`
    |}]

let%expect_test "[s7 reject] a chain reaction panics past twice `mailbox:`, with the high-water mark" =
  until "s7"
    ~says:
      [
        "panic: `Peers` has 5 posts queued, past twice its `mailbox:` of 2";
        "high-water mark";
      ]
    (fun () ->
      run_error
        {|
type Key = | Key(n: Int)
dep Peer =
  double: fn()
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers =
  double() =>
    let Key(n) = k
    Peers.post(Key(n + 1)).double()
    Peers.post(Key(n + 1)).double()

fn main() uses Console =
  with actors(peer, mailbox: 2) as Peers in
    Peers.post(Key(0)).double()
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:13
    4 │ dep Peers = Actors<Key, Peer>
      │             ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Peer`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Peers` is a type, not a dependency
      ┌─ test.ren:5:36
    5 │ handler peer(k: Key) for Peer uses Peers =
      │                                    ^^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
      ┌─ test.ren:8:11
    8 │     Peers.post(Key(n + 1)).double()
      │           ^^^^
      help: declare it under `type Peers`

    error: `Peers` has no member named `post`
      ┌─ test.ren:9:11
    9 │     Peers.post(Key(n + 1)).double()
      │           ^^^^
      help: declare it under `type Peers`

    error: there's no function named `actors`
       ┌─ test.ren:12:8
    12 │   with actors(peer, mailbox: 2) as Peers in
       │        ^^^^^^

    error: `Peers` is a type, not a dependency
       ┌─ test.ren:12:36
    12 │   with actors(peer, mailbox: 2) as Peers in
       │                                    ^^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Peers` has no member named `post`
       ┌─ test.ren:13:11
    13 │     Peers.post(Key(0)).double()
       │           ^^^^
       help: declare it under `type Peers`
    |}]

let%expect_test "[s7 accept] a post from inside `at` while the mailbox is full and its target isn't live completes" =
  (* research/actors-post/'s first counterexample, which the fixed rules
     make complete: the post from inside `at` makes room by delivering *)
  until "s7"
    ~want:{|
done
()
|}
    (fun () ->
      run
        {|
type Key = | Key(n: Int)
dep Doc =
  touch: fn()
dep Docs = Actors<Key, Doc>
handler doc(k: Key) for Doc =
  touch() => ()

fn main() uses Console, Async =
  with actors(doc, max: 1, mailbox: 1) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.post(Key(2)).touch()
      s.spawn fn() =>
        Docs.at(Key(1)) fn() => Docs.post(Key(2)).touch()
  print("done")
|});
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:4:12
    4 │ dep Docs = Actors<Key, Doc>
      │            ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: there's no function named `actors`
      ┌─ test.ren:9:8
    9 │   with actors(doc, max: 1, mailbox: 1) as Docs in
      │        ^^^^^^

    error: `Docs` is a type, not a dependency
      ┌─ test.ren:9:43
    9 │   with actors(doc, max: 1, mailbox: 1) as Docs in
      │                                           ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `post`
       ┌─ test.ren:11:28
    11 │       s.spawn fn() => Docs.post(Key(2)).touch()
       │                            ^^^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `at`
       ┌─ test.ren:13:14
    13 │         Docs.at(Key(1)) fn() => Docs.post(Key(2)).touch()
       │              ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `post`
       ┌─ test.ren:13:38
    13 │         Docs.at(Key(1)) fn() => Docs.post(Key(2)).touch()
       │                                      ^^^^
       help: declare it under `type Docs`
    |}]

let%expect_test "[s7 accept] a session looping an `at` operation that posts to a sibling is held at the edge" =
  (* the second counterexample: every call from outside is metered, so
     the index's mail never passes `mailbox:` plus one operation's posts *)
  until "s7"
    ~says:[ "✓ the session's posts stay within the bound" ]
    (fun () ->
      test ~seeds:100
        (pub_all
         {|
type Key = | Key(n: Int)
dep Doc =
  edit: fn()
  changed: fn()
dep Docs = Actors<Key, Doc>
handler doc(k: Key) for Doc uses Docs =
  edit() => Docs.post(Key(0)).changed()
  changed() => ()

test "the session's posts stay within the bound" =
  with actors(doc, mailbox: 4) as Docs in
    Docs.at(Key(1)) fn() =>
      for i in 0..50
        Doc.edit()
    assert Docs.high_water() <= 5
|}));
  [%expect {|
    (until s7)
    error: there's no dependency named `Actors`
      ┌─ test.ren:5:16
    5 │ pub dep Docs = Actors<Key, Doc>
      │                ^^^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Doc`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`

    error: `Docs` is a type, not a dependency
      ┌─ test.ren:6:38
    6 │ pub handler doc(k: Key) for Doc uses Docs =
      │                                      ^^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `post`
      ┌─ test.ren:7:18
    7 │   edit() => Docs.post(Key(0)).changed()
      │                  ^^^^
      help: declare it under `type Docs`

    error: there's no function named `actors`
       ┌─ test.ren:11:8
    11 │   with actors(doc, mailbox: 4) as Docs in
       │        ^^^^^^

    error: `Docs` is a type, not a dependency
       ┌─ test.ren:11:35
    11 │   with actors(doc, mailbox: 4) as Docs in
       │                                   ^^^^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `Docs` has no member named `at`
       ┌─ test.ren:12:10
    12 │     Docs.at(Key(1)) fn() =>
       │          ^^
       help: declare it under `type Docs`

    error: `Docs` has no member named `high_water`
       ┌─ test.ren:15:17
    15 │     assert Docs.high_water() <= 5
       │                 ^^^^^^^^^^
       help: declare it under `type Docs`
    |}]

(* ---- s8: the milestone, in miniature (bench/services/docs is the whole one) ---- *)

let%expect_test "[s8 accept] the document server's actors under chaos eviction keep every edit" =
  until "s8"
    ~says:[ "✓ every edit is in the store, in one order" ]
    (fun () ->
      test ~seeds:100
        (pub_all
         (docs
       ^ {|
import sim

wiring live provides Docs uses Console = mem_store(), actors(doc, max: 2) as Docs

test "every edit is in the store, in one order" =
  with sim.scheduler(3, evict: AnyIdle) in
    with live in
      Async.scope fn(s) =>
        for n in 0..3
          s.spawn fn() =>
            let _ = attempt Docs.at(DocId(n % 2)) fn() =>
              let _ = attempt Doc.edit("x")
              ()
      let t = attempt Docs.at(DocId(0)) fn() => Doc.text()
      assert t == Ok("xx")
|})));
  [%expect {|
    (until s8)
    error: expected a new line, found `!`
       ┌─ test.ren:29:35
    29 │ pub dep Docs = Actors<DocId, Doc> ! StoreDown
       │                                   ^

    error: imports go at the top of the file
       ┌─ test.ren:31:1
    31 │ import sim
       │ ^^^^^^^^^^
       help: move it above the file's first function or type

    error: expected `fn`, `type`, `dep`, `handler`, `test` or `group`, found `wiring`
       ┌─ test.ren:33:5
    33 │ pub wiring live provides Docs uses Console = mem_store(), actors(doc, max: 2) as Docs
       │     ^^^^^^
       help: only imports, function, type, dependency and handler definitions, tests and groups can appear at the top level (for now)

    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:41:17
    41 │             let _ = attempt Docs.at(DocId(n % 2)) fn() =>
       │                 ^
       help: add the value this block should produce as its last line
    |}]
