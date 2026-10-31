(* Stage 12a build roots keep their declaration identity throughout the
   frontend; the existing associated-value path remains separate. *)
open Ren
open Helpers

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let rejects source parts =
  let source = clean source in
  let source = if contains source "fn main(" then source
    else source ^ "\nfn main() = ()\n" in
  let output, raised = captured (fun () ->
      report source (fun () -> ignore (Driver.check ~file source))) in
  Option.iter raise raised;
  List.iter (fun part ->
      if not (contains output part) then
        failwith ("missing diagnostic " ^ part ^ ":\n" ^ output)) parts

let%expect_test "build root item kinds and source identity" =
  let roots = Driver.parse ~file
      "let TABLE: Array<Int> = [1, 2]\nassert TABLE.len() == 2\nfn main() = ()\n" in
  (match roots with
  | [ Ast.Top_value value; Top_assert assertion; Fn _ ] ->
      assert (value.name.name = "TABLE");
      assert (value.params = []);
      assert (assertion.name.name = "$assert:2:1");
      (match assertion.body.kind with Ast.Assert _ -> () | _ -> assert false)
  | _ -> assert false);
  [%expect {| |}]

let%expect_test "forward uppercase and lowercase values through helpers" =
  run {|let TABLE = table()
let start = END - 1
let END = 3
fn table() -> Array<Int> = [start, END]
assert TABLE == [2, 3]
fn main() uses Console =
  print(TABLE)
  print(start)
|};
  [%expect {|
    [2, 3]
    2
    () |}]

let%expect_test "imported build values retain data schemes and privacy" =
  run_files [
    ("main.ren", {|import data
let LOCAL = data.TABLE
assert data.answer == 42
fn main() uses Console =
  print(LOCAL)
  print(data.TABLE.len())
|});
    ("data.ren", {|pub let TABLE: Array<Int> = [answer, 7]
pub let answer: Int = 42
|}) ];
  [%expect {|
    [42, 7]
    2
    () |}]

let%expect_test "build root refusals include helper cycles and scoped data" =
  rejects "let A = next()\nlet B = A\nfn next() = B\n"
    [ "cycle"; "A"; "B"; "next" ];
  rejects "let BAD = Clock.now()\n"
    [ "BAD"; "Clock"; "build"; "packages" ];
  rejects "let BLOCK = fn(x: Int) => x + 1\n"
    [ "block" ];
  rejects "assert 1\n" [ "Bool"; "Int" ];
  rejects "let BAD: Str = 1\n" [ "Str"; "Int" ];
  [%expect {| |}]

let%expect_test "build assertion retains both computed operands" =
  rejects "let LEFT = 2 + 2\nassert LEFT == 5\n"
    [ "assert"; "4"; "5" ];
  [%expect {| |}]

let%expect_test "top-level try propagates the original build failure" =
  rejects "let BAD = try broken()\nfn broken() -> Int ! Bad = fail Bad\n"
    [ "BAD"; "Bad" ];
  [%expect {| |}]

let%expect_test "function uses records inferred reach rather than a written upper bound" =
  run {|fn quiet() -> Int uses Clock = 1
let PURE = quiet()
assert quiet.uses <= []
assert not quiet.uses.includes(Clock)
fn main() uses Console =
  print(PURE)
  print(quiet.uses <= [Clock])
|};
  [%expect {|
    1
    true
    () |}]

let%expect_test "function uses rejects an architecture assertion with its transitive path" =
  rejects {|fn handle_request() -> Time = render()
fn render() -> Time = load_template()
fn load_template() -> Time = Clock.now()
assert handle_request.uses <= []
fn main() = ()
|} [ "Clock"; "handle_request → render → load_template → Clock.now";
      "pass the input in or revise the rule" ];
  [%expect {| |}]

let%expect_test "function uses crosses modules and keeps instantiated dependency identity" =
  run_files [
    ("main.ren", {|import work.{Store}
assert work.load.uses <= [Store]
assert work.load.uses.includes(Store)
fn main() uses Console = print(work.load.uses.includes(Store))
|});
    ("work.ren", {|pub dep Store =
  get: fn() -> Int
pub fn load() -> Int uses Store = helper()
fn helper() -> Int = Store.get()
|}) ];
  [%expect {|
    true
    () |}]

let%expect_test "function uses distinguishes concrete generic arguments" =
  run {|dep Store<T> =
  get: fn() -> T
fn load<T>() -> T uses Store<T> = Store.get()
assert load<Int>.uses <= [Store<Int>]
assert load<Int>.uses.includes(Store<Int>)
assert not load<Int>.uses.includes(Store<Str>)
fn main() uses Console = print(load<Int>.uses.includes(Store<Int>))
|};
  [%expect {|
    true
    () |}]

let%expect_test "function uses accounts for installed handlers" =
  run {|fn local() -> Time = with Clock.frozen(Time.epoch) in Clock.now()
assert local.uses <= []
fn main() = ()
|};
  [%expect {| () |}]

let%expect_test "qualified uppercase values do not turn named types into values" =
  let files = [
    "main.ren", "import billing\nfn main() = billing.Plan\n";
    "billing.ren", "pub type Plan = { amount: Int }\n" ] in
  let said, raised = captured (fun () -> check_error_files files) in
  Option.iter raise raised;
  List.iter (fun fragment -> if not (contains said fragment) then
      failwith ("missing qualified-type refusal " ^ fragment ^ ":\n" ^ said))
    ["error:"; "billing.Plan"; "type"; "can't be used as a value"; "constructors"; "record"];
  [%expect {||}]
