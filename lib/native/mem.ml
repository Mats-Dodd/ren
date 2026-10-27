(* Mem IR: the program as the native backend sees it, made from Core by
   to_mem.ml, checked by mem_lint.ml, and written out as C by emit_c.ml
   (compiler.md, "Native slice").

   It's in A-normal form: every operand is an [atom], a variable or a
   constant, and anything that computes something is a statement that
   puts its result in a fresh variable. So the order things happen in is
   the order of the statements, and every intermediate value has a name
   that a later pass can count, borrow or reuse.

   Every value has a [layout], which says how it's held in memory: a
   scalar, a counted object, or the address of a C local. A variable's
   layout is fixed where it's made, and mem_lint.ml checks that every use
   agrees with it.

   Memory is explicit. [Alloc] makes an object, with a count of 1;
   [Dup] counts one more reference to it, [Drop] one fewer, freeing it
   with the last, and [Free] gives back an object the program knows
   nothing else holds. Native step 2 places them naively: a [Dup] at
   every use of a counted variable, and a [Drop] of every variable that
   owns one when its scope ends (to_mem.ml). Step 4's Perceus places
   them precisely, over this same IR.

   Failing is explicit too, as in Core. A function that can fail returns
   a status, its error or nothing, and writes its value through a
   pointer: a [Call_fails] says what to do when the callee failed, and a
   [Raise] either returns an error from the function or jumps to the
   [Catch] that handles it. *)

(* How a value is held. *)
type layout =
  | Int  (** int64_t *)
  | Float  (** double *)
  | Bool
  | Unit
  | Enum
      (** a value of a sum type none of whose constructors has fields: its
          constructor's tag *)
  | Boxed
      (** a pointer to a counted object: a record, a tuple, a constructor with
          fields, an error, an array or a [Str]. A sum type with fields keeps
          its constructors without any here too, as small tagged scalars, which
          are never counted *)
  | Cell of layout
      (** the address of a C local that holds a value of this layout: an `inout`
          parameter, which changes the caller's variable *)

(* Whether a value of this layout has a count. *)
let counted (l : layout) = match l with Boxed -> true | _ -> false

(* A variable, known by its id, which is unique in its function. *)
type var = { id : int; name : string; layout : layout }

type atom =
  | Var of var
  | Int of int64
  | Float of float
  | Bool of bool
  | Unit
  | Enum_tag of int  (** an [Enum]: the constructor with this tag *)
  | Scalar_ctor of int
      (** a [Boxed] sum's constructor without fields, with this tag *)
  | Lit of int
      (** the program's [strings]'s n-th, a [Str] made once and never freed *)

(* The parts of a panic's message that are known when the program is
   compiled: where it is, and for an `Int` that overflowed, the operands
   the help suggests the wrapping method for (eval.ml, [wrap]). An
   [Asserts] site's whole message is known: an `assert` that failed. *)
type wrap = { meth : string; recv : Loc.t; arg : Loc.t option }
type site_kind = Panics | Asserts
type site = { sid : int; loc : Loc.t; wrap : wrap option; kind : site_kind }
type cmp = Lt | Le | Gt | Ge | Eq | Ne

(* A function of the runtime's (ren_rt.h). Each borrows its arguments:
   what it keeps, it counts again itself. *)
type rt =
  | Array_len
  | Array_get of layout  (** of an array whose elements have this layout *)
  | Array_set of layout
  | Array_push of layout
  | Str_len
  | Str_concat
  | Str_eq
  | Show_int
  | Show_float
  | Show_bool
  | Float_of_int
  | Float_sqrt
  | Float_round
  | Float_truncate
  | Wrapping of Ast.binop  (** `Int`'s `wrapping_add`, `_sub` or `_mul` *)
  | Wrapping_neg
  | Console_write
  | Console_error

(* What a [Let] computes. *)
type rhs =
  | Atom of atom
  | Arith of Ast.binop * atom * atom * site
      (** [+], [-], [*], [/] or [%] on two [Int]s or two [Float]s, which panics
          at [site] if it overflows or has no answer *)
  | Neg of atom * site
  | Compare of cmp * atom * atom
      (** two scalars of one layout, [Int], [Float], [Bool], [Unit] or [Enum] *)
  | Not of atom
  | Tag_of of atom  (** the tag of a sum type's value, an [Int] *)
  | Field of atom * int
      (** the [n]-th field of a constructor, a record or a tuple, by its slot:
          borrowed, not counted again *)
  | Alloc of { tag : int; fields : atom list; nobjs : int }
      (** a new constructor, record, tuple or error, which takes its fields: in
          slot order, the [nobjs] counted ones first *)
  | Alloc_array of layout * atom list
      (** a new array of these elements, which it takes *)
  | Call of string * atom list
      (** a function that can't fail, which takes its arguments, but for cells
      *)
  | Runtime of rt * atom list * site option
  | Load of var  (** what a [Cell] holds, not counted again *)
  | Addr of var  (** a local's address, a [Cell] *)

type stmt =
  | Let of var * rhs
  | Decl of var  (** a variable a later [Set] gives its value *)
  | Set of var * atom
  | Store of var * atom  (** into what a [Cell] points at *)
  | Dup of atom
  | Drop of atom
  | Free of atom
  | Do of rhs  (** for what it does, a [Runtime] call or a [Call] *)
  | Call_fails of {
      result : var;
      fn : string;
      args : atom list;
      error : var;
      on_error : block;
    }
      (** call a function that can fail. If it fails, its error is [error], and
          [on_error] runs, which ends in a [Raise]; otherwise its value is
          [result], defined after this statement *)
  | If of atom * block * block
  | Switch of atom * (int * block) list * block
      (** on a tag: the block for each, and the one for any other *)
  | Loop of int * block  (** run [block] until a [Break] of this label *)
  | Break of int
  | Joins of block * (int * block) list
      (** run the block, which ends by jumping to one of the labelled blocks
          after it; once that ends, go on after the [Joins] (Lean IR's join
          points, Lean/Compiler/IR/Basic.lean, [jdecl] and [jmp]) *)
  | Jump of int
  | Catch of { label : int; body : block; error : var; handler : block }
      (** run [body]; a [Raise] to [label] in it sets [error], and runs
          [handler]. Either way, go on after it *)
  | Raise of atom * int option
      (** fail with this error: to the [Catch] of this label, or, with [None],
          return it from the function *)
  | Return of atom
  | Assert of atom * site  (** panic if this [Bool] is false *)
  | Panic of site * string

and block = stmt list

type fn = {
  name : string;  (** its C name *)
  params : var list;
  result : layout;
  fails : bool;  (** whether it returns a status, its value through a pointer *)
  body : block;
  loc : Loc.t;
}

(* How `ren run` shows a value: [main]'s, or an error's payload. *)
type shown = Shows_int | Shows_float | Shows_bool | Shows_str | Shows_unit

type program = {
  fns : fn list;
  start : string;  (** the C name of `$start`, which the binary runs *)
  start_result : layout;
  start_fails : bool;
  prints : shown;  (** how its value is printed, as `ren run` prints it *)
  errors : (int * string * (int * shown) list) list;
      (** each error `main` can fail with: its tag, its name, and its payload's
          slots, in order, each with how it's shown *)
  strings : string list;  (** the string literals, by [Lit]'s index *)
  sites : site list;  (** by [sid] *)
  overflow : site;  (** where the stack overflowing is said to be *)
}

(* ---- printing, as s-expressions, for tests ---- *)

let rec show_layout (l : layout) =
  match l with
  | Int -> "Int"
  | Float -> "Float"
  | Bool -> "Bool"
  | Unit -> "Unit"
  | Enum -> "Enum"
  | Boxed -> "Boxed"
  | Cell l -> "&" ^ show_layout l

let show_var (v : var) = v.name ^ "/" ^ string_of_int v.id
let typed (v : var) = Core.Atom (show_var v ^ ":" ^ show_layout v.layout)

let show_atom = function
  | Var v -> show_var v
  | Int n -> Int64.to_string n
  | Float f -> Ast.show_float f
  | Bool b -> string_of_bool b
  | Unit -> "()"
  | Enum_tag t -> "#" ^ string_of_int t
  | Scalar_ctor t -> "#" ^ string_of_int t ^ "*"
  | Lit n -> "lit" ^ string_of_int n

let show_cmp = function
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="

let show_rt = function
  | Array_len -> "array-len"
  | Array_get l -> "array-get:" ^ show_layout l
  | Array_set l -> "array-set:" ^ show_layout l
  | Array_push l -> "array-push:" ^ show_layout l
  | Str_len -> "str-len"
  | Str_concat -> "str-concat"
  | Str_eq -> "str-eq"
  | Show_int -> "show-int"
  | Show_float -> "show-float"
  | Show_bool -> "show-bool"
  | Float_of_int -> "float-of-int"
  | Float_sqrt -> "sqrt"
  | Float_round -> "round"
  | Float_truncate -> "truncate"
  | Wrapping op -> "wrapping" ^ Ast.binop_to_string op
  | Wrapping_neg -> "wrapping-neg"
  | Console_write -> "console-write"
  | Console_error -> "console-error"

let atoms xs = List.map (fun a -> Core.Atom (show_atom a)) xs
let a x = Core.Atom x

let rhs_sexp = function
  | Atom x -> a (show_atom x)
  | Arith (op, x, y, _) ->
      Core.List (a (Ast.binop_to_string op) :: atoms [ x; y ])
  | Neg (x, _) -> Core.List (a "neg" :: atoms [ x ])
  | Compare (c, x, y) -> Core.List (a (show_cmp c) :: atoms [ x; y ])
  | Not x -> Core.List (a "not" :: atoms [ x ])
  | Tag_of x -> Core.List (a "tag" :: atoms [ x ])
  | Field (x, n) ->
      Core.List [ a "field"; a (show_atom x); a (string_of_int n) ]
  | Alloc { tag; fields; nobjs } ->
      Core.List
        (a "alloc"
        :: a ("#" ^ string_of_int tag)
        :: a ("objs:" ^ string_of_int nobjs)
        :: atoms fields)
  | Alloc_array (l, xs) -> Core.List (a ("array:" ^ show_layout l) :: atoms xs)
  | Call (f, xs) -> Core.List (a "call" :: a f :: atoms xs)
  | Runtime (r, xs, _) -> Core.List (a (show_rt r) :: atoms xs)
  | Load v -> Core.List [ a "load"; a (show_var v) ]
  | Addr v -> Core.List [ a "addr"; a (show_var v) ]

let rec stmt_sexp = function
  | Let (v, r) -> Core.List [ a "let"; typed v; rhs_sexp r ]
  | Decl v -> Core.List [ a "decl"; typed v ]
  | Set (v, x) -> Core.List [ a "set"; a (show_var v); a (show_atom x) ]
  | Store (v, x) -> Core.List [ a "store"; a (show_var v); a (show_atom x) ]
  | Dup x -> Core.List [ a "dup"; a (show_atom x) ]
  | Drop x -> Core.List [ a "drop"; a (show_atom x) ]
  | Free x -> Core.List [ a "free"; a (show_atom x) ]
  | Do r -> Core.List [ a "do"; rhs_sexp r ]
  | Call_fails { result; fn; args; error; on_error } ->
      Core.List
        [
          a "call-fails";
          typed result;
          Core.List (a fn :: atoms args);
          Core.List (a "error" :: typed error :: List.map stmt_sexp on_error);
        ]
  | If (c, t, f) ->
      Core.List [ a "if"; a (show_atom c); block_sexp t; block_sexp f ]
  | Switch (x, cases, default) ->
      Core.List
        (a "switch"
         :: a (show_atom x)
         :: List.map
              (fun (t, b) ->
                Core.List [ a ("#" ^ string_of_int t); block_sexp b ])
              cases
        @ [ Core.List [ a "else"; block_sexp default ] ])
  | Loop (l, b) -> Core.List [ a ("loop L" ^ string_of_int l); block_sexp b ]
  | Break l -> a ("break L" ^ string_of_int l)
  | Joins (b, joins) ->
      Core.List
        (a "joins" :: block_sexp b
        :: List.map
             (fun (l, j) ->
               Core.List [ a ("L" ^ string_of_int l ^ ":"); block_sexp j ])
             joins)
  | Jump l -> a ("jump L" ^ string_of_int l)
  | Catch { label; body; error; handler } ->
      Core.List
        [
          a ("catch L" ^ string_of_int label);
          block_sexp body;
          Core.List (typed error :: [ block_sexp handler ]);
        ]
  | Raise (x, Some l) ->
      Core.List [ a ("raise L" ^ string_of_int l); a (show_atom x) ]
  | Raise (x, None) -> Core.List [ a "raise"; a (show_atom x) ]
  | Return x -> Core.List [ a "return"; a (show_atom x) ]
  | Assert (x, _) -> Core.List [ a "assert"; a (show_atom x) ]
  | Panic (_, msg) -> Core.List [ a "panic"; a (Ast.show_str msg) ]

and block_sexp b = Core.List (a "do" :: List.map stmt_sexp b)

let show_fn (f : fn) =
  Core.render 0
    (Core.List
       [
         a "fn";
         a f.name;
         Core.List (List.map typed f.params);
         a ((if f.fails then "fails " else "") ^ "-> " ^ show_layout f.result);
         block_sexp f.body;
       ])
