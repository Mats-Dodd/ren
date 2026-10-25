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
| `program.ren` | `Program`, opaque: `Program.check` is the only way to make one |
| `stack.ren` | `Stack<T>`, opaque over a private list |
| `machine.ren` | `Vm`, and `step`: everything the machine does |
| `timeline.ren` | `Timeline`: record, rewind, and run while recording |
| `programs.ren` | the two programs, written out by hand |
| `main.ren` | runs them, rewinds, and forks a different future |

## What to look at

**`&` shows every change.** In `machine.ren`, each line that changes the
machine starts with `&`: `&self.stack.push(n)`, `&self.fail()`. A line
without one doesn't change anything. `&tl.run(&vm, p, fuel)` in
`timeline.ren` changes two things, so it has two `&`s.

**Recording is a copy.** `Timeline.record` is one line,
`&self.frames.push(vm)`. In `main.ren`, the machine keeps running after
each state is recorded, the fork changes a local and runs on, and
`ftl.back(...) == Some(early)` still holds: the timeline never changed.

**The compiler finds constructors through types.** `machine.ren` never
imports `Op`, yet `match p.at(self.pc)` names `Push`, `Load` and the rest.
Its arms are found through the type of `p.at(...)`. Importing `Op`
anyway is reported as an unused import.

**Opaque types are a contract.** Outside `program.ren` an `Array<Op>` is
not a `Program`: every `Program` passed `check`. Outside `stack.ren`
nobody knows a `Stack` is a list.

**Only `main` uses `Io`.** `ren types` shows `fn main() uses Io` and no
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

- **No `while`, ranges, `break` or early `return`.** `Vm.run` loops by
  recursing with a `fuel` count.
- **No error handling yet (stage 6).** `tl.back(10).unwrap_or(Vm.fresh)`
  invents a default where it should fail, and `load` turns a bad program
  into one that does nothing.
- **No strings.** Output is bare values, so `main.ren` comments what each
  printed line means, and jumps name instruction indexes, counted by hand.
- **Arguments can't read part of what a call changes.** `step`'s `Load`
  needs a `let` (planned for stage 11, for plain values).
- **`print` shows an opaque type's insides.** Printing a `Vm` would show
  its `Stack` as the list it is. Should debug output respect opacity?
- **`ren types` lists a public type only if it has members.** `Status`
  and `Fault` don't appear.
