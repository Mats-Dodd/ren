(* The scheduler: the interpreter's tasks (async.md; compiler.md, "Stage
   11a", "Scheduling" and "Structured tasks").

   The interpreter runs `main`, and each test, as the root task of a
   scheduler ([run]), whatever the program does: a program that starts
   no task is a scheduler with one, and nothing it does changes. A task
   is a fiber, OCaml 5's effect continuation. It runs until it waits, at
   one of the waits below ([wait]): it performs the effect [Suspend],
   which hands its continuation, the rest of its run, to the handler
   around the fiber, here; the scheduler keeps it, and runs the next task
   in its queue. Whatever wakes the task, a task ending, a timer, puts it
   back on the queue's end, and when its turn comes the continuation is
   resumed, as if [Effect.perform] had returned. There's no preemption: a
   task that never waits runs to its end.

   This is `single`'s order (compiler.md, "`single`'s order"), which `ren
   run`'s output follows exactly: one run queue, first in first out, a
   task woken or started going on its end in the order that happens; and
   when no task can run, the scheduler sleeps until the earliest timer,
   real time, and wakes what it was for.

   **Cancellation** is the exception [Cancelled], raised in a task asked
   to stop at its next dependency call ([check]), or at once if it's
   waiting: the wait ends, with the continuation resumed by raising it
   ([Effect.Deep.discontinue]). What isn't the interpreter's to decide,
   `finally` seeing it, is eval.ml's; here a task keeps how deep in
   `finally`s it is, [shield]: while it's in one, a cancel isn't seen,
   until the cleanup deadline, 5 seconds after the cancel, has passed.

   A task's path, `main/serve:3`, is its parent's, a label, the code its
   spawn is written in, and an ordinal, counting what its parent started
   with that label: what panics and the deadlock panic say a task is. *)

(* A task was asked to stop, and has seen it. Nothing in Ren catches it:
   only a `finally` sees it, which eval.ml runs and then goes on with it. *)
exception Cancelled

(* The cleanup deadline: how long a cancelled task's `finally`s may run
   before their own waits and calls are cancelled too, in seconds. *)
let cleanup = 5.

type state =
  | Fresh  (** started, but it hasn't run yet *)
  | Running
  | Waiting  (** suspended, on the queue or waiting to be woken *)
  | Ended

(* A task. [k] is its continuation while it's suspended. [wait] numbers
   its current wait, 0 when it isn't waiting, so that a waker of a wait
   that's over, a timer cancelled with it, is a no-op; [what] is what it
   waits for, for the deadlock panic, and [cancellable] whether a cancel
   ends the wait (a scope's end, cancelling its tasks, waits for them
   regardless). [asked] is whether it's been asked to stop, and
   [cleanup_by] when its shield is gone if it has. [result] is what it
   gave, once it's [Ended]: [None] if it was cancelled first. *)
type task = {
  path : string;
  root : bool;
  scope : scope option;  (** the scope it was started in, if it isn't a root *)
  mutable state : state;
  mutable k : (unit, unit) Effect.Deep.continuation option;
  mutable wait : int;
  mutable what : string;
  mutable cancellable : bool;
  mutable asked : bool;
  mutable cleanup_by : float;
  mutable shield : int;
  mutable result : Value.t option;
  mutable joiners : (unit -> bool) list;  (** what to wake when it ends *)
  ordinals : (string, int) Hashtbl.t;
      (** how many tasks it has started with each label *)
  mutable withs : int;  (** how many `with`s it has entered, ever *)
  mutable frames : frame list;
      (** the `with`s whose bodies it's running, the innermost first *)
}

(* A scope: what `Async.scope` gives its body. [running] are its tasks
   that haven't ended, the first started first; [room] are the spawns
   waiting while it's full; [empty], what waits for them all to end;
   [keyed], `s.replace`'s tasks by their key, each with its type. *)
and scope = {
  max : int;
  owner : task;
  began : int;
      (** how many `with`s [owner] had entered when the scope began: one
          entered after is beside it (see [frame]) *)
  mutable running : task list;
  mutable room : (unit -> bool) list;
  mutable empty : (unit -> bool) list;
  mutable keyed : (Ty.ty * Value.t * task) list;
}

(* A `with` whose body a task is running, numbered by the task's count
   of `with`s, with what it installed: a task spawned in its body into a
   scope that began before it, whose block's evidence holds what it
   installed, is its background task ([bg]), which it cancels and waits
   for when its body ends (compiler.md, "A task spawned beside a `with`
   is its background task"). *)
and frame = {
  num : int;
  installed : Value.installed list;
  mutable bg : task list;
}

(* A scope and a task's handle, as values a program holds (value.ml,
   [sched]). *)
type Value.sched += Scope of scope | Handle of task

(* What the queue holds: a task to start, with what it runs; one to
   resume where it waited; one to resume by raising [Cancelled] where it
   waited; or by raising a panic, the deadlock's. *)
type action =
  | Start of (unit -> Value.t)
  | Resume
  | Interrupt
  | Raise of exn

(* A timer: when it's due, in the order it was set among those due at
   once, what it does then, and whether it's still wanted, which it isn't
   once the wait it was for has ended some other way. *)
type timer = { at : float; seq : int; fire : unit -> unit; live : unit -> bool }

(* The scheduler of a run: its queue, its timers, the task running, and
   the root, whose end is the run's. *)
type t = {
  queue : (task * action) Queue.t;
  mutable timers : timer list;  (** sorted by [at], then [seq] *)
  mutable current : task;
  root_task : task;
  mutable alive : task list;
      (** every task that hasn't ended, the latest started first: what the
          deadlock panic lists *)
  mutable count : int;  (** for numbering waits and timers *)
}

(* The scheduler running, if one is: a run is one program, or one test,
   at a time, and [run] puts back the one before when it ends. *)
let running : t option ref = ref None

let now () = Unix.gettimeofday ()
let bug what = failwith ("bug: the scheduler: " ^ what)

let sched () =
  match !running with Some s -> s | None -> bug "no scheduler is running"

let fresh s =
  s.count <- s.count + 1;
  s.count

(* The task running, if a scheduler is. *)
let current () = Option.map (fun s -> s.current) !running

(* The path of the task running, if it isn't a root: what a panic in it
   says it was in. *)
let task_path () =
  match current () with Some t when not t.root -> Some t.path | _ -> None

(* The path of the task running: `main` if no scheduler is. *)
let current_path () =
  match current () with Some t -> t.path | None -> "main"

(* The effect a task waits with: its continuation goes to the scheduler,
   which resumes it once something wakes it. *)
type _ Effect.t += Suspend : unit Effect.t

let add_timer s ~at ~live fire =
  let tm = { at; seq = fresh s; fire; live } in
  let rec insert = function
    | x :: rest when x.at <= at -> x :: insert rest
    | rest -> tm :: rest
  in
  s.timers <- insert s.timers

(* Whether [t] sees a cancel now: it's been asked to, and isn't in a
   `finally`, or is past its cleanup deadline. *)
let sees_cancel t = t.asked && (t.shield = 0 || now () >= t.cleanup_by)

(* End [t]'s wait [id], if it's still the one it's in, to resume it with
   [action]. A waker of a wait that's over gives [false]. *)
let wake s t id action =
  if t.wait = id && id <> 0 then begin
    t.wait <- 0;
    Queue.push (t, action) s.queue;
    true
  end
  else false

(* Wake the first of [ws] that's still waiting, and give the rest. *)
let rec wake_first = function [] -> [] | w :: rest -> if w () then rest else wake_first rest

(* Wait, as the task running, until [register]'s waker is called, which
   [register] keeps where what it waits for will call it. [what] is what
   the deadlock panic says it waits for, and [at] the program's call it
   waits at, `server.ren:9:3`, if it's known. A cancellable wait ends at once
   if the task sees a cancel, and otherwise raises [Cancelled] where it
   waited if it's cancelled meanwhile, or, in a `finally`, once its
   cleanup deadline passes. *)
let wait ?(cancellable = true) ?at what register =
  let s = sched () in
  let t = s.current in
  if cancellable && sees_cancel t then raise Cancelled;
  let id = fresh s in
  t.wait <- id;
  t.what <- (match at with Some at -> what ^ " at " ^ at | None -> what);
  t.cancellable <- cancellable;
  if cancellable && t.asked then
    (* shielded: until the deadline *)
    add_timer s ~at:t.cleanup_by
      ~live:(fun () -> t.wait = id)
      (fun () -> ignore (wake s t id Interrupt));
  register (fun () -> wake s t id Resume);
  Effect.perform Suspend

(* Raise [Cancelled] if the task running sees a cancel: what a dependency
   call does first. *)
let check () =
  match current () with Some t when sees_cancel t -> raise Cancelled | _ -> ()

(* [f ()], in a `finally`: a cancel isn't seen meanwhile, until the
   cleanup deadline. *)
let shielded f =
  match current () with
  | None -> f ()
  | Some t -> (
      t.shield <- t.shield + 1;
      match f () with
      | v ->
          t.shield <- t.shield - 1;
          v
      | exception e ->
          t.shield <- t.shield - 1;
          raise e)

(* Ask [t] to stop, and return at once. It stops at its next dependency
   call, or now, if it's waiting, unless it's in a `finally`: then once
   its cleanup deadline passes. A task that hasn't run yet never runs. *)
let cancel t =
  let s = sched () in
  if t.state <> Ended && not t.asked then begin
    t.asked <- true;
    t.cleanup_by <- now () +. cleanup;
    if t.wait <> 0 && t.cancellable then
      let id = t.wait in
      if t.shield = 0 then ignore (wake s t id Interrupt)
      else
        add_timer s ~at:t.cleanup_by
          ~live:(fun () -> t.wait = id)
          (fun () -> ignore (wake s t id Interrupt))
  end

(* [t] has ended, giving [result]: what waits for it is woken, and its
   scope has room for one more. *)
let ended t result =
  let s = sched () in
  s.alive <- List.filter (fun u -> u != t) s.alive;
  t.state <- Ended;
  t.result <- result;
  List.iter (fun w -> ignore (w ())) (List.rev t.joiners);
  t.joiners <- [];
  match t.scope with
  | None -> ()
  | Some sc ->
      sc.running <- List.filter (fun u -> u != t) sc.running;
      sc.keyed <- List.filter (fun (_, _, u) -> u != t) sc.keyed;
      sc.room <- wake_first sc.room;
      if sc.running = [] then begin
        List.iter (fun w -> ignore (w ())) (List.rev sc.empty);
        sc.empty <- []
      end

(* Run [thunk] as [t]'s fiber, until it ends or first waits. A task that
   ends by being cancelled gave nothing; anything else it raises, a
   panic, ends the run: it goes on out of the scheduler's loop. *)
let start s t thunk =
  s.current <- t;
  t.state <- Running;
  Effect.Deep.match_with thunk ()
    {
      retc = (fun v -> ended t (Some v));
      exnc = (function Cancelled -> ended t None | e -> raise e);
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Suspend ->
              Some
                (fun (k : (a, unit) Effect.Deep.continuation) ->
                  t.k <- Some k;
                  t.state <- Waiting)
          | _ -> None);
    }

(* Run what the queue holds next. *)
let step s (t, action) =
  match action with
  | Start thunk ->
      (* a task cancelled before it first runs never runs *)
      if t.asked then ended t None else start s t thunk
  | Resume | Interrupt | Raise _ -> (
      let k = match t.k with Some k -> k | None -> bug "a task with no continuation" in
      t.k <- None;
      s.current <- t;
      t.state <- Running;
      match action with
      | Resume -> Effect.Deep.continue k ()
      | Interrupt -> Effect.Deep.discontinue k Cancelled
      | Raise e -> Effect.Deep.discontinue k e
      | Start _ -> ())

(* A task, not started yet, with the path [path], in [scope]. *)
let task ~path ~root scope =
  {
    path;
    root;
    scope;
    state = Fresh;
    k = None;
    wait = 0;
    what = "";
    cancellable = true;
    asked = false;
    cleanup_by = 0.;
    shield = 0;
    result = None;
    joiners = [];
    ordinals = Hashtbl.create 4;
    withs = 0;
    frames = [];
  }

(* Run [f] as the root task of a scheduler, its path [root], `main` or
   `test`: what it gives, or what it raises, once it has ended, which it
   does only once every task it started has. When no task can run and no
   timer is due to wake one, it's a deadlock: [deadlock] makes the panic
   raised in the root, where it waits, given what each task waits for. *)
let run ~root ~(deadlock : string list -> exn) (f : unit -> Value.t) =
  let t = task ~path:root ~root:true None in
  let s =
    {
      queue = Queue.create ();
      timers = [];
      current = t;
      root_task = t;
      alive = [ t ];
      count = 0;
    }
  in
  let rec loop () =
    if t.state <> Ended then
      match Queue.take_opt s.queue with
      | Some next ->
          step s next;
          loop ()
      | None -> (
          s.timers <- List.filter (fun tm -> tm.live ()) s.timers;
          match s.timers with
          | first :: _ ->
              let dt = first.at -. now () in
              (if dt > 0. then
                 try Unix.sleepf dt with Unix.Unix_error (EINTR, _, _) -> ());
              (* each timer due, in the order they're due *)
              let at = now () in
              let due, later = List.partition (fun tm -> tm.at <= at) s.timers in
              s.timers <- later;
              List.iter (fun tm -> if tm.live () then tm.fire ()) due;
              loop ()
          | [] ->
              (* every task waits, and nothing can wake one: the root
                 too, or it would have ended *)
              let waits =
                List.rev_map (fun u -> u.path ^ " " ^ u.what) s.alive
              in
              t.wait <- 0;
              Queue.push (t, Raise (deadlock waits)) s.queue;
              loop ())
  in
  let before = !running in
  running := Some s;
  Queue.push (t, Start f) s.queue;
  match loop () with
  | () -> (
      running := before;
      match t.result with Some v -> v | None -> raise Cancelled)
  | exception e ->
      running := before;
      raise e

(* ---- scopes and tasks ---- *)

(* A new scope, of the task running, which `spawn` lets run [max] tasks
   at once. *)
let scope ~max =
  let t = (sched ()).current in
  {
    max;
    owner = t;
    began = t.withs;
    running = [];
    room = [];
    empty = [];
    keyed = [];
  }

(* Wait until [sc]'s tasks have all ended: cancellable, as the end of a
   scope's body is, or not, as cancelling them is. *)
let wait_empty ?cancellable ?at sc =
  if sc.running <> [] then
    wait ?cancellable ?at "waits for its scope's tasks" (fun wake ->
        sc.empty <- wake :: sc.empty)

(* Cancel [sc]'s tasks, and wait for them to end: whatever the task
   running is asked meanwhile, it can't leave before they have. *)
let cancel_all ?at sc =
  List.iter cancel sc.running;
  wait_empty ~cancellable:false ?at sc

(* Wait for [t] to end. *)
let join ?at t =
  if t.state <> Ended then
    wait ?at ("waits for " ^ t.path ^ " to end") (fun wake ->
        t.joiners <- wake :: t.joiners)

(* The task of the frame a task spawned into [sc] now, whose block's
   evidence is [evidence], is the background task of: the innermost
   `with` the running task is in the body of that began after [sc] did,
   and installed something [evidence] holds. A task running in a scope
   it doesn't own was started after the scope began, and so was every
   `with` it's in. *)
let beside sc evidence =
  let t = (sched ()).current in
  List.find_opt
    (fun f ->
      (sc.owner != t || f.num > sc.began)
      && List.exists (fun i -> List.memq i evidence) f.installed)
    t.frames

(* Start [thunk] as a task of [sc], labelled [label], once [sc] has room
   for it, under [key] if it's given; [evidence] is its block's, the
   evidence where it was written. The task goes on the queue's end, and
   the task running goes on. *)
let spawn ?key ?at sc ~label ~evidence thunk =
  let s = sched () in
  let parent = s.current in
  while List.length sc.running >= sc.max do
    wait ?at "waits for room in its scope" (fun wake ->
        sc.room <- sc.room @ [ wake ])
  done;
  let n = Option.value (Hashtbl.find_opt parent.ordinals label) ~default:0 in
  Hashtbl.replace parent.ordinals label (n + 1);
  let path = Printf.sprintf "%s/%s:%d" parent.path label n in
  let t = task ~path ~root:false (Some sc) in
  sc.running <- sc.running @ [ t ];
  s.alive <- t :: s.alive;
  Option.iter (fun (ty, k) -> sc.keyed <- (ty, k, t) :: sc.keyed) key;
  Option.iter (fun f -> f.bg <- t :: f.bg) (beside sc evidence);
  Queue.push (t, Start thunk) s.queue;
  t

(* The task [sc] started under a key equal to [k], of the type [ty], if
   it's still running: keys of different types are never equal. *)
let keyed sc ty k ~equal =
  List.find_map
    (fun (ty', k', t) -> if ty' = ty && equal k k' then Some t else None)
    sc.keyed

(* ---- `with`s ---- *)

(* The task running enters the body of a `with` that installed
   [installed]. *)
let enter_with installed =
  match current () with
  | None -> None
  | Some t ->
      t.withs <- t.withs + 1;
      let f = { num = t.withs; installed; bg = [] } in
      t.frames <- f :: t.frames;
      Some f

(* The body of the `with` [f] has ended: its background tasks still
   running are cancelled, and waited for. *)
let leave_with ?at = function
  | None -> ()
  | Some f ->
      let t = (sched ()).current in
      t.frames <- List.filter (fun g -> g != f) t.frames;
      let live = List.filter (fun u -> u.state <> Ended) f.bg in
      List.iter cancel live;
      List.iter
        (fun u ->
          if u.state <> Ended then
            wait ~cancellable:false ?at ("waits for " ^ u.path ^ " to stop")
              (fun wake -> u.joiners <- wake :: u.joiners))
        live

(* ---- time ---- *)

(* Sleep for [ms] milliseconds: the task running waits, and the others
   run meanwhile. Without a scheduler, the thread sleeps. *)
let sleep ?at ms =
  let secs = Int64.to_float ms /. 1000. in
  match !running with
  | None -> if secs > 0. then Unix.sleepf secs
  | Some s ->
      if secs > 0. then
        wait ?at "sleeps" (fun wake ->
            let id = s.current.wait in
            let t = s.current in
            add_timer s ~at:(now () +. secs)
              ~live:(fun () -> t.wait = id)
              (fun () -> ignore (wake ())))
