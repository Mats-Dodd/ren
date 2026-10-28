(* What the prelude's built-in functions do when they run: the runtime half
   of the prelude, whose static half, each one's type, is prelude.ml's.
   Each is run by its id (intrinsic.ml), with a [match], so the compiler
   checks that every built-in can run. *)

open Value

(* A built-in function has panicked, which the interpreter reports at the
   call. *)
exception Panic of string

(* A built-in function has failed with this error, which the call fails
   with. *)
exception Fail of Value.t

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug x =
  failwith ("bug: `" ^ Intrinsic.name x ^ "` was called with the wrong values")

(* What the real implementations of the built-in dependencies run on: the
   system's clock, its source of randomness, stdout and stderr. Each is a number
   of milliseconds, as the prelude's source represents time. [Unix.gettimeofday] is
   the wall clock, which can be set back, so `instant` isn't yet the clock
   that never goes back that `Instant` promises: OCaml's standard library
   has no monotonic one (deps.md, "Built in"). *)
let now_ms () = Int64.of_float (Unix.gettimeofday () *. 1000.)

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
        | _, Unix.WEXITED code ->
            proc_outcome "ProcExited" [ VInt (Int64.of_int code) ]
        | _, (Unix.WSIGNALED _ | Unix.WSTOPPED _) ->
            proc_outcome "ProcKilled" []
      in
      wait ()

(* `Some(args)` or `None` *)
let option name args = VCon { ty = Path.prelude "Option"; name; args }

(* `Random.int`'s panic, real or not, for a [below] it can't stay below *)
let not_above_0 below =
  Printf.sprintf "`Random.int` needs a number above 0 to stay below, not %Ld"
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
let boundary s i = i = String.length s || Char.code s.[i] land 0xc0 <> 0x80

let slice s from to_ =
  let n = Int64.of_int (String.length s) in
  let fail fmt = Printf.ksprintf (fun msg -> raise (Panic msg)) fmt in
  if from > to_ then fail "slice %Ld to %Ld ends before it starts" from to_;
  if from < 0L || to_ > n then
    fail "slice %Ld to %Ld is out of bounds for a string of length %Ld" from to_
      n;
  (* in bounds, so each fits in an OCaml [int] *)
  let i = Int64.to_int from and j = Int64.to_int to_ in
  if not (boundary s i) then
    fail "slice %Ld to %Ld starts inside a character" from to_;
  if not (boundary s j) then
    fail "slice %Ld to %Ld ends inside a character" from to_;
  String.sub s i (j - i)

let split s sep =
  if sep = "" then raise (Panic "`split` needs a separator that isn't empty");
  let rec go from =
    match find_from s sep from with
    | Some i -> String.sub s from (i - from) :: go (i + String.length sep)
    | None -> [ String.sub s from (String.length s - from) ]
  in
  go 0

(* ---- numbers ---- *)

(* An `Int`, from a count OCaml keeps as an [int]: a length, an index. *)
let int n = VInt (Int64.of_int n)

(* [f], made an `Int` by [how] (`round` or `truncate`), which panics if
   it isn't one: a NaN (nan.ml), infinity, or too big for 64 bits. 2^63
   is the first float past the largest `Int`. *)
let to_int how f =
  if Float.is_nan f then raise (Panic (Nan.observed (Nan.converted how) f));
  let r = if how = "round" then Float.round f else Float.trunc f in
  if
    Float.is_finite r
    && r >= -9.223372036854775808e18
    && r < 9.223372036854775808e18
  then VInt (Int64.of_float r)
  else
    raise
      (Panic
         (Printf.sprintf "`%s` of %s doesn't fit in an `Int`" how
            (Ast.show_float f)))

(* `A` to `Z` made `a` to `z`, and every other byte left as it is, so a
   `Str` stays UTF-8. There's no table of the rest of Unicode's cases
   yet. *)
let lower s = String.map Char.lowercase_ascii s

(* ---- running one ---- *)

(* A built-in that changes none of its parameters: its result, with the
   values it was given as their final values. *)
let pure f args = (f args, args)

(* The one dictionary a built-in that needs a requirement is given: a
   `Map`'s `hash` of its keys, `sort`'s order. *)
let one_dict x (dicts : Value.dict list) =
  match dicts with [ d ] -> d | _ -> bug x

(* ---- numbers ---- *)

(* [f ()], one operation of Arith's (arith.ml), which panics as the
   operator does, but without a help: a wrapping method is the
   operator's, and this is already a method. *)
let number f =
  try f () with
  | Arith.Overflowed { op; shown; _ } ->
      raise (Panic (Arith.overflow_message ~op ~shown))
  | Arith.Undefined msg -> raise (Panic msg)

(* [k], the amount of the shift [op], `shl` or `shr`, if it's one: 0 to
   63, or a panic. *)
let shift op k =
  if Int64.compare k 0L < 0 || Int64.compare k 63L > 0 then
    raise
      (Panic (Printf.sprintf "`%s` by %Ld: a shift is by 0 to 63" op k));
  Int64.to_int k

(* The operator [op], as the method of [x]'s two operands, a NaN it
   makes tagged by [made]. *)
let arith ~made x op = function
  | [ a; b ] -> number (fun () -> Arith.binop ~made op a b)
  | _ -> bug x

(* [f ()], which may walk a value with a NaN in it, as [what] does
   (nan.ml): a panic, said at the call. *)
let walking what f =
  try f () with Nan.Seen v -> raise (Panic (Nan.observed what v))

(* ---- tables ---- *)

let table x = function VTable t -> t | _ -> bug x

(* The pair a `Map.of` is given, `(k, v)`. *)
let pair x = function VTuple [ k; v ] -> (k, v) | _ -> bug x

let run (x : Intrinsic.t) ~(dicts : Value.dict list) ~(tys : Ty.ty list)
    ~made =
  match x with
  | Show -> fun _ -> failwith "bug: `show` is run by the interpreter"
  (* the journal's need the types of what they're given, as `show` does,
     and the program's types, to write and read values through *)
  | Journal_kept | Journal_gave | Journal_answer | Journal_outputs
  | Journal_load ->
      fun _ ->
        failwith ("bug: `" ^ Intrinsic.name x ^ "` is run by the interpreter")
  (* the real `Clock.now` and `Clock.instant` *)
  | Clock_now | Clock_instant -> pure (fun _ -> VInt (now_ms ()))
  | Clock_sleep ->
      pure (function
        | [ VInt ms ] ->
            if ms > 0L then Unix.sleepf (Int64.to_float ms /. 1000.);
            VUnit
        | _ -> bug x)
  | Random_int ->
      pure (function
        | [ VInt below ] ->
            if below <= 0L then raise (Panic (not_above_0 below));
            let state = Random.State.make_self_init () in
            VInt (Random.State.int64 state below)
        | _ -> bug x)
  (* the state after [state] of the test `Random`, a linear congruential
     generator's, which never goes negative *)
  | Seeded_next ->
      pure (function
        | [ VInt state ] ->
            let state = Int64.to_int state in
            VInt
              (Int64.of_int
                 (((abs state * 1103515245) + 12345) land 0x7fffffff))
        | _ -> bug x)
  (* a number from 0 below [below], from that state's high bits, which
     vary more than its low ones *)
  | Seeded_int ->
      pure (function
        | [ VInt state; VInt below ] ->
            if below <= 0L then raise (Panic (not_above_0 below));
            VInt (Int64.rem (Int64.shift_right_logical state 16) below)
        | _ -> bug x)
  | Console_write ->
      pure (function
        | [ VStr line ] ->
            print_endline line;
            VUnit
        | _ -> bug x)
  (* the real `Console.error`: stderr *)
  | Console_error ->
      pure (function
        | [ VStr line ] ->
            prerr_endline line;
            VUnit
        | _ -> bug x)
  (* the real `Fs.read` *)
  | Fs_read -> pure (function [ VStr path ] -> read_file path | _ -> bug x)
  (* the real `Fs.write` *)
  | Fs_write ->
      pure (function
        | [ VStr path; VBytes data ] -> write_file path data
        | _ -> bug x)
  | Fs_exists ->
      pure (function
        | [ VStr path ] -> VBool (Sys.file_exists path)
        | _ -> bug x)
  | Os_args ->
      pure (fun _ ->
          (* a `Str` is UTF-8, so an argument that isn't can't be one *)
          let str i s =
            if String.is_valid_utf_8 s then VStr s
            else
              raise (Panic (Printf.sprintf "argument %d isn't UTF-8" (i + 1)))
          in
          array_of_list (List.mapi str !args))
  (* the real `Proc.run` *)
  | Proc_run ->
      pure (function
        | [ VStr cmd; VArray xs ] -> (
            let strs =
              Array.to_list
                (Array.map (function VStr s -> s | _ -> bug x) (items xs))
            in
            match find_program cmd with
            | Some path -> run_program path cmd strs
            | None -> proc_outcome "ProcMissing" [])
        | _ -> bug x)
  | Array_len -> pure (function [ VArray xs ] -> int xs.len | _ -> bug x)
  (* the one that changes a parameter: its receiver, `inout` *)
  | Array_push -> (
      function [ VArray xs; x ] -> (VUnit, [ push xs x; x ]) | _ -> bug x)
  (* by the elements' order, a merge sort, which keeps equal ones in the
     order they were *)
  | Array_sort ->
      pure (function
        | [ VArray xs ] -> (
            match one_dict x dicts with
            | Ord compare ->
                walking (Nan.compared "sort") (fun () ->
                    array_of_list
                      (List.stable_sort compare (Array.to_list (items xs))))
            | _ -> bug x)
        | _ -> bug x)
  (* `map`'s own: an array is a value here, so `map` replacing each
     element where it is gives what a new array would *)
  | Array_reserve -> pure (fun _ -> array_of_list [])
  | Map_into ->
      pure (fun _ ->
          VCon { ty = Path.prelude "MapInto"; name = "InPlace"; args = [] })
  | Unsafe_cast -> pure (function [ v ] -> v | _ -> bug x)
  (* `sum`'s own: whether its `T` is `Float`, and its lanes if it is *)
  | Float_lanes -> pure (fun _ -> VBool (tys = [ Ty.float ]))
  | Float_sum ->
      pure (function
        | [ VArray xs ] ->
            VFloat
              (Arith.float_sum ~made
                 (Array.map
                    (function VFloat f -> f | _ -> bug x)
                    (items xs)))
        | _ -> bug x)
  (* ---- `Map` and `Set`, by the `hash` of their keys (table.ml) ---- *)
  | Map_empty | Set_empty -> pure (fun _ -> VTable Table.empty)
  | Map_of ->
      pure (function
        | [ VArray pairs ] ->
            VTable
              (Table.of_list (one_dict x dicts)
                 (List.map (pair x) (Array.to_list (items pairs))))
        | _ -> bug x)
  | Set_of ->
      pure (function
        | [ VArray xs ] ->
            VTable
              (Table.of_list (one_dict x dicts)
                 (List.map (fun v -> (v, VUnit)) (Array.to_list (items xs))))
        | _ -> bug x)
  | Map_get ->
      pure (function
        | [ m; k ] -> (
            match Table.get (one_dict x dicts) (table x m) k with
            | Some v -> option "Some" [ v ]
            | None -> option "None" [])
        | _ -> bug x)
  | Map_includes | Set_includes ->
      pure (function
        | [ m; k ] -> VBool (Table.find (one_dict x dicts) (table x m) k <> None)
        | _ -> bug x)
  (* the ones that change their receiver, `inout` *)
  | Map_set -> (
      function
      | [ m; k; v ] ->
          ( VUnit,
            [ VTable (Table.set (one_dict x dicts) (table x m) k v); k; v ] )
      | _ -> bug x)
  | Set_add -> (
      function
      | [ m; k ] ->
          ( VUnit,
            [ VTable (Table.set (one_dict x dicts) (table x m) k VUnit); k ] )
      | _ -> bug x)
  | Map_remove | Set_remove -> (
      function
      | [ m; k ] ->
          (VUnit, [ VTable (Table.remove (one_dict x dicts) (table x m) k); k ])
      | _ -> bug x)
  | Map_keys ->
      pure (function
        | [ m ] -> array_of_list (List.map fst (Table.to_list (table x m)))
        | _ -> bug x)
  | Map_values ->
      pure (function
        | [ m ] -> array_of_list (List.map snd (Table.to_list (table x m)))
        | _ -> bug x)
  | Map_len | Set_len ->
      pure (function [ m ] -> int (Table.len (table x m)) | _ -> bug x)
  (* in bytes *)
  | Str_len ->
      pure (function [ VStr s ] -> int (String.length s) | _ -> bug x)
  (* the bytes from [from] up to, but not including, [to] *)
  | Str_slice ->
      pure (function
        | [ VStr s; VInt from; VInt to_ ] -> VStr (slice s from to_)
        | _ -> bug x)
  (* where [s] first starts *)
  | Str_index ->
      pure (function
        | [ VStr s; VStr sub ] -> (
            match find_from s sub 0 with
            | Some i -> option "Some" [ int i ]
            | None -> option "None" [])
        | _ -> bug x)
  (* the parts between each [sep] *)
  | Str_split ->
      pure (function
        | [ VStr s; VStr sep ] ->
            array_of_list (List.map (fun p -> VStr p) (split s sep))
        | _ -> bug x)
  (* without the spaces, tabs and newlines at either end *)
  | Str_trim ->
      pure (function [ VStr s ] -> VStr (String.trim s) | _ -> bug x)
  | Str_starts_with ->
      pure (function
        | [ VStr s; VStr prefix ] -> VBool (String.starts_with ~prefix s)
        | _ -> bug x)
  (* this, then [s] *)
  | Str_concat ->
      pure (function [ VStr a; VStr b ] -> VStr (a ^ b) | _ -> bug x)
  (* its UTF-8 *)
  | Str_bytes -> pure (function [ VStr s ] -> VBytes s | _ -> bug x)
  | Str_from_utf8 ->
      pure (function
        | [ VBytes b ] ->
            if String.is_valid_utf_8 b then VStr b
            else
              raise (Fail (VTag { name = "InvalidUtf8"; args = []; tys = [] }))
        | _ -> bug x)
  | Bytes_len ->
      pure (function [ VBytes b ] -> int (String.length b) | _ -> bug x)
  | Str_lower -> pure (function [ VStr s ] -> VStr (lower s) | _ -> bug x)
  (* wrapping arithmetic at 64 bits, as [Int64]'s is *)
  | Int_wrapping_add ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.add a b) | _ -> bug x)
  | Int_wrapping_sub ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.sub a b) | _ -> bug x)
  | Int_wrapping_mul ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.mul a b) | _ -> bug x)
  | Int_wrapping_neg ->
      pure (function [ VInt a ] -> VInt (Int64.neg a) | _ -> bug x)
  | Int_xor ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.logxor a b) | _ -> bug x)
  | Int_bit_and ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.logand a b) | _ -> bug x)
  | Int_bit_or ->
      pure (function [ VInt a; VInt b ] -> VInt (Int64.logor a b) | _ -> bug x)
  (* the shifts: [Int64]'s, whose [shift_left] loses the bits shifted out
     and whose [shift_right] is arithmetic; by an amount outside 0 to 63
     it panics, as every build does at the call *)
  | Int_shl ->
      pure (function
        | [ VInt a; VInt k ] -> VInt (Int64.shift_left a (shift "shl" k))
        | _ -> bug x)
  | Int_shr ->
      pure (function
        | [ VInt a; VInt k ] -> VInt (Int64.shift_right a (shift "shr" k))
        | _ -> bug x)
  (* the operators, as methods, `n.add(2)`: Arith's, as `n + 2` is, with
     the panic said at the call *)
  | Int_add | Float_add -> pure (arith ~made x Add)
  | Int_sub | Float_sub -> pure (arith ~made x Sub)
  | Int_mul | Float_mul -> pure (arith ~made x Mul)
  | Int_div | Float_div -> pure (arith ~made x Div)
  | Int_rem | Float_rem -> pure (arith ~made x Mod)
  | Int_neg | Float_neg ->
      pure (function [ v ] -> number (fun () -> Arith.neg v) | _ -> bug x)
  | Float_of ->
      pure (function [ VInt n ] -> VFloat (Int64.to_float n) | _ -> bug x)
  | Float_round ->
      pure (function [ VFloat f ] -> to_int "round" f | _ -> bug x)
  | Float_truncate ->
      pure (function [ VFloat f ] -> to_int "truncate" f | _ -> bug x)
  (* a negative number's square root is a NaN, carried as arithmetic's
     are (nan.ml) *)
  | Float_sqrt ->
      pure (function
        | [ VFloat f ] -> VFloat (Nan.carried ~made f f (Float.sqrt f))
        | _ -> bug x)
