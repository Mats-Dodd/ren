(* The compiler pipeline, one stage after another. *)

let tokens ~file src = Lexer.tokenize ~file src
let parse ~file src = Parser.parse_program (tokens ~file src)
let run ~file src = Eval.run ~file (parse ~file src)

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "
