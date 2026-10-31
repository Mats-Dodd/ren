(* Bounds: which indices into arrays are in bounds without checking
   (foundations.md, decision 16, "Loops that don't index don't check
   bounds").

   A loop lowering writes, `for x in xs`, `for i, x in &xs`, `for (x, y)
   in xs.zip(ys)` and `for i in 0..xs.len()`, counts a local up from 0
   or more, by 1, while it's below a bound read once before the loop:
   an array's length, or the least of several. If nothing in the loop
   can change how long those arrays are, the count is in bounds for each
   of them everywhere in a pass but the step that counts it on, so an
   index that is that count, or a copy of it, needs no check: [In_bounds]
   (core.ml). Then the loop's one check is its condition. Everything else
   stays [Checked], and a native build checks it as before.

   What the proof needs, each of which this walk finds in Core, so it
   proves what the shapes say rather than what lowering meant:

   - **The bound.** [n] is let-bound, never assigned, to `length a` or
     `a.len()`, to a copy of such a bound, or to `if p < q then p else
     q` of two (`zip`'s least length). Then [n] is at most the length of
     each such [a] while [a] keeps its length.
   - **A length that doesn't change.** An array changes only where a
     local is assigned, or passed with `&` to a call, since arrays are
     values (foundations.md, decision 2). An assignment `a = set a j v`
     keeps [a]'s length. So [a] keeps its length over a stretch of code
     with no other assignment to [a] and no `&a` in it. A block, though,
     runs where it's called, not where it's written, so a local assigned
     or passed with `&` inside any block or handler of the function is
     never trusted at all ([unsteady]).
   - **The count.** [i] is let-bound to 0 or more: a literal, or a count
     already in bounds plus a small literal (nbody's `(i + 1)..n`); and
     the only assignment to [i] anywhere in the function is `i = i + 1`,
     the last thing a pass of `while i < n` does. Then at every point of
     a pass before that step, 0 <= i < n, and `i + 1` can't overflow.
   - **Copies.** `let j = i` of a count in bounds, never assigned, is in
     bounds for the same arrays everywhere it's in scope inside the pass.

   - **Below the count.** `i - k` of a count let-bound to at least [k]
     is in bounds wherever [i] is ([low]).
   - **Another array.** `if n <= length b then ...` teaches that [n] is
     at most [b]'s length in its `then`. So [mark] makes an innermost
     loop that indexes, at its count, an array its bound doesn't cover,
     and doesn't change, two ([versions]): `if n <= length b then (the
     loop, its binders renamed) else (the loop)`. They run the same
     code; the first has [b]'s indices proved, the second checks them
     and panics where it always did. That's loop versioning, as LLVM's
     LoopVersioning and the JVM's range-check elimination do it.

   The facts a loop's pass learns don't reach into a block written in it,
   which may run later; nor past any code that changes one of their
   arrays, which the walk forgets them at.

   [mark] runs on every function lowering makes, before the interpreter
   or a native build sees it; [verify] runs in Core Lint, after lowering
   and again after specializing, and finds the same facts, so an
   [In_bounds] that a later pass moved out of its loop is caught there.
   The interpreter checks an [In_bounds] index anyway, and treats one
   out of bounds as a bug in the compiler (eval.ml, [proved]). *)

open Core
module Ids = Set.Make (Int)
module Facts = Map.Make (Int)

(* The locals a function assigns, how often, and those a block or a
   handler in it changes. *)
type fn_info = {
  assigns : int Facts.t;
      (** how many assignments to each, anywhere, a pass with `&` counted as
          one *)
  stepped : Ids.t;  (** those whose every assignment is `x = x + 1` *)
  unsteady : Ids.t;  (** assigned or passed with `&` inside a block *)
  nonneg : Ids.t;
      (** [Int] locals that are 0 or more wherever they're in scope
          ([nonneg]) *)
}

(* What's known at a point of a walk. *)
type env = {
  bound : Ids.t Facts.t;
      (** [n] -> the arrays [n] is at most the length of, which haven't
          changed since *)
  within : Ids.t Facts.t;
      (** [j] -> the arrays [j] is in bounds for, here: [0 <= j < length] *)
  low : int64 Facts.t;
      (** [v] -> the least [v] can be, 0 or more: let-bound to at least
          that, and never assigned, or only counted up *)
}

let empty = { bound = Facts.empty; within = Facts.empty; low = Facts.empty }
let arrays m (v : var) = Option.value (Facts.find_opt v.id m) ~default:Ids.empty
let arrays_of = arrays

(* [env] without any fact about the arrays in [changed], nor any that an
   index in [changed] is in bounds: a count's is never forgotten in its
   pass, since only its step, the last thing, changes it, but one learned
   from a test ([learn_test]) is, where the index changes. *)
let forget env changed =
  if Ids.is_empty changed then env
  else
    let drop m =
      Facts.filter_map
        (fun _ s ->
          let s = Ids.diff s changed in
          if Ids.is_empty s then None else Some s)
        m
    in
    {
      env with
      bound = drop env.bound;
      within = Facts.filter (fun j _ -> not (Ids.mem j changed)) (drop env.within);
    }

(* An assignment that keeps [a]'s length: `a = set a j v`. *)
let keeps_length (a : var) (value : expr) =
  match value.kind with
  | Prim (Set_index _, [ { kind = Local b; _ }; _; _ ]) -> a.id = b.id
  | _ -> false

(* The locals running [e] may change the length of: each assigned other
   than by [keeps_length], and each passed with `&`. A block's body is
   included, though it runs only when called: what it changes is
   [unsteady] anyway. *)
let rec changed (e : expr) =
  let here =
    match e.kind with
    | Assign (a, v) | Owned_assign { target = a; value = v; _ }
        when not (keeps_length a v) -> Ids.singleton a.id
    | Gen_step { cursor; _ } -> Ids.singleton cursor.id
    | Call (_, args, _) | Gen_create { args; _ } ->
        Ids.of_list
          (List.filter_map (function Ref (v : var) -> Some v.id | Value _ -> None) args)
    | _ -> Ids.empty
  in
  List.fold_left (fun s c -> Ids.union s (changed c)) here (children e)

(* Whether [value] is `v + 1` of [v]: a step, written or proved ([Step]). *)
let is_step (v : var) (value : expr) =
  match value.kind with
  | Prim (Binop Add, [ { kind = Local w; _ }; { kind = Int 1L; _ } ])
  | Prim (Step, [ { kind = Local w; _ } ]) ->
      w.id = v.id
  | _ -> false

(* ---- locals that are never below 0 ----

   An [Int] local is 0 or more wherever it's in scope if it's let-bound
   to something that is, and every assignment to it is of something that
   is: a literal of 0 or more, a length, another such local, or such a
   local plus a literal of 0 or more, or plus another such local. An
   addition that overflowed would panic ([Step]'s can't), so its result
   is never negative. Locals passed with `&` are never among them, since
   a callee may store anything in them. [nonneg] finds the most it can:
   it starts from every let-bound local and drops each with a value that
   doesn't qualify, till none is dropped. That's how `var j = i`, then
   `j += 1`, beside `i = j + 1`, are both known 0 or more, which a count
   that steps by more than 1 needs, as a tokenizer's does. *)
let nonneg (body : expr) (refs : Ids.t) =
  let values = Hashtbl.create 16 and lets = ref Ids.empty in
  let rec go (e : expr) =
    (match e.kind with
    | Let (v, init, _) when v.ty = Ty.int ->
        lets := Ids.add v.id !lets;
        Hashtbl.add values v.id init
    | Assign (v, value) | Owned_assign { target = v; value; _ } -> Hashtbl.add values v.id value
    | _ -> ());
    List.iter go (children e)
  in
  go body;
  let set = ref (Ids.diff !lets refs) in
  let rec ok (e : expr) =
    match e.kind with
    | Int n -> n >= 0L
    | Local w -> Ids.mem w.id !set
    | Prim (Length, [ _ ])
    | Call
        ( { kind = Intrinsic ((Array_len | Bytes_len | Str_byte_len), _, _, _); _ },
          [ Value _ ],
          _ ) ->
        true
    | Prim (Binop Add, [ a; b ]) -> ok a && ok b
    | Prim (Step, [ a ]) -> ok a
    | _ -> false
  in
  let changed = ref true in
  while !changed do
    changed := false;
    Ids.iter
      (fun id ->
        if not (List.for_all ok (Hashtbl.find_all values id)) then (
          set := Ids.remove id !set;
          changed := true))
      !set
  done;
  !set

let info (body : expr) =
  let assigns = ref Facts.empty
  and unsteady = ref Ids.empty
  and other = ref Ids.empty
  and refs = ref Ids.empty in
  let assigned (v : var) =
    assigns :=
      Facts.update v.id (fun n -> Some (1 + Option.value n ~default:0)) !assigns
  in
  let rec go in_block (e : expr) =
    (match e.kind with
    | Assign (v, value) | Owned_assign { target = v; value; _ } ->
        assigned v;
        if not (is_step v value) then other := Ids.add v.id !other;
        if in_block then unsteady := Ids.add v.id !unsteady
    (* a local passed with `&` is assigned whatever the callee leaves in
       it *)
    | Gen_step { cursor; _ } ->
        assigned cursor;
        other := Ids.add cursor.id !other;
        refs := Ids.add cursor.id !refs;
        if in_block then unsteady := Ids.add cursor.id !unsteady
    | Call (_, args, _) | Gen_create { args; _ } ->
        let retained = match e.kind with Gen_create _ -> true | _ -> in_block in
        List.iter
          (function
            | Ref (v : var) ->
                assigned v;
                other := Ids.add v.id !other;
                refs := Ids.add v.id !refs;
                if retained then unsteady := Ids.add v.id !unsteady
            | Value _ -> ())
          args;
        (match e.kind with
         | Gen_create { places; _ } ->
             List.iter (fun (p : gen_place) -> unsteady := Ids.add p.root.id !unsteady) places
         | _ -> ())
    | _ -> ());
    let in_block =
      in_block || match e.kind with Lambda _ | Handler _ -> true | _ -> false
    in
    List.iter (go in_block) (children e)
  in
  go false body;
  let stepped =
    Facts.fold
      (fun id _ s -> if Ids.mem id !other then s else Ids.add id s)
      !assigns Ids.empty
  in
  { assigns = !assigns; stepped; unsteady = !unsteady; nonneg = nonneg body !refs }

let never_assigned fi (v : var) = not (Facts.mem v.id fi.assigns)

(* The least [j] is here, if it's known to be 0 or more. *)
let least fi env (j : var) =
  match (Facts.find_opt j.id env.low, Facts.mem j.id env.within) with
  | Some l, _ -> Some l
  | None, true -> Some 0L
  | None, false -> if Ids.mem j.id fi.nonneg then Some 0L else None

(* The least [init], an [Int], can be, if it's 0 or more: a literal, a
   local that is ([least]), or such a local in bounds plus a literal of 0
   or more, which can't overflow: an array's length is far below 2^62,
   so an index in bounds plus less than 2^61 isn't. *)
let lower_bound fi env (init : expr) =
  match init.kind with
  | Int n when n >= 0L -> Some n
  | Local j -> least fi env j
  | Prim (Binop Add, [ { kind = Local j; _ }; { kind = Int c; _ } ])
    when Facts.mem j.id env.within && c >= 0L && c < Int64.shift_left 1L 61 ->
      Option.map (Int64.add c) (least fi env j)
  | _ -> None

(* What's learned from `let v = init`, [init] already run. *)
let learn fi env (v : var) (init : expr) =
  let env =
    match lower_bound fi env init with
    | Some l when never_assigned fi v || Ids.mem v.id fi.stepped ->
        { env with low = Facts.add v.id l env.low }
    | _ -> env
  in
  if not (never_assigned fi v) then env
  else
    let steady (a : var) =
      if Ids.mem a.id fi.unsteady then Ids.empty else Ids.singleton a.id
    in
    let bound =
      match init.kind with
      | Prim (Length, [ { kind = Local a; _ } ])
      | Call
          ( { kind = Intrinsic ((Array_len | Bytes_len), _, _, _); _ },
            [ Value { kind = Local a; _ } ],
            _ ) ->
          steady a
      | Local p -> arrays env.bound p
      | If
          ( { kind = Prim (Binop Lt, [ { kind = Local p; _ }; { kind = Local q; _ } ]); _ },
            { kind = Local p'; _ },
            { kind = Local q'; _ } )
        when p.id = p'.id && q.id = q'.id ->
          Ids.union (arrays env.bound p) (arrays env.bound q)
      | _ -> Ids.empty
    in
    let within =
      match init.kind with Local j -> arrays env.within j | _ -> Ids.empty
    in
    let add m s = if Ids.is_empty s then m else Facts.add v.id s m in
    { env with bound = add env.bound bound; within = add env.within within }

(* The last thing [body] does, through its [Let]s and [Seq]s. *)
let rec last (body : expr) =
  match body.kind with
  | Let (_, _, b) | Seq (_, b) | Owner_alias { body = b; _ }
  | Cleanup_scope { body = b; _ } -> last b
  | _ -> body

(* How many assignments to [i] [e] has, a pass with `&` counted as one. *)
let rec assigns_in (i : var) (e : expr) =
  List.fold_left
    (fun n c -> n + assigns_in i c)
    (match e.kind with
    | Assign (v, _) | Owned_assign { target = v; _ } when v.id = i.id -> 1
    | Gen_step { cursor; _ } when cursor.id = i.id -> 1
    | Call (_, args, _) | Gen_create { args; _ } ->
        List.length
          (List.filter (function Ref (v : var) -> v.id = i.id | Value _ -> false) args)
    | _ -> 0)
    (children e)

(* `while i < n` whose pass ends `i = i + 1`, with no other assignment
   to [i] in it, where [i] is let-bound to 0 or more and only ever
   counted up by 1, and [n] is never assigned: its count and bound. No
   block may step [i] ([unsteady]): a call to one, mid-pass, would count
   [i] past [n] where no assignment shows it. *)
let counter fi env (cond : expr) (body : expr) =
  match cond.kind with
  | Prim (Binop Lt, [ { kind = Local i; _ }; { kind = Local n; _ } ])
    when never_assigned fi n
         && Facts.mem i.id env.low
         && Ids.mem i.id fi.stepped
         && (not (Ids.mem i.id fi.unsteady))
         && assigns_in i body = 1 -> (
      match (last body).kind with
      | Assign (i', step) when i'.id = i.id && is_step i step -> Some (i, n)
      | _ -> None)
  | _ -> None

(* The pass's facts: the arrays [n] bounds, [i] is in bounds for, in the
   pass, before its last step. *)
let counted fi env (cond : expr) (body : expr) =
  match counter fi env cond body with
  | Some (i, n) ->
      let arrays = arrays env.bound n in
      if Ids.is_empty arrays then env
      else { env with within = Facts.add i.id arrays env.within }
  | None -> env

(* The array or `Bytes` [e] is the length of, `a.len()`. *)
let length_of (e : expr) =
  match e.kind with
  | Prim (Length, [ { kind = Local a; _ } ])
  | Call
      ( { kind = Intrinsic ((Array_len | Bytes_len), _, _, _); _ },
        [ Value { kind = Local a; _ } ],
        _ ) ->
      Some a
  | _ -> None

(* What's learned where [test] held, an `if`'s or a loop's condition:
   `n <= a.len()`; `j < n` of a bound [n], or `j < a.len()`, where [j] is
   0 or more, which puts [j] in bounds of those arrays till [j] or they
   change ([forget]); and conjunctions of those, `if c1 then c2 else
   false`. That's `while j < n && b.at(j) ...`, whose read is in bounds.
   [j] mustn't be one a block changes ([unsteady]): a call to the block
   changes [j] where [forget] can't see it. And what [c1] teaches is
   forgotten where [c2] changes it, as `j < b.len() && shrink(&b)`
   does. *)
let rec learn_test fi env (test : expr) =
  match test.kind with
  | Prim (Binop Lt, [ { kind = Local j; _ }; hi ])
    when least fi env j <> None && not (Ids.mem j.id fi.unsteady) -> (
      let arrays =
        match (hi.kind, length_of hi) with
        | Local n, _ when never_assigned fi n -> arrays env.bound n
        | _, Some a when not (Ids.mem a.id fi.unsteady) -> Ids.singleton a.id
        | _ -> Ids.empty
      in
      if Ids.is_empty arrays then env
      else
        {
          env with
          within = Facts.add j.id (Ids.union arrays (arrays_of env.within j)) env.within;
        })
  | Prim
      ( Binop Le,
        [ { kind = Local n; _ }; { kind = Prim (Length, [ { kind = Local a; _ } ]); _ } ] )
    when never_assigned fi n && not (Ids.mem a.id fi.unsteady) ->
      {
        env with
        bound = Facts.add n.id (Ids.add a.id (arrays env.bound n)) env.bound;
      }
  | If (c1, c2, { kind = Bool false; _ }) ->
      learn_test fi (forget (learn_test fi env c1) (changed c2)) c2
  | _ -> env

(* An index into [a] at [j] is in bounds here: [j] is in bounds, or
   [j - k] where [j] is at least [k]. *)
let holds fi env (a : expr) (j : expr) =
  match (a.kind, j.kind) with
  | Local a, Local j -> Ids.mem a.id (arrays env.within j)
  | Local a, Prim (Binop Sub, [ { kind = Local j; _ }; { kind = Int k; _ } ]) -> (
      Ids.mem a.id (arrays env.within j)
      && k >= 0L
      && match least fi env j with Some l -> k <= l | None -> false)
  | _ -> false

(* [e] with [f] on each of its immediate parts. *)
let map f (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Global _
  | Global_value _ | Intrinsic _ | Break ->
      e.kind
  | Source_view v -> Source_view { v with value = f v.value }
  | Pattern_scope p -> Pattern_scope { p with source = f p.source;
      on_match = f p.on_match; on_else = Option.map f p.on_else }
  | Return (p, e) -> Return (p, f e)
  | Yield e -> Yield (f e)
  | Yield_from y -> Yield_from { y with pull = f y.pull }
  | Gen_close e -> Gen_close (f e)
  | Gen_step _ -> e.kind
  | Gen_create g -> Gen_create { g with args = List.map (function Core.Value e -> Core.Value (f e) | Ref v -> Ref v) g.args;
        places = List.map (fun (p : Core.gen_place) -> { p with read = f p.read; write = f p.write }) g.places }
  | Cleanup_scope c -> Cleanup_scope { c with body = f c.body }
  | Instance_scope c -> Instance_scope { c with body = f c.body }
  | Own o -> Own { o with value = f o.value }
  | Owned_assign a -> Owned_assign { a with value = f a.value }
  | Owner_alias a -> Owner_alias { a with body = f a.body }
  | Prim (p, es) -> Prim (p, List.map f es)
  | Array es -> Array (List.map f es)
  | Tuple es -> Tuple (List.map f es)
  | Con (p, c, es) -> Con (p, c, List.map f es)
  | Tag (t, es, ds) -> Tag (t, List.map f es, ds)
  | Dep_call d -> Dep_call { d with args = List.map f d.args }
  | With w -> With { w with impl = f w.impl; body = f w.body }
  | With_handler w -> With_handler { w with handler = f w.handler; body = f w.body }
  | Instance { impls; finally; exclusive } ->
      Instance
        {
          impls = List.map (fun (d, i) -> (d, f i)) impls;
          finally = Option.map f finally;
          exclusive;
        }
  | Let (v, a, b) -> Let (v, f a, f b)
  | Covered c -> Covered { c with body = f c.body; after = f c.after }
  | While (a, b) -> While (f a, f b)
  | Seq (a, b) -> Seq (f a, f b)
  | Update (a, n, b) -> Update (f a, n, f b)
  | Finally (a, b) -> Finally (f a, f b)
  | Assert_equal (a, b, d, q) -> Assert_equal (f a, f b, d, q)
  | Assign (v, a) -> Assign (v, f a)
  | Assert a -> Assert (f a)
  | Field (a, p, n) -> Field (f a, p, n)
  | Of_variant a -> Of_variant (f a)
  | Narrowed (ds, a) -> Narrowed (ds, f a)
  | Fail a -> Fail (f a)
  | Lambda l -> Lambda { l with body = f l.body }
  | Handler h -> Handler { h with body = f h.body }
  | If (c, t, e) -> If (f c, f t, f e)
  | Match (s, arms) ->
      Match
        ( f s,
          List.map
            (fun (a : arm) -> { a with guard = Option.map f a.guard; body = f a.body })
            arms )
  | Call (g, args, ev) ->
      Call
        ( f g,
          List.map (function Value a -> Value (f a) | Ref v -> Ref v) args,
          ev )
  | Record (p, fs) -> Record (p, List.map (fun (n, x) -> (n, f x)) fs)
  | Handle h ->
      Handle
        { h with body = f h.body; on_value = f h.on_value; on_error = f h.on_error }

(* ---- versioning ----

   `for i, y in &ys` that reads `xs[i]` can't prove `xs[i]` in bounds:
   nothing says `xs` is as long as `ys`. A loop that counts from 0 or
   more below [n] is then made twice, `if n <= xs.len() then (the loop)
   else (the loop)`, the first a copy whose `xs[i]`s [learn_test] proves,
   the second the loop as it was, checked: the classic answer, loop
   versioning, which keeps every panic where it was, since the copy runs
   only when none of its indices can be out of bounds. Only an innermost
   loop is copied, of a modest size, and only for arrays the loop can't
   change the length of, that it indexes at its count. *)

(* Every local a function binds or uses, by id: the largest, from which
   a copy's binders are numbered. *)
let rec max_id (e : expr) =
  let own =
    match e.kind with
    | Local v | Assign (v, _) | Let (v, _, _) | Covered { result = v; _ }
    | Owned_assign { target = v; _ } | Own { owner = v; _ }
    | Cleanup_scope { owner = v; _ } | Instance_scope { owner = v; _ } -> v.id
    | Pattern_scope p ->
        let arm = { pat = p.pat; guard = None; body = p.on_match } in
        max (Option.fold ~none:0 ~some:(fun (v : var) -> v.id) p.binding)
          (max (max p.owner.id p.receiving.id)
            (max_id { e with kind = Match (p.source, [arm]) }))
    | Gen_step { cursor; ev; _ } -> max cursor.id ev.id
    | Owner_alias { target; root; _ } -> max target.id root.id
    | Lambda l ->
        List.fold_left (fun m (p : param) -> max m p.var.id) (max l.ev.id l.outer.id) l.params
    | Handle h -> max h.value.id h.error.id
    | With w -> w.ev.id
    | With_handler w -> w.ev.id
    | Handler h -> h.ev.id
    | Call (_, args, ev) | Gen_create { args; ev; _ } ->
        List.fold_left
          (fun m -> function Ref (v : var) -> max m v.id | Value _ -> m)
          ev.id args
    | Match (_, arms) ->
        let rec pat (p : pattern) =
          match p.pkind with
          | PVar v -> v.id
          | PAs (q, v) -> max v.id (pat q)
          | PCon (_, _, ps) | PTag (_, ps) | POr ps | PTuple ps | PRecord (_, ps)
            ->
              List.fold_left (fun m p -> max m (pat p)) 0 ps
          | (PStr_rest _ | PArray _) as k ->
              List.fold_left (fun m p -> max m (pat p))
                (List.fold_left (fun m (v : var) -> max m v.id) 0 (seq_rest k))
                (seq_pieces k)
          | PWild | PInt _ | PBool _ | PStr _ -> 0
        in
        List.fold_left (fun m (a : arm) -> max m (pat a.pat)) 0 arms
    | _ -> 0
  in
  List.fold_left (fun m c -> max m (max_id c)) own (children e)

(* [e] with each local it binds given a fresh id ([fresh ()]), and each
   use of one the new one: a copy that can sit beside [e] in a function,
   every binder in it its own. *)
let rename fresh (e : expr) =
  let table = Hashtbl.create 16 in
  let bind (v : var) =
    let v' = { v with id = fresh () } in
    Hashtbl.replace table v.id v';
    v'
  in
  let use (v : var) = Option.value (Hashtbl.find_opt table v.id) ~default:v in
  let rec pat (p : pattern) =
    let pkind =
      match p.pkind with
      | PVar v -> PVar (bind v)
      | PCon (t, c, ps) -> PCon (t, c, List.map pat ps)
      | PTag (t, ps) -> PTag (t, List.map pat ps)
      | PTuple ps -> PTuple (List.map pat ps)
      | PRecord (t, ps) -> PRecord (t, List.map pat ps)
      | PAs (q, v) ->
          let q = pat q in
          PAs (q, bind v)
      | POr (first :: rest) ->
          (* each alternative binds the same variables *)
          let first = pat first in
          POr (first :: List.map pat_again rest)
      | (PStr_rest _ | PArray _) as k -> map_seq ~pat ~var:bind k
      | (PWild | PInt _ | PBool _ | PStr _ | POr []) as k -> k
    in
    { p with pkind }
  and pat_again (p : pattern) =
    let pkind =
      match p.pkind with
      | PVar v -> PVar (use v)
      | PCon (t, c, ps) -> PCon (t, c, List.map pat_again ps)
      | PTag (t, ps) -> PTag (t, List.map pat_again ps)
      | PTuple ps -> PTuple (List.map pat_again ps)
      | PRecord (t, ps) -> PRecord (t, List.map pat_again ps)
      | PAs (q, v) -> PAs (pat_again q, use v)
      | POr ps -> POr (List.map pat_again ps)
      | (PStr_rest _ | PArray _) as k -> map_seq ~pat:pat_again ~var:use k
      | (PWild | PInt _ | PBool _ | PStr _) as k -> k
    in
    { p with pkind }
  in
  let rec go (e : expr) : expr =
    let kind =
      match e.kind with
      | Local v -> Local (use v)
      | Let (v, a, b) ->
          let a = go a in
          let v = bind v in
          Let (v, a, go b)
      | Covered ({ body; result; after; _ } as c) ->
          let body = go body in
          let result = bind result in
          Covered { c with body; result; after = go after }
      | Pattern_scope p ->
          let receiving = use p.receiving in
          let owner = bind p.owner in
          let source = go p.source and on_else = Option.map go p.on_else in
          let pattern = pat p.pat in
          let binding = Option.map bind p.binding in
          Pattern_scope { owner; receiving; binding; source; pat = pattern; on_match = go p.on_match; on_else }
      | Assign (v, a) -> Assign (use v, go a)
      | Owned_assign a -> Owned_assign { a with target = use a.target; value = go a.value }
      | Own a -> Own { a with owner = use a.owner; value = go a.value }
      | Owner_alias a -> Owner_alias { target = use a.target; root = use a.root; body = go a.body }
      | Cleanup_scope c ->
          let owner = bind c.owner in Cleanup_scope { owner; body = go c.body }
      | Instance_scope c ->
          let owner = bind c.owner in Instance_scope { owner; body = go c.body }
      | Gen_step g -> Gen_step { g with cursor = use g.cursor; ev = use g.ev }
      | Gen_create g ->
          Gen_create { g with ev = use g.ev; args = List.map (function Value a -> Value (go a) | Ref v -> Ref (use v)) g.args;
            places = List.map (fun (p : gen_place) ->
              { param = use p.param; root = use p.root; read = go p.read; write = go p.write }) g.places }
      | Match (s, arms) ->
          let s = go s in
          Match
            ( s,
              List.map
                (fun (a : arm) ->
                  let pat = pat a.pat in
                  { pat; guard = Option.map go a.guard; body = go a.body })
                arms )
      | Call (g, args, ev) ->
          Call
            ( go g,
              List.map (function Value a -> Value (go a) | Ref v -> Ref (use v)) args,
              use ev )
      | Dep_call d -> Dep_call { d with ev = use d.ev; args = List.map go d.args }
      | Lambda l ->
          let captures = List.map use l.captures and outer = use l.outer in
          let params = List.map (fun (p : param) -> { p with var = bind p.var }) l.params in
          let ev = bind l.ev in
          Lambda { l with captures; outer; params; ev; body = go l.body }
      | Handler h ->
          let captures = List.map use h.captures in
          let ev = bind h.ev in
          Handler { ev; captures; body = go h.body }
      | With w ->
          let outer = use w.outer and impl = go w.impl in
          let ev = bind w.ev in
          With { w with outer; impl; ev; body = go w.body }
      | With_handler w ->
          let outer = use w.outer and handler = go w.handler in
          let ev = bind w.ev in
          With_handler { w with outer; handler; ev; body = go w.body }
      | Handle h ->
          let body = go h.body in
          let value = bind h.value in
          let on_value = go h.on_value in
          let error = bind h.error in
          Handle { body; value; on_value; error; on_error = go h.on_error }
      | _ -> map go e
    in
    { e with kind }
  in
  go e

(* The arrays a copy of [loop], `while i < n`, would prove its indices
   into, if it ran only when [n] is at most each one's length: each
   indexed, unchecked, at [i] or a copy of it, that [loop] doesn't bind or
   change the length of, and that isn't already proved. None for a loop
   with a loop inside, or one too big to copy. *)
let versions fi env (loop : expr) (i : var) (n : var) (body : expr) =
  let rec size (e : expr) = List.fold_left (fun s c -> s + size c) 1 (children e) in
  let rec has_loop (e : expr) =
    match e.kind with While _ -> true | _ -> List.exists has_loop (children e)
  in
  if has_loop body || size body > 400 then []
  else
    (* [i] and the copies of it: `let j = i`, never assigned *)
    let copies = ref (Ids.singleton i.id) and bound_here = ref Ids.empty in
    let rec scan (e : expr) =
      (match e.kind with
      | Let (v, { kind = Local j; _ }, _) when Ids.mem j.id !copies && never_assigned fi v
        ->
          copies := Ids.add v.id !copies
      | _ -> ());
      (match e.kind with
      | Let (v, _, _) | Covered { result = v; _ } ->
          bound_here := Ids.add v.id !bound_here
      | _ -> ());
      List.iter scan (children e)
    in
    scan body;
    let changed = changed loop and proved = arrays env.bound n in
    let found = ref [] in
    (* at [i], or a copy, or `i - k` where [i] is at least [k] *)
    let at_count (j : expr) =
      match j.kind with
      | Local j -> Ids.mem j.id !copies
      | Prim (Binop Sub, [ { kind = Local j; _ }; { kind = Int k; _ } ]) -> (
          Ids.mem j.id !copies
          && k >= 0L
          && match least fi env i with Some l -> k <= l | None -> false)
      | _ -> false
    in
    let rec look (e : expr) =
      (match e.kind with
      | Prim
          ( (Get_index Checked | Set_index Checked),
            { kind = Local a; _ } :: j :: _ )
        when at_count j
             && (not (Ids.mem a.id !bound_here))
             && (not (Ids.mem a.id changed))
             && (not (Ids.mem a.id fi.unsteady))
             && (not (Ids.mem a.id proved))
             && not (List.exists (fun (b : var) -> b.id = a.id) !found) ->
          found := a :: !found
      | _ -> ());
      match e.kind with Lambda _ | Handler _ -> () | _ -> List.iter look (children e)
    in
    look body;
    List.rev !found

(* The walk, in the order [e] runs: [decide] is told, for each index,
   its [bounds] and whether it holds here, and gives the [bounds] to
   keep. With [fresh], it makes a loop that would prove more in bounds
   two loops ([versions]). *)
let rec suspends (e : expr) =
  match e.kind with
  | Yield _ | Yield_from _ -> true
  | Lambda _ | Handler _ -> false
  | _ -> List.exists suspends (children e)

let rec walk ?fresh fi decide env (e : expr) : expr =
  let go = walk ?fresh fi decide env in
  let kind =
    match e.kind with
    | Source_view v -> Source_view { v with value = go v.value }
    | Pattern_scope p ->
        let source = go p.source in
        let env = if suspends p.source then empty else forget env (changed p.source) in
        Pattern_scope { p with source;
          on_match = walk ?fresh fi decide env p.on_match;
          on_else = Option.map (walk ?fresh fi decide env) p.on_else }
    | Owner_alias a -> Owner_alias { a with body = go a.body }
    | Cleanup_scope c -> Cleanup_scope { c with body = go c.body }
    | Instance_scope c -> Instance_scope { c with body = go c.body }
    | Let (v, init, body) ->
        let init = go init in
        let env = learn fi (if suspends init then empty else forget env (changed init)) v init in
        Let (v, init, walk ?fresh fi decide env body)
    | Seq (a, b) ->
        let a' = go a in
        Seq (a', walk ?fresh fi decide (if suspends a then empty else forget env (changed a)) b)
    | If (c, t, f) ->
        let c' = go c in
        let env = forget env (changed c) in
        If (c', walk ?fresh fi decide (learn_test fi env c) t, walk ?fresh fi decide env f)
    | Match (s, arms) ->
        let s' = go s in
        let env = forget env (changed s) in
        Match
          ( s',
            List.map
              (fun (a : arm) ->
                let guard = Option.map (walk ?fresh fi decide env) a.guard in
                let env =
                  match a.guard with Some g -> forget env (changed g) | None -> env
                in
                { a with guard; body = walk ?fresh fi decide env a.body })
              arms )
    | While (cond, body) -> (
        (* what a pass changes, it may have changed before any pass *)
        let env = if suspends e then empty else forget env (changed e) in
        (* a pass runs where its condition held *)
        let plain () =
          While
            ( walk ?fresh fi decide env cond,
              walk ?fresh fi decide (learn_test fi (counted fi env cond body) cond) body )
        in
        match (fresh, counter fi env cond body) with
        | Some fresh, Some (i, n) -> (
            match versions fi env e i n body with
            | [] -> plain ()
            | arrays ->
                let loc = e.loc in
                let le (a : var) =
                  mk
                    (Prim
                       ( Binop Le,
                         [ local n loc; mk (Prim (Length, [ local a loc ])) Ty.int loc ] ))
                    Ty.bool loc
                in
                let test =
                  List.fold_left
                    (fun t a -> mk (If (t, le a, mk (Bool false) Ty.bool loc)) Ty.bool loc)
                    (le (List.hd arrays))
                    (List.tl arrays)
                in
                (* each loop walked as it is, not made two again; the
                   copy walked before its binders are renamed, so what
                   [fi] says of them holds *)
                let fast = rename fresh (walk fi decide (learn_test fi env test) e) in
                let slow = walk fi decide env e in
                If (test, fast, slow))
        | _ -> plain ())
    | Prim (Get_index b, [ a; j ]) ->
        let a = go a and j = go j in
        Prim (Get_index (decide e b (holds fi env a j)), [ a; j ])
    | Prim (Set_index b, [ a; j; v ]) ->
        let a = go a and j = go j and v = go v in
        let env = forget env (changed v) in
        Prim (Set_index (decide e b (holds fi env a j)), [ a; j; v ])
    (* `b.at(j)` as `xs[j]`: a `Bytes` changes only as an array does *)
    | Prim (Byte_at b, [ a; j ]) ->
        let a = go a and j = go j in
        Prim (Byte_at (decide e b (holds fi env a j)), [ a; j ])
    | Call (({ kind = Intrinsic (Bytes_at, _, _, _); _ } as g), [ Value a; Value j ], ev)
      -> (
        let a = go a and j = go j in
        match decide e Checked (holds fi env a j) with
        | In_bounds -> Prim (Byte_at In_bounds, [ a; j ])
        | Checked -> Call (g, [ Value a; Value j ], ev))
    | Lambda l -> Lambda { l with body = walk ?fresh fi decide empty l.body }
    | Handler h -> Handler { h with body = walk ?fresh fi decide empty h.body }
    | _ ->
        (* anything else: its parts in turn, knowing only what none of
           them can change *)
        map (walk ?fresh fi decide (if suspends e then empty else forget env (changed e))) e
  in
  { e with kind }

(* ---- steps that can't overflow ----

   `i = i + 1` is a step that can't overflow when it's the last thing a
   pass of a loop does whose condition tests `i < e`, alone or as one
   side of an `&&`, and nothing else in the pass or the condition changes
   [i], nor a block (which may run anywhere): the pass ran because [i]
   was below [e], an [Int], so [i + 1] is at most [e], at most
   2^63 - 1. Nothing about [i]'s lower bound, or about arrays, is needed.
   That's every `for` loop over a range, whose count `+ 1` was a checked
   add on every pass (compiler.md, "Bytes stage"), and it's marked
   [Step]. *)

(* Whether [cond] tests `i < e` where it holds. *)
let rec tested (i : var) (cond : expr) =
  match cond.kind with
  | Prim (Binop Lt, [ { kind = Local j; _ }; _ ]) -> j.id = i.id && i.ty = Ty.int
  | If (c1, c2, { kind = Bool false; _ }) -> tested i c1 || tested i c2
  | _ -> false

let steppable fi (cond : expr) (body : expr) =
  match (last body).kind with
  | Assign (i, value)
    when is_step i value && tested i cond
         && assigns_in i body = 1
         && assigns_in i cond = 0
         && not (Ids.mem i.id fi.unsteady) ->
      Some i
  | _ -> None

(* [body] with its last thing, through its [Let]s and [Seq]s, [f]'s. *)
let rec with_last f (body : expr) =
  match body.kind with
  | Let (v, a, b) -> { body with kind = Let (v, a, with_last f b) }
  | Seq (a, b) -> { body with kind = Seq (a, with_last f b) }
  | Owner_alias a -> { body with kind = Owner_alias { a with body = with_last f a.body } }
  | Cleanup_scope c -> { body with kind = Cleanup_scope { c with body = with_last f c.body } }
  | _ -> f body

let rec mark_steps fi (e : expr) =
  let e = { e with kind = map (mark_steps fi) e } in
  match e.kind with
  | While (cond, body) when steppable fi cond body <> None ->
      let step (s : expr) =
        match s.kind with
        | Assign (i, value) ->
            { s with kind = Assign (i, { value with kind = Prim (Step, [ local i value.loc ]) }) }
        | _ -> s
      in
      { e with kind = While (cond, with_last step body) }
  | _ -> e

(* The first [Step] in [body] that isn't a step [steppable] proves. *)
let bad_step (body : expr) =
  let fi = info body and proved = ref [] and bad = ref None in
  let rec go (e : expr) =
    match e.kind with
    | Assign (_, { kind = Prim (Step, [ i ]); _ }) when List.memq e !proved -> go i
    | Prim (Step, _) -> if !bad = None then bad := Some e
    | While (cond, body) ->
        if steppable fi cond body <> None then proved := last body :: !proved;
        List.iter go (children e)
    | _ -> List.iter go (children e)
  in
  go body;
  !bad

(* A function with each index this proves in bounds marked so, a loop
   versioned where its copy would prove more, and each step it proves
   can't overflow marked [Step]. *)
let mark (f : fn_def) =
  let fi = info f.body in
  let next =
    ref
      (List.fold_left
         (fun m (v : var) -> max m v.id)
         (max_id f.body)
         ((f.ev :: List.map (fun (p : param) -> p.var) f.params) @ f.tys @ f.dicts))
  in
  let fresh () =
    incr next;
    !next
  in
  let body = walk ~fresh fi (fun _ b holds -> if holds then In_bounds else b) empty f.body in
  { f with body = mark_steps fi body }

(* Whether each [In_bounds] index and each [Step] in [body] is proved
   here: the first that isn't, if one isn't. *)
let verify (body : expr) =
  let fi = info body and bad = ref None in
  ignore
    (walk fi
       (fun e b holds ->
         if b = In_bounds && (not holds) && !bad = None then bad := Some e;
         b)
       empty body);
  match !bad with Some e -> Some e | None -> bad_step body
