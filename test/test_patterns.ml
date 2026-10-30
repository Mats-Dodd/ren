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

   A test still to land runs through [until] (helpers.ml): [want] is the
   whole output of a program that runs, [says] the lines an error has to
   hold, its headline and its help. Its [%expect] holds today's output
   after `(until pN)`. When the program prints what's wanted, the test
   fails until the step turns it on: written plainly, with the target in
   its [%expect]. *)

open Helpers

let p1 ~want src = until "p1" ~want (fun () -> run src)
let p1_refused ~says src = until "p1" ~says (fun () -> check_error src)

(* ---- p1: string literal patterns ---- *)

let%expect_test "[p1 accept] string literals as arms, with `|`" =
  p1
    ~want:{|
GET
read
write
other
other
()
|}
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
    (until p1)
    error: expected a pattern, found the string `"GET"`
      ┌─ test.ren:3:5
    3 │     "GET" | "HEAD" => "read"
      │     ^^^^^
    |}]

let%expect_test "[p1 accept] the empty string, as a key and as a subject" =
  p1
    ~want:{|
empty
one
other
empty
()
|}
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
    (until p1)
    error: expected a pattern, found the string `""`
      ┌─ test.ren:3:5
    3 │     "" => "empty"
      │     ^^
    |}]

let%expect_test "[p1 accept] keys of 1, 16, 17 and 255 bytes" =
  let k n c = String.make n c in
  p1
    ~want:{|
1
16
17
255
0
0
()
|}
    (Printf.sprintf
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
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" => 1
      │     ^^^
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
  p1 ~want:"8128\n-1\n-1\n()\n" (many_arms 128);
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"k0"`
      ┌─ test.ren:3:5
    3 │     "k0" => 0
      │     ^^^^
    |}]

let%expect_test "[p1 accept] 200 arms" =
  p1 ~want:"19900\n-1\n-1\n()\n" (many_arms 200);
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"k0"`
      ┌─ test.ren:3:5
    3 │     "k0" => 0
      │     ^^^^
    |}]

(* ---- p1: `Str` sequences ---- *)

let%expect_test "[p1 accept] a prefix, a suffix, both, and `..` ignored" =
  p1
    ~want:{|
token abc
stem main
inner b
flag
plain x
token
()
|}
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
    (until p1)
    error: expected a pattern, found the string `"Bearer "`
      ┌─ test.ren:3:5
    3 │     "Bearer " ..token => "token " + token
      │     ^^^^^^^^^
    |}]

let%expect_test "[p1 accept] the minimum length: `\"a\" ..x \"a\"` needs two bytes" =
  p1
    ~want:{|
one
both
both b
()
|}
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
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" ..x "a" => "both " + x
      │     ^^^
    |}]

let%expect_test "[p1 accept] adjacent literals are one" =
  p1 ~want:"yes\nno\n()\n"
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
    (until p1)
    error: expected a pattern, found the string `"ab"`
      ┌─ test.ren:3:5
    3 │     "ab" "c" => "yes"
      │     ^^^^
    |}]

let%expect_test "[p1 accept] cuts beside multi-byte characters" =
  p1
    ~want:{|
té
5
caf
€ 3
()
|}
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
    (until p1)
    error: expected a pattern, found the string `"é"`
      ┌─ test.ren:4:5
    4 │     "é" ..rest => print(rest)
      │     ^^^^
    |}]

let%expect_test "[p1 accept] a slice bound outlives its subject" =
  p1 ~want:"secret\n7\n()\n"
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
    (until p1)
    error: expected a pattern, found the string `"Bearer "`
      ┌─ test.ren:3:5
    3 │     "Bearer " ..t => t
      │     ^^^^^^^^^
    |}]

(* ---- p1: guards ---- *)

let%expect_test "[p1 accept] a guard that fails falls through past literals to prefixes and `_`" =
  p1
    ~want:{|
short ab
literal ab
prefix abc
any b
literal-x
()
|}
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
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" ..x if short && x.byte_len() < 2 => "short a" + x
      │     ^^^
    |}]

let%expect_test "[p1 accept] a guarded literal falls through to the prefix after it" =
  p1 ~want:"lit\nprefix v1\nother\n()\n"
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
    (until p1)
    error: expected a pattern, found the string `"v1"`
      ┌─ test.ren:3:5
    3 │     "v1" if ok => "lit"
      │     ^^^^
    |}]

(* ---- p1: `Array` sequences ---- *)

let%expect_test "[p1 accept] every form on `Array`" =
  p1
    ~want:{|
empty
two 1 2
first 1 rest 2
init 3 last 4
ends 1 5
one 7
()
|}
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
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [] => "empty"
      │     ^
    |}]

let%expect_test "[p1 accept] element patterns of any kind, and a slice kept" =
  p1
    ~want:{|
get k1
put k2
stats
none
[3, 4]
()
|}
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
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:5:11
    5 │     (Get, ["v1", "keys", k]) => "get " + k
      │           ^

    error: expected a pattern, found `[`
       ┌─ test.ren:12:5
    12 │     [_, _, ..rest] => rest
       │     ^
    |}]

let%expect_test "[p1 accept] string patterns inside records, constructors, `as` and arrays" =
  p1
    ~want:{|
json main
ver 2 of ["v2", "x"]
some bearer
none
()
|}
    {|
type File = { name: Str, size: Int }

fn f(x: File) -> Str =
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
    (until p1)
    error: expected a pattern, found `..`
      ┌─ test.ren:5:13
    5 │     { name: ..stem ".json", .. } => "json " + stem
      │             ^^

    error: expected a pattern, found `[`
       ┌─ test.ren:10:5
    10 │     ["v" ..n, ..] as all => "ver " + n + " of " + show(all)
       │     ^

    error: expected a pattern, found the string `"Bearer "`
       ┌─ test.ren:15:10
    15 │     Some("Bearer " ..) => "some bearer"
       │          ^^^^^^^^^
    |}]

(* ---- p1: exhaustiveness and covered arms ---- *)

let%expect_test "[p1 accept] `[]`, `[_]` and `[_, _, ..]` cover every array" =
  p1 ~want:"0\n1\n2\n()\n"
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
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [] => 0
      │     ^
    |}]

let%expect_test "[p1 accept] `[..init, last]` and `[]` cover every array" =
  p1 ~want:"0\n3\n()\n"
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
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [..init, last] => last
      │     ^
    |}]

let%expect_test "[p1 reject] an array match that misses a length" =
  p1_refused
    ~says:
      [
        "error: this `match` doesn't handle every `Array`";
        "[_, _, ..] => todo";
      ]
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [] => 0
    [_] => 1

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [] => 0
      │     ^
    |}]

let%expect_test "[p1 reject] a string match needs `_` or a binding" =
  p1_refused
    ~says:
      [
        "error: this `match` doesn't handle every `Str`";
        "help: add a `_ =>` arm to cover the remaining values:";
      ]
    {|
fn n(s: Str) -> Int =
  match s
    "a" => 0
    "a" .. => 1

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" => 0
      │     ^^^
    |}]

let%expect_test "[p1 reject] a literal a prefix above covers" =
  p1_refused
    ~says:
      [
        "error: this arm can never match";
        "help: the arms above already match everything this one does";
      ]
    {|
fn n(s: Str) -> Int =
  match s
    "a" .. => 1
    "ab" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" .. => 1
      │     ^^^
    |}]

let%expect_test "[p1 reject] a prefix a shorter prefix above covers" =
  p1_refused
    ~says:[ "error: this arm can never match" ]
    {|
fn n(s: Str) -> Int =
  match s
    "--" .. => 1
    "--out=" ..path => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"--"`
      ┌─ test.ren:3:5
    3 │     "--" .. => 1
      │     ^^^^
    |}]

let%expect_test "[p1 reject] a suffix a shorter suffix above covers, and a repeated literal" =
  p1_refused
    ~says:[ "error: this arm can never match" ]
    {|
fn n(s: Str) -> Int =
  match s
    .. "s" => 1
    "is" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `..`
      ┌─ test.ren:3:5
    3 │     .. "s" => 1
      │     ^^
    |}];
  p1_refused
    ~says:[ "error: this arm can never match" ]
    {|
fn n(s: Str) -> Int =
  match s
    "a" => 1
    "a" => 0
    _ => 2

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" => 1
      │     ^^^
    |}]

let%expect_test "[p1 accept] what doesn't cover: longer prefixes, the minimum length, guards" =
  p1 ~want:"1\n0\n2\n3\n()\n"
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
    (until p1)
    error: expected a pattern, found the string `"ab"`
      ┌─ test.ren:3:5
    3 │     "ab" .. => 1
      │     ^^^^
    |}]

let%expect_test "[p1 reject] an array arm the lengths above cover" =
  p1_refused
    ~says:[ "error: this arm can never match" ]
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [] => 0
    [_, ..] => 1
    [_, _] => 2

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [] => 0
      │     ^
    |}]

(* ---- p1: the errors ---- *)

let%expect_test "[p1 reject] `..x` alone" =
  p1_refused
    ~says:
      [ "error: `..rest` alone is the whole value"; "help: bind it with a name: `rest`" ]
    {|
fn n(s: Str) -> Str =
  match s
    ..rest => rest

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `..`
      ┌─ test.ren:3:5
    3 │     ..rest => rest
      │     ^^
    |}]

let%expect_test "[p1 reject] `[..xs]` alone" =
  p1_refused
    ~says:
      [ "error: `[..xs]` alone is the whole array"; "help: bind it with a name: `xs`" ]
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [..xs] => xs.len()

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [..xs] => xs.len()
      │     ^
    |}]

let%expect_test "[p1 reject] two rests" =
  p1_refused
    ~says:
      [
        "error: a pattern has one `..` at most";
        "help: to cut at a separator, use `split` or `split_once` on the value";
      ]
    {|
fn n(s: Str) -> Str =
  match s
    ..k "=" ..v => k
    _ => ""

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `..`
      ┌─ test.ren:3:5
    3 │     ..k "=" ..v => k
      │     ^^
    |}];
  p1_refused
    ~says:[ "error: a pattern has one `..` at most" ]
    {|
fn n(xs: Array<Int>) -> Int =
  match xs
    [a, .., b, ..] => a
    _ => 0

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [a, .., b, ..] => a
      │     ^
    |}]

let%expect_test "[p1 reject] a `Bytes` subject with a string pattern" =
  p1_refused
    ~says:
      [
        "error: a string pattern matches a `Str`, but this is `Bytes`";
        "help: read it with a format, or match `Str.from_utf8(b)` first";
      ]
    {|
fn n(b: Bytes) -> Int =
  match b
    "GET" => 1
    _ => 0

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"GET"`
      ┌─ test.ren:3:5
    3 │     "GET" => 1
      │     ^^^^^
    |}]

let%expect_test "[p1 reject] a piece that isn't a literal" =
  p1_refused
    ~says:[ "error: the pieces of a string pattern are string literals" ]
    {|
fn n(s: Str) -> Int =
  match s
    "a" ..x y => 1
    _ => 0

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" ..x y => 1
      │     ^^^
    |}]

let%expect_test "[p1 reject] alternatives that bind different names" =
  p1_refused
    ~says:[ "error: `x` is bound in `\"a\" ..x` but not in `\"b\"`" ]
    {|
fn n(s: Str) -> Str =
  match s
    "a" ..x | "b" => x
    _ => ""

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found the string `"a"`
      ┌─ test.ren:3:5
    3 │     "a" ..x | "b" => x
      │     ^^^
    |}]

let%expect_test "[p1 reject] a list pattern on something that isn't an array" =
  p1_refused
    ~says:[ "error: a list pattern matches an `Array`, but this is `Int`" ]
    {|
fn n(x: Int) -> Int =
  match x
    [a] => a
    _ => 0

fn main() = ()
|};
  [%expect {|
    (until p1)
    error: expected a pattern, found `[`
      ┌─ test.ren:3:5
    3 │     [a] => a
      │     ^
    |}]
