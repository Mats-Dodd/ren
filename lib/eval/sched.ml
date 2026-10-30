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

   How the next task is chosen is the runtime's policy, which the
   runtime's handler sets for its `with`'s body ([install]): `single`'s
   order (compiler.md, "`single`'s order"), which `ren run`'s output
   follows exactly, is one run queue, first in first out, a task woken or
   started going on its end in the order that happens; and when no task
   can run, the scheduler sleeps until the earliest timer, real time, and
   wakes what it was for. `sim`'s, which `ren test` runs each test under,
   draws the next task from the queue by a tape of numbers from its seed,
   and its time is virtual: when no task can run it moves straight to the
   earliest timer ("`sim`'s choices").

   **Cancellation** is the exception [Cancelled], raised in a task asked
   to stop at its next dependency call ([check]), or at once if it's
   waiting: the wait ends, with the continuation resumed by raising it
   ([Effect.Deep.discontinue]). What isn't the interpreter's to decide,
   `finally` seeing it, is eval.ml's; here a task keeps how deep in
   `finally`s it is, [shield]: while it's in one, a cancel isn't seen,
   until the cleanup deadline, 5 seconds after the cancel, has passed.
   An `Async.timeout` is a cancel too, of the part of the task inside it,
   from its deadline on ([deadline]): the task sees it as it sees a
   cancel, and the timeout, where it reaches it, makes it `Timeout`.

   A task's path, `main/serve:3`, is its parent's, a label, the code its
   spawn is written in, and an ordinal, counting what its parent started
   with that label: what panics and the deadlock panic say a task is. *)

(* A task was asked to stop, and has seen it. Nothing in Ren catches it:
   only a `finally` sees it, which eval.ml runs and then goes on with it. *)
exception Cancelled

(* The root ended cancelled, by the signal numbered so, which nothing
   stopped for: `ren run` exits with 128 and it (compiler.md, "Stage 11a",
   "`Net`"). *)
exception Signalled of int

(* The cleanup deadline: how long a cancelled task's `finally`s may run
   before their own waits and calls are cancelled too, in seconds. *)
let cleanup = 5.

type state =
  | Fresh  (** started, but it hasn't run yet *)
  | Running
  | Waiting  (** suspended, on the queue or waiting to be woken *)
  | Ended

(* An `Async.timeout` a task is running the body of: when its deadline
   is, [due], and how deep in `finally`s the task was when it began,
   [dshield]. Past [due] the task sees a cancel, unless it's in a
   `finally` it entered since, which shields it until the cleanup
   deadline after [due]; a `finally` around the timeout doesn't, so a
   timeout written in a `finally` bounds its own body (compiler.md, "The
   rest of `Async`"). *)
type deadline = { mutable due : float; dshield : int }

(* An `Async.isolate` a task is running the body of: [base], the number
   of the last instance made before it began (Value.instance), so one
   numbered [base] or less was installed outside it, and [depth], how
   many operations the task was in then ([holding]). *)
type isolate = { base : int; depth : int }

(* An instance a task is in an operation of: its number, the label of the
   arm that's running, `gate.wait`, and the dependency it's installed as,
   `Gate`, which the deadlock panic names. *)
type held = { inst : int; label : string; dep : string }

(* A task. [k] is its continuation while it's suspended. [wait] numbers
   its current wait, 0 when it isn't waiting, so that a waker of a wait
   that's over, a timer cancelled with it, is a no-op; [what] is what it
   waits for, for the deadlock panic, and [cancellable] whether a cancel
   ends the wait (a scope's end, cancelling its tasks, waits for them
   regardless). [asked] is whether it's been asked to stop, [asked_at]
   when, and [cleanup_by] when its shield is gone if it has. [result] is
   what it gave, once it's [Ended]: [None] if it was cancelled first. *)
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
  mutable asked_at : float;
  mutable cleanup_by : float;
  mutable deadlines : deadline list;
      (** the `Async.timeout`s whose bodies it's running, the innermost first *)
  mutable queued : int option;
      (** the locked instance it's queued for, if it is ([holding]): what
          a call that would close a cycle of waits follows *)
  mutable holding : held list;
      (** the instances whose operations it's in, the innermost first: what
          `Async.until` and `release` let go of *)
  mutable let_go : int list;
      (** the instances among those it has let go of for the call a
          `release` covers, the innermost first ([let_go]): what it doesn't
          hold meanwhile, though it's still in one of their operations *)
  mutable isolates : isolate list;
      (** the `Async.isolate`s whose bodies it's running, the innermost first *)
  mutable through : int list;
      (** the instances whose operations the panic it's raising has left, on
          its way out: one installed outside an isolate keeps it from being
          isolated ([isolatable]) *)
  mutable shield : int;
  mutable drained : float option;
      (** when it sees a cancel, if a task whose scope it's in has stopped
          accepting connections ([drain]): the cleanup deadline from then *)
  mutable scopes : scope list;
      (** the scopes whose bodies it's running, the innermost first *)
  mutable result : Value.t option;
  mutable joiners : (unit -> bool) list;  (** what to wake when it ends *)
  ordinals : (string, int) Hashtbl.t;
      (** how many tasks it has started with each label *)
  mutable frames : frame list;
      (** the `with`s whose bodies it's running, the innermost first *)
  context : frame list;
      (** the `with`s whose bodies the code that spawned it was running
          then, the innermost first: its spawner's [frames], then its
          spawner's [context] ([inner]) *)
  mutable pointed : bool;
      (** it's suspended at a scheduling point ([point]), where it hasn't
          waited, only let the tape choose what runs next *)
  randoms : (int, int) Hashtbl.t;
      (** the state of its own stream of each test `Random` it has drawn
          from, by the instance's number, if it isn't a root (eval.ml,
          [task_random]) *)
}

(* A scope: what `Async.scope` gives its body. [running] are its tasks
   that haven't ended, the first started first; [room] are the spawns
   waiting while it's full; [empty], what waits for them all to end;
   [keyed], `s.replace`'s tasks by their key, each with its type. *)
and scope = {
  max : int;
  owner : task;
  began : int;
      (** when it began, in the order scopes and `with`s begin ([begun]):
          a `with` whose body began after it is inside it (see [frame]) *)
  mutable running : task list;
  mutable room : (unit -> bool) list;
  mutable empty : (unit -> bool) list;
  mutable keyed : (Ty.ty * Value.t * task) list;
  mutable drain : float option;
      (** the cleanup deadline its tasks have, once its owner has stopped
          accepting connections ([drain]) *)
  mutable ended : bool;
      (** its body and its tasks have ended ([closed]): nothing more can
          start in it *)
}

(* A `with` whose body a task is running, numbered in the order scopes
   and `with`s begin ([begun]), with what it installed: a task spawned in
   its body into a scope that began before it can't reach what it
   installed, since the task could outlive it ([inner]; foundations.md,
   decision 7). Its body is [over] once it has. *)
and frame = {
  num : int;
  installed : Value.installed list;
  mutable over : bool;
}

(* What `Async.beside` and `Async.background` run their body beside
   (compiler.md, "Services stage", "Background work"): the scope its
   tasks are in, [tasks], of the task running the body, [body]; the
   deadline the body is under, [cut], which a task's failure moves to
   now, so that the body sees a cancel there as at a timeout's deadline
   ([cancel_due]); and that failure, the first, if one has. *)
type background = {
  tasks : scope;
  body : task;
  cut : deadline;
  mutable failure : Value.t option;
}

(* A scope, a task's handle, and a background, as values a program
   holds (value.ml, [sched]). *)
type Value.sched += Scope of scope | Handle of task | Background of background

(* What the queue holds: a task to start, with what it runs; one to
   resume where it waited; one to resume by raising [Cancelled] where it
   waited; or by raising a panic, the deadlock's. *)
type action =
  | Start of (unit -> Value.t)
  | Resume
  | Interrupt
  | Raise of exn

(* A timer: when it's due, in the order it was set among those due at
   once, the task it wakes, what it does then, which says whether it woke
   it, and whether it's still wanted, which it isn't once the wait it was
   for has ended some other way. *)
type timer = {
  at : float;
  seq : int;
  wakes : task;
  fire : unit -> bool;
  live : unit -> bool;
}

(* A task waiting in `Async.until`, in its wait [id], until [holds]; and
   how many of the instance's operations it was in when it let go of it,
   which it's in again once it has it back, if the instance is locked
   ([lock]). *)
type waiter = { wt : task; id : int; holds : unit -> bool; wdepth : int }

(* A task waiting until the descriptor [fd] can be read, or written if
   [out], in its wait [ioid]; what wakes it. *)
type io = { fd : Unix.file_descr; out : bool; iot : task; ioid : int; iowake : unit -> bool }

(* An exclusive instance a spawned task can reach, whose operations don't
   interleave (compiler.md, "Operations that don't interleave"): the task
   in its operations, [holder], if one is, and how many it's in, [depth];
   and the calls waiting for it, first come first, each a task and what
   wakes it. *)
type lock = {
  mutable holder : task option;
  mutable depth : int;
  callers : (task * (unit -> bool)) Queue.t;
}

(* The runtime's policy (compiler.md, "Runtimes" and "Scheduling"):
   `single`'s, first in first out in real time; or `sim`'s, each next
   task drawn by [tape], a splitmix64 stream from its seed, in the virtual
   time [clock], in seconds. *)
type policy = Single | Sim of { mutable tape : int64; mutable clock : float }

(* A task waiting in `Async.tick` under `sim`, until each of [pending],
   the tasks in the queue when it was called, has run until it waited,
   or ended. *)
type ticker = { mutable pending : task list; woken : unit -> bool }

(* A journal being recorded or replayed (journal.ml, compiler.md,
   "Journal version 2"), as the scheduler sees it: what it's told, and,
   replaying, what it says the scheduler does. Recording, it's told when
   a task waits, which makes a call to the world that's running then a
   call that waits, written in two lines ([waits]); which tasks a poll
   woke, in their order ([polled]); and when a task sees a cancel
   ([saw_cancel]), or a second failure is said ([note]).

   Replaying, while it [follows] the recording, the scheduler runs in the
   recorded order: `single`'s, first in first out, whatever the policy;
   no timer fires on its own; and when no task can run, the recording's
   next poll says which waits end, in what order ([poll]: each task's
   path, and whether it's woken to see a cancel). A task sees a cancel
   that time would have made, a timeout's or a cleanup deadline's, only
   where the recording says it did ([cancel_here]); one a task asked
   for, deterministic, it sees as it would. [astray] is a poll's task that
   isn't waiting, which the journal says is a replay gone differently, or
   the end of following. [path_of] is a task's path as the journal writes
   it. *)
type journal = {
  path_of : task -> string;
  follows : unit -> bool;
  waits : task -> unit;
  polled : task list -> unit;
  poll : unit -> (string * bool) list option;
  cancel_here : task -> bool;
  saw_cancel : task -> unit;
  astray : string -> unit;
  note : string -> unit;
}

(* The scheduler of a run: its queue, its timers, the task running, and
   the root, whose end is the run's. *)
type t = {
  queue : (task * action) Queue.t;
  mutable policy : policy;
  mutable before : policy list;
      (** the policies the runtimes installed around this one put back,
          the latest first ([install], [leave]) *)
  mutable skew : float;
      (** how far `TestClock.advance` has moved time on under `single`,
          whose time is otherwise the system's *)
  mutable ticks : ticker list;
  mutable timers : timer list;  (** sorted by [at], then [seq] *)
  mutable current : task;
  root_task : task;
  mutable alive : task list;
      (** every task that hasn't ended, the latest started first: what the
          deadlock panic lists *)
  mutable count : int;  (** for numbering waits and timers *)
  waiters : (int, waiter list) Hashtbl.t;
      (** the tasks waiting in `Async.until` for each instance, by its number,
          the first to begin waiting first *)
  locks : (int, lock) Hashtbl.t;
      (** the exclusive instances a spawned task can reach, the shared ones
          ([share]), each with its lock, by its number *)
  mutable journal : journal option;
      (** the journal being recorded or replayed, if one is ([watch]) *)
  mutable ios : io list;  (** the tasks waiting for I/O, the first first *)
  mutable sigwaits : (int * task * (unit -> bool)) list;
      (** the tasks waiting in `Net.accept_until` for each signal, by its
          number, the first first *)
  mutable awaited : int list;
      (** the signals an `accept_until` has waited for: one of them that
          comes is for it, and doesn't stop the program *)
  mutable came : int list;  (** those of them that have come *)
  mutable signalled : int option;
      (** the signal that cancelled the root, which nothing stopped for *)
}

(* The scheduler running, if one is: a run is one program, or one test,
   at a time, and [run] puts back the one before when it ends. *)
let running : t option ref = ref None

let bug what = failwith ("bug: the scheduler: " ^ what)

(* The scheduler's time, in seconds: the system's under `single` (moved
   on by `TestClock.advance`, [advance]), virtual under `sim`. Every
   deadline, timer and cancel is in it. *)
let now () =
  match !running with
  | Some { policy = Sim v; _ } -> v.clock
  | Some s -> Unix.gettimeofday () +. s.skew
  | None -> Unix.gettimeofday ()

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

(* Whether a journal being replayed says the order, now. *)
let following s = match s.journal with Some j -> j.follows () | None -> false

(* The scheduler's time moves on to [at], if it's later: what a replay
   does where the recording says a task saw a cancel that time made, so a
   timeout reaching it sees its deadline passed, as the recording did. *)
let jump s at =
  let d = at -. now () in
  if d > 0. then
    match s.policy with Sim v -> v.clock <- v.clock +. d | Single -> s.skew <- s.skew +. d

let add_timer s ~at ~wakes ~live fire =
  let tm = { at; seq = fresh s; wakes; fire; live } in
  let rec insert = function
    | x :: rest when x.at <= at -> x :: insert rest
    | rest -> tm :: rest
  in
  s.timers <- insert s.timers

(* When [t] sees a cancel, if anything's to cancel it: when it was asked
   to stop, if it isn't in a `finally`, and otherwise at its cleanup
   deadline; and each of its timeouts' deadlines, in the same way, from
   the `finally`s it has entered since that timeout began. *)
let cancel_due t =
  let asked =
    if not t.asked then None
    else if t.shield = 0 then Some t.asked_at
    else Some t.cleanup_by
  in
  let asked =
    match (asked, t.drained) with
    | _, None -> asked
    | None, Some by -> Some (if t.shield = 0 then by else by +. cleanup)
    | Some a, Some by -> Some (Float.min a (if t.shield = 0 then by else by +. cleanup))
  in
  List.fold_left
    (fun due d ->
      let at = if t.shield <= d.dshield then d.due else d.due +. cleanup in
      match due with
      | _ when d.due = Float.infinity ->
          (* a background's, with no timeout around, before it's cut
             ([background]): nothing's due *)
          due
      | Some x -> Some (Float.min x at)
      | None -> Some at)
    asked t.deadlines

(* The root [t], replaying, is cancelled where the recording's was by a
   signal nothing stopped for: SIGTERM, the one the runtime catches for
   that. *)
let signal_replayed s t =
  t.asked <- true;
  t.asked_at <- now ();
  t.cleanup_by <- t.asked_at +. cleanup;
  s.signalled <- Some 15

(* Whether [t] sees a cancel now. Following a recording, one that time
   makes is seen only where the recording says, and the time moves on to
   when it's due ([journal]). *)
let sees_cancel t =
  match !running with
  | Some ({ journal = Some j; _ } as s) when j.follows () -> (
      (t.asked && t.shield = 0)
      ||
      match cancel_due t with
      | Some at when j.cancel_here t ->
          jump s at;
          true
      | None when t.root && j.cancel_here t ->
          (* a cancel of the root nothing here explains: a signal's, which
             the replay isn't sent *)
          signal_replayed s t;
          true
      | _ -> false)
  | _ -> ( match cancel_due t with Some at -> now () >= at | None -> false)

(* [t] is about to see a cancel, which a journal is told. *)
let seen t =
  match !running with
  | Some { journal = Some j; _ } -> j.saw_cancel t
  | _ -> ()

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

(* [t], waiting cancellably, stops waiting when it sees a cancel: now, or
   at a timer, if that's later (a timeout's deadline, a cleanup
   deadline). *)
let interrupt_when s t =
  if t.wait <> 0 && t.cancellable then
    (* following a recording, only a cancel the task asked for is now:
       one time makes waits for the poll that says it *)
    let now_ at = if following s then t.asked && t.shield = 0 else at <= now () in
    match cancel_due t with
    | Some at when now_ at -> ignore (wake s t t.wait Interrupt)
    | Some at ->
        let id = t.wait in
        add_timer s ~at ~wakes:t
          ~live:(fun () -> t.wait = id)
          (fun () -> wake s t id Interrupt)
    | None -> ()

(* Wait, as the task running, until [register]'s waker is called, which
   [register] keeps where what it waits for will call it. [what] is what
   the deadlock panic says it waits for, and [at] the program's call it
   waits at, `server.ren:9:3`, if it's known. A cancellable wait ends at once
   if the task sees a cancel, and otherwise raises [Cancelled] where it
   waited if it's cancelled meanwhile, or, in a `finally`, once its
   cleanup deadline passes; and at the deadline of a timeout it's in. *)
let wait ?(cancellable = true) ?at what register =
  let s = sched () in
  let t = s.current in
  if cancellable && sees_cancel t then begin
    seen t;
    raise Cancelled
  end;
  let id = fresh s in
  t.wait <- id;
  t.what <- (match at with Some at -> what ^ " at " ^ at | None -> what);
  t.cancellable <- cancellable;
  interrupt_when s t;
  register (fun () -> wake s t id Resume);
  Option.iter (fun j -> j.waits t) s.journal;
  Effect.perform Suspend

(* Raise [Cancelled] if the task running sees a cancel: what a dependency
   call does first. *)
let check () =
  match current () with
  | Some t when sees_cancel t ->
      seen t;
      raise Cancelled
  | _ -> ()

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
    t.asked_at <- now ();
    t.cleanup_by <- t.asked_at +. cleanup;
    interrupt_when s t
  end

(* [t] has run until it waited, or ended: a task waiting in `Async.tick`
   under `sim` for it, and for nothing else now, is woken. *)
let waited s t =
  match s.ticks with
  | [] -> ()
  | ticks ->
      s.ticks <-
        List.filter
          (fun tk ->
            tk.pending <- List.filter (fun u -> u != t) tk.pending;
            match tk.pending with
            | [] ->
                ignore (tk.woken ());
                false
            | _ -> true)
          ticks

(* [t] has ended, giving [result]: what waits for it is woken, and its
   scope has room for one more. *)
let ended t result =
  let s = sched () in
  waited s t;
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
                  t.state <- Waiting;
                  if t.pointed then t.pointed <- false else waited s t)
          | _ -> None);
    }

(* The next number of [sim]'s tape: splitmix64 (Steele, Lea and Flood,
   "Fast splittable pseudorandom number generators"), which is the same
   on every machine. *)
let draw = function
  | Sim v ->
      v.tape <- Int64.add v.tape 0x9E3779B97F4A7C15L;
      let z = v.tape in
      let z = Int64.(mul (logxor z (shift_right_logical z 30)) 0xBF58476D1CE4E5B9L) in
      let z = Int64.(mul (logxor z (shift_right_logical z 27)) 0x94D049BB133111EBL) in
      Int64.(logxor z (shift_right_logical z 31))
  | Single -> bug "a draw from `single`'s tape"

(* What runs next, if anything can: under `single` the queue's first;
   under `sim` the one the tape picks among all that can, each the same
   odds ("`sim`'s choices"). *)
let take s =
  match s.policy with
    | Single -> Queue.take_opt s.queue
    | Sim _ when Queue.length s.queue <= 1 || following s -> Queue.take_opt s.queue
    | Sim _ ->
        let n = Queue.length s.queue in
        let i = Int64.to_int (Int64.unsigned_rem (draw s.policy) (Int64.of_int n)) in
        let all = List.of_seq (Queue.to_seq s.queue) in
        Queue.clear s.queue;
        List.iteri (fun j e -> if j <> i then Queue.push e s.queue) all;
        Some (List.nth all i)


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
      | Interrupt ->
          seen t;
          Effect.Deep.discontinue k Cancelled
      | Raise e -> Effect.Deep.discontinue k e
      | Start _ -> ())

(* A task, not started yet, with the path [path], in [scope]. *)
let task ?(context = []) ~path ~root scope =
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
    asked_at = 0.;
    cleanup_by = 0.;
    deadlines = [];
    queued = None;
    holding = [];
    let_go = [];
    isolates = [];
    through = [];
    shield = 0;
    drained = None;
    scopes = [];
    result = None;
    joiners = [];
    ordinals = Hashtbl.create 4;
    frames = [];
    context;
    pointed = false;
    randoms = Hashtbl.create 1;
  }

(* What [t] waits for, [what] if it's about to, for the deadlock panic and
   the cycle's: its path, its wait, and the instances it holds, those
   whose operations it's in and hasn't let go of, the innermost first,
   `main/main:0 waits in `Async.until` at test.ren:11:13, holding `A`
   (a.go)` (foundations.md, decision 10: `sim` names the instances a
   parked task holds). *)
let waits_of ?what t =
  let what = Option.value what ~default:t.what in
  let held =
    List.fold_left
      (fun acc h ->
        if List.mem h.inst t.let_go || List.exists (fun g -> g.inst = h.inst) acc
        then acc
        else acc @ [ h ])
      [] t.holding
  in
  t.path ^ " " ^ what
  ^
  match held with
  | [] -> ""
  | hs ->
      ", holding "
      ^ String.concat ", "
          (List.map (fun h -> Printf.sprintf "`%s` (%s)" h.dep h.label) hs)

(* ---- errors from tasks ---- *)

(* The errors that came from a task, each with its path: what an error
   `main` fails with that came from one says (compiler.md, "Errors and
   panics show the task path"). An error is a value no one changes, so
   it's found by being the same one ([==]). Kept across a run's end,
   since `main`'s error is seen after it; [run] at the top starts it
   again. *)
let origins : (Value.t * string) list ref = ref []

let came_from err path =
  if not (List.exists (fun (e, _) -> e == err) !origins) then
    origins := (err, path) :: !origins

let origin err = List.find_map (fun (e, p) -> if e == err then Some p else None) !origins

(* Fire each timer that's due now, in the order they're due: the tasks
   they woke, in that order. *)
let fire_timers s =
  let at = now () in
  let due, later = List.partition (fun tm -> tm.at <= at) s.timers in
  s.timers <- later;
  List.filter_map
    (fun tm -> if tm.live () && tm.fire () then Some tm.wakes else None)
    due

(* A journal being recorded is told the tasks a poll woke, in the order
   it woke them. *)
let polled s woke =
  match (woke, s.journal) with
  | _ :: _, Some j -> j.polled woke
  | _ -> ()

(* Fire each timer that's due now, a poll. *)
let fire_due s = polled s (fire_timers s)

(* ---- I/O and signals ----

   When no task can run, the scheduler waits, in [poll], for whichever
   comes first of the earliest timer, a descriptor a task waits for being
   ready ([wait_io]), and a signal the runtime catches ([catch_signals]):
   the real `Net` waits so. A signal is only noted when it comes, by
   OCaml's handler, which writes a byte to a pipe [poll] waits on too, so
   that one that comes just before [poll] waits still ends its wait; [poll]
   is where it's seen, so a journal's polls say when, as they say when a
   timer fired. *)

(* The signals that have come and haven't been seen yet, the first first;
   and how many of each have come. Signals are the process's, not a
   scheduler's. *)
let caught : int list ref = ref []
let counts : (int, int) Hashtbl.t = Hashtbl.create 2

(* The pipe the handler writes to, once signals are caught. *)
let pipe : (Unix.file_descr * Unix.file_descr) option ref = ref None

(* OCaml's number for the signal the system numbers [n], if the runtime
   can catch it: SIGTERM and SIGINT. *)
let ocaml_signal = function 15 -> Some Sys.sigterm | 2 -> Some Sys.sigint | _ -> None

(* Catch the signal numbered [n] from now on, if it can be: the first
   that comes is noted, for [poll]; a second ends the program at once,
   since a program asked twice to stop has had its chance to do it
   gracefully (compiler.md, "`Net`"). *)
let catch n =
  match (ocaml_signal n, !pipe) with
  | Some sg, Some (_, w) when not (Hashtbl.mem counts n) ->
      Hashtbl.replace counts n 0;
      Sys.set_signal sg
        (Sys.Signal_handle
           (fun _ ->
             let k = Hashtbl.find counts n + 1 in
             Hashtbl.replace counts n k;
             if k >= 2 then begin
               flush_all ();
               Unix._exit (128 + n)
             end;
             caught := !caught @ [ n ];
             try ignore (Unix.single_write_substring w "!" 0 1)
             with Unix.Unix_error _ -> ()))
  | _ -> ()

(* `ren run`'s runtime catches SIGTERM: one that nothing waits for in
   `Net.accept_until` cancels `main`, so a plain program shuts down
   gracefully too, its `finally`s run. *)
let catch_signals () =
  if !pipe = None then begin
    let r, w = Unix.pipe ~cloexec:true () in
    Unix.set_nonblock r;
    Unix.set_nonblock w;
    pipe := Some (r, w)
  end;
  catch 15

(* Wait, as the task running, until [fd] can be read, or written if
   [out], or, with [signal], until that signal has come. *)
let wait_io ?at ?signal ~out fd what =
  let s = sched () in
  let t = s.current in
  wait ?at what (fun wake ->
      s.ios <- s.ios @ [ { fd; out; iot = t; ioid = t.wait; iowake = wake } ];
      Option.iter (fun n -> s.sigwaits <- s.sigwaits @ [ (n, t, wake) ]) signal)

(* ---- programs ----

   The real `Proc.run` waits for its program as a task waits for a timer
   (compiler.md, "The standard library (step 8)"): a timer looks at
   whether it has exited, without waiting for it, `waitpid` with
   `WNOHANG`, a millisecond after it started, then at twice the gap each
   time, up to 20 ms, so a poll that sees it ends the wait, which a
   journal writes as its poll line. Under `sim`, whose time doesn't wait
   for the system's, those timers come one after another until it has
   exited; a test uses `sim.proc()`, which takes no real time. *)

(* How [pid] ended, if it has. *)
let exited pid =
  match Unix.waitpid [ Unix.WNOHANG ] pid with
  | 0, _ -> None
  | _, status -> Some status
  | exception Unix.Unix_error (Unix.EINTR, _, _) -> None

(* Wait, as the task running, cancellably if [cancellable], for [pid] to
   exit, and give how it did; [late], at each look that finds it still
   running, can kill it. A poll that ends the wait is a journal's poll
   line if [journaled]. *)
let wait_exit ?at ~cancellable ?(late = fun () -> ()) ?(journaled = true) pid what =
  let s = sched () in
  let t = s.current in
  let ended = ref None in
  wait ~cancellable ?at what (fun wake ->
      let id = t.wait in
      let rec look gap =
        add_timer s ~at:(now () +. gap) ~wakes:t
          ~live:(fun () -> t.wait = id)
          (fun () ->
            match exited pid with
            | Some status ->
                ended := Some status;
                wake () && journaled
            | None ->
                late ();
                look (Float.min 0.02 (gap *. 2.));
                false)
      in
      look 0.001);
  match !ended with Some status -> status | None -> bug "a program's wait woken before it exited"

(* Wait for the program [pid] the task running started to exit, and give
   how it did. Cancelling the task kills it: SIGTERM, then, if it's still
   running at the cleanup deadline, SIGKILL, sent to its process group if
   [group], the one it was started in of its own (`kill: Tree`), which
   kills what it started too, `sh -c "sleep 5; true"`'s `sleep`, or to it
   alone (`kill: Child`); and the task waits for it to exit before it goes
   on being cancelled, so nothing it started is left running (async.md,
   "Cancellation"). That last wait isn't a journal's:
   a replay runs no program, so its cancelled call ends where the
   recording's `cancelled` line is, and has nothing to wait for. Without
   a scheduler, the thread waits. *)
let wait_pid ?at ~group pid =
  let target = if group then -pid else pid in
  let rec blocking () =
    match Unix.waitpid [] pid with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> blocking ()
    | _, status -> status
  in
  match !running with
  | None -> blocking ()
  | Some _ -> (
      match wait_exit ?at ~cancellable:true pid "waits for its program" with
      | status -> status
      | exception Cancelled ->
          (try Unix.kill target Sys.sigterm with Unix.Unix_error _ -> ());
          let by = now () +. cleanup in
          let killed = ref false in
          let late () =
            if (not !killed) && now () >= by then begin
              killed := true;
              try Unix.kill target Sys.sigkill with Unix.Unix_error _ -> ()
            end
          in
          ignore
            (wait_exit ?at ~cancellable:false ~late ~journaled:false pid
               "waits for its program, killed, to exit");
          raise Cancelled)

(* An `accept_until` waits for the signal numbered [n]: one that comes is
   for it from now on, kept until one asks ([stopped]), and caught if it
   can be. *)
let awaits n =
  let s = sched () in
  if not (List.mem n s.awaited) then s.awaited <- n :: s.awaited;
  catch n

(* Whether the signal numbered [n] has come, for an `accept_until`: once
   it has, every one waiting for it gives `None`. *)
let stopped n = List.mem n (sched ()).came

(* The signals that have come are seen: each is for the `accept_until`s
   waiting for it, which are woken, if one has ever waited for it, and
   otherwise it cancels the root, which the program ends with. What it
   woke. *)
let deliver s =
  let came = !caught in
  caught := [];
  List.concat_map
    (fun n ->
      if List.mem n s.awaited then begin
        if not (List.mem n s.came) then s.came <- n :: s.came;
        let mine, rest = List.partition (fun (m, _, _) -> m = n) s.sigwaits in
        s.sigwaits <- rest;
        List.filter_map (fun (_, t, wake) -> if wake () then Some t else None) mine
      end
      else
        let r = s.root_task in
        s.signalled <- Some n;
        let was = r.wait in
        cancel r;
        if was <> 0 && r.wait = 0 then [ r ] else [])
    came

(* No task can run, and something is pending: wait for the earliest
   timer, I/O or a signal, and wake what they were for, a poll: the tasks
   whose timers are due, in the order of their deadlines, then those whose
   descriptors are ready, in the order of the descriptors, then those a
   signal is for. Under `sim`, time doesn't wait: if nothing's ready now,
   it moves straight to the earliest timer. *)
let poll s =
  let first = match s.timers with tm :: _ -> Some tm.at | [] -> None in
  let timeout =
    match (s.policy, first) with
    | _ when !caught <> [] -> 0.
    | Single, Some at -> Float.max 0. (at -. now ())
    | Sim _, Some _ -> 0.
    | _, None -> -1.
  in
  let reads = List.filter_map (fun io -> if io.out then None else Some io.fd) s.ios
  and writes = List.filter_map (fun io -> if io.out then Some io.fd else None) s.ios in
  let pipe_r = Option.map fst !pipe in
  let ready_r, ready_w =
    if reads = [] && writes = [] && pipe_r = None && timeout = 0. then ([], [])
    else
      match Unix.select (Option.to_list pipe_r @ reads) writes [] timeout with
      | r, w, _ -> (r, w)
      | exception Unix.Unix_error (EINTR, _, _) -> ([], [])
  in
  (match pipe_r with
  | Some r when List.mem r ready_r -> (
      let b = Bytes.create 64 in
      try
        while Unix.read r b 0 64 > 0 do
          ()
        done
      with Unix.Unix_error _ -> ())
  | _ -> ());
  (match (s.policy, first) with
  | Sim v, Some at
    when !caught = []
         && not (List.exists (fun io -> List.mem io.fd ready_r || List.mem io.fd ready_w) s.ios) ->
      v.clock <- Float.max v.clock at
  | _ -> ());
  let timers = fire_timers s in
  let ready =
    List.stable_sort
      (fun a b -> compare a.fd b.fd)
      (List.filter
         (fun io -> List.mem io.fd (if io.out then ready_w else ready_r))
         s.ios)
  in
  let ios = List.filter_map (fun io -> if io.iowake () then Some io.iot else None) ready in
  let signals = deliver s in
  polled s (timers @ ios @ signals)

(* The task running has stopped accepting connections: `Net.accept_until`
   gave `None`. The tasks of the scopes whose bodies it's running, the
   connections in flight, and those spawned into them from now on, have
   the cleanup deadline from now: past it they see a cancel, unless
   they're in a `finally` then, which has a cleanup deadline of its own
   after it (compiler.md, "After `accept_until` returns `None`"). *)
let drain () =
  match !running with
  | None -> ()
  | Some s ->
      let by = now () +. cleanup in
      List.iter
        (fun sc ->
          if sc.drain = None then sc.drain <- Some by;
          List.iter
            (fun u ->
              if u.drained = None then begin
                u.drained <- Some by;
                interrupt_when s u
              end)
            sc.running)
        s.current.scopes

(* Following a recording, no task can run: its next poll ends the waits
   it says, in its order ([journal]), and gives [true]; or it has none
   next, and gives [false]. *)
let replay_poll s (j : journal) =
  match j.poll () with
  | None -> false
  | Some woken ->
      List.iter
        (fun (p, cancels) ->
          match List.find_opt (fun u -> j.path_of u = p && u.wait <> 0) s.alive with
          | Some t when cancels -> (
              match cancel_due t with
              | Some at when t.cancellable ->
                  jump s at;
                  ignore (wake s t t.wait Interrupt)
              | None when t.root && t.cancellable ->
                  signal_replayed s t;
                  ignore (wake s t t.wait Interrupt)
              | _ -> j.astray p)
          | Some t -> ignore (wake s t t.wait Resume)
          | None -> j.astray p)
        woken;
      true

(* Run [f] as the root task of a scheduler, its path [root], `main` or
   `test`: what it gives, or what it raises, once it has ended, which it
   does only once every task it started has. It starts under `single`'s
   policy, until a runtime's handler installs one ([install]). When no
   task can run and no timer is due to wake one, it's a deadlock:
   [deadlock] makes the panic raised in the root, where it waits, given
   what each task waits for. *)
let run ~root ~(deadlock : string list -> exn) (f : unit -> Value.t) =
  let t = task ~path:root ~root:true None in
  let s =
    {
      queue = Queue.create ();
      policy = Single;
      before = [];
      skew = 0.;
      ticks = [];
      timers = [];
      current = t;
      root_task = t;
      alive = [ t ];
      count = 0;
      waiters = Hashtbl.create 8;
      locks = Hashtbl.create 8;
      journal = None;
      ios = [];
      sigwaits = [];
      awaited = [];
      came = [];
      signalled = None;
    }
  in
  let rec loop () =
    if t.state <> Ended then
      match take s with
      | Some next ->
          step s next;
          loop ()
      | None when following s && replay_poll s (Option.get s.journal) -> loop ()
      | None -> (
          s.timers <- List.filter (fun tm -> tm.live ()) s.timers;
          s.ios <- List.filter (fun io -> io.iot.wait = io.ioid) s.ios;
          s.sigwaits <- List.filter (fun (_, u, _) -> u.wait <> 0) s.sigwaits;
          (* following a recording that has no poll next, it ends as it
             did: no timer fired then, and no I/O was ready *)
          match
            if following s then false
            else s.timers <> [] || s.ios <> [] || !caught <> []
          with
          | true ->
              poll s;
              loop ()
          | false ->
              (* every task waits, and nothing can wake one: the root
                 too, or it would have ended *)
              let waits =
                List.rev_map (fun u -> waits_of u) s.alive
              in
              t.wait <- 0;
              Queue.push (t, Raise (deadlock waits)) s.queue;
              loop ())
  in
  let before = !running in
  if Option.is_none before then origins := [];
  running := Some s;
  Queue.push (t, Start f) s.queue;
  match loop () with
  | () -> (
      running := before;
      match (t.result, s.signalled) with
      | Some v, _ -> v
      | None, Some n -> raise (Signalled n)
      | None, None -> raise Cancelled)
  | exception e ->
      running := before;
      raise e

(* ---- journals ---- *)

(* The journal [j] is recorded or replayed in this run from now on, or,
   [None], none is: the one before it, which it gives back. *)
let watch j =
  match !running with
  | Some s ->
      let before = s.journal in
      s.journal <- j;
      before
  | None -> None

(* A journal being recorded is told [line], a second failure's warning,
   which it keeps as a comment. *)
let note line =
  match !running with Some { journal = Some j; _ } -> j.note line | _ -> ()

(* ---- scopes and tasks ---- *)

(* The order scopes and `with`s begin in, across all tasks, so a scope
   and a `with` of different tasks can be told apart by which began
   first. *)
let order = ref 0

let begun () =
  incr order;
  !order

(* A new scope, of the task running, which `spawn` lets run [max] tasks
   at once. *)
let scope ~max =
  let t = (sched ()).current in
  let sc =
    {
      max;
      owner = t;
      began = begun ();
      running = [];
      room = [];
      empty = [];
      keyed = [];
      drain = None;
      ended = false;
    }
  in
  t.scopes <- sc :: t.scopes;
  sc

(* The body of [sc] has ended, and so have its tasks. *)
let closed sc =
  sc.ended <- true;
  sc.owner.scopes <- List.filter (fun x -> x != sc) sc.owner.scopes

(* Wait until [sc]'s tasks have all ended: cancellable, as the end of a
   scope's body is, or not, as cancelling them is. *)
let wait_empty ?cancellable ?at ?(what = "waits for its scope's tasks") sc =
  if sc.running <> [] then
    wait ?cancellable ?at what (fun wake -> sc.empty <- wake :: sc.empty)

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

(* What a task spawned into [sc] now can reach that a `with` installed
   inside [sc], whose body is still running: the first of them, if any,
   which is the run time's half of decision 7, a panic at the spawn
   (compiler.md, "Services stage", "Background work"). [reaching] gives
   what the task's block can reach, asked only if a `with` began inside
   [sc]. The spawn is in the bodies of the running task's `with`s, and of
   those its own spawn was in, its [context], all the way up: a task
   spawned in a scope inside a `with`'s body that spawns into a scope
   outside it spawns from inside that `with` too, though another task is
   running its body. *)
let inner sc ~(reaching : unit -> Value.installed list) =
  let t = (sched ()).current in
  match
    List.filter (fun f -> (not f.over) && f.num > sc.began) (t.frames @ t.context)
  with
  | [] -> None
  | inside ->
      let reached = reaching () in
      List.find_map
        (fun f -> List.find_opt (fun i -> List.memq i reached) f.installed)
        inside

(* Wait, as the task running, until [sc] has room for one more task, or
   has ended. *)
let room ?at sc =
  while List.length sc.running >= sc.max && not sc.ended do
    wait ?at "waits for room in its scope" (fun wake ->
        sc.room <- sc.room @ [ wake ])
  done

(* Start [thunk] as a task of [sc], labelled [label], once [sc] has room
   for it, under [key] if it's given. The task goes on the queue's end, and
   the task running goes on. A scope that has ended starts nothing: it's
   [ended ()], a panic. Only a task of a scope outside [sc] can still
   hold it then, one spawned in [sc]'s body that it captured [sc] in, and
   a task started now would outlive the scope, and the frame whose
   variables it reads (foundations.md, decision 7). *)
let rec spawn ?key ?at sc ~label ~ended thunk =
  let s = sched () in
  let parent = s.current in
  room ?at sc;
  if sc.ended then raise (ended ());
  (* `s.replace(key)`: the task under the key is cancelled, and waited
     for, and then it's all asked again, since another task may have
     started one under it, or taken the room, while this one waited. So
     there's no wait between finding the key free and the room there, and
     starting the task: a key never has two *)
  match
    Option.bind key (fun (ty, k, equal) ->
        List.find_map
          (fun (ty', k', t) ->
            if t.state <> Ended && ty' = ty && equal k k' then Some t else None)
          sc.keyed)
  with
  | Some old ->
      cancel old;
      join ?at old;
      spawn ?key ?at sc ~label ~ended thunk
  | None -> started ?key sc ~parent ~label thunk

(* [spawn]'s task, started now. *)
and started ?key sc ~parent ~label thunk =
  let s = sched () in
  let n = Option.value (Hashtbl.find_opt parent.ordinals label) ~default:0 in
  Hashtbl.replace parent.ordinals label (n + 1);
  let path = Printf.sprintf "%s/%s:%d" parent.path label n in
  let t =
    task ~context:(parent.frames @ parent.context) ~path ~root:false (Some sc)
  in
  sc.running <- sc.running @ [ t ];
  s.alive <- t :: s.alive;
  Option.iter
    (fun (ty, k, _) ->
      (* the keys of tasks that have ended are dropped, so a server that
         replaces forever keeps only its running ones *)
      sc.keyed <-
        (ty, k, t) :: List.filter (fun (_, _, u) -> u.state <> Ended) sc.keyed)
    key;
  t.drained <- sc.drain;
  Queue.push (t, Start thunk) s.queue;
  t

(* ---- `with`s ---- *)

(* The task running enters the body of a `with` that installed
   [installed]. *)
let enter_with installed =
  match current () with
  | None -> None
  | Some t ->
      let f = { num = begun (); installed; over = false } in
      t.frames <- f :: t.frames;
      Some f

(* The body of the `with` [f] has ended. No task can reach what it
   installed any more but through a scope inside it, whose tasks have all
   ended ([inner]). *)
let leave_with = function
  | None -> ()
  | Some f ->
      let t = (sched ()).current in
      f.over <- true;
      t.frames <- List.filter (fun g -> g != f) t.frames

(* ---- background work ----

   `Async.beside` and `Async.background` (compiler.md, "Services stage",
   "Background work"): a body run in the calling task, beside tasks of a
   scope of its own, which are cancelled and waited for once the body
   ends, and the first of which to fail cancels the body. *)

(* A background for a body the task running is about to run: its scope,
   which never waits for room, and the deadline the body is under, which
   carries the one the task is under already, as a timeout's does, until
   a failure moves it to now ([fail]). *)
let background () =
  let t = (sched ()).current in
  let tasks = scope ~max:max_int in
  let due = match t.deadlines with d :: _ -> d.due | [] -> Float.infinity in
  let cut = { due; dshield = t.shield } in
  t.deadlines <- cut :: t.deadlines;
  { tasks; body = t; cut; failure = None }

(* A task of [b] failed with [err]: if it's the first, it's kept, and the
   body is cut, seeing a cancel now, or at once if it's waiting. Gives
   whether it was the first. *)
let fail b err =
  match b.failure with
  | Some _ -> false
  | None ->
      b.failure <- Some err;
      b.cut.due <- now ();
      interrupt_when (sched ()) b.body;
      true

(* [b]'s body has ended, however it did: it's no longer under [b]'s
   deadline, and [b]'s tasks are cancelled and waited for, whatever the
   task is asked meanwhile. *)
let stop_background ?at b =
  let t = b.body in
  t.deadlines <- List.filter (fun d -> d != b.cut) t.deadlines;
  Fun.protect ~finally:(fun () -> closed b.tasks) (fun () -> cancel_all ?at b.tasks)

(* Whether [Cancelled], raised out of [b]'s body, was [b]'s own: a task
   of it failed, and the task running the body wasn't asked to stop
   itself (as [timeout] tells its deadline's cancel from the task's). *)
let cut_off b =
  let t = b.body in
  let asked =
    (t.asked && (t.shield = 0 || now () >= t.cleanup_by))
    || match t.drained with Some by -> now () >= by | None -> false
  in
  (not asked) && Option.is_some b.failure

(* ---- streams ----

   `Async.produce` and `Async.map_pull` (compiler.md, "Services stage",
   step 5): what's made on other tasks, given to a body that takes it in
   order, on its own task. *)

(* `Async.produce`'s buffer: what the producer has sent and the body
   hasn't taken, in order, at most [cap] of it; whether the producer has
   ended, and what it failed with if it did; and the tasks waiting to put
   one in, and to take one, each a waker. *)
type stream = {
  cap : int;
  items : Value.t Queue.t;
  mutable over : bool;
  mutable failed : Value.t option;
  mutable putters : (unit -> bool) list;
  mutable takers : (unit -> bool) list;
}

(* `Async.map_pull`'s results: each finished task's, by its item's place
   in the source, until it's taken; how many have started and been
   taken, which never differ by more than [room], `max:`; whether the
   source is over, or failed with what [source_failed] says; the task
   waiting for the next result; and how to pull the source, on the task
   that takes, and start the task for the item at a place. *)
type mapped = {
  room : int;
  results : (int, (Value.t, Value.t) result) Hashtbl.t;
  mutable started : int;
  mutable taken : int;
  mutable source_over : bool;
  mutable source_failed : Value.t option;
  mutable waiting : (unit -> bool) list;
  pull : unit -> (Value.t option, Value.t) result;
  mutable start : int -> Value.t -> unit;
}

(* What a body takes from: a producer's buffer, or `map_pull`'s results. *)
type inbox = Produced of stream | Mapped of mapped

(* The two ends, as values the prelude's source holds (value.ml,
   [sched]). *)
type Value.sched += Outbox of stream | Inbox of inbox

let stream cap =
  { cap; items = Queue.create (); over = false; failed = None; putters = []; takers = [] }

(* [x] into [st], waiting while it's full. *)
let put ?at st x =
  while Queue.length st.items >= st.cap do
    wait ?at "waits for room in `Async.produce`'s buffer" (fun wake ->
        st.putters <- st.putters @ [ wake ])
  done;
  Queue.push x st.items;
  st.takers <- wake_first st.takers

(* The producer of [st] has ended, failing with [failed] if it did: what's
   in it is still taken, and then that. *)
let end_stream st failed =
  st.over <- true;
  st.failed <- failed;
  List.iter (fun w -> ignore (w ())) st.takers;
  st.takers <- []

(* The next of [st], waiting while there's none and its producer runs:
   [None] once it's ended and nothing's left, or what it failed with. *)
let take ?at st =
  while Queue.is_empty st.items && not st.over do
    wait ?at "waits for `Async.produce`'s producer" (fun wake ->
        st.takers <- st.takers @ [ wake ])
  done;
  match Queue.take_opt st.items with
  | Some x ->
      st.putters <- wake_first st.putters;
      Ok (Some x)
  | None -> ( match st.failed with Some err -> Error err | None -> Ok None)

(* Start a task for each item of [m]'s source there's room for, pulling
   it on the task running: one more each time one is taken. *)
let fill m =
  while (not m.source_over) && m.source_failed = None && m.started - m.taken < m.room do
    match m.pull () with
    | Ok (Some v) ->
        let i = m.started in
        m.started <- i + 1;
        m.start i v
    | Ok None -> m.source_over <- true
    | Error err -> m.source_failed <- Some err
  done

(* The task for the item at [i] of [m] has ended, with [r]. *)
let finished m i r =
  Hashtbl.replace m.results i r;
  List.iter (fun w -> ignore (w ())) m.waiting;
  m.waiting <- []

(* The next result of [m], in the source's order, waiting for it while its
   task runs, and starting the next task; [None] once the source is over
   and every result's taken; or what the source or the task failed with,
   in its place. *)
let take_mapped ?at m =
  if m.taken = m.started then
    match m.source_failed with Some err -> Error err | None -> Ok None
  else begin
    while not (Hashtbl.mem m.results m.taken) do
      wait ?at "waits for `Async.map_pull`'s next result" (fun wake ->
          m.waiting <- wake :: m.waiting)
    done;
    let r = Hashtbl.find m.results m.taken in
    Hashtbl.remove m.results m.taken;
    m.taken <- m.taken + 1;
    fill m;
    match r with Ok v -> Ok (Some v) | Error err -> Error err
  end

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
            add_timer s ~at:(now () +. secs) ~wakes:t
              ~live:(fun () -> t.wait = id)
              wake)

(* ---- runtimes ---- *)

(* Move the times the task running keeps on by [d] seconds, and every
   timer's, when the scheduler's time is changed under it: what a new
   policy's time is from what the old one's was. Only it is running,
   so nothing else keeps a time. *)
let rebase s d =
  if d <> 0. then begin
    let t = s.current in
    t.asked_at <- t.asked_at +. d;
    t.cleanup_by <- t.cleanup_by +. d;
    List.iter (fun dl -> dl.due <- dl.due +. d) t.deadlines;
    s.timers <-
      List.map (fun tm -> { tm with at = tm.at +. d }) (List.filter (fun tm -> tm.live ()) s.timers)
  end

(* Install [p], the policy of a runtime's handler being installed, for
   its `with`'s body: what [leave] is given to put back the one before.
   Policies never mix, so it's [busy ()], a panic, if any task but the one
   installing it is alive (compiler.md, "A runtime installed while any
   task but the one installing it is running is a panic"). `sim`'s time
   starts at 0, whatever the time was, so a seed's run is the same
   whenever it's run. *)
let install p ~busy =
  match !running with
  | None -> 0
  | Some s ->
      if List.exists (fun u -> u != s.current) s.alive then raise (busy ());
      let was = now () in
      s.before <- s.policy :: s.before;
      s.policy <- p;
      rebase s (now () -. was);
      List.length s.before

(* The `with` of the runtime that [install] gave [n] ends: the policy
   before it is put back. Its tasks have all ended (every task reaches
   the runtime that runs it, so none was spawned in its body into a scope
   outside it: [inner]), so again only the task running keeps a time. *)
let leave n =
  match !running with
  | Some s when n > 0 ->
      let was = now () in
      while List.length s.before >= n do
        match s.before with
        | p :: rest ->
            s.policy <- p;
            s.before <- rest
        | [] -> ()
      done;
      rebase s (now () -. was)
  | _ -> ()

(* `sim`'s policy, its tape from [seed]. *)
let sim seed = Sim { tape = Int64.of_int seed; clock = 0. }

(* The scheduler's time in milliseconds, what `sim.clock()` reads. *)
let time_ms () = Int64.of_float (Float.round (now () *. 1000.))

(* `TestClock.advance(d)` of `sim.clock()`: the scheduler's time moves on
   by [ms] milliseconds at once, and what it passes wakes. *)
let advance ms =
  match !running with
  | Some s when ms > 0L ->
      let d = Int64.to_float ms /. 1000. in
      (match s.policy with
      | Sim v -> v.clock <- v.clock +. d
      | Single -> s.skew <- s.skew +. d);
      fire_due s
  | _ -> ()

(* ---- `yield`, `tick` and `Async.until` ---- *)

(* `Async.yield()`: the task running goes to the end of the queue, so
   every other task that can run, runs first. *)
let yield_ ?at () = wait ?at "yields" (fun wake -> ignore (wake ()))

(* `Async.tick()`: the task running waits until each task in the queue
   now has run until it waits, or ended. In `single`'s order, one queue
   first in first out, that's the queue's end, as for [yield_]: what was
   in the queue runs first, and what it wakes goes behind. Under `sim`,
   where the next task is drawn from the queue, the task waits until
   each of those has run until it waited, or ended ([waited]): a
   scheduling point isn't a wait, since under `single` there's none. *)
let tick ?at () =
  let s = sched () in
  match s.policy with
  | Single -> wait ?at "waits in `Async.tick`" (fun wake -> ignore (wake ()))
  | Sim _ when following s -> wait ?at "waits in `Async.tick`" (fun wake -> ignore (wake ()))
  | Sim _ ->
      let pending = List.of_seq (Seq.map fst (Queue.to_seq s.queue)) in
      wait ?at "waits in `Async.tick`" (fun wake ->
          match pending with
          | [] -> ignore (wake ())
          | _ -> s.ticks <- { pending; woken = wake } :: s.ticks)

(* A scheduling point before a call of an operation of a shared,
   exclusive instance ([locked]), where the order of two tasks' calls can
   be seen: under `sim` the task running goes back on the queue, and the
   tape picks what runs next, itself among them; under `single`, nothing
   happens ("`sim`'s choices"). *)
let point ?at () =
  match !running with
  | Some ({ policy = Sim _; _ } as s) when not (following s) ->
      wait ?at "yields" (fun wake ->
          s.current.pointed <- true;
          ignore (wake ()))
  | _ -> ()

(* ---- operations that don't interleave ---- *)

(* How many of the operations of the instance numbered [inst] [t] is in. *)
let depth_in t inst = List.length (List.filter (fun h -> h.inst = inst) t.holding)

(* [xs] without the first [x] in it. *)
let rec remove_first x = function
  | [] -> []
  | y :: rest -> if y = x then rest else y :: remove_first x rest

(* The instance numbered [inst], exclusive if [excl], can be reached by a
   task being spawned (compiler.md, "Operations that don't interleave"):
   from now on, if it's exclusive, its operations keep it from each
   other's tasks, for good. A task in one of its operations now, which
   reached it before it was shared, holds it, as it would have; one
   waiting in `Async.until` on it, or in a call a `release` covers, has
   let go of it. Without a scheduler, nothing is spawned. *)
let share inst ~excl =
  match !running with
  | Some s when excl && not (Hashtbl.mem s.locks inst) ->
      let waiting t =
        List.exists
          (fun w -> w.wt == t && w.wt.wait = w.id)
          (Option.value (Hashtbl.find_opt s.waiters inst) ~default:[])
      in
      let depth t = depth_in t inst in
      let holder =
        List.find_opt
          (fun t -> depth t > 0 && not (waiting t || List.mem inst t.let_go))
          s.alive
      in
      Hashtbl.replace s.locks inst
        {
          holder;
          depth = (match holder with Some t -> depth t | None -> 0);
          callers = Queue.create ();
        }
  | _ -> ()

(* Whether the instance numbered [inst] is shared and exclusive: what
   `sim` makes a scheduling point of each call of ([point]). *)
let locked inst =
  match !running with Some s -> Hashtbl.mem s.locks inst | None -> false

(* Whether a released instance is the tape's to give: under `sim`, but
   not while it follows a recording, which runs in `single`'s order
   (decision 10, "The queue is fair, not first in first out"). *)
let fair s = match s.policy with Sim _ -> not (following s) | Single -> false

(* The instance numbered [inst], locked by [lk], has no task in its
   operations now. Under `single` it goes to the first of the tasks
   waiting in `Async.until` on it whose condition holds now, back in as
   many operations as it was, or else to the first caller still waiting
   for it, which [holding] puts in one. Each is woken; the others go on
   waiting (compiler.md, "The rest of `Async`": a waiter whose condition
   holds comes first, then the queue's first caller). Under `sim`
   ([fair]) it goes to none: every waiter whose condition holds and
   every queued caller is woken, and the first of them, or of the tasks
   arriving meanwhile, that the tape runs takes it; the others queue
   again ([take_back], [holding]). So the tape chooses among the waiters
   and the arrivals, and none is passed over without bound but by its
   odds (compiler.md, "Services stage", "`sim`'s fair choice"). A
   condition reads only the instance's state, which only its operations
   change, so each release is when one can have come to hold. It's
   evaluated as its waiter's, so a panic in it is the waiter's, raised
   where it waits. *)
let rec released inst =
  match !running with
  | None -> ()
  | Some s -> (
      let lk = Hashtbl.find_opt s.locks inst in
      match lk with
      | Some lk when fair s ->
          ignore (wake_waiter s inst None ~all:true);
          let callers = List.of_seq (Queue.to_seq lk.callers) in
          Queue.clear lk.callers;
          List.iter (fun (_, wake) -> ignore (wake ())) callers
      | _ -> (
          let woke = wake_waiter s inst lk ~all:false in
          match lk with
          | Some lk when not woke ->
              let rec next () =
                match Queue.take_opt lk.callers with
                | None -> ()
                | Some (t, wake) ->
                    (* one cancelled meanwhile isn't waiting any more *)
                    if wake () then begin
                      lk.holder <- Some t;
                      lk.depth <- 0
                    end
                    else next ()
              in
              next ()
          | _ -> ()))

(* Wake the first task waiting in `Async.until` on [inst] whose condition
   holds, or with [all] each one whose does, giving the one it wakes the
   instance if it's locked by [lk]. *)
and wake_waiter s inst lk ~all =
  match Hashtbl.find_opt s.waiters inst with
  | None | Some [] -> false
  | Some ws ->
      (* those still waiting: one cancelled meanwhile isn't *)
      let ws = List.filter (fun w -> w.wt.wait = w.id) ws in
      let woke = ref false in
      let give w =
        woke := true;
        Option.iter
          (fun lk ->
            lk.holder <- Some w.wt;
            lk.depth <- w.wdepth)
          lk
      in
      let rec first = function
        | [] -> []
        | w :: rest -> (
            match as_task s w.wt w.holds with
            | true ->
                ignore (wake s w.wt w.id Resume);
                give w;
                if all then first rest else rest
            | false -> w :: first rest
            | exception e ->
                (* it ends where it waits, so it's not in the instance *)
                ignore (wake s w.wt w.id (Raise e));
                first rest)
      in
      Hashtbl.replace s.waiters inst (first ws);
      !woke

(* [f ()], as if [t] were running: what a panic says it was in. [f]
   can't wait, since a condition uses nothing. *)
and as_task s t f =
  let was = s.current in
  s.current <- t;
  match f () with
  | v ->
      s.current <- was;
      v
  | exception e ->
      s.current <- was;
      raise e

(* The task running leaves one of the operations of the instance
   numbered [inst]: if it's locked, and the task is in none of them now,
   it's released. *)
let leave_lock s inst =
  match Hashtbl.find_opt s.locks inst with
  | Some lk ->
      lk.depth <- lk.depth - 1;
      if lk.depth <= 0 then begin
        lk.holder <- None;
        lk.depth <- 0;
        released inst
      end
  | None -> released inst

(* The task running, [t], takes back the instance numbered [inst], locked
   by [lk], which it let go of in [depth] of its operations, in
   `Async.until` or for a call a `release` covers: at once if it's free,
   or if [released] gave it to it, and otherwise queued behind the
   callers, as many times as it's woken and finds it taken (under `sim`,
   where a release wakes them all). It can't be cancelled meanwhile: the
   operation it's in goes on, its `finally` too, with the instance. *)
let rec take_back ?at s t inst lk depth =
  match lk.holder with
  | None ->
      lk.holder <- Some t;
      lk.depth <- depth
  | Some h when h == t -> lk.depth <- depth
  | Some _ ->
      t.queued <- Some inst;
      Fun.protect
        ~finally:(fun () -> t.queued <- None)
        (fun () ->
          wait ~cancellable:false ?at "waits for its instance back" (fun wake ->
              Queue.push (t, wake) lk.callers));
      take_back ?at s t inst lk depth

(* [f ()], as the operation [label] of the instance numbered [inst],
   installed as [dep]: the task running is in it meanwhile, and once it
   returns, or fails, or is cancelled, the instance is released
   ([released]). If the instance is locked, shared and exclusive, the
   task waits first while another task is in one of its operations,
   queued behind the others waiting (first in first out under `single`,
   the tape's choice under `sim`), and has it until it returns
   (compiler.md, "Operations that don't interleave"); [what] is what the
   deadlock panic says it waits for, and [at] the program's call. A call
   back into it from the task in it could never go on, which [reentered]
   makes a panic of; and so could one that would wait for a task that
   waits, through the tasks each waits for, for this one, which [cycle]
   makes a panic of, given what each task in the cycle waits for. It's
   raised at once, since the deadlock panic comes only when every task
   waits, and a server's accept loop never does.

   A panic that leaves it notes that it did, for `Async.isolate`
   ([isolatable]), and leaves the lock taken for good: what it was
   changing may be half changed, and only an isolate inside its `with` can
   go on, whose tasks are all cancelled. Without a scheduler, as when a
   value is made, it's just [f ()]. *)
let holding ?at ~what ~reentered ~cycle inst ~dep label f =
  match !running with
  | None -> f ()
  | Some s -> (
      let t = s.current in
      let rec take () =
        match Hashtbl.find_opt s.locks inst with
        | Some ({ holder = None; _ } as lk) ->
            lk.holder <- Some t;
            lk.depth <- 1
        | Some { holder = Some h; _ } when h == t -> raise (reentered ())
        | Some lk -> (
            (* the tasks this one would wait for, each queued for an
               instance the next is in: if they come back to this one,
               none of them can go on *)
            let rec chain (h : task) seen =
              if h == t then Some (List.rev seen)
              else if List.memq h seen then None
              else
                match h.queued with
                | Some i -> (
                    match Hashtbl.find_opt s.locks i with
                    | Some { holder = Some h'; _ } -> chain h' (h :: seen)
                    | _ -> None)
                | None -> None
            in
            (match chain (Option.get lk.holder) [] with
            | Some others ->
                raise (cycle (waits_of ~what t :: List.map (fun u -> waits_of u) others))
            | None -> ());
            (* given it by [released] once it's this one's turn, or woken
               to try again (under `sim`); or this task is cancelled, and
               it stays where it was *)
            t.queued <- Some inst;
            Fun.protect
              ~finally:(fun () -> t.queued <- None)
              (fun () -> wait ?at what (fun wake -> Queue.push (t, wake) lk.callers));
            match lk.holder with
            | Some h when h == t -> lk.depth <- lk.depth + 1
            | _ -> take ())
        | None -> ()
      in
      take ();
      t.holding <- { inst; label; dep } :: t.holding;
      let leave () =
        match t.holding with
        | h :: rest when h.inst = inst -> t.holding <- rest
        | _ -> bug "an operation left out of turn"
      in
      match f () with
      | v ->
          leave ();
          leave_lock s inst;
          v
      | exception Cancelled ->
          leave ();
          leave_lock s inst;
          raise Cancelled
      | exception e ->
          (* the lock, if it has one, stays taken; and a panic out of a
             call a `release` covers in it isn't letting go any more *)
          leave ();
          if depth_in t inst = 0 then
            t.let_go <- List.filter (fun i -> i <> inst) t.let_go;
          t.through <- inst :: t.through;
          raise e)

(* The instance whose operation `Async.until` or `release` is written in,
   for the code labelled [label]: the innermost the task running is in
   with that arm's label, or else the innermost, if it's in one. *)
let op_instance label =
  match current () with
  | None -> None
  | Some t -> (
      match List.find_opt (fun h -> h.label = label) t.holding with
      | Some h -> Some h.inst
      | None -> Option.map (fun h -> h.inst) (List.nth_opt t.holding 0))

(* At the scheduler's time [ms], in milliseconds, the instance numbered
   [inst] is released, as if an operation of it had just ended, unless a
   task is in it, whose leaving releases it anyway: so a task waiting in
   `Async.until` on it for a condition that reads the time is checked
   again then (`sim_alarm`, which `sim.proc()`'s programs wait with, so
   that one doesn't keep the instance while it takes its time). The timer
   says it woke the task that set it if that's who [released] woke. *)
let alarm inst ms =
  match !running with
  | None -> ()
  | Some s ->
      let t = s.current in
      add_timer s
        ~at:(Int64.to_float ms /. 1000.)
        ~wakes:t
        ~live:(fun () -> true)
        (fun () ->
          let was = t.wait in
          (match Hashtbl.find_opt s.locks inst with
          | Some { holder = Some _; _ } -> ()
          | _ -> released inst);
          was <> 0 && t.wait <> was)

(* Wait, as the task running, in `Async.until` on the instance numbered
   [inst], until it's released with [holds] holding. If the instance is
   locked, the task lets go of it while it waits, which releases it, and
   has it back once it's woken ([wake_waiter], [take_back]). *)
let until ?at inst ~holds =
  let s = sched () in
  let t = s.current in
  let lk = Hashtbl.find_opt s.locks inst in
  let depth =
    match lk with Some { holder = Some h; depth; _ } when h == t -> depth | _ -> 0
  in
  let waiting () =
    wait ?at "waits in `Async.until`" (fun _ ->
      let w = { wt = t; id = t.wait; holds; wdepth = depth } in
      let ws = Option.value (Hashtbl.find_opt s.waiters inst) ~default:[] in
      Hashtbl.replace s.waiters inst (ws @ [ w ]);
      (* let go of it: another task may change the state now, which is
         what this waits for *)
      match lk with
      | Some lk when depth > 0 ->
          lk.holder <- None;
          lk.depth <- 0;
          (* not this one: it's just begun waiting, on a condition that
             didn't hold *)
          Hashtbl.replace s.waiters inst (List.filter (fun x -> x != w) (ws @ [ w ]));
          released inst;
          let now = Option.value (Hashtbl.find_opt s.waiters inst) ~default:[] in
          Hashtbl.replace s.waiters inst (now @ [ w ])
      | _ -> ())
  in
  (* it holds nothing of it meanwhile, which the deadlock panic says *)
  t.let_go <- inst :: t.let_go;
  let back () =
    (match lk with Some lk when depth > 0 -> take_back ?at s t inst lk depth | _ -> ());
    t.let_go <- remove_first inst t.let_go
  in
  match waiting () with
  | () -> back ()
  | exception e ->
      (* cancelled while it waited, or its condition panicked: it's still
         in the operation, whose `finally` runs with the instance, so it
         has it back first, once it's its turn *)
      back ();
      raise e

(* The task running lets go of the instance numbered [inst], whose
   operation it's in, for the call a `release` covers (compiler.md,
   "Services stage", step 4): if it's locked and this task holds it, it's
   released, as if the operation had ended, and under `sim` the tape
   chooses what runs next ([point]), so a stale read across a `release`
   is found by a seed (decision 10). An instance no spawned task can
   reach has no lock and nothing else to run: it's a plain call. *)
let let_go ?at inst =
  match !running with
  | None -> ()
  | Some s -> (
      let t = s.current in
      t.let_go <- inst :: t.let_go;
      match Hashtbl.find_opt s.locks inst with
      | Some lk ->
          (match lk.holder with
          | Some h when h == t ->
              lk.holder <- None;
              lk.depth <- 0;
              released inst
          | _ -> ());
          point ?at ()
      | None -> ())

(* The task running takes back the instance it last let go of with
   [let_go], however the call ended, queueing like any caller
   ([take_back]), back in as many of its operations as it is. *)
let retake ?at () =
  match !running with
  | None -> ()
  | Some s -> (
      let t = s.current in
      match t.let_go with
      | inst :: rest ->
          (match Hashtbl.find_opt s.locks inst with
          | Some lk -> take_back ?at s t inst lk (depth_in t inst)
          | None -> ());
          t.let_go <- rest
      | [] -> bug "an instance taken back that wasn't let go of")

(* ---- `Async.timeout` ---- *)

(* [f ()], under a deadline [ms] milliseconds from now, or the one the
   task is already under, if that's sooner: deadlines carry down. What
   [f] gives, or fails with, it gives; [Cancelled] that only the
   deadline caused, once it has reached here, is [Error ()], the
   timeout's `Timeout`. So a body that finished, returning or failing,
   gives what it did however late, and one whose cancel was shielded,
   in a `finally`, is late too, never `Timeout`. *)
let timeout ms (f : unit -> 'a) : ('a, unit) result =
  match current () with
  | None -> Ok (f ())
  | Some t -> (
      let due = now () +. (Int64.to_float ms /. 1000.) in
      let due =
        match t.deadlines with d :: _ -> Float.min due d.due | [] -> due
      in
      let d = { due; dshield = t.shield } in
      t.deadlines <- d :: t.deadlines;
      let leave () = t.deadlines <- List.filter (fun x -> x != d) t.deadlines in
      match f () with
      | v ->
          leave ();
          Ok v
      | exception Cancelled ->
          leave ();
          (* the task's own cancel, if it sees it, goes on; otherwise it
             was the deadline's *)
          let asked =
            (t.asked && (t.shield = 0 || now () >= t.cleanup_by))
            || match t.drained with Some by -> now () >= by | None -> false
          in
          if (not asked) && now () >= d.due then Error () else raise Cancelled
      | exception e ->
          leave ();
          raise e)

(* ---- `Async.isolate` ---- *)

(* [f ()], as the body of an `Async.isolate`; or, if it raises an
   exception [caught] makes a value of, a panic, and [isolatable] says
   it can be, that value. *)
let rec isolated ~caught f =
  match current () with
  | None -> f ()
  | Some t -> (
      let i = { base = !Value.instances; depth = List.length t.holding } in
      t.isolates <- i :: t.isolates;
      t.through <- [];
      let leave () = t.isolates <- List.filter (fun x -> x != i) t.isolates in
      match f () with
      | v ->
          leave ();
          v
      | exception e -> (
          match if isolatable () then caught e else None with
          | Some v ->
              leave ();
              (* it's left nothing behind *)
              t.through <- [];
              v
          | None ->
              leave ();
              raise e))

(* Whether the panic the task running is raising, where it's got to, is
   one the innermost `Async.isolate` it's in will make a value: none of
   the operations it has left, or is still in since the isolate began,
   is one of an instance installed outside it, since that instance's
   state could be half changed (foundations.md, decision 8). Asked as it
   goes, so the `finally`s and scopes it leaves on the way know to clean
   up, as they don't for a panic that ends the program. *)
and isolatable () =
  match current () with
  | None -> false
  | Some t -> (
      match t.isolates with
      | [] -> false
      | i :: _ ->
          let inside = List.length t.holding - i.depth in
          let outside n = n <= i.base in
          (not (List.exists outside t.through))
          && not
               (List.exists
                  (fun h -> outside h.inst)
                  (List.filteri (fun k _ -> k < inside) t.holding)))

