(* Release builds' specialization (compiler.md, "Specialization";
   foundations.md, decisions 1, 4 and 13): the whole program, from
   `$start`, over Core, into Core that Core Lint checks and the
   interpreter runs, which `ren run --release` does to test it.

   It's a worklist driven by demand, as Roc's monomorphization is
   (roc-rust/crates/compiler/mono/src/ir.rs, [specialize_all] :3027 and
   [specialize_external]; roc-zig/design.md, "Specialization By Demand"
   :16296). Each call of a function reached from `$start` asks for a
   copy of it, keyed by what the call knows:

   - **its types**: the type arguments, and what each of its error rows
     stands for. A copy at closed types has no type variables, so its
     descriptors are [Known] and its dictionaries [Derived] of known
     types, and Mem lowering gives its values their own layouts, never a
     word. A row of what a function uses stays a variable: it changes
     nothing a copy does, and keying on it would make more copies.
   - **its blocks**: for each block parameter, the block passed, lifted
     out of the function it's written in to one of its own whose captures
     are parameters before the block's (Effekt's Mono.scala and
     optimizer/StaticArguments.scala; roc-zig/design.md, "Lambda Mono
     Decisions" :17674). The copy calls it directly, with the captures it
     was given: a capture the block changes is `inout`, the rest are
     values. A block parameter passed on, as a recursive function passes
     its own, keeps its key, so it's specialized once.
   - **its evidence's shape**: which dependencies it uses have a handler
     known to be installed, by a [With] around the call whose handler's
     code is known. A known handler is its state and a static record of
     blocks, so its operations are lifted the same way, the state their
     first parameters, and a [Dep_call] of one becomes a direct call of
     its operation, given the state in the [With]'s frame (Core.known).

   A copy is only ever faster than what it replaces (compiler.md, rule
   1), and there's no cap on the copies of one function (foundations.md,
   decision 4): measured, copies grow with a program's distinct calls, as
   Rust's do, and shrink its machine code. The one limit is a size budget
   for the whole program: once the copies made add up to more of Core
   than [budget], a call that would need a new copy gets the function as
   written, the debug build's strategy, its arguments boxed, unless a
   handler it uses is known, which only a copy can call directly. Each
   such call is a dispatch the program didn't ask for, so it's reported
   ([stats.notes]), never silent. *)

module C = Core
module Ids = Map.Make (Int)

let bug what = failwith ("bug: specialize: " ^ what)

(* ---- closing types ---- *)

(* What a copy's type variables stand for, [Var 0] the first, and each
   of its error rows' variables, all closed: none has a variable in it. *)
type sub = { tys : Ty.ty list; errs : (int * Ty.row) list }

(* [t], in a copy made with [s]: each of the function's type variables
   what it stands for, any other variable, one inference left undecided,
   `()`, since no value of its type is ever made; and every row of errors
   closed, with what its variable stands for. In a handler's `finally`
   ([fin]), the variable after the function's own is the `with` body's
   type (Core.Instance), the copy's first. *)
let close_ty ~fin (s : sub) (t : Ty.ty) : Ty.ty =
  let n = List.length s.tys in
  let rec ty (t : Ty.ty) : Ty.ty =
    match t with
    | Var i when i < n -> List.nth s.tys i
    | Var i when fin && i = n -> Var 0
    | Var _ -> Ty.unit
    (* with what's known once a dependency is, as [Ty.apply] makes it *)
    | Con (p, ts) -> Ty.known (Con (p, List.map ty ts))
    | Variant (p, c, ts) -> Variant (p, c, List.map ty ts)
    | Fun (ps, r, e, u) ->
        Fun
          ( List.map (fun (p : Ty.param) -> { p with ty = ty p.ty }) ps,
            ty r,
            errs e,
            uses u )
    | Errors r -> Errors (errs r)
    | Impl i ->
        Ty.known @@ Impl
          {
            i with
            deps =
              List.map
                (fun (d : Ty.dep) -> { d with dargs = List.map ty d.dargs })
                i.deps;
            needs = uses i.needs;
            fails = errs i.fails;
          }
    | Error -> Error
  and labels ls =
    List.map
      (fun (l : Ty.label) -> { l with payload = List.map ty l.payload })
      ls
  and errs (r : Ty.row) : Ty.row =
    let ls = labels r.labels in
    let more =
      match r.tail with
      | Some j -> (
          match List.assoc_opt j s.errs with Some m -> m.labels | None -> [])
      | None -> []
    in
    let has (l : Ty.label) =
      List.exists (fun (k : Ty.label) -> k.name = l.name) ls
    in
    {
      labels = Ty.sort_labels (ls @ List.filter (fun l -> not (has l)) more);
      tail = None;
    }
  and uses (r : Ty.row) =
    { r with labels = Ty.sort_labels (List.map Ty.known_label (labels r.labels)) }
  in
  ty t

(* Whether a type has no variable in it, but for the variable of what a
   block uses past what its type lists. *)
let rec closed (t : Ty.ty) =
  let row (r : Ty.row) =
    List.for_all (fun (l : Ty.label) -> List.for_all closed l.payload) r.labels
  in
  match t with
  | Var _ -> false
  | Con (_, ts) | Variant (_, _, ts) -> List.for_all closed ts
  | Fun (ps, r, e, u) ->
      List.for_all (fun (p : Ty.param) -> closed p.ty) ps
      && closed r && row e && row u
  | Errors r -> row r
  (* what a handler needs past what it lists is the caller's row, a
     variable of another function's *)
  | Impl i ->
      List.for_all (fun (d : Ty.dep) -> List.for_all closed d.dargs) i.deps
      && row i.needs && i.needs.tail = None && row i.fails
  | Error -> true

(* The variables of a scheme's rows of errors, which a copy closes, as
   opposed to those of what it uses, which it keeps. *)
let error_vars (t : Ty.ty) =
  let found = ref [] in
  let rec ty (t : Ty.ty) =
    match t with
    | Var _ | Error -> ()
    | Con (_, ts) | Variant (_, _, ts) -> List.iter ty ts
    | Fun (ps, r, e, u) ->
        List.iter (fun (p : Ty.param) -> ty p.ty) ps;
        ty r;
        row true e;
        row false u
    | Errors r -> row true r
    | Impl i ->
        List.iter (fun (d : Ty.dep) -> List.iter ty d.dargs) i.deps;
        row false i.needs;
        row true i.fails
  and row is_errs (r : Ty.row) =
    (match r.tail with
    | Some j when is_errs && not (List.mem j !found) -> found := j :: !found
    | _ -> ());
    List.iter (fun (l : Ty.label) -> List.iter ty l.payload) r.labels
  in
  ty t;
  List.sort compare !found

(* ---- walking Core ---- *)

(* [e] with every variable in it, bound or used, given by [f]. *)
let rec map_vars f (e : C.expr) : C.expr =
  let go = map_vars f in
  let desc = map_desc f and dict = map_dict f in
  let kind : C.kind =
    match e.kind with
    | Source_view s -> Source_view { s with value = go s.value }
    | Pattern_scope p ->
        Pattern_scope { owner = f p.owner; receiving = f p.receiving;
          binding = Option.map f p.binding; source = go p.source; pat = map_pat f p.pat;
          on_match = go p.on_match; on_else = Option.map go p.on_else }
    | Return (target, value) -> Return (target, go value)
    | Gen_create g ->
        Gen_create
          { g with ev = f g.ev; tys = List.map desc g.tys;
            places = List.map (fun (p : C.gen_place) ->
              { C.param = f p.param; root = f p.root; read = go p.read; write = go p.write }) g.places;
            dicts = List.map dict g.dicts;
            args = List.map
              (function C.Value a -> C.Value (go a) | Ref v -> Ref (f v)) g.args }
    | Yield a -> Yield (go a)
    | Yield_from y -> Yield_from { y with pull = go y.pull }
    | Gen_step g -> Gen_step { g with cursor = f g.cursor; ev = f g.ev }
    | Gen_close a -> Gen_close (go a)
    | Cleanup_scope { owner; body } ->
        Cleanup_scope { owner = f owner; body = go body }
    | Instance_scope { owner; body } ->
        Instance_scope { owner = f owner; body = go body }
    | Own o -> Own { o with owner = f o.owner; value = go o.value; desc = desc o.desc }
    | Owned_assign a -> Owned_assign { a with target = f a.target; value = go a.value }
    | Owner_alias a ->
        Owner_alias { target = f a.target; root = f a.root; body = go a.body }
    | (Int _ | Float _ | Bool _ | Str _ | Unit | Global_value _ | Break) as k ->
        k
    | Local v -> Local (f v)
    | Global (p, a, ds, dicts) ->
        Global (p, a, List.map desc ds, List.map dict dicts)
    | Intrinsic (x, a, ds, dicts) ->
        Intrinsic (x, a, List.map desc ds, List.map dict dicts)
    | Dep_call d ->
        Dep_call
          {
            d with
            ev = f d.ev;
            dargs = List.map desc d.dargs;
            args = List.map go d.args;
          }
    | With w ->
        With
          {
            w with
            ev = f w.ev;
            outer = f w.outer;
            dargs = List.map desc w.dargs;
            impl = go w.impl;
            desc = desc w.desc;
            body = go w.body;
          }
    | Handler { ev; captures; body } ->
        Handler { ev = f ev; captures = List.map f captures; body = go body }
    | Instance { impls; finally; exclusive } ->
        Instance
          {
            impls = List.map (fun (d, i) -> (d, go i)) impls;
            finally = Option.map go finally;
            exclusive;
          }
    | Narrowed (ds, h) -> Narrowed (ds, go h)
    | With_handler w ->
        With_handler
          {
            ev = f w.ev;
            outer = f w.outer;
            deps =
              List.map
                (fun ((k : C.dkey), p) ->
                  ({ k with kargs = List.map desc k.kargs }, p))
                w.deps;
            handler = go w.handler;
            desc = desc w.desc;
            body = go w.body;
          }
    | Prim (p, args) -> Prim (map_prim f p, List.map go args)
    | Let (v, a, b) -> Let (f v, go a, go b)
    | Covered { body; result; after; return_target } ->
        Covered { body = go body; result = f result; after = go after; return_target }
    | Assign (v, a) -> Assign (f v, go a)
    | If (c, t, e) -> If (go c, go t, go e)
    | Match (s, arms) ->
        Match
          ( go s,
            List.map
              (fun (a : C.arm) ->
                {
                  C.pat = map_pat f a.pat;
                  guard = Option.map go a.guard;
                  body = go a.body;
                })
              arms )
    | While (c, b) -> While (go c, go b)
    | Seq (a, b) -> Seq (go a, go b)
    | Call (callee, args, ev) ->
        Call
          ( go callee,
            List.map
              (function C.Value a -> C.Value (go a) | Ref v -> Ref (f v))
              args,
            f ev )
    | Lambda l ->
        Lambda
          {
            l with
            params =
              List.map (fun (p : C.param) -> { p with var = f p.var }) l.params;
            ev = f l.ev;
            outer = f l.outer;
            captures = List.map f l.captures;
            body = go l.body;
          }
    | Con (p, c, args) -> Con (p, c, List.map go args)
    | Record (p, fs) -> Record (p, List.map (fun (n, x) -> (n, go x)) fs)
    | Field (r, p, n) -> Field (go r, p, n)
    | Of_variant r -> Of_variant (go r)
    | Update (r, n, v) -> Update (go r, n, go v)
    | Array xs -> Array (List.map go xs)
    | Tuple xs -> Tuple (List.map go xs)
    | Tag (t, args, ds) -> Tag (t, List.map go args, List.map desc ds)
    | Fail a -> Fail (go a)
    | Handle h ->
        Handle
          {
            body = go h.body;
            value = f h.value;
            on_value = go h.on_value;
            error = f h.error;
            on_error = go h.on_error;
          }
    | Assert a -> Assert (go a)
    | Assert_equal (a, b, d, dc) -> Assert_equal (go a, go b, desc d, dict dc)
    | Finally (a, b) -> Finally (go a, go b)
  in
  { e with kind }

and map_desc f (d : C.desc) : C.desc =
  match d with
  | Known _ -> d
  | Param v -> Param (f v)
  | Applied (p, ds) -> Applied (p, List.map (map_desc f) ds)
  | Applied_variant (p, c, ds) ->
      Applied_variant (p, c, List.map (map_desc f) ds)
  | Errs r ->
      Errs
        {
          r with
          dlabels =
            List.map (fun (n, ds) -> (n, List.map (map_desc f) ds)) r.dlabels;
        }

and map_dict f (d : C.dict) : C.dict =
  match d with
  | Dict_param v -> Dict_param (f v)
  | Derived dr ->
      Derived
        {
          dr with
          ddesc = map_desc f dr.ddesc;
          from = List.map (fun (k, v) -> (k, f v)) dr.from;
        }

and map_prim f (p : C.prim) : C.prim =
  match p with
  | Equal d -> Equal (map_dict f d)
  | Not_equal d -> Not_equal (map_dict f d)
  | Compare (op, d) -> Compare (op, map_dict f d)
  | Op (r, d) -> Op (r, map_dict f d)
  | Value_of (r, d) -> Value_of (r, map_dict f d)
  | p -> p

and map_pat f (p : C.pattern) : C.pattern =
  let pkind : C.pattern_kind =
    match p.pkind with
    | PVar v -> PVar (f v)
    | PCon (t, c, ps) -> PCon (t, c, List.map (map_pat f) ps)
    | PTag (t, ps) -> PTag (t, List.map (map_pat f) ps)
    | PTuple ps -> PTuple (List.map (map_pat f) ps)
    | PRecord (t, ps) -> PRecord (t, List.map (map_pat f) ps)
    | POr ps -> POr (List.map (map_pat f) ps)
    | PAs (q, v) -> PAs (map_pat f q, f v)
    | (PStr_rest _ | PArray _) as k -> C.map_seq ~pat:(map_pat f) ~var:f k
    | (PWild | PInt _ | PBool _ | PStr _) as k -> k
  in
  { p with pkind }

(* Every variable in [e], bound or used, each as often as it's there. *)
let all_vars (e : C.expr) =
  let found = ref [] in
  ignore
    (map_vars
       (fun v ->
         found := v :: !found;
         v)
       e);
  !found

(* The variables [e] uses from around it, as to_mem.ml's [refs] finds
   them: a block's and a handler's body only through what they
   capture. Each is in the list as often as it's used. *)
let rec uses_of (e : C.expr) acc =
  let desc d acc = List.rev_append (C.desc_vars d) acc in
  let dict d acc = List.rev_append (C.dict_vars d) acc in
  let own =
    match e.kind with
    | Local v | Assign (v, _) | Owned_assign { target = v; _ } -> v :: acc
    | Gen_create { args; places; ev; tys; dicts; _ } ->
        let place_vars = List.concat_map (fun (p : C.gen_place) -> [ p.param; p.root ]) places in
        let refs = List.filter_map (function C.Ref v -> Some v | Value _ -> None) args in
        List.fold_left (fun acc d -> dict d acc)
          (List.fold_right desc tys (ev :: refs @ place_vars @ acc)) dicts
    | Gen_step { cursor; ev; _ } -> cursor :: ev :: acc
    | Own { owner; desc = d; _ } -> desc d (owner :: acc)
    | Pattern_scope { receiving; _ } -> receiving :: acc
    | Owner_alias { target; root; _ } -> target :: root :: acc
    | Call (_, args, ev) ->
        (ev :: List.filter_map (function C.Ref v -> Some v | _ -> None) args)
        @ acc
    | Dep_call { ev; dargs; _ } -> List.fold_right desc dargs (ev :: acc)
    | With { outer; desc = d; dargs; _ } ->
        List.fold_right desc dargs (desc d (outer :: acc))
    | With_handler { outer; desc = d; deps; _ } ->
        List.fold_right
          (fun ((k : C.dkey), _) acc -> List.fold_right desc k.kargs acc)
          deps
          (desc d (outer :: acc))
    | Lambda { captures; _ } | Handler { captures; _ } -> captures @ acc
    | Global (_, _, ds, dicts) | Intrinsic (_, _, ds, dicts) ->
        List.fold_left
          (fun acc d -> dict d acc)
          (List.fold_right desc ds acc)
          dicts
    | Tag (_, _, ds) -> List.fold_right desc ds acc
    | Prim
        ( (Equal d | Not_equal d | Compare (_, d) | Op (_, d) | Value_of (_, d)),
          _ ) ->
        dict d acc
    | Assert_equal (_, _, d, dc) -> dict dc (desc d acc)
    | _ -> acc
  in
  match e.kind with
  | Lambda _ | Handler _ -> own
  | _ -> List.fold_left (fun acc c -> uses_of c acc) own (C.children e)

(* Whether [e], or a block in it, changes [v]: assigns it, or passes it
   with `&`. *)
let rec changes (v : C.var) (e : C.expr) =
  (match e.kind with
    | Assign (w, _) | Owned_assign { target = w; _ }
    | Gen_step { cursor = w; _ } -> w.id = v.id
    | Call (_, args, _) | Gen_create { args; _ } ->
        List.exists (function C.Ref w -> w.id = v.id | Value _ -> false) args
    | _ -> false)
  || List.exists (changes v) (C.children e)

(* The evidence variables bound in [e]: by a [With], a block or a
   handler. *)
let rec bound_evs (e : C.expr) acc =
  let acc =
    match e.kind with
    | With { ev; _ }
    | With_handler { ev; _ }
    | Lambda { ev; _ }
    | Handler { ev; _ } ->
        ev.id :: acc
    | _ -> acc
  in
  List.fold_left (fun acc c -> bound_evs c acc) acc (C.children e)

let max_id (f : C.fn_def) =
  List.fold_left
    (fun m (v : C.var) -> max m v.id)
    0
    ((f.ev :: List.map (fun (p : C.param) -> p.var) f.params) @ all_vars f.body)

(* [vars], each once, in order of id, as a block's captures are. *)
let by_id (vars : C.var list) =
  List.sort_uniq (fun (a : C.var) (b : C.var) -> compare a.id b.id) vars

(* ---- what's made ---- *)

(* A block, lifted to a function of its own: its path, its type, and
   its parameters, its captures, then the block's. A capture it changes is
   `inout`. *)
type lifted = {
  lpath : Path.t;
  lty : Ty.ty;
  caps : C.param list;  (** the writer's variables it captures *)
  bname : string;  (** the block's name *)
  bty : Ty.ty;  (** the block's own type, as a parameter has it *)
  bparams : C.param list;  (** the block's own parameters *)
  buses : Ty.label list;  (** the dependencies it may use, where it's written *)
}

(* A handler known where it's installed: its function, the dependency
   it implements, its state, which the [With] that installs it makes in
   its own frame, and each of its operations, lifted, with its type. Its
   [lets] make the state, and [handler] is its description, whose
   instance shares the state, all in the variables of [hparams], the
   handler's parameters: a [With] makes its own of each. *)
type hspec = {
  hid : int;
  hpath : Path.t;
  hdep : Path.t;
  hparams : C.var list;
  lets : (C.var * C.expr) list;
  state : C.var list;
  handler : C.expr;
  ops : (string * (Path.t * Ty.ty)) list;
}

(* What a call asks for: the function, closed types and error rows, or
   none, kept generic; the block lifted for each block parameter, by its
   number; which of the call's variables the captures of those blocks
   share, as a slot each; and the known handler of each dependency, by
   number. *)
type key = {
  kpath : Path.t;
  kargs : (Ty.ty list * (int * Ty.row) list) option;
  kblocks : (int * Path.t) list;
  kshare : int list list;
  kshape : (Path.t * int) list;
}

(* The copies made, by key. [Hashtbl.hash] looks at only the first 10
   meaningful words of what it hashes, which a key's [kpath] mostly uses
   up, so every copy of one function would land in one bucket and each
   lookup would compare against all of them: O(copies²) for a function
   copied often. [Hashtbl.hash_param 256 1024] looks further in. Equal
   keys still hash the same, so what's found is what [Hashtbl] found. *)
module Keys = Hashtbl.Make (struct
  type t = key

  let equal = ( = )
  let hash = Hashtbl.hash_param 256 1024
end)

type stats = {
  copies : int;
  blocks : int;
  handlers : int;
  past_budget : int;
  notes : (Path.t * Loc.t) list;
      (** each call past the size budget, given the function as written: what it
          calls and where, in the order met *)
}

type cx = {
  fns : (Path.t, C.fn_def) Hashtbl.t;
  eligible : (Path.t, unit) Hashtbl.t;
      (** dependencies whose handler can be known: no block is given one by its
          callee, and no handler needs one *)
  copies : (Path.t * Ty.ty) Keys.t;
  taken : (Path.t, unit) Hashtbl.t;
  suffixes : (Path.t, int) Hashtbl.t;
      (** for each path [fresh_path] was asked for, the smallest suffix that may
          still be free *)
  specs : (Path.t * Ty.args, hspec option) Hashtbl.t;
  own_ev : (Path.t * int, bool) Hashtbl.t;
  todo : (unit -> unit) Queue.t;
      (** the copies still to make, first in first out *)
  made : (string, C.fn_def list) Hashtbl.t;  (** by module, last first *)
  mutable nspecs : int;
  sizes : (Path.t, int) Hashtbl.t;  (** each function's size, [size] *)
  budget : int;  (** how much Core the copies may add up to *)
  mutable spent : int;  (** how much they do so far *)
  mutable st : stats;
}

(* How big an expression is: its nodes, the measure of the size budget. *)
let rec size (e : C.expr) =
  List.fold_left (fun n c -> n + size c) 1 (C.children e)

let fn_size cx (f : C.fn_def) =
  match Hashtbl.find_opt cx.sizes f.path with
  | Some n -> n
  | None ->
      let n = size f.body in
      Hashtbl.replace cx.sizes f.path n;
      n

let add_fn cx (f : C.fn_def) =
  let home = f.path.home in
  Hashtbl.replace cx.made home
    (f :: Option.value (Hashtbl.find_opt cx.made home) ~default:[])

(* A path no function has, in [home], named after [name]: `map$2`. A
   member's copy is still a member of its type, so it's printed after
   it.

   The search starts where the last one for [p] ended, not at 1: a path
   that's taken stays taken, so the smallest free suffix only grows, and
   the names are the ones a search from 1 finds. From 1 each time, the
   nth copy of a function cost n probes, O(copies²) in all. *)
let fresh_path cx (p : Path.t) =
  let rec go n =
    let suffix = "$" ^ string_of_int n in
    let q : Path.t =
      match p.member with
      | Some m -> { p with member = Some { m with mname = m.mname ^ suffix } }
      | None -> { p with name = p.name ^ suffix }
    in
    if Hashtbl.mem cx.taken q || Hashtbl.mem cx.fns q then go (n + 1)
    else (
      Hashtbl.replace cx.taken q ();
      Hashtbl.replace cx.suffixes p (n + 1);
      q)
  in
  go (Option.value (Hashtbl.find_opt cx.suffixes p) ~default:1)

(* A function being made: the next free variable id, and the known
   handlers of the evidence in it so far. *)
type fb = {
  mutable next : int;
  mutable kn : C.known list;
  path : Path.t;  (** its path, which a block lifted out of it is named after *)
}

let fresh fb name ty : C.var =
  fb.next <- fb.next + 1;
  { id = fb.next; name; ty }

(* [kn]'s entries for evidence bound in [body], or [ev]. *)
let known_in (kn : C.known list) (ev : C.var) (body : C.expr) =
  let evs = ev.id :: bound_evs body [] in
  List.filter (fun (k : C.known) -> List.mem k.kev.id evs) kn

(* The evidence [ev] has the known handlers [around]. *)
let note fb (ev : C.var) around =
  List.iter
    (fun (d, ((s : hspec), _)) ->
      fb.kn <- { kev = ev; kdep = d; khandler = s.hpath } :: fb.kn)
    around

(* ---- rewriting a function's body ---- *)

(* Where an expression is rewritten. *)
type env = {
  sub : sub option;  (** its types, closed, or [None] in a generic copy *)
  own_dicts : (int * (int * string)) list;
      (** the original's dictionary parameters, by id: the type variable and the
          requirement each is for *)
  fin : bool;  (** in a handler's `finally` *)
  scope : C.var Ids.t;  (** the variables in scope, by id, as rewritten *)
  blocks : (lifted * C.var list) Ids.t;
      (** the block parameters a copy was given a block for, by id: the block,
          lifted, and the variable here for each of its captures *)
  fn_vars : C.var list option Ids.t;
      (** the blocks bound by `let` here, by id: the variables each may use, or
          [None] if that isn't known *)
  known : (Path.t * (hspec * C.var list)) list Ids.t;
      (** for evidence by id, its known handlers, each with its state here *)
  uses : Ty.label list;  (** the dependencies used here, or installed *)
  cur : C.var;  (** the evidence in scope *)
}

let ty env t =
  match env.sub with None -> t | Some s -> close_ty ~fin:env.fin s t

let cvar env (v : C.var) : C.var = { v with ty = ty env v.ty }
let in_scope env (v : C.var) = { env with scope = Ids.add v.id v env.scope }

let known_at env (ev : C.var) =
  Option.value (Ids.find_opt ev.id env.known) ~default:[]

(* A use's type arguments, for a function of type [scheme]: each row
   of errors closed, and each row of what it uses kept open. *)
let args_ty env (scheme : Ty.ty) (a : Ty.args) : Ty.args =
  match env.sub with
  | None -> a
  | Some _ ->
      let errs = error_vars scheme in
      {
        tys = List.map (ty env) a.tys;
        rows =
          List.mapi
            (fun j (r : Ty.row) ->
              if List.mem j errs then
                match ty env (Errors r) with Errors r -> r | _ -> r
              else
                match ty env (Fun ([], Ty.unit, Ty.closed, r)) with
                | Fun (_, _, _, r) -> r
                | _ -> r)
            a.rows;
      }

(* The type of what a top-level function, a value or an intrinsic is,
   by its scheme's type. *)
let scheme_of cx (p : Path.t) =
  Option.map (fun (f : C.fn_def) -> f.scheme.ty) (Hashtbl.find_opt cx.fns p)

(* The label a dependency's key stands for, as a row of what a block uses
   holds it: its type arguments where they're known, closed. *)
let key_label (k : C.dkey) : Ty.label =
  let rec ty (d : C.desc) : Ty.ty =
    match d with
    | Known t -> t
    | Applied (p, ds) -> Con (p, List.map ty ds)
    | Applied_variant (p, c, ds) -> Variant (p, c, List.map ty ds)
    | Param _ | Errs _ -> Error
  in
  { name = Ty.dep_label k.kpath; payload = List.map ty k.kargs }

(* A descriptor in a copy: known, if its type is closed. *)
let rec desc env (d : C.desc) : C.desc =
  match env.sub with
  | None -> d
  | Some s -> (
      let n = List.length s.tys in
      match d with
      | Known t -> Known (ty env t)
      | Param v when v.id < 0 && -1 - v.id < n && v = C.type_param (-1 - v.id)
        ->
          Known (List.nth s.tys (-1 - v.id))
      | Param v -> Param (cvar env v)
      | Applied (p, ds) -> (
          let ds = List.map (desc env) ds in
          match known ds with
          | Some ts -> Known (Con (p, ts))
          | None -> Applied (p, ds))
      | Applied_variant (p, c, ds) -> (
          let ds = List.map (desc env) ds in
          match known ds with
          | Some ts -> Known (Variant (p, c, ts))
          | None -> Applied_variant (p, c, ds))
      | Errs r -> (
          let row = errs_of_desc env r in
          match row with Some t -> Known t | None -> Errs r))

(* The types descriptors describe, if each is known. *)
and known ds =
  let ts = List.filter_map (function C.Known t -> Some t | _ -> None) ds in
  if List.length ts = List.length ds then Some ts else None

(* An error set's descriptor, closed, as the type it describes, if all
   it holds is known. *)
and errs_of_desc env (r : C.desc_row) : Ty.ty option =
  let labels =
    List.map
      (fun (name, ds) ->
        ( name,
          List.map (desc env) ds
          |> List.map (function C.Known t -> Some t | _ -> None) ))
      r.dlabels
  in
  if List.exists (fun (_, ts) -> List.mem None ts) labels then None
  else
    let row : Ty.row =
      {
        labels =
          List.map
            (fun (name, ts) : Ty.label ->
              { name; payload = List.map Option.get ts })
            labels;
        tail = Option.map (fun t -> t) r.dtail;
      }
    in
    Some (ty env (Errors row))

(* A dictionary in a copy: derived from its known type. *)
let dict env (d : C.dict) : C.dict =
  match env.sub with
  | None -> d
  | Some s -> (
      let derived req t : C.dict =
        Derived { req; dty = t; ddesc = Known t; from = [] }
      in
      match d with
      | Dict_param v -> (
          match List.assoc_opt v.id env.own_dicts with
          | Some (n, req) -> derived req (List.nth s.tys n)
          | None -> bug ("a dictionary that isn't a parameter: " ^ v.name))
      | Derived { req; dty; _ } -> derived req (ty env dty))

let prim env (p : C.prim) : C.prim =
  match p with
  | Equal d -> Equal (dict env d)
  | Not_equal d -> Not_equal (dict env d)
  | Compare (op, d) -> Compare (op, dict env d)
  | Op (r, d) -> Op (r, dict env d)
  | Value_of (r, d) -> Value_of (r, dict env d)
  | p -> p

let rec pattern env (p : C.pattern) : C.pattern * env =
  let env = ref env in
  let rec go (p : C.pattern) : C.pattern =
    let pkind : C.pattern_kind =
      match p.pkind with
      | PVar v ->
          let v = cvar !env v in
          env := in_scope !env v;
          PVar v
      | PCon (t, c, ps) -> PCon (t, c, List.map go ps)
      | PTag (t, ps) -> PTag (t, List.map go ps)
      | PTuple ps -> PTuple (List.map go ps)
      | PRecord (t, ps) -> PRecord (t, List.map go ps)
      | PAs (q, v) ->
          let q = go q in
          let v = cvar !env v in
          env := in_scope !env v;
          PAs (q, v)
      | POr (first :: rest) ->
          let first = go first in
          POr (first :: List.map (fun q -> fst (pattern !env q)) rest)
      | (PStr_rest _ | PArray _) as k ->
          C.map_seq ~pat:go
            ~var:(fun v ->
              let v = cvar !env v in
              env := in_scope !env v;
              v)
            k
      | (PWild | PInt _ | PBool _ | PStr _ | POr []) as k -> k
    in
    { p with pkind; pty = ty !env p.pty }
  in
  let p = go p in
  (p, !env)

(* A use of a function made here, at its own type. *)
let global (p : Path.t) (t : Ty.ty) loc : C.expr =
  C.mk (Global (p, Ty.own_args t, [], [])) t loc

(* The arguments a lifted block is given for its captures: the
   variables here for them, a changed one with `&`. *)
let cap_args (l : lifted) (vars : C.var list) loc =
  List.map2
    (fun (c : C.param) (v : C.var) ->
      if c.mode = Inout then C.Ref v else Value (C.local v loc))
    l.caps vars

(* Whether the block parameter [i] of [f] is only ever called, or passed
   on to a call, with [f]'s own evidence, or a block's that's [f]'s: so a
   copy that calls the block lifted gives it the evidence where it was
   written, which its caller passed [f]. *)
let own_ev cx (f : C.fn_def) i =
  match Hashtbl.find_opt cx.own_ev (f.path, i) with
  | Some b -> b
  | None ->
      let p = (List.nth f.params i).var in
      let roots = Hashtbl.create 16 in
      Hashtbl.replace roots f.ev.id f.ev.id;
      let root (v : C.var) = Hashtbl.find_opt roots v.id in
      let rec scan (e : C.expr) =
        (match e.kind with
        | Lambda { ev; outer; given = []; _ } -> (
            match root outer with
            | Some r -> Hashtbl.replace roots ev.id r
            | None -> ())
        | _ -> ());
        List.iter scan (C.children e)
      in
      scan f.body;
      let own (ev : C.var) = root ev = Some f.ev.id in
      let is_p (a : C.expr) =
        match a.kind with Local v -> v.id = p.id | _ -> false
      in
      let rec ok (e : C.expr) =
        match e.kind with
        | Call (callee, args, ev) ->
            let here =
              is_p callee
              || List.exists
                   (function C.Value a -> is_p a | Ref _ -> false)
                   args
            in
            ((not here) || own ev)
            && (match callee.kind with Local _ -> true | _ -> ok callee)
            && List.for_all
                 (function C.Value a -> is_p a || ok a | Ref _ -> true)
                 args
        | Local v -> v.id <> p.id
        | _ -> List.for_all ok (C.children e)
      in
      let b = ok f.body in
      Hashtbl.replace cx.own_ev (f.path, i) b;
      b

(* Whether [v] holds data, as a block's captures that are slots do, not
   evidence, a type or a dictionary. *)
let is_data (v : C.var) =
  not (List.mem v.ty [ C.evidence_ty; C.type_ty; C.dict_ty; C.owner_ty ])

(* The variables here a block [x], rewritten, may use when it's called:
   what it captures, and what the blocks bound by `let` it uses may, or
   [None] if that isn't known. A block parameter can't use this
   function's variables, which exclusivity sees to. *)
let reach env (x : C.expr) =
  List.fold_left
    (fun acc (v : C.var) ->
      match (acc, Ids.find_opt v.id env.fn_vars) with
      | None, _ | _, Some None -> None
      | Some vs, Some (Some ws) -> Some (ws @ vs)
      | Some vs, None -> Some (if is_data v then v :: vs else vs))
    (Some []) (uses_of x [])

let rec rw cx fb env (e : C.expr) : C.expr =
  let mk kind : C.expr = { e with kind; ty = ty env e.ty } in
  let r = rw cx fb env in
  let arg = function C.Value a -> C.Value (r a) | Ref v -> Ref (cvar env v) in
  match e.kind with
  | Source_view s -> mk (Source_view { s with value = r s.value })
  | Pattern_scope p ->
      let owner = cvar env p.owner and receiving = cvar env p.receiving in
      let source_env = in_scope env owner in
      let pat, match_env = pattern env p.pat in
      mk (Pattern_scope { owner; receiving; binding = Option.map (cvar env) p.binding;
        source = rw cx fb source_env p.source; pat;
        on_match = rw cx fb match_env p.on_match;
        on_else = Option.map (rw cx fb source_env) p.on_else })
  | Return (_, value) -> mk (Return (fb.path, r value))
  | Gen_create g ->
      let type_args =
        match Hashtbl.find_opt cx.fns g.producer with
        | Some ({ generator = Some producer; _ } : C.fn_def) ->
            args_ty env
              (Fun (producer.params, producer.item, producer.errors, producer.uses))
              g.type_args
        | Some producer -> args_ty env producer.scheme.ty g.type_args
        | None -> g.type_args
      in
      mk (Gen_create
        { g with type_args; ev = cvar env g.ev; args = List.map arg g.args;
          places = List.map (fun (p : C.gen_place) ->
            { C.param = cvar env p.param; root = cvar env p.root;
              read = r p.read; write = r p.write }) g.places;
          tys = List.map (desc env) g.tys; dicts = List.map (dict env) g.dicts })
  | Yield a -> mk (Yield (r a))
  | Yield_from y -> mk (Yield_from { y with pull = r y.pull })
  | Gen_step g ->
      let errors, uses =
        match ty env (Fun ([], Ty.unit, g.errors, g.uses)) with
        | Fun (_, _, errors, uses) -> (errors, uses)
        | _ -> bug "a generator step without rows"
      in
      mk (Gen_step { cursor = cvar env g.cursor; ev = cvar env g.ev; errors; uses })
  | Gen_close a -> mk (Gen_close (r a))
  | Cleanup_scope { owner; body } ->
      let owner = cvar env owner in
      mk (Cleanup_scope { owner; body = rw cx fb (in_scope env owner) body })
  | Instance_scope { owner; body } ->
      let owner = cvar env owner in
      mk (Instance_scope { owner; body = rw cx fb (in_scope env owner) body })
  | Own o ->
      mk (Own { o with owner = cvar env o.owner; value = r o.value; desc = desc env o.desc })
  | Owned_assign a ->
      mk (Owned_assign { a with target = cvar env a.target; value = r a.value })
  | Owner_alias a ->
      mk (Owner_alias { target = cvar env a.target; root = cvar env a.root; body = r a.body })
  | Int _ | Float _ | Bool _ | Str _ | Unit | Break -> mk e.kind
  | Local v -> (
      match Ids.find_opt v.id env.blocks with
      | Some (l, vars) -> rematerialize fb env e l vars
      | None -> mk (Local (cvar env v)))
  | Global (p, a, ds, dicts) -> (
      let ds = List.map (desc env) ds and dicts = List.map (dict env) dicts in
      match scheme_of cx p with
      | Some s ->
          let a = args_ty env s a in
          { e with kind = Global (p, a, ds, dicts); ty = Ty.apply a s }
      | None -> mk (Global (p, a, ds, dicts)))
  | Global_value (p, a) -> (
      match scheme_of cx p with
      | Some (Fun (_, t, _, _) as s) ->
          let a = args_ty env s a in
          { e with kind = Global_value (p, a); ty = Ty.apply a t }
      | _ -> mk (Global_value (p, a)))
  | Intrinsic (x, a, ds, dicts) ->
      let s = (Prelude.scheme x).ty in
      let a = args_ty env s a in
      {
        e with
        kind =
          Intrinsic (x, a, List.map (desc env) ds, List.map (dict env) dicts);
        ty = Ty.apply a s;
      }
  | Dep_call d -> (
      let args = List.map r d.args in
      let dargs = List.map (desc env) d.dargs in
      (* a generic dependency's handler is never known: its instance is
         found by its type arguments, through evidence *)
      match List.assoc_opt d.dep (known_at env d.ev) with
      | Some (spec, state) when (not d.next) && d.dargs = [] ->
          let p, t = List.assoc d.op spec.ops in
          mk
            (Call
               ( global p t e.loc,
                 List.map (fun v -> C.Value (C.local v e.loc)) state
                 @ List.map (fun a -> C.Value a) args,
                 cvar env d.ev ))
      | _ ->
          mk
            (Dep_call
               { d with fty = ty env d.fty; ev = cvar env d.ev; dargs; args }))
  | With { ev; outer; dep; dargs; from; impl; desc = d; body } -> (
      let ev' = cvar env ev and outer' = cvar env outer in
      let dargs = List.map (desc env) dargs in
      let around = List.remove_assoc dep (known_at env outer) in
      let inner known =
        note fb ev' known;
        {
          (in_scope env ev') with
          known = Ids.add ev.id known env.known;
          uses = key_label { kpath = dep; kargs = dargs } :: env.uses;
          cur = ev';
        }
      in
      (* only a dependency that isn't generic, installed as itself, has
         its handler known *)
      match
        if dargs = [] && from = dep then known_handler cx fb env dep impl
        else None
      with
      | Some (spec, lets, handler, state) ->
          fb.kn <- { kev = ev'; kdep = dep; khandler = spec.hpath } :: fb.kn;
          let env_b =
            List.fold_left
              (fun env (v, _) -> in_scope env v)
              (inner ((dep, (spec, state)) :: around))
              lets
          in
          let w =
            mk
              (With
                 {
                   ev = ev';
                   outer = outer';
                   dep;
                   dargs;
                   from;
                   impl = handler;
                   desc = desc env d;
                   body = rw cx fb env_b body;
                 })
          in
          cx.st <- { cx.st with handlers = cx.st.handlers + 1 };
          List.fold_right
            (fun ((v : C.var), x) b -> C.mk (Let (v, x, b)) w.ty e.loc)
            lets w
      | None ->
          mk
            (With
               {
                 ev = ev';
                 outer = outer';
                 dep;
                 dargs;
                 from;
                 impl = r impl;
                 desc = desc env d;
                 body = rw cx fb (inner around) body;
               }))
  | With_handler w ->
      let ev' = cvar env w.ev in
      let deps =
        List.map
          (fun ((k : C.dkey), p) ->
            ({ k with kargs = List.map (desc env) k.kargs }, p))
          w.deps
      in
      let around =
        List.filter
          (fun (d, _) ->
            not (List.exists (fun ((k : C.dkey), _) -> k.kpath = d) deps))
          (known_at env w.outer)
      in
      note fb ev' around;
      let env_b =
        {
          (in_scope env ev') with
          known = Ids.add w.ev.id around env.known;
          uses = List.map (fun (k, _) -> key_label k) deps @ env.uses;
          cur = ev';
        }
      in
      mk
        (With_handler
           {
             deps;
             ev = ev';
             outer = cvar env w.outer;
             handler = r w.handler;
             desc = desc env w.desc;
             body = rw cx fb env_b w.body;
           })
  | Narrowed (ds, h) -> mk (Narrowed (ds, r h))
  | Handler { ev; captures; body } ->
      (* it sees only what it captures, and what's installed where it's
         installed: nothing known *)
      let ev' = cvar env ev in
      (* a hidden type or dictionary parameter a copy doesn't have isn't
         captured *)
      let captures =
        List.filter_map
          (fun (v : C.var) -> Ids.find_opt v.id env.scope)
          captures
      in
      (* its arms run with what it needs, which a block lifted from one
         may use too *)
      let needs =
        match Ty.impl_parts (ty env e.ty) with
        | Some (_, needs) -> needs.labels
        | None -> []
      in
      let env_h =
        {
          env with
          scope =
            List.fold_left
              (fun s (v : C.var) -> Ids.add v.id v s)
              Ids.empty (ev' :: captures);
          blocks = Ids.empty;
          known = Ids.empty;
          cur = ev';
          uses = needs @ env.uses;
        }
      in
      mk (Handler { ev = ev'; captures; body = rw cx fb env_h body })
  | Instance { impls; finally; exclusive } ->
      mk
        (Instance
           {
             impls = List.map (fun (d, i) -> (d, r i)) impls;
             finally = Option.map (rw cx fb { env with fin = true }) finally;
             exclusive;
           })
  | Prim (p, args) -> mk (Prim (prim env p, List.map r args))
  | Let (v, a, b) ->
      let v' = cvar env v and a = r a in
      let env = in_scope env v' in
      let env =
        match v.ty with
        | Fun _ ->
            let vs = if changes v b then None else reach env a in
            { env with fn_vars = Ids.add v.id vs env.fn_vars }
        | _ -> env
      in
      mk (Let (v', a, rw cx fb env b))
  | Covered { body; result; after; return_target } ->
      let body = r body in
      let result = cvar env result in
      let env = in_scope env result in
      let return_target = Option.map (fun _ -> fb.path) return_target in
      mk (Covered { body; result; after = rw cx fb env after; return_target })
  | Assign (v, a) -> mk (Assign (cvar env v, r a))
  | If (c, t, f) -> mk (If (r c, r t, r f))
  | Match (s, arms) ->
      let s = r s in
      mk
        (Match
           ( s,
             List.map
               (fun (a : C.arm) ->
                 let pat, env_a = pattern env a.pat in
                 {
                   C.pat;
                   guard = Option.map (rw cx fb env_a) a.guard;
                   body = rw cx fb env_a a.body;
                 })
               arms ))
  | While (c, b) -> mk (While (r c, r b))
  | Seq (a, b) -> mk (Seq (r a, r b))
  | Call ({ kind = Global (p, a, ds, dicts); _ }, args, cev)
    when Hashtbl.mem cx.fns p ->
      call cx fb env e p a ds dicts args cev
  | Call ({ kind = Local v; _ }, args, cev) when Ids.mem v.id env.blocks ->
      let l, vars = Ids.find v.id env.blocks in
      mk
        (Call
           ( global l.lpath l.lty e.loc,
             cap_args l vars e.loc @ List.map arg args,
             cvar env cev ))
  | Call (callee, args, cev) ->
      mk (Call (r callee, List.map arg args, cvar env cev))
  | Lambda _ -> fst (lambda cx fb env e)
  | Con (p, c, args) -> mk (Con (p, c, List.map r args))
  | Record (p, fs) -> mk (Record (p, List.map (fun (n, x) -> (n, r x)) fs))
  | Field (x, p, n) -> mk (Field (r x, p, n))
  | Of_variant x -> mk (Of_variant (r x))
  | Update (x, n, v) -> mk (Update (r x, n, r v))
  | Array xs -> mk (Array (List.map r xs))
  | Tuple xs -> mk (Tuple (List.map r xs))
  | Tag (t, args, ds) -> mk (Tag (t, List.map r args, List.map (desc env) ds))
  | Fail a -> mk (Fail (r a))
  | Handle h ->
      let value = cvar env h.value and error = cvar env h.error in
      mk
        (Handle
           {
             body = r h.body;
             value;
             on_value = rw cx fb (in_scope env value) h.on_value;
             error;
             on_error = rw cx fb (in_scope env error) h.on_error;
           })
  | Assert a -> mk (Assert (r a))
  | Assert_equal (a, b, d, dc) ->
      mk (Assert_equal (r a, r b, desc env d, dict env dc))
  | Finally (a, b) -> mk (Finally (r a, r b))

(* A block written here, its body rewritten: as a block, which captures
   what its body now uses, and, if it can be lifted, what lifting it
   needs. It can be if its callee provides it nothing, it takes no
   block and nothing `inout`, and it captures only values and cells of
   closed types, besides the evidence where it's written. *)
and lambda cx fb env (e : C.expr) : C.expr * (unit -> lifted) option =
  match e.kind with
  | Lambda { name; params; ev; outer; given; body; _ } ->
      let ev' = cvar env ev and outer' = cvar env outer in
      let params =
        List.map (fun (p : C.param) -> { p with var = cvar env p.var }) params
      in
      let given =
        List.map
          (fun (k : C.dkey) ->
            let k = { k with kargs = List.map (desc env) k.kargs } in
            (* `uses D`, once [D] is known: the dependency it's a
               description of (Ty.known_label) *)
            match (k.kpath = Ty.param_path, k.kargs) with
            | true, [ Known t ] -> (
                match Ty.key_ty t with
                | Impl { deps = [ x ]; _ } when x.dpath <> Ty.param_path ->
                    { C.kpath = x.dpath; kargs = List.map (fun a -> C.Known a) x.dargs }
                | _ -> k)
            | _ -> k)
          given
      in
      let around =
        List.filter
          (fun (d, _) ->
            not (List.exists (fun (k : C.dkey) -> k.kpath = d) given))
          (known_at env outer)
      in
      note fb ev' around;
      let env_in =
        {
          (List.fold_left
             (fun env (p : C.param) -> in_scope env p.var)
             (in_scope env ev') params)
          with
          known = Ids.add ev.id around env.known;
          uses = List.map key_label given @ env.uses;
          cur = ev';
        }
      in
      let body = rw cx fb env_in body in
      (* what it captures, as lowering finds it, with what rewriting its
         body made it use: a known handler's state, say *)
      let used = Lower.free body in
      let from_here =
        by_id
          (List.filter_map
             (fun (v : C.var) ->
               if
                 v.id = ev'.id
                 || List.exists (fun (p : C.param) -> p.var.id = v.id) params
               then None
               else Ids.find_opt v.id env.scope)
             used)
      in
      let captures = by_id (outer' :: from_here) in
      let t = ty env e.ty in
      let block : C.expr =
        {
          e with
          kind =
            Lambda
              { name; params; ev = ev'; outer = outer'; given; captures; body };
          ty = t;
        }
      in
      let caps = List.filter (fun (v : C.var) -> v.id <> outer'.id) from_here in
      let liftable =
        given = []
        && List.for_all
             (fun (p : C.param) ->
               p.mode = Read && match p.var.ty with Fun _ -> false | _ -> true)
             params
        && closed t
        && List.for_all
             (fun (v : C.var) ->
               closed v.ty
               && not (List.mem v.ty [ C.evidence_ty; C.type_ty; C.dict_ty; C.owner_ty ]))
             caps
        && not (List.exists (fun (v : C.var) -> v.id = outer'.id) used)
      in
      let lift () =
        let caps =
          List.map
            (fun (v : C.var) : C.param ->
              { mode = (if changes v body then Inout else Read); var = v })
            caps
        in
        let ret, errs =
          match t with
          | Fun (_, ret, errs, _) -> (ret, errs)
          | _ -> bug "a block whose type isn't a function's"
        in
        let buses = List.sort_uniq compare env.uses in
        let lty : Ty.ty =
          Fun
            ( List.map
                (fun (p : C.param) : Ty.param ->
                  { mode = p.mode; ty = p.var.ty })
                (caps @ params),
              ret,
              errs,
              { labels = Ty.sort_labels buses; tail = None } )
        in
        {
          lpath = Path.make "" "";
          lty;
          caps;
          bname = name;
          bty = t;
          bparams = params;
          buses;
        }
      in
      (block, if liftable then Some lift else None)
  | _ -> bug "a block that isn't a lambda"

(* The lifted block [l] as a function of its own, named after the one
   it's written in, [writer], with its rewritten [body]. *)
and add_lifted cx fb (writer : Path.t) (l : lifted) (ev : C.var) body loc =
  let n =
    match String.rindex_opt l.bname '#' with
    | Some i -> String.sub l.bname (i + 1) (String.length l.bname - i - 1)
    | None -> "block"
  in
  let base = Path.make writer.home (Path.local writer ^ "#" ^ n) in
  let path =
    if Hashtbl.mem cx.taken base || Hashtbl.mem cx.fns base then
      fresh_path cx base
    else (
      Hashtbl.replace cx.taken base ();
      base)
  in
  let l = { l with lpath = path } in
  add_fn cx
    {
      path;
      params = l.caps @ l.bparams;
      ev;
      tys = [];
      dicts = [];
      scheme = { ty = l.lty; names = []; reqs = []; row_reqs = []; tparams = []; modes = []; defaults = [] };
      body;
      test = false;
      loc;
      origin = Lifted_block l.bname;
      generator = None;
      known = known_in fb.kn ev body;
    };
  cx.st <- { cx.st with blocks = cx.st.blocks + 1 };
  l

(* A block parameter given a lifted block, used as a block again, where
   it can't be passed lifted: a block that calls the lifted one with the
   captures it was given. *)
and rematerialize fb env (e : C.expr) (l : lifted) (vars : C.var list) =
  let ev = fresh fb "ev" C.evidence_ty in
  note fb ev (known_at env env.cur);
  let params =
    List.map
      (fun (p : C.param) : C.param ->
        { p with var = fresh fb p.var.name p.var.ty })
      l.bparams
  in
  let ret =
    match l.bty with Fun (_, r, _, _) -> r | _ -> bug "a block's type"
  in
  let body =
    C.mk
      (Call
         ( global l.lpath l.lty e.loc,
           cap_args l vars e.loc
           @ List.map
               (fun (p : C.param) -> C.Value (C.local p.var e.loc))
               params,
           ev ))
      ret e.loc
  in
  C.mk
    (Lambda
       {
         name = l.bname;
         params;
         ev;
         outer = env.cur;
         given = [];
         captures = by_id (env.cur :: vars);
         body;
       })
    l.bty e.loc

(* A call of the function [p] at [a]: of a copy for what the call knows,
   or of [p] as it's written. *)
and call cx fb env (e : C.expr) p (a : Ty.args) ds dicts args (cev : C.var) =
  let src = Hashtbl.find cx.fns p in
  let a = args_ty env src.scheme.ty a in
  let ds = List.map (desc env) ds and dicts = List.map (dict env) dicts in
  let cev' = cvar env cev in
  let ps = match src.scheme.ty with Fun (ps, _, _, _) -> ps | _ -> [] in
  (* each argument: a block lifted already, one written here that can
     be, or anything else, rewritten *)
  let classified =
    List.mapi
      (fun i ((q : Ty.param), x) ->
        match (q.ty, x) with
        | Fun _, C.Value { kind = Local v; _ }
          when Ids.mem v.id env.blocks && own_ev cx src i ->
            let l, vars = Ids.find v.id env.blocks in
            `Pass (l, vars)
        | Fun _, C.Value ({ kind = Lambda { outer; _ }; _ } as b)
          when outer.id = cev.id && own_ev cx src i -> (
            match lambda cx fb env b with
            | block, Some lift -> `Lit (block, lift)
            | block, None -> `Plain (C.Value block))
        | _, C.Value x -> `Plain (C.Value (rw cx fb env x))
        | _, C.Ref v -> `Plain (C.Ref (cvar env v)))
      (List.combine ps args)
  in
  (* A lifted block is given its captures when the call is made: by
     value, or `inout`. So none may be a variable an argument passed as
     written may use or change during the call, a block that isn't
     lifted or one passed with `&`, or the copy would compute something
     else; such a block is passed as written too. *)
  let rec settle classified =
    let used =
      List.fold_left
        (fun acc c ->
          match (acc, c) with
          | None, _ -> None
          | Some vs, `Plain (C.Ref v) -> Some (v :: vs)
          | Some vs, `Plain (C.Value (x : C.expr)) -> (
              match x.ty with
              | Fun _ -> Option.map (fun ws -> ws @ vs) (reach env x)
              | _ -> Some vs)
          | Some vs, _ -> Some vs)
        (Some []) classified
    in
    let caps = function
      | `Pass (_, vars) -> List.filter is_data vars
      | `Lit (({ kind = Lambda { captures; _ }; _ } : C.expr), _) ->
          List.filter is_data captures
      | _ -> []
    in
    let clash c =
      caps c <> []
      &&
      match used with
      | None -> true
      | Some vs ->
          List.exists
            (fun (v : C.var) -> List.exists (fun (w : C.var) -> w.id = v.id) vs)
            (caps c)
    in
    if not (List.exists clash classified) then classified
    else
      settle
        (List.map
           (fun c ->
             if not (clash c) then c
             else
               match c with
               | `Pass (l, vars) ->
                   `Plain (C.Value (rematerialize fb env e l vars))
               | `Lit (block, _) -> `Plain (C.Value block)
               | c -> c)
           classified)
  in
  let classified = settle classified in
  let as_written () : C.expr =
    let args =
      List.map
        (function
          | `Plain x -> x
          | `Pass (l, vars) -> C.Value (rematerialize fb env e l vars)
          | `Lit (block, _) -> C.Value block)
        classified
    in
    {
      e with
      kind =
        Call
          ( C.mk (Global (p, a, ds, dicts)) (Ty.apply a src.scheme.ty) e.loc,
            args,
            cev' );
      ty = ty env e.ty;
    }
  in
  let kargs =
    match env.sub with
    | Some _ when List.for_all closed a.tys ->
        Some
          ( a.tys,
            List.map
              (fun j ->
                ( j,
                  match List.nth_opt a.rows j with
                  | Some (r : Ty.row) -> { r with tail = None }
                  | None -> Ty.closed ))
              (error_vars src.scheme.ty) )
    | _ -> None
  in
  let indexed = List.mapi (fun i c -> (i, c)) classified in
  let has_blocks =
    List.exists (function `Plain _ -> false | _ -> true) classified
  in
  (* the handlers known here of what the callee uses, or a block it's
     given does *)
  let uses =
    (match Ty.apply a src.scheme.ty with
      | Fun (_, _, _, u) -> u.labels
      | _ -> [])
    @ List.concat_map
        (function
          | `Pass ((l : lifted), _) -> l.buses
          | `Lit _ -> env.uses
          | `Plain _ -> [])
        classified
  in
  let shape =
    List.filter
      (fun (d, _) -> List.mem (Ty.label (Ty.dep_label d)) uses)
      (List.sort (fun (d, _) (d', _) -> compare d d') (known_at env cev))
  in
  (* past the size budget, a call that needs a new copy, and knows no
     handler, gets [p] as written, and is reported *)
  let spent = cx.spent >= cx.budget && shape = [] in
  let past_budget () =
    cx.st <-
      {
        cx.st with
        past_budget = cx.st.past_budget + 1;
        notes = (p, e.loc) :: cx.st.notes;
      };
    as_written ()
  in
  if kargs = None && (not has_blocks) && shape = [] then as_written ()
  else if
    spent && List.exists (function _, `Lit _ -> true | _ -> false) indexed
  then past_budget ()
  else
    (* each block written here, lifted; a block lifted already is passed
       on as it is *)
    let lift i = function
      | `Pass (l, vars) -> Some (i, l, vars)
      | `Lit (({ kind = Lambda { ev; body; _ }; loc; _ } : C.expr), lift) ->
          let l = add_lifted cx fb fb.path (lift ()) ev body loc in
          Some (i, l, List.map (fun (q : C.param) -> q.var) l.caps)
      | _ -> None
    in
    let blocks = List.filter_map (fun (i, c) -> lift i c) indexed in
    (* the captures' variables here, each once: the copy's slots *)
    let slots =
      List.fold_left
        (fun acc (_, (l : lifted), vars) ->
          List.fold_left2
            (fun acc (c : C.param) (v : C.var) ->
              match List.assoc_opt v.id acc with
              | Some (w, mode) ->
                  let mode = if c.mode = Inout then C.Inout else mode in
                  List.map
                    (fun (id, x) ->
                      if id = v.id then (id, (w, mode)) else (id, x))
                    acc
              | None -> acc @ [ (v.id, (v, c.mode)) ])
            acc l.caps vars)
        [] blocks
    in
    let slot_of (v : C.var) =
      let rec find i = function
        | [] -> bug "a capture without a slot"
        | (id, _) :: _ when id = v.id -> i
        | _ :: rest -> find (i + 1) rest
      in
      find 0 slots
    in
    let key =
      {
        kpath = p;
        kargs;
        kblocks = List.map (fun (i, (l : lifted), _) -> (i, l.lpath)) blocks;
        kshare = List.map (fun (_, _, vars) -> List.map slot_of vars) blocks;
        kshape = List.map (fun (d, ((s : hspec), _)) -> (d, s.hid)) shape;
      }
    in
    match Keys.find_opt cx.copies key with
    | None when spent -> past_budget ()
    | found ->
        let path, sty =
          match found with
          | Some c -> c
          | None ->
              make_copy cx key src
                (List.map (fun (i, l, _) -> (i, l)) blocks)
                (List.map (fun (_, (w, mode)) -> (w, mode)) slots)
                (List.map (fun (d, (s, _)) -> (d, s)) shape)
        in
        let rest =
          List.filter_map
            (fun (i, c) ->
              if List.exists (fun (j, _, _) -> j = i) blocks then None
              else
                match c with
                | `Plain x -> Some x
                | `Lit (block, _) -> Some (C.Value block)
                | `Pass (l, vars) ->
                    Some (C.Value (rematerialize fb env e l vars)))
            indexed
        in
        let slot_args =
          List.map
            (fun (_, ((v : C.var), mode)) ->
              if mode = C.Inout then C.Ref v else C.Value (C.local v e.loc))
            slots
        in
        let state_args =
          List.concat_map
            (fun (_, (_, state)) ->
              List.map (fun v -> C.Value (C.local v e.loc)) state)
            shape
        in
        let own = Ty.own_args sty in
        let generic = kargs = None in
        let cargs : Ty.args =
          {
            tys = (if generic then a.tys else []);
            rows = List.filteri (fun j _ -> j < List.length own.rows) a.rows;
          }
        in
        let callee =
          C.mk
            (Global
               ( path,
                 cargs,
                 (if generic then ds else []),
                 if generic then dicts else [] ))
            (Ty.apply cargs sty) e.loc
        in
        {
          e with
          kind = Call (callee, rest @ slot_args @ state_args, cev');
          ty = ty env e.ty;
        }

(* The copy of [src] [key] asks for, made later from the worklist: its
   path and type now. [blocks] are the blocks lifted for its block
   parameters, by number, [slots] the variables of the call that are its
   captures, each once, and [shape] its known handlers. *)
and make_copy cx key (src : C.fn_def) blocks slots shape =
  let path = fresh_path cx src.path in
  cx.spent <- cx.spent + fn_size cx src;
  let sub = Option.map (fun (tys, errs) -> { tys; errs }) key.kargs in
  let env0 =
    {
      sub;
      own_dicts =
        List.map2 (fun (v : C.var) r -> (v.id, r)) src.dicts src.scheme.reqs;
      fin = false;
      scope = Ids.empty;
      blocks = Ids.empty;
      fn_vars = Ids.empty;
      known = Ids.empty;
      uses = [];
      cur = src.ev;
    }
  in
  let fb = { next = max_id src + 1; kn = []; path } in
  let ps, ret, errs, uses =
    match ty env0 src.scheme.ty with
    | Fun (ps, r, e, u) -> (ps, r, e, u)
    | _ -> bug "a function whose type isn't a function's"
  in
  let in_key i = List.mem_assoc i blocks in
  let params =
    List.filteri
      (fun i _ -> not (in_key i))
      (List.map
         (fun (p : C.param) -> { p with var = cvar env0 p.var })
         src.params)
  in
  let pts = List.filteri (fun i _ -> not (in_key i)) ps in
  let slot_params =
    List.map
      (fun ((v : C.var), mode) : C.param ->
        { mode; var = fresh fb v.name v.ty })
      slots
  in
  let state_params =
    List.map
      (fun (d, (s : hspec)) ->
        (d, s, List.map (fun (v : C.var) -> fresh fb v.name v.ty) s.state))
      shape
  in
  let buses = List.concat_map (fun (_, (l : lifted)) -> l.buses) blocks in
  let uses : Ty.row =
    {
      uses with
      labels = Ty.sort_labels (List.sort_uniq compare (uses.labels @ buses));
    }
  in
  let sty : Ty.ty =
    Fun
      ( pts
        @ List.map
            (fun (q : C.param) : Ty.param -> { mode = q.mode; ty = q.var.ty })
            slot_params
        @ List.concat_map
            (fun (_, _, vs) -> List.map (fun (v : C.var) -> Ty.read v.ty) vs)
            state_params,
        ret,
        errs,
        uses )
  in
  Keys.replace cx.copies key (path, sty);
  cx.st <- { cx.st with copies = cx.st.copies + 1 };
  let job () =
    let ev = cvar env0 src.ev in
    let all_params =
      params @ slot_params
      @ List.concat_map
          (fun (_, _, vs) ->
            List.map (fun v : C.param -> { mode = Read; var = v }) vs)
          state_params
    in
    let hidden = if sub = None then src.tys @ src.dicts else [] in
    let scope =
      List.fold_left
        (fun s (v : C.var) -> Ids.add v.id v s)
        Ids.empty
        ((ev :: hidden) @ List.map (fun (p : C.param) -> p.var) all_params)
    in
    (* each lifted block's captures, as the slots they share *)
    let block_vars =
      List.fold_left2
        (fun m (i, (l : lifted)) share ->
          let v = (List.nth src.params i).var in
          Ids.add v.id
            (l, List.map (fun s -> (List.nth slot_params s).var) share)
            m)
        Ids.empty blocks key.kshare
    in
    List.iter
      (fun (d, (s : hspec), _) ->
        fb.kn <- { kev = ev; kdep = d; khandler = s.hpath } :: fb.kn)
      state_params;
    let env =
      {
        env0 with
        scope;
        blocks = block_vars;
        known =
          Ids.singleton src.ev.id
            (List.map (fun (d, s, vs) -> (d, (s, vs))) state_params);
        uses = uses.labels;
        cur = ev;
      }
    in
    let body = rw cx fb env src.body in
    let scheme : Ty.scheme =
      match sub with
      | Some _ -> { ty = sty; names = []; reqs = []; row_reqs = []; tparams = []; modes = []; defaults = [] }
      | None -> { src.scheme with ty = sty }
    in
    add_fn cx
      {
        path;
        params = all_params;
        ev;
        tys = (if sub = None then src.tys else []);
        dicts = (if sub = None then src.dicts else []);
        scheme;
        body;
        test = src.test;
        loc = src.loc;
        origin = Copy src.path;
        generator = src.generator;
        known = known_in fb.kn ev body;
      }
  in
  Queue.push job cx.todo;
  (path, sty)

(* The handler [impl] installs for [dep], if it's known: a call of a
   handler's function, at closed types, whose description is its state
   and an instance of simple operations, which need nothing, with no
   `finally`. Its state, made here, and its description, sharing it. *)
and known_handler cx fb env dep (impl : C.expr) =
  match impl.kind with
  | Call ({ kind = Global (h, a, _, _); _ }, hargs, _)
    when Hashtbl.mem cx.eligible dep && env.sub <> None -> (
      let a =
        match scheme_of cx h with Some t -> args_ty env t a | None -> a
      in
      if not (List.for_all closed a.tys) then None
      else
        match spec cx h a dep with
        | None -> None
        | Some s ->
            let hargs =
              List.map
                (function
                  | C.Value x -> rw cx fb env x
                  | Ref _ -> bug "a handler given `&`")
                hargs
            in
            (* the state's variables, and the parameters', made fresh here *)
            let fresh_vars = Hashtbl.create 16 in
            let rename (v : C.var) =
              match Hashtbl.find_opt fresh_vars v.id with
              | Some w -> w
              | None ->
                  let w = fresh fb v.name v.ty in
                  Hashtbl.replace fresh_vars v.id w;
                  w
            in
            let params = List.map rename s.hparams in
            let lets =
              List.map2 (fun v x -> (v, x)) params hargs
              @ List.map
                  (fun ((v : C.var), x) -> (rename v, map_vars rename x))
                  s.lets
            in
            Some (s, lets, map_vars rename s.handler, List.map rename s.state))
  | _ -> None

(* The handler [h] at [a], if it's one whose instance can be known. *)
and spec cx h (a : Ty.args) dep =
  match Hashtbl.find_opt cx.specs (h, a) with
  | Some s -> s
  | None ->
      (* a handler installed again in its own operations isn't known
         there *)
      Hashtbl.replace cx.specs (h, a) None;
      let s = make_spec cx h a dep in
      Hashtbl.replace cx.specs (h, a) s;
      s

and make_spec cx h (a : Ty.args) dep =
  let src = Hashtbl.find cx.fns h in
  let sub =
    {
      tys = a.tys;
      errs =
        List.map
          (fun j ->
            ( j,
              match List.nth_opt a.rows j with
              | Some (r : Ty.row) -> { r with tail = None }
              | None -> Ty.closed ))
          (error_vars src.scheme.ty);
    }
  in
  match src.body.kind with
  | Handler { captures; _ }
    when List.for_all
           (fun (v : C.var) ->
             List.exists (fun (p : C.param) -> p.var.id = v.id) src.params)
           captures -> (
      let fb = { next = max_id src + 1; kn = []; path = h } in
      let env0 =
        {
          sub = Some sub;
          own_dicts =
            List.map2 (fun (v : C.var) r -> (v.id, r)) src.dicts src.scheme.reqs;
          fin = false;
          scope = Ids.empty;
          blocks = Ids.empty;
          fn_vars = Ids.empty;
          known = Ids.empty;
          uses = [];
          cur = src.ev;
        }
      in
      let env =
        {
          env0 with
          scope =
            List.fold_left
              (fun sc (v : C.var) -> Ids.add v.id v sc)
              Ids.empty
              (List.map (cvar env0)
                 (src.ev :: List.map (fun (p : C.param) -> p.var) src.params));
        }
      in
      let handler = rw cx fb env src.body in
      let simple (x : C.expr) =
        let rec ok (x : C.expr) =
          (match x.kind with
            | Return _ | Gen_create _ | Yield _ | Yield_from _ | Gen_step _ | Gen_close _
            | Cleanup_scope _ | Instance_scope _ | Own _ | Owned_assign _ | Owner_alias _
            | Source_view _ | Pattern_scope _
            | Call _ | Dep_call _ | Lambda _ | Handler _ | With _
            | With_handler _ | Fail _ | Handle _ | Finally _ | Covered _ | While _
            | Assign _ | Assert _ | Assert_equal _ | Global_value _ | Instance _
              ->
                false
            | _ -> true)
          && List.for_all ok (C.children x)
        in
        ok x
      in
      let rec split (x : C.expr) acc =
        match x.kind with
        | Let (v, value, rest) when simple value ->
            split rest ((v, value) :: acc)
        | Instance
            { impls = [ (d, { kind = Record (_, ops); _ }) ]; finally = None; _ }
          when d = dep ->
            Some (List.rev acc, x, ops)
        | _ -> None
      in
      match (handler.kind, Ty.impl_parts handler.ty) with
      | Handler { ev = hev; body; _ }, Some (_, needs)
        when needs.labels = []
             &&
             match handler.ty with
             | Impl { over; _ } -> not over
             | _ -> false -> (
          match split body [] with
          | None -> None
          | Some (lets, instance, ops) ->
              let op_ok (_, (o : C.expr)) =
                match o.kind with
                | Lambda { given = []; params; body; captures; _ } ->
                    List.for_all
                      (fun (p : C.param) ->
                        p.mode = Read
                        && match p.var.ty with Fun _ -> false | _ -> true)
                      params
                    && (not
                          (List.exists
                             (fun (v : C.var) -> v.id = hev.id)
                             (uses_of body [])))
                    && not (List.exists (fun v -> changes v body) captures)
                | _ -> false
              in
              (* a handler known inside its own operations would be known
                 in each copy of its description too: not here *)
              if fb.kn <> [] || not (List.for_all op_ok ops) then None
              else
                let state =
                  by_id
                    (List.filter
                       (fun (v : C.var) -> v.id <> hev.id)
                       (uses_of instance []))
                in
                cx.nspecs <- cx.nspecs + 1;
                let hid = cx.nspecs in
                let ops =
                  List.map
                    (fun (name, (o : C.expr)) ->
                      match o.kind with
                      | Lambda { params; ev; body; _ } ->
                          let base =
                            Path.make h.home (Path.local h ^ "." ^ name)
                          in
                          let path =
                            if Hashtbl.mem cx.taken base then fresh_path cx base
                            else (
                              Hashtbl.replace cx.taken base ();
                              base)
                          in
                          let ret, errs, uses =
                            match o.ty with
                            | Fun (_, r, e, u) -> (r, e, u)
                            | _ ->
                                bug "an operation whose type isn't a function's"
                          in
                          let ps =
                            List.map (fun (v : C.var) -> Ty.read v.ty) state
                            @ List.map
                                (fun (p : C.param) -> Ty.read p.var.ty)
                                params
                          in
                          let t : Ty.ty = Fun (ps, ret, errs, uses) in
                          add_fn cx
                            {
                              path;
                              params =
                                List.map
                                  (fun v : C.param -> { mode = Read; var = v })
                                  state
                                @ params;
                              ev;
                              tys = [];
                              dicts = [];
                              scheme =
                                { ty = t; names = []; reqs = []; row_reqs = []; tparams = []; modes = []; defaults = [] };
                              body;
                              test = false;
                              loc = o.loc;
                              origin = Lifted_op { dep; handler = h; op = name };
                              generator = None;
                              known = known_in fb.kn ev body;
                            };
                          (name, (path, t))
                      | _ -> bug "an operation that isn't a block")
                    ops
                in
                Some
                  {
                    hid;
                    hpath = h;
                    hdep = dep;
                    hparams =
                      List.map (fun (p : C.param) -> cvar env p.var) src.params;
                    lets;
                    state;
                    handler =
                      {
                        handler with
                        kind =
                          Handler
                            { ev = hev; captures = state; body = instance };
                      };
                    ops;
                  })
      | _ -> None)
  | _ -> None

(* The dependencies whose handlers can be known: those no block is
   given by its callee and no handler needs, so a call of one of their
   operations is always where a [With] of the program installs one, or
   in a function called there. Nor one whose handler uses `Async`: its
   operations can wait in `Async.until`, which lets go of the instance
   the interpreter finds by the [Dep_call] (eval.ml); and none at all in
   a program that calls `Async.isolate`, which tells an operation of an
   instance installed inside it from one outside by the same means
   (compiler.md, "Step 3, as built"); nor in one that starts tasks, with
   `Async.scope`, `map`, `each`, `both` or `race`, whose operations of a
   shared instance don't interleave by the same means, and are where `sim`
   chooses which task runs next (step 4). All are about tasks, which only
   the interpreter runs, so a native build loses nothing it has. *)
let eligible (modules : C.program list) =
  let deps = Hashtbl.create 16 and out = Hashtbl.create 16 in
  let tasks = ref false in
  let async = Ty.dep_label (Path.prelude "Async") in
  let rec walk (e : C.expr) =
    (match e.kind with
    | Lambda { given; _ } ->
        List.iter (fun (k : C.dkey) -> Hashtbl.replace out k.kpath ()) given
    | Handler _ -> (
        match Ty.impl_parts e.ty with
        | Some (own, needs) ->
            List.iter
              (fun (l : Ty.label) ->
                Hashtbl.replace out (Ty.dep_path l.name) ())
              needs.labels;
            if List.exists (fun (l : Ty.label) -> l.name = async) needs.labels
            then
              List.iter (fun p -> Hashtbl.replace out p ()) (Ty.dep_paths own)
        | None -> ())
    | Global (p, _, _, _)
      when List.exists
             (fun m -> p = Path.member (Path.prelude "Async") m)
             [ "isolate"; "scope"; "map"; "each"; "both"; "race" ] ->
        tasks := true
    | _ -> ());
    List.iter walk (C.children e)
  in
  List.iter
    (fun (m : C.program) ->
      List.iter
        (fun (d : Iface.type_decl) ->
          (* a generic one's handler is never known ([rw]) *)
          match d.body with
          | Dep _ when d.params = [] -> Hashtbl.replace deps d.path ()
          | _ -> ())
        m.types;
      List.iter (fun (f : C.fn_def) -> walk f.body) m.fns)
    modules;
  Hashtbl.iter (fun d () -> Hashtbl.remove deps d) out;
  if !tasks then Hashtbl.reset deps;
  deps

(* The size budget, unless one is given: [budget_factor] times the
   program's Core, or [budget_floor], whichever is more. Measured, a
   release build's C is 1.25 times a debug build's, whatever the program's
   size (compiler.md, "Native slice", step 9), so this is reached only by
   generic code that makes more generic code at new types without bound;
   the floor keeps a small program from reaching it. *)
let budget_factor = 8
let budget_floor = 1_000_000

let program ?budget (modules : C.program list) =
  let sizes = Hashtbl.create 256 in
  let whole =
    List.fold_left
      (fun n (m : C.program) ->
        List.fold_left
          (fun n (f : C.fn_def) ->
            let k = size f.body in
            Hashtbl.replace sizes f.path k;
            n + k)
          n m.fns)
      0 modules
  in
  let budget =
    match budget with
    | Some b -> b
    | None -> max budget_floor (budget_factor * whole)
  in
  let cx =
    {
      fns = Hashtbl.create 256;
      eligible = eligible modules;
      copies = Keys.create 64;
      taken = Hashtbl.create 64;
      suffixes = Hashtbl.create 64;
      specs = Hashtbl.create 16;
      own_ev = Hashtbl.create 64;
      todo = Queue.create ();
      made = Hashtbl.create 16;
      nspecs = 0;
      sizes;
      budget;
      spent = 0;
      st = { copies = 0; blocks = 0; handlers = 0; past_budget = 0; notes = [] };
    }
  in
  List.iter
    (fun (m : C.program) ->
      List.iter (fun (f : C.fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns)
    modules;
  let entry =
    match List.rev modules with m :: _ -> m | [] -> bug "no modules"
  in
  let start_path = Path.make entry.home Lower.start_name in
  let start =
    match Hashtbl.find_opt cx.fns start_path with
    | Some f -> f
    | None -> bug "a program with no `$start`"
  in
  (* `$start`, in place, from which everything it reaches is copied *)
  let fb = { next = max_id start + 1; kn = []; path = start.path } in
  let uses =
    match start.scheme.ty with Fun (_, _, _, u) -> u.labels | _ -> []
  in
  let env =
    {
      (* a type variable of its own is one inference left undecided *)
      sub = Some { tys = List.map (fun _ -> Ty.unit) start.tys; errs = [] };
      own_dicts =
        List.map2 (fun (v : C.var) r -> (v.id, r)) start.dicts start.scheme.reqs;
      fin = false;
      scope = Ids.singleton start.ev.id start.ev;
      blocks = Ids.empty;
      fn_vars = Ids.empty;
      known = Ids.empty;
      uses;
      cur = start.ev;
    }
  in
  let body = rw cx fb env start.body in
  let start =
    {
      start with
      body;
      tys = [];
      dicts = [];
      scheme =
        { ty = ty env start.scheme.ty; names = []; reqs = []; row_reqs = []; tparams = []; modes = []; defaults = [] };
      known = known_in fb.kn start.ev body;
    }
  in
  let rec drain () =
    match Queue.take_opt cx.todo with
    | None -> ()
    | Some job ->
        job ();
        drain ()
  in
  drain ();
  let modules =
    List.map
      (fun (m : C.program) ->
        let fns =
          List.map
            (fun (f : C.fn_def) -> if f.path = start_path then start else f)
            m.fns
        in
        {
          m with
          fns =
            fns
            @ List.rev
                (Option.value (Hashtbl.find_opt cx.made m.home) ~default:[]);
        })
      modules
  in
  (modules, { cx.st with notes = List.rev cx.st.notes })
