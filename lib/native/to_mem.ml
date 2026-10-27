(* Core to Mem IR (mem.ml), for the native slice's subset, in the debug
   build's strategy (compiler.md, "Native slice"; foundations.md,
   decisions 1, 4 and 13).

   Only what `$start` reaches is compiled. Core is expression-shaped and
   Mem is statements in A-normal form, so each expression is compiled
   into the statements that compute it, ending in an atom that holds its
   value: an `if` or a `match` that gives a value sets a variable declared
   before it, in each branch.

   Reference counting is naive, the baseline Perceus is measured against
   (H3): every use of a counted variable is a [Dup], into a fresh
   temporary, which whatever uses it takes. Something that only reads a
   value, a `match` or a field, drops the temporary once it's done. A
   variable is dropped when its scope ends, and so is every value that's
   still held when a [Break] or a [Raise] leaves its scope: the
   function's state keeps, for each scope it's in, the counted values
   held there ([frame]).

   Nothing is specialized. A generic function is compiled once, and
   takes a descriptor for each of its type variables and one for each of
   its requirements, as hidden parameters; a value of a type variable is
   one word, counted through its descriptor. A block is lifted to a
   function with a block's signature, whose environment, on the writer's
   stack, holds the address of each local it captures, so it shares
   them. Evidence is a chain on the stack: a `with` calls the code of the
   handler's description, which makes the handler's state as its own
   locals, installs its instance, and calls the `with`'s body, lifted as
   a block, with that evidence.

   What the subset leaves out, a `Map` or a `Set`, a type's own `show`,
   `key` or operators, the world but the real `Console`, is an
   [Unsupported] error at the code that needs it, which the driver
   reports. *)

open Mem
module C = Core

let sprintf = Printf.sprintf
let bug what = failwith ("bug: native lowering: " ^ what)

(* [what] isn't in the native slice yet, at [loc]: "a block". *)
exception Unsupported of Loc.t * string

let unsupported loc what = raise (Unsupported (loc, what))

(* ---- the program ---- *)

(* What compiling the whole program shares: every type declared and
   every function, by path, and the types with a `show`, a `key` or an
   operator of their own; the C name given to each function compiled;
   the functions still to compile, each with the code that first called
   it, and those lifted from blocks and handlers; the string literals,
   panic sites, error tags, dependencies, descriptors, declarations and
   associated values so far; and [nwords], how many of the type
   variables of the function being compiled are words, [Var 0] to
   [Var (nwords - 1)]: any other is one inference left undecided. *)
type ctx = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
  fns : (Path.t, C.fn_def) Hashtbl.t;
  own_members : (Path.t, string) Hashtbl.t;
  names : (Path.t, string) Hashtbl.t;
  taken : (string, unit) Hashtbl.t;
  mutable todo : (Path.t * Loc.t) list;
  mutable lifted : Mem.fn list;  (** most recent first *)
  strings : (string, int) Hashtbl.t;
  mutable string_list : string list;  (** most recent first *)
  mutable sites : site list;  (** most recent first *)
  mutable nsites : int;  (** how many [sites] has, the next one's number *)
  tags : (string, int) Hashtbl.t;
  deps : (Path.t, int) Hashtbl.t;
  descs : (bool * Ty.ty, int) Hashtbl.t;
  mutable desc_list : Mem.desc list;  (** most recent first *)
  decls : (Path.t, int) Hashtbl.t;
  decl_bodies : (int, Mem.decl) Hashtbl.t;
  values : (Path.t, Mem.value) Hashtbl.t;
  mutable nwords : int;
  release : bool;
      (** a release build's, which keeps a copied record or tuple as a C struct
          ([Struct]) *)
  boxed : (Ty.ty, unit) Hashtbl.t;
      (** the copied types kept boxed all the same, since a value of one would
          be a word or in an object: found compiling the program, which is then
          compiled again ([Demote]) *)
  structs : (Ty.ty, int) Hashtbl.t;  (** each [Struct]'s type, by its n *)
  mutable struct_list : strukt list;  (** most recent first *)
  recursive : (Path.t, bool) Hashtbl.t;
      (** whether each type's declaration reaches itself ([recursive]) *)
}

(* A value of the copied type would have to be one word, or a field of an
   object, so the type's values are kept boxed: the program is compiled
   again, with it among [boxed]. *)
exception Demote of Ty.ty

(* What one pass of compiling found to keep boxed, all of it. *)
exception Demoted of Ty.ty list

(* A C name for [s] no other function has: [s] with anything C doesn't
   allow in a name made `_`, and a number after it if another took that
   already. *)
let fresh_name cx s =
  let base =
    "ren_"
    ^ String.map
        (function
          | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_') as c -> c | _ -> '_')
        s
  in
  let rec free n =
    let name = if n = 0 then base else base ^ "_" ^ string_of_int n in
    if Hashtbl.mem cx.taken name then free (n + 1) else name
  in
  let name = free 0 in
  Hashtbl.replace cx.taken name ();
  name

(* The C name of the function at [p], given the first time it's asked
   for. *)
let c_name cx (p : Path.t) =
  match Hashtbl.find_opt cx.names p with
  | Some n -> n
  | None ->
      let name = fresh_name cx (Path.full p) in
      Hashtbl.replace cx.names p name;
      name

let literal cx s =
  match Hashtbl.find_opt cx.strings s with
  | Some n -> Lit n
  | None ->
      let n = Hashtbl.length cx.strings in
      Hashtbl.replace cx.strings s n;
      cx.string_list <- s :: cx.string_list;
      Lit n

let new_site cx ?wrap ?(kind = Panics) loc =
  let s = { sid = cx.nsites; loc; wrap; kind } in
  cx.sites <- s :: cx.sites;
  cx.nsites <- cx.nsites + 1;
  s

(* The number of [key] in [table], given the first time it's asked
   for. *)
let number table key =
  match Hashtbl.find_opt table key with
  | Some n -> n
  | None ->
      let n = Hashtbl.length table in
      Hashtbl.replace table key n;
      n

(* An error tag's number, the same for every error of that name: two
   tags with one name are one error (errors.md, "Tags are structural"). *)
let tag_id cx name = number cx.tags name

(* A dependency's number, which evidence finds it by. *)
let dep_id cx dep = number cx.deps dep

(* ---- layouts ---- *)

let array_path = match Ty.array Ty.int with Con (p, _) -> p | _ -> bug "Array"
let cell_path = match C.cell_ty Ty.int with Con (p, _) -> p | _ -> bug "Cell"
let is_struct (l : layout) = match l with Struct _ -> true | _ -> false

let is_cell (t : Ty.ty) =
  match t with Con (p, [ _ ]) -> p = cell_path | _ -> false

(* [t], a type in a declaration, with its parameters, [Var i], replaced by
   [args]. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | _ -> t

(* What a type is called in a message: `Map<Str, Int>`. *)
let ty_name (t : Ty.ty) =
  Ty.show
    (Ty.printer ~names:Path.full
       { ty = t; names = []; reqs = []; row_reqs = [] })
    t

(* A [Struct]'s type, by its number. *)
let struct_ty cx n =
  match
    Hashtbl.fold
      (fun t m found -> if m = n then Some t else found)
      cx.structs None
  with
  | Some t -> t
  | None -> bug "a struct that isn't there"

let scalar (l : layout) =
  match l with Int | Float | Bool | Unit | Enum -> true | _ -> false

(* Whether the type [p]'s declaration reaches [p] again, through the
   types of its fields and theirs, whatever their arguments: a recursive
   type, which is never a small value, since its values can be as big as
   the program makes them (Koka's [createDataDef], Kind/Repr.hs:66, which
   never makes a recursive type a value type). *)
let recursive cx (p : Path.t) =
  match Hashtbl.find_opt cx.recursive p with
  | Some r -> r
  | None ->
      let rec paths acc (t : Ty.ty) =
        match t with Con (q, ts) -> List.fold_left paths (q :: acc) ts | _ -> acc
      in
      let fields (fs : Iface.field list) =
        List.fold_left (fun acc (f : Iface.field) -> paths acc f.fty) [] fs
      in
      let mentions q =
        match Hashtbl.find_opt cx.types q with
        | Some { body = Record fs; _ } -> fields fs
        | Some { body = Sum cs; _ } ->
            List.concat_map (fun (c : Iface.ctor) -> fields c.cfields) cs
        | Some { body = Opaque (Rep r); _ } -> paths [] r
        | _ -> []
      in
      let seen = Hashtbl.create 8 in
      let rec reaches q =
        q = p
        || (not (Hashtbl.mem seen q))
           && (Hashtbl.replace seen q ();
               List.exists reaches (mentions q))
      in
      let r = List.exists reaches (mentions p) in
      Hashtbl.replace cx.recursive p r;
      r

let rec layout cx loc (t : Ty.ty) : layout =
  match t with
  | Con (p, args) when cx.release && not (Hashtbl.mem cx.boxed t) -> (
      match small cx loc p args with
      | Some (st, _) ->
          Struct (struct_id cx t st, List.exists is_object st.sfields)
      | None -> plain_layout cx loc t)
  | _ -> plain_layout cx loc t

(* How a release build keeps a value of [Con (p, args)] if it's a small
   value (foundations.md, decision 14), a C struct passed by value, and
   the slot of each field of each constructor, by tag:
   - a copied record or tuple (copied.ml) of scalars, however many;
   - a record or a tuple of at most four fields, each a scalar or an
     object;
   - a sum that isn't recursive, whose constructors' fields are each a
     scalar or an object, with a tag and at most three slots, which the
     constructors share where their fields' layouts are the same (as
     Koka's constructors of a value type share their scan fields,
     Kind/Repr.hs:150-170); or, if it has two constructors, one with no
     fields and one with an object, that object, or a value no object is
     (Koka's [DataAsMaybe], Core/Core.hs:533).
   A field that would be a struct itself isn't one of these: the type
   with that field stays boxed, and so the field's type is boxed too
   ([slot]), after which this one is a struct. *)
and small cx loc p args : (strukt * int list list) option =
  let t : Ty.ty = Con (p, args) in
  let types_of (fs : Iface.field list) =
    List.map (fun (f : Iface.field) -> subst args f.fty) fs
  in
  (* the layouts of fields of types [tys], if each is a scalar or an
     object *)
  let simple tys =
    let ls = List.map (layout cx loc) tys in
    if List.for_all (fun l -> scalar l || l = Boxed) ls then Some ls else None
  in
  let product tys =
    let slots = [ List.mapi (fun i _ -> i) tys ] in
    let plain = List.map (plain_layout cx loc) tys in
    if Copied.is ~types:(Hashtbl.find_opt cx.types) t && List.for_all scalar plain
    then Some ({ sfields = plain; skind = Product }, slots)
    else
      match simple tys with
      | Some ls when List.length ls <= 4 ->
          Some ({ sfields = ls; skind = Product }, slots)
      | _ -> None
  in
  if Ty.is_tuple p then product args
  else
    match Hashtbl.find_opt cx.types p with
    | Some { body = Record fs; _ } when not (recursive cx p) ->
        product (types_of fs)
    | Some { body = Sum cs; _ }
      when List.exists (fun (c : Iface.ctor) -> c.cfields <> []) cs
           && not (recursive cx p) -> (
        let ctors = List.map (fun (c : Iface.ctor) -> simple (types_of c.cfields)) cs in
        if List.mem None ctors then None
        else
          let ctors = List.map Option.get ctors in
          match ctors with
          | [ []; [ Boxed ] ] ->
              Some ({ sfields = [ Boxed ]; skind = Nullable (0, 1) }, [ []; [ 0 ] ])
          | [ [ Boxed ]; [] ] ->
              Some ({ sfields = [ Boxed ]; skind = Nullable (1, 0) }, [ [ 0 ]; [] ])
          | _ ->
              (* slot 0 is the tag; each field goes in the first slot after
                 of its layout that its constructor hasn't used *)
              let slots = ref [ (Int : layout) ] in
              let place ls =
                let used = ref [] in
                List.map
                  (fun l ->
                    let rec find i = function
                      | [] ->
                          slots := !slots @ [ l ];
                          i
                      | l' :: rest ->
                          if i > 0 && l' = l && not (List.mem i !used) then i
                          else find (i + 1) rest
                    in
                    let i = find 0 !slots in
                    used := i :: !used;
                    i)
                  ls
              in
              let placed = List.map place ctors in
              if List.length !slots <= 4 then
                Some ({ sfields = !slots; skind = Tagged }, placed)
              else None)
    | _ -> None

and struct_id cx (t : Ty.ty) st =
  match Hashtbl.find_opt cx.structs t with
  | Some n -> n
  | None ->
      let n = Hashtbl.length cx.structs in
      Hashtbl.replace cx.structs t n;
      cx.struct_list <- st :: cx.struct_list;
      n

and plain_layout cx loc (t : Ty.ty) : layout =
  match t with
  | _ when t = C.type_ty || t = C.dict_ty -> Desc
  | _ when t = C.evidence_ty -> Ev
  | Con (p, [ t ]) when p = cell_path -> Cell (layout cx loc t)
  | _ when t = Ty.int -> Int
  | _ when t = Ty.float -> Float
  | _ when t = Ty.bool -> Bool
  | _ when t = Ty.unit -> Unit
  | _ when t = Ty.str -> Boxed
  | Con (p, [ e ]) when p = array_path ->
      (* an array's elements are counted as words are, or never: a struct
         that holds an object is kept boxed instead *)
      (if cx.release then
         match layout cx loc e with
         | Struct (n, true) -> raise (Demote (struct_ty cx n))
         | _ -> ());
      Boxed
  | Con (p, _) when Ty.is_tuple p -> Boxed
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      | Some { body = Record _; _ } -> Boxed
      | Some { body = Sum ctors; _ } ->
          if List.for_all (fun (c : Iface.ctor) -> c.cfields = []) ctors then
            Enum
          else Boxed
      | Some { body = Opaque (Rep r); _ } -> layout cx loc (subst args r)
      | _ -> unsupported loc (sprintf "a value of type `%s`" (ty_name t)))
  | Errors _ -> Boxed
  | Var n when n < cx.nwords -> Word n
  (* any other type variable is one inference left undecided, and no
     value of its type is ever made *)
  | Var _ -> Unit
  | Fun _ -> Block
  (* a handler's description *)
  | Impl _ -> Boxed
  | Error -> bug "a type with an error"

(* [f] with [n] of the type variables words. *)
let with_words cx n f =
  let saved = cx.nwords in
  cx.nwords <- n;
  Fun.protect ~finally:(fun () -> cx.nwords <- saved) f

(* Where a field of an object is kept: a word of its own, [Slot n], or
   [bits] bits from bit [at] of word [n], which it shares with other small
   scalars ([Bits (n, at, bits)]). *)
type place = Slot of int | Bits of int * int * int

(* Where each field of a constructor goes, in the order they're declared:
   its place, and its layout; and how many words the object has. A
   field's word is the one of its number, whatever its type is given, so
   generic code finds a field where any other does, and the object's
   header says which hold objects (ren_rt.h, [ren_obj]); but a type with
   no parameters may pack its small scalars ([pack]). *)
type shape = { tag : int; places : (place * layout) list; words : int }

let shape tag layouts =
  {
    tag;
    places = List.mapi (fun i l -> (Slot i, l)) layouts;
    words = List.length layouts;
  }

(* How many bits a field of type [t] takes if it's a small scalar that can
   share a word: a [Bool] or a [Unit], a byte, or a sum none of whose
   constructors has fields, an [Enum], a byte for up to 256 of them (as
   Koka sizes one, Kind/Repr.hs, [createMaxDataDef]). *)
let rec small_bits cx (t : Ty.ty) =
  match t with
  | _ when t = Ty.bool || t = Ty.unit -> Some 8
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      | Some { body = Sum cs; _ }
        when cs <> [] && List.for_all (fun (c : Iface.ctor) -> c.cfields = []) cs
        ->
          let n = List.length cs in
          Some (if n <= 256 then 8 else if n <= 65536 then 16 else 32)
      | Some { body = Opaque (Rep r); _ } -> small_bits cx (subst args r)
      | _ -> None)
  | _ -> None

(* Where the fields of a constructor or a record, of types [tys], go if
   its small scalars are packed, and how many words it then has: the
   other fields first, a word each, in the order they're declared, then
   the small scalars, the widest first, each in the first word with room
   for it. Lean keeps its scalar fields after the objects, packed by
   size (lean.h:592-612, [lean_ctor_get_uint8] and the rest, and
   [ctor_set_uint*]); Ren's header masks which words hold objects, so the
   order of the rest needn't change. [None] if packing saves no word. *)
let pack cx (tys : Ty.ty list) : (place list * int) option =
  let small =
    List.filter_map
      (fun (i, t) -> Option.map (fun b -> (i, b)) (small_bits cx t))
      (List.mapi (fun i t -> (i, t)) tys)
  in
  let widest = List.stable_sort (fun (_, a) (_, b) -> compare b a) small in
  (* the bits used of each packed word, by its number among them *)
  let used = ref [||] and where = Hashtbl.create 8 in
  List.iter
    (fun (i, b) ->
      let rec fit k =
        if k = Array.length !used then (
          used := Array.append !used [| b |];
          Hashtbl.replace where i (k, 0))
        else if !used.(k) + b <= 64 then (
          Hashtbl.replace where i (k, !used.(k));
          !used.(k) <- !used.(k) + b)
        else fit (k + 1)
      in
      fit 0)
    widest;
  let packed = Array.length !used in
  if packed >= List.length small then None
  else
    let plain = List.length tys - List.length small in
    let next = ref 0 in
    let places =
      List.mapi
        (fun i _ ->
          match (Hashtbl.find_opt where i, List.assoc_opt i small) with
          | Some (k, at), Some b -> Bits (plain + k, at, b)
          | _ ->
              let n = !next in
              incr next;
              Slot n)
        tys
    in
    Some (places, plain + packed)

(* The layout of a field of type [t] of an object: a word, which a
   [Struct] can't be, so its type is kept boxed instead. *)
let slot cx loc (t : Ty.ty) =
  match layout cx loc t with
  | Struct (n, _) -> raise (Demote (struct_ty cx n))
  | l -> l

(* The [n]-th struct. *)
let struct_of cx n = List.nth (List.rev cx.struct_list) n

(* [l], an array's elements': counted as words are, or never, so a
   struct that holds an object is kept boxed instead. *)
let element cx (l : layout) =
  match l with Struct (n, true) -> raise (Demote (struct_ty cx n)) | _ -> l

(* [l], where a value has to be a word: a [Struct]'s type is kept boxed
   instead. *)
let word_only cx (l : layout) =
  match l with Struct (n, _) -> raise (Demote (struct_ty cx n)) | _ -> ()

(* The declaration of the named type [t], and its arguments. *)
let rec decl cx loc (t : Ty.ty) =
  match t with
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      (* an opaque type is its representation, where it can be seen *)
      | Some { body = Opaque (Rep r); _ } -> decl cx loc (subst args r)
      | Some d -> (d, args)
      | None -> unsupported loc (sprintf "a value of type `%s`" (ty_name t)))
  | _ -> bug "a constructor of a type that isn't named"

(* Whether an object of the type declared [d], [t], packs its small
   scalars: only a type with no parameters, and one that's an object. *)
let packs cx loc (d : Iface.type_decl) (t : Ty.ty) =
  d.params = [] && with_words cx 0 (fun () -> layout cx loc t) = Boxed

(* The shape of an object of [t], declared [d], whose fields, of types
   [tys], are given [layouts]: packed if it can be ([pack]). *)
let placed cx loc d t tag tys layouts =
  match if packs cx loc d t then pack cx tys else None with
  | Some (places, words) ->
      { tag; places = List.combine places layouts; words }
  | None -> shape tag layouts

(* The constructor [c] of the sum type [t]: of a small value, its fields'
   slots in the struct ([small]). *)
let ctor_shape cx loc (t : Ty.ty) c =
  let small_of (t : Ty.ty) =
    match (t, layout cx loc t) with
    | Con (p, args), Struct _ -> small cx loc p args
    | _ -> None
  in
  (* an opaque type is its representation, where it can be seen *)
  let rec rep (t : Ty.ty) =
    match t with
    | Con (p, args) -> (
        match Hashtbl.find_opt cx.types p with
        | Some { body = Opaque (Rep r); _ } -> rep (subst args r)
        | _ -> t)
    | _ -> t
  in
  match (small_of (rep t), decl cx loc t) with
  | Some (st, slots), ({ body = Sum ctors; _ }, _) ->
      let rec find i = function
        | [] -> bug ("no constructor " ^ c)
        | (k : Iface.ctor) :: _ when k.cname = c ->
            {
              tag = i;
              places =
                List.map2
                  (fun n _ -> (Slot n, List.nth st.sfields n))
                  (List.nth slots i) k.cfields;
              words = List.length st.sfields;
            }
        | _ :: rest -> find (i + 1) rest
      in
      find 0 ctors
  | _ ->
  match decl cx loc t with
  | ({ body = Sum ctors; _ } as d), args ->
      let rec find i = function
        | [] -> bug ("no constructor " ^ c)
        | (k : Iface.ctor) :: _ when k.cname = c ->
            let tys =
              List.map (fun (f : Iface.field) -> subst args f.fty) k.cfields
            in
            placed cx loc d t i tys (List.map (slot cx loc) tys)
        | _ :: rest -> find (i + 1) rest
      in
      find 0 ctors
  | _ -> bug ("a constructor of a type that isn't a sum: " ^ c)

(* A sum type's constructors, by tag. *)
let rec ctors cx (t : Ty.ty) =
  match t with
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      | Some { body = Sum cs; _ } -> Some cs
      | Some { body = Opaque (Rep r); _ } -> ctors cx (subst args r)
      | _ -> None)
  | _ -> None

(* A record's fields, in the order they're declared, with their types. *)
let record_fields cx loc (t : Ty.ty) =
  match decl cx loc t with
  | { body = Record fs; _ }, args ->
      List.map (fun (f : Iface.field) -> (f.fname, subst args f.fty)) fs
  | { body = Opaque _; _ }, _ ->
      unsupported loc (sprintf "a field of the opaque type `%s`" (ty_name t))
  | _ -> bug "fields of a type that isn't a record"

let record_shape cx loc t =
  let tys = List.map snd (record_fields cx loc t) in
  placed cx loc (fst (decl cx loc t)) t 0 tys (List.map (slot cx loc) tys)

let tuple_shape cx loc (t : Ty.ty) =
  match t with
  | Con (_, parts) -> shape 0 (List.map (slot cx loc) parts)
  | _ -> bug "a tuple whose type isn't one"

let error_shape cx loc name (payload : Ty.ty list) =
  shape (tag_id cx name) (List.map (slot cx loc) payload)

(* ---- descriptors ---- *)

(* The program's descriptor of [t], static data, by its index: a closed
   type's, whose type variables are ones inference left undecided, or,
   with [template], a field's type in a declaration, whose [Var i] is the
   type's [i]-th parameter. *)
let rec static_desc cx loc ~template (t : Ty.ty) : int =
  (* what a descriptor describes is a word, or in one *)
  if not template then no_struct_in cx loc t;
  match Hashtbl.find_opt cx.descs (template, t) with
  | Some n -> n
  | None ->
      let arg = static_desc cx loc ~template in
      let kind, args =
        match t with
        | _ when t = Ty.int -> (D_int, [])
        | _ when t = Ty.float -> (D_float, [])
        | _ when t = Ty.bool -> (D_bool, [])
        | _ when t = Ty.unit -> (D_unit, [])
        | _ when t = Ty.str -> (D_str, [])
        | Con (p, [ e ]) when p = array_path -> (D_array, [ arg e ])
        | Con (p, parts) when Ty.is_tuple p -> (D_tuple, List.map arg parts)
        | Con (p, args) -> (D_named (decl_id cx loc p), List.map arg args)
        | Errors _ -> (D_errors, [])
        | Var i when template -> (D_var i, [])
        | Var _ -> (D_unknown, [])
        | Fun _ | Impl _ | Error -> bug "a descriptor of what has none"
      in
      let counted =
        match kind with
        | D_str | D_array | D_tuple | D_errors -> true
        | D_named k -> (
            match (Hashtbl.find cx.decl_bodies k).dbody with
            | Record_decl _ -> true
            | Sum_decl cs -> List.exists (fun (_, ts) -> ts <> []) cs
            (* an opaque type's is what it's represented as, which the
               runtime finds from its template ([ren_counted_in]) *)
            | Rep_decl _ ->
                (not template)
                && is_object (with_words cx 0 (fun () -> layout cx loc t)))
        | _ -> false
      in
      let n = List.length cx.desc_list in
      cx.desc_list <-
        { dkind = kind; dargs = args; dcounted = counted } :: cx.desc_list;
      Hashtbl.replace cx.descs (template, t) n;
      n

(* A [Struct]'s type in [t], kept boxed instead: what has a descriptor
   is a word, or in one. *)
and no_struct_in cx loc (t : Ty.ty) =
  match t with
  | Con (p, args) ->
      if
        cx.release
        && (not (Hashtbl.mem cx.boxed t))
        && small cx loc p args <> None
      then raise (Demote t);
      List.iter (no_struct_in cx loc) args
  | _ -> ()

(* The program's declaration of the type [p], by its index: its fields'
   types as templates. A type with a `show`, a `key` or an operator of its
   own would need its member called from the walk, which the slice
   doesn't do. *)
and decl_id cx loc (p : Path.t) : int =
  match Hashtbl.find_opt cx.decls p with
  | Some n -> n
  | None ->
      (match Hashtbl.find_opt cx.own_members p with
      | Some what ->
          unsupported loc
            (sprintf "a value of `%s`, which has %s of its own" p.name what)
      | None -> ());
      let d =
        match Hashtbl.find_opt cx.types p with
        | Some d -> d
        | None -> unsupported loc (sprintf "a value of type `%s`" p.name)
      in
      let n = Hashtbl.length cx.decls in
      Hashtbl.replace cx.decls p n;
      (* the body's templates may name this type again: it has its number
         first *)
      Hashtbl.replace cx.decl_bodies n
        { dname = p.name; dopaque = d.opaque; dbody = Rep_decl 0; dplaces = [] };
      let tmpl t = static_desc cx loc ~template:true t in
      let dbody =
        match d.body with
        | Record fs ->
            Record_decl
              (List.map (fun (f : Iface.field) -> (f.fname, tmpl f.fty)) fs)
        | Sum cs ->
            Sum_decl
              (List.map
                 (fun (c : Iface.ctor) ->
                   ( c.cname,
                     List.map (fun (f : Iface.field) -> tmpl f.fty) c.cfields ))
                 cs)
        | Opaque (Rep r) -> Rep_decl (tmpl r)
        | _ -> unsupported loc (sprintf "a value of type `%s`" p.name)
      in
      (* where each field is, for the walks, as [placed] puts it *)
      let places (fs : Iface.field list) =
        let tys = List.map (fun (f : Iface.field) -> f.fty) fs in
        match if packs cx loc d (Con (p, [])) then pack cx tys else None with
        | None -> None
        | Some (places, _) ->
            Some
              (List.map
                 (function
                   | Slot n -> (n lsl 16) lor 64
                   | Bits (n, at, bits) -> (n lsl 16) lor (at lsl 8) lor bits)
                 places)
      in
      let dplaces =
        match d.body with
        | Record fs -> [ places fs ]
        | Sum cs -> List.map (fun (c : Iface.ctor) -> places c.cfields) cs
        | _ -> []
      in
      Hashtbl.replace cx.decl_bodies n
        { dname = p.name; dopaque = d.opaque; dbody; dplaces };
      n

(* Whether a function returns a status and its value through a pointer:
   whether its type says it can fail with a tag. A row of errors that
   only has a tail, `! ..e`, which every function whose errors are
   inferred has, can't bring one in unless a parameter's type has that
   tail too, and no parameter is a block in the subset: so most
   functions, fib's among them, return their value. *)
let fn_fails (f : C.fn_def) =
  match f.scheme.ty with
  | Fun (ps, _, errs, _) ->
      errs.labels <> []
      || errs.tail <> None
         && List.exists
              (fun (p : Ty.param) ->
                match p.ty with Fun _ -> true | _ -> false)
              ps
  | _ -> false

(* ---- a function ---- *)

(* What a scope holds, which a [Break] or [Raise] that leaves it drops.
   [Catch_frame] is the body of a [Catch], where a [Raise] goes, with the
   [after] of the `Finally` it's for, which a [Break] that leaves it runs
   first. *)
type frame_kind =
  | Fn_frame
  | Loop_frame of int
  | Catch_frame of int * C.expr option
  | Scope

type frame = { kind : frame_kind; mutable live : var list }

module Vars = Map.Make (Int)

(* Where an expression is compiled: Mem's variable for each of Core's in
   scope, by id, and the scopes it's in, the innermost first. *)
type env = { vars : var Vars.t; frames : frame list }

(* What the code of a handler's description is given, which its
   [Instance] uses: the `with`'s body, as a block, its descriptor, and the
   dependencies to install the instance for. *)
type handler_args = {
  outer : var;
  body : var;
  body_desc : var;
  deps : var;
  ndeps : var;
}

(* A function being compiled: the statements of the block being built,
   last first, the numbers given out, and [here], the call that reached
   it, which a problem in the prelude, whose source can't be shown, is
   said to be at; its C name, which code lifted out of it is named after;
   whether it can fail; the descriptor of each of its type variables
   that's a word; and, in a handler's code, what it's given. *)
type fs = {
  cx : ctx;
  fname : string;
  mutable out : stmt list;
  mutable next_id : int;
  mutable next_label : int;
  here : Loc.t;
  fails : bool;
  mutable words : (int * var) list;
  mutable handler : handler_args option;
  known : (int * Path.t) list;
      (** the [With]s whose handler a release build knows (Core's [known]):
          their evidence and dependency. Each installs nothing *)
}

let at fs (loc : Loc.t) = if loc.file = Prelude.file then fs.here else loc
let unsupported_at fs loc what = unsupported (at fs loc) what
let layout_at fs loc t = layout fs.cx (at fs loc) t
let emit fs s = fs.out <- s :: fs.out

let fresh fs name layout =
  fs.next_id <- fs.next_id + 1;
  { id = fs.next_id; name; layout }

let label fs =
  fs.next_label <- fs.next_label + 1;
  fs.next_label

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

(* Of a record or a tuple [x], the [n]-th of [size] fields, borrowed. *)
let field_rhs (x : atom) n size : rhs =
  match atom_layout x with
  | Struct _ -> Struct_get (x, n)
  | _ -> Field (x, n, size)

(* Of a record, a tuple or a constructor [x] of [words] words, the field
   kept at [place], of layout [l], borrowed, as a new variable: a small
   scalar packed with others is its word, then its bits. *)
let field_var fs name (x : atom) ((place, l) : place * layout) words : var =
  let get name l rhs =
    fs.next_id <- fs.next_id + 1;
    let v = { id = fs.next_id; name; layout = l } in
    fs.out <- Let (v, rhs) :: fs.out;
    v
  in
  match place with
  | Slot n -> get name l (field_rhs x n words)
  | Bits (n, at, bits) ->
      let w = get "$packed" Int (Field (x, n, words)) in
      get name l (Unpack (Var w, at, bits))

(* The descriptor of the type variable [n], a word here. *)
let word_desc fs n : atom =
  match List.assoc_opt n fs.words with
  | Some d -> Var d
  | None -> unsupported fs.here "a value of a type variable here"

(* One more reference to [x], or one fewer: through its descriptor if
   it's a word, and to each object in it if it's a struct. *)
let dup fs (x : atom) =
  match atom_layout x with
  | Word n -> emit fs (Dup_word (x, word_desc fs n))
  | l when counted l -> emit fs (Dup x)
  | _ -> ()

let drop_now fs (x : atom) =
  match atom_layout x with
  | Word n -> emit fs (Drop_word (x, word_desc fs n))
  | l when counted l -> emit fs (Drop x)
  | _ -> ()

(* The statements [f] emits, as a block, and what it gives. *)
let sub fs f =
  let saved = fs.out in
  fs.out <- [];
  let r = f () in
  let b = List.rev fs.out in
  fs.out <- saved;
  (b, r)

let block fs f = fst (sub fs f)

(* [f], whose code may not run: what each scope holds is put back after,
   as it was, for the code that runs instead. *)
let branch env f =
  let saved = List.map (fun fr -> fr.live) env.frames in
  let r = f () in
  List.iter2 (fun fr l -> fr.live <- l) env.frames saved;
  r

(* [v] holds a counted value its scope owns. *)
let own env (v : var) =
  if counted v.layout then
    match env.frames with
    | fr :: _ -> fr.live <- v :: fr.live
    | [] -> bug "a value held outside every scope"

(* [x] has been taken: its scope doesn't own it any more. *)
let consume env (x : atom) =
  match x with
  | Var v when counted v.layout ->
      let rec go = function
        | [] -> bug ("a value taken that nothing held: " ^ show_var v)
        | fr :: rest ->
            if List.memq v fr.live then
              fr.live <- List.filter (fun w -> w != v) fr.live
            else go rest
      in
      go env.frames
  | _ -> ()

(* Done with [x], which was only read. *)
let drop fs env (x : atom) =
  match x with
  | Var v when counted v.layout ->
      drop_now fs x;
      consume env x
  | _ -> ()

(* A new variable holding [rhs], which it owns. *)
let owned fs env name layout rhs =
  let v = fresh fs name layout in
  emit fs (Let (v, rhs));
  own env v;
  Var v

(* A new variable holding [rhs], borrowed from something else that holds
   it: a field. *)
let borrowed fs name layout rhs =
  let v = fresh fs name layout in
  emit fs (Let (v, rhs));
  Var v

(* Whether `map` can replace each element of an array of [t]s with a
   [u] where it is (prelude.ml, [map_into]): it reads each as a [t] and
   writes the [u] it gives back as a [t] (to_mem's [Unsafe_cast]), so a
   [t] must hold a [u] whole, and the array must count them as it would
   an array of [u]s. A value of the same layout; or a [t] that's an
   [Int], which holds any word that isn't an object, a [Float]'s bits
   too. Not a type variable's word, which may be either. *)
let scalar_element (l : layout) =
  match l with Int | Float | Bool | Unit | Enum -> true | _ -> false

let same_elements (t : layout) (u : layout) =
  match (t, u) with
  | Word _, _ | _, Word _ -> false
  | Int, u -> scalar_element u
  | t, u -> t = u

(* An atom of [layout] for code that never runs, after a [Raise] or a
   [Break]. *)
let rec dummy fs env (l : layout) : atom =
  match l with
  | Int -> Int 0L
  | Float -> Float 0.
  | Bool -> Bool false
  | Unit -> Unit
  | Enum -> Enum_tag 0
  | Boxed -> Scalar_ctor 0
  | Word _ -> owned fs env "$never" l (To_word Unit)
  | Desc -> Desc_lit 0
  | Ev -> No_ev
  | Ptr -> Fn_ptr "NULL"
  | Struct (n, _) ->
      owned fs env "$never" l
        (Make_struct (List.map (dummy fs env) (struct_of fs.cx n).sfields))
  | Cell _ | Block | Token ->
      bug "a cell, a block or a token where nothing runs"

let drop_all fs (fr : frame) = List.iter (fun v -> drop_now fs (Var v)) fr.live

(* Fail with [err], which has been taken: drop what every scope up to the
   [Catch] that handles it holds, or the function's, and raise it. In a
   function that can't fail, with no [Catch], an error can't happen: the
   types say whatever could fail here won't, a callee's row variable
   standing for no errors. *)
let raise_error fs env err =
  let rec go = function
    | [] -> bug "a raise outside the function"
    | fr :: rest -> (
        drop_all fs fr;
        match fr.kind with
        | Catch_frame (l, _) -> emit fs (Raise (err, Some l))
        | Fn_frame when fs.fails -> emit fs (Raise (err, None))
        | Fn_frame ->
            emit fs
              (Panic
                 ( new_site fs.cx fs.here,
                   "an error where the types say there's none" ))
        | Loop_frame _ | Scope -> go rest)
  in
  go env.frames

(* Whether an error raised here can go anywhere: to a [Catch], or out
   of a function that can fail. *)
let can_raise fs env =
  fs.fails
  || List.exists
       (fun fr -> match fr.kind with Catch_frame _ -> true | _ -> false)
       env.frames

let mem_var env (v : C.var) =
  match Vars.find_opt v.id env.vars with
  | Some m -> m
  | None -> bug ("`" ^ v.name ^ "` used outside its scope")

let bind env (v : C.var) m = { env with vars = Vars.add v.id m env.vars }

(* The variables a pattern binds, each once. *)
let rec pattern_vars (p : C.pattern) =
  match p.pkind with
  | PWild | PInt _ | PBool _ -> []
  | PVar v -> [ v ]
  | PCon (_, _, ps) | PTag (_, ps) | PTuple ps ->
      List.concat_map pattern_vars ps
  | POr (p :: _) -> pattern_vars p
  | POr [] -> []

let cmp_of (op : Ast.binop) =
  match op with
  | Lt -> Some Lt
  | Le -> Some Le
  | Gt -> Some Gt
  | Ge -> Some Ge
  | _ -> None

let wrapping_meth (op : Ast.binop) =
  match op with
  | Add -> Some "wrapping_add"
  | Sub -> Some "wrapping_sub"
  | Mul -> Some "wrapping_mul"
  | _ -> None

(* The binary operator a requirement is: `add` is `+`; [None] is `neg`. *)
let op_of_req req : Ast.binop option =
  match req with
  | "add" -> Some Add
  | "sub" -> Some Sub
  | "mul" -> Some Mul
  | "div" -> Some Div
  | "rem" -> Some Mod
  | "neg" -> None
  | _ -> bug ("`" ^ req ^ "` as an operator")

(* The locals [e] refers to, anywhere in it: what a lifted `with` body
   captures, of those in scope where it's written. *)
let rec refs (e : C.expr) acc =
  let ids vs acc = List.rev_append vs acc in
  let desc_ids ds acc =
    List.fold_left (fun acc d -> ids (C.desc_vars d) acc) acc ds
  in
  let dict_ids ds acc =
    List.fold_left (fun acc d -> ids (C.dict_vars d) acc) acc ds
  in
  let own =
    match e.kind with
    | Local v | Assign (v, _) -> ids [ v ] acc
    | Call (_, args, ev) ->
        ids
          (ev
          :: List.filter_map
               (function C.Ref v -> Some v | Value _ -> None)
               args)
          acc
    | Dep_call { ev; _ } -> ids [ ev ] acc
    | With { outer; desc; _ } | With_handler { outer; desc; _ } ->
        desc_ids [ desc ] (ids [ outer ] acc)
    | Lambda { captures; _ } | Handler { captures; _ } -> ids captures acc
    | Global (_, _, ds, dicts) | Intrinsic (_, _, ds, dicts) ->
        dict_ids dicts (desc_ids ds acc)
    | Tag (_, _, ds) -> desc_ids ds acc
    | Prim
        ( (Equal d | Not_equal d | Compare (_, d) | Op (_, d) | Value_of (_, d)),
          _ )
    | Assert_equal (_, _, _, d) ->
        dict_ids [ d ] acc
    | _ -> acc
  in
  match e.kind with
  (* a lambda's and a handler's body see only what they capture *)
  | Lambda _ | Handler _ -> own
  | _ -> List.fold_left (fun acc c -> refs c acc) own (C.children e)

(* A new variable holding [rhs], borrowed: the variable itself. *)
let let_var fs name layout rhs =
  let v = fresh fs name layout in
  emit fs (Let (v, rhs));
  v

(* [v]'s value, borrowed, as a variable. *)
let borrow_var fs env (v : C.var) : var =
  let m = mem_var env v in
  match m.layout with Cell l -> let_var fs v.name l (Load m) | _ -> m

(* [v]'s value, owned: a local's, counted again, or what its cell holds. *)
let read fs env (v : C.var) : atom =
  let m = mem_var env v in
  match m.layout with
  | Cell l ->
      let t = borrowed fs v.name l (Load m) in
      dup fs t;
      (match t with Var tv -> own env tv | _ -> ());
      t
  | l ->
      let t = fresh fs v.name l in
      emit fs (Let (t, Atom (Var m)));
      dup fs (Var t);
      own env t;
      Var t

(* [v]'s value, borrowed: evidence, which isn't counted, or a block. *)
let borrow fs env (v : C.var) : atom = Var (borrow_var fs env v)

(* The number of the operation [op] among its dependency's, in the order
   it declares them, which an implementation keeps them in. *)
let op_index fs loc dep op =
  match Hashtbl.find_opt fs.cx.types dep with
  | Some { body = Dep ops; _ } ->
      let rec find i = function
        | [] -> bug ("no operation " ^ op)
        | (f : Iface.field) :: _ when f.fname = op -> i
        | _ :: rest -> find (i + 1) rest
      in
      find 0 ops
  | _ ->
      unsupported (at fs loc) (sprintf "the dependency `%s`" (Path.local dep))

(* The tag of the prelude's [Result]'s constructor [c]: what a
   `finally` is given. *)
let result_tag cx c =
  match Hashtbl.find_opt cx.types (Path.prelude "Result") with
  | Some { body = Sum cs; _ } ->
      let rec find i = function
        | [] -> bug ("no constructor " ^ c)
        | (k : Iface.ctor) :: _ when k.cname = c -> i
        | _ :: rest -> find (i + 1) rest
      in
      find 0 cs
  | _ -> bug "no `Result`"

(* [x] as a word, borrowed: what a runtime walk is given. *)
let as_word fs (x : atom) : atom =
  word_only fs.cx (atom_layout x);
  match atom_layout x with
  | Word _ -> x
  | _ -> borrowed fs "$word" (Word 0) (To_word x)

(* What [rhs] gives, a word, as an owned value of [l]: a type
   variable's word as it is, anything else taken out of it. *)
let from_word fs env name (rhs : rhs) (l : layout) : atom =
  word_only fs.cx l;
  match l with
  | Word _ -> owned fs env name l rhs
  | _ ->
      let w = borrowed fs name (Word 0) rhs in
      owned fs env name l (Of_word (w, l))

(* [x] as a value of [l], what a callee takes: a word if that's what it
   takes and [x] isn't one. Taken. *)
let convert fs (x : atom) (l : layout) : atom =
  (match l with Word _ -> word_only fs.cx (atom_layout x) | _ -> ());
  match (l, atom_layout x) with
  | Word _, Word _ -> x
  | Word _, _ -> borrowed fs "$word" (Word 0) (To_word x)
  | _ -> x

(* The descriptor [d] stands for, owned: static if it's known, what a
   hidden parameter holds, or one built from those. *)
let rec desc fs env (d : C.desc) : atom =
  match d with
  | Known t -> Desc_lit (static_desc fs.cx fs.here ~template:false t)
  | Param v -> read fs env v
  | Errs _ ->
      Desc_lit
        (static_desc fs.cx fs.here ~template:false
           (Errors { labels = []; tail = None }))
  | Applied (p, ds) ->
      let args = List.map (desc fs env) ds in
      let how =
        if p = array_path then Of_array
        else if Ty.is_tuple p then Of_tuple
        else Of_decl (decl_id fs.cx fs.here p)
      in
      let r = owned fs env "$desc" Desc (Runtime (New_desc how, args, None)) in
      (* the runtime counts again what it keeps *)
      List.iter (drop fs env) args;
      r

(* A requirement's dictionary, owned: the descriptor of its type. *)
let dict fs env (d : C.dict) : atom =
  match d with
  | Dict_param v -> read fs env v
  | Derived { ddesc; _ } -> desc fs env ddesc

(* Whether [e] only computes, calling and changing nothing, so whatever
   it reads is the same before it and after. *)
let rec pure (e : C.expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Unit | Local _ -> true
  | Prim (_, args) -> List.for_all pure args
  | Field (r, _, _) -> pure r
  | Update (r, _, v) -> pure r && pure v
  | _ -> false

let rec expr fs env (e : C.expr) : atom =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  match e.kind with
  | Int n -> Int n
  | Float f -> Float f
  | Bool b -> Bool b
  | Unit -> Unit
  | Str s -> literal cx s
  | Local v -> read fs env v
  | Let (v, value, body) ->
      let x = expr fs env value in
      let m = fresh fs v.name (lay v.ty) in
      emit fs (Let (m, Atom x));
      consume env x;
      own env m;
      let r = expr fs (bind env v m) body in
      drop fs env (Var m);
      r
  | Assign (v, value) ->
      let x = expr fs env value in
      let m = mem_var env v in
      consume env x;
      (match m.layout with
      | Cell l ->
          if counted l then drop_now fs (borrowed fs v.name l (Load m));
          emit fs (Store (m, x))
      | _ ->
          drop_now fs (Var m);
          emit fs (Set (m, x)));
      Unit
  | Seq (a, b) ->
      drop fs env (expr fs env a);
      expr fs env b
  | If (c, t, f) ->
      let c = expr fs env c in
      let r = fresh fs "$if" (lay e.ty) in
      emit fs (Decl r);
      let arm x =
        block fs (fun () ->
            branch env (fun () ->
                let a = expr fs env x in
                consume env a;
                emit fs (Set (r, a))))
      in
      let t = arm t in
      let f = arm f in
      emit fs (If (c, t, f));
      own env r;
      Var r
  | While (c, body) ->
      let l = label fs in
      let env' =
        { env with frames = { kind = Loop_frame l; live = [] } :: env.frames }
      in
      let b =
        block fs (fun () ->
            let c = expr fs env' c in
            emit fs (If (c, [], block fs (fun () -> break_out fs env')));
            drop fs env' (expr fs env' body))
      in
      emit fs (Loop (l, b));
      Unit
  | Break ->
      break_out fs env;
      dummy fs env (lay e.ty)
  | Call (f, args, ev) -> call fs env e f args ev
  | Dep_call { dep; op; fty; ev; args; _ } ->
      let xs = List.map (expr fs env) args in
      List.iter (consume env) xs;
      let ev = borrow fs env ev in
      let b =
        borrowed fs ("$" ^ op) Block
          (Op_block (ev, dep_id cx dep, op_index fs e.loc dep op))
      in
      call_block fs env ~result:(lay e.ty) ~fails:(C.fails fty) b ev xs
  | With { dep; impl = { kind = Global_value (real, _); _ }; _ }
    when real = Path.member dep "real" && dep <> Path.prelude "Console" ->
      unsupported_at fs e.loc (sprintf "the real `%s`" (Path.local dep))
  | With { ev; outer; dep; body; _ } when List.mem (ev.id, dep) fs.known ->
      (* a handler a release build knows: its state is in this frame,
         made before the `with`, and each call of one of its operations
         is a direct call already, so it installs nothing *)
      expr fs (bind env ev (borrow_var fs env outer)) body
  | With { ev; outer; dep; impl; desc = d; body } ->
      install fs env e ~ev ~outer ~deps:[ dep ] ~handler:impl ~body_desc:d body
  | With_handler { ev; outer; handler; deps; desc = d; body } ->
      install fs env e ~ev ~outer ~deps ~handler ~body_desc:d body
  (* which of a handler's dependencies are installed is the `with`'s *)
  | Narrowed (_, h) -> expr fs env h
  | Handler { ev; captures; body } -> handler fs env e ~ev ~captures body
  | Instance { impls; finally } -> instance fs env e impls finally
  | Lambda { name; params; ev; outer; given; captures; body } ->
      lambda fs env ~name ~params ~ev ~outer ~given ~captures body
  | Global (p, _, _, _) ->
      unsupported_at fs e.loc
        (sprintf "`%s` used as a value, not called" (Path.local p))
  | Global_value (p, _) -> global_value fs env e p
  | Intrinsic (x, _, _, _) ->
      unsupported_at fs e.loc
        (sprintf "`%s` used as a value, not called" (Intrinsic.name x))
  | Prim (p, args) -> prim fs env e p args
  | Con (_, c, args) when is_struct (lay e.ty) ->
      (* a small value: its tag and its fields in their slots, a scalar in
         each slot it has no field in *)
      let l = lay e.ty in
      let st = match l with Struct (n, _) -> struct_of cx n | _ -> bug "a struct" in
      let sh = ctor_shape cx (at fs e.loc) e.ty c in
      let xs = List.map (expr fs env) args in
      let slots = Array.of_list (List.map (dummy fs env) st.sfields) in
      (match st.skind with
      | Tagged -> slots.(0) <- Int (Int64.of_int sh.tag)
      | Nullable (none, _) when sh.tag = none -> slots.(0) <- Scalar_ctor (-1)
      | _ -> ());
      List.iter2
        (fun ((place : place), _) x ->
          match place with
          | Slot k -> slots.(k) <- x
          | Bits _ -> bug "a struct's field packed")
        sh.places xs;
      List.iter (consume env) xs;
      owned fs env "$struct" l (Make_struct (Array.to_list slots))
  | Con (_, c, args) -> (
      let sh = ctor_shape cx (at fs e.loc) e.ty c in
      match args with
      | [] -> (
          match lay e.ty with
          | Enum -> Enum_tag sh.tag
          | _ -> Scalar_ctor sh.tag)
      | _ -> alloc fs env sh (List.map (expr fs env) args))
  | Record (_, fields) when is_struct (lay e.ty) ->
      let decl_fields = record_fields cx (at fs e.loc) e.ty in
      let values = List.map (fun (f, x) -> (f, expr fs env x)) fields in
      let xs = List.map (fun (f, _) -> List.assoc f values) decl_fields in
      List.iter (consume env) xs;
      owned fs env "$struct" (lay e.ty) (Make_struct xs)
  | Tuple xs when is_struct (lay e.ty) ->
      let xs = List.map (expr fs env) xs in
      List.iter (consume env) xs;
      owned fs env "$struct" (lay e.ty) (Make_struct xs)
  | Record (_, fields) ->
      let decl_fields = record_fields cx (at fs e.loc) e.ty in
      let values = List.map (fun (f, x) -> (f, expr fs env x)) fields in
      alloc fs env
        (record_shape cx (at fs e.loc) e.ty)
        (List.map (fun (f, _) -> List.assoc f values) decl_fields)
  | Field (r, _, f) ->
      let x = expr fs env r in
      let fields = record_fields cx (at fs e.loc) r.ty in
      let sh = record_shape cx (at fs e.loc) r.ty in
      let t =
        field_var fs f x
          (List.assoc f (List.combine (List.map fst fields) sh.places))
          sh.words
      in
      dup fs (Var t);
      drop fs env x;
      own env t;
      Var t
  | Update (r, f, v) ->
      let x = expr fs env r in
      let y = expr fs env v in
      let fields = record_fields cx (at fs e.loc) r.ty in
      let sh = record_shape cx (at fs e.loc) r.ty in
      let parts =
        List.map2
          (fun (name, _) place ->
            if name = f then y
            else
              let t = Var (field_var fs name x place sh.words) in
              dup fs t;
              t)
          fields sh.places
      in
      let r =
        match atom_layout x with
        | Struct _ as l -> owned fs env "$struct" l (Make_struct parts)
        | _ -> alloc_taking fs env sh parts
      in
      consume env y;
      drop fs env x;
      r
  | Array xs ->
      let l = element cx (lay (C.elem_ty e.ty)) in
      let xs = List.map (expr fs env) xs in
      List.iter (consume env) xs;
      let desc = match l with Word n -> Some (word_desc fs n) | _ -> None in
      owned fs env "$array" Boxed (Alloc_array { elem = l; elems = xs; desc })
  | Tuple xs ->
      alloc fs env
        (tuple_shape cx (at fs e.loc) e.ty)
        (List.map (expr fs env) xs)
  | Tag (t, [], _) -> Scalar_ctor (tag_id cx t)
  | Tag (t, args, ds) ->
      (* an error keeps its payload's descriptors after it, to be shown and
         compared by *)
      let xs = List.map (expr fs env) args in
      let ds = List.map (desc fs env) ds in
      alloc fs env
        (shape (tag_id cx t) (List.map atom_layout (xs @ ds)))
        (xs @ ds)
  | Fail x ->
      let err = expr fs env x in
      consume env err;
      raise_error fs env err;
      dummy fs env (lay e.ty)
  | Handle { body; value; on_value; error; on_error } ->
      let r = fresh fs "$handled" (lay e.ty) in
      emit fs (Decl r);
      let l = label fs in
      let err = fresh fs error.name Boxed in
      let inner =
        {
          env with
          frames = { kind = Catch_frame (l, None); live = [] } :: env.frames;
        }
      in
      let body =
        block fs (fun () ->
            let x = expr fs inner body in
            let m = fresh fs value.name (lay value.ty) in
            emit fs (Let (m, Atom x));
            consume inner x;
            own env m;
            let y = expr fs (bind env value m) on_value in
            consume env y;
            emit fs (Set (r, y));
            drop fs env (Var m))
      in
      let handler =
        block fs (fun () ->
            branch env (fun () ->
                own env err;
                let y = expr fs (bind env error err) on_error in
                consume env y;
                emit fs (Set (r, y));
                drop fs env (Var err)))
      in
      emit fs (Catch { label = l; body; error = err; handler });
      own env r;
      Var r
  | Finally (body, after) ->
      let r = fresh fs "$finally" (lay e.ty) in
      emit fs (Decl r);
      let l = label fs in
      let err = fresh fs "$error" Boxed in
      let inner =
        {
          env with
          frames =
            { kind = Catch_frame (l, Some after); live = [] } :: env.frames;
        }
      in
      let body =
        block fs (fun () ->
            let x = expr fs inner body in
            consume inner x;
            emit fs (Set (r, x)))
      in
      let handler =
        block fs (fun () ->
            branch env (fun () ->
                drop fs env (expr fs env after);
                raise_error fs env (Var err)))
      in
      emit fs (Catch { label = l; body; error = err; handler });
      drop fs env (expr fs env after);
      own env r;
      Var r
  | Match (s, arms) -> match_ fs env e s arms
  | Assert x ->
      if x.loc.file = Prelude.file then
        unsupported_at fs e.loc "a call of the prelude that `assert`s";
      let c = expr fs env x in
      emit fs (Assert (c, new_site cx ~kind:Asserts x.loc));
      Unit
  | Assert_equal _ -> unsupported_at fs e.loc "`assert a == b`"

(* Leave the innermost loop: drop what every scope up to it holds, and
   run the [after] of each `Finally` on the way. *)
and break_out fs env =
  let rec go = function
    | [] -> bug "a `break` outside a loop"
    | fr :: rest -> (
        drop_all fs fr;
        match fr.kind with
        | Loop_frame l -> emit fs (Break l)
        | Catch_frame (_, Some after) ->
            let outer = { env with frames = rest } in
            drop fs outer (expr fs outer after);
            go rest
        | Catch_frame (_, None) | Scope -> go rest
        | Fn_frame -> bug "a `break` outside a loop")
  in
  go env.frames

(* A new object of shape [sh], which takes [fields], given in the order
   they're declared. *)
and alloc fs env sh fields =
  let r = alloc_taking fs env sh fields in
  List.iter (consume env) fields;
  r

and alloc_taking fs env (sh : shape) fields =
  (* an object's header has a bit for each field that holds an object,
     64 at most (ren_rt.h, [ren_ctor_objs]) *)
  if sh.words > 64 then
    unsupported fs.here
      "a record, a tuple, a constructor or an error of more than 64 fields";
  (* each word: a field, or the small scalars packed in it *)
  let words = Array.make sh.words [] in
  List.iter2
    (fun ((place : place), _) x ->
      match place with
      | Slot n -> words.(n) <- [ (x, -1, 0) ]
      | Bits (n, at, bits) -> words.(n) <- words.(n) @ [ (x, at, bits) ])
    sh.places fields;
  let fields =
    Array.to_list
      (Array.map
         (function
           | [ (x, -1, _) ] -> x
           | packed ->
               borrowed fs "$packed" Int
                 (Pack
                    (List.sort (fun (_, a, _) (_, b, _) -> compare a b) packed)))
         words)
  in
  let words =
    List.filter_map
      (fun x ->
        match atom_layout x with Word n -> Some (word_desc fs n) | _ -> None)
      fields
  in
  owned fs env "$new" Boxed (Alloc { tag = sh.tag; fields; words; at = None })

and prim fs env (e : C.expr) (p : C.prim) (args : C.expr list) =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  let site ?wrap () = new_site cx ?wrap (at fs e.loc) in
  match (p, args) with
  | Neg, [ a ] ->
      let x = expr fs env a in
      let wrap =
        if a.ty = Ty.int then
          Some { meth = "wrapping_neg"; recv = a.loc; arg = None }
        else None
      in
      owned fs env "$neg" (lay e.ty) (Neg (x, site ?wrap ()))
  | Not, [ a ] ->
      let x = expr fs env a in
      owned fs env "$not" Bool (Not x)
  | Binop op, [ a; b ] -> (
      let x = expr fs env a in
      let y = expr fs env b in
      match cmp_of op with
      | Some c -> owned fs env "$cmp" Bool (Compare (c, x, y))
      | None ->
          let wrap =
            match wrapping_meth op with
            | Some meth when a.ty = Ty.int ->
                Some { meth; recv = a.loc; arg = Some b.loc }
            | _ -> None
          in
          owned fs env "$arith" (lay e.ty) (Arith (op, x, y, site ?wrap ())))
  | (Equal _ | Not_equal _), [ a; b ] -> (
      let c = match p with Equal _ -> Eq | _ -> Ne in
      let x = expr fs env a in
      let y = expr fs env b in
      match lay a.ty with
      | Int | Float | Bool | Unit | Enum ->
          owned fs env "$eq" Bool (Compare (c, x, y))
      | Boxed when a.ty = Ty.str ->
          let same =
            owned fs env "$eq" Bool (Runtime (Str_eq, [ x; y ], None))
          in
          drop fs env x;
          drop fs env y;
          if c = Eq then same else owned fs env "$ne" Bool (Not same)
      | _ ->
          (* through the walk, by the descriptor of what's compared *)
          let d = match p with Equal d | Not_equal d -> d | _ -> bug "==" in
          let d = dict fs env d in
          let same =
            owned fs env "$eq" Bool
              (Runtime (Equal_any, [ d; as_word fs x; as_word fs y ], None))
          in
          List.iter (drop fs env) [ x; y; d ];
          if c = Eq then same else owned fs env "$ne" Bool (Not same))
  | Length, [ a ] ->
      let x = expr fs env a in
      let n = owned fs env "$len" Int (Runtime (Array_len, [ x ], None)) in
      drop fs env x;
      n
  | Get_index, [ a; i ] ->
      let x = expr fs env a in
      let i = expr fs env i in
      let l = element cx (lay e.ty) in
      let v =
        owned fs env "$elem" l (Runtime (Array_get l, [ x; i ], Some (site ())))
      in
      drop fs env x;
      v
  (* `a[i].f = w`, which Core writes `a = set a i (update (get a i) f w)`,
     of an array of structs: only the field is written, in place once
     Perceus takes the array, rather than the element built again and
     copied in. [i]'s check runs where `get`'s would, before [w]; [w]
     changes nothing, so [a] is read again after it as before it. *)
  | ( Set_index,
      [
        ({ kind = Local av; _ } as a);
        ({ kind = Local iv; _ } as i);
        {
          kind =
            Update
              ( ({
                   kind =
                     Prim
                       ( Get_index,
                         [ { kind = Local av'; _ }; { kind = Local iv'; _ } ] );
                   _;
                 } as get),
                f,
                w );
          ty;
          _;
        };
      ] )
    when av.id = av'.id && iv.id = iv'.id && is_struct (lay ty) && pure w ->
      let n = match lay ty with Struct (n, _) -> n | _ -> bug "a struct" in
      let fields = record_fields cx (at fs e.loc) ty in
      let sh = record_shape cx (at fs e.loc) ty in
      let k, l =
        match List.assoc f (List.combine (List.map fst fields) sh.places) with
        | Slot k, l -> (k, l)
        | Bits _, _ -> bug "a struct's field packed"
      in
      let at_get = new_site cx (at fs get.loc) in
      let x = expr fs env a in
      emit fs (Do (Runtime (Array_check, [ x; expr fs env i ], Some at_get)));
      drop fs env x;
      let y = expr fs env w in
      let x = expr fs env a in
      let r =
        owned fs env "$set" Boxed
          (Runtime
             (Array_set_field (n, k, l), [ x; expr fs env i; y ], Some at_get))
      in
      drop fs env x;
      drop fs env y;
      r
  | Set_index, [ a; i; v ] ->
      let x = expr fs env a in
      let i = expr fs env i in
      let y = expr fs env v in
      let l = element cx (lay v.ty) in
      let r =
        owned fs env "$set" Boxed
          (Runtime (Array_set l, [ x; i; y ], Some (site ())))
      in
      drop fs env x;
      drop fs env y;
      r
  | Compare (op, d), [ a; b ] ->
      let x = expr fs env a in
      let y = expr fs env b in
      let d = dict fs env d in
      let order =
        owned fs env "$order" Int
          (Runtime (Compare_any, [ d; as_word fs x; as_word fs y ], None))
      in
      List.iter (drop fs env) [ x; y; d ];
      let c = match cmp_of op with Some c -> c | None -> bug "an order" in
      owned fs env "$cmp" Bool (Compare (c, order, Int 0L))
  | Op (req, d), args ->
      let xs = List.map (expr fs env) args in
      let d = dict fs env d in
      let r =
        from_word fs env "$op"
          (Runtime
             ( Op_any (op_of_req req),
               d :: List.map (as_word fs) xs,
               Some (site ()) ))
          (lay e.ty)
      in
      List.iter (drop fs env) (xs @ [ d ]);
      r
  | Value_of (req, d), [] ->
      let d = dict fs env d in
      let r =
        from_word fs env "$value"
          (Runtime (Value_any (req = "one"), [ d ], None))
          (lay e.ty)
      in
      drop fs env d;
      r
  | (Entries | Members), _ -> unsupported_at fs e.loc "a `Map` or a `Set`"
  | New_cell, [ x ] ->
      (* a handler's `var`: a local of its code, whose address its
         operations share *)
      let v = expr fs env x in
      let store = fresh fs "$state" (atom_layout v) in
      emit fs (Let (store, Atom v));
      consume env v;
      own env store;
      borrowed fs "$cell" (Cell store.layout) (Addr store)
  | Get_cell, [ { kind = Local c; _ } ] -> read fs env c
  | Set_cell, [ { kind = Local c; _ }; x ] -> (
      let v = expr fs env x in
      consume env v;
      match mem_var env c with
      | { layout = Cell l; _ } as m ->
          if counted l then drop_now fs (borrowed fs c.name l (Load m));
          emit fs (Store (m, v));
          Unit
      | _ -> bug "a cell that isn't one")
  | _ -> bug ("`" ^ C.show_prim p ^ "` on the wrong number of operands")

and call fs env (e : C.expr) (f : C.expr) args ev =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  match f.kind with
  | Global (p, _, descs, dicts) ->
      let callee =
        match Hashtbl.find_opt cx.fns p with
        | Some d -> d
        | None -> bug ("a call of `" ^ Path.local p ^ "`, which isn't there")
      in
      cx.todo <- (p, at fs e.loc) :: cx.todo;
      (* what the callee takes, in its own type variables, each a word *)
      let takes, gives =
        with_words cx (List.length callee.tys) (fun () ->
            let l t = layout cx (at fs e.loc) t in
            match callee.scheme.ty with
            | Fun (ps, r, _, _) ->
                ( List.map
                    (fun (q : Ty.param) ->
                      match (q.mode, l q.ty) with
                      | Inout, Word _ ->
                          unsupported_at fs e.loc
                            "an `inout` parameter of a type variable's type"
                      | Inout, lq -> Cell lq
                      | Read, lq -> lq)
                    ps,
                  l r )
            | _ -> bug "a function without a function type")
      in
      let hidden =
        List.map (desc fs env) descs @ List.map (dict fs env) dicts
      in
      let xs =
        List.map
          (function
            (* a cell, a known handler's state, passed as its address *)
            | C.Value { kind = Local v; _ } when is_cell v.ty ->
                Var (mem_var env v)
            | C.Value a -> expr fs env a
            | Ref v -> (
                let m = mem_var env v in
                match m.layout with
                | Cell _ -> Var m
                | l -> borrowed fs ("&" ^ v.name) (Cell l) (Addr m)))
          args
      in
      List.iter (consume env) (hidden @ xs);
      let xs = List.map2 (convert fs) xs takes in
      let args = hidden @ [ borrow fs env ev ] @ xs in
      let name = c_name cx p in
      let r =
        if fn_fails callee then (
          let result = fresh fs "$result" gives in
          let error = fresh fs "$error" Boxed in
          let on_error = block fs (fun () -> raise_error fs env (Var error)) in
          emit fs (Call_fails { result; fn = name; args; error; on_error });
          own env result;
          Var result)
        else owned fs env "$result" gives (Call (name, args))
      in
      take_word fs env r (lay e.ty)
  | Intrinsic (x, a, descs, _) -> intrinsic fs env e x a.tys descs args
  | _ ->
      (* a block: a parameter, a local bound to one, or one written here *)
      let b = expr fs env f in
      let xs =
        List.map
          (function
            | C.Value a -> expr fs env a
            | Ref _ -> unsupported_at fs e.loc "a block's `inout` parameter")
          args
      in
      List.iter (consume env) xs;
      call_block fs env ~result:(lay e.ty) ~fails:(C.fails f.ty) b
        (borrow fs env ev) xs

(* [r], an owned value of what a callee gives, as an owned value of [l]:
   taken out of a word if it's one and [l] isn't, and a word of the
   callee's type variable made one of the caller's. *)
and take_word fs env (r : atom) (l : layout) : atom =
  (match atom_layout r with Word _ -> word_only fs.cx l | _ -> ());
  match (atom_layout r, l) with
  | Word i, Word j when i = j -> r
  | Word _, Word _ ->
      consume env r;
      owned fs env "$word" l (Atom r)
  | Word _, _ ->
      consume env r;
      owned fs env "$unword" l (Of_word (r, l))
  | _ -> r

(* Call the block [b] with the caller's evidence [ev] and the arguments
   [xs], which it takes; its value is of layout [result]. If its type
   says it can fail, its error is raised here. *)
and call_block fs env ~result ~fails b ev xs =
  List.iter (fun x -> word_only fs.cx (atom_layout x)) xs;
  word_only fs.cx result;
  let r = fresh fs "$result" result in
  let error = fresh fs "$error" Boxed in
  let on_error =
    if fails then Some (block fs (fun () -> raise_error fs env (Var error)))
    else None
  in
  emit fs (Call_block { result = r; block = b; ev; args = xs; error; on_error });
  own env r;
  Var r

(* `show` of [x], a value of type [t] that [d] describes, taken: a [Str]
   it owns. A scalar's is the runtime's own, and anything else's walks
   the descriptor. *)
and show fs env loc t (d : C.desc) x =
  match layout_at fs loc t with
  | Boxed when t = Ty.str -> x
  | l ->
      let rt =
        match l with
        | Int -> Some Show_int
        | Float -> Some Show_float
        | Bool -> Some Show_bool
        | _ -> None
      in
      let s =
        match rt with
        | Some rt -> owned fs env "$shown" Boxed (Runtime (rt, [ x ], None))
        | None ->
            let d = desc fs env d in
            let s =
              owned fs env "$shown" Boxed
                (Runtime (Show_any, [ d; as_word fs x ], None))
            in
            drop fs env d;
            s
      in
      drop fs env x;
      s

and intrinsic fs env (e : C.expr) (x : Intrinsic.t) tys descs args =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  let site () = new_site cx (at fs e.loc) in
  let values () =
    List.map
      (function
        | C.Value a -> expr fs env a
        | Ref _ -> bug "an intrinsic taking `&` that isn't `push`")
      args
  in
  (* the runtime's [rt] of the arguments, which it only reads *)
  let runtime ?site rt =
    let xs = values () in
    let r =
      owned fs env
        ("$" ^ Intrinsic.member_name x)
        (lay e.ty)
        (Runtime (rt, xs, site))
    in
    List.iter (drop fs env) xs;
    r
  in
  match (x, tys, descs) with
  | Show, [ t ], [ d ] -> (
      match values () with
      | [ v ] -> show fs env e.loc t d v
      | _ -> bug "a `show` of no value")
  | Array_len, _, _ -> runtime Array_len
  | Array_push, [ t ], _ -> (
      match args with
      | [ Ref xs; Value v ] ->
          let m = mem_var env xs in
          let cell =
            match m.layout with
            | Cell _ -> Var m
            | l -> borrowed fs ("&" ^ xs.name) (Cell l) (Addr m)
          in
          let y = expr fs env v in
          emit fs
            (Do (Runtime (Array_push (element cx (lay t)), [ cell; y ], None)));
          drop fs env y;
          Unit
      | _ -> bug "a `push` without `&`")
  | Str_len, _, _ -> runtime Str_len
  | Str_concat, _, _ -> runtime Str_concat
  | Float_of, _, _ -> runtime Float_of_int
  | Float_sqrt, _, _ -> runtime ~site:(site ()) Float_sqrt
  | Float_round, _, _ -> runtime ~site:(site ()) Float_round
  | Float_truncate, _, _ -> runtime ~site:(site ()) Float_truncate
  | Int_wrapping_add, _, _ -> runtime (Wrapping Add)
  | Int_wrapping_sub, _, _ -> runtime (Wrapping Sub)
  | Int_wrapping_mul, _, _ -> runtime (Wrapping Mul)
  | Int_wrapping_neg, _, _ -> runtime Wrapping_neg
  (* `map`'s own (prelude.ml) *)
  | Array_reserve, [ t ], [ d ] -> (
      match values () with
      | [ n ] ->
          let l = element cx (lay t) in
          let d = match l with Word _ -> [ desc fs env d ] | _ -> [] in
          let r =
            owned fs env "$reserved" Boxed
              (Runtime (Array_reserve l, n :: d, None))
          in
          List.iter (drop fs env) d;
          r
      | _ -> bug "an `array_reserve` of no length")
  | Map_into, [ t; u ], _ -> (
      let into tag =
        Enum_tag (ctor_shape cx (at fs e.loc) e.ty tag).tag
      in
      match values () with
      | [ xs ] when same_elements (lay t) (lay u) ->
          let unique = borrowed fs "$unique" Bool (Is_unique xs) in
          drop fs env xs;
          let r = fresh fs "$into" Enum in
          emit fs (Decl r);
          emit fs
            (If
               ( unique,
                 [ Set (r, into "InPlace") ],
                 [ Set (r, into "Fresh") ] ));
          Var r
      | [ xs ] ->
          drop fs env xs;
          into "Fresh"
      | _ -> bug "a `map_into` of no array")
  | Unsafe_cast, [ a; b ], _ -> (
      match (values (), lay a, lay b) with
      | [ x ], la, lb when la = lb -> x
      | [ x ], la, Int when scalar_element la ->
          (* the word, read as an [Int]: its bits, not a conversion *)
          from_word fs env "$cast" (To_word x) Int
      | [ x ], _, lb ->
          (* never run: [map_into] says `Fresh` for these layouts, and
             this is `map`'s other arm *)
          drop fs env x;
          emit fs
            (Panic
               ( new_site cx (at fs e.loc),
                 "an element cast to a type it isn't kept as" ));
          dummy fs env lb
      | _ -> bug "an `unsafe_cast` of no value")
  (* the real `Console`'s operations *)
  | Console_write, _, _ -> runtime Console_write
  | Console_error, _, _ -> runtime Console_error
  | _ -> unsupported_at fs e.loc (sprintf "`%s`" (Intrinsic.name x))

(* A block's code: a function with a block's signature, lifted out of
   the one being compiled, whose environment holds the cells of
   [captures], then of the descriptors of this function's words. [enter]
   binds what its body sees of its evidence and arguments, given its
   code, where it's compiled, the caller's evidence and the arguments.
   What it gives is the block, made here, its environment on this
   function's stack. *)
and lift fs env ~name ~(captures : C.var list) ~enter (body : C.expr) : atom =
  let cx = fs.cx in
  (* each capture's cell: a local's address, or the cell it already is *)
  let cell (m : var) =
    match m.layout with
    | Cell _ -> Var m
    | l -> borrowed fs ("&" ^ m.name) (Cell l) (Addr m)
  in
  let caps = List.map (fun (v : C.var) -> (v, mem_var env v)) captures in
  (* the descriptors of this function's type variables; a handler's code
     has the one of its `with`'s body too, which nothing it lifts uses *)
  let words = List.filter (fun (n, _) -> n >= 0) fs.words in
  let cells =
    List.map (fun (_, m) -> cell m) caps @ List.map (fun (_, d) -> cell d) words
  in
  let code =
    {
      cx;
      fname = fs.fname;
      out = [];
      next_id = 0;
      next_label = 0;
      here = fs.here;
      fails = true;
      words = [];
      handler = None;
      known = fs.known;
    }
  in
  let env_p = fresh code "$env" Ptr in
  let caller = fresh code "$caller" Ev in
  let args = fresh code "$args" Ptr in
  let frame = { kind = Fn_frame; live = [] } in
  let n = List.length caps in
  let body_block =
    block code (fun () ->
        let cenv = { vars = Vars.empty; frames = [ frame ] } in
        let cenv =
          List.fold_left
            (fun cenv (i, ((v : C.var), (m : var))) ->
              let l = match m.layout with Cell _ -> m.layout | l -> Cell l in
              bind cenv v (let_var code v.name l (Env_get (Var env_p, i))))
            cenv
            (List.mapi (fun i c -> (i, c)) caps)
        in
        code.words <-
          List.mapi
            (fun i (k, (d : var)) ->
              let c =
                let_var code d.name (Cell Desc) (Env_get (Var env_p, n + i))
              in
              (k, let_var code d.name Desc (Load c)))
            words;
        let cenv = enter code cenv (Var caller) (Var args) in
        let r = expr code cenv body in
        consume cenv r;
        let w =
          match atom_layout r with
          | Word _ -> r
          | l ->
              word_only cx l;
              borrowed code "$word" (Word 0) (To_word r)
        in
        drop_all code frame;
        emit code (Return w))
  in
  let name = fresh_name cx name in
  cx.lifted <-
    {
      name;
      params = [ env_p; caller; args ];
      modes = [ Owned; Owned; Owned ];
      inout = [];
      stack = [];
      slot = None;
      words = code.words;
      result = Word 0;
      fails = true;
      body = body_block;
      loc = body.loc;
    }
    :: cx.lifted;
  let envv = borrowed fs "$env" Ptr (Env_new cells) in
  borrowed fs "$block" Block (Block_of (name, envv))

(* A block written here: its code, lifted, which runs with the evidence
   where it's written and, on top, what its parameter's type lists from
   its caller's. A handler's `finally` takes the descriptor of what the
   `with`'s body gives first, the type variable after its function's
   own. *)
and lambda fs env ~name ~(params : C.param list) ~ev ~outer ~given ~captures
    body =
  let cx = fs.cx in
  let typed =
    match params with p :: _ -> p.var.ty = C.type_ty | [] -> false
  in
  let n = cx.nwords in
  let enter code cenv caller args =
    let outer_ev = borrow code cenv outer in
    let ev_var =
      match given with
      | [] -> ( match outer_ev with Var v -> v | _ -> bug "evidence")
      | deps ->
          let_var code "ev" Ev
            (Given
               { outer = outer_ev; caller; deps = List.map (dep_id cx) deps })
    in
    let cenv = bind cenv ev ev_var in
    fst
      (List.fold_left
         (fun (cenv, i) (p : C.param) ->
           if p.mode = Inout then
             unsupported_at code body.loc "a block's `inout` parameter";
           let l = layout_at code body.loc p.var.ty in
           if not (match l with Block | Cell _ -> false | _ -> true) then
             unsupported_at code body.loc "a block passed to a block";
           word_only cx l;
           let x = let_var code p.var.name l (Arg (args, i)) in
           own cenv x;
           if typed && i = 0 then code.words <- (n, x) :: code.words;
           (bind cenv p.var x, i + 1))
         (cenv, 0) params)
  in
  let go () = lift fs env ~name ~captures ~enter body in
  if typed then with_words cx (n + 1) go else go ()

(* A `with`: the code of [handler]'s description, called with the
   evidence here, the body lifted as a block that captures what it uses
   from here, and the dependencies to install it for. *)
and install fs env (e : C.expr) ~ev ~outer ~deps ~handler ~body_desc body =
  let cx = fs.cx in
  let h = expr fs env handler in
  let seen = Hashtbl.create 16 in
  let captures =
    List.filter
      (fun (v : C.var) ->
        v.id <> ev.C.id && Vars.mem v.id env.vars
        && (not (Hashtbl.mem seen v.id))
        &&
        (Hashtbl.replace seen v.id ();
         true))
      (List.rev (refs body []))
  in
  let b =
    lift fs env ~name:(fs.fname ^ ".with") ~captures
      ~enter:(fun _ cenv caller _ ->
        match caller with Var c -> bind cenv ev c | _ -> bug "evidence")
      body
  in
  let d = desc fs env body_desc in
  let outer = borrow fs env outer in
  let result = fresh fs "$with" (layout_at fs e.loc e.ty) in
  word_only cx result.layout;
  let error = fresh fs "$error" Boxed in
  let on_error =
    if can_raise fs env then
      Some (block fs (fun () -> raise_error fs env (Var error)))
    else None
  in
  emit fs
    (Call_handler
       {
         result;
         handler = h;
         outer;
         body = b;
         desc = d;
         deps = List.map (dep_id cx) deps;
         error;
         on_error;
       });
  drop fs env d;
  drop fs env h;
  own env result;
  Var result

(* A handler's description: an object holding its code, lifted, and
   what it captures, copied. *)
and handler fs env (e : C.expr) ~ev ~captures body =
  let cx = fs.cx in
  let values = List.map (read fs env) captures in
  let code =
    {
      cx;
      fname = fs.fname;
      out = [];
      next_id = 0;
      next_label = 0;
      here = fs.here;
      fails = true;
      words = [];
      handler = None;
      known = fs.known;
    }
  in
  let self = fresh code "$self" Boxed in
  let outer = fresh code "$outer" Ev in
  let body_p = fresh code "$body" Block in
  let body_desc = fresh code "$body_desc" Desc in
  let deps = fresh code "$deps" Ptr in
  let ndeps = fresh code "$ndeps" Int in
  code.handler <- Some { outer; body = body_p; body_desc; deps; ndeps };
  (* the `with`'s body gives a word described by [body_desc] *)
  code.words <- [ (-1, body_desc) ];
  let frame = { kind = Fn_frame; live = [] } in
  let body_block =
    block code (fun () ->
        let cenv = { vars = Vars.empty; frames = [ frame ] } in
        let cenv =
          List.fold_left
            (fun cenv (i, ((v : C.var), x)) ->
              bind cenv v
                (let_var code v.name (atom_layout x)
                   (Field (Var self, i + 1, List.length captures + 1))))
            cenv
            (List.mapi (fun i c -> (i, c)) (List.combine captures values))
        in
        let cenv = bind cenv ev outer in
        let r = expr code cenv body in
        consume cenv r;
        drop_all code frame;
        emit code (Return r))
  in
  let name = fresh_name cx (fs.fname ^ ".handler") in
  cx.lifted <-
    {
      name;
      params = [ self; outer; body_p; body_desc; deps; ndeps ];
      (* the `with` that calls it keeps its description and the body's
         descriptor *)
      modes = [ Borrowed; Owned; Owned; Borrowed; Owned; Owned ];
      inout = [];
      stack = [];
      slot = None;
      words = code.words;
      result = Word 0;
      fails = true;
      body = body_block;
      loc = e.loc;
    }
    :: cx.lifted;
  alloc fs env
    (shape 0 (Ptr :: List.map atom_layout values))
    (Fn_ptr name :: values)

(* A handler's instance, at the end of its code: each implementation a
   record of its operations' blocks, installed on the evidence the
   handler was given for the `with`'s dependencies, then the `with`'s
   body run with that, and its `finally` given the outcome. *)
and instance fs env (e : C.expr) impls finally =
  let cx = fs.cx in
  let h =
    match fs.handler with
    | Some h -> h
    | None -> unsupported_at fs e.loc "an instance outside a handler"
  in
  let impls =
    List.map
      (fun (dep, (r : C.expr)) ->
        let ops =
          match r.kind with
          | Record (_, fields) ->
              List.map snd
                (List.sort
                   (fun (i, _) (j, _) -> compare i j)
                   (List.map
                      (fun (op, x) -> (op_index fs r.loc dep op, expr fs env x))
                      fields))
          | _ -> bug "an implementation that isn't a record of its operations"
        in
        borrowed fs ("$" ^ dep.Path.name) Ptr (Impl (dep_id cx dep, ops)))
      impls
  in
  let fin = Option.map (expr fs env) finally in
  let ev =
    borrowed fs "$installed" Ev
      (Install
         { outer = Var h.outer; impls; deps = Var h.deps; ndeps = Var h.ndeps })
  in
  let run_body env =
    call_block fs env ~result:(Word (-1)) ~fails:true (Var h.body) ev []
  in
  match fin with
  | None -> run_body env
  | Some f ->
      (* the outcome, `Ok` of the body's value or `Err` of its error *)
      let outcome = fresh fs "$outcome" Boxed in
      emit fs (Decl outcome);
      let l = label fs in
      let err = fresh fs "$error" Boxed in
      let inner =
        {
          env with
          frames = { kind = Catch_frame (l, None); live = [] } :: env.frames;
        }
      in
      let body =
        block fs (fun () ->
            let v = run_body inner in
            let ok =
              alloc fs inner (shape (result_tag cx "Ok") [ Word (-1) ]) [ v ]
            in
            consume inner ok;
            emit fs (Set (outcome, ok)))
      in
      let handler =
        block fs (fun () ->
            branch env (fun () ->
                own env err;
                let bad =
                  alloc fs env
                    (shape (result_tag cx "Err") [ Boxed ])
                    [ Var err ]
                in
                consume env bad;
                emit fs (Set (outcome, bad))))
      in
      emit fs (Catch { label = l; body; error = err; handler });
      own env outcome;
      let d = Var h.body_desc in
      dup fs d;
      consume env (Var outcome);
      call_block fs env ~result:(Word (-1)) ~fails:true f (Var h.outer)
        [ d; Var outcome ]

(* An associated value, made once when the program starts: borrowed from
   where it's kept, and counted again. *)
and global_value fs env (e : C.expr) p =
  let cx = fs.cx in
  let f =
    match Hashtbl.find_opt cx.fns p with
    | Some f -> f
    | None -> bug ("the value `" ^ Path.local p ^ "`, which isn't there")
  in
  if f.tys <> [] || f.dicts <> [] then
    unsupported_at fs e.loc
      (sprintf "the associated value `%s` of a generic type" (Path.local p));
  let v =
    match Hashtbl.find_opt cx.values p with
    | Some v -> v
    | None ->
        cx.todo <- (p, at fs e.loc) :: cx.todo;
        let fn = c_name cx p in
        let v =
          {
            vname = fn ^ "_value";
            vfn = fn;
            vlayout = with_words cx 0 (fun () -> layout_at fs e.loc e.ty);
          }
        in
        Hashtbl.replace cx.values p v;
        v
  in
  let t = let_var fs ("$" ^ p.name) v.vlayout (Global v.vname) in
  dup fs (Var t);
  own env t;
  Var t

(* A `match`: each arm's body is a join point, its pattern's variables
   declared before the tests that set them. A subject of a sum type is
   switched on by its tag, each case trying in order only the arms that
   can match that constructor; anything else tries every arm in order. A
   subject written as a tuple, `match (a, b)`, isn't made: each arm's
   parts are matched against its parts. *)
and match_ fs env (e : C.expr) (s : C.expr) (arms : C.arm list) =
  let cx = fs.cx in
  let r = fresh fs "$match" (layout_at fs e.loc e.ty) in
  emit fs (Decl r);
  let parts =
    match s.kind with
    | Tuple es
      when List.for_all
             (fun (a : C.arm) ->
               match a.pat.pkind with PTuple _ | PWild -> true | _ -> false)
             arms ->
        Some es
    | _ -> None
  in
  let subjects =
    match parts with
    | Some es -> List.map (expr fs env) es
    | None -> [ expr fs env s ]
  in
  (* what each arm's pattern matches each subject against *)
  let columns (a : C.arm) =
    match (parts, a.pat.pkind) with
    | Some _, PTuple ps -> List.combine ps subjects
    | Some _, _ -> []
    | None, _ -> [ (a.pat, List.hd subjects) ]
  in
  let arms =
    List.map
      (fun (a : C.arm) ->
        let vars =
          List.map
            (fun (v : C.var) ->
              (v, fresh fs v.name (layout_at fs a.pat.ploc v.ty)))
            (pattern_vars a.pat)
        in
        (a, vars, label fs))
      arms
  in
  List.iter
    (fun (_, vars, _) -> List.iter (fun (_, m) -> emit fs (Decl m)) vars)
    arms;
  let arm_env vars = List.fold_left (fun env (v, m) -> bind env v m) env vars in
  let no_arm = new_site cx (at fs e.loc) in
  (* the arm [a] has matched: count what its pattern bound, check its
     guard, and go to its body *)
  let matched ((a : C.arm), vars, l) =
    List.iter (fun (_, (m : var)) -> dup fs (Var m)) vars;
    let go () =
      List.iter
        (fun x ->
          match x with Var v when counted v.layout -> drop_now fs x | _ -> ())
        subjects;
      emit fs (Jump l)
    in
    match a.guard with
    | None -> go ()
    | Some g ->
        let scope = { kind = Scope; live = [] } in
        let genv = { (arm_env vars) with frames = scope :: env.frames } in
        List.iter (fun (_, m) -> own genv m) vars;
        let c = expr fs genv g in
        let yes = block fs go in
        let no =
          block fs (fun () ->
              List.iter (fun (_, m) -> drop_now fs (Var m)) vars)
        in
        emit fs (If (c, yes, no))
  in
  (* the statements that test [pats] in order, each a pattern and the atom
     it's matched against, then do [k]; [known] is a subject whose tag a
     switch knows *)
  let rec test ~known vars pats k =
    match pats with
    | [] -> k ()
    | ((p : C.pattern), x) :: rest -> (
        let rest_then () = test ~known vars rest k in
        let check rhs =
          let c = borrowed fs "$test" Bool rhs in
          emit fs (If (c, block fs rest_then, []))
        in
        let fields (sh : shape) ps =
          List.filter_map
            (fun ((q : C.pattern), place) ->
              match q.pkind with
              | PWild -> None
              | _ -> Some (q, Var (field_var fs "$part" x place sh.words)))
            (List.combine ps sh.places)
        in
        let tagged sh ps =
          let inner () = test ~known vars (fields sh ps @ rest) k in
          if known = Some (x, sh.tag) then inner ()
          else
            let t = borrowed fs "$tag" Int (Tag_of x) in
            let c =
              borrowed fs "$is" Bool
                (Compare (Eq, t, Int (Int64.of_int sh.tag)))
            in
            emit fs (If (c, block fs inner, []))
        in
        match p.pkind with
        | PWild -> rest_then ()
        | PVar v ->
            emit fs (Set (List.assq v vars, x));
            rest_then ()
        | PInt n -> check (Compare (Eq, x, Int n))
        | PBool true -> emit fs (If (x, block fs rest_then, []))
        | PBool false -> emit fs (If (x, [], block fs rest_then))
        | PCon (_, c, ps) -> tagged (ctor_shape cx (at fs p.ploc) p.pty c) ps
        | PTag (t, ps) ->
            tagged
              (error_shape cx (at fs p.ploc) t
                 (List.map (fun (q : C.pattern) -> q.pty) ps))
              ps
        | PTuple ps ->
            let sh = tuple_shape cx (at fs p.ploc) p.pty in
            test ~known vars (fields sh ps @ rest) k
        | POr alts ->
            (* the first alternative that matches binds the variables, as
               the interpreter does: a guard that fails after it goes on
               to the next arm, not the next alternative *)
            let any = fresh fs "$or" Bool in
            emit fs (Decl any);
            emit fs (Set (any, Bool false));
            List.iter
              (fun alt ->
                emit fs
                  (If
                     ( Var any,
                       [],
                       block fs (fun () ->
                           test ~known vars
                             [ (alt, x) ]
                             (fun () -> emit fs (Set (any, Bool true)))) )))
              alts;
            emit fs (If (Var any, block fs rest_then, [])))
  in
  let try_arms ~known arms =
    List.iter
      (fun ((a, vars, _) as arm) ->
        test ~known vars (columns a) (fun () -> matched arm))
      arms;
    emit fs (Panic (no_arm, "no arm of this `match` matched"))
  in
  (* whether an arm's pattern can match the constructor [tag] *)
  let rec can_match tag (p : C.pattern) =
    match p.pkind with
    | PCon (_, c, _) -> (ctor_shape cx (at fs p.ploc) p.pty c).tag = tag
    | POr alts -> List.exists (can_match tag) alts
    | _ -> true
  in
  let dispatch =
    block fs (fun () ->
        match (parts, subjects, ctors cx s.ty) with
        | None, [ x ], Some cs
          when List.exists
                 (fun ((a : C.arm), _, _) ->
                   match a.pat.pkind with PCon _ -> true | _ -> false)
                 arms ->
            let t = borrowed fs "$tag" Int (Tag_of x) in
            let cases =
              List.mapi
                (fun tag _ ->
                  ( tag,
                    block fs (fun () ->
                        try_arms
                          ~known:(Some (x, tag))
                          (List.filter
                             (fun ((a : C.arm), _, _) -> can_match tag a.pat)
                             arms)) ))
                cs
            in
            emit fs
              (Switch
                 (t, cases, [ Panic (no_arm, "no arm of this `match` matched") ]))
        | _ -> try_arms ~known:None arms)
  in
  (* the subjects were dropped on the way to each arm *)
  List.iter (consume env) subjects;
  let joins =
    List.map
      (fun ((a : C.arm), vars, l) ->
        ( l,
          block fs (fun () ->
              branch env (fun () ->
                  List.iter (fun (_, m) -> own env m) vars;
                  let y = expr fs (arm_env vars) a.body in
                  consume env y;
                  emit fs (Set (r, y));
                  List.iter (fun (_, m) -> drop fs env (Var m)) vars)) ))
      arms
  in
  emit fs (Joins (dispatch, joins));
  own env r;
  Var r

(* The function [f], reached from the code at [here]: its hidden
   parameters first, a descriptor for each of its type variables and one
   for each of its requirements, then its evidence. *)
let fn cx here (f : C.fn_def) : Mem.fn =
  with_words cx (List.length f.tys) (fun () ->
      let fs =
        {
          cx;
          fname = Path.full f.path;
          out = [];
          next_id = 0;
          next_label = 0;
          here;
          fails = fn_fails f;
          words = [];
          handler = None;
          known = List.map (fun (k : C.known) -> (k.kev.id, k.kdep)) f.known;
        }
      in
      let lay t = layout_at fs f.loc t in
      let frame = { kind = Fn_frame; live = [] } in
      let env0 = { vars = Vars.empty; frames = [ frame ] } in
      let hidden env (v : C.var) layout =
        let m = fresh fs v.name layout in
        own env m;
        (bind env v m, m)
      in
      let env, tys =
        List.fold_left_map (fun env v -> hidden env v Desc) env0 f.tys
      in
      fs.words <- List.mapi (fun n m -> (n, m)) tys;
      let env, dicts =
        List.fold_left_map (fun env v -> hidden env v Desc) env f.dicts
      in
      let ev = fresh fs "ev" Ev in
      let env = bind env f.ev ev in
      let env, params =
        List.fold_left_map
          (fun env (p : C.param) ->
            let l = lay p.var.ty in
            let m =
              fresh fs p.var.name (if p.mode = Inout then Cell l else l)
            in
            if p.mode = Read && not (is_cell p.var.ty) then own env m;
            (bind env p.var m, m))
          env f.params
      in
      let result =
        match f.scheme.ty with
        | Fun (_, r, _, _) -> lay r
        | _ -> bug "a function without a function type"
      in
      let body =
        block fs (fun () ->
            let r = expr fs env f.body in
            consume env r;
            drop_all fs frame;
            emit fs (Return r))
      in
      {
        name = c_name cx f.path;
        params = tys @ dicts @ [ ev ] @ params;
        modes = List.map (fun _ -> Owned) (tys @ dicts @ [ ev ] @ params);
        inout =
          List.filter_map
            (fun ((p : C.param), m) -> if p.mode = Inout then Some m else None)
            (List.combine f.params params);
        stack = [];
        slot = None;
        words = fs.words;
        result;
        fails = fn_fails f;
        body;
        loc = f.loc;
      })

(* The program [modules], the prelude first and the entry last, with its
   `$start`, compiled from there: only what it reaches. *)
let compile ~release ~boxed (modules : C.program list) : Mem.program =
  let cx =
    {
      types = Hashtbl.create 64;
      fns = Hashtbl.create 256;
      own_members = Hashtbl.create 16;
      names = Hashtbl.create 64;
      taken = Hashtbl.create 64;
      todo = [];
      lifted = [];
      strings = Hashtbl.create 16;
      string_list = [];
      sites = [];
      nsites = 0;
      tags = Hashtbl.create 16;
      deps = Hashtbl.create 16;
      descs = Hashtbl.create 64;
      desc_list = [];
      decls = Hashtbl.create 16;
      decl_bodies = Hashtbl.create 16;
      values = Hashtbl.create 16;
      nwords = 0;
      release;
      boxed;
      structs = Hashtbl.create 8;
      struct_list = [];
      recursive = Hashtbl.create 16;
    }
  in
  List.iter
    (fun (m : C.program) ->
      List.iter
        (fun (d : Iface.type_decl) -> Hashtbl.replace cx.types d.path d)
        m.types;
      List.iter (fun (f : C.fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns;
      List.iter
        (fun (t, _) -> Hashtbl.replace cx.own_members t "a `show`")
        m.shows;
      List.iter
        (fun (t, _) -> Hashtbl.replace cx.own_members t "a `key`")
        m.keys;
      List.iter
        (fun ((t, _), _) -> Hashtbl.replace cx.own_members t "an operator")
        m.ops)
    modules;
  let entry =
    match List.rev modules with m :: _ -> m | [] -> bug "no modules"
  in
  let start_path = Path.make entry.home Lower.start_name in
  let start =
    match Hashtbl.find_opt cx.fns start_path with
    | Some f -> f
    | None -> bug "a program with no `$start`"
  in
  let ret =
    match start.scheme.ty with
    | Fun (_, r, _, _) -> r
    | _ -> bug "a `$start` without a function type"
  in
  let start_desc = static_desc cx start.loc ~template:false ret in
  let overflow = new_site cx start.loc in
  cx.todo <- [ (start_path, start.loc) ];
  let done_ = Hashtbl.create 64 in
  (* A function that finds a type to keep boxed ([Demote]) is left
     unfinished, and the others are still compiled, to find the rest of
     the program's such types in this one pass: compiling again for each
     was O(types × program), 826 times a 100,000-line program's lowering
     (compiler.md, "Native slice", step 9). What's compiled once one is
     found is thrown away, so state a function left unfinished can only
     make it stop early: anything else it raises then ends the pass. *)
  let demoted = ref [] in
  let rec go acc =
    match cx.todo with
    | [] -> List.rev acc
    | (p, here) :: rest ->
        cx.todo <- rest;
        if Hashtbl.mem done_ p then go acc
        else (
          Hashtbl.replace done_ p ();
          match fn cx here (Hashtbl.find cx.fns p) with
          | f -> go (f :: acc)
          | exception Demote t ->
              if not (List.mem t !demoted) then demoted := t :: !demoted;
              go acc
          | exception _ when !demoted <> [] -> raise (Demoted !demoted))
  in
  let fns = go [] in
  (* a function whose types are to be kept boxed was left unfinished, and
     whatever it reaches only through what's left wasn't reached *)
  if !demoted <> [] then raise (Demoted !demoted);
  let by_index table =
    List.map snd
      (List.sort compare (Hashtbl.fold (fun k n acc -> (n, k) :: acc) table []))
  in
  {
    fns = fns @ List.rev cx.lifted;
    start = c_name cx start_path;
    start_result = layout cx start.loc ret;
    start_fails = fn_fails start;
    start_desc;
    descs = List.rev cx.desc_list;
    decls =
      List.init (Hashtbl.length cx.decl_bodies) (Hashtbl.find cx.decl_bodies);
    tags = by_index cx.tags;
    values =
      List.filter_map
        (Hashtbl.find_opt cx.values)
        (List.concat_map (fun (m : C.program) -> m.values) modules);
    strings = List.rev cx.string_list;
    sites = List.rev cx.sites;
    structs = List.rev cx.struct_list;
    overflow;
  }

(* In a release build, a small value's type a value of which turns out
   to need a word, a field of an object or, if it holds an object, an
   array's element, is kept boxed, and the program compiled again: once
   for each pass that finds such types, which is once for most programs
   that have any, and never more than once for each type. Where a value
   has to be a word is its type's to decide, not its layout's. Boxing a
   type can make another a struct, one with a field of the type, which a
   later pass may find to box in turn; each pass boxes types none before
   did, so it ends. *)
let program ?(release = false) (modules : C.program list) : Mem.program =
  let boxed = Hashtbl.create 4 in
  let box t =
    if Hashtbl.mem boxed t then bug "a type kept boxed found again";
    Hashtbl.replace boxed t ()
  in
  let rec go () =
    match compile ~release ~boxed modules with
    | p -> p
    | exception Demote t ->
        box t;
        go ()
    | exception Demoted ts ->
        List.iter box ts;
        go ()
  in
  go ()
