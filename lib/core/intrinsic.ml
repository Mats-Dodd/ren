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

(* A read or a write at an offset of layer 3 (formats.md, "Layer 3: raw
   bytes"; compiler.md, "Bytes stage", "Layer 3: the API"): its [width]
   in bytes, 1, 2, 4 or 8, whether it's [signed], and whether its bytes
   are the most significant first ([big], `be`) or the least (`le`). A
   byte has no order: its [big] is [false]. *)
type access = { width : int; signed : bool; big : bool }

(* Every one, unsigned before signed, `le` before `be`, by width: what
   `Bytes` has, `u8` to `i64_be`. *)
let accesses =
  List.concat_map
    (fun width ->
      List.concat_map
        (fun signed ->
          if width = 1 then [ { width; signed; big = false } ]
          else [ { width; signed; big = false }; { width; signed; big = true } ])
        [ false; true ])
    [ 1; 2; 4; 8 ]

(* Its name, as a read's: `u8`, `i16_le`, `u64_be`. *)
let access_name a =
  Printf.sprintf "%s%d%s"
    (if a.signed then "i" else "u")
    (a.width * 8)
    (if a.width = 1 then "" else if a.big then "_be" else "_le")

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
  | Net_listen
  | Net_accept
  | Net_accept_until
  | Net_read
  | Net_write
  | Net_close
  | Journal_kept
  | Journal_gave
  | Journal_answer
  | Journal_outputs
  | Journal_load
  | Array_len
  | Array_push
  | Array_sort
  | Array_reserve
  | Map_into
  | Unsafe_cast
  | Float_lanes
  | Float_sum
  | Lib_panic
  | Scope_run
  | Task_spawn
  | Task_start
  | Task_replace
  | Task_join
  | Task_cancel
  | Task_until
  | Arm_release
  | Arm_retake
  | Task_timeout
  | Task_isolate
  | Task_map
  | Task_each
  | Task_both
  | Task_race
  | Task_beside
  | Task_background
  | Background_spawn
  | Task_produce
  | Task_map_pull
  | Outbox_send
  | Inbox_take
  | Async_yield
  | Async_tick
  | Runtime_single
  | Runtime_sim
  | Runtime_leave
  | Sim_time
  | Sim_sleep
  | Sim_advance
  | Sim_alarm
  | Sync_keyed
  | Async_worker
  | Family_open
  | Family_call
  | Family_make
  | Family_keys
  | Family_evict
  | Family_evictable
  | Family_counts
  | Family_close
  | Call_first_hash
  | Call_add
  | Call_max
  | Call_min
  | Call_concat
  | Call_fold
  | Call_operations
  | Task_random
  | Task_drain
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
  | Str_byte_len
  | Str_index
  | Str_split
  | Str_trim
  | Str_starts_with
  | Str_add
  | Str_bytes
  | Str_from_utf8
  | Str_from_utf8_lossy
  | Bytes_len
  | Bytes_at
  | Bytes_of
  | Bytes_read of access
  | Bytes_write of access
  | Bytes_zeros
  | Bytes_set_var of bool
  | Bytes_var_size of bool
  | Array_copy
  | Str_copy
  | Bytes_copy
  | Array_split_at
  | Str_split_at
  | Bytes_split_at
  | Int_wrapping_add
  | Int_wrapping_sub
  | Int_wrapping_mul
  | Int_wrapping_neg
  | Int_xor
  | Int_bit_and
  | Int_bit_or
  | Int_shl
  | Int_shr
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
  | Str_ascii_lower
  | Bytes_ascii_lower
  | Bytes_add
  | Str_char_floor
  | Str_char_ceil
  | Str_code
  | Str_of_code
  | Array_join
  | Hash

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
  | Net_listen -> fn "net_listen"
  | Net_accept -> fn "net_accept"
  | Net_accept_until -> fn "net_accept_until"
  | Net_read -> fn "net_read"
  | Net_write -> fn "net_write"
  | Net_close -> fn "net_close"
  | Journal_kept -> fn "journal_kept"
  | Journal_gave -> fn "journal_gave"
  | Journal_answer -> fn "journal_answer"
  | Journal_outputs -> fn "journal_outputs"
  | Journal_load -> fn "journal_load"
  | Array_len -> member "Array" "len"
  | Array_push -> member "Array" "push"
  | Array_sort -> member "Array" "sort"
  | Array_reserve -> fn "array_reserve"
  | Map_into -> fn "map_into"
  | Unsafe_cast -> fn "unsafe_cast"
  | Float_lanes -> fn "float_lanes"
  | Float_sum -> fn "float_sum"
  | Lib_panic -> fn "lib_panic"
  | Scope_run -> fn "scope_run"
  | Task_spawn -> fn "task_spawn"
  | Task_start -> fn "task_start"
  | Task_replace -> fn "task_replace"
  | Task_join -> fn "task_join"
  | Task_cancel -> fn "task_cancel"
  | Task_until -> fn "task_until"
  | Arm_release -> fn "arm_release"
  | Arm_retake -> fn "arm_retake"
  | Task_timeout -> fn "task_timeout"
  | Task_isolate -> fn "task_isolate"
  | Task_map -> fn "task_map"
  | Task_each -> fn "task_each"
  | Task_both -> fn "task_both"
  | Task_race -> fn "task_race"
  | Task_beside -> fn "task_beside"
  | Task_background -> fn "task_background"
  | Background_spawn -> member "Background" "spawn"
  | Task_produce -> fn "task_produce"
  | Task_map_pull -> fn "task_map_pull"
  | Outbox_send -> fn "outbox_send"
  | Inbox_take -> fn "inbox_take"
  | Async_yield -> fn "async_yield"
  | Async_tick -> fn "async_tick"
  | Runtime_single -> fn "runtime_single"
  | Runtime_sim -> fn "runtime_sim"
  | Runtime_leave -> fn "runtime_leave"
  | Sim_time -> fn "sim_time"
  | Sim_sleep -> fn "sim_sleep"
  | Sim_advance -> fn "sim_advance"
  | Sim_alarm -> fn "sim_alarm"
  | Sync_keyed -> fn "sync_keyed"
  | Async_worker -> fn "async_worker"
  | Family_open -> fn "family_open"
  | Family_call -> fn "family_call"
  | Family_make -> fn "family_make"
  | Family_keys -> fn "family_keys"
  | Family_evict -> fn "family_evict"
  | Family_evictable -> fn "family_evictable"
  | Family_counts -> fn "family_counts"
  | Family_close -> fn "family_close"
  | Call_first_hash -> fn "call_first_hash"
  | Call_add -> fn "call_add"
  | Call_max -> fn "call_max"
  | Call_min -> fn "call_min"
  | Call_concat -> fn "call_concat"
  | Call_fold -> fn "call_fold"
  | Call_operations -> fn "call_operations"
  | Task_random -> fn "task_random"
  | Task_drain -> fn "task_drain"
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
  | Str_byte_len -> member "Str" "byte_len"
  | Str_index -> member "Str" "index"
  | Str_split -> member "Str" "split"
  | Str_trim -> member "Str" "trim"
  | Str_starts_with -> member "Str" "starts_with"
  | Str_add -> member "Str" "add"
  | Str_bytes -> member "Str" "bytes"
  | Str_from_utf8 -> member "Str" "from_utf8"
  | Str_from_utf8_lossy -> member "Str" "from_utf8_lossy"
  | Bytes_len -> member "Bytes" "len"
  | Bytes_at -> member "Bytes" "at"
  | Bytes_of -> member "Bytes" "of"
  | Bytes_read a -> member "Bytes" (access_name a)
  | Bytes_write a -> member "Bytes" ("set_" ^ access_name a)
  | Bytes_zeros -> member "Bytes" "zeros"
  (* [true] for `VarInt`, zigzag, and [false] for `VarUInt` *)
  | Bytes_set_var signed -> member "Bytes" (if signed then "set_varint" else "set_varuint")
  | Bytes_var_size signed ->
      member "Bytes" (if signed then "varint_size" else "varuint_size")
  | Array_copy -> member "Array" "copy"
  | Str_copy -> member "Str" "copy"
  | Bytes_copy -> member "Bytes" "copy"
  | Array_split_at -> member "Array" "split_at"
  | Str_split_at -> member "Str" "split_at"
  | Bytes_split_at -> member "Bytes" "split_at"
  | Int_wrapping_add -> member "Int" "wrapping_add"
  | Int_wrapping_sub -> member "Int" "wrapping_sub"
  | Int_wrapping_mul -> member "Int" "wrapping_mul"
  | Int_wrapping_neg -> member "Int" "wrapping_neg"
  | Int_xor -> member "Int" "xor"
  | Int_bit_and -> member "Int" "bit_and"
  | Int_bit_or -> member "Int" "bit_or"
  | Int_shl -> member "Int" "shl"
  | Int_shr -> member "Int" "shr"
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
  | Str_ascii_lower -> member "Str" "ascii_lower"
  | Bytes_ascii_lower -> member "Bytes" "ascii_lower"
  | Bytes_add -> member "Bytes" "add"
  | Str_char_floor -> member "Str" "char_floor"
  | Str_char_ceil -> member "Str" "char_ceil"
  | Str_code -> member "Str" "code"
  | Str_of_code -> member "Str" "of_code"
  | Array_join -> member "Array" "join"
  (* `x.hash()` on a value of any type with `hash`, which the checker finds
     for a type with no `hash` of its own (compiler.md, "Bytes stage") *)
  | Hash -> fn "hash_of"

let name x = Path.local (path x)
let member_name x = Path.short (path x)

(* Whether it can wait for another task: a scheduling point, which only
   code that uses `Async` reaches (compiler.md, "Stage 11a", "The two
   holes"). `task_cancel` returns at once, but asks the
   scheduler, as the rest do. The world's waits, `Clock.sleep`, `Net`'s
   and `Proc.run`, aren't these: only the runtime installs the world. *)
let waits = function
  | Scope_run | Task_spawn | Task_start | Task_replace | Task_join
  | Task_cancel | Task_until | Task_timeout | Task_isolate | Task_map
  | Task_each | Task_both | Task_race | Task_beside | Task_background
  | Task_produce | Task_map_pull | Outbox_send | Inbox_take
  | Async_yield | Async_tick | Sim_sleep | Family_call | Family_make | Family_evict
  | Family_close ->
      true
  | _ -> false
