# A stack machine with time travel

A small virtual machine runs bytecode for `n!` and Fibonacci, and a
timeline records every state it passes through. Rewinding means reading an
old state; resuming means running a copy of it. There is no undo log, no
deep clone and no persistent data structure, because a Ren value is a
value: once recorded, a state can't change.

```
ren run vm/main.ren      # what it prints, line by line, is commented in main.ren
ren types vm/main.ren    # every module's interface
```

| File | What's in it |
|---|---|
| `op.ren` | the instruction set, one sum type |
| `program.ren` | `Program`, opaque: `Program.check` is the only way to make one, and fails with why it can't |
| `stack.ren` | `Stack<T>`, opaque over a private list |
| `machine.ren` | `Vm`, and `step`: everything the machine does; `Fault`, what can go wrong |
| `timeline.ren` | `Timeline`: record, rewind, and run while recording |
| `programs.ren` | the two programs, written out by hand |
| `main.ren` | runs them, rewinds, and forks a different future |

## What to look at

**`&` shows every change.** In `machine.ren`, each call that changes the
machine is marked with `&`: `&self.stack.push(n)`, `let v = try
&self.pop()`. A call without one doesn't change anything. `&tl.run(&vm, p, fuel)` in
`timeline.ren` changes two things, so it has two `&`s.

**Recording is a copy.** `Timeline.record` is one line,
`&self.frames.push(vm)`. In `main.ren`, the machine keeps running after
each state is recorded, the fork changes a local and runs on, and
`try ftl.back(...) == early` still holds: the timeline never changed.

**The compiler finds constructors through types.** `machine.ren` never
imports `Op`, yet `match p.at(self.pc)` names `Push`, `Load` and the rest.
Its arms are found through the type of `p.at(...)`. Importing `Op`
anyway is reported as an unused import.

**A fault is an error.** An instruction that needs a value the stack
doesn't have fails with `Underflow(pc)`: `Vm.pop` turns the stack's
`Option` into the error, `&self.stack.pop() orelse fail
Underflow(self.pc)`, and `step`, `run` and `Timeline.run` pass it on with
`try`. `Fault` names the set, so the three signatures write `! Fault`. A
machine that failed is still a value: in `main.ren`, `attempt` keeps the
error, and the machine kept what it did before it failed.

**Opaque types are a contract.** Outside `program.ren` an `Array<Op>` is
not a `Program`: every `Program` passed `check`, which fails with
`Empty`, `NoHalt` or `Outside(pc, to)` otherwise. Outside `stack.ren`
nobody knows a `Stack` is a list.

**Only `main` uses `Console`.** `ren types` shows `uses Console` on `main` and no
other dependency anywhere. The machine and the timeline are pure, and the
compiler worked that out without being told.

**The errors.** `examples.t` breaks the VM in five ways a reader might,
and shows what the compiler says for each:

- a new instruction, until `step` handles it
- a missing `&`
- a private method called from `main`
- an array used as a `Program`
- an argument that reads part of `self` in a call that changes it

## What writing it ran into

The program works around what Ren doesn't have yet. These are the
candidates for what comes next:

- ~~**No error handling yet (stage 6).**~~ Stage 6 fixed it:
  `tl.back(10)` fails with `NotRecorded(10)` instead of inventing a
  default, `Program.check` fails with what's wrong instead of `main`
  turning a bad program into one that does nothing, and a fault fails the
  run instead of being a status to check.
- **No `while`, ranges, `break` or early `return`.** `Vm.run` loops by
  recursing with a `fuel` count.
- **No strings.** Output is bare values, so `main.ren` comments what each
  printed line means, and jumps name instruction indexes, counted by hand.
- **Arguments can't read part of what a call changes.** `step`'s `Load`
  needs a `let` (planned for stage 11, for plain values).
- **`print` shows an opaque type's insides.** Printing a `Vm` would show
  its `Stack` as the list it is. Should debug output respect opacity?
- **`ren types` lists a public type only if it has members.** `Status`
  doesn't appear. A named error set does: `pub type Fault = ! Underflow(Int)`.
- **A passed function is called with `try`.** `binary` takes
  `f: fn(Int, Int) -> Int`, and a parameter's function type passes on
  whatever the function passed in fails with, so `f(a, b)` is written
  `try f(a, b)` though none of the four lambdas can fail.
