(* Unification: make two types equal by solving their variables, or fail.

   It raises a bare exception rather than a diagnostic, because only the
   caller knows what the two types mean ("the argument", "the `then`
   branch") and so how to explain the failure.

   [st] is the compilation's inference state (types.ml), which supplies
   ids for the row variables [rewrite] creates. *)

open Types

exception Mismatch

exception Infinite
(** a variable would have to contain itself *)

exception Two_shapes of string
(** two labels of one name, whose payloads differ: one error set would hold two
    shapes of the tag (module-build.md, "Error tags have no home") *)

(* Before binding variable [id] to [t]: fail if [t] contains the variable,
   and lower the levels inside [t] to [level] (see types.ml). *)
let rec occurs id level t =
  match repr t with
  | TVar ({ contents = Unbound (id', l) } as r) ->
      if id = id' then raise Infinite;
      if l > level then r := Unbound (id', level)
  | TVar { contents = Link _ } -> assert false
  | TSkol _ | TError -> ()
  | TCon (_, args) -> List.iter (occurs id level) args
  | TErrors e | TUses e -> occurs_row ~ty:id (-1) level e
  | TFun (ps, r, e, u) ->
      List.iter (occurs id level) (r :: param_tys ps);
      occurs_row ~ty:id (-1) level e;
      occurs_row ~ty:id (-1) level u

(* The same for row variables. Type and row ids never clash, so passing -1
   as [id] just adjusts levels. A label's payload is made of types, which
   are looked through for the type variable [ty], if there is one. *)
and occurs_row ?(ty = -1) id level r =
  match repr_row r with
  | RVar ({ contents = RUnbound (id', l) } as cell) ->
      if id = id' then raise Infinite;
      if l > level then cell := RUnbound (id', level)
  | RVar { contents = RLink _ } -> assert false
  | REmpty | RSkol _ -> ()
  | RExtend (label, rest) ->
      List.iter (occurs ty level) label.payload;
      occurs_row ~ty id level rest

let rec unify st a b =
  match (repr a, repr b) with
  | TVar r1, TVar r2 when r1 == r2 -> ()
  | TVar ({ contents = Unbound (id, l) } as r), t
  | t, TVar ({ contents = Unbound (id, l) } as r) ->
      occurs id l t;
      r := Link t
  (* code with an error, already reported, fits anywhere; a variable unified
     with it becomes an error too, so the mistake isn't reported again *)
  | TError, _ | _, TError -> ()
  | TCon (n1, a1), TCon (n2, a2) when n1 = n2 && List.length a1 = List.length a2
    ->
      List.iter2 (unify st) a1 a2
  (* in its own module, an opaque type is what it's represented as *)
  | (TCon (p, _) as t), u when Hashtbl.mem st.reps p -> unify st (reveal st t) u
  | t, (TCon (p, _) as u) when Hashtbl.mem st.reps p -> unify st t (reveal st u)
  | TFun (p1, r1, e1, u1), TFun (p2, r2, e2, u2)
    when List.length p1 = List.length p2 ->
      List.iter2
        (fun a b ->
          (* `fn(inout Int)` and `fn(Int)` are different types *)
          if a.mode <> b.mode then raise Mismatch;
          unify st a.ty b.ty)
        p1 p2;
      unify st r1 r2;
      unify_row st e1 e2;
      unify_row st u1 u2
  | TErrors e1, TErrors e2 | TUses e1, TUses e2 -> unify_row st e1 e2
  | TSkol (i, _), TSkol (j, _) when i = j -> ()
  | _ -> raise Mismatch

(* Rows are equal when they have the same labels, in any order. To unify
   `<l | rest1>` with a row, rewrite that row so it starts with `l`, then
   unify what remains. An open tail can always grow to supply a missing
   label; a closed row can't. A row can hold a label twice, which means
   what holding it once does (Infer_rows.join_uses), so once `l` is
   matched, what remains of either row has it no more. *)
and unify_row st a b =
  match (repr_row a, repr_row b) with
  | REmpty, REmpty -> ()
  | RVar c1, RVar c2 when c1 == c2 -> ()
  | RSkol (i, _), RSkol (j, _) when i = j -> ()
  | RVar ({ contents = RUnbound (id, l) } as cell), r
  | r, RVar ({ contents = RUnbound (id, l) } as cell) ->
      occurs_row id l r;
      cell := RLink r
  | RExtend (label, rest1), r2 ->
      let tail1 = snd (row_parts rest1) in
      let rest2 = rewrite st r2 label in
      (* If supplying `label` bound rest1's own tail, the two rows share a
         tail but disagree on labels: `<Console | ρ>` and `<Clock | ρ>`. *)
      (match (tail1, snd (row_parts rest1)) with
      | Some before, after when after <> Some before -> raise Mismatch
      | _ -> ());
      unify_row st (strip st rest1 label) (strip st rest2 label)
  (* a named row has no labels inference can see, and gets none *)
  | RSkol _, RExtend _ -> unify_row st b a
  | (REmpty | RSkol _), (REmpty | RSkol _) | REmpty, RExtend _ -> raise Mismatch
  | RVar { contents = RLink _ }, _ | _, RVar { contents = RLink _ } ->
      assert false

(* [row] with [label] removed, extending an open tail if the label isn't
   there yet. A label of the same name has to have the same payload. *)
and rewrite st row (label : label) =
  match repr_row row with
  | REmpty | RSkol _ -> raise Mismatch
  | RExtend (l, rest) when l.name = label.name ->
      same_shape st l label;
      rest
  | RExtend (l, rest) -> RExtend (l, rewrite st rest label)
  | RVar ({ contents = RUnbound (_, level) } as cell) ->
      let rest = RVar (ref (RUnbound (fresh_id st, level))) in
      cell := RLink (RExtend (label, rest));
      rest
  | RVar { contents = RLink _ } -> assert false

(* [row] with no more of [label] among the labels it has now: a row that
   holds it twice, matched once. *)
and strip st row (label : label) =
  match repr_row row with
  | RExtend (l, rest) when l.name = label.name ->
      same_shape st l label;
      strip st rest label
  | RExtend (l, rest) -> RExtend (l, strip st rest label)
  | r -> r

(* Two labels of one name have the same payload, or it's two shapes of a
   tag. *)
and same_shape st (l : label) (label : label) =
  try
    if List.length l.payload <> List.length label.payload then raise Mismatch;
    List.iter2 (unify st) l.payload label.payload
  with Mismatch | Infinite -> raise (Two_shapes label.name)

(* ---- trying a unification first ----

   Unification changes types as it goes, so one that fails partway leaves
   them half changed: a variable bound, the next label refused. The
   constraint solver (solve.ml) never lets that happen. It tries a
   unification on copies of the types first, and does it for real only if
   that worked, so a failure changes nothing anything else sees. *)

(* A way to copy types: each variable still unbound gets a cell of its own,
   with the same id, so the copies are unified exactly as the originals
   would be, and print the same. A variable met twice gets the one copy,
   since the copies have to share what the originals share. *)
type copy = { ty : ty -> ty; row : row -> row }

let copier () =
  (* only looked up, by id, never walked, so their order never shows *)
  let tys = Hashtbl.create 16 and rows = Hashtbl.create 16 in
  let rec ty t =
    match repr t with
    | TVar { contents = Unbound (id, l) } -> (
        match Hashtbl.find_opt tys id with
        | Some c -> c
        | None ->
            let c = TVar (ref (Unbound (id, l))) in
            Hashtbl.replace tys id c;
            c)
    | TVar { contents = Link _ } -> assert false
    | TCon (p, args) -> TCon (p, List.map ty args)
    | TFun (ps, r, e, u) ->
        TFun
          ( List.map (fun (p : param) -> { p with ty = ty p.ty }) ps,
            ty r,
            row e,
            row u )
    | TErrors r -> TErrors (row r)
    | TUses r -> TUses (row r)
    | (TSkol _ | TError) as t -> t
  and row r =
    match repr_row r with
    | RVar { contents = RUnbound (id, l) } -> (
        match Hashtbl.find_opt rows id with
        | Some c -> c
        | None ->
            let c = RVar (ref (RUnbound (id, l))) in
            Hashtbl.replace rows id c;
            c)
    | RVar { contents = RLink _ } -> assert false
    | RExtend (l, rest) ->
        RExtend ({ l with payload = List.map ty l.payload }, row rest)
    | (REmpty | RSkol _) as r -> r
  in
  { ty; row }

(* The types themselves, for doing it for real. *)
let originals = { ty = Fun.id; row = Fun.id }

(* Run [f], which unifies what it's given through a [copy], first on the
   copies [c] makes, with a state of its own, so the new variables it
   makes don't count; and if that worked, again on the types themselves,
   which then can't fail. If it failed, it says how, and nothing but the
   copies changed: [c] gives them back, as far as it got, for a message.
   [{ st with level = st.level }] is a new record with the same fields,
   whose counters change without changing [st]'s. *)
let atomically st c f =
  match f { st with level = st.level } c with
  | () ->
      f st originals;
      Ok ()
  | exception ((Mismatch | Infinite | Two_shapes _) as failure) -> Error failure
