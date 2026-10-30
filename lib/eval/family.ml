(* The keyed instance family (foundations.md, decision 18, "The keyed
   instance family: a runtime primitive"; compiler.md, "Services stage",
   "The keyed instance family"): instances of one handler, by key, which
   the runtime keeps for a library, since a program never holds an
   instance (the bet). `striped` keeps its stripes in one, and `actors`
   its actors.

   A family is a second scheduler inside the first (the brief's risk), so
   it's a module of its own, beside sched.ml, using its waits, and only
   its waits. It does what's the runtime's: make an instance for a key,
   pin one while an operation of it runs, evict one that's evictable,
   list the live keys, and stamp each instance with when it was last
   taken, which a library's policy reads. It decides nothing a library
   decides: which instance to evict, when, how many to keep, how to
   route. The interpreter's half, making an instance and running an
   operation of it or its `finally`, is eval.ml's, which gives a family
   what it needs of it when it opens one ([opened]).

   **Eviction is sampled** (experiments/runtime-p2/SYNTHESIS.md, K1b):
   one cap for the whole family, and each take of an instance, a pin,
   writes its use stamp, the family's count of takes then, which is the
   only thing a take writes for eviction. A full family gives the
   library its evictable instances, in the order they were made, each
   with its stamp, and the library picks the victim: `actors` samples 5
   with `Random` and evicts the oldest-stamped. Nothing here keeps an
   order of release, and there are no partitions, so the victim depends
   only on the takes and on what the library draws, which a journal
   replays (concurrency.md, "Many cores": `parts:` left `actors`).

   **Names, by one rule** (decision 11, as a task's path is named): a
   family is named where it's installed, by the dependency its opening
   handler is installed as, snake_cased, `docs` for `Docs`, and a second
   family one handler opens is `docs.2`; an instance is its family's
   name, its key written as a value is, and its life, which counts the
   key's lives from 1: `docs[DocId(7)]#3` ([name_of]). The deadlock panic
   names an instance a parked task holds so.

   **Posts** (concurrency.md, rules 2 to 4): a call put in a key's
   mailbox, which belongs to the key, not to its instance, so the order of
   one task's posts survives eviction; a task of the family's, one per key
   with mail, delivers each as one operation of the key's instance, in
   order ([deliver]). A post makes its instance, as a pin does, so what a
   delivery runs on is always live (queued mail keeps an instance from
   eviction, [evictable]) and a delivery never runs setup or needs a slot;
   then it waits for room in its key's mailbox, at most [mailbox] calls,
   and only there ([post]): a slow key holds up only its own posters.
   There's no mail inside a family: an instance's operations reach only
   families installed outside it (its `uses` resolve there), and a block
   that pins one of a family's instances reaches none installed inside it
   ([held]), so every wait points outward, and the waits can't close a
   cycle (research/structured-actors/MODEL.md). The family's end
   delivers what's queued, which may post outward, then runs its
   instances' `finally`s; if it's cancelled, it cancels what's running,
   drops what's queued, and the `finally`s see `Err(Cancelled)`
   ([close]). *)

(* Where an instance is in its life. *)
type state = Making | Live | Evicting

(* An instance: its key, its life ([name_of]); its implementation of
   the family's dependency and its `finally`, once it's made; how many
   operations of it are running, [pins]; its use stamp, [used], the family's count of takes
   when it was last taken; when it last stopped being pinned, by the
   scheduler's clock, which is how long it's been idle ([evictable_keys]);
   and what waits for it to be made, or, while it's evicted, for its
   `finally` to end, which [evictor] runs. *)
type inst = {
  key : Value.t;
  life : int;
  mutable installed : Value.installed option;
  mutable finally : Value.t option;
  mutable pins : int;
  mutable used : int;
  mutable released_at : float;
  mutable state : state;
  mutable waiting : (unit -> bool) list;
  mutable failed : exn option;
      (** what its setup failed with, which those that waited for it to be
          made fail with too *)
  mutable evictor : Sched.task option;
}

(* What eval.ml does for a family: make an instance for a key, its
   implementation and its `finally`; run a `finally`, given `Ok(())`, or
   `Err(Cancelled)` if the family's `with` was cancelled; run a posted
   call, a value of the dependency's `D.Call`, as one operation of an
   instance's; and show a key, as a value of the keys' type is shown, and
   a call. *)
type runner = {
  make : Value.t -> Value.installed * Value.t option;
  finish : cancelled:bool -> Value.t -> unit;
  deliver : string -> Value.installed -> Value.t -> unit;
  show : Value.t -> string;
  show_call : Value.t -> string;
}

(* A key's mailbox: its posted calls, the first posted first, each with
   the task that posted it; whether a task of the family's is delivering
   them, and whose call it's delivering now; the tasks waiting for their
   own posts to be delivered before they call the instance ([ordered]);
   and those waiting for room in it ([post]). *)
type box = {
  calls : (Sched.task option * Value.t) Queue.t;
  mutable delivering : bool;
  mutable current : Sched.task option;
  mutable after : (unit -> bool) list;
  mutable room : (unit -> bool) list;
}

type family = {
  name : string;
  dep : string;  (** the dependency its opener is installed as, `Docs` *)
  num : int;
      (** its place among the families opened, which a family opened
          inside another's `with` comes after: what "installed inside"
          means to rule 3 ([held]) *)
  mailbox : int;  (** each key's bound ([post]) *)
  shield : int;
      (** how deep in `finally`s the `with` that installs it began, which
          its drain sees a cancel as ([close]) *)
  equal : Value.t -> Value.t -> bool;
  compare : Value.t -> Value.t -> int;
      (** keys in their type's derived order, which `at_all` holds them
          in ([hold]) *)
  cap : int;  (** the most instances it keeps *)
  mutable insts : inst list;  (** its instances, the first made first *)
  mutable room : (unit -> bool) list;  (** the tasks waiting for room in it *)
  mutable takes : int;  (** how many times an instance was taken, which stamps each ([take]) *)
  runner : runner;
  mutable made : int;
  mutable evicted : int;
  mutable lives : (Value.t * int) list;
      (** each key made, with its last life's number, kept across eviction *)
  mutable closed : bool;
  mutable boxes : (Value.t * box) list;
      (** each key with calls queued or being delivered, and its queue: the
          key's, not its instance's *)
  tasks : Sched.scope;  (** where its deliveries run, which [close] waits for *)
  context : Sched.frame list;
      (** the `with`s the opener was in, which its deliveries are in too *)
  mutable deliveries : Sched.task list;  (** those running now *)
  mutable at_edge : (unit -> unit) option;
      (** what the library runs at each call from outside into one of its
          instances, before it takes it ([entering]): `actors`' chaos *)
}

(* A family as a program holds it, `Family<K, D>`: a handle, not an
   instance, so keeping one in a handler's state keeps none (value.ml,
   [sched]). *)
type Value.sched += Family of family

(* A panic of the family's, which the interpreter says at the program's
   call that reached it, as a built-in's. *)
let panic msg = raise (Builtins.Panic msg)

(* What's journaled of a family (journal.ml, version 3), on the task
   that did it: a family opened, an instance made
   and one evicted, each named by the one rule, and a call posted, to a
   key, not an instance, since the queue is the key's: `posted
   docs[DocId(7)] Edit { op: "a" }`. *)
let on_made name = Sched.family_event ("made " ^ name)
let on_evicted name = Sched.family_event ("evicted " ^ name)
let on_opened name = Sched.family_event ("opened " ^ name)
let on_posted to_ call = Sched.family_event (Printf.sprintf "posted %s %s" to_ call)

(* The family each live instance is of, and the instance, by its number
   (Value.installed's [inst]): what an operation's family is found by
   ([entering]). Numbers are never reused, so an entry a run that
   panicked left is never found. *)
let owners : (int, family * inst) Hashtbl.t = Hashtbl.create 16

(* The families whose instances each task pins for a block, the last
   pinned first, by the task: what rule 3 reads ([held]). A task is
   compared by itself, not by its path. *)
let pinning : (Sched.task * family list ref) list ref = ref []

let me () = Sched.current ()

let pinned_by t =
  match List.find_opt (fun (t', _) -> t' == t) !pinning with
  | Some (_, fs) -> !fs
  | None -> []

let pinned () = match me () with Some t -> pinned_by t | None -> []

let add_pin f =
  match me () with
  | None -> ()
  | Some t -> (
      match List.find_opt (fun (t', _) -> t' == t) !pinning with
      | Some (_, fs) -> fs := f :: !fs
      | None -> pinning := (t, ref [ f ]) :: !pinning)

let drop_pin f =
  match me () with
  | None -> ()
  | Some t -> (
      match List.find_opt (fun (t', _) -> t' == t) !pinning with
      | Some (_, fs) ->
          let rec drop = function
            | [] -> []
            | g :: rest -> if g == f then rest else g :: drop rest
          in
          fs := drop !fs;
          if !fs = [] then pinning := List.filter (fun (t', _) -> t' != t) !pinning
      | None -> ())

(* The instances each task holds for an `at_all` block, with their
   family, the last held first, by the task: inside the block, `at` of a
   key it holds doesn't wait, and `at` of any other key of the family is
   rule 3's panic ([pin]). *)
let holding : (Sched.task * (family * inst list) list ref) list ref = ref []

(* What this task holds of [f] for an `at_all` block, the innermost's, if
   it holds any. *)
let holds f =
  match me () with
  | None -> None
  | Some t -> (
      match List.find_opt (fun (t', _) -> t' == t) !holding with
      | Some (_, hs) -> List.assq_opt f !hs
      | None -> None)

let add_hold f insts =
  match me () with
  | None -> ()
  | Some t -> (
      match List.find_opt (fun (t', _) -> t' == t) !holding with
      | Some (_, hs) -> hs := (f, insts) :: !hs
      | None -> holding := (t, ref [ (f, insts) ]) :: !holding)

let drop_hold f =
  match me () with
  | None -> ()
  | Some t -> (
      match List.find_opt (fun (t', _) -> t' == t) !holding with
      | Some (_, hs) ->
          hs := List.remove_assq f !hs;
          if !hs = [] then holding := List.filter (fun (t', _) -> t' != t) !holding
      | None -> ())

(* A dependency's name snake_cased: `HitCounter`'s `hit_counter`. *)
let snake name =
  let b = Buffer.create (String.length name + 4) in
  String.iteri
    (fun i c ->
      if c >= 'A' && c <= 'Z' then (
        if i > 0 then Buffer.add_char b '_';
        Buffer.add_char b (Char.lowercase_ascii c))
      else Buffer.add_char b c)
    name;
  Buffer.contents b

(* The families each `with` has opened while its handler was made, by
   the dependency it installs, which names the next one ([opened]). *)
let opening : (string * int ref) list ref = ref []

(* [f ()], making the instance a `with` installs as [dep]: a family its
   handler opens meanwhile is named by it. *)
let installing dep f =
  let around = !opening in
  opening := (dep, ref 0) :: around;
  Fun.protect ~finally:(fun () -> opening := around) f

(* A family opened now, by the handler being made for the innermost
   `with` that's installing one, of at most [cap] instances. *)
let opened_count = ref 0

let opened ~cap ~mailbox ~equal ~compare runner =
  if cap < 1 then panic (Printf.sprintf "a family keeps at least 1 instance, not %d" cap);
  if mailbox < 1 then panic (Printf.sprintf "a key's mailbox holds at least 1 call, not %d" mailbox);
  let dep, name =
    match !opening with
    | (dep, n) :: _ ->
        incr n;
        (dep, if !n = 1 then snake dep else Printf.sprintf "%s.%d" (snake dep) !n)
    | [] -> ("Instances", "family")
  in
  incr opened_count;
  on_opened name;
  let f =
    {
      name;
      dep;
      num = !opened_count;
      mailbox;
      shield = Sched.shield ();
      equal;
      compare;
      cap;
      insts = [];
      room = [];
      takes = 0;
      runner;
      made = 0;
      evicted = 0;
      lives = [];
      closed = false;
      boxes = [];
      tasks = Sched.owned ();
      context = Sched.context ();
      deliveries = [];
      at_edge = None;
    }
  in
  f

(* An instance's name by the one rule: `docs[DocId(7)]#3`. *)
let name_of f (i : inst) =
  Printf.sprintf "%s[%s]#%d" f.name (f.runner.show i.key) i.life

let ended f =
  if f.closed then panic "this family ended with the `with` that opened it"

(* [k]'s instance, if it has one that isn't being evicted. *)
let find f k = List.find_opt (fun i -> i.state <> Evicting && f.equal i.key k) f.insts

(* [k]'s instance whose `finally` is running, if one is: a key has one
   instance at a time, so the next isn't made until it's over. *)
let dying f k = List.find_opt (fun i -> i.state = Evicting && f.equal i.key k) f.insts

(* [k]'s queue of posted calls, if it has calls queued or being
   delivered. *)
let box_of f k = List.find_map (fun (k', b) -> if f.equal k' k then Some b else None) f.boxes

(* Whether calls are queued for [k]: they count as waiting for its
   instance (decision 18). *)
let has_mail f k =
  match box_of f k with Some b -> not (Queue.is_empty b.calls) | None -> false

(* Whether [i] can be evicted: it's live, no operation of it runs, and no
   call is queued for it, so a delivery never makes one. *)
let evictable f i = i.state = Live && i.pins = 0 && not (has_mail f i.key)

(* [i] taken now, pinned once more: its use stamp is the family's count
   of takes, the one write a take makes for eviction (K1b). A pin that
   isn't use ([visit]) leaves the stamp as it was. *)
let take ?(use = true) f i =
  i.pins <- i.pins + 1;
  if use then (
    f.takes <- f.takes + 1;
    i.used <- f.takes)

(* Nothing pins [i] any more: a task waiting for room may evict it. Used,
   it's been idle since now ([evictable_keys]). *)
let released ~use f i =
  if use then i.released_at <- Sched.now ();
  f.room <- Sched.wake_first f.room

(* The next life of [k]. *)
let next_life f k =
  let life =
    match List.find_opt (fun (k', _) -> f.equal k' k) f.lives with
    | Some (_, n) -> n + 1
    | None -> 1
  in
  f.lives <- (k, life) :: List.filter (fun (k', _) -> not (f.equal k' k)) f.lives;
  life

(* Evict [i] now, running its `finally` on this task, shielded, as a
   `with`'s is, under the cleanup deadline if the task is cancelled
   meanwhile: the task that evicts pays for it (decision 18). *)
let evict_now f i =
  i.state <- Evicting;
  i.evictor <- me ();
  on_evicted (name_of f i);
  Fun.protect
    ~finally:(fun () ->
      f.insts <- List.filter (fun j -> j != i) f.insts;
      Option.iter (fun (ins : Value.installed) -> Hashtbl.remove owners ins.inst) i.installed;
      f.evicted <- f.evicted + 1;
      (* those waiting to make its key's next instance *)
      List.iter (fun w -> ignore (w ())) i.waiting;
      i.waiting <- [];
      f.room <- Sched.wake_first f.room)
    (fun () ->
      Option.iter (fun fin -> Sched.shielded (fun () -> f.runner.finish ~cancelled:false fin)) i.finally)

(* Rule 3 (concurrency.md): a block that pins one of a family's
   instances holds the family, and while it's held, its task can't reach
   that family or one installed inside it, by `at` or by `post`, so every
   wait it makes points outward and can't close a cycle (decision 10's
   inner-to-outer rule, applied to blocks; MODEL.md: the looser "not the
   family itself" deadlocks three ways). Infer refuses it where it sees
   the `with`s; this is the run time's check, where a helper hid it: a
   panic, said at the program's call that reached it, for a pin of [f]'s
   ([`Pin]) or a post to it ([`Post]). A family opened after [g] while
   [g] is open was opened inside its `with`, or in a task that can't
   reach [g] (decision 7). The one pin it allows is `at` of a key an
   `at_all` block holds, which [pin] takes before asking. *)
let held f how =
  match List.find_opt (fun g -> f.num >= g.num) (pinned ()) with
  | Some g when g == f ->
      panic
        (match (how, holds f) with
        | `Pin, Some _ ->
            Printf.sprintf
              "`%s` pins an instance its `at_all` block doesn't hold, which could wait for a slot the block holds"
              f.dep
        | `Pin, None ->
            Printf.sprintf
              "`%s` pins one of its instances inside a block that pins another, which could wait for a slot its own block holds"
              f.dep
        | `Post, _ ->
            Printf.sprintf
              "`%s` is posted to inside a block that pins one of its instances, which could wait for what its own block holds"
              f.dep)
  | Some g ->
      panic
        (match how with
        | `Pin ->
            Printf.sprintf
              "a block that pins one of `%s`'s instances pins one of `%s`'s, installed inside it, which could wait for what the block holds"
              g.dep f.dep
        | `Post ->
            Printf.sprintf
              "a block that pins one of `%s`'s instances posts to `%s`, installed inside it, which could wait for what the block holds"
              g.dep f.dep)
  | None -> ()

(* What [pin ~room:false] raises where it would wait for room: whether
   there were evictable instances that the library's [victim] declined. *)
exception No_room of bool

(* [k]'s instance, pinned: made first if it isn't live, its setup run on
   this task while any other task asking for it waits, and fails as
   setup did for each of them; a setup that's cancelled leaves the key
   unmade, and the first of those waiting tries again. A full family asks
   [victim] which of its evictable instances to evict, given each, in the
   order they were made, with its use stamp, and the evicting task runs
   its `finally`; when [victim] gives none, or none is evictable, it
   waits for room, or, with [room] false, raises [No_room]. That wait
   can't close a cycle: what holds a slot is a block that reaches only
   families installed outside this one ([held]), an operation, which
   does too, or mail, which a delivery drains. [block] says it's pinned
   for a block, not for one operation, which rule 3 checks ([held]):
   `at` of a key an `at_all` block of this task's holds is pinned at
   once, since it's live and pinned already, and doesn't wait. Each
   [pin] is matched by an [unpin]. *)
let pin ?at ?(victim = fun _ -> None) ?(block = false) ?(room = true) f k =
  ended f;
  let rec go () =
    match find f k with
    | Some ({ state = Live; _ } as i) ->
        take f i;
        i
    | Some ({ state = Making; _ } as i) -> (
        Sched.wait ?at
          (Printf.sprintf "waits for `%s` to be made" (name_of f i))
          (fun wake -> i.waiting <- i.waiting @ [ wake ]);
        match i.failed with Some e -> raise e | None -> go ())
    | Some { state = Evicting; _ } -> failwith "bug: the family: [find] found an evicted instance"
    | None when dying f k <> None ->
        (* its last life's `finally` is running: the next is made once
           it's over, since a key has one instance at a time (decision
           18), and a setup that reads what that `finally` writes would
           read it stale. The task running that `finally` would wait for
           itself, which no program can ask for: an instance's `finally`
           reaches only families installed outside its own *)
        let i = Option.get (dying f k) in
        (match (i.evictor, me ()) with
        | Some e, Some t when e == t ->
            panic
              (Printf.sprintf
                 "`%s`'s `finally` asks for the instance it ends, which is made again only once it's over"
                 (name_of f i))
        | _ -> ());
        Sched.wait ?at
          (Printf.sprintf "waits for `%s`'s `finally` to end" (name_of f i))
          (fun wake -> i.waiting <- i.waiting @ [ wake ]);
        go ()
    | None ->
        if List.length f.insts < f.cap then fresh ()
        else
          let stamped =
            List.filter_map (fun i -> if evictable f i then Some (i.key, i.used) else None) f.insts
          in
          match if stamped = [] then None else victim stamped with
          | None ->
              if not room then raise (No_room (stamped <> []));
              Sched.wait ?at
                (Printf.sprintf "waits for room in `%s`" f.name)
                (fun wake -> f.room <- f.room @ [ wake ]);
              go ()
          | Some v ->
              if not (List.exists (fun (k', _) -> f.equal k' v) stamped) then
                panic "`victim` picked a key that isn't evictable";
              (* the victim was asked by a block, which may have let
                 another task run: it's evicted only if it still can be *)
              (match find f v with
              | Some j when evictable f j -> evict_now f j
              | _ -> ());
              go ()
  (* [k]'s instance made now, on this task, pinned *)
  and fresh () =
    f.takes <- f.takes + 1;
    let i =
      {
        key = k;
        life = next_life f k;
        installed = None;
        finally = None;
        pins = 1;
        used = f.takes;
        released_at = 0.;
        state = Making;
        waiting = [];
        failed = None;
        evictor = None;
      }
    in
    f.insts <- f.insts @ [ i ];
    let wake_all () =
      List.iter (fun w -> ignore (w ())) i.waiting;
      i.waiting <- []
    in
    (match f.runner.make k with
    | installed, finally ->
        i.installed <- Some installed;
        i.finally <- finally;
        i.state <- Live;
        Hashtbl.replace owners installed.inst (f, i);
        f.made <- f.made + 1;
        on_made (name_of f i);
        wake_all ()
    | exception e ->
        (* its setup failed, or was cancelled: the key is left
           unmade; those waiting fail with the same error, or, if
           it was cancelled, the first of them tries again *)
        f.insts <- List.filter (fun j -> j != i) f.insts;
        (match e with Sched.Cancelled -> () | e -> i.failed <- Some e);
        wake_all ();
        f.room <- Sched.wake_first f.room;
        raise e);
    i
  in
  let i =
    match if block then holds f else None with
    | Some insts when List.exists (fun i -> f.equal i.key k) insts ->
        let i = List.find (fun i -> f.equal i.key k) insts in
        take f i;
        i
    | _ ->
        if block then held f `Pin;
        go ()
  in
  if block then add_pin f;
  i

(* The pin [i] is over: one of [pin]'s, [block] as it was given; or a
   [visit]'s, which isn't [use]. *)
let unpin ?(block = false) ?(use = true) f i =
  if block then drop_pin f;
  i.pins <- i.pins - 1;
  if i.pins = 0 && i.state = Live then released ~use f i

(* Several keys at once (concurrency.md, "Several keys at once"):
   `at_all`'s instances of [ks], each made first if it isn't live, as
   [pin] makes it, pinned for its block, in the keys' order, so two
   `at_all`s over the same keys can't wait on each other; each key once.
   The block holds the family ([held]), and inside it, `at` of a key it
   holds is pinned at once ([pin]). It never waits for room in the family
   while it holds part of it, since what it would wait for could be
   another `at_all` holding the rest: where a key needs room no instance
   can give, it lets go of what it pinned and waits, holding nothing,
   until the family has room for every key it asks for, and tries again
   (what it let go of may have been evicted by then, and is made again).
   Matched by a [let_go]. *)
let hold ?at ?victim f ks =
  ended f;
  held f `Pin;
  let ks = List.sort_uniq f.compare ks in
  let n = List.length ks in
  if n > f.cap then
    panic
      (Printf.sprintf "`%s.at_all` asks for %d keys of a family that keeps at most %d" f.dep n
         f.cap);
  let wait_for_room () =
    Sched.wait ?at
      (Printf.sprintf "waits for room in `%s`" f.name)
      (fun wake -> f.room <- f.room @ [ wake ])
  in
  (* whether the family has room for every key of [ks]: the instances of
     other keys that can't be evicted leave at least [n] slots *)
  let fits () =
    let busy =
      List.filter
        (fun i -> (not (evictable f i)) && not (List.exists (f.equal i.key) ks))
        f.insts
    in
    List.length busy + n <= f.cap
  in
  let rec attempt () =
    while not (fits ()) do
      wait_for_room ()
    done;
    let got = ref [] in
    match List.iter (fun k -> got := pin ?at ?victim ~room:false f k :: !got) ks with
    | () -> List.rev !got
    | exception No_room declined ->
        List.iter (fun i -> unpin ~use:false f i) !got;
        (* a [victim] that declined is waited on as [pin] waits on it;
           otherwise another task took a slot while this one evicted,
           and [fits] says when to try again *)
        if declined then wait_for_room ();
        attempt ()
    | exception e ->
        List.iter (fun i -> unpin ~use:false f i) !got;
        raise e
  in
  let insts = attempt () in
  add_pin f;
  add_hold f insts;
  insts

(* The end of an `at_all` block: what [hold] pinned is let go of. *)
let let_go f insts =
  drop_hold f;
  drop_pin f;
  List.iter (fun i -> unpin f i) insts

(* [k]'s instance pinned for a block if it's live, without making it or
   counting as use: [None] if it isn't. Matched by an [unpin ~use:false
   ~block:true]. *)
let visit f k =
  ended f;
  held f `Pin;
  match find f k with
  | Some ({ state = Live; _ } as i) ->
      take ~use:false f i;
      add_pin f;
      Some i
  | _ -> None

(* Evict [k]'s instance if it's live and evictable: whether it did. *)
let evict f k =
  ended f;
  match find f k with
  | Some i when evictable f i ->
      evict_now f i;
      true
  | _ -> false

(* ---- posts (concurrency.md, rules 2 and 4) ---- *)

(* Whether [t] posted a call in [b] that hasn't been delivered yet. *)
let posted_by t (b : box) =
  let is = function Some u -> u == t | None -> false in
  is b.current || Queue.fold (fun seen (p, _) -> seen || is p) false b.calls

(* A task calling an operation of [i] waits first until what it posted to
   [i]'s key has been delivered: a task's posts and its calls of one
   actor come in the order it made them, as a cast and a call of one
   Erlang process do, through its one mailbox. *)
let ordered ?at f i =
  match me () with
  | None -> ()
  | Some t ->
      let rec go () =
        match box_of f i.key with
        | Some b when posted_by t b ->
            Sched.wait ?at
              (Printf.sprintf "waits for its posts to `%s` to be delivered" (name_of f i))
              (fun wake -> b.after <- b.after @ [ wake ]);
            go ()
        | _ -> ()
      in
      go ()

(* An operation of the instance numbered [inst] is about to take it: if
   it's an instance of a family's, called through a block that pins it
   rather than by one of the family's deliveries, it waits for what its
   task posted to the instance ([ordered]); then the library's [at_edge]
   runs, which may evict others, not this one, which its block pins. *)
let entering ?at inst =
  match Hashtbl.find_opt owners inst with
  | Some (f, i) when not (match me () with Some t -> List.memq t f.deliveries | None -> false) ->
      ordered ?at f i;
      Option.iter (fun each -> each ()) f.at_edge
  | _ -> ()

(* [k]'s instance, which a call is queued for and so is live, taken for
   one delivery. *)
let delivered_to f k =
  match find f k with
  | Some ({ state = Live; _ } as i) ->
      take f i;
      i
  | _ -> failwith "bug: the family: a delivery to an instance that isn't live"

(* What's queued for [k], delivered on a task of the family's, each as one
   operation of its instance, the first posted first, until none is
   left. Each is taken off the queue as it starts, which makes room for
   the first poster waiting for it; the instance is pinned while it runs,
   and once its queue is empty and nothing pins it, it's evictable again.
   When it ends, those still waiting for room look again, and start
   another. *)
let deliver f k (b : box) () =
  let rec next () =
    if not (Queue.is_empty b.calls) then (
      let i = delivered_to f k in
      let poster, c = Queue.pop b.calls in
      b.current <- poster;
      b.room <- Sched.wake_first b.room;
      Fun.protect
        ~finally:(fun () ->
          b.current <- None;
          unpin f i;
          List.iter (fun w -> ignore (w ())) b.after;
          b.after <- [])
        (fun () ->
          match i.installed with
          | Some ins -> f.runner.deliver (name_of f i) ins c
          | None -> failwith "bug: the family: a delivery to an instance that isn't made");
      next ())
  in
  let t = me () in
  Fun.protect
    ~finally:(fun () ->
      b.delivering <- false;
      f.boxes <- List.filter (fun (_, b') -> b' != b) f.boxes;
      List.iter (fun w -> ignore (w ())) b.room;
      b.room <- [];
      match t with
      | Some t -> f.deliveries <- List.filter (fun u -> u != t) f.deliveries
      | None -> ())
    next

(* [k]'s mailbox, made now if it has none. *)
let box_for f k =
  match box_of f k with
  | Some b -> b
  | None ->
      let b = { calls = Queue.create (); delivering = false; current = None; after = []; room = [] } in
      f.boxes <- f.boxes @ [ (k, b) ];
      b

(* Put [c] in [k]'s mailbox, [b], which a task of the family's delivers,
   started now if none is: named by the instance it delivers to, by the
   one rule. *)
let enqueue f k (b : box) (i : inst) c =
  Queue.push (me (), c) b.calls;
  if not b.delivering then (
    b.delivering <- true;
    let t = Sched.start_owned f.tasks ~path:(name_of f i) ~context:f.context (fun () ->
        deliver f k b ();
        Value.VUnit)
    in
    f.deliveries <- t :: f.deliveries)

(* `post`: [c] put in [k]'s mailbox, a call of [k]'s instance that gives
   `()` and can't fail, to be run later, after those this task posted to
   [k] before it. The instance is made now if it isn't live, as [pin]
   makes it, so what making it fails with is the post's, and nothing is
   queued then; then the post waits for room in [k]'s mailbox, and only
   there, holding the instance so it isn't evicted meanwhile. That wait
   can't close a cycle: room is made by [k]'s delivery, whose operations
   reach only families installed outside [f], and a block that holds [f]
   can't post to it ([held]). *)
let post ?at ?victim f k c =
  ended f;
  held f `Post;
  let i = pin ?at ?victim f k in
  Fun.protect
    ~finally:(fun () -> unpin f i)
    (fun () ->
      let rec room () =
        let b = box_for f k in
        if Queue.length b.calls >= f.mailbox then (
          Sched.wait ?at
            (Printf.sprintf "waits for room in `%s`'s mailbox" (name_of f i))
            (fun wake -> b.room <- b.room @ [ wake ]);
          room ())
        else b
      in
      let b = room () in
      on_posted (Printf.sprintf "%s[%s]" f.name (f.runner.show k)) (f.runner.show_call c);
      enqueue f k b i c)

(* Every instance, in the order they were made. *)
let all f = f.insts

(* The live keys, in the order they were made. *)
let keys f =
  ended f;
  List.filter_map (fun i -> if i.state = Live then Some i.key else None) (all f)

(* The evictable keys, in the order they were made; with [idle], in
   seconds, only those last used at least that long ago, by the
   scheduler's clock. *)
let evictable_keys ?(idle = 0.) f =
  ended f;
  let now = Sched.now () in
  List.filter (fun i -> evictable f i && now -. i.released_at >= idle) f.insts
  |> List.map (fun i -> i.key)

(* Live, made and evicted. *)
let counts f =
  ended f;
  (List.length (keys f), f.made, f.evicted)

(* The family's end (concurrency.md, rule 4). If its `with`'s body
   returned, what's queued is delivered first, by its tasks, which may
   post outward (decision 7: a scope waits for its tasks), then its
   instances' `finally`s run, the last made's first. The drain isn't
   shielded by the `finally` it runs in: it sees a cancel as the `with`'s
   body would, so a drain with a limit is the whole `with` inside
   `Async.timeout`. If the `with` is cancelled, or is while it drains,
   cancellation goes down: the operations running are cancelled at their
   next dependency call, the mail that hasn't started is dropped, and
   the `finally`s are given `Err(Cancelled)`; then the cancel goes on
   out. An operation of an instance's still running after that would be
   a task that outlived the `with` that installed the family, which
   decision 7 rules out. *)
let close f =
  ended f;
  let drained () =
    Sched.check ();
    while f.tasks.running <> [] do
      Sched.wait_empty ~what:(Printf.sprintf "waits for `%s`'s mail to be delivered" f.dep) f.tasks
    done
  in
  let cancelled =
    match Sched.shielded_at f.shield drained with
    | () -> false
    | exception Sched.Cancelled ->
        (* nothing more is delivered: what's queued is dropped, and what's
           running is cancelled, and waited for *)
        List.iter
          (fun (_, b) ->
            Queue.clear b.calls;
            List.iter (fun w -> ignore (w ())) (b.after @ b.room);
            b.after <- [];
            b.room <- [])
          f.boxes;
        Sched.cancel_all f.tasks;
        true
  in
  Sched.closed f.tasks;
  let insts = List.rev (all f) in
  f.closed <- true;
  List.iter
    (fun i ->
      if i.pins > 0 then
        panic
          (Printf.sprintf "`%s` is still running an operation as its family ends"
             (name_of f i));
      if i.state = Live then (
        i.state <- Evicting;
        Option.iter (fun (ins : Value.installed) -> Hashtbl.remove owners ins.inst) i.installed;
        Option.iter
          (fun fin -> Sched.shielded (fun () -> f.runner.finish ~cancelled fin))
          i.finally))
    insts;
  if cancelled then raise Sched.Cancelled
