(* The functions built into the compiler, each named by an id (see
   intrinsic.ml). *)

(* One of them: [Array_push] is `Array.push`. *)
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
  | Float_of
  | Float_round
  | Float_truncate
  | Float_sqrt
  | Str_lower

(* Its path in the prelude: [show], or a built-in type's member,
   [Array.push]. *)
val path : t -> Path.t

(* The name its path has in the prelude, which messages and printed Core
   show: [show], or a built-in type's member after the type, [Array.push]. *)
val name : t -> string

(* Its name among its type's members, [push]; a function that isn't a
   member's is its [name]. *)
val member_name : t -> string
