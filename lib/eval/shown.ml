(* Values, as a test or a failed `assert` shows them.

   A value is shown as it's written, with the names of the types it's
   made of: a record after its type's name, `Account { id: AccountId(1)
   }`, and an opaque value as its type's name around what it is,
   `Money(-100)`, which `show` can't do, since at runtime it's only what
   it's represented as. So a value is shown through its type, and each
   type's declaration, by its path. `ren test` and `ren run` show the
   sides of a failed `assert a == b` this way, so they read the same in
   both. *)

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

(* [v], a value of type [t]. *)
let rec value (types : types) (t : Ty.ty) (v : Value.t) =
  let list xs = String.concat ", " xs in
  match (t, v) with
  | Con (p, [ elem ]), VArray xs when p = Path.prelude "Array" ->
      "[" ^ list (Array.to_list (Array.map (value types elem) xs)) ^ "]"
  | Con (p, args), _ -> (
      let d = Hashtbl.find_opt types p in
      match (Option.map (fun (d : Iface.type_decl) -> d.body) d, v) with
      | Some (Record fields), VRecord vs ->
          (* the fields in the order they're declared *)
          p.name ^ " { "
          ^ list
              (List.map
                 (fun (f : Iface.field) ->
                   f.fname ^ ": "
                   ^ value types (subst args f.fty) (List.assoc f.fname vs))
                 fields)
          ^ " }"
      | Some (Sum ctors), VCon c -> (
          match
            List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) ctors
          with
          | Some k
            when k.cfields <> [] && List.length k.cfields = List.length c.args
            ->
              c.name ^ "("
              ^ list
                  (List.map2
                     (fun (f : Iface.field) a ->
                       value types (subst args f.fty) a)
                     k.cfields c.args)
              ^ ")"
          | _ -> Value.show v)
      | Some (Opaque (Some rep)), _ ->
          p.name ^ "(" ^ value types (subst args rep) v ^ ")"
      | Some (Opaque None), _ -> p.name ^ "(" ^ Value.show v ^ ")"
      | _ -> Value.show v)
  | _ -> Value.show v
