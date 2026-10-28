(* Late overflow (foundations.md, decision 15): in a release build, an
   `Int` `+`, `-` or `*` in a loop that overflows doesn't leave the loop
   to panic. It gives its wrapped result, the first such fault is kept
   (its site and its operands, ren_rt.h, [ren_late]), and the loop goes
   on; the fault is reported later, with the message `ren run` gives where
   it happened, before anything outside the loop's own computation can
   see what the loop did after it. So each checked operation is no
   longer a way out of the loop.

   It's built, checked and tested, but only done when REN_LATE is set
   (driver.ml): measured, it made no loop vectorize and every loop it
   changed slower (RESULTS.md, "Floats and late overflow"). A fault has
   to be kept with its site and operands, since the panic is `ren run`'s,
   so each operation still has a branch to a call that records it, which
   clang won't vectorize; and an overflow flag alone, which it might,
   can't say which operation it was or what its operands were. A running
   sum's overflow can't be checked in lanes at all: whether a prefix
   overflowed isn't known from the lanes' sums. What's left is the count
   each loop keeps and the branch to a call that returns, both slower
   than the branch to a panic that doesn't.

   A region is a loop with such an operation in it, anywhere, the
   outermost one. In a region, every `Int` `+`, `-` and `*` is a [Late],
   and a [Late_check] reports a kept fault:

   - before every call: of a function, a block or a handler, and the
     runtime's that reach the world or allocate what a number says
     ([Console_write], [Console_error], [Array_reserve]). So a fault never
     crosses a call: a dependency's operation, the only thing a callee
     could reach the world or a handler's state by, is never made after
     one, and a callee never runs on a wrapped number, so it can't run
     away on one. That's stricter than decision 15, which lets a loop
     whose calls use nothing report its faults when it leaves;
   - before every way out of the region: a [Return], a [Raise], and a
     [Break] or a [Jump] to a label outside it. So everything after the
     region, and every caller, sees what it would have: a fault
     reported, or none;
   - at the top of every loop in the region, once every 1,024 turns
     ([Late_tick], a count each loop keeps), so a loop whose wrapped
     numbers keep it going can't go on for long: decision 15's "at the
     end of each run of 1,024 iterations".

   And any other panic reports a kept fault first (ren_rt.h,
   [ren_panic]), out of memory too, so a wrapped number that makes an
   index out of bounds, a division by zero or a store that doesn't fit
   says the overflow, as `ren run` does, which panicked at it.

   Why it's sound: between a fault and its report, only the region's own
   code runs, calls none, and leaves nothing it changed where anything
   else can see it before the report, which ends the program. What it
   wrote to its arrays and variables after the fault is never read by
   anything that prints, since nothing prints until it's reported. The
   first fault is the one kept, so the panic is `ren run`'s: the same
   site and operands, since everything up to that operation computed
   what `ren run` did. Async.isolate (11a), which would let a panic be
   caught, isn't built; when it is, decision 8 says an isolated block
   can't change outer variables, which is what keeps a late report
   unobservable there too. [check] is Mem Lint's, which checks that
   every [Late] is in a loop and every call and way out of its region has
   its [Late_check] just before it. *)

open Mem
module Ids = Set.Make (Int)

(* An operation that can be late: an `Int`'s `+`, `-` or `*`. *)
let lateable (r : rhs) =
  match r with
  | Arith ((Add | Sub | Mul), Var { layout = Int; _ }, _, _)
  | Arith ((Add | Sub | Mul), Int _, Var { layout = Int; _ }, _) ->
      true
  | _ -> false

let rec blocks (s : stmt) : block list =
  match s with
  | If (_, a, b) -> [ a; b ]
  | Switch (_, cases, d) -> d :: List.map snd cases
  | Loop (_, b) -> [ b ]
  | Joins (b, js) -> b :: List.map snd js
  | Catch { body; handler; _ } -> [ body; handler ]
  | Call_fails { on_error; _ } -> [ on_error ]
  | Call_block { on_error = Some b; _ } | Call_handler { on_error = Some b; _ }
    ->
      [ b ]
  | _ -> []

and exists f (b : block) =
  List.exists (fun s -> f s || List.exists (exists f) (blocks s)) b

(* Whether a block has an operation that could be late. *)
let has_lateable =
  exists (function Let (_, r) -> lateable r | _ -> false)

(* Whether [s], in a region whose labels are [inside], needs a
   [Late_check] before it: a call, or a way out. *)
let leaves inside (s : stmt) =
  match s with
  | Let (_, (Call _ | Runtime ((Console_write | Console_error | Array_reserve _), _, _)))
  | Do (Call _ | Runtime ((Console_write | Console_error | Array_reserve _), _, _))
  | Call_fails _ | Call_block _ | Call_handler _ | Return _ | Raise _ ->
      true
  | Break l | Jump l -> not (Ids.mem l inside)
  | _ -> false

let check_stmt = Do (Runtime (Late_check, [], None))
let is_check = function Do (Runtime (Late_check, [], None)) -> true | _ -> false

(* ---- making them ---- *)

type cx = { mutable next : int }

let fresh cx name layout =
  cx.next <- cx.next + 1;
  { id = cx.next; name; layout }

(* A loop in a region: its count of turns, declared before it, 0 so its
   first turn checks, and ticked at the top of each. *)
let rec loop cx inside l b : block =
  let n = fresh cx "$late" Int in
  let m = fresh cx "$late" Int in
  [
    Decl n;
    Loop
      ( l,
        Let (m, Runtime (Late_tick, [ Var n ], None))
        :: Set (n, Var m)
        :: region_block cx inside b );
  ]

and region_block cx inside (b : block) : block =
  List.concat_map
    (fun s ->
      let s =
        match s with
        | Let (v, (Arith (op, x, y, site) as r)) when lateable r ->
            Let (v, Late (op, x, y, site))
        | Loop (l, b) -> Loop (l, b) (* below *)
        | If (c, a, b) -> If (c, region_block cx inside a, region_block cx inside b)
        | Switch (x, cases, d) ->
            Switch
              ( x,
                List.map (fun (t, b) -> (t, region_block cx inside b)) cases,
                region_block cx inside d )
        | Joins (b, js) ->
            Joins
              ( region_block cx inside b,
                List.map (fun (l, b) -> (l, region_block cx inside b)) js )
        | Catch c ->
            Catch
              {
                c with
                body = region_block cx inside c.body;
                handler = region_block cx inside c.handler;
              }
        | Call_fails c -> Call_fails { c with on_error = region_block cx inside c.on_error }
        | Call_block ({ on_error = Some b; _ } as c) ->
            Call_block { c with on_error = Some (region_block cx inside b) }
        | Call_handler ({ on_error = Some b; _ } as c) ->
            Call_handler { c with on_error = Some (region_block cx inside b) }
        | s -> s
      in
      match s with
      | Loop (l, b) -> loop cx inside l b
      | s when leaves inside s -> [ check_stmt; s ]
      | s -> [ s ])
    b

(* [b] outside any region: each outermost loop with something that
   could be late in it made one. *)
let rec outside cx (b : block) : block =
  List.concat_map
    (fun s ->
      match s with
      | Loop (l, body) when has_lateable body ->
          (* the loop's own label is a way out of it: a [Break] of it is
             checked after the loop, where all of them go *)
          let _, labels = Hoist.defined [ s ] in
          loop cx labels l body @ [ check_stmt ]
      | If (c, a, b) -> [ If (c, outside cx a, outside cx b) ]
      | Switch (x, cases, d) ->
          [ Switch (x, List.map (fun (t, b) -> (t, outside cx b)) cases, outside cx d) ]
      | Loop (l, b) -> [ Loop (l, outside cx b) ]
      | Joins (b, js) -> [ Joins (outside cx b, List.map (fun (l, b) -> (l, outside cx b)) js) ]
      | Catch c -> [ Catch { c with body = outside cx c.body; handler = outside cx c.handler } ]
      | Call_fails c -> [ Call_fails { c with on_error = outside cx c.on_error } ]
      | Call_block ({ on_error = Some b; _ } as c) ->
          [ Call_block { c with on_error = Some (outside cx b) } ]
      | Call_handler ({ on_error = Some b; _ } as c) ->
          [ Call_handler { c with on_error = Some (outside cx b) } ]
      | s -> [ s ])
    b

let fn (f : fn) : fn =
  if not (has_lateable f.body) then f
  else
    let defined, _ = Hoist.defined f.body in
    let top =
      List.fold_left (fun m (v : var) -> max m v.id) (Ids.fold max defined 0) f.params
    in
    { f with body = outside { next = top } f.body }

let program (p : program) : program = { p with fns = List.map fn p.fns }

(* ---- checking them (Mem Lint) ---- *)

(* Every [Late] in a loop, and in each region, every statement [leaves]
   says needs one with a [Late_check] just before it. *)
let check (f : fn) =
  let fail what = failwith (Printf.sprintf "Mem Lint: %s, in %s" what f.name) in
  let rec region inside (b : block) =
    ignore
      (List.fold_left
         (fun prev s ->
           if leaves inside s && not prev then
             fail "a call or a way out of a loop with a late operation, not checked first";
           List.iter (region inside) (blocks s);
           is_check s)
         false b)
  in
  let rec out (b : block) =
    match b with
    | [] -> ()
    | Let (_, Late _) :: _ -> fail "a late operation outside a loop"
    | (Loop (_, body) as s) :: rest
      when exists (function Let (_, Late _) -> true | _ -> false) body ->
        if not (match rest with s :: _ -> is_check s | [] -> false) then
          fail "a loop with a late operation, not checked after it";
        let _, labels = Hoist.defined [ s ] in
        region labels body;
        out rest
    | s :: rest ->
        List.iter out (blocks s);
        out rest
  in
  out f.body
