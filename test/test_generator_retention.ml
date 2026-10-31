(* The source flow analysis is independent of mode selection and lowering. *)

open Ren

let summaries src =
  let src = Helpers.clean src in
  let file = "test.ren" in
  let sink = Diag.sink () in
  let parsed = Parser.parse_program sink (Lexer.tokenize ~file src) in
  let resolved = Resolve.program sink ~home:"test" ~imports:[] parsed in
  if Diag.has_errors sink then
    failwith (String.concat "; " (List.map (fun (d : Diag.t) -> d.msg) (Diag.reported sink)));
  let definitions = Ast.functions resolved.prog
    |> List.filter (fun (f : Ast.Resolved.fn_def) -> f.fn_kind <> Ast.Ordinary_fn) in
  let table = Hashtbl.create 8 in
  List.iter (fun f -> Hashtbl.add table (Ast.fn_path "test" f) false) definitions;
  let rec round () =
    let changed = ref false in
    List.iter (fun (f : Ast.Resolved.fn_def) ->
        let path = Ast.fn_path "test" f in
        let holds = Generator_retention.analyze
            ~summary:(fun p -> Hashtbl.find table p)
            ~factory:(Hashtbl.mem table)
            ~type_of:(fun _ -> None) ~fact:(fun _ -> None) f.body in
        if holds && not (Hashtbl.find table path) then (
          Hashtbl.replace table path true;
          changed := true)) definitions;
    if !changed then round ()
  in
  round ();
  List.iter (fun f ->
      Printf.printf "%s: %b\n" (Ast.fn_name f)
        (Hashtbl.find table (Ast.fn_path "test" f))) definitions

let child = {|
dep Local =
  ping: fn()
handler local() for Local =
  ping() => ()
gen fn child() =
  with local() in
    yield 1
|}

let%expect_test "delegation and iteration inherit a child's retained instance" =
  summaries (child ^ {|
gen fn delegated() = yield from child()
gen fn iterated() =
  for x in child()
    yield x
gen fn stepped() =
  let c = child()
  let _ = c()
  yield 0
|});
  [%expect
    {|
    child: true
    delegated: true
    iterated: true
    stepped: true
    |}]

let%expect_test "unstarted, exhausted, temporary and scoped frames retain nothing" =
  summaries (child ^ {|
gen fn unstarted() =
  let c = child()
  yield 0
gen fn exhausted() =
  let c = child()
  for x in c
    ()
  yield 0
gen fn temporary() =
  let _ = child()()
  yield 0
gen fn scoped() =
  if true then
    let c = child()
    let _ = c()
    ()
  yield 0
|});
  [%expect
    {|
    child: true
    unstarted: false
    exhausted: false
    temporary: false
    scoped: false
    |}]

let%expect_test "branches and repeated loop steps preserve possible activation" =
  summaries (child ^ {|
gen fn conditional(yes) =
  let c = child()
  if yes then
    let _ = c()
    ()
  yield 0
gen fn untaken() =
  let c = child()
  if false then
    let _ = c()
    ()
  yield 0
gen fn repeated(yes) =
  let c = child()
  while yes
    yield 0
    let _ = c()
    ()
|});
  [%expect
    {|
    child: true
    conditional: true
    untaken: false
    repeated: true
    |}]

let%expect_test "a local stage's source and callback decide retention" =
  summaries (child ^ {|
gen fn pure() = yield 1
gen fn stage(src, f) =
  for x in src
    yield f(x)
gen fn pure_parent() = yield from stage(pure(), fn(x) => x)
gen fn held_parent() = yield from stage(child(), fn(x) => x)
gen fn captured() =
  let c = child()
  let step = fn() => c()
  let _ = step()
  yield 0
|});
  [%expect
    {|
    child: true
    pure: false
    stage: false
    pure_parent: false
    held_parent: true
    captured: true
    |}]

let%expect_test "retention reaches a recursive generator component" =
  summaries (child ^ {|
gen fn left(n) =
  if n > 0 then yield from right(n - 1)
gen fn right(n) =
  if n > 0 then yield from left(n - 1)
  else yield from child()
|});
  [%expect
    {|
    child: true
    left: true
    right: true
    |}]

(* Also exercise the actual inference hook and exported summaries. A mode
   refusal must be the only error, so a malformed fixture can't pass. *)
let source_mode files =
  let _, file, src, load = Helpers.program files in
  try
    ignore (Driver.types ~lint:true ~load ~file src);
    "value"
  with
  | Diag.Errors [ d ] when d.says = Some "a block, which can't be returned" -> "block"

let concrete_child = {|
dep Local =
  ping: fn()
handler local() for Local =
  ping() => ()
gen fn child() -> Int =
  with local() in
    yield 1
    yield 2
|}

let make = {|
fn make() = parent()
fn main() = ()
|}

let%expect_test "source classification follows activation and full exhaustion" =
  List.iter (fun (name, parent) ->
      Printf.printf "%s: %s\n" name
        (source_mode [ "main.ren", concrete_child ^ parent ^ make ]))
    [ "stepped", {|
gen fn parent() -> Int =
  let c = child()
  let _ = c()
  yield 0
|};
      "exhausted", {|
gen fn parent() -> Int =
  let c = child()
  for x in c
    ()
  yield 0
|};
      "unstarted", {|
gen fn parent() -> Int =
  let c = child()
  yield 0
|} ];
  [%expect
    {|
    stepped: block
    exhausted: value
    unstarted: value
    |}]

let%expect_test "source classification keeps a pure local user stage as data" =
  print_endline (source_mode [ "main.ren", {|
gen fn pure(n: Int) -> Int =
  for i in 0..n
    yield i
gen fn stage(src: fn() -> Option<Int>, f: fn(Int) -> Int) -> Int =
  for x in try src
    yield try f(x)
gen fn parent() -> Int = yield from stage(pure(2), fn(x) => x + 1)
|} ^ make ]);
  [%expect {| value |}]

let%expect_test "imported empty-row child retains its instance in the parent" =
  let producer = String.split_on_char '\n' concrete_child
    |> List.map (fun line ->
        if line = "gen fn child() -> Int =" then "pub " ^ line else line)
    |> String.concat "\n" in
  print_endline (source_mode
    [ "main.ren", {|
import producer
gen fn parent() -> Int =
  let c = producer.child()
  let _ = c()
  yield 0
|} ^ make;
      "producer.ren", producer ]);
  [%expect {| block |}]
