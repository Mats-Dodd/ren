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

   Every name has already been resolved (resolve.ml): a local is known by
   its binder's id, and a top-level function by its path, so nothing here
   looks a name up in a scope.

   A type error is reported to the sink (diag.ml), and inference carries
   on. The code with the error gets the type [TError], which unifies with
   everything, so the one mistake isn't reported again wherever its value
   goes.

   The pass is split in three: infer_expr.ml infers expressions,
   infer_top.ml works over the whole module, and infer_msg.ml words the
   errors. *)

let program = Infer_top.program
