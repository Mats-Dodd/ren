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
   slow way; Stage 12 makes it cheap.

   A [Fail] raises [Failed], an OCaml exception, which the nearest [Handle]
   catches. It never leaves the interpreter: a call returns what its
   callee failed with as a [result] (OCaml's [Ok v] or [Error e]), so it
   can write its `inout` arguments back first, and if `main` fails, [run]
   raises [Uncaught] instead.

   What's installed is evidence (core.ml): a value in a variable like any
   other, passed to each call as its hidden parameter. A call of an
   operation finds its dependency's implementation in it by the
   dependency's path, never by a name the program spells. *)

open Core
open Value

exception Panic of Loc.t * string
exception Uncaught of Value.t

exception
  Assert_failed of { loc : Loc.t; sides : (Ty.ty * Value.t * Value.t) option }

let panic loc msg = raise (Panic (loc, msg))

(* An error on its way to the [Handle] that catches it. *)
exception Failed of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: checking or lowering let through " ^ what)

(* Structural equality. Functions have no meaningful equality, so comparing
   them panics; Stage 10's operators will turn that into a type error. *)
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

(* The program's top-level functions, by path, and its associated values
   once they're made. Nothing else is global: what's installed is evidence
   (core.ml), held in a variable like any value. *)
type ctx = {
  fns : (Path.t, fn_def) Hashtbl.t;
  values : (Path.t, Value.t) Hashtbl.t;
}

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
  | As_dep (_, h) -> eval cx env h
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
        raise (Assert_failed { loc = e.loc; sides = Some (a.ty, x, y) });
      VUnit
  | Finally (body, after) -> (
      match eval cx env body with
      | v ->
          ignore (eval cx env after);
          v
      | exception Failed err ->
          ignore (eval cx env after);
          raise (Failed err))

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
  | Prelude.Panic msg -> panic loc msg
  | Panic (l, msg) when l.file = Prelude.file && loc.file <> Prelude.file ->
      (* the prelude's source can't be shown, so a panic inside it is the
         program's call that reached it *)
      panic loc msg

(* Call [f], passing it the evidence [ev]. Returns its result, or the
   error it failed with, and the final value of every parameter, so the
   caller can write back the ones passed `inout`. *)
and apply cx f args ev =
  let run params ev_id body env =
    (match ev with
    | VEvidence _ -> ()
    | _ -> bug ("a call of " ^ describe f ^ " passing something not evidence"));
    if List.length params <> List.length args then
      bug ("a call of " ^ describe f ^ " with the wrong number of arguments");
    let cells = List.map ref args in
    let env =
      List.fold_left2 (fun env id c -> Env.add id c env) env params cells
    in
    let env = Env.add ev_id (ref ev) env in
    let result = try Ok (eval cx env body) with Failed err -> Error err in
    (result, List.map ( ! ) cells)
  in
  match f with
  | VBuiltin name -> (
      match Prelude.find_fn name with
      | Some b -> (
          match b.eval args with
          | v, finals -> (Ok v, finals)
          | exception Prelude.Fail err -> (Error err, args))
      | None -> bug ("the unknown built-in `" ^ name ^ "`"))
  | VFn p ->
      let f =
        match Hashtbl.find_opt cx.fns p with
        | Some f -> f
        | None -> bug ("a call of `" ^ p.name ^ "`, which doesn't exist")
      in
      run
        (List.map (fun (p : param) -> p.var.id) f.params)
        f.ev.id f.body Env.empty
  | VClosure { params; ev; body; env } -> run params ev body env
  | _ -> bug "a call to something that isn't a function"

(* A program's functions, by path, and its associated values, made in
   order: a module's after those of every module it imports, which come
   before it, and within a module in the order lowering gives, each after
   every value it uses, with nothing installed: a value can't use a
   dependency (infer_top.ml). If making one fails, nothing handles the
   error: [Uncaught]. *)
let load (modules : program list) =
  let cx = { fns = Hashtbl.create 16; values = Hashtbl.create 16 } in
  List.iter
    (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns)
    modules;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun p ->
          match fst (apply cx (VFn p) [] (VEvidence [])) with
          | Ok v -> Hashtbl.replace cx.values p v
          | Error err -> raise (Uncaught err))
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
  (* OCaml's own stack runs out when a Ren function calls itself too
     deeply; that's the program's fault, so it's a panic *)
  let overflow () =
    match List.find_opt (fun (f : fn_def) -> f.path = start) entry.fns with
    | Some f ->
        panic f.loc "the stack overflowed: a function called itself too deeply"
    | None -> bug "a program with no `main`"
  in
  try
    let cx = load modules in
    if not (Hashtbl.mem cx.fns start) then bug "a program with no `main`";
    match fst (apply cx (VFn start) [] (VEvidence [])) with
    | Ok v -> v
    | Error err -> raise (Uncaught err)
  with Stack_overflow -> overflow ()

(* ---- tests ---- *)

(* How a test ended. *)
type outcome =
  | Passed
  | Failed of Value.t  (** with this error, which nothing handled *)
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
    match apply cx (VFn (Path.prelude name)) args (VEvidence []) with
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
      match fst (apply cx (VFn fn) [] (VEvidence installed)) with
      | Ok _ -> Passed
      | Error err -> Failed err
    with
    | (Panic _ | Assert_failed _) as e -> Panicked e
    | Stack_overflow ->
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
