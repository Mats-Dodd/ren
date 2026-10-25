(* The `ren` command-line tool. *)

open Ren

let usage =
  {|usage: ren <command> <file.ren>

The file is the program's entry module. A module it imports is found from
the file's folder: `import billing/stripe` is the file billing/stripe.ren.

commands:
  run     run the program's `main` function
  check   check the program without running it
  types   print every function's inferred signature, module by module,
          and each type's `ops` items under it
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
      (* each module the program imports, read from its file, which is
         next to the entry's or in a folder below it *)
      let load m =
        try
          Some
            (In_channel.with_open_bin
               (Driver.module_file ~entry:path m)
               In_channel.input_all)
        with Sys_error _ -> None
      in
      try
        match cmd with
        | "run" -> (
            match Driver.run ~load ~file:path src with
            | VUnit -> ()
            | v -> print_endline (Value.show v))
        | "check" -> ignore (Driver.check ~load ~file:path src)
        | "types" ->
            List.iteri
              (fun i (home, sigs) ->
                if i > 0 then print_newline ();
                print_endline ("-- " ^ home);
                List.iter print_endline sigs)
              (Driver.types ~load ~file:path src)
        | "tokens" ->
            print_endline (Driver.dump_tokens (Driver.tokens ~file:path src))
        | "ast" ->
            List.iter
              (fun f -> print_endline (Ast.show_item f))
              (Driver.parse ~file:path src)
        | _ ->
            prerr_endline usage;
            exit 2
      with e -> (
        (* the source map: the file that was read, and any other file a
           message points into, read when it's needed *)
        let sources file =
          if file = path then Some src
          else
            try Some (In_channel.with_open_bin file In_channel.input_all)
            with Sys_error _ -> None
        in
        match Driver.render_error ~sources e with
        | Some msg ->
            prerr_string msg;
            exit 1
        | None -> raise e))
  | _ ->
      prerr_endline usage;
      exit 2
