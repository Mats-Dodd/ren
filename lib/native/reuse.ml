(* Reuse (compiler.md, "Native slice"): an object that dies where one of
   as many fields is built after it, its memory used for the new one if
   it's unique, after Koka's ParcReuse.hs and Lean's ResetReuse.lean.

   rc.ml drops an object whose fields are still used with a drop
   specialized for it: if it's unique, it's freed and its fields are
   kept, and a field that dies with it whose shape the program knows is
   dropped the same way in turn, inside (Koka's nested [specializeDrop],
   Parc.hs:356). Here, each object such a tree frees, the outer one and
   the nested ones, is reset instead if a constructor of as many fields
   is built after it, on the path that goes on (Lean's [D] and [S],
   ResetReuse.lean:188 and :83, which [R], :255, runs at every `cases`,
   a nested pattern's too; Koka's [ruPattern], ParcReuse.hs:322, which
   makes every constructor of a nested pattern available): its fields
   that aren't kept are dropped, and its memory is a token, a variable
   of layout [Token] the build takes, `kk_block_alloc_at` in
   kklib.h:628. A plain drop of an object whose size is known, because
   the function reads its fields, is made the same way.

   Which build takes a token: on each path, of the builds of as many
   fields before the path branches, the one that has the most fields
   already in the token's memory, in the same slot, so it writes least
   (Koka's reuse specialization, ParcReuseSpec.hs, [ruSpecialize] :155
   and [tryMatch] :218, and its [pick], ParcReuse.hs:386, which prefers
   the same constructor; Lean's [isSelfSset], ExpandResetReuse.lean:153).
   A field already there is one the reset kept, given back to the same
   slot, or a scalar read from the same slot of the same object, which
   a reset never changes. The token is null if the object wasn't unique,
   and the build allocates as before; one no build takes is freed where
   its path ends, or before a loop.

   Like the rest of the counting, reuse is only an optimization
   (compiler.md, "What it has to do", rule 1): Mem Lint checks every
   token is used or freed once on every path. *)

open Mem

(* The variable each one is only a name for, by a [Let] of it. *)
let roots (f : fn) =
  let root = Hashtbl.create 64 in
  Rc.iter_stmts
    (function
      | Let (v, Atom (Var x)) ->
          let r = Option.value (Hashtbl.find_opt root x.id) ~default:x.id in
          Hashtbl.replace root v.id r
      | _ -> ())
    f.body;
  fun (v : var) -> Option.value (Hashtbl.find_opt root v.id) ~default:v.id

(* How many fields each object has, by its root, where the function knows:
   it reads a field of it, or builds it. *)
let sizes root (f : fn) =
  let size = Hashtbl.create 16 in
  Rc.iter_stmts
    (function
      | Let (_, Field (Var x, _, n)) -> Hashtbl.replace size (root x) n
      | Let (v, Alloc { fields; _ }) ->
          Hashtbl.replace size (root v) (List.length fields)
      | _ -> ())
    f.body;
  size

(* Each variable that's a field of an object, by its id: the object's
   root and the slot. Not of a variable that changes, which may hold
   another object by the time it's reset. *)
let fields_of root (f : fn) =
  let changes = Hashtbl.create 16 in
  Rc.iter_stmts
    (function
      | Decl v | Set (v, _) -> Hashtbl.replace changes v.id ()
      | _ -> ())
    f.body;
  let field = Hashtbl.create 16 in
  Rc.iter_stmts
    (function
      | Let (v, Field (Var x, slot, _)) when not (Hashtbl.mem changes (root x))
        ->
          Hashtbl.replace field v.id (root x, slot)
      | _ -> ())
    f.body;
  field

(* An object stack.ml keeps in the frame is never a reuse's token, nor
   built in one: its memory isn't the heap's. *)
let is_alloc ~stack n (s : stmt) =
  match s with
  | Let (v, Alloc { fields; at = None; _ }) ->
      List.length fields = n && not (List.mem v.id stack)
  | _ -> false

(* Whether a build of [n] fields is on some path through [b], not in a
   loop, before the path leaves the block. *)
let rec builds ~stack n (b : block) =
  List.exists
    (fun s ->
      is_alloc ~stack n s
      ||
      match s with
      | If (_, t, e) -> builds ~stack n t || builds ~stack n e
      | Switch (_, cases, d) ->
          List.exists (fun (_, b) -> builds ~stack n b) cases
          || builds ~stack n d
      | Joins (d, _) -> builds ~stack n d
      | _ -> false)
    b

(* Whether some path through [b]'s branches leaves it: a [Jump], a
   [Return], a [Break] or a [Raise] inside an [If] or a [Switch]. *)
let rec leaves (b : block) =
  List.exists
    (fun s ->
      Rc.ends s
      ||
      match s with
      | If (_, t, e) -> leaves t || leaves e
      | Switch (_, cases, d) -> List.exists (fun (_, b) -> leaves b) cases || leaves d
      | _ -> false)
    b

(* Whether every path through [b] leaves it. *)
let rec ends_all (b : block) =
  match List.rev b with
  | [] -> false
  | s :: _ -> (
      Rc.ends s
      ||
      match s with
      | If (_, t, e) -> ends_all t && ends_all e
      | Switch (_, cases, d) ->
          List.for_all (fun (_, b) -> ends_all b) cases && ends_all d
      | _ -> false)

(* Whether some path may leave from inside [s], other than through the
   branches of an [If] or a [Switch]: anything in it that jumps, breaks,
   returns or raises, or a call's block for when it fails. *)
let escapes (s : stmt) =
  let found = ref false in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Return _ | Raise _ | Jump _ | Break _ | Call_fails _
      | Call_block { on_error = Some _; _ }
      | Call_handler { on_error = Some _; _ } ->
          found := true
      | _ -> ())
    [ s ];
  !found

exception Give_up

(* A call whose block for when it fails always leaves: on a token's path
   before a build takes it, that block frees the token first ([guard]),
   and the path goes on after the call. A call whose block may go on, or
   anything else a path may leave from inside, ends the token's path
   there. Without this, a failing call between a reset and the build
   that takes its token leaked the token on the error's path. *)
let guardable (s : stmt) =
  match s with
  | Call_fails { on_error; _ } -> ends_all on_error
  | Call_block { on_error = Some b; _ } | Call_handler { on_error = Some b; _ }
    ->
      ends_all b
  | _ -> false

let guard tok (s : stmt) =
  let free b = Free_token (Var tok) :: b in
  match s with
  | Call_fails c -> Call_fails { c with on_error = free c.on_error }
  | Call_block ({ on_error = Some b; _ } as c) ->
      Call_block { c with on_error = Some (free b) }
  | Call_handler ({ on_error = Some b; _ } as c) ->
      Call_handler { c with on_error = Some (free b) }
  | s -> s

type cx = {
  next : int ref;
  root : var -> int;
  size : (int, int) Hashtbl.t;
  field : (int, int * int) Hashtbl.t;
  stack : int list;
}

let fresh cx name layout =
  let v = { id = !(cx.next); name; layout } in
  incr cx.next;
  v

(* A token: its variable, how many fields the object had, which root it
   was, and what the reset kept, by slot. *)
type token = { tok : var; n : int; origin : int; kept : (int * var) list }

(* The slots of a build of [fields] that already hold their field in
   [t]'s memory: a variable the reset kept, back in its slot, or a scalar
   read from that slot of the same object. *)
let same cx t (fields : atom list) =
  List.concat
    (List.mapi
       (fun i x ->
         match x with
         | Var w -> (
             match List.assoc_opt i t.kept with
             | Some k when cx.root w = cx.root k -> [ i ]
             | _ ->
                 if counted w.layout then []
                 else
                   match Hashtbl.find_opt cx.field (cx.root w) with
                   | Some (o, slot) when o = t.origin && slot = i -> [ i ]
                   | _ -> [])
         | _ -> [])
       fields)

(* [b], the rest of a block after [t] is made, with the token taken by a
   build of [n] fields on each path, or freed where the path ends
   without one. Of the builds before the path branches, the one with the
   most fields already in place takes it. *)
let rec take cx (t : token) (b : block) : block =
  (* the statements before the path branches, leaves or loops *)
  let rec straight i acc = function
    | [] -> acc
    | s :: rest -> (
        match s with
        | (If _ | Switch _ | Joins _) when builds ~stack:cx.stack t.n [ s ] || leaves [ s ] ->
            acc
        | Loop _ | Joins _ | Catch _ -> acc
        | s when Rc.ends s -> acc
        | s when guardable s -> straight (i + 1) acc rest
        | s when escapes s -> acc
        | Let (_, Alloc a) when is_alloc ~stack:cx.stack t.n s ->
            straight (i + 1) ((i, List.length (same cx t a.fields)) :: acc) rest
        | _ -> straight (i + 1) acc rest)
  in
  match List.rev (straight 0 [] b) with
  | (i0, s0) :: more ->
      let best, _ =
        List.fold_left
          (fun (bi, bs) (i, s) -> if s > bs then (i, s) else (bi, bs))
          (i0, s0) more
      in
      List.mapi
        (fun i s ->
          match s with
          | Let (v, Alloc a) when i = best ->
              Let (v, Alloc { a with at = Some (Var t.tok, same cx t a.fields) })
          | s when i < best && guardable s -> guard t.tok s
          | s -> s)
        b
  | [] -> branch cx t b

(* The same, where no build comes before the path branches: the token
   goes into the branches, or is freed. A branch some path of which
   leaves, a `match` arm's test that jumps past the rest when it
   matches, say, gives the token to the paths that leave and keeps it
   for the rest of the block on those that go on. *)
and branch cx t (b : block) : block =
  match b with
  | [] -> [ Free_token (Var t.tok) ]
  | (If (c, th, e) as s) :: rest when builds ~stack:cx.stack t.n [ s ] || leaves [ s ] ->
      if leaves [ s ] && not (ends_all [ s ]) then
        If (c, take_open cx t th, take_open cx t e) :: take cx t rest
      else If (c, take cx t th, take cx t e) :: rest
  | (Switch (x, cases, d) as s) :: rest when builds ~stack:cx.stack t.n [ s ] || leaves [ s ]
    ->
      if leaves [ s ] && not (ends_all [ s ]) then
        Switch
          ( x,
            List.map (fun (tag, b) -> (tag, take_open cx t b)) cases,
            take_open cx t d )
        :: take cx t rest
      else
        Switch
          (x, List.map (fun (tag, b) -> (tag, take cx t b)) cases, take cx t d)
        :: rest
  (* a [Joins]'s first block ends by jumping, so each path through it
     takes or frees the token before it leaves *)
  | Joins (d, js) :: rest when builds ~stack:cx.stack t.n d -> Joins (take cx t d, js) :: rest
  | s :: rest when Rc.ends s -> Free_token (Var t.tok) :: s :: rest
  | (Loop _ | Joins _ | Catch _) :: _ -> Free_token (Var t.tok) :: b
  | s :: rest when guardable s -> guard t.tok s :: branch cx t rest
  | s :: _ when escapes s -> Free_token (Var t.tok) :: b
  | s :: rest -> s :: branch cx t rest

(* [b], a branch the path may go on from, after the statement it's in:
   the token is taken or freed on the paths that leave, and still held
   on those that go on. A path can only leave from a branch of an [If] or
   a [Switch] here; one that may leave from inside anything else isn't
   handled, and the object isn't reset ([Give_up]). *)
and take_open cx t (b : block) : block =
  if ends_all b then take cx t b
  else
    match b with
    | [] -> []
    | s :: rest when Rc.ends s -> Free_token (Var t.tok) :: s :: rest
    | If (c, th, e) :: rest when leaves [ List.hd b ] ->
        If (c, take_open cx t th, take_open cx t e) :: take_open cx t rest
    | Switch (x, cases, d) :: rest when leaves [ List.hd b ] ->
        Switch
          ( x,
            List.map (fun (tag, b) -> (tag, take_open cx t b)) cases,
            take_open cx t d )
        :: take_open cx t rest
    | s :: rest ->
        if escapes s then raise Give_up;
        s :: take_open cx t rest

(* A specialized drop's tree, the object [x] at its root, with [rest],
   the rest of the block, taking a token for each object in it that's
   freed where one as big is built after. The tokens are declared before
   it, null on the paths where nothing was reset. *)
let tree cx (u : var) (x : var) kept inner shared rest =
  let toks = ref [] and rest = ref rest in
  let reset_or (x : var) kept ~otherwise =
    match Hashtbl.find_opt cx.size (cx.root x) with
    | Some n when builds ~stack:cx.stack n !rest && not (List.mem x.id cx.stack)
      -> (
        let tok = fresh cx "$reuse" Token in
        let kept_vars =
          List.filter_map
            (fun (i, k) -> match k with Var v -> Some (i, v) | _ -> None)
            kept
        in
        match take cx { tok; n; origin = cx.root x; kept = kept_vars } !rest with
        | taken ->
            let r = fresh cx "$token" Token in
            rest := taken;
            toks := tok :: !toks;
            [ Let (r, Reset (Var x, kept)); Set (tok, Var r) ]
        | exception Give_up -> otherwise)
    | _ -> otherwise
  in
  (* the unique branch's statements after the free: the nested drops *)
  let rec nested (b : block) =
    match b with
    | Let (u2, Is_unique (Var c))
      :: If (Var u2', Free (Var c', kept2) :: inner2, shared2)
      :: more
      when u2.id = u2'.id && c.id = c'.id ->
        let unique =
          reset_or c kept2 ~otherwise:[ Free (Var c, kept2) ] @ nested inner2
        in
        Let (u2, Is_unique (Var c)) :: If (Var u2', unique, shared2) :: nested more
    | (Drop (Var c) as d) :: more when c.layout = Boxed ->
        let u2 = fresh cx "$unique" Bool in
        (match reset_or c [] ~otherwise:[] with
        | [] -> [ d ]
        | reset -> [ Let (u2, Is_unique (Var c)); If (Var u2, reset, [ d ]) ])
        @ nested more
    | s :: more -> s :: nested more
    | [] -> []
  in
  let unique = reset_or x kept ~otherwise:[ Free (Var x, kept) ] @ nested inner in
  List.rev_map (fun t -> Decl t) !toks
  @ [ Let (u, Is_unique (Var x)); If (Var u, unique, shared) ]
  @ !rest

let rec block cx (b : block) : block =
  match b with
  | [] -> []
  (* a drop rc.ml specialized: the object freed if it's unique, and the
     fields that die with it dropped the same way in turn *)
  | Let (u, Is_unique (Var x))
    :: If (Var u', Free (Var x', kept) :: inner, shared)
    :: rest
    when u.id = u'.id && x.id = x'.id && not (List.mem x.id cx.stack) ->
      tree cx u x kept inner shared (block cx rest)
  | (Drop (Var x) as s) :: rest
    when x.layout = Boxed && not (List.mem x.id cx.stack) -> (
      let rest = block cx rest in
      match Hashtbl.find_opt cx.size (cx.root x) with
      | Some n when builds ~stack:cx.stack n rest ->
          let u = fresh cx "$unique" Bool in
          tree cx u x [] [] [ s ] rest
      | _ -> s :: rest)
  | s :: rest ->
      let s = Rc.map_blocks (block cx) s in
      s :: block cx rest

let fn (f : fn) : fn =
  let next, _ = Rc.fresh_counters f in
  let root = roots f in
  let cx =
    {
      next; root; size = sizes root f; field = fields_of root f;
      stack = f.stack;
    } in
  { f with body = block cx f.body }

(* The program with each object that dies where one as big is built
   reused for it. *)
let program (p : program) : program = { p with fns = List.map fn p.fns }

(* How many fields the object each token of [f] was made of had, by the
   token's id: what inline.ml looks for a build of. *)
let token_sizes (f : fn) =
  let root = roots f in
  let size = sizes root f in
  let resets = Hashtbl.create 8 and toks = Hashtbl.create 8 in
  Rc.iter_stmts
    (function
      | Let (r, Reset (Var x, _)) -> (
          match Hashtbl.find_opt size (root x) with
          | Some n -> Hashtbl.replace resets r.id n
          | None -> ())
      | Set (t, Var r) when t.layout = Token -> (
          match Hashtbl.find_opt resets r.id with
          | Some n -> Hashtbl.replace toks t.id n
          | None -> ())
      | _ -> ())
    f.body;
  toks
