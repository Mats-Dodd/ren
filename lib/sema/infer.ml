(* Type inference: Hindley–Milner with Rémy-style rows, the system OCaml
   uses.

   Every expression gets a type, and a mismatch is reported before the
   program runs. Private functions need no annotations: inference works out
   their parameter and return types, and generalizes them, so `fn id(x) = x`
   works on any type.

   Every function type also carries two rows (types.ml): the errors it can
   fail with and the dependencies it uses. Each function body has its own
   pair of open rows, and every call adds the callee's rows to the caller's,
   so a function's `uses` is everything the functions it calls use. `print`
   uses `Io`, so `main` does too. Nothing can fail with an error until Stage
   6, so error rows are always empty for now, but they're inferred the same
   way.

   Top-level functions are checked in dependency order: callees before
   callers, with mutually recursive functions checked together (a strongly
   connected component of the call graph). Inside one group every function
   has a single type; the group is generalized once it's done.

   Every name has already been resolved (resolve.ml): a local is known by
   its binder's id, and a top-level function by its path, so nothing here
   looks a name up in a scope.

   A type error is reported to the sink (diag.ml), and inference carries
   on. The code with the error gets the type [TError], which unifies with
   everything, so the one mistake isn't reported again wherever its value
   goes. *)

open Ast
open Ast.Resolved
open Types

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let quote names = String.concat ", " (List.map (sprintf "`%s`") names)

(* "a `Bool`", "an `Int`" *)
let article name =
  match name.[0] with
  | 'A' | 'E' | 'I' | 'O' | 'U' -> sprintf "an `%s`" name
  | _ -> sprintf "a `%s`" name

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

(* Where [found] and [expected] disagree on whether a function parameter is
   `inout`, the mode [found] has there. Error messages explain that, since
   the two types can otherwise look alike. *)
let rec mode_clash found expected =
  match (repr found, repr expected) with
  | TFun (p1, r1, _, _), TFun (p2, r2, _, _)
    when List.length p1 = List.length p2 ->
      let here =
        List.find_map
          (fun ((x : Types.param), (y : Types.param)) ->
            if x.mode <> y.mode then Some x.mode else mode_clash x.ty y.ty)
          (List.combine p1 p2)
      in
      if here <> None then here else mode_clash r1 r2
  | TCon (n1, a1), TCon (n2, a2) when n1 = n2 && List.length a1 = List.length a2
    ->
      List.find_map (fun (x, y) -> mode_clash x y) (List.combine a1 a2)
  | _ -> None

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
      let params =
        List.sort_uniq compare (List.map snd (skolems found @ skolems expected))
      in
      let clash = mode_clash found expected in
      let notes =
        notes
        @ List.map
            (fun t ->
              sprintf
                "`%s` is a type parameter, so this code has to work for every \
                 type `%s` could be"
                t t)
            params
        @
        match clash with
        | Some Inout ->
            [
              "a function that changes its argument (`inout`) can't stand in \
               for one that only reads it: its caller wouldn't pass the \
               argument with `&`, so the change would be lost";
            ]
        | Some Read ->
            [
              "a function that only reads its argument can't stand in for one \
               that changes it (`inout`)";
            ]
        | None -> []
      in
      let help =
        match (help, clash) with
        | None, Some Inout ->
            Some
              "pass it only where the parameter's type says `fn(inout ...)`, \
               or call it directly"
        | h, _ -> h
      in
      ignore (fail env ?help ~notes ~labels:(labels f x) loc msg);
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

(* ---- the call graph ---- *)

(* Group functions into strongly connected components of the call graph,
   callees before callers (Tarjan's algorithm, which finishes a component
   only after every component it reaches). [calls] lists the top-level
   functions each function uses, which resolve.ml found. *)
let components ~home ~calls (fns : fn_def list) =
  let by_name = Hashtbl.create 16 in
  List.iter (fun (f : fn_def) -> Hashtbl.replace by_name f.name.name f) fns;
  let callees (f : fn_def) =
    List.assoc f.name.name calls
    |> List.filter_map (fun (p : Path.t) ->
        if p.home = home then Hashtbl.find_opt by_name p.name else None)
  in
  let index = Hashtbl.create 16 and low = Hashtbl.create 16 in
  let stack = ref [] and on_stack = Hashtbl.create 16 in
  let counter = ref 0 and result = ref [] in
  let rec visit (f : fn_def) =
    let v = f.name.name in
    Hashtbl.replace index v !counter;
    Hashtbl.replace low v !counter;
    incr counter;
    stack := f :: !stack;
    Hashtbl.replace on_stack v ();
    List.iter
      (fun (g : fn_def) ->
        let w = g.name.name in
        if not (Hashtbl.mem index w) then (
          visit g;
          Hashtbl.replace low v (min (Hashtbl.find low v) (Hashtbl.find low w)))
        else if Hashtbl.mem on_stack w then
          Hashtbl.replace low v
            (min (Hashtbl.find low v) (Hashtbl.find index w)))
      (callees f);
    if Hashtbl.find low v = Hashtbl.find index v then
      let rec pop acc =
        match !stack with
        | g :: rest ->
            stack := rest;
            Hashtbl.remove on_stack g.name.name;
            if g.name.name = v then g :: acc else pop (g :: acc)
        | [] -> assert false
      in
      let group = pop [] in
      (* keep source order inside a group, for stable error messages *)
      let pos (g : fn_def) = (g.loc.start.line, g.loc.start.col) in
      result := List.sort (fun a b -> compare (pos a) (pos b)) group :: !result
  in
  List.iter (fun f -> if not (Hashtbl.mem index f.name.name) then visit f) fns;
  List.rev !result

(* ---- transparent parameters ----

   A parameter whose type is written `fn(...)` is transparent: its errors
   and dependencies flow into the caller, so they're never written. That's
   only true if the function just calls it, or passes it straight on to
   another function. Storing it, returning it, or capturing it in a lambda
   that escapes would let it outlive the call. *)

let check_transparent sink (f : fn_def) =
  let fn_params =
    List.filter_map
      (fun (p : Resolved.param) ->
        match p.pty with Some (TyFn _) -> Some p.pname | _ -> None)
      f.params
  in
  List.iter
    (fun (param : binder) ->
      let name = param.ident.name in
      let fail loc what =
        Diag.error loc
          ~notes:
            [
              "a parameter whose type is written `fn(...)` can only be called, \
               or passed straight to another function";
            ]
          ~help:
            (sprintf
               "remove the type from `%s` and let it be inferred, so its \
                errors and dependencies are tracked wherever it goes"
               name)
          (sprintf "`%s` %s, so it isn't transparent" name what)
      in
      let is_param = function Local b -> b.id = param.id | _ -> false in
      (* does [e] use the parameter anywhere? *)
      let rec mentions (e : expr) =
        let any = List.exists mentions in
        match e.kind with
        | Var x -> is_param x
        | Int _ | Bool _ | Unit -> false
        | Unop (_, a) | Field (a, _) | Ref a | Lambda (_, a) -> mentions a
        | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ }
          ->
            any [ a; b ]
        | If (c, t, f) -> any (c :: t :: Option.to_list f)
        | Array xs -> any xs
        | For { iter; body; _ } -> any [ iter; body ]
        | Call (f, args) -> any (f :: args)
        | Con (_, args) -> any (List.map snd args)
        | Record (_, fields) -> any (List.map snd fields)
        | Block (stmts, last) ->
            any
              (List.map
                 (function Let { value; _ } -> value | Expr e -> e)
                 stmts
              @ [ last ])
        | Match (s, arms) ->
            any
              (s
              :: List.concat_map
                   (fun (a : arm) ->
                     Option.to_list a.arm_guard @ [ a.arm_body ])
                   arms)
      in
      (* [ok]: this position may hold the bare parameter, or a lambda that
         captures it *)
      let rec walk ~ok (e : expr) =
        let walk_all = List.iter (walk ~ok:false) in
        match e.kind with
        | Var x when is_param x ->
            if not ok then fail e.loc "is used as a value here"
        | Int _ | Bool _ | Unit | Var _ -> ()
        | Call (callee, args) ->
            walk ~ok:true callee;
            List.iter (walk ~ok:true) args
        | Lambda (_, body) ->
            if (not ok) && mentions body then
              fail e.loc "is captured by a lambda that outlives the call"
            else walk ~ok:false body
        | Unop (_, a) | Field (a, _) | Ref a -> walk_all [ a ]
        | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ }
          ->
            walk_all [ a; b ]
        | If (c, t, f) -> walk_all (c :: t :: Option.to_list f)
        | Array xs -> walk_all xs
        | For { iter; body; _ } -> walk_all [ iter; body ]
        | Con (_, args) -> walk_all (List.map snd args)
        | Record (_, fields) -> walk_all (List.map snd fields)
        | Block (stmts, last) ->
            List.iter
              (function
                | Let { value; _ } -> walk ~ok:false value
                | Expr e -> walk ~ok:false e)
              stmts;
            walk ~ok:false last
        | Match (s, arms) ->
            walk ~ok:false s;
            List.iter
              (fun (a : arm) ->
                Option.iter (walk ~ok:false) a.arm_guard;
                walk ~ok:false a.arm_body)
              arms
      in
      Diag.recover sink ~default:() (fun () -> walk ~ok:false f.body))
    fn_params

(* ---- the program ---- *)

(* Infer every function's type, and return each function's type scheme, in
   canonical form. *)
let program sink ~imports ?entry (r : Resolve.t) =
  let st = Types.new_state () in
  let home = r.home in
  let env =
    {
      st;
      sink;
      home;
      types = Hashtbl.create 16;
      ctors = Hashtbl.create 16;
      globals = Hashtbl.create 16;
      deferred = [];
    }
  in
  List.iter
    (fun (iface : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace env.globals
            (Path.make iface.home v.vname)
            (of_scheme st v.scheme))
        iface.values)
    imports;
  let fns =
    List.filter_map (function Fn f -> Some f | Type _ -> None) r.prog
  in
  let path (f : fn_def) = Path.make home f.name.name in
  List.iter
    (fun (td : Iface.type_decl) ->
      Hashtbl.replace env.types td.path td;
      match td.body with
      | Sum cs ->
          List.iter
            (fun (c : Iface.ctor) -> Hashtbl.replace env.ctors c.cname (td, c))
            cs
      | Record _ | Builtin -> ())
    (List.concat_map (fun (iface : Iface.t) -> iface.types) imports @ r.types);
  List.iter (check_transparent sink) fns;
  let schemes = Hashtbl.create 16 in
  List.iter
    (fun group ->
      enter_level env.st;
      (* each function's type within the group: its own type parameters
         (as skolems), parameters, result and effects *)
      let setup (f : fn_def) =
        let skolems =
          List.map (fun (t : ident) -> (fresh_id env.st, t.name)) f.tparams
        in
        let tparams = List.map (fun (id, n) -> TSkol (id, n)) skolems in
        let cx =
          {
            locals = Hashtbl.create 16;
            errs = fresh_row env.st;
            uses = fresh_row env.st;
            tparams;
          }
        in
        let ps = List.map (param_type env cx) f.params in
        let ret =
          match f.ret with
          | Some t -> convert ~tvars:tparams ~row:closed t
          | None when f.pub ->
              unit (* a public function without `->` returns Unit *)
          | None -> fresh_var env.st
        in
        Hashtbl.replace env.globals (path f) (TFun (ps, ret, cx.errs, cx.uses));
        (f, skolems, cx, ps, ret)
      in
      let setups = List.map setup group in
      List.iter
        (fun ((f : fn_def), _, cx, ps, ret) ->
          bind_params cx f.params ps;
          let tb = infer env cx f.body in
          let pr = printer env in
          let notes, help =
            match f.ret with
            | Some _ ->
                ( [
                    sprintf "`%s` is declared to return `%s`" f.name.name
                      (show pr ret);
                  ],
                  None )
            | None when f.pub ->
                ( [ "a public function without `->` returns `Unit`" ],
                  Some (sprintf "add `-> %s` to the signature" (show pr tb)) )
            | None -> ([], None)
          in
          unify_at env (result_loc f.body) ~found:tb ~expected:ret ~notes ?help)
        setups;
      resolve_deferred env;
      leave_level env.st;
      List.iter
        (fun ((f : fn_def), skolems, _, _, _) ->
          let mono = Hashtbl.find env.globals (path f) in
          (match
             List.filter
               (fun (id, _) -> not (List.mem_assoc id skolems))
               (Types.skolems mono)
           with
          | (id, t) :: _ ->
              let owner =
                List.find (fun (_, sk, _, _, _) -> List.mem_assoc id sk) setups
              in
              let (o : fn_def), _, _, _, _ = owner in
              let declared =
                List.find (fun (p : ident) -> p.name = t) o.tparams
              in
              ignore
              @@ fail env f.name.loc
                   ~labels:[ (declared.loc, sprintf "`%s` is declared here" t) ]
                   ~notes:
                     [
                       sprintf
                         "`%s` and `%s` call each other, and functions that \
                          call each other are checked at a single type"
                         f.name.name o.name.name;
                     ]
                   ~help:
                     (sprintf
                        "remove the type parameter from `%s`, or break the \
                         cycle"
                        o.name.name)
                   (sprintf
                      "`%s` would have to use `%s`, the type parameter of `%s`"
                      f.name.name t o.name.name)
          | [] -> ());
          let scheme = generalize env.st ~skolems mono in
          Hashtbl.replace env.globals (path f) scheme;
          Hashtbl.replace schemes f.name.name scheme)
        setups;
      (* public functions spell out their full contract *)
      List.iter
        (fun ((f : fn_def), _, _, _, _) ->
          if f.pub then
            match Hashtbl.find schemes f.name.name with
            | TFun (ps, _, _, _) as scheme ->
                List.iter2
                  (fun (p : Resolved.param) (t : Types.param) ->
                    if p.pty = None then (
                      let pr = printer env in
                      reserve pr scheme;
                      let name = p.pname.ident in
                      ignore
                      @@ fail env name.loc
                           ~help:
                             (sprintf "write `%s: %s`" name.name (show pr t.ty))
                           ~notes:
                             [
                               "public functions spell out their full signature";
                             ]
                           (sprintf
                              "the parameter `%s` of the public function `%s` \
                               has no type"
                              name.name f.name.name)))
                  f.params ps
            | _ -> assert false)
        setups)
    (components ~home ~calls:r.calls fns);
  (match
     Option.map
       (fun file ->
         (file, List.find_opt (fun (f : fn_def) -> f.name.name = "main") fns))
       entry
   with
  | None -> ()
  | Some (file, None) ->
      ignore
        (fail env (Loc.point ~file 1 1)
           ~help:"add `fn main() = ...`, which is where the program starts"
           "this program has no `main` function")
  | Some (_, Some f) when f.params <> [] ->
      ignore
        (fail env (List.hd f.params).pname.ident.loc
           ~help:"remove the parameters" "`main` can't take parameters")
  | Some _ -> ());
  List.map
    (fun f -> (f.name.name, to_scheme st (Hashtbl.find schemes f.name.name)))
    fns
