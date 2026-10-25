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

The shop is the stage 5a milestone: four modules, a type imported by name,
a constructor name two types share, an opaque type, and `uses` on every
public function that needs it:

  $ ren run shop/main.ren
  { plan: Free, status: Free }
  0
  30
  1030
  $ ren types shop/main.ren
  -- plan
  pub fn price(p: Plan) -> Int
  
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
