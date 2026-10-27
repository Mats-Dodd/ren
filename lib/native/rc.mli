(* Perceus over Mem IR (see rc.ml): the counting placed precisely, after
   Koka's Parc.hs and Lean's ExplicitRC.lean. *)

(* The program with its counting erased and put in the shape Perceus
   sees through: each `match` arm only one test reaches moved to it, and
   the array changes made the ones that take the array. *)
val prepare : Mem.program -> Mem.program

(* The prepared program with its counting placed, by its functions'
   parameters' modes, which borrow.ml decided. *)
val program : Mem.program -> Mem.program

(* Whether a function's body consumes a parameter of it, by its callees'
   modes, by name: borrow.ml's step. *)
val consumed : (string, Mem.fn) Hashtbl.t -> Mem.fn -> Mem.var -> bool

(* Walking Mem IR, for the passes after it. *)

(* Every statement of a block and the blocks in it, in order. *)
val iter_stmts : (Mem.stmt -> unit) -> Mem.block -> unit

(* A statement with each block in it changed. *)
val map_blocks : (Mem.block -> Mem.block) -> Mem.stmt -> Mem.stmt

(* What a statement reads itself, not in its blocks. *)
val stmt_atoms : Mem.stmt -> Mem.atom list

(* Whether control never goes on after a statement. *)
val ends : Mem.stmt -> bool

(* The next fresh variable id and label of a function. *)
val fresh_counters : Mem.fn -> int ref * int ref
