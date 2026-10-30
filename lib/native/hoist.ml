(* Hoisting an array out of a loop (compiler.md, "Native slice"): in a
   release build, a loop that changes an array in place, or only reads
   it, indexes the array's elements directly, its uniqueness made sure
   of once, before the loop, rather than at each write.

   After Perceus, a write to an array a loop holds is a view of its
   slot, taken by [Array_set_taking] and stored back: each one checks
   the index, checks the count is 1, copies if it isn't, and writes
   (lean.h's `lean_array_uset`). Where a loop makes no new reference to
   the array and gives it to nothing, the count can't change during the
   loop, so the check is made once, [Array_own] before it, and inside
   it the array's elements are a pointer and a length read before it,
   [Array_data] and [Array_len]: [Buf_get] and [Buf_set] check the
   index against the length and load or store.

   It's sound because nothing else can reach the array while the loop
   runs. Perceus says the count is the number of slots that hold the
   object, and a view of a slot isn't counted only while nothing changes
   the slot (rc.ml, [find_takes]); so after [Array_own] the slot is the
   only one, and the loop makes no other, since every use of the place
   in it is a view given straight to an index, a length or a write that
   is stored back. The exclusivity rule (foundations.md, decision 2) says
   no one else reaches the slot: an `&` parameter's cell aliases nothing
   the function can see, not another parameter, a capture or handler
   state, so the only accesses to it are the function's own [Load]s and
   [Store]s, all of them in view here. A local is the same unless its
   address is taken; then the loop may make no call, through which a
   block or a callee could reach it, and use no cell made from it. The
   length can't change: nothing in the loop pushes, and every write
   stores the same object back.

   That also makes the arrays' buffers apart from each other and from
   anything else the loop touches: each array changed is unique, so no
   other object, and no other array's buffer, is it, and an array only
   read is never one changed, which is unique. So emit_c.ml writes the
   loop as a function of its own, inlined, whose buffers are `restrict`
   parameters, what C needs to keep the elements in registers and
   vectorize; `--no-restrict` leaves the keyword out and nothing else.
   For that, a loop is hoisted only if control leaves it only by its end
   or its own `break`: no [Return], [Raise] or [Jump] out, and nothing
   on its frame's stack, an environment or evidence, that outlives it. *)

open Mem
module Ids = Set.Make (Int)

let vars_of (xs : atom list) =
  List.filter_map (function Var v -> Some v | _ -> None) xs

(* Every variable [s] mentions itself, not in its blocks: what it reads
   and what it defines or changes. *)
let mentions (s : stmt) : var list =
  let own =
    match s with
    | Let (v, _) | Decl v | Set (v, _) -> [ v ]
    | Call_fails { result; error; _ }
    | Call_block { result; error; _ }
    | Call_handler { result; error; _ } ->
        [ result; error ]
    | Catch { error; _ } -> [ error ]
    | _ -> []
  in
  own @ vars_of (Rc.stmt_atoms s)

(* The variables, labels of loops, joins and catches [b] defines. *)
let defined (b : block) =
  let vars = ref Ids.empty and labels = ref Ids.empty in
  Rc.iter_stmts
    (fun s ->
      (match s with
      | Let (v, _) | Decl v -> vars := Ids.add v.id !vars
      | Call_fails { result; error; _ }
      | Call_block { result; error; _ }
      | Call_handler { result; error; _ } ->
          vars := Ids.add result.id (Ids.add error.id !vars)
      | Catch { label; error; _ } ->
          vars := Ids.add error.id !vars;
          labels := Ids.add label !labels
      | Loop (l, _) -> labels := Ids.add l !labels
      | Joins (_, js) ->
          List.iter (fun (l, _) -> labels := Ids.add l !labels) js
      | _ -> ());
      ())
    b;
  (!vars, !labels)

(* Whether control leaves [Loop (l, b)] only by its end or a [Break] of
   a loop in it, and it puts nothing on the stack that would outlive a
   function it's moved to. *)
let outlinable l (b : block) =
  let _, labels = defined b in
  let labels = Ids.add l labels in
  let ok = ref true in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Return _ | Raise (_, None) | Call_handler _ -> ok := false
      | Raise (_, Some k) | Break k | Jump k ->
          if not (Ids.mem k labels) then ok := false
      | Let (_, (Env_new _ | Install _ | Impl _ | Given _)) -> ok := false
      | _ -> ())
    b;
  !ok

let calls (b : block) =
  let any = ref false in
  Rc.iter_stmts
    (function
      | Let (_, Call _) | Do (Call _) | Call_fails _ | Call_block _ ->
          any := true
      | _ -> ())
    b;
  !any

(* What the whole function says of its places. *)
type facts = {
  inout : Ids.t;  (** its `inout` parameters' cells *)
  passed : Ids.t;
      (** cells used other than by [Load], [Store] and as a call's argument *)
  addressed : Ids.t;  (** locals whose address is taken *)
  loaded : Ids.t;
      (** variables that are views of what a cell holds, not places of their own
      *)
  cells_of : (int, Ids.t) Hashtbl.t;  (** a local's id: the cells of it *)
}

let facts (f : fn) =
  let addressed = ref Ids.empty and passed = ref Ids.empty in
  let loaded = ref Ids.empty in
  let cells_of = Hashtbl.create 8 in
  let add_cell local c =
    let old =
      Option.value (Hashtbl.find_opt cells_of local) ~default:Ids.empty
    in
    Hashtbl.replace cells_of local (Ids.add c old)
  in
  let is_cell (v : var) = match v.layout with Cell _ -> true | _ -> false in
  Rc.iter_stmts
    (fun s ->
      (match s with
      | Let (c, Addr v) ->
          addressed := Ids.add v.id !addressed;
          add_cell v.id c.id
      | _ -> ());
      List.iter
        (fun (v : var) ->
          let fine =
            match s with
            | Let (_, Load c) -> c.id = v.id
            | Store (c, x) -> c.id = v.id && x <> Var v
            | Let (c, Addr _) -> c.id = v.id
            | Let (_, Call (_, xs))
            | Do (Call (_, xs))
            | Call_fails { args = xs; _ } ->
                List.mem (Var v) xs
            | _ -> false
          in
          if is_cell v && not fine then passed := Ids.add v.id !passed)
        (mentions s);
      match s with
      | Let (x, Load _) -> loaded := Ids.add x.id !loaded
      | Let (x, Atom (Var y)) when Ids.mem y.id !loaded ->
          loaded := Ids.add x.id !loaded
      | _ -> ())
    f.body;
  (* a cell copied is a cell of the same local *)
  Hashtbl.iter
    (fun local cs ->
      let cs = ref cs in
      Rc.iter_stmts
        (function
          | Let (c, Atom (Var d)) when Ids.mem d.id !cs ->
              cs := Ids.add c.id !cs
          | _ -> ())
        f.body;
      Hashtbl.replace cells_of local !cs)
    (Hashtbl.copy cells_of);
  {
    inout = Ids.of_list (List.map (fun (v : var) -> v.id) f.inout);
    passed = !passed;
    addressed = !addressed;
    loaded = !loaded;
    cells_of;
  }

(* A place a loop may hoist: a local, or an `inout` parameter's cell. *)
type place = {
  pvar : var;
  cell : bool;
  mutable views : Ids.t;  (** the loop's views of it *)
  mutable sets : Ids.t;  (** the writes' results, stored back into it *)
  mutable elem : layout option;  (** its elements', from what reads them *)
  mutable ok : bool;
  mutable buf : var option;
  mutable len : var option;
}

let elem_of (rt : rt) =
  match rt with
  | Array_get l | Array_take l | Array_set_taking l -> Some l
  | Array_set_field_taking (n, _, _) -> Some (Struct (n, false))
  | _ -> None

(* The places [Loop (l, b)] can hoist, each with its views and writes;
   [] if none. *)
let places facts (b : block) =
  let inside, _ = defined b in
  let has_calls = calls b in
  let tbl : (int, place) Hashtbl.t = Hashtbl.create 8 in
  let view_of = Hashtbl.create 16 and set_of = Hashtbl.create 8 in
  let place (v : var) cell =
    match Hashtbl.find_opt tbl v.id with
    | Some p -> p
    | None ->
        let p =
          {
            pvar = v;
            cell;
            views = Ids.empty;
            sets = Ids.empty;
            elem = None;
            ok = true;
            buf = None;
            len = None;
          }
        in
        Hashtbl.replace tbl v.id p;
        p
  in
  (* the views and the writes, in order *)
  Rc.iter_stmts
    (fun s ->
      match s with
      | Let (x, Atom (Var p)) when p.layout = Boxed && not (Ids.mem p.id inside)
        ->
          let pl = place p false in
          pl.views <- Ids.add x.id pl.views;
          Hashtbl.replace view_of x.id pl
      | Let (x, Load c) when c.layout = Cell Boxed && not (Ids.mem c.id inside)
        ->
          let pl = place c true in
          pl.views <- Ids.add x.id pl.views;
          Hashtbl.replace view_of x.id pl
      | Let
          ( r,
            Runtime
              ((Array_set_taking _ | Array_set_field_taking _), Var x :: _, _)
          ) -> (
          match Hashtbl.find_opt view_of x.id with
          | Some pl ->
              pl.sets <- Ids.add r.id pl.sets;
              Hashtbl.replace set_of r.id pl
          | None -> ())
      | _ -> ())
    b;
  let bad (pl : place) = pl.ok <- false in
  let agree (pl : place) l =
    match (pl.elem, l) with
    | _, (Word _ | Cell _ | Ev | Block | Ptr | Token) -> bad pl
    | None, l -> pl.elem <- Some l
    (* a field's write says only which struct, not whether it's counted *)
    | Some (Struct (n, _)), Struct (n', _) -> if n <> n' then bad pl
    | Some l', l -> if l <> l' then bad pl
  in
  (* each mention of a place, a view or a write's result must be one of
     those the loop is rewritten around *)
  Rc.iter_stmts
    (fun s ->
      let allowed =
        match s with
        | Let (_, (Atom (Var _) | Load _)) -> (
            match s with
            | Let (x, _) when Hashtbl.mem view_of x.id -> true
            | _ -> false)
        | Let (_, Runtime (rt, Var x :: rest, _))
        | Do (Runtime (rt, Var x :: rest, _)) -> (
            match Hashtbl.find_opt view_of x.id with
            | None -> false
            | Some pl -> (
                let others = vars_of rest in
                if
                  List.exists
                    (fun (v : var) ->
                      Hashtbl.mem view_of v.id || Hashtbl.mem tbl v.id
                      || Hashtbl.mem set_of v.id)
                    others
                then false
                else
                  match rt with
                  | Array_len -> true
                  | Array_check -> true
                  | Array_get _ | Array_take _ | Array_set_taking _
                  | Array_set_field_taking _ ->
                      Option.iter (agree pl) (elem_of rt);
                      true
                  | _ -> false))
        | Set (p, Var r) | Store (p, Var r) -> (
            match Hashtbl.find_opt set_of r.id with
            | Some pl -> pl.pvar.id = p.id
            | None -> false)
        | _ -> false
      in
      if not allowed then
        List.iter
          (fun (v : var) ->
            match Hashtbl.find_opt tbl v.id with
            | Some pl -> bad pl
            | None -> (
                match Hashtbl.find_opt view_of v.id with
                | Some pl -> bad pl
                | None -> (
                    match Hashtbl.find_opt set_of v.id with
                    | Some pl -> bad pl
                    | None -> ())))
          (mentions s)
      else
        (* a write's result used anywhere but where it's stored *)
        match s with
        | Set _ | Store _ -> ()
        | _ ->
            List.iter
              (fun (v : var) ->
                match Hashtbl.find_opt set_of v.id with
                | Some pl -> (
                    match s with
                    | Let (r, _) when r.id = v.id -> ()
                    | _ -> bad pl)
                | None -> ())
              (mentions s))
    b;
  (* what the rest of the function does with each place *)
  Hashtbl.iter
    (fun _ (pl : place) ->
      let id = pl.pvar.id in
      if pl.cell then (
        if (not (Ids.mem id facts.inout)) || Ids.mem id facts.passed then bad pl)
      else if Ids.mem id facts.loaded then bad pl
      else if Ids.mem id facts.addressed then (
        if has_calls then bad pl;
        let cells =
          Option.value (Hashtbl.find_opt facts.cells_of id) ~default:Ids.empty
        in
        Rc.iter_stmts
          (fun s ->
            if List.exists (fun (v : var) -> Ids.mem v.id cells) (mentions s)
            then bad pl)
          b))
    tbl;
  (* a place no element of which is read or written may not be an array
     at all: a `Str` or a record a view was made of and left unused *)
  Hashtbl.fold
    (fun _ pl acc -> if pl.ok && pl.elem <> None then pl :: acc else acc)
    tbl []
  |> List.sort (fun a b -> compare a.pvar.id b.pvar.id)

(* [b] with each hoisted place's views, writes and stores turned into
   its buffer's. *)
let rec rewrite (pls : place list) (b : block) : block =
  let view x = List.find_opt (fun pl -> Ids.mem x pl.views) pls in
  let set r = List.exists (fun pl -> Ids.mem r pl.sets) pls in
  let buf pl = Var (Option.get pl.buf) and len pl = Var (Option.get pl.len) in
  List.concat_map
    (fun s ->
      match s with
      | Let (x, (Atom (Var _) | Load _)) when view x.id <> None -> []
      | (Set (_, Var r) | Store (_, Var r)) when set r.id -> []
      | (Let (_, Runtime (_, Var x :: _, _)) | Do (Runtime (_, Var x :: _, _)))
        when view x.id <> None -> (
          let pl = Option.get (view x.id) in
          let v, rt, rest, site =
            match s with
            | Let (v, Runtime (rt, _ :: rest, site)) -> (Some v, rt, rest, site)
            | Do (Runtime (rt, _ :: rest, site)) -> (None, rt, rest, site)
            | _ -> assert false
          in
          let let_ r = match v with Some v -> Let (v, r) | None -> Do r in
          match rt with
          | Array_len -> (
              match v with Some v -> [ Let (v, Atom (len pl)) ] | None -> [])
          | Array_check -> [ let_ (Runtime (Buf_check, len pl :: rest, site)) ]
          | Array_get l ->
              [ let_ (Runtime (Buf_get l, buf pl :: len pl :: rest, site)) ]
          (* the array is unique now, so the element is moved out; its
             write back is the [Buf_set] it pairs with (swap.ml) *)
          | Array_take l ->
              [ let_ (Runtime (Buf_take l, buf pl :: len pl :: rest, site)) ]
          | Array_set_taking l ->
              [ Do (Runtime (Buf_set l, buf pl :: len pl :: rest, site)) ]
          | Array_set_field_taking (n, k, l) ->
              [
                Do
                  (Runtime
                     (Buf_set_field (n, k, l), buf pl :: len pl :: rest, site));
              ]
          | _ -> [ s ])
      | s -> [ Rc.map_blocks (rewrite pls) s ])
    b

(* The statements before a loop that hoist [pl]: its length, then its
   array made unique if the loop changes it, then its buffer. The length
   is read first, from the array as it was, which a copy keeps, so C can
   see it's the length a loop's bound was read from before. *)
let before fresh (pl : place) =
  let view () =
    let x = fresh pl.pvar.name Boxed in
    (x, if pl.cell then Let (x, Load pl.pvar) else Let (x, Atom (Var pl.pvar)))
  in
  let x, lx = view () in
  let len = fresh "$len" Int in
  let read_len = [ lx; Let (len, Runtime (Array_len, [ Var x ], None)) ] in
  let own =
    if Ids.is_empty pl.sets then []
    else
      let u = fresh "$own" Boxed in
      [
        Let (u, Runtime (Array_own, [ Var x ], None));
        (if pl.cell then Store (pl.pvar, Var u) else Set (pl.pvar, Var u));
      ]
  in
  let y, ly = view () in
  let buf = fresh "$buf" Ptr in
  pl.buf <- Some buf;
  pl.len <- Some len;
  read_len @ own @ [ ly; Let (buf, Runtime (Array_data, [ Var y ], None)) ]

let fn (f : fn) =
  let facts = facts f in
  let next, _ = Rc.fresh_counters f in
  let fresh name layout =
    let id = !next in
    incr next;
    { id; name; layout }
  in
  let rec block (b : block) : block =
    List.concat_map
      (fun s ->
        match s with
        | Loop (l, body) -> (
            match if outlinable l body then places facts body else [] with
            | [] -> [ Loop (l, block body) ]
            | pls ->
                let pre = List.concat_map (before fresh) pls in
                pre @ [ Loop (l, rewrite pls body) ])
        | s -> [ Rc.map_blocks block s ])
      b
  in
  { f with body = block f.body }

(* ---- the bytes a loop reads ----

   A `Str`'s or `Bytes`' length and where its bytes are don't change
   while two references hold it (ren_rt.h, [ren_str]), but C can't know
   that: a loop that
   reads a byte, [Bytes_at], and also calls a function or stores
   anything reads both from the object again before every byte, since
   the call or the store might have changed them as far as C knows. Rust
   keeps a slice's pointer and length in registers instead (compiler.md,
   "Bytes stage", "The baseline"). So each `Bytes` a loop reads a byte of
   has its length and its bytes read once, before the loop, [Str_len]
   and [Str_data], and in the loop [Bytes_get] checks the index against
   that length and loads.

   It's sound because the loop reads the same object all through, and
   that object is alive: the variable is a parameter or a [Let], which
   nothing in the function [Set]s, so it holds one object from before
   the loop to after it (nor takes the address of, [Addr], which a write
   through `&` puts another object in: a layer 3 write that copies the
   bytes, since they were shared); it's used in the loop, so the reference it
   holds (or, borrowed, its caller's) is alive across it, or the loop's
   own reads would be of freed memory; and nothing writes a string's
   header while more than one reference holds it: a `+=` that appends in
   place ([Str_concat_taking]) takes the only one, and the variable alive
   across the loop holds one, so it copies instead. A copy made in the loop, `let y = x`, never
   [Set] either, is the same object, and read through as [x] is. A
   [Decl]ed variable, which is [Set] later, is never one. *)

let bytes ?sv (f : fn) =
  (* a string: an object, or a release build's two words (representation
     B), whose length and bytes are its range's and its root's, which no
     more change while it's held than an object's do *)
  let stringy (l : layout) =
    l = Boxed || match (l, sv) with Struct (n, _), Some m -> n = m | _ -> false
  in
  let set = ref Ids.empty and lets = ref Ids.empty in
  let copy_of = Hashtbl.create 16 in
  List.iter (fun (v : var) -> lets := Ids.add v.id !lets) f.params;
  Rc.iter_stmts
    (function
      | Set (v, _) | Decl v -> set := Ids.add v.id !set
      (* a variable whose address is taken may be given another object
         through it: a layer 3 write that copies the bytes, or a call
         given it with `&` *)
      | Let (_, Addr v) -> set := Ids.add v.id !set
      | Let (v, r) ->
          lets := Ids.add v.id !lets;
          (match r with
          | Atom (Var w) when stringy v.layout -> Hashtbl.replace copy_of v.id w
          | _ -> ())
      | _ -> ())
    f.body;
  let steady (v : var) =
    stringy v.layout && Ids.mem v.id !lets && not (Ids.mem v.id !set)
  in
  (* the variable [x] is a copy of, through copies, that holds the same
     object all along *)
  let rec root (x : var) =
    match Hashtbl.find_opt copy_of x.id with
    | Some w when steady x && steady w -> root w
    | _ -> x
  in
  let next, _ = Rc.fresh_counters f in
  let fresh name layout =
    let id = !next in
    incr next;
    { id; name; layout }
  in
  let read (s : stmt) =
    match s with
    | Let (_, Runtime (Bytes_at, Var x :: _, _))
    | Do (Runtime (Bytes_at, Var x :: _, _)) ->
        Some (root x)
    | _ -> None
  in
  (* [b] with each byte read of one of [views] read from its buffer *)
  let rec rewrite views (b : block) : block =
    List.map
      (fun s ->
        let get site i (_, len, data) =
          Runtime (Bytes_get, [ Var data; Var len; i ], site)
        in
        let view x = List.find_opt (fun ((r : var), _, _) -> r.id = (root x).id) views in
        match s with
        | Let (v, Runtime (Bytes_at, [ Var x; i ], site)) when view x <> None ->
            Let (v, get site i (Option.get (view x)))
        | Do (Runtime (Bytes_at, [ Var x; i ], site)) when view x <> None ->
            Do (get site i (Option.get (view x)))
        | s -> Rc.map_blocks (rewrite views) s)
      b
  in
  let rec block (b : block) : block =
    List.concat_map
      (fun s ->
        match s with
        | Loop (l, body) -> (
            let inside, _ = defined body in
            let roots = ref [] in
            Rc.iter_stmts
              (fun s ->
                match read s with
                | Some r
                  when steady r
                       && (not (Ids.mem r.id inside))
                       && not (List.exists (fun (v : var) -> v.id = r.id) !roots) ->
                    roots := r :: !roots
                | _ -> ())
              body;
            match List.rev !roots with
            | [] -> [ Loop (l, block body) ]
            | roots ->
                let views =
                  List.map (fun r -> (r, fresh "$blen" Int, fresh "$bytes" Ptr)) roots
                in
                List.concat_map
                  (fun (r, len, data) ->
                    [
                      Let (len, Runtime (Str_len, [ Var r ], None));
                      Let (data, Runtime (Str_data, [ Var r ], None));
                    ])
                  views
                @ [ Loop (l, block (rewrite views body)) ])
        | s -> [ Rc.map_blocks block s ])
      b
  in
  { f with body = block f.body }

let program (p : program) =
  { p with fns = List.map (fun f -> bytes ?sv:p.sv (fn f)) p.fns }
