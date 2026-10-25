(* A type's `ops` block: its methods, associated functions and associated
   values, declared under the type, and called: `s.push(1)` through the
   receiver's type, `Stack.of(...)` and `Stack.empty` after the type
   (module-build.md, "Methods and operators live on the type"). *)

open Helpers

let stack =
  ( "stack.ren",
    {|
pub type Stack<T> = { items: Array<T> }
  ops =
    pub fn push(inout self, x: T) = &self.items.push(x)
    pub fn peek(self) -> Option<T> =
      let n = self.items.len()
      if n == 0 then None else Some(self.items[n - 1])
    pub fn size(self) -> Int = self.items.len()
    pub fn of(xs: Array<T>) -> Stack<T> = Stack { items: xs }
    pub let empty: Stack<T> = Stack { items: [] }
    fn grow(inout self) =
      let first = self.items[0]
      &self.items.push(first)
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
    {| (pub type Stack<T> (fields items:Array<T>) (ops (pub (fn push (self x) (& (call (. (. self items) push) x)))) (pub (fn peek (self) (block (let n (call (. (. self items) len))) (if (== n 0) (con None) (con Some (index (. self items) (- n 1))))))) (pub (fn size (self) (call (. (. self items) len)))) (pub (fn of (xs) (record Stack items=xs))) (pub let empty (record Stack items=(array))) ((fn grow (self) (block (let first (index (. self items) 0)) (& (call (. (. self items) push) first))))))) |}]

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
    pub fn push(inout self, x) = &self.items.push(x)
    pub fn size(self) = self.items.len()
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
    3 │     pub fn push(inout self, x) = &self.items.push(x)
      │                             ^
      = public functions spell out their full signature
      help: write `x: Int`

    error: expected `Unit`, found `Int`
      ┌─ test.ren:4:25
    4 │     pub fn size(self) = self.items.len()
      │                         ^^^^^^^^^^^^^^^^
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

(* ---- calling ----

   A method is called through its receiver's type, `s.size()`, which is
   `Stack.size(s)`; an associated function or value is written after its
   type, found through scope. *)

let%expect_test "methods, associated functions and values, from another module"
    =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() uses Io =
  var s = Stack.empty
  &s.push(1)
  &s.push(s.size() + 1)
  print(s.peek())
  let t = Stack.of([7, 8, 9])
  print(t.size())
  print(stack.Stack.of([1]).size())
  let peek = Stack.peek
  peek(t)
|}
      );
      stack;
    ];
  [%expect {|
    Some(2)
    3
    1
    Some(9)
    |}]

let%expect_test "a method call is a call of the type's function" =
  (* the receiver comes first, and `&` passes it `inout`: a place that
     isn't a plain variable goes through a temporary, as any argument
     with `&` does *)
  core
    {|
type Counter = { n: Int }
  ops =
    fn bump(inout self, by: Int) = self.n += by
    fn get(self) -> Int = self.n

type Pair = { left: Counter, right: Counter }
  ops =
    fn bump_left(inout self) = &self.left.bump(1)
    let zero = Pair { left: Counter { n: 0 }, right: Counter { n: 0 } }

fn main() =
  var p = Pair.zero
  &p.bump_left()
  &p.right.bump(p.left.get() + 2)
  p
|};
  [%expect
    {|
    (fn Counter.bump (self/1 by/2)
      (= self/1 (update self/1 n: (+ (. self/1 n) by/2))))
    (fn Counter.get (self/1) (. self/1 n))
    (fn Pair.bump_left (self/1)
      (let $ref/2 (. self/1 left)
        (let $result/3 (call Counter.bump &$ref/2 1)
          (seq (= self/1 (update self/1 left: $ref/2)) $result/3))))
    (fn Pair.zero () (record (left: (record (n: 0))) (right: (record (n: 0)))))
    (fn main ()
      (let p/1 Pair.zero
        (seq (call Pair.bump_left &p/1)
          (seq
            (let $ref/2 (. p/1 right)
              (let $arg/3 (+ (call Counter.get (. p/1 left)) 2)
                (let $result/4 (call Counter.bump &$ref/2 $arg/3)
                  (seq (= p/1 (update p/1 right: $ref/2)) $result/4))))
            p/1))))
    |}]

let%expect_test "methods inside their own module" =
  (* a method can call its type's other methods, and itself; another
     type's method of the same name is a different one *)
  run
    {|
type Light =
  | Red
  | Green
  ops =
    fn next(self) -> Light =
      match self
        Red => Green
        Green => Red
    fn after(self, n: Int) -> Light =
      if n == 0 then self else self.next().after(n - 1)

type Counter = { n: Int }
  ops =
    fn next(self) -> Counter = Counter { n: self.n + 1 }

fn main() uses Io =
  let c = Counter { n: 1 }
  print([Light.Red.after(3), Light.Red.after(4)])
  print(c.next().next())
|};
  [%expect {|
    [Green, Red]
    { n: 3 }
    ()
    |}]

let%expect_test "an opaque type's API is its ops" =
  run_files
    [
      ( "main.ren",
        {|
import users.{UserId}
fn main() =
  let id = UserId.new(42)
  id.raw() + 1
|}
      );
      ( "users.ren",
        {|
pub type UserId = opaque Int
  ops =
    pub fn new(n: Int) -> UserId = n
    pub fn raw(self) -> Int = self
|}
      );
    ];
  [%expect {| 43 |}]

let%expect_test "associated values are made in the order they need" =
  (* `b` is made from `a`, so `a` is made first, though it's declared
     after it; `c` uses `a` through a function *)
  run
    {|
type Box = { n: Int }
  ops =
    let b = Box { n: Box.a.n + 1 }
    let c = Box.twice()
    fn twice() -> Box = Box { n: Box.a.n * 2 }
    let a = Box { n: 10 }

fn main() = [Box.a.n, Box.b.n, Box.c.n]
|};
  [%expect {| [10, 11, 20] |}]

let%expect_test "a receiver whose type isn't known yet" =
  (* step 2: the one type in scope with a `size` *)
  types
    {|
type Bag = { items: Array<Int> }
  ops =
    fn size(self) -> Int = self.items.len()

fn count(b) = b.size()
fn main() = count(Bag { items: [1] })
|};
  [%expect
    {|
    type Bag
      fn size(self) -> Int
    fn count(b: Bag) -> Int
    fn main() -> Int
    |}]

let%expect_test "methods of the same name on different types" =
  (* `b.size()` calls `B.size`, since `b`'s type is written, and so
     `pick` and `A.size` aren't checked together as if they called each
     other: each use of `pick` can have its own types *)
  run
    {|
type B = { m: Int }
  ops =
    fn size(self) -> Int = self.m

type A = { n: Int }
  ops =
    fn size(self) -> Int =
      let b = B { m: 1 }
      if pick(true, b) then pick(self.n, b) else 0

fn pick(x, b: B) =
  let k = b.size()
  x

fn main() = A { n: 3 }.size()
|};
  (* `h.b`'s type isn't known until it's checked, but `B.size` and
     `A.size` are written out in full, so a dot call of either needn't
     wait for it to be checked: `pick`, checked first, sees `B.size`'s
     declaration *)
  run
    {|
fn pick(x, h) =
  let k = h.b.size()
  x

pub type B = { m: Int }
  ops =
    pub fn size(self) -> Int = self.m

pub type H = { b: B }

pub type A = { n: Int }
  ops =
    pub fn size(self) -> Int =
      let h = H { b: B { m: 1 } }
      if pick(true, h) then pick(self.n, h) else 0

fn main() = A { n: 3 }.size()
|};
  [%expect {|
    3
    3
    |}]

let%expect_test "a dot call whose receiver's type is found by inference" =
  (* `mk().size()` calls `B.size`, found through `mk`'s result, so `pick`
     doesn't call `A.size`, which has a `size` too: `pick` and `A.size`
     aren't checked together, and each use of `pick` has its own types *)
  run
    {|
type B = { m: Int }
  ops =
    fn size(self) -> Int = self.m

type A = { n: Int }
  ops =
    fn size(self) -> Int =
      if pick(true) then pick(self.n) else 0

fn mk() = B { m: 1 }

fn pick(x) =
  let k = mk().size()
  x

fn main() = A { n: 3 }.size()
|};
  (* a dot call found this way that closes a cycle puts the method and its
     caller in one group, as calling it by name would *)
  run
    {|
fn down(n) = mk(n - 1).count() + 1

fn mk(n) = A { n: n }

type A = { n: Int }
  ops =
    fn count(self) = if self.n == 0 then 0 else down(self.n)

fn main() = mk(3).count()
|};
  (* nor does `pick` pick up `A.size`'s `Io` *)
  types
    {|
type B = { m: Int }
  ops =
    fn size(self) -> Int = self.m

type A = { n: Int }
  ops =
    fn size(self) -> Int =
      print(pick(self.n))
      0

fn mk() = B { m: 1 }

fn pick(x) =
  let k = mk().size()
  x

pub fn pure() -> Int = pick(1)

fn main() = pure()
|};
  [%expect
    {|
    3
    3
    type B
      fn size(self) -> Int
    type A
      fn size(self) -> Int uses Io
    fn mk() -> B
    fn pick<T>(x: T) -> T
    pub fn pure() -> Int
    fn main() -> Int
    |}]

(* ---- calling: errors ---- *)

let%expect_test "a method that changes its receiver needs `&`" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  var s = Stack.of([1])
  s.push(1)
|}
      );
      stack;
    ];
  [%expect
    {|
    error: `push` changes `s`, so the call needs `&`
      ┌─ main.ren:4:3
    4 │   s.push(1)
      │   ^^^^^^^^^
      = `&` shows at the call that `s` is changed
      help: write `&s.push(1)`
    |}]

let%expect_test "`&` on a method that doesn't change its receiver" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  var s = Stack.of([1])
  &s.size()
|}
      );
      stack;
    ];
  [%expect
    {|
    error: `size` doesn't change `s`
      ┌─ main.ren:4:3
    4 │   &s.size()
      │   ^^^^^^^^^
      help: remove the `&`
    |}]

let%expect_test "`&` needs a receiver that can change" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  let s = Stack.of([1])
  &s.push(1)
|}
      );
      stack;
    ];
  run_files
    [
      ("main.ren", {|
import stack.{Stack}
fn main() = &Stack.of([1]).push(2)
|});
      stack;
    ];
  run_files
    [
      ("main.ren", {|
import stack.{Stack}
fn main() = &Stack.empty.push(2)
|});
      stack;
    ];
  [%expect
    {|
    error: `s` is a `let`, so it can't be changed
      ┌─ main.ren:4:4
    4 │   &s.push(1)
      │    ^
      help: declare it with `var` to change it
    error: `&` needs something it can change, but `Stack.of([1])` is a new value
      ┌─ main.ren:2:14
    2 │ fn main() = &Stack.of([1]).push(2)
      │              ^^^^^^^^^^^^^
      help: put it in a `var` first
    error: `Stack.empty` is an associated value, so it can't be changed
      ┌─ main.ren:2:14
    2 │ fn main() = &Stack.empty.push(2)
      │              ^^^^^^^^^^^
      = an associated value is made once, and never changes
      help: copy it into a `var`, and change the copy
    |}]

let%expect_test "`self` changes only with `inout self`" =
  run
    {|
type C = { n: Int }
  ops =
    fn b(inout self) = self.n = 1
    fn c(self) = &self.b()

fn main() = 1
|};
  [%expect
    {|
    error: `self` is a parameter, so it can't be changed
      ┌─ test.ren:4:19
    4 │     fn c(self) = &self.b()
      │                   ^^^^
      help: write `inout self` to change the caller's value, or copy it with `var s = self`
    |}]

let%expect_test "a changed receiver's call isn't a place" =
  run
    {|
type C = { n: Int }
  ops =
    fn pop(inout self) -> Int = self.n

fn take(inout x: Int) = x = 2

fn main() =
  var c = C { n: 1 }
  take(&c.pop())
|};
  [%expect
    {|
    error: `take` changes this argument, but `c.pop()` is a call's result, not something it can change
      ┌─ test.ren:9:8
    9 │   take(&c.pop())
      │        ^^^^^^^^
      = the `&` in `&c.pop()` marks the receiver the call changes, not the argument
      help: put it in a `var` first, and pass that
    |}]

let%expect_test "a changed receiver can't be another argument" =
  run
    {|
type Bag = { items: Array<Int> }
  ops =
    fn add(inout self, other: Bag) = self.items = other.items

fn main() =
  var b = Bag { items: [1] }
  &b.add(Bag { items: [b.items[0] + 1] })
  &b.add(b)
|};
  [%expect
    {|
    error: this call changes `b`, so no other argument can use it
      ┌─ test.ren:8:10
    8 │   &b.add(b)
      │          ^
      │    - passed with `&` here
      = an argument passed with `&` has to be the only way the call can reach that value
      help: copy it with `let` first if the call should see the value `b` had before
    |}]

let%expect_test "another module's private method" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  var s = Stack.of([1])
  &s.grow()
|}
      );
      stack;
    ];
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  var s = Stack.of([1])
  Stack.grow(&s)
|}
      );
      stack;
    ];
  [%expect
    {|
    error: `Stack<Int>` has no public `grow`
      ┌─ main.ren:4:6
    4 │   &s.grow()
      │      ^^^^
      help: if it's defined in `stack`, mark it `pub`
    error: `Stack` has no public `grow`
      ┌─ main.ren:4:9
    4 │   Stack.grow(&s)
      │         ^^^^
      help: if it's defined in `stack`, mark it `pub`
    |}]

let%expect_test "an associated function isn't a method" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  let s = Stack.of([1])
  s.of([1])
  s.empty()
|}
      );
      stack;
    ];
  [%expect
    {|
    error: `of` isn't a method (it has no `self`)
      ┌─ main.ren:4:5
    4 │   s.of([1])
      │     ^^
      help: write `Stack.of([1])`

    error: `empty` isn't a method (it's an associated value)
      ┌─ main.ren:5:5
    5 │   s.empty()
      │     ^^^^^
      help: write `Stack.empty`
    |}]

let%expect_test "a method has to be called" =
  run_files
    [
      ( "main.ren",
        {|
import stack.{Stack}
fn main() =
  let s = Stack.of([1])
  let f = s.peek
  let g = s.of
  1
|}
      );
      stack;
    ];
  [%expect
    {|
    error: `peek` is a method, so it has to be called
      ┌─ main.ren:4:13
    4 │   let f = s.peek
      │             ^^^^
      help: write `s.peek()`, or use `Stack.peek` as a function

    error: `of` is an associated function, not a field
      ┌─ main.ren:5:13
    5 │   let g = s.of
      │             ^^
      help: write `Stack.of`
    |}]

let%expect_test "a method that changes its receiver, not called" =
  run
    {|
type C = { n: Int }
  ops =
    fn b(inout self) = self.n = 1

fn main() =
  var c = C { n: 1 }
  let f = c.b
  1
|};
  [%expect
    {|
    error: `b` is a method, so it has to be called
      ┌─ test.ren:7:13
    7 │   let f = c.b
      │             ^
      help: write `&c.b()`, or use `C.b` as a function
    |}]

let%expect_test "a type without the method" =
  run
    {|
type Bag = { items: Array<Int> }
  ops =
    fn size(self) -> Int = self.items.len()

type Empty = { n: Int }

fn main() =
  let b = Bag { items: [] }
  let e = Empty { n: 0 }
  [b.count(), e.count(), [1].count()]
|};
  run
    {|
type Bag = { items: Array<Int> }
  ops =
    fn size(self) -> Int = self.items.len()

fn main() = [Bag.count(Bag { items: [] }), Bag.items]
|};
  [%expect
    {|
    error: `Bag` has no method named `count`
       ┌─ test.ren:10:6
    10 │   [b.count(), e.count(), [1].count()]
       │      ^^^^^
       help: its methods: `size`

    error: `Empty` has no method named `count`
       ┌─ test.ren:10:17
    10 │   [b.count(), e.count(), [1].count()]
       │                 ^^^^^
       help: declare it in `Empty`'s `ops` block, with `self` first

    error: `Array<Int>` has no method named `count`
       ┌─ test.ren:10:30
    10 │   [b.count(), e.count(), [1].count()]
       │                              ^^^^^
       help: its methods: `len`, `push`
    error: `Bag` has no `ops` item named `count`
      ┌─ test.ren:5:18
    5 │ fn main() = [Bag.count(Bag { items: [] }), Bag.items]
      │                  ^^^^^
      help: its `ops` items: `size`

    error: `Bag` has no `ops` item named `items`
      ┌─ test.ren:5:48
    5 │ fn main() = [Bag.count(Bag { items: [] }), Bag.items]
      │                                                ^^^^^
      help: `items` is a field, so it's read from a value, like `x.items`
    |}]

let%expect_test "a receiver that could be several types" =
  types
    {|
type Bag = { items: Array<Int> }
  ops =
    fn size(self) -> Int = self.items.len()

type Box = { n: Int }
  ops =
    fn size(self) -> Int = 1

fn count(b) = b.size()
fn main() = count(Bag { items: [1] })
|};
  [%expect
    {|
    error: can't tell which type `b` is
      ┌─ test.ren:9:15
    9 │ fn count(b) = b.size()
      │               ^
      = `Bag` and `Box` each have a method `size`
      = a method is found through its receiver's type, which has to be known where it's called
      help: annotate `b` where it's defined, like `b: Bag`
    |}]

let%expect_test "a method of a type that isn't in scope" =
  run_files
    [
      ( "main.ren",
        {|
import stack
fn sz(x) = x.size()
fn main() = sz(stack.Stack.of([1]))
|}
      );
      stack;
    ];
  [%expect
    {|
    error: no type in scope here has a method named `size`
      ┌─ main.ren:2:14
    2 │ fn sz(x) = x.size()
      │              ^^^^
      = `size` is a method of `stack.Stack`
      = a method is found through its receiver's type, which has to be known where it's called
      help: annotate `x` where it's defined, like `x: stack.Stack`
    |}]

let%expect_test "a method not called, on a receiver whose type isn't known yet"
    =
  run
    {|
type B = { m: Int }
  ops =
    fn get(inout self) -> Int = self.m

type C = { m: Int }
  ops =
    fn put(self) -> Int = self.m
    fn get(self) -> Int = self.m

fn four(x) = x.put
fn five(x) = x.get
fn main() = 1
|};
  [%expect
    {|
    error: `put` is a method, so it has to be called
       ┌─ test.ren:10:16
    10 │ fn four(x) = x.put
       │                ^^^
       help: write `x.put()`, or use `C.put` as a function

    error: can't tell which type `x` is
       ┌─ test.ren:11:14
    11 │ fn five(x) = x.get
       │              ^
       = `B` and `C` each have a method `get`
       = a method is found through its receiver's type, which has to be known where it's called
       help: annotate `x` where it's defined, like `x: B`
    |}]

let%expect_test "an associated value uses nothing" =
  types
    {|
type Log = { lines: Array<Int> }
  ops =
    let noisy = Log.make()
    fn make() -> Log =
      print(1)
      Log { lines: [] }

fn main() = Log.noisy
|};
  [%expect
    {|
    error: the associated value `Log.noisy` uses `Io`
      ┌─ test.ren:3:9
    3 │     let noisy = Log.make()
      │         ^^^^^
      │                 ---------- this call uses `Io`
      = an associated value is made once, when the program starts, so it can't use a dependency
      help: make it an associated function, `fn noisy() uses Io = ...`
    |}]

let%expect_test "an associated value can't need itself" =
  types
    {|
type Box = { n: Int }
  ops =
    let a = Box { n: Box.b.n }
    let b = Box.make()
    fn make() -> Box = Box.a
    let c = Box { n: Box.c.n }

fn main() = Box.a
|};
  [%expect
    {|
    error: `Box.a` is made from itself: Box.a → Box.b → Box.make → Box.a
      ┌─ test.ren:3:9
    3 │     let a = Box { n: Box.b.n }
      │         ^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make one of them without the other

    error: `Box.c` is made from itself: Box.c → Box.c
      ┌─ test.ren:6:9
    6 │     let c = Box { n: Box.c.n }
      │         ^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make it without using itself
    |}]

let%expect_test "a built-in type's items" =
  (* no help to mark it `pub`: the prelude's types have every item they
     will ever have *)
  run {|
fn main() = [Int.foo, Array.foo]
|};
  [%expect
    {|
    error: `Int` has no `ops` item named `foo`
      ┌─ test.ren:1:18
    1 │ fn main() = [Int.foo, Array.foo]
      │                  ^^^

    error: `Array` has no `ops` item named `foo`
      ┌─ test.ren:1:29
    1 │ fn main() = [Int.foo, Array.foo]
      │                             ^^^
      help: its `ops` items: `len`, `push`
    |}]

let%expect_test "a value of the wrong type, in a cycle of values" =
  (* `Box.c` is shown as the value it is, not the function of no
     parameters it's checked as *)
  run
    {|
type Box = { n: Int }
  ops =
    let c = Box { n: 1 }.via()
    fn via(self) -> Int = Box.c.n

fn main() = 1
|};
  [%expect
    {|
    error: `Box.c` is made from itself: Box.c → Box.via → Box.c
      ┌─ test.ren:3:9
    3 │     let c = Box { n: 1 }.via()
      │         ^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make one of them without the other

    error: `Box.c` is used here as `Box`, but its definition makes it `Int`
      ┌─ test.ren:4:27
    4 │     fn via(self) -> Int = Box.c.n
      │                           ^^^^^
      = values and functions that need each other are checked at a single type
    |}]

let%expect_test
    "an item written after its module and type parses as one name; after a \
     bare type, as a constructor's field" =
  ast {|
fn main() = stack.Stack.of(Stack.empty).size()
|};
  [%expect
    {| (fn main () (call (. (call stack.Stack.of (. (con Stack) empty)) size))) |}]

let%expect_test "a call that changes its receiver is a value like any call" =
  run
    {|
type Counter = { n: Int }
  ops =
    fn take(inout self) -> Int =
      self.n += 1
      self.n

fn twice(x: Int) = x * 2

fn main() =
  var c = Counter { n: 1 }
  let xs = [&c.take(), twice(&c.take())]
  [xs[0], xs[1], c.n]
|};
  [%expect {| [2, 6, 3] |}]

let%expect_test "a field and a method of the same name, on different types" =
  run
    {|
type A = { f: Int }

type B = { n: Int }
  ops =
    fn f(self) -> Int = self.n

fn g(x) = x.f()

fn main() = g(B { n: 1 })
|};
  [%expect
    {|
    error: can't tell which type `x` is
      ┌─ test.ren:7:11
    7 │ fn g(x) = x.f()
      │           ^
      = `A` has a field `f`, and `B` has a method `f`
      = a method is found through its receiver's type, which has to be known where it's called
      help: annotate `x` where it's defined, like `x: A`
    |}]

let%expect_test "an associated value not of its declared type" =
  run {|
type T = { n: Int }
  ops =
    let a: Int = true

fn main() = T.a
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:3:18
    3 │     let a: Int = true
      │                  ^^^^
      = `T.a` is declared to have the type `Int`
    |}]

let%expect_test "`&` before a call with no receiver" =
  run {|
fn id(xs) = xs

fn main() =
  var xs = [1]
  let ys = &id(xs)
  ys
|};
  [%expect
    {|
    error: `&` marks a method's receiver, but `id(xs)` has none
      ┌─ test.ren:5:12
    5 │   let ys = &id(xs)
      │            ^^^^^^^
      = `&` before a call marks a method's receiver as changed, like `&s.push(1)`, and an argument the call changes is marked inside it, like `f(&x)`
      help: remove the `&`
    |}]

let%expect_test "a method called on a constructor with no fields" =
  run
    {|
type Role =
  | Admin
  | Guest(n: Int)
  ops =
    fn rank(self) -> Int =
      match self
        Admin => 10
        Guest(n) => n

fn main() =
  print(Admin.rank())
  print(Guest(4).rank())
|};
  [%expect {|
    10
    4
    ()
    |}]

let%expect_test "an array's built-in methods" =
  (* `len` and `push` are built into the compiler, but called like any
     method: a pushed field goes through a temporary, as any changed
     receiver does *)
  run
    {|
type Bag = { items: Array<Int> }

fn main() =
  var xs = [1, 2]
  &xs.push(3)
  var b = Bag { items: [] }
  &b.items.push(xs.len())
  let count = Array.len
  [xs.len(), count(b.items), b.items[0]]
|};
  [%expect {| [3, 1, 3] |}];
  core
    {|
type Bag = { items: Array<Int> }

fn main() =
  var b = Bag { items: [] }
  &b.items.push(1)
  b.items.len()
|};
  [%expect
    {|
    (fn main ()
      (let b/1 (record (items: (array)))
        (seq
          (let $ref/2 (. b/1 items)
            (let $result/3 (call Array.push &$ref/2 1)
              (seq (= b/1 (update b/1 items: $ref/2)) $result/3)))
          (call Array.len (. b/1 items)))))
    |}]

let%expect_test "an array's built-in methods, called wrong" =
  run {|
fn main() =
  let xs = [1]
  &xs.push(3)
|};
  [%expect
    {|
    error: `xs` is a `let`, so it can't be changed
      ┌─ test.ren:3:4
    3 │   &xs.push(3)
      │    ^^
      help: declare it with `var` to change it
    |}];
  run {|
fn main() =
  var xs = [1]
  xs.push(2)
  &xs.len()
  xs.len
|};
  [%expect
    {|
    error: `push` changes `xs`, so the call needs `&`
      ┌─ test.ren:3:3
    3 │   xs.push(2)
      │   ^^^^^^^^^^
      = `&` shows at the call that `xs` is changed
      help: write `&xs.push(2)`

    error: `len` doesn't change `xs`
      ┌─ test.ren:4:3
    4 │   &xs.len()
      │   ^^^^^^^^^
      help: remove the `&`

    error: `len` is a method, so it has to be called
      ┌─ test.ren:5:6
    5 │   xs.len
      │      ^^^
      help: write `xs.len()`, or use `Array.len` as a function
    |}]

let%expect_test "the prelude's methods written in Ren" =
  (* `Option`'s `is_some` and `unwrap_or` are written in the prelude's
     source, and called from every module like any other module's *)
  run_files
    [
      ( "main.ren",
        {|
import lookup

fn main() =
  let found = lookup.find([3, 4], 4)
  let none: Option<Int> = None
  [found.is_some(), none.is_some(), Option.is_some(Some(1))]
|}
      );
      ( "lookup.ren",
        {|
pub fn find(xs: Array<Int>, x: Int) -> Option<Int> =
  var i = 0
  var at = None
  for y in xs
    if y == x then at = Some(i) else ()
    i += 1
  if at.is_some() then Some(at.unwrap_or(0)) else None
|}
      );
    ];
  [%expect {| [true, false, true] |}]

let%expect_test "an array's methods aren't functions" =
  run {|
fn main() =
  var xs = [1]
  push(&xs, 2)
  len(xs)
|};
  [%expect
    {|
    error: there's no function named `push`
      ┌─ test.ren:3:3
    3 │   push(&xs, 2)
      │   ^^^^
      help: `push` is a method of `Array`, so it's called with a dot: `&xs.push(...)`

    error: there's no function named `len`
      ┌─ test.ren:4:3
    4 │   len(xs)
      │   ^^^
      help: `len` is a method of `Array`, so it's called with a dot: `xs.len()`
    |}]
