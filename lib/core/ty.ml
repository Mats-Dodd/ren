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
  | Fun of param list * ty * row * row  (** params, result, errors, uses *)
  | Var of int
      (** a type variable. In a scheme, a generic one, numbered by first
          appearance; in a type declaration, the declaration's parameter at that
          position (`T` in `Option<T>` is [Var 0]) *)
  | Error  (** the type of code that had an error, already reported *)

and param = { mode : mode; ty : ty }

and row = {
  labels : string list;  (** sorted *)
  tail : int option;
      (** [None]: exactly these labels. [Some n]: these and possibly more,
          standing for row variable [n] (numbered apart from type variables) *)
}

(* A function's type, for every choice of its variables. [names] are the
   names its variables were declared with, like the `T` of `fn id<T>`, so
   `ren types` can print them back. *)
type scheme = { ty : ty; names : (int * string) list }

let int = Con (Path.prelude "Int", [])
let bool = Con (Path.prelude "Bool", [])
let unit = Con (Path.prelude "Unit", [])
let array t = Con (Path.prelude "Array", [ t ])
let read ty = { mode = Read; ty }
let closed = { labels = []; tail = None }

(* The row variables inside a type. *)
let rec tails t =
  let of_row r = Option.to_list r.tail in
  match t with
  | Var _ | Error -> []
  | Con (_, args) -> List.concat_map tails args
  | Fun (ps, r, e, u) ->
      List.concat_map (fun (p : param) -> tails p.ty) ps
      @ tails r @ of_row e @ of_row u

(* A scheme with its variables renumbered by where they first appear,
   reading left to right, as inference numbers them: type variables and row
   variables separately. [names] follow their variables. *)
let canonical (s : scheme) =
  let number table n =
    match List.assoc_opt n !table with
    | Some m -> m
    | None ->
        let m = List.length !table in
        table := (n, m) :: !table;
        m
  in
  let tys = ref [] and rows = ref [] in
  let rec go = function
    | Var n -> Var (number tys n)
    | Error -> Error
    | Con (p, args) -> Con (p, List.map go args)
    | Fun (ps, r, e, u) ->
        (* `let`s fix the order of first appearance: OCaml evaluates a
           constructor's arguments right to left *)
        let ps = List.map (fun (p : param) -> { p with ty = go p.ty }) ps in
        let r = go r in
        let e = row e in
        let u = row u in
        Fun (ps, r, e, u)
  and row r = { r with tail = Option.map (number rows) r.tail } in
  let ty = go s.ty in
  let names =
    List.filter_map
      (fun (n, h) -> Option.map (fun m -> (m, h)) (List.assoc_opt n !tys))
      s.names
  in
  { ty; names = List.sort compare names }

(* ---- printing ----

   A printer names variables consistently across everything printed with
   it. A variable gets the name it was declared with if that's still free,
   otherwise the next of T, U, V, ...

   Row tails are hidden unless [show_tail] picks them, and then print as
   `..e` (errors) or `..d` (dependencies). [names] says how to write each
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
}

let printer ?(show_tail = fun _ -> false) ~names (s : scheme) =
  {
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
  | Fun (ps, r, _, _) ->
      List.iter (reserve pr) (r :: List.map (fun (p : param) -> p.ty) ps)

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
  let tail =
    match r.tail with
    | Some id when pr.show_tail id -> [ ".." ^ tail_name pr id kind ]
    | _ -> []
  in
  match r.labels @ tail with
  | [] -> ""
  | parts -> prefix ^ String.concat sep parts

let rec show pr t =
  match t with
  | Con (p, []) -> pr.type_name p
  | Con (p, args) ->
      pr.type_name p ^ "<" ^ String.concat ", " (List.map (show pr) args) ^ ">"
  | Error -> "_"
  | Var id -> var_name pr id
  | Fun (ps, r, e, u) ->
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
  match r with
  | r when r = unit -> ""
  | Fun (_, _, e, u) as f ->
      let s = show pr f in
      if show_effects pr e u = "" then " -> " ^ s else " -> (" ^ s ^ ")"
  | r -> " -> " ^ show pr r

and show_effects pr e u =
  show_row pr ~prefix:" ! " ~sep:" | " ~kind:"e" e
  ^ show_row pr ~prefix:" uses " ~sep:", " ~kind:"d" u

(* How `ren types` prints a function: the signature `ren fmt --annotate`
   would write. [params] are the parameters' names. A row tail is printed
   (as `..e` / `..d`) only when it reaches the result; otherwise the
   parameter is transparent and the tail implied.

   A member of a type is printed under its type, so [outer]
   are the type's parameters, which aren't the function's own and aren't
   listed after its name, and `self` is printed without its type, which is
   always the type's. *)
let signature ?(outer = []) ~names ~pub ~name ~params (s : scheme) =
  match s.ty with
  | Fun (ps, ret, errs, uses) ->
      let in_ret = tails ret in
      let pr = printer ~show_tail:(fun id -> List.mem id in_ret) ~names s in
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
      (* the names of the type's own parameters, among those handed out *)
      let outer =
        List.filter_map
          (fun (id, n) ->
            if List.mem n outer then Hashtbl.find_opt pr.names id else None)
          s.names
      in
      let tparams =
        match
          List.filter (fun n -> not (List.mem n outer)) (List.rev pr.order)
        with
        | [] -> ""
        | names -> "<" ^ String.concat ", " names ^ ">"
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
