(* What Mem Lint catches of the bytes stage's part two (compiler.md,
   "Bytes stage, part two"), in Mem built by hand, as test_native.ml's
   "what Mem Lint catches" does, with its [fn] and [v]: a release build's
   `Str` given as its two words only to a walk that reads it ([views]),
   an element lent from an array a part of it ([lent_part]) that dies
   where the array changes or dies ([unlend]), and a struct of a lent
   part a part too ([lend_parts]'s rule). *)

open Ren
open Test_native

(* [fns], linted as a program whose `$start` is "f": a release build's,
   whose `Str` is the first of [structs] (representation B), if [release] *)
let lint ?(release = false) ?(structs = []) fns =
  let p : Mem.program =
    {
      fns;
      start = "f";
      start_result = Int;
      start_fails = false;
      start_desc = 0;
      descs = [ { dkind = D_int; dargs = []; dcounted = false } ];
      decls = [];
      tags = [];
      values = [];
      static_data = [];
      strings = [];
      sites = [];
      structs;
      handlers = [];
      dep_infos = [];
      dsites = [];
      clones = [];
      sv = (if release then Some 0 else None);
      overflow =
        {
          sid = 0;
          loc = Loc.point ~file:"x" 1 1;
          wrap = None;
          kind = Panics;
          made = None;
          notes = [];
          help = None;
          recv = None;
        };
    }
  in
  match Mem_lint.program p with
  | () -> print_endline "ok"
  | exception Failure msg -> print_endline msg

(* a release build's `Str`: its root and its range *)
let sv : Mem.strukt = { sfields = [ Boxed; Int ]; skind = Product }

(* `$start`, which takes only its evidence, so the program passes, beside
   [g], the function under test, named "g" *)
let start = fn ~params:[ v 9 "ev" Ev ] [ Return (Int 0L) ]
let g (f : Mem.fn) = { f with name = "g" }

(* ---- views: a `Str`'s two words, given where a word is wanted ---- *)

let%expect_test "Mem Lint: a `Str`'s two words given to a walk that reads it" =
  let s = v 1 "s" (Struct (0, true)) and h = v 2 "h" Int in
  lint ~release:true ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ s ] ~modes:[ Borrowed ]
           [ Let (h, Runtime (Hash_fixed, [ Desc_lit 0; Var s ], None)); Return (Var h) ]);
    ];
  [%expect {| ok |}]

(* an array of words keeps what it's given: a `Str` is boxed for it *)
let%expect_test "Mem Lint: a `Str`'s two words stored where a word is wanted" =
  let s = v 1 "s" (Struct (0, true))
  and a = v 2 "a" Boxed
  and r = v 3 "r" Boxed in
  lint ~release:true ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ a; s ] ~modes:[ Borrowed; Borrowed ] ~result:Boxed
           [
             Let (r, Runtime (Array_set (Word 0), [ Var a; Int 0L; Var s ], None));
             Return (Var r);
           ]);
    ];
  [%expect
    {| Mem Lint, in g: array-set:Word0 s/1 is Struct0c, but should be Word0 |}]

(* a debug build's `Str` is its box, so its walks are given that *)
let%expect_test "Mem Lint: two words given to a walk in a debug build" =
  let s = v 1 "s" (Struct (0, true)) and h = v 2 "h" Int in
  lint ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ s ] ~modes:[ Borrowed ]
           [ Let (h, Runtime (Hash_fixed, [ Desc_lit 0; Var s ], None)); Return (Var h) ]);
    ];
  [%expect
    {| Mem Lint, in g: hash-fixed s/1 is Struct0c, but should be Word0 |}]

(* ---- lent_part: an element lent from an array, a part of it ---- *)

let%expect_test "Mem Lint: an element lent from an array, read while it's there" =
  let a = v 1 "a" Boxed and x = v 2 "x" Boxed and n = v 3 "n" Int in
  lint
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Owned ]
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (n, Tag_of (Var x));
             Drop (Var a);
             Return (Var n);
           ]);
    ];
  [%expect {| ok |}]

let%expect_test "Mem Lint: an element lent from an array, read after the array" =
  let a = v 1 "a" Boxed and x = v 2 "x" Boxed and n = v 3 "n" Int in
  lint
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Owned ]
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Drop (Var a);
             Let (n, Tag_of (Var x));
             Return (Var n);
           ]);
    ];
  [%expect {| Mem Lint, in g: x/2 is read after it's dropped |}]

(* a lent element holds no reference, so it can't be given away *)
let%expect_test "Mem Lint: an element lent from an array, given away" =
  let a = v 1 "a" Boxed and x = v 2 "x" Boxed and o = v 3 "o" Boxed in
  lint
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Borrowed ] ~result:Boxed
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (o, Alloc { tag = 0; fields = [ Var x ]; words = []; at = None });
             Return (Var o);
           ]);
    ];
  [%expect {| Mem Lint, in g: x/2 is given away, but holds no reference here |}]

(* ---- unlend: an element lent, then the array's elements moved ---- *)

(* `Array_take` moves the element out, so the one lent before may be
   gone: an array whose elements are taken ends what it lent *)
let%expect_test "Mem Lint: an element lent from an array, read after one's taken" =
  let a = v 1 "a" Boxed
  and x = v 2 "x" Boxed
  and y = v 3 "y" Boxed
  and r = v 4 "r" Boxed
  and n = v 5 "n" Int in
  lint
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Owned ]
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (y, Runtime (Array_take Boxed, [ Var a; Int 0L ], None));
             Let (n, Tag_of (Var x));
             Let (r, Runtime (Array_set_taking Boxed, [ Var a; Int 0L; Var y ], None));
             Drop (Var r);
             Return (Var n);
           ]);
    ];
  [%expect {| Mem Lint, in g: x/2 is read after it's dropped |}]

(* and so does writing one in place through its buffer *)
let%expect_test "Mem Lint: an element lent from an array, read after one's written" =
  let a = v 1 "a" Boxed
  and p = v 2 "p" Ptr
  and x = v 3 "x" Boxed
  and e = v 4 "e" Boxed
  and n = v 5 "n" Int in
  lint
    [
      start;
      g
        (fn ~params:[ a; e ] ~modes:[ Owned; Owned ]
           [
             Let (p, Runtime (Array_data, [ Var a ], None));
             Let (x, Runtime (Buf_peek Boxed, [ Var p; Int 0L; Int 1L ], None));
             Do (Runtime (Buf_set Boxed, [ Var p; Int 0L; Int 1L; Var e ], None));
             Let (n, Tag_of (Var x));
             Drop (Var a);
             Return (Var n);
           ]);
    ];
  [%expect {| Mem Lint, in g: x/3 is read after it's dropped |}]

(* ---- lend_parts: a struct of a lent part, a part of the same object ---- *)

let%expect_test "Mem Lint: a struct of an element lent from an array" =
  let a = v 1 "a" Boxed
  and x = v 2 "x" Boxed
  and s = v 3 "s" (Struct (0, true))
  and y = v 4 "y" Boxed
  and n = v 5 "n" Int in
  lint ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Owned ]
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (s, Make_struct [ Var x; Int 1L ]);
             Let (y, Struct_get (Var s, 0));
             Let (n, Tag_of (Var y));
             Drop (Var a);
             Return (Var n);
           ]);
    ];
  [%expect {| ok |}]

let%expect_test "Mem Lint: a struct of a lent element, read after the array" =
  let a = v 1 "a" Boxed
  and x = v 2 "x" Boxed
  and s = v 3 "s" (Struct (0, true))
  and y = v 4 "y" Boxed in
  lint ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Owned ]
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (s, Make_struct [ Var x; Int 1L ]);
             Drop (Var a);
             Let (y, Struct_get (Var s, 0));
             Drop (Var y);
             Return (Int 0L);
           ]);
    ];
  [%expect {| Mem Lint, in g: s/3 is read after it's dropped |}]

(* a struct of a part holds no reference either: it can't be given away *)
let%expect_test "Mem Lint: a struct of a lent element, given away" =
  let a = v 1 "a" Boxed
  and x = v 2 "x" Boxed
  and s = v 3 "s" (Struct (0, true)) in
  lint ~structs:[ sv ]
    [
      start;
      g
        (fn ~params:[ a ] ~modes:[ Borrowed ] ~result:(Struct (0, true))
           [
             Let (x, Runtime (Array_peek Boxed, [ Var a; Int 0L ], None));
             Let (s, Make_struct [ Var x; Int 1L ]);
             Return (Var s);
           ]);
    ];
  [%expect {| Mem Lint, in g: s/3 is given away, but holds no reference here |}]
