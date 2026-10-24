(* The compiler pipeline, one stage after another. *)

let tokens ~file src = Lexer.tokenize ~file src
let parse ~file src = Parser.parse_program (tokens ~file src)

(* Parsed once, the first time it's needed. [lazy] delays a computation and
   [Lazy.force] runs it (at most once). *)
let prelude = lazy (parse ~file:"<prelude>" (String.trim Prelude.source))

(* The user's program with the prelude in front, checked before anything
   runs. *)
let check ~file src =
  let prog = Lazy.force prelude @ parse ~file src in
  Check.program prog;
  prog

let run ~file src = Eval.run ~file (check ~file src)

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "
