(* A tree-walking interpreter: the "interpreted Ren" milestone on the roadmap.

   For now, mistakes like calling an unknown function are only caught when the
   offending code runs. Later stages move these checks into a type checker so
   they fire before the program starts. *)

open Ast

type value = VInt of int | VBool of bool | VUnit

let show_value = function
  | VInt n -> string_of_int n
  | VBool b -> string_of_bool b
  | VUnit -> "()"

let type_name = function VInt _ -> "Int" | VBool _ -> "Bool" | VUnit -> "Unit"

(* Variables in scope: an immutable map from name to value. Map.Make is a
   functor: a function from a module (String) to a module (Env). *)
module Env = Map.Make (String)

let type_error loc expected v =
  Diag.error loc
    (Printf.sprintf "expected a `%s` here, but this is a `%s`" expected
       (type_name v))

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
  | Eq, x, y when type_name x = type_name y -> VBool (x = y)
  | Neq, x, y when type_name x = type_name y -> VBool (x <> y)
  | _ ->
      Diag.error loc
        (Printf.sprintf "`%s` can't be used on `%s` and `%s`"
           (binop_to_string op) (type_name a) (type_name b))

let rec eval fns env (e : expr) =
  match e.kind with
  | Int n -> VInt n
  | Bool b -> VBool b
  | Var x -> (
      match Env.find_opt x env with
      | Some v -> v
      | None ->
          Diag.error e.loc (Printf.sprintf "there's no variable named `%s`" x))
  | Unop (Neg, a) -> (
      match eval fns env a with
      | VInt n -> VInt (-n)
      | v -> type_error a.loc "Int" v)
  | Binop (op, a, b) -> binop e.loc op (eval fns env a) (eval fns env b)
  | If (c, t, f) -> (
      match eval fns env c with
      | VBool true -> eval fns env t
      | VBool false -> eval fns env f
      | v -> type_error c.loc "Bool" v)
  | Call (name, args) -> call fns e.loc name (List.map (eval fns env) args)
  | Block (stmts, last) ->
      let exec env = function
        | Let { name; value; _ } -> Env.add name.name (eval fns env value) env
        | Expr e ->
            ignore (eval fns env e);
            env
      in
      eval fns (List.fold_left exec env stmts) last

and call fns loc name args =
  match (name.name, args) with
  | "print", [ v ] ->
      print_endline (show_value v);
      VUnit
  | _ -> (
      match Hashtbl.find_opt fns name.name with
      | None ->
          Diag.error name.loc
            (Printf.sprintf "there's no function named `%s`" name.name)
      | Some f ->
          let expected = List.length f.params and given = List.length args in
          if expected <> given then
            Diag.error loc
              (Printf.sprintf "`%s` takes %d argument%s but was given %d"
                 name.name expected
                 (if expected = 1 then "" else "s")
                 given);
          let bind env (p : param) v = Env.add p.pname.name v env in
          eval fns (List.fold_left2 bind Env.empty f.params args) f.body)

let run ~file (prog : program) =
  let fns = Hashtbl.create 16 in
  List.iter
    (fun f ->
      if Hashtbl.mem fns f.name.name then
        Diag.error f.name.loc
          (Printf.sprintf "`%s` is defined more than once" f.name.name);
      Hashtbl.replace fns f.name.name f)
    prog;
  match Hashtbl.find_opt fns "main" with
  | None ->
      Diag.error (Loc.point ~file 1 1)
        ~help:"add `fn main() = ...`, which is where the program starts"
        "this program has no `main` function"
  | Some f -> eval fns Env.empty f.body
