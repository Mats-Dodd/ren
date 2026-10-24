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

(* Before binding variable [id] to [t]: fail if [t] contains the variable,
   and lower the levels inside [t] to [level] (see types.ml). *)
let rec occurs id level t =
  match repr t with
  | TVar ({ contents = Unbound (id', l) } as r) ->
      if id = id' then raise Infinite;
      if l > level then r := Unbound (id', level)
  | TVar { contents = Link _ } -> assert false
  | TSkol _ -> ()
  | TCon (_, args) -> List.iter (occurs id level) args
  | TFun (ps, r, e, u) ->
      List.iter (occurs id level) (r :: param_tys ps);
      occurs_row (-1) level e;
      occurs_row (-1) level u

(* The same for row variables. Type and row ids never clash, so passing -1
   as [id] just adjusts levels. *)
and occurs_row id level r =
  match repr_row r with
  | RVar ({ contents = RUnbound (id', l) } as cell) ->
      if id = id' then raise Infinite;
      if l > level then cell := RUnbound (id', level)
  | RVar { contents = RLink _ } -> assert false
  | REmpty -> ()
  | RExtend (_, rest) -> occurs_row id level rest

let rec unify st a b =
  match (repr a, repr b) with
  | TVar r1, TVar r2 when r1 == r2 -> ()
  | TVar ({ contents = Unbound (id, l) } as r), t
  | t, TVar ({ contents = Unbound (id, l) } as r) ->
      occurs id l t;
      r := Link t
  | TCon (n1, a1), TCon (n2, a2) when n1 = n2 && List.length a1 = List.length a2
    ->
      List.iter2 (unify st) a1 a2
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
  | TSkol (i, _), TSkol (j, _) when i = j -> ()
  | _ -> raise Mismatch

(* Rows are equal when they have the same labels, in any order. To unify
   `<l | rest1>` with a row, rewrite that row so it starts with `l`, then
   unify what remains. An open tail can always grow to supply a missing
   label; a closed row can't. *)
and unify_row st a b =
  match (repr_row a, repr_row b) with
  | REmpty, REmpty -> ()
  | RVar c1, RVar c2 when c1 == c2 -> ()
  | RVar ({ contents = RUnbound (id, l) } as cell), r
  | r, RVar ({ contents = RUnbound (id, l) } as cell) ->
      occurs_row id l r;
      cell := RLink r
  | RExtend (label, rest1), r2 ->
      let tail1 = snd (row_parts rest1) in
      let rest2 = rewrite st r2 label in
      (* If supplying `label` bound rest1's own tail, the two rows share a
         tail but disagree on labels: `<Io | ρ>` and `<Clock | ρ>`. *)
      (match (tail1, snd (row_parts rest1)) with
      | Some before, after when after <> Some before -> raise Mismatch
      | _ -> ());
      unify_row st rest1 rest2
  | REmpty, RExtend _ -> raise Mismatch
  | RVar { contents = RLink _ }, _ | _, RVar { contents = RLink _ } ->
      assert false

(* [row] with [label] removed, extending an open tail if the label isn't
   there yet. *)
and rewrite st row label =
  match repr_row row with
  | REmpty -> raise Mismatch
  | RExtend (l, rest) when l = label -> rest
  | RExtend (l, rest) -> RExtend (l, rewrite st rest label)
  | RVar ({ contents = RUnbound (_, level) } as cell) ->
      let rest = RVar (ref (RUnbound (fresh_id st, level))) in
      cell := RLink (RExtend (label, rest));
      rest
  | RVar { contents = RLink _ } -> assert false
