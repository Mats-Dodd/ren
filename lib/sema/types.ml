(* Types as the type checker sees them, as opposed to types as written in
   source (Ast.ty).

   A type variable is a mutable cell: [Unbound] until inference learns what
   it is, then [Link]ed to that type. Unifying two variables links one cell
   to the other, so everything that shares the cell learns the answer at
   once (a union-find structure). [repr] follows links to the current
   answer, and every function here looks at types through it.

   Function types carry two rows: the errors the function can fail with and
   the dependencies it uses. A row is a list of labels ending either in
   [REmpty] (closed: exactly these labels) or in a row variable (open: these
   labels and possibly more). Rows are unified the way OCaml unifies
   polymorphic variants, after Rémy; see unify.ml.

   Levels decide which variables can be generalized, without scanning the
   environment. Every variable records the level at which it was created.
   Inference enters a new level for each group of top-level functions it
   checks; when it leaves, any variable still at a deeper level belongs only
   to those functions, so it becomes generic (a "for all"). Unification keeps
   levels honest: binding a variable to a type lowers the levels inside that
   type to the variable's own.

   These types stay inside inference. What it hands on is converted to the
   canonical, immutable types of ty.ml ([to_scheme]), and what it reads from
   other modules' interfaces is converted back ([of_scheme]). *)

(* The same [Read | Inout] as in the AST. Writing [= Ast.mode] re-exports
   that type, so both modules' constructors are interchangeable. *)
type mode = Ast.mode = Read | Inout

type ty =
  | TCon of Path.t * ty list  (** [Int], [Option<Int>], [User] *)
  | TVariant of Path.t * string * ty list
      (** a variant type, [Order.Placed] (ty.ml, [Variant]): the sum's path,
          the by-name constructor and the sum's type arguments. It unifies
          only with itself, never with its sum *)
  | TFun of param list * ty * row * row  (** params, result, errors, uses *)
  | TVar of tvar ref
  | TErrors of row
      (** an error set as a type argument, which only [Result<T, ! ...>] takes
      *)
  | TImpl of impl
      (** an implementation of a dependency, or of several sharing one state,
          what a handler of several describes, `Clock & TestClock` ([impl_type])
      *)
  | TSkol of int * string
      (** a type parameter like [T], while checking the function that declares
          it: equal only to itself, since the function has to work for every [T]
      *)
  | TError
      (** the type of code that has an error, already reported. It unifies with
          every type, so the one mistake isn't reported again everywhere its
          value goes. *)

(* A function type's parameter: its type, and whether the function changes
   it. The mode is part of the type, so a function that changes its argument
   can't be passed where one that only reads it is expected: the caller
   wouldn't write `&`, and the change would be lost. *)
and param = { mode : mode; ty : ty }

(* An implementation's type (ty.ml, [impl]): the dependencies it
   implements, sorted, each once; whether it goes over another
   implementation of them (handlers.md, "`over`"); what it needs where
   it's installed; and what installing it can fail with, what its state
   and its `finally` fail with. *)
and impl = { deps : dep list; over : bool; needs : row; fails : row }

(* A dependency an implementation implements: its path and type arguments,
   `Chan<Int>` (ty.ml, [dep]). *)
and dep = { dpath : Path.t; dargs : ty list }
and tvar = Unbound of int * int  (** id, level *) | Link of ty

and row =
  | REmpty
  | RExtend of label * row
  | RVar of rvar ref
  | RSkol of int * string
      (** a row named in the signature of the function being checked, the `..d`
          of `c: Clock uses ..d`: like a [TSkol], equal only to itself, since
          the function has to work for whatever it stands for *)

and rvar = RUnbound of int * int  (** id, level *) | RLink of row

(* A row's label: an error's tag and its payload's types, or a dependency
   and its type arguments (ty.ml). *)
and label = {
  name : string;
  payload : ty list;
  dep : bool;
      (** a dependency's label, which is told apart from another of its name by
          its payload, its type arguments: `Chan<Int>` and `Chan<Str>` are two
          dependencies, where a tag of one name has one payload ([same_label])
      *)
  written : mark;
      (** where the tag was written inside `Err(...)`, if it's in a set of its
          own, made of tags written so (solve.ml, [value_tag]). Such a set holds
          exactly those, so what an `attempt` keeps can't take the tag from it
          (B5). It's the same label either way: only the solver's check of kept
          sets reads it, and canonical form drops it *)
}

(* Two labels unified are one tag, so they share one mark, the way a
   variable linked to another shares its type ([join_marks]): a mark is
   where it was written, or a link to the mark it was joined with. *)
and mark = mark_cell ref
and mark_cell = Mark of Loc.t option | Mark_link of mark

let generic_level = max_int

(* A set of strings. Unlike a [Hashtbl] it never changes: adding to one
   makes a new set, sharing most of the old. Finding one is quick however
   many there are. *)
module Names = Set.Make (String)

(* What inference changes as it goes. Each compilation makes its own and
   passes it to everything that needs it, so there are no global counters
   and two compilations in one process can't affect each other. *)
type state = {
  mutable level : int;  (** the level new variables are created at *)
  mutable last_id : int;  (** the last id handed out to a variable *)
  hints : (int, string) Hashtbl.t;
      (** the names of type parameters, remembered so `ren types` can print `T`
          for a variable that came from `fn id<T>` *)
  skolem_vars : (int, ty) Hashtbl.t;
      (** the generic variable each type parameter became when its function was
          generalized, by the parameter's id *)
  skolem_rows : (int, row) Hashtbl.t;
      (** and the generic row variable each named row became *)
  needs : (int, string list) Hashtbl.t;
      (** what each variable needs of the type it stands for, `eq` for `==`, by
          its id: a generic variable's are its scheme's requirements, and a type
          parameter's, while its function is checked, what its body found
          (Infer_reqs). Only looked up, never walked *)
  need_at : (int * string, Loc.t) Hashtbl.t;
      (** where each variable was first found to need each requirement, for a
          message at a call that gives it a type without it *)
  reps : (Path.t, Ty.ty) Hashtbl.t;
      (** what each opaque type of the module being checked is represented as:
          in its own module, an opaque type is its representation (see [reveal])
      *)
  aliases : (Path.t, Ty.dep) Hashtbl.t;
      (** what each alias of a dependency names, `Jobs` `Chan<Job>`: a
          description of one is a description of the other (Unify) *)
}

let new_state () =
  {
    level = 1;
    last_id = 0;
    hints = Hashtbl.create 16;
    skolem_vars = Hashtbl.create 16;
    skolem_rows = Hashtbl.create 8;
    needs = Hashtbl.create 8;
    need_at = Hashtbl.create 8;
    reps = Hashtbl.create 4;
    aliases = Hashtbl.create 4;
  }

let enter_level st = st.level <- st.level + 1
let leave_level st = st.level <- st.level - 1

let fresh_id st =
  st.last_id <- st.last_id + 1;
  st.last_id

let fresh_var st = TVar (ref (Unbound (fresh_id st, st.level)))
let fresh_row st = RVar (ref (RUnbound (fresh_id st, st.level)))
let generic_var st = TVar (ref (Unbound (fresh_id st, generic_level)))
let generic_row st = RVar (ref (RUnbound (fresh_id st, generic_level)))
let int = TCon (Path.prelude "Int", [])
let float = TCon (Path.prelude "Float", [])
let bool = TCon (Path.prelude "Bool", [])
let unit = TCon (Path.prelude "Unit", [])
let str = TCon (Path.prelude "Str", [])
let array t = TCon (Path.prelude "Array", [ t ])
let read ty = { mode = Read; ty }
let param_tys ps = List.map (fun p -> p.ty) ps

(* The type of an implementation of [deps], needing [needs]: one
   dependency's, `Clock`, or for several, a type that lists them, `Clock &
   TestClock`, the same whichever order they're written in, so they're
   kept sorted, each once (deps.md, "Implementations"). [over] says it
   goes over another implementation of them, and [fails] is what
   installing it can fail with: nothing, unless it's said. *)
let impl_type ?(over = false) ?(fails = REmpty) deps needs =
  TImpl
    {
      deps = List.sort_uniq (fun a b -> compare a.dpath b.dpath) deps;
      over;
      needs;
      fails;
    }

(* The dependency at [p], with no type arguments. *)
let plain p = { dpath = p; dargs = [] }

(* A label's mark when it isn't written inside `Err`: one of its own,
   since a mark is changed when it's joined with another. *)
let unmarked () = ref (Mark None)

(* `Cancelled`, which a `finally`'s result can hold, and no other row
   (compiler.md, "Stage 11a", "Cancellation"). *)
let cancelled_tag = "Cancelled"

let cancelled () =
  { name = cancelled_tag; payload = []; dep = false; written = unmarked () }

(* [r] without `Cancelled`: what `try r` passes on of a `finally`'s [r],
   since the cancel goes on by itself. *)
let rec without_cancelled r =
  match r with
  | RExtend (l, rest) when l.name = cancelled_tag && l.payload = [] -> rest
  | RExtend (l, rest) -> RExtend (l, without_cancelled rest)
  | RVar { contents = RLink r } -> without_cancelled r
  | r -> r

(* The label of a dependency, [name] its path in full (Ty.dep_label), with
   its type arguments, if it takes some. *)
let dep ?(args = []) name =
  { name; payload = args; dep = true; written = unmarked () }

(* The label of the dependency [d]. *)
let dep_of d = dep ~args:d.dargs (Ty.dep_label d.dpath)

(* The type parameters refined where they're checked: in an arm of a
   `match` on a `call` clause's call, the result of the call is known to
   be the result of the arm's case's operation (compiler.md, "Services
   stage", "`D.Call`"), so the skolem that stands for it is that type
   there, by its id. It holds something only while such an arm is
   checked (Infer_expr.infer_match), and [repr] reads it. That's sound:
   inside the arm the call is that case, so its result has that type;
   and outside it the skolem is itself again, so what was found inside
   about something of the clause's, a variable's type, is only ever
   [repr]'d into the refined type, never linked to it ([repr] keeps the
   link to the skolem). *)
let refined : (int, ty) Hashtbl.t = Hashtbl.create 1

(* Follow links to the type a variable currently stands for, shortening the
   chain as it goes so later lookups are quick. *)
let rec repr t =
  match chase t with
  | TSkol (id, _) as t when Hashtbl.length refined > 0 -> (
      match Hashtbl.find_opt refined id with Some r -> repr r | None -> t)
  | t -> t

(* The same, without refining: what a link is shortened to. *)
and chase t =
  match t with
  | TVar ({ contents = Link t' } as r) ->
      let t'' = chase t' in
      r := Link t'';
      t''
  | t -> t

let rec repr_row r =
  match r with
  | RVar ({ contents = RLink r' } as cell) ->
      let r'' = repr_row r' in
      cell := RLink r'';
      r''
  | r -> r

(* Whether [a] and [b] are the same type now: a variable only itself, a
   type parameter only itself. It's what tells two instances of a generic
   dependency apart, where inference doesn't unify them ([same_label]). *)
let rec same_ty a b =
  match (repr a, repr b) with
  | TVar r1, TVar r2 -> r1 == r2
  | TSkol (i, _), TSkol (j, _) -> i = j
  | TError, TError -> true
  | TCon (p, xs), TCon (q, ys) ->
      p = q && List.length xs = List.length ys && List.for_all2 same_ty xs ys
  | TVariant (p, c, xs), TVariant (q, d, ys) ->
      p = q && c = d
      && List.length xs = List.length ys
      && List.for_all2 same_ty xs ys
  | TFun (ps, r, e, u), TFun (qs, r', e', u') ->
      List.length ps = List.length qs
      && List.for_all2 (fun p q -> p.mode = q.mode && same_ty p.ty q.ty) ps qs
      && same_ty r r' && same_row e e' && same_row u u'
  | TErrors e, TErrors e' -> same_row e e'
  | TImpl i, TImpl j ->
      List.length i.deps = List.length j.deps
      && List.for_all2 same_dep i.deps j.deps
      && i.over = j.over && same_row i.needs j.needs && same_row i.fails j.fails
  | _ -> false

and same_dep a b =
  a.dpath = b.dpath
  && List.length a.dargs = List.length b.dargs
  && List.for_all2 same_ty a.dargs b.dargs

and same_row a b =
  match (repr_row a, repr_row b) with
  | REmpty, REmpty -> true
  | RVar c1, RVar c2 -> c1 == c2
  | RSkol (i, _), RSkol (j, _) -> i = j
  | RExtend (l, r), RExtend (l', r') ->
      l.name = l'.name
      && List.length l.payload = List.length l'.payload
      && List.for_all2 same_ty l.payload l'.payload
      && same_row r r'
  | _ -> false

(* Whether two labels are one: the same name, and for a dependency, the
   same type arguments. Two tags of one name are one tag, whose payloads
   unification makes the same (unify.ml). *)
let same_label (a : label) (b : label) =
  a.name = b.name
  && ((not (a.dep || b.dep))
     || List.length a.payload = List.length b.payload
        && List.for_all2 same_ty a.payload b.payload)

(* If [t] is an implementation, of one dependency or several: which, sorted,
   and what it needs. *)
let impl_parts t =
  match repr t with TImpl i -> Some (i.deps, i.needs) | _ -> None

(* If [t] is an implementation, all of its type. *)
let impl_of t = match repr t with TImpl i -> Some i | _ -> None

(* A row's labels and, if it's open, the id of its tail: a variable, or a
   named row, which stands for more labels too, only not ones inference
   can add. A row can hold a label twice, which means what holding it once
   does (Infer_rows.join_uses), so a label is listed once, where it first
   is. *)
let rec row_parts r =
  (* [seen] are the names in [acc], so a row of many labels is listed in
     time proportional to them; a dependency's of the same name is looked
     for among them only then *)
  let rec go acc seen r =
    match repr_row r with
    | REmpty -> (List.rev acc, None)
    | RExtend (l, rest)
      when Names.mem l.name seen && List.exists (same_label l) acc ->
        go acc seen rest
    | RExtend (l, rest) -> go (l :: acc) (Names.add l.name seen) rest
    | RVar { contents = RUnbound (id, _) } | RSkol (id, _) ->
        (List.rev acc, Some id)
    | RVar { contents = RLink _ } -> assert false (* repr_row followed it *)
  in
  go [] Names.empty r

(* Just the labels' names. *)
and row_names r = List.map (fun l -> l.name) (fst (row_parts r))

(* Whether [r] has the label [l] among those it lists. *)
let has_label r l = List.exists (same_label l) (fst (row_parts r))

(* [r]'s labels, sorted by name, each once, as canonical form lists them
   (Ty.sort_labels): two of one name, two instances of a generic
   dependency, by their type arguments as they are now. *)
let sorted_labels r =
  let canon (t : ty) =
    (* enough of a type to sort by: a variable by its id *)
    let rec go t =
      match repr t with
      | TCon (p, args) ->
          Path.full p ^ "<" ^ String.concat "," (List.map go args) ^ ">"
      | TVariant (p, c, args) ->
          Path.full p ^ "." ^ c ^ "<"
          ^ String.concat "," (List.map go args)
          ^ ">"
      | TVar { contents = Unbound (id, _) } -> "'" ^ string_of_int id
      | TSkol (id, _) -> "!" ^ string_of_int id
      | _ -> "?"
    in
    go t
  in
  List.stable_sort
    (fun (a : label) (b : label) ->
      match String.compare a.name b.name with
      | 0 -> compare (List.map canon a.payload) (List.map canon b.payload)
      | c -> c)
    (fst (row_parts r))

(* Labels without those of [drop]. *)
let without_labels drop ls =
  List.filter (fun l -> not (List.exists (same_label l) drop)) ls

(* The row variable a row ends in, if it's open. *)
let row_tail r = snd (row_parts r)

(* The named row [r] ends in, if it ends in one. *)
let rec row_skolem r =
  match repr_row r with
  | RExtend (_, rest) -> row_skolem rest
  | RSkol (id, name) -> Some (id, name)
  | RVar _ | REmpty -> None

(* Close [r]: it has exactly the labels it has now. A named row stays
   what it is. *)
let rec close_row r =
  match repr_row r with
  | RExtend (_, rest) -> close_row rest
  | RVar ({ contents = RUnbound _ } as cell) -> cell := RLink REmpty
  | RVar { contents = RLink _ } | REmpty | RSkol _ -> ()

(* Close what each description in [t] needs, unless a generic row stands
   for more of it: a call gives a description a tail of its own, so it
   fits a slot that needs more (Infer_expr.made), and once its function
   is checked, a tail nothing joined to anything is nothing more. Done
   before a function's types are made canonical, so every type that
   shares the tail agrees. *)
let rec close_free_needs t =
  let rec row_args r =
    match repr_row r with
    | RExtend (l, rest) ->
        List.iter close_free_needs l.payload;
        row_args rest
    | _ -> ()
  in
  match repr t with
  | TImpl i ->
      List.iter (fun d -> List.iter close_free_needs d.dargs) i.deps;
      row_args i.needs;
      row_args i.fails;
      let rec go r =
        match repr_row r with
        | RExtend (_, rest) -> go rest
        | RVar ({ contents = RUnbound (_, l) } as cell) when l <> generic_level
          ->
            cell := RLink REmpty
        | _ -> ()
      in
      go i.needs
  | TCon (_, args) | TVariant (_, _, args) -> List.iter close_free_needs args
  | TErrors e -> row_args e
  | TFun (ps, r, e, u) ->
      List.iter (fun p -> close_free_needs p.ty) ps;
      close_free_needs r;
      row_args e;
      row_args u
  | TVar _ | TSkol _ | TError -> ()

(* Close what the description a function gives needs, [t] being its type,
   if nothing else in [t] has that row: it's exactly what the function's
   body found. Where it's called, it's opened again (Infer_expr.made). *)
let close_result_needs t =
  let seen = Hashtbl.create 8 in
  let rec ty t =
    match repr t with
    | TImpl i ->
        List.iter (fun d -> List.iter ty d.dargs) i.deps;
        row i.needs;
        row i.fails
    | TCon (_, args) | TVariant (_, _, args) -> List.iter ty args
    | TErrors e -> row e
    | TFun (ps, r, e, u) ->
        List.iter (fun p -> ty p.ty) ps;
        ty r;
        row e;
        row u
    | TVar _ | TSkol _ | TError -> ()
  and row r =
    match repr_row r with
    | RExtend (l, rest) ->
        List.iter ty l.payload;
        row rest
    | RVar { contents = RUnbound (id, _) } ->
        Hashtbl.replace seen id
          (1 + Option.value (Hashtbl.find_opt seen id) ~default:0)
    | _ -> ()
  in
  ty t;
  match repr t with
  | TFun (_, r, _, _) -> (
      match repr r with
      | TImpl i -> (
          let rec go r =
            match repr_row r with
            | RExtend (_, rest) -> go rest
            | RVar ({ contents = RUnbound (id, _) } as cell)
              when Hashtbl.find_opt seen id = Some 1 ->
                cell := RLink REmpty
            | _ -> ()
          in
          go i.needs)
      | _ -> ())
  | _ -> ()

(* [l] as a set gets it by inclusion, from what's failed with: not
   written, wherever it was before. *)
let unwritten l = { l with written = unmarked () }

(* The mark [m] stands for, at the end of its links. *)
let rec mark_root m = match !m with Mark _ -> m | Mark_link m -> mark_root m

(* Where [l] was written inside `Err`, if every label it's been unified
   with was too. *)
let written_at (l : label) =
  match !(mark_root l.written) with Mark w -> w | Mark_link _ -> assert false

(* Join the marks of two labels just unified. A tag that's anywhere
   other than in a set of tags written in `Err` (declared, or failed
   with) is unmarked, so a kept set can take it, as it could if the tags
   were written in place; of two places it was written, the first in the
   file is kept. Joined, not just set on the two, so a label unified with
   one of them earlier sees it too, whatever order they meet in (R3). *)
let join_marks a b =
  let a = mark_root a and b = mark_root b in
  if a != b then
    match (!a, !b) with
    | Mark (Some x), Mark (Some y) ->
        a := Mark (Some (min x y));
        b := Mark_link a
    | Mark _, Mark _ ->
        a := Mark None;
        b := Mark_link a
    | _ -> assert false

(* What the variable or type parameter [id] needs, sorted. *)
let needs st id = Option.value (Hashtbl.find_opt st.needs id) ~default:[]

(* Where [id] was first found to need [req], if that's known. *)
let need_at st id req = Hashtbl.find_opt st.need_at (id, req)

(* Say that [id] needs [req], found [at] that place. Whether that's new. *)
let add_need ?at st id req =
  let have = needs st id in
  if List.mem req have then false
  else (
    Hashtbl.replace st.needs id (List.sort compare (req :: have));
    Option.iter (Hashtbl.replace st.need_at (id, req)) at;
    true)

(* A row of [labels], ending in [tail]. *)
let extend labels tail =
  List.fold_right (fun l rest -> RExtend (l, rest)) labels tail

(* ---- generalizing and instantiating ---- *)

(* A parameter's type [t] copied by [go]: if inference found it, it's
   still a variable in the copy, linked to what it found, so the copy
   doesn't look written (Infer_written.is_written), and an argument isn't
   narrowed to it however the function is reached. *)
let copy_param go t =
  match t with
  | TVar { contents = Link _ } -> TVar (ref (Link (go t)))
  | t -> go t

(* Make generic every variable created deeper than the current level, and
   replace the function's own type parameters ([skolems], as id and name)
   with generic variables too. The result is the function's type scheme. *)
let generalize st ~skolems ?(row_skolems = []) t =
  let table = Hashtbl.create 8 and rows = Hashtbl.create 4 in
  let rec go t =
    match repr t with
    | TVar ({ contents = Unbound (id, l) } as r) as t ->
        if l > st.level then r := Unbound (id, generic_level);
        t
    | TVar { contents = Link _ } -> assert false
    | TSkol (id, name) as t -> (
        if not (List.mem_assoc id skolems) then t
        else
          match Hashtbl.find_opt table id with
          | Some v -> v
          | None ->
              let v = generic_var st in
              (* it's named after the parameter, and needs what it does *)
              (match v with
              | TVar { contents = Unbound (vid, _) } ->
                  Hashtbl.replace st.hints vid name;
                  List.iter
                    (fun r -> ignore (add_need ?at:(need_at st id r) st vid r))
                    (needs st id)
              | _ -> ());
              Hashtbl.add table id v;
              Hashtbl.replace st.skolem_vars id v;
              v)
    | TCon (n, args) -> TCon (n, List.map go args)
    | TVariant (n, c, args) -> TVariant (n, c, List.map go args)
    | TErrors e -> TErrors (row e)
    | TImpl i ->
        let deps =
          List.map (fun d -> { d with dargs = List.map go d.dargs }) i.deps
        in
        TImpl { i with deps; needs = row i.needs; fails = row i.fails }
    | TFun (ps, r, e, u) -> TFun (List.map param ps, go r, row e, row u)
    | TError -> TError
  and param p = { p with ty = copy_param go p.ty }
  and row r =
    match repr_row r with
    | RVar ({ contents = RUnbound (id, l) } as cell) as r ->
        if l > st.level then cell := RUnbound (id, generic_level);
        r
    | RVar { contents = RLink _ } -> assert false
    | RSkol (id, _) as r -> (
        if not (List.mem_assoc id row_skolems) then r
        else
          match Hashtbl.find_opt rows id with
          | Some v -> v
          | None ->
              let v = generic_row st in
              (* it needs what the named row does *)
              (match v with
              | RVar { contents = RUnbound (vid, _) } ->
                  List.iter (fun r -> ignore (add_need st vid r)) (needs st id)
              | _ -> ());
              Hashtbl.add rows id v;
              Hashtbl.replace st.skolem_rows id v;
              v)
    | REmpty -> REmpty
    | RExtend (l, rest) ->
        RExtend ({ l with payload = List.map go l.payload }, row rest)
  in
  go t

(* What [instantiate] put in place of a scheme's generic variables: each
   one's id and the fresh variable that took its place, type variables and
   row variables apart. They're in the order canonical form numbers them
   (ty.ml), by where they first appear reading left to right, so the n-th
   of [tys] is what [Var n] of the function's [Ty.scheme] became at this
   use: its n-th type argument. *)
type subst = { tys : (int * ty) list; rows : (int * row) list }

(* The generic variables of a scheme, each standing for itself, in the
   order canonical form numbers them: walked as [canon_ty] walks a type, a
   function's parameters, result, errors and uses, and a row's labels by
   name, then its tail. It's the substitution that gives back the scheme
   itself, the type arguments of a function used at its own type, as in
   its own body. *)
let generics t =
  let seen_tys = ref [] and seen_rows = ref [] in
  let see seen id v =
    if not (List.mem_assoc id !seen) then seen := (id, v) :: !seen
  in
  let rec walk t =
    match repr t with
    | TVar { contents = Unbound (id, l) } as v when l = generic_level ->
        see seen_tys id v
    | TVar _ | TSkol _ | TError -> ()
    | TCon (_, args) | TVariant (_, _, args) -> List.iter walk args
    | TErrors e -> walk_row e
    | TImpl i ->
        List.iter (fun d -> List.iter walk d.dargs) i.deps;
        walk_row i.needs;
        walk_row i.fails
    | TFun (ps, r, e, u) ->
        List.iter (fun p -> walk p.ty) ps;
        walk r;
        walk_row e;
        walk_row u
  and walk_row r =
    List.iter (fun l -> List.iter walk l.payload) (sorted_labels r);
    walk_tail r
  and walk_tail r =
    match repr_row r with
    | RVar { contents = RUnbound (id, l) } as v when l = generic_level ->
        see seen_rows id v
    | RExtend (_, rest) -> walk_tail rest
    | REmpty | RVar _ | RSkol _ -> ()
  in
  walk t;
  { tys = List.rev !seen_tys; rows = List.rev !seen_rows }

(* Only those of [s]'s variables that are among [keep]'s, in [s]'s order. *)
let restrict s keep =
  {
    tys = List.filter (fun (id, _) -> List.mem_assoc id keep.tys) s.tys;
    rows = List.filter (fun (id, _) -> List.mem_assoc id keep.rows) s.rows;
  }

(* A copy of a type scheme with fresh variables in place of the generic
   ones, so each use of a function can pick its own types, and which
   fresh variable took each one's place. *)
let instantiate st t =
  let tys = Hashtbl.create 8 and rows = Hashtbl.create 8 in
  let rec go t =
    match repr t with
    | TVar { contents = Unbound (id, l) } when l = generic_level -> (
        match Hashtbl.find_opt tys id with
        | Some v -> v
        | None ->
            let v = fresh_var st in
            Hashtbl.add tys id v;
            v)
    | (TVar _ | TSkol _ | TError) as t -> t
    | TCon (n, args) -> TCon (n, List.map go args)
    | TVariant (n, c, args) -> TVariant (n, c, List.map go args)
    | TErrors e -> TErrors (row e)
    | TImpl i ->
        (* `let`s fix the order: OCaml evaluates a record's fields in no
           order it promises *)
        let deps =
          List.map (fun d -> { d with dargs = List.map go d.dargs }) i.deps
        in
        let needs = row i.needs in
        let fails = row i.fails in
        TImpl { i with deps; needs; fails }
    | TFun (ps, r, e, u) -> TFun (List.map param ps, go r, row e, row u)
  and param p = { p with ty = copy_param go p.ty }
  and row r =
    match repr_row r with
    | RVar { contents = RUnbound (id, l) } when l = generic_level -> (
        match Hashtbl.find_opt rows id with
        | Some v -> v
        | None ->
            let v = fresh_row st in
            Hashtbl.add rows id v;
            v)
    | (REmpty | RVar _ | RSkol _) as r -> r
    | RExtend (l, rest) ->
        (* a mark of its own, so what the copy is unified with doesn't
           change the scheme's *)
        RExtend
          ( {
              l with
              payload = List.map go l.payload;
              written = ref (Mark (written_at l));
            },
            row rest )
  in
  let copy = go t in
  (* each generic variable, in order, with the fresh one [go] made for
     it. [go] can't record the order itself, since OCaml evaluates a
     constructor's arguments right to left *)
  let g = generics t in
  ( copy,
    {
      tys = List.map (fun (id, _) -> (id, Hashtbl.find tys id)) g.tys;
      rows = List.map (fun (id, _) -> (id, Hashtbl.find rows id)) g.rows;
    } )

(* A copy of [t] with [s]'s types in place of the type parameters (as
   skolems) it lists by id, and its rows in place of the named rows and
   the unbound row variables it lists by id. That's how a function of the
   group being checked, which isn't generic yet, is used at types of its
   own: its type parameters and the rows it names are what its declaration
   makes generic (infer_lookup.ml, [own_instance]). *)
let replace (s : subst) t =
  let rec go t =
    match repr t with
    | TSkol (id, _) as t -> Option.value (List.assoc_opt id s.tys) ~default:t
    | (TVar _ | TError) as t -> t
    | TCon (n, args) -> TCon (n, List.map go args)
    | TVariant (n, c, args) -> TVariant (n, c, List.map go args)
    | TErrors e -> TErrors (row e)
    | TImpl i ->
        (* `let`s fix the order: OCaml evaluates a record's fields in no
           order it promises *)
        let deps =
          List.map (fun d -> { d with dargs = List.map go d.dargs }) i.deps
        in
        let needs = row i.needs in
        let fails = row i.fails in
        TImpl { i with deps; needs; fails }
    | TFun (ps, r, e, u) -> TFun (List.map param ps, go r, row e, row u)
  and param p = { p with ty = go p.ty }
  and row r =
    match repr_row r with
    | (RSkol (id, _) | RVar { contents = RUnbound (id, _) }) as r ->
        Option.value (List.assoc_opt id s.rows) ~default:r
    | (REmpty | RVar _) as r -> r
    | RExtend (l, rest) ->
        RExtend ({ l with payload = List.map go l.payload }, row rest)
  in
  go t

(* ---- canonical types ---- *)

(* Converting to canonical form (ty.ml) numbers every variable by where it
   first appears. A [canon] holds that numbering, so everything converted
   with one shares it: a function's scheme first, then the types of the
   expressions in its body, so a variable is the same [Var n] in both. *)
type canon = {
  cst : state;
  tys : (int, int) Hashtbl.t;  (** variable id -> its number *)
  rows : (int, int) Hashtbl.t;  (** row variable id -> its number *)
  mutable names : (int * string) list;
      (** the declared names of the numbered variables *)
  for_message : bool;
      (** converting for an error message, while inference is still running (see
          [printer]) *)
  mutable params : (int * string) list;
      (** for a message: the type parameters numbered so far, with their names
      *)
  mutable named_rows : (int * string) list;
      (** and the named rows, `..d` (see [RSkol]) *)
}

let canon st =
  {
    cst = st;
    tys = Hashtbl.create 8;
    rows = Hashtbl.create 8;
    names = [];
    for_message = false;
    params = [];
    named_rows = [];
  }

let number table id =
  match Hashtbl.find_opt table id with
  | Some n -> n
  | None ->
      let n = Hashtbl.length table in
      Hashtbl.add table id n;
      n

(* [t] in canonical form. A scheme ([all = false]) numbers only its generic
   variables: one inference never solved, outside any scheme, can only come
   from code with an error, so it becomes [Error], and a row whose tail
   isn't generic is exactly its labels. Inside a function's body
   ([all = true]) a variable nothing constrained is still a variable, like
   the parameter of a lambda that's never used. A type parameter is the
   variable it became when its function was generalized.

   For a message ([c.for_message]), a type parameter is a variable of its
   own, which the printer names as the parameter, and every row tail is
   kept, so the printer can choose which to show. *)
let rec canon_ty c ~all t : Ty.ty =
  match repr t with
  | TVar { contents = Unbound (id, l) } when all || l = generic_level ->
      let n = number c.tys id in
      (match Hashtbl.find_opt c.cst.hints id with
      | Some h when not (List.mem_assoc n c.names) ->
          c.names <- (n, h) :: c.names
      | _ -> ());
      Var n
  | TSkol (id, name) when c.for_message ->
      let n = number c.tys id in
      if not (List.mem_assoc n c.params) then c.params <- (n, name) :: c.params;
      Var n
  | TSkol (id, _) -> (
      match Hashtbl.find_opt c.cst.skolem_vars id with
      | Some v -> canon_ty c ~all v
      | None -> Error)
  | TVar _ | TError -> Error
  | TCon (p, args) -> Con (p, List.map (canon_ty c ~all) args)
  | TVariant (p, k, args) -> Variant (p, k, List.map (canon_ty c ~all) args)
  | TErrors e -> Errors (canon_row c ~all e)
  | TImpl i ->
      let deps =
        List.map
          (fun d ->
            { Ty.dpath = d.dpath; dargs = List.map (canon_ty c ~all) d.dargs })
          i.deps
      in
      let needs = canon_row c ~all i.needs in
      let fails = canon_row c ~all i.fails in
      Impl { deps; over = i.over; needs; fails }
  | TFun (ps, r, e, u) ->
      (* `let`s fix the order of first appearance: OCaml evaluates a
         constructor's arguments right to left *)
      let ps =
        List.map (fun p -> { Ty.mode = p.mode; ty = canon_ty c ~all p.ty }) ps
      in
      let r = canon_ty c ~all r in
      let e = canon_row c ~all e in
      let u = canon_row c ~all u in
      Fun (ps, r, e, u)

and canon_row c ~all r : Ty.row =
  (* only a generic tail stands for "and possibly more", in a scheme. The
     labels' payloads are converted in order of name, then the tail, as
     Ty.canonical numbers them. *)
  let rec tail r =
    match repr_row r with
    | RVar { contents = RUnbound (id, l) } ->
        if all || c.for_message || l = generic_level then
          Some (number c.rows id)
        else None
    | RSkol (id, name) when c.for_message ->
        let n = number c.rows id in
        if not (List.mem_assoc n c.named_rows) then
          c.named_rows <- (n, name) :: c.named_rows;
        Some n
    | RSkol (id, _) -> (
        (* the generic variable it became, as a [TSkol] does *)
        match Hashtbl.find_opt c.cst.skolem_rows id with
        | Some v -> tail v
        | None -> None)
    | RExtend (_, rest) -> tail rest
    | REmpty -> None
    | RVar { contents = RLink _ } -> assert false
  in
  let labels =
    List.map
      (fun (l : label) ->
        { Ty.name = l.name; payload = List.map (canon_ty c ~all) l.payload })
      (sorted_labels r)
  in
  { labels; tail = tail r }

(* What [canon] has numbered so far, as a scheme's [names]. *)
let canon_names c = List.sort compare c.names

(* And what the variables it has numbered need, as a scheme's [reqs]: a
   [Hashtbl.fold] visits them in no particular order, so they're sorted. *)
let needs_of c table =
  List.sort compare
    (Hashtbl.fold
       (fun id n acc -> List.map (fun r -> (n, r)) (needs c.cst id) @ acc)
       table [])

let canon_reqs c = needs_of c c.tys

(* And what the row variables it has numbered need, as its [row_reqs]. *)
let canon_row_reqs c = needs_of c c.rows

(* A type scheme in canonical form, numbered on its own. *)
let to_scheme st t : Ty.scheme =
  let c = canon st in
  let ty = canon_ty c ~all:false t in
  {
    ty;
    names = canon_names c;
    reqs = canon_reqs c;
    row_reqs = canon_row_reqs c;
    modes = [];
    defaults = [];
  }

(* A canonical type from an interface, with [vars] standing for its
   variables and [tails] for its row variables. *)
let rec of_ty ~vars ~tails (t : Ty.ty) =
  let go = of_ty ~vars ~tails in
  match t with
  | Con (p, args) -> TCon (p, List.map go args)
  | Variant (p, c, args) -> TVariant (p, c, List.map go args)
  | Errors e -> TErrors (of_row ~vars ~tails ~dep:false e)
  | Impl i ->
      let deps =
        List.map
          (fun (d : Ty.dep) -> { dpath = d.dpath; dargs = List.map go d.dargs })
          i.deps
      in
      let needs = of_row ~vars ~tails ~dep:true i.needs in
      let fails = of_row ~vars ~tails ~dep:false i.fails in
      TImpl { deps; over = i.over; needs; fails }
  | Fun (ps, r, e, u) ->
      TFun
        ( List.map (fun (p : Ty.param) -> { mode = p.mode; ty = go p.ty }) ps,
          go r,
          of_row ~vars ~tails ~dep:false e,
          of_row ~vars ~tails ~dep:true u )
  | Var n -> vars n
  | Error -> TError

(* [dep] says it's a row of dependencies, not of errors. *)
and of_row ~vars ~tails ~dep (r : Ty.row) =
  let tail = match r.tail with Some n -> tails n | None -> REmpty in
  extend
    (List.map
       (fun (l : Ty.label) ->
         {
           name = l.name;
           payload = List.map (of_ty ~vars ~tails) l.payload;
           dep;
           written = unmarked ();
         })
       r.labels)
    tail

(* [t], or if it's one of the module's own opaque types, what that's
   represented as, and so on until it's some other type (resolve.ml makes
   sure that ends). In its own module `type UserId = opaque Int` makes a
   `UserId` an `Int`, so wherever inference needs to know what kind of type
   something is (a record, a function, ...), it looks through [reveal]. *)
let rec reveal st t =
  match repr t with
  | TCon (p, args) as t -> (
      match Hashtbl.find_opt st.reps p with
      | Some rep ->
          reveal st (of_ty ~vars:(List.nth args) ~tails:(fun _ -> REmpty) rep)
      | None -> t)
  | t -> t

(* What each of the generic variables of the scheme [s] stands for in
   [t], a type of its shape: the part of [t] in its place, or for a row
   variable, the labels [t]'s row has besides the scheme's, ending in its
   tail. It's the substitution [instantiate] returns, for a type that
   isn't a copy of the scheme: a function of the group being checked is
   used at the type its declaration gives it, or its own, and is generic
   only once the group is done (Infer_lookup.lookup). A variable [t] has
   nothing in the place of, which only code with an error can do, stands
   for [TError], or a row of nothing. *)
let matching st s t =
  let tys = Hashtbl.create 8 and rows = Hashtbl.create 8 in
  (* a row's labels, and the row it ends in *)
  let rec split acc r =
    match repr_row r with
    | RExtend (l, rest) -> split (l :: acc) rest
    | r -> (List.rev acc, r)
  in
  let rec go s t =
    match (repr s, repr t) with
    | TVar { contents = Unbound (id, l) }, t when l = generic_level ->
        if not (Hashtbl.mem tys id) then Hashtbl.add tys id t
    | TCon (p, a), TCon (q, b) when p = q && List.length a = List.length b ->
        List.iter2 go a b
    | TVariant (p, c, a), TVariant (q, d, b)
      when p = q && c = d && List.length a = List.length b ->
        List.iter2 go a b
    | TFun (ps, r, e, u), TFun (qs, r', e', u')
      when List.length ps = List.length qs ->
        List.iter2 (fun p q -> go p.ty q.ty) ps qs;
        go r r';
        row rows e e';
        row rows u u'
    | TErrors e, TErrors e' -> row rows e e'
    | TImpl i, TImpl j
      when List.map (fun d -> d.dpath) i.deps
           = List.map (fun d -> d.dpath) j.deps ->
        List.iter2 (fun a b -> List.iter2 go a.dargs b.dargs) i.deps j.deps;
        row rows i.needs j.needs;
        row rows i.fails j.fails
    | (TCon _ as s), (TCon _ as t) ->
        (* one of the module's opaque types, and what it's represented
           as: [!=] says [reveal] made something else of one *)
        let s' = reveal st s and t' = reveal st t in
        if s' != s || t' != t then go s' t'
    | _ -> ()
  and row table s t =
    let ls, s_end = split [] s and lt, t_end = split [] t in
    (* a dependency's label of the same type arguments, where a generic
       one's are, or else the only one of its name *)
    let named (l : label) ks =
      match List.find_opt (fun (k : label) -> same_label k l) ks with
      | Some k -> Some k
      | None -> (
          match List.filter (fun (k : label) -> k.name = l.name) ks with
          | [ k ] -> Some k
          | _ -> None)
    in
    List.iter
      (fun (l : label) ->
        match named l lt with
        | Some k when List.length k.payload = List.length l.payload ->
            List.iter2 go l.payload k.payload
        | _ -> ())
      ls;
    match s_end with
    | RVar { contents = RUnbound (id, l) } when l = generic_level ->
        if not (Hashtbl.mem table id) then
          Hashtbl.add table id
            (extend (List.filter (fun k -> named k ls = None) lt) t_end)
    | _ -> ()
  in
  go s t;
  let g = generics s in
  let find table missing (id, _) =
    (id, Option.value (Hashtbl.find_opt table id) ~default:missing)
  in
  {
    tys = List.map (find tys TError) g.tys;
    rows = List.map (find rows REmpty) g.rows;
  }

(* An interface's type scheme as a scheme of this compilation: generic
   variables of its own, which [instantiate] copies at each use, each
   needing what the scheme says it does, row variables too. *)
let of_scheme st (s : Ty.scheme) =
  let memo table make n =
    match Hashtbl.find_opt table n with
    | Some v -> v
    | None ->
        let v = make n in
        Hashtbl.add table n v;
        v
  in
  let vars =
    memo (Hashtbl.create 8) (fun n ->
        let v = generic_var st in
        (match v with
        | TVar { contents = Unbound (id, _) } ->
            Option.iter (Hashtbl.replace st.hints id) (List.assoc_opt n s.names);
            List.iter
              (fun (m, r) -> if m = n then ignore (add_need st id r))
              s.reqs
        | _ -> ());
        v)
  in
  let tails =
    memo (Hashtbl.create 8) (fun n ->
        let r = generic_row st in
        (match r with
        | RVar { contents = RUnbound (id, _) } ->
            List.iter
              (fun (m, req) -> if m = n then ignore (add_need st id req))
              s.row_reqs
        | _ -> ());
        r)
  in
  of_ty ~vars ~tails s.ty

(* ---- printing ---- *)

(* A printer names variables consistently across everything printed with it,
   so one message reads `T` for the same variable throughout. Generic
   variables get names (their hint, or T, U, V, ...); variables inference
   hasn't solved yet print as `_`, and type parameters as themselves.

   Row tails are hidden unless [show_tail] picks them (by row variable id),
   and then print as `..e` (errors) or `..d` (dependencies). [names] says
   how to write each type's name (ty.ml).

   This is for error messages, while inference is still running. Each type
   is converted to canonical form as it's printed and printed by ty.ml's
   printer, so types print the same way here as in `ren types`. One [canon]
   and one [Ty.printer] serve every call, so a variable keeps its number,
   and so its name, across the whole message. *)
type printer = { canon : canon; ty_printer : Ty.printer }

let printer ?(show_tail = fun _ -> false) ~names (st : state) =
  let c = { (canon st) with for_message = true } in
  (* [Ty.printer] asks about a tail by its number; find the id that has it.
     There's only one, so the order [fold] visits them in doesn't matter. *)
  let numbered n =
    List.mem_assoc n c.named_rows
    || Hashtbl.fold
         (fun id m found -> found || (m = n && show_tail id))
         c.rows false
  in
  (* the scheme's names start empty: [to_ty] adds them as they're found *)
  let scheme : Ty.scheme =
    { ty = Error; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }
  in
  { canon = c; ty_printer = Ty.printer ~show_tail:numbered ~names scheme }

(* Bring the Ty printer up to date with what conversion has learned:
   the declared names of the variables, and the type parameters. *)
let sync pr =
  Ty.set_hints pr.ty_printer pr.canon.names;
  List.iter (fun (n, name) -> Ty.name pr.ty_printer n name) pr.canon.params;
  List.iter
    (fun (n, name) -> Ty.name_tail pr.ty_printer n name)
    pr.canon.named_rows

let to_ty pr t =
  let t = canon_ty pr.canon ~all:false t in
  sync pr;
  t

let reserve pr t = Ty.reserve pr.ty_printer (to_ty pr t)
let show pr t = Ty.show pr.ty_printer (to_ty pr t)

let show_row pr ~prefix ~sep ~kind r =
  Ty.show_row pr.ty_printer ~prefix ~sep ~kind (canon_row pr.canon ~all:false r)

(* A label as a row shows it, `Short(Int, Money)`. *)
let show_label pr (l : label) =
  let payload = List.map (to_ty pr) l.payload in
  Ty.show_label pr.ty_printer { name = l.name; payload }

(* A dependency's label as its type is written, `Chan<Int>`. *)
let show_dep pr (l : label) =
  let payload = List.map (to_ty pr) l.payload in
  Ty.show_dep pr.ty_printer (Ty.of_label { name = l.name; payload })

let show_effects pr e u =
  let e = canon_row pr.canon ~all:false e in
  let u = canon_row pr.canon ~all:false u in
  Ty.show_effects pr.ty_printer e u

(* The row variables in a type, by id: a function type's tails, and those
   of the function types inside it. *)
let rec row_vars t =
  let row r =
    let labels, tail = row_parts r in
    List.concat_map
      (fun (l : label) -> List.concat_map row_vars l.payload)
      labels
    @ Option.to_list tail
  in
  match repr t with
  | TVar _ | TSkol _ | TError -> []
  | TCon (_, args) | TVariant (_, _, args) -> List.concat_map row_vars args
  | TErrors e -> row e
  | TImpl i ->
      List.concat_map (fun d -> List.concat_map row_vars d.dargs) i.deps
      @ row i.needs @ row i.fails
  | TFun (ps, r, e, u) ->
      List.concat_map row_vars (r :: param_tys ps) @ row e @ row u

(* Does the type mention a type parameter? Error messages explain those. *)
let rec skolems t =
  match repr t with
  | TSkol (id, n) -> [ (id, n) ]
  | TVar _ | TError | TErrors _ | TImpl _ -> []
  | TCon (_, args) | TVariant (_, _, args) -> List.concat_map skolems args
  | TFun (ps, r, _, _) -> List.concat_map skolems (r :: param_tys ps)

(* Whether [v], a variable still unbound, is in [t]: a call says which of
   its arguments a variable of its callee's is in. *)
let mentions v t =
  match repr v with
  | TVar { contents = Unbound (id, _) } ->
      let rec go t =
        match repr t with
        | TVar { contents = Unbound (i, _) } -> i = id
        | TVar _ | TSkol _ | TError -> false
        | TCon (_, args) | TVariant (_, _, args) -> List.exists go args
        | TErrors e -> row e
        | TImpl i ->
            List.exists (fun d -> List.exists go d.dargs) i.deps
            || row i.needs || row i.fails
        | TFun (ps, r, e, u) ->
            List.exists go (r :: param_tys ps) || row e || row u
      and row r =
        List.exists
          (fun (l : label) -> List.exists go l.payload)
          (fst (row_parts r))
      in
      go t
  | _ -> false
