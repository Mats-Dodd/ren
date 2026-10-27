`ren console <module>` reads a line at a time inside a module, from the
program's folder: each line is a `let`, a `var` or an expression, and an
expression's value is printed with its type. It's inside the module, so
its private items and its opaque types' representations are in reach,
and it runs on the test implementations of the built-ins:

  $ cd bank
  $ cat > session <<'END'
  > var a = Account.open(AccountId.of(1))
  > a.balance
  > &a.freeze()
  > a
  > :t Account.credit
  > attempt &a.credit(Money.dollars(5), Deposited(Money.dollars(5)))
  > Clock.now()
  > END
  $ ren console account < session
  account> var a = Account.open(AccountId.of(1))
  account> a.balance
  Money(0) : Money
  account> &a.freeze()
  account> a
  Account(id: AccountId(1), balance: Money(0), frozen: true, statement: []) : Account
  account> :t Account.credit
  fn(inout Account, Money, Movement) ! Frozen(AccountId) uses Clock
  account> attempt &a.credit(Money.dollars(5), Deposited(Money.dollars(5)))
  Err(Frozen(AccountId(1))) : Result<Unit, ! Frozen(AccountId)>
  account> Clock.now()
  Time(0) : Time
  account> 

A line that doesn't check, or panics, is reported and left out, and the
session goes on. The session runs again from its first line each time,
on the same test implementations, so what a line prints is shown once,
and what one that panics printed before it did is shown too:

  $ cat > session <<'END'
  > let x: Int = "no"
  > 1 / 0
  > print(1)
  > print(2)
  > (print(3), 1 / 0)
  > let n = 5
  > n * 2
  > :x
  > :q
  > print(3)
  > END
  $ ren console account < session
  account> let x: Int = "no"
  error: expected `Int`, found `Str`
    ┌─ <console>:1:14
  1 │ let x: Int = "no"
    │              ^^^^
  account> 1 / 0
  error: panic: division by zero
    ┌─ <console>:1:1
  1 │ 1 / 0
    │ ^^^^^
  account> print(1)
  1
  account> print(2)
  2
  account> (print(3), 1 / 0)
  3
  error: panic: division by zero
    ┌─ <console>:1:12
  1 │ (print(3), 1 / 0)
    │            ^^^^^
  account> let n = 5
  account> n * 2
  10 : Int
  account> :x
  error: there's no console command `:x`
    help: `:t <expression>` shows its type, `:q` quits
  account> :q

A private function, or member, is in reach too:

  $ cat > session <<'END'
  > var acme = Bank.empty
  > let id = &acme.open()
  > try acme.get(id)
  > END
  $ ren console bank < session
  bank> var acme = Bank.empty
  bank> let id = &acme.open()
  bank> try acme.get(id)
  Account(id: AccountId(1), balance: Money(0), frozen: false, statement: []) : Account
  bank> 

The module can be named from outside its folder, which is then the
program's, as it is for `ren check dir/main.ren`:

  $ (cd .. && echo 'Money.zero' | ren console bank/account)
  account> Money.zero
  Money(0) : Money
  account> 

`--real` gives a line the real implementation of a built-in instead:

  $ echo 'Clock.now() > Time.epoch' | ren console account --real Clock
  account> Clock.now() > Time.epoch
  true : Bool
  account> 

Each real call is made once. The session keeps what the real built-ins
gave each line, and gives it back when the session runs again, so an
earlier line's output isn't printed again and its process isn't run
again:

  $ cat > session <<'END'
  > print("once")
  > attempt Proc.run("sh", ["-c", "echo ran >> log.txt"])
  > let n = 2
  > n + 1
  > END
  $ ren console account --real Console,Proc < session
  account> print("once")
  once
  account> attempt Proc.run("sh", ["-c", "echo ran >> log.txt"])
  Ok(0) : Result<Int, ! CantRun(Str, Str) | Killed(Str) | NoSuchProgram(Str)>
  account> let n = 2
  account> n + 1
  3 : Int
  account> 
  $ cat log.txt
  ran
  $ rm log.txt

  $ ren console account --real Users
  error: `--real` names a built-in dependency with a real implementation, and only `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc` have one, not `Users`
  [2]

A dependency that isn't a built-in is installed in the line itself:

  $ cd ../prices
  $ cat > session <<'END'
  > try Prices.price("apple")
  > END
  $ ren console cache < session
  cache> try Prices.price("apple")
  error: nothing installs `Prices` in the console
    ┌─ <console>:1:1
  1 │ try Prices.price("apple")
    │ ^^^^^^^^^^^^^^^^^^^^^^^^^ the console gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os` and `Proc`, and what controls them
    │     --------------------- this call uses `Prices`
    help: install one in the line: `with counting() in ...`
  cache> 

An error a `try` passes up stops the line, as a panic does, with how to
see it as a value:

  $ echo 'try Fs.read_str(Path.of("nothing"))' | ren console cache
  cache> try Fs.read_str(Path.of("nothing"))
  error: the line failed with `NoSuchFile(nothing)`
    ┌─ <console>:1:1
  1 │ try Fs.read_str(Path.of("nothing"))
    │ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    help: see it as a value: `attempt Fs.read_str(Path.of("nothing"))`
  cache> 

`:t` doesn't run its expression, so it needs nothing installed, and a
message points into the line as it was typed:

  $ cat > session <<'END'
  > :t try Prices.price("apple")
  > :t   1 + "a"
  > :t
  > END
  $ ren console cache < session
  cache> :t try Prices.price("apple")
  Int
  cache> :t   1 + "a"
  error: `Int` has no `+` that takes a `Str`
    ┌─ <console>:1:6
  1 │ :t   1 + "a"
    │      ^^^^^^^
    = `+` is found on its left side's type, `Int`
  cache> :t
  error: `:t` needs an expression to show the type of
    help: write it after `:t`, `:t 1 + 2`
  cache> 

The console is where a test that reaches past the interface is sent, so
it opens anyway, and it can use the module's test items:

  $ cd ..
  $ mkdir explore && cd explore
  $ cat > s.ren <<'END'
  > fn secret() -> Int = 42
  > 
  > pub fn f() -> Int = 1
  > 
  > test fn helper() -> Int = 7
  > 
  > test "reaches in" = assert secret() == 42
  > END
  $ ren test s.ren
  error: `secret` is private, and a test sees what an importer sees
    ┌─ s.ren:7:28
  7 │ test "reaches in" = assert secret() == 42
    │                            ^^^^^^
    = a test is a specification of `s`'s interface
    help: mark it `pub`, or explore it in the console: `ren console s`
  [1]
  $ printf 'secret()\nhelper()\n' | ren console s
  s> secret()
  42 : Int
  s> helper()
  7 : Int
  s> 
  $ cd ..

  $ ren console nowhere
  error: there's no module `nowhere` here: it would be the file `nowhere.ren`
  [1]
