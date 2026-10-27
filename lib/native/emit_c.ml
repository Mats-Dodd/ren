(* Mem IR to C: one file, the runtime (ren_rt.h and ren_rt.c, embedded
   as Runtime_c) first, then the program (compiler.md, "Native slice").

   Each Mem function is a C function, and each variable a C local. A
   function that can fail returns its error, or NULL, and writes its
   value through a last parameter, [ren_out]. Control that isn't an `if`
   or a `switch` is a `goto`: a [Break] to the end of its loop, a [Raise]
   to its [Catch]'s handler, and a [Jump] to a join point, so none of
   them depends on which C statement it's inside. *)

open Mem

let sprintf = Printf.sprintf

let rec ctype (l : layout) =
  match l with
  | Int -> "int64_t"
  | Float -> "double"
  | Bool -> "bool"
  | Unit -> "ren_unit"
  | Enum -> "uint32_t"
  | Boxed -> "ren_obj*"
  | Cell l -> ctype l ^ "*"

let zero (l : layout) =
  match l with
  | Int | Unit | Enum -> "0"
  | Float -> "0.0"
  | Bool -> "false"
  | Boxed | Cell _ -> "NULL"

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

(* The member of a [ren_val] a value of [l] is kept in. *)
let member (l : layout) = match l with Float -> "f" | Boxed -> "o" | _ -> "i"

(* [x] as a [ren_val]. *)
let to_val (x : atom) =
  let l = atom_layout x in
  match l with
  | Float | Boxed -> sprintf "(ren_val){.%s = %s}" (member l) (atom x)
  | _ -> sprintf "(ren_val){.i = (int64_t)%s}" (atom x)

(* A [ren_val], [v], as a value of [l]. *)
let of_val l v =
  match (l : layout) with
  | Float | Boxed -> sprintf "%s.%s" v (member l)
  | Int -> sprintf "%s.i" v
  | _ -> sprintf "(%s)%s.i" (ctype l) v

let site (s : site) = sprintf "&ren_site_%d" s.sid

let binop_fn (op : Ast.binop) (l : layout) =
  let name =
    match op with
    | Add -> "add"
    | Sub -> "sub"
    | Mul -> "mul"
    | Div -> "div"
    | Mod -> "rem"
    | _ -> failwith "bug: emit_c: an arithmetic operator that isn't one"
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
    | None -> failwith "bug: emit_c: a runtime call that panics without a site"
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

(* Whether the runtime's [rt] gives nothing, so a [Let] of it gives [Unit]
   after calling it. *)
let gives_nothing = function
  | Array_push _ | Console_write | Console_error -> true
  | _ -> false

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
  | Field (x, n) ->
      failwith (sprintf "bug: emit_c: a field %s.%d outside a Let" (atom x) n)
  | Call (f, xs) -> sprintf "%s(%s)" f (String.concat ", " (List.map atom xs))
  | Runtime (rt, xs, s) ->
      let call = runtime rt xs s in
      if gives_nothing rt then sprintf "(%s, (ren_unit)0)" call else call
  | Load v -> sprintf "(*%s)" (var v)
  | Addr v -> sprintf "(&%s)" (var v)
  | Alloc _ | Alloc_array _ ->
      failwith "bug: emit_c: an allocation outside a Let"

type out = { b : Buffer.t; fails : bool; mutable catches : (int * var) list }

let line o depth s =
  Buffer.add_string o.b (String.make (2 * depth) ' ');
  Buffer.add_string o.b s;
  Buffer.add_char o.b '\n'

let rec stmt o d (s : stmt) =
  let line = line o d in
  match s with
  | Let (v, Field (x, n)) ->
      line
        (sprintf "%s %s = %s;" (ctype v.layout) (var v)
           (of_val v.layout (sprintf "ren_fields(%s)[%d]" (atom x) n)))
  | Let (v, Alloc { tag; fields; nobjs }) ->
      line
        (sprintf "ren_obj* %s = ren_alloc_ctor(%d, %d, %d);" (var v) tag
           (List.length fields) nobjs);
      List.iteri
        (fun i x ->
          let l = atom_layout x in
          line
            (sprintf "ren_fields(%s)[%d].%s = %s;" (var v) i (member l)
               (match l with
               | Float | Boxed -> atom x
               | _ -> sprintf "(int64_t)%s" (atom x))))
        fields
  | Let (v, Alloc_array (l, xs)) ->
      line
        (sprintf "ren_obj* %s = ren_alloc_array(%d, %b);" (var v)
           (List.length xs) (counted l));
      List.iteri
        (fun i x ->
          line (sprintf "ren_elems(%s)[%d] = %s;" (var v) i (to_val x)))
        xs
  | Let (v, r) -> line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (rhs r))
  | Decl v ->
      line (sprintf "%s %s = %s;" (ctype v.layout) (var v) (zero v.layout))
  | Set (v, x) -> line (sprintf "%s = %s;" (var v) (atom x))
  | Store (v, x) -> line (sprintf "*%s = %s;" (var v) (atom x))
  | Dup x -> line (sprintf "ren_dup(%s);" (atom x))
  | Drop x -> line (sprintf "ren_drop(%s);" (atom x))
  | Free x -> line (sprintf "ren_free(%s);" (atom x))
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

(* How `ren run` shows [x], a C expression of a value shown [s], to the
   stream [out]: [Str] in quotes. *)
let show_to out (s : shown) x =
  match s with
  | Shows_int -> sprintf "fprintf(%s, \"%%\" PRId64, %s);" out x
  | Shows_float ->
      sprintf "{ char buf[400]; ren_format_float(buf, %s); fputs(buf, %s); }" x
        out
  | Shows_bool -> sprintf "fputs(%s ? \"true\" : \"false\", %s);" x out
  | Shows_str -> sprintf "ren_print_quoted(%s, %s);" out x
  | Shows_unit -> sprintf "fputs(\"()\", %s);" out

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
  add "\n";
  List.iter (fun f -> add (signature f ^ ";\n")) p.fns;
  add "\n";
  List.iter (fn b) p.fns;
  (* what `main` failed with, as `ren run` says it *)
  add "static _Noreturn void ren_uncaught(ren_obj* e) {\n";
  add
    "  fflush(stdout);\n\
    \  fputs(\"error: \", stderr);\n\
    \  switch (ren_tag(e)) {\n";
  List.iter
    (fun (tag, name, payload) ->
      add (sprintf "  case %d:\n    fputs(%s, stderr);\n" tag (c_string name));
      if payload <> [] then (
        add "    fputs(\"(\", stderr);\n";
        List.iteri
          (fun i (slot, s) ->
            if i > 0 then add "    fputs(\", \", stderr);\n";
            let l : layout =
              match s with
              | Shows_float -> Float
              | Shows_str -> Boxed
              | _ -> Int
            in
            add
              (sprintf "    %s\n"
                 (show_to "stderr" s
                    (of_val l (sprintf "ren_fields(e)[%d]" slot)))))
          payload;
        add "    fputs(\")\", stderr);\n");
      add "    break;\n")
    p.errors;
  add "  }\n  fputs(\"\\n\", stderr);\n  exit(1);\n}\n\n";
  add "static void ren_program(void) {\n";
  if p.start_fails then (
    add (sprintf "  %s r = %s;\n" (ctype p.start_result) (zero p.start_result));
    add (sprintf "  ren_obj* e = %s(&r);\n" p.start);
    add "  if (e != NULL) ren_uncaught(e);\n")
  else add (sprintf "  %s r = %s();\n" (ctype p.start_result) p.start);
  if p.prints <> Shows_unit then (
    add (sprintf "  %s\n" (show_to "stdout" p.prints "r"));
    add "  fputc('\\n', stdout);\n");
  if counted p.start_result then add "  ren_drop(r);\n";
  add "}\n\n";
  add "int main(void) {\n";
  add (sprintf "  ren_overflow_site = &ren_site_%d;\n" p.overflow.sid);
  add "  return ren_run(ren_program);\n}\n";
  Buffer.contents b
