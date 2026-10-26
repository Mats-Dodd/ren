(* Lowering to Core (lower.ml), and Core Lint (core_lint.ml), which every
   test that runs a program or prints its types also runs. A local prints
   as its name and binder id; a temporary's name starts with `$`. *)

open Helpers

let%expect_test "assignments to places become updates of a variable" =
  core
    {|
type P = { x: Int, y: Int }
fn main() =
  var p = P { x: 1, y: 2 }
  p.x += 1
  var xs = [1, 2]
  xs[0] = 5
  var grid = [[1]]
  grid[0][0] = p.y
|};
  [%expect
    {|
    (fn main () ev/1
      (let p/2 (record (x: 1) (y: 2))
        (seq (= p/2 (update p/2 x: (+ (. p/2 x) 1)))
          (let xs/3 (array 1 2)
            (seq (= xs/3 (set xs/3 0 5))
              (let grid/4 (array (array 1))
                (let $v/5 (. p/2 y)
                  (= grid/4 (set grid/4 0 (set (get grid/4 0) 0 $v/5))))))))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "a place passed with & goes through a temporary" =
  core
    {|
type P = { x: Int, y: Int }
fn swap(inout a: Int, inout b: Int) =
  let t = a
  a = b
  b = t
fn main() =
  var ps = [P { x: 1, y: 2 }]
  var n = 3
  swap(&ps[0].x, &n)
|};
  [%expect
    {|
    (fn swap (a/1 b/2) ev/3 (let t/4 a/1 (seq (= a/1 b/2) (= b/2 t/4))))
    (fn main () ev/1
      (let ps/2 (array (record (x: 1) (y: 2)))
        (let n/3 3
          (let $ref/4 (. (get ps/2 0) x)
            (let $ref/5 n/3
              (let $result/6 (call ev/1 swap &$ref/4 &$ref/5)
                (seq (= ps/2 (set ps/2 0 (update (get ps/2 0) x: $ref/4)))
                  (seq (= n/3 $ref/5) $result/6))))))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "for loops become while loops; for & writes back" =
  core
    {|
fn main() =
  var xs = [1, 2]
  for x in &xs
    x *= 2
  for x in xs
    if x > 2 then print(x)
|};
  [%expect
    {|
    (fn main () ev/1
      (let xs/2 (array 1 2)
        (seq
          (let $n/3 (length xs/2)
            (let $i/4 0
              (while (< $i/4 $n/3)
                (let x/5 (get xs/2 $i/4)
                  (seq (= x/5 (* x/5 2))
                    (seq (= xs/2 (set xs/2 $i/4 x/5)) (= $i/4 (+ $i/4 1))))))))
          (let $xs/6 xs/2
            (let $n/7 (length $xs/6)
              (let $i/8 0
                (while (< $i/8 $n/7)
                  (let x/9 (get $xs/6 $i/8)
                    (seq (if (> x/9 2) (call ev/1 print x/9) ())
                      (= $i/8 (+ $i/8 1)))))))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main)))
    |}]

let%expect_test "a lambda lists what it captures" =
  core {|
fn main() =
  let n = 1
  let m = 2
  let f = fn(x) => x + n
  f(m)
|};
  [%expect
    {|
    (fn main () ev/1
      (let n/2 1
        (let m/3 2
          (let f/4 (lambda (x/5) (captures n/2) ev/6 (+ x/5 n/2))
            (call ev/1 f/4 m/3)))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "an index in a place is evaluated once, before the call" =
  core
    {|
type P = { x: Int, xs: Array<Int> }
fn bump(inout n: Int) = n += 1
fn main() =
  var ps = [P { x: 1, xs: [2] }]
  var i = 0
  bump(&ps[i].x)
  for y in &ps[i].xs
    y += 1
|};
  [%expect
    {|
    (fn bump (n/1) ev/2 (= n/1 (+ n/1 1)))
    (fn main () ev/1
      (let ps/2 (array (record (x: 1) (xs: (array 2))))
        (let i/3 0
          (seq
            (let $index/4 i/3
              (let $ref/5 (. (get ps/2 $index/4) x)
                (let $result/6 (call ev/1 bump &$ref/5)
                  (seq
                    (= ps/2
                      (set ps/2 $index/4 (update (get ps/2 $index/4) x: $ref/5)))
                    $result/6))))
            (let $index/7 i/3
              (let $n/8 (length (. (get ps/2 $index/7) xs))
                (let $i/9 0
                  (while (< $i/9 $n/8)
                    (let y/10 (get (. (get ps/2 $index/7) xs) $i/9)
                      (seq (= y/10 (+ y/10 1))
                        (seq
                          (= ps/2
                            (set ps/2 $index/7
                              (update (get ps/2 $index/7) xs:
                                (set (. (get ps/2 $index/7) xs) $i/9 y/10))))
                          (= $i/9 (+ $i/9 1)))))))))))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

(* A use of a generic function carries the type arguments it picks, which
   a typed print shows: what each of the function's variables stands for,
   in the variables of the function it's used in. *)

let%expect_test "a typed print shows each use's type arguments" =
  core ~types:true
    {|
type Stack<T> = { items: Array<T> }
  fn push(inout self, x: T) = &self.items.push(x)
  let empty: Stack<T> = Stack { items: [] }
fn pair(a, b) = [a, b]
fn main() =
  var s = Stack.empty
  &s.push(1)
  let ns = pair(1, 2)
  let words = pair("a", "b")
  ()
|};
  [%expect
    {|
    (fn Stack.push : fn(inout test.Stack<T>, T) ! ..e uses ..d (self/1 x/2) ev/3
      (let $ref/4 (. self/1 items)
        (let $arg/5 x/2
          (let $result/6 (call ev/3 (inst Array.push T {} {..d}) &$ref/4 $arg/5)
            (seq (= self/1 (update self/1 items: $ref/4)) $result/6)))))
    (fn Stack.empty : fn() -> test.Stack<T> ! ..e uses ..d () ev/1
      (record (items: (array))))
    (fn pair : fn(T, T) -> Array<T> ! ..e uses ..d (a/1 b/2) ev/3 (array a/1 b/2))
    (fn main : fn() ! ..e uses ..d () ev/1
      (let s/2 (inst Stack.empty Int)
        (seq (call ev/1 (inst Stack.push Int {} {..d}) &s/2 1)
          (let ns/3 (call ev/1 (inst pair Int {} {..d}) 1 2)
            (let words/4 (call ev/1 (inst pair Str {} {..d}) "a" "b") ())))))
    (fn $start : fn() ! ..e () ev/1 (call ev/1 (inst main {..e} {..r})))
    |}]

let%expect_test "a function of the group being checked is used at its own type"
    =
  (* [walk] and [back] are checked together, so each is used at its own
     type in the other: its type arguments are the variables of the
     function it's used in. A public function is used at a copy of the
     type its declaration gives it, even in its own body, where storing
     [f] as a `fn()` closes only that copy's rows *)
  core ~types:true
    {|
type H = { h: fn() }
fn walk(x, n) = if n == 0 then x else back(x, n - 1)
fn back(x, n) = walk(x, n)
pub fn f() =
  let k = H { h: f }
  ()
fn main() =
  let s = walk("a", 3)
  f()
|};
  [%expect
    {|
    (fn walk : fn(T, Int) -> T uses ..d (x/1 n/2) ev/3
      (if (== n/2 0) x/1 (call ev/3 (inst back T {..d}) x/1 (- n/2 1))))
    (fn back : fn(T, Int) -> T uses ..d (x/1 n/2) ev/3
      (call ev/3 (inst walk T {..d}) x/1 n/2))
    (fn f : fn() ! ..e uses ..d () ev/1 (let k/2 (record (h: (inst f {} {}))) ()))
    (fn main : fn() ! ..e uses ..d () ev/1
      (let s/2 (call ev/1 (inst walk Str {..d}) "a" 3)
        (call ev/1 (inst f {} {..d}))))
    (fn $start : fn() ! ..e () ev/1 (call ev/1 (inst main {..e} {..r})))
    |}]

(* lint catches a lowering mistake at the node it's in *)

let%expect_test "Core Lint reports a node of the wrong type" =
  let loc = Ren.Loc.point ~file 1 1 in
  let x : Ren.Core.var = { id = 1; name = "x"; ty = Ren.Ty.int } in
  let body =
    Ren.Core.mk
      (Let (x, Ren.Core.mk (Bool true) Ren.Ty.bool loc, Ren.Core.unit loc))
      Ren.Ty.unit loc
  in
  let main : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "main";
      params = [];
      ev = Ren.Core.evidence 2;
      tys = [];
      scheme =
        {
          ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed);
          names = [];
          reqs = [];
        };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ main ];
              values = [];
              shows = [];
            }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: the value of `x` has type `Bool`, but should have `Int`")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* `fn id<T>(x: T) -> T`, and a `main` that calls it with 1, using it with
   the type arguments [targs] at `fn(Int) -> Int` *)
let id_program targs =
  let loc = Ren.Loc.point ~file 1 1 in
  let fn path params ty body : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" path;
      params;
      ev = Ren.Core.evidence 9;
      tys = Ren.Core.type_params { ty; names = []; reqs = [] };
      scheme = { ty; names = []; reqs = [] };
      body;
      loc;
    }
  in
  let x : Ren.Core.var = { id = 1; name = "x"; ty = Var 0 } in
  let open_row n : Ren.Ty.row = { labels = []; tail = Some n } in
  let id =
    fn "id"
      [ { mode = Read; var = x } ]
      (Fun ([ Ren.Ty.read (Var 0) ], Var 0, open_row 0, open_row 1))
      (Ren.Core.local x loc)
  in
  let int_fn : Ren.Ty.ty =
    Fun ([ Ren.Ty.read Ren.Ty.int ], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed)
  in
  let call =
    Ren.Core.mk
      (Call
         ( Ren.Core.mk
             (Global (id.path, targs, List.map (Ren.Core.describe []) targs.tys))
             int_fn loc,
           [ Value (Ren.Core.mk (Int 1) Ren.Ty.int loc) ],
           Ren.Core.evidence 9 ))
      Ren.Ty.int loc
  in
  let main =
    fn "main" [] (Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed)) call
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ id; main ];
              values = [];
              shows = [];
            });
      print_endline "ok")

let%expect_test "Core Lint reports a use at the wrong type arguments" =
  (* at `Int`, with rows of nothing, it's clean *)
  id_program { tys = [ Ren.Ty.int ]; rows = [ Ren.Ty.closed; Ren.Ty.closed ] };
  [%expect {| ok |}];
  (* at `Bool`, its type would be `fn(Bool) -> Bool` *)
  id_program { tys = [ Ren.Ty.bool ]; rows = [ Ren.Ty.closed; Ren.Ty.closed ] };
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `id` is used at `fn(Int) -> Int`, but its type arguments make it `fn(Bool) -> Bool`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a row of `Short`, which `fn(Int) -> Int` doesn't fail with *)
  id_program
    {
      tys = [ Ren.Ty.int ];
      rows =
        [ { labels = [ Ren.Ty.label "Short" ]; tail = None }; Ren.Ty.closed ];
    };
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `id` is used at `fn(Int) -> Int`, but its type arguments make it `fn(Int) -> Int ! Short`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* and too few *)
  id_program { tys = [ Ren.Ty.int ]; rows = [] };
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `id` is given 1 type and 0 row arguments, but `fn(T) -> T ! ..e uses ..d` has 1 type and 2 row variables")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports a pattern of an error type" =
  (* a tag that a set which may hold more doesn't list: its subpattern's
     type is checked only against itself *)
  let loc = Ren.Loc.point ~file 1 1 in
  let set : Ren.Ty.ty = Errors { labels = []; tail = Some 0 } in
  let e : Ren.Core.var = { id = 1; name = "e"; ty = set } in
  let pat pkind pty : Ren.Core.pattern = { pkind; pty; ploc = loc } in
  let body =
    Ren.Core.mk
      (Match
         ( Ren.Core.local e loc,
           [
             {
               pat = pat (PTag ("Short", [ pat PWild Error ])) set;
               guard = None;
               body = Ren.Core.unit loc;
             };
           ] ))
      Ren.Ty.unit loc
  in
  let f : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "f";
      params = [ { mode = Read; var = e } ];
      ev = Ren.Core.evidence 2;
      tys = [];
      scheme =
        {
          ty =
            Fun ([ Ren.Ty.read set ], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed);
          names = [];
          reqs = [];
        };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            { home = "test"; types = []; fns = [ f ]; values = []; shows = [] }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `f`, at test.ren:1:1: a pattern has an error type")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports a fail of something that isn't an error" =
  let loc = Ren.Loc.point ~file 1 1 in
  let body =
    Ren.Core.mk (Fail (Ren.Core.mk (Int 1) Ren.Ty.int loc)) Ren.Ty.unit loc
  in
  let main : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "main";
      params = [];
      ev = Ren.Core.evidence 2;
      tys = [];
      scheme =
        {
          ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed);
          names = [];
          reqs = [];
        };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ main ];
              values = [];
              shows = [];
            }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: what `fail` fails with has type `Int`, which isn't an error set")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports an instance that is a value" =
  (* an [Instance] anywhere but the end of a [Handler]'s body: here a
     statement of [main], which a program could keep (compiler.md, "No
     cycles") *)
  let loc = Ren.Loc.point ~file 1 1 in
  let body =
    Ren.Core.mk
      (Seq (Ren.Core.mk (Instance []) Ren.Ty.unit loc, Ren.Core.unit loc))
      Ren.Ty.unit loc
  in
  let main : Ren.Core.fn_def =
    {
      path = Ren.Path.make "test" "main";
      params = [];
      ev = Ren.Core.evidence 2;
      tys = [];
      scheme =
        {
          ty = Fun ([], Ren.Ty.unit, Ren.Ty.closed, Ren.Ty.closed);
          names = [];
          reqs = [];
        };
      body;
      loc;
    }
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ main ];
              values = [];
              shows = [];
            }));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: an instance that isn't the end of a handler's body")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* An associated value, `T.a` and `T.b`, is a function of no parameters
   in Core, named only by a [Global_value] node, and made after every
   value it uses. *)
let t_member = Ren.Path.member (Ren.Path.make "test" "T")

let values_program ~uses_b ~values =
  let loc = Ren.Loc.point ~file 1 1 in
  let path = t_member in
  let int_fn : Ren.Ty.ty = Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed) in
  let value name body : Ren.Core.fn_def =
    {
      path = path name;
      params = [];
      ev = Ren.Core.evidence 2;
      tys = [];
      scheme = { ty = int_fn; names = []; reqs = [] };
      body;
      loc;
    }
  in
  let a = value "a" (Ren.Core.mk uses_b Ren.Ty.int loc) in
  let b = value "b" (Ren.Core.mk (Int 1) Ren.Ty.int loc) in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            {
              home = "test";
              types = [];
              fns = [ a; b ];
              values = List.map path values;
              shows = [];
            }))

let%expect_test "Core Lint reports a value named as a function" =
  values_program
    ~uses_b:
      (Call
         ( Ren.Core.mk
             (Global (t_member "b", Ren.Ty.own_args Ren.Ty.int, []))
             (Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed))
             (Ren.Loc.point ~file 1 1),
           [],
           Ren.Core.evidence 2 ))
    ~values:[ "b"; "a" ];
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `T.a`, at test.ren:1:1: there's no function `T.b`")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports values made out of order" =
  values_program
    ~uses_b:(Global_value (t_member "b", Ren.Ty.own_args Ren.Ty.int))
    ~values:[ "a"; "b" ];
  (* and is clean on them in order *)
  values_program
    ~uses_b:(Global_value (t_member "b", Ren.Ty.own_args Ren.Ty.int))
    ~values:[ "b"; "a" ];
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: the value `T.a` is made before `T.b`, which it uses")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* every example lowers, and Core Lint is clean on it *)

let%expect_test "every example lints" =
  let dir = "../examples" in
  Sys.readdir dir |> Array.to_list
  |> List.filter (fun f -> Filename.check_suffix f ".ren")
  |> List.sort compare
  |> List.iter (fun f ->
      let path = Filename.concat dir f in
      let src = In_channel.with_open_bin path In_channel.input_all in
      report_files
        [ (f, src) ]
        (fun () ->
          ignore (Ren.Driver.core ~lint:true ~file:f src);
          print_endline (f ^ ": ok")));
  [%expect
    {|
    blocks.ren: ok
    fib.ren: ok
    infer.ren: ok
    plans.ren: ok
    values.ren: ok
    |}]

let%expect_test "a place's index is the one it had when the place was found" =
  run
    {|
type P = { xs: Array<Int> }
fn bump(inout n: Int, inout i: Int) =
  n += 10
  i += 1
fn main() =
  var ps = [P { xs: [1, 2] }, P { xs: [3] }]
  var i = 0
  for y in &ps[i].xs
    y += 1
    i = 1
  i = 0
  bump(&ps[i].xs[0], &i)
  print(i)
  ps
|};
  [%expect {|
    1
    [{ xs: [12, 3] }, { xs: [3] }]
    |}]

let%expect_test "&& and || become ifs; not is a primitive" =
  core {|
fn main() =
  let a = 1 < 2
  let b = a && not a
  b || a
|};
  [%expect
    {|
    (fn main () ev/1
      (let a/2 (< 1 2) (let b/3 (if a/2 (not a/2) false) (if b/3 true a/2))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "fail raises a tag; attempt and a fail arm handle it" =
  core
    {|
fn load(id: Int) -> Int = if id == 0 then fail NotFound(id) else id
fn keep(id: Int) -> Result<Int, ! NotFound(Int)> = attempt load(id)
fn handled(id: Int) -> Int =
  match load(id)
    n => n
    fail NotFound(_) => 0
fn passed(id: Int) -> Int =
  try match load(id)
    n => n
    fail NotFound(0) => 0
fn again(r: Result<Int, ! NotFound(Int)>) -> Int = try r
fn first(o: Option<Int>) -> Int = o orelse fail Empty
fn main() = ()
|};
  [%expect
    {|
    (fn load (id/1) ev/2 (if (== id/1 0) (fail (tag NotFound id/1)) id/1))
    (fn keep (id/1) ev/2
      (handle (call ev/2 load id/1) ($value/3 => (con Ok $value/3))
        (fail $error/4 => (con Err $error/4))))
    (fn handled (id/1) ev/2
      (handle (call ev/2 load id/1) ($value/3 => (match $value/3 (n/4 => n/4)))
        (fail $error/5 => (match $error/5 ((tag NotFound _) => 0)))))
    (fn passed (id/1) ev/2
      (handle (call ev/2 load id/1) ($value/3 => (match $value/3 (n/4 => n/4)))
        (fail $error/5 =>
          (match $error/5 ((tag NotFound 0) => 0) (_ => (fail $error/5))))))
    (fn again (r/1) ev/2
      (match r/1 ((Ok $value/3) => $value/3) ((Err $error/4) => (fail $error/4))))
    (fn first (o/1) ev/2
      (match o/1 ((Some $value/3) => $value/3) (None => (fail (tag Empty)))))
    (fn main () ev/1 ())
    (fn $start () ev/1 (call ev/1 main))
    |}]

let%expect_test "a call that can fail writes its & places back anyway" =
  core
    {|
fn add(inout xs: Array<Int>, x: Int) =
  &xs.push(x)
  if x < 0 then fail Negative
fn main() =
  var grid = [[1]]
  let _ = attempt add(&grid[0], 2)
  let _ = attempt each(&grid)
  ()
fn each(inout grid: Array<Array<Int>>) =
  for row in &grid
    try add(&row, -1)
|};
  [%expect
    {|
    (fn add (xs/1 x/2) ev/3
      (seq (call ev/3 Array.push &xs/1 x/2)
        (if (< x/2 0) (fail (tag Negative)) ())))
    (fn main () ev/1
      (let grid/2 (array (array 1))
        (let _/3
          (handle
            (let $ref/4 (get grid/2 0)
              (finally (call ev/1 add &$ref/4 2) (= grid/2 (set grid/2 0 $ref/4))))
            ($value/5 => (con Ok $value/5))
            (fail $error/6 => (con Err $error/6)))
          (let _/7
            (handle (call ev/1 each &grid/2) ($value/8 => (con Ok $value/8))
              (fail $error/9 => (con Err $error/9)))
            ()))))
    (fn each (grid/1) ev/2
      (let $n/3 (length grid/1)
        (let $i/4 0
          (while (< $i/4 $n/3)
            (let row/5 (get grid/1 $i/4)
              (seq
                (finally (call ev/2 add &row/5 (neg 1))
                  (= grid/1 (set grid/1 $i/4 row/5)))
                (= $i/4 (+ $i/4 1))))))))
    (fn $start () ev/1 (call ev/1 main))
    |}]
