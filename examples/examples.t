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
public function that needs it, and methods. A `Cart` has methods that change
it (called with `&`), an associated function and an associated value, and
the opaque `UserId` gets its whole API from the members under it:

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

The VM is a stack machine and a timeline of every state it has been in
(vm/README.md). Rewinding is reading an old copy, and the copy never
changes:

  $ ren run vm/main.ren
  [120]
  true
  65
  true
  true
  [0, 1, 1, 2, 3]
  [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]
  true
  Failed(Underflow(1))
  false
  $ ren types vm/main.ren
  -- op
  pub type Op
    pub fn target(self) -> Option<Int>
  
  -- program
  pub type Program
    pub let halt: Program
    pub fn check(ops: Array<Op>) -> Option<Program>
    pub fn at(self, pc: Int) -> Op
    pub fn size(self) -> Int
  fn lands(ops: Array<Op>) -> Bool
  fn inside(i: Int, n: Int) -> Bool
  
  -- stack
  pub type Stack<T>
    pub let empty: Stack<T>
    pub fn push(inout self, x: T)
    pub fn pop(inout self) -> Option<T>
    pub fn peek(self) -> Option<T>
  
  -- machine
  pub type Vm
    pub let fresh: Vm
    pub fn running(self) -> Bool
    pub fn step(inout self, p: Program)
    pub fn run(inout self, p: Program, fuel: Int)
    fn push(inout self, n: Int)
    fn binary(inout self, f: fn(Int, Int) -> Int)
    fn underflow(inout self)
  
  -- timeline
  pub type Timeline
    pub let empty: Timeline
    pub fn record(inout self, vm: Vm)
    pub fn size(self) -> Int
    pub fn back(self, n: Int) -> Option<Vm>
    pub fn run(inout self, inout vm: Vm, p: Program, fuel: Int)
  
  -- programs
  pub fn factorial(n: Int) -> Array<Op>
  pub fn fibonacci(n: Int) -> Array<Op>
  
  -- main
  fn main() uses Io
  fn load(ops: Array<Op>) -> Program
  fn fact(n: Int) -> Int

What it says when the VM is changed in the ways a reader might try. A new
instruction isn't handled until `Vm.step` has an arm for it:

  $ cp -r vm v1 && perl -0pi -e 's/(  \| Push\(n: Int\)[^\n]*\n)/$1  | Dup\n/' v1/op.ren
  $ ren check v1/main.ren
  error: this `match` doesn't handle every `op.Op`
     ┌─ v1/machine.ren:40:5
  40 │     match p.at(self.pc)
     │     ^^^^^
     = missing: Dup
     help: add an arm for `Dup`, or a `_ =>` arm for the rest
  [1]

A method that changes its receiver is called with `&`:

  $ cp -r vm v2 && perl -0pi -e 's/    &self.stack.push\(n\)/    self.stack.push(n)/' v2/machine.ren
  $ ren check v2/main.ren
  error: `push` changes `self.stack`, so the call needs `&`
     ┌─ v2/machine.ren:76:5
  76 │     self.stack.push(n)
     │     ^^^^^^^^^^^^^^^^^^
     = `&` shows at the call that `self.stack` is changed
     help: write `&self.stack.push(n)`
  [1]

A private method can't be called from another module:

  $ cp -r vm v3 && perl -0pi -e 's/  print\(bad.status\)[^\n]*/  &bad.underflow()/' v3/main.ren
  $ ren check v3/main.ren
  error: `Vm` has no public `underflow`
     ┌─ v3/main.ren:51:8
  51 │   &bad.underflow()
     │        ^^^^^^^^^
     help: if it's defined in `machine`, mark it `pub`
  [1]

A `Program` is opaque, so an array of instructions isn't one until
`Program.check` says so:

  $ cp -r vm v4 && perl -0pi -e 's/let p = load\(programs.factorial\(5\)\)/let p: Program = programs.factorial(5)/' v4/main.ren
  $ ren check v4/main.ren
  error: expected `Program`, found `Array<Op>`
     ┌─ v4/main.ren:12:20
  12 │   let p: Program = programs.factorial(5)
     │                    ^^^^^^^^^^^^^^^^^^^^^
     = `Program`'s representation is private to `program`
     help: use a function from `program` to make or read one
  [1]

A call that changes `self` can't also read part of it in an argument:

  $ cp -r vm v5 && perl -0pi -e 's/let v = self.locals\[slot\]\n *&self.push\(v\)/&self.push(self.locals[slot])/' v5/machine.ren
  $ ren check v5/main.ren
  error: this call changes `self`, so no other argument can use it
     ┌─ v5/machine.ren:45:20
  45 │         &self.push(self.locals[slot])
     │                    ^^^^^^^^^^^^^^^^^
     │          ---- passed with `&` here
     = an argument passed with `&` has to be the only way the call can reach that value
     = reading part of `self` counts as using it
     help: read it into a `let` before the call, and pass that
  [1]

The bank: accounts, transfers that can be refused, and batches that go
through whole or not at all (bank/README.md). A transfer works on a copy of
the bank and keeps it only if every step went through:

  $ ren run bank/main.ren
  None
  7000
  5000
  Some(Short(2, 45000))
  5000
  true
  Some(Frozen(3))
  7000
  Some(Frozen(3))
  true
  None
  6500
  5500
  true
  4
  $ ren types bank/main.ren
  -- money
  pub type Money
    pub let zero: Money
    pub fn cents(n: Int) -> Money
    pub fn dollars(n: Int) -> Money
    pub fn plus(self, m: Money) -> Money
    pub fn minus(self, m: Money) -> Money
    pub fn covers(self, m: Money) -> Bool
    pub fn positive(self) -> Bool
    pub fn in_cents(self) -> Int
  
  -- account
  pub type AccountId
    pub fn of(n: Int) -> AccountId
  pub type Refusal
    pub fn worth_retrying(self) -> Bool
  pub type Account
    pub fn open(id: AccountId) -> Account
    pub fn credit(inout self, m: Money, e: Entry) -> Option<Refusal>
    pub fn debit(inout self, m: Money, e: Entry) -> Option<Refusal>
  
  -- bank
  pub type Bank
    pub let empty: Bank
    pub fn open(inout self) -> AccountId
    pub fn deposit(inout self, to: AccountId, m: Money) -> Option<Refusal>
    pub fn transfer(inout self, t: Transfer) -> Option<Refusal>
    pub fn batch(inout self, ts: Array<Transfer>) -> Option<Refusal>
    pub fn freeze(inout self, id: AccountId) -> Option<Refusal>
    pub fn balance(self, id: AccountId) -> Option<Money>
    pub fn statement(self, id: AccountId) -> Array<Entry>
    pub fn total(self) -> Money
    fn find(self, id: AccountId) -> Option<Int>
  
  -- main
  fn main() uses Io
  fn send(from: AccountId, to: AccountId, dollars: Int) -> Transfer
  fn cents(b: Bank, id: AccountId) -> Int
  fn retry(why: Option<Refusal>) -> Bool

`Money` and `AccountId` are opaque, so neither is an `Int` outside its
module:

  $ cp -r bank b1 && perl -0pi -e 's/print\(cents\(acme, alice\)\)( *\/\/ 7000\n  print\(cents\(acme, bob\)\))/print(acme.balance(alice).unwrap_or(Money.zero) + 5)$1/' b1/main.ren
  $ ren check b1/main.ren
  error: expected `Int`, found `Money`
     ┌─ b1/main.ren:19:9
  19 │   print(acme.balance(alice).unwrap_or(Money.zero) + 5)                       // 7000
     │         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
     = `+` works on `Int`s
     = `Money`'s representation is private to `money`
     help: use a function from `money` to make or read one
  [1]
  $ cp -r bank b2 && perl -0pi -e 's/&acme.deposit\(bob, Money.dollars\(20\)\)/&acme.deposit(2, Money.dollars(20))/' b2/main.ren
  $ ren check b2/main.ren
  error: expected `AccountId`, found `Int`
     ┌─ b2/main.ren:15:25
  15 │   let _ = &acme.deposit(2, Money.dollars(20))
     │                         ^
     = `AccountId`'s representation is private to `account`
     help: use a function from `account` to make or read one
  [1]

Freezing an account changes the bank, so the call says so:

  $ cp -r bank b3 && perl -0pi -e 's/&acme.freeze\(carol\)/acme.freeze(carol)/' b3/main.ren
  $ ren check b3/main.ren
  error: `freeze` changes `acme`, so the call needs `&`
     ┌─ b3/main.ren:30:11
  30 │   let _ = acme.freeze(carol)
     │           ^^^^^^^^^^^^^^^^^^
     = `&` shows at the call that `acme` is changed
     help: write `&acme.freeze(carol)`
  [1]

A new kind of refusal has to be handled wherever refusals are told apart:

  $ cp -r bank b4 && perl -0pi -e 's/(  \| SameAccount\n)/$1  | Closed(account: AccountId)\n/' b4/account.ren
  $ ren check b4/main.ren
  error: this `match` doesn't handle every `Refusal`
     ┌─ b4/account.ren:22:5
  22 │     match self
     │     ^^^^^
     = missing: Closed(_)
     help: add an arm for `Closed(_)`, or a `_ =>` arm for the rest
  [1]

A public function can't take a type other modules can't name:

  $ cp -r bank b5 && perl -0pi -e 's/pub type Transfer/type Transfer/' b5/bank.ren
  $ ren check b5/main.ren
  error: `pub fn Bank.transfer` takes `Transfer`, which is private to this module
     ┌─ b5/bank.ren:30:34
  12 │ type Transfer = { from: AccountId, to: AccountId, amount: Money }
     │      -------- `Transfer` is declared here, without `pub`
  30 │   pub fn transfer(inout self, t: Transfer) -> Option<Refusal> =
     │                                  ^^^^^^^^
     help: mark `Transfer` `pub`
  
  error: `pub fn Bank.batch`'s signature mentions `Transfer`, which is private to this module
     ┌─ b5/bank.ren:48:38
  12 │ type Transfer = { from: AccountId, to: AccountId, amount: Money }
     │      -------- `Transfer` is declared here, without `pub`
  48 │   pub fn batch(inout self, ts: Array<Transfer>) -> Option<Refusal> =
     │                                      ^^^^^^^^
     help: mark `Transfer` `pub`
  [1]
