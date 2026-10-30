(* The one walk over a value and its type: what `==`, `hash`, ordering
   and `show` are derived from (operators.md, "Equality, hashing and
   `show`"). Each of them is a fold over [view], which says what a value
   of a type is made of, as its type's declaration says: a record's
   fields, a constructor and its fields, an array's elements, a tuple's
   parts, a map's entries or a set's members, in the order each was
   first set, an error's payload, as the error itself says (Core.Tag), an
   opaque value's representation. So the four can't
   disagree about what a type is made of, and a new kind of type is
   taught to all four at once, here.

   The type is the running program's (core.ml, [desc]): what a generic
   function's type variables stand for is known by the time a value of
   one is walked, from the descriptors its caller passed. A type variable
   nothing decided, which a function the runtime calls from outside has,
   says nothing, so a value of one is walked by its shape alone.

   `==`, `hash` and ordering go through a type's `key`, if it has one:
   the key is the one way to change what equal means, and with it hashing
   and ordering, so the three never disagree. `show` never does: a value
   is shown as it is, or as its type's own `show` makes it (shown.ml).
   Calling a key is the interpreter's, so it's passed in ([cx]). *)

open Value

(* Every type's declaration, by its path. *)
type types = (Path.t, Iface.type_decl) Hashtbl.t

let types_of (decls : Iface.type_decl list) : types =
  let t = Hashtbl.create 64 in
  List.iter (fun (d : Iface.type_decl) -> Hashtbl.replace t d.path d) decls;
  t

(* [t] with each of its type's parameters, [Var i], replaced by [args]'s
   [i]th. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | Variant (p, c, ts) -> Variant (p, c, List.map (subst args) ts)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst args p.ty }) ps,
          subst args r,
          e,
          u )
  | Errors _ | Impl _ | Error -> t

(* What a value of a type is made of. *)
type view =
  | Leaf  (** an `Int`, a `Float`, a `Bool`, a `Str`, `Bytes` or `Unit` *)
  | Record of {
      name : string;
      opaque : bool;
          (** whether it's declared [opaque \{ ... \}], which is shown as
              [Name(f: v)], since no other module can write it as a record *)
      fields : (string * Ty.ty * Value.t) list;
    }
      (** a record: its type's name, and its fields in the order they're
          declared, each with its type *)
  | Ctor of {
      name : string;
      index : int;
      fields : (Ty.ty * Value.t) list;
      names : string list option;
    }
      (** a constructor: its name, its place among its type's, which is the
          order a sum type with no fields has, and its fields, with their
          names if it's by name (compiler.md, "Data stage", "By-name
          variants") *)
  | Opaque of string * Ty.ty
      (** an opaque value: its type's name, and what it's represented as, which
          the value is *)
  | Hidden of string
      (** an opaque value whose representation isn't known here *)
  | Elems of Ty.ty * Value.t array  (** an array's elements, and their type *)
  | Parts of (Ty.ty * Value.t) list  (** a tuple's parts, each with its type *)
  | Entries of Ty.ty * Ty.ty * Value.table
      (** a [Map]'s entries, and the types of its keys and values *)
  | Members of Ty.ty * Value.table  (** a [Set]'s members, and their type *)
  | Tag of string * (Ty.ty * Value.t) list
      (** an error: its tag, and its payload, each with its type *)
  | Shape
      (** a value nothing says the type of: a type variable left undecided *)

(* What [v], of type [t], is made of. *)
let view (types : types) (t : Ty.ty) (v : Value.t) =
  (* a variant type's value is its sum's, and so is how it's shown,
     compared and hashed (compiler.md, "Data stage", "Variant types") *)
  let t = Ty.as_sum t in
  let body =
    match t with
    | Con (p, _) ->
        Option.map
          (fun (d : Iface.type_decl) -> d.body)
          (Hashtbl.find_opt types p)
    | _ -> None
  in
  match (t, body, v) with
  (* an opaque value is what it's represented as, which may be an [Int] *)
  | Con (p, args), Some (Opaque (Rep rep)), _ -> Opaque (p.name, subst args rep)
  | Con (p, _), Some (Opaque (Hidden _)), _ -> Hidden p.name
  | _, _, (VInt _ | VFloat _ | VBool _ | VStr _ | VBytes _ | VUnit) -> Leaf
  (* an error carries its payload's types (Core.Tag), which says what they
     are even for one an error set's tail brought in *)
  | _, _, VTag { name; args; tys } -> Tag (name, List.combine tys args)
  | Con (p, [ elem ]), _, VArray xs when p = Path.prelude "Array" ->
      Elems (elem, items xs)
  | Con (p, parts), _, VTuple xs
    when Ty.is_tuple p && List.length parts = List.length xs ->
      Parts (List.combine parts xs)
  | Con (p, [ k; v ]), _, VTable t when p = Path.prelude "Map" ->
      Entries (k, v, t)
  | Con (p, [ elem ]), _, VTable t when p = Path.prelude "Set" ->
      Members (elem, t)
  | Con (p, args), _, _ -> (
      let field (f : Iface.field) = subst args f.fty in
      match (body, v) with
      | Some (Record fs), VRecord vs ->
          Record
            {
              name = p.name;
              opaque =
                (match Hashtbl.find_opt types p with
                | Some d -> d.opaque
                | None -> false);
              fields =
                List.map
                  (fun (f : Iface.field) ->
                    (f.fname, field f, List.assoc f.fname vs))
                  fs;
            }
      | Some (Sum cs), VCon c ->
          let rec find i = function
            | [] -> Shape
            | (k : Iface.ctor) :: _ when k.cname = c.name ->
                if List.length k.cfields = List.length c.args then
                  Ctor
                    {
                      name = c.name;
                      index = i;
                      fields = List.combine (List.map field k.cfields) c.args;
                      names =
                        (if k.cnamed then
                           Some (List.map (fun (f : Iface.field) -> f.fname) k.cfields)
                         else None);
                    }
                else Shape
            | _ :: rest -> find (i + 1) rest
          in
          find 0 cs
      | _ -> Shape)
  | _ -> Shape

(* What the walks for `==`, `hash` and ordering need of the interpreter:
   the types, and the key of a value of a type that has one, with the
   key's type. *)
type cx = {
  types : types;
  key : Path.t -> Ty.ty list -> Value.t -> (Ty.ty * Value.t) option;
}

(* [v]'s key, if its type has one. *)
let keyed cx (t : Ty.ty) v =
  (* a variant type's key is its sum's, borrowed *)
  match Ty.as_sum t with Con (p, args) -> cx.key p args v | _ -> None

(* ---- `hash` ---- *)

(* The runtime's own seed, chosen when it starts, which every hash is
   mixed with: which keys share a hash then depends on it, so keys can't
   be chosen ahead of time to collide, as they could with a fixed hash
   (operators.md, "`Map` and `Set`"). Nothing a program sees depends on
   it: a table keeps its keys in the order they were set (table.ml). *)
let seed = ref (Random.State.bits64 (Random.State.make_self_init ()))

(* The seed made a constant, before anything is hashed: what `ren test`
   and `ren replay` run with, so a test, or a replay, goes the same way
   inside too, not only in what it shows (compiler.md, "Bytes stage"). It
   can't change once a table is made, which keeps its keys' hashes. *)
let fix_seed () = seed := 0x5eed_0f_7e57L

(* Two hashes made one, so each part's place counts: FNV-1a's step, with
   the seed. The multiplication's carries make where two parts' hashes
   collide differ from seed to seed. *)
let mix h x = Int64.mul (Int64.logxor (Int64.logxor h x) !seed) 0x100000001b3L

let hash_string s =
  String.fold_left
    (fun h c -> mix h (Int64.of_int (Char.code c)))
    0xcbf29ce484222325L s

(* A float's hash: -0.0 is 0.0, which [=] says it equals. A NaN can't be
   hashed (nan.ml): what asked says so. *)
let hash_float f =
  if Float.is_nan f then raise (Nan.Seen f);
  mix 2L (Int64.bits_of_float (if f = 0. then 0. else f))

(* Two leaves the same, a NaN in either seen (nan.ml), the first's
   before the second's. *)
let same_leaf a b =
  match (a, b) with
  | VFloat x, _ when Float.is_nan x -> raise (Nan.Seen x)
  | _, VFloat y when Float.is_nan y -> raise (Nan.Seen y)
  | _ -> a = b

(* [v]'s hash by its shape alone, which agrees with [by_shape]. *)
let rec hash_shape v =
  let all h xs = List.fold_left (fun h x -> mix h (hash_shape x)) h xs in
  match v with
  | VInt n -> mix 1L n
  | VFloat f -> hash_float f
  | VStr s -> mix 3L (hash_string s)
  | VBytes s -> mix 4L (hash_string s)
  | VBool b -> mix 5L (if b then 1L else 0L)
  | VUnit -> 6L
  | VRecord xs -> all 7L (List.map snd xs)
  | VCon c -> all (mix 8L (hash_string (Path.local c.ty ^ "." ^ c.name))) c.args
  | VArray xs -> all 9L (Array.to_list (items xs))
  | VTag x -> all (mix 10L (hash_string x.name)) x.args
  | VTuple xs -> all 11L xs
  | VTable t ->
      (* in any order, as [hash] *)
      List.fold_left
        (fun h (k, v) -> Int64.add h (mix (hash_shape k) (hash_shape v)))
        12L (Table.to_list t)
  | VClosure _ | VFn _ | VBuiltin _ | VHandler _ | VInstance _ | VType _
  | VDict _ | VCell _ | VEvidence _ | VSched _ ->
      failwith "bug: a hash of something with no `==`"

(* [v]'s hash, as a value of type [t]: the same for two values [equal]
   says are equal, by their key if their type has one, `-0.0` and `0.0`
   included: what a `Map` finds a key by, and a `Set` a member (table.ml).
   A table's is its entries' added up, so it's the same in any order, as
   its `==` is. *)
let rec hash cx (t : Ty.ty) v =
  match keyed cx t v with
  | Some (k, x) -> hash cx k x
  | None -> (
      let all h parts =
        List.fold_left (fun h (t, x) -> mix h (hash cx t x)) h parts
      in
      match (view cx.types t v, v) with
      | Leaf, VInt n -> mix 1L n
      | Leaf, VFloat f -> hash_float f
      | Leaf, VStr s -> mix 3L (hash_string s)
      | Leaf, VBytes s -> mix 4L (hash_string s)
      | Leaf, VBool b -> mix 5L (if b then 1L else 0L)
      | Leaf, _ -> 6L
      | Record { fields = fs; _ }, _ ->
          all 7L (List.map (fun (_, t, x) -> (t, x)) fs)
      | Ctor c, _ -> all (mix 8L (Int64.of_int c.index)) c.fields
      | Opaque (_, rep), _ -> hash cx rep v
      | Elems (t, xs), _ ->
          all 9L (Array.to_list (Array.map (fun x -> (t, x)) xs))
      | Tag (name, payload), _ -> all (mix 10L (hash_string name)) payload
      | Parts parts, _ -> all 11L parts
      | Entries (kt, vt, t), _ ->
          (* the same in any order, as `==` is: each entry's hash, added *)
          List.fold_left
            (fun h (k, v) -> Int64.add h (mix (hash cx kt k) (hash cx vt v)))
            12L (Table.to_list t)
      | Members (t, members), _ ->
          List.fold_left
            (fun h (k, _) -> Int64.add h (hash cx t k))
            13L (Table.to_list members)
      | (Hidden _ | Shape), _ -> hash_shape v)

(* What [f] gives with the seed 0: a hash with no seed, the same in every
   run. Nothing hashes meanwhile but [f]'s own walk, and a key's
   function, which can't wait. *)
let unseeded f =
  let s = !seed in
  seed := 0L;
  Fun.protect ~finally:(fun () -> seed := s) f

(* [v]'s hash as [hash] gives it, but with no seed: what has to be the
   same in every run, which of `striped`'s stripes a key goes to
   (`Call.first_hash`), since what each instance holds can be seen, and `x.hash()`, which a program can print or journal
   (compiler.md, "Bytes stage"). A native build computes the same bits
   (ren_rt.c, [ren_hash_fixed]). *)
let fixed_hash cx t v = unseeded (fun () -> hash cx t v)

(* ---- `==` ---- *)

(* [a] and [b] compared by their shape alone, where nothing says what
   type they are. Inference made sure nothing compared holds a function. *)
let rec by_shape a b =
  match (a, b) with
  | VCon x, VCon y ->
      x.ty = y.ty && x.name = y.name
      && List.length x.args = List.length y.args
      && List.for_all2 by_shape x.args y.args
  | VTag x, VTag y ->
      x.name = y.name
      && List.length x.args = List.length y.args
      && List.for_all2 by_shape x.args y.args
  | VRecord xs, VRecord ys ->
      List.length xs = List.length ys
      && List.for_all2 (fun (_, x) (_, y) -> by_shape x y) xs ys
  | VArray xs, VArray ys ->
      xs.len = ys.len && Array.for_all2 by_shape (items xs) (items ys)
  | VTuple xs, VTuple ys ->
      List.length xs = List.length ys && List.for_all2 by_shape xs ys
  | VTable x, VTable y ->
      (* in order: a table's type is always known where it's compared, so
         this is never what decides *)
      let xs = Table.to_list x and ys = Table.to_list y in
      List.length xs = List.length ys
      && List.for_all2
           (fun (k, v) (k', v') -> by_shape k k' && by_shape v v')
           xs ys
  | (VInt _ | VFloat _ | VBool _ | VStr _ | VBytes _ | VUnit), _ ->
      same_leaf a b
  | (VClosure _ | VFn _ | VBuiltin _ | VHandler _ | VInstance _), _ ->
      failwith "bug: a comparison of functions"
  | (VCon _ | VTag _ | VRecord _ | VArray _ | VTuple _ | VTable _), _ -> false
  | (VType _ | VDict _ | VCell _ | VEvidence _ | VSched _), _ ->
      failwith "bug: a comparison of something a program never sees"

(* [a] and [b], of type [t], equal: by their keys, if their type has one,
   and otherwise part by part. A [Float]'s `-0.0` and `0.0` are equal, as
   OCaml's [=] on floats has them; a NaN met on the way is seen
   (nan.ml). [equal], below, sees one it didn't meet too. *)
let rec equal_in cx (t : Ty.ty) a b =
  let equal = equal_in in
  match (keyed cx t a, keyed cx t b) with
  | Some (k, x), Some (_, y) -> equal cx k x y
  | _ -> (
      match (view cx.types t a, view cx.types t b) with
      | Leaf, _ -> same_leaf a b
      | Record { fields = xs; _ }, Record { fields = ys; _ } ->
          List.for_all2 (fun (_, t, x) (_, _, y) -> equal cx t x y) xs ys
      | Ctor x, Ctor y ->
          x.name = y.name
          && List.for_all2
               (fun (t, x) (_, y) -> equal cx t x y)
               x.fields y.fields
      | Ctor _, _ | _, Ctor _ -> false
      | Opaque (_, rep), _ -> equal cx rep a b
      | Elems (t, xs), Elems (_, ys) ->
          Array.length xs = Array.length ys && Array.for_all2 (equal cx t) xs ys
      | Parts xs, Parts ys ->
          List.for_all2 (fun (t, x) (_, y) -> equal cx t x y) xs ys
      | Entries (k, v, x), Entries (_, _, y) ->
          (* the same keys, each with an equal value, in any order *)
          let d = by_hash cx k in
          Table.len x = Table.len y
          && List.for_all
               (fun (key, a) ->
                 match Table.get d y key with
                 | Some b -> equal cx v a b
                 | None -> false)
               (Table.to_list x)
      | Members (t, x), Members (_, y) ->
          let d = by_hash cx t in
          Table.len x = Table.len y
          && List.for_all
               (fun (key, _) -> Table.find d y key <> None)
               (Table.to_list x)
      | Tag (x, xs), Tag (y, ys) ->
          x = y && List.for_all2 (fun (t, x) (_, y) -> equal cx t x y) xs ys
      | Tag _, _ | _, Tag _ -> by_shape a b
      | _ -> by_shape a b)

(* The `hash` dictionary of [t]'s values, which a table finds a key by. *)
and by_hash cx t = Hash { hash = hash cx t; equal = equal_in cx t }

(* ---- ordering ---- *)

(* [a] against [b], of type [t]: negative if [a] comes first, 0 if
   they're equal, positive if [b] does. Inference allows it only for a
   type that has an order: an `Int` or a `Float`, a total order once a
   NaN is seen (nan.ml); a `Str` by its bytes, which is code point order; a
   `Bool`, `false` first; a sum type with no fields, by the order of its
   variants; a tuple, part by part, the first that differs deciding;
   anything with a key, by its key; and an opaque type in its own module,
   as what it's represented as. [compare], below, sees a NaN it didn't
   meet. *)
let rec compare_in cx (t : Ty.ty) a b =
  let compare = compare_in in
  match (keyed cx t a, keyed cx t b) with
  | Some (k, x), Some (_, y) -> compare cx k x y
  | _ -> (
      match (view cx.types t a, view cx.types t b, a, b) with
      | Leaf, _, VInt x, VInt y -> Int64.compare x y
      | Leaf, _, VFloat x, VFloat y ->
          ignore (same_leaf a b);
          Float.compare x y
      | Leaf, _, VStr x, VStr y -> String.compare x y
      | Leaf, _, VBool x, VBool y -> Bool.compare x y
      | Ctor x, Ctor y, _, _ -> Int.compare x.index y.index
      | Parts xs, Parts ys, _, _ ->
          let rec first = function
            | ((t, x), (_, y)) :: rest ->
                let c = compare cx t x y in
                if c <> 0 then c else first rest
            | [] -> 0
          in
          first (List.combine xs ys)
      | Opaque (_, rep), _, _, _ -> compare cx rep a b
      | _ -> failwith "bug: an order inference didn't allow")

(* ---- NaN ---- *)

(* Raise [Nan.Seen] of the first NaN in [v], of type [t], in the order
   its parts are declared, as the runtime's walk finds it
   ([ren_nan_val]). [through] says what a value is seen through, if not
   what it's made of: its key, for what's compared. *)
let rec nan_walk ~through (types : types) (t : Ty.ty) v =
  let nan_in = nan_walk ~through in
  match through t v with
  | Some (k, x) -> nan_in types k x
  | None -> (
      match (view types t v, v) with
      | Leaf, VFloat f when Float.is_nan f -> raise (Nan.Seen f)
      | Leaf, _ -> ()
      | Record { fields; _ }, _ ->
          List.iter (fun (_, t, x) -> nan_in types t x) fields
      | Ctor c, _ -> List.iter (fun (t, x) -> nan_in types t x) c.fields
      | Opaque (_, rep), _ -> nan_in types rep v
      | Elems (t, xs), _ -> Array.iter (nan_in types t) xs
      | (Tag (_, parts) | Parts parts), _ ->
          List.iter (fun (t, x) -> nan_in types t x) parts
      | Entries (kt, vt, tb), _ ->
          List.iter
            (fun (k, x) ->
              nan_in types kt k;
              nan_in types vt x)
            (Table.to_list tb)
      | Members (t, tb), _ ->
          List.iter (fun (k, _) -> nan_in types t k) (Table.to_list tb)
      | (Hidden _ | Shape), _ -> nan_shape v)

(* The same, by its shape alone. *)
and nan_shape v =
  match v with
  | VFloat f when Float.is_nan f -> raise (Nan.Seen f)
  | VCon { args; _ } | VTag { args; _ } | VTuple args -> List.iter nan_shape args
  | VRecord xs -> List.iter (fun (_, x) -> nan_shape x) xs
  | VArray xs -> Array.iter nan_shape (items xs)
  | VTable t ->
      List.iter
        (fun (k, x) ->
          nan_shape k;
          nan_shape x)
        (Table.to_list t)
  | _ -> ()

(* What's given to a dependency's operation (nan.ml): through what it's
   made of, not its key. *)
let nan_in types t v = nan_walk ~through:(fun _ _ -> None) types t v

(* ---- `==` and ordering, a NaN in what's compared seen ----

   Comparing a value with a NaN in it panics (operators.md, "`Int` and
   `Float`"), whether or not the walk met it: `Some(nan) == None` stops
   at the constructors and `(1, nan) < (2, 0.0)` at the first part, but
   each compares a value a NaN is in. So a comparison that ends early,
   unequal or ordered, looks through both values for one, [a]'s first,
   in the order their parts are declared, as the runtime does
   ([ren_equal_any], [ren_compare_any]). One that doesn't end early met
   every leaf, so it has seen any NaN already. *)

let nan_compared cx t a b =
  nan_walk ~through:(keyed cx) cx.types t a;
  nan_walk ~through:(keyed cx) cx.types t b

let equal cx (t : Ty.ty) a b =
  let same = equal_in cx t a b in
  if not same then nan_compared cx t a b;
  same

let compare cx (t : Ty.ty) a b =
  let c = compare_in cx t a b in
  if c <> 0 then nan_compared cx t a b;
  c
