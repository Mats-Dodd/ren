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

   A value is shown through its type (shown.ml), which for a generic
   function only its caller knows: `print<T>`'s `T` is whatever the caller
   passes. So a generic function is given a descriptor of the type each of
   its type variables stands for, as a hidden parameter, which lowering
   made explicit (core.ml, [desc]), and the interpreter only evaluates
   them, as it does evidence: it never works a type out.

   [==] is the same: what `T` stands for decides how two values of it are
   compared, so a generic function that compares them is given `T`'s `eq`
   dictionary (core.ml, [dict]). A dictionary is a function of the
   interpreter's: for a type known where it's built, it compares two
   values as the type's declaration says, and wherever that has the
   function's type variable, through the dictionary the function was given
   for it. Inference makes sure nothing compared has a function in it, so
   none is ever reached. *)

open Core
open Value

type wrap = { meth : string; recv : Loc.t; arg : Loc.t option }

exception Panic of { loc : Loc.t; msg : string; wrap : wrap option }
exception Uncaught of string
exception Assert_failed of { loc : Loc.t; sides : (string * string) option }

let panic ?wrap loc msg = raise (Panic { loc; msg; wrap })

(* An error on its way to the [Handle] that catches it. *)
exception Failed of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: checking or lowering let through " ^ what)

(* The program's top-level functions, by path, its associated values
   once they're made, and its types, with the function that shows each
   type that has a `show` method of its own, the `key` of each that has
   one, and the member that gives each its operators and associated
   values (Core.program). Nothing else
   is global: what's installed is evidence (core.ml), held in a variable
   like any value. [showing] are the types whose own `show` method the
   program is inside. [depth] is how many calls deep the program is, not
   counting tail calls: one cell, shared by every copy of the [ctx] made
   with [{ cx with ... }]. *)
type ctx = {
  fns : (Path.t, fn_def) Hashtbl.t;
  values : (Path.t, Value.t) Hashtbl.t;
  types : Shown.types;
  shows : (Path.t, Path.t) Hashtbl.t;
  keys : (Path.t, Path.t) Hashtbl.t;
  ops : (Path.t * string, Path.t) Hashtbl.t;
  showing : Path.t list;
  depth : int ref;
}

(* How many calls deep a program can go before it's stopped with a panic.
   OCaml's own stack would run out somewhere past this, but only after
   growing so large that every garbage collection on the way there scans
   all of it, which took minutes; a limit of our own is reached in a
   fraction of a second. *)
let max_depth = 100_000

(* The program went [max_depth] calls deep: [load], [run] and [run_test]
   report it as a panic at the function they started ([overflowed]). *)
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
      f : Value.t;
      args : Value.t list;
      ev : Value.t;  (** the evidence it's passed *)
    }

(* ---- numbers ----

   An `Int` is 64 bits, as it is on every backend, and arithmetic that
   doesn't fit panics, in every build (operators.md, "`Int` and
   `Float`"). A `Float` is never `NaN`: an operation that would make one
   panics too, and each result is checked here, where the C backend will
   check one only where it leaves arithmetic. [at] are the operands'
   expressions, for the panic's help to show them calling the method that
   wraps, `n.wrapping_add(1)`: none for an operator through a dictionary,
   on a `T`, which has no such method. *)

(* An overflow's panic: with the help, if the left side is written as an
   `Int`, which has the method [meth], and not a `with numeric` type. *)
let overflowed ~(at : expr list) loc op meth shown =
  let wrap =
    match at with
    | { ty = Con (p, []); loc = recv; _ } :: rest when p = Path.prelude "Int" ->
        let arg = match rest with b :: _ -> Some b.loc | [] -> None in
        Some { meth; recv; arg }
    | _ -> None
  in
  panic ?wrap loc (Printf.sprintf "`%s` overflowed: %s" op shown)

(* What a panic shows of [x op y], made only once there is one: building
   it for every operation made arithmetic several times slower. *)
let shown_ints op x y = Printf.sprintf "%Ld %s %Ld" x (Ast.binop_to_string op) y

let int_over ~at loc op meth x y =
  overflowed ~at loc (Ast.binop_to_string op) meth (shown_ints op x y)

let int_binop ~at loc (op : Ast.binop) x y =
  match op with
  | Add ->
      let r = Int64.add x y in
      (* it overflowed if both have the same sign and [r] the other *)
      if Int64.logand (Int64.logxor x r) (Int64.logxor y r) < 0L then
        int_over ~at loc op "wrapping_add" x y
      else VInt r
  | Sub ->
      let r = Int64.sub x y in
      if Int64.logand (Int64.logxor x y) (Int64.logxor x r) < 0L then
        int_over ~at loc op "wrapping_sub" x y
      else VInt r
  | Mul ->
      let r = Int64.mul x y in
      if
        (x = -1L && y = Int64.min_int)
        || (y = -1L && x = Int64.min_int)
        || (x <> 0L && Int64.div r x <> y)
      then int_over ~at loc op "wrapping_mul" x y
      else VInt r
  | (Div | Mod) when y = 0L -> panic loc "division by zero"
  | Div when x = Int64.min_int && y = -1L ->
      panic loc (Printf.sprintf "`/` overflowed: %s" (shown_ints op x y))
  (* both round toward zero, as C's do *)
  | Div -> VInt (Int64.div x y)
  | Mod -> VInt (Int64.rem x y)
  | Lt -> VBool (x < y)
  | Le -> VBool (x <= y)
  | Gt -> VBool (x > y)
  | Ge -> VBool (x >= y)
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on `Int`s")

(* [r], unless it's `NaN`, which there isn't: a panic that says what made
   it. *)
let not_nan loc (op : Ast.binop) x y r =
  if Float.is_nan r then
    panic loc
      (Printf.sprintf "`%s` has no answer here: %s %s %s"
         (Ast.binop_to_string op) (Ast.show_float x) (Ast.binop_to_string op)
         (Ast.show_float y))
  else VFloat r

let float_binop loc (op : Ast.binop) x y =
  match op with
  | Add -> not_nan loc op x y (x +. y)
  | Sub -> not_nan loc op x y (x -. y)
  | Mul -> not_nan loc op x y (x *. y)
  | Div -> not_nan loc op x y (x /. y)
  | Mod -> not_nan loc op x y (Float.rem x y)
  (* a total order, since there's no `NaN`, with -0.0 and 0.0 equal *)
  | Lt -> VBool (Float.compare x y < 0)
  | Le -> VBool (Float.compare x y <= 0)
  | Gt -> VBool (Float.compare x y > 0)
  | Ge -> VBool (Float.compare x y >= 0)
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on `Float`s")

let binop ~at loc (op : Ast.binop) a b =
  match (a, b) with
  | VInt x, VInt y -> int_binop ~at loc op x y
  | VFloat x, VFloat y -> float_binop loc op x y
  | _ -> bug ("`" ^ Ast.binop_to_string op ^ "` on the wrong types")

let neg ~at loc = function
  | VInt n when n = Int64.min_int ->
      overflowed ~at loc "-" "wrapping_neg" (Printf.sprintf "-(%Ld)" n)
  | VInt n -> VInt (Int64.neg n)
  | VFloat f -> VFloat (Float.neg f)
  | _ -> bug "`-` on the wrong type"

let element loc xs i =
  if i < 0L || i >= Int64.of_int (Array.length xs) then
    panic loc
      (Printf.sprintf "index %Ld is out of bounds for an array of length %d" i
         (Array.length xs))
  else xs.(Int64.to_int i)

(* [op] on [args], whose expressions are [at]. *)
let prim loc op args (at : expr list) =
  match (op, args) with
  | Neg, [ v ] -> neg ~at loc v
  | Not, [ VBool b ] -> VBool (not b)
  | Binop op, [ x; y ] -> binop ~at loc op x y
  | Length, [ VArray xs ] -> VInt (Int64.of_int (Array.length xs))
  | Get_index, [ VArray xs; VInt i ] -> element loc xs i
  | Set_index, [ VArray xs; VInt i; x ] ->
      ignore (element loc xs i);
      let ys = Array.copy xs in
      ys.(Int64.to_int i) <- x;
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
  | PTag (t, ps), VTag { name; args; _ } when t = name -> match_all ps args env
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
  | VFn (p, _, _) -> "`" ^ Path.local p ^ "`"
  | VBuiltin (x, _) -> "`" ^ Intrinsic.name x ^ "`"
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

(* The type [d] describes (core.ml, [desc]): built from its parts, with
   what the hidden type parameters it names hold, as a constructor's value
   is. *)
let rec type_of env (d : desc) : Ty.ty =
  let row r : Ty.row =
    {
      labels =
        List.map
          (fun (name, ds) : Ty.label ->
            { name; payload = List.map (type_of env) ds })
          r.dlabels;
      tail = r.dtail;
    }
  in
  match d with
  | Known t -> t
  | Param v -> (
      match !(cell env v) with
      | VType t -> t
      | _ -> bug ("a descriptor built from `" ^ v.name ^ "`, which isn't one"))
  | Applied (p, ds) -> Con (p, List.map (type_of env) ds)
  | Fn (ps, r, e, u) ->
      Fun
        ( List.map (fun (mode, d) : Ty.param -> { mode; ty = type_of env d }) ps,
          type_of env r,
          row e,
          u,
          Ty.any_lams )
  | Errs e -> Errors (row e)

(* The dictionary the hidden dictionary parameter [v] holds. *)
let dict_in env (v : var) =
  match !(cell env v) with
  | VDict d -> d
  | _ -> bug ("a dictionary built from `" ^ v.name ^ "`, which isn't one")

(* Two values the same, by an `eq` dictionary. *)
let equal_by (d : Value.dict) x y =
  match d with Eq f -> f x y | _ -> bug "`==` through a dictionary not `eq`'s"

(* The binary operator a requirement is: `add` is `+`. *)
let binop_of_req req : Ast.binop =
  match req with
  | "add" -> Add
  | "sub" -> Sub
  | "mul" -> Mul
  | "div" -> Div
  | "rem" -> Mod
  | _ -> bug ("`" ^ req ^ "` as a binary operator")

(* An [Int]'s or a [Float]'s operator, as a dictionary has it, which is
   given where its operands are and doesn't need them. *)
let number_op req loc (_ : Loc.t list) vs =
  (* no help: the operands are a `T`'s, which has no `wrapping_add` *)
  match (req, vs) with
  | "neg", [ v ] -> neg ~at:[] loc v
  | _, [ x; y ] -> binop ~at:[] loc (binop_of_req req) x y
  | _ -> bug ("`" ^ req ^ "` on the wrong number of values")

let rec eval cx env (e : expr) =
  match e.kind with
  | Int n -> VInt n
  | Float f -> VFloat f
  | Bool b -> VBool b
  | Str s -> VStr s
  | Unit -> VUnit
  | Local v -> !(cell env v)
  | Global (p, _, ds, dicts) ->
      VFn
        ( p,
          List.map (type_of env) ds,
          List.map (fun d -> VDict (dict cx env d)) dicts )
  | Global_value (p, _) -> (
      match Hashtbl.find_opt cx.values p with
      | Some v -> v
      | None -> bug ("the value `" ^ Path.local p ^ "` used before it's made"))
  | Intrinsic (x, _, ds) -> VBuiltin (x, List.map (type_of env) ds)
  | Dep_call { dep; op; ev; args; _ } -> (
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
          | Some f -> ok (fst (call_at cx e.loc f args (VEvidence outer)))
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
  | Narrowed (_, h) -> eval cx env h
  | Handler { ev; captures; body } ->
      (* like a lambda, it copies what it captures now *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (ref !(cell env v)) inner)
          Env.empty captures
      in
      VHandler { ev = ev.id; body; env }
  | Instance impls ->
      let values = eval_all cx env (List.map snd impls) in
      VInstance (List.combine (List.map fst impls) values)
  | With_handler { ev; outer; handler; deps; body } -> (
      let what = "installing a handler" in
      let h = eval cx env handler in
      let outer = evidence_in env outer what in
      match h with
      | VHandler h ->
          (* of what the instance implements, only [deps]: it may have
             been narrowed to them (Core.Narrowed) *)
          let impls = instance cx h outer what in
          if not (List.for_all (fun d -> List.mem_assoc d impls) deps) then
            bug (what ^ " whose instance doesn't implement its dependencies");
          let installed =
            List.fold_left
              (fun acc (dep, impl) ->
                if List.mem dep deps then { dep; impl; outer } :: acc else acc)
              outer impls
          in
          eval cx (Env.add ev.id (ref (VEvidence installed)) env) body
      | _ -> bug (what ^ " with something that isn't a handler"))
  | Prim (((Equal d | Not_equal d) as op), [ a; b ]) ->
      let x = eval cx env a in
      let y = eval cx env b in
      let same = equal_by (dict cx env d) x y in
      VBool (match op with Not_equal _ -> not same | _ -> same)
  | Prim (Compare (op, d), [ a; b ]) -> (
      let x = eval cx env a in
      let y = eval cx env b in
      match dict cx env d with
      | Ord compare ->
          let c = compare x y in
          VBool
            (match op with
            | Lt -> c < 0
            | Le -> c <= 0
            | Gt -> c > 0
            | Ge -> c >= 0
            | _ -> bug "a comparison that isn't one")
      | _ -> bug "a comparison through a dictionary that isn't `ord`'s")
  | Prim (Op (_, d), args) -> (
      let vs = eval_all cx env args in
      match dict cx env d with
      | Op f -> f e.loc (List.map (fun (a : expr) -> a.loc) args) vs
      | _ -> bug "an operator through a dictionary that isn't one")
  | Prim (Value_of (_, d), []) -> (
      match dict cx env d with
      | Const v -> v
      | _ -> bug "an associated value through a dictionary that isn't one")
  | Prim (op, args) -> prim e.loc op (eval_all cx env args) args
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
      let f = eval cx env f in
      (* an `inout` argument is a local: read it now, and write the
         parameter's final value back once the call returns *)
      let values =
        eval_all cx env
          (List.map (function Value a -> a | Ref v -> local v e.loc) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      let result, finals = call_at cx e.loc f values (VEvidence ev) in
      (* written back whether the call failed or not: failing doesn't undo
         what it changed (errors.md, "Failure and `&`") *)
      List.iter2
        (fun a v -> match a with Ref x -> cell env x := v | Value _ -> ())
        args finals;
      ok result
  | Lambda { params; ev; captures; body; _ } ->
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
      let env, body = arm_for cx env e.loc (eval cx env subject) arms in
      eval cx env body
  | Tag (t, args, ds) ->
      VTag
        {
          name = t;
          args = eval_all cx env args;
          tys = List.map (type_of env) ds;
        }
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
  | Assert_equal (a, b, d, eq) ->
      let x = eval cx env a in
      let y = eval cx env b in
      if not (equal_by (dict cx env eq) x y) then
        raise
          (Assert_failed
             {
               loc = e.loc;
               sides =
                 Some
                   (Shown.sides ~own:(own_show cx) cx.types (type_of env d) x y);
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
      let env, body = arm_for cx env e.loc (eval cx env subject) arms in
      tail cx env body
  | Call (f, args, ev)
    when List.for_all (function Value _ -> true | Ref _ -> false) args ->
      let f = eval cx env f in
      let args =
        eval_all cx env
          (List.filter_map (function Value a -> Some a | Ref _ -> None) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      Tail { loc = e.loc; f; args; ev = VEvidence ev }
  | _ -> Done (eval cx env e)

(* Make the call [step] ends in, then the one that ends in, and so on,
   until one gives a value. A panic is said to be where the call that
   reached it is, as [call_at] says: [at] is the last of these calls made
   from the program's own code rather than the prelude's, which a panic
   inside the prelude is said to be at. *)
(* The first of a `match`'s [arms] whose pattern [v] matches and whose
   guard passes: the environment its body runs in, with what the pattern
   bound, and the body, for [eval] or [tail] to run. *)
and arm_for cx env loc v arms =
  let guard_passes env = function
    | None -> true
    | Some g -> truth (eval cx env g)
  in
  let rec first = function
    | [] -> panic loc "no arm of this `match` matched"
    | a :: rest -> (
        match match_pattern a.pat v env with
        | Some env when guard_passes env a.guard -> (env, a.body)
        | _ -> first rest)
  in
  first arms

and finish cx at step =
  match step with
  | Done v -> v
  | Tail t ->
      let at = if t.loc.file <> Prelude.file then Some t.loc else at in
      let next =
        try enter cx t.f t.args t.ev with
        | Builtins.Panic msg -> panic (Option.value at ~default:t.loc) msg
        | Panic { loc; msg; _ } when loc.file = Prelude.file && at <> None ->
            panic (Option.get at) msg
      in
      finish cx at next

(* What a call returned, or else fail with its error. *)
and ok = function Ok v -> v | Error err -> raise (Failed err)

(* A fresh instance of the handler [h], made with [outer], what's
   installed where it's installed, which its operations then run with: its
   implementation of each of its dependencies. *)
and instance cx (h : handler) outer what =
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
and call_at cx loc f args ev =
  try apply cx f args ev with
  | Builtins.Panic msg -> panic loc msg
  | Panic { loc = l; msg; _ }
    when l.file = Prelude.file && loc.file <> Prelude.file ->
      (* the prelude's source can't be shown, so a panic inside it is the
         program's call that reached it *)
      panic loc msg

(* Call [f], passing it the evidence [ev]. Returns its result, or the
   error it failed with, and the final value of every parameter, so the
   caller can write back the ones passed `inout`. *)
and apply cx f args ev =
  match f with
  | VBuiltin _ -> builtin cx f args
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
        match finish cx None (start cx f cells ev) with
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
   one. A top-level function's hidden type parameters hold what its value
   was given for them where it was used. *)
and start cx f cells ev =
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
  | VFn (p, tys, dicts) ->
      let f =
        match Hashtbl.find_opt cx.fns p with
        | Some f -> f
        | None -> bug ("a call of `" ^ Path.local p ^ "`, which doesn't exist")
      in
      if List.length tys <> List.length f.tys then
        bug
          ("a call of `" ^ Path.local p
         ^ "` with the wrong number of type descriptors");
      if List.length dicts <> List.length f.dicts then
        bug
          ("a call of `" ^ Path.local p
         ^ "` with the wrong number of dictionaries");
      let env =
        List.fold_left2
          (fun env (v : var) t -> Env.add v.id (ref (VType t)) env)
          Env.empty f.tys tys
      in
      let env =
        List.fold_left2
          (fun env (v : var) d -> Env.add v.id (ref d) env)
          env f.dicts dicts
      in
      run cx
        (List.map (fun (p : param) -> p.var.id) f.params)
        f.ev.id f.body env
  | VClosure { params; ev; body; env } -> run cx params ev body env
  | _ -> bug "a call to something that isn't a function"

(* A call in tail position, which [finish] makes: a built-in's value, or
   its error, or the callee's body as far as the call it ends in. *)
and enter cx f args ev =
  match f with
  | VBuiltin _ -> Done (ok (fst (builtin cx f args)))
  | _ -> start cx f (List.map ref args) ev

(* A call of a built-in function, which [apply] returns. *)
and builtin cx f args =
  match f with
  | VBuiltin (Show, tys) -> (
      (* the one built-in that needs its argument's type, which is what its
         type variable stands for *)
      match (tys, args) with
      | [ t ], [ v ] ->
          (Ok (VStr (Shown.shown ~own:(own_show cx) cx.types t v)), args)
      | _ -> bug "a call of `show` with the wrong number of arguments")
  | VBuiltin (x, _) -> (
      match Builtins.run x args with
      | v, finals -> (Ok v, finals)
      | exception Builtins.Fail err -> (Error err, args))
  | _ -> bug "a call of a built-in that isn't one"

(* How the type [p], given [args], shows [v] (Shown.own): through the
   `show` method of its own that lowering found for it (Core.program), if
   it has one, unless that's where this is. The method's type variables
   are the type's parameters, in order, so it's given [args] for them. *)
and own_show cx (p : Path.t) args v : Shown.own =
  match Hashtbl.find_opt cx.shows p with
  | Some _ when List.mem p cx.showing -> Inside
  | Some m when Hashtbl.mem cx.fns m -> (
      let cx = { cx with showing = p :: cx.showing } in
      let dicts = known_dicts cx (Hashtbl.find cx.fns m) args in
      match apply cx (VFn (m, args, dicts)) [ v ] (VEvidence []) with
      | Ok (VStr s), _ -> Itself s
      | _ -> Declared)
  | _ -> Declared

(* ---- dictionaries ----

   A requirement's dictionary for a type the running program knows
   (core.ml, [dict]): `eq`, `hash` and ordering by the walk over the type
   (walk.ml), through its key, if it has one; and an operator or an
   associated value by [Int]'s and [Float]'s own, or by the member of the
   type that gives it (Core.program's [ops]), or, for an opaque type that
   has none, what it's represented as has, which the value is: a `with
   numeric` type's. *)

(* The walk's view of the program: its types, and how to find a value's
   key. *)
and walk cx : Walk.cx = { types = cx.types; key = key_of cx }

(* [v]'s key, and its type, if [v]'s type, [p] given [args], has one: its
   `key` method's result, given [args] for its type variables, which are
   the type's parameters, in order, as [own_show]'s are. *)
and key_of cx (p : Path.t) args v =
  match Hashtbl.find_opt cx.keys p with
  | Some m when Hashtbl.mem cx.fns m -> (
      let f = Hashtbl.find cx.fns m in
      let k =
        match f.scheme.ty with
        | Fun (_, r, _, _, _) -> Walk.subst args r
        | _ -> bug "a key that isn't a function"
      in
      match
        apply cx (VFn (m, args, known_dicts cx f args)) [ v ] (VEvidence [])
      with
      | Ok key, _ -> Some (k, key)
      | Error _, _ -> bug "a key that failed")
  | _ -> None

(* [req]'s dictionary for [t]. *)
and known cx req (t : Ty.ty) : Value.dict =
  match req with
  | "eq" -> Eq (Walk.equal (walk cx) t)
  | "hash" -> Hash (Walk.hash (walk cx) t)
  | "ord" -> Ord (Walk.compare (walk cx) t)
  | "zero" | "one" -> Const (constant cx req t)
  | _ -> Op (operator cx req t)

(* The associated value [req], `zero` or `one`, of [t]. *)
and constant cx req (t : Ty.ty) =
  let one = req = "one" in
  match t with
  | Con (p, []) when p = Path.prelude "Int" -> VInt (if one then 1L else 0L)
  | Con (p, []) when p = Path.prelude "Float" -> VFloat (if one then 1. else 0.)
  | Con (p, args) -> (
      match (Hashtbl.find_opt cx.ops (p, req), Hashtbl.find_opt cx.types p) with
      | Some m, _ -> (
          match Hashtbl.find_opt cx.values m with
          | Some v -> v
          | None ->
              bug ("the value `" ^ Path.local m ^ "` used before it's made"))
      | None, Some { body = Opaque (Rep rep); _ } ->
          constant cx req (Walk.subst args rep)
      | _ -> bug ("`" ^ req ^ "` of a type that hasn't it"))
  | _ -> bug ("`" ^ req ^ "` of a type that hasn't it")

(* The operator [req], `add`, of [t]: given where it's used and where its
   operands are, for a panic, and their values. *)
and operator cx req (t : Ty.ty) =
  match t with
  | Con (p, []) when p = Path.prelude "Int" || p = Path.prelude "Float" ->
      number_op req
  | Con (p, args) -> (
      match (Hashtbl.find_opt cx.ops (p, req), Hashtbl.find_opt cx.types p) with
      | Some m, _ ->
          fun loc _ vs ->
            let f = Hashtbl.find cx.fns m in
            ok
              (fst
                 (call_at cx loc
                    (VFn (m, args, known_dicts cx f args))
                    vs (VEvidence [])))
      | None, Some { body = Opaque (Rep rep); _ } ->
          operator cx req (Walk.subst args rep)
      | _ -> fun _ _ _ -> bug ("`" ^ req ^ "` of a type that hasn't it"))
  | _ -> fun _ _ _ -> bug ("`" ^ req ^ "` of a type that hasn't it")

(* What a function of [f]'s scheme is given for its requirements, for the
   types [tys] its type variables stand for: each one's dictionary, as
   [known]. *)
and known_dicts cx (f : fn_def) tys =
  List.map (fun (n, req) -> VDict (known cx req (List.nth tys n))) f.scheme.reqs

(* The dictionary [d] stands for (core.ml, [dict]): what a hidden
   dictionary parameter holds, or one derived for the type its descriptor
   describes, with what the hidden type parameters it's built from
   hold. *)
and dict cx env (d : Core.dict) : Value.dict =
  match d with
  | Dict_param v -> dict_in env v
  | Derived { req; ddesc; _ } -> known cx req (type_of env ddesc)

(* An error nothing handled, which the top-level function [p] failed
   with, shown through the types its errors' payloads have there. *)
let error_of cx p err =
  match
    Option.map (fun (f : fn_def) -> f.scheme.ty) (Hashtbl.find_opt cx.fns p)
  with
  | Some (Fun (_, _, errs, _, _)) ->
      Shown.value ~own:(own_show cx) cx.types (Errors errs) err
  | _ -> Value.show err

(* The top-level function [p], as the runtime calls it, from outside the
   program: nothing there knows what its type variables stand for, so its
   value is given each as a type variable nothing decided, and a value of
   that type is shown by its shape alone (shown.ml). *)
let from_outside cx (p : Path.t) =
  match Hashtbl.find_opt cx.fns p with
  | Some f ->
      let tys = List.mapi (fun n _ -> Ty.Var n) f.tys in
      VFn (p, tys, known_dicts cx f tys)
  | None -> bug ("a call of `" ^ Path.local p ^ "`, which doesn't exist")

(* The panic, to raise, for a program that called too deeply, past
   [max_depth] or past OCaml's own stack, from the function [p] it
   started: it has a bug, so it's a panic, not an error. *)
let overflowed cx (p : Path.t) =
  match Hashtbl.find_opt cx.fns p with
  | Some f ->
      Panic
        {
          loc = f.loc;
          msg = "the stack overflowed: a function called itself too deeply";
          wrap = None;
        }
  | None ->
      bug ("a call too deep from `" ^ Path.local p ^ "`, which isn't there")

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
      shows = Hashtbl.create 16;
      keys = Hashtbl.create 16;
      ops = Hashtbl.create 16;
      showing = [];
      depth = ref 0;
    }
  in
  List.iter
    (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns;
      List.iter (fun (p, m) -> Hashtbl.replace cx.shows p m) m.shows;
      List.iter (fun (p, k) -> Hashtbl.replace cx.keys p k) m.keys;
      List.iter (fun (r, o) -> Hashtbl.replace cx.ops r o) m.ops)
    modules;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun p ->
          match fst (apply cx (from_outside cx p) [] (VEvidence [])) with
          | Ok v -> Hashtbl.replace cx.values p v
          | Error err -> raise (Uncaught (error_of cx p err))
          (* caught here, not by whoever called [load], so that `ren test`,
             which loads outside any test, reports it as `ren run` does *)
          | exception (Stack_overflow | Too_deep) -> raise (overflowed cx p))
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
  let cx = load modules in
  if not (Hashtbl.mem cx.fns start) then bug "a program with no `main`";
  match fst (apply cx (from_outside cx start) [] (VEvidence [])) with
  | Ok v -> v
  | Error err -> raise (Uncaught (error_of cx start err))
  | exception (Stack_overflow | Too_deep) -> raise (overflowed cx start)

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
    | None -> bug (what ^ " with `" ^ Path.local p ^ "` not made")
  in
  (* the instance of the prelude's handler [name], given [args] *)
  let instance_of name args =
    match
      apply cx (from_outside cx (Path.prelude name)) args (VEvidence [])
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
              impl = value (Path.member (Path.prelude dep) "real");
              outer = [];
            };
          ]
        else
          List.map
            (fun (dep, impl) -> { dep; impl; outer = [] })
            (instance_of handler args))
      [
        ( "Clock",
          "test_clock",
          [ value (Path.member (Path.prelude "Time") "epoch") ] );
        ("Random", "test_random", [ VInt (Int64.of_int seed) ]);
        ("Console", "test_console", []);
        ("Fs", "mem_fs", [ VArray [||] ]);
        ("Os", "test_os", [ VArray [||] ]);
        ("Proc", "test_proc", [ VArray [||] ]);
      ]
  in
  let outcome =
    try
      match fst (apply cx (from_outside cx fn) [] (VEvidence installed)) with
      | Ok _ -> Passed
      | Error err -> Failed (error_of cx fn err)
    with
    | (Panic _ | Assert_failed _) as e -> Panicked e
    | Stack_overflow | Too_deep -> Panicked (overflowed cx fn)
  in
  (* what the test `Console` kept, asked of it as the test would *)
  let console =
    List.find_map
      (fun (i : installed) ->
        match i.impl with
        | VRecord ops when i.dep = Path.prelude "TestConsole" -> (
            match apply cx (List.assoc "output" ops) [] (VEvidence []) with
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
