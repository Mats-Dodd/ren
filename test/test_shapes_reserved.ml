(* Stage 12a's conversion members are checked at their declaration, even
   when no shape walk or call reaches them. *)

open Helpers

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let rejects src fragments =
  let src = clean src ^ "\nfn main() = ()\n" in
  let said, raised =
    captured (fun () ->
        report src (fun () -> ignore (Ren.Driver.check ~file src)))
  in
  Option.iter raise raised;
  List.iter
    (fun part ->
      if not (contains said part) then
        failwith ("missing diagnostic fragment " ^ part ^ ":\n" ^ said))
    ("error:" :: "help:" :: fragments)

let%expect_test "parse and repr run as ordinary pure members" =
  run
    {|
pub type Id = opaque { n: Int }
  pub fn parse(n: Int) -> Id ! Negative =
    if n < 0 then fail Negative
    Id { n }
  pub fn repr(self) -> Int = self.n
fn main() uses Console =
  let id = try Id.parse(42)
  print(id.repr())
  print(attempt Id.parse(-1))
|};
  [%expect {|
    42
    Err(Negative)
    ()
    |}]

let%expect_test "parse-only and repr-only conversions are allowed" =
  run
    {|
type Read = opaque { n: Int }
  fn parse(n: Int) -> Read = Read { n }
  fn get(self) -> Int = self.n
type Write = { n: Int }
  fn repr(self) -> Int = self.n
fn parse(n: Int) -> Int = n + 1
fn repr(n: Int) -> Int = n + 2
fn main() uses Console =
  print(Read.parse(1).get())
  print(Write { n: 2 }.repr())
  print(parse(3) + repr(4))
|};
  [%expect {|
    1
    2
    10
    ()
    |}]

let%expect_test "conversion types share their owner's type parameters" =
  run
    {|
type Box<T> = opaque { value: T }
  fn parse(value: T) -> Box<T> = Box { value }
  fn repr(self) -> T = self.value
fn main() uses Console =
  print(Box.parse(7).repr())
  print(Box.parse("box").repr())
|};
  [%expect {|
    7
    box
    ()
    |}]

let%expect_test "conversion signatures have their complete reserved shape" =
  let cases =
    [
      ("fn parse(self) -> Id = self", [ "without `self`" ]);
      ("fn parse() -> Id = Id { n: 0 }", [ "one argument" ]);
      ("fn parse(n: Int, m: Int) -> Id = Id { n }", [ "one argument" ]);
      ("fn parse(n) -> Id = Id { n }", [ "signature is written in full" ]);
      ("fn parse(n: Int) = Id { n }", [ "signature is written in full" ]);
      ("fn parse(inout n: Int) -> Id = Id { n }", [ "can't change" ]);
      ("fn parse(n: Int) -> Int = n", [ "makes a `Id`" ]);
      ("let parse: Int = 1", [ "associated function" ]);
      ("fn repr(n: Int) -> Int = n", [ "method" ]);
      ("fn repr(self, n: Int) -> Int = n", [ "only `self`" ]);
      ("fn repr(self) = self.n", [ "signature is written in full" ]);
      ("fn repr(inout self) -> Int = self.n", [ "can't change `self`" ]);
      ("fn repr(self) -> Int ! Bad = self.n", [ "can't fail" ]);
      ("let repr: Int = 1", [ "method" ]);
      ("fn parse<U>(n: Int) -> Id = Id { n }", [ "member type parameters" ]);
      ("fn repr<U>(self) -> Int = self.n", [ "member type parameters" ]);
    ]
  in
  List.iter
    (fun (member, fragments) ->
      rejects ("type Id = opaque { n: Int }\n  " ^ member ^ "\n") fragments)
    cases;
  print_endline "all malformed conversion signatures refused";
  [%expect {| all malformed conversion signatures refused |}]

let%expect_test "public types expose both reserved conversions" =
  List.iter
    (fun (member, name) ->
      rejects ("pub type Id = opaque { n: Int }\n  " ^ member ^ "\n")
        [ name; "has to be public" ])
    [
      ("fn parse(n: Int) -> Id = Id { n }", "parse");
      ("fn repr(self) -> Int = self.n", "repr");
    ];
  print_endline "public conversions required";
  [%expect {| public conversions required |}]

let%expect_test "both conversions have the same complete encoded type" =
  List.iter
    (fun src -> rejects src [ "parse"; "repr"; "encoded type" ])
    [
      {|type Id = opaque { n: Int }
  fn parse(n: Int) -> Id = Id { n }
  fn repr(self) -> Str = "id"
|};
      {|type Box<T, U> = opaque { left: T, right: U }
  fn parse(pair: (T, U)) -> Box<T, U> =
    let (left, right) = pair
    Box { left, right }
  fn repr(self) -> (U, T) = (self.right, self.left)
|};
      {|type Id = opaque { n: Int }
  fn parse(n: Array<Int>) -> Id = Id { n: 0 }
  fn repr(self) -> Array<Str> = []
|};
    ];
  rejects
    {|type Box<T> = opaque { value: T }
  fn parse(value: T) -> Box<Int> = Box { value: 1 }
|}
    [ "parse"; "makes a `Box<T>`" ];
  print_endline "encoded types and owner arguments checked";
  [%expect {| encoded types and owner arguments checked |}]

let%expect_test "conversion bodies cannot infer dependencies or repr errors" =
  List.iter
    (fun (member, fragments) ->
      rejects ("type Id = opaque { n: Int }\n  " ^ member ^ "\n") fragments)
    [
      ( "fn parse(n: Int) -> Id uses Console = Id { n }",
        [ "parse"; "pure"; "dependency" ] );
      ( "fn repr(self) -> Int uses Console = self.n",
        [ "repr"; "dependency" ] );
      ( "fn parse(n: Int) -> Id =\n    print(n)\n    Id { n }",
        [ "parse"; "Console"; "pure" ] );
      ( "fn repr(self) -> Int =\n    print(self.n)\n    self.n",
        [ "repr"; "Console"; "pure" ] );
      ( "fn repr(self) -> Int =\n    if self.n < 0 then fail Negative\n    self.n",
        [ "repr"; "can't fail"; "Negative" ] );
    ];
  rejects
    {|type Id = opaque { n: Int }
  fn parse(n: Int) -> Id = Id { n: noisy(n) }
fn noisy(n: Int) -> Int =
  print(n)
  n
|}
    [ "parse"; "Console"; "pure" ];
  print_endline "declared, inferred and transitive conversion effects refused";
  [%expect {| declared, inferred and transitive conversion effects refused |}]

let%expect_test "parse can infer errors while staying pure" =
  types
    {|
type Id = opaque { n: Int }
  fn parse(n: Int) -> Id =
    if n < 0 then fail Negative
    Id { n }
  fn repr(self) -> Int = self.n
fn main() = ()
|};
  [%expect {|
    type Id
      fn parse(n: Int) -> Id ! Negative
      fn repr(self) -> Int
    fn main()
    |}]

let%expect_test "encoded types expand named error sets before comparison" =
  let src =
    clean
      {|type Both = ! A | B
type Id = opaque { n: Int }
  fn parse(x: Result<Int, ! Both>) -> Id = Id { n: 0 }
  fn repr(self) -> Result<Int, ! B | A> = Ok(self.n)
fn main() = ()
|}
  in
  report src (fun () -> ignore (Ren.Driver.check ~file src));
  [%expect {| |}]

let%expect_test "try preserves a scalar conversion's nominal result" =
  run
    {|
type Id = opaque Int
  pub fn parse(n: Int) -> Id ! Negative =
    if n < 0 then fail Negative
    n
  pub fn repr(self) -> Int = self
fn main() uses Console =
  let id = try Id.parse(7)
  print(id.repr())
|};
  [%expect {|
    7
    ()
    |}]

let%expect_test "try preserves ordinary scalar opaque function results too" =
  run
    {|
type Id = opaque Int
  fn value(self) -> Int = self
fn make(n: Int) -> Id ! Negative =
  if n < 0 then fail Negative
  n
fn main() uses Console =
  let id = try make(9)
  print(id.value())
|};
  [%expect {|
    9
    ()
    |}]
