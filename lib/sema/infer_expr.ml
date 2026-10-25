(* Inferring the types of expressions (see infer.ml for the whole pass).

   Inference is bidirectional (module-build.md, "In the compiler"). [infer]
   works out an expression's type from the expression alone. [check] also
   knows the type the expression is expected to have, and passes it down to
   where it helps: into a block's last line, an `if`'s branches and a
   `match`'s arms, to a lambda, which takes its parameters' types from it,
   and to a constructor or record literal, which is found through it. A
   call's arguments are checked left to right against the callee's
   parameter types, so what one argument settles is known to the next.

   Constructors, record fields and record literals without a type name are
   all found through a type, by one lookup ([through_type]) in the three
   steps of module-build.md. Nothing waits: a question that can't be
   answered where it's asked is an error that says which annotation would
   answer it, so the result never depends on the order inference happens to
   learn things in.

   As it goes, inference records every expression's and pattern's type by
   its node id, and what each lookup found. infer_top.ml hands the table on
   in canonical form, for the passes after it. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg

(* What a lookup through a type found. *)
type found =
  | Field_of of Path.t  (** a field access: the record type the field is in *)
  | Ctor_of of Path.t * string  (** a constructor: its type, and its name *)

type env = {
  st : Types.state;
  sink : Diag.sink;
  home : string;  (** the module being checked *)
  names : Path.t -> string;
      (** how the module writes each type's name (Resolve.type_name) *)
  types : (Path.t, Iface.type_decl) Hashtbl.t;
      (** every type the module can meet: its own, and the public types of every
          module reachable through its imports (iface.ml) *)
  visible : Iface.type_decl list;
      (** the types it can name bare, sorted by name, which is the order an
          error lists them in: its own, those imported by name, and the
          prelude's *)
  globals : (Path.t, ty) Hashtbl.t;
      (** top-level functions: a type scheme once their group is done *)
  mutable group : (Path.t * (unit -> ty)) list;
      (** the functions of the group being checked, each with a way to make the
          type its declaration gives it *)
  mutable joins : join list;  (** most recent first *)
}

(* A use of another function of the group being checked. While the group's
   bodies are being checked, each one sees the others only as their
   declarations describe them, so no body learns anything from another
   body of its group, and checking them in another order would find the
   same. Once every body is checked, each use is joined with the type that
   function's own body gave it. *)
and join = { jloc : Loc.t; jname : string; used : ty; target : Path.t }

(* What the expression being inferred can see. *)
type ctx = {
  self : Path.t;  (** the top-level function being checked *)
  locals : (int, ty) Hashtbl.t;
      (** the type of each local of the top-level function, by binder id *)
  nodes : (int, ty) Hashtbl.t;
      (** the type of each expression and pattern of the function, by node id *)
  found : (int, found) Hashtbl.t;  (** what each lookup found, by node id *)
  errs : row;  (** the errors of the innermost function or lambda *)
  uses : row;  (** the dependencies of the innermost function or lambda *)
  tparams : ty list;  (** what the type parameters in scope stand for *)
}

(* ---- reporting ---- *)

let printer env = Types.printer ~names:env.names env.st
let type_name env p = env.names p

(* A name as it's written, for messages. *)
let name_of = function
  | Local b -> b.ident.name
  | Global p -> p.name
  | Intrinsic x -> x

let report env d = Diag.report env.sink d

(* Report an error, and carry on: the code it's about has type [TError]. *)
let fail env ?help ?notes ?labels loc msg =
  report env (Diag.make ?help ?notes ?labels loc msg);
  TError

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_loc (e : expr) =
  match e.kind with Block (_, last) -> result_loc last | _ -> e.loc

(* How to explain a mismatch with an expected type, passed down along with
   it: [msg] words the error, [help] suggests a fix and [labels] point at
   other code, each given both types printed (the one found, then the one
   expected); [notes] say where the expectation comes from. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
}

let explain ?msg ?(notes = []) ?help ?(labels = fun _ _ -> []) () =
  { msg; notes; help; labels }

let plain = explain ()

(* Unify [found] (what the code has) with [expected] (what it needs), and
   say whether that worked. *)
let unifies env why loc ~found ~expected =
  match Unify.unify env.st found expected with
  | () -> true
  | exception Unify.Mismatch ->
      let pr = printer env in
      let f = show pr found and x = show pr expected in
      let msg =
        match why.msg with
        | Some m -> m f x
        | None -> sprintf "expected `%s`, found `%s`" x f
      in
      let help = Option.map (fun h -> h f x) why.help in
      let more, help = mismatch_notes ?help ~found ~expected () in
      ignore
        (fail env ?help ~notes:(why.notes @ more) ~labels:(why.labels f x) loc
           msg);
      false
  | exception Unify.Infinite ->
      let pr = printer env in
      ignore
        (fail env loc
           ~notes:
             [
               sprintf "it would have to be `%s` and `%s` at the same time"
                 (show pr expected) (show pr found);
             ]
           "this value's type would have to contain itself");
      false

let unify_at env ?msg ?notes ?help ?labels loc ~found ~expected =
  let help = Option.map (fun h _ _ -> h) help in
  ignore
    (unifies env (explain ?msg ?notes ?help ?labels ()) loc ~found ~expected)

(* ---- types as written ---- *)

(* Turn a written type into a checker type. [tvars] are what the type
   parameters in scope stand for, in order. [row] makes the rows of written
   function types: fresh variables in parameters (a parameter `f: fn()`
   passes its dependencies through to the caller), closed in declarations
   and return types (a stored `fn()` uses nothing). *)
let rec convert ~tvars ~row (t : Resolved.ty) =
  match t with
  | TyName ({ tref = Param i; _ }, _) -> List.nth tvars i
  | TyName ({ tref = Named p; _ }, args) ->
      TCon (p, List.map (convert ~tvars ~row) args)
  | TyFn (ps, ret, _) ->
      let ret =
        match ret with Some r -> convert ~tvars ~row r | None -> unit
      in
      TFun (List.map (convert_param ~tvars ~row) ps, ret, row (), row ())
  | TyInout _ ->
      (* the parser only writes `inout` on a function type's parameter *)
      assert false

and convert_param ~tvars ~row = function
  | TyInout (t, _) -> { mode = Inout; ty = convert ~tvars ~row t }
  | t -> read (convert ~tvars ~row t)

let closed () = REmpty

(* A parameter's type: as written, or a fresh variable. [own] are the
   errors and dependencies of the top-level function the parameter belongs
   to. A parameter written `fn(...)` is transparent: what it fails with and
   uses is exactly what its function does, so that's its rows.

   A top-level function's signature is read exactly as its interface reads
   it (Iface.signature), so the body is checked against the type other
   modules will see: any other function type in its parameters, like the
   `fn()` in `f: fn(fn()) -> Int` or in `f: Option<fn()>`, is closed, as it
   is in a declaration. With open rows there, the body could widen them, and
   its type would no longer be the one its signature states. A lambda's
   parameters, which no interface shows, get fresh rows instead. *)
let param_type env ~tparams ?own (p : Resolved.param) =
  let t =
    match (p.pty, own) with
    | Some (TyFn _ as t), Some (errs, uses) -> (
        match convert ~tvars:tparams ~row:closed t with
        | TFun (ps, ret, _, _) -> TFun (ps, ret, errs, uses)
        | _ -> assert false)
    | Some t, Some _ -> convert ~tvars:tparams ~row:closed t
    | Some t, None -> convert ~tvars:tparams ~row:(fun () -> fresh_row env.st) t
    | None, _ -> fresh_var env.st
  in
  { mode = p.pmode; ty = t }

(* Fresh variables for a type declaration's parameters: `Option<T>` used
   once can be an `Option<Int>`, and elsewhere an `Option<Bool>`. *)
let instance env (td : Iface.type_decl) =
  let tvars = List.map (fun _ -> fresh_var env.st) td.params in
  (TCon (td.path, tvars), tvars)

(* A field's type, given what the type's parameters stand for. A function
   type written in a declaration uses and fails with nothing. *)
let field_type ~tvars (f : Iface.field) =
  of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty) f.fty

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
      | [ found ] -> Found found
      | [] -> Nowhere
      | several ->
          Several
            (List.map (fun ((td : Iface.type_decl), _) -> td.path) several))

(* The declaration of [t]'s type, if [t] is already known to be a named
   type. *)
let known_decl env t =
  match repr t with TCon (p, _) -> Hashtbl.find_opt env.types p | _ -> None

let ctor_in (c : ident) (td : Iface.type_decl) =
  match td.body with
  | Sum cs -> List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) cs
  | Record _ | Builtin -> None

(* The constructor [c], where a value of type [expected] is wanted. *)
let find_ctor env (c : ident) ~expected =
  let known =
    Option.bind (known_decl env expected) (fun td ->
        Option.map (fun k -> (td, k)) (ctor_in c td))
  in
  match through_type env ~known ~fits:(ctor_in c) with
  | Found found -> Some found
  | Nowhere ->
      report env (no_ctor c);
      None
  | Several owners ->
      report env (ambiguous_ctor ~names:env.names c owners);
      None

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

let record_fields (td : Iface.type_decl) =
  match td.body with Record fs -> Some fs | Sum _ | Builtin -> None

let sorted names = List.sort String.compare names

(* ---- expressions ---- *)

(* A name's type. A top-level function's is a fresh instance of its
   scheme, so each use can pick its own types; another function of the
   group being checked has the type its declaration gives it, joined with
   its real type once the group is done (see [join]). *)
let lookup env cx loc = function
  | Local b -> Hashtbl.find cx.locals b.id
  | Global p when p <> cx.self && List.mem_assoc p env.group ->
      let used = (List.assoc p env.group) () in
      env.joins <- { jloc = loc; jname = p.name; used; target = p } :: env.joins;
      used
  | Global p -> instantiate env.st (Hashtbl.find env.globals p)
  | Intrinsic x ->
      instantiate env.st (Hashtbl.find env.globals (Path.prelude x))

let want_int env op (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int
    ~notes:[ sprintf "`%s` works on `Int`s" op ]

let want_bool env what (e : expr) t =
  unify_at env e.loc ~found:t ~expected:bool
    ~notes:[ sprintf "%s has to be a `Bool`" what ]

(* A call adds the callee's errors and dependencies to the caller's. An
   open row is unified with the caller's, which is how its tail picks up
   everything the caller does. A closed one, like a stored `fn()`'s, says
   only what the callee itself does: unified as it is, it would close the
   caller's row too, and then nothing else the caller calls could fail or
   use anything. So it's opened first, with a fresh tail. *)
let absorb env cx loc errs uses =
  let rec reopen r =
    match repr_row r with
    | REmpty -> fresh_row env.st
    | RExtend (l, rest) -> RExtend (l, reopen rest)
    | r -> r
  in
  try
    Unify.unify_row env.st (reopen errs) cx.errs;
    Unify.unify_row env.st (reopen uses) cx.uses
  with Unify.Mismatch | Unify.Infinite ->
    let pr = printer env in
    ignore
      (fail env loc
         (sprintf "this call%s, which isn't allowed here"
            (show_effects pr errs uses)))

(* Inside the function, an `inout` parameter is an ordinary variable. *)
let bind_params cx params ps =
  List.iter2
    (fun (p : Resolved.param) (t : Types.param) ->
      Hashtbl.replace cx.locals p.pname.id t.ty)
    params ps

(* [e]'s type, from [e] alone. *)
let rec infer env cx (e : expr) : ty =
  let t = synth env cx e in
  Hashtbl.replace cx.nodes e.node t;
  t

(* Check [e] against [expected], explaining a mismatch with [why]. When
   nothing is known about [expected] yet, that's inferring [e] and unifying
   the two. *)
and check env cx ?(why = plain) (e : expr) expected =
  let leaf () =
    let t = synth env cx e in
    Hashtbl.replace cx.nodes e.node t;
    ignore (unifies env why (result_loc e) ~found:t ~expected)
  in
  let fits () = Hashtbl.replace cx.nodes e.node expected in
  match (e.kind, repr expected) with
  | _, TVar _ -> leaf ()
  | Block (stmts, last), _ ->
      fits ();
      List.iter (stmt env cx) stmts;
      check env cx ~why last expected
  | If (c, t, Some f), _ ->
      fits ();
      want_bool env "an `if` condition" c (infer env cx c);
      check env cx ~why t expected;
      check env cx ~why f expected
  | Match (subject, arms), _ ->
      fits ();
      ignore (infer_match env cx subject arms ~want:(Some (expected, why)))
  | Lambda (params, body), TFun (eps, eret, _, _)
    when List.length eps = List.length params
         && List.for_all2
              (fun (p : Resolved.param) (ep : Types.param) -> p.pmode = ep.mode)
              params eps ->
      (* the parameters take their types from where the lambda is going,
         unless they're written; the whole type is unified with the expected
         one at the end, which also checks what the body fails with and
         uses *)
      let ps =
        List.map2
          (fun (p : Resolved.param) ep ->
            if p.pty = None then ep else param_type env ~tparams:cx.tparams p)
          params eps
      in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      bind_params cx params ps;
      check env { cx with errs; uses } body eret
        ~why:
          (explain ~notes:why.notes
             ~msg:(fun f x ->
               sprintf "this lambda produces %s, but it has to produce %s"
                 (article f) (article x))
             ());
      let t = TFun (ps, eret, errs, uses) in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Con (c, args), _ ->
      let t = infer_con env cx e c args ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Record (None, fields), _ ->
      let t = infer_record env cx e None fields ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Array xs, TCon (p, [ elem ]) when p = Path.prelude "Array" ->
      fits ();
      List.iter
        (fun x -> check env cx ~why:{ plain with notes = why.notes } x elem)
        xs
  | _ -> leaf ()

(* The type of [e], not yet recorded. *)
and synth env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Bool _ -> bool
  | Unit -> unit
  | Var x -> lookup env cx e.loc x
  | Unop (Neg, a) ->
      want_int env "-" a (infer env cx a);
      int
  | Binop (op, a, b) -> (
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod | Lt | Le | Gt | Ge ->
          let ta = infer env cx a in
          let tb = infer env cx b in
          want_int env name a ta;
          want_int env name b tb;
          if List.mem op [ Lt; Le; Gt; Ge ] then bool else int
      | Eq | Neq ->
          (* the left side says what the right side has to be *)
          let ta = infer env cx a in
          check env cx b ta
            ~why:
              (explain
                 ~msg:(fun f x ->
                   sprintf
                     "`%s` compares two values of the same type, but this is \
                      %s and the left side is %s"
                     name (article f) (article x))
                 ~labels:(fun _ x ->
                   [ (a.loc, sprintf "this is %s" (article x)) ])
                 ());
          bool)
  | If (c, t, Some f) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let tt = infer env cx t in
      check env cx f tt
        ~why:
          (explain
             ~msg:(fun f x ->
               sprintf "this `else` branch is %s, but the `then` branch is %s"
                 (article f) (article x))
             ~labels:(fun _ x ->
               [ (result_loc t, sprintf "the `then` branch is %s" (article x)) ])
             ~notes:[ "both branches of an `if` have to produce the same type" ]
             ());
      tt
  | If (c, t, None) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "this `if` has no `else`, so it can't produce %s"
                 (article f))
             ~help:(fun _ _ ->
               "add an `else` branch for when the condition is false")
             ())
          (result_loc t) ~found:(infer env cx t) ~expected:unit
      in
      (* if it was meant to produce a value, it isn't a `Unit` *)
      if ok then unit else TError
  | Call (f, args) -> infer_call env cx e f args
  | Lambda (params, body) ->
      let ps = List.map (param_type env ~tparams:cx.tparams) params in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      bind_params cx params ps;
      let tb = infer env { cx with errs; uses } body in
      TFun (ps, tb, errs, uses)
  | Block (stmts, last) ->
      List.iter (stmt env cx) stmts;
      infer env cx last
  | Con (c, args) -> infer_con env cx e c args ~expected:(fresh_var env.st)
  | Record (name, fields) ->
      infer_record env cx e name fields ~expected:(fresh_var env.st)
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) -> infer_match env cx subject arms ~want:None
  | Array xs ->
      (* the first element says what the others have to be *)
      let elem = fresh_var env.st in
      List.iteri
        (fun i (x : expr) ->
          let msg =
            if i = 0 then None
            else
              Some
                (fun f x ->
                  sprintf
                    "this element is %s, but the elements before it are %s"
                    (article f) (article x))
          in
          check env cx x elem ~why:(explain ?msg ()))
        xs;
      array elem
  | Index (a, i) ->
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "only an `Array` can be indexed, but this is %s"
                 (article f))
             ())
          (result_loc a) ~found:(infer env cx a) ~expected:(array elem)
      in
      want_int env "an index" i (infer env cx i);
      if ok then elem else TError
  | Ref a ->
      (* mut.ml allows `&` only on call arguments and `for` loops, which
         handle it themselves *)
      infer env cx a
  | Assign { target; op; value } ->
      let tt = infer env cx target in
      (match op with
      | Some op ->
          let name = binop_to_string op ^ "=" in
          want_int env name target tt;
          want_int env name value (infer env cx value)
      | None ->
          check env cx value tt
            ~why:
              (explain
                 ~msg:(fun f x ->
                   sprintf "this is %s, but it's being assigned to %s"
                     (article f) (article x))
                 ()));
      unit
  | For { var; iter; body } ->
      let array_of = match iter.kind with Ref a -> a | _ -> iter in
      let ta = infer env cx array_of in
      Hashtbl.replace cx.nodes iter.node ta;
      let elem = fresh_var env.st in
      let ok =
        unifies env
          (explain
             ~msg:(fun f _ ->
               sprintf "a `for` loop goes over an `Array`, but this is %s"
                 (article f))
             ())
          (result_loc array_of) ~found:ta ~expected:(array elem)
      in
      Hashtbl.replace cx.locals var.id (if ok then elem else TError);
      ignore (infer env cx body);
      unit

and stmt env cx = function
  | Let { name; ty; value; _ } ->
      let t =
        match ty with
        | Some ann ->
            let t =
              convert ~tvars:cx.tparams ~row:(fun () -> fresh_row env.st) ann
            in
            check env cx value t;
            t
        | None -> infer env cx value
      in
      Hashtbl.replace cx.locals name.id t
  | Expr e -> ignore (infer env cx e)

and infer_call env cx (e : expr) (f : expr) args =
  let tf = infer env cx f in
  let name =
    match f.kind with Var x -> sprintf "`%s`" (name_of x) | _ -> "this"
  in
  match repr tf with
  | TFun (ps, ret, errs, uses) ->
      let n = List.length ps and given = List.length args in
      if n <> given then (
        (* still check the arguments, for errors of their own *)
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        fail env e.loc
          (sprintf "%s takes %d argument%s but was given %d" name n (plural n)
             given))
      else (
        (* left to right, each against its parameter's type *)
        List.iter2
          (fun (p : Types.param) (a : expr) ->
            match (p.mode, a.kind) with
            | Inout, Ref place ->
                Hashtbl.replace cx.nodes a.node p.ty;
                check env cx place p.ty
            | Inout, _ ->
                let help =
                  match a.kind with
                  | Var x
                  | Field ({ kind = Var x; _ }, _)
                  | Index ({ kind = Var x; _ }, _) ->
                      sprintf "write `&` before it, as in `&%s`" (name_of x)
                  | _ -> "pass a variable, marked with `&`"
                in
                ignore (infer env cx a);
                ignore
                  (fail env a.loc ~help
                     ~notes:
                       [ "`&` shows at the call that the argument is changed" ]
                     (sprintf "%s changes this argument, so it needs `&`" name))
            | Read, Ref place ->
                ignore (infer env cx place);
                ignore
                  (fail env a.loc ~help:"remove the `&`"
                     ~notes:
                       [
                         "`&` marks an argument the call changes: an `inout` \
                          parameter";
                       ]
                     (sprintf "%s doesn't change this argument" name))
            | Read, _ -> check env cx a p.ty)
          ps args;
        absorb env cx e.loc errs uses;
        ret)
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         function, and its errors and dependencies become the caller's *)
      let ps = List.map (infer_arg env cx) args in
      let ret = fresh_var env.st in
      unify_at env f.loc ~found:tf ~expected:(TFun (ps, ret, cx.errs, cx.uses));
      ret
  | TError ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      TError
  | t ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      fail env f.loc
        (sprintf "%s is %s, not a function" name
           (article (show (printer env) t)))

(* An argument's type, and whether it's passed with `&`. *)
and infer_arg env cx (a : expr) =
  match a.kind with
  | Ref place ->
      let t = infer env cx place in
      Hashtbl.replace cx.nodes a.node t;
      { mode = Inout; ty = t }
  | _ -> read (infer env cx a)

(* A constructor applied to [args], where a value of type [expected] is
   wanted. *)
and infer_con env cx (e : expr) (c : ident) args ~expected =
  match find_ctor env c ~expected with
  | None ->
      List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      TError
  | Some (td, ctor) ->
      Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
      let t, tvars = instance env td in
      if ctor_shape env e.loc c ctor (List.map fst args) then
        List.iter2
          (fun (f : Iface.field) (_, (a : expr)) ->
            check env cx a (field_type ~tvars f)
              ~why:
                (explain
                   ~notes:[ sprintf "`%s`'s field `%s`" c.name f.fname ]
                   ()))
          ctor.cfields args
      else
        (* still check the arguments, for errors of their own *)
        List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      t

(* A record literal: `User { ... }`, or `{ ... }` with its type found
   through [expected], or else through its fields. *)
and infer_record env cx (e : expr) name fields ~expected =
  let ids = List.map fst fields in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (f : ident) ->
      match Hashtbl.find_opt seen f.name with
      | Some first ->
          report env
            (Diag.make f.loc ~help:"remove one of them"
               ~labels:[ (first, sprintf "the first `%s` is here" f.name) ]
               (sprintf "there are two fields named `%s`" f.name))
      | None -> Hashtbl.replace seen f.name f.loc)
    ids;
  let given = sorted (List.map (fun (f : ident) -> f.name) ids) in
  let decl =
    match name with
    | Some { tref = Named p; tloc } -> (
        let td = Hashtbl.find env.types p in
        match record_fields td with
        | Some fs -> Some (td, fs)
        | None ->
            report env (not_a_record ~names:env.names tloc td);
            None)
    | Some { tref = Param _; _ } ->
        (* resolve.ml only resolves a record's name to a declared type *)
        assert false
    | None -> (
        let known =
          Option.bind (known_decl env expected) (fun td ->
              Option.map (fun fs -> (td, fs)) (record_fields td))
        in
        let fits td =
          match record_fields td with
          | Some fs when sorted (field_names fs) = given -> Some fs
          | _ -> None
        in
        match through_type env ~known ~fits with
        | Found found -> Some found
        | Nowhere ->
            report env (no_record_fits e.loc);
            None
        | Several paths ->
            report env (several_records_fit ~names:env.names e.loc paths);
            None)
  in
  match decl with
  | None ->
      List.iter (fun (_, v) -> ignore (infer env cx v)) fields;
      TError
  | Some (td, decl) ->
      let t, tvars = instance env td in
      (* a misspelled field is also a missing one; once it's reported, the
         missing ones aren't, as they're likely the same mistake *)
      let unknown = ref false in
      List.iter
        (fun ((f : ident), v) ->
          match
            List.find_opt (fun (d : Iface.field) -> d.fname = f.name) decl
          with
          | Some fd ->
              check env cx v (field_type ~tvars fd)
                ~why:
                  (explain
                     ~notes:
                       [
                         sprintf "`%s`'s field `%s`" (type_name env td.path)
                           f.name;
                       ]
                     ())
          | None ->
              report env (no_such_field ~names:env.names f td.path decl);
              unknown := true;
              ignore (infer env cx v))
        fields;
      let missing =
        List.filter (fun d -> not (List.mem d given)) (field_names decl)
      in
      if missing <> [] && not !unknown then
        report env (missing_fields ~names:env.names e.loc td.path missing);
      t

(* `r.f`: the field is found through [r]'s type, which has to be known by
   now, or be the one record type that has a field named [f]. *)
and infer_field env cx (e : expr) r (f : ident) =
  let tr = infer env cx r in
  let field_of (td : Iface.type_decl) =
    Option.bind (record_fields td)
      (List.find_opt (fun (d : Iface.field) -> d.fname = f.name))
  in
  let found (td : Iface.type_decl) fd tvars =
    Hashtbl.replace cx.found e.node (Field_of td.path);
    field_type ~tvars fd
  in
  let needs_record t =
    report env (needs_record f (show (printer env) t));
    TError
  in
  match repr tr with
  | TError -> TError
  | TCon (p, args) as t -> (
      let td = Hashtbl.find env.types p in
      match (record_fields td, field_of td) with
      | _, Some fd -> found td fd args
      | Some decl, None ->
          report env (no_such_field ~names:env.names f p decl);
          TError
      | None, None -> needs_record t)
  | TVar _ -> (
      match through_type env ~known:None ~fits:field_of with
      | Found (td, fd) ->
          let t, tvars = instance env td in
          unify_at env r.loc ~found:tr ~expected:t;
          found td fd tvars
      | Nowhere ->
          report env (no_record_has f);
          TError
      | Several paths ->
          let what =
            match r.kind with
            | Var x -> Some (Infer_msg.Named (name_of x))
            | Call ({ kind = Var (Global p); _ }, _)
              when p <> cx.self && List.mem_assoc p env.group ->
                (* another function of the group, seen only as declared *)
                Some (Group_result p.name)
            | _ -> None
          in
          report env (several_records_have ~names:env.names r.loc ?what f paths);
          TError)
  | t -> needs_record t

(* A `match`. With [want], every arm is checked against the type it says;
   otherwise the first arm says what the others have to be. *)
and infer_match env cx subject arms ~want =
  let ts = infer env cx subject in
  let result, arm_why =
    match want with
    | Some (expected, why) -> (expected, fun _ -> why)
    | None ->
        let first = result_loc (List.hd arms).arm_body in
        ( fresh_var env.st,
          fun i ->
            let msg =
              if i = 0 then None
              else
                Some
                  (fun f x ->
                    sprintf "this arm is %s, but the arms above it are %s"
                      (article f) (article x))
            in
            explain ?msg
              ~labels:(fun _ x ->
                [ (first, sprintf "the first arm is %s" (article x)) ])
              () )
  in
  List.iteri
    (fun i a ->
      bind_pattern env cx ts a.arm_pat;
      Option.iter
        (fun g -> want_bool env "a guard" g (infer env cx g))
        a.arm_guard;
      check env cx ~why:(arm_why i) a.arm_body result)
    arms;
  result

(* Check a pattern against the type of the value it matches, and give the
   variables it binds their types. A constructor is found through that
   type. *)
and bind_pattern env cx t (p : pattern) =
  Hashtbl.replace cx.nodes p.pnode t;
  let check found =
    unify_at env p.ploc ~found ~expected:t ~msg:(fun f x ->
        sprintf "expected a pattern for `%s`, but this one is %s" x (article f))
  in
  match p.pkind with
  | PWild -> ()
  | PVar b -> Hashtbl.replace cx.locals b.id t
  | PInt _ -> check int
  | PBool _ -> check bool
  | PCon (c, ps) -> (
      let unknown () = List.iter (bind_pattern env cx TError) ps in
      match find_ctor env c ~expected:t with
      | None -> unknown ()
      | Some (td, ctor) ->
          Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
          let tc, tvars = instance env td in
          check tc;
          if ctor_shape env p.ploc c ctor (List.map (fun _ -> None) ps) then
            List.iter2
              (fun fd sub -> bind_pattern env cx (field_type ~tvars fd) sub)
              ctor.cfields ps
          else unknown ())
