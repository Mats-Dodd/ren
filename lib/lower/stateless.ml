(* Stateless: an operation is called on a description only when its
   handler has no state (foundations.md, decision 3; language.md §6;
   compiler.md, "Data stage", "Descriptions (step 6)").

   `c.area()` means `with c in Area.area()`: it makes a fresh instance of
   `c`'s handler for the call. For a handler with a `var` that's
   language.md's trap, a counter that says 1 at every call, and for one
   with a `finally` it's a `finally` run at the end of each; so a method
   call that may reach either is refused, and method syntax on a
   description always means a pure dispatch. The other two kinds of state
   decision 3 names are refused at the call by their types already: one
   that can fail to start, and one that goes `over` another (Infer's
   [desc_method]).

   A description's type doesn't say which handler made it, so which ones
   a method call may reach is the whole program's to say, and this pass
   runs on the program linked (Driver.link), before anything runs or
   builds. It reads Core, where a method call is the [With] that installs
   its receiver for the call, which Lower records beside
   ([Core.method_call], by the [With]'s location).

   **Where a description goes.** A handler's description is made where
   its function is called, `counter()`, and from there it goes one of
   three ways, which this walk tells apart:

   - **Installed where it's made,** a [With]'s or a [With_handler]'s item
     (`with counter() in ...`, or `counter().area()`). It reaches that
     one [With] and nothing else.
   - **Bound to a local only installed,** `let c = counter()`, where `c`
     is never assigned or passed with `&`, and every use of it, or of a
     `let` copy of it, is a [With]'s item. It reaches those [With]s and
     nothing else: `c` holds that description wherever it's read.
   - **Kept,** anywhere else: stored in an array, a record or a map,
     passed, returned, captured, assigned. Then it may reach any method
     call whose receiver came from somewhere this walk doesn't follow, so
     its handler is among those that every such call on its dependency
     may be. The function used without being called, `let f = counter`,
     is kept too.

   So a method call whose receiver is a description installed where it's
   made, or a local only installed, may be only that handler's; any other
   may be any kept handler of its dependency. It's refused if one of those
   keeps state. That's sound because every description is made by
   calling a handler's function, or by an inline handler, which has no
   state (step 3 of 10d): one that isn't kept reaches only the [With]s
   the walk saw it reach, so a receiver it didn't follow holds a kept one.
   It's finer than refusing every method call on a dependency one of
   whose handlers keeps state: a stateful handler installed by `with`, or
   bound and called as a method only through its own local, leaves the
   calls on its dependency's stored descriptions alone. *)

open Core

(* What a handler keeps that a method call would start again. *)
type state = Keeps_state | Has_finally

(* A handler of the program: a function whose body is a [Handler]. *)
type handler = {
  hpath : Path.t;
  hdeps : Path.t list;  (** the dependencies it implements *)
  hstate : state option;
}

(* Whether a handler's body makes a cell, which only a `var` of its
   state is (Core's [New_cell]), or ends in an instance with a
   `finally`. *)
let rec makes_cell (e : expr) =
  match e.kind with
  | Prim (New_cell, _) -> true
  | _ -> List.exists makes_cell (children e)

let rec has_finally (e : expr) =
  match e.kind with
  | Instance { finally = Some _; _ } -> true
  | _ -> List.exists has_finally (children e)

let handler_of (f : fn_def) =
  match (f.body.kind, f.scheme.ty) with
  | Handler { body; _ }, Fun (_, ret, _, _) ->
      let hdeps =
        match Ty.impl_parts ret with
        | Some (deps, _) -> Ty.dep_paths deps
        | None -> []
      in
      let hstate =
        if makes_cell body then Some Keeps_state
        else if has_finally body then Some Has_finally
        else None
      in
      Some { hpath = f.path; hdeps; hstate }
  | _ -> None

(* The locals a function assigns or passes with `&`: one of those may
   hold another description than the one it was bound to. *)
let changed (f : fn_def) =
  let ids = Hashtbl.create 16 in
  let rec go (e : expr) =
    (match e.kind with
    | Assign (v, _) -> Hashtbl.replace ids v.id ()
    | Call (_, args, _) ->
        List.iter
          (function Ref v -> Hashtbl.replace ids v.id () | Value _ -> ())
          args
    | _ -> ());
    List.iter go (children e)
  in
  go f.body;
  ids

(* A description narrowed to some of its dependencies is the same one. *)
let rec strip (e : expr) =
  match e.kind with Narrowed (_, e) -> strip e | _ -> e

(* What one function's walk needs, and what the walk of the whole
   program found. *)
type cx = {
  handlers : handler Path.Map.t;
  calls : (Loc.t, method_call) Hashtbl.t;  (** by their [With]'s location *)
  mutable home : string;  (** the module being walked *)
  mutable changed : (int, unit) Hashtbl.t;  (** the function's ([changed]) *)
  bound : (int, handler) Hashtbl.t;
      (** the function's locals only installed, each with the handler whose
          description it holds *)
  kept : (Path.t, unit) Hashtbl.t;  (** handlers whose descriptions are kept *)
  mutable known : (string * method_call * handler) list;
      (** method calls whose receiver can be only this handler's, with the
          module they're in *)
  mutable unknown : (string * method_call) list;
      (** method calls whose receiver may be any kept handler's *)
}

(* Where [e], a [With]'s item or a [Let]'s value, comes from: a call of a
   handler's function, made right here, or a local only installed. *)
type origin = Made of handler * arg list | Bound of handler | Other

let origin cx (e : expr) =
  match (strip e).kind with
  | Call ({ kind = Global (p, _, _, _); _ }, args, _)
    when Path.Map.mem p cx.handlers ->
      Made (Path.Map.find p cx.handlers, args)
  | Local v -> (
      match Hashtbl.find_opt cx.bound v.id with
      | Some h -> Bound h
      | None -> Other)
  | _ -> Other

(* Whether every use of the locals [ids] in [e] is a [With]'s item, or
   the value of a `let` of another such local that's never changed,
   whose uses are the same. *)
let rec only_installed cx ids (e : expr) =
  let mine (e : expr) =
    match (strip e).kind with Local v -> List.mem v.id ids | _ -> false
  in
  match e.kind with
  | Local v -> not (List.mem v.id ids)
  | With { impl = item; body; _ } | With_handler { handler = item; body; _ } ->
      (mine item || only_installed cx ids item) && only_installed cx ids body
  | Let (y, v, body) when mine v ->
      (not (Hashtbl.mem cx.changed y.id)) && only_installed cx (y.id :: ids) body
  | _ -> List.for_all (only_installed cx ids) (children e)

let rec walk cx (e : expr) =
  match e.kind with
  | Global (p, _, _, _) when Path.Map.mem p cx.handlers ->
      Hashtbl.replace cx.kept p ()
  | With { impl = item; body; _ } | With_handler { handler = item; body; _ }
    ->
      install cx (Hashtbl.find_opt cx.calls e.loc) item;
      walk cx body
  | Let (x, v, body) -> (
      match origin cx v with
      | (Made (h, _) | Bound h)
        when (not (Hashtbl.mem cx.changed x.id))
             && only_installed cx [ x.id ] body ->
          made_args cx v;
          Hashtbl.replace cx.bound x.id h;
          walk cx body
      | _ ->
          walk cx v;
          walk cx body)
  | _ -> List.iter (walk cx) (children e)

(* [item], installed by a [With], which is the method call [call] if
   it's one. *)
and install cx call item =
  match origin cx item with
  | Made (h, _) | Bound h ->
      made_args cx item;
      Option.iter (fun m -> cx.known <- (cx.home, m, h) :: cx.known) call
  | Other ->
      walk cx item;
      Option.iter (fun m -> cx.unknown <- (cx.home, m) :: cx.unknown) call

(* The arguments of a handler's call whose description isn't kept: they
   may make descriptions of their own. *)
and made_args cx item =
  match origin cx item with
  | Made (_, args) ->
      List.iter (function Value a -> walk cx a | Ref _ -> ()) args
  | Bound _ | Other -> ()

(* `c` may be a description of `counter`, which keeps state. *)
let refusal home (m : method_call) (h : handler) state =
  let name =
    if h.hpath.home = home then Path.local h.hpath else Path.full h.hpath
  in
  let has, note =
    match state with
    | Keeps_state ->
        ("keeps state", "its state would start again at each call")
    | Has_finally -> ("has a `finally`", "its `finally` would run at the end of each call")
  in
  Diag.make m.mop
    ~notes:[ "a call as a method makes a fresh instance, so " ^ note ]
    ~help:(Printf.sprintf "install it: `with %s in %s`" m.mrecv m.mcall)
    (Printf.sprintf
       "`%s` may be a description of `%s`, which %s, so it isn't called as a \
        method"
       m.mrecv name has)

let check (programs : program list) =
  let handlers =
    List.fold_left
      (fun acc (p : program) ->
        List.fold_left
          (fun acc f ->
            match handler_of f with
            | Some h -> Path.Map.add h.hpath h acc
            | None -> acc)
          acc p.fns)
      Path.Map.empty programs
  in
  (* nothing to refuse without a handler that keeps state *)
  if Path.Map.exists (fun _ h -> h.hstate <> None) handlers then (
    let cx =
      {
        handlers;
        calls = Hashtbl.create 16;
        home = "";
        changed = Hashtbl.create 1;
        bound = Hashtbl.create 16;
        kept = Hashtbl.create 16;
        known = [];
        unknown = [];
      }
    in
    List.iter
      (fun (p : program) ->
        List.iter
          (fun (m : method_call) -> Hashtbl.replace cx.calls m.mloc m)
          p.method_calls)
      programs;
    List.iter
      (fun (p : program) ->
        cx.home <- p.home;
        List.iter
          (fun (f : fn_def) ->
            cx.changed <- changed f;
            Hashtbl.reset cx.bound;
            walk cx f.body)
          p.fns)
      programs;
    (* the kept handlers with state, in the program's order, the first of
       a dependency's being the one an error names *)
    let kept_stateful =
      List.concat_map
        (fun (p : program) ->
          List.filter_map
            (fun (f : fn_def) ->
              match Path.Map.find_opt f.path handlers with
              | Some ({ hstate = Some s; _ } as h) when Hashtbl.mem cx.kept h.hpath
                ->
                  Some (h, s)
              | _ -> None)
            p.fns)
        programs
    in
    let sink = Diag.sink () in
    List.iter
      (fun (home, m, h) ->
        Option.iter (fun s -> Diag.report sink (refusal home m h s)) h.hstate)
      cx.known;
    List.iter
      (fun (home, (m : method_call)) ->
        match
          List.find_opt (fun (h, _) -> List.mem m.mdep h.hdeps) kept_stateful
        with
        | Some (h, s) -> Diag.report sink (refusal home m h s)
        | None -> ())
      cx.unknown;
    if Diag.has_errors sink then raise (Diag.Errors (Diag.reported sink)))
