(* Perceus over Mem IR (compiler.md, "Native slice"): counting placed
   precisely, after Koka's Parc.hs and Lean's ExplicitRC.lean, so a value
   is counted again only where it's used again, and dropped as soon as
   it's dead.

   It starts from what to_mem.ml makes, the naive counting, and puts it
   in a shape Perceus can see through ([prepare]): every [Dup] and [Drop]
   erased, the runtime's array changes made the ones that take the array,
   and each `match` arm that only one test reaches moved to that test, so
   the subject dies where the arm's pattern takes it apart. Then
   borrow.ml decides which parameters are borrowed, and [program] places
   the counting again, one function at a time.

   What's counted is a group: a variable and the others that are only
   it under another name, a [Let] of it or its word. Each group is one
   of:
   - owned: it holds a reference, which is dropped where the group dies,
     or given away by its last use where that takes one;
   - borrowed: a borrowed parameter, or an associated value, which some
     caller keeps alive;
   - a part: a field of another group, borrowed from it while that one
     is alive. When the parent dies, a part that's still used is counted
     again first, so it owns its reference from then on (Lean's derived
     borrows, ExplicitRC.lean, [addDescendants] :291 and [withCtorAlt]
     :257; Koka's [dup] of a pattern's variables before the [drop] of
     what it matched);
   - a view: what a mutable variable or a local whose address is taken
     holds now, or what a cell holds, borrowed while that doesn't
     change. One that's live where it changes is a snapshot, and owns a
     reference from where it's made.
   A local whose address is taken is a slot: whatever the cells that
   point at it do, it holds its value until its scope ends.

   Liveness is the backward analysis every Perceus does, over the groups:
   loops by a fixpoint, join points and catches by the live sets of
   their blocks. Placing it is one backward walk: a use that takes a
   reference takes the group's if the group dies there, and counts it
   again if not (Lean's [useVar] :308 and [useArgs] :316); a group that
   dies at a use that only reads it, or that's never used, is dropped
   right after; and each branch drops first what's dead in it but live
   in another ([addPrologForAlt] :394, Koka's [parcBranches], Parc.hs:239).
   A drop whose object's fields the program keeps is specialized: if
   it's unique, it's freed without counting them, and if not, they're
   counted and it's dropped (Koka's [specializeDrop], Parc.hs:356).

   Ownership is only an optimization: what the program computes never
   depends on it (compiler.md, "What it has to do", rule 1). Mem Lint
   checks the counting it places, path by path. *)

open Mem
module Ids = Set.Make (Int)

let bug what = failwith ("bug: Perceus: " ^ what)

(* ---- walking statements ---- *)

(* [s] with each block in it changed by [f]. *)
let map_blocks f (s : stmt) : stmt =
  match s with
  | Call_fails c -> Call_fails { c with on_error = f c.on_error }
  | Call_block c -> Call_block { c with on_error = Option.map f c.on_error }
  | Call_handler c -> Call_handler { c with on_error = Option.map f c.on_error }
  | If (c, t, e) -> If (c, f t, f e)
  | Switch (x, cases, d) ->
      Switch (x, List.map (fun (t, b) -> (t, f b)) cases, f d)
  | Loop (l, b) -> Loop (l, f b)
  | Joins (b, js) -> Joins (f b, List.map (fun (l, j) -> (l, f j)) js)
  | Catch c -> Catch { c with body = f c.body; handler = f c.handler }
  | s -> s

(* The blocks in [s]. *)
let blocks (s : stmt) : block list =
  match s with
  | Call_fails c -> [ c.on_error ]
  | Call_block { on_error; _ } | Call_handler { on_error; _ } ->
      Option.to_list on_error
  | If (_, t, e) -> [ t; e ]
  | Switch (_, cases, d) -> List.map snd cases @ [ d ]
  | Loop (_, b) -> [ b ]
  | Joins (b, js) -> b :: List.map snd js
  | Catch c -> [ c.body; c.handler ]
  | _ -> []

let rhs_atoms (r : rhs) : atom list =
  match r with
  | Atom x
  | Neg (x, _)
  | Not x
  | Tag_of x
  | Field (x, _, _)
  | Struct_get (x, _)
  | To_word x
  | Of_word (x, _)
  | Env_get (x, _)
  | Arg (x, _)
  | Block_of (_, x)
  | Op_block (x, _, _)
  | Is_unique x
  | Unpack (x, _, _)
  | Hole (x, _) ->
      [ x ]
  | Pack ps -> List.map (fun (x, _, _) -> x) ps
  | Arith (_, x, y, _) | Late (_, x, y, _) | Compare (_, x, y) -> [ x; y ]
  | Alloc { fields; words; at; _ } ->
      fields @ words @ Option.to_list (Option.map fst at)
  | Alloc_array { elems; desc; _ } -> elems @ Option.to_list desc
  | Call (_, xs)
  | Runtime (_, xs, _)
  | Env_new xs
  | Impl (_, xs)
  | Make_struct xs ->
      xs
  | Load v | Addr v -> [ Var v ]
  | Global _ -> []
  | Install { outer; impls; deps; ndeps } -> (outer :: impls) @ [ deps; ndeps ]
  | Given { outer; caller; _ } -> [ outer; caller ]
  | Reset (x, kept) -> x :: List.map snd kept

(* What [s] itself reads, not in its blocks: a [Set]'s variable is what
   it defines, not a use. *)
let stmt_atoms (s : stmt) : atom list =
  match s with
  | Let (_, r) | Do r -> rhs_atoms r
  | Decl _ -> []
  | Set (_, x) -> [ x ]
  | Store (c, x) -> [ Var c; x ]
  | Dup x | Drop x | Free_token x -> [ x ]
  | Fill (p, x) -> [ p; x ]
  | Dup_word (x, d) | Drop_word (x, d) -> [ x; d ]
  | Free (x, kept) -> x :: List.map snd kept
  | Call_fails { args; _ } -> args
  | Call_block { block; ev; args; _ } -> block :: ev :: args
  | Call_handler { handler; outer; body; desc; _ } ->
      [ handler; outer; body; desc ]
  | If (c, _, _) | Switch (c, _, _) | Raise (c, _) | Return c | Assert (c, _) ->
      [ c ]
  | Loop _ | Break _ | Joins _ | Jump _ | Catch _ | Panic _ -> []

let atom_vars xs = List.filter_map (function Var v -> Some v | _ -> None) xs

(* Every statement in [b], its blocks' too, in order. *)
let rec iter_stmts f (b : block) =
  List.iter
    (fun s ->
      f s;
      List.iter (iter_stmts f) (blocks s))
    b

(* Whether control never goes on after [s]. *)
let ends (s : stmt) =
  match s with
  | Return _ | Raise _ | Break _ | Jump _ | Panic _ -> true
  | _ -> false

(* The labels and variable ids [f] uses, so new ones come after. *)
let fresh_counters (f : fn) =
  let var = ref 0 and label = ref 0 in
  let see_var (v : var) = var := max !var v.id in
  List.iter see_var f.params;
  iter_stmts
    (fun s ->
      (match s with
      | Let (v, _) | Decl v | Set (v, _) -> see_var v
      | Call_fails { result; error; _ }
      | Call_block { result; error; _ }
      | Call_handler { result; error; _ } ->
          see_var result;
          see_var error
      | Catch { label = l; error; _ } ->
          see_var error;
          label := max !label l
      | Loop (l, _) -> label := max !label l
      | Joins (_, js) -> List.iter (fun (l, _) -> label := max !label l) js
      | _ -> ());
      List.iter see_var (atom_vars (stmt_atoms s)))
    f.body;
  (ref (!var + 1), ref (!label + 1))

(* ---- preparing the naive IR ---- *)

(* Every count to_mem.ml placed erased, what's after a statement that
   never goes on dropped, and the array changes made the ones that take
   the array. *)
let rec erase (b : block) : block =
  let taking (r : rhs) =
    match r with
    | Runtime (Array_set l, xs, s) -> Runtime (Array_set_taking l, xs, s)
    | Runtime (Array_set_field (n, k, l), xs, s) ->
        Runtime (Array_set_field_taking (n, k, l), xs, s)
    | Runtime (Array_push l, xs, s) -> Runtime (Array_push_taking l, xs, s)
    | r -> r
  in
  match b with
  | [] -> []
  | (Dup _ | Drop _ | Dup_word _ | Drop_word _ | Free _ | Free_token _) :: rest
    ->
      erase rest
  | s :: rest ->
      let s =
        match map_blocks erase s with
        | Let (v, r) -> Let (v, taking r)
        | Do r -> Do (taking r)
        | s -> s
      in
      if ends s then [ s ] else s :: erase rest

(* A `match` arm one test reaches, moved to that test: its [Jump]
   becomes the arm, then a jump past the rest, to a label of its own
   whose block is empty. So the arm runs where the pattern's variables
   are taken out of the subject, which can die there. *)
let rec inline_joins label (b : block) : block =
  List.concat_map
    (fun s ->
      match map_blocks (inline_joins label) s with
      | Joins (dispatch, joins) ->
          let count = Hashtbl.create 8 in
          iter_stmts
            (function
              | Jump l ->
                  Hashtbl.replace count l
                    (1 + Option.value (Hashtbl.find_opt count l) ~default:0)
              | _ -> ())
            dispatch;
          let once (l, _) = Hashtbl.find_opt count l = Some 1 in
          if not (List.exists once joins) then [ Joins (dispatch, joins) ]
          else
            let end_ = !label in
            incr label;
            let rec move b =
              List.concat_map
                (fun s ->
                  match s with
                  | Jump l when List.exists (fun j -> fst j = l && once j) joins
                    ->
                      erase (List.assoc l joins @ [ Jump end_ ])
                  | s -> [ map_blocks move s ])
                b
            in
            [
              Joins
                ( move dispatch,
                  List.filter (fun j -> not (once j)) joins @ [ (end_, []) ] );
            ]
      | s -> [ s ])
    b

(* How many times each variable is read, anywhere in [b]. *)
let use_counts (b : block) =
  let n = Hashtbl.create 64 in
  iter_stmts
    (fun s ->
      List.iter
        (fun (v : var) ->
          Hashtbl.replace n v.id
            (1 + Option.value (Hashtbl.find_opt n v.id) ~default:0))
        (atom_vars (stmt_atoms s)))
    b;
  n

let uses_of n (v : var) = Option.value (Hashtbl.find_opt n v.id) ~default:0

(* A variable declared, then set once, where every read of it comes after
   that [Set] in its block, made a [Let] there: a pattern's variable, once
   its arm is moved to its test, is the field it's set to. *)
let set_once (body : block) : block =
  let sets = Hashtbl.create 16 and decls = Hashtbl.create 16 in
  iter_stmts
    (function
      | Set (v, _) ->
          Hashtbl.replace sets v.id
            (1 + Option.value (Hashtbl.find_opt sets v.id) ~default:0)
      | Decl v -> Hashtbl.replace decls v.id ()
      | _ -> ())
    body;
  let total = use_counts body in
  let made = Hashtbl.create 16 in
  let rec go (b : block) =
    match b with
    | [] -> []
    | Set (v, x) :: rest
      when Hashtbl.mem decls v.id
           && Hashtbl.find_opt sets v.id = Some 1
           && uses_of (use_counts rest) v = uses_of total v ->
        Hashtbl.replace made v.id ();
        Let (v, Atom x) :: go rest
    | s :: rest -> map_blocks go s :: go rest
  in
  let body = go body in
  let rec undecl b =
    List.filter_map
      (fun s ->
        match s with
        | Decl v when Hashtbl.mem made v.id -> None
        | s -> Some (map_blocks undecl s))
      b
  in
  undecl body

(* Whether [r] does nothing but give a value, so a [Let] of it nothing
   reads can go. *)
let pure (r : rhs) =
  match r with
  | Atom _ | Field _ | Load _ | Addr _ | To_word _ | Of_word _ | Tag_of _
  | Compare _ | Not _ | Global _ | Env_get _ | Is_unique _ | Pack _ | Unpack _ ->
      true
  | _ -> false

(* Every [Let] of a pure value nothing reads, gone: the loads to_mem.ml
   made to drop what a cell held before it changed. *)
let rec unread ~keep (body : block) : block =
  let n = use_counts body in
  let removed = ref false in
  let rec go b =
    List.filter_map
      (fun s ->
        match s with
        | Let (v, r) when pure r && uses_of n v = 0 && not (keep v) ->
            removed := true;
            None
        | s -> Some (map_blocks go s))
      b
  in
  let body = go body in
  if !removed then unread ~keep body else body

(* A word made of what a variable that changes holds now, made of a
   copy of it first: the copy is what it holds, an object, which can be
   counted where the variable changes. *)
let name_views next (body : block) : block =
  let changes = Hashtbl.create 16 in
  iter_stmts
    (function
      | Decl v | Set (v, _) | Let (_, Addr v) -> Hashtbl.replace changes v.id ()
      | _ -> ())
    body;
  let rec go b =
    List.concat_map
      (fun s ->
        match s with
        | Let (w, To_word (Var m))
          when Hashtbl.mem changes m.id && is_object m.layout ->
            let t = { m with id = !next } in
            incr next;
            [ Let (t, Atom (Var m)); Let (w, To_word (Var t)) ]
        | s -> [ map_blocks go s ])
      b
  in
  go body

let prepare_fn (f : fn) : fn =
  let next, label = fresh_counters f in
  let body = erase f.body in
  let body = erase (inline_joins label body) in
  let body = name_views next (set_once body) in
  (* a type variable's descriptor stays, which counting its words needs *)
  let keep (v : var) =
    List.exists (fun (_, (d : var)) -> d.id = v.id) f.words
  in
  { f with body = unread ~keep body }

(* The program with its counting erased and ready for Perceus. *)
let prepare (p : program) : program = { p with fns = List.map prepare_fn p.fns }

(* ---- groups ---- *)

type kind =
  | Uncounted  (** its layout has no count *)
  | Static  (** a constant: never freed, never counted *)
  | Borrowed_param
      (** a borrowed parameter, an associated value or a descriptor a block's
          environment holds: someone else keeps it alive *)
  | Owned
  | Part of int * int  (** a field of this group, at this slot *)
  | View of int
      (** what this group, a mutable variable or a slot, holds now: the same
          object *)
  | Cell_view of var  (** what this cell holds now *)

type group = {
  gid : int;  (** its first variable's id *)
  mutable kind : kind;
  mutable members : var list;  (** in the order they're made *)
  mutable children : int list;  (** the parts and views of it *)
  mutable snap : bool;
      (** a view live where what it views changes: owned from where it's made *)
  mutable uses : int;  (** how many times its variables are read *)
  mutable cvar : var option;  (** the variable it's counted through *)
}

type info = {
  fn : fn;
  fns : (string, fn) Hashtbl.t;
  group_of : (int, group) Hashtbl.t;  (** by variable id *)
  mutable groups : group list;
  slots : Ids.t;  (** counted locals whose address is taken *)
  mutables : Ids.t;  (** variables a [Set] changes, or declared first *)
}

let group fi (v : var) =
  match Hashtbl.find_opt fi.group_of v.id with
  | Some g -> g
  | None -> bug ("no group for " ^ show_var v ^ " in " ^ fi.fn.name)

let new_group fi (v : var) kind =
  let g =
    {
      gid = v.id;
      kind = (if counted v.layout then kind else Uncounted);
      members = [ v ];
      children = [];
      snap = false;
      uses = 0;
      cvar = None;
    }
  in
  Hashtbl.replace fi.group_of v.id g;
  fi.groups <- g :: fi.groups;
  g

let find_group fi id = List.find (fun g -> g.gid = id) fi.groups

(* Whether a group is counted here at all: Perceus tracks it. *)
let tracked g =
  match g.kind with
  | Owned | Part _ | View _ | Cell_view _ -> true
  | Uncounted | Static | Borrowed_param -> false

(* Whether a group owns its reference where it's made. *)
let owner g = g.kind = Owned || g.snap
let is_struct (l : layout) = match l with Struct _ -> true | _ -> false
let parent g = match g.kind with Part (p, _) | View p -> Some p | _ -> None

(* Whether a value of this layout is counted as itself, not through a
   descriptor: an object, or a struct that holds one, counted as the
   objects in it are. *)
let direct (l : layout) =
  is_object l || match l with Struct (_, c) -> c | _ -> false

(* The callee of a call, by its C name. *)
let callee fi name =
  match Hashtbl.find_opt fi.fns name with
  | Some f -> f
  | None -> bug ("a call of " ^ name ^ ", which isn't in the program")

(* Which groups each variable is in, what each is, and which are parts or
   views of which. *)
let analyze fns (f : fn) : info =
  let slots = ref Ids.empty and mutables = ref Ids.empty in
  iter_stmts
    (fun s ->
      match s with
      | Let (_, Addr v) when counted v.layout -> slots := Ids.add v.id !slots
      | Set (v, _) | Decl v -> mutables := Ids.add v.id !mutables
      | _ -> ())
    f.body;
  let fi =
    {
      fn = f;
      fns;
      group_of = Hashtbl.create 64;
      groups = [];
      slots = !slots;
      mutables = !mutables;
    }
  in
  let ssa (v : var) = not (Ids.mem v.id fi.mutables || Ids.mem v.id fi.slots) in
  let changes (v : var) = not (ssa v) in
  List.iter2
    (fun (v : var) m ->
      ignore
        (new_group fi v
           (if changes v then Owned
            else
              match (m : mode) with
              | Owned -> Owned
              | Borrowed -> Borrowed_param)))
    f.params
    (if List.length f.modes = List.length f.params then f.modes
     else List.map (fun _ : mode -> Owned) f.params);
  let alias (v : var) (x : var) =
    let g = group fi x in
    if g.kind = Uncounted || not (counted v.layout) then
      ignore (new_group fi v (if counted v.layout then Static else Uncounted))
    else (
      g.members <- g.members @ [ v ];
      Hashtbl.replace fi.group_of v.id g)
  in
  let child (v : var) kind p =
    let g = new_group fi v kind in
    if g.kind <> Uncounted then p.children <- p.children @ [ g.gid ]
  in
  (* [v] made from [x], the same value under another name *)
  let uncount = Hashtbl.create 8 and results = Hashtbl.create 8 in
  let same (v : var) (x : atom) =
    match x with
    | Var x ->
        let gx = group fi x in
        (* a word made an [Int], say: a callee's type variable's, which is
           this one here, uncounted *)
        if (not (counted v.layout)) && gx.kind <> Uncounted then
          Hashtbl.replace uncount gx.gid ();
        if (not (counted v.layout)) || gx.kind = Uncounted then
          ignore
            (new_group fi v (if counted v.layout then Static else Uncounted))
        else if ssa x && ssa v then alias v x
        else if ssa v then child v (View gx.gid) gx
        else ignore (new_group fi v Owned)
    | _ -> ignore (new_group fi v (if changes v then Owned else Static))
  in
  let define (v : var) kind = ignore (new_group fi v kind) in
  let rec go b =
    List.iter
      (fun s ->
        (match s with
        | Let (v, r) -> (
            match r with
            | Atom x | To_word x | Of_word (x, _) -> same v x
            | (Field (Var x, slot, _) | Struct_get (Var x, slot))
              when not (changes v) ->
                let gx = group fi x in
                if gx.kind = Uncounted then define v Uncounted
                else child v (Part (gx.gid, slot)) gx
            | Load c when not (changes v) -> (
                match c.layout with
                | Cell Desc -> define v Borrowed_param
                | _ -> define v (Cell_view c))
            | Global _ -> define v (if changes v then Owned else Borrowed_param)
            | Call _ ->
                define v Owned;
                Hashtbl.replace results v.id ()
            | _ -> define v Owned)
        | Decl v -> define v Owned
        | Call_fails { result; error; _ }
        | Call_block { result; error; _ }
        | Call_handler { result; error; _ } ->
            define error Owned;
            define result Owned;
            Hashtbl.replace results result.id ()
        | Catch { error; _ } -> define error Owned
        | _ -> ());
        List.iter go (blocks s))
      b
  in
  go f.body;
  (* a variable defined twice is a bug Mem Lint finds; uses are counted
     for each group *)
  iter_stmts
    (fun s ->
      List.iter
        (fun (v : var) ->
          match Hashtbl.find_opt fi.group_of v.id with
          | Some g -> g.uses <- g.uses + 1
          | None -> ())
        (atom_vars (stmt_atoms s)))
    f.body;
  (* the variable each group is counted through: one that's always an
     object if it has one, else a word of one of this function's own type
     variables. A word of a callee's, the result of a call to a generic
     function, is counted through the [Let] that makes it a value of the
     caller's own type, if there's one; if that type isn't counted,
     neither is the group *)
  List.iter
    (fun g ->
      let own (v : var) =
        match v.layout with
        | Word n -> List.mem_assoc n f.words
        | l -> direct l
      in
      let renamed (v : var) = own v && not (Hashtbl.mem results v.id) in
      g.cvar <-
        (match
           List.find_opt (fun (v : var) -> direct v.layout) g.members
         with
        | Some v -> Some v
        | None -> (
            match List.find_opt renamed g.members with
            | Some v -> Some v
            | None -> List.find_opt own g.members));
      if g.cvar = None || Hashtbl.mem uncount g.gid then g.kind <- Uncounted)
    fi.groups;
  fi

let count_var g = g.cvar

(* One more reference to the group's value, or one fewer. *)
let count fi g ~dup : stmt list =
  match count_var g with
  | None -> []
  | Some v -> (
      match v.layout with
      | Word n -> (
          match List.assoc_opt n fi.fn.words with
          | Some d ->
              [
                (if dup then Dup_word (Var v, Var d)
                 else Drop_word (Var v, Var d));
              ]
          | None ->
              bug
                (Printf.sprintf
                   "a word of type variable %d with no descriptor in %s" n
                   fi.fn.name))
      | _ -> [ (if dup then Dup (Var v) else Drop (Var v)) ])

(* The same, for a variable of its own layout: what a cell held. *)
let count_var_layout fi (v : var) ~dup : stmt list =
  match v.layout with
  | Word n -> (
      match List.assoc_opt n fi.fn.words with
      | Some d ->
          [
            (if dup then Dup_word (Var v, Var d) else Drop_word (Var v, Var d));
          ]
      | None -> bug "a cell of a word with no descriptor")
  | l when direct l -> [ (if dup then Dup (Var v) else Drop (Var v)) ]
  | _ -> []

(* ---- uses ---- *)

(* The tracked group of an atom, if it has one. *)
let tracked_of fi (x : atom) =
  match x with
  | Var v -> (
      match Hashtbl.find_opt fi.group_of v.id with
      | Some g when tracked g -> Some g.gid
      | _ -> None)
  | _ -> None

(* The counted group of an atom, tracked or not: what a use that takes a
   reference counts again. *)
let counted_of fi (x : atom) =
  match x with
  | Var v -> (
      match Hashtbl.find_opt fi.group_of v.id with
      | Some g when g.kind <> Uncounted && g.kind <> Static -> Some g
      | _ -> None)
  | _ -> None

let modes_of (f : fn) =
  if List.length f.modes = List.length f.params then f.modes
  else List.map (fun _ : mode -> Owned) f.params

(* What [s] itself uses: the atoms it takes a reference from, with
   repeats, and those it only reads. *)
let operands fi (s : stmt) : atom list * atom list =
  let call name args =
    let f = callee fi name in
    let modes = modes_of f in
    if List.length modes <> List.length args then ([], args)
    else
      List.fold_right2
        (fun x m (o, b) ->
          match (m : mode) with Owned -> (x :: o, b) | Borrowed -> (o, x :: b))
        args modes ([], [])
  in
  let rhs (r : rhs) =
    match r with
    | Alloc { fields; words; _ } -> (fields, words)
    | Alloc_array { elems; desc; _ } -> (elems, Option.to_list desc)
    | Call (name, args) -> call name args
    | Runtime (rt, args, _) ->
        let o, b =
          List.partition
            (fun (i, _) -> takes rt i)
            (List.mapi (fun i x -> (i, x)) args)
        in
        (List.map snd o, List.map snd b)
    | Reset (x, _) -> ([ x ], [])
    | Make_struct xs -> (xs, [])
    | r -> ([], rhs_atoms r)
  in
  match s with
  | Let (v, (Atom x | To_word x | Of_word (x, _))) -> (
      match (Hashtbl.find_opt fi.group_of v.id, x) with
      | Some g, Var xv when (group fi xv).gid = g.gid -> ([], [])
      | Some { kind = View _; snap = true; _ }, Var xv
        when not (Ids.mem xv.id fi.slots) ->
          ([ x ], [])
      | Some { kind = View _; _ }, _ -> ([], [ x ])
      | Some { kind = Owned; _ }, _ -> ([ x ], [])
      | _ -> ([], [ x ]))
  | Let (_, r) | Do r -> rhs r
  | Set (_, x) -> ([ x ], [])
  | Store (_, x) -> ([ x ], [])
  | Fill (_, x) -> ([ x ], [])
  | Call_fails { fn; args; _ } -> call fn args
  | Call_block { args; _ } -> (args, [])
  | Call_handler { handler; desc; _ } -> ([], [ handler; desc ])
  | Return x | Raise (x, _) -> ([ x ], [])
  | _ -> ([], [])

(* The tracked groups [s] defines on the path that goes on after it. *)
let defines fi (s : stmt) : int list =
  let own (v : var) =
    match Hashtbl.find_opt fi.group_of v.id with
    | Some g when tracked g && g.gid = v.id -> [ g.gid ]
    | _ -> []
  in
  match s with
  | Let (v, _) | Set (v, _) -> own v
  | Call_fails { result; _ }
  | Call_block { result; _ }
  | Call_handler { result; _ } ->
      own result
  | _ -> []

let ids_of fi xs = Ids.of_list (List.filter_map (tracked_of fi) xs)

(* Whether [s] may change what a slot or a cell holds: a store, a push,
   or any call, which may be given a cell or a block that changes one. *)
let writes_slots fi (s : stmt) =
  match s with
  | Set (v, _) -> Ids.mem v.id fi.slots
  | Store _ | Call_fails _ | Call_block _ | Call_handler _ -> true
  | Let (_, Call _) | Do (Call _) -> true
  | Let (_, Runtime (Array_push_taking _, _, _))
  | Do (Runtime (Array_push_taking _, _, _)) ->
      true
  | _ -> false

(* Whether [f]'s body consumes each of its parameters, given its
   callees' modes in [fns]: it gives the parameter away, or a part or a
   view of it, or changes it (borrow.ml; Lean's [ownVar] of a
   projection's parent, InferBorrow.lean). *)
let consumed fns (f : fn) =
  let fi = analyze fns f in
  let rec root g =
    match parent g with Some p -> root (find_group fi p) | None -> g
  in
  let owned = Hashtbl.create 8 in
  iter_stmts
    (fun s ->
      let o, _ = operands fi s in
      List.iter
        (fun (x : atom) ->
          match x with
          | Var v -> (
              match Hashtbl.find_opt fi.group_of v.id with
              | Some g -> Hashtbl.replace owned (root g).gid ()
              | None -> ())
          | _ -> ())
        o)
    f.body;
  fun (v : var) ->
    Hashtbl.mem owned v.id || Ids.mem v.id fi.mutables || Ids.mem v.id fi.slots

(* The variables [s] defines for the statements after it. *)
let made (s : stmt) =
  match s with
  | Let (v, _) | Decl v -> Ids.singleton v.id
  | Call_fails { result; _ }
  | Call_block { result; _ }
  | Call_handler { result; _ } ->
      Ids.singleton result.id
  | _ -> Ids.empty

(* ---- liveness ---- *)

type cx = {
  fi : info;
  always : Ids.t;
      (** the slots in scope, and the owned descriptors words are counted
          through: alive until their scope ends *)
  defined : Ids.t;
      (** the variables in scope: what a nested drop may name ([dtree]) *)
  breaks : (int * Ids.t) list;
  jumps : (int * Ids.t) list;
  raises : (int * Ids.t) list;
}

(* Whether a group's value is used in [live], itself or through a part or
   a view of it that isn't a snapshot. *)
let rec live_through fi live gid =
  Ids.mem gid live
  || List.exists
       (fun c ->
         let g = find_group fi c in
         (not g.snap) && live_through fi live c)
       (find_group fi gid).children

(* A view that's live where what it views changes is a snapshot. *)
let mark_snapshots cx (s : stmt) (after : Ids.t) =
  let fi = cx.fi in
  let check live g =
    if (not g.snap) && live_through fi live g.gid then g.snap <- true
  in
  (match s with
  | Set (m, _) when not (Ids.mem m.id fi.slots) -> (
      match Hashtbl.find_opt fi.group_of m.id with
      | Some gm ->
          List.iter
            (fun c ->
              let g = find_group fi c in
              match g.kind with View _ -> check after g | _ -> ())
            gm.children
      | None -> ())
  | _ -> ());
  if writes_slots fi s then
    let live =
      match s with
      | Set _ | Store _ -> after
      | s ->
          let o, b = operands fi s in
          Ids.union after (ids_of fi (o @ b))
    in
    List.iter
      (fun g ->
        match g.kind with
        | View p when Ids.mem p fi.slots -> check live g
        | Cell_view _ -> check live g
        | _ -> ())
      fi.groups

(* Each statement of [b] with the context it runs in: the slots made
   before it in [b] are in scope. *)
let scoped cx (b : block) =
  let fi = cx.fi in
  let always_desc (v : var) =
    List.exists (fun (_, (d : var)) -> d.id = v.id) fi.fn.words
  in
  let _, items =
    List.fold_left
      (fun (cx, acc) s ->
        let cx' =
          match s with
          | Let (v, _) when Ids.mem v.id fi.slots || always_desc v -> (
              match Hashtbl.find_opt fi.group_of v.id with
              | Some g when owner g ->
                  { cx with always = Ids.add g.gid cx.always }
              | _ -> cx)
          | _ -> cx
        in
        let cx' = { cx' with defined = Ids.union cx'.defined (made s) } in
        (cx', (cx, s) :: acc))
      (cx, []) b
  in
  List.rev items

let rec live_block cx (b : block) (out : Ids.t) : Ids.t =
  List.fold_right (fun (cx, s) l -> live_stmt cx s l) (scoped cx b) out

and live_stmt cx (s : stmt) (after : Ids.t) : Ids.t =
  let fi = cx.fi in
  let o, b = operands fi s in
  let uses = ids_of fi (o @ b) in
  let err_block (error : var) on_error out =
    match on_error with
    | Some blk -> Ids.remove error.id (live_block cx blk out)
    | None -> Ids.empty
  in
  let before =
    match s with
    | If (_, t, e) -> Ids.union (live_block cx t after) (live_block cx e after)
    | Switch (_, cases, d) ->
        List.fold_left
          (fun acc (_, b) -> Ids.union acc (live_block cx b after))
          (live_block cx d after) cases
    | Loop (l, body) ->
        let cx' = { cx with breaks = (l, after) :: cx.breaks } in
        let rec fix h =
          let h' = Ids.union h (live_block cx' body h) in
          if Ids.equal h h' then h else fix h'
        in
        fix Ids.empty
    | Joins (d, js) ->
        let live = List.map (fun (l, j) -> (l, live_block cx j after)) js in
        live_block { cx with jumps = live @ cx.jumps } d after
    | Catch { label; body; error; handler } ->
        let h = Ids.remove error.id (live_block cx handler after) in
        live_block { cx with raises = (label, h) :: cx.raises } body after
    | Jump l -> List.assoc l cx.jumps
    | Break l -> List.assoc l cx.breaks
    | Raise (_, Some l) -> Ids.union (List.assoc l cx.raises) uses
    | Raise (_, None) | Return _ -> uses
    | Panic _ -> Ids.empty
    | Call_fails { result; error; on_error; _ } ->
        let rest = Ids.remove result.id after in
        Ids.union uses (Ids.union rest (err_block error (Some on_error) rest))
    | Call_block { result; error; on_error; _ }
    | Call_handler { result; error; on_error; _ } ->
        let rest = Ids.remove result.id after in
        Ids.union uses (Ids.union rest (err_block error on_error rest))
    | _ -> Ids.union uses (Ids.diff after (Ids.of_list (defines fi s)))
  in
  mark_snapshots cx s after;
  if ends s then before else Ids.union before cx.always

(* ---- placing the counts ---- *)

type placer = {
  info : info;
  next : int ref;  (** the next fresh variable's id *)
  taken : (int, unit) Hashtbl.t;
      (** views a use takes straight from their slot, which the store after
          fills again *)
  untouched : stmt list;  (** the stores after them, which drop nothing *)
}

let fresh pl name layout =
  let v = { id = !(pl.next); name; layout } in
  incr pl.next;
  v

(* Whether group [gid] holds a reference of its own while [s] runs:
   an owner, or a part or view whose parent isn't alive through [s]. A
   parent is alive if it's used after, or used by [s] without being
   taken; [moved] says which groups [s] takes. *)
let rec owns fi ~after ~uses ~moved gid =
  let g = find_group fi gid in
  if owner g then true
  else
    match parent g with
    | Some p -> not (alive fi ~after ~uses ~moved p)
    | None -> false

and alive fi ~after ~uses ~moved gid =
  let g = find_group fi gid in
  if not (tracked g) then true
  else if g.kind = Owned || g.snap then
    Ids.mem gid after || (Ids.mem gid uses && not (moved gid))
  else if owns fi ~after ~uses ~moved gid then
    Ids.mem gid after || (Ids.mem gid uses && not (moved gid))
  else true

(* The counting that makes the descendants of [gid], which is dying,
   that are live in [live] own their references: one more of each, but a
   view, the same object, which can take [gid]'s own if [transfer]. The
   parts of [gid]'s own object are returned as [(slot, var)], for a
   specialized drop; with [transfer], the view that took it. *)
let promote pl gid ~live ~transfer =
  let fi = pl.info in
  let incs = ref [] and parts = ref [] and took = ref false in
  let rec go gid ~direct =
    List.iter
      (fun c ->
        let g = find_group fi c in
        if not g.snap then
          if Ids.mem c live then
            match g.kind with
            | View _ when transfer && direct && not !took -> took := true
            | Part (_, slot) when direct -> (
                match count_var g with
                | Some v when not (List.mem_assoc slot !parts) ->
                    parts := !parts @ [ (slot, v) ]
                | _ -> incs := !incs @ count fi g ~dup:true)
            | _ -> incs := !incs @ count fi g ~dup:true
          else
            go c
              ~direct:(direct && match g.kind with View _ -> true | _ -> false))
      (find_group fi gid).children
  in
  go gid ~direct:true;
  (!incs, !parts, !took)

(* How a dying group's object is dropped, as a tree: [incs] counts again
   the descendants that are live but aren't kept below; [parts] are the
   live fields of its own object, by slot; and [nested] the fields that
   die with it whose own fields the program read, so their shape is
   known, each with its tree, to drop in turn (Koka's [specializeDrop],
   Parc.hs:356, which drops the children in the unique branch through
   [optimizeDupDrops] again, Parc.hs:359, so a pattern's inner nodes are
   specialized too). A field is nested only if no other variable of the
   same slot is used: that would hold the same object. *)
type dtree = {
  incs : stmt list;
  parts : (int * var) list;
  nested : (int * var * dtree) list;
  took : bool;
}

let rec dtree pl gid ~scope ~live ~transfer : dtree =
  let fi = pl.info in
  let incs = ref [] and parts = ref [] and nested = ref [] and took = ref false in
  let kids = (find_group fi gid).children in
  (* another field of the same slot, used: the same object *)
  let shared_slot c slot =
    List.exists
      (fun k ->
        k <> c
        && (match (find_group fi k).kind with
           | Part (_, s) -> s = slot
           | _ -> false)
        && live_through fi live k)
      kids
  in
  let known c =
    List.exists
      (fun k -> match (find_group fi k).kind with Part _ -> true | _ -> false)
      (find_group fi c).children
  in
  let rec go gid ~direct =
    List.iter
      (fun c ->
        let g = find_group fi c in
        if not g.snap then
          if Ids.mem c live then
            match g.kind with
            | View _ when transfer && direct && not !took -> took := true
            | Part (_, slot) when direct -> (
                match count_var g with
                | Some v when not (List.mem_assoc slot !parts) ->
                    parts := !parts @ [ (slot, v) ]
                | _ -> incs := !incs @ count fi g ~dup:true)
            | _ -> incs := !incs @ count fi g ~dup:true
          else
            match (g.kind, count_var g) with
            | Part (_, slot), Some v
              when direct && v.layout = Boxed
                   && Ids.mem v.id scope
                   && (not (shared_slot c slot))
                   && known c ->
                nested :=
                  !nested
                  @ [ (slot, v, dtree pl c ~scope ~live ~transfer:false) ]
            | _ ->
                go c
                  ~direct:
                    (direct && match g.kind with View _ -> true | _ -> false))
      (find_group fi gid).children
  in
  go gid ~direct:true;
  { incs = !incs; parts = !parts; nested = !nested; took = !took }

(* The counting a tree's descendants need if its object isn't unique:
   each live one counted again. *)
let rec shared_incs fi (t : dtree) =
  List.concat_map (fun (_, (v : var)) -> count fi (group fi v) ~dup:true) t.parts
  @ List.concat_map (fun (_, _, t) -> t.incs @ shared_incs fi t) t.nested

(* What drops the object of group [g], whose tree is [t], once [t.incs]
   are counted: if it's unique, it's freed keeping its live fields and
   its nested ones, which are dropped the same way in turn; if not, every
   live descendant is counted again and it's dropped. *)
let rec drop_tree pl (g : group) (t : dtree) : stmt list =
  let fi = pl.info in
  if t.took then shared_incs fi t
  else
    match (t.parts, t.nested, count_var g) with
    | [], [], _ -> count fi g ~dup:false
    (* a struct is always its own: it drops the slots not kept, and the
       nested ones are dropped the same way in turn *)
    | _, _, Some cv when is_struct cv.layout ->
        let kept =
          List.map (fun (n, v) -> (n, Var v)) t.parts
          @ List.map (fun (n, (v : var), _) -> (n, Var v)) t.nested
        in
        Free (Var cv, kept)
        :: List.concat_map
             (fun (_, (v : var), sub) ->
               sub.incs @ drop_tree pl (group fi v) sub)
             t.nested
    | _, _, Some cv when cv.layout = Boxed ->
        let u = fresh pl "$unique" Bool in
        let kept =
          List.map (fun (n, v) -> (n, Var v)) t.parts
          @ List.map (fun (n, (v : var), _) -> (n, Var v)) t.nested
        in
        [
          Let (u, Is_unique (Var cv));
          If
            ( Var u,
              Free (Var cv, kept)
              :: List.concat_map
                   (fun (_, (v : var), sub) ->
                     sub.incs @ drop_tree pl (group fi v) sub)
                   t.nested,
              shared_incs fi t @ count fi g ~dup:false );
        ]
    | _ -> shared_incs fi t @ count fi g ~dup:false

(* What drops each of [dying], whose descendants live in [live] are
   promoted first: one more reference to each, then the drops, a
   specialized one where it keeps parts of the object (Koka's
   [specializeDrop], Parc.hs:356), nested where a field dying with it
   has a known shape. *)
let kill pl ~scope (dying : int list) ~live : stmt list =
  let fi = pl.info in
  let incs, drops =
    List.fold_left
      (fun (incs, drops) gid ->
        let g = find_group fi gid in
        let t = dtree pl gid ~scope ~live ~transfer:true in
        (incs @ t.incs, drops @ drop_tree pl g t))
      ([], []) dying
  in
  incs @ drops

(* The groups in [held] that own a reference, aren't in [live], and so
   die here. *)
let dying ~held ~live ~owned =
  Ids.elements (Ids.filter (fun g -> owned g && not (Ids.mem g live)) held)

let rec place_block pl cx ?(entry = []) (b : block) (out : Ids.t) :
    block * Ids.t =
  let stmts, live =
    List.fold_right
      (fun (cx, s) (acc, l) ->
        (* nothing is alive after a statement that leaves the function,
           wherever its block is: a [Return] in a loop (trmc.ml) takes
           what the loop's next turn would have read *)
        let l =
          match s with Return _ | Raise (_, None) | Panic _ -> Ids.empty | _ -> l
        in
        let ss, before = place_stmt pl cx s l in
        (ss @ acc, before))
      (scoped cx b) ([], out)
  in
  (* a variable made where the block starts, an error, dropped there if
     the block never uses it *)
  let fi = pl.info in
  let entry = List.filter_map (fun v -> tracked_of fi (Var v)) entry in
  let dead = List.filter (fun g -> not (Ids.mem g live)) entry in
  let scope = Ids.union cx.defined (Ids.of_list entry) in
  (kill pl ~scope dead ~live @ stmts, Ids.diff live (Ids.of_list entry))

(* A branch's block, which first drops what's held before it ([held],
   whose owners [owned] says) but dead in it. *)
and branch pl cx ?(entry = []) ~held ~owned (b : block) (out : Ids.t) =
  let b, live = place_block pl cx ~entry b out in
  let dead = dying ~held ~live ~owned in
  (kill pl ~scope:cx.defined dead ~live @ b, live)

and place_stmt pl cx (s : stmt) (after : Ids.t) : stmt list * Ids.t =
  let fi = pl.info in
  let before = live_stmt cx s after in
  let o, b = operands fi s in
  let uses = ids_of fi (o @ b) in
  let owned_ids = List.filter_map (tracked_of fi) o in
  let borrowed_ids = List.filter_map (tracked_of fi) b in
  (* a use that takes a view straight from its slot: the store after it
     fills the slot again *)
  let taken gid = Hashtbl.mem pl.taken gid && List.mem gid owned_ids in
  (* what [s] changes holds another value after it: the one it held,
     which a part or a view may be borrowed from, isn't alive after *)
  let kept = Ids.diff after (Ids.of_list (defines fi s)) in
  let rec moved gid =
    taken gid
    || List.mem gid owned_ids
       && (not (Ids.mem gid after))
       && (not (List.mem gid borrowed_ids))
       && owns fi ~after:kept ~uses:before ~moved gid
  in
  (* a part or a view is borrowed from its parent while the parent is
     held, even where the two die together *)
  let owned_now gid = owns fi ~after:kept ~uses:before ~moved gid in
  (* one more reference for each use that takes one, but the first use
     of a group [s] takes, which takes the group's own *)
  let dups =
    let first = Hashtbl.create 4 in
    List.concat_map
      (fun x ->
        match counted_of fi x with
        | None -> []
        | Some g -> (
            match tracked_of fi x with
            | Some gid when moved gid && not (Hashtbl.mem first gid) ->
                Hashtbl.replace first gid ();
                []
            | _ -> count fi g ~dup:true))
      o
  in
  (* what a group [s] takes keeps alive must own its reference first *)
  let promotions =
    List.concat_map
      (fun gid ->
        if moved gid && not (taken gid) then
          let incs, parts, _ =
            promote pl gid ~live:(Ids.union after uses) ~transfer:false
          in
          incs
          @ List.concat_map
              (fun (_, (v : var)) -> count fi (group fi v) ~dup:true)
              parts
        else [])
      (List.sort_uniq compare owned_ids)
  in
  let pre = promotions @ dups in
  (* a snapshot of a slot or a cell owns a reference from where it's
     made *)
  let snapshot =
    match s with
    | Let (v, (Atom (Var x) | To_word (Var x) | Of_word (Var x, _)))
    | Let (v, Load x) -> (
        match Hashtbl.find_opt fi.group_of v.id with
        | Some ({ snap = true; kind = View _ | Cell_view _; _ } as g)
          when g.gid = v.id
               && (Ids.mem x.id fi.slots
                  || match g.kind with Cell_view _ -> true | _ -> false)
               && Ids.mem g.gid after ->
            count fi g ~dup:true
        | _ -> [])
    | _ -> []
  in
  (* a variable that changes, or whose address is taken, made from what
     the program only borrows, a field say, owns a reference of its own *)
  let borrowed_def =
    match s with
    | Let (v, (Field _ | Struct_get _ | Load _ | Global _ | Env_get _)) -> (
        match Hashtbl.find_opt fi.group_of v.id with
        | Some ({ kind = Owned; _ } as g) when g.gid = v.id -> Some g
        | _ -> None)
    | _ -> None
  in
  let snapshot =
    match borrowed_def with
    | Some g when Ids.mem g.gid after -> snapshot @ count fi g ~dup:true
    | _ -> snapshot
  in
  let held_after = Ids.union before (Ids.of_list (defines fi s)) in
  let is_snapshot_slot_unused gid =
    let g = find_group fi gid in
    (not (Ids.mem gid after))
    && List.mem gid (defines fi s)
    && (borrowed_def <> None
       || g.snap
          &&
          match g.kind with
          | Cell_view _ -> true
          | View p -> Ids.mem p fi.slots
          | _ -> false)
  in
  (* a statement with blocks drops in them what dies there, but a call,
     whose block is only where it fails; nothing runs after one that
     never goes on *)
  let compound =
    match s with
    | If _ | Switch _ | Loop _ | Joins _ | Catch _ -> true
    | s -> ends s
  in
  let after_kills =
    if compound then []
    else
      kill pl ~scope:(Ids.union cx.defined (made s))
        (List.filter
           (fun gid -> (not (moved gid)) && not (is_snapshot_slot_unused gid))
           (dying ~held:held_after ~live:after ~owned:owned_now))
        ~live:after
  in
  (* what a slot or a cell held before a store, dropped, unless a use took
     it *)
  let release =
    if List.memq s pl.untouched then []
    else
      match s with
      | Set (m, _) when Ids.mem m.id fi.slots -> (
          match Hashtbl.find_opt fi.group_of m.id with
          | Some g -> count fi g ~dup:false
          | None -> [])
      | Store (c, _) -> (
          match c.layout with
          | Cell l when counted l ->
              let old = fresh pl "$old" l in
              Let (old, Load c) :: count_var_layout fi old ~dup:false
          | _ -> [])
      | _ -> []
  in
  let held_before = before in
  let owned_before gid =
    owns fi ~after:before ~uses:Ids.empty ~moved:(fun _ -> false) gid
  in
  let br ?entry b out =
    fst (branch pl cx ?entry ~held:held_before ~owned:owned_before b out)
  in
  let on_err (error : var) on_error rest =
    let held =
      Ids.diff
        (Ids.union held_before Ids.empty)
        (Ids.of_list (List.filter moved (Ids.elements held_before)))
    in
    let owned = owned_now in
    fst (branch pl cx ~entry:[ error ] ~held ~owned on_error rest)
  in
  let s' =
    match s with
    | If (c, t, e) -> If (c, br t after, br e after)
    | Switch (x, cases, d) ->
        Switch (x, List.map (fun (t, b) -> (t, br b after)) cases, br d after)
    | Loop (l, body) ->
        let cx' = { cx with breaks = (l, after) :: cx.breaks } in
        Loop (l, fst (place_block pl cx' body before))
    | Joins (d, js) ->
        let placed =
          List.map (fun (l, j) -> (l, place_block pl cx j after)) js
        in
        let cx' =
          {
            cx with
            jumps = List.map (fun (l, (_, live)) -> (l, live)) placed @ cx.jumps;
          }
        in
        Joins
          ( fst (place_block pl cx' d after),
            List.map (fun (l, (j, _)) -> (l, j)) placed )
    | Catch ({ label; body; error; handler } as c) ->
        let h, hlive = place_block pl cx ~entry:[ error ] handler after in
        let cx' = { cx with raises = (label, hlive) :: cx.raises } in
        Catch { c with body = fst (place_block pl cx' body after); handler = h }
    | Call_fails ({ result; error; on_error; _ } as c) ->
        Call_fails
          {
            c with
            on_error = on_err error on_error (Ids.remove result.id after);
          }
    | Call_block ({ result; error; on_error; _ } as c) ->
        Call_block
          {
            c with
            on_error =
              Option.map
                (fun b -> on_err error b (Ids.remove result.id after))
                on_error;
          }
    | Call_handler ({ result; error; on_error; _ } as c) ->
        Call_handler
          {
            c with
            on_error =
              Option.map
                (fun b -> on_err error b (Ids.remove result.id after))
                on_error;
          }
    | s -> s
  in
  (pre @ release @ [ s' ] @ snapshot @ after_kills, before)

(* The uses that take a view straight from its slot: a view read once, by
   a statement that takes it and can't run the program's code, followed
   in its block by a store into the same slot, with nothing between that
   reads the slot or calls anything. Taking it leaves the object's count
   as it was, 1 if nothing else holds it, so an array changed through an
   `&` parameter, or a local a block captures, changes in place. *)
let find_takes fi (body : block) =
  let taken = Hashtbl.create 8 and untouched = ref [] in
  let mentions (slot : [ `Var of int | `Cell of int ]) (s : stmt) =
    List.exists
      (fun (v : var) ->
        match slot with `Var m -> v.id = m | `Cell c -> v.id = c)
      (atom_vars (stmt_atoms s))
  in
  let quiet slot (s : stmt) =
    (not (mentions slot s))
    &&
    match s with
    | Let (_, r) -> (
        match r with
        | Atom _ | Arith _ | Late _ | Neg _ | Compare _ | Not _ | Tag_of _ | Field _
        | Alloc _ | Alloc_array _ | To_word _ | Of_word _ | Global _
        | Is_unique _ ->
            true
        | Load _ -> true
        | Runtime (rt, _, _) -> (
            match rt with
            | Array_push _ | Array_push_taking _ -> false
            | _ -> true)
        | _ -> false)
    | Assert _ -> true
    | _ -> false
  in
  let fills slot (s : stmt) =
    match (slot, s) with
    | `Var m, Set (v, _) -> v.id = m
    | `Cell c, Store (v, _) -> v.id = c
    | _ -> false
  in
  let takes_view (s : stmt) =
    match s with
    | Let (_, (Runtime _ | Alloc _ | Alloc_array _)) ->
        let o, _ = operands fi s in
        List.filter_map
          (fun x ->
            match x with
            | Var v -> (
                match Hashtbl.find_opt fi.group_of v.id with
                | Some g when (not g.snap) && g.uses = 1 -> (
                    match g.kind with
                    | View p when Ids.mem p fi.slots -> Some (g, `Var p)
                    | Cell_view c -> Some (g, `Cell c.id)
                    | _ -> None)
                | _ -> None)
            | _ -> None)
          o
    | _ -> []
  in
  let rec block (b : block) =
    let rec go = function
      | [] -> ()
      | s :: rest ->
          List.iter
            (fun (g, slot) ->
              let rec scan = function
                | [] -> ()
                | w :: _ when fills slot w ->
                    Hashtbl.replace taken g.gid ();
                    untouched := w :: !untouched
                | w :: more -> if quiet slot w then scan more
              in
              scan rest)
            (takes_view s);
          List.iter block (blocks s);
          go rest
    in
    go b
  in
  block body;
  (taken, !untouched)

let place_fn fns (f : fn) : fn =
  let fi = analyze fns f in
  let next, _ = fresh_counters f in
  let slots_in_params =
    List.fold_left
      (fun acc (v : var) ->
        match Hashtbl.find_opt fi.group_of v.id with
        | Some g
          when owner g
               && (Ids.mem v.id fi.slots
                  || List.exists (fun (_, (d : var)) -> d.id = v.id) f.words) ->
            Ids.add g.gid acc
        | _ -> acc)
      Ids.empty f.params
  in
  let cx =
    {
      fi;
      always = slots_in_params;
      defined = Ids.of_list (List.map (fun (v : var) -> v.id) f.params);
      breaks = [];
      jumps = [];
      raises = [];
    }
  in
  (* liveness once first, which finds every snapshot *)
  ignore (live_block cx f.body Ids.empty);
  let taken, untouched = find_takes fi f.body in
  let pl = { info = fi; next; taken; untouched } in
  let body, live = place_block pl cx f.body Ids.empty in
  (* an owned parameter the body never uses is dropped where it starts *)
  let params =
    List.filter_map
      (fun (v : var) ->
        match Hashtbl.find_opt fi.group_of v.id with
        | Some g
          when tracked g && owner g && g.gid = v.id && not (Ids.mem g.gid live)
          ->
            Some g.gid
        | _ -> None)
      f.params
  in
  { f with body = kill pl ~scope:cx.defined params ~live @ body }

(* The program with its counting placed by Perceus: [prepare]d, and its
   parameters' modes decided by borrow.ml. *)
let program (p : program) : program =
  let fns = Hashtbl.create 64 in
  List.iter (fun (f : fn) -> Hashtbl.replace fns f.name f) p.fns;
  { p with fns = List.map (place_fn fns) p.fns }
