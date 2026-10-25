Every example runs and prints what it should. A new example shows up here as
a diff; `dune promote` accepts its output.

  $ for f in *.ren; do echo "== $f"; ren run $f; done
  == blocks.ren
  21
  true
  == fib.ren
  832040
  == infer.ren
  5
  21
  true
  1
  1
  == plans.ren
  5
  Some(5)
  None
  true
  { id: 2, plan: Free }
  == values.ren
  [2, 0, 1, 10]
  [13, 11, 12]
  13
  { x: 11, y: 0 }
  { x: 1, y: 2 }
  1

infer.ren annotates nothing; this is what inference works out:

  $ ren types infer.ren
  -- infer
  fn seats(u: User) -> Int
  fn first_or<T>(o: Option<T>, fallback: T) -> T
  fn map_option<T, U>(o: Option<T>, f: fn(T) -> U) -> Option<U>
  fn twice<T>(f: fn() -> T) -> T
  fn main() uses Io

A program of several modules is a folder; its entry imports the rest:

  $ ren run two/main.ren
  4
  20
  $ ren types two/main.ren
  -- util
  pub fn double(n: Int) -> Int
  fn twice(n: Int) -> Int
  
  -- main
  fn main() -> Int uses Io

An error in one module can point into another, and shows that file's line:

  $ mkdir cycle
  $ printf 'import b\nfn main() = 1\n' > cycle/a.ren
  $ printf 'import a\npub fn f() = 1\n' > cycle/b.ren
  $ ren run cycle/a.ren
  error: import cycle: a → b → a
    ┌─ cycle/b.ren:1:1
  1 │ import a
    │ ^^^^^^^^
    ┌─ cycle/a.ren:1:1
  1 │ import b
    │ -------- `a` imports `b` here
    help: move what both modules need into a third module that both can import
  [1]

The shop is the milestone of stages 5a and 5b: six modules, a type imported
by name, a constructor name two types share, opaque types, `uses` on every
public function that needs it, and `ops`. A `Cart` has methods that change
it (called with `&`), an associated function and an associated value, and
the opaque `UserId` gets its whole API from its `ops`:

  $ ren run shop/main.ren
  { plan: Free, status: Free }
  0
  7
  2
  30
  0
  0
  30
  1030
  $ ren types shop/main.ren
  -- plan
  pub fn price(p: Plan) -> Int
  
  -- users
  pub type UserId
    pub fn new(n: Int) -> UserId
    pub fn raw(self) -> Int
  
  -- cart
  pub type Cart
    pub fn of(owner: UserId) -> Cart
    pub let guest: Cart
    pub fn put(inout self, p: Plan)
    pub fn clear(inout self)
    pub fn size(self) -> Int
    pub fn total(self) -> Int
    fn prices(self) -> Array<Int>
  fn sum(xs: Array<Int>) -> Int
  
  -- billing/stripe
  pub fn charge(amount: Int) -> ChargeId uses Io
  pub fn receipt(id: ChargeId) -> Int
  fn next_id(amount: Int) -> Int
  
  -- billing/invoice
  pub fn make(p: Plan) -> Invoice
  pub fn pay(i: Invoice) -> Option<stripe.ChargeId> uses Io
  
  -- main
  fn checkout(p: Plan) -> Int uses Io
  fn main() -> Int uses Io

Each of these breaks the shop in one way. A private function can't be
called from another module:

  $ mkdir broken && cp -RL shop/. broken/ && chmod -R u+w broken
  $ printf 'import billing/stripe\nfn main() = stripe.next_id(1)\n' > broken/private.ren
  $ ren check broken/private.ren
  error: `billing/stripe` has no public `next_id`
    ┌─ broken/private.ren:2:20
  2 │ fn main() = stripe.next_id(1)
    │                    ^^^^^^^
    help: if it's defined there, mark it `pub`
  [1]

An import nothing uses is an error:

  $ printf 'import plan\nimport billing/stripe\nfn main() = plan.price(Free)\n' > broken/unused.ren
  $ ren check broken/unused.ren
  error: `billing/stripe` is imported but never used
    ┌─ broken/unused.ren:2:1
  2 │ import billing/stripe
    │ ^^^^^^^^^^^^^^^^^^^^^
    help: remove it
  [1]

A public function has to declare what it uses:

  $ printf 'import plan\npub fn loud(p: plan.Plan) -> Int =\n  print(p)\n  plan.price(p)\nfn main() = loud(Free)\n' > broken/loud.ren
  $ ren check broken/loud.ren
  error: `loud` doesn't declare `Io`
    ┌─ broken/loud.ren:2:8
  2 │ pub fn loud(p: plan.Plan) -> Int =
    │        ^^^^
  3 │   print(p)
    │   -------- this call uses `Io`
    = a public function without `uses` uses nothing, and its body is checked against that
    help: add `uses Io`
  [1]

Two modules can't import each other:

  $ printf 'import billing/invoice\n' | cat - shop/billing/stripe.ren > broken/billing/stripe.ren
  $ ren check broken/main.ren
  error: import cycle: billing/invoice → billing/stripe → billing/invoice
    ┌─ broken/billing/stripe.ren:1:1
  1 │ import billing/invoice
    │ ^^^^^^^^^^^^^^^^^^^^^^
    ┌─ broken/billing/invoice.ren:8:1
  8 │ import billing/stripe
    │ --------------------- `billing/invoice` imports `billing/stripe` here
    help: move what both modules need into a third module that both can import
  [1]

A method that changes its receiver is called with `&`:

  $ printf 'import cart.{Cart}\nimport users.{UserId}\nfn main() =\n  var c = Cart.of(UserId.new(1))\n  c.put(Free)\n' > broken/no_amp.ren
  $ ren check broken/no_amp.ren
  error: `put` changes `c`, so the call needs `&`
    ┌─ broken/no_amp.ren:5:3
  5 │   c.put(Free)
    │   ^^^^^^^^^^^
    = `&` shows at the call that `c` is changed
    help: write `&c.put(Free)`
  [1]

and one that doesn't change it is called without:

  $ printf 'import cart.{Cart}\nimport users.{UserId}\nfn main() =\n  var c = Cart.of(UserId.new(1))\n  &c.size()\n' > broken/extra_amp.ren
  $ ren check broken/extra_amp.ren
  error: `size` doesn't change `c`
    ┌─ broken/extra_amp.ren:5:3
  5 │   &c.size()
    │   ^^^^^^^^^
    help: remove the `&`
  [1]

A private method can't be called from another module:

  $ printf 'import cart.{Cart}\nfn main() = Cart.guest.prices()\n' > broken/private_method.ren
  $ ren check broken/private_method.ren
  error: `Cart` has no public `prices`
    ┌─ broken/private_method.ren:2:24
  2 │ fn main() = Cart.guest.prices()
    │                        ^^^^^^
    help: if it's defined in `cart`, mark it `pub`
  [1]
