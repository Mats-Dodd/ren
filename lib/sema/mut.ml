(* Mutability checks: what may change, and through which name. Runs after
   check.ml and before type inference, since none of it needs types.

   - Only a place can be assigned to or passed with `&`: a variable, then
     any fields and indices into it (`user.plan`, `xs[i]`). Its variable has
     to be a `var`, an `inout` parameter, or the element of `for p in &ps`.
   - A lambda can't change a variable from outside it. It captures the
     values it uses when it's created, so the change would go nowhere.
   - `&` only appears on a call's arguments and in `for p in &ps`.
   - Exclusivity: an argument passed with `&` must be the only way the call
     can reach that value, so `swap(&a, &a)` and `f(&xs, xs)` are errors.
     Likewise, inside `for p in &ps` the loop body reaches `ps` only
     through `p`.

   Together these make sure no two names ever see the same mutable value,
   which is what lets the interpreter (and later the compiler) treat every
   `inout` as a copy in and a copy out. *)

open Ast
module Env = Map.Make (String)

let sprintf = Printf.sprintf

type kind =
  | Mutable  (** a `var`, an `inout` parameter, or the element of a `for &` *)
  | Fixed of string * string
      (** what the name is ("a `let`"), and how to get one that can change *)

type binding = { id : int; kind : kind; depth : int  (** lambda nesting *) }

(* A step of a place's path. Two indices are assumed to overlap, since
   whether `xs[i]` and `xs[j]` are the same element isn't known until the
   program runs. *)
type step = SField of string | SIndex
type place = { root : ident; path : step list }

(* A place a `for &` loop is changing, and the name of its element. *)
type lock = { lid : int; lpath : step list; elem : string }

(* Hands out binding ids, numbered per function. A record with a [mutable]
   field is shared by every copy of the [ctx] that holds it, so ids stay
   unique while the [ctx] itself is copied as scopes open. *)
type ids = { mutable last : int }

type ctx = {
  scope : binding Env.t;
  depth : int;
  locks : lock list;
  fns : string list;  (** top-level and built-in functions *)
  ids : ids;
}

let bind cx (name : ident) kind =
  cx.ids.last <- cx.ids.last + 1;
  {
    cx with
    scope =
      Env.add name.name { id = cx.ids.last; kind; depth = cx.depth } cx.scope;
  }

let rec place_of (e : expr) =
  match e.kind with
  | Var x -> Some { root = { name = x; loc = e.loc }; path = [] }
  | Field (r, f) ->
      Option.map
        (fun p -> { p with path = p.path @ [ SField f.name ] })
        (place_of r)
  | Index (a, _) ->
      Option.map (fun p -> { p with path = p.path @ [ SIndex ] }) (place_of a)
  | _ -> None

(* One path is a prefix of the other: changing one changes the other. *)
let rec overlap a b =
  match (a, b) with
  | [], _ | _, [] -> true
  | SIndex :: a, SIndex :: b -> overlap a b
  | SField f :: a, SField g :: b -> f = g && overlap a b
  | _ -> false

let check_locks cx (p : place) =
  match Env.find_opt p.root.name cx.scope with
  | None -> ()
  | Some b ->
      List.iter
        (fun l ->
          if l.lid = b.id && overlap l.lpath p.path then
            Diag.error p.root.loc
              ~help:(sprintf "inside the loop, use `%s`" l.elem)
              (sprintf "`%s` is being changed by the `for` loop around this"
                 p.root.name))
        cx.locks

(* Check that [e] is a place this code may change. [what] words the error
   when it isn't a place at all. *)
let writable cx (e : expr) ~what =
  match place_of e with
  | None ->
      Diag.error e.loc
        ~help:"only a variable, or a field or element of one, can be changed"
        what
  | Some p -> (
      let x = p.root.name in
      match Env.find_opt x cx.scope with
      | None when List.mem x cx.fns ->
          Diag.error p.root.loc (sprintf "`%s` is a function, not a variable" x)
      | None ->
          Diag.error p.root.loc (sprintf "there's no variable named `%s`" x)
      | Some { kind = Fixed (is, help); _ } ->
          Diag.error p.root.loc ~help
            (sprintf "`%s` is %s, so it can't be changed" x is)
      | Some { depth; _ } when depth < cx.depth ->
          Diag.error p.root.loc
            ~notes:
              [
                "a lambda captures the values of the variables it uses when \
                 it's created, so changing them would have no effect outside";
              ]
            (sprintf "a lambda can't change `%s`, a variable from outside it" x)
      | Some _ -> check_locks cx p)

let let_kind = Fixed ("a `let`", "declare it with `var` to change it")

let param_kind (p : param) =
  match p.pmode with
  | Inout -> Mutable
  | Read ->
      Fixed
        ( "a parameter",
          sprintf
            "mark it `inout` to change the caller's value, or copy it with \
             `var %s = %s`"
            p.pname.name p.pname.name )

let copy_kind is (x : string) =
  Fixed (is, sprintf "copy it with `var %s = %s` and change the copy" x x)

let rec pattern_names (p : pattern) =
  match p.pkind with
  | PVar x -> [ { name = x; loc = p.ploc } ]
  | PWild | PInt _ | PBool _ -> []
  | PCon (_, ps) -> List.concat_map pattern_names ps

let rec walk cx (e : expr) =
  match e.kind with
  | Int _ | Bool _ | Unit -> ()
  | Var _ | Field _ | Index _ -> (
      match place_of e with
      | Some p ->
          check_locks cx p;
          walk_indices cx e
      | None -> (
          match e.kind with
          | Field (r, _) -> walk cx r
          | Index (a, i) ->
              walk cx a;
              walk cx i
          | _ -> ()))
  | Ref _ ->
      Diag.error e.loc ~help:"remove the `&`"
        ~notes:
          [
            "`&` marks an argument a call changes, or the array a `for` loop \
             changes";
          ]
        "`&` can't be used here"
  | Unop (_, a) -> walk cx a
  | Binop (_, a, b) ->
      walk cx a;
      walk cx b
  | If (c, t, f) -> List.iter (walk cx) (c :: t :: Option.to_list f)
  | Call (f, args) ->
      walk cx f;
      List.iter
        (fun (a : expr) ->
          match a.kind with
          | Ref p ->
              writable cx p ~what:"`&` needs a variable it can change";
              walk_indices cx p
          | _ -> walk cx a)
        args;
      exclusive cx args
  | Lambda (ps, body) ->
      List.iter
        (fun (p : param) ->
          if p.pmode = Inout then
            Diag.error p.pname.loc ~help:"use a top-level function for this"
              "lambdas can't take `inout` parameters yet")
        ps;
      let cx = { cx with depth = cx.depth + 1 } in
      let cx =
        List.fold_left
          (fun cx (p : param) ->
            bind cx p.pname (copy_kind "a lambda's parameter" p.pname.name))
          cx ps
      in
      walk cx body
  | Block (stmts, last) ->
      let cx =
        List.fold_left
          (fun cx -> function
            | Let { name; value; mut; _ } ->
                walk cx value;
                bind cx name (if mut then Mutable else let_kind)
            | Expr e ->
                walk cx e;
                cx)
          cx stmts
      in
      walk cx last
  | Con (_, args) -> List.iter (fun (_, a) -> walk cx a) args
  | Record (_, fields) -> List.iter (fun (_, v) -> walk cx v) fields
  | Array xs -> List.iter (walk cx) xs
  | Assign { target; value; _ } ->
      writable cx target ~what:"this can't be assigned to";
      walk_indices cx target;
      walk cx value
  | For { var; iter = { kind = Ref a; _ }; body } ->
      writable cx a ~what:"`&` needs a variable it can change";
      walk_indices cx a;
      let p = Option.get (place_of a) in
      let b = Env.find p.root.name cx.scope in
      let cx =
        {
          cx with
          locks = { lid = b.id; lpath = p.path; elem = var.name } :: cx.locks;
        }
      in
      walk (bind cx var Mutable) body
  | For { var; iter; body } ->
      walk cx iter;
      let help =
        sprintf "loop with `for %s in &...` to change the elements" var.name
      in
      walk (bind cx var (Fixed ("a loop variable", help))) body
  | Match (subject, arms) ->
      walk cx subject;
      List.iter
        (fun a ->
          let cx =
            List.fold_left
              (fun cx (x : ident) ->
                bind cx x (copy_kind "bound by a pattern" x.name))
              cx (pattern_names a.arm_pat)
          in
          Option.iter (walk cx) a.arm_guard;
          walk cx a.arm_body)
        arms

(* The index expressions inside a place, like the `i` in `xs[i].pos`. *)
and walk_indices cx (e : expr) =
  match e.kind with
  | Index (a, i) ->
      walk_indices cx a;
      walk cx i
  | Field (r, _) -> walk_indices cx r
  | _ -> ()

(* No argument passed with `&` may overlap another argument of the call. *)
and exclusive cx args =
  let places =
    List.filter_map
      (fun (a : expr) ->
        let inner, changed =
          match a.kind with Ref p -> (p, true) | _ -> (a, false)
        in
        match place_of inner with
        | Some p -> (
            match Env.find_opt p.root.name cx.scope with
            | Some b -> Some (a, b.id, p, changed)
            | None -> None)
        | None -> None)
      args
  in
  let rec check = function
    | [] -> ()
    | (_, id, p, changed) :: rest ->
        List.iter
          (fun ((a : expr), id', p', changed') ->
            if id = id' && (changed || changed') && overlap p.path p'.path then
              let x = p.root.name in
              let notes =
                [
                  "an argument passed with `&` has to be the only way the call \
                   can reach that value";
                ]
              in
              if changed && changed' then
                Diag.error a.loc ~notes
                  (sprintf "`%s` is passed with `&` twice in this call" x)
              else
                Diag.error a.loc ~notes
                  ~help:
                    (sprintf
                       "copy it with `let` first if the call should see the \
                        value `%s` had before"
                       x)
                  (sprintf
                     "this call changes `%s`, so no other argument can use it" x))
          rest;
        check rest
  in
  check places

let program (prog : program) =
  let fns =
    List.map (fun (f : Prelude.builtin_fn) -> f.name) Prelude.fns
    @ List.filter_map
        (function Fn f -> Some f.name.name | Type _ -> None)
        prog
  in
  List.iter
    (function
      | Fn f ->
          let cx =
            {
              scope = Env.empty;
              depth = 0;
              locks = [];
              fns;
              ids = { last = 0 };
            }
          in
          let cx =
            List.fold_left
              (fun cx p -> bind cx p.pname (param_kind p))
              cx f.params
          in
          walk cx f.body
      | Type _ -> ())
    prog
