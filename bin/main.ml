(* The `ren` command-line tool. *)

open Ren

let usage =
  {|usage: ren <command> <file.ren>
       ren test [<folder or file.ren>] [--only <text>] [--seed <n>] [--list]

The file is the program's entry module. A module it imports is found from
the file's folder: `import billing/stripe` is the file billing/stripe.ren.

commands:
  run     run the program's `main` function
  test    run the tests of every module in the folder (the current one if
          none is given), or of the file and what it imports:
            --only <text>  only the tests whose name has <text> in it
            --seed <n>     start every test's `Random` from <n>
            --list         list the tests, without running them, saying
                           which use a real dependency
          REN_NO_TIMINGS set leaves out how long they took
  check   check the program and its tests without running them
  types   print every function's inferred signature, module by module,
          and each type's members under it
  core    print every module in Core, the language it's lowered to,
          with the evidence of what's installed passed explicitly
  tokens  print the tokens the lexer produces
  ast     print the parsed syntax tree|}

(* Read a file, or stop with its error. *)
let read path =
  try In_channel.with_open_bin path In_channel.input_all
  with Sys_error msg ->
    prerr_endline ("error: " ^ msg);
    exit 1

(* The source map: the text of any file a message points into, [known]'s,
   which were read already, and any other, read when it's needed. *)
let sources ~known file =
  match List.assoc_opt file known with
  | Some src -> Some src
  | None -> (
      try Some (In_channel.with_open_bin file In_channel.input_all)
      with Sys_error _ -> None)

(* Print the error a pass raised, and stop. *)
let fail ~known e =
  match Driver.render_error ~sources:(sources ~known) e with
  | Some msg ->
      prerr_string msg;
      exit 1
  | None -> raise e

(* Every `.ren` file under the folder [dir], in sorted order. *)
let rec ren_files dir =
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.concat_map (fun name ->
      let path =
        if dir = Filename.current_dir_name then name
        else Filename.concat dir name
      in
      if Sys.is_directory path then
        if String.starts_with ~prefix:"." name || name = "_build" then []
        else ren_files path
      else if Filename.check_suffix name ".ren" then [ path ]
      else [])

(* `ren test [path] [flags]` (deps.md, "`ren test`"). *)
let test args =
  let rec parse (opts : Test_runner.options) = function
    | [] -> opts
    | "--only" :: text :: rest -> parse { opts with only = Some text } rest
    | "--seed" :: n :: rest -> (
        match int_of_string_opt n with
        | Some n when n >= 0 -> parse { opts with seed = Some n } rest
        | _ ->
            prerr_endline ("error: a seed is a number from 0 up, not " ^ n);
            exit 2)
    | "--list" :: rest -> parse { opts with list = true } rest
    | flag :: _ when String.starts_with ~prefix:"-" flag ->
        prerr_endline ("error: `ren test` has no option " ^ flag);
        prerr_endline usage;
        exit 2
    | path :: rest when opts.path = "" -> parse { opts with path } rest
    | _ ->
        prerr_endline usage;
        exit 2
  in
  let opts =
    parse
      {
        path = "";
        dir = ".";
        only = None;
        seed = None;
        list = false;
        timings = Sys.getenv_opt "REN_NO_TIMINGS" = None;
      }
      args
  in
  let path = if opts.path = "" then "." else opts.path in
  let dir, files =
    if Sys.file_exists path && Sys.is_directory path then
      (* a folder is written with or without a `/` on the end *)
      let dir =
        if String.length path > 1 && String.ends_with ~suffix:"/" path then
          String.sub path 0 (String.length path - 1)
        else path
      in
      (dir, ren_files dir)
    else (Filename.dirname path, [ path ])
  in
  let opts = { opts with path; dir } in
  let roots = List.map (fun f -> (f, read f)) files in
  let load m =
    try
      Some
        (In_channel.with_open_bin (Driver.file_in ~dir m) In_channel.input_all)
    with Sys_error _ -> None
  in
  match Driver.suite ~load ~dir roots with
  | suite ->
      exit
        (try Test_runner.run ~opts ~sources:(sources ~known:roots) suite
         with e -> fail ~known:roots e)
  | exception e -> fail ~known:roots e

let () =
  match Sys.argv with
  | args when Array.length args >= 2 && args.(1) = "test" ->
      test (List.tl (List.tl (Array.to_list args)))
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
        | "core" ->
            (* every module but the prelude, which comes first *)
            List.iteri
              (fun i (m : Core.program) ->
                if i > 0 then print_newline ();
                print_endline ("-- " ^ m.home);
                List.iter (fun f -> print_endline (Core.show_fn f)) m.fns)
              (List.tl (Driver.linked ~load ~file:path src))
        | "tokens" ->
            print_endline (Driver.dump_tokens (Driver.tokens ~file:path src))
        | "ast" ->
            List.iter
              (fun f -> print_endline (Ast.show_item f))
              (Driver.parse ~file:path src)
        | _ ->
            prerr_endline usage;
            exit 2
      with e -> fail ~known:[ (path, src) ] e)
  | _ ->
      prerr_endline usage;
      exit 2
