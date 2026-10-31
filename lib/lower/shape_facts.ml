(* Declaration facts shared by type inspection and template sites. Recursive
   edges retain their qualified type name rather than expanding forever. *)
open Core

let path n = Path.make "shape" n
let ty n = Ty.Con (path n, [])
let data cty ckind = { cty; ckind }
let str s = data Ty.str (CStr s)
let bool b = data Ty.bool (CBool b)
let int n = data Ty.int (CInt (Int64.of_int n))
let array t xs = data (Ty.Con (Path.prelude "Array", [t])) (CArray xs)
let con n c xs = data (ty n) (CCon (path n, c, xs))
let record n xs = data (ty n) (CRecord xs)
let none t = data (Ty.Con (Path.prelude "Option", [t]))
    (CCon (Path.prelude "Option", "None", []))
let some t x = data (Ty.Con (Path.prelude "Option", [t]))
    (CCon (Path.prelude "Option", "Some", [x]))

let rec value c =
  let make name xs = con "Value" name xs in
  match c.ckind with
  | CBool _ -> make "Bool" [c]
  | CInt _ -> make "Int" [c]
  | CFloat _ -> make "Float" [c]
  | CStr _ -> make "Text" [c]
  | CBytes _ -> make "Bytes" [c]
  | CUnit -> make "None" []
  | CArray xs | CTuple xs | CSet xs ->
      make "List" [array (ty "Value") (List.map value xs)]
  | CRecord fs ->
      let pair (n, v) = data (Ty.tuple [Ty.str; ty "Value"])
          (CTuple [str n; value v]) in
      make "Fields" [array (Ty.tuple [Ty.str; ty "Value"]) (List.map pair fs)]
  | CMap xs ->
      let pair (k, v) = data (Ty.tuple [ty "Value"; ty "Value"])
          (CTuple [value k; value v]) in
      make "Map" [array (Ty.tuple [ty "Value"; ty "Value"]) (List.map pair xs)]
  | CCon (_, "None", []) -> make "None" []
  | CCon (_, "Some", [x]) -> value x
  | CCon (_, name, xs) | CTag (name, xs) ->
      make "Case" [make "Text" [str name];
        make "List" [array (ty "Value") (List.map value xs)]]
  | CHandler _ -> invalid_arg "a handler description has no data shape"

let literal t = function
  | Ast.LInt n -> data t (CInt n)
  | LFloat f -> data t (CFloat f)
  | LBool b -> data t (CBool b)
  | LStr s -> data t (CStr s)
  | LCtor c ->
      let p = match c.csum, t with Some p, _ -> p | _, Ty.Con (p, _) -> p
        | _ -> invalid_arg "unresolved default constructor" in
      data t (CCon (p, c.cname.name, []))

let type_name t =
  let scheme = { Ty.ty = t; tparams = []; names = []; reqs = []; row_reqs = [];
    modes = []; defaults = [] } in
  Ty.show (Ty.printer ~names:Path.full scheme) t

let shape ?(default = fun _ _ -> None) ~types ~home target =
  let rec walk seen t =
    let make c xs = con "Shape" c xs in
    let ref_ () = make "Ref" [str (type_name t)] in
    let fields seen owner args fs =
      List.map (fun (f : Iface.field) ->
        let ft = Walk.subst args f.fty in
        let d = match f.fdefault_member, f.fdefault with
          | Some (Iface.Value_default p | Function_default p), _ -> default p args
          | None, Some l -> Some (literal ft l)
          | _ -> None in
        record "Field" ["name", str f.fname;
          "of", str (Path.full owner ^ "." ^ f.fname); "exact", bool false;
          "shape", walk seen ft;
          "default", (match d with None -> none (ty "Value")
            | Some d -> some (ty "Value") (value d)); "doc", str ""]) fs
    in
    match t with
    | Ty.Con (p, args) | Variant (p, _, args) ->
        if List.mem t seen then ref_ () else
        let seen = t :: seen in
        let builtin name = p = Path.prelude name in
        if List.exists builtin ["Unit"; "Bool"; "Int"; "Float"; "Str"; "Bytes"] then
          make p.name []
        else if Ty.is_tuple p then make "Tuple" [array (ty "Shape") (List.map (walk seen) args)]
        else if List.exists builtin ["Array"; "Set"; "Option"] then
          (match args with [x] -> make p.name [walk seen x] | _ -> ref_ ())
        else if builtin "Map" then
          (match args with [k; v] -> make "Map" [walk seen k; walk seen v] | _ -> ref_ ())
        else if Option.is_some (Sized.of_path p) then
          let k = Option.get (Sized.of_path p) in
          if Sized.is_float k then make "Float32" []
          else make (if String.starts_with ~prefix:"UInt" p.name then "Unsigned" else "Signed")
            [int (Sized.bits k)]
        else (match Hashtbl.find_opt types p with
          | None -> ref_ ()
          | Some d when d.Iface.opaque && p.home <> home -> ref_ ()
          | Some d ->
              match d.Iface.body with
              | Record fs -> make "Record" [str (type_name t);
                  array (ty "Field") (fields seen p args fs); str ""]
              | Sum cs ->
                  let cases = List.map (fun (c : Iface.ctor) ->
                    record "Case" ["name", str c.cname;
                      "tag", con "Value" "Text" [str c.cname];
                      "holes", array Ty.str [];
                      "fields", array (ty "Field") (fields seen p args c.cfields);
                      "positional", bool (not c.cnamed); "doc", str ""]) cs in
                  make "Sum" [str (type_name t); array (ty "Case") cases; str ""]
              | Opaque (Rep rep) -> walk seen (Walk.subst args rep)
              | Dep fs ->
                  let ops = List.map (fun (f : Iface.field) ->
                    match Walk.subst args f.fty with
                    | Ty.Fun (ps, r, errors, _) ->
                        let params = List.mapi (fun i (param : Ty.param) ->
                          let name = string_of_int i in
                          record "Field" ["name", str name; "of", str (Path.full p ^ "." ^ f.fname ^ "." ^ name);
                            "exact", bool false; "shape", walk seen param.ty;
                            "default", none (ty "Value"); "doc", str ""]) ps in
                        let errs = List.map (fun (e : Ty.label) ->
                          record "Case" ["name", str e.name;
                            "tag", con "Value" "Text" [str e.name]; "holes", array Ty.str [];
                            "fields", array (ty "Field") []; "positional", bool true; "doc", str ""]) errors.labels in
                        record "DepOperation" ["name", str f.fname;
                          "params", array (ty "Field") params; "result", walk seen r;
                          "errors", array (ty "Case") errs; "doc", str ""]
                    | _ -> invalid_arg "dependency operation is not a function") fs in
                  make "Dependency" [str (Path.full p); array (ty "DepOperation") ops; str ""]
              | Dep_alias dep -> walk seen (Ty.Con (dep.dpath, dep.dargs))
              | Builtin | Opaque (Hidden _) | Errors _ -> ref_ ())
    | Ty.Var _ -> invalid_arg "shape requires a resolved descriptor"
    | Fun _ | Impl _ | Errors _ | Error -> invalid_arg "this type has no data shape"
  in
  walk [] target
