(* The sized storage types (foundations.md, decision 15; operators.md,
   "Sized integers"): `Int8`, `Int16`, `Int32`, `UInt8`, `UInt16`,
   `UInt32`, `UInt64` and `Float32`, the types of fields and array
   elements kept at a width. Arithmetic is only ever done in `Int` and
   `Float`, so each is the storage of one of those, its wide type:

   - reading one gives its wide type, the same number;
   - storing a wide value into one checks that it fits, and panics if it
     doesn't: an integer must be in the type's range, and a `Float` is
     rounded to the nearest `Float32`, which must stay finite if it was;
   - storing the result of a wrapping operator, `+%`, `-%` or `*%`, into
     an integer type of 32 bits or fewer keeps its low bits instead, so
     it always fits.

   A `UInt64` holds what an `Int` can that isn't negative, 0 to
   9223372036854775807, so reading one always gives the same number back
   as an `Int`. That's the crisp choice of three (stage 10 native
   follow-ups): reading one above `Int`'s largest as a negative `Int`
   would make `<` disagree with the stored order, and panicking on a read
   would make every read a check. A wrapping operator's result can't be
   stored into one, since wrapping at 64 bits is what `Int`'s own
   wrapping operators do already, and half their results are negative.

   This module is the one place that says what each is: its name, its
   range and how a value is made to fit. The interpreter (eval) and the
   native backend's runtime (ren_rt.h, [ren_narrow_*]) do what it says. *)

type t = I8 | I16 | I32 | U8 | U16 | U32 | U64 | F32

let all = [ I8; I16; I32; U8; U16; U32; U64; F32 ]

let name = function
  | I8 -> "Int8"
  | I16 -> "Int16"
  | I32 -> "Int32"
  | U8 -> "UInt8"
  | U16 -> "UInt16"
  | U32 -> "UInt32"
  | U64 -> "UInt64"
  | F32 -> "Float32"

let path k = Path.prelude (name k)
let ty k : Ty.ty = Con (path k, [])
let of_path (p : Path.t) = List.find_opt (fun k -> path k = p) all

let of_ty (t : Ty.ty) =
  match t with Con (p, []) -> of_path p | _ -> None

let is_float k = k = F32

(* The type a value of [k] is read as, and stored from. *)
let wide k = if is_float k then Ty.float else Ty.int

(* How many bits a value of [k] takes in memory. *)
let bits = function
  | I8 | U8 -> 8
  | I16 | U16 -> 16
  | I32 | U32 | F32 -> 32
  | U64 -> 64

let signed = function I8 | I16 | I32 -> true | _ -> false

(* The least and greatest integer [k] holds. *)
let range k =
  match k with
  | U64 -> (0L, Int64.max_int)
  | F32 -> (Int64.min_int, Int64.max_int)
  | _ ->
      let b = bits k in
      if signed k then
        (Int64.neg (Int64.shift_left 1L (b - 1)), Int64.pred (Int64.shift_left 1L (b - 1)))
      else (0L, Int64.pred (Int64.shift_left 1L b))

let fits k n =
  let lo, hi = range k in
  Int64.compare n lo >= 0 && Int64.compare n hi <= 0

(* Whether a wrapping operator's result can be stored into [k], wrapped
   to its width: an integer type narrower than `Int`. *)
let wraps k = (not (is_float k)) && k <> U64

(* [n] wrapped to [k]'s width: its low bits, read as [k] reads them, so
   the same as the exact result modulo 2^bits. Since 2^bits divides
   2^64, it doesn't matter that the operator wrapped at 64 bits first. *)
let wrap k n =
  if not (wraps k) then invalid_arg "Sized.wrap";
  let b = bits k in
  let low = Int64.logand n (Int64.pred (Int64.shift_left 1L b)) in
  if signed k && Int64.compare low (Int64.shift_left 1L (b - 1)) >= 0 then
    Int64.sub low (Int64.shift_left 1L b)
  else low

(* [x] rounded to the nearest `Float32`, as C's `(float)x` does: [None]
   if a finite [x] rounds to an infinity, which doesn't fit. *)
let float32 x =
  let r = Int32.float_of_bits (Int32.bits_of_float x) in
  if Float.is_finite x && not (Float.is_finite r) then None else Some r

(* What a panic says when [what], a value written as it's shown, doesn't
   fit in [k]: "300 doesn't fit in a `UInt8`, which holds 0 to 255". *)
let doesnt_fit k what =
  if is_float k then
    Printf.sprintf "%s doesn't fit in a `Float32`, which holds up to about 3.4e38"
      what
  else
    let lo, hi = range k in
    let a = if signed k then "an" else "a" in
    Printf.sprintf "%s doesn't fit in %s `%s`, which holds %Ld to %Ld" what a
      (name k) lo hi

(* What happens to an expression's value where it's used, which
   inference decides and lowering does (Infer.node's [coerce]): [read],
   it's a value of this sized type read as its wide type; [store], it's
   a wide value stored as one of this sized type, checked, or wrapped if
   [true] (the result of a wrapping operator). Both, for a value of one
   sized type stored as another. *)
type coerce = { read : t option; store : (t * bool) option }
