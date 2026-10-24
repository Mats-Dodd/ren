(* The `ren` command-line tool. *)

open Ren

let usage =
  {|usage: ren <command> <file.ren>

commands:
  run     run the program's `main` function
  check   check the program without running it
  types   print every function's inferred signature
  tokens  print the tokens the lexer produces
  ast     print the parsed syntax tree|}

let () =
  match Sys.argv with
  | [| _; cmd; path |] -> (
      let src =
        try In_channel.with_open_bin path In_channel.input_all
        with Sys_error msg ->
          prerr_endline ("error: " ^ msg);
          exit 1
      in
      try
        match cmd with
        | "run" -> (
            match Driver.run ~file:path src with
            | VUnit -> ()
            | v -> print_endline (Value.show v))
        | "check" -> ignore (Driver.check ~file:path src)
        | "types" -> List.iter print_endline (Driver.types ~file:path src)
        | "tokens" ->
            print_endline (Driver.dump_tokens (Driver.tokens ~file:path src))
        | "ast" ->
            List.iter
              (fun f -> print_endline (Ast.show_item f))
              (Driver.parse ~file:path src)
        | _ ->
            prerr_endline usage;
            exit 2
      with Diag.Error d ->
        prerr_string (Diag.render ~src d);
        exit 1)
  | _ ->
      prerr_endline usage;
      exit 2
