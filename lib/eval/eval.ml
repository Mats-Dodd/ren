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
   slow way; Stage 11 makes it cheap.

   A [Fail] raises [Failed], an OCaml exception, which the nearest [Handle]
   catches. It never leaves the interpreter: a call returns what its
   callee failed with as a [result] (OCaml's [Ok v] or [Error e]), so it
   can write its `inout` arguments back first, and if `main` fails, [run]
   raises [Uncaught] instead. *)

open Core
open Value

exception Panic of Loc.t * string
exception Uncaught of Value.t

let panic loc msg = raise (Panic (loc, msg))

(* An error on its way to the [Handle] that catches it. *)
exception Failed of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: checking or lowering let through " ^ what)

(* Structural equality. Functions have no meaningful equality, so comparing
   them panics; Stage 9's operators will turn that into a type error. *)
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
  | _ -> a = b

(* The program's top-level functions, by path, its associated values
   once they're made, and the implementation of each dependency installed
   around `main`, by the dependency's path. *)
type ctx = {
  fns : (Path.t, fn_def) Hashtbl.t;
  values : (Path.t, Value.t) Hashtbl.t;
  mutable installed : (Path.t * Value.t) list;
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
  | Dep_op (p, op) -> (
      (* the operation of the implementation installed: the type checker
         made sure there's one *)
      match List.assoc_opt p cx.installed with
      | Some (VRecord ops) -> List.assoc op ops
      | _ -> bug ("a call of `" ^ p.name ^ "." ^ op ^ "` with nothing installed")
      )
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
  | Call (f, args) ->
      let f = eval cx env f in
      (* an `inout` argument is a local: read it now, and write the
         parameter's final value back once the call returns *)
      let values =
        eval_all cx env
          (List.map (function Value a -> a | Ref v -> local v e.loc) args)
      in
      let result, finals =
        try apply cx f values with
        | Prelude.Panic msg -> panic e.loc msg
        | Panic (l, msg)
          when l.file = Prelude.file && e.loc.file <> Prelude.file ->
            (* the prelude's source can't be shown, so a panic inside it is
               the program's call that reached it *)
            panic e.loc msg
      in
      (* written back whether the call failed or not: failing doesn't undo
         what it changed (errors.md, "Failure and `&`") *)
      List.iter2
        (fun a v -> match a with Ref x -> cell env x := v | Value _ -> ())
        args finals;
      ok result
  | Lambda { params; captures; body } ->
      (* copy the captured variables' values now, into cells of the
         lambda's own: assigning to a variable later doesn't change what
         the lambda sees *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (ref !(cell env v)) inner)
          Env.empty captures
      in
      VClosure
        { params = List.map (fun (p : param) -> p.var.id) params; body; env }
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

(* Evaluate [es] left to right. (A `let` in [::]'s head fixes the order.) *)
and eval_all cx env = function
  | [] -> []
  | e :: rest ->
      let v = eval cx env e in
      v :: eval_all cx env rest

(* Call [f]. Returns its result, or the error it failed with, and the final
   value of every parameter, so the caller can write back the ones passed
   `inout`. *)
and apply cx f args =
  let run params body env =
    let cells = List.map ref args in
    let env =
      List.fold_left2 (fun env id c -> Env.add id c env) env params cells
    in
    let result = try Ok (eval cx env body) with Failed err -> Error err in
    (result, List.map ( ! ) cells)
  in
  match f with
  | VBuiltin name -> (
      match Prelude.find_fn name with
      | Some b ->
          let v, finals = b.eval args in
          (Ok v, finals)
      | None -> bug ("the unknown built-in `" ^ name ^ "`"))
  | VFn p ->
      let f = Hashtbl.find cx.fns p in
      run (List.map (fun (p : param) -> p.var.id) f.params) f.body Env.empty
  | VClosure { params; body; env } -> run params body env
  | _ -> bug "a call to something that isn't a function"

(* Run a program made of [modules] (the prelude, then the user's file),
   starting from the last one's `main`. First each module's associated
   values are made, in order: a module's after those of every module it
   imports, which come before it, and within a module in the order
   lowering gives, each after every value it uses. If `main`, or making a
   value, fails, nothing handles the error: [Uncaught]. *)
let run (modules : program list) =
  let cx =
    { fns = Hashtbl.create 16; values = Hashtbl.create 16; installed = [] }
  in
  List.iter
    (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns)
    modules;
  let entry = List.nth modules (List.length modules - 1) in
  match Hashtbl.find_opt cx.fns (Path.make entry.home "main") with
  | None -> bug "a program with no `main`"
  | Some f -> (
      (* the runtime installs the real implementation of each built-in
         dependency `main` uses, around it; the type checker made sure
         it uses no other (deps.md, "`main`") *)
      let installs () =
        match f.scheme.ty with
        | Fun (_, _, _, uses) ->
            List.filter_map
              (fun (l : Ty.label) ->
                let p = Ty.dep_path l.name in
                if
                  p.home = Path.prelude_home
                  && List.mem p.name Prelude.runtime_deps
                then
                  Some
                    (p, Hashtbl.find cx.values (Path.prelude (p.name ^ ".real")))
                else None)
              uses.labels
        | _ -> []
      in
      (* OCaml's own stack runs out when a Ren function calls itself too
         deeply; that's the program's fault, so it's a panic *)
      let call p =
        match fst (apply cx (VFn p) []) with
        | Ok v -> v
        | Error err -> raise (Uncaught err)
      in
      try
        List.iter
          (fun (m : program) ->
            List.iter (fun p -> Hashtbl.replace cx.values p (call p)) m.values)
          modules;
        cx.installed <- installs ();
        call f.path
      with Stack_overflow ->
        panic f.loc "the stack overflowed: a function called itself too deeply")
