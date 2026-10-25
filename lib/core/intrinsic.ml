(* The functions built into the compiler, because they can't be written in
   Ren yet: `show`, what the built-in dependencies' real implementations
   run on, and the built-in types' members, `Array.push`.

   Each is named by an id, a constructor of [t], never by a string, so a
   pass that finds one finds it with a [match], and the compiler checks
   that every pass handles every one. This is only the names: each one's
   type is the prelude's (prelude.ml), and what it does when it runs is the
   interpreter's (builtins.ml). It's a module of its own, depending on
   nothing, so the AST can name one too. *)

type t =
  | Show
  | Clock_now
  | Clock_instant
  | Clock_sleep
  | Random_int
  | Seeded_next
  | Seeded_int
  | Console_write
  | Console_error
  | Fs_read
  | Fs_write
  | Fs_exists
  | Os_args
  | Proc_run
  | Array_len
  | Array_push
  | Str_len
  | Str_slice
  | Str_find
  | Str_split
  | Str_trim
  | Str_starts_with
  | Str_concat
  | Str_bytes
  | Str_from_utf8
  | Bytes_len

let name = function
  | Show -> "show"
  | Clock_now -> "clock_now"
  | Clock_instant -> "clock_instant"
  | Clock_sleep -> "clock_sleep"
  | Random_int -> "random_int"
  | Seeded_next -> "seeded_next"
  | Seeded_int -> "seeded_int"
  | Console_write -> "console_write"
  | Console_error -> "console_error"
  | Fs_read -> "fs_read"
  | Fs_write -> "fs_write"
  | Fs_exists -> "fs_exists"
  | Os_args -> "os_args"
  | Proc_run -> "proc_run"
  | Array_len -> "Array.len"
  | Array_push -> "Array.push"
  | Str_len -> "Str.len"
  | Str_slice -> "Str.slice"
  | Str_find -> "Str.find"
  | Str_split -> "Str.split"
  | Str_trim -> "Str.trim"
  | Str_starts_with -> "Str.starts_with"
  | Str_concat -> "Str.concat"
  | Str_bytes -> "Str.bytes"
  | Str_from_utf8 -> "Str.from_utf8"
  | Bytes_len -> "Bytes.len"

(* what's after the type's name and its `.` *)
let member_name x =
  let n = name x in
  match String.index_opt n '.' with
  | Some i -> String.sub n (i + 1) (String.length n - i - 1)
  | None -> n
