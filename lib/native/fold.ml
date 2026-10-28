(* Folding identical functions (foundations.md, decision 4): in a
   release build, functions whose Mem is the same are one function.

   Specialization copies a generic function for each type it's called
   at (specialize.ml), and Mem lowering lays each copy's values out by
   its types (to_mem.ml). A copy whose body only moves its values, with
   no `==`, `show`, hashing or anything else that depends on its type,
   has the same Mem at two types laid out alike: each module's
   `Tag { code: Int, label: Int }` is one two-word struct, so `keep` at
   one module's `Tag` and at another's are the same code. A copy that
   does depend on its type doesn't: a `show` names its type's descriptor
   ([Desc_lit]), and a `==` calls through it, so it stays one per type.
   So folding is how a copy that only moves values is specialized per
   layout, not per type, as Go's GC-shape stenciling and Swift's merging
   of functions share code (swift/lib/IRGen/IRGen.cpp:529-536 runs
   LLVM's merge-functions pass over Swift's specialized code), and one
   that depends on its type is per type, without a dictionary of
   indirect calls.

   Two functions fold when they're equal but for:

   - their names, and where they call themselves;
   - the functions they call, where those folded already: each round
     folds what calls what was folded the round before, until a round
     folds nothing;
   - the number of a [Struct] (to_mem.ml numbers one for each type),
     where the two structs' slots are laid out alike and keep their
     values alike: the C is the same, a word for each slot, and so are
     their counting and their tags (emit_c.ml);
   - the number of a panic's site, where the two sites say the same: a
     panic prints what its site says, where it is and its help, nothing
     else.

   It's sound because a call of either runs the same statements on the
   same values: equal Mem is equal C, but for those names and numbers,
   which change nothing a function does. Mem Lint checks the program
   after, as it checks any, and the C compiler checks that each struct
   given is the struct taken. *)

open Mem

(* What [map] changes: the numbers of structs, the names of functions and
   the sites of panics. *)
type hooks = { st : int -> int; name : string -> string; site : site -> site }

let rec lay h (l : layout) : layout =
  match l with Cell l -> Cell (lay h l) | Struct (n, c) -> Struct (h.st n, c) | l -> l

let var h (v : var) = { v with layout = lay h v.layout }

let atom h (a : atom) : atom =
  match a with Var v -> Var (var h v) | Fn_ptr s -> Fn_ptr (h.name s) | a -> a

let atoms h = List.map (atom h)

let rt h (r : rt) : rt =
  match r with
  | Array_get l -> Array_get (lay h l)
  | Array_take l -> Array_take (lay h l)
  | Array_set l -> Array_set (lay h l)
  | Array_push l -> Array_push (lay h l)
  | Array_set_taking l -> Array_set_taking (lay h l)
  | Array_push_taking l -> Array_push_taking (lay h l)
  | Array_set_field (n, k, l) -> Array_set_field (h.st n, k, lay h l)
  | Array_set_field_taking (n, k, l) ->
      Array_set_field_taking (h.st n, k, lay h l)
  | Buf_get l -> Buf_get (lay h l)
  | Buf_take l -> Buf_take (lay h l)
  | Buf_set l -> Buf_set (lay h l)
  | Buf_set_field (n, k, l) -> Buf_set_field (h.st n, k, lay h l)
  | Array_reserve l -> Array_reserve (lay h l)
  | ( Array_len | Array_check | Array_own | Array_data | Buf_check | Str_len
    | Str_concat | Str_eq | Show_int | Show_float | Show_bool | Float_of_int
    | Float_sqrt | Float_round | Float_truncate | Wrapping _ | Wrapping_neg
    | Bits _ | Widen | Narrow _ | Wrap_to _
    | Console_write | Console_error | Show_any | Equal_any _ | Compare_any _
    | Op_any _ | Value_any _ | New_desc _ | Nan_check _ | Nan_check_any _
    | Float_lanes | Float_sum | Here_set | Here_get | Here_put ) as r ->
      r

let kept h = List.map (fun (i, a) -> (i, atom h a))

let rhs h (r : rhs) : rhs =
  let a = atom h and xs = atoms h in
  match r with
  | Atom x -> Atom (a x)
  | Arith (op, x, y, s) -> Arith (op, a x, a y, h.site s)
  | Neg (x, s) -> Neg (a x, h.site s)
  | Compare (c, x, y) -> Compare (c, a x, a y)
  | Not x -> Not (a x)
  | Tag_of x -> Tag_of (a x)
  | Field (x, i, n) -> Field (a x, i, n)
  | Alloc { tag; fields; words; at } ->
      Alloc
        {
          tag;
          fields = xs fields;
          words = xs words;
          at = Option.map (fun (t, slots) -> (a t, slots)) at;
        }
  | Alloc_array { elem; elems; desc } ->
      Alloc_array
        { elem = lay h elem; elems = xs elems; desc = Option.map a desc }
  | Call (f, args) -> Call (h.name f, xs args)
  | Runtime (r, args, s) -> Runtime (rt h r, xs args, Option.map h.site s)
  | Load v -> Load (var h v)
  | Addr v -> Addr (var h v)
  | To_word x -> To_word (a x)
  | Of_word (x, l) -> Of_word (a x, lay h l)
  | Global g -> Global g
  | Env_new cells -> Env_new (xs cells)
  | Env_get (x, n) -> Env_get (a x, n)
  | Arg (x, n) -> Arg (a x, n)
  | Block_of (f, env) -> Block_of (h.name f, a env)
  | Impl (d, blocks) -> Impl (d, xs blocks)
  | Install { outer; impls; deps; ndeps } ->
      Install
        { outer = a outer; impls = xs impls; deps = a deps; ndeps = a ndeps }
  | Given { outer; caller; deps } ->
      Given { outer = a outer; caller = a caller; deps }
  | Op_block (x, d, n) -> Op_block (a x, d, n)
  | Is_unique x -> Is_unique (a x)
  | Make_struct fields -> Make_struct (xs fields)
  | Struct_get (x, n) -> Struct_get (a x, n)
  | Pack ps -> Pack (List.map (fun (x, at, n) -> (a x, at, n)) ps)
  | Unpack (x, at, n) -> Unpack (a x, at, n)
  | Reset (x, k) -> Reset (a x, kept h k)
  | Hole (x, n) -> Hole (a x, n)

let rec stmt h (s : stmt) : stmt =
  let a = atom h and v = var h and b = block h in
  match s with
  | Let (x, r) -> Let (v x, rhs h r)
  | Decl x -> Decl (v x)
  | Set (x, y) -> Set (v x, a y)
  | Store (x, y) -> Store (v x, a y)
  | Dup x -> Dup (a x)
  | Drop x -> Drop (a x)
  | Dup_word (x, d) -> Dup_word (a x, a d)
  | Drop_word (x, d) -> Drop_word (a x, a d)
  | Free (x, k) -> Free (a x, kept h k)
  | Free_token x -> Free_token (a x)
  | Fill (p, x) -> Fill (a p, a x)
  | Do r -> Do (rhs h r)
  | Call_fails { result; fn; args; error; on_error } ->
      Call_fails
        {
          result = v result;
          fn = h.name fn;
          args = atoms h args;
          error = v error;
          on_error = b on_error;
        }
  | Call_block { result; block = blk; ev; args; error; on_error } ->
      Call_block
        {
          result = v result;
          block = a blk;
          ev = a ev;
          args = atoms h args;
          error = v error;
          on_error = Option.map b on_error;
        }
  | Call_handler { result; handler; outer; body; desc; deps; error; on_error }
    ->
      Call_handler
        {
          result = v result;
          handler = a handler;
          outer = a outer;
          body = a body;
          desc = a desc;
          deps;
          error = v error;
          on_error = Option.map b on_error;
        }
  | If (c, t, e) -> If (a c, b t, b e)
  | Switch (x, cases, other) ->
      Switch (a x, List.map (fun (n, c) -> (n, b c)) cases, b other)
  | Loop (l, body) -> Loop (l, b body)
  | Break l -> Break l
  | Joins (first, joins) ->
      Joins (b first, List.map (fun (l, j) -> (l, b j)) joins)
  | Jump l -> Jump l
  | Catch { label; body; error; handler } ->
      Catch { label; body = b body; error = v error; handler = b handler }
  | Raise (x, l) -> Raise (a x, l)
  | Return x -> Return (a x)
  | Assert (x, s) -> Assert (a x, h.site s)
  | Panic (s, msg) -> Panic (h.site s, msg)

and block h (b : block) = List.map (stmt h) b

(* [f], its layouts, the functions it names and its panics' sites
   changed by [h]. *)
let map_fn h (f : fn) : fn =
  {
    f with
    params = List.map (var h) f.params;
    inout = List.map (var h) f.inout;
    words = List.map (fun (n, v) -> (n, var h v)) f.words;
    result = lay h f.result;
    body = block h f.body;
  }

(* What two functions must have the same of to fold: all of it but its
   name and where it is, with its layouts, callees and sites made
   [canon]'s, and a call of itself a call of no name. Compared as bytes:
   [Marshal] writes equal values as equal bytes, without sharing. *)
let key canon (f : fn) =
  let h =
    { canon with name = (fun g -> if g = f.name then "" else canon.name g) }
  in
  let f = map_fn h f in
  Marshal.to_string
    ( f.params,
      f.modes,
      f.inout,
      f.words,
      f.result,
      f.fails,
      f.body )
    [ No_sharing ]

let program (p : program) : program =
  (* each struct's number: the first of those whose fields are laid out
     the same *)
  let structs = Array.of_list p.structs in
  let first = Hashtbl.create 16 in
  Array.iteri
    (fun n fields ->
      if not (Hashtbl.mem first fields) then Hashtbl.replace first fields n)
    structs;
  let st n = Hashtbl.find first structs.(n) in
  (* each function's name: the function it's folded into, if it is *)
  let into = Hashtbl.create 64 in
  let rec name g =
    match Hashtbl.find_opt into g with Some f -> name f | None -> g
  in
  let canon = { st; name; site = (fun s -> { s with sid = 0 }) } in
  let rec round (fns : fn list) =
    (* the first of each key, by key, and whether any folded *)
    let seen = Hashtbl.create 1024 in
    let folded =
      List.fold_left
        (fun folded (f : fn) ->
          let k = key canon f in
          match Hashtbl.find_opt seen k with
          | Some g ->
              Hashtbl.replace into f.name g;
              true
          | None ->
              Hashtbl.replace seen k f.name;
              folded)
        false fns
    in
    let fns = List.filter (fun (f : fn) -> not (Hashtbl.mem into f.name)) fns in
    if folded then round fns else fns
  in
  let fns = round p.fns in
  (* the program with each function named by what it's folded into, and
     each site that's still used, by the first of those that say the
     same, which every one of them is now *)
  let sites = Hashtbl.create 1024 in
  let used = Hashtbl.create 1024 in
  let site (s : site) =
    let same = { s with sid = 0 } in
    let s =
      match Hashtbl.find_opt sites same with
      | Some s -> s
      | None ->
          Hashtbl.replace sites same s;
          s
    in
    Hashtbl.replace used s.sid ();
    s
  in
  let h = { st; name; site } in
  let fns = List.map (map_fn h) fns in
  let overflow = site p.overflow in
  {
    p with
    fns;
    start = name p.start;
    values = List.map (fun (v : value) -> { v with vfn = name v.vfn }) p.values;
    sites = List.filter (fun (s : site) -> Hashtbl.mem used s.sid) p.sites;
    overflow;
  }
