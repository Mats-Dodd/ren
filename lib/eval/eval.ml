(* A tree-walking interpreter over Core (core.ml): the "interpreted Ren"
   milestone on the roadmap.

   By the time a program gets here it has been resolved, checked,
   type-checked and lowered, so it can't add a Bool to an Int or call a
   function that doesn't exist, and every change it makes is an assignment
   to a local variable. What's left is failing, which the program says it
   can do, and panics, like division by zero. A panic is the running
   program's fault, not a mistake in its source, so it's an exception of
   its own rather than a diagnostic.

   Values are never changed in place. A variable is a cell ([ref]) holding a
   value, and lowering has turned `user.plan = Free` or `xs[i] = v` into
   building a new value and assigning it to the variable, so a value some
   other name holds can't change under it. That's value semantics, done the
   slow way; stage 11 makes it cheap.

   A [Fail] raises [Failed], an OCaml exception, which the nearest [Handle]
   catches. It never leaves the interpreter: a call returns what its
   callee failed with as a [result] (OCaml's [Ok v] or [Error e]), so it
   can write its `inout` arguments back first, and if `main` fails, [run]
   raises [Uncaught] instead.

   What's installed is evidence (core.ml): a value in a variable like any
   other, passed to each call as its hidden parameter. A call of an
   operation finds its dependency's implementation in it by the
   dependency's path, never by a name the program spells.

   A value is shown through its type (shown.ml), which at runtime only a
   call knows for a generic function: `print<T>`'s `T` is whatever the
   caller passes. So each call works out what its callee's type variables
   stand for, from the type the callee has at the call, and the callee
   runs with them, [ctx.tys], as a compiler that makes a copy of each
   generic function for each type it's called at would. *)

open Core
open Value

exception Panic of Loc.t * string
exception Uncaught of string
exception Assert_failed of { loc : Loc.t; sides : (string * string) option }

let panic loc msg = raise (Panic (loc, msg))

(* An error on its way to the [Handle] that catches it. *)
exception Failed of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: checking or lowering let through " ^ what)

(* Structural equality. Functions have no meaningful equality, so comparing
   them panics; stage 9's operators will turn that into a type error. *)
let rec equal loc a b =
  match (a, b) with
  | VCon x, VCon y ->
      x.ty = y.ty && x.name = y.name && List.for_all2 (equal loc) x.args y.args
  | VTag x, VTag y ->
      x.name = y.name
      && List.length x.args = List.length y.args
      && List.for_all2 (equal loc) x.args y.args
  | VRecord xs, VRecord ys ->
      List.for_all2 (fun (_, x) (_, y) -> equal loc x y) xs ys
  | VArray xs, VArray ys ->
      Array.length xs = Array.length ys && Array.for_all2 (equal loc) xs ys
  | (VClosure _ | VFn _ | VBuiltin _), _ | _, (VClosure _ | VFn _ | VBuiltin _)
    ->
      panic loc "functions can't be compared"
  | VHandler _, _ | _, VHandler _ -> panic loc "handlers can't be compared"
  | _ -> a = b

(* The program's top-level functions, by path, its associated values
   once they're made, and its types. Nothing else is global: what's
   installed is evidence (core.ml), held in a variable like any value.
   [tys] is what the type variables of the function running stand for, by
   number, as far as its caller knew, and [showing] the types whose own
   `show` method it's inside. [depth] is how many calls deep the program
   is, not counting tail calls: one cell, shared by every copy of the
   [ctx] made with [{ cx with ... }]. *)
type ctx = {
  fns : (Path.t, fn_def) Hashtbl.t;
  values : (Path.t, Value.t) Hashtbl.t;
  types : Shown.types;
  tys : Ty.ty Env.t;
  showing : Path.t list;
  depth : int ref;
}

(* How many calls deep a program can go before it's stopped with a panic.
   OCaml's own stack would run out somewhere past this, but only after
   growing so large that every garbage collection on the way there scans
   all of it, which took minutes; a limit of our own is reached in a
   fraction of a second. *)
let max_depth = 100_000

(* The program went [max_depth] calls deep: [run] and [run_test] report it
   as a panic at the function they started. *)
exception Too_deep

(* What evaluating a function's body in tail position gives: its value,
   or the call it ends in, still to be made. That call is made by the loop
   in [finish], after the body that made it has returned, so a function
   that calls itself last, as a loop written as recursion does, runs in
   constant stack however many times it goes round. *)
type step =
  | Done of Value.t
  | Tail of {
      loc : Loc.t;  (** where the call is *)
      fty : Ty.ty;  (** the callee's type at the call, resolved *)
      f : Value.t;
      args : Value.t list;
      ev : Value.t;  (** the evidence it's passed *)
    }

(* [t], with each type variable [tys] knows replaced by what it stands for.
   One it doesn't know stays a variable: a value of that type is shown by
   its shape alone. *)
let rec resolve tys (t : Ty.ty) : Ty.ty =
  let row (r : Ty.row) =
    {
      r with
      labels =
        List.map
          (fun (l : Ty.label) ->
            { l with payload = List.map (resolve tys) l.payload })
          r.labels;
    }
  in
  match t with
  | Var i -> Option.value (Env.find_opt i tys) ~default:t
  | Con (p, ts) -> Con (p, List.map (resolve tys) ts)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = resolve tys p.ty }) ps,
          resolve tys r,
          row e,
          u )
  | Errors e -> Errors (row e)
  | Uses _ | Error -> t

(* What a function's type variables stand for in a call: its type as it's
   declared, [declared], matched against the type it has at the call,
   [actual], added to [tys]. *)
let rec bind tys (declared : Ty.ty) (actual : Ty.ty) =
  let all tys ds xs =
    if List.length ds = List.length xs then List.fold_left2 bind tys ds xs
    else tys
  in
  match (declared, actual) with
  | _, Var _ -> tys
  | Var i, t -> if Env.mem i tys then tys else Env.add i t tys
  | Con (p, ds), Con (q, xs) when p = q -> all tys ds xs
  | Fun (dps, dr, de, _), Fun (xps, xr, xe, _) ->
      let ty (p : Ty.param) = p.ty in
      let tys = all tys (List.map ty dps) (List.map ty xps) in
      bind (bind tys dr xr) (Errors de) (Errors xe)
  | Errors d, Errors x ->
      (* a tag's payload, matched by the tag's name *)
      List.fold_left
        (fun tys (l : Ty.label) ->
          match
            List.find_opt (fun (m : Ty.label) -> m.name = l.name) x.labels
          with
          | Some m -> all tys l.payload m.payload
          | None -> tys)
        tys d.labels
  | _ -> tys

let binop loc (op : Ast.binop) a b =
  match (op, a, b) with
  | Add, VInt x, VInt y -> VInt (x + y)
  | Sub, VInt x, VInt y -> VInt (x - y)
  | Mul, VInt x, VInt y -> VInt (x * y)
  | (Div | Mod), VInt _, VInt 0 -> panic loc "division by zero"
  | Div, VInt x, VInt y -> VInt (x / y)
  | Mod, VInt x, VInt y -> VInt (x mod y)
  | Lt, VInt x, VInt y -> VBool (x < y)
  | Le, VInt x, VInt y -> VBool (x <= y)
  | Gt, VInt x, VInt y -> VBool (x > y)
  | Ge, VInt x, VInt y -> VBool (x >= y)
  | Eq, x, y -> VBool (equal loc x y)
  | Neq, x, y -> VBool (not (equal loc x y))
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on the wrong types")

let element loc xs i =
  if i < 0 || i >= Array.length xs then
    panic loc
      (Printf.sprintf "index %d is out of bounds for an array of length %d" i
         (Array.length xs))
  else xs.(i)

let prim loc op args =
  match (op, args) with
  | Neg, [ VInt n ] -> VInt (-n)
  | Not, [ VBool b ] -> VBool (not b)
  | Binop op, [ a; b ] -> binop loc op a b
  | Length, [ VArray xs ] -> VInt (Array.length xs)
  | Get_index, [ VArray xs; VInt i ] -> element loc xs i
  | Set_index, [ VArray xs; VInt i; x ] ->
      ignore (element loc xs i);
      let ys = Array.copy xs in
      ys.(i) <- x;
      VArray ys
  | New_cell, [ v ] -> VCell (ref v)
  | Get_cell, [ VCell c ] -> !c
  | Set_cell, [ VCell c; v ] ->
      c := v;
      VUnit
  | _ -> bug ("`" ^ show_prim op ^ "` on the wrong values")

let truth = function VBool b -> b | _ -> bug "a non-Bool condition"

(* Match a value against a pattern. On success, return the environment
   extended with the variables the pattern binds. *)
let rec match_pattern p v env =
  match (p.pkind, v) with
  | PWild, _ -> Some env
  | PVar x, _ -> Some (Env.add x.id (ref v) env)
  | PInt n, VInt m -> if n = m then Some env else None
  | PBool b, VBool c -> if b = c then Some env else None
  | PCon (_, c, ps), VCon { name; args; _ } when c = name ->
      match_all ps args env
  | PTag (t, ps), VTag { name; args } when t = name -> match_all ps args env
  | POr ps, _ -> List.find_map (fun p -> match_pattern p v env) ps
  | _ -> None

and match_all ps vs env =
  match (ps, vs) with
  | [], [] -> Some env
  | p :: ps, v :: vs -> Option.bind (match_pattern p v env) (match_all ps vs)
  | _ -> None

let cell env (v : var) =
  match Env.find_opt v.id env with
  | Some c -> c
  | None -> bug ("`" ^ v.name ^ "` used outside its scope")

(* What [f] is, for a bug report. *)
let describe = function
  | VFn p -> "`" ^ p.name ^ "`"
  | VBuiltin x -> "`" ^ x ^ "`"
  | VClosure { body; _ } ->
      Printf.sprintf "a lambda (its body at %s:%d)" body.loc.file
        body.loc.start.line
  | _ -> "something that isn't a function"

(* The evidence in [v], for [what]: threading it wrongly is a bug Core
   Lint should have caught, but `ren run` doesn't lint, so say where. *)
let evidence_in env (v : var) what =
  match Option.map ( ! ) (Env.find_opt v.id env) with
  | Some (VEvidence installed) -> installed
  | Some _ -> bug (what ^ " with something that isn't evidence")
  | None -> bug (what ^ " with evidence that isn't in scope")

let rec eval cx env (e : expr) =
  match e.kind with
  | Int n -> VInt n
  | Bool b -> VBool b
  | Str s -> VStr s
  | Unit -> VUnit
  | Local v -> !(cell env v)
  | Global p -> VFn p
  | Global_value p -> (
      match Hashtbl.find_opt cx.values p with
      | Some v -> v
      | None -> bug ("the value `" ^ p.name ^ "` used before it's made"))
  | Intrinsic x -> VBuiltin x
  | Dep_call { dep; op; ev; args; fty; _ } -> (
      (* the innermost implementation of [dep]: a record of functions, the
         operation's run with what was installed where it was *)
      let args = eval_all cx env args in
      let what = Printf.sprintf "a call of `%s.%s`" dep.name op in
      match
        List.find_opt
          (fun (i : installed) -> i.dep = dep)
          (evidence_in env ev what)
      with
      | Some { impl = VRecord ops; outer; _ } -> (
          match List.assoc_opt op ops with
          | Some f ->
              let fty = resolve cx.tys fty in
              ok (fst (call_at cx e.loc ~fty f args (VEvidence outer)))
          | None -> bug (what ^ " on an implementation without it"))
      | Some _ -> bug (what ^ " on an implementation that isn't a record")
      | None -> bug (what ^ " where nothing installs `" ^ dep.name ^ "`"))
  | With { ev; outer; dep; impl; body } ->
      let what = "installing `" ^ dep.name ^ "`" in
      let impl = eval cx env impl in
      let outer = evidence_in env outer what in
      (* a record is installed as it is, and a handler's description as a
         fresh instance's implementation of [dep] *)
      let impl =
        match impl with
        | VHandler h -> (
            match List.assoc_opt dep (instance cx h outer what) with
            | Some impl -> impl
            | None -> bug (what ^ " from a handler that doesn't implement it"))
        | impl -> impl
      in
      let installed = VEvidence ({ dep; impl; outer } :: outer) in
      eval cx (Env.add ev.id (ref installed) env) body
  | As_dep (_, h) -> eval cx env h
  | Handler { ev; captures; body } ->
      (* like a lambda, it copies what it captures now *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (ref !(cell env v)) inner)
          Env.empty captures
      in
      VHandler { ev = ev.id; body; env; tys = cx.tys }
  | Instance impls ->
      let values = eval_all cx env (List.map snd impls) in
      VInstance (List.combine (List.map fst impls) values)
  | With_handler { ev; outer; handler; deps; body } -> (
      let what = "installing a handler" in
      let h = eval cx env handler in
      let outer = evidence_in env outer what in
      match h with
      | VHandler h -> (
          match instance cx h outer what with
          | impls when List.map fst impls = deps ->
              let installed =
                List.fold_left
                  (fun acc (dep, impl) -> { dep; impl; outer } :: acc)
                  outer impls
              in
              eval cx (Env.add ev.id (ref (VEvidence installed)) env) body
          | _ ->
              bug (what ^ " whose instance doesn't implement its dependencies"))
      | _ -> bug (what ^ " with something that isn't a handler"))
  | Prim (op, args) -> prim e.loc op (eval_all cx env args)
  | Let (v, value, body) ->
      let x = eval cx env value in
      eval cx (Env.add v.id (ref x) env) body
  | Assign (v, value) ->
      cell env v := eval cx env value;
      VUnit
  | If (c, t, f) ->
      if truth (eval cx env c) then eval cx env t else eval cx env f
  | While (c, body) ->
      while truth (eval cx env c) do
        ignore (eval cx env body)
      done;
      VUnit
  | Seq (a, b) ->
      ignore (eval cx env a);
      eval cx env b
  | Call (f, args, ev) ->
      let fty = resolve cx.tys f.ty in
      let f = eval cx env f in
      (* an `inout` argument is a local: read it now, and write the
         parameter's final value back once the call returns *)
      let values =
        eval_all cx env
          (List.map (function Value a -> a | Ref v -> local v e.loc) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      let result, finals = call_at cx e.loc ~fty f values (VEvidence ev) in
      (* written back whether the call failed or not: failing doesn't undo
         what it changed (errors.md, "Failure and `&`") *)
      List.iter2
        (fun a v -> match a with Ref x -> cell env x := v | Value _ -> ())
        args finals;
      ok result
  | Lambda { params; ev; captures; body } ->
      (* copy the captured variables' values now, into cells of the
         lambda's own: assigning to a variable later doesn't change what
         the lambda sees *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (ref !(cell env v)) inner)
          Env.empty captures
      in
      VClosure
        {
          params = List.map (fun (p : param) -> p.var.id) params;
          ev = ev.id;
          body;
          env;
          tys = cx.tys;
        }
  | Con (p, c, args) -> VCon { ty = p; name = c; args = eval_all cx env args }
  | Record (_, fields) ->
      let values = eval_all cx env (List.map snd fields) in
      let fields = List.combine (List.map fst fields) values in
      VRecord (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)
  | Field (r, _, f) -> (
      match eval cx env r with
      | VRecord fields -> List.assoc f fields
      | _ -> bug "a field of a non-record")
  | Update (r, f, v) -> (
      let r = eval cx env r in
      let v = eval cx env v in
      match r with
      | VRecord fields ->
          VRecord
            (List.map (fun (g, w) -> if g = f then (g, v) else (g, w)) fields)
      | _ -> bug "an update of a non-record")
  | Array xs -> VArray (Array.of_list (eval_all cx env xs))
  | Match (subject, arms) ->
      let v = eval cx env subject in
      let guard_passes env = function
        | None -> true
        | Some g -> truth (eval cx env g)
      in
      let rec first = function
        | [] -> panic e.loc "no arm of this `match` matched"
        | a :: rest -> (
            match match_pattern a.pat v env with
            | Some env when guard_passes env a.guard -> eval cx env a.body
            | _ -> first rest)
      in
      first arms
  | Tag (t, args) -> VTag { name = t; args = eval_all cx env args }
  | Fail a -> raise (Failed (eval cx env a))
  | Handle { body; value; on_value; error; on_error } -> (
      (* [match ... with exception] runs one branch for a value and another
         for an exception that evaluating it raised *)
      match eval cx env body with
      | v -> eval cx (Env.add value.id (ref v) env) on_value
      | exception Failed err ->
          eval cx (Env.add error.id (ref err) env) on_error)
  | Assert a ->
      if not (truth (eval cx env a)) then
        raise (Assert_failed { loc = a.loc; sides = None });
      VUnit
  | Assert_equal (a, b) ->
      let x = eval cx env a in
      let y = eval cx env b in
      if not (equal e.loc x y) then
        raise
          (Assert_failed
             {
               loc = e.loc;
               sides =
                 Some
                   (Shown.sides ~own:(own_show cx) cx.types
                      (resolve cx.tys a.ty) x y);
             });
      VUnit
  | Finally (body, after) -> (
      match eval cx env body with
      | v ->
          ignore (eval cx env after);
          v
      | exception Failed err ->
          ignore (eval cx env after);
          raise (Failed err))

(* [e], the body of a function or a part of one in tail position: a
   [Call] there with no `inout` argument, which would have to be written
   back once it returns, is returned for [finish] to make, and anything
   else is evaluated. Each part is evaluated in the order [eval] evaluates
   it. *)
and tail cx env (e : expr) =
  match e.kind with
  | If (c, t, f) ->
      if truth (eval cx env c) then tail cx env t else tail cx env f
  | Let (v, value, body) ->
      let x = eval cx env value in
      tail cx (Env.add v.id (ref x) env) body
  | Seq (a, b) ->
      ignore (eval cx env a);
      tail cx env b
  | Match (subject, arms) ->
      let v = eval cx env subject in
      let guard_passes env = function
        | None -> true
        | Some g -> truth (eval cx env g)
      in
      let rec first = function
        | [] -> panic e.loc "no arm of this `match` matched"
        | a :: rest -> (
            match match_pattern a.pat v env with
            | Some env when guard_passes env a.guard -> tail cx env a.body
            | _ -> first rest)
      in
      first arms
  | Call (f, args, ev)
    when List.for_all (function Value _ -> true | Ref _ -> false) args ->
      let fty = resolve cx.tys f.ty in
      let f = eval cx env f in
      let args =
        eval_all cx env
          (List.filter_map (function Value a -> Some a | Ref _ -> None) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      Tail { loc = e.loc; fty; f; args; ev = VEvidence ev }
  | _ -> Done (eval cx env e)

(* Make the call [step] ends in, then the one that ends in, and so on,
   until one gives a value. A panic is said to be where the call that
   reached it is, as [call_at] says: [at] is the last of these calls made
   from the program's own code rather than the prelude's, which a panic
   inside the prelude is said to be at. *)
and finish cx at step =
  match step with
  | Done v -> v
  | Tail t ->
      let at = if t.loc.file <> Prelude.file then Some t.loc else at in
      let next =
        try enter cx ~fty:t.fty t.f t.args t.ev with
        | Prelude.Panic msg -> panic (Option.value at ~default:t.loc) msg
        | Panic (l, msg) when l.file = Prelude.file && at <> None ->
            panic (Option.get at) msg
      in
      finish cx at next

(* What a call returned, or else fail with its error. *)
and ok = function Ok v -> v | Error err -> raise (Failed err)

(* A fresh instance of the handler [h], made with [outer], what's
   installed where it's installed, which its operations then run with: its
   implementation of each of its dependencies. *)
and instance cx (h : handler) outer what =
  let cx = { cx with tys = h.tys } in
  match eval cx (Env.add h.ev (ref (VEvidence outer)) h.env) h.body with
  | VInstance impls -> impls
  | _ -> bug (what ^ " whose description doesn't make an instance")

(* Evaluate [es] left to right. (A `let` in [::]'s head fixes the order.) *)
and eval_all cx env = function
  | [] -> []
  | e :: rest ->
      let v = eval cx env e in
      v :: eval_all cx env rest

(* [apply], from a call at [loc]. *)
and call_at cx loc ~fty f args ev =
  try apply cx ~fty f args ev with
  | Prelude.Panic msg -> panic loc msg
  | Panic (l, msg) when l.file = Prelude.file && loc.file <> Prelude.file ->
      (* the prelude's source can't be shown, so a panic inside it is the
         program's call that reached it *)
      panic loc msg

(* Call [f], of type [fty] at the call, passing it the evidence [ev].
   Returns its result, or the error it failed with, and the final value of
   every parameter, so the caller can write back the ones passed `inout`.
   A call that doesn't know [f]'s type passes [Ty.Error]. *)
and apply cx ~fty f args ev =
  match f with
  | VBuiltin _ -> builtin cx ~fty f args
  | _ ->
      (* the function's parameters are cells, whose final values are
         returned, to be written back to the arguments passed `inout`. The
         calls it ends in are made by [finish], here, once its body has
         returned; none passes anything `inout`, so these cells are still
         the ones to return *)
      let cells = List.map ref args in
      if !(cx.depth) >= max_depth then raise Too_deep;
      incr cx.depth;
      let result =
        match finish cx None (start cx ~fty f cells ev) with
        | v -> Ok v
        | exception Failed err -> Error err
        | exception e ->
            decr cx.depth;
            raise e
      in
      decr cx.depth;
      (result, List.map ( ! ) cells)

(* Begin a call of [f], a function of the program, whose parameters are
   [cells]: evaluate its body as far as the call it ends in, if it ends in
   one. *)
and start cx ~fty f cells ev =
  let run cx params ev_id body env =
    (match ev with
    | VEvidence _ -> ()
    | _ -> bug ("a call of " ^ describe f ^ " passing something not evidence"));
    if List.length params <> List.length cells then
      bug ("a call of " ^ describe f ^ " with the wrong number of arguments");
    let env =
      List.fold_left2 (fun env id c -> Env.add id c env) env params cells
    in
    let env = Env.add ev_id (ref ev) env in
    tail cx env body
  in
  match f with
  | VFn p ->
      let f =
        match Hashtbl.find_opt cx.fns p with
        | Some f -> f
        | None -> bug ("a call of `" ^ p.name ^ "`, which doesn't exist")
      in
      let tys = bind Env.empty f.scheme.ty fty in
      run { cx with tys }
        (List.map (fun (p : param) -> p.var.id) f.params)
        f.ev.id f.body Env.empty
  | VClosure { params; ev; body; env; tys } ->
      run { cx with tys } params ev body env
  | _ -> bug "a call to something that isn't a function"

(* A call in tail position, which [finish] makes: a built-in's value, or
   its error, or the callee's body as far as the call it ends in. *)
and enter cx ~fty f args ev =
  match f with
  | VBuiltin _ -> Done (ok (fst (builtin cx ~fty f args)))
  | _ -> start cx ~fty f (List.map ref args) ev

(* A call of a built-in function, which [apply] returns. *)
and builtin cx ~fty f args =
  match f with
  | VBuiltin "show" -> (
      (* the one built-in that needs its argument's type *)
      match (fty, args) with
      | _, [ v ] ->
          let t =
            match fty with Fun ([ p ], _, _, _) -> p.ty | _ -> Ty.Error
          in
          (Ok (VStr (Shown.shown ~own:(own_show cx) cx.types t v)), args)
      | _ -> bug "a call of `show` with the wrong number of arguments")
  | VBuiltin name -> (
      match Prelude.find_fn name with
      | Some b -> (
          match b.eval args with
          | v, finals -> (Ok v, finals)
          | exception Prelude.Fail err -> (Error err, args))
      | None -> bug ("the unknown built-in `" ^ name ^ "`"))
  | _ -> bug "a call of a built-in that isn't one"

(* [v], of type [t] in the function running, as `show` and a failed
   `assert` show it (shown.ml). *)
and show_value cx t v =
  Shown.value ~own:(own_show cx) cx.types (resolve cx.tys t) v

(* How the type [p], given [args], shows [v] (Shown.own): through its own
   method `show`, if it has one that takes only its `self` and gives a
   `Str` without failing or using a dependency, unless that's where this
   is. *)
and own_show cx (p : Path.t) args v : Shown.own =
  let own (d : Iface.type_decl) =
    List.find_map
      (fun (o : Iface.op) ->
        match (o.okind, o.oscheme.ty) with
        | Method, Fun ([ _ ], ret, errs, uses)
          when o.oname = "show" && ret = Ty.str && errs.labels = []
               && uses.labels = [] ->
            Some (Path.make p.home (p.name ^ ".show"))
        | _ -> None)
      d.members
  in
  match Option.bind (Hashtbl.find_opt cx.types p) own with
  | Some _ when List.mem p cx.showing -> Inside
  | Some m when Hashtbl.mem cx.fns m -> (
      let fty =
        Ty.Fun ([ Ty.read (Con (p, args)) ], Ty.str, Ty.closed, Ty.closed)
      in
      let cx = { cx with showing = p :: cx.showing } in
      match apply cx ~fty (VFn m) [ v ] (VEvidence []) with
      | Ok (VStr s), _ -> Itself s
      | _ -> Declared)
  | _ -> Declared

(* An error nothing handled, which the top-level function [p] failed
   with, shown through the types its errors' payloads have there. *)
let error_of cx p err =
  match
    Option.map (fun (f : fn_def) -> f.scheme.ty) (Hashtbl.find_opt cx.fns p)
  with
  | Some (Fun (_, _, errs, _)) -> show_value cx (Errors errs) err
  | _ -> Value.show err

(* A program's functions, by path, and its associated values, made in
   order: a module's after those of every module it imports, which come
   before it, and within a module in the order lowering gives, each after
   every value it uses, with nothing installed: a value can't use a
   dependency (infer_top.ml). If making one fails, nothing handles the
   error: [Uncaught]. *)
let load (modules : program list) =
  let cx =
    {
      fns = Hashtbl.create 16;
      values = Hashtbl.create 16;
      types =
        Shown.types (List.concat_map (fun (m : program) -> m.types) modules);
      tys = Env.empty;
      showing = [];
      depth = ref 0;
    }
  in
  List.iter
    (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns)
    modules;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun p ->
          match fst (apply cx ~fty:Ty.Error (VFn p) [] (VEvidence [])) with
          | Ok v -> Hashtbl.replace cx.values p v
          | Error err -> raise (Uncaught (error_of cx p err)))
        m.values)
    modules;
  cx

(* Run a program made of [modules] (the prelude, then the user's files),
   starting from the last one's `$start`, which installs what `main` uses
   and calls it (lower.ml). If `main`, or making a value, fails, nothing
   handles the error: [Uncaught]. *)
let run (modules : program list) =
  let entry = List.nth modules (List.length modules - 1) in
  let start = Path.make entry.home Lower.start_name in
  (* a program that calls too deeply, past [max_depth] or past OCaml's
     own stack, has a bug, so it's a panic *)
  let overflow () =
    match List.find_opt (fun (f : fn_def) -> f.path = start) entry.fns with
    | Some f ->
        panic f.loc "the stack overflowed: a function called itself too deeply"
    | None -> bug "a program with no `main`"
  in
  try
    let cx = load modules in
    if not (Hashtbl.mem cx.fns start) then bug "a program with no `main`";
    match fst (apply cx ~fty:Ty.Error (VFn start) [] (VEvidence [])) with
    | Ok v -> v
    | Error err -> raise (Uncaught (error_of cx start err))
  with Stack_overflow | Too_deep -> overflow ()

(* ---- tests ---- *)

(* How a test ended. *)
type outcome =
  | Passed
  | Failed of string  (** with this error, which nothing handled, shown *)
  | Panicked of exn  (** a [Panic], or an [Assert_failed] *)

(* Run the test whose function is [fn], in a program [load] made, with
   the test implementation of each built-in dependency (deps.md, "Tests"),
   a fresh instance for this test, but the real one of those in [real]:
   `Random`'s seeded with [seed]. The runtime installs them as it does
   `main`'s, outermost, so they run with nothing installed. Returns how
   it ended, and every line it wrote to the test `Console`, which is kept
   even if it panicked; with the real one, it went to stdout. *)
let run_test cx ~(fn : Path.t) ~real ~seed =
  let what = "installing a test's implementations" in
  let value p =
    match Hashtbl.find_opt cx.values p with
    | Some v -> v
    | None -> bug (what ^ " with `" ^ p.name ^ "` not made")
  in
  (* the instance of the prelude's handler [name], given [args] *)
  let instance_of name args =
    match
      apply cx ~fty:Ty.Error (VFn (Path.prelude name)) args (VEvidence [])
    with
    | Ok (VHandler h), _ -> instance cx h [] what
    | _ -> bug (what ^ " with `" ^ name ^ "`, which isn't a handler")
  in
  let installed =
    List.concat_map
      (fun (dep, handler, args) ->
        if List.mem dep real then
          [
            {
              dep = Path.prelude dep;
              impl = value (Path.prelude (dep ^ ".real"));
              outer = [];
            };
          ]
        else
          List.map
            (fun (dep, impl) -> { dep; impl; outer = [] })
            (instance_of handler args))
      [
        ("Clock", "test_clock", [ value (Path.prelude "Time.epoch") ]);
        ("Random", "test_random", [ VInt seed ]);
        ("Console", "test_console", []);
        ("Fs", "mem_fs", [ VArray [||] ]);
        ("Os", "test_os", [ VArray [||] ]);
        ("Proc", "test_proc", [ VArray [||] ]);
      ]
  in
  let outcome =
    try
      match fst (apply cx ~fty:Ty.Error (VFn fn) [] (VEvidence installed)) with
      | Ok _ -> Passed
      | Error err -> Failed (error_of cx fn err)
    with
    | (Panic _ | Assert_failed _) as e -> Panicked e
    | Stack_overflow | Too_deep ->
        let loc =
          match Hashtbl.find_opt cx.fns fn with
          | Some f -> f.loc
          | None -> bug ("a test whose function `" ^ fn.name ^ "` isn't there")
        in
        Panicked
          (Panic
             (loc, "the stack overflowed: a function called itself too deeply"))
  in
  (* what the test `Console` kept, asked of it as the test would *)
  let console =
    List.find_map
      (fun (i : installed) ->
        match i.impl with
        | VRecord ops when i.dep = Path.prelude "TestConsole" -> (
            match
              apply cx ~fty:Ty.Error (List.assoc "output" ops) [] (VEvidence [])
            with
            | Ok (VArray lines), _ ->
                Some
                  (Array.to_list
                     (Array.map
                        (function VStr s -> s | v -> Value.show v)
                        lines))
            | _ -> bug "a test `Console` whose output isn't an array")
        | _ -> None)
      installed
  in
  (outcome, Option.value console ~default:[])
