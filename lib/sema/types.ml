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
and row = REmpty | RExtend of string * row | RVar of rvar ref
and rvar = RUnbound of int * int  (** id, level *) | RLink of row

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
}

let new_state () = { level = 1; last_id = 0; hints = Hashtbl.create 16 }
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
let array t = TCon (Path.prelude "Array", [ t ])
let read ty = { mode = Read; ty }
let param_tys ps = List.map (fun p -> p.ty) ps

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
let row_parts r =
  let rec go acc r =
    match repr_row r with
    | REmpty -> (List.rev acc, None)
    | RExtend (l, rest) -> go (l :: acc) rest
    | RVar { contents = RUnbound (id, _) } -> (List.rev acc, Some id)
    | RVar { contents = RLink _ } -> assert false (* repr_row followed it *)
  in
  go [] r

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
              v)
    | TCon (n, args) -> TCon (n, List.map go args)
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
    | RExtend (l, rest) -> RExtend (l, row rest)
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
    | RExtend (l, rest) -> RExtend (l, row rest)
  in
  go t

(* ---- canonical types ---- *)

(* A type scheme in canonical form (ty.ml): every generic variable numbered
   by where it first appears. A variable inference never solved, outside
   any scheme, can only come from code with an error, so it becomes
   [Error]. *)
let to_scheme st t : Ty.scheme =
  let tys = Hashtbl.create 8 and rows = Hashtbl.create 8 in
  let number table id =
    match Hashtbl.find_opt table id with
    | Some n -> n
    | None ->
        let n = Hashtbl.length table in
        Hashtbl.add table id n;
        n
  in
  let names = ref [] in
  let rec go t : Ty.ty =
    match repr t with
    | TVar { contents = Unbound (id, l) } when l = generic_level ->
        let n = number tys id in
        (match Hashtbl.find_opt st.hints id with
        | Some h when not (List.mem_assoc n !names) -> names := (n, h) :: !names
        | _ -> ());
        Var n
    | TVar _ | TSkol _ | TError -> Error
    | TCon (p, args) -> Con (p, List.map go args)
    | TFun (ps, r, e, u) ->
        (* `let`s fix the order of first appearance: OCaml evaluates a
           constructor's arguments right to left *)
        let ps = List.map (fun p -> { Ty.mode = p.mode; ty = go p.ty }) ps in
        let r = go r in
        let e = row e in
        let u = row u in
        Fun (ps, r, e, u)
  and row r : Ty.row =
    (* only a generic tail stands for "and possibly more" *)
    let rec tail r =
      match repr_row r with
      | RVar { contents = RUnbound (id, l) } ->
          if l = generic_level then Some (number rows id) else None
      | RExtend (_, rest) -> tail rest
      | REmpty -> None
      | RVar { contents = RLink _ } -> assert false
    in
    {
      labels = List.sort_uniq String.compare (fst (row_parts r));
      tail = tail r;
    }
  in
  let ty = go t in
  { ty; names = List.sort compare !names }

(* A canonical type from an interface, with [vars] standing for its
   variables and [tails] for its row variables. *)
let rec of_ty ~vars ~tails (t : Ty.ty) =
  match t with
  | Con (p, args) -> TCon (p, List.map (of_ty ~vars ~tails) args)
  | Fun (ps, r, e, u) ->
      TFun
        ( List.map
            (fun (p : Ty.param) ->
              { mode = p.mode; ty = of_ty ~vars ~tails p.ty })
            ps,
          of_ty ~vars ~tails r,
          of_row ~tails e,
          of_row ~tails u )
  | Var n -> vars n
  | Error -> TError

and of_row ~tails (r : Ty.row) =
  let tail = match r.tail with Some n -> tails n | None -> REmpty in
  List.fold_right (fun l rest -> RExtend (l, rest)) r.labels tail

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
   so one message or signature reads `T` for the same variable throughout.
   Generic variables get names (their hint, or T, U, V, ...); variables
   inference hasn't solved yet print as `_`.

   Row tails are hidden unless [show_tail] picks them, and then print as
   `..e` (errors) or `..d` (dependencies). Type names are written as they'd
   be written in module [home] (path.ml).

   This is for error messages, while inference is still running; `ren
   types` prints the canonical types of ty.ml instead. *)
type printer = {
  home : string;
  hints : (int, string) Hashtbl.t;  (** from the [state] *)
  names : (int, string) Hashtbl.t;
  mutable order : string list;  (** names handed out, most recent first *)
  reserved : (string, unit) Hashtbl.t;
  show_tail : int -> bool;
  tail_names : (int, string) Hashtbl.t;
}

let printer ?(show_tail = fun _ -> false) ~home (st : state) =
  {
    home;
    hints = st.hints;
    names = Hashtbl.create 8;
    order = [];
    reserved = Hashtbl.create 8;
    show_tail;
    tail_names = Hashtbl.create 4;
  }

let auto_names = Ty.auto_names
let taken pr n = Hashtbl.mem pr.reserved n || List.mem n pr.order

let var_name pr id =
  match Hashtbl.find_opt pr.names id with
  | Some n -> n
  | None ->
      let n =
        match Hashtbl.find_opt pr.hints id with
        | Some h when not (List.mem h pr.order) -> h
        | _ -> List.find (fun n -> not (taken pr n)) auto_names
      in
      Hashtbl.add pr.names id n;
      pr.order <- n :: pr.order;
      n

(* Keep the hinted names of a type's variables free, so an automatic name
   handed out first doesn't take them. *)
let rec reserve pr t =
  match repr t with
  | TVar { contents = Unbound (id, _) } ->
      Option.iter
        (fun h -> Hashtbl.replace pr.reserved h ())
        (Hashtbl.find_opt pr.hints id)
  | TVar { contents = Link _ } | TSkol _ | TError -> ()
  | TCon (_, args) -> List.iter (reserve pr) args
  | TFun (ps, r, _, _) -> List.iter (reserve pr) (r :: param_tys ps)

let tail_name pr id kind =
  match Hashtbl.find_opt pr.tail_names id with
  | Some n -> n
  | None ->
      let existing = Hashtbl.fold (fun _ n acc -> n :: acc) pr.tail_names [] in
      let rec pick i =
        let n = if i = 1 then kind else kind ^ string_of_int i in
        if List.mem n existing then pick (i + 1) else n
      in
      let n = pick 1 in
      Hashtbl.add pr.tail_names id n;
      n

let show_row pr ~prefix ~sep ~kind r =
  let labels, tail = row_parts r in
  let labels = List.sort_uniq String.compare labels in
  let tail =
    match tail with
    | Some id when pr.show_tail id -> [ ".." ^ tail_name pr id kind ]
    | _ -> []
  in
  match labels @ tail with
  | [] -> ""
  | parts -> prefix ^ String.concat sep parts

let rec show pr t =
  match repr t with
  | TCon (p, []) -> Path.show ~home:pr.home p
  | TCon (p, args) ->
      Path.show ~home:pr.home p ^ "<"
      ^ String.concat ", " (List.map (show pr) args)
      ^ ">"
  | TSkol (_, n) -> n
  | TError -> "_"
  | TVar { contents = Unbound (id, l) } ->
      if l = generic_level then var_name pr id else "_"
  | TVar { contents = Link _ } -> assert false
  | TFun (ps, r, e, u) ->
      (* `let`s fix the order variables are named in: OCaml evaluates the
         operands of `^` right to left *)
      let ps = List.map (show_param pr) ps in
      let r = show_ret pr r in
      "fn(" ^ String.concat ", " ps ^ ")" ^ r ^ show_effects pr e u

and show_param pr p =
  match p.mode with Inout -> "inout " ^ show pr p.ty | Read -> show pr p.ty

(* ` -> R`, or nothing for Unit. A returned function with effects is
   parenthesized, so it's clear whose effects they are. *)
and show_ret pr r =
  match repr r with
  | TCon (p, []) when p = Path.prelude "Unit" -> ""
  | TFun (_, _, e, u) as f ->
      let s = show pr f in
      if show_effects pr e u = "" then " -> " ^ s else " -> (" ^ s ^ ")"
  | r -> " -> " ^ show pr r

and show_effects pr e u =
  show_row pr ~prefix:" ! " ~sep:" | " ~kind:"e" e
  ^ show_row pr ~prefix:" uses " ~sep:", " ~kind:"d" u

(* Does the type mention a type parameter? Error messages explain those. *)
let rec skolems t =
  match repr t with
  | TSkol (id, n) -> [ (id, n) ]
  | TVar _ | TError -> []
  | TCon (_, args) -> List.concat_map skolems args
  | TFun (ps, r, _, _) -> List.concat_map skolems (r :: param_tys ps)
