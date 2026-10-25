(* Values, as `show`, `print`, a failed `assert` and an error nothing
   handled show them.

   A value is shown as it's written, with the names of the types it's
   made of: a record after its type's name, `Account { id: AccountId(1)
   }`, and an opaque value as its type's name around what it is,
   `Money(-100)`, unless its type has a `show` method of its own, `Path`'s,
   which is used instead. At runtime an opaque value is only what it's
   represented as, so a value is shown through its type, and each type's
   declaration, by its path. *)

(* Every type's declaration, by its path. *)
type types = (Path.t, Iface.type_decl) Hashtbl.t

let types (decls : Iface.type_decl list) : types =
  let t = Hashtbl.create 64 in
  List.iter (fun (d : Iface.type_decl) -> Hashtbl.replace t d.path d) decls;
  t

(* [t] with each of its type's parameters, [Var i], replaced by [args]'s
   [i]th. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst args p.ty }) ps,
          subst args r,
          e,
          u )
  | Errors _ | Uses _ | Error -> t

(* How a type shows its values: as its own `show` method made [v] look,
   [Itself], or as it's declared. [Inside] is inside that method, where
   an opaque value is shown as only what it's represented as, so that
   `show(self)` there doesn't call the method again. *)
type own = Itself of string | Inside | Declared

(* [v], a value of type [t]. [own p args v] says how the type [p], given
   [args], shows [v] (eval.ml). *)
let rec value ~own (types : types) (t : Ty.ty) (v : Value.t) =
  let value = value ~own types in
  let list xs = String.concat ", " xs in
  match (t, v) with
  | Con (p, [ elem ]), VArray xs when p = Path.prelude "Array" ->
      "[" ^ list (Array.to_list (Array.map (value elem) xs)) ^ "]"
  | Con (p, args), _ -> (
      match own p args v with
      | Itself s -> s
      | how -> (
          let d = Hashtbl.find_opt types p in
          match (Option.map (fun (d : Iface.type_decl) -> d.body) d, v) with
          | Some (Record fields), VRecord vs ->
              (* the fields in the order they're declared *)
              p.name ^ " { "
              ^ list
                  (List.map
                     (fun (f : Iface.field) ->
                       f.fname ^ ": "
                       ^ value (subst args f.fty) (List.assoc f.fname vs))
                     fields)
              ^ " }"
          | Some (Sum ctors), VCon c -> (
              match
                List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) ctors
              with
              | Some k
                when k.cfields <> []
                     && List.length k.cfields = List.length c.args ->
                  c.name ^ "("
                  ^ list
                      (List.map2
                         (fun (f : Iface.field) a -> value (subst args f.fty) a)
                         k.cfields c.args)
                  ^ ")"
              | _ -> Value.show v)
          | Some (Opaque (Some rep)), _ when how = Inside ->
              value (subst args rep) v
          | Some (Opaque (Some rep)), _ ->
              p.name ^ "(" ^ value (subst args rep) v ^ ")"
          | Some (Opaque None), _ -> p.name ^ "(" ^ Value.show v ^ ")"
          | _ -> Value.show v))
  | Errors row, VTag { name; args } -> (
      (* an error, through its tag's payload's types in the set *)
      match List.find_opt (fun (l : Ty.label) -> l.name = name) row.labels with
      | Some l when l.payload <> [] && List.length l.payload = List.length args
        ->
          name ^ "(" ^ list (List.map2 value l.payload args) ^ ")"
      | _ -> Value.show v)
  | _ -> Value.show v

(* What `show` makes of [v]: a string is itself, and anything else, a
   string inside it included, is shown as it's written. *)
let shown ~own types (t : Ty.ty) (v : Value.t) =
  match (t, v) with
  | Con (p, []), VStr s when p = Path.prelude "Str" -> s
  | (Var _ | Error), VStr s -> s
  | _ -> value ~own types t v
