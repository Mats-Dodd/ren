(* Build-time values have no executable initializer. Exercise their layout,
   sharing and copy-on-write behavior through the native backend too. *)
open Ren
open Helpers

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1)) in
  at 0

let native ?load source release =
  Driver.native ?load ~lint:true ~release ~sources:(fun name ->
      if name = file then Some source else None) ~file source

let run_c ?load ?(zero = false) source expected =
  List.iter (fun release ->
      let c = Filename.temp_file "ren-static" ".c" in
      let exe = c ^ ".exe" and out = c ^ ".out" and err = c ^ ".err" in
      Fun.protect ~finally:(fun () ->
          List.iter (fun p -> if Sys.file_exists p then Sys.remove p) [c;exe;out;err])
        (fun () ->
          Out_channel.with_open_bin c (fun oc -> output_string oc (native ?load source release));
          let command = Printf.sprintf
            "cc %s -DREN_STATS -fsanitize=address,undefined %s -lm -o %s > %s 2>&1 && %s > %s 2> %s"
            (if release then "-O2" else "-O0") (Filename.quote c)
            (Filename.quote exe) (Filename.quote err) (Filename.quote exe)
            (Filename.quote out) (Filename.quote err) in
          if Sys.command command <> 0 then
            failwith (In_channel.with_open_bin err In_channel.input_all);
          let said = In_channel.with_open_bin out In_channel.input_all in
          if said <> expected then failwith ("native static output: " ^ said);
          let stats = In_channel.with_open_bin err In_channel.input_all in
          assert (contains stats "objects live at exit 0");
          if zero then assert (contains stats "allocations 0, frees 0")))
    [false;true]

let%expect_test "static nested arrays share owners and names survive unrelated roots" =
  let source = "let TABLE = [[1, 2], [1, 2]]\nfn main() -> Int = TABLE[0][1]\n" in
  List.iter (fun release ->
      let p = Driver.mem ~lint:true ~release ~file source in
      assert (p.values = []);
      assert (List.length p.static_data = 2);
      (match (List.nth p.static_data 1).sdkind with
      | Static_array (_, [a;b]) -> assert (a = b)
      | _ -> assert false);
      let other = Driver.mem ~lint:true ~release ~file
          ("let UNRELATED = [9, 8, 7]\n" ^ source) in
      assert (List.map (fun (d : Mem.static_data) -> d.sdname) p.static_data
          = List.map (fun (d : Mem.static_data) -> d.sdname) other.static_data);
      let c = native source release in
      assert (contains c "const struct ren_const_");
      assert (not (contains c "ren_test_TABLE("))) [false;true];
  run_c ~zero:true source "2\n";
  [%expect {| |}]

let%expect_test "static Map Set and nested array mutation preserve the original" =
  let source = {|let GRID = [[1, 2], [1, 2]]
let TABLE = Map.of([("a", GRID[0]), ("b", GRID[1])])
let SET = Set.of([3, 1, 3])
fn main() -> Int =
  var grid = GRID
  grid[0][0] = 99
  assert (GRID[0][0] == 1) && true
  assert (grid[0][0] == 99) && true
  assert (TABLE.get("a") == Some([1, 2])) && true
  assert (TABLE == Map.of([("b", [1, 2]), ("a", [1, 2])])) && true
  assert (TABLE.hash() == Map.of([("b", [1, 2]), ("a", [1, 2])]).hash()) && true
  var table = TABLE
  &table.set("a", [7])
  &table.remove("b")
  &table.set("c", [5])
  assert (TABLE.get("a") == Some([1, 2])) && true
  assert (table.keys() == ["a", "c"]) && true
  assert (table.values() == [[7], [5]]) && true
  var members = SET
  &members.remove(1)
  &members.add(4)
  assert (SET == Set.of([1, 3])) && true
  assert (members == Set.of([3, 4])) && true
  42
|} in
  run_c source "42\n";
  [%expect {| |}]

let%expect_test "static data handler descriptions relocate code and captures" =
  let source = {|dep Numbers =
  get: fn() -> Int
handler constant(n: Int) for Numbers =
  get() => n
let HANDLER: Numbers = constant(7)
let ROUTES: Array<Numbers> = [HANDLER, constant(8)]
fn main() -> Int =
  let a = with ROUTES[0] in Numbers.get()
  let b = with ROUTES[1] in Numbers.get()
  a + b
|} in
  run_c ~zero:true source "15\n";
  [%expect {| |}]

let%expect_test "Mem Lint rejects forged static layouts and scoped references" =
  let p = Driver.mem ~lint:true ~file
      "let TABLE = [1, 2]\nfn main() -> Int = TABLE[0]\n" in
  let d = List.hd p.static_data in
  let rejects d =
    match Mem_lint.program {p with static_data=[d]} with
    | () -> failwith "accepted malformed static data"
    | exception Failure s -> assert (contains s "Mem Lint: static data") in
  rejects {d with sdlayout=Int};
  rejects {d with sdkind=Static_array (Ev,[No_ev])};
  [%expect {| |}]

let%expect_test "static packed scalars sized arrays and large object masks" =
  let source = {|type Data = {
  a: Array<Int>, b: Array<Int>, c: Array<Int>, d: Array<Int>,
  e: Array<Int>, f: Array<Int>, g: Array<Int>, h: Array<Int>, i: Array<Int>
}
type Scalars = { neg: Int8, byte: UInt8, single: Float32, yes: Bool }
type Choice = Stop | Hold(Scalars)
let BIG = Data { a: [1], b: [2], c: [3], d: [4], e: [5], f: [6], g: [7], h: [8], i: [9] }
let SMALL = Scalars { neg: -3, byte: 255, single: 0.5, yes: true }
let CHOICE = Choice.Hold(SMALL)
let SIZED: Array<Int16> = [-300, 7]
let BYTES = b"\x00\xff"
let TEXT = "static"
let PAIR = (CHOICE, TEXT)
fn main() -> Int =
  assert (SMALL.neg == -3) && true
  assert (SMALL.byte == 255) && true
  assert (SMALL.single == 0.5) && true
  assert (SMALL.yes) && true
  assert (SIZED[0] == -300) && true
  assert (BYTES.at(1) == 255) && true
  let (_, text) = PAIR
  assert (text == TEXT) && true
  BIG.i[0] + BIG.a[0]
|} in
  run_c ~zero:true source "10\n";
  [%expect {| |}]

let%expect_test "generic defaults select static data and descriptions close type evidence" =
  let source = {|type Box<T> = { value: T, rest: Array<T> = [] }
fn box<T>(x: T) -> Box<T> = { value: x }
fn wrap<T>(x: T) -> Box<T> = box(x)
dep Textual<T> =
  get: fn(value: T) -> Str
handler described<T>(x: T) for Textual<T> =
  get(value) => show(x)
let TEXT: Textual<Int> = described(7)
fn main() -> Int =
  let a = wrap(7)
  let b = wrap("x")
  let text = with TEXT in Textual.get(0)
  a.value + a.rest.len() + b.rest.len() + text.byte_len()
|} in
  run_c source "8\n";
  [%expect {| |}]

let%expect_test "nested static empty constructors retain scalar and niche tags" =
  let source = {|type Choice = Blank | Text(Str)
let VALUES = [Choice.Blank, Choice.Text("ok")]
fn main() -> Int =
  let head = match VALUES[0]
    Choice.Blank => 1
    Choice.Text(_) => 0
  let tail = match VALUES[1]
    Choice.Blank => 0
    Choice.Text(text) => text.byte_len()
  head + tail
|} in
  run_c ~zero:true source "3\n";
  [%expect {| |}]

let%expect_test "frozen descriptions distinguish identical names in imported modules" =
  let load = function
    | "numbers" -> Some "pub dep Numbers =\n  get: fn() -> Int\n"
    | "a" -> Some "import numbers\npub handler constant(n: Int) for numbers.Numbers =\n  get() => n + 1\n"
    | "b" -> Some "import numbers\npub handler constant(n: Int) for numbers.Numbers =\n  get() => n + 2\n"
    | _ -> None in
  let source = {|import numbers
import a
import b
let ROUTES: Array<numbers.Numbers> = [a.constant(7), b.constant(7)]
fn main() -> Int =
  let first = with ROUTES[0] in numbers.Numbers.get()
  let second = with ROUTES[1] in numbers.Numbers.get()
  first * 100 + second
|} in
  run_c ~load ~zero:true source "809\n";
  List.iter(fun release ->
    let names text = (Driver.mem ~load ~lint:true ~release ~file text).static_data
      |> List.map(fun(d:Mem.static_data)->d.sdname) in
    let prefix = "import numbers\nimport a\nimport b\n" in
    let extra = prefix ^ "let UNRELATED = 1\n" ^
      String.sub source (String.length prefix) (String.length source-String.length prefix) in
    assert(names source=names extra);
    let shifted = function
      | "a" -> Some "import numbers\nlet UNRELATED = 1\npub handler constant(n: Int) for numbers.Numbers =\n  get() => n + 1\n"
      | name -> load name in
    let shifted_names = (Driver.mem ~load:shifted ~lint:true ~release ~file source).static_data
      |> List.map(fun(d:Mem.static_data)->d.sdname) in
    assert(names source=shifted_names)) [false;true];
  [%expect {| |}]
