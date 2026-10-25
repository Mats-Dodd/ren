(* A type's `ops` block: its methods, associated functions and associated
   values, declared under the type (module-build.md, "Methods and
   operators live on the type"). Calling them arrives in the next step of
   stage 5b; these tests are about declaring them. *)

open Helpers

let stack =
  ( "stack.ren",
    {|
pub type Stack<T> = { items: Array<T> }
  ops =
    pub fn push(inout self, x: T) = push(&self.items, x)
    pub fn peek(self) -> Option<T> =
      let n = len(self.items)
      if n == 0 then None else Some(self.items[n - 1])
    pub fn size(self) -> Int = len(self.items)
    pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
    pub let empty: Stack<T> = Stack { items: [] }
    fn grow(inout self) =
      let first = self.items[0]
      push(&self.items, first)
|}
  )

let%expect_test "`ren types` shows a type's ops under it" =
  types_files
    [
      ("main.ren", {|
import stack.{Stack}
fn main() = Stack { items: [1] }
|});
      stack;
    ];
  [%expect
    {|
    -- stack
    pub type Stack<T>
      pub fn push(inout self, x: T)
      pub fn peek(self) -> Option<T>
      pub fn size(self) -> Int
      pub fn of(xs: Array<T>) -> Stack<T>
      pub let empty: Stack<T>
      fn grow(inout self)

    -- main
    fn main() -> Stack<Int>
    |}]

let%expect_test "an ops block parses under its type" =
  ast (snd stack);
  [%expect
    {| (pub type Stack<T> (fields items:Array<T>) (ops (pub (fn push (self x) (call push (& (. self items)) x))) (pub (fn peek (self) (block (let n (call len (. self items))) (if (== n 0) (con None) (con Some (index (. self items) (- n 1))))))) (pub (fn size (self) (call len (. self items)))) (pub (fn of (xs) (record Stack items=xs))) (pub let empty (record Stack items=(array))) ((fn grow (self) (block (let first (index (. self items) 0)) (call push (& (. self items)) first)))))) |}]

let%expect_test "ops on a sum type and on an opaque type" =
  (* inside its module, an opaque type is what it's represented as, so
     its ops can make one from an `Int` and give one back as an `Int` *)
  types
    {|
type Light =
  | Red
  | Green
  ops =
    fn next(self) -> Light =
      match self
        Red => Green
        Green => Red
    fn all() = [Red, Green]
    fn show(self) uses Io = print(self)

pub type UserId = opaque Int
  ops =
    pub fn new(n: Int) -> UserId = n
    pub fn raw(self) -> Int = self

fn main() = 1
|};
  [%expect
    {|
    type Light
      fn next(self) -> Light
      fn all() -> Array<Light>
      fn show(self) uses Io
    pub type UserId
      pub fn new(n: Int) -> UserId
      pub fn raw(self) -> Int
    fn main() -> Int
    |}]

let%expect_test "a method's own type parameters, and inferred ones" =
  (* the type's `T` is in scope in the whole block, and isn't listed after
     a method's name; a variable inference finds gets another name *)
  types
    {|
type Box<T> = { value: T }
  ops =
    fn map<U>(self, f: fn(T) -> U) -> Box<U> = Box { value: f(self.value) }
    fn with(self, x) = Box { value: x }
    fn first(self, x) = x
    let none = Box { value: None }

fn main() = 1
|};
  [%expect
    {|
    type Box<T>
      fn map<U>(self, f: fn(T) -> U) -> Box<U>
      fn with<U>(self, x: U) -> Box<U>
      fn first<U>(self, x: U) -> U
      let none: Box<Option<T>>
    fn main() -> Int
    |}]

let%expect_test "a type's interface holds its public ops items" =
  let src = clean (snd stack) ^ "fn main() = 1\n" in
  let i = Ren.Driver.interface ~file:"stack.ren" src in
  List.iter
    (fun (td : Ren.Iface.type_decl) ->
      List.iter
        (fun (o : Ren.Iface.op) ->
          Printf.printf "%s.%s: %s\n" td.path.name o.oname
            (match o.okind with
            | Method -> "a method"
            | Function -> "an associated function"
            | Value -> "an associated value"))
        td.ops)
    i.types;
  [%expect
    {|
    Stack.push: a method
    Stack.peek: a method
    Stack.size: a method
    Stack.of: an associated function
    Stack.empty: an associated value
    |}]

(* ---- errors ---- *)

let%expect_test "operators are reserved for stage 9" =
  types
    {|
type Vec = { x: Int, y: Int }
  ops =
    add(a, b) => Vec { x: a.x + b.x, y: a.y + b.y }
    zero => Vec { x: 0, y: 0 }

fn main() = 1
|};
  [%expect
    {|
    error: operators like `add` arrive in stage 9
      ┌─ test.ren:3:5
    3 │     add(a, b) => Vec { x: a.x + b.x, y: a.y + b.y }
      │     ^^^
      help: for now, write a method: `fn add(self, ...) = ...`

    error: operators like `zero` arrive in stage 9
      ┌─ test.ren:4:5
    4 │     zero => Vec { x: 0, y: 0 }
      │     ^^^^
      help: for now, write an associated value: `let zero = ...`
    |}]

let%expect_test "`self` is only a method's first parameter" =
  types
    {|
type Stack = { items: Array<Int> }
  ops =
    fn swap(x: Int, self) = x
    fn typed(self: Stack) = 1
    fn of() = self

fn top(self) = 1
fn main() = fn(self) => 1
|};
  [%expect
    {|
    error: `self` has to be the first parameter
      ┌─ test.ren:3:21
    3 │     fn swap(x: Int, self) = x
      │                     ^^^^
      help: move it to the front

    error: `self` is always a `Stack`, so its type isn't written
      ┌─ test.ren:4:20
    4 │     fn typed(self: Stack) = 1
      │                    ^^^^^
      help: remove the type

    error: there's no `self` here: only a method has one
      ┌─ test.ren:5:15
    5 │     fn of() = self
      │               ^^^^
      help: make `self` the first parameter, of a function in its type's `ops` block

    error: `self` is only a parameter of a method, in an `ops` block
      ┌─ test.ren:7:8
    7 │ fn top(self) = 1
      │        ^^^^
      help: choose another name, or move the function into its type's `ops` block to make it a method

    error: `self` is only a parameter of a method, in an `ops` block
      ┌─ test.ren:8:16
    8 │ fn main() = fn(self) => 1
      │                ^^^^
      help: choose another name
    |}]

let%expect_test "`self` can't name anything else" =
  types {|
fn main() =
  let self = 1
  self
|};
  [%expect
    {|
    error: `self` is reserved for the first parameter of a method
      ┌─ test.ren:2:7
    2 │   let self = 1
      │       ^^^^
      help: choose another name
    |}]

let%expect_test "an ops item has a name of its own" =
  types
    {|
type Stack = { items: Array<Int>, size: Int }
  ops =
    fn items(self) = self.items
    fn top(self) = 1
    fn top(self) = 2
    fn size() = 3
    let size = 4

fn main() = 1
|};
  [%expect
    {|
    error: `Stack` has a field and a method both named `items`
      ┌─ test.ren:3:8
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                ----- the field `items` is here
    3 │     fn items(self) = self.items
      │        ^^^^^
      help: rename one of them

    error: `Stack` has two `ops` items named `top`
      ┌─ test.ren:5:8
    4 │     fn top(self) = 1
      │        --- the first `top` is here
    5 │     fn top(self) = 2
      │        ^^^
      help: rename one of them

    error: `Stack` has a field and an associated function both named `size`
      ┌─ test.ren:6:8
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                                   ---- the field `size` is here
    6 │     fn size() = 3
      │        ^^^^
      help: rename one of them

    error: `Stack` has two `ops` items named `size`
      ┌─ test.ren:7:9
    6 │     fn size() = 3
      │        ---- the first `size` is here
    7 │     let size = 4
      │         ^^^^
      help: rename one of them

    error: `Stack` has a field and an associated value both named `size`
      ┌─ test.ren:7:9
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                                   ---- the field `size` is here
    7 │     let size = 4
      │         ^^^^
      help: rename one of them
    |}]

let%expect_test "a method's type parameter can't hide its type's" =
  types
    {|
type Box<T> = { value: T }
  ops =
    fn map<T>(self, f: fn(T) -> T) -> Box<T> = Box { value: f(self.value) }

fn main() = 1
|};
  [%expect
    {|
    error: there are two type parameters named `T`
      ┌─ test.ren:3:12
    1 │ type Box<T> = { value: T }
      │          - the first `T` is here
    3 │     fn map<T>(self, f: fn(T) -> T) -> Box<T> = Box { value: f(self.value) }
      │            ^
      help: rename one of them
    |}]

let%expect_test "a public item spells out its signature" =
  types
    {|
pub type Stack = { items: Array<Int> }
  ops =
    pub fn push(inout self, x) = push(&self.items, x)
    pub fn size(self) = len(self.items)
    pub let empty = Stack { items: [] }

pub type Box<T> = { items: Array<T> }
  ops =
    pub let empty = Box { items: [] }

fn main() = 1
|};
  [%expect
    {|
    error: the parameter `x` of the public function `Stack.push` has no type
      ┌─ test.ren:3:29
    3 │     pub fn push(inout self, x) = push(&self.items, x)
      │                             ^
      = public functions spell out their full signature
      help: write `x: Int`

    error: expected `Unit`, found `Int`
      ┌─ test.ren:4:25
    4 │     pub fn size(self) = len(self.items)
      │                         ^^^^^^^^^^^^^^^
      = a public function without `->` returns `Unit`
      help: add `-> Int` to the signature

    error: the public value `Stack.empty` has no type
      ┌─ test.ren:5:13
    5 │     pub let empty = Stack { items: [] }
      │             ^^^^^
      = public values spell out their type
      help: write `pub let empty: Stack`

    error: the public value `Box.empty` has no type
      ┌─ test.ren:9:13
    9 │     pub let empty = Box { items: [] }
      │             ^^^^^
      = public values spell out their type
      help: write `pub let empty: Box<T>`
    |}]

let%expect_test "a public type's public items can't mention a private type" =
  types
    {|
type Secret = { code: Int }

pub type Vault = { size: Int }
  ops =
    pub fn open(self) -> Secret = Secret { code: self.size }
    pub let hidden: Option<Secret> = None
    fn peek(self) -> Secret = Secret { code: 0 }

fn main() = 1
|};
  [%expect
    {|
    error: `pub fn Vault.open` returns `Secret`, which is private to this module
      ┌─ test.ren:5:26
    1 │ type Secret = { code: Int }
      │      ------ `Secret` is declared here, without `pub`
    5 │     pub fn open(self) -> Secret = Secret { code: self.size }
      │                          ^^^^^^
      help: mark `Secret` `pub`

    error: `pub let Vault.hidden`'s type mentions `Secret`, which is private to this module
      ┌─ test.ren:6:28
    1 │ type Secret = { code: Int }
      │      ------ `Secret` is declared here, without `pub`
    6 │     pub let hidden: Option<Secret> = None
      │                            ^^^^^^
      help: mark `Secret` `pub`
    |}]

let%expect_test "an ops block holds functions and values" =
  types {|
type Counter = { n: Int }
  ops =
    var count = 0

fn main() = 1
|};
  types
    {|
type Counter = { n: Int }
  ops =
    type Inner = { m: Int }

fn main() = 1
|};
  types {|
type Counter = { n: Int }
  ops = 1

fn main() = 1
|};
  [%expect
    {|
    error: an associated value can't be a `var`: it's made once, and never changes
      ┌─ test.ren:3:5
    3 │     var count = 0
      │     ^^^
      help: write `let`
    error: expected `fn`, `let` or an operator, in the `ops` block, found `type`
      ┌─ test.ren:3:5
    3 │     type Inner = { m: Int }
      │     ^^^^
    error: expected the items of the `ops` block, found the number `1`
      ┌─ test.ren:2:9
    2 │   ops = 1
      │         ^
      help: put each item on its own line, indented under `ops =`
    |}]
