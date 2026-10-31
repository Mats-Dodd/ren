(* Until generator frames lower natively, their execution is refused by
   to_mem.ml. The ownership registries around ordinary polymorphic code
   can then be erased: there are no native generator frames to close.
   This runs only before Mem lowering, never before interpretation. *)
module C = Core

let rec cursor_type (t : Ty.ty) =
  match t with
  | Con (p, ts) | Variant (p, _, ts) ->
      Ty.is_generator_cursor p || List.exists cursor_type ts
  | Fun _ | Errors _ | Impl _ | Var _ | Error -> false

let rec erase_owners (e : C.expr) : C.expr =
  let r = erase_owners in
  let arg = function C.Value x -> C.Value (r x) | Ref v -> Ref v in
  let captures = List.filter (fun (v : C.var) -> v.ty <> C.owner_ty) in
  match e.kind with
  | Source_view { value; _ } -> r value
  | Pattern_scope p ->
      let first : C.arm = { pat = p.pat; guard = None; body = r p.on_match } in
      let rest = match p.on_else with
        | None -> []
        | Some body ->
            [ { C.pat = { pkind = PWild; pty = p.source.ty; ploc = p.source.loc };
                guard = None; body = r body } ]
      in
      { e with kind = (match p.binding with
          | Some v -> Let (v, r p.source, r p.on_match)
          | None -> Match (r p.source, first :: rest)) }
  | Cleanup_scope { body; _ } | Instance_scope { body; _ }
  | Owner_alias { body; _ } -> r body
  | Own { value; _ } -> r value
  | Owned_assign { target; value; _ } ->
      { e with kind = Assign (target, r value) }
  | _ ->
      let kind : C.kind =
        match e.kind with
        | Return (p, x) -> Return (p, r x)
        | Gen_create g ->
            Gen_create { g with args = List.map arg g.args;
              places = List.map (fun (p : C.gen_place) ->
                { p with read = r p.read; write = r p.write }) g.places }
        | Yield x -> Yield (r x)
        | Yield_from y -> Yield_from { y with pull = r y.pull }
        | Gen_close x -> Gen_close (r x)
        | (Const _ | Function_uses _ | Frozen_default _ | Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Global _
          | Global_value _ | Intrinsic _ | Break | Gen_step _) as k -> k
        | Dep_call d -> Dep_call { d with args = List.map r d.args }
        | With w -> With { w with impl = r w.impl; body = r w.body }
        | Handler h ->
            Handler { h with captures = captures h.captures; body = r h.body }
        | Instance i ->
            Instance
              { i with impls = List.map (fun (d, x) -> (d, r x)) i.impls;
                finally = Option.map r i.finally }
        | Narrowed (ds, x) -> Narrowed (ds, r x)
        | With_handler w ->
            With_handler { w with handler = r w.handler; body = r w.body }
        | Prim (p, xs) -> Prim (p, List.map r xs)
        | Let (v, x, body) -> Let (v, r x, r body)
        | Covered c -> Covered { c with body = r c.body; after = r c.after }
        | Assign (v, x) -> Assign (v, r x)
        | If (c, t, f) -> If (r c, r t, r f)
        | Match (x, arms) ->
            Match (r x, List.map
              (fun (a : C.arm) ->
                { a with guard = Option.map r a.guard; body = r a.body }) arms)
        | While (c, body) -> While (r c, r body)
        | Seq (a, b) -> Seq (r a, r b)
        | Call (f, args, ev) -> Call (r f, List.map arg args, ev)
        | Lambda l ->
            Lambda { l with captures = captures l.captures; body = r l.body }
        | Con (p, c, xs) -> Con (p, c, List.map r xs)
        | Record (p, fields) ->
            Record (p, List.map (fun (n, x) -> (n, r x)) fields)
        | Field (x, p, n) -> Field (r x, p, n)
        | Of_variant x -> Of_variant (r x)
        | Update (x, n, y) -> Update (r x, n, r y)
        | Array xs -> Array (List.map r xs)
        | Tuple xs -> Tuple (List.map r xs)
        | Tag (t, xs, ds) -> Tag (t, List.map r xs, ds)
        | Fail x -> Fail (r x)
        | Handle h ->
            Handle { h with body = r h.body; on_value = r h.on_value;
                            on_error = r h.on_error }
        | Assert x -> Assert (r x)
        | Assert_equal (a, b, d, dc) -> Assert_equal (r a, r b, d, dc)
        | Finally (a, b) -> Finally (r a, r b)
        | Cleanup_scope _ | Instance_scope _ | Own _ | Owned_assign _
        | Owner_alias _ | Source_view _ | Pattern_scope _ -> assert false
      in
      { e with kind }

let program (modules : C.program list) =
  List.map
    (fun (m : C.program) ->
      { m with fns = List.map
          (fun (f : C.fn_def) -> { f with body = erase_owners f.body }) m.fns })
    modules
