(* A `Float` that's NaN (foundations.md, decision 15; operators.md,
   "`Int` and `Float`"): arithmetic and stores carry it, and where a
   program observes it, it panics. Comparing one (`<`, `==`, an order or
   `==` through the walk), converting one to an `Int` (`round`,
   `truncate`) or to a `Str` (`show`), hashing one, or passing one to a
   dependency's operation, panics. A `match` can't observe one: there are
   no `Float` patterns, so a `Float` is only ever bound. The interpreter
   and both native builds check at those points and nowhere else, so a
   NaN panics at the same place in each, with the same message.

   The interpreter and a debug build also say where the NaN was made:
   the operation that made it from operands that weren't NaN puts a tag
   in its payload, a number for where it is, which every operation after
   it carries, since one given a NaN gives that NaN back. A release build
   makes no tags and says nothing more. This module is the one place that
   says how a tag is kept, what an operation given a NaN gives, and what
   a panic says; the runtime (ren_rt.h, "NaN") does the same in C. *)

(* A tag is kept in bits 29 to 50 of the payload, under the quiet bit:
   those are the bits a `Float32` keeps of a double's payload, so a tag
   survives being stored as one and read back, which C's conversions and
   OCaml's [Int32.bits_of_float] both do. 0 is no tag. *)
let shift = 29
let max_tag = (1 lsl 22) - 1

(* A quiet NaN tagged [n]. *)
let tagged n =
  if n <= 0 || n > max_tag then Float.nan
  else
    Int64.float_of_bits
      (Int64.logor 0x7FF8000000000000L
         (Int64.shift_left (Int64.of_int n) shift))

(* [f]'s tag, if it's a NaN with one. *)
let tag_of f =
  if not (Float.is_nan f) then 0
  else
    Int64.to_int
      (Int64.logand
         (Int64.shift_right_logical (Int64.bits_of_float f) shift)
         (Int64.of_int max_tag))

(* What an operation on [a] and [b] gives, [r] as the hardware computed
   it: the first operand that's a NaN, so which one's tag is kept is said
   here and not by the machine (which may swap the operands of a `+`);
   or, if neither was and [r] is, a NaN made here, tagged by [made ()]. *)
let carried ~made a b r =
  if not (Float.is_nan r) then r
  else if Float.is_nan a then a
  else if Float.is_nan b then b
  else tagged (made ())

(* Where an operation is, as the note says it: "at x.ren:3:9", or "in the
   prelude", whose source a program doesn't show. *)
let where (loc : Loc.t) =
  if loc.file = Prelude.file then "in the prelude"
  else Printf.sprintf "at %s:%d:%d" loc.file loc.start.line loc.start.col

(* What a panic says when [what] observed a NaN, "`<` compared a NaN",
   and, if it's known, where it was made: "`<` compared a NaN made at
   x.ren:3:9". *)
let message what made =
  match made with Some w -> what ^ " made " ^ w | None -> what

(* What each observation says. *)
let compared op = Printf.sprintf "`%s` compared a NaN" op
let shown = "`show` of a NaN"
let hashed = "`hash` of a NaN"
let converted how = Printf.sprintf "`%s` of a NaN" how
let passed op = Printf.sprintf "`%s` was given a NaN" op

(* ---- the interpreter's tags ----

   Each place a NaN is made gets the next number, the first time one is
   made there; a debug build numbers its places when it's compiled
   (emit_c.ml), so the numbers differ but what they say doesn't. *)

let places : (string, int) Hashtbl.t = Hashtbl.create 16
let wheres : (int, string) Hashtbl.t = Hashtbl.create 16

(* The tag of [loc], numbered now if it has none. *)
let tag_at (loc : Loc.t) =
  let w = where loc in
  match Hashtbl.find_opt places w with
  | Some n -> n
  | None ->
      let n = Hashtbl.length places + 1 in
      if n > max_tag then 0
      else (
        Hashtbl.replace places w n;
        Hashtbl.replace wheres n w;
        n)

(* Where the NaN [f] was made, if its tag says. *)
let made f = Hashtbl.find_opt wheres (tag_of f)

(* A NaN a walk found, [==], `hash`, an order or `show` of a value with
   one in it: raised there and turned into a panic by what asked, which
   knows where it is and what it was doing. *)
exception Seen of float

(* The panic message for [f], seen by [what]. *)
let observed what f = message what (made f)
