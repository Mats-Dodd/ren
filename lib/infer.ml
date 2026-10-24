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
   5, so error rows are always empty for now, but they're inferred the same
   way.

   Top-level functions are checked in dependency order: callees before
   callers, with mutually recursive functions checked together (a strongly
   connected component of the call graph). Inside one group every function
   has a single type; the group is generalized once it's done. *)

open Ast
open Types
module Env = Map.Make (String)
module Names = Set.Make (String)

let sprintf = Printf.sprintf
let plural n = if n = 1 then "" else "s"
let quote names = String.concat ", " (List.map (sprintf "`%s`") names)

(* "a `Bool`", "an `Int`" *)
let article name =
  match name.[0] with
  | 'A' | 'E' | 'I' | 'O' | 'U' -> sprintf "an `%s`" name
  | _ -> sprintf "a `%s`" name

type env = {
  types : (string, type_def) Hashtbl.t;
  ctors : (string, type_def * ctor) Hashtbl.t;
  globals : (string, ty) Hashtbl.t;
      (** top-level functions: a type scheme once their group is done *)
  mutable deferred : deferred list;  (** most recent first *)
}

(* A question that can't be answered yet, such as which record type has the
   field in `u.id` when `u`'s type isn't known: retried once the rest of the
   group has been inferred. *)
and deferred = { attempt : unit -> bool; fail : unit -> unit }

(* What the expression being inferred can see. *)
type ctx = {
  locals : ty Env.t;
  errs : row;  (** the errors of the innermost function or lambda *)
  uses : row;  (** the dependencies of the innermost function or lambda *)
  tparams : (string * ty) list;  (** type parameters in scope *)
}

(* ---- reporting ---- *)

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_loc (e : expr) =
  match e.kind with Block (_, last) -> result_loc last | _ -> e.loc

(* Unify [found] (what the code has) with [expected] (what it needs). [msg]
   words the error, given both types printed. *)
let unify_at ?(notes = []) ?help ?msg loc ~found ~expected =
  try Unify.unify found expected with
  | Unify.Mismatch ->
      let pr = printer () in
      let f = show pr found and x = show pr expected in
      let msg =
        match msg with
        | Some m -> m f x
        | None -> sprintf "expected `%s`, found `%s`" x f
      in
      let params =
        List.sort_uniq compare (List.map snd (skolems found @ skolems expected))
      in
      let notes =
        notes
        @ List.map
            (fun t ->
              sprintf
                "`%s` is a type parameter, so this code has to work for every \
                 type `%s` could be"
                t t)
            params
      in
      Diag.error ?help ~notes loc msg
  | Unify.Infinite ->
      let pr = printer () in
      Diag.error loc
        ~notes:
          [
            sprintf "it would have to be `%s` and `%s` at the same time"
              (show pr expected) (show pr found);
          ]
        "this value's type would have to contain itself"

(* ---- types as written ---- *)

(* Turn a written type into a checker type. [tvars] maps type parameter
   names to what they stand for. [row] makes the rows of written function
   types: fresh variables in parameters (a parameter `f: fn()` passes its
   dependencies through to the caller), closed in declarations and return
   types (a stored `fn()` uses nothing). *)
let rec convert ~tvars ~row (t : Ast.ty) =
  match t with
  | TyName (id, []) when List.mem_assoc id.name tvars ->
      List.assoc id.name tvars
  | TyName (id, args) -> TCon (id.name, List.map (convert ~tvars ~row) args)
  | TyFn (ps, ret, _) ->
      let ret =
        match ret with Some r -> convert ~tvars ~row r | None -> unit
      in
      TFun (List.map (convert ~tvars ~row) ps, ret, row (), row ())
  | TyInout (t, _) -> TInout (convert ~tvars ~row t)

let closed () = REmpty

(* Fresh variables for a type declaration's parameters: `Option<T>` used
   once can be an `Option<Int>`, and elsewhere an `Option<Bool>`. *)
let instance (td : type_def) =
  let tvars =
    List.map (fun (p : ident) -> (p.name, fresh_var ())) td.type_params
  in
  (TCon (td.type_name.name, List.map snd tvars), tvars)

let field_type ~tvars (f : field) = convert ~tvars ~row:closed f.field_ty

let record_fields env name =
  match Hashtbl.find_opt env.types name with
  | Some { type_body = Fields fs; _ } -> Some fs
  | _ -> None

(* Record types, by name, whose fields pass [keep]. *)
let records_where env keep =
  Hashtbl.fold
    (fun name td acc ->
      match td.type_body with Fields fs when keep fs -> name :: acc | _ -> acc)
    env.types []
  |> List.sort String.compare

(* ---- expressions ---- *)

let lookup env cx loc ~what x =
  match Env.find_opt x cx.locals with
  | Some t -> t
  | None -> (
      match Hashtbl.find_opt env.globals x with
      | Some t -> instantiate t
      | None -> Diag.error loc (sprintf "there's no %s named `%s`" what x))

let want_int op (e : expr) t =
  unify_at e.loc ~found:t ~expected:int
    ~notes:[ sprintf "`%s` works on `Int`s" op ]

let want_bool what (e : expr) t =
  unify_at e.loc ~found:t ~expected:bool
    ~notes:[ sprintf "%s has to be a `Bool`" what ]

(* A call adds the callee's errors and dependencies to the caller's. *)
let absorb cx loc errs uses =
  try
    Unify.unify_row errs cx.errs;
    Unify.unify_row uses cx.uses
  with Unify.Mismatch | Unify.Infinite ->
    let pr = printer () in
    Diag.error loc
      (sprintf "this call%s, which isn't allowed here"
         (show_effects pr errs uses))

let rec infer env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Bool _ -> bool
  | Unit -> unit
  | Var x -> lookup env cx e.loc ~what:"variable" x
  | Unop (Neg, a) ->
      want_int "-" a (infer env cx a);
      int
  | Binop (op, a, b) -> (
      let ta = infer env cx a in
      let tb = infer env cx b in
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod ->
          want_int name a ta;
          want_int name b tb;
          int
      | Lt | Le | Gt | Ge ->
          want_int name a ta;
          want_int name b tb;
          bool
      | Eq | Neq ->
          unify_at b.loc ~found:tb ~expected:ta ~msg:(fun f x ->
              sprintf
                "`%s` compares two values of the same type, but this is %s and \
                 the left side is %s"
                name (article f) (article x));
          bool)
  | If (c, t, Some f) ->
      want_bool "an `if` condition" c (infer env cx c);
      let tt = infer env cx t in
      let tf = infer env cx f in
      unify_at (result_loc f) ~found:tf ~expected:tt
        ~msg:(fun f x ->
          sprintf "this `else` branch is %s, but the `then` branch is %s"
            (article f) (article x))
        ~notes:[ "both branches of an `if` have to produce the same type" ];
      tt
  | If (c, t, None) ->
      want_bool "an `if` condition" c (infer env cx c);
      unify_at (result_loc t) ~found:(infer env cx t) ~expected:unit
        ~msg:(fun f _ ->
          sprintf "this `if` has no `else`, so it can't produce %s" (article f))
        ~help:"add an `else` branch for when the condition is false";
      unit
  | Call (f, args) -> infer_call env cx e f args
  | Lambda (params, body) ->
      let ps = List.map (param_type cx) params in
      let errs = fresh_row () and uses = fresh_row () in
      let locals = bind_params cx.locals params ps in
      let tb = infer env { cx with locals; errs; uses } body in
      TFun (ps, tb, errs, uses)
  | Block (stmts, last) ->
      let cx =
        List.fold_left
          (fun cx -> function
            | Let { name; ty; value; _ } ->
                let t = infer env cx value in
                Option.iter
                  (fun ann ->
                    unify_at (result_loc value) ~found:t
                      ~expected:(convert ~tvars:cx.tparams ~row:fresh_row ann))
                  ty;
                { cx with locals = Env.add name.name t cx.locals }
            | Expr e ->
                ignore (infer env cx e);
                cx)
          cx stmts
      in
      infer env cx last
  | Con (c, args) ->
      (* check.ml has confirmed the constructor exists with this many
         arguments, labelled correctly *)
      let td, ctor = Hashtbl.find env.ctors c.name in
      let t, tvars = instance td in
      List.iter2
        (fun f (_, (a : expr)) ->
          unify_at (result_loc a) ~found:(infer env cx a)
            ~expected:(field_type ~tvars f)
            ~notes:[ sprintf "`%s`'s field `%s`" c.name f.field_name.name ])
        ctor.ctor_fields args;
      t
  | Record (name, fields) -> infer_record env cx e name fields
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) ->
      let ts = infer env cx subject in
      let result = fresh_var () in
      List.iteri
        (fun i a ->
          let locals = bind_pattern env cx.locals ts a.arm_pat in
          let cx = { cx with locals } in
          Option.iter
            (fun g -> want_bool "a guard" g (infer env cx g))
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
          unify_at (result_loc a.arm_body) ~found:tb ~expected:result ?msg)
        arms;
      result
  | Array xs ->
      let elem = fresh_var () in
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
          unify_at (result_loc x) ~found:(infer env cx x) ~expected:elem ?msg)
        xs;
      array elem
  | Index (a, i) ->
      let elem = fresh_var () in
      unify_at (result_loc a) ~found:(infer env cx a) ~expected:(array elem)
        ~msg:(fun f _ ->
          sprintf "only an `Array` can be indexed, but this is %s" (article f));
      want_int "an index" i (infer env cx i);
      elem
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
          want_int name target tt;
          want_int name value tv
      | None ->
          unify_at (result_loc value) ~found:tv ~expected:tt ~msg:(fun f x ->
              sprintf "this is %s, but it's being assigned to %s" (article f)
                (article x)));
      unit
  | For { var; iter; body } ->
      let iter = match iter.kind with Ref a -> a | _ -> iter in
      let elem = fresh_var () in
      unify_at (result_loc iter) ~found:(infer env cx iter)
        ~expected:(array elem) ~msg:(fun f _ ->
          sprintf "a `for` loop goes over an `Array`, but this is %s"
            (article f));
      ignore
        (infer env { cx with locals = Env.add var.name elem cx.locals } body);
      unit

and param_type cx (p : param) =
  let t =
    match p.pty with
    | Some t -> convert ~tvars:cx.tparams ~row:fresh_row t
    | None -> fresh_var ()
  in
  match p.pmode with Inout -> TInout t | Read -> t

(* Inside the function, an `inout` parameter is an ordinary variable. *)
and bind_params locals params ps =
  List.fold_left2
    (fun locals (p : param) t ->
      let t = match t with TInout t -> t | t -> t in
      Env.add p.pname.name t locals)
    locals params ps

and infer_call env cx (e : expr) (f : expr) args =
  let tf =
    match f.kind with
    | Var x -> lookup env cx f.loc ~what:"function" x
    | _ -> infer env cx f
  in
  let name = match f.kind with Var x -> sprintf "`%s`" x | _ -> "this" in
  match repr tf with
  | TFun (ps, ret, errs, uses) ->
      let n = List.length ps and given = List.length args in
      if n <> given then
        Diag.error e.loc
          (sprintf "%s takes %d argument%s but was given %d" name n (plural n)
             given);
      List.iter2
        (fun p (a : expr) ->
          match (repr p, a.kind) with
          | TInout p, Ref place ->
              unify_at (result_loc place) ~found:(infer env cx place)
                ~expected:p
          | TInout _, _ ->
              let help =
                match a.kind with
                | Var x
                | Field ({ kind = Var x; _ }, _)
                | Index ({ kind = Var x; _ }, _) ->
                    sprintf "write `&` before it, as in `&%s`" x
                | _ -> "pass a variable, marked with `&`"
              in
              Diag.error a.loc ~help
                ~notes:[ "`&` shows at the call that the argument is changed" ]
                (sprintf "%s changes this argument, so it needs `&`" name)
          | _, Ref _ ->
              Diag.error a.loc ~help:"remove the `&`"
                ~notes:
                  [
                    "`&` marks an argument the call changes: an `inout` \
                     parameter";
                  ]
                (sprintf "%s doesn't change this argument" name)
          | _ -> unify_at (result_loc a) ~found:(infer env cx a) ~expected:p)
        ps args;
      absorb cx e.loc errs uses;
      ret
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         function, and its errors and dependencies become the caller's *)
      let arg (a : expr) =
        match a.kind with
        | Ref place -> TInout (infer env cx place)
        | _ -> infer env cx a
      in
      let ps = List.map arg args in
      let ret = fresh_var () in
      unify_at f.loc ~found:tf ~expected:(TFun (ps, ret, cx.errs, cx.uses));
      ret
  | t ->
      Diag.error f.loc
        (sprintf "%s is %s, not a function" name
           (article (show (printer ()) t)))

and infer_record env cx (e : expr) name fields =
  let given =
    List.map (fun ((f : ident), v) -> (f, v, infer env cx v)) fields
  in
  (* the record type [tn], checking each field's value against it *)
  let build tn =
    let td = Hashtbl.find env.types tn in
    let t, tvars = instance td in
    let decl = Option.get (record_fields env tn) in
    List.iter
      (fun ((f : ident), v, tv) ->
        let fd = List.find (fun d -> d.field_name.name = f.name) decl in
        unify_at (result_loc v) ~found:tv ~expected:(field_type ~tvars fd)
          ~notes:[ sprintf "`%s`'s field `%s`" tn f.name ])
      given;
    t
  in
  match name with
  | Some tn -> build tn.name
  | None -> (
      let names =
        List.sort String.compare
          (List.map (fun ((f : ident), _) -> f.name) fields)
      in
      let fits =
        records_where env (fun fs ->
            List.sort String.compare (List.map (fun f -> f.field_name.name) fs)
            = names)
      in
      match fits with
      | [ one ] -> build one
      | _ ->
          (* several types have exactly these fields: wait to see which one
             this record is used as *)
          let t = fresh_var () in
          let attempt () =
            match repr t with
            | TVar _ -> false
            | TCon (n, _) when List.mem n fits ->
                unify_at e.loc ~found:(build n) ~expected:t;
                true
            | _ ->
                unify_at e.loc ~found:(build (List.hd fits)) ~expected:t;
                true
          in
          let fail () =
            Diag.error e.loc
              ~help:
                (sprintf "write the type's name first, like `%s { ... }`"
                   (List.hd fits))
              (sprintf "these fields fit more than one type: %s" (quote fits))
          in
          env.deferred <- { attempt; fail } :: env.deferred;
          t)

and infer_field env cx (e : expr) r (f : ident) =
  let tr = infer env cx r in
  (* the field's type, once the record's type is known *)
  let resolve () =
    let pr = printer () in
    match repr tr with
    | TCon (n, args) as t -> (
        match record_fields env n with
        | None ->
            Diag.error f.loc
              (sprintf "`.%s` needs a record, but this is %s" f.name
                 (article (show pr t)))
        | Some decl -> (
            match List.find_opt (fun d -> d.field_name.name = f.name) decl with
            | Some fd ->
                let td = Hashtbl.find env.types n in
                let tvars =
                  List.map2
                    (fun (p : ident) a -> (p.name, a))
                    td.type_params args
                in
                field_type ~tvars fd
            | None ->
                Diag.error f.loc
                  ~help:
                    (sprintf "its fields: %s"
                       (quote (List.map (fun d -> d.field_name.name) decl)))
                  (sprintf "`%s` has no field named `%s`" n f.name)))
    | t ->
        Diag.error f.loc
          (sprintf "`.%s` needs a record, but this is %s" f.name
             (article (show pr t)))
  in
  match repr tr with
  | TVar _ -> (
      let has fs = List.exists (fun d -> d.field_name.name = f.name) fs in
      match records_where env has with
      | [] ->
          Diag.error f.loc
            (sprintf "no record type has a field named `%s`" f.name)
      | [ n ] ->
          unify_at r.loc ~found:tr
            ~expected:(fst (instance (Hashtbl.find env.types n)));
          resolve ()
      | candidates ->
          (* more than one record type has this field: wait until the rest
             of the code says which one this is *)
          let result = fresh_var () in
          let attempt () =
            match repr tr with
            | TVar _ -> false
            | _ ->
                unify_at e.loc ~found:(resolve ()) ~expected:result;
                true
          in
          let fail () =
            let what, help =
              match r.kind with
              | Var x ->
                  ( sprintf "`%s`" x,
                    sprintf "annotate `%s` where it's defined, like `%s: %s`" x
                      x (List.hd candidates) )
              | _ -> ("this", "add a type annotation to say which")
            in
            Diag.error r.loc ~help
              ~notes:
                [
                  sprintf "`%s` is a field of %s" f.name
                    (String.concat " and "
                       (List.map (sprintf "`%s`") candidates));
                ]
              (sprintf "can't tell which record type %s is" what)
          in
          env.deferred <- { attempt; fail } :: env.deferred;
          result)
  | _ -> resolve ()

(* Check a pattern against the type of the value it matches, and add the
   variables it binds. *)
and bind_pattern env locals t (p : pattern) =
  let check found =
    unify_at p.ploc ~found ~expected:t ~msg:(fun f x ->
        sprintf "expected a pattern for `%s`, but this one is %s" x (article f))
  in
  match p.pkind with
  | PWild -> locals
  | PVar x -> Env.add x t locals
  | PInt _ ->
      check int;
      locals
  | PBool _ ->
      check bool;
      locals
  | PCon (c, ps) ->
      let td, ctor = Hashtbl.find env.ctors c.name in
      let tc, tvars = instance td in
      check tc;
      List.fold_left2
        (fun locals fd sub ->
          bind_pattern env locals (field_type ~tvars fd) sub)
        locals ctor.ctor_fields ps

(* Retry deferred questions until none makes progress; whatever is still
   unanswered is an error. *)
let resolve_deferred env =
  let rec loop pending =
    let still = List.filter (fun d -> not (d.attempt ())) pending in
    if List.length still < List.length pending then loop still
    else match still with [] -> () | d :: _ -> d.fail ()
  in
  let pending = List.rev env.deferred in
  env.deferred <- [];
  loop pending

(* ---- the call graph ---- *)

let rec pattern_vars (p : pattern) =
  match p.pkind with
  | PVar x -> [ x ]
  | PWild | PInt _ | PBool _ -> []
  | PCon (_, ps) -> List.concat_map pattern_vars ps

(* The names [e] uses that aren't bound inside it. *)
let rec free bound (e : expr) acc =
  match e.kind with
  | Int _ | Bool _ | Unit -> acc
  | Var x -> if Names.mem x bound then acc else x :: acc
  | Unop (_, a) | Field (a, _) | Ref a -> free bound a acc
  | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ } ->
      free bound a (free bound b acc)
  | If (c, t, f) ->
      let acc = match f with Some f -> free bound f acc | None -> acc in
      free bound c (free bound t acc)
  | Array xs -> List.fold_left (fun acc x -> free bound x acc) acc xs
  | For { var; iter; body } ->
      free bound iter (free (Names.add var.name bound) body acc)
  | Call (f, args) ->
      List.fold_left (fun acc a -> free bound a acc) (free bound f acc) args
  | Lambda (ps, body) ->
      free
        (List.fold_left
           (fun b (p : param) -> Names.add p.pname.name b)
           bound ps)
        body acc
  | Block (stmts, last) ->
      let bound, acc =
        List.fold_left
          (fun (bound, acc) -> function
            | Let { name; value; _ } ->
                (Names.add name.name bound, free bound value acc)
            | Expr e -> (bound, free bound e acc))
          (bound, acc) stmts
      in
      free bound last acc
  | Con (_, args) ->
      List.fold_left (fun acc (_, a) -> free bound a acc) acc args
  | Record (_, fields) ->
      List.fold_left (fun acc (_, v) -> free bound v acc) acc fields
  | Match (s, arms) ->
      List.fold_left
        (fun acc a ->
          let bound =
            List.fold_left
              (fun b x -> Names.add x b)
              bound (pattern_vars a.arm_pat)
          in
          let acc =
            match a.arm_guard with Some g -> free bound g acc | None -> acc
          in
          free bound a.arm_body acc)
        (free bound s acc) arms

(* Group functions into strongly connected components of the call graph,
   callees before callers (Tarjan's algorithm, which finishes a component
   only after every component it reaches). *)
let components (fns : fn_def list) =
  let by_name = Hashtbl.create 16 in
  List.iter (fun f -> Hashtbl.replace by_name f.name.name f) fns;
  let callees (f : fn_def) =
    let bound =
      List.fold_left (fun b p -> Names.add p.pname.name b) Names.empty f.params
    in
    free bound f.body []
    |> List.sort_uniq String.compare
    |> List.filter_map (Hashtbl.find_opt by_name)
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

let check_transparent (f : fn_def) =
  let fn_params =
    List.filter_map
      (fun p ->
        match p.pty with Some (TyFn _) -> Some p.pname.name | _ -> None)
      f.params
  in
  List.iter
    (fun name ->
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
      let mentions e = List.mem name (free Names.empty e []) in
      (* [ok]: this position may hold the bare parameter, or a lambda that
         captures it *)
      let rec walk ~ok (e : expr) =
        let walk_all = List.iter (walk ~ok:false) in
        match e.kind with
        | Var x when x = name ->
            if not ok then fail e.loc "is used as a value here"
        | Int _ | Bool _ | Unit | Var _ -> ()
        | Call (callee, args) ->
            walk ~ok:true callee;
            List.iter (walk ~ok:true) args
        | Lambda (ps, body) ->
            if List.exists (fun (p : param) -> p.pname.name = name) ps then ()
            else if (not ok) && mentions body then
              fail e.loc "is captured by a lambda that outlives the call"
            else walk ~ok:false body
        | Unop (_, a) | Field (a, _) | Ref a -> walk_all [ a ]
        | Binop (_, a, b) | Index (a, b) | Assign { target = a; value = b; _ }
          ->
            walk_all [ a; b ]
        | If (c, t, f) -> walk_all (c :: t :: Option.to_list f)
        | Array xs -> walk_all xs
        | For { var; iter; body } ->
            walk_all [ iter ];
            if var.name <> name then walk ~ok:false body
        | Con (_, args) -> walk_all (List.map snd args)
        | Record (_, fields) -> walk_all (List.map snd fields)
        | Block (stmts, last) ->
            let rec go = function
              | [] -> walk ~ok:false last
              | Let { name = n; value; _ } :: rest ->
                  walk ~ok:false value;
                  if n.name <> name then go rest
              | Expr e :: rest ->
                  walk ~ok:false e;
                  go rest
            in
            go stmts
        | Match (s, arms) ->
            walk ~ok:false s;
            List.iter
              (fun a ->
                if not (List.mem name (pattern_vars a.arm_pat)) then (
                  Option.iter (walk ~ok:false) a.arm_guard;
                  walk ~ok:false a.arm_body))
              arms
      in
      walk ~ok:false f.body)
    fn_params

(* ---- signatures ---- *)

(* How `ren types` prints a function: the signature `ren fmt --annotate`
   would write. A row tail is printed (as `..e` / `..d`) only when it reaches
   the result; otherwise the parameter is transparent and the tail implied. *)
let signature (f : fn_def) scheme =
  match repr scheme with
  | TFun (ps, ret, errs, uses) ->
      let in_ret = row_vars ret in
      let pr = printer ~show_tail:(fun id -> List.mem id in_ret) () in
      reserve pr scheme;
      let params =
        List.map2
          (fun (p : param) t ->
            match repr t with
            | TInout t -> "inout " ^ p.pname.name ^ ": " ^ show pr t
            | t -> p.pname.name ^ ": " ^ show pr t)
          f.params ps
      in
      let ret = show_ret pr ret in
      let effects = show_effects pr errs uses in
      let tparams =
        match List.rev pr.order with
        | [] -> ""
        | names -> "<" ^ String.concat ", " names ^ ">"
      in
      sprintf "%sfn %s%s(%s)%s%s"
        (if f.pub then "pub " else "")
        f.name.name tparams
        (String.concat ", " params)
        ret effects
  | _ -> assert false

(* ---- the program ---- *)

(* The built-in functions and their type schemes. *)
let builtins () =
  let t = generic_var () in
  [
    (* fn<T>(T) uses Io *)
    ( "print",
      TFun
        ( [ generic_var () ],
          unit,
          generic_row (),
          RExtend ("Io", generic_row ()) ) );
    (* fn<T>(Array<T>) -> Int *)
    ( "len",
      TFun ([ array (generic_var ()) ], int, generic_row (), generic_row ()) );
    (* fn<T>(inout Array<T>, T) *)
    ( "push",
      TFun ([ TInout (array t); t ], unit, generic_row (), generic_row ()) );
  ]

(* Infer every function's type, and return each function's signature. *)
let program ~file (prog : program) =
  let env =
    {
      types = Hashtbl.create 16;
      ctors = Hashtbl.create 16;
      globals = Hashtbl.create 16;
      deferred = [];
    }
  in
  List.iter (fun (n, t) -> Hashtbl.replace env.globals n t) (builtins ());
  let fns = List.filter_map (function Fn f -> Some f | Type _ -> None) prog in
  List.iter
    (function
      | Type td -> (
          Hashtbl.replace env.types td.type_name.name td;
          match td.type_body with
          | Ctors cs ->
              List.iter
                (fun c -> Hashtbl.replace env.ctors c.ctor_name.name (td, c))
                cs
          | Fields _ -> ())
      | Fn _ -> ())
    prog;
  List.iter check_transparent fns;
  let schemes = Hashtbl.create 16 in
  List.iter
    (fun group ->
      enter_level ();
      (* each function's type within the group: its own type parameters
         (as skolems), parameters, result and effects *)
      let setup (f : fn_def) =
        let skolems =
          List.map (fun (t : ident) -> (fresh_id (), t.name)) f.tparams
        in
        let tparams = List.map (fun (id, n) -> (n, TSkol (id, n))) skolems in
        let cx =
          {
            locals = Env.empty;
            errs = fresh_row ();
            uses = fresh_row ();
            tparams;
          }
        in
        let ps = List.map (param_type cx) f.params in
        let ret =
          match f.ret with
          | Some t -> convert ~tvars:tparams ~row:closed t
          | None when f.pub ->
              unit (* a public function without `->` returns Unit *)
          | None -> fresh_var ()
        in
        Hashtbl.replace env.globals f.name.name
          (TFun (ps, ret, cx.errs, cx.uses));
        (f, skolems, cx, ps, ret)
      in
      let setups = List.map setup group in
      List.iter
        (fun ((f : fn_def), _, cx, ps, ret) ->
          let locals = bind_params Env.empty f.params ps in
          let tb = infer env { cx with locals } f.body in
          let pr = printer () in
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
          unify_at (result_loc f.body) ~found:tb ~expected:ret ~notes ?help)
        setups;
      resolve_deferred env;
      leave_level ();
      List.iter
        (fun ((f : fn_def), skolems, _, _, _) ->
          let mono = Hashtbl.find env.globals f.name.name in
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
              Diag.error f.name.loc
                ~notes:
                  [
                    sprintf
                      "`%s` and `%s` call each other, and functions that call \
                       each other are checked at a single type"
                      f.name.name o.name.name;
                  ]
                ~help:
                  (sprintf
                     "remove the type parameter from `%s`, or break the cycle"
                     o.name.name)
                (sprintf
                   "`%s` would have to use `%s`, the type parameter of `%s`"
                   f.name.name t o.name.name)
          | [] -> ());
          let scheme = generalize ~skolems mono in
          Hashtbl.replace env.globals f.name.name scheme;
          Hashtbl.replace schemes f.name.name scheme)
        setups;
      (* public functions spell out their full contract *)
      List.iter
        (fun ((f : fn_def), _, _, _, _) ->
          if f.pub then
            match Hashtbl.find schemes f.name.name with
            | TFun (ps, _, _, _) as scheme ->
                List.iter2
                  (fun (p : param) t ->
                    if p.pty = None then (
                      let pr = printer () in
                      reserve pr scheme;
                      Diag.error p.pname.loc
                        ~help:
                          (sprintf "write `%s: %s`" p.pname.name (show pr t))
                        ~notes:
                          [ "public functions spell out their full signature" ]
                        (sprintf
                           "the parameter `%s` of the public function `%s` has \
                            no type"
                           p.pname.name f.name.name)))
                  f.params ps
            | _ -> assert false)
        setups)
    (components fns);
  (match List.find_opt (fun (f : fn_def) -> f.name.name = "main") fns with
  | None ->
      Diag.error (Loc.point ~file 1 1)
        ~help:"add `fn main() = ...`, which is where the program starts"
        "this program has no `main` function"
  | Some f when f.params <> [] ->
      Diag.error (List.hd f.params).pname.loc ~help:"remove the parameters"
        "`main` can't take parameters"
  | Some _ -> ());
  List.map (fun f -> signature f (Hashtbl.find schemes f.name.name)) fns
