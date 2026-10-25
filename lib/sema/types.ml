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
and tvar = Unbound of int * int  (** id, level *) | Link of ty
and row = REmpty | RExtend of label * row | RVar of rvar ref
and rvar = RUnbound of int * int  (** id, level *) | RLink of row

(* A row's label: an error's tag and its payload's types, or a dependency,
   whose payload is empty (ty.ml). *)
and label = { name : string; payload : ty list }

let generic_level = max_int

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
let bool = TCon (Path.prelude "Bool", [])
let unit = TCon (Path.prelude "Unit", [])
let str = TCon (Path.prelude "Str", [])
let array t = TCon (Path.prelude "Array", [ t ])
let read ty = { mode = Read; ty }
let param_tys ps = List.map (fun p -> p.ty) ps
let dep name = { name; payload = [] }

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

(* A row's labels and, if it's open, the id of its tail variable. *)
let rec row_parts r =
  let rec go acc r =
    match repr_row r with
    | REmpty -> (List.rev acc, None)
    | RExtend (l, rest) -> go (l :: acc) rest
    | RVar { contents = RUnbound (id, _) } -> (List.rev acc, Some id)
    | RVar { contents = RLink _ } -> assert false (* repr_row followed it *)
  in
  go [] r

(* Just the labels' names. *)
and row_names r = List.map (fun l -> l.name) (fst (row_parts r))

(* The row variable a row ends in, if it's open. *)
let row_tail r = snd (row_parts r)

(* Close [r]: it has exactly the labels it has now. *)
let rec close_row r =
  match repr_row r with
  | RExtend (_, rest) -> close_row rest
  | RVar ({ contents = RUnbound _ } as cell) -> cell := RLink REmpty
  | RVar { contents = RLink _ } | REmpty -> ()

(* A row of [labels], ending in [tail]. *)
let extend labels tail =
  List.fold_right (fun l rest -> RExtend (l, rest)) labels tail

(* ---- generalizing and instantiating ---- *)

(* Make generic every variable created deeper than the current level, and
   replace the function's own type parameters ([skolems], as id and name)
   with generic variables too. The result is the function's type scheme. *)
let generalize st ~skolems t =
  let table = Hashtbl.create 8 in
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
              (match v with
              | TVar { contents = Unbound (vid, _) } ->
                  Hashtbl.replace st.hints vid name
              | _ -> ());
              Hashtbl.add table id v;
              Hashtbl.replace st.skolem_vars id v;
              v)
    | TCon (n, args) -> TCon (n, List.map go args)
    | TErrors e -> TErrors (row e)
    | TFun (ps, r, e, u) -> TFun (List.map param ps, go r, row e, row u)
    | TError -> TError
  and param p = { p with ty = go p.ty }
  and row r =
    match repr_row r with
    | RVar ({ contents = RUnbound (id, l) } as cell) as r ->
        if l > st.level then cell := RUnbound (id, generic_level);
        r
    | RVar { contents = RLink _ } -> assert false
    | REmpty -> REmpty
    | RExtend (l, rest) ->
        RExtend ({ l with payload = List.map go l.payload }, row rest)
  in
  go t

(* A copy of a type scheme with fresh variables in place of the generic
   ones, so each use of a function can pick its own types. *)
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
    | TFun (ps, r, e, u) -> TFun (List.map param ps, go r, row e, row u)
  and param p = { p with ty = go p.ty }
  and row r =
    match repr_row r with
    | RVar { contents = RUnbound (id, l) } when l = generic_level -> (
        match Hashtbl.find_opt rows id with
        | Some v -> v
        | None ->
            let v = fresh_row st in
            Hashtbl.add rows id v;
            v)
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
}

let canon st =
  {
    cst = st;
    tys = Hashtbl.create 8;
    rows = Hashtbl.create 8;
    names = [];
    for_message = false;
    params = [];
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

(* A type scheme in canonical form, numbered on its own. *)
let to_scheme st t : Ty.scheme =
  let c = canon st in
  let ty = canon_ty c ~all:false t in
  { ty; names = canon_names c }

(* A canonical type from an interface, with [vars] standing for its
   variables and [tails] for its row variables. *)
let rec of_ty ~vars ~tails (t : Ty.ty) =
  match t with
  | Con (p, args) -> TCon (p, List.map (of_ty ~vars ~tails) args)
  | Errors e -> TErrors (of_row ~vars ~tails e)
  | Fun (ps, r, e, u) ->
      TFun
        ( List.map
            (fun (p : Ty.param) ->
              { mode = p.mode; ty = of_ty ~vars ~tails p.ty })
            ps,
          of_ty ~vars ~tails r,
          of_row ~vars ~tails e,
          of_row ~vars ~tails u )
  | Var n -> vars n
  | Error -> TError

and of_row ~vars ~tails (r : Ty.row) =
  let tail = match r.tail with Some n -> tails n | None -> REmpty in
  extend
    (List.map
       (fun (l : Ty.label) ->
         { name = l.name; payload = List.map (of_ty ~vars ~tails) l.payload })
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

(* An interface's type scheme as a scheme of this compilation: generic
   variables of its own, which [instantiate] copies at each use. *)
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
        (match (v, List.assoc_opt n s.names) with
        | TVar { contents = Unbound (id, _) }, Some h ->
            Hashtbl.replace st.hints id h
        | _ -> ());
        v)
  in
  let tails = memo (Hashtbl.create 8) (fun _ -> generic_row st) in
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
    Hashtbl.fold
      (fun id m found -> found || (m = n && show_tail id))
      c.rows false
  in
  (* the scheme's names start empty: [to_ty] adds them as they're found *)
  let scheme : Ty.scheme = { ty = Error; names = [] } in
  { canon = c; ty_printer = Ty.printer ~show_tail:numbered ~names scheme }

(* Bring the Ty printer up to date with what conversion has learned:
   the declared names of the variables, and the type parameters. *)
let sync pr =
  pr.ty_printer.hints <- pr.canon.names;
  List.iter (fun (n, name) -> Ty.name pr.ty_printer n name) pr.canon.params

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
  | TFun (ps, r, e, u) ->
      List.concat_map row_vars (r :: param_tys ps) @ row e @ row u

(* Does the type mention a type parameter? Error messages explain those. *)
let rec skolems t =
  match repr t with
  | TSkol (id, n) -> [ (id, n) ]
  | TVar _ | TError | TErrors _ -> []
  | TCon (_, args) -> List.concat_map skolems args
  | TFun (ps, r, _, _) -> List.concat_map skolems (r :: param_tys ps)
