(* A type's members: its methods, associated functions and associated
   values, declared directly under the type, and called: `s.push(1)` through the
   receiver's type, `Stack.of(...)` and `Stack.empty` after the type
   (module-build.md, "Methods and operators live on the type"). *)

open Helpers

let stack =
  ( "stack.ren",
    {|
pub type Stack<T> = opaque { items: Array<T> }
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

let%expect_test "`ren types` shows a type's members under it" =
  types_files
    [
      ("main.ren", {|
import stack.{Stack}
fn main() = Stack.of([1])
|}); stack;
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

let%expect_test "members parse under their type" =
  ast (snd stack);
  [%expect
    {| (pub type Stack<T> (opaque (fields items:Array<T>)) (members (pub (fn push (self x) (& (call (. (. self items) push) x)))) (pub (fn peek (self) (block (let n (call (. (. self items) len))) (if (== n 0) (con None) (con Some (index (. self items) (- n 1))))))) (pub (fn size (self) (call (. (. self items) len)))) (pub (fn of (xs) (record Stack items=xs))) (pub let empty (record Stack items=(array))) ((fn grow (self) (block (let first (index (. self items) 0)) (& (call (. (. self items) push) first))))))) |}]

let%expect_test "members of a sum type and of an opaque type" =
  (* inside its module, an opaque type is what it's represented as, so
     its members can make one from an `Int` and give one back as an `Int` *)
  types
    {|
type Light =
  | Red
  | Green

  fn next(self) -> Light =
    match self
      Red => Green
      Green => Red
  fn all() = [Red, Green]
  fn shout(self) uses Console = print(self)

pub type UserId = opaque Int
  pub fn new(n: Int) -> UserId = n
  pub fn raw(self) -> Int = self

fn main() = 1
|};
  [%expect
    {|
    type Light
      fn next(self) -> Light
      fn all() -> Array<Light>
      fn shout(self) uses Console
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
  fn map<U>(self, f: fn(T) -> U) -> Box<U> = Box { value: try f(self.value) }
  fn put(self, x) = Box { value: x }
  fn first(self, x) = x
  let none = Box { value: None }

fn main() = 1
|};
  [%expect
    {|
    type Box<T>
      fn map<U>(self, f: fn(T) -> U) -> Box<U>
      fn put<U>(self, x: U) -> Box<U>
      fn first<U>(self, x: U) -> U
      let none: Box<Option<T>>
    fn main() -> Int
    |}]

let%expect_test "a type's interface holds its public members" =
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
        (Ren.Iface.members td))
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
  add(a, b) => Vec { x: a.x + b.x, y: a.y + b.y }
  zero => Vec { x: 0, y: 0 }

fn main() = 1
|};
  [%expect
    {|
    error: an operator is a method
      ┌─ test.ren:2:3
    2 │   add(a, b) => Vec { x: a.x + b.x, y: a.y + b.y }
      │   ^^^
      help: write `pub fn add(self, b: Vec) -> Vec = ...`

    error: an associated value is written with `let`
      ┌─ test.ren:3:3
    3 │   zero => Vec { x: 0, y: 0 }
      │   ^^^^
      help: write `pub let zero: Vec = ...`
    |}]

let%expect_test "`self` is only a method's first parameter" =
  types
    {|
type Stack = { items: Array<Int> }
  fn swap(x: Int, self) = x
  fn typed(self: Stack) = 1
  fn of() = self

fn top(self) = 1
fn main() = fn(self) => 1
|};
  [%expect
    {|
    error: `self` has to be the first parameter
      ┌─ test.ren:2:19
    2 │   fn swap(x: Int, self) = x
      │                   ^^^^
      help: move it to the front

    error: `self` is always a `Stack`, so its type isn't written
      ┌─ test.ren:3:18
    3 │   fn typed(self: Stack) = 1
      │                  ^^^^^
      help: remove the type

    error: there's no `self` here: only a method has one
      ┌─ test.ren:4:13
    4 │   fn of() = self
      │             ^^^^
      help: make `self` the first parameter of a function declared under its type

    error: `self` is only a parameter of a method, declared under its type
      ┌─ test.ren:6:8
    6 │ fn top(self) = 1
      │        ^^^^
      help: choose another name, or move the function under its type, indented, to make it a method

    error: `self` is only a parameter of a method, declared under its type
      ┌─ test.ren:7:16
    7 │ fn main() = fn(self) => 1
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

let%expect_test "a member has a name of its own" =
  types
    {|
type Stack = { items: Array<Int>, size: Int }
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
      ┌─ test.ren:2:6
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                ----- the field `items` is here
    2 │   fn items(self) = self.items
      │      ^^^^^
      help: rename one of them

    error: `Stack` has two members named `top`
      ┌─ test.ren:4:6
    3 │   fn top(self) = 1
      │      --- the first `top` is here
    4 │   fn top(self) = 2
      │      ^^^
      help: rename one of them

    error: `Stack` has a field and an associated function both named `size`
      ┌─ test.ren:5:6
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                                   ---- the field `size` is here
    5 │   fn size() = 3
      │      ^^^^
      help: rename one of them

    error: `Stack` has two members named `size`
      ┌─ test.ren:6:7
    5 │   fn size() = 3
      │      ---- the first `size` is here
    6 │   let size = 4
      │       ^^^^
      help: rename one of them

    error: `Stack` has a field and an associated value both named `size`
      ┌─ test.ren:6:7
    1 │ type Stack = { items: Array<Int>, size: Int }
      │                                   ---- the field `size` is here
    6 │   let size = 4
      │       ^^^^
      help: rename one of them
    |}]

let%expect_test "a method's type parameter can't hide its type's" =
  types
    {|
type Box<T> = { value: T }
  fn map<T>(self, f: fn(T) -> T) -> Box<T> = Box { value: f(self.value) }

fn main() = 1
|};
  [%expect
    {|
    error: there are two type parameters named `T`
      ┌─ test.ren:2:10
    1 │ type Box<T> = { value: T }
      │          - the first `T` is here
    2 │   fn map<T>(self, f: fn(T) -> T) -> Box<T> = Box { value: f(self.value) }
      │          ^
      help: rename one of them
    |}]

let%expect_test "a public item spells out its signature" =
  types
    {|
pub type Stack = opaque { items: Array<Int> }
  pub fn push(inout self, x) = &self.items.push(x)
  pub fn size(self) = self.items.len()
  pub let empty = Stack { items: [] }

pub type Box<T> = { items: Array<T> }
  pub let empty = Box { items: [] }

fn main() = 1
|};
  [%expect
    {|
    error: the parameter `x` of the public function `Stack.push` has no type
      ┌─ test.ren:2:27
    2 │   pub fn push(inout self, x) = &self.items.push(x)
      │                           ^
      = public functions spell out their full signature
      help: write `x: Int`

    error: expected `Unit`, found `Int`
      ┌─ test.ren:3:23
    3 │   pub fn size(self) = self.items.len()
      │                       ^^^^^^^^^^^^^^^^
      = a public function without `->` returns `Unit`
      help: add `-> Int` to the signature

    error: the public value `Stack.empty` has no type
      ┌─ test.ren:4:11
    4 │   pub let empty = Stack { items: [] }
      │           ^^^^^
      = public values spell out their type
      help: write `pub let empty: Stack`

    error: the public value `Box.empty` has no type
      ┌─ test.ren:7:11
    7 │   pub let empty = Box { items: [] }
      │           ^^^^^
      = public values spell out their type
      help: write `pub let empty: Box<T>`
    |}]

let%expect_test "a public type's public items can't mention a private type" =
  types
    {|
type Secret = { code: Int }

pub type Vault = { size: Int }
  pub fn open(self) -> Secret = Secret { code: self.size }
  pub let hidden: Option<Secret> = None
  fn peek(self) -> Secret = Secret { code: 0 }

fn main() = 1
|};
  [%expect
    {|
    error: `pub fn Vault.open` returns `Secret`, which is private to this module
      ┌─ test.ren:4:24
    1 │ type Secret = { code: Int }
      │      ------ `Secret` is declared here, without `pub`
    4 │   pub fn open(self) -> Secret = Secret { code: self.size }
      │                        ^^^^^^
      help: mark `Secret` `pub`

    error: `pub let Vault.hidden`'s type mentions `Secret`, which is private to this module
      ┌─ test.ren:5:26
    1 │ type Secret = { code: Int }
      │      ------ `Secret` is declared here, without `pub`
    5 │   pub let hidden: Option<Secret> = None
      │                          ^^^^^^
      help: mark `Secret` `pub`
    |}]

let%expect_test "a type's members are functions and values" =
  types {|
type Counter = { n: Int }
  var count = 0

fn main() = 1
|};
  types {|
type Counter = { n: Int }
  type Inner = { m: Int }

fn main() = 1
|};
  [%expect
    {|
    error: an associated value can't be a `var`: it's made once, and never changes
      ┌─ test.ren:2:3
    2 │   var count = 0
      │   ^^^
      help: write `let`
    error: expected `fn`, `let` or an operator, in `Counter`'s members, found `type`
      ┌─ test.ren:2:3
    2 │   type Inner = { m: Int }
      │   ^^^^
    |}]

let%expect_test "a sum type's variants end at its first member" =
  (* a blank line between them is conventional, not needed *)
  types
    {|
type Light =
  | Red
  | Green
  fn next(self) -> Light =
    match self
      Red => Green
      Green => Red

fn main() = Red.next()
|};
  types {|
type Light =
  | Red
  Green
  fn next(self) = self

fn main() = 1
|};
  [%expect
    {|
    type Light
      fn next(self) -> Light
    fn main() -> Light
    error: expected `fn`, `let` or an operator, in `Light`'s members, found `Green`
      ┌─ test.ren:3:3
    3 │   Green
      │   ^^^^^
      help: a variant starts with `|`, and the variants come first
    |}]

let%expect_test "a leftover `ops =` line says what changed" =
  types
    {|
type Counter = { n: Int }
  ops =
    fn get(self) -> Int = self.n

fn main() = 1
|};
  types
    {|
type Light =
  | Red
  | Green
  ops =
    fn next(self) = self

fn main() = 1
|};
  [%expect
    {|
    error: `ops =` is gone: a type's methods go directly under it
      ┌─ test.ren:2:3
    2 │   ops =
      │   ^^^
      help: delete this line and indent what was under it one level less
    error: `ops =` is gone: a type's methods go directly under it
      ┌─ test.ren:4:3
    4 │   ops =
      │   ^^^
      help: delete this line and indent what was under it one level less
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
fn main() uses Console =
  var s = Stack.empty
  &s.push(1)
  &s.push(s.size() + 1)
  print(s.peek())
  let t = Stack.of([7, 8, 9])
  print(t.size())
  print(stack.Stack.of([1]).size())
  [t].map(Stack.peek)[0]
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
  fn bump(inout self, by: Int) = self.n += by
  fn get(self) -> Int = self.n

type Pair = { left: Counter, right: Counter }
  fn bump_left(inout self) = &self.left.bump(1)
  let start = Pair { left: Counter { n: 0 }, right: Counter { n: 0 } }

fn main() =
  var p = Pair.start
  &p.bump_left()
  &p.right.bump(p.left.get() + 2)
  p
|};
  [%expect
    {|
    (fn Counter.bump (self/1 by/2) ev/3
      (= self/1 (update self/1 n: (+ (. self/1 n) by/2))))
    (fn Counter.get (self/1) ev/2 (. self/1 n))
    (fn Pair.bump_left (self/1) ev/2
      (let $ref/3 (. self/1 left)
        (let $result/4 (call ev/2 Counter.bump &$ref/3 1)
          (seq (= self/1 (update self/1 left: $ref/3)) $result/4))))
    (fn Pair.start () ev/1
      (record (left: (record (n: 0))) (right: (record (n: 0)))))
    (fn main () ev/1
      (let p/2 Pair.start
        (seq (call ev/1 Pair.bump_left &p/2)
          (seq
            (let $ref/3 (. p/2 right)
              (let $arg/4 (+ (call ev/1 Counter.get (. p/2 left)) 2)
                (let $result/5 (call ev/1 Counter.bump &$ref/3 $arg/4)
                  (seq (= p/2 (update p/2 right: $ref/3)) $result/5))))
            p/2))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "methods inside their own module" =
  (* a method can call its type's other methods, and itself; another
     type's method of the same name is a different one *)
  run
    {|
type Light =
  | Red
  | Green

  fn next(self) -> Light =
    match self
      Red => Green
      Green => Red
  fn after(self, n: Int) -> Light =
    if n == 0 then self else self.next().after(n - 1)

type Counter = { n: Int }
  fn next(self) -> Counter = Counter { n: self.n + 1 }

fn main() uses Console =
  let c = Counter { n: 1 }
  print([Light.Red.after(3), Light.Red.after(4)])
  print(c.next().next())
|};
  [%expect {|
    [Green, Red]
    Counter { n: 3 }
    ()
    |}]

let%expect_test "an opaque type's API is its members" =
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
  fn size(self) -> Int = self.m

type A = { n: Int }
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
  pub fn size(self) -> Int = self.m

pub type H = { b: B }

pub type A = { n: Int }
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
  fn size(self) -> Int = self.m

type A = { n: Int }
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
  fn count(self) = if self.n == 0 then 0 else down(self.n)

fn main() = mk(3).count()
|};
  (* nor does `pick` pick up `A.size`'s `Console` *)
  types
    {|
type B = { m: Int }
  fn size(self) -> Int = self.m

type A = { n: Int }
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
      fn size(self) -> Int uses Console
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
      help: remove the `&`, and use the `Int` it returns
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
  fn b(inout self) = self.n = 1
  fn c(self) = &self.b()

fn main() = 1
|};
  [%expect
    {|
    error: `self` is a parameter, so it can't be changed
      ┌─ test.ren:3:17
    3 │   fn c(self) = &self.b()
      │                 ^^^^
      help: write `inout self` to change the caller's value, or copy it with `var s = self`
    |}]

let%expect_test "a changed receiver's call isn't a place" =
  run
    {|
type C = { n: Int }
  fn pop(inout self) -> Int = self.n

fn take(inout x: Int) = x = 2

fn main() =
  var c = C { n: 1 }
  take(&c.pop())
|};
  [%expect
    {|
    error: `take` changes this argument, but `c.pop()` is a call's result, not something it can change
      ┌─ test.ren:8:8
    8 │   take(&c.pop())
      │        ^^^^^^^^
      = the `&` in `&c.pop()` marks the receiver the call changes, not the argument
      help: put it in a `var` first, and pass that
    |}]

let%expect_test "a changed receiver can't be another argument" =
  run
    {|
type Bag = { items: Array<Int> }
  fn take(inout self, other: Bag) = self.items = other.items

fn main() =
  var b = Bag { items: [1] }
  &b.take(Bag { items: [b.items[0] + 1] })
  &b.take(b)
|};
  [%expect
    {|
    error: this call changes `b`, so no other argument can use it
      ┌─ test.ren:7:11
    7 │   &b.take(b)
      │           ^
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
  fn b(inout self) = self.n = 1

fn main() =
  var c = C { n: 1 }
  let f = c.b
  1
|};
  [%expect
    {|
    error: `b` is a method, so it has to be called
      ┌─ test.ren:6:13
    6 │   let f = c.b
      │             ^
      help: write `&c.b()`, or use `C.b` as a function
    |}]

let%expect_test "a type without the method" =
  run
    {|
type Bag = { items: Array<Int> }
  fn size(self) -> Int = self.items.len()

type Empty = { n: Int }

fn main() =
  let b = Bag { items: [] }
  let e = Empty { n: 0 }
  [b.count(), e.count(), [1].size()]
|};
  run
    {|
type Bag = { items: Array<Int> }
  fn size(self) -> Int = self.items.len()

fn main() = [Bag.count(Bag { items: [] }), Bag.items]
|};
  [%expect
    {|
    error: `Bag` has no method named `count`
      ┌─ test.ren:9:6
    9 │   [b.count(), e.count(), [1].size()]
      │      ^^^^^
      help: its methods: `size`

    error: `Empty` has no method named `count`
      ┌─ test.ren:9:17
    9 │   [b.count(), e.count(), [1].size()]
      │                 ^^^^^
      help: declare it under `type Empty`, with `self` first

    error: `Array<Int>` has no method named `size`
      ┌─ test.ren:9:30
    9 │   [b.count(), e.count(), [1].size()]
      │                              ^^^^
      help: Ren calls it `len`
    error: `Bag` has no member named `count`
      ┌─ test.ren:4:18
    4 │ fn main() = [Bag.count(Bag { items: [] }), Bag.items]
      │                  ^^^^^
      help: its members: `size`

    error: `Bag` has no member named `items`
      ┌─ test.ren:4:48
    4 │ fn main() = [Bag.count(Bag { items: [] }), Bag.items]
      │                                                ^^^^^
      help: `items` is a field, so it's read from a value, like `x.items`
    |}]

let%expect_test "a receiver that could be several types" =
  types
    {|
type Bag = { items: Array<Int> }
  fn size(self) -> Int = self.items.len()

type Box = { n: Int }
  fn size(self) -> Int = 1

fn count(b) = b.size()
fn main() = count(Bag { items: [1] })
|};
  [%expect
    {|
    error: can't tell which type `b` is
      ┌─ test.ren:7:15
    7 │ fn count(b) = b.size()
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
  fn get(inout self) -> Int = self.m

type C = { m: Int }
  fn put(self) -> Int = self.m
  fn get(self) -> Int = self.m

fn four(x) = x.put
fn five(x) = x.get
fn main() = 1
|};
  [%expect
    {|
    error: `put` is a method, so it has to be called
      ┌─ test.ren:8:16
    8 │ fn four(x) = x.put
      │                ^^^
      help: write `x.put()`, or use `C.put` as a function

    error: can't tell which type `x` is
      ┌─ test.ren:9:14
    9 │ fn five(x) = x.get
      │              ^
      = `Array` and `B` and `C` and `Map` each have a method `get`
      = a method is found through its receiver's type, which has to be known where it's called
      help: annotate `x` where it's defined, like `x: B`
    |}]

let%expect_test "an associated value uses nothing" =
  types
    {|
type Log = { lines: Array<Int> }
  let noisy = Log.make()
  fn make() -> Log =
    print(1)
    Log { lines: [] }

fn main() = Log.noisy
|};
  [%expect
    {|
    error: the associated value `Log.noisy` uses `Console`
      ┌─ test.ren:2:7
    2 │   let noisy = Log.make()
      │       ^^^^^
      │               ---------- this call uses `Console`
      = an associated value is made once, when the program starts, so it can't use a dependency
      help: make it an associated function, `fn noisy() uses Console = ...`
    |}]

let%expect_test "an associated value can't need itself" =
  types
    {|
type Box = { n: Int }
  let a = Box { n: Box.b.n }
  let b = Box.make()
  fn make() -> Box = Box.a
  let c = Box { n: Box.c.n }

fn main() = Box.a
|};
  [%expect
    {|
    error: `Box.a` is made from itself: Box.a → Box.b → Box.make → Box.a
      ┌─ test.ren:2:7
    2 │   let a = Box { n: Box.b.n }
      │       ^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make one of them without the other

    error: `Box.c` is made from itself: Box.c → Box.c
      ┌─ test.ren:5:7
    5 │   let c = Box { n: Box.c.n }
      │       ^
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
    error: `Int` has no member named `foo`
      ┌─ test.ren:1:18
    1 │ fn main() = [Int.foo, Array.foo]
      │                  ^^^
      help: its members: `add`, `sub`, `mul`, `div`, `rem`, `neg`, `wrapping_add`, `wrapping_sub`, `wrapping_mul`, `wrapping_neg`

    error: `Array` has no member named `foo`
      ┌─ test.ren:1:29
    1 │ fn main() = [Int.foo, Array.foo]
      │                             ^^^
      help: its members: `len`, `push`, `sort`, `get`, `first`, `last`, `map`, `flat_map`, `select`, `reject`, `find`, `index`, `any`, `all`, `count`, `includes`, `reduce`, `sum`, `min`, `max`, `min_by`, `max_by`, `sort_by`, `group_by`, `partition`, `tally`, `uniq`, `zip`, `with_index`, `take`, `drop`, `reverse`
    |}]

let%expect_test "a value of the wrong type, in a cycle of values" =
  (* `Box.c` is shown as the value it is, not the function of no
     parameters it's checked as *)
  run
    {|
type Box = { n: Int }
  let c = Box { n: 1 }.via()
  fn via(self) -> Int = Box.c.n

fn main() = 1
|};
  [%expect
    {|
    error: `Box.c` is made from itself: Box.c → Box.via → Box.c
      ┌─ test.ren:2:7
    2 │   let c = Box { n: 1 }.via()
      │       ^
      = an associated value is made once, when the program starts, so it can't need itself to be made
      help: make one of them without the other

    error: `Box.c` is used here as `Box`, but its definition makes it `Int`
      ┌─ test.ren:3:25
    3 │   fn via(self) -> Int = Box.c.n
      │                         ^^^^^
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
  fn f(self) -> Int = self.n

fn g(x) = x.f()

fn main() = g(B { n: 1 })
|};
  [%expect
    {|
    error: can't tell which type `x` is
      ┌─ test.ren:6:11
    6 │ fn g(x) = x.f()
      │           ^
      = `A` has a field `f`, and `B` has a method `f`
      = a method is found through its receiver's type, which has to be known where it's called
      help: annotate `x` where it's defined, like `x: A`
    |}]

let%expect_test "an associated value not of its declared type" =
  run {|
type T = { n: Int }
  let a: Int = true

fn main() = T.a
|};
  [%expect
    {|
    error: expected `Int`, found `Bool`
      ┌─ test.ren:2:16
    2 │   let a: Int = true
      │                ^^^^
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
  [xs.len(), [b.items].map(Array.len)[0], b.items[0]]
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
    (fn main () ev/1
      (let b/2 (record (items: (array)))
        (seq
          (let $ref/3 (. b/2 items)
            (let $result/4 (call ev/1 Array.push &$ref/3 1)
              (seq (= b/2 (update b/2 items: $ref/3)) $result/4)))
          (call ev/1 Array.len (. b/2 items)))))
    (fn $start () ev/1 (call ev/1 main))
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
  let _ = &xs.len()
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
      ┌─ test.ren:4:11
    4 │   let _ = &xs.len()
      │           ^^^^^^^^^
      help: remove the `&`, and use the `Int` it returns

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

let%expect_test "reading part of a receiver the call changes" =
  run {|
fn main() =
  var xs = [1, 2]
  &xs.push(xs[0])
|};
  [%expect
    {|
    error: this call changes `xs`, so no other argument can use it
      ┌─ test.ren:3:12
    3 │   &xs.push(xs[0])
      │            ^^^^^
      │    -- passed with `&` here
      = an argument passed with `&` has to be the only way the call can reach that value
      = reading part of `xs` counts as using it
      help: read it into a `let` before the call, and pass that
    |}]

(* A type that keeps rules is opaque (module-build.md, "Private unless
   `pub`"): a public record or sum type can have no member that changes
   it, and none that can refuse to make one. *)

let%expect_test "an open type's method can't change it" =
  types
    {|
pub type Bank = { accounts: Map<Int, Int>, next: Int }
  pub fn size(self) -> Int = self.accounts.len()
  pub fn open(inout self) =
    self.next = self.next + 1
fn main() = ()
|};
  [%expect
    {|
    error: `Bank` is open, so `open` can't change it
      ┌─ test.ren:3:10
    3 │   pub fn open(inout self) =
      │          ^^^^
      = anyone can change an open type's fields, so a method that changes it is either a second way to do that, or a rule nobody else has to follow
      help: hide its fields: `pub type Bank = opaque { accounts: Map<Int, Int>, next: Int }`
    |}]

let%expect_test "nor can a private member of a public open type" =
  types
    {|
pub type Counter = { n: Int }
  pub fn get(self) -> Int = self.n
  fn bump(inout self) = self.n = self.n + 1
fn main() = ()
|};
  [%expect
    {|
    error: `Counter` is open, so `bump` can't change it
      ┌─ test.ren:3:6
    3 │   fn bump(inout self) = self.n = self.n + 1
      │      ^^^^
      = anyone can change an open type's fields, so a method that changes it is either a second way to do that, or a rule nobody else has to follow
      help: hide its fields: `pub type Counter = opaque { n: Int }`
    |}]

let%expect_test "an open sum type's method can't change it" =
  types
    {|
pub type Light =
  | Red
  | Green
  pub fn next(inout self) =
    self = match self
      Red => Green
      Green => Red
fn main() = ()
|};
  [%expect
    {|
    error: `Light` is open, so `next` can't change it
      ┌─ test.ren:4:10
    4 │   pub fn next(inout self) =
      │          ^^^^
      = anyone can make an open type's values, so a method that changes one is either a second way to do that, or a rule nobody else has to follow
      help: hide its constructors: declare them in a private type, `type LightState = ...`, and make this `pub type Light = opaque LightState`
    |}]

let%expect_test "an open type's constructor can't fail" =
  types
    {|
pub type Range = { lo: Int, hi: Int }
  pub fn of(lo: Int, hi: Int) -> Range ! Backwards =
    if hi < lo then fail Backwards
    Range { lo, hi }
fn main() = ()
|};
  [%expect
    {|
    error: `Range` is open, so `of` can't refuse to make one
      ┌─ test.ren:2:10
    2 │   pub fn of(lo: Int, hi: Int) -> Range ! Backwards =
      │          ^^
      = anyone can make an open type's values without calling `of`, so what it checks isn't a rule
      help: hide its fields: `pub type Range = opaque { lo: Int, hi: Int }`
    |}]

let%expect_test "nor can a private one whose errors are inferred" =
  types
    {|
pub type Range = { lo: Int, hi: Int }
  fn of(lo: Int, hi: Int) =
    if hi < lo then fail Backwards
    Range { lo, hi }
fn main() = ()
|};
  [%expect
    {|
    error: `Range` is open, so `of` can't refuse to make one
      ┌─ test.ren:2:6
    2 │   fn of(lo: Int, hi: Int) =
      │      ^^
      = anyone can make an open type's values without calling `of`, so what it checks isn't a rule
      help: hide its fields: `pub type Range = opaque { lo: Int, hi: Int }`
    |}]

let%expect_test "the help keeps a generic type's parameters" =
  types
    {|
pub type Stack<T> = { items: Array<T> }
  pub fn push(inout self, x: T) = &self.items.push(x)
pub type Tree<T> =
  | Leaf
  | Node(left: Tree<T>, value: T, right: Tree<T>)
  pub fn clear(inout self) = self = Leaf
fn main() = ()
|};
  [%expect
    {|
    error: `Stack` is open, so `push` can't change it
      ┌─ test.ren:2:10
    2 │   pub fn push(inout self, x: T) = &self.items.push(x)
      │          ^^^^
      = anyone can change an open type's fields, so a method that changes it is either a second way to do that, or a rule nobody else has to follow
      help: hide its fields: `pub type Stack<T> = opaque { items: Array<T> }`

    error: `Tree` is open, so `clear` can't change it
      ┌─ test.ren:6:10
    6 │   pub fn clear(inout self) = self = Leaf
      │          ^^^^^
      = anyone can make an open type's values, so a method that changes one is either a second way to do that, or a rule nobody else has to follow
      help: hide its constructors: declare them in a private type, `type TreeState<T> = ...`, and make this `pub type Tree<T> = opaque TreeState<T>`
    |}]

let%expect_test "what keeps no rules can stay open" =
  (* a private open type changes itself; an opaque record does; a pure
     method, a constructor that can't fail, a function that fails making
     another type, and one that fails only with what it's given *)
  types
    {|
type Draft = { n: Int }
  fn bump(inout self) = self.n = self.n + 1
pub type Account = opaque { balance: Int }
  pub fn credit(inout self, m: Int) = self.balance = self.balance + m
pub type Point = { x: Int, y: Int }
  pub fn moved(self, dx: Int) -> Point = Point { x: self.x + dx, y: self.y }
  pub fn origin() -> Point = Point { x: 0, y: 0 }
  pub fn parse(s: Str) -> Int ! Bad =
    if s == "" then fail Bad
    0
  pub fn made(f: fn() -> Point) -> Point = try f()
fn main() = ()
|};
  [%expect
    {|
    type Draft
      fn bump(inout self)
    pub type Account
      pub fn credit(inout self, m: Int)
    pub type Point
      pub fn moved(self, dx: Int) -> Point
      pub fn origin() -> Point
      pub fn parse(s: Str) -> Int ! Bad
      pub fn made(f: fn() -> Point) -> Point
    fn main()
    |}]

let%expect_test "nor one that can refuse to make a value holding one" =
  types
    {|
pub type P = { n: Int }
  pub fn make(n: Int) -> Option<P> ! Neg =
    if n < 0 then fail Neg
    Some(P { n })
fn main() = ()
|};
  [%expect
    {|
    error: `P` is open, so `make` can't refuse to make one
      ┌─ test.ren:2:10
    2 │   pub fn make(n: Int) -> Option<P> ! Neg =
      │          ^^^^
      = anyone can make an open type's values without calling `make`, so what it checks isn't a rule
      help: hide its fields: `pub type P = opaque { n: Int }`
    |}]

let%expect_test "nor one that refuses in what it returns" =
  (* `Result<P, ! Bad>` and `Option<P>` refuse as a value, as `P ! Bad`
     does with an error; a method returning `Option` of one is a question
     about a value, not a way to make one *)
  types
    {|
pub type P = { n: Int }
  pub fn mk(n: Int) -> Result<P, ! Neg> =
    if n < 0 then Err(Neg) else Ok(P { n })
pub type Q = { n: Int }
  pub fn mk(n: Int) -> Option<Q> = if n < 0 then None else Some(Q { n })
pub type Day = Mon | Tue
  pub fn next(self) -> Option<Day> =
    match self
      Mon => Some(Tue)
      Tue => None
fn main() = ()
|};
  [%expect
    {|
    error: `P` is open, so `mk` can't refuse to make one
      ┌─ test.ren:2:10
    2 │   pub fn mk(n: Int) -> Result<P, ! Neg> =
      │          ^^
      = anyone can make an open type's values without calling `mk`, so what it checks isn't a rule
      help: hide its fields: `pub type P = opaque { n: Int }`

    error: `Q` is open, so `mk` can't refuse to make one
      ┌─ test.ren:5:10
    5 │   pub fn mk(n: Int) -> Option<Q> = if n < 0 then None else Some(Q { n })
      │          ^^
      = anyone can make an open type's values without calling `mk`, so what it checks isn't a rule
      help: hide its fields: `pub type Q = opaque { n: Int }`
    |}]
