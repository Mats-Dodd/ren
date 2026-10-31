let%expect_test "separate executions keep independent cursor ownership across child tasks" =
  let suite = Ren.Driver.suite ~dir:"." ["main.ren", {|pub gen fn values() -> Int =
  yield 1
  yield 2

test "cursor ownership" =
  var original = values()
  assert &original.next() == Some(1)
  var copy = original
  assert &original.next() == Some(2)
  assert &original.next() == None
  Async.scope fn(s) =>
    s.spawn fn() =>
      var nested = copy
      assert &nested.next() == Some(2)
      assert &nested.next() == None
  assert &copy.next() == Some(2)
  assert &copy.next() == None
|}] in
  let cx = Ren.Eval.load suite.core in
  let _, home, tests = List.hd suite.files in
  let test = List.hd tests in
  let execute seed =
    match Ren.Eval.run_test cx ~fn:(Ren.Path.make home test.fn) ~real:test.real ~seed with
    | Ren.Eval.Passed, [] -> ()
    | _ -> failwith "cursor ownership changed between executions"
  in
  execute 0;
  for seed = 1 to 300 do execute seed done;
  print_endline "300 executions keep independent cursor state";
  [%expect {| 300 executions keep independent cursor state |}]
