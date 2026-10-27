(* The functions built into the compiler, because they can't be written in
   Ren yet: `show`, what the built-in dependencies' real implementations
   run on, what the journal's recorder and replayer run on, and the
   built-in types' members, `Array.push`.

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
  | Journal_kept
  | Journal_gave
  | Journal_answer
  | Journal_outputs
  | Journal_load
  | Array_len
  | Array_push
  | Array_sort
  | Map_empty
  | Map_of
  | Map_get
  | Map_set
  | Map_remove
  | Map_includes
  | Map_keys
  | Map_values
  | Map_len
  | Set_empty
  | Set_of
  | Set_add
  | Set_remove
  | Set_includes
  | Set_len
  | Str_len
  | Str_slice
  | Str_index
  | Str_split
  | Str_trim
  | Str_starts_with
  | Str_concat
  | Str_bytes
  | Str_from_utf8
  | Bytes_len
  | Int_wrapping_add
  | Int_wrapping_sub
  | Int_wrapping_mul
  | Int_wrapping_neg
  | Int_add
  | Int_sub
  | Int_mul
  | Int_div
  | Int_rem
  | Int_neg
  | Float_add
  | Float_sub
  | Float_mul
  | Float_div
  | Float_rem
  | Float_neg
  | Float_of
  | Float_round
  | Float_truncate
  | Float_sqrt
  | Str_lower

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
  | Journal_kept -> fn "journal_kept"
  | Journal_gave -> fn "journal_gave"
  | Journal_answer -> fn "journal_answer"
  | Journal_outputs -> fn "journal_outputs"
  | Journal_load -> fn "journal_load"
  | Array_len -> member "Array" "len"
  | Array_push -> member "Array" "push"
  | Array_sort -> member "Array" "sort"
  | Map_empty -> fn "map_empty"
  | Map_of -> member "Map" "of"
  | Map_get -> member "Map" "get"
  | Map_set -> member "Map" "set"
  | Map_remove -> member "Map" "remove"
  | Map_includes -> member "Map" "includes"
  | Map_keys -> member "Map" "keys"
  | Map_values -> member "Map" "values"
  | Map_len -> member "Map" "len"
  | Set_empty -> fn "set_empty"
  | Set_of -> member "Set" "of"
  | Set_add -> member "Set" "add"
  | Set_remove -> member "Set" "remove"
  | Set_includes -> member "Set" "includes"
  | Set_len -> member "Set" "len"
  | Str_len -> member "Str" "len"
  | Str_slice -> member "Str" "slice"
  | Str_index -> member "Str" "index"
  | Str_split -> member "Str" "split"
  | Str_trim -> member "Str" "trim"
  | Str_starts_with -> member "Str" "starts_with"
  | Str_concat -> member "Str" "concat"
  | Str_bytes -> member "Str" "bytes"
  | Str_from_utf8 -> member "Str" "from_utf8"
  | Bytes_len -> member "Bytes" "len"
  | Int_wrapping_add -> member "Int" "wrapping_add"
  | Int_wrapping_sub -> member "Int" "wrapping_sub"
  | Int_wrapping_mul -> member "Int" "wrapping_mul"
  | Int_wrapping_neg -> member "Int" "wrapping_neg"
  | Int_add -> member "Int" "add"
  | Int_sub -> member "Int" "sub"
  | Int_mul -> member "Int" "mul"
  | Int_div -> member "Int" "div"
  | Int_rem -> member "Int" "rem"
  | Int_neg -> member "Int" "neg"
  | Float_add -> member "Float" "add"
  | Float_sub -> member "Float" "sub"
  | Float_mul -> member "Float" "mul"
  | Float_div -> member "Float" "div"
  | Float_rem -> member "Float" "rem"
  | Float_neg -> member "Float" "neg"
  | Float_of -> member "Float" "of"
  | Float_round -> member "Float" "round"
  | Float_truncate -> member "Float" "truncate"
  | Float_sqrt -> member "Float" "sqrt"
  | Str_lower -> member "Str" "lower"

let name x = Path.local (path x)
let member_name x = Path.short (path x)
