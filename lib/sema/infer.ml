(* Type inference: Hindley–Milner with Rémy-style rows, the system OCaml
   uses.

   Every expression gets a type, and a mismatch is reported before the
   program runs. Private functions need no annotations: inference works out
   their parameter and return types, and generalizes them, so `fn id(x) = x`
   works on any type.

   Every function type also carries two rows (types.ml): the errors it can
   fail with and the dependencies it uses. Each function body has its own
   pair of open rows, and every call adds the callee's rows to the caller's,
   so a function's `uses` is everything the functions it calls use. `print`
   uses `Io`, so `main` does too. Nothing can fail with an error until Stage
   6, so error rows are always empty for now, but they're inferred the same
   way.

   Top-level functions are checked in dependency order: callees before
   callers, with mutually recursive functions checked together (a strongly
   connected component of the call graph). Inside one group every function
   has a single type; the group is generalized once it's done.

   Inference is bidirectional: an expression is checked against the type
   it's expected to have whenever that's known. Constructors, record fields
   and record literals are found through a type, in the three steps of
   module-build.md, and a question that can't be answered where it's asked
   is an error, never put off until later (infer_expr.ml).

   Every name has already been resolved (resolve.ml): a local is known by
   its binder's id, and a top-level function by its path, so nothing here
   looks a name up in a scope.

   A type error is reported to the sink (diag.ml), and inference carries
   on. The code with the error gets the type [TError], which unifies with
   everything, so the one mistake isn't reported again wherever its value
   goes.

   Besides each function's type scheme, inference returns the type of
   every expression and pattern, and what each lookup through a type
   found, so later passes don't have to work it out again: exhaust.ml reads
   which constructor each pattern is.

   The pass is split in three: infer_expr.ml infers expressions,
   infer_top.ml works over the whole module, and infer_msg.ml words the
   errors. *)

(* [type found = Infer_expr.found = ...] re-exports a type along with its
   constructors (or fields), so they can be written [Infer.Field_of] as well
   as [Infer_expr.Field_of]. *)
type found = Infer_expr.found =
  | Field_of of Path.t
  | Ctor_of of Path.t * string

module Nodes = Infer_top.Nodes

type node = Infer_top.node = { ty : Ty.ty; found : found option }

type t = Infer_top.t = {
  schemes : (string * Ty.scheme) list;
  nodes : (string * node Nodes.t) list;
  in_scope : Path.t list;
}

let program = Infer_top.program
