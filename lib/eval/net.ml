(* The real `Net` (compiler.md, "Stage 11a", "`Net`"): TCP through
   [Unix], each socket non-blocking, and each wait a scheduler wait on its
   descriptor (Sched.wait_io), so the other tasks run meanwhile. What each
   gives is the prelude's private [NetOutcome<T>], which its source turns
   into the value or a `NetError`.

   A listener and a connection are numbers, the runtime's: each socket
   gets the next, and a number is never given twice, so a call with one
   that's been closed finds nothing, and is `Closed`. *)

open Value

let outcome name args = VCon { ty = Path.prelude "NetOutcome"; name; args }
let ok v = outcome "NetDone" [ v ]
let closed = outcome "NetClosed" []

(* What the system said, as an outcome. *)
let failed (e : Unix.error) =
  match e with
  | ECONNREFUSED -> outcome "NetRefused" []
  | EADDRINUSE -> outcome "NetInUse" []
  | EPIPE | ECONNRESET | ECONNABORTED | EBADF | ENOTCONN | ESHUTDOWN -> closed
  | e -> outcome "NetOther" [ VStr (Unix.error_message e) ]

(* Whether a call would have waited: the socket isn't ready yet. *)
let would_wait (e : Unix.error) = match e with EAGAIN | EWOULDBLOCK | EINTR -> true | _ -> false

(* Every socket open, by its number. *)
let sockets : (int64, Unix.file_descr) Hashtbl.t = Hashtbl.create 8
let numbered = ref 0L

let keep fd =
  Unix.set_nonblock fd;
  numbered := Int64.succ !numbered;
  Hashtbl.replace sockets !numbered fd;
  VInt !numbered

(* A write to a connection the other side has closed is `Closed`, not
   SIGPIPE, which would end the program. *)
let started = ref false

let start () =
  if not !started then begin
    started := true;
    Sys.set_signal Sys.sigpipe Sys.Signal_ignore
  end

(* `listen(addr)`: a socket bound to [host] and [port], listening, with
   a backlog of 128. The host is written as numbers, since there's no DNS
   yet. Its address may be used again at once, so a server that has just
   stopped can start again; one something listens at is `InUse`. *)
let listen host port =
  start ();
  match Unix.inet_addr_of_string host with
  | exception Failure _ ->
      outcome "NetOther"
        [
          VStr
            (Printf.sprintf
               "`%s` isn't an address written as numbers, which is all `Net` \
                takes: there's no DNS yet"
               host);
        ]
  | ip -> (
      let addr = Unix.ADDR_INET (ip, Int64.to_int port) in
      match Unix.socket ~cloexec:true (Unix.domain_of_sockaddr addr) SOCK_STREAM 0 with
      | exception Unix.Unix_error (e, _, _) -> failed e
      | fd -> (
          match
            Unix.setsockopt fd SO_REUSEADDR true;
            Unix.bind fd addr;
            Unix.listen fd 128
          with
          | () -> ok (keep fd)
          | exception Unix.Unix_error (e, _, _) ->
              Unix.close fd;
              failed e))

(* A connection accepted on [fd], or [None] if none is waiting yet. *)
let accepted fd =
  match Unix.accept ~cloexec:true fd with
  | c, _ -> Ok (Some (keep c))
  | exception Unix.Unix_error (ECONNABORTED, _, _) -> Ok None
  | exception Unix.Unix_error (e, _, _) when would_wait e -> Ok None
  | exception Unix.Unix_error (e, _, _) -> Error (failed e)

(* `close(c)`: closed, and forgotten. *)
let close n =
  match Hashtbl.find_opt sockets n with
  | Some fd ->
      Hashtbl.remove sockets n;
      (try Unix.close fd with Unix.Unix_error _ -> ());
      VUnit
  | None -> VUnit

(* `accept(l)`: waits for a connection. *)
let accept ?at n =
  match Hashtbl.find_opt sockets n with
  | None -> closed
  | Some fd ->
      let rec go () =
        match accepted fd with
        | Ok (Some c) -> ok c
        | Ok None ->
            Sched.wait_io ?at ~out:false fd "waits for a connection";
            go ()
        | Error o -> o
      in
      go ()

(* `accept_until(l, stop)`: waits for a connection, or for the signal
   [stop]. Once it has come, the listener is closed and it gives `None`,
   and the prelude's `real_net` starts the cleanup deadline
   (Sched.drain). *)
let accept_until ?at n stop =
  let some v = VCon { ty = Path.prelude "Option"; name = "Some"; args = [ v ] }
  and none = VCon { ty = Path.prelude "Option"; name = "None"; args = [] } in
  let stop = Int64.to_int stop in
  match Hashtbl.find_opt sockets n with
  | None -> closed
  | Some fd ->
      Sched.awaits stop;
      let rec go () =
        if Sched.stopped stop then begin
          ignore (close n);
          ok none
        end
        else
          match accepted fd with
          | Ok (Some c) -> ok (some c)
          | Ok None ->
              Sched.wait_io ?at ~signal:stop ~out:false fd
                "waits for a connection, or a signal";
              go ()
          | Error o -> o
      in
      go ()

(* Why a read of fewer than one byte fails, as `sim.net()`'s says too
   (std_lib.ml): its bytes, none, would read as the other side having
   closed. *)
let read_nothing = "a read takes at least 1 byte, or it couldn't tell that from the end"

(* `read(c, max)`: up to [max] bytes, once there are some; none once the
   other side has closed. *)
let read ?at n max =
  match Hashtbl.find_opt sockets n with
  | None -> closed
  | Some _ when max < 1L -> outcome "NetOther" [ VStr read_nothing ]
  | Some fd ->
      let buf = Bytes.create (Int64.to_int max) in
      let rec go () =
        match Unix.read fd buf 0 (Bytes.length buf) with
        | k -> ok (VBytes (Bytes.sub_string buf 0 k))
        | exception Unix.Unix_error (e, _, _) when would_wait e ->
            Sched.wait_io ?at ~out:false fd "waits to read";
            go ()
        | exception Unix.Unix_error (e, _, _) -> failed e
      in
      go ()

(* `write(c, b)`: waits until all of [b] is written. *)
let write ?at n data =
  match Hashtbl.find_opt sockets n with
  | None -> closed
  | Some fd ->
      let rec go off =
        if off >= String.length data then ok VUnit
        else
          match Unix.write_substring fd data off (String.length data - off) with
          | k -> go (off + k)
          | exception Unix.Unix_error (e, _, _) when would_wait e ->
              Sched.wait_io ?at ~out:true fd "waits to write";
              go off
          | exception Unix.Unix_error (e, _, _) -> failed e
      in
      go 0
