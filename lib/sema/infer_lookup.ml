(* Looking things up for inference (see infer_expr.ml): constructors,
   fields and members found through a type, and the type of a name. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written

(* ---- lookups through a type ----

   Constructors, fields and record literals are found through a type
   (module-build.md, "Found through a type"), in three steps:

   1. if the type is already known at this point, look in its declaration
   2. otherwise, if exactly one visible type has what's being looked for,
      that's the one
   3. otherwise it's an error, which the caller words

   [known] is what step 1 found, if the type was known and has it, and
   [fits] says what a type declaration has. For a constructor, a type that
   is known but doesn't have it falls through to step 2, so the error can
   name both types: `expected a pattern for `Int`, but this one is a
   `Plan``. *)

type 'a lookup = Found of 'a | Nowhere | Several of Path.t list

let through_type env ~known ~fits =
  match known with
  | Some found -> Found found
  | None -> (
      match
        List.filter_map
          (fun (td : Iface.type_decl) ->
            Option.map (fun x -> (td, x)) (fits td))
          env.visible
      with
      | [ (((td : Iface.type_decl), _) as found) ] ->
          if not (List.mem td.path env.in_scope) then
            env.in_scope <- td.path :: env.in_scope;
          Found found
      | [] -> Nowhere
      | several ->
          Several
            (List.map (fun ((td : Iface.type_decl), _) -> td.path) several))

(* The declaration of [t]'s type, if [t] is already known to be a named
   type. In its own module, an opaque type's is its representation's. *)
let known_decl env t =
  match reveal env.st t with
  | TCon (p, _) -> Hashtbl.find_opt env.types p
  | _ -> None

let ctor_in (c : ident) (td : Iface.type_decl) =
  match td.body with
  | Sum cs -> List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) cs
  | Record _ | Builtin | Opaque _ | Errors _ | Dep _ | Handler _ -> None

(* The constructor [c], where a value of type [expected] is wanted. One
   written after its type, `Light.Red`, is looked for there and nowhere
   else; that's how two types that share a constructor's name are told
   apart when nothing else says which. *)
let find_ctor env (c : ctor_ref) ~expected =
  match c.qual with
  | Some { tref = Named p; tloc } -> (
      let td = Hashtbl.find env.types p in
      match ctor_in c.name td with
      | Some k -> Some (td, k)
      | None ->
          report env (not_in_type ~names:env.names tloc c.name td);
          None)
  | Some { tref = Param _; _ } ->
      (* resolve.ml only puts a declared type before a constructor *)
      assert false
  | None -> (
      let c = c.name in
      match known_decl env expected with
      | Some ({ body = Opaque (Hidden _); _ } as td) ->
          (* another module's opaque type has no constructors here *)
          report env (opaque_private c.loc td);
          None
      | Some ({ body = Sum _; _ } as td) when ctor_in c td = None ->
          (* a sum type is expected, so no other type's constructor would
             do *)
          report env (not_in_type ~names:env.names ~expected:true c.loc c td);
          None
      | decl -> (
          let known =
            Option.bind decl (fun td ->
                Option.map (fun k -> (td, k)) (ctor_in c td))
          in
          match through_type env ~known ~fits:(ctor_in c) with
          | Found found -> Some found
          | Nowhere ->
              (* it may be in a type the module can't name bare, which is
                 only looked in when that type is expected *)
              let elsewhere =
                Hashtbl.fold
                  (fun p td acc ->
                    if ctor_in c td <> None then p :: acc else acc)
                  env.types []
                |> List.sort compare
              in
              report env
                (no_ctor ~names:env.names ~can_name:env.can_name c elsewhere);
              None
          | Several owners ->
              report env (ambiguous_ctor ~names:env.names c owners);
              None))

(* Is [c] given as many arguments as it has fields, labelled correctly?
   Each problem is reported. *)
let ctor_shape env loc (c : ident) (ctor : Iface.ctor) labels =
  let given = List.length labels in
  if List.length ctor.cfields <> given then (
    report env (ctor_arity loc c ctor given);
    false)
  else
    let named = List.filter_map Fun.id labels in
    if named = [] then true
    else if List.length named <> given then (
      report env (some_labels loc c);
      false)
    else
      List.fold_left2
        (fun ok (l : ident) (f : Iface.field) ->
          if l.name <> f.fname then (
            report env (wrong_label l f);
            false)
          else ok)
        true named ctor.cfields

(* The fields a value of [td] can be read with, `r.f`: a record's. *)
let record_fields (td : Iface.type_decl) =
  match td.body with
  | Record fs -> Some fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Dep _ | Handler _ -> None

(* The fields a literal of [td] gives, `T { f: ... }`: a record's, or a
   dependency's operations, which an implementation gives (deps.md,
   "Implementations"). An operation isn't read from one: it's called on
   the dependency, where it's installed. *)
let literal_fields (td : Iface.type_decl) =
  match td.body with
  | Record fs | Dep fs -> Some fs
  | Sum _ | Builtin | Opaque _ | Errors _ | Handler _ -> None

(* The operation [name] of the dependency [td], if it's one. *)
let dep_op_in name (td : Iface.type_decl) =
  match td.body with
  | Dep ops -> List.find_opt (fun (o : Iface.field) -> o.fname = name) ops
  | Record _ | Sum _ | Builtin | Opaque _ | Errors _ | Handler _ -> None

let op_in name (td : Iface.type_decl) = Iface.find_member td name

let field_in name (td : Iface.type_decl) =
  Option.bind (record_fields td)
    (List.find_opt (fun (d : Iface.field) -> d.fname = name))

(* What [name] is in the type [p], which has a field or a member of
   that name, for an error: the kind of member, or [None] for a field. *)
let member_kind env name p =
  Option.map
    (fun (o : Iface.op) -> o.okind)
    (op_in name (Hashtbl.find env.types p))

(* The member [name] of [t]'s type, if [t] is already known to be a
   named type that has one. In its own module, an opaque type is also what
   it's represented as, so an item of that type is found too, if the
   opaque type has none of that name. *)
let rec op_of env t name =
  match repr t with
  | TCon (p, args) -> (
      match Hashtbl.find_opt env.types p with
      | None -> None
      | Some td -> (
          match (op_in name td, Hashtbl.find_opt env.st.reps p) with
          | Some o, _ -> Some (td, o)
          | None, Some rep ->
              op_of env
                (of_ty ~vars:(List.nth args)
                   ~tails:(fun _ -> REmpty)
                   ~lams:(fun _ -> fresh_row env.st)
                   rep)
                name
          | None, None -> None))
  | _ -> None

(* Whether a value of type [t] has a member or a field named [name]: a
   dependency's operations are its fields. *)
let has_member env t name =
  op_of env t name <> None
  ||
  match known_decl env t with
  | Some { body = Dep ops; _ } ->
      List.exists (fun (d : Iface.field) -> d.fname = name) ops
  | Some td -> field_in name td <> None
  | None -> false

(* The function a member is: [Stack.push]. *)
let op_path (td : Iface.type_decl) (o : Iface.op) = Path.member td.path o.oname
let sorted names = List.sort String.compare names

(* `r.f`, once [r]'s type [tr] is known: the field is found through it,
   so it has to be known by now, or be the one record type that has a
   field named [f]. A member of [r]'s type isn't a field: a method has to
   be called, and anything else is written after the type. *)
let rec field_access env cx (e : expr) r tr (f : ident) =
  let field_of = field_in f.name in
  match op_of env tr f.name with
  | Some (td, o) ->
      let item = type_name env td.path ^ "." ^ o.oname in
      report env
        (match o.okind with
        | Method ->
            let changes =
              match o.oscheme.ty with
              | Fun ({ mode = Inout; _ } :: _, _, _, _, _) -> true
              | _ -> false
            in
            method_not_called f ~recv:(env.source r) ~item ~changes
        | Function | Value -> item_not_field f o.okind ~item);
      TError
  | None -> (
      let found (td : Iface.type_decl) fd tvars =
        Hashtbl.replace cx.found e.node (Field_of td.path);
        field_type env ~tvars fd
      in
      let needs_record t =
        report env (needs_record f (show (printer env) t));
        TError
      in
      Infer_coerce.settle_for_member env tr ~has:(fun t ->
          has_member env t f.name);
      match reveal env.st tr with
      | TError -> TError
      | TCon (p, args) as t -> (
          let td = Hashtbl.find env.types p in
          (* another module's opaque type, whose fields are hidden *)
          let hidden =
            match td.body with Opaque (Hidden _) -> true | _ -> false
          in
          match (record_fields td, field_of td) with
          | _, Some fd -> found td fd args
          | Some decl, None ->
              report env (no_such_field ~names:env.names f p decl);
              TError
          | None, None when hidden ->
              report env (opaque_private f.loc td);
              TError
          | None, None -> (
              match td.body with
              | Dep ops ->
                  report env (op_of_value ~names:env.names f p ops);
                  TError
              | _ -> needs_record t))
      | TVar _ -> (
          let what =
            match r.kind with
            | Var x -> Some (Infer_msg.Named (name_of x))
            | Call ({ kind = Var (Global p); _ }, _)
              when p <> cx.self && List.mem_assoc p env.group ->
                (* another function of the group, seen only as declared *)
                Some (Group_result (Path.local p))
            | _ -> None
          in
          match through_type env ~known:None ~fits:field_of with
          | Found (td, fd) ->
              let t, tvars = instance env td in
              unify_at env r.loc ~found:tr ~expected:t;
              found td fd tvars
          | Nowhere
            when List.exists (fun td -> op_in f.name td <> None) env.visible
            -> (
              (* not a field, but a member: once [r] is known to have
                 its type, the first case says which kind, and how to use it *)
              match through_type env ~known:None ~fits:(op_in f.name) with
              | Found (td, _) ->
                  let t, _ = instance env td in
                  unify_at env r.loc ~found:tr ~expected:t;
                  field_access env cx e r tr f
              | Nowhere -> TError
              | Several paths ->
                  report env
                    (several_have_member ~names:env.names r.loc ?what f
                       (List.map (fun p -> (p, member_kind env f.name p)) paths));
                  TError)
          | Nowhere ->
              (* it may be in a record type the module can't name bare *)
              let elsewhere =
                Hashtbl.fold
                  (fun p td acc ->
                    if field_of td <> None then p :: acc else acc)
                  env.types []
                |> List.sort compare
              in
              report env
                (no_record_has ~names:env.names ~can_name:env.can_name ?what f
                   elsewhere);
              TError
          | Several paths ->
              report env
                (several_records_have ~names:env.names r.loc ?what f paths);
              TError)
      | t -> needs_record t)

(* ---- names ---- *)

(* Whether calling [p] calls a function of the group being checked whose
   errors are known only once the group is done: one whose declaration
   doesn't say everything about it, or the function being checked. *)
let group_call env p =
  List.mem_assoc p env.group && not (List.mem p env.spelled)

(* The use of [p] at [node], [loc], which put [inst] in place of its
   variables, needs what [p] does of them, whichever of them it is: it's
   decided once the group's types are known (see [Infer_env.required]).
   Its row variables are among them, since they can need something of the
   tags they stand for. *)
let require env cx ~node loc p (inst : subst) =
  let tys = inst.tys and rows = inst.rows in
  if tys <> [] || rows <> [] then (
    let r =
      {
        uname = Path.local p;
        uloc = loc;
        uinst = tys;
        urows = rows;
        uat = [];
        udone = [];
      }
    in
    Hashtbl.replace cx.required node r;
    defer env (Required r))

(* A fresh instance of the scheme of [p], a function of an earlier group
   or another module, or an intrinsic, recording the type arguments it
   picked at [node], [loc]. *)
let fresh env cx ~node loc p =
  let t, s = instantiate env.st (Hashtbl.find env.globals p) in
  Hashtbl.replace cx.targs node
    { tcallee = p; tvalue = false; tpicked = Fresh s };
  (* only a variable that needs something can make the use need it *)
  let needing l = List.filter (fun (id, _) -> needs env.st id <> []) l in
  require env cx ~node loc p
    { s with tys = needing s.tys; rows = needing s.rows };
  t

(* [p], a function of the group being checked, is used at [node] at the
   type [t]. *)
let in_group cx ~node p t =
  Hashtbl.replace cx.targs node
    { tcallee = p; tvalue = false; tpicked = Group t };
  t

(* Fresh variables for the type parameters and named rows of [g], a
   function of the group being checked, by their skolems' ids: what a use
   of it puts in their place (Types.replace). Its declaration says it works
   for any of them, so a function of its group can use it at [Int] and
   another at [Str], as one of a later group could. *)
let own_instance env (g : group_fn) : subst =
  {
    tys = List.map (fun id -> (id, fresh_var env.st)) g.gparams;
    rows = List.map (fun id -> (id, fresh_row env.st)) g.grows;
    lams = [];
  }

(* [t], the type a top-level function, a member, an intrinsic or an
   operation [p] is used at, with [p]'s identity in its lambda set: a
   value of it can be [p], as well as whatever else it meets. *)
let named env p t =
  (match repr t with
  | TFun (_, _, _, _, l) ->
      Unify.unify_lams env.st l
        (extend [ lam (Ty.global_id p) ] (fresh_row env.st))
  | _ -> ());
  t

(* The type of a function of the group being checked, [t], with a lambda
   set of its own, for one use of it: what flows to the use, [named] it,
   isn't what the function's own type says it can be, which nothing in
   its group constrains, so it's generic once the group is done. *)
let own_set env t =
  match repr t with
  | TFun (ps, r, e, u, _) -> TFun (ps, r, e, u, fresh_row env.st)
  | t -> t

(* A name's type, at the expression [node]. A top-level function's is a
   fresh instance of its scheme, so each use can pick its own types;
   another function of the group being checked has the type its
   declaration gives it, with fresh variables for the type parameters and
   rows it names, joined with its real type once the group is done (see
   [join]), unless its declaration is all there is to know. Which
   type arguments a use of a top-level function picked is recorded at
   [node] (see [targs]). *)
let rec lookup env cx ~node loc = function
  | Local b -> Hashtbl.find cx.locals b.id
  | Global_value p -> (
      (* a function of no parameters (ast.ml), whose result is the value *)
      let t = lookup env cx ~node loc (Global p) in
      (* its type arguments are those of the result's type, which a
         function of the group knows only once the group is done *)
      let used = Hashtbl.find cx.targs node in
      let picked =
        match (used.tpicked, repr (Hashtbl.find env.globals p)) with
        | Fresh s, TFun ([], r, _, _, _) -> Fresh (restrict s (generics r))
        | picked, _ -> picked
      in
      Hashtbl.replace cx.targs node
        { used with tvalue = true; tpicked = picked };
      match repr t with TFun ([], t, _, _, _) -> t | _ -> TError)
  | Global p when List.mem p env.spelled ->
      (* its declaration says everything about it, so even in its own body
         it's an instance of that, joined with nothing: a use that closes
         its rows, like storing it as a `fn()`, closes only the instance's *)
      let g = List.assoc p env.group in
      let inst = own_instance env g in
      require env cx ~node loc p inst;
      in_group cx ~node p (named env p (replace inst (g.declared ())))
  | Global p when p <> cx.self && List.mem_assoc p env.group ->
      let g = List.assoc p env.group in
      let jinst = own_instance env g in
      require env cx ~node loc p jinst;
      let used = named env p (replace jinst (g.declared ())) in
      defer env
        (Join { jloc = loc; jname = Path.local p; used; target = p; jinst });
      in_group cx ~node p used
  | Global p when p = cx.self ->
      (* its own type, not generic until its group is done, so the copy
         is the same type, but for its lambda set ([own_set]) *)
      in_group cx ~node p
        (named env p
           (own_set env (fst (instantiate env.st (Hashtbl.find env.globals p)))))
  | Global p -> named env p (fresh env cx ~node loc p)
  | Intrinsic x ->
      let p = Intrinsic.path x in
      named env p (fresh env cx ~node loc p)
  | Dep_op (p, op) -> (
      (* the operation as declared, which uses its dependency: a call
         adds it to the caller's `uses` *)
      match Option.bind (Hashtbl.find_opt env.types p) (dep_op_in op) with
      | Some o -> (
          match field_type env ~tvars:[] o with
          | TFun (ps, ret, errs, _, l) ->
              (* used as a value, it's a lambda that calls it, of its
                 identity (Lower) *)
              named env (Path.member p op)
                (TFun
                   ( ps,
                     ret,
                     errs,
                     RExtend (dep (Ty.dep_label p), fresh_row env.st),
                     l ))
          | _ -> TError)
      | None -> TError)
