(* Generator suspension is local to the consumer. Scheduler effects are left
   unhandled, so the existing task remains the task executing the producer. *)
open Value

type state = Unstarted | Running | Suspended | Returned | Failed of Value.t | Cancelled

type answer = Item of Value.t | End | Error of Value.t

type fiber = {
  mutable state : state;
  mutable continuation : (unit, answer) Effect.Deep.continuation option;
  run : unit -> unit;
  failure : exn -> Value.t option;
  panic : string -> exn;
  unstarted_close : unit -> unit;
  mutable with_frames : Sched.frame list;
  depth : int ref;
}

type cache = { mutable at : (int * fiber) option }

type replay = {
  spawn : unit -> fiber;
  cache : cache;
  mutable position : int;
  mutable logical : state;
}

type representation = Block of fiber | Replay of replay

type frame = {
  name : string;
  reach : Value.installed list;
  blocks : Value.t list;
  item : Ty.ty option;
  copy_payload : (Value.t -> Value.t) option;
  register_payload : (scope -> Value.t -> unit) option;
  before_step : unit -> unit;
  after_step : unit -> unit;
  projected : bool;
  representation : representation;
  mutable owner : scope option;
}
and scope = {
  mutable tokens : frame list;
  mutable closed : bool;
  mutable closing : bool;
  depth_at_exit : unit -> int;
}

type Value.sched += Frame of frame | Owner of scope
  | Instance_finally of { finally : Value.t option; owner : scope }

type _ Effect.t += Yield_item : Value.t -> unit Effect.t

let yield value = Effect.perform (Yield_item value)

let fiber ?(unstarted_close = fun () -> ()) ?run_at_depth ?unstarted_close_at_depth ~run ~failure ~panic () =
  let depth = ref 0 in
  let run = match run_at_depth with None -> run | Some run -> fun () -> run depth in
  let unstarted_close = match unstarted_close_at_depth with None -> unstarted_close | Some close -> fun () -> close depth in
  { state = Unstarted; continuation = None; run; failure; panic; unstarted_close; with_frames = []; depth }

let execute f resume =
  Effect.Deep.match_with resume ()
    {
      retc = (fun () -> f.state <- Returned; End);
      exnc =
        (fun exn ->
          f.continuation <- None;
          match f.failure exn with
          | Some err -> f.state <- Failed err; Error err
          | None ->
              f.state <- Cancelled;
              if exn = Sched.Cancelled then raise Sched.Cancelled else raise exn);
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Yield_item value ->
              Some
                (fun (k : (a, answer) Effect.Deep.continuation) ->
                  f.continuation <- Some k;
                  f.state <- Suspended;
                  Item value)
          | _ -> None);
    }

(* A producer may suspend inside a direct [with]. Those lexical frames
   remain live, but are not the consumer's current dynamic context. Restore
   only their prefix onto whichever consumer context resumes this fiber. *)
let with_context f run =
  match Sched.current () with
  | None -> run ()
  | Some task ->
      let consumer = task.frames in
      task.frames <- f.with_frames @ consumer;
      Fun.protect
        ~finally:(fun () ->
          f.with_frames <- List.filter (fun frame -> not (List.memq frame consumer)) task.frames;
          task.frames <- consumer)
        run

let step_fiber ?depth f =
  match f.state with
  | Returned -> End
  | Failed error -> Error error
  | Cancelled -> raise (f.panic "a cancelled generator can't be stepped")
  | Running -> raise (f.panic "a running generator can't be stepped again")
  | Unstarted ->
      Option.iter (fun depth -> f.depth := depth) depth;
      f.state <- Running;
      with_context f (fun () -> execute f f.run)
  | Suspended ->
      Option.iter (fun depth -> f.depth := depth + 1) depth;
      let k = Option.get f.continuation in
      f.continuation <- None;
      f.state <- Running;
      (* [k] already includes this fiber's deep handler. Installing a second
         handler would retain an unnecessary handler at every yield. *)
      with_context f (fun () -> Effect.Deep.continue k ())

let close_fiber ?depth f =
  match f.state with
  | Returned | Failed _ | Cancelled -> ()
  | Running -> raise (f.panic "a running generator can't be closed")
  | Unstarted -> Option.iter (fun depth -> f.depth := depth) depth; f.state <- Cancelled; f.unstarted_close ()
  | Suspended ->
      Option.iter (fun depth -> f.depth := depth + 1) depth;
      let k = Option.get f.continuation in
      f.continuation <- None;
      f.state <- Running;
      (match with_context f (fun () -> Sched.shielded (fun () -> Effect.Deep.discontinue k Sched.Cancelled)) with
      | _ -> f.state <- Cancelled
      | exception Sched.Cancelled -> f.state <- Cancelled
      | exception exn -> f.state <- Cancelled; raise exn)

let new_scope ?(depth = fun () -> 0) () = { tokens = []; closed = false; closing = false; depth_at_exit = depth }

let rec map_leaves f = function
  | VSched (Frame frame) -> VSched (Frame (f frame))
  | VCon c -> VCon { c with args = List.map (map_leaves f) c.args }
  | VTag c -> VTag { c with args = List.map (map_leaves f) c.args }
  | VRecord fields ->
      let fields = List.sort (fun (a,_) (b,_) -> String.compare a b) fields in
      VRecord (List.map (fun (k,v) -> k,map_leaves f v) fields)
  | VTuple values -> VTuple (List.map (map_leaves f) values)
  | VArray values -> array (Array.map (map_leaves f) (items values))
  | VTable table -> VTable { table with entries = Ints.map (fun (k,v) -> let k = map_leaves f k in let v = map_leaves f v in k,v) table.entries }
  | value -> value


let rec iter_leaves f = function
  | VSched (Frame frame) -> f frame
  | VCon c -> List.iter (iter_leaves f) c.args
  | VTag c -> List.iter (iter_leaves f) c.args
  | VRecord fields ->
      List.iter (fun (_,v) -> iter_leaves f v)
        (List.sort (fun (a,_) (b,_) -> String.compare a b) fields)
  | VTuple values -> List.iter (iter_leaves f) values
  | VArray values -> for i = 0 to values.len - 1 do iter_leaves f (nth values i) done
  | VTable table -> Ints.iter (fun _ (k,v) -> iter_leaves f k; iter_leaves f v) table.entries
  | _ -> ()


let rec register owner frame =
  if owner.closed then invalid_arg "generator cleanup owner has ended";
  match frame.owner with
  | Some prior when prior == owner -> ()
  | _ ->
      frame.owner <- Some owner; owner.tokens <- frame :: owner.tokens;
      let state = match frame.representation with Block f -> f.state | Replay r -> r.logical in
      (match state with
      | Failed error ->
          (match frame.register_payload with
          | Some register_payload -> register_payload owner error
          | None -> iter_leaves (register owner) error)
      | _ -> ())

let block ?owner ?unstarted_close ?run_at_depth ?unstarted_close_at_depth ?(reach = []) ?(blocks = []) ?item ?copy_payload ?register_payload ?before_step ?after_step ~name ~run ~failure ~panic () =
  let projected = Option.is_some before_step || Option.is_some after_step in
  let before_step = Option.value before_step ~default:(fun () -> ()) and after_step = Option.value after_step ~default:(fun () -> ()) in
  let frame = { name; reach; blocks; item; copy_payload; register_payload; before_step; after_step; projected; representation = Block (fiber ?unstarted_close ?run_at_depth ?unstarted_close_at_depth ~run ~failure ~panic ()); owner = None } in
  Option.iter (fun owner -> register owner frame) owner;
  frame

let replay ?owner ?unstarted_close ?run_at_depth ?unstarted_close_at_depth ?(reach = []) ?(blocks = []) ?item ?copy_payload ?register_payload ?before_step ?after_step ~name ~run ~failure ~panic () =
  let spawn () = fiber ?unstarted_close ?run_at_depth ?unstarted_close_at_depth ~run ~failure ~panic () in
  let projected = Option.is_some before_step || Option.is_some after_step in
  let before_step = Option.value before_step ~default:(fun () -> ()) and after_step = Option.value after_step ~default:(fun () -> ()) in
  let frame = {
    name;
    reach;
    blocks;
    item;
    copy_payload; register_payload;
    before_step; after_step; projected;
    representation = Replay { spawn; cache = { at = None }; position = 0; logical = Unstarted };
    owner = None;
  } in
  Option.iter (fun owner -> register owner frame) owner;
  frame

let state frame =
  match frame.representation with Block f -> f.state | Replay r -> r.logical

let show frame =
  let state = match state frame with
    | Unstarted -> "unstarted" | Running | Suspended -> "suspended"
    | Returned -> "returned" | Failed _ -> "failed" | Cancelled -> "cancelled"
  in
  frame.name ^ ".Cursor(<" ^ state ^ ">)"

let rec fork ?owner frame =
  let representation = match frame.representation with
    | Block _ -> invalid_arg "a block generator cannot be copied as data"
    | Replay r ->
        let logical = match r.logical with
          | Failed error -> Failed (match frame.copy_payload with
              | Some copy -> copy error
              | None -> map_leaves (fork ?owner:None) error)
          | state -> state
        in Replay { r with position = r.position; logical }
  in
  let copy = { frame with representation; owner = None } in
  Option.iter (fun owner -> register owner copy) owner;
  copy

(* A yielded prefix already succeeded. Replaying it uses a neutral caller
   depth, so implementation history does not introduce a depth panic under a
   later, deeper consumer. Actual next/cleanup resumes with the active caller
   depth; all new calls still perform the ordinary depth checks.

   Reconstructing never closes the abandoned cache entry: caches do not own
   cleanup. A source token's eventual close reconstructs its own exact saved
   suspension and unwinds that execution, independently of every other copy. *)
let reconstruct r =
  let f = r.spawn () in
  for _ = 1 to r.position do
    match step_fiber ~depth:0 f with
    | Item _ -> ()
    | End | Error _ -> failwith "bug: pure generator replay changed its prefix"
  done;
  f

let step_raw ?depth frame =
  match frame.representation with
  | Block f ->
      let result = step_fiber ?depth f in
      (match result, frame.owner with
      | Error error, Some owner ->
          (match frame.register_payload with Some register_payload -> register_payload owner error
          | None -> iter_leaves (register owner) error)
      | _ -> ()); result
  | Replay r ->
      match r.logical with
      | Returned -> End
      | Failed error -> Error error
      | Cancelled ->
          let f = r.spawn () in
          raise (f.panic "a cancelled generator can't be stepped")
      | Running ->
          let f = r.spawn () in
          raise (f.panic "a running generator can't be stepped again")
      | Unstarted | Suspended ->
          let f = match r.cache.at with
            | Some (at, f) when at = r.position &&
                (f.state = Unstarted || f.state = Suspended) -> f
            | _ -> reconstruct r
          in
          r.cache.at <- None;
          r.logical <- Running;
          match step_fiber ?depth f with
          | Item value ->
              r.position <- r.position + 1;
              r.logical <- Suspended;
              r.cache.at <- Some (r.position, f);
              Item value
          | End -> r.logical <- Returned; End
          | Error error ->
              r.logical <- Failed error;
              Option.iter (fun owner ->
                match frame.register_payload with Some register_payload -> register_payload owner error
                | None -> iter_leaves (register owner) error) frame.owner;
              Error error
          | exception exn -> r.logical <- Cancelled; raise exn

let close_raw ?depth frame =
  match frame.representation with
  | Block f -> close_fiber ?depth f
  | Replay r ->
      match r.logical with
      | Returned | Failed _ | Cancelled -> ()
      | Running ->
          let f = r.spawn () in
          raise (f.panic "a running generator can't be closed")
      | Unstarted -> r.logical <- Cancelled; close_fiber ?depth (r.spawn ())
      | Suspended ->
          let f = match r.cache.at with
            | Some (at, f) when at = r.position && f.state = Suspended ->
                r.cache.at <- None; f
            | _ -> reconstruct r
          in
          (* A token may claim the cached execution for its own close; the
             cache itself still owns no cleanup. Other copies reconstruct. *)
          r.logical <- Cancelled;
          close_fiber ?depth f

let cancelled frame = match frame.representation with
  | Block f -> f.state <- Cancelled
  | Replay r -> r.logical <- Cancelled

let projected_call ?depth frame run =
  try
    frame.before_step ();
    match run () with
    | result -> frame.after_step (); result
    | exception exn ->
        (try frame.after_step () with _ -> ());
        raise exn
  with exn ->
    (try close_raw ?depth frame with _ -> ());
    cancelled frame;
    raise exn

let step ?depth frame =
  match frame.projected, state frame with
  | true, (Unstarted | Suspended) -> projected_call ?depth frame (fun () -> step_raw ?depth frame)
  | _ -> step_raw ?depth frame

let close ?depth frame =
  match frame.projected, state frame with
  | true, Suspended -> projected_call ?depth frame (fun () -> close_raw ?depth frame)
  | _ -> close_raw ?depth frame

let close_scope ?depth scope =
  if not scope.closed && not scope.closing then begin
    scope.closing <- true;
    let first = ref None in
    let rec drain () = match scope.tokens with
      | [] -> ()
      | frame :: rest ->
          scope.tokens <- rest;
          (match frame.owner with
          | Some owner when owner == scope ->
              frame.owner <- None;
              (try close ~depth:(Option.value depth ~default:(scope.depth_at_exit ())) frame with exn ->
                match !first with None -> first := Some exn | Some _ -> ())
          | _ -> ());
          (* Cleanup can itself create copies in a still-live captured root.
             Registrations made while unwinding are drained before older ones. *)
          drain ()
    in
    drain ();
    scope.closing <- false;
    scope.closed <- true;
    Option.iter raise !first
  end

(* Cursor leaves are runtime-tagged, including when hidden behind a generic
   descriptor or opaque representation. No type-name heuristic decides whether
   an aggregate contains cleanup. Tables cannot have cursor-containing keys,
   since generated cursors deliberately have neither equality nor hashing. *)

let clone ?owner value = map_leaves (fork ?owner) value
let adopt owner value = iter_leaves (register owner) value; value
let detach value = iter_leaves (fun frame -> frame.owner <- None) value; value

(* A closed descriptor can prove the ordinary data fast path. Hidden or
   unresolved representations remain conservative; this includes nested
   cursor leaves independently of the producer's dependency row. *)
(* Core modules contain their source declarations, not primitive types such
   as Int. Seed those descriptors before source declarations override them. *)
let runtime_types declarations =
  Walk.types_of (Prelude.intrinsics.types @ declarations)

let may_cleanup types ty =
  let rec go seen = function
    | Ty.Fun _ | Ty.Impl _ -> false
    | Ty.Var _ | Ty.Error -> true
    | Ty.Errors row -> List.exists (fun (l : Ty.label) -> List.exists (go seen) l.payload) row.labels || row.tail <> None
    | Ty.Variant (p, _, args) -> go seen (Ty.Con (p, args))
    | Ty.Con (p, args) ->
        Ty.is_generator_cursor p || List.exists (go seen) args ||
        if List.mem p seen then false else
        match Hashtbl.find_opt types p with
        | None -> true
        | Some (decl : Iface.type_decl) ->
            let field (f : Iface.field) = go (p :: seen) (Walk.subst args f.fty) in
            match decl.body with
            | Builtin | Dep _ | Dep_alias _ -> false
            | Opaque (Hidden _) -> true
            | Opaque (Rep rep) -> go (p :: seen) (Walk.subst args rep)
            | Record fields -> List.exists field fields
            | Sum ctors -> List.exists (fun (c : Iface.ctor) -> List.exists field c.cfields) ctors
            | Errors errors -> List.exists (function Iface.Tag (_, payload) -> List.exists (go (p :: seen)) payload | Iface.Set path -> go (p :: seen) (Ty.Con (path, []))) errors
  in go [] ty
let to_value frame = VSched (Frame frame)
let of_value = function VSched (Frame frame) -> frame | _ -> invalid_arg "not a generator frame"
let owner_value owner = VSched (Owner owner)
let owner_of_value = function VSched (Owner owner) -> owner | _ -> invalid_arg "not a generator cleanup owner"

let () =
  let previous = !Value.sched_show in
  Value.sched_show := (function Frame frame -> Some (show frame) | handle -> previous handle)

(* Root capabilities are attached to cells, including empty containers.
   Structural hashing would change when a cell is assigned, so use physical
   identity and a constant hash for these short per-execution maps. *)
module Roots = Ephemeron.K1.Make (struct
  type t = Value.t ref
  let equal a b = a == b
  let hash _ = 0
end)


let dynamic_frames frame =
  let rec frame_frames seen frame =
    if List.memq frame seen then [] else
    let seen = frame :: seen in
    let local = match frame.representation with Block f -> f.with_frames | Replay _ -> [] in
    local @ List.concat_map (value_frames seen) frame.blocks
  and value_frames seen = function
    | VSched (Frame frame) -> frame_frames seen frame
    | VClosure closure -> Env.fold (fun _ value frames -> value_frames seen !value @ frames) closure.env []
    | _ -> []
  in frame_frames [] frame

let reaching frame =
  frame.reach @ List.concat_map (fun (frame : Sched.frame) -> frame.installed) (dynamic_frames frame)

(* Only the exiting owner's anonymous results move. A borrowed block handle
   may occur as a lexical result too, and must keep its caller's lifetime. *)
let escape scope parent value =
  iter_leaves (fun frame -> match frame.owner with
    | Some owner when owner != scope -> ()
    | _ -> match parent with
      | Some owner -> register owner frame
      | None -> frame.owner <- None) value;
  value

(* Descriptors let aggregate copying share cleanup-free subtrees. A record
   containing one cursor need not copy an unrelated large Array<Int> field. *)
let rec map_typed types ty f value =
  if not (may_cleanup types ty) then value else
  let go ty value = map_typed types ty f value in
  match value with
  | VSched (Frame frame) -> VSched (Frame (f frame))
  | _ ->
      match Walk.view types ty value with
      | Opaque (_, rep) -> go rep value
      | Elems (elem, values) ->
          if may_cleanup types elem then array (Array.map (go elem) values) else value
      | Parts values -> VTuple (List.map (fun (ty,value) -> go ty value) values)
      | Entries (key, item, table) -> VTable { table with entries = Ints.map (fun (k,v) -> let k = go key k in let v = go item v in k,v) table.entries }
      | Members (elem, table) -> VTable { table with entries = Ints.map (fun (k,v) -> go elem k,v) table.entries }
      | Record { fields; _ } ->
          (match value with
          | VRecord _ ->
              let fields = List.map (fun (name,ty,value) -> name,go ty value) fields in
              VRecord (List.sort (fun (a,_) (b,_) -> String.compare a b) fields)
          | _ -> map_leaves f value)
      | Ctor { fields; _ } ->
          (match value with VCon c -> VCon { c with args = List.map (fun (ty,value) -> go ty value) fields }
          | _ -> map_leaves f value)
      | Tag (_, fields) ->
          (match value with VTag tag -> VTag { tag with args = List.map (fun (ty,value) -> go ty value) fields }
          | _ -> map_leaves f value)
      | Hidden _ | Shape -> map_leaves f value
      | Leaf -> value

let rec iter_typed types ty f value =
  if may_cleanup types ty then
    let go ty value = iter_typed types ty f value in
    match value with
    | VSched (Frame frame) -> f frame
    | _ ->
        match Walk.view types ty value with
        | Opaque (_, rep) -> go rep value
        | Elems (elem, values) -> if may_cleanup types elem then Array.iter (go elem) values
        | Parts values | Ctor { fields = values; _ } | Tag (_, values) -> List.iter (fun (ty,value) -> go ty value) values
        | Entries (key, item, table) -> Ints.iter (fun _ (k,v) -> go key k; go item v) table.entries
        | Members (elem, table) -> Ints.iter (fun _ (k,_) -> go elem k) table.entries
        | Record { fields; _ } -> List.iter (fun (_,ty,value) -> go ty value) fields
        | Hidden _ | Shape -> iter_leaves f value
        | Leaf -> ()

let clone_typed ?owner types ty value = map_typed types ty (fork ?owner) value
let adopt_typed owner types ty value = iter_typed types ty (register owner) value; value
let detach_typed types ty value = iter_typed types ty (fun frame -> frame.owner <- None) value; value

let escape_typed scope parent types ty value =
  let move frame = match frame.owner with
    | Some owner when owner != scope -> ()
    | _ -> match parent with Some owner -> register owner frame | None -> frame.owner <- None
  in
  (match value with VSched (Frame frame) -> move frame | _ -> iter_typed types ty move value);
  value


let bind_from_typed ~source ~retained owner types ty value =
  map_typed types ty (fun frame -> match frame.owner with
    | Some prior when prior == source -> register owner frame; frame
    | None when not retained -> register owner frame; frame
    | _ -> fork ~owner frame) value
