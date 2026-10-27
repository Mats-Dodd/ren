(* Reuse (compiler.md, "Native slice"): an object that dies where one of
   as many fields is built after it, its memory used for the new one if
   it's unique, after Koka's ParcReuse.hs and Lean's ResetReuse.lean.

   rc.ml drops an object whose fields are still used with a drop
   specialized for it: if it's unique, it's freed and its fields are
   kept. Here, if a constructor of as many fields is built after it, on
   the path that goes on, it's reset instead (Lean's [D] and [S],
   ResetReuse.lean:188 and :83; Koka's [ruBranch], ParcReuse.hs:305): its fields that aren't kept are
   dropped, and its memory is a token, a variable of layout [Token] the
   build takes, `kk_block_alloc_at` in kklib.h:628. A field the new
   object has in the same slot isn't written again (Lean's
   [isSelfSset], ExpandResetReuse.lean:153, the fields that didn't
   change). A plain drop of
   an object whose size is known, because the function reads its fields,
   is made the same way. The token is null if the object wasn't unique,
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

let is_alloc n (s : stmt) =
  match s with
  | Let (_, Alloc { fields; at = None; _ }) -> List.length fields = n
  | _ -> false

(* Whether a build of [n] fields is on some path through [b], not in a
   loop, before the path leaves the block. *)
let rec builds n (b : block) =
  List.exists
    (fun s ->
      is_alloc n s
      ||
      match s with
      | If (_, t, e) -> builds n t || builds n e
      | Switch (_, cases, d) ->
          List.exists (fun (_, b) -> builds n b) cases || builds n d
      | _ -> false)
    b

type cx = { next : int ref; root : var -> int; size : (int, int) Hashtbl.t }

let fresh cx name layout =
  let v = { id = !(cx.next); name; layout } in
  incr cx.next;
  v

(* [b], the rest of a block after [tok] is made, with the token taken by
   the first build of [n] fields on each path, or freed where the path
   ends without one. [kept] is what the reset kept, by slot: a build
   that has the same one in the same slot doesn't write it again. *)
let rec take cx tok n kept (b : block) : block =
  match b with
  | [] -> [ Free_token (Var tok) ]
  | (Let (v, Alloc a) as s) :: rest when is_alloc n s ->
      let same =
        List.concat
          (List.mapi
             (fun i x ->
               match (x, List.assoc_opt i kept) with
               | Var w, Some k when cx.root w = cx.root k -> [ i ]
               | _ -> [])
             a.fields)
      in
      Let (v, Alloc { a with at = Some (Var tok, same) }) :: rest
  | If (c, t, e) :: rest when builds n t || builds n e ->
      If (c, take cx tok n kept t, take cx tok n kept e) :: rest
  | Switch (x, cases, d) :: rest
    when List.exists (fun (_, b) -> builds n b) cases || builds n d ->
      Switch
        ( x,
          List.map (fun (t, b) -> (t, take cx tok n kept b)) cases,
          take cx tok n kept d )
      :: rest
  | s :: rest when Rc.ends s -> Free_token (Var tok) :: s :: rest
  | (Loop _ | Joins _ | Catch _) :: _ -> Free_token (Var tok) :: b
  | s :: rest -> s :: take cx tok n kept rest

(* The object [x], dying here with the drop [d] if it isn't unique,
   reset to a token the rest of the block, [rest], takes. *)
let reset cx (x : var) kept ~shared n rest =
  let tok = fresh cx "$reuse" Token in
  let u = fresh cx "$unique" Bool in
  let r = fresh cx "$token" Token in
  [
    Decl tok;
    Let (u, Is_unique (Var x));
    If (Var u, [ Let (r, Reset (Var x, kept)); Set (tok, Var r) ], shared);
  ]
  @ take cx tok n
      (List.filter_map
         (fun (i, k) -> match k with Var v -> Some (i, v) | _ -> None)
         kept)
      rest

let rec block cx (b : block) : block =
  match b with
  | [] -> []
  (* a drop rc.ml specialized: the object freed if it's unique *)
  | (Let (u, Is_unique (Var x)) as s1)
    :: (If (Var u', [ Free (Var x', kept) ], shared) as s2)
    :: rest
    when u.id = u'.id && x.id = x'.id -> (
      let rest = block cx rest in
      match Hashtbl.find_opt cx.size (cx.root x) with
      | Some n when builds n rest -> reset cx x kept ~shared n rest
      | _ -> s1 :: s2 :: rest)
  | (Drop (Var x) as s) :: rest when x.layout = Boxed -> (
      let rest = block cx rest in
      match Hashtbl.find_opt cx.size (cx.root x) with
      | Some n when builds n rest -> reset cx x [] ~shared:[ s ] n rest
      | _ -> s :: rest)
  | s :: rest ->
      let s = Rc.map_blocks (block cx) s in
      s :: block cx rest

let fn (f : fn) : fn =
  let next, _ = Rc.fresh_counters f in
  let root = roots f in
  let cx = { next; root; size = sizes root f } in
  { f with body = block cx f.body }

(* The program with each object that dies where one as big is built
   reused for it. *)
let program (p : program) : program = { p with fns = List.map fn p.fns }
