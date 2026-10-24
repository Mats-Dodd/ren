(* The compiler pipeline, one pass after another. *)

(* Something went wrong inside the compiler itself: an exception that isn't
   a diagnostic or a panic. [pass] names the pass that was running. *)
exception Internal_error of { pass : string; message : string }

(* Run one pass. Diagnostics and panics are about the program, so they pass
   through; anything else is a bug in the compiler, and is reported as one
   so it can't be mistaken for a problem with the program. *)
let pass name f =
  try f () with
  | (Diag.Error _ | Eval.Panic _ | Internal_error _) as e -> raise e
  | e -> raise (Internal_error { pass = name; message = Printexc.to_string e })

let tokens ~file src = pass "lex" (fun () -> Lexer.tokenize ~file src)

let parse ~file src =
  let toks = tokens ~file src in
  pass "parse" (fun () -> Parser.parse_program toks)

(* Parsed once, the first time it's needed. [lazy] delays a computation and
   [Lazy.force] runs it (at most once). *)
let prelude = lazy (parse ~file:"<prelude>" (String.trim Prelude.source))

(* The user's program with the prelude in front, checked and type-checked
   before anything runs. Returns the program and each function's inferred
   signature. *)
let check_with_types ~file src =
  let prog = Lazy.force prelude @ parse ~file src in
  pass "check" (fun () -> Check.program prog);
  pass "mut" (fun () -> Mut.program prog);
  let sigs = pass "infer" (fun () -> Infer.program ~file prog) in
  (prog, sigs)

let check ~file src = fst (check_with_types ~file src)
let types ~file src = snd (check_with_types ~file src)

let run ~file src =
  let prog = check ~file src in
  pass "eval" (fun () -> Eval.run prog)

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "

(* What to print for an exception a pass raised, or [None] if it isn't one
   the compiler knows about. *)
let render_error ~src = function
  | Diag.Error d -> Some (Diag.render ~src d)
  | Eval.Panic (loc, msg) ->
      Some (Diag.render ~src (Diag.make loc ("panic: " ^ msg)))
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None
