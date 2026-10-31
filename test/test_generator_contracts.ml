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

let frame_adapter : (module Frame) option = None

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
  [%expect {| skipped until g1: real generator-frame adapter |}]

let%expect_test "[g1] closing an unstarted frame runs no body or cleanup" =
  (match frame_adapter with
  | None -> print_endline "skipped until g1: real generator-frame adapter"
  | Some adapter -> unstarted_cancel adapter);
  [%expect {| skipped until g1: real generator-frame adapter |}]

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
