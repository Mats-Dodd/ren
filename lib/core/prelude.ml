(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet, and is
   listed in the tables below: each entry says everything every pass needs
   to know about it, so adding a built-in means adding one entry. *)

(* The file its source is said to be in, which no message can show. *)
let file = "<prelude>"

let source =
  {|
pub type Option<T> =
  | Some(value: T)
  | None

  pub fn is_some(self) -> Bool =
    match self
      Some(_) => true
      None => false
  pub fn unwrap_or(self, d: T) -> T =
    match self
      Some(x) => x
      None => d

pub type Result<T, E> =
  | Ok(value: T)
  | Err(error: E)

// ---- time ----
//
// Opaque, with methods only, until operators arrive (stage 10). Inside the
// prelude each is a number of milliseconds.

// how long something takes
pub type Duration = opaque Int
  pub fn ms(n: Int) -> Duration = n
  pub fn seconds(n: Int) -> Duration = n * 1000
  pub fn minutes(n: Int) -> Duration = n * 60000
  pub fn plus(self, d: Duration) -> Duration = self + d

// a moment on the calendar: since the epoch, 1970-01-01 00:00 UTC
pub type Time = opaque Int
  pub let epoch: Time = 0
  pub fn plus(self, d: Duration) -> Time = self + d
  pub fn before(self, t: Time) -> Bool = self < t
  pub fn after(self, t: Time) -> Bool = self > t

// a moment for measuring how long something took, on a clock that never
// goes back: an instant means nothing on its own, only next to another
pub type Instant = opaque Int
  pub let zero: Instant = 0
  pub fn plus(self, d: Duration) -> Instant = self + d
  pub fn since(self, earlier: Instant) -> Duration = self - earlier
  pub fn before(self, i: Instant) -> Bool = self < i
  pub fn not_before(self, i: Instant) -> Bool = self >= i

// ---- the built-in dependencies (deps.md, "Built in") ----
//
// The runtime installs each one's `real` around `main`, if `main` uses
// it. It's private: nothing else can install the world.

pub dep Clock =
  now: fn() -> Time
  instant: fn() -> Instant
  sleep: fn(d: Duration)

  // a clock stopped at `at`, that never sleeps
  pub fn frozen(at: Time) -> Clock =
    Clock { now: fn() => at, instant: fn() => Instant.zero, sleep: fn(_) => () }
  let real: Clock =
    Clock {
      now: fn() => clock_now(),
      instant: fn() => clock_instant(),
      sleep: fn(d) => clock_sleep(d),
    }

pub dep Random =
  // a number from 0 up to, but not including, `below`
  int: fn(below: Int) -> Int

  let real: Random = Random { int: fn(below) => random_int(below) }

pub dep Console =
  write: fn(line: Str)

  let real: Console = Console { write: fn(line) => console_write(line) }

// what any value shows as, on a line of its own
pub fn print<T>(x: T) uses Console = Console.write(show(x))

// ---- what a test gets (deps.md, "Tests") ----
//
// Each test runs with a fresh instance of each of these handlers, unless
// its `uses` asks for the real dependency instead.

pub dep TestClock =
  // move the test clock on, by `d`
  advance: fn(d: Duration)

// a clock that stands still at `at` until it's moved on: by
// `TestClock.advance`, or by sleeping, which takes no time at all
pub handler test_clock(at: Time) for Clock, TestClock =
  var time = at
  var since = Instant.zero
  now() => time
  instant() => since
  sleep(d) =>
    time = time.plus(d)
    since = since.plus(d)
  advance(d) =>
    time = time.plus(d)
    since = since.plus(d)

pub dep TestRandom =
  // the seed the test's numbers come from, which `ren test --seed`
  // sets
  seed: fn() -> Int

// numbers that are the same on every run with the same seed
pub handler test_random(seed: Int) for Random, TestRandom =
  var state = seed
  int(below) =>
    state = seeded_next(state)
    seeded_int(state, below)
  seed() => seed

pub dep TestConsole =
  // every line written to `Console` so far, the first first
  output: fn() -> Array<Str>

// a console that keeps what's written to it
pub handler test_console() for Console, TestConsole =
  var lines: Array<Str> = []
  write(line) => &lines.push(line)
  output() => lines
|}

(* ---- built-in functions ---- *)

type builtin_fn = {
  name : string;
  scheme : Ty.scheme;
      (** its type scheme. Each parameter's mode ([inout] or not) is part of the
          type. *)
  eval : Value.t list -> Value.t * Value.t list;
      (** run it: the result, and the final value of every parameter, which the
          interpreter writes back for the arguments passed with `&` *)
  runtime : bool;
      (** whether only the prelude's own source can call it: it reaches the
          world, which a program does only through a dependency, in the real
          implementation the runtime installs, or it's how one of the test
          implementations works *)
}

(* A built-in function has panicked, which the interpreter reports at the
   call. *)
exception Panic of string

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug name = failwith ("bug: `" ^ name ^ "` was called with the wrong values")

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
let scheme ty : Ty.scheme = { ty; names = [] }
let open_row n : Ty.row = { labels = []; tail = Some n }

(* What the real implementations of the built-in dependencies run on: the
   system's clock, its source of randomness, and stdout. Each is a number
   of milliseconds, as [source] represents time. [Unix.gettimeofday] is
   the wall clock, which can be set back, so `instant` isn't yet the clock
   that never goes back that `Instant` promises: OCaml's standard library
   has no monotonic one (deps.md, "Built in"). *)
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

(* `Random.int`'s panic, real or not, for a [below] it can't stay below *)
let not_above_0 below =
  Printf.sprintf "`Random.int` needs a number above 0 to stay below, not %d"
    below

let fns =
  let open Ty in
  let fn ?(runtime = false) name ty eval =
    { name; scheme = scheme ty; eval; runtime }
  in
  [
    (* fn<T>(T) -> Str *)
    fn "show"
      (Fun ([ read (Var 0) ], str, open_row 0, open_row 1))
      (function
        | [ v ] as args -> (Value.VStr (Value.display v), args)
        | _ -> bug "show");
    (* fn() -> Int, the real `Clock.now` and `Clock.instant` *)
    fn ~runtime:true "clock_now"
      (Fun ([], int, open_row 0, open_row 1))
      (fun args -> (Value.VInt (now_ms ()), args));
    fn ~runtime:true "clock_instant"
      (Fun ([], int, open_row 0, open_row 1))
      (fun args -> (Value.VInt (now_ms ()), args));
    (* fn(Int) *)
    fn ~runtime:true "clock_sleep"
      (Fun ([ read int ], unit, open_row 0, open_row 1))
      (function
        | [ Value.VInt ms ] as args ->
            if ms > 0 then Unix.sleepf (float_of_int ms /. 1000.);
            (Value.VUnit, args)
        | _ -> bug "clock_sleep");
    (* fn(Int) -> Int *)
    fn ~runtime:true "random_int"
      (Fun ([ read int ], int, open_row 0, open_row 1))
      (function
        | [ Value.VInt below ] as args ->
            if below <= 0 then raise (Panic (not_above_0 below));
            let state = Random.State.make_self_init () in
            (Value.VInt (Random.State.full_int state below), args)
        | _ -> bug "random_int");
    (* fn(Int) -> Int: the state after [state] of the test `Random`, a
       linear congruential generator's, which never goes negative *)
    fn ~runtime:true "seeded_next"
      (Fun ([ read int ], int, open_row 0, open_row 1))
      (function
        | [ Value.VInt state ] as args ->
            ( Value.VInt (((abs state * 1103515245) + 12345) land 0x7fffffff),
              args )
        | _ -> bug "seeded_next");
    (* fn(Int, Int) -> Int: a number from 0 below [below], from that
       state's high bits, which vary more than its low ones *)
    fn ~runtime:true "seeded_int"
      (Fun ([ read int; read int ], int, open_row 0, open_row 1))
      (function
        | [ Value.VInt state; Value.VInt below ] as args ->
            if below <= 0 then raise (Panic (not_above_0 below));
            (Value.VInt ((state lsr 16) mod below), args)
        | _ -> bug "seeded_int");
    (* fn(Str) *)
    fn ~runtime:true "console_write"
      (Fun ([ read str ], unit, open_row 0, open_row 1))
      (function
        | [ Value.VStr line ] as args ->
            print_endline line;
            (Value.VUnit, args)
        | _ -> bug "console_write");
  ]

(* ---- built-in types ----

   A built-in type's methods are built in too, and listed with it: each is
   called with a dot, its receiver its first parameter, `self`. In a
   method's scheme the type's parameters are its first variables, as in
   any member's (iface.ml). *)

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : builtin_fn list;
}

let array_methods =
  let open Ty in
  [
    {
      (* fn<T>(self: Array<T>) -> Int *)
      name = "len";
      scheme =
        scheme (Fun ([ read (array (Var 0)) ], int, open_row 0, open_row 1));
      eval =
        (function
        | [ Value.VArray xs ] as args -> (Value.VInt (Array.length xs), args)
        | _ -> bug "len");
      runtime = false;
    };
    {
      (* fn<T>(inout self: Array<T>, x: T) *)
      name = "push";
      scheme =
        scheme
          (Fun
             ( [ { mode = Inout; ty = array (Var 0) }; read (Var 0) ],
               unit,
               open_row 0,
               open_row 1 ));
      eval =
        (function
        | [ Value.VArray xs; x ] ->
            (Value.VUnit, [ Value.VArray (Array.append xs [| x |]); x ])
        | _ -> bug "push");
      runtime = false;
    };
  ]

let types =
  [
    { name = "Int"; arity = 0; methods = [] };
    { name = "Bool"; arity = 0; methods = [] };
    { name = "Unit"; arity = 0; methods = [] };
    { name = "Str"; arity = 0; methods = [] };
    { name = "Array"; arity = 1; methods = array_methods };
  ]

(* ---- built-in dependencies ----

   The dependencies the runtime installs around `main`, if it uses them:
   each is declared in [source], with its real implementation, `real`
   (deps.md, "`main`"). *)
let runtime_deps = [ "Clock"; "Random"; "Console" ]

(* The dependencies a `uses` can name that aren't declared anywhere yet:
   their stages give them operations. *)
let dependencies = [ "Net"; "Alloc"; "Async"; "Unsafe" ]

(* A built-in function, by the name its path has: [print], or a method
   after its type, [Array.push]. *)
let find_fn name =
  match String.index_opt name '.' with
  | None -> List.find_opt (fun (f : builtin_fn) -> f.name = name) fns
  | Some i ->
      let ty = String.sub name 0 i in
      let m = String.sub name (i + 1) (String.length name - i - 1) in
      Option.bind
        (List.find_opt (fun (t : builtin_type) -> t.name = ty) types)
        (fun t -> List.find_opt (fun (f : builtin_fn) -> f.name = m) t.methods)

(* The intrinsic half of the prelude's interface, as the prelude's own
   source sees it, with what reaches the world; [public] is what every
   other module sees, without it. *)
let intrinsics : Iface.t =
  {
    home = Path.prelude_home;
    types =
      List.map
        (fun (t : builtin_type) : Iface.type_decl ->
          {
            path = Path.prelude t.name;
            params = List.init t.arity (fun i -> "T" ^ string_of_int i);
            body = Builtin;
            members =
              List.map
                (fun (f : builtin_fn) : Iface.op ->
                  {
                    oname = f.name;
                    opub = true;
                    okind = Method;
                    oscheme = f.scheme;
                  })
                t.methods;
            loc = None;
          })
        types;
    values =
      List.map
        (fun (f : builtin_fn) -> { Iface.vname = f.name; scheme = f.scheme })
        fns;
  }

let public =
  {
    intrinsics with
    values =
      List.filter
        (fun (v : Iface.value) ->
          match
            List.find_opt (fun (f : builtin_fn) -> f.name = v.vname) fns
          with
          | Some f -> not f.runtime
          | None -> true)
        intrinsics.values;
  }
