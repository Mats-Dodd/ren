(* Generator syntax stays in the tree until inference chooses its kind. *)

open Helpers

let syntax_errors src =
  let src = clean src in
  let sink = Ren.Diag.sink () in
  let toks = Ren.Lexer.tokenize ~file src in
  ignore (Ren.Parser.parse_program sink toks);
  List.iter
    (fun (d : Ren.Diag.t) -> print_endline d.msg)
    (Ren.Diag.reported sink)

let%expect_test "gen modifies a function and yield requires its operand" =
  syntax_errors {|gen handler fake() for Console = ()|};
  syntax_errors {|gen fn broken() -> Int = yield|};
  syntax_errors {|gen fn broken() -> Int = yield from|};
  [%expect
    {|
    expected `fn`, found `handler`
    expected an expression, found the end of the file
    expected an expression, found the end of the file
    |}]

let%expect_test "generator tokens and contextual from" =
  tokens {|pub gen fn f() = yield from try g()|};
  [%expect
    {| PUB (IDENT "gen") FN (IDENT "f") LPAREN RPAREN EQ YIELD (IDENT "from") TRY (IDENT "g") LPAREN RPAREN EOF |}]

let%expect_test "generator item, delegation marker and return are retained" =
  ast {|
pub gen fn walk(n: Int) -> Int ! Bad uses Console =
  if n <= 0 then return
  yield n + 1
  yield from try walk(n - 1)

gen fn inside() -> Int =
  with fake() in
    finally(r) => try r
    yield 1
|};
  [%expect
    {|
    (gen fn walk (n) (! Bad) (uses Console) (block (if (<= n 0) (return)) (yield (+ n 1)) (yield from (try (call walk (- n 1))))))
    (gen fn inside () (with (call fake) (block (finally (lambda (r) (try r))) (yield 1))))
    |}]

let%expect_test "yield contexts are left for resolve and return can give a value" =
  ast {|
gen fn values(from: Int) -> Int =
  yield (from + 1)
  yield if from > 0 then from else 0
  yield from source()

fn answer(ok: Bool) -> Int =
  if ok then return 42 else return 0

fn choose() =
  let body = fn() => yield 1
  body
|};
  [%expect
    {|
    (gen fn values (from) (block (yield (+ from 1)) (yield (if (> from 0) from 0)) (yield from (call source))))
    (fn answer (ok) (if ok (return 42) (return 0)))
    (fn choose () (block (let body (lambda () (yield 1))) body))
    |}]

let%expect_test "scheduler yield keeps its operation name" =
  ast {|
dep Pauses =
  yield: fn()

handler pauses() for Pauses =
  yield() => Async.yield()

fn run() uses Async =
  Async.yield()
|};
  [%expect
    {|
    (dep Pauses (ops yield:fn()))
    (fn pauses () (handler (for Pauses) (yield (lambda () (call (. (con Async) yield))))))
    (fn run () (uses Async) (call (. (con Async) yield)))
    |}]

let%expect_test "generator member syntax reaches its contextual check" =
  ast {|
type Bag = {}
  gen fn numbers() -> Int = yield 1
|};
  [%expect {| (type Bag (fields) (members ((gen fn numbers () (yield 1))))) |}]

let%expect_test "cursor type namespace allows a generator under a module alias" =
  ast {|
fn keep(a: numbers.Cursor<Int>, b: walks.numbers.Cursor<Int>) -> numbers.Cursor<Int> = a
|};
  [%expect {| (fn keep (a b) a) |}]

let%expect_test "gen is a modifier only where a function declaration starts" =
  ast {|
import gen
fn gen(x: Int) -> Int = x
fn use_gen(gen: Int) -> Int = gen
fn main() =
  let gen = gen.keys()
  gen

gen fn generated() -> Int = yield 1
|};
  [%expect {|
    (import gen as gen)
    (fn gen (x) x)
    (fn use_gen (gen) gen)
    (fn main () (block (let gen (call (. gen keys))) gen))
    (gen fn generated () (yield 1))
    |}]

let%expect_test "a module can still be imported with the alias gen" =
  ast {|
import helpers as gen
fn main() = gen.keys()
|};
  [%expect {|
    (import helpers as gen)
    (fn main () (call (. gen keys)))
    |}]

let%expect_test "ordinary gen names still resolve and execute" =
  run_files
    [ "main.ren", {|
import gen
fn main() uses Console = print(gen.keys())
|}; "gen.ren", {|pub fn keys() -> Int = 3|} ];
  run_files
    [ "main.ren", {|
import helpers as gen
fn main() uses Console = print(gen.keys())
|}; "helpers.ren", {|pub fn keys() -> Int = 4|} ];
  run {|
fn gen(x: Int) -> Int = x
fn main() uses Console =
  let gen = gen(5)
  print(gen)
|};
  [%expect {|3
()
4
()
5
()
|}]

let%expect_test "a malformed contextual generator keeps its function diagnostic" =
  syntax_errors {|gen fn = 1|};
  [%expect {| expected a name, found `=` |}]
