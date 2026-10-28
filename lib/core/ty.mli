(* Types in canonical form, what leaves the type checker, and how they're
   printed (see ty.ml). Equal programs give equal [ty] values, so a type
   can be cached or compared with [=]. *)

type mode = Ast.mode = Read | Inout

type ty =
  | Con of Path.t * ty list  (** [Int], [Option<Int>], [User] *)
  | Fun of param list * ty * row * row  (** params, result, errors, uses *)
  | Var of int
      (** a type variable. In a scheme, a generic one, numbered by first
          appearance; in a type declaration, the declaration's parameter at that
          position (`T` in `Option<T>` is [Var 0]) *)
  | Errors of row
      (** an error set as a type argument, [! Short(Int) | Frozen], which only
          [Result<T, ! ...>] takes (errors.md, "Keeping an error") *)
  | Impl of impl
      (** an implementation of a dependency, or of several sharing one state,
          what a handler of several describes, [Clock & TestClock] ([impl]) *)
  | Error  (** the type of code that had an error, already reported *)

and param = { mode : mode; ty : ty }

(* An implementation's type (deps.md, "Implementations"): the
   dependencies it implements, sorted, each once; whether it goes over
   another implementation of them, [over Users] (handlers.md, "`over`"),
   whose [needs] then has them too; what it needs where it's installed,
   [Clock uses Os]; and what installing it can fail with, what its state
   and its `finally` fail with, [Sql ! DbDown]. *)
and impl = { deps : dep list; over : bool; needs : row; fails : row }

(* A dependency an implementation implements: its path and its type
   arguments, `Chan<Int>` (foundations.md, decision 6). *)
and dep = { dpath : Path.t; dargs : ty list }

and row = {
  labels : label list;  (** sorted by name *)
  tail : int option;
      (** [None]: exactly these labels. [Some n]: these and possibly more,
          standing for row variable [n] (numbered apart from type variables) *)
}

(* A row's label: an error's tag and its payload's types, `Short(Int)`, or
   a dependency, whose name is its path written in full ([dep_label]) and
   whose payload is its type arguments, `Chan<Int>`. A label is its name
   and payload together ([same_label]). *)
and label = { name : string; payload : ty list }

(* A function's type, for every choice of its variables. [names] are the
   names its variables were declared with, like the `T` of `fn id<T>`.
   [reqs] are what it needs of its variables, [(0, "eq")] for variable 0
   having `==`, which inference finds in the function's body. [row_reqs]
   are what it needs of its row variables, [(0, "eq")] for every tag row
   variable 0 stands for having `==`, which no dictionary is passed for:
   it's only checked where the function is used. All are sorted. *)
type scheme = {
  ty : ty;
  names : (int * string) list;
  reqs : (int * string) list;
  row_reqs : (int * string) list;
}

(* What one use of a scheme picks for its variables, its type arguments:
   the n-th of [tys] for [Var n], and the n-th of [rows] for row variable
   [n], which stands for that row's labels, added to the scheme's, and its
   tail. Typed Core carries them on each use of a top-level function
   (core.ml). *)
type args = { tys : ty list; rows : row list }

(* The prelude's types: [Int], [Bool], [Unit], [Str] and [Array<t>]. *)
val int : ty
val float : ty
val bool : ty
val unit : ty
val str : ty
val array : ty -> ty
val option : ty -> ty

(* A tuple's type, `(Str, Int)`: a built-in type for each size, named by
   its shape, ["(,)"] and ["(,,)"]. A program writes those two; the
   compiler makes the others, ["(_)"] for one part. *)
val tuple_path : int -> Path.t
val tuple : ty list -> ty
val is_tuple : Path.t -> bool

(* The dependency a handler `over any` lists until it's installed over
   one, and whether a dependency is it. *)
val any_path : Path.t
val is_any : dep -> bool

(* A parameter that isn't `inout`. *)
val read : ty -> param

(* The row with no labels and no tail: nothing at all. *)
val closed : row

(* A label with no payload: an error tag like `Frozen`, or a dependency. *)
val label : string -> label

(* Whether two labels are one: the same name and payload. *)
val same_label : label -> label -> bool

(* The dependency at a path, with no type arguments. *)
val plain : Path.t -> dep

(* The paths of some dependencies. *)
val dep_paths : dep list -> Path.t list

(* The type of an implementation of these dependencies, sorted and each
   once, needing the row; [over] another implementation of them, and
   failing to be installed with [fails] (nothing, unless it's said). *)
val impl : ?over:bool -> ?fails:row -> dep list -> row -> ty

(* If a type is an implementation's, of one dependency or several: which,
   and what it needs. *)
val impl_parts : ty -> (dep list * row) option

(* The name of the n-th lambda of a top-level function, counting from 1,
   `main.main#2`, which Lower gives its code. *)
val lambda_id : Path.t -> int -> string

(* The label of the dependency declared at a path, `Clock` or
   `shop/store.Users`, and the path back from a label. *)
val dep_label : Path.t -> string
val dep_path : string -> Path.t

(* A dependency as a row's label, its type arguments its payload, and
   back. *)
val dep_of : dep -> label
val of_label : label -> dep

(* Labels sorted by name, as a row keeps them, and by payload among
   those of one name. *)
val sort_labels : label list -> label list

(* The type arguments that give back a canonical type itself, the ones
   a function is used at its own type with: [Var n] for each type
   variable, and for each row variable a row of no labels ending in it. *)
val own_args : ty -> args

(* [s], a scheme's type, with the type arguments [a] put in: the n-th
   of [a.tys] for [Var n], and for a row ending in row variable [n], the
   n-th of [a.rows]'s labels added to the row's, ending in its tail. *)
val apply : args -> ty -> ty

(* A scheme with its variables renumbered by where they first appear,
   reading left to right, type and row variables separately, and its
   rows' labels sorted. Its [names],
   [reqs] and [row_reqs] follow their variables, and those of a variable
   the type doesn't have are dropped. *)
val canonical : scheme -> scheme

(* ---- printing ---- *)

(* A printer names variables consistently across everything printed with
   it: a variable gets the name it was declared with if that's still
   free, otherwise the next of T, U, V, ... A printer is mutable: it
   remembers the names it has handed out. *)
type printer

(* A printer for types of scheme [s], which gives its variables their
   declared names. [names] writes a type's name as the module it's shown
   in would (Resolve.type_name). Row tails are hidden unless [show_tail]
   picks them, by number, and then print as `..e` or `..d`. *)
val printer :
  ?show_tail:(int -> bool) -> names:(Path.t -> string) -> scheme -> printer

(* Replace the declared names the printer knows, by variable, as the
   [names] of a scheme. types.ml adds to them as it converts types for a
   message. *)
val set_hints : printer -> (int * string) list -> unit

(* Give a variable a name up front, which it prints as whatever else has
   that name: a type parameter like `T` while its function is checked. *)
val name : printer -> int -> string -> unit

(* The same for a row tail: a named row prints as itself, `..d`. *)
val name_tail : printer -> int -> string -> unit

(* Keep the declared names of a type's variables free, so an automatic
   name handed out first doesn't take them. *)
val reserve : printer -> ty -> unit

(* A type, as Ren writes it. *)
val show : printer -> ty -> string

(* A row: [prefix], then its labels joined by [sep], then its tail if
   it's shown, named after [kind] ("e" or "d"); empty for a row with
   nothing to show. A dependency's label ([kind] "d") is written as its
   type is. *)
val show_row :
  printer -> prefix:string -> sep:string -> kind:string -> row -> string

(* An error tag and its payload's types, `Short(Int, Money)`. *)
val show_label : printer -> label -> string

(* A dependency, as its type is written, `Chan<Int>`. *)
val show_dep : printer -> dep -> string

(* A function's `! errors` and `uses deps`, each with a leading space, or
   nothing for an empty row. *)
val show_effects : printer -> row -> row -> string

(* How `ren types` prints a function: `pub fn name<T>(x: T) -> T`, and
   `fn same<T has eq>(a: T, b: T) -> Bool` for one with requirements.
   [params] are its parameters' names. A row tail is shown only where it
   links two places. For a member of a type, [outer] are the type's
   parameters, which aren't listed after the name unless it needs
   something of one, and `self` is shown without its type. Fails with [Invalid_argument] if the scheme isn't a
   function's. *)
val signature :
  ?outer:string list ->
  names:(Path.t -> string) ->
  pub:bool ->
  name:string ->
  params:string list ->
  scheme ->
  string

(* How `ren types` prints an associated value, `pub let name: T`, whose
   type is [s]'s. *)
val value_signature :
  names:(Path.t -> string) -> pub:bool -> name:string -> scheme -> string

(* How `ren types` prints a handler: its parameters, named [params], the
   dependencies it implements, [deps], after `for` or `over`, what
   installing it can fail with, and what it needs, from the scheme
   of its function, whose result is the handler's type. Fails with
   [Invalid_argument] if that isn't a handler's. *)
val handler_signature :
  names:(Path.t -> string) ->
  pub:bool ->
  name:string ->
  params:string list ->
  deps:Path.t list ->
  scheme ->
  string
