open Ren

let path = Path.make "generator_types" "values"
let cursor_path = Ty.generator_cursor path
let error_row : Ty.row = { labels = []; tail = Some 0 }

let signature : Ty.generator =
  {
    path;
    cursor_path;
    cursor_args = [ Ty.Var 0; Ty.Var 0; Ty.Errors error_row ];
    item = Ty.Var 0;
    errors = error_row;
    uses = Ty.closed;
    kind = Value_gen;
    holds_instance = false;
    replay_unsafe = false;
    params = [ Ty.read (Ty.Var 0) ];
  }

let%expect_test "a cursor retains its generic item and step error row" =
  let errors : Ty.row =
    { labels = [ { name = "Bad"; payload = [ Ty.int ] } ]; tail = None }
  in
  let cursor = Ty.Con (cursor_path, [ Ty.int; Ty.int; Ty.Errors errors ]) in
  (match Ty.generator_instance signature cursor with
  | Some (args, g) ->
      assert (args.tys = [ Ty.int ]);
      assert (args.rows = [ errors ]);
      assert (g.item = Ty.int);
      assert (g.params = [ Ty.read Ty.int ]);
      assert (g.errors = errors);
      print_endline "item and step errors preserved"
  | None -> failwith "a valid cursor instantiation was rejected");
  [%expect {| item and step errors preserved |}]

let%expect_test "cursor projections cannot disagree about one type variable" =
  let cursor = Ty.Con (cursor_path, [ Ty.int; Ty.str; Ty.Errors Ty.closed ]) in
  assert (Ty.generator_instance signature cursor = None);
  print_endline "inconsistent cursor rejected";
  [%expect {| inconsistent cursor rejected |}]

let%expect_test "a cursor cannot erase an unrepresented step row" =
  let missing = { signature with cursor_args = [ Ty.Var 0 ] } in
  assert (Ty.generator_instance missing (Ty.Con (cursor_path, [ Ty.int ])) = None);
  print_endline "missing step row rejected";
  [%expect {| missing step row rejected |}]

let%expect_test "cursor identities are nominal" =
  let other = Ty.generator_cursor (Path.make "generator_types" "other") in
  let cursor = Ty.Con (other, [ Ty.int; Ty.int; Ty.Errors Ty.closed ]) in
  assert (Ty.generator_instance signature cursor = None);
  print_endline "another producer's cursor rejected";
  [%expect {| another producer's cursor rejected |}]

let%expect_test "a written generic cursor determines its hidden frame types" =
  let cursor_path = Ty.generator_cursor ~source_params:1 path in
  let g =
    { signature with cursor_path;
      cursor_args = [ Ty.Var 0; Ty.Var 0; Ty.Var 0; Ty.Errors Ty.closed ];
      errors = Ty.closed }
  in
  assert (Ty.expand_generator_cursor g (Ty.Con (cursor_path, [ Ty.str ])) =
          Some (Ty.Con (cursor_path, [ Ty.str; Ty.str; Ty.str; Ty.Errors Ty.closed ])));
  print_endline "source argument determines the frame";
  [%expect {| source argument determines the frame |}]

let%expect_test "a stored cursor annotation cannot hide an unconstrained error row" =
  let cursor_path = Ty.generator_cursor ~source_params:1 path in
  let g =
    { signature with cursor_path;
      cursor_args = [ Ty.Var 0; Ty.Var 0; Ty.Var 0; Ty.Errors error_row ] }
  in
  assert (Ty.expand_generator_cursor g (Ty.Con (cursor_path, [ Ty.str ])) = None);
  print_endline "unexpressed step row rejected";
  [%expect {| unexpressed step row rejected |}]

let%expect_test "a fixed generator's written cursor has no hidden existential" =
  let g =
    { signature with cursor_args = [ Ty.int; Ty.int; Ty.Errors Ty.closed ];
      item = Ty.int; params = [ Ty.read Ty.int ]; errors = Ty.closed }
  in
  assert (Ty.expand_generator_cursor g (Ty.Con (cursor_path, [])) =
          Some (Ty.Con (cursor_path, g.cursor_args)));
  print_endline "fixed frame expanded";
  [%expect {| fixed frame expanded |}]

let%expect_test "generic dependency instances match after substitution reorders them" =
  let channel = Path.make "generator_types" "Chan" in
  let dep ty : Ty.dep = { dpath = channel; dargs = [ty] } in
  let row a b : Ty.row =
    { labels = Ty.sort_labels [Ty.dep_of (dep a); Ty.dep_of (dep b)]; tail = None }
  in
  let description a b = Ty.impl [dep a; dep b] (row a b) in
  let g =
    { signature with cursor_args = [Ty.Var 0; Ty.Var 1; description (Ty.Var 0) (Ty.Var 1)];
      params = []; errors = Ty.closed }
  in
  let actual = Ty.Con (cursor_path, [Ty.str; Ty.int; description Ty.str Ty.int]) in
  (match Ty.generator_instance g actual with
  | Some (args, _) -> assert (args.tys = [Ty.str; Ty.int])
  | None -> failwith "reordered dependency instances were rejected");
  (* The later cursor argument, not a declaration-order guess, decides the
     initially ambiguous labels. Failed candidates must roll back bindings. *)
  let g = { g with cursor_args = [Ty.Errors (row (Ty.Var 0) (Ty.Var 1)); Ty.Var 0] } in
  let actual = Ty.Con (cursor_path, [Ty.Errors (row Ty.int Ty.str); Ty.str]) in
  (match Ty.generator_instance g actual with
  | Some (args, _) -> assert (args.tys = [Ty.str; Ty.int])
  | None -> failwith "a later cursor constraint could not resolve row instances");
  let invalid = Ty.Con (cursor_path, [Ty.Errors (row Ty.int Ty.str); Ty.bool]) in
  assert (Ty.generator_instance g invalid = None);
  print_endline "reordered dependencies and later constraints preserved";
  [%expect {| reordered dependencies and later constraints preserved |}]
