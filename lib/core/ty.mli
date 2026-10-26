(* Types in canonical form, what leaves the type checker, and how they're
   printed (see ty.ml). Equal programs give equal [ty] values, so a type
   can be cached or compared with [=]. *)

type mode = Ast.mode = Read | Inout

type ty =
  | Con of Path.t * ty list  (** [Int], [Option<Int>], [User] *)
  | Fun of param list * ty * row * row * lams
      (** params, result, errors, uses, and its lambda set *)
  | Var of int
      (** a type variable. In a scheme, a generic one, numbered by first
          appearance; in a type declaration, the declaration's parameter at that
          position (`T` in `Option<T>` is [Var 0]) *)
  | Errors of row
      (** an error set as a type argument, [! Short(Int) | Frozen], which only
          [Result<T, ! ...>] takes (errors.md, "Keeping an error") *)
  | Uses of row
      (** what an implementation needs, as the one argument of its dependency's
          type: [Clock uses Os] is [Con (Clock, [Uses Os])] (deps.md,
          "Implementations"). Nothing else takes one *)
  | Error  (** the type of code that had an error, already reported *)

and param = { mode : mode; ty : ty }

and row = {
  labels : label list;  (** sorted by name *)
  tail : int option;
      (** [None]: exactly these labels. [Some n]: these and possibly more,
          standing for row variable [n] (numbered apart from type variables) *)
}

(* A row's label: an error's tag and its payload's types, `Short(Int)`, or
   a dependency, whose payload is always empty and whose name is its
   path written in full ([dep_label]). *)
and label = { name : string; payload : ty list }

(* A function type's lambda set: the identities of the lambdas and
   top-level functions known to flow to it, sorted, and the lambda-set
   variable that stands for the rest, numbered apart from type and row
   variables. A set is always open. Hidden from every message and from
   `ren types` (see ty.ml). In canonical form [lvar] is [Some n]; [None]
   is a set nothing else shares, in a type written in a declaration,
   which [canonical] numbers. *)
and lams = { ids : string list; lvar : int option }

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
   tail, and the n-th of [lams] for lambda-set variable [n], the same way.
   Typed Core carries them on each use of a top-level function
   (core.ml). *)
type args = { tys : ty list; rows : row list; lams : lams list }

(* The prelude's types: [Int], [Bool], [Unit], [Str] and [Array<t>]. *)
val int : ty
val bool : ty
val unit : ty
val str : ty
val array : ty -> ty

(* A parameter that isn't `inout`. *)
val read : ty -> param

(* The row with no labels and no tail: nothing at all. *)
val closed : row

(* A label with no payload: an error tag like `Frozen`, or a dependency. *)
val label : string -> label

(* A lambda set of its own, for a function type written in a
   declaration. *)
val any_lams : lams

(* The identity in a lambda set of a top-level function, a member or an
   intrinsic, by its path, and of the n-th lambda of a top-level function,
   counting from 1, `main.main#2`. *)
val global_id : Path.t -> string
val lambda_id : Path.t -> int -> string

(* The lambda-set variables in a type, in the order they appear. *)
val lam_vars : ty -> int list

(* A type with every lambda set [any_lams]: the type without them, to
   compare by what can be written. *)
val without_lams : ty -> ty

(* The label of the dependency declared at a path, `Clock` or
   `shop/store.Users`, and the path back from a label. *)
val dep_label : Path.t -> string
val dep_path : string -> Path.t

(* Labels sorted by name, as a row keeps them. *)
val sort_labels : label list -> label list

(* The type arguments that give back a canonical type itself, the ones
   a function is used at its own type with: [Var n] for each type
   variable, for each row variable a row of no labels ending in it, and
   for each lambda-set variable an empty set ending in it. *)
val own_args : ty -> args

(* A scheme with its variables renumbered by where they first appear,
   reading left to right, type, row and lambda-set variables separately,
   and its rows' labels and lambda sets' identities sorted. A lambda set
   of its own ([any_lams]) gets a variable of its own. Its [names],
   [reqs] and [row_reqs] follow their variables, and those of a variable
   the type doesn't have are dropped. *)
val canonical : scheme -> scheme

(* A scheme with each of its lambda sets one of its own, numbered apart,
   in canonical form: what an interface states of a function, whose
   lambda sets inference finds from bodies. *)
val forget_lams : scheme -> scheme

(* ---- printing ---- *)

(* A printer names variables consistently across everything printed with
   it: a variable gets the name it was declared with if that's still
   free, otherwise the next of T, U, V, ... A printer is mutable: it
   remembers the names it has handed out. *)
type printer

(* A printer for types of scheme [s], which gives its variables their
   declared names. [names] writes a type's name as the module it's shown
   in would (Resolve.type_name). Row tails are hidden unless [show_tail]
   picks them, by number, and then print as `..e` or `..d`. Lambda sets
   are hidden unless [show_lams], which only a debug printer passes, and
   then print after the function's effects, `[main.inc | ..l0]`. *)
val printer :
  ?show_tail:(int -> bool) ->
  ?show_lams:bool ->
  names:(Path.t -> string) ->
  scheme ->
  printer

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

(* A lambda set, with a leading space, ` [main.inc | ..l0]`, if the
   printer shows them; otherwise nothing. *)
val show_lams : printer -> lams -> string

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
   dependencies it implements, [deps], and what it needs, from the scheme
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
