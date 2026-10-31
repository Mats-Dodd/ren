(* Stage 12a's targets. A disabled stage is a skip, not a passing specimen.
   Turn its [until] into a direct call when the owning step lands. Successful
   runs use Helpers.run, which compares ordinary and release interpretation. *)

open Helpers

let enabled = [ "s1"; "s2" ]

let until step f =
  if List.mem step enabled then f ()
  else print_endline ("skipped until " ^ step)

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let output src expected =
  let said, raised = captured (fun () -> run src) in
  Option.iter raise raised;
  if said <> expected then
    failwith ("unexpected stage 12a output:\n" ^ said)

let rejects src fragments =
  let src = clean src in
  let src = if contains src "fn main" then src else src ^ "\nfn main() = ()\n" in
  let said, raised = captured (fun () ->
      report src (fun () -> ignore (Ren.Driver.check ~file src))) in
  Option.iter raise raised;
  List.iter
    (fun part ->
      if not (contains said part) then
        failwith ("missing diagnostic fragment " ^ part ^ ":\n" ^ said))
    ("error:" :: "help:" :: fragments)

let%expect_test "[s1] calls, comparisons and defaults" =
  until "s1" (fun () ->
      output
        {|fn id<T>(x: T) -> T = x
type Cfg = { port: Int = 8080, name: Str }
fn main() uses Console =
  let cfg: Cfg = { name: "local" }
  print(id<Int>(cfg.port))
  print(id<Str>(cfg.name))
  print(1 < 2 && 3 > 2)
  let copy = { ..cfg, name: "remote" }
  let { port, .. } = copy
  print(port)
|}
        "8080\nlocal\ntrue\n8080\n()\n");
  [%expect {| |}]

let%expect_test "[s1] reserved parse and repr are pure and agree" =
  until "s1" (fun () ->
      rejects
        {|type Id = opaque Int
  fn parse(s: Str) -> Id uses Clock =
    let _ = Clock.now()
    1
  fn repr(self) -> Int = self
|}
        [ "parse"; "pure" ];
      rejects
        {|type Id = opaque Int
  fn parse(s: Str) -> Id = 1
  fn repr(self) -> Int = self
|}
        [ "parse"; "repr" ]);
  [%expect {| |}]

let%expect_test "[s2] dependency order, CRC data and data router" =
  until "s2" (fun () ->
      output
        {|let CRC_TABLE: Array<Int> = table()
let ROUTES = [Get("/users"), Post("/users")]
let START = END - 1
let END = 3
type Route = Get(Str) | Post(Str)
fn table() -> Array<Int> = [0, 1, 3, 2]
assert START == 2
fn main() uses Console =
  print(CRC_TABLE)
  print(ROUTES.len())
|}
        "[0, 1, 3, 2]\n2\n()\n");
  [%expect {||}]

let%expect_test "[s2] build errors, effects and blocks" =
  until "s2" (fun () ->
      rejects "let A = B\nlet B = A\n" [ "cycle"; "A"; "B" ];
      rejects "assert 2 + 2 == 5\n" [ "assert"; "4"; "5" ];
      rejects "let BAD = try broken()\nfn broken() -> Int ! Bad = fail Bad\n"
        [ "BAD"; "Bad" ];
      rejects "let NEVER = forever()\nfn forever() -> Int =\n  var n = 0\n  while true\n    n += 1\n  n\n"
        [ "NEVER"; "steps"; "limit" ];
      List.iter
        (fun (name, expr) ->
          rejects ("let BAD = " ^ expr ^ "\n")
            [ name; "build"; "packages" ])
        [ ("Clock", "Clock.now()"); ("Fs", "try Fs.read(Path.of(\"a\"))") ];
      rejects "let BLOCK = fn(x: Int) => x + 1\n" [ "block" ]);
  [%expect {||}]

let%expect_test "[s2] uses is inferred, with a transitive failing path" =
  until "s2" (fun () ->
      output
        {|fn quiet() -> Int uses Clock = 1
assert quiet.uses <= []
assert not quiet.uses.includes(Clock)
fn main() = ()
|} "()\n";
      rejects
        {|fn load_template() uses Fs = try Fs.read(Path.of("template"))
fn render() uses Fs = try load_template()
fn handle_request() uses Fs = try render()
assert handle_request.uses <= [Console]
|}
        [ "handle_request"; "render"; "load_template"; "Fs.read" ]);
  [%expect {||}]

let%expect_test "[s3] templates, debug holes and literal forms" =
  until "s3" (fun () ->
      output
        {|fn consume<H>(t: Template<H>) -> Str = t.render()
fn main() uses Console =
  let x = 7
  print(consume(t"value \{x=}"))
  print(consume(t#"raw \#{x}"#))
  print(consume(t"""
    multi \{x}
    """))
  print("plain \{x}")
|}
        "value x=7\nraw 7\nmulti 7\nplain 7\n()\n");
  [%expect {| skipped until s3 |}]

let%expect_test "[s3] templates obey the block rule" =
  until "s3" (fun () ->
      List.iter (fun src -> rejects src [ "template" ])
        [ "fn take<H>(t: Template<H>) = ()\nfn main() = take(\"text\")\n";
          "fn escape() = t\"value\"\n";
          "type Box<H> = { value: Template<H> }\n";
          "fn main() =\n  let t = t\"value\"\n  fn() => t.render()\n";
          "fn main() =\n  let t = if true then t\"yes\" else t\"no\"\n  t.render()\n" ]);
  [%expect {| skipped until s3 |}]

let%expect_test "[s3] signature let refuses unknown caller types and forwarded sites" =
  until "s3" (fun () ->
      rejects
        {|fn inspect<T>(x: T) -> Int
  let shape = T.shape
= 1
fn wrapper<T>(x: T) -> Int = inspect<T>(x)
|}
        [ "caller"; "type parameter" ];
      rejects
        {|fn planned<H>(t: Template<H>) -> Str
  let site = t.site()
= t.render()
fn wrapper<H>(t: Template<H>) -> Str = planned(t)
|}
        [ "template"; "wrapper" ]);
  [%expect {| skipped until s3 |}]

let record = "type User = { id: Int, name: Str, email: Option<Str> }\n  fn show(self) -> Str = \"user\"\n"

let%expect_test "[s4] each record declaration check has help" =
  until "s4" (fun () ->
      List.iter
        (fun (look, fragments) -> rejects (record ^ look ^ "\n") fragments)
        [ ("format public for User = id", [ "name"; "left out" ]);
          ("format public for User =\n  id\n  id\n  ..", [ "id"; "twice" ]);
          ("format public for User = missing = nope\n  ..", [ "nope"; "field" ]);
          ("format public for User = id: UInt16 le\n  name", [ "layout"; "look" ]);
          ("format show for User = ..\n", [ "show"; "method" ]);
          ("format public for User = ..\nformat public for User = ..", [ "public"; "two" ]) ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] sum declaration checks" =
  until "s4" (fun () ->
      let sum = "type Event = Placed { id: Int } | Refunded { id: Int }\n" in
      List.iter
        (fun (look, fragments) -> rejects (sum ^ look ^ "\n") fragments)
        [ ("format v1 for Event =\n  | Placed as \"placed\"", [ "Refunded"; "tag" ]);
          ("format v1 for Event =\n  | Placed as \"same\"\n  | Refunded as \"same\"", [ "tag"; "same" ]);
          ("format v1 for Event =\n  | Placed as 1\n  | Refunded as \"refund\"", [ "tag"; "type" ]);
          ("format v1 for Event =\n  | Placed as t\"placed/\\{missing}\"\n  | ..", [ "missing"; "field" ]) ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] opaque values and impure via functions" =
  until "s4" (fun () ->
      rejects "type Money = opaque { cents: Int }\nformat raw for Money = cents\n"
        [ "Money"; "opaque"; "via" ];
      rejects
        {|type Id = opaque Int
fn read(n: Int) -> Id uses Clock =
  let _ = Clock.now()
  1
fn write(id: Id) -> Int = id
format number for Id = Int via (read, write)
|}
        [ "Clock"; "pure" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] Value's door is identity" =
  until "s4" (fun () ->
      output
        {|import shape
fn main() uses Console =
  let v = shape.Value.Fields([("id", shape.Value.Int(7))])
  print(try shape.build<shape.Value>(v) == v)
|} "true\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s5] json absence and defaults" =
  until "s5" (fun () ->
      output
        {|import json
type User = { id: Int, name: Str = "anonymous", email: Option<Str> }
fn main() uses Console =
  let u = try json.decode<User>("{\"id\":7}")
  print(u.name)
  print(u.email)
  print(try json.encode(u))
|}
        "anonymous\nNone\n{\"id\":7,\"name\":\"anonymous\"}\n()\n";
      rejects
        "import json\ntype Patch = { x: Option<Option<Int>> }\nfn main() = try json.decode<Patch>(\"{}\")\n"
        [ "Option<Option"; "Keep"; "Clear"; "Set" ]);
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] Raw and untyped Value preserve their contract" =
  until "s5" (fun () ->
      output
        {|import json
import shape
type Envelope = { raw: json.Raw }
fn main() uses Console =
  let v = try json.decode<shape.Value>("{\"n\":7,\"nil\":null}")
  print(try json.encode(v))
  let e = try json.decode<Envelope>("{\"raw\": [ 1, 2 ]}")
  print(try json.encode(e))
|}
        "{\"n\":7,\"nil\":null}\n{\"raw\": [ 1, 2 ]}\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] bin round trips scalar, record, sum and recursive values" =
  until "s5" (fun () ->
      output
        {|import bin
type Tree = Leaf(Int) | Branch(Array<Tree>)
type Packet = { id: Int, body: Bytes, note: Option<Str> }
fn main() uses Console =
  let p: Packet = { id: -1, body: b"abc", note: Some("ok") }
  print(try bin.decode<Packet>(try bin.encode(p)) == p)
  let tree = Branch([Leaf(1), Branch([Leaf(2)])])
  print(try bin.decode<Tree>(try bin.encode(tree)) == tree)
|} "true\ntrue\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] cli flags, positionals, shorts, choices and subcommands" =
  until "s5" (fun () ->
      output
        {|import cli
type Mode = Fast | Safe
type Cmd = Get { key: Str, mode: Mode } | Put { key: Str, value: Str }
let CLI = try cli.spec<Cmd>(positional: ["key"], short: [("mode", "m")])
fn main() uses Console =
  print(try cli.parse<Cmd>(["get", "hello", "-m", "Safe"], CLI))
|} "Get { key: \"hello\", mode: Safe }\n()\n";
      rejects
        "import cli\ntype Cmd = { key: Str }\nlet CLI = try cli.spec<Cmd>(positional: [\"kee\"])\n"
        [ "kee"; "key" ]);
  [%expect {| skipped until s5 |}]

let%expect_test "[s6] every world name needs its import" =
  until "s6" (fun () ->
      List.iter
        (fun (name, module_) ->
          rejects ("fn main() = " ^ name ^ "\n") [ "import " ^ module_ ])
        [ ("Clock", "std/clock"); ("Time", "std/clock");
          ("Instant", "std/clock"); ("Random", "std/random");
          ("Net", "std/net"); ("Fs", "std/fs"); ("Os", "std/os");
          ("Proc", "std/proc"); ("actors", "std/actors");
          ("striped", "std/actors"); ("Instances", "std/actors");
          ("retry", "std/retry") ]);
  [%expect {| skipped until s6 |}]

let%expect_test "[s7] release and interpreter json bytes agree" =
  until "s7" (fun () ->
      output
        {|import json
type Order = { id: Int, customer: Int, total: Int, note: Option<Str> }
format v1 for Order =
  kind = "order"
  customerId = customer
  ..
let API = json.settings(formats: [Order.v1])
fn main() uses Console =
  let o = try json.decode<Order>("{\"kind\":\"order\",\"customerId\":2,\"id\":1,\"total\":42}", API)
  print(try json.encode(o, API))
|}
        "{\"kind\":\"order\",\"customerId\":2,\"id\":1,\"total\":42}\n()\n");
  [%expect {| skipped until s7 |}]

(* s8's [until] gate is in bench/shapes/check.py: formats.lock belongs to
   the command-line driver and must be tested on disk, not modelled here. *)

let%expect_test "[s1] nested explicit types and comparison ambiguity" =
  until "s1" (fun () ->
      output
        {|fn id<T>(x: T) -> T = x
fn main() uses Console =
  print(id<Array<Option<Int>>>([Some(7), None]))
  print(1 < id<Int>(2))
  print(id<Int>(3) > 2)
|} "[Some(7), None]\ntrue\ntrue\n()\n";
      rejects "fn main() = 1 < 2 > 3\n" [ "comparisons"; "chained" ]);
  [%expect {| |}]

let%expect_test "[s1] constructors fill defaults without changing explicit fields" =
  until "s1" (fun () ->
      output
        {|type Source = Web | App
type Cfg = { source: Source = Web, retries: Int = 3 }
fn main() uses Console =
  let a = Cfg {}
  let b = Cfg { source: App }
  let c: Cfg = { ..b, retries: 9 }
  let { source, .. } = c
  print(a.source)
  print(source)
  print(c.retries)
|} "Web\nApp\n9\n()\n");
  [%expect {| |}]

let%expect_test "[s3] template holes run eagerly in source order and kind is a value" =
  until "s3" (fun () ->
      output
        {|fn hole(n: Int) -> Int uses Console =
  print(n)
  n
fn kind(n: Int) -> Int = n + 10
fn consume<H>(t: Template<H>) -> Str = t.render()
fn main() uses Console =
  let t = t"\{kind(hole(1))}:\{hole(2)}"
  print("bound")
  print(consume(t))
|} "1\n2\nbound\n11:2\n()\n");
  [%expect {| skipped until s3 |}]

let%expect_test "[s3] signature plans read literals and sites but not runtime holes" =
  until "s3" (fun () ->
      output
        {|fn planned<H>(t: Template<H>) -> Str
  let parts = t.site().parts
= t.render()
fn main() uses Console = print(planned(t"value \{7}"))
|} "value 7\n()\n";
      rejects
        {|fn bad<H>(t: Template<H>) -> Int
  let holes = t.holes()
= 1
|} [ "holes"; "known" ];
      rejects
        {|fn checked(n: Int) -> Int
  let plan = try broken()
= n
fn broken() -> Int ! Bad = fail Bad
fn main() = checked(1)
|} [ "Bad"; "building" ]);
  [%expect {| skipped until s3 |}]

let%expect_test "[s4] via types, cycles, case reshaping and unsupported layouts" =
  until "s4" (fun () ->
      List.iter
        (fun (src, fragments) -> rejects src fragments)
        [ ("type Id = opaque Int\nfn read(s: Str) -> Id = 1\nfn write(id: Id) -> Int = id\nformat wire for Id = Str via (read, write)\n",
           [ "via"; "Str" ]);
          ("import shape\ntype A = { n: Int }\ntype B = { n: Int }\nfn read(b: B) -> A = { n: b.n }\nfn write(a: A) -> B = { n: a.n }\nfn back(a: A) -> B = { n: a.n }\nfn forth(b: B) -> A = { n: b.n }\nformat wire for A = B via (read, write)\nformat wire for B = A via (back, forth)\nlet SHAPE = try shape.through<A>([A.wire, B.wire])\n",
           [ "cycle"; "wire" ]);
          ("type E = A { n: Int }\nformat fields for E.A = n\nformat wire for E =\n  | A: E.A.fields\n    n\n",
           [ "A"; "both" ]);
          ("type PageHeader = { id: Int }\nformat disk for PageHeader, le =\n  id: UInt16\n",
           [ "layout"; "not" ]) ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] look visibility protects constructors" =
  until "s4" (fun () ->
      let files =
        [ ("main.ren", "import money\nlet RAW = money.Money.raw\nfn main() = ()\n");
          ("money.ren", "pub type Money = opaque Int\nfn read(n: Int) -> Money = n\nfn write(m: Money) -> Int = m\nformat raw for Money = Int via (read, write)\n") ]
      in
      let said, raised = captured (fun () -> types_files files) in
      Option.iter raise raised;
      List.iter (fun part -> assert (contains said part))
        [ "error:"; "help:"; "raw"; "private" ];
      rejects
        "pub type Money = opaque Int\nfn read(n: Int) -> Money = n\nfn write(m: Money) -> Int = m\npub format raw for Money = Int via (read, write)\n"
        [ "pub"; "private" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] look directions and conflicting choices" =
  until "s4" (fun () ->
      List.iter
        (fun (direction, call, fragment) ->
          rejects
            ("import json\ntype User = { id: Int }\nformat wire for User, " ^ direction
             ^ " = id\nlet API = json.settings(formats: [User.wire])\nfn main() = " ^ call ^ "\n")
            [ fragment; "wire" ])
        [ ("writes", "try json.decode<User>(\"{\\\"id\\\":1}\", API)", "read");
          ("reads", "try json.encode(User(id: 1), API)", "write") ];
      rejects
        "import shape\ntype User = { id: Int }\nformat a for User = id\nformat b for User = id\nlet BAD = try shape.through<User>([User.a, User.b])\n"
        [ "User"; "two" ];
      rejects
        "import shape\ntype Secret = opaque Int\nlet BAD = try shape.through<Secret>([])\n"
        [ "Secret"; "opaque" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] dependency shape and nondata Call refusal" =
  until "s4" (fun () ->
      output
        {|import shape
dep Keys =
  get: fn(key: Str) -> Int ! Missing
fn main() uses Console =
  print(Keys.shape == Keys.shape)
|} "true\n()\n";
      rejects
        "dep Bad =\n  use: fn(body: fn() -> Int) -> Int\nlet BAD = Bad.Call.shape\n"
        [ "Bad"; "data" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s5] json strictness, casing, defaults and nested options" =
  until "s5" (fun () ->
      rejects
        "import json\ntype User = { customer_id: Int, customerId: Int }\nlet API = json.settings(keys: camel_case)\nfn main() = try json.decode<User>(\"{}\", API)\n"
        [ "customerId"; "twice" ];
      rejects
        "import json\ntype User = { id: Int }\nfn settings(n: Int) = json.settings()\nfn decode(n: Int, s: Str) = try json.decode<User>(s, settings(n))\n"
        [ "known"; "top-level" ];
      output
        {|import json
type User = { customer: Int, display_name: Str }
format wire for User =
  customerId = customer
  ..
let API = json.settings(keys: snake_case, formats: [User.wire], unknown: Ignore)
fn main() uses Console =
  print(try json.encode(try json.decode<User>("{\"customerId\":7,\"display_name\":\"a\",\"future\":0}", API), API))
|} "{\"customerId\":7,\"display_name\":\"a\"}\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] json sum payloads and adjacent tag policy" =
  until "s5" (fun () ->
      output
        {|import json
type Entry = { key: Str }
type Event = Named { id: Int } | Record(Entry) | Scalar(Int) | Empty
let ADJ = json.settings(tag: Adjacent("type", "data"))
fn main() uses Console =
  print(try json.encode(Named { id: 7 }))
  print(try json.encode(Record({ key: "a" })))
  print(try json.encode(Scalar(2)))
  print(try json.encode(Empty))
  print(try json.encode(Scalar(2), ADJ))
|} "{\"type\":\"Named\",\"id\":7}\n{\"type\":\"Record\",\"key\":\"a\"}\n{\"type\":\"Scalar\",\"value\":2}\n{\"type\":\"Empty\"}\n{\"type\":\"Scalar\",\"data\":2}\n()\n";
      rejects
        "import json\ntype E = A { tag: Int }\nlet API = json.settings(tag: Adjacent(\"tag\", \"data\"))\nfn main() = try json.decode<E>(\"{}\", API)\n"
        [ "tag"; "field" ];
      rejects
        "import json\ntype E = A | B\nformat wire for E =\n  | A as 1\n  | B as 2\nlet API = json.settings(formats: [E.wire])\nfn main() = try json.decode<E>(\"{}\", API)\n"
        [ "tag"; "Str" ]);
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] json's untyped numbers and typed Float" =
  until "s5" (fun () ->
      output
        {|import json
import shape
fn main() uses Console =
  print(try json.decode<Float>("1.5"))
  print(attempt json.decode<shape.Value>("1.5"))
|} "1.5\nErr(Invalid(\"\", \"a non-whole number needs Decimal, which is not built yet\"))\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] json preserves Raw extra fields and recursively walks Ref" =
  until "s5" (fun () ->
      output
        {|import json
type Envelope = { id: Int, extra: Map<Str, json.Raw> }
type Tree = Leaf(Int) | Branch(Array<Tree>)
fn main() uses Console =
  let e = try json.decode<Envelope>("{\"id\":1,\"future\": [ 1, 2 ]}")
  print(try json.encode(e))
  let t = Branch([Leaf(1), Branch([Leaf(2)])])
  print(try json.decode<Tree>(try json.encode(t)) == t)
|} "{\"id\":1,\"future\": [ 1, 2 ]}\ntrue\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] cli reads through parse and dependency Call" =
  until "s5" (fun () ->
      output
        {|import cli
type Region = opaque Str
  pub fn parse(s: Str) -> Region = s
  pub fn repr(self) -> Str = self
type Options = { region: Region }
dep Keys =
  get: fn(key: Str) -> Str
fn main() uses Console =
  print(try cli.parse<Options>(["--region", "west"]))
  print(try cli.parse<Keys.Call>(["get", "--key", "hello"]))
|} "Options { region: west }\nGet { key: \"hello\" }\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s6] imports expose exactly their existing declarations" =
  until "s6" (fun () ->
      List.iter
        (fun (module_, src) ->
          let said, raised = captured (fun () -> types ("import " ^ module_ ^ "\n" ^ src)) in
          Option.iter raise raised;
          assert (not (contains said "error:")))
        [ ("std/clock", "fn stamp() -> Time uses Clock = Clock.now()\n");
          ("std/fs", "import std/path\nfn exists() -> Bool uses Fs = Fs.exists(Path.of(\"a\"))\n");
          ("std/random", "fn draw() uses Random = Random.int(1)\n");
          ("std/os", "fn args() uses Os = Os.args()\n");
          ("sim", "fn main() = ()\n"); ("sync", "fn main() = ()\n") ]);
  [%expect {| skipped until s6 |}]

let%expect_test "[s4] a leaf's parse is the only way into an opaque type" =
  until "s4" (fun () ->
      output
        {|import shape
type Money = opaque Int
  pub fn parse(n: Int) -> Money ! Negative =
    if n < 0 then fail Negative
    n
  pub fn repr(self) -> Int = self
fn main() uses Console =
  print(try shape.view<Money>(try shape.build<Money>(shape.Value.Int(7))))
  print(attempt shape.build<Money>(shape.Value.Int(-1)))
|} "Int(7)\nErr(Invalid(\"\", \"Negative\"))\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] defaults, Option absence and differing constants at the door" =
  until "s4" (fun () ->
      output
        {|import shape
type Cfg = { port: Int = 8080, name: Option<Str> }
fn main() uses Console =
  let c = try shape.build<Cfg>(shape.Value.Fields([]))
  print(c.port)
  print(c.name)
|} "8080\nNone\n()\n";
      output
        {|import shape
type Item = { id: Int }
format wire for Item =
  kind = "item"
  id
fn main() uses Console =
  print(attempt shape.build<Item>(shape.Value.Fields([("kind", shape.Value.Text("wrong")), ("id", shape.Value.Int(1))]), [Item.wire]))
|} "Err(Invalid(\"kind\", \"expected constant item\"))\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] first and all problems use the look's path and original field" =
  until "s4" (fun () ->
      output
        {|import shape
type User = { customer: Int, total: Int }
format wire for User =
  customerId = customer
  total
fn main() uses Console =
  let v = shape.Value.Fields([])
  print(attempt shape.build<User>(v, [User.wire]))
  print(shape.build_all<User>(v, [User.wire]))
|} "Err(Missing(\"customerId\", \"User.customer\"))\nErr(Problems([Err(Missing(\"customerId\", \"User.customer\")), Err(Missing(\"total\", \"User.total\"))]))\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] view refuses a missing repr at the complete field path" =
  until "s4" (fun () ->
      rejects
        {|import shape
type Token = opaque Str
  pub fn parse(s: Str) -> Token = s
type Cfg = { admin_token: Token }
fn encode(cfg: Cfg) = try shape.view<Cfg>(cfg)
|} [ "repr"; "Cfg.admin_token" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s5] json absence, null, unknown and invalid syntax are distinct" =
  until "s5" (fun () ->
      output
        {|import json
type Cfg = { id: Int, port: Int = 8080, note: Option<Str> }
fn main() uses Console =
  print(attempt json.decode<Cfg>("{}"))
  print(attempt json.decode<Cfg>("{\"id\":1,\"port\":null}"))
  print(attempt json.decode<Cfg>("{\"id\":1,\"other\":2}"))
|} "Err(Missing(\"id\", \"Cfg.id\"))\nErr(Mismatch(\"port\", \"Int\", \"null\"))\nErr(Unknown(\"other\"))\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] bounds use runtime Limits with an exact depth boundary" =
  until "s5" (fun () ->
      output
        {|import json
import shape
type Tree = Leaf(Int) | Branch(Array<Tree>)
fn main() uses Console =
  let limits = shape.Limits { depth: 1 }
  print(attempt json.decode<Tree>("{\"type\":\"Branch\",\"value\":[{\"type\":\"Leaf\",\"value\":1}]}", limits: limits))
|} "Err(TooDeep(\"value[0]\", 1))\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] cli unknown flags suggest the closest spelling and docs become help" =
  until "s5" (fun () ->
      output
        {|import cli
type Cmd = {
  // TCP listener port.
  listen: Int = 8080
 }
let CLI = try cli.spec<Cmd>()
fn main() uses Console =
  let help = cli.help(CLI)
  print(help.includes("TCP listener port."))
  print(attempt cli.parse<Cmd>(["--litsen", "9000"], CLI))
|} "true\nErr(Usage(\"unknown flag --litsen; did you mean --listen?\"))\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] bin bytes equal the runtime core table's golden vectors" =
  until "s5" (fun () ->
      output
        {|import bin
type Pair = { n: Int, flag: Bool }
type Choice = A | B(Int)
fn main() uses Console =
  print(try bin.encode(()) == b"")
  print(try bin.encode(false) == b"\x00")
  print(try bin.encode(true) == b"\x01")
  print(try bin.encode(0) == b"\x00")
  print(try bin.encode(-1) == b"\x01")
  print(try bin.encode(64) == b"\x80\x01")
  print(try bin.encode("hi") == b"\x02hi")
  print(try bin.encode(b"hi") == b"\x02hi")
  print(try bin.encode(Pair(n: -1, flag: true)) == b"\x01\x01")
  print(try bin.encode(B(2)) == b"\x01\x04")
  print(try bin.encode([1, -1]) == b"\x02\x02\x01")
  print(try bin.decode<Unit>(b"") == ())
  print(try bin.decode<Bool>(b"\x01"))
  print(try bin.decode<Int>(b"\x80\x01") == 64)
  print(try bin.decode<Str>(b"\x02hi") == "hi")
  print(try bin.decode<Bytes>(b"\x02hi") == b"hi")
  print(try bin.decode<Pair>(b"\x01\x01") == Pair(n: -1, flag: true))
  print(try bin.decode<Choice>(b"\x01\x04") == B(2))
  print(try bin.decode<Array<Int>>(b"\x02\x02\x01") == [1, -1])
|} "true\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s8] the real CLI freezes unchanged input and rejects three mutations" =
  until "s8" (fun () ->
      let runner =
        match Sys.getenv_opt "REN_SHAPES_CLI_TEST" with
        | Some path -> path
        | None -> failwith "REN_SHAPES_CLI_TEST must name bench/shapes/check.py"
      in
      let code = Sys.command (Filename.quote runner ^ " --freeze-only") in
      if code <> 0 then failwith "the formats.lock CLI fixture failed");
  [%expect {| skipped until s8 |}]

let%expect_test "[s4] imported looks with the same type and name are ambiguous" =
  until "s4" (fun () ->
      let said, raised = captured (fun () -> types_files
        [ ("main.ren", "import types\nimport first\nimport second\nlet LOOK = types.Id.wire\nfn main() = ()\n");
          ("types.ren", "pub type Id = { n: Int }\n");
          ("first.ren", "import types\npub format wire for types.Id = n\n");
          ("second.ren", "import types\npub format wire for types.Id = n\n") ]) in
      Option.iter raise raised;
      List.iter (fun part -> assert (contains said part))
        [ "error:"; "help:"; "wire"; "first"; "second"; "rename" ]);
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] successful via chain reaches the encoded leaf once" =
  until "s4" (fun () ->
      output
        {|import shape
type Outer = opaque Int
  pub fn make(n: Int) -> Outer = n
  pub fn number(self) -> Int = self
type Middle = { n: Int }
fn read(m: Middle) -> Outer = Outer.make(m.n)
fn write(o: Outer) -> Middle = { n: o.number() }
fn read_middle(n: Int) -> Middle = { n }
fn write_middle(m: Middle) -> Int = m.n
format wire for Outer = Middle via (read, write)
format wire for Middle = Int via (read_middle, write_middle)
fn main() uses Console =
  let looks = [Outer.wire, Middle.wire]
  let v = try shape.build<Outer>(shape.Value.Int(7), looks)
  print(v.number())
  print(try shape.view<Outer>(v, looks))
|} "7\nInt(7)\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s5] every derived-bin type family has golden bytes and round trips" =
  until "s5" (fun () ->
      let vectors =
        [ ("Unit", "()", {|b""|});
          ("Bool", "false", {|b"\x00"|});
          ("Bool", "true", {|b"\x01"|});
          ("Int", "0", {|b"\x00"|});
          ("Int", "-1", {|b"\x01"|});
          ("Int", "64", {|b"\x80\x01"|});
          ("Int8", "-1", {|b"\xff"|});
          ("UInt8", "255", {|b"\xff"|});
          ("Int16", "-2", {|b"\xfe\xff"|});
          ("UInt16", "258", {|b"\x02\x01"|});
          ("Int32", "-2", {|b"\xfe\xff\xff\xff"|});
          ("UInt32", "258", {|b"\x02\x01\x00\x00"|});
          ("UInt64", "258", {|b"\x02\x01\x00\x00\x00\x00\x00\x00"|});
          ("Float", "1.0", {|b"\x00\x00\x00\x00\x00\x00\xf0\x3f"|});
          ("Float32", "1.0", {|b"\x00\x00\x80\x3f"|});
          ("Str", "\"é\"", {|b"\x02\xc3\xa9"|});
          ("Bytes", {|b"\xff"|}, {|b"\x01\xff"|});
          ("(Int, Bool)", "(-1, true)", {|b"\x01\x01"|});
          ("Option<Int>", "Some(2)", {|b"\x00\x04"|});
          ("Option<Int>", "None", {|b"\x01"|});
          ("Result<Int, ! Bad>", "Ok(1)", {|b"\x00\x02"|});
          ("Result<Int, ! Bad>", "Err(Bad)", {|b"\x01\x00"|});
          ("Array<Int>", "[1, -1]", {|b"\x02\x02\x01"|}) ]
      in
      List.iter
        (fun (ty, value, bytes) ->
          output
            ("import bin\nfn main() uses Console =\n  let v: " ^ ty ^ " = " ^ value
             ^ "\n  print(try bin.encode(v) == " ^ bytes
             ^ ")\n  print(try bin.decode<" ^ ty ^ ">(" ^ bytes ^ ") == v)\n")
            "true\ntrue\n()\n")
        vectors;
      output
        {|import bin
type Id = opaque Int
  pub fn parse(n: Int) -> Id = n
  pub fn repr(self) -> Int = self
fn main() uses Console =
  let v = Id.parse(7)
  print(try bin.encode(v) == b"\x0e")
  print(try bin.decode<Id>(b"\x0e") == v)
  var m: Map<Str, Int> = Map.empty
  &m.set("b", 2)
  &m.set("a", 1)
  print(try bin.encode(m) == b"\x02\x01b\x04\x01a\x02")
  print(try bin.decode<Map<Str, Int>>(b"\x02\x01b\x04\x01a\x02") == m)
  var s: Set<Int> = Set.empty
  &s.add(2)
  &s.add(1)
  print(try bin.encode(s) == b"\x02\x04\x02")
  print(try bin.decode<Set<Int>>(b"\x02\x04\x02") == s)
|} "true\ntrue\ntrue\ntrue\ntrue\ntrue\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] bin rejects malformed encodings without accepting a prefix" =
  until "s5" (fun () ->
      List.iter
        (fun (ty, bytes) ->
          output
            ("import bin\nfn main() uses Console =\n  print(match attempt bin.decode<" ^ ty ^ ">(" ^ bytes
             ^ ")\n    Ok(_) => false\n    Err(_) => true)\n")
            "true\n()\n")
        [ ("Int", {|b"\x80\x00"|}); ("Int", {|b"\x80"|});
          ("Int", {|b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02"|});
          ("Bool", {|b"\x02"|}); ("Str", {|b"\x01\xff"|});
          ("Option<Int>", {|b"\x02"|}); ("Int", {|b"\x00\x00"|});
          ("Map<Str, Int>", {|b"\x02\x01a\x00\x01a\x00"|}) ]);
  [%expect {| skipped until s5 |}]

let%expect_test "[s3] template site's parts, raw parts, source types and identity" =
  until "s3" (fun () ->
      output
        {|fn inspect<H>(t: Template<H>) uses Console =
  let site = t.site()
  print(site.parts == ["a\n", "z"])
  print(site.raw_parts == [#"a\n"#, "z"])
  print(site.holes[0].source)
  print(site.id != 0)
  print(site.hash == site.hash)
fn main() uses Console =
  let value = 7
  inspect(t"a\n\{value}z")
|} "true\ntrue\nvalue\ntrue\ntrue\n()\n");
  [%expect {| skipped until s3 |}]

let%expect_test "[s4] field, caller, repr and structure win in precisely that order" =
  until "s4" (fun () ->
      output
        {|import shape
type OrderId = opaque Int
  pub fn parse(n: Int) -> OrderId = n
  pub fn repr(self) -> Int = self
type CustomerId = opaque Int
  pub fn parse(n: Int) -> CustomerId = n
  pub fn repr(self) -> Int = self
type Money = opaque Int
  pub fn parse(s: Str) -> Money = 0
  pub fn repr(self) -> Str = "money"
  pub fn from_cents(n: Int) -> Money = n
  pub fn cents(self) -> Int = self
type Time = opaque Int
  pub fn parse(s: Str) -> Time = 0
  pub fn repr(self) -> Str = "time"
  pub fn from_unix(n: Int) -> Time = n
  pub fn unix_seconds(self) -> Int = self
type Line = { sku: Str }
type Order = { id: OrderId, customer: CustomerId, total: Money, placed: Time, lines: Array<Line> }
format cents for Money = Int via (Money.from_cents, fn(m) => m.cents())
format unix for Time = Int via (Time.from_unix, fn(t) => t.unix_seconds())
format v1 for Order =
  kind = "order"
  id
  customerId = customer
  total: Money.cents
  placed
  ..
fn main() uses Console =
  let order = Order(id: OrderId.parse(1), customer: CustomerId.parse(2), total: Money.from_cents(42), placed: Time.from_unix(100), lines: [{ sku: "a" }])
  let v = try shape.view<Order>(order, [Time.unix, Order.v1])
  print(v == shape.Value.Fields([
    ("kind", shape.Value.Text("order")),
    ("id", shape.Value.Int(1)),
    ("customerId", shape.Value.Int(2)),
    ("total", shape.Value.Int(42)),
    ("placed", shape.Value.Int(100)),
    ("lines", shape.Value.List([shape.Value.Fields([("sku", shape.Value.Text("a"))])]))]))
|} "true\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s3] site ids are per literal and hashes ignore hole values" =
  until "s3" (fun () ->
      output
        {|fn identify<H>(t: Template<H>) -> Int = t.site().id
fn fingerprint<H>(t: Template<H>) -> Int = t.site().hash
fn same_site(n: Int) -> Int = identify(t"value \{n}")
fn main() uses Console =
  print(same_site(1) == same_site(2))
  print(identify(t"value \{1}") != identify(t"value \{1}"))
  print(fingerprint(t"value \{1}") == fingerprint(t"value \{2}"))
|} "true\ntrue\ntrue\n()\n");
  [%expect {| skipped until s3 |}]

let%expect_test "[s4] dependency shape contains operation names, fields, results and errors" =
  until "s4" (fun () ->
      output
        {|import shape
dep Keys =
  get: fn(key: Str) -> Int ! Missing
fn main() uses Console =
  match Keys.shape
    shape.Shape.Dependency { operations, .. } =>
      print(operations.len() == 1)
      let get = operations[0]
      print(get.name == "get")
      print(get.params[0].name == "key")
      print(get.params[0].shape == shape.Shape.Str)
      print(get.result == shape.Shape.Int)
      print(get.errors[0].name == "Missing")
    _ => panic("dependency shape missing")
|} "true\ntrue\ntrue\ntrue\ntrue\ntrue\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s4] field and case documentation is declaration data" =
  until "s4" (fun () ->
      output
        {|import shape
type User = {
  // The unique number.
  // Stable across sessions.
  id: Int
 }
type Cmd =
  // Read a key.
  | Get { key: Str }
fn main() uses Console =
  match User.shape
    shape.Shape.Record { fields, .. } => print(fields[0].doc == "The unique number.\nStable across sessions.")
    _ => panic("record shape missing")
  match Cmd.shape
    shape.Shape.Sum { cases, .. } => print(cases[0].doc == "Read a key.")
    _ => panic("sum shape missing")
|} "true\ntrue\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s5] json checks map key text forms and preserves map keys" =
  until "s5" (fun () ->
      rejects
        "import json\ntype Key = { id: Int }\nfn decode(s: Str) = try json.decode<Map<Key, Int>>(s)\n"
        [ "key"; "Array<(K, V)>" ];
      output
        {|import json
let API = json.settings(keys: snake_case)
fn main() uses Console =
  var m: Map<Str, Int> = Map.empty
  &m.set("customerId", 1)
  print(try json.encode(m, API))
|} "{\"customerId\":1}\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s5] json null policy, duplicate keys and tag order" =
  until "s5" (fun () ->
      output
        {|import json
type User = { email: Option<Str> }
type Event = Put(Int) | Empty
let API = json.settings(none: Null)
fn main() uses Console =
  print(try json.encode(User(email: None), API))
  print(try json.decode<Event>("{\"value\":7,\"type\":\"Put\"}") == Put(7))
  print(match attempt json.decode<User>("{\"email\":null,\"email\":null}")
    Ok(_) => false
    Err(_) => true)
|} "{\"email\":null}\ntrue\ntrue\n()\n");
  [%expect {| skipped until s5 |}]

let%expect_test "[s3] templates never implicitly become text" =
  until "s3" (fun () ->
      rejects
        "fn text(s: Str) = ()\nfn main() = text(t\"value\")\n"
        [ "Template"; "Str"; "render" ]);
  [%expect {| skipped until s3 |}]

let%expect_test "[s1] pure parse and repr execute as ordinary methods" =
  until "s1" (fun () ->
      output
        {|type Id = opaque Int
  pub fn parse(n: Int) -> Id ! Negative =
    if n < 0 then fail Negative
    n
  pub fn repr(self) -> Int = self
fn main() uses Console =
  let id = try Id.parse(7)
  print(id.repr())
|} "7\n()\n");
  [%expect {| |}]

let%expect_test "[s2] data handler descriptions are frozen without executing operations" =
  until "s2" (fun () ->
      output
        {|dep Numbers =
  get: fn() -> Int
handler constant(n: Int) for Numbers =
  get() => n
let HANDLER: Numbers = constant(7)
fn main() uses Console =
  print(with HANDLER in Numbers.get())
|} "7\n()\n");
  [%expect {||}]

let%expect_test "[s2] the same budget failure reports exactly the same steps" =
  until "s2" (fun () ->
      let src = "let NEVER = forever()\nfn forever() -> Int =\n  var n = 0\n  while true\n    n += 1\n  n\n" in
      let once () =
        let src = clean src ^ "\nfn main() = ()\n" in
        let said, raised = captured (fun () ->
            report src (fun () -> ignore (Ren.Driver.check ~file src))) in
        Option.iter raise raised;
        List.iter (fun part -> assert (contains said part)) [ "NEVER"; "steps"; "limit" ];
        said
      in
      assert (once () = once ()));
  [%expect {||}]

let%expect_test "[s3] site's stable hash has fixed empty, escaped and Unicode vectors" =
  until "s3" (fun () ->
      output
        {|fn fingerprint<H>(t: Template<H>) -> Int = t.site().hash
fn main() uses Console =
  let x = 7
  print(fingerprint(t""))
  print(fingerprint(t"value \{x}"))
  print(fingerprint(t"a\n\{x}z"))
  print(fingerprint(t"é\{x}"))
|} "-8245200967992839256\n-4753601207794907562\n4011749346734791143\n9120157815504581253\n()\n");
  [%expect {| skipped until s3 |}]

let%expect_test "[s4] a template hole retains its static type shape" =
  until "s4" (fun () ->
      output
        {|fn inspect<H>(t: Template<H>) -> Bool = t.site().holes[0].shape == Int.shape
fn main() uses Console = print(inspect(t"value \{7}"))
|} "true\n()\n");
  [%expect {| skipped until s4 |}]

let%expect_test "[s6] moved supporting types and test handlers have exact import help" =
  until "s6" (fun () ->
      let type_names =
        [ ("std/clock", [ "Time"; "Instant" ]);
          ("std/net", [ "Addr"; "Listener"; "Conn"; "Signal" ]);
          ("std/fs", [ "File" ]);
          ("std/proc", [ "Kill"; "Command"; "Exit" ]);
          ("std/actors", [ "Family<Int, Console>"; "Pinned<Console>";
                            "InstanceCounts"; "Stamped<Int>"; "By"; "Fold<Console>"; "Evict" ]);
          ("std/path", [ "Path" ]); ("std/bytes", [ "ByteCursor" ]);
          ("std/str", [ "Chars" ]); ("std/collections", [ "Zip<Int, Int>"; "Zip3<Int, Int, Int>" ]);
          ("std/shape", [ "Operation" ]) ]
      in
      List.iter (fun (module_, names) -> List.iter
          (fun name -> rejects ("fn f(x: " ^ name ^ ") = ()\n") [ "import " ^ module_ ]) names)
        type_names;
      List.iter (fun (module_, names) -> List.iter
          (fun name -> rejects ("fn f() uses " ^ name ^ " = ()\n") [ "import " ^ module_ ]) names)
        [ ("std/clock", [ "Clock"; "TestClock" ]);
          ("std/random", [ "Random"; "TestRandom" ]);
          ("std/net", [ "Net" ]); ("std/fs", [ "Fs" ]); ("std/os", [ "Os" ]);
          ("std/proc", [ "Proc"; "TestProc" ]);
          ("std/actors", [ "Instances"; "Actors<Int, Console>" ]) ];
      List.iter (fun (module_, names) -> List.iter
          (fun name -> rejects ("fn f() ! " ^ name ^ " = ()\n") [ "import " ^ module_ ]) names)
        [ ("std/bytes", [ "FormatError" ]); ("std/fs", [ "FsError" ]);
          ("std/proc", [ "ProcError" ]); ("std/net", [ "NetError" ]) ];
      List.iter (fun (module_, names) -> List.iter
          (fun name -> rejects ("fn main() = " ^ name ^ "\n") [ "import " ^ module_ ]) names)
        [ ("std/clock", [ "test_clock" ]); ("std/random", [ "test_random" ]);
          ("std/fs", [ "mem_fs" ]); ("std/os", [ "test_os" ]); ("std/proc", [ "test_proc" ]);
          ("std/actors", [ "actors"; "striped"; "Worker"; "Key"; "Unmerged"; "Sum"; "Max"; "Min"; "Concat"; "Custom"; "Lru" ]);
          ("std/proc", [ "Tree"; "Child" ]);
          ("std/shape", [ "operations" ]); ("std/retry", [ "retry" ]);
          ("std/runtime", [ "lib_panic"; "family_kept" ]) ];
      List.iter (fun (module_, errors) -> List.iter
          (fun error ->
            let imports = if module_ = "std/fs" then "import std/path\n" else "" in
            rejects (imports ^ "fn f() = fail " ^ error ^ "\n") [ "import " ^ module_ ]) errors)
        [ ("std/bytes", [ "Short(0, 1)"; "Malformed(0, \"\", \"bad\")"; "UnknownTag(0, 1)" ]);
          ("std/fs", [ "NoSuchFile(Path.of(\"a\"))"; "NotAllowed(Path.of(\"a\"))";
                       "IsAFolder(Path.of(\"a\"))"; "FsFailed(Path.of(\"a\"), \"bad\")" ]);
          ("std/proc", [ "NoSuchProgram(\"a\")"; "CantRun(\"a\", \"bad\")"; "Killed(\"a\")" ]);
          ("std/net", [ "Refused({ host: \"a\", port: 1 })"; "InUse({ host: \"a\", port: 1 })";
                        "Closed"; "NetFailed(\"bad\")" ]) ]);
  [%expect {| skipped until s6 |}]

let%expect_test "[s5] bin canonicalizes NaNs, preserves signed zero and encodes Int extremes" =
  until "s5" (fun () ->
      output
        {|import bin
fn main() uses Console =
  let nan = b"\x01\x00\x00\x00\x00\x00\xf8\x7f".f64_le(0)
  let canonical = b"\x00\x00\x00\x00\x00\x00\xf8\x7f"
  print(try bin.encode(nan) == canonical)
  print(try bin.encode(try bin.decode<Float>(canonical)) == canonical)
  let nan32 = b"\x01\x00\xc0\x7f".f32_le(0)
  let canonical32 = b"\x00\x00\xc0\x7f"
  print(try bin.encode(nan32) == canonical32)
  print(try bin.encode(try bin.decode<Float32>(canonical32)) == canonical32)
  let minus_zero = b"\x00\x00\x00\x00\x00\x00\x00\x80"
  print(try bin.encode(-0.0) == minus_zero)
  print(try bin.encode(try bin.decode<Float>(minus_zero)) == minus_zero)
  let minus_zero32 = b"\x00\x00\x00\x80"
  print(try bin.encode(try bin.decode<Float32>(minus_zero32)) == minus_zero32)
  let low = -9223372036854775807 - 1
  let high = 9223372036854775807
  let low_bytes = b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01"
  let high_bytes = b"\xfe\xff\xff\xff\xff\xff\xff\xff\xff\x01"
  print(try bin.encode(low) == low_bytes)
  print(try bin.decode<Int>(low_bytes) == low)
  print(try bin.encode(high) == high_bytes)
  print(try bin.decode<Int>(high_bytes) == high)
|} "true\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\n()\n");
  [%expect {| skipped until s5 |}]
