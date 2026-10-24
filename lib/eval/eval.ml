(* A tree-walking interpreter: the "interpreted Ren" milestone on the roadmap.

   By the time a program gets here it has been checked (check.ml, mut.ml)
   and type-checked (infer.ml), so it can't add a Bool to an Int, call a
   function that doesn't exist, or change a `let`. The only errors left are
   panics, like division by zero. A panic is the running program's fault,
   not a mistake in its source, so it's an exception of its own rather than
   a diagnostic.

   Values are never changed in place. A variable is a cell ([ref]) holding a
   value, and assigning to `user.plan` or `xs[i]` builds a new value and puts
   it in the cell, so a value some other name holds can't change under it.
   That's value semantics, done the slow way; Stage 11 makes it cheap. *)

open Ast
open Value

exception Panic of Loc.t * string

let panic loc msg = raise (Panic (loc, msg))

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: the type checker let through " ^ what)

(* Structural equality. Functions have no meaningful equality, so comparing
   them panics; Stage 9's operators will turn that into a type error. *)
let rec equal loc a b =
  match (a, b) with
  | VCon x, VCon y -> x.name = y.name && List.for_all2 (equal loc) x.args y.args
  | VRecord xs, VRecord ys ->
      List.for_all2 (fun (_, x) (_, y) -> equal loc x y) xs ys
  | VArray xs, VArray ys ->
      Array.length xs = Array.length ys && Array.for_all2 (equal loc) xs ys
  | (VClosure _ | VFn _ | VBuiltin _), _ | _, (VClosure _ | VFn _ | VBuiltin _)
    ->
      panic loc "functions can't be compared"
  | _ -> a = b

(* Everything the evaluator looks up by name. *)
type ctx = {
  fns : (string, fn_def) Hashtbl.t;
  ctor_types : (string, string) Hashtbl.t;  (** constructor -> its type *)
}

let binop loc op a b =
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
  | _ -> bug ("`" ^ binop_to_string op ^ "` on the wrong types")

(* ---- places ----

   A place is somewhere a value can be written: a variable's cell, then a
   path of fields and indices into its value, like `user.plan` or
   `grid[i][j]`. Indices are evaluated once, when the place is found. *)

type step = SField of string | SIndex of int * Loc.t

let element loc xs i =
  if i < 0 || i >= Array.length xs then
    panic loc
      (Printf.sprintf "index %d is out of bounds for an array of length %d" i
         (Array.length xs))
  else xs.(i)

let rec get v path =
  match (path, v) with
  | [], v -> v
  | SField f :: rest, VRecord fields -> get (List.assoc f fields) rest
  | SIndex (i, loc) :: rest, VArray xs -> get (element loc xs i) rest
  | _ -> bug "a place of the wrong shape"

(* [v] with the value at [path] replaced by [x]: a new value, sharing
   whatever didn't change. *)
let rec set v path x =
  match (path, v) with
  | [], _ -> x
  | SField f :: rest, VRecord fields ->
      VRecord
        (List.map
           (fun (g, w) -> if g = f then (g, set w rest x) else (g, w))
           fields)
  | SIndex (i, loc) :: rest, VArray xs ->
      let ys = Array.copy xs in
      ys.(i) <- set (element loc xs i) rest x;
      VArray ys
  | _ -> bug "a place of the wrong shape"

(* Match a value against a pattern. On success, return the environment
   extended with the variables the pattern binds. *)
let rec match_pattern (p : pattern) v env =
  match (p.pkind, v) with
  | PWild, _ -> Some env
  | PVar x, _ -> Some (Env.add x (ref v) env)
  | PInt n, VInt m -> if n = m then Some env else None
  | PBool b, VBool c -> if b = c then Some env else None
  | PCon (c, ps), VCon { name; args; _ } when c.name = name ->
      match_all ps args env
  | _ -> None

and match_all ps vs env =
  match (ps, vs) with
  | [], [] -> Some env
  | p :: ps, v :: vs -> Option.bind (match_pattern p v env) (match_all ps vs)
  | _ -> None

let rec eval cx env (e : expr) =
  match e.kind with
  | Int n -> VInt n
  | Bool b -> VBool b
  | Unit -> VUnit
  | Var x -> (
      (* locals shadow top-level functions *)
      match Env.find_opt x env with
      | Some cell -> !cell
      | None when Hashtbl.mem cx.fns x -> VFn x
      | None when Prelude.is_fn x -> VBuiltin x
      | None -> bug ("the unknown name `" ^ x ^ "`"))
  | Unop (Neg, a) -> (
      match eval cx env a with
      | VInt n -> VInt (-n)
      | _ -> bug "`-` on a non-Int")
  | Binop (op, a, b) -> binop e.loc op (eval cx env a) (eval cx env b)
  | If (c, t, f) -> (
      match (eval cx env c, f) with
      | VBool true, _ -> eval cx env t
      | VBool false, Some f -> eval cx env f
      | VBool false, None -> VUnit
      | _ -> bug "a non-Bool `if` condition")
  | Call (f, args) ->
      let f = eval cx env f in
      (* an `&` argument is read from its place, and written back once the
         call returns *)
      let args =
        List.map
          (fun (a : expr) ->
            match a.kind with
            | Ref p ->
                let cell, path = place cx env p in
                (Some (cell, path), get !cell path)
            | _ -> (None, eval cx env a))
          args
      in
      let result, finals = apply cx f (List.map snd args) in
      List.iter2
        (fun (at, _) v ->
          match at with
          | Some (cell, path) -> cell := set !cell path v
          | None -> ())
        args finals;
      result
  | Lambda (params, body) ->
      (* capture the variables' values now, in cells of the lambda's own:
         assigning to a variable later doesn't change what the lambda sees *)
      let env = Env.map (fun cell -> ref !cell) env in
      VClosure { params = List.map (fun p -> p.pname.name) params; body; env }
  | Block (stmts, last) ->
      let exec env = function
        | Let { name; value; _ } ->
            Env.add name.name (ref (eval cx env value)) env
        | Expr e ->
            ignore (eval cx env e);
            env
      in
      eval cx (List.fold_left exec env stmts) last
  | Con (c, args) ->
      (* check.ml has already confirmed the constructor exists *)
      let ty = Hashtbl.find cx.ctor_types c.name in
      VCon
        {
          ty;
          name = c.name;
          args = List.map (fun (_, a) -> eval cx env a) args;
        }
  | Record (_, fields) ->
      let fields =
        List.map (fun ((f : ident), v) -> (f.name, eval cx env v)) fields
      in
      VRecord (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)
  | Field (r, f) -> get (eval cx env r) [ SField f.name ]
  | Array xs -> VArray (Array.of_list (List.map (eval cx env) xs))
  | Index (a, i) -> (
      let a = eval cx env a in
      match eval cx env i with
      | VInt n -> get a [ SIndex (n, e.loc) ]
      | _ -> bug "a non-Int index")
  | Ref a -> eval cx env a
  | Assign { target; op; value } ->
      let cell, path = place cx env target in
      let v = eval cx env value in
      let v =
        match op with Some op -> binop e.loc op (get !cell path) v | None -> v
      in
      cell := set !cell path v;
      VUnit
  | For { var; iter = { kind = Ref p; loc }; body } ->
      (* each element is copied into `var`, and written back after each
         pass; mut.ml makes sure the body can't change the array itself *)
      let cell, path = place cx env p in
      let n =
        match get !cell path with
        | VArray xs -> Array.length xs
        | _ -> bug "a `for` loop over a non-Array"
      in
      for i = 0 to n - 1 do
        let at = path @ [ SIndex (i, loc) ] in
        let x = ref (get !cell at) in
        ignore (eval cx (Env.add var.name x env) body);
        cell := set !cell at !x
      done;
      VUnit
  | For { var; iter; body } -> (
      match eval cx env iter with
      | VArray xs ->
          Array.iter
            (fun x -> ignore (eval cx (Env.add var.name (ref x) env) body))
            xs;
          VUnit
      | _ -> bug "a `for` loop over a non-Array")
  | Match (subject, arms) ->
      let v = eval cx env subject in
      let guard_passes env = function
        | None -> true
        | Some g -> (
            match eval cx env g with
            | VBool b -> b
            | _ -> bug "a non-Bool guard")
      in
      let rec first = function
        | [] -> panic e.loc "no arm of this `match` matched"
        | a :: rest -> (
            match match_pattern a.arm_pat v env with
            | Some env when guard_passes env a.arm_guard ->
                eval cx env a.arm_body
            | _ -> first rest)
      in
      first arms

(* The cell and path a place expression names (mut.ml has checked it is
   one). *)
and place cx env (e : expr) =
  match e.kind with
  | Var x -> (
      match Env.find_opt x env with
      | Some cell -> (cell, [])
      | None -> bug ("an assignment to `" ^ x ^ "`, which isn't a variable"))
  | Field (r, f) ->
      let cell, path = place cx env r in
      (cell, path @ [ SField f.name ])
  | Index (a, i) -> (
      let cell, path = place cx env a in
      match eval cx env i with
      | VInt n -> (cell, path @ [ SIndex (n, e.loc) ])
      | _ -> bug "a non-Int index")
  | _ -> bug "an assignment to something that isn't a place"

(* Call [f]. Returns its result and the final value of every parameter, so
   the caller can write back the ones it passed with `&`. *)
and apply cx f args =
  let run params body env =
    let cells = List.map ref args in
    let env =
      List.fold_left2 (fun env x c -> Env.add x c env) env params cells
    in
    let result = eval cx env body in
    (result, List.map ( ! ) cells)
  in
  match (f, args) with
  | VBuiltin name, _ -> (
      match Prelude.find_fn name with
      | Some b -> b.eval args
      | None -> bug ("the unknown built-in `" ^ name ^ "`"))
  | VFn name, _ ->
      let f = Hashtbl.find cx.fns name in
      run (List.map (fun p -> p.pname.name) f.params) f.body Env.empty
  | VClosure { params; body; env }, _ -> run params body env
  | _ -> bug "a call to something that isn't a function"

let run (prog : program) =
  let cx = { fns = Hashtbl.create 16; ctor_types = Hashtbl.create 16 } in
  List.iter
    (function
      | Fn f -> Hashtbl.replace cx.fns f.name.name f
      | Type { type_name; type_body = Ctors cs; _ } ->
          List.iter
            (fun c ->
              Hashtbl.replace cx.ctor_types c.ctor_name.name type_name.name)
            cs
      | Type { type_body = Fields _; _ } -> ())
    prog;
  match Hashtbl.find_opt cx.fns "main" with
  | None -> bug "a program with no `main`"
  | Some f -> (
      (* OCaml's own stack runs out when a Ren function calls itself too
         deeply; that's the program's fault, so it's a panic *)
      try fst (apply cx (VFn f.name.name) [])
      with Stack_overflow ->
        panic f.name.loc
          "the stack overflowed: a function called itself too deeply")
