(* Lowering: from the resolved, type-checked tree to Core (core.ml).

   By now every name is resolved (resolve.ml), every expression has a type
   and every constructor and field says which type it's in (infer.ml), so
   lowering only rewrites. What it rewrites:

   - a place is read and written with plain operations. `user.plan = Free`
     becomes `user = { user with plan = Free }`, and `xs[i] += 1` becomes
     `xs = set(xs, i, get(xs, i) + 1)`. An index is evaluated once, into a
     temporary, before anything is read or written.
   - an argument passed with `&` that isn't a plain variable, like
     `&ps[0].x`, is copied into a temporary, which is passed instead and
     written back to the place once the call returns
   - a method call, `s.size()`, is a call of the type's function with the
     receiver first, `Stack.size(s)`; with `&`, `&s.push(1)`, the receiver
     is passed `inout`, `Stack.push(&s, 1)`, like any argument with `&`
   - `for x in xs` and `for p in &ps` become `while` loops over an index;
     the second writes each element back after each pass. `for i in a..b`
     counts in a `while` loop of its own
   - `let (a, b) = t`, and a loop's tuple, `for (k, v) in ...`, are a
     `match` of one arm
   - an `if` without `else` gets `else ()`
   - a block becomes nested [Let]s and [Seq]s
   - a lambda lists the variables it captures
   - `fail X(a)` is a [Fail] of the error [Tag]; `attempt e`, and a
     `match` with `fail` arms, are [Handle]s; `try r` of a `Result` and
     `x orelse e` are `match`es. A `try` of anything else is its operand:
     a call that can fail passes its error on by itself
   - a place passed with `&` to a call that can fail is written back in a
     [Finally], so it's written back even if the call fails

   Everything is evaluated in the order it was before: the order the
   interpreter has always used, so a program prints the same things.

   And the evidence (core.ml) is threaded: each function takes its own,
   each call passes the one in scope, and a call of an operation,
   `Clock.now()`, is a [Dep_call] on it. A block captures the evidence
   where it's written, as it does a local, and takes from its caller's
   only what its parameter's type lists (foundations.md, decision 5). A
   named function or an operation used as a value, `each(xs, show)`, is a
   block written there that calls it.

   So are types' descriptors (core.ml, [desc]): each function takes one
   for each of its type variables, and each use of a generic function, and
   each `assert a == b`, gets the descriptors of its types, built from
   them. And requirements' dictionaries (core.ml, [dict]): each function
   takes one for each of its requirements, and each use of a function
   that has some, and each `==`, gets the dictionaries it needs, built
   from them. Which types show their values through a `show` method of
   their own is decided here too, once. *)

open Ast
open Ast.Resolved
module C = Core

(* Sets of binder ids. [Set.Make] is a functor: it makes a module of sets
   whose elements are compared with [Int.compare], so looking one up takes
   a few steps, not a walk of every element. *)
module Ids = Set.Make (Int)

(* The type checker and mut.ml rule these out, so reaching one is a
   compiler bug. *)
let bug what = failwith ("bug: lowering found " ^ what)

(* A function made for what it's given, which lowering asks for where
   it's used, and the driver makes in the module that declares it, once
   each (compiler.md, "`over any` and `retry`"): a handler `over any`,
   for the dependency at the second path, which a `with` installs it
   over; or a function with parameters of `Tags`, for the tags each is
   given, sorted, in order. Neither is lowered as it's written: what it
   does depends on what it's made for. *)
type request = Any_for of Path.t * Path.t | Tags_for of Path.t * string list list

(* [p] with [s] after its name, or its member's. *)
let suffixed (p : Path.t) s =
  match p.member with
  | None -> { p with name = p.name ^ s }
  | Some m -> { p with member = Some { m with mname = m.mname ^ s } }

(* The function a request is made as: `recorder$Clock`, `retry$DbDown`. *)
let made_path = function
  | Any_for (h, d) -> suffixed h ("$" ^ Path.full d)
  | Tags_for (f, sets) ->
      suffixed f ("$" ^ String.concat ";" (List.map (String.concat "|") sets))

(* What a type of a function being made for a request becomes: each type
   variable [var] gives, each row variable's row [tail] gives, and with
   [dep], an implementation of the dependency `any` stands for, which
   that one is then (compiler.md, "`over any` and `retry`"). *)
type subst = {
  var : int -> Ty.ty;
  tail : int -> Ty.row;
  dep : Ty.dep option;
}

let same_subst =
  { var = (fun n -> Var n); tail = (fun n -> { labels = []; tail = Some n }); dep = None }

let rec subst_ty s (t : Ty.ty) : Ty.ty =
  match t with
  | Var n -> s.var n
  | Error -> Error
  | Con (p, args) -> Ty.known (Con (p, List.map (subst_ty s) args))
  | Variant (p, c, args) -> Variant (p, c, List.map (subst_ty s) args)
  | Errors r -> Errors (subst_row s r)
  | Impl i -> (
      let needs = subst_row s i.needs and fails = subst_row s i.fails in
      match s.dep with
      | Some d when List.exists Ty.is_any i.deps ->
          (* it needs what it goes over, where it's installed *)
          let l = Ty.dep_of d in
          let needs =
            if List.exists (Ty.same_label l) needs.labels then needs
            else { needs with labels = Ty.sort_labels (l :: needs.labels) }
          in
          Impl { i with deps = [ d ]; needs; fails }
      | _ ->
          let deps =
            List.map
              (fun (d : Ty.dep) -> { d with dargs = List.map (subst_ty s) d.dargs })
              i.deps
          in
          Ty.known (Impl { i with deps; needs; fails }))
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst_ty s p.ty }) ps,
          subst_ty s r,
          subst_row s e,
          subst_row s u )

(* As [Ty.apply_row]: a row variable's labels are added to the row's. *)
and subst_row s (r : Ty.row) : Ty.row =
  let labels =
    List.map
      (fun (l : Ty.label) -> { l with payload = List.map (subst_ty s) l.payload })
      r.labels
  in
  match r.tail with
  | None -> { labels; tail = None }
  | Some n ->
      let more = s.tail n in
      let has (l : Ty.label) = List.exists (Ty.same_label l) labels in
      {
        labels =
          Ty.sort_labels (labels @ List.filter (fun l -> not (has l)) more.labels);
        tail = more.tail;
      }

(* In a copy of the arm of a handler `over any`, made for one operation:
   the dependency, the operation, its parameters' types, result and
   errors, and the locals its arguments are in. *)
type call = {
  cdep : Ty.dep;
  cop : string;
  cps : Ty.param list;
  cret : Ty.ty;
  cerrs : Ty.row;
  cargs : C.var list;
}

(* What lowering one top-level function needs. *)
type cx = {
  nodes : Infer.node Infer.Nodes.t;  (** what inference found, by node id *)
  mutable subst : subst;
      (** what its types become, in a function made for a request *)
  mutable shift : int;
  mutable shifted : Ids.t;
      (** in a copy of an arm `over any` for one operation, the binders in
          the arm, whose locals' ids are theirs plus [shift], so each copy's
          are its own *)
  mutable call : call option;  (** in such a copy, its call *)
  mutable case : (int * string) option;
      (** in a copy of a `call` clause made for one operation, the binder of
          its call and the operation's case of `D.Call`: an arm of a `match`
          on the call for another case is never taken there, and inference
          refined each to its own case's (compiler.md, "Services stage",
          "`D.Call`") *)
  mutable cells : (C.var * C.var) list;
      (** in a handler's arm, its state's `var`s and their cells
          ([with_cells]), which `Async.until` writes back and reads again
          ([until_released]) *)
  tags : (int * string list) list;
      (** in a function made for the tags it's given, each parameter of
          `Tags`, by its binder's id, with them *)
  mutable suffix : string;
      (** what's added to each block's name in a function made for a request,
          so that each copy's blocks have names of their own *)
  requests : request list ref;  (** what it uses that's made for a request *)
  calls : C.method_call list ref;
      (** each method call on a description it has (Core.program) *)
  types : Path.t -> Iface.type_decl option;
      (** every type of the program, by path, which a dependency's operations
          are found in *)
  opaque : Path.t list;
      (** the opaque types the module sees, but the prelude's (Infer.t) *)
  through : (int * Loc.t, Path.t) Hashtbl.t;
      (** the member functions of dependencies called through an alias, by
          node, with the alias (Resolve.through) *)
  vars : (int, C.var) Hashtbl.t;  (** each local, by binder id *)
  mutable next : int;  (** the id of the next temporary *)
  mutable ev : C.var;
      (** the evidence in scope: the function's, or the lambda's whose body is
          being lowered *)
  mutable handler_ev : C.var option;
      (** in a handler, its evidence, where it was installed, which `next` finds
          the implementation it's over in *)
  self : Path.t;  (** the function being lowered, as it's written *)
  mutable handler_deps : Ty.dep list;
      (** in a handler, the dependencies it implements, at its types, which
          `next` finds the one under it of *)
  mutable tys : C.var list;
      (** the function's hidden type parameters (core.ml), and in a handler's
          `finally`, the one it's given for the type of the `with`'s body *)
  dicts : ((int * string) * C.var) list;
      (** its hidden dictionary parameters, by the requirement each is for *)
}

let node cx id =
  match Infer.Nodes.find_opt id cx.nodes with
  | Some n when cx.subst == same_subst -> n
  | Some n ->
      {
        n with
        ty = subst_ty cx.subst n.ty;
        targs =
          Option.map
            (fun (a : Ty.args) : Ty.args ->
              {
                tys = List.map (subst_ty cx.subst) a.tys;
                rows = List.map (subst_row cx.subst) a.rows;
              })
            n.targs;
      }
  | None -> bug (Printf.sprintf "no type for node %d" id)

let ty_of cx id = (node cx id).ty

(* The type arguments inference found a use of a top-level function, a
   member, an associated value or an intrinsic picked (Infer.node). *)
let targs_of cx id =
  match (node cx id).targs with
  | Some a -> a
  | None -> bug (Printf.sprintf "no type arguments for node %d" id)

(* Whether a value of type [t] can't hold a `Float`: a scalar of the
   prelude's but `Float`, or one of its collections, tuples, options and
   results of those. A type of the program's, or a type variable, may. *)
let rec floatless (t : Ty.ty) =
  match t with
  | Con (p, args) ->
      let prelude n = p = Path.prelude n in
      (List.exists prelude [ "Int"; "Bool"; "Str"; "Unit"; "Bytes" ]
      || (match Sized.of_path p with Some k -> not (Sized.is_float k) | None -> false)
      || Ty.is_tuple p
      || List.exists prelude [ "Array"; "Option"; "Result"; "Map"; "Set" ])
      && List.for_all floatless args
  | _ -> false

(* [args], given to the operation [op] of [dep]: each that could hold a
   NaN checked first (nan.ml, [Nan_check]), so none reaches a handler,
   the world or the journal. A block isn't checked: it holds no value, and
   what it gives is checked where that goes; nor is an implementation. *)
let nan_checked (dep : Path.t) op (args : C.expr list) =
  List.map
    (fun (a : C.expr) ->
      match a.ty with
      | Fun _ | Impl _ | Errors _ -> a
      | _ when floatless a.ty -> a
      | _ ->
          C.mk (Prim (Nan_check (dep.name ^ "." ^ op), [ a ])) a.ty a.loc)
    args

(* The name inference gave the block at node [id] (Ty.lambda_id), and
   the dependencies its callee gives it (Infer.Block). *)
let block_of cx id =
  match (node cx id).found with
  | Some (Block { name; given }) -> (name ^ cx.suffix, given)
  | _ -> bug (Printf.sprintf "no name for the block at node %d" id)

(* The type of a block that does what a function of type [t] does, given
   [given] by its callee, which is all it uses of its caller's evidence. *)
let block_ty (t : Ty.ty) given : Ty.ty =
  match t with
  | Fun (ps, ret, errs, _) ->
      Fun (ps, ret, errs, { labels = Ty.sort_labels given; tail = None })
  | _ -> bug "a block whose type isn't a function's"

(* The descriptors a use at the type arguments [a] is passed (core.ml,
   [desc]), built from the function's own hidden type parameters. *)
let descs cx (a : Ty.args) = List.map (C.describe cx.tys) a.tys

(* The type arguments of the dependency [dep] that the operation of type
   [fty] uses, as descriptors: its type lists the instance, `Log<Int>`, in
   its row of dependencies (Infer_lookup, [Dep_op]). *)
let dep_args cx ~node (dep : Path.t) (fty : Ty.ty) =
  match Infer.Nodes.find_opt node cx.nodes with
  | Some { targs = Some a; _ } when a.tys <> [] ->
      List.map (C.describe cx.tys) a.tys
  | _ -> (
      match fty with
      | Fun (_, _, _, u) -> (
          match
            List.find_opt
              (fun (l : Ty.label) -> l.name = Ty.dep_label dep)
              u.labels
          with
          | Some l -> List.map (C.describe cx.tys) l.payload
          | None -> [])
      | _ -> [])

(* The key of a dependency's label, a block's [given], as descriptors. *)
let key_of_label cx (l : Ty.label) = C.key_of cx.tys (Ty.of_label l)

(* The descriptors of an error's payload's types, which the error carries
   (core.ml, [Tag]). *)
let payload_descs cx (args : C.expr list) =
  List.map (fun (a : C.expr) -> C.describe cx.tys a.ty) args

(* [req]'s dictionary for [t] (core.ml, [dict]), built from the function's
   own dictionary parameters. Inference passed on to the function each
   requirement a type variable of it in [t] has to meet, so it has one
   for each. *)
let dict cx req t =
  try C.dict_for cx.tys cx.dicts req t
  with Not_found -> bug "a requirement inference didn't pass on"

(* The dictionaries the use at node [id] is passed: one for each of the
   requirements of the function it uses, for the type argument it's on. *)
let dicts_of cx id =
  let a = targs_of cx id in
  List.map (fun (n, req) -> dict cx req (List.nth a.tys n)) (node cx id).needs

(* Whether [a] is an argument given by name, `on: DbDown`. *)
let is_named (a : expr) = match a.kind with Named _ -> true | _ -> false

(* Whether [t] is the prelude's `Tags`. *)
let is_tags (t : Ty.ty) = t = Con (Path.prelude "Tags", [])

(* Whether inference found [id] to be a `match` with `fail` arms, or a
   `fail` arm's pattern (Infer.found). *)
let handles cx id = (node cx id).found = Some Handles
let is_fail cx id = (node cx id).found = Some Fail_arm

(* A local's id: its binder's, or in a copy of an arm `over any`, that
   plus the copy's shift (see [cx]). *)
let local_id cx (b : binder) =
  if Ids.mem b.id cx.shifted then b.id + cx.shift else b.id

(* A local, when it's bound: it takes the binder's id and name. *)
let bind cx (b : binder) ty =
  let v : C.var = { id = local_id cx b; name = b.ident.name; ty } in
  Hashtbl.replace cx.vars v.id v;
  v

let var_of cx (b : binder) =
  match Hashtbl.find_opt cx.vars (local_id cx b) with
  | Some v -> v
  | None -> bug ("`" ^ b.ident.name ^ "` used outside its scope")

(* A temporary the compiler makes. Its name starts with `$`, which no
   variable in Ren source can, so it's easy to tell apart when printed. *)
let temp cx name ty : C.var =
  let v : C.var = { id = cx.next; name = "$" ^ name; ty } in
  cx.next <- cx.next + 1;
  v

(* A function's or lambda's evidence. *)
let evidence cx : C.var =
  let v = C.evidence cx.next in
  cx.next <- cx.next + 1;
  v

let mk = C.mk
let local = C.local
let int_lit n loc = mk (Int n) Ty.int loc

(* The temporaries holding the subjects of the chains being lowered,
   innermost first: a step's [Piped] is the innermost's (see [Pipe] in
   [expr_of]). *)
let piped : C.var list ref = ref []

(* [let v = value in body], for each binding in turn. *)
let lets binds (body : C.expr) =
  List.fold_right
    (fun ((v : C.var), (value : C.expr)) body ->
      mk (Let (v, value, body)) body.ty value.loc)
    binds body

let seq (a : C.expr) (b : C.expr) = mk (Seq (a, b)) b.ty a.loc

(* Each of [es], which are [Unit]s, in turn. *)
let seq_all loc (es : C.expr list) =
  match List.rev es with
  | [] -> C.unit loc
  | last :: before -> List.fold_left (fun rest e -> seq e rest) last before

(* A value that's always the same: using it later, instead of evaluating
   it into a temporary first, changes nothing. A local is the same until
   something assigns to it, so it counts only with [~local], where nothing
   but reading runs before it's used. *)
let is_atom ~local (e : C.expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Unit | Global _ | Global_value _ | Intrinsic _ ->
      true
  | Local _ -> local
  | _ -> false

(* [e], or a temporary holding it: the binding to make, and what to use. *)
let hold ?(local = false) cx name (e : C.expr) =
  if is_atom ~local e then ([], e)
  else
    let v = temp cx name e.ty in
    ([ (v, e) ], C.local v e.loc)

(* ---- places ----

   A place is a local variable, then a path of fields and indices into its
   value. Each index is held in a temporary, so it's evaluated once. *)

type step =
  | SField of Path.t * string * Ty.ty * Loc.t
      (** a field of a record of type [Path.t]; the field's type *)
  | SIndex of C.expr * Ty.ty * Loc.t
      (** an index (an atom); the element type *)
  | SRange of C.expr * C.expr * Ty.ty * Loc.t
      (** a range of indices, `xs[a..b]` (atoms); the type of what's sliced,
          which a slice is too (foundations.md, decision 17) *)

type place = { root : C.var; steps : step list }

(* A call's argument, lowered: a value, or a place passed with `&`, with
   the temporaries holding its indices, or a pull argument's block, with
   what's made first for it to pull, a snapshot or a cursor (Lower's
   [pull_block]). *)
type arg =
  | Read of C.expr
  | Inout of {
      binds : (C.var * C.expr) list;
      place : place;
      ty : Ty.ty;
      loc : Loc.t;
    }
  | Pull of (C.var * C.expr) list * C.expr

(* The value at the end of the steps, starting from [base]. *)
let rec read_from (base : C.expr) steps =
  match steps with
  | [] -> base
  | SField (p, f, ty, loc) :: rest ->
      read_from (mk (Field (base, p, f)) ty loc) rest
  | SIndex (i, ty, loc) :: rest ->
      read_from (mk (Prim (Get_index Checked, [ base; i ])) ty loc) rest
  | SRange (a, b, ty, loc) :: rest ->
      read_from (mk (Prim (Slice Range, [ base; a; b ])) ty loc) rest

let read pl loc = read_from (local pl.root loc) pl.steps

(* [base] with the value at the end of the steps replaced by [v]: a new
   value, built by updating each step on the way back up. *)
let rec update (base : C.expr) steps (v : C.expr) =
  match steps with
  | [] -> v
  | SField (p, f, ty, loc) :: rest ->
      let inner = update (mk (Field (base, p, f)) ty loc) rest v in
      mk (Update (base, f, inner)) base.ty loc
  | SIndex (i, ty, loc) :: rest ->
      let inner = update (mk (Prim (Get_index Checked, [ base; i ])) ty loc) rest v in
      mk (Prim (Set_index Checked, [ base; i; inner ])) base.ty loc
  | SRange (a, b, ty, loc) :: rest ->
      (* what the range holds is replaced, whatever its length now *)
      let inner = update (mk (Prim (Slice Range, [ base; a; b ])) ty loc) rest v in
      mk (Prim (Splice, [ base; a; b; inner ])) base.ty loc

(* Write [v] to the place. *)
let write pl (v : C.expr) loc =
  mk (Assign (pl.root, update (local pl.root loc) pl.steps v)) Ty.unit loc

(* A place with a range in it, `xs[a..b].f`, split after its last range:
   the place of the range, and the steps after it. A loop that changes
   what's in a range changes a copy of it, written back once. *)
let split_range pl =
  let rec last_range i = function
    | [] -> None
    | SRange _ :: rest -> (
        match last_range (i + 1) rest with None -> Some i | j -> j)
    | _ :: rest -> last_range (i + 1) rest
  in
  match last_range 0 pl.steps with
  | None -> None
  | Some i ->
      let before = List.filteri (fun j _ -> j <= i) pl.steps
      and after = List.filteri (fun j _ -> j > i) pl.steps in
      Some ({ pl with steps = before }, after)

(* ---- expressions ---- *)

let result_path = Path.prelude "Result"
let option_path = Path.prelude "Option"

(* Whether [t] is an [Int] or a [Float], whose operators and order are
   the language's own. *)
let is_number (t : Ty.ty) = t = Ty.int || t = Ty.float
let pat pkind pty ploc : C.pattern = { pkind; pty; ploc }

(* The arm `c(v) => body(v)` of a `match` on a value of type [ty]: [c] is
   a constructor of the type at [path] with one field, of type [t], which
   is bound to a temporary named [name]. *)
let field_arm cx loc path ty c (name, t) body : C.arm =
  let v = temp cx name t in
  {
    pat = pat (PCon (path, c, [ pat (PVar v) t loc ])) ty loc;
    guard = None;
    body = body (local v loc);
  }

(* The type arguments of [Result<T, ! ...>]. *)
let result_args (t : Ty.ty) =
  match t with
  | Con (_, [ v; errs ]) -> (v, errs)
  | _ -> bug "a `Result` without its two type arguments"

(* A value of a sized type, read as its wide type; anything else as it
   is (sized.ml). *)
let widen (x : C.expr) =
  match Sized.of_ty x.ty with
  | Some k -> mk (Prim (Widen, [ x ])) (Sized.wide k) x.loc
  | None -> x

(* A value of [k]'s wide type stored as a [k]: checked, or wrapped if a
   wrapping operator made it. *)
let store_as k ~wrap (x : C.expr) =
  mk (Prim ((if wrap then Wrap else Narrow), [ x ])) (Sized.ty k) x.loc

(* [e], lowered: narrowed to some of its dependencies, if it's an
   implementation of several where a written type asks for those
   (Infer.node, [narrowed]); and read from a sized type, or stored into
   one, as inference decided (Infer.node, [coerce]). *)
let rec expr cx (e : expr) : C.expr =
  let x = expr_of cx e in
  let x =
    match ((node cx e.node).narrowed, Ty.impl_parts x.ty) with
    | Some ds, Some (all, needs) ->
        let kept = List.filter (fun (d : Ty.dep) -> List.mem d.dpath ds) all in
        mk (Narrowed (ds, x)) (Ty.impl kept needs) e.loc
    | Some _, None -> bug "a narrowed implementation isn't one"
    | None, _ -> x
  in
  match (node cx e.node).coerce with
  | None -> x
  | Some { read; store } ->
      let x = if read <> None then widen x else x in
      Option.fold ~none:x ~some:(fun (k, wrap) -> store_as k ~wrap x) store

and expr_of cx (e : expr) : C.expr =
  let ty () = ty_of cx e.node in
  let here kind = mk kind (ty ()) e.loc in
  match e.kind with
  | Int n -> here (Int n)
  | Float f -> here (Float f)
  | Bool b -> here (Bool b)
  | Str s -> here (Str s)
  | Interp ps -> (
      (* each hole through its type's `show`, a `Str` being itself, and the
         pieces joined by `+`, left to right, so the first is copied and
         the rest appended (compiler.md, "Bytes stage, part two", "The
         API") *)
      let parts =
        List.filter_map
          (function
            | Ast.Lit "" -> None
            | Lit t -> Some (mk (Str t) Ty.str e.loc)
            | Hole h ->
                let x = expr cx h in
                Some (if x.ty = Ty.str then x else shown cx x h.loc))
          ps
      in
      match parts with
      | [] -> here (Str "")
      | first :: rest ->
          List.fold_left (fun a b -> str_add cx a b e.loc) first rest)
  | Unit -> here Unit
  | Var (Local b) -> local (var_of cx b) e.loc
  | Var (Global p) when (node cx e.node).found = None ->
      (* called: a call takes it as it is *)
      let a = targs_of cx e.node in
      here (Global (p, a, descs cx a, dicts_of cx e.node))
  | Var (Global_value p) -> here (Global_value (p, targs_of cx e.node))
  | Var (Intrinsic x) when (node cx e.node).found = None ->
      let a = targs_of cx e.node in
      here (Intrinsic (x, a, descs cx a, dicts_of cx e.node))
  | Var (Global _ | Intrinsic _ | Dep_op _) ->
      (* used as a value: a block written here that calls it, so what it
         uses is found here, but what its callee gives it (foundations.md,
         decision 5) *)
      named_block cx e
  | Var (Next_op _) -> bug "`next` used other than by calling through it"
  (* in a copy of an arm `over any`, made for one operation: its name, as
     the journal writes it, and its arguments, a tuple of them *)
  | Var (Call_op "name") ->
      let c = the_call cx in
      here (Str (c.cdep.dpath.name ^ "." ^ c.cop))
  | Var (Call_op "args") -> (
      let c = the_call cx in
      match c.cargs with
      | [] -> here Unit
      | vs -> here (Tuple (List.map (fun v -> local v e.loc) vs)))
  | Var (Call_op _) -> bug "`call` used other than through"
  | Named _ | Tag_set _ -> bug "tags lowered other than as a call's"
  | Var (Assoc_value (_, req)) -> value_of cx req (ty ()) e.loc
  | Unop (Neg, a, onode) ->
      operator cx ~onode ~meth:"neg" C.Neg (ty ()) e.loc [ expr cx a ]
  | Unop (Not, a, _) -> here (Prim (Not, [ expr cx a ]))
  (* `a && b` is `if a then b else false`, and `a || b` is
     `if a then true else b`: [b] runs only when [a] doesn't decide *)
  | Binop (And, a, b, _) ->
      let a = expr cx a in
      here (If (a, expr cx b, mk (Bool false) Ty.bool e.loc))
  | Binop (Or, a, b, _) ->
      let a = expr cx a in
      here (If (a, mk (Bool true) Ty.bool e.loc, expr cx b))
  | Binop (Orelse, a, b, _) ->
      (* `x orelse e` is `match x { Some(v) => v, None => e }` *)
      let a = expr cx a in
      let some =
        field_arm cx e.loc option_path a.ty "Some"
          ("value", C.elem_ty a.ty)
          Fun.id (* the function that returns its argument: the arm is `v` *)
      in
      let none : C.arm =
        {
          pat = pat (PCon (option_path, "None", [])) a.ty e.loc;
          guard = None;
          body = expr cx b;
        }
      in
      here (Match (a, [ some; none ]))
  | Fail (tag, args) ->
      (* a payload's names only document it, so it's in the order written *)
      let args = List.map (fun (_, a) -> expr cx a) args in
      let set : Ty.row =
        {
          labels =
            [
              {
                name = tag.name;
                payload = List.map (fun (a : C.expr) -> a.ty) args;
              };
            ];
          tail = None;
        }
      in
      here
        (Fail
           (mk (Tag (tag.name, args, payload_descs cx args)) (Errors set) e.loc))
  | Try ({ kind = Match (subject, arms); _ } as m) when handles cx m.node ->
      handle_match cx ~passed:true (ty_of cx m.node) e.loc subject arms
  | Try a when (node cx e.node).found = Some Unwrap ->
      (* `try r` is `match r { Ok(v) => v, Err(e) => fail e }`. A call in
         [r] that fails passes its error on, as every call does *)
      let r = expr cx a in
      let v, errs = result_args r.ty in
      let arm = field_arm cx e.loc result_path r.ty in
      let ok = arm "Ok" ("value", v) Fun.id in
      let err = arm "Err" ("error", errs) (fun err -> here (Fail err)) in
      here (Match (r, [ ok; err ]))
  | Try a ->
      (* a call passes on what it fails with by itself: the `try` only says
         so, for whoever reads it *)
      expr cx a
  | Assert ({ kind = Binop (Eq, a, b, _); _ } as cmp) ->
      (* both sides, so a failure can show them, and where the comparison
         is, which it points at *)
      let a = expr cx a in
      let b = expr cx b in
      mk
        (Assert_equal (a, b, C.describe cx.tys a.ty, dict cx "eq" a.ty))
        Ty.unit cmp.loc
  | Assert a -> here (Assert (expr cx a))
  | Release a -> released cx (expr cx a)
  | Pipe { subject; step } ->
      (* `x |> f(a)` is `let s = x in f(s, a)`: the subject is evaluated
         first, then the step's call, which [Piped] gives [s] (language.md
         §8) *)
      let s = temp cx "piped" (ty_of cx subject.node) in
      let value = expr cx subject in
      piped := s :: !piped;
      let call =
        Fun.protect ~finally:(fun () -> piped := List.tl !piped) (fun () ->
            expr cx step)
      in
      mk (Let (s, value, call)) call.ty e.loc
  | Piped -> (
      match !piped with
      | s :: _ -> local s e.loc
      | [] -> bug "a step's subject outside its chain")
  | Attempt a ->
      (* `Ok` of its value, or `Err` of its error *)
      let t = ty () in
      let v, errs = result_args t in
      let body = expr cx a in
      let value = temp cx "value" v and error = temp cx "error" errs in
      here
        (Handle
           {
             body;
             value;
             on_value =
               mk (Con (result_path, "Ok", [ local value e.loc ])) t e.loc;
             error;
             on_error =
               mk (Con (result_path, "Err", [ local error e.loc ])) t e.loc;
           })
  | Binop (((Eq | Neq) as op), a, b, _) ->
      (* through the `eq` dictionary of what it compares *)
      let a = expr cx a in
      let d = dict cx "eq" a.ty in
      let op : C.prim = if op = Eq then Equal d else Not_equal d in
      here (Prim (op, [ a; expr cx b ]))
  | Binop (((Lt | Le | Gt | Ge) as op), a, b, _) ->
      (* a number's own, or else through the `ord` dictionary of what it
         compares *)
      let a = expr cx a in
      let op : C.prim =
        if is_number a.ty then Binop op else Compare (op, dict cx "ord" a.ty)
      in
      here (Prim (op, [ a; expr cx b ]))
  | Binop (op, a, b, onode) -> (
      (* a wrapping operator is `Int`'s method, `wrapping_add` *)
      match (binop_method op, wrapping_method op) with
      | Some meth, _ | None, Some meth ->
          let a = expr cx a in
          operator cx ~onode ~meth (C.Binop op) (ty ()) e.loc [ a; expr cx b ]
      | None, None -> bug ("`" ^ binop_to_string op ^ "` as an operator"))
  | If (c, t, f) ->
      let c = expr cx c in
      let t = expr cx t in
      let f = match f with Some f -> expr cx f | None -> C.unit e.loc in
      here (If (c, t, f))
  | Call (f, args) -> until_released cx (call cx e f args)
  | Lambda (params, body) ->
      let ps =
        match ty () with
        | Fun (ps, _, _, _) -> ps
        | _ -> bug "a lambda whose type isn't a function"
      in
      let params =
        List.map2
          (fun (p : Resolved.param) (t : Ty.param) : C.param ->
            { mode = p.pmode; var = bind cx p.pname t.ty })
          params ps
      in
      let name, given = block_of cx e.node in
      block_value cx ~name ~given params (ty ()) e.loc (fun () -> expr cx body)
  | Block (stmts, last) -> block cx stmts last
  | Con (tag, args) -> (
      match (node cx e.node).found with
      | Some Error_tag ->
          (* a tag, inside `Err(...)`: the error it holds *)
          let args = List.map (fun (_, a) -> expr cx a) args in
          here (Tag (tag.name.name, args, payload_descs cx args))
      | Some (Ctor_of (p, c)) -> (
          (* ctor_shape (infer_lookup.ml) made sure the arguments are in the
             order of the fields; a field left out has a default, which
             inference checked at a node of its own (Infer_expr.infer_con) *)
          match (args, ctor_decl cx p c) with
          | [], [ { Iface.fdefault = Some lit; _ } ] ->
              let d : expr =
                {
                  kind = Infer_env.literal_kind lit e.loc;
                  loc = e.loc;
                  node = Infer_env.default_node e.node 0;
                }
              in
              here (Con (p, c, [ expr cx d ]))
          | _ -> here (Con (p, c, List.map (fun (_, a) -> expr cx a) args)))
      | _ -> bug "a constructor inference didn't find")
  | Record (_, fields) -> (
      match ty () with
      | Con (p, _) ->
          here
            (Record
               (p, List.map (fun ((f : ident), v) -> (f.name, expr cx v)) fields))
      | _ -> bug "a record literal whose type isn't a record")
  | Con_named (_, fields) -> (
      match (node cx e.node).found with
      | Some (Ctor_of (p, c)) ->
          (* each value, in the order written, then the constructor's
             fields in the order declared: written in that order, they're
             the constructor's arguments as they are *)
          let decl = ctor_decl cx p c in
          let names = List.map (fun ((f : ident), _) -> f.name) fields in
          if names = List.map (fun (d : Iface.field) -> d.fname) decl then
            here (Con (p, c, List.map (fun (_, v) -> expr cx v) fields))
          else
            let given =
              List.map
                (fun ((f : ident), v) ->
                  let v = expr cx v in
                  (f.name, temp cx f.name v.ty, v))
                fields
            in
            let arg (d : Iface.field) =
              let _, v, _ = List.find (fun (f, _, _) -> f = d.fname) given in
              local v e.loc
            in
            lets
              (List.map (fun (_, v, value) -> (v, value)) given)
              (here (Con (p, c, List.map arg decl)))
      | _ -> bug "a by-name constructor inference didn't find")
  | Update { base; fields; _ } -> update cx e base fields
  | Field (r, f) -> (
      match (node cx e.node).found with
      | Some (Field_of p) -> here (Field (expr cx r, p, f.name))
      | _ -> bug "a field inference didn't find")
  | Match (subject, arms) when handles cx e.node ->
      handle_match cx ~passed:false (ty ()) e.loc subject arms
  | Match (subject, arms) ->
      (* in a copy of a `call` clause, a `match` on its call takes only
         its own case's arms, and those that take any *)
      let arms =
        match (cx.case, subject.kind) with
        | Some (b, case), Var (Local v) when v.id = b ->
            List.filter
              (fun (a : arm) ->
                match a.arm_pat.pkind with
                | PCon ({ name; _ }, _) | PCon_named ({ name; _ }, _) ->
                    name.name = case
                | _ -> true)
              arms
        | _ -> arms
      in
      let subject = expr cx subject in
      here (Match (subject, List.map (arm cx) arms))
  | Array xs -> here (Array (List.map (expr cx) xs))
  | Tuple xs -> here (Tuple (List.map (expr cx) xs))
  | Index (a, i) ->
      let a = expr cx a in
      here (Prim (Get_index Checked, [ a; expr cx i ]))
  | Slice (a, lo, hi) ->
      let a = expr cx a in
      let lo = expr cx lo in
      here (Prim (Slice Range, [ a; lo; expr cx hi ]))
  | Ref ({ kind = Call (f, args); _ } as c) -> call cx ~changed:true c f args
  | Ref _ -> bug "`&` outside a call or a `for` loop"
  | Assign { target; op; value; onode } -> assign cx e ~onode target op value
  | For { index; pat; over = Each iter; body } ->
      for_loop cx e index pat iter body
  | For { pat; over = Range (lo, hi); body; _ } -> range_loop cx e pat lo hi body
  | While { cond; body } ->
      let cond = expr cx cond in
      here (While (cond, expr cx body))
  | Break -> here Break
  | Todo -> todo cx e.loc (ty ())
  | With { items; body } -> with_ cx e items body
  | Handler { deps; state; arms; _ } ->
      (* it runs where it's installed, with the evidence there *)
      let ev = evidence cx and outer = cx.ev and around = cx.handler_ev in
      let around_deps = cx.handler_deps in
      cx.ev <- ev;
      cx.handler_ev <- Some ev;
      cx.handler_deps <-
        (match Ty.impl_parts (ty_of cx e.node) with
        | Some (ds, _) -> ds
        | None -> []);
      let body = handler cx e deps state arms in
      cx.ev <- outer;
      cx.handler_ev <- around;
      cx.handler_deps <- around_deps;
      (* its own evidence, which `next` uses, is bound, not captured *)
      let captures =
        List.filter (fun (v : C.var) -> v.id <> ev.id) (free body)
      in
      here (Handler { ev; captures; body })
  | Inline_handler lam ->
      (* `handler fn(req) => ...`: a handler with no state and one arm,
         [lam], of the only operation of its dependency (foundations.md,
         decision 3). What it captures it copies, as a block does: nothing
         changes a local it captures (mut.ml), so a copy is the same. *)
      let dep, op =
        match (node cx e.node).found with
        | Some (Inline_op { dep; op }) -> (dep, op)
        | _ -> bug "an inline handler without its operation"
      in
      let own, needs =
        match Ty.impl_parts (ty ()) with
        | Some ([ d ], needs) -> (d, needs)
        | _ -> bug "an inline handler whose type isn't a handler of one"
      in
      let ev = evidence cx and outer = cx.ev and around = cx.handler_ev in
      let around_deps = cx.handler_deps in
      cx.ev <- ev;
      cx.handler_ev <- Some ev;
      cx.handler_deps <- [ own ];
      let arm = expr cx lam in
      cx.ev <- outer;
      cx.handler_ev <- around;
      cx.handler_deps <- around_deps;
      let impl = mk (Record (dep, [ (op, arm) ])) (Ty.impl [ own ] needs) e.loc in
      let body =
        let kind = C.Instance { impls = [ (dep, impl) ]; finally = None; exclusive = false } in
        mk
          (Instance
             {
               impls = [ (dep, impl) ];
               finally = None;
               (* it has no state, but what it captures *)
               exclusive = opaque_state cx e.loc kind;
             })
          (ty ()) e.loc
      in
      let captures =
        List.filter (fun (v : C.var) -> v.id <> ev.id) (free body)
      in
      here (Handler { ev; captures; body })

(* The call of the copy of an arm `over any` being lowered. *)
and the_call cx =
  match cx.call with
  | Some c -> c
  | None -> bug "`call` outside an arm `over any`"

(* A block of type [ty], named [name], taking [params], whose body [body]
   makes, with the evidence it runs with in scope: the evidence where it's
   written, [cx.ev], which it captures, with what [given] lists from its
   caller's on top (Core.Lambda). *)
and block_value cx ~name ~given params ty loc body =
  let ev = evidence cx and outer = cx.ev in
  cx.ev <- ev;
  let body = body () in
  cx.ev <- outer;
  let given = List.map (key_of_label cx) given in
  (* the descriptors its keys are built from are captured too *)
  let captures =
    captures_of params ev outer body @ List.concat_map C.key_vars given
    |> List.sort_uniq (fun (a : C.var) (b : C.var) -> compare a.id b.id)
  in
  mk (Lambda { name; params; ev; outer; given; captures; body }) ty loc

(* What a block's [body] captures: the locals from outside it it uses, and
   the evidence where it's written, [outer], but not its [params] or its own
   evidence [ev]. *)
and captures_of params (ev : C.var) (outer : C.var) body =
  let own =
    Ids.of_list (ev.id :: List.map (fun (p : C.param) -> p.var.id) params)
  in
  List.filter (fun (v : C.var) -> not (Ids.mem v.id own)) (free body)
  @ [ outer ]
  |> List.sort_uniq (fun (a : C.var) (b : C.var) -> compare a.id b.id)

(* [e], a top-level function, an intrinsic or an operation, used as a
   value: a block written here, `fn(x) => f(x)`, of the type the parameter
   it's passed to has (Infer.Block). *)
and named_block cx (e : expr) =
  let name, given = block_of cx e.node in
  let fty = ty_of cx e.node in
  let ps =
    match fty with
    | Fun (ps, _, _, _) -> ps
    | _ -> bug "a function used as a value whose type isn't a function's"
  in
  let params =
    List.map
      (fun (p : Ty.param) : C.param ->
        { mode = p.mode; var = temp cx "x" p.ty })
      ps
  in
  let ret = match fty with Fun (_, r, _, _) -> r | _ -> Ty.unit in
  block_value cx ~name ~given params (block_ty fty given) e.loc (fun () ->
      let args =
        List.map
          (fun (p : C.param) : C.arg ->
            match p.mode with
            | Inout -> Ref p.var
            | Read -> Value (local p.var e.loc))
          params
      in
      let values = List.map (fun (p : C.param) -> local p.var e.loc) params in
      match e.kind with
      | Var (Global p) ->
          let a = targs_of cx e.node in
          let f =
            mk (Global (p, a, descs cx a, dicts_of cx e.node)) fty e.loc
          in
          mk (Call (f, args, cx.ev)) ret e.loc
      | Var (Intrinsic x) ->
          let a = targs_of cx e.node in
          let f =
            mk (Intrinsic (x, a, descs cx a, dicts_of cx e.node)) fty e.loc
          in
          mk (Call (f, args, cx.ev)) ret e.loc
      | Var (Dep_op (dep, op)) ->
          mk
            (Dep_call
               {
                 dep;
                 dargs = dep_args cx ~node:e.node dep fty;
                 op;
                 fty;
                 ev = cx.ev;
                 next = false;
                 args = nan_checked dep op values;
               })
            ret e.loc
      | _ -> bug "a block made of something that isn't a function")

(* `with a, b over c in body` (handlers.md, "A `with` is a set"). What
   each link of each item installs is made first, outside the `with`, in
   the order written; then the items are installed in the order inference
   worked out, outermost first, each chain's bottom outermost, each a
   [With] or a [With_handler] whose body sees evidence of its own, which
   extends what's installed around it. *)
and with_ cx (e : expr) items body =
  let ty = ty_of cx e.node in
  let order =
    match (node cx e.node).found with
    | Some (Install_order o) -> o
    | _ -> bug "a `with` inference didn't say the order of"
  in
  let kind (lk : with_link) = (node cx lk.knode).found in
  (* each implementation's value, in a temporary, in the order written,
     unless there's only one, which its [With] makes before it installs it *)
  let made =
    List.concat_map
      (fun (it : with_item) ->
        List.filter_map
          (fun (lk : with_link) ->
            match kind lk with
            | Some (Installs { key; _ }) when made_any cx lk ->
                Some (lk.knode, any_link cx lk (Ty.of_label key))
            | Some (Installs _ | Installs_handler _) ->
                Some (lk.knode, expr cx lk.link)
            | _ -> None)
          it.chain)
      items
  in
  let alone = List.length made = 1 in
  let made =
    List.map
      (fun (k, (v : C.expr)) ->
        (k, ((if alone then None else Some (temp cx "impl" v.ty)), v)))
      made
  in
  let desc = C.describe cx.tys ty in
  (* [inside], with the link [lk] installed around it *)
  let install (lk : with_link) inside =
    let impl =
      match List.assoc_opt lk.knode made with
      | Some (None, value) -> value
      | Some (Some v, _) -> local v lk.link.loc
      | None -> bug "a `with`'s implementation not made"
    in
    let ev = evidence cx and outer = cx.ev in
    cx.ev <- ev;
    let body = inside () in
    cx.ev <- outer;
    match kind lk with
    | Some (Installs { key; from }) ->
        let k = key_of_label cx key in
        mk
          (With
             {
               ev;
               outer;
               dep = k.kpath;
               dargs = k.kargs;
               from;
               impl;
               desc;
               body;
             })
          ty e.loc
    | Some (Installs_handler keys) ->
        let deps =
          List.map
            (fun l ->
              let k = key_of_label cx l in
              (k, k.kpath))
            keys
        in
        mk
          (With_handler { ev; outer; handler = impl; deps; desc; body })
          ty e.loc
    | _ -> bug "a link of a `with` that isn't an implementation"
  in
  let rec nest = function
    | [] -> expr cx body
    | idx :: rest ->
        let it : with_item = List.nth items idx in
        let rec chain = function
          | [] -> nest rest
          | lk :: above -> install lk (fun () -> chain above)
        in
        chain (List.rev it.chain)
  in
  lets
    (List.filter_map
       (fun (_, (v, value)) -> Option.map (fun v -> (v, value)) v)
       made)
    (nest order)

(* Whether the link [lk] makes a handler `over any`, which it installs
   over one dependency. *)
and made_any cx (lk : with_link) =
  match Ty.impl_parts (ty_of cx lk.link.node) with
  | Some (ds, _) -> List.exists Ty.is_any ds
  | None -> false

(* The link [lk], `logged() over ...`, which makes a handler `over any`
   to install over [d]: a call of the function made of it for [d]'s
   dependency, which is given the descriptors of [d]'s type arguments
   after its own (compiler.md, "`over any` and `retry`"). Inference made
   sure it's such a call. *)
and any_link cx (lk : with_link) (d : Ty.dep) =
  match lk.link.kind with
  | Call (({ kind = Var (Global h); _ } as f), args) ->
      let req = Any_for (h, d.dpath) in
      cx.requests := req :: !(cx.requests);
      let a = targs_of cx f.node in
      let a = { a with tys = a.tys @ d.dargs } in
      let s = { same_subst with dep = Some d } in
      let fty = subst_ty s (ty_of cx f.node) in
      let callee =
        mk (Global (made_path req, a, descs cx a, dicts_of cx f.node)) fty f.loc
      in
      let args = List.map (fun a -> C.Value (expr cx a)) args in
      let ty = subst_ty s (ty_of cx lk.link.node) in
      mk (Call (callee, args, cx.ev)) ty lk.link.loc
  | _ -> bug "a handler `over any` installed other than where it's made"

(* A handler's body, which makes an instance: its state, each `var` then
   put in a cell, and an implementation of each of [deps], a record of its
   arms. An arm is a lambda that keeps the cells, not the `var`s: it reads
   each `var` it uses from its cell when it starts, and writes back each
   one it changes when it ends, even if it fails. Nothing else changes a
   cell in between: an arm runs with what was installed outside its
   handler's `with`, which isn't the instance it's part of, so it never
   runs inside another arm of the same instance.

   Each `finally` among the state covers what comes after it (handlers.md,
   "`finally`"): the state after it is a [Handle], which gives it what
   that fails to start with, `Err(e)`, and fails with what it fails with,
   as it can only fail, given an error, since it has to give back a value
   of the body's type, which it doesn't know. The `with`'s body it covers
   through the instance's `finally`, which runs them all, the last written
   first, each given what the one after it ends in. As Koka's `finally` is
   a handler around what it covers
   (/tmp/ren-refs/koka/lib/std/core/hnd.kk:485-494), Core needs nothing
   new for it. *)
and handler cx (e : expr) deps state arms =
  let needs =
    match Ty.impl_parts (ty_of cx e.node) with
    | Some (_, needs) -> needs
    | None -> bug "a handler whose type isn't a handler's"
  in
  let forwards, body_ty, any_vars, call_vars =
    match (node cx e.node).found with
    | Some (Handler_facts { forwards; body_ty; any_vars; call_vars }) ->
        (* the variable for the body's type, as what it's made for numbers
           it *)
        let body_ty =
          Option.map
            (fun k -> match cx.subst.var k with Var k -> k | _ -> k)
            body_ty
        in
        (forwards, body_ty, any_vars, call_vars)
    | _ -> ([], None, None, None)
  in
  let finallies =
    List.filter_map (function Finally f -> Some f | _ -> None) state
  in
  let clause =
    List.find_opt (fun (a : handler_arm) -> a.arm_op = Call_op "clause") arms
  in
  (* what the `finally` [f] is given, of type `Result<T, ! ..e>`, the
     body's type and errors (Infer_handlers.finally_), shared by each *)
  let outcome_ty (f : expr) =
    match ty_of cx f.node with
    | Fun ([ r ], _, _, _) -> r.ty
    | _ -> bug "a `finally` whose type isn't a function's"
  in
  let rec state_lets = function
    | [] -> instance ()
    | Let { name; value; _ } :: rest ->
        let value = expr cx value in
        let v = bind cx name value.ty in
        let body = state_lets rest in
        mk (Let (v, value, body)) body.ty value.loc
    | Let_pattern { pat; value; else_ } :: rest ->
        take_apart cx pat ?else_ (expr cx value) (fun () -> state_lets rest)
    | Expr s :: rest -> seq (expr cx s) (state_lets rest)
    | Finally f :: rest ->
        (* the state after it, which, if it fails to start, it's given;
           most can't *)
        let after = state_lets rest in
        if not (C.can_fail after) then after
        else
          let rt = outcome_ty f in
          let made = temp cx "instance" after.ty
          and error = temp cx "error" (snd (result_args rt)) in
          let failed =
            mk (Con (result_path, "Err", [ local error f.loc ])) rt f.loc
          in
          let given = finally_body cx f failed in
          let on_error =
            seq given (mk (Fail (local error f.loc)) after.ty f.loc)
          in
          mk
            (Handle
               {
                 body = after;
                 value = made;
                 on_value = local made f.loc;
                 error;
                 on_error;
               })
            after.ty f.loc
  and instance () =
    let cells =
      List.filter_map
        (function
          | Let { name; mut = true; _ } ->
              let v = var_of cx name in
              Some (v, temp cx v.name (C.cell_ty v.ty))
          | Let _ | Let_pattern _ | Expr _ | Finally _ -> None)
        state
    in
    let impl (d : tname dep_ref) : Path.t * C.expr =
      let p =
        match d.dep.tref with
        | Named p -> p
        | Param _ -> bug "a type parameter after `for`"
      in
      (* its own type arguments, which the one under it is found at *)
      let own =
        match
          List.find_opt (fun (o : Ty.dep) -> o.dpath = p) cx.handler_deps
        with
        | Some o -> o
        | None -> Ty.plain p
      in
      let ops =
        List.filter_map
          (fun (a : handler_arm) ->
            match a.arm_op with
            | Dep_op (q, op) when q = p ->
                Some (op, arm_impl cx cells a.arm_impl)
            | _ -> None)
          arms
      in
      (* what it leaves out, the one under it does: a lambda that calls
         it, with the evidence the operation runs with, where the one
         under it is the innermost *)
      let forwarded =
        List.filter_map
          (fun (q, op, (fty : Ty.ty)) ->
            match fty with
            | Fun (ps, ret, errs, _) when q = p ->
                let name = Path.full (Path.member p op) in
                let fty = Ty.Fun (ps, ret, errs, needs) in
                let params =
                  List.map
                    (fun (q : Ty.param) : C.param ->
                      { mode = Read; var = temp cx "x" q.ty })
                    ps
                in
                Some
                  ( op,
                    block_value cx ~name ~given:[] params fty e.loc (fun () ->
                        let args =
                          List.map
                            (fun (q : C.param) -> local q.var e.loc)
                            params
                        in
                        mk
                          (Dep_call
                             {
                               dep = p;
                               dargs = List.map (C.describe cx.tys) own.dargs;
                               op;
                               fty;
                               ev = cx.ev;
                               next = false;
                               args = nan_checked p op args;
                             })
                          ret e.loc) )
            | _ -> None)
          forwards
      in
      (* what its `call` clause implements *)
      let clauses =
        match (call_vars, clause) with
        | Some vars, Some clause ->
            clause_ops cx e ~cells ~needs ~vars own ~written:(List.map fst ops)
              clause
        | _ -> []
      in
      (p, mk (Record (p, ops @ forwarded @ clauses)) (Ty.impl [ own ] needs) e.loc)
    in
    (* its `finally`s, as one lambda, which is given the descriptor of
       the `with`'s body's type first, the variable after the function's
       own, then the body's outcome: the last one written is given that,
       and each before it what the one after it ends in *)
    let finally =
      match (finallies, body_ty) with
      | [], _ -> None
      | first :: _, Some k when k = List.length cx.tys ->
          let d = temp cx "ty" C.type_ty in
          let own = cx.tys in
          cx.tys <- own @ [ d ];
          let rt = outcome_ty first in
          let outcome = temp cx "outcome" rt in
          let ret, errs, uses =
            match ty_of cx first.node with
            | Fun (_, r, errs, uses) -> (r, errs, uses)
            | _ -> bug "a `finally` whose type isn't a function's"
          in
          let params : C.param list =
            [ { mode = Read; var = d }; { mode = Read; var = outcome } ]
          in
          let name, _ = block_of cx first.node in
          let lam =
            block_value cx ~name ~given:[] params
              (Fun
                 ( [ { mode = Read; ty = C.type_ty }; { mode = Read; ty = rt } ],
                   ret,
                   errs,
                   uses ))
              first.loc
              (fun () ->
                List.fold_left
                  (fun (given : C.expr) f ->
                    finally_body cx f (attempted cx given rt))
                  (finally_body cx
                     (List.hd (List.rev finallies))
                     (local outcome first.loc))
                  (List.tl (List.rev finallies)))
          in
          cx.tys <- own;
          Some (with_cells cx cells lam)
      | _ :: _, _ -> bug "a `finally` without the type of its body"
    in
    let made =
      List.map
        (fun ((v : C.var), (c : C.var)) ->
          (c, mk (Prim (New_cell, [ local v e.loc ])) c.ty e.loc))
        cells
    in
    let impls =
      match (any_vars, call_vars, clause, deps) with
      | Some vars, _, _, _ -> [ any_impl cx e ~cells ~needs ~vars arms ]
      | None, Some vars, Some clause, [ { dep = { tref = Param _; _ }; _ } ] ->
          (* a handler `for D`, made for the dependency it's given: its
             `call` clause is its every operation *)
          let d =
            match cx.handler_deps with
            | [ d ] -> d
            | _ -> bug "a handler `for D` not made for one dependency"
          in
          [
            ( d.dpath,
              mk
                (Record (d.dpath, clause_ops cx e ~cells ~needs ~vars d ~written:[] clause))
                (Ty.impl [ d ] needs) e.loc );
          ]
      | _ -> List.map impl deps
    in
    let exclusive =
      cells <> [] || opaque_state cx e.loc (Instance { impls; finally; exclusive = false })
    in
    lets made
      (mk (Instance { impls; finally; exclusive }) (ty_of cx e.node) e.loc)
  in
  state_lets state

(* Whether what an instance [kind] keeps, the state's `let`s and its
   handler's parameters, the variables it uses from outside, has a value
   of an opaque type of the program's: a resource it keeps, which its
   operations, like a `var`'s, need to keep from each other's tasks
   (compiler.md, "Operations that don't interleave"). The prelude's own,
   the journal a recorder keeps, are the runtime's, whose intrinsics never
   wait with one half changed, and a recorder mustn't make the calls it
   records wait for each other ([cx.opaque] leaves them out). *)
and opaque_state cx loc kind =
  let rec opaque (t : Ty.ty) =
    match t with
    | Con (p, args) | Variant (p, _, args) ->
        List.mem p cx.opaque || List.exists opaque args
    | Fun (ps, r, _, _) -> List.exists (fun (q : Ty.param) -> opaque q.ty) ps || opaque r
    | Var _ | Errors _ | Impl _ | Error -> false
  in
  List.exists
    (fun (v : C.var) -> opaque v.ty)
    (free (mk kind Ty.Error loc))

(* The implementation a handler `over any` [e] makes, in a function made
   for the dependency it's installed over, the one [cx.handler_deps]
   lists: its arm, `call => body`, copied for each operation of that one,
   with the arm's call's arguments' type, result and errors, the
   variables [vars] (Infer.Handler_facts), that operation's. Each copy
   takes the operation's arguments, which `call.args` is a tuple of, and
   `call.forward()` calls the operation under it with (compiler.md,
   "`over any` and `retry`"). *)
and any_impl cx (e : expr) ~cells ~needs ~vars:(ka, kr, ke) arms =
  let d =
    match cx.handler_deps with
    | [ d ] -> d
    | _ -> bug "a handler `over any` not made for one dependency"
  in
  let impl, body =
    match arms with
    | [ ({ arm_impl = { kind = Lambda ([], body); _ }; _ } : handler_arm) ] ->
        ((List.hd arms).arm_impl, body)
    | _ -> bug "a handler `over any` without its one arm"
  in
  let ops =
    match Iface.dep_fields cx.types d with
    | Some ops -> ops
    | None -> bug "a handler `over any` over what isn't a dependency"
  in
  let inside = Ids.of_list (Ast.bound_in impl) in
  let most = Ids.fold max inside 0 in
  let copy (o : Iface.field) =
    match o.fty with
    | Fun (ps, ret, errs, _) ->
        let around = cx.subst and suffix = cx.suffix in
        let args =
          match ps with
          | [] -> Ty.unit
          | ps -> Ty.tuple (List.map (fun (p : Ty.param) -> p.ty) ps)
        in
        cx.subst <-
          {
            around with
            var =
              (fun k ->
                if k = ka then args else if k = kr then ret else around.var k);
            tail = (fun k -> if k = ke then errs else around.tail k);
          };
        cx.suffix <- suffix ^ "$" ^ o.fname;
        cx.shifted <- inside;
        cx.shift <- cx.next;
        cx.next <- cx.next + most + 1;
        let params =
          List.map
            (fun (p : Ty.param) : C.param -> { mode = p.mode; var = temp cx "x" p.ty })
            ps
        in
        cx.call <-
          Some
            {
              cdep = d;
              cop = o.fname;
              cps = ps;
              cret = ret;
              cerrs = errs;
              cargs = List.map (fun (p : C.param) -> p.var) params;
            };
        let name, given = block_of cx impl.node in
        (* it runs with what the handler needs, the dependency it goes
           over among it *)
        let fty : Ty.ty =
          match ty_of cx impl.node with
          | Fun (_, r, errs, _) -> Fun (ps, r, errs, needs)
          | _ -> bug "an arm `over any` whose type isn't a function's"
        in
        let lam =
          block_value cx ~name ~given params fty impl.loc (fun () ->
              let around = cx.cells in
              cx.cells <- cells;
              let lowered = expr cx body in
              cx.cells <- around;
              lowered)
        in
        cx.subst <- around;
        cx.suffix <- suffix;
        cx.shifted <- Ids.empty;
        cx.call <- None;
        (o.fname, with_cells cx cells lam)
    | _ -> bug "an operation whose type isn't a function's"
  in
  let ops = List.map copy ops in
  (d.dpath, mk (Record (d.dpath, ops)) (Ty.impl [ d ] needs) e.loc)

(* What the `call` clause [clause] of the handler [e] implements, in its
   implementation of [d], whose arms implement the operations [written]
   (compiler.md, "Services stage", "`D.Call`"). `call(c) => body` is
   copied for each other operation of [d], as an arm `over any` is, with
   the result and the errors' row of the call, the variables [vars]
   (Infer.Handler_facts), that operation's: each copy takes the
   operation's arguments and makes [c] of them, its case of `D.Call`. A
   merge's, `call(c, a, b) => body`, is copied for every operation, as
   the fold of two of its results, `fold op` in the record, which
   `c.fold(m, a, b)` calls (eval.ml); and each operation it doesn't write
   an arm for panics, since a merge folds results and isn't installed to
   make them. In each copy, a `match` on [c] takes only that case's arms
   ([cx.case]). *)
and clause_ops cx (e : expr) ~cells ~needs ~vars:(kr, ke) (d : Ty.dep) ~written
    (clause : handler_arm) =
  let impl = clause.arm_impl in
  let params, body =
    match impl.kind with
    | Lambda (ps, body) -> (ps, body)
    | _ -> bug "a `call` clause that isn't a lambda"
  in
  let c = match params with c :: _ -> c | [] -> bug "a `call` clause of no call" in
  let ops =
    match Iface.dep_fields cx.types d with
    | Some ops -> ops
    | None -> bug "a `call` clause of what isn't a dependency"
  in
  let cp = Ty.call_path d.dpath in
  let call_ty : Ty.ty = Con (cp, d.dargs) in
  let fold = List.length params = 3 in
  let inside = Ids.of_list (Ast.bound_in impl) in
  let most = Ids.fold max inside 0 in
  let copy (o : Iface.field) =
    match o.fty with
    | Fun (ps, ret, errs, _) ->
        let around = cx.subst and suffix = cx.suffix and case = cx.case in
        cx.subst <-
          {
            around with
            var = (fun k -> if k = kr then ret else around.var k);
            tail = (fun k -> if k = ke then errs else around.tail k);
          };
        cx.suffix <- suffix ^ "$" ^ o.fname;
        cx.shifted <- inside;
        cx.shift <- cx.next;
        cx.next <- cx.next + most + 1;
        cx.case <- Some (c.pname.id, Ty.call_case o.fname);
        let name, given = block_of cx impl.node in
        let lowered () =
          let around = cx.cells in
          cx.cells <- cells;
          let l = expr cx body in
          cx.cells <- around;
          l
        in
        let lam =
          if fold then
            let cps =
              List.map2
                (fun (p : Resolved.param) t : C.param ->
                  { mode = Read; var = bind cx p.pname t })
                params [ call_ty; ret; ret ]
            in
            let fty =
              Ty.Fun (List.map Ty.read [ call_ty; ret; ret ], ret, Ty.closed, needs)
            in
            block_value cx ~name ~given cps fty impl.loc lowered
          else
            let xs =
              List.map
                (fun (p : Ty.param) : C.param ->
                  { mode = p.mode; var = temp cx "x" p.ty })
                ps
            in
            block_value cx ~name ~given xs (Ty.Fun (ps, ret, errs, needs))
              impl.loc (fun () ->
                let v = bind cx c.pname call_ty in
                let made =
                  mk
                    (Con
                       ( cp,
                         Ty.call_case o.fname,
                         List.map (fun (x : C.param) -> local x.var impl.loc) xs
                       ))
                    call_ty impl.loc
                in
                let l = lowered () in
                mk (Let (v, made, l)) l.ty impl.loc)
        in
        cx.subst <- around;
        cx.suffix <- suffix;
        cx.shifted <- Ids.empty;
        cx.case <- case;
        ((if fold then "fold " ^ o.fname else o.fname), with_cells cx cells lam)
    | _ -> bug "an operation whose type isn't a function's"
  in
  (* a merge's operations it doesn't write: each panics *)
  let unmade (o : Iface.field) =
    match o.fty with
    | Fun (ps, ret, errs, _) ->
        let xs =
          List.map
            (fun (p : Ty.param) : C.param -> { mode = p.mode; var = temp cx "x" p.ty })
            ps
        in
        let handler = Path.local cx.self in
        ( o.fname,
          block_value cx
            ~name:(Path.full (Path.member d.dpath o.fname) ^ cx.suffix)
            ~given:[] xs (Ty.Fun (ps, ret, errs, needs)) e.loc (fun () ->
              panic_with cx e.loc ret
                (Printf.sprintf
                   "`%s` folds two results of a call with its `call` clause, \
                    so it isn't installed to run `%s.%s`"
                   handler d.dpath.name o.fname)) )
    | _ -> bug "an operation whose type isn't a function's"
  in
  let missing = List.filter (fun (o : Iface.field) -> not (List.mem o.fname written)) ops in
  if fold then List.map copy ops @ List.map unmade missing
  else List.map copy missing

(* The body of the `finally` [f], given [given], what it covers ends in,
   as its parameter. *)
and finally_body cx (f : expr) (given : C.expr) =
  match f.kind with
  | Lambda ([ p ], body) ->
      let r = bind cx p.pname given.ty in
      let body = expr cx body in
      mk (Let (r, given, body)) body.ty f.loc
  | _ -> bug "a `finally` that isn't a lambda of one parameter"

(* What [e] ends in, of type [rt], a [Result] of its type: `Ok` of its
   value, or `Err` of its error, as `attempt e` is. *)
and attempted cx (e : C.expr) rt =
  let v, errs = result_args rt in
  let value = temp cx "value" v and error = temp cx "error" errs in
  mk
    (Handle
       {
         body = e;
         value;
         on_value = mk (Con (result_path, "Ok", [ local value e.loc ])) rt e.loc;
         error;
         on_error =
           mk (Con (result_path, "Err", [ local error e.loc ])) rt e.loc;
       })
    rt e.loc

(* An arm of a handler, the lambda [impl], which keeps [cells], the
   state's `var`s' cells. *)
and arm_impl cx cells (impl : expr) =
  let around = cx.cells in
  cx.cells <- cells;
  let lowered = expr cx impl in
  cx.cells <- around;
  with_cells cx cells lowered

(* [c], a call; if it's of `Async.until` in a handler's arm, which lets
   go of the instance while it waits (compiler.md, "The rest of
   `Async`"), the arm's copies of the state are written back to their
   cells first, so other operations see what it changed, and read again
   after, since they may have changed it meanwhile; and the condition
   reads the cells, not the arm's copies, since it's checked each time
   the instance is released, while the arm waits ([with_cells] keeps
   the state in the arm's own locals until it ends). Excl makes sure the
   condition is a block written there. *)
and until_released cx (c : C.expr) =
  match (c.kind, cx.cells) with
  | ( Call (({ kind = Global (p, _, _, _); _ } as f), [ Value cond ], ev),
      (_ :: _ as cells) )
    when p = Path.member (Path.prelude "Async") "until" ->
      let loc = c.loc in
      let cond =
        match cond.kind with
        | Lambda ({ params; ev = lev; outer; captures; body; _ } as l) ->
            let read =
              List.filter
                (fun ((v : C.var), _) ->
                  List.exists (fun (w : C.var) -> w.id = v.id) captures)
                cells
            in
            let body =
              lets
                (List.map
                   (fun ((v : C.var), (cell : C.var)) ->
                     (v, mk (Prim (Get_cell, [ local cell loc ])) v.ty loc))
                   read)
                body
            in
            let captures = captures_of params lev outer body in
            { cond with kind = Lambda { l with captures; body } }
        | _ -> cond
      in
      let written =
        List.map
          (fun ((v : C.var), (cell : C.var)) ->
            mk (Prim (Set_cell, [ local cell loc; local v loc ])) Ty.unit loc)
          cells
      and read_again =
        List.map
          (fun ((v : C.var), (cell : C.var)) ->
            mk
              (Assign (v, mk (Prim (Get_cell, [ local cell loc ])) v.ty loc))
              Ty.unit loc)
          cells
      in
      (* read again however it ends: a waiter that's cancelled has the
         instance back first, and the arm's `finally` and what it writes
         back at its end start from what other operations changed *)
      let call = { c with kind = Call (f, [ Value cond ], ev) } in
      seq_all loc
        (written
        @ [ (match read_again with
            | [] -> call
            | rs -> mk (Finally (call, seq_all loc rs)) call.ty loc) ])
  | _ -> c

(* [c], a call marked `release` in a handler's arm (compiler.md,
   "Services stage", step 4): as [until_released] does around
   `Async.until`, the arm's copies of its state are written back to their
   cells first, so the operations that run meanwhile see what it changed,
   and read again after, however the call ends, since they may have
   changed it; between, `arm_release()` lets go of the instance and
   `arm_retake()` takes it back, queueing like any caller, also however
   the call ends, so the rest of the arm and its `finally` run holding it.
   With no other task, and natively, both do nothing and the reads give
   back what the writes wrote: a plain call. *)
and released cx (c : C.expr) =
  let loc = c.loc in
  let intrinsic x =
    let a : Ty.args = { tys = []; rows = [ Ty.closed; Ty.closed ] } in
    let fty = Ty.apply a (Prelude.scheme x).ty in
    let f = mk (Intrinsic (x, a, [], [])) fty loc in
    mk (Call (f, [], cx.ev)) Ty.unit loc
  in
  let written =
    List.map
      (fun ((v : C.var), (cell : C.var)) ->
        mk (Prim (Set_cell, [ local cell loc; local v loc ])) Ty.unit loc)
      cx.cells
  and read_again =
    List.map
      (fun ((v : C.var), (cell : C.var)) ->
        mk
          (Assign (v, mk (Prim (Get_cell, [ local cell loc ])) v.ty loc))
          Ty.unit loc)
      cx.cells
  in
  seq_all loc
    (written
    @ [
        intrinsic Arm_release;
        mk
          (Finally (c, seq_all loc (intrinsic Arm_retake :: read_again)))
          c.ty loc;
      ])

(* [lam], a lambda of a handler, an arm or its `finally`s, made to keep
   [cells], the state's `var`s' cells, rather than the `var`s: it reads
   each it uses when it starts, and writes back each it changes when it
   ends, even if it fails. *)
and with_cells cx cells (lam : C.expr) =
  match lam.kind with
  | Lambda { name; params; ev; outer; given; captures; body } ->
      let loc = lam.loc in
      let used =
        List.filter
          (fun ((v : C.var), _) ->
            List.exists (fun (w : C.var) -> w.id = v.id) captures)
          cells
      in
      let changed = assigned Ids.empty body in
      let writes =
        List.filter_map
          (fun ((v : C.var), (c : C.var)) ->
            if Ids.mem v.id changed then
              Some
                (mk (Prim (Set_cell, [ local c loc; local v loc ])) Ty.unit loc)
            else None)
          used
      in
      let body =
        match writes with
        | [] -> body
        (* written back however it ends: failing, or cancelled, which
           a `finally` in the arm may have changed the state for *)
        | ws when C.can_fail body || C.can_stop body ->
            mk (Finally (body, seq_all loc ws)) body.ty loc
        | ws ->
            let r = temp cx "result" body.ty in
            lets [ (r, body) ] (List.fold_right seq ws (local r loc))
      in
      let body =
        lets
          (List.map
             (fun ((v : C.var), (c : C.var)) ->
               (v, mk (Prim (Get_cell, [ local c loc ])) v.ty loc))
             used)
          body
      in
      let captures = captures_of params ev outer body in
      {
        lam with
        kind = Lambda { name; params; ev; outer; given; captures; body };
      }
  | _ -> bug "a handler's arm that isn't a lambda"

(* The ids of the locals [e] changes, added to [acc]: those it assigns to,
   and those it passes to a call with `&`, which the call writes back to. *)
and assigned acc (e : C.expr) =
  let acc =
    match e.kind with
    | Assign (v, _) -> Ids.add v.id acc
    | Call (_, args, _) ->
        List.fold_left
          (fun acc -> function
            | C.Ref (v : C.var) -> Ids.add v.id acc | Value _ -> acc)
          acc args
    | _ -> acc
  in
  List.fold_left assigned acc (C.children e)

and arm cx ?error (a : arm) : C.arm =
  match (a.arm_pat.pkind, error) with
  | PFail_in b, Some (error : C.expr) ->
      (* `fail on`: any error, if its tag is one of those `on` was given,
         and the guard holds *)
      let names =
        match List.assoc_opt b.id cx.tags with
        | Some names -> names
        | None -> bug "`fail on` in a function not made for its tags"
      in
      let loc = a.arm_pat.ploc in
      let test = mk (Prim (Tag_in names, [ error ])) Ty.bool loc in
      let guard =
        match a.arm_guard with
        | None -> test
        | Some g -> mk (If (test, expr cx g, mk (Bool false) Ty.bool loc)) Ty.bool loc
      in
      {
        pat = pat PWild (ty_of cx a.arm_pat.pnode) loc;
        guard = Some guard;
        body = expr cx a.arm_body;
      }
  | _ ->
      let pat = pattern cx a.arm_pat in
      let guard = Option.map (expr cx) a.arm_guard in
      { pat; guard; body = expr cx a.arm_body }

(* A `match` with `fail` arms, of type [ty]: a [Handle] of its subject,
   whose value is matched by the other arms, and its error by the `fail`
   arms. The arms aren't handled: what they fail with goes on. A `try
   match` ([passed]) fails again with whatever no arm matched. *)
and handle_match cx ~passed ty loc subject arms =
  let body = expr cx subject in
  let fails, values =
    List.partition (fun (a : arm) -> is_fail cx a.arm_pat.pnode) arms
  in
  (* every `fail` pattern's type is the set the subject fails with *)
  let errs = ty_of cx (List.hd fails).arm_pat.pnode in
  let value = temp cx "value" body.ty and error = temp cx "error" errs in
  let on_value =
    mk (Match (local value loc, List.map (arm cx) values)) ty loc
  in
  let rest =
    if passed then
      [
        {
          C.pat = pat PWild errs loc;
          guard = None;
          body = mk (Fail (local error loc)) ty loc;
        };
      ]
    else []
  in
  let on_error =
    mk
      (Match
         (local error loc, List.map (arm cx ~error:(local error loc)) fails @ rest))
      ty loc
  in
  mk (Handle { body; value; on_value; error; on_error }) ty loc

(* The place [e] names, and the temporaries holding its indices, in the
   order they're evaluated. mut.ml has checked it is a place. *)
and place cx (e : expr) =
  match e.kind with
  | Var (Local b) -> ([], { root = var_of cx b; steps = [] })
  | Field (r, f) -> (
      let binds, pl = place cx r in
      match (node cx e.node).found with
      | Some (Field_of p) ->
          ( binds,
            {
              pl with
              steps = pl.steps @ [ SField (p, f.name, ty_of cx e.node, e.loc) ];
            } )
      | _ -> bug "a field inference didn't find")
  | Index (a, i) ->
      let binds, pl = place cx a in
      let hold_i, i = hold cx "index" (expr cx i) in
      ( binds @ hold_i,
        { pl with steps = pl.steps @ [ SIndex (i, ty_of cx e.node, e.loc) ] } )
  | Slice (a, lo, hi) ->
      let binds, pl = place cx a in
      let hold_lo, lo = hold cx "from" (expr cx lo) in
      let hold_hi, hi = hold cx "to" (expr cx hi) in
      ( binds @ hold_lo @ hold_hi,
        {
          pl with
          steps = pl.steps @ [ SRange (lo, hi, ty_of cx e.node, e.loc) ];
        } )
  | _ -> bug "an assignment to something that isn't a place"

(* `x = v` stays as it is. Anything else finds the place, then evaluates
   the value, then reads and writes the place: the value is held in a
   temporary first in case it changes what the place holds. *)
and assign cx (e : expr) ~onode target op value =
  let value = expr cx value in
  match (target.kind, op) with
  | Var (Local b), None -> mk (Assign (var_of cx b, value)) Ty.unit e.loc
  | _ ->
      (* [place] evaluates the indices, so it has to come first *)
      let binds, pl = place cx target in
      (* only reading the place runs between holding the value and using
         it, so a local needn't be copied *)
      let hold_v, v = hold ~local:true cx "v" value in
      let v =
        match op with
        | None -> v
        | Some op -> (
            (* `x += v` is `x = x + v`, whose `+` is the operator's. Of a
               sized type, `x` is read as its wide type, and what the
               operator makes stored back (sized.ml) *)
            let held = ty_of cx target.node in
            let made =
              match Sized.of_ty held with Some k -> Sized.wide k | None -> held
            in
            match (binop_method op, wrapping_method op) with
            | Some meth, _ | None, Some meth -> (
                let x =
                  operator cx ~onode ~meth (C.Binop op) made e.loc
                    [ widen (read pl target.loc); v ]
                in
                match Sized.of_ty held with
                | Some k -> store_as k ~wrap:(is_wrapping op) x
                | None -> x)
            | None, None -> bug ("`" ^ binop_to_string op ^ "=`"))
      in
      lets (binds @ hold_v) (write pl v e.loc)

(* An operator, `a + b` or `-a`, given its operands, lowered: what
   inference found at its node [onode] (Infer_expr.operator). A method of
   the left side's type, `Time.sub`, is called, as `a.sub(b)` would be;
   an operator on a type variable's values goes through that
   requirement's dictionary, `add` for `+`; and a number's, or a `with
   numeric` type's, is the language's own, [prim]. A `with numeric`
   type's value is what it's represented as, so the same operator does
   for both. *)
and operator cx ~onode ~meth prim ty loc (args : C.expr list) =
  match ((node cx onode).found, args) with
  | Some (Method_of p), _ ->
      let a = targs_of cx onode in
      let callee : C.kind =
        match Prelude.find p with
        | Some x -> Intrinsic (x, a, descs cx a, dicts_of cx onode)
        | None -> Global (p, a, descs cx a, dicts_of cx onode)
      in
      mk
        (Call
           ( mk callee (ty_of cx onode) loc,
             List.map (fun a -> C.Value a) args,
             cx.ev ))
        ty loc
  | Some (Generic_op _), a :: _ when not (is_number a.ty) ->
      mk (Prim (Op (meth, dict cx meth a.ty), args)) ty loc
  | _ -> mk (Prim (prim, args)) ty loc

(* `T.zero` or `T.one`, of type [t]: a number's is a literal, and any
   other type's is through that requirement's dictionary. *)
and value_of cx req (t : Ty.ty) loc =
  let one = req = "one" in
  if t = Ty.int then mk (Int (if one then 1L else 0L)) t loc
  else if t = Ty.float then mk (Float (if one then 1. else 0.)) t loc
  else mk (Prim (Value_of (req, dict cx req t), [])) t loc

(* A call. When every argument passed with `&` is a plain variable, it
   stays as it is. Otherwise each one is read into a temporary, which is
   passed instead and written back to its place once the call returns. The
   callee and the other arguments are held in temporaries too, so
   everything is still evaluated left to right.

   A method call's receiver is its first argument, passed `inout` when
   [changed], `&s.push(1)`. *)
(* A `todo` reached where a [t] is wanted: the standard library's panic,
   at [t], with the `todo`'s place as the call's, which is where the
   panic is said. *)
and todo cx loc t =
  let a : Ty.args = { tys = [ t ]; rows = [ Ty.closed; Ty.closed ] } in
  let fty = Ty.apply a (Prelude.scheme Lib_panic).ty in
  let f = mk (Intrinsic (Lib_panic, a, descs cx a, [])) fty loc in
  let msg = mk (Str "reached a `todo`") Ty.str loc in
  mk (Call (f, [ C.Value msg ], cx.ev)) t loc

(* The standard library's panic with [msg], at [loc], where a [t] is
   wanted, as [todo]'s. *)
and panic_with cx loc t msg =
  let a : Ty.args = { tys = [ t ]; rows = [ Ty.closed; Ty.closed ] } in
  let fty = Ty.apply a (Prelude.scheme Lib_panic).ty in
  let f = mk (Intrinsic (Lib_panic, a, descs cx a, [])) fty loc in
  mk (Call (f, [ C.Value (mk (Str msg) Ty.str loc) ], cx.ev)) t loc

(* `show(x)`, of [x]'s type: a hole's (above, [Interp]). *)
and shown cx (x : C.expr) loc =
  let a : Ty.args = { tys = [ x.ty ]; rows = [ Ty.closed; Ty.closed ] } in
  let fty = Ty.apply a (Prelude.scheme Show).ty in
  let f = mk (Intrinsic (Show, a, descs cx a, [])) fty loc in
  mk (Call (f, [ C.Value x ], cx.ev)) Ty.str loc

(* [a + b], of two strings: `Str.add`, as the operator is. *)
and str_add cx (a : C.expr) (b : C.expr) loc =
  let n : Ty.args = { tys = []; rows = [ Ty.closed; Ty.closed ] } in
  let fty = Ty.apply n (Prelude.scheme Str_add).ty in
  let f = mk (Intrinsic (Str_add, n, [], [])) fty loc in
  mk (Call (f, [ C.Value a; C.Value b ], cx.ev)) Ty.str loc

and call cx ?(changed = false) (e : expr) f args =
  (* a call that gives a default by name, or leaves it out: its arguments
     in order, each left out its literal (Infer.Args) *)
  let args =
    match Infer.Nodes.find_opt e.node cx.nodes with
    | Some { found = Some (Args xs); _ } -> xs
    | _ -> args
  in
  match f.kind with
  | Todo ->
      (* `todo(x)`: the callee is evaluated first, and panics, so nothing
         is called and its arguments are never evaluated, as in `ren run`;
         a type variable never stands for a block (Core Lint), so it's the
         panic at the call's type, not a block's *)
      todo cx f.loc (ty_of cx e.node)
  | Var (Dep_op (dep, op)) ->
      (* never with `&` (mut.ml), so its arguments are values, evaluated in
         order *)
      let args = nan_checked dep op (List.map (expr cx) args) in
      let fty = ty_of cx f.node in
      mk
        (Dep_call
           {
             dep;
             dargs = dep_args cx ~node:f.node dep fty;
             op;
             fty;
             ev = cx.ev;
             next = false;
             args;
           })
        (ty_of cx e.node) e.loc
  | Var (Next_op (dep, op)) ->
      (* `next.get(id)`: the innermost implementation where the handler
         was installed, which is the one it's over (handlers.md, "How it
         runs"), whatever is installed where the call runs *)
      let ev =
        match cx.handler_ev with
        | Some ev -> ev
        | None -> bug "`next` outside a handler"
      in
      let args = nan_checked dep op (List.map (expr cx) args) in
      (* the one under it is at the handler's own types *)
      let dargs =
        match
          List.find_opt (fun (o : Ty.dep) -> o.dpath = dep) cx.handler_deps
        with
        | Some o -> List.map (C.describe cx.tys) o.dargs
        | None -> []
      in
      mk
        (Dep_call
           { dep; dargs; op; fty = ty_of cx f.node; ev; next = true; args })
        (ty_of cx e.node) e.loc
  | Var (Call_op "forward") ->
      (* `call.forward()`: the operation the copy of the arm is for, given
         its arguments, through the evidence where the handler was
         installed, as `next` is *)
      let c = the_call cx in
      let ev =
        match cx.handler_ev with
        | Some ev -> ev
        | None -> bug "`call.forward()` outside a handler"
      in
      mk
        (Dep_call
           {
             dep = c.cdep.dpath;
             dargs = List.map (C.describe cx.tys) c.cdep.dargs;
             op = c.cop;
             fty = Fun (c.cps, c.cret, c.cerrs, Ty.closed);
             ev;
             next = true;
             args = List.map (fun v -> local v e.loc) c.cargs;
           })
        (ty_of cx e.node) e.loc
  | Var (Global p) when for_param cx f.node <> None ->
      for_call cx ~changed e f p (Option.get (for_param cx f.node)) args
  | Var (Global _) when Hashtbl.mem cx.through (f.node, f.loc) ->
      plain_call cx ~changed ~through:(Hashtbl.find cx.through (f.node, f.loc)) e f args
  | Var (Global p) when List.exists is_named args ->
      tags_call cx ~changed e f p args
  | Field (r, _) -> (
      match ((node cx f.node).found, args) with
      | Some (Calls_op { key; from; op; recv; call }), _ ->
          desc_method cx e f r ~key ~from ~op ~written:recv ~shown:call args
      | Some (Method_of p), [ n; body ]
        when changed
             && List.mem (Prelude.find p)
                  [ Some Array_split_at; Some Str_split_at; Some Bytes_split_at ]
        ->
          split_at cx e r n body
      | _ -> plain_call cx ~changed e f args)
  | _ -> plain_call cx ~changed e f args

(* Which of the variables of the handler `for D` called at [node] is [D]
   (Infer.For_param), if it's one. *)
and for_param cx node =
  match Infer.Nodes.find_opt (Infer.for_node node) cx.nodes with
  | Some { found = Some (For_param k); _ } -> Some k
  | _ -> None

(* A call of [p], a handler `for D`, [D] its variable [kd]: a call of the
   function made of it for the dependency [D] is an implementation of at
   this call (compiler.md, "Services stage", "Stripes"), as a handler
   `over any` is made for what it's installed over. That one's variables
   are [p]'s but [D], then the dependency's type arguments, and its rows
   are [p]'s, then what [D] needs and what it fails to start with
   ([fn_def]). *)
and for_call cx ~changed (e : expr) (f : expr) p kd args =
  let a = targs_of cx f.node in
  let d, needs, fails =
    match List.nth a.tys kd with
    | Impl { deps = [ d ]; needs; fails; _ } -> (d, needs, fails)
    | _ -> bug "a handler `for D` given what isn't a handler of one dependency"
  in
  let req = Any_for (p, d.dpath) in
  cx.requests := req :: !(cx.requests);
  let made : Ty.args =
    { tys = List.filteri (fun i _ -> i <> kd) a.tys @ d.dargs; rows = a.rows @ [ needs; fails ] }
  in
  (* its type here, what's known once [D] is: an implementation of [d] *)
  let fty = subst_ty same_subst (ty_of cx f.node) in
  let callee =
    mk (Global (made_path req, made, descs cx made, dicts_of cx f.node)) fty f.loc
  in
  plain_call cx ~changed ~callee e f args

(* A call of [p], a function with parameters of `Tags`, each given its
   tags by name, `on: DbDown`, or passed on, `on: on`: a call of the
   function made for those tags, which takes the other arguments
   (compiler.md, "`over any` and `retry`"). *)
and tags_call cx ~changed (e : expr) (f : expr) p args =
  let sets =
    List.filter_map
      (fun (a : expr) ->
        match a.kind with
        | Named (_, v) -> Some (given_tags cx v)
        | _ -> None)
      args
  in
  let req = Tags_for (p, sets) in
  cx.requests := req :: !(cx.requests);
  let fty =
    match ty_of cx f.node with
    | Fun (ps, r, errs, uses) ->
        Ty.Fun (List.filter (fun (q : Ty.param) -> not (is_tags q.ty)) ps, r, errs, uses)
    | _ -> bug "a call of tags whose callee isn't a function"
  in
  let a = targs_of cx f.node in
  let callee =
    mk (Global (made_path req, a, descs cx a, dicts_of cx f.node)) fty f.loc
  in
  plain_call cx ~changed ~callee e f
    (List.filter (fun a -> not (is_named a)) args)

(* The tags [v], given to a parameter of `Tags`, stand for: those written,
   or those the parameter passed on was given. *)
and given_tags cx (v : expr) =
  match (v.kind, (node cx v.node).found) with
  | Tag_set _, Some (Tags_given names) -> names
  | Var (Local b), _ -> (
      match List.assoc_opt (local_id cx b) cx.tags with
      | Some names -> names
      | None -> bug "a parameter of `Tags` in a function not made for its tags")
  | _ -> bug "tags inference didn't find"

(* `d.op(args)`, [e]: `with d in Dep.op(args)`, the description [r] and
   the arguments evaluated first, in order, outside (foundations.md,
   decision 3). [key] is what it's installed as, implementing [from].
   It's recorded in [calls], with [written], [r] as written, and [shown],
   the call as a `with` would make it, for Stateless (stateless.ml). *)
and desc_method cx (e : expr) (f : expr) (r : expr) ~key ~from ~op ~written ~shown
    args =
  let k = key_of_label cx key in
  let hold_r, recv = hold ~local:true cx "desc" (expr cx r) in
  let binds, values =
    List.fold_left
      (fun (binds, values) (a : expr) ->
        let b, v = hold ~local:true cx "arg" (expr cx a) in
        (binds @ b, values @ [ v ]))
      ([], []) args
  in
  let ty = ty_of cx e.node in
  let fty =
    match e.kind with
    | Call (f, _) -> ty_of cx f.node
    | _ -> bug "a method call that isn't a call"
  in
  let ev = evidence cx and outer = cx.ev in
  let mop = match f.kind with Field (_, m) -> m.loc | _ -> e.loc in
  cx.calls :=
    { C.mdep = from; mrecv = written; mcall = shown; mloc = e.loc; mop }
    :: !(cx.calls);
  let body =
    mk
      (Dep_call
         {
           dep = k.kpath;
           dargs = k.kargs;
           op;
           fty;
           ev;
           next = false;
           args = nan_checked k.kpath op values;
         })
      ty e.loc
  in
  lets (hold_r @ binds)
    (mk
       (With
          {
            ev;
            outer;
            dep = k.kpath;
            dargs = k.kargs;
            from;
            impl = recv;
            desc = C.describe cx.tys ty;
            body;
          })
       ty e.loc)

(* `&xs.split_at(n) fn(&lo, &hi) => ...`, [e]: the block given the halves
   of the place [r], `xs[0..n]` and `xs[n..len]`, each in a variable of
   its own, which it changes, as an argument passed with `&` is; then
   [r] is the first followed by the second, even if the block fails
   (compiler.md, "Blocks with `inout` parameters, and slices"). The place
   is read, and written back, once, so the block can't see [r] (excl.ml:
   the call writes it), and holds [Vacant] meanwhile. What the block
   gives is the call's. *)
and split_at cx (e : expr) (r : expr) n body =
  let loc = e.loc in
  let ty = ty_of cx e.node and self = ty_of cx r.node in
  let binds, pl = place cx r in
  let hold_n, n = hold cx "n" (expr cx n) in
  let hold_b, body = hold cx "body" (expr cx body) in
  let whole = temp cx "whole" self in
  let lo = temp cx "lo" self and hi = temp cx "hi" self in
  (* the place as it's written, which a cut character's help names *)
  let half which args =
    mk (Prim (Slice which, local whole r.loc :: n :: args)) self loc
  in
  let call = mk (Call (body, [ Ref lo; Ref hi ], cx.ev)) ty loc in
  let back =
    write pl (mk (Prim (Join, [ local lo loc; local hi loc ])) self loc) loc
  in
  lets
    (binds @ hold_n @ hold_b
    @ [
        (whole, read pl loc);
        (* the place is vacant while the block has its halves, which a
           native build can then change in place *)
        (temp cx "vacant" Ty.unit,
         write pl (mk (Prim (Vacant, [ local whole loc ])) self loc) loc);
        (lo, half Before []);
        (hi, half After [ local lo loc ]);
      ])
    (if C.fails body.ty then mk (Finally (call, back)) ty loc
     else
       let result = temp cx "result" ty in
       lets [ (result, call) ] (seq back (local result loc)))

and plain_call cx ~changed ?callee ?through (e : expr) f args =
  let inout (p : expr) ty =
    let binds, pl = place cx p in
    Inout { binds; place = pl; ty; loc = p.loc }
  in
  let f, receiver =
    match (f.kind, (node cx f.node).found) with
    | _ when callee <> None -> (Option.get callee, [])
    | Field (r, _), Some (Method_of p) ->
        let recv =
          if changed then inout r (ty_of cx r.node)
          else if is_pulled cx r then
            (* a cursor's `count()`, its receiver a pull argument
               (Infer_expr.cursor_count) *)
            let binds, block = pull_block cx r in
            Pull (binds, block)
          else Read (expr cx r)
        in
        (* a built-in method, `xs.len()`, is built into the compiler *)
        let callee : C.kind =
          let a = targs_of cx f.node in
          match Prelude.find p with
          | Some x -> Intrinsic (x, a, descs cx a, dicts_of cx f.node)
          | _ -> Global (p, a, descs cx a, dicts_of cx f.node)
        in
        (mk callee (ty_of cx f.node) f.loc, [ recv ])
    | _ -> (expr cx f, [])
  in
  let lowered =
    receiver
    @ List.map
        (fun (a : expr) ->
          match a.kind with
          | _ when is_pulled cx a ->
              let binds, block = pull_block cx a in
              Pull (binds, block)
          | Ref p when changed_receiver a = None -> inout p (ty_of cx a.node)
          | _ -> Read (expr cx a))
        args
  in
  let ty = ty_of cx e.node in
  match (f.kind, lowered) with
  | Intrinsic (((Pulled_count | Pulled_count_by) as x), _, _, _), Pull (binds, items) :: rest ->
      pulled_count cx e.loc ~by:(x = Pulled_count_by) binds items rest
  | _ ->
  let direct = function
    | Read a | Pull ([], a) -> Some (C.Value a)
    | Inout { binds = []; place = { root; steps = [] }; _ } -> Some (C.Ref root)
    | Inout _ | Pull _ -> None
  in
  if through = None && List.for_all (fun a -> direct a <> None) lowered then
    mk (Call (f, List.filter_map direct lowered, cx.ev)) ty e.loc
  else
    let hold_f, f = hold cx "f" f in
    let binds, args, writes =
      List.fold_left
        (fun (binds, args, writes) a ->
          match a with
          | Read v ->
              let b, v = hold cx "arg" v in
              (binds @ b, args @ [ C.Value v ], writes)
          | Pull (b, block) -> (binds @ b, args @ [ C.Value block ], writes)
          | Inout r ->
              let t = temp cx "ref" r.ty in
              ( binds @ r.binds @ [ (t, read r.place r.loc) ],
                args @ [ C.Ref t ],
                writes @ [ write r.place (local t r.loc) r.loc ] ))
        (hold_f, [], []) lowered
    in
    (* through an alias, only the call itself runs with the alias's
       implementation: the callee and its arguments are held first *)
    let call =
      match through with
      | Some alias -> rebound cx ~alias e.loc (fun () -> mk (Call (f, args, cx.ev)) ty e.loc)
      | None -> mk (Call (f, args, cx.ev)) ty e.loc
    in
    if C.fails f.ty then
      (* the places are written back even if it fails *)
      lets binds (mk (Finally (call, seq_all e.loc writes)) ty e.loc)
    else
      let result = temp cx "result" ty in
      lets binds
        (lets
           [ (result, call) ]
           (List.fold_right seq writes (local result e.loc)))

and block cx stmts last =
  match stmts with
  | [] -> expr cx last
  | Let { name; value; _ } :: rest ->
      let value = expr cx value in
      let v = bind cx name value.ty in
      let body = block cx rest last in
      mk (Let (v, value, body)) body.ty value.loc
  | Let_pattern { pat; value; else_ } :: rest ->
      let value = expr cx value in
      take_apart cx pat ?else_ value (fun () -> block cx rest last)
  | Expr e :: rest ->
      let e = expr cx e in
      seq e (block cx rest last)
  | Finally f :: rest -> (
      (* in an arm: it's given what the rest of it ends in, or
         `Err(Cancelled)`, if that was cancelled (Core.Covered) *)
      let rt =
        match ty_of cx f.node with
        | Fun ([ r ], _, _, _) -> r.ty
        | _ -> bug "a `finally` whose type isn't a function's"
      in
      let covered = attempted cx (block cx rest last) rt in
      match f.kind with
      | Lambda ([ p ], body) ->
          let result = bind cx p.pname rt in
          let after = expr cx body in
          mk (Covered { body = covered; result; after }) after.ty f.loc
      | _ -> bug "a `finally` that isn't a lambda of one parameter")

(* [body ()] with [pat] bound to [value]: a [Let], or a [match] of one
   arm, which always matches (Exhaust sees to that). With [else_], `let
   PAT = value else LEAVE`, a [match] of two arms, [pat] then the body,
   and `_` then [else_], which leaves, so it's of the body's type
   (inference checked it is). *)
and take_apart cx (pat : pattern) ?else_ (value : C.expr) body =
  match (pat.pkind, else_) with
  | PVar b, None ->
      let v = bind cx b value.ty in
      let body = body () in
      mk (Let (v, value, body)) body.ty value.loc
  | _, None ->
      let pat = pattern cx pat in
      let body = body () in
      mk (Match (value, [ { pat; guard = None; body } ])) body.ty value.loc
  | _, Some leave ->
      let leave = expr cx leave in
      let pat = pattern cx pat in
      let body = body () in
      let other : C.pattern = { pkind = PWild; pty = value.ty; ploc = pat.ploc } in
      mk
        (Match
           ( value,
             [
               { pat; guard = None; body };
               { pat = other; guard = None; body = leave };
             ] ))
        body.ty value.loc

(* `for i in a..b` holds both ends, then counts from the first up to the
   second, which it never reaches: when it starts there, the body never
   runs. *)
and range_loop cx (e : expr) (pat : pattern) lo hi body =
  let loc = e.loc in
  let lo = expr cx lo in
  let hi = expr cx hi in
  let stop = temp cx "stop" Ty.int and i = temp cx "i" Ty.int in
  let index = local i loc in
  let binop op a b ty = mk (Prim (Binop op, [ a; b ])) ty loc in
  let step =
    mk (Assign (i, binop Add index (int_lit 1L loc) Ty.int)) Ty.unit loc
  in
  let pass = take_apart cx pat index (fun () -> seq (expr cx body) step) in
  lets
    [ (i, lo); (stop, hi) ]
    (mk (While (binop Lt index (local stop loc) Ty.bool, pass)) Ty.unit loc)

(* `for x in xs` holds the array, then goes over its indices; a `Map`'s
   entries and a `Set`'s members are made an array first, in order.
   `for p in &ps` finds the place (once), then each pass copies the element
   into `p` and writes it back afterwards, even if the body fails or
   `break`s. mut.ml makes sure the body can't change the array itself, so
   its length can't change. A cursor's is a loop of its own
   ([cursor_loop]). *)
and for_loop cx (e : expr) index (pat : pattern) (iter : expr) body =
  match (node cx e.node).found with
  | Some Pulls_block -> block_loop cx e pat iter body
  | Some (Method_of next) -> (
      match zipped cx iter with
      | Some arrays -> zip_loop cx e pat arrays body
      | None -> cursor_loop cx e pat iter next body)
  | _ -> array_loop cx e index pat iter body

(* The arrays of `xs.zip(ys)` or `xs.zip(ys).zip(zs)`, if [iter] is one
   of those calls of the prelude's, in the order they're evaluated. *)
and zipped cx (iter : expr) =
  let method_ (f : expr) =
    match (node cx f.node).found with Some (Method_of p) -> Some p | _ -> None
  in
  let zip_of owner = Some (Path.member (Path.prelude owner) "zip") in
  match iter.kind with
  | Call (({ kind = Field (xs, _); _ } as f), [ ys ])
    when method_ f = zip_of "Array" ->
      Some [ xs; ys ]
  | Call (({ kind = Field (pair, _); _ } as f), [ zs ])
    when method_ f = zip_of "Zip" -> (
      match zipped cx pair with
      | Some [ xs; ys ] -> Some [ xs; ys; zs ]
      | _ -> None)
  | _ -> None

(* `for (x, y) in xs.zip(ys)`, and three arrays' the same way: what the
   cursor `Zip` would give, without making one. Each array is held, as
   `zip` would hold it, in the order written; the loop counts up to the
   shortest length, which is each array's bound at once, and each pass
   takes the element at the count from each (bounds.ml finds the reads in
   bounds). A pattern of as many names as arrays binds the elements
   directly, with no tuple made. *)
and zip_loop cx (e : expr) (pat : pattern) (arrays : expr list) body =
  let loc = e.loc in
  let held =
    List.map
      (fun (a : expr) ->
        let v = expr cx a in
        (temp cx "xs" v.ty, v))
      arrays
  in
  let lens =
    List.map
      (fun ((xs : C.var), _) ->
        (temp cx "len" Ty.int, mk (Prim (Length, [ local xs loc ])) Ty.int loc))
      held
  in
  let binop op a b ty = mk (Prim (Binop op, [ a; b ])) ty loc in
  (* the least of the lengths, a pair at a time *)
  let n, mins =
    match lens with
    | [] -> bug "a zip of no arrays"
    | (first, _) :: rest ->
        List.fold_left
          (fun ((least : C.var), binds) ((l : C.var), _) ->
            let m = temp cx "n" Ty.int in
            let a = local least loc and b = local l loc in
            ( m,
              binds
              @ [ (m, mk (If (binop Lt a b Ty.bool, a, b)) Ty.int loc) ] ))
          (first, []) rest
  in
  let i = temp cx "i" Ty.int in
  let index = local i loc in
  let step =
    mk (Assign (i, binop Add index (int_lit 1L loc) Ty.int)) Ty.unit loc
  in
  let elements =
    List.map
      (fun ((xs : C.var), _) ->
        mk (Prim (Get_index Checked, [ local xs loc; index ]))
          (C.elem_ty xs.ty) loc)
      held
  in
  let rest () = seq (expr cx body) step in
  let pass =
    match pat.pkind with
    | PTuple ps when List.length ps = List.length elements ->
        List.fold_right2
          (fun p el k () -> take_apart cx p el k)
          ps elements rest ()
    | _ ->
        let tuple = Ty.tuple (List.map (fun (el : C.expr) -> el.ty) elements) in
        take_apart cx pat (mk (Tuple elements) tuple loc) rest
  in
  lets
    (held @ lens @ mins @ [ (i, int_lit 0L loc) ])
    (mk (While (binop Lt index (local n loc) Ty.bool, pass)) Ty.unit loc)

and array_loop cx (e : expr) idx (pat : pattern) (iter : expr) body =
  let loc = e.loc in
  let iter_ty = ty_of cx iter.node in
  (* what's gone over, as an array, from the value of [iter] *)
  let array_ty, elements =
    match iter_ty with
    | Con (p, [ k; v ]) when p = Path.prelude "Map" ->
        let t = Ty.array (Ty.tuple [ k; v ]) in
        (t, fun m -> mk (Prim (Entries, [ m ])) t iter.loc)
    | Con (p, [ x ]) when p = Path.prelude "Set" ->
        let t = Ty.array x in
        (t, fun s -> mk (Prim (Members, [ s ])) t iter.loc)
    | t -> (t, Fun.id)
  in
  let elem = C.elem_ty array_ty in
  let n = temp cx "n" Ty.int and i = temp cx "i" Ty.int in
  let index = local i iter.loc in
  let index_e = index in
  let binop op a b ty = mk (Prim (Binop op, [ a; b ])) ty loc in
  let step =
    mk (Assign (i, binop Add index (int_lit 1L loc) Ty.int)) Ty.unit loc
  in
  (* `for i, x in xs`: [pass ()], with the index bound first *)
  let numbered pass =
    match idx with
    | Some ip -> take_apart cx ip index_e pass
    | None -> pass ()
  in
  (* [pass] makes each pass, given each element *)
  let loop ~start ~pass =
    lets
      [ (n, mk (Prim (Length, [ start ])) Ty.int loc); (i, int_lit 0L loc) ]
      (mk (While (binop Lt index (local n loc) Ty.bool, pass)) Ty.unit loc)
  in
  match (iter.kind, pat.pkind) with
  | Ref p, PVar b -> (
      let binds, pl = place cx p in
      let x = bind cx b elem in
      let changing pl =
        let at =
          { pl with steps = pl.steps @ [ SIndex (index, elem, iter.loc) ] }
        in
        let pass () =
          let body = expr cx body in
          (* the element is written back after the body, even if it fails *)
          let write = write at (local x loc) loc in
          let rest =
            if C.can_fail body || breaks body then
              seq (mk (Finally (body, write)) body.ty loc) step
            else seq body (seq write step)
          in
          mk (Let (x, read at iter.loc, rest)) Ty.unit loc
        in
        loop ~start:(read pl iter.loc) ~pass:(numbered pass)
      in
      match split_range pl with
      | None -> lets binds (changing pl)
      | Some (range, after) ->
          (* `for x in &xs[a..b]`: the range is read once, changed, and
             written back once, even if the loop fails, as `&xs[a..b]`
             passed to a call is *)
          let ty =
            match List.rev range.steps with
            | SRange (_, _, t, _) :: _ -> t
            | _ -> bug "a range's place that doesn't end in one"
          in
          let t = temp cx "range" ty in
          let looped = changing { root = t; steps = after } in
          let back = write range (local t loc) loc in
          lets
            (binds @ [ (t, read range iter.loc) ])
            (if C.can_fail looped then mk (Finally (looped, back)) Ty.unit loc
             else seq looped back))
  | Ref _, _ -> bug "a `for` with `&` that takes its element apart"
  | _ ->
      let xs = temp cx "xs" array_ty in
      let xs_e = local xs iter.loc in
      let element = mk (Prim (Get_index Checked, [ xs_e; index ])) elem iter.loc in
      lets
        [ (xs, elements (expr cx iter)) ]
        (loop ~start:xs_e
           ~pass:
             (numbered (fun () ->
                  take_apart cx pat element (fun () -> seq (expr cx body) step))))

(* `for x in &c` over a cursor (Infer_expr.cursor), whose method [next]
   is called each time round, with `&` of the place, until it gives
   `None`: a [While] that [Break]s then. Inference recorded the method's
   use at the `for`'s node, [e] (Infer_expr.cursor). `c` keeps its place
   after the loop, a `break` included. `for x in c` goes over a copy, in
   a temporary. *)
and cursor_loop cx (e : expr) (pat : pattern) (iter : expr) next body =
  let loc = e.loc in
  let cursor = ty_of cx iter.node in
  let elem = ty_of cx pat.pnode in
  let opt : Ty.ty = Con (option_path, [ elem ]) in
  let call =
    next_call cx ?through:(made_through cx iter) ~at:e.node ~meth_at:e.node next opt iter.loc
  in
  (* the place it advances, and how to advance it once: a local is passed
     as it is, and anything else through a temporary, written back *)
  let binds, advance =
    match iter.kind with
    | Ref p -> (
        let binds, pl = place cx p in
        match pl with
        | { root; steps = [] } -> (binds, call root)
        | _ ->
            let t = temp cx "ref" cursor and got = temp cx "next" opt in
            ( binds,
              lets
                [ (t, read pl iter.loc); (got, call t) ]
                (seq (write pl (local t loc) loc) (local got loc)) ))
    | _ ->
        let copy = temp cx "cursor" cursor in
        ([ (copy, expr cx iter) ], call copy)
  in
  option_loop cx e pat binds advance body

(* [body ()], with the implementation of the alias [alias], `Events` for
   `dep Events = Chan<Event>`, installed as the dependency it names, for a
   member function of that one called through it, `Events.items()`, and a
   cursor's `next` that call makes: a stateless handler whose operations
   call the alias's, installed around [body] alone, so nothing else there
   sees it (compiler.md, "Services stage", step 5). *)
and rebound cx ~(alias : Path.t) loc (body : unit -> C.expr) =
  let target =
    match cx.types alias with
    | Some { body = Dep_alias d; _ } -> d
    | _ -> bug "a call through an alias that isn't one"
  in
  let ops =
    match Iface.dep_fields cx.types (Ty.plain alias) with
    | Some ops -> ops
    | None -> bug "an alias of a dependency without operations"
  in
  let needs : Ty.row = { labels = [ Ty.dep_of (Ty.plain alias) ]; tail = None } in
  let impl_ty = Ty.impl [ target ] needs in
  (* the handler, whose operations run where it's installed *)
  let hev = evidence cx and outer = cx.ev in
  cx.ev <- hev;
  let forwarded =
    List.map
      (fun (o : Iface.field) ->
        match o.fty with
        | Fun (ps, ret, errs, _) ->
            let fty = Ty.Fun (ps, ret, errs, needs) in
            let params =
              List.map
                (fun (q : Ty.param) : C.param -> { mode = Read; var = temp cx "x" q.ty })
                ps
            in
            ( o.fname,
              block_value cx
                ~name:(Path.full (Path.member alias o.fname))
                ~given:[] params fty loc
                (fun () ->
                  let args = List.map (fun (q : C.param) -> local q.var loc) params in
                  mk
                    (Dep_call
                       {
                         dep = alias;
                         dargs = [];
                         op = o.fname;
                         fty;
                         ev = cx.ev;
                         next = false;
                         args = nan_checked alias o.fname args;
                       })
                    ret loc) )
        | _ -> bug "an operation whose type isn't a function's")
      ops
  in
  cx.ev <- outer;
  let instance =
    mk
      (Instance
         {
           impls = [ (target.dpath, mk (Record (target.dpath, forwarded)) impl_ty loc) ];
           finally = None;
           exclusive = false;
         })
      impl_ty loc
  in
  let captures = List.filter (fun (v : C.var) -> v.id <> hev.id) (free instance) in
  let handler = mk (Handler { ev = hev; captures; body = instance }) impl_ty loc in
  let ev = evidence cx in
  cx.ev <- ev;
  let b = body () in
  cx.ev <- outer;
  mk
    (With
       {
         ev;
         outer;
         dep = target.dpath;
         dargs = List.map (C.describe cx.tys) target.dargs;
         from = target.dpath;
         impl = handler;
         desc = C.describe cx.tys b.ty;
         body = b;
       })
    b.ty loc

(* The alias a cursor [iter] is made through, if it's a call of a
   dependency's member function through one, `Events.items()`: its
   `next` is called with the alias's implementation too ([rebound]). *)
and made_through cx (iter : expr) =
  match iter.kind with
  | Call ({ kind = Var (Global _); node; loc }, _) -> Hashtbl.find_opt cx.through (node, loc)
  | _ -> None

(* Whether [a] is a pull argument, what `for` takes passed to a block
   parameter `fn() -> Option<T>` (Infer_expr.pull_arg). *)
and is_pulled cx (a : expr) =
  match Infer.Nodes.find_opt (Infer.pulled_node a.node) cx.nodes with
  | Some { found = Some (Pulled _); _ } -> true
  | _ -> false

(* The block a pull argument [a] is passed as, of the parameter's type,
   `fn() -> Option<T>`, which gives its next item each time it's called,
   on the caller's task (streams.md, rule 3), with what it pulls from,
   bound first, where the argument is evaluated: a collection's from a
   snapshot of it, counting along it; a temporary cursor's, held, from its
   `next`; and a named one's, `&r`, from its `next` on the place, which
   the block changes where it is, so it goes on from there after the call
   (excl.ml holds it changed for the whole call). *)
and pull_block cx (a : expr) =
  let at = Infer.pulled_node a.node in
  let n = node cx at in
  let what, name =
    match n.found with
    | Some (Pulled { what; name }) -> (what, name ^ cx.suffix)
    | _ -> bug "a pull argument inference didn't say how to pull"
  in
  let bty = n.ty in
  let opt = match bty with Fun (_, r, _, _) -> r | _ -> bug "a pull block that isn't one" in
  let elem =
    match opt with Con (_, [ x ]) -> x | _ -> bug "a pull of what isn't an `Option`"
  in
  let loc = a.loc in
  let pulling body = block_value cx ~name ~given:[] [] bty loc body in
  match (what, a.kind) with
  | Snapshot, _ ->
      let v = expr cx a in
      let array_ty = Ty.array elem in
      let snapshot =
        match v.ty with
        | Con (p, [ _; _ ]) when p = Path.prelude "Map" ->
            mk (Prim (Entries, [ v ])) array_ty loc
        | Con (p, [ _ ]) when p = Path.prelude "Set" ->
            mk (Prim (Members, [ v ])) array_ty loc
        | _ -> v
      in
      let xs = temp cx "xs" array_ty and i = temp cx "i" Ty.int in
      let index = local i loc in
      let binop op a b ty = mk (Prim (Binop op, [ a; b ])) ty loc in
      ( [ (xs, snapshot); (i, int_lit 0L loc) ],
        pulling (fun () ->
             let x = temp cx "x" elem in
             let more =
               binop Lt index (mk (Prim (Length, [ local xs loc ])) Ty.int loc) Ty.bool
             in
             let next =
               lets
                 [ (x, mk (Prim (Get_index Checked, [ local xs loc; index ])) elem loc) ]
                 (seq
                    (mk (Assign (i, binop Add index (int_lit 1L loc) Ty.int)) Ty.unit loc)
                    (mk (Con (option_path, "Some", [ local x loc ])) opt loc))
             in
             mk (If (more, next, mk (Con (option_path, "None", [])) opt loc)) opt loc) )
  | Cursor next, Ref p -> (
      let binds, pl = place cx p in
      let cursor = ty_of cx a.node in
      let call = next_call cx ~at ~meth_at:a.node next opt loc in
      match pl with
      | { root; steps = [] } -> (binds, pulling (fun () -> call root))
      | _ ->
          ( binds,
            pulling (fun () ->
                let t = temp cx "ref" cursor and got = temp cx "next" opt in
                lets
                  [ (t, read pl loc); (got, call t) ]
                  (seq (write pl (local t loc) loc) (local got loc))) ))
  | Cursor next, _ ->
      let c = temp cx "cursor" (ty_of cx a.node) in
      let call = next_call cx ?through:(made_through cx a) ~at ~meth_at:a.node next opt loc in
      ([ (c, expr cx a) ], pulling (fun () -> call c))

(* A call of [next], a cursor's method, found at the node [at], at the
   type recorded at [meth_at]'s [Infer.next_node], on the cursor in [v],
   giving [opt]: what uses it has, a channel's `items()`'s, are in the
   evidence where it's called. *)
and next_call cx ?through ~at ~meth_at next opt loc (v : C.var) =
  let fty = ty_of cx (Infer.next_node meth_at) in
  let a = targs_of cx at in
  let callee : C.kind =
    match Prelude.find next with
    | Some x -> Intrinsic (x, a, descs cx a, dicts_of cx at)
    | None -> Global (next, a, descs cx a, dicts_of cx at)
  in
  let call () = mk (Call (mk callee fty loc, [ Ref v ], cx.ev)) opt loc in
  match through with
  | Some alias -> rebound cx ~alias loc call
  | None -> call ()

(* A cursor's `c.count()`, or `c.count(f)` if [by] (Infer_expr.cursor_count),
   written out: [items], the block that pulls the cursor, after [binds],
   called until it gives `None`, as [option_loop] calls it, counting the
   items, or those [f], held first, is true of. *)
and pulled_count cx loc ~by binds (items : C.expr) rest =
  let opt = match items.ty with Fun (_, r, _, _) -> r | _ -> bug "a pull that isn't a block" in
  let elem = match opt with Con (_, [ x ]) -> x | _ -> bug "a pull of what isn't an `Option`" in
  let b = temp cx "items" items.ty and n = temp cx "n" Ty.int in
  let held, test =
    match (by, rest) with
    | true, [ Read f ] ->
        let fv = temp cx "f" f.ty in
        ([ (fv, f) ], Some fv)
    | false, [] -> ([], None)
    | _ -> bug "a cursor's `count` given what it doesn't take"
  in
  let x = temp cx "x" elem in
  let add =
    mk (Assign (n, mk (Prim (Binop Add, [ local n loc; int_lit 1L loc ])) Ty.int loc)) Ty.unit loc
  in
  let counted =
    match test with
    | Some fv ->
        let yes = mk (Call (local fv loc, [ Value (local x loc) ], cx.ev)) Ty.bool loc in
        mk (If (yes, add, C.unit loc)) Ty.unit loc
    | None -> add
  in
  let pat kind : C.pattern = { pkind = kind; pty = opt; ploc = loc } in
  let some : C.arm =
    {
      pat = pat (PCon (option_path, "Some", [ { pkind = PVar x; pty = elem; ploc = loc } ]));
      guard = None;
      body = counted;
    }
  in
  let none : C.arm =
    { pat = pat (PCon (option_path, "None", [])); guard = None; body = mk Break Ty.unit loc }
  in
  let pass = mk (Match (mk (Call (local b loc, [], cx.ev)) opt loc, [ some; none ])) Ty.unit loc in
  lets
    (binds @ [ (b, items) ] @ held @ [ (n, int_lit 0L loc) ])
    (seq (mk (While (mk (Bool true) Ty.bool loc, pass)) Ty.unit loc) (local n loc))

(* `for x in f`, or `for x in try f`, [f] a block `fn() -> Option<T>`
   (Infer_expr.block_subject): [f] is called each time round, until it
   gives `None`. A call that fails ends the loop with its error, as any
   call does. *)
and block_loop cx (e : expr) (pat : pattern) (iter : expr) body =
  let f = match iter.kind with Try f -> f | _ -> iter in
  let fv = expr cx f in
  let ret = match fv.ty with Fun (_, r, _, _) -> r | _ -> bug "a block pulled that isn't one" in
  option_loop cx e pat [] (mk (Call (fv, [], cx.ev)) ret iter.loc) body

(* The loop of a cursor or a block: [advance] each time round, after
   [binds], until it gives `None`, the body run with [pat] bound to what's
   in each `Some`, as a [While] that [Break]s at `None`. *)
and option_loop cx (e : expr) (pat : pattern) binds (advance : C.expr) body =
  let loc = e.loc in
  let opt = advance.ty in
  (* the pattern binds what the body uses, so it's lowered first *)
  let elem_pat = pattern cx pat in
  let body =
    (* its value is dropped, as a statement's is *)
    let b = expr cx body in
    if b.ty = Ty.unit then b else seq b (C.unit loc)
  in
  let some : C.arm =
    {
      pat =
        {
          pkind = PCon (option_path, "Some", [ elem_pat ]);
          pty = opt;
          ploc = pat.ploc;
        };
      guard = None;
      body;
    }
  in
  let none : C.arm =
    {
      pat = { pkind = PCon (option_path, "None", []); pty = opt; ploc = loc };
      guard = None;
      body = mk Break Ty.unit loc;
    }
  in
  let pass = mk (Match (advance, [ some; none ])) Ty.unit loc in
  lets binds (mk (While (mk (Bool true) Ty.bool loc, pass)) Ty.unit loc)

(* Whether [e] has a [Break] in it that leaves it, one outside every
   [While] in it. *)
and breaks (e : C.expr) =
  match e.kind with
  | Break -> true
  | While _ | Lambda _ | Handler _ -> false
  | _ -> List.exists breaks (C.children e)

and pattern cx (p : pattern) : C.pattern =
  let pty = ty_of cx p.pnode in
  let pkind : C.pattern_kind =
    match p.pkind with
    | PWild -> PWild
    | PVar b -> PVar (bind cx b pty)
    | PInt n -> PInt n
    | PBool b -> PBool b
    | PCon (c, ps) -> (
        match (node cx p.pnode).found with
        | Some (Ctor_of (path, c)) -> PCon (path, c, List.map (pattern cx) ps)
        | Some Error_tag ->
            (* a tag, inside `Err(...)` *)
            PTag (c.name.name, List.map (pattern cx) ps)
        | _ -> bug "a constructor pattern inference didn't find")
    | PFail (t, ps) -> PTag (t.name, List.map (pattern cx) ps)
    | PFail_any -> PWild
    | PFail_in _ -> bug "`fail on` other than as a whole arm's pattern"
    | POr ps -> POr (List.map (pattern cx) ps)
    | PAs (q, b) ->
        (* of a by-name constructor's pattern, its variant type, as
           inference has it: the same value, the subject itself *)
        let whole : Ty.ty =
          match (q.pkind, (node cx q.pnode).found, pty) with
          | PCon_named _, Some (Ctor_of (path, c)), Con (s, args)
            when s = path && ctor_named cx path c ->
              Variant (path, c, args)
          | _ -> pty
        in
        PAs (pattern cx q, bind cx b whole)
    | PTuple ps -> PTuple (List.map (pattern cx) ps)
    | PStr s -> PStr s
    | PSeq q when q.bracketed ->
        let rest : C.rest =
          match q.middle with
          | None -> No_rest
          | Some r -> Rest (Option.map (fun b -> bind cx b pty) r.rname)
        in
        PArray
          {
            front = List.map (pattern cx) q.front;
            rest;
            back = List.map (pattern cx) q.back;
          }
    | PSeq q ->
        (* the literal pieces on each side of the rest, as one *)
        let text ps =
          String.concat ""
            (List.map
               (fun (p : pattern) -> match p.pkind with PStr s -> s | _ -> "")
               ps)
        in
        PStr_rest
          {
            prefix = text q.front;
            rest =
              Option.map (fun b -> bind cx b pty)
                (Option.bind q.middle (fun r -> r.rname));
            suffix = text q.back;
          }
    | PCon_named (_, fs) -> (
        (* the positional constructor, a pattern for every field, in
           declaration order, `_` for one left out *)
        match ((node cx p.pnode).found, pty) with
        | Some (Ctor_of (path, c)), (Con (_, args) | Variant (_, _, args)) ->
            let field (d : Iface.field) =
              match
                List.find_opt (fun ((f : ident), _) -> f.name = d.fname) fs.fpats
              with
              | Some (_, q) -> pattern cx q
              | None ->
                  {
                    pkind = PWild;
                    pty = Ty.apply { tys = args; rows = [] } d.fty;
                    ploc = p.ploc;
                  }
            in
            PCon (path, c, List.map field (ctor_decl cx path c))
        | _ -> bug "a by-name constructor pattern inference didn't find")
    | PRecord (_, fs) -> (
        (* a pattern for every field, in declaration order, `_` for one
           left out *)
        let field path (d : Iface.field) : C.pattern =
          match
            List.find_opt (fun ((f : ident), _) -> f.name = d.fname) fs.fpats
          with
          | Some (_, q) -> pattern cx q
          | None ->
              { pkind = PWild; pty = field_ty cx pty path d.fname; ploc = p.ploc }
        in
        match pty with
        | Variant (path, c, _) ->
            (* a variant type is a record of its constructor's fields: its
               constructor's pattern, which always matches *)
            PCon (path, c, List.map (field path) (ctor_decl cx path c))
        | Con (path, _) -> PRecord (path, List.map (field path) (record_decl cx path))
        | _ -> bug "a record pattern whose type isn't a record")
  in
  { pkind; pty; ploc = p.ploc }

(* The fields of the constructor [c] of the sum type [path], as they're
   declared. *)
and ctor_decl cx path c =
  match cx.types path with
  | Some { body = Sum cs; _ } -> (
      match List.find_opt (fun (k : Iface.ctor) -> k.cname = c) cs with
      | Some k -> k.cfields
      | None -> bug "a constructor its type doesn't have")
  | _ -> bug "a constructor of something that isn't a sum type"

(* Whether the constructor [c] of the sum type [path] is by name. *)
and ctor_named cx path c =
  match cx.types path with
  | Some { body = Sum cs; _ } ->
      List.exists (fun (k : Iface.ctor) -> k.cname = c && k.cnamed) cs
  | _ -> false

(* The fields of the record type [path], as it's declared. *)
and record_decl cx path =
  match cx.types path with
  | Some { body = Record fs; _ } -> fs
  | _ -> bug "a record type without fields"

(* The type of the field [f] of [t], a value of the record type [path]. *)
and field_ty cx (t : Ty.ty) path f =
  match t with
  | Variant (_, c, args) -> (
      (* a variant type's fields are its constructor's *)
      match
        List.find_opt (fun (d : Iface.field) -> d.fname = f) (ctor_decl cx path c)
      with
      | Some d -> Ty.apply { tys = args; rows = [] } d.fty
      | None -> bug "a field its constructor doesn't have")
  | Con (_, args) -> (
      match
        List.find_opt (fun (d : Iface.field) -> d.fname = f) (record_decl cx path)
      with
      | Some d -> Ty.apply { tys = args; rows = [] } d.fty
      | None -> bug "a field its record doesn't have")
  | _ -> bug "a field of something that isn't a record"

(* `{ ..base, f: v, ... }` (compiler.md, "Data stage", "Record update"):
   the base, bound first, then each field given, bound in the order
   written, then the record, its fields in declaration order, each the
   one given or the base's. A unique base is built over in place, since
   reuse (reuse.ml) pairs it, dead once its fields are read, with the
   record's allocation. *)
and update cx (e : expr) base fields =
  let loc = e.loc in
  let t = ty_of cx e.node in
  let b = expr cx base in
  let bv = temp cx "base" b.ty in
  let given =
    List.map
      (fun ((f : ident), v) ->
        let v = expr cx v in
        (f.name, temp cx f.name v.ty, v))
      fields
  in
  let bpath =
    match b.ty with
    | Con (p, _) | Variant (p, _, _) -> p
    | _ -> bug "an update of something that isn't a record"
  in
  let field (d : Iface.field) =
    match List.find_opt (fun (f, _, _) -> f = d.fname) given with
    | Some (_, v, _) -> (d.fname, local v loc)
    | None ->
        ( d.fname,
          mk
            (Field (local bv loc, bpath, d.fname))
            (field_ty cx b.ty bpath d.fname)
            loc )
  in
  let bound = (bv, b) :: List.map (fun (_, v, value) -> (v, value)) given in
  match ((node cx e.node).found, t, b.ty) with
  | Some (Ctor_of (path, c)), _, Variant (s, c', _)
    when fields = [] && s = path && c = c' ->
      (* `Placed { ..p }`, of a `p` of its own variant type: the same
         value, as the sum, no code (compiler.md, "Data stage", "Variant
         types") *)
      mk (Of_variant b) t loc
  | Some (Ctor_of (path, c)), _, _ ->
      (* `Placed { ..draft, id }`: the sum, built by the constructor *)
      lets bound
        (mk (Con (path, c, List.map snd (List.map field (ctor_decl cx path c)))) t loc)
  | _, Variant (path, c, _), _ ->
      (* `{ ..p, total: x }`: a value of [p]'s variant type, built by its
         constructor *)
      lets bound
        (mk (Con (path, c, List.map snd (List.map field (ctor_decl cx path c)))) t loc)
  | _, Con (path, _), _ ->
      lets bound
        (mk (Record (path, List.map field (record_decl cx path))) t loc)
  | _ -> bug "an update whose type isn't a record"


(* The locals [e] uses but doesn't bind, in order of id. Every local of a
   function has its own id, so that's every local used, minus every local
   bound. *)
and free (e : C.expr) =
  let used = ref [] and bound = ref Ids.empty in
  let use (v : C.var) = used := v :: !used in
  let bind (v : C.var) = bound := Ids.add v.id !bound in
  let rec go (e : C.expr) =
    match e.kind with
    | Int _ | Float _ | Bool _ | Str _ | Unit | Global_value _ | Break -> ()
    | Global (_, _, ds, dicts) | Intrinsic (_, _, ds, dicts) ->
        (* the hidden type and dictionary parameters its descriptors and
           dictionaries are built from *)
        List.iter use (List.concat_map C.desc_vars ds);
        List.iter use (List.concat_map C.dict_vars dicts)
    | Local v -> use v
    | Prim
        ( (Equal d | Not_equal d | Compare (_, d) | Op (_, d) | Value_of (_, d)),
          args ) ->
        List.iter use (C.dict_vars d);
        List.iter go args
    | Tag (_, args, ds) ->
        List.iter use (List.concat_map C.desc_vars ds);
        List.iter go args
    | Dep_call { ev; args; dargs; _ } ->
        (* evidence is a local like any other: a block captures the
           evidence where it's written, and through `next`, its handler's;
           and so are the descriptors its key is built from *)
        use ev;
        List.iter use (List.concat_map C.desc_vars dargs);
        List.iter go args
    | Prim (_, args) | Array args | Tuple args | Con (_, _, args) ->
        List.iter go args
    | With { ev; outer; impl; desc; dargs; body; _ } ->
        use outer;
        go impl;
        List.iter use (C.desc_vars desc);
        List.iter use (List.concat_map C.desc_vars dargs);
        bind ev;
        go body
    | With_handler { ev; outer; handler; desc; deps; body; _ } ->
        use outer;
        go handler;
        List.iter use (C.desc_vars desc);
        List.iter use (List.concat_map (fun (k, _) -> C.key_vars k) deps);
        bind ev;
        go body
    | Instance { impls; finally; _ } ->
        List.iter (fun (_, i) -> go i) impls;
        Option.iter go finally
    | Handler { captures; _ } -> List.iter use captures
    | Fail a | Narrowed (_, a) | Assert a -> go a
    | Finally (a, b) ->
        go a;
        go b
    | Assert_equal (a, b, d, dict) ->
        go a;
        go b;
        List.iter use (C.desc_vars d);
        List.iter use (C.dict_vars dict)
    | Handle { body; value; on_value; error; on_error } ->
        go body;
        bind value;
        go on_value;
        bind error;
        go on_error
    | Let (v, value, body) ->
        bind v;
        go value;
        go body
    | Covered { body; result; after } ->
        go body;
        bind result;
        go after
    | Assign (v, value) ->
        use v;
        go value
    | If (c, t, f) -> List.iter go [ c; t; f ]
    | Match (s, arms) ->
        go s;
        List.iter
          (fun (a : C.arm) ->
            pat a.pat;
            Option.iter go a.guard;
            go a.body)
          arms
    | While (a, b) | Seq (a, b) | Update (a, _, b) ->
        go a;
        go b
    | Call (f, args, ev) ->
        use ev;
        go f;
        List.iter (function C.Value a -> go a | C.Ref v -> use v) args
    | Lambda { params; ev; captures; _ } ->
        List.iter (fun (p : C.param) -> bind p.var) params;
        bind ev;
        List.iter use captures
    | Record (_, fields) -> List.iter (fun (_, v) -> go v) fields
    | Field (r, _, _) | Of_variant r -> go r
  and pat (p : C.pattern) =
    match p.pkind with
    | PVar v -> bind v
    | PAs (q, v) ->
        pat q;
        bind v
    | PCon (_, _, ps) | PTag (_, ps) | POr ps | PTuple ps | PRecord (_, ps) ->
        List.iter pat ps
    | (PStr_rest _ | PArray _) as k ->
        List.iter pat (C.seq_pieces k);
        List.iter bind (C.seq_rest k)
    | PWild | PInt _ | PBool _ | PStr _ -> ()
  in
  go e;
  List.filter (fun (v : C.var) -> not (Ids.mem v.id !bound)) !used
  |> List.sort_uniq (fun (a : C.var) (b : C.var) -> compare a.id b.id)

(* ---- top-level functions ---- *)

(* The largest binder id in a function, so temporaries can be numbered
   after its own locals. *)
let max_binder (f : fn_def) =
  let m = ref 0 in
  let see (b : binder) = m := max !m b.id in
  let rec go (e : expr) =
    match e.kind with
    | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break | Todo | Tag_set _
    | Piped ->
        ()
    | Interp ps -> List.iter go (Ast.holes ps)
    | Unop (_, a, _)
    | Field (a, _)
    | Ref a
    | Try a
    | Attempt a
    | Release a
    | Assert a
    | Named (_, a)
    | Inline_handler a ->
        go a
    | Pipe { subject = a; step = b }
    | Binop (_, a, b, _)
    | Index (a, b)
    | Assign { target = a; value = b; _ }
    | While { cond = a; body = b } ->
        go a;
        go b
    | Slice (a, lo, hi) -> List.iter go [ a; lo; hi ]
    | Fail (_, args) -> List.iter (fun (_, a) -> go a) args
    | If (c, t, f) -> List.iter go (c :: t :: Option.to_list f)
    | Call (f, args) -> List.iter go (f :: args)
    | Lambda (ps, body) ->
        List.iter (fun (p : Resolved.param) -> see p.pname) ps;
        go body
    | Block (stmts, last) ->
        List.iter stmt stmts;
        go last
    | Con (_, args) -> List.iter (fun (_, a) -> go a) args
    | Record (_, fields) | Con_named (_, fields) ->
        List.iter (fun (_, v) -> go v) fields
    | Update { base; fields; _ } ->
        go base;
        List.iter (fun (_, v) -> go v) fields
    | Match (s, arms) ->
        go s;
        List.iter
          (fun (a : arm) ->
            pat a.arm_pat;
            Option.iter go a.arm_guard;
            go a.arm_body)
          arms
    | Array xs | Tuple xs -> List.iter go xs
    | For { index; pat = p; _ } ->
        Option.iter pat index;
        pat p;
        List.iter go (Ast.children e)
    | With { items; body } ->
        List.iter go (with_links items);
        go body
    | Handler { state; arms; _ } ->
        List.iter stmt state;
        List.iter (fun (a : handler_arm) -> go a.arm_impl) arms
  and stmt = function
    | Let { name; value; _ } ->
        see name;
        go value
    | Let_pattern { pat = p; value; else_ } ->
        pat p;
        go value;
        Option.iter go else_
    | Expr e | Finally e -> go e
  and pat (p : pattern) =
    match p.pkind with
    | PVar b -> see b
    | PAs (q, b) ->
        pat q;
        see b
    | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps -> List.iter pat ps
    | PRecord (_, fs) | PCon_named (_, fs) -> List.iter (fun (_, q) -> pat q) fs.fpats
    | PSeq q ->
        List.iter pat (Ast.seq_pieces q);
        Option.iter (fun (r : _ Ast.rest) -> Option.iter see r.rname) q.middle
    | PWild | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> ()
  in
  List.iter (fun (p : Resolved.param) -> see p.pname) f.params;
  go f.body;
  !m

(* [f], lowered; or made for [made], what a use of it asked for. What
   it uses that's made for a request, it adds to [requests], and each
   method call on a description it has, to [calls]. *)
let fn_def ~home ~types ~through ~requests ~calls ?made (inferred : Infer.t) (f : fn_def) :
    C.fn_def =
  let path = Ast.fn_path home f in
  let scheme = Path.Map.find path inferred.schemes in
  let nodes = Path.Map.find path inferred.nodes in
  let next = max_binder f + 1 in
  (* what its types become, and its parameters of `Tags` *)
  let subst, scheme, tags, suffix =
    match (made, f.body.kind) with
    | None, _ -> (same_subst, scheme, [], "")
    | ( Some (Any_for (_, d)),
        Handler { deps = [ { dep = { tref = Param _; _ }; _ } ]; _ } ) ->
        (* a handler `for D`: [D], its variable [kd], is an implementation
           of [d], at type arguments that are the function's last
           variables, needing and failing to start with what its last two
           rows stand for; its other variables after [kd] move down one *)
        let kd =
          match scheme.ty with
          | Fun (_, Impl { deps = [ { dpath; dargs = [ Var k ] } ]; _ }, _, _)
            when dpath = Ty.param_path ->
              k
          | _ -> bug "a handler `for D` whose type doesn't list `D`"
        in
        let own = Ty.own_args scheme.ty in
        let n = List.length own.tys and r = List.length own.rows in
        let m =
          match types d with
          | Some (decl : Iface.type_decl) -> List.length decl.params
          | None -> bug "a handler `for D` made for what isn't a type"
        in
        let impl : Ty.ty =
          Impl
            {
              deps = [ { dpath = d; dargs = List.init m (fun i -> Ty.Var (n - 1 + i)) } ];
              over = false;
              needs = { labels = []; tail = Some r };
              fails = { labels = []; tail = Some (r + 1) };
            }
        in
        let moved k = if k > kd then k - 1 else k in
        let subst =
          {
            same_subst with
            var = (fun k -> if k = kd then impl else Var (moved k));
          }
        in
        let vars xs =
          List.filter_map (fun (k, x) -> if k = kd then None else Some (moved k, x)) xs
        in
        ( subst,
          {
            scheme with
            ty = subst_ty subst scheme.ty;
            names = vars scheme.names;
            reqs = vars scheme.reqs;
          },
          [],
          "$" ^ Path.full d )
    | Some (Any_for (_, d)), _ ->
        (* the dependency's type parameters are the function's, after
           its own *)
        let n = List.length (Ty.own_args scheme.ty).tys in
        let m =
          match types d with
          | Some (decl : Iface.type_decl) -> List.length decl.params
          | None -> bug "a handler `over any` made for what isn't a type"
        in
        let dep : Ty.dep = { dpath = d; dargs = List.init m (fun i -> Ty.Var (n + i)) } in
        let subst =
          {
            same_subst with
            var = (fun k -> if k < n then Var k else Var (k + m));
            dep = Some dep;
          }
        in
        ( subst,
          { scheme with ty = subst_ty subst scheme.ty },
          [],
          "$" ^ Path.full d )
    | Some (Tags_for (_, sets)), _ ->
        let ps =
          match scheme.ty with Fun (ps, _, _, _) -> ps | _ -> []
        in
        let given = ref sets in
        let tags =
          List.concat
            (List.map2
               (fun (p : Resolved.param) (t : Ty.param) ->
                 if is_tags t.ty then (
                   let names = List.hd !given in
                   given := List.tl !given;
                   [ (p.pname.id, names) ])
                 else [])
               f.params ps)
        in
        let ty : Ty.ty =
          match scheme.ty with
          | Fun (ps, r, e, u) ->
              Fun (List.filter (fun (p : Ty.param) -> not (is_tags p.ty)) ps, r, e, u)
          | t -> t
        in
        ( same_subst,
          { scheme with ty },
          tags,
          "$" ^ String.concat ";" (List.map (String.concat "|") sets) )
  in
  let cx =
    {
      nodes;
      subst;
      shift = 0;
      shifted = Ids.empty;
      call = None;
      case = None;
      cells = [];
      tags;
      suffix;
      requests;
      calls;
      types;
      opaque = inferred.opaque;
      through;
      vars = Hashtbl.create 16;
      next = next + 1;
      ev = C.evidence next;
      handler_ev = None;
      handler_deps = [];
      self = path;
      tys = C.type_params scheme;
      dicts = List.combine scheme.reqs (C.dict_params scheme);
    }
  in
  let ps =
    match scheme.ty with
    | Fun (ps, _, _, _) -> ps
    | _ -> bug "a function whose type isn't a function"
  in
  let own =
    List.filter
      (fun (p : Resolved.param) -> not (List.mem_assoc p.pname.id tags))
      f.params
  in
  let params =
    List.map2
      (fun (p : Resolved.param) (t : Ty.param) : C.param ->
        { mode = p.pmode; var = bind cx p.pname t.ty })
      own ps
  in
  {
    path = (match made with Some req -> made_path req | None -> path);
    params;
    ev = cx.ev;
    tys = cx.tys;
    dicts = List.map snd cx.dicts;
    scheme;
    body = expr cx f.body;
    test = f.test;
    loc = f.name.loc;
    origin = Written;
    known = [];
  }

(* Whether [f] is made for each request rather than lowered as it's
   written: a handler `over any`, or a function with a parameter of
   `Tags`. *)
let made_for_requests (inferred : Infer.t) path (f : fn_def) =
  (match f.body.kind with
  | Handler { any = true; _ } -> true
  (* a handler `for D`, made for each dependency it's given *)
  | Handler { deps = [ { dep = { tref = Param _; _ }; _ } ]; _ } -> true
  | _ -> false)
  ||
  match Path.Map.find_opt path inferred.schemes with
  | Some { ty = Fun (ps, _, _, _); _ } ->
      List.exists (fun (p : Ty.param) -> is_tags p.ty) ps
  | _ -> false

(* The types among [types] that show their values through their own
   `show` method (shown.ml), each with its function, one of [fns]: a
   method that takes only its `self`, of the type with its parameters in
   order, and gives a `Str` without failing or using a dependency. Decided
   here, once, so the interpreter never looks for a member by its name. *)
let shows (types : Iface.type_decl list) (fns : C.fn_def list) =
  List.filter_map
    (fun (d : Iface.type_decl) ->
      let own = List.init (List.length d.params) (fun n -> Ty.Var n) in
      match Iface.find_member d "show" with
      | Some
          {
            okind = Method;
            oscheme =
              { ty = Fun ([ { ty = Con (p, args); _ } ], ret, errs, uses); _ };
            _;
          }
        when p = d.path && args = own && ret = Ty.str && errs.labels = []
             && uses.labels = [] ->
          let m = Path.member d.path "show" in
          if List.exists (fun (f : C.fn_def) -> f.path = m) fns then
            Some (d.path, m)
          else None
      | _ -> None)
    types

(* The types among [types] that have a `key` (Iface.key), each with its
   function, one of [fns]: what the interpreter equals, hashes and orders
   their values by (walk.ml). *)
let keys (types : Iface.type_decl list) (fns : C.fn_def list) =
  List.filter_map
    (fun (d : Iface.type_decl) ->
      match Iface.key d with
      | Some (m, _) when List.exists (fun (f : C.fn_def) -> f.path = m) fns ->
          Some (d.path, m)
      | _ -> None)
    types

(* The types among [types] that have an operator or an associated value
   for a requirement, `add` or `zero`, through a member of their own
   (Iface.provider), each with that member: what a dictionary for the
   requirement calls, or is. *)
let ops (types : Iface.type_decl list) =
  List.concat_map
    (fun (d : Iface.type_decl) ->
      List.filter_map
        (fun req ->
          match Iface.provider d req with
          (* a built-in member, `Bytes.add`, isn't a function of the
             program's *)
          | Some (m, _) when Prelude.find m = None -> Some ((d.path, req), m)
          | _ -> None)
        Iface.requirements)
    types

let program ~types (r : Resolve.t) (inferred : Infer.t) =
  let requests = ref [] and calls = ref [] in
  let fns =
    List.filter_map
      (fun f ->
        if made_for_requests inferred (Ast.fn_path r.home f) f then None
        else Some (fn_def ~home:r.home ~types ~through:r.through ~requests ~calls inferred f))
      (Ast.functions r.prog)
  in
  (* the indices its loops keep in bounds, marked so (bounds.ml) *)
  let fns =
    List.map Bounds.mark fns
  in
  ( ({
       home = r.home;
       types = r.types;
       fns;
       values = inferred.values;
       shows = shows r.types fns;
       keys = keys r.types fns;
       ops = ops r.types;
       method_calls = !calls;
     }
      : C.program),
    List.rev !requests )

(* The function [req] asks for, made in the module that declares the
   function it's made of, [r], what it uses that's made for a request in
   turn, and the method calls on descriptions it has (Core.program). *)
let made ~types (r : Resolve.t) (inferred : Infer.t) req =
  let p = match req with Any_for (p, _) | Tags_for (p, _) -> p in
  match
    List.find_opt (fun f -> Ast.fn_path r.home f = p) (Ast.functions r.prog)
  with
  | Some f ->
      let requests = ref [] and calls = ref [] in
      let fn = fn_def ~home:r.home ~types ~through:r.through ~requests ~calls ~made:req inferred f in
      (Bounds.mark fn, List.rev !requests, !calls)
  | None -> bug ("a request of `" ^ Path.local p ^ "`, which isn't there")

(* ---- starting ---- *)

let start_name = "$start"

(* The built-in dependencies [main] uses, in its row's order: what the
   runtime installs around it, `$start` here, and the recorders or the
   replayer, by a journal's header, which the driver writes from this. *)
let main_uses (main : C.fn_def) =
  match main.scheme.ty with
  | Fun (_, _, _, uses) ->
      List.map (fun (l : Ty.label) -> Ty.dep_path l.name) uses.labels
  | _ -> bug "a `main` whose type isn't a function's"

(* What the runtime runs: `$start`, which installs the real implementation
   of each built-in dependency [main] uses, the first in its row
   outermost, and calls it. The type checker made sure it uses no other
   (infer_top.ml, [check_main]). It starts from no evidence at all. *)
let start (main : C.fn_def) : C.fn_def =
  let loc = main.loc in
  (* A `main` that never gives a value, `fn main() = todo`, is generic in
     the one it would give, `fn main<T>() -> T`: `$start` calls it at
     `Unit`, so that what the runtime runs isn't generic. *)
  let own = Ty.own_args main.scheme.ty in
  let own =
    if main.scheme.reqs = [] then
      { own with tys = List.map (fun _ -> Ty.unit) own.tys }
    else own
  in
  let ret, errs =
    match Ty.apply own main.scheme.ty with
    | Fun (_, ret, errs, _) -> (ret, errs)
    | _ -> bug "a `main` whose type isn't a function's"
  in
  let deps = main_uses main in
  let scheme =
    let names = if main.scheme.reqs = [] then [] else main.scheme.names in
    { main.scheme with ty = Fun ([], ret, errs, Ty.closed); names }
  in
  let tys = C.type_params scheme in
  let dicts = C.dict_params scheme in
  (* each install's evidence is numbered after the one it extends *)
  let rec install n = function
    | [] ->
        mk
          (Call
             ( mk
                 (Global
                    ( main.path,
                      own,
                      List.map (C.describe tys) own.tys,
                      List.map (fun v -> C.Dict_param v) dicts ))
                 (Ty.apply own main.scheme.ty) loc,
               [],
               C.evidence n ))
          ret loc
    | (dep : Path.t) :: rest ->
        let real = Path.member dep "real" in
        mk
          (With
             {
               ev = C.evidence (n + 1);
               outer = C.evidence n;
               dep;
               dargs = [];
               from = dep;
               (* of a type with no variables *)
               impl =
                 mk
                   (Global_value (real, { tys = []; rows = [] }))
                   (Ty.impl [ Ty.plain dep ] Ty.closed)
                   loc;
               desc = C.describe tys ret;
               body = install (n + 1) rest;
             })
          ret loc
  in
  {
    path = Path.make main.path.home start_name;
    params = [];
    ev = C.evidence 1;
    tys;
    dicts;
    scheme;
    body = install 1 deps;
    test = false;
    loc;
    origin = Written;
    known = [];
  }
