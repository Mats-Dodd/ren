(* The build evaluator owns its step count and data boundary in every mode. *)
open Ren
open Helpers

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let rejects src parts =
  let src = src ^ "\nfn main() = ()\n" in
  let said, raised = captured (fun () ->
    report src (fun () -> ignore (Driver.check ~file src))) in
  Option.iter raise raised;
  List.iter (fun part ->
    if not (contains said part) then failwith (part ^ " missing from:\n" ^ said)) parts

let%test_unit "top-level roots are constants after transitive ordering" =
  let modules = Driver.linked ~lint:true ~file
    "let FIRST: Int = through()\nlet LAST = 9\nfn through() -> Int = LAST - 1\nassert FIRST == 8\nfn main() = FIRST\n" in
  let entry = List.hd (List.rev modules) in
  assert (List.length entry.build_values = 2);
  assert (entry.build_asserts = []);
  List.iter (fun p ->
    let f = List.find (fun (f : Core.fn_def) -> f.path = p) entry.fns in
    match f.body.kind with Core.Const _ -> () | _ -> assert false) entry.build_values;
  assert (Eval.run modules = Value.VInt 8L)

let%test_unit "check executes assertions, try and panics" =
  rejects "assert 2 + 2 == 5\n" ["assert failed while building"; "4"; "5"];
  rejects "let BAD = try broken()\nfn broken() -> Int ! Broken = fail Broken\n"
    ["BAD"; "failed while building"; "Broken"];
  rejects "let BAD = 1 / 0\n" ["BAD"; "panicked while building"; "zero"]

let%test_unit "dependency cycles retain helper paths" =
  rejects
    "let A: Int = first()\nlet B: Int = second()\nfn first() -> Int = B\nfn second() -> Int = A\n"
    ["cycle"; "A"; "first"; "B"; "second"]

let minimal_roots bodies =
  let home = "budget" in
  let loc = Loc.point ~file 1 1 in
  let scheme = {Ty.ty=Ty.Fun ([],Ty.unit,Ty.closed,Ty.closed);
    tparams=[];names=[];reqs=[];row_reqs=[];modes=[];defaults=[]} in
  let roots = List.mapi (fun i body ->
    {Core.path=Path.make home ("ROOT" ^ string_of_int i);params=[];
      ev=Core.evidence 0;tys=[];dicts=[];scheme;body=body loc;
      test=false;generator=None;loc;origin=Core.Written;known=[]}) bodies in
  { Core.home; types=[];fns=roots;build_values=List.map (fun (f : Core.fn_def) -> f.path) roots;
    build_asserts=[];values=[];shows=[];keys=[];ops=[];method_calls=[] }

let%test_unit "each expression and direct tail dispatch costs exactly one step" =
  assert (Eval.build_step_limit = 64_100_000);
  let unit = Core.unit in
  let three loc = Core.mk (Core.Seq (unit loc, unit loc)) Ty.unit loc in
  let skipped loc =
    let expensive = three loc in
    Core.mk (Core.If (Core.mk (Bool false) Ty.bool loc, expensive, unit loc)) Ty.unit loc in
  let call loc =
    let fty = Ty.Fun ([],Ty.unit,Ty.closed,Ty.closed) in
    let callee = Core.mk (Core.Global (Path.make "budget" "ROOT1",
      {Ty.tys=[];rows=[]},[],[])) fty loc in
    Core.mk (Core.Call (callee,[],Core.evidence 0)) Ty.unit loc in
  let m = minimal_roots [call; unit; three; skipped] in
  ignore (Eval.build ~limit:3 [m]);
  let once () =
    try ignore (Eval.build ~limit:2 [m]); assert false
    with Diag.Error d ->
      assert (contains d.msg "ROOT0");
      assert (List.exists (fun s -> contains s "3 evaluation steps; the limit is 2") d.notes);
      d
  in
  assert (once () = once ());
  ignore (Eval.build ~limit:1 [minimal_roots (List.init 20 (fun _ -> unit))])

let%expect_test "frozen collections keep typed ordered data" =
  run {|let M = Map.of([("a", 1), ("b", 2), ("a", 3)])
let S = Set.of([3, 2, 3])
type Row = { bytes: Array<UInt8>, names: Array<Str> }
let ROW: Row = { bytes: [1, 2, 255], names: ["a", "b"] }
fn main() uses Console =
  print(M)
  print(S)
  print(ROW)
|};
  [%expect {|
    Map.of([("a", 3), ("b", 2)])
    Set.of([3, 2])
    Row { bytes: [1, 2, 255], names: ["a", "b"] }
    () |}]

let%expect_test "data descriptions remain descriptions until installed" =
  run {|dep Numbers =
  get: fn() -> Int
handler constant(n: Int) for Numbers =
  get() => n
let HANDLER: Numbers = constant(7)
fn main() uses Console =
  print(with HANDLER in Numbers.get())
|};
  [%expect {|
    7
    () |}]

let%test_unit "generic field defaults freeze every closed instance" =
  let modules = Driver.linked ~lint:true ~file
    "type Box<T> = { value: T, rest: Array<T> = [] }\nfn box<T>(x: T) -> Box<T> = { value: x }\nfn wrap<T>(x: T) -> Box<T> = box(x)\nfn main() =\n  let a = wrap(7)\n  let b = wrap(\"x\")\n  ()\n" in
  let entry = List.hd (List.rev modules) in
  let defaults = List.filter_map (fun (f : Core.fn_def) ->
    match f.body.kind with
    | Core.Frozen_default d -> Some d.frozen_cases
    | _ -> None) entry.fns in
  match defaults with
  | [cases] ->
      assert (List.length cases = 2);
      List.iter (fun (_, c) -> match c.Core.ckind with
        | CArray [] -> () | _ -> assert false) cases
  | _ -> assert false

let%expect_test "generic descriptions close their captured types as static code" =
  run {|dep Textual<T> =
  get: fn(value: T) -> Str
handler described<T>(x: T) for Textual<T> =
  get(value) => show(x)
let TEXT: Textual<Int> = described(7)
fn main() uses Console =
  print(with TEXT in Textual.get(0))
|};
  [%expect {|
    7
    () |}]

let%test_unit "static interpreter tables use equality until a mutation indexes them" =
  let hashes = ref 0 in
  let dict = Value.Hash {
    hash = (fun _ -> incr hashes; 0L);
    equal = (fun a b -> a = b);
  } in
  let one = Value.VInt 1L and two = Value.VInt 2L in
  let original = Table.frozen [one,two] in
  assert (Table.get dict original one = Some two);
  assert (!hashes = 0);
  let changed = Table.set dict original one one in
  assert (!hashes > 0);
  assert (Table.get dict changed one = Some one);
  assert (Table.get dict original one = Some two);
  assert (Table.to_list original = [one,two])
