(* What the prelude's built-in functions do when they run: the runtime half
   of the prelude, whose static half, each one's type, is prelude.ml's.
   Each is run by its id (intrinsic.ml), with a [match], so the compiler
   checks that every built-in can run. *)

open Value

(* A built-in function has panicked, which the interpreter reports at the
   call. *)
exception Panic of string

(* One that has a help of its own, which the panic says under it. *)
exception Panic_help of { msg : string; help : string }

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

(* The child of ren_spawn.c, which `fork`s, puts it in a process group of
   its own if asked, and `execv`s [path] with [argv], giving its pid, or
   raising the `Unix_error` of a `fork` or `execv` that failed. *)
external spawn : string -> string array -> bool -> int = "ren_spawn"

(* Run the program at [path] as [cmd], with [args], and wait for its exit
   code. It writes to, and reads from, what this program does, so what
   this program has written so far goes out first. With [group], it's in a
   process group of its own, which a cancel kills (Sched.wait_pid); else
   it's in this program's, as `Unix.create_process` would start it. A
   program the system won't start, or one killed by a signal, is said so,
   for `Proc` to fail with. *)
let start_program ~group path cmd args =
  flush stdout;
  flush stderr;
  match spawn path (Array.of_list (cmd :: args)) group with
  | exception Unix.Unix_error (e, _, _) ->
      Error (proc_outcome "ProcNotStarted" [ VStr (Unix.error_message e) ])
  | pid -> Ok pid

(* What became of a program that ended so. *)
let exit_outcome = function
  | Unix.WEXITED code -> proc_outcome "ProcExited" [ VInt (Int64.of_int code) ]
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> proc_outcome "ProcKilled" []

(* The real `Proc.run`: [cmd], found, started and waited for, by [wait],
   which the interpreter's scheduler does (Sched.wait_pid), so other
   tasks run meanwhile. *)
let run_program ~wait ~group cmd args =
  match find_program cmd with
  | None -> proc_outcome "ProcMissing" []
  | Some path -> (
      match start_program ~group path cmd args with
      | Error outcome -> outcome
      | Ok pid -> exit_outcome (wait pid))

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

(* ---- slices (foundations.md, decision 17) ----

   A slice is a value of the type it slices. A native build shares its
   root's buffer, which value semantics make impossible to tell from the
   copy the interpreter makes here (String.sub, Array.sub), so this is
   what every build does. *)

(* What's sliced, as a panic says it, and its length. *)
let sliced = function
  | VArray v -> ("an array", v.len)
  | VStr s -> ("a string", String.length s)
  | VBytes b -> ("bytes", String.length b)
  | _ -> failwith "bug: a slice of what isn't an array, a string or bytes"

(* [v]'s part from [i] up to [j], both in bounds, and for a string at
   character boundaries. *)
let part v i j =
  match v with
  | VArray xs -> array (Array.sub xs.store.items i (j - i))
  | VStr s -> VStr (String.sub s i (j - i))
  | VBytes b -> VBytes (String.sub b i (j - i))
  | _ -> failwith "bug: a slice of what isn't an array, a string or bytes"

(* For a string, that [i] and [j] are at characters' boundaries, as
   [slice] says. The help names `char_floor`, and `char_ceil` for a start
   (strings.md, "Cutting a character"), on the receiver as it's written,
   a `\002` (eval.ml, [Panic]). *)
let check_chars v from to_ i j =
  match v with
  | VStr s ->
      let fail help fmt =
        Printf.ksprintf (fun msg -> raise (Panic_help { msg; help })) fmt
      in
      if not (boundary s i) then
        fail
          (Printf.sprintf
             "to start where a character does, use `\002.char_floor(%Ld)` or \
              `\002.char_ceil(%Ld)`"
             from from)
          "slice %Ld to %Ld starts inside a character" from to_;
      if not (boundary s j) then
        fail
          (Printf.sprintf "to cut at most %Ld bytes, end at `\002.char_floor(%Ld)`"
             (Int64.sub to_ from) to_)
          "slice %Ld to %Ld ends inside a character" from to_
  | _ -> ()

(* The last character boundary at or before [i] of [s], or the first at
   or after it, `s.char_floor(i)` and `s.char_ceil(i)`: panics if [i]
   isn't in [s]. *)
let char_bound ~ceil s i =
  let n = String.length s in
  if i < 0L || i > Int64.of_int n then
    raise
      (Panic
         (Printf.sprintf "`%s` %Ld is out of bounds for a string of length %d"
            (if ceil then "char_ceil" else "char_floor")
            i n));
  let rec go k = if boundary s k then k else go (if ceil then k + 1 else k - 1) in
  go (Int64.to_int i)

(* `c.code()`: the code point of a string of one, panicking on any other,
   with a help naming the receiver, a `\002`, if it has more. *)
let code s =
  if s = "" then
    raise (Panic "`code()` takes one code point, and this string is empty");
  let d = String.get_utf_8_uchar s 0 in
  if Uchar.utf_decode_length d = String.length s then
    Int64.of_int (Uchar.to_int (Uchar.utf_decode_uchar d))
  else
    let rec count k n =
      if k >= String.length s then n
      else count (k + Uchar.utf_decode_length (String.get_utf_8_uchar s k)) (n + 1)
    in
    raise
      (Panic_help
         {
           msg =
             Printf.sprintf "`code()` takes one code point, and this string has %d"
               (count 0 0);
           help = "for each code point: `for c in \002.chars()`, and `c.code()`";
         })

(* `Str.of_code(n)`: the string of one code point, [n], a Unicode scalar
   value. *)
let of_code n =
  if n < 0L || n > 0x10FFFFL || (n >= 0xD800L && n <= 0xDFFFL) then
    raise
      (Panic_help
         {
           msg = Printf.sprintf "`Str.of_code(%Ld)` isn't a Unicode scalar value" n;
           help = "a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, the surrogates";
         });
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b (Uchar.of_int (Int64.to_int n));
  Buffer.contents b

(* `v[from..to]`: panics if the range ends before it starts, isn't in
   [v], or, in a string, cuts a character. *)
let slice_value v from to_ =
  let what, n = sliced v in
  let fail fmt = Printf.ksprintf (fun msg -> raise (Panic msg)) fmt in
  if from > to_ then fail "slice %Ld to %Ld ends before it starts" from to_;
  if from < 0L || to_ > Int64.of_int n then
    fail "slice %Ld to %Ld is out of bounds for %s of length %d" from to_ what n;
  let i = Int64.to_int from and j = Int64.to_int to_ in
  check_chars v from to_ i j;
  part v i j

(* The halves of `v.split_at(n)`, `v[0..n]` and `v[n..len]`: panics if
   [n] isn't in [v], or in a string, if it's inside a character, as the
   first half's slice would. *)
let split_halves v n =
  let what, len = sliced v in
  if n < 0L || n > Int64.of_int len then
    raise
      (Panic
         (Printf.sprintf "`split_at` %Ld is out of bounds for %s of length %d" n
            what len));
  let k = Int64.to_int n in
  check_chars v 0L n 0 k;
  (part v 0 k, part v k len)

(* [v] with its part from [i] up to [j] replaced by [w], of the same type:
   what `&v[i..j]` writes back. The range is one a slice of [v] read. *)
let splice v i j w =
  let i = Int64.to_int i and j = Int64.to_int j in
  let _, n = sliced v in
  let before = part v 0 i and after = part v j n in
  match (before, w, after) with
  | VArray a, VArray b, VArray c ->
      Value.array (Array.concat [ items a; items b; items c ])
  | VStr a, VStr b, VStr c -> VStr (a ^ b ^ c)
  | VBytes a, VBytes b, VBytes c -> VBytes (a ^ b ^ c)
  | _ -> failwith "bug: a splice of different kinds of values"

(* [a] followed by [b]: what a `split_at` writes back. *)
let join a b =
  match (a, b) with
  | VArray a, VArray b -> Value.array (Array.append (items a) (items b))
  | VStr a, VStr b -> VStr (a ^ b)
  | VBytes a, VBytes b -> VBytes (a ^ b)
  | _ -> failwith "bug: a join of different kinds of values"

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
let upper s = String.map Char.uppercase_ascii s

(* `s.line_col(at)`: the line [at] is on, counting `\n`s before it from
   1, and its column, counting code points from the line's start from 1
   (strings.md, "The API"). Panics if [at] isn't in [s], or is inside a
   character, with a help naming the receiver, a `\002`. *)
let line_col s at =
  let n = String.length s in
  if at < 0L || at > Int64.of_int n then
    raise
      (Panic
         (Printf.sprintf "`line_col` %Ld is out of bounds for a string of length %d" at n));
  let at = Int64.to_int at in
  if not (boundary s at) then
    raise
      (Panic_help
         {
           msg = Printf.sprintf "`line_col` %d is inside a character" at;
           help =
             Printf.sprintf "the character it's in starts at `\002.char_floor(%d)`" at;
         });
  let line = ref 1 and col = ref 1 in
  for i = 0 to at - 1 do
    if s.[i] = '\n' then (
      incr line;
      col := 1)
    else if Char.code s.[i] land 0xc0 <> 0x80 then incr col
  done;
  (!line, !col)

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

(* The state after [state] of the test `Random`, a linear congruential
   generator's, which never goes negative. *)
let seeded_next state =
  let state = Int64.to_int state in
  Int64.of_int (((abs state * 1103515245) + 12345) land 0x7fffffff)

(* A number from 0 below [below], from that state's high bits, which vary
   more than its low ones. *)
let seeded_int state below =
  if below <= 0L then raise (Panic (not_above_0 below));
  Int64.rem (Int64.shift_right_logical state 16) below

(* ---- layer 3: reads and writes at an offset (compiler.md, "Bytes
   stage", "Layer 3: the API") ---- *)

(* Panics unless [width] bytes at [at] are in [b]: computed so that a
   huge [at] can't overflow into a small one. A byte's message is
   `b.at(i)`'s. *)
let room b at width =
  let len = String.length b in
  let len64 = Int64.of_int len in
  if
    Int64.compare at 0L < 0
    || Int64.compare at (Int64.sub len64 (Int64.of_int width)) > 0
  then
    raise
      (Panic
         (if width = 1 then
            Printf.sprintf "index %Ld is out of bounds for bytes of length %d" at
              len
          else
            Printf.sprintf "%d bytes at %Ld are out of bounds for bytes of length %d"
              width at len));
  Int64.to_int at

(* The sized type a write of [a] stores into, whose range it checks: none
   for `i64`, which any `Int` fits. *)
let stored_as (a : Intrinsic.access) : Sized.t option =
  match (a.width, a.signed) with
  | 1, false -> Some U8
  | 1, true -> Some I8
  | 2, false -> Some U16
  | 2, true -> Some I16
  | 4, false -> Some U32
  | 4, true -> Some I32
  | _, false -> Some U64
  | _, true -> None

(* [a]'s number at [at] in [b]. A `u64` of 2^63 or more isn't an `Int`. *)
let read_at (a : Intrinsic.access) b at =
  let i = room b at a.width in
  match (a.width, a.signed, a.big) with
  | 1, false, _ -> Int64.of_int (String.get_uint8 b i)
  | 1, true, _ -> Int64.of_int (String.get_int8 b i)
  | 2, false, false -> Int64.of_int (String.get_uint16_le b i)
  | 2, false, true -> Int64.of_int (String.get_uint16_be b i)
  | 2, true, false -> Int64.of_int (String.get_int16_le b i)
  | 2, true, true -> Int64.of_int (String.get_int16_be b i)
  | 4, false, big ->
      let x = if big then String.get_int32_be b i else String.get_int32_le b i in
      Int64.logand (Int64.of_int32 x) 0xFFFF_FFFFL
  | 4, true, big ->
      Int64.of_int32 (if big then String.get_int32_be b i else String.get_int32_le b i)
  | _, signed, big ->
      let x = if big then String.get_int64_be b i else String.get_int64_le b i in
      if (not signed) && Int64.compare x 0L < 0 then
        raise
          (Panic_help
             {
               msg =
                 Printf.sprintf
                   "`%s` at %Ld read %Lu, which is more than an `Int` holds"
                   (Intrinsic.access_name a) at x;
               help =
                 Printf.sprintf "read its bits as an `Int` with `i64_%s`"
                   (if big then "be" else "le");
             });
      x

(* [b] with [x] written at [at] as [a] says: a copy, since a string is a
   value here. *)
let write_at (a : Intrinsic.access) b at x =
  (match stored_as a with
  | Some k when not (Sized.fits k x) ->
      raise (Panic (Sized.doesnt_fit k (Int64.to_string x)))
  | _ -> ());
  let i = room b at a.width in
  let out = Bytes.of_string b in
  (match (a.width, a.big) with
  | 1, _ -> Bytes.set_uint8 out i (Int64.to_int (Int64.logand x 0xFFL))
  | 2, false -> Bytes.set_uint16_le out i (Int64.to_int (Int64.logand x 0xFFFFL))
  | 2, true -> Bytes.set_uint16_be out i (Int64.to_int (Int64.logand x 0xFFFFL))
  | 4, false -> Bytes.set_int32_le out i (Int64.to_int32 x)
  | 4, true -> Bytes.set_int32_be out i (Int64.to_int32 x)
  | _, false -> Bytes.set_int64_le out i x
  | _, true -> Bytes.set_int64_be out i x);
  Bytes.to_string out

(* The 64 bits [x] is written as, as a `VarInt` ([signed], zigzag) or a
   `VarUInt`, which holds no negative number. *)
let var_bits signed x =
  if signed then Int64.logxor (Int64.shift_left x 1) (Int64.shift_right x 63)
  else if Int64.compare x 0L < 0 then
    raise
      (Panic
         (Printf.sprintf
            "%Ld doesn't fit in a `VarUInt`, which holds 0 to 9223372036854775807" x))
  else x

(* How many bytes LEB128 writes the bits [z] in, 7 a byte: 1 to 10. *)
let var_size z =
  let rec go n z =
    let z = Int64.shift_right_logical z 7 in
    if z = 0L then n else go (n + 1) z
  in
  go 1 z

(* [b] with [x] written at [at] as a `VarInt` or a `VarUInt`, and how
   many bytes that took. *)
let write_var signed b at x =
  let z = var_bits signed x in
  let n = var_size z in
  let i = room b at n in
  let out = Bytes.of_string b in
  let rec go k z =
    let low = Int64.to_int (Int64.logand z 0x7FL) in
    if k = n - 1 then Bytes.set_uint8 out (i + k) low
    else (
      Bytes.set_uint8 out (i + k) (low lor 0x80);
      go (k + 1) (Int64.shift_right_logical z 7))
  in
  go 0 z;
  (Bytes.to_string out, n)

let run (x : Intrinsic.t) ~(dicts : Value.dict list) ~(tys : Ty.ty list)
    ~made =
  match x with
  | Show -> fun _ -> failwith "bug: `show` is run by the interpreter"
  (* the journal's need the types of what they're given, as `show` does,
     and the program's types, to write and read values through *)
  | Journal_kept | Journal_gave | Journal_answer | Journal_outputs
  | Journal_load
  (* and the scheduler's, which run blocks, and wait (eval.ml, [tasks]) *)
  | Scope_run | Task_spawn
  | Task_until | Arm_release | Arm_retake | Task_timeout
  | Task_isolate | Task_map
  | Task_each | Task_both | Task_race | Task_beside | Task_background
  | Background_spawn | Task_produce | Task_map_pull | Outbox_send | Inbox_take
  | Async_yield | Async_tick
  | Runtime_single | Runtime_sim | Runtime_leave | Sim_time | Sim_sleep
  | Sim_advance | Sim_alarm | Task_random | Task_drain | Async_worker
  (* and the keyed instance family's, which keep instances and run their
     operations, and `Call`'s, which read the program's types (eval.ml,
     [family]) *)
  | Family_open | Family_call | Family_make | Family_keys | Family_evict | Family_evictable
  | Family_counts | Family_close | Family_pin | Family_visit | Family_idle | Family_edge
  | Family_enter | Family_post | Family_hold | Family_made | Family_kept
  | Call_first_hash | Call_add | Call_max
  | Call_min | Call_concat | Call_fold | Call_operations
  (* and the real `Net`'s and `Proc.run`, which wait too (net.ml,
     [run_program]) *)
  | Net_listen | Net_accept | Net_accept_until | Net_read | Net_write
  | Net_close | Proc_run ->
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
  | Seeded_next ->
      pure (function [ VInt state ] -> VInt (seeded_next state) | _ -> bug x)
  | Seeded_int ->
      pure (function
        | [ VInt state; VInt below ] -> VInt (seeded_int state below)
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
  | Lib_panic -> (
      function
      | [ VStr what ] -> raise (Panic what)
      | _ -> bug x)
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
  (* `x.hash()`: its type's `hash`, with no seed (walk.ml, [fixed_hash]) *)
  | Hash -> (
      pure (function
        | [ v ] -> (
            match one_dict x dicts with
            | Hash { hash; _ } -> VInt (Walk.unseeded (fun () -> hash v))
            | _ -> bug x)
        | _ -> bug x))
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
  | Str_byte_len ->
      pure (function [ VStr s ] -> int (String.length s) | _ -> bug x)
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
  (* the rest of strings.md's table, and `Bytes`' same names, which mean
     the same (compiler.md, "Bytes stage, part two", step 5) *)
  | Str_ends_with ->
      pure (function
        | [ VStr s; VStr suffix ] -> VBool (String.ends_with ~suffix s)
        | _ -> bug x)
  | Bytes_index ->
      pure (function
        | [ VBytes s; VBytes sub ] -> (
            match find_from s sub 0 with
            | Some i -> option "Some" [ int i ]
            | None -> option "None" [])
        | _ -> bug x)
  | Bytes_starts_with ->
      pure (function
        | [ VBytes s; VBytes prefix ] -> VBool (String.starts_with ~prefix s)
        | _ -> bug x)
  | Bytes_ends_with ->
      pure (function
        | [ VBytes s; VBytes suffix ] -> VBool (String.ends_with ~suffix s)
        | _ -> bug x)
  | Bytes_split ->
      pure (function
        | [ VBytes s; VBytes sep ] ->
            array_of_list (List.map (fun p -> VBytes p) (split s sep))
        | _ -> bug x)
  | Bytes_trim ->
      pure (function [ VBytes s ] -> VBytes (String.trim s) | _ -> bug x)
  | Str_ascii_upper -> pure (function [ VStr s ] -> VStr (upper s) | _ -> bug x)
  | Bytes_ascii_upper ->
      pure (function [ VBytes s ] -> VBytes (upper s) | _ -> bug x)
  | Str_line_col ->
      pure (function
        | [ VStr s; VInt at ] ->
            let line, col = line_col s at in
            VTuple [ int line; int col ]
        | _ -> bug x)
  (* this, then [s]: `+`, and `+=`, a copy here, which a native build
     makes in place when it can (compiler.md, "Bytes stage, part two",
     "Appending in place") *)
  | Str_add ->
      pure (function [ VStr a; VStr b ] -> VStr (a ^ b) | _ -> bug x)
  | Bytes_add ->
      pure (function [ VBytes a; VBytes b ] -> VBytes (a ^ b) | _ -> bug x)
  | Str_char_floor | Str_char_ceil ->
      pure (function
        | [ VStr s; VInt i ] -> int (char_bound ~ceil:(x = Str_char_ceil) s i)
        | _ -> bug x)
  | Str_code -> pure (function [ VStr s ] -> VInt (code s) | _ -> bug x)
  | Str_of_code -> pure (function [ VInt n ] -> VStr (of_code n) | _ -> bug x)
  (* the strings, [sep] between each two *)
  | Array_join ->
      pure (function
        | [ VArray xs; VStr sep ] ->
            VStr
              (String.concat sep
                 (List.init xs.len (fun i ->
                      match nth xs i with VStr s -> s | _ -> bug x)))
        | _ -> bug x)
  (* its UTF-8 *)
  | Str_bytes -> pure (function [ VStr s ] -> VBytes s | _ -> bug x)
  (* fails with `at`, where OCaml's decoder first finds an invalid
     character, and `incomplete`: whether that invalid decode runs to the
     end from a lead byte, C2 to F4, so the end cut a character off.
     Native builds find the same by their rescan (ren_rt.c, "UTF-8"). *)
  | Str_from_utf8 ->
      pure (function
        | [ VBytes b ] ->
            if String.is_valid_utf_8 b then VStr b
            else
              let n = String.length b in
              let rec bad i =
                let d = String.get_utf_8_uchar b i in
                if Uchar.utf_decode_is_valid d then bad (i + Uchar.utf_decode_length d)
                else (i, i + Uchar.utf_decode_length d = n && b.[i] >= '\xc2' && b.[i] <= '\xf4')
              in
              let at, incomplete = bad 0 in
              raise
                (Fail
                   (VTag
                      { name = "InvalidUtf8"; args = [ int at; VBool incomplete ]; tys = [ Ty.int; Ty.bool ] }))
        | _ -> bug x)
  (* U+FFFD for each maximal invalid subpart, as OCaml's decoder finds
     them (Unicode's "best practice") *)
  | Str_from_utf8_lossy ->
      pure (function
        | [ VBytes b ] ->
            if String.is_valid_utf_8 b then VStr b
            else
              let n = String.length b in
              let out = Buffer.create (n + 8) in
              let rec go i =
                if i < n then (
                  let d = String.get_utf_8_uchar b i in
                  Buffer.add_utf_8_uchar out (Uchar.utf_decode_uchar d);
                  go (i + Uchar.utf_decode_length d))
              in
              go 0;
              VStr (Buffer.contents out)
        | _ -> bug x)
  | Bytes_len ->
      pure (function [ VBytes b ] -> int (String.length b) | _ -> bug x)
  | Bytes_at ->
      pure (function
        | [ VBytes b; VInt i ] ->
            if i < 0L || i >= Int64.of_int (String.length b) then
              raise
                (Panic
                   (Printf.sprintf
                      "index %Ld is out of bounds for bytes of length %d" i
                      (String.length b)));
            int (Char.code b.[Int64.to_int i])
        | _ -> bug x)
  | Bytes_of ->
      pure (function
        | [ VArray v ] ->
            VBytes
              (String.init v.len (fun i ->
                   match nth v i with
                   | VInt n when n >= 0L && n <= 255L -> Char.chr (Int64.to_int n)
                   | VInt n ->
                       raise
                         (Panic (Printf.sprintf "%Ld isn't a byte, 0 to 255" n))
                   | _ -> bug x))
        | _ -> bug x)
  | Bytes_read a ->
      pure (function [ VBytes b; VInt at ] -> VInt (read_at a b at) | _ -> bug x)
  (* the ones that change their receiver, `inout` *)
  | Bytes_write a -> (
      function
      | [ VBytes b; (VInt at as i); (VInt n as v) ] ->
          (VUnit, [ VBytes (write_at a b at n); i; v ])
      | _ -> bug x)
  | Bytes_set_var signed -> (
      function
      | [ VBytes b; (VInt at as i); (VInt n as v) ] ->
          let b, k = write_var signed b at n in
          (int k, [ VBytes b; i; v ])
      | _ -> bug x)
  | Bytes_var_size signed ->
      pure (function [ VInt n ] -> int (var_size (var_bits signed n)) | _ -> bug x)
  | Bytes_zeros ->
      pure (function
        | [ VInt n ] ->
            if Int64.compare n 0L < 0 then
              raise
                (Panic (Printf.sprintf "`Bytes.zeros(%Ld)`: a length is 0 or more" n));
            VBytes (String.make (Int64.to_int n) '\000')
        | _ -> bug x)
  (* a value is its own here: the interpreter's slices are copies *)
  | Array_copy | Str_copy | Bytes_copy ->
      pure (function [ v ] -> v | _ -> bug x)
  (* lowering writes each call out (lower.ml, [split_at]) *)
  | Array_split_at | Str_split_at | Bytes_split_at | Pulled_count | Pulled_count_by -> bug x
  | Str_ascii_lower -> pure (function [ VStr s ] -> VStr (lower s) | _ -> bug x)
  | Bytes_ascii_lower ->
      pure (function [ VBytes s ] -> VBytes (lower s) | _ -> bug x)
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
