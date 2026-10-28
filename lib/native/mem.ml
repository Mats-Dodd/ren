(* Mem IR: the program as the native backend sees it, made from Core by
   to_mem.ml, checked by mem_lint.ml, and written out as C by emit_c.ml
   (compiler.md, "Native slice").

   It's in A-normal form: every operand is an [atom], a variable or a
   constant, and anything that computes something is a statement that
   puts its result in a fresh variable. So the order things happen in is
   the order of the statements, and every intermediate value has a name
   that a later pass can count, borrow or reuse.

   Every value has a [layout], which says how it's held in memory: a
   scalar, a counted object, the address of a C local, a word of a type
   variable's, or one of the debug build's hidden values: a type's
   descriptor, evidence, a block. A variable's layout is fixed where it's
   made, and mem_lint.ml checks that every use agrees with it.

   Memory is explicit. [Alloc] makes an object, with a count of 1;
   [Dup] counts one more reference to it, [Drop] one fewer, freeing it
   with the last. to_mem.ml places them naively, `--rc naive`: a [Dup]
   at every use of a counted variable, and a [Drop] of every variable
   that owns one when its scope ends. Perceus, `--rc perceus`, the
   default, places them again over this same IR: borrow.ml decides which
   parameters each function borrows ([fn.modes]), rc.ml puts a [Dup] only
   where a value is used again and a [Drop] where it dies, specialized
   ([Is_unique] and [Free]) when the program keeps some of its fields,
   and reuse.ml turns a [Drop] followed by an [Alloc] of the same size
   into a [Reset] whose memory the [Alloc] is built in.

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
          parameter, which changes the caller's variable, a local a block
          captures, or a handler's state *)
  | Word of int
      (** a value of the function's type variable [n]: one word, whatever it
          holds, counted through that variable's descriptor (ren_rt.h,
          [ren_val]) *)
  | Desc
      (** a type's descriptor, or a requirement's dictionary, which is its
          type's descriptor: a counted object, static if the compiler knows the
          type *)
  | Ev  (** evidence: a chain of the implementations installed *)
  | Block  (** a block: its code and its environment, two words *)
  | Ptr
      (** a raw pointer: a block's environment or its arguments, an
          implementation of a dependency, a handler's code *)
  | Struct of int * bool
      (** a release build's small value (foundations.md, decision 14): a record,
          a tuple or a sum that isn't recursive, kept as a C struct, the
          program's [structs]'s n-th, a word for each of its slots, passed by
          value and never allocated. With [true], a slot holds an object, and
          the struct is counted as its slots are, each its own (Koka's value
          types, Backend/C/FromCore.hs:1048, [genDupDropValue]); with [false],
          it's never counted, and may be an array's element. Never a word, nor
          in an object: a type whose value would be one is boxed instead *)
  | Token
      (** a reuse token: the memory of an object a [Reset] found unique, to
          build a new one in, or NULL. Never counted, and used or freed once *)
  | Sized of Sized.t
      (** a value of a sized storage type, `UInt8`, at its width: [uint8_t].
          An array of them keeps its elements at that width, and an object
          packs them as it does a [Bool] ([Pack]). Never counted; read as an
          [Int] or a [Float] by [Widen], and made of one by [Narrow] or
          [Wrap_to] (sized.ml) *)

(* How a [Struct] keeps its value. *)
type struct_kind =
  | Product  (** a record's or a tuple's fields, a slot each *)
  | Tagged
      (** a sum's: slot 0 its constructor's tag, an [Int], and the fields of
          each constructor in the slots after, which constructors share where
          their layouts are the same; a slot a constructor has no field in
          holds a scalar ([Scalar_ctor 0] where it's [Boxed]) *)
  | Nullable of int * int
      (** a sum of two constructors, the first tag's without fields and the
          second's with one, an object, its only slot: the object, or
          [Scalar_ctor (-1)], which no object or constructor is, for the first
          (Koka's [DataAsMaybe], Core/Core.hs:533) *)

(* A [Struct]: its slots' layouts, and how it keeps its value. *)
type strukt = { sfields : layout list; skind : struct_kind }

(* Whether a value of this layout has a count: an object, a descriptor,
   a type variable's word, which may be either, or a struct holding an
   object. *)
let counted (l : layout) =
  match l with Boxed | Desc | Word _ -> true | Struct (_, c) -> c | _ -> false

(* Whether a value of this layout is always an object, so the runtime
   counts it without a descriptor. *)
let is_object (l : layout) = match l with Boxed | Desc -> true | _ -> false

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
  | Desc_lit of int
      (** the program's [descs]'s n-th: a [Desc] made once and never freed *)
  | Fn_ptr of string  (** a function's code, a [Ptr]: a handler's *)
  | No_ev  (** the evidence with nothing installed, `$start`'s *)

(* The parts of a panic's message that are known when the program is
   compiled: where it is, and for an `Int` that overflowed, the operands
   the help suggests the wrapping method for (eval.ml, [wrap]). An
   [Asserts] site's whole message is known: an `assert` that failed. A
   [Caller] site is in the prelude, whose source a program doesn't show,
   so a panic there is said to be at the program's call that reached it,
   as `ren run` says (eval.ml, [call_at]): the runtime's [ren_here], which
   a [Here_set] sets before each call of the prelude from the program's
   code. *)
type wrap = { meth : string; recv : Loc.t; arg : Loc.t option }
type site_kind = Panics | Asserts | Caller
type site = {
  sid : int;
  loc : Loc.t;
  wrap : wrap option;
  kind : site_kind;
  made : string option;
      (** where a NaN made here is said to be made, "at x.ren:3:9" (nan.ml):
          a `Float` operation's, which a debug build tags a NaN it makes with *)
}
type cmp = Lt | Le | Gt | Ge | Eq | Ne

(* A function of the runtime's (ren_rt.h). Each borrows its arguments,
   and counts again what it keeps, but for those that change an array in
   place, and [Array_own], which take theirs ([takes]). *)
type rt =
  | Array_len
  | Array_get of layout  (** of an array whose elements have this layout *)
  | Array_set of layout  (** a copy with one element changed *)
  | Array_push of layout
      (** what a [Cell] holds, copied with one element more, put back *)
  | Array_set_taking of layout
      (** [Array_set], which takes the array and the element, and changes the
          array in place if it's unique (lean.h, [lean_ensure_exclusive_array])
      *)
  | Array_push_taking of layout
      (** [Array_push], which takes the element, and grows the array in place if
          it's unique *)
  | Array_take of layout
      (** [Array_get], for an element written back where it was before anything
          else can see the array (swap.ml): if the array is unique, the element
          is moved out, its count not changed, and a scalar left in its place,
          so what it's changed into can be changed in place too (Lean's
          swap-out, Init/Data/Array/Basic.lean:774); otherwise it's counted
          again, as [Array_get] does *)
  | Array_check
      (** panics if an index is out of bounds for an array, as [Array_get] would
      *)
  | Array_set_field of int * int * layout
      (** [Array_set] of an array of the [n]-th struct that changes only its
          [k]-th field, of this layout: a copy *)
  | Array_set_field_taking of int * int * layout
      (** [Array_set_field], which takes the array and changes its element's
          field in place if it's unique *)
  | Array_own
      (** an array, taken, made unique: itself if its count is 1, else a copy
          (lean.h, [lean_ensure_exclusive_array]). hoist.ml's, before a loop *)
  | Array_data
      (** where an array's elements are, a [Ptr]: hoist.ml's, for a loop that
          indexes it without going through the array again *)
  | Buf_get of layout
      (** an element, of this layout, of the elements a [Ptr] points at, of
          which there are as many as its [Int]: [Array_get] once the array is
          known *)
  | Buf_set of layout
      (** an element changed in place, taking the new one and dropping the old:
          [Array_set_taking] once the array is known unique *)
  | Buf_take of layout
      (** [Array_take] once the array is known unique: the element moved out,
          a scalar left in its place *)
  | Buf_set_field of int * int * layout
      (** [Array_set_field_taking] once the array is known unique *)
  | Buf_check  (** [Array_check] of a length *)
  | Array_reserve of layout
      (** an empty array of these elements, with room for as many as the [Int]
          given; a [Word]'s descriptor after it says whether they're objects *)
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
  | Bits of Intrinsic.t  (** `Int`'s `xor`, `bit_and` or `bit_or` *)
  | Shift of Intrinsic.t
      (** `Int`'s `shl` or `shr`, which panics at its site if the amount isn't
          0 to 63 *)
  | Widen  (** a [Sized] as its wide type, the variable's, the same number *)
  | Narrow of Sized.t
      (** an [Int] or a [Float] as a [Sized] of this type: panics if it doesn't
          fit, as the interpreter does (eval.ml, [stored]) *)
  | Wrap_to of Sized.t  (** an [Int]'s low bits as a [Sized] of this type *)
  | Console_write
  | Console_error
  | Show_any  (** a descriptor and a [Word]: `show` through the walk *)
  | Equal_any of string
      (** a descriptor and two [Word]s: `==` through the walk, which panics on a
          NaN saying this operator compared it *)
  | Compare_any of string
      (** a descriptor and two [Word]s: their order, an [Int] below 0 if the
          first comes first *)
  | Op_any of Ast.binop option
      (** a descriptor and two [Word]s, or one for [None], `-`: an operator
          through a requirement's dictionary, which panics as the operator does
      *)
  | Nan_check of string
      (** one or two [Float]s: panics if one is a NaN, the first, saying this,
          "`<` compared a NaN" (nan.ml) *)
  | Nan_check_any of string
      (** a descriptor and a [Word]: panics if a NaN is anywhere in it *)
  | Float_lanes
      (** a descriptor: whether it describes `Float`, whose `sum` adds in
          lanes *)
  | Float_sum
      (** an array of [Float]s, or of a [Word] that's one, added up in eight
          lanes (prelude.ml, [float_sum]) *)
  | Here_set
      (** its site, a call of the prelude from the program's code, is where
          a panic at a [Caller] site is said to be *)
  | Here_get  (** a [Ptr]: where [Here_set] last said, to put back *)
  | Here_put  (** a [Ptr] [Here_get] gave: where it was again *)
  | Value_any of bool  (** a descriptor: `zero`, or `one` if [true] *)
  | New_desc of new_desc
      (** a descriptor built of the descriptors given: a named type's, from its
          declaration, the program's [decls]'s n-th, or an array's or a tuple's
      *)

and new_desc = Of_decl of int | Of_array | Of_tuple

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
  | Tag_of of atom
      (** the tag of a sum type's value, an [Int]: an [Enum], a [Boxed], or a
          [Struct] that's [Tagged] or [Nullable] *)
  | Field of atom * int * int
      (** the [n]-th field of a constructor, a record or a tuple of [size]
          fields, by its slot: borrowed, not counted again *)
  | Alloc of {
      tag : int;
      fields : atom list;
      words : atom list;
      at : (atom * int list) option;
    }
      (** a new constructor, record, tuple or error, which takes its fields, in
          the order they're declared; [words] are the descriptors of those that
          are a [Word], in order, which say whether each holds an object. An
          error keeps its payload's descriptors after its payload, as fields.
          With [at], it's built in a [Token]'s memory if it has some, whose
          slots listed already hold their fields (Lean's ExpandResetReuse.lean,
          [reuseToSet]), and allocated if it's NULL *)
  | Alloc_array of { elem : layout; elems : atom list; desc : atom option }
      (** a new array of these elements, which it takes; [desc] describes them
          if they're [Word]s *)
  | Call of string * atom list
      (** a function that can't fail, which takes its arguments, but for cells
      *)
  | Runtime of rt * atom list * site option
  | Load of var  (** what a [Cell] holds, not counted again *)
  | Addr of var  (** a local's address, a [Cell] *)
  | To_word of atom  (** a value as a type variable's word *)
  | Of_word of atom * layout  (** a [Word] as a value of this layout *)
  | Global of string
      (** an associated value, made once when the program starts (the program's
          [values]), by its C name: borrowed *)
  | Env_new of atom list
      (** a block's environment, a [Ptr]: these [Cell]s, in an array on the
          stack of the function this is in *)
  | Env_get of atom * int
      (** the [n]-th cell of the environment a block's code is given, of the
          variable's layout *)
  | Arg of atom * int
      (** the [n]-th of the words a block's code is given, as a value of the
          variable's layout *)
  | Block_of of string * atom
      (** a block: the code of the function named, which has a block's
          signature, and an environment *)
  | Impl of int * atom list
      (** an implementation of the dependency with this number, a [Ptr]: a
          [Block] for each operation, in the order the dependency declares them,
          in a record on the stack *)
  | Install of { outer : atom; impls : atom list; deps : atom; ndeps : atom }
      (** [outer] with an implementation from [impls] installed for each of the
          dependency numbers [deps] points at, [ndeps] of them: new evidence,
          whose nodes are on the stack *)
  | Given of { outer : atom; caller : atom; deps : int list }
      (** [outer] with the implementations of [deps] that [caller] has on top: a
          block's evidence, when its parameter's type lists them *)
  | Op_block of atom * int * int
      (** the [Block] of an operation, its dependency's [n]-th, of the innermost
          implementation of the dependency with this number in the evidence *)
  | Is_unique of atom
      (** whether an object's count is 1 (lean.h, [lean_is_exclusive]) *)
  | Make_struct of atom list
      (** a [Struct], the variable's, of these slots, in order, which it takes
      *)
  | Struct_get of atom * int
      (** the [n]-th slot of a [Struct]: borrowed, not counted again *)
  | Pack of (atom * int * int) list
      (** a word, an [Int], holding small scalars side by side: each a [Bool],
          a [Unit] or an [Enum], at the bit given, in as many bits as given.
          The scalar fields of an object packed together, after Lean's
          ([lean_ctor_set_uint8], lean.h:612, and the [sset] of
          Lean/Compiler/IR/Basic.lean) *)
  | Unpack of atom * int * int
      (** the scalar, of the variable's layout, at this bit of a word [Pack]
          made, in this many bits ([lean_ctor_get_uint8], lean.h:592) *)
  | Hole of atom * int
      (** where slot [n] of an object is, a [Ptr]: a constructor built before
          what goes in that slot, which holds a scalar till [Fill] puts it
          there (trmc.ml, Koka's constructor contexts) *)
  | Reset of atom * (int * atom) list
      (** a unique object's memory, as a [Token]: the fields at the slots listed
          are the variables after them, which keep their references, and the
          others are dropped (Koka's drop-reuse, Lean's [reset]) *)

type stmt =
  | Let of var * rhs
  | Decl of var  (** a variable a later [Set] gives its value *)
  | Set of var * atom
  | Store of var * atom  (** into what a [Cell] points at *)
  | Dup of atom
  | Drop of atom
  | Dup_word of atom * atom
      (** a [Word], counted through the descriptor after it *)
  | Drop_word of atom * atom
  | Free of atom * (int * atom) list
      (** free a unique object: the fields at the slots listed are the variables
          after them, which keep their references, and the others are dropped
          (Koka's drop specialization, Parc.hs, [specializeDrop]). Of a counted
          [Struct], which is always its own, its slots not listed are dropped *)
  | Free_token of atom  (** the memory of a [Token] nothing was built in *)
  | Fill of atom * atom
      (** the value after it, taken, written where a [Hole] is, which held a
          scalar: the slot of a constructor only the function building it can
          reach (trmc.ml) *)
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
  | Call_block of {
      result : var;
      block : atom;
      ev : atom;
      args : atom list;
      error : var;
      on_error : block option;
    }
      (** call a block, which takes its arguments, with the caller's evidence:
          an indirect call, whose arguments and value go as words. A block's
          code always returns a status; [on_error] runs if it failed, and is
          [None] if its type says it can't *)
  | Call_handler of {
      result : var;
      handler : atom;
      outer : atom;
      body : atom;
      desc : atom;
      deps : int list;
      error : var;
      on_error : block option;
    }
      (** install a handler: call the code of the description [handler], with
          the evidence [outer], the [Block] [body] to run with the evidence it
          makes, [desc] describing what [body] gives, and the dependencies to
          install it for. Its value is the `with`'s, a word *)
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

(* Whether a function takes a parameter's reference, and drops it or
   passes it on, or borrows it from its caller, who keeps it alive. *)
type mode = Owned | Borrowed

type fn = {
  name : string;  (** its C name *)
  params : var list;
  modes : mode list;  (** each parameter's, in order *)
  inout : var list;
      (** its `inout` parameters, which nothing else points to what they point
          to: a release build tells C so, with `restrict` *)
  words : (int * var) list;
      (** the descriptor of each type variable whose values are words here, a
          parameter or a variable its body defines first *)
  result : layout;
  fails : bool;  (** whether it returns a status, its value through a pointer *)
  body : block;
  loc : Loc.t;
  lines : (int * int) list;
      (** the line of its source each variable it defines was made at, by the
          variable's id, which a debug build tells C with `#line`, so a
          debugger steps through Ren (foundations.md, decision 13). A line
          of [loc]'s file; none for code from another, the prelude's *)
}

(* A descriptor the compiler knows, which the C file holds as static
   data (ren_rt.h, [ren_desc]): a type's, or, in a declaration, a field
   type's template, which names the type's parameters ([D_var]). Each
   argument is another of the program's [descs], by its index. *)
type dkind =
  | D_int
  | D_float
  | D_bool
  | D_unit
  | D_str
  | D_named of int  (** the program's [decls]'s n-th *)
  | D_array
  | D_tuple
  | D_errors
  | D_var of int
  | D_unknown
  | D_sized of Sized.t

type desc = { dkind : dkind; dargs : int list; dcounted : bool }

(* A type's declaration, as the walks need it: its fields' types are
   templates, among the program's [descs]. *)
type decl_body =
  | Record_decl of (string * int) list
  | Sum_decl of (string * int list) list  (** its constructors, by tag *)
  | Rep_decl of int  (** an opaque type: what it's represented as *)

type decl = {
  dname : string;
  dopaque : bool;
  dbody : decl_body;
  dplaces : int list option list;
      (** for each constructor, a record's one, where each field is kept, if
          its scalars are packed ([Pack]): the word's number, shifted left 16,
          the bit it starts at, shifted left 8, and how many bits, 64 for a
          word of its own; [None] where each field is the word of its number
          (ren_rt.h, [ren_ctor_info]) *)
}

(* An associated value: its C name, the function that makes it, and its
   layout. *)
type value = { vname : string; vfn : string; vlayout : layout }

type program = {
  fns : fn list;
  start : string;
      (** the C name of `$start`, which the binary runs with [No_ev] *)
  start_result : layout;
  start_fails : bool;
  start_desc : int;
      (** the descriptor of what it gives, which the binary prints as `ren run`
          does *)
  descs : desc list;  (** by [Desc_lit]'s index *)
  decls : decl list;
  tags : string list;  (** the error tags' names, by number *)
  values : value list;  (** made in this order, each after those it uses *)
  strings : string list;  (** the string literals, by [Lit]'s index *)
  sites : site list;  (** by [sid] *)
  structs : strukt list;  (** each [Struct], by its n *)
  overflow : site;  (** where the stack overflowing is said to be *)
}

(* Whether the runtime's [rt] takes its [n]-th argument's reference: the
   array and the element of those that change an array in place, the
   element of a buffer's, and the array [Array_own] makes unique. *)
let takes (rt : rt) n =
  match rt with
  | Array_set_taking _ | Array_set_field_taking _ -> n = 0 || n = 2
  | Array_push_taking _ -> n = 1
  | Array_own -> n = 0
  | Buf_set _ | Buf_set_field _ -> n = 3
  | _ -> false

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
  | Word n -> "Word" ^ string_of_int n
  | Desc -> "Desc"
  | Ev -> "Ev"
  | Block -> "Block"
  | Ptr -> "Ptr"
  | Token -> "Token"
  | Struct (n, c) -> "Struct" ^ string_of_int n ^ if c then "c" else ""
  | Sized k -> Sized.name k

let show_var (v : var) = v.name ^ "/" ^ string_of_int v.id
let typed (v : var) = Core.Atom (show_var v ^ ":" ^ show_layout v.layout)

let show_atom = function
  | Var v -> show_var v
  | Int n -> Int64.to_string n
  | Float f -> Ast.show_float f
  | Bool b -> string_of_bool b
  | Unit -> "()"
  | Enum_tag t -> "#" ^ string_of_int t
  | Scalar_ctor t when t < 0 -> "#none*"
  | Scalar_ctor t -> "#" ^ string_of_int t ^ "*"
  | Lit n -> "lit" ^ string_of_int n
  | Desc_lit n -> "desc" ^ string_of_int n
  | Fn_ptr f -> "&" ^ f
  | No_ev -> "no-ev"

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
  | Array_set_taking l -> "array-set-taking:" ^ show_layout l
  | Array_push_taking l -> "array-push-taking:" ^ show_layout l
  | Array_take l -> "array-take:" ^ show_layout l
  | Array_check -> "array-check"
  | Array_set_field (n, k, _) -> Printf.sprintf "array-set-field:%d.%d" n k
  | Array_set_field_taking (n, k, _) ->
      Printf.sprintf "array-set-field-taking:%d.%d" n k
  | Array_own -> "array-own"
  | Array_data -> "array-data"
  | Buf_get l -> "buf-get:" ^ show_layout l
  | Buf_set l -> "buf-set:" ^ show_layout l
  | Buf_take l -> "buf-take:" ^ show_layout l
  | Buf_set_field (n, k, _) -> Printf.sprintf "buf-set-field:%d.%d" n k
  | Buf_check -> "buf-check"
  | Array_reserve l -> "array-reserve:" ^ show_layout l
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
  | Bits x -> Intrinsic.member_name x
  | Shift x -> Intrinsic.member_name x
  | Widen -> "widen"
  | Narrow k -> "narrow:" ^ Sized.name k
  | Wrap_to k -> "wrap:" ^ Sized.name k
  | Console_write -> "console-write"
  | Console_error -> "console-error"
  | Show_any -> "show-any"
  | Equal_any op -> "equal-any" ^ op
  | Compare_any op -> "compare-any" ^ op
  | Nan_check _ -> "nan-check"
  | Nan_check_any _ -> "nan-check-any"
  | Float_lanes -> "float-lanes"
  | Float_sum -> "float-sum"
  | Here_set -> "here-set"
  | Here_get -> "here-get"
  | Here_put -> "here-put"
  | Op_any (Some op) -> "op-any" ^ Ast.binop_to_string op
  | Op_any None -> "op-any-neg"
  | Value_any one -> if one then "one-any" else "zero-any"
  | New_desc (Of_decl n) -> "new-desc:" ^ string_of_int n
  | New_desc Of_array -> "new-desc:array"
  | New_desc Of_tuple -> "new-desc:tuple"

let atoms xs = List.map (fun a -> Core.Atom (show_atom a)) xs
let a x = Core.Atom x

(* The fields a [Free] or a [Reset] keeps: [slot=var]. *)
let kept_sexp kept =
  List.map (fun (n, x) -> a (string_of_int n ^ "=" ^ show_atom x)) kept

let rhs_sexp = function
  | Atom x -> a (show_atom x)
  | Arith (op, x, y, _) ->
      Core.List (a (Ast.binop_to_string op) :: atoms [ x; y ])
  | Neg (x, _) -> Core.List (a "neg" :: atoms [ x ])
  | Compare (c, x, y) -> Core.List (a (show_cmp c) :: atoms [ x; y ])
  | Not x -> Core.List (a "not" :: atoms [ x ])
  | Tag_of x -> Core.List (a "tag" :: atoms [ x ])
  | Field (x, n, size) ->
      Core.List
        [
          a "field";
          a (show_atom x);
          a (string_of_int n ^ "/" ^ string_of_int size);
        ]
  | Alloc { tag; fields; words; at } ->
      Core.List
        ((a "alloc" :: a ("#" ^ string_of_int tag) :: atoms fields)
        @ (if words = [] then [] else [ Core.List (a "words" :: atoms words) ])
        @
        match at with
        | None -> []
        | Some (t, same) ->
            [
              Core.List
                (a "at"
                :: a (show_atom t)
                :: List.map (fun n -> a ("=" ^ string_of_int n)) same);
            ])
  | Alloc_array { elem; elems; desc } ->
      Core.List
        ((a ("array:" ^ show_layout elem) :: atoms elems)
        @ atoms (Option.to_list desc))
  | Call (f, xs) -> Core.List (a "call" :: a f :: atoms xs)
  | Runtime (r, xs, _) -> Core.List (a (show_rt r) :: atoms xs)
  | Load v -> Core.List [ a "load"; a (show_var v) ]
  | Addr v -> Core.List [ a "addr"; a (show_var v) ]
  | To_word x -> Core.List [ a "to-word"; a (show_atom x) ]
  | Of_word (x, l) ->
      Core.List [ a ("of-word:" ^ show_layout l); a (show_atom x) ]
  | Global v -> Core.List [ a "global"; a v ]
  | Env_new xs -> Core.List (a "env" :: atoms xs)
  | Env_get (x, n) ->
      Core.List [ a "env-get"; a (show_atom x); a (string_of_int n) ]
  | Arg (x, n) -> Core.List [ a "arg"; a (show_atom x); a (string_of_int n) ]
  | Block_of (f, env) -> Core.List [ a "block"; a f; a (show_atom env) ]
  | Impl (dep, ops) ->
      Core.List (a "impl" :: a ("dep" ^ string_of_int dep) :: atoms ops)
  | Install { outer; impls; deps; ndeps } ->
      Core.List ((a "install" :: atoms [ outer; deps; ndeps ]) @ atoms impls)
  | Given { outer; caller; deps } ->
      Core.List
        ((a "given" :: atoms [ outer; caller ])
        @ List.map (fun d -> a ("dep" ^ string_of_int d)) deps)
  | Op_block (ev, dep, op) ->
      Core.List
        [
          a "op";
          a (show_atom ev);
          a ("dep" ^ string_of_int dep);
          a (string_of_int op);
        ]
  | Is_unique x -> Core.List [ a "unique?"; a (show_atom x) ]
  | Reset (x, kept) -> Core.List (a "reset" :: a (show_atom x) :: kept_sexp kept)
  | Hole (x, n) -> Core.List [ a "hole"; a (show_atom x); a (string_of_int n) ]
  | Make_struct xs ->
      Core.List (a "struct" :: List.map (fun x -> a (show_atom x)) xs)
  | Struct_get (x, n) ->
      Core.List [ a "."; a (show_atom x); a (string_of_int n) ]
  | Pack xs ->
      Core.List
        (a "pack"
        :: List.map
             (fun (x, at, bits) ->
               a (Printf.sprintf "%s@%d:%d" (show_atom x) at bits))
             xs)
  | Unpack (x, at, bits) ->
      Core.List [ a "unpack"; a (Printf.sprintf "%s@%d:%d" (show_atom x) at bits) ]

let rec stmt_sexp = function
  | Let (v, r) -> Core.List [ a "let"; typed v; rhs_sexp r ]
  | Decl v -> Core.List [ a "decl"; typed v ]
  | Set (v, x) -> Core.List [ a "set"; a (show_var v); a (show_atom x) ]
  | Store (v, x) -> Core.List [ a "store"; a (show_var v); a (show_atom x) ]
  | Dup x -> Core.List [ a "dup"; a (show_atom x) ]
  | Drop x -> Core.List [ a "drop"; a (show_atom x) ]
  | Dup_word (x, d) -> Core.List [ a "dup"; a (show_atom x); a (show_atom d) ]
  | Drop_word (x, d) -> Core.List [ a "drop"; a (show_atom x); a (show_atom d) ]
  | Free (x, kept) -> Core.List (a "free" :: a (show_atom x) :: kept_sexp kept)
  | Free_token x -> Core.List [ a "free-token"; a (show_atom x) ]
  | Fill (p, x) -> Core.List [ a "fill"; a (show_atom p); a (show_atom x) ]
  | Do r -> Core.List [ a "do"; rhs_sexp r ]
  | Call_fails { result; fn; args; error; on_error } ->
      Core.List
        [
          a "call-fails";
          typed result;
          Core.List (a fn :: atoms args);
          Core.List (a "error" :: typed error :: List.map stmt_sexp on_error);
        ]
  | Call_block { result; block; ev; args; error; on_error } ->
      Core.List
        ([
           a "call-block";
           typed result;
           Core.List (a (show_atom block) :: atoms (ev :: args));
         ]
        @ error_sexp error on_error)
  | Call_handler { result; handler; outer; body; desc; deps; error; on_error }
    ->
      Core.List
        ([
           a "call-handler";
           typed result;
           Core.List
             (atoms [ handler; outer; body; desc ]
             @ List.map (fun d -> a ("dep" ^ string_of_int d)) deps);
         ]
        @ error_sexp error on_error)
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

and error_sexp error = function
  | Some b -> [ Core.List (a "error" :: typed error :: List.map stmt_sexp b) ]
  | None -> []

(* A borrowed parameter is printed with a [^] before it, as Koka writes
   one. *)
let show_fn (f : fn) =
  let param (v : var) m =
    match (m : mode) with
    | Owned -> typed v
    | Borrowed -> Core.Atom ("^" ^ show_var v ^ ":" ^ show_layout v.layout)
  in
  let modes =
    if List.length f.modes = List.length f.params then f.modes
    else List.map (fun _ -> Owned) f.params
  in
  Core.render 0
    (Core.List
       [
         a "fn";
         a f.name;
         Core.List (List.map2 param f.params modes);
         a ((if f.fails then "fails " else "") ^ "-> " ^ show_layout f.result);
         block_sexp f.body;
       ])
