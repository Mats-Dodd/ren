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
     the second writes each element back after each pass
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

   And the evidence (core.ml) is threaded: each function and lambda takes
   its own, each call passes the one in scope, and a call of an
   operation, `Clock.now()`, is a [Dep_call] on it. An operation used as a
   value, `let write = Console.write`, is a lambda that calls it. *)

open Ast
open Ast.Resolved
module C = Core

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
}

let node cx id =
  match Infer.Nodes.find_opt id cx.nodes with
  | Some n -> n
  | None -> bug (Printf.sprintf "no type for node %d" id)

let ty_of cx id = (node cx id).ty

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
  | Int _ | Bool _ | Unit | Global _ | Global_value _ | Intrinsic _ -> true
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
      read_from (mk (Prim (Get_index, [ base; i ])) ty loc) rest

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
      let inner = update (mk (Prim (Get_index, [ base; i ])) ty loc) rest v in
      mk (Prim (Set_index, [ base; i; inner ])) base.ty loc

(* Write [v] to the place. *)
let write pl (v : C.expr) loc =
  mk (Assign (pl.root, update (local pl.root loc) pl.steps v)) Ty.unit loc

(* ---- expressions ---- *)

let is_result : Ty.ty -> bool = function
  | Con (p, _) -> p = Path.prelude "Result"
  | _ -> false

let result_path = Path.prelude "Result"
let option_path = Path.prelude "Option"
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

(* [e], lowered: taken as one dependency's, if it's a handler of several
   where a value of one of their types is wanted (Infer.node, [as_dep]). *)
let rec expr cx (e : expr) : C.expr =
  let x = expr_of cx e in
  match ((node cx e.node).as_dep, x.ty) with
  | Some d, Con (_, [ needs ]) -> mk (As_dep (d, x)) (Con (d, [ needs ])) e.loc
  | Some _, _ -> bug "a handler taken as one dependency's isn't a handler"
  | None, _ -> x

and expr_of cx (e : expr) : C.expr =
  let ty () = ty_of cx e.node in
  let here kind = mk kind (ty ()) e.loc in
  match e.kind with
  | Int n -> here (Int n)
  | Bool b -> here (Bool b)
  | Str s -> here (Str s)
  | Unit -> here Unit
  | Var (Local b) -> local (var_of cx b) e.loc
  | Var (Global p) -> here (Global p)
  | Var (Global_value p) -> here (Global_value p)
  | Var (Intrinsic x) -> here (Intrinsic x)
  | Var (Dep_op (dep, op)) -> (
      (* used as a value: a lambda that calls it, with the evidence it's
         given where it's called *)
      match ty () with
      | Fun (ps, ret, _, _) as fty ->
          let params = List.map (fun (p : Ty.param) -> temp cx "x" p.ty) ps in
          let ev = evidence cx in
          let args = List.map (fun v -> local v e.loc) params in
          here
            (Lambda
               {
                 params =
                   List.map (fun var : C.param -> { mode = Read; var }) params;
                 ev;
                 captures = [];
                 body = mk (Dep_call { dep; op; fty; ev; args }) ret e.loc;
               })
      | _ -> bug "an operation whose type isn't a function's")
  | Unop (Neg, a) -> here (Prim (Neg, [ expr cx a ]))
  | Unop (Not, a) -> here (Prim (Not, [ expr cx a ]))
  (* `a && b` is `if a then b else false`, and `a || b` is
     `if a then true else b`: [b] runs only when [a] doesn't decide *)
  | Binop (And, a, b) ->
      let a = expr cx a in
      here (If (a, expr cx b, mk (Bool false) Ty.bool e.loc))
  | Binop (Or, a, b) ->
      let a = expr cx a in
      here (If (a, mk (Bool true) Ty.bool e.loc, expr cx b))
  | Binop (Orelse, a, b) ->
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
      here (Fail (mk (Tag (tag.name, args)) (Errors set) e.loc))
  | Try ({ kind = Match (subject, arms); _ } as m) when Infer_expr.handles arms
    ->
      handle_match cx ~passed:true (ty_of cx m.node) e.loc subject arms
  | Try a when is_result (ty_of cx a.node) ->
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
  | Assert ({ kind = Binop (Eq, a, b); _ } as cmp) ->
      (* both sides, so a failure can show them, and where the comparison
         is, which it points at *)
      let a = expr cx a in
      mk (Assert_equal (a, expr cx b)) Ty.unit cmp.loc
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
  | Binop (op, a, b) ->
      let a = expr cx a in
      here (Prim (Binop op, [ a; expr cx b ]))
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
      (* its body sees its own evidence, never the one where it's made *)
      let ev = evidence cx and outer = cx.ev in
      cx.ev <- ev;
      let body = expr cx body in
      cx.ev <- outer;
      let own = List.map (fun (p : C.param) -> p.var.id) params in
      let captures =
        List.filter (fun (v : C.var) -> not (List.mem v.id own)) (free body)
      in
      here (Lambda { params; ev; captures; body })
  | Block (stmts, last) -> block cx stmts last
  | Con (tag, args) -> (
      match ((node cx e.node).found, ty ()) with
      | None, Errors _ ->
          (* a tag, inside `Err(...)`: the error it holds *)
          here (Tag (tag.name.name, List.map (fun (_, a) -> expr cx a) args))
      | Some (Ctor_of (p, c)), _ ->
          (* ctor_shape (infer_expr.ml) made sure the arguments are in the
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
  | Match (subject, arms) when Infer_expr.handles arms ->
      handle_match cx ~passed:false (ty ()) e.loc subject arms
  | Match (subject, arms) ->
      let subject = expr cx subject in
      here (Match (subject, List.map (arm cx) arms))
  | Array xs -> here (Array (List.map (expr cx) xs))
  | Index (a, i) ->
      let a = expr cx a in
      here (Prim (Get_index, [ a; expr cx i ]))
  | Ref ({ kind = Call (f, args); _ } as c) -> call cx ~changed:true c f args
  | Ref _ -> bug "`&` outside a call or a `for` loop"
  | Assign { target; op; value } -> assign cx e target op value
  | For { var; iter; body } -> for_loop cx e var iter body
  | With { item; body; lam } -> (
      (* the body sees evidence of its own: the [With]'s, which extends
         what's installed around it, or the lambda's, which a wrapper
         passes the evidence it's called with *)
      let inner () =
        let ev = evidence cx and outer = cx.ev in
        cx.ev <- ev;
        let body = expr cx body in
        cx.ev <- outer;
        (ev, outer, body)
      in
      match (node cx e.node).found with
      | Some (Installs dep) ->
          let impl = expr cx item in
          let ev, outer, body = inner () in
          here (With { ev; outer; dep; impl; body })
      | Some (Installs_handler deps) ->
          let handler = expr cx item in
          let ev, outer, body = inner () in
          here (With_handler { ev; outer; handler; deps; body })
      | Some Wraps -> (
          (* `with retry(3) in body` is `retry(3, fn() => body)` *)
          let ev, _, b = inner () in
          let lam =
            mk
              (Lambda { params = []; ev; captures = free b; body = b })
              (ty_of cx lam) body.loc
          in
          match item.kind with
          | Call (f, args) -> plain_call cx ~changed:false ~last:lam item f args
          | _ ->
              let f = expr cx item in
              here (Call (f, [ Value lam ], cx.ev)))
      | _ -> bug "a `with` inference didn't say the kind of")
  | Handler { deps; state; arms; _ } ->
      (* it runs where it's installed, with the evidence there *)
      let ev = evidence cx and outer = cx.ev in
      cx.ev <- ev;
      let body = handler cx e deps state arms in
      cx.ev <- outer;
      here (Handler { ev; captures = free body; body })

(* A handler's body, which makes an instance: its state, each `var` then
   put in a cell, and an implementation of each of [deps], a record of its
   arms. An arm is a lambda that keeps the cells, not the `var`s: it reads
   each `var` it uses from its cell when it starts, and writes back each
   one it changes when it ends, even if it fails. Nothing else changes a
   cell in between: an arm runs with what was installed outside its
   handler's `with`, which isn't the instance it's part of, so it never
   runs inside another arm of the same instance. *)
and handler cx (e : expr) deps state arms =
  let needs =
    match ty_of cx e.node with
    | Con (_, [ needs ]) -> needs
    | _ -> bug "a handler whose type isn't a handler's"
  in
  let rec state_lets = function
    | [] -> instance ()
    | Let { name; value; _ } :: rest ->
        let value = expr cx value in
        let v = bind cx name value.ty in
        let body = state_lets rest in
        mk (Let (v, value, body)) body.ty value.loc
    | Expr s :: rest -> seq (expr cx s) (state_lets rest)
  and instance () =
    let cells =
      List.filter_map
        (function
          | Let { name; mut = true; _ } ->
              let v = var_of cx name in
              Some (v, temp cx v.name (C.cell_ty v.ty))
          | Let _ | Expr _ -> None)
        state
    in
    let impl (d : tname) : Path.t * C.expr =
      let p =
        match d.tref with
        | Named p -> p
        | Param _ -> bug "a type parameter after `for`"
      in
      let ops =
        List.filter_map
          (fun (a : handler_arm) ->
            match a.arm_op with
            | Dep_op (q, op) when q = p -> Some (op, arm_impl cx cells a)
            | _ -> None)
          arms
      in
      (p, mk (Record (p, ops)) (Con (p, [ needs ])) e.loc)
    in
    let made =
      List.map
        (fun ((v : C.var), (c : C.var)) ->
          (c, mk (Prim (New_cell, [ local v e.loc ])) c.ty e.loc))
        cells
    in
    lets made (mk (Instance (List.map impl deps)) (ty_of cx e.node) e.loc)
  in
  state_lets state

(* An arm of a handler, which keeps [cells], the state's `var`s' cells. *)
and arm_impl cx cells (a : handler_arm) =
  let lam = expr cx a.arm_impl in
  match lam.kind with
  | Lambda { params; ev; captures; body } ->
      let loc = a.arm_impl.loc in
      let used =
        List.filter
          (fun ((v : C.var), _) ->
            List.exists (fun (w : C.var) -> w.id = v.id) captures)
          cells
      in
      let changed = assigned body in
      let writes =
        List.filter_map
          (fun ((v : C.var), (c : C.var)) ->
            if List.mem v.id changed then
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
      let own = List.map (fun (p : C.param) -> p.var.id) params in
      let captures =
        List.filter (fun (v : C.var) -> not (List.mem v.id own)) (free body)
      in
      { lam with kind = Lambda { params; ev; captures; body } }
  | _ -> bug "a handler's arm that isn't a lambda"

(* The locals [e] changes: those it assigns to, and those it passes to a
   call with `&`, which the call writes back to. *)
and assigned (e : C.expr) =
  let own =
    match e.kind with
    | Assign (v, _) -> [ v.id ]
    | Call (_, args, _) ->
        List.filter_map (function C.Ref v -> Some v.id | Value _ -> None) args
    | _ -> []
  in
  own @ List.concat_map assigned (C.children e)

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
    List.partition (fun (a : arm) -> Infer_expr.is_fail a.arm_pat) arms
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
and assign cx (e : expr) target op value =
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
        | Some op -> mk (Prim (Binop op, [ read pl e.loc; v ])) Ty.int e.loc
      in
      lets (binds @ hold_v) (write pl v e.loc)

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
      let args = List.map (expr cx) args in
      mk
        (Dep_call { dep; op; fty = ty_of cx f.node; ev = cx.ev; args })
        (ty_of cx e.node) e.loc
  | _ -> plain_call cx ~changed e f args

and plain_call cx ~changed ?last (e : expr) f args =
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
          match Prelude.find p with Some x -> Intrinsic x | _ -> Global p
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
    (* a wrapper's body, already lowered *)
    @ List.map (fun l -> Read l) (Option.to_list last)
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
  | Expr e :: rest ->
      let e = expr cx e in
      seq e (block cx rest last)

(* `for x in xs` holds the array, then goes over its indices.
   `for p in &ps` finds the place (once), then each pass copies the element
   into `p` and writes it back afterwards. mut.ml makes sure the body can't
   change the array itself, so its length can't change. *)
and for_loop cx (e : expr) var (iter : expr) body =
  let loc = e.loc in
  let array_ty = ty_of cx iter.node in
  let elem = C.elem_ty array_ty in
  let n = temp cx "n" Ty.int and i = temp cx "i" Ty.int in
  let index = local i iter.loc in
  let binop op a b ty = mk (Prim (Binop op, [ a; b ])) ty loc in
  (* [after] makes what to do after the body, given the loop variable *)
  let loop ~start ~element ~after =
    let x = bind cx var elem in
    let body = expr cx body in
    let step =
      mk (Assign (i, binop Add index (int_lit 1 loc) Ty.int)) Ty.unit loc
    in
    (* what's written back after the body is written back even if the
       body fails *)
    let rest =
      match after x with
      | writes when writes <> [] && C.can_fail body ->
          seq (mk (Finally (body, seq_all loc writes)) body.ty loc) step
      | writes -> seq body (List.fold_right seq writes step)
    in
    let pass = mk (Let (x, element, rest)) Ty.unit loc in
    lets
      [ (n, mk (Prim (Length, [ start ])) Ty.int loc); (i, int_lit 0 loc) ]
      (mk (While (binop Lt index (local n loc) Ty.bool, pass)) Ty.unit loc)
  in
  match iter.kind with
  | Ref p ->
      let binds, pl = place cx p in
      let at =
        { pl with steps = pl.steps @ [ SIndex (index, elem, iter.loc) ] }
      in
      lets binds
        (loop ~start:(read pl iter.loc) ~element:(read at iter.loc)
           ~after:(fun x -> [ write at (local x loc) loc ]))
  | _ ->
      let xs = temp cx "xs" array_ty in
      let xs_e = local xs iter.loc in
      lets
        [ (xs, expr cx iter) ]
        (loop ~start:xs_e
           ~element:(mk (Prim (Get_index, [ xs_e; index ])) elem iter.loc)
           ~after:(fun _ -> []))

and pattern cx (p : pattern) : C.pattern =
  let pty = ty_of cx p.pnode in
  let pkind : C.pattern_kind =
    match p.pkind with
    | PWild -> PWild
    | PVar b -> PVar (bind cx b pty)
    | PInt n -> PInt n
    | PBool b -> PBool b
    | PCon (c, ps) -> (
        match ((node cx p.pnode).found, pty) with
        | Some (Ctor_of (path, c)), _ -> PCon (path, c, List.map (pattern cx) ps)
        | None, Errors _ ->
            (* a tag, inside `Err(...)` *)
            PTag (c.name.name, List.map (pattern cx) ps)
        | _ -> bug "a constructor pattern inference didn't find")
    | PFail (t, ps) -> PTag (t.name, List.map (pattern cx) ps)
    | PFail_any -> PWild
    | POr ps -> POr (List.map (pattern cx) ps)
  in
  { pkind; pty; ploc = p.ploc }

(* The locals [e] uses but doesn't bind, in order of id. Every local of a
   function has its own id, so that's every local used, minus every local
   bound. *)
and free (e : C.expr) =
  let used = ref [] and bound = ref [] in
  let use (v : C.var) = used := v :: !used in
  let bind (v : C.var) = bound := v.id :: !bound in
  let rec go (e : C.expr) =
    match e.kind with
    | Int _ | Bool _ | Str _ | Unit | Global _ | Global_value _ | Intrinsic _ ->
        ()
    | Local v -> use v
    | Prim (_, args)
    | Array args
    | Con (_, _, args)
    | Tag (_, args)
    | Dep_call { args; _ } ->
        List.iter go args
    | With { impl; body; _ } ->
        (* its evidence isn't a local: nothing captures it *)
        go impl;
        go body
    | With_handler { handler; body; _ } ->
        go handler;
        go body
    | Instance impls -> List.iter (fun (_, i) -> go i) impls
    | Handler { captures; _ } -> List.iter use captures
    | Fail a | As_dep (_, a) | Assert a -> go a
    | Finally (a, b) | Assert_equal (a, b) ->
        go a;
        go b
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
    | Call (f, args, _) ->
        go f;
        List.iter (function C.Value a -> go a | C.Ref v -> use v) args
    | Lambda { params; captures; _ } ->
        List.iter (fun (p : C.param) -> bind p.var) params;
        List.iter use captures
    | Record (_, fields) -> List.iter (fun (_, v) -> go v) fields
    | Field (r, _, _) -> go r
  and pat (p : C.pattern) =
    match p.pkind with
    | PVar v -> bind v
    | PCon (_, _, ps) | PTag (_, ps) | POr ps -> List.iter pat ps
    | PWild | PInt _ | PBool _ -> ()
  in
  go e;
  List.filter (fun (v : C.var) -> not (List.mem v.id !bound)) !used
  |> List.sort_uniq (fun (a : C.var) (b : C.var) -> compare a.id b.id)

(* ---- top-level functions ---- *)

(* The largest binder id in a function, so temporaries can be numbered
   after its own locals. *)
let max_binder (f : fn_def) =
  let m = ref 0 in
  let see (b : binder) = m := max !m b.id in
  let rec go (e : expr) =
    match e.kind with
    | Int _ | Bool _ | Str _ | Unit | Var _ -> ()
    | Unop (_, a) | Field (a, _) | Ref a | Try a | Attempt a | Assert a -> go a
    | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
        go a;
        go b
    | Fail (_, args) -> List.iter (fun (_, a) -> go a) args
    | If (c, t, f) -> List.iter go (c :: t :: Option.to_list f)
    | Call (f, args) -> List.iter go (f :: args)
    | Lambda (ps, body) ->
        List.iter (fun (p : Resolved.param) -> see p.pname) ps;
        go body
    | Block (stmts, last) ->
        List.iter
          (function
            | Let { name; value; _ } ->
                see name;
                go value
            | Expr e -> go e)
          stmts;
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
    | Array xs -> List.iter go xs
    | For { var; iter; body } ->
        see var;
        go iter;
        go body
    | With { item; body; _ } ->
        go item;
        go body
    | Handler { state; arms; _ } ->
        List.iter
          (function
            | Let { name; value; _ } ->
                see name;
                go value
            | Expr e -> go e)
          state;
        List.iter (fun (a : handler_arm) -> go a.arm_impl) arms
  and pat (p : pattern) =
    match p.pkind with
    | PVar b -> see b
    | PCon (_, ps) | PFail (_, ps) | POr ps -> List.iter pat ps
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
  { path; params; ev = cx.ev; scheme; body = expr cx f.body; loc = f.name.loc }

let program (r : Resolve.t) (inferred : Infer.t) : C.program =
  {
    home = r.home;
    types = r.types;
    fns = List.map (fn_def ~home:r.home inferred) (Ast.functions r.prog);
    values = inferred.values;
  }

(* ---- starting ---- *)

let start_name = "$start"

(* What the runtime runs: `$start`, which installs the real implementation
   of each built-in dependency [main] uses, the first in its row
   outermost, and calls it. The type checker made sure it uses no other
   (infer_top.ml, [check_main]). It starts from no evidence at all. *)
let start (main : C.fn_def) : C.fn_def =
  let loc = main.loc in
  let ret, errs, uses =
    match main.scheme.ty with
    | Fun (_, ret, errs, uses) -> (ret, errs, uses)
    | _ -> bug "a `main` whose type isn't a function's"
  in
  let deps = List.map (fun (l : Ty.label) -> Ty.dep_path l.name) uses.labels in
  (* each install's evidence is numbered after the one it extends *)
  let rec install n = function
    | [] ->
        mk
          (Call (mk (Global main.path) main.scheme.ty loc, [], C.evidence n))
          ret loc
    | (dep : Path.t) :: rest ->
        let real = Path.member dep "real" in
        mk
          (With
             {
               ev = C.evidence (n + 1);
               outer = C.evidence n;
               dep;
               impl = mk (Global_value real) (Con (dep, [ Uses Ty.closed ])) loc;
               body = install (n + 1) rest;
             })
          ret loc
  in
  {
    path = Path.make main.path.home start_name;
    params = [];
    ev = C.evidence 1;
    scheme = { main.scheme with ty = Fun ([], ret, errs, Ty.closed) };
    body = install 1 deps;
    loc;
  }
