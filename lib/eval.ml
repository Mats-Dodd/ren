(* A tree-walking interpreter: the "interpreted Ren" milestone on the roadmap.

   By the time a program gets here it has been checked (check.ml) and
   type-checked (infer.ml), so it can't add a Bool to an Int or call a
   function that doesn't exist. The only errors left are panics, like
   division by zero. *)

open Ast

(* Variables in scope: an immutable map from name to value. Map.Make is a
   functor: a function from a module (String) to a module (Env). *)
module Env = Map.Make (String)

type value =
  | VInt of int
  | VBool of bool
  | VUnit
  | VCon of { ty : string; name : string; args : value list }
      (** [Pro(5)]: the type it belongs to, the constructor, its fields *)
  | VRecord of (string * value) list
      (** fields sorted by name, so structural equality ignores field order *)
  | VClosure of { params : string list; body : expr; env : value Env.t }
      (** a lambda, with the variables it captured when it was created *)
  | VFn of string  (** a top-level function used as a value *)
  | VBuiltin of string  (** [print] *)

let rec show_value = function
  | VInt n -> string_of_int n
  | VBool b -> string_of_bool b
  | VUnit -> "()"
  | VCon { name; args = []; _ } -> name
  | VCon { name; args; _ } ->
      name ^ "(" ^ String.concat ", " (List.map show_value args) ^ ")"
  | VRecord fields ->
      let show_field (f, v) = f ^ ": " ^ show_value v in
      "{ " ^ String.concat ", " (List.map show_field fields) ^ " }"
  | VClosure _ -> "<fn>"
  | VFn name | VBuiltin name -> "<fn " ^ name ^ ">"

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: the type checker let through " ^ what)

(* Structural equality. Functions have no meaningful equality, so comparing
   them panics; Stage 8's `ops` will turn that into a type error. *)
let rec equal loc a b =
  match (a, b) with
  | VCon x, VCon y -> x.name = y.name && List.for_all2 (equal loc) x.args y.args
  | VRecord xs, VRecord ys ->
      List.for_all2 (fun (_, x) (_, y) -> equal loc x y) xs ys
  | (VClosure _ | VFn _ | VBuiltin _), _ | _, (VClosure _ | VFn _ | VBuiltin _)
    ->
      Diag.error loc "panic: functions can't be compared"
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
  | (Div | Mod), VInt _, VInt 0 -> Diag.error loc "panic: division by zero"
  | Div, VInt x, VInt y -> VInt (x / y)
  | Mod, VInt x, VInt y -> VInt (x mod y)
  | Lt, VInt x, VInt y -> VBool (x < y)
  | Le, VInt x, VInt y -> VBool (x <= y)
  | Gt, VInt x, VInt y -> VBool (x > y)
  | Ge, VInt x, VInt y -> VBool (x >= y)
  | Eq, x, y -> VBool (equal loc x y)
  | Neq, x, y -> VBool (not (equal loc x y))
  | _ -> bug ("`" ^ binop_to_string op ^ "` on the wrong types")

(* Match a value against a pattern. On success, return the environment
   extended with the variables the pattern binds. *)
let rec match_pattern (p : pattern) v env =
  match (p.pkind, v) with
  | PWild, _ -> Some env
  | PVar x, _ -> Some (Env.add x v env)
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
      | Some v -> v
      | None when Hashtbl.mem cx.fns x -> VFn x
      | None when x = "print" -> VBuiltin x
      | None -> bug ("the unknown name `" ^ x ^ "`"))
  | Unop (Neg, a) -> (
      match eval cx env a with
      | VInt n -> VInt (-n)
      | _ -> bug "`-` on a non-Int")
  | Binop (op, a, b) -> binop e.loc op (eval cx env a) (eval cx env b)
  | If (c, t, f) -> (
      match eval cx env c with
      | VBool true -> eval cx env t
      | VBool false -> eval cx env f
      | _ -> bug "a non-Bool `if` condition")
  | Call (f, args) ->
      let f = eval cx env f in
      apply cx f (List.map (eval cx env) args)
  | Lambda (params, body) ->
      VClosure { params = List.map (fun p -> p.pname.name) params; body; env }
  | Block (stmts, last) ->
      let exec env = function
        | Let { name; value; _ } -> Env.add name.name (eval cx env value) env
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
  | Field (r, f) -> (
      match eval cx env r with
      | VRecord fields -> (
          match List.assoc_opt f.name fields with
          | Some v -> v
          | None -> bug ("the missing field `" ^ f.name ^ "`"))
      | _ -> bug "a field access on a non-record")
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
        | [] -> Diag.error e.loc "panic: no arm of this `match` matched"
        | a :: rest -> (
            match match_pattern a.arm_pat v env with
            | Some env when guard_passes env a.arm_guard ->
                eval cx env a.arm_body
            | _ -> first rest)
      in
      first arms

and apply cx f args =
  let bind env name v = Env.add name v env in
  match f with
  | VBuiltin "print" ->
      List.iter (fun v -> print_endline (show_value v)) args;
      VUnit
  | VFn name ->
      let f = Hashtbl.find cx.fns name in
      let names = List.map (fun p -> p.pname.name) f.params in
      eval cx (List.fold_left2 bind Env.empty names args) f.body
  | VClosure { params; body; env } ->
      eval cx (List.fold_left2 bind env params args) body
  | _ -> bug "a call to something that isn't a function"

let run ~file (prog : program) =
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
  | None ->
      Diag.error (Loc.point ~file 1 1)
        ~help:"add `fn main() = ...`, which is where the program starts"
        "this program has no `main` function"
  | Some f -> apply cx (VFn f.name.name) []
