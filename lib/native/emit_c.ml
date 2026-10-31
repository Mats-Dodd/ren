(* Mem IR to C (compiler.md, "Native slice"): for a release build, one
   file, the runtime (ren_rt.h and ren_rt.c, embedded as Runtime_c)
   first, then the program; for a debug build, units to compile apart
   ([units], below).

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
(* The perfect-hash lookups of the program, by their keys, each with its
   number, in the order they're first emitted, and its C (phash.ml):
   made as the functions are, and written before them. *)
let lookups : (string list, int * string) Hashtbl.t = Hashtbl.create 8

let lookup keys =
  match Hashtbl.find_opt lookups keys with
  | Some (n, _) -> sprintf "ren_ph%d" n
  | None ->
      let n = Hashtbl.length lookups in
      let name = sprintf "ren_ph%d" n in
      let ks = Array.of_list keys in
      Hashtbl.replace lookups keys (n, Phash.c ~name ks (Phash.plan ks));
      name

(* Each lookup's C, by its name, in order. *)
let lookup_defs () =
  Hashtbl.fold (fun _ (n, c) acc -> (n, c) :: acc) lookups []
  |> List.sort compare
  |> List.map (fun (n, c) -> (sprintf "ren_ph%d" n, c))

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
  | Static_data (_, l) -> l
  | Int _ -> Int
  | Float _ -> Float
  | Bool _ -> Bool
  | Unit -> Unit
  | Enum_tag _ -> Enum
  | Scalar_ctor _ | Lit _ -> Boxed
  | Desc_lit _ -> Desc
  | Fn_ptr _ | Handler_tag _ -> Ptr
  | No_ev -> Ev

(* Whether a handler's tag is its number, a release build's, rather than
   a pointer to its record (ren_rt.h, [ren_handler]). *)
let numbered_tags = ref false

(* A release build's dispatch over the program's handlers (dispatch.ml),
   and its sites, by number: set by [parts]. *)
let dispatch : Dispatch.t option ref = ref None
let dsites : dsite array ref = ref [||]

let atom (x : atom) =
  match x with
  | Var v -> var v
  | Int n when n = Int64.min_int -> "INT64_MIN"
  | Int n -> sprintf "INT64_C(%Ld)" n
  | Float f when Float.is_nan f -> "NAN"
  | Float f when f = Float.infinity -> "INFINITY"
  | Float f when f = Float.neg_infinity -> "(-INFINITY)"
  (* hexadecimal, which C reads back exactly *)
  | Float f -> sprintf "%h" f
  | Bool b -> if b then "true" else "false"
  | Unit -> "((ren_unit)0)"
  | Enum_tag t -> sprintf "((uint32_t)%d)" t
  (* a [Niche] struct's constructor [-1 - t] without fields: a scalar no
     object or constructor is *)
  | Scalar_ctor t when t < 0 -> sprintf "ren_box(UINT32_MAX - %d)" (-1 - t)
  | Scalar_ctor t -> sprintf "ren_box(%d)" t
  | Static_data (n, (Boxed | Desc)) -> sprintf "((ren_obj*)&%s)" n
  | Static_data (n, _) -> n
  | Lit n -> sprintf "((ren_obj*)&ren_lit_%d)" n
  | Desc_lit n -> sprintf "((ren_obj*)&ren_desc_%d)" n
  | Fn_ptr f -> sprintf "((void*)%s)" f
  | Handler_tag n when !numbered_tags -> (
      (* a handler whose tag is its method's code (dispatch.ml) *)
      match !dispatch with
      | Some t when Hashtbl.mem t.code n ->
          sprintf "((void*)%s)" (Hashtbl.find t.code n)
      | _ -> sprintf "((void*)(intptr_t)%d)" n)
  | Handler_tag n -> sprintf "((void*)&ren_handler_%d)" n
  | No_ev -> "((const ren_ev*)NULL)"

let bug what = failwith ("bug: emit_c: " ^ what)

(* The record of the handler whose description is [x], found from its
   tag, the description's first word. *)
let handler_of ?(code = false) x =
  if code then sprintf "ren_handler_by_code(ren_fields(%s)[0].p)" x
  else if !numbered_tags then
    sprintf "(&ren_handlers[(intptr_t)ren_fields(%s)[0].p])" x
  else sprintf "((const ren_handler *)ren_fields(%s)[0].p)" x

(* The tag of the description [x], and the tag of the handler [h]. *)
let tag_of x = sprintf "ren_fields(%s)[0].p" x
let htag (h : handler) = atom (Handler_tag h.hid)

(* The table of the methods for [op] of [dep] of the program's handlers,
   by tag, NULL for a handler with none (dispatch.ml). *)
let method_table dep op = sprintf "ren_mtab_%d_%d" dep op

(* The [Method_of]s of the function being written, by variable. *)
let methods : (int, meth) Hashtbl.t = Hashtbl.create 8

(* How the call of [m] is lowered in this build: a release build's
   dispatch, or [None] in a debug build, which finds the method in the
   handler's record. *)
let lowering (m : meth) =
  match !dispatch with
  | Some t -> Some (t, fst (Dispatch.lowering t !dsites.(m.msite) m))
  | None -> None

(* The [Struct] a release build keeps a `Str` and `Bytes` as, the
   runtime's [ren_sv] (representation B), if it has one: set by [parts]. *)
let sv : int option ref = ref None

let is_sv (l : layout) =
  match (l, !sv) with Struct (n, _), Some m -> n = m | _ -> false

(* [c], a C expression of a value of [l], as a [ren_val], a word. A
   release build's `Str` is given to what only reads it, a walk, as an A
   slice made on the stack for the call ([REN_SV_VIEW], ren_rt.h), which
   lives as long as the statement: Mem Lint lets nothing else be given
   one (mem_lint.ml, [views]). *)
let word_of (l : layout) c =
  match l with
  | Word _ -> c
  | l when is_sv l -> sprintf "(ren_val){.o = REN_SV_VIEW(%s)}" c
  | Float -> sprintf "(ren_val){.f = %s}" c
  | Boxed | Desc -> sprintf "(ren_val){.o = %s}" c
  | Ptr | Ev | Cell _ -> sprintf "(ren_val){.p = (void*)%s}" c
  | Int | Bool | Unit | Enum -> sprintf "(ren_val){.i = (int64_t)%s}" c
  (* a sized type's value as a word is the number it is *)
  | Sized F32 -> sprintf "(ren_val){.f = (double)%s}" c
  | Sized _ -> sprintf "(ren_val){.i = (int64_t)%s}" c
  | Block | Token | Struct _ ->
      bug "a block, a token or a struct as a word"

let to_val (x : atom) = word_of (atom_layout x) (atom x)

(* A [ren_val], [v], as a value of [l]. *)
let of_val l v =
  match (l : layout) with
  | Word _ -> v
  | Float -> sprintf "%s.f" v
  | Boxed | Desc -> sprintf "%s.o" v
  | Ptr -> sprintf "%s.p" v
  | Cell _ as l -> sprintf "((%s)%s.p)" (ctype l) v
  | Ev -> sprintf "((const ren_ev*)%s.p)" v
  | Int -> sprintf "%s.i" v
  | Bool | Unit | Enum -> sprintf "(%s)%s.i" (ctype l) v
  | Sized F32 -> sprintf "((float)%s.f)" v
  | Sized k -> sprintf "((%s)%s.i)" (sized_ctype k) v
  | Block | Token | Struct _ ->
      bug "a word as a block, a token or a struct"

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

(* The mask of the [n]-th struct's slots that hold objects, bit [i] for
   slot [i]: an array of them keeps it in its header's [objs] (ren_rt.h,
   [ren_obj]), and counts its elements by it. *)
let struct_mask n =
  List.fold_left
    (fun (m, i) l -> ((if is_object l then m lor (1 lsl i) else m), i + 1))
    (0, 0) !structs.(n).sfields
  |> fst

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

let rec runtime ?result rt args site_arg =
  let a i = atom (List.nth args i) in
  let site () =
    match site_arg with
    | Some s -> site s
    | None -> bug "a runtime call that panics without a site"
  in
  (* an index's: none for one bounds.ml proved in bounds, which the
     runtime then doesn't check ([ren_array_check]) *)
  let isite () = if site_arg = None then "REN_IN_BOUNDS" else site () in
  let svx i = is_sv (atom_layout (List.nth args i)) in
  let str s = match (s : sliced) with Of_str -> "true" | _ -> "false" in
  (* a release build's `Str` and `Bytes`: the runtime's functions of two
     words (ren_rt.h, "representation B") *)
  let b =
    if !sv = None then None
    else
      match rt with
      | Str_len when svx 0 -> Some (sprintf "ren_sv_len(%s)" (a 0))
      | Str_data when svx 0 -> Some (sprintf "((void*)ren_sv_data(%s))" (a 0))
      | Str_eq when svx 0 -> Some (sprintf "ren_sv_eq(%s, %s)" (a 0) (a 1))
      | Str_is s when svx 0 ->
          Some (sprintf "ren_sv_pat_is(%s, %s, %d)" (a 0) (c_string s) (String.length s))
      | Str_affix (p, s) when svx 0 ->
          Some
            (sprintf "ren_sv_pat_affix(%s, %s, %d, %s, %d)" (a 0) (c_string p)
               (String.length p) (c_string s) (String.length s))
      | Str_lookup ks when svx 0 ->
          Some
            (sprintf "%s(ren_sv_data(%s), (uint64_t)ren_sv_len(%s))" (lookup ks) (a 0)
               (a 0))
      | Str_concat when svx 0 ->
          Some (sprintf "ren_sv_concat(%s, %s)" (a 0) (a 1))
      | Str_concat_taking when svx 0 ->
          Some (sprintf "ren_sv_concat_taking(%s, %s, NULL)" (a 0) (a 1))
      | Str_box -> Some (sprintf "ren_sv_box(%s)" (a 0))
      | Str_unbox -> Some (sprintf "ren_sv_unbox(%s)" (a 0))
      | Slice (s, Range) when svx 0 ->
          Some
            (sprintf "ren_sv_slice(%s, %s, %s, %s, %s)" (a 0) (a 1) (a 2) (str s)
               (site ()))
      (* the uncounted view: the same checks, the root not counted *)
      | Str_view s when svx 0 ->
          Some
            (sprintf "ren_sv_view_slice(%s, %s, %s, %s, %s)" (a 0) (a 1) (a 2)
               (str s) (site ()))
      | Slice (s, Before) when svx 0 ->
          Some (sprintf "ren_sv_before(%s, %s, %s, %s)" (a 0) (a 1) (str s) (site ()))
      | Slice (_, After) when svx 0 -> Some (sprintf "ren_sv_after(%s, %s)" (a 0) (a 1))
      | Join _ when svx 0 -> Some (sprintf "ren_sv_join(%s, %s)" (a 0) (a 1))
      | Copied _ when svx 0 -> Some (sprintf "ren_sv_copied(%s)" (a 0))
      | Str_split when svx 0 ->
          Some (sprintf "ren_sv_split(%s, %s, %s)" (a 0) (a 1) (site ()))
      | Str_trim when svx 0 -> Some (sprintf "ren_sv_trim(%s)" (a 0))
      | Vacant when svx 0 -> Some "ren_sv_vacant()"
      | Bytes_at when svx 0 ->
          Some (sprintf "ren_sv_at(%s, %s, %s)" (a 0) (a 1) (isite ()))
      | Bytes_load acc when svx 0 ->
          Some
            (sprintf "ren_sv_load(%s, %s, %d, %b, %b, %s)" (a 0) (a 1) acc.width
               acc.signed acc.big (site ()))
      | (Bytes_store acc | Bytes_store_taking acc)
        when (match atom_layout (List.hd args) with Cell l -> is_sv l | _ -> false) ->
          Some
            (sprintf "ren_sv_store(%s, %s, %s, %d, %b, %b, %b, %s)" (a 0) (a 1)
               (a 2) acc.width acc.signed acc.big
               (match rt with Bytes_store_taking _ -> true | _ -> false)
               (site ()))
      | (Bytes_set_var signed | Bytes_set_var_taking signed)
        when (match atom_layout (List.hd args) with Cell l -> is_sv l | _ -> false) ->
          Some
            (sprintf "ren_sv_set_var(%s, %s, %s, %b, %b, %s)" (a 0) (a 1) (a 2)
               signed
               (match rt with Bytes_set_var_taking _ -> true | _ -> false)
               (site ()))
      | Str_join when svx 1 -> Some (sprintf "ren_sv_strs_join(%s, %s)" (a 0) (a 1))
      | _ -> None
  in
  (* the functions of A strings a release build still calls, each given a
     `Str` as an A slice on the stack: they only read it *)
  let str_args =
    match rt with
    | Console_write | Console_error | Utf8_error | Utf8_incomplete | Utf8_lossy
    | Char_bound _ | Str_code | Str_lower | Splice _ | Panic_str | Str_find
    | Str_has _ | Str_upper | Line_col _ ->
        true
    | _ -> false
  in
  match b with
  | Some c -> c
  | None
    when (match result with Some l -> is_sv l | None -> false)
         && (str_args
            ||
            match rt with
            | Show_int | Show_float | Show_bool | Show_any | Bytes_zeros
            | Bytes_of | Str_of_code ->
                true
            | _ -> false) ->
      (* a new owner, or what may be one of the strings given, an A
         object, as two words *)
      let fresh =
        match rt with
        | Show_int | Show_float | Show_bool | Bytes_zeros | Bytes_of
        | Str_of_code | Str_lower | Str_upper | Splice _ ->
            true
        | _ -> false
      in
      sprintf "%s(%s)"
        (if fresh then "ren_sv_of" else "ren_sv_take")
        (runtime rt args site_arg)
  | None ->
  (* a `Str` given to a function of A objects is an A slice on the stack
     for the call ([REN_SV_VIEW]) *)
  let a i =
    if str_args && svx i then sprintf "REN_SV_VIEW(%s)" (atom (List.nth args i))
    else a i
  in
  let w i = if svx i then to_val (List.nth args i) else a i in
  match rt with
  | Array_len -> sprintf "ren_array_len(%s)" (a 0)
  (* an array of structs: each element its words, a stride the C knows *)
  (* an element not counted, a part of the array (rc.ml, [lent_reads]):
     its words, as an uncounted struct's or a scalar's are read *)
  | Array_peek (Struct (n, _)) ->
      sprintf "(*(ren_struct_%d*)ren_array_slots_k(%s, %s, %d, %s))" n (a 0)
        (a 1) (struct_words n) (isite ())
  | Array_peek l ->
      of_val l (sprintf "ren_array_get_s(%s, %s, %s)" (a 0) (a 1) (isite ()))
  | Buf_peek (Struct (n, _)) ->
      sprintf "(*(ren_struct_%d*)ren_buf_slots(%s, %s, %s, %d, %s))" n (a 0)
        (a 1) (a 2) (struct_words n) (isite ())
  | Buf_peek l ->
      of_val l
        (sprintf "ren_buf_get_s(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (isite ()))
  | Array_get (Struct (n, false)) ->
      sprintf "(*(ren_struct_%d*)ren_array_slots_k(%s, %s, %d, %s))" n (a 0)
        (a 1) (struct_words n) (isite ())
  (* of structs that hold objects: an element counted again, and the old
     one's objects dropped where it's changed in place *)
  | Array_get (Struct (n, true)) ->
      sprintf "(*(ren_struct_%d*)ren_array_slots_dup_k(%s, %s, %d, %d, %s))" n
        (a 0) (a 1) (struct_words n) (struct_mask n) (isite ())
  | Array_set_taking (Struct (n, true)) ->
      sprintf "ren_array_set_slots_taking_ko(%s, %s, %s.s, %d, %d, %s)" (a 0)
        (a 1) (a 2) (struct_words n) (struct_mask n) (isite ())
  | Array_set (Struct _) ->
      sprintf "ren_array_set_slots(%s, %s, %s.s, %s)" (a 0) (a 1) (a 2)
        (isite ())
  | Array_push (Struct _) ->
      sprintf "ren_array_push_slots(%s, %s.s)" (a 0) (a 1)
  | Array_set_taking (Struct (n, _)) ->
      sprintf "ren_array_set_slots_taking_k(%s, %s, %s.s, %d, %s)" (a 0) (a 1)
        (a 2) (struct_words n) (isite ())
  | Array_push_taking (Struct (n, _)) ->
      sprintf "ren_array_push_slots_taking_k(%s, %s.s, %d)" (a 0) (a 1)
        (struct_words n)
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
  | Array_set_field_taking (n, k, l) ->
      sprintf "ren_array_set_field_taking%s(%s, %s, %d, %d, %s, %s)"
        (if is_object l then "_o" else "")
        (a 0) (a 1) k
        (struct_words n)
        (to_val (List.nth args 2))
        (isite ())
  | Array_own -> sprintf "ren_array_own(%s)" (a 0)
  | Array_data -> sprintf "((void*)ren_elems(%s))" (a 0)
  (* a buffer hoist.ml found: never of [Word]s, so whether its elements
     are counted is the layout's *)
  | Buf_get (Struct (n, false)) ->
      sprintf "(*(ren_struct_%d*)ren_buf_slots(%s, %s, %s, %d, %s))" n (a 0)
        (a 1) (a 2) (struct_words n) (isite ())
  | Buf_get (Struct (n, true)) ->
      sprintf "(*(ren_struct_%d*)ren_buf_slots_dup(%s, %s, %s, %d, %d, %s))" n
        (a 0) (a 1) (a 2) (struct_words n) (struct_mask n) (isite ())
  | Buf_set (Struct (n, true)) ->
      sprintf "ren_buf_set_slots_o(%s, %s, %s, %s.s, %d, %d, %s)" (a 0) (a 1)
        (a 2) (a 3) (struct_words n) (struct_mask n) (isite ())
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
  | Buf_set_field (n, k, l) ->
      sprintf "ren_buf_set_field%s(%s, %s, %s, %d, %d, %s, %s)"
        (if is_object l then "_o" else "")
        (a 0) (a 1) (a 2) k (struct_words n)
        (to_val (List.nth args 3))
        (isite ())
  | Buf_take l ->
      of_val l
        (sprintf "ren_buf_take_o(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (isite ()))
  | Buf_check -> sprintf "ren_buf_check(%s, %s, %s)" (a 0) (a 1) (site ())
  | Array_reserve (Struct (n, _)) ->
      sprintf "ren_array_reserve(%s, %d, %d)" (a 0) (struct_mask n)
        (struct_words n)
  | Array_reserve (Word _) -> sprintf "ren_array_reserve_d(%s, %s)" (a 0) (a 1)
  | Array_reserve (Sized k) ->
      sprintf "ren_array_reserve_k(%s, %s)" (a 0) (sized_kind k)
  | Array_reserve l ->
      sprintf "ren_array_reserve(%s, %b, 0)" (a 0) (is_object l)
  | Str_len -> sprintf "ren_str_len(%s)" (a 0)
  | Str_concat -> sprintf "ren_str_concat(%s, %s)" (a 0) (a 1)
  (* a debug build's report counts its site's copies; a release build's
     has none *)
  | Str_concat_taking -> (
      match site_arg with
      | Some s when not !is_release ->
          sprintf "ren_str_concat_taking(%s, %s, &ren_append_%d)" (a 0) (a 1)
            s.sid
      | _ -> sprintf "ren_str_concat_taking(%s, %s, NULL)" (a 0) (a 1))
  | Str_eq -> sprintf "ren_str_eq(%s, %s)" (a 0) (a 1)
  | Str_is s -> sprintf "ren_pat_is(%s, %s, %d)" (a 0) (c_string s) (String.length s)
  | Str_affix (p, s) ->
      sprintf "ren_pat_affix(%s, %s, %d, %s, %d)" (a 0) (c_string p)
        (String.length p) (c_string s) (String.length s)
  | Str_lookup ks ->
      sprintf "%s(ren_str_data(%s), (uint64_t)ren_str_len(%s))" (lookup ks) (a 0) (a 0)
  (* slices (ren_rt.c, "slices"): a `Str`'s and `Bytes`' are strings, a
     `Str`'s checked not to cut a character *)
  | Slice (Of_array_elems, Range) ->
      sprintf "ren_array_slice(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (site ())
  | Slice (s, Range) ->
      sprintf "ren_str_slice(%s, %s, %s, %b, %s)" (a 0) (a 1) (a 2) (s = Of_str)
        (site ())
  | Slice (Of_array_elems, Before) ->
      sprintf "ren_array_before(%s, %s, %s)" (a 0) (a 1) (site ())
  | Slice (s, Before) ->
      sprintf "ren_str_before(%s, %s, %b, %s)" (a 0) (a 1) (s = Of_str)
        (site ())
  | Slice (Of_array_elems, After) ->
      sprintf "ren_array_after(%s, %s, %s)" (a 0) (a 1) (a 2)
  | Slice (_, After) -> sprintf "ren_str_after(%s, %s)" (a 0) (a 1)
  | Splice Of_array_elems ->
      sprintf "ren_array_splice(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (a 3)
  | Splice _ -> sprintf "ren_str_splice(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (a 3)
  | Join Of_array_elems -> sprintf "ren_array_join(%s, %s)" (a 0) (a 1)
  | Join _ -> sprintf "ren_str_join(%s, %s)" (a 0) (a 1)
  | Vacant -> "ren_box(0)"
  | Str_split -> sprintf "ren_str_split(%s, %s, %s)" (a 0) (a 1) (site ())
  | Str_trim -> sprintf "ren_str_trim(%s)" (a 0)
  | Copied Of_array_elems -> sprintf "ren_array_copied(%s)" (a 0)
  | Copied _ -> sprintf "ren_str_copied(%s)" (a 0)
  | Bytes_at -> sprintf "ren_bytes_at(%s, %s, %s)" (a 0) (a 1) (isite ())
  | Str_data -> sprintf "((void*)ren_str_data(%s))" (a 0)
  | Bytes_get -> sprintf "ren_buf_byte(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (isite ())
  | Bytes_of -> sprintf "ren_bytes_of(%s, %s)" (a 0) (site ())
  (* layer 3's: the width, whether it's signed and whether it's `be` as
     constants, which clang folds the runtime's switches on *)
  | Bytes_load acc ->
      sprintf "ren_bytes_load(%s, %s, %d, %b, %b, %s)" (a 0) (a 1) acc.width
        acc.signed acc.big (site ())
  | Bytes_store acc | Bytes_store_taking acc ->
      sprintf "ren_bytes_store(%s, %s, %s, %d, %b, %b, %b, %s)" (a 0) (a 1) (a 2)
        acc.width acc.signed acc.big
        (match rt with Bytes_store_taking _ -> true | _ -> false)
        (site ())
  | Bytes_set_var signed | Bytes_set_var_taking signed ->
      sprintf "ren_bytes_set_var(%s, %s, %s, %b, %b, %s)" (a 0) (a 1) (a 2) signed
        (match rt with Bytes_set_var_taking _ -> true | _ -> false)
        (site ())
  | Bytes_zeros -> sprintf "ren_bytes_zeros(%s, %s)" (a 0) (site ())
  | Utf8_error -> sprintf "ren_utf8_error(%s)" (a 0)
  | Utf8_incomplete -> sprintf "ren_utf8_incomplete(%s, %s)" (a 0) (a 1)
  | Utf8_lossy -> sprintf "ren_utf8_lossy(%s)" (a 0)
  | U64_read big -> sprintf "ren_u64_read(%s, %s, %b, %s)" (a 0) (a 1) big (site ())
  | Var_size signed -> sprintf "ren_var_size(%s, %b, %s)" (a 0) signed (site ())
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
  (* proved not to overflow (bounds.ml), so C's signed `+`, which tells
     clang it doesn't, and which UBSan checks *)
  | Count_step -> sprintf "(%s + 1)" (a 0)
  | Bits x ->
      let o =
        match x with
        | Int_xor -> "^"
        | Int_bit_and -> "&"
        | Int_bit_or -> "|"
        | _ -> bug "a bitwise operation that isn't one"
      in
      sprintf "(%s %s %s)" (a 0) o (a 1)
  | Shift x ->
      let f =
        match x with
        | Int_shl -> "ren_shl"
        | Int_shr -> "ren_shr"
        | _ -> bug "a shift that isn't one"
      in
      sprintf "%s(%s, %s, %s)" f (a 0) (a 1) (site ())
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
  | Show_any -> sprintf "ren_show_any(%s, %s, %s)" (a 0) (w 1) (site ())
  | Equal_any what ->
      sprintf "ren_equal_any(%s, %s, %s, %s, %s)" (a 0) (w 1) (w 2)
        (c_string what) (site ())
  | Compare_any what ->
      sprintf "ren_compare_any(%s, %s, %s, %s, %s)" (a 0) (w 1) (w 2)
        (c_string what) (site ())
  | Nan_check what ->
      let y = if List.length args > 1 then a 1 else a 0 in
      sprintf "ren_nan_check(%s, %s, %s, %s)" (a 0) y (c_string what) (site ())
  | Nan_check_any what ->
      sprintf "ren_nan_in(%s, %s, %s, %s)" (a 0) (w 1) (c_string what) (site ())
  | Float_lanes -> sprintf "ren_desc_is_float(%s)" (a 0)
  | Float_sum ->
      let t = match site_arg with Some s -> tag s | None -> "0" in
      sprintf "ren_float_sum(%s, %s)" (a 0) t
  | Here_set -> sprintf "(void)(ren_here = %s)" (site ())
  | Here_get -> "(void *)ren_here"
  | Here_put -> sprintf "(void)(ren_here = (const ren_site *)%s)" (a 0)
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
      let b = if op = None then "(ren_val){0}" else w 2 in
      let t = match site_arg with Some s -> tag s | None -> "0" in
      sprintf "ren_op_any(%s, %s, %s, %s, %s, %s)" (a 0) code (w 1) b (site ()) t
  | Desc_same -> sprintf "ren_desc_same((const ren_desc*)%s, (const ren_desc*)%s)" (a 0) (a 1)
  | Value_any one -> sprintf "ren_value_any(%s, %b)" (a 0) one
  (* maps and sets (ren_rt.c, "maps and sets"): keys and values as words,
     each with its descriptor *)
  | Map_new set -> sprintf "ren_map_new(%b)" set
  | Map_len -> sprintf "ren_map_len(%s)" (a 0)
  | Map_find when svx 1 ->
      sprintf "ren_map_find_sv(%s, %s, %s, %s)" (a 0) (a 1) (a 2) (site ())
  | Map_find ->
      sprintf "ren_map_find(%s, %s, %s, %s)" (a 0) (to_val (List.nth args 1)) (a 2)
        (site ())
  (* a release build's `Str` value, two words, as the entry keeps it *)
  | Map_value (Struct _) -> sprintf "ren_map_value_sv(%s, %s)" (a 0) (a 1)
  | Map_value l -> of_val l (sprintf "ren_map_value(%s, %s)" (a 0) (a 1))
  | Map_peek (Struct _) -> sprintf "ren_map_peek_sv(%s, %s)" (a 0) (a 1)
  | Map_peek l -> of_val l (sprintf "ren_map_peek(%s, %s)" (a 0) (a 1))
  (* a release build's `Str` key or value, two words, which the entries
     keep as they are *)
  | (Map_set | Map_set_taking) when svx 1 || svx 2 ->
      let f =
        match (svx 1, svx 2) with
        | true, true -> "ren_map_set_svsv"
        | true, false -> "ren_map_set_sv"
        | _ -> "ren_map_set_vsv"
      in
      let w i = if svx i then a i else to_val (List.nth args i) in
      sprintf "%s(%s, %s, %s, %s, %s, %b, %s)" f (a 0) (w 1) (w 2) (a 3) (a 4)
        (rt = Map_set_taking) (site ())
  | (Set_add | Set_add_taking) when svx 1 ->
      sprintf "ren_map_set_sv(%s, %s, (ren_val){0}, %s, NULL, %b, %s)" (a 0)
        (a 1) (a 2) (rt = Set_add_taking) (site ())
  | Map_set | Map_set_taking ->
      sprintf "ren_map_set(%s, %s, %s, %s, %s, %b, %s)" (a 0)
        (to_val (List.nth args 1))
        (to_val (List.nth args 2))
        (a 3) (a 4) (rt = Map_set_taking) (site ())
  | Set_add | Set_add_taking ->
      sprintf "ren_map_set(%s, %s, (ren_val){0}, %s, NULL, %b, %s)" (a 0)
        (to_val (List.nth args 1))
        (a 2) (rt = Set_add_taking) (site ())
  | Map_remove | Map_remove_taking ->
      sprintf "ren_map_remove(%s, %s, %s, %b, %s)" (a 0)
        (to_val (List.nth args 1))
        (a 2) (rt = Map_remove_taking) (site ())
  | Map_of flat ->
      sprintf "ren_map_of(%s, %s, %s, %b, %s)" (a 0) (a 1) (a 2) flat (site ())
  | Set_of -> sprintf "ren_map_of(%s, %s, NULL, false, %s)" (a 0) (a 1) (site ())
  | Map_entries flat -> sprintf "ren_map_entries(%s, %b)" (a 0) flat
  | Map_keys -> sprintf "ren_map_keys(%s, %s)" (a 0) (a 1)
  | Map_values -> sprintf "ren_map_values(%s, %s)" (a 0) (a 1)
  | Hash_fixed ->
      sprintf "ren_hash_fixed(%s, %s, %s)" (a 0) (to_val (List.nth args 1)) (site ())
  | Array_sort what ->
      sprintf "ren_array_sort(%s, %s, %s, %s)" (a 0) (a 1) (c_string what) (site ())
  | Str_lower -> sprintf "ren_str_lower(%s)" (a 0)
  | Char_bound ceil ->
      sprintf "ren_char_bound(%s, %s, %s, %s)" (a 0) (a 1)
        (if ceil then "true" else "false")
        (site ())
  | Str_code -> sprintf "ren_str_code(%s, %s)" (a 0) (site ())
  | Str_of_code -> sprintf "ren_str_of_code(%s, %s)" (a 0) (site ())
  | Str_join -> sprintf "ren_strs_join(%s, %s)" (a 0) (a 1)
  | Panic_str -> sprintf "ren_panic_str(%s, %s)" (site ()) (a 0)
  | Str_find -> sprintf "ren_str_find(%s, %s)" (a 0) (a 1)
  | Str_has suffix -> sprintf "ren_str_has(%s, %s, %b)" (a 0) (a 1) suffix
  | Str_upper -> sprintf "ren_str_upper(%s)" (a 0)
  | Line_col col -> sprintf "ren_line_col(%s, %s, %b, %s)" (a 0) (a 1) col (site ())
  | Str_box | Str_unbox -> bug "a box of a string that isn't two words"
  | Str_view _ -> bug "a view of a string that isn't two words"
  | New_desc _ -> bug "a descriptor built outside a Let"

(* Whether the runtime's [rt] gives nothing, so a [Let] of it gives [Unit]
   after calling it. *)
let gives_nothing = function
  | Array_push _ | Array_push_taking _ | Bytes_store _ | Bytes_store_taking _
  | Console_write | Console_error | Array_check | Buf_set _ | Buf_set_field _ | Buf_check | Nan_check _
  | Nan_check_any _ | Here_set | Here_put | Map_set | Map_set_taking | Set_add
  | Set_add_taking | Map_remove | Map_remove_taking | Panic_str ->
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
let rhs ?result (r : rhs) =
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
  (* `/` or `%` of an [Int] by a constant other than 0 and -1: C's own,
     which can't fault or overflow then, so [ren_div]'s and [ren_rem]'s
     tests would be dead; and the constant reaches clang's lowering of a
     division by one, a multiply, as itself, where through [ren_rem]
     constant hoisting could hide it (compiler.md, "Bytes stage") *)
  | Arith (((Div | Mod) as op), x, (Int c as y), _)
    when atom_layout x = Int && c <> 0L && c <> -1L ->
      sprintf "(%s %s %s)" (atom x) (if op = Div then "/" else "%") (atom y)
  | Arith (op, x, y, s) ->
      sprintf "%s(%s, %s, %s)"
        (binop_fn op (atom_layout x))
        (atom x) (atom y) (site s)
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
          | Tagged 64 -> sprintf "%s.s[0].i" (atom x)
          | Tagged bits ->
              sprintf "((int64_t)((uint64_t)%s.s[0].i & %s))" (atom x)
                (low_bits bits)
          | Niche { obj_ctor; slot; ctors } -> (
              (* the constructors without fields, by their niches *)
              match
                List.filter (( <> ) obj_ctor)
                  (List.init ctors Fun.id)
              with
              | [] -> sprintf "INT64_C(%d)" obj_ctor
              | [ t ] ->
                  sprintf "(%s.s[%d].o == ren_box(UINT32_MAX - %d) ? %d : %d)"
                    (atom x) slot t t obj_ctor
              | ts ->
                  sprintf "ren_niche_tag(%s.s[%d].o, %d, %d)" (atom x) slot
                    obj_ctor
                    (List.fold_left max 0 ts))
          | Product -> bug "the tag of a record or a tuple")
      | _ -> sprintf "ren_tag(%s)" (atom x))
  | Obj_tag x -> sprintf "((int64_t)%s->tag)" (atom x)
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
      let call = runtime ?result rt xs s in
      if gives_nothing rt then sprintf "(%s, (ren_unit)0)" call else call
  | Load v -> sprintf "(*%s)" (var v)
  | Addr v -> sprintf "(&%s)" (var v)
  | To_word x -> to_val x
  | Of_word (x, l) -> of_val l (atom x)
  | Global name -> name
  | Block_of (f, env) -> sprintf "((ren_block){%s, %s})" f (atom env)
  | Method_of m -> (
      let x = atom m.mdesc in
      match lowering m with
      | None ->
          sprintf "((ren_block){ren_method_of(%s, %d, %d), NULL})"
            (handler_of x) m.mdep m.mop
      | Some (_, Direct h) ->
          sprintf "((ren_block){%s, NULL})"
            (match Dispatch.method_of h m.mdep m.mop with
            | Some f -> "(ren_code)" ^ f
            | None -> "NULL")
      | Some (_, Code) -> sprintf "((ren_block){(ren_code)%s, NULL})" (tag_of x)
      | Some (_, (Arms _ | Table)) ->
          sprintf "((ren_block){%s[(intptr_t)%s], NULL})"
            (method_table m.mdep m.mop) (tag_of x)
      | Some (_, Installed) -> "((ren_block){NULL, NULL})")
  | Has_code (Var v as x) when Hashtbl.mem methods v.id -> (
      let m = Hashtbl.find methods v.id in
      match !dispatch with
      | None -> sprintf "(%s.code != NULL)" (atom x)
      | Some t -> (
          match Dispatch.has_code t !dsites.(m.msite) m with
          | Some b -> if b then "true" else "false"
          | None -> (
              let d = atom m.mdesc in
              match lowering m with
              | Some (_, Arms hs) ->
                  "("
                  ^ String.concat " || "
                      (List.map
                         (fun h -> sprintf "%s == %s" (tag_of d) (htag h))
                         hs)
                  ^ ")"
              | _ ->
                  sprintf "(%s[(intptr_t)%s] != NULL)"
                    (method_table m.mdep m.mop) (tag_of d))))
  | Has_code x -> sprintf "(%s.code != NULL)" (atom x)
  | Tag_is (x, h) ->
      sprintf "(%s == %s)" (tag_of (atom x)) (atom (Handler_tag h))
  | Op_block (ev, dep, [], op) ->
      sprintf "ren_find(%s, %d)->ops[%d]" (atom ev) dep op
  | Op_block (ev, dep, args, op) ->
      (* a generic dependency's, found by its type arguments too *)
      sprintf "ren_find_args(%s, %d, (ren_obj*const[]){%s}, %d)->ops[%d]"
        (atom ev) dep
        (String.concat ", " (List.map atom args))
        (List.length args) op
  | Alloc _ | Alloc_array _ | Env_new _ | Env_get _ | Arg _ | Arg_borrowed _
  | Impl _ | Install _ | Given _ ->
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

(* ---- where in the Ren source each line of C is ----

   A debug build's C says, with `#line`, which line of Ren each of its
   lines comes from, so a debugger sets breakpoints and steps by Ren's
   lines (foundations.md, decision 13). After `#line n`, C counts on from
   [n], one a line, so the C of one Ren line is one line of C, and each
   line of C whose Ren line isn't the next one gets its own `#line`:
   [line] writes them. A statement's Ren line is its
   variable's (Mem's [fn.lines]), or its site's; one with neither is on
   the line before it. *)

(* Whether this C says where its lines are, set by [units]. *)
let line_dirs = ref false

(* The function being written's Ren lines, by variable, and its file. *)
let fn_lines : (int, int) Hashtbl.t = Hashtbl.create 64
let fn_file = ref ""

(* The Ren line of the statement being written, 0 if none is known; the
   line C would give the next line of C; and the Ren line of the line of
   C [line] wrote last, 0 if what's next can't go on it. *)
let cur_line = ref 0
let next_line = ref 0
let open_line = ref 0

let site_line (s : site) =
  if s.loc.file = !fn_file then s.loc.start.line else 0

(* The Ren line [s] is at, 0 if it doesn't say. *)
let stmt_line (s : stmt) =
  let of_rhs = function
    | Arith (_, _, _, s) | Neg (_, s) -> site_line s
    | Runtime (_, _, Some s) -> site_line s
    | _ -> 0
  in
  let of_var (v : var) r =
    match Hashtbl.find_opt fn_lines v.id with Some l -> l | None -> r ()
  in
  match s with
  | Let (v, r) -> of_var v (fun () -> of_rhs r)
  | Decl v
  | Call_fails { result = v; _ }
  | Call_block { result = v; _ }
  | Call_handler { result = v; _ } ->
      of_var v (fun () -> 0)
  | Do r -> of_rhs r
  | Assert (_, s) | Panic (s, _) -> site_line s
  | _ -> 0

(* A source file's path as a debugger finds it from anywhere. *)
let source_path file =
  if Filename.is_relative file then Filename.concat (Sys.getcwd ()) file
  else file

let line o depth s =
  if !line_dirs && !cur_line > 0 && !cur_line = !open_line then (
    (* on the line of C before, which is this one's line of Ren *)
    Buffer.truncate o.b (Buffer.length o.b - 1);
    Buffer.add_char o.b ' ';
    Buffer.add_string o.b s;
    Buffer.add_char o.b '\n')
  else (
    if !line_dirs && !cur_line > 0 then (
      if !cur_line <> !next_line then (
        Buffer.add_string o.b "#line ";
        Buffer.add_string o.b (string_of_int !cur_line);
        Buffer.add_char o.b '\n');
      next_line := !cur_line + 1;
      open_line := !cur_line);
    Buffer.add_string o.b (String.make (2 * depth) ' ');
    Buffer.add_string o.b s;
    Buffer.add_char o.b '\n')

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

(* The keys [deps] of what a `with` installs, or a block is given, as
   [name_keys]: static unless one is generic, whose type arguments' array,
   [name_args3], is the frame's, as long-lived as the evidence that
   points at it. *)
let keys line name (deps : key list) =
  let n = List.length deps in
  List.iteri
    (fun i k ->
      if k.kargs <> [] then
        line
          (sprintf "ren_obj* %s_args%d[%d] = %s;" name i (List.length k.kargs)
             (braces (List.map atom k.kargs))))
    deps;
  let static = List.for_all (fun k -> k.kargs = []) deps in
  line
    (sprintf "%sren_key %s_keys[%d] = %s;"
       (if static then "static const " else "")
       name (max 1 n)
       (braces
          (List.mapi
             (fun i k ->
               sprintf "{%d, %d, %d, %s}" k.kdep k.kfrom (List.length k.kargs)
                 (if k.kargs = [] then "NULL" else sprintf "%s_args%d" name i))
             deps)))

let rec stmt o d (s : stmt) =
  if !line_dirs then (
    let l = stmt_line s in
    if l > 0 then cur_line := l);
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
      let alloc = sprintf "ren_alloc_ctor(%d, %d, %s)" tag n objs in
      let set i x =
        line (sprintf "ren_fields(%s)[%d] = %s;" (var v) i (to_val x))
      in
      match at with
      | None ->
          line (sprintf "ren_obj* %s = %s;" (var v) alloc);
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
            (sprintf "ren_obj* %s = ren_alloc_array_n(%d, %d, %d);" (var v)
               (List.length elems) (struct_words n) (struct_mask n));
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
  | Let (v, Runtime (New_desc how, xs, _)) -> (
      let args = var v ^ "_args" in
      let n = List.length xs in
      if n > 0 then
        line
          (sprintf "ren_obj* %s[%d] = %s;" args n (braces (List.map atom xs)));
      let kind, decl =
        match how with
        | Of_decl k | Of_variant (k, _) -> ("REN_D_NAMED", sprintf "&ren_decl_%d" k)
        | Of_array -> ("REN_D_ARRAY", "NULL")
        | Of_tuple -> ("REN_D_TUPLE", "NULL")
        | Of_map -> ("REN_D_MAP", "NULL")
        | Of_set -> ("REN_D_SET", "NULL")
      in
      line
        (sprintf "ren_obj* %s = ren_desc_new(%s, %s, %d, %s);" (var v) kind decl
           n
           (if n > 0 then args else "NULL"));
      (* a variant type's is its sum's, its constructor's tag plus one its
         [var], which only [ren_desc_same] reads *)
      match how with
      | Of_variant (_, c) ->
          line (sprintf "((ren_desc*)%s)->var = %d;" (var v) (c + 1))
      | _ -> ())
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
  | Let (v, (Arg (x, n) | Arg_borrowed (x, n))) ->
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
      keys line (var v)
        (List.map (fun (d, args) -> { kdep = d; kfrom = d; kargs = args }) deps);
      line
        (sprintf "const ren_ev* %s = ren_given(%s_nodes, %s, %s, %s_keys, %d);"
           (var v) (var v) (atom outer) (atom caller) (var v) n)
  (* a buffer hoist.ml read: its elements, which a loop not moved out
     indexes where it is *)
  | Let (v, (Runtime (Array_data, _, _) as r)) ->
      line (sprintf "ren_val* %s = %s;" (var v) (rhs r))
  | Let (v, r) ->
      line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (rhs ~result:v.layout r))
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
  | Drop x -> line (sprintf "ren_drop(%s);" (atom x))
  | Dup_word (x, dsc) ->
      line (sprintf "ren_dup_val(%s, %s);" (atom x) (atom dsc))
  | Drop_word (x, dsc) ->
      line (sprintf "ren_drop_val(%s, %s);" (atom x) (atom dsc))
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
      line
        (sprintf "ren_obj* %s = %s(%s);" (var error) fn
           (String.concat ", "
              (List.map atom args @ [ "&" ^ var result ])));
      line (sprintf "if (%s != NULL) {" (var error));
      block o (d + 1) on_error;
      line "}"
  | Call_block { result; block = Var m; ev; args; error; on_error; _ }
    when !dispatch <> None && Hashtbl.mem methods m.id ->
      (* a method, lowered as dispatch.ml says *)
      let meth = Hashtbl.find methods m.id in
      let args = args_array o d (var result ^ "_args") args in
      let call f out = sprintf "%s(NULL, %s, %s, %s)" f (atom ev) args out in
      let desc = tag_of (atom meth.mdesc) in
      indirect o d ~result ~error (fun out ->
          match lowering meth with
          | Some (_, Direct h) | Some (_, Arms [ h ]) ->
              call (Option.get (Dispatch.method_of h meth.mdep meth.mop)) out
          | Some (_, Arms hs) ->
              (* compare-and-branch, the last arm the one left *)
              let rec arms = function
                | [ h ] -> call (Option.get (Dispatch.method_of h meth.mdep meth.mop)) out
                | h :: rest ->
                    sprintf "(%s == %s ? %s : %s)" desc (htag h)
                      (call (Option.get (Dispatch.method_of h meth.mdep meth.mop)) out)
                      (arms rest)
                | [] -> "NULL"
              in
              arms hs
          | Some (_, Code) -> call (sprintf "((ren_code)%s)" desc) out
          | Some (_, Table) ->
              call (sprintf "%s[(intptr_t)%s]" (method_table meth.mdep meth.mop) desc) out
          | Some (_, Installed) | None ->
              sprintf "%s.code(%s.env, %s, %s, %s)" (var m) (var m) (atom ev)
                args out);
      on_failure o d error on_error
  | Call_block { result; block = b; ev; args; error; on_error; _ } ->
      line "REN_STAT(block_calls);";
      let args = args_array o d (var result ^ "_args") args in
      indirect o d ~result ~error (fun out ->
          sprintf "%s.code(%s.env, %s, %s, %s)" (atom b) (atom b) (atom ev) args
            out);
      on_failure o d error on_error
  | Call_handler
      { result; handler; outer; body; desc; deps; error; on_error; hsite = _ }
    ->
      let n = List.length deps in
      keys line (var result) deps;
      (* a handler whose tag is its method's code finds its record by it *)
      let code =
        match (!dispatch, deps) with
        | Some t, k :: _ -> Hashtbl.mem t.code_deps k.kfrom
        | _ -> false
      in
      indirect o d ~result ~error (fun out ->
          sprintf
            "%s->install(%s, %s, %s, %s, (void*)%s_keys, %d, %s)"
            (handler_of ~code (atom handler)) (atom handler) (atom outer) (atom body) (atom desc)
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
  | Loop (l, b) when (not o.inside) && uses_buffer o b ->
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

(* A run of counts is written as one where its objects are one object,
   [ren_dup_by]: the slices of one root a record or an array is given
   (pages' key and value, logs' six fields). C merged those itself while
   a slice's root was its string's, but a slice of the 4 GiB escape has
   a root of its own (ren_rt.h, [ren_sv_view_escape]), so it can't know
   they're one. *)
and block o d b =
  let objects = function
    | Dup x when is_struct x -> Some (struct_objects ~kept:[] (atom_layout x) (atom x))
    | Dup x -> Some [ atom x ]
    | _ -> None
  in
  let rec go = function
    | [] -> ()
    | s :: _ as b when objects s <> None ->
        let rec run acc = function
          | s :: rest when objects s <> None -> run (acc @ Option.get (objects s)) rest
          | rest -> (acc, rest)
        in
        let os, rest = run [] b in
        (match os with
        | a :: (_ :: _ as others) ->
            let compared = List.filter (fun x -> x <> a) others in
            if compared = [] then
              line o d (sprintf "ren_dup_by(%s, %d);" a (List.length os))
            else
              line o d
                (sprintf "if (%s) ren_dup_by(%s, %d); else ren_dup_each(%d, %s);"
                   (String.concat " && " (List.map (fun x -> sprintf "%s == %s" x a) compared))
                   a (List.length os) (List.length os) (String.concat ", " os))
        | _ -> List.iter (fun x -> line o d (sprintf "ren_dup(%s);" x)) os);
        go rest
    | s :: rest ->
        stmt o d s;
        go rest
  in
  go b

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

(* "static " in one file; nothing in a debug build's units, whose
   functions and data are called and read from other units: set by
   [program] and [units]. *)
let linkage = ref "static "

(* With [restrict], an `inout` parameter is a `restrict` pointer: the
   only way to what it points to, which exclusivity (excl.ml) makes
   true, so C may keep what it points to in a register. *)
(* Whether a release build has C inline [f] wherever it's called: one of
   the prelude's small members, a cursor's read or `Zip.next`, with no
   loop, which isn't recursive. Rust's std marks its own `#[inline]`;
   clang's own measure leaves a function called from many places out of
   line, and a cursor's reads are each a call, an out-parameter and a
   status then, which was half of layer 3's kernel's time (compiler.md,
   "Bytes stage", "Step 2, as built"). Only where C is told, so what the
   program computes doesn't change. *)
let small_prelude (f : fn) =
  !is_release && f.loc.file = Prelude.file
  &&
  let n = ref 0 and ok = ref true in
  Rc.iter_stmts
    (fun s ->
      incr n;
      match s with
      | Loop _ | Catch _ -> ok := false
      (* one that makes a block, installs a handler or calls one is the
         program's plumbing, not a member a loop calls *)
      | Let (_, (Block_of _ | Impl _ | Install _ | Env_new _ | Method_of _ | Given _))
      | Do (Block_of _ | Impl _ | Install _ | Env_new _ | Method_of _ | Given _)
      | Call_handler _ | Call_block _ ->
          ok := false
      (* nor one that reaches the world, `print`'s path: once, at the
         end, inlining it made the function that ran a kernel too big
         for clang to inline the kernel, and pages_r 33% slower *)
      | Let (_, Runtime ((Console_write | Console_error), _, _))
      | Do (Runtime ((Console_write | Console_error), _, _)) ->
          ok := false
      | Let (_, Call (g, _)) | Do (Call (g, _)) when g = f.name -> ok := false
      | Call_fails { fn = g; _ } when g = f.name -> ok := false
      | _ -> ())
    f.body;
  !ok && !n <= 40

let signature ~restrict (f : fn) =
  let linkage =
    if !linkage <> "" && small_prelude f then
      "static REN_INLINE "
    else !linkage
  in
  let params =
    List.map
      (fun v ->
        if restrict && List.exists (fun (w : var) -> w.id = v.id) f.inout then
          ctype v.layout ^ " restrict " ^ var v
        else ctype v.layout ^ " " ^ var v)
      f.params
  in
  if f.fails then
    sprintf "%sren_obj* %s(%s)" linkage f.name
      (String.concat ", " (params @ [ ctype f.result ^ "* ren_out" ]))
  else
    sprintf "%s%s %s(%s)" linkage (ctype f.result) f.name
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

let fn ~restrict ~checks b (f : fn) =
  let bufs = Hashtbl.create 8 in
  Hashtbl.reset methods;
  Rc.iter_stmts
    (function
      | Let (v, Runtime (Array_data, _, _)) -> Hashtbl.replace bufs v.id ()
      | Let (v, Method_of m) -> Hashtbl.replace methods v.id m
      | _ -> ())
    f.body;
  let o =
    {
      b = Buffer.create 4096;
      fails = f.fails;
      catches = [];
      fname = f.name;
      bufs;
      outlined = Buffer.create 0;
      inside = false;
      restrict;
    }
  in
  (* where its Ren source is, if it has any: its lines, and the line its
     name is on, which its C function's first line is *)
  Hashtbl.reset fn_lines;
  fn_file := f.loc.file;
  let ren = !line_dirs && Filename.check_suffix f.loc.file ".ren" in
  if ren then List.iter (fun (v, l) -> Hashtbl.replace fn_lines v l) f.lines;
  cur_line := if ren then f.loc.start.line else 0;
  next_line := if ren then f.loc.start.line + 1 else 0;
  open_line := 0;
  if checks f.name then line o 1 "REN_STACK_CHECK();";
  block o 1 f.body;
  Buffer.add_buffer b o.outlined;
  (* the signature on its name's line, the body's lines on theirs *)
  if ren then
    Buffer.add_string b
      (sprintf "#line %d %s\n" f.loc.start.line (c_string (source_path f.loc.file)));
  Buffer.add_string b (signature ~restrict f ^ " {\n");
  Buffer.add_buffer b o.b;
  Buffer.add_string b "}\n\n";
  cur_line := 0;
  open_line := 0

let dkind_c (k : dkind) =
  match k with
  | D_int -> "REN_D_INT"
  | D_float -> "REN_D_FLOAT"
  | D_bool -> "REN_D_BOOL"
  | D_unit -> "REN_D_UNIT"
  | D_str -> "REN_D_STR"
  | D_bytes -> "REN_D_BYTES"
  | D_named _ | D_variant _ -> "REN_D_NAMED"
  | D_array -> "REN_D_ARRAY"
  | D_tuple -> "REN_D_TUPLE"
  | D_map -> "REN_D_MAP"
  | D_set -> "REN_D_SET"
  | D_errors -> "REN_D_ERRORS"
  | D_var _ -> "REN_D_VAR"
  | D_unknown -> "REN_D_UNKNOWN"
  | D_handler -> "REN_D_HANDLER"
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
  List.iteri (fun i _ -> add (sprintf "%sren_desc ren_desc_%d;\n" !linkage i)) descs;
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
              List.for_all (fun (_, _, ts) -> ts = []) cs,
              List.length cs,
              ctors_of cs,
              "NULL" )
        | Rep_decl r -> ("REN_DECL_REP", false, 0, "NULL", desc_ref r)
      in
      (* its own `key`, the program's function, through a wrapper that
         takes and gives words ([key_wrapper]), which the first unit
         defines *)
      let key =
        match dc.dkey with
        | Some (_, d) ->
            add (sprintf "static ren_val ren_key_%d(ren_val v);\n" i);
            sprintf "ren_key_%d, %s" i (desc_ref d)
        | None -> "NULL, NULL"
      in
      add
        (sprintf
           "%sconst ren_decl ren_decl_%d = {%s, %s, %b, %b, %d, %s, %s, %s};\n"
           !linkage i (c_string dc.dname) kind dc.dopaque enumlike nctors ctors
           rep key))
    decls;
  List.iteri
    (fun i (d : desc) ->
      let args = table (sprintf "ren_desc_%d_args" i) d.dargs in
      add
        (sprintf
           "%sren_desc ren_desc_%d = {{0, REN_TAG_DESC, 0, 0}, %s, %b, \
            %d, %s, %s, %s};\n"
           !linkage i (dkind_c d.dkind) d.dcounted (List.length d.dargs)
           (* a variable's number, a sized type's kind, or a variant type's
              constructor's tag plus one *)
           (match d.dkind with
           | D_var n -> string_of_int n
           | D_sized k -> sized_kind k
           | D_variant (_, c) -> string_of_int (c + 1)
           | _ -> "0")
           (match d.dkind with
           | D_named k | D_variant (k, _) -> sprintf "&ren_decl_%d" k
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
   each once, in [ren_text_table], which [add] is given, and each site's
   pieces as bytes, a site for all those whose bytes are the same, which
   it gives, each defined apart. Text written next to text
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
        | Help_hole (n, recv) ->
            op 7;
            leb b n;
            leb b (text recv)
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
  let decls =
    List.filter_map
      (fun (s : site) ->
        let bytes = ops (site_pieces s) in
        match Hashtbl.find_opt named bytes with
        | Some n ->
            Hashtbl.replace site_names s.sid n;
            None
        | None ->
            Hashtbl.replace named bytes s.sid;
            Hashtbl.replace site_names s.sid s.sid;
            Some
              (sprintf
                 "%sconst ren_site ren_site_%d = { (const unsigned char *)%s \
                  };\n"
                 !linkage s.sid (c_string bytes)))
      all
  in
  let texts = List.rev !text_list in
  add
    (sprintf "static const char *const ren_text_table[%d] = %s;\n"
       (max 1 (List.length texts))
       (braces
          (match texts with [] -> [ "NULL" ] | ts -> List.map c_string ts)));
  decls

(* What a program's C is made of, apart: its data, the functions, each
   as it's written, and [ren_program] and [main], which run it. *)
type parts = {
  data : string;
      (** its string literals, the texts its sites print, descriptors,
          declarations, structs and associated values *)
  site_defs : string list;  (** its sites, each defined *)
  appends : (int * string) list;
      (** a debug build's `+=` report's counts, each defined, and the site
          it points at *)
  typedefs : string;  (** its structs' C types, which all of it uses *)
  protos : (string * string) list;
      (** each function's name, and its prototype *)
  externs : (string * string) list;
      (** each associated value's name, and what declares it in another
          unit than the one [data] is in *)
  fns : (fn * string) list;  (** each function and its C *)
  lookups : (string * string) list;
      (** each perfect-hash lookup's name and its C, static: its tables
          and its function (phash.ml) *)
  run : string;  (** [ren_program] and [main] *)
}

(* The operations, each a dependency's number and its own, that some
   handler of [hs] has a method for. *)
let method_ops (hs : handler list) =
  List.sort_uniq compare
    (List.concat_map
       (fun (h : handler) -> List.map (fun (d, o, _) -> (d, o)) h.methods)
       hs)

(* The wrapper of the [i]-th declaration's `key`, the function [name],
   which the walks call with a value as a word it borrows, and which
   gives the key as a word the caller owns (ren_rt.h, [ren_key_fn]). A
   parameter the function takes is counted again first; its evidence,
   which a `key` never uses, is none. *)
let key_wrapper (fns : fn list) i name =
  let f =
    match List.find_opt (fun (f : fn) -> f.name = name) fns with
    | Some f -> f
    | None -> bug ("a `key` that isn't compiled: " ^ name)
  in
  let b = Buffer.create 256 in
  let add = Buffer.add_string b in
  add (sprintf "static ren_val ren_key_%d(ren_val v) {\n" i);
  let args =
    List.map2
      (fun (v : var) m ->
        match v.layout with
        | Ev -> "((const ren_ev*)NULL)"
        (* a release build's `Str`, which a word holds as its box *)
        | l when is_sv l ->
            if m = Owned then "ren_sv_unbox(v.o)" else "ren_sv_peek(v.o)"
        | l ->
            if m = Owned && counted l then add (sprintf "  ren_dup(v.o);\n");
            of_val l "v")
      f.params f.modes
  in
  let call = sprintf "%s(%s)" f.name (String.concat ", " args) in
  add
    (sprintf "  return %s;\n}\n"
       (if is_sv f.result then sprintf "(ren_val){.o = ren_sv_box_taking(%s)}" call
        else word_of f.result call));
  Buffer.contents b

(* Constant initializers are expanded through scalar/struct references:
   C permits address relocations here, but reading another global's value
   would turn this into executable initialization. *)
let static_definitions add (p : program) =
  let defs = Hashtbl.create 32 in
  List.iter (fun d -> Hashtbl.add defs d.sdname d) p.static_data;
  let rec scalar x = match x with
    | Static_data (n, l) -> (match (Hashtbl.find defs n).sdkind with
      | Static_scalar x -> sprintf "((%s)%s)" (ctype l) (scalar x)
      | _ -> atom x)
    | Scalar_ctor t ->
        let tag = if t < 0 then Int64.sub 0xffff_ffffL (Int64.of_int (-1-t)) else Int64.of_int t in
        sprintf "((ren_obj*)(uintptr_t)UINT64_C(%Lu))" (Int64.logor (Int64.shift_left tag 1) 1L)
    | _ -> atom x
  and word x =
    let l = atom_layout x in
    let member = match l with Boxed | Desc -> "o" | Ptr -> "p" | Float | Sized F32 -> "f" | _ -> "i" in
    sprintf "{.%s = %s}" member (scalar x)
  and fields x = match x with
    | Static_data (n, Struct _) -> (match (Hashtbl.find defs n).sdkind with
      | Static_struct xs -> xs | _ -> failwith "bug: a static struct")
    | _ -> [x]
  in
  let mask xs = List.fold_left (fun (i, m) x -> (i+1, if is_object (atom_layout x) then Int64.logor m (Int64.shift_left 1L i) else m)) (0,0L) xs |> snd in
  let word_array xs = braces (match xs with [] -> ["{.i = 0}"] | _ -> List.map word xs) in
  List.iter (fun d ->
    let n = d.sdname in
    match d.sdkind with
    | Static_string str ->
        let len = String.length str in
        add (sprintf "%sconst struct %s { ren_obj h; int64_t len; const char *data; int64_t cap; char bytes[%d]; } %s = {{0, REN_TAG_STR, 0, 0}, %d, %s.bytes, %d, %s};\n" !linkage n (len+1) n len n len (c_string str))
    | Static_object (tag, xs) ->
        let count = List.length xs in
        let m = mask xs in
        let stored = if count > 8 then xs @ [Int m] else xs in
        add (sprintf "%sconst struct %s { ren_obj h; ren_val fields[%d]; } %s = {{0, %d, %d, %Ld}, %s};\n" !linkage n (max 1 (List.length stored)) n tag count (Int64.logand m 255L) (word_array stored))
    | Static_array (elem, xs) ->
        let flattened = List.concat_map fields xs in
        let stride = match elem with Struct (i, _) -> List.length (List.nth p.structs i).sfields | _ -> 1 in
        let emask = match elem with Struct (i, _) -> struct_mask i | _ -> if is_object elem then 1 else 0 in
        let ctyp, kind, contents = match elem with
          | Sized k -> (sized_ctype k, sized_kind k, braces (match xs with [] -> ["0"] | _ -> List.map scalar xs))
          | _ -> ("ren_val", "REN_ELEM_WORD", word_array flattened) in
        add (sprintf "%sconst struct %s { ren_array a; %s data[%d]; } %s = {{{0, REN_TAG_ARRAY, %s, %d}, %d, %d, (ren_val*)%s.data, %d, NULL}, %s};\n" !linkage n ctyp (max 1 (List.length flattened)) n kind emask (List.length xs) (max 1 (List.length xs)) n stride contents)
    | Static_struct xs ->
        add (sprintf "%sconst %s %s = {%s};\n" !linkage (ctype d.sdlayout) n (word_array xs))
    | Static_scalar x ->
        add (sprintf "%sconst %s %s = %s;\n" !linkage (ctype d.sdlayout) n (scalar x))
    | Static_map {set;key;value;entries} ->
        let keysv = is_sv key and valsv = not set && is_sv value in
        let width = 1 + (if keysv then 2 else 1) + (if set then 0 else if valsv then 2 else 1) in
        let flags = (if set then 1 else 0) + (if keysv then 2 else 0) + (if valsv then 4 else 0) in
        let objs = (if counted key then 1 else 0) + (if not set && counted value then 2 else 0) in
        let xs = List.concat_map (fun (k,v) -> [Int 1L] @ fields k @ (if set then [] else fields v)) entries in
        add (sprintf "%sconst struct %s { ren_map m; ren_val entries[%d]; } %s = {{{0, REN_TAG_MAP, REN_MAP_STATIC | %d, %d}, %d, %d, %d, 0, %d, (ren_val*)%s.entries, NULL}, %s};\n" !linkage n (max 1 (List.length xs)) n flags objs (List.length entries) (List.length entries) (List.length entries) width n (word_array xs))
  ) p.static_data

let parts ~restrict ~release ~site_pieces (p : program) =
  is_release := release;
  sv := p.sv;
  numbered_tags := release;
  dispatch := if release then Some (Dispatch.make p) else None;
  dsites := Array.of_list p.dsites;
  Hashtbl.reset made_tags;
  Hashtbl.reset lookups;
  let b = Buffer.create 65536 in
  let add = Buffer.add_string b in
  List.iteri
    (fun i s ->
      let n = String.length s in
      add
        (sprintf
           "%sstruct ren_lit_%d { ren_obj h; int64_t len; const char *data; \
            int64_t cap; char bytes[%d]; } ren_lit_%d = { { 0, REN_TAG_STR, \
            0, 0 }, %d, ren_lit_%d.bytes, %d, %s };\n"
           !linkage i (n + 1) i n i n (c_string s)))
    p.strings;
  (* a [Caller] site is [ren_here], none of its own *)
  let site_defs =
    sites add ~site_pieces
      (List.filter (fun (s : site) -> s.kind <> Caller) p.sites)
  in
  (* a debug build's `+=` report: each [Appends] site's count of the
     copies made there (ren_rt.h, [ren_append]), after the sites *)
  let appends =
    if release then []
    else
      List.filter_map
        (fun (s : site) ->
          match s.kind with
          | Appends compound ->
              let named =
                Option.value (Hashtbl.find_opt site_names s.sid) ~default:s.sid
              in
              Some
                ( named,
                  sprintf
                    "%sren_append ren_append_%d = { &ren_site_%d, 0, NULL, %d, \
                     %d };\n"
                    !linkage s.sid named s.sid (Bool.to_int compound) )
          | _ -> None)
        p.sites
  in
  add
    (sprintf "static const char *const ren_tag_table[%d] = %s;\n"
       (max 1 (List.length p.tags))
       (braces
          (match p.tags with [] -> [ "NULL" ] | ts -> List.map c_string ts)));
  static_types add p.descs p.decls;
  (* the handlers' records, declared here, since the functions use their
     tags, and defined with [run], after the functions they point at *)
  (match p.handlers with
  | [] -> ()
  | hs when release ->
      add (sprintf "static const ren_handler ren_handlers[%d];\n" (List.length hs));
      (* each operation's table of methods, by tag, and how a tag that's
         code finds its record (dispatch.ml) *)
      List.iter
        (fun (dep, op) ->
          add
            (sprintf "static const ren_code %s[%d];\n" (method_table dep op)
               (List.length hs)))
        (method_ops hs);
      if Hashtbl.length (Option.get !dispatch).code > 0 then
        add "static const ren_handler *ren_handler_by_code(void *code);\n"
  | hs ->
      List.iter
        (fun (h : handler) ->
          add (sprintf "%sconst ren_handler ren_handler_%d;\n" !linkage h.hid))
        hs);
  structs := Array.of_list p.structs;
  (* each struct, a word for each slot, as an array of structs keeps it *)
  let typedefs =
    String.concat ""
      (List.mapi
         (fun n st ->
           if p.sv = Some n then sprintf "typedef ren_sv ren_struct_%d;\n" n
           else
             sprintf "typedef struct { ren_val s[%d]; } ren_struct_%d;\n"
               (max 1 (List.length st.sfields))
               n)
         p.structs)
  in
  List.iter
    (fun (v : value) ->
      add (sprintf "%s%s %s;\n" !linkage (ctype v.vlayout) v.vname))
    p.values;
  static_definitions add p;
  let data = Buffer.contents b in
  let protos =
    List.map (fun (f : fn) -> (f.name, signature ~restrict f ^ ";\n")) p.fns
  in
  let unchecked = unchecked p.fns in
  let checks name = not (Hashtbl.mem unchecked name) in
  let fns =
    List.map
      (fun (f : fn) ->
        let b = Buffer.create 4096 in
        fn ~restrict ~checks b f;
        (f, Buffer.contents b))
      p.fns
  in
  let b = Buffer.create 4096 in
  let add = Buffer.add_string b in
  List.iteri
    (fun i (dc : decl) ->
      match dc.dkey with
      | Some (name, _) -> add (key_wrapper p.fns i name)
      | None -> ())
    p.decls;
  let record (h : handler) =
    sprintf "{%d, %d, %s, %s, %d, %s}" h.hid h.hwords (c_string h.hname)
      (if h.install = "" then "NULL" else "(ren_hcode)" ^ h.install)
      (List.length h.methods)
      (if h.methods = [] then "NULL" else sprintf "ren_methods_%d" h.hid)
  in
  List.iter
    (fun (h : handler) ->
      if h.methods <> [] then
        add
          (sprintf "static const ren_method ren_methods_%d[%d] = %s;\n" h.hid
             (List.length h.methods)
             (braces
                (List.map
                   (fun (d, op, f) -> sprintf "{%d, %d, (ren_code)%s}" d op f)
                   h.methods))))
    p.handlers;
  (match p.handlers with
  | [] -> ()
  | hs when release ->
      add
        (sprintf "static const ren_handler ren_handlers[%d] = %s;\n"
           (List.length hs) (braces (List.map record hs)));
      List.iter
        (fun (dep, op) ->
          add
            (sprintf "static const ren_code %s[%d] = %s;\n" (method_table dep op)
               (List.length hs)
               (braces
                  (List.map
                     (fun h ->
                       match Dispatch.method_of h dep op with
                       | Some f -> "(ren_code)" ^ f
                       | None -> "NULL")
                     hs))))
        (method_ops hs);
      if Hashtbl.length (Option.get !dispatch).code > 0 then
        add
          (sprintf
             "static const ren_handler *ren_handler_by_code(void *code) {\n\
             \  for (int i = 0; i < %d; i++)\n\
             \    if (ren_handlers[i].nmethods == 1 && (void*)ren_handlers[i].methods[0].code == code)\n\
             \      return &ren_handlers[i];\n\
             \  return NULL;\n\
              }\n"
             (List.length hs))
  | hs ->
      List.iter
        (fun (h : handler) ->
          add
            (sprintf "%sconst ren_handler ren_handler_%d = %s;\n" !linkage
               h.hid (record h)))
        hs);
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
  if p.start_result <> Unit then
    add
      (sprintf
         "  ren_print_result((ren_obj*)&ren_desc_%d, %s, ren_overflow_site);\n"
         p.start_desc
         (word_of p.start_result "r"));
  if is_object p.start_result then add "  ren_drop(r);\n";
  if is_sv p.start_result then add "  ren_drop(r.s[0].o);\n";
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
  let externs =
    List.map
      (fun (v : value) ->
        (v.vname, sprintf "extern %s %s;\n" (ctype v.vlayout) v.vname))
      p.values
  in
  {
    data;
    site_defs;
    appends;
    typedefs;
    protos;
    externs;
    fns;
    lookups = lookup_defs ();
    run = Buffer.contents b;
  }

(* The C file for [p]. [site_pieces] is what a panic at a site prints,
   with a [Hole] where its message goes. *)
let program ?(restrict = false) ?(release = false)
    ~(site_pieces : site -> Diag.piece list) (p : program) =
  linkage := "static ";
  line_dirs := false;
  let ps = parts ~restrict ~release ~site_pieces p in
  let b = Buffer.create 65536 in
  let add = Buffer.add_string b in
  (* a release build's `Str` and `Bytes` are two words (ren_rt.h,
     "representation B"), and the runtime's arrays and walks of them know *)
  if p.sv <> None then add "#define REN_SV 1\n";
  add Runtime_c.header;
  add "\n";
  add Runtime_c.source;
  add "\n/* ---- the program ---- */\n\n";
  add ps.typedefs;
  List.iter (fun (_, proto) -> add proto) ps.protos;
  add ps.data;
  List.iter add ps.site_defs;
  List.iter (fun (_, d) -> add d) ps.appends;
  add "\n";
  add "\n";
  List.iter (fun (_, c) -> add c) ps.lookups;
  List.iter (fun (_, c) -> add c) ps.fns;
  add ps.run;
  Buffer.contents b

(* ---- a debug build's units ---- *)

let per_job = 4
let min_unit = 65536

type units = {
  header : string;  (** ren_rt.h *)
  runtime : string;  (** the runtime's unit, ren_rt.c *)
  program : (string * string) list;
      (** the program's units, each a name and its C, the first holding its
          data and [main] *)
}

(* The C identifiers in [s] that start with [ren_], as every name of the
   program's does, each once, in the order they're first in it. *)
let identifiers s =
  let seen = Hashtbl.create 256 and acc = ref [] in
  let n = String.length s in
  let is_part = function
    | 'a' .. 'z' | 'A' .. 'Z' | '_' | '0' .. '9' -> true
    | _ -> false
  in
  let i = ref 0 in
  while !i < n do
    if is_part (String.unsafe_get s !i) then (
      let j = ref (!i + 1) in
      while !j < n && is_part (String.unsafe_get s !j) do
        incr j
      done;
      if
        !j - !i > 4
        && s.[!i] = 'r'
        && s.[!i + 1] = 'e'
        && s.[!i + 2] = 'n'
        && s.[!i + 3] = '_'
      then (
        let id = String.sub s !i (!j - !i) in
        if not (Hashtbl.mem seen id) then (
          Hashtbl.replace seen id ();
          acc := id :: !acc));
      i := !j)
    else incr i
  done;
  List.rev !acc

(* A debug build's C (foundations.md, decision 13): ren_rt.h, the
   runtime's unit, and the program in units of a module's functions or a
   few modules', about [per_job] for each of [jobs] that compile them in
   parallel. A unit
   includes no system header (ren_rt.h, REN_UNIT) and declares only what
   it uses of the others: the functions it calls, and the data it reads,
   which the first unit defines. Its lines say which Ren lines they come
   from. *)
let units ~jobs ~(site_pieces : site -> Diag.piece list) (p : program) =
  linkage := "";
  line_dirs := true;
  let ps = parts ~restrict:false ~release:false ~site_pieces p in
  line_dirs := false;
  linkage := "static ";
  (* what declares each thing a unit may use of the others *)
  let decls = Hashtbl.create 4096 in
  List.iter (fun (name, d) -> Hashtbl.replace decls name d) ps.protos;
  List.iter (fun (name, d) -> Hashtbl.replace decls name d) ps.externs;
  List.iter (fun d ->
    let decl = match d.sdlayout with
      | Boxed | Desc -> sprintf "extern const struct %s %s;\n" d.sdname d.sdname
      | l -> sprintf "extern const %s %s;\n" (ctype l) d.sdname in
    Hashtbl.replace decls d.sdname decl) p.static_data;
  List.iteri
    (fun i _ ->
      let n = sprintf "ren_lit_%d" i in
      Hashtbl.replace decls n (sprintf "extern struct %s %s;\n" n n))
    p.strings;
  List.iter
    (fun (s : site) ->
      let n = sprintf "ren_site_%d" s.sid in
      Hashtbl.replace decls n (sprintf "extern const ren_site %s;\n" n))
    p.sites;
  List.iter
    (fun (s : site) ->
      let n = sprintf "ren_append_%d" s.sid in
      Hashtbl.replace decls n (sprintf "extern ren_append %s;\n" n))
    p.sites;
  List.iteri
    (fun i _ ->
      let n = sprintf "ren_desc_%d" i in
      Hashtbl.replace decls n (sprintf "extern ren_desc %s;\n" n))
    p.descs;
  List.iter
    (fun (h : handler) ->
      let n = sprintf "ren_handler_%d" h.hid in
      Hashtbl.replace decls n (sprintf "extern const ren_handler %s;\n" n))
    p.handlers;
  List.iteri
    (fun i _ ->
      let n = sprintf "ren_decl_%d" i in
      Hashtbl.replace decls n (sprintf "extern const ren_decl %s;\n" n))
    p.decls;
  (* a lookup is static, its own in each unit that uses it *)
  List.iter (fun (n, c) -> Hashtbl.replace decls n c) ps.lookups;
  let unit body =
    let b = Buffer.create (String.length body + 4096) in
    Buffer.add_string b "#define REN_UNIT\n#include \"ren_rt.h\"\n\n";
    Buffer.add_string b ps.typedefs;
    List.iter
      (fun id ->
        match Hashtbl.find_opt decls id with
        | Some d -> Buffer.add_string b d
        | None -> ())
      (identifiers body);
    Buffer.add_string b "\n";
    Buffer.add_string b body;
    Buffer.contents b
  in
  (* the first unit: the data, then what runs the program *)
  let first =
    let b = Buffer.create 65536 in
    Buffer.add_string b "#define REN_UNIT\n#include \"ren_rt.h\"\n\n";
    Buffer.add_string b ps.typedefs;
    List.iter (fun (_, proto) -> Buffer.add_string b proto) ps.protos;
    Buffer.add_string b ps.data;
    List.iter
      (fun id ->
        match Hashtbl.find_opt decls id with
        | Some d -> Buffer.add_string b d
        | None -> ())
      (identifiers ps.run);
    Buffer.add_string b "\n";
    Buffer.add_string b ps.run;
    Buffer.contents b
  in
  (* the functions, a file's together, those without Ren source (the
     prelude's) first in each unit, so no `#line` is in force over them,
     cut into units of about [size] bytes of them *)
  let files = ref [] and by_file = Hashtbl.create 64 in
  List.iter
    (fun (((f : fn), _) as x) ->
      match Hashtbl.find_opt by_file f.loc.file with
      | Some xs -> Hashtbl.replace by_file f.loc.file (x :: xs)
      | None ->
          files := f.loc.file :: !files;
          Hashtbl.replace by_file f.loc.file [ x ])
    ps.fns;
  let ordered =
    List.concat_map
      (fun file -> List.rev (Hashtbl.find by_file file))
      (List.rev !files)
  in
  (* [per_job] units for each job that compiles them, so a unit that
     takes longer than the rest doesn't leave the others waiting, but
     none so small it's mostly ren_rt.h *)
  let total = List.fold_left (fun n (_, c) -> n + String.length c) 0 ps.fns in
  let size = max min_unit (total / (per_job * max 1 jobs)) in
  let chunks = ref [] and cur = ref [] and bytes = ref 0 in
  let cut () =
    if !cur <> [] then chunks := List.rev !cur :: !chunks;
    cur := [];
    bytes := 0
  in
  List.iter
    (fun ((f : fn), c) ->
      cur := (f, c) :: !cur;
      bytes := !bytes + String.length c;
      if !bytes >= size then cut ())
    ordered;
  cut ();
  (* the sites, which are most of a program's data, in units of their
     own, of about [size] bytes too *)
  let site_units = ref [] and cur = ref [] and bytes = ref 0 in
  let cut () =
    if !cur <> [] then site_units := String.concat "" (List.rev !cur) :: !site_units;
    cur := [];
    bytes := 0
  in
  List.iter
    (fun d ->
      cur := d :: !cur;
      bytes := !bytes + String.length d;
      if !bytes >= size then cut ())
    ps.site_defs;
  cut ();
  let body chunk =
    let plain, lined =
      List.partition
        (fun ((f : fn), _) -> not (Filename.check_suffix f.loc.file ".ren"))
        chunk
    in
    String.concat "" (List.map snd (plain @ lined))
  in
  {
    header = Runtime_c.header;
    runtime = "#include \"ren_rt.h\"\n\n" ^ Runtime_c.source;
    program =
      ("ren_main", first)
      :: List.mapi
           (fun i chunk -> (sprintf "ren_u%d" i, unit (body chunk)))
           (List.rev !chunks)
      @ List.mapi
          (fun i defs ->
            ( sprintf "ren_s%d" i,
              "#define REN_UNIT\n#include \"ren_rt.h\"\n\n" ^ defs ))
          (List.rev !site_units)
      (* the report's counts, a unit of their own, which declares the
         sites they point at *)
      @
      match ps.appends with
      | [] -> []
      | xs ->
          [
            ( "ren_appends",
              "#define REN_UNIT\n#include \"ren_rt.h\"\n\n"
              ^ String.concat ""
                  (List.map
                     (fun n -> sprintf "extern const ren_site ren_site_%d;\n" n)
                     (List.sort_uniq compare (List.map fst xs)))
              ^ String.concat "" (List.map snd xs) );
          ];
  }
