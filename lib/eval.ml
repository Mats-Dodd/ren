(* A tree-walking interpreter: the "interpreted Ren" milestone on the roadmap.

   Constructors, record fields and `match` exhaustiveness are checked before
   the program runs (check.ml). Other mistakes, like calling an unknown
   function or adding a Bool to an Int, are still only caught when the
   offending code runs; Stage 3's type checker moves those earlier too. *)

open Ast

type value =
  | VInt of int
  | VBool of bool
  | VUnit
  | VCon of { ty : string; name : string; args : value list }
      (** [Pro(5)]: the type it belongs to, the constructor, its fields *)
  | VRecord of (string * value) list
      (** fields sorted by name, so structural equality ignores field order *)

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

let type_name = function
  | VInt _ -> "Int"
  | VBool _ -> "Bool"
  | VUnit -> "Unit"
  | VCon { ty; _ } -> ty
  | VRecord _ -> "record"

(* Variables in scope: an immutable map from name to value. Map.Make is a
   functor: a function from a module (String) to a module (Env). *)
module Env = Map.Make (String)

(* Everything the evaluator looks up by name. *)
type ctx = {
  fns : (string, fn_def) Hashtbl.t;
  ctor_types : (string, string) Hashtbl.t;  (** constructor -> its type *)
}

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
  | Var x -> (
      match Env.find_opt x env with
      | Some v -> v
      | None ->
          Diag.error e.loc (Printf.sprintf "there's no variable named `%s`" x))
  | Unop (Neg, a) -> (
      match eval cx env a with
      | VInt n -> VInt (-n)
      | v -> type_error a.loc "Int" v)
  | Binop (op, a, b) -> binop e.loc op (eval cx env a) (eval cx env b)
  | If (c, t, f) -> (
      match eval cx env c with
      | VBool true -> eval cx env t
      | VBool false -> eval cx env f
      | v -> type_error c.loc "Bool" v)
  | Call (name, args) -> call cx e.loc name (List.map (eval cx env) args)
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
          | None ->
              Diag.error f.loc
                (Printf.sprintf "this record has no field named `%s`" f.name))
      | v ->
          Diag.error f.loc
            (Printf.sprintf "`.%s` needs a record, but this is a `%s`" f.name
               (type_name v)))
  | Match (subject, arms) ->
      let v = eval cx env subject in
      let guard_passes env = function
        | None -> true
        | Some g -> (
            match eval cx env g with
            | VBool b -> b
            | v -> type_error g.loc "Bool" v)
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

and call cx loc name args =
  match (name.name, args) with
  | "print", [ v ] ->
      print_endline (show_value v);
      VUnit
  | _ -> (
      match Hashtbl.find_opt cx.fns name.name with
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
          eval cx (List.fold_left2 bind Env.empty f.params args) f.body)

let run ~file (prog : program) =
  let cx = { fns = Hashtbl.create 16; ctor_types = Hashtbl.create 16 } in
  List.iter
    (function
      | Fn f ->
          if Hashtbl.mem cx.fns f.name.name then
            Diag.error f.name.loc
              (Printf.sprintf "`%s` is defined more than once" f.name.name);
          Hashtbl.replace cx.fns f.name.name f
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
  | Some f -> eval cx Env.empty f.body
