(* Inferring the types of expressions (see infer.ml for the whole pass).

   Inference is bidirectional (module-build.md, "In the compiler"). [infer]
   works out an expression's type from the expression alone. [check] also
   knows the type the expression is expected to have, and passes it down to
   where it helps: into a block's last line, an `if`'s branches and a
   `match`'s arms, to a lambda, which takes its parameters' types from it,
   and to a constructor or record literal, which is found through it. A
   call's arguments are checked left to right against the callee's
   parameter types, so what one argument settles is known to the next.

   Constructors, record fields, record literals without a type name and
   methods called with a dot, `s.push(1)`, are all found through a type, by
   one lookup (Infer_lookup.through_type) in the three steps of
   module-build.md. Nothing waits: a question that can't be answered where
   it's asked is an error that says which annotation would answer it, so
   the result never depends on the order inference happens to learn things
   in. An implementation of several dependencies, `Rates & RateCalls`, is
   narrowed to some of them only where [check]'s expected type is written
   ([narrow]), never where it's a variable inference has solved. Its own
   type is whatever inference knows of it there: types flow left to right,
   as in Rust and TypeScript (deps.md, "Implementations").

   As it goes, inference records every expression's and pattern's type by
   its node id, and what each lookup found. infer_top.ml hands the table on
   in canonical form, for the passes after it.

   This file is the core of it, [check] and [synth]. The rest is split by
   concern, into modules beside it: infer_env.ml has the types they all
   share, infer_report.ml reports a mismatch and explains it,
   infer_written.ml turns written types into the checker's,
   infer_lookup.ml finds things through a type, infer_rows.ml keeps
   track of what code fails with and uses, and infer_handlers.ml checks
   handlers and `with`. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env
open Infer_report
open Infer_written
open Infer_lookup
open Infer_rows
open Infer_handlers

(* ---- expressions ---- *)

let want_int env use (e : expr) t =
  unify_at env e.loc ~found:t ~expected:int ~notes:[ int_note use ]

let want_bool env use (e : expr) t =
  let help =
    match repr t with
    | TCon (p, _) -> not_bool_help p ~written:(env.source e)
    | _ -> None
  in
  unify_at env e.loc ~found:t ~expected:bool ~notes:[ bool_note use ] ?help

(* ---- sized types (sized.ml) ----

   A sized type, `UInt8`, is the type of a field, an array's element or a
   variable, never of what's computed with one: wherever an expression
   whose type is one is used, its value is read as its wide type, `Int`
   (or `Float`), the same number ([read_wide]); and wherever one is wanted,
   what's checked against it is checked against its wide type and stored
   into it, checked, or wrapped if it's what a wrapping operator made
   ([stored]). A value of one sized type is never a value of another, or
   the same type but through a type variable, so a type variable is only
   ever a sized type because a written type says so: `Array<UInt8>`, never
   because of a value. Each is recorded at the expression's node, for
   lowering ([Sized.coerce]). *)

(* The sized type [t] is, if it's one. *)
let sized_of t =
  match repr t with TCon (p, []) -> Sized.of_path p | _ -> None

let wide_of k = if Sized.is_float k then float else int
let sized_ty k = TCon (Sized.path k, [])

(* Record that the value of [node] is read as its wide type, [read], or
   stored into a sized type, [store], keeping what's recorded already. *)
let coerce cx node ?read ?store () =
  let c : Sized.coerce =
    Option.value
      (Hashtbl.find_opt cx.coerced node)
      ~default:{ read = None; store = None }
  in
  let c : Sized.coerce =
    {
      read = (match read with Some _ -> read | None -> c.read);
      store = (match store with Some _ -> store | None -> c.store);
    }
  in
  Hashtbl.replace cx.coerced node c

(* [e], of type [t], used as a value: if [t] is a sized type, it's read as
   its wide one. *)
let read_wide cx (e : expr) t =
  match sized_of t with
  | Some k ->
      coerce cx e.node ~read:k ();
      wide_of k
  | None -> t

(* The wrapping operator [e] is, by name, if it's one: `a +% b`, or the
   method it is, `a.wrapping_add(b)` (operators are methods), or `a.shl(k)`,
   which wraps by the same rule (foundations.md, decision 15). *)
let wrapping_op cx (e : expr) =
  match e.kind with
  | Binop (op, _, _, _) when is_wrapping op -> Some (binop_to_string op)
  | Call ({ kind = Field (_, m); node; _ }, _)
    when String.starts_with ~prefix:"wrapping_" m.name || m.name = "shl" -> (
      match Hashtbl.find_opt cx.found node with
      | Some (Method_of p) when p = Path.member (Path.prelude "Int") m.name ->
          Some m.name
      | _ -> None)
  | _ -> None

(* [e], which makes [t], where a value of the sized type [k] is wanted: it
   has to make [k]'s wide type, which is stored into [k], checked, or
   wrapped if a wrapping operator made it. A literal that can't fit is an
   error here. *)
let stored env cx why (e : expr) t k =
  let wide = wide_of k in
  let makes_wide =
    match repr t with
    | TVar { contents = Unbound _ } -> true
    | TCon (p, []) -> TCon (p, []) = wide
    | _ -> false
  in
  match repr t with
  | TError -> ()
  | _ when makes_wide ->
      ignore (unifies env why (result_loc e) ~found:t ~expected:wide);
      let wrap = wrapping_op cx e in
      (match wrap with
      | Some op when not (Sized.is_float k || Sized.wraps k) ->
          report env (wrapped_into_uint64 e.loc ~op)
      | _ -> ());
      let written = Option.value (env.source e) ~default:"" in
      (match e.kind with
      | Int n when (not (Sized.is_float k)) && not (Sized.fits k n) ->
          report env (literal_doesnt_fit e.loc k ~written)
      | Unop (Neg, { kind = Int n; _ }, _)
        when (not (Sized.is_float k)) && not (Sized.fits k (Int64.neg n)) ->
          report env (literal_doesnt_fit e.loc k ~written)
      | Float f when Sized.is_float k && Sized.float32 f = None ->
          report env (literal_doesnt_fit e.loc k ~written)
      | _ -> ());
      coerce cx e.node ~store:(k, wrap <> None) ()
  | _ ->
      ignore (unifies env why (result_loc e) ~found:t ~expected:(sized_ty k))

(* How to explain a mismatch with [expected], the type of a parameter of
   [callee]: when a statement of [callee] threw away a value whose type
   wasn't known, that made it `Unit`, and a `Unit` in [expected] may well be
   that one, which the caller can't see. So the mismatch points back at the
   statement. *)
let forced_why env callee expected =
  let rec has_unit t =
    match repr t with
    | TCon (p, args) -> p = Path.prelude "Unit" || List.exists has_unit args
    | TFun (ps, ret, _, _) ->
        List.exists (fun (p : param) -> has_unit p.ty) ps || has_unit ret
    | _ -> false
  in
  match callee with
  | Some c when has_unit expected ->
      let sites =
        List.filter_map
          (fun (f, loc) -> if f = c then Some loc else None)
          env.forced
      in
      let label loc = (loc, forced_unit (Path.local c)) in
      let help = forced_unit_help (Path.local c) in
      if sites = [] then plain
      else
        explain
          ~help:(fun _ _ -> help)
          ~labels:(fun _ _ -> List.map label sites)
          ()
  | _ -> plain

(* [e], of type [t], where a value of type [expected] is wanted, which is
   written: if [e] is an implementation of several dependencies, and
   [expected] one of some of them, it's narrowed to those there, which
   lowering is told. It still describes the same handler, but its other
   dependencies can't be reached through it (deps.md, "Implementations").
   Its type there, or else [t]. [t] is what inference knows of [e]'s type
   by now: a lambda's parameter that a generic's `T` gave a type to
   already is narrowed, one whose type comes later isn't. *)
let narrow env cx (e : expr) t expected =
  match (impl_parts t, impl_parts (reveal env.st expected)) with
  | Some (have, needs), Some (want, _)
    when List.length want < List.length have
         && List.for_all
              (fun d -> List.exists (fun h -> h.dpath = d.dpath) have)
              want ->
      Hashtbl.replace cx.narrowed e.node (List.map (fun d -> d.dpath) want);
      impl_type want needs
  | _ -> t

(* Whether [e] is made in branches, which [check] narrows one by one. *)
let branchy (e : expr) =
  match e.kind with Block _ | If (_, _, Some _) | Match _ -> true | _ -> false

(* A call of something that isn't known, because finding it was reported
   already: a name or a method that isn't there, or is private. It might
   have failed, so the `try` or `attempt` around it isn't reported as
   covering nothing, which would only follow from that first error, and
   whose help, to remove it, would be wrong once that's fixed. *)
let unknown_call cx = List.iter (fun m -> m.failed <- true) cx.markers

(* The row of a block's type that lists [listed], the dependencies its
   callee provides, and no more. *)
let listed_row listed = extend listed REmpty

(* A block written in [cx] at [loc], whose body [bcx] has been checked:
   what its body uses but [listed], what its parameter's type lists, is
   used where it's written, under the `with`s there, which the solver
   decides once the group is done, as for a `with`'s body
   (Solve.install). Its calls bring in what they bring in, but [listed]. *)
let block_uses env cx loc ~listed (bcx : ctx) =
  defer env
    (Install
       {
         wloc = loc;
         wdeps = listed;
         wbody = bcx.uses;
         wouter = cx.uses;
         wself = cx.self;
         wblock = true;
         wsrc = "";
       });
  cx.calls :=
    List.map
      (fun c -> { c with own = without_labels listed c.own })
      !(bcx.calls)
    @ !(cx.calls)

(* The arguments of the operation calls being checked, by node: each the
   operation, as it's written, `Tally.change`, and its dependency's path.
   A block written as one gets its dependencies only from its parameter's
   type ([op_block]); [applied] adds a call's arguments while it checks
   them. *)
let op_args : (int, string * Path.t) Hashtbl.t = Hashtbl.create 16

(* The calls in the body of each lambda, by node, which a `let` that binds
   one keeps for its local ([ctx.let_blocks]). *)
let lambda_calls : (int, call list ref) Hashtbl.t = Hashtbl.create 16

(* [e], a block passed to an operation if [op_args] says so, which lists
   [listed], what its parameter's type, [expected], lists: once the
   group's rows are decided, its [calls] bring in nothing else
   (compiler.md, "Operations that don't interleave", "No deadlock"). The
   operation holds its instance while it runs the block, so the block
   can't call back into it, nor into anything installed inside it, which
   an operation of that would wait for in the other order. Reported at the
   first call that brings one in. What each call brings in is what its
   callee's row had when it was met ([call]'s [own]); the block's own row
   can't say, since a block's row is joined to where it's written. *)
let op_block env (e : expr) ~listed ~expected ~calls =
  match Hashtbl.find_opt op_args e.node with
  | None -> ()
  | Some (op, dpath) ->
      defer env
        (Later
           (fun () ->
             let extra =
               without_labels listed (List.concat_map (fun c -> c.own) !calls)
             in
             if extra <> [] then
               let pos (l : Loc.t) = (l.start.line, l.start.col) in
               let calls =
                 List.sort (fun a b -> compare (pos a.cloc) (pos b.cloc)) !calls
               in
               let at, l =
                 match
                   List.find_map
                     (fun c ->
                       Option.map (fun l -> (c.cloc, l))
                         (List.find_opt (brings c) extra))
                     calls
                 with
                 | Some found -> found
                 | None -> (e.loc, List.hd extra)
               in
               let param =
                 match reveal env.st expected with
                 | TFun (ps, ret, errs, _) ->
                     show (printer env)
                       (TFun (ps, ret, errs, extend (listed @ [ l ]) REmpty))
                 | t -> show (printer env) t
               in
               report env
                 (op_block_uses at ~op ~dep:(shown_dep env l)
                    ~own:(l.name = Ty.dep_label dpath) ~param)))

(* [e]'s type, from [e] alone, as it's used: a sized type's value is read
   as its wide type ([read_wide]). *)
(* ---- by-name variants (compiler.md, "Data stage", "By-name variants") ---- *)

(* A constructor as it's written: `Rect`, or after its type,
   `Shape.Rect`. *)
let ctor_written env (c : ctor_ref) =
  match c.qual with
  | Some { tref = Named p; _ } -> type_name env p ^ "." ^ c.name.name
  | Some { tref = Param _; _ } | None -> c.name.name

(* [c] written by name, `Rect { w: 2, h: 3 }`: each of [fields] given the
   value written in its place, [shown], or `...` for one there's none for;
   a value that's the field's name is punned, `Rect { w, h }`. *)
let by_name c (fields : Iface.field list) shown =
  let field i (f : Iface.field) =
    match List.nth_opt shown i with
    | Some v when v = f.fname -> v
    | Some v -> f.fname ^ ": " ^ v
    | None -> f.fname ^ ": ..."
  in
  c ^ " { " ^ String.concat ", " (List.mapi field fields) ^ " }"

(* The pattern [c] of a by-name variant, written by name from its
   positional subpatterns, [ps]: a name that's its field's is punned, a
   `_` left out, with `..` at the end for the rest, and any other `f: p`.
   `Rect(w, tall)` is `Rect { w, h: tall }`; `Rect(w, _)` is `Rect { w,
   .. }`. *)
let pattern_by_name env c (fields : Iface.field list) (ps : pattern list) =
  let written = Ast.pattern_source ~type_name:(type_name env) in
  let named =
    List.filteri (fun i _ -> i < List.length ps) fields
    |> List.mapi (fun i (f : Iface.field) ->
           let q = List.nth ps i in
           match q.pkind with
           | PWild -> None
           | PVar b when b.ident.name = f.fname -> Some f.fname
           | _ -> Some (f.fname ^ ": " ^ written q))
  in
  let given = List.filter_map Fun.id named in
  let rest = List.length given < List.length fields in
  c ^ " { " ^ String.concat ", " (given @ if rest then [ ".." ] else []) ^ " }"

let rec infer env cx (e : expr) : ty = read_wide cx e (infer_raw env cx e)

(* [e]'s type, from [e] alone, as it's written: a place's, which a sized
   type's value is stored into, or a value passed with `&`. *)
and infer_raw env cx (e : expr) : ty =
  let t = synth env cx e in
  Hashtbl.replace cx.nodes e.node t;
  t

(* Check [e] against [expected], explaining a mismatch with [why]. When
   nothing is known about [expected] yet, that's inferring [e] and unifying
   the two. [written] is the type written where [e] is, an annotation or a
   declaration (Infer_written.is_written), usually [expected] itself: an
   implementation of several dependencies is narrowed to what it asks for
   ([narrow]). It's passed down only to the parts of it that are written
   too. A value of a sized type is read as its wide type, and one is
   stored into a sized type that's expected ([stored]), unless [exact]:
   a place passed with `&`, which has to be of the parameter's type. *)
and check env cx ?(why = plain) ?written ?(exact = false) (e : expr) expected =
  let leaf () =
    let t = synth env cx e in
    Hashtbl.replace cx.nodes e.node t;
    let t =
      match written with
      | Some w when impl_parts w <> None ->
          (* one that needs less than what's written will do too *)
          widen env ~loc:e.loc (narrow env cx e t w)
      | Some w -> narrow env cx e t w
      | None -> t
    in
    (* a variant type where its sum is wanted: the help writes the
       conversion of this value *)
    let why =
      match (repr t, repr expected) with
      | TVariant (p, c, _), TCon (q, _) when p = q && why.help = None ->
          let value = Option.value (env.source e) ~default:"p" in
          { why with help = Some (fun _ _ -> make_the_sum ~ctor:c ~value) }
      | _ -> why
    in
    match (sized_of t, sized_of expected) with
    | a, b when exact ->
        (* a place of a sized type is kept at its width, so it can't be
           changed as an `Int`, nor an `Int`'s as a sized type's *)
        let why =
          if a = None && b = None then why
          else
            explain
              ~notes:
                [
                  "an `inout` argument is changed where it's kept, so its type \
                   has to be the parameter's exactly";
                ]
              ~help:(fun _ _ ->
                "copy it into a `var` of the parameter's type, pass that, and \
                 store it back")
              ()
        in
        ignore (unifies env why (result_loc e) ~found:t ~expected)
    | Some a, Some b when a = b ->
        ignore (unifies env why (result_loc e) ~found:t ~expected)
    | _, Some k -> stored env cx why e (read_wide cx e t) k
    | _ ->
        ignore
          (unifies env why (result_loc e) ~found:(read_wide cx e t) ~expected)
  in
  let fits () = Hashtbl.replace cx.nodes e.node expected in
  (* the expected type, and what's written of it, go to where the value is
     made *)
  let branches () =
    fits ();
    match e.kind with
    | Block (stmts, last) ->
        ignore
          (block env cx stmts (fun cx ->
               check env cx ~why ?written last expected;
               expected))
    | If (c, t, Some f) ->
        want_bool env Condition c (infer env cx c);
        check env cx ~why ?written t expected;
        check env cx ~why ?written f expected
    | Match (subject, arms) ->
        ignore
          (infer_match env cx e.node subject arms
             ~want:(Some (expected, why, written)))
    | _ -> assert false
  in
  (* a constructor builds its sum, where its variant type is expected too
     (compiler.md, "Data stage", "Variant types") *)
  let built t =
    match (repr t, repr expected) with
    | TCon (p, _), TVariant (q, _, _) when p = q ->
        { why with notes = why.notes @ [ builds_the_sum ] }
    | _ -> why
  in
  match (e.kind, reveal env.st expected) with
  | Con (c, args), _ ->
      let t = infer_con env cx e c args ~written ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env (built t) e.loc ~found:t ~expected)
  | Con_named (c, fields), _ ->
      let t = infer_con_named env cx e c fields ~written ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env (built t) e.loc ~found:t ~expected)
  | Record (name, fields), _ ->
      let t = infer_record env cx e name fields ~written ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Update { target; base; fields }, _ ->
      let t = infer_update env cx e target base fields ~expected in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env (built t) e.loc ~found:t ~expected)
  (* a block, an `if` or a `match` passes a written type on to where its
     value is made, even where what's expected is still a variable, the
     payload of a constructor `Option<Rates>` is written for *)
  | (Block _ | If (_, _, Some _) | Match _), TVar _ when written <> None ->
      branches ()
  | Inline_handler lam, TImpl { deps = [ d ]; over = false; _ } ->
      (* where it's written says which dependency it implements *)
      let found = inline_handler core env cx e lam d in
      Hashtbl.replace cx.nodes e.node found;
      ignore (unifies env why e.loc ~found ~expected)
  | Var (Global _ | Intrinsic _ | Dep_op _), TVar _ ->
      (* where it's going isn't written, so it's given nothing *)
      named_block env cx ~why e REmpty expected
  | _, TVar _ -> leaf ()
  | Int n, (TCon (_, []) as t) when t = float && Option.is_none why.help ->
      (* an `Int` literal where a `Float` is wanted, `x.add(2)`: it's
         written as one, as for an operator's ([numbers_help]) *)
      let help _ _ = float_literal_help ~written:(sprintf "%Ld.0" n) in
      check env cx ?written e expected
        ~why:
          {
            why with
            notes = why.notes @ [ "numbers never convert by themselves" ];
            help = Some help;
          }
  | (Block _ | If (_, _, Some _) | Match _), _ -> branches ()
  | Var (Global _ | Intrinsic _ | Dep_op _), TFun (_, _, _, eu) ->
      named_block env cx ~why e eu expected
  | Var (Local b), TFun (_, _, _, eu)
    when why.help = None
         &&
         match Option.map (reveal env.st) (Hashtbl.find_opt cx.locals b.id) with
         | Some (TFun (_, _, _, u)) ->
             List.exists (fun l -> not (has_label u l)) (fst (row_parts eu))
         | _ -> false ->
      (* a block whose type lists less than its callee gives, which it
         can't take, since what it uses was found where it's written *)
      let param = Hashtbl.find_opt cx.binders b.id <> Some Let_bound in
      check env cx e expected
        ~why:
          {
            why with
            notes = why.notes @ [ block_lists_less ];
            help =
              Some
                (fun _ expected ->
                  block_lists_less_help ~name:b.ident.name ~param expected);
          }
  | Lambda (params, body), TFun (eps, eret, _, eu)
    when List.length eps = List.length params
         && List.for_all2
              (fun (p : Resolved.param) (ep : Types.param) -> p.pmode = ep.mode)
              params eps ->
      (* the parameters take their types from where the lambda is going,
         unless they're written; the whole type is unified with the expected
         one at the end, which also checks what the body fails with. It
         uses what the parameter's type lists, which the callee provides,
         and what else its body uses is found where it's written
         ([block_uses]) *)
      let ps =
        List.map2
          (fun (p : Resolved.param) ep ->
            if p.pty = None then ep
            else param_type env ~tparams:cx.tparams ~named:cx.named p)
          params eps
      in
      let listed = sorted_labels eu in
      let errs = fresh_row env.st and uses = fresh_row env.st in
      (* numbered before the lambdas in its body, as when it's inferred *)
      name_lambda ~given:listed cx e.node;
      bind_params cx params ps;
      let bcx = lambda_cx cx params ps ~errs ~uses in
      check env bcx body eret
        ?written:
          (match written with
          | Some (TFun (_, r, _, _)) when is_written r -> Some r
          | _ -> None)
        ~why:
          (explain ~notes:why.notes ?help:why.help
             ?narrowed_help:why.narrowed_help ~labels:why.labels
             ~msg:(Option.value why.produces ~default:lambda_produces) ());
      block_uses env cx e.loc ~listed bcx;
      op_block env e ~listed ~expected ~calls:bcx.calls;
      Hashtbl.replace lambda_calls e.node bcx.calls;
      let t = TFun (ps, eret, errs, listed_row listed) in
      Hashtbl.replace cx.nodes e.node t;
      ignore (unifies env why e.loc ~found:t ~expected)
  | Handler { deps; over; _ }, t
    when match impl_of t with
         | Some i ->
             List.map (fun d -> d.dpath) i.deps
             = List.sort_uniq compare
                 (List.map (fun d -> d.dpath) (handler_deps env cx deps))
             && i.over = over
         | None -> false ->
      (* what it's written to need, and more, which is reported once the
         group is done *)
      fits ();
      let i = Option.get (impl_of t) in
      let labels = fst (row_parts i.needs) in
      (* what it goes over is added once its body is checked (Handler) *)
      let own = List.map dep_of (handler_deps env cx deps) in
      let needs =
        extend
          (List.filter (fun (l : label) -> not (over && has_dep own l)) labels)
          (fresh_row env.st)
      in
      handler core env cx e ~own:i.deps ~needs ~fails:i.fails
        ~declared:(Some labels)
  | Tuple xs, TCon (p, parts)
    when p = Ty.tuple_path (List.length xs)
         && List.length parts = List.length xs ->
      (* each part where it's made, as an array's elements *)
      fits ();
      List.iter2
        (fun x part ->
          check env cx ~why:{ plain with notes = why.notes } x part)
        xs parts
  | Array xs, TCon (p, [ elem ]) when p = Path.prelude "Array" ->
      fits ();
      List.iter
        (fun x ->
          check env cx
            ~why:
              {
                plain with
                notes = why.notes;
                inside = (fun t -> why.inside (sprintf "Array<%s>" t));
              }
            ?written:
              (match written with
              | Some (TCon (_, [ w ])) when is_written w -> Some w
              | _ -> None)
            x elem)
        xs
  | _ -> leaf ()

(* [e], a top-level function, an intrinsic or an operation, passed where
   a block of type [expected] is wanted, which lists [eu]: it's a block
   written here, which calls it (Lower), so what it uses but what [eu]
   lists is found here, as for a lambda's body ([block_uses]). Its node
   keeps the function's own type, which the call in the block has. *)
and named_block env cx ~why (e : expr) eu expected =
  let t = infer env cx e in
  match reveal env.st t with
  | TFun (ps, ret, errs, uses) ->
      let listed = sorted_labels eu in
      name_lambda ~given:listed cx e.node;
      let callee = match e.kind with Var (Global p) -> Some p | _ -> None in
      let op = match e.kind with Var (Dep_op (_, o)) -> Some o | _ -> None in
      let calls =
        ref
          [
            {
              cloc = e.loc;
              own = fst (row_parts uses);
              row = uses;
              needs = false;
              callee;
              op;
            };
          ]
      in
      block_uses env cx e.loc ~listed { cx with uses; calls };
      op_block env e ~listed ~expected ~calls;
      ignore
        (unifies env why (result_loc e)
           ~found:(TFun (ps, ret, errs, listed_row listed))
           ~expected)
  | _ -> ignore (unifies env why (result_loc e) ~found:t ~expected)

(* The type of [e], not yet recorded. *)
and synth env cx (e : expr) : ty =
  match e.kind with
  | Int _ -> int
  | Float _ -> float
  | Bool _ -> bool
  | Str _ -> str
  | Unit -> unit
  | Var x -> lookup env cx ~node:e.node e.loc x
  | Named (_, a) -> infer env cx a
  | Tag_set es ->
      (* the tags `on: A | B` gives, those of a named set written out *)
      let names =
        List.sort_uniq compare
          (List.map (fun (l : Ty.label) -> l.name) (Iface.of_errors ~sets:env.sets es))
      in
      Hashtbl.replace cx.found e.node (Tags_given names);
      TCon (tags_path, [])
  | Unop (Neg, a, onode) ->
      operator env cx e ~onode ~meth:"neg" ~name:"-" a (infer env cx a) None
  | Unop (Not, a, _) ->
      want_bool env Negated a (infer env cx a);
      bool
  | Binop (op, a, b, onode) -> (
      let name = binop_to_string op in
      match op with
      | Add | Sub | Mul | Div | Mod | Wrap_add | Wrap_sub | Wrap_mul ->
          arith env cx e ~onode ~op ~name a (infer env cx a) (Some b)
      | Lt | Le | Gt | Ge ->
          (* the left side says what the right side has to be, and that
             has to have an order, which is known once the group's types
             are, as `==` is *)
          let ta = infer env cx a in
          compared env cx ~name a ta b;
          defer env
            (Compared { qty = ta; qloc = e.loc; qop = name; qreq = "ord" });
          bool
      | And | Or ->
          want_bool env (Side name) a (infer env cx a);
          want_bool env (Side name) b (infer env cx b);
          bool
      | Orelse ->
          (* the value in the `Option`, or else the right side, which is
             usually a `fail`, whose type is anything *)
          let v = fresh_var env.st in
          unify_at env (result_loc a) ~found:(infer env cx a)
            ~expected:(TCon (option_path, [ v ]))
            ~msg:orelse_left ~help:orelse_left_help;
          check env cx b v
            ~why:
              (explain ~msg:orelse_right
                 ~help:(fun _ _ -> orelse_right_help)
                 ());
          v
      | Eq | Neq ->
          (* the left side says what the right side has to be, and that
             has to have `==`, which is known once the group's types are *)
          let ta = infer env cx a in
          compared env cx ~name a ta b;
          defer env
            (Compared { qty = ta; qloc = e.loc; qop = name; qreq = "eq" });
          bool)
  | If (c, t, Some f) ->
      want_bool env Condition c (infer env cx c);
      let tt = infer env cx t in
      let else_why =
        explain ~msg:else_branch
          ~labels:(fun _ x -> [ (result_loc t, then_branch x) ])
          ~notes:[ if_branches ] ~narrowed_help:if_produces ()
      in
      check env cx f tt ~why:else_why;
      tt
  | If (c, t, None) ->
      want_bool env Condition c (infer env cx c);
      let ok =
        unifies env
          (explain ~msg:no_else ~help:(fun _ _ -> no_else_help) ())
          (result_loc t) ~found:(infer env cx t) ~expected:unit
      in
      (* if it was meant to produce a value, it isn't a `Unit` *)
      if ok then unit else TError
  | Call (f, args) -> infer_call env cx e f args
  | Lambda (params, body) ->
      let ps =
        List.map (param_type env ~tparams:cx.tparams ~named:cx.named) params
      in
      (* where it's going isn't known, so its callee provides nothing:
         everything its body uses is found where it's written *)
      let errs = fresh_row env.st and uses = fresh_row env.st in
      name_lambda cx e.node;
      bind_params cx params ps;
      let bcx = lambda_cx cx params ps ~errs ~uses in
      let tb = infer env bcx body in
      block_uses env cx e.loc ~listed:[] bcx;
      Hashtbl.replace lambda_calls e.node bcx.calls;
      TFun (ps, tb, errs, REmpty)
  | Block (stmts, last) -> block env cx stmts (fun cx -> infer env cx last)
  | Con (c, args) ->
      infer_con env cx e c args ~written:None ~expected:(fresh_var env.st)
  | Con_named (c, fields) ->
      infer_con_named env cx e c fields ~written:None
        ~expected:(fresh_var env.st)
  | Record (name, fields) ->
      infer_record env cx e name fields ~written:None
        ~expected:(fresh_var env.st)
  | Update { target; base; fields } ->
      infer_update env cx e target base fields ~expected:(fresh_var env.st)
  | Field (r, f) -> infer_field env cx e r f
  | Match (subject, arms) -> infer_match env cx e.node subject arms ~want:None
  | Array xs -> infer_array env cx xs
  | Tuple xs -> TCon (Ty.tuple_path (List.length xs), List.map (infer env cx) xs)
  | Index (a, i) -> (
      let ta = infer env cx a in
      match reveal env.st ta with
      | TCon (p, [ _; _ ]) when p = Path.prelude "Map" ->
          (* a key that isn't there is ordinary, so there's no `m[k]`
             (operators.md, "`Map` and `Set`") *)
          ignore (infer env cx i);
          report env (map_indexed e.loc ~map:(env.source a) ~key:(env.source i));
          TError
      | _ ->
          let elem = fresh_var env.st in
          let ok =
            unifies env
              (explain ~msg:not_indexable ())
              (result_loc a) ~found:ta ~expected:(array elem)
          in
          want_int env Indexing i (infer env cx i);
          if ok then elem else TError)
  | Slice (a, lo, hi) -> (
      (* `xs[a..b]`: a value of the type it slices (foundations.md,
         decision 17) *)
      let ta = infer env cx a in
      want_int env Indexing lo (infer env cx lo);
      want_int env Indexing hi (infer env cx hi);
      match reveal env.st ta with
      | TCon (p, []) when p = Path.prelude "Str" || p = Path.prelude "Bytes" ->
          ta
      | TError -> TError
      | _ ->
          let elem = fresh_var env.st in
          if
            unifies env
              (explain ~msg:not_sliceable ())
              (result_loc a) ~found:ta ~expected:(array elem)
          then array elem
          else TError)
  | Ref ({ kind = Call (f, args); _ } as call) ->
      (* `&s.push(1)`: a method call that changes its receiver *)
      let t = infer_call env cx ~changed:e.loc call f args in
      Hashtbl.replace cx.nodes call.node t;
      t
  | Ref a ->
      (* mut.ml allows `&` only on call arguments, `for` loops and method
         calls; the first two handle it themselves *)
      infer env cx a
  | Assign { target; op; value; onode } ->
      let tt =
        match target.kind with
        | Field (r, f) ->
            (* as [infer] would, but saying it's written to *)
            let t =
              field_access ~assigned:true env cx target r (infer env cx r) f
            in
            Hashtbl.replace cx.nodes target.node t;
            t
        | _ -> infer_raw env cx target
      in
      (match op with
      | Some op ->
          (* `x += v` puts `x + v` back in `x`, so it has to make what [x]
             holds: of a sized type, its wide type, which is stored back,
             wrapped if [op] is a wrapping operator (sized.ml) *)
          let name = binop_to_string op in
          let sized = sized_of tt in
          let tt = match sized with Some k -> wide_of k | None -> tt in
          (match sized with
          | Some k
            when is_wrapping op
                 && not (Sized.is_float k || Sized.wraps k) ->
              report env (wrapped_into_uint64 e.loc ~op:name)
          | _ -> ());
          let made = arith env cx e ~onode ~op ~name target tt (Some value) in
          let written =
            match (env.source target, env.source value) with
            | Some t, Some v -> Some (sprintf "%s %s= %s" t name v)
            | _ -> None
          in
          ignore
            (unifies env
               (explain
                  ~msg:(fun made held ->
                    match written with
                    | Some w -> op_assign_makes ~written:w ~made ~target:held
                    | None ->
                        op_assign_makes ~written:(name ^ "=") ~made ~target:held)
                  ())
               e.loc ~found:made ~expected:tt)
      | None ->
          (* a place whose type is written narrows what's assigned to it,
             as it does what it's made with *)
          let narrowed_help =
            match target.kind with
            | Var (Local b) when impl_parts tt <> None ->
                Some (assigned_var b.ident.name)
            | _ -> None
          in
          check env cx value tt
            ?written:(if written_place cx target then Some tt else None)
            ~why:(explain ~msg:assigned ?narrowed_help ()));
      unit
  | For { index; pat; over; body } ->
      let elem =
        match over with
        | Range (lo, hi) ->
            (* `0..n`: each `Int` from the first up to the second *)
            want_int env Ranging lo (infer env cx lo);
            want_int env Ranging hi (infer env cx hi);
            int
        | Each iter -> (
            let array_of = match iter.kind with Ref a -> a | _ -> iter in
            let ta = infer env cx array_of in
            Hashtbl.replace cx.nodes iter.node ta;
            (* a `Map` gives its entries, each a `(k, v)`, and a `Set` its
               members; anything else is an array *)
            let map_path = Path.prelude "Map"
            and set_path = Path.prelude "Set" in
            match (reveal env.st ta, iter.kind) with
            | TCon (p, [ _; _ ]), Ref _ when p = map_path ->
                report env (changes_entries iter.loc ~what:"map");
                TError
            | TCon (p, [ _ ]), Ref _ when p = set_path ->
                report env (changes_entries iter.loc ~what:"set");
                TError
            | TCon (p, [ k; v ]), _ when p = map_path ->
                TCon (Ty.tuple_path 2, [ k; v ])
            | TCon (p, [ x ]), _ when p = set_path -> x
            | TCon (p, _), _
              when p <> Path.prelude "Array" && op_of env ta "next" <> None ->
                cursor env cx iter ta
            | _ -> (
                let elem = fresh_var env.st in
                let ok =
                  unifies env
                    (explain ~msg:not_iterable ())
                    (result_loc array_of) ~found:ta ~expected:(array elem)
                in
                match (pat.pkind, iter.kind) with
                | (PTuple _ | PRecord _), Ref _ when ok ->
                    (* here, not in the parser, so that a map's own
                       message comes first, above *)
                    report env
                      (changed_taken_apart pat.ploc ~over:(env.source array_of));
                    TError
                | _ -> if ok then elem else TError))
      in
      bind_pattern ~binding:true env cx elem pat;
      (* the index is an `Int`, where the element is; a cursor has none *)
      Option.iter
        (fun (i : pattern) ->
          bind_pattern ~binding:true env cx int i;
          match over with
          | Each iter
            when match Hashtbl.find_opt cx.found iter.node with
                 | Some (Method_of _) -> true
                 | _ -> false ->
              report env
                (cursor_index i.ploc
                   ~index:
                     (match i.pkind with PVar b -> b.ident.name | _ -> "i"))
          | _ -> ())
        index;
      (match over with
      | Each ({ kind = Ref _; _ } as iter)
        when match Hashtbl.find_opt cx.found iter.node with
             | Some (Method_of _) -> true
             | _ -> false ->
          (* over a cursor, `for x in &c` changes `c`, not `x` *)
          Option.iter
            (fun (loc, name) -> report env (cursor_elem_changed loc name))
            (changes (pattern_binders pat) body)
      | _ -> ());
      (* each time round, the body's value is thrown away, as a
         statement's is *)
      dropped env cx (result_of body) (infer env cx body);
      unit
  | While { cond; body } ->
      want_bool env Condition cond (infer env cx cond);
      dropped env cx (result_of body) (infer env cx body);
      unit
  | Break ->
      (* it never produces a value, as `fail` doesn't *)
      fresh_var env.st
  | Fail ({ name = "Cancelled"; _ }, []) when env.in_finally > 0 ->
      (* in a `finally`: the cancel goes on, which no row has *)
      List.iter (fun m -> if m.mkind <> Mtry then m.failed <- true) cx.markers;
      fresh_var env.st
  | Fail (tag, args) ->
      (* anywhere else, it's refused, and checked as any other `fail`, so
         nothing else is said of it *)
      if tag.name = cancelled_tag then report env (fail_cancelled e.loc);
      (* the error joins whatever handles the code here, by inclusion, as
         a call's do, so the solver knows what an `attempt` around it
         fails with; a field's name in the payload only documents it *)
      let payload = List.map (fun (_, a) -> infer env cx a) args in
      let l =
        { name = tag.name; payload; dep = false; written = unmarked () }
      in
      include_errors env cx ~loc:e.loc ~here:(This "fail")
        ~sources:(fun () -> sources_of cx)
        ~fix:rename_fail (extend [ l ] REmpty) cx.handler;
      Option.iter (fun s -> s := Failed (e.loc, l) :: !s) cx.sources;
      List.iter (fun m -> if m.mkind <> Mtry then m.failed <- true) cx.markers;
      (* it never produces a value, so it can stand where any type is
         wanted *)
      fresh_var env.st
  | Try ({ kind = Match (subject, arms); _ } as a) when handles arms ->
      (* `try match`: the errors no arm handles are passed on. The arms
         aren't covered by the `try`: a call in one is marked like any
         other *)
      let m = marker env Mtry (keyword e.loc 3) in
      let t = infer_match env cx ~passed:m a.node subject arms ~want:None in
      Hashtbl.replace cx.nodes a.node t;
      t
  | Try a -> (
      let m = marker env Mtry (keyword e.loc 3) in
      (* the `try` around a group's test in a run of it, which needn't
         cover anything: the test may fail with nothing *)
      if e.node = Test_items.passed_on then m.failed <- true;
      let t = infer env { cx with markers = m :: cx.markers } a in
      (match (a.kind, Hashtbl.find_opt cx.found a.node) with
      | Con (_, [ (_, tag) ]), Some (Ctor_of (p, "Err")) when p = result_path ->
          (* `fail` is the way to fail with a tag written in place. A
             `Result` made with `Err` and kept in a `let` is passed on like
             any other (deps.md, "Deviations") *)
          report env (try_err e.loc (env.source tag))
      | _ -> ());
      (* `try r`, where [r] is a [Result]: what's in [r] if it's `Ok`, and
         if it's `Err`, its error again *)
      match reveal env.st t with
      | TCon (p, [ v; errs ]) when p = result_path -> (
          match repr errs with
          | TErrors errs
            when match row_skolem errs with
                 | Some (id, _) -> List.mem id env.finally_rows
                 | None -> false ->
              (* a `finally`'s `try r`: what it passes on is the `with`'s
                 body's error, which the `with` fails with already *)
              Hashtbl.replace cx.found e.node Unwrap;
              m.unwrapped <- errs :: m.unwrapped;
              v
          | TErrors errs ->
              (* a `finally`'s `try r` of a cancelled body goes on with the
                 cancel, which isn't an error *)
              let errs = without_cancelled errs in
              Hashtbl.replace cx.found e.node Unwrap;
              include_errors env cx ~loc:a.loc ~here:(This "Result")
                ~sources:
                  (sources_later cx ~this:(function
                    | Unwrapped (_, r) -> r == errs
                    | _ -> false))
                ~fix:rename_where_in errs cx.handler;
              m.unwrapped <- errs :: m.unwrapped;
              Option.iter
                (fun s -> s := Unwrapped (a.loc, errs) :: !s)
                cx.sources;
              v
          | _ -> t)
      | t ->
          m.hint <-
            (match a.kind with
            | With _ -> Some Installs_only
            | _ -> try_hint env cx a t);
          t)
  | Attempt a ->
      (* the calls it covers fail into its [Result] instead, and so does a
         `fail` *)
      let at = keyword e.loc 7 in
      let m = marker env Mattempt at in
      let kept = fresh_row env.st in
      defer env (Kept (kept, cx.params, Some at));
      let t =
        infer env { cx with handler = kept; markers = [ m ]; sources = None } a
      in
      TCon (result_path, [ t; TErrors kept ])
  | With { items; body } -> with_ core env cx e items body
  | Assert a ->
      want_bool env Asserted a (infer env cx a);
      unit
  | Handler { deps; over; any; _ } ->
      let needs = fresh_row env.st and fails = fresh_row env.st in
      let own = own_deps env cx ~any deps in
      handler core env cx e ~own ~needs ~fails ~declared:None;
      impl_type ~over ~fails own needs
  | Inline_handler lam ->
      (* which dependency it implements isn't known yet: what comes after
         may say, an element of an array whose first is a description, so
         it's checked once the function's body is (foundations.md,
         decision 3) *)
      let t = fresh_var env.st in
      cx.later :=
        (fun () ->
          match impl_of t with
          | Some { deps = [ d ]; over = false; _ } ->
              let found = inline_handler core env cx e lam d in
              ignore (unifies env plain e.loc ~found ~expected:t)
          | _ -> report env (inline_unknown e.loc))
        :: !(cx.later);
      t

(* `for x in &c` or `for x in c` over a cursor (foundations.md, decision
   12), [iter], of type [tc]: a value whose type has a method
   `next(inout self) -> Option<T>`, found as an operator is, by method on
   its type, which can't fail or use a dependency. Its elements are [T]s.
   The method's use is recorded at [iter], whose type is the cursor's, so
   lowering can call it each time round (lower.ml, [for_loop]). *)
and cursor env cx (iter : expr) tc =
  let td, o = Option.get (op_of env tc "next") in
  let path = op_path td o in
  if path.home = env.home && not (Hashtbl.mem env.globals path) then
    raise (Unchecked { caller = cx.self; callee = path });
  let tm = lookup env cx ~node:iter.node iter.loc (Global path) in
  Hashtbl.replace cx.found iter.node (Method_of path);
  let elem = fresh_var env.st in
  let shaped =
    o.okind = Method
    &&
    match repr tm with
    | TFun ([ self ], ret, errs, uses) -> (
        self.mode = Inout
        && row_names errs = []
        && row_names uses = []
        &&
        match repr ret with
        | TCon (p, [ _ ]) -> p = Path.prelude "Option"
        | _ -> false)
    | _ -> false
  in
  if
    shaped
    && unifies env plain iter.loc ~found:tm
         ~expected:
           (TFun
              ( [ { mode = Inout; ty = tc } ],
                TCon (Path.prelude "Option", [ elem ]),
                REmpty,
                REmpty ))
  then elem
  else (
    if not shaped then
      report env
        (not_a_cursor (result_loc iter) ~item:(type_name env td.path ^ ".next"));
    TError)

(* The binders of the pattern [p]. *)
and pattern_binders (p : pattern) =
  match p.pkind with
  | PVar b -> [ b ]
  | PAs (q, b) -> pattern_binders q @ [ b ]
  | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps ->
      List.concat_map pattern_binders ps
  | PRecord (_, fs) | PCon_named (_, fs) ->
      List.concat_map (fun (_, q) -> pattern_binders q) fs.fpats
  | PWild | PInt _ | PBool _ | PFail_any | PFail_in _ -> []

(* Where [e] first changes one of [bs], and which: an assignment to it, or
   a `&` of it. *)
and changes bs (e : expr) =
  let rec root (e : expr) =
    match e.kind with
    | Var (Local b) when List.memq b bs -> Some b.ident.name
    | Field (r, _) | Index (r, _) -> root r
    | Call ({ kind = Field (r, _); _ }, _) -> root r
    | _ -> None
  in
  match e.kind with
  | Assign { target; _ } when root target <> None ->
      Some (target.loc, Option.get (root target))
  | Ref a when root a <> None -> Some (e.loc, Option.get (root a))
  | _ -> List.find_map (changes bs) (children e)

(* Whether the place [target], assigned to, has a type that's written: a
   local whose is, a field, by its declaration, or an item of an array
   that's one of these and whose item type is written. *)
and written_place cx (target : expr) =
  match target.kind with
  | Var (Local b) -> Hashtbl.mem cx.written_locals b.id
  | Field _ -> is_written (Hashtbl.find cx.nodes target.node)
  | Index (a, _) -> (
      written_place cx a
      &&
      match Hashtbl.find_opt cx.nodes a.node with
      | Some (TCon (_, [ item ])) -> is_written item
      | _ -> false)
  | _ -> false

(* An array's items, [xs]: the first says what the others have to be. An
   implementation of several dependencies and one of some of them aren't
   the same type, and a written element type would narrow the first to
   the second (deps.md, "Implementations"), so that's what the message
   says to write, in a `let` of [name], if the array is one's value. *)
and infer_array env cx ?(name = "xs") xs =
  let elem = fresh_var env.st in
  (match xs with
  | [] -> ()
  | first :: rest ->
      let t1 = infer env cx first in
      ignore (unifies env plain (result_loc first) ~found:t1 ~expected:elem);
      let joined ds = shown_deps env ds in
      let mem d ds = List.exists (same_dep d) ds in
      List.iter
        (fun (x : expr) ->
          let why = explain ~msg:element_before () in
          match impl_parts elem with
          | None -> check env cx x elem ~why
          | Some (es, _) -> (
              let t = infer env cx x in
              match impl_parts t with
              | Some (ds, _)
                when (not (List.equal same_dep ds es))
                     && List.exists (fun d -> mem d es) ds ->
                  let part = List.filter (fun d -> mem d es) ds in
                  report env
                    (items_differ (result_loc x) ~this_ty:(joined ds)
                       ~first_loc:(result_loc first) ~first_ty:(joined es) ~name
                       ~part:(joined part))
              | _ ->
                  ignore
                    (unifies env why (result_loc x) ~found:t ~expected:elem)))
        rest);
  array elem

and stmt env cx = function
  | Let { name; ty; value; _ } ->
      Hashtbl.replace cx.binders name.id Let_bound;
      let t =
        match (ty, value.kind) with
        | Some ann, _ ->
            let t =
              convert env ~tvars:cx.tparams ~named:cx.named
                ~row:(fun () -> fresh_row env.st)
                ann
            in
            check env cx ~written:t value t;
            Hashtbl.replace cx.written_locals name.id ();
            t
        | None, Array xs ->
            let t = infer_array env cx ~name:name.ident.name xs in
            Hashtbl.replace cx.nodes value.node t;
            t
        | None, _ -> infer env cx value
      in
      Hashtbl.replace cx.locals name.id t;
      (* its calls were just kept, by [infer] or [check] *)
      (match value.kind with
      | Lambda _ ->
          Option.iter
            (Hashtbl.replace cx.let_blocks name.id)
            (Hashtbl.find_opt lambda_calls value.node)
      | _ -> ())
  | Let_pattern { pat; value; else_ = None } ->
      bind_pattern ~binding:true env cx (infer env cx value) pat
  | Let_pattern { pat; value; else_ = Some _ } ->
      (* a test, as an arm's is; [block] checks the `else` *)
      bind_pattern env cx (infer env cx value) pat
  | Expr e -> dropped env cx e (infer env cx e)
  | Finally f ->
      (* only among a handler's state ([Infer_handlers.handler]) or an
         arm's statements ([block]): anywhere else, Resolve reported it *)
      ignore (infer env cx f)

(* A block's statements, then what [last] makes of the rest of it, with
   what they bind: its type. A `finally` among them, in an operation's
   arm, covers the rest ([finally_stmt]). *)
and block env cx stmts (last : ctx -> ty) =
  match stmts with
  | [] -> last cx
  | Finally f :: rest ->
      finally_stmt env cx f (fun cx -> block env cx rest last)
  | (Let_pattern { else_ = Some e; _ } as s) :: rest ->
      (* the `else` leaves (Resolve), so it's of any type: the rest's,
         which a `match` of the two lowers to *)
      stmt env cx s;
      let t = block env cx rest last in
      check env cx e t;
      t
  | s :: rest ->
      stmt env cx s;
      block env cx rest last

(* `finally(r) => ...` in an operation's arm (handlers.md, "`finally`"),
   [f], and [rest], what comes after it: the rest is checked as `attempt`
   checks what it covers, its errors kept apart, and [r] is what it ends
   in, `Ok` of its value or `Err` of its error. What `finally` gives is
   the arm's value, and what it fails with, the arm's errors. *)
and finally_stmt env cx (f : expr) rest =
  match f.kind with
  | Lambda ([ p ], body) ->
      let kept = fresh_row env.st in
      defer env (Kept (kept, cx.params, None));
      let t = rest { cx with handler = kept; sources = None } in
      (* what it covers ends in, or `Err(Cancelled)` if that was
         cancelled *)
      let rt = TCon (result_path, [ t; TErrors (RExtend (cancelled (), kept)) ]) in
      let qs = [ { mode = Read; ty = rt } ] in
      name_lambda cx f.node;
      bind_params cx [ p ] qs;
      env.in_finally <- env.in_finally + 1;
      check env cx body t ~why:(explain ~msg:finally_gives ());
      env.in_finally <- env.in_finally - 1;
      Hashtbl.replace cx.nodes f.node (TFun (qs, t, cx.handler, REmpty));
      t
  | Lambda (ps, _) ->
      report env (finally_params f.loc (List.length ps));
      ignore (infer env cx f);
      rest cx
  | _ ->
      ignore (infer env cx f);
      rest cx

(* Keep [t], the type of a value [e] throws away, to be checked later
   (see [drop]). *)
and dropped env cx (e : expr) t =
  let rec call (e : expr) = match e.kind with Try a -> call a | _ -> e in
  let callee =
    match (call e).kind with
    | Call (f, _) | Ref { kind = Call (f, _); _ } -> (
        match f.kind with
        | Var x -> Some (short_of x)
        | Field (_, m) -> Some m.name
        | _ -> None)
    | _ -> None
  in
  defer env (Drop { dloc = e.loc; dty = t; callee; dself = cx.self })

(* ---- operators (operators.md) ----

   An operator is a method with a reserved name, `a + b` is `a.add(b)`,
   found on its left side's type and nowhere else, and chosen among that
   type's `add`s by its right side's type: the one place a name is
   defined more than once. Types flow left to right, so the left side's
   type is known first. It's one of:

   - a type variable, `a: T`: the operator is the one of the same type on
     both sides, so the right side is checked against the left, and the
     type needs it, `T has add`, which the solver decides once the
     group's types are known (Infer_reqs);
   - `Int` or `Float`, whose operators are the language's own, and take
     one of the same type: numbers never convert by themselves;
   - a `with numeric` type, which has `+`, `-` and `-a` of its own type
     and `*` by what it's represented as, and any other operator it
     writes;
   - any other type, whose method it is.

   In its own module an opaque type has its operators as anywhere else,
   the ones it writes and what `with numeric` gives, and where none of
   them takes the right side, it's what it's represented as (Types.
   reveal). Inside its own members it's always what it's represented as,
   which is what they're written in terms of: `self - t` in `Time.sub`
   subtracts two `Int`s, rather than calling itself. What it found is
   recorded at the operator's own node, [onode] (Ast.Binop). *)

(* The name of the type an operator method takes on its right, which
   tells it apart from the type's other operators of its name. *)
and right_head (o : Iface.op) =
  match o.oscheme.ty with
  | Fun ([ _; { ty = Con (q, _); _ } ], _, _, _) -> Some q
  | _ -> None

(* [t] as a type of the checker's, from a type a declaration writes with
   none of its parameters in it. *)
and of_decl (t : Ty.ty) =
  of_ty ~vars:(fun _ -> TError) ~tails:(fun _ -> REmpty) t

(* The operator methods [meth] the type [p] writes. *)
and op_overloads env p meth =
  match Hashtbl.find_opt env.types p with
  | Some td ->
      List.filter
        (fun (_, (o : Iface.op)) -> o.okind = Method)
        (Iface.find_members td meth)
  | None -> []

(* Whether [p], a `with numeric` type, has the operator [meth] itself,
   given the right side's type [tb], if it has one: `+` and `-` of its own
   type, `*` by its representation's, and `-a`. *)
and numeric_takes env p meth tb =
  match (Infer_reqs.numeric env p, meth, Option.map (fun t -> repr t) tb) with
  | Some _, "neg", None -> true
  | Some _, ("add" | "sub"), Some (TCon (q, _)) -> q = p
  | Some rep, "mul", Some (TCon (q, _)) -> TCon (q, []) = of_decl rep
  | _ -> false

(* The arithmetic operator [op], written [name], on [a], of type [ta],
   and [b]: a wrapping one is `Int`'s ([wrapping]), and any other is
   found on [ta] ([operator]). *)
and arith env cx (e : expr) ~onode ~op ~name (a : expr) ta b =
  match (binop_method op, wrapping_method op) with
  | Some meth, _ -> operator env cx e ~onode ~meth ~name a ta b
  | None, Some meth -> wrapping env cx e ~onode ~meth ~name a ta b
  | None, None -> assert false

(* `a +% b`, the wrapping operator [name], the method [meth] of `Int`,
   `wrapping_add`, on [a], of type [ta], and [b]: `Int`'s only, so it's
   that method, which wraps at 64 bits; stored into a sized type it wraps
   at that type's width instead ([stored]). *)
and wrapping env cx (e : expr) ~onode ~meth ~name (a : expr) ta b =
  let infer_b () = Option.map (fun b -> (b, infer env cx b)) b in
  match repr ta with
  | TError ->
      ignore (infer_b ());
      TError
  | TVar { contents = Unbound _ } | TCon (_, []) ->
      if
        match repr ta with
        | TCon (p, []) -> TCon (p, []) = int
        | _ -> unifies env plain a.loc ~found:ta ~expected:int
      then
        op_method env cx e ~onode a int (infer_b ())
          (Path.member (Path.prelude "Int") meth)
      else (
        ignore (infer_b ());
        report env (no_wrapping e.loc ~shown:(show (printer env) ta) ~op:name);
        TError)
  | t ->
      ignore (infer_b ());
      report env (no_wrapping e.loc ~shown:(show (printer env) t) ~op:name);
      TError

(* The operator [name], `+`, the method [meth], `add`, on [a], of type
   [ta], and [b], the right side, if it has one: the type it makes. *)
and operator env cx (e : expr) ~onode ~meth ~name (a : expr) ta b =
  let found f = Hashtbl.replace cx.found onode f in
  let done_ t =
    Hashtbl.replace cx.nodes onode t;
    t
  in
  let pr = printer env in
  (* the right side is inferred once, when it's first needed *)
  let b_inferred = lazy (Option.map (fun b -> (b, infer env cx b)) b) in
  let infer_b () = Lazy.force b_inferred in
  (* the left side's type, seen as an operator sees it: one of the
     module's own opaque types is what it's represented as unless it has
     an operator of its own that takes the right side *)
  let left =
    match repr ta with
    | TCon (p, _) as t when Hashtbl.mem env.st.reps p ->
        let in_its_members = cx.self.member <> None && Path.owner cx.self = p in
        let tb = Option.map snd (infer_b ()) in
        let written =
          match Option.map repr tb with
          | Some (TCon (q, _)) ->
              List.exists
                (fun (_, o) -> right_head o = Some q)
                (op_overloads env p meth)
          | Some _ -> false
          | None -> op_overloads env p meth <> []
        in
        if (not in_its_members) && (written || numeric_takes env p meth tb) then
          t
        else reveal env.st ta
    | _ -> reveal env.st ta
  in
  match left with
  | TError ->
      ignore (infer_b ());
      TError
  | (TVar _ | TSkol _) as t ->
      (* in generic code, an operator is the one of the same type on both
         sides *)
      Option.iter
        (fun b ->
          check env cx b ta
            ~why:
              (explain
                 ~msg:(fun found left ->
                   sprintf "`%s` has no `%s` that takes %s" left name
                     (code found))
                 ~notes:
                   [
                     "in generic code, an operator takes one of the same type \
                      on both sides";
                   ]
                 ()))
        b;
      defer env (Compared { qty = t; qloc = e.loc; qop = name; qreq = meth });
      found (Generic_op meth);
      done_ ta
  | TCon (p, []) as t when Infer_reqs.is_number p ->
      (* one that doesn't take the right side makes nothing, so what
         it's used as isn't checked against it, a second error *)
      let takes =
        match infer_b () with
        | Some (b, tb) -> numbers env e ~meth ~name a t b tb
        | None -> true
      in
      found Builtin_op;
      done_ (if takes then t else TError)
  | TCon (p, _) as t -> (
      let left = show pr t in
      let numeric = Infer_reqs.numeric env p in
      (* another module's opaque type, which may be used here as though
         it were what it's represented as *)
      let hidden =
        match Hashtbl.find_opt env.types p with
        | Some { body = Opaque (Hidden _); _ } when not (own env p) -> Some p
        | _ -> None
      in
      (* the module's own, seen from a test *)
      let hidden_own = hidden <> None && p.home = env.home in
      let overloads = op_overloads env p meth in
      let numeric_takes tb = numeric_takes env p meth tb in
      let builtin () =
        found Builtin_op;
        done_ ta
      in
      match infer_b () with
      | None when numeric_takes None -> builtin ()
      | None -> (
          match overloads with
          | [ (path, _) ] -> op_method env cx e ~onode a ta None path
          | _ ->
              report env
                (no_op ?hidden ~test:hidden_own e.loc ~shown:left ~op:name
                   ~by:None ~uses:None);
              TError)
      | Some (b, tb) -> (
          (* the overload that takes [tb]'s type, by its type's name *)
          let head = right_head in
          let taking q =
            List.find_opt (fun (_, o) -> head o = Some q) overloads
          in
          let right = show pr tb in
          let no_taking () =
            match (numeric, meth, repr tb) with
            | Some _, "mul", TCon (q, _) when q = p ->
                report env
                  (numeric_mul e.loc ~left
                     ~rep:(show pr (of_decl (Option.get numeric))))
            | Some _, ("div" | "rem"), _ when overloads = [] ->
                report env
                  (numeric_div e.loc ~left
                     ~rep:(show pr (of_decl (Option.get numeric)))
                     ~op:name ~meth)
            | _, _, _ when overloads = [] && numeric = None ->
                report env
                  (no_op ?hidden ~test:hidden_own e.loc ~shown:left ~op:name
                     ~by:None ~uses:None)
            | Some rep, ("mul" | "div"), _
              when literal_scale env ~name rep a b <> None ->
                (* `w * 2` scales a `Float` one by a `Float`, as `x * 2`
                   on a plain `Float` would *)
                report env
                  (no_op_taking e.loc ~left ~op:name ~right ~numbers:true
                     ?help:(literal_scale env ~name rep a b)
                     ())
            | Some rep, ("add" | "sub"), _
              when literal_made env ~name ~right:true p rep a b tb <> None ->
                report env
                  (no_op_taking e.loc ~left ~op:name ~right ~numbers:false
                     ?help:(literal_made env ~name ~right:true p rep a b tb)
                     ())
            | _ ->
                report env
                  (no_op_taking e.loc ~left ~op:name ~right ~numbers:false
                     ?help:(swapped env ~meth ~name p a tb b)
                     ())
          in
          (* one it writes, `mul(self, b: Meters) -> Area`, comes before
             what `with numeric` gives *)
          match repr tb with
          | TError -> TError
          | TCon (q, _) when taking q <> None -> (
              match taking q with
              | Some (path, _) ->
                  op_method env cx e ~onode a ta (Some (b, tb)) path
              | None -> TError)
          | _ when numeric_takes (Some tb) -> builtin ()
          | TCon _ ->
              no_taking ();
              TError
          | _ -> (
              (* the right side's type isn't known yet: if there's only
                 one, it's that one's *)
              match (overloads, numeric) with
              | [ (path, _) ], None ->
                  op_method env cx e ~onode a ta (Some (b, tb)) path
              | [], None ->
                  no_taking ();
                  TError
              | _, Some _ when meth = "add" || meth = "sub" ->
                  unify_at env b.loc ~found:tb ~expected:ta;
                  builtin ()
              | _, Some rep when meth = "mul" && overloads = [] ->
                  unify_at env b.loc ~found:tb ~expected:(of_decl rep);
                  builtin ()
              | _ ->
                  report env (which_overload e.loc ~left ~op:name);
                  TError)))
  | t ->
      ignore (infer_b ());
      report env (no_op e.loc ~shown:(show pr t) ~op:name ~by:None ~uses:None);
      TError

(* `a op b` on [Int]s or [Float]s, [ta] [a]'s type: [b], of type [tb],
   has to be the same, since numbers never convert by themselves. In its
   own module an opaque type is what it's represented as. Whether it's
   one the operator takes, [false] having said it isn't. *)
and numbers env (e : expr) ~meth ~name (a : expr) ta (b : expr) tb =
  let pr = printer env in
  match (repr ta, reveal env.st tb) with
  | TCon (p, _), TCon (q, _) when p <> q ->
      let left = show pr ta and right = show pr (reveal env.st tb) in
      let is_numbers = Infer_reqs.is_number q in
      let help =
        if is_numbers then numbers_help env ~name ~left a b
        else
          match Infer_reqs.numeric env q with
          | Some rep when meth = "add" || meth = "sub" ->
              (* `5 + price`: the number is made one of the right side's
                 type *)
              literal_made env ~name ~right:false q rep a b ta
          | _ -> swapped env ~meth ~name p a tb b
      in
      report env
        (no_op_taking e.loc ~left ~op:name ~right ~numbers:is_numbers ?help ());
      false
  | _ ->
      unify_at env b.loc ~found:tb ~expected:ta ~msg:(fun found left ->
          sprintf "`%s` has no `%s` that takes %s" left name (code found));
      true

(* The help for `a op b` where [a]'s type, [p], has no [meth] taking
   [b]'s, [tb], but [tb]'s has one taking [p]'s: write it the other way
   round. Only for `+` and `*`, which don't care which side is which. A
   `with numeric` type's `*` takes what it's represented as, so
   `3 * price` is `price * 3`. *)
and swapped env ~meth ~name p (a : expr) tb (b : expr) =
  match repr tb with
  | TCon (q, _) when meth = "add" || meth = "mul" -> (
      let written =
        match Hashtbl.find_opt env.types q with
        | Some td ->
            List.exists
              (fun (_, o) -> right_head o = Some p)
              (Iface.find_members td meth)
        | None -> false
      in
      let numeric =
        match Infer_reqs.numeric env q with
        | Some _ when q = p -> true
        | Some rep when meth = "mul" -> repr (of_decl rep) = TCon (p, [])
        | _ -> false
      in
      match (written || numeric, env.source a, env.source b) with
      | true, Some sa, Some sb ->
          Some (swap_help ~written:(sprintf "%s %s %s" sb name sa))
      | _ -> None)
  | _ -> None

(* What to write for `w * 2`, where [a] is a `with numeric` type
   represented as a `Float`, [rep], and [b] an [Int] literal: what's
   scaled by is a `Float`, so the literal is written as one, `w * 2.0`. *)
and literal_scale env ~name rep (a : expr) (b : expr) =
  match (repr (of_decl rep), b.kind, env.source a) with
  | t, Int n, Some sa when t = float ->
      Some (float_literal_help ~written:(sprintf "%s %s %Ld.0" sa name n))
  | _ -> None

(* The ways to make one of the `with numeric` type [p], represented as
   [rep], of [b], of type [tb]: by each of [p]'s public functions that
   takes one of [rep] and gives a [p], in source order, `Money.cents(5)`.
   Choosing the unit is the point, so each is given. [b] is a literal
   number, written as [rep] is, `2.0` for a `Float`, or any other
   expression whose type is [rep], `Money.cents(k)`. Empty if [p] has
   none of those functions, or [b] can't be a [rep]. *)
and made_of env p rep (b : expr) tb =
  let written =
    match (repr (of_decl rep), b.kind) with
    | t, Int n when t = int -> Some (Int64.to_string n)
    | t, Int n when t = float -> Some (sprintf "%Ld.0" n)
    | t, Float f when t = float -> Some (Ast.show_float f)
    | t, _ when reveal env.st tb = t -> env.source b
    | _ -> None
  in
  let makes (o : Iface.op) =
    match (o.okind, o.oscheme.ty) with
    | Function, Fun ([ x ], Con (q, []), _, _) ->
        o.opub && q = p && x.mode = Read && x.ty = rep
    | _ -> false
  in
  match (written, Hashtbl.find_opt env.types p) with
  | Some w, Some td ->
      List.map
        (fun (o : Iface.op) -> sprintf "%s.%s(%s)" (env.names p) o.oname w)
        (List.filter makes (Iface.members td))
  | _ -> []

(* What to write for `a op b`, where one side is of the `with numeric`
   type [p] and the other, [b] if [right] or else [a], is what it's
   represented as, [rep], of type [tb]: `price + 5` is `price +
   Money.cents(5)`, `5 + price` is `Money.cents(5) + price`, and
   `Money.cents(1) < k` is `Money.cents(1) < Money.cents(k)` ([made_of]).
   [None] if there's no way to make one of it. *)
and literal_made env ~name ~right p rep (a : expr) (b : expr) tb =
  let other = if right then b else a in
  match (made_of env p rep other tb, env.source a, env.source b) with
  | (_ :: _ as made), Some sa, Some sb ->
      Some
        (made_help ~ty:(env.names p)
           (List.map
              (fun m ->
                if right then sprintf "%s %s %s" sa name m
                else sprintf "%s %s %s" m name sb)
              made))
  | _ -> None

(* What to write for `a op b` on an [Int] and a [Float], [left] [a]'s
   type: a literal written as the other number, `2.0`, or else one of
   them converted. *)
and numbers_help env ~name ~left (a : expr) (b : expr) =
  match (env.source a, env.source b, a.kind, b.kind) with
  | Some sa, Some _, _, Int n ->
      Some (float_literal_help ~written:(sprintf "%s %s %Ld.0" sa name n))
  | Some _, Some sb, Int n, _ ->
      Some (float_literal_help ~written:(sprintf "%Ld.0 %s %s" n name sb))
  | Some sa, Some sb, _, _ when left = "Float" ->
      Some (convert_help ~written:(sprintf "%s %s Float.of(%s)" sa name sb))
  | Some sa, Some sb, _, _ ->
      Some (convert_help ~written:(sprintf "Float.of(%s) %s %s" sa name sb))
  | _ -> None

(* `a op b`, a comparison, [ta] [a]'s type: [b] has to be the same type.
   An [Int] and a [Float] never convert by themselves, which is said, as
   it is for arithmetic ([numbers]). *)
and compared env cx ~name (a : expr) ta (b : expr) =
  let why ?(notes = []) ?help () =
    explain ~msg:(compares name)
      ~labels:(fun _ x -> [ (a.loc, this_is x) ])
      ~notes
      ?help:(Option.map (fun h _ _ -> h) help)
      ()
  in
  match repr ta with
  | TCon (p, []) when Infer_reqs.is_number p -> (
      let tb = infer env cx b in
      match reveal env.st tb with
      | TCon (q, []) when Infer_reqs.is_number q && q <> p ->
          let left = show (printer env) ta in
          let help = numbers_help env ~name ~left a b in
          ignore
            (unifies env
               (why ~notes:[ "numbers never convert by themselves" ] ?help ())
               (result_loc b) ~found:tb ~expected:ta)
      | TCon (q, []) as t when Infer_reqs.numeric env q <> None ->
          (* `5 < price`: the number is made one of the right side's
             type *)
          let help =
            literal_made env ~name ~right:false q
              (Option.get (Infer_reqs.numeric env q))
              a b ta
          in
          ignore
            (unifies env (why ?help ()) (result_loc b) ~found:t ~expected:ta)
      | _ -> ignore (unifies env (why ()) (result_loc b) ~found:tb ~expected:ta)
      )
  | TCon (p, []) when Infer_reqs.numeric env p <> None ->
      (* `price < 5`: the other side is made one of [p] *)
      let tb = infer env cx b in
      let help =
        literal_made env ~name ~right:true p
          (Option.get (Infer_reqs.numeric env p))
          a b tb
      in
      ignore (unifies env (why ?help ()) (result_loc b) ~found:tb ~expected:ta)
  | _ -> check env cx b ta ~why:(why ())

(* The operator [e] is [path], a method of [a]'s type, `Time.sub`, used
   at the node [onode]: [a] is its `self`, and [b] its other operand, if
   it has one, of type [tb]. A method of the module not checked yet is
   checked first, as a dot call's is (Infer_env.Unchecked). *)
and op_method env cx (e : expr) ~onode (a : expr) ta b path =
  if path.home = env.home && not (Hashtbl.mem env.globals path) then
    raise (Unchecked { caller = cx.self; callee = path });
  let tm = lookup env cx ~node:onode e.loc (Global path) in
  Hashtbl.replace cx.nodes onode tm;
  Hashtbl.replace cx.found onode (Method_of path);
  match repr tm with
  | TFun (self :: ps, ret, _, _) -> (
      blame_at cx onode
        ((self.ty, a.loc)
        ::
        (match (ps, b) with
        | [ p ], Some ((b : expr), _) -> [ (p.ty, b.loc) ]
        | _ -> []));
      unify_at env a.loc ~found:ta ~expected:self.ty;
      match (ps, b) with
      | [ p ], Some (b, tb) ->
          unify_at env b.loc ~found:tb ~expected:p.ty;
          ret
      | [], None -> ret
      | _ -> TError)
  | _ -> TError

(* A call. One with a dot, `x.m(...)`, can be a method call, found through
   [x]'s type: as a field is, by [through_type], except that a method can
   be in a type of any kind, not only a record. [changed] is where the `&`
   is, if it's `&x.m(...)`. *)
and infer_call env cx ?changed ?tr (e : expr) (f : expr) args =
  match f.kind with
  | Field (r, m) -> (
      (* [tr] is the receiver's type, if it's inferred already; one of
         several dependencies' is the one that has [m] *)
      let tr = match tr with Some t -> t | None -> infer env cx r in
      let tr = member_of_several env cx r tr m in
      (* `r.m` is a field holding a function *)
      let field_call () =
        let tf = field_access env cx f r tr m in
        Hashtbl.replace cx.nodes f.node tf;
        let t = apply env cx e ~name:(Some m.name) f tf args in
        match changed with
        | Some loc ->
            (* as for a method, below: only the `&` is reported *)
            report env (not_changed loc ~recv:(env.source r) m.name);
            TError
        | None -> t
      in
      let nothing () =
        unknown_call cx;
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        TError
      in
      match (op_of env tr m.name, reveal env.st tr) with
      | None, TImpl ({ deps = [ d ]; _ } as i)
        when match Hashtbl.find_opt env.types d.dpath with
             | Some td -> dep_op_in env m.name td <> None
             | None -> false ->
          desc_method env cx e f r m i d args
      | Some (td, o), _ -> method_call env cx ?changed e f r m tr td o args
      | None, TError -> nothing ()
      | None, TVariant (p, c, args')
        when op_of env (TCon (p, args')) m.name <> None
             && not
                  (List.exists
                     (fun (d : Iface.field) -> d.fname = m.name)
                     (snd (variant_ctor env p c)).cfields) ->
          (* the sum's method: a variant type has none of its own, and
             calling the sum's would be a conversion no one wrote
             (compiler.md, "Data stage", "Variant types") *)
          let recv = Option.value (env.source r) ~default:"p" in
          let recv = if String.contains recv ' ' then "(" ^ recv ^ ")" else recv in
          report env
            (variant_no_methods m.loc ~shown:(show (printer env) tr) ~ctor:c
               ~recv ~name:m.name);
          nothing ()
      | None, (TCon (p, _) as t)
        when Option.bind (known_decl env t) (field_in m.name) = None ->
          let td = Hashtbl.find env.types p in
          let shown = show (printer env) tr in
          (match td.body with
          | Dep ops -> report env (op_of_value ~names:env.names ?recv:(env.source r) m p ops)
          | _
            when Infer_reqs.numeric env p <> None
                 && List.mem_assoc m.name numeric_operators ->
              (* `with numeric` gives the operator, with no method of that
                 name behind it *)
              let op = List.assoc m.name numeric_operators in
              let written =
                match (env.source r, List.map env.source args) with
                | Some sr, [] -> Some (op ^ sr)
                | Some sr, [ Some sa ] -> Some (sprintf "%s %s %s" sr op sa)
                | _ -> None
              in
              report env (numeric_method m ~shown ~op ~written)
          | _ when (not (own env p)) && p.home <> Path.prelude_home ->
              let test = env.client && op_in m.name td <> None in
              let d = no_public_method ~test m ~shown p in
              (* a test calling a private method: at the first use only *)
              if test then report_test_once env (Path.member p m.name) d
              else report env d
          | _ ->
              (* an operator written for several types on its right is
                 named once *)
              let methods =
                List.fold_left
                  (fun acc (o : Iface.op) ->
                    if o.okind = Method && not (List.mem o.oname acc) then
                      acc @ [ o.oname ]
                    else acc)
                  []
                  ((if own env p then Iface.members else Iface.public_members)
                     td)
              in
              (* an `Array`, a `Str` or `Bytes` is sliced with an index,
                 `s[0..2]`, as `s.slice(0, 2)` once was *)
              let slice =
                match (env.source r, List.map env.source args) with
                | Some sr, [ Some a; Some b ]
                  when List.mem p.name [ "Array"; "Str"; "Bytes" ]
                       && p.home = Path.prelude_home ->
                    let sr =
                      match r.kind with
                      | Var _ | Field _ | Index _ | Slice _ | Call _ | Str _ -> sr
                      | _ -> "(" ^ sr ^ ")"
                    in
                    Some (sprintf "%s[%s..%s]" sr a b)
                | _ -> None
              in
              report env
                (no_method ?slice m ~shown ~own:(own env p)
                   ~type_name:(type_name env p) methods));
          nothing ()
      | None, TVar _
        when List.exists (fun td -> op_in m.name td <> None) env.visible -> (
          (* step 2: the one visible type with a field or an item of that
             name *)
          let fits td =
            match (op_in m.name td, field_in m.name td) with
            | Some o, _ -> Some (Some o)
            | None, Some _ -> Some None
            | None, None -> None
          in
          match through_type env ~known:None ~fits with
          | Found (td, Some o) ->
              let t, _ = instance env td in
              unify_at env r.loc ~found:tr ~expected:t;
              method_call env cx ?changed e f r m tr td o args
          | Found (_, None) | Nowhere -> field_call ()
          | Several paths ->
              let what =
                match r.kind with
                | Var x -> Some (Infer_msg.Named (name_of x))
                | _ -> None
              in
              report env
                (several_have_member ~names:env.names r.loc ?what m
                   (List.map (fun p -> (p, member_kind env m.name p)) paths));
              nothing ())
      | None, TVar _
        when not
               (List.exists (fun td -> field_in m.name td <> None) env.visible)
        -> (
          (* it may be a method of a type the module can't name bare *)
          let elsewhere =
            Hashtbl.fold
              (fun p td acc ->
                match op_in m.name td with
                | Some { okind = Method; _ } -> p :: acc
                | _ -> acc)
              env.types []
            |> List.sort compare
          in
          match elsewhere with
          | [] -> field_call ()
          | _ ->
              let what =
                match r.kind with
                | Var x -> Some (Infer_msg.Named (name_of x))
                | _ -> None
              in
              report env
                (no_type_has_method ~names:env.names ~can_name:env.can_name
                   ?what m elsewhere);
              nothing ())
      | None, _ -> field_call ())
  | _ -> call_with env cx e f (infer env cx f) args

(* `d.op(args)`, the call [e] of [f], where [d] is [r], a description of
   the dependency [dep], whose type is [i], and [op] one of its operations
   (foundations.md, decision 3): `with d in Dep.op(args)`, the arguments
   evaluated first, outside. So it fails with what the operation declares,
   and uses what [d]'s type says it needs, which the `with` would: never
   [dep] itself, which [d] provides. One whose state can fail to start, or
   that goes over another, is only installed. *)
and desc_method env cx (e : expr) (f : expr) (r : expr) (m : ident) (i : impl)
    (d : dep) args =
  let recv = Option.value (env.source r) ~default:"it" in
  let shown = shown_deps env [ d ] in
  let call = sprintf "%s.%s(%s)" shown m.name (if args = [] then "" else "...") in
  let refuse diag =
    report env diag;
    unknown_call cx;
    List.iter (fun a -> ignore (infer_arg env cx a)) args;
    TError
  in
  if i.over then refuse (method_over m.loc ~recv ~dep:shown ~call)
  else if fst (row_parts i.fails) <> [] then
    refuse (method_fails m.loc ~recv ~call)
  else
    (* the operation as declared, at [d]'s type arguments: its node keeps
       that, as a dependency's call does, for lowering *)
    match lookup env cx ~node:f.node m.loc (Dep_op (d.dpath, m.name)) with
    | TFun (ps, ret, errs, (RExtend (l, _) as uses)) ->
        if List.length l.payload = List.length d.dargs then
          List.iter2
            (fun t a -> unify_at env r.loc ~found:a ~expected:t)
            l.payload d.dargs;
        Hashtbl.replace cx.nodes f.node (TFun (ps, ret, errs, uses));
        Hashtbl.replace cx.found f.node
          (Calls_op { key = dep_of d; from = d.dpath; op = m.name });
        let needs = copy_needs env ~loc:e.loc ~what:Installing i.needs in
        apply env cx e ~name:(Some m.name) f (TFun (ps, ret, errs, needs)) args
    | _ -> refuse (op_of_value ~names:env.names ~recv m d.dpath [])

(* The call [e] of [f], which isn't a method, once [f]'s type [tf] is
   known. *)
and call_with env cx (e : expr) (f : expr) tf args =
  let name = callee_name f in
  let target =
    match f.kind with
    | Var (Global p) when group_call env p -> Some p
    | _ -> None
  in
  let callee = match f.kind with Var (Global p) -> Some p | _ -> None in
  apply env cx e ~name ?target ?callee f tf args

(* `r.m(args)`, the call [e] of [f], where [m] is the member [o] of
   [r]'s type [td]: a method is called with [r] as its `self`. [tr] is
   [r]'s type. *)
and method_call env cx ?changed (e : expr) (f : expr) r (m : ident) tr td o args
    =
  let recv = env.source r in
  let item = type_name env td.path ^ "." ^ o.oname in
  let nothing () =
    unknown_call cx;
    List.iter (fun a -> ignore (infer_arg env cx a)) args;
    TError
  in
  match o.okind with
  | Function | Value ->
      report env (not_a_method m o.okind ~item (List.map env.source args));
      nothing ()
  | Method when List.length (Iface.find_members td o.oname) > 1 -> (
      (* an operator written for several types on its right, called by
         name, `t.sub(d)`: the one that takes its argument's type, as
         `t - d` would be *)
      let pr = printer env in
      match args with
      | [ a ] -> (
          let ta = infer env cx a in
          match repr ta with
          | TError -> TError
          | TCon (q, _) -> (
              match
                List.find_opt
                  (fun (_, o) -> right_head o = Some q)
                  (Iface.find_members td o.oname)
              with
              | Some (path, _) ->
                  op_method env cx e ~onode:f.node r tr (Some (a, ta)) path
              | None ->
                  report env
                    (no_op_taking e.loc ~left:(show pr tr) ~op:("." ^ o.oname)
                       ~right:(show pr ta) ~numbers:false ());
                  TError)
          | _ ->
              report env
                (which_overload e.loc ~left:(show pr tr) ~op:("." ^ o.oname));
              TError)
      | _ ->
          report env (wrong_arity_overload e.loc ~name:o.oname);
          nothing ())
  | Method -> (
      let path = op_path td o in
      if path.home = env.home && not (Hashtbl.mem env.globals path) then
        raise (Unchecked { caller = cx.self; callee = path });
      let tm = lookup env cx ~node:f.node f.loc (Global path) in
      Hashtbl.replace cx.nodes f.node tm;
      Hashtbl.replace cx.found f.node (Method_of path);
      match repr tm with
      | TFun (self :: ps, ret, errs, uses) -> (
          (* the arguments first, so `&m.set(k, v)` blames the key it's
             given, rather than the map *)
          let given =
            if List.length ps = List.length args then
              List.map2
                (fun (p : Types.param) (a : expr) -> (p.ty, a.loc))
                ps args
            else []
          in
          blame_args cx f (given @ [ (self.ty, r.loc) ]);
          (* a shift by a literal amount it can't be by panics every
             time: an error where it's written, as a literal that
             doesn't fit is *)
          (if
             path = Path.member (Path.prelude "Int") "shl"
             || path = Path.member (Path.prelude "Int") "shr"
           then
             match args with
             | [ ({ kind = Int _ | Unop (Neg, { kind = Int _; _ }, _); _ } as a) ]
               ->
                 let k =
                   match a.kind with
                   | Unop (_, { kind = Int k; _ }, _) -> Int64.neg k
                   | Int k -> k
                   | _ -> 0L
                 in
                 if Int64.compare k 0L < 0 || Int64.compare k 63L > 0 then
                   report env (shift_out_of_range a.loc ~op:o.oname ~k)
             | _ -> ());
          (* a dependency's method takes an implementation that needs less
             than its `self` allows, as an argument does *)
          unify_at env r.loc ~found:(widen env ~loc:r.loc tr) ~expected:self.ty;
          (match (self.mode, changed) with
          | Inout, None ->
              report env (needs_amp e.loc ~recv ~call:(env.source e) o.oname)
          | Inout, Some _ | Read, _ -> ());
          let t =
            apply env cx e ~name:(Some o.oname)
              ?target:(if group_call env path then Some path else None)
              ~callee:path
              ~written:(written_params env ~callee:path ~skip:1 tm ps)
              f
              (TFun (ps, ret, errs, uses))
              args
          in
          match (self.mode, changed) with
          | Read, Some loc ->
              (* what it returns is the `&`'s mistake, so it isn't also
                 reported as thrown away *)
              let pr = printer env in
              let returns =
                match repr t with
                | TCon (p, []) when p = Path.prelude "Unit" -> None
                | TError | TVar _ -> None
                | _ -> Some (show pr t)
              in
              let keep =
                match (recv, env.source e) with
                | Some r, Some call when show pr t = show pr tr ->
                    Some (sprintf "%s = %s" r call)
                | _ -> None
              in
              report env (not_changed loc ~recv ?returns ?keep o.oname);
              TError
          | _ -> t)
      | _ -> nothing ())

(* What the callee [f] of a call needs of a type argument is blamed on
   the first of its arguments it's in, if one is, given as each one's
   parameter's type and the argument's location, before they're checked
   (Infer_env.required). A method's receiver comes first. *)
and blame_args cx (f : expr) args = blame_at cx f.node args

(* The same, for the use at [node]. *)
and blame_at cx node args =
  (* the first argument whose type [is_in] says has it *)
  let blame r is_in vars =
    List.filter_map
      (fun (id, v) ->
        if List.mem_assoc id r.uat then None
        else
          List.find_map
            (fun (t, loc) -> if is_in v t then Some (id, loc) else None)
            args)
      vars
  in
  (* a row variable is in a type if its tail is one of the type's *)
  let row_in r t =
    match row_tail r with Some id -> List.mem id (row_vars t) | None -> false
  in
  Option.iter
    (fun r ->
      r.uat <- r.uat @ blame r mentions r.uinst;
      r.uat <- r.uat @ blame r row_in r.urows)
    (Hashtbl.find_opt cx.required node)

(* The call [e] of [f], a function of type [tf]; [name] says which, for
   messages, [target] which function of the group it is, if it's one, and
   [callee] which top-level function it is, if it's one. [written] says
   which of its parameters have a type written, if the caller knows
   better than [tf] (Infer_written.written_params). *)
and apply env cx (e : expr) ~name ?target ?callee ?written (f : expr) tf args =
  let ds =
    match callee with
    | Some p -> Option.value (Hashtbl.find_opt env.defaults_of p) ~default:[]
    | None -> []
  in
  match (ds, reveal env.st tf, callee) with
  | _ :: _, TFun (ps, _, _, _), Some p -> (
      match with_defaults env cx e ~name ~callee:p ds ps args with
      | Some args -> applied env cx e ~name ?target ?callee ?written f tf args
      | None ->
          List.iter
            (fun (a : expr) ->
              match a.kind with
              | Named (_, v) -> ignore (infer_arg env cx v)
              | _ -> ignore (infer_arg env cx a))
            args;
          TError)
  | _ -> applied env cx e ~name ?target ?callee ?written f tf args

(* The arguments of [e], a call of [callee], whose parameters [ps] have
   defaults [ds] (Infer_env.defaults_of), in its parameters' order: the
   positional ones fill the parameters without defaults, in order, a
   trailing block the last; one with a default is given by name or left
   out, when it's its default, a literal at a node of its own; and a
   parameter of `Tags` keeps its argument by name, which [tags_call]
   reads. [None] once it's reported that they don't fit (compiler.md,
   "Stage 11a", "The surface"). *)
and with_defaults env cx (e : expr) ~name ~callee ds (ps : Types.param list)
    args =
  let n = List.length ps in
  let fn = Path.short callee in
  let pnames =
    match Hashtbl.find_opt env.params_of callee with
    | Some (_ :: rest as all) -> if List.length all = n + 1 then rest else all
    | Some [] | None -> []
  in
  let default_at i = List.find_opt (fun (j, _, _) -> j = i) ds in
  let tags_at i = is_tags (List.nth ps i).ty in
  let named =
    List.filter_map
      (fun (a : expr) ->
        match a.kind with Named (nm, v) -> Some (a, nm, v) | _ -> None)
      args
  in
  let positional =
    List.filter (fun (a : expr) -> match a.kind with Named _ -> false | _ -> true) args
  in
  (* the names a call may give, in order *)
  let by_name =
    List.concat
      (List.init n (fun i ->
           match default_at i with
           | Some (_, d, _) -> [ d ]
           | None when tags_at i -> Option.to_list (List.nth_opt pnames i)
           | None -> []))
  in
  let tags_unnamed =
    pnames = [] && List.exists (fun (p : Types.param) -> is_tags p.ty) ps
  in
  let required =
    List.filter (fun i -> default_at i = None && not (tags_at i)) (List.init n Fun.id)
  in
  let src (a : expr) = Option.value (env.source a) ~default:"..." in
  match
    List.find_opt
      (fun (_, (nm : ident), _) ->
        not (List.mem nm.name by_name || tags_unnamed))
      named
  with
  | Some (_, nm, _) ->
      report env (no_param_named nm.loc ~fn ~given:nm.name ~names:by_name);
      None
  | None when List.length positional > List.length required ->
      (* the first one past those without a default, before a trailing
         block, is one given by position *)
      let block_last =
        match List.rev required with
        | i :: _ -> i = n - 1 && (match repr (List.nth ps i).ty with TFun _ -> true | _ -> false)
        | [] -> false
      in
      let k = List.length required - if block_last then 1 else 0 in
      let extra = List.nth positional k in
      let left =
        List.find_opt
          (fun (_, d, _) -> not (List.exists (fun (_, (nm : ident), _) -> nm.name = d) named))
          ds
      in
      (match left with
      | Some (_, d, _) ->
          report env (default_by_position extra.loc ~param:d ~arg:(src extra))
      | None ->
          report env
            (wrong_arity e.loc name (List.length required) (List.length positional)));
      None
  | None when List.length positional < List.length required ->
      report env
        (wrong_arity e.loc name (List.length required) (List.length positional));
      None
  | None ->
      let rest = ref positional in
      let args =
        List.concat
          (List.init n (fun i ->
               match default_at i with
               | Some (_, d, lit) -> (
                   match
                     List.find_opt (fun (_, (nm : ident), _) -> nm.name = d) named
                   with
                   | Some (_, _, v) -> [ v ]
                   | None ->
                       let kind : expr_kind =
                         match lit with
                         | LInt k -> Int k
                         | LFloat x -> Float x
                         | LBool b -> Bool b
                         | LStr s -> Str s
                       in
                       [ { kind; loc = e.loc; node = default_node e.node i } ])
               | None when tags_at i ->
                   List.filter_map
                     (fun ((a : expr), (nm : ident), _) ->
                       if
                         List.nth_opt pnames i = Some nm.name
                         || (tags_unnamed && not (List.exists (fun (_, d, _) -> d = nm.name) ds))
                       then Some a
                       else None)
                     named
               | None -> (
                   match !rest with
                   | a :: more ->
                       rest := more;
                       [ a ]
                   | [] -> [])))
      in
      Hashtbl.replace cx.found e.node (Args args);
      Some args

(* [apply], once the arguments are in order. *)
and applied env cx (e : expr) ~name ?target ?callee ?written (f : expr) tf args =
  let ename = Option.value name ~default:"this" in
  let named (a : expr) = match a.kind with Named _ -> true | _ -> false in
  match reveal env.st tf with
  | TFun (ps, ret, errs, uses)
    when List.exists (fun (p : Types.param) -> is_tags p.ty) ps
         || List.exists named args ->
      tags_call env cx e ~name ?target ?callee f tf (ps, ret, errs, uses) args
  | TFun (ps, ret, errs, uses) ->
      let n = List.length ps and given = List.length args in
      if n <> given then (
        (* still check the arguments, for errors of their own *)
        List.iter (fun a -> ignore (infer_arg env cx a)) args;
        report env (wrong_arity e.loc name n given);
        TError)
      else (
        blame_args cx f
          (List.map2
             (fun (p : Types.param) (a : expr) -> (p.ty, a.loc))
             ps args);
        let written =
          match written with
          | Some w -> w
          | None -> written_params env ?callee tf ps
        in
        (* a block passed to an operation gets its dependencies only from
           its parameter's type ([op_block]) *)
        let op =
          match (f.kind, Hashtbl.find_opt cx.found f.node) with
          | Var (Dep_op (p, o)), _ | _, Some (Calls_op { from = p; op = o; _ }) ->
              Some (Option.value name ~default:o, p)
          | _ -> None
        in
        Option.iter
          (fun op -> List.iter (fun (a : expr) -> Hashtbl.replace op_args a.node op) args)
          op;
        Fun.protect
          ~finally:(fun () ->
            if op <> None then
              List.iter (fun (a : expr) -> Hashtbl.remove op_args a.node) args)
          (fun () ->
            check_args env cx ~name ?callee ~written ps args;
            (* a block bound by `let` and passed here brings in only what
               the parameter's type lists, as one written here does *)
            if op <> None then
              List.iter2
                (fun (p : Types.param) (a : expr) ->
                  match (a.kind, reveal env.st p.ty) with
                  | Var (Local b), TFun (_, _, _, eu) -> (
                      match Hashtbl.find_opt cx.let_blocks b.id with
                      | Some calls ->
                          op_block env a ~listed:(sorted_labels eu)
                            ~expected:p.ty ~calls
                      | None -> ())
                  | _ -> ())
                ps args);
        absorb env cx ~call:e ~ename ~fn:f ?target ?callee errs uses;
        if keyed_described env cx ?callee args then made env ret else TError)
  | TVar _ ->
      (* a parameter whose type isn't known yet: calling it says it's a
         block, whose errors are the call's. Its type isn't written, so it
         lists no dependencies: the block finds them where it's written *)
      let ps = List.map (infer_arg env cx) args in
      let ret = fresh_var env.st in
      let errs = fresh_row env.st in
      unify_at env f.loc ~found:tf ~expected:(TFun (ps, ret, errs, REmpty));
      absorb env cx ~call:e ~ename ~fn:f errs REmpty;
      ret
  | TError ->
      unknown_call cx;
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      TError
  | t ->
      List.iter (fun a -> ignore (infer_arg env cx a)) args;
      report env (not_a_function f.loc name (show (printer env) t));
      TError

(* A call [e] of [f], of type [tf], of parameters [ps], a parameter of
   `Tags` among them, or given an argument by name (compiler.md, "`over
   any` and `retry`"): a parameter of `Tags` is given its tags by its
   name, `on: Flaky | Broken`, or passed one on, `on: on`, and it's the
   only parameter given by name. The rest are checked as any call's are.
   Each tag given is one the call can fail with, which is checked once
   the group's rows are decided. *)
and tags_call env cx (e : expr) ~name ?target ?callee (f : expr) tf
    (ps, ret, errs, uses) args =
  let ename = Option.value name ~default:"this" in
  let fn =
    match (callee, name) with
    | Some p, _ -> Path.short p
    | None, Some n -> n
    | None, None -> "this"
  in
  let pnames =
    match callee with
    | Some p -> Option.value (Hashtbl.find_opt env.params_of p) ~default:[]
    | None -> []
  in
  let pname i = List.nth_opt pnames i in
  let src (a : expr) = Option.value (env.source a) ~default:"..." in
  let tags (p : Types.param) = is_tags p.ty in
  let written = written_params env ?callee tf ps in
  let n = List.length ps and given = List.length args in
  let ntags = List.length (List.filter tags ps) in
  let named (a : expr) = match a.kind with Named _ -> true | _ -> false in
  (* the parameters and arguments that aren't of `Tags`, checked as any
     call's *)
  let rest_checked ps written args =
    check_args env cx ~name ?callee ~written ps args;
    absorb env cx ~call:e ~ename ~fn:f ?target ?callee errs uses
  in
  if ntags > 0 && given = n - ntags && not (List.exists named args) then (
    (* no `on:` at all: the help writes it, with what the call can fail
       with, once the other arguments say *)
    let kept = List.filter (fun (p, _) -> not (tags p)) (List.combine ps written) in
    rest_checked (List.map fst kept) (List.map snd kept) args;
    let at = ref 0 and parts = ref [] and param = ref "on" in
    let can = List.sort_uniq compare (row_names errs) in
    List.iteri
      (fun i (p : Types.param) ->
        if tags p then (
          param := Option.value (pname i) ~default:"on";
          parts :=
            !parts
            @ [
                sprintf "%s: %s" !param
                  (match can with [] -> "..." | can -> String.concat " | " can);
              ])
        else (
          (match List.nth_opt args !at with
          | Some { kind = Lambda _; _ } -> ()
          | Some a -> parts := !parts @ [ src a ]
          | None -> ());
          incr at))
      ps;
    report env
      (tags_missing e.loc ~fn ~param:!param
         ~call:(fn ^ "(" ^ String.concat ", " !parts ^ ")"));
    made env ret)
  else if n <> given then (
    List.iter
      (fun (a : expr) ->
        match a.kind with
        | Named (_, { kind = Tag_set _; _ }) -> ()
        | Named (_, v) -> ignore (infer_arg env cx v)
        | _ -> ignore (infer_arg env cx a))
      args;
    report env (wrong_arity e.loc name n given);
    TError)
  else
    let given_tags = ref [] in
    let kept =
      List.concat
        (List.mapi
           (fun i (((p : Types.param), w), (a : expr)) ->
             let param = Option.value (pname i) ~default:"on" in
             match (tags p, a.kind) with
             | true, Named (nm, v) ->
                 if pname i <> None && nm.name <> param then
                   report env (tags_misnamed nm.loc ~given:nm.name ~param);
                 (match v.kind with
                 | Tag_set _ -> (
                     ignore (infer env cx v);
                     match Hashtbl.find_opt cx.found v.node with
                     | Some (Tags_given names) ->
                         given_tags := (v.loc, param, names) :: !given_tags
                     | _ -> ())
                 | _ -> check env cx v p.ty);
                 Hashtbl.replace cx.nodes a.node p.ty;
                 []
             | true, _ ->
                 report env (tags_unnamed a.loc ~fn ~param ~arg:(src a));
                 []
             | false, Named (nm, v) ->
                 report env (named_not_tags nm.loc ~name:nm.name ~arg:(src v));
                 [ ((p, w), v) ]
             | false, _ -> [ ((p, w), a) ])
           (List.combine (List.combine ps written) args))
    in
    rest_checked
      (List.map (fun ((p, _), _) -> p) kept)
      (List.map (fun ((_, w), _) -> w) kept)
      (List.map snd kept);
    (* each tag it's given is one the call can fail with, once the
       group's rows are decided *)
    let what =
      if List.exists (fun (a : expr) -> match a.kind with Lambda _ -> true | _ -> false) args
      then "the block"
      else sprintf "`%s(...)`" fn
    in
    List.iter
      (fun (loc, param, names) ->
        defer env
          (Later
             (fun () ->
               let can = List.sort_uniq compare (row_names errs) in
               List.iter
                 (fun t ->
                   if not (List.mem t can) then
                     report env
                       (tags_cant_fail loc ~fn ~param ~tag:t ~what ~can))
                 names)))
      (List.rev !given_tags);
    made env ret

(* Whether a call of [callee] with [args] is all right as far as
   `sync.keyed` goes: it's generic in what it keeps instances of, which
   has to be a handler's description, since it's built in (compiler.md,
   "The standard library (step 8)"). One that isn't is said, and the call
   is then of no type, so its `with` says nothing more. *)
and keyed_described env cx ?callee args =
  match (callee, args) with
  | Some c, [ _; (h : expr) ] when c = Path.make "sync" "keyed" -> (
      match Option.map repr (Hashtbl.find_opt cx.nodes h.node) with
      | Some (TImpl _ | TVar _ | TError) | None -> true
      | Some t ->
          report env
            (keyed_not_described h.loc
               ~arg:(Option.value (env.source h) ~default:"this")
               (show (printer env) t));
          false)
  | _ -> true

(* Whether [t] is the prelude's `Tags`. *)
and is_tags t =
  match repr t with TCon (p, []) -> p = tags_path | _ -> false

(* [t], what a call gives: if it's a handler's description, one whose
   `uses` is an upper bound (foundations.md, decision 3): what it needs,
   and a tail of its own, so it fits wherever a type that lists at least
   that much is written, `Router<(Api uses Cache, Db)>` holding `health()`.
   Needing less is always safe, since whatever installs or calls it
   provides the whole row its type says. What it can fail to start with,
   `!`, stays exact. One whose row is open already, a function's of the
   group being checked, or one that names a row, stays as it is: it's as
   open as it can be. *)
and made env t =
  match repr t with
  | TImpl i when row_tail i.needs = None && row_skolem i.needs = None ->
      TImpl { i with needs = extend (fst (row_parts i.needs)) (fresh_row env.st) }
  | _ -> t

(* A call's arguments [args], left to right, each against its parameter's
   type, of [ps]; [name] is the callee, for messages, and [callee] the
   top-level function it is, if it's one. [written] says which of [ps]
   have a type written, where an argument is narrowed to it ([narrow]). *)
and check_args env cx ~name ?callee ~written ps args =
  List.iter2
    (fun ((p : Types.param), written) (a : expr) ->
      (* `f(&s.pop())` passes the call's result: its `&` is the
               receiver's *)
      let passed = changed_receiver a = None in
      match (p.mode, a.kind) with
      | Inout, Ref place when passed ->
          Hashtbl.replace cx.nodes a.node p.ty;
          check env cx ~exact:true place p.ty
      | Inout, Ref call ->
          (* `take(&c.pop())`: the `&` is `c`'s, and the argument is
                   what the call returns *)
          ignore (infer env cx a);
          report env
            (changes_call_result a.loc name ~arg:(env.source a)
               ~call:(env.source call))
      | Inout, _ ->
          let var =
            match a.kind with
            | Var x
            | Field ({ kind = Var x; _ }, _)
            | Index ({ kind = Var x; _ }, _) ->
                Some (name_of x)
            | _ -> None
          in
          ignore (infer env cx a);
          report env (arg_needs_amp a.loc name ~var)
      | Read, Ref place when passed ->
          ignore (infer env cx place);
          report env (arg_not_changed a.loc name)
      | Read, _ -> (
          let why =
            match (cant_fail_why env callee a p.ty, callee) with
            | Some why, _ -> why
            | None, Some c when c = Path.member (Path.prelude "Async") "each" ->
                (* what `each`'s block gives is thrown away, so it gives
                   `()` (compiler.md, "The rest of `Async`") *)
                explain
                  ~produces:(fun f _ ->
                    sprintf "`Async.each`'s block gives %s, which `each` would throw away"
                      (article f))
                  ~help:(fun _ _ ->
                    "use `Async.map` to keep the results, or end the block with `()`")
                  ()
            | None, _ -> forced_why env callee p.ty
          in
          (* a parameter whose type is a variable, a generic's `T`, isn't
             written, however it's solved: the argument is unified with
             it *)
          match if is_written p.ty then impl_parts p.ty else None with
          | Some _ when written && branchy a ->
              (* `run(if b then h1 else h2)`: each branch is narrowed, as
                 under `let x: Rates = if ...` *)
              check env cx ~why ~written:p.ty a p.ty
          | Some _ ->
              (* an implementation that needs less than the parameter
                 allows will do, and where the parameter's type is
                 written, so will one of more dependencies, narrowed to
                 the parameter's *)
              let t = infer env cx a in
              let t = if written then narrow env cx a t p.ty else t in
              ignore
                (unifies env why (result_loc a) ~found:(widen env ~loc:a.loc t)
                   ~expected:p.ty)
          | None ->
              check env cx ~why
                ?written:(if written then Some p.ty else None)
                a p.ty))
    (List.combine ps written) args

(* How to word [a], a block given to a parameter of [callee]'s of type
   [t] that can't fail, failing: a spawned task's, or a branch of
   `Async.race` (compiler.md, "Stage 11a", "The checker"). The help writes
   the first call in it marked with `try` as one marked with `attempt`. *)
and cant_fail_why env callee (a : expr) t =
  let spawns =
    List.map (Path.member (Path.prelude "Scope")) [ "spawn"; "start"; "replace" ]
  in
  let rec first_try (e : expr) =
    match e.kind with
    | Try x -> env.source x
    | _ -> List.find_map first_try (Ast.children e)
  in
  match (callee, repr t, a.kind) with
  | Some c, TFun (_, _, REmpty, _), Lambda (_, body)
    when List.mem c spawns || Iface.closed_blocks c ->
      let call = Option.value (first_try body) ~default:"..." in
      let msg, help =
        if List.mem c spawns then
          ( "a spawned task can't fail, or one task's failure would stop all \
             the others",
            sprintf "handle them in the task: `match attempt %s`" call )
        else
          ( "a branch of `race` can't fail, or a failure could leave the race \
             waiting on the other",
            sprintf
              "make the failure a value inside it: `attempt %s`; to try again \
               until one succeeds, use `retry`"
              call )
      in
      (* what it fails with, after the `!` of its type as it's printed *)
      let fails found =
        match String.index_opt found '!' with
        | Some i ->
            String.trim (String.sub found (i + 1) (String.length found - i - 1))
        | None -> "..."
      in
      Some
        (explain
           ~msg:(fun _ _ -> msg)
           ~help:(fun _ _ -> help)
           ~labels:(fun found _ -> [ (body.loc, "can fail with " ^ fails found) ])
           ~alone:true ())
  | _ -> None

(* An argument's type, and whether it's passed with `&`. *)
and infer_arg env cx (a : expr) =
  match a.kind with
  | Ref place when changed_receiver a = None ->
      let t = infer_raw env cx place in
      Hashtbl.replace cx.nodes a.node t;
      { mode = Inout; ty = t }
  | _ -> read (infer env cx a)

(* A constructor applied to [args], where a value of type [expected] is
   wanted. *)
and infer_con env cx (e : expr) (cref : ctor_ref) args ~written ~expected =
  let c = cref.name in
  match find_ctor env cref ~expected with
  | None ->
      List.iter (fun (_, a) -> ignore (infer env cx a)) args;
      TError
  | Some (td, ctor) when td.path = result_path && ctor.cname = "Err" -> (
      match args with
      | [ (_, ({ kind = Con ({ qual = None; name = tag }, payload); _ } as a)) ]
        ->
          (* a tag, written as the error the `Result` holds:
             `Err(Short(a, b))`. It's a value only here, so an error is
             still always inside a `Result`; a payload's names only
             document it, as in a `fail` *)
          Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
          let payload = List.map (fun (_, a) -> (infer env cx a, a)) payload in
          let row = err_row env cx tag payload ~expected in
          Hashtbl.replace cx.nodes a.node (TErrors row);
          Hashtbl.replace cx.found a.node Error_tag;
          TCon (td.path, [ fresh_var env.st; TErrors row ])
      | _ ->
          (* anything else would be an error of its own, outside the
             `Result`. A tag among several arguments, `Err(Neg(1), 2)`,
             is likely meant as one, so only its payload is checked, not
             the tag as a constructor *)
          List.iter
            (fun (_, (a : expr)) ->
              match a.kind with
              | Con ({ qual = None; _ }, payload) ->
                  List.iter (fun (_, a) -> ignore (infer env cx a)) payload
              | _ -> ignore (infer env cx a))
            args;
          report env (err_made c.loc);
          fst (instance env td))
  | Some (td, ctor) ->
      Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
      let t, tvars = instance env td in
      let written = written_args td written in
      let shown = ctor_written env cref in
      let source (a : expr) = Option.value (env.source a) ~default:"..." in
      (* still check the arguments, for errors of their own *)
      let unchecked () = List.iter (fun (_, a) -> ignore (infer env cx a)) args in
      if ctor.cnamed then (
        (* by name, in braces (compiler.md, "Data stage", "By-name
           variants") *)
        report env
          (built_by_name e.loc shown
             ~written:
               (by_name shown ctor.cfields
                  (List.map (fun (_, a) -> source a) args)));
        unchecked ())
      else if ctor_shape env e.loc c ctor (List.length args) then (
        (match args with
        | [ (Some _, a) ] ->
            (* a label on one field only documents it *)
            report env
              (by_position e.loc shown ~fields:1 ~pattern:false
                 ~written:(sprintf "%s(%s)" shown (source a)))
        | _ -> ());
        List.iter2
          (fun (f : Iface.field) (_, (a : expr)) ->
            check env cx a (field_type ~tvars f)
              ?written:(written_field ~tvars written f)
              ~why:(explain ~notes:[ part_of c.name "field" f.fname ] ()))
          ctor.cfields args)
      else unchecked ();
      t

(* `Rect { w: 2, h: 3 }`, a by-name constructor, where a value of type
   [expected] is wanted: found as [infer_con] finds one, then its fields
   checked as a record literal's are, each the constructor's, once, and
   every one given. A constructor whose fields are positional is
   refused, its help writing it that way. *)
and infer_con_named env cx (e : expr) (cref : ctor_ref) fields ~written
    ~expected =
  let c = cref.name in
  let unchecked () = List.iter (fun (_, v) -> ignore (infer env cx v)) fields in
  match find_ctor env cref ~expected with
  | None ->
      unchecked ();
      TError
  | Some (td, ctor) ->
      Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
      let t, tvars = instance env td in
      let written = written_args td written in
      let shown = ctor_written env cref in
      (if not ctor.cnamed then (
         let value =
           match (ctor.cfields, fields) with
           | [ f ], [ (g, v) ] when g.name = f.fname || f.fname = "" ->
               Option.value (env.source v) ~default:"..."
           | _ -> "..."
         in
         report env
           (by_position e.loc shown ~fields:(List.length ctor.cfields)
              ~pattern:false
              ~written:
                (if ctor.cfields = [] then shown
                 else sprintf "%s(%s)" shown value));
         unchecked ())
       else
         let seen = Hashtbl.create 8 in
         (* a misspelled field is also a missing one; once it's reported,
            the missing ones aren't, as they're likely the same mistake *)
         let unknown = ref false in
         List.iter
           (fun ((f : ident), v) ->
             (match Hashtbl.find_opt seen f.name with
             | Some first -> report env (two_fields f first)
             | None -> Hashtbl.replace seen f.name f.loc);
             match
               List.find_opt (fun (d : Iface.field) -> d.fname = f.name) ctor.cfields
             with
             | Some fd ->
                 check env cx v (field_type ~tvars fd)
                   ?written:(written_field ~tvars written fd)
                   ~why:(explain ~notes:[ part_of c.name "field" f.name ] ())
             | None ->
                 report env
                   (no_such_field ~names:env.names
                      ~owner:(type_name env td.path ^ "." ^ c.name)
                      f td.path ctor.cfields);
                 unknown := true;
                 ignore (infer env cx v))
           fields;
         let missing =
           List.filter
             (fun n -> not (Hashtbl.mem seen n))
             (field_names ctor.cfields)
         in
         if missing <> [] && not !unknown then
           report env (missing_fields e.loc c.name missing));
      t

(* What [td]'s parameters are where the type written for a value of it,
   [written], says, if it's written: so a field whose declared type is a
   parameter, `Box<T>`'s `T`, is written where the `Box` is, `let b:
   Box<Users> = Box(h)`, and a handler there is narrowed to it (deps.md,
   "Implementations"). The field is still checked against its type from
   fresh variables, as without it, so only narrowing sees these. *)
and written_args (td : Iface.type_decl) written =
  match written with
  | Some (TCon (p, xs))
    when p = td.path && List.length xs = List.length td.params ->
      Some xs
  | _ -> None

(* The type written for field [f], if it's written: its declared type,
   where [written_args] found what the parameters are, or else [tvars]. *)
and written_field ~tvars xs (f : Iface.field) =
  let ft = field_type ~tvars:(Option.value xs ~default:tvars) f in
  if is_written ft then Some ft else None

(* A record literal: `User { ... }`, or `{ ... }` with its type found
   through [expected], or else through its fields. *)
and infer_record env cx (e : expr) name fields ~written ~expected =
  let ids = List.map fst fields in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (f : ident) ->
      match Hashtbl.find_opt seen f.name with
      | Some first -> report env (two_fields f first)
      | None -> Hashtbl.replace seen f.name f.loc)
    ids;
  let given = sorted (List.map (fun (f : ident) -> f.name) ids) in
  let decl =
    match name with
    | Some { tref = Named p; tloc } -> (
        let td = Hashtbl.find env.types p in
        match (td.body, record_fields td) with
        | Dep _, _ ->
            impl_record env cx e td fields;
            None
        | _, Some fs -> Some (td, fs)
        | _, None ->
            report_rep env td
              (not_a_record ~names:env.names ~test:(tested env td) tloc td);
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
        match (known_decl env expected, through_type env ~known ~fits) with
        | Some ({ body = Dep _; _ } as td), _ ->
            impl_record env cx e td fields;
            None
        | _, Found found -> Some found
        | _, Nowhere ->
            report env (no_record_fits e.loc);
            None
        | _, Several paths ->
            report env (several_records_fit ~names:env.names e.loc paths);
            None)
  in
  match decl with
  | None ->
      List.iter (fun (_, v) -> ignore (infer env cx v)) fields;
      TError
  | Some (td, decl) ->
      let t, tvars = instance env td in
      let written = written_args td written in
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
                ?written:(written_field ~tvars written fd)
                ~why:
                  (explain
                     ~notes:[ part_of (type_name env td.path) "field" f.name ]
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
        report env (missing_fields e.loc (env.names td.path) missing);
      t

(* `{ ..base, f: v, ... }`, an update (compiler.md, "Data stage", "Record
   update"): a record of the type [target] names, or else of [base]'s,
   which has to be known here, as a field read's does, or else be
   [expected]. The fields given are the target's, each once; every other
   field of the target is [base]'s, of the same type; and every field of
   [base] is the target's, so nothing is dropped unseen. [base] is
   checked first, then the fields, as they're evaluated. *)
and infer_update env cx (e : expr) target base fields ~expected =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun ((f : ident), _) ->
      match Hashtbl.find_opt seen f.name with
      | Some first -> report env (two_fields f first)
      | None -> Hashtbl.replace seen f.name f.loc)
    fields;
  let tb = infer env cx base in
  let shown = ".." ^ Option.value (env.source base) ~default:"it" in
  let pr = printer env in
  (* a record type's declaration and its fields, if [t] is one, and the
     constructor, if it's a variant type, whose fields those are
     (compiler.md, "Data stage", "Variant types"); reported if it isn't,
     at [loc] *)
  let record_of t =
    match reveal env.st t with
    | TError -> None
    | TVariant (p, c, args) ->
        let td, k = variant_ctor env p c in
        Some (td, k.cfields, args, Some c)
    | TCon (p, args) as t -> (
        let td = Hashtbl.find env.types p in
        match (td.body, record_fields td) with
        | _, Some fs -> Some (td, fs, args, None)
        | Opaque (Hidden _), None ->
            report_rep env td
              (opaque_private ~test:(tested env td) base.loc td);
            None
        | Sum cs, None ->
            (* a sum has no fields to take: its variant's type has, which
               a pattern's `as` binds; the help names the target's
               variant, or one with the fields given *)
            let named = List.filter (fun (k : Iface.ctor) -> k.cnamed) cs in
            let has (k : Iface.ctor) =
              List.for_all
                (fun ((f : ident), _) ->
                  List.exists (fun (d : Iface.field) -> d.fname = f.name) k.cfields)
                fields
            in
            let variant =
              match target with
              | Some (Into_ctor c) -> Some c.name.name
              | _ -> (
                  match List.find_opt has named with
                  | Some k -> Some k.cname
                  | None -> (
                      match named with k :: _ -> Some k.cname | [] -> None))
            in
            report env
              (update_from_sum base.loc ~base:shown (show pr t) ~variant);
            None
        | _ -> 
            report env (update_not_record base.loc ~base:shown (show pr t));
            None)
    | t ->
        report env (update_not_record base.loc ~base:shown (show pr t));
        None
  in
  (* the target, if it's written: its type's declaration, its fields, and
     its name, which is a by-name constructor's, `Placed`, when it's one,
     building its sum *)
  let target_decl =
    match target with
    | Some (Into_type { tref = Named p; tloc }) -> (
        let td = Hashtbl.find env.types p in
        match record_fields td with
        | Some fs -> Some (Some (td, fs, None))
        | None ->
            report_rep env td
              (not_a_record ~names:env.names ~test:(tested env td) tloc td);
            None)
    | Some (Into_type { tref = Param _; _ }) ->
        (* resolve.ml only resolves a record's name to a declared type *)
        assert false
    | Some (Into_ctor cref) -> (
        match find_ctor env cref ~expected with
        | None -> None
        | Some (td, ctor) when ctor.cnamed ->
            Hashtbl.replace cx.found e.node (Ctor_of (td.path, ctor.cname));
            Some (Some (td, ctor.cfields, Some ctor.cname))
        | Some (_, ctor) ->
            let shown = ctor_written env cref in
            report env
              (by_position e.loc shown ~fields:(List.length ctor.cfields)
                 ~pattern:false
                 ~written:
                   (if ctor.cfields = [] then shown else shown ^ "(...)"));
            None)
    | None -> Some None
  in
  (* the base, whose type is the target's when it isn't known yet and the
     target is a record type named, or expected *)
  let based =
    match (reveal env.st tb, target_decl) with
    | TVar _, Some (Some (_, _, Some _)) ->
        report env (no_record_fits e.loc);
        None
    | TVar _, Some (Some (td, _, None)) ->
        let t, _ = instance env td in
        unify_at env base.loc ~found:tb ~expected:t;
        record_of tb
    | TVar _, Some None -> (
        match known_decl env expected with
        | Some td when record_fields td <> None ->
            let t, _ = instance env td in
            unify_at env base.loc ~found:tb ~expected:t;
            record_of tb
        | _ ->
            report env (no_record_fits e.loc);
            None)
    | _, Some _ -> record_of tb
    | _, None -> None
  in
  let based =
    Option.map (fun (td, fs, args, _) -> (td, fs, args)) based
  and base_variant =
    match based with Some (_, _, _, v) -> v | None -> None
  in
  let unknown () =
    List.iter (fun (_, v) -> ignore (infer env cx v)) fields;
    TError
  in
  match (based, target_decl) with
  | None, _ | _, None -> unknown ()
  | Some (btd, bfs, bargs), Some tgt ->
      let td, decl, ctor =
        match tgt with Some t -> t | None -> (btd, bfs, None)
      in
      let t, tvars = instance env td in
      (* with no target, an update of a variant type is that variant
         type: `{ ..p, total: x }` is an `Order.Placed` *)
      let t, target_name =
        match (tgt, base_variant) with
        | None, Some c -> (TVariant (td.path, c, tvars), c)
        | _ -> (
            ( t,
              match ctor with Some c -> c | None -> type_name env td.path ))
      in
      (* the fields given, at the target's types *)
      List.iter
        (fun ((f : ident), v) ->
          match
            List.find_opt (fun (d : Iface.field) -> d.fname = f.name) decl
          with
          | Some fd ->
              check env cx v (field_type ~tvars fd)
                ~why:
                  (explain
                     ~notes:[ part_of target_name "field" f.name ]
                     ())
          | None ->
              report env (no_such_field ~names:env.names f td.path decl);
              ignore (infer env cx v))
        fields;
      let given (d : Iface.field) =
        List.exists (fun ((f : ident), _) -> f.name = d.fname) fields
      in
      (* the rest, from the base *)
      List.iter
        (fun (d : Iface.field) ->
          if not (given d) then
            match
              List.find_opt (fun (b : Iface.field) -> b.fname = d.fname) bfs
            with
            | None ->
                report env
                  (update_needs base.loc ~target:target_name ~base:shown
                     d.fname)
            | Some b -> (
                let found = field_type ~tvars:bargs b in
                let wanted = field_type ~tvars d in
                match Unify.unify env.st found wanted with
                | () -> ()
                | exception (Unify.Mismatch | Unify.Two_shapes _ | Unify.Infinite)
                  ->
                    report env
                      (update_field_type base.loc ~target:target_name
                         ~base:shown d.fname ~found:(show pr found)
                         ~expected:(show pr wanted))))
        decl;
      (* nothing of the base is dropped *)
      List.iter
        (fun (b : Iface.field) ->
          if not (List.exists (fun (d : Iface.field) -> d.fname = b.fname) decl)
          then
            report env
              (update_drops base.loc ~target:target_name ~base:shown b.fname))
        bfs;
      t

(* `Clock { now: fn() => t, ... }`, a record literal of the dependency
   [td]: an implementation is a handler, which the help writes from the
   literal, an arm for each operation it gives (deps.md,
   "Implementations"). Its fields are still checked, for errors of their
   own. *)
and impl_record env cx (e : expr) (td : Iface.type_decl) fields =
  List.iter (fun (_, v) -> ignore (infer env cx v)) fields;
  let arm ((f : ident), (v : expr)) =
    match v.kind with
    | Lambda (ps, body) ->
        let ps = List.map (fun (p : Resolved.param) -> p.pname.ident.name) ps in
        let body =
          match env.source body with
          | Some s when not (String.contains s '\n') -> s
          | _ -> "..."
        in
        sprintf "%s(%s) => %s" f.name (String.concat ", " ps) body
    | _ -> f.name ^ "(...) => ..."
  in
  report env
    (impl_record_made e.loc ~dep:(type_name env td.path)
       ~name:(String.lowercase_ascii td.path.name)
       (List.map arm fields))

(* `r.f`: the field is found through [r]'s type ([field_access]), which
   has to be known by now, or be the one record type that has a field
   named [f]. *)
and infer_field env cx (e : expr) r (f : ident) =
  field_access env cx e r (infer env cx r) f

(* A `match`. With [want], every arm is checked against the type it says;
   otherwise the first arm says what the others have to be.

   A `match` with `fail` arms handles what its subject fails with
   (errors.md, "Handling: `match`"), so the calls in the subject are
   marked by the `match`, as they would be by an `attempt`: their errors,
   and a `fail`'s, go to a row of the `match`'s own, which the `fail` arms
   match. The arms are outside it, under the code's own handler. [passed]
   is the `try` of a `try match`, which passes on what no arm handles.
   Which `match`es handle errors, and which arms are `fail` arms, is
   recorded by [node], the `match`'s id, and each arm's pattern's, for
   later passes. *)
and infer_match env cx ?passed node subject arms ~want =
  let ts, errs =
    if handles arms then (
      Hashtbl.replace cx.found node Handles;
      let first = List.find (fun a -> is_fail a.arm_pat) arms in
      (* `fail on` handles what it's given, which isn't known here: a
         `match` of only those handles nothing it can name *)
      let rec tags_only (p : pattern) =
        match p.pkind with
        | PFail_in _ -> true
        | POr ps -> List.for_all tags_only ps
        | _ -> false
      in
      let kind =
        if
          List.for_all
            (fun a -> (not (is_fail a.arm_pat)) || tags_only a.arm_pat)
            arms
        then Mmatch_on
        else Mmatch
      in
      let m = marker env kind first.arm_pat.ploc in
      let errs = fresh_row env.st in
      defer env (Kept (errs, cx.params, None));
      let ts =
        infer env
          { cx with handler = errs; markers = [ m ]; sources = None }
          subject
      in
      Option.iter (fun p -> pass_on env cx p subject arms errs) passed;
      (ts, Some errs))
    else (infer env cx subject, None)
  in
  let result, arm_why =
    match want with
    | Some (expected, why, _) -> (expected, fun _ -> why)
    | None ->
        let first = result_loc (List.hd arms).arm_body in
        ( fresh_var env.st,
          fun i ->
            let msg = if i = 0 then None else Some arm_after in
            explain ?msg ~labels:(fun _ x -> [ (first, first_arm x) ]) () )
  in
  List.iteri
    (fun i a ->
      (match errs with
      | Some errs when is_fail a.arm_pat ->
          Hashtbl.replace cx.found a.arm_pat.pnode Fail_arm;
          bind_fail env cx errs a.arm_pat
      | _ -> bind_pattern env cx ts a.arm_pat);
      Option.iter (fun g -> want_bool env Guard g (infer env cx g)) a.arm_guard;
      let written = Option.bind want (fun (_, _, w) -> w) in
      check env cx ~why:(arm_why i) ?written a.arm_body result)
    arms;
  result

(* A `fail` arm's pattern, which matches an error of the set [errs]: a
   tag, destructured, or any of them. Each alternative of `fail A(x) |
   fail B(x)` binds the same names, which have to have one type. *)
and bind_fail env cx errs (p : pattern) =
  Hashtbl.replace cx.nodes p.pnode (TErrors errs);
  match p.pkind with
  | PFail (c, ps) -> tag_pattern env cx ~arm:true p c ps errs
  | PFail_any | PFail_in _ -> ()
  | POr ps -> alternatives env cx ps (bind_fail env cx errs)
  | PWild | PVar _ | PInt _ | PBool _ | PCon _ | PCon_named _ | PTuple _
  | PRecord _ | PAs _ ->
      (* the parser combines only `fail` patterns *)
      bind_pattern env cx TError p

(* The alternatives [ps] of an or-pattern, each bound by [bind]: each
   binds the same names (Resolve), which have to have one type, the
   first's. *)
and alternatives env cx ps bind =
  match ps with
  | [] -> ()
  | first :: rest ->
      bind first;
      let shown = Ast.pattern_source ~type_name:(type_name env) in
      List.iter
        (fun alt ->
          let before =
            List.map
              (fun (b, loc) -> (b, loc, Hashtbl.find_opt cx.locals b.id))
              (binders alt)
          in
          bind alt;
          List.iter
            (fun ((b : binder), loc, t) ->
              match (t, Hashtbl.find_opt cx.locals b.id) with
              | Some t1, Some here ->
                  unify_at env loc ~found:here ~expected:t1
                    ~msg:
                      (alternative b.ident.name ~first:(shown first)
                         ~here:(shown alt))
                    ~help:"bind it to one type in every alternative";
                  Hashtbl.replace cx.locals b.id t1
              | _ -> ())
            before)
        rest

(* Check a pattern against the type of the value it matches, and give the
   variables it binds their types. A constructor is found through that
   type. With [binding], it's a `let`'s, a `for`'s or a block parameter's,
   which only takes apart, so a record pattern there may leave fields out
   without `..` (compiler.md, "Data stage", "Record patterns"). *)
and bind_pattern ?(binding = false) env cx t (p : pattern) =
  let bind_pattern = bind_pattern ~binding in
  Hashtbl.replace cx.nodes p.pnode t;
  let check found = unify_at env p.ploc ~found ~expected:t ~msg:pattern_for in
  match (p.pkind, repr t) with
  | PCon ({ qual = None; name = c }, ps), TErrors errs ->
      (* a tag, inside `Err(...)`: one of the errors the [Result] holds *)
      Hashtbl.replace cx.found p.pnode Error_tag;
      tag_pattern env cx p c ps errs
  | PVar b, TErrors errs ->
      (* `Err(e)` would make the error a value of its own *)
      (match row_skolem errs with
      | Some (id, _) when List.mem id env.finally_rows ->
          (* in a `finally`, the body's, which it can only pass on *)
          let r =
            match
              List.find_opt
                (fun (_, ty) ->
                  match repr ty with
                  | TCon (_, [ _; e ]) -> (
                      match repr e with
                      | TErrors e -> (
                          match row_skolem e with
                          | Some (id', _) -> id' = id
                          | None -> false)
                      | _ -> false)
                  | _ -> false)
                cx.params
            with
            | Some (r, _) -> r
            | None -> "r"
          in
          report env (bound_body_error p.ploc b.ident.name ~r)
      | _ -> report env (bound_error p.ploc b.ident.name));
      Hashtbl.replace cx.nodes p.pnode TError;
      Hashtbl.replace cx.locals b.id TError
  | pkind, _ -> (
      match pkind with
      | PWild -> ()
      | PVar b -> Hashtbl.replace cx.locals b.id t
      | PInt _ -> check int
      | PBool _ -> check bool
      | PCon (cref, ps) -> (
          let c = cref.name in
          let unknown () = List.iter (bind_pattern env cx TError) ps in
          match find_ctor env cref ~expected:t with
          | None -> unknown ()
          | Some (td, ctor) ->
              Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
              let tc, tvars = instance env td in
              check tc;
              let bind () =
                List.iter2
                  (fun fd sub -> bind_pattern env cx (field_type ~tvars fd) sub)
                  ctor.cfields ps
              in
              if ctor.cnamed then (
                (* by name, in braces; its names are still bound, so what
                   uses them isn't reported too *)
                let shown = ctor_written env cref in
                report env
                  (matched_by_name p.ploc shown
                     ~written:(pattern_by_name env shown ctor.cfields ps));
                if List.length ps = List.length ctor.cfields then bind ()
                else unknown ())
              else if ctor_shape env p.ploc c ctor (List.length ps) then bind ()
              else unknown ())
      | PCon_named (cref, fs) -> con_pattern env cx t p cref fs
      | PTuple ps ->
          let n = List.length ps in
          let parts = List.map (fun _ -> fresh_var env.st) ps in
          let help =
            match repr t with
            | TCon (p, args) when Ty.is_tuple p && List.length args <> n ->
                Some (tuple_parts_help ps (List.length args))
            | TCon (p, _) when not (Ty.is_tuple p) ->
                Some (not_a_tuple_help (show (printer env) t))
            | _ -> None
          in
          unify_at env p.ploc
            ~found:(TCon (Ty.tuple_path n, parts))
            ~expected:t ~msg:pattern_for ?help;
          List.iter2 (bind_pattern env cx) parts ps
      | PRecord (name, fs) -> record_pattern ~binding env cx t p name fs
      | POr ps -> alternatives env cx ps (bind_pattern env cx t)
      | PAs (q, b) ->
          (* the whole of what's matched, which of a by-name constructor's
             pattern is its variant type, `Placed { .. } as p` an
             `Order.Placed` (compiler.md, "Data stage", "Variant types");
             of anything else, an or-pattern's too, what's matched *)
          bind_pattern env cx t q;
          let whole =
            match (q.pkind, Hashtbl.find_opt cx.found q.pnode, reveal env.st t) with
            | PCon_named _, Some (Ctor_of (path, c)), TCon (s, args)
              when s = path ->
                let _, k = variant_ctor env path c in
                if k.cnamed then TVariant (path, c, args) else t
            | _ -> t
          in
          Hashtbl.replace cx.locals b.id whole
      | PFail _ | PFail_any | PFail_in _ ->
          (* a `fail` pattern is a whole arm's (the parser says so), and
             [infer_match] binds it with [bind_fail] *)
          ())

(* `Rect { w, h: tall }`, `Rect { w, .. }`, a by-name constructor's
   pattern matched against [t]: the constructor found as a positional
   one's is, then its fields as a record pattern's are, each the
   constructor's, once, and every one named unless it ends in `..`. A
   constructor whose fields are positional is refused, its help writing
   it that way. A binding position never has one (resolve.ml). *)
and con_pattern env cx t (p : pattern) (cref : ctor_ref) (fs : fields) =
  let unknown () =
    List.iter (fun (_, q) -> bind_pattern env cx TError q) fs.fpats
  in
  let c = cref.name in
  match find_ctor env cref ~expected:t with
  | None -> unknown ()
  | Some (td, ctor) when of_variant t td ctor <> None -> (
      (* matched against a value of a variant type: its own constructor,
         which always matches, its fields at the variant type's arguments *)
      match of_variant t td ctor with
      | Some (Ok tvars) ->
          Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
          named_fields env cx p ~owner:(type_name env td.path ^ "." ^ c.name)
            td ctor tvars fs
            ~written:(fun fs -> PCon_named (cref, fs))
      | _ ->
          let own = match repr t with TVariant (_, c, _) -> c | _ -> c.name in
          report env
            (other_variant p.ploc (show (printer env) t) ctor.cname ~own);
          unknown ())
  | Some (td, ctor) when not ctor.cnamed -> (
      Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
      let tc, tvars = instance env td in
      unify_at env p.ploc ~found:tc ~expected:t ~msg:pattern_for;
      let shown = ctor_written env cref in
      match ctor.cfields with
      | [] ->
          report env
            (by_position p.ploc shown ~fields:0 ~pattern:true ~written:shown);
          unknown ()
      | f :: _ ->
          (* its one field's pattern, if it's named, by its name or by the
             one it would have *)
          let sub =
            List.find_map
              (fun ((g : ident), q) ->
                if g.name = f.fname || (f.fname = "" && List.length fs.fpats = 1)
                then Some q
                else None)
              fs.fpats
          in
          report env
            (by_position p.ploc shown ~fields:1 ~pattern:true
               ~written:
                 (sprintf "%s(%s)" shown
                    (match sub with
                    | Some q -> Ast.pattern_source ~type_name:(type_name env) q
                    | None -> "_")));
          List.iter
            (fun (_, q) ->
              bind_pattern env cx
                (if Some q == sub then field_type ~tvars f else TError)
                q)
            fs.fpats)
  | Some (td, ctor) ->
      Hashtbl.replace cx.found p.pnode (Ctor_of (td.path, ctor.cname));
      let tc, tvars = instance env td in
      unify_at env p.ploc ~found:tc ~expected:t ~msg:pattern_for;
      named_fields env cx p ~owner:(type_name env td.path ^ "." ^ c.name) td
        ctor tvars fs
        ~written:(fun fs -> PCon_named (cref, fs))

(* Whether [t], what a pattern of the constructor [ctor] of [td] is
   matched against, is a variant type of [td]: [Ok] its type arguments if
   it's [ctor]'s, [Error] if it's another constructor's, [None] if it
   isn't one. *)
and of_variant t (td : Iface.type_decl) (ctor : Iface.ctor) =
  match repr t with
  | TVariant (p, c, args) when p = td.path ->
      Some (if c = ctor.cname then Ok args else Error c)
  | _ -> None

(* The fields [fs] of a by-name pattern of [ctor], of [td] at [tvars]: each
   [ctor]'s, once, and every one named unless it ends in `..`. [owner] names
   it in a message, and [written] makes the pattern again for the help. *)
and named_fields ?(binding = false) env cx (p : pattern) ~owner
    (td : Iface.type_decl) (ctor : Iface.ctor) tvars (fs : fields) ~written =
  let seen = Hashtbl.create 8 in
  let unknown_field = ref false in
  List.iter
    (fun ((f : ident), q) ->
      (match Hashtbl.find_opt seen f.name with
      | Some first -> report env (two_fields f first)
      | None -> Hashtbl.replace seen f.name f.loc);
      match
        List.find_opt (fun (d : Iface.field) -> d.fname = f.name) ctor.cfields
      with
      | Some fd -> bind_pattern env cx (field_type ~tvars fd) q
      | None ->
          report env
            (no_such_field ~names:env.names ~owner f td.path ctor.cfields);
          unknown_field := true;
          bind_pattern env cx TError q)
    fs.fpats;
  let missing =
    List.filter (fun n -> not (Hashtbl.mem seen n)) (field_names ctor.cfields)
  in
  if missing <> [] && (not fs.rest) && (not binding) && not !unknown_field then
    let written =
      Ast.pattern_source ~type_name:(type_name env)
        { p with pkind = written { fs with rest = true } }
    in
    report env (pattern_misses p.ploc missing ~written)

(* `{ f: q, .. }` or `User { f: q, .. }`, matched against [t]: a record
   of the type named, or of [t]'s, or else the one visible record type
   that has the fields named (as a literal's is found, [infer_record]).
   Each field is the record's, once; one in a `match` names every field
   or ends in `..`, unless it's [binding]. *)
and record_pattern ~binding env cx t (p : pattern) name (fs : fields) =
  match (name, reveal env.st t) with
  | None, TVariant (path, c, args) ->
      (* a variant type is a record of its constructor's fields: matched
         as that constructor's pattern is, which always matches *)
      let td, ctor = variant_ctor env path c in
      Hashtbl.replace cx.found p.pnode (Ctor_of (path, c));
      named_fields ~binding env cx p
        ~owner:(type_name env path ^ "." ^ c)
        td ctor args fs
        ~written:(fun fs -> PRecord (None, fs))
  | _ -> plain_record_pattern ~binding env cx t p name fs

and plain_record_pattern ~binding env cx t (p : pattern) name (fs : fields) =
  let unknown () = List.iter (fun (_, q) -> bind_pattern env cx TError q) fs.fpats in
  let named = List.map (fun ((f : ident), _) -> f.name) fs.fpats in
  let has_all decl =
    List.for_all (fun n -> List.mem n (field_names decl)) named
    && (fs.rest || binding || List.length (field_names decl) = List.length named)
  in
  let decl =
    match name with
    | Some { tref = Named path; tloc } -> (
        let td = Hashtbl.find env.types path in
        match record_fields td with
        | Some decl -> Some (td, decl)
        | None ->
            report_rep env td
              (not_a_record ~names:env.names ~test:(tested env td) tloc td);
            None)
    | Some { tref = Param _; _ } -> assert false
    | None -> (
        match reveal env.st t with
        | TError -> None
        | TCon (path, _) as shown -> (
            let td = Hashtbl.find env.types path in
            match (td.body, record_fields td) with
            | _, Some decl -> Some (td, decl)
            | Opaque (Hidden _), None ->
                report_rep env td
                  (opaque_private ~test:(tested env td) p.ploc td);
                None
            | Sum cs, None ->
                (* the variant it could be: the first by name with every
                   field it names *)
                let fits (k : Iface.ctor) =
                  k.cnamed
                  && List.for_all (fun n -> List.mem n (field_names k.cfields)) named
                in
                let written =
                  Option.map
                    (fun (k : Iface.ctor) ->
                      k.cname ^ " "
                      ^ Ast.show_fields
                          (Ast.pattern_source ~type_name:(type_name env))
                          fs)
                    (List.find_opt fits cs)
                in
                report env
                  (record_pattern_of_sum p.ploc (show (printer env) shown)
                     ~written);
                None
            | _ ->
                report env (pattern_not_record p.ploc (show (printer env) shown));
                None)
        | TVar _ -> (
            let fits td =
              match record_fields td with
              | Some decl when has_all decl -> Some decl
              | _ -> None
            in
            match through_type env ~known:None ~fits with
            | Found found -> Some found
            | Nowhere ->
                report env (no_record_fits p.ploc);
                None
            | Several paths ->
                report env (several_records_fit ~names:env.names p.ploc paths);
                None)
        | shown ->
            report env (pattern_not_record p.ploc (show (printer env) shown));
            None)
  in
  match decl with
  | None -> unknown ()
  | Some (td, decl) ->
      let tr, tvars = instance env td in
      unify_at env p.ploc ~found:tr ~expected:t ~msg:pattern_for;
      Hashtbl.replace cx.nodes p.pnode tr;
      let seen = Hashtbl.create 8 in
      let unknown_field = ref false in
      List.iter
        (fun ((f : ident), q) ->
          (match Hashtbl.find_opt seen f.name with
          | Some first -> report env (two_fields f first)
          | None -> Hashtbl.replace seen f.name f.loc);
          match List.find_opt (fun (d : Iface.field) -> d.fname = f.name) decl with
          | Some fd -> bind_pattern env cx (field_type ~tvars fd) q
          | None ->
              report env (no_such_field ~names:env.names f td.path decl);
              unknown_field := true;
              bind_pattern env cx TError q)
        fs.fpats;
      let missing = List.filter (fun n -> not (List.mem n named)) (field_names decl) in
      if missing <> [] && (not fs.rest) && (not binding) && not !unknown_field then
        let written =
          Ast.pattern_source ~type_name:(type_name env)
            { p with pkind = PRecord (name, { fs with rest = true }) }
        in
        report env (pattern_misses p.ploc missing ~written)

(* The tag [c] of the error set [errs], destructured by [ps]. A misspelled
   tag is caught here: it isn't one of the errors (errors.md, "Tags are
   structural"). While the set is open, as an `attempt`'s is until its
   group is done, a tag not in it yet is checked then. *)
and tag_pattern env cx ?(arm = false) (p : pattern) (c : ident) ps errs =
  let labels, tail = row_parts errs in
  let bind payload =
    if List.length payload = List.length ps then
      List.iter2 (bind_pattern env cx) payload ps
    else (
      report env (tag_arity p.ploc c (List.length payload) (List.length ps));
      List.iter (bind_pattern env cx TError) ps)
  in
  match (List.find_opt (fun (l : label) -> l.name = c.name) labels, tail) with
  | Some l, _ -> bind l.payload
  | None, None ->
      let pr = printer env in
      report env
        (not_an_error c ~arm
           (List.map (fun (l : label) -> (l.name, show_label pr l)) labels));
      List.iter (bind_pattern env cx TError) ps
  | None, Some _ ->
      let payload = List.map (fun _ -> fresh_var env.st) ps in
      defer env
        (Tag_pattern
           {
             ttag = c;
             tpayload = payload;
             tset = errs;
             tin = cx.params;
             tarm = arm;
             tvalue = false;
           });
      bind payload

(* What infer_handlers.ml calls back, from the functions above (see
   [Infer_handlers.core]). A [let rec] can define a record of its
   functions, as well as the functions themselves. *)
and core =
  {
    infer;
    check = (fun env cx ?why ?written e t -> check env cx ?why ?written e t);
    stmt;
    infer_call;
    call_with;
    check_args;
  }
