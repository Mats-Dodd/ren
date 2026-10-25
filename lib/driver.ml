(* The compiler pipeline, one pass after another. *)

(* Something went wrong inside the compiler itself: an exception that isn't
   a diagnostic or a panic. [pass] names the pass that was running. *)
exception Internal_error of { pass : string; message : string }

(* Run one pass. Diagnostics and panics are about the program, so they pass
   through; anything else is a bug in the compiler, and is reported as one
   so it can't be mistaken for a problem with the program. *)
let pass name f =
  try f () with
  | (Diag.Error _ | Diag.Errors _ | Eval.Panic _ | Internal_error _) as e ->
      raise e
  | e -> raise (Internal_error { pass = name; message = Printexc.to_string e })

(* Run a pass that reports diagnostics to a sink. If it reported any, the
   program stops here: later passes would only trip over the same mistakes,
   and could rely on nothing this pass promises. *)
let checked name f =
  let sink = Diag.sink () in
  let result =
    try pass name (fun () -> f sink)
    with Diag.Error d ->
      Diag.report sink d;
      raise (Diag.Errors (Diag.reported sink))
  in
  if Diag.has_errors sink then raise (Diag.Errors (Diag.reported sink));
  result

let tokens ~file src = checked "lex" (fun _ -> Lexer.tokenize ~file src)

let parse ~file src =
  let toks = tokens ~file src in
  checked "parse" (fun sink -> Parser.parse_program sink toks)

(* Check one module against the interfaces it imports, before anything
   runs: first what its names refer to (found through scope), then what may
   change, then types (and what's found through them), then whether every
   `match` is exhaustive. Returns the module resolved, its interface and
   what inference found. [entry] is set for the module the program starts
   in, which needs a `main`. *)
let check_module ~home ~imports ?entry prog =
  let r =
    checked "resolve" (fun sink -> Resolve.program sink ~home ~imports prog)
  in
  checked "mut" (fun sink -> Mut.program sink r);
  let inferred =
    checked "infer" (fun sink -> Infer.program sink ~imports ?entry r)
  in
  checked "exhaust" (fun sink -> Exhaust.program sink ~imports r inferred);
  (* what a public function uses can't be written in its signature yet, so
     its interface takes that from inference *)
  let uses name =
    match (List.assoc name inferred.schemes).ty with
    | Fun (_, _, _, u) -> u.labels
    | _ -> []
  in
  let iface = Iface.of_module ~home ~uses r.prog in
  (* A public function's body was checked against its signature, so the
     type inference found for it is the one its interface states. Other
     modules see only the interface, so if the two ever differ, that's a
     bug in the compiler, and it's caught here rather than in whichever
     module trips over it. *)
  List.iter
    (fun (v : Iface.value) ->
      let found = List.assoc v.vname inferred.schemes in
      if found <> v.scheme then
        let show (s : Ty.scheme) =
          Ty.show (Ty.printer ~show_tail:(fun _ -> true) ~home s) s.ty
        in
        raise
          (Internal_error
             {
               pass = "interface";
               message =
                 Printf.sprintf
                   "the interface of `%s` says `%s`, but inference found `%s`"
                   v.vname (show v.scheme) (show found);
             }))
    iface.values;
  (r, iface, inferred)

(* A checked module, lowered to Core. With [lint], Core Lint checks the
   result; the tests turn it on for every program. *)
let lower ?(lint = false) ~imports r inferred =
  let core = pass "lower" (fun () -> Lower.program r inferred) in
  if lint then pass "lint" (fun () -> Core_lint.program ~imports core);
  core

(* The prelude, as a module: its source, parsed and checked against the
   intrinsics (prelude.ml) and lowered (and linted), and its whole
   interface. It's checked once, the first time it's needed: [lazy] delays
   a computation and [Lazy.force] runs it (at most once). It's the same for
   every program, so sharing it is safe. *)
let prelude =
  lazy
    (let prog = parse ~file:"<prelude>" (String.trim Prelude.source) in
     let imports = [ Prelude.intrinsics ] in
     let r, iface, inferred =
       check_module ~home:Path.prelude_home ~imports prog
     in
     (lower ~lint:true ~imports r inferred, Iface.union Prelude.intrinsics iface))

(* The user's program, checked against the prelude's interface. *)
type checked = {
  prog : Ast.Parsed.program;
  resolved : Resolve.t;
  iface : Iface.t;
  inferred : Infer.t;
  imports : Iface.t list;
}

let check_all ~file src =
  let _, prelude_iface = Lazy.force prelude in
  let prog = parse ~file src in
  let home = Path.home_of_file file in
  let imports = [ prelude_iface ] in
  let resolved, iface, inferred =
    check_module ~home ~imports ~entry:file prog
  in
  { prog; resolved; iface; inferred; imports }

let check ~file src = (check_all ~file src).prog
let inferred ~file src = (check_all ~file src).inferred
let schemes ~file src = (inferred ~file src).schemes
let interface ~file src = (check_all ~file src).iface

let core ?lint ~file src =
  let c = check_all ~file src in
  lower ?lint ~imports:c.imports c.resolved c.inferred

let types ?(lint = false) ~file src =
  let ({ prog; inferred; _ } as c) = check_all ~file src in
  (* the tests also check that the program lowers, and lints *)
  if lint then ignore (lower ~lint:true ~imports:c.imports c.resolved inferred);
  let schemes = inferred.schemes in
  List.filter_map
    (function
      | Ast.Fn f ->
          Some
            (Ty.signature ~home:(Path.home_of_file file) ~pub:f.pub
               ~name:f.name.name
               ~params:
                 (List.map
                    (fun (p : Ast.Parsed.param) -> p.pname.name)
                    f.params)
               (List.assoc f.name.name schemes))
      | Type _ -> None)
    prog

let run ?lint ~file src =
  let prog = core ?lint ~file src in
  let prelude, _ = Lazy.force prelude in
  pass "eval" (fun () -> Eval.run [ prelude; prog ])

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "

(* What to print for an exception a pass raised, or [None] if it isn't one
   the compiler knows about. *)
let render_error ~src = function
  | Diag.Error d -> Some (Diag.render ~src d)
  | Diag.Errors ds -> Some (Diag.render_all ~src ds)
  | Eval.Panic (loc, msg) ->
      Some (Diag.render ~src (Diag.make loc ("panic: " ^ msg)))
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None
