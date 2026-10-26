(* Values, as `show`, `print`, a failed `assert` and an error nothing
   handled show them.

   A value is shown as it's written, with the names of the types it's
   made of: a record after its type's name, `Account { id: AccountId(1)
   }`, and an opaque value as its type's name around what it is,
   `Money(-100)`, unless its type has a `show` method of its own, `Path`'s,
   which is used instead. At runtime an opaque value is only what it's
   represented as, so a value is shown through its type, and each type's
   declaration, by its path. *)

(* Every type's declaration, by its path. *)
type types = (Path.t, Iface.type_decl) Hashtbl.t

let types (decls : Iface.type_decl list) : types =
  let t = Hashtbl.create 64 in
  List.iter (fun (d : Iface.type_decl) -> Hashtbl.replace t d.path d) decls;
  t

(* [t] with each of its type's parameters, [Var i], replaced by [args]'s
   [i]th. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | Fun (ps, r, e, u, l) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst args p.ty }) ps,
          subst args r,
          e,
          u,
          l )
  | Errors _ | Uses _ | All _ | Error -> t

(* How a type shows its values: as its own `show` method made [v] look,
   [Itself], or as it's declared. [Inside] is inside that method, where
   an opaque value is shown as only what it's represented as, so that
   `show(self)` there doesn't call the method again. *)
type own = Itself of string | Inside | Declared

(* [v], a value of type [t]. [own p args v] says how the type [p], given
   [args], shows [v] (eval.ml). *)
let rec value ~own (types : types) (t : Ty.ty) (v : Value.t) =
  let value = value ~own types in
  let list xs = String.concat ", " xs in
  match (t, v) with
  | Con (p, [ elem ]), VArray xs when p = Path.prelude "Array" ->
      "[" ^ list (Array.to_list (Array.map (value elem) xs)) ^ "]"
  | Con (p, args), _ -> (
      match own p args v with
      | Itself s -> s
      | how -> (
          let d = Hashtbl.find_opt types p in
          match (Option.map (fun (d : Iface.type_decl) -> d.body) d, v) with
          | Some (Record fields), VRecord vs ->
              (* the fields in the order they're declared *)
              p.name ^ " { "
              ^ list
                  (List.map
                     (fun (f : Iface.field) ->
                       f.fname ^ ": "
                       ^ value (subst args f.fty) (List.assoc f.fname vs))
                     fields)
              ^ " }"
          | Some (Sum ctors), VCon c -> (
              match
                List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) ctors
              with
              | Some k
                when k.cfields <> []
                     && List.length k.cfields = List.length c.args ->
                  c.name ^ "("
                  ^ list
                      (List.map2
                         (fun (f : Iface.field) a -> value (subst args f.fty) a)
                         k.cfields c.args)
                  ^ ")"
              | _ -> Value.show v)
          | Some (Opaque (Rep rep)), _ when how = Inside ->
              value (subst args rep) v
          | Some (Opaque (Rep rep)), _ ->
              p.name ^ "(" ^ value (subst args rep) v ^ ")"
          | Some (Opaque (Hidden _)), _ -> p.name ^ "(" ^ Value.show v ^ ")"
          | _ -> Value.show v))
  | Errors row, VTag { name; args } -> (
      (* an error, through its tag's payload's types in the set *)
      match List.find_opt (fun (l : Ty.label) -> l.name = name) row.labels with
      | Some l when l.payload <> [] && List.length l.payload = List.length args
        ->
          name ^ "(" ^ list (List.map2 value l.payload args) ^ ")"
      | _ -> Value.show v)
  | _ -> Value.show v

(* What `show` makes of [v]: a string is itself, and anything else, a
   string inside it included, is shown as it's written. *)
let shown ~own types (t : Ty.ty) (v : Value.t) =
  match (t, v) with
  | Con (p, []), VStr s when p = Path.prelude "Str" -> s
  | (Var _ | Error), VStr s -> s
  | _ -> value ~own types t v

(* The two sides of a failed `assert a == b`, [a] and [b] of type [t],
   with what they share left out (deps.md, "`assert`"): the way to the
   first place they differ, and what each side has there, with every
   other field, element and payload `...`, and a run of them one `...`.
   `Account { ..., balance: Money(-100), ... }`. Both sides leave out the
   same things, so everything up to the difference is written the same on
   both, and a marker can be put under it. A part is kept whole where it
   can't be looked inside to compare: an opaque value, one its type's own
   `show` shows, two different constructors, and an element only one side
   has, after the last they share, which stays so the shorter side reads
   as ending there. If nothing's left to tell them apart, both are shown
   in full. *)
let sides ~own types (t : Ty.ty) (a : Value.t) (b : Value.t) =
  let value = value ~own types in
  (* whether the difference has been shown: everything after it is `...`.
     A [ref] is a mutable cell, here local to one call *)
  let shown = ref false in
  (* each side's parts, with a run of `...` made one *)
  let parts xs =
    let rec go = function
      | "..." :: ("..." :: _ as rest) -> go rest
      | x :: rest -> x :: go rest
      | [] -> []
    in
    String.concat ", " (go xs)
  in
  (* [f] on each of [xs] in turn, left to right, since [shown] says what
     comes after the difference *)
  let rec each f = function
    | [] -> []
    | x :: rest ->
        let y = f x in
        y :: each f rest
  in
  (* [xs] and [ys], two by two, the [i]th of type [ts]'s [i]th, written
     around by [label i] if it isn't left out: each side's parts, not yet
     joined, so an array can add the elements only one side has before a
     run of `...` is made one *)
  let rec each_part ts label xs ys =
    List.split
      (each
         (fun (i, t, x, y) ->
           let l, r = go t x y in
           let label s = if s = "..." then s else label i s in
           (label l, label r))
         (List.mapi
            (fun i (t, (x, y)) -> (i, t, x, y))
            (List.combine ts (List.combine xs ys))))
  (* the same, joined *)
  and both ts label xs ys =
    let ls, rs = each_part ts label xs ys in
    (parts ls, parts rs)
  and go t x y =
    let l = value t x and r = value t y in
    if !shown || l = r then ("...", "...")
    else
      let whole () =
        shown := true;
        (l, r)
      in
      match (t, x, y) with
      | Con (p, [ elem ]), VArray xs, VArray ys when p = Path.prelude "Array" ->
          (* the elements both have, then the first that only one side
             has *)
          let xs = Array.to_list xs and ys = Array.to_list ys in
          let n = min (List.length xs) (List.length ys) in
          let l, r =
            each_part
              (List.init n (fun _ -> elem))
              (fun _ s -> s)
              (List.filteri (fun i _ -> i < n) xs)
              (List.filteri (fun i _ -> i < n) ys)
          in
          (* if they differ only in length, the last element both have
             stays, so the shorter side reads as ending there: `[..., 3]`
             against `[..., 3, 4, ...]` *)
          let l, r =
            if (not !shown) && n > 0 then
              let last = value elem (List.nth xs (n - 1)) in
              let s = (if n > 1 then [ "..." ] else []) @ [ last ] in
              (s, s)
            else (l, r)
          in
          let extra side n_side =
            match List.nth_opt side n with
            | Some v when not !shown ->
                shown := true;
                let rest = if n_side > n + 1 then [ "..." ] else [] in
                value elem v :: rest
            | Some _ -> [ "..." ]
            | None -> []
          in
          let el = extra xs (List.length xs)
          and er = extra ys (List.length ys) in
          let side shared extra = "[" ^ parts (shared @ extra) ^ "]" in
          (side l el, side r er)
      | Con (p, args), _, _ -> (
          match own p args x with
          | Itself _ -> whole ()
          | _ -> (
              match
                ( Option.map
                    (fun (d : Iface.type_decl) -> d.body)
                    (Hashtbl.find_opt types p),
                  x,
                  y )
              with
              | Some (Record fields), VRecord xs, VRecord ys ->
                  let get vs =
                    List.map
                      (fun (f : Iface.field) -> List.assoc f.fname vs)
                      fields
                  in
                  let l, r =
                    both
                      (List.map
                         (fun (f : Iface.field) -> subst args f.fty)
                         fields)
                      (fun i s -> (List.nth fields i).fname ^ ": " ^ s)
                      (get xs) (get ys)
                  in
                  (p.name ^ " { " ^ l ^ " }", p.name ^ " { " ^ r ^ " }")
              | Some (Sum ctors), VCon c, VCon d when c.name = d.name -> (
                  match
                    List.find_opt
                      (fun (k : Iface.ctor) -> k.cname = c.name)
                      ctors
                  with
                  | Some k
                    when k.cfields <> []
                         && List.length k.cfields = List.length c.args
                         && List.length c.args = List.length d.args ->
                      let l, r =
                        both
                          (List.map
                             (fun (f : Iface.field) -> subst args f.fty)
                             k.cfields)
                          (fun _ s -> s)
                          c.args d.args
                      in
                      (c.name ^ "(" ^ l ^ ")", c.name ^ "(" ^ r ^ ")")
                  | _ -> whole ())
              | _ -> whole ()))
      | Errors row, VTag x, VTag y when x.name = y.name -> (
          match
            List.find_opt (fun (l : Ty.label) -> l.name = x.name) row.labels
          with
          | Some l
            when l.payload <> []
                 && List.length l.payload = List.length x.args
                 && List.length x.args = List.length y.args ->
              let l, r = both l.payload (fun _ s -> s) x.args y.args in
              (x.name ^ "(" ^ l ^ ")", x.name ^ "(" ^ r ^ ")")
          | _ -> whole ())
      | _ -> whole ()
  in
  match go t a b with
  | l, r when l = r -> (value t a, value t b)
  | sides -> sides
