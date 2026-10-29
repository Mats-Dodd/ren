(* A release build's specialization (specialize.ml): the Core it makes,
   which Core Lint checks, and which the interpreter runs as it runs the
   program (helpers.ml runs every program of the tests both ways).
   bench/build.t compiles what it makes. *)

open Ren
open Helpers

(* The entry module's functions, specialized, once Core Lint has checked
   every module, and what specializing made. *)
let specialized ?budget src =
  let src = clean src in
  report src (fun () ->
      let modules, (s : Specialize.stats) =
        Driver.specialized ~lint:true ?budget ~file src
      in
      let entry = List.nth modules (List.length modules - 1) in
      List.iter (fun f -> print_endline (show_fn f)) entry.fns;
      Printf.printf "%d copies, %d blocks lifted, %d handlers known, %d past\n"
        s.copies s.blocks s.handlers s.past_budget)

let%expect_test "a generic function is copied for each type it's used at" =
  specialized
    {|
fn twice<T>(x: T, f: fn(T) -> T) -> T = try f(try f(x))
fn main() uses Console =
  print(twice(1, fn(n) => n + 1))
  print(twice("a", fn(s) => s.concat("b")))
|};
  [%expect
    {|
    (fn twice (x/1 f/2) ev/3 (call ev/3 f/2 (call ev/3 f/2 x/1)))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (call ev/1 twice 1
            (lambda (n/2) (captures ev/1) ev/3 (extend ev/1) (+ n/2 1))))
        (call ev/1 print
          (call ev/1 twice "a"
            (lambda (s/4) (captures ev/1) ev/5 (extend ev/1)
              (call ev/5 Str.concat s/4 "b"))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main$1)))
    (fn main$1#2 (s/1) ev/2 (call ev/2 Str.concat s/1 "b"))
    (fn main$1#1 (n/1) ev/2 (+ n/1 1))
    (fn main$1 () ev/1
      (seq (call ev/1 print$2 (call ev/1 twice$2 1))
        (call ev/1 print$1 (call ev/1 twice$1 "a"))))
    (fn twice$1 (x/1) ev/2 (call ev/2 main$1#2 (call ev/2 main$1#2 x/1)))
    (fn twice$2 (x/1) ev/2 (call ev/2 main$1#1 (call ev/2 main$1#1 x/1)))
    5 copies, 2 blocks lifted, 0 handlers known, 0 past
    |}]

let%expect_test "a block's captures are its lifted function's parameters" =
  (* one it changes is `inout`, so the caller's variable changes *)
  specialized
    {|
fn each_to(n: Int, f: fn(Int)) =
  for i in 0..n
    try f(i)
fn main() uses Console =
  var total = 0
  let k = 3
  each_to(4, fn(i) => total += i * k)
  print(total)
|};
  [%expect
    {|
    (fn each_to (n/1 f/2) ev/3
      (let $i/4 0
        (let $stop/5 n/1
          (while (< $i/4 $stop/5)
            (let i/6 $i/4 (seq (call ev/3 f/2 i/6) (= $i/4 (step $i/4))))))))
    (fn main () ev/1
      (let total/2 0
        (let k/3 3
          (seq
            (call ev/1 each_to 4
              (lambda (i/4) (captures total/2 k/3 ev/1) ev/5 (extend ev/1)
                (let $v/6 (* i/4 k/3) (= total/2 (+ total/2 $v/6)))))
            (call ev/1 print total/2)))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main$1)))
    (fn main$1#1 (total/1 k/2 i/3) ev/4
      (let $v/5 (* i/3 k/2) (= total/1 (+ total/1 $v/5))))
    (fn main$1 () ev/1
      (let total/2 0
        (let k/3 3
          (seq (call ev/1 each_to$1 4 &total/2 k/3) (call ev/1 print$1 total/2)))))
    (fn each_to$1 (n/1 total/2 k/3) ev/4
      (let $i/5 0
        (let $stop/6 n/1
          (while (< $i/5 $stop/6)
            (let i/7 $i/5
              (seq (call ev/4 main$1#1 &total/2 k/3 i/7) (= $i/5 (step $i/5))))))))
    3 copies, 1 blocks lifted, 0 handlers known, 0 past
    |}]

let%expect_test
    "a block isn't lifted if one passed as written uses what it captures" =
  (* a lifted block is given its captures when the call is made, so the
     reader would miss what the other block changes during it *)
  run
    {|
fn both(f: fn(), g: fn() -> Int) -> Int =
  try f()
  let a = try g()
  try f()
  a
fn main() uses Console =
  var n = 10
  let get = fn() => n
  print(both(fn() => n -= 1, get))
  print(n)
  let dec = fn() => n = 5
  print(both(dec, fn() => n))
  print(n)
|};
  [%expect {|
    9
    8
    5
    5
    ()
    |}]

let%expect_test "an operation whose handler is known is called directly" =
  (* the handler's state is made where it's installed, and passed to
     each function that calls the operation; the `with` stays, for the
     interpreter, and a native build installs nothing *)
  specialized
    {|
dep Count =
  next: fn() -> Int

handler counter(start: Int) for Count =
  var n = start
  next() =>
    n += 1
    n

fn three() -> Int uses Count = Count.next() + Count.next() + Count.next()

fn main() uses Console =
  print(with counter(10) in three())
|};
  [%expect
    {|
    (fn counter (start/1) ev/2
      (handler (captures start/1) ev/3
        (let n/4 start/1
          (let $n/5 (cell n/4)
            (instance
              (test.Count:
                (record
                  (next:
                    (lambda () (captures ev/3 $n/5) ev/6 (extend ev/3)
                      (let n/4 (get-cell $n/5)
                        (let $result/7 (seq (= n/4 (+ n/4 1)) n/4)
                          (seq (set-cell $n/5 n/4) $result/7))))))))))))
    (fn three () ev/1
      (+ (+ (dep-call ev/1 test.Count.next) (dep-call ev/1 test.Count.next))
        (dep-call ev/1 test.Count.next)))
    (fn main () ev/1
      (call ev/1 print
        (with ev/2 (extend ev/1 test.Count (call ev/1 counter 10))
          (call ev/2 three))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main$1)))
    (fn counter.next ($n/1) ev/2
      (let n/3 (get-cell $n/1)
        (let $result/4 (seq (= n/3 (+ n/3 1)) n/3)
          (seq (set-cell $n/1 n/3) $result/4))))
    (fn main$1 () ev/1
      (call ev/1 print$1
        (let start/2 10
          (let n/3 start/2
            (let $n/4 (cell n/3)
              (with ev/5
                (extend ev/1 test.Count
                  (handler (captures $n/4) ev/6
                    (instance
                      (test.Count:
                        (record
                          (next:
                            (lambda () (captures ev/6 $n/4) ev/7 (extend ev/6)
                              (let n/3 (get-cell $n/4)
                                (let $result/8 (seq (= n/3 (+ n/3 1)) n/3)
                                  (seq (set-cell $n/4 n/3) $result/8))))))))))
                (call ev/5 three$1 $n/4)))))))
    (fn three$1 ($n/1) ev/2
      (+ (+ (call ev/2 counter.next $n/1) (call ev/2 counter.next $n/1))
        (call ev/2 counter.next $n/1)))
    3 copies, 0 blocks lifted, 1 handlers known, 0 past
    |}]

(* The budget is of the whole program's copies, in Core's nodes: 25 is
   enough for `main`'s, `print`'s and one of `apply`'s, not the other. *)
let%expect_test "past the budget, a call is of the function as it's written" =
  specialized ~budget:25
    {|
fn apply(x: Int, f: fn(Int) -> Int) -> Int = try f(x)
fn main() uses Console =
  print(apply(1, fn(n) => n + 1))
  print(apply(2, fn(n) => n * 2))
|};
  [%expect
    {|
    (fn apply (x/1 f/2) ev/3 (call ev/3 f/2 x/1))
    (fn main () ev/1
      (seq
        (call ev/1 print
          (call ev/1 apply 1
            (lambda (n/2) (captures ev/1) ev/3 (extend ev/1) (+ n/2 1))))
        (call ev/1 print
          (call ev/1 apply 2
            (lambda (n/4) (captures ev/1) ev/5 (extend ev/1) (* n/4 2))))))
    (fn $start () ev/1
      (with ev/2 (extend ev/1 Console Console.real) (call ev/2 main$1)))
    (fn main$1#2 (n/1) ev/2 (* n/1 2))
    (fn main$1 () ev/1
      (seq
        (call ev/1 print$1
          (call ev/1 apply 1
            (lambda (n/2) (captures ev/1) ev/3 (extend ev/1) (+ n/2 1))))
        (call ev/1 print$1 (call ev/1 apply$1 2))))
    (fn apply$1 (x/1) ev/2 (call ev/2 main$1#2 x/1))
    3 copies, 1 blocks lifted, 0 handlers known, 1 past
    |}]

(* ---- what Core Lint checks of it ---- *)

(* What Core Lint says of the program [src], specialized, once [change]
   has changed each of its functions. *)
let tampered src change =
  let src = clean src in
  report src (fun () ->
      let modules, _ = Driver.specialized ~file src in
      let fns = Hashtbl.create 64 in
      List.iter
        (fun (m : Core.program) ->
          List.iter
            (fun (f : Core.fn_def) -> Hashtbl.replace fns f.path (change f))
            m.fns)
        modules;
      try
        Hashtbl.iter (fun _ f -> Core_lint.specialized ~fns f) fns;
        print_endline "Core Lint: ok"
      with Failure msg -> print_endline msg)

let counting =
  {|
dep Count =
  next: fn() -> Int

handler counter(start: Int) for Count =
  var n = start
  next() =>
    n += 1
    n

fn two() -> Int uses Count = Count.next() + Count.next()

fn main() uses Console =
  print(with counter(10) in two())
|}

let%expect_test "Core Lint: specialized as it should be" =
  tampered counting Fun.id;
  [%expect {| Core Lint: ok |}]

let%expect_test
    "Core Lint: a direct call of an operation whose handler isn't known" =
  tampered counting (fun f ->
      match f.origin with Copy _ -> { f with known = [] } | _ -> f);
  [%expect
    {| Core Lint: in `two$1`, at test.ren:10:30: a direct call of `next`, where `Count`'s handler isn't known to be `counter` |}]

let%expect_test "Core Lint: a cell parameter of a function as it's written" =
  tampered counting (fun f ->
      match f.origin with Lifted_op _ -> { f with origin = Written } | _ -> f);
  [%expect
    {| Core Lint: in `counter.next`, at test.ren:6:3: the parameter `$n` is a cell, in a function as written |}]

let%expect_test "a copy at a type its module doesn't import" =
  (* the prelude's `sum`, copied at `money.Money`: Core Lint checks the
     prelude's copy seeing money's interface, where `Money` has a `zero`
     (examples/bank's release build) *)
  run_files
    [
      ( "main.ren",
        {|
import money.{Money}
fn main() uses Console =
  print([Money.cents(3), Money.cents(4)].sum().in_cents())
|}
      );
      ( "money.ren",
        {|
pub type Money = opaque Int with numeric
  pub fn cents(n: Int) -> Money = n
  pub fn in_cents(self) -> Int = self
|}
      );
    ];
  [%expect {|
    7
    ()
    |}]
