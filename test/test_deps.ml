(* Dependencies (deps.md): declaring one with `dep`, calling its
   operations, implementations, `with`, handlers, tests, and how it runs.

   The tests are in six sections, one for each of the things deps.md says
   dependencies have to do:

   1. the signature says what code touches
   2. nothing reaches the world another way
   3. a missing implementation is a compile error
   4. swapping is one line, and a test needs none
   5. interfaces are exact
   6. a dependency call costs a function call

   The helpers come first, since tests in several sections use them. *)

open Helpers

(* A program run from a `$start` written in Core: [body] makes its body
   from the functions of the entry ([fn_]), around the evidence `$start`
   takes, ev/1. Core Lint checks it, then it runs. *)
let run_start files body =
  let files, file, src, load = program files in
  report_files files (fun () ->
      let open Ren in
      let linked = Driver.linked ~lint:true ~load ~file src in
      let entry = List.nth linked (List.length linked - 1) in
      let fn_ name =
        List.find (fun (f : Core.fn_def) -> Path.local f.path = name) entry.fns
      in
      let start = fn_ Lower.start_name in
      let body = body ~fn_ ~loc:start.loc in
      print_endline (Core.show body);
      let start =
        {
          start with
          body;
          scheme =
            {
              ty = Fun ([], body.ty, Ty.closed, Ty.closed);
              names = [];
              reqs = [];
            };
        }
      in
      let entry =
        {
          entry with
          fns =
            List.map
              (fun (g : Core.fn_def) ->
                if g.path = start.path then start else g)
              entry.fns;
        }
      in
      Driver.pass "lint" (fun () -> Core_lint.program ~imports:[] ~linked entry);
      let modules = List.rev (entry :: List.tl (List.rev linked)) in
      print_endline
        (Value.show (Driver.pass "eval" (fun () -> Eval.run modules))))

(* Core for a call of [f], of no parameters, with the evidence [ev]. *)
let call ~loc (f : Ren.Core.fn_def) ev =
  let ret = match f.scheme.ty with Fun (_, t, _, _) -> t | t -> t in
  Ren.Core.mk
    (Call
       ( Ren.Core.mk
           (Global (f.path, Ren.Ty.own_args f.scheme.ty, []))
           f.scheme.ty loc,
         [],
         Ren.Core.evidence ev ))
    ret loc

(* Core Lint checks the evidence is threaded: a module with a dependency
   `D` of one operation, and a `main` that uses it, whose evidence is
   ev/1 *)
let lint_evidence body =
  let open Ren in
  let loc = Loc.point ~file 1 1 in
  let d = Path.make "test" "D" in
  let int_fn : Ty.ty = Fun ([], Ty.int, Ty.closed, Ty.closed) in
  let uses_d : Ty.row =
    { labels = [ Ty.label (Ty.dep_label d) ]; tail = None }
  in
  let op ev =
    Core.mk
      (Dep_call
         {
           dep = d;
           op = "op";
           fty = Fun ([], Ty.int, Ty.closed, uses_d);
           ev = Core.evidence ev;
           args = [];
         })
      Ty.int loc
  in
  let lambda ?(uses = Ty.closed) ev body =
    Core.mk
      (Lambda { params = []; ev = Core.evidence ev; captures = []; body })
      (Fun ([], Ty.int, Ty.closed, uses))
      loc
  in
  let call f ev = Core.mk (Call (f, [], Core.evidence ev)) Ty.int loc in
  let main : Core.fn_def =
    {
      path = Path.make "test" "main";
      params = [];
      ev = Core.evidence 1;
      tys = [];
      scheme =
        { ty = Fun ([], Ty.int, Ty.closed, uses_d); names = []; reqs = [] };
      body = body ~loc ~op ~lambda ~call ~uses_d;
      loc;
    }
  in
  report "" (fun () ->
      Driver.pass "lint" (fun () ->
          Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types =
                [
                  {
                    path = d;
                    params = [];
                    body = Dep [ { fname = "op"; fty = int_fn } ];
                    members = Path.Map.empty;
                    loc = None;
                  };
                ];
              fns = [ main ];
              values = [];
              shows = [];
            }))

(* deps.md's handler of two dependencies sharing one state, and a function
   that uses one of them, for the handler tests to build on *)
let rates =
  {|
dep Rates =
  usd_to: fn(c: Int) -> Int

dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls

fn convert(n: Int) uses Rates = n * Rates.usd_to(1)
|}

(* ---- 1. the signature says what code touches ----

   Declaring a dependency, calling its operations, and the `uses` that
   follows: inferred for a private function, checked for a public one,
   through parameters of a dependency's type and named rows. *)

let%expect_test "a dependency lists its operations, then its members" =
  ast
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

  pub fn none() -> Users = Users { get: fn(_) => None, save: fn(_) => () }
|};
  [%expect
    {| (pub dep Users (ops get:fn(Int) -> Option<Int> save:fn(Int) ! Conflict) (members (pub (fn none () (record Users get=(lambda (_) (con None)) save=(lambda (_) ())))))) |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

  pub fn none() -> Users = Users { get: fn(_) => None, save: fn(_) => () }

fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      get: fn(Int) -> Option<Int>
      save: fn(Int) ! Conflict
      pub fn none() -> Users
    fn main() -> Int
    |}]

let%expect_test "calling an operation adds its dependency to uses" =
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

fn find(id: Int) = Users.get(id)
fn store(u) = try Users.save(u)
fn both(u: Int) =
  let _ = find(u)
  try store(u)
pub fn declared(id: Int) -> Option<Int> uses Users = Users.get(id)
fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      get: fn(Int) -> Option<Int>
      save: fn(Int) ! Conflict
    fn find(id: Int) -> Option<Int> uses Users
    fn store(u: Int) ! Conflict uses Users
    fn both(u: Int) ! Conflict uses Users
    pub fn declared(id: Int) -> Option<Int> uses Users
    fn main() -> Int
    |}]

let%expect_test "a public function lists the dependencies its calls use" =
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

pub fn find(id: Int) -> Option<Int> =
  let first = Users.get(id)
  first
fn main() = 1
|};
  [%expect
    {|
    error: `find` doesn't declare `Users`
      ┌─ test.ren:4:8
    4 │ pub fn find(id: Int) -> Option<Int> =
      │        ^^^^
    5 │   let first = Users.get(id)
      │               ------------- this call uses `Users`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Users`
    |}]

let%expect_test "an operation and a member can't share a name" =
  types
    {|
dep Timer =
  now: fn() -> Int

  pub fn now() -> Int = 0
fn main() = 1
|};
  [%expect
    {|
    error: `Timer` has an operation and a member both named `now`
      ┌─ test.ren:4:10
    2 │   now: fn() -> Int
      │   --- the operation `now` is here
    4 │   pub fn now() -> Int = 0
      │          ^^^
      = `Timer.now` has to mean one thing: calling the installed implementation's `now`, or this member
      help: rename one of them
    |}]

let%expect_test "two operations with one name" =
  types {|
dep Timer =
  now: fn() -> Int
  now: fn() -> Bool
fn main() = 1
|};
  [%expect
    {|
    error: there are two operations named `now`
      ┌─ test.ren:3:3
    2 │   now: fn() -> Int
      │   --- the first `now` is here
    3 │   now: fn() -> Bool
      │   ^^^
      help: rename one of them
    |}]

let%expect_test "what a dependency's declaration can't be" =
  ast {|
dep Timer =
  now: Int
|};
  [%expect
    {|
    error: `now` is an operation, so its type is a function's, but this is `Int`
      ┌─ test.ren:2:8
    2 │   now: Int
      │        ^^^
      help: write its type as a function's, like `now: fn() -> Int`
    |}];
  ast {|
dep Timer =
  pub fn zero() -> Int = 0
|};
  [%expect
    {|
    error: `Timer` has no operations: a dependency lists them first
      ┌─ test.ren:2:3
    2 │   pub fn zero() -> Int = 0
      │   ^^^
      help: list its operations first, like `now: fn() -> Time`, then its members
    |}];
  ast
    {|
dep Timer =
  now: fn() -> Int

  pub fn zero() -> Int = 0
  sleep: fn(ms: Int)
|};
  [%expect
    {|
    error: expected `fn`, `let` or an operator, in `Timer`'s members, found `sleep`
      ┌─ test.ren:5:3
    5 │   sleep: fn(ms: Int)
      │   ^^^^^
      help: a dependency's operations come first, before its members
    |}];
  (* a record's field under it is the same mistake, the other way round *)
  ast {|
type R = { a: Int }
  b: Int
|};
  [%expect
    {|
    error: expected `fn`, `let` or an operator, in `R`'s members, found `b`
      ┌─ test.ren:2:3
    2 │   b: Int
      │   ^
      help: a record's fields go in its braces, `{ ... }`
    |}];
  ast {|
dep Timer = now: fn() -> Int
|};
  [%expect
    {|
    error: expected the operations of `Timer`, found `now`
      ┌─ test.ren:1:13
    1 │ dep Timer = now: fn() -> Int
      │             ^^^
      help: put each of its operations on a line of its own, indented under it, like `now: fn() -> Time`
    |}];
  ast {|
dep Box<T> =
  get: fn() -> T
|};
  [%expect
    {|
    error: a dependency can't take type parameters
      ┌─ test.ren:1:8
    1 │ dep Box<T> =
      │        ^
      help: remove them
    |}]

let%expect_test "uses names a dependency" =
  types {|
fn b() uses users.lookup = 1
fn main() = 1
|};
  [%expect
    {|
    error: a dependency's name must start with a capital letter
      ┌─ test.ren:1:19
    1 │ fn b() uses users.lookup = 1
      │                   ^^^^^^
      help: write `Lookup`
    |}];
  types {|
fn f() uses Int = 1
fn g() uses Nope = 1
fn main() = 1
|};
  [%expect
    {|
    error: `Int` is a type, not a dependency
      ┌─ test.ren:1:13
    1 │ fn f() uses Int = 1
      │             ^^^
      help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: there's no dependency named `Nope`
      ┌─ test.ren:2:13
    2 │ fn g() uses Nope = 1
      │             ^^^^
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
      help: use one of those, or declare it with `dep`
    |}]

let%expect_test "another module's dependency" =
  types_files
    [
      ( "main.ren",
        {|
import store

pub fn find(id: Int) -> Option<Int> uses store.Users = store.Users.get(id)
fn look(id: Int) = store.Users.get(id)
fn main() = 1
|}
      );
      ("store.ren", {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
|});
    ];
  [%expect
    {|
    -- store
    pub dep Users
      get: fn(Int) -> Option<Int>

    -- main
    pub fn find(id: Int) -> Option<Int> uses store.Users
    fn look(id: Int) -> Option<Int> uses store.Users
    fn main() -> Int
    |}]

let%expect_test "a public signature can't use a private dependency" =
  types
    {|
dep Users =
  get: fn(id: Int) -> Option<Int>

pub fn find(id: Int) -> Option<Int> uses Users = Users.get(id)
fn main() = 1
|};
  [%expect
    {|
    error: `pub fn find` uses `Users`, which is private to this module
      ┌─ test.ren:4:42
    1 │ dep Users =
      │     ----- `Users` is declared here, without `pub`
    4 │ pub fn find(id: Int) -> Option<Int> uses Users = Users.get(id)
      │                                          ^^^^^
      help: mark `Users` `pub`
    |}]

let%expect_test "a parameter of a dependency's type is transparent" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn convert(r: Rates) = with r in Rates.usd_to(1)
fn passed(r: Rates) = convert(r)
pub fn public(r: Rates) -> Int = with r in Rates.usd_to(1)
fn caller() = passed(timed())
fn main() = 1
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    fn timed() -> (Rates uses Clock, ..d)
    fn convert(r: Rates) -> Int
    fn passed(r: Rates) -> Int
    pub fn public(r: Rates) -> Int
    fn caller() -> Int uses Clock
    fn main() -> Int
    |}];
  types
    {|
type Box = { c: Clock }
fn keep(c: Clock) -> Clock = c
fn boxed(c: Clock) = Box { c }
fn main() = 1
|};
  [%expect
    {|
    error: `c` is used as a value here, so it isn't transparent
      ┌─ test.ren:2:30
    2 │ fn keep(c: Clock) -> Clock = c
      │                              ^
      = a parameter whose type is a dependency's, `Clock`, can only be installed, with `with`, or passed straight to another function, so what it needs is what its function uses
      help: to keep it, name what it needs: `c: Clock uses ..d`

    error: `c` is used as a value here, so it isn't transparent
      ┌─ test.ren:3:28
    3 │ fn boxed(c: Clock) = Box { c }
      │                            ^
      = a parameter whose type is a dependency's, `Clock`, can only be installed, with `with`, or passed straight to another function, so what it needs is what its function uses
      help: to keep it, name what it needs: `c: Clock uses ..d`
    |}]

let%expect_test "a dependency parameter that's kept names its row" =
  run
    {|
pub fn id(c: Clock uses ..d) -> (Clock uses ..d) = c
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Console =
  print(with id(at(2)) in Clock.now())
|};
  [%expect {|
    Time(120000)
    ()
    |}];
  types
    {|
fn install(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
fn main() = 1
|};
  [%expect
    {|
    error: installing this needs `..d`, which `install` doesn't declare
      ┌─ test.ren:1:59
    1 │ fn install(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
      │                                                           ^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `install` uses: `uses Console, ..d`
    |}]

let%expect_test "a closure that's kept names its rows" =
  let src =
    {|
type Button<F> = { on_click: F }

fn keep(f: fn() -> Int ! ..e uses ..d) -> (fn() -> Int ! ..e uses ..d) = f
fn mk(f: fn() -> Int ! ..e uses ..d) -> Button<fn() -> Int ! ..e uses ..d> =
  Button { on_click: f }
fn press(b: Button<fn() -> Int ! ..e uses ..d>) -> Int ! ..e uses ..d =
  let f = b.on_click
  try f()
fn tick() -> Int ! Late uses Console =
  print(1)
  fail Late

fn main() uses Console =
  print(press(mk(fn() => 3)))
  let g = keep(tick)
  print(attempt g())
  print(attempt press(mk(tick)))
|}
  in
  types src;
  [%expect
    {|
    fn keep(f: fn() -> Int ! ..e uses ..d) -> (fn() -> Int ! ..e uses ..d)
    fn mk(f: fn() -> Int ! ..e uses ..d) -> Button<fn() -> Int ! ..e uses ..d>
    fn press(b: Button<fn() -> Int ! ..e uses ..d>) -> Int ! ..e uses ..d
    fn tick() -> Int ! Late uses Console
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    3
    1
    Err(Late)
    1
    Err(Late)
    ()
    |}]

let%expect_test "what a function does with a named row, it declares" =
  types
    {|
pub fn calls(f: fn() -> Int uses ..d) -> Int = f()
pub fn fails(f: fn() -> Int ! ..e) -> Int ! Bad = try f()
fn listed(f: fn() -> Int uses ..d) uses Console = f()
fn other(f: fn() -> Int uses ..d, g: fn() -> Int uses ..x) uses ..d =
  f() + g()
fn main() = 1
|};
  [%expect
    {|
    error: this call uses `..d`, which `calls` doesn't declare
      ┌─ test.ren:1:48
    1 │ pub fn calls(f: fn() -> Int uses ..d) -> Int = f()
      │                                                ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `calls` uses: `uses ..d`

    error: this can fail with `..e`, which `fails` doesn't declare
      ┌─ test.ren:2:55
    2 │ pub fn fails(f: fn() -> Int ! ..e) -> Int ! Bad = try f()
      │                                                       ^^^
      = `..e` stands for whatever the closure it names fails with, and a function that declares its errors declares that too
      help: add `..e` to what `fails` declares it fails with, after `!`

    error: this call uses `..d`, which `listed` doesn't declare
      ┌─ test.ren:3:51
    3 │ fn listed(f: fn() -> Int uses ..d) uses Console = f()
      │                                                   ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `listed` uses: `uses Console, ..d`

    error: this call uses `..x`, which `other` doesn't declare
      ┌─ test.ren:5:9
    5 │   f() + g()
      │         ^^^
      = `..x` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: `other` names one row, `..d`, which is all it can name: name this one `..d` too, where it's written
    |}];
  types
    {|
type Button = { on_click: fn() }
fn mk(f: fn() uses ..d) = Button { on_click: fn() => f() }
fn both(f: fn() uses ..d, g: fn() uses ..x) =
  f()
  g()
fn main() = 1
|};
  [%expect
    {|
    error: this call uses `..d`, which isn't allowed here
      ┌─ test.ren:2:54
    2 │ fn mk(f: fn() uses ..d) = Button { on_click: fn() => f() }
      │                                                      ^^^
      = `..d` stands for whatever the closure or implementation it names uses, and what this is in can't use more than it lists
      help: use it where `..d` can go: in the function that names it, or in a lambda whose type isn't written

    error: this call uses `..x`, but what this is in already uses `..d`
      ┌─ test.ren:5:3
    5 │   g()
      │   ^^^
      = a row ends in at most one named row, and what this is in already uses `..d`, so `..x` can't be added
      help: name the two rows alike, `..d`, if they can stand for the same
    |}]

let%expect_test "only a signature names a row" =
  types
    {|
type Button = { on_click: fn() uses ..d }
fn body() =
  let g: fn() uses ..q = fn() => ()
  g
fn kinds(f: fn() ! ..d, g: fn() uses ..d) = 1
fn main() = 1
|};
  [%expect
    {|
    error: a declaration can't name a row, `..d`
      ┌─ test.ren:1:39
    1 │ type Button = { on_click: fn() uses ..d }
      │                                       ^
      = only a function's signature names a row, for now (deps.md, "Implementations")
      help: to keep a closure in a type, make its type a type parameter, `type Button<F> = { on_click: F }`, which a signature can write `Button<fn() uses ..d>`

    error: there's no `..q` in this function's signature
      ┌─ test.ren:3:22
    3 │   let g: fn() uses ..q = fn() => ()
      │                      ^
      = a named row stands for what a closure or an implementation that comes into or out of the function does, so the signature names it
      help: name `..q` in the function's signature

    error: `..d` names what something uses here, and what something fails with elsewhere in this signature
      ┌─ test.ren:5:40
    5 │ fn kinds(f: fn() ! ..d, g: fn() uses ..d) = 1
      │                                        ^
      │                      - here it names what something fails with
      = a row is a list of errors or a list of dependencies, never both
      help: give the two rows two names
    |}]

(* A public wrapper can't infer its body's rows, so it names them: what
   `attempt` keeps, and passes on with `try`, is `..e` *)
let%expect_test "a public wrapper names its body's rows" =
  let src =
    {|
fn flaky(n: Int) -> Int ! Boom =
  if n < 3 then fail Boom else n
pub fn retry(n: Int, body: fn() -> Int ! ..e uses ..d) -> Int ! ..e uses ..d =
  let r = attempt body()
  if n <= 1 then try r
  else
    match r
      Ok(v) => v
      Err(_) => try retry(n - 1, body)
pub fn safe() -> Int ! Boom = with retry(3) in try flaky(2)
fn main() uses Console =
  print(attempt safe())
  print(with retry(2) in 7)
|}
  in
  types src;
  [%expect
    {|
    fn flaky(n: Int) -> Int ! Boom
    pub fn retry(n: Int, body: fn() -> Int) -> Int
    pub fn safe() -> Int ! Boom
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Err(Boom)
    7
    ()
    |}]

let%expect_test "a dependency's self is an implementation" =
  (* `self` needs what its method uses, as `c: N` does, and a receiver
     that needs less will do *)
  run
    {|
dep N =
  get: fn() -> Int

  fn fixed(n: Int) -> N = N { get: fn() => n }
  fn same(self, k: Int) -> N = self
  fn scaled(self, k: Int) -> (N uses N) = N { get: fn() => (with self in N.get()) * k }
fn main() uses Console =
  let b = N.fixed(7).same(3)
  let base = N.fixed(7)
  print(with N.fixed(1) in with base.scaled(3) in N.get())
  print(with b in N.get())
|};
  [%expect {|
    21
    7
    ()
    |}];
  (* a public one names what it needs where it's kept *)
  run
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = N { get: fn() => n }
  pub fn same(self, k: Int) -> (N uses ..d) uses ..d = self
  pub fn scaled(self, k: Int) -> (N uses ..d) uses ..d = N { get: fn() => (with self in N.get()) * k }
fn main() uses Console =
  print(with N.fixed(7).same(1).scaled(3) in N.get())
|};
  [%expect {|
    21
    ()
    |}];
  types
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = N { get: fn() => n }
  pub fn same(self, k: Int) -> N = self
fn noisy() -> Int uses Console =
  print(0)
  5
fn loud() -> (N uses Console) = N { get: fn() => noisy() }
fn main() =
  let b = loud().same(3)
  1
|};
  [%expect
    {|
    error: `self` is kept where it can't need anything, so it isn't transparent
      ┌─ test.ren:5:15
    5 │   pub fn same(self, k: Int) -> N = self
      │               ^^^^
      = a dependency's `self` needs what its method uses, but here it's kept as `N`, which needs nothing
      help: to keep it, name what it needs where it's kept, `(N uses ..d)`, and add `uses ..d` to `N.same`

    error: expected `N`, found `N uses Console`
       ┌─ test.ren:11:11
    11 │   let b = loud().same(3)
       │           ^^^^^^
       = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
       help: say what it needs where its type is written: `(N uses Console)`
    |}]

let%expect_test "a transparent parameter kept where its rows close" =
  (* the interface says what the parameter fails with and uses is the
     function's; kept as a plain `fn() -> Int`, it can't be *)
  types
    {|
pub type Box<R> = { r: R }
pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = Box { r: f }
pub fn sneakyf(f: fn() -> Int) -> Box<fn() -> Int> = store_fn(f)
pub dep Rates =
  usd_to: fn(Int) -> Int
pub fn keep(r: Rates uses ..d) -> Box<Rates uses ..d> = Box { r: r }
pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
fn main() = 1
|};
  [%expect
    {|
    error: `f` is kept where it can't fail or use anything, so it isn't transparent
      ┌─ test.ren:3:16
    3 │ pub fn sneakyf(f: fn() -> Int) -> Box<fn() -> Int> = store_fn(f)
      │                ^
      = a parameter whose type is written `fn(...)` passes what it fails with and uses on to `sneakyf`'s callers, but here it's passed to something that keeps it as a function that can't fail or use anything
      help: to keep it, name its rows, `f: fn(...) ! ..e uses ..d`, and write them where it's kept

    error: `r` is kept where it can't need anything, so it isn't transparent
      ┌─ test.ren:7:15
    7 │ pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
      │               ^
      = a parameter whose type is a dependency's, `Rates`, needs what its function uses, but here it's passed to something that keeps it as an implementation that needs nothing
      help: to keep it, name what it needs, `r: Rates uses ..d`, and write it where it's kept
    |}];
  (* named, they're fine *)
  types
    {|
pub type Box<R> = { r: R }
pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = Box { r: f }
pub fn fine(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d> = store_fn(f)
fn main() = 1
|};
  [%expect
    {|
    pub fn store_fn(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d>
    pub fn fine(f: fn() -> Int ! ..e uses ..d) -> Box<fn() -> Int ! ..e uses ..d>
    fn main() -> Int
    |}]

let%expect_test "why a closure in a with still needs what it installs" =
  types
    {|
dep N =
  get: fn() -> Int

fn fixed(n: Int) -> N = N { get: fn() => n }
fn run_two(f) = (with fixed(1) in f()) + (with fixed(2) in f())
fn main() uses Console =
  print(run_two(fn() => N.get()))
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
      ┌─ test.ren:6:4
    6 │ fn main() uses Console =
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    7 │   print(run_two(fn() => N.get()))
      │         ------------------------ this call uses `N`
      = `run_two` calls a closure inside more than one `with`, so the closure gets only what's installed outside all of them, not the `N` one of them installs
      help: install one inside `main`: `with fixed(...) in ...`
    |}];
  types
    {|
dep N =
  get: fn() -> Int

type A = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = with N { get: fn() => self.n } in try body()
fn main() uses Console =
  let a = A { n: 3 }
  print(with a.wrap() in N.get())
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
      ┌─ test.ren:6:4
    6 │ fn main() uses Console =
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    8 │   print(with a.wrap() in N.get())
      │              -------- this call uses `N`
      = in `A.wrap`, what's called inside the `with` that installs `N` uses what `A.wrap` itself does: a parameter whose type is written `fn(...)`, or a closure that's called outside the `with` too, gets only what's installed outside it
      help: install one inside `main`, with `with`: an implementation is a `N { ... }` that gives each of its operations
    |}]

let%expect_test "an operation given by name, or as a named row" =
  types
    {|
dep N =
  get: fn() -> Int ! Low

fn helper() -> Int ! High =
  fail High
fn f3() -> N = N { get: helper }
fn f4(g: fn() -> Int ! ..e uses ..d) -> (N uses ..d) = N { get: g }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `High`, and `N.get` can't
      ┌─ test.ren:6:25
    6 │ fn f3() -> N = N { get: helper }
      │                         ^^^^^^ fails with `High`
      = `N.get` can fail only with `Low`
      help: give a lambda that calls `helper` and maps what it fails with, with `match` and `fail` arms, to what `N.get` can: `fail High => fail Low`

    error: expected `fn() -> Int ! Low`, found `fn() -> Int ! ..e uses ..d`
      ┌─ test.ren:7:65
    7 │ fn f4(g: fn() -> Int ! ..e uses ..d) -> (N uses ..d) = N { get: g }
      │                                                                 ^
      = `N`'s operation `get`
      help: `g` can fail with anything `..e` stands for, and the operation only with `Low`: write `! Low` in place of `! ..e`
    |}]

let%expect_test "an implementation a function makes can need anything" =
  (* `ren types` shows its open row, which written back keeps it so *)
  let src =
    {|
dep N =
  get: fn() -> Int

fn noisy() -> Int uses Console =
  print(0)
  5
fn loud() -> (N uses Console) = N { get: fn() => noisy() }
fn fixed(n: Int) = N { get: fn() => n }
fn written(n: Int) -> (N uses ..d) = N { get: fn() => n }
fn pick(b: Bool) -> (N uses Console) = if b then written(1) else loud()
fn main() uses Console =
  print(with pick(true) in N.get())
  print(with fixed(2) in N.get())
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn() -> Int
    fn noisy() -> Int uses Console
    fn loud() -> (N uses Console)
    fn fixed(n: Int) -> (N uses ..d)
    fn written(n: Int) -> (N uses ..d)
    fn pick(b: Bool) -> (N uses Console)
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    1
    2
    ()
    |}]

let%expect_test "a handler that keeps a closure names its row" =
  let src =
    {|
pub dep N =
  get: fn() -> Int

handler inferred(f) for N =
  var n = 0
  get() =>
    n += f()
    n

pub handler written(f: fn() -> Int uses ..d) for N uses ..d =
  get() => f()

fn loud() -> Int uses Console =
  print(9)
  1

fn main() uses Console =
  with inferred(fn() => 2) in
    print(N.get())
    print(N.get())
  with written(loud) in
    print(N.get())
|}
  in
  types src;
  [%expect
    {|
    pub dep N
      get: fn() -> Int
    handler inferred(f: fn() -> Int uses ..d) for N uses ..d
    pub handler written(f: fn() -> Int uses ..d) for N uses ..d
    fn loud() -> Int uses Console
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    2
    4
    9
    1
    ()
    |}]

(* ---- 2. nothing reaches the world another way ----

   The built-in dependencies, `Time` and its kin, and what can't be done
   to an operation but call it. *)

let%expect_test "an operation isn't read from an implementation" =
  types
    {|
dep Timer =
  now: fn() -> Int

fn read(c: Timer) = c.now
fn call(c: Timer) = c.now()
fn other(c: Timer) = c.later()
fn main() = 1
|};
  [%expect
    {|
    error: `now` is an operation of `Timer`, so it isn't read from a value
      ┌─ test.ren:4:23
    4 │ fn read(c: Timer) = c.now
      │                       ^^^
      = a value of `Timer` is an implementation of it: it's used by installing it, with `with`, and then `Timer.now` calls it
      help: call the installed one: `Timer.now(...)`

    error: `now` is an operation of `Timer`, so it isn't read from a value
      ┌─ test.ren:5:23
    5 │ fn call(c: Timer) = c.now()
      │                       ^^^
      = a value of `Timer` is an implementation of it: it's used by installing it, with `with`, and then `Timer.now` calls it
      help: call the installed one: `Timer.now(...)`

    error: `Timer` has no operation named `later`
      ┌─ test.ren:6:24
    6 │ fn other(c: Timer) = c.later()
      │                        ^^^^^
      help: its operations: `now`
    |}];
  types {|
dep Timer =
  now: fn() -> Int

fn main() = Timer.later()
|};
  [%expect
    {|
    error: `Timer` has no operation or member named `later`
      ┌─ test.ren:4:19
    4 │ fn main() = Timer.later()
      │                   ^^^^^
      help: its operations: `now`
    |}]

let%expect_test "the real Clock and Random" =
  run
    {|
fn main() uses Clock, Random, Console =
  let start = Clock.instant()
  Clock.sleep(Duration.ms(1))
  print(Clock.instant().not_before(start))
  print(Clock.now().after(Time.epoch))
  print(Random.int(10) < 10)
  Random.int(0)
|};
  [%expect
    {|
    true
    true
    true
    error: panic: `Random.int` needs a number above 0 to stay below, not 0
      ┌─ test.ren:7:3
    7 │   Random.int(0)
      │   ^^^^^^^^^^^^^
    |}]

(* A file of its own, for the real `Fs` to write, read back and remove.
   Each path is shown as a string, so the file is named in a Ren literal. *)
let temp_file () = Filename.temp_file "ren" ".txt"

let%expect_test "the real Fs" =
  let file = temp_file () in
  Sys.remove file;
  run
    (Printf.sprintf
       {|
fn main() ! FsError | InvalidUtf8 uses Fs, Console =
  let p = Path.of("%s")
  print(Fs.exists(p))
  match attempt Fs.read(p)
    Err(NoSuchFile(q)) => print(q == p)
    _ => print("it read a file that isn't there")
  try Fs.write(p, "héllo".bytes())
  print(Fs.exists(p))
  print((try Fs.read(p)).len())
  try Fs.write(p, "again".bytes())
  print(try Fs.read_str(p))
  try Fs.read_str(Path.of("no/such/file.txt"))
|}
       file);
  Sys.remove file;
  [%expect
    {|
    false
    true
    true
    6
    again
    error: NoSuchFile(no/such/file.txt)
    |}];
  (* bytes that aren't UTF-8, written by something else *)
  let file = temp_file () in
  Out_channel.with_open_bin file (fun oc -> output_string oc "\xff");
  run
    (Printf.sprintf
       {|
fn main() ! FsError | InvalidUtf8 uses Fs, Console =
  let p = Path.of("%s")
  print((try Fs.read(p)).len())
  try Fs.read_str(p)
|}
       file);
  Sys.remove file;
  [%expect {|
    1
    error: InvalidUtf8
    |}]

let%expect_test "the real Fs fails, rather than panics" =
  (* a file that may only be read *)
  let locked = temp_file () in
  Unix.chmod locked 0o444;
  Unix.mkdir "a-folder" 0o755;
  run
    (Printf.sprintf
       {|
fn main() ! FsError uses Fs, Console =
  print(Fs.exists(Path.of("a-folder")))
  match attempt Fs.read(Path.of("a-folder"))
    Err(IsAFolder(p)) => print(p)
    _ => print("it read a folder")
  match attempt Fs.write(Path.of("%s"), "x".bytes())
    Err(NotAllowed(_)) => print("not allowed")
    _ => print("it wrote a file it may only read")
  try Fs.write(Path.of("no/such/folder/file.txt"), "x".bytes())
|}
       locked);
  Unix.rmdir "a-folder";
  Sys.remove locked;
  [%expect
    {|
    true
    a-folder
    not allowed
    error: NoSuchFile(no/such/folder/file.txt)
    |}]

let%expect_test "the real Fs is reached only through Fs" =
  types {|
fn main() uses Console =
  print(Fs.real)
  print(fs_read("x"))
|};
  [%expect {|
    error: `Fs` has no operation or member named `real`
      ┌─ test.ren:2:12
    2 │   print(Fs.real)
      │            ^^^^
      help: its operations: `read`, `write`, `exists`; its members: `read_str`

    error: there's no function named `fs_read`
      ┌─ test.ren:3:9
    3 │   print(fs_read("x"))
      │         ^^^^^^^
    |}]

let%expect_test "time, with methods" =
  run
    {|
fn main() =
  let t = Time.epoch.plus(Duration.minutes(5)).plus(Duration.seconds(1))
  print(t.after(Time.epoch))
  print(t == Time.epoch.plus(Duration.ms(301000)))
  let i = Instant.zero.plus(Duration.ms(5))
  print(i.since(Instant.zero) == Duration.ms(5))
  print(Instant.zero.before(i))
  let d = Duration.seconds(2).times(3)
  print(d.in_ms())
  print(d.after(Duration.seconds(5)))
  print(d.before(Duration.seconds(6)))
|};
  [%expect {|
    true
    true
    true
    true
    6000
    true
    false
    ()
    |}]

let%expect_test "the world is reached only through a dependency" =
  types {|
fn main() = clock_now()
|};
  [%expect
    {|
    error: there's no function named `clock_now`
      ┌─ test.ren:1:13
    1 │ fn main() = clock_now()
      │             ^^^^^^^^^
    |}];
  types {|
fn main() = Clock.real
|};
  [%expect
    {|
    error: `Clock` has no operation or member named `real`
      ┌─ test.ren:1:19
    1 │ fn main() = Clock.real
      │                   ^^^^
      help: its operations: `now`, `instant`, `sleep`; its members: `frozen`
    |}]

let%expect_test "an operation is called, not changed or made" =
  types {|
fn main() =
  Clock.now = 1
|};
  [%expect
    {|
    error: `Clock.now` is an operation of a dependency, not a variable
      ┌─ test.ren:2:3
    2 │   Clock.now = 1
      │   ^^^^^^^^^
      help: call it, `Clock.now(...)`; what it does is changed by installing another implementation, with `with`
    |}];
  types {|
fn main() uses Clock = &Clock.now()
|};
  [%expect
    {|
    error: `Clock.now` is a dependency's operation, and its call never takes `&`
      ┌─ test.ren:1:24
    1 │ fn main() uses Clock = &Clock.now()
      │                        ^^^^^^^^^^^^
      = what an operation changes belongs to the implementation installed for it, a handler's state say, which isn't a value the caller holds
      help: remove the `&`
    |}];
  types
    {|
dep Users =
  get: fn(id: Int) -> Option<Int>

fn main() = Users.Foo
|};
  [%expect
    {|
    error: `Users` is a dependency, so it has no constructors
      ┌─ test.ren:4:13
    4 │ fn main() = Users.Foo
      │             ^^^^^^^^^
      help: make an implementation of it with `Users { ... }`, giving each of its operations
    |}]

let%expect_test "the prelude's names are taken" =
  types
    {|
type Time = { at: Int }
dep Clock =
  now: fn() -> Int
fn main() = 1
|};
  [%expect
    {|
    error: the prelude already has a type named `Time`
      ┌─ test.ren:1:6
    1 │ type Time = { at: Int }
      │      ^^^^
      = the prelude's types and dependencies, like `Option`, `Time` and `Clock`, can be named in every module
      help: choose another name

    error: the prelude already has a dependency named `Clock`
      ┌─ test.ren:2:5
    2 │ dep Clock =
      │     ^^^^^
      = the prelude's types and dependencies, like `Option`, `Time` and `Clock`, can be named in every module
      help: choose another name
    |}]

(* ---- 3. a missing implementation is a compile error ----

   At `main`, in a test, and in a group's run, naming the dependency and
   the call that needs it. *)

let%expect_test "the real Os and Proc" =
  run ~args:[ "build"; "a b" ]
    {|
fn main() ! ProcError uses Os, Proc, Console =
  print(Os.args())
  // what's printed before a program runs comes out before what it prints
  print("before")
  print(try Proc.run("sh", ["-c", "echo $0 $1; exit 3", "x", "y z"]))
  print(try Proc.run("true", []))
  match attempt Proc.run("no-such-program", [])
    Err(NoSuchProgram(name)) => print(name)
    _ => print("it ran a program that isn't there")
  print(try Proc.run("/bin/sh", ["-c", "exit 0"]))
  try Proc.run("./no/such/program", [])
|};
  [%expect
    {|
    ["build", "a b"]
    before
    x y z
    3
    0
    no-such-program
    0
    error: NoSuchProgram("./no/such/program")
    |}];
  run {|
fn main() uses Os, Console =
  print(Os.args())
|};
  [%expect {|
    []
    ()
    |}]

let%expect_test "the real Os panics at an argument that isn't UTF-8" =
  run ~args:[ "ok"; "\xff\xfe" ]
    {|
fn main() uses Os, Console =
  print(Os.args())
|};
  [%expect {|
    error: panic: argument 2 isn't UTF-8
      ┌─ test.ren:2:9
    2 │   print(Os.args())
      │         ^^^^^^^^^
    |}]

let%expect_test "the real Proc fails when a program can't run, or finish" =
  (* A file that's there, but may not be run. A file that may be run but
     isn't a program is left to the system: Linux refuses it, and macOS
     runs it with `sh`. *)
  let file = "not-runnable" in
  Out_channel.with_open_bin file (fun oc -> output_string oc "#!/bin/sh\n");
  Unix.chmod file 0o644;
  run
    {|
fn main() ! ProcError uses Proc, Console =
  match attempt Proc.run("./not-runnable", [])
    Err(CantRun(name, reason)) => print([name, reason])
    _ => print("it ran a file that may not be run")
  try Proc.run("sh", ["-c", "kill -9 $$"])
|};
  Sys.remove file;
  [%expect {|
    ["./not-runnable", "Permission denied"]
    error: Killed("sh")
    |}]

let%expect_test "the real Os and Proc are reached only through them" =
  types
    {|
fn main() uses Console =
  print(Proc.real)
  print(os_args())
  print(proc_run("sh", []))
|};
  [%expect {|
    error: `Proc` has no operation or member named `real`
      ┌─ test.ren:2:14
    2 │   print(Proc.real)
      │              ^^^^
      help: its operations: `run`

    error: there's no function named `os_args`
      ┌─ test.ren:3:9
    3 │   print(os_args())
      │         ^^^^^^^

    error: there's no function named `proc_run`
      ┌─ test.ren:4:9
    4 │   print(proc_run("sh", []))
      │         ^^^^^^^^
    |}]

let%expect_test "main lists Fs to get the real one" =
  types {|
fn load() -> Bool uses Fs = Fs.exists(Path.of("x"))

fn main() uses Console = print(load())
|};
  [%expect {|
    error: `main` doesn't declare `Fs`
      ┌─ test.ren:3:4
    3 │ fn main() uses Console = print(load())
      │    ^^^^
      │                                ------ this call uses `Fs`
      = `main`'s body can only use what its `uses` lists
      help: add `Fs` to its `uses`
    |}];
  test
    {|
test "the real file system, and the test clock" uses Fs, Clock =
  TestClock.advance(Duration.ms(1))
  assert not Fs.exists(Path.of("no/such/file.txt"))
|};
  [%expect {|
    error: nothing installs `TestClock` in the test "the real file system, and the test clock"
      ┌─ test.ren:1:6
    1 │ test "the real file system, and the test clock" uses Fs, Clock =
      │      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ this test gets only the real `Fs` and `Clock`, and the test `Random`, `Console`, `Os` and `Proc`, and what controls them
    2 │   TestClock.advance(Duration.ms(1))
      │   --------------------------------- this call uses `TestClock`
      = the test asks for the real `Clock`, which `TestClock` can't control
      help: remove `Clock` from the test's `uses`, to get the test one
    |}]

let%expect_test "the runtime installs only the built-in dependencies main uses"
    =
  run {|
fn main() =
  print(1)
  Console.write("written")
|};
  [%expect {|
    1
    written
    ()
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

  pub fn none() -> Users = Users { get: fn(_) => None }

fn main() uses Users, Console =
  print(Users.get(1))
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:6:16
    6 │ fn main() uses Users, Console =
      │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    7 │   print(Users.get(1))
      │         ------------ this call uses `Users`
      help: install one inside `main`: `with Users.none() in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

fn mem_users(ids: Array<Int>) -> Users = Users { get: fn(id) => None }
fn find(id: Int) = Users.get(id)

fn main() = print(find(1))
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:7:4
    7 │ fn main() = print(find(1))
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      │                   ------- this call uses `Users`
      help: install one inside `main`: `with mem_users(...) in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

fn main() uses Net = print(Users.get(1))
|};
  [%expect
    {|
    error: `main` doesn't declare `Console`
      ┌─ test.ren:4:4
    4 │ fn main() uses Net = print(Users.get(1))
      │    ^^^^
      │                      ------------------- this call uses `Console`
      = `main`'s body can only use what its `uses` lists
      help: add `Console` to its `uses`

    error: nothing installs `Users` before `main`
      ┌─ test.ren:4:4
    4 │ fn main() uses Net = print(Users.get(1))
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      │                            ------------ this call uses `Users`
      help: install one inside `main`, with `with`: an implementation is a `Users { ... }` that gives each of its operations

    error: nothing installs `Net` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Net = print(Users.get(1))
      │                ^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
      help: remove it: nothing can implement `Net` yet
    |}]

let%expect_test
    "main's help suggests only an implementation that can be installed" =
  (* one that needs what it implements would need one installed before it *)
  types
    {|
dep Log =
  put: fn(n: Int)
fn doubling() = Log { put: fn(n) => Log.put(n * 2) }
fn main() uses Log =
  Log.put(1)
|};
  [%expect
    {|
    error: nothing installs `Log` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Log =
      │                ^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    5 │   Log.put(1)
      │   ---------- this call uses `Log`
      help: install one inside `main`, with `with`: an implementation is a `Log { ... }` that gives each of its operations
    |}]

let%expect_test "main is told a handler can install what it uses" =
  types (rates ^ {|
fn main() uses Rates, Console = print(convert(1))
|});
  [%expect
    {|
    error: nothing installs `Rates` before `main`
       ┌─ test.ren:16:16
    16 │ fn main() uses Rates, Console = print(convert(1))
       │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
       │                                       ---------- this call uses `Rates`
       help: install one inside `main`: `with counting_rates(...) in ...`
    |}]

let%expect_test "what a test can't use" =
  test
    {|
dep Users =
  count: fn() -> Int

  pub fn none() -> Users = Users { count: fn() => 0 }

test "counts users" =
  assert Users.count() == 0

test "the system clock" uses Clock =
  TestClock.advance(Duration.ms(1))
|};
  [%expect
    {|
    error: nothing installs `Users` in the test "counts users"
      ┌─ test.ren:6:6
    6 │ test "counts users" =
      │      ^^^^^^^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`, and what controls them
    7 │   assert Users.count() == 0
      │          ------------- this call uses `Users`
      help: install one inside the test: `with Users.none() in ...`

    error: nothing installs `TestClock` in the test "the system clock"
       ┌─ test.ren:9:6
     9 │ test "the system clock" uses Clock =
       │      ^^^^^^^^^^^^^^^^^^ this test gets only the real `Clock`, and the test `Random`, `Console`, `Fs`, `Os` and `Proc`, and what controls them
    10 │   TestClock.advance(Duration.ms(1))
       │   --------------------------------- this call uses `TestClock`
       = the test asks for the real `Clock`, which `TestClock` can't control
       help: remove `Clock` from the test's `uses`, to get the test one
    |}];
  test
    {|
dep Users =
  count: fn() -> Int

test "users" uses Users, ..d =
  ()
|};
  [%expect
    {|
    error: a test's `uses` asks for a real implementation, and only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc` have one, not `Users`
      ┌─ test.ren:4:19
    4 │ test "users" uses Users, ..d =
      │                   ^^^^^
      = a test gets the test implementation of each of them unless its `uses` asks for the real one
      help: install an implementation inside the test, with `with`, and remove it from here

    error: a test can't name a row: its `uses` lists what it gets the real implementation of
      ┌─ test.ren:4:28
    4 │ test "users" uses Users, ..d =
      │                            ^
      help: remove it
    |}]

let%expect_test "a group's run needs what its tests use" =
  test
    {|
dep Users =
  count: fn() -> Int

  pub fn none() -> Users = Users { count: fn() => 0 }

group counts(c: Clock) with c =
  test "counts users" =
    assert Users.count() == 0

group "frozen" = counts(Clock.frozen(Time.epoch))
|};
  [%expect
    {|
    error: nothing installs `Users` in the test "frozen / counts users"
       ┌─ test.ren:10:7
    10 │ group "frozen" = counts(Clock.frozen(Time.epoch))
       │       ^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`, and what controls them
       │                  -------------------------------- this call uses `Users`
       help: install one around each of its tests, in the group's `with`: `group counts(...) with Users.none() =`
    |}]

let%expect_test "a group's run needs what its tests use, from another module" =
  test_files
    [
      ("main.ren", {|
import conform

group "frozen" = conform.counts()
|});
      ( "conform.ren",
        {|
pub dep Users =
  count: fn() -> Int

pub group counts() =
  test "counts users" =
    assert Users.count() == 0
|}
      );
    ];
  [%expect
    {|
    error: nothing installs `conform.Users` in the test "frozen / counts users"
      ┌─ main.ren:3:7
    3 │ group "frozen" = conform.counts()
      │       ^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`, and what controls them
      │                  ---------------- this call uses `conform.Users`
      help: `conform.counts` is another module's group, so pass one in: give the group a parameter of type `conform.Users` that its `with` installs, and pass an implementation to it here
    |}]

(* ---- 4. swapping is one line, and a test needs none ----

   Implementations, `with` and wrappers, handlers, and tests and groups
   with the test implementations they get. *)

let%expect_test "an implementation is a record of its operations" =
  types
    {|
dep Timer =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn frozen(at: Int) -> Timer = Timer { now: fn() => at, sleep: fn(_) => () }
fn main() = frozen(0)
|};
  [%expect
    {|
    dep Timer
      now: fn() -> Int
      sleep: fn(Int)
    fn frozen(at: Int) -> Timer
    fn main() -> Timer
    |}];
  types
    {|
dep Timer =
  now: fn() -> Int
  sleep: fn(ms: Int)

fn half() = Timer { now: fn() => 1 }
fn typo() = Timer { now: fn() => 1, slep: fn(_) => () }
fn wrong() = Timer { now: fn() => true, sleep: fn(_) => () }
fn main() = 1
|};
  [%expect
    {|
    error: this `Timer` is missing `sleep`
      ┌─ test.ren:5:13
    5 │ fn half() = Timer { now: fn() => 1 }
      │             ^^^^^^^^^^^^^^^^^^^^^^^^
      help: give it a value too, like `sleep: ...`

    error: `Timer` has no operation named `slep`
      ┌─ test.ren:6:37
    6 │ fn typo() = Timer { now: fn() => 1, slep: fn(_) => () }
      │                                     ^^^^
      help: its operations: `now`, `sleep`

    error: this lambda produces a `Bool`, but it has to produce an `Int`
      ┌─ test.ren:7:35
    7 │ fn wrong() = Timer { now: fn() => true, sleep: fn(_) => () }
      │                                   ^^^^
      = `Timer`'s operation `now`
    |}]

let%expect_test "with's syntax" =
  ast
    {|
fn main() =
  with Clock.frozen(t), counting(1) in
    body()
  with retry(3) in try f()
  g(with a in 1, 2)
|};
  [%expect
    {| (fn main () (block (with (call (. (con Clock) frozen) t) (with (call counting 1) (call body))) (with (call retry 3) (try (call f))) (call g (with a 1) 2))) |}];
  ast {|
fn main() = with a b in 1
|};
  [%expect
    {|
    error: expected `,` or `in` after what `with` installs, found `b`
      ┌─ test.ren:1:20
    1 │ fn main() = with a b in 1
      │                    ^
      help: write what it installs, then `in`, then the code it's installed around
    |}];
  (* what a signature writes: what an implementation needs, what a
     function type uses, and named rows *)
  types
    {|
fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad | ..e uses Clock) -> (Clock uses Random, ..d)
    ! ..e
    uses ..d =
  c
fn h(k: Option<fn() uses Clock>, m: (Int)) = 1
fn main() = 1
|};
  [%expect
    {|
    fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad | ..e uses Clock) -> (Clock uses Random, ..d) ! ..e uses ..d
    fn h(k: Option<fn() uses Clock>, m: Int) -> Int
    fn main() -> Int
    |}];
  (* `with` is a keyword now *)
  ast {|
fn with() = 1
|};
  [%expect
    {|
    error: expected a name, found `with`
      ┌─ test.ren:1:4
    1 │ fn with() = 1
      │    ^^^^
    |}]

let%expect_test "with installs around its body, and the innermost wins" =
  let src =
    {|
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn stamp() = Clock.now()
fn main() uses Console =
  print(with at(1) in stamp())
  print(with at(1), at(2) in stamp())
  with at(3) in
    print(stamp())
    print(with at(4) in stamp())
    print(stamp())
|}
  in
  types src;
  [%expect
    {|
    fn at(minutes: Int) -> Clock
    fn stamp() -> Time uses Clock
    fn main() uses Console
    |}];
  core src;
  [%expect
    {|
    (fn at (minutes/1) ev/2
      (call ev/2 Clock.frozen
        (call ev/2 Time.plus Time.epoch (call ev/2 Duration.minutes minutes/1))))
    (fn stamp () ev/1 (dep-call ev/1 Clock.now))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (with ev/2 (extend ev/1 Clock (call ev/1 at 1)) (call ev/2 stamp)))
        (seq
          (call ev/1 print
            (with ev/3 (extend ev/1 Clock (call ev/1 at 1))
              (with ev/4 (extend ev/3 Clock (call ev/3 at 2)) (call ev/4 stamp))))
          (with ev/5 (extend ev/1 Clock (call ev/1 at 3))
            (seq (call ev/5 print (call ev/5 stamp))
              (seq
                (call ev/5 print
                  (with ev/6 (extend ev/5 Clock (call ev/5 at 4))
                    (call ev/6 stamp)))
                (call ev/5 print (call ev/5 stamp))))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect
    {|
    Time(60000)
    Time(120000)
    Time(180000)
    Time(240000)
    Time(180000)
    ()
    |}]

let%expect_test "with removes what it installs from the body's uses" =
  types
    {|
dep Users =
  get: fn(id: Int) -> Int
fn none() -> Users = Users { get: fn(_) => 0 }
fn find() = Users.get(1)
fn found() = with none() in find()
pub fn public() -> Int = with none() in find()
fn main() = 1
|};
  [%expect
    {|
    dep Users
      get: fn(Int) -> Int
    fn none() -> Users
    fn find() -> Int uses Users
    fn found() -> Int
    pub fn public() -> Int
    fn main() -> Int
    |}]

let%expect_test "a with's body uses no more than what's outside it" =
  (* a closure called both inside a `with` and outside it, a closure
     parameter called inside one, and a dependency parameter installed
     inside another: each uses what's outside, which is less than the
     body can *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn run_at(f: fn() -> Int) -> Int = with at(1) in try f()
fn run_inferred(f) = with at(1) in try f()
fn convert(r: Rates) = with Clock.frozen(Time.epoch) in with r in Rates.usd_to(4)
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn local() uses Console =
  let k = fn() => print(Clock.now())
  with at(2) in k()
  with at(3) in
    k()
    with Rates { usd_to: fn(c) => c } in k()
fn main() uses Console, Clock =
  let pure = fn() => 5
  print(with at(1) in pure())
  print(pure())
  print(run_at(fn() => 6))
  print(run_inferred(fn() => Clock.now()))
  print(convert(timed()))
  local()
|}
  in
  types src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    fn at(minutes: Int) -> Clock
    fn run_at(f: fn() -> Int) -> Int
    fn run_inferred<T>(f: fn() -> T ! ..e uses Clock, ..d) -> T ! ..e uses ..d
    fn convert(r: Rates) -> Int
    fn timed() -> (Rates uses Clock, ..d)
    fn local() uses Console
    fn main() uses Clock, Console
    |}];
  run src;
  [%expect
    {|
    5
    5
    6
    Time(60000)
    0
    Time(120000)
    Time(180000)
    Time(180000)
    ()
    |}];
  (* a closure parameter called inside a `with`: an inferred one may use
     what it installs, and one whose type is written transparent passes
     everything it uses on (deps.md, "Deviations") *)
  types
    {|
fn inferred(f) = with Clock.frozen(Time.epoch) in try f()
fn written(f: fn() -> Time) -> Time = with Clock.frozen(Time.epoch) in try f()
fn main() uses Console =
  print(inferred(fn() => Clock.now()))
  print(written(fn() => Clock.now()))
|};
  [%expect
    {|
    error: `main` doesn't declare `Clock`
      ┌─ test.ren:3:4
    3 │ fn main() uses Console =
      │    ^^^^
    5 │   print(written(fn() => Clock.now()))
      │         ---------------------------- this call uses `Clock`
      = `main`'s body can only use what its `uses` lists
      = in `written`, what's called inside the `with` that installs `Clock` uses what `written` itself does: a parameter whose type is written `fn(...)`, or a closure that's called outside the `with` too, gets only what's installed outside it
      help: add `Clock` to its `uses`
    |}];
  (* a signature that says so, called where the caller uses the same
     dependency itself *)
  run
    {|
fn run_at(f: fn() -> Int uses Clock, ..d) -> Int uses ..d =
  with Clock.frozen(Time.epoch) in f()
fn main() uses Console, Clock =
  print(run_at(fn() => if Clock.now().after(Time.epoch) then 1 else 2))
|};
  [%expect {|
    2
    ()
    |}];
  (* a function calling itself, or one of its group, inside a `with` *)
  run
    {|
dep Log =
  put: fn(n: Int)
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn logger(base: Int) = Log { put: fn(n) => print(base + n) }
fn walk(n: Int) =
  if n > 0 then
    print(Clock.now())
    with at(n) in walk(n - 1)
fn ping(n: Int) =
  if n > 0 then
    Log.put(n)
    with logger(n * 100) in pong(n - 1)
fn pong(n: Int) =
  if n > 0 then
    Log.put(n)
    ping(n - 1)
fn main() uses Console =
  with at(7) in walk(3)
  with logger(0) in ping(4)
|};
  [%expect
    {|
    Time(420000)
    Time(180000)
    Time(120000)
    4
    403
    402
    201
    ()
    |}];
  (* a function calling itself inside a `with` doesn't use what the `with`
     installs: the call uses what the function does outside it *)
  types
    {|
fn count(n: Int) -> Int =
  if n == 0 then 0
  else
    with Clock.frozen(Time.epoch) in
      let _ = Clock.now()
      count(n - 1) + 1
fn loud(n: Int) -> Int =
  print(n)
  if n == 0 then 0
  else
    with Clock.frozen(Time.epoch) in
      let _ = Clock.now()
      loud(n - 1)
fn main() uses Console =
  print(count(3))
  print(loud(1))
|};
  [%expect {|
    fn count(n: Int) -> Int
    fn loud(n: Int) -> Int uses Console
    fn main() uses Console
    |}]

let%expect_test "with installs an implementation or wraps its body" =
  types {|
fn bad() = with 3 in 1
fn unknown(c) = with c in 1
fn main() = 1
|};
  [%expect
    {|
    error: `with` installs an implementation, or wraps its body, but this is an `Int`
      ┌─ test.ren:1:17
    1 │ fn bad() = with 3 in 1
      │                 ^
      = `with` installs an implementation of a dependency around its body, or passes its body to a wrapper, a function whose last parameter is the body
      help: give it an implementation, like `Clock.frozen(t)`, or a wrapper's call without its last argument, like `retry(3)`

    error: `with` can't tell what this installs: its type isn't known here
      ┌─ test.ren:2:22
    2 │ fn unknown(c) = with c in 1
      │                      ^
      = `with` installs an implementation of a dependency around its body, or passes its body to a wrapper, a function whose last parameter is the body
      help: say what it is where it's declared, like `c: Clock`
    |}]

let%expect_test "a wrapper is passed the body" =
  let src =
    {|
fn flaky(n: Int) -> Int ! Boom =
  if n < 3 then fail Boom else n

fn retry(n: Int, body: fn() -> Int) -> Int =
  let r = attempt body()
  if n <= 1 then try r
  else
    match r
      Ok(v) => v
      Err(_) => try retry(n - 1, body)

fn twice(body: fn() -> Int) -> Int = try body() + try body()

pub fn safe() -> Int = with retry(3) in 1

fn main() uses Console =
  print(attempt with retry(3) in try flaky(2))
  print(attempt with retry(3) in try flaky(4))
  print(with twice in 21)
|}
  in
  types src;
  [%expect
    {|
    fn flaky(n: Int) -> Int ! Boom
    fn retry(n: Int, body: fn() -> Int) -> Int
    fn twice(body: fn() -> Int) -> Int
    pub fn safe() -> Int
    fn main() uses Console
    |}];
  core src;
  [%expect
    {|
    (fn flaky (n/1) ev/2 (if (< n/1 3) (fail (tag Boom)) n/1))
    (fn retry (n/1 body/2) ev/3
      (let r/4
        (handle (call ev/3 body/2) ($value/5 => (con Ok $value/5))
          (fail $error/6 => (con Err $error/6)))
        (if (<= n/1 1)
          (match r/4 ((Ok $value/7) => $value/7)
            ((Err $error/8) => (fail $error/8)))
          (match r/4 ((Ok v/9) => v/9)
            ((Err _) => (call ev/3 retry (- n/1 1) body/2))))))
    (fn twice (body/1) ev/2 (+ (call ev/2 body/1) (call ev/2 body/1)))
    (fn safe () ev/1 (call ev/1 retry 3 (lambda () (captures) ev/2 1)))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (handle
            (call ev/1 retry 3 (lambda () (captures) ev/2 (call ev/2 flaky 2)))
            ($value/3 => (con Ok $value/3))
            (fail $error/4 => (con Err $error/4))))
        (seq
          (call ev/1 print
            (handle
              (call ev/1 retry 3 (lambda () (captures) ev/5 (call ev/5 flaky 4)))
              ($value/6 => (con Ok $value/6))
              (fail $error/7 => (con Err $error/7))))
          (call ev/1 print (call ev/1 twice (lambda () (captures) ev/8 21))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    Err(Boom)
    Ok(4)
    42
    ()
    |}]

let%expect_test "a method is a wrapper too" =
  run
    {|
type W = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = self.n * (try body())
  fn times(n: Int, body: fn() -> Int) -> Int = n + (try body())
fn main() uses Console =
  let w = W { n: 3 }
  print(with w.wrap() in 5)
  print(with W.times(3) in 5)
  print(with w.wrap(), w.wrap() in 2)
  print(attempt with w.wrap() in fail Nope)
|};
  [%expect {|
    15
    8
    18
    Err(Nope)
    ()
    |}];
  types
    {|
type W = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = self.n * (try body())
  fn bump(inout self, body: fn() -> Int) -> Int = try body()
fn main() uses Console =
  var w = W { n: 3 }
  print(with w.wrap in 5)
  print(with w.bump() in 5)
|};
  [%expect
    {|
    error: `wrap` is a method, so it has to be called
      ┌─ test.ren:6:16
    6 │   print(with w.wrap in 5)
      │                ^^^^
      help: write `w.wrap()`, or use `W.wrap` as a function

    error: `bump` changes its receiver, so it can't wrap a body
      ┌─ test.ren:7:14
    7 │   print(with w.bump() in 5)
      │              ^^^^^^^^
      = `with r.w(a) in body` calls `r.w(a, fn() => body)`, and a `with`'s item can't change what it's called on
      help: call `bump` outside the `with`, with all its arguments
    |}]

let%expect_test "what a wrapper can't be" =
  types
    {|
fn grab(n: Int, inout body: fn() -> Int) -> Int = 1
fn intish(n: Int, body: Int) -> Int = body
fn twice(body: fn() -> Int) -> Int = try body() + try body()
fn main() =
  var n = 1
  let a = with grab(1) in 2
  let b = with intish(3) in 2
  let c = with twice in
    n += 1
    n
  a + b + c
|};
  [%expect
    {|
    error: `grab` changes its last argument, so it can't take a body
      ┌─ test.ren:6:16
    6 │   let a = with grab(1) in 2
      │                ^^^^^^^
      = `with w(a) in body` calls `w(a, fn() => body)`, and a lambda isn't a place to change
      help: call `grab` outside the `with`, with all its arguments

    error: `intish`'s last parameter is an `Int`, but a `with` passes it its body, a `fn()`
      ┌─ test.ren:7:16
    7 │   let b = with intish(3) in 2
      │                ^^^^^^^^^
      = `with w(a) in body` calls `w(a, fn() => body)`, so the wrapper's last parameter is a function of no parameters
      help: call `intish` outside the `with`, with all its arguments

    error: the body of this `with` can't change `n`, a variable from outside it
      ┌─ test.ren:9:5
    9 │     n += 1
      │     ^
      = `with` passes its body to `twice` as a lambda, `fn() => ...`, which captures the values of the variables it uses when it's made, so changing them would have no effect outside
      help: give the body's result back as its value instead
    |}]

let%expect_test "a handler implements several dependencies sharing one state" =
  ast rates;
  [%expect
    {|
    (dep Rates (ops usd_to:fn(Int) -> Int))
    (dep RateCalls (ops count:fn() -> Int))
    (fn counting_rates (rate) (handler (for Rates RateCalls) (var calls 0) (usd_to (lambda (_) (block (+= calls 1) rate))) (count (lambda () calls))))
    (fn convert (n) (uses Rates) (* n (call (. (con Rates) usd_to) 1)))
    |}];
  let src =
    rates
    ^ {|
fn main() uses Console =
  with counting_rates(3) in
    print(convert(2))
    print(convert(5))
    print(RateCalls.count())
|}
  in
  types src;
  [%expect
    {|
    dep Rates
      usd_to: fn(Int) -> Int
    dep RateCalls
      count: fn() -> Int
    handler counting_rates(rate: Int) for Rates, RateCalls
    fn convert(n: Int) -> Int uses Rates
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    6
    15
    2
    ()
    |}]

let%expect_test "each with makes a fresh instance" =
  run
    (rates
   ^ {|
fn calls() uses Rates, RateCalls =
  let _ = convert(1)
  RateCalls.count()

fn main() uses Console =
  let h = counting_rates(2)
  with h in
    print(calls())
    print(calls())
  with h in
    print(calls())
  with counting_rates(2), counting_rates(5) in
    print(calls())
    print(convert(1))
|}
    );
  [%expect {|
    1
    2
    1
    1
    5
    ()
    |}]

let%expect_test "a failing arm still changes its state" =
  run
    {|
dep N =
  get: fn() -> Int ! Low

handler counted() for N =
  var calls = 0
  get() =>
    calls += 1
    if calls < 3 then fail Low else calls

fn main() uses Console =
  with counted() in
    print(attempt N.get())
    print(attempt N.get())
    print(attempt N.get())
|};
  [%expect {|
    Err(Low)
    Err(Low)
    Ok(3)
    ()
    |}]

let%expect_test "an arm changes its state through `&` too" =
  (* a method or function that takes the `var` with `&` writes it back, and
     so does the arm, even when it fails afterwards *)
  run
    {|
dep N =
  next: fn() -> Int ! Low

type C = { v: Int }
  fn inc(inout self) = self.v += 1

fn bump(inout x: Int) = x += 1

handler h() for N =
  var arr = [0]
  var n = 0
  var c = C { v: 0 }
  next() =>
    &arr.push(1)
    bump(&n)
    &c.inc()
    if n == 2 then fail Low else arr.len() * 100 + n * 10 + c.v

fn main() uses Console =
  with h() in
    print(attempt N.next())
    print(attempt N.next())
    print(attempt N.next())
|};
  [%expect {|
    Ok(211)
    Err(Low)
    Ok(433)
    ()
    |}]

let%expect_test "what a handler's declaration can't be" =
  types
    {|
dep A =
  x: fn() -> Int
  y: fn() -> Int

dep B =
  x: fn() -> Int
  z: fn(n: Int) -> Int

type T = { a: Int }

handler missing() for A =
  x() => 1

handler unknown() for A =
  x() => 1
  y() => 2
  w() => 3

handler twice() for A =
  x() => 1
  x() => 2
  y() => 3

handler both() for A, B =
  x() => 1
  y() => 2
  z(n) => n

handler not_dep() for T, A, A =
  x() => 1
  y() => 2

handler net() for Net =
  get() => 1

handler change(inout n: Int) for A =
  x() => n
  y() => n

fn main() = 1
|};
  [%expect
    {|
    error: the handler `missing` doesn't implement `A.y`
       ┌─ test.ren:11:9
    11 │ handler missing() for A =
       │         ^^^^^^^
       help: add `y(...) => ...`

    error: `A` has no operation named `w`
       ┌─ test.ren:17:3
    17 │   w() => 3
       │   ^
       help: the operations it implements: `A.x`, `A.y`

    error: `x` is implemented twice
       ┌─ test.ren:21:3
    20 │   x() => 1
       │   - the first `x` is here
    21 │   x() => 2
       │   ^
       help: remove one of them

    error: `A` and `B` both have an operation named `x`
       ┌─ test.ren:25:3
    25 │   x() => 1
       │   ^
       = an arm implements an operation by its name, so `x` could be either
       help: implement them in two handlers

    error: `T` is a type, not a dependency
       ┌─ test.ren:29:23
    29 │ handler not_dep() for T, A, A =
       │                       ^
       help: a dependency is declared with `dep`, and lists the operations a function can call on it

    error: `A` is after `for` twice
       ┌─ test.ren:29:29
    29 │ handler not_dep() for T, A, A =
       │                             ^
       │                          - the first `A` is here
       help: remove one of them

    error: `Net` has no operations, so a handler can't implement it
       ┌─ test.ren:33:19
    33 │ handler net() for Net =
       │                   ^^^
       = `Net` is only a name so far: what it can do comes in a later stage
       help: remove it from the `for` list

    error: a handler's parameter can't be `inout`
       ┌─ test.ren:36:22
    36 │ handler change(inout n: Int) for A =
       │                      ^
       = calling a handler describes it, and each `with` that installs it keeps its parameters, so there's nothing to write back
       help: remove the `inout`
    |}]

let%expect_test "a lambda in an arm can't change the handler's state" =
  types
    {|
dep A =
  x: fn() -> Int

handler h() for A =
  var n = 0
  x() =>
    let f = fn() => n += 1
    n += 1
    n

fn main() = 1
|};
  [%expect
    {|
    error: a lambda can't change `n`, a variable from outside it
      ┌─ test.ren:7:21
    7 │     let f = fn() => n += 1
      │                     ^
      = a lambda captures the values of the variables it uses when it's created, so changing them would have no effect outside
    |}]

let%expect_test "a handler's state comes before its arms" =
  ast
    {|
dep A =
  x: fn() -> Int

handler h() for A =
  x() => 1
  var n = 0

handler g for A =
  x() => 1

handler f() =
  x() => 1
|};
  [%expect
    {|
    error: a handler's state comes first, before its operations
      ┌─ test.ren:6:3
    6 │   var n = 0
      │   ^^^
      help: move it above the handler's first operation

    error: expected `(` after the handler's name, found `for`
      ┌─ test.ren:8:11
    8 │ handler g for A =
      │           ^^^
      help: write its parameters, `handler g() for ...`, even if it has none

    error: expected `for` and the dependencies it implements, found `=`
       ┌─ test.ren:11:13
    11 │ handler f() =
       │             ^
       help: say what it implements: `handler f(...) for Clock =`
    |}]

let%expect_test "another module's handler" =
  let files =
    [
      ( "main.ren",
        {|
import fx

fn main() uses Console =
  with fx.counting(4) in
    print(fx.Rates.usd_to(1) + fx.Rates.usd_to(1))
    print(fx.RateCalls.count())
|}
      );
      ( "fx.ren",
        {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

pub handler counting(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(c) =>
    calls += 1
    c * rate
  count() => calls
|}
      );
    ]
  in
  types_files files;
  [%expect
    {|
    -- fx
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub dep RateCalls
      count: fn() -> Int
    pub handler counting(rate: Int) for Rates, RateCalls

    -- main
    fn main() uses Console
    |}];
  run_files files;
  [%expect {|
    8
    2
    ()
    |}]

let%expect_test "a handler's state is made where it's installed, and can't fail"
    =
  types
    {|
dep N =
  get: fn() -> Int

fn bad() -> Int ! Oops = fail Oops

handler h() for N =
  var n = try bad()
  get() => n

fn main() = 1
|};
  [%expect
    {|
    error: this can fail with Oops, which isn't allowed here
      ┌─ test.ren:7:15
    7 │   var n = try bad()
      │               ^^^^^
      = a handler's state is made where a `with` installs it, which can't fail
      help: handle it here, with `attempt` or a `match` with `fail` arms, or make the value in an operation instead
    |}]

let%expect_test "a handler of one dependency is a value of its type" =
  (* calling it describes it, and each `with` that installs it, wherever
     it's been passed, makes a fresh instance *)
  let src =
    {|
pub dep N =
  next: fn() -> Int

handler counter() for N =
  var n = 0
  next() =>
    n += 1
    n

fn twice(r: N) -> Int = with r in N.next() * 10 + N.next()

pub fn made() -> N = counter()

fn fixed(k: Int) -> N = N { next: fn() => k }

fn main() uses Console =
  print(twice(counter()))
  let c = counter()
  print(twice(c))
  print(twice(c))
  print(twice(made()))
  print(twice(fixed(4)))
  let all = [counter(), fixed(7)]
  print(twice(all[0]) + twice(all[1]))
  with c in
    print(N.next())
|}
  in
  types src;
  [%expect
    {|
    pub dep N
      next: fn() -> Int
    handler counter() for N
    fn twice(r: N) -> Int
    pub fn made() -> N
    fn fixed(k: Int) -> N
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    12
    12
    12
    12
    44
    89
    1
    ()
    |}]

let%expect_test "a handler of several is taken as the one that's wanted" =
  (* where a value of one of its dependencies' types is wanted, it
     describes an implementation of just that one: installing it installs
     only that, and the other comes from further out *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(c) =>
    calls += 1
    c * rate
  count() => calls

fn convert(r: Rates) -> Int = with r in Rates.usd_to(1) + Rates.usd_to(2)

pub fn mem() -> Rates = counting_rates(5)

fn counted(r: Rates) uses RateCalls =
  with r in Rates.usd_to(1) * 100 + RateCalls.count()

fn main() uses Console =
  print(convert(counting_rates(3)))
  print(convert(mem()))
  let r: Rates = counting_rates(2)
  print(convert(r))
  with counting_rates(7) in
    let _ = Rates.usd_to(1)
    print(counted(counting_rates(2)))
  let h = counting_rates(4)
  print(convert(h))
  with h in
    print(Rates.usd_to(1))
    print(RateCalls.count())
|}
  in
  types src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub dep RateCalls
      count: fn() -> Int
    handler counting_rates(rate: Int) for Rates, RateCalls
    fn convert(r: Rates) -> Int
    pub fn mem() -> Rates
    fn counted(r: Rates) -> Int uses RateCalls
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    9
    15
    6
    201
    12
    4
    1
    ()
    |}];
  core
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler both() for Rates, RateCalls =
  usd_to(c) => c
  count() => 0

fn convert(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() -> Int = convert(both())
|};
  [%expect
    {|
    (fn both () ev/1
      (handler (captures) ev/2
        (instance
          (test.Rates: (record (usd_to: (lambda (c/3) (captures) ev/4 c/3))))
          (test.RateCalls: (record (count: (lambda () (captures) ev/5 0)))))))
    (fn convert (r/1) ev/2
      (with ev/3 (extend ev/2 test.Rates r/1) (dep-call ev/3 test.Rates.usd_to 1)))
    (fn main () ev/1 (call ev/1 convert (as test.Rates (call ev/1 both))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "an implementation used inside the `with` that installs it" =
  (* each place an implementation is used needs what it needs, and no
     more: used again under another `with`, what that one installs isn't
     needed outside it *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(c) =>
    calls += 1
    c * rate
  count() => calls

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn nested(r: Rates) -> Int =
  with r in
    with RateCalls { count: fn() => 0 } in
      run(r) + RateCalls.count()

fn main() uses Console =
  let p = Rates { usd_to: fn(c) => c }
  with p in
    with RateCalls { count: fn() => 0 } in
      print(run(p))
  let h = counting_rates(4)
  with h in
    print(run(h))
    let r: Rates = h
    print(run(r))
    print(RateCalls.count())
  let s = counting_rates(2)
  with s in
    with RateCalls { count: fn() => 7 } in
      with s in
        print(run(s))
  print(nested(Rates { usd_to: fn(c) => c + 10 }))
|}
  in
  types src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub dep RateCalls
      count: fn() -> Int
    handler counting_rates(rate: Int) for Rates, RateCalls
    fn run(r: Rates) -> Int
    fn nested(r: Rates) -> Int
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    1
    4
    4
    0
    2
    11
    ()
    |}];
  (* what it needs that's learned only once its group is done is still
     needed where it's installed *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn a(n: Int) -> Int =
  if n == 0 then 0
  else
    let h = Rates { usd_to: fn(c) => b(c) }
    with h in
      with Rates { usd_to: fn(c) => c } in
        run(h) + Rates.usd_to(n)

fn b(c: Int) -> Int = a(c - 1) + Random.int(1)

fn main() uses Console, Random = print(a(2))
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    fn run(r: Rates) -> Int
    fn a(n: Int) -> Int uses Random
    fn b(c: Int) -> Int uses Random
    fn main() uses Console, Random
    |}]

let%expect_test "taken as one, it installs only that one" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(c) =>
    calls += 1
    c * rate
  count() => calls

fn main() uses Console =
  let r: Rates = counting_rates(2)
  with r in
    print(RateCalls.count())
|};
  [%expect
    {|
    error: nothing installs `RateCalls` before `main`
       ┌─ test.ren:14:4
    14 │ fn main() uses Console =
       │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`
    17 │     print(RateCalls.count())
       │           ----------------- this call uses `RateCalls`
       help: install one inside `main`: `with counting_rates(...) in ...`
    |}];
  (* a field of a dependency's type says which too *)
  run
    {|
type Box = { c: Clock }

fn main() -> Bool =
  let b = Box { c: test_clock(Time.epoch) }
  with b.c in
    Clock.sleep(Duration.ms(3))
    Clock.now() == Time.epoch.plus(Duration.ms(3))
|};
  [%expect {| true |}]

let%expect_test "where nothing says which, a handler of several is its own" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn pick(b: Bool) =
  if b then counting_rates(1) else Rates { usd_to: fn(c) => c }

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn later() -> Int =
  let h = Some(counting_rates(1))
  match h
    Some(r) => run(r)
    None => 0

pub fn make() = counting_rates(1)

pub fn some() = Some(counting_rates(1))

fn main() = 1
|};
  [%expect
    {|
    error: this `else` branch is a `Rates`, but the `then` branch is a `counting_rates`
       ┌─ test.ren:12:36
    12 │   if b then counting_rates(1) else Rates { usd_to: fn(c) => c }
       │                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │             ----------------- the `then` branch is a `counting_rates`
       = both branches of an `if` have to produce the same type

    error: expected `Unit`, found `counting_rates`
       ┌─ test.ren:22:17
    22 │ pub fn make() = counting_rates(1)
       │                 ^^^^^^^^^^^^^^^^^
       = a public function without `->` returns `Unit`
       help: say which of its dependencies it gives an implementation of, `-> Rates`: the type of a handler of several can't be written

    error: expected `Unit`, found `Option<counting_rates>`
       ┌─ test.ren:24:17
    24 │ pub fn some() = Some(counting_rates(1))
       │                 ^^^^^^^^^^^^^^^^^^^^^^^
       = a public function without `->` returns `Unit`
       help: say which of its dependencies `counting_rates` gives an implementation of, `-> Option<Rates>`: the type of a handler of several can't be written
    |}]

let%expect_test "taken as one inside the type that's wanted" =
  (* `Option<Rates>` wants a `Rates` inside it, and so does an array
     whose other elements are `Rates`, in either order *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

pub type Box<T> = { v: T }

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

pub fn some() -> Option<Rates> = Some(counting_rates(6))

fn main() uses Console =
  let o: Option<Rates> = Some(counting_rates(2))
  match o
    Some(r) => print(run(r))
    None => ()
  let b: Box<Rates> = Box { v: counting_rates(3) }
  print(run(b.v))
  let xs = [counting_rates(4), Rates { usd_to: fn(c) => c }]
  let ys = [Rates { usd_to: fn(c) => c }, counting_rates(5)]
  print(run(xs[0]) + run(ys[1]))
  match some()
    Some(r) => print(run(r))
    None => ()
|}
  in
  types src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub dep RateCalls
      count: fn() -> Int
    handler counting_rates(rate: Int) for Rates, RateCalls
    fn run(r: Rates) -> Int
    pub fn some() -> Option<Rates>
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    2
    3
    9
    6
    ()
    |}]

let%expect_test "a handler of several where something else is wanted" =
  (* each says what the handler's call is, and what to write instead *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn f() = counting_rates(1)

fn main() =
  let r: Clock = counting_rates(1)
  let g: fn() -> Rates = f
  let o = Some(counting_rates(1))
  let p: Option<Rates> = o
  let zs = [counting_rates(1), Clock.frozen(Time.epoch)]
  ()
|};
  [%expect
    {|
    error: expected `Clock`, found `counting_rates`
       ┌─ test.ren:14:18
    14 │   let r: Clock = counting_rates(1)
       │                  ^^^^^^^^^^^^^^^^^
       = `counting_rates` is a handler for `Rates` and `RateCalls`, so what its call describes implements those, not `Clock`
       help: give an implementation of `Clock` here: a `Clock { ... }`, or a handler for `Clock`

    error: expected `fn() -> Rates`, found `fn() -> counting_rates`
       ┌─ test.ren:15:26
    15 │   let g: fn() -> Rates = f
       │                          ^
       = `counting_rates` implements `Rates` and `RateCalls`, so it's taken as just `Rates` only where `Rates` is wanted as it's made
       help: say so where it's made: `let x: Rates = counting_rates(...)`

    error: expected `Option<Rates>`, found `Option<counting_rates>`
       ┌─ test.ren:17:26
    17 │   let p: Option<Rates> = o
       │                          ^
       = `counting_rates` implements `Rates` and `RateCalls`, so it's taken as just `Rates` only where `Rates` is wanted as it's made
       help: say so where it's made: `let x: Rates = counting_rates(...)`

    error: this element is a `counting_rates`, but the others are a `Clock`
       ┌─ test.ren:18:13
    18 │   let zs = [counting_rates(1), Clock.frozen(Time.epoch)]
       │             ^^^^^^^^^^^^^^^^^
       = `counting_rates` is a handler for `Rates` and `RateCalls`, so what its call describes implements those, not `Clock`
       help: give an implementation of `Clock` here: a `Clock { ... }`, or a handler for `Clock`
    |}]

let%expect_test "a handler given too few arguments in a `with`" =
  (* what's missing is an argument, not the `with`'s body *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

handler one(k: Int) for Rates =
  usd_to(c) => c * k

fn make(k: Int) -> Rates = one(k)

fn main() -> Int =
  with one() in Rates.usd_to(1) + (with make() in Rates.usd_to(2))
|};
  [%expect
    {|
    error: `one` takes 1 argument but was given 0
       ┌─ test.ren:10:8
    10 │   with one() in Rates.usd_to(1) + (with make() in Rates.usd_to(2))
       │        ^^^^^
       = `one` makes an implementation, `Rates`, which `with` installs once it's called with all its arguments
       help: give `one` all its arguments

    error: `make` takes 1 argument but was given 0
       ┌─ test.ren:10:41
    10 │   with one() in Rates.usd_to(1) + (with make() in Rates.usd_to(2))
       │                                         ^^^^^^
       = `make` makes an implementation, `Rates`, which `with` installs once it's called with all its arguments
       help: give `make` all its arguments
    |}]

let%expect_test "a conformance function runs against a record and a handler" =
  (* stage 7.5's groups are functions over implementations like this one:
     the library's fake, a handler of two dependencies, is passed as a
     `Clock` *)
  let files =
    [
      ( "main.ren",
        {|
import fakes

fn clock_conforms(c: Clock) -> Bool =
  with c in
    let a = Clock.instant()
    Clock.sleep(Duration.ms(5))
    Clock.instant().not_before(a)

fn main() uses Console =
  print(clock_conforms(Clock.frozen(Time.epoch)))
  print(clock_conforms(fakes.manual_clock(Time.epoch)))
  print(clock_conforms(fakes.stopped()))
  with fakes.manual_clock(Time.epoch) in
    fakes.ManualClock.advance(Duration.minutes(1))
    print(Clock.now() == Time.epoch.plus(Duration.minutes(1)))
|}
      );
      ( "fakes.ren",
        {|
pub dep ManualClock =
  advance: fn(d: Duration)

pub handler manual_clock(start: Time) for Clock, ManualClock =
  var now = start
  var at = Instant.zero
  now() => now
  instant() => at
  sleep(d) =>
    now = now.plus(d)
    at = at.plus(d)
  advance(d) =>
    now = now.plus(d)
    at = at.plus(d)

pub fn stopped() -> Clock = manual_clock(Time.epoch)
|}
      );
    ]
  in
  types_files files;
  [%expect
    {|
    -- fakes
    pub dep ManualClock
      advance: fn(Duration)
    pub handler manual_clock(start: Time) for Clock, ManualClock
    pub fn stopped() -> Clock

    -- main
    fn clock_conforms(c: Clock) -> Bool
    fn main() uses Console
    |}];
  run_files files;
  [%expect {|
    true
    true
    true
    true
    ()
    |}]

let%expect_test "what a handler's call can't be" =
  types
    {|
dep N =
  next: fn() -> Int

handler counter() for N =
  var n = 0
  next() =>
    n += 1
    n

pub fn make() = counter()

fn main() uses Console =
  counter()
  with counter in print(N.next())
|};
  [%expect
    {|
    error: expected `Unit`, found `N`
       ┌─ test.ren:10:17
    10 │ pub fn make() = counter()
       │                 ^^^^^^^^^
       = a public function without `->` returns `Unit`
       help: add `-> N` to the signature

    error: `counter` makes `N`, and this throws it away
       ┌─ test.ren:13:3
    13 │   counter()
       │   ^^^^^^^^^
       help: install it with `with`, or write `let _ = ...` if you mean to drop it

    error: `with` installs an implementation, but this is a `fn() -> N`
       ┌─ test.ren:14:8
    14 │   with counter in print(N.next())
       │        ^^^^^^^
       = `with` installs an implementation, and `counter` makes one when it's called
       help: call it: `with counter() in ...`
    |}]

let%expect_test "a handler's name starts with a lowercase letter" =
  types
    {|
dep N =
  next: fn() -> Int

handler Counter() for N =
  next() => 1
|};
  [%expect
    {|
    error: a handler's name must start with a lowercase letter
      ┌─ test.ren:4:9
    4 │ handler Counter() for N =
      │         ^^^^^^^
      = a capitalized name is a type's, a dependency's or a constructor's
      help: write `counter`
    |}];
  types {|
fn Double(n: Int) -> Int = n * 2
|};
  [%expect
    {|
    error: a function's name must start with a lowercase letter
      ┌─ test.ren:1:4
    1 │ fn Double(n: Int) -> Int = n * 2
      │    ^^^^^^
      = a capitalized name is a type's, a dependency's or a constructor's
      help: write `double`
    |}];
  (* a handler's own type, which a handler of several dependencies has,
     is in no scope, so it hides no type, even one spelled like it *)
  run
    {|
dep N =
  next: fn() -> Int

dep M =
  m: fn() -> Int

type T = { n: Int }

handler t() for N, M =
  next() => 1
  m() => 2

fn main() -> T =
  with t() in T { n: N.next() + M.m() }
|};
  [%expect {| { n: 3 } |}]

let%expect_test "a handler's mistakes are said as a handler's" =
  types
    {|
pub dep N =
  next: fn() -> Int

type Secret = { a: Int }

pub handler keeps(k: Secret) for N =
  next() => k.a

dep Hidden =
  n: fn() -> Int

pub handler needs() for N uses Hidden =
  next() => Hidden.n()
|};
  [%expect
    {|
    error: `pub handler keeps` takes `Secret`, which is private to this module
      ┌─ test.ren:6:22
    4 │ type Secret = { a: Int }
      │      ------ `Secret` is declared here, without `pub`
    6 │ pub handler keeps(k: Secret) for N =
      │                      ^^^^^^
      help: mark `Secret` `pub`

    error: `pub handler needs` needs `Hidden`, which is private to this module
       ┌─ test.ren:12:32
     9 │ dep Hidden =
       │     ------ `Hidden` is declared here, without `pub`
    12 │ pub handler needs() for N uses Hidden =
       │                                ^^^^^^
       help: mark `Hidden` `pub`
    |}];
  (* an arm's result reads as a record implementation's lambda's does; a
     `with` that can't tell what it installs doesn't pass on what its body
     uses, which would be reported again at the call *)
  types
    {|
dep N =
  next: fn() -> Int

handler wrong() for N =
  next() => true

fn r() -> N = N { next: fn() => true }

fn run(r) -> Int = with r in N.next()

fn main() uses Console = print(run(wrong()))
|};
  [%expect
    {|
    error: this arm produces a `Bool`, but it has to produce an `Int`
      ┌─ test.ren:5:13
    5 │   next() => true
      │             ^^^^
      = `N`'s operation `next`

    error: this lambda produces a `Bool`, but it has to produce an `Int`
      ┌─ test.ren:7:33
    7 │ fn r() -> N = N { next: fn() => true }
      │                                 ^^^^
      = `N`'s operation `next`

    error: `with` can't tell what this installs: its type isn't known here
      ┌─ test.ren:9:25
    9 │ fn run(r) -> Int = with r in N.next()
      │                         ^
      = `with` installs an implementation of a dependency around its body, or passes its body to a wrapper, a function whose last parameter is the body
      help: say what it is where it's declared, like `r: Clock`
    |}]

let%expect_test "a handler can be installed by its own group" =
  (* its type is known before its body is checked, so a function it calls,
     or one of its own arms, can install it *)
  let src =
    {|
dep N =
  get: fn(d: Int) -> Int

fn use_it(k: Int) -> Int = if k > 3 then k else with h(k) in N.get(0)

handler h(k: Int) for N =
  get(d) => use_it(k + 1)

fn via(d: Int) uses N = N.get(d)

handler deeper(k: Int) for N =
  get(d) => if k > 6 then k else with deeper(k + 1) in via(d)

fn main() uses Console =
  print(use_it(0))
  print(with deeper(0) in N.get(0))
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn(Int) -> Int
    fn use_it(k: Int) -> Int
    handler h(k: Int) for N
    fn via(d: Int) -> Int uses N
    handler deeper(k: Int) for N
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    4
    7
    ()
    |}]

let%expect_test "what a handler can't do, said as a handler's" =
  types
    {|
dep N =
  get: fn() -> Int

dep M =
  m: fn() -> Int

handler bump(k: Int) for N =
  get() =>
    k += 1
    k

fn main() = 1
|};
  [%expect
    {|
    error: `k` is a handler's parameter, so it can't be changed
      ┌─ test.ren:9:5
    9 │     k += 1
      │     ^
      = each `with` that installs a handler keeps its parameters, as they were when it was called
      help: keep a copy in its state, `var k = k`, which its arms can change
    |}];
  run
    {|
dep N =
  get: fn() -> Int

handler bump(k: Int) for N =
  var k = k
  get() =>
    k += 1
    k

fn main() uses Console =
  with bump(1) in
    print(N.get())
    print(N.get())
|};
  [%expect {|
    2
    3
    ()
    |}];
  types
    {|
dep N =
  get: fn() -> Int

dep M =
  m: fn() -> Int

handler keeps(n: N) for M =
  m() => with n in N.get()

fn main() = 1
|};
  [%expect
    {|
    error: `n` is kept by the handler, whose operations run where a `with` installs it, so it isn't transparent
      ┌─ test.ren:8:15
    8 │   m() => with n in N.get()
      │               ^
      = a parameter whose type is a dependency's, `N`, can only be installed, with `with`, or passed straight to another function, so what it needs is what its function uses
      help: to keep it, name what it needs, `n: N uses ..d`, and say the handler needs that: `for M uses ..d`
    |}];
  types
    {|
dep N =
  get: fn() -> Int

handler dup() for N =
  get() => 1

fn dup() = 2

fn main() = 1
|};
  [%expect
    {|
    error: a handler and a function are both named `dup`
      ┌─ test.ren:7:4
    4 │ handler dup() for N =
      │         --- the handler `dup` is here
    7 │ fn dup() = 2
      │    ^^^
      help: rename one of them
    |}];
  types
    {|
dep N =
  get: fn() -> Int

handler poly<T>(x: T) for N =
  get() => 1
|};
  [%expect
    {|
    error: a handler can't take type parameters
      ┌─ test.ren:4:13
    4 │ handler poly<T>(x: T) for N =
      │             ^
      = a handler's operations have the types its dependencies declare, which can't take type parameters either
      help: remove them
    |}]

let%expect_test "the prelude's test implementations, installed by hand" =
  run
    {|
fn main() uses Console =
  with test_clock(Time.epoch) in
    TestClock.advance(Duration.minutes(5))
    Clock.sleep(Duration.seconds(1))
    print(Clock.now() == Time.epoch.plus(Duration.ms(301000)))
    print(Clock.instant().since(Instant.zero) == Duration.ms(301000))
  // the same seed gives the same numbers
  let a = with test_random(42) in [Random.int(100), Random.int(100), TestRandom.seed()]
  let b = with test_random(42) in [Random.int(100), Random.int(100), TestRandom.seed()]
  print(a == b)
  print(a[2])
  let lines = with test_console() in
    print("kept")
    Console.error("apart")
    Console.write("too")
    [TestConsole.output(), TestConsole.errors()]
  print(lines)
|};
  [%expect
    {|
    true
    true
    true
    42
    [["kept", "too"], ["apart"]]
    ()
    |}]

let%expect_test "mem_fs, installed by hand" =
  run
    {|
fn main() ! FsError | InvalidUtf8 uses Console =
  let notes = Path.of("notes.txt")
  let files = [File { path: notes, data: "hi".bytes() }]
  with mem_fs(files) in
    print(try Fs.read_str(notes))
    print(Fs.exists(Path.of("other.txt")))
    try Fs.write(notes, "bye".bytes())
    try Fs.write(Path.of("other.txt"), "new".bytes())
    print(try Fs.read_str(notes))
    print(try Fs.read_str(Path.of("other.txt")))
  // each instance starts from `files` again
  with mem_fs(files) in
    print(try Fs.read_str(notes))
    print(Fs.exists(Path.of("other.txt")))
  with mem_fs([File { path: notes, data: "é".bytes() }]) in
    print((try Fs.read(notes)).len())
  with mem_fs([]) in
    try Fs.read(notes)
|};
  [%expect
    {|
    hi
    false
    bye
    new
    hi
    false
    2
    error: NoSuchFile(notes.txt)
    |}]

let%expect_test "a test gets no args, and programs that exit with 0" =
  test
    {|
fn build() -> Int ! ProcError uses Proc =
  try Proc.run("make", ["all"])

test "nothing runs" =
  assert Os.args() == []
  assert TestProc.ran() == []

test "what ran, in order" =
  assert (try build()) == 0
  assert (try Proc.run("no-such-program", [])) == 0
  assert TestProc.ran() == [
    Command { cmd: "make", args: ["all"] },
    Command { cmd: "no-such-program", args: [] },
  ]
|};
  [%expect {|
    test.ren
      ✓ nothing runs
      ✓ what ran, in order

    2 passed
    [exit 0]
    |}]

let%expect_test "test_os and test_proc, installed by hand" =
  run
    {|
fn build() -> Int ! ProcError uses Os, Proc =
  var last = 0
  for a in Os.args()
    last = try Proc.run("make", [a])
  last

fn main() ! ProcError uses Console =
  let fails = Command { cmd: "make", args: ["test"] }
  with test_os(["all", "test"]), test_proc([Exit { command: fails, code: 2 }]) in
    print(try build())
    print(TestProc.ran())
  // each instance starts with nothing run
  with test_os(["all"]), test_proc([Exit { command: fails, code: 2 }]) in
    print(try build())
    print(TestProc.ran())
|};
  [%expect {|
    2
    [Command { cmd: "make", args: ["all"] }, Command { cmd: "make", args: ["test"] }]
    0
    [Command { cmd: "make", args: ["all"] }]
    ()
    |}]

let%expect_test "a test, a group and a group's run are items of their own" =
  ast
    {|
test "two is two" uses Clock =
  assert 1 + 1 == 2

pub group conforms(c: Clock, n: Int) with c, Clock.frozen(Time.epoch) =
  test "it runs" =
    assert n > 0
  test "and again" =
    assert true

group "frozen" = conforms(Clock.frozen(Time.epoch), 1)
|};
  [%expect
    {|
    (test "two is two" (uses Clock) (assert (== (+ 1 1) 2)))
    (pub group conforms (c:Clock n:Int) (with c (call (. (con Clock) frozen) (. (con Time) epoch))) (test "it runs" (assert (> n 0))) (test "and again" (assert true)))
    (group "frozen" (call conforms (call (. (con Clock) frozen) (. (con Time) epoch)) 1))
    |}]

let%expect_test "what a test or a group can't be" =
  ast {|
test two =
  assert true
|};
  [%expect
    {|
    error: expected the test's name, a string, found `two`
      ┌─ test.ren:1:6
    1 │ test two =
      │      ^^^
      help: name it with a string, saying what it checks: `test "..." =`
    |}];
  ast {|
pub test "shared" =
  assert true
|};
  [%expect
    {|
    error: a test can't be `pub`
      ┌─ test.ren:1:5
    1 │ pub test "shared" =
      │     ^^^^
      help: remove the `pub`: to share tests, put them in a `pub group`, which other modules can run
    |}];
  ast
    {|
group conforms with Clock.frozen(Time.epoch) =
  test "x" =
    assert true
|};
  [%expect
    {|
    error: expected `(` after the group's name, found `with`
      ┌─ test.ren:1:16
    1 │ group conforms with Clock.frozen(Time.epoch) =
      │                ^^^^
      help: write its parameters, `group conforms() =`, even if it has none
    |}];
  ast {|
group conforms() =
  fn helper() = 1
|};
  [%expect
    {|
    error: expected a test, `test "..." =`, found `fn`
      ┌─ test.ren:2:3
    2 │   fn helper() = 1
      │   ^^
      help: move it out of the group: a group holds only tests
    |}];
  ast {|
group "frozen" = conforms
|};
  [%expect
    {|
    error: a group's run calls a group, with the arguments for its tests
      ┌─ test.ren:1:18
    1 │ group "frozen" = conforms
      │                  ^^^^^^^^
      help: call the group with its arguments: `g(...)`
    |}];
  ast {|
pub group "frozen" = conforms()
|};
  [%expect
    {|
    error: a group's run can't be `pub`
      ┌─ test.ren:1:11
    1 │ pub group "frozen" = conforms()
      │           ^^^^^^^^
      help: remove the `pub`: a `pub group` is one other modules can run
    |}]

let%expect_test "a test gets the test dependencies, and shows how it failed" =
  test
    {|
type Money = opaque Int
  pub fn dollars(n: Int) -> Money = n * 100
  pub fn minus(self, m: Money) -> Money = self - m

type Account = { id: Int, balance: Money, at: Time }

// private, and a test can call it
fn pay(a: Account, m: Money) -> Account uses Clock =
  Account { id: a.id, balance: a.balance.minus(m), at: Clock.now() }

fn main() uses Clock, Console =
  print("paying")
  let a = pay(Account { id: 1, balance: Money.dollars(1), at: Time.epoch }, Money.dollars(1))
  print(a.balance == Money.dollars(0))

test "paying takes the money" =
  let a = Account { id: 1, balance: Money.dollars(1), at: Time.epoch }
  TestClock.advance(Duration.minutes(5))
  let paid = pay(a, Money.dollars(1))
  assert paid == Account { id: 1, balance: Money.dollars(0), at: Time.epoch.plus(Duration.minutes(5)) }

test "paying too much is caught" =
  let a = Account { id: 1, balance: Money.dollars(1), at: Time.epoch }
  print("before")
  assert pay(a, Money.dollars(2)) == a

test "main prints" =
  main()
  assert TestConsole.output() == ["paying", "true"]
|};
  [%expect
    {|
    test.ren
      ✓ paying takes the money
      ✗ paying too much is caught
      ✓ main prints

    ──── paying too much is caught ── test.ren:25
       │
    25 │   assert pay(a, Money.dollars(2)) == a
       │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  Account { ..., balance: Money(-100), ... }
       right: Account { ..., balance: Money(100), ... }
                                            ^ differs here

       seed 6438 · rerun: ren test test.ren --only "paying too" --seed 6438

       printed:
         before

    2 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "a test without a real dependency prints the same every time" =
  let src =
    {|
fn roll() -> Int uses Random = Random.int(6) + 1

test "a roll is a die's" =
  let r = roll()
  print(r)
  assert r > 6

test "the seed is the test's" =
  print(TestRandom.seed())
  assert false
|}
  in
  test src;
  [%expect
    {|
    test.ren
      ✗ a roll is a die's
      ✗ the seed is the test's

    ──── a roll is a die's ── test.ren:6
      │
    6 │   assert r > 6
      │          ^^^^^
      │
      this is false

      seed 8482 · rerun: ren test test.ren --only "a roll" --seed 8482

      printed:
        5

    ──── the seed is the test's ── test.ren:10
       │
    10 │   assert false
       │          ^^^^^
       │
       this is false

       seed 2770 · rerun: ren test test.ren --only "the seed" --seed 2770

       printed:
         2770

    0 passed, 2 failed
    [exit 1]
    |}];
  test src;
  [%expect
    {|
    test.ren
      ✗ a roll is a die's
      ✗ the seed is the test's

    ──── a roll is a die's ── test.ren:6
      │
    6 │   assert r > 6
      │          ^^^^^
      │
      this is false

      seed 8482 · rerun: ren test test.ren --only "a roll" --seed 8482

      printed:
        5

    ──── the seed is the test's ── test.ren:10
       │
    10 │   assert false
       │          ^^^^^
       │
       this is false

       seed 2770 · rerun: ren test test.ren --only "the seed" --seed 2770

       printed:
         2770

    0 passed, 2 failed
    [exit 1]
    |}];
  (* `--seed` sets every test's *)
  test ~seed:7 src;
  [%expect
    {|
    test.ren
      ✗ a roll is a die's
      ✗ the seed is the test's

    ──── a roll is a die's ── test.ren:6
      │
    6 │   assert r > 6
      │          ^^^^^
      │
      this is false

      seed 7 · rerun: ren test test.ren --only "a roll" --seed 7

      printed:
        5

    ──── the seed is the test's ── test.ren:10
       │
    10 │   assert false
       │          ^^^^^
       │
       this is false

       seed 7 · rerun: ren test test.ren --only "the seed" --seed 7

       printed:
         7

    0 passed, 2 failed
    [exit 1]
    |}]

let%expect_test "a test's `uses` asks for the real implementation" =
  test
    {|
test "the system clock is past the epoch" uses Clock =
  assert Clock.now().after(Time.epoch)

test "the test clock isn't" =
  assert Clock.now() == Time.epoch
|};
  [%expect
    {|
    test.ren
      ✓ the system clock is past the epoch
      ✓ the test clock isn't

    2 passed
    [exit 0]
    |}];
  test ~list:true
    {|
test "the system clock is past the epoch" uses Clock, Random =
  assert Clock.now().after(Time.epoch)

test "the test clock isn't" =
  assert Clock.now() == Time.epoch
|};
  [%expect
    {|
    test.ren
      the system clock is past the epoch · uses the real `Clock` and `Random`
      the test clock isn't
    [exit 0]
    |}]

let%expect_test "a test gets an empty mem_fs, or the files its with gives" =
  test
    {|
fn save(name: Str, text: Str) ! FsError uses Fs =
  try Fs.write(Path.of(name), text.bytes())

test "there are no files" =
  assert not Fs.exists(Path.of("notes.txt"))
  match attempt Fs.read(Path.of("notes.txt"))
    Err(NoSuchFile(p)) => assert p == Path.of("notes.txt")
    _ => assert false

test "what it writes, it reads back" =
  try save("notes.txt", "hi")
  assert try Fs.read_str(Path.of("notes.txt")) == "hi"

test "nothing's left from the test before" =
  assert not Fs.exists(Path.of("notes.txt"))

test "a with gives it files" =
  let files = [File { path: Path.of("notes.txt"), data: "seeded".bytes() }]
  with mem_fs(files) in
    assert try Fs.read_str(Path.of("notes.txt")) == "seeded"

test "a missing file fails the test" =
  let s = try Fs.read_str(Path.of("gone.txt"))
  assert s == ""
|};
  [%expect
    {|
    test.ren
      ✓ there are no files
      ✓ what it writes, it reads back
      ✓ nothing's left from the test before
      ✓ a with gives it files
      ✗ a missing file fails the test

    ──── a missing file fails the test ── test.ren:22
       │
    22 │ test "a missing file fails the test" =
       │      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       error: NoSuchFile(gone.txt)

       seed 9888 · rerun: ren test test.ren --only "a missing" --seed 9888

    4 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "a test whose uses asks for the real Fs" =
  let file = temp_file () in
  test
    (Printf.sprintf
       {|
test "the real file system" uses Fs =
  let p = Path.of("%s")
  try Fs.write(p, "real".bytes())
  assert try Fs.read_str(p) == "real"
|}
       file);
  Sys.remove file;
  [%expect {|
    test.ren
      ✓ the real file system

    1 passed
    [exit 0]
    |}]

let%expect_test "a test that fails with an error, or panics" =
  test
    {|
fn half(n: Int) -> Int ! Odd(Int) =
  if n % 2 == 1 then fail Odd(n)
  n / 2

test "three halves" =
  assert try half(3) == 1

test "dividing by zero" =
  let zero = 0
  assert 1 / zero == 1
|};
  [%expect
    {|
    test.ren
      ✗ three halves
      ✗ dividing by zero

    ──── three halves ── test.ren:5
      │
    5 │ test "three halves" =
      │      ^^^^^^^^^^^^^^
      │
      error: Odd(3)

      seed 7036 · rerun: ren test test.ren --only "three halves" --seed 7036

    ──── dividing by zero ── test.ren:10
       │
    10 │   assert 1 / zero == 1
       │          ^^^^^^^^
       │
       panic: division by zero

       seed 6354 · rerun: ren test test.ren --only "dividing by" --seed 6354

    0 passed, 2 failed
    [exit 1]
    |}]

let%expect_test "a group's test that fails with an error, or passes" =
  (* a run calls each of the group's tests with `try`, so what it fails
     with reaches the runner, and a test that can't fail runs as well *)
  test
    {|
fn may(n: Int) -> Int ! Boom = if n > 0 then fail Boom else n

group g() =
  test "fails" =
    assert try may(1) == 0
  test "passes" =
    assert try may(0) == 0
  test "can't fail" =
    assert 1 == 1

group "run" = g()
|};
  [%expect
    {|
    test.ren
      run
        ✗ fails
        ✓ passes
        ✓ can't fail

    ──── run / fails ── test.ren:11
       │
    11 │ group "run" = g()
       │       ^^^^^
       │
       error: Boom

       seed 6182 · rerun: ren test test.ren --only "run / fails" --seed 6182

    2 passed, 1 failed
    [exit 1]
    |}];
  test_files
    [
      ("main.ren", {|
import lib

group "wrapped" = lib.wrapped()
|});
      ( "lib.ren",
        {|
pub fn retry(n: Int, body: fn() ! ..e uses ..d) ! ..e uses ..d =
  match attempt body()
    Ok(_) => ()
    Err(_) =>
      if n <= 1 then try body() else try retry(n - 1, body)

pub group wrapped() with retry(5) =
  test "always fails" =
    fail Boom
|}
      );
    ];
  [%expect
    {|
    main.ren
      wrapped
        ✗ always fails

    ──── wrapped / always fails ── main.ren:3
      │
    3 │ group "wrapped" = lib.wrapped()
      │       ^^^^^^^^^
      │
      error: Boom

      seed 6897 · rerun: ren test . --only "wrapped /" --seed 6897

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "`--only` runs the tests whose name has it" =
  let src =
    {|
test "one adds" =
  assert 1 + 1 == 2

test "two adds" =
  assert 2 + 2 == 5

test "one subtracts" =
  assert 1 - 1 == 0
|}
  in
  test ~only:"adds" src;
  [%expect
    {|
    test.ren
      ✓ one adds
      ✗ two adds

    ──── two adds ── test.ren:5
      │
    5 │   assert 2 + 2 == 5
      │          ^^^^^^^^^^
      │
      left:  4
      right: 5
             ^ differs here

      seed 2999 · rerun: ren test test.ren --only "two adds" --seed 2999

    1 passed, 1 failed
    [exit 1]
    |}];
  test ~only:"multiplies" src;
  [%expect {|
    no test's name has "multiplies" in it
    [exit 1]
    |}];
  (* listing them is the same mistake *)
  test ~only:"multiplies" ~list:true src;
  [%expect {|
    no test's name has "multiplies" in it
    [exit 1]
    |}]

let%expect_test "a rerun runs just the test that failed" =
  (* "panics" is inside "it panics", so its rerun needs `--exact` *)
  test {|
test "panics" =
  assert false

test "it panics" =
  assert true
|};
  [%expect
    {|
    test.ren
      ✗ panics
      ✓ it panics

    ──── panics ── test.ren:2
      │
    2 │   assert false
      │          ^^^^^
      │
      this is false

      seed 4325 · rerun: ren test test.ren --only "panics" --exact --seed 4325

    1 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "a test's name with a line break, and a difference after an é" =
  (* the name is shown as it's written, so it stays on one line; a rerun
     looks for what comes before the break *)
  test
    {|
type P = {name: Str, n: Int}

test "café\nprices" =
  assert P { name: "café", n: 1 } == P { name: "café", n: 2 }
|};
  [%expect
    {|
    test.ren
      ✗ café\nprices

    ──── café\nprices ── test.ren:4
      │
    4 │   assert P { name: "café", n: 1 } == P { name: "café", n: 2 }
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  P { ..., n: 1 }
      right: P { ..., n: 2 }
                         ^ differs here

      seed 6167 · rerun: ren test test.ren --only "café" --seed 6167

    0 passed, 1 failed
    [exit 1]
    |}]

let%expect_test
    "`--exact` runs the test of that whole name, or that group run's tests" =
  (* what an editor's ▶ beside a test runs: "a cup" isn't also "a cup
     holds two" *)
  let src =
    {|
test "a cup" =
  assert true

test "a cup holds two" =
  assert true

group g() =
  test "a cup" =
    assert true

group "a cup holds" = g()
|}
  in
  test ~only:"a cup" ~exact:true src;
  [%expect {|
    test.ren
      ✓ a cup

    1 passed
    [exit 0]
    |}];
  test ~only:"a cup holds" ~exact:true src;
  [%expect
    {|
    test.ren
      a cup holds
        ✓ a cup

    1 passed
    [exit 0]
    |}]

let%expect_test "a group runs its tests against each implementation" =
  test_files
    [
      ( "conform.ren",
        {|
pub group clock_conforms(c: Clock) with c =
  test "instant never goes backwards" =
    let a = Clock.instant()
    assert Clock.instant().not_before(a)
  test "sleeping moves it on" =
    let t = Clock.now()
    Clock.sleep(Duration.ms(5))
    assert Clock.now().after(t)
|}
      );
      ( "main.ren",
        {|
import conform

group "frozen" = conform.clock_conforms(Clock.frozen(Time.epoch))
group "test clock" = conform.clock_conforms(test_clock(Time.epoch))
|}
      );
    ];
  [%expect
    {|
    main.ren
      frozen
        ✓ instant never goes backwards
        ✗ sleeping moves it on
      test clock
        ✓ instant never goes backwards
        ✓ sleeping moves it on

    ──── frozen / sleeping moves it on ── conform.ren:8
      │
    8 │     assert Clock.now().after(t)
      │            ^^^^^^^^^^^^^^^^^^^^
      │
      this is false

      seed 8783 · rerun: ren test . --only "frozen / sleeping" --seed 8783

    3 passed, 1 failed
    [exit 1]
    |}]

let%expect_test "each test of a group gets a fresh instance" =
  test
    {|
group stopped(c: Clock) with c =
  test "moving it on" =
    Clock.sleep(Duration.minutes(1))
    assert Clock.now() == Time.epoch.plus(Duration.minutes(1))
  test "it starts where it was made" =
    assert Clock.now() == Time.epoch

group "test clock" = stopped(test_clock(Time.epoch))
|};
  [%expect
    {|
    test.ren
      test clock
        ✓ moving it on
        ✓ it starts where it was made

    2 passed
    [exit 0]
    |}]

let%expect_test "what a group's run can't be" =
  test_files
    [
      ( "main.ren",
        {|
import conform

group conforms(c: Clock) with c =
  test "x" =
    assert true

group "none" = nothing(1)
group "wrong" = conforms()
group "private" = conform.hidden()
group "alias" = nowhere.g()
|}
      );
      ("conform.ren", {|
group hidden() =
  test "x" =
    assert true
|});
    ];
  [%expect
    {|
    error: there's no group named `nothing`
      ┌─ main.ren:7:16
    7 │ group "none" = nothing(1)
      │                ^^^^^^^
      help: declare it with `group name(...) =`, or run one another module declares, after its alias: `m.name(...)`

    error: the group `conforms` takes 1 argument, but this gives it 0
      ┌─ main.ren:8:17
    8 │ group "wrong" = conforms()
      │                 ^^^^^^^^^^
      help: give it 1 argument

    error: `conform` has no public group `hidden`
      ┌─ main.ren:9:27
    9 │ group "private" = conform.hidden()
      │                           ^^^^^^
      help: if it's declared there, mark it `pub`

    error: there's no module imported as `nowhere`
       ┌─ main.ren:10:17
    10 │ group "alias" = nowhere.g()
       │                 ^^^^^^^
       help: import it at the top of the file, like `import nowhere`
    |}];
  test
    {|
group counts(c: Clock) with c =
  test "two" =
    assert true
  test "two" =
    assert true

fn counts() = 1

group "frozen" = counts(Clock.frozen(Time.epoch))
group "frozen" = counts(Clock.frozen(Time.epoch))
|};
  [%expect
    {|
    error: there's a function named `counts` already
      ┌─ test.ren:1:7
    1 │ group counts(c: Clock) with c =
      │       ^^^^^^
    7 │ fn counts() = 1
      │    ------ the function is here
      help: rename one of them

    error: there are two tests in this group named "two"
      ┌─ test.ren:4:8
    2 │   test "two" =
      │        ----- the first is here
    4 │   test "two" =
      │        ^^^^^
      help: rename one of them

    error: there are two tests named "frozen"
       ┌─ test.ren:10:7
     9 │ group "frozen" = counts(Clock.frozen(Time.epoch))
       │       -------- the first is here
    10 │ group "frozen" = counts(Clock.frozen(Time.epoch))
       │       ^^^^^^^^
       help: rename one of them
    |}]

let%expect_test "a public group can't take a private type" =
  (* another module runs it, so it has to be able to name what it gives *)
  test
    {|
type Priv = {n: Int}

pub group leaky(p: Priv, ps: Array<Priv>) =
  test "a" =
    assert p.n == 1
  test "b" =
    assert ps == []
|};
  [%expect
    {|
    error: `pub group leaky` takes `Priv`, which is private to this module
      ┌─ test.ren:3:20
    1 │ type Priv = {n: Int}
      │      ---- `Priv` is declared here, without `pub`
    3 │ pub group leaky(p: Priv, ps: Array<Priv>) =
      │                    ^^^^
      help: mark `Priv` `pub`

    error: `pub group leaky`'s parameters mention `Priv`, which is private to this module
      ┌─ test.ren:3:36
    1 │ type Priv = {n: Int}
      │      ---- `Priv` is declared here, without `pub`
    3 │ pub group leaky(p: Priv, ps: Array<Priv>) =
      │                                    ^^^^
      help: mark `Priv` `pub`
    |}]

let%expect_test
    "an error in a group's header or its run's arguments is shown once" =
  (* each of the group's tests is a function with the group's parameters
     and `with`, and each of a run's calls it with the run's arguments *)
  test
    {|
group g(x: Nope) with nothere =
  test "a" =
    assert true
  test "b" =
    assert true
|};
  [%expect
    {|
    error: there's no type named `Nope`
      ┌─ test.ren:1:12
    1 │ group g(x: Nope) with nothere =
      │            ^^^^

    error: there's no variable named `nothere`
      ┌─ test.ren:1:23
    1 │ group g(x: Nope) with nothere =
      │                       ^^^^^^^
    |}];
  test
    {|
group g(x: Bool) =
  test "a" =
    assert x
  test "b" =
    assert x
  test "c" =
    assert x

group "r" = g(1)
|};
  [%expect
    {|
    error: expected `Bool`, found `Int`
      ┌─ test.ren:9:15
    9 │ group "r" = g(1)
      │               ^
    |}]

let%expect_test "a test's body is `Unit`" =
  test
    {|
fn compute() = 3

test "a forgotten assert" =
  compute() == 3

test "a number" = 1

group g() =
  test "in a group" =
    let n = compute()
    n
|};
  [%expect
    {|
    error: a test's body is `Unit`, but this is a `Bool`
      ┌─ test.ren:4:3
    4 │   compute() == 3
      │   ^^^^^^^^^^^^^^
      = a test passes unless it panics or fails
      help: to check it, write `assert` before it

    error: a test's body is `Unit`, but this is an `Int`
      ┌─ test.ren:6:19
    6 │ test "a number" = 1
      │                   ^
      = a test passes unless it panics or fails
      help: check it with `assert`, or write `let _ = ...` if you mean to drop it

    error: a test's body is `Unit`, but this is an `Int`
       ┌─ test.ren:11:5
    11 │     n
       │     ^
       = a test passes unless it panics or fails
       help: check it with `assert`, or write `let _ = ...` if you mean to drop it
    |}]

let%expect_test "a group's wrapper that gives a value is reported once" =
  (* the test's body is the wrapper's, which is wrong; its last line is
     `Unit`, as a test's is *)
  test
    {|
fn retry(n: Int, body: fn() -> Int) -> Int = try body()

group g() with retry(3) =
  test "a" =
    assert 1 == 1
|};
  [%expect
    {|
    error: expected `Int`, found `Unit`
      ┌─ test.ren:5:5
    5 │     assert 1 == 1
      │     ^^^^^^^^^^^^^
    |}]

let%expect_test
    "`ren run` doesn't run the tests, and `ren types` leaves them out" =
  let src = {|
fn main() -> Int = 1

test "broken" =
  assert false
|} in
  run src;
  [%expect {| 1 |}];
  types src;
  [%expect {| fn main() -> Int |}];
  core src;
  [%expect
    {|
    (fn main () ev/1 1)
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "a failed `assert` outside a test is a panic" =
  run {|
fn main() =
  let xs = [1, 2]
  assert xs == [1, 3]
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:3:10
    3 │   assert xs == [1, 3]
      │          ^^^^^^^^^^^^
      = left:  [..., 2]
      = right: [..., 3]
    |}];
  (* its sides read as `ren test` shows them, through their type *)
  run
    {|
type M = opaque Int
type P = {m: M, n: Int}

fn main() =
  assert P { m: 1, n: 2 } == P { m: 2, n: 2 }
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:5:10
    5 │   assert P { m: 1, n: 2 } == P { m: 2, n: 2 }
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = left:  P { m: M(1), ... }
      = right: P { m: M(2), ... }
    |}]

let%expect_test "a failed assert leaves out what its two sides share" =
  (* the way to the first difference and what's there; a record's other
     fields, the other elements and an element only one side has *)
  test
    {|
type Shape = Dot | Box(w: Int, h: Int)
type P = { name: Str, at: Int, shapes: Array<Shape> }

test "a payload" =
  assert P { name: "a", at: 1, shapes: [Dot, Box(1, 2)] } == P { name: "a", at: 1, shapes: [Dot, Box(1, 3)] }

test "two constructors" =
  assert [Dot, Dot, Dot] == [Dot, Box(1, 1), Dot]

test "one side is longer" =
  assert [1, 2, 3, 4] == [1, 2]

test "the left side is shorter" =
  assert [1, 2, 3] == [1, 2, 3, 4, 5]

test "only the first difference" =
  assert P { name: "a", at: 1, shapes: [] } == P { name: "b", at: 2, shapes: [Dot] }

test "nothing in common" =
  assert 1 == 2

test "apart first, right longer" =
  assert [1, 2] == [9, 2, 3]

test "apart first, left longer" =
  assert [1, 2, 7, 8] == [9, 2, 3]
|};
  [%expect {|
    test.ren
      ✗ a payload
      ✗ two constructors
      ✗ one side is longer
      ✗ the left side is shorter
      ✗ only the first difference
      ✗ nothing in common
      ✗ apart first, right longer
      ✗ apart first, left longer

    ──── a payload ── test.ren:5
      │
    5 │   assert P { name: "a", at: 1, shapes: [Dot, Box(1, 2)] } == P { name: "a", at: 1, shapes: [Dot, Box(1, 3)] }
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  P { ..., shapes: [..., Box(..., 2)] }
      right: P { ..., shapes: [..., Box(..., 3)] }
                                             ^ differs here

      seed 4626 · rerun: ren test test.ren --only "a payload" --seed 4626

    ──── two constructors ── test.ren:8
      │
    8 │   assert [Dot, Dot, Dot] == [Dot, Box(1, 1), Dot]
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  [..., Dot, ...]
      right: [..., Box(1, 1), ...]
                   ^ differs here

      seed 446 · rerun: ren test test.ren --only "two constructors" --seed 446

    ──── one side is longer ── test.ren:11
       │
    11 │   assert [1, 2, 3, 4] == [1, 2]
       │          ^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  [..., 2, 3, ...]
       right: [..., 2]
                     ^ differs here

       seed 3291 · rerun: ren test test.ren --only "one side" --seed 3291

    ──── the left side is shorter ── test.ren:14
       │
    14 │   assert [1, 2, 3] == [1, 2, 3, 4, 5]
       │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  [..., 3]
       right: [..., 3, 4, ...]
                     ^ differs here

       seed 3665 · rerun: ren test test.ren --only "the left" --seed 3665

    ──── only the first difference ── test.ren:17
       │
    17 │   assert P { name: "a", at: 1, shapes: [] } == P { name: "b", at: 2, shapes: [Dot] }
       │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  P { name: "a", ... }
       right: P { name: "b", ... }
                         ^ differs here

       seed 9197 · rerun: ren test test.ren --only "only the" --seed 9197

    ──── nothing in common ── test.ren:20
       │
    20 │   assert 1 == 2
       │          ^^^^^^
       │
       left:  1
       right: 2
              ^ differs here

       seed 6226 · rerun: ren test test.ren --only "nothing in" --seed 6226

    ──── apart first, right longer ── test.ren:23
       │
    23 │   assert [1, 2] == [9, 2, 3]
       │          ^^^^^^^^^^^^^^^^^^^
       │
       left:  [1, ...]
       right: [9, ...]
               ^ differs here

       seed 360 · rerun: ren test test.ren --only "apart first, right" --seed 360

    ──── apart first, left longer ── test.ren:26
       │
    26 │   assert [1, 2, 7, 8] == [9, 2, 3]
       │          ^^^^^^^^^^^^^^^^^^^^^^^^^
       │
       left:  [1, ...]
       right: [9, ...]
               ^ differs here

       seed 647 · rerun: ren test test.ren --only "apart first, left" --seed 647

    0 passed, 8 failed
    [exit 1]
    |}]

let%expect_test "print shows a value through its type, as a failed assert does" =
  (* an opaque type as its name around what it is, unless it has a `show`
     of its own; through a generic function, a lambda and a handler too,
     and an error that ends the program. A failed `assert` uses a type's
     own `show` too. *)
  run
    {|
type M = opaque Int
  pub fn of(n: Int) -> M = n
type Cents = opaque Int
  pub fn of(n: Int) -> Cents = n
  // inside it, `show(self)` shows only what it's represented as
  pub fn show(self) -> Str = show(self).concat("c")
type P = { m: M, c: Cents, at: Path }
dep Out =
  put: fn(m: M)
handler out() for Out =
  put(m) => print(m)

fn twice<T>(x: T) uses Console =
  let f = fn() => print(x)
  f()
  print([x])

fn main() ! Gone(p: P) uses Console =
  let p = P { m: M.of(1), c: Cents.of(2), at: Path.of("a/b") }
  print(p)
  print(show(M.of(3)).len())
  twice(M.of(4))
  with out() in Out.put(M.of(5))
  print(Path.of("a/b"))
  print(Some("a"))
  fail Gone(p)
|};
  [%expect
    {|
    P { m: M(1), c: 2c, at: a/b }
    4
    M(4)
    [M(4)]
    M(5)
    a/b
    Some("a")
    error: Gone(P { m: M(1), c: 2c, at: a/b })
    |}];
  run
    {|
type Cents = opaque Int
  pub fn of(n: Int) -> Cents = n
  // inside it, `show(self)` shows only what it's represented as
  pub fn show(self) -> Str = show(self).concat("c")

fn main() =
  assert [Cents.of(1)] == [Cents.of(2)]
|};
  [%expect
    {|
    error: panic: this `assert` failed
      ┌─ test.ren:7:10
    7 │   assert [Cents.of(1)] == [Cents.of(2)]
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      = left:  [1c]
      = right: [2c]
    |}]

(* ---- 5. interfaces are exact ----

   What an implementation fails with and what it needs: no more than its
   interface says, required where it's installed and fixed there. *)

let%expect_test "an operation's errors are marked as any call's" =
  types
    {|
dep Users =
  save: fn(u: Int) ! Conflict

fn store(u: Int) = Users.save(u)
fn main() = 1
|};
  [%expect
    {|
    error: `Users.save` can fail, and nothing handles it
      ┌─ test.ren:4:20
    4 │ fn store(u: Int) = Users.save(u)
      │                    ^^^^^^^^^^^^^
      │                    ---------- it can fail with `Conflict`
      help: pass the errors on with `try`, or handle them with `match`
    |}]

let%expect_test "an operation that fails, called with try" =
  types
    {|
pub dep Users =
  save: fn(u: Int) ! Conflict | Full

fn store(u: Int) = try Users.save(u)
fn handled(u: Int) =
  match Users.save(u)
    _ => true
    fail Conflict => false
    fail Full => false
fn main() = 1
|};
  [%expect
    {|
    pub dep Users
      save: fn(Int) ! Conflict | Full
    fn store(u: Int) ! Conflict | Full uses Users
    fn handled(u: Int) -> Bool uses Users
    fn main() -> Int
    |}]

let%expect_test "what an implementation needs is part of its type" =
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn fixed() -> Rates = Rates { usd_to: fn(c) => c }
pub fn stored() -> Rates uses Clock = timed()
fn convert() = with timed() in Rates.usd_to(1)
pub fn public() -> Int = with timed() in Rates.usd_to(1)
fn main() = 1
|};
  [%expect
    {|
    error: expected `Rates`, found `Rates uses Clock`
      ┌─ test.ren:5:39
    5 │ pub fn stored() -> Rates uses Clock = timed()
      │                                       ^^^^^^^
      = `stored` is declared to return `Rates`
      = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
      help: say what it needs where its type is written: `(Rates uses Clock)`

    error: `public` doesn't declare `Clock`
      ┌─ test.ren:7:8
    7 │ pub fn public() -> Int = with timed() in Rates.usd_to(1)
      │        ^^^^^^
      │                               ------- installing this needs `Clock`
      = a public function without `uses` uses nothing, and its body is checked against that
      help: add `uses Clock`
    |}];
  (* the `uses` after a type name is what an implementation needs, and in
     a result it's parenthesized *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
pub fn timed() -> (Rates uses Clock) =
  Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
pub fn convert(r: Rates uses Clock) -> Int uses Clock = 1
fn main() = 1
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub fn timed() -> (Rates uses Clock)
    pub fn convert(r: Rates uses Clock) -> Int uses Clock
    fn main() -> Int
    |}];
  types {|
fn f(x: Int uses Clock) = 1
fn main() = 1
|};
  [%expect
    {|
    error: `Int` isn't a dependency, so it needs nothing
      ┌─ test.ren:1:9
    1 │ fn f(x: Int uses Clock) = 1
      │         ^^^
      help: remove the `uses`: only an implementation of a dependency needs something
    |}]

(* An implementation's operations run with what's installed where it's
   installed: the clock at 1 minute, not the one at 0 *)
let%expect_test "an implementation that needs more, inside another type" =
  types
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
type Box<T> = { it: T }
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn boxed() -> Box<Rates> = Box { it: timed() }
fn main() = 1
|};
  [%expect
    {|
    error: expected `Box<Rates>`, found `Box<Rates uses Clock>`
      ┌─ test.ren:5:28
    5 │ fn boxed() -> Box<Rates> = Box { it: timed() }
      │                            ^^^^^^^^^^^^^^^^^^^
      = `boxed` is declared to return `Box<Rates>`
      = an implementation's type says what it needs, so one that needs more can't stand in for one that needs less
      help: say what it needs where its type is written: `Box<Rates uses Clock>`
    |}]

let%expect_test "an implementation's needs are fixed where it's installed" =
  run
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn timed() = Rates { usd_to: fn(c) => if Clock.now().after(Time.epoch) then c else 0 }
fn main() uses Console =
  with at(1) in
    with timed() in
      with at(0) in
        print(Rates.usd_to(100))
        print(Clock.now())
|};
  [%expect {|
    100
    Time(0)
    ()
    |}]

let%expect_test "an operation can fail with fewer errors, never more" =
  types
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:5:38
    5 │ fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
      │                                      ^^^^^^^^^^^^^^^^^^^^ fails with `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map it: `match Http.get_rate(c)` with the arm `fail Timeout => fail RateUnavailable`
    |}];
  types
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout | Gone
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
dep Plain =
  get: fn() -> Int
fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
fn plain() = Plain { get: fn() => try Http.get_rate(1) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Gone` and `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:7:38
    7 │ fn live() = Rates { usd_to: fn(c) => try Http.get_rate(c) }
      │                                      ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map what it fails with inside it, with `match` and `fail` arms, to what it can: `fail RateUnavailable`

    error: this implementation can fail with `Gone` and `Timeout`, and `Plain.get` can't
      ┌─ test.ren:8:35
    8 │ fn plain() = Plain { get: fn() => try Http.get_rate(1) }
      │                                   ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
      = `Plain.get` can't fail
      help: handle what it fails with inside it, with `match` and `fail` arms
    |}];
  (* an ordinary function's call: its row is open where it's called, which
     isn't more errors, so the help says `match` *)
  types
    {|
fn get(c: Int) -> Int ! Timeout = if c > 0 then c else fail Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn live() = Rates { usd_to: fn(c) => try get(c) }
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:4:38
    4 │ fn live() = Rates { usd_to: fn(c) => try get(c) }
      │                                      ^^^^^^^^^^ fails with `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map it: `match get(c)` with the arm `fail Timeout => fail RateUnavailable`
    |}];
  (* following the help, and an operation that fails with less *)
  run
    {|
dep Http =
  get_rate: fn(c: Int) -> Int ! Timeout
dep Rates =
  usd_to: fn(c: Int) -> Int ! RateUnavailable
fn http(up: Bool) -> Http =
  Http { get_rate: fn(c) => if up then c * 2 else fail Timeout }
fn ask(c: Int) =
  match Http.get_rate(c)
    fail Timeout => fail RateUnavailable
    r => r
fn live() = Rates { usd_to: fn(c) => try ask(c) }
fn fixed() -> Rates = Rates { usd_to: fn(_) => 3 }
fn main() uses Console =
  print(attempt with http(true), live() in Rates.usd_to(5))
  print(attempt with http(false), live() in Rates.usd_to(5))
  print(attempt with fixed() in Rates.usd_to(5))
|};
  [%expect {|
    Ok(10)
    Err(RateUnavailable)
    Ok(3)
    ()
    |}]

let%expect_test "what a handler needs is fixed where it's installed" =
  (* its state is made, and its operations run, with what's installed
     outside its `with`: the inner `Base` doesn't change them *)
  let src =
    {|
dep Base =
  n: fn() -> Int

dep N =
  get: fn() -> Int

handler offset() for N =
  let start = Base.n()
  var seen = 0
  get() =>
    seen += 1
    start * 100 + Base.n() * 10 + seen

fn base(n: Int) -> Base = Base { n: fn() => n }

fn main() uses Console =
  with base(1), offset(), base(2) in
    print(N.get())
    print(N.get())
    print(Base.n())
|}
  in
  types src;
  [%expect
    {|
    dep Base
      n: fn() -> Int
    dep N
      get: fn() -> Int
    handler offset() for N uses Base
    fn base(n: Int) -> Base
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    111
    112
    2
    ()
    |}]

let%expect_test "what a handler needs is needed where it's installed" =
  let src =
    {|
dep N =
  get: fn() -> Int

handler noisy() for N =
  get() =>
    print(1)
    2

fn get() = with noisy() in N.get()
fn main() = get()
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn() -> Int
    handler noisy() for N uses Console
    fn get() -> Int uses Console
    fn main() -> Int uses Console
    |}]

let%expect_test "a public handler says what it needs" =
  types
    {|
pub dep N =
  get: fn() -> Int

pub handler quiet(n: Int) for N =
  get() => n

pub handler noisy(n: Int) for N
    uses Console =
  get() =>
    print(n)
    n

fn main() = 1
|};
  [%expect
    {|
    pub dep N
      get: fn() -> Int
    pub handler quiet(n: Int) for N
    pub handler noisy(n: Int) for N uses Console
    fn main() -> Int
    |}];
  types
    {|
pub dep N =
  get: fn() -> Int

pub handler forgot(n: Int) for N =
  var last = 0
  get() =>
    print(n)
    last = n
    n

handler partly() for N uses Clock =
  let start = Random.int(10)
  get() => start

fn main() = 1
|};
  [%expect
    {|
    error: the handler `forgot` doesn't declare that it needs `Console`
      ┌─ test.ren:4:13
    4 │ pub handler forgot(n: Int) for N =
      │             ^^^^^^
    7 │     print(n)
      │     -------- this call uses `Console`
      = a public handler without `uses` needs nothing, and its operations and state are checked against that
      help: add `uses Console` after what it implements

    error: the handler `partly` doesn't declare that it needs `Random`
       ┌─ test.ren:11:9
    11 │ handler partly() for N uses Clock =
       │         ^^^^^^
    12 │   let start = Random.int(10)
       │               -------------- this call uses `Random`
       = `partly`'s operations and state can only use what its `uses` lists, which is what a `with` that installs it needs
       help: add `Random` to its `uses`
    |}]

let%expect_test "an arm fails with no more than its operation declares" =
  types
    {|
dep N =
  get: fn() -> Int ! Low

fn high() -> Int ! High = fail High

handler wrong() for N =
  get() => try high()

handler longer() for N =
  var calls = 0
  get() =>
    calls += 1
    let n = try high()
    n + calls

fn record(k: Int) -> N = N { get: fn() => if k == 1 then fail High else k }

fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `High`, and `N.get` can't
      ┌─ test.ren:7:12
    7 │   get() => try high()
      │            ^^^^^^^^^^ fails with `High`
      = `N.get` can fail only with `Low`
      help: map it: `match high()` with the arm `fail High => fail Low`

    error: this implementation can fail with `High`, and `N.get` can't
       ┌─ test.ren:13:13
    13 │     let n = try high()
       │             ^^^^^^^^^^ fails with `High`
       = `N.get` can fail only with `Low`
       help: map it: `match high()` with the arm `fail High => fail Low`

    error: this implementation can fail with `High`, and `N.get` can't
       ┌─ test.ren:16:58
    16 │ fn record(k: Int) -> N = N { get: fn() => if k == 1 then fail High else k }
       │                                                          ^^^^^^^^^ fails with `High`
       = `N.get` can fail only with `Low`
       help: fail with what `N.get` can instead: `fail Low`
    |}]

let%expect_test "an arm takes its operation's arguments" =
  types
    {|
dep B =
  z: fn(n: Int) -> Int

handler arity() for B =
  z() => 2

handler typed() for B =
  z(n: Bool) => 2

fn main() = 1
|};
  [%expect
    {|
    error: `B.z` takes 1 argument, but this has 0 parameters
      ┌─ test.ren:5:3
    5 │   z() => 2
      │   ^
      help: give it 1 parameter, one for each argument

    error: expected `fn(Int) -> Int`, found `fn(Bool) -> Int`
      ┌─ test.ren:8:3
    8 │   z(n: Bool) => 2
      │   ^^^^^^^^^^^^^^^
      = `B`'s operation `z`
    |}]

let%expect_test
    "a handler can't use what it implements, even through a function" =
  types
    {|
dep N =
  next: fn() -> Int

fn via() uses N = N.next()

handler through() for N =
  next() => via()

handler direct() for N uses Console =
  next() => N.next()

handler declared() for N uses N =
  next() => 1

fn main() = 1
|};
  [%expect
    {|
    error: a handler for `N` can't use `N`
      ┌─ test.ren:7:13
    6 │ handler through() for N =
      │         ------- `through` implements `N`
    7 │   next() => via()
      │             ^^^^^ this call uses `N`
      = a handler's operations run with what's installed outside its `with`, so `N` here would be the next `N` out, which comes with `outer` (stage 10)
      help: call it outside the handler, install an implementation of `N` around the call with `with`, or implement `N` with a record of functions instead

    error: a handler for `N` can't use `N`
       ┌─ test.ren:10:13
     9 │ handler direct() for N uses Console =
       │         ------ `direct` implements `N`
    10 │   next() => N.next()
       │             ^^^^^^^^ this call uses `N`
       = a handler's operations run with what's installed outside its `with`, so `N` here would be the next `N` out, which comes with `outer` (stage 10)
       help: call it outside the handler, install an implementation of `N` around the call with `with`, or implement `N` with a record of functions instead

    error: a handler for `N` can't use `N`
       ┌─ test.ren:12:9
    12 │ handler declared() for N uses N =
       │         ^^^^^^^^
       = a handler's operations run with what's installed outside its `with`, so `N` here would be the next `N` out, which comes with `outer` (stage 10)
       help: remove `N` from its `uses`
    |}]

let%expect_test "an implementation passes on a parameter's errors" =
  (* what a lambda of an implementation fails with is its own until the
     group is done, so a parameter it passes on with `try` can fail with
     what the operation can *)
  let src =
    {|
dep N =
  get: fn() -> Int ! Low

handler h(f) for N =
  get() => try f()

fn mk(f) -> N = N { get: fn() => try f() }

fn low() -> Int ! Low = fail Low

fn one() -> Int = 1

fn main() uses Console =
  print(with h(low) in attempt N.get())
  print(with mk(low) in attempt N.get())
  print(with h(one) in attempt N.get())
|}
  in
  types src;
  [%expect
    {|
    dep N
      get: fn() -> Int ! Low
    handler h(f: fn() -> Int ! Low uses ..d) for N uses ..d
    fn mk(f: fn() -> Int ! Low) -> N
    fn low() -> Int ! Low
    fn one() -> Int
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Err(Low)
    Err(Low)
    Ok(1)
    ()
    |}];
  types
    {|
dep N =
  get: fn() -> Int ! Low(Int)

fn kept(g: fn() -> Int ! ..e uses ..d) -> (N uses ..d) =
  N { get: fn() => try g() }

handler shape() for N =
  get() => fail Low

fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with anything `..e` stands for, and `N.get` can't
      ┌─ test.ren:5:12
    5 │   N { get: fn() => try g() }
      │            ^^^^^^^^^^^^^^^
      = `N.get` can fail only with `Low`
      help: handle what it passes on inside it, with `match` and `fail` arms

    error: this implementation fails with a different `Low`
      ┌─ test.ren:8:12
    8 │   get() => fail Low
      │            ^^^^^^^^
      = `N.get` declares `Low`'s payload as `Low(Int)`
      help: fail with `Low` as the operation declares it
    |}]

(* ---- 6. a dependency call costs a function call (deps.md, "How it runs") ----

   Every function and lambda takes one hidden parameter, its evidence: the
   vector of what's installed where it's called. Every call passes the
   caller's on, and a call of an operation finds its implementation in
   it. A local prints as its name and id, and so does evidence, `ev`: a
   function's or lambda's after its parameters, a call's right after
   `call`. *)

let%expect_test "every call passes the caller's evidence on" =
  core
    {|
fn stamp() = Clock.now()
fn double(n: Int) = n * 2
fn main() uses Clock, Console =
  let t = stamp()
  print(t.after(Time.epoch))
  print(double(2))
|};
  [%expect
    {|
    (fn stamp () ev/1 (dep-call ev/1 Clock.now))
    (fn double (n/1) ev/2 (* n/1 2))
    (fn main () ev/1
      (let t/2 (call ev/1 stamp)
        (seq (call ev/1 print (call ev/1 Time.after t/2 Time.epoch))
          (call ev/1 print (call ev/1 double 2)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real)
        (with ev/3 (extend ev/2 Console Console.real) (call ev/3 main))))
    |}]

let%expect_test "a lambda takes its evidence where it's called" =
  core
    {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn main() uses Clock =
  let f = later()
  f()
|};
  [%expect
    {|
    (fn later () ev/1
      (let _/2 (dep-call ev/1 Clock.now)
        (lambda () (captures) ev/3 (dep-call ev/3 Clock.now))))
    (fn main () ev/1 (let f/2 (call ev/1 later) (call ev/1 f/2)))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real) (call ev/2 main)))
    |}]

(* There are no copies of a function for what its callers' closures use:
   `twice` passes `f` its own evidence, whatever is in it. *)
let%expect_test "a function over closures passes them its evidence" =
  let src =
    {|
fn twice(f: fn()) =
  try f()
  try f()
fn quiet() = twice(fn() => ())
fn main() uses Console =
  twice(fn() => print(1))
  quiet()
|}
  in
  core src;
  [%expect
    {|
    (fn twice (f/1) ev/2 (seq (call ev/2 f/1) (call ev/2 f/1)))
    (fn quiet () ev/1 (call ev/1 twice (lambda () (captures) ev/2 ())))
    (fn main () ev/1
      (seq (call ev/1 twice (lambda () (captures) ev/2 (call ev/2 print 1)))
        (call ev/1 quiet)))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    1
    ()
    |}];
  let files =
    [
      ( "main.ren",
        {|
import lib
fn main() uses Console = lib.twice(fn() => print(1))
|} );
      ("lib.ren", {|
pub fn twice(f: fn()) =
  try f()
  try f()
|});
    ]
  in
  core_files files;
  [%expect
    {|
    -- lib
    (fn twice (f/1) ev/2 (seq (call ev/2 f/1) (call ev/2 f/1)))

    -- main
    (fn main () ev/1
      (call ev/1 twice (lambda () (captures) ev/2 (call ev/2 print 1))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run_files files;
  [%expect {|
    1
    1
    ()
    |}]

let%expect_test "an operation used as a value calls it where it's called" =
  let src =
    {|
fn one() = 1
fn apply(f: fn() -> Int) -> Int = try f()
fn main() uses Console =
  print(apply(one))
  let write = Console.write
  write("written")
|}
  in
  core src;
  [%expect
    {|
    (fn one () ev/1 1)
    (fn apply (f/1) ev/2 (call ev/2 f/1))
    (fn main () ev/1
      (seq (call ev/1 print (call ev/1 apply one))
        (let write/2
          (lambda ($x/3) (captures) ev/4 (dep-call ev/4 Console.write $x/3))
          (call ev/1 write/2 "written"))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    written
    ()
    |}]

(* An associated value is made once, at startup, with nothing installed. A
   closure in one is called like any other, with its caller's evidence. *)
let%expect_test "a closure in an associated value gets its caller's evidence" =
  let src =
    {|
type T = { n: Int }
  let one = fn() => 1
  let f = fn(g) => g()
fn twice(g) = g() + g()
fn main() uses Console =
  print(T.one())
  print(twice(T.one))
  T.f(fn() => print(3))
|}
  in
  core src;
  [%expect
    {|
    (fn T.one () ev/1 (lambda () (captures) ev/2 1))
    (fn T.f () ev/1 (lambda (g/2) (captures) ev/3 (call ev/3 g/2)))
    (fn twice (g/1) ev/2 (+ (call ev/2 g/1) (call ev/2 g/1)))
    (fn main () ev/1
      (seq (call ev/1 print (call ev/1 T.one))
        (seq (call ev/1 print (call ev/1 twice T.one))
          (call ev/1 T.f (lambda () (captures) ev/2 (call ev/2 print 3))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    2
    3
    ()
    |}]

(* What the first try at threading evidence, which passed one parameter
   per dependency and made copies of functions for them, got wrong. Each
   runs now. *)

let%expect_test "closures in values, and pure lambdas, run where more is used" =
  run
    {|
type T = { n: Int }
  let one = fn() => 1
fn main() uses Console =
  print(T.one())
|};
  [%expect {|
    1
    ()
    |}];
  (* a value whose type is shared with the closure it holds *)
  run
    {|
fn twice_ret(f) =
  let _ = f()
  f
type T = { n: Int }
  let v = twice_ret(fn() => 1)
fn main() uses Console =
  print(T.v())
|};
  [%expect {|
    1
    ()
    |}];
  (* a pure lambda passed from a `main` that uses several dependencies,
     and a closure that takes a closure *)
  run
    {|
fn twice_gen(f, x) = f(f(x))
fn drive(run: fn(fn() -> Int) -> Int) -> Int = try run(fn() => 20)
fn main() uses Clock, Console, Random =
  print(twice_gen(fn(x) => x + 1, 1))
  print(drive(fn(g) => g() + 1))
  let _ = Clock.now()
  print(Random.int(1))
|};
  [%expect {|
    3
    21
    0
    ()
    |}]

let%expect_test "a closure over another module's dependency runs" =
  (* lib doesn't import main, where Users is declared: `twice` passes `f`
     the evidence it's given, whatever is in it *)
  let files =
    [
      ( "main.ren",
        {|
import lib
dep Users =
  get: fn(id: Int) -> Int
fn users() -> Users = Users { get: fn(id) => id * 10 }
fn look() = lib.twice(fn() => Users.get(1))
fn main() uses Console = print(with users() in look())
|}
      );
      ( "lib.ren",
        {|
pub fn twice(f: fn() -> Int) -> Int =
  let _ = try f()
  try f()
|}
      );
    ]
  in
  core_files files;
  [%expect
    {|
    -- lib
    (fn twice (f/1) ev/2 (let _/3 (call ev/2 f/1) (call ev/2 f/1)))

    -- main
    (fn users () ev/1 (record (get: (lambda (id/2) (captures) ev/3 (* id/2 10)))))
    (fn look () ev/1
      (call ev/1 twice
        (lambda () (captures) ev/2 (dep-call ev/2 main.Users.get 1))))
    (fn main () ev/1
      (call ev/1 print
        (with ev/2 (extend ev/1 main.Users (call ev/1 users)) (call ev/2 look))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run_files files;
  [%expect {|
    10
    ()
    |}]

(* The closure is made where one clock is installed, and called where
   another is, which it uses. *)
let%expect_test "a closure uses the implementation installed where it's called"
    =
  let src =
    {|
fn later() uses Clock =
  let _ = Clock.now()
  fn() => Clock.now()
fn frozen_at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch.plus(Duration.minutes(minutes)))
fn main() uses Console =
  let f = with frozen_at(0) in later()
  print(with frozen_at(5) in f())
|}
  in
  core src;
  [%expect
    {|
    (fn later () ev/1
      (let _/2 (dep-call ev/1 Clock.now)
        (lambda () (captures) ev/3 (dep-call ev/3 Clock.now))))
    (fn frozen_at (minutes/1) ev/2
      (call ev/2 Clock.frozen
        (call ev/2 Time.plus Time.epoch (call ev/2 Duration.minutes minutes/1))))
    (fn main () ev/1
      (let f/2
        (with ev/3 (extend ev/1 Clock (call ev/1 frozen_at 0)) (call ev/3 later))
        (call ev/1 print
          (with ev/4 (extend ev/1 Clock (call ev/1 frozen_at 5)) (call ev/4 f/2)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    Time(300000)
    ()
    |}]

(* Evidence threaded wrongly is a bug in the compiler. Core Lint catches
   it, and `ren run`, which doesn't lint, has the interpreter say which
   call it was, rather than fail somewhere inside OCaml. *)
let%expect_test "evidence threaded wrongly is a compiler bug, named" =
  let files =
    [
      ("test.ren", {|
fn stamp() = Clock.now()
fn main() uses Clock = stamp()
|});
    ]
  in
  (* a call passing evidence that isn't in scope *)
  run_start files (fun ~fn_ ~loc -> call ~loc (fn_ "main") 7);
  [%expect
    {|
    (call ev/7 main)
    internal compiler error in lint: Failure("Core Lint: in `$start`, at test.ren:2:4: a call of `main` is given `ev` (7), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call of a function that uses what nothing installs *)
  run_start files (fun ~fn_ ~loc -> call ~loc (fn_ "main") 1);
  [%expect
    {|
    (call ev/1 main)
    internal compiler error in lint: Failure("Core Lint: in `$start`, at test.ren:2:4: a call of `main` uses `Clock`, which is neither used here, by `fn()`, nor installed")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* and the same, run without linting first *)
  let src = clean (snd (List.hd files)) in
  let unlinted body =
    report src (fun () ->
        let open Ren in
        let linked = Driver.linked ~file src in
        let entry = List.nth linked (List.length linked - 1) in
        let fn_ name =
          List.find
            (fun (f : Core.fn_def) -> Path.local f.path = name)
            entry.fns
        in
        let start = fn_ Lower.start_name in
        let start = { start with body = body ~fn_ ~loc:start.loc } in
        let entry =
          {
            entry with
            fns =
              List.map
                (fun (g : Core.fn_def) ->
                  if g.path = start.path then start else g)
                entry.fns;
          }
        in
        let modules = List.rev (entry :: List.tl (List.rev linked)) in
        ignore (Driver.pass "eval" (fun () -> Eval.run modules)))
  in
  unlinted (fun ~fn_ ~loc -> call ~loc (fn_ "main") 7);
  [%expect
    {|
    internal compiler error in eval: Failure("bug: checking or lowering let through a call of `main` with evidence that isn't in scope")
      = this is a bug in the Ren compiler, not in your program
    |}];
  unlinted (fun ~fn_ ~loc -> call ~loc (fn_ "main") 1);
  [%expect
    {|
    internal compiler error in eval: Failure("bug: checking or lowering let through a call of `Clock.now` where nothing installs `Clock`")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint checks evidence is threaded" =
  (* clean: the operation finds `D` in the function's evidence, and a
     lambda's in its own *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call (lambda ~uses:uses_d 2 (op 2)) 1);
  [%expect {||}];
  (* evidence that isn't in scope *)
  lint_evidence (fun ~loc:_ ~op ~lambda:_ ~call:_ ~uses_d:_ -> op 2);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (2), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call that doesn't pass the evidence in scope *)
  lint_evidence (fun ~loc ~op:_ ~lambda ~call ~uses_d:_ ->
      call (lambda 2 (Ren.Core.mk (Int 1) Ren.Ty.int loc)) 2);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a call is given `ev` (2), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a lambda that keeps the evidence of the function it's made in *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call (lambda ~uses:uses_d 2 (op 1)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (1), but the evidence in scope is `ev` (2)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* an operation of a dependency the lambda it's in doesn't use *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call (lambda 2 (op 2)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` uses `test.D`, which is neither used here, by `fn()`, nor installed")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* evidence an inner `With` extends *)
  lint_evidence (fun ~loc ~op ~lambda ~call:_ ~uses_d:_ ->
      let d = Ren.Path.make "test" "D" in
      let impl =
        Ren.Core.mk
          (Record (d, [ ("op", lambda 3 (Ren.Core.mk (Int 1) Ren.Ty.int loc)) ]))
          (Con (d, [ Uses Ren.Ty.closed ]))
          loc
      in
      Ren.Core.mk
        (With
           {
             ev = Ren.Core.evidence 2;
             outer = Ren.Core.evidence 1;
             dep = d;
             impl;
             body = op 1;
           })
        Ren.Ty.int loc);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (1), but the evidence in scope is `ev` (2)")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "a handler is a record of closures over shared cells" =
  core
    (rates
   ^ {|
fn main() uses Console = with counting_rates(3) in print(convert(2))
|}
    );
  [%expect
    {|
    (fn counting_rates (rate/1) ev/2
      (handler (captures rate/1) ev/3
        (let calls/4 0
          (let $calls/5 (cell calls/4)
            (instance
              (test.Rates:
                (record
                  (usd_to:
                    (lambda (_/6) (captures rate/1 $calls/5) ev/7
                      (let calls/4 (get-cell $calls/5)
                        (let $result/8 (seq (= calls/4 (+ calls/4 1)) rate/1)
                          (seq (set-cell $calls/5 calls/4) $result/8)))))))
              (test.RateCalls:
                (record
                  (count:
                    (lambda () (captures $calls/5) ev/9
                      (let calls/4 (get-cell $calls/5) calls/4))))))))))
    (fn convert (n/1) ev/2 (* n/1 (dep-call ev/2 test.Rates.usd_to 1)))
    (fn main () ev/1
      (with ev/2
        (extend ev/1 (test.Rates test.RateCalls) (call ev/1 counting_rates 3))
        (call ev/2 print (call ev/2 convert 2))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}]
