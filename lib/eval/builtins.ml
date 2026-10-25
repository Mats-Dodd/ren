(* What the prelude's built-in functions do when they run: the runtime half
   of the prelude, whose static half, each one's type, is prelude.ml's.
   Each is run by its name, as the prelude lists it. *)

open Value

(* A built-in function has panicked, which the interpreter reports at the
   call. *)
exception Panic of string

(* A built-in function has failed with this error, which the call fails
   with. *)
exception Fail of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug name = failwith ("bug: `" ^ name ^ "` was called with the wrong values")

(* What the real implementations of the built-in dependencies run on: the
   system's clock, its source of randomness, stdout and stderr. Each is a number
   of milliseconds, as the prelude's source represents time. [Unix.gettimeofday] is
   the wall clock, which can be set back, so `instant` isn't yet the clock
   that never goes back that `Instant` promises: OCaml's standard library
   has no monotonic one (deps.md, "Built in"). *)
let now_ms () = int_of_float (Unix.gettimeofday () *. 1000.)

(* What the system said to a read or a write, as the prelude's private
   [FsOutcome<T>], which its source turns into the value or an `FsError`. *)
let fs_outcome name args = VCon { ty = Path.prelude "FsOutcome"; name; args }

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
  VCon { ty = Path.prelude "ProcOutcome"; name; args }

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
let option name args = VCon { ty = Path.prelude "Option"; name; args }

(* `Random.int`'s panic, real or not, for a [below] it can't stay below *)
let not_above_0 below =
  Printf.sprintf "`Random.int` needs a number above 0 to stay below, not %d"
    below

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

(* ---- running one ---- *)

(* A built-in that changes none of its parameters: its result, with the
   values it was given as their final values. *)
let pure f args = (f args, args)

let run name =
  match name with
  | "show" -> fun _ -> failwith "bug: `show` is run by the interpreter"
  (* the real `Clock.now` and `Clock.instant` *)
  | "clock_now" | "clock_instant" -> pure (fun _ -> VInt (now_ms ()))
  | "clock_sleep" ->
      pure (function
        | [ VInt ms ] ->
            if ms > 0 then Unix.sleepf (float_of_int ms /. 1000.);
            VUnit
        | _ -> bug name)
  | "random_int" ->
      pure (function
        | [ VInt below ] ->
            if below <= 0 then raise (Panic (not_above_0 below));
            let state = Random.State.make_self_init () in
            VInt (Random.State.full_int state below)
        | _ -> bug name)
  (* the state after [state] of the test `Random`, a linear congruential
     generator's, which never goes negative *)
  | "seeded_next" ->
      pure (function
        | [ VInt state ] ->
            VInt (((abs state * 1103515245) + 12345) land 0x7fffffff)
        | _ -> bug name)
  (* a number from 0 below [below], from that state's high bits, which
     vary more than its low ones *)
  | "seeded_int" ->
      pure (function
        | [ VInt state; VInt below ] ->
            if below <= 0 then raise (Panic (not_above_0 below));
            VInt ((state lsr 16) mod below)
        | _ -> bug name)
  | "console_write" ->
      pure (function
        | [ VStr line ] ->
            print_endline line;
            VUnit
        | _ -> bug name)
  (* the real `Console.error`: stderr *)
  | "console_error" ->
      pure (function
        | [ VStr line ] ->
            prerr_endline line;
            VUnit
        | _ -> bug name)
  (* the real `Fs.read` *)
  | "fs_read" ->
      pure (function [ VStr path ] -> read_file path | _ -> bug name)
  (* the real `Fs.write` *)
  | "fs_write" ->
      pure (function
        | [ VStr path; VBytes data ] -> write_file path data
        | _ -> bug name)
  | "fs_exists" ->
      pure (function
        | [ VStr path ] -> VBool (Sys.file_exists path)
        | _ -> bug name)
  | "os_args" ->
      pure (fun _ ->
          (* a `Str` is UTF-8, so an argument that isn't can't be one *)
          let str i s =
            if String.is_valid_utf_8 s then VStr s
            else
              raise (Panic (Printf.sprintf "argument %d isn't UTF-8" (i + 1)))
          in
          VArray (Array.of_list (List.mapi str !args)))
  (* the real `Proc.run` *)
  | "proc_run" ->
      pure (function
        | [ VStr cmd; VArray xs ] -> (
            let strs =
              Array.to_list
                (Array.map (function VStr s -> s | _ -> bug name) xs)
            in
            match find_program cmd with
            | Some path -> run_program path cmd strs
            | None -> proc_outcome "ProcMissing" [])
        | _ -> bug name)
  | "Array.len" ->
      pure (function [ VArray xs ] -> VInt (Array.length xs) | _ -> bug name)
  (* the one that changes a parameter: its receiver, `inout` *)
  | "Array.push" -> (
      function
      | [ VArray xs; x ] -> (VUnit, [ VArray (Array.append xs [| x |]); x ])
      | _ -> bug name)
  (* in bytes *)
  | "Str.len" ->
      pure (function [ VStr s ] -> VInt (String.length s) | _ -> bug name)
  (* the bytes from [from] up to, but not including, [to] *)
  | "Str.slice" ->
      pure (function
        | [ VStr s; VInt from; VInt to_ ] -> VStr (slice s from to_)
        | _ -> bug name)
  (* where [s] first starts *)
  | "Str.find" ->
      pure (function
        | [ VStr s; VStr sub ] -> (
            match find_from s sub 0 with
            | Some i -> option "Some" [ VInt i ]
            | None -> option "None" [])
        | _ -> bug name)
  (* the parts between each [sep] *)
  | "Str.split" ->
      pure (function
        | [ VStr s; VStr sep ] ->
            VArray (Array.of_list (List.map (fun p -> VStr p) (split s sep)))
        | _ -> bug name)
  (* without the spaces, tabs and newlines at either end *)
  | "Str.trim" ->
      pure (function [ VStr s ] -> VStr (String.trim s) | _ -> bug name)
  | "Str.starts_with" ->
      pure (function
        | [ VStr s; VStr prefix ] -> VBool (String.starts_with ~prefix s)
        | _ -> bug name)
  (* this, then [s] *)
  | "Str.concat" ->
      pure (function [ VStr a; VStr b ] -> VStr (a ^ b) | _ -> bug name)
  (* its UTF-8 *)
  | "Str.bytes" -> pure (function [ VStr s ] -> VBytes s | _ -> bug name)
  | "Str.from_utf8" ->
      pure (function
        | [ VBytes b ] ->
            if String.is_valid_utf_8 b then VStr b
            else raise (Fail (VTag { name = "InvalidUtf8"; args = [] }))
        | _ -> bug name)
  | "Bytes.len" ->
      pure (function [ VBytes b ] -> VInt (String.length b) | _ -> bug name)
  | _ -> failwith ("bug: the unknown built-in `" ^ name ^ "`")
