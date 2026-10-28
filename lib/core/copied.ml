(* Whether a value of a type is copied, rather than counted: one fact,
   which exclusivity (excl.ml) uses to decide that reading one is an
   instant, and the native backend (to_mem.ml) to decide that a release
   build keeps one as a C struct, passed by value and inline in an
   array, not as a counted object. *)

(* [t] with the type arguments [args] put in for its declaration's
   parameters, [Var 0] the first. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> Option.value (List.nth_opt args i) ~default:t
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | Fun _ | Errors _ | Impl _ | Error -> t

(* Whether a value of type [t] is copied: a number, a sized one, a `Bool`
   or `Unit`, or a record, tuple or enum made only of those. [types] finds a type's
   declaration. [seen] are the types it's inside, so a recursive type,
   which has to be counted, ends the search. A type whose representation
   is hidden is counted, unless it's a number type. *)
let rec is ~(types : Path.t -> Iface.type_decl option) ?(seen = []) (t : Ty.ty)
    =
  match t with
  | _ when List.mem t [ Ty.int; Ty.float; Ty.bool; Ty.unit ] -> true
  | _ when Sized.of_ty t <> None -> true
  | Con (p, args) when Ty.is_tuple p -> List.for_all (is ~types ~seen) args
  | Con (p, args) -> (
      if List.mem t seen || List.length seen > 16 then false
      else
        let seen = t :: seen in
        let all tys =
          List.for_all (fun t -> is ~types ~seen (subst args t)) tys
        in
        let fields (fs : Iface.field list) =
          List.map (fun f -> f.Iface.fty) fs
        in
        match types p with
        | None -> false
        | Some td -> (
            match td.body with
            | Builtin -> List.mem t [ Ty.int; Ty.float; Ty.bool; Ty.unit ]
            | Record fs -> all (fields fs)
            | Sum cs ->
                all
                  (List.concat_map
                     (fun (c : Iface.ctor) -> fields c.cfields)
                     cs)
            | Opaque (Rep r) -> all [ r ]
            | Opaque (Hidden _) -> td.numeric <> None
            | Errors _ | Dep _ -> false))
  | Error -> true
  | Fun _ | Var _ | Errors _ | Impl _ -> false
