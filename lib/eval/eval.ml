(* A tree-walking interpreter over Core (core.ml): the "interpreted Ren"
   milestone on the roadmap.

   By the time a program gets here it has been resolved, checked,
   type-checked and lowered, so it can't add a Bool to an Int or call a
   function that doesn't exist, and every change it makes is an assignment
   to a local variable. What's left is failing, which the program says it
   can do, and panics, like division by zero. A panic is the running
   program's fault, not a mistake in its source, so it's an exception of
   its own rather than a diagnostic.

   Values are never changed in place. A variable is a cell ([ref]) holding a
   value, and lowering has turned `user.plan = Free` or `xs[i] = v` into
   building a new value and assigning it to the variable, so a value some
   other name holds can't change under it. That's value semantics, done the
   slow way; stage 11 makes it cheap.

   A [Fail] raises [Failed], an OCaml exception, which the nearest [Handle]
   catches. It never leaves the interpreter: a call returns what its
   callee failed with as a [result] (OCaml's [Ok v] or [Error e]), so it
   can write its `inout` arguments back first, and if `main` fails, [run]
   raises [Uncaught] instead.

   What's installed is evidence (core.ml): a value in a variable like any
   other, passed to each call as its hidden parameter. A call of an
   operation finds its dependency's implementation in it by the
   dependency's path, never by a name the program spells.

   A value is shown through its type (shown.ml), which for a generic
   function only its caller knows: `print<T>`'s `T` is whatever the caller
   passes. So a generic function is given a descriptor of the type each of
   its type variables stands for, as a hidden parameter, which lowering
   made explicit (core.ml, [desc]), and the interpreter only evaluates
   them, as it does evidence: it never works a type out.

   [==] is the same: what `T` stands for decides how two values of it are
   compared, so a generic function that compares them is given `T`'s `eq`
   dictionary (core.ml, [dict]). A dictionary is a function of the
   interpreter's: for a type known where it's built, it compares two
   values as the type's declaration says, and wherever that has the
   function's type variable, through the dictionary the function was given
   for it. Inference makes sure nothing compared has a function in it, so
   none is ever reached. *)

open Core
open Value

let sprintf = Printf.sprintf

type wrap = { meth : string; recv : Loc.t; arg : Loc.t option }

(* A panic: where, what it says, the wrapping method its help suggests
   for an overflow, its notes, the task it was in first among them, and
   a help of its own. *)
exception Panic of {
  loc : Loc.t;
  msg : string;
  wrap : wrap option;
  notes : string list;
  help : string option;
}
exception Uncaught of { shown : string; written : string }
exception Assert_failed of { loc : Loc.t; sides : (string * string) option }
exception Went_differently of { loc : Loc.t; differs : Journal.differs }

(* A panic at [loc], in the task running, which a note says if it isn't
   a root (compiler.md, "Errors and panics show the task path"). *)
let panic_at ?wrap ?(notes = []) ?help loc msg =
  let task =
    match Sched.task_path () with
    | Some p -> [ "in the task " ^ p ]
    | None -> []
  in
  Panic { loc; msg; wrap; notes = task @ notes; help }

let panic ?wrap ?notes ?help loc msg =
  raise (panic_at ?wrap ?notes ?help loc msg)

(* The panic [p], said at [loc] instead: a panic in the prelude, whose
   source can't be shown, is said at the program's call that reached it. *)
let moved loc = function
  | Panic p -> Panic { p with loc }
  | e -> e

(* A call the program made at [loc], past the end of a recording that
   ended in a panic at [at] (Journal.Recorded_panic): the panic, if it
   was here, and otherwise what [instead] gives, the replay having gone
   differently here, or a test having gone past the bug's end. *)
let recorded_panic loc ~at ~msg ~instead =
  if Journal.at_place ~at loc then panic_at loc msg
  else
    match instead () with
    | Journal.Differs differs -> Went_differently { loc; differs }
    | e -> e

(* An error on its way to the [Handle] that catches it. *)
exception Failed of Value.t

(* A [Break] on its way to the [While] it leaves. Core Lint makes sure
   there's one around it, in the same function or block. *)
exception Broke

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug what = failwith ("bug: checking or lowering let through " ^ what)

(* The program's top-level functions, by path, its associated values
   once they're made, and its types, with the function that shows each
   type that has a `show` method of its own, the `key` of each that has
   one, and the member that gives each its operators and associated
   values (Core.program). Nothing else
   is global: what's installed is evidence (core.ml), held in a variable
   like any value. [showing] are the types whose own `show` method the
   program is inside. [depth] is how many calls deep the program is, not
   counting tail calls: one cell, shared by every copy of the [ctx] made
   with [{ cx with ... }]. *)
type ctx = {
  fns : (Path.t, fn_def) Hashtbl.t;
  values : (Path.t, Value.t) Hashtbl.t;
  types : Shown.types;
  shows : (Path.t, Path.t) Hashtbl.t;
  keys : (Path.t, Path.t) Hashtbl.t;
  ops : (Path.t * string, Path.t) Hashtbl.t;
  showing : Path.t list;
  depth : int ref;
  dir : string;
      (** the folder of the file the code running is in, which a test's
          `replay(file)` finds its journal from *)
  trace : Trace.t option;  (** `ren run --trace`'s tree of calls, if it's on *)
  outputs : (string * string, unit) Hashtbl.t;
      (** the operations of the built-in dependencies that give nothing, `()`,
          by their dependency and name: a journal's outputs ([gives_nothing]) *)
  site : string;
      (** the label of the code running, the function it's written in, `serve`,
          or `handler.op` in a handler's arm, which a task it spawns is
          labelled by ([site_of]); the prelude's code keeps its caller's *)
  entry : Path.t option;
      (** the test running, whose code's label is `test` *)
  call : Loc.t option;
      (** the program's call the prelude's code running was reached from,
          which a task waiting in it is said to wait at ([at_call]) *)
}

(* How many calls deep a program can go before it's stopped with a panic.
   OCaml's own stack would run out somewhere past this, but only after
   growing so large that every garbage collection on the way there scans
   all of it, which took minutes; a limit of our own is reached in a
   fraction of a second. *)
let max_depth = 100_000

(* The program went [max_depth] calls deep: [load], [run] and [run_test]
   report it as a panic at the function they started ([overflowed]). *)
exception Too_deep

(* What evaluating a function's body in tail position gives: its value,
   or the call it ends in, still to be made. That call is made by the loop
   in [finish], after the body that made it has returned, so a function
   that calls itself last, as a loop written as recursion does, runs in
   constant stack however many times it goes round. *)
type step =
  | Done of Value.t
  | Tail of {
      loc : Loc.t;  (** where the call is *)
      f : Value.t;
      args : Value.t list;
      ev : Value.t;  (** the evidence it's passed *)
      site : string;  (** the label of the code it's in ([ctx]'s) *)
      call : Loc.t option;  (** and the program's call it's under ([ctx]'s) *)
    }

(* ---- numbers ----

   The arithmetic is Arith's (arith.ml), shared with the methods the
   operators are, `n.add(2)`; here a panic is given where the operation
   is. [at] are the operands' expressions, for an overflow's help to show
   them calling the wrapping method, `n.wrapping_add(1)`: none for an
   operator through a dictionary, on a `T`, which has no such method. *)

(* An overflow's panic: with the help, if the left side is written as an
   `Int`, which has the method [meth], and not a `with numeric` type. *)
let overflowed ~(at : expr list) loc op meth shown =
  let wrap =
    match at with
    | { ty = Con (p, []); loc = recv; _ } :: rest when p = Path.prelude "Int" ->
        let arg = match rest with b :: _ -> Some b.loc | [] -> None in
        Some { meth; recv; arg }
    | _ -> None
  in
  panic ?wrap loc (Arith.overflow_message ~op ~shown)

(* [f ()], one operation of Arith's, with its panic said at [loc]. *)
let arith ~at loc f =
  try f () with
  | Arith.Overflowed { op; meth; shown } -> overflowed ~at loc op meth shown
  | Arith.Undefined msg -> panic loc msg

let binop ~at loc (op : Ast.binop) a b =
  arith ~at loc (fun () ->
      Arith.binop ~made:(fun () -> Nan.tag_at loc) op a b)

let neg ~at loc v = arith ~at loc (fun () -> Arith.neg v)

let element loc (xs : vec) i =
  if i < 0L || i >= Int64.of_int xs.len then
    panic loc
      (Printf.sprintf "index %Ld is out of bounds for an array of length %d" i
         xs.len)
  else nth xs (Int64.to_int i)

(* [v] stored as a value of the sized type [k] (sized.ml): an `Int` or a
   `Float`, checked that it fits, or with [wrap], an `Int`'s low bits. *)
let stored loc ~wrap k v =
  match (v, wrap) with
  | VInt n, true -> VInt (Sized.wrap k n)
  | VInt n, false ->
      if Sized.fits k n then v
      else panic loc (Sized.doesnt_fit k (Int64.to_string n))
  | VFloat f, false -> (
      match Sized.float32 f with
      | Some r -> VFloat r
      | None -> panic loc (Sized.doesnt_fit k (Ast.show_float f)))
  | _ -> bug "a sized value that isn't a number"

(* An index bounds.ml proved in bounds is: a native build doesn't check
   it, so its being out of bounds here is a bug in the compiler, not a
   panic of the program's. *)
let proved (b : bounds) (xs : vec) i =
  if b = In_bounds && (i < 0L || i >= Int64.of_int xs.len) then
    bug "an index proved in bounds is out of them"

(* [op] on [args], whose expressions are [at]. *)
let prim loc op args (at : expr list) =
  match (op, args) with
  | Neg, [ v ] -> neg ~at loc v
  | Not, [ VBool b ] -> VBool (not b)
  | Binop op, [ x; y ] -> binop ~at loc op x y
  | Length, [ VArray xs ] -> VInt (Int64.of_int xs.len)
  | Get_index b, [ VArray xs; VInt i ] ->
      proved b xs i;
      element loc xs i
  | Entries, [ VTable t ] ->
      array_of_list (List.map (fun (k, v) -> VTuple [ k; v ]) (Table.to_list t))
  | Members, [ VTable t ] -> array_of_list (List.map fst (Table.to_list t))
  | Set_index b, [ VArray xs; VInt i; x ] ->
      proved b xs i;
      ignore (element loc xs i);
      let ys = items xs in
      ys.(Int64.to_int i) <- x;
      array ys
  | Slice Range, [ v; VInt a; VInt b ] ->
      (try Builtins.slice_value v a b
       with Builtins.Panic msg -> panic loc msg)
  | Slice Before, [ v; VInt n ] ->
      (try fst (Builtins.split_halves v n)
       with Builtins.Panic msg -> panic loc msg)
  | Slice After, [ v; VInt n; _ ] -> snd (Builtins.split_halves v n)
  | Splice, [ v; VInt a; VInt b; w ] -> Builtins.splice v a b w
  | Join, [ a; b ] -> Builtins.join a b
  | Vacant, [ v ] -> v
  | New_cell, [ v ] -> VCell (ref v)
  | Get_cell, [ VCell c ] -> !c
  | Set_cell, [ VCell c; v ] ->
      c := v;
      VUnit
  | _ -> bug ("`" ^ show_prim op ^ "` on the wrong values")

let truth = function VBool b -> b | _ -> bug "a non-Bool condition"

(* Match a value against a pattern. On success, return the environment
   extended with the variables the pattern binds. *)
let rec match_pattern p v env =
  match (p.pkind, v) with
  | PWild, _ -> Some env
  | PVar x, _ -> Some (Env.add x.id (ref v) env)
  | PInt n, VInt m -> if n = m then Some env else None
  | PBool b, VBool c -> if b = c then Some env else None
  | PCon (_, c, ps), VCon { name; args; _ } when c = name ->
      match_all ps args env
  | PTag (t, ps), VTag { name; args; _ } when t = name -> match_all ps args env
  | POr ps, _ -> List.find_map (fun p -> match_pattern p v env) ps
  | PTuple ps, VTuple xs -> match_all ps xs env
  | _ -> None

and match_all ps vs env =
  match (ps, vs) with
  | [], [] -> Some env
  | p :: ps, v :: vs -> Option.bind (match_pattern p v env) (match_all ps vs)
  | _ -> None

let cell env (v : var) =
  match Env.find_opt v.id env with
  | Some c -> c
  | None -> bug ("`" ^ v.name ^ "` used outside its scope")

(* What [f] is, for a bug report. *)
(* The prelude's source at [loc], which is on one line. *)
let prelude_text (loc : Loc.t) =
  let line =
    List.nth
      (String.split_on_char '\n' (String.trim Prelude.source))
      (loc.start.line - 1)
  in
  String.sub line (loc.start.col - 1) (loc.stop.col - loc.start.col)

(* What a failed `assert` [a] of the prelude's says: the function it's
   in, which the program called, what it needs, and what each variable in
   it is, `` `take` needs `n >= 0`, but `n` is -1 ``. The function is the
   prelude's last declared before [a]. *)
let unmet cx env (a : Core.expr) =
  let fn =
    Hashtbl.fold
      (fun _ (f : fn_def) found ->
        match found with
        | _
          when f.loc.file <> Prelude.file
               || f.loc.start.line > a.loc.start.line
               || f.origin <> Written ->
            found
        | Some (g : fn_def) when g.loc.start.line >= f.loc.start.line -> found
        | _ -> Some f)
      cx.fns None
  in
  let who =
    match fn with
    | Some f -> Printf.sprintf "`%s`" (Path.short f.path)
    | None -> "this call"
  in
  let rec locals (e : Core.expr) =
    match e.kind with
    | Local v -> [ v ]
    | _ -> List.concat_map locals (Core.children e)
  in
  let values =
    List.map
      (fun (v : var) -> Printf.sprintf "`%s` is %s" v.name (show !(cell env v)))
      (List.sort_uniq compare (locals a))
  in
  match values with
  | [] ->
      Printf.sprintf "%s needs `%s`, and it isn't so" who (prelude_text a.loc)
  | _ ->
      Printf.sprintf "%s needs `%s`, but %s" who (prelude_text a.loc)
        (String.concat " and " values)

let describe = function
  | VFn (p, _, _) -> "`" ^ Path.local p ^ "`"
  | VBuiltin (x, _, _) -> "`" ^ Intrinsic.name x ^ "`"
  | VClosure { body; _ } ->
      Printf.sprintf "a block (its body at %s:%d)" body.loc.file
        body.loc.start.line
  | _ -> "something that isn't a function"

(* The evidence in [v], for [what]: threading it wrongly is a bug Core
   Lint should have caught, but `ren run` doesn't lint, so say where. *)
let evidence_in env (v : var) what =
  match Option.map ( ! ) (Env.find_opt v.id env) with
  | Some (VEvidence installed) -> installed
  | Some _ -> bug (what ^ " with something that isn't evidence")
  | None -> bug (what ^ " with evidence that isn't in scope")

(* The type [d] describes (core.ml, [desc]): built from its parts, with
   what the hidden type parameters it names hold, as a constructor's value
   is. *)
let rec type_of env (d : desc) : Ty.ty =
  let row r : Ty.row =
    {
      labels =
        List.map
          (fun (name, ds) : Ty.label ->
            { name; payload = List.map (type_of env) ds })
          r.dlabels;
      tail = r.dtail;
    }
  in
  match d with
  | Known t -> t
  | Param v -> (
      match !(cell env v) with
      | VType t -> t
      | _ -> bug ("a descriptor built from `" ^ v.name ^ "`, which isn't one"))
  | Applied (p, ds) -> Con (p, List.map (type_of env) ds)
  | Errs e -> Errors (row e)

(* The dictionary the hidden dictionary parameter [v] holds. *)
let dict_in env (v : var) =
  match !(cell env v) with
  | VDict d -> d
  | _ -> bug ("a dictionary built from `" ^ v.name ^ "`, which isn't one")

(* Two values the same, by an `eq` dictionary. *)
let equal_by (d : Value.dict) x y =
  match d with Eq f -> f x y | _ -> bug "`==` through a dictionary not `eq`'s"

(* [f ()], which walks a value as [what] does, `==` or `<`: a NaN it
   finds panics at [loc] (nan.ml). *)
let comparing loc what f =
  try f () with Nan.Seen x -> panic loc (Nan.observed (Nan.compared what) x)

(* The binary operator a requirement is: `add` is `+`. *)
let binop_of_req req : Ast.binop =
  match req with
  | "add" -> Add
  | "sub" -> Sub
  | "mul" -> Mul
  | "div" -> Div
  | "rem" -> Mod
  | _ -> bug ("`" ^ req ^ "` as a binary operator")

(* An [Int]'s or a [Float]'s operator, as a dictionary has it, which is
   given where its operands are and doesn't need them. *)
let number_op req loc (_ : Loc.t list) vs =
  (* no help: the operands are a `T`'s, which has no `wrapping_add` *)
  match (req, vs) with
  | "neg", [ v ] -> neg ~at:[] loc v
  | _, [ x; y ] -> binop ~at:[] loc (binop_of_req req) x y
  | _ -> bug ("`" ^ req ^ "` on the wrong number of values")

(* ---- task labels ----

   A task's path labels it by the code its spawn is written in
   (compiler.md, "Structured tasks"): the function's name, or a handler's
   and its operation's, `ticks.tick`, for an arm; and a test's, `test`.
   It's kept in [cx.site] as the code runs, set where a function or a
   block of the program's starts, and kept as it is by the prelude's,
   which isn't anyone's code. *)

(* The label of the function a block is written in, from its name
   (Ty.lambda_id), `main.serve#2`: the function's path, without its
   module, which has no `.` in it. *)
let block_label name =
  let fn =
    match String.index_opt name '#' with
    | Some i -> String.sub name 0 i
    | None -> name
  in
  match String.index_opt fn '.' with
  | Some i -> String.sub fn (i + 1) (String.length fn - i - 1)
  | None -> fn

(* [label], a function's, for the code running where [cx.site] is: a
   block written in a handler's arm runs as that arm's, `ticks.tick`,
   whose handler's label is [label]. *)
let site_in cx label =
  if cx.site = label || String.starts_with ~prefix:(label ^ ".") cx.site then
    cx.site
  else label

(* The label of a block named [name], for the code running where
   [cx.site] is: a test's own is `test`. *)
let block_site cx name =
  let label = block_label name in
  match cx.entry with
  | Some p when Path.local p = label -> "test"
  | _ -> site_in cx label

(* The label of [f], a function of the program, or of what a release
   build made it from (Core.origin). *)
let rec fn_label cx (f : fn_def) =
  if Some f.path = cx.entry then "test"
  else
    match f.origin with
    | Written -> Path.local f.path
    | Copy p -> (
        match Hashtbl.find_opt cx.fns p with
        | Some g -> fn_label cx g
        | None -> Path.local p)
    | Lifted_block name -> block_site cx name
    | Lifted_op { handler; op; _ } -> Path.local handler ^ "." ^ op

(* [v], copied for a task it's spawned as: each variable it captured, a
   cell of its own, and each block it holds, the same. A spawned block
   only reads what it captures (excl.ml, rule C), and what it reads from
   the frame that called `Async.scope` can't change until the scope ends,
   so a copy reads just what the variable would have; and one bound
   inside the scope, a loop's, is read as it was when the task was
   spawned, as rule C says (async.md, "What a task can touch"). A handler
   state's cell is a value ([VCell]), so the task still shares it. *)
let rec copied v =
  match v with
  | VClosure c ->
      VClosure { c with env = Env.map (fun r -> ref (copied !r)) c.env }
  | v -> v

(* Where [loc] is, `server.ren:9:3`, as the deadlock panic says a task
   waits there (Sched.wait). *)
let where (loc : Loc.t) = sprintf "%s:%d:%d" loc.file loc.start.line loc.start.col

(* The program's call the prelude's code running was reached from, if
   it's known ([ctx]'s [call]). *)
let at_call cx = Option.map where cx.call

(* The tag a `finally` is given for a body that was cancelled,
   `Err(Cancelled)`'s. *)
let cancelled_tag = VTag { name = "Cancelled"; args = []; tys = [] }

let is_cancelled_tag = function
  | VTag { name = "Cancelled"; args = []; _ } -> true
  | _ -> false

(* The scope or the task a value of `Scope` or `Task<T>` is. *)
let scope_of = function
  | VSched (Sched.Scope sc) -> sc
  | _ -> bug "a scope that isn't one"

let task_of = function
  | VSched (Sched.Handle t) -> t
  | _ -> bug "a task's handle that isn't one"

let rec eval cx env (e : expr) =
  match e.kind with
  | Int n -> VInt n
  | Float f -> VFloat f
  | Bool b -> VBool b
  | Str s -> VStr s
  | Unit -> VUnit
  | Local v -> !(cell env v)
  | Global (p, _, ds, dicts) ->
      VFn
        ( p,
          List.map (type_of env) ds,
          List.map (fun d -> VDict (dict cx env d)) dicts )
  | Global_value (p, _) -> (
      match Hashtbl.find_opt cx.values p with
      | Some v -> v
      | None -> bug ("the value `" ^ Path.local p ^ "` used before it's made"))
  | Intrinsic (x, _, ds, dicts) ->
      VBuiltin
        ( x,
          List.map (type_of env) ds,
          List.map (fun d -> VDict (dict cx env d)) dicts )
  | Dep_call { dep; dargs; op; ev; args; next; fty } -> (
      (* the innermost implementation of [dep] at [dargs]: a record of
         functions, the operation's run with what was installed where it
         was. A generic one's instance is found by its path and the types
         its descriptors stand for (compiler.md, "Generic dependencies") *)
      let args = eval_all cx env args in
      (* a task asked to stop stops here, before the call (async.md,
         "Cancellation") *)
      Sched.check ();
      let what = Printf.sprintf "a call of `%s.%s`" dep.name op in
      let tys = List.map (type_of env) dargs in
      match
        List.find_opt
          (fun (i : installed) -> i.dep = dep && i.args = tys)
          (evidence_in env ev what)
      with
      | Some { impl = VRecord ops; outer; _ } -> (
          match List.assoc_opt op ops with
          | Some f -> (
              (* a handler's arm of the program's runs as `handler.op` *)
              let cx =
                match f with
                | VClosure { site; _ } when site <> "" ->
                    { cx with site = site ^ "." ^ op }
                (* the prelude's, `Clock.sleep`'s, waits at this call *)
                | VClosure _ when e.loc.file <> Prelude.file ->
                    { cx with call = Some e.loc }
                | _ -> cx
              in
              let call () = fst (call_at cx e.loc f args (VEvidence outer)) in
              match cx.trace with
              (* the recorder's own call of what it's over isn't one the
                 program made *)
              | Some t when not (next && e.loc.file = Prelude.file) ->
                  ok (traced cx t ~dep:dep.name ~op fty args call)
              | _ -> ok (call ()))
          | None -> bug (what ^ " on an implementation without it"))
      | Some _ -> bug (what ^ " on an implementation that isn't a record")
      | None -> bug (what ^ " where nothing installs `" ^ dep.name ^ "`"))
  | With { ev; outer; dep; dargs; from; impl; desc; body } ->
      let what = "installing `" ^ dep.name ^ "`" in
      let impl = eval cx env impl in
      let outer = evidence_in env outer what in
      (* a handler's description, as a fresh instance's implementation
         of [from], installed as [dep]: they differ for an alias. A
         description of one dependency has one implementation, which is
         it whichever it was made for: `let q: Jobs = queue()` made a
         `Chan<Job>`'s a `Jobs`'s *)
      let impl, finally =
        match impl with
        | VHandler h -> (
            let impls, finally = instance cx h outer what in
            match (List.assoc_opt from impls, impls) with
            | Some impl, _ | None, [ (_, impl) ] -> (impl, finally)
            | None, _ ->
                bug (what ^ " from a handler that doesn't implement it"))
        | _ -> bug (what ^ " with something that isn't a handler")
      in
      let args = List.map (type_of env) dargs in
      let top = { dep; args; impl; outer } in
      let installed = VEvidence (top :: outer) in
      ending cx env e.loc finally desc outer [ top ] (fun () ->
          eval cx (Env.add ev.id (ref installed) env) body)
  | Narrowed (_, h) -> eval cx env h
  | Handler { ev; captures; body } ->
      (* like a lambda, it copies what it captures now *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (ref !(cell env v)) inner)
          Env.empty captures
      in
      VHandler { ev = ev.id; body; env }
  | Instance { impls; finally } ->
      let values = eval_all cx env (List.map snd impls) in
      VInstance
        {
          impls = List.combine (List.map fst impls) values;
          finally = Option.map (eval cx env) finally;
        }
  | With_handler { ev; outer; handler; deps; desc; body } -> (
      let what = "installing a handler" in
      let h = eval cx env handler in
      let outer = evidence_in env outer what in
      match h with
      | VHandler h ->
          (* of what the instance implements, only [deps]: it may have
             been narrowed to them (Core.Narrowed) *)
          let impls, finally = instance cx h outer what in
          if not (List.for_all (fun (_, p) -> List.mem_assoc p impls) deps) then
            bug (what ^ " whose instance doesn't implement its dependencies");
          (* in the order the instance has them, each at its key *)
          let installed =
            List.fold_left
              (fun acc (p, impl) ->
                match List.find_opt (fun (_, q) -> q = p) deps with
                | Some ((k : dkey), _) ->
                    {
                      dep = k.kpath;
                      args = List.map (type_of env) k.kargs;
                      impl;
                      outer;
                    }
                    :: acc
                | None -> acc)
              outer impls
          in
          let top = List.filter (fun i -> not (List.memq i outer)) installed in
          ending cx env e.loc finally desc outer top (fun () ->
              eval cx (Env.add ev.id (ref (VEvidence installed)) env) body)
      | _ -> bug (what ^ " with something that isn't a handler"))
  | Prim (((Equal d | Not_equal d) as op), [ a; b ]) ->
      let x = eval cx env a in
      let y = eval cx env b in
      let what = match op with Not_equal _ -> "!=" | _ -> "==" in
      let same =
        comparing e.loc what (fun () -> equal_by (dict cx env d) x y)
      in
      VBool (match op with Not_equal _ -> not same | _ -> same)
  | Prim (Compare (op, d), [ a; b ]) -> (
      let x = eval cx env a in
      let y = eval cx env b in
      match dict cx env d with
      | Ord compare ->
          let c =
            comparing e.loc (Ast.binop_to_string op) (fun () -> compare x y)
          in
          VBool
            (match op with
            | Lt -> c < 0
            | Le -> c <= 0
            | Gt -> c > 0
            | Ge -> c >= 0
            | _ -> bug "a comparison that isn't one")
      | _ -> bug "a comparison through a dictionary that isn't `ord`'s")
  | Prim (Op (_, d), args) -> (
      let vs = eval_all cx env args in
      match dict cx env d with
      | Op f -> f e.loc (List.map (fun (a : expr) -> a.loc) args) vs
      | _ -> bug "an operator through a dictionary that isn't one")
  | Prim (Value_of (_, d), []) -> (
      match dict cx env d with
      | Const v -> v
      | _ -> bug "an associated value through a dictionary that isn't one")
  (* a sized type's value is the number it holds: read, it's itself *)
  | Prim (Widen, [ a ]) -> eval cx env a
  | Prim (((Narrow | Wrap) as op), [ a ]) -> (
      match Sized.of_ty e.ty with
      | Some k -> stored e.loc ~wrap:(op = Wrap) k (eval cx env a)
      | None -> bug "a value stored into a type that isn't sized")
  (* what a dependency's operation is given has no NaN in it (nan.ml) *)
  | Prim (Nan_check op, [ a ]) -> (
      let v = eval cx env a in
      match Walk.nan_in cx.types a.ty v with
      | () -> v
      | exception Nan.Seen x -> panic e.loc (Nan.observed (Nan.passed op) x))
  (* whether an error's tag is one a `fail on` arm was given *)
  | Prim (Tag_in names, [ a ]) -> (
      match eval cx env a with
      | VTag { name; _ } -> VBool (List.mem name names)
      | _ -> bug "a tag asked of what isn't an error")
  | Prim (op, args) -> prim e.loc op (eval_all cx env args) args
  | Let (v, value, body) ->
      let x = eval cx env value in
      eval cx (Env.add v.id (ref x) env) body
  | Assign (v, value) ->
      cell env v := eval cx env value;
      VUnit
  | If (c, t, f) ->
      if truth (eval cx env c) then eval cx env t else eval cx env f
  | While (c, body) ->
      (try
         while truth (eval cx env c) do
           ignore (eval cx env body)
         done
       with Broke -> ());
      VUnit
  | Break -> raise Broke
  | Seq (a, b) ->
      ignore (eval cx env a);
      eval cx env b
  | Call (f, args, ev) ->
      let f = eval cx env f in
      (* an `inout` argument is a local: read it now, and write the
         parameter's final value back once the call returns *)
      let values =
        eval_all cx env
          (List.map (function Value a -> a | Ref v -> local v e.loc) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      let result, finals = call_at cx e.loc f values (VEvidence ev) in
      (* written back whether the call failed or not: failing doesn't undo
         what it changed (errors.md, "Failure and `&`") *)
      List.iter2
        (fun a v -> match a with Ref x -> cell env x := v | Value _ -> ())
        args finals;
      ok result
  | Lambda { name; params; ev; outer; given; captures; body } ->
      (* share the captured variables' cells: a block captures by
         reference, so it reads a variable when it runs, and what it
         assigns is seen outside it. Exclusivity (excl.ml) makes sure
         nothing else uses a variable while a block changes it. The
         evidence where it's written is one of them *)
      let env =
        List.fold_left
          (fun inner (v : var) -> Env.add v.id (cell env v) inner)
          Env.empty captures
      in
      VClosure
        {
          site =
            (if body.loc.file = Prelude.file then ""
             else block_site cx name);
          params = List.map (fun (p : param) -> p.var.id) params;
          ev = ev.id;
          outer = outer.id;
          given =
            List.map
              (fun (k : dkey) -> (k.kpath, List.map (type_of env) k.kargs))
              given;
          body;
          env;
        }
  | Con (p, c, args) -> VCon { ty = p; name = c; args = eval_all cx env args }
  | Record (_, fields) ->
      let values = eval_all cx env (List.map snd fields) in
      let fields = List.combine (List.map fst fields) values in
      VRecord (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)
  | Field (r, _, f) -> (
      match eval cx env r with
      | VRecord fields -> List.assoc f fields
      | _ -> bug "a field of a non-record")
  | Update (r, f, v) -> (
      let r = eval cx env r in
      let v = eval cx env v in
      match r with
      | VRecord fields ->
          VRecord
            (List.map (fun (g, w) -> if g = f then (g, v) else (g, w)) fields)
      | _ -> bug "an update of a non-record")
  | Array xs -> array_of_list (eval_all cx env xs)
  | Tuple xs -> VTuple (eval_all cx env xs)
  | Match (subject, arms) ->
      let env, body = arm_for cx env e.loc (eval cx env subject) arms in
      eval cx env body
  | Tag (t, args, ds) ->
      VTag
        {
          name = t;
          args = eval_all cx env args;
          tys = List.map (type_of env) ds;
        }
  | Fail a -> (
      match eval cx env a with
      (* `fail Cancelled`, and `try r` of a cancelled body's `r`, in a
         `finally`: the task goes on being cancelled, which no `attempt`
         can catch (compiler.md, "Cancellation") *)
      | err when is_cancelled_tag err -> raise Sched.Cancelled
      | err -> raise (Failed err))
  | Handle { body; value; on_value; error; on_error } -> (
      (* [match ... with exception] runs one branch for a value and another
         for an exception that evaluating it raised *)
      match eval cx env body with
      | v -> eval cx (Env.add value.id (ref v) env) on_value
      | exception Failed err ->
          eval cx (Env.add error.id (ref err) env) on_error)
  | Assert a ->
      if not (truth (eval cx env a)) then
        if a.loc.file = Prelude.file then
          (* the prelude's, on what it was given, `n >= 0` in `take`: a
             panic, which [call_at] says is at the program's call, with the
             condition, since the prelude's source can't be shown *)
          panic a.loc (unmet cx env a)
        else raise (Assert_failed { loc = a.loc; sides = None });
      VUnit
  | Assert_equal (a, b, d, eq) ->
      let x = eval cx env a in
      let y = eval cx env b in
      if not (comparing e.loc "==" (fun () -> equal_by (dict cx env eq) x y))
      then
        raise
          (Assert_failed
             {
               loc = e.loc;
               sides =
                 Some
                   (Shown.sides ~own:(own_show cx)
                      ~equal:(Walk.equal (walk cx))
                      cx.types (type_of env d) x y);
             });
      VUnit
  | Finally (body, after) -> (
      let after () = ignore (Sched.shielded (fun () -> eval cx env after)) in
      match eval cx env body with
      | v ->
          after ();
          v
      | exception Failed err ->
          after ();
          raise (Failed err)
      | exception Broke ->
          (* a `break` leaves the loop, but writes back what was changed,
             a `for &`'s element *)
          after ();
          raise Broke
      | exception Sched.Cancelled ->
          after ();
          raise Sched.Cancelled)
  | Covered { body; result; after } -> (
      (* an arm's `finally`: [body] is what it covers, as `attempt`
         keeps it, which a cancel goes through *)
      match eval cx env body with
      | outcome ->
          Sched.shielded (fun () ->
              eval cx (Env.add result.id (ref outcome) env) after)
      | exception Sched.Cancelled ->
          let outcome =
            VCon { ty = Path.prelude "Result"; name = "Err"; args = [ cancelled_tag ] }
          in
          (* what it gives, or fails with, is thrown away: the task goes
             on being cancelled *)
          (try
             ignore
               (Sched.shielded (fun () ->
                    eval cx (Env.add result.id (ref outcome) env) after))
           with Failed _ | Sched.Cancelled -> ());
          raise Sched.Cancelled)

(* [e], the body of a function or a part of one in tail position: a
   [Call] there with no `inout` argument, which would have to be written
   back once it returns, is returned for [finish] to make, and anything
   else is evaluated. Each part is evaluated in the order [eval] evaluates
   it. *)
and tail cx env (e : expr) =
  match e.kind with
  | If (c, t, f) ->
      if truth (eval cx env c) then tail cx env t else tail cx env f
  | Let (v, value, body) ->
      let x = eval cx env value in
      tail cx (Env.add v.id (ref x) env) body
  | Seq (a, b) ->
      ignore (eval cx env a);
      tail cx env b
  | Match (subject, arms) ->
      let env, body = arm_for cx env e.loc (eval cx env subject) arms in
      tail cx env body
  | Call (f, args, ev)
    when List.for_all (function Value _ -> true | Ref _ -> false) args ->
      let f = eval cx env f in
      let args =
        eval_all cx env
          (List.filter_map (function Value a -> Some a | Ref _ -> None) args)
      in
      let ev = evidence_in env ev ("a call of " ^ describe f) in
      Tail { loc = e.loc; f; args; ev = VEvidence ev; site = cx.site; call = cx.call }
  | _ -> Done (eval cx env e)

(* Make the call [step] ends in, then the one that ends in, and so on,
   until one gives a value. A panic is said to be where the call that
   reached it is, as [call_at] says: [at] is the last of these calls made
   from the program's own code rather than the prelude's, which a panic
   inside the prelude is said to be at. *)
(* The first of a `match`'s [arms] whose pattern [v] matches and whose
   guard passes: the environment its body runs in, with what the pattern
   bound, and the body, for [eval] or [tail] to run. *)
and arm_for cx env loc v arms =
  let guard_passes env = function
    | None -> true
    | Some g -> truth (eval cx env g)
  in
  let rec first = function
    | [] -> panic loc "no arm of this `match` matched"
    | a :: rest -> (
        match match_pattern a.pat v env with
        | Some env when guard_passes env a.guard -> (env, a.body)
        | _ -> first rest)
  in
  first arms

and finish cx at step =
  match step with
  | Done v -> v
  | Tail t ->
      let at = if t.loc.file <> Prelude.file then Some t.loc else at in
      let next =
        try enter ~at:t.loc { cx with site = t.site; call = t.call } t.f t.args t.ev with
        | Builtins.Panic msg -> panic (Option.value at ~default:t.loc) msg
        | Panic { loc; _ } as p when loc.file = Prelude.file && at <> None ->
            raise (moved (Option.get at) p)
        | Journal.Differs differs ->
            raise
              (Went_differently
                 { loc = Option.value at ~default:t.loc; differs })
        | Journal.Recorded_panic { at = p; msg; instead } when at <> None ->
            raise (recorded_panic (Option.get at) ~at:p ~msg ~instead)
        | Went_differently { loc; differs }
          when loc.file = Prelude.file && at <> None ->
            raise (Went_differently { loc = Option.get at; differs })
      in
      finish cx at next

(* What a call returned, or else fail with its error. *)
and ok = function Ok v -> v | Error err -> raise (Failed err)

(* A fresh instance of the handler [h], made with [outer], what's
   installed where it's installed, which its operations then run with: its
   implementation of each of its dependencies. *)
and instance cx (h : handler) outer what =
  match eval cx (Env.add h.ev (ref (VEvidence outer)) h.env) h.body with
  | VInstance { impls; finally } -> (impls, finally)
  | _ -> bug (what ^ " whose description doesn't make an instance")

(* Run [body], the body of a `with` that installed [installed], an
   instance whose `finally` is [finally], if it has one: it's given the
   body's outcome, `Ok` of its value or `Err` of its error, and the
   descriptor of its type, [desc], and runs with [outer], what was
   installed where the instance was; what it gives is the `with`'s
   (handlers.md, "When a `with` ends"). A panic isn't an outcome: it ends
   the program. Cancellation is, as `Err(Cancelled)`: then what the
   `finally` gives is thrown away, and the cancellation goes on. When the
   body ends, and before the `finally` runs, the tasks spawned beside the
   `with` are cancelled and waited for (Sched.leave_with). *)
and ending cx env loc finally desc outer installed body =
  let frame = Sched.enter_with installed in
  let at = if loc.file = Prelude.file then at_call cx else Some (where loc) in
  let body () =
    match body () with
    | v ->
        Sched.leave_with ?at frame;
        v
    | exception ((Failed _ | Sched.Cancelled) as e) ->
        Sched.leave_with ?at frame;
        raise e
  in
  match finally with
  | None -> body ()
  | Some f -> (
      let result = Path.prelude "Result" in
      let given outcome () =
        ok
          (fst
             (call_at cx loc f
                [ VType (type_of env desc); outcome ]
                (VEvidence outer)))
      in
      match body () with
      | v -> Sched.shielded (given (VCon { ty = result; name = "Ok"; args = [ v ] }))
      | exception Failed err ->
          Sched.shielded (given (VCon { ty = result; name = "Err"; args = [ err ] }))
      | exception Sched.Cancelled ->
          (try
             ignore
               (Sched.shielded
                  (given
                     (VCon { ty = result; name = "Err"; args = [ cancelled_tag ] })))
           with Failed _ | Sched.Cancelled -> ());
          raise Sched.Cancelled)

(* Evaluate [es] left to right. (A `let` in [::]'s head fixes the order.) *)
and eval_all cx env = function
  | [] -> []
  | e :: rest ->
      let v = eval cx env e in
      v :: eval_all cx env rest

(* [apply], from a call at [loc]. *)
and call_at cx loc f args ev =
  try apply ~loc cx f args ev with
  | Builtins.Panic msg -> panic loc msg
  | Panic { loc = l; _ } as p
    when l.file = Prelude.file && loc.file <> Prelude.file ->
      (* the prelude's source can't be shown, so a panic inside it is the
         program's call that reached it *)
      raise (moved loc p)
  (* and so is a replay that went differently, which the journal says
     where the call was made *)
  | Journal.Differs differs -> raise (Went_differently { loc; differs })
  | Went_differently { loc = l; differs }
    when l.file = Prelude.file && loc.file <> Prelude.file ->
      raise (Went_differently { loc; differs })
  | Journal.Recorded_panic { at; msg; instead } when loc.file <> Prelude.file ->
      raise (recorded_panic loc ~at ~msg ~instead)

(* Call [f], passing it the evidence [ev]. Returns its result, or the
   error it failed with, and the final value of every parameter, so the
   caller can write back the ones passed `inout`. *)
and apply ?loc cx f args ev =
  match f with
  | VBuiltin _ -> builtin ?loc cx f args
  | _ ->
      (* the function's parameters are cells, whose final values are
         returned, to be written back to the arguments passed `inout`. The
         calls it ends in are made by [finish], here, once its body has
         returned; none passes anything `inout`, so these cells are still
         the ones to return *)
      let cells = List.map ref args in
      if !(cx.depth) >= max_depth then raise Too_deep;
      incr cx.depth;
      let result =
        match finish cx None (start ?loc cx f cells ev) with
        | v -> Ok v
        | exception Failed err -> Error err
        | exception e ->
            decr cx.depth;
            raise e
      in
      decr cx.depth;
      (result, List.map ( ! ) cells)

(* Begin a call of [f], a function of the program, whose parameters are
   [cells]: evaluate its body as far as the call it ends in, if it ends in
   one. A top-level function's hidden type parameters hold what its value
   was given for them where it was used. *)
and start ?loc cx f cells ev =
  let passed =
    match ev with
    | VEvidence installed -> installed
    | _ -> bug ("a call of " ^ describe f ^ " passing something not evidence")
  in
  let run cx params ev_id ev body env =
    if List.length params <> List.length cells then
      bug ("a call of " ^ describe f ^ " with the wrong number of arguments");
    let env =
      List.fold_left2 (fun env id c -> Env.add id c env) env params cells
    in
    let env = Env.add ev_id (ref ev) env in
    tail cx env body
  in
  match f with
  | VFn (p, tys, dicts) ->
      let f =
        match Hashtbl.find_opt cx.fns p with
        | Some f -> f
        | None -> bug ("a call of `" ^ Path.local p ^ "`, which doesn't exist")
      in
      if List.length tys <> List.length f.tys then
        bug
          ("a call of `" ^ Path.local p
         ^ "` with the wrong number of type descriptors");
      if List.length dicts <> List.length f.dicts then
        bug
          ("a call of `" ^ Path.local p
         ^ "` with the wrong number of dictionaries");
      let env =
        List.fold_left2
          (fun env (v : var) t -> Env.add v.id (ref (VType t)) env)
          Env.empty f.tys tys
      in
      let env =
        List.fold_left2
          (fun env (v : var) d -> Env.add v.id (ref d) env)
          env f.dicts dicts
      in
      let cx =
        if f.loc.file <> Prelude.file then { cx with site = fn_label cx f }
        else
          (* the prelude's function, `Async.scope`, called by the program:
             a wait in it is at this call *)
          match loc with
          | Some l when l.file <> Prelude.file -> { cx with call = Some l }
          | _ -> cx
      in
      run cx
        (List.map (fun (p : param) -> p.var.id) f.params)
        f.ev.id ev f.body env
  | VClosure { params; ev = ev_id; outer; given; body; env; site } ->
      (* a block runs with the evidence where it was written, with the
         caller's implementations of what it's given on top, as a
         [With_handler] puts its instance's on top of what's outside it:
         Koka's `evv-insert` (koka/lib/std/core/hnd.kk:176), by path *)
      let written =
        match Option.map ( ! ) (Env.find_opt outer env) with
        | Some (VEvidence installed) -> installed
        | _ -> bug (describe f ^ " without the evidence where it was written")
      in
      let installed =
        List.fold_left
          (fun acc ((dep : Path.t), args) ->
            match
              List.find_opt
                (fun (i : installed) -> i.dep = dep && i.args = args)
                passed
            with
            | Some i -> i :: acc
            | None ->
                bug
                  ("a call of " ^ describe f ^ " where nothing installs `"
                 ^ dep.name ^ "`"))
          written given
      in
      (* a handler's arm runs as `handler.op`, which its call set *)
      let cx = if site = "" then cx else { cx with site = site_in cx site } in
      run cx params ev_id (VEvidence installed) body env
  | _ -> bug "a call to something that isn't a function"

(* A call in tail position, which [finish] makes: a built-in's value, or
   its error, or the callee's body as far as the call it ends in. *)
and enter ~at cx f args ev =
  match f with
  | VBuiltin _ -> Done (ok (fst (builtin ~loc:at cx f args)))
  | _ -> start ~loc:at cx f (List.map ref args) ev

(* A call of a built-in function, which [apply] returns, from [loc], where
   a NaN it makes is said to be made. *)
and builtin ?loc cx f args =
  match f with
  | VBuiltin (Show, tys, _) -> (
      (* the one built-in that needs its argument's type, which is what its
         type variable stands for *)
      match (tys, args) with
      | [ t ], [ v ] -> (
          match Shown.shown ~own:(own_show cx) cx.types t v with
          | s -> (Ok (VStr s), args)
          | exception Nan.Seen x ->
              raise (Builtins.Panic (Nan.observed Nan.shown x)))
      | _ -> bug "a call of `show` with the wrong number of arguments")
  | VBuiltin
      ( (( Journal_kept | Journal_gave | Journal_answer | Journal_outputs
         | Journal_load ) as x),
        tys,
        _ ) ->
      (Ok (journal cx x tys args), args)
  | VBuiltin
      ( (( Scope_run | Task_spawn | Task_start | Task_replace | Task_join
         | Task_cancel ) as x),
        tys,
        dicts ) ->
      tasks ?loc cx x tys dicts args
  | VBuiltin (Clock_sleep, _, _) -> (
      (* the real `Clock.sleep`: the task waits, and the others run *)
      match args with
      | [ VInt ms ] ->
          Sched.sleep ?at:(at_call cx) ms;
          (Ok VUnit, args)
      | _ -> bug "a call of `clock_sleep` with the wrong values")
  | VBuiltin (x, tys, dicts) -> (
      let dicts =
        List.map (function VDict d -> d | _ -> bug "a dictionary") dicts
      in
      let made () = match loc with Some l -> Nan.tag_at l | None -> 0 in
      match Builtins.run x ~dicts ~tys ~made args with
      | v, finals -> (Ok v, finals)
      (* a `Map`'s or a `Set`'s key with a NaN in it, which hashing it
         found first (nan.ml) *)
      | exception Nan.Seen v -> raise (Builtins.Panic (Nan.observed Nan.hashed v))
      | exception Builtins.Fail err -> (Error err, args))
  | _ -> bug "a call of a built-in that isn't one"

(* ---- tasks (sched.ml) ----

   The scheduler's intrinsics, which `Async.scope` and the members of
   `Scope` and `Task` call (prelude.ml), from [loc], in the prelude. *)
and tasks ?loc cx (x : Intrinsic.t) tys dicts args =
  let loc =
    match loc with Some l -> l | None -> Loc.point ~file:Prelude.file 1 1
  in
  let at = at_call cx in
  let some v = VCon { ty = Path.prelude "Option"; name = "Some"; args = [ v ] }
  and none = VCon { ty = Path.prelude "Option"; name = "None"; args = [] } in
  (* [body], a block, started as a task of [sc]: copied, and run with a
     count of calls of its own. A spawned block can't fail (infer), so
     it never gives an error *)
  let spawn ?key sc body =
    let body = copied body in
    let evidence =
      match body with
      | VClosure { outer; env; _ } -> (
          match Option.map ( ! ) (Env.find_opt outer env) with
          | Some (VEvidence installed) -> installed
          | _ -> [])
      | _ -> []
    in
    Sched.spawn ?key ?at sc ~label:cx.site ~evidence (fun () ->
        ok (fst (call_at { cx with depth = ref 0 } loc body [] (VEvidence []))))
  in
  match (x, args) with
  | Scope_run, [ VInt max; body ] ->
      if max < 1L then
        panic ~help:"`max:` is at least 1" loc
          (sprintf "`Async.scope`'s `max` is %Ld, so it couldn't start a task"
             max);
      let sc = Sched.scope ~max:(Int64.to_int max) in
      (* the body runs in this task; what it ends in, a value or an
         error, waits for the scope's tasks to end, after cancelling them
         if it's an error (async.md, "A failure cancels the tasks beside
         it"); and so does a cancel, which goes on down to them *)
      let stop () =
        Sched.cancel_all ?at sc;
        raise Sched.Cancelled
      in
      let result =
        match fst (call_at cx loc body [ VSched (Sched.Scope sc) ] (VEvidence [])) with
        | r -> r
        | exception Sched.Cancelled -> stop ()
      in
      (match result with
      | Ok _ -> ( try Sched.wait_empty ?at sc with Sched.Cancelled -> stop ())
      | Error _ -> Sched.cancel_all ?at sc);
      (result, args)
  | Task_spawn, [ s; body ] ->
      ignore (spawn (scope_of s) body);
      (Ok VUnit, args)
  | Task_start, [ s; body ] ->
      (Ok (VSched (Sched.Handle (spawn (scope_of s) body))), args)
  | Task_replace, [ s; key; body ] ->
      let sc = scope_of s in
      let ty, equal =
        match (tys, dicts) with
        | [ ty ], [ VDict (Hash { equal; _ }) ] -> (ty, equal)
        | _ -> bug "a call of `task_replace` without its key's type and `hash`"
      in
      (match Sched.keyed sc ty key ~equal with
      | Some t ->
          Sched.cancel t;
          Sched.join ?at t
      | None -> ());
      ignore (spawn ~key:(ty, key) sc body);
      (Ok VUnit, args)
  | Task_join, [ t ] ->
      let t = task_of t in
      Sched.join ?at t;
      (Ok (match t.result with Some v -> some v | None -> none), args)
  | Task_cancel, [ t ] ->
      Sched.cancel (task_of t);
      (Ok VUnit, args)
  | _ -> bug ("`" ^ Intrinsic.name x ^ "` with the wrong values")

(* ---- the journal (journal.ml) ----

   The recorder's and the replayer's operations (prelude.ml, "the
   journal") call these, with the journal by its number, the call,
   `Fs.read`, its arguments, one value, and what it gave, each with its
   type, from the descriptors they're given, as `show` is. *)
and journal cx (x : Intrinsic.t) tys args =
  let find = function
    | VInt n -> Journal.find (Int64.to_int n)
    | _ -> bug "a journal that isn't a number"
  in
  let made name ta a =
    let dep, op = Journal.split_call name in
    Journal.made ~dep ~op ~args:(Journal.write_args cx.types ta a)
  in
  let option name args = VCon { ty = Path.prelude "Option"; name; args } in
  match (x, tys, args) with
  | Journal_kept, [ ta; _ ], [ j; VStr name; a ] -> (
      match Journal.kept (find j) (made name ta a) with
      (* given back as it was given: an array is copied, since one can
         be pushed onto *)
      | Some (VArray xs) -> option "Some" [ array (items xs) ]
      | Some v -> option "Some" [ v ]
      | None -> option "None" [])
  | Journal_gave, [ ta; tr ], [ j; VStr name; a; r ] ->
      let c = made name ta a in
      let c =
        {
          c with
          gave = Journal.write_gave cx.types tr r ~output:(gives_nothing cx c);
        }
      in
      Journal.gave (find j) c r ~line:(fun () ->
          match a with VStr s | VTuple [ VStr s ] -> s | v -> Value.show v);
      r
  | Journal_answer, [ ta; tr ], [ j; VStr name; a ] ->
      let j = find j in
      let c = made name ta a in
      Journal.answer j c ~output:(gives_nothing cx c) ~read:(answered cx j tr)
        ~print:(fun (e : Journal.call) ->
          match (e.dep, e.op, a) with
          | "Console", "write", VStr line -> print_endline line
          | "Console", _, VStr line ->
              flush stdout;
              prerr_endline line
          | _ -> ())
        ~nothing:(Journal.nothing tr)
  | Journal_outputs, [], [ j ] ->
      Journal.outputs (find j);
      VUnit
  | Journal_load, [], [ VStr file ] -> load_journal cx file
  | _ -> bug ("`" ^ Intrinsic.name x ^ "` with the wrong values")

(* What the recording's call [e] gave, read as a [tr]. One that can't be
   is said at its line of the journal's file. *)
and answered cx (j : Journal.t) (tr : Ty.ty) (e : Journal.call) =
  let unreadable msg =
    raise
      (Diag.Error
         (Diag.make
            (Loc.point ~file:j.file e.line 1)
            msg
            ~help:"record the run again, or write the value as it's recorded"))
  in
  let shown =
    Ty.show
      (Ty.printer
         ~names:(fun (p : Path.t) -> p.name)
         { ty = tr; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] })
      tr
  in
  match e.gave with
  | None when gives_nothing cx e -> Journal.nothing tr
  | None ->
      unreadable
        (sprintf "this entry gives nothing back, but the call gives %s"
           (Diag.article shown))
  | Some text -> (
      try Journal.read_all cx.types tr text with
      | Journal.Unreadable ->
          unreadable
            (sprintf "this entry can't be read as %s" (Diag.article shown))
      | Journal.Redacted ->
          unreadable
            "what this call gave was left out when it was recorded, so it \
             can't be given back")

(* `replay(file)` in a test: the journal in [file], from the folder of
   the file the test is in, standing in for the world. *)
and load_journal cx file =
  let path =
    if Filename.is_relative file && cx.dir <> Filename.current_dir_name then
      Filename.concat cx.dir file
    else file
  in
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ ->
      raise (Builtins.Panic (sprintf "there's no journal at %s" path))
  | text ->
      let j = Journal.load ~file:path text in
      let j = Journal.for_test j ~gives_nothing:(gives_nothing cx) in
      VInt (Int64.of_int (Journal.register j))

(* Whether the call [c]'s operation gives nothing, `()`, by its
   dependency's declaration, which [load] looked at once: an output. *)
and gives_nothing cx (c : Journal.call) = Hashtbl.mem cx.outputs (c.dep, c.op)

(* A call of [dep]'s operation [op], of type [fty], with [args], made by
   [call] and added to the trace [t] (trace.ml): its arguments and what
   it gave as the journal writes them, but `Bytes` as how many, each cut
   short. *)
and traced cx t ~dep ~op (fty : Ty.ty) args call =
  let ps, ret, errs =
    match fty with
    | Fun (ps, r, e, _) -> (List.map (fun (p : Ty.param) -> p.ty) ps, r, e)
    | _ -> bug "an operation whose type isn't a function's"
  in
  let write (t : Ty.ty) v =
    match (t, v) with
    | Con (p, []), VBytes b when p = Path.prelude "Bytes" ->
        sprintf "%d bytes" (String.length b)
    | _ -> Trace.short (Journal.write cx.types t v)
  in
  let task = Sched.current_path () in
  let node =
    Trace.enter t ~task
      (sprintf "%s.%s(%s)" dep op
         (String.concat ", "
            (if List.length ps = List.length args then List.map2 write ps args
             else List.map Value.show args)))
  in
  match call () with
  | Ok VUnit as r ->
      Trace.leave t ~task node ~gave:"";
      r
  | Ok v as r ->
      Trace.leave t ~task node ~gave:(write ret v);
      r
  | Error e as r ->
      Trace.leave t ~task node ~gave:("fails " ^ write (Errors errs) e);
      r
  | exception ex ->
      Trace.leave t ~task node ~gave:"";
      raise ex

(* How the type [p], given [args], shows [v] (Shown.own): through the
   `show` method of its own that lowering found for it (Core.program), if
   it has one, unless that's where this is. The method's type variables
   are the type's parameters, in order, so it's given [args] for them. *)
and own_show cx (p : Path.t) args v : Shown.own =
  match Hashtbl.find_opt cx.shows p with
  | Some _ when List.mem p cx.showing -> Inside
  | Some m when Hashtbl.mem cx.fns m -> (
      let cx = { cx with showing = p :: cx.showing } in
      let dicts = known_dicts cx (Hashtbl.find cx.fns m) args in
      match apply cx (VFn (m, args, dicts)) [ v ] (VEvidence []) with
      | Ok (VStr s), _ -> Itself s
      | _ -> Declared)
  | _ -> Declared

(* ---- dictionaries ----

   A requirement's dictionary for a type the running program knows
   (core.ml, [dict]): `eq`, `hash` and ordering by the walk over the type
   (walk.ml), through its key, if it has one; and an operator or an
   associated value by [Int]'s and [Float]'s own, or by the member of the
   type that gives it (Core.program's [ops]), or, for an opaque type that
   has none, what it's represented as has, which the value is: a `with
   numeric` type's. *)

(* The walk's view of the program: its types, and how to find a value's
   key. *)
and walk cx : Walk.cx = { types = cx.types; key = key_of cx }

(* [v]'s key, and its type, if [v]'s type, [p] given [args], has one: its
   `key` method's result, given [args] for its type variables, which are
   the type's parameters, in order, as [own_show]'s are. *)
and key_of cx (p : Path.t) args v =
  match Hashtbl.find_opt cx.keys p with
  | Some m when Hashtbl.mem cx.fns m -> (
      let f = Hashtbl.find cx.fns m in
      let k =
        match f.scheme.ty with
        | Fun (_, r, _, _) -> Walk.subst args r
        | _ -> bug "a key that isn't a function"
      in
      match
        apply cx (VFn (m, args, known_dicts cx f args)) [ v ] (VEvidence [])
      with
      | Ok key, _ -> Some (k, key)
      | Error _, _ -> bug "a key that failed")
  | _ -> None

(* [req]'s dictionary for [t]. *)
and known cx req (t : Ty.ty) : Value.dict =
  match req with
  | "eq" -> Eq (Walk.equal (walk cx) t)
  | "hash" ->
      Hash { hash = Walk.hash (walk cx) t; equal = Walk.equal (walk cx) t }
  | "ord" -> Ord (Walk.compare (walk cx) t)
  | "zero" | "one" -> Const (constant cx req t)
  | _ -> Op (operator cx req t)

(* The associated value [req], `zero` or `one`, of [t]. *)
and constant cx req (t : Ty.ty) =
  let one = req = "one" in
  match t with
  | Con (p, []) when p = Path.prelude "Int" -> VInt (if one then 1L else 0L)
  | Con (p, []) when p = Path.prelude "Float" -> VFloat (if one then 1. else 0.)
  | Con (p, args) -> (
      match (Hashtbl.find_opt cx.ops (p, req), Hashtbl.find_opt cx.types p) with
      | Some m, _ -> (
          match Hashtbl.find_opt cx.values m with
          | Some v -> v
          | None ->
              bug ("the value `" ^ Path.local m ^ "` used before it's made"))
      | None, Some { body = Opaque (Rep rep); _ } ->
          constant cx req (Walk.subst args rep)
      | _ -> bug ("`" ^ req ^ "` of a type that hasn't it"))
  | _ -> bug ("`" ^ req ^ "` of a type that hasn't it")

(* The operator [req], `add`, of [t]: given where it's used and where its
   operands are, for a panic, and their values. *)
and operator cx req (t : Ty.ty) =
  match t with
  | Con (p, []) when p = Path.prelude "Int" || p = Path.prelude "Float" ->
      number_op req
  | Con (p, args) -> (
      match (Hashtbl.find_opt cx.ops (p, req), Hashtbl.find_opt cx.types p) with
      | Some m, _ ->
          fun loc _ vs ->
            let f = Hashtbl.find cx.fns m in
            ok
              (fst
                 (call_at cx loc
                    (VFn (m, args, known_dicts cx f args))
                    vs (VEvidence [])))
      | None, Some { body = Opaque (Rep rep); _ } ->
          operator cx req (Walk.subst args rep)
      | _ -> fun _ _ _ -> bug ("`" ^ req ^ "` of a type that hasn't it"))
  | _ -> fun _ _ _ -> bug ("`" ^ req ^ "` of a type that hasn't it")

(* What a function of [f]'s scheme is given for its requirements, for the
   types [tys] its type variables stand for: each one's dictionary, as
   [known]. *)
and known_dicts cx (f : fn_def) tys =
  List.map (fun (n, req) -> VDict (known cx req (List.nth tys n))) f.scheme.reqs

(* The dictionary [d] stands for (core.ml, [dict]): what a hidden
   dictionary parameter holds, or one derived for the type its descriptor
   describes, with what the hidden type parameters it's built from
   hold. *)
and dict cx env (d : Core.dict) : Value.dict =
  match d with
  | Dict_param v -> dict_in env v
  | Derived { req; ddesc; _ } -> known cx req (type_of env ddesc)

(* An error nothing handled, which the top-level function [p] failed
   with, shown through the types its errors' payloads have there. *)
let error_of cx p err =
  match
    Option.map (fun (f : fn_def) -> f.scheme.ty) (Hashtbl.find_opt cx.fns p)
  with
  | Some (Fun (_, _, errs, _)) ->
      Shown.value ~own:(own_show cx) cx.types (Errors errs) err
  | _ -> Value.show err

(* The same, unhandled, as [Uncaught] says it: shown, and as a journal
   writes it. *)
let uncaught cx p err =
  let written =
    match
      Option.map (fun (f : fn_def) -> f.scheme.ty) (Hashtbl.find_opt cx.fns p)
    with
    | Some (Fun (_, _, errs, _)) -> Journal.write cx.types (Errors errs) err
    | _ -> Value.show err
  in
  Uncaught { shown = error_of cx p err; written }

(* The top-level function [p], as the runtime calls it, from outside the
   program: nothing there knows what its type variables stand for, so its
   value is given each as a type variable nothing decided, and a value of
   that type is shown by its shape alone (shown.ml). *)
let from_outside cx (p : Path.t) =
  match Hashtbl.find_opt cx.fns p with
  | Some f ->
      let tys = List.mapi (fun n _ -> Ty.Var n) f.tys in
      VFn (p, tys, known_dicts cx f tys)
  | None -> bug ("a call of `" ^ Path.local p ^ "`, which doesn't exist")

(* The panic, to raise, for a program that called too deeply, past
   [max_depth] or past OCaml's own stack, from the function [p] it
   started: it has a bug, so it's a panic, not an error. *)
let overflowed cx (p : Path.t) =
  match Hashtbl.find_opt cx.fns p with
  | Some f ->
      panic_at f.loc "the stack overflowed: a function called itself too deeply"
  | None ->
      bug ("a call too deep from `" ^ Path.local p ^ "`, which isn't there")

(* A program's functions, by path, and its associated values, made in
   order: a module's after those of every module it imports, which come
   before it, and within a module in the order lowering gives, each after
   every value it uses, with nothing installed: a value can't use a
   dependency (infer_top.ml). If making one fails, nothing handles the
   error: [Uncaught]. *)
let load (modules : program list) =
  let cx =
    {
      fns = Hashtbl.create 16;
      values = Hashtbl.create 16;
      types =
        Shown.types (List.concat_map (fun (m : program) -> m.types) modules);
      shows = Hashtbl.create 16;
      keys = Hashtbl.create 16;
      ops = Hashtbl.create 16;
      showing = [];
      depth = ref 0;
      dir = Filename.current_dir_name;
      trace = None;
      outputs = Hashtbl.create 16;
      site = "main";
      entry = None;
      call = None;
    }
  in
  (* which operations are outputs is decided once, by their types *)
  List.iter
    (fun dep ->
      match Hashtbl.find_opt cx.types (Path.prelude dep) with
      | Some { body = Dep ops; _ } ->
          List.iter
            (fun (o : Iface.field) ->
              match o.fty with
              | Fun (_, r, _, _) when r = Ty.unit ->
                  Hashtbl.replace cx.outputs (dep, o.fname) ()
              | _ -> ())
            ops
      | _ -> ())
    Prelude.runtime_deps;
  List.iter
    (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns;
      List.iter (fun (p, m) -> Hashtbl.replace cx.shows p m) m.shows;
      List.iter (fun (p, k) -> Hashtbl.replace cx.keys p k) m.keys;
      List.iter (fun (r, o) -> Hashtbl.replace cx.ops r o) m.ops)
    modules;
  List.iter
    (fun (m : program) ->
      List.iter
        (fun p ->
          match fst (apply cx (from_outside cx p) [] (VEvidence [])) with
          | Ok v -> Hashtbl.replace cx.values p v
          | Error err -> raise (uncaught cx p err)
          (* caught here, not by whoever called [load], so that `ren test`,
             which loads outside any test, reports it as `ren run` does *)
          | exception (Stack_overflow | Too_deep) -> raise (overflowed cx p))
        m.values)
    modules;
  cx

(* What's installed for a run: the evidence, built by the runtime, as
   `$start` builds it in Core. A value made already, by its path. *)
let made_value cx what p =
  match Hashtbl.find_opt cx.values p with
  | Some v -> v
  | None -> bug (what ^ " with `" ^ Path.local p ^ "` not made")

(* The instance of the prelude's handler [name], given [args], made with
   [outer], what's installed where it's installed: its implementation of
   each of its dependencies. *)
let prelude_instance cx name args outer what =
  match apply cx (from_outside cx (Path.prelude name)) args (VEvidence []) with
  | Ok (VHandler h), _ -> fst (instance cx h outer what)
  | _ -> bug (what ^ " with `" ^ name ^ "`, which isn't a handler")

(* The recorder of the built-in dependency [dep] (prelude.ml, "the
   journal") with the journal [h], over [under], installed for it: a
   test implementation, or the real one. *)
let recorded cx h (under : installed) what =
  let name =
    Path.local (Lower.made_path (Any_for (Path.prelude "recorder", under.dep)))
  in
  let impls =
    prelude_instance cx name [ VInt (Int64.of_int h) ] [ under ] what
  in
  match List.assoc_opt under.dep impls with
  | Some impl -> { dep = under.dep; args = under.args; impl; outer = [ under ] }
  | None -> bug (what ^ " with a recorder that doesn't implement its dependency")

(* The real implementation of each built-in dependency in [deps], as
   `$start` installs them: an instance of the handler its `real`
   describes (`real_fs` for `Fs.real`), made with nothing installed. *)
let reals cx deps what =
  List.map
    (fun (dep : Path.t) ->
      match made_value cx what (Path.member dep "real") with
      | VHandler h -> (
          match List.assoc_opt dep (fst (instance cx h [] what)) with
          | Some impl -> { dep; args = []; impl; outer = [] }
          | None -> bug (what ^ " with a `real` that doesn't implement it"))
      | _ -> bug (what ^ " with a `real` that isn't a handler"))
    deps

(* [f ()], a call of `main` or of a test, as the root task of a
   scheduler of its own (sched.ml), labelled [root]: what the call gave,
   once it and every task it started have ended. *)
let rooted ~root f =
  let result = ref None in
  let deadlock waits =
    (* raised in the root, where it waits, which says it's at the
       program's call that waits *)
    Panic
      {
        loc = Loc.point ~file:Prelude.file 1 1;
        msg = "every task is waiting, and nothing can wake one";
        wrap = None;
        notes = waits;
        help = None;
      }
  in
  ignore
    (Sched.run ~root ~deadlock (fun () ->
         result := Some (fst (f ()));
         VUnit));
  match !result with Some r -> r | None -> bug "a root task that gave nothing"

(* What `main` ending by being cancelled is: only a `finally` that goes on
   with a cancel nothing asked for does that, until stage 11a's signals. *)
let cancelled_main = Uncaught { shown = "`main` was cancelled"; written = "Cancelled" }

(* How `ren run` starts the program (handlers.md, "The journal"): as
   `$start` does, on the real implementations ([Real]); recording, with
   the journal's recorder over each of them ([Record]); or replaying it,
   with the replayer in place of them all ([Replay]). *)
type start = Real | Record of Journal.t | Replay of Journal.t

(* Run a program made of [modules] (the prelude, then the user's files).
   It starts from the last one's `$start`, which installs what `main`
   uses and calls it (lower.ml), unless it's recording or replaying: then
   the runtime installs what it uses itself, a recorder over each real
   implementation, or the replayer in place of them, as it installs a
   test's implementations (see [run_installed]), and calls `main`. What
   it uses is the journal's header's, which the driver wrote, or checked
   was what `main` uses (Lower.main_uses). With
   [trace], each call of an operation is added to it. If `main`, or
   making a value, fails, nothing handles the error: [Uncaught]. *)
let run ?(start = Real) ?trace (modules : program list) =
  let entry = List.nth modules (List.length modules - 1) in
  let cx = { (load modules) with trace } in
  let what = "starting the program" in
  (* recording or replaying, the runtime itself, `Async`, is the real one,
     outermost: the journal holds only the world's calls *)
  let runtime () = reals cx [ Path.prelude "Async" ] what in
  let fn, installed =
    match start with
    | Real -> (Path.make entry.home Lower.start_name, [])
    | Record j ->
        let h = Journal.register j in
        ( Path.make entry.home "main",
          runtime ()
          @ List.map
              (fun r -> recorded cx h r what)
              (reals cx (List.map Path.prelude j.header.deps) what) )
    | Replay j ->
        let h = Journal.register j in
        let deps = List.map Path.prelude j.header.deps in
        let impls =
          prelude_instance cx "replaying" [ VInt (Int64.of_int h) ] [] what
        in
        ( Path.make entry.home "main",
          runtime ()
          @ List.map
              (fun dep ->
                match List.assoc_opt dep impls with
                | Some impl -> { dep; args = []; impl; outer = [] }
                | None -> bug (what ^ " with a replayer that hasn't a dependency"))
              deps )
  in
  if not (Hashtbl.mem cx.fns fn) then bug "a program with no `main`";
  match rooted ~root:"main" (fun () -> apply cx (from_outside cx fn) [] (VEvidence installed)) with
  | Ok v -> v
  | Error err -> raise (uncaught cx fn err)
  | exception Sched.Cancelled -> raise cancelled_main
  | exception (Stack_overflow | Too_deep) -> raise (overflowed cx fn)

(* ---- tests ---- *)

(* How a test ended. *)
type outcome =
  | Passed
  | Failed of string  (** with this error, which nothing handled, shown *)
  | Panicked of exn
      (** a [Panic], an [Assert_failed], a replay that [Went_differently], or a
          journal's entry that can't be read ([Diag.Error]) *)

(* Run the function [fn], of no parameters, in a program [load] made, as
   a test is run: with the test implementation of each built-in
   dependency (deps.md, "Tests"), a fresh instance for this run, but the
   real one of those in [real]: `Random`'s seeded with [seed]. The runtime
   installs them as it does `main`'s, outermost, so they run with nothing
   installed. [dir] is the folder of the file [fn] is in, which
   `replay(file)` finds a journal from. With [journal], a console
   session's (journal.ml), a recorder is installed over each, which keeps
   what the session's calls gave. Returns what it gave, or how it ended
   if it didn't, and every line it wrote to the test `Console`, which is
   kept even if it panicked; with the real one, it went to stdout. A test
   runs this way, and so does a `ren console` session (driver.ml). *)
let run_installed ?(dir = Filename.current_dir_name) ?journal cx ~(fn : Path.t)
    ~real ~seed =
  let cx = { cx with dir; entry = Some fn; site = "test" } in
  let what = "installing a test's implementations" in
  let value = made_value cx what in
  let installed =
    List.concat_map
      (fun (dep, handler, args) ->
        let dep = Path.prelude dep in
        if List.mem dep.name real then reals cx [ dep ] what
        else
          List.map
            (fun (dep, impl) -> { dep; args = []; impl; outer = [] })
            (prelude_instance cx handler args [] what))
      [
        ( "Clock",
          "test_clock",
          [ value (Path.member (Path.prelude "Time") "epoch") ] );
        ("Random", "test_random", [ VInt (Int64.of_int seed) ]);
        ("Console", "test_console", []);
        ("Fs", "mem_fs", [ array [||] ]);
        ("Os", "test_os", [ array [||] ]);
        ("Proc", "test_proc", [ array [||] ]);
        (* one task, until stage 11a's step 5 makes this `sim`'s *)
        ("Async", "single_runtime", []);
      ]
  in
  (* a session's recorder over each built-in dependency, not over what
     controls a test one, `TestClock` *)
  let recorded =
    match journal with
    | None -> installed
    | Some j ->
        let h = Journal.register j in
        List.map
          (fun (i : installed) ->
            if List.mem i.dep.name Prelude.world_deps then
              recorded cx h i what
            else i)
          installed
  in
  let outcome =
    try
      match
        rooted ~root:"test" (fun () ->
            apply cx (from_outside cx fn) [] (VEvidence recorded))
      with
      | Ok v -> Ok v
      | Error err -> Error (Failed (error_of cx fn err))
    with
    | Sched.Cancelled -> Error (Failed "the test was cancelled")
    | (Panic _ | Assert_failed _ | Went_differently _) as e ->
        Error (Panicked e)
    (* a journal's entry `replay` can't read *)
    | Diag.Error _ as e -> Error (Panicked e)
    (* a test of a bug's recording went past where it ended *)
    | Journal.Went_past -> Ok VUnit
    | Stack_overflow | Too_deep -> Error (Panicked (overflowed cx fn))
  in
  (* what the test `Console` kept, asked of it as the test would *)
  let console =
    List.find_map
      (fun (i : installed) ->
        match i.impl with
        | VRecord ops when i.dep = Path.prelude "TestConsole" -> (
            match apply cx (List.assoc "output" ops) [] (VEvidence []) with
            | Ok (VArray lines), _ ->
                Some
                  (Array.to_list
                     (Array.map
                        (function VStr s -> s | v -> Value.show v)
                        (items lines)))
            | _ -> bug "a test `Console` whose output isn't an array")
        | _ -> None)
      installed
  in
  (outcome, Option.value console ~default:[])

(* Run the test whose function is [fn] (see [run_installed]): how it
   ended, and what it wrote to the test `Console`. *)
let run_test ?dir cx ~fn ~real ~seed =
  match run_installed ?dir cx ~fn ~real ~seed with
  | Ok _, console -> (Passed, console)
  | Error outcome, console -> (outcome, console)

(* [v], a value of type [t], as `ren console` shows it: as it's written,
   through its type (shown.ml), a string in quotes. *)
let show cx (t : Ty.ty) v = Shown.value ~own:(own_show cx) cx.types t v
