(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet. Each such
   function is named by an id (intrinsic.ml), and below are its type and
   where it's listed: everything the passes before the interpreter need
   to know about it. What it does when it runs is the interpreter's half,
   eval/builtins.ml. So adding a built-in means adding its id, an entry
   here, and its implementation there, and the compiler points out any
   [match] that's missing it. *)

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
// Inside the prelude each is a number of milliseconds. A `Duration` is a
// number of its own (operators.md, "Number types"); a `Time` and an
// `Instant` are moments, so two can be told apart, giving a `Duration`,
// and one moved on by a `Duration`, but not added together.

// how long something takes
pub type Duration = opaque Int with numeric
  pub fn ms(n: Int) -> Duration = n
  pub fn seconds(n: Int) -> Duration = n * 1000
  pub fn minutes(n: Int) -> Duration = n * 60000
  // how many milliseconds it is
  pub fn in_ms(self) -> Int = self

// a moment on the calendar: since the epoch, 1970-01-01 00:00 UTC
pub type Time = opaque Int
  pub let epoch: Time = 0
  pub fn add(self, d: Duration) -> Time = self + d.in_ms()
  pub fn sub(self, t: Time) -> Duration = Duration.ms(self - t)
  pub fn sub(self, d: Duration) -> Time = self - d.in_ms()
  // ordered by when it is
  pub fn key(self) -> Int = self

// a moment for measuring how long something took, on a clock that never
// goes back: an instant means nothing on its own, only next to another
pub type Instant = opaque Int
  pub let zero: Instant = 0
  pub fn add(self, d: Duration) -> Instant = self + d.in_ms()
  pub fn sub(self, i: Instant) -> Duration = Duration.ms(self - i)
  pub fn sub(self, d: Duration) -> Instant = self - d.in_ms()
  // ordered by when it is
  pub fn key(self) -> Int = self

// ---- paths ----

// where a file is, as the system writes it: names with `/` between them
pub type Path = opaque Str
  pub fn of(s: Str) -> Path = s
  // `name` inside this path, or `name` itself if it starts at the root
  pub fn join(self, name: Str) -> Path =
    if self == "" || name.starts_with("/") then name
    else
      // a path that ends in `/` has an empty last part
      let parts = self.split("/")
      if parts[parts.len() - 1] == "" then self.concat(name)
      else self.concat("/").concat(name)
  pub fn show(self) -> Str = self

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
  // a line apart from what the program writes: how it's going, or what
  // went wrong
  error: fn(line: Str)

  let real: Console =
    Console {
      write: fn(line) => console_write(line),
      error: fn(line) => console_error(line),
    }

// what any value shows as, on a line of its own
pub fn print<T>(x: T) uses Console = Console.write(show(x))

// a file: where it is, and what's in it
pub type File = { path: Path, data: Bytes }

// every way the real `Fs` can fail: there's nothing at the path, the
// system won't let this program at it, it's a folder, or something else
// went wrong, which the system gives its reason for
pub type FsError =
  ! NoSuchFile(path: Path) | NotAllowed(path: Path) | IsAFolder(path: Path) | FsFailed(path: Path, reason: Str)

// what the system said to a read or a write, which `fs_checked` turns
// into its value or its error
type FsOutcome<T> =
  | FsDone(value: T)
  | FsMissing
  | FsDenied
  | FsFolder
  | FsOther(reason: Str)

fn fs_checked<T>(o: FsOutcome<T>, p: Path) -> T ! FsError =
  match o
    FsDone(v) => v
    FsMissing => fail NoSuchFile(p)
    FsDenied => fail NotAllowed(p)
    FsFolder => fail IsAFolder(p)
    FsOther(reason) => fail FsFailed(p, reason)

pub dep Fs =
  read: fn(p: Path) -> Bytes ! FsError
  // makes the file, or replaces what's in it
  write: fn(p: Path, b: Bytes) ! FsError
  exists: fn(p: Path) -> Bool

  // what's in a file, as a string
  pub fn read_str(p: Path) -> Str ! FsError | InvalidUtf8 uses Fs =
    let b = try Fs.read(p)
    try Str.from_utf8(b)
  let real: Fs =
    Fs {
      read: fn(p) => try fs_checked(fs_read(p), p),
      write: fn(p, b) => try fs_checked(fs_write(p, b), p),
      exists: fn(p) => fs_exists(p),
    }

pub dep Os =
  // what `ren run file.ren -- args` was given after the `--`
  args: fn() -> Array<Str>

  let real: Os = Os { args: fn() => os_args() }

// every way the real `Proc` can fail: there's no such program, the
// system wouldn't start it, with its reason, or it was killed before it
// could exit
pub type ProcError = ! NoSuchProgram(name: Str) | CantRun(name: Str, reason: Str) | Killed(name: Str)

// what became of a program, which `proc_checked` turns into its exit code
// or its error
type ProcOutcome =
  | ProcExited(code: Int)
  | ProcMissing
  | ProcNotStarted(reason: Str)
  | ProcKilled

fn proc_checked(o: ProcOutcome, cmd: Str) -> Int ! ProcError =
  match o
    ProcExited(code) => code
    ProcMissing => fail NoSuchProgram(cmd)
    ProcNotStarted(reason) => fail CantRun(cmd, reason)
    ProcKilled => fail Killed(cmd)

pub dep Proc =
  // runs the program `cmd`, found on `PATH` unless it has a `/` in it,
  // with what this program prints to and reads from, and gives back its
  // exit code
  run: fn(cmd: Str, args: Array<Str>) -> Int ! ProcError

  let real: Proc = Proc { run: fn(cmd, args) => try proc_checked(proc_run(cmd, args), cmd) }

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
    time = time + d
    since = since + d
  advance(d) =>
    time = time + d
    since = since + d

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
  // every line given to `Console.error` so far, the first first
  errors: fn() -> Array<Str>

// a console that keeps what's written to it
pub handler test_console() for Console, TestConsole =
  var lines: Array<Str> = []
  var errors: Array<Str> = []
  write(line) => &lines.push(line)
  error(line) => &errors.push(line)
  output() => lines
  errors() => errors

// files kept in memory, starting with `files`. A test gets an empty one,
// and reads back what it wrote through `Fs` itself.
pub handler mem_fs(files: Array<File>) for Fs =
  var kept = files
  read(p) =>
    var found = None
    for f in kept
      if f.path == p then found = Some(f.data)
    found orelse fail NoSuchFile(p)
  write(p, b) =>
    var at = None
    var i = 0
    for f in kept
      if f.path == p then at = Some(i)
      i += 1
    match at
      Some(j) => kept[j].data = b
      None => &kept.push(File { path: p, data: b })
  exists(p) =>
    var found = false
    for f in kept
      if f.path == p then found = true
    found

// a system whose program was given `args`
pub handler test_os(args: Array<Str>) for Os =
  args() => args

// a program that was run: its name, and what it was given
pub type Command = { cmd: Str, args: Array<Str> }

// what a test `Proc` says `command` exits with
pub type Exit = { command: Command, code: Int }

pub dep TestProc =
  // every program run so far, the first first
  ran: fn() -> Array<Command>

// programs that don't run, but are kept: each exits with the code its
// `Exit` in `exits` gives, or 0 if none does
pub handler test_proc(exits: Array<Exit>) for Proc, TestProc =
  var commands: Array<Command> = []
  run(cmd, args) =>
    let c = Command { cmd: cmd, args: args }
    &commands.push(c)
    var code = 0
    for e in exits
      if e.command == c then code = e.code
    code
  ran() => commands
|}

(* ---- built-in functions ---- *)

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
(* canonical numbers each function type's lambda set *)
let scheme_of ty : Ty.scheme =
  Ty.canonical { ty; names = []; reqs = []; row_reqs = [] }

let open_row n : Ty.row = { labels = []; tail = Some n }
let bytes = Ty.Con (Path.prelude "Bytes", [])

(* Each built-in function's type scheme, by its id. Each parameter's mode
   ([inout] or not) is part of the type. A built-in type's method has its
   receiver, `self`, first, and the type's parameters are its scheme's
   first variables, as in any member's (iface.ml). *)
let scheme (x : Intrinsic.t) =
  let open Ty in
  (* most fail with nothing and use nothing: open rows, which any row
     fits *)
  let fn params ret =
    scheme_of (Fun (params, ret, open_row 0, open_row 1, any_lams))
  in
  match x with
  (* fn<T>(T) -> Str, which the interpreter runs itself, since it shows a
     value through its type (eval.ml) *)
  | Show -> fn [ read (Var 0) ] str
  (* fn() -> Int, the real `Clock.now` and `Clock.instant` *)
  | Clock_now | Clock_instant -> fn [] int
  (* fn(Int) *)
  | Clock_sleep -> fn [ read int ] unit
  (* fn(Int) -> Int *)
  | Random_int -> fn [ read int ] int
  (* fn(Int) -> Int: the state after [state] of the test `Random` *)
  | Seeded_next -> fn [ read int ] int
  (* fn(Int, Int) -> Int: a number from 0 below [below], from that state *)
  | Seeded_int -> fn [ read int; read int ] int
  (* fn(Str) *)
  | Console_write -> fn [ read str ] unit
  (* fn(Str), the real `Console.error`: stderr *)
  | Console_error -> fn [ read str ] unit
  (* fn(Str) -> FsOutcome<Bytes>, the real `Fs.read` *)
  | Fs_read -> fn [ read str ] (Con (Path.prelude "FsOutcome", [ bytes ]))
  (* fn(Str, Bytes) -> FsOutcome<Unit>, the real `Fs.write` *)
  | Fs_write ->
      fn [ read str; read bytes ] (Con (Path.prelude "FsOutcome", [ unit ]))
  (* fn(Str) -> Bool *)
  | Fs_exists -> fn [ read str ] bool
  (* fn() -> Array<Str> *)
  | Os_args -> fn [] (array str)
  (* fn(Str, Array<Str>) -> ProcOutcome, the real `Proc.run` *)
  | Proc_run ->
      fn [ read str; read (array str) ] (Con (Path.prelude "ProcOutcome", []))
  (* fn<T>(self: Array<T>) -> Int *)
  | Array_len -> fn [ read (array (Var 0)) ] int
  (* fn<T>(inout self: Array<T>, x: T) *)
  | Array_push -> fn [ { mode = Inout; ty = array (Var 0) }; read (Var 0) ] unit
  (* A `Str` is UTF-8, always, and `Bytes` are any bytes at all
     (builtins.ml, "strings and bytes"). *)
  (* fn(self: Str) -> Int, in bytes *)
  | Str_len -> fn [ read str ] int
  (* fn(self: Str, from: Int, to: Int) -> Str: the bytes from [from] up
     to, but not including, [to] *)
  | Str_slice -> fn [ read str; read int; read int ] str
  (* fn(self: Str, s: Str) -> Option<Int>: where [s] first starts *)
  | Str_find -> fn [ read str; read str ] (Con (Path.prelude "Option", [ int ]))
  (* fn(self: Str, sep: Str) -> Array<Str>: the parts between each [sep] *)
  | Str_split -> fn [ read str; read str ] (array str)
  (* fn(self: Str) -> Str, without the spaces, tabs and newlines at
     either end *)
  | Str_trim -> fn [ read str ] str
  (* fn(self: Str, prefix: Str) -> Bool *)
  | Str_starts_with -> fn [ read str; read str ] bool
  (* fn(self: Str, s: Str) -> Str: this, then [s] *)
  | Str_concat -> fn [ read str; read str ] str
  (* fn(self: Str) -> Bytes: its UTF-8 *)
  | Str_bytes -> fn [ read str ] bytes
  (* fn(b: Bytes) -> Str ! InvalidUtf8 *)
  | Str_from_utf8 ->
      scheme_of
        (Fun
           ( [ read bytes ],
             str,
             { labels = [ label "InvalidUtf8" ]; tail = None },
             open_row 0,
             any_lams ))
  (* fn(self: Bytes) -> Int *)
  | Bytes_len -> fn [ read bytes ] int
  (* fn(self: Int, n: Int) -> Int: the arithmetic that wraps around at
     64 bits instead of panicking (operators.md, "`Int` and `Float`") *)
  | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul ->
      fn [ read int; read int ] int
  (* fn(self: Int) -> Int *)
  | Int_wrapping_neg -> fn [ read int ] int
  (* fn(n: Int) -> Float: numbers never convert by themselves *)
  | Float_of -> fn [ read int ] float
  (* fn(self: Float) -> Int: the nearest, half away from zero; and
     toward zero *)
  | Float_round | Float_truncate -> fn [ read float ] int
  (* fn(self: Float) -> Float *)
  | Float_sqrt -> fn [ read float ] float
  (* fn(self: Str) -> Str, with `A` to `Z` made `a` to `z` *)
  | Str_lower -> fn [ read str ] str

(* Whether only the prelude's own source can call it: it reaches the
   world, which a program does only through a dependency, in the real
   implementation the runtime installs, or it's how one of the test
   implementations works. *)
let runtime (x : Intrinsic.t) =
  match x with
  | Clock_now | Clock_instant | Clock_sleep | Random_int | Seeded_next
  | Seeded_int | Console_write | Console_error | Fs_read | Fs_write | Fs_exists
  | Os_args | Proc_run ->
      true
  | Show | Array_len | Array_push | Str_len | Str_slice | Str_find | Str_split
  | Str_trim | Str_starts_with | Str_concat | Str_bytes | Str_from_utf8
  | Bytes_len | Int_wrapping_add | Int_wrapping_sub | Int_wrapping_mul
  | Int_wrapping_neg | Float_of | Float_round | Float_truncate | Float_sqrt
  | Str_lower ->
      false

(* The built-in functions that aren't a type's members, in the order the
   prelude's interface lists them. *)
let fns : Intrinsic.t list =
  [
    Show;
    Clock_now;
    Clock_instant;
    Clock_sleep;
    Random_int;
    Seeded_next;
    Seeded_int;
    Console_write;
    Console_error;
    Fs_read;
    Fs_write;
    Fs_exists;
    Os_args;
    Proc_run;
  ]

(* ---- built-in types ----

   A built-in type's methods are built in too, and listed with it: each is
   called with a dot, its receiver its first parameter, `self`. *)

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : Intrinsic.t list;
  functions : Intrinsic.t list;  (** its associated functions, without `self` *)
}

let types =
  let t ?(methods = []) ?(functions = []) ?(arity = 0) name =
    { name; arity; methods; functions }
  in
  (* `Array` before `Str`, whose `len` an old-style `len(xs)` means
     less often (resolve.ml) *)
  [
    t "Int"
      ~methods:
        [
          Int_wrapping_add; Int_wrapping_sub; Int_wrapping_mul; Int_wrapping_neg;
        ];
    t "Float"
      ~methods:[ Float_round; Float_truncate; Float_sqrt ]
      ~functions:[ Float_of ];
    t "Bool";
    t "Unit";
    t "Array" ~arity:1 ~methods:[ Array_len; Array_push ];
    t "Str"
      ~methods:
        [
          Str_len;
          Str_slice;
          Str_find;
          Str_split;
          Str_trim;
          Str_starts_with;
          Str_concat;
          Str_bytes;
          Str_lower;
        ]
      ~functions:[ Str_from_utf8 ];
    t "Bytes" ~methods:[ Bytes_len ];
  ]

(* ---- built-in dependencies ----

   The dependencies the runtime installs around `main`, if it uses them:
   each is declared in [source], with its real implementation, `real`
   (deps.md, "`main`"). *)
let runtime_deps = [ "Clock"; "Random"; "Console"; "Fs"; "Os"; "Proc" ]

(* The dependencies a `uses` can name that aren't declared anywhere yet:
   their stages give them operations. *)
let dependencies = [ "Net"; "Alloc"; "Async"; "Unsafe" ]

(* Every built-in function, by its path. The map is made once, when the
   compiler starts, and never changes. *)
let by_path =
  let all = fns @ List.concat_map (fun t -> t.methods @ t.functions) types in
  List.fold_left
    (fun m x -> Path.Map.add (Intrinsic.path x) x m)
    Path.Map.empty all

let find p = Path.Map.find_opt p by_path

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
              Path.Map.of_list
                (List.mapi
                   (fun onum (okind, x) ->
                     ( Intrinsic.path x,
                       {
                         Iface.oname = Intrinsic.member_name x;
                         onum;
                         opub = true;
                         okind;
                         oscheme = scheme x;
                       } ))
                   (List.map (fun x -> (Iface.Method, x)) t.methods
                   @ List.map (fun x -> (Iface.Function, x)) t.functions));
            numeric = None;
            loc = None;
          })
        types;
    values =
      List.map
        (fun x -> { Iface.vname = Intrinsic.name x; scheme = scheme x })
        fns;
  }

let public =
  {
    intrinsics with
    values =
      List.filter
        (fun (v : Iface.value) ->
          match find (Path.prelude v.vname) with
          | Some x -> not (runtime x)
          | None -> true)
        intrinsics.values;
  }
