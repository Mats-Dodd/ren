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

(* ---- printing ----

   A printer names variables consistently across everything printed with
   it. A variable gets the name it was declared with if that's still free,
   otherwise the next of T, U, V, ...

   Row tails are hidden unless [show_tail] picks them, and then print as
   `..e` (errors) or `..d` (dependencies). Type names are written as they'd
   be written in module [home] (path.ml). *)
type printer = {
  home : string;
  hints : (int * string) list;
  names : (int, string) Hashtbl.t;
  mutable order : string list;  (** names handed out, most recent first *)
  mutable reserved : string list;
  show_tail : int -> bool;
  tail_names : (int, string) Hashtbl.t;
}

let printer ?(show_tail = fun _ -> false) ~home (s : scheme) =
  {
    home;
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
  | Con (p, []) -> Path.show ~home:pr.home p
  | Con (p, args) ->
      Path.show ~home:pr.home p ^ "<"
      ^ String.concat ", " (List.map (show pr) args)
      ^ ">"
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
   parameter is transparent and the tail implied. *)
let signature ~home ~pub ~name ~params (s : scheme) =
  match s.ty with
  | Fun (ps, ret, errs, uses) ->
      let in_ret = tails ret in
      let pr = printer ~show_tail:(fun id -> List.mem id in_ret) ~home s in
      reserve pr s.ty;
      let params =
        List.map2
          (fun name (p : param) ->
            match p.mode with
            | Inout -> "inout " ^ name ^ ": " ^ show pr p.ty
            | Read -> name ^ ": " ^ show pr p.ty)
          params ps
      in
      let ret = show_ret pr ret in
      let effects = show_effects pr errs uses in
      let tparams =
        match List.rev pr.order with
        | [] -> ""
        | names -> "<" ^ String.concat ", " names ^ ">"
      in
      Printf.sprintf "%sfn %s%s(%s)%s%s"
        (if pub then "pub " else "")
        name tparams
        (String.concat ", " params)
        ret effects
  | _ -> invalid_arg "Ty.signature: not a function type"
