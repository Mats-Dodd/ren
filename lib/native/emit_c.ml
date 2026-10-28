(* Mem IR to C: one file, the runtime (ren_rt.h and ren_rt.c, embedded
   as Runtime_c) first, then the program (compiler.md, "Native slice").

   Each Mem function is a C function, and each variable a C local. A
   function that can fail returns its error, or NULL, and writes its
   value through a last parameter, [ren_out]. Control that isn't an `if`
   or a `switch` is a `goto`: a [Break] to the end of its loop, a [Raise]
   to its [Catch]'s handler, and a [Jump] to a join point, so none of
   them depends on which C statement it's inside.

   A block's code, and a handler's, is a C function with the signature
   every caller of one uses, [ren_code] and [ren_hcode] (ren_rt.h), whose
   arguments and value go as words. The program's descriptors and its
   types' declarations are static data, written before its functions. *)

open Mem

let sprintf = Printf.sprintf

module Ids = Set.Make (Int)

(* A sized type's C type, the suffix of the runtime's functions on it,
   and its [REN_ELEM_] kind (ren_rt.h). A `UInt64` is an [int64_t], since
   it holds only what an `Int` can that isn't negative (sized.ml). *)
let sized_ctype (k : Sized.t) =
  match k with
  | I8 -> "int8_t"
  | U8 -> "uint8_t"
  | I16 -> "int16_t"
  | U16 -> "uint16_t"
  | I32 -> "int32_t"
  | U32 -> "uint32_t"
  | U64 -> "int64_t"
  | F32 -> "float"

let sized_suffix (k : Sized.t) =
  match k with
  | I8 -> "i8"
  | U8 -> "u8"
  | I16 -> "i16"
  | U16 -> "u16"
  | I32 -> "i32"
  | U32 -> "u32"
  | U64 -> "u64"
  | F32 -> "f32"

let sized_kind k = "REN_ELEM_" ^ String.uppercase_ascii (sized_suffix k)

let rec ctype (l : layout) =
  match l with
  | Int -> "int64_t"
  | Float -> "double"
  | Bool -> "bool"
  | Unit -> "ren_unit"
  | Enum -> "uint32_t"
  | Boxed | Desc | Token -> "ren_obj*"
  | Cell l -> ctype l ^ "*"
  | Word _ -> "ren_val"
  | Ev -> "const ren_ev*"
  | Block -> "ren_block"
  | Ptr -> "void*"
  | Struct (n, _) -> sprintf "ren_struct_%d" n
  | Sized k -> sized_ctype k

let zero (l : layout) =
  match l with
  | Int | Unit | Enum | Sized _ -> "0"
  | Float -> "0.0"
  | Bool -> "false"
  | Boxed | Desc | Cell _ | Ev | Ptr | Token -> "NULL"
  | Word _ -> "(ren_val){0}"
  | Block -> "(ren_block){0}"
  | Struct (n, _) -> sprintf "(ren_struct_%d){0}" n

(* [s] as a C string literal: a byte that isn't printable ASCII as an
   octal escape, and `?` escaped, so nothing reads as a trigraph. *)
let c_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '?' -> Buffer.add_string b "\\?"
      | '\n' -> Buffer.add_string b "\\n"
      | ' ' .. '~' -> Buffer.add_char b c
      | c -> Buffer.add_string b (sprintf "\\%03o" (Char.code c)))
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* The variables of the function a loop is moved out of that the loop
   changes, which it's given the address of: [var] writes each as what
   its address points to. *)
let by_address : (int, unit) Hashtbl.t = Hashtbl.create 16

let c_name (v : var) =
  let name =
    String.concat ""
      (List.map (String.make 1)
         (List.filter
            (function
              | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
            (List.of_seq (String.to_seq v.name))))
  in
  sprintf "v%d_%s" v.id name

let var (v : var) =
  if Hashtbl.mem by_address v.id then "(*" ^ c_name v ^ ")" else c_name v

let atom_layout (x : atom) : layout =
  match x with
  | Var v -> v.layout
  | Int _ -> Int
  | Float _ -> Float
  | Bool _ -> Bool
  | Unit -> Unit
  | Enum_tag _ -> Enum
  | Scalar_ctor _ | Lit _ -> Boxed
  | Desc_lit _ -> Desc
  | Fn_ptr _ -> Ptr
  | No_ev -> Ev

let atom (x : atom) =
  match x with
  | Var v -> var v
  | Int n when n = Int64.min_int -> "INT64_MIN"
  | Int n -> sprintf "INT64_C(%Ld)" n
  | Float f when f = Float.infinity -> "INFINITY"
  | Float f when f = Float.neg_infinity -> "(-INFINITY)"
  (* hexadecimal, which C reads back exactly *)
  | Float f -> sprintf "%h" f
  | Bool b -> if b then "true" else "false"
  | Unit -> "((ren_unit)0)"
  | Enum_tag t -> sprintf "((uint32_t)%d)" t
  (* a [Nullable] struct's first constructor: a tag no type has *)
  | Scalar_ctor t when t < 0 -> "ren_box(UINT32_MAX)"
  | Scalar_ctor t -> sprintf "ren_box(%d)" t
  | Lit n -> sprintf "((ren_obj*)&ren_lit_%d)" n
  | Desc_lit n -> sprintf "((ren_obj*)&ren_desc_%d)" n
  | Fn_ptr f -> sprintf "((void*)%s)" f
  | No_ev -> "((const ren_ev*)NULL)"

let bug what = failwith ("bug: emit_c: " ^ what)

(* [c], a C expression of a value of [l], as a [ren_val], a word. *)
let word_of (l : layout) c =
  match l with
  | Word _ -> c
  | Float -> sprintf "(ren_val){.f = %s}" c
  | Boxed | Desc -> sprintf "(ren_val){.o = %s}" c
  | Ptr | Ev -> sprintf "(ren_val){.p = (void*)%s}" c
  | Int | Bool | Unit | Enum -> sprintf "(ren_val){.i = (int64_t)%s}" c
  (* a sized type's value as a word is the number it is *)
  | Sized F32 -> sprintf "(ren_val){.f = (double)%s}" c
  | Sized _ -> sprintf "(ren_val){.i = (int64_t)%s}" c
  | Block | Cell _ | Token | Struct _ ->
      bug "a block, a cell, a token or a struct as a word"

let to_val (x : atom) = word_of (atom_layout x) (atom x)

(* A [ren_val], [v], as a value of [l]. *)
let of_val l v =
  match (l : layout) with
  | Word _ -> v
  | Float -> sprintf "%s.f" v
  | Boxed | Desc -> sprintf "%s.o" v
  | Ptr -> sprintf "%s.p" v
  | Ev -> sprintf "((const ren_ev*)%s.p)" v
  | Int -> sprintf "%s.i" v
  | Bool | Unit | Enum -> sprintf "(%s)%s.i" (ctype l) v
  | Sized F32 -> sprintf "((float)%s.f)" v
  | Sized k -> sprintf "((%s)%s.i)" (sized_ctype k) v
  | Block | Cell _ | Token | Struct _ ->
      bug "a word as a block, a cell, a token or a struct"

(* Each site's C name's number, by its [sid]: one site for all those
   whose pieces are the same, set by [program]. *)
let site_names : (int, int) Hashtbl.t = Hashtbl.create 64

let site (s : site) =
  if s.kind = Caller then "ren_here"
  else
    sprintf "&ren_site_%d"
      (Option.value (Hashtbl.find_opt site_names s.sid) ~default:s.sid)

(* Whether this is a release build, set by [program]: it tags no NaN. *)
let is_release = ref false

(* A debug build's tags of where NaNs are made (nan.ml), each place's
   number, from 1, which [ren_nan_where] says the place of. *)
let made_tags : (string, int) Hashtbl.t = Hashtbl.create 16

(* The tag a NaN made at [s] gets: 0, none, in a release build. *)
let tag (s : site) =
  match s.made with
  | Some w when not !is_release -> (
      match Hashtbl.find_opt made_tags w with
      | Some n -> string_of_int n
      | None ->
          let n = Hashtbl.length made_tags + 1 in
          if n > Nan.max_tag then "0"
          else (
            Hashtbl.replace made_tags w n;
            string_of_int n))
  | _ -> "0"

(* The program's structs, by number: set by [program], for the C it
   writes. *)
let structs : strukt array ref = ref [||]
let struct_words n = max 1 (List.length !structs.(n).sfields)

(* The slots of a value [x] of a counted struct that hold objects, but
   those in [kept]: what counting it counts (Koka's [genDupDropValue],
   Backend/C/FromCore.hs:1048). A slot of a constructor without a field
   there holds a scalar, which [ren_dup] and [ren_drop] skip. *)
let struct_objects ?(kept = []) (l : layout) c =
  match l with
  | Struct (n, true) ->
      List.filter_map
        (fun (i, l) ->
          if is_object l && not (List.mem_assoc i kept) then
            Some (sprintf "%s.s[%d].o" c i)
          else None)
        (List.mapi (fun i l -> (i, l)) !structs.(n).sfields)
  | _ -> bug "a struct counted that holds no object"

let is_struct (x : atom) =
  match atom_layout x with Struct _ -> true | _ -> false

(* The variables of the function being written whose objects are in its
   frame (stack.ml, [Mem.fn.stack]): set by [fn]. *)
let in_frame : int list ref = ref []

let framed (x : atom) =
  match x with Var v -> List.mem v.id !in_frame | _ -> false

(* In a function's version that builds its result in its caller's frame,
   the variables whose [Alloc]s are built there, through [ren_slot]. *)
let in_slot : int list ref = ref []

(* The functions that have such a version, with how many fields what
   they build there has: set by [program]. *)
let slot_sizes : (string, int) Hashtbl.t = Hashtbl.create 16

(* The C name of a function's version that builds its result in its
   caller's frame. *)
let slot_fn name = name ^ "_frame"

(* The words after the header an object of [n] fields takes in a frame:
   its fields, and the mask's word past eight (ren_rt.h, [ren_ctor_size]). *)
let frame_words n = n + if n > 8 then 1 else 0

(* A call of [fn] whose result [r] is in this frame: to the version of
   [fn] that builds it there, given the memory. *)
let into_frame (r : var) fn =
  if List.mem r.id !in_frame && Hashtbl.mem slot_sizes fn then
    Some (slot_fn fn, sprintf "&%s_frame.h" (var r))
  else None

let binop_fn (op : Ast.binop) (l : layout) =
  let name =
    match op with
    | Add -> "add"
    | Sub -> "sub"
    | Mul -> "mul"
    | Div -> "div"
    | Mod -> "rem"
    | _ -> bug "an arithmetic operator that isn't one"
  in
  match l with Float -> "ren_f" ^ name | _ -> "ren_" ^ name

let cmp_op = function
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="

(* The suffix of the runtime's array functions for elements of [l]:
   [_s] if they're never counted. *)
let uncounted (l : layout) =
  match l with
  | Int | Float | Bool | Unit | Enum -> "_s"
  | Word _ -> "_w"
  | _ -> ""

(* The suffix of the buffer functions for elements of [l]: [_o] for
   objects, which are counted, [_s] for scalars. *)
let buf_suffix (l : layout) =
  match l with
  | Int | Float | Bool | Unit | Enum -> "_s"
  | Boxed | Desc -> "_o"
  | _ -> bug "a buffer of words"

let runtime rt args site_arg =
  let a i = atom (List.nth args i) in
  let site () =
    match site_arg with
    | Some s -> site s
    | None -> bug "a runtime call that panics without a site"
  in
  (* an index's: none for one bounds.ml proved in bounds, which the
     runtime then doesn't check ([ren_array_check]) *)
  let isite () = if site_arg = None then "REN_IN_BOUNDS" else site () in
  match rt with
  | Array_len -> sprintf "ren_array_len(%s)" (a 0)
  (* an array of structs: each element its words, a stride the C knows *)
  | Array_get (Struct (n, _)) ->
      sprintf "(*(ren_struct_%d*)ren_array_slots_k(%s, %s, %d, %s))" n (a 0)
        (a 1) (struct_words n) (isite ())
  | Array_set (Struct _) ->
      sprintf "ren_array_set_slots(%s, %s, %s.s, %s)" (a 0) (a 1) (a 2)
        (isite ())
  | Array_push (Struct _) ->
      sprintf "ren_array_push_slots(%s, %s.s)" (a 0) (a 1)
  | Array_set_taking (Struct (n, _)) ->
      sprintf "ren_array_set_slots_taking_k(%s, %s, %s.s, %d, %s)" (a 0) (a 1)
        (a 2) (struct_words n) (isite ())
  | Array_push_taking (Struct _) ->
      sprintf "ren_array_push_slots_taking(%s, %s.s)" (a 0) (a 1)
  (* an array of a sized type's elements, at its width: read and written
     in place directly, and copied, which is rarer, through the words *)
  | Array_get (Sized k) | Array_take (Sized k) ->
      sprintf "ren_array_get_%s(%s, %s, %s)" (sized_suffix k) (a 0) (a 1)
        (isite ())
  | Array_set_taking (Sized k) ->
      sprintf "ren_array_set_taking_%s(%s, %s, %s, %s)" (sized_suffix k) (a 0)
        (a 1) (a 2) (isite ())
  | Array_set (Sized _) ->
      sprintf "ren_array_set_w(%s, %s, %s, %s)" (a 0) (a 1)
        (to_val (List.nth args 2))
        (isite ())
  | Array_push (Sized _) ->
      sprintf "ren_array_push_w(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Array_push_taking (Sized _) ->
      sprintf "ren_array_push_taking_w(%s, %s)" (a 0) (to_val (List.nth args 1))
  (* a type variable's elements, which may be a sized type's: the array
     says ([_w]) *)
  | Array_set (Word _) ->
      sprintf "ren_array_set_w(%s, %s, %s, %s)" (a 0) (a 1)
        (to_val (List.nth args 2))
        (isite ())
  | Array_push (Word _) ->
      sprintf "ren_array_push_w(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Array_push_taking (Word _) ->
      sprintf "ren_array_push_taking_w(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Array_take (Word _ as l) ->
      of_val l (sprintf "ren_array_take_w(%s, %s, %s)" (a 0) (a 1) (isite ()))
  (* elements never counted skip the check of whether they are *)
  | Array_get l ->
      of_val l
        (sprintf "ren_array_get%s(%s, %s, %s)" (uncounted l) (a 0) (a 1)
           (isite ()))
  | Array_set _ ->
      sprintf "ren_array_set(%s, %s, %s, %s)" (a 0) (a 1)
        (to_val (List.nth args 2))
        (isite ())
  | Array_push _ ->
      sprintf "ren_array_push(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Array_set_taking l ->
      sprintf "ren_array_set_taking%s(%s, %s, %s, %s)" (uncounted l) (a 0) (a 1)
        (to_val (List.nth args 2))
        (isite ())
  | Array_push_taking _ ->
      sprintf "ren_array_push_taking(%s, %s)" (a 0) (to_val (List.nth args 1))
  (* an element moved out, if the array is unique (swap.ml): of objects
     or a [Word]'s, whose array says whether they're counted *)
  | Array_take l ->
      of_val l
        (sprintf "ren_array_take(%s, %s, %s)" (a 0) (a 1) (isite ()))
  | Array_check -> sprintf "ren_array_check(%s, %s, %s)" (a 0) (a 1) (site ())
  | Array_set_field (n, k, _) ->
      sprintf "ren_array_set_field(%s, %s, %d, %d, %s, %s)" (a 0) (a 1) k
        (struct_words n)
        (to_val (List.nth args 2))
        (isite ())
  | Array_set_field_taking (n, k, _) ->
      sprintf "ren_array_set_field_taking(%s, %s, %d, %d, %s, %s)" (a 0) (a 1) k
        (struct_words n)
        (to_val (List.nth args 2))
        (isite ())
  | Array_own -> sprintf "ren_array_own(%s)" (a 0)
  | Array_data -> sprintf "((void*)ren_elems(%s))" (a 0)
  (* a buffer hoist.ml found: never of [Word]s, so whether its elements
     are counted is the layout's *)
  | Buf_get (Struct (n, _)) ->
      sprintf "(*(ren_struct_%d*)ren_buf_slots(%s, %s, %s, %d, %s))" n (a 0)
        (a 1) (a 2) (struct_words n) (isite ())
  | Buf_get (Sized k) ->
      sprintf "ren_buf_get_n(%s, %s, %s, %s, %s)" (sized_ctype k) (a 0) (a 1)
        (a 2) (isite ())
  | Buf_set (Sized k) ->
      sprintf "ren_buf_set_n(%s, %s, %s, %s, %s, %s)" (sized_ctype k) (a 0)
        (a 1) (a 2) (a 3) (isite ())
  | Buf_get l ->
      of_val l
        (sprintf "ren_buf_get%s(%s, %s, %s, %s)" (buf_suffix l) (a 0) (a 1)
           (a 2) (isite ()))
  | Buf_set (Struct (n, _)) ->
      sprintf "ren_buf_set_slots(%s, %s, %s, %s.s, %d, %s)" (a 0) (a 1) (a 2)
        (a 3) (struct_words n) (isite ())
  | Buf_set l ->
      sprintf "ren_buf_set%s(%s, %s, %s, %s, %s)" (buf_suffix l) (a 0) (a 1)
        (a 2)
        (to_val (List.nth args 3))
        (isite ())
  | Buf_set_field (n, k, _) ->
      sprintf "ren_buf_set_field(%s, %s, %s, %d, %d, %s, %s)" (a 0) (a 1) (a 2)
        k (struct_words n)
        (to_val (List.nth args 3))
        (isite ())
  | Buf_take l ->
      of_val l
        (sprintf "ren_buf_take_o(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (isite ()))
  | Buf_check -> sprintf "ren_buf_check(%s, %s, %s)" (a 0) (a 1) (site ())
  | Array_reserve (Struct (n, _)) ->
      sprintf "ren_array_reserve(%s, false, %d)" (a 0) (struct_words n)
  | Array_reserve (Word _) -> sprintf "ren_array_reserve_d(%s, %s)" (a 0) (a 1)
  | Array_reserve (Sized k) ->
      sprintf "ren_array_reserve_k(%s, %s)" (a 0) (sized_kind k)
  | Array_reserve l ->
      sprintf "ren_array_reserve(%s, %b, 0)" (a 0) (is_object l)
  | Str_len -> sprintf "ren_str_len(%s)" (a 0)
  | Str_concat -> sprintf "ren_str_concat(%s, %s)" (a 0) (a 1)
  | Str_eq -> sprintf "ren_str_eq(%s, %s)" (a 0) (a 1)
  | Show_int -> sprintf "ren_show_int(%s)" (a 0)
  | Show_float -> sprintf "ren_show_float(%s, %s)" (a 0) (site ())
  | Show_bool -> sprintf "ren_show_bool(%s)" (a 0)
  | Float_of_int -> sprintf "((double)%s)" (a 0)
  | Float_sqrt -> (
      match site_arg with
      | Some s when not !is_release -> sprintf "ren_fsqrt_d(%s, %s)" (a 0) (tag s)
      | _ -> sprintf "sqrt(%s)" (a 0))
  | Float_round -> sprintf "ren_fround(%s, %s)" (a 0) (site ())
  | Float_truncate -> sprintf "ren_ftruncate(%s, %s)" (a 0) (site ())
  | Wrapping op ->
      let o = match op with Add -> "+" | Sub -> "-" | _ -> "*" in
      sprintf "((int64_t)((uint64_t)%s %s (uint64_t)%s))" (a 0) o (a 1)
  | Wrapping_neg -> sprintf "((int64_t)(0 - (uint64_t)%s))" (a 0)
  | Bits x ->
      let o =
        match x with
        | Int_xor -> "^"
        | Int_bit_and -> "&"
        | Int_bit_or -> "|"
        | _ -> bug "a bitwise operation that isn't one"
      in
      sprintf "(%s %s %s)" (a 0) o (a 1)
  | Widen -> (
      match atom_layout (List.hd args) with
      | Sized F32 -> sprintf "((double)%s)" (a 0)
      | Sized _ -> sprintf "((int64_t)%s)" (a 0)
      | _ -> bug "a widening of what isn't sized")
  | Narrow k -> sprintf "ren_narrow_%s(%s, %s)" (sized_suffix k) (a 0) (site ())
  (* the low bits: converting to an unsigned type is modulo 2^bits in C,
     and to a signed one, from there, keeps the bits (C11 6.3.1.3, which
     GCC and Clang define so) *)
  | Wrap_to k ->
      sprintf "((%s)(uint%d_t)(uint64_t)%s)" (sized_ctype k) (Sized.bits k)
        (a 0)
  | Console_write -> sprintf "ren_console_write(%s)" (a 0)
  | Console_error -> sprintf "ren_console_error(%s)" (a 0)
  | Show_any -> sprintf "ren_show_any(%s, %s, %s)" (a 0) (a 1) (site ())
  | Equal_any what ->
      sprintf "ren_equal_any(%s, %s, %s, %s, %s)" (a 0) (a 1) (a 2)
        (c_string what) (site ())
  | Compare_any what ->
      sprintf "ren_compare_any(%s, %s, %s, %s, %s)" (a 0) (a 1) (a 2)
        (c_string what) (site ())
  | Nan_check what ->
      let y = if List.length args > 1 then a 1 else a 0 in
      sprintf "ren_nan_check(%s, %s, %s, %s)" (a 0) y (c_string what) (site ())
  | Nan_check_any what ->
      sprintf "ren_nan_in(%s, %s, %s, %s)" (a 0) (a 1) (c_string what) (site ())
  | Float_lanes -> sprintf "ren_desc_is_float(%s)" (a 0)
  | Float_sum ->
      let t = match site_arg with Some s -> tag s | None -> "0" in
      sprintf "ren_float_sum(%s, %s)" (a 0) t
  | Late_check -> "ren_late_check()"
  | Here_set -> sprintf "(void)(ren_here = %s)" (site ())
  | Here_get -> "(void *)ren_here"
  | Here_put -> sprintf "(void)(ren_here = (const ren_site *)%s)" (a 0)
  | Late_tick -> sprintf "ren_late_tick(%s)" (a 0)
  | Op_any op ->
      let code =
        match op with
        | Some Add -> "REN_OP_ADD"
        | Some Sub -> "REN_OP_SUB"
        | Some Mul -> "REN_OP_MUL"
        | Some Div -> "REN_OP_DIV"
        | Some Mod -> "REN_OP_REM"
        | None -> "REN_OP_NEG"
        | Some _ -> bug "an operator through a dictionary that isn't one"
      in
      let b = if op = None then "(ren_val){0}" else a 2 in
      let t = match site_arg with Some s -> tag s | None -> "0" in
      sprintf "ren_op_any(%s, %s, %s, %s, %s, %s)" (a 0) code (a 1) b (site ()) t
  | Value_any one -> sprintf "ren_value_any(%s, %b)" (a 0) one
  | New_desc _ -> bug "a descriptor built outside a Let"

(* Whether the runtime's [rt] gives nothing, so a [Let] of it gives [Unit]
   after calling it. *)
let gives_nothing = function
  | Array_push _ | Array_push_taking _ | Console_write | Console_error
  | Array_check | Buf_set _ | Buf_set_field _ | Buf_check | Nan_check _
  | Nan_check_any _ | Late_check | Here_set | Here_put ->
      true
  | _ -> false

(* Field [n]'s bit in a constructor's mask of them (ren_rt.h,
   [ren_ctor_objs]), which has 64. *)
let bit n =
  if n >= 64 then bug "a field past the 64th";
  sprintf "((uint64_t)1 << %d)" n

(* The slots a [Free] or a [Reset] keeps, as a mask of bits. *)
let mask kept =
  match kept with
  | [] -> "0u"
  | _ -> String.concat " | " (List.map (fun (n, _) -> bit n) kept)

(* A mask of the low [bits] bits of a word, as C. *)
let low_bits bits =
  if bits >= 64 then "UINT64_MAX" else sprintf "UINT64_C(0x%Lx)" (Int64.pred (Int64.shift_left 1L bits))

(* What [r] computes, as a C expression; an [Alloc] is statements of its
   own ([stmt]). *)
let rhs (r : rhs) =
  match r with
  | Atom x -> atom x
  (* a release build's `Float` arithmetic is C's, which carries a NaN; a
     debug build's tags one it makes (ren_rt.h, "NaN") *)
  | Arith (op, x, y, _) when atom_layout x = Float && !is_release -> (
      match op with
      | Mod -> sprintf "fmod(%s, %s)" (atom x) (atom y)
      | _ ->
          sprintf "(%s %s %s)" (atom x) (Ast.binop_to_string op) (atom y))
  | Arith (op, x, y, s) when atom_layout x = Float ->
      sprintf "%s_d(%s, %s, %s)"
        (binop_fn op Float)
        (atom x) (atom y) (tag s)
  | Arith (op, x, y, s) ->
      sprintf "%s(%s, %s, %s)"
        (binop_fn op (atom_layout x))
        (atom x) (atom y) (site s)
  | Late (op, x, y, s) ->
      sprintf "%s_late(%s, %s, %s)" (binop_fn op Int) (atom x) (atom y) (site s)
  | Neg (x, s) -> (
      match atom_layout x with
      | Float -> sprintf "(-%s)" (atom x)
      | _ -> sprintf "ren_neg(%s, %s)" (atom x) (site s))
  | Compare (c, x, y) -> sprintf "(%s %s %s)" (atom x) (cmp_op c) (atom y)
  | Not x -> sprintf "(!%s)" (atom x)
  | Tag_of x -> (
      match atom_layout x with
      | Enum -> sprintf "((int64_t)%s)" (atom x)
      | Struct (n, _) -> (
          match !structs.(n).skind with
          | Tagged -> sprintf "%s.s[0].i" (atom x)
          | Nullable (none, some) ->
              sprintf "(%s.s[0].o == ren_box(UINT32_MAX) ? %d : %d)" (atom x)
                none some
          | Product -> bug "the tag of a record or a tuple")
      | _ -> sprintf "ren_tag(%s)" (atom x))
  | Field (x, n, _) | Struct_get (x, n) ->
      failwith (sprintf "bug: emit_c: a field %s.%d outside a Let" (atom x) n)
  | Make_struct _ -> bug "a struct made outside a Let"
  | Pack xs ->
      (* a `Float32` by its bits; a signed type's value, converted to
         [uint64_t], has its low bits as they are *)
      let part (x, at, bits) =
        let c =
          match atom_layout x with
          | Sized F32 -> sprintf "ren_f32_bits(%s)" (atom x)
          | _ -> atom x
        in
        sprintf "(((uint64_t)%s & %s) << %d)" c (low_bits bits) at
      in
      sprintf "((int64_t)(%s))" (String.concat " | " (List.map part xs))
  | Unpack _ -> bug "a packed field read outside a Let"
  | Is_unique x -> sprintf "ren_is_unique(%s)" (atom x)
  | Reset (x, kept) -> sprintf "ren_reset(%s, %s)" (atom x) (mask kept)
  | Hole (x, n) -> sprintf "((void*)&ren_fields(%s)[%d])" (atom x) n
  | Call (f, xs) -> sprintf "%s(%s)" f (String.concat ", " (List.map atom xs))
  | Runtime (rt, xs, s) ->
      let call = runtime rt xs s in
      if gives_nothing rt then sprintf "(%s, (ren_unit)0)" call else call
  | Load v -> sprintf "(*%s)" (var v)
  | Addr v -> sprintf "(&%s)" (var v)
  | To_word x -> to_val x
  | Of_word (x, l) -> of_val l (atom x)
  | Global name -> name
  | Block_of (f, env) -> sprintf "((ren_block){%s, %s})" f (atom env)
  | Op_block (ev, dep, op) ->
      sprintf "ren_find(%s, %d)->ops[%d]" (atom ev) dep op
  | Alloc _ | Alloc_array _ | Env_new _ | Env_get _ | Arg _ | Impl _ | Install _
  | Given _ ->
      bug "an allocation on the heap or the stack outside a Let"

type out = {
  b : Buffer.t;
  fails : bool;
  mutable catches : (int * var) list;
  fname : string;
  bufs : (int, unit) Hashtbl.t;
      (** the buffers hoist.ml read before a loop, [Array_data]'s *)
  outlined : Buffer.t;  (** the loops moved out of the function, before it *)
  inside : bool;  (** whether this is a loop moved out *)
  restrict : bool;
}

let line o depth s =
  Buffer.add_string o.b (String.make (2 * depth) ' ');
  Buffer.add_string o.b s;
  Buffer.add_char o.b '\n'

(* A list of C expressions, in braces, for an array's initializer. *)
let braces xs = "{" ^ String.concat ", " xs ^ "}"

(* The C type of a [ren_val]'s caller's arguments: an array of them on
   the stack, or none. *)
let args_array o d name xs =
  match xs with
  | [] -> "NULL"
  | _ ->
      line o d
        (sprintf "ren_val %s[%d] = %s;" name (List.length xs)
           (braces (List.map to_val xs)));
      name

(* A call through a block's or a handler's code, [call] given where its
   value goes, which a status says the end of. *)
let indirect o d ~result ~error call =
  let line = line o d in
  let out = var result ^ "_out" in
  line (sprintf "ren_val %s = {0};" out);
  line (sprintf "ren_obj* %s = %s;" (var error) (call ("&" ^ out)));
  line
    (sprintf "%s %s = %s;" (ctype result.layout) (var result)
       (of_val result.layout out))

let rec stmt o d (s : stmt) =
  let line = line o d in
  match s with
  | Let (v, Field (x, n, _)) ->
      line
        (sprintf "%s %s = %s;" (ctype v.layout) (var v)
           (of_val v.layout (sprintf "ren_fields(%s)[%d]" (atom x) n)))
  | Let (v, Struct_get (x, n)) ->
      line
        (sprintf "%s %s = %s;" (ctype v.layout) (var v)
           (of_val v.layout (sprintf "%s.s[%d]" (atom x) n)))
  | Let (v, Unpack (x, at, bits)) when v.layout = Sized F32 ->
      line
        (sprintf "float %s = ren_f32_of_bits((uint32_t)(((uint64_t)%s >> %d) & %s));"
           (var v) (atom x) at (low_bits bits))
  | Let (v, Unpack (x, at, bits)) ->
      line
        (sprintf "%s %s = (%s)(((uint64_t)%s >> %d) & %s);" (ctype v.layout)
           (var v) (ctype v.layout) (atom x) at (low_bits bits))
  | Let (v, Make_struct xs) ->
      line
        (sprintf "%s %s = {%s};" (ctype v.layout) (var v)
           (braces (List.map to_val xs)))
  | Let (v, Alloc { tag; fields; words; at }) -> (
      (* a bit for each field that holds an object: one that always does,
         or a word whose descriptor says it does *)
      let words = ref words in
      let bits =
        List.concat
          (List.mapi
             (fun i x ->
               match atom_layout x with
               | l when is_object l -> [ bit i ]
               | Word _ -> (
                   match !words with
                   | w :: rest ->
                       words := rest;
                       [
                         sprintf "(ren_desc_counted(%s) ? %s : 0u)" (atom w)
                           (bit i);
                       ]
                   | [] -> bug "a word with no descriptor")
               | _ -> [])
             fields)
      in
      let objs = match bits with [] -> "0" | _ -> String.concat " | " bits in
      let n = List.length fields in
      (* the top three tags are the runtime's (ren_rt.h, [REN_TAG_ARRAY]),
         and a field count is a byte *)
      if tag >= 0xFFFD then bug "a constructor's tag past 65,532";
      if n > 64 then bug "a constructor of more than 64 fields";
      let alloc =
        if at = None && List.mem v.id !in_slot then
          sprintf "ren_stack_ctor(ren_slot, %d, %d, %s)" tag n objs
        else if at = None && List.mem v.id !in_frame then
          sprintf "ren_stack_ctor(&%s_frame.h, %d, %d, %s)" (var v) tag n objs
        else sprintf "ren_alloc_ctor(%d, %d, %s)" tag n objs
      in
      let set i x =
        line (sprintf "ren_fields(%s)[%d] = %s;" (var v) i (to_val x))
      in
      match at with
      | None ->
          line (sprintf "ren_obj* %s = %s;" (var v) alloc);
          List.iteri set fields
      | Some (t, _) when List.mem v.id !in_slot ->
          (* the version that builds its result in its caller's frame
             builds it there, as its caller drops it: the token's memory,
             which reuse gave the version that builds on the heap, is
             given back *)
          line (sprintf "ren_free_token(%s);" (atom t));
          line
            (sprintf "ren_obj* %s = ren_stack_ctor(ren_slot, %d, %d, %s);"
               (var v) tag n objs);
          List.iteri set fields
      | Some (t, same) ->
          (* in the token's memory, the slots in [same] already hold their
             fields: only a new object needs them written *)
          line
            (sprintf "ren_obj* %s = %s != NULL ? ren_reuse(%s, %d, %d, %s) : %s;"
               (var v) (atom t) (atom t) tag n objs alloc);
          if same <> [] then (
            line (sprintf "if (%s == NULL) {" (atom t));
            List.iteri
              (fun i x ->
                if List.mem i same then
                  line
                    (sprintf "  ren_fields(%s)[%d] = %s;" (var v) i (to_val x)))
              fields;
            line "}");
          List.iteri (fun i x -> if not (List.mem i same) then set i x) fields)
  | Let (v, Alloc_array { elem; elems; desc }) -> (
      let boxed =
        match desc with
        | Some d -> sprintf "ren_desc_counted(%s)" (atom d)
        | None -> string_of_bool (is_object elem)
      in
      match elem with
      | Struct (n, _) ->
          line
            (sprintf "ren_obj* %s = ren_alloc_array_n(%d, %d);" (var v)
               (List.length elems) (struct_words n));
          List.iteri
            (fun i x ->
              line
                (sprintf "((ren_struct_%d*)ren_elems(%s))[%d] = %s;" n (var v) i
                   (atom x)))
            elems
      (* a sized type's, at its width *)
      | Sized k ->
          line
            (sprintf "ren_obj* %s = ren_alloc_array_k(%d, %s);" (var v)
               (List.length elems) (sized_kind k));
          List.iteri
            (fun i x ->
              line
                (sprintf "((%s*)ren_elems(%s))[%d] = %s;" (sized_ctype k)
                   (var v) i (atom x)))
            elems
      (* a type variable's, which its descriptor says how to keep *)
      | Word _ when desc <> None ->
          line
            (sprintf "ren_obj* %s = ren_alloc_array_d(%d, %s);" (var v)
               (List.length elems) (atom (Option.get desc)));
          List.iteri
            (fun i x ->
              line
                (sprintf "ren_array_init_w(%s, %d, %s);" (var v) i (to_val x)))
            elems
      | _ ->
          line
            (sprintf "ren_obj* %s = ren_alloc_array(%d, %s);" (var v)
               (List.length elems) boxed);
          List.iteri
            (fun i x ->
              line (sprintf "ren_elems(%s)[%d] = %s;" (var v) i (to_val x)))
            elems)
  | Let (v, Runtime (New_desc how, xs, _)) ->
      let args = var v ^ "_args" in
      let n = List.length xs in
      if n > 0 then
        line
          (sprintf "ren_obj* %s[%d] = %s;" args n (braces (List.map atom xs)));
      let kind, decl =
        match how with
        | Of_decl k -> ("REN_D_NAMED", sprintf "&ren_decl_%d" k)
        | Of_array -> ("REN_D_ARRAY", "NULL")
        | Of_tuple -> ("REN_D_TUPLE", "NULL")
      in
      line
        (sprintf "ren_obj* %s = ren_desc_new(%s, %s, %d, %s);" (var v) kind decl
           n
           (if n > 0 then args else "NULL"))
  | Let (v, Env_new xs) -> (
      match xs with
      | [] -> line (sprintf "void* %s = NULL;" (var v))
      | _ ->
          line
            (sprintf "void* %s_env[%d] = %s;" (var v) (List.length xs)
               (braces (List.map (fun x -> "(void*)" ^ atom x) xs)));
          line (sprintf "void* %s = %s_env;" (var v) (var v)))
  | Let (v, Env_get (x, n)) ->
      line
        (sprintf "%s %s = (%s)((void**)%s)[%d];" (ctype v.layout) (var v)
           (ctype v.layout) (atom x) n)
  | Let (v, Arg (x, n)) ->
      line
        (sprintf "%s %s = %s;" (ctype v.layout) (var v)
           (of_val v.layout (sprintf "((ren_val*)%s)[%d]" (atom x) n)))
  | Let (v, Impl (dep, ops)) ->
      line
        (sprintf "ren_block %s_ops[%d] = %s;" (var v)
           (max 1 (List.length ops))
           (braces (List.map atom ops)));
      line
        (sprintf "ren_impl %s_impl = {%d, %d, %s_ops};" (var v) dep
           (List.length ops) (var v));
      line (sprintf "void* %s = &%s_impl;" (var v) (var v))
  | Let (v, Install { outer; impls; deps; ndeps }) ->
      let n = List.length impls in
      line (sprintf "ren_ev %s_nodes[%d];" (var v) (max 1 n));
      line
        (sprintf "const ren_impl* %s_impls[%d] = %s;" (var v) (max 1 n)
           (braces (List.map (fun x -> "(const ren_impl*)" ^ atom x) impls)));
      line
        (sprintf
           "const ren_ev* %s = ren_install(%s_nodes, %s, %s, %s, %s_impls, %d);"
           (var v) (var v) (atom outer) (atom deps) (atom ndeps) (var v) n)
  | Let (v, Given { outer; caller; deps }) ->
      let n = List.length deps in
      line (sprintf "ren_ev %s_nodes[%d];" (var v) n);
      line
        (sprintf "static const int32_t %s_deps[%d] = %s;" (var v) n
           (braces (List.map string_of_int deps)));
      line
        (sprintf "const ren_ev* %s = ren_given(%s_nodes, %s, %s, %s_deps, %d);"
           (var v) (var v) (atom outer) (atom caller) (var v) n)
  | Let (v, Call (f, xs)) when into_frame v f <> None ->
      let f, mem = Option.get (into_frame v f) in
      line
        (sprintf "%s %s = %s(%s);" (ctype v.layout) (var v) f
           (String.concat ", " (List.map atom xs @ [ mem ])))
  (* a buffer hoist.ml read: its elements, which a loop not moved out
     ([builds_framed]) indexes where it is *)
  | Let (v, (Runtime (Array_data, _, _) as r)) ->
      line (sprintf "ren_val* %s = %s;" (var v) (rhs r))
  | Let (v, r) -> line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (rhs r))
  | Decl v ->
      line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (zero v.layout))
  | Set (v, x) -> line (sprintf "%s = %s;" (var v) (atom x))
  | Store (v, x) -> line (sprintf "*%s = %s;" (var v) (atom x))
  (* a struct: each object it holds *)
  | (Dup x | Drop x | Free (x, _)) when is_struct x ->
      let what, kept =
        match s with
        | Dup _ -> ("ren_dup", [])
        | Free (_, kept) -> ("ren_drop", kept)
        | _ -> ("ren_drop", [])
      in
      List.iter
        (fun o -> line (sprintf "%s(%s);" what o))
        (struct_objects ~kept (atom_layout x) (atom x))
  | Dup x -> line (sprintf "ren_dup(%s);" (atom x))
  | Drop x when framed x -> line (sprintf "ren_stack_drop(%s, 0u);" (atom x))
  | Drop x -> line (sprintf "ren_drop(%s);" (atom x))
  | Dup_word (x, dsc) ->
      line (sprintf "ren_dup_val(%s, %s);" (atom x) (atom dsc))
  | Drop_word (x, dsc) ->
      line (sprintf "ren_drop_val(%s, %s);" (atom x) (atom dsc))
  | Free (x, kept) when framed x ->
      line (sprintf "ren_stack_drop(%s, %s);" (atom x) (mask kept))
  | Free (x, kept) ->
      line (sprintf "ren_free_keeping(%s, %s);" (atom x) (mask kept))
  | Free_token x -> line (sprintf "ren_free_token(%s);" (atom x))
  | Fill (p, x) -> line (sprintf "*(ren_val*)%s = %s;" (atom p) (to_val x))
  | Do (Runtime (rt, xs, s)) -> line (sprintf "%s;" (runtime rt xs s))
  | Do r -> line (sprintf "(void)%s;" (rhs r))
  | Call_fails { result; fn; args; error; on_error } ->
      line
        (sprintf "%s %s = %s;" (ctype result.layout) (var result)
           (zero result.layout));
      let fn, mem =
        match into_frame result fn with
        | Some (f, mem) -> (f, [ mem ])
        | None -> (fn, [])
      in
      line
        (sprintf "ren_obj* %s = %s(%s);" (var error) fn
           (String.concat ", "
              (List.map atom args @ mem @ [ "&" ^ var result ])));
      line (sprintf "if (%s != NULL) {" (var error));
      block o (d + 1) on_error;
      line "}"
  | Call_block { result; block = b; ev; args; error; on_error } ->
      line "REN_STAT(block_calls);";
      let args = args_array o d (var result ^ "_args") args in
      indirect o d ~result ~error (fun out ->
          sprintf "%s.code(%s.env, %s, %s, %s)" (atom b) (atom b) (atom ev) args
            out);
      on_failure o d error on_error
  | Call_handler { result; handler; outer; body; desc; deps; error; on_error }
    ->
      let n = List.length deps in
      line
        (sprintf "static const int32_t %s_deps[%d] = %s;" (var result) (max 1 n)
           (braces (List.map string_of_int deps)));
      indirect o d ~result ~error (fun out ->
          sprintf
            "((ren_hcode)ren_fields(%s)[0].p)(%s, %s, %s, %s, (void*)%s_deps, \
             %d, %s)"
            (atom handler) (atom handler) (atom outer) (atom body) (atom desc)
            (var result) n out);
      on_failure o d error on_error
  | If (c, t, f) ->
      line (sprintf "if (%s) {" (atom c));
      block o (d + 1) t;
      if f <> [] then (
        line "} else {";
        block o (d + 1) f);
      line "}"
  | Switch (x, cases, default) ->
      line (sprintf "switch (%s) {" (atom x));
      List.iter
        (fun (t, b) ->
          line (sprintf "case %d: {" t);
          block o (d + 1) b;
          line "  break;";
          line "}")
        cases;
      line "default: {";
      block o (d + 1) default;
      line "}";
      line "}"
  | Loop (l, b) when (not o.inside) && uses_buffer o b && not (builds_framed b)
    ->
      outline o d l b
  | Loop (l, b) ->
      line "for (;;) {";
      block o (d + 1) b;
      line "}";
      line (sprintf "ren_break_%d: ;" l)
  | Break l -> line (sprintf "goto ren_break_%d;" l)
  | Joins (b, joins) ->
      let end_ = match joins with (l, _) :: _ -> l | [] -> 0 in
      line "{";
      block o (d + 1) b;
      List.iter
        (fun (l, j) ->
          line (sprintf "ren_join_%d: ;" l);
          line "{";
          block o (d + 1) j;
          line "}";
          line (sprintf "goto ren_joined_%d;" end_))
        joins;
      line (sprintf "ren_joined_%d: ;" end_);
      line "}"
  | Jump l -> line (sprintf "goto ren_join_%d;" l)
  | Catch { label; body; error; handler } ->
      line (sprintf "ren_obj* %s = NULL;" (var error));
      o.catches <- (label, error) :: o.catches;
      line "{";
      block o (d + 1) body;
      line "}";
      line (sprintf "goto ren_caught_%d;" label);
      line (sprintf "ren_catch_%d: ;" label);
      line "{";
      block o (d + 1) handler;
      line "}";
      line (sprintf "ren_caught_%d: ;" label)
  | Raise (x, Some l) ->
      let e = List.assoc l o.catches in
      line (sprintf "%s = %s;" (var e) (atom x));
      line (sprintf "goto ren_catch_%d;" l)
  | Raise (x, None) -> line (sprintf "return %s;" (atom x))
  | Return x ->
      if o.fails then (
        line (sprintf "*ren_out = %s;" (atom x));
        line "return NULL;")
      else line (sprintf "return %s;" (atom x))
  | Assert (c, s) ->
      line (sprintf "if (!%s) ren_panic(%s, \"\");" (atom c) (site s))
  | Panic (s, msg) ->
      line (sprintf "ren_panic(%s, %s);" (site s) (c_string msg))

and block o d b = List.iter (stmt o d) b

(* Whether a loop builds an object in the frame (stack.ml): its memory is
   the function's, which a loop moved out of it can't name, so such a
   loop stays where it is, without `restrict`. *)
and builds_framed b =
  let found = ref false in
  Rc.iter_stmts
    (function
      | Let (v, Alloc { at = None; _ })
        when List.mem v.id !in_frame || List.mem v.id !in_slot ->
          found := true
      | (Let (v, Call (g, _)) | Call_fails { result = v; fn = g; _ })
        when into_frame v g <> None ->
          found := true
      | _ -> ())
    b;
  !found

(* Whether a loop indexes a buffer hoist.ml read before it. *)
and uses_buffer o b =
  let free, _ = free_vars [ Loop (0, b) ] in
  List.exists (fun (v : var) -> Hashtbl.mem o.bufs v.id) free

(* A loop hoist.ml read buffers for, as a function of its own, inlined,
   whose parameters are the variables it uses from around it: a buffer
   as a pointer, `restrict` unless [--no-restrict], since the clang this
   was measured on ignores `restrict` on a local but keeps it on a
   parameter it inlines; a variable the loop changes, or takes the
   address of, by its address; the rest by value. hoist.ml moves a loop
   only if control leaves it by its end. *)
and outline o d l b =
  let loop = [ Loop (l, b) ] in
  let free, changed = free_vars loop in
  let name = sprintf "%s_loop_%d" o.fname l in
  let params =
    List.map
      (fun (v : var) ->
        if Hashtbl.mem o.bufs v.id then
          ( sprintf "ren_val*%s %s"
              (if o.restrict then " restrict" else "")
              (c_name v),
            var v )
        else if List.mem v.id changed then
          (sprintf "%s* %s" (ctype v.layout) (c_name v), "&" ^ var v)
        else (sprintf "%s %s" (ctype v.layout) (c_name v), var v))
      free
  in
  line o d (sprintf "%s(%s);" name (String.concat ", " (List.map snd params)));
  let o' = { o with b = Buffer.create 4096; inside = true } in
  List.iter
    (fun (v : var) ->
      if List.mem v.id changed then Hashtbl.replace by_address v.id ())
    free;
  block o' 1 loop;
  List.iter (fun (v : var) -> Hashtbl.remove by_address v.id) free;
  Buffer.add_string o.outlined
    (sprintf "static inline __attribute__((always_inline)) void %s(%s) {\n" name
       (match params with
       | [] -> "void"
       | ps -> String.concat ", " (List.map fst ps)));
  Buffer.add_buffer o.outlined o'.b;
  Buffer.add_string o.outlined "}\n\n"

(* The variables a block uses that it doesn't define, by id, and the
   ids of those it changes or takes the address of. *)
and free_vars (b : block) =
  let inside, _ = Hoist.defined b in
  let free = Hashtbl.create 16 and changed = ref [] in
  Rc.iter_stmts
    (fun s ->
      List.iter
        (fun (v : var) ->
          if not (Ids.mem v.id inside) then Hashtbl.replace free v.id v)
        (Hoist.mentions s);
      match s with
      | Set (v, _) | Let (_, Addr v) -> changed := v.id :: !changed
      | _ -> ())
    b;
  let free =
    Hashtbl.fold (fun _ v acc -> v :: acc) free []
    |> List.sort (fun (a : var) b -> compare a.id b.id)
  in
  (free, !changed)

(* What an indirect call does if it failed. *)
and on_failure o d error on_error =
  match on_error with
  | Some b ->
      line o d (sprintf "if (%s != NULL) {" (var error));
      block o (d + 1) b;
      line o d "}"
  | None -> line o d (sprintf "(void)%s;" (var error))

(* With [restrict], an `inout` parameter is a `restrict` pointer: the
   only way to what it points to, which exclusivity (excl.ml) makes
   true, so C may keep what it points to in a register.
   With [slot], it's the version that builds its result in memory its
   caller gives, [ren_slot] (stack.ml). *)
let signature ?(slot = false) ~restrict (f : fn) =
  let params =
    List.map
      (fun v ->
        if restrict && List.exists (fun (w : var) -> w.id = v.id) f.inout then
          ctype v.layout ^ " restrict " ^ var v
        else ctype v.layout ^ " " ^ var v)
      f.params
    @ if slot then [ "ren_obj* ren_slot" ] else []
  in
  let name = if slot then slot_fn f.name else f.name in
  if f.fails then
    sprintf "static ren_obj* %s(%s)" name
      (String.concat ", " (params @ [ ctype f.result ^ "* ren_out" ]))
  else
    sprintf "static %s %s(%s)" (ctype f.result) name
      (match params with [] -> "void" | ps -> String.concat ", " ps)

(* ---- where the stack is checked ----

   Every function checks the stack when it starts ([REN_STACK_CHECK]),
   but for one that can't be where it runs out: one that calls no
   function of the program's but those that can't either, through no
   block or handler, whose code isn't known, in a chain of at most
   [shallow] of them. Recursion only goes on through functions that
   check, so it panics as before, and below the last frame that checked
   there are at most [shallow] that didn't, each of a fixed size, which
   [REN_STACK_MARGIN] (1 MiB) has room for. A lifted block that only
   computes, H1's `map`, is one of them: its check was three
   instructions an element (bench/native/RESULTS.md, H1). *)

let shallow = 8

(* The functions [b] calls directly, or [None] if it calls through a
   block or a handler. *)
let callees (b : block) =
  let exception Indirect in
  let acc = ref [] in
  let rhs = function Call (g, _) -> acc := g :: !acc | _ -> () in
  let rec stmt = function
    | Let (_, r) | Do r -> rhs r
    | Call_fails { fn; on_error; _ } ->
        acc := fn :: !acc;
        block on_error
    | Call_block _ | Call_handler _ -> raise Indirect
    | If (_, a, b) ->
        block a;
        block b
    | Switch (_, cases, d) ->
        List.iter (fun (_, b) -> block b) cases;
        block d
    | Loop (_, b) -> block b
    | Joins (b, js) ->
        block b;
        List.iter (fun (_, b) -> block b) js
    | Catch { body; handler; _ } ->
        block body;
        block handler
    | Decl _ | Set _ | Store _ | Dup _ | Drop _ | Dup_word _ | Drop_word _
    | Free _ | Free_token _ | Fill _ | Break _ | Jump _ | Raise _ | Return _
    | Assert _ | Panic _ ->
        ()
  and block b = List.iter stmt b in
  match block b with () -> Some !acc | exception Indirect -> None

(* The functions that needn't check, each with the length of the
   longest chain of calls it starts, itself counted: found from the
   leaves up, so a function in a cycle is never one. *)
let unchecked (fns : fn list) =
  let calls =
    List.filter_map
      (fun (f : fn) -> Option.map (fun gs -> (f.name, gs)) (callees f.body))
      fns
  in
  let depth = Hashtbl.create 64 in
  let rec go () =
    let changed = ref false in
    List.iter
      (fun (f, gs) ->
        if not (Hashtbl.mem depth f) then
          let ds = List.map (Hashtbl.find_opt depth) gs in
          if List.for_all Option.is_some ds then
            let d = 1 + List.fold_left (fun m d -> max m (Option.get d)) 0 ds in
            if d <= shallow then (
              Hashtbl.replace depth f d;
              changed := true))
      calls;
    if !changed then go ()
  in
  go ();
  depth

let fn ?(slot = false) ~restrict ~checks b (f : fn) =
  let bufs = Hashtbl.create 8 in
  Rc.iter_stmts
    (function
      | Let (v, Runtime (Array_data, _, _)) -> Hashtbl.replace bufs v.id ()
      | _ -> ())
    f.body;
  let o =
    {
      b = Buffer.create 4096;
      fails = f.fails;
      catches = [];
      fname = (if slot then slot_fn f.name else f.name);
      bufs;
      outlined = Buffer.create 0;
      inside = false;
      restrict;
    }
  in
  if checks f.name then line o 1 "REN_STACK_CHECK();";
  (match f.slot with
  | Some (v, names) when slot ->
      in_slot := v;
      in_frame := names @ f.stack
  | _ ->
      in_slot := [];
      in_frame := f.stack);
  (* each object kept in the frame: its memory, for the whole call, so
     a name declared before the block it's built in still points at it;
     one built in a loop is built over its last, which stack.ml makes
     sure is dead by then *)
  let frame (v : var) n =
    line o 1
      (sprintf "struct { ren_obj h; ren_val f[%d]; } %s_frame;" (frame_words n)
         (var v))
  in
  Rc.iter_stmts
    (function
      | Let (v, Alloc { fields; at = None; _ })
        when List.mem v.id !in_frame && not (List.mem v.id !in_slot) ->
          frame v (List.length fields)
      | (Let (v, Call (g, _)) | Call_fails { result = v; fn = g; _ })
        when into_frame v g <> None ->
          frame v (Hashtbl.find slot_sizes g)
      | _ -> ())
    f.body;
  block o 1 f.body;
  Buffer.add_buffer b o.outlined;
  Buffer.add_string b (signature ~slot ~restrict f ^ " {\n");
  Buffer.add_buffer b o.b;
  Buffer.add_string b "}\n\n"

let dkind_c (k : dkind) =
  match k with
  | D_int -> "REN_D_INT"
  | D_float -> "REN_D_FLOAT"
  | D_bool -> "REN_D_BOOL"
  | D_unit -> "REN_D_UNIT"
  | D_str -> "REN_D_STR"
  | D_named _ -> "REN_D_NAMED"
  | D_array -> "REN_D_ARRAY"
  | D_tuple -> "REN_D_TUPLE"
  | D_errors -> "REN_D_ERRORS"
  | D_var _ -> "REN_D_VAR"
  | D_unknown -> "REN_D_UNKNOWN"
  | D_sized _ -> "REN_D_SIZED"

(* The program's descriptors and its types' declarations, as static data
   (ren_rt.h, [ren_desc] and [ren_decl]): each descriptor declared first,
   since a declaration's fields and a descriptor's arguments refer to
   others. A descriptor's count is 0, so it's never freed. *)
let static_types add (descs : desc list) (decls : decl list) =
  let desc_ref n = sprintf "&ren_desc_%d" n in
  let table name xs =
    match xs with
    | [] -> "NULL"
    | _ ->
        add
          (sprintf "static ren_desc *const %s[%d] = %s;\n" name (List.length xs)
             (braces (List.map desc_ref xs)));
        name
  in
  List.iteri (fun i _ -> add (sprintf "static ren_desc ren_desc_%d;\n" i)) descs;
  List.iteri
    (fun i (dc : decl) ->
      let ctor j (name, fields, types) =
        let nfields = List.length types in
        let types = table (sprintf "ren_decl_%d_%d_types" i j) types in
        (* where each field is kept, if its small scalars are packed *)
        let at =
          match List.nth_opt dc.dplaces j with
          | Some (Some places) ->
              let n = sprintf "ren_decl_%d_%d_at" i j in
              add
                (sprintf "static const uint32_t %s[%d] = %s;\n" n
                   (max 1 (List.length places))
                   (braces (List.map string_of_int places)));
              n
          | _ -> "NULL"
        in
        let names =
          match fields with
          | Some names ->
              let n = sprintf "ren_decl_%d_%d_names" i j in
              add
                (sprintf "static const char *const %s[%d] = %s;\n" n
                   (max 1 (List.length names))
                   (braces (List.map c_string names)));
              n
          | None -> "NULL"
        in
        sprintf "{%s, %d, %s, %s, %s}" (c_string name) nfields names types at
      in
      let ctors_of cs =
        let name = sprintf "ren_decl_%d_ctors" i in
        let cs = List.mapi ctor cs in
        add
          (sprintf "static const ren_ctor_info %s[%d] = %s;\n" name
             (List.length cs) (braces cs));
        name
      in
      let kind, enumlike, nctors, ctors, rep =
        match dc.dbody with
        | Record_decl fs ->
            ( "REN_DECL_RECORD",
              false,
              1,
              ctors_of [ (dc.dname, Some (List.map fst fs), List.map snd fs) ],
              "NULL" )
        | Sum_decl cs ->
            ( "REN_DECL_SUM",
              List.for_all (fun (_, ts) -> ts = []) cs,
              List.length cs,
              ctors_of (List.map (fun (c, ts) -> (c, None, ts)) cs),
              "NULL" )
        | Rep_decl r -> ("REN_DECL_REP", false, 0, "NULL", desc_ref r)
      in
      add
        (sprintf
           "static const ren_decl ren_decl_%d = {%s, %s, %b, %b, %d, %s, %s};\n"
           i (c_string dc.dname) kind dc.dopaque enumlike nctors ctors rep))
    decls;
  List.iteri
    (fun i (d : desc) ->
      let args = table (sprintf "ren_desc_%d_args" i) d.dargs in
      add
        (sprintf
           "static ren_desc ren_desc_%d = {{0, REN_TAG_DESC, 0, 0}, %s, %b, \
            %d, %s, %s, %s};\n"
           i (dkind_c d.dkind) d.dcounted (List.length d.dargs)
           (* a variable's number, or a sized type's kind *)
           (match d.dkind with
           | D_var n -> string_of_int n
           | D_sized k -> sized_kind k
           | _ -> "0")
           (match d.dkind with
           | D_named k -> sprintf "&ren_decl_%d" k
           | _ -> "NULL")
           args))
    descs

(* A number in a site's pieces: 7 bits a byte, least first, the top bit
   set on all but the last (LEB128), as ren_rt.c's [ren_site_num] reads
   it. *)
let leb b n =
  let rec go n =
    if n < 0x80 then Buffer.add_char b (Char.chr n)
    else (
      Buffer.add_char b (Char.chr (0x80 lor (n land 0x7f)));
      go (n lsr 7))
  in
  go n

(* The sites' pieces as C (ren_rt.h, [ren_site]): the texts they print,
   each once, in [ren_text_table], and each site's pieces as bytes, a
   site for all those whose bytes are the same. Text written next to text
   is one piece, but for [Shared] text, which other sites print too. *)
let sites add ~(site_pieces : site -> Diag.piece list) (all : site list) =
  let texts = Hashtbl.create 1024 and text_list = ref [] in
  let text s =
    match Hashtbl.find_opt texts s with
    | Some n -> n
    | None ->
        let n = Hashtbl.length texts in
        Hashtbl.replace texts s n;
        text_list := s :: !text_list;
        n
  in
  let rec merge (ps : Diag.piece list) : Diag.piece list =
    match ps with
    | Text a :: Text b :: rest -> merge (Text (a ^ b) :: rest)
    | Text "" :: rest -> merge rest
    | p :: rest -> p :: merge rest
    | [] -> []
  in
  let ops (ps : Diag.piece list) =
    let b = Buffer.create 32 in
    let op n = Buffer.add_char b (Char.chr n) in
    List.iter
      (fun (p : Diag.piece) ->
        match p with
        | Text s | Shared s ->
            op 1;
            leb b (text s)
        | Spaces n when n >= 0 ->
            op 2;
            leb b n
        | Marks (c, n) when n >= 0 ->
            op 3;
            Buffer.add_char b c;
            leb b n
        | Num n when n >= 0 ->
            op 4;
            leb b n
        | Hole -> op 5
        | Slice (s, i, n) ->
            op 6;
            leb b (text s);
            leb b i;
            leb b n
        (* what a number can't be: never, as it's rendered *)
        | Spaces _ | Marks _ | Num _ ->
            op 1;
            leb b (text (Diag.expand [ p ])))
      (merge ps);
    op 0;
    Buffer.contents b
  in
  Hashtbl.reset site_names;
  let named = Hashtbl.create 1024 in
  let decls = Buffer.create 65536 in
  List.iter
    (fun (s : site) ->
      let bytes = ops (site_pieces s) in
      match Hashtbl.find_opt named bytes with
      | Some n -> Hashtbl.replace site_names s.sid n
      | None ->
          Hashtbl.replace named bytes s.sid;
          Hashtbl.replace site_names s.sid s.sid;
          Buffer.add_string decls
            (sprintf
               "static const ren_site ren_site_%d = { (const unsigned char \
                *)%s };\n"
               s.sid (c_string bytes)))
    all;
  let texts = List.rev !text_list in
  add
    (sprintf "static const char *const ren_text_table[%d] = %s;\n"
       (max 1 (List.length texts))
       (braces
          (match texts with [] -> [ "NULL" ] | ts -> List.map c_string ts)));
  add (Buffer.contents decls)

(* The C file for [p]. [site_pieces] is what a panic at a site prints,
   with a [Hole] where its message goes. *)
let program ?(restrict = false) ?(release = false)
    ~(site_pieces : site -> Diag.piece list) (p : program) =
  let b = Buffer.create 65536 in
  is_release := release;
  Hashtbl.reset made_tags;
  let add = Buffer.add_string b in
  add Runtime_c.header;
  add "\n";
  add Runtime_c.source;
  add "\n/* ---- the program ---- */\n\n";
  List.iteri
    (fun i s ->
      let n = String.length s in
      add
        (sprintf
           "static struct { ren_obj h; int64_t len; char data[%d]; } \
            ren_lit_%d = { { 0, REN_TAG_STR, 0, 0 }, %d, %s };\n"
           (n + 1) i n (c_string s)))
    p.strings;
  (* a [Caller] site is [ren_here], none of its own *)
  sites add ~site_pieces
    (List.filter (fun (s : site) -> s.kind <> Caller) p.sites);
  add
    (sprintf "static const char *const ren_tag_table[%d] = %s;\n"
       (max 1 (List.length p.tags))
       (braces
          (match p.tags with [] -> [ "NULL" ] | ts -> List.map c_string ts)));
  static_types add p.descs p.decls;
  structs := Array.of_list p.structs;
  (* each struct, a word for each slot, as an array of structs keeps it *)
  List.iteri
    (fun n st ->
      add
        (sprintf "typedef struct { ren_val s[%d]; } ren_struct_%d;\n"
           (max 1 (List.length st.sfields))
           n))
    p.structs;
  List.iter
    (fun (v : value) ->
      add (sprintf "static %s %s;\n" (ctype v.vlayout) v.vname))
    p.values;
  add "\n";
  Hashtbl.reset slot_sizes;
  List.iter
    (fun (f : fn) ->
      match f.slot with
      | Some (v, _) ->
          (* as big as the biggest object built there *)
          Rc.iter_stmts
            (function
              | Let (w, Alloc { fields; _ }) when List.mem w.id v ->
                  let n = List.length fields in
                  let m =
                    Option.value (Hashtbl.find_opt slot_sizes f.name) ~default:0
                  in
                  Hashtbl.replace slot_sizes f.name (max n m)
              | _ -> ())
            f.body
      | None -> ())
    p.fns;
  List.iter
    (fun (f : fn) ->
      add (signature ~restrict f ^ ";\n");
      if f.slot <> None then add (signature ~slot:true ~restrict f ^ ";\n"))
    p.fns;
  add "\n";
  let unchecked = unchecked p.fns in
  let checks name = not (Hashtbl.mem unchecked name) in
  List.iter
    (fun (f : fn) ->
      fn ~restrict ~checks b f;
      if f.slot <> None then fn ~slot:true ~restrict ~checks b f)
    p.fns;
  add "static void ren_program(void) {\n";
  (* the associated values, made once, in order *)
  List.iter
    (fun (v : value) -> add (sprintf "  %s = %s(NULL);\n" v.vname v.vfn))
    p.values;
  if p.start_fails then (
    add (sprintf "  %s r = %s;\n" (ctype p.start_result) (zero p.start_result));
    add (sprintf "  ren_obj* e = %s(NULL, &r);\n" p.start);
    add "  if (e != NULL) ren_uncaught(e);\n")
  else add (sprintf "  %s r = %s(NULL);\n" (ctype p.start_result) p.start);
  if p.start_result <> Unit then (
    add
      (sprintf
         "  ren_print_value(stdout, (ren_obj*)&ren_desc_%d, %s, \
          ren_overflow_site);\n"
         p.start_desc
         (word_of p.start_result "r"));
    add "  fputc('\\n', stdout);\n");
  if is_object p.start_result then add "  ren_drop(r);\n";
  List.iter
    (fun (v : value) ->
      match v.vlayout with
      | Struct (_, true) ->
          List.iter
            (fun o -> add (sprintf "  ren_drop(%s);\n" o))
            (struct_objects v.vlayout v.vname)
      | l -> if is_object l then add (sprintf "  ren_drop(%s);\n" v.vname))
    (List.rev p.values);
  add "}\n\n";
  (* where each tag a debug build gives a NaN says it was made *)
  let wheres = Array.make (Hashtbl.length made_tags + 1) "NULL" in
  Hashtbl.iter (fun w n -> wheres.(n) <- c_string w) made_tags;
  if Hashtbl.length made_tags > 0 then
    add
      (sprintf "static const char *const ren_nan_where_table[%d] = %s;\n\n"
         (Array.length wheres)
         (braces (Array.to_list wheres)));
  add "int main(void) {\n";
  add (sprintf "  ren_overflow_site = %s;\n" (site p.overflow));
  if Hashtbl.length made_tags > 0 then (
    add "  ren_nan_where = ren_nan_where_table;\n";
    add (sprintf "  ren_nan_nwhere = %d;\n" (Array.length wheres)));
  add "  ren_texts = ren_text_table;\n";
  add "  ren_tag_names = ren_tag_table;\n";
  add "  return ren_run(ren_program);\n}\n";
  Buffer.contents b
