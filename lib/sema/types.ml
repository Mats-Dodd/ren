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
and impl = { deps : Path.t list; over : bool; needs : row; fails : row }
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

(* A row's label: an error's tag and its payload's types, or a dependency,
   whose payload is empty (ty.ml). *)
and label = {
  name : string;
  payload : ty list;
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
  TImpl { deps = List.sort_uniq compare deps; over; needs; fails }

(* A label's mark when it isn't written inside `Err`: one of its own,
   since a mark is changed when it's joined with another. *)
let unmarked () = ref (Mark None)
let dep name = { name; payload = []; written = unmarked () }

(* Follow links to the type a variable currently stands for, shortening the
   chain as it goes so later lookups are quick. *)
let rec repr t =
  match t with
  | TVar ({ contents = Link t' } as r) ->
      let t'' = repr t' in
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
     time proportional to them *)
  let rec go acc seen r =
    match repr_row r with
    | REmpty -> (List.rev acc, None)
    | RExtend (l, rest) when Names.mem l.name seen -> go acc seen rest
    | RExtend (l, rest) -> go (l :: acc) (Names.add l.name seen) rest
    | RVar { contents = RUnbound (id, _) } | RSkol (id, _) ->
        (List.rev acc, Some id)
    | RVar { contents = RLink _ } -> assert false (* repr_row followed it *)
  in
  go [] Names.empty r

(* Just the labels' names. *)
and row_names r = List.map (fun l -> l.name) (fst (row_parts r))

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
    | TErrors e -> TErrors (row e)
    | TImpl i -> TImpl { i with needs = row i.needs; fails = row i.fails }
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
    | TCon (_, args) -> List.iter walk args
    | TErrors e -> walk_row e
    | TImpl i ->
        walk_row i.needs;
        walk_row i.fails
    | TFun (ps, r, e, u) ->
        List.iter (fun p -> walk p.ty) ps;
        walk r;
        walk_row e;
        walk_row u
  and walk_row r =
    List.iter
      (fun l -> List.iter walk l.payload)
      (List.sort_uniq
         (fun (a : label) b -> String.compare a.name b.name)
         (fst (row_parts r)));
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
    | TErrors e -> TErrors (row e)
    | TImpl i ->
        (* `let`s fix the order: OCaml evaluates a record's fields in no
           order it promises *)
        let needs = row i.needs in
        let fails = row i.fails in
        TImpl { i with needs; fails }
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
    | TErrors e -> TErrors (row e)
    | TImpl i ->
        (* `let`s fix the order: OCaml evaluates a record's fields in no
           order it promises *)
        let needs = row i.needs in
        let fails = row i.fails in
        TImpl { i with needs; fails }
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
  | TErrors e -> Errors (canon_row c ~all e)
  | TImpl i ->
      let needs = canon_row c ~all i.needs in
      let fails = canon_row c ~all i.fails in
      Impl { deps = i.deps; over = i.over; needs; fails }
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
    List.sort_uniq
      (fun (a : label) b -> String.compare a.name b.name)
      (fst (row_parts r))
  in
  let labels =
    List.map
      (fun (l : label) ->
        { Ty.name = l.name; payload = List.map (canon_ty c ~all) l.payload })
      labels
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
  }

(* A canonical type from an interface, with [vars] standing for its
   variables and [tails] for its row variables. *)
let rec of_ty ~vars ~tails (t : Ty.ty) =
  let go = of_ty ~vars ~tails in
  match t with
  | Con (p, args) -> TCon (p, List.map go args)
  | Errors e -> TErrors (of_row ~vars ~tails e)
  | Impl i ->
      let needs = of_row ~vars ~tails i.needs in
      let fails = of_row ~vars ~tails i.fails in
      TImpl { deps = i.deps; over = i.over; needs; fails }
  | Fun (ps, r, e, u) ->
      TFun
        ( List.map (fun (p : Ty.param) -> { mode = p.mode; ty = go p.ty }) ps,
          go r,
          of_row ~vars ~tails e,
          of_row ~vars ~tails u )
  | Var n -> vars n
  | Error -> TError

and of_row ~vars ~tails (r : Ty.row) =
  let tail = match r.tail with Some n -> tails n | None -> REmpty in
  extend
    (List.map
       (fun (l : Ty.label) ->
         {
           name = l.name;
           payload = List.map (of_ty ~vars ~tails) l.payload;
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
    | TFun (ps, r, e, u), TFun (qs, r', e', u')
      when List.length ps = List.length qs ->
        List.iter2 (fun p q -> go p.ty q.ty) ps qs;
        go r r';
        row rows e e';
        row rows u u'
    | TErrors e, TErrors e' -> row rows e e'
    | TImpl i, TImpl j when i.deps = j.deps ->
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
    let named (l : label) =
      List.find_opt (fun (k : label) -> k.name = l.name)
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
    { ty = Error; names = []; reqs = []; row_reqs = [] }
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
  | TCon (_, args) -> List.concat_map row_vars args
  | TErrors e -> row e
  | TImpl i -> row i.needs @ row i.fails
  | TFun (ps, r, e, u) ->
      List.concat_map row_vars (r :: param_tys ps) @ row e @ row u

(* Does the type mention a type parameter? Error messages explain those. *)
let rec skolems t =
  match repr t with
  | TSkol (id, n) -> [ (id, n) ]
  | TVar _ | TError | TErrors _ | TImpl _ -> []
  | TCon (_, args) -> List.concat_map skolems args
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
        | TCon (_, args) -> List.exists go args
        | TErrors e -> row e
        | TImpl i -> row i.needs || row i.fails
        | TFun (ps, r, e, u) ->
            List.exists go (r :: param_tys ps) || row e || row u
      and row r =
        List.exists
          (fun (l : label) -> List.exists go l.payload)
          (fst (row_parts r))
      in
      go t
  | _ -> false
