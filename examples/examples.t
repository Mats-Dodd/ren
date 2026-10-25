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
