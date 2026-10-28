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

(* What lowering one top-level function needs. *)
type cx = {
  nodes : Infer.node Infer.Nodes.t;  (** what inference found, by node id *)
  vars : (int, C.var) Hashtbl.t;  (** each local, by binder id *)
  mutable next : int;  (** the id of the next temporary *)
  mutable ev : C.var;
      (** the evidence in scope: the function's, or the lambda's whose body is
          being lowered *)
  mutable handler_ev : C.var option;
      (** in a handler, its evidence, where it was installed, which `next` finds
          the implementation it's over in *)
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
  | Some n -> n
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
  | Some (Block { name; given }) -> (name, given)
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

(* Whether inference found [id] to be a `match` with `fail` arms, or a
   `fail` arm's pattern (Infer.found). *)
let handles cx id = (node cx id).found = Some Handles
let is_fail cx id = (node cx id).found = Some Fail_arm

(* A local, when it's bound: it takes the binder's id and name. *)
let bind cx (b : binder) ty =
  let v : C.var = { id = b.id; name = b.ident.name; ty } in
  Hashtbl.replace cx.vars b.id v;
  v

let var_of cx (b : binder) =
  match Hashtbl.find_opt cx.vars b.id with
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

type place = { root : C.var; steps : step list }

(* A call's argument, lowered: a value, or a place passed with `&`, with
   the temporaries holding its indices. *)
type arg =
  | Read of C.expr
  | Inout of {
      binds : (C.var * C.expr) list;
      place : place;
      ty : Ty.ty;
      loc : Loc.t;
    }

(* The value at the end of the steps, starting from [base]. *)
let rec read_from (base : C.expr) steps =
  match steps with
  | [] -> base
  | SField (p, f, ty, loc) :: rest ->
      read_from (mk (Field (base, p, f)) ty loc) rest
  | SIndex (i, ty, loc) :: rest ->
      read_from (mk (Prim (Get_index Checked, [ base; i ])) ty loc) rest

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

(* Write [v] to the place. *)
let write pl (v : C.expr) loc =
  mk (Assign (pl.root, update (local pl.root loc) pl.steps v)) Ty.unit loc

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
  | Call (f, args) -> call cx e f args
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
      | Some (Ctor_of (p, c)) ->
          (* ctor_shape (infer_lookup.ml) made sure the arguments are in the
             order of the fields *)
          here (Con (p, c, List.map (fun (_, a) -> expr cx a) args))
      | _ -> bug "a constructor inference didn't find")
  | Record (_, fields) -> (
      match ty () with
      | Con (p, _) ->
          here
            (Record
               (p, List.map (fun ((f : ident), v) -> (f.name, expr cx v)) fields))
      | _ -> bug "a record literal whose type isn't a record")
  | Field (r, f) -> (
      match (node cx e.node).found with
      | Some (Field_of p) -> here (Field (expr cx r, p, f.name))
      | _ -> bug "a field inference didn't find")
  | Match (subject, arms) when handles cx e.node ->
      handle_match cx ~passed:false (ty ()) e.loc subject arms
  | Match (subject, arms) ->
      let subject = expr cx subject in
      here (Match (subject, List.map (arm cx) arms))
  | Array xs -> here (Array (List.map (expr cx) xs))
  | Tuple xs -> here (Tuple (List.map (expr cx) xs))
  | Index (a, i) ->
      let a = expr cx a in
      here (Prim (Get_index Checked, [ a; expr cx i ]))
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
        mk (Instance { impls = [ (dep, impl) ]; finally = None }) (ty ()) e.loc
      in
      let captures =
        List.filter (fun (v : C.var) -> v.id <> ev.id) (free body)
      in
      here (Handler { ev; captures; body })

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
  let forwards, body_ty =
    match (node cx e.node).found with
    | Some (Handler_facts { forwards; body_ty }) -> (forwards, body_ty)
    | _ -> ([], None)
  in
  let finallies =
    List.filter_map (function Finally f -> Some f | _ -> None) state
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
    | Let_tuple { pat; value } :: rest ->
        take_apart cx pat (expr cx value) (fun () -> state_lets rest)
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
          | Let _ | Let_tuple _ | Expr _ | Finally _ -> None)
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
      (p, mk (Record (p, ops @ forwarded)) (Ty.impl [ own ] needs) e.loc)
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
    lets made
      (mk
         (Instance { impls = List.map impl deps; finally })
         (ty_of cx e.node) e.loc)
  in
  state_lets state

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
and arm_impl cx cells (impl : expr) = with_cells cx cells (expr cx impl)

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
        | ws when C.can_fail body ->
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

and arm cx (a : arm) : C.arm =
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
    mk (Match (local error loc, List.map (arm cx) fails @ rest)) ty loc
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
and call cx ?(changed = false) (e : expr) f args =
  match f.kind with
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
  | Field (r, _) -> (
      match (node cx f.node).found with
      | Some (Calls_op { key; from; op }) -> desc_method cx e r key from op args
      | _ -> plain_call cx ~changed e f args)
  | _ -> plain_call cx ~changed e f args

(* `d.op(args)`, [e]: `with d in Dep.op(args)`, the description [r] and
   the arguments evaluated first, in order, outside (foundations.md,
   decision 3). [key] is what it's installed as, implementing [from]. *)
and desc_method cx (e : expr) (r : expr) key from op args =
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

and plain_call cx ~changed (e : expr) f args =
  let inout (p : expr) ty =
    let binds, pl = place cx p in
    Inout { binds; place = pl; ty; loc = p.loc }
  in
  let f, receiver =
    match (f.kind, (node cx f.node).found) with
    | Field (r, _), Some (Method_of p) ->
        let recv =
          if changed then inout r (ty_of cx r.node) else Read (expr cx r)
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
          | Ref p when changed_receiver a = None -> inout p (ty_of cx a.node)
          | _ -> Read (expr cx a))
        args
  in
  let ty = ty_of cx e.node in
  let direct = function
    | Read a -> Some (C.Value a)
    | Inout { binds = []; place = { root; steps = [] }; _ } -> Some (C.Ref root)
    | Inout _ -> None
  in
  if List.for_all (fun a -> direct a <> None) lowered then
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
          | Inout r ->
              let t = temp cx "ref" r.ty in
              ( binds @ r.binds @ [ (t, read r.place r.loc) ],
                args @ [ C.Ref t ],
                writes @ [ write r.place (local t r.loc) r.loc ] ))
        (hold_f, [], []) lowered
    in
    let call = mk (Call (f, args, cx.ev)) ty e.loc in
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
  | Let_tuple { pat; value } :: rest ->
      let value = expr cx value in
      take_apart cx pat value (fun () -> block cx rest last)
  | Expr e :: rest ->
      let e = expr cx e in
      seq e (block cx rest last)
  | Finally f :: rest ->
      (* in an arm: it's given what the rest of it ends in *)
      let rt =
        match ty_of cx f.node with
        | Fun ([ r ], _, _, _) -> r.ty
        | _ -> bug "a `finally` whose type isn't a function's"
      in
      finally_body cx f (attempted cx (block cx rest last) rt)

(* [body ()] with [pat], a name or a tuple of them (the parser sees to
   that), bound to [value]: a [Let], or a [match] of one arm, which always
   matches. *)
and take_apart cx (pat : pattern) (value : C.expr) body =
  match pat.pkind with
  | PVar b ->
      let v = bind cx b value.ty in
      let body = body () in
      mk (Let (v, value, body)) body.ty value.loc
  | _ ->
      let pat = pattern cx pat in
      let body = body () in
      mk (Match (value, [ { pat; guard = None; body } ])) body.ty value.loc

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
  match (node cx iter.node).found with
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
  | Ref p, PVar b ->
      let binds, pl = place cx p in
      let at =
        { pl with steps = pl.steps @ [ SIndex (index, elem, iter.loc) ] }
      in
      let x = bind cx b elem in
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
      lets binds (loop ~start:(read pl iter.loc) ~pass:(numbered pass))
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
   `None`: a [While] that [Break]s then. `c` keeps its place after the
   loop, a `break` included. `for x in c` goes over a copy, in a
   temporary. *)
and cursor_loop cx (e : expr) (pat : pattern) (iter : expr) next body =
  let loc = e.loc in
  let cursor = ty_of cx iter.node in
  let elem = ty_of cx pat.pnode in
  let opt : Ty.ty = Con (option_path, [ elem ]) in
  let fty : Ty.ty =
    Fun ([ { mode = Inout; ty = cursor } ], opt, Ty.closed, Ty.closed)
  in
  let a = targs_of cx iter.node in
  let callee : C.kind =
    match Prelude.find next with
    | Some x -> Intrinsic (x, a, descs cx a, dicts_of cx iter.node)
    | None -> Global (next, a, descs cx a, dicts_of cx iter.node)
  in
  let call (v : C.var) =
    mk (Call (mk callee fty iter.loc, [ Ref v ], cx.ev)) opt iter.loc
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
    | POr ps -> POr (List.map (pattern cx) ps)
    | PTuple ps -> PTuple (List.map (pattern cx) ps)
  in
  { pkind; pty; ploc = p.ploc }

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
    | Instance { impls; finally } ->
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
    | Field (r, _, _) -> go r
  and pat (p : C.pattern) =
    match p.pkind with
    | PVar v -> bind v
    | PCon (_, _, ps) | PTag (_, ps) | POr ps | PTuple ps -> List.iter pat ps
    | PWild | PInt _ | PBool _ -> ()
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
    | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break -> ()
    | Unop (_, a, _)
    | Field (a, _)
    | Ref a
    | Try a
    | Attempt a
    | Assert a
    | Inline_handler a ->
        go a
    | Binop (_, a, b, _)
    | Index (a, b)
    | Assign { target = a; value = b; _ }
    | While { cond = a; body = b } ->
        go a;
        go b
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
    | Record (_, fields) -> List.iter (fun (_, v) -> go v) fields
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
    | Let_tuple { pat = p; value } ->
        pat p;
        go value
    | Expr e | Finally e -> go e
  and pat (p : pattern) =
    match p.pkind with
    | PVar b -> see b
    | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps -> List.iter pat ps
    | PWild | PInt _ | PBool _ | PFail_any -> ()
  in
  List.iter (fun (p : Resolved.param) -> see p.pname) f.params;
  go f.body;
  !m

let fn_def ~home (inferred : Infer.t) (f : fn_def) : C.fn_def =
  let path = Ast.fn_path home f in
  let scheme = Path.Map.find path inferred.schemes in
  let next = max_binder f + 1 in
  let cx =
    {
      nodes = Path.Map.find path inferred.nodes;
      vars = Hashtbl.create 16;
      next = next + 1;
      ev = C.evidence next;
      handler_ev = None;
      handler_deps = [];
      tys = C.type_params scheme;
      dicts = List.combine scheme.reqs (C.dict_params scheme);
    }
  in
  let ps =
    match scheme.ty with
    | Fun (ps, _, _, _) -> ps
    | _ -> bug "a function whose type isn't a function"
  in
  let params =
    List.map2
      (fun (p : Resolved.param) (t : Ty.param) : C.param ->
        { mode = p.pmode; var = bind cx p.pname t.ty })
      f.params ps
  in
  {
    path;
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
          Option.map (fun (m, _) -> ((d.path, req), m)) (Iface.provider d req))
        Iface.requirements)
    types

let program (r : Resolve.t) (inferred : Infer.t) : C.program =
  let fns = List.map (fn_def ~home:r.home inferred) (Ast.functions r.prog) in
  (* the indices its loops keep in bounds, marked so (bounds.ml) *)
  let fns =
    List.map Bounds.mark fns
  in
  {
    home = r.home;
    types = r.types;
    fns;
    values = inferred.values;
    shows = shows r.types fns;
    keys = keys r.types fns;
    ops = ops r.types;
  }

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
  let ret, errs =
    match main.scheme.ty with
    | Fun (_, ret, errs, _) -> (ret, errs)
    | _ -> bug "a `main` whose type isn't a function's"
  in
  let deps = main_uses main in
  let scheme = { main.scheme with ty = Fun ([], ret, errs, Ty.closed) } in
  let tys = C.type_params scheme in
  let dicts = C.dict_params scheme in
  (* each install's evidence is numbered after the one it extends *)
  let rec install n = function
    | [] ->
        let own = Ty.own_args main.scheme.ty in
        mk
          (Call
             ( mk
                 (Global
                    ( main.path,
                      own,
                      List.map (C.describe tys) own.tys,
                      List.map (fun v -> C.Dict_param v) dicts ))
                 main.scheme.ty loc,
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
