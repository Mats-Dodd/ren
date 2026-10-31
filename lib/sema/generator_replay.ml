(* An empty dependency row does not by itself make replay deterministic:
   runtime/task intrinsics, and dictionaries or descriptions whose code is
   unknown, can still observe ambient state. This private summary is separate
   from the language's effect rows. It adds no constraints to inference. *)

open Ast
open Ast.Resolved
open Infer_env

module Locals = Map.Make (Int)

type value = { description : bool; callable : callable option }
and callable =
  | Function of Path.t
  | Primitive of Intrinsic.t * Types.ty option
  | Closure of context * param list * expr
and context = {
  env : Infer_env.env;
  definition : replay_def;
  locals : value Locals.t;
  stack : Path.t list;
  unsafe : bool ref;
}

let unknown = { description = false; callable = None }
let description = { unknown with description = true }
let merge a b =
  { description = a.description && b.description;
    callable = (match a.callable, b.callable with
      | Some (Function a), Some (Function b) when a = b -> Some (Function a)
      | _ -> None) }

let mark cx condition = if condition then cx.unsafe := true
let type_at cx node = Hashtbl.find_opt cx.definition.replay_nodes node
let fact_at cx node = Hashtbl.find_opt cx.definition.replay_facts node
let path_unsafe env path = Hashtbl.mem env.replay_unsafe path

let ambient (x : Intrinsic.t) =
  Prelude.reaches x <> None
  || match x with
  | Journal_kept | Journal_gave | Journal_answer | Journal_outputs | Journal_load
  | Scope_run | Task_spawn | Task_until | Arm_release | Arm_retake
  | Task_timeout | Task_isolate | Task_map | Task_each | Task_both | Task_race
  | Task_beside | Task_background | Background_spawn | Task_produce | Task_map_pull
  | Outbox_send | Inbox_take | Async_yield | Async_tick | Runtime_single
  | Runtime_sim | Runtime_leave | Sim_time | Sim_sleep | Sim_advance | Sim_alarm
  | Async_worker | Task_random | Task_drain | Family_open | Family_call
  | Family_make | Family_keys | Family_evict | Family_evictable | Family_counts
  | Family_close | Family_pin | Family_visit | Family_idle | Family_edge
  | Family_enter | Family_post | Family_hold | Family_kept -> true
  | _ -> false

(* Follow the same key/provider choices as lowering. A hidden representation
   has no private structural dictionary summary, so cannot establish safety.
   Recursive data stops at the second visit to its declaration. *)
let implicit_unsafe env path =
  match Prelude.find path with
  | Some intrinsic -> ambient intrinsic
  | None ->
      if path.Path.home = env.home && not (Hashtbl.mem env.replay_defs path) then
        match env.group with
        | (caller, _) :: _ -> raise (Unchecked {caller; callee = path})
        | [] -> true
      else path_unsafe env path

let rec dispatch env seen req ty =
  let recurse = dispatch env seen req in
  match Types.repr ty with
  | TError -> false
  | TVar _ | TSkol _ -> true
  | TGen g -> path_unsafe env g.gpath
  | TFun _ | TImpl _ -> req <> "show"
  | TErrors row ->
      let labels, tail = Types.row_parts row in
      List.exists (fun (l : Types.label) -> List.exists recurse l.payload) labels
      || tail <> None
  | TVariant (p, _, args) -> dispatch env seen req (TCon (p, args))
  | TCon (p, args) ->
      if List.mem p seen then List.exists recurse args
      else if Ty.is_generator_cursor p then false (* stable opaque show *)
      else
        let seen = p :: seen in
        let recurse = dispatch env seen req in
        let apply t = Types.of_ty ~vars:(fun i -> Option.value (List.nth_opt args i) ~default:Types.TError) ~tails:(fun _ -> Types.REmpty) t in
        let fields fs = List.exists (fun (f : Iface.field) -> recurse (apply f.fty)) fs in
        let member name = Path.member p name in
        match Hashtbl.find_opt env.types p with
        | None -> true
        | Some td ->
            if req = "show" && (Iface.find_member td "show" <> None
                                  || path_unsafe env (member "show")) then
              implicit_unsafe env (member "show")
            else if List.mem req ["eq"; "hash"; "ord"] && Iface.key td <> None then
              (match Iface.key td with
              | Some (path, result) -> implicit_unsafe env path || recurse (apply result)
              | None -> assert false)
            else if not (List.mem req ["eq"; "hash"; "ord"; "show"]) then
              (match Iface.provider td req with
              | Some (path, op) ->
                  implicit_unsafe env path
                  || List.exists (fun (i, r) ->
                      match List.nth_opt args i with
                      | Some t -> dispatch env seen r t
                      | None -> true) op.oscheme.reqs
              | None ->
                  if td.numeric <> None || p = Path.prelude "Int"
                     || p = Path.prelude "Float" then false else true)
            else
              match td.body with
              | Builtin -> List.exists recurse args
              | Record fs -> fields fs
              | Sum cs -> List.exists (fun (c : Iface.ctor) -> fields c.cfields) cs
              | Opaque (Rep t) -> recurse (apply t)
              | Opaque (Hidden _) -> true
              | Errors es -> List.exists (function
                  | Iface.Tag (_, ts) -> List.exists (fun t -> recurse (apply t)) ts
                  | Iface.Set _ -> true) es
              | Dep _ | Dep_alias _ -> req <> "show"

let function_params ty =
  match Option.map Types.repr ty with
  | Some (TFun (ps, _, _, _)) -> List.map (fun (p : Types.param) -> p.ty) ps
  | _ -> []

let primitive_unsafe env intrinsic ty =
  let params = function_params ty in
  let at i req = match List.nth_opt params i with
    | Some t -> dispatch env [] req t | None -> true in
  let element req = match params with
    | t :: _ -> (match Types.repr t with
        | TCon (_, t :: _) -> dispatch env [] req t
        | _ -> true)
    | _ -> true in
  let key req = match params with
    | t :: _ -> (match Types.repr t with
        | TCon (_, t :: _) -> dispatch env [] req t
        | _ -> true)
    | _ -> true in
  ambient intrinsic
  || match intrinsic with
  | Show -> at 0 "show"
  | Hash -> at 0 "hash"
  | Array_sort -> element "ord"
  | Map_of -> (* its Array<(K,V)> argument *)
      (match params with
      | t :: _ -> (match Types.repr t with
          | TCon (_, [t]) -> (match Types.repr t with
              | TCon (_, key :: _) -> dispatch env [] "hash" key
              | _ -> true)
          | _ -> true)
      | _ -> true)
  | Map_get | Map_set | Map_remove | Map_includes
  | Set_add | Set_remove | Set_includes -> key "hash"
  | Set_of -> element "hash"
  | Call_first_hash | Call_max | Call_min | Call_fold -> true
  | _ -> false

let rec bind_pattern locals (p : pattern) value =
  match p.pkind with
  | PVar b -> Locals.add b.id value locals
  | PAs (p, b) -> Locals.add b.id value (bind_pattern locals p value)
  | POr ps -> List.fold_left (fun ls p -> bind_pattern ls p value) locals ps
  | PCon (_, ps) | PFail (_, ps) | PTuple ps ->
      List.fold_left (fun ls p -> bind_pattern ls p unknown) locals ps
  | PCon_named (_, fs) | PRecord (_, fs) ->
      List.fold_left (fun ls (_, p) -> bind_pattern ls p unknown) locals fs.fpats
  | PSeq q ->
      let locals = List.fold_left (fun ls p -> bind_pattern ls p unknown)
          locals (q.front @ q.back) in
      (match Option.bind q.middle (fun r -> r.rname) with
      | Some b -> Locals.add b.id unknown locals
      | None -> locals)
  | PWild | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> locals

let rec expression cx (e : expr) =
  let inspect e = ignore (expression cx e) in
  let check req e = match type_at cx e.node with
    | Some t -> mark cx (dispatch cx.env [] req t)
    | None -> mark cx true in
  let operator node operand =
    match fact_at cx node with
    | Some (Method_of p) -> mark cx (path_unsafe cx.env p)
    | Some (Generic_op req) -> check req operand
    | _ -> () in
  (match fact_at cx e.node with
  | Some (Method_of p) when Prelude.find p = None
      && not (Ty.is_generator_cursor (Path.owner p)) ->
      mark cx (implicit_unsafe cx.env p)
  | Some (Generic_op req) ->
      Option.iter (fun t -> mark cx (dispatch cx.env [] req t)) (type_at cx e.node)
  | _ -> ());
  match e.kind with
  | Var (Global p | Global_value p) ->
      (match Prelude.find p with
      | Some intrinsic ->
          mark cx (primitive_unsafe cx.env intrinsic (type_at cx e.node));
          { unknown with callable = Some (Primitive (intrinsic, type_at cx e.node)) }
      | None ->
          mark cx (path_unsafe cx.env p);
          { unknown with callable = Some (Function p) })
  | Var (Intrinsic intrinsic) ->
      mark cx (primitive_unsafe cx.env intrinsic (type_at cx e.node));
      { unknown with callable = Some (Primitive (intrinsic, type_at cx e.node)) }
  | Var (Local b) ->
      if b.bound = By_var || b.bound = By_inout then unknown
      else Option.value (Locals.find_opt b.id cx.locals) ~default:unknown
  | Call (callee, arguments) ->
      let arguments = match fact_at cx e.node with
        | Some (Args normalized) -> normalized
        | _ -> arguments in
      let actuals = List.map (expression cx) arguments in
      let target, actuals = callee_value cx callee actuals in
      invoke cx target actuals
  | Lambda (params, body) ->
      let nested = {cx with locals = List.fold_left (fun ls (p : param) ->
          Locals.add p.pname.id unknown ls) cx.locals params} in
      ignore (expression nested body);
      { unknown with callable = Some (Closure (cx, params, body)) }
  | Handler { state; arms; _ } ->
      let nested = statements cx state in
      List.iter (fun a -> ignore (expression nested a.arm_impl)) arms;
      description
  | Inline_handler body -> inspect body; description
  | Block (stmts, last) -> expression (statements cx stmts) last
  | With { items; body } ->
      List.iter (fun item -> List.iter (fun link ->
          let value = expression cx link.link in
          (* A wrapper is callable instead of a description. Its known body
             is followed with an unknown body callback, which is harmless by
             itself; executing an unknown description inside it is not. *)
          if not value.description then
            match value.callable, Option.map Types.repr (type_at cx link.link.node) with
            | Some _, Some (TFun _) -> ignore (invoke cx value [unknown])
            | _ -> mark cx true) item.chain) items;
      expression cx body
  | Field (receiver, member) ->
      (match fact_at cx e.node with
      | Some (Method_of path) ->
          inspect receiver;
          (match Prelude.find path with
          | Some intrinsic ->
              mark cx (primitive_unsafe cx.env intrinsic (type_at cx e.node));
              {unknown with callable = Some (Primitive (intrinsic, type_at cx e.node))}
          | None ->
              mark cx (path_unsafe cx.env path);
              {unknown with callable = Some (Function path)})
      | Some (Calls_op _) ->
          let value = expression cx receiver in
          mark cx (not value.description); unknown
      | Some (Generic_op req) -> inspect receiver; check req receiver; unknown
      | _ ->
          inspect receiver;
          if member.name = "hash" then check "hash" receiver;
          unknown)
  | If (condition, yes, no) ->
      inspect condition;
      merge (expression cx yes)
        (match no with Some no -> expression cx no | None -> unknown)
  | Match (subject, arms) ->
      let subject = expression cx subject in
      let values = List.map (fun arm ->
          let nested = {cx with locals = bind_pattern cx.locals arm.arm_pat subject} in
          Option.iter (fun e -> ignore (expression nested e)) arm.arm_guard;
          expression nested arm.arm_body) arms in
      (match values with [] -> unknown | v :: vs -> List.fold_left merge v vs)
  | Binop (op, left, right, node) ->
      inspect left; inspect right; operator node left;
      (match op with
      | Eq | Neq -> check "eq" left
      | Lt | Le | Gt | Ge -> check "ord" left
      | _ -> ());
      unknown
  | Unop (_, operand, node) -> inspect operand; operator node operand; unknown
  | Assign {target;value;op;onode} ->
      inspect target; inspect value;
      Option.iter (fun _ -> operator onode target) op; unknown
  | Interp pieces ->
      List.iter (function Lit _ -> () | Hole e -> inspect e; check "show" e) pieces;
      unknown
  | Ref e | Named (_, e) | Try e | Attempt e | Release e | Return (Some e) ->
      expression cx e
  | _ -> List.iter inspect (Ast.children e); unknown

and statements cx stmts =
  List.fold_left (fun cx -> function
    | Let {name;value;_} ->
        let value = expression cx value in
        {cx with locals = Locals.add name.id value cx.locals}
    | Let_pattern {pat;value;else_;_} ->
        let value = expression cx value in
        Option.iter (fun e -> ignore (expression cx e)) else_;
        {cx with locals = bind_pattern cx.locals pat value}
    | Expr e | Finally e -> ignore (expression cx e); cx) cx stmts

and callee_value cx (callee : expr) arguments =
  match callee.kind with
  | Var (Global p | Global_value p) ->
      (match Prelude.find p with
      | Some x ->
          ({unknown with callable = Some (Primitive (x, type_at cx callee.node))}, arguments)
      | None -> ({unknown with callable = Some (Function p)}, arguments))
  | Var (Intrinsic x) ->
      ({unknown with callable = Some (Primitive (x, type_at cx callee.node))}, arguments)
  | Field (receiver, _) ->
      (match fact_at cx callee.node with
      | Some (Method_of p) ->
          let value = expression cx receiver in
          (match Prelude.find p with
          | Some x ->
              ({unknown with callable = Some (Primitive (x, type_at cx callee.node))}, value :: arguments)
          | None -> ({unknown with callable = Some (Function p)}, value :: arguments))
      | _ -> expression cx callee, arguments)
  | _ -> expression cx callee, arguments

and invoke cx target arguments =
  match target.callable with
  | Some (Primitive (intrinsic, ty)) ->
      mark cx (primitive_unsafe cx.env intrinsic ty); unknown
  | Some (Function path) ->
      (match Prelude.find path with
      | Some intrinsic -> mark cx (primitive_unsafe cx.env intrinsic None); unknown
      | None ->
          match Hashtbl.find_opt cx.env.replay_defs path with
          | Some definition when not (List.mem path cx.stack)
              && (match Hashtbl.find_opt definition.replay_nodes definition.replay_fn.body.node with
                  | Some t -> (match Types.repr t with TImpl _ | TFun _ -> true | _ -> false)
                  | None -> false) ->
              let locals = List.mapi (fun i (p : param) ->
                  p.pname.id, Option.value (List.nth_opt arguments i) ~default:unknown)
                  definition.replay_fn.params
                |> List.fold_left (fun ls (id,v) -> Locals.add id v ls) Locals.empty in
              expression {cx with definition; locals; stack = path :: cx.stack}
                definition.replay_fn.body
          | _ ->
              mark cx (path_unsafe cx.env path);
              (* An imported descriptor producer is certified by its summary:
                 unknown returned provenance itself makes the producer unsafe.
                 Its dependency/error rows still receive the ordinary checks. *)
              if path.Path.home <> cx.env.home && not (path_unsafe cx.env path)
                 && (match Hashtbl.find_opt cx.env.globals path with
                     | Some ty -> (match Types.repr ty with
                         | TFun (_, ret, _, _) ->
                             (match Types.repr ret with TImpl _ -> true | _ -> false)
                         | _ -> false)
                     | None -> false)
              then description else unknown)
  | Some (Closure (captured, params, body)) ->
      let locals = List.mapi (fun i (p : param) ->
          p.pname.id, Option.value (List.nth_opt arguments i) ~default:unknown) params
        |> List.fold_left (fun ls (id,v) -> Locals.add id v ls) captured.locals in
      expression {captured with locals; unsafe = cx.unsafe; stack = cx.stack} body
  | None ->
      (* Blocks are second class: they cannot be stored/returned, and a
         Value_gen cannot capture an external function parameter. Thus an
         unknown ordinary block parameter ultimately comes from an actual
         lambda/global/generator source scanned in this body or its caller.
         Description execution and unresolved dictionaries have their own
         conservative checks above; neither is trusted by this case. *)
      unknown

let unsafe env path definition =
  let result = ref false in
  let cx = {env; definition; locals = Locals.empty; stack = [path]; unsafe = result} in
  let value = expression cx definition.replay_fn.body in
  (match type_at cx definition.replay_fn.body.node with
  | Some ty -> (match Types.repr ty with
      | TImpl _ -> mark cx (not value.description)
      | _ -> ())
  | None -> ());
  Hashtbl.iter (fun _ fact -> match fact with
      | Pulled {what = Cursor path; _}
          when not (Ty.is_generator_cursor (Path.owner path)) ->
          mark cx (implicit_unsafe env path)
      | Gen_step path -> mark cx (path_unsafe env path)
      | _ -> ()) definition.replay_facts;
  (* Calls can require implicit key/operator code without an explicit AST
     method reference. The solver has already recorded each decided use. *)
  Hashtbl.iter (fun _ (required : Infer_env.required) ->
      List.iter (fun (id,req) ->
          match List.assoc_opt id required.uinst with
          | Some ty -> mark cx (dispatch env [] req ty)
          | None -> ()) required.udone) definition.replay_required;
  !result

let update env =
  let changed = ref true in
  while !changed do
    changed := false;
    Hashtbl.iter (fun path definition ->
        if not (path_unsafe env path) && unsafe env path definition then (
          Hashtbl.replace env.replay_unsafe path ();
          changed := true)) env.replay_defs
  done;
  Hashtbl.iter (fun path definition ->
      definition.gen_unsafe <- path_unsafe env path) env.generators
