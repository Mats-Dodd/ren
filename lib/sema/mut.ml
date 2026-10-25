(* Mutability checks: what may change, and through which name. Runs after
   resolve.ml and before type inference, since none of it needs types.

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
   `inout` as a copy in and a copy out.

   Every name has already been resolved (resolve.ml), so what a name is
   (a `let`, a `var`, a parameter...) is on its binder, and two places
   start from the same variable when their binders have the same id.

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the rest of the function. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf

type kind =
  | Mutable  (** a `var`, an `inout` parameter, or the element of a `for &` *)
  | Fixed of string * string
      (** what the name is ("a `let`"), and how to get one that can change *)

(* A step of a place's path. Two indices are assumed to overlap, since
   whether `xs[i]` and `xs[j]` are the same element isn't known until the
   program runs. *)
type step = SField of string | SIndex

(* A place: the name it starts from (written at [rloc]), then a path of
   fields and indices. *)
type place = { root : name; rloc : Loc.t; path : step list }

(* A place a `for &` loop is changing, and the name of its element. *)
type lock = {
  lid : int;  (** the binder of the array's variable *)
  lpath : step list;
  elem : string;
  lloc : Loc.t;  (** the loop's `&ps` *)
}

type ctx = {
  depth : int;  (** how many lambdas deep *)
  locks : lock list;
  sink : Diag.sink;
}

(* Run a check; if it finds a problem, report it and carry on. *)
let guard cx f = Diag.recover cx.sink ~default:() f

let name_of = function
  | Local b -> b.ident.name
  | Global p -> p.name
  | Intrinsic x -> x

let rec place_of (e : expr) =
  match e.kind with
  | Var x -> Some { root = x; rloc = e.loc; path = [] }
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
  match p.root with
  | Global _ | Intrinsic _ -> ()
  | Local b ->
      List.iter
        (fun l ->
          if l.lid = b.id && overlap l.lpath p.path then
            Diag.error p.rloc
              ~help:(sprintf "inside the loop, use `%s`" l.elem)
              ~labels:
                [ (l.lloc, sprintf "the loop changes `%s` here" b.ident.name) ]
              (sprintf "`%s` is being changed by the `for` loop around this"
                 b.ident.name))
        cx.locks

(* Whether a local can change, and if not, what it is and how to get one
   that can. *)
let kind (b : binder) =
  let x = b.ident.name in
  let copy is =
    Fixed (is, sprintf "copy it with `var %s = %s` and change the copy" x x)
  in
  match b.bound with
  | By_var | By_inout | By_ref_loop -> Mutable
  | By_let -> Fixed ("a `let`", "declare it with `var` to change it")
  | By_param ->
      Fixed
        ( "a parameter",
          sprintf
            "mark it `inout` to change the caller's value, or copy it with \
             `var %s = %s`"
            x x )
  | By_lambda -> copy "a lambda's parameter"
  | By_pattern -> copy "bound by a pattern"
  | By_loop ->
      Fixed
        ( "a loop variable",
          sprintf "loop with `for %s in &...` to change the elements" x )

(* Check that [e] is a place this code may change. [what] words the error
   when it isn't a place at all. *)
let writable cx (e : expr) ~what =
  match place_of e with
  | None ->
      Diag.error e.loc
        ~help:"only a variable, or a field or element of one, can be changed"
        what
  | Some ({ root = Global _ | Intrinsic _; _ } as p) ->
      Diag.error p.rloc
        (sprintf "`%s` is a function, not a variable" (name_of p.root))
  | Some ({ root = Local b; _ } as p) -> (
      let x = b.ident.name in
      match kind b with
      | Fixed (is, help) ->
          Diag.error p.rloc ~help
            (sprintf "`%s` is %s, so it can't be changed" x is)
      | Mutable when b.depth < cx.depth ->
          Diag.error p.rloc
            ~notes:
              [
                "a lambda captures the values of the variables it uses when \
                 it's created, so changing them would have no effect outside";
              ]
            (sprintf "a lambda can't change `%s`, a variable from outside it" x)
      | Mutable -> check_locks cx p)

let rec walk cx (e : expr) =
  match e.kind with
  | Int _ | Bool _ | Unit -> ()
  | Var _ | Field _ | Index _ -> (
      match place_of e with
      | Some p ->
          guard cx (fun () -> check_locks cx p);
          walk_indices cx e
      | None -> (
          match e.kind with
          | Field (r, _) -> walk cx r
          | Index (a, i) ->
              walk cx a;
              walk cx i
          | _ -> ()))
  | Ref _ ->
      Diag.report cx.sink
        (Diag.make e.loc ~help:"remove the `&`"
           ~notes:
             [
               "`&` marks an argument a call changes, or the array a `for` \
                loop changes";
             ]
           "`&` can't be used here")
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
              guard cx (fun () ->
                  writable cx p ~what:"`&` needs a variable it can change");
              walk_indices cx p
          | _ -> walk cx a)
        args;
      guard cx (fun () -> exclusive args)
  | Lambda (ps, body) ->
      List.iter
        (fun (p : param) ->
          if p.pmode = Inout then
            Diag.report cx.sink
              (Diag.make p.pname.ident.loc
                 ~help:"use a top-level function for this"
                 "lambdas can't take `inout` parameters yet"))
        ps;
      walk { cx with depth = cx.depth + 1 } body
  | Block (stmts, last) ->
      List.iter
        (function Let { value; _ } -> walk cx value | Expr e -> walk cx e)
        stmts;
      walk cx last
  | Con (_, args) -> List.iter (fun (_, a) -> walk cx a) args
  | Record (_, fields) -> List.iter (fun (_, v) -> walk cx v) fields
  | Array xs -> List.iter (walk cx) xs
  | Assign { target; value; _ } ->
      guard cx (fun () -> writable cx target ~what:"this can't be assigned to");
      walk_indices cx target;
      walk cx value
  | For { var; iter = { kind = Ref a; loc = iter_loc; _ }; body } ->
      guard cx (fun () ->
          writable cx a ~what:"`&` needs a variable it can change");
      walk_indices cx a;
      (* lock the array, if it's a place the loop can change *)
      let locks =
        match place_of a with
        | Some { root = Local b; path; _ } ->
            { lid = b.id; lpath = path; elem = var.ident.name; lloc = iter_loc }
            :: cx.locks
        | _ -> cx.locks
      in
      walk { cx with locks } body
  | For { iter; body; _ } ->
      walk cx iter;
      walk cx body
  | Match (subject, arms) ->
      walk cx subject;
      List.iter
        (fun (a : arm) ->
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
and exclusive args =
  let places =
    List.filter_map
      (fun (a : expr) ->
        let inner, changed =
          match a.kind with Ref p -> (p, true) | _ -> (a, false)
        in
        match place_of inner with
        | Some ({ root = Local b; _ } as p) -> Some (a, b, p, changed)
        | _ -> None)
      args
  in
  let rec check = function
    | [] -> ()
    | (first, (b : binder), p, changed) :: rest ->
        List.iter
          (fun ((a : expr), (b' : binder), p', changed') ->
            if b.id = b'.id && (changed || changed') && overlap p.path p'.path
            then
              let x = b.ident.name in
              let notes =
                [
                  "an argument passed with `&` has to be the only way the call \
                   can reach that value";
                ]
              in
              let labels =
                [
                  ( (first : expr).loc,
                    if changed then "passed with `&` here" else "used here" );
                ]
              in
              if changed && changed' then
                Diag.error a.loc ~notes ~labels
                  (sprintf "`%s` is passed with `&` twice in this call" x)
              else
                Diag.error a.loc ~notes ~labels
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

let program sink (r : Resolve.t) =
  List.iter
    (function
      | Fn f -> walk { depth = 0; locks = []; sink } f.body | Type _ -> ())
    r.prog
