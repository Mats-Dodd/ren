(* Arithmetic on `Int`s and `Float`s, as it runs: shared by the
   interpreter's operators (eval.ml), `a + b`, and the methods they are,
   `a.add(b)` (builtins.ml), so the two can't differ.

   An `Int` is 64 bits, as it is on every backend, and arithmetic that
   doesn't fit panics, in every build (operators.md, "`Int` and
   `Float`"). A `Float` is never `NaN`: an operation that would make one
   panics too. What to say is decided here, and where to say it by the
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

(* [r], unless it's `NaN`, which there isn't: a panic that says what made
   it. *)
let not_nan (op : Ast.binop) x y r =
  if Float.is_nan r then
    raise
      (Undefined
         (Printf.sprintf "`%s` has no answer here: %s %s %s"
            (Ast.binop_to_string op) (Ast.show_float x) (Ast.binop_to_string op)
            (Ast.show_float y)))
  else VFloat r

let float_binop (op : Ast.binop) x y =
  match op with
  | Add -> not_nan op x y (x +. y)
  | Sub -> not_nan op x y (x -. y)
  | Mul -> not_nan op x y (x *. y)
  | Div -> not_nan op x y (x /. y)
  | Mod -> not_nan op x y (Float.rem x y)
  (* a total order, since there's no `NaN`, with -0.0 and 0.0 equal *)
  | Lt -> VBool (Float.compare x y < 0)
  | Le -> VBool (Float.compare x y <= 0)
  | Gt -> VBool (Float.compare x y > 0)
  | Ge -> VBool (Float.compare x y >= 0)
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on `Float`s")

let binop (op : Ast.binop) a b =
  match (a, b) with
  | VInt x, VInt y -> int_binop op x y
  | VFloat x, VFloat y -> float_binop op x y
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
