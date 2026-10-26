(* The prelude (see prelude.ml): what every program can use without
   declaring it. *)

(* The part written in Ren, which the driver checks like any module, and
   the file it's said to be in. *)
val source : string
val file : string

(* A built-in function's type scheme. *)
val scheme : Intrinsic.t -> Ty.scheme

(* Whether it reaches the world: only the prelude's source can call it. *)
val runtime : Intrinsic.t -> bool

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : Intrinsic.t list;  (** its built-in methods: [Array]'s [push] *)
  functions : Intrinsic.t list;
      (** its built-in associated functions: [Str]'s [from_utf8] *)
}

val types : builtin_type list

(* The built-in dependencies the runtime installs around `main`: [Clock],
   [Random], [Console], [Fs], [Os] and [Proc]. Each one's real
   implementation is its private associated value [real]. *)
val runtime_deps : string list

(* The dependencies a `uses` can name that aren't declared yet: [Net], ... *)
val dependencies : string list

(* The built-in functions that aren't a type's members. *)
val fns : Intrinsic.t list

(* A built-in function by its path: [show], or a built-in type's member,
   [Array.push]. *)
val find : Path.t -> Intrinsic.t option

(* The interface of the built-in half: the built-in types and functions, as
   [source] sees them. *)
val intrinsics : Iface.t

(* The same, as every other module sees it, without the functions that
   reach the world. The driver joins it to the interface of [source]. *)
val public : Iface.t
