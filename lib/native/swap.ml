(* Swap-out (compiler.md, "Native slice"): an element read from an array
   only to be changed and written back where it was is moved out of the
   array, if the array is unique, rather than counted again, so the
   change can be made in place too. `grid[i][j] = x` changes the row
   where it is instead of copying it, and so does `map` over an array of
   arrays. It's Lean's: `Array.modify` swaps the element out
   (`swapAt`), and `Array.mapMUnsafe` writes `default` where it took
   one (`uset i default`, lean4 src/Init/Data/Array/Basic.lean:774),
   so the element's count is 1 when it's changed.

   After Perceus, `grid[i][j] = x` reads the row, counted again, and
   writes it back with [Array_set_taking]:

     row = (array-get grid i)            the row's count is now 2
     row' = (array-set-taking row j x)   so this copies it
     grid' = (array-set-taking grid i row')

   This pass makes that [Array_get] an [Array_take] (ren_rt.h,
   [ren_array_take]): if the array is unique, the row is moved out,
   still counted 1, and a scalar left in its place, which drops ignore;
   if it isn't, the row is counted again, as before.

   Why it's sound. A take is made only where the same array is written
   back at the same index by an [Array_set_taking], later in the same
   block, and nothing between can see the array:

   - Nothing between uses the array but to name it again. No statement
     between mentions any variable that may be it, its slot or a cell
     of it, a view of a field it's in, or a cast of it (its class,
     [classes]), but for a [Let] that names it again. So no [Dup] or
     [Drop] of it comes between, and its count at the take is its count
     at the write.
   - So the take moves the element out exactly when the write changes
     the array in place: both test the count is 1 ([ren_array_own]).
     The write takes a reference the function holds (Mem Lint checks
     the counting), and a count of 1 then means that reference is the
     only one: anything else that holds the array, a field, another
     variable's own reference, a caller that kept it, counts it. Only
     a borrowed name for that same reference doesn't, and every name
     the function has for it is in its class, which nothing between
     uses. So no one but the write sees the scalar, and the write
     replaces it.
   - Nothing between leaves the block another way. No [Break], [Jump],
     [Return] or [Raise], and no loop or catch, between; an [If] or a
     [Switch] between only if nothing in it calls, mentions the class
     or leaves. A call's error path may come between if it only drops
     the array and returns the error from the function, where nothing
     sees the array again; a panic ends the program.
   - A call between runs code that could reach the array only through
     a reference of its own, which counts it, or through a cell of a
     variable that holds it. So calls may come between only if no
     variable of the class has its address taken. That's `map`'s loop,
     `out[i] = f(out[i])`: `out` is a local no block captures.
   - The write is to the same array and the same index. Each is known
     by a token ([scan]) that a [Let] naming it again keeps and that
     changes where the variable could: a [Set] of it, or a call, a
     store or a nested block where its address is taken. The two
     tokens must agree.

   Mem Lint checks every take again with [unpaired], after hoist.ml has
   made some of them [Buf_take]s, written back by a [Buf_set] into the
   same buffer, which hoist.ml already knows is unique. *)

open Mem
module Ids = Set.Make (Int)
module Toks = Map.Make (Int)

(* ---- classes: the variables that may be one array ---- *)

(* A union-find over variable ids. *)
let rec find (uf : (int, int) Hashtbl.t) x =
  match Hashtbl.find_opt uf x with
  | Some p when p <> x ->
      let r = find uf p in
      Hashtbl.replace uf x r;
      r
  | _ -> x

let union uf a b =
  let a = find uf a and b = find uf b in
  if a <> b then Hashtbl.replace uf a b

type facts = {
  uf : (int, int) Hashtbl.t;
      (** the classes: a variable, another name for it, its slot, a cell of the
          slot, what's loaded from that, what's stored there, a part of it, a
          cast of it, a buffer of it *)
  addressed : Ids.t;  (** the classes a variable of which has a cell *)
  mutables : Ids.t;
      (** the variables whose value can change: [Decl]'d or [Set], or with a
          cell *)
  celled : Ids.t;
      (** the variables with a cell, which a call or a store may change *)
}

let facts (f : fn) =
  let uf = Hashtbl.create 64 in
  let cells = ref [] and mutables = ref Ids.empty in
  let join (v : var) (x : atom) =
    match x with Var y -> union uf v.id y.id | _ -> ()
  in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Let (v, Atom x)
      | Let (v, (To_word x | Of_word (x, _)))
      | Let (v, (Field (x, _, _) | Struct_get (x, _))) ->
          join v x
      | Let (v, Load c) -> union uf v.id c.id
      | Let (c, Addr v) ->
          union uf c.id v.id;
          cells := v :: !cells;
          mutables := Ids.add v.id !mutables
      | Let (v, Runtime ((Array_own | Array_data), [ x ], _)) -> join v x
      | Set (v, x) ->
          join v x;
          mutables := Ids.add v.id !mutables
      | Decl v -> mutables := Ids.add v.id !mutables
      | Store (c, x) -> join c x
      | _ -> ())
    f.body;
  let addressed =
    List.fold_left
      (fun acc (v : var) -> Ids.add (find uf v.id) acc)
      Ids.empty !cells
  in
  let celled = Ids.of_list (List.map (fun (v : var) -> v.id) !cells) in
  { uf; addressed; mutables = !mutables; celled }

(* ---- tokens: which value a variable holds, as a block goes on ---- *)

(* A variable's token says which value it holds: a [Let] that names
   another keeps the other's, and a constant is its own; what a cell
   holds has one too, which a [Load] of it gets. *)
type tok = T of int | K of int64

type scan = {
  toks : tok Toks.t;  (** each variable's, by its id *)
  held : tok Toks.t;  (** what each cell holds, by the cell's id *)
  next : int;
}

let start = { toks = Toks.empty; held = Toks.empty; next = 0 }

(* A token, from [m], or a new one there, which [sc] is given back with. *)
let tok_in m id sc =
  match Toks.find_opt id m with
  | Some t -> (t, m, sc)
  | None ->
      let t = T sc.next in
      (t, Toks.add id t m, { sc with next = sc.next + 1 })

let tok sc (v : var) =
  let t, toks, sc = tok_in sc.toks v.id sc in
  (t, { sc with toks })

let atom_tok sc (x : atom) =
  match x with Var v -> tok sc v | Int n -> (K n, sc) | _ -> (T (-1), sc)

(* Forget what can change: what cells hold, and the variables in [vars]:
   those with a cell, where a call or a store may change them, or all
   that can change, where a nested block may [Set] them. *)
let forget vars sc =
  {
    sc with
    toks = Toks.filter (fun id _ -> not (Ids.mem id vars)) sc.toks;
    held = Toks.empty;
  }

let calls_code (r : rhs) =
  match r with
  | Call _ -> true
  (* an operator or a value through a requirement's dictionary may be
     the program's own *)
  | Runtime ((Op_any _ | Value_any _), _, _) -> true
  | _ -> false

(* Whether [r] may change what a cell holds: a push into one. *)
let changes_cell (r : rhs) =
  match r with
  | Runtime (_, xs, _) ->
      List.exists
        (function Var { layout = Cell _; _ } -> true | _ -> false)
        xs
  | _ -> false

let set_tok sc (v : var) t = { sc with toks = Toks.add v.id t sc.toks }

(* [sc] after [s]. *)
let step fx sc (s : stmt) =
  match s with
  | Let (v, Atom (Int n)) -> set_tok sc v (K n)
  | Let (v, Atom (Var y)) | Set (v, Var y) ->
      let t, sc = tok sc y in
      set_tok sc v t
  | Let (v, Load c) ->
      let t, held, sc = tok_in sc.held c.id sc in
      set_tok { sc with held } v t
  | Let (v, r) ->
      let sc = { sc with toks = Toks.remove v.id sc.toks } in
      if calls_code r || changes_cell r then forget fx.celled sc else sc
  | Set (v, _) | Decl v -> { sc with toks = Toks.remove v.id sc.toks }
  | Store (c, x) ->
      let t, sc = atom_tok sc x in
      let sc = forget fx.celled sc in
      { sc with held = Toks.add c.id t sc.held }
  | Do _ | Call_fails _ | Call_block _ | Call_handler _ ->
      let sc =
        match s with
        | Call_fails { result; _ }
        | Call_block { result; _ }
        | Call_handler { result; _ } ->
            { sc with toks = Toks.remove result.id sc.toks }
        | _ -> sc
      in
      (* a call's error path never comes back here *)
      forget fx.celled sc
  | _ -> if Rc.blocks s = [] then sc else forget fx.mutables sc

(* ---- pairing a take with its write ---- *)

(* The variables [s] mentions itself: what it reads, and what it sets. *)
let mentions (s : stmt) =
  let set = match s with Set (v, _) | Decl v -> [ v ] | _ -> [] in
  set
  @ List.filter_map (function Var v -> Some v | _ -> None) (Rc.stmt_atoms s)

let in_class fx cls (v : var) = find fx.uf v.id = cls

(* Whether a nested block between a take and its write can't see the
   array, leave, or call. *)
let rec inert fx cls (b : block) =
  List.for_all
    (fun s ->
      (not (List.exists (in_class fx cls) (mentions s)))
      &&
      match s with
      | Let (_, r) | Do r -> not (calls_code r)
      | If (_, x, y) -> inert fx cls x && inert fx cls y
      | Switch (_, arms, d) ->
          List.for_all (fun (_, b) -> inert fx cls b) arms && inert fx cls d
      | Dup _ | Drop _ | Dup_word _ | Drop_word _ | Free _ | Free_token _
      | Set _ | Decl _ | Store _ | Assert _ | Panic _ ->
          true
      | _ -> false)
    b

(* Whether a call's error path only drops the array, and returns the
   error from the function. *)
let exits fx cls (b : block) =
  let rec go = function
    | [ Raise (_, None) ] -> true
    | s :: rest ->
        (match s with
          | (Drop (Var v) | Drop_word (Var v, _)) when in_class fx cls v -> true
          | Let (_, r) | Do r ->
              (not (calls_code r))
              && not (List.exists (in_class fx cls) (mentions s))
          | Dup _ | Drop _ | Dup_word _ | Drop_word _ | Free _ | Free_token _ ->
              not (List.exists (in_class fx cls) (mentions s))
          | _ -> false)
        && go rest
    | [] -> false
  in
  go b

(* A take of [arr] at [idx], and the write it pairs with. *)
type take = {
  arr : var;  (** the array, or the buffer of a hoisted loop *)
  buf : bool;  (** a [Buf_take], written back by a [Buf_set] *)
  arr_tok : tok;
  idx_tok : tok;
}

(* Whether [s] is the write [t] pairs with. *)
let writes_back sc t (s : stmt) =
  let same x i =
    let a, sc = atom_tok sc x in
    let b, _ = atom_tok sc i in
    a = t.arr_tok && b = t.idx_tok
  in
  match (t.buf, s) with
  | false, Let (_, Runtime (Array_set_taking _, [ x; i; _ ], _)) -> same x i
  | true, Do (Runtime (Buf_set _, [ p; _; i; _ ], _)) -> same p i
  | _ -> false

(* Whether the statements after a take, [rest], write it back as the
   comment at the top says, with [sc] the tokens just after it. *)
let paired fx sc t (rest : block) =
  let cls = find fx.uf t.arr.id in
  let calls = not (Ids.mem cls fx.addressed) in
  let rec go sc = function
    | [] -> false
    | s :: rest ->
        if writes_back sc t s then true
        else
          let mentioned = List.exists (in_class fx cls) (mentions s) in
          let ok =
            match s with
            (* another name for it, which only the write may use *)
            | Let (_, (Atom (Var _) | Load _)) -> true
            | _ when mentioned -> false
            | Let (_, r) | Do r -> calls || not (calls_code r)
            | Call_fails { on_error; _ } -> calls && exits fx cls on_error
            | Call_block { on_error; _ } ->
                calls && Option.fold ~none:true ~some:(exits fx cls) on_error
            | If (_, x, y) -> inert fx cls x && inert fx cls y
            | Switch (_, arms, d) ->
                List.for_all (fun (_, b) -> inert fx cls b) arms
                && inert fx cls d
            | Dup _ | Drop _ | Dup_word _ | Drop_word _ | Free _ | Free_token _
            | Set _ | Decl _ | Store _ | Assert _ | Panic _ ->
                true
            | _ -> false
          in
          ok && go (step fx sc s) rest
  in
  go sc rest

(* The take a statement is, or could be, of an element that's an object
   or a type variable's word, which may be one, with the tokens after
   it. *)
let take_of fx sc (s : stmt) =
  let mk arr i buf =
    let arr_tok, sc = tok sc arr in
    let idx_tok, sc = atom_tok sc i in
    Some ({ arr; buf; arr_tok; idx_tok }, step fx sc s)
  in
  match s with
  | Let (_, Runtime ((Array_get l | Array_take l), [ Var a; i ], _)) -> (
      match l with Boxed | Word _ -> mk a i false | _ -> None)
  | Let (_, Runtime (Buf_take _, [ Var p; _; i ], _)) -> mk p i true
  | _ -> None

(* Each block of [b] walked in order, [f] given each statement, the
   tokens before it and the statements after it in its block. *)
let rec walk fx f (b : block) : block =
  let rec go sc = function
    | [] -> []
    | s :: rest ->
        let s = f sc s rest in
        let s = Rc.map_blocks (walk fx f) s in
        s :: go (step fx sc s) rest
  in
  go start b

let fn (f : fn) =
  let fx = facts f in
  let body =
    walk fx
      (fun sc s rest ->
        match (s, take_of fx sc s) with
        | Let (v, Runtime (Array_get l, xs, site)), Some (t, after)
          when paired fx after t rest ->
            Let (v, Runtime (Array_take l, xs, site))
        | _ -> s)
      f.body
  in
  { f with body }

(* A program after Perceus with every element that can be taken taken. *)
let program (p : program) = { p with fns = List.map fn p.fns }

(* A take Mem Lint finds isn't written back as it must be, if there is
   one. *)
let unpaired (f : fn) =
  let fx = facts f in
  let bad = ref None in
  ignore
    (walk fx
       (fun sc s rest ->
         (match (s, take_of fx sc s) with
         | Let (v, Runtime ((Array_take _ | Buf_take _), _, _)), t ->
             let ok =
               match t with
               | Some (t, after) -> paired fx after t rest
               | None -> false
             in
             if not ok then bad := Some (Mem.show_var v)
         | _ -> ());
         s)
       f.body);
  !bad
