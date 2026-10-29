(* Values: what a running Ren program computes. A module of its own, so the
   prelude's built-in functions (builtins.ml) can work on values without
   depending on the interpreter that calls them. *)

(* Variables in scope: an immutable map from a local's binder id (core.ml)
   to a cell holding its value. Map.Make is a functor: a function from a
   module (Int) to a module (Env). *)
module Env = Map.Make (Int)

(* Maps keyed by an [int] and by an [Int64.t], for a table's entries and
   its hashes (see [table]). *)
module Ints = Map.Make (Int)
module Hashes = Map.Make (Int64)

type t =
  | VInt of Int64.t
  | VFloat of float
  | VBool of bool
  | VStr of string  (** UTF-8, always *)
  | VBytes of string  (** any bytes at all *)
  | VUnit
  | VCon of { ty : Path.t; name : string; args : t list }
      (** [Pro(5)]: the type it belongs to, the constructor, its fields *)
  | VRecord of (string * t) list
      (** fields sorted by name, so structural equality ignores field order *)
  | VArray of vec
      (** never changed as a program sees it: an update makes a new one, and
          `push` shares what it can (see [vec]) *)
  | VTuple of t list  (** [(k, v)]: two parts, or three *)
  | VTable of table
      (** a [Map]'s entries, or a [Set]'s members, each a key whose value is
          [VUnit]. Never changed in place: setting a key makes a new table,
          which shares most of the old one *)
  | VClosure of {
      params : int list;  (** the parameters' binder ids *)
      ev : int;  (** the id of the evidence its body runs with *)
      outer : int;
          (** the id of the evidence where it was written, which it captured *)
      given : (Path.t * Ty.ty list) list;
          (** what it takes from the evidence it's passed where it's called, on
              top of [outer]'s (Core.Lambda), each dependency with its type
              arguments *)
      body : Core.expr;
      env : t ref Env.t;
      site : string;
          (** the label of the code it's written in, `serve`, or `ticks.tick`
              for a handler's arm: what a task it spawns is labelled by
              (compiler.md, "Stage 11a", "Structured tasks") *)
    }
      (** a block, with the variables it captured when it was made, the evidence
          where it was written and the hidden type parameters of the function
          it's in among them *)
  | VFn of Path.t * Ty.ty list * t list
      (** a top-level function used as a value, with what it's given for its
          hidden type parameters, the types its type variables stand for where
          it was used (core.ml, [desc]), and for its hidden dictionary
          parameters, a [VDict] for each of its requirements (core.ml, [dict])
      *)
  | VBuiltin of Intrinsic.t * Ty.ty list * t list
      (** a function built into the prelude, [show], with the types its type
          variables stand for and a [VDict] for each of its requirements, as a
          [VFn]'s: [Map.get] is given its keys' `hash` *)
  | VType of Ty.ty
      (** a type's descriptor, built where it's passed (core.ml, [desc]): what a
          hidden type parameter holds. A program never sees one *)
  | VDict of dict
      (** a requirement's dictionary, built where it's passed (core.ml, [dict]):
          what a hidden dictionary parameter holds. A program never sees one *)
  | VTag of { name : string; args : t list; tys : Ty.ty list }
      (** an error, [Short(2, 45000)]: its tag, its payload, and the payload's
          types in the running program (Core.Tag). A program sees one only
          inside a [Result]'s [Err] *)
  | VHandler of handler
      (** a handler, described (core.ml, [Handler]): a value of its dependency's
          type, or of the handler's own *)
  | VInstance of {
      impls : (Path.t * t) list;
      finally : t option;
      exclusive : bool;
    }
      (** a handler's instance: an implementation of each of its dependencies,
          and its `finally`, a closure, if it has one; [exclusive] as
          Core's [Instance] *)
  | VCell of t ref
      (** a `var` of a handler's state, shared by its instance's operations *)
  | VEvidence of installed list
      (** evidence (core.ml): what's installed, the innermost first. A program
          never sees one *)
  | VSched of sched
      (** a scope or a task's handle, which the scheduler made (sched.ml) *)
  | VKeyed of int * t
      (** `sync.keyed(n, h)`: a description of [n] instances of the handler
          [h] describes, made when it's installed *)
  | VKeys of (t * int * bool) array
      (** [VKeyed]'s instances, installed: each one's implementation of the
          dependency, its number and whether it's exclusive, as an
          [installed]'s, which an operation's call picks one of by its first
          argument (eval.ml, [Dep_call]) *)

(* What the scheduler gives a program to hold, `Scope` and `Task<T>`'s
   values. It's an extensible type, one whose constructors are declared
   elsewhere, with [+=]: sched.ml declares them, since they hold its own
   records, which hold values, so neither module can come first. *)
and sched = ..

(* A dictionary: what a type has that a requirement names, as the
   interpreter's own functions (core.ml, [dict]): `eq`'s `==`, `ord`'s
   comparison, negative, 0 or positive, `hash`'s hash, with the `==` it
   agrees with, since a `Map` needs both of its keys, an operator, `add`,
   given where it's used and where its operands are, for a panic, and an
   associated value, `zero`. *)
and dict =
  | Eq of (t -> t -> bool)
  | Ord of (t -> t -> int)
  | Hash of { hash : t -> int64; equal : t -> t -> bool }
  | Op of (Loc.t -> Loc.t list -> t list -> t)
  | Const of t

(* A table of keys and their values, in the order each key was first set
   (operators.md, "`Map` and `Set`"): [entries] by that order's number,
   the next of which is [next], and [buckets], each entry's number by its
   key's hash, which finds a key without looking at every one. Two keys
   with one hash share a bucket. table.ml has what's done with one. *)
and table = {
  entries : (t * t) Ints.t;
  buckets : int list Hashes.t;
  next : int;
}

(* An array: the first [len] items of a [store], which other arrays may
   share. An item below an array's [len] is never changed, so sharing is
   safe. What it buys is `push`, which an array is built by: pushing onto
   an array that ends where its store's used items do writes the item
   into the store's spare room, in place, and gives a longer array of the
   same store, while the one pushed onto still sees its own [len] items.
   Pushing onto any other array copies it. So a loop of `&out.push(x)` is
   linear, not quadratic, as each push would be if it copied (compiler.md,
   "Stage 9b"). [push] below is the only thing that writes a store. *)
and vec = { store : store; len : int }
and store = { mutable items : t array; mutable used : int }

(* A handler's description: its body makes an instance, given the
   evidence [ev] where it's installed, with the variables it captured. *)
and handler = { ev : int; body : Core.expr; env : t ref Env.t }

(* An implementation of the dependency [dep] at the type arguments
   [args], a generic one's instance, installed: it runs with the evidence
   [outer], what was installed where it was. [inst] numbers the instance
   it's an implementation of ([instance]): a handler of several
   dependencies installs one of these for each, with one number, since
   they share one state. [excl] says its operations don't interleave
   once a spawned task can reach it (Core's [Instance]'s [exclusive];
   sched.ml, [holding]). *)
and installed = {
  dep : Path.t;
  args : Ty.ty list;
  impl : t;
  outer : installed list;
  inst : int;
  excl : bool;
}

(* A new instance's number, each one more than the last: so an instance
   made before another has a smaller number, which is how `Async.isolate`
   tells the instances installed outside it from those inside it
   (sched.ml, [isolatable]). *)
let instances = ref 0

let instance () =
  incr instances;
  !instances

(* An array of [xs], which it takes: nothing else may change [xs]. *)
let array xs =
  VArray
    { store = { items = xs; used = Array.length xs }; len = Array.length xs }

let array_of_list xs = array (Array.of_list xs)

(* [v]'s items, as an array of their own. *)
let items v = Array.sub v.store.items 0 v.len
let nth v i = v.store.items.(i)

(* [v] with [x] after its items: in [v]'s store, if [v] ends where the
   store's used items do and there's room, or with room made, by doubling
   it; or else in a copy. *)
let push v x =
  let s = v.store in
  if v.len = s.used && v.len < Array.length s.items then begin
    s.items.(v.len) <- x;
    s.used <- v.len + 1;
    VArray { store = s; len = v.len + 1 }
  end
  else begin
    let items = Array.make (max 8 (2 * (v.len + 1))) VUnit in
    Array.blit s.items 0 items 0 v.len;
    items.(v.len) <- x;
    VArray { store = { items; used = v.len + 1 }; len = v.len + 1 }
  end

let rec show = function
  | VInt n -> Int64.to_string n
  | VFloat f -> Ast.show_float f
  | VBool b -> string_of_bool b
  | VStr s -> Ast.show_str s
  | VBytes b ->
      (* there's no way to write bytes yet, so each one in hex *)
      let hex i = Printf.sprintf " %02x" (Char.code b.[i]) in
      "<bytes" ^ String.concat "" (List.init (String.length b) hex) ^ ">"
  | VUnit -> "()"
  | VCon { name; args = []; _ } | VTag { name; args = []; _ } -> name
  | VCon { name; args; _ } | VTag { name; args; _ } ->
      name ^ "(" ^ String.concat ", " (List.map show args) ^ ")"
  | VRecord fields ->
      let show_field (f, v) = f ^ ": " ^ show v in
      "{ " ^ String.concat ", " (List.map show_field fields) ^ " }"
  | VArray v ->
      "[" ^ String.concat ", " (Array.to_list (Array.map show (items v))) ^ "]"
  | VTuple xs -> "(" ^ String.concat ", " (List.map show xs) ^ ")"
  | VTable t ->
      (* shown through its type, shown.ml, which knows a `Set` from a `Map` *)
      "{"
      ^ String.concat ", "
          (List.map
             (fun (_, (k, v)) -> show k ^ ": " ^ show v)
             (Ints.bindings t.entries))
      ^ "}"
  | VClosure _ -> "<fn>"
  | VFn (p, _, _) -> "<fn " ^ Path.local p ^ ">"
  | VBuiltin (x, _, _) -> "<fn " ^ Intrinsic.name x ^ ">"
  | VHandler _ -> "<handler>"
  | VInstance _ -> "<instance>"
  | VCell _ -> "<cell>"
  | VEvidence _ -> "<evidence>"
  | VSched _ -> "<task>"
  | VKeyed _ -> "<handler>"
  | VKeys _ -> "<instance>"
  | VType _ -> "<type>"
  | VDict _ -> "<dict>"
