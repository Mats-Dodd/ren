(* Arithmetic on `Int`s and `Float`s, as it runs: shared by the
   interpreter's operators (eval.ml), `a + b`, and the methods they are,
   `a.add(b)` (builtins.ml), so the two can't differ.

   An `Int` is 64 bits, as it is on every backend, and arithmetic that
   doesn't fit panics, in every build (operators.md, "`Int` and
   `Float`"). A `Float` operation that has no answer, `0.0 / 0.0`, gives
   a NaN, which arithmetic carries and comparing panics on (nan.ml):
   [made] is the tag of where the operation is, asked for only once it
   makes one. What to say is decided here, and where to say it by the
   caller, which knows where the operation is: so a panic is one of two
   exceptions, which the caller turns into its own. *)

open Value

(* [op] overflowed, which the method [meth] would wrap instead of
   panicking: [shown] is the operation, `9223372036854775807 + 1`. *)
exception Overflowed of { op : string; meth : string; shown : string }

(* An operation that has no answer, and what to say: "division by zero". *)
exception Undefined of string

let bug what = failwith ("bug: checking let through " ^ what)

(* What a panic shows of [x op y], made only once there is one: building
   it for every operation made arithmetic several times slower. *)
let shown_ints op x y = Printf.sprintf "%Ld %s %Ld" x (Ast.binop_to_string op) y

let over op meth x y =
  raise
    (Overflowed { op = Ast.binop_to_string op; meth; shown = shown_ints op x y })

let int_binop (op : Ast.binop) x y =
  match op with
  | Add ->
      let r = Int64.add x y in
      (* it overflowed if both have the same sign and [r] the other *)
      if Int64.logand (Int64.logxor x r) (Int64.logxor y r) < 0L then
        over op "wrapping_add" x y
      else VInt r
  | Sub ->
      let r = Int64.sub x y in
      if Int64.logand (Int64.logxor x y) (Int64.logxor x r) < 0L then
        over op "wrapping_sub" x y
      else VInt r
  | Mul ->
      let r = Int64.mul x y in
      if
        (x = -1L && y = Int64.min_int)
        || (y = -1L && x = Int64.min_int)
        || (x <> 0L && Int64.div r x <> y)
      then over op "wrapping_mul" x y
      else VInt r
  | (Div | Mod) when y = 0L -> raise (Undefined "division by zero")
  | Div when x = Int64.min_int && y = -1L ->
      raise
        (Undefined (Printf.sprintf "`/` overflowed: %s" (shown_ints op x y)))
  (* both round toward zero, as C's do *)
  | Div -> VInt (Int64.div x y)
  | Mod -> VInt (Int64.rem x y)
  | Lt -> VBool (x < y)
  | Le -> VBool (x <= y)
  | Gt -> VBool (x > y)
  | Ge -> VBool (x >= y)
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on `Int`s")

(* No place, for an operation whose caller doesn't know where it is: a
   NaN it makes has no tag. *)
let nowhere () = 0

(* [x op y], comparing, which panics on a NaN: the first that is one,
   whose tag says where it was made. *)
let ordered (op : Ast.binop) x y =
  if Float.is_nan x || Float.is_nan y then
    raise
      (Undefined
         (Nan.observed
            (Nan.compared (Ast.binop_to_string op))
            (if Float.is_nan x then x else y)))

let float_binop ?(made = nowhere) (op : Ast.binop) x y =
  let carried r = VFloat (Nan.carried ~made x y r) in
  match op with
  | Add -> carried (x +. y)
  | Sub -> carried (x -. y)
  | Mul -> carried (x *. y)
  | Div -> carried (x /. y)
  | Mod -> carried (Float.rem x y)
  (* a total order, once a NaN has panicked, with -0.0 and 0.0 equal *)
  | Lt | Le | Gt | Ge -> (
      ordered op x y;
      match op with
      | Lt -> VBool (Float.compare x y < 0)
      | Le -> VBool (Float.compare x y <= 0)
      | Gt -> VBool (Float.compare x y > 0)
      | _ -> VBool (Float.compare x y >= 0))
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on `Float`s")

let binop ?made (op : Ast.binop) a b =
  match (a, b) with
  | VInt x, VInt y -> int_binop op x y
  | VFloat x, VFloat y -> float_binop ?made op x y
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on the wrong types")

let neg = function
  | VInt n when n = Int64.min_int ->
      raise
        (Overflowed
           {
             op = "-";
             meth = "wrapping_neg";
             shown = Printf.sprintf "-(%Ld)" n;
           })
  | VInt n -> VInt (Int64.neg n)
  | VFloat f -> VFloat (Float.neg f)
  | _ -> bug "`-` on the wrong type"

(* What a panic says of an overflow: "`+` overflowed: 1 + 2". *)
let overflow_message ~op ~shown = Printf.sprintf "`%s` overflowed: %s" op shown

(* [xs], `Float`s, added up as `sum` adds them (prelude.ml, [float_sum]):
   element i into lane i mod 8, each lane from 0.0, then the lanes
   pairwise, ((0 + 1) + (2 + 3)) + ((4 + 5) + (6 + 7)). Each addition
   carries a NaN as [float_binop]'s do, with a NaN made in it tagged by
   [made]. The runtime's [ren_float_sum] is the same. *)
let float_sum ?(made = nowhere) (xs : float array) =
  let add a b = Nan.carried ~made a b (a +. b) in
  let lanes = Array.make 8 0. in
  Array.iteri (fun i x -> lanes.(i mod 8) <- add lanes.(i mod 8) x) xs;
  let l = lanes in
  add (add (add l.(0) l.(1)) (add l.(2) l.(3))) (add (add l.(4) l.(5)) (add l.(6) l.(7)))
