(* Identities. Every top-level entity (a type, a function) is named by
   where it lives: its home module, and its name there. Two types called
   `Plan` in different modules are different types, because their paths
   differ. See module-build.md, "Three rules".

   A file is a module, and its home is its path from the entry's folder,
   without the `.ren`: `billing/stripe` for billing/stripe.ren. The entry's
   home is its file's name, `main`, and the prelude's is [prelude].

   A type's member, `Stack.push`, is named by its type's path and which
   member it is. It's a path too, rather than a kind of name of its own,
   because everything that names a top-level function (a call, a scheme,
   a function in Core) names a member the same way: what tells the two
   apart is only [member]. *)

type t = {
  home : string;  (** the module it's declared in *)
  name : string;  (** its name there; a member's type's name *)
  member : member option;  (** which of that type's members it is, if one *)
}

and member = {
  mname : string;  (** as it's written: [push] *)
  overload : int;
      (** which of the members of that name, counting from 0 in source order: an
          operator has one per type on its right (operators.md), all with one
          name, and anything else only 0 *)
}

let prelude_home = "prelude"
let make home name = { home; name; member = None }
let prelude name = make prelude_home name

(* The member [m] of the type [owner], the [n]th of that name. *)
let member_n owner m n =
  { owner with member = Some { mname = m; overload = n } }

(* The member [m] of the type [owner]: the first of that name, and for
   anything but an operator, the only one. *)
let member owner m = member_n owner m 0

(* Which of its type's members of its name [p] is. *)
let overload p = match p.member with Some m -> m.overload | None -> 0

(* The type a member is of; a path that isn't a member's is its own. *)
let owner p = { p with member = None }

(* A member's name as it's written, [push] for `Stack.push`; a path that
   isn't a member's has its [name]. *)
let short p = match p.member with Some m -> m.mname | None -> p.name

(* How [p] is written in its own module: `Stack.push` for a member, after
   its type's name. *)
let local p =
  match p.member with Some m -> p.name ^ "." ^ m.mname | None -> p.name

(* The full way to write [p], which works in any module:
   `billing/invoice.Invoice`. The prelude's names are in scope everywhere,
   so they're written bare. A module writes most types more briefly; see
   Resolve.type_name. *)
let full p = if p.home = prelude_home then local p else p.home ^ "." ^ local p

(* The module the entry file is: its name without the folder or the
   `.ren`. *)
let home_of_file file = Filename.remove_extension (Filename.basename file)

(* Maps keyed by path. Paths compare as records do, field by field, so a
   map's order is fixed: by home, then name, then member. *)
module Map = Map.Make (struct
  type nonrec t = t

  let compare = compare
end)
