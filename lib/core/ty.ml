(* Types in canonical form: what leaves the type checker.

   Inference works on mutable types (types.ml), whose variables are cells
   that get filled in as it learns more. Once a function's type is worked
   out, it's converted to a [Ty.ty], which is an ordinary immutable value:

   - variables are numbered by where they first appear, reading the type
     left to right, so `fn(T, U) -> T` is always `fn(Var 0, Var 1) -> Var 0`
   - the labels of a row are sorted
   - there are no cells, levels or ids from the checker's run

   So the same program always gives equal [Ty] values, however many other
   programs were checked before it in the same process, and in whatever
   order. That's what makes a type safe to cache or compare
   (module-build.md: "types leave the checker in a canonical form"). *)

type mode = Ast.mode = Read | Inout

type ty =
  | Con of Path.t * ty list  (** [Int], [Option<Int>], [User] *)
  | Fun of param list * ty * row * row * lams
      (** params, result, errors, uses, and its lambda set *)
  | Var of int
      (** a type variable. In a scheme, a generic one, numbered by first
          appearance; in a type declaration, the declaration's parameter at that
          position (`T` in `Option<T>` is [Var 0]) *)
  | Errors of row
      (** an error set as a type argument, [! Short(Int) | Frozen], which only
          [Result<T, ! ...>] takes (errors.md, "Keeping an error") *)
  | Uses of row
      (** what an implementation needs, as the one argument of its dependency's
          type: [Clock uses Os] is [Con (Clock, [Uses Os])] (deps.md,
          "Implementations"). Nothing else takes one *)
  | Error  (** the type of code that had an error, already reported *)

and param = { mode : mode; ty : ty }

and row = {
  labels : label list;  (** sorted by name *)
  tail : int option;
      (** [None]: exactly these labels. [Some n]: these and possibly more,
          standing for row variable [n] (numbered apart from type variables) *)
}

(* A function type's lambda set (compiler.md, "The facts"): which code a
   value of the type can run. [ids] are the identities of the lambdas and
   top-level functions known to flow to it ([lambda_id], [global_id]),
   sorted, each once; [lvar] is the lambda-set variable that stands for
   the rest, numbered apart from type and row variables. A set is like a
   row whose labels have no payload, and it's always open: as far as this
   stage knows, a function value can be one nothing has listed yet, and no
   pass reads them until specialization.

   They're hidden: no message and nothing `ren types` prints shows one,
   and only [printer]'s [show_lams] does, for debugging. In canonical form
   [lvar] is always [Some n]. [None] is only in a type written in a
   declaration, before [canonical]: a set nothing else shares, which
   [canonical] numbers apart from every other. *)
and lams = { ids : string list; lvar : int option }

(* A row's label: an error's tag and its payload's types, `Short(Int)`, or
   a dependency, whose payload is always empty. A tag is its name and its
   payload's types, in order, so one row never has two labels of the same
   name (module-build.md, "Error tags have no home"). A dependency is a
   type, so its label is its path, written in full ([dep_label]): two
   modules' `Users` are two dependencies. *)
and label = { name : string; payload : ty list }

(* A function's type, for every choice of its variables. [names] are the
   names its variables were declared with, like the `T` of `fn id<T>`, so
   `ren types` can print them back.

   [reqs] are what the function needs of its variables: [(0, "eq")] says
   variable 0 must have `==`, which `ren types` prints as
   `same<T has eq>` (operators.md, "Generic code"). They're sorted, as
   [names] are, so equal schemes are equal values. They're never written:
   inference finds them in the function's body, and an interface keeps
   them (iface.ml).

   [row_reqs] are the same for its row variables: [(0, "eq")] says every
   tag row variable 0 stands for must have `==`, since the function
   compares what something it's given fails with, `same(attempt g(),
   attempt g())`. Nothing is passed for one at runtime (core.ml): it's
   only checked where the function is used, as a type variable's is, so a
   tag that holds a function never reaches its `==`. `ren types` prints
   it as `..e has eq`. *)
type scheme = {
  ty : ty;
  names : (int * string) list;
  reqs : (int * string) list;
  row_reqs : (int * string) list;
}

(* What one use of a scheme picks for its variables: its type arguments.
   The n-th of [tys] stands for [Var n], and the n-th of [rows] for the
   row variable [n], whose row is that one's labels added to the scheme's,
   ending in its tail. Typed Core puts them on each use of a polymorphic
   function (core.ml), and Core Lint checks the use's type is the scheme's
   with them put in. The n-th of [lams] is what lambda-set variable [n]
   stands for, the same way: its identities, added to the set's. *)
type args = { tys : ty list; rows : row list; lams : lams list }

let int = Con (Path.prelude "Int", [])
let bool = Con (Path.prelude "Bool", [])
let unit = Con (Path.prelude "Unit", [])
let str = Con (Path.prelude "Str", [])
let array t = Con (Path.prelude "Array", [ t ])
let read ty = { mode = Read; ty }
let closed = { labels = []; tail = None }
let label name = { name; payload = [] }

(* The lambda set of a function type written in a declaration: one of its
   own, which nothing else shares, that [canonical] numbers. *)
let any_lams = { ids = []; lvar = None }

(* The identity a top-level function, a member or an intrinsic has in a
   lambda set: its path, written in full, `shop/cart.total`. *)
let global_id p = Path.full p

(* And the [n]-th lambda of the top-level function [p], counting from 1
   in the order inference meets them, `main.main#2`: its function's path
   and its place in it, so an edit elsewhere in the module doesn't change
   it. *)
let lambda_id p n = Path.full p ^ "#" ^ string_of_int n

(* The label of the dependency declared at [p]: `Clock`, the prelude's, or
   `shop/store.Users`, another module's. [dep_path] reads it back: a
   module's path has no `.` in it, so the last one ends it. *)
let dep_label p = Path.full p

let dep_path label =
  match String.rindex_opt label '.' with
  | Some i ->
      Path.make (String.sub label 0 i)
        (String.sub label (i + 1) (String.length label - i - 1))
  | None -> Path.prelude label

(* Labels sorted by name, as a row keeps them. *)
let sort_labels ls = List.sort (fun a b -> String.compare a.name b.name) ls

(* The row variables inside a type. *)
let rec tails t =
  match t with
  | Var _ | Error -> []
  | Con (_, args) -> List.concat_map tails args
  | Errors e | Uses e -> row_tails e
  | Fun (ps, r, e, u, _) ->
      List.concat_map (fun (p : param) -> tails p.ty) ps
      @ tails r @ row_tails e @ row_tails u

and row_tails r =
  List.concat_map (fun l -> List.concat_map tails l.payload) r.labels
  @ Option.to_list r.tail

(* The lambda-set variables inside a type, in the order they appear. *)
let rec lam_vars t =
  match t with
  | Var _ | Error -> []
  | Con (_, args) -> List.concat_map lam_vars args
  | Errors e | Uses e -> row_lam_vars e
  | Fun (ps, r, e, u, l) ->
      List.concat_map (fun (p : param) -> lam_vars p.ty) ps
      @ lam_vars r @ row_lam_vars e @ row_lam_vars u @ Option.to_list l.lvar

and row_lam_vars r =
  List.concat_map (fun l -> List.concat_map lam_vars l.payload) r.labels

(* [t] with every lambda set one of its own, [any_lams]: what it is
   without them. *)
let rec without_lams t =
  match t with
  | Var _ | Error -> t
  | Con (p, args) -> Con (p, List.map without_lams args)
  | Errors e -> Errors (row_without_lams e)
  | Uses u -> Uses (row_without_lams u)
  | Fun (ps, r, e, u, _) ->
      Fun
        ( List.map (fun (p : param) -> { p with ty = without_lams p.ty }) ps,
          without_lams r,
          row_without_lams e,
          row_without_lams u,
          any_lams )

and row_without_lams r =
  {
    r with
    labels =
      List.map
        (fun l -> { l with payload = List.map without_lams l.payload })
        r.labels;
  }

(* The type arguments that give back a canonical type itself: [Var n]
   for each of its type variables, for each row variable a row of no
   labels ending in that variable, and for each lambda-set variable a set
   of nothing ending in it. They're how a function is used at its
   own type, as `$start` calls `main`. A canonical type numbers its
   variables from 0 without gaps, so how many there are is one more than
   the largest. *)
let own_args t =
  let rec vars = function
    | Var n -> [ n ]
    | Error -> []
    | Con (_, args) -> List.concat_map vars args
    | Errors e | Uses e -> row_vars e
    | Fun (ps, r, e, u, _) ->
        List.concat_map (fun (p : param) -> vars p.ty) ps
        @ vars r @ row_vars e @ row_vars u
  and row_vars r =
    List.concat_map (fun l -> List.concat_map vars l.payload) r.labels
  in
  let count ns = 1 + List.fold_left max (-1) ns in
  {
    tys = List.init (count (vars t)) (fun n -> Var n);
    rows = List.init (count (tails t)) (fun n -> { labels = []; tail = Some n });
    lams = List.init (count (lam_vars t)) (fun n -> { ids = []; lvar = Some n });
  }

(* A scheme with its variables renumbered by where they first appear,
   reading left to right, as inference numbers them: type variables, row
   variables and lambda-set variables separately. [names], [reqs] and
   [row_reqs] follow their variables. A lambda set of its own
   ([any_lams]) gets a variable nothing else has. *)
let canonical (s : scheme) =
  let number table n =
    match List.assoc_opt n !table with
    | Some m -> m
    | None ->
        let m = List.length !table in
        table := (n, m) :: !table;
        m
  in
  let tys = ref [] and rows = ref [] and lams = ref [] in
  (* a set of its own takes a number no variable of the type has *)
  let own = ref 0 in
  let lam_var = function
    | Some n -> number lams n
    | None ->
        decr own;
        number lams !own
  in
  let rec go = function
    | Var n -> Var (number tys n)
    | Error -> Error
    | Con (p, args) -> Con (p, List.map go args)
    | Errors e -> Errors (row e)
    | Uses u -> Uses (row u)
    | Fun (ps, r, e, u, l) ->
        (* `let`s fix the order of first appearance: OCaml evaluates a
           constructor's arguments right to left *)
        let ps = List.map (fun (p : param) -> { p with ty = go p.ty }) ps in
        let r = go r in
        let e = row e in
        let u = row u in
        let l =
          { ids = List.sort_uniq compare l.ids; lvar = Some (lam_var l.lvar) }
        in
        Fun (ps, r, e, u, l)
  (* the labels' payloads, in order of name, then the tail *)
  and row r =
    let labels =
      List.map
        (fun l -> { l with payload = List.map go l.payload })
        (sort_labels r.labels)
    in
    { labels; tail = Option.map (number rows) r.tail }
  in
  let ty = go s.ty in
  (* a name or requirement whose variable the type no longer has goes *)
  let renumber table pairs =
    List.sort compare
      (List.filter_map
         (fun (n, h) -> Option.map (fun m -> (m, h)) (List.assoc_opt n !table))
         pairs)
  in
  {
    ty;
    names = renumber tys s.names;
    reqs = renumber tys s.reqs;
    row_reqs = renumber rows s.row_reqs;
  }

(* A scheme without its lambda sets: each one of its own, numbered apart.
   It's what an interface states (iface.ml): a function type written in a
   declaration says nothing of which lambdas flow to it, and inference's
   sets depend on the module's bodies, which an interface mustn't
   (compiler.md, "Lambda sets"). *)
let forget_lams (s : scheme) = canonical { s with ty = without_lams s.ty }

(* ---- printing ----

   A printer names variables consistently across everything printed with
   it. A variable gets the name it was declared with if that's still free,
   otherwise the next of T, U, V, ...

   Row tails are hidden unless [show_tail] picks them, and then print as
   `..e` (errors) or `..d` (dependencies). Lambda sets are hidden unless
   [show_lams] says to show them, which only a debug printer does. [names] says how to write each
   type's name: the shortest way the module the type is shown in could
   write it (Resolve.type_name), so a message or `ren types` shows what
   you'd write there.

   Error messages print inference's types with this printer too: types.ml
   converts each one to a [Ty.ty] as it's printed, adding to [hints] as it
   goes, so one printer can name variables across a whole message. *)
type printer = {
  type_name : Path.t -> string;
  mutable hints : (int * string) list;  (** declared names, by variable *)
  names : (int, string) Hashtbl.t;
  mutable order : string list;  (** names handed out, most recent first *)
  mutable reserved : string list;
  show_tail : int -> bool;
  tail_names : (int, string) Hashtbl.t;
  show_lams : bool;
}

let printer ?(show_tail = fun _ -> false) ?(show_lams = false) ~names
    (s : scheme) =
  {
    show_lams;
    type_name = names;
    hints = s.names;
    names = Hashtbl.create 8;
    order = [];
    reserved = [];
    show_tail;
    tail_names = Hashtbl.create 4;
  }

let auto_names =
  List.init 7 (fun i -> String.make 1 "TUVWXYZ".[i])
  @ List.init 20 (fun i -> "T" ^ string_of_int (i + 1))

let taken pr n = List.mem n pr.reserved || List.mem n pr.order

let var_name pr id =
  match Hashtbl.find_opt pr.names id with
  | Some n -> n
  | None ->
      let n =
        match List.assoc_opt id pr.hints with
        | Some h when not (List.mem h pr.order) -> h
        | _ -> List.find (fun n -> not (taken pr n)) auto_names
      in
      Hashtbl.add pr.names id n;
      pr.order <- n :: pr.order;
      n

(* Replace the declared names the printer knows. types.ml's printer adds
   to them as it converts types for a message. *)
let set_hints pr hints = pr.hints <- hints

(* Give variable [id] the name [n] up front. Unlike a name handed out by
   [var_name], it doesn't take [n] from other variables. types.ml uses it
   for a type parameter like `T` while its function is being checked: the
   parameter prints as itself, whatever else is named `T`. *)
let name pr id n = Hashtbl.replace pr.names id n

(* Keep the declared names of a type's variables free, so an automatic name
   handed out first doesn't take them. *)
let rec reserve pr t =
  match t with
  | Var id ->
      Option.iter
        (fun h -> pr.reserved <- h :: pr.reserved)
        (List.assoc_opt id pr.hints)
  | Error -> ()
  | Con (_, args) -> List.iter (reserve pr) args
  | Errors e -> List.iter (reserve_label pr) e.labels
  | Uses _ -> ()
  | Fun (ps, r, e, _, _) ->
      List.iter (reserve pr) (r :: List.map (fun (p : param) -> p.ty) ps);
      List.iter (reserve_label pr) e.labels

and reserve_label pr l = List.iter (reserve pr) l.payload

(* Give tail [id] the name [n] up front, as [name] does a variable: a named
   row prints as itself, `..d`. *)
let name_tail pr id n = Hashtbl.replace pr.tail_names id n

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

(* A row: its labels, each with its payload, `Short(Int, Money)`, then its
   tail if it's shown. *)
let rec show_row pr ~prefix ~sep ~kind r =
  let tail =
    match r.tail with
    | Some id when pr.show_tail id -> [ ".." ^ tail_name pr id kind ]
    | _ -> []
  in
  (* a dependency is written as its type is *)
  let label l =
    if kind = "d" then pr.type_name (dep_path l.name) else show_label pr l
  in
  match List.map label r.labels @ tail with
  | [] -> ""
  | parts -> prefix ^ String.concat sep parts

and show_label pr l =
  match l.payload with
  | [] -> l.name
  | ps -> l.name ^ "(" ^ String.concat ", " (List.map (show pr) ps) ^ ")"

and show pr t =
  match t with
  | Con (p, [ Uses u ]) ->
      (* an implementation, and what it needs *)
      pr.type_name p ^ show_row pr ~prefix:" uses " ~sep:", " ~kind:"d" u
  | Con (p, []) -> pr.type_name p
  | Con (p, args) -> pr.type_name p ^ "<" ^ show_list pr args ^ ">"
  | Errors e -> (
      (* an empty set, which nothing fails with, is just the `!` *)
      match show_row pr ~prefix:"! " ~sep:" | " ~kind:"e" e with
      | "" -> "!"
      | s -> s)
  | Uses u -> show_row pr ~prefix:"uses " ~sep:", " ~kind:"d" u
  | Error -> "_"
  | Var id -> var_name pr id
  | Fun (ps, r, e, u, l) ->
      (* `let`s fix the order variables are named in: OCaml evaluates the
         operands of `^` right to left *)
      let ps =
        commas
          (List.map
             (fun (p : param) ->
               let s = show_param pr p in
               (s, ends_in_uses pr p.ty))
             ps)
      in
      let r = show_ret pr r in
      "fn(" ^ ps ^ ")" ^ r ^ show_effects pr e u ^ show_lams pr l

(* A function type's parameters, each shown, and whether it ends in a
   `uses` list, which a comma could go on: one that does is in parentheses
   unless it's the last, `fn((fn() uses Clock, Random), Int)`. *)
and commas shown =
  let n = List.length shown in
  String.concat ", "
    (List.mapi
       (fun i (s, trails) -> if trails && i < n - 1 then "(" ^ s ^ ")" else s)
       shown)

(* Type arguments: in one, a comma after a `uses` list ends the argument,
   so a list of several dependencies is in parentheses,
   `Box<(fn() uses Clock, Random)>`. *)
and show_list pr ts =
  String.concat ", "
    (List.map
       (fun t ->
         let s = show pr t in
         match t with
         | (Con (_, [ Uses u ]) | Fun (_, _, _, u, _))
           when List.length u.labels > 1 ->
             "(" ^ s ^ ")"
         | _ -> s)
       ts)

and show_param pr p =
  match p.mode with Inout -> "inout " ^ show pr p.ty | Read -> show pr p.ty

(* Whether [t], shown, ends in a `uses` list. *)
and ends_in_uses pr t =
  match t with
  | Con (_, [ Uses u ]) | Fun (_, _, _, u, _) ->
      show_row pr ~prefix:"" ~sep:"" ~kind:"d" u <> ""
  | _ -> false

(* ` -> R`, or nothing for Unit. A returned function with effects is
   parenthesized, so it's clear whose effects they are, and so is an
   implementation that needs something: after `->`, a `uses` would be the
   function's own. *)
and show_ret pr r =
  match r with
  | r when r = unit -> ""
  | Fun (_, _, e, u, l) as f ->
      let s = show pr f in
      if show_effects pr e u ^ show_lams pr l = "" then " -> " ^ s
      else " -> (" ^ s ^ ")"
  | r when ends_in_uses pr r -> " -> (" ^ show pr r ^ ")"
  | r -> " -> " ^ show pr r

and show_effects pr e u =
  show_row pr ~prefix:" ! " ~sep:" | " ~kind:"e" e
  ^ show_row pr ~prefix:" uses " ~sep:", " ~kind:"d" u

(* A lambda set, ` [main.inc, main.main#1 | ..l0]`, only if the printer
   shows them: nothing else ever does. *)
and show_lams pr l =
  if not pr.show_lams then ""
  else
    let tail =
      match l.lvar with
      | Some n -> [ "..l" ^ string_of_int n ]
      | None -> [ "..l?" ]
    in
    match l.ids with
    | [] -> " [" ^ String.concat "" tail ^ "]"
    | ids -> " [" ^ String.concat ", " ids ^ " | " ^ String.concat "" tail ^ "]"

(* How `ren types` prints a function: the signature `ren fmt --annotate`
   would write. [params] are the parameters' names. A row tail is printed
   (as `..e` / `..d`) only when it links two places, like a closure kept in
   the result, `-> (fn() ! ..e)`, or in a type, `Button<fn() ! ..e>`, and
   the function's own errors; a tail found only once says nothing. A transparent
   parameter, whose row is its function's own, is printed as it's written,
   `f: fn(Int)` or `c: Clock`: the function's `!` and `uses` already say
   what's in it.

   What it needs of a type parameter follows the parameter's name,
   `same<T has eq>`, `sum<T has add, zero>` (operators.md, "Generic
   code"); a parameter without a written name is named as everywhere
   else, `T`, `U`, ... What it needs of the tags an error row stands for
   follows them, `twice<T has eq, ..e has eq>`, with the row's tail
   shown wherever it is.

   A member of a type is printed under its type, so [outer]
   are the type's parameters, which aren't the function's own and aren't
   listed after its name, unless the member needs something of one,
   `fn has<T has eq>(self, x: T)`, which the type doesn't say; and `self`
   is printed without its type, which is always the type's. *)
let signature ?(outer = []) ~names ~pub ~name ~params (s : scheme) =
  match s.ty with
  | Fun (ps, ret, errs, uses, lams) ->
      (* a parameter's row that is the function's own, which isn't printed:
         a transparent parameter, written `fn(...)`. One that ends in the
         same tail but has fewer labels fails with less than the function,
         and is printed, so the tail shows whose it is *)
      let own (own : row) (r : row) =
        if r.tail <> None && r = own then closed else r
      in
      let ps =
        List.map
          (fun (p : param) ->
            match p.ty with
            | Fun (qs, r, e, u, l) ->
                (* one row the function's own and the other closed and
                   empty is a closure that's kept, `f: fn() uses ..d`,
                   which isn't written like a transparent one, *)
                let is_own (own : row) (r : row) = r.tail <> None && r = own in
                let e_own = is_own errs e and u_own = is_own uses u in
                (* and so is one with a row of its own, `fn() ! ..e`, whose
                   other row is then written too *)
                let kept own r = r.tail <> None && r <> own in
                if
                  (e_own && u = closed)
                  || (u_own && e = closed)
                  || kept errs e || kept uses u
                then p
                else { p with ty = Fun (qs, r, own errs e, own uses u, l) }
            | Con (d, [ Uses u ]) ->
                { p with ty = Con (d, [ Uses (own uses u) ]) }
            | _ -> p)
          ps
      in
      let ty = Fun (ps, ret, errs, uses, lams) in
      let s = { s with ty } in
      (* a tail is printed where it links two places: the function's own
         rows, a parameter, the result. So is one at the end of a
         parameter's function type that isn't the function's own, which
         would read as a transparent parameter's without it *)
      let all = tails ty in
      let links id = List.length (List.filter (( = ) id) all) > 1 in
      let kept =
        List.concat_map
          (fun (p : param) ->
            match p.ty with
            | Fun (_, _, e, u, _) ->
                Option.to_list e.tail @ Option.to_list u.tail
            | _ -> [])
          ps
      in
      (* and so is one at the end of what an implementation in the result
         needs: `-> N` would say it needs nothing, `-> (N uses ..d)` that
         it can be used where anything is installed *)
      let rec needs t =
        match t with
        | Con (_, [ Uses u ]) -> Option.to_list u.tail
        | Con (_, args) -> List.concat_map needs args
        | Var _ | Error | Errors _ | Uses _ | Fun _ -> []
      in
      let kept = kept @ needs ret in
      (* and so is one the function needs something of, which is listed
         with its type parameters *)
      let pr =
        printer
          ~show_tail:(fun id ->
            links id || List.mem id kept || List.mem_assoc id s.row_reqs)
          ~names s
      in
      pr.reserved <- outer;
      reserve pr s.ty;
      let params =
        List.map2
          (fun name (p : param) ->
            let mode = match p.mode with Inout -> "inout " | Read -> "" in
            if name = "self" then mode ^ name
            else mode ^ name ^ ": " ^ show pr p.ty)
          params ps
      in
      let ret = show_ret pr ret in
      let effects = show_effects pr errs uses in
      (* what the variable named [n] needs, `T has eq`, or just `T` *)
      let needs n =
        match
          Hashtbl.fold
            (fun id m found -> if m = n then Some id else found)
            pr.names None
        with
        | None -> []
        | Some id ->
            List.filter_map
              (fun (v, r) -> if v = id then Some r else None)
              s.reqs
      in
      let param n =
        match needs n with [] -> n | rs -> n ^ " has " ^ String.concat ", " rs
      in
      (* the names of the type's own parameters, among those handed out,
         which aren't listed unless the function needs something of one,
         which the type doesn't say *)
      let outer =
        List.filter_map
          (fun (id, n) ->
            if List.mem n outer then Hashtbl.find_opt pr.names id else None)
          s.names
      in
      (* what it needs of a row, `..e has eq`, after the type
         parameters: an error set's tail is only ever named `..e` *)
      let rows =
        List.map
          (fun (id, reqs) ->
            ".." ^ tail_name pr id "e" ^ " has " ^ String.concat ", " reqs)
          (List.fold_right
             (fun (id, r) acc ->
               match acc with
               | (id', rs) :: rest when id' = id -> (id, r :: rs) :: rest
               | _ -> (id, [ r ]) :: acc)
             s.row_reqs [])
      in
      let tparams =
        match
          List.map param
            (List.filter
               (fun n -> (not (List.mem n outer)) || needs n <> [])
               (List.rev pr.order))
          @ rows
        with
        | [] -> ""
        | parts -> "<" ^ String.concat ", " parts ^ ">"
      in
      Printf.sprintf "%sfn %s%s(%s)%s%s"
        (if pub then "pub " else "")
        name tparams
        (String.concat ", " params)
        ret effects
  | _ -> invalid_arg "Ty.signature: not a function type"

(* How `ren types` prints an associated value, under its type: [s] is its
   type. *)
let value_signature ~names ~pub ~name (s : scheme) =
  let pr = printer ~names s in
  Printf.sprintf "%slet %s: %s" (if pub then "pub " else "") name (show pr s.ty)

(* How `ren types` prints a handler (ast.ml, [is_handler]): its
   parameters, named [params], the dependencies it implements, [deps], and
   what it needs, from its function's scheme [s], whose result is the
   handler's type: its dependency's, or its own. A row tail is printed
   where it links two places, a closure it keeps and what it needs, say. *)
let handler_signature ~names ~pub ~name ~params ~deps (s : scheme) =
  match s.ty with
  | Fun (ps, (Con (_, [ Uses needs ]) as ret), _, _, _) ->
      let all =
        List.concat_map (fun (p : param) -> tails p.ty) ps @ tails ret
      in
      let links id = List.length (List.filter (( = ) id) all) > 1 in
      let pr = printer ~show_tail:links ~names s in
      reserve pr s.ty;
      let params =
        List.map2 (fun n (p : param) -> n ^ ": " ^ show pr p.ty) params ps
      in
      Printf.sprintf "%shandler %s(%s) for %s%s"
        (if pub then "pub " else "")
        name
        (String.concat ", " params)
        (String.concat ", " (List.map names deps))
        (show_row pr ~prefix:" uses " ~sep:", " ~kind:"d" needs)
  | _ -> invalid_arg "Ty.handler_signature: not a handler's function"
