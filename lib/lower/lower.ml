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

   Everything is evaluated in the order it was before: the order the
   interpreter has always used, so a program prints the same things. *)

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

let rec expr cx (e : expr) : C.expr =
  let ty () = ty_of cx e.node in
  let here kind = mk kind (ty ()) e.loc in
  match e.kind with
  | Int n -> here (Int n)
  | Bool b -> here (Bool b)
  | Unit -> here Unit
  | Var (Local b) -> local (var_of cx b) e.loc
  | Var (Global p) -> here (Global p)
  | Var (Global_value p) -> here (Global_value p)
  | Var (Intrinsic x) -> here (Intrinsic x)
  | Unop (Neg, a) -> here (Prim (Neg, [ expr cx a ]))
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
      let body = expr cx body in
      let own = List.map (fun (p : C.param) -> p.var.id) params in
      let captures =
        List.filter (fun (v : C.var) -> not (List.mem v.id own)) (free body)
      in
      here (Lambda { params; captures; body })
  | Block (stmts, last) -> block cx stmts last
  | Con (_, args) -> (
      match (node cx e.node).found with
      | Some (Ctor_of (p, c)) ->
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
  | Match (subject, arms) ->
      let subject = expr cx subject in
      let arm (a : arm) : C.arm =
        let pat = pattern cx a.arm_pat in
        let guard = Option.map (expr cx) a.arm_guard in
        { pat; guard; body = expr cx a.arm_body }
      in
      here (Match (subject, List.map arm arms))
  | Array xs -> here (Array (List.map (expr cx) xs))
  | Index (a, i) ->
      let a = expr cx a in
      here (Prim (Get_index, [ a; expr cx i ]))
  | Ref ({ kind = Call (f, args); _ } as c) -> call cx ~changed:true c f args
  | Ref _ -> bug "`&` outside a call or a `for` loop"
  | Assign { target; op; value } -> assign cx e target op value
  | For { var; iter; body } -> for_loop cx e var iter body

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
        (mk (Global p) (ty_of cx f.node) f.loc, [ recv ])
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
    mk (Call (f, List.filter_map direct lowered)) ty e.loc
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
    let result = temp cx "result" ty in
    lets binds
      (lets
         [ (result, mk (Call (f, args)) ty e.loc) ]
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
    let pass =
      mk
        (Let (x, element, seq body (List.fold_right seq (after x) step)))
        Ty.unit loc
    in
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
    | PCon (_, ps) -> (
        match (node cx p.pnode).found with
        | Some (Ctor_of (path, c)) -> PCon (path, c, List.map (pattern cx) ps)
        | _ -> bug "a constructor pattern inference didn't find")
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
    | Int _ | Bool _ | Unit | Global _ | Global_value _ | Intrinsic _ -> ()
    | Local v -> use v
    | Prim (_, args) | Array args | Con (_, _, args) -> List.iter go args
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
    | Call (f, args) ->
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
    | PCon (_, _, ps) -> List.iter pat ps
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
    | Int _ | Bool _ | Unit | Var _ -> ()
    | Unop (_, a) | Field (a, _) | Ref a -> go a
    | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
        go a;
        go b
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
  and pat (p : pattern) =
    match p.pkind with
    | PVar b -> see b
    | PCon (_, ps) -> List.iter pat ps
    | PWild | PInt _ | PBool _ -> ()
  in
  List.iter (fun (p : Resolved.param) -> see p.pname) f.params;
  go f.body;
  !m

let fn_def ~home (inferred : Infer.t) (f : fn_def) : C.fn_def =
  let name = f.name.name in
  let scheme = List.assoc name inferred.schemes in
  let cx =
    {
      nodes = List.assoc name inferred.nodes;
      vars = Hashtbl.create 16;
      next = max_binder f + 1;
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
    path = Path.make home name;
    params;
    scheme;
    body = expr cx f.body;
    loc = f.name.loc;
  }

let program (r : Resolve.t) (inferred : Infer.t) : C.program =
  {
    home = r.home;
    types = r.types;
    fns = List.map (fn_def ~home:r.home inferred) (Ast.functions r.prog);
    values = List.map (Path.make r.home) inferred.values;
  }
