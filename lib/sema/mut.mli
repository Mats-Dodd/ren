(* Mutability checks (see mut.ml): what may change, and through which name.
   Every problem is reported to the sink. *)
(* [defer_for] delays only the writable-place check for a [for ... in &p]
   subject until inference distinguishes a data cursor from a block. The
   supplied raw check raises diagnostics for the caller to recover with its
   current sink; omitting the callback performs the check immediately. *)
val program : ?defer_for:(Ast.Resolved.expr -> (unit -> unit) -> unit) -> Diag.sink -> Resolve.t -> unit
