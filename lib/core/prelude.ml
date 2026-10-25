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
  // this, `n` times over
  pub fn times(self, n: Int) -> Duration = self * n
  pub fn before(self, d: Duration) -> Bool = self < d
  pub fn after(self, d: Duration) -> Bool = self > d
  // how many milliseconds it is
  pub fn in_ms(self) -> Int = self

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

  let real: Console = Console { write: fn(line) => console_write(line) }

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

(* A built-in function has failed with this error, which the call fails
   with. *)
exception Fail of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug name = failwith ("bug: `" ^ name ^ "` was called with the wrong values")

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
let scheme ty : Ty.scheme = { ty; names = [] }
let open_row n : Ty.row = { labels = []; tail = Some n }
let bytes = Ty.Con (Path.prelude "Bytes", [])

(* What the real implementations of the built-in dependencies run on: the
   system's clock, its source of randomness, and stdout. Each is a number
   of milliseconds, as [source] represents time. [Unix.gettimeofday] is
   the wall clock, which can be set back, so `instant` isn't yet the clock
   that never goes back that `Instant` promises: OCaml's standard library
   has no monotonic one (deps.md, "Built in"). *)
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

(* What the system said to a read or a write, as the prelude's private
   [FsOutcome<T>], which its source turns into the value or an `FsError`. *)
let fs_outcome name args =
  Value.VCon { ty = Path.prelude "FsOutcome"; name; args }

let fs_failed (e : Unix.error) =
  match e with
  | ENOENT | ENOTDIR -> fs_outcome "FsMissing" []
  | EACCES | EPERM | EROFS -> fs_outcome "FsDenied" []
  | EISDIR -> fs_outcome "FsFolder" []
  | e -> fs_outcome "FsOther" [ VStr (Unix.error_message e) ]

(* A file's bytes, as [FsDone], or why it couldn't be read. A folder opens,
   but isn't a file to read. *)
let read_file path =
  match Unix.openfile path [ Unix.O_RDONLY ] 0 with
  | exception Unix.Unix_error (e, _, _) -> fs_failed e
  | fd -> (
      match Unix.fstat fd with
      | exception Unix.Unix_error (e, _, _) ->
          Unix.close fd;
          fs_failed e
      | { st_kind = Unix.S_DIR; _ } ->
          Unix.close fd;
          fs_failed Unix.EISDIR
      | _ -> (
          let ic = Unix.in_channel_of_descr fd in
          match In_channel.input_all ic with
          | data ->
              close_in ic;
              fs_outcome "FsDone" [ VBytes data ]
          | exception Sys_error msg ->
              close_in_noerr ic;
              fs_outcome "FsOther" [ VStr msg ]))

(* Make the file at [path], or replace what's in it, as [FsDone ()], or say
   why it couldn't be written. *)
let write_file path data =
  match
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o644
  with
  | exception Unix.Unix_error (e, _, _) -> fs_failed e
  | fd -> (
      let b = Bytes.unsafe_of_string data in
      let rec go off =
        if off < Bytes.length b then
          go (off + Unix.write fd b off (Bytes.length b - off))
      in
      match go 0 with
      | () ->
          Unix.close fd;
          fs_outcome "FsDone" [ VUnit ]
      | exception Unix.Unix_error (e, _, _) ->
          Unix.close fd;
          fs_failed e)

(* What `ren run file.ren -- args` was given after the `--`, which the
   real `Os.args` gives back. *)
let args : string list ref = ref []

(* Where the program [cmd] is: [cmd] itself if it has a `/` in it and
   something's there, or else the first file of that name on `PATH` that
   can be run, as a shell looks. One that's there but can't be run is
   found, and `Proc` fails with `CantRun` when it's run. *)
let find_program cmd =
  let runnable p =
    (try not (Sys.is_directory p) with Sys_error _ -> false)
    &&
    try
      Unix.access p [ Unix.X_OK ];
      true
    with Unix.Unix_error _ -> false
  in
  if String.contains cmd '/' then if Sys.file_exists cmd then Some cmd else None
  else
    let path = Option.value (Sys.getenv_opt "PATH") ~default:"/usr/bin:/bin" in
    List.find_map
      (fun dir ->
        let p = Filename.concat (if dir = "" then "." else dir) cmd in
        if runnable p then Some p else None)
      (String.split_on_char ':' path)

(* What became of a program, as the prelude's private [ProcOutcome]. *)
let proc_outcome name args =
  Value.VCon { ty = Path.prelude "ProcOutcome"; name; args }

(* Run the program at [path] as [cmd], with [args], and wait for its exit
   code. It writes to, and reads from, what this program does, so what
   this program has written so far goes out first. A program the system
   won't start, or one killed by a signal, is said so, for `Proc` to fail
   with. *)
let run_program path cmd args =
  flush stdout;
  flush stderr;
  match
    Unix.create_process path
      (Array.of_list (cmd :: args))
      Unix.stdin Unix.stdout Unix.stderr
  with
  | exception Unix.Unix_error (e, _, _) ->
      proc_outcome "ProcNotStarted" [ VStr (Unix.error_message e) ]
  | pid ->
      let rec wait () =
        match Unix.waitpid [] pid with
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
        | _, Unix.WEXITED code -> proc_outcome "ProcExited" [ VInt code ]
        | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) -> proc_outcome "ProcKilled" []
      in
      wait ()

(* `Some(args)` or `None` *)
let option name args = Value.VCon { ty = Path.prelude "Option"; name; args }

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
    (* fn(Str) -> FsOutcome<Bytes>, the real `Fs.read` *)
    fn ~runtime:true "fs_read"
      (Fun
         ( [ read str ],
           Con (Path.prelude "FsOutcome", [ bytes ]),
           open_row 0,
           open_row 1 ))
      (function
        | [ Value.VStr path ] as args -> (read_file path, args)
        | _ -> bug "fs_read");
    (* fn(Str, Bytes) -> FsOutcome<Unit>, the real `Fs.write` *)
    fn ~runtime:true "fs_write"
      (Fun
         ( [ read str; read bytes ],
           Con (Path.prelude "FsOutcome", [ unit ]),
           open_row 0,
           open_row 1 ))
      (function
        | [ Value.VStr path; Value.VBytes data ] as args ->
            (write_file path data, args)
        | _ -> bug "fs_write");
    (* fn(Str) -> Bool *)
    fn ~runtime:true "fs_exists"
      (Fun ([ read str ], bool, open_row 0, open_row 1))
      (function
        | [ Value.VStr path ] as args ->
            (Value.VBool (Sys.file_exists path), args)
        | _ -> bug "fs_exists");
    (* fn() -> Array<Str> *)
    fn ~runtime:true "os_args"
      (Fun ([], array str, open_row 0, open_row 1))
      (fun a ->
        (* a `Str` is UTF-8, so an argument that isn't can't be one *)
        let str i s =
          if String.is_valid_utf_8 s then Value.VStr s
          else
            raise (Panic (Printf.sprintf "argument %d isn't UTF-8" (i + 1)))
        in
        let strs = List.mapi str !args in
        (Value.VArray (Array.of_list strs), a));
    (* fn(Str, Array<Str>) -> ProcOutcome, the real `Proc.run` *)
    fn ~runtime:true "proc_run"
      (Fun
         ( [ read str; read (array str) ],
           Con (Path.prelude "ProcOutcome", []),
           open_row 0,
           open_row 1 ))
      (function
        | [ Value.VStr cmd; Value.VArray xs ] as a ->
            let strs =
              Array.to_list
                (Array.map
                   (function Value.VStr s -> s | _ -> bug "proc_run")
                   xs)
            in
            ( (match find_program cmd with
              | Some path -> run_program path cmd strs
              | None -> proc_outcome "ProcMissing" []),
              a )
        | _ -> bug "proc_run");
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
  functions : builtin_fn list;  (** its associated functions, without `self` *)
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

(* ---- strings and bytes ----

   A `Str` is UTF-8, always, and `Bytes` are any bytes at all: the one way
   from bytes to a string is `Str.from_utf8`, which checks them. A string's
   indices are byte offsets, as `len` counts them, and a slice that would
   cut a character in two panics, so that a `Str` stays UTF-8. *)

(* Where [sub] first starts in [s], at [from] or after. *)
let find_from s sub from =
  let n = String.length s and m = String.length sub in
  let rec go i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else go (i + 1)
  in
  go from

(* Whether byte [i] of [s] starts a character, or ends [s]: it isn't one
   of the bytes after a character's first, which are 0b10xxxxxx. *)
let boundary s i =
  i = String.length s || Char.code s.[i] land 0xc0 <> 0x80

let slice s from to_ =
  let n = String.length s in
  let fail fmt = Printf.ksprintf (fun msg -> raise (Panic msg)) fmt in
  if from > to_ then fail "slice %d to %d ends before it starts" from to_;
  if from < 0 || to_ > n then
    fail "slice %d to %d is out of bounds for a string of length %d" from to_
      n;
  if not (boundary s from) then
    fail "slice %d to %d starts inside a character" from to_;
  if not (boundary s to_) then
    fail "slice %d to %d ends inside a character" from to_;
  String.sub s from (to_ - from)

let split s sep =
  if sep = "" then raise (Panic "`split` needs a separator that isn't empty");
  let rec go from =
    match find_from s sep from with
    | Some i -> String.sub s from (i - from) :: go (i + String.length sep)
    | None -> [ String.sub s from (String.length s - from) ]
  in
  go 0

let str_methods =
  let open Ty in
  let m name params ret eval =
    {
      name;
      scheme =
        scheme
          (Fun (List.map read (str :: params), ret, open_row 0, open_row 1));
      eval = (fun args -> (eval args, args));
      runtime = false;
    }
  in
  [
    (* fn(self: Str) -> Int, in bytes *)
    m "len" [] int (function
      | [ VStr s ] -> VInt (String.length s)
      | _ -> bug "Str.len");
    (* fn(self: Str, from: Int, to: Int) -> Str: the bytes from [from] up
       to, but not including, [to] *)
    m "slice" [ int; int ] str (function
      | [ VStr s; VInt from; VInt to_ ] -> VStr (slice s from to_)
      | _ -> bug "Str.slice");
    (* fn(self: Str, s: Str) -> Option<Int>: where [s] first starts *)
    m "find" [ str ]
      (Con (Path.prelude "Option", [ int ]))
      (function
        | [ VStr s; VStr sub ] -> (
            match find_from s sub 0 with
            | Some i -> option "Some" [ VInt i ]
            | None -> option "None" [])
        | _ -> bug "Str.find");
    (* fn(self: Str, sep: Str) -> Array<Str>: the parts between each [sep] *)
    m "split" [ str ] (array str) (function
      | [ VStr s; VStr sep ] ->
          VArray
            (Array.of_list (List.map (fun p -> Value.VStr p) (split s sep)))
      | _ -> bug "Str.split");
    (* fn(self: Str) -> Str, without the spaces, tabs and newlines at
       either end *)
    m "trim" [] str (function
      | [ VStr s ] -> VStr (String.trim s)
      | _ -> bug "Str.trim");
    (* fn(self: Str, prefix: Str) -> Bool *)
    m "starts_with" [ str ] bool (function
      | [ VStr s; VStr prefix ] -> VBool (String.starts_with ~prefix s)
      | _ -> bug "Str.starts_with");
    (* fn(self: Str, s: Str) -> Str: this, then [s] *)
    m "concat" [ str ] str (function
      | [ VStr a; VStr b ] -> VStr (a ^ b)
      | _ -> bug "Str.concat");
    (* fn(self: Str) -> Bytes: its UTF-8 *)
    m "bytes" [] bytes (function
      | [ VStr s ] -> VBytes s
      | _ -> bug "Str.bytes");
  ]

let str_functions =
  let open Ty in
  [
    {
      (* fn(b: Bytes) -> Str ! InvalidUtf8 *)
      name = "from_utf8";
      scheme =
        scheme
          (Fun
             ( [ read bytes ],
               str,
               { labels = [ label "InvalidUtf8" ]; tail = None },
               open_row 0 ));
      eval =
        (function
        | [ Value.VBytes b ] as args ->
            if String.is_valid_utf_8 b then (Value.VStr b, args)
            else raise (Fail (Value.VTag { name = "InvalidUtf8"; args = [] }))
        | _ -> bug "Str.from_utf8");
      runtime = false;
    };
  ]

let bytes_methods =
  let open Ty in
  [
    {
      (* fn(self: Bytes) -> Int *)
      name = "len";
      scheme = scheme (Fun ([ read bytes ], int, open_row 0, open_row 1));
      eval =
        (function
        | [ Value.VBytes b ] as args -> (Value.VInt (String.length b), args)
        | _ -> bug "Bytes.len");
      runtime = false;
    };
  ]

let types =
  let t ?(methods = []) ?(functions = []) ?(arity = 0) name =
    { name; arity; methods; functions }
  in
  (* `Array` before `Str`, whose `len` an old-style `len(xs)` means
     less often (resolve.ml) *)
  [
    t "Int";
    t "Bool";
    t "Unit";
    t "Array" ~arity:1 ~methods:array_methods;
    t "Str" ~methods:str_methods ~functions:str_functions;
    t "Bytes" ~methods:bytes_methods;
  ]

(* ---- built-in dependencies ----

   The dependencies the runtime installs around `main`, if it uses them:
   each is declared in [source], with its real implementation, `real`
   (deps.md, "`main`"). *)
let runtime_deps = [ "Clock"; "Random"; "Console"; "Fs"; "Os"; "Proc" ]

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
        (fun t ->
          List.find_opt
            (fun (f : builtin_fn) -> f.name = m)
            (t.methods @ t.functions))

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
                (fun (okind, (f : builtin_fn)) : Iface.op ->
                  { oname = f.name; opub = true; okind; oscheme = f.scheme })
                (List.map (fun f -> (Iface.Method, f)) t.methods
                @ List.map (fun f -> (Iface.Function, f)) t.functions);
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
