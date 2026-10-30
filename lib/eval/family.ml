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
   list the live keys, and keep the order instances became evictable in,
   the least recently released first, which a library's policy reads. It
   decides nothing a library decides: which instance to evict, when, how
   many to keep, how to route. The interpreter's half, making an instance
   and running an operation of it or its `finally`, is eval.ml's, which
   gives a family what it needs of it when it opens one ([opened]).

   Partitions: a key belongs to the partition its hash says, by
   [Walk.fixed_hash], the same in every run; each has its own instances
   and its own cap, and a library fixes how many there are, never the
   runtime, so which instance a full one evicts is the same on one core or
   many (decision 18).

   **Names, by one rule** (decision 11, as a task's path is named): a
   family is named where it's installed, by the dependency its opening
   handler is installed as, snake_cased, `docs` for `Docs`, and a second
   family one handler opens is `docs.2`; an instance is its family's
   name, its key written as a value is, and its life, which counts the
   key's lives from 1: `docs[DocId(7)]#3` ([name_of]). The deadlock panic
   names an instance a parked task holds so.

   Not built yet, step 7b's (compiler.md, "Services stage", progress
   log): `post` and the queue of calls per key with its delivery tasks,
   the meter at the family's edge, and teardown draining the queues. *)

(* Where an instance is in its life. *)
type state = Making | Live | Evicting

(* An instance: its key, its life ([name_of]), when it was made among
   the family's, [born]; its implementation of the family's dependency
   and its `finally`, once it's made; how many operations of it are
   running, [pins]; when it last stopped being pinned, for the order of
   release; and what waits for it to be made. *)
type inst = {
  key : Value.t;
  life : int;
  born : int;
  mutable installed : Value.installed option;
  mutable finally : Value.t option;
  mutable pins : int;
  mutable released_at : float;
  mutable state : state;
  mutable waiting : (unit -> bool) list;
  mutable failed : exn option;
      (** what its setup failed with, which those that waited for it to be
          made fail with too *)
}

(* A partition: its instances, the first made first, at most [cap] of
   them; those evictable, the least recently released first, [lru]; and
   the tasks waiting for room, [room]. *)
type part = {
  mutable insts : inst list;
  mutable lru : inst list;
  cap : int;
  mutable room : (unit -> bool) list;
}

(* What eval.ml does for a family: make an instance for a key, its
   implementation and its `finally`; run a `finally`; and show a key, as
   a value of the keys' type is shown. *)
type runner = {
  make : Value.t -> Value.installed * Value.t option;
  finish : Value.t -> unit;
  show : Value.t -> string;
}

type family = {
  name : string;
  dep : string;  (** the dependency its opener is installed as, `Docs` *)
  num : int;
      (** its place among the families opened, which a family opened
          inside another's `with` comes after: what "installed outside"
          means to the no-deadlock rule ([pin]) *)
  mailbox : int;  (** the edge's bound, which step 7's meter reads *)
  hash : Value.t -> int64;  (** a key's, the same in every run *)
  equal : Value.t -> Value.t -> bool;
  parts : part array;
  runner : runner;
  mutable order : int;  (** instances made, which numbers each's [born] *)
  mutable made : int;
  mutable evicted : int;
  mutable high : int;  (** the most calls queued at once *)
  mutable lives : (Value.t * int) list;
      (** each key made, with its last life's number, kept across eviction *)
  mutable closed : bool;
}

(* A family as a program holds it, `Family<K, D>`: a handle, not an
   instance, so keeping one in a handler's state keeps none (value.ml,
   [sched]). *)
type Value.sched += Family of family

(* A panic of the family's, which the interpreter says at the program's
   call that reached it, as a built-in's. *)
let panic msg = raise (Builtins.Panic msg)

(* A pin that would wait for room in a family installed inside one whose
   instance its task pins already, where the call that asked for it was
   marked as one that can fail with `Full` ([may_be_full]): eval.ml makes
   it that error (decision 18, "No deadlock"). *)
exception Full

(* What's journaled of a family (journal.ml, version 3), on the task
   that did it: a family opened, with its partitions, and an instance
   made and one evicted, each named by the one rule. *)
let on_made name = Sched.family_event ("made " ^ name)
let on_evicted name = Sched.family_event ("evicted " ^ name)
let on_opened name parts = Sched.family_event (Printf.sprintf "opened %s parts %d" name parts)

(* The families whose instances each task pins for a block, the last
   pinned first, by the task: what the no-deadlock rules read ([pin]).
   A task is compared by itself, not by its path. *)
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

(* The tasks whose next pin may fail with `Full` rather than panic, since
   Infer saw the call that reaches it is inside another family's pinned
   block and added `Full` to its errors there ([Full]); the next pin
   takes the mark ([pin]), and the call clears it when it's over. *)
let marked : Sched.task list ref = ref []

let may_be_full on =
  match me () with
  | None -> ()
  | Some t ->
      marked := List.filter (fun t' -> t' != t) !marked;
      if on then marked := t :: !marked

let take_mark () =
  match me () with
  | Some t when List.memq t !marked ->
      marked := List.filter (fun t' -> t' != t) !marked;
      true
  | _ -> false

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
   `with` that's installing one, in [parts] partitions of [cap] instances
   each. *)
let opened_count = ref 0

let opened ~parts ~cap ~mailbox ~hash ~equal runner =
  if parts < 1 then panic (Printf.sprintf "a family has at least 1 partition, not %d" parts);
  if cap < 1 then panic (Printf.sprintf "a family's partition keeps at least 1 instance, not %d" cap);
  let dep, name =
    match !opening with
    | (dep, n) :: _ ->
        incr n;
        (dep, if !n = 1 then snake dep else Printf.sprintf "%s.%d" (snake dep) !n)
    | [] -> ("Instances", "family")
  in
  incr opened_count;
  on_opened name parts;
  {
    name;
    dep;
    num = !opened_count;
    mailbox;
    hash;
    equal;
    parts = Array.init parts (fun _ -> { insts = []; lru = []; cap; room = [] });
    runner;
    order = 0;
    made = 0;
    evicted = 0;
    high = 0;
    lives = [];
    closed = false;
  }

(* An instance's name by the one rule: `docs[DocId(7)]#3`. *)
let name_of f (i : inst) =
  Printf.sprintf "%s[%s]#%d" f.name (f.runner.show i.key) i.life

let ended f =
  if f.closed then panic "this family ended with the `with` that opened it"

(* The partition [k] belongs to. *)
let part_of f k =
  let n = Int64.of_int (Array.length f.parts) in
  f.parts.(Int64.to_int (Int64.unsigned_rem (f.hash k) n))

(* [k]'s instance, if it has one that isn't being evicted. *)
let find f k =
  List.find_opt
    (fun i -> i.state <> Evicting && f.equal i.key k)
    (part_of f k).insts

(* Whether [i] can be evicted: it's live, and no operation of it runs. *)
let evictable i = i.state = Live && i.pins = 0

(* The order of release: [i], once nothing pins it, goes where the time
   it was last released puts it, the least recently released first, and
   a task waiting for room in its partition may take it. A pin that isn't
   use ([visit]) leaves that time as it was, so it goes back where it
   was. *)
let place f i =
  let p = part_of f i.key in
  let before, after =
    List.partition (fun j -> j.released_at <= i.released_at) (List.filter (fun j -> j != i) p.lru)
  in
  p.lru <- before @ (i :: after);
  p.room <- Sched.wake_first p.room

(* [i] has stopped being pinned, and was used: it's the most recently
   released. *)
let released f i =
  i.released_at <- Sched.now ();
  place f i

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
  let p = part_of f i.key in
  i.state <- Evicting;
  p.lru <- List.filter (fun j -> j != i) p.lru;
  on_evicted (name_of f i);
  Fun.protect
    ~finally:(fun () ->
      p.insts <- List.filter (fun j -> j != i) p.insts;
      f.evicted <- f.evicted + 1;
      p.room <- Sched.wake_first p.room)
    (fun () -> Option.iter (fun fin -> Sched.shielded (fun () -> f.runner.finish fin)) i.finally)

(* A family whose instance this task pins, that [f] is installed inside
   of, or [f] itself, if there's one: then waiting for room in [f] could
   close a cycle of waits, since a task that holds what's in the way
   could be waiting for what this one pins. A task may wait only for a
   family installed outside every one it pins (decision 18, "No
   deadlock"; decision 10's inner-to-outer rule). A family opened after
   [g] while [g] is open was opened inside its `with`, or in a task that
   can't reach [g] (decision 7). *)
let inside f = List.find_opt (fun g -> f.num >= g.num) (pinned ())

(* [k]'s instance, pinned: made first if it isn't live, its setup run on
   this task while any other task asking for it waits, and fails as
   setup did for each of them; a setup that's cancelled leaves the key
   unmade, and the first of those waiting tries again. A partition that's
   full asks [victim] which of its evictable instances, the least
   recently released first, to evict, and the evicting task runs its
   `finally`; when [victim] gives none, or none is evictable, it waits
   for room, unless the task pins an instance of a family installed
   inside [f]: then it fails with [Full] where the call was marked as one
   that can ([take_mark]), and panics where it wasn't, since that error
   is in no signature there. [block] says it's pinned for a block, not
   for one operation, which a task already pinning one of [f]'s for a
   block can't do (a helper hid what Infer refuses). Each [pin] is
   matched by an [unpin]. *)
let pin ?at ?(victim = fun _ -> None) ?(block = false) f k =
  ended f;
  let full_ok = take_mark () in
  if block && List.memq f (pinned ()) then
    panic
      (Printf.sprintf
         "`%s` pins one of its instances inside a block that pins another, \
          which could wait for a slot its own block holds"
         f.dep);
  let rec go () =
    match find f k with
    | Some ({ state = Live; _ } as i) ->
        i.pins <- i.pins + 1;
        let p = part_of f k in
        p.lru <- List.filter (fun j -> j != i) p.lru;
        i
    | Some ({ state = Making; _ } as i) -> (
        Sched.wait ?at
          (Printf.sprintf "waits for `%s` to be made" (name_of f i))
          (fun wake -> i.waiting <- i.waiting @ [ wake ]);
        match i.failed with Some e -> raise e | None -> go ())
    | Some { state = Evicting; _ } -> go ()
    | None ->
        let p = part_of f k in
        if List.length p.insts >= p.cap then (
          let lru = List.filter evictable p.lru in
          let wait () =
            match inside f with
            | Some g ->
                if full_ok then raise Full
                else
                  panic
                    (Printf.sprintf
                       "a task pinning `%s` would wait for a slot of `%s`, \
                        installed inside it"
                       g.dep f.dep)
            | None ->
              Sched.wait ?at
                (Printf.sprintf "waits for room in `%s`" f.name)
                (fun wake -> p.room <- p.room @ [ wake ])
          in
          (match lru with
          | [] -> wait ()
          | _ -> (
              let keys = List.map (fun i -> i.key) lru in
              match victim keys with
              | None -> wait ()
              | Some v -> (
                  if not (List.exists (fun k' -> f.equal k' v) keys) then
                    panic "`victim` picked a key that isn't evictable";
                  (* the victim was asked by a block, which may have let
                     another task run: it's evicted only if it still can be *)
                  match find f v with
                  | Some j when evictable j -> evict_now f j
                  | _ -> ())));
          go ())
        else
          let i =
            {
              key = k;
              life = next_life f k;
              born = f.order;
              installed = None;
              finally = None;
              pins = 1;
              released_at = 0.;
              state = Making;
              waiting = [];
              failed = None;
            }
          in
          f.order <- f.order + 1;
          p.insts <- p.insts @ [ i ];
          let wake_all () =
            List.iter (fun w -> ignore (w ())) i.waiting;
            i.waiting <- []
          in
          (match f.runner.make k with
          | installed, finally ->
              i.installed <- Some installed;
              i.finally <- finally;
              i.state <- Live;
              f.made <- f.made + 1;
              on_made (name_of f i);
              wake_all ()
          | exception e ->
              (* its setup failed, or was cancelled: the key is left
                 unmade; those waiting fail with the same error, or, if
                 it was cancelled, the first of them tries again *)
              p.insts <- List.filter (fun j -> j != i) p.insts;
              (match e with Sched.Cancelled -> () | e -> i.failed <- Some e);
              wake_all ();
              p.room <- Sched.wake_first p.room;
              raise e);
          i
  in
  let i = go () in
  if block then add_pin f;
  i

(* The pin [i] is over: one of [pin]'s, [block] as it was given; or a
   [visit]'s, which isn't use, so [i] goes back where it was in the order
   of release. *)
let unpin ?(block = false) ?(use = true) f i =
  if block then drop_pin f;
  i.pins <- i.pins - 1;
  if i.pins = 0 && i.state = Live then if use then released f i else place f i

(* [k]'s instance pinned for a block if it's live, without making it or
   counting as use: [None] if it isn't. Matched by an [unpin ~use:false
   ~block:true]. *)
let visit f k =
  ended f;
  if List.memq f (pinned ()) then
    panic
      (Printf.sprintf
         "`%s` pins one of its instances inside a block that pins another, \
          which could wait for a slot its own block holds"
         f.dep);
  match find f k with
  | Some ({ state = Live; _ } as i) ->
      i.pins <- i.pins + 1;
      let p = part_of f k in
      p.lru <- List.filter (fun j -> j != i) p.lru;
      add_pin f;
      Some i
  | _ -> None

(* Evict [k]'s instance if it's live and evictable: whether it did. *)
let evict f k =
  ended f;
  match find f k with
  | Some i when evictable i ->
      evict_now f i;
      true
  | _ -> false

(* Every instance, in the order they were made. *)
let all f =
  Array.to_list f.parts
  |> List.concat_map (fun p -> p.insts)
  |> List.sort (fun a b -> compare a.born b.born)

(* The live keys, in the order they were made. *)
let keys f =
  ended f;
  List.filter_map (fun i -> if i.state = Live then Some i.key else None) (all f)

(* The evictable keys, least recently released first, across
   partitions; with [idle], in seconds, only those released at least that
   long ago, by the scheduler's clock. *)
let evictable_keys ?(idle = 0.) f =
  ended f;
  let now = Sched.now () in
  Array.to_list f.parts
  |> List.concat_map (fun p -> List.filter evictable p.lru)
  |> List.filter (fun i -> now -. i.released_at >= idle)
  |> List.stable_sort (fun a b -> compare a.released_at b.released_at)
  |> List.map (fun i -> i.key)

(* Live, made, evicted, and the most calls queued at once. *)
let counts f =
  ended f;
  (List.length (keys f), f.made, f.evicted, f.high)

(* The family's end: its instances' `finally`s, the last made's first.
   An operation of one still running would be a task that outlived the
   `with` that installed the family, which decision 7 rules out. *)
let close f =
  ended f;
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
        Option.iter (fun fin -> Sched.shielded (fun () -> f.runner.finish fin)) i.finally))
    insts
