(* Identities. Every top-level entity (a type, a function) is named by
   where it lives: its home module, and its name there. Two types called
   `Plan` in different modules are different types, because their paths
   differ. See module-build.md, "Three rules".

   A file is a module, and its home is its path from the entry's folder,
   without the `.ren`: `billing/stripe` for billing/stripe.ren. The entry's
   home is its file's name, `main`, and the prelude's is [prelude]. *)

type t = {
  home : string;  (** the module it's declared in *)
  name : string;  (** its name there *)
}

let prelude_home = "prelude"
let make home name = { home; name }
let prelude name = { home = prelude_home; name }

(* The full way to write [p], which works in any module:
   `billing/invoice.Invoice`. The prelude's names are in scope everywhere,
   so they're written bare. A module writes most types more briefly; see
   Resolve.type_name. *)
let full p = if p.home = prelude_home then p.name else p.home ^ "." ^ p.name

(* The module the entry file is: its name without the folder or the
   `.ren`. *)
let home_of_file file = Filename.remove_extension (Filename.basename file)
