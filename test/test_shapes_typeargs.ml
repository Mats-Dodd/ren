(* Explicit call-site type arguments keep declaration order across schemes,
   whose variables are independently numbered by first occurrence. *)

open Helpers

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let rejects ?(help = true) src fragments =
  let said, raised = captured (fun () -> check_error src) in
  Option.iter raise raised;
  List.iter
    (fun part -> if not (contains said part) then failwith (part ^ ":\n" ^ said))
    ("error:" :: (if help then "help:" :: fragments else fragments))

let%expect_test "explicit arguments precede value inference and keep declaration order" =
  run
    {|fn pick<A, B>(b: B, a: A) -> A = a
fn phantom<A, B, C>(x: B) -> B = x
fn id<T>(x: T) -> T = x
fn take<A, B>(b: B, a: A, n: Int = 7) -> (A, B, Int) = (a, b, n)
fn main() uses Console =
  print(pick<Int, Str>("word", 4))
  print(phantom<Str, Int, Bool>(5))
  print(id<Array<Option<Int>>>([Some(3), None]))
  print(take<Int, Str>("word", 4, n: 9))
  print(take<Int, Str>("word", 4))
  print<Int>(6)
|};
  [%expect {|
    4
    5
    [Some(3), None]
    (4, "word", 9)
    (4, "word", 7)
    6
    ()
    |}]

let%expect_test "explicit arguments in recursive groups" =
  run
    {|fn left<A, B>(b: B, a: A, n: Int) -> A =
  if n == 0 then a else right<A, B>(b, a, n - 1)
fn right<A, B>(b: B, a: A, n: Int) -> A =
  if n == 0 then a else left<A, B>(b, a, n - 1)
fn main() uses Console = print(left<Int, Str>("word", 8, 4))
|};
  [%expect {|
    8
    ()
    |}]

let%expect_test "method arguments omit the owner's parameters" =
  run
    {|type Box<T> = opaque T
  fn make<U>(ignored: U, x: T) -> Box<T> = x
  fn choose<U>(self, x: U, n: Int = 7) -> (U, Int) = (x, n)
  fn get(self) -> T = self
type Counter = opaque Int
  fn make() -> Counter = 3
  fn get(self) -> Int = self
  fn replace<U>(inout self, x: Int, ignored: U) -> Int =
    let old = self
    self = x
    old
fn main() uses Console =
  let b = Box.make<Int, Bool>(true, 3)
  print(b.choose<Str>("word", n: 9))
  print(b.choose<Bool>(false))
  print(b.get())
  var c = Counter.make()
  print(&c.replace<Str>(4, "ignored"))
  print(c.get())
|};
  [%expect {|
    ("word", 9)
    (false, 7)
    3
    3
    4
    ()
    |}]

let%expect_test "declaration mapping and unused slots survive interfaces" =
  run_files
    [
      ( "main.ren",
        {|import poly
fn main() uses Console =
  print(poly.pick<Int, Str>("word", 4))
  print(poly.phantom<Str, Int, Bool>(5))
  let b = poly.Box.make<Int, Bool>(true, 3)
  print(b.choose<Str>("word"))
|} );
      ( "poly.ren",
        {|pub fn pick<A, B>(b: B, a: A) -> A = a
pub fn phantom<A, B, C>(x: B) -> B = x
pub type Box<T> = opaque T
  pub fn make<U>(ignored: U, x: T) -> Box<T> = x
  pub fn choose<U>(self, x: U) -> U = x
|} );
    ];
  [%expect {|
    4
    5
    word
    ()
    |}]

let%expect_test "standalone type application and comparison boundaries" =
  run
    {|fn id<T>(x: T) -> T = x
fn use(f: fn(Int) -> Int) -> Int = try f(4)
fn main() uses Console =
  print((id<Int>)(3))
  print(use(id<Int>))
  print(1 < 2 && 3 > 2)
  print((1 < 2) == (3 > 2))
  print(1 <= 2 && 3 >= 2)
|};
  [%expect {|
    3
    4
    true
    true
    true
    ()
    |}];
  rejects "fn main() =\n  let a = 1\n  let b = 2\n  let c = 3\n  a < b > c\n"
    [ "split it into two comparisons" ];
  [%expect {| |}]

let%expect_test "written arity, mismatches and requirements are checked" =
  rejects "fn id<T>(x: T) -> T = x\nfn main() = id<Int, Str>(1)\n"
    [ "takes 1 explicit type argument" ];
  rejects "fn plain(x: Int) -> Int = x\nfn main() = plain<Int>(1)\n"
    [ "takes 0 explicit type arguments" ];
  rejects ~help:false "fn id<T>(x: T) -> T = x\nfn main() = id<Str>(1)\n"
    [ "Str"; "Int" ];
  rejects
    "type Box<T> = opaque T\n  fn get(self) -> T = self\nfn main() =\n  let b: Box<Int> = 1\n  b.get<Int>()\n"
    [ "takes 0 explicit type arguments" ];
  rejects
    "dep Tick =\n  tick: fn()\nfn same<T>(x: T) -> Bool = x == x\nfn wrong(x: Tick) -> Bool = same<Tick>(x)\n"
    [ "`==`"; "same" ];
  rejects
    "fn phantom<T>() -> Int = 1\nfn main() = phantom<fn(Int) -> Int>()\n"
    [ "type argument"; "block" ];
  rejects
    "fn phantom<T>() -> Int = 1\nfn main() = phantom<Result<Int, Int>>()\n"
    [ "Result"; "error set" ];
  [%expect {| |}]
