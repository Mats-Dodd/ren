(* Mutability checks: what may change, and through which name. Runs after
   resolve.ml and before type inference, since none of it needs types.

   - Only a place can be assigned to or passed with `&`: a variable, then
     any fields and indices into it (`user.plan`, `xs[i]`). Its variable has
     to be a `var`, an `inout` parameter, or the element of `for p in &ps`.
     A block can change one from outside it, since it captures by
     reference.
   - `&` only appears on a call's arguments, in `for p in &ps`, and before
     a method call that changes its receiver, `&s.push(1)`, whose receiver
     has to be a place this code may change, like an argument's.

   That nothing is used while it's being changed, `swap(&a, &a)`, is
   exclusivity, which needs types and is checked after inference
   (excl.ml).

   Every name has already been resolved (resolve.ml), so what a name is
   (a `let`, a `var`, a parameter...) is on its binder, and two places
   start from the same variable when their binders have the same id.

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the rest of the function. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf

type kind =
  | Mutable  (** a `var`, an `inout` parameter, or the element of a `for &` *)
  | Fixed of string * string
      (** what the name is ("a `let`"), and how to get one that can change *)

(* A place: the name it starts from, written at [rloc], then any fields
   and indices into it. *)
type place = { root : name; rloc : Loc.t }

type ctx = {
  sink : Diag.sink;
  source : expr -> string option;
      (** code as it's written, for messages (Ast.source) *)
  in_handler : bool;  (** inside a handler's body, whose parameters it keeps *)
  inline : int list option;
      (** inside an inline handler: the binders its own code binds, by id. What
          else it reads, it's copied when it's made (foundations.md, decision
          3), so it can't change it *)
  defer_for : expr -> (unit -> unit) -> unit;
      (** The subject's inferred type distinguishes a data cursor's mutation
          from a block, which never takes `&`. *)
}

(* Run a check; if it finds a problem, report it and carry on. *)
let guard cx f = Diag.recover cx.sink ~default:() f

let name_of = function
  | Local b -> b.ident.name
  | Global p | Global_value p -> Path.local p
  | Intrinsic x -> Intrinsic.name x
  | Dep_op (p, op) -> p.name ^ "." ^ op
  | Next_op (_, op) -> "next." ^ op
  | Call_op x -> "call." ^ x
  | Assoc_value (Named p, v) -> p.name ^ "." ^ v
  | Assoc_value (Param _, v) -> v

let rec place_of (e : expr) =
  match e.kind with
  | Var x -> Some { root = x; rloc = e.loc }
  | Field (r, _) | Index (r, _) | Slice (r, _, _) -> place_of r
  | _ -> None

(* The range in a place, `xs[a..b]`, if there's one: what only `&`
   changes, as a call's argument or a `for`'s array. *)
let rec range_in (e : expr) =
  match e.kind with
  | Slice _ -> Some e
  | Field (r, _) | Index (r, _) -> range_in r
  | _ -> None

(* Whether a local can change, and if not, what it is and how to get one
   that can. *)
let kind (b : binder) =
  let x = b.ident.name in
  let copy is =
    Fixed (is, sprintf "copy it with `var %s = %s` and change the copy" x x)
  in
  match b.bound with
  | By_var | By_inout | By_ref_loop -> Mutable
  | By_let -> Fixed ("a `let`", "declare it with `var` to change it")
  | By_param when x = "self" ->
      (* `self` is a reserved word, so it can't be copied into a `var` of
         its own name *)
      Fixed
        ( "a parameter",
          "write `inout self` to change the caller's value, or copy it with \
           `var s = self`" )
  | By_param ->
      Fixed
        ( "a parameter",
          sprintf
            "mark it `inout` to change the caller's value, or copy it with \
             `var %s = %s`"
            x x )
  | By_lambda -> copy "a lambda's parameter"
  | By_pattern -> copy "bound by a pattern"
  | By_loop ->
      Fixed
        ( "a loop variable",
          sprintf "loop with `for %s in &...` to change the elements" x )
  | By_index ->
      Fixed
        ( "the loop's index",
          "it says where the element is: keep a count you change in a `var` \
           of its own" )

(* Check that [e] is a place this code may change. [what] words the error
   when it isn't a place at all, and [help] says what to do. *)
let writable cx (e : expr) ~what
    ?(help = "only a variable, or a field or element of one, can be changed") ()
    =
  match place_of e with
  | None -> Diag.error e.loc ~help what
  | Some ({ root = Global _ | Intrinsic _; _ } as p) ->
      Diag.error p.rloc
        (sprintf "`%s` is a function, not a variable" (name_of p.root))
  | Some ({ root = Call_op x; _ } as p) ->
      Diag.error p.rloc
        (sprintf "`call.%s` is part of the call this arm runs for, so it \
                  can't be changed" x)
  | Some ({ root = Dep_op _ | Next_op _; _ } as p) ->
      Diag.error p.rloc
        ~help:
          (sprintf
             "call it, `%s(...)`; what it does is changed by installing \
              another implementation, with `with`"
             (name_of p.root))
        (sprintf "`%s` is an operation of a dependency, not a variable"
           (name_of p.root))
  | Some ({ root = Global_value _ | Assoc_value _; _ } as p) ->
      Diag.error p.rloc ~help:"copy it into a `var`, and change the copy"
        ~notes:[ "an associated value is made once, and never changes" ]
        (sprintf "`%s` is an associated value, so it can't be changed"
           (name_of p.root))
  | Some ({ root = Local b; _ } as p) -> (
      let x = b.ident.name in
      match (kind b, cx.inline) with
      | _, Some own when not (List.mem b.id own) ->
          Diag.error p.rloc
            ~notes:
              [
                "an inline handler copies what it reads from where it's \
                 written, when its description is made, and keeps no state";
              ]
            ~help:
              "declare a handler with a `var` in its state to keep something \
               that changes"
            (sprintf "`%s` is copied into this inline handler, so it can't be \
                      changed" x)
      | k, _ ->
      match k with
      | Fixed _ when b.bound = By_param && cx.in_handler ->
          Diag.error p.rloc
            ~notes:
              [
                "each `with` that installs a handler keeps its parameters, as \
                 they were when it was called";
              ]
            ~help:
              (sprintf
                 "keep a copy in its state, `var %s = %s`, which its arms can \
                  change"
                 x x)
            (sprintf "`%s` is a handler's parameter, so it can't be changed" x)
      | Fixed (is, help) ->
          Diag.error p.rloc ~help
            (sprintf "`%s` is %s, so it can't be changed" x is)
      | Mutable -> ())

(* The parameters of a handler's arm or its `finally`, which are given
   values: a block's may be `&` (compiler.md, "Blocks with `inout`
   parameters"), but these aren't called with `&`. *)
let no_inout cx (ps : param list) =
  List.iter
    (fun (p : param) ->
      if p.pmode = Inout then
        Diag.report cx.sink
          (Diag.make p.pname.ident.loc ~help:"remove the `&`"
             "an arm's parameters are the operation's arguments, which it \
              can't change"))
    ps

let rec walk cx (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Break | Todo | Tag_set _ | Piped
    ->
      ()
  | Interp ps -> List.iter (walk cx) (Ast.holes ps)
  | Named (_, a) -> walk cx a
  | Pipe { subject; step } ->
      (* the subject is a value the step's call is given, as a `let`'s *)
      walk cx subject;
      walk cx step
  | Var _ | Field _ | Index _ | Slice _ -> (
      match place_of e with
      | Some _ -> walk_indices cx e
      | None -> (
          match e.kind with
          | Field (r, _) -> walk cx r
          | Index (a, i) ->
              walk cx a;
              walk cx i
          | Slice (a, lo, hi) ->
              walk cx a;
              walk cx lo;
              walk cx hi
          | _ -> ()))
  | Ref { kind = Call ({ kind = Field (r, _); _ }, args); _ } ->
      (* `&s.push(1)`: the receiver is changed, as if passed with `&` *)
      guard cx (fun () ->
          writable cx r ~help:"put it in a `var` first"
            ~what:
              (sprintf
                 "`&` needs something it can change, but %s is a new value"
                 (match cx.source r with
                 | Some code -> sprintf "`%s`" code
                 | None -> "this"))
            ());
      (match place_of r with Some _ -> walk_indices cx r | None -> walk cx r);
      List.iter (arg cx) args
  | Ref { kind = Call ({ kind = Var ((Dep_op _ | Next_op _) as op); _ }, _); _ }
    ->
      (* `&Clock.now()`: an operation's state is its implementation's *)
      Diag.report cx.sink
        (Diag.make e.loc ~help:"remove the `&`"
           ~notes:
             [
               "what an operation changes belongs to the implementation \
                installed for it, a handler's state say, which isn't a value \
                the caller holds";
             ]
           (sprintf
              "`%s` is a dependency's operation, and its call never takes `&`"
              (name_of op)))
  | Ref ({ kind = Call _; _ } as call) ->
      (* `&id(xs)`: a call with no receiver for the `&` to mark *)
      Diag.report cx.sink
        (Diag.make e.loc ~help:"remove the `&`"
           ~notes:
             [
               "`&` before a call marks a method's receiver as changed, like \
                `&s.push(1)`, and an argument the call changes is marked \
                inside it, like `f(&x)`";
             ]
           (sprintf "`&` marks a method's receiver, but %s has none"
              (match cx.source call with
              | Some code -> sprintf "`%s`" code
              | None -> "this call")))
  | Ref _ ->
      Diag.report cx.sink
        (Diag.make e.loc ~help:"remove the `&`"
           ~notes:
             [
               "`&` marks an argument a call changes, or the array a `for` \
                loop changes";
             ]
           "`&` can't be used here")
  | Unop (_, a, _) | Try a | Attempt a | Release a | Assert a
  | Yield a | Yield_from a -> walk cx a
  | Return value -> Option.iter (walk cx) value
  | With { items; body } ->
      List.iter (walk cx) (with_links items);
      walk cx body
  | Fail (_, args) -> List.iter (fun (_, a) -> walk cx a) args
  | Binop (_, a, b, _) ->
      walk cx a;
      walk cx b
  | If (c, t, f) -> List.iter (walk cx) (c :: t :: Option.to_list f)
  | Call (f, args) ->
      walk cx f;
      List.iter (arg cx) args
  | Lambda (_, body) -> walk cx body
  | Inline_handler l ->
      walk { cx with inline = Some (bound_in l) } l
  | Handler { state; arms; _ } ->
      let cx = { cx with in_handler = true } in
      List.iter (stmt cx) state;
      List.iter
        (fun (a : handler_arm) ->
          match a.arm_impl.kind with
          | Lambda (ps, body) ->
              no_inout cx ps;
              walk cx body
          | _ -> walk cx a.arm_impl)
        arms
  | Block (stmts, last) ->
      List.iter (stmt cx) stmts;
      walk cx last
  | Con (_, args) -> List.iter (fun (_, a) -> walk cx a) args
  | Record (_, fields) | Con_named (_, fields) ->
      List.iter (fun (_, v) -> walk cx v) fields
  | Update { base; fields; _ } ->
      walk cx base;
      List.iter (fun (_, v) -> walk cx v) fields
  | Array xs | Tuple xs -> List.iter (walk cx) xs
  | Assign { target; value; _ } ->
      guard cx (fun () ->
          writable cx target ~what:"this can't be assigned to" ();
          match range_in target with
          | Some r ->
              let x = Option.value (cx.source r) ~default:"xs[a..b]" in
              Diag.error r.loc
                ~help:
                  (sprintf
                     "pass it to a function that changes it, `f(&%s)`, or \
                      change each element, `for x in &%s`"
                     x x)
                "a range of an array is changed through `&`"
          | None -> ());
      walk_indices cx target;
      walk cx value
  | For { over = Each { kind = Ref a; _ }; body; _ } ->
      cx.defer_for a (fun () ->
          writable cx a ~what:"`&` needs a variable it can change" ());
      walk_indices cx a;
      walk cx body
  | For { over = Each iter; body; _ } ->
      walk cx iter;
      walk cx body
  | For { over = Range (lo, hi); body; _ } ->
      walk cx lo;
      walk cx hi;
      walk cx body
  | While { cond; body } ->
      walk cx cond;
      walk cx body
  | Match (subject, arms) ->
      walk cx subject;
      List.iter
        (fun (a : arm) ->
          Option.iter (walk cx) a.arm_guard;
          walk cx a.arm_body)
        arms

(* A statement: a `finally`, in a handler, is an arm's lambda too. *)
and stmt cx = function
  | Let { value; _ } | Expr value -> walk cx value
  | Let_pattern { value; else_; _ } ->
      walk cx value;
      Option.iter (walk cx) else_
  | Finally f -> (
      match f.kind with
      | Lambda (ps, body) ->
          no_inout cx ps;
          walk cx body
      | _ -> walk cx f)

(* A call's argument. One passed with `&` is a place the call changes,
   unless it's a method call, `f(&s.pop())`, which changes `s` itself. *)
and arg cx (a : expr) =
  match a.kind with
  | Ref p when changed_receiver a = None ->
      guard cx (fun () ->
          writable cx p ~what:"`&` needs a variable it can change" ());
      walk_indices cx p
  | _ -> walk cx a

(* The index expressions inside a place, like the `i` in `xs[i].pos`. *)
and walk_indices cx (e : expr) =
  match e.kind with
  | Index (a, i) ->
      walk_indices cx a;
      walk cx i
  | Slice (a, lo, hi) ->
      walk_indices cx a;
      walk cx lo;
      walk cx hi
  | Field (r, _) -> walk_indices cx r
  | _ -> ()

let program ?defer_for sink (r : Resolve.t) =
  let defer_for = Option.value defer_for
      ~default:(fun _ check -> Diag.recover sink ~default:() check) in
  let source =
    Ast.source ~type_name:(Resolve.type_name r)
      ~value_name:(Resolve.value_name r)
  in
  List.iter
    (fun (f : fn_def) -> walk { sink; source; in_handler = false; inline = None; defer_for } f.body)
    (Ast.functions r.prog)
