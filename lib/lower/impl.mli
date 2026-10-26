(* The implementation tier of a module's summary (module-build.md,
   "Interface summaries"; see impl.ml): what the modules that import it
   will need of it to generate code, where its interface (iface.ml) is
   what they need to be type checked. Nothing reads it yet: the
   specializer will (compiler.md, "Specialization"). *)

type t = {
  home : string;  (** the module this is the implementation tier of *)
  bodies : Core.fn_def Path.Map.t;
      (** the typed Core of each of its public functions, and its public types'
          member functions, that's generic or higher-order: that has a type
          variable, or a parameter or result with a function in it. By path, and
          with no source locations in it, so it changes only when one of those
          functions does *)
}

(* The implementation tier of the module lowered to this Core, whose
   interface is this. *)
val of_module : Iface.t -> Core.program -> t

(* Each recorded body, in the order of its path, as [Core.show_fn] prints
   it typed, for tests. *)
val show : t -> string
