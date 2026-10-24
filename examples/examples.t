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
  fn seats(u: User) -> Int
  fn first_or<T>(o: Option<T>, fallback: T) -> T
  fn map_option<T, U>(o: Option<T>, f: fn(T) -> U) -> Option<U>
  fn twice<T>(f: fn() -> T) -> T
  fn main() uses Io
