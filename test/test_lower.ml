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
      (if (== (eq Int) n/2 0) x/1 (call ev/3 (inst back T {..d}) x/1 (- n/2 1))))
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
      dicts = [];
      scheme =
        {
          ty =
            Fun
              ( [],
                Ren.Ty.unit,
                Ren.Ty.closed,
                Ren.Ty.closed,
                { ids = []; lvar = Some 0 } );
          names = [];
          reqs = [];
          row_reqs = [];
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
   the type arguments [targs] at `fn(Int) -> Int`, passing it the
   descriptors of their types, or [descs]. [id] has its hidden type
   parameters, or [tys]. [types] are the module's, and [shows] the types
   it says show themselves. *)
let id_program ?descs ?tys ?(types = []) ?(shows = []) (targs : Ren.Ty.args) =
  let loc = Ren.Loc.point ~file 1 1 in
  let fn path params ty body : Ren.Core.fn_def =
    let own =
      Ren.Core.type_params { ty; names = []; reqs = []; row_reqs = [] }
    in
    {
      path = Ren.Path.make "test" path;
      params;
      ev = Ren.Core.evidence 9;
      tys = (if path = "id" then Option.value tys ~default:own else own);
      dicts = [];
      scheme = { ty; names = []; reqs = []; row_reqs = [] };
      body;
      loc;
    }
  in
  let x : Ren.Core.var = { id = 1; name = "x"; ty = Var 0 } in
  let open_row n : Ren.Ty.row = { labels = []; tail = Some n } in
  let id =
    fn "id"
      [ { mode = Read; var = x } ]
      (Fun
         ( [ Ren.Ty.read (Var 0) ],
           Var 0,
           open_row 0,
           open_row 1,
           { ids = []; lvar = Some 0 } ))
      (Ren.Core.local x loc)
  in
  (* a use of `id` can be `id`, and its lambda-set argument says so *)
  let used_id : Ren.Ty.lams = { ids = [ "test.id" ]; lvar = Some 0 } in
  let targs = { targs with lams = [ used_id ] } in
  let int_fn : Ren.Ty.ty =
    Fun
      ( [ Ren.Ty.read Ren.Ty.int ],
        Ren.Ty.int,
        Ren.Ty.closed,
        Ren.Ty.closed,
        used_id )
  in
  let call =
    Ren.Core.mk
      (Call
         ( Ren.Core.mk
             (Global
                ( id.path,
                  targs,
                  Option.value descs
                    ~default:(List.map (Ren.Core.describe []) targs.tys),
                  [] ))
             int_fn loc,
           [ Value (Ren.Core.mk (Int 1) Ren.Ty.int loc) ],
           Ren.Core.evidence 9 ))
      Ren.Ty.int loc
  in
  let main =
    fn "main" []
      (Fun
         ( [],
           Ren.Ty.int,
           Ren.Ty.closed,
           Ren.Ty.closed,
           { ids = []; lvar = Some 0 } ))
      call
  in
  report "" (fun () ->
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked:[]
            { home = "test"; types; fns = [ id; main ]; values = []; shows });
      print_endline "ok")

let%expect_test "Core Lint reports a use at the wrong type arguments" =
  (* at `Int`, with rows of nothing, it's clean *)
  id_program
    { tys = [ Ren.Ty.int ]; rows = [ Ren.Ty.closed; Ren.Ty.closed ]; lams = [] };
  [%expect {| ok |}];
  (* at `Bool`, its type would be `fn(Bool) -> Bool` *)
  id_program
    {
      tys = [ Ren.Ty.bool ];
      rows = [ Ren.Ty.closed; Ren.Ty.closed ];
      lams = [];
    };
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
      lams = [];
    };
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `id` is used at `fn(Int) -> Int`, but its type arguments make it `fn(Int) -> Int ! Short`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* and too few *)
  id_program { tys = [ Ren.Ty.int ]; rows = []; lams = [] };
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
      dicts = [];
      scheme =
        {
          ty =
            Fun
              ( [ Ren.Ty.read set ],
                Ren.Ty.unit,
                Ren.Ty.closed,
                Ren.Ty.closed,
                Ren.Ty.any_lams );
          names = [];
          reqs = [];
          row_reqs = [];
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
      dicts = [];
      scheme =
        {
          ty =
            Fun
              ( [],
                Ren.Ty.unit,
                Ren.Ty.closed,
                Ren.Ty.closed,
                { ids = []; lvar = Some 0 } );
          names = [];
          reqs = [];
          row_reqs = [];
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
      dicts = [];
      scheme =
        {
          ty =
            Fun
              ( [],
                Ren.Ty.unit,
                Ren.Ty.closed,
                Ren.Ty.closed,
                { ids = []; lvar = Some 0 } );
          names = [];
          reqs = [];
          row_reqs = [];
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
  let int_fn : Ren.Ty.ty =
    Fun ([], Ren.Ty.int, Ren.Ty.closed, Ren.Ty.closed, Ren.Ty.any_lams)
  in
  let value name body : Ren.Core.fn_def =
    {
      path = path name;
      params = [];
      ev = Ren.Core.evidence 2;
      tys = [];
      dicts = [];
      scheme = { ty = int_fn; names = []; reqs = []; row_reqs = [] };
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
             (Global (t_member "b", Ren.Ty.own_args Ren.Ty.int, [], []))
             (Fun
                ( [],
                  Ren.Ty.int,
                  Ren.Ty.closed,
                  Ren.Ty.closed,
                  { ids = [ "test.T.b" ]; lvar = Some 0 } ))
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

let%expect_test "Core Lint reports a descriptor that doesn't describe its type"
    =
  let targs : Ren.Ty.args =
    { tys = [ Ren.Ty.int ]; rows = [ Ren.Ty.closed; Ren.Ty.closed ]; lams = [] }
  in
  (* `id` at `Int`, passed `Bool`'s *)
  id_program ~descs:[ Known Ren.Ty.bool ] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: type argument 1 of `id` is described as `Bool`, but is `Int`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* passed none *)
  id_program ~descs:[] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `id` is given 1 type arguments, but 0 descriptors")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* built from a hidden type parameter `main` doesn't have *)
  id_program ~descs:[ Param (Ren.Core.type_param 0) ] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:1:1: `$ty0` (-1) is used outside its scope")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* `id` without its hidden type parameter *)
  id_program ~tys:[] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `id`, at test.ren:1:1: its hidden type parameters aren't one for each of its type variables")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "Core Lint reports a type said to show itself that can't" =
  let targs : Ren.Ty.args =
    { tys = [ Ren.Ty.int ]; rows = [ Ren.Ty.closed; Ren.Ty.closed ]; lams = [] }
  in
  let box = Ren.Path.make "test" "Box" in
  let decl : Ren.Iface.type_decl =
    {
      path = box;
      params = [ "T" ];
      body = Record [ { fname = "v"; fty = Var 0 } ];
      members = Ren.Path.Map.empty;
      loc = None;
    }
  in
  (* `id` takes a `T`, not a `Box<T>`, and doesn't give a `Str` *)
  id_program ~types:[ decl ] ~shows:[ (box, Ren.Path.make "test" "id") ] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `id`, at test.ren:1:1: `id` shows a `test.Box`, but has type `fn(T) -> T ! ..e uses ..d`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a type the module doesn't declare *)
  id_program ~shows:[ (box, Ren.Path.make "test" "id") ] targs;
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: `id` is said to show `test.Box`, which isn't declared here")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* ---- requirements' dictionaries ---- *)

let%expect_test "a typed print shows the dictionaries a function takes" =
  (* `same` takes `T`'s `eq`, which its `==` compares with; `both` passes
     its own on for `U`, and one it derives for `Box<U>` from it; `main`
     passes `Int`'s. A plain print shows none of them *)
  let src =
    {|
type Box<T> = { v: T }
fn same(a, b) = a == b
fn both<U>(a: U, b: U) -> Bool = same(a, b) && same(Box { v: b }, Box { v: a })
fn main() =
  assert both(1, 1)
  assert 1 != 2
|}
  in
  core ~types:true src;
  [%expect
    {|
    (fn same : fn(T, T) -> Bool ! ..e uses ..d (needs (eq T)) (a/1 b/2) ev/3
      (== (eq T) a/1 b/2))
    (fn both : fn(U, U) -> Bool ! ..e uses ..d (needs (eq U)) (a/1 b/2) ev/3
      (if (call ev/3 (inst same U {} {..d} (eq U)) a/1 b/2)
        (call ev/3 (inst same test.Box<U> {} {..d} (eq test.Box<U>))
          (record (v: b/2))
          (record (v: a/1)))
        false))
    (fn main : fn() ! ..e uses ..d () ev/1
      (seq (assert (call ev/1 (inst both Int {} {..d} (eq Int)) 1 1))
        (assert (!= (eq Int) 1 2))))
    (fn $start : fn() ! ..e () ev/1 (call ev/1 (inst main {..e} {..r})))
    |}];
  core src;
  [%expect
    {|
    (fn same (a/1 b/2) ev/3 (== a/1 b/2))
    (fn both (a/1 b/2) ev/3
      (if (call ev/3 same a/1 b/2)
        (call ev/3 same (record (v: b/2)) (record (v: a/1)))
        false))
    (fn main () ev/1 (seq (assert (call ev/1 both 1 1)) (assert (!= 1 2))))
    (fn $start () ev/1 (call ev/1 main))
    |}]

(* `same`, which needs `T`'s `eq`, and `main`, which uses it at `Int`,
   lowered, with [change] made to each of the module's functions, then
   linted *)
let lint_same change =
  let src = clean {|
fn same(a, b) = a == b
fn main() = same(1, 2)
|} in
  report src (fun () ->
      let linked = Ren.Driver.linked ~file src in
      let entry = List.nth linked (List.length linked - 1) in
      let entry = { entry with fns = List.map change entry.fns } in
      let linked = List.rev (entry :: List.tl (List.rev linked)) in
      Ren.Driver.pass "lint" (fun () ->
          Ren.Core_lint.program ~imports:[] ~linked entry);
      print_endline "ok")

let%expect_test "Core Lint checks requirements' dictionaries" =
  let open Ren.Core in
  let named name (f : fn_def) = Ren.Path.local f.path = name in
  (* [main]'s call of `same`, given [dicts] instead *)
  let given dicts (f : fn_def) =
    match f.body.kind with
    | Call (({ kind = Global (p, a, ds, _); _ } as g), args, ev)
      when named "main" f ->
        let g = { g with kind = Global (p, a, ds, dicts) } in
        { f with body = { f.body with kind = Call (g, args, ev) } }
    | _ -> f
  in
  (* [same]'s `==` made [kind] from its dictionary *)
  let compared kind (f : fn_def) =
    match f.body.kind with
    | Prim (Equal d, args) when named "same" f ->
        { f with body = { f.body with kind = kind d args } }
    | _ -> f
  in
  let eq dty from = Derived { req = "eq"; dty; from } in
  lint_same Fun.id;
  [%expect {| ok |}];
  (* `same` without its dictionary parameter *)
  lint_same (fun f -> if named "same" f then { f with dicts = [] } else f);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `same`, at test.ren:1:4: its hidden dictionary parameters aren't one for each of its requirements")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a use that passes none *)
  lint_same (given []);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:2:13: `same` has 1 requirements, but is given 0 dictionaries")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* or `Str`'s for `Int` *)
  lint_same (given [ eq Ren.Ty.str [] ]);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:2:13: `same` is given the `eq` dictionary of `Str`, but needs `eq` of `Int`")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* or one derived for a function's type, which has none *)
  let inc : Ren.Ty.ty =
    Fun
      ( [ Ren.Ty.read Ren.Ty.int ],
        Ren.Ty.int,
        Ren.Ty.closed,
        Ren.Ty.closed,
        Ren.Ty.any_lams )
  in
  lint_same (given [ eq inc [] ]);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:2:13: `fn(Int) -> Int` has no `eq` to derive")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* `same`'s `==` through one derived for its own `T`, not its own *)
  lint_same
    (compared (fun d args ->
         let own = List.map (fun v -> (0, v)) (dict_vars d) in
         Prim (Equal (eq (Var 0) own), args)));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `same`, at test.ren:1:17: a dictionary for `T` is derived, not the function's own")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* or with none at all *)
  lint_same (compared (fun _ args -> Prim (Binop Eq, args)));
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `same`, at test.ren:1:17: `==` or `!=` without the dictionary it compares by")
      = this is a bug in the Ren compiler, not in your program
    |}]

(* ---- lambda sets ----

   Every function type has a lambda set, which only a print with [lams]
   shows (compiler.md, "The facts"): the identities of the lambdas and
   functions a value of the type can be, `main.main#1` for the first
   lambda in `main`, and `..l0` for the rest. *)

let%expect_test "lambda sets of a map-like function's calls" =
  (* each call of [map] puts what it's given in its [f]'s set, at that
     call only: [map]'s own scheme has a variable for it, as a row *)
  core ~lams:true
    {|
fn map(xs, f) =
  var out = []
  for x in xs
    &out.push(try f(x))
  out
fn inc(x: Int) -> Int = x + 1
fn main() =
  let a = map([1, 2], fn(x) => x * 2)
  let b = map(a, inc)
  print(b)
|};
  [%expect
    {|
    (fn map :
      fn(Array<T>, fn(T) -> U ! ..e uses ..d [..l0]) -> Array<U> ! ..e uses ..d [..l1]
      (xs/1 f/2)
      ev/3
      (let out/4 (array)
        (seq
          (let $xs/5 xs/1
            (let $n/6 (length $xs/5)
              (let $i/7 0
                (while (< $i/7 $n/6)
                  (let x/8 (get $xs/5 $i/7)
                    (seq
                      (call ev/3 (inst Array.push U {} {..d} [Array.push | ..l2])
                        &out/4
                        (call ev/3 (: f/2 fn(T) -> U ! ..e uses ..d [..l0]) x/8))
                      (= $i/7 (+ $i/7 1))))))))
          out/4)))
    (fn inc : fn(Int) -> Int ! ..e uses ..d [..l0] (x/1) ev/2 (+ x/1 1))
    (fn main : fn() ! ..e uses Console, ..d [..l0] () ev/1
      (let a/2
        (call ev/1
          (inst map Int Int {} {Console | ..d} [test.main#1 | ..l1]
            [test.map | ..l2])
          (array 1 2)
          (lambda test.main#1 :
            fn(Int) -> Int uses Console, ..d [test.main#1 | ..l1]
            (x/3)
            (captures)
            ev/4
            (* x/3 2)))
        (let b/5
          (call ev/1
            (inst map Int Int {} {Console | ..d} [test.inc | ..l3]
              [test.map | ..l4])
            a/2
            (inst inc {} {Console | ..d} [test.inc | ..l3]))
          (call ev/1 (inst print Array<Int> {} {..d} [print | ..l5]) b/5))))
    (fn $start : fn() ! ..e [..l0] () ev/1
      (with ev/2 (extend ev/1 Console Console.real)
        (call ev/2 (inst main {..e} {..r} [test.main | ..l0]))))
    |}]

let%expect_test "an if of two lambdas can be either" =
  (* the `if`'s set has both, and so has the variable it's given to, and
     so does each branch, since inference unifies them *)
  core ~lams:true
    {|
fn inc(x: Int) -> Int = x + 1
fn main() =
  let n = 2
  let f = if n > 1 then fn(x: Int) => x + n else inc
  let g = if n > 1 then fn(x: Int) => x * 2 else fn(x: Int) => x
  print(f(g(1)))
|};
  [%expect
    {|
    (fn inc : fn(Int) -> Int ! ..e uses ..d [..l0] (x/1) ev/2 (+ x/1 1))
    (fn main : fn() ! ..e uses Console, ..d [..l0] () ev/1
      (let n/2 2
        (let f/3
          (:
            (if (> n/2 1)
              (lambda test.main#1 :
                fn(Int) -> Int uses Console, ..d [test.inc, test.main#1 | ..l1]
                (x/4)
                (captures n/2)
                ev/5
                (+ x/4 n/2))
              (inst inc {} {Console | ..d} [test.inc, test.main#1 | ..l1]))
            fn(Int) -> Int uses Console, ..d [test.inc, test.main#1 | ..l1])
          (let g/6
            (:
              (if (> n/2 1)
                (lambda test.main#2 :
                  fn(Int) -> Int uses Console, ..d [test.main#2, test.main#3 | ..l2]
                  (x/7)
                  (captures)
                  ev/8
                  (* x/7 2))
                (lambda test.main#3 :
                  fn(Int) -> Int uses Console, ..d [test.main#2, test.main#3 | ..l2]
                  (x/9)
                  (captures)
                  ev/10
                  x/9))
              fn(Int) -> Int uses Console, ..d [test.main#2, test.main#3 | ..l2])
            (call ev/1 (inst print Int {} {..d} [print | ..l3])
              (call ev/1
                (: f/3
                  fn(Int) -> Int uses Console, ..d [test.inc, test.main#1 | ..l1])
                (call ev/1
                  (: g/6
                    fn(Int) -> Int uses Console, ..d [test.main#2, test.main#3 | ..l2])
                  1)))))))
    (fn $start : fn() ! ..e [..l0] () ev/1
      (with ev/2 (extend ev/1 Console Console.real)
        (call ev/2 (inst main {..e} {..r} [test.main | ..l0]))))
    |}]

let%expect_test "a recursive group passes functions to each other" =
  (* [even] and [odd] are checked together: [odd]'s lambda reaches [even]'s
     [k] and comes back, so each one's [k] can be it, and whatever its
     callers pass, the set's variable *)
  core ~lams:true
    {|
fn even(n, k) = if n == 0 then k(0) else odd(n - 1, k)
fn odd(n, k) = if n == 0 then false else even(n - 1, fn(m) => k(m + 1))
fn main() =
  print(even(4, fn(x) => x == 0))
  let e = even
  print(e(3, fn(x) => true))
|};
  [%expect
    {|
    (fn even :
      fn(Int, fn(Int) -> Bool uses ..d [test.odd#1 | ..l0]) -> Bool uses ..d [..l1]
      (n/1 k/2)
      ev/3
      (if (== (eq Int) n/1 0)
        (call ev/3 (: k/2 fn(Int) -> Bool uses ..d [test.odd#1 | ..l0]) 0)
        (call ev/3 (inst odd {..d} [..l0] [test.odd | ..l2]) (- n/1 1)
          (: k/2 fn(Int) -> Bool uses ..d [test.odd#1 | ..l0]))))
    (fn odd :
      fn(Int, fn(Int) -> Bool uses ..d [test.odd#1 | ..l0]) -> Bool uses ..d [..l1]
      (n/1 k/2)
      ev/3
      (if (== (eq Int) n/1 0) false
        (call ev/3 (inst even {..d} [..l0] [test.even | ..l2]) (- n/1 1)
          (lambda test.odd#1 : fn(Int) -> Bool uses ..d [test.odd#1 | ..l0] (m/4)
            (captures k/2)
            ev/5
            (call ev/5 (: k/2 fn(Int) -> Bool uses ..d [test.odd#1 | ..l0])
              (+ m/4 1))))))
    (fn main : fn() ! ..e uses Console, ..d [..l0] () ev/1
      (seq
        (call ev/1 (inst print Bool {} {..d} [print | ..l1])
          (call ev/1
            (inst even {Console | ..d} [test.main#1 | ..l2] [test.even | ..l3])
            4
            (lambda test.main#1 :
              fn(Int) -> Bool uses Console, ..d [test.main#1, test.odd#1 | ..l2]
              (x/2)
              (captures)
              ev/3
              (== (eq Int) x/2 0))))
        (let e/4
          (inst even {Console | ..d} [test.main#2 | ..l4] [test.even | ..l5])
          (call ev/1 (inst print Bool {} {..d} [print | ..l6])
            (call ev/1
              (: e/4
                fn(Int, fn(Int) -> Bool uses Console, ..d [test.main#2, test.odd#1 | ..l4]) -> Bool uses Console, ..d [test.even | ..l5])
              3
              (lambda test.main#2 :
                fn(Int) -> Bool uses Console, ..d [test.main#2, test.odd#1 | ..l4]
                (x/5)
                (captures)
                ev/6
                true))))))
    (fn $start : fn() ! ..e [..l0] () ev/1
      (with ev/2 (extend ev/1 Console Console.real)
        (call ev/2 (inst main {..e} {..r} [test.main | ..l0]))))
    |}]

(* [prog]'s [main], lowered, with [f] applied to its body's lets, ifs,
   calls and lambdas, and then linted: enough to put one thing wrong in
   a small program. *)
let lint_changed src f =
  let open Ren in
  let linked = Driver.linked ~lint:true ~file (clean src) in
  let prog = List.nth linked (List.length linked - 1) in
  let rec go (e : Core.expr) : Core.expr =
    let kind : Core.kind =
      match e.kind with
      | Let (v, a, b) -> Let (v, go a, go b)
      | Seq (a, b) -> Seq (go a, go b)
      | If (c, t, e) -> If (go c, go t, go e)
      | Call (g, args, ev) ->
          Call
            ( go g,
              List.map
                (function Core.Value a -> Core.Value (go a) | r -> r)
                args,
              ev )
      | Lambda l -> Lambda { l with body = go l.body }
      | k -> k
    in
    f { e with kind }
  in
  let fns =
    List.map
      (fun (fd : Core.fn_def) ->
        if Path.local fd.path = "main" then { fd with body = go fd.body }
        else fd)
      prog.fns
  in
  report "" (fun () ->
      Driver.pass "lint" (fun () ->
          Core_lint.program ~imports:[] ~linked { prog with fns });
      print_endline "ok")

let%expect_test "Core Lint catches a wrong lambda set" =
  let src =
    {|
fn inc(x: Int) -> Int = x + 1
fn main() =
  let f = if true then fn(x: Int) => x + 2 else inc
  print(f(1))
|}
  in
  (* as lowered, it's clean *)
  lint_changed src Fun.id;
  [%expect {| ok |}];
  (* a lambda whose set hasn't its identity *)
  lint_changed src (fun e ->
      match e.kind with
      | Lambda l -> { e with kind = Lambda { l with name = "test.main#7" } }
      | _ -> e);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:3:24: a lambda is `test.main#7`, but its lambda set `[test.inc, test.main#1 | ..l1]` doesn't have it")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* an `if` whose set hasn't one of what its branches can be *)
  let without id (t : Ren.Ty.ty) : Ren.Ty.ty =
    match t with
    | Fun (ps, r, es, u, l) ->
        Fun (ps, r, es, u, { l with ids = List.filter (( <> ) id) l.ids })
    | t -> t
  in
  lint_changed src (fun e ->
      match e.kind with
      | If _ -> { e with ty = without "test.inc" e.ty }
      | _ -> e);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:3:24: the `then` branch can be `test.inc`, which the lambda set `[test.main#1 | ..l1]` it's given to hasn't")
      = this is a bug in the Ren compiler, not in your program
    |}];
  (* a call of what its set says can be [inc], given two arguments *)
  lint_changed src (fun e ->
      match e.kind with
      | Call (({ kind = Local _; _ } as g), [ a ], ev) ->
          { e with kind = Call (g, [ a; a ], ev) }
      | _ -> e);
  [%expect
    {|
    internal compiler error in lint: Failure("Core Lint: in `main`, at test.ren:4:9: a call passes 2 arguments to what can be `test.inc`, which takes 1")
      = this is a bug in the Ren compiler, not in your program
    |}]

let%expect_test "an implementation's and a handler's operations have sets" =
  (* a record of lambdas, a handler's arms, a function given by name for
     an operation, and an operation used as a value, which is a lambda
     that calls it, of the operation's identity *)
  core ~lams:true
    {|
dep Rates =
  usd_to: fn(c: Int) -> Int
handler doubling() for Rates =
  usd_to(c) => c * 2
fn same(c: Int) -> Int = c
fn convert(n: Int) uses Rates =
  let f = Rates.usd_to
  f(n)
fn main() =
  print(with Rates { usd_to: fn(c) => c + 1 } in convert(1))
  print(with Rates { usd_to: same } in convert(2))
  print(with doubling() in convert(3))
|};
  [%expect
    {|
    (fn doubling : fn() -> (test.Rates uses ..d) ! ..e uses ..d2 [..l0] () ev/1
      (handler (captures) ev/2
        (instance
          (test.Rates:
            (record
              (usd_to:
                (lambda test.doubling#1 :
                  fn(Int) -> Int uses ..d [test.doubling#1 | ..l1]
                  (c/3)
                  (captures)
                  ev/4
                  (* c/3 2))))))))
    (fn same : fn(Int) -> Int ! ..e uses ..d [..l0] (c/1) ev/2 c/1)
    (fn convert : fn(Int) -> Int ! ..e uses test.Rates, ..d [..l0] (n/1) ev/2
      (let f/3
        (lambda test.Rates.usd_to :
          fn(Int) -> Int uses test.Rates, ..d [test.Rates.usd_to | ..l1]
          ($x/4)
          (captures)
          ev/5
          (dep-call ev/5 test.Rates.usd_to $x/4))
        (call ev/2
          (: f/3 fn(Int) -> Int uses test.Rates, ..d [test.Rates.usd_to | ..l1])
          n/1)))
    (fn main : fn() ! ..e uses Console, ..d [..l0] () ev/1
      (seq
        (call ev/1 (inst print Int {} {..d} [print | ..l1])
          (with ev/2
            (extend ev/1 test.Rates
              (record
                (usd_to:
                  (lambda test.main#1 :
                    fn(Int) -> Int uses ..d2 [test.main#1 | ..l2]
                    (c/3)
                    (captures)
                    ev/4
                    (+ c/3 1)))))
            (call ev/2 (inst convert {} {Console | ..d} [test.convert | ..l3]) 1)))
        (seq
          (call ev/1 (inst print Int {} {..d} [print | ..l4])
            (with ev/5
              (extend ev/1 test.Rates
                (record (usd_to: (inst same {} {..r2} [test.same | ..l5]))))
              (call ev/5 (inst convert {} {Console | ..d} [test.convert | ..l6])
                2)))
          (call ev/1 (inst print Int {} {..d} [print | ..l7])
            (with ev/6
              (extend ev/1 test.Rates
                (call ev/1
                  (inst doubling {..r} {} {Console | ..d} [test.doubling | ..l8])))
              (call ev/6 (inst convert {} {Console | ..d} [test.convert | ..l9])
                3))))))
    (fn $start : fn() ! ..e [..l0] () ev/1
      (with ev/2 (extend ev/1 Console Console.real)
        (call ev/2 (inst main {..e} {..r} [test.main | ..l0]))))
    |}]
