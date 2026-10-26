(* Values, as `show`, `print`, a failed `assert` and an error nothing
   handled show them.

   A value is shown as it's written, with the names of the types it's
   made of: a record after its type's name, `Account { id: AccountId(1)
   }`, and an opaque value as its type's name around what it is,
   `Money(-100)`, unless its type has a `show` method of its own, `Path`'s,
   which is used instead. At runtime an opaque value is only what it's
   represented as, so a value is shown through its type, and each type's
   declaration, by its path. *)

(* Every type's declaration, by its path (walk.ml). *)
type types = Walk.types

let types = Walk.types_of
let subst = Walk.subst

(* How a type shows its values: as its own `show` method made [v] look,
   [Itself], or as it's declared. [Inside] is inside that method, where
   an opaque value is shown as only what it's represented as, so that
   `show(self)` there doesn't call the method again. *)
type own = Itself of string | Inside | Declared

(* [v], a value of type [t], through what [Walk.view] says it's made of.
   [own p args v] says how the type [p], given [args], shows [v]
   (eval.ml). *)
let rec value ~own (types : types) (t : Ty.ty) (v : Value.t) =
  let value = value ~own types in
  let list xs = String.concat ", " xs in
  let how = match t with Con (p, args) -> own p args v | _ -> Declared in
  match (how, Walk.view types t v) with
  | Itself s, _ -> s
  | _, Elems (elem, xs) ->
      "[" ^ list (Array.to_list (Array.map (value elem) xs)) ^ "]"
  | _, Record (name, fields) ->
      (* the fields in the order they're declared *)
      name ^ " { "
      ^ list (List.map (fun (f, t, x) -> f ^ ": " ^ value t x) fields)
      ^ " }"
  | _, Ctor { name; fields = _ :: _ as fields; _ } ->
      name ^ "(" ^ list (List.map (fun (t, x) -> value t x) fields) ^ ")"
  | Inside, Opaque (_, rep) -> value rep v
  | _, Opaque (name, rep) -> name ^ "(" ^ value rep v ^ ")"
  | _, Hidden name -> name ^ "(" ^ Value.show v ^ ")"
  | _, Tag (name, (_ :: _ as payload)) ->
      (* an error, through its tag's payload's types in the set *)
      name ^ "(" ^ list (List.map (fun (t, x) -> value t x) payload) ^ ")"
  | _, (Leaf | Ctor _ | Tag _ | Shape) -> Value.show v

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
      (* a value its type's own `show` shows is kept whole *)
      let own_shown =
        match t with
        | Con (p, args) -> (
            match own p args x with
            | Itself _ -> true
            | Inside | Declared -> false)
        | _ -> false
      in
      match (Walk.view types t x, Walk.view types t y) with
      | _ when own_shown -> whole ()
      | Elems (elem, xs), Elems (_, ys) ->
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
      | Record (name, xs), Record (_, ys) ->
          let l, r =
            both
              (List.map (fun (_, t, _) -> t) xs)
              (fun i s ->
                let f, _, _ = List.nth xs i in
                f ^ ": " ^ s)
              (List.map (fun (_, _, x) -> x) xs)
              (List.map (fun (_, _, y) -> y) ys)
          in
          (name ^ " { " ^ l ^ " }", name ^ " { " ^ r ^ " }")
      | Ctor c, Ctor d when c.name = d.name && c.fields <> [] ->
          let l, r =
            both (List.map fst c.fields)
              (fun _ s -> s)
              (List.map snd c.fields) (List.map snd d.fields)
          in
          (c.name ^ "(" ^ l ^ ")", c.name ^ "(" ^ r ^ ")")
      | Tag (x, xs), Tag (y, ys) when x = y && xs <> [] ->
          let l, r =
            both (List.map fst xs)
              (fun _ s -> s)
              (List.map snd xs) (List.map snd ys)
          in
          (x ^ "(" ^ l ^ ")", x ^ "(" ^ r ^ ")")
      | _ -> whole ()
  in
  match go t a b with
  | l, r when l = r -> (value t a, value t b)
  | sides -> sides
