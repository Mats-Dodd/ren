(* The functions built into the compiler, each named by an id (see
   intrinsic.ml). *)

(* A read or a write at an offset of layer 3: its width in bytes, 1, 2,
   4 or 8, whether it's signed, and whether it's big-endian (a byte's is
   [false]). *)
type access = { width : int; signed : bool; big : bool }

(* Every one: `u8`, `i8`, `u16_le`, `u16_be` ... `i64_be`. *)
val accesses : access list

(* Its name as a read: `u16_le`. *)
val access_name : access -> string

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
  | Bytes_read of access  (** `b.u32_le(at)`, which panics out of range *)
  | Bytes_write of access  (** `&b.set_u32_le(at, x)` *)
  | Bytes_zeros  (** `Bytes.zeros(n)` *)
  | Bytes_set_var of bool
      (** `&b.set_varint(at, x)` if [true], else `set_varuint`: how many
          bytes it wrote *)
  | Bytes_var_size of bool  (** `Bytes.varint_size(x)`, or `varuint_size` *)
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
      (** `x.hash()`, the derived hash a program can call: unseeded, the same
          on every run *)

(* Its path in the prelude: [show], or a built-in type's member,
   [Array.push]. *)
val path : t -> Path.t

(* The name its path has in the prelude, which messages and printed Core
   show: [show], or a built-in type's member after the type, [Array.push]. *)
val name : t -> string

(* Its name among its type's members, [push]; a function that isn't a
   member's is its [name]. *)
val member_name : t -> string

(* Whether it can wait for another task, a scheduling point: only the
   prelude's members and handlers whose rows have `Async` call one, which
   Core Lint checks. *)
val waits : t -> bool
