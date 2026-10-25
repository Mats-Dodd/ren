(* Inferring the types of expressions (see infer.ml for the whole pass):
   what each kind of expression requires of its parts, and what type it
   has. infer_top.ml runs this over every function, a group at a time. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg

type env = {
  st : Types.state;
  sink : Diag.sink;
  home : string;  (** the module being checked *)
  types : (Path.t, Iface.type_decl) Hashtbl.t;
      (** every type the module can see (iface.ml) *)
  ctors : (string, Iface.type_decl * Iface.ctor) Hashtbl.t;
  globals : (Path.t, ty) Hashtbl.t;
      (** top-level functions: a type scheme once their group is done *)
  mutable deferred : deferred list;  (** most recent first *)
}

(* A question that can't be answered yet, such as which record type has the
   field in `u.id` when `u`'s type isn't known: retried once the rest of the
   group has been inferred. *)
and deferred = { attempt : unit -> bool; fail : unit -> unit }

(* What the expression being inferred can see. *)
type ctx = {
  locals : (int, ty) Hashtbl.t;
      (** the type of each local of the top-level function, by binder id *)
  errs : row;  (** the errors of the innermost function or lambda *)
  uses : row;  (** the dependencies of the innermost function or lambda *)
  tparams : ty list;  (** what the type parameters in scope stand for *)
}

(* ---- reporting ---- *)

let printer env = Types.printer ~home:env.home env.st
let type_name env p = Path.show ~home:env.home p

(* A name as it's written, for messages. *)
let name_of = function
  | Local b -> b.ident.name
  | Global p -> p.name
  | Intrinsic x -> x

(* Report an error, and carry on: the code it's about has type [TError]. *)
let fail env ?help ?notes ?labels loc msg =
  Diag.report env.sink (Diag.make ?help ?notes ?labels loc msg);
  TError

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_loc (e : expr) =
  match e.kind with Block (_, last) -> result_loc last | _ -> e.loc

(* Unify [found] (what the code has) with [expected] (what it needs), and
   say whether that worked. [msg] words the error, and [labels] point at
   other code, given both types printed. *)
let unifies env ?(notes = []) ?help ?msg ?(labels = fun _ _ -> []) loc ~found
    ~expected =
  match Unify.unify env.st found expected with
  | () -> true
  | exception Unify.Mismatch ->
      let pr = printer env in
      let f = show pr found and x = show pr expected in
      let msg =
        match msg with
        | Some m -> m f x
        | None -> sprintf "expected `%s`, found `%s`" x f
      in
      let more, help = mismatch_notes ?help ~found ~expected () in
      ignore (fail env ?help ~notes:(notes @ more) ~labels:(labels f x) loc msg);
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

let unify_at env ?notes ?help ?msg ?labels loc ~found ~expected =
  ignore (unifies env ?notes ?help ?msg ?labels loc ~found ~expected)

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

(* Fresh variables for a type declaration's parameters: `Option<T>` used
   once can be an `Option<Int>`, and elsewhere an `Option<Bool>`. *)
let instance env (td : Iface.type_decl) =
  let tvars = List.map (fun _ -> fresh_var env.st) td.params in
  (TCon (td.path, tvars), tvars)

(* A field's type, given what the type's parameters stand for. A function
   type written in a declaration uses and fails with nothing. *)
let field_type ~tvars (f : Iface.field) =
  of_ty ~vars:(List.nth tvars) ~tails:(fun _ -> REmpty) f.fty

let record_fields env path =
  match Hashtbl.find_opt env.types path with
  | Some { body = Record fs; _ } -> Some fs
  | _ -> None

let field_names (fs : Iface.field list) = List.map (fun f -> f.Iface.fname) fs

(* Record types whose fields pass [keep], sorted by name. *)
let records_where env keep =
  Hashtbl.fold
    (fun path (td : Iface.type_decl) acc ->
      match td.body with Record fs when keep fs -> path :: acc | _ -> acc)
    env.types []
  |> List.sort (fun (a : Path.t) (b : Path.t) ->
      compare (a.name, a.home) (b.name, b.home))

(* ---- expressions ---- *)

(* A name's type. A top-level function's is a fresh instance of its
   scheme, so each use can pick its own types. *)
let lookup env cx = function
  | Local b -> Hashtbl.find cx.locals b.id
  | Global p -> instantiate env.st (Hashtbl.find env.globals p)
  | Intrinsic x ->
      instantiate env.st (Hashtbl.find env.globals (Path.prelude x))

let want_int env op (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int
    ~notes:[ sprintf "`%s` works on `Int`s" op ]

let want_bool env what (e : expr) t =
  unify_at env e.loc ~found:t ~expected:bool
    ~notes:[ sprintf "%s has to be a `Bool`" what ]

(* A call adds the callee's errors and dependencies to the caller's. *)
let absorb env cx loc errs uses =
  try
    Unify.unify_row env.st errs cx.errs;
    Unify.unify_row env.st uses cx.uses
  with Unify.Mismatch | Unify.Infinite ->
    let pr = printer env in
    ignore
      (fail env loc
         (sprintf "this call%s, which isn't allowed here"
            (show_effects pr errs uses)))

let rec infer env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Bool _ -> bool
  | Unit -> unit
  | Var x -> lookup env cx x
  | Unop (Neg, a) ->
      want_int env "-" a (infer env cx a);
      int
  | Binop (op, a, b) -> (
      let ta = infer env cx a in
      let tb = infer env cx b in
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod ->
          want_int env name a ta;
          want_int env name b tb;
          int
      | Lt | Le | Gt | Ge ->
          want_int env name a ta;
          want_int env name b tb;
          bool
      | Eq | Neq ->
          unify_at env b.loc ~found:tb ~expected:ta
            ~msg:(fun f x ->
              sprintf
                "`%s` compares two values of the same type, but this is %s and \
                 the left side is %s"
                name (article f) (article x))
            ~labels:(fun _ x -> [ (a.loc, sprintf "this is %s" (article x)) ]);
          bool)
  | If (c, t, Some f) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let tt = infer env cx t in
      let tf = infer env cx f in
      unify_at env (result_loc f) ~found:tf ~expected:tt
        ~msg:(fun f x ->
          sprintf "this `else` branch is %s, but the `then` branch is %s"
            (article f) (article x))
        ~labels:(fun _ x ->
          [ (result_loc t, sprintf "the `then` branch is %s" (article x)) ])
        ~notes:[ "both branches of an `if` have to produce the same type" ];
      tt
  | If (c, t, None) ->
      want_bool env "an `if` condition" c (infer env cx c);
      let ok =
        unifies env (result_loc t) ~found:(infer env cx t) ~expected:unit
          ~msg:(fun f _ ->
            sprintf "this `if` has no `else`, so it can't produce %s"
              (article f))
          ~help:"add an `else` branch for when the condition is false"
      in
      (* if it was meant to produce a value, it isn't a `Unit` *)
      if ok then unit else TError
  | Call (f, args) -> infer_call env cx e f args
  | Lambda (params, body) ->
      let ps = List.map (param_type env cx) params in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      bind_params cx params ps;
      let tb = infer env { cx with errs; uses } body in
      TFun (ps, tb, errs, uses)
  | Block (stmts, last) ->
      List.iter
        (function
          | Let { name; ty; value; _ } ->
              let t = infer env cx value in
              Option.iter
                (fun ann ->
                  unify_at env (result_loc value) ~found:t
                    ~expected:
                      (convert ~tvars:cx.tparams
                         ~row:(fun () -> fresh_row env.st)
                         ann))
                ty;
              Hashtbl.replace cx.locals name.id t
          | Expr e -> ignore (infer env cx e))
        stmts;
      infer env cx last
  | Con (c, args) ->
      (* check.ml has confirmed the constructor exists with this many
         arguments, labelled correctly *)
      let td, ctor = Hashtbl.find env.ctors c.name in
      let t, tvars = instance env td in
      List.iter2
        (fun (f : Iface.field) (_, (a : expr)) ->
          unify_at env (result_loc a) ~found:(infer env cx a)
            ~expected:(field_type ~tvars f)
            ~notes:[ sprintf "`%s`'s field `%s`" c.name f.fname ])
        ctor.cfields args;
      t
  | Record (name, fields) -> infer_record env cx e name fields
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) ->
      let ts = infer env cx subject in
      let result = fresh_var env.st in
      let first = result_loc (List.hd arms).arm_body in
      List.iteri
        (fun i a ->
          bind_pattern env cx ts a.arm_pat;
          Option.iter
            (fun g -> want_bool env "a guard" g (infer env cx g))
            a.arm_guard;
          let tb = infer env cx a.arm_body in
          let msg =
            if i = 0 then None
            else
              Some
                (fun f x ->
                  sprintf "this arm is %s, but the arms above it are %s"
                    (article f) (article x))
          in
          let labels _ x =
            [ (first, sprintf "the first arm is %s" (article x)) ]
          in
          unify_at env (result_loc a.arm_body) ~found:tb ~expected:result ?msg
            ~labels)
        arms;
      result
  | Array xs ->
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
          unify_at env (result_loc x) ~found:(infer env cx x) ~expected:elem
            ?msg)
        xs;
      array elem
  | Index (a, i) ->
      let elem = fresh_var env.st in
      let ok =
        unifies env (result_loc a) ~found:(infer env cx a)
          ~expected:(array elem) ~msg:(fun f _ ->
            sprintf "only an `Array` can be indexed, but this is %s" (article f))
      in
      want_int env "an index" i (infer env cx i);
      if ok then elem else TError
  | Ref a ->
      (* mut.ml allows `&` only on call arguments and `for` loops, which
         handle it themselves *)
      infer env cx a
  | Assign { target; op; value } ->
      let tt = infer env cx target in
      let tv = infer env cx value in
      (match op with
      | Some op ->
          let name = binop_to_string op ^ "=" in
          want_int env name target tt;
          want_int env name value tv
      | None ->
          unify_at env (result_loc value) ~found:tv ~expected:tt
            ~msg:(fun f x ->
              sprintf "this is %s, but it's being assigned to %s" (article f)
                (article x)));
      unit
  | For { var; iter; body } ->
      let iter = match iter.kind with Ref a -> a | _ -> iter in
      let elem = fresh_var env.st in
      let ok =
        unifies env (result_loc iter) ~found:(infer env cx iter)
          ~expected:(array elem) ~msg:(fun f _ ->
            sprintf "a `for` loop goes over an `Array`, but this is %s"
              (article f))
      in
      Hashtbl.replace cx.locals var.id (if ok then elem else TError);
      ignore (infer env cx body);
      unit

and param_type env cx (p : Resolved.param) =
  let t =
    match p.pty with
    | Some t -> convert ~tvars:cx.tparams ~row:(fun () -> fresh_row env.st) t
    | None -> fresh_var env.st
  in
  { mode = p.pmode; ty = t }

(* Inside the function, an `inout` parameter is an ordinary variable. *)
and bind_params cx params ps =
  List.iter2
    (fun (p : Resolved.param) (t : Types.param) ->
      Hashtbl.replace cx.locals p.pname.id t.ty)
    params ps

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
        List.iter2
          (fun (p : Types.param) (a : expr) ->
            match (p.mode, a.kind) with
            | Inout, Ref place ->
                unify_at env (result_loc place) ~found:(infer env cx place)
                  ~expected:p.ty
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
            | Read, _ ->
                unify_at env (result_loc a) ~found:(infer env cx a)
                  ~expected:p.ty)
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
  | Ref place -> { mode = Inout; ty = infer env cx place }
  | _ -> read (infer env cx a)

and infer_record env cx (e : expr) name fields =
  let given =
    List.map (fun ((f : ident), v) -> (f, v, infer env cx v)) fields
  in
  (* the record type [tn], checking each field's value against it *)
  let build tn =
    let td = Hashtbl.find env.types tn in
    let t, tvars = instance env td in
    let decl = Option.get (record_fields env tn) in
    List.iter
      (fun ((f : ident), v, tv) ->
        let fd = List.find (fun (d : Iface.field) -> d.fname = f.name) decl in
        unify_at env (result_loc v) ~found:tv ~expected:(field_type ~tvars fd)
          ~notes:[ sprintf "`%s`'s field `%s`" (type_name env tn) f.name ])
      given;
    t
  in
  match name with
  | Some { tref = Named p; _ } -> build p
  | Some { tref = Param _; _ } ->
      (* resolve.ml only resolves a record's name to a declared type *)
      assert false
  | None -> (
      let names =
        List.sort String.compare
          (List.map (fun ((f : ident), _) -> f.name) fields)
      in
      let fits =
        records_where env (fun fs ->
            List.sort String.compare (field_names fs) = names)
      in
      match fits with
      | [ one ] -> build one
      | _ ->
          (* several types have exactly these fields: wait to see which one
             this record is used as *)
          let t = fresh_var env.st in
          let attempt () =
            match repr t with
            | TVar _ -> false
            | TCon (n, _) when List.mem n fits ->
                unify_at env e.loc ~found:(build n) ~expected:t;
                true
            | _ ->
                unify_at env e.loc ~found:(build (List.hd fits)) ~expected:t;
                true
          in
          let fail () =
            ignore
              (fail env e.loc
                 ~help:
                   (sprintf "write the type's name first, like `%s { ... }`"
                      (type_name env (List.hd fits)))
                 (sprintf "these fields fit more than one type: %s"
                    (quote (List.map (type_name env) fits))))
          in
          env.deferred <- { attempt; fail } :: env.deferred;
          t)

and infer_field env cx (e : expr) r (f : ident) =
  let tr = infer env cx r in
  (* the field's type, once the record's type is known *)
  let resolve () =
    let pr = printer env in
    match repr tr with
    | TCon (n, args) as t -> (
        match record_fields env n with
        | None ->
            fail env f.loc
              (sprintf "`.%s` needs a record, but this is %s" f.name
                 (article (show pr t)))
        | Some decl -> (
            match
              List.find_opt (fun (d : Iface.field) -> d.fname = f.name) decl
            with
            | Some fd -> field_type ~tvars:args fd
            | None ->
                fail env f.loc
                  ~help:(sprintf "its fields: %s" (quote (field_names decl)))
                  (sprintf "`%s` has no field named `%s`" (type_name env n)
                     f.name)))
    | TError -> TError
    | t ->
        fail env f.loc
          (sprintf "`.%s` needs a record, but this is %s" f.name
             (article (show pr t)))
  in
  match repr tr with
  | TVar _ -> (
      let has fs = List.mem f.name (field_names fs) in
      match records_where env has with
      | [] ->
          fail env f.loc
            (sprintf "no record type has a field named `%s`" f.name)
      | [ n ] ->
          unify_at env r.loc ~found:tr
            ~expected:(fst (instance env (Hashtbl.find env.types n)));
          resolve ()
      | candidates ->
          (* more than one record type has this field: wait until the rest
             of the code says which one this is *)
          let result = fresh_var env.st in
          let attempt () =
            match repr tr with
            | TVar _ -> false
            | _ ->
                unify_at env e.loc ~found:(resolve ()) ~expected:result;
                true
          in
          let fail () =
            let what, help =
              match r.kind with
              | Var x ->
                  let x = name_of x in
                  ( sprintf "`%s`" x,
                    sprintf "annotate `%s` where it's defined, like `%s: %s`" x
                      x
                      (type_name env (List.hd candidates)) )
              | _ -> ("this", "add a type annotation to say which")
            in
            ignore
              (fail env r.loc ~help
                 ~notes:
                   [
                     sprintf "`%s` is a field of %s" f.name
                       (String.concat " and "
                          (List.map
                             (fun p -> sprintf "`%s`" (type_name env p))
                             candidates));
                   ]
                 (sprintf "can't tell which record type %s is" what))
          in
          env.deferred <- { attempt; fail } :: env.deferred;
          result)
  | _ -> resolve ()

(* Check a pattern against the type of the value it matches, and give the
   variables it binds their types. *)
and bind_pattern env cx t (p : pattern) =
  let check found =
    unify_at env p.ploc ~found ~expected:t ~msg:(fun f x ->
        sprintf "expected a pattern for `%s`, but this one is %s" x (article f))
  in
  match p.pkind with
  | PWild -> ()
  | PVar b -> Hashtbl.replace cx.locals b.id t
  | PInt _ -> check int
  | PBool _ -> check bool
  | PCon (c, ps) ->
      let td, ctor = Hashtbl.find env.ctors c.name in
      let tc, tvars = instance env td in
      check tc;
      List.iter2
        (fun fd sub -> bind_pattern env cx (field_type ~tvars fd) sub)
        ctor.cfields ps

(* Retry deferred questions until none makes progress; whatever is still
   unanswered is an error. *)
let resolve_deferred env =
  let rec loop pending =
    let still = List.filter (fun d -> not (d.attempt ())) pending in
    if List.length still < List.length pending then loop still
    else List.iter (fun d -> d.fail ()) still
  in
  let pending = List.rev env.deferred in
  env.deferred <- [];
  loop pending
