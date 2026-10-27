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

let zero (l : layout) =
  match l with
  | Int | Unit | Enum -> "0"
  | Float -> "0.0"
  | Bool -> "false"
  | Boxed | Desc | Cell _ | Ev | Ptr | Token -> "NULL"
  | Word _ -> "(ren_val){0}"
  | Block -> "(ren_block){0}"

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

let var (v : var) =
  let name =
    String.concat ""
      (List.map (String.make 1)
         (List.filter
            (function
              | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
            (List.of_seq (String.to_seq v.name))))
  in
  sprintf "v%d_%s" v.id name

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
  | Block | Cell _ | Token -> bug "a block, a cell or a token as a word"

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
  | Block | Cell _ | Token -> bug "a word as a block, a cell or a token"

let site (s : site) = sprintf "&ren_site_%d" s.sid

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

let runtime rt args site_arg =
  let a i = atom (List.nth args i) in
  let site () =
    match site_arg with
    | Some s -> site s
    | None -> bug "a runtime call that panics without a site"
  in
  match rt with
  | Array_len -> sprintf "ren_array_len(%s)" (a 0)
  | Array_get l ->
      of_val l (sprintf "ren_array_get(%s, %s, %s)" (a 0) (a 1) (site ()))
  | Array_set _ ->
      sprintf "ren_array_set(%s, %s, %s, %s)" (a 0) (a 1)
        (to_val (List.nth args 2))
        (site ())
  | Array_push _ ->
      sprintf "ren_array_push(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Array_set_taking _ ->
      sprintf "ren_array_set_taking(%s, %s, %s, %s)" (a 0) (a 1)
        (to_val (List.nth args 2))
        (site ())
  | Array_push_taking _ ->
      sprintf "ren_array_push_taking(%s, %s)" (a 0) (to_val (List.nth args 1))
  | Str_len -> sprintf "ren_str_len(%s)" (a 0)
  | Str_concat -> sprintf "ren_str_concat(%s, %s)" (a 0) (a 1)
  | Str_eq -> sprintf "ren_str_eq(%s, %s)" (a 0) (a 1)
  | Show_int -> sprintf "ren_show_int(%s)" (a 0)
  | Show_float -> sprintf "ren_show_float(%s)" (a 0)
  | Show_bool -> sprintf "ren_show_bool(%s)" (a 0)
  | Float_of_int -> sprintf "((double)%s)" (a 0)
  | Float_sqrt -> sprintf "ren_fsqrt(%s, %s)" (a 0) (site ())
  | Float_round -> sprintf "ren_fround(%s, %s)" (a 0) (site ())
  | Float_truncate -> sprintf "ren_ftruncate(%s, %s)" (a 0) (site ())
  | Wrapping op ->
      let o = match op with Add -> "+" | Sub -> "-" | _ -> "*" in
      sprintf "((int64_t)((uint64_t)%s %s (uint64_t)%s))" (a 0) o (a 1)
  | Wrapping_neg -> sprintf "((int64_t)(0 - (uint64_t)%s))" (a 0)
  | Console_write -> sprintf "ren_console_write(%s)" (a 0)
  | Console_error -> sprintf "ren_console_error(%s)" (a 0)
  | Show_any -> sprintf "ren_show_any(%s, %s)" (a 0) (a 1)
  | Equal_any -> sprintf "ren_equal_any(%s, %s, %s)" (a 0) (a 1) (a 2)
  | Compare_any -> sprintf "ren_compare_any(%s, %s, %s)" (a 0) (a 1) (a 2)
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
      sprintf "ren_op_any(%s, %s, %s, %s, %s)" (a 0) code (a 1) b (site ())
  | Value_any one -> sprintf "ren_value_any(%s, %b)" (a 0) one
  | New_desc _ -> bug "a descriptor built outside a Let"

(* Whether the runtime's [rt] gives nothing, so a [Let] of it gives [Unit]
   after calling it. *)
let gives_nothing = function
  | Array_push _ | Array_push_taking _ | Console_write | Console_error -> true
  | _ -> false

(* The slots a [Free] or a [Reset] keeps, as a mask of bits. *)
let mask kept =
  match kept with
  | [] -> "0u"
  | _ ->
      String.concat " | "
        (List.map (fun (n, _) -> sprintf "%uu" (1 lsl n)) kept)

(* What [r] computes, as a C expression; an [Alloc] is statements of its
   own ([stmt]). *)
let rhs (r : rhs) =
  match r with
  | Atom x -> atom x
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
      | _ -> sprintf "ren_tag(%s)" (atom x))
  | Field (x, n, _) ->
      failwith (sprintf "bug: emit_c: a field %s.%d outside a Let" (atom x) n)
  | Is_unique x -> sprintf "ren_is_unique(%s)" (atom x)
  | Reset (x, kept) -> sprintf "ren_reset(%s, %s)" (atom x) (mask kept)
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

type out = { b : Buffer.t; fails : bool; mutable catches : (int * var) list }

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
  | Let (v, Alloc { tag; fields; words; at }) -> (
      (* a bit for each field that holds an object: one that always does,
         or a word whose descriptor says it does *)
      let words = ref words in
      let bits =
        List.concat
          (List.mapi
             (fun i x ->
               match atom_layout x with
               | l when is_object l -> [ sprintf "%uu" (1 lsl i) ]
               | Word _ -> (
                   match !words with
                   | w :: rest ->
                       words := rest;
                       [
                         sprintf "(ren_desc_counted(%s) ? %uu : 0u)" (atom w)
                           (1 lsl i);
                       ]
                   | [] -> bug "a word with no descriptor")
               | _ -> [])
             fields)
      in
      let objs = match bits with [] -> "0" | _ -> String.concat " | " bits in
      let alloc =
        sprintf "ren_alloc_ctor(%d, %d, %s)" tag (List.length fields) objs
      in
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
            (sprintf "ren_obj* %s = %s != NULL ? ren_reuse(%s, %d, %s) : %s;"
               (var v) (atom t) (atom t) tag objs alloc);
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
  | Let (v, Alloc_array { elem; elems; desc }) ->
      let boxed =
        match desc with
        | Some d -> sprintf "ren_desc_counted(%s)" (atom d)
        | None -> string_of_bool (is_object elem)
      in
      line
        (sprintf "ren_obj* %s = ren_alloc_array(%d, %s);" (var v)
           (List.length elems) boxed);
      List.iteri
        (fun i x ->
          line (sprintf "ren_elems(%s)[%d] = %s;" (var v) i (to_val x)))
        elems
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
  | Let (v, r) -> line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (rhs r))
  | Decl v ->
      line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (zero v.layout))
  | Set (v, x) -> line (sprintf "%s = %s;" (var v) (atom x))
  | Store (v, x) -> line (sprintf "*%s = %s;" (var v) (atom x))
  | Dup x -> line (sprintf "ren_dup(%s);" (atom x))
  | Drop x -> line (sprintf "ren_drop(%s);" (atom x))
  | Dup_word (x, dsc) ->
      line (sprintf "ren_dup_val(%s, %s);" (atom x) (atom dsc))
  | Drop_word (x, dsc) ->
      line (sprintf "ren_drop_val(%s, %s);" (atom x) (atom dsc))
  | Free (x, kept) ->
      line (sprintf "ren_free_keeping(%s, %s);" (atom x) (mask kept))
  | Free_token x -> line (sprintf "ren_free_token(%s);" (atom x))
  | Do (Runtime (rt, xs, s)) -> line (sprintf "%s;" (runtime rt xs s))
  | Do r -> line (sprintf "(void)%s;" (rhs r))
  | Call_fails { result; fn; args; error; on_error } ->
      line
        (sprintf "%s %s = %s;" (ctype result.layout) (var result)
           (zero result.layout));
      line
        (sprintf "ren_obj* %s = %s(%s);" (var error) fn
           (String.concat ", " (List.map atom args @ [ "&" ^ var result ])));
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

(* What an indirect call does if it failed. *)
and on_failure o d error on_error =
  match on_error with
  | Some b ->
      line o d (sprintf "if (%s != NULL) {" (var error));
      block o (d + 1) b;
      line o d "}"
  | None -> line o d (sprintf "(void)%s;" (var error))

let signature (f : fn) =
  let params = List.map (fun v -> ctype v.layout ^ " " ^ var v) f.params in
  if f.fails then
    sprintf "static ren_obj* %s(%s)" f.name
      (String.concat ", " (params @ [ ctype f.result ^ "* ren_out" ]))
  else
    sprintf "static %s %s(%s)" (ctype f.result) f.name
      (match params with [] -> "void" | ps -> String.concat ", " ps)

let fn b (f : fn) =
  let o = { b; fails = f.fails; catches = [] } in
  Buffer.add_string b (signature f ^ " {\n");
  line o 1 "REN_STACK_CHECK();";
  block o 1 f.body;
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
        sprintf "{%s, %d, %s, %s}" (c_string name) nfields names types
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
           "static ren_desc ren_desc_%d = {{0, 0, REN_DESC, 0, 0, 0}, %s, %b, \
            %d, %d, %s, %s};\n"
           i (dkind_c d.dkind) d.dcounted (List.length d.dargs)
           (match d.dkind with D_var n -> n | _ -> 0)
           (match d.dkind with
           | D_named k -> sprintf "&ren_decl_%d" k
           | _ -> "NULL")
           args))
    descs

(* The C file for [p]. [site_text] is what's printed before and after the
   message of a panic at a site. *)
let program ~(site_text : site -> string * string) (p : program) =
  let b = Buffer.create 65536 in
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
            ren_lit_%d = { { 0, 0, REN_STR, 0, 0, 0 }, %d, %s };\n"
           (n + 1) i n (c_string s)))
    p.strings;
  List.iter
    (fun (s : site) ->
      let before, after = site_text s in
      add
        (sprintf "static const ren_site ren_site_%d = { %s, %s };\n" s.sid
           (c_string before) (c_string after)))
    p.sites;
  add
    (sprintf "static const char *const ren_tag_table[%d] = %s;\n"
       (max 1 (List.length p.tags))
       (braces
          (match p.tags with [] -> [ "NULL" ] | ts -> List.map c_string ts)));
  static_types add p.descs p.decls;
  List.iter
    (fun (v : value) ->
      add (sprintf "static %s %s;\n" (ctype v.vlayout) v.vname))
    p.values;
  add "\n";
  List.iter (fun f -> add (signature f ^ ";\n")) p.fns;
  add "\n";
  List.iter (fn b) p.fns;
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
      (sprintf "  ren_print_value(stdout, (ren_obj*)&ren_desc_%d, %s);\n"
         p.start_desc
         (word_of p.start_result "r"));
    add "  fputc('\\n', stdout);\n");
  if is_object p.start_result then add "  ren_drop(r);\n";
  List.iter
    (fun (v : value) ->
      if is_object v.vlayout then add (sprintf "  ren_drop(%s);\n" v.vname))
    (List.rev p.values);
  add "}\n\n";
  add "int main(void) {\n";
  add (sprintf "  ren_overflow_site = &ren_site_%d;\n" p.overflow.sid);
  add "  ren_tag_names = ren_tag_table;\n";
  add "  return ren_run(ren_program);\n}\n";
  Buffer.contents b
