open Helpers

let%expect_test "a contained initializer panic wins over cursor cleanup panic" =
  run {|gen fn guarded_data() -> Int =
  finally(r) =>
    match r
      Err(Cancelled) =>
        let xs = [0]
        let _ = xs[5]
        try r
      _ => try r
  yield 1
  yield 2

dep Vault =
  get: fn() -> Int

handler vault() for Vault =
  var saved = guarded_data()
  let stepped = &saved.next()
  var broken = [0][9]
  get() => broken

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    with vault() in
      print(Vault.get()))
|};
  [%expect {|
    Err(Panicked("index 9 is out of bounds for an array of length 1"))
    ()
    |}]

let%expect_test "a failed initializer transfers its cursor error payload to the caller" =
  run {|gen fn guarded_data() -> Int =
  yield 1
  yield 2

dep Vault =
  get: fn() -> Int

handler vault() for Vault =
  var saved = guarded_data()
  let stepped = &saved.next()
  var broken: Int = fail Oops(saved)
  get() => broken

fn main() uses Console, Async =
  print(attempt Async.isolate fn() =>
    match attempt with vault() in Vault.get()
      Ok(n) => print(n)
      Err(Oops(value)) =>
        var cursor = value
        print(&cursor.next())
        print(&cursor.next()))
|};
  [%expect {|
    Some(2)
    None
    Ok(())
    ()
    |}]
