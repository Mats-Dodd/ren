(* Exclusivity: while a place is being changed, nothing else may use it
   (foundations.md, decision 2). It's what lets a block capture its
   frame's variables by reference and change them, and lets the
   interpreter, and later the compiler, treat every `inout` as a copy in
   and a copy out: an `&` parameter aliases nothing else the callee can
   see, not another parameter, a block's capture, or handler state.

   It runs after inference, since it needs types: whether a value is
   copied or counted, and which arguments are blocks. Like the type
   checker, it checks one function at a time, in one walk over its body,
   with no dataflow and no lifetimes: how long each access lasts comes
   from the syntax, a call, a loop or an instant.

   A place is a variable followed by fields and indices, `user.plan` or
   `xs[i]`. Different fields don't overlap, any two indices may be the
   same element, and a place overlaps its prefixes. The accesses, and how
   long each lasts:

   - reading a copied value, an `Int` or a record of them: an instant;
   - a counted value passed to a parameter that only reads it, `f(xs)` or
     `xs.len()`: a read for the call, which reads it where it is;
   - `&p`, as an argument or a receiver: a write for the call, from after
     the arguments are evaluated, so `&xs.push(xs.len())` is fine;
   - `p = e` and `p += e`: a write, an instant, after `e`;
   - `for x in p`: a read, an instant, since the loop goes over a snapshot;
   - `for x in &p`: a write for the loop;
   - a block passed to a call: each place it captures, read or written as
     its body uses it, nested blocks included, for the call. A block bound
     by `let` accesses nothing where it's bound, and acts as its captures
     wherever it's called or passed.

   Two overlapping accesses, at least one a write, are an error, but
   blocks passed to the same call don't conflict with each other: the
   callee runs one at a time, and rule A below keeps one from running
   inside another. Inside a handler's arm, a dependency call, or a call of
   a block parameter, is a write of all the handler's `var`s for that
   call (foundations.md, decision 2): at a dependency call, `Async.until`,
   other tasks can run the handler, and a block parameter can call into
   it again. An operation otherwise keeps its instance across its own
   dependency calls (decision 10), so this is more than tasks need; it's
   what the decision says, and natively it's what keeps a borrow of the
   state from being changed under it at `Async.until`.

   Rule A: a block parameter, or a block that captures one, can't be
   passed to a call of a block parameter. Otherwise a block could run
   inside itself, and a block that changes `n` while it calls the one
   it's given would change it twice at once. A recursive combinator like
   `fix` is written as a named recursive function instead.

   Rule B (stage 11a): a block parameter's mode is part of its type. A
   block passed to a `concurrent` parameter, `Async.map`'s `f`, may run on
   several tasks at once during the call, so it only reads what it
   captures; one passed to a `spawned` one, `Scope.spawn`'s `body`, runs
   as a task until the `Async.scope` that made its scope ends, so it only
   reads too, and what it reads by reference (rule C: only the variables
   of the frame that called `Async.scope`) can't change until then. A
   block parameter passed on to such a parameter needs a mode at least as
   strong, `Spawned` over `Concurrent` over `Ordinary`: written on a
   public function, inferred on a private one, before any body is checked
   ([infer_modes]). Rule D, that a scope and a task's handle are kept as
   blocks are, is inference's (Infer_top.check_blocks).

   Prior art: this is Swift's static exclusivity for non-escaping
   closures, without the dynamic half, since a block never escapes.
   SE-0176 (/tmp/ren-refs/swift-evolution/proposals/
   0176-enforce-exclusive-access-to-memory.md:552-671) defines
   non-escaping closures and the Non-Escaping Parameter Call Restriction
   (NPCR), which is rule A. Swift's checker counts what a non-escaping
   closure accesses at the call it's passed to, including closures passed
   to it in turn (/tmp/ren-refs/swift/lib/SILOptimizer/Mandatory/
   DiagnoseStaticExclusivity.cpp:814-845), as [call] does here with a
   block's captures.

   Each problem is reported to the sink, and checking carries on. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf

type kind = Read | Write

(* A step of a place's path: a field, an index, or a range of them,
   `xs[a..b]`, as it's written if it can be shown, for messages. A range is
   indices, so it may overlap any other (foundations.md, decision 17). *)
type step =
  | SField of string
  | SIndex of string option
  | SRange of string option * string option

(* Code a help can move before the call, and a name for its `let`. *)
type hoisted = (string * string) option

(* Why an access happens, which words what an error says about it. *)
type why =
  | Used of hoisted
      (** read or changed where it's written; for a read, the code that reads it
      *)
  | Called  (** a block parameter, called *)
  | Passed  (** `&p`, for the call *)
  | Borrowed of hoisted
      (** a counted value passed to a parameter that only reads it, for the call
      *)
  | Looped of string  (** `for x in &p`, for the loop; the element's name *)
  | Dep_call of string option
      (** in a handler's arm, a dependency call, which changes all its `var`s:
          the call, as it's written *)
  | Block_call of string
      (** in a handler's arm, a call of the block parameter of that name, which
          changes all its `var`s *)

type access = {
  var : binder;
  path : step list;
  kind : kind;
  loc : Loc.t;
  why : why;
  block_param : bool;  (** [var] is a block parameter, which rule A is about *)
}

(* The accesses an argument makes for the whole of its call, or the
   callee's own. *)
type group = {
  held : access list;
  via : Loc.t option;  (** the block they're made through, if they are *)
  sibling : bool;
      (** a block passed to an ordinary parameter, which never conflicts with
          another *)
}

let none = { held = []; via = None; sibling = false }

type ctx = {
  nodes : Infer.node Infer.Nodes.t;
  types : (Path.t, Iface.type_decl) Hashtbl.t;
  schemes : (Path.t, Ty.scheme) Hashtbl.t;
      (** the scheme of each function the module can call, its own and its
          imports', members included *)
  sink : Diag.sink;
  source : expr -> string option;
      (** code as it's written, for messages (Ast.source) *)
  depth : int;  (** how many lambdas deep *)
  loops : access list;  (** the `for &` loops around, each a write *)
  blocks : (int, access list) Hashtbl.t;
      (** the blocks bound by `let`, by their binder, each with what it accesses
          of the variables from outside it *)
  state : binder list option;
      (** inside a handler's arm or its `finally`: the handler's `var`s *)
  in_op : bool;
      (** inside a handler's arm, blocks included, where `Async.until` is
          written *)
  seen : access list ref;
      (** every access made so far, for the block around it *)
  names : Path.t -> string;  (** how the module writes a type's name *)
  fn_name : string;  (** the function being checked, as it's written *)
  own_modes : (int * Ty.block_mode) list;
      (** the mode of each of its block parameters that isn't ordinary, by
          binder *)
  own_tys : (int * Ty.ty) list;  (** its parameters' types, by binder *)
  tasks : frame list;
      (** the `Async.scope` calls whose bodies are being walked, innermost
          first *)
}

(* An `Async.scope` call whose body is being walked: its body's parameter,
   the scope, by binder; how deep its body is, so that the variables of
   the frame that called it are those bound less deep (rule C); and the
   places the tasks spawned into it so far read by reference, until it
   ends. *)
and frame = { sid : int; sdepth : int; reads : access list ref }

let ty cx (e : expr) =
  match Infer.Nodes.find_opt e.node cx.nodes with
  | Some n -> n.ty
  | None -> Ty.Error

let is_block cx e = match ty cx e with Fun _ -> true | _ -> false

let is_method cx (f : expr) =
  match Infer.Nodes.find_opt f.node cx.nodes with
  | Some { found = Some (Method_of _); _ } -> true
  | _ -> false

(* Whether calling [f] is a dependency call: an operation, or a
   function whose own signature uses a dependency. A block it's given
   that uses one is a dependency call where the block calls it. *)
let dep_call cx (f : expr) =
  let uses p =
    match Hashtbl.find_opt cx.schemes p with
    | Some { Ty.ty = Fun (_, _, _, uses); _ } -> uses.labels <> []
    | _ -> false
  in
  match f.kind with
  | Var (Dep_op _ | Next_op _) -> true
  | Var (Global p) -> uses p
  | Field _ -> (
      match Infer.Nodes.find_opt f.node cx.nodes with
      | Some { found = Some (Method_of p); _ } -> uses p
      | _ -> false)
  | _ -> false

(* ---- block parameters' modes (rule B) ---- *)

let rank : Ty.block_mode -> int = function
  | Ordinary -> 0
  | Concurrent -> 1
  | Spawned -> 2

(* The function a call of [f] calls, if it's one whose scheme is known,
   and the place among its parameters of the call's first argument: 1
   for a method, whose receiver is `self`. *)
let callee_of nodes schemes (f : expr) =
  let known p = if Hashtbl.mem schemes p then Some p else None in
  match f.kind with
  | Var (Global p) -> Option.map (fun p -> (p, 0)) (known p)
  | Field _ -> (
      match Infer.Nodes.find_opt f.node nodes with
      | Some { Infer.found = Some (Method_of p); _ } ->
          Option.map (fun p -> (p, 1)) (known p)
      | _ -> None)
  | _ -> None

(* The mode of the [i]th parameter of the function at [p]. *)
let mode_of schemes p i : Ty.block_mode =
  match Hashtbl.find_opt schemes p with
  | Some (s : Ty.scheme) -> Option.value (List.assoc_opt i s.modes) ~default:Ordinary
  | None -> Ordinary

(* Each of a call [e]'s arguments [args], with the place among the
   callee's arguments of the parameter it's given to: in order, unless
   the call gives a default by name or leaves one out (Infer.Args). *)
let placed nodes (e : expr) args =
  match Infer.Nodes.find_opt e.node nodes with
  | Some { Infer.found = Some (Args xs); _ } ->
      let index (a : expr) =
        let v = match a.kind with Named (_, v) -> v | _ -> a in
        let rec go i = function
          | (x : expr) :: rest ->
              if x.node = v.node || x.node = a.node then i else go (i + 1) rest
          | [] -> -1
        in
        go 0 xs
      in
      List.map (fun a -> (index a, a)) args
  | _ -> List.mapi (fun i a -> (i, a)) args

let call_is p (f : expr) nodes schemes =
  match callee_of nodes schemes f with Some (q, _) -> q = p | None -> false

let async_member name = Path.member (Path.prelude "Async") name

(* ---- copied values ---- *)

(* Whether a value of type [t] is copied, rather than counted (copied.ml):
   reading one is an instant. *)
let copied cx (t : Ty.ty) = Copied.is ~types:(Hashtbl.find_opt cx.types) t

(* ---- places ---- *)

type place = { pvar : binder; ppath : step list; ploc : Loc.t }

let rec place_of cx (e : expr) =
  match e.kind with
  | Var (Local b) -> Some { pvar = b; ppath = []; ploc = e.loc }
  | Field (r, f) ->
      Option.map
        (fun p -> { p with ppath = p.ppath @ [ SField f.name ]; ploc = e.loc })
        (place_of cx r)
  | Index (a, i) ->
      Option.map
        (fun p ->
          { p with ppath = p.ppath @ [ SIndex (cx.source i) ]; ploc = e.loc })
        (place_of cx a)
  | Slice (a, lo, hi) ->
      Option.map
        (fun p ->
          {
            p with
            ppath = p.ppath @ [ SRange (cx.source lo, cx.source hi) ];
            ploc = e.loc;
          })
        (place_of cx a)
  | _ -> None

let access ?(loc : Loc.t option) (p : place) kind why =
  {
    var = p.pvar;
    path = p.ppath;
    kind;
    loc = Option.value loc ~default:p.ploc;
    why;
    block_param = false;
  }

(* One path is a prefix of the other, or they differ only in indices. *)
let rec overlap a b =
  match (a, b) with
  | [], _ | _, [] -> true
  | (SIndex _ | SRange _) :: a, (SIndex _ | SRange _) :: b -> overlap a b
  | SField f :: a, SField g :: b -> f = g && overlap a b
  | _ -> false

(* A dependency call, or a block parameter's, in a handler's arm: it
   stands for what other code might do to the state, so two of them
   don't conflict with each other. *)
let state_write a =
  match a.why with Dep_call _ | Block_call _ -> true | _ -> false

let clash a b =
  a.var.id = b.var.id
  && (a.kind = Write || b.kind = Write)
  && overlap a.path b.path
  && not (state_write a && state_write b)

(* A place as it's written, `r.a` or `xs[i]`. *)
let show_path x path =
  x
  ^ String.concat ""
      (List.map
         (function
           | SField f -> "." ^ f
           | SIndex (Some i) -> "[" ^ i ^ "]"
           | SIndex None -> "[...]"
           | SRange (a, b) ->
               let s = Option.value ~default:"..." in
               "[" ^ s a ^ ".." ^ s b ^ "]")
         path)

let show a = show_path a.var.ident.name a.path

(* Code a help can move into a `let` before the call: [e], named after
   the method it calls or the field it reads. *)
let hoist cx (e : expr) : hoisted =
  Option.map
    (fun code ->
      let name =
        match e.kind with
        | Call ({ kind = Field (_, m); _ }, _) -> m.name
        | Field (_, f) -> f.name
        | Index _ -> "item"
        | Slice _ -> "part"
        | _ -> "before"
      in
      (code, name))
    (cx.source e)

(* ---- messages ---- *)

let report cx ?says ?help ?(notes = []) ?(labels = []) loc msg =
  Diag.report cx.sink (Diag.make ?says ?help ~notes ~labels loc msg)

let block_note = "a block runs during the call it's passed to"

let only_way =
  "an argument passed with `&` has to be the only way the call can reach that \
   value"

(* An access that holds its place for a call or a loop, made where it's
   written. *)
let lasting a =
  match a.why with Passed | Borrowed _ | Looped _ -> true | _ -> false

let read_or_changed a = if a.kind = Write then "changed" else "read"

(* Why a dependency call in an arm is a change of its handler's state. *)
let dep_call_note =
  "a dependency call in an arm counts as a change of the handler's state: \
   at one, `Async.until`, other tasks run the handler"

(* [o] happens while [f], which lasts, holds a handler's state: a
   dependency call, or a block parameter's. *)
let across cx f o =
  let x = f.var.ident.name in
  let label =
    match f.why with
    | Looped _ -> "changed for the whole loop"
    | Borrowed _ -> "read for the whole call"
    | _ -> "changed for the whole call"
  in
  let help ~during =
    match f.why with
    | Borrowed _ ->
        sprintf
          "pass a copy: `let before = %s` before the call, and pass `before`"
          (show f)
    | Looped _ -> sprintf "%s before or after the loop" during
    | _ -> sprintf "%s before or after the change" during
  in
  match o.why with
  | Block_call g ->
      report cx o.loc
        ~says:(sprintf "`%s` is called here" g)
        ~labels:[ (f.loc, label) ]
        ~notes:[ sprintf "`%s` can run this handler again" g ]
        ~help:(help ~during:(sprintf "call `%s`" g))
        (sprintf "`%s` is %s across a call of `%s`" x (read_or_changed f) g)
  | _ ->
      let help =
        match (o.why, f.why) with
        | Dep_call (Some code), Passed ->
            sprintf
              "make the call first, `let v = %s`, then change `%s` with `v`"
              code x
        | _ -> help ~during:"make the dependency call"
      in
      report cx o.loc ~says:"a dependency call"
        ~labels:[ (f.loc, label) ]
        ~notes:[ dep_call_note ]
        ~help
        (sprintf "`%s` is %s across a dependency call" x (read_or_changed f))

(* [a], made by a block, happens during [call]: a dependency call, or a
   block parameter's, in a handler's arm, which the block is passed to. *)
let block_across cx a call =
  let x = a.var.ident.name in
  let across, note =
    match call.why with
    | Block_call g ->
        (sprintf "a call of `%s`" g, sprintf "`%s` can run this handler again" g)
    | _ ->
        ( "a dependency call",
          dep_call_note )
  in
  let help =
    if a.kind = Read then
      let c = String.sub x 0 1 in
      let c = if c = x then c ^ "0" else c in
      sprintf "copy it first: `let %s = %s`, and use `%s` in the block" c
        (show a) c
    else
      sprintf
        "change `%s` before or after the call, and pass the change as a value" x
  in
  report cx a.loc
    ~says:(read_or_changed a ^ " here")
    ~labels:[ (call.loc, "the handler's state can change during this call") ]
    ~notes:[ block_note; note ] ~help
    (sprintf "`%s` is %s by this block across %s" x (read_or_changed a) across)

(* Two accesses that overlap, the first made in [va] (a block) if it's
   [Some], the second in [vb]. *)
let conflict cx (a, va) (b, vb) =
  (* the one that lasts, made where it's written, first *)
  let f, vf, o, vo =
    if lasting a && va = None then (a, va, b, vb) else (b, vb, a, va)
  in
  let x = f.var.ident.name in
  (* a block bound by `let` is pointed at where it runs, too *)
  let report cx ?says ?help ?notes ?(labels = []) loc msg =
    let pos (p : Loc.pos) = (p.line, p.col) in
    let runs =
      match vo with
      | Some (l : Loc.t)
        when pos l.start > pos o.loc.start || pos l.stop < pos o.loc.stop ->
          [ (l, "the block runs here") ]
      | _ -> []
    in
    report cx ?says ?help ?notes ~labels:(labels @ runs) loc msg
  in
  match (f.why, vf, o.why, vo) with
  | _, None, (Dep_call _ | Block_call _), _ when lasting f -> across cx f o
  | _, _, _, Some _ when state_write f -> block_across cx o f
  | _, Some _, _, _ when state_write o -> block_across cx f o
  | Looped elem, None, _, None ->
      report cx o.loc
        ~help:(sprintf "inside the loop, use `%s`" elem)
        ~labels:[ (f.loc, sprintf "the loop changes `%s` here" x) ]
        (sprintf "`%s` is being changed by the `for` loop around this" x)
  | Looped elem, None, _, Some _ ->
      report cx o.loc
        ~says:(read_or_changed o ^ " here")
        ~labels:[ (f.loc, "changed for the whole loop") ]
        ~notes:[ block_note ]
        ~help:(sprintf "inside the loop, use `%s`" elem)
        (sprintf "`%s` is %s by this block while the loop changes it" x
           (read_or_changed o))
  | Passed, None, Passed, None ->
      let indices =
        match (List.rev f.path, List.rev o.path) with
        | SIndex (Some i) :: before, SIndex (Some j) :: _ ->
            `Two (show_path x (List.rev before), i, j)
        | SRange (_, hi) :: before, SRange _ :: _
        | SRange (_, hi) :: before, SIndex _ :: _
        | SIndex _ :: before, SRange (_, hi) :: _ ->
            `Ranges (show_path x (List.rev before), hi)
        | _ -> `Other
      in
      let notes, help =
        match indices with
        | `Ranges (xs, hi) ->
            ( [ only_way; sprintf "`%s` and `%s` may overlap" (show f) (show o) ],
              sprintf
                "to change two parts of one array, split it: `&%s.split_at(%s) \
                 fn(&lo, &hi) => ...`"
                xs
                (Option.value hi ~default:"n") )
        | `Two (xs, i, j) ->
            ( [
                only_way;
                sprintf "`%s` and `%s` may be the same element" (show f)
                  (show o);
              ],
              sprintf
                "to exchange them, write `%s.swap(%s, %s)`; otherwise change \
                 one, then the other"
                xs i j )
        | `Other ->
            ( [ only_way ],
              sprintf
                "pass `%s` with `&` once; a second value it changes needs a \
                 `var` of its own"
                (show f) )
      in
      report cx o.loc ~notes ~help
        ~labels:[ (f.loc, "passed with `&` here") ]
        (sprintf "`%s` is passed with `&` twice in this call" x)
  | Passed, None, Borrowed code, None | Borrowed code, None, Passed, None ->
      let p, r = if f.why = Passed then (f, o) else (o, f) in
      let help =
        match code with
        | Some (code, name) ->
            sprintf
              "read it into a `let` before the call, `let %s = %s`, and pass \
               that"
              name code
        | None -> "read it into a `let` before the call, and pass that"
      in
      report cx r.loc ~says:"read for the whole call" ~notes:[ only_way ] ~help
        ~labels:[ (p.loc, "passed with `&` here") ]
        (if show p = show r then
           sprintf "`%s` is passed with `&` and read by the same call" (show p)
         else
           sprintf "`%s` is passed with `&` while `%s` is read by the same call"
             (show p) (show r))
  | Passed, None, _, Some _ when o.kind = Write ->
      report cx o.loc ~says:"changed here" ~notes:[ block_note ]
        ~labels:[ (f.loc, "passed with `&` here") ]
        ~help:
          (sprintf
             "change `%s` in one place: pass the block's change as a value, or \
              apply it after the call"
             x)
        (sprintf
           "`%s` is changed by this block and passed with `&` to the same call"
           x)
  | Passed, None, _, Some _ ->
      let help =
        match o.why with
        | Used (Some (code, name)) | Borrowed (Some (code, name)) ->
            sprintf "read it first: `let %s = %s`, and use `%s` in the block"
              name code name
        | _ -> sprintf "read `%s` into a `let` before the call, and use that" x
      in
      report cx o.loc ~says:"read here" ~notes:[ block_note ] ~help
        ~labels:[ (f.loc, "changed for the whole call") ]
        (sprintf "`%s` is read by this block while the call changes it" x)
  | Borrowed _, None, _, Some _ ->
      report cx o.loc ~says:"changed here"
        ~labels:[ (f.loc, "read for the whole call") ]
        ~notes:
          [
            sprintf "the call reads `%s` where it is, without copying it"
              (show f);
          ]
        ~help:
          (sprintf
             "pass a copy: `let before = %s` before the call, and pass `before`"
             (show f))
        (sprintf "`%s` is changed by this block while the call reads it" x)
  | _ ->
      (* two blocks, one of them the callee. They can reach the place
         through the same code, a block bound by `let` that both call *)
      let labels =
        match vf with
        | Some l when f.loc = o.loc ->
            [
              ( l,
                sprintf "this block %s it too"
                  (if f.kind = Write then "changes" else "reads") );
            ]
        | _ -> [ (f.loc, read_or_changed f ^ " here") ]
      in
      report cx o.loc
        ~says:(read_or_changed o ^ " here")
        ~labels ~notes:[ block_note ]
        ~help:
          (sprintf
             "change `%s` in only one of them, or pass the change as a value" x)
        (sprintf
           "`%s` is used by two blocks that run during this call, and one \
            changes it"
           x)

(* Rule A: [arg], passed to [f], a block parameter, is one itself, or
   captures one, [cap]. *)
let rule_a cx (f : binder) (arg : expr) (cap : access option) =
  let fx = f.ident.name in
  let msg, labels =
    match cap with
    | None -> (
        match arg.kind with
        | Var (Local g) when g.id = f.id ->
            (sprintf "`%s` can't be passed to itself" fx, [])
        | Var (Local g) ->
            ( sprintf "`%s`, a block parameter, can't be passed to `%s`"
                g.ident.name fx,
              [] )
        | _ -> (sprintf "a block parameter can't be passed to `%s`" fx, []))
    | Some c ->
        let g = c.var.ident.name in
        if c.var.id = f.id && c.why = Called then
          ( sprintf "a block that calls `%s` can't be passed to `%s`" fx fx,
            [ (c.loc, sprintf "calls `%s` here" fx) ] )
        else if c.var.id = f.id then
          ( sprintf "a block that captures `%s` can't be passed to `%s`" fx fx,
            [ (c.loc, sprintf "captures `%s` here" fx) ] )
        else
          ( sprintf
              "a block that captures `%s`, a block parameter, can't be passed \
               to `%s`"
              g fx,
            [ (c.loc, sprintf "captures `%s` here" g) ] )
  in
  report cx arg.loc ~labels
    ~notes:
      [
        sprintf
          "`%s` is a block parameter, and a block given to one can't reach \
           one, or it could run inside itself"
          fx;
      ]
    ~help:"write it as a named recursive function" msg

(* Rule B: [b], a block parameter of mode [own], is passed to [arg]'s
   parameter, of mode [wanted], which it isn't as strong as: [callee] is
   the callee as written. *)
let rule_b cx (b : binder) (loc : Loc.t) ~own ~(wanted : Ty.block_mode) ~callee
    =
  let x = b.ident.name in
  let param_ty =
    match Option.value (List.assoc_opt b.id cx.own_tys) ~default:Ty.Error with
    | Fun (ps, r, _, u) as t ->
        (* the block's type as its parameter writes it *)
        let pr =
          Ty.printer ~names:cx.names
            { ty = t; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }
        in
        Ty.show pr (Fun (ps, r, Ty.closed, u))
    | _ -> "fn(...)"
  in
  let mark m = sprintf "mark the parameter: `%s: %s %s`" x m param_ty in
  match (b.bound, own, wanted) with
  | By_param, Ty.Concurrent, Ty.Spawned ->
      report cx loc ~help:"mark the parameter `spawned` instead"
        (sprintf "`%s` is concurrent, so it can't be spawned" x)
  | By_param, _, Ty.Concurrent ->
      report cx loc
        ~notes:[ "a block that runs on several tasks at once can only read what it captures" ]
        ~help:(mark "concurrent")
        (sprintf "`%s` runs on several tasks at once in `%s`, but `%s` doesn't say it can"
           x callee cx.fn_name)
  | By_param, _, _ ->
      report cx loc
        ~notes:[ "a spawned block runs until its scope ends, and can only read what it captures" ]
        ~help:(mark "spawned")
        (sprintf "`%s` is spawned as a task here, but `%s` doesn't say it can be" x cx.fn_name)
  | _, _, _ ->
      (* a lambda's parameter, which has no mode to write *)
      report cx loc
        ~help:
          "pass a block written here instead, or make it a parameter of a \
           named function, marked"
        (sprintf "`%s` is a block's parameter, so it can't say it can run %s" x
           (if wanted = Concurrent then "on several tasks at once"
            else "as a task"))

(* [a], a write in a block given to a parameter of mode [m], of a place
   it captures. *)
let task_write cx (a : access) (m : Ty.block_mode) =
  let x = a.var.ident.name in
  match m with
  | Concurrent ->
      report cx a.loc ~says:"changed here"
        ~notes:[ "a block that runs on several tasks at once can only read what it captures" ]
        ~help:
          "give back what each one makes, and add them up after: \
           `Async.map(xs) fn(x) => ...`, then `.sum()`"
        (sprintf "`%s` can't change in a block that runs on several tasks at once" x)
  | _ ->
      report cx a.loc ~says:"changed here"
        ~notes:[ "a spawned task only reads what it captures, while other tasks run" ]
        ~help:
          "change it through a handler's operation, or give it back: \
           `t.join()` has what the task returned"
        (sprintf "a spawned task can't change `%s`, which it only reads" x)

(* [a] changes a place [r], which a task spawned into a scope that's
   still open reads (rule C). *)
let task_read_clash cx (r : access) (a : access) =
  let x = a.var.ident.name in
  let m = if x = "m" then "m0" else "m" in
  report cx a.loc
    ~labels:[ (r.loc, "read until `Async.scope` ends") ]
    ~notes:[ "a spawned task reads what it captures from the frame that called `Async.scope` where it is, until the scope ends" ]
    ~help:
      (sprintf "copy it for the task, `let %s = %s`, or change it after the scope" m x)
    (sprintf "`%s` can't change while a spawned task reads it" x)

(* ---- `Async.until` and `Async.isolate` (compiler.md, "The rest of
   `Async`") ---- *)

(* `Async.until` at [e], outside a handler's operation, where there's no
   instance to let go of while it waits. *)
let until_outside cx (e : expr) =
  report cx e.loc
    ~help:"move the wait into an operation of the handler whose state it reads"
    "`Async.until` waits for a handler's state to change, so it's only \
     written in one of its operations"

(* The first call in [e] that uses a dependency, and the dependency, as
   it's written: what `Async.until`'s condition can't do. *)
let rec first_dep cx (e : expr) =
  let named p = Some (e.loc, cx.names p) in
  let first_use p =
    match Hashtbl.find_opt cx.schemes p with
    | Some { Ty.ty = Fun (_, _, _, uses); _ } -> (
        match uses.labels with
        | l :: _ -> Some (e.loc, cx.names (Ty.dep_path l.name))
        | [] -> None)
    | _ -> None
  in
  let here =
    match e.kind with
    | Call (f, _) when dep_call cx f -> (
        match f.kind with
        | Var (Dep_op (p, _)) -> named p
        | Var (Next_op (p, _)) -> named p
        | Var (Global p) -> first_use p
        | Field _ -> (
            match Infer.Nodes.find_opt f.node cx.nodes with
            | Some { found = Some (Method_of p); _ } -> first_use p
            | _ -> None)
        | _ -> None)
    | _ -> None
  in
  match here with
  | Some _ -> here
  | None -> List.find_map (first_dep cx) (children e)

(* `Async.until`'s condition uses [dep], at [loc]. *)
let until_uses cx (loc, dep) =
  report cx loc
    ~notes:
      [
        "it's checked again each time the handler is released, so it can \
         only read the handler's state";
      ]
    ~help:"read it in the operation, before the wait"
    (sprintf "`Async.until`'s condition can't use `%s`" dep)

(* [a], given to [callee] as a block that isn't written there. *)
let not_written_here cx (a : expr) ~callee =
  let name = Option.value (cx.source a) ~default:"f" in
  report cx a.loc
    ~help:(sprintf "write the block: `%s fn() => %s()`" callee name)
    (sprintf "`%s` takes a block written here, not `%s`" callee name)

(* What an isolated block changes of what's outside it, [caps]: nothing,
   since nothing it changed may be seen after a panic it's isolated from
   (foundations.md, decision 8). It changes what's outside through
   operations, which a handler's `finally` sees, so those aren't these;
   nor can it call a block parameter, which may change its caller's
   variables. *)
let isolated_changes cx caps =
  let reported = ref [] in
  List.iter
    (fun c ->
      if not (List.mem c.var.id !reported) then
        if c.block_param && c.why = Called then (
          reported := c.var.id :: !reported;
          report cx c.loc
            ~notes:[ "a block it was given can change its caller's variables" ]
            ~help:"call it before the isolate, and isolate what uses what it gives"
            (sprintf "an isolated block can't call `%s`, a block it was given"
               c.var.ident.name))
        else if c.kind = Write && not (state_write c) then (
          reported := c.var.id :: !reported;
          let x = c.var.ident.name in
          report cx c.loc ~says:"changed here"
            ~notes:
              [
                "nothing it changed is seen after a panic, so it changes only \
                 what it returns, and what it changes through operations";
              ]
            ~help:
              (sprintf
                 "give it back as the block's result: `let %s = try \
                  Async.isolate fn() => ...`"
                 x)
            (sprintf "an isolated block can't change `%s`, which is outside it" x)))
    caps

(* ---- the walk ---- *)

let record cx a = cx.seen := a :: !(cx.seen)

(* [a] keeps clear of what the tasks spawned so far into the scopes
   around read: reported once a place. *)
let against_tasks cx (a : access) =
  if a.kind = Write then
    List.iter
      (fun fr ->
        match List.find_opt (fun r -> clash r a) !(fr.reads) with
        | Some r ->
            task_read_clash cx r a;
            (* once is enough: the place is the task's until the scope ends *)
            fr.reads := List.filter (fun r' -> r'.var.id <> r.var.id) !(fr.reads)
        | None -> ())
      cx.tasks

(* An access that lasts an instant: it only has to keep clear of the
   loops around, and of what spawned tasks read. *)
let instant cx (a : access) =
  record cx a;
  List.iter
    (fun l -> if clash l a then conflict cx (l, None) (a, None))
    cx.loops;
  against_tasks cx a

(* A block parameter, [b], used at [loc]. *)
let param_use cx (b : binder) loc why =
  record cx { var = b; path = []; kind = Read; loc; why; block_param = true }

let rec walk cx (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Break -> ()
  | Var _ | Field _ | Index _ | Slice _ -> (
      match place_of cx e with
      | Some p ->
          walk_indices cx e;
          if not (is_block cx e) then
            instant cx (access p Read (Used (hoist cx e)))
      | None -> List.iter (walk cx) (children e))
  | Ref { kind = Call (({ kind = Field _; _ } as f), args); _ } ->
      call cx e f args ~changed:true
  | Ref _ -> (* mut.ml reported it *) ()
  | Call (f, args) -> call cx e f args ~changed:false
  | Lambda _ -> ignore (block cx e)
  | Inline_handler l ->
      (* what it reads is copied when it's made, data that nothing it does
         can change *)
      ignore (block cx l)
  | Block (stmts, last) ->
      List.iter (stmt cx) stmts;
      walk cx last
  | Assign { target; value; _ } -> (
      walk cx value;
      walk_indices cx target;
      match place_of cx target with
      | Some p -> instant cx (access p Write (Used None))
      | None -> ())
  | For { pat; over = Each { kind = Ref a; loc = iter_loc; _ }; body; _ } -> (
      walk_indices cx a;
      match place_of cx a with
      | Some p ->
          let elem = match pat.pkind with PVar x -> x.ident.name | _ -> "_" in
          let l = access p Write (Looped elem) ~loc:iter_loc in
          instant cx l;
          walk { cx with loops = l :: cx.loops } body
      | None -> walk cx body)
  | Handler { state; arms; _ } ->
      List.iter (function Finally _ -> () | s -> stmt cx s) state;
      let vars =
        List.filter_map
          (function Let { name; mut = true; _ } -> Some name | _ -> None)
          state
      in
      (* its `finally`s run as its arms do, when the `with` ends. An arm,
         and a `finally`, binds its parameters beside the handler's state
         (Resolve.arm_lambda), so its body is walked at this depth, not as
         a block one deeper *)
      let arm = { cx with state = Some vars; in_op = true } in
      let body cx (l : expr) =
        match l.kind with Lambda (_, b) -> walk cx b | _ -> walk cx l
      in
      List.iter
        (function Finally f -> body { arm with in_op = false } f | _ -> ())
        state;
      List.iter (fun (a : handler_arm) -> body arm a.arm_impl) arms
  | Unop _ | Binop _ | If _ | Con _ | Con_named _ | Record _ | Update _
  | Match _ | Array _
  | Tuple _
  | For _ | While _ | Fail _ | Try _ | Attempt _ | With _ | Assert _
  | Named _ | Tag_set _ ->
      List.iter (walk cx) (children e)

and stmt cx = function
  | Let { name; value = { kind = Lambda _; _ } as value; mut = false; _ } ->
      (* no access where it's bound: its captures are made where it's
         called or passed *)
      Hashtbl.replace cx.blocks name.id (block cx value)
  | Let { value; _ } | Let_tuple { value; _ } -> walk cx value
  | Expr e -> walk cx e
  | Finally { kind = Lambda (_, body); _ } ->
      (* in an arm: it runs in the arm's frame, after the rest of it *)
      walk cx body
  | Finally f -> walk cx f

(* A block, checked on its own, and what it accesses of the variables
   from outside it, its captures, nested blocks' included. *)
and block ?(scope = false) cx (e : expr) =
  match e.kind with
  | Lambda (ps, body) ->
      let inner = { cx with depth = cx.depth + 1; loops = []; seen = ref [] } in
      (* the body of an `Async.scope` call: its parameter is the scope its
         tasks are spawned into *)
      let inner =
        match ps with
        | [ s ] when scope ->
            {
              inner with
              tasks =
                { sid = s.pname.id; sdepth = inner.depth; reads = ref [] }
                :: inner.tasks;
            }
        | _ -> inner
      in
      walk inner body;
      List.filter (fun a -> a.var.depth < inner.depth) !(inner.seen)
  | _ -> []

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

(* A call, [e], of [f] with [args]; [changed] if its receiver is passed
   with `&`, `&s.push(1)`. Its arguments are evaluated in order, each
   checked as it's made; then every access that lasts the call starts. *)
and call cx (e : expr) (f : expr) args ~changed =
  let state_writes why loc =
    match cx.state with
    | Some vars ->
        List.map
          (fun v ->
            { var = v; path = []; kind = Write; loc; why; block_param = false })
          vars
    | None -> []
  in
  let why = Dep_call (cx.source e) in
  (* the block parameter called, if it's one *)
  let param =
    match f.kind with
    | Var (Local b) when is_block cx f && not (Hashtbl.mem cx.blocks b.id) ->
        Some b
    | _ -> None
  in
  (* the callee's own accesses, for the call *)
  let callee, receiver =
    match f.kind with
    | Field (r, _) when is_method cx f ->
        let held = if dep_call cx f then state_writes why e.loc else [] in
        ({ none with held }, Some r)
    | Var (Local b) when is_block cx f -> (
        match Hashtbl.find_opt cx.blocks b.id with
        | Some caps -> ({ none with held = caps; via = Some f.loc }, None)
        | None ->
            param_use cx b f.loc Called;
            ( { none with held = state_writes (Block_call b.ident.name) e.loc },
              None ))
    | Lambda _ -> ({ none with held = block cx f; via = Some f.loc }, None)
    | _ ->
        walk cx f;
        let held = if dep_call cx f then state_writes why e.loc else [] in
        ({ none with held }, None)
  in
  (* the callee's parameters' modes (rule B), the scope a spawn's receiver
     is, if its `Async.scope` is being walked, and how the callee is
     written *)
  let callee_p = callee_of cx.nodes cx.schemes f in
  let mode_at i =
    match callee_p with
    | Some (p, off) when i >= 0 -> mode_of cx.schemes p (i + off)
    | _ -> Ty.Ordinary
  in
  let scope_call = call_is (async_member "scope") f cx.nodes cx.schemes in
  let until_call = call_is (async_member "until") f cx.nodes cx.schemes in
  let isolate_call = call_is (async_member "isolate") f cx.nodes cx.schemes in
  if until_call && not cx.in_op then until_outside cx e;
  let callee_name = Option.value (cx.source f) ~default:"this" in
  (* the scopes a block given to a spawned parameter may be spawned into:
     the one the call is given, as its receiver or an argument, if it's
     one being walked; otherwise, since a helper may spawn it into any it
     can reach, every one around *)
  let frames =
    let given =
      List.filter_map
        (fun (a : expr) ->
          match a.kind with
          | Var (Local s) -> List.find_opt (fun fr -> fr.sid = s.id) cx.tasks
          | _ -> None)
        (Option.to_list receiver @ args)
    in
    if given <> [] then given else cx.tasks
  in
  (* [b], a block parameter, passed on where it runs as [m] says *)
  let passed_on (b : binder) loc (m : Ty.block_mode) =
    let own = Option.value (List.assoc_opt b.id cx.own_modes) ~default:Ty.Ordinary in
    if rank own < rank m then
      rule_b cx b loc ~own ~wanted:m ~callee:callee_name
  in
  (* an argument passed to a parameter that only reads it, or a block
     passed to a parameter of mode [m] *)
  let plain ?(m = Ty.Ordinary) (a : expr) ~code =
    if is_block cx a then (
      (* a block passed to an ordinary parameter runs during the call, on
         the caller's task, so blocks passed to one call are siblings; a
         concurrent or spawned one isn't (foundations.md, rules B to D) *)
      let sibling = m = Ordinary in
      (* what a block that runs as [m] says captures: it only reads them,
         and passes on each block parameter it calls *)
      let as_task caps =
        if m = Ordinary then caps
        else
          let changed = ref [] in
          List.iter
            (fun c ->
              if c.block_param && c.why = Called then passed_on c.var c.loc m
              else if
                c.kind = Write && (not (state_write c))
                && not (List.mem c.var.id !changed)
              then (
                changed := c.var.id :: !changed;
                task_write cx c m))
            caps;
          let reads = List.filter (fun c -> c.kind = Read && not c.block_param) caps in
          (* a spawned task reads the variables of the frame that called
             `Async.scope` where they are, until it ends (rule C); the
             others are copied when it's spawned *)
          if m = Spawned then
            List.iter
              (fun fr ->
                fr.reads :=
                  List.filter (fun c -> c.var.depth < fr.sdepth) reads
                  @ !(fr.reads))
              frames;
          reads
      in
      match a.kind with
      | Lambda (_, body) when until_call ->
          (* `Async.until`'s condition is checked only while the instance
             is free, so it conflicts with nothing in its arm; and it's
             checked where the instance is released, so it uses nothing *)
          ignore (block cx a);
          Option.iter (until_uses cx) (first_dep cx body);
          none
      | _ when until_call ->
          (* checked again as other tasks release the instance, so it reads
             the state's cells (Lower.until_released), which a block bound
             elsewhere doesn't *)
          not_written_here cx a ~callee:"Async.until";
          walk cx a;
          none
      | Lambda _ ->
          let caps = block ~scope:scope_call cx a in
          if isolate_call then isolated_changes cx caps;
          { held = as_task caps; via = Some a.loc; sibling }
      | Var (Local b) -> (
          match Hashtbl.find_opt cx.blocks b.id with
          | Some caps ->
              if isolate_call then isolated_changes cx caps;
              { held = as_task caps; via = Some a.loc; sibling }
          | None ->
              param_use cx b a.loc (Used None);
              if isolate_call then not_written_here cx a ~callee:"Async.isolate";
              if m <> Ordinary then passed_on b a.loc m;
              none)
      | Var (Dep_op _ | Next_op _) ->
          {
            held = state_writes (Dep_call (cx.source a)) a.loc;
            via = Some a.loc;
            sibling;
          }
      | _ ->
          walk cx a;
          none)
    else
      match place_of cx a with
      | Some p when not (copied cx (ty cx a)) ->
          walk_indices cx a;
          { none with held = [ access p Read (Borrowed code) ] }
      | _ ->
          walk cx a;
          none
  in
  (* one passed with `&` *)
  let passed (a : expr) ~loc =
    walk_indices cx a;
    match place_of cx a with
    | Some p -> { none with held = [ access p Write Passed ~loc ] }
    | None ->
        walk cx a;
        none
  in
  let receiver =
    match receiver with
    | Some r when changed -> [ passed r ~loc:r.loc ]
    | Some r -> [ plain r ~code:(hoist cx e) ]
    | None -> []
  in
  let args_held =
    List.map
      (fun (i, (a : expr)) ->
        match a.kind with
        | Ref p when changed_receiver a = None -> passed p ~loc:a.loc
        | _ -> plain ~m:(mode_at i) a ~code:(hoist cx a))
      (placed cx.nodes e args)
  in
  (* rule A *)
  Option.iter
    (fun b ->
      List.iter2
        (fun (a : expr) (g : group) ->
          match a.kind with
          | Var (Local c) when is_block cx a && not (Hashtbl.mem cx.blocks c.id)
            ->
              rule_a cx b a None
          | _ when g.via <> None -> (
              match List.find_opt (fun c -> c.block_param) g.held with
              | Some c -> rule_a cx b a (Some c)
              | None -> ())
          | _ -> ())
        args args_held)
    param;
  let groups = (callee :: receiver) @ args_held in
  (* each variable is reported once a call *)
  let reported = ref [] in
  let once (a, va) (b, vb) =
    if not (List.mem a.var.id !reported) then (
      reported := a.var.id :: !reported;
      conflict cx (a, va) (b, vb))
  in
  let rec pairs = function
    | [] -> ()
    | g :: rest ->
        List.iter
          (fun h ->
            if not (g.sibling && h.sibling) then
              List.iter
                (fun a ->
                  List.iter
                    (fun b -> if clash a b then once (a, g.via) (b, h.via))
                    h.held)
                g.held)
          rest;
        pairs rest
  in
  pairs groups;
  List.iter
    (fun g ->
      List.iter
        (fun a ->
          List.iter
            (fun l -> if clash l a then once (l, None) (a, g.via))
            cx.loops;
          against_tasks cx a;
          record cx a)
        g.held)
    groups

(* Rule B for the module's private functions, whose modes aren't written:
   each block parameter takes the strongest mode of the parameters it's
   passed to, itself or in a block it's used in, `Spawned` over
   `Concurrent` over `Ordinary`, to a fixpoint over the module's private
   functions. Modes only go up, and there are three, so it ends. The
   schemes in [schemes] are updated with what's found. *)
let infer_modes (r : Resolve.t) (inferred : Infer.t) schemes =
  let privates =
    List.filter (fun (f : fn_def) -> not f.pub) (Ast.functions r.prog)
  in
  (* what each of [f]'s block parameters is passed to: its place among
     [f]'s parameters, the callee, and the place there *)
  let passes (f : fn_def) =
    let nodes = Path.Map.find (Ast.fn_path r.home f) inferred.nodes in
    let index (b : binder) =
      let rec go i = function
        | (p : param) :: rest -> if p.pname.id = b.id then Some i else go (i + 1) rest
        | [] -> None
      in
      if b.bound = By_param then go 0 f.params else None
    in
    let rec params_in (e : expr) =
      match e.kind with
      | Var (Local b) -> Option.to_list (index b)
      | _ -> List.concat_map params_in (children e)
    in
    let found = ref [] in
    let rec go (e : expr) =
      (match e.kind with
      | Call (g, args) -> (
          match callee_of nodes schemes g with
          | Some (p, off) ->
              List.iter
                (fun (i, (a : expr)) ->
                  let ks =
                    match a.kind with
                    | Var (Local b) -> Option.to_list (index b)
                    | Lambda _ -> params_in a
                    | _ -> []
                  in
                  if i >= 0 then
                    List.iter (fun k -> found := (k, p, i + off) :: !found) ks)
                (placed nodes e args)
          | None -> ())
      | _ -> ());
      List.iter go (children e)
    in
    go f.body;
    (Ast.fn_path r.home f, !found)
  in
  let all = List.map passes privates in
  let set path k (m : Ty.block_mode) =
    let s : Ty.scheme = Hashtbl.find schemes path in
    Hashtbl.replace schemes path
      { s with modes = List.sort compare ((k, m) :: List.remove_assoc k s.modes) }
  in
  let rec fix () =
    let changed = ref false in
    List.iter
      (fun (path, edges) ->
        List.iter
          (fun (k, p, j) ->
            let m = mode_of schemes p j in
            if rank m > rank (mode_of schemes path k) then (
              set path k m;
              changed := true))
          edges)
      all;
    if !changed then fix ()
  in
  fix ();
  Path.Map.mapi
    (fun path (s : Ty.scheme) ->
      match Hashtbl.find_opt schemes path with
      | Some found -> { s with modes = found.modes }
      | None -> s)
    inferred.schemes

let program sink ~reachable (r : Resolve.t) (inferred : Infer.t) =
  let types = Hashtbl.create 16 and schemes = Hashtbl.create 64 in
  List.iter
    (fun (td : Iface.type_decl) ->
      Hashtbl.replace types td.path td;
      Path.Map.iter
        (fun p (o : Iface.op) -> Hashtbl.replace schemes p o.oscheme)
        td.members)
    (List.concat_map (fun (i : Iface.t) -> i.types) reachable @ r.types);
  List.iter
    (fun (i : Iface.t) ->
      List.iter
        (fun (v : Iface.value) ->
          Hashtbl.replace schemes (Path.make i.home v.vname) v.scheme)
        i.values)
    reachable;
  Path.Map.iter (Hashtbl.replace schemes) inferred.schemes;
  let found = infer_modes r inferred schemes in
  let source =
    Ast.source ~type_name:(Resolve.type_name r)
      ~value_name:(Resolve.value_name r)
  in
  List.iter
    (fun (f : fn_def) ->
      let path = Ast.fn_path r.home f in
      let nodes = Path.Map.find path inferred.nodes in
      let s : Ty.scheme = Hashtbl.find schemes path in
      let ids = List.map (fun (p : param) -> p.pname.id) f.params in
      let own_tys =
        match s.ty with
        | Fun (ps, _, _, _) when List.length ps = List.length ids ->
            List.combine ids (List.map (fun (q : Ty.param) -> q.ty) ps)
        | _ -> []
      in
      walk
        {
          nodes;
          types;
          schemes;
          sink;
          source;
          depth = 0;
          loops = [];
          blocks = Hashtbl.create 8;
          state = None;
          in_op = false;
          seen = ref [];
          names = Resolve.type_name r;
          fn_name = Ast.fn_name f;
          own_modes =
            List.filter_map
              (fun (i, m) -> Option.map (fun id -> (id, m)) (List.nth_opt ids i))
              s.modes;
          own_tys;
          tasks = [];
        }
        f.body)
    (Ast.functions r.prog);
  found
