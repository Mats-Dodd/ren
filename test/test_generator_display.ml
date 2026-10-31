(* Source cursor types expose their written parameters, never frame slots. *)

open Ren

let scheme ty : Ty.scheme =
  { ty; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }

let shown ?(names = Path.full) ty =
  Ty.show (Ty.printer ~names (scheme ty)) ty

let%expect_test "cursor private names retain source arity without exposing it" =
  let path = Path.make "trees" "walk" in
  List.iter
    (fun n ->
      let cursor = Ty.generator_cursor ~source_params:n path in
      Printf.printf "%s: %d\n"
        (Ty.generator_cursor_name cursor) (Ty.generator_cursor_arity cursor))
    [ 0; 1; 2 ];
  [%expect
    {|
    walk.Cursor: 0
    walk.Cursor: 1
    walk.Cursor: 2
    |}]

let%expect_test "cursor display hides parameter, item and error arguments" =
  let cursor = Ty.generator_cursor (Path.make "trees" "numbers") in
  let hidden_errors : Ty.row =
    { labels = [ { name = "Secret"; payload = [ Ty.str ] } ]; tail = Some 4 }
  in
  let value = Ty.Con (cursor, [ Ty.int; Ty.int; Ty.Errors hidden_errors ]) in
  print_endline (shown value);
  print_endline
    (shown ~names:(fun p -> "alias." ^ Ty.generator_cursor_name p) value);
  [%expect
    {|
    trees.numbers.Cursor
    alias.numbers.Cursor
    |}]

let%expect_test "generic cursor display keeps exactly the declared arguments" =
  let cursor = Ty.generator_cursor ~source_params:1 (Path.make "trees" "walk") in
  let value =
    Ty.Con
      (cursor, [ Ty.str; Ty.array Ty.str; Ty.str; Ty.Errors Ty.closed ])
  in
  print_endline (shown value);
  print_endline (shown (Ty.array value));
  [%expect
    {|
    trees.walk.Cursor<Str>
    Array<trees.walk.Cursor<Str>>
    |}]

let%expect_test "hidden cursor variables do not reserve printed names" =
  let cursor = Ty.generator_cursor ~source_params:1 (Path.make "trees" "walk") in
  let result =
    Ty.tuple
      [ Ty.Con (cursor, [ Ty.Var 0; Ty.Var 1; Ty.Var 1; Ty.Errors Ty.closed ]);
        Ty.Var 2 ]
  in
  let fn = Ty.Fun ([], result, Ty.closed, Ty.closed) in
  let s = { (scheme fn) with names = [ (1, "T") ] } in
  print_endline (Ty.signature ~names:Path.full ~pub:false ~name:"f" ~params:[] s);
  [%expect {| fn f<T, U>() -> (trees.walk.Cursor<T>, U) |}]

let%expect_test "hidden cursor rows do not create visible signature links" =
  let cursor = Ty.generator_cursor (Path.make "trees" "numbers") in
  let errors : Ty.row = { labels = []; tail = Some 0 } in
  let result = Ty.Con (cursor, [ Ty.int; Ty.int; Ty.Errors errors ]) in
  let fn = Ty.Fun ([], result, errors, Ty.closed) in
  print_endline
    (Ty.signature ~names:Path.full ~pub:false ~name:"f" ~params:[] (scheme fn));
  [%expect {| fn f() -> trees.numbers.Cursor |}]
