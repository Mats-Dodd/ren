(* The functions built into the compiler, because they can't be written in
   Ren yet: `show`, what the built-in dependencies' real implementations
   run on, and the built-in types' members, `Array.push`.

   Each is named by an id, a constructor of [t], never by a string, so a
   pass that finds one finds it with a [match], and the compiler checks
   that every pass handles every one. This is only the names: each one's
   type is the prelude's (prelude.ml), and what it does when it runs is the
   interpreter's (builtins.ml). It's a module of its own, depending
   only on paths, so the AST can name one too. *)

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

(* Its path in the prelude (path.ml): a function's, [show], or a built-in
   type's member's, [Array.push]. *)
let path x =
  let fn = Path.prelude and member t m = Path.member (Path.prelude t) m in
  match x with
  | Show -> fn "show"
  | Clock_now -> fn "clock_now"
  | Clock_instant -> fn "clock_instant"
  | Clock_sleep -> fn "clock_sleep"
  | Random_int -> fn "random_int"
  | Seeded_next -> fn "seeded_next"
  | Seeded_int -> fn "seeded_int"
  | Console_write -> fn "console_write"
  | Console_error -> fn "console_error"
  | Fs_read -> fn "fs_read"
  | Fs_write -> fn "fs_write"
  | Fs_exists -> fn "fs_exists"
  | Os_args -> fn "os_args"
  | Proc_run -> fn "proc_run"
  | Array_len -> member "Array" "len"
  | Array_push -> member "Array" "push"
  | Str_len -> member "Str" "len"
  | Str_slice -> member "Str" "slice"
  | Str_find -> member "Str" "find"
  | Str_split -> member "Str" "split"
  | Str_trim -> member "Str" "trim"
  | Str_starts_with -> member "Str" "starts_with"
  | Str_concat -> member "Str" "concat"
  | Str_bytes -> member "Str" "bytes"
  | Str_from_utf8 -> member "Str" "from_utf8"
  | Bytes_len -> member "Bytes" "len"

let name x = Path.local (path x)
let member_name x = Path.short (path x)
