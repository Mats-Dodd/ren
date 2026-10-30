(* The patterns stage (language.md, "List patterns and string patterns";
   research/perfect-hash/synthesis.md): this file is the stage's
   specification in the interpreter, as test_data.ml was the data
   stage's (compiler.md, "Patterns stage", "The tests").

   Each test's name starts with a tag, `[pN accept]` or `[pN reject]`. N
   is the step that lands it:

     p1  string literal patterns and sequence patterns, in `ren run`,
         with every error and the exhaustiveness and covered-arm checks
     p2  natively, as chains (bench/patterns.t)
     p3  the perfect hash (bench/patterns.t, test_phash.ml)
     p4  `keys.index(s)` on a constant (bench/patterns.t)

   Step 1 turned every test here on: each is written plainly, with what
   it prints in its [%expect], the whole message for an error. Steps 2
   to 4 change no output in `ren run`: theirs are bench/patterns.t's
   lines, which say what each native build prints and what's hashed. *)

open Helpers

(* ---- p1: string literal patterns ---- *)

let%expect_test "[p1 accept] string literals as arms, with `|`" =
  run
    {|
fn kind(m: Str) -> Str =
  match m
    "GET" | "HEAD" => "read"
    "POST" | "PUT" | "DELETE" => "write"
    _ => "other"

fn main() uses Console =
  let m = "GET"
  print(m)
  print(kind("HEAD"))
  print(kind("PUT"))
  print(kind("get"))
  print(kind("GETS"))
|};
  [%expect {|
    GET
    read
    write
    other
    other
    ()
    |}]

let%expect_test "[p1 accept] the empty string, as a key and as a subject" =
  run
    {|
fn f(s: Str) -> Str =
  match s
    "" => "empty"
    "a" => "one"
    _ => "other"

fn main() uses Console =
  print(f(""))
  print(f("a"))
  print(f("ab"))
  let s = "abc"
  print(f(s[1..1]))
|};
  [%expect {|
    empty
    one
    other
    empty
    ()
    |}]

let%expect_test "[p1 accept] keys of 1, 16, 17 and 255 bytes" =
  let k n c = String.make n c in
  run (Printf.sprintf
       {|
fn f(s: Str) -> Int =
  match s
    "%s" => 1
    "%s" => 16
    "%s" => 17
    "%s" => 255
    _ => 0

fn main() uses Console =
  print(f("%s"))
  print(f("%s"))
  print(f("%s"))
  print(f("%s"))
  print(f("%s"))
  print(f("%s"))
|}
       (k 1 'a') (k 16 'b') (k 17 'c') (k 255 'd') (k 1 'a') (k 16 'b')
       (k 17 'c') (k 255 'd') (k 254 'd') (k 15 'b'));
  [%expect {|
    1
    16
    17
    255
    0
    0
    ()
    |}]

(* 200 arms, each a key [k<i>]: the value table is wider than a byte,
   and the generator has to place every key *)
let many_arms n =
  let arms =
    String.concat ""
      (List.init n (fun i -> Printf.sprintf "    \"k%d\" => %d\n" i i))
  in
  Printf.sprintf
    {|
fn f(s: Str) -> Int =
  match s
%s    _ => -1

fn main() uses Console =
  var t = 0
  for i in 0..%d
    t += f("k" + show(i))
  print(t)
  print(f("k%d"))
  print(f("k"))
|}
    arms n n

let%expect_test "[p1 accept] 128 arms" =
  run (many_arms 128);
  [%expect {|
    8128
    -1
    -1
    ()
    |}]

let%expect_test "[p1 accept] 200 arms" =
  run (many_arms 200);
  [%expect {|
    19900
    -1
    -1
    ()
    |}]

(* ---- p1: `Str` sequences ---- *)

let%expect_test "[p1 accept] a prefix, a suffix, both, and `..` ignored" =
  run
    {|
fn f(s: Str) -> Str =
  match s
    "Bearer " ..token => "token " + token
    ..stem ".json" => "stem " + stem
    "<" ..inner ">" => "inner " + inner
    "--" .. => "flag"
    _ => "plain " + s

fn main() uses Console =
  print(f("Bearer abc"))
  print(f("main.json"))
  print(f("<b>"))
  print(f("--verbose"))
  print(f("x"))
  print(f("Bearer "))
|};
  [%expect {|
    token abc
    stem main
    inner b
    flag
    plain x
    token
    ()
    |}]

let%expect_test "[p1 accept] the minimum length: `\"a\" ..x \"a\"` needs two bytes" =
  run
    {|
fn f(s: Str) -> Str =
  match s
    "a" ..x "a" => "both " + x
    "a" => "one"
    _ => "other"

fn main() uses Console =
  print(f("a"))
  print(f("aa"))
  print(f("aba"))
|};
  [%expect {|
    one
    both
    both b
    ()
    |}]

let%expect_test "[p1 accept] adjacent literals are one" =
  run
    {|
fn f(s: Str) -> Str =
  match s
    "ab" "c" => "yes"
    _ => "no"

fn main() uses Console =
  print(f("abc"))
  print(f("ab"))
|};
  [%expect {|
    yes
    no
    ()
    |}]

let%expect_test "[p1 accept] cuts beside multi-byte characters" =
  run
    {|
fn main() uses Console =
  let s = "été"
  match s
    "é" ..rest => print(rest)
    _ => print("no")
  print(s.byte_len())
  match "café"
    ..stem "é" => print(stem)
    _ => print("no")
  match "a€b"
    "a" ..mid "b" => print(mid + " " + show(mid.byte_len()))
    _ => print("no")
|};
  [%expect {|
    té
    5
    caf
    € 3
    ()
    |}]

let%expect_test "[p1 accept] a slice bound outlives its subject" =
  run
    {|
fn token(h: Str) -> Str =
  match h
    "Bearer " ..t => t
    _ => ""

fn header() -> Str = "Bearer " + "sec" + "ret"

fn main() uses Console =
  let t = token(header())
  print(t)
  print(header().byte_len() - t.byte_len())
|};
  [%expect {|
    secret
    7
    ()
    |}]

(* ---- p1: guards ---- *)

let%expect_test "[p1 accept] a guard that fails falls through past literals to prefixes and `_`" =
  run
    {|
fn f(s: Str, short: Bool) -> Str =
  match s
    "a" ..x if short && x.byte_len() < 2 => "short a" + x
    "ab" => "literal ab"
    "a" ..x => "prefix a" + x
    "x" if short => "literal-x"
    _ => "any " + s

fn main() uses Console =
  print(f("ab", true))
  print(f("ab", false))
  print(f("abc", true))
  print(f("b", true))
  print(f("x", true))
|};
  [%expect {|
    short ab
    literal ab
    prefix abc
    any b
    literal-x
    ()
    |}]

let%expect_test "[p1 accept] a guarded literal falls through to the prefix after it" =
  run
    {|
fn f(s: Str, ok: Bool) -> Str =
  match s
    "v1" if ok => "lit"
    "v" ..n => "prefix v" + n
    _ => "other"

fn main() uses Console =
  print(f("v1", true))
  print(f("v1", false))
  print(f("w", false))
|};
  [%expect {|
    lit
    prefix v1
    other
    ()
    |}]

(* ---- p1: `Array` sequences ---- *)

let%expect_test "[p1 accept] every form on `Array`" =
  run
    {|
fn f(xs: Array<Int>) -> Str =
  match xs
    [] => "empty"
    [a] => "one " + show(a)
    [a, b] => "two " + show(a) + " " + show(b)
    [first, ..rest] if rest.len() == 2 => "first " + show(first) + " rest " + show(rest.len())
    [..init, last] if init.len() == 3 => "init " + show(init.len()) + " last " + show(last)
    [a, .., z] => "ends " + show(a) + " " + show(z)

fn main() uses Console =
  print(f([]))
  print(f([1, 2]))
  print(f([1, 2, 3]))
  print(f([1, 2, 3, 4]))
  print(f([1, 2, 3, 4, 5]))
  print(f([7]))
|};
  [%expect {|
    empty
    two 1 2
    first 1 rest 2
    init 3 last 4
    ends 1 5
    one 7
    ()
    |}]

let%expect_test "[p1 accept] element patterns of any kind, and a slice kept" =
  run
    {|
type Method = Get | Put

fn route(m: Method, segs: Array<Str>) -> Str =
  match (m, segs)
    (Get, ["v1", "keys", k]) => "get " + k
    (Put, ["v1" | "v2", "keys", k]) => "put " + k
    (Get, ["v1", "stats", ..]) => "stats"
    _ => "none"

fn tail(xs: Array<Int>) -> Array<Int> =
  match xs
    [_, _, ..rest] => rest
    _ => []

fn main() uses Console =
  print(route(Get, ["v1", "keys", "k1"]))
  print(route(Put, ["v2", "keys", "k2"]))
  print(route(Get, ["v1", "stats", "a", "b"]))
  print(route(Put, ["v1", "stats"]))
  print(tail([1, 2, 3, 4]))
|};
  [%expect {|
    get k1
    put k2
    stats
    none
    [3, 4]
    ()
    |}]

let%expect_test "[p1 accept] string patterns inside records, constructors, `as` and arrays" =
  run
    {|
type Doc = { name: Str, size: Int }

fn f(x: Doc) -> Str =
  match x
    { name: ..stem ".json", .. } => "json " + stem
    _ => "other"

fn g(xs: Array<Str>) -> Str =
  match xs
    ["v" ..n, ..] as all => "ver " + n + " of " + show(all)
    _ => "none"

fn h(o: Option<Str>) -> Str =
  match o
    Some("Bearer " ..) => "some bearer"
    _ => "none"

fn main() uses Console =
  print(f({ name: "main.json", size: 3 }))
  print(g(["v2", "x"]))
  print(h(Some("Bearer t")))
  print(h(None))
|};
  [%expect {|
    json main
    ver 2 of ["v2", "x"]
    some bearer
    none
    ()
    |}]

(* ---- p1: exhaustiveness and covered arms ---- *)

let%expect_test "[p1 accept] `[]`, `[_]` and `[_, _, ..]` cover every array" =
  run
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [] => 0
    [_] => 1
    [_, _, ..] => 2

fn main() uses Console =
  print(n([]))
  print(n([5]))
  print(n([5, 6, 7]))
|};
  [%expect {|
    0
    1
    2
    ()
    |}]

let%expect_test "[p1 accept] `[..init, last]` and `[]` cover every array" =
  run
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [..init, last] => last
    [] => 0

fn main() uses Console =
  print(n([]))
  print(n([1, 2, 3]))
|};
  [%expect {|
    0
    3
    ()
    |}]

let%expect_test "[p1 reject] an array match that misses a length" =
  check_error
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [] => 0
    [_] => 1

fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Array`
      ┌─ test.ren:2:3
    2 │   match xs
      │   ^^^^^
      = missing: [_, _, ..]
      help: add the missing arms, or a `_ =>` arm for the rest:
        [_, _, ..] => todo
    |}]

let%expect_test "[p1 reject] a string match needs `_` or a binding" =
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    "a" => 0
    "a" .. => 1

fn main() = ()
|};
  [%expect {|
    error: this `match` doesn't handle every `Str`
      ┌─ test.ren:2:3
    2 │   match s
      │   ^^^^^
      = missing: _
      help: add a `_ =>` arm to cover the remaining values:
        _ => todo
    |}]

let%expect_test "[p1 reject] a literal a prefix above covers" =
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    "a" .. => 1
    "ab" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    error: this arm can never match
      ┌─ test.ren:4:5
    4 │     "ab" => 0
      │     ^^^^
      help: the arms above already match everything this one does
    |}]

let%expect_test "[p1 reject] a prefix a shorter prefix above covers" =
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    "--" .. => 1
    "--out=" ..path => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    error: this arm can never match
      ┌─ test.ren:4:5
    4 │     "--out=" ..path => 0
      │     ^^^^^^^^^^^^^^^
      help: the arms above already match everything this one does
    |}]

let%expect_test "[p1 reject] a suffix a shorter suffix above covers, and a repeated literal" =
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    .. "s" => 1
    "is" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    error: this arm can never match
      ┌─ test.ren:4:5
    4 │     "is" => 0
      │     ^^^^
      help: the arms above already match everything this one does
    |}];
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    "a" => 1
    "a" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    error: this arm can never match
      ┌─ test.ren:4:5
    4 │     "a" => 0
      │     ^^^
      help: the arms above already match everything this one does
    |}]

let%expect_test "[p1 accept] what doesn't cover: longer prefixes, the minimum length, guards" =
  run
    {|
fn n(s: Str, g: Bool) -> Int =
  match s
    "ab" .. => 1
    "a" ..x "a" => 0
    "a" => 2
    "a" .. if g => 4
    "a" .. => 3
    _ => 5

fn main() uses Console =
  print(n("abc", true))
  print(n("aca", true))
  print(n("a", true))
  print(n("ac", false))
|};
  [%expect {|
    1
    0
    2
    3
    ()
    |}]

let%expect_test "[p1 reject] an array arm the lengths above cover" =
  check_error
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [] => 0
    [_, ..] => 1
    [_, _] => 2

fn main() = ()
|};
  [%expect {|
    error: this arm can never match
      ┌─ test.ren:5:5
    5 │     [_, _] => 2
      │     ^^^^^^
      help: the arms above already match everything this one does
    |}]

(* ---- p1: the errors ---- *)

let%expect_test "[p1 reject] `..x` alone" =
  check_error
    {|
fn n(s: Str) -> Str =
  match s
    ..rest => rest

fn main() = ()
|};
  [%expect {|
    error: `..rest` alone is the whole value
      ┌─ test.ren:3:5
    3 │     ..rest => rest
      │     ^^^^^^
      help: bind it with a name: `rest`
    |}]

let%expect_test "[p1 reject] `[..xs]` alone" =
  check_error
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [..xs] => xs.len()

fn main() = ()
|};
  [%expect {|
    error: `[..xs]` alone is the whole array
      ┌─ test.ren:3:6
    3 │     [..xs] => xs.len()
      │      ^^^^
      help: bind it with a name: `xs`
    |}]

let%expect_test "[p1 reject] two rests" =
  check_error
    {|
fn n(s: Str) -> Str =
  match s
    ..k "=" ..v => k
    _ => ""

fn main() = ()
|};
  [%expect {|
    error: a pattern has one `..` at most
      ┌─ test.ren:3:13
    3 │     ..k "=" ..v => k
      │             ^^^
      help: to cut at a separator, use `split` or `split_once` on the value
    |}];
  check_error
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [a, .., b, ..] => a
    _ => 0

fn main() = ()
|};
  [%expect {|
    error: a pattern has one `..` at most
      ┌─ test.ren:3:16
    3 │     [a, .., b, ..] => a
      │                ^^
      help: to cut at a separator, use `split` or `split_once` on the value
    |}]

let%expect_test "[p1 reject] a `Bytes` subject with a string pattern" =
  check_error
    {|
fn n(b: Bytes) -> Int =
  match b
    "GET" => 1
    _ => 0

fn main() = ()
|};
  [%expect {|
    error: a string pattern matches a `Str`, but this is `Bytes`
      ┌─ test.ren:3:5
    3 │     "GET" => 1
      │     ^^^^^
      help: read it with a format, or match `Str.from_utf8(b)` first
    |}]

let%expect_test "[p1 reject] a piece that isn't a literal" =
  check_error
    {|
fn n(s: Str) -> Int =
  match s
    "a" ..x y => 1
    _ => 0

fn main() = ()
|};
  [%expect {|
    error: the pieces of a string pattern are string literals
      ┌─ test.ren:3:13
    3 │     "a" ..x y => 1
      │             ^
      help: bind the middle with `..name`, and test the rest in the arm
    |}]

let%expect_test "[p1 reject] alternatives that bind different names" =
  check_error
    {|
fn n(s: Str) -> Str =
  match s
    "a" ..x | "b" => x
    _ => ""

fn main() = ()
|};
  [%expect {|
    error: `x` is bound in `"a" ..x` but not in `"b"`
      ┌─ test.ren:3:15
    3 │     "a" ..x | "b" => x
      │               ^^^
      help: bind the same names in every alternative
    |}]

let%expect_test "[p1 reject] a list pattern on something that isn't an array" =
  check_error
    {|
fn n(x: Int) -> Int =
  match x
    [a] => a
    _ => 0

fn main() = ()
|};
  [%expect {|
    error: a list pattern matches an `Array`, but this is `Int`
      ┌─ test.ren:3:5
    3 │     [a] => a
      │     ^^^
      help: take it apart as what it is, or bind it to a name
    |}]

let%expect_test "[p1 accept] `let ... else` takes a list or a string apart" =
  run
    {|
fn first_two(xs: Array<Int>) -> Int ! Short =
  let [a, b, ..] = xs else fail Short
  a + b

fn token(h: Str) -> Str ! NoToken =
  let "Bearer " ..t = h else fail NoToken
  t

fn main() uses Console =
  print(attempt first_two([1, 2, 3]))
  print(attempt first_two([1]))
  print(attempt token("Bearer abc"))
  print(attempt token("Basic x"))
|};
  [%expect {|
    Ok(3)
    Err(Short)
    Ok("abc")
    Err(NoToken)
    ()
    |}]

let%expect_test "[p1 reject] a list pattern in a `let` might not match" =
  check_error
    {|
fn f(xs: Array<Int>) -> Int =
  let [a, ..] = xs
  a

fn main() = ()
|};
  [%expect {|
    error: `[a, ..]` might not match, so this `let` needs an `else`
      ┌─ test.ren:2:7
    2 │   let [a, ..] = xs
      │       ^^^^^^^
      help: add one that leaves, `let [a, ..] = xs else fail ...`, or use a `match`
    |}]
