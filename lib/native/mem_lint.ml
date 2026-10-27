(* Mem Lint: check a Mem IR program (mem.ml) again, from scratch, as
   Core Lint checks Core.

   It checks that every variable is defined before it's used, in a scope
   around the use, as C's blocks scope them, and defined once; that every
   operand has the layout its operation needs and every variable the
   layout of what it's given; that only counted values are counted; that a
   call passes what its callee takes, and that only a [Call_fails] calls a
   function that can fail; that a [Break] is inside its [Loop], a [Jump]
   inside the [Joins] it goes to, and a [Raise] inside the [Catch] it goes
   to, or in a function that can fail; that an [Alloc] is given a
   descriptor for each field that's a type variable's word; that a block
   is never stored in an object, or anywhere but a local, an argument or
   an environment on the stack, so it can't outlive the call it's passed
   to (foundations.md, decision 1); and that a block's code, and a
   handler's, has the signature every caller of one uses. Then it checks
   the counting, path by path ("counting", below).

   Anything it finds is a bug in the compiler, which fails with [Failure],
   and the driver reports as an internal compiler error. `ren build` runs
   it on every program, and so do the tests. *)

open Mem
module Ids = Set.Make (Int)

let sprintf = Printf.sprintf

type env = {
  fns : (string, fn) Hashtbl.t;
  values : (string, layout) Hashtbl.t;
  ndescs : int;
  structs : strukt array;  (** each [Struct], by its number *)
  fn : fn;  (** the function being checked *)
  defined : Ids.t;  (** the variables in scope here *)
  seen : (int, unit) Hashtbl.t;  (** every variable defined so far *)
  loops : int list;
  joins : int list;
  catches : int list;
}

let fail env msg = failwith (sprintf "Mem Lint, in %s: %s" env.fn.name msg)

(* The program's [k]-th struct. *)
let struct_of env k =
  if k < 0 || k >= Array.length env.structs then
    fail env (sprintf "a struct %d, which isn't in the program" k);
  env.structs.(k)

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

(* Whether two layouts are held the same way: a type variable's word is
   one whichever variable it's of. *)
let same (a : layout) (b : layout) =
  match (a, b) with Word _, Word _ -> true | _ -> a = b

(* Whether a value of this layout fits in a word, which is how a block's
   arguments and value, and a type variable's, are passed. A block, two
   words, never is one, and neither is a cell, nor a struct. *)
let wordable (l : layout) =
  match l with Block | Cell _ | Struct _ -> false | _ -> true

let use env (v : var) =
  if not (Ids.mem v.id env.defined) then
    fail env (sprintf "%s is used where it isn't defined" (show_var v))

let atom env x =
  (match x with
  | Var v -> use env v
  | Desc_lit n ->
      if n < 0 || n >= env.ndescs then
        fail env (sprintf "a descriptor desc%d, which isn't in the program" n)
  | _ -> ());
  atom_layout x

let expect env what (want : layout) (got : layout) =
  if not (same want got) then
    fail env
      (sprintf "%s is %s, but should be %s" what (show_layout got)
         (show_layout want))

let operand env what want x =
  expect env (what ^ " " ^ show_atom x) want (atom env x)

let define env (v : var) =
  if Hashtbl.mem env.seen v.id then
    fail env (sprintf "%s is defined twice" (show_var v));
  Hashtbl.replace env.seen v.id ();
  { env with defined = Ids.add v.id env.defined }

(* What the runtime's [rt] takes and gives. *)
let rt_sig (rt : rt) : layout list * layout =
  match rt with
  | Array_len -> ([ Boxed ], Int)
  | Array_get l -> ([ Boxed; Int ], l)
  | Array_set l -> ([ Boxed; Int; l ], Boxed)
  | Array_push l | Array_push_taking l -> ([ Cell Boxed; l ], Unit)
  | Array_set_taking l -> ([ Boxed; Int; l ], Boxed)
  | Array_check -> ([ Boxed; Int ], Unit)
  | Array_set_field (_, _, l) | Array_set_field_taking (_, _, l) ->
      ([ Boxed; Int; l ], Boxed)
  | Array_own -> ([ Boxed ], Boxed)
  | Array_data -> ([ Boxed ], Ptr)
  | Buf_get l -> ([ Ptr; Int; Int ], l)
  | Buf_set l -> ([ Ptr; Int; Int; l ], Unit)
  | Buf_set_field (_, _, l) -> ([ Ptr; Int; Int; l ], Unit)
  | Buf_check -> ([ Int; Int ], Unit)
  | Array_reserve (Word _) -> ([ Int; Desc ], Boxed)
  | Array_reserve _ -> ([ Int ], Boxed)
  | Str_len -> ([ Boxed ], Int)
  | Str_concat -> ([ Boxed; Boxed ], Boxed)
  | Str_eq -> ([ Boxed; Boxed ], Bool)
  | Show_int -> ([ Int ], Boxed)
  | Show_float -> ([ Float ], Boxed)
  | Show_bool -> ([ Bool ], Boxed)
  | Float_of_int -> ([ Int ], Float)
  | Float_sqrt -> ([ Float ], Float)
  | Float_round | Float_truncate -> ([ Float ], Int)
  | Wrapping _ -> ([ Int; Int ], Int)
  | Wrapping_neg -> ([ Int ], Int)
  | Console_write | Console_error -> ([ Boxed ], Unit)
  | Show_any -> ([ Desc; Word 0 ], Boxed)
  | Equal_any -> ([ Desc; Word 0; Word 0 ], Bool)
  | Compare_any -> ([ Desc; Word 0; Word 0 ], Int)
  | Op_any (Some _) -> ([ Desc; Word 0; Word 0 ], Word 0)
  | Op_any None -> ([ Desc; Word 0 ], Word 0)
  | Value_any _ -> ([ Desc ], Word 0)
  | New_desc _ -> ([], Desc)

let args env what (want : layout list) xs =
  if List.length want <> List.length xs then
    fail env
      (sprintf "%s is given %d operands, not %d" what (List.length xs)
         (List.length want));
  List.iter2 (fun l x -> operand env what l x) want xs

(* A word: what a block's arguments and value are passed as. *)
let word env what x =
  let l = atom env x in
  if not (wordable l) then
    fail env
      (sprintf "%s %s is %s, not a word" what (show_atom x) (show_layout l))

let callee env name =
  match Hashtbl.find_opt env.fns name with
  | Some f -> f
  | None -> fail env (sprintf "a call of %s, which isn't in the program" name)

(* The fields a [Free] or a [Reset] keeps: each slot once, below 32, and
   held as a counted variable. *)
let kept_fields env kept =
  List.iteri
    (fun i (n, x) ->
      if n < 0 || n >= 32 then fail env (sprintf "a kept slot %d" n);
      if
        List.exists (fun (m, _) -> m = n) (List.filteri (fun j _ -> j < i) kept)
      then fail env (sprintf "slot %d kept twice" n);
      if not (counted (atom env x)) then
        fail env (sprintf "a kept field %s that isn't counted" (show_atom x)))
    kept

(* The layout of what [r] gives. *)
let rhs env (r : rhs) : layout =
  match r with
  | Atom x -> atom env x
  | Arith (op, x, y, _) ->
      let l = atom env x in
      if l <> Int && l <> Float then
        fail env (sprintf "`%s` on %s" (Ast.binop_to_string op) (show_layout l));
      operand env "the right operand" l y;
      l
  | Neg (x, _) ->
      let l = atom env x in
      if l <> Int && l <> Float then fail env "`-` on what isn't a number";
      l
  | Compare (_, x, y) ->
      let l = atom env x in
      (match l with
      | Int | Float | Bool | Unit | Enum -> ()
      | _ -> fail env (sprintf "a comparison of %s" (show_layout l)));
      operand env "the right side" l y;
      Bool
  | Not x ->
      operand env "`not`'s operand" Bool x;
      Bool
  | Tag_of x ->
      (match atom env x with
      | Enum | Boxed -> ()
      | Struct (k, _) when (struct_of env k).skind <> Product -> ()
      | l -> fail env (sprintf "the tag of %s" (show_layout l)));
      Int
  | Field (x, n, size) ->
      operand env "what a field is read from" Boxed x;
      if n < 0 || n >= size then
        fail env (sprintf "field %d of an object of %d" n size);
      (* the field's own layout is the variable's, which the object
         doesn't say: Lint takes it *)
      Unit
  | Alloc { fields; words; at; _ } ->
      let ls = List.map (atom env) fields in
      Option.iter
        (fun (t, same) ->
          operand env "where an object is built" Token t;
          List.iter
            (fun n ->
              if n < 0 || n >= List.length fields then
                fail env
                  (sprintf "an unchanged slot %d of %d" n (List.length fields)))
            same)
        at;
      if List.length ls > 32 then fail env "an object of more than 32 fields";
      List.iter
        (fun l ->
          if not (wordable l) then
            fail env (sprintf "%s stored in an object" (show_layout l)))
        ls;
      let nwords =
        List.length (List.filter (function Word _ -> true | _ -> false) ls)
      in
      if nwords <> List.length words then
        fail env
          (sprintf "an object with %d words given %d descriptors" nwords
             (List.length words));
      List.iter (operand env "a field's descriptor" Desc) words;
      Boxed
  | Alloc_array { elem; elems; desc } ->
      (* an array's elements are counted as words, or never: a struct that
         holds an object is never one *)
      if not (wordable elem || match elem with Struct (_, c) -> not c | _ -> false)
      then fail env (sprintf "an array of %s" (show_layout elem));
      List.iter (operand env "an array's element" elem) elems;
      (match (elem, desc) with
      | Word _, Some d -> operand env "an array's descriptor" Desc d
      | Word _, None -> fail env "an array of words with no descriptor"
      | _, Some _ -> fail env "a descriptor for an array that isn't of words"
      | _, None -> ());
      Boxed
  | Call (name, xs) ->
      let f = callee env name in
      if f.fails then
        fail env (sprintf "%s, which can fail, called without a status" name);
      args env ("a call of " ^ name)
        (List.map (fun (v : var) -> v.layout) f.params)
        xs;
      f.result
  | Runtime (r, xs, _) ->
      let want, gives = rt_sig r in
      args env (show_rt r) want xs;
      gives
  | Load v -> (
      use env v;
      match v.layout with
      | Cell l -> l
      | l ->
          fail env
            (sprintf "a load from %s, which is %s" (show_var v) (show_layout l))
      )
  | Addr v -> (
      use env v;
      match v.layout with
      | Cell _ ->
          fail env (sprintf "the address of %s, already a cell" (show_var v))
      | l -> Cell l)
  | To_word x ->
      word env "what's made a word" x;
      Word 0
  | Of_word (x, l) ->
      operand env "what's taken from a word" (Word 0) x;
      if not (wordable l) then
        fail env (sprintf "a word taken as %s" (show_layout l));
      l
  | Global name -> (
      match Hashtbl.find_opt env.values name with
      | Some l -> l
      | None ->
          fail env (sprintf "the value %s, which isn't in the program" name))
  | Env_new xs ->
      List.iter
        (fun x ->
          match atom env x with
          | Cell _ -> ()
          | l ->
              fail env
                (sprintf "an environment holding %s, not a cell" (show_layout l)))
        xs;
      Ptr
  | Env_get (x, _) ->
      operand env "an environment" Ptr x;
      (* the cell's layout is the variable's, as a field's is *)
      Unit
  | Arg (x, _) ->
      operand env "a block's arguments" Ptr x;
      Unit
  | Block_of (name, x) ->
      let f = callee env name in
      if
        not
          (List.map (fun (v : var) -> v.layout) f.params = [ Ptr; Ev; Ptr ]
          && f.fails && same f.result (Word 0))
      then
        fail env
          (sprintf "a block of %s, which hasn't a block's signature" name);
      operand env "a block's environment" Ptr x;
      Block
  | Impl (_, ops) ->
      List.iter (operand env "an operation" Block) ops;
      Ptr
  | Install { outer; impls; deps; ndeps } ->
      operand env "the evidence installed on" Ev outer;
      List.iter (operand env "an implementation" Ptr) impls;
      operand env "the dependencies installed" Ptr deps;
      operand env "how many are installed" Int ndeps;
      Ev
  | Given { outer; caller; _ } ->
      operand env "a block's evidence" Ev outer;
      operand env "its caller's" Ev caller;
      Ev
  | Op_block (ev, _, _) ->
      operand env "the evidence an operation is found in" Ev ev;
      Block
  | Is_unique x ->
      operand env "what's asked if it's unique" Boxed x;
      Bool
  | Reset (x, kept) ->
      operand env "what's reset" Boxed x;
      kept_fields env kept;
      Token
  | Make_struct xs ->
      (* the struct's is the variable's, which [stmt] checks *)
      List.iter (fun x -> ignore (atom env x)) xs;
      Unit
  | Pack xs ->
      ignore
        (List.fold_left
           (fun used (x, at, bits) ->
             (match atom env x with
             | Bool | Unit | Enum -> ()
             | l -> fail env (sprintf "%s packed in a word" (show_layout l)));
             if bits < 1 || bits > 32 || at < 0 || at + bits > 64 then
               fail env (sprintf "a packed field at bit %d of %d bits" at bits);
             let m = Int64.shift_left (Int64.pred (Int64.shift_left 1L bits)) at in
             if Int64.logand used m <> 0L then
               fail env (sprintf "packed fields that overlap at bit %d" at);
             Int64.logor used m)
           0L xs);
      Int
  | Unpack (x, at, bits) ->
      operand env "a packed word" Int x;
      if bits < 1 || bits > 32 || at < 0 || at + bits > 64 then
        fail env (sprintf "a packed field at bit %d of %d bits" at bits);
      (* the field's own layout is the variable's, which [stmt] checks *)
      Unit
  | Struct_get (x, n) -> (
      match atom env x with
      | Struct (k, _) -> (
          match List.nth_opt (struct_of env k).sfields n with
          | Some l -> l
          | None -> fail env (sprintf "field %d of a struct of fewer" n))
      | l -> fail env (sprintf "a struct's field read from %s" (show_layout l)))

let rec stmt env (s : stmt) : env =
  match s with
  | Let (v, r) ->
      let l = rhs env r in
      (match r with
      | Field _ | Arg _ ->
          if not (wordable v.layout) then
            fail env
              (sprintf "%s, %s, read from words" (show_var v)
                 (show_layout v.layout))
      | Unpack _ -> (
          match v.layout with
          | Bool | Unit | Enum -> ()
          | l ->
              fail env
                (sprintf "%s, %s, unpacked from a word" (show_var v)
                   (show_layout l)))
      | Make_struct xs -> (
          match v.layout with
          | Struct (k, c)
            when List.length (struct_of env k).sfields = List.length xs ->
              let st = struct_of env k in
              List.iter2 (operand env "a struct's field") st.sfields xs;
              (* it's counted if and only if a slot holds an object *)
              if c <> List.exists is_object st.sfields then
                fail env
                  (sprintf "%s is counted as a struct %s objects"
                     (show_layout v.layout)
                     (if c then "without" else "with"));
              (match (st.skind, st.sfields) with
              | Product, _ -> ()
              | Tagged, Int :: _ -> ()
              | Nullable _, [ Boxed ] -> ()
              | _ -> fail env "a struct of a sum kept wrong")
          | l ->
              fail env
                (sprintf "a struct made as %s, %s" (show_var v) (show_layout l))
          )
      | Env_get _ -> (
          match v.layout with
          | Cell _ -> ()
          | l ->
              fail env
                (sprintf "%s, %s, read from an environment" (show_var v)
                   (show_layout l)))
      | _ -> expect env (show_var v) v.layout l);
      define env v
  | Decl v -> define env v
  | Set (v, x) ->
      use env v;
      operand env ("what's set to " ^ show_var v) v.layout x;
      env
  | Store (v, x) ->
      use env v;
      (match v.layout with
      | Cell l -> operand env ("what's stored in " ^ show_var v) l x
      | l ->
          fail env
            (sprintf "a store into %s, which is %s" (show_var v) (show_layout l)));
      env
  | Free (x, kept) ->
      (match atom env x with
      | Struct (_, true) -> ()
      | _ -> operand env "what's freed" Boxed x);
      kept_fields env kept;
      env
  | Free_token x ->
      operand env "a token freed" Token x;
      env
  | Dup x | Drop x ->
      let l = atom env x in
      if not (is_object l || match l with Struct (_, c) -> c | _ -> false)
      then
        fail env
          (sprintf "%s is %s, which isn't an object, but is counted"
             (show_atom x) (show_layout l));
      env
  | Dup_word (x, d) | Drop_word (x, d) ->
      operand env "what's counted" (Word 0) x;
      operand env "what it's counted through" Desc d;
      env
  | Do r ->
      ignore (rhs env r);
      env
  | Call_fails { result; fn; args = xs; error; on_error } ->
      let f = callee env fn in
      if not f.fails then
        fail env (sprintf "%s can't fail, but is called as if it can" fn);
      args env ("a call of " ^ fn)
        (List.map (fun (v : var) -> v.layout) f.params)
        xs;
      expect env (show_var result) f.result result.layout;
      expect env (show_var error) Boxed error.layout;
      block (define env error) on_error;
      define env result
  | Call_block { result; block = b; ev; args = xs; error; on_error } ->
      operand env "what's called" Block b;
      operand env "the caller's evidence" Ev ev;
      List.iter (word env "an argument") xs;
      if not (wordable result.layout) then
        fail env (sprintf "a block giving %s" (show_layout result.layout));
      expect env (show_var error) Boxed error.layout;
      Option.iter (block (define env error)) on_error;
      define env result
  | Call_handler { result; handler; outer; body; desc; error; on_error; _ } ->
      operand env "a handler's description" Boxed handler;
      operand env "the evidence it's installed on" Ev outer;
      operand env "the body it runs" Block body;
      operand env "the body's descriptor" Desc desc;
      if not (wordable result.layout) then
        fail env (sprintf "a `with` giving %s" (show_layout result.layout));
      expect env (show_var error) Boxed error.layout;
      Option.iter (block (define env error)) on_error;
      define env result
  | If (c, t, f) ->
      operand env "a condition" Bool c;
      block env t;
      block env f;
      env
  | Switch (x, cases, default) ->
      operand env "what's switched on" Int x;
      List.iter (fun (_, b) -> block env b) cases;
      block env default;
      env
  | Loop (l, b) ->
      block { env with loops = l :: env.loops } b;
      env
  | Break l ->
      if not (List.mem l env.loops) then
        fail env (sprintf "a break of L%d outside it" l);
      env
  | Joins (b, joins) ->
      block { env with joins = List.map fst joins @ env.joins } b;
      List.iter (fun (_, j) -> block env j) joins;
      env
  | Jump l ->
      if not (List.mem l env.joins) then
        fail env (sprintf "a jump to L%d from outside it" l);
      env
  | Catch { label; body; error; handler } ->
      expect env (show_var error) Boxed error.layout;
      let env = define env error in
      block { env with catches = label :: env.catches } body;
      block env handler;
      env
  | Raise (x, target) ->
      operand env "an error" Boxed x;
      (match target with
      | Some l ->
          if not (List.mem l env.catches) then
            fail env (sprintf "a raise to L%d from outside it" l)
      | None ->
          if not env.fn.fails then
            fail env "a raise in a function that can't fail");
      env
  | Return x ->
      operand env "what's returned" env.fn.result x;
      env
  | Assert (c, _) ->
      operand env "what's asserted" Bool c;
      env
  | Panic _ -> env

(* A block's own definitions end with it. *)
and block env b = ignore (List.fold_left stmt env b)

let fn fns values ndescs structs (f : fn) =
  let env =
    {
      fns;
      values;
      ndescs;
      structs;
      fn = f;
      defined = Ids.empty;
      seen = Hashtbl.create 64;
      loops = [];
      joins = [];
      catches = [];
    }
  in
  block (List.fold_left define env f.params) f.body

(* ---- counting ----

   Then the counting, path by path, from scratch: that every reference a
   function holds is given away or dropped exactly once on every path,
   that it never drops or gives away one it doesn't hold, that it never
   reads a value after the last reference it held was dropped, and that
   every reuse token is used or freed. It's the same check for the naive
   counting and for Perceus's (compiler.md, "Native slice").

   What it tracks is a bundle of references to one value: those a
   variable holds, or the variables that are only it under another name,
   a [Let] or a [Set] of it, or what a cell holds. A bundle is owned,
   with the references the function holds in it; borrowed, a borrowed
   parameter's or one an environment holds, which someone else keeps
   alive; a part, a field of another bundle, alive while that one is,
   or while it holds references of its own; or static, a constant or a
   word of a type that isn't counted. A value split into two bundles,
   given away through one and kept through the other, is counted in
   each: that's stricter than the runtime, never looser.

   A cell is a local whose address is taken, or one a caller or a
   block's writer lends: anything called may change what it holds, so
   at a call each one whose address is in scope, and whose value is
   still held, has one reference fewer to that value, and a new value
   with one is there instead. A lent cell holds exactly one reference
   when the function ends.

   Where paths meet, the variables that share a bundle on one path are
   taken together, and hold as many references on each; a loop's body
   ends holding as many as it started with, or a constant, which holds
   none. *)

module IM = Map.Make (Int)

type bundle_kind = B_owned | B_borrowed | B_part of int | B_static

type rc_state = {
  vars : int IM.t;  (** a variable's bundle *)
  count : int IM.t;  (** how many references the function holds *)
  kind : bundle_kind IM.t;
  bname : string IM.t;  (** what it's called in a message *)
  cells : int IM.t;
      (** a cell variable's slot: a local's id, or a lent cell's, below 0 *)
  lent : int IM.t;  (** what each lent cell holds *)
  tokens : Ids.t;  (** the tokens not yet used or freed *)
}

type rc_env = {
  rfn : fn;
  rfns : (string, fn) Hashtbl.t;
  next : int ref;
  addressed : Ids.t;  (** the locals whose address is taken *)
  scope : Ids.t;  (** the variables defined around here *)
  rloops : (int * (Ids.t * rc_state list ref)) list;
  rjoins : (int * rc_state list ref) list;
  rcatches : (int * (var * rc_state list ref)) list;
}

let rc_fail env msg = failwith (sprintf "Mem Lint, in %s: %s" env.rfn.name msg)

(* Whether a variable is counted here: a [Word] of a callee's type
   variable is a value of a type the caller knows, and counted as that. *)
let rc_counted env (v : var) =
  match v.layout with
  | Word n -> List.mem_assoc n env.rfn.words
  | Boxed | Desc -> true
  | Struct (_, c) -> c
  | _ -> false

let get m k = match IM.find_opt k m with Some x -> x | None -> 0

let bundle env st ?(count = 0) kind name =
  let b = !(env.next) in
  incr env.next;
  ( {
      st with
      count = IM.add b count st.count;
      kind = IM.add b kind st.kind;
      bname = IM.add b name st.bname;
    },
    b )

let bind st (v : var) b = { st with vars = IM.add v.id b st.vars }

(* [v] given a new bundle, if it's counted at all. *)
let fresh_var env st (v : var) ?(count = 1) kind =
  if not (counted v.layout) then st
  else
    let kind = if rc_counted env v then kind else B_static in
    let st, b = bundle env st ~count kind (show_var v) in
    bind st v b

let bundle_of st (x : atom) =
  match x with Var v -> IM.find_opt v.id st.vars | _ -> None

let name st b = Option.value (IM.find_opt b st.bname) ~default:"a value"

(* Whether a bundle's value is still alive, so it can be read. *)
let rec alive st b =
  match IM.find_opt b st.kind with
  | Some (B_borrowed | B_static) | None -> true
  | Some B_owned -> get st.count b > 0
  | Some (B_part p) -> get st.count b > 0 || alive st p

let read env st (x : atom) =
  match bundle_of st x with
  | Some b when not (alive st b) ->
      rc_fail env (sprintf "%s is read after it's dropped" (show_atom x))
  | _ -> ()

let add st b n = { st with count = IM.add b (get st.count b + n) st.count }

let dup env st (x : atom) =
  read env st x;
  match bundle_of st x with Some b -> add st b 1 | None -> st

(* One reference given away or dropped. *)
let take env st what (x : atom) =
  match bundle_of st x with
  | None -> st
  | Some b -> (
      match IM.find_opt b st.kind with
      | Some B_static | None -> st
      | _ ->
          if get st.count b < 1 then
            rc_fail env
              (sprintf "%s is %s, but holds no reference here" (show_atom x)
                 what);
          add st b (-1))

(* What a cell's slot holds, and the same, changed. *)
let slot_bundle st slot =
  if slot >= 0 then IM.find_opt slot st.vars else IM.find_opt slot st.lent

let set_slot st slot b =
  if slot >= 0 then { st with vars = IM.add slot b st.vars }
  else { st with lent = IM.add slot b st.lent }

(* The slot [c] may have changed: what it held loses the reference the
   slot held, and a new value with one is there. *)
let changed env st slot =
  match slot_bundle st slot with
  | None -> st
  | Some b -> (
      match IM.find_opt b st.kind with
      | Some B_static | None -> st
      | _ ->
          if get st.count b < 1 then
            rc_fail env
              (sprintf
                 "%s is held by a cell that may change here, but the cell \
                  holds no reference to it"
                 (name st b));
          let st = add st b (-1) in
          let st, b' = bundle env st ~count:1 B_owned (name st b) in
          set_slot st slot b')

(* A call may change any cell whose address is in scope: a local's, or
   one lent to the function. *)
let call_changes env st =
  let slots = IM.fold (fun _ slot acc -> Ids.add slot acc) st.cells Ids.empty in
  (* a local's cell whose value was dropped is dead: nothing writes it
     again *)
  let dead slot =
    slot >= 0
    &&
    match IM.find_opt slot st.vars with
    | Some b -> get st.count b = 0
    | None -> true
  in
  Ids.fold
    (fun slot st -> if dead slot then st else changed env st slot)
    slots st

let cell_slot env st (c : var) =
  match IM.find_opt c.id st.cells with
  | Some s -> s
  | None ->
      rc_fail env (sprintf "%s isn't a cell this function knows" (show_var c))

let modes_of (f : fn) =
  if List.length f.modes = List.length f.params then f.modes
  else List.map (fun _ : mode -> Owned) f.params

(* The arguments of a call of [name]: each it takes given away, each it
   borrows read. *)
let call_args env st name xs =
  let f =
    match Hashtbl.find_opt env.rfns name with
    | Some f -> f
    | None -> rc_fail env ("a call of " ^ name)
  in
  let modes = modes_of f in
  let modes =
    if List.length modes = List.length xs then modes
    else List.map (fun _ : mode -> Owned) xs
  in
  List.iter2 (fun x (m : mode) -> if m = Borrowed then read env st x) xs modes;
  List.fold_left2
    (fun st x (m : mode) ->
      match m with Owned -> take env st "given away" x | Borrowed -> st)
    st xs modes

(* The references still held where the function ends: none, but each
   lent cell's one. *)
let exit_check env st =
  if not (Ids.is_empty st.tokens) then
    rc_fail env "a reuse token is never used or freed";
  let lent =
    IM.fold (fun _ b acc -> IM.add b (get acc b + 1) acc) st.lent IM.empty
  in
  IM.iter
    (fun b n ->
      let want = get lent b in
      match IM.find_opt b st.kind with
      | Some B_static | None -> ()
      | _ ->
          if n > want then
            rc_fail env
              (sprintf "%s still holds a reference where the function ends"
                 (name st b))
          else if n < want then
            rc_fail env
              (sprintf "a cell's value, %s, is dropped, but stays in the cell"
                 (name st b)))
    st.count

(* The references held that nothing in [scope] can reach: leaked. *)
let leak_check env st scope =
  let reached =
    IM.fold
      (fun v b acc -> if Ids.mem v scope then Ids.add b acc else acc)
      st.vars Ids.empty
  in
  let reached = IM.fold (fun _ b acc -> Ids.add b acc) st.lent reached in
  IM.iter
    (fun b n ->
      if n > 0 && not (Ids.mem b reached) then
        match IM.find_opt b st.kind with
        | Some B_static | None -> ()
        | _ ->
            rc_fail env
              (sprintf "a reference to %s is never dropped" (name st b)))
    st.count

(* The state where paths meet, from each path's. A variable in [scope],
   or a lent cell, that shares a bundle with another on one path shares
   one with it on all of them, and each such class of them holds as many
   references on every path. *)
let merge env scope (states : rc_state list) : rc_state option =
  match states with
  | [] -> None
  | [ st ] ->
      leak_check env st scope;
      Some st
  | first :: _ ->
      List.iter (fun st -> leak_check env st scope) states;
      List.iter
        (fun st ->
          if not (Ids.equal st.tokens first.tokens) then
            rc_fail env "a reuse token is used on one path but not another")
        states;
      let real st b =
        match IM.find_opt b st.kind with
        | Some B_static | None -> false
        | _ -> true
      in
      (* each variable, and each lent cell as its slot, below 0 *)
      let keys st =
        IM.bindings (IM.filter (fun v _ -> Ids.mem v scope) st.vars)
        @ IM.bindings st.lent
      in
      let all_keys =
        List.sort_uniq compare
          (List.concat_map (fun st -> List.map fst (keys st)) states)
      in
      let all_keys =
        List.filter
          (fun k ->
            List.for_all
              (fun st -> IM.mem k (if k >= 0 then st.vars else st.lent))
              states)
          all_keys
      in
      let find st k = if k >= 0 then IM.find k st.vars else IM.find k st.lent in
      (* the classes: keys that share a real bundle on some path *)
      let parent = Hashtbl.create 16 in
      let rec root k =
        match Hashtbl.find_opt parent k with
        | Some p when p <> k -> root p
        | _ -> k
      in
      let union a b =
        let a = root a and b = root b in
        if a <> b then Hashtbl.replace parent a b
      in
      List.iter
        (fun st ->
          let by = Hashtbl.create 16 in
          List.iter
            (fun k ->
              let b = find st k in
              if real st b then
                match Hashtbl.find_opt by b with
                | Some k' -> union k k'
                | None -> Hashtbl.replace by b k)
            all_keys)
        states;
      let classes = Hashtbl.create 16 in
      List.iter
        (fun k ->
          let r = root k in
          Hashtbl.replace classes r
            (k :: Option.value (Hashtbl.find_opt classes r) ~default:[]))
        all_keys;
      let merged = ref first in
      Hashtbl.iter
        (fun _ ks ->
          let bundles st =
            List.sort_uniq compare
              (List.filter (real st) (List.map (find st) ks))
          in
          (* a path where they hold only a constant holds no references,
             and dropping it does nothing *)
          let per =
            List.filter
              (fun (_, bs) -> bs <> [])
              (List.map (fun st -> (st, bundles st)) states)
          in
          let total (st, bs) =
            List.fold_left (fun n b -> n + get st.count b) 0 bs
          in
          let totals = List.map total per in
          let what () =
            let k = List.hd ks in
            if k >= 0 then name first (find first k) else "a lent cell's value"
          in
          (match totals with
          | t :: rest when List.exists (( <> ) t) rest ->
              rc_fail env
                (sprintf "%s holds %s references on different paths" (what ())
                   (String.concat " and " (List.map string_of_int totals)))
          | _ -> ());
          match per with
          | [] -> ()
          | (_, [ b ]) :: rest
            when List.length per = List.length states
                 && List.for_all (fun (_, bs) -> bs = [ b ]) rest ->
              (* the same bundle on every path *)
              ()
          | _ ->
              let kinds =
                List.concat_map
                  (fun (st, bs) ->
                    List.filter_map (fun b -> IM.find_opt b st.kind) bs)
                  per
              in
              if kinds <> [] then
                let kind =
                  match kinds with
                  | k :: rest when List.for_all (( = ) k) rest -> k
                  | _ -> B_owned
                in
                let st = !merged in
                let st =
                  List.fold_left
                    (fun st b -> { st with count = IM.add b 0 st.count })
                    st (bundles first)
                in
                let st, b =
                  bundle env st ~count:(List.hd totals) kind (what ())
                in
                merged :=
                  List.fold_left
                    (fun st k ->
                      if k >= 0 then { st with vars = IM.add k b st.vars }
                      else set_slot st k b)
                    st ks)
        classes;
      Some !merged

(* What a loop's body starts from: each variable it sets, and each cell
   if it calls anything, given a new bundle with the references the old
   one held, so the end of the body can be checked against it. *)
let loop_head env st (sets : Ids.t) calls =
  (* a bundle another variable shares gives the one that changes one
     reference: what [Let] of it and then [Set] does *)
  let renew st b =
    match IM.find_opt b st.kind with
    | Some B_static | None -> (st, b)
    | Some k ->
        let sharers =
          IM.fold
            (fun v b' n -> if b' = b && Ids.mem v env.scope then n + 1 else n)
            st.vars 0
        in
        let n = get st.count b in
        let n = if sharers > 1 then min n 1 else n in
        let st = add st b (-n) in
        bundle env st ~count:n k (name st b)
  in
  let st =
    Ids.fold
      (fun v st ->
        match IM.find_opt v st.vars with
        | Some b when Ids.mem v env.scope ->
            let st, b' = renew st b in
            { st with vars = IM.add v b' st.vars }
        | _ -> st)
      (if calls then Ids.union sets env.addressed else sets)
      st
  in
  if calls then
    IM.fold
      (fun slot b st ->
        let st, b' = renew st b in
        set_slot st slot b')
      st.lent st
  else st

(* The end of a loop's body, which goes round again: each variable and
   cell holds as many references as where the body started. *)
let loop_check env head st =
  leak_check env st env.scope;
  if not (Ids.equal st.tokens head.tokens) then
    rc_fail env "a reuse token is used in a loop's body";
  (* a constant where it goes round holds no references, and dropping
     it does nothing, as where paths meet *)
  let same what b0 b1 =
    match (IM.find_opt b0 head.kind, IM.find_opt b1 st.kind) with
    | (Some B_static | None), _ | _, (Some B_static | None) -> ()
    | _ ->
        if get head.count b0 <> get st.count b1 then
          rc_fail env
            (sprintf
               "%s holds %d references where a loop starts, %d where it goes \
                round"
               what (get head.count b0) (get st.count b1))
  in
  IM.iter
    (fun v b0 ->
      if Ids.mem v env.scope then
        match IM.find_opt v st.vars with
        | Some b1 -> same (name head b0) b0 b1
        | None -> ())
    head.vars;
  IM.iter
    (fun slot b0 ->
      match IM.find_opt slot st.lent with
      | Some b1 -> same "a lent cell" b0 b1
      | None -> ())
    head.lent

(* The variables a block sets, anywhere in it. *)
let rec sets_in (b : block) acc =
  List.fold_left
    (fun acc (s : stmt) ->
      let acc =
        match s with Set (v, _) | Let (v, _) -> Ids.add v.id acc | _ -> acc
      in
      List.fold_left (fun acc b -> sets_in b acc) acc (sub_blocks s))
    acc b

and sub_blocks (s : stmt) : block list =
  match s with
  | Call_fails c -> [ c.on_error ]
  | Call_block { on_error; _ } | Call_handler { on_error; _ } ->
      Option.to_list on_error
  | If (_, t, e) -> [ t; e ]
  | Switch (_, cases, d) -> List.map snd cases @ [ d ]
  | Loop (_, b) -> [ b ]
  | Joins (b, js) -> b :: List.map snd js
  | Catch c -> [ c.body; c.handler ]
  | _ -> []

let rec calls_in (b : block) =
  List.exists
    (fun (s : stmt) ->
      (match s with
        | Let
            (_, (Call _ | Runtime ((Array_push _ | Array_push_taking _), _, _)))
        | Do (Call _ | Runtime ((Array_push _ | Array_push_taking _), _, _))
        | Call_fails _ | Call_block _ | Call_handler _ | Store _ ->
            true
        | _ -> false)
      || List.exists calls_in (sub_blocks s))
    b

(* A part [k] of [x] that a [Free] or a [Reset] of [x] keeps: the
   reference the object held is [k]'s now. *)
let keep_part env st (x : atom) (k : atom) =
  match (bundle_of st x, bundle_of st k) with
  | Some p, Some b -> (
      match IM.find_opt b st.kind with
      | Some (B_part p') when p' = p -> add st b 1
      | Some B_static -> st
      | _ ->
          rc_fail env
            (sprintf "%s is kept, but isn't a field of %s" (show_atom k)
               (show_atom x)))
  | _ -> st

(* What [Let (v, r)] does to the counts. *)
let rc_let env st (v : var) (r : rhs) =
  let same x =
    match bundle_of st x with
    | Some b when counted v.layout -> bind st v b
    | _ -> fresh_var env st v ~count:0 B_static
  in
  match r with
  | Atom x | To_word x -> same x
  | Of_word (x, l) -> (
      if counted l then same x
      else
        (* a word of a type that isn't counted: never counted *)
        match bundle_of st x with
        | Some b -> { st with kind = IM.add b B_static st.kind }
        | None -> st)
  | Field (x, _, _) | Struct_get (x, _) -> (
      read env st x;
      match bundle_of st x with
      | Some p -> fresh_var env st v ~count:0 (B_part p)
      | None -> fresh_var env st v ~count:0 B_static)
  (* a struct takes what it holds *)
  | Make_struct xs ->
      List.iter (read env st) xs;
      let st = List.fold_left (fun st x -> take env st "given away" x) st xs in
      fresh_var env st v B_owned
  | Load c -> (
      match c.layout with
      | Cell l when (not (counted l)) || l = Desc ->
          fresh_var env st v ~count:0 B_borrowed
      | _ -> (
          match slot_bundle st (cell_slot env st c) with
          | Some b -> bind st v b
          | None -> fresh_var env st v ~count:0 B_static))
  | Addr m -> { st with cells = IM.add v.id m.id st.cells }
  | Env_get _ -> (
      match v.layout with
      | Cell l when counted l && l <> Desc ->
          let slot = - !(env.next) in
          incr env.next;
          let st, b = bundle env st ~count:1 B_owned (show_var v) in
          {
            st with
            cells = IM.add v.id slot st.cells;
            lent = IM.add slot b st.lent;
          }
      | _ -> fresh_var env st v ~count:0 B_borrowed)
  | Global _ -> fresh_var env st v ~count:0 B_static
  | Alloc { fields; words; at; _ } ->
      List.iter (read env st) words;
      let st =
        match at with
        | Some (Var t, _) ->
            if not (Ids.mem t.id st.tokens) then
              rc_fail env
                (sprintf "%s is used where it's no token" (show_var t));
            { st with tokens = Ids.remove t.id st.tokens }
        | _ -> st
      in
      let st =
        List.fold_left (fun st x -> take env st "given away" x) st fields
      in
      fresh_var env st v B_owned
  | Alloc_array { elems; desc; _ } ->
      Option.iter (read env st) desc;
      let st =
        List.fold_left (fun st x -> take env st "given away" x) st elems
      in
      fresh_var env st v B_owned
  | Call (name, xs) ->
      let st = call_args env st name xs in
      let st = call_changes env st in
      fresh_var env st v B_owned
  | Runtime (rt, xs, _) ->
      let st =
        List.fold_left
          (fun (st, i) x ->
            if takes rt i then (take env st "given away" x, i + 1)
            else (
              read env st x;
              (st, i + 1)))
          (st, 0) xs
        |> fst
      in
      let st =
        match (rt, xs) with
        | (Array_push _ | Array_push_taking _), Var c :: _ ->
            changed env st (cell_slot env st c)
        | _ -> st
      in
      fresh_var env st v B_owned
  | Reset (x, kept) ->
      read env st x;
      let st = take env st "reset" x in
      let st = List.fold_left (fun st (_, k) -> keep_part env st x k) st kept in
      { st with tokens = Ids.add v.id st.tokens }
  | Arg _ -> fresh_var env st v B_owned
  | r ->
      List.iter (read env st)
        (match r with
        | Arith (_, x, y, _) | Compare (_, x, y) -> [ x; y ]
        | Neg (x, _) | Not x | Tag_of x | Is_unique x -> [ x ]
        | _ -> []);
      fresh_var env st v ~count:0 B_static

let with_var env (v : var) = { env with scope = Ids.add v.id env.scope }

let rec rc_stmt env (st : rc_state option) (s : stmt) : rc_state option =
  match st with
  | None -> None
  | Some st -> (
      match s with
      | Let (v, r) -> Some (rc_let env st v r)
      | Do r ->
          let v = { id = -1; name = "$do"; layout = Unit } in
          Some (rc_let env st v r)
      | Decl v ->
          if v.layout = Token then
            Some { st with tokens = Ids.add v.id st.tokens }
          else Some (fresh_var env st v ~count:0 B_static)
      | Set (v, x) -> (
          if v.layout = Token then
            match x with
            | Var r -> Some { st with tokens = Ids.remove r.id st.tokens }
            | _ -> Some st
          else
            match bundle_of st x with
            | Some b ->
                read env st x;
                Some (bind st v b)
            | None -> Some (fresh_var env st v ~count:0 B_static))
      | Store ({ layout = Cell l; _ }, _) when (not (counted l)) || l = Desc ->
          Some st
      | Store (c, x) -> (
          let slot = cell_slot env st c in
          match bundle_of st x with
          | Some b ->
              read env st x;
              Some (set_slot st slot b)
          | None ->
              let st, b = bundle env st ~count:0 B_static "a constant" in
              Some (set_slot st slot b))
      | Dup x | Dup_word (x, _) -> Some (dup env st x)
      | Drop x | Drop_word (x, _) -> Some (take env st "dropped" x)
      | Free (x, kept) ->
          read env st x;
          let st = take env st "freed" x in
          Some (List.fold_left (fun st (_, k) -> keep_part env st x k) st kept)
      | Free_token (Var t) ->
          if not (Ids.mem t.id st.tokens) then
            rc_fail env (sprintf "%s is freed where it's no token" (show_var t));
          Some { st with tokens = Ids.remove t.id st.tokens }
      | Free_token _ -> Some st
      | Call_fails { result; fn; args; error; on_error } ->
          let st = call_args env st fn args in
          let st = call_changes env st in
          rc_block (with_var env error)
            (Some (fresh_var env st error B_owned))
            on_error
          |> ignore;
          Some (fresh_var env st result B_owned)
      | Call_block { result; block; ev = _; args; error; on_error } ->
          read env st block;
          let st =
            List.fold_left (fun st x -> take env st "given away" x) st args
          in
          let st = call_changes env st in
          Option.iter
            (fun b ->
              ignore
                (rc_block (with_var env error)
                   (Some (fresh_var env st error B_owned))
                   b))
            on_error;
          Some (fresh_var env st result B_owned)
      | Call_handler { result; handler; desc; error; on_error; _ } ->
          read env st handler;
          read env st desc;
          let st = call_changes env st in
          Option.iter
            (fun b ->
              ignore
                (rc_block (with_var env error)
                   (Some (fresh_var env st error B_owned))
                   b))
            on_error;
          Some (fresh_var env st result B_owned)
      | If (c, t, e) ->
          read env st c;
          let a = rc_block env (Some st) t and b = rc_block env (Some st) e in
          merge env env.scope (Option.to_list a @ Option.to_list b)
      | Switch (x, cases, d) ->
          read env st x;
          let ends =
            List.filter_map (fun (_, b) -> rc_block env (Some st) b) cases
            @ Option.to_list (rc_block env (Some st) d)
          in
          merge env env.scope ends
      | Loop (l, body) ->
          let head =
            loop_head env st (sets_in body Ids.empty) (calls_in body)
          in
          let breaks = ref [] in
          let env' =
            { env with rloops = (l, (env.scope, breaks)) :: env.rloops }
          in
          (match rc_block env' (Some head) body with
          | Some last -> loop_check env head last
          | None -> ());
          merge env env.scope !breaks
      | Break l ->
          let scope, breaks = List.assoc l env.rloops in
          ignore scope;
          breaks := st :: !breaks;
          None
      | Joins (d, js) ->
          let refs = List.map (fun (l, _) -> (l, ref [])) js in
          let env' = { env with rjoins = refs @ env.rjoins } in
          let fall = rc_block env' (Some st) d in
          let ends =
            List.filter_map
              (fun (l, j) ->
                rc_block env' (merge env env.scope !(List.assoc l refs)) j)
              js
          in
          merge env env.scope (Option.to_list fall @ ends)
      | Jump l ->
          let r = List.assoc l env.rjoins in
          r := st :: !r;
          None
      | Catch { label; body; error; handler } ->
          let raises = ref [] in
          let env' =
            { env with rcatches = (label, (error, raises)) :: env.rcatches }
          in
          let fall = rc_block env' (Some st) body in
          let h =
            match merge env env.scope !raises with
            | Some st ->
                rc_block (with_var env error)
                  (Some (fresh_var env st error B_owned))
                  handler
            | None -> None
          in
          merge env env.scope (Option.to_list fall @ Option.to_list h)
      | Raise (x, Some l) ->
          read env st x;
          let st = take env st "raised" x in
          let _, raises = List.assoc l env.rcatches in
          raises := st :: !raises;
          None
      | Raise (x, None) | Return x ->
          read env st x;
          let st = take env st "given away" x in
          exit_check env st;
          None
      | Assert (c, _) ->
          read env st c;
          Some st
      | Panic _ -> None)

(* A block, from [st]: the state where it ends, if it can, with only the
   variables around it. *)
and rc_block env st (b : block) : rc_state option =
  let outer = env.scope in
  let _, st =
    List.fold_left
      (fun (env, st) s ->
        let st = rc_stmt env st s in
        let env =
          match s with
          | Let (v, _) | Decl v -> { env with scope = Ids.add v.id env.scope }
          | Call_fails { result; _ }
          | Call_block { result; _ }
          | Call_handler { result; _ } ->
              { env with scope = Ids.add result.id env.scope }
          | _ -> env
        in
        (env, st))
      (env, st) b
  in
  match st with
  | None -> None
  | Some st ->
      leak_check env st outer;
      if Ids.exists (fun t -> not (Ids.mem t outer)) st.tokens then
        rc_fail env "a reuse token is never used or freed";
      let inside v _ = Ids.mem v outer in
      Some
        {
          st with
          vars = IM.filter inside st.vars;
          cells = IM.filter inside st.cells;
        }

let counting fns (f : fn) =
  let addressed = ref Ids.empty in
  let rec scan b =
    List.iter
      (fun (s : stmt) ->
        (match s with
        | Let (_, Addr m) when counted m.layout ->
            addressed := Ids.add m.id !addressed
        | _ -> ());
        List.iter scan (sub_blocks s))
      b
  in
  scan f.body;
  let env =
    {
      rfn = f;
      rfns = fns;
      next = ref 1;
      addressed = !addressed;
      scope = Ids.of_list (List.map (fun (v : var) -> v.id) f.params);
      rloops = [];
      rjoins = [];
      rcatches = [];
    }
  in
  let st =
    {
      vars = IM.empty;
      count = IM.empty;
      kind = IM.empty;
      bname = IM.empty;
      cells = IM.empty;
      lent = IM.empty;
      tokens = Ids.empty;
    }
  in
  let st =
    List.fold_left2
      (fun st (v : var) (m : mode) ->
        match v.layout with
        | Cell l when counted l && l <> Desc ->
            let slot = - !(env.next) in
            incr env.next;
            let st, b = bundle env st ~count:1 B_owned (show_var v) in
            {
              st with
              cells = IM.add v.id slot st.cells;
              lent = IM.add slot b st.lent;
            }
        | _ -> (
            match m with
            | Owned -> fresh_var env st v B_owned
            | Borrowed -> fresh_var env st v ~count:0 B_borrowed))
      st f.params (modes_of f)
  in
  ignore (rc_block env (Some st) f.body)

let program (p : program) =
  let fns = Hashtbl.create 64 in
  List.iter
    (fun (f : fn) ->
      if Hashtbl.mem fns f.name then
        failwith ("Mem Lint: two functions named " ^ f.name);
      Hashtbl.replace fns f.name f)
    p.fns;
  let values = Hashtbl.create 16 in
  List.iter
    (fun (v : value) ->
      (match Hashtbl.find_opt fns v.vfn with
      | Some f when f.result = v.vlayout && not f.fails -> ()
      | _ -> failwith ("Mem Lint: the value " ^ v.vname ^ " isn't made right"));
      Hashtbl.replace values v.vname v.vlayout)
    p.values;
  let ndescs = List.length p.descs in
  List.iter (fn fns values ndescs (Array.of_list p.structs)) p.fns;
  List.iter (counting fns) p.fns;
  if p.start_desc < 0 || p.start_desc >= ndescs then
    failwith "Mem Lint: `main`'s descriptor isn't in the program";
  match Hashtbl.find_opt fns p.start with
  | Some f ->
      if
        List.map (fun (v : var) -> v.layout) f.params <> [ Ev ]
        || f.result <> p.start_result || f.fails <> p.start_fails
      then failwith "Mem Lint: `$start` isn't what the program says it is"
  | None -> failwith "Mem Lint: no `$start`"
