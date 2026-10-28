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
  fn(&Account, Money, Movement) ! Frozen(AccountId) uses Clock
  account> attempt &a.credit(Money.dollars(5), Deposited(Money.dollars(5)))
  Err(Frozen(AccountId(1))) : Result<Unit, ! Frozen(AccountId)>
  account> Clock.now()
    Clock.now() → 0
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
    ┌─ <console>:3:12
  3 │ (print(3), 1 / 0)
    │            ^^^^^
  account> let n = 5
  account> n * 2
  10 : Int
  account> :x
  error: there's no console command `:x`
    help: `:t <expression>` shows its type, `:reload` checks the module again and runs the session on it, `:spec [name]` turns the session into a test, `:q` quits
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

  $ echo 'Clock.now() > Time.epoch' | ren console account --real Clock | sed 's/→ [0-9]*/→ N/'
  account> Clock.now() > Time.epoch
    Clock.now() → N
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
    Proc.run("sh", ["-c", "echo ran >> log.txt"]) → Ok(0)
  Ok(0) : Result<Int, ! CantRun(Str, Str) | Killed(Str) | NoSuchProgram(Str)>
  account> let n = 2
  account> n + 1
  3 : Int
  account> 
  $ cat log.txt
  ran
  $ rm log.txt

  $ ren console account --real Users
  error: `--real` names a built-in dependency with a real implementation, and only `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc` and `Async` have one, not `Users`
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
    │ ^^^^^^^^^^^^^^^^^^^^^^^^^ the console gets only the test `Clock`, `Random`, `Console`, `Fs`, `Os`, `Proc` and `Async`, and what controls them
    │     --------------------- this call uses `Prices`
    help: install one in the line: `with counting() in ...`
  cache> 

An error a `try` passes up stops the line, as a panic does, with how to
see it as a value:

  $ echo 'try Fs.read_str(Path.of("nothing"))' | ren console cache
  cache> try Fs.read_str(Path.of("nothing"))
    Fs.read("nothing") → Err(NoSuchFile("nothing"))
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

Every call to a built-in is shown as it's made, a line given to the test
`Console` as it would be printed. `:reload` reads the module again after
an edit and runs the session on it, so what the lines made is there
again; and `:spec` turns the session into a test of the module, leaving
out what a test can't reach:

  $ mkdir counter && cd counter
  $ cat > counter.ren <<'END'
  > pub type Counter = opaque { n: Int }
  >   pub fn start() -> Counter = Counter { n: 0 }
  > 
  >   pub fn bump(self) -> Counter uses Console =
  >     Console.write("bump")
  >     Counter { n: self.n + 1 }
  > 
  >   pub fn count(self) -> Int = self.n
  > 
  > fn secret() -> Int = 42
  > END
  $ cp counter.ren before
  $ cat > session <<'END'
  > let c = Counter.start().bump()
  > c.count()
  > secret()
  > let t = Clock.now()
  > :reload
  > c.count()
  > :spec counting
  > END
  $ ren console counter < session
  counter> let c = Counter.start().bump()
  bump
  counter> c.count()
  1 : Int
  counter> secret()
  42 : Int
  counter> let t = Clock.now()
    Clock.now() → 0
  counter> :reload
  reloaded counter.ren, and ran the session's 4 lines again
  counter> c.count()
  1 : Int
  counter> :spec counting
  added to counter.ren, to edit or delete:
  
  test "counting" =
    let c = Counter.start().bump()
    assert c.count() == 1
    let t = Clock.now()
    assert c.count() == 1
    = left out line 3, `secret()`: `secret` is private, and a test sees what an importer sees
  counter> 
  $ REN_NO_TIMINGS=1 ren test counter.ren
  counter.ren
    ✓ counting
  
  1 passed

A name a test of the module has already isn't taken again. A value a
test can't write, an opaque one's representation, is kept as `let _ = `
and its line, so what the line does stays in the test; a line that uses
a variable of a line left out is left out for that; and the test is run
as `ren test` runs it, so an `assert` that only held for the session's
`Random`, whose seed isn't the test's, is kept as its line too:

  $ cat >> counter.ren <<'END'
  > 
  > pub fn two() -> Int = 2
  > END
  $ cat > session <<'END'
  > :spec counting
  > let c = Counter.start().bump()
  > c
  > two() == 2
  > let s = secret()
  > s + 1
  > Random.int(1000)
  > :spec more
  > END
  $ ren console counter < session
  counter> :spec counting
  error: counter.ren has a test named "counting" already
     ┌─ counter.ren:12:6
  12 │ test "counting" =
     │      ^^^^^^^^^^
     help: give this one another name: `:spec <name>`
  counter> let c = Counter.start().bump()
  bump
  counter> c
  Counter(n: 1) : Counter
  counter> two() == 2
  true : Bool
  counter> let s = secret()
  counter> s + 1
  43 : Int
  counter> Random.int(1000)
    Random.int(1000) → 0
  0 : Int
  counter> :spec more
  added to counter.ren, to edit or delete:
  
  test "more" =
    let c = Counter.start().bump()
    let _ = c
    assert two() == 2
    = left out line 4, `let s = secret()`: `secret` is private, and a test sees what an importer sees
    = left out line 5, `s + 1`: it uses `s`, from line 4, which is left out
    = left out line 6, `Random.int(1000)`: it's at the end, where a test can't keep it as `let _ = ` and the line
  counter> 
  $ REN_NO_TIMINGS=1 ren test counter.ren
  counter.ren
    ✓ counting
    ✓ more
  
  2 passed

A session none of whose lines a test can keep adds nothing:

  $ echo ':spec' | ren console counter
  counter> :spec
  nothing added to counter.ren: a test of it can keep none of the session's lines
  counter> 

After an edit, a line that doesn't check any more, or that makes calls
other than those it kept, is dropped, with the lines after it. The
module is read again only by `:reload`, so here the edit is made while
the session waits for its next line:

  $ cp before counter.ren && mkfifo lines
  $ ren console counter < lines > out 2>&1 &
  $ exec 3> lines
  $ echo 'let c = Counter.start().bump()' >&3; echo 'c.count()' >&3
  $ until grep -q '1 : Int' out; do sleep 0.05; done
  $ perl -pi -e 's/fn count/fn total/' counter.ren
  $ echo ':reload' >&3; echo 'c' >&3; exec 3>&-; wait
  $ cat out
  counter> let c = Counter.start().bump()
  bump
  counter> c.count()
  1 : Int
  counter> :reload
  error: `Counter` has no method named `count`
    ┌─ <console>:2:3
  2 │ c.count()
    │   ^^^^^
    = the session goes on from line 2, which is dropped, and those after it
    help: its methods: `bump`, `total`
  counter> c
  Counter(n: 1) : Counter
  counter> 
  $ cp before counter.ren
  $ ren console counter < lines > out 2>&1 &
  $ exec 3> lines
  $ echo 'let c = Counter.start().bump()' >&3
  $ until grep -q 'bump' out; do sleep 0.05; done
  $ perl -pi -e 's/"bump"/"bump!"/' counter.ren
  $ echo ':reload' >&3; echo 'c' >&3; exec 3>&-; wait
  $ cat out
  counter> let c = Counter.start().bump()
  bump
  counter> :reload
  error: the session went differently at line 1
    ┌─ <console>:1:1
  1 │ let c = Counter.start().bump()
    │ ^
    = the session had: Console.write("bump")
    = this run made: Console.write("bump!")
    = the session goes on from line 1, which is dropped, and those after it
    help: the code changed since that line ran: type it again to run it on the code as it is now
  counter> c
  error: there's no variable named `c`
    ┌─ <console>:1:1
  1 │ c
    │ ^
  counter> 

`:spec` adds to the module's file only if it's what the session read: an
edit saved since is run first, by `:reload`, and isn't overwritten:

  $ cp before counter.ren
  $ ren console counter < lines > out 2>&1 &
  $ exec 3> lines
  $ echo 'Counter.start().bump().count()' >&3
  $ until grep -q '1 : Int' out; do sleep 0.05; done
  $ echo 'pub fn three() -> Int = 3' >> counter.ren
  $ echo ':spec edited' >&3; echo ':reload' >&3; echo ':spec edited' >&3
  $ exec 3>&-; wait
  $ cat out
  counter> Counter.start().bump().count()
  bump
  1 : Int
  counter> :spec edited
  error: counter.ren has changed since the session read it, so `:spec` adds nothing to it
    help: `:reload` first, to run the session on it, then `:spec` again
  counter> :reload
  reloaded counter.ren, and ran the session's line again
  counter> :spec edited
  added to counter.ren, to edit or delete:
  
  test "edited" =
    assert Counter.start().bump().count() == 1
  counter> 
  $ tail -4 counter.ren
  pub fn three() -> Int = 3
  
  test "edited" =
    assert Counter.start().bump().count() == 1
  $ cd ..
