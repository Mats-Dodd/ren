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
         that's a variant written bare, with no fields or defaults for all
     s5  pull arguments to `Async.each` and `Async.map`, channels as
         dependencies with `items()`, and `Async.produce` with `Send<T>`
     s6  the keyed instance family, `D.Call`, and `striped` in Ren over
         them, which replaces `sync.keyed`
     s7  `actors` in Ren over the family, then `post`, a trailing call of
         `D.Call`, and `chaos: true`
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
fn twice(s: Str) -> Str = s + s
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
  get(id) => "ann" + show(id)

handler pg_db(url: Str) for Db uses Console =
  get(id) =>
    print("pg " + url)
    "pg" + show(id)

handler console_audit() for Audit uses Console =
  note(s) => print("audit: " + s)

handler db_users() for Users uses Db, Audit =
  name(id) =>
    Audit.note(show(id))
    try Db.get(id)
|}

let%expect_test "[s2 accept] a wiring is flattened where it's used" =
  (* `live` names three handlers; the body sees only `Users` *)
  run
    (users_deps
   ^ {|
wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()

fn main() uses Console =
  with live("main") in print(attempt Users.name(7))
|});
  [%expect {|
    audit: 7
    pg main
    Ok("pg7")
    ()
    |}]

let%expect_test "[s2 accept] an item beside a wiring meets what the wiring installs" =
  (* one set, one instance of each: `counted()` shares `live`'s `Db` *)
  run
    (users_deps
   ^ {|
dep Count =
  hit: fn() -> Str ! DbDown

handler counted() for Count uses Db, Console =
  var n = 0
  hit() =>
    n += 1
    print("counted " + show(n))
    try Db.get(n)

wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with live, counted() in print(attempt Count.hit())
|});
  [%expect {|
    counted 1
    Ok("ann1")
    ()
    |}]

let%expect_test "[s2 accept] wirings combine and nest, and a test splits one" =
  (* language.md §5's "Tests: split the wiring, don't patch it": `core`
     needs `Db`; `live` adds the real one, a test a memory one. A test
     sees what an importer sees, so `core` is `pub` here, its needs
     written *)
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
|}));
  [%expect {|
    test.ren
      ✓ a lookup is audited

    1 passed
    [exit 0]
    |}]

let%expect_test "[s2 accept] a wiring's parameter can be a description" =
  (* functor-style: `app(db: Db)` installs the `Db` it's given *)
  run
    (users_deps
   ^ {|
wiring app(db: Db) provides Users = db, console_audit(), db_users()

fn main() uses Console =
  with app(mem_db()) in print(attempt Users.name(3))
|});
  [%expect {|
    audit: 3
    Ok("ann3")
    ()
    |}]

let%expect_test "[s2 accept] a wiring fails to start with its items' errors, installed with `try with`" =
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
|});
  [%expect {|
    Err(DbDown)
    ()
    |}]

let%expect_test "[s2 accept] teardown runs `finally` in reverse install order" =
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
|};
  [%expect {|
    in body
    users done
    db done
    audit done
    ()
    |}]

let%expect_test "[s2 accept] a plain `with` still exposes everything it installs" =
  run
    (users_deps
   ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with mem_db() in print(attempt Db.get(5))
|});
  [%expect {|
    Ok("ann5")
    ()
    |}]

let%expect_test "[s2 accept] a private wiring's `uses` and `!` are inferred, a `pub` one's written" =
  (* `core`'s audit keeps quiet, so all it needs from outside is `Db`;
     `live`'s `pg_db` prints *)
  types
    (users_deps
   ^ {|
handler quiet_audit() for Audit =
  note(_) => ()

pub wiring core provides Users uses Db = quiet_audit(), db_users()
wiring live(url: Str) provides Users = core, pg_db(url)
fn main() = 1
|});
  [%expect {|
    dep Db
      get: fn(Int) -> Str ! DbDown
    dep Audit
      note: fn(Str)
    dep Users
      name: fn(Int) -> Str ! DbDown
    handler mem_db() for Db
    handler pg_db(url: Str) for Db uses Console
    handler console_audit() for Audit uses Console
    handler db_users() for Users uses Audit, Db
    handler quiet_audit() for Audit
    fn main() -> Int
    pub wiring core provides Users uses Db
    wiring live(url: Str) provides Users uses Console
    |}]

let%expect_test "[s2 accept] a pub wiring used from another module" =
  run_files
    [
      ( "main.ren",
        {|
import app

fn main() uses Console =
  with app.live in print(attempt app.Users.name(4))
|} );
      ( "app.ren",
        pub_all users_deps
        ^ {|
pub wiring live provides Users uses Console = mem_db(), console_audit(), db_users()
|} );
    ];
  [%expect {|
    audit: 4
    Ok("ann4")
    ()
    |}]

let%expect_test "[s2 reject] a missing need" =
  check_error
    (users_deps
   ^ {|
wiring live provides Users = console_audit(), db_users()

fn main() uses Console =
  with live in print(attempt Users.name(1))
|});
  [%expect {|
    error: nothing installs `Db`, which `db_users()` in `live` needs
       ┌─ test.ren:27:8
    24 │ wiring live provides Users = console_audit(), db_users()
       │        ---- `live` lists `db_users()` here
    27 │   with live in print(attempt Users.name(1))
       │        ^^^^
       help: add an item that installs `Db` beside `live`: `with live, mem_db() in`
    |}]

let%expect_test "[s2 reject] a pub wiring's need it doesn't declare" =
  check_error
    (users_deps
   ^ {|
pub wiring live provides Users = console_audit(), db_users()
fn main() = 1
|});
  [%expect {|
    error: `live` needs `Console`, which it doesn't declare
       ┌─ test.ren:24:12
    24 │ pub wiring live provides Users = console_audit(), db_users()
       │            ^^^^
       │                                  --------------- `console_audit()` needs `Console`
       = a public wiring's `uses` lists what it needs from outside, which is what a `with` that lists it has to have
       help: add it to `uses`: `uses Console`

    error: `live` needs `Db`, which it doesn't declare
       ┌─ test.ren:24:12
    24 │ pub wiring live provides Users = console_audit(), db_users()
       │            ^^^^
       │                                                   ---------- `db_users()` needs `Db`
       = a public wiring's `uses` lists what it needs from outside, which is what a `with` that lists it has to have
       help: add it to `uses`: `uses Db`
    |}]

let%expect_test "[s2 reject] a hidden service used" =
  check_error
    (users_deps
   ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()

fn main() uses Console =
  with live in print(attempt Db.get(1))
|});
  [%expect {|
    error: `live` installs `Db` but doesn't provide it
       ┌─ test.ren:27:30
    27 │   with live in print(attempt Db.get(1))
       │                              ^^^^^^^^^
       = a wiring's items meet each other, but what's listed beside it and the body see only what its `provides` says
       help: add `Db` to `live`'s `provides`, or install your own inside: `with mem_db() in`
    |}]

let%expect_test "[s2 reject] a duplicate through flattening" =
  check_error
    (users_deps
   ^ {|
wiring live(url: Str) provides Users = pg_db(url), console_audit(), db_users()

fn main() uses Console =
  with live("x"), mem_db() in print(attempt Users.name(1))
|});
  [%expect {|
    error: this `with` installs `Db` twice: `mem_db()` here, and `pg_db(url)` in `live` (test.ren:24)
       ┌─ test.ren:27:19
    27 │   with live("x"), mem_db() in print(attempt Users.name(1))
       │                   ^^^^^^^^ and again here
       │        --------- `live` installs `Db` here
       = a wiring is flattened where it's listed: its items are the `with`'s
       help: use a smaller wiring that leaves `Db` out, or remove one
    |}]

let%expect_test "[s2 reject] a cycle through wirings" =
  check_error
    (users_deps
   ^ {|
wiring a provides Users = b, db_users()
wiring b provides Audit = a, console_audit()
fn main() = 1
|});
  [%expect {|
    error: `a` lists itself: a → b → a
       ┌─ test.ren:24:8
    24 │ wiring a provides Users = b, db_users()
       │        ^
       help: a wiring can list another, but not one that lists it
    |}]

let%expect_test "[s2 reject] a cycle among the items a wiring flattens" =
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
|};
  [%expect {|
    error: `ping()` and `pong()` in `both` each need what the other installs
      ┌─ test.ren:9:29
    9 │ wiring both provides Ping = ping(), pong()
      │                             ^^^^^^
      = `ping()` → `pong()` → `ping()`
      help: install one of them in a `with` around this one
    |}]

let%expect_test "[s2 reject] `provides` names what nothing installs" =
  check_error
    (users_deps
   ^ {|
wiring live provides Users, Clock = mem_db(), console_audit(), db_users()
fn main() = 1
|});
  [%expect {|
    error: `live` provides `Clock`, which nothing in it installs
       ┌─ test.ren:24:8
    24 │ wiring live provides Users, Clock = mem_db(), console_audit(), db_users()
       │        ^^^^
       help: remove it from `provides`, or add an item that installs it
    |}]

let%expect_test "[s2 reject] an item nothing uses" =
  check_error
    (users_deps
   ^ {|
handler plain_users() for Users uses Db =
  name(id) => try Db.get(id)
wiring live provides Users = mem_db(), console_audit(), plain_users()
fn main() = 1
|});
  [%expect {|
    error: `console_audit()` in `live` provides `Audit`, which nothing needs
       ┌─ test.ren:26:40
    26 │ wiring live provides Users = mem_db(), console_audit(), plain_users()
       │                                        ^^^^^^^^^^^^^^^
       = Ren has no warnings: what nothing uses is an error
       help: remove it, or add `Audit` to `live`'s `provides`
    |}]

let%expect_test "[s2 reject] a wiring used as a value" =
  check_error
    (users_deps
   ^ {|
wiring live provides Users = mem_db(), console_audit(), db_users()
fn main() =
  let w = live
  1
|});
  [%expect {|
    error: a wiring isn't a value
       ┌─ test.ren:26:11
    26 │   let w = live
       │           ^^^^
       help: install it: `with live in ...`
    |}]

let%expect_test "[s2 reject] a wiring with no `provides`" =
  check_error
    (users_deps
   ^ {|
wiring live = mem_db(), console_audit(), db_users()
fn main() = 1
|});
  [%expect {|
    error: a wiring says what it provides
       ┌─ test.ren:24:13
    24 │ wiring live = mem_db(), console_audit(), db_users()
       │             ^
       help: write `provides` and the dependencies the body may call
    |}]

let%expect_test "[s2 reject] a wiring's body is items only" =
  check_error
    (users_deps
   ^ {|
wiring live provides Users =
  print("starting")
  mem_db()
fn main() = 1
|});
  [%expect {|
    error: a wiring's body lists what it installs
       ┌─ test.ren:26:3
    26 │   mem_db()
       │   ^
       help: code that runs around a block stays a function: `fn live(body: fn() -> T) -> T`
    |}]

let%expect_test "[s2 reject] `provides` names what a nested wiring hides" =
  check_error
    (users_deps
   ^ {|
wiring core provides Users = console_audit(), db_users()
wiring live provides Users, Audit = core, mem_db()
fn main() = 1
|});
  [%expect {|
    error: `core` installs `Audit` but doesn't provide it
       ┌─ test.ren:25:37
    25 │ wiring live provides Users, Audit = core, mem_db()
       │                                     ^^^^
       = a wiring's items meet each other, but what's listed beside it and the body see only what its `provides` says
       help: add `Audit` to `core`'s `provides`
    |}]

(* ---- s3: background work (decision 7) ---- *)

let ticks_dep =
  {|
dep Ticks =
  tick: fn()

handler ticks() for Ticks uses Console =
  var n = 0
  finally(r) =>
    print("ticks: " + show(n))
    try r
  tick() => n += 1
|}

let%expect_test "[s3 reject] a task that reaches a handler installed inside its scope" =
  (* what 11a cancelled when the `with`'s body ended is a compile error
     now, whose help opens the scope inside the `with` *)
  check_error
    (ticks_dep
   ^ {|
fn main() uses Console, Async =
  Async.scope fn(s) =>
    with ticks() in
      s.spawn fn() => Ticks.tick()
|});
  [%expect {|
    error: this task can reach `Ticks`, installed inside the scope it's spawned into
       ┌─ test.ren:14:7
    13 │     with ticks() in
       │     --------------- `Ticks` is installed here, inside the scope
    14 │       s.spawn fn() => Ticks.tick()
       │       ^^^^^^^
       help: open the scope inside the `with`: `with ticks() in Async.scope fn(s) => ...`, or run it beside the body with `Async.beside`
    |}]

let%expect_test "[s3 reject] a helper hides which scope is inner: the run time's check" =
  (* `start` is handed the scope from outside the `with`, which only the
     run time can see: a panic at the spawn *)
  run_error
    (ticks_dep
   ^ {|
fn start(s: Scope) uses Ticks, Async =
  s.spawn fn() => Ticks.tick()

fn main() uses Console, Async =
  Async.scope fn(s) =>
    with ticks() in
      start(s)
|});
  [%expect {|
    error: panic: this task can reach `Ticks`, installed inside the scope it's spawned into
       ┌─ test.ren:12:3
    12 │   s.spawn fn() => Ticks.tick()
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       help: open the scope inside the `with`
    |}]

let%expect_test "[s3 accept] `Async.beside` cancels its task when the body ends, before the `finally`" =
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
|});
  [%expect {|
    ticks: 3
    after
    ()
    |}]

let%expect_test "[s3 accept] a pool's order: the work drains, the background stops, then `finally`" =
  (* decision 7: `with pool() in Async.beside(health) fn() =>
     Async.scope ...` *)
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
  finally(r) =>
    print("health stopped")
    try r
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
|};
  [%expect {|
    work done
    health stopped
    pool closed
    ()
    |}]

let%expect_test "[s3 accept] a background failure cancels the body and is its error" =
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
|};
  [%expect {|
    body cancelled
    Err(LeaseLost)
    ()
    |}]

let%expect_test "[s3 accept] `Async.background`: tasks spawned as the body goes, stopped when it ends" =
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
|});
  [%expect {|
    body done
    ticks: 2
    ()
    |}]

let%expect_test "[s3 accept] `Async.background`'s first failure cancels the body" =
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
|};
  [%expect {|
    Err(Gone)
    ()
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
|};
  [%expect {|
    1
    2
    ()
    |}]

let%expect_test "[s4 accept] `release` lets other callers in while the call runs" =
  (* the slow call is in `Next.get`, released: the second caller's
     operation runs meanwhile, which it couldn't without `release` *)
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

fn main() uses Console, Async, Clock =
  with next(), front() in
    Async.scope fn(s) =>
      s.spawn fn() => print("slow " + show(Front.ask(1)))
      s.spawn fn() => print("fast " + show(Front.ask(2)))
|};
  [%expect {|
    fast 2
    slow 1
    ()
    |}]

let%expect_test "[s4 accept] state written before a `release` and read after it is the cells'" =
  (* the arm's copies are written back before the call and read again
     after, as `Async.until`'s are: the other caller's change is seen *)
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

fn main() uses Console, Async, Clock =
  with next(), front() in
    Async.scope fn(s) =>
      s.spawn fn() => print(Front.ask(100))
      s.spawn fn() =>
        let _ = Front.ask(1)
        ()
|};
  [%expect {|
    2
    ()
    |}]

let%expect_test "[s4 accept] `try release` on a call that can fail" =
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
|};
  [%expect {|
    Err(Down)
    ()
    |}]

let%expect_test "[s4 accept] `release` in a block inside an arm" =
  (* the arm's state is the arm's locals, which the block captures: the
     write-back and the reads again are the arm's, natively too *)
  run
    {|
dep Next =
  get: fn(id: Int) -> Int
dep Front =
  ask: fn(ids: Array<Int>) -> Int

handler next() for Next =
  get(id) => id

handler front() for Front uses Next =
  var total = 0
  ask(ids) =>
    let got = ids.map(fn(i) => release Next.get(i))
    for g in got
      total += g
    total

fn main() uses Console =
  with next(), front() in
    print(Front.ask([1, 2, 3]))
    print(Front.ask([4]))
|};
  [%expect {|
    6
    10
    ()
    |}]

let%expect_test "[s4 accept] a stale read across `release` is found by a seed, and the fix holds" =
  (* decision 10: `sim` switches tasks at every `release`, so a value read
     from state before one and written after loses an update *)
      test ~seeds:200
        (pub_all
         {|
dep Next =
  get: fn() -> Int
dep Count =
  add: fn()
  bad_add: fn()
  total: fn() -> Int

handler next() for Next =
  get() => 1

handler count() for Count uses Next =
  var n = 0
  bad_add() =>
    let before = n
    let k = release Next.get()
    n = before + k
  add() =>
    let k = release Next.get()
    n += k
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
|});
  [%expect {|
    test.ren
      ✗ two counts both land
      ✓ the fix reads after

    ──── two counts both land ── test.ren:27
       │
    27 │     assert Count.total() == 2
       │            ^^^^^^^^^^^^^^^^^^
       │
       left:  1
       right: 2
              ^ differs here

       seed 2979 · rerun: ren test test.ren --only "two counts" --seed 2979

    1 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s4 reject] `release` outside a handler's operation" =
      check_error
        {|
dep Next =
  get: fn() -> Int
handler next() for Next =
  get() => 1
fn main() -> Int = with next() in release Next.get()
|};
  [%expect {|
    error: `release` lets go of a handler's instance, so it's only written in one of its operations
      ┌─ test.ren:5:35
    5 │ fn main() -> Int = with next() in release Next.get()
      │                                   ^^^^^^^^^^^^^^^^^^
      help: call it without `release`
    |}]

let%expect_test "[s4 reject] `release` on what isn't a dependency's operation" =
      check_error
        {|
dep Front =
  ask: fn() -> Int
fn twice(n: Int) -> Int = n * 2
handler front() for Front =
  ask() => release twice(1)
fn main() = 1
|};
  [%expect {|
    error: `release` lets go of the instance for one call of another dependency's operation, and `twice(1)` isn't one
      ┌─ test.ren:5:20
    5 │   ask() => release twice(1)
      │                    ^^^^^^^^
      help: write it on the operation's call: `release Next.get(id)`
    |}]

let%expect_test "[s4 accept] an actor-shaped handler loops over a reader in its state while it calls another service" =
  (* decision 2's row narrowed to `Async.until`, `release` and block
     parameters: a dependency call holds none of the handler's state *)
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
|};
  [%expect {|
    3
    ()
    |}]

let%expect_test "[s4 accept] state borrowed across `release` is still refused" =
  (* `release` is one of the three in decision 2's row: the state can
     change during it *)
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

fn main() = 1
|};
  [%expect {|
    error: `r` is changed across a call that lets go of the handler
       ┌─ test.ren:20:15
    19 │     for x in &r
       │              -- changed for the whole loop
    20 │       release Sink.put(x)
       │               ^^^^^^^^^^^ lets go of the handler
       = at `release` and `Async.until` other tasks run the handler
       help: make the call before or after the loop
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
|};
  [%expect {|
    error: panic: every task is waiting, and nothing can wake one
       ┌─ test.ren:24:5
    24 │     Async.scope fn(s) =>
       │     ^^^^^^^^^^^^^^^^^^^^
       = main waits for its scope's tasks at test.ren:24:5
       = main/main:0 waits in `Async.until` at test.ren:10:13, holding `A` (a.go)
       = main/main:1 waits for `A`, which another task is in at test.ren:26:23
    |}]

let%expect_test "[s4 accept] `sim` chooses fairly among an instance's waiters and arrivals" =
  (* decision 10: the queue is fair, not first in first out, and `sim`
     chooses among the waiters and a caller that arrives as the instance
     is released from its tape. Task 4 arrives just as task 1 lets go,
     after 2 and 3 have queued: first in first out it's never second, and
     under some seed it is *)
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
|});
  [%expect {|
    test.ren
      ✗ a caller arriving as it's released never overtakes the queue

    ──── a caller arriving as it's released never overtakes the queue ── test.ren:25
       │
    25 │     assert Gate.second() != 4
       │            ^^^^^^^^^^^^^^^^^^
       │
       this is false

       seed 2364 · rerun: ren test test.ren --only "a caller" --seed 2364

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s4 accept] a default that's a variant with no fields" =
  (* What's decided 11: `kill: Kill = Tree` *)
      run
        {|
type Mode = | Gentle | Hard

fn stop(n: Int, how: Mode = Gentle) -> Mode = how

fn main() uses Console =
  print(stop(1))
  print(stop(1, how: Hard))
|};
  [%expect {|
    Gentle
    Hard
    ()
    |}]

let%expect_test "[s4 accept] a default that's a variant whose fields all have defaults" =
  (* What's decided 11: `by: By = Key` is `Key(n: 16)`; a field with a
     default is left out, or given by name *)
      run
        {|
type Mode = | Gentle(ms: Int = 5) | Hard

fn stop(n: Int, how: Mode = Gentle) -> Mode = how

fn main() uses Console =
  print(stop(1))
  print(stop(1, how: Gentle(ms: 9)))
  print(Gentle)
|};
  [%expect {|
    Gentle(5)
    Gentle(9)
    Gentle(5)
    ()
    |}]

let%expect_test "[s4 reject] a default that's a variant written with arguments" =
      check_error
        {|
type Mode = | Gentle | After(ms: Int)
fn stop(n: Int, how: Mode = After(5)) -> Mode = how
fn main() = 1
|};
  [%expect {|
    error: a parameter's default is a literal, or a variant written bare
      ┌─ test.ren:2:29
    2 │ fn stop(n: Int, how: Mode = After(5)) -> Mode = how
      │                             ^^^^^
      help: give it where it's called instead
    |}]

let%expect_test "[s4 accept] `Proc.run(kill:)`: `sim.proc()` says how each cancelled run was killed" =
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
|});
  [%expect {|
    test.ren
      ✓ a cancelled run is killed with its process group

    1 passed
    [exit 0]
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
  run
    (cursor_type
   ^ {|
fn main() uses Console, Async =
  print(Async.map(Count { at: 0, to: 3 }) fn(x) => x * 2)
|});
  [%expect {|
    [2, 4, 6]
    ()
    |}]

let%expect_test "[s5 accept] `Async.each` over a named cursor, `&r`, which goes on after" =
  (* `&r` is pulled in its place, so `r` is where the call left it: at its
     end *)
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
  print(&r.next())
  var s = Count { at: 0, to: 4 }
  print(&s.next())
  print(Async.map(&s) fn(x) => x)
|});
  [%expect {|
    10
    None
    Some(1)
    [2, 3, 4]
    ()
    |}]

let%expect_test "[s5 accept] `Async.each` over a hand-written block" =
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
|};
  [%expect {|
    3
    ()
    |}]

let%expect_test "[s5 accept] a collection is pulled by a snapshot of it" =
  run
    {|
fn main() uses Console, Async =
  var xs = [1, 2, 3]
  print(Async.map(xs) fn(x) => x * 10)
  print(Async.map(Map.of([("a", 1), ("b", 2)])) fn(e) => e)
  print(Async.map(Set.of([5, 6])) fn(x) => x + 1)
|};
  [%expect {|
    [10, 20, 30]
    [("a", 1), ("b", 2)]
    [6, 7]
    ()
    |}]

let%expect_test "[s5 accept] a function's own pull parameter takes what `for` takes" =
  (* streams.md, rule 3: a block parameter `fn() -> Option<T>` is a pull
     parameter, a user's as `Async.map`'s *)
  run
    (cursor_type
   ^ {|
fn total(xs: fn() -> Option<Int>) -> Int =
  var t = 0
  for x in try xs
    t += x
  t

fn bad() -> Option<Int> ! Broken = fail Broken

fn main() uses Console =
  print(total([1, 2, 3]))
  print(total(Count { at: 0, to: 3 }))
  var r = Count { at: 0, to: 2 }
  print(total(&r))
  print(&r.next())
  print(attempt total(fn() => try bad()))
|});
  [%expect {|
    6
    6
    3
    None
    Err(Broken)
    ()
    |}]

let%expect_test "[s5 reject] a named cursor passed to `Async.each` while the block touches it" =
  (* decision 2's new row: `&r` as a pull argument is a write, held for
     the call *)
  check_error
    (cursor_type
   ^ {|
fn main() uses Async =
  var r = Count { at: 0, to: 4 }
  Async.each(&r) fn(x) =>
    let _ = r.at
    ()
|});
  [%expect {|
    error: `r` is read by this block while the call changes it
       ┌─ test.ren:11:13
    10 │   Async.each(&r) fn(x) =>
       │              -- changed for the whole call
    11 │     let _ = r.at
       │             ^^^^ read here
       = a block runs during the call it's passed to
       help: read it first: `let at = r.at`, and use `at` in the block
    |}]

let%expect_test "[s5 reject] `&` on a collection given to a pull parameter" =
  check_error
    {|
fn main() uses Async =
  var xs = [1, 2]
  Async.each(&xs) fn(x) => ()
|};
  [%expect {|
    error: `Async.each` doesn't change this argument
      ┌─ test.ren:3:14
    3 │   Async.each(&xs) fn(x) => ()
      │              ^^^
      = `&` marks an argument the call changes: an `inout` parameter
      help: remove the `&`
    |}]

let%expect_test "[s5 accept] pulled on the caller's task only when a slot frees" =
  (* `max: 1`: each item is pulled after the one before has ended *)
  run
    {|
dep Src =
  pull: fn() -> Option<Int>

handler src() for Src uses Console =
  var n = 0
  pull() =>
    n += 1
    print("pulled " + show(n))
    if n > 2 then None else Some(n)

fn main() uses Console, Async =
  with src() in
    Async.each(fn() => Src.pull(), max: 1) fn(x) => print("ran " + show(x))
|};
  [%expect {|
    pulled 1
    ran 1
    pulled 2
    ran 2
    pulled 3
    ()
    |}]

let%expect_test "[s5 accept] a pull argument that fails is the call's failure" =
  run
    {|
dep Src =
  pull: fn() -> Option<Int> ! Dry

handler src() for Src =
  var n = 0
  pull() =>
    n += 1
    if n > 2 then fail Dry else Some(n)

fn main() uses Console, Async =
  with src() in
    print(attempt Async.map(fn() => try Src.pull(), max: 1) fn(x) => x)
|};
  [%expect {|
    Err(Dry)
    ()
    |}]

let%expect_test "[s5 accept] a channel is a dependency, and `items()` pulls `recv()`" =
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
|};
  [%expect {|
    1
    2
    3
    ()
    |}]

let%expect_test "[s5 accept] a channel's `items()` as a pull argument" =
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
|};
  [%expect {|
    [10, 20]
    ()
    |}]

let%expect_test "[s5 accept] two channels of one element type don't mix where each is named" =
  run
    {|
import sync.{Chan}

dep Events = Chan<Int>
dep Done = Chan<Int>

fn main() uses Console, Async =
  with sync.channel(4) as Events, sync.channel(4) as Done, sync.channel(4) in
    Events.send(1)
    Events.close()
    Done.send(2)
    Done.close()
    Chan.send(3)
    Chan.close()
    for e in Events.items()
      print(("events", e))
    for d in Done.items()
      print(("done", d))
    for c in Chan.items()
      let x: Int = c
      print(("chan", x))
|};
  [%expect {|
    ("events", 1)
    ("done", 2)
    ("chan", 3)
    ()
    |}]

let%expect_test "[s5 reject] `items()` where it isn't pulled" =
  check_error
    {|
import sync.{Chan}
dep Events = Chan<Int>
fn main() uses Events =
  let xs = Events.items()
  ()
|};
  [%expect {|
    error: nothing installs `Events` before `main`
      ┌─ test.ren:3:16
    3 │ fn main() uses Events =
      │                ^^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    4 │   let xs = Events.items()
      │            -------------- this call uses `Events`
      help: install one inside `main`, with `with`: `with h() in ...`, for a handler `h` for `Events`

    error: `Events.items()` is pulled where it's written: in a `for`, or as a pull argument
      ┌─ test.ren:4:12
    4 │   let xs = Events.items()
      │            ^^^^^^^^^^^^^^
      = its `next` runs with what the alias names only where it's written, on the task that pulls it
      help: loop over it: `for e in Events.items()`
    |}]

let%expect_test "[s5 accept] `Async.produce`: the producer sends through `Send<T>`, the body pulls" =
  (* `count_to` can't fail, so neither can `items`, and `for` takes it with
     no `try` *)
  run
    {|
fn count_to(n: Int) uses Send<Int> =
  for i in 1..n + 1
    Send.send(i)

fn main() uses Console, Async =
  Async.produce(cap: 2, fn() => count_to(3)) fn(items) =>
    for x in items
      print(x)
|};
  [%expect {|
    1
    2
    3
    ()
    |}]

let%expect_test "[s5 accept] a `break` in `produce`'s body cancels and waits for the producer" =
  run
    {|
dep Stopped =
  noted: fn()

handler stopped() for Stopped uses Console =
  finally(r) =>
    print("producer stopped")
    try r
  noted() => ()

fn forever() uses Send<Int>, Console =
  with stopped() in
    var i = 0
    while true
      i += 1
      Send.send(i)

fn main() uses Console, Async =
  Async.produce(fn() => forever()) fn(items) =>
    for x in items
      print(x)
      break
  print("after")
|};
  [%expect {|
    1
    producer stopped
    after
    ()
    |}]

let%expect_test "[s5 accept] a producer blocked at `cap` makes progress as the consumer takes" =
  test ~seeds:1000
    (pub_all
       {|
fn many() uses Send<Int> =
  for i in 0..20
    Send.send(i)

test "a slow consumer still gets everything, in order" =
  var got: Array<Int> = []
  Async.produce(cap: 1, fn() => many()) fn(items) =>
    for x in items
      Async.yield()
      &got.push(x)
  assert got == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
|});
  [%expect {|
    test.ren
      ✓ a slow consumer still gets everything, in order

    1 passed, each under 1000 seeds
    [exit 0]
    |}]

let%expect_test "[s5 accept] a failure in the producer ends the stream with it" =
  (* what was sent before it is taken first; the call fails with it, so
     it's marked `try` *)
  run
    {|
fn one_then_fail() ! Broken uses Send<Int> =
  Send.send(1)
  fail Broken

fn consume() ! Broken uses Console, Async =
  try Async.produce(fn() => try one_then_fail()) fn(items) =>
    for x in try items
      print(x)

fn main() uses Console, Async = print(attempt consume())
|};
  [%expect {|
    1
    Err(Broken)
    ()
    |}]

let%expect_test "[s5 reject] `produce`'s `cap` is 0" =
  run_error
    {|
fn none() uses Send<Int> = ()

fn main() uses Console, Async =
  Async.produce(cap: 0, fn() => none()) fn(items) =>
    for x in items
      print(x)
|};
  [%expect {|
    error: panic: `Async.produce`'s `cap` is 0, so nothing could be sent
      ┌─ test.ren:4:3
    4 │   Async.produce(cap: 0, fn() => none()) fn(items) =>
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      help: `cap:` is at least 1
    |}]

let%expect_test "[s5 accept] `Async.map_pull`: results as a stream, in order" =
  run
    {|
fn main() uses Console, Async =
  var out: Array<Int> = []
  Async.map_pull([1, 2, 3], max: 2, fn(x) => x * x) fn(results) =>
    for r in results
      &out.push(r)
  print(out)
|};
  [%expect {|
    [1, 4, 9]
    ()
    |}]

let%expect_test "[s5 accept] pull arguments, channels and producers under seeds" =
  (* each of step 5's, where the order its tasks run in varies with the
     seed: what's asserted holds under every one *)
  test ~seeds:1000
    (pub_all
       {|
import sync.{Chan}

type Count = opaque { at: Int, to: Int }
  pub fn next(inout self) -> Option<Int> =
    if self.at >= self.to then None
    else
      self.at += 1
      Some(self.at)

fn upto(n: Int) -> Count = Count { at: 0, to: n }

dep Events = Chan<Int>

fn many(n: Int) uses Send<Int> =
  for i in 0..n
    Send.send(i)

fn fails_at(n: Int) ! Broken uses Send<Int> =
  for i in 0..n
    Send.send(i)
  fail Broken

fn drained(n: Int) -> Array<Int> ! Broken uses Async =
  var got: Array<Int> = []
  try Async.produce(cap: 2, fn() => try fails_at(n)) fn(items) =>
    for x in try items
      &got.push(x)
  got

test "`map` over a cursor keeps its order" =
  let got = Async.map(upto(6), max: 3) fn(x) =>
    Async.yield()
    x * 2
  assert got == [2, 4, 6, 8, 10, 12]

test "`each` over `&r` leaves it at its end" =
  var r = upto(5)
  Async.each(&r, max: 2) fn(x) => Async.yield()
  assert &r.next() == None

test "a channel's items, sent from a task" =
  with sync.channel(1) as Events in
    var got: Array<Int> = []
    Async.scope fn(s) =>
      s.spawn fn() =>
        for i in 0..5
          Events.send(i)
        Events.close()
      for e in Events.items()
        &got.push(e)
    assert got == [0, 1, 2, 3, 4]

test "a producer at `cap`, a body that breaks" =
  var got: Array<Int> = []
  Async.produce(cap: 1, fn() => many(100)) fn(items) =>
    for x in items
      &got.push(x)
      if x == 3 then break
  assert got == [0, 1, 2, 3]

test "a producer's failure, after what it sent" =
  assert attempt drained(3) == Err(Broken)

test "`map_pull` keeps its source's order" =
  var out: Array<Int> = []
  Async.map_pull([5, 1, 4, 2, 3], max: 2, fn(x) =>
    for _ in 0..x
      Async.yield()
    x * 10) fn(results) =>
    for r in results
      &out.push(r)
  assert out == [50, 10, 40, 20, 30]
|});
  [%expect {|
    test.ren
      ✓ `map` over a cursor keeps its order
      ✓ `each` over `&r` leaves it at its end
      ✓ a channel's items, sent from a task
      ✓ a producer at `cap`, a body that breaks
      ✓ a producer's failure, after what it sent
      ✓ `map_pull` keeps its source's order

    6 passed, each under 1000 seeds
    [exit 0]
    |}]

(* ---- s6: `striped`, plain Ren over the keyed instance family (decisions 18 and 20, language.md §11) ---- *)

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
  run
        (hits
       ^ {|
fn main() uses Console, Async =
  with striped(counter(), by: Key(n: 4), merge: Sum) in
    Hits.hit("/a")
    Hits.hit("/b")
    Hits.hit("/a")
    print(Hits.total())
|});
  [%expect {|
    3
    ()
    |}]

let%expect_test "[s6 accept] `by: Worker`: a stripe per worker, the merge erasing which" =
  test ~seeds:200
        (pub_all
         (hits
       ^ {|
test "every hit is counted, whichever worker it lands on" =
  with striped(counter(), by: Worker, merge: Sum) in
    Async.each([1, 2, 3, 4]) fn(_) => Hits.hit("/")
    assert Hits.total() == 4
|}));
  [%expect {|
    test.ren
      ✓ every hit is counted, whichever worker it lands on

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s6 accept] the split law: a result that depends on routing fails under some seed" =
  (* under `sim` two virtual workers, `Async.worker()` from the tape: `Max`
     of the stripes' counts erases nothing about which stripe a hit went
     to *)
  test ~seeds:200
        (pub_all
         (hits
       ^ {|
test "the busiest stripe saw every hit" =
  with striped(counter(), by: Worker, merge: Max) in
    Async.each([1, 2, 3, 4]) fn(_) => Hits.hit("/")
    assert Hits.total() == 4
|}));
  [%expect {|
    test.ren
      ✗ the busiest stripe saw every hit

    ──── the busiest stripe saw every hit ── test.ren:13
       │
    13 │     assert Hits.total() == 4
       │            ^^^^^^^^^^^^^^^^^
       │
       left:  3
       right: 4
              ^ differs here

       seed 5671 · rerun: ren test test.ren --only "the busiest" --seed 5671

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s6 accept] a keyless operation that returns `()` broadcasts" =
  (* `by:` left out is `Key`, which is `Key(n: 16)` *)
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

fn main() uses Console, Async =
  with striped(counter(), merge: Sum) in
    Hits.hit("/a")
    Hits.hit("/b")
    Hits.reset()
    print(Hits.total())
|};
  [%expect {|
    0
    ()
    |}]

let%expect_test "[s6 accept] `merge: Concat` and `Custom(m)`, m's `call` clause folding, left to right in stripe order" =
  (* `Custom` holds a stateless handler over `Seen` whose `call(c:
     Seen.Call, a, b)` clause folds two stripes' results for `c`: there's
     no `Merge<D>` *)
  run
        {|
dep Seen =
  see: fn(path: Str)
  all: fn() -> Array<Str>

handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  all() => paths

handler longest() for Seen =
  call(c: Seen.Call, a, b) =>
    match c
      All => if a.len() >= b.len() then a else b
      See { .. } => a

fn main() uses Console, Async =
  with striped(seen(), by: Key(n: 1), merge: Concat) in
    Seen.see("/a")
    Seen.see("/b")
    print(Seen.all())
  with striped(seen(), by: Key(n: 1), merge: Custom(longest())) in
    Seen.see("/a")
    Seen.see("/b")
    print(Seen.all().len())
|};
  [%expect {|
    ["/a", "/b"]
    2
    ()
    |}]

let%expect_test "[s6 reject] a keyless operation that returns a value, with no `merge:`, panics at the `with`" =
  (* decision 20, rule 3: a check `striped` makes on its arguments, at the
     `with` until stage 12 makes it at build time; no Infer rule *)
  run_error
        (hits
       ^ {|
fn main() uses Console, Async =
  with striped(counter()) in print(Hits.total())
|});
  [%expect {|
    error: panic: `total` runs on every stripe and gives an `Int`, so `striped` needs `merge:`
       ┌─ test.ren:11:3
    11 │   with striped(counter()) in print(Hits.total())
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s6 reject] `by: Worker` with a count can't be written" =
  (* routing is an ADT: `Worker` has no fields, so this is the ADT's own
     error, not a rule written for `striped` *)
  check_error
        (hits
       ^ {|
fn main() uses Console, Async =
  with striped(counter(), by: Worker(n: 4), merge: Sum) in print(Hits.total())
|});
  [%expect {|
    error: `Worker` has 0 fields but was given 1
       ┌─ test.ren:11:31
    11 │   with striped(counter(), by: Worker(n: 4), merge: Sum) in print(Hits.total())
       │                               ^^^^^^^^^^^^
       help: write `Worker` with no parentheses
    |}]

let%expect_test "[s6 reject] `Custom(m)` with a handler that has state" =
  (* `striped` calls m as a method, `m.call(c, a, b)`: the data stage's
     rule for a description called as a method, nothing written for
     `striped` *)
  run_error
        (hits
       ^ {|
handler adding() for Hits =
  var calls = 0
  call(c: Hits.Call, a, b) =>
    calls += 1
    match c
      Total => a + b
      Hit { .. } => a

fn main() uses Console, Async =
  with striped(counter(), merge: Custom(adding())) in print(Hits.total())
|});
  [%expect {|
    error: panic: `m` may be a description of `adding`, which keeps state, so it isn't called as a method
       ┌─ test.ren:19:61
    19 │   with striped(counter(), merge: Custom(adding())) in print(Hits.total())
       │                                                             ^^^^^^^^^^^^
    |}]

let%expect_test "[s6 reject] `merge: Sum` of what isn't a number panics at the `with`" =
  run_error
        {|
dep Seen =
  see: fn(path: Str)
  all: fn() -> Array<Str>
handler seen() for Seen =
  var paths: Array<Str> = []
  see(p) => &paths.push(p)
  all() => paths
fn main() uses Console, Async =
  with striped(seen(), merge: Sum) in print(Seen.all())
|};
  [%expect {|
    error: panic: `merge: Sum` adds what `all` gives, and an `Array<Str>` isn't a number
      ┌─ test.ren:9:3
    9 │   with striped(seen(), merge: Sum) in print(Seen.all())
      │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s6 reject] `striped` keeps at least 1 stripe" =
  run_error
        (hits
       ^ {|
fn main() uses Console, Async =
  with striped(counter(), by: Key(n: 0), merge: Sum) in print(Hits.total())
|});
  [%expect {|
    error: panic: `striped` keeps at least 1 stripe, not 0
       ┌─ test.ren:11:3
    11 │   with striped(counter(), by: Key(n: 0), merge: Sum) in print(Hits.total())
       │   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    |}]

let%expect_test "[s6 reject] `striped` of what isn't a handler's description" =
  check_error {|
fn main() uses Console, Async =
  with striped(16) in print(1)
|};
  [%expect {|
    error: `striped` takes a handler's description, and `16` is an `Int`
      ┌─ test.ren:2:16
    2 │   with striped(16) in print(1)
      │                ^^
      help: describe the handler whose dependency it implements: `striped(counter())`
    |}]

let%expect_test "[s6 reject] `sync.keyed` is gone" =
  check_error
        ("import sync\n" ^ hits
       ^ {|
fn main() uses Console =
  with sync.keyed(4, counter()) in print(Hits.total())
|});
  [%expect {|
    error: `sync` has no public `keyed`
       ┌─ test.ren:13:13
    13 │   with sync.keyed(4, counter()) in print(Hits.total())
       │             ^^^^^
       help: if it's defined there, mark it `pub`
    |}]

(* test_tasks.ml's tests of `sync.keyed` (11a's step 8), moved here as
   `striped`'s, `keyed(n, h)` becoming `striped(h, by: Key(n: n))`; a
   call with no key that gives a value is folded by a `merge:` *)

let%expect_test "[s6 accept] `striped` sends each call to a stripe by its key" =
  run
    {|
dep Counts =
  add: fn(key: Str)
  get: fn(key: Str) -> Int

handler counts() for Counts =
  var m: Map<Str, Int> = Map.of([])
  add(k) => &m.set(k, m.get(k).unwrap_or(0) + 1)
  get(k) => m.get(k).unwrap_or(0)

fn main() uses Console, Async =
  with striped(counts(), by: Key(n: 4)) in
    Counts.add("a")
    Counts.add("b")
    Counts.add("a")
    print(Counts.get("a"))
    print(Counts.get("b"))
|};
  [%expect {|
    2
    1
    ()
    |}]

let%expect_test "[s6 accept] `striped`'s stripes: two keys overlap, one key takes turns" =
  (* "a" and "b" go to different stripes of 2, by a hash that's the same
     in every run; each stripe keeps its own instance's lock, so two
     calls on one key wait for each other; and a call with no key goes to
     each stripe in turn, in order, folded here to the last's *)
  test ~seeds:100
    {|
pub dep Slow =
  // takes a second, keeping its instance
  put: fn(key: Str)
  // how many puts this instance had, and says so
  count: fn() -> Int

pub dep Said =
  say: fn(n: Int)
  all: fn() -> Array<Int>

test handler said() for Said =
  var xs: Array<Int> = []
  say(n) => &xs.push(n)
  all() => xs

test handler slow() for Slow uses Clock, Said =
  var n = 0
  put(k) =>
    n += 1
    Clock.sleep(Duration.seconds(1))
  count() =>
    Said.say(n)
    n

// the second of two results, the later stripe's
test handler last() for Slow =
  call(c, a, b) => b

test fn puts(keys: Array<Str>) uses Slow, Async =
  Async.each(keys) fn(k) => Slow.put(k)

test "calls on keys in different stripes overlap" =
  with said(), striped(slow(), by: Key(n: 2), merge: Custom(last())) in
    puts(["a", "b"])
    assert Clock.now() == Time.epoch + Duration.seconds(1)

test "calls on one key take turns" =
  with said(), striped(slow(), by: Key(n: 2), merge: Custom(last())) in
    puts(["a", "a"])
    assert Clock.now() == Time.epoch + Duration.seconds(2)

test "a call with no key goes to each stripe in turn" =
  with said(), striped(slow(), by: Key(n: 3), merge: Custom(last())) in
    puts(["a", "b", "a"])
    let n = Slow.count()
    assert Said.all().len() == 3
    assert n == Said.all()[2]
    assert Said.all()[0] + Said.all()[1] + Said.all()[2] == 3
|};
  [%expect {|
    test.ren
      ✓ calls on keys in different stripes overlap
      ✓ calls on one key take turns
      ✓ a call with no key goes to each stripe in turn

    3 passed, each under 100 seeds
    [exit 0]
    |}]

let%expect_test "[s6 accept] `striped`'s stripes each have their own `finally`, the last made's first" =
  run
    {|
dep Tally =
  add: fn(key: Int)

handler tally(name: Str) for Tally uses Console =
  var n = 0
  finally(r) =>
    print(name + ": " + show(n))
    try r
  add(k) => n += k

fn main() uses Console, Async =
  with striped(tally("one"), by: Key(n: 2)) in
    Tally.add(1)
    Tally.add(2)
    Tally.add(3)
|};
  [%expect {|
    one: 2
    one: 4
    ()
    |}]

(* ---- s7: `actors`, plain Ren over the keyed instance family (decisions 18 and 20, language.md §11) ----

   `actors` uses `Random`, for `chaos:`, so a `main` that installs it
   names `Random` (compiler.md, "Where this stage may differ"). The rules
   of decision 18's list that aren't `post`'s each have a test here, or in
   test_actors.ml. *)

(* A document actor and its store, the smallest stand-ins: a document is
   text that grows by appending, and the store keeps the last text saved
   and counts what it was asked. Its `finally` gives back the `with`'s
   body's result, as any handler's does, which a family gives it as
   `Ok(())`. *)
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

handler doc(id: DocId) for Doc ! StoreDown uses Store, Console =
  var text = try Store.load(id)
  finally(r) =>
    print("evicted " + show(id))
    try r
  edit(s) =>
    text = text + s
    try Store.save(id, text)
  text() => text

dep Docs = Actors<DocId, Doc> ! StoreDown
|}

let%expect_test "[s7 accept] `at` makes an actor on demand, and installs it as `D` for its block" =
  (* the `with`'s body prints what `go` gave before the family ends,
     evicting the actor *)
  run
    (docs
   ^ {|
fn go() ! StoreDown uses Docs, Console =
  try Docs.at(DocId(1)) fn() =>
    try Doc.edit("a")
    try Doc.edit("b")
    print(Doc.text())
  print(Docs.count())

fn main() uses Console, Random =
  with mem_store(), actors(doc, max: 2) as Docs in print(attempt go())
|});
  [%expect {|
    ab
    1
    Ok(())
    evicted DocId(1)
    ()
    |}]

let%expect_test "[s7 accept] setup's errors are `at`'s, and the next `at` tries again" =
  run
    (docs
   ^ {|
fn main() uses Console, Random =
  with mem_store(), actors(doc) as Docs in
    print(attempt Docs.at(DocId(-1)) fn() => Doc.text())
    print(Docs.count())
|});
  [%expect {|
    Err(StoreDown)
    0
    ()
    |}]

let%expect_test "[s7 accept] past `max:`, the least recently released actor is evicted, its `finally` on the caller's task" =
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

fn main() uses Console, Random =
  with mem_store(), actors(doc, max: 2) as Docs in
    match attempt go()
      Ok(_) => ()
      Err(_) => print("failed")
|});
  [%expect {|
    evicted DocId(1)
    2
    1
    1
    evicted DocId(3)
    evicted DocId(2)
    ()
    |}]

let%expect_test "[s7 accept] an evicted actor made again reads what the store kept" =
  run
    (docs
   ^ {|
fn go() ! StoreDown uses Docs, Console =
  try Docs.at(DocId(1)) fn() => try Doc.edit("x")
  try Docs.at(DocId(2)) fn() => try Doc.edit("-")
  try Docs.at(DocId(1)) fn() =>
    try Doc.edit("y")
    print(Doc.text())

fn main() uses Console, Random =
  with mem_store(), actors(doc, max: 1) as Docs in
    match attempt go()
      Ok(_) => ()
      Err(_) => print("failed")
|});
  [%expect {|
    evicted DocId(1)
    evicted DocId(2)
    xy
    evicted DocId(1)
    ()
    |}]

let%expect_test "[s7 accept] a pinned actor isn't evicted; the maker waits for one that's evictable" =
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
        ()
      s.spawn fn() =>
        let _ = attempt Docs.at(DocId(2)) fn() => Doc.text()
        ()
|}));
  [%expect {|
    test.ren
      ✓ the pinned one keeps its text

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s7 accept] `evict(k)`, `evict_idle(d)` and `each`" =
  run
    ("import sim\n" ^ docs
   ^ {|
fn go() ! StoreDown uses Docs, Console, Clock =
  try Docs.at(DocId(1)) fn() => try Doc.edit("a")
  Clock.sleep(Duration.seconds(10))
  try Docs.at(DocId(2)) fn() => try Doc.edit("b")
  Docs.evict_idle(Duration.seconds(5))
  print(Docs.count())
  Docs.each fn() => print(Doc.text())
  Docs.evict(DocId(2))
  print(Docs.count())

fn main() uses Console, Random =
  with sim.scheduler(1) in
    with sim.clock() in
      with mem_store(), actors(doc) as Docs in
        match attempt go()
          Ok(_) => ()
          Err(_) => print("failed")
|});
  [%expect {|
    evicted DocId(1)
    1
    b
    evicted DocId(2)
    0
    ()
    |}]

let%expect_test "[s7 accept] teardown in reverse creation order" =
  run
    (docs
   ^ {|
fn main() uses Console, Random =
  with mem_store(), actors(doc) as Docs in
    for n in [2, 1, 3]
      let _ = attempt Docs.at(DocId(n)) fn() => Doc.text()
      ()
|});
  [%expect {|
    evicted DocId(3)
    evicted DocId(1)
    evicted DocId(2)
    ()
    |}]

let%expect_test "[s7 accept] two operations of one actor race; one operation doesn't" =
  (* language.md §11: a read and a write in two operations race *)
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
  append(s) => text = text + s

dep Docs = Actors<DocId, Doc>

test "two appends by read-then-write both land" =
  with actors(doc) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text() + "a")
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.set(Doc.text() + "b")
    Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2

test "two appends by one operation both land" =
  with actors(doc) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("a")
      s.spawn fn() => Docs.at(DocId(1)) fn() => Doc.append("b")
    Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2
|});
  [%expect {|
    test.ren
      ✗ two appends by read-then-write both land
      ✓ two appends by one operation both land

    ──── two appends by read-then-write both land ── test.ren:21
       │
    21 │     Docs.at(DocId(1)) fn() => assert Doc.text().bytes().len() == 2
       │                                      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  1
       right: 2
              ^ differs here

       seed 7511 · rerun: ren test test.ren --only "two appends by read-then-write" --seed 7511

    1 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s7 accept] `actors(doc, chaos: true)` finds what lives only in memory" =
  (* chaos is a parameter of `actors`: at each call into the family it
     evicts the evictable actors `Random` picks, from the tape under
     `ren test`, so under some seed the document kept only in memory
     loses its text between two `at`s. The scheduler and `ren test` know
     nothing of it *)
  test ~seeds:50
    (pub_all
       {|
type DocId = | DocId(n: Int)

dep Doc =
  append: fn(s: Str)
  text: fn() -> Str

handler doc(id: DocId) for Doc =
  var text = ""
  append(s) => text = text + s
  text() => text

dep Docs = Actors<DocId, Doc>

test "the text kept only in memory survives" =
  with actors(doc, chaos: true) as Docs in
    Docs.at(DocId(1)) fn() => Doc.append("a")
    Docs.at(DocId(1)) fn() => assert Doc.text() == "a"
|});
  [%expect {|
    test.ren
      ✗ the text kept only in memory survives

    ──── the text kept only in memory survives ── test.ren:17
       │
    17 │     Docs.at(DocId(1)) fn() => assert Doc.text() == "a"
       │                                      ^^^^^^^^^^^^^^^^^
       │
       left:  ""
       right: "a"
               ^ differs here

       seed 6561 · rerun: ren test test.ren --only "the text" --seed 6561

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "[s7 reject] `at` inside `at` of the same family" =
  check_error
    (docs
   ^ {|
fn go() ! StoreDown uses Docs =
  try Docs.at(DocId(1)) fn() =>
    try Docs.at(DocId(2)) fn() => Doc.text()

fn main() = ()
|});
  [%expect {|
    error: `Docs.at` inside a block of `Docs.at` could wait for a slot its own block holds
       ┌─ test.ren:35:9
    35 │     try Docs.at(DocId(2)) fn() => Doc.text()
       │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       = `Docs.at` keeps the instance it pins for its block, and making another can wait for room in the family
       help: finish with the first, then call the second; or post to it, which holds nothing
    |}]

let%expect_test "[s7 reject] an actor `at`-ing its own family" =
  (* an actor names its own family to post to it (step 7b); it may never
     pin one of its siblings *)
  check_error
    {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
handler doc(id: DocId) for Doc uses Docs =
  poke() => Docs.at(DocId(2)) fn() => Doc.poke()
fn main() uses Console, Random =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|};
  [%expect {|
    error: `doc` is kept by `Docs`'s family, so it can't call `Docs.at`, which pins one of its siblings
      ┌─ test.ren:6:13
    6 │   poke() => Docs.at(DocId(2)) fn() => Doc.poke()
      │             ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = an actor's siblings are the other instances of `Docs`
      help: post to it instead, which holds nothing
    |}]

let%expect_test "[s7 reject] an actor's handler takes one parameter, its key" =
  (* `actors`' `h` is `fn(k: K) -> D`: an ordinary argument's type *)
  check_error
    {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
handler doc(id: DocId, size: Int) for Doc =
  poke() => ()
fn main() uses Random =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|};
  [%expect {|
    error: expected `fn(_) -> _`, found `fn(DocId, Int) -> Doc`
      ┌─ test.ren:8:15
    8 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
      │               ^^^
    |}]

let%expect_test "[s7 reject] setup that fails with what the family doesn't declare" =
  (* the alias's `! E` is what making an actor fails with, which is none
     here *)
  check_error
    {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc>
fn load() -> Int ! StoreDown = fail StoreDown
handler doc(id: DocId) for Doc =
  let n = try load()
  poke() => ()
fn main() uses Random =
  with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
|};
  [%expect {|
    error: `doc`'s setup can fail with `StoreDown`, which `Docs` doesn't declare
       ┌─ test.ren:10:8
    10 │   with actors(doc) as Docs in Docs.at(DocId(1)) fn() => Doc.poke()
       │        ^^^^^^^^^^^^^^^^^^^
       = a family's `at` fails with what making an instance does, which `Docs` says
       help: declare it on the alias, after its type arguments, `dep Docs = ... ! StoreDown`, or handle it in `doc`'s setup
    |}]

let%expect_test "[s7 reject] an actor's `finally` that can fail" =
  check_error
    {|
type DocId = | DocId(n: Int)
dep Doc =
  poke: fn()
dep Docs = Actors<DocId, Doc> ! StoreDown
fn flush() ! StoreDown = fail StoreDown
handler doc(id: DocId) for Doc =
  finally(r) =>
    try flush()
    try r
  poke() => ()
fn main() uses Random =
  with actors(doc) as Docs in
    match attempt Docs.at(DocId(1)) fn() => Doc.poke()
      _ => ()
|};
  [%expect {|
    error: `doc` is kept by a family, so its `finally` can't fail
      ┌─ test.ren:8:5
    8 │     try flush()
      │     ^^^^^^^^^^^
      = it runs when an instance is evicted, or the family ends, where no caller is given its error
      help: save in its operations, write-through, or flush before the family ends
    |}]

let%expect_test "[s7 accept] `Full` where waiting could close a cycle" =
  (* decision 18: a task that pins an actor may wait for a slot only in a
     family installed outside the ones it pins; anywhere else `Full`,
     which `Inners.at` inside `Outers.at`'s block can fail with. Here the
     first task holds the only slot of `Inners`, installed inside
     `Outers`, while the second, pinning one of `Outers`, asks for
     another *)
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

fn main() uses Console, Async, Random =
  with actors(outer, max: 1) as Outers in
    with actors(inner, max: 1) as Inners in
      Async.scope fn(s) =>
        s.spawn fn() =>
          Inners.at(Key(1)) fn() =>
            Async.yield()
            Inner.poke()
        s.spawn fn() =>
          Outers.at(Key(1)) fn() =>
            print(attempt Inners.at(Key(2)) fn() => Inner.poke())
|};
  [%expect {|
    Err(Full)
    ()
    |}]

(* A third library over the family, written in a test: a family with a
   fixed key set. It gets the family's rules, here its no-deadlock check
   on `pin`, with no compiler support of its own. *)
let shards =
  {|
type Shard = | A | B

dep Count =
  add: fn(n: Int)
  total: fn() -> Int

handler count(s: Shard) for Count =
  var n = 0
  add(k) => n += k
  total() => n

dep Shards =
  at: fn(s: Shard, body: fn() -> Int uses Count) -> Int

handler shards() for Shards =
  let fam = Instances.open(count, 1, 2, 16)
  finally(r) =>
    Instances.close(fam)
    try r
  at(s, body) => Instances.pin(fam, s, fn(_) => None, body)
|}

let%expect_test "[s7 accept] a third library over the family: a fixed key set" =
  run
    (shards
   ^ {|
fn main() uses Console =
  with shards() in
    let _ = Shards.at(A) fn() =>
      Count.add(2)
      0
    let _ = Shards.at(B) fn() =>
      Count.add(3)
      0
    print(Shards.at(B) fn() => Count.total())
    print(Shards.at(A) fn() => Count.total())
|});
  [%expect {|
    3
    2
    ()
    |}]

let%expect_test "[s7 reject] a third library's `at` inside its own `at`: the family's check on `pin`" =
  check_error
    (shards
   ^ {|
fn main() =
  with shards() in
    let _ = Shards.at(A) fn() =>
      Shards.at(B) fn() =>
        Count.add(1)
        0
    ()
|});
  [%expect {|
    error: `Shards.at` inside a block of `Shards.at` could wait for a slot its own block holds
       ┌─ test.ren:25:7
    25 │       Shards.at(B) fn() =>
       │       ^^^^^^^^^^^^^^^^^^^^
       = `Shards.at` keeps the instance it pins for its block, and making another can wait for room in the family
       help: finish with the first, then call the second; or post to it, which holds nothing
    |}]

let%expect_test "[s7 accept] a journal of a run that evicts and remakes a key names each life, and replays" =
  (* `docs[DocId(1)]#1`, then `#2` once it's made again: version 3's
     opened, made and evicted lines; `ren replay` of it follows it, and
     recording it again writes the same journal, byte for byte *)
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

fn main() uses Console, Random =
  with actors(doc, max: 1) as Docs in
    Docs.at(DocId(1)) fn() => Doc.poke()
    Docs.at(DocId(2)) fn() => Doc.poke()
    Docs.at(DocId(1)) fn() => Doc.poke()
|}
      );
    ]
    (fun () ->
      record ();
      let first = read "run.journal" in
      replay "run.journal";
      record ();
      print_endline
        (if read "run.journal" = first then "recorded again: the same bytes"
         else "recorded again: different"));
  [%expect {|
    DocId(1)
    DocId(2)
    DocId(1)
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened docs parts 1
    2 main made docs[DocId(1)]#1
    3 main Console.write("DocId(1)")
    4 main evicted docs[DocId(1)]#1
    5 main made docs[DocId(2)]#1
    6 main Console.write("DocId(2)")
    7 main evicted docs[DocId(2)]#1
    8 main made docs[DocId(1)]#2
    9 main Console.write("DocId(1)")
    10 main exit 0
    DocId(1)
    DocId(2)
    DocId(1)
    replayed 3 calls
    DocId(1)
    DocId(2)
    DocId(1)
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened docs parts 1
    2 main made docs[DocId(1)]#1
    3 main Console.write("DocId(1)")
    4 main evicted docs[DocId(1)]#1
    5 main made docs[DocId(2)]#1
    6 main Console.write("DocId(2)")
    7 main evicted docs[DocId(2)]#1
    8 main made docs[DocId(1)]#2
    9 main Console.write("DocId(1)")
    10 main exit 0
    recorded again: the same bytes
    |}]

(* ---- s7: `post`, Erlang's cast ---- *)

let%expect_test "[s7 accept] a post's arguments are evaluated when it's posted" =
  run
    {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  all: fn() -> Str
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log =
  var text = ""
  put(s) => text = text + s
  all() => text

fn main() uses Console, Random =
  with actors(log) as Logs in
    var s = "a"
    Logs.post(Key(1), Log.Call.Put { s })
    s = "b"
    Logs.at(Key(1)) fn() => print(Log.all())
|};
  [%expect {|
    a
    ()
    |}]

let%expect_test "[s7 accept] a post's call is a value: built, kept, posted and shown" =
  (* `post` takes a `Log.Call`, the call value the compiler writes for
     every dependency whose operations are all data; there's no
     `Logs.post(k).put(s)` (decided 2026-10-29) *)
  run
    {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  all: fn() -> Str
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log =
  var text = ""
  put(s) => text = text + s
  all() => text

fn main() uses Console, Random =
  with actors(log) as Logs in
    Logs.post(Key(1), Log.Call.Put { s: "a" })
    let c = Log.Call.Put { s: "b" }
    Logs.post(Key(1), c)
    Logs.at(Key(1)) fn() => print(Log.all())
    print(c)
|};
  [%expect {|
    ab
    Put { s: "b" }
    ()
    |}]

let%expect_test "[s7 accept] posts from one task to one actor run in order, each as one operation" =
  (* `max: 1` evicts key 1's actor once its mail is delivered, when the
     second task's `at` needs the slot, so each actor writes through to
     `Kept`, which outlives it: what's in memory is lost on eviction, as
     it should be *)
  test ~seeds:1000
    (pub_all
     {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  all: fn() -> Str
dep Logs = Actors<Key, Log>
dep Kept =
  add: fn(n: Int, s: Str)
  all: fn(n: Int) -> Str
handler kept() for Kept =
  var texts: Map<Int, Str> = Map.empty
  add(n, s) =>
    let t = (texts.get(n) orelse "") + s
    &texts.set(n, t)
  all(n) => texts.get(n) orelse ""
handler log(k: Key) for Log uses Kept =
  put(s) =>
    let Key(n) = k
    Kept.add(n, s)
  all() =>
    let Key(n) = k
    Kept.all(n)

test "posts arrive in the order posted" =
  with kept(), actors(log, max: 1) as Logs in
    Async.scope fn(s) =>
      s.spawn fn() =>
        Logs.post(Key(1), Log.Call.Put { s: "a" })
        Logs.post(Key(1), Log.Call.Put { s: "b" })
        Logs.post(Key(1), Log.Call.Put { s: "c" })
      s.spawn fn() => Logs.at(Key(2)) fn() => Log.put("x")
    Async.tick()
    Logs.at(Key(1)) fn() => assert Log.all() == "abc"
|});
  [%expect {|
    test.ren
      ✓ posts arrive in the order posted
          `Logs`'s high-water mark: 3 posts queued at once

    1 passed, each under 1000 seeds
    [exit 0]
    |}]

let%expect_test "[s7 accept] a post makes its actor, so setup's errors are the post's, and nothing is lost" =
  run
    (docs
   ^ {|
dep Notes = Actors<DocId, Note> ! StoreDown
dep Note =
  touch: fn()
handler note(id: DocId) for Note uses Store =
  let _ = try Store.load(id)
  touch() => ()

fn main() uses Console, Random =
  with mem_store(), actors(note) as Notes in
    print(attempt Notes.post(DocId(-1), Note.Call.Touch))
    print(Notes.count())
|});
  [%expect {|
    Err(StoreDown)
    0
    ()
    |}]

let%expect_test "[s7 accept] teardown delivers queued posts before the `finally`s" =
  run
    {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log uses Console =
  finally(r) =>
    print("done " + show(k))
    try r
  put(s) => print("got " + s)

fn main() uses Console, Random =
  with actors(log) as Logs in
    Logs.post(Key(1), Log.Call.Put { s: "a" })
    Logs.post(Key(1), Log.Call.Put { s: "b" })
|};
  [%expect {|
    got a
    got b
    done Key(1)
    ()
    |}]

let%expect_test "[s7 accept] an actor posts to its own family" =
  run
    {|
type Key = | Key(n: Int)
dep Peer =
  ping: fn(from: Key)
  pong: fn(from: Key)
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers, Console =
  ping(from) => Peers.post(from, Peer.Call.Pong { from: k })
  pong(from) => print("pong from " + show(from))

fn main() uses Console, Random =
  with actors(peer) as Peers in
    Peers.post(Key(2), Peer.Call.Ping { from: Key(1) })
|};
  [%expect {|
    pong from Key(2)
    ()
    |}]

let%expect_test "[s7 reject] posting an operation that returns a value" =
  (* `post`'s parameter is a `Doc.Call<()>`: an ordinary type error *)
  check_error
    {|
type Key = | Key(n: Int)
dep Log =
  put: fn(s: Str)
  line: fn(at: Int) -> Str
dep Logs = Actors<Key, Log>
handler log(k: Key) for Log =
  var lines: Array<Str> = []
  put(s) => &lines.push(s)
  line(at) => lines[at]
fn go() uses Logs =
  Logs.post(Key(1), Log.Call.Line { at: 0 })
fn main() = ()
|};
  [%expect {|
    error: `post` takes a call that gives `()` and can't fail, and `line` gives a `Str`
       ┌─ test.ren:11:21
    11 │   Logs.post(Key(1), Log.Call.Line { at: 0 })
       │                     ^^^^^^^^^^^^^^^^^^^^^^^
       help: use the value, or handle the error, inside the operation, or make the call directly where its result is wanted
    |}]

let%expect_test "[s7 reject] posting an operation that can fail" =
  check_error
    (docs
   ^ {|
fn go() ! StoreDown uses Docs =
  try Docs.post(DocId(1), Doc.Call.Edit { s: "a" })
fn main() = ()
|});
  [%expect {|
    error: `post` takes a call that gives `()` and can't fail, and `edit` can fail with `StoreDown`
       ┌─ test.ren:34:27
    34 │   try Docs.post(DocId(1), Doc.Call.Edit { s: "a" })
       │                           ^^^^^^^^^^^^^^^^^^^^^^^^
       help: use the value, or handle the error, inside the operation, or make the call directly where its result is wanted
    |}]

let%expect_test "[s7 accept] two actors posting to each other past `mailbox:` don't deadlock while an outside poster waits" =
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
    if left > 0 then Peers.post(Key(3 - n), Peer.Call.Ping { left: left - 1 })
  noted() => ()

test "siblings never wait; the outside does" =
  with actors(peer, mailbox: 2) as Peers in
    Async.scope fn(s) =>
      s.spawn fn() => Peers.post(Key(1), Peer.Call.Ping { left: 3 })
      s.spawn fn() =>
        for i in 0..5
          Peers.post(Key(2), Peer.Call.Noted)
|});
  [%expect {|
    test.ren
      ✓ siblings never wait; the outside does
          `Peers`'s high-water mark: 2 posts queued at once

    1 passed, each under 200 seeds
    [exit 0]
    |}]

let%expect_test "[s7 reject] a chain reaction panics past twice `mailbox:`, with the high-water mark" =
  run_error
    {|
type Key = | Key(n: Int)
dep Peer =
  double: fn(depth: Int)
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers =
  double(depth) =>
    let Key(n) = k
    Peers.post(Key(n + 1), Peer.Call.Double { depth: depth + 1 })
    Peers.post(Key(n + 1), Peer.Call.Double { depth: depth + 1 })

fn main() uses Console, Random =
  with actors(peer, mailbox: 2) as Peers in
    Peers.post(Key(0), Peer.Call.Double { depth: 0 })
|};
  [%expect {|
    error: panic: `Peers` has 5 posts queued, past twice its `mailbox:` of 2
      ┌─ test.ren:9:5
    9 │     Peers.post(Key(n + 1), Peer.Call.Double { depth: depth + 1 })
      │     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = in the task peers[Key(2)]#1
      = the high-water mark: 5
      = an instance that posts twice around a cycle grows its family's mail without end
    |}]

let%expect_test "[s7 accept] a post from inside `at` while the mailbox is full and its target isn't live completes" =
  (* research/actors-post/'s first counterexample, which the fixed rules
     make complete: the post from inside `at` makes room by delivering *)
  run
    {|
type Key = | Key(n: Int)
dep Doc =
  touch: fn(by: Int)
dep Docs = Actors<Key, Doc>
handler doc(k: Key) for Doc =
  touch(_) => ()

fn main() uses Console, Async, Random =
  with actors(doc, max: 1, mailbox: 1) as Docs in
    Async.scope fn(s) =>
      s.spawn fn() => Docs.post(Key(2), Doc.Call.Touch { by: 1 })
      s.spawn fn() =>
        Docs.at(Key(1)) fn() => Docs.post(Key(2), Doc.Call.Touch { by: 2 })
  print("done")
|};
  [%expect {|
    done
    ()
    |}]

let%expect_test "[s7 accept] a session looping an `at` operation that posts to a sibling is held at the edge" =
  (* the second counterexample: every call from outside is metered, so
     the index's mail never passes `mailbox:` plus one operation's posts *)
  test ~seeds:100
    (pub_all
     {|
type Key = | Key(n: Int)
dep Doc =
  edit: fn()
  changed: fn(from: Key)
dep Docs = Actors<Key, Doc>
handler doc(k: Key) for Doc uses Docs =
  edit() => Docs.post(Key(0), Doc.Call.Changed { from: k })
  changed(_) => ()

test "the session's posts stay within the bound" =
  with actors(doc, mailbox: 4) as Docs in
    Docs.at(Key(1)) fn() =>
      for i in 0..50
        Doc.edit()
    assert Docs.high_water() <= 5
|});
  [%expect {|
    test.ren
      ✓ the session's posts stay within the bound
          `Docs`'s high-water mark: 4 posts queued at once

    1 passed, each under 100 seeds
    [exit 0]
    |}]

let%expect_test "[s7 accept] each family's high-water mark is reported" =
  (* the most posts a family has queued at once (decision 18, "A chain
     reaction panics": debug builds and `sim` report it, which is how one
     is found before it panics): `ren test` says it under each test, the
     most under any seed, and `high_water()` gives it to the program *)
  test ~seeds:50
    (pub_all
     {|
type Key = | Key(n: Int)
dep Tally =
  add: fn(n: Int)
dep Tallies = Actors<Key, Tally>
handler tally(k: Key) for Tally =
  var total = 0
  add(n) => total += n

test "three posts queued before any is delivered" =
  with actors(tally) as Tallies in
    Tallies.post(Key(1), Tally.Call.Add { n: 1 })
    Tallies.post(Key(1), Tally.Call.Add { n: 2 })
    Tallies.post(Key(2), Tally.Call.Add { n: 3 })
    assert Tallies.high_water() == 3
|});
  [%expect {|
    test.ren
      ✓ three posts queued before any is delivered
          `Tallies`'s high-water mark: 3 posts queued at once

    1 passed, each under 50 seeds
    [exit 0]
    |}]

let%expect_test "[s7 accept] a run with posts replays from its journal" =
  (* a post is journaled as data, on the task that posted it, and what a
     delivery does under its instance's name: `ren replay` runs it again,
     and recording it again writes the same journal, byte for byte *)
  in_folder
    [
      ( "main.ren",
        {|
type Key = | Key(n: Int)
dep Peer =
  ping: fn(left: Int)
  say: fn(s: Str)
dep Peers = Actors<Key, Peer>
handler peer(k: Key) for Peer uses Peers, Console =
  ping(left) =>
    let Key(n) = k
    print(show(k) + " " + show(left))
    if left > 0 then Peers.post(Key(3 - n), Peer.Call.Ping { left: left - 1 })
  say(s) => print(s + " to " + show(k))

fn main() uses Console, Random =
  with actors(peer, max: 1) as Peers in
    Peers.post(Key(1), Peer.Call.Ping { left: 3 })
    Peers.post(Key(2), Peer.Call.Say { s: "hi there" })
    Peers.at(Key(2)) fn() => Peer.say("hello")
|}
      );
    ]
    (fun () ->
      record ();
      let first = read "run.journal" in
      replay "run.journal";
      record ();
      print_endline
        (if read "run.journal" = first then "recorded again: the same bytes"
         else "recorded again: different"));
  [%expect {|
    Key(1) 3
    hi there to Key(2)
    Key(2) 2
    hello to Key(2)
    Key(1) 1
    Key(2) 0
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened peers parts 1
    2 main made peers[Key(1)]#1
    3 main posted peers[Key(1)] Ping { left: 3 }
    4 main made peers[Key(2)]#1
    5 main posted peers[Key(2)] Say { s: "hi there" }
    6 peers[Key(1)]#1 Console.write("Key(1) 3")
    7 peers[Key(1)]#1 posted peers[Key(2)] Ping { left: 2 }
    8 peers[Key(2)]#1 Console.write("hi there to Key(2)")
    9 peers[Key(2)]#1 Console.write("Key(2) 2")
    10 peers[Key(2)]#1 posted peers[Key(1)] Ping { left: 1 }
    11 main Console.write("hello to Key(2)")
    12 peers[Key(1)]#1 Console.write("Key(1) 1")
    13 peers[Key(1)]#1 posted peers[Key(2)] Ping { left: 0 }
    14 peers[Key(2)]#1 Console.write("Key(2) 0")
    15 main exit 0
    Key(1) 3
    hi there to Key(2)
    Key(2) 2
    hello to Key(2)
    Key(1) 1
    Key(2) 0
    replayed 6 calls
    Key(1) 3
    hi there to Key(2)
    Key(2) 2
    hello to Key(2)
    Key(1) 1
    Key(2) 0
    # ren journal 3 · main.ren · deps: Console Random
    1 main opened peers parts 1
    2 main made peers[Key(1)]#1
    3 main posted peers[Key(1)] Ping { left: 3 }
    4 main made peers[Key(2)]#1
    5 main posted peers[Key(2)] Say { s: "hi there" }
    6 peers[Key(1)]#1 Console.write("Key(1) 3")
    7 peers[Key(1)]#1 posted peers[Key(2)] Ping { left: 2 }
    8 peers[Key(2)]#1 Console.write("hi there to Key(2)")
    9 peers[Key(2)]#1 Console.write("Key(2) 2")
    10 peers[Key(2)]#1 posted peers[Key(1)] Ping { left: 1 }
    11 main Console.write("hello to Key(2)")
    12 peers[Key(1)]#1 Console.write("Key(1) 1")
    13 peers[Key(1)]#1 posted peers[Key(2)] Ping { left: 0 }
    14 peers[Key(2)]#1 Console.write("Key(2) 0")
    15 main exit 0
    recorded again: the same bytes
    |}]

let senders =
  {|
type Shard = | A | B

dep Count =
  add: fn(n: Int)
  total: fn() -> Int

handler count(s: Shard) for Count uses Console =
  var n = 0
  finally(r) =>
    print(show(s) + " " + show(n))
    try r
  add(k) => n += k
  total() => n

dep Shards<D> =
  send: fn(s: Shard, c: Call<D, Unit, !>)
dep Counts = Shards<Count>

handler shards<D>(h: spawned fn(s: Shard) -> D) for Shards<D> =
  let fam = Instances.open(fn(s: Shard) => h(s), 1, 2, 16)
  finally(r) =>
    Instances.close(fam)
    try r
  send(s, c) =>
    let _ = Instances.post(fam, s, c, fn(_) => None)
    ()
|}

let%expect_test "[s7 accept] a third library over the family posts, with no support of its own" =
  (* `Instances.post` and the prelude's `Call<D, (), !>` are all it needs:
     the queue, the delivery and the type rule are the family's and the
     compiler's for any library *)
  run
    (senders
   ^ {|
fn main() uses Console =
  with shards(count) as Counts in
    Counts.send(A, Count.Call.Add { n: 2 })
    Counts.send(B, Count.Call.Add { n: 3 })
    Counts.send(A, Count.Call.Add { n: 4 })
|});
  [%expect {|
    B 3
    A 6
    ()
    |}]

let%expect_test "[s7 reject] a third library's post of an operation that gives a value" =
  check_error
    (senders
   ^ {|
fn main() uses Console =
  with shards(count) as Counts in
    Counts.send(A, Count.Call.Total)
|});
  [%expect {|
    error: `send` takes a call that gives `()` and can't fail, and `total` gives an `Int`
       ┌─ test.ren:30:20
    30 │     Counts.send(A, Count.Call.Total)
       │                    ^^^^^^^^^^^^^^^^
       help: use the value, or handle the error, inside the operation, or make the call directly where its result is wanted
    |}]

(* ---- s8: the milestone, in miniature (bench/services/docs is the whole one) ---- *)

let%expect_test "[s8 accept] the document server's actors under chaos eviction keep every edit" =
  (* chaos is the program's: its wiring installs `actors(doc, max: 2,
     chaos: true)`; there's no `ren test --chaos` *)
  until "s8"
    ~says:[ "✓ every edit is in the store, in one order" ]
    (fun () ->
      test ~seeds:100
        (pub_all
         (docs
       ^ {|
wiring live provides Docs uses Console, Random = mem_store(), actors(doc, max: 2, chaos: true) as Docs

test "every edit is in the store, in one order" =
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
    error: this block ends with a `let`, so it has no value
       ┌─ test.ren:40:15
    40 │           let _ = attempt Docs.at(DocId(n % 2)) fn() =>
       │               ^
       help: add the value this block should produce as its last line
    |}]

