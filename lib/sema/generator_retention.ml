(* A generator may suspend a child that owns an instance, even when its
   own dependency row and lexical `with`s are empty. Track those sources
   through locals and captures; constructing one doesn't start it. The
   caller repeats this analysis to a fixed point over generator summaries. *)

open Ast
open Ast.Resolved
open Infer_env

module Ids = Set.Make (Int)
module Locals = Map.Make (Int)
module Paths = Set.Make (struct
  type t = Path.t
  let compare = compare
end)

type value = {
  sources : Ids.t;
  captures : Ids.t;
  blocks : expr Locals.t;
  factories : Paths.t;
}

let empty =
  { sources = Ids.empty; captures = Ids.empty;
    blocks = Locals.empty; factories = Paths.empty }

let union a b =
  { sources = Ids.union a.sources b.sources;
    captures = Ids.union a.captures b.captures;
    blocks = Locals.union (fun _ a _ -> Some a) a.blocks b.blocks;
    factories = Paths.union a.factories b.factories }

type state = {
  locals : value Locals.t;
  present : Ids.t;
  active : Ids.t;
  ended : Ids.t;
}

type exit = Next | Broke | Returned | Failed
type flow = (exit * state * value) list

let same_value a b =
  Ids.equal a.sources b.sources && Ids.equal a.captures b.captures
  && Locals.equal (fun a b -> a.node = b.node) a.blocks b.blocks
  && Paths.equal a.factories b.factories

let same a b =
  Locals.equal same_value a.locals b.locals
  && Ids.equal a.present b.present && Ids.equal a.active b.active
  && Ids.equal a.ended b.ended

let join a b =
  { locals = Locals.union (fun _ a b -> Some (union a b)) a.locals b.locals;
    present = Ids.union a.present b.present;
    active = Ids.union a.active b.active;
    ended = Ids.inter a.ended b.ended }

let combine flows =
  List.fold_left
    (fun result (how, state, value) ->
      match List.find_opt (fun (h, _, _) -> h = how) result with
      | None -> (how, state, value) :: result
      | Some (_, previous, v) ->
          (how, join previous state, union v value)
          :: List.filter (fun (h, _, _) -> h <> how) result)
    [] flows

let continue flows f =
  List.concat_map
    (function Next, state, value -> f state value | other -> [ other ])
    flows
  |> combine

let normal state value = [ (Next, state, value) ]

type context = {
  summary : Path.t -> bool;
  factory : Path.t -> bool;
  type_of : int -> Types.ty option;
  fact : int -> Infer_env.found option;
  risky : (int, bool) Hashtbl.t;
  depends : (int, Ids.t) Hashtbl.t;
  mutable held : bool;
  mutable piped : value list;
  mutable epoch : int;
}

let summary env path =
  match Hashtbl.find_opt env.generators path with
  | Some d -> d.gen_with
  | None -> (
      match Hashtbl.find_opt env.generator_signatures path with
      | Some g -> g.holds_instance
      | None -> true)

let is_factory env path =
  Hashtbl.mem env.generators path
  || Hashtbl.mem env.generator_signatures path

let rec closure cx seen sources =
  Ids.fold
    (fun source all ->
      if Ids.mem source all then all
      else
        let all = Ids.add source all in
        match Hashtbl.find_opt cx.depends source with
        | Some more -> closure cx all more
        | None -> all)
    sources seen

(* Blocks capture by reference. Consult the current local as well as the
   capture recorded at creation, so later assignments cannot hide a source. *)
let reachable cx state value =
  let rec from seen value =
    let sources = Ids.union value.sources value.captures in
    Locals.fold
      (fun id block sources ->
        if Ids.mem id seen then sources
        else
          let seen = Ids.add id seen in
          let rec referenced sources (e : expr) =
            let sources =
              match e.kind with
              | Var (Local b) -> (
                  match Locals.find_opt b.id state.locals with
                  | Some v -> Ids.union sources (from seen v)
                  | None -> sources)
              | _ -> sources
            in
            List.fold_left referenced sources (Ast.children e)
          in
          referenced sources block)
      value.blocks sources
  in
  closure cx Ids.empty (from Ids.empty value)

let active cx state value =
  let sources = Ids.diff (reachable cx state value) state.ended in
  { state with active = Ids.union state.active sources }

let ended state sources =
  { state with active = Ids.diff state.active sources;
               ended = Ids.union state.ended sources }

let observe cx lexical state =
  if lexical
     || Ids.exists
          (fun id -> Option.value (Hashtbl.find_opt cx.risky id) ~default:false)
          (closure cx Ids.empty state.active)
  then cx.held <- true

let producer_of_cursor path =
  let name = Ty.generator_cursor_name path in
  Path.make path.Path.home (String.sub name 0 (String.length name - 7))

let result_source cx (e : expr) =
  match cx.type_of e.node with
  | Some t -> (
      match Types.chase t with
      | Types.TGen g -> Some g.gpath
      | Types.TCon (p, _) when Ty.is_generator_cursor p ->
          Some (producer_of_cursor p)
      | _ -> None)
  | None -> None

let factory_at cx (e : expr) =
  match cx.fact e.node with
  | Some (Gen_call path) -> Some path
  | _ -> (
      match e.kind with
      | Var (Global path) when cx.factory path -> Some path
      | _ -> None)

let create cx state (e : expr) paths arguments =
  let captures =
    List.fold_left
      (fun all value -> Ids.union all (reachable cx state value))
      Ids.empty arguments
  in
  let previous = Option.value (Hashtbl.find_opt cx.depends e.node) ~default:Ids.empty in
  let depends = Ids.union previous captures in
  if not (Ids.equal previous depends) then cx.epoch <- cx.epoch + 1;
  Hashtbl.replace cx.depends e.node depends;
  let risk = Paths.exists cx.summary paths in
  let previous = Option.value (Hashtbl.find_opt cx.risky e.node) ~default:false in
  if risk && not previous then cx.epoch <- cx.epoch + 1;
  Hashtbl.replace cx.risky e.node (risk || previous);
  let state =
    { state with present = Ids.add e.node state.present;
                 ended = Ids.remove e.node state.ended }
  in
  normal state { empty with sources = Ids.singleton e.node }

let remove state gone =
  { state with present = Ids.diff state.present gone;
               active = Ids.diff state.active gone;
               ended = Ids.diff state.ended gone }

let temporaries cx before state value =
  let kept =
    Locals.fold
      (fun _ v kept -> Ids.union kept (reachable cx state v))
      state.locals (Ids.union before.present (reachable cx state value))
  in
  remove state (Ids.diff state.present kept)

let scope cx before flows =
  List.map
    (fun (how, state, value) ->
      let locals = Locals.filter (fun id _ -> Locals.mem id before.locals) state.locals in
      let kept =
        if how = Next then Ids.union before.present (reachable cx state value)
        else before.present
      in
      let kept = Locals.fold
          (fun _ value kept -> Ids.union kept (reachable cx state value)) locals kept in
      let state = remove state (Ids.diff state.present kept) in
      (how, { state with locals }, value))
    flows
  |> combine

let rec bind_pattern state value (p : pattern) =
  let add b = { state with locals = Locals.add b.id value state.locals } in
  match p.pkind with
  | PVar b -> add b
  | PAs (p, b) -> bind_pattern (add b) value p
  | PSeq s ->
      let state = match s.middle with
        | Some { rname = Some b; _ } -> add b
        | _ -> state in
      List.fold_left (fun state p -> bind_pattern state value p)
        state (Ast.seq_pieces s)
  | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps ->
      List.fold_left (fun state p -> bind_pattern state value p) state ps
  | PRecord (_, fs) | PCon_named (_, fs) ->
      List.fold_left (fun state (_, p) -> bind_pattern state value p) state fs.fpats
  | PFail_in b -> add b
  | PWild | PInt _ | PBool _ | PStr _ | PFail_any -> state

let rec eval cx lexical state (e : expr) : flow =
  let go = eval cx lexical in
  match e.kind with
  | Var (Local b) ->
      normal state (Option.value (Locals.find_opt b.id state.locals) ~default:empty)
  | Var (Global path) when cx.factory path ->
      normal state { empty with factories = Paths.singleton path }
  | Piped -> normal state (match cx.piped with v :: _ -> v | [] -> empty)
  | Lambda _ ->
      let value = { empty with blocks = Locals.singleton e.node e } in
      normal state { value with captures = reachable cx state value }
  | Handler _ -> normal state empty
  | Yield value ->
      continue (go state value) (fun state _ ->
          observe cx lexical state;
          normal state empty)
  | Yield_from source ->
      continue (go state source) (fun state value ->
          let state = active cx state value in
          observe cx lexical state;
          normal (ended state value.sources) empty)
  | Return value ->
      let flow = match value with Some e -> go state e | None -> normal state empty in
      List.map (fun (how, state, v) -> (if how = Next then Returned else how), state, v) flow
  | Break -> [ (Broke, state, empty) ]
  | Todo -> [ (Returned, state, empty) ]
  | Fail (_, arguments) ->
      List.map (fun (how, state, v) -> (if how = Next then Failed else how), state, v)
        (eval_all cx lexical state (List.map snd arguments))
  | Attempt body ->
      List.map (fun (how, state, v) -> (if how = Failed then Next else how), state, v)
        (go state body)
  | Block (statements, last) -> block cx lexical state statements last
  | If (condition, yes, no) ->
      continue (go state condition) (fun state _ ->
          let yes () = go state yes in
          let no () = match no with Some e -> go state e | None -> normal state empty in
          match condition.kind with
          | Bool true -> yes ()
          | Bool false -> no ()
          | _ -> combine (yes () @ no ()))
  | Binop ((And | Or as op), left, right, _) ->
      continue (go state left) (fun state value ->
          match left.kind, op with
          | Bool false, And | Bool true, Or -> normal state value
          | Bool _, _ -> go state right
          | _ -> combine (normal state value @ go state right))
  | Match (subject, arms) ->
      let rec fails p =
        match p.pkind with
        | PFail _ | PFail_any | PFail_in _ -> true
        | POr ps -> List.exists fails ps
        | _ -> false
      in
      let inputs = go state subject in
      List.concat_map
        (fun (how, state, value) ->
          let eligible = List.filter (fun a -> fails a.arm_pat = (how = Failed)) arms in
          if how <> Next && how <> Failed || eligible = [] then [ how, state, value ]
          else
            List.concat_map
              (fun a ->
                let inner = bind_pattern state value a.arm_pat in
                let guards = match a.arm_guard with
                  | None -> normal inner empty
                  | Some e -> go inner e in
                scope cx state
                  (continue guards (fun state _ -> go state a.arm_body)))
              eligible)
        inputs
      |> combine
  | With { items; body } ->
      continue (eval_all cx lexical state (Ast.with_links items)) (fun state _ ->
          scope cx state (eval cx true state body))
  | Call (callee, arguments) -> call cx lexical state e callee arguments
  | For { over = Each source; pat; index; body } ->
      continue (go state source) (fun state value ->
          loop cx lexical state value (Some (pat, index)) None body)
  | For { over = Range (lo, hi); pat; index; body } ->
      continue (eval_all cx lexical state [ lo; hi ]) (fun state _ ->
          loop cx lexical state empty (Some (pat, index)) None body)
  | While { cond; body } -> loop cx lexical state empty None (Some cond) body
  | Assign { target; value; _ } ->
      continue (go state value) (fun state value ->
          let rec root e = match e.kind with
            | Var (Local b) -> Some b.id
            | Field (e, _) | Index (e, _) | Slice (e, _, _) -> root e
            | _ -> None in
          let state = match root target with
            | Some id ->
                (* Replaced suspended frames retire to the binding's scope.
                   Keep their active tokens while the new value gets its own. *)
                let value = match target.kind with
                  | Var _ -> value
                  | _ -> union value (Option.value (Locals.find_opt id state.locals) ~default:empty) in
                { state with locals = Locals.add id value state.locals }
            | None -> state in
          normal state empty)
  | Pipe { subject; step } ->
      continue (go state subject) (fun state value ->
          let previous = cx.piped in
          cx.piped <- value :: previous;
          Fun.protect ~finally:(fun () -> cx.piped <- previous)
            (fun () -> go state step))
  | _ -> eval_all cx lexical state (Ast.children e)

and eval_all cx lexical state expressions =
  List.fold_left
    (fun flows e -> continue flows (fun state value ->
         continue (eval cx lexical state e) (fun state v -> normal state (union value v))))
    (normal state empty) expressions

and invoke cx lexical state block arguments =
  match block.kind with
  | Lambda (parameters, body) ->
      let inner = List.fold_left
          (fun (state, args) (p : Resolved.param) ->
            let value, args = match args with v :: xs -> v, xs | [] -> empty, [] in
            ({ state with locals = Locals.add p.pname.id value state.locals }, args))
          (state, arguments) parameters |> fst in
      scope cx state (eval cx lexical inner body)
  | _ -> normal state empty

and call cx lexical state expression callee arguments =
  continue (eval cx lexical state callee) (fun state fn ->
      let flows, values =
        List.fold_left
          (fun (flows, previous) argument ->
            let value = ref empty in
            let flows = continue flows (fun state _ ->
                continue (eval cx lexical state argument) (fun state v ->
                    value := union !value v;
                    normal state empty)) in
            flows, previous @ [ !value ])
          (normal state empty, []) arguments
      in
      continue flows (fun state _ ->
          let factories = match factory_at cx callee with
            | Some p -> Paths.add p fn.factories
            | None -> fn.factories in
          if not (Paths.is_empty factories) then create cx state expression factories values
          else if not (Locals.is_empty fn.blocks) then
            Locals.fold
              (fun _ block flows -> combine (invoke cx lexical state block values @ flows))
              fn.blocks []
          else
            let state = List.fold_left (active cx) (active cx state fn) values in
            match result_source cx expression with
            | Some path -> create cx state expression (Paths.singleton path) values
            | None -> normal state empty))

and block cx lexical before statements last =
  let rec statements_ state finalizers = function
    | [] -> finish finalizers (eval cx lexical state last)
    | Finally f :: rest -> statements_ state (f :: finalizers) rest
    | statement :: rest ->
        let flows = match statement with
          | Let { name; value; _ } ->
              continue (eval cx lexical state value) (fun after value ->
                  let after = { after with locals = Locals.add name.id value after.locals } in
                  normal (temporaries cx state after value) empty)
          | Let_pattern { pat; value; else_ } ->
              let flows = continue (eval cx lexical state value) (fun after value ->
                  let after = bind_pattern after value pat in
                  normal (temporaries cx state after value) empty) in
              (match else_ with None -> flows | Some e -> combine (flows @ eval cx lexical state e))
          | Expr e -> continue (eval cx lexical state e) (fun after _ ->
                normal (temporaries cx state after empty) empty)
          | Finally _ -> assert false in
        let normals, exits = List.partition (fun (how, _, _) -> how = Next) flows in
        let rest = List.concat_map (fun (_, state, _) -> statements_ state finalizers rest) normals in
        combine (rest @ finish finalizers exits)
  and finish finalizers flows =
    List.fold_left
      (fun flows finalizer ->
        List.concat_map
          (fun (how, state, value) ->
            List.map
              (fun (ended, state, _) ->
                (if how = Next && ended = Failed then Failed else how), state, value)
              (invoke cx lexical state finalizer [ empty ]))
          flows |> combine)
      flows finalizers
  in
  scope cx before (statements_ before [] statements)

and loop cx lexical before source binding condition body =
  let bind state = match binding with
    | None -> state
    | Some (pat, index) ->
        let state = bind_pattern state empty pat in
        Option.fold ~none:state ~some:(bind_pattern state empty) index in
  let rec rounds header =
    let epoch = cx.epoch in
    let condition_flow = match condition with
      | None -> normal header empty
      | Some e -> eval cx lexical header e in
    let branches = continue condition_flow (fun state _ ->
        let state = active cx state source in
        scope cx state (eval cx lexical (bind state) body)) in
    let repeated = List.filter_map
        (function Next, state, _ -> Some state | _ -> None) branches in
    let next = List.fold_left join before repeated in
    if not (same header next) || epoch <> cx.epoch then rounds next
    else
      let can_end = match condition with Some { kind = Bool true; _ } -> false | _ -> true in
      let exhausted =
        if not can_end then []
        else continue condition_flow (fun state _ ->
            let state = active cx state source in
            normal (ended state source.sources) empty)
      in
      let exits = List.filter_map
          (function
            | Broke, state, _ -> Some (Next, state, empty)
            | Next, _, _ -> None
            | other -> Some other)
          branches in
      combine (exhausted @ exits)
  in
  match condition with
  | Some { kind = Bool false; _ } -> normal before empty
  | _ -> rounds before

let analyze ~summary ~factory ~type_of ~fact body =
  let cx =
    { summary; factory; type_of; fact;
      risky = Hashtbl.create 8; depends = Hashtbl.create 8;
      held = false; piped = []; epoch = 0 }
  in
  let state =
    { locals = Locals.empty; present = Ids.empty; active = Ids.empty; ended = Ids.empty }
  in
  ignore (eval cx false state body);
  cx.held

let holds env definition =
  analyze ~summary:(summary env) ~factory:(is_factory env)
    ~type_of:(Hashtbl.find_opt definition.gen_nodes)
    ~fact:(Hashtbl.find_opt definition.gen_facts)
    definition.gen_fn.body
