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
  User { id: 2, plan: Free }
  == values.ren
  [2, 0, 1, 10]
  [13, 11, 12]
  13
  Point { x: 11, y: 0 }
  Point { x: 1, y: 2 }
  1

infer.ren annotates nothing; this is what inference works out:

  $ ren types infer.ren
  -- infer
  fn seats(u: User) -> Int
  fn first_or<T>(o: Option<T>, fallback: T) -> T
  fn map_option<T, U>(o: Option<T>, f: fn(T) -> U uses ..d) -> Option<U> uses ..d
  fn twice<T>(f: fn() -> T uses ..d) -> T uses ..d
  fn main() uses Console

`ren core` prints the program in Core, which it runs as: every function and
lambda takes the evidence of what's installed, `ev`, which every call passes
on (deps.md, "How it runs"):

  $ ren core infer.ren
  -- infer
  (fn seats (u/1) ev/3 (match (. u/1 plan) (Free => 1) ((Pro n/2) => n/2)))
  (fn first_or (o/1 fallback/2) ev/4
    (match o/1 ((Some v/3) => v/3) (None => fallback/2)))
  (fn map_option (o/1 f/2) ev/4
    (match o/1 ((Some v/3) => (con Some (call ev/4 f/2 v/3)))
      (None => (con None))))
  (fn twice (f/1) ev/3 (let _/2 (call ev/3 f/1) (call ev/3 f/1)))
  (fn main () ev/3
    (let alice/1 (record (id: 1) (plan: (con Pro 5)))
      (seq (call ev/3 print (call ev/3 seats alice/1))
        (seq
          (call ev/3 print
            (call ev/3 first_or
              (call ev/3 map_option (con Some 20)
                (lambda (n/2) (captures) ev/4 (+ n/2 1)))
              0))
          (seq (call ev/3 print (call ev/3 first_or (con None) true))
            (call ev/3 twice
              (lambda () (captures alice/1) ev/5
                (call ev/5 print (. alice/1 id)))))))))
  (fn $start () ev/1
    (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))

A program of several modules is a folder; its entry imports the rest:

  $ ren run two/main.ren
  4
  20
  $ ren types two/main.ren
  -- util
  pub fn double(n: Int) -> Int
  fn twice(n: Int) -> Int
  
  -- main
  fn main() -> Int uses Console

`ren core` prints each module. A function over closures passes them the
evidence it's given, so there's one of it, whatever its callers' closures
use:

  $ mkdir closures
  $ printf 'pub fn twice(f: fn()) =\n  try f()\n  try f()\n' > closures/lib.ren
  $ printf 'import lib\nfn main() uses Console = lib.twice(fn() => print(1))\n' > closures/main.ren
  $ ren core closures/main.ren
  -- lib
  (fn twice (f/1) ev/2 (seq (call ev/2 f/1) (call ev/2 f/1)))
  
  -- main
  (fn main () ev/1
    (call ev/1 twice (lambda () (captures) ev/2 (call ev/2 print 1))))
  (fn $start () ev/1
    (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))

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

When `main` fails, nothing handles the error: the program prints it to
stderr and exits with status 1. What it printed before stays printed:

  $ printf 'fn freeze(id: Int) = fail Frozen(id)\nfn main() =\n  print(1)\n  try freeze(3)\n  print(2)\n' > fails.ren
  $ ren run fails.ren 2> stderr.txt
  1
  [1]
  $ cat stderr.txt
  error: Frozen(3)

The shop is the milestone of stages 5a and 5b: six modules, a type imported
by name, a constructor name two types share, opaque types, `uses` on every
public function that needs it, and methods. A `Cart` has methods that
change it (called with `&`), an associated function and an associated
value, and the opaque `UserId` gets its whole API from the members under
it. Since stage 6 a charge over the card's limit is declined, which
`checkout` handles with a `fail` arm:

  $ ren run shop/main.ren
  Invoice { plan: Free, status: Free }
  0
  7
  2
  30
  0
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
  pub fn charge(amount: Int) -> ChargeId ! Declined(Int) uses Console
  pub fn receipt(id: ChargeId) -> Int
  fn next_id(amount: Int) -> Int
  
  -- billing/invoice
  pub fn make(p: Plan) -> Invoice
  pub fn pay(i: Invoice) -> Option<stripe.ChargeId> ! Declined(Int) uses Console
  
  -- main
  fn checkout(p: Plan) -> Int uses Console
  fn main() -> Int uses Console

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
  error: `loud` doesn't declare `Console`
    ┌─ broken/loud.ren:2:8
  2 │ pub fn loud(p: plan.Plan) -> Int =
    │        ^^^^
  3 │   print(p)
    │   -------- this call uses `Console`
    = a public function without `uses` uses nothing, and its body is checked against that
    help: add `uses Console`
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
  Err(NotRecorded(85))
  Err(Underflow(1))
  2
  Err(Outside(0, 7))
  $ ren types vm/main.ren
  -- op
  pub type Op
    pub fn target(self) -> Option<Int>
  
  -- program
  pub type Program
    pub fn check(ops: Array<Op>) -> Program ! Empty | NoHalt | Outside(Int, Int)
    pub fn at(self, pc: Int) -> Op
    pub fn size(self) -> Int
  fn lands(ops: Array<Op>) ! Outside(Int, Int)
  fn inside(i: Int, n: Int) -> Bool
  
  -- stack
  pub type Stack<T>
    pub let empty: Stack<T>
    pub fn push(inout self, x: T)
    pub fn pop(inout self) -> Option<T>
    pub fn peek(self) -> Option<T>
  
  -- machine
  pub type Fault = ! Underflow(Int)
  pub type Vm
    pub let fresh: Vm
    pub fn running(self) -> Bool
    pub fn step(inout self, p: Program) ! Underflow(Int)
    pub fn run(inout self, p: Program, fuel: Int) ! Underflow(Int)
    fn push(inout self, n: Int)
    fn pop(inout self) -> Int ! Underflow(Int)
    fn binary(inout self, f: fn(Int, Int) -> Int ! ..e uses ..d) ! Underflow(Int) | ..e uses ..d
  
  -- timeline
  pub type Timeline
    pub let empty: Timeline
    pub fn record(inout self, vm: Vm)
    pub fn size(self) -> Int
    pub fn back(self, n: Int) -> Vm ! NotRecorded(Int)
    pub fn run(inout self, inout vm: Vm, p: Program, fuel: Int) ! Underflow(Int)
  
  -- programs
  pub fn factorial(n: Int) -> Array<Op>
  pub fn fibonacci(n: Int) -> Array<Op>
  
  -- main
  fn main() ! Empty | NoHalt | NotRecorded(Int) | Outside(Int, Int) | Underflow(Int) uses Console
  fn fact(n: Int) -> Int

What it says when the VM is changed in the ways a reader might try. A new
instruction isn't handled until `Vm.step` has an arm for it:

  $ cp -r vm v1 && perl -0pi -e 's/(  \| Push\(n: Int\)[^\n]*\n)/$1  | Dup\n/' v1/op.ren
  $ ren check v1/main.ren
  error: this `match` doesn't handle every `op.Op`
     ┌─ v1/machine.ren:39:5
  39 │     match p.at(self.pc)
     │     ^^^^^
     = missing: Dup
     help: add an arm for `Dup`, or a `_ =>` arm for the rest
  [1]

A method that changes its receiver is called with `&`:

  $ cp -r vm v2 && perl -0pi -e 's/    &self.stack.push\(n\)/    self.stack.push(n)/' v2/machine.ren
  $ ren check v2/main.ren
  error: `push` changes `self.stack`, so the call needs `&`
     ┌─ v2/machine.ren:70:5
  70 │     self.stack.push(n)
     │     ^^^^^^^^^^^^^^^^^^
     = `&` shows at the call that `self.stack` is changed
     help: write `&self.stack.push(n)`
  [1]

A private method can't be called from another module:

  $ cp -r vm v3 && perl -0pi -e 's/  print\(bad.steps\)[^\n]*/  let _ = &bad.pop()/' v3/main.ren
  $ ren check v3/main.ren
  error: `Vm` has no public `pop`
     ┌─ v3/main.ren:54:16
  54 │   let _ = &bad.pop()
     │                ^^^
     help: if it's defined in `machine`, mark it `pub`
  [1]

A `Program` is opaque, so an array of instructions isn't one until
`Program.check` says so:

  $ cp -r vm v4 && perl -0pi -e 's/let p = try Program.check\(programs.factorial\(5\)\)/let p: Program = programs.factorial(5)/' v4/main.ren
  $ ren check v4/main.ren
  error: expected `Program`, found `Array<op.Op>`
     ┌─ v4/main.ren:11:20
  11 │   let p: Program = programs.factorial(5)
     │                    ^^^^^^^^^^^^^^^^^^^^^
     = `Program`'s representation is private to `program`
     help: use a function from `program` to make or read one
  [1]

A call that changes `self` can't also read part of it in an argument:

  $ cp -r vm v5 && perl -0pi -e 's/let v = self.locals\[slot\]\n *&self.push\(v\)/&self.push(self.locals[slot])/' v5/machine.ren
  $ ren check v5/main.ren
  error: this call changes `self`, so no other argument can use it
     ┌─ v5/machine.ren:44:20
  44 │         &self.push(self.locals[slot])
     │                    ^^^^^^^^^^^^^^^^^
     │          ---- passed with `&` here
     = an argument passed with `&` has to be the only way the call can reach that value
     = reading part of `self` counts as using it
     help: read it into a `let` before the call, and pass that
  [1]

The bank is the milestone of stage 6: accounts, transfers that can fail,
and batches that go through whole or not at all (bank/README.md). Its
functions fail with error tags, `main` passes them on with `try`, keeps
them with `attempt` and handles them with `match`. A transfer works on a
copy of the bank and keeps it only if nothing failed:

  $ ren run bank/main.ren
  7000
  5000
  Err(Short(AccountId(2), Money(45000)))
  5000
  true
  AccountId(3)
  7000
  Err(Frozen(AccountId(3)))
  true
  Ok(())
  6500
  5500
  true
  4
  true
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
  pub type Refusal = ! Short(AccountId, Money) | Frozen(AccountId)
  pub type Account
    pub fn open(id: AccountId) -> Account
    pub fn credit(inout self, m: Money, what: Movement) ! Frozen(AccountId) uses Clock
    pub fn debit(inout self, m: Money, what: Movement) ! Frozen(AccountId) | Short(AccountId, Money) uses Clock
  
  -- bank
  pub type TransferError = ! Refusal | NoSuchAccount(AccountId) | NotPositive(Money) | SameAccount
  pub type Bank
    pub let empty: Bank
    pub fn open(inout self) -> AccountId
    pub fn deposit(inout self, to: AccountId, m: Money) ! Frozen(AccountId) | NoSuchAccount(AccountId) | NotPositive(Money) uses Clock
    pub fn transfer(inout self, t: Transfer) ! Frozen(AccountId) | NoSuchAccount(AccountId) | NotPositive(Money) | SameAccount | Short(AccountId, Money) uses Clock
    pub fn batch(inout self, ts: Array<Transfer>) ! Frozen(AccountId) | NoSuchAccount(AccountId) | NotPositive(Money) | SameAccount | Short(AccountId, Money) uses Clock
    pub fn freeze(inout self, id: AccountId) ! NoSuchAccount(AccountId)
    pub fn balance(self, id: AccountId) -> Money ! NoSuchAccount(AccountId)
    pub fn statement(self, id: AccountId) -> Array<Entry> ! NoSuchAccount(AccountId)
    pub fn total(self) -> Money
    fn find(self, id: AccountId) -> Int ! NoSuchAccount(AccountId)
  
  -- main
  fn main() ! Frozen(AccountId) | NoSuchAccount(AccountId) | NotPositive(Money) | SameAccount | Short(AccountId, Money) uses Clock, Console
  fn send(from: AccountId, to: AccountId, dollars: Int) -> Transfer
  fn cents(b: Bank, id: AccountId) -> Int ! NoSuchAccount(AccountId)
  fn worth_retrying(r: Result<Unit, ! Frozen(AccountId) | NoSuchAccount(AccountId) | NotPositive(Money) | SameAccount | Short(AccountId, Money)>) -> Bool

`Money` and `AccountId` are opaque, so neither is an `Int` outside its
module:

  $ cp -r bank b1 && perl -0pi -e 's/print\(try cents\(acme, alice\)\)( *\/\/ 7000\n  print\(try cents\(acme, bob\)\))/print(try acme.balance(alice) + 5)$1/' b1/main.ren
  $ ren check b1/main.ren
  error: expected `Int`, found `Money`
     ┌─ b1/main.ren:18:13
  18 │   print(try acme.balance(alice) + 5)                   // 7000
     │             ^^^^^^^^^^^^^^^^^^^
     = `+` works on `Int`s
     = `Money`'s representation is private to `money`
     help: use a function from `money` to make or read one
  [1]
  $ cp -r bank b2 && perl -0pi -e 's/&acme.deposit\(bob, Money.dollars\(20\)\)/&acme.deposit(2, Money.dollars(20))/' b2/main.ren
  $ ren check b2/main.ren
  error: expected `AccountId`, found `Int`
     ┌─ b2/main.ren:14:21
  14 │   try &acme.deposit(2, Money.dollars(20))
     │                     ^
     = `AccountId`'s representation is private to `account`
     help: use a function from `account` to make or read one
  [1]

Freezing an account changes the bank, so the call says so:

  $ cp -r bank b3 && perl -0pi -e 's/&acme.freeze\(carol\)/acme.freeze(carol)/' b3/main.ren
  $ ren check b3/main.ren
  error: `freeze` changes `acme`, so the call needs `&`
     ┌─ b3/main.ren:31:7
  31 │   try acme.freeze(carol)
     │       ^^^^^^^^^^^^^^^^^^
     = `&` shows at the call that `acme` is changed
     help: write `&acme.freeze(carol)`
  [1]

A new way for a transfer to fail has to be handled wherever its errors
are told apart. The compiler points at each place that has to decide what
to do about it:

  $ cp -r bank b4 && perl -0pi -e 's/( \| SameAccount)\n/$1 | TooLarge(amount: Money)\n/; s/(    let i = try self.find\(t.from\))/    if t.amount.in_cents() > 1000000 then fail TooLarge(t.amount)\n$1/' b4/bank.ren
  $ ren check b4/main.ren
  error: this `match` doesn't handle every error it can fail with
     ┌─ b4/main.ren:32:3
  32 │   match &acme.transfer(send(alice, carol, 10))
     │   ^^^^^
     = missing: fail TooLarge(_)
     help: add an arm for `fail TooLarge(_)`, or a `fail _ =>` arm for the rest, or pass them on with `try match`
  
  error: this `match` doesn't handle every `Result`
     ┌─ b4/main.ren:68:3
  68 │   match r
     │   ^^^^^
     = missing: Err(TooLarge(_))
     help: add an arm for `Err(TooLarge(_))`, or a `_ =>` arm for the rest
  [1]

A public function can't take a type other modules can't name:

  $ cp -r bank b5 && perl -0pi -e 's/pub type Transfer/type Transfer/' b5/bank.ren
  $ ren check b5/main.ren
  error: `pub fn Bank.transfer` takes `Transfer`, which is private to this module
     ┌─ b5/bank.ren:34:34
  13 │ type Transfer = { from: AccountId, to: AccountId, amount: Money }
     │      -------- `Transfer` is declared here, without `pub`
  34 │   pub fn transfer(inout self, t: Transfer) ! TransferError uses Clock =
     │                                  ^^^^^^^^
     help: mark `Transfer` `pub`
  
  error: `pub fn Bank.batch`'s signature mentions `Transfer`, which is private to this module
     ┌─ b5/bank.ren:45:38
  13 │ type Transfer = { from: AccountId, to: AccountId, amount: Money }
     │      -------- `Transfer` is declared here, without `pub`
  45 │   pub fn batch(inout self, ts: Array<Transfer>) ! TransferError uses Clock =
     │                                      ^^^^^^^^
     help: mark `Transfer` `pub`
  [1]

The same new failure, left out of `TransferError`: a public function's
signature lists exactly what it can fail with, so `transfer` is wrong now:

  $ cp -r bank b6 && perl -0pi -e 's/(    let i = try self.find\(t.from\))/    if t.amount.in_cents() > 1000000 then fail TooLarge(t.amount)\n$1/' b6/bank.ren
  $ ren check b6/main.ren
  error: `pub fn Bank.transfer` can fail with `TooLarge`, but its signature doesn't say so
     ┌─ b6/bank.ren:34:10
  34 │   pub fn transfer(inout self, t: Transfer) ! TransferError uses Clock =
     │          ^^^^^^^^
  37 │     if t.amount.in_cents() > 1000000 then fail TooLarge(t.amount)
     │                                           ----------------------- this fails with `TooLarge`
     = `Bank.transfer` can only fail with what's after its `!`
     help: add `TooLarge(Money)` after `!`, or handle it here with `match`
  [1]

Every call that can fail is marked, so freezing without `try` says what
it can fail with:

  $ cp -r bank b7 && perl -0pi -e 's/try &acme.freeze\(carol\)/&acme.freeze(carol)/' b7/main.ren
  $ ren check b7/main.ren
  error: `freeze` can fail, and nothing handles it
     ┌─ b7/main.ren:31:4
  31 │   &acme.freeze(carol)
     │    ^^^^^^^^^^^^^^^^^^
     │    ----------- it can fail with `NoSuchAccount(AccountId)`
     help: pass the errors on with `try`, or handle them with `match`
  [1]

A value can't be thrown away without a word:

  $ cp -r bank b8 && perl -0pi -e 's/print\(acme.total\(\) == Money.dollars\(120\)\)/acme.total()/' b8/main.ren
  $ ren check b8/main.ren
  error: `total` returns `Money`, and this throws it away
     ┌─ b8/main.ren:54:3
  54 │   acme.total()       // true
     │   ^^^^^^^^^^^^
     = `Money`'s representation is private to `money`
     help: use it, or write `let _ = ...` if you mean to drop it
  [1]

A `fail` arm on a call that can't fail handles nothing:

  $ cp -r bank b9 && perl -0pi -e 's/  print\(acme.total\(\) == Money.dollars\(120\)\)[^\n]*\n/  match acme.total()\n    t => print(t)\n    fail NoSuchAccount(_) => print(0)\n/' b9/main.ren
  $ ren check b9/main.ren
  error: nothing here can fail, so this `fail` arm can never match
     ┌─ b9/main.ren:56:5
  56 │     fail NoSuchAccount(_) => print(0)
     │     ^^^^^^^^^^^^^^^^^^^^^
     = a `fail` arm matches an error of what the `match` looks at
     help: remove the `fail` arms
  [1]

If `main` passes the frozen account's error on instead of handling it, the
program stops there:

  $ cp -r bank b10 && perl -0pi -e 's/match (&acme.transfer\(send\(alice, carol, 10\)\))\n(    [^\n]*\n)+/try $1\n/' b10/main.ren
  $ ren run b10/main.ren 2> stderr.txt
  7000
  5000
  Err(Short(AccountId(2), Money(45000)))
  5000
  true
  [1]
  $ cat stderr.txt
  error: Frozen(AccountId(3))

Stamping an entry reads the clock, so a public signature that drops
`uses Clock` is wrong, and the error points at the call that reads it:

  $ cp -r bank b11 && perl -0pi -e 's/(pub fn credit[^\n]*) uses Clock =/$1 =/' b11/account.ren
  $ ren check b11/main.ren
  error: `Account.credit` doesn't declare `Clock`
     ┌─ b11/account.ren:39:10
  39 │   pub fn credit(inout self, m: Money, what: Movement) ! Frozen(account: AccountId) =
     │          ^^^^^^
  42 │     &self.statement.push(Entry { at: Clock.now(), what })
     │                                      ----------- this call uses `Clock`
     = a public function without `uses` uses nothing, and its body is checked against that
     help: add `uses Clock`
  [1]

`ren test` runs a program's tests (deps.md, "Tests"): every module's in a
folder, each with the test `Clock`, `Random` and `Console`. A count of how
many passed ends it, and how long that took:

  $ mkdir tested
  $ cat > tested/dice.ren <<'END'
  > // a die, and a cup of them
  > pub fn roll() -> Int uses Random = Random.int(6) + 1
  > 
  > pub fn cup(n: Int) -> Array<Int> uses Random =
  >   var rolls = []
  >   if n > 0 then
  >     rolls = cup(n - 1)
  >   &rolls.push(roll())
  >   rolls
  > 
  > test "a roll is a die's" =
  >   let r = roll()
  >   assert r >= 1 && r <= 6
  > 
  > test "a cup holds as many as it's asked for" =
  >   print(cup(3))
  >   assert cup(3).len() == 3
  > 
  > test "the system clock has started" uses Clock =
  >   assert Clock.now().after(Time.epoch)
  > END
  $ cat > tested/clock.ren <<'END'
  > pub group conforms(c: Clock) with c =
  >   test "now never goes back" =
  >     let t = Clock.now()
  >     Clock.sleep(Duration.seconds(1))
  >     assert not Clock.now().before(t)
  >   test "sleeping moves it on" =
  >     let t = Clock.now()
  >     Clock.sleep(Duration.seconds(1))
  >     assert Clock.now() == t.plus(Duration.seconds(1))
  > 
  > group "frozen" = conforms(Clock.frozen(Time.epoch))
  > group "test clock" = conforms(test_clock(Time.epoch))
  > END
  $ ren test tested | tail -1 | sed 's/[0-9]*ms$/Nms/'
  5 passed, 2 failed in Nms

Leaving out how long they took, a test that uses no real dependency
prints the same on every run; it exits with 1 if any failed:

  $ export REN_NO_TIMINGS=1
  $ ren test tested
  clock.ren
    frozen
      ✓ now never goes back
      ✗ sleeping moves it on
    test clock
      ✓ now never goes back
      ✓ sleeping moves it on
  
  dice.ren
    ✓ a roll is a die's
    ✗ a cup holds as many as it's asked for
    ✓ the system clock has started
  
  ──── frozen / sleeping moves it on ── clock.ren:9
    │
  9 │     assert Clock.now() == t.plus(Duration.seconds(1))
    │            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    │
    left:  Time(0)
    right: Time(1000)
                ^ differs here
  
    seed 8783 · rerun: ren test tested --only "frozen / sleeping" --seed 8783
  
  ──── a cup holds as many as it's asked for ── dice.ren:17
     │
  17 │   assert cup(3).len() == 3
     │          ^^^^^^^^^^^^^^^^^
     │
     left:  4
     right: 3
            ^ differs here
  
     seed 6461 · rerun: ren test tested --only "a cup" --seed 6461
  
     printed:
       [6, 2, 2, 1]
  
  5 passed, 2 failed
  [1]

The rerun runs just that one, with its seed:

  $ ren test tested --only "a cup" --seed 6461 | head -3
  dice.ren
    ✗ a cup holds as many as it's asked for
  

`--list` lists the tests without running them, and says which use a real
dependency:

  $ ren test tested --list
  clock.ren
    frozen
      now never goes back
      sleeping moves it on
    test clock
      now never goes back
      sleeping moves it on
  
  dice.ren
    a roll is a die's
    a cup holds as many as it's asked for
    the system clock has started · uses the real `Clock`

Fixed, they all pass:

  $ perl -pi -e 's/^  &rolls/    &rolls/' tested/dice.ren
  $ ren test tested/dice.ren
  dice.ren
    ✓ a roll is a die's
    ✓ a cup holds as many as it's asked for
    ✓ the system clock has started
  
  3 passed

`--only` that matches no test's name fails, since a mistyped name isn't a
pass, and a flag without its value says what it needs:

  $ ren test tested --only "a cop"
  
  no test's name has "a cop" in it
  [1]
  $ ren test tested --only
  error: --only needs the text to look for in the tests' names, like --only "a deposit"
  [2]
  $ ren test tested --seed
  error: --seed needs a number, like --seed 42
  [2]

A folder in the one tested that holds a program of its own, with a
`main`, finds its imports from itself, so it isn't part of this program;
its tests are left out, with a note that says how to run them:

  $ mkdir -p outer/inner
  $ cat > outer/sums.ren <<'END'
  > test "sums" =
  >   assert 1 + 1 == 2
  > END
  $ cat > outer/inner/main.ren <<'END'
  > import parts
  > fn main() = print(parts.two())
  > END
  $ cat > outer/inner/parts.ren <<'END'
  > pub fn two() -> Int = 2
  > test "two" =
  >   assert two() == 2
  > END
  $ ren test outer
  note: outer/inner holds a program of its own, so its tests aren't run here: run them with `ren test outer/inner`
  sums.ren
    ✓ sums
  
  1 passed
  $ ren test outer/inner
  parts.ren
    ✓ two
  
  1 passed

The bank is the milestone of stage 7 too: its statements are stamped by
`Clock.now()`, and its modules carry their tests. They use the test
`Clock` and `Console` and need no `with`: one checks each way the bank
says no, with `attempt`, one runs `main` and checks what it printed, and
`clocks.ren` runs a conformance group against two clocks:

  $ ren test bank
  bank.ren
    ✓ a deposit is stamped with the time
    ✓ a transfer moves money, and stamps both sides
    ✓ an overdraft is refused, and nothing moves
    ✓ a frozen account takes nothing in
    ✓ an account that doesn't exist is refused
    ✓ only a positive amount moves
    ✓ an account can't send to itself
    ✓ a batch that fails moves nothing
  
  clocks.ren
    frozen
      ✓ now never goes back
      ✓ an instant never goes back
      ✓ sleeping doesn't move it back
    test clock
      ✓ now never goes back
      ✓ an instant never goes back
      ✓ sleeping doesn't move it back
  
  main.ren
    ✓ main prints the balances, and every refusal
  
  15 passed

If `covers` only checks the balance isn't negative, an account can go
below zero. The tests that check nothing moved show the two banks, and
`main`'s shows what it printed before it stopped:

  $ cp -r bank b12 && perl -pi -e 's/= self >= m$/= self >= 0/' b12/money.ren
  $ ren test b12
  bank.ren
    ✓ a deposit is stamped with the time
    ✓ a transfer moves money, and stamps both sides
    ✗ an overdraft is refused, and nothing moves
    ✓ a frozen account takes nothing in
    ✓ an account that doesn't exist is refused
    ✓ only a positive amount moves
    ✓ an account can't send to itself
    ✗ a batch that fails moves nothing
  
  clocks.ren
    frozen
      ✓ now never goes back
      ✓ an instant never goes back
      ✓ sleeping doesn't move it back
    test clock
      ✓ now never goes back
      ✓ an instant never goes back
      ✓ sleeping doesn't move it back
  
  main.ren
    ✗ main prints the balances, and every refusal
  
  ──── an overdraft is refused, and nothing moves ── bank.ren:115
      │
  115 │   assert acme == before
      │          ^^^^^^^^^^^^^^
      │
      left:  Bank { accounts: [Account { id: AccountId(1), balance: Money(-100), frozen: false, statement: [Entry { at: Time(0), what: Deposited(Money(1000)) }, Entry { at: Time(0), what: Sent(Money(1100), AccountId(2)) }] }, Account { id: AccountId(2), balance: Money(1100), frozen: false, statement: [Entry { at: Time(0), what: Received(Money(1100), AccountId(1)) }] }], next: 3 }
      right: Bank { accounts: [Account { id: AccountId(1), balance: Money(1000), frozen: false, statement: [Entry { at: Time(0), what: Deposited(Money(1000)) }] }, Account { id: AccountId(2), balance: Money(0), frozen: false, statement: [] }], next: 3 }
                                                                          ^ differs here
  
      seed 3529 · rerun: ren test b12 --only "an overdraft" --seed 3529
  
  ──── a batch that fails moves nothing ── bank.ren:161
      │
  161 │   assert acme == before
      │          ^^^^^^^^^^^^^^
      │
      left:  Bank { accounts: [Account { id: AccountId(1), balance: Money(1100), frozen: false, statement: [Entry { at: Time(0), what: Deposited(Money(1000)) }, Entry { at: Time(0), what: Sent(Money(500), AccountId(2)) }, Entry { at: Time(0), what: Received(Money(600), AccountId(2)) }] }, Account { id: AccountId(2), balance: Money(-100), frozen: false, statement: [Entry { at: Time(0), what: Received(Money(500), AccountId(1)) }, Entry { at: Time(0), what: Sent(Money(600), AccountId(1)) }] }], next: 3 }
      right: Bank { accounts: [Account { id: AccountId(1), balance: Money(1000), frozen: false, statement: [Entry { at: Time(0), what: Deposited(Money(1000)) }] }, Account { id: AccountId(2), balance: Money(0), frozen: false, statement: [] }], next: 3 }
                                                                           ^ differs here
  
      seed 119 · rerun: ren test b12 --only "a batch" --seed 119
  
  ──── main prints the balances, and every refusal ── main.ren:59
     │
  59 │   print(not s[3].at.before(s[0].at))              // true
     │             ^^^^
     │
     panic: index 3 is out of bounds for an array of length 3
  
     seed 5578 · rerun: ren test b12 --only "main prints" --seed 5578
  
     printed:
       7000
       5000
       Ok(())
       -45000
       false
       AccountId(3)
       7000
       Err(Short(AccountId(2), Money(44500)))
       true
       Err(Short(AccountId(2), Money(44500)))
       7000
       -45000
       true
       3
  
  12 passed, 3 failed
  [1]

The price lookup puts a cache with expiry in front of a supplier that a
rate limiter guards (prices/README.md). Each piece is a dependency, and
`main` stacks them with one `with`:

  $ ren run prices/main.ren
  3
  3
  5
  throttled
  8
  unknown
  $ ren test prices
  cache.ren
    ✓ a second ask is answered from the cache
    ✓ an old entry is asked for again
    ✓ an unknown item isn't kept
    ✓ a cached answer doesn't count against the limit
  
  limiter.ren
    ✓ calls up to the limit go through
    ✓ one more is throttled until the window ends
    ✓ a new window lets calls through again
    ✓ a burst goes through, and then one call each time a token comes
    ✓ tokens build up to the burst, and no more
  
  main.ren
    ✓ main prints each price, or what stopped it
  
  10 passed
