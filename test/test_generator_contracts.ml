(* Internal contracts that public Ren cannot probe without escaping a scope.
   The assertions compile now; the owning step connects each adapter to the
   real runtime. There is deliberately no model implementation here. An
   adapter translates only the named outcome; unexpected exceptions escape. *)

module type Frame = sig
  type t

  (* A body that records Started, installs its finally, yields once, then
     returns. Its finally records which outcome it was given. *)
  val fresh : unit -> t
  val events : t -> [ `Started | `Finally_cancelled | `Finally_other ] list
  val step : t -> [ `Item | `End | `Cancelled_panic ]
  val close : t -> unit
end

exception Generator_panic of string

module Real_frame : Frame = struct
  type t = {
    frame : Ren.Generator.frame;
    observed : [ `Started | `Finally_cancelled | `Finally_other ] list ref;
  }

  let fresh () =
    let observed = ref [] in
    let note event = observed := !observed @ [ event ] in
    let run () =
      note `Started;
      match Ren.Generator.yield (Ren.Value.VInt 1L) with
      | () -> note `Finally_other
      | exception Ren.Sched.Cancelled ->
          note `Finally_cancelled;
          raise Ren.Sched.Cancelled
    in
    let frame =
      Ren.Generator.block ~name:"contract" ~run ~failure:(fun _ -> None)
        ~panic:(fun message -> Generator_panic message) ()
    in
    { frame; observed }

  let events t = !(t.observed)

  let step t =
    match Ren.Generator.step t.frame with
    | Item (Ren.Value.VInt 1L) -> `Item
    | End -> `End
    | Item _ | Error _ -> failwith "unexpected generator contract answer"
    | exception Generator_panic "a cancelled generator can't be stepped" -> `Cancelled_panic

  let close t = Ren.Generator.close t.frame
end

let frame_adapter : (module Frame) option = Some (module Real_frame)

let suspended_cancel (module F : Frame) =
  let frame = F.fresh () in
  assert (F.events frame = []);
  assert (F.step frame = `Item);
  assert (F.events frame = [ `Started ]);
  F.close frame;
  let ended = [ `Started; `Finally_cancelled ] in
  assert (F.events frame = ended);
  F.close frame;
  assert (F.events frame = ended);
  assert (F.step frame = `Cancelled_panic);
  assert (F.step frame = `Cancelled_panic);
  assert (F.events frame = ended)

let unstarted_cancel (module F : Frame) =
  let frame = F.fresh () in
  assert (F.events frame = []);
  F.close frame;
  assert (F.events frame = []);
  assert (F.step frame = `Cancelled_panic);
  assert (F.step frame = `Cancelled_panic);
  F.close frame;
  assert (F.events frame = [])

let%expect_test "[g1] a cancelled suspended frame stays cancelled and cleans up once" =
  (match frame_adapter with
  | None -> print_endline "skipped until g1: real generator-frame adapter"
  | Some adapter -> suspended_cancel adapter);
  [%expect {| |}]

let%expect_test "[g1] closing an unstarted frame runs no body or cleanup" =
  (match frame_adapter with
  | None -> print_endline "skipped until g1: real generator-frame adapter"
  | Some adapter -> unstarted_cancel adapter);
  [%expect {| |}]

let%expect_test "[g1] rejecting reentrant step and close preserves the running continuation" =
  let open Ren in
  let check make =
    let current = ref None and rejected = ref 0 and completed = ref 0 in
    let reject_running_calls () =
      let frame = Option.get !current in
      assert (Generator.state frame = Running);
      (match Generator.step frame with
      | _ -> failwith "a running generator accepted a reentrant step"
      | exception Generator_panic "a running generator can't be stepped again" ->
          incr rejected);
      assert (Generator.state frame = Running);
      (match Generator.close frame with
      | () -> failwith "a running generator accepted a reentrant close"
      | exception Generator_panic "a running generator can't be closed" ->
          incr rejected);
      assert (Generator.state frame = Running)
    in
    let frame =
      make ~name:"reentrant"
        ~run:(fun () ->
          reject_running_calls ();
          Generator.yield (Value.VInt 1L);
          reject_running_calls ();
          Generator.yield (Value.VInt 2L);
          incr completed)
        ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
    in
    current := Some frame;
    assert (Generator.state frame = Unstarted);
    assert (Generator.step frame = Item (Value.VInt 1L));
    assert (Generator.state frame = Suspended && !rejected = 2);
    assert (Generator.step frame = Item (Value.VInt 2L));
    assert (Generator.state frame = Suspended && !rejected = 4);
    assert (Generator.step frame = End);
    assert (Generator.state frame = Returned && !completed = 1);
    assert (Generator.step frame = End);
    Generator.close frame;
    assert (Generator.state frame = Returned && !completed = 1 && !rejected = 4)
  in
  check (fun ~name ~run ~failure ~panic () -> Generator.block ~name ~run ~failure ~panic ());
  check (fun ~name ~run ~failure ~panic () -> Generator.replay ~name ~run ~failure ~panic ());
  print_endline "block and replay: reentrant step and close rejected; both yields and return preserved";
  [%expect {| block and replay: reentrant step and close rejected; both yields and return preserved |}]

type direction = Pushed | Pulled

module type Depth = sig
  (* The maximum permitted logical generator-call depth, counting the root
     as one. Both paths consume the same straight yield-from chain fully.
     Depth_panic means the recursive-call depth diagnostic, not any panic. *)
  val limit : int
  val consume : direction -> depth:int -> [ `Completed | `Depth_panic ]
end

let depth_adapter : (module Depth) option = None

let depth_boundary (module D : Depth) =
  assert (D.limit > 1);
  List.iter
    (fun direction ->
      assert (D.consume direction ~depth:(D.limit - 1) = `Completed);
      assert (D.consume direction ~depth:D.limit = `Completed);
      assert (D.consume direction ~depth:(D.limit + 1) = `Depth_panic))
    [ Pushed; Pulled ]

let%expect_test "[g4] push and pull share the exact recursive depth boundary" =
  (match depth_adapter with
  | None -> print_endline "skipped until g4: real native generator-depth adapter"
  | Some adapter -> depth_boundary adapter);
  [%expect {| skipped until g4: real native generator-depth adapter |}]

type backend = Mem_fs | Real_fs

module type Reader = sig
  type family
  type reader

  (* A fresh family and reader over a fixture with at least two lines.
     Calls use the same fixture path, including after a family has ended.
     The adapter owns any real temporary file. This probes runtime values
     directly; it does not allow a reader to escape in public Ren source. *)
  val fresh : backend -> family * reader
  val next : reader -> [ `Line | `End | `Closed ]
  val end_family : family -> unit
end

let reader_adapter : (module Reader) option = None

let stale_reader (module R : Reader) backend =
  let family, reader = R.fresh backend in
  let live = ref true in
  Fun.protect
    ~finally:(fun () -> if !live then R.end_family family)
    (fun () ->
      assert (R.next reader = `Line);
      R.end_family family;
      live := false;
      assert (R.next reader = `Closed);
      assert (R.next reader = `Closed);
      let newer, current = R.fresh backend in
      Fun.protect
        ~finally:(fun () -> R.end_family newer)
        (fun () ->
          assert (R.next current = `Line);
          assert (R.next reader = `Closed)))

let%expect_test "[g5] a reader's old incarnation stays Closed after family end" =
  (match reader_adapter with
  | None -> print_endline "skipped until g5: real mem_fs and real_fs reader adapter"
  | Some adapter -> List.iter (stale_reader adapter) [ Mem_fs; Real_fs ]);
  [%expect {| skipped until g5: real mem_fs and real_fs reader adapter |}]

let%expect_test "[g1] replay cache never owns a copy's position terminal state or cancellation" =
  let open Ren in
  let frame =
    Generator.replay ~name:"logical"
      ~run:(fun () ->
        Generator.yield (Value.VInt 1L);
        Generator.yield (Value.VInt 2L))
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  let expect_item frame expected =
    match Generator.step frame with
    | Item (Value.VInt actual) -> assert (actual = expected)
    | _ -> failwith "replay cursor changed the yielded prefix"
  in
  let unstarted = Generator.fork frame in
  expect_item frame 1L;
  expect_item frame 2L;
  assert (Generator.step frame = End);
  assert (Generator.state frame = Returned);
  assert (Generator.state unstarted = Unstarted);
  assert (Generator.show unstarted = "logical.Cursor(<unstarted>)");
  expect_item unstarted 1L;
  assert (Generator.state frame = Returned);
  assert (Generator.show frame = "logical.Cursor(<returned>)");
  let cancelled = Generator.fork unstarted in
  Generator.close cancelled;
  assert (Generator.state cancelled = Cancelled);
  assert (Generator.state unstarted = Suspended);
  assert (Generator.show cancelled = "logical.Cursor(<cancelled>)");
  (match Generator.step cancelled with
  | _ -> failwith "cancelled replay cursor produced an answer"
  | exception Generator_panic "a cancelled generator can't be stepped" -> ());
  expect_item unstarted 2L;
  assert (Generator.step unstarted = End);
  Generator.close frame;
  Generator.close unstarted;
  Generator.close cancelled;
  assert (Generator.state frame = Returned);
  assert (Generator.state unstarted = Returned);
  print_endline "independent replay positions, terminal states and cancellation";
  [%expect {| independent replay positions, terminal states and cancellation |}]

let%expect_test "[g1] unowned task snapshots do not finalize before an owning binding exists" =
  let open Ren in
  let cancelled = ref 0 in
  let run () =
    try
      Generator.yield (Value.VInt 1L);
      Generator.yield (Value.VInt 2L)
    with Sched.Cancelled ->
      incr cancelled;
      raise Sched.Cancelled
  in
  let original_owner = Generator.new_scope () in
  let original =
    Generator.replay ~owner:original_owner ~name:"snapshot" ~run
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  assert (Generator.step original = Item (Value.VInt 1L));
  (* This is the real clone operation used for readonly task captures and
     implicit collection snapshots. It has no receiving source binding. *)
  let captured = Generator.clone (Generator.to_value original) in
  let snapshot = Generator.of_value captured in
  assert (Generator.step original = Item (Value.VInt 2L));
  assert (Generator.step original = End);
  Generator.close_scope original_owner;
  let never_started_owner = Generator.new_scope () in
  Generator.close_scope never_started_owner;
  assert (!cancelled = 0);
  assert (Generator.state original = Returned);
  assert (Generator.state snapshot = Suspended);
  (* The task-local var/aggregate binding creates its own fork and token;
     abandoning that binding closes it without changing its borrowed input. *)
  let running_owner = Generator.new_scope () in
  let local = Generator.clone ~owner:running_owner captured in
  Generator.close_scope running_owner;
  assert (!cancelled = 1);
  assert (Generator.state (Generator.of_value local) = Cancelled);
  assert (Generator.state snapshot = Suspended);
  assert (Generator.state original = Returned);
  print_endline "capture snapshots keep position; only real bindings own cleanup";
  [%expect {| capture snapshots keep position; only real bindings own cleanup |}]

let%expect_test "[g1] projected places refresh and write back only active steps and cleanup" =
  let open Ren in
  let root = ref 1 and cell = ref 0 in
  let reads = ref 0 and writes = ref 0 in
  let make () =
    Generator.block ~name:"projected"
      ~before_step:(fun () -> incr reads; cell := !root)
      ~after_step:(fun () -> incr writes; root := !cell)
      ~run:(fun () ->
        try
          cell := !cell + 1;
          Generator.yield (Value.VInt (Int64.of_int !cell));
          cell := !cell + 2;
          Generator.yield (Value.VInt (Int64.of_int !cell))
        with Sched.Cancelled ->
          cell := !cell + 10;
          raise Sched.Cancelled)
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  let unstarted = make () in
  Generator.close unstarted;
  assert (!reads = 0 && !writes = 0 && !root = 1);
  let frame = make () in
  assert (Generator.step frame = Item (Value.VInt 2L));
  assert (!root = 2);
  root := 20;
  assert (Generator.step frame = Item (Value.VInt 22L));
  assert (!root = 22);
  root := 30;
  Generator.close frame;
  assert (!root = 40);
  assert (!reads = 3 && !writes = 3);
  Generator.close frame;
  (match Generator.step frame with
  | _ -> failwith "cancelled projected generator produced an answer"
  | exception Generator_panic "a cancelled generator can't be stepped" -> ());
  assert (!root = 40 && !reads = 3 && !writes = 3);
  print_endline "no unstarted or terminal projection; active steps and close refresh the root";
  [%expect {| no unstarted or terminal projection; active steps and close refresh the root |}]

let%expect_test "[g1] a resumed generator takes depth from its current consumer" =
  let open Ren in
  let final_depth = ref None in
  let frame =
    Generator.block ~name:"depth" ~run:(fun () -> assert false)
      ~run_at_depth:(fun depth ->
        assert (!depth = 3);
        incr depth;
        Generator.yield Value.VUnit;
        assert (!depth = 41);
        Generator.yield Value.VUnit;
        ())
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  assert (Generator.step ~depth:3 frame = Item Value.VUnit);
  assert (Generator.step ~depth:40 frame = Item Value.VUnit);
  let cleanup =
    Generator.block ~name:"cleanup_depth" ~run:(fun () -> assert false)
      ~run_at_depth:(fun depth ->
        try Generator.yield Value.VUnit
        with Sched.Cancelled ->
          final_depth := Some !depth;
          raise Sched.Cancelled)
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  assert (Generator.step ~depth:2 cleanup = Item Value.VUnit);
  Generator.close ~depth:10 cleanup;
  assert (!final_depth = Some 11);
  assert (Generator.step ~depth:1 frame = End);
  print_endline "step and cleanup use the active consumer depth";
  [%expect {| step and cleanup use the active consumer depth |}]

let%expect_test "[g1] typed record copies register cleanup in declaration order" =
  let open Ren in
  let closed = ref [] in
  let make name =
    Generator.replay ~name
      ~run:(fun () ->
        try Generator.yield Value.VUnit
        with Sched.Cancelled ->
          closed := !closed @ [ name ];
          raise Sched.Cancelled)
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) ()
  in
  let z = make "z" and a = make "a" in
  assert (Generator.step z = Item Value.VUnit);
  assert (Generator.step a = Item Value.VUnit);
  let record_path = Path.make "generator_contracts" "Record" in
  let cursor_ty = Ty.Con (Ty.generator_cursor (Path.make "generator_contracts" "leaf"), []) in
  let field name : Iface.field =
    { fname = name; fty = cursor_ty; fdefault = None; fdefault_member = None; fdefaults = [] }
  in
  let declaration : Iface.type_decl =
    { path = record_path; params = []; body = Record [ field "z"; field "a" ];
      members = Path.Map.empty; numeric = None; opaque = false; loc = None }
  in
  let types = Hashtbl.create 2 in
  Hashtbl.add types record_path declaration;
  let owner = Generator.new_scope () in
  let value = Value.VRecord [ "a", Generator.to_value a; "z", Generator.to_value z ] in
  let _ = Generator.clone_typed ~owner types (Ty.Con (record_path, [])) value in
  Generator.close_scope owner;
  assert (!closed = [ "a"; "z" ]);
  assert (Generator.state a = Suspended && Generator.state z = Suspended);
  assert (Generator.step a = End && Generator.step z = End);
  assert (!closed = [ "a"; "z" ]);
  print_endline "record declaration z,a closes copies a,z despite sorted value storage";
  [%expect {| record declaration z,a closes copies a,z despite sorted value storage |}]

let%expect_test "[g1] overlapping pattern bindings adopt once and fork each later owner" =
  let open Ren in
  let cancelled = ref 0 in
  let source = Generator.new_scope () and receiving = Generator.new_scope () in
  let frame = Generator.replay ~owner:source ~name:"pattern"
      ~run:(fun () ->
        try
          Generator.yield (Value.VInt 1L);
          Generator.yield (Value.VInt 2L)
        with Sched.Cancelled -> incr cancelled; raise Sched.Cancelled)
      ~failure:(fun _ -> None) ~panic:(fun message -> Generator_panic message) () in
  assert (Generator.step frame = Item (Value.VInt 1L));
  let types = Hashtbl.create 1 in
  let ty = Ty.Con (Ty.generator_cursor (Path.make "generator_contracts" "pattern"), []) in
  let value = Generator.to_value frame in
  let first = Generator.bind_from_typed ~source ~retained:false receiving types ty value in
  let alias = Generator.bind_from_typed ~source ~retained:false receiving types ty value in
  let first = Generator.of_value first and alias = Generator.of_value alias in
  assert (first != alias);
  Generator.close_scope source;
  assert (!cancelled = 0);
  assert (Generator.step first = Item (Value.VInt 2L));
  assert (Generator.step alias = Item (Value.VInt 2L));
  Generator.close_scope receiving;
  assert (!cancelled = 2);
  Generator.close_scope receiving;
  assert (!cancelled = 2);
  print_endline "first binder adopts, overlapping alias forks, both close once";
  [%expect {| first binder adopts, overlapping alias forks, both close once |}]

let%expect_test "[g1] runtime primitive descriptors preserve the cleanup-free data path" =
  let open Ren in
  let types = Generator.runtime_types [] in
  let array item = Ty.Con (Path.prelude "Array", [item]) in
  let map key item = Ty.Con (Path.prelude "Map", [key; item]) in
  let cursor = Ty.Con (Ty.generator_cursor ~source_params:0 (Path.make "proof" "items"), []) in
  List.iter (fun ty -> assert (not (Generator.may_cleanup types ty)))
    [Ty.int; Ty.float; Ty.bool; Ty.unit; array Ty.int; array (array Ty.int); map Ty.int Ty.int];
  List.iter (fun ty -> assert (Generator.may_cleanup types ty))
    [cursor; array cursor; map Ty.int cursor; Ty.Con (Ty.tuple_path 2, [Ty.int; cursor]); Ty.Var 0];
  print_endline "primitive data stays shared; cursor payloads and unknown types retain cleanup";
  [%expect {| primitive data stays shared; cursor payloads and unknown types retain cleanup |}]
