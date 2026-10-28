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
  assigns : int Facts.t;  (** how many assignments to each, anywhere *)
  stepped : Ids.t;  (** those whose every assignment is `x = x + 1` *)
  unsteady : Ids.t;  (** assigned or passed with `&` inside a block *)
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

(* [env] without any fact about the arrays in [changed]. *)
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
    { env with bound = drop env.bound; within = drop env.within }

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
    | Assign (a, v) when not (keeps_length a v) -> Ids.singleton a.id
    | Call (_, args, _) ->
        Ids.of_list
          (List.filter_map (function Ref (v : var) -> Some v.id | Value _ -> None) args)
    | _ -> Ids.empty
  in
  List.fold_left (fun s c -> Ids.union s (changed c)) here (children e)

let info (body : expr) =
  let assigns = ref Facts.empty
  and unsteady = ref Ids.empty
  and other = ref Ids.empty in
  let rec go in_block (e : expr) =
    (match e.kind with
    | Assign (v, value) ->
        assigns :=
          Facts.update v.id
            (fun n -> Some (1 + Option.value n ~default:0))
            !assigns;
        (match value.kind with
        | Prim (Binop Add, [ { kind = Local w; _ }; { kind = Int 1L; _ } ])
          when w.id = v.id ->
            ()
        | _ -> other := Ids.add v.id !other);
        if in_block then unsteady := Ids.add v.id !unsteady
    | Call (_, args, _) when in_block ->
        List.iter
          (function Ref (v : var) -> unsteady := Ids.add v.id !unsteady | Value _ -> ())
          args
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
  { assigns = !assigns; stepped; unsteady = !unsteady }

let never_assigned fi (v : var) = not (Facts.mem v.id fi.assigns)

(* The least [j] is here, if it's known to be 0 or more. *)
let least env (j : var) =
  match (Facts.find_opt j.id env.low, Facts.mem j.id env.within) with
  | Some l, _ -> Some l
  | None, true -> Some 0L
  | None, false -> None

(* The least [init], an [Int], can be, if it's 0 or more: a literal, a
   local that is ([least]), or such a local in bounds plus a literal of 0
   or more, which can't overflow: an array's length is far below 2^62,
   so an index in bounds plus less than 2^61 isn't. *)
let lower_bound env (init : expr) =
  match init.kind with
  | Int n when n >= 0L -> Some n
  | Local j -> least env j
  | Prim (Binop Add, [ { kind = Local j; _ }; { kind = Int c; _ } ])
    when Facts.mem j.id env.within && c >= 0L && c < Int64.shift_left 1L 61 ->
      Option.map (Int64.add c) (least env j)
  | _ -> None

(* What's learned from `let v = init`, [init] already run. *)
let learn fi env (v : var) (init : expr) =
  let env =
    match lower_bound env init with
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
          ( { kind = Intrinsic (Array_len, _, _, _); _ },
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
  match body.kind with Let (_, _, b) | Seq (_, b) -> last b | _ -> body

(* How many assignments to [i] [e] has. *)
let rec assigns_in (i : var) (e : expr) =
  List.fold_left
    (fun n c -> n + assigns_in i c)
    (match e.kind with Assign (v, _) when v.id = i.id -> 1 | _ -> 0)
    (children e)

(* `while i < n` whose pass ends `i = i + 1`, with no other assignment
   to [i] in it, where [i] is let-bound to 0 or more and only ever
   counted up by 1, and [n] is never assigned: its count and bound. *)
let counter fi env (cond : expr) (body : expr) =
  match cond.kind with
  | Prim (Binop Lt, [ { kind = Local i; _ }; { kind = Local n; _ } ])
    when never_assigned fi n
         && Facts.mem i.id env.low
         && Ids.mem i.id fi.stepped
         && assigns_in i body = 1 -> (
      match (last body).kind with
      | Assign
          ( i',
            { kind = Prim (Binop Add, [ { kind = Local i''; _ }; { kind = Int 1L; _ } ]); _ } )
        when i'.id = i.id && i''.id = i.id ->
          Some (i, n)
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

(* What's learned where [test] held, an `if`'s condition: `n <= a.len()`
   and conjunctions of those, `if c1 then c2 else false`. *)
let rec learn_test fi env (test : expr) =
  match test.kind with
  | Prim
      ( Binop Le,
        [ { kind = Local n; _ }; { kind = Prim (Length, [ { kind = Local a; _ } ]); _ } ] )
    when never_assigned fi n && not (Ids.mem a.id fi.unsteady) ->
      {
        env with
        bound = Facts.add n.id (Ids.add a.id (arrays env.bound n)) env.bound;
      }
  | If (c1, c2, { kind = Bool false; _ }) ->
      learn_test fi (learn_test fi env c1) c2
  | _ -> env

(* An index into [a] at [j] is in bounds here: [j] is in bounds, or
   [j - k] where [j] is at least [k]. *)
let holds env (a : expr) (j : expr) =
  match (a.kind, j.kind) with
  | Local a, Local j -> Ids.mem a.id (arrays env.within j)
  | Local a, Prim (Binop Sub, [ { kind = Local j; _ }; { kind = Int k; _ } ]) -> (
      Ids.mem a.id (arrays env.within j)
      && k >= 0L
      && match least env j with Some l -> k <= l | None -> false)
  | _ -> false

(* [e] with [f] on each of its immediate parts. *)
let map f (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Global _
  | Global_value _ | Intrinsic _ | Break ->
      e.kind
  | Prim (p, es) -> Prim (p, List.map f es)
  | Array es -> Array (List.map f es)
  | Tuple es -> Tuple (List.map f es)
  | Con (p, c, es) -> Con (p, c, List.map f es)
  | Tag (t, es, ds) -> Tag (t, List.map f es, ds)
  | Dep_call d -> Dep_call { d with args = List.map f d.args }
  | With w -> With { w with impl = f w.impl; body = f w.body }
  | With_handler w -> With_handler { w with handler = f w.handler; body = f w.body }
  | Instance { impls; finally } ->
      Instance
        {
          impls = List.map (fun (d, i) -> (d, f i)) impls;
          finally = Option.map f finally;
        }
  | Let (v, a, b) -> Let (v, f a, f b)
  | While (a, b) -> While (f a, f b)
  | Seq (a, b) -> Seq (f a, f b)
  | Update (a, n, b) -> Update (f a, n, f b)
  | Finally (a, b) -> Finally (f a, f b)
  | Assert_equal (a, b, d, q) -> Assert_equal (f a, f b, d, q)
  | Assign (v, a) -> Assign (v, f a)
  | Assert a -> Assert (f a)
  | Field (a, p, n) -> Field (f a, p, n)
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
    | Local v | Assign (v, _) | Let (v, _, _) -> v.id
    | Lambda l ->
        List.fold_left (fun m (p : param) -> max m p.var.id) (max l.ev.id l.outer.id) l.params
    | Handle h -> max h.value.id h.error.id
    | With w -> w.ev.id
    | With_handler w -> w.ev.id
    | Handler h -> h.ev.id
    | Call (_, args, ev) ->
        List.fold_left
          (fun m -> function Ref (v : var) -> max m v.id | Value _ -> m)
          ev.id args
    | Match (_, arms) ->
        let rec pat (p : pattern) =
          match p.pkind with
          | PVar v -> v.id
          | PCon (_, _, ps) | PTag (_, ps) | POr ps | PTuple ps ->
              List.fold_left (fun m p -> max m (pat p)) 0 ps
          | PWild | PInt _ | PBool _ -> 0
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
      | POr (first :: rest) ->
          (* each alternative binds the same variables *)
          let first = pat first in
          POr (first :: List.map pat_again rest)
      | (PWild | PInt _ | PBool _ | POr []) as k -> k
    in
    { p with pkind }
  and pat_again (p : pattern) =
    let pkind =
      match p.pkind with
      | PVar v -> PVar (use v)
      | PCon (t, c, ps) -> PCon (t, c, List.map pat_again ps)
      | PTag (t, ps) -> PTag (t, List.map pat_again ps)
      | PTuple ps -> PTuple (List.map pat_again ps)
      | POr ps -> POr (List.map pat_again ps)
      | (PWild | PInt _ | PBool _) as k -> k
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
      | Assign (v, a) -> Assign (use v, go a)
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
      | Let (v, _, _) -> bound_here := Ids.add v.id !bound_here
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
          && match least env i with Some l -> k <= l | None -> false)
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
let rec walk ?fresh fi decide env (e : expr) : expr =
  let go = walk ?fresh fi decide env in
  let kind =
    match e.kind with
    | Let (v, init, body) ->
        let init = go init in
        let env = learn fi (forget env (changed init)) v init in
        Let (v, init, walk ?fresh fi decide env body)
    | Seq (a, b) ->
        let a' = go a in
        Seq (a', walk ?fresh fi decide (forget env (changed a)) b)
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
        let env = forget env (changed e) in
        let plain () =
          While (walk ?fresh fi decide env cond, walk ?fresh fi decide (counted fi env cond body) body)
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
                let copy = { e with kind = While (cond, rename fresh body) } in
                (* each loop walked as it is, not made two again *)
                let fast = walk fi decide (learn_test fi env test) copy in
                let slow = walk fi decide env e in
                If (test, fast, slow))
        | _ -> plain ())
    | Prim (Get_index b, [ a; j ]) ->
        let a = go a and j = go j in
        Prim (Get_index (decide e b (holds env a j)), [ a; j ])
    | Prim (Set_index b, [ a; j; v ]) ->
        let a = go a and j = go j and v = go v in
        let env = forget env (changed v) in
        Prim (Set_index (decide e b (holds env a j)), [ a; j; v ])
    | Lambda l -> Lambda { l with body = walk ?fresh fi decide empty l.body }
    | Handler h -> Handler { h with body = walk ?fresh fi decide empty h.body }
    | _ ->
        (* anything else: its parts in turn, knowing only what none of
           them can change *)
        map (walk ?fresh fi decide (forget env (changed e))) e
  in
  { e with kind }

(* A function with each index this proves in bounds marked so, a loop
   versioned where its copy would prove more. *)
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
  {
    f with
    body = walk ~fresh fi (fun _ b holds -> if holds then In_bounds else b) empty f.body;
  }

(* Whether each [In_bounds] index in [body] is proved here: the first
   that isn't, if one isn't. *)
let verify (body : expr) =
  let fi = info body and bad = ref None in
  ignore
    (walk fi
       (fun e b holds ->
         if b = In_bounds && (not holds) && !bad = None then bad := Some e;
         b)
       empty body);
  !bad
