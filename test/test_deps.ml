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
              row_reqs = [];
              modes = [];
              defaults = [];
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
  let args = Ren.Ty.own_args f.scheme.ty in
  Ren.Core.mk
    (Call
       ( Ren.Core.mk (Global (f.path, args, [], [])) f.scheme.ty loc,
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
           dargs = [];
           op = "op";
           fty = Fun ([], Ty.int, Ty.closed, uses_d);
           ev = Core.evidence ev;
           next = false;
           args = [];
         })
      Ty.int loc
  in
  let lambda ?(uses = Ty.closed) ?(given = []) ?(outer = 1) ?captures ev body =
    Core.mk
      (Lambda
         {
           name = "test.main#1";
           params = [];
           ev = Core.evidence ev;
           outer = Core.evidence outer;
           given;
           captures = Option.value captures ~default:[ Core.evidence outer ];
           body;
         })
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
      dicts = [];
      scheme =
        {
          ty = Fun ([], Ty.int, Ty.closed, uses_d);
          names = [];
          reqs = [];
          row_reqs = [];
          modes = [];
          defaults = [];
        };
      body = body ~loc ~op ~lambda ~call ~uses_d;
      test = false;
      loc;
      origin = Written;
      known = [];
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
                    body = Dep [ { fname = "op"; fty = int_fn; fdefault = None; fdefaults = [] } ];
                    members = Path.Map.empty;
                    numeric = None;
                    opaque = false;
                    loc = None;
                  };
                ];
              fns = [ main ];
              values = [];
              shows = [];
              keys = [];
              ops = [];
              method_calls = [];
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

  pub fn none() -> Users = no_users()

handler no_users() for Users =
  get(_) => None
  save(_) => ()
|};
  [%expect
    {|
    (pub dep Users (ops get:fn(Int) -> Option<Int> save:fn(Int) ! Conflict) (members (pub (fn none () (call no_users)))))
    (fn no_users () (handler (for Users) (get (lambda (_) (con None))) (save (lambda (_) ()))))
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>
  save: fn(u: Int) ! Conflict

  pub fn none() -> Users = no_users()

fn main() = 1

handler no_users() for Users =
  get(_) => None
  save(_) => ()
|};
  [%expect
    {|
    pub dep Users
      get: fn(Int) -> Option<Int>
      save: fn(Int) ! Conflict
      pub fn none() -> Users
    fn main() -> Int
    handler no_users() for Users
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
  (* a generic dependency (foundations.md, decision 6) *)
  ast {|
dep Box<T> =
  get: fn() -> T
|};
  [%expect {| (dep Box<T> (ops get:fn() -> T)) |}]

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
      = the dependencies in scope are: `Alloc`, `Async`, `Clock`, `Console`, `Fs`, `Net`, `Os`, `Proc`, `Random`, `Send`, `TestClock`, `TestConsole`, `TestProc`, `TestRandom`, `Unsafe`
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
handler timed() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
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
    handler timed() for Rates uses Clock
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
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
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

let%expect_test "what a function does with a named row, it declares" =
  types
    {|
pub fn calls(c: Clock uses ..d) -> Time = with c in Clock.now()
fn listed(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
fn other(c: Clock uses ..d, r: Random uses ..x) -> Time uses ..d =
  with c, r in Clock.now()
fn main() = 1
|};
  [%expect
    {|
    error: installing this needs `..d`, which `calls` doesn't declare
      ┌─ test.ren:1:48
    1 │ pub fn calls(c: Clock uses ..d) -> Time = with c in Clock.now()
      │                                                ^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `calls` uses: `uses ..d`

    error: installing this needs `..d`, which `listed` doesn't declare
      ┌─ test.ren:2:58
    2 │ fn listed(c: Clock uses ..d) -> Time uses Console = with c in Clock.now()
      │                                                          ^
      = `..d` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: add it to what `listed` uses: `uses Console, ..d`

    error: installing this needs `..x`, which `other` doesn't declare
      ┌─ test.ren:4:11
    4 │   with c, r in Clock.now()
      │           ^
      = `..x` stands for whatever the closure or implementation it names uses, and a function that declares its dependencies declares that too
      help: `other` names one row, `..d`, which is all it can name: name this one `..d` too, where it's written
    |}]

let%expect_test "only a signature names a row" =
  types
    {|
type Holder = { c: Clock uses ..d }
fn body() =
  let g: Clock uses ..q = Clock.frozen(Time.epoch)
  1
fn kinds(c: Clock ! ..d, r: Random uses ..d) = 1
fn main() = 1
|};
  [%expect
    {|
    error: a declaration can't name a row, `..d`
      ┌─ test.ren:1:33
    1 │ type Holder = { c: Clock uses ..d }
      │                                 ^
      = only a function's signature names a row, for now (deps.md, "Implementations")
      help: leave `..d` out

    error: there's no `..q` in this function's signature
      ┌─ test.ren:3:23
    3 │   let g: Clock uses ..q = Clock.frozen(Time.epoch)
      │                       ^
      = a named row stands for what an implementation that comes into or out of the function does, so the signature names it
      help: name `..q` in the function's signature

    error: `..d` names what something uses here, and what something fails with elsewhere in this signature
      ┌─ test.ren:5:43
    5 │ fn kinds(c: Clock ! ..d, r: Random uses ..d) = 1
      │                                           ^
      │                       - here it names what something fails with
      = a row is a list of errors or a list of dependencies, never both
      help: give the two rows two names
    |}]

(* A public wrapper that keeps what its block fails with, to look at it,
   says what that is: a block's errors are otherwise its caller's, passed
   on *)
let%expect_test "a public wrapper says what its body fails with" =
  let src =
    {|
fn flaky(n: Int) -> Int ! Boom =
  if n < 3 then fail Boom else n
pub fn again(n: Int, body: fn() -> Int ! Boom) -> Int ! Boom =
  let r = attempt body()
  if n <= 1 then try r
  else
    match r
      Ok(v) => v
      Err(_) => try again(n - 1, body)
pub fn safe() -> Int ! Boom = try again(3) fn() => try flaky(2)
fn main() uses Console =
  print(attempt safe())
  print(attempt again(2) fn() => 7)
|}
  in
  types src;
  [%expect
    {|
    fn flaky(n: Int) -> Int ! Boom
    pub fn again(n: Int, body: fn() -> Int ! Boom) -> Int ! Boom
    pub fn safe() -> Int ! Boom
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    Err(Boom)
    Ok(7)
    ()
    |}]

let%expect_test "a dependency's self is an implementation" =
  (* `self` needs what its method uses, as `c: N` does, and a receiver
     that needs less will do *)
  run
    {|
dep N =
  get: fn() -> Int

  fn fixed(n: Int) -> N = fixed_n(n)
  fn same(self, k: Int) -> N = self
fn main() uses Console =
  let b = N.fixed(7).same(3)
  print(with b in N.get())

handler fixed_n(n: Int) for N =
  get() => n
|};
  [%expect {|
    7
    ()
    |}];
  (* a public one names what it needs where it's kept *)
  run
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = fixed_n(n)
  pub fn same(self, k: Int) -> (N uses ..d) uses ..d = self
fn main() uses Console =
  print(with N.fixed(7).same(1) in N.get())

handler fixed_n(n: Int) for N =
  get() => n
|};
  [%expect {|
    7
    ()
    |}];
  types
    {|
pub dep N =
  get: fn() -> Int

  pub fn fixed(n: Int) -> N = fixed_n(n)
  pub fn same(self, k: Int) -> N = self
fn noisy() -> Int uses Console =
  print(0)
  5
handler loud() for N =
  get() => noisy()
handler fixed_n(n: Int) for N =
  get() => n
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
       ┌─ test.ren:14:11
    14 │   let b = loud().same(3)
       │           ^^^^^^
       = a stored description's `uses` is the most it may need, and this one needs `Console` too
       help: add it where the type is written: `(N uses Console)`
    |}]

let%expect_test "a transparent parameter kept where its rows close" =
  (* the interface says what the parameter needs is the function's; kept
     as a plain `Rates`, it can't be *)
  types
    {|
pub type Box<R> = { r: R }
pub dep Rates =
  usd_to: fn(Int) -> Int
pub fn keep(r: Rates uses ..d) -> Box<Rates uses ..d> = Box { r: r }
pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
fn main() = 1
|};
  [%expect
    {|
    error: `r` is kept where it can't need anything, so it isn't transparent
      ┌─ test.ren:5:15
    5 │ pub fn sneaky(r: Rates) -> Box<Rates> = keep(r)
      │               ^
      = a parameter whose type is a dependency's, `Rates`, needs what its function uses, but here it's passed to something that keeps it as an implementation that needs nothing
      help: to keep it, name what it needs, `r: Rates uses ..d`, and write it where it's kept
    |}];
  (* named, it's fine *)
  types
    {|
pub type Box<R> = { r: R }
pub dep Rates =
  usd_to: fn(Int) -> Int
pub fn keep(r: Rates uses ..d) -> Box<Rates uses ..d> = Box { r: r }
pub fn fine(r: Rates uses ..d) -> Box<Rates uses ..d> = keep(r)
fn main() = 1
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub fn keep(r: Rates uses ..d) -> Box<Rates uses ..d>
    pub fn fine(r: Rates uses ..d) -> Box<Rates uses ..d>
    fn main() -> Int
    |}]

let%expect_test "a block's dependency is its writer's, whatever a with installs"
    =
  (* `run_two` installs `N` around its calls of `f`, whose type lists
     nothing: the block finds `N` where it's written, in `main` *)
  types
    {|
dep N =
  get: fn() -> Int

handler fixed(n: Int) for N =
  get() => n
fn run_two(f) = (with fixed(1) in f()) + (with fixed(2) in f())
fn main() uses Console =
  print(run_two(fn() => N.get()))
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
      ┌─ test.ren:7:4
    7 │ fn main() uses Console =
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    8 │   print(run_two(fn() => N.get()))
      │                         ------- this call uses `N`
      help: install one inside `main`: `with fixed(...) in ...`
    |}];
  types
    {|
dep N =
  get: fn() -> Int

handler fixed(n: Int) for N =
  get() => n
type A = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = with fixed(self.n) in try body()
fn main() uses Console =
  let a = A { n: 3 }
  print(a.wrap() fn() => N.get())
|};
  [%expect
    {|
    error: nothing installs `N` before `main`
       ┌─ test.ren:8:4
     8 │ fn main() uses Console =
       │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    10 │   print(a.wrap() fn() => N.get())
       │                          ------- this call uses `N`
       help: install one inside `main`: `with fixed(...) in ...`
    |}]

let%expect_test "an implementation a function makes can need anything" =
  (* a description a function gives is exactly what its body found, and
     each call of it opens it again, so it fits wherever more is allowed
     (foundations.md, decision 3): `fixed` gives an `N` *)
  let src =
    {|
dep N =
  get: fn() -> Int

fn noisy() -> Int uses Console =
  print(0)
  5
handler loud_n() for N =
  get() => noisy()
handler fixed_n(n: Int) for N =
  get() => n
fn loud() -> (N uses Console) = loud_n()
fn fixed(n: Int) = fixed_n(n)
fn written(n: Int) -> (N uses ..d) = fixed_n(n)
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
    handler loud_n() for N uses Console
    handler fixed_n(n: Int) for N
    fn loud() -> (N uses Console)
    fn fixed(n: Int) -> N
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
    error: `now` is an operation of `Timer`: an operation is called, not read
      ┌─ test.ren:4:23
    4 │ fn read(c: Timer) = c.now
      │                       ^^^
      = a description of `Timer` is called as a method, `c.now(...)`, which installs it for the call
      help: call it: `c.now(...)`

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
  print(Clock.instant() >= start)
  print(Clock.now() > Time.epoch)
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
  run ~twice:false
    (Printf.sprintf
       {|
fn main() ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Fs, Console =
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
fn main() ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Fs, Console =
  let p = Path.of("%s")
  print((try Fs.read(p)).len())
  try Fs.read_str(p)
|}
       file);
  Sys.remove file;
  [%expect {|
    1
    error: InvalidUtf8(0, false)
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
  [%expect
    {|
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
  let t = Time.epoch + Duration.minutes(5) + Duration.seconds(1)
  print(t > Time.epoch)
  print(t == Time.epoch + Duration.ms(301000))
  let i = Instant.zero + Duration.ms(5)
  print(i - Instant.zero == Duration.ms(5))
  print(Instant.zero < i)
  let d = Duration.seconds(2) * 3
  print(d.in_ms())
  print(d > Duration.seconds(5))
  print(d < Duration.seconds(6))
|};
  [%expect
    {|
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
      help: an implementation of it is a handler, `handler h() for Users`, with an arm for each operation under it, called as `h()`
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
  [%expect
    {|
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
  [%expect
    {|
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
  [%expect
    {|
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
  types
    {|
fn load() -> Bool uses Fs = Fs.exists(Path.of("x"))

fn main() uses Console = print(load())
|};
  [%expect
    {|
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
  [%expect
    {|
    error: nothing installs `TestClock` in the test "the real file system, and the test clock"
      ┌─ test.ren:1:6
    1 │ test "the real file system, and the test clock" uses Fs, Clock =
      │      ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ this test gets only the real `Fs` and `Clock`, and the test `Random`, `Console`, `Os`, `Proc`, `Net` and `Async`, and what controls them
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

  pub fn none() -> Users = no_users()

fn main() uses Users, Console =
  print(Users.get(1))

handler no_users() for Users =
  get(_) => None
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:6:16
    6 │ fn main() uses Users, Console =
      │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    7 │   print(Users.get(1))
      │         ------------ this call uses `Users`
      help: install one inside `main`: `with Users.none() in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

handler mem_users(ids: Array<Int>) for Users =
  get(id) => None
fn find(id: Int) = Users.get(id)

fn main() = print(find(1))
|};
  [%expect
    {|
    error: nothing installs `Users` before `main`
      ┌─ test.ren:8:4
    8 │ fn main() = print(find(1))
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
      │                   ------- this call uses `Users`
      help: install one inside `main`: `with mem_users(...) in ...`
    |}];
  types
    {|
pub dep Users =
  get: fn(id: Int) -> Option<Int>

fn main() uses Alloc = print(Users.get(1))
|};
  [%expect
    {|
    error: `main` doesn't declare `Console`
      ┌─ test.ren:4:4
    4 │ fn main() uses Alloc = print(Users.get(1))
      │    ^^^^
      │                        ------------------- this call uses `Console`
      = `main`'s body can only use what its `uses` lists
      help: add `Console` to its `uses`

    error: nothing installs `Users` before `main`
      ┌─ test.ren:4:4
    4 │ fn main() uses Alloc = print(Users.get(1))
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
      │                              ------------ this call uses `Users`
      help: install one inside `main`, with `with`: `with h() in ...`, for a handler `h` for `Users`

    error: nothing installs `Alloc` before `main`
      ┌─ test.ren:4:16
    4 │ fn main() uses Alloc = print(Users.get(1))
      │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
      help: remove it: nothing can implement `Alloc` yet
    |}]

let%expect_test
    "main's help suggests only an implementation that can be installed" =
  (* one that needs what it implements would need one installed before it *)
  types
    {|
dep Log =
  put: fn(n: Int)
handler doubling() over Log =
  put(n) => next.put(n * 2)
fn main() uses Log =
  Log.put(1)
|};
  [%expect
    {|
    error: nothing installs `Log` before `main`
      ┌─ test.ren:5:16
    5 │ fn main() uses Log =
      │                ^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    6 │   Log.put(1)
      │   ---------- this call uses `Log`
      help: install one inside `main`, with `with`: `with h() in ...`, for a handler `h` for `Log`
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
       │                ^^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
       │                                       ---------- this call uses `Rates`
       help: install one inside `main`: `with counting_rates(...) in ...`
    |}]

let%expect_test "what a test can't use" =
  test
    {|
pub dep Users =
  count: fn() -> Int

  pub fn none() -> Users = no_users()

test "counts users" =
  assert Users.count() == 0

test "the system clock" uses Clock =
  TestClock.advance(Duration.ms(1))

handler no_users() for Users =
  count() => 0
|};
  [%expect
    {|
    error: nothing installs `Users` in the test "counts users"
      ┌─ test.ren:6:6
    6 │ test "counts users" =
      │      ^^^^^^^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`, and what controls them
    7 │   assert Users.count() == 0
      │          ------------- this call uses `Users`
      help: install one inside the test: `with Users.none() in ...`

    error: nothing installs `TestClock` in the test "the system clock"
       ┌─ test.ren:9:6
     9 │ test "the system clock" uses Clock =
       │      ^^^^^^^^^^^^^^^^^^ this test gets only the real `Clock`, and the test `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`, and what controls them
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
    error: a test's `uses` asks for a real implementation, and only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async` have one, not `Users`
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
pub dep Users =
  count: fn() -> Int

  pub fn none() -> Users = no_users()

group counts(c: Clock) with c =
  test "counts users" =
    assert Users.count() == 0

group "frozen" = counts(Clock.frozen(Time.epoch))

handler no_users() for Users =
  count() => 0
|};
  [%expect
    {|
    error: nothing installs `Users` in the test "frozen / counts users"
       ┌─ test.ren:10:7
    10 │ group "frozen" = counts(Clock.frozen(Time.epoch))
       │       ^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`, and what controls them
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
      │       ^^^^^^^^ a test gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`, and what controls them
      │                  ---------------- this call uses `conform.Users`
      help: `conform.counts` is another module's group, so pass one in: give the group a parameter of type `conform.Users` that its `with` installs, and pass an implementation to it here
    |}]

(* ---- 4. swapping is one line, and a test needs none ----

   Implementations, `with`, handlers, and tests and groups
   with the test implementations they get. *)

let%expect_test "with's syntax" =
  ast
    {|
fn main() =
  with Clock.frozen(t), counting(1) in
    body()
  g(with a in 1, 2)
|};
  [%expect
    {| (fn main () (block (with (call (. (con Clock) frozen) t) (call counting 1) (call body)) (call g (with a 1) 2))) |}];
  ast {|
fn main() = with a b in 1
|};
  [%expect
    {|
    error: expected `,`, `over`, `as` or `in` after what `with` installs, found `b`
      ┌─ test.ren:1:20
    1 │ fn main() = with a b in 1
      │                    ^
      help: write what it installs, then `in`, then the code it's installed around
    |}];
  (* what a signature writes: what an implementation needs, what a
     block's type fails with and uses, and named rows *)
  types
    {|
fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad uses Clock) -> (Clock uses Random, ..d)
    ! ..e
    uses ..d =
  c
fn h(k: Option<Clock uses Random>, m: (Int)) = 1
fn main() = 1
|};
  [%expect
    {|
    fn f(c: Clock uses Random, ..d, g: fn(Int) -> Int ! Bad uses Clock) -> (Clock uses Random, ..d) uses ..d
    fn h(k: Option<Clock uses Random>, m: Int) -> Int
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
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
fn stamp() = Clock.now()
fn main() uses Console =
  print(with at(1) in stamp())
  print(with at(1) in with at(2) in stamp())
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
        (call ev/2 Time.add Time.epoch (call ev/2 Duration.minutes minutes/1))))
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
handler none() for Users =
  get(_) => 0
fn find() = Users.get(1)
fn found() = with none() in find()
pub fn public() -> Int = with none() in find()
fn main() = 1
|};
  [%expect
    {|
    dep Users
      get: fn(Int) -> Int
    handler none() for Users
    fn find() -> Int uses Users
    fn found() -> Int
    pub fn public() -> Int
    fn main() -> Int
    |}]

let%expect_test "a with's body uses no more than what's outside it" =
  (* a block called inside a `with` but written outside it, a block
     parameter called inside one, and a dependency parameter installed
     inside another: a block uses what's where it's written, never what
     the `with` around its call installs (foundations.md, decision 5) *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
fn run_at(f: fn() -> Int) -> Int = with at(1) in try f()
fn run_inferred(f) = with at(1) in try f()
fn convert(r: Rates) = with Clock.frozen(Time.epoch) in with r in Rates.usd_to(4)
handler timed() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
handler same() for Rates =
  usd_to(c) => c
fn local() uses Console, Clock =
  let k = fn() => print(Clock.now())
  with at(2) in k()
  with at(3) in
    k()
    with same() in k()
fn main() uses Console =
  with Clock.frozen(Time.epoch + Duration.minutes(9)) in
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
    fn run_inferred<T>(f: fn() -> T) -> T
    fn convert(r: Rates) -> Int
    handler timed() for Rates uses Clock
    handler same() for Rates
    fn local() uses Clock, Console
    fn main() uses Console
    |}];
  run src;
  [%expect
    {|
    5
    5
    6
    Time(540000)
    0
    Time(540000)
    Time(540000)
    Time(540000)
    ()
    |}];
  (* a block parameter called inside a `with`, inferred or written, gets
     none of what it installs: the block's `Clock` is its writer's *)
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
    4 │   print(inferred(fn() => Clock.now()))
      │                          ----------- this call uses `Clock`
      = `main`'s body can only use what its `uses` lists
      help: add `Clock` to its `uses`
    |}];
  (* a signature that says so, called where the caller uses the same
     dependency itself *)
  run
    {|
fn run_at(f: fn() -> Int uses Clock) -> Int =
  with Clock.frozen(Time.epoch) in try f()
fn main() uses Console, Clock =
  print(run_at(fn() => if Clock.now() > Time.epoch then 1 else 2))
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
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
handler logger(base: Int) for Log =
  put(n) => print(base + n)
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
  [%expect
    {|
    fn count(n: Int) -> Int
    fn loud(n: Int) -> Int uses Console
    fn main() uses Console
    |}]

let%expect_test "with installs an implementation" =
  types {|
fn bad() = with 3 in 1
fn unknown(c) = with c in 1
fn main() = 1
|};
  [%expect
    {|
    error: `with` installs an implementation, but this is an `Int`
      ┌─ test.ren:1:17
    1 │ fn bad() = with 3 in 1
      │                 ^
      = `with` installs an implementation of a dependency, a handler, around its body
      help: give it an implementation, like `Clock.frozen(t)`

    error: `with` can't tell what `c` installs
      ┌─ test.ren:2:22
    2 │ fn unknown(c) = with c in 1
      │                      ^ its type isn't written
      help: write `c`'s type, the dependencies it implements
    |}]

let%expect_test "a wrapper in a with is called instead" =
  (* the help writes the item as a call with the body as a block, and
     `try` only if it fails *)
  types
    {|
type W = { n: Int }
  fn wrap(self, body: fn() -> Int) -> Int = self.n * (try body())
  fn times(n: Int, body: fn() -> Int ! Nope) -> Int ! Nope = n + (try body())
fn main() uses Console =
  let w = W { n: 3 }
  print(with w.wrap() in 5)
  print(with W.times(3) in 5)
|};
  [%expect
    {|
    error: `with` installs only handlers
      ┌─ test.ren:6:14
    6 │   print(with w.wrap() in 5)
      │              ^^^^^^^^ takes a block
      = `wrap` is a function that runs a block, so it's called with the body as one
      help: call it: `w.wrap() fn() => ...`

    error: `with` installs only handlers
      ┌─ test.ren:7:14
    7 │   print(with W.times(3) in 5)
      │              ^^^^^^^^^^ takes a block
      = `W.times` is a function that runs a block, so it's called with the body as one
      help: call it: `try W.times(3) fn() => ...`
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
  with counting_rates(2) in with counting_rates(5) in
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

handler alloc() for Alloc =
  get() => 1

handler change(inout n: Int) for A =
  x() => n
  y() => n

fn main() = 1
|};
  [%expect
    {|
    error: `missing` doesn't implement `y`
       ┌─ test.ren:11:9
    11 │ handler missing() for A =
       │         ^^^^^^^
       = a handler implements every operation, unless it goes `over` another implementation, which then does the rest
       help: write them, or declare it `over A` if another `A` should handle them

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
       help: say which dependency's it is: `A.x(...) => ...` or `B.x(...) => ...`

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

    error: `Alloc` has no operations, so a handler can't implement it
       ┌─ test.ren:33:21
    33 │ handler alloc() for Alloc =
       │                     ^^^^^
       = `Alloc` is only a name so far: what it can do comes in a later stage
       help: remove it from after `for`

    error: a handler's parameter can't be `inout`
       ┌─ test.ren:36:22
    36 │ handler change(inout n: Int) for A =
       │                      ^
       = calling a handler describes it, and each `with` that installs it keeps its parameters, so there's nothing to write back
       help: remove the `inout`
    |}]

let%expect_test "a block in an arm changes the handler's state" =
  (* it captures the arm's `n` by reference, and the arm writes it back
     to the handler's state when it ends *)
  run
    {|
dep A =
  x: fn() -> Int

fn twice(f: fn()) =
  try f()
  try f()

handler h() for A =
  var n = 0
  x() =>
    twice(fn() => n += 1)
    n

fn main() uses Console =
  with h() in
    print(A.x())
    print(A.x())
|};
  [%expect {|
    2
    4
    ()
    |}]

let%expect_test "an arm calls a block parameter, then changes its state" =
  (* row 34 of exclusivity.md: each access is an instant, so the call
     running the handler again in between is only recursion *)
  run
    {|
dep A =
  visit: fn(f: fn())
  count: fn() -> Int

handler h() for A =
  var seen = [0]
  visit(f) =>
    f()
    &seen.push(seen.len())
  count() => seen.len()

fn main() uses Console =
  with h() in
    A.visit(fn() => ())
    A.visit(fn() => ())
    print(A.count())
|};
  [%expect {|
    3
    ()
    |}]

let%expect_test "an arm changes its state across a call that lets go of it" =
  (* row 31 of exclusivity.md, narrowed to a call marked `release` (the
     services stage's What's decided 10): the block makes one while the
     call it's passed to changes `cache` *)
  types
    {|
dep A =
  load: fn(k: Int) -> Int

fn update(inout m: Map<Int, Int>, k: Int, f: fn() -> Int) =
  &m.set(k, try f())

handler cached() over A =
  var cache: Map<Int, Int> = Map.empty
  load(k) =>
    update(&cache, k, fn() => release next.load(k))
    cache.get(k) orelse 0

fn main() = 1
|};
  [%expect
    {|
    error: `cache` is changed across a call that lets go of the handler
       ┌─ test.ren:10:39
    10 │     update(&cache, k, fn() => release next.load(k))
       │                                       ^^^^^^^^^^^^ lets go of the handler
       │            ------ changed for the whole call
       = at `release` and `Async.until` other tasks run the handler
       help: make the call first, `let v = release next.load(k)`, then change `cache` with `v`
    |}]

let%expect_test "an arm changes its state across a call of a block parameter" =
  (* row 33 of exclusivity.md: `f` can run this handler again while
     `each_mut` changes `items` *)
  types
    {|
dep A =
  visit: fn(f: fn())

fn each_mut(inout xs: Array<Int>, f: fn(Int) -> Int) =
  for x in &xs
    x = try f(x)

handler h() for A =
  var items = [1, 2]
  visit(f) =>
    each_mut(&items, fn(i) =>
      f()
      i + 1)

fn main() = 1
|};
  [%expect
    {|
    error: `items` is changed across a call of `f`
       ┌─ test.ren:12:7
    11 │     each_mut(&items, fn(i) =>
       │              ------ changed for the whole call
    12 │       f()
       │       ^^^ `f` is called here
       = `f` can run this handler again
       help: call `f` before or after the change
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

    error: expected `for` or `over` and the dependencies it implements, found `=`
       ┌─ test.ren:11:13
    11 │ handler f() =
       │             ^
       help: say what it implements: `handler f(...) for Clock =`, or `over Clock` to go in front of another `Clock`
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

let%expect_test "a handler's state is made where it's installed, and can fail" =
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
    dep N
      get: fn() -> Int
    fn bad() -> Int ! Oops
    handler h() for N ! Oops
    fn main() -> Int
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

handler fixed(k: Int) for N =
  next() => k

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
    handler fixed(k: Int) for N
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

let%expect_test "narrowed where a written type asks for one" =
  (* where a written type asks for one of its dependencies, it describes
     an implementation of just that one: installing it installs only
     that, and the other comes from further out *)
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
          (test.Rates:
            (record
              (usd_to: (lambda (c/3) (captures ev/2) ev/4 (extend ev/2) c/3))))
          (test.RateCalls:
            (record (count: (lambda () (captures ev/2) ev/5 (extend ev/2) 0)))))))
    (fn convert (r/1) ev/2
      (with ev/3 (extend ev/2 test.Rates r/1) (dep-call ev/3 test.Rates.usd_to 1)))
    (fn main () ev/1 (call ev/1 convert (narrowed test.Rates (call ev/1 both))))
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
    with calls_at(0) in
      run(r) + RateCalls.count()

fn main() uses Console =
  let p = plus(0)
  with p in
    with calls_at(0) in
      print(run(p))
  let h = counting_rates(4)
  with h in
    print(run(h))
    let r: Rates = h
    print(run(r))
    print(RateCalls.count())
  let s = counting_rates(2)
  with s in
    with calls_at(7) in
      with s in
        print(run(s))
  print(nested(plus(10)))

handler plus(k: Int) for Rates =
  usd_to(c) => c + k

handler calls_at(k: Int) for RateCalls =
  count() => k
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
    handler plus(k: Int) for Rates
    handler calls_at(k: Int) for RateCalls
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
     needed where it's installed. Today a handler in a group whose arms
     use a dependency is wrongly said not to declare it, which the record
     implementation this was before didn't run into: until that's fixed,
     this is today's output, not the target, `a` and `b` `uses Random` *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn a(n: Int) -> Int =
  if n == 0 then 0
  else
    let h = via_b()
    with h in
      with plus(0) in
        run(h) + Rates.usd_to(n)

fn b(c: Int) -> Int = a(c - 1) + Random.int(1)

fn main() uses Console, Random = print(a(2))

handler via_b() for Rates =
  usd_to(c) => b(c)

handler plus(k: Int) for Rates =
  usd_to(c) => c + k
|};
  [%expect
    {|
    error: `via_b` doesn't declare `Random`
       ┌─ test.ren:18:9
    18 │ handler via_b() for Rates =
       │         ^^^^^
       = `via_b`'s body can only use what its `uses` lists
       help: add `Random` to its `uses`
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
       │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
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
    Clock.now() == Time.epoch + Duration.ms(3)
|};
  [%expect {| true |}]

let%expect_test
    "where nothing says which, a handler of several keeps its whole type" =
  (* `later`'s `h` keeps its type, `RateCalls & Rates`, and `run(r)`
     narrows it to a `Rates` there, as `run`'s parameter is written;
     `make` and `some` return it, which a public function can't without
     writing its type *)
  types
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

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
    error: expected `Unit`, found `RateCalls & Rates`
       ┌─ test.ren:19:17
    19 │ pub fn make() = counting_rates(1)
       │                 ^^^^^^^^^^^^^^^^^
       = a public function without `->` returns `Unit`
       help: add `-> RateCalls & Rates` to the signature

    error: expected `Unit`, found `Option<RateCalls & Rates>`
       ┌─ test.ren:21:17
    21 │ pub fn some() = Some(counting_rates(1))
       │                 ^^^^^^^^^^^^^^^^^^^^^^^
       = a public function without `->` returns `Unit`
       help: add `-> Option<RateCalls & Rates>` to the signature
    |}]

let%expect_test "narrowed inside the type that's written" =
  (* `Option<Rates>` asks for a `Rates` inside it, and so does an array
     written to hold `Rates`, in either order *)
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
  let xs: Array<Rates> = [counting_rates(4), plus(0)]
  let ys: Array<Rates> = [plus(0), counting_rates(5)]
  print(run(xs[0]) + run(ys[1]))
  match some()
    Some(r) => print(run(r))
    None => ()

handler plus(k: Int) for Rates =
  usd_to(c) => c + k
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
    handler plus(k: Int) for Rates
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
fn takes(g: fn() -> Rates) = 1

fn main() =
  let r: Clock = counting_rates(1)
  let n = takes(f)
  let zs = [counting_rates(1), Clock.frozen(Time.epoch)]
  ()
|};
  [%expect
    {|
    error: expected `Clock`, found `RateCalls & Rates`
       ┌─ test.ren:15:18
    15 │   let r: Clock = counting_rates(1)
       │                  ^^^^^^^^^^^^^^^^^
       = a `RateCalls & Rates` is an implementation of `RateCalls` and `Rates`, not of `Clock`
       help: give an implementation of `Clock` here: a handler for `Clock`

    error: expected `fn() -> Rates`, found `fn() -> RateCalls & Rates`
       ┌─ test.ren:16:17
    16 │   let n = takes(f)
       │                 ^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: this element is a `Clock`, but the elements before it are a `RateCalls & Rates`
       ┌─ test.ren:17:32
    17 │   let zs = [counting_rates(1), Clock.frozen(Time.epoch)]
       │                                ^^^^^^^^^^^^^^^^^^^^^^^^
       = a `RateCalls & Rates` is an implementation of `RateCalls` and `Rates`, not of `Clock`
       help: give an implementation of `Clock` instead of the `RateCalls & Rates`: a handler for `Clock`
    |}]

let%expect_test "whether it checks doesn't depend on which comes first" =
  (* [same]'s `T` is inferred, not written, so a handler of several isn't
     narrowed to it, whichever argument comes first; nor is what's in `o`,
     already made when `p` says it's a `Rates`. Where nothing says, it
     keeps its whole type, which a `with` installs both of *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn same(a, b) = if true then a else b

fn id(a) = a

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  with id(counting_rates(5)) in print(RateCalls.count() + Rates.usd_to(1))
  let x = same(plus(1), counting_rates(2))
  let y = same(counting_rates(3), plus(1))
  print(run(x) + run(y))
  let o = Some(counting_rates(4))
  let p: Option<Rates> = o
  match p
    Some(r) => print(run(r))
    None => ()

handler plus(k: Int) for Rates =
  usd_to(c) => c + k
|}
  in
  run src;
  [%expect
    {|
    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:19:25
    19 │   let x = same(plus(1), counting_rates(2))
       │                         ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: expected `RateCalls & Rates`, found `Rates`
       ┌─ test.ren:20:35
    20 │   let y = same(counting_rates(3), plus(1))
       │                                   ^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: expected `Option<Rates>`, found `Option<RateCalls & Rates>`
       ┌─ test.ren:23:26
    23 │   let p: Option<Rates> = o
       │                          ^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`
    |}]

let%expect_test
    "an `if` whose branches are a handler of several and one of them" =
  (* a branch isn't a written type, so neither narrows the other, in
     either order: the help says to write what the `if` produces, which
     narrows both *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

handler plus_one() for Rates =
  usd_to(c) => c + 1

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let x = if true then plus_one() else counting_rates(2)
  let y = if true then counting_rates(3) else plus_one()
  print(run(x) + run(y))
|}
  in
  run src;
  [%expect
    {|
    error: this `else` branch is a `RateCalls & Rates`, but the `then` branch is a `Rates`
       ┌─ test.ren:17:40
    17 │   let x = if true then plus_one() else counting_rates(2)
       │                                        ^^^^^^^^^^^^^^^^^
       │                        ---------- the `then` branch is a `Rates`
       = both branches of an `if` have to produce the same type
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: say what the `if` produces: `let x: Rates = if ...`

    error: this `else` branch is a `Rates`, but the `then` branch is a `RateCalls & Rates`
       ┌─ test.ren:18:47
    18 │   let y = if true then counting_rates(3) else plus_one()
       │                                               ^^^^^^^^^^
       │                        ----------------- the `then` branch is a `RateCalls & Rates`
       = both branches of an `if` have to produce the same type
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: say what the `if` produces: `let x: Rates = if ...`
    |}];
  run
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

handler plus_one() for Rates =
  usd_to(c) => c + 1

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let x: Rates = if true then plus_one() else counting_rates(2)
  let y: Rates = if true then counting_rates(3) else plus_one()
  print(run(x) + run(y))
  print(run(if false then plus_one() else counting_rates(4)))
|};
  [%expect {|
    5
    4
    ()
    |}];
  check_error
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn main() =
  let x = if true then Clock.frozen(Time.epoch) else counting_rates(2)
  let y = if true then counting_rates(3) else Clock.frozen(Time.epoch)
  ()
|};
  [%expect
    {|
    error: this `else` branch is a `RateCalls & Rates`, but the `then` branch is a `Clock`
       ┌─ test.ren:12:54
    12 │   let x = if true then Clock.frozen(Time.epoch) else counting_rates(2)
       │                                                      ^^^^^^^^^^^^^^^^^
       │                        ------------------------ the `then` branch is a `Clock`
       = both branches of an `if` have to produce the same type
       = a `RateCalls & Rates` is an implementation of `RateCalls` and `Rates`, not of `Clock`
       help: give an implementation of `Clock` here: a handler for `Clock`

    error: this `else` branch is a `Clock`, but the `then` branch is a `RateCalls & Rates`
       ┌─ test.ren:13:47
    13 │   let y = if true then counting_rates(3) else Clock.frozen(Time.epoch)
       │                                               ^^^^^^^^^^^^^^^^^^^^^^^^
       │                        ----------------- the `then` branch is a `RateCalls & Rates`
       = both branches of an `if` have to produce the same type
       = a `RateCalls & Rates` is an implementation of `RateCalls` and `Rates`, not of `Clock`
       help: give an implementation of `Clock` instead of the `RateCalls & Rates`: a handler for `Clock`
    |}]

let%expect_test "a handler of several passed on inside its own `with`" =
  (* nothing says what's in `o` is one of the handler's dependencies, so
     it keeps its whole type: `with r` installs both, and `run(r)`, inside
     it, narrows it to a `Rates` there. What `r` needs is then copied where
     it's passed, as it is for a handler whose type is known: joined to
     what `run` uses, it would be what the `with`'s body uses, `Rates`
     included, and `main` would have to install the `Rates` the `with`
     installs. `k` gets nothing from outside. A `for` loop's variable is
     what the array's items are known to be, as a pattern's is *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn k() =
  let o = Some(counting_rates(2))
  match o
    Some(r) => with r in RateCalls.count() + run(r)
    None => 0

fn main() uses Console =
  let o = Some(counting_rates(2))
  match o
    Some(r) => print(with r in Rates.usd_to(5) + run(r))
    None => ()
  for r in [counting_rates(3)]
    print(with r in Rates.usd_to(1) + run(r))
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
    fn k() -> Int
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    12
    6
    ()
    |}]

let%expect_test "a value of several deps passed as each of them" =
  (* passing a value of several dependencies where a written type asks for
     one of them narrows it to that one there, and no more: the value
     keeps its whole type, so another use can pass it as the other
     dependency, or install both with `with`. A `let` or a pattern has
     the type its value was made with, through a generic's `T` too, and a
     lambda's parameter the type written for it *)
  run
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn run2(c: RateCalls) -> Int = with c in RateCalls.count()

fn id(x) = x

fn main() uses Console =
  let o = Some(counting_rates(2))
  match o
    Some(h) => print(run(h) + run2(h))
    None => print(0)
  let h = id(counting_rates(3))
  print(run(h))
  with h in
    print(RateCalls.count())
  let hs = [counting_rates(4), counting_rates(5)]
  let a = hs[1]
  print(run(a))
  with a in
    print(RateCalls.count())
  let b = if hs.len() > 1 then counting_rates(6) else counting_rates(7)
  print(run(b))
  with b in
    print(Rates.usd_to(1) + RateCalls.count())
  let f = fn(r: RateCalls & Rates) => run(r) + (with r in RateCalls.count())
  print(f(counting_rates(8)))
|}
    );
  [%expect {|
    2
    3
    0
    5
    0
    6
    7
    8
    ()
    |}]

let%expect_test "a value holding a handler of several, written as one elsewhere"
    =
  (* what's in `o` was made with its whole type, which a type written for
     `o` afterwards doesn't narrow: the same error whether that's said
     before the handler's passed or after *)
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let o = Some(counting_rates(2))
  match o
    Some(h) => print(run(h))
    None => ()
  let p: Option<RateCalls> = o
  print(0)
|}
    );
  [%expect
    {|
    error: expected `Option<RateCalls>`, found `Option<RateCalls & Rates>`
       ┌─ test.ren:23:30
    23 │   let p: Option<RateCalls> = o
       │                              ^
       = `RateCalls & Rates` is a `RateCalls` only where a written type asks for one
       help: write it where it's made or passed, `let x: RateCalls = ...` or `fn f(x: RateCalls)`
    |}];
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let o = Some(counting_rates(2))
  let p: Option<RateCalls> = o
  match o
    Some(h) => print(run(h))
    None => ()
|}
    );
  [%expect
    {|
    error: expected `Option<RateCalls>`, found `Option<RateCalls & Rates>`
       ┌─ test.ren:20:30
    20 │   let p: Option<RateCalls> = o
       │                              ^
       = `RateCalls & Rates` is a `RateCalls` only where a written type asks for one
       help: write it where it's made or passed, `let x: RateCalls = ...` or `fn f(x: RateCalls)`
    |}]

let%expect_test "many handlers of several given early check in time" =
  (* a handler of several has its type when it's made, and is narrowed
     where it's passed, so neither another value given a handler, nor
     another use of one, nor another call costs more for each such value
     already made. The bound is far from what each takes, as in
     test_infer.ml's "a group of many calls checks in time linear in
     them" *)
  let lines n f = String.concat "\n" (List.init n (fun i -> f (i + 1))) in
  let timed what body =
    let src =
      String.concat "\n"
        [
          rates;
          "fn run(r: Rates) -> Int = with r in Rates.usd_to(1)";
          "fn id(x) = x";
          "fn f(i: Int) -> Int ! Bad = if i > 0 then i else fail Bad";
          "fn main() uses Console =";
          body;
        ]
    in
    let start = Sys.time () in
    ignore (Ren.Driver.check ~file src);
    let took = Sys.time () -. start in
    Printf.printf "%s: %s\n" what
      (if took < 10. then "in time" else Printf.sprintf "%.1fs" took)
  in
  timed "a value each"
    (lines 6_000 (fun _ -> "  print(run(id(counting_rates(2))))"));
  timed "one value, used again and again"
    ("  let h = id(counting_rates(3))\n"
    ^ lines 16_000 (fun _ -> "  print(run(h))"));
  timed "values, then other calls"
    (lines 8_000 (fun i ->
         Printf.sprintf "  let o%d = Some(counting_rates(%d))" i i)
    ^ "\n"
    ^ lines 8_000 (Printf.sprintf "  print(try f(%d))"));
  [%expect
    {|
    a value each: in time
    one value, used again and again: in time
    values, then other calls: in time
    |}]

let%expect_test "an operation read from a value holding a handler of several" =
  (* only `Rates` has `usd_to`, so that's the one it's looked up in, and
     `h.usd_to(1)` is a call of it as a method, installing `h` for the
     call (compiler.md, "Descriptions (step 3)") *)
  run
    (rates
   ^ {|
handler fixed_rates(rate: Int) for Rates, RateCalls =
  usd_to(_) => rate
  count() => 0

fn id(x) = x

fn main() uses Console =
  let h = id(fixed_rates(3))
  print(h.usd_to(1))
|}
    );
  [%expect
    {|
    3
    ()
    |}]

let%expect_test "an operation of a handler of several that keeps state isn't called as a method" =
  (* `counting_rates` counts its calls, so a call as a method, which would
     start it fresh, is refused (compiler.md, "Data stage",
     "Descriptions (step 6)"), the help naming the dependency the
     operation was found in *)
  run
    (rates
   ^ {|
fn id(x) = x

fn main() uses Console =
  let h = id(counting_rates(3))
  print(h.usd_to(1))
|}
    );
  [%expect
    {|
    error: `h` may be a description of `counting_rates`, which keeps state, so it isn't called as a method
       ┌─ test.ren:20:11
    20 │   print(h.usd_to(1))
       │           ^^^^^^
       = a call as a method makes a fresh instance, so its state would start again at each call
       help: install it: `with h in Rates.usd_to(1)`
    |}]

let%expect_test "a handler of several, then said to be something else" =
  (* what the handler is given to is decided after it, so it's what says
     so after that's blamed, as the constraint met second always is: not
     the handler, with a message about what isn't there. And there's one
     error, whichever comes first, the mistake or a use as one of its
     dependencies *)
  let fns =
    {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn id(x) = x
|}
  in
  check_error
    (rates ^ fns
   ^ {|
fn main() uses Console =
  let b = if true then counting_rates(3) else counting_rates(4)
  print(b + 1)
|}
    );
  [%expect
    {|
    error: `RateCalls & Rates` has no `+`
       ┌─ test.ren:22:9
    22 │   print(b + 1)
       │         ^^^^^
    |}];
  check_error
    (rates ^ fns
   ^ {|
fn main() uses Console =
  let o = [counting_rates(3)]
  let n: Array<Int> = o
  ()
|}
    );
  [%expect
    {|
    error: expected `Array<Int>`, found `Array<RateCalls & Rates>`
       ┌─ test.ren:22:23
    22 │   let n: Array<Int> = o
       │                       ^
    |}];
  check_error
    (rates ^ fns
   ^ {|
fn main() uses Console =
  let o = Some(counting_rates(3))
  let n: Option<Int> = o
  ()
|}
    );
  [%expect
    {|
    error: expected `Option<Int>`, found `Option<RateCalls & Rates>`
       ┌─ test.ren:22:24
    22 │   let n: Option<Int> = o
       │                        ^
    |}];
  check_error
    (rates ^ fns
   ^ {|
fn main() uses Console =
  let h = id(counting_rates(3))
  print(run(h))
  let n: Int = h
  ()
|}
    );
  [%expect
    {|
    error: expected `Int`, found `RateCalls & Rates`
       ┌─ test.ren:23:16
    23 │   let n: Int = h
       │                ^
    |}];
  check_error
    (rates ^ fns
   ^ {|
fn main() uses Console =
  let h = id(counting_rates(3))
  let n: Int = h
  print(run(h))
|}
    );
  [%expect
    {|
    error: expected `Int`, found `RateCalls & Rates`
       ┌─ test.ren:22:16
    22 │   let n: Int = h
       │                ^
    |}]

let%expect_test "a block called inside a `with` and outside it (B4)" =
  (* [run] installs `Rates` around its call of [k], and [twice] calls [k]
     itself too, outside any `with`. [k]'s type lists nothing, so neither
     gives it anything: its `Rates` is the one where it's written, `main`'s
     `times(3)`, both times, 3 + 3. (Before stage 10c a closure got its
     caller's evidence, so [run]'s `times(2)` reached it, and this tested
     how two rows ending in the same variable were joined.) *)
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

handler times(n: Int) for Rates =
  usd_to(c) => c * n

fn run(k) =
  with times(2) in k()

fn twice(k) =
  let a = run(k)
  a + k()

fn main() uses Console =
  with times(3) in
    print(twice(fn() => Rates.usd_to(1)))
|}
  in
  types src;
  run src;
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    handler times(n: Int) for Rates
    fn run<T>(k: fn() -> T) -> T
    fn twice<T has add>(k: fn() -> T) -> T
    fn main() uses Console
    6
    ()
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
    Clock.instant() >= a

fn main() uses Console =
  print(clock_conforms(Clock.frozen(Time.epoch)))
  print(clock_conforms(fakes.manual_clock(Time.epoch)))
  print(clock_conforms(fakes.stopped()))
  with fakes.manual_clock(Time.epoch) in
    fakes.ManualClock.advance(Duration.minutes(1))
    print(Clock.now() == Time.epoch + Duration.minutes(1))
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
    now = now + d
    at = at + d
  advance(d) =>
    now = now + d
    at = at + d

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
  (* an arm's result is checked against its operation's; a
     `with` that can't tell what it installs doesn't pass on what its body
     uses, which would be reported again at the call *)
  types
    {|
dep N =
  next: fn() -> Int

handler wrong() for N =
  next() => true

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

    error: `with` can't tell what `r` installs
      ┌─ test.ren:7:25
    7 │ fn run(r) -> Int = with r in N.next()
      │                         ^ its type isn't written
      help: write it: `fn run(r: N)`
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
  (* a parameter of a dependency's type is a description, which is data:
     installed in an arm, it needs what the handler needs *)
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
    dep N
      get: fn() -> Int
    dep M
      m: fn() -> Int
    handler keeps(n: N) for M
    fn main() -> Int
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
  (* a handler's type parameters are its dependencies' *)
  types
    {|
dep N =
  get: fn() -> Int

handler poly<T>(x: T) for N =
  get() => 1
|};
  [%expect
    {|
    error: `T` isn't a type parameter of `N`
      ┌─ test.ren:4:14
    4 │ handler poly<T>(x: T) for N =
      │              ^
      help: a handler's type parameters are its dependencies': remove `<T>`
    |}]

let%expect_test "the prelude's test implementations, installed by hand" =
  run
    {|
fn main() uses Console =
  with test_clock(Time.epoch) in
    TestClock.advance(Duration.minutes(5))
    Clock.sleep(Duration.seconds(1))
    print(Clock.now() == Time.epoch + Duration.ms(301000))
    print(Clock.instant() - Instant.zero == Duration.ms(301000))
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
fn main() ! FsError | InvalidUtf8(at: Int, incomplete: Bool) uses Console =
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
pub fn build() -> Int ! ProcError uses Proc =
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
  [%expect
    {|
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
  [%expect
    {|
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
pub type Money = opaque Int
  pub fn dollars(n: Int) -> Money = n * 100
  pub fn minus(self, m: Money) -> Money = self - m

pub type Account = { id: Int, balance: Money, at: Time }

// public, so a test can call it
pub fn pay(a: Account, m: Money) -> Account uses Clock =
  Account { id: a.id, balance: a.balance.minus(m), at: Clock.now() }

pub fn main() uses Clock, Console =
  print("paying")
  let a = pay(Account { id: 1, balance: Money.dollars(1), at: Time.epoch }, Money.dollars(1))
  print(a.balance == Money.dollars(0))

test "paying takes the money" =
  let a = Account { id: 1, balance: Money.dollars(1), at: Time.epoch }
  TestClock.advance(Duration.minutes(5))
  let paid = pay(a, Money.dollars(1))
  assert paid == Account { id: 1, balance: Money.dollars(0), at: Time.epoch + Duration.minutes(5) }

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
pub fn roll() -> Int uses Random = Random.int(6) + 1

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
  assert Clock.now() > Time.epoch

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
  assert Clock.now() > Time.epoch

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
pub fn save(name: Str, text: Str) ! FsError uses Fs =
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
  [%expect
    {|
    test.ren
      ✓ the real file system

    1 passed
    [exit 0]
    |}]

let%expect_test "a test that fails with an error, or panics" =
  test
    {|
pub fn half(n: Int) -> Int ! Odd(Int) =
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
pub fn may(n: Int) -> Int ! Boom = if n > 0 then fail Boom else n

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
pub fn again(n: Int, body: fn() ! Boom) ! Boom =
  match attempt body()
    Ok(_) => ()
    Err(_) =>
      if n <= 1 then try body() else try again(n - 1, body)

pub group wrapped() =
  test "always fails" =
    try again(5) fn() => fail Boom
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
pub type P = {name: Str, n: Int}

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
    assert Clock.instant() >= a
  test "sleeping moves it on" =
    let t = Clock.now()
    Clock.sleep(Duration.ms(5))
    assert Clock.now() > t
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
    8 │     assert Clock.now() > t
      │            ^^^^^^^^^^^^^^^
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
    assert Clock.now() == Time.epoch + Duration.minutes(1)
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
    error: `Priv` is private, and a test sees what an importer sees
      ┌─ test.ren:3:20
    3 │ pub group leaky(p: Priv, ps: Array<Priv>) =
      │                    ^^^^
      = a test is a specification of `test`'s interface
      help: mark it `pub`, or explore it in the console: `ren console test`

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
pub fn compute() -> Int = 3

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
pub type Shape = Dot | Box { w: Int, h: Int }
pub type P = { name: Str, at: Int, shapes: Array<Shape> }

test "a payload" =
  assert P { name: "a", at: 1, shapes: [Dot, Box { w: 1, h: 2 }] } == P { name: "a", at: 1, shapes: [Dot, Box { w: 1, h: 3 }] }

test "two constructors" =
  assert [Dot, Dot, Dot] == [Dot, Box { w: 1, h: 1 }, Dot]

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
  [%expect
    {|
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
    5 │   assert P { name: "a", at: 1, shapes: [Dot, Box { w: 1, h: 2 }] } == P { name: "a", at: 1, shapes: [Dot, Box { w: 1, h: 3 }] }
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  P { ..., shapes: [..., Box { ..., h: 2 }] }
      right: P { ..., shapes: [..., Box { ..., h: 3 }] }
                                                  ^ differs here

      seed 4626 · rerun: ren test test.ren --only "a payload" --seed 4626

    ──── two constructors ── test.ren:8
      │
    8 │   assert [Dot, Dot, Dot] == [Dot, Box { w: 1, h: 1 }, Dot]
      │          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
      │
      left:  [..., Dot, ...]
      right: [..., Box { w: 1, h: 1 }, ...]
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

let%expect_test "print shows a value through its type, as a failed assert does"
    =
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
  pub fn show(self) -> Str = show(self) + "c"
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
  print(show(M.of(3)).byte_len())
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
  pub fn show(self) -> Str = show(self) + "c"

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
handler timed() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
handler fixed() for Rates =
  usd_to(c) => c
pub fn stored() -> Rates uses Clock = timed()
fn convert() = with timed() in Rates.usd_to(1)
pub fn public() -> Int = with timed() in Rates.usd_to(1)
fn main() = 1
|};
  [%expect
    {|
    error: expected `Rates`, found `Rates uses Clock`
      ┌─ test.ren:7:39
    7 │ pub fn stored() -> Rates uses Clock = timed()
      │                                       ^^^^^^^
      = `stored` is declared to return `Rates`
      = a stored description's `uses` is the most it may need, and this one needs `Clock` too
      help: add it where the type is written: `(Rates uses Clock)`

    error: `public` doesn't declare `Clock`
      ┌─ test.ren:9:8
    9 │ pub fn public() -> Int = with timed() in Rates.usd_to(1)
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
pub fn timed() -> (Rates uses Clock) = timed_rates()
pub fn convert(r: Rates uses Clock) -> Int uses Clock = 1
fn main() = 1

handler timed_rates() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
|};
  [%expect
    {|
    pub dep Rates
      usd_to: fn(Int) -> Int
    pub fn timed() -> (Rates uses Clock)
    pub fn convert(r: Rates uses Clock) -> Int uses Clock
    fn main() -> Int
    handler timed_rates() for Rates uses Clock
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
handler timed() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
fn boxed() -> Box<Rates> = Box { it: timed() }
fn main() = 1
|};
  [%expect
    {|
    error: expected `Box<Rates>`, found `Box<Rates uses Clock>`
      ┌─ test.ren:6:28
    6 │ fn boxed() -> Box<Rates> = Box { it: timed() }
      │                            ^^^^^^^^^^^^^^^^^^^
      = `boxed` is declared to return `Box<Rates>`
      = a stored description's `uses` is the most it may need, and this one needs `Clock` too
      help: add it where the type is written: `Box<Rates uses Clock>`
    |}]

let%expect_test "an implementation's needs are fixed where it's installed" =
  run
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
fn at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
handler timed() for Rates =
  usd_to(c) => if Clock.now() > Time.epoch then c else 0
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
handler live() for Rates =
  usd_to(c) => try Http.get_rate(c)
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:6:16
    6 │   usd_to(c) => try Http.get_rate(c)
      │                ^^^^^^^^^^^^^^^^^^^^ fails with `Timeout`
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
handler live() for Rates =
  usd_to(c) => try Http.get_rate(c)
handler plain() for Plain =
  get() => try Http.get_rate(1)
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Gone` and `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:8:16
    8 │   usd_to(c) => try Http.get_rate(c)
      │                ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
      = `Rates.usd_to` can fail only with `RateUnavailable`
      help: map what it fails with inside it, with `match` and `fail` arms, to what it can: `fail RateUnavailable`

    error: this implementation can fail with `Gone` and `Timeout`, and `Plain.get` can't
       ┌─ test.ren:10:12
    10 │   get() => try Http.get_rate(1)
       │            ^^^^^^^^^^^^^^^^^^^^ fails with `Gone` and `Timeout`
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
handler live() for Rates =
  usd_to(c) => try get(c)
fn main() = 1
|};
  [%expect
    {|
    error: this implementation can fail with `Timeout`, and `Rates.usd_to` can't
      ┌─ test.ren:5:16
    5 │   usd_to(c) => try get(c)
      │                ^^^^^^^^^^ fails with `Timeout`
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
handler http(up: Bool) for Http =
  get_rate(c) => if up then c * 2 else fail Timeout
fn ask(c: Int) =
  match Http.get_rate(c)
    fail Timeout => fail RateUnavailable
    r => r
handler live() for Rates =
  usd_to(c) => try ask(c)
handler fixed() for Rates =
  usd_to(_) => 3
fn main() uses Console =
  print(with http(true), live() in attempt Rates.usd_to(5))
  print(with http(false), live() in attempt Rates.usd_to(5))
  print(with fixed() in attempt Rates.usd_to(5))
|};
  [%expect {|
    Ok(10)
    Err(RateUnavailable)
    Ok(3)
    ()
    |}]

let%expect_test "what a handler needs is fixed where it's installed" =
  (* its state is made, and its operations run, with what's installed
     outside it: the inner `Base` doesn't change them *)
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

handler base(k: Int) for Base =
  n() => k

fn main() uses Console =
  with base(1), offset() in with base(2) in
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
    handler base(k: Int) for Base
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

handler direct(k: Int) for N =
  get() => if k == 1 then fail High else k

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
       ┌─ test.ren:17:27
    17 │   get() => if k == 1 then fail High else k
       │                           ^^^^^^^^^ fails with `High`
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
      = a handler's operations run with what's installed outside its `with`, so `N` here would be the one under it
      help: declare it `over N`, and call the one under it through `next`

    error: a handler for `N` can't use `N`
       ┌─ test.ren:10:13
     9 │ handler direct() for N uses Console =
       │         ------ `direct` implements `N`
    10 │   next() => N.next()
       │             ^^^^^^^^ this call uses `N`
       = a handler's operations run with what's installed outside its `with`, so `N` here would be the one under it
       help: declare it `over N`, and call the one under it through `next`

    error: a handler for `N` can't use `N`
       ┌─ test.ren:12:9
    12 │ handler declared() for N uses N =
       │         ^^^^^^^^
       = a handler's operations run with what's installed outside its `with`, so `N` here would be the one under it
       help: remove `N` from its `uses`
    |}]

let%expect_test "an implementation fails as its operation declares" =
  types
    {|
dep N =
  get: fn() -> Int ! Low(Int)

handler shape() for N =
  get() => fail Low

fn main() = 1
|};
  [%expect
    {|
    error: this implementation fails with a different `Low`
      ┌─ test.ren:5:12
    5 │   get() => fail Low
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
  print(t > Time.epoch)
  print(double(2))
|};
  [%expect
    {|
    (fn stamp () ev/1 (dep-call ev/1 Clock.now))
    (fn double (n/1) ev/2 (* n/1 2))
    (fn main () ev/1
      (let t/2 (call ev/1 stamp)
        (seq (call ev/1 print (> t/2 Time.epoch))
          (call ev/1 print (call ev/1 double 2)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real)
        (with ev/3 (extend ev/2 Console Console.real) (call ev/3 main))))
    |}]

let%expect_test "a block captures the evidence where it's written" =
  core
    {|
fn run(f: fn() -> Time) -> Time = try f()
fn main() uses Clock =
  let f = fn() => Clock.now()
  run(f)
|};
  [%expect
    {|
    (fn run (f/1) ev/2 (call ev/2 f/1))
    (fn main () ev/1
      (let f/2
        (lambda () (captures ev/1) ev/3 (extend ev/1) (dep-call ev/3 Clock.now))
        (call ev/1 run f/2)))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Clock Clock.real) (call ev/2 main)))
    |}]

(* There are no copies of a function for what its callers' blocks use:
   each block captures the evidence where it's written, and `twice` gives
   `f` nothing, since its type lists nothing. *)
let%expect_test "a function over blocks gives them only what their types list" =
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
    (fn quiet () ev/1
      (call ev/1 twice (lambda () (captures ev/1) ev/2 (extend ev/1) ())))
    (fn main () ev/1
      (seq
        (call ev/1 twice
          (lambda () (captures ev/1) ev/2 (extend ev/1) (call ev/2 print 1)))
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
      (call ev/1 twice
        (lambda () (captures ev/1) ev/2 (extend ev/1) (call ev/2 print 1))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run_files files;
  [%expect {|
    1
    1
    ()
    |}]

let%expect_test
    "a function or an operation used as a value is a block written there" =
  let src =
    {|
fn one() = 1
fn apply(f: fn() -> Int) -> Int = try f()
fn say(f: fn(Str), s: Str) = try f(s)
fn main() uses Console =
  print(apply(one))
  say(Console.write, "written")
|}
  in
  core src;
  [%expect
    {|
    (fn one () ev/1 1)
    (fn apply (f/1) ev/2 (call ev/2 f/1))
    (fn say (f/1 s/2) ev/3 (call ev/3 f/1 s/2))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (call ev/1 apply
            (lambda () (captures ev/1) ev/2 (extend ev/1) (call ev/2 one))))
        (call ev/1 say
          (lambda ($x/3) (captures ev/1) ev/4 (extend ev/1)
            (dep-call ev/4 Console.write $x/3))
          "written")))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    1
    written
    ()
    |}]

(* What the first try at threading evidence, which passed one parameter
   per dependency and made copies of functions for them, got wrong. Each
   runs now. *)

let%expect_test "pure lambdas run where more is used" =
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

let%expect_test "a block over another module's dependency runs" =
  (* lib doesn't import main, where Users is declared: the block captures
     the evidence where it's written, in `look`, whatever is in it *)
  let files =
    [
      ( "main.ren",
        {|
import lib
dep Users =
  get: fn(id: Int) -> Int
handler users() for Users =
  get(id) => id * 10
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
    (fn users () ev/1
      (handler (captures) ev/2
        (instance
          (main.Users:
            (record
              (get:
                (lambda (id/3) (captures ev/2) ev/4 (extend ev/2) (* id/3 10))))))))
    (fn look () ev/1
      (call ev/1 twice
        (lambda () (captures ev/1) ev/2 (extend ev/1)
          (dep-call ev/2 main.Users.get 1))))
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

(* The block is written where one clock is installed, and called where
   another is: it uses the one where it's written. *)
let%expect_test "a block uses the implementation installed where it's written" =
  let src =
    {|
fn frozen_at(minutes: Int) -> Clock =
  Clock.frozen(Time.epoch + Duration.minutes(minutes))
fn later(f: fn() -> Time) -> Time = with frozen_at(5) in try f()
fn main() uses Console =
  with frozen_at(0) in
    print(later(fn() => Clock.now()))
|}
  in
  core src;
  [%expect
    {|
    (fn frozen_at (minutes/1) ev/2
      (call ev/2 Clock.frozen
        (call ev/2 Time.add Time.epoch (call ev/2 Duration.minutes minutes/1))))
    (fn later (f/1) ev/2
      (with ev/3 (extend ev/2 Clock (call ev/2 frozen_at 5)) (call ev/3 f/1)))
    (fn main () ev/1
      (with ev/2 (extend ev/1 Clock (call ev/1 frozen_at 0))
        (call ev/2 print
          (call ev/2 later
            (lambda () (captures ev/2) ev/3 (extend ev/2)
              (dep-call ev/3 Clock.now))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  run src;
  [%expect {|
    Time(0)
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
     block's in its own, the evidence where it's written, with what its
     caller gives it or not *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call (lambda 2 (op 2)) 1);
  [%expect {||}];
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call
        (lambda ~uses:uses_d
           ~given:[ { kpath = Ren.Path.make "test" "D"; kargs = [] } ]
           2 (op 2))
        1);
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
      call (lambda 2 (Ren.Core.mk (Int 1L) Ren.Ty.int loc)) 2);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a call is given `ev` (2), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a block whose body uses the evidence where it's written, not its own *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d ->
      call (lambda ~uses:uses_d 2 (op 1)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `D.op` is given `ev` (1), but the evidence in scope is `ev` (2)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a block given a dependency its type doesn't list *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call
        (lambda
           ~given:[ { kpath = Ren.Path.make "test" "D"; kargs = [] } ]
           2 (op 2))
        1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a block is given `test.D`, which its type doesn't list")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a block that says it's written where other evidence is in scope *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call (lambda ~outer:3 2 (op 2)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a block is given `ev` (3), but the evidence in scope is `ev` (1)")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a block that doesn't capture the evidence where it's written *)
  lint_evidence (fun ~loc:_ ~op ~lambda ~call ~uses_d:_ ->
      call (lambda ~captures:[] 2 (op 2)) 1);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: a block doesn't capture the evidence where it's written")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* evidence an inner `With` extends *)
  lint_evidence (fun ~loc ~op ~lambda ~call:_ ~uses_d:_ ->
      let d = Ren.Path.make "test" "D" in
      (* a handler, with no state, whose instance is a record of its
         one operation *)
      let ty = Ren.Ty.impl [ Ren.Ty.plain d ] Ren.Ty.closed in
      let record =
        Ren.Core.mk
          (Record
             ( d,
               [
                 ("op", lambda ~outer:4 3 (Ren.Core.mk (Int 1L) Ren.Ty.int loc));
               ] ))
          ty loc
      in
      let instance =
        Ren.Core.mk
          (Instance { impls = [ (d, record) ]; finally = None; exclusive = false })
          ty loc
      in
      let impl =
        Ren.Core.mk
          (Handler { ev = Ren.Core.evidence 4; captures = []; body = instance })
          ty loc
      in
      Ren.Core.mk
        (With
           {
             ev = Ren.Core.evidence 2;
             outer = Ren.Core.evidence 1;
             dep = d;
             dargs = [];
             from = d;
             impl;
             desc = Known Ren.Ty.int;
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
                    (lambda (_/6) (captures rate/1 ev/3 $calls/5) ev/7
                      (extend ev/3)
                      (let calls/4 (get-cell $calls/5)
                        (let $result/8 (seq (= calls/4 (+ calls/4 1)) rate/1)
                          (seq (set-cell $calls/5 calls/4) $result/8)))))))
              (test.RateCalls:
                (record
                  (count:
                    (lambda () (captures ev/3 $calls/5) ev/9 (extend ev/3)
                      (let calls/4 (get-cell $calls/5) calls/4))))))))))
    (fn convert (n/1) ev/2 (* n/1 (dep-call ev/2 test.Rates.usd_to 1)))
    (fn main () ev/1
      (with ev/2
        (extend ev/1 (test.RateCalls test.Rates) (call ev/1 counting_rates 3))
        (call ev/2 print (call ev/2 convert 2))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}]

(* ---- A handler of several dependencies has a type that lists them ----

   deps.md, "Implementations": its type is `Rates & RateCalls`, fixed
   where it's made; a written type that asks for some of them narrows it
   to those, and nothing else does; `with` installs what its type says. *)

let%expect_test "a handler of several, installed where it's made" =
  run
    (rates
   ^ {|
fn main() uses Console =
  with counting_rates(2) in print(Rates.usd_to(1) + RateCalls.count())
|}
    );
  [%expect {|
    3
    ()
    |}];
  test
    {|
test "the test clock moves on" =
  let c = test_clock(Time.epoch)
  with c in
    TestClock.advance(Duration.ms(3))
    assert Clock.now() == Time.epoch + Duration.ms(3)
|};
  [%expect
    {|
    test.ren
      ✓ the test clock moves on

    1 passed
    [exit 0]
    |}]

let%expect_test "a handler of several passed to a written parameter" =
  (* `run`'s `r` is a `Rates`, so `with r` installs only that *)
  run
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console = print(run(counting_rates(3)))
|}
    );
  [%expect {|
    3
    ()
    |}];
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1) + RateCalls.count()

fn main() uses Console = print(run(counting_rates(3)))
|}
    );
  [%expect
    {|
    error: nothing installs `RateCalls` before `main`
       ┌─ test.ren:18:4
    18 │ fn main() uses Console = print(run(counting_rates(3)))
       │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
       │                                ---------------------- this call uses `RateCalls`
       help: install one inside `main`: `with counting_rates(...) in ...`
    |}]

let%expect_test "a handler of several in a `let`, then passed" =
  run
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let h = counting_rates(4)
  print(run(h))
  with h in print(RateCalls.count())
|}
    );
  [%expect {|
    4
    0
    ()
    |}]

let%expect_test "a handler of several as a written result" =
  let src =
    {|
pub dep Rates =
  usd_to: fn(c: Int) -> Int

pub dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls

fn one() -> Rates = counting_rates(5)

fn both() -> RateCalls & Rates = counting_rates(6)

pub fn joined() -> Rates & RateCalls = counting_rates(7)

fn main() uses Console =
  with one() in print(Rates.usd_to(1))
  with both() in print(Rates.usd_to(1) + RateCalls.count())
  with joined() in print(Rates.usd_to(1) + RateCalls.count())
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
    fn one() -> Rates
    fn both() -> RateCalls & Rates
    pub fn joined() -> RateCalls & Rates
    fn main() uses Console
    |}];
  run src;
  [%expect {|
    5
    7
    8
    ()
    |}]

let%expect_test "a record field's declared type narrows it" =
  check_error
    {|
type Box = { c: Clock }

fn main() =
  let b = Box { c: test_clock(Time.epoch) }
  with b.c in
    TestClock.advance(Duration.ms(3))
|};
  [%expect
    {|
    error: nothing installs `TestClock` before `main`
      ┌─ test.ren:3:4
    3 │ fn main() =
      │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
    6 │     TestClock.advance(Duration.ms(3))
      │     --------------------------------- this call uses `TestClock`
      help: install one inside `main`, with `with`: `with h() in ...`, for a handler `h` for `TestClock`
    |}]

let%expect_test "an array's items that are different implementations" =
  check_error
    (rates
   ^ {|
fn main() =
  let bs = [same(), counting_rates(1)]
  ()

handler same() for Rates =
  usd_to(c) => c
|}
    );
  [%expect
    {|
    error: the items in this list have different types
       ┌─ test.ren:17:21
    17 │   let bs = [same(), counting_rates(1)]
       │                     ^^^^^^^^^^^^^^^^^ is `RateCalls & Rates`
       │             ------ is `Rates`
       help: say what the list holds: `let bs: Array<Rates> = ...`
    |}];
  run
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  let bs: Array<Rates> = [same(), counting_rates(1)]
  print(run(bs[0]) + run(bs[1]))

handler same() for Rates =
  usd_to(c) => c
|}
    );
  [%expect {|
    2
    ()
    |}]

let%expect_test "never narrowed through a generic function's type variable" =
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn apply(f, a) = f(a)

fn apply2(a, f) = f(a)

fn main() uses Console =
  print(apply(run, counting_rates(1)))
  print(apply2(counting_rates(1), run))
|}
    );
  [%expect
    {|
    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:23:20
    23 │   print(apply(run, counting_rates(1)))
       │                    ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: expected `fn(RateCalls & Rates) -> _`, found `fn(Rates) -> Int`
       ┌─ test.ren:24:35
    24 │   print(apply2(counting_rates(1), run))
       │                                   ^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`
    |}]

let%expect_test "a `with` of what has no written type" =
  check_error {|
fn run(c) = with c in Clock.now()

fn main() = ()
|};
  [%expect
    {|
    error: `with` can't tell what `c` installs
      ┌─ test.ren:1:18
    1 │ fn run(c) = with c in Clock.now()
      │                  ^ its type isn't written
      help: write it: `fn run(c: Clock)`
    |}];
  check_error
    {|
fn make(g) =
  let c = g()
  with c in Clock.now()

fn main() = ()
|};
  [%expect
    {|
    error: `with` can't tell what `c` installs
      ┌─ test.ren:3:8
    3 │   with c in Clock.now()
      │        ^ its type isn't written
      help: write it: `let c: Clock = ...`
    |}];
  check_error {|
fn main() =
  let f = fn(c) => with c in Clock.now()
  ()
|};
  [%expect
    {|
    error: `with` can't tell what `c` installs
      ┌─ test.ren:2:25
    2 │   let f = fn(c) => with c in Clock.now()
      │                         ^ its type isn't written
      help: write it: `fn(c: Clock) => ...`
    |}]

let%expect_test "a method of one of its dependencies" =
  (* only `Rates` has `twice`, so it's that one's, and the receiver is
     narrowed to a `Rates` there *)
  let src =
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int

  fn twice(self, c: Int) -> Int = (with self in Rates.usd_to(c)) * 2

dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn main() uses Console =
  let h = counting_rates(2)
  print(h.twice(5))
|}
  in
  run src;
  [%expect {|
    20
    ()
    |}];
  core src;
  [%expect
    {|
    (fn Rates.twice (self/1 c/2) ev/3
      (*
        (with ev/4 (extend ev/3 test.Rates self/1)
          (dep-call ev/4 test.Rates.usd_to c/2))
        2))
    (fn counting_rates (rate/1) ev/2
      (handler (captures rate/1) ev/3
        (instance
          (test.Rates:
            (record
              (usd_to:
                (lambda (c/4) (captures rate/1 ev/3) ev/5 (extend ev/3)
                  (* c/4 rate/1)))))
          (test.RateCalls:
            (record (count: (lambda () (captures ev/3) ev/6 (extend ev/3) 0)))))))
    (fn main () ev/1
      (let h/2 (call ev/1 counting_rates 2)
        (call ev/1 print (call ev/1 Rates.twice (narrowed test.Rates h/2) 5))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}];
  check_error
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int

  fn describe(self) -> Str = "rates"

dep RateCalls =
  count: fn() -> Int

  fn describe(self) -> Str = "calls"

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(c) => c * rate
  count() => 0

fn main() uses Console =
  let h = counting_rates(2)
  print(h.describe())
|};
  [%expect
    {|
    error: `describe` is a member of both `RateCalls` and `Rates`
       ┌─ test.ren:17:11
    17 │   print(h.describe())
       │           ^^^^^^^^
       = a `RateCalls & Rates` is an implementation of `RateCalls` and `Rates`, and each of them has `describe`
       help: say which it is where it's made or passed: `let r: RateCalls = h`
    |}];
  check_error
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int

  fn reset(inout self) = self = zero()

dep RateCalls =
  count: fn() -> Int

handler counting_rates(rate: Int) for Rates, RateCalls =
  usd_to(_) => rate
  count() => 7

fn main() uses Console =
  var h = counting_rates(2)
  &h.reset()
  with h in print(RateCalls.count())

handler zero() for Rates =
  usd_to(_) => 0
|};
  [%expect
    {|
    error: `reset` can't change `h`, which implements more than `Rates`
       ┌─ test.ren:15:6
    15 │   &h.reset()
       │      ^^^^^
       = `reset` changes a `Rates`, and `h` is a `RateCalls & Rates`
       help: change a `Rates` of its own: `var r: Rates = h`
    |}];
  check_error
    (rates
   ^ {|
fn main() uses Console =
  let h = counting_rates(2)
  print(h.nothing())
|}
    );
  [%expect
    {|
    error: `.nothing` needs a record, but this is a `RateCalls & Rates`
       ┌─ test.ren:18:11
    18 │   print(h.nothing())
       │           ^^^^^^^
    |}]

let%expect_test "a test clock and a clock passed to a generic function" =
  (* [same]'s `T` isn't written, so whichever comes first, the two are
     different types *)
  check_error
    {|
fn same<T>(a: T, b: T) -> T = if true then a else b

fn f(c: Clock) =
  let x = same(test_clock(Time.epoch), c)
  let y = same(c, test_clock(Time.epoch))
  ()

fn main() = ()
|};
  [%expect
    {|
    error: expected `Clock & TestClock`, found `Clock`
      ┌─ test.ren:4:40
    4 │   let x = same(test_clock(Time.epoch), c)
      │                                        ^
      = `Clock & TestClock` is a `Clock` only where a written type asks for one
      help: write it where it's made or passed, `let x: Clock = ...` or `fn f(x: Clock)`

    error: expected `Clock`, found `Clock & TestClock`
      ┌─ test.ren:5:19
    5 │   let y = same(c, test_clock(Time.epoch))
      │                   ^^^^^^^^^^^^^^^^^^^^^^
      = `Clock & TestClock` is a `Clock` only where a written type asks for one
      help: write it where it's made or passed, `let x: Clock = ...` or `fn f(x: Clock)`
    |}]

let%expect_test "`with` installs what the value's type says" =
  run
    (rates
   ^ {|
dep Extra =
  more: fn() -> Int

handler three(rate: Int) for Rates, RateCalls, Extra =
  var calls = 0
  usd_to(_) =>
    calls += 1
    rate
  count() => calls
  more() => 100

fn both(h: Rates & RateCalls) -> Int =
  with h in Rates.usd_to(1) + RateCalls.count()

fn main() uses Console =
  print(both(counting_rates(2)))
  print(both(three(3)))
|}
    );
  [%expect {|
    3
    4
    ()
    |}];
  check_error
    (rates
   ^ {|
dep Extra =
  more: fn() -> Int

handler three(rate: Int) for Rates, RateCalls, Extra =
  usd_to(_) => rate
  count() => 0
  more() => 100

fn both(h: Rates & RateCalls) -> Int =
  with h in Extra.more()

fn main() uses Console = print(both(three(3)))
|}
    );
  [%expect
    {|
    error: nothing installs `Extra` before `main`
       ┌─ test.ren:27:4
    27 │ fn main() uses Console = print(both(three(3)))
       │    ^^^^ the runtime installs only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc`, `Net` and `Async`
       │                                -------------- this call uses `Extra`
       help: install one inside `main`: `with three(...) in ...`
    |}]

let%expect_test "the same type in either order" =
  run
    (rates
   ^ {|
fn g(y: RateCalls & Rates) -> Int = with y in RateCalls.count()

fn f(x: Rates & RateCalls) -> Int = g(x)

fn main() uses Console = print(f(counting_rates(2)))
|}
    );
  [%expect {|
    0
    ()
    |}]

let%expect_test "only dependencies are joined with `&`" =
  check_error {|
fn f(c: Clock & Int) = ()

fn main() = ()
|};
  [%expect
    {|
    error: only a dependency's type can be joined with `&`
      ┌─ test.ren:1:17
    1 │ fn f(c: Clock & Int) = ()
      │                 ^^^
      help: `Int` isn't one: an implementation of several dependencies is the one value of this type
    |}];
  check_error {|
fn f(c: Clock & Clock) = ()

fn main() = ()
|};
  [%expect
    {|
    error: `Clock` is joined with `&` twice
      ┌─ test.ren:1:17
    1 │ fn f(c: Clock & Clock) = ()
      │                 ^^^^^
      help: remove one
    |}];
  check_error
    {|
type Box<T> = { v: T }

fn f(c: Clock & Box<Int>) = ()

fn main() = ()
|};
  [%expect
    {|
    error: only a dependency's type can be joined with `&`
      ┌─ test.ren:3:17
    3 │ fn f(c: Clock & Box<Int>) = ()
      │                 ^^^
      help: `Box` isn't one: an implementation of several dependencies is the one value of this type
    |}];
  check_error {|
fn f() uses Clock & TestClock = ()

fn main() = ()
|};
  [%expect
    {|
    error: in a `uses` list, dependencies are separated by commas
      ┌─ test.ren:1:19
    1 │ fn f() uses Clock & TestClock = ()
      │                   ^
      help: write `Clock, ...`: a function uses each of them
    |}]

let%expect_test "types flow left to right" =
  (* a value's type is what inference knows of it where it's used: once
     a generic's `T` is a `RateCalls & Rates`, a lambda's parameter of
     that type is narrowed at `run`'s written `Rates`. The other way
     round, the parameter is already a `Rates` when the handler arrives,
     and `T` isn't written, so that's an error *)
  let prog body =
    rates
    ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn ap(x, f) = f(x)

fn ap2(f, x) = f(x)

fn apply<A, U>(a: A, f: fn(A) -> U) -> U = try f(a)

fn apply2<A, U>(f: fn(A) -> U, a: A) -> U = try f(a)

fn main() uses Console =
|}
    ^ body ^ "\n"
  in
  run
    (prog
       {|  print(ap(counting_rates(8), fn(r) => run(r)))
  print(apply(counting_rates(9), fn(r) => run(r)))|});
  [%expect {|
    8
    9
    ()
    |}];
  check_error
    (prog
       {|  print(ap2(fn(r) => run(r), counting_rates(8)))
  print(apply2(fn(r) => run(r), counting_rates(9)))|});
  [%expect
    {|
    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:27:30
    27 │   print(ap2(fn(r) => run(r), counting_rates(8)))
       │                              ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:28:33
    28 │   print(apply2(fn(r) => run(r), counting_rates(9)))
       │                                 ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`
    |}];
  (* an array made empty, or an `Option` made `None`: filled before the
     use, it's known there; filled after, it isn't yet *)
  run
    (prog
       {|  var xs = []
  &xs.push(counting_rates(1))
  print(run(xs[0]))
  var o = None
  o = Some(counting_rates(2))
  let f = fn() => match o
    Some(r) => run(r)
    None => 0
  print(f())|});
  [%expect {|
    1
    2
    ()
    |}];
  check_error
    (prog
       {|  var ys = []
  let f = fn() => run(ys[0])
  &ys.push(counting_rates(1))
  print(f())|});
  [%expect
    {|
    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:29:12
    29 │   &ys.push(counting_rates(1))
       │            ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`
    |}];
  (* handlers pushed onto an array made empty are installed from it,
     of one dependency or several, once that's known *)
  run
    (rates
   ^ {|
handler fixed(rate: Int) for Rates =
  usd_to(_) => rate

fn main() uses Console =
  var xs = []
  &xs.push(fixed(3))
  &xs.push(fixed(4))
  for c in xs
    with c in print(Rates.usd_to(1))
  var ys = []
  &ys.push(counting_rates(5))
  for c in ys
    with c in
      print(Rates.usd_to(1))
      print(RateCalls.count())
|}
    );
  [%expect {|
    3
    4
    5
    1
    ()
    |}];
  (* a parameter nothing wrote the type of is known once a call says
     what it is, so it can be installed after that, but not before *)
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn f(c) -> Int =
  let n = run(c)
  with c in n + Rates.usd_to(1)

fn g(c) -> Int =
  let n = with c in Rates.usd_to(1)
  n + run(c)

fn main() = ()
|}
    );
  [%expect
    {|
    error: `with` can't tell what `c` installs
       ┌─ test.ren:23:16
    23 │   let n = with c in Rates.usd_to(1)
       │                ^ its type isn't written
       help: write it: `fn g(c: Rates)`
    |}];
  (* with the types written, each order checks *)
  run
    (prog
       {|  let h: Rates = counting_rates(8)
  print(ap2(fn(r) => run(r), h))
  print(ap2(fn(r: RateCalls & Rates) => run(r), counting_rates(8)))
  var ys: Array<RateCalls & Rates> = []
  &ys.push(counting_rates(1))
  let f = fn() => run(ys[0])
  print(f())|});
  [%expect {|
    8
    8
    1
    ()
    |}]

let%expect_test "a narrowed handler's messages" =
  (* a written type inside a constructor's argument reaches an `if`'s
     branches there *)
  run
    (rates
   ^ {|
handler fixed(rate: Int) for Rates =
  usd_to(_) => rate

fn main() uses Console =
  let c = true
  let x: Option<Rates> = Some(if c then counting_rates(2) else fixed(1))
  match x
    Some(r) => print(with r in Rates.usd_to(1))
    None => ()
|}
    );
  [%expect {|
    2
    ()
    |}];
  (* fewer dependencies than a written type asks for: no written type can
     add any, so nothing says to write one *)
  check_error
    (rates
   ^ {|
handler fixed(rate: Int) for Rates =
  usd_to(_) => rate

fn run(r: Rates & RateCalls) -> Int = with r in Rates.usd_to(1)

fn main() uses Console =
  print(run(fixed(1)))
  let h: Rates & RateCalls & Console = counting_rates(3)
  ()
|}
    );
  [%expect
    {|
    error: expected `RateCalls & Rates`, found `Rates`
       ┌─ test.ren:22:13
    22 │   print(run(fixed(1)))
       │             ^^^^^^^^

    error: expected `Console & RateCalls & Rates`, found `RateCalls & Rates`
       ┌─ test.ren:23:40
    23 │   let h: Rates & RateCalls & Console = counting_rates(3)
       │                                        ^^^^^^^^^^^^^^^^^
    |}];
  (* in a group, a parameter that's narrowed once it's written *)
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn a(n: Int) -> Int = if n == 0 then b(counting_rates(1), n) else 0

fn b(r, n: Int) -> Int = if n == 0 then run(r) else a(n)

fn main() uses Console = print(a(0))
|}
    );
  [%expect
    {|
    error: `b` is used here as `fn(RateCalls & Rates, Int) -> Int`, but its definition makes it `fn(Rates, Int) -> Int`
       ┌─ test.ren:18:38
    18 │ fn a(n: Int) -> Int = if n == 0 then b(counting_rates(1), n) else 0
       │                                      ^
       = functions that call each other are checked at a single type
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write the type of `b`'s first parameter, `Rates`, which narrows it there
    |}];
  (* `with` of a value whose type isn't known: the help writes the
     dependencies the body uses that the runtime doesn't install, and for
     one bound by a pattern, where no type can be written, says where to *)
  check_error
    (rates
   ^ {|
fn run(c) uses Console = with c in print(Rates.usd_to(1))

fn main() uses Console =
  run(counting_rates(1))
  let x = None
  match x
    Some(h) => with h in print(RateCalls.count())
    None => ()
|}
    );
  [%expect
    {|
    error: `with` can't tell what `c` installs
       ┌─ test.ren:16:31
    16 │ fn run(c) uses Console = with c in print(Rates.usd_to(1))
       │                               ^ its type isn't written
       help: write it: `fn run(c: Rates)`

    error: `with` can't tell what `h` installs
       ┌─ test.ren:22:21
    22 │     Some(h) => with h in print(RateCalls.count())
       │                     ^ its type isn't written
       help: write the type of what it installs where that's made or passed in, as a `let`'s or a parameter's
    |}]

let%expect_test
    "a function whose parameter's type is inferred, reached another way" =
  (* `g`'s parameter is a `Rates` because of what `g` does with it, which
     isn't written, so a handler of several isn't narrowed to it however
     `g` is reached: called by name, or passed *)
  check_error
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

fn g(r) = run(r)

fn ap(f, x) = f(x)

fn main() uses Console =
  print(g(counting_rates(1)))
  print(ap(g, counting_rates(1)))
|}
    );
  [%expect
    {|
    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:23:11
    23 │   print(g(counting_rates(1)))
       │           ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`

    error: expected `Rates`, found `RateCalls & Rates`
       ┌─ test.ren:24:15
    24 │   print(ap(g, counting_rates(1)))
       │               ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write it where it's made or passed, `let x: Rates = ...` or `fn f(x: Rates)`
    |}]

let%expect_test "a place whose type is written narrows what's assigned to it" =
  (* a field's declared type, a `var`'s written one, and an item of an
     array whose item type is written; a `var` whose type isn't written
     keeps the type it was made with *)
  run
    (rates
   ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)

type R = { r: Rates, n: Int }

fn main() uses Console =
  var x = R { r: plus(0), n: 1 }
  x.r = counting_rates(2)
  print(run(x.r))
  var xs: Array<Rates> = [plus(0)]
  xs[0] = counting_rates(4)
  print(run(xs[0]))
  var v: Rates = plus(0)
  v = counting_rates(5)
  with v in print(Rates.usd_to(3))

handler plus(k: Int) for Rates =
  usd_to(c) => c + k
|}
    );
  [%expect {|
    2
    4
    5
    ()
    |}];
  check_error
    (rates
   ^ {|
fn main() =
  var w = plus(0)
  w = counting_rates(5)

handler plus(k: Int) for Rates =
  usd_to(c) => c + k
|}
    );
  [%expect
    {|
    error: this is a `RateCalls & Rates`, but it's being assigned to a `Rates`
       ┌─ test.ren:18:7
    18 │   w = counting_rates(5)
       │       ^^^^^^^^^^^^^^^^^
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write `w`'s type where it's declared: `var w: Rates = ...`
    |}]

let%expect_test "a group function's result that isn't written" =
  (* `make` and `a` call each other, so `a` sees `make`'s result only as
     its declaration describes it, a variable, which isn't narrowed, in
     either order *)
  let src first second =
    rates ^ {|
fn run(r: Rates) -> Int = with r in Rates.usd_to(1)
|} ^ first
    ^ second ^ {|
fn main() uses Console = print(a(1))
|}
  in
  let make =
    {|
fn make(n: Int) = if n > 5 then counting_rates(a(n)) else counting_rates(1)
|}
  and a = {|
fn a(n: Int) -> Int = if n == 0 then run(make(n)) else 0
|} in
  check_error (src make a);
  [%expect
    {|
    error: `make` is used here as `fn(Int) -> Rates`, but its definition makes it `fn(Int) -> RateCalls & Rates`
       ┌─ test.ren:20:42
    20 │ fn a(n: Int) -> Int = if n == 0 then run(make(n)) else 0
       │                                          ^^^^
       = functions that call each other are checked at a single type
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write `make`'s result, `-> Rates`, which narrows it there
    |}];
  check_error (src a make);
  [%expect
    {|
    error: `make` is used here as `fn(Int) -> Rates`, but its definition makes it `fn(Int) -> RateCalls & Rates`
       ┌─ test.ren:18:42
    18 │ fn a(n: Int) -> Int = if n == 0 then run(make(n)) else 0
       │                                          ^^^^
       = functions that call each other are checked at a single type
       = `RateCalls & Rates` is a `Rates` only where a written type asks for one
       help: write `make`'s result, `-> Rates`, which narrows it there
    |}]

(* ---- test items (testing.md, "Test items") ---- *)

let%expect_test "a test uses its module's test items" =
  test
    {|
pub dep Store =
  get: fn() -> Int

test fn twice(n: Int) -> Int = n * 2

test handler fixed(n: Int) for Store =
  get() => n

pub fn read() -> Int uses Store = Store.get()

test "a test item helps" =
  assert with fixed(7) in twice(read()) == 14
|};
  [%expect
    {|
    test.ren
      ✓ a test item helps

    1 passed
    [exit 0]
    |}]

let%expect_test "another module's tests use its public test items" =
  test_files
    [
      ( "main.ren",
        {|
import store

group "fixed" = store.reads(store.fixed(3))

test "a public test item, imported" =
  assert with store.fixed(5) in store.twice(store.read()) == 10
|}
      );
      ( "store.ren",
        {|
pub dep Store =
  get: fn() -> Int

pub fn read() -> Int uses Store = Store.get()

pub test fn twice(n: Int) -> Int = n * 2

pub test handler fixed(n: Int) for Store =
  get() => n

pub group reads(s: Store) with s =
  test "reads what it's given" =
    assert read() == read()
|}
      );
    ];
  [%expect
    {|
    main.ren
      fixed
        ✓ reads what it's given
      ✓ a public test item, imported

    2 passed
    [exit 0]
    |}]

let%expect_test "a private test item is its own module's" =
  check_error_files
    [
      ( "main.ren",
        {|
import store

test "it can't" =
  assert store.twice(2) == 4

fn main() = ()
|}
      );
      ("store.ren", {|
test fn twice(n: Int) -> Int = n * 2
|});
    ];
  [%expect
    {|
    error: `store` has no public `twice`
      ┌─ main.ren:4:16
    4 │   assert store.twice(2) == 4
      │                ^^^^^
      help: if it's defined there, mark it `pub`
    |}]

let%expect_test "only test code uses a test item" =
  check_error {|
test fn alice() -> Int = 1

fn main() = print(alice())
|};
  [%expect
    {|
    error: `alice` is a test item, so only a test can use it
      ┌─ test.ren:3:19
    3 │ fn main() = print(alice())
      │                   ^^^^^
      = a test item isn't part of `test`'s interface, and `ren run` leaves it out
      help: call it from a test, or remove `test` from its declaration
    |}];
  check_error_files
    [
      ("main.ren", {|
import store

fn main() = print(store.twice(2))
|});
      ("store.ren", {|
pub test fn twice(n: Int) -> Int = n * 2
|});
    ];
  [%expect
    {|
    error: `store.twice` is a test item, so only a test can use it
      ┌─ main.ren:3:25
    3 │ fn main() = print(store.twice(2))
      │                         ^^^^^
      = a test item isn't part of `store`'s interface, and `ren run` leaves it out
      help: call it from a test, or remove `test` from its declaration
    |}]

let%expect_test "nor a test handler" =
  check_error
    {|
pub dep Store =
  get: fn() -> Int

test handler fixed(v: Int) for Store =
  get() => v

fn main() = print(with fixed(1) in Store.get())
|};
  [%expect
    {|
    error: `fixed` is a test item, so only a test can use it
      ┌─ test.ren:7:24
    7 │ fn main() = print(with fixed(1) in Store.get())
      │                        ^^^^^
      = a test item isn't part of `test`'s interface, and `ren run` leaves it out
      help: call it from a test, or remove `test` from its declaration
    |}]

let%expect_test "a public test item is written `pub test`" =
  check_error {|
test pub fn twice(n: Int) -> Int = n * 2
|};
  [%expect
    {|
    error: `pub` goes before `test`
      ┌─ test.ren:1:6
    1 │ test pub fn twice(n: Int) -> Int = n * 2
      │      ^^^
      help: write `pub` first: `pub test fn ...`, `pub test handler ...`
    |}]

let%expect_test "a test compares its own opaque type as an importer would" =
  check_error
    {|
pub type Id = opaque Int
  pub fn of(n: Int) -> Id = n

test "ordered" =
  assert Id.of(1) < Id.of(2)

fn main() = ()
|};
  [%expect
    {|
    error: `Id` has no `<`
      ┌─ test.ren:5:10
    5 │   assert Id.of(1) < Id.of(2)
      │          ^^^^^^^^^^^^^^^^^^^
      = a test sees what an importer sees, and to an importer an opaque type is ordered only by its `key`
      help: give `Id` a key: `fn key(self) -> K = ...`
    |}]

let%expect_test "`ren run` leaves test items out, and `ren types` shows them" =
  let src =
    {|
pub test fn twice(n: Int) -> Int = n * 2
test fn alice() -> Int = 1

test "they work" =
  assert twice(alice()) == 2

fn main() = print(3)
|}
  in
  run src;
  types src;
  [%expect
    {|
    3
    ()
    pub test fn twice(n: Int) -> Int
    test fn alice() -> Int
    fn main() uses Console
    |}]

let%expect_test "only a function or a handler can be a test item" =
  check_error {|
test type Fake = { n: Int }
|};
  check_error {|
test dep Fake =
  get: fn() -> Int
|};
  check_error {|
test let n = 1
|};
  check_error
    {|
pub type Account = opaque { n: Int }
  test fn peek(self) -> Int = self.n
|};
  [%expect
    {|
    error: only a function or a handler can be a test item
      ┌─ test.ren:1:1
    1 │ test type Fake = { n: Int }
      │ ^^^^
      help: make it an ordinary item; a test sees it if it's `pub`
    error: only a function or a handler can be a test item
      ┌─ test.ren:1:1
    1 │ test dep Fake =
      │ ^^^^
      help: make it an ordinary item; a test sees it if it's `pub`
    error: only a function or a handler can be a test item
      ┌─ test.ren:1:1
    1 │ test let n = 1
      │ ^^^^
      help: make it an ordinary item; a test sees it if it's `pub`
    error: a member can't be a test item
      ┌─ test.ren:2:3
    2 │   test fn peek(self) -> Int = self.n
      │   ^^^^
      help: declare it at the top level: `test fn name(...)`
    |}]

let%expect_test "a test item is named like any function" =
  check_error {|
test fn alice() -> Int = 1
fn alice() -> Int = 2
|};
  [%expect
    {|
    error: there are two functions named `alice`
      ┌─ test.ren:2:4
    1 │ test fn alice() -> Int = 1
      │         ----- the first `alice` is here
    2 │ fn alice() -> Int = 2
      │    ^^^^^
      help: rename one of them
    |}]

(* ---- a test sees what an importer sees (testing.md, "Tests are
   specifications") ---- *)

let account =
  {|
pub type AccountId = opaque Int
  pub fn of(n: Int) -> AccountId = n

pub type Account = opaque { id: AccountId, balance: Int, log: Array<Str> }
  pub fn open(id: AccountId) -> Account = Account { id, balance: 0, log: [] }
  pub fn balance(self) -> Int = self.balance
  pub fn credit(inout self, n: Int) =
    self.balance = self.balance + n
    &self.stamp("credit")
  fn stamp(inout self, what: Str) = &self.log.push(what)
  pub fn key(self) -> AccountId = self.id

type Ledger = { entries: Array<Int> }

dep Users =
  count: fn() -> Int

fn audit(a: Account) -> Int = a.log.len()
|}

let%expect_test "a test can't use a private function, type or dependency" =
  check_error
    (account
   ^ {|
test "a private function" =
  assert audit(Account.open(AccountId.of(1))) == 0

test "a private type" =
  let l = Ledger { entries: [] }
  assert l.entries == []

test "a private dependency" =
  assert Users.count() == 0
|}
    );
  [%expect
    {|
    error: `audit` is private, and a test sees what an importer sees
       ┌─ test.ren:21:10
    21 │   assert audit(Account.open(AccountId.of(1))) == 0
       │          ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`

    error: `Ledger` is private, and a test sees what an importer sees
       ┌─ test.ren:24:11
    24 │   let l = Ledger { entries: [] }
       │           ^^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`

    error: `Users` is private, and a test sees what an importer sees
       ┌─ test.ren:28:10
    28 │   assert Users.count() == 0
       │          ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}]

let%expect_test "a test can't use a private member" =
  test
    (account
   ^ {|
test "through a value" =
  var a = Account.open(AccountId.of(1))
  &a.stamp("x")
|}
    );
  [%expect
    {|
    error: `stamp` is private, and a test sees what an importer sees
       ┌─ test.ren:22:6
    22 │   &a.stamp("x")
       │      ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}];
  test
    (account
   ^ {|
test "after its type" =
  var a = Account.open(AccountId.of(1))
  Account.stamp(&a, "x")
|}
    );
  [%expect
    {|
    error: `Account.stamp` is private, and a test sees what an importer sees
       ┌─ test.ren:22:11
    22 │   Account.stamp(&a, "x")
       │           ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}]

(* what a private method could fail with is unknown to a test, so the
   `try` around its call isn't said to cover nothing *)
let%expect_test "a test's call of a private method that can fail is one error" =
  test
    {|
pub type Account = opaque { log: Array<Str>, frozen: Bool }
  pub fn open() -> Account = Account { log: [], frozen: false }
  fn stamp(inout self, e: Str) ! Frozen =
    if self.frozen then fail Frozen
    &self.log.push(e)

test "stamps" =
  var a = Account.open()
  try &a.stamp("x")
|};
  [%expect
    {|
    error: `stamp` is private, and a test sees what an importer sees
      ┌─ test.ren:9:10
    9 │   try &a.stamp("x")
      │          ^^^^^
      = a test is a specification of `test`'s interface
      help: mark it `pub`, or explore it in the console: `ren console test`
    |}];
  (* and so is a method that isn't there at all *)
  types
    {|
type Account = { frozen: Bool }
fn f(a: Account) = attempt a.thaw()
fn main() = ()
|};
  [%expect
    {|
    error: `Account` has no method named `thaw`
      ┌─ test.ren:2:30
    2 │ fn f(a: Account) = attempt a.thaw()
      │                              ^^^^
      help: declare it under `type Account`, with `self` first
    |}]

let%expect_test "a test sees its module's opaque types as opaque" =
  test
    (account
   ^ {|
test "a field" =
  let a = Account.open(AccountId.of(1))
  assert a.log == []

test "a literal" =
  let a = Account { id: AccountId.of(1), balance: 5, log: [] }
  assert a.balance() == 5

test "an update" =
  var a = Account.open(AccountId.of(1))
  a.log = ["x"]

test "a representation" =
  assert AccountId.of(1) == 1
|}
    );
  [%expect
    {|
    error: `Account` is opaque, and a test sees what an importer sees
       ┌─ test.ren:22:12
    22 │   assert a.log == []
       │            ^^^
       = a test is a specification of `test`'s interface
       help: explore it in the console: `ren console test`

    error: `==` compares two values of the same type, but this is an `Int` and the left side is an `AccountId`
       ┌─ test.ren:33:29
    33 │   assert AccountId.of(1) == 1
       │                             ^
       │          --------------- this is an `AccountId`
       = `AccountId` is opaque, and a test sees what an importer sees
       help: explore it in the console: `ren console test`
    |}]

(* the fix is the same at every use, so it's said once per type, as a
   private item's is *)
let%expect_test
    "a test reaching an opaque type's fields is told at the first use only" =
  test
    (account
   ^ {|
test "reads and writes" =
  let a = Account.open(AccountId.of(1))
  assert a.log == []
  assert a.log.len() == 0
  let b = Account { id: AccountId.of(2), balance: 0, log: [] }
  assert b.balance() == 0
|}
    );
  [%expect
    {|
    error: `Account` is opaque, and a test sees what an importer sees
       ┌─ test.ren:22:12
    22 │   assert a.log == []
       │            ^^^
       = a test is a specification of `test`'s interface
       help: explore it in the console: `ren console test`
    |}]

(* and so is using one as what it's represented as, or comparing one an
   importer can't order: one error for the type, at the first use *)
let%expect_test
    "a test using an opaque type as its representation is told at the first \
     use only" =
  test
    {|
pub type Money = opaque Int
  pub fn cents(n: Int) -> Money =
    let m: Money = n
    m

test "reach" =
  let m = Money.cents(5)
  assert m > 0
  assert m > 1
  assert m == 5
  let k: Int = m
  assert k == 5
|};
  [%expect
    {|
    error: `>` compares two values of the same type, but this is an `Int` and the left side is a `Money`
      ┌─ test.ren:8:14
    8 │   assert m > 0
      │              ^
      │          - this is a `Money`
      = `Money` is opaque, and a test sees what an importer sees
      help: explore it in the console: `ren console test`
    |}]

(* a private method is told once, as a private function is *)
let%expect_test "a test calling a private method is told at the first use only"
    =
  test
    (account
   ^ {|
test "twice" =
  var a = Account.open(AccountId.of(1))
  &a.stamp("x")
  &a.stamp("y")
|}
    );
  [%expect
    {|
    error: `stamp` is private, and a test sees what an importer sees
       ┌─ test.ren:22:6
    22 │   &a.stamp("x")
       │      ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}]

let%expect_test "a test item, a group and a run see what an importer sees" =
  test
    (account
   ^ {|
test fn rich() -> Account =
  var a = Account.open(AccountId.of(1))
  a.log = ["rich"]
  a
|}
    );
  [%expect
    {|
    error: `Account` is opaque, and a test sees what an importer sees
       ┌─ test.ren:22:5
    22 │   a.log = ["rich"]
       │     ^^^
       = a test is a specification of `test`'s interface
       help: explore it in the console: `ren console test`
    |}];
  test
    (account
   ^ {|
group spends(a: Account) =
  test "it's spent" =
    assert audit(a) == 0

group "spent" = spends(Account.open(AccountId.of(audit(Account.open(AccountId.of(1))))))
|}
    );
  [%expect
    {|
    error: `audit` is private, and a test sees what an importer sees
       ┌─ test.ren:22:12
    22 │     assert audit(a) == 0
       │            ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}]

let%expect_test "what a test can use" =
  (* its module's public items and test items, its public members, `==`
     through a private `key`, and what it imports *)
  test_files
    [
      ( "account.ren",
        account
        ^ {|
pub type Money = opaque Int with numeric
  pub fn cents(n: Int) -> Money = n

test fn opened(n: Int) -> Account = Account.open(AccountId.of(n))

test "its public items" =
  var a = opened(1)
  &a.credit(5)
  assert a.balance() == 5
  assert a == opened(1)
  assert Money.cents(2) + Money.cents(3) == Money.cents(5)
  assert Money.cents(2) * 3 == Money.cents(6)
  assert Path.of("a") == Path.of("a")
|}
      );
    ];
  [%expect
    {|
    account.ren
      ✓ its public items

    1 passed
    [exit 0]
    |}]

let%expect_test "a test can't name a private error set" =
  check_error
    {|
type Oops = ! Bad | Worse

pub fn f() -> Int = 1

test fn t() ! Oops = fail Bad

test "a set" = assert attempt t() == Err(Bad)
|};
  [%expect
    {|
    error: `Oops` is private, and a test sees what an importer sees
      ┌─ test.ren:5:15
    5 │ test fn t() ! Oops = fail Bad
      │               ^^^^
      = a test is a specification of `test`'s interface
      help: mark it `pub`, or explore it in the console: `ren console test`
    |}]

let%expect_test "a test can't use a private type's constructor" =
  check_error
    {|
type State =
  | Red
  | Green

pub type Light = opaque State

pub fn red() -> Light = Red

fn main() = ()

test "through the opaque type" = assert red() == Red

test "on its own" = assert Green == Green
|};
  [%expect
    {|
    error: `Red` is private, and a test sees what an importer sees
       ┌─ test.ren:11:50
    11 │ test "through the opaque type" = assert red() == Red
       │                                                  ^^^
       = a test is a specification of `test`'s interface
       help: mark its type, `State`, `pub`, or explore it in the console: `ren console test`

    error: `Green` is private, and a test sees what an importer sees
       ┌─ test.ren:13:28
    13 │ test "on its own" = assert Green == Green
       │                            ^^^^^
       = a test is a specification of `test`'s interface
       help: mark its type, `State`, `pub`, or explore it in the console: `ren console test`

    error: `Green` is private, and a test sees what an importer sees
       ┌─ test.ren:13:37
    13 │ test "on its own" = assert Green == Green
       │                                     ^^^^^
       = a test is a specification of `test`'s interface
       help: mark its type, `State`, `pub`, or explore it in the console: `ren console test`
    |}]

let%expect_test "a test item is told what a test is told" =
  check_error
    (account
   ^ {|
test fn count() -> Int = audit(Account.open(AccountId.of(1)))
|});
  [%expect
    {|
    error: `audit` is private, and a test sees what an importer sees
       ┌─ test.ren:20:26
    20 │ test fn count() -> Int = audit(Account.open(AccountId.of(1)))
       │                          ^^^^^
       = a test is a specification of `test`'s interface
       help: mark it `pub`, or explore it in the console: `ren console test`
    |}];
  check_error (account ^ {|
test fn peek(a: Account) -> Int = a.log.len()
|});
  [%expect
    {|
    error: this program has no `main` function
      ┌─ test.ren:1:1
    1 │ pub type AccountId = opaque Int
      │ ^
      help: add `fn main() = ...`, which is where the program starts

    error: `Account` is opaque, and a test sees what an importer sees
       ┌─ test.ren:20:37
    20 │ test fn peek(a: Account) -> Int = a.log.len()
       │                                     ^^^
       = a test is a specification of `test`'s interface
       help: explore it in the console: `ren console test`
    |}]


(* ---- generic dependencies (compiler.md, "Generic dependencies") ---- *)

let%expect_test "an alias, a written alias type, a member and a chain" =
  (* `Replica` is a `Db` of its own, installed beside it; `let q: Jobs`
     makes `queue()`'s description a `Jobs`'s; `Chan.make()` is called at
     the types its result is used as; and `limit()` goes over `queue()`
     at its types *)
  run {|
dep Db =
  get: fn() -> Int

handler fixed(n: Int) for Db =
  get() => n

dep Replica = Db

dep Chan<T> =
  send: fn(x: T)
  take: fn() -> Option<T>

  pub fn make() -> Chan<T> = queue()

handler queue<T>() for Chan<T> =
  var xs: Array<T> = []
  send(x) => &xs.push(x)
  take() => if xs.len() == 0 then None else Some(xs[0])

dep Jobs = Chan<Int>

handler limit<T>() over Chan<T> =
  send(x) => next.send(x)
  take() => next.take()

fn both() -> Int uses Db, Replica = Db.get() * 10 + Replica.get()

fn main() uses Console =
  with fixed(1), fixed(2) as Replica in
    print(both())
  let q: Jobs = queue()
  with q in
    Jobs.send(3)
    print(Jobs.take())
  let m: Chan<Str> = Chan.make()
  with m in
    Chan.send("s")
    let s: Option<Str> = Chan.take()
    print(s)
  with limit() over queue() in
    Chan.send(4)
    let f: Option<Int> = Chan.take()
    print(f)
|};
  [%expect {|
    12
    Some(3)
    Some("s")
    Some(4)
    ()
    |}]

let%expect_test "a generic link goes over one at its own types" =
  check_error {|
dep Chan<T> =
  send: fn(x: T)
  take: fn() -> Option<T>

handler queue<T>() for Chan<T> =
  var xs: Array<T> = []
  send(x) => &xs.push(x)
  take() => if xs.len() == 0 then None else Some(xs[0])

handler limit<T>() over Chan<T> =
  send(x) => next.send(x)
  take() => next.take()

fn main() =
  let q: Chan<Str> = queue()
  let l: over Chan<Int> = limit()
  with l over q in 1
|};
  [%expect {|
    error: `l` goes over a `Chan<Int>`, and `q` isn't one
       ┌─ test.ren:17:15
    17 │   with l over q in 1
       │               ^
       help: put a `Chan<Int>` under it
    |}];
  (* `as` follows one implementation: a chain installed as an alias is
     a later step's *)
  check_error {|
dep Chan<T> =
  send: fn(x: T)
  take: fn() -> Option<T>

handler queue<T>() for Chan<T> =
  var xs: Array<T> = []
  send(x) => &xs.push(x)
  take() => if xs.len() == 0 then None else Some(xs[0])

handler limit<T>() over Chan<T> =
  send(x) => next.send(x)
  take() => next.take()

dep Jobs = Chan<Int>

fn main() =
  with limit() over queue() as Jobs in 1
|};
  [%expect {|
    error: `as` follows one implementation, and `queue()` is part of a chain
       ┌─ test.ren:17:8
    17 │   with limit() over queue() as Jobs in 1
       │        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
       help: install the chain without `as`, or make its top the one implementation of the item
    |}]
