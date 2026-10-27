(* Mem Lint: check a Mem IR program (mem.ml) again, from scratch, as
   Core Lint checks Core.

   It checks that every variable is defined before it's used, in a scope
   around the use, as C's blocks scope them, and defined once; that every
   operand has the layout its operation needs and every variable the
   layout of what it's given; that only counted values are counted; that a
   call passes what its callee takes, and that only a [Call_fails] calls a
   function that can fail; that a [Break] is inside its [Loop], a [Jump]
   inside the [Joins] it goes to, and a [Raise] inside the [Catch] it goes
   to, or in a function that can fail; and that an [Alloc] keeps its
   counted fields first.

   Anything it finds is a bug in the compiler, which fails with [Failure],
   and the driver reports as an internal compiler error. `ren build` runs
   it on every program, and so do the tests. *)

open Mem
module Ids = Set.Make (Int)

let sprintf = Printf.sprintf

type env = {
  fns : (string, fn) Hashtbl.t;
  fn : fn;  (** the function being checked *)
  defined : Ids.t;  (** the variables in scope here *)
  seen : (int, unit) Hashtbl.t;  (** every variable defined so far *)
  loops : int list;
  joins : int list;
  catches : int list;
}

let fail env msg = failwith (sprintf "Mem Lint, in %s: %s" env.fn.name msg)

let atom_layout (x : atom) : layout =
  match x with
  | Var v -> v.layout
  | Int _ -> Int
  | Float _ -> Float
  | Bool _ -> Bool
  | Unit -> Unit
  | Enum_tag _ -> Enum
  | Scalar_ctor _ | Lit _ -> Boxed

let use env (v : var) =
  if not (Ids.mem v.id env.defined) then
    fail env (sprintf "%s is used where it isn't defined" (show_var v))

let atom env x =
  (match x with Var v -> use env v | _ -> ());
  atom_layout x

let expect env what (want : layout) (got : layout) =
  if want <> got then
    fail env
      (sprintf "%s is %s, but should be %s" what (show_layout got)
         (show_layout want))

let operand env what want x =
  expect env (what ^ " " ^ show_atom x) want (atom env x)

let define env (v : var) =
  if Hashtbl.mem env.seen v.id then
    fail env (sprintf "%s is defined twice" (show_var v));
  Hashtbl.replace env.seen v.id ();
  { env with defined = Ids.add v.id env.defined }

(* What the runtime's [rt] takes and gives. *)
let rt_sig (rt : rt) : layout list * layout =
  match rt with
  | Array_len -> ([ Boxed ], Int)
  | Array_get l -> ([ Boxed; Int ], l)
  | Array_set l -> ([ Boxed; Int; l ], Boxed)
  | Array_push l -> ([ Cell Boxed; l ], Unit)
  | Str_len -> ([ Boxed ], Int)
  | Str_concat -> ([ Boxed; Boxed ], Boxed)
  | Str_eq -> ([ Boxed; Boxed ], Bool)
  | Show_int -> ([ Int ], Boxed)
  | Show_float -> ([ Float ], Boxed)
  | Show_bool -> ([ Bool ], Boxed)
  | Float_of_int -> ([ Int ], Float)
  | Float_sqrt -> ([ Float ], Float)
  | Float_round | Float_truncate -> ([ Float ], Int)
  | Wrapping _ -> ([ Int; Int ], Int)
  | Wrapping_neg -> ([ Int ], Int)
  | Console_write | Console_error -> ([ Boxed ], Unit)

let args env what (want : layout list) xs =
  if List.length want <> List.length xs then
    fail env
      (sprintf "%s is given %d operands, not %d" what (List.length xs)
         (List.length want));
  List.iter2 (fun l x -> operand env what l x) want xs

let callee env name =
  match Hashtbl.find_opt env.fns name with
  | Some f -> f
  | None -> fail env (sprintf "a call of %s, which isn't in the program" name)

(* The layout of what [r] gives. *)
let rhs env (r : rhs) : layout =
  match r with
  | Atom x -> atom env x
  | Arith (op, x, y, _) ->
      let l = atom env x in
      if l <> Int && l <> Float then
        fail env (sprintf "`%s` on %s" (Ast.binop_to_string op) (show_layout l));
      operand env "the right operand" l y;
      l
  | Neg (x, _) ->
      let l = atom env x in
      if l <> Int && l <> Float then fail env "`-` on what isn't a number";
      l
  | Compare (_, x, y) ->
      let l = atom env x in
      (match l with
      | Int | Float | Bool | Unit | Enum -> ()
      | _ -> fail env (sprintf "a comparison of %s" (show_layout l)));
      operand env "the right side" l y;
      Bool
  | Not x ->
      operand env "`not`'s operand" Bool x;
      Bool
  | Tag_of x ->
      (match atom env x with
      | Enum | Boxed -> ()
      | l -> fail env (sprintf "the tag of %s" (show_layout l)));
      Int
  | Field (x, n) ->
      operand env "what a field is read from" Boxed x;
      if n < 0 then fail env "a field before the first";
      (* the field's own layout is the variable's, which the object
         doesn't say: Lint takes it *)
      Unit
  | Alloc { fields; nobjs; _ } ->
      let ls = List.map (atom env) fields in
      let rec firsts n = function
        | [] -> n = 0
        | l :: rest ->
            if n > 0 then counted l && firsts (n - 1) rest
            else not (List.exists counted (l :: rest))
      in
      if not (firsts nobjs ls) then
        fail env
          (sprintf "an object whose %d counted fields aren't the first" nobjs);
      Boxed
  | Alloc_array (l, xs) ->
      List.iter (operand env "an array's element" l) xs;
      Boxed
  | Call (name, xs) ->
      let f = callee env name in
      if f.fails then
        fail env (sprintf "%s, which can fail, called without a status" name);
      args env ("a call of " ^ name)
        (List.map (fun (v : var) -> v.layout) f.params)
        xs;
      f.result
  | Runtime (r, xs, _) ->
      let want, gives = rt_sig r in
      args env (show_rt r) want xs;
      gives
  | Load v -> (
      use env v;
      match v.layout with
      | Cell l -> l
      | l ->
          fail env
            (sprintf "a load from %s, which is %s" (show_var v) (show_layout l))
      )
  | Addr v -> (
      use env v;
      match v.layout with
      | Cell _ ->
          fail env (sprintf "the address of %s, already a cell" (show_var v))
      | l -> Cell l)

let rec stmt env (s : stmt) : env =
  match s with
  | Let (v, r) ->
      let l = rhs env r in
      (match r with Field _ -> () | _ -> expect env (show_var v) v.layout l);
      define env v
  | Decl v -> define env v
  | Set (v, x) ->
      use env v;
      operand env ("what's set to " ^ show_var v) v.layout x;
      env
  | Store (v, x) ->
      use env v;
      (match v.layout with
      | Cell l -> operand env ("what's stored in " ^ show_var v) l x
      | l ->
          fail env
            (sprintf "a store into %s, which is %s" (show_var v) (show_layout l)));
      env
  | Dup x | Drop x | Free x ->
      operand env "what's counted" Boxed x;
      env
  | Do r ->
      ignore (rhs env r);
      env
  | Call_fails { result; fn; args = xs; error; on_error } ->
      let f = callee env fn in
      if not f.fails then
        fail env (sprintf "%s can't fail, but is called as if it can" fn);
      args env ("a call of " ^ fn)
        (List.map (fun (v : var) -> v.layout) f.params)
        xs;
      expect env (show_var result) f.result result.layout;
      expect env (show_var error) Boxed error.layout;
      block (define env error) on_error;
      define env result
  | If (c, t, f) ->
      operand env "a condition" Bool c;
      block env t;
      block env f;
      env
  | Switch (x, cases, default) ->
      operand env "what's switched on" Int x;
      List.iter (fun (_, b) -> block env b) cases;
      block env default;
      env
  | Loop (l, b) ->
      block { env with loops = l :: env.loops } b;
      env
  | Break l ->
      if not (List.mem l env.loops) then
        fail env (sprintf "a break of L%d outside it" l);
      env
  | Joins (b, joins) ->
      block { env with joins = List.map fst joins @ env.joins } b;
      List.iter (fun (_, j) -> block env j) joins;
      env
  | Jump l ->
      if not (List.mem l env.joins) then
        fail env (sprintf "a jump to L%d from outside it" l);
      env
  | Catch { label; body; error; handler } ->
      expect env (show_var error) Boxed error.layout;
      let env = define env error in
      block { env with catches = label :: env.catches } body;
      block env handler;
      env
  | Raise (x, target) ->
      operand env "an error" Boxed x;
      (match target with
      | Some l ->
          if not (List.mem l env.catches) then
            fail env (sprintf "a raise to L%d from outside it" l)
      | None ->
          if not env.fn.fails then
            fail env "a raise in a function that can't fail");
      env
  | Return x ->
      operand env "what's returned" env.fn.result x;
      env
  | Assert (c, _) ->
      operand env "what's asserted" Bool c;
      env
  | Panic _ -> env

(* A block's own definitions end with it. *)
and block env b = ignore (List.fold_left stmt env b)

let fn fns (f : fn) =
  let env =
    {
      fns;
      fn = f;
      defined = Ids.empty;
      seen = Hashtbl.create 64;
      loops = [];
      joins = [];
      catches = [];
    }
  in
  block (List.fold_left define env f.params) f.body

let program (p : program) =
  let fns = Hashtbl.create 64 in
  List.iter
    (fun (f : fn) ->
      if Hashtbl.mem fns f.name then
        failwith ("Mem Lint: two functions named " ^ f.name);
      Hashtbl.replace fns f.name f)
    p.fns;
  List.iter (fn fns) p.fns;
  match Hashtbl.find_opt fns p.start with
  | Some f ->
      if
        f.params <> [] || f.result <> p.start_result || f.fails <> p.start_fails
      then failwith "Mem Lint: `$start` isn't what the program says it is"
  | None -> failwith "Mem Lint: no `$start`"
