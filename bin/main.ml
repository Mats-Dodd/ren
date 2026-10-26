(* The `ren` command-line tool. *)

open Ren

(* What `ren --version` prints. *)
let version = "ren 0.1.0"

let usage =
  {|usage: ren <command> <file.ren>
       ren run <file.ren> [-- <args>...]
       ren core --types <file.ren>
       ren test [<folder or file.ren>] [--only <text> [--exact]] [--seed <n>]
                [--list]
       ren --help | --version

The file is the program's entry module. A module it imports is found from
the file's folder: `import billing/stripe` is the file billing/stripe.ren.

commands:
  run     run the program's `main` function, with the <args> after `--`
          as `Os.args()`
  test    run the tests of every module in the folder (the current one if
          none is given) and the folders in it, but those holding a
          program of their own, with a `main`; or of the file and what
          it imports:
            --only <text>  only the tests whose name has <text> in it
            --exact        <text> is a test's whole name, or a group
                           run's label
            --seed <n>     start every test's `Random` from <n>
            --list         list the tests, without running them, saying
                           which use a real dependency
          REN_NO_TIMINGS set leaves out how long they took
  check   check the program and its tests without running them
  types   print every function's inferred signature, module by module,
          and each type's members under it
  core    print every module in Core, the language it's lowered to,
          with the evidence of what's installed passed explicitly:
            --types  also each function's type, and the type arguments
                     each use of a generic function picks
  tokens  print the tokens the lexer produces
  ast     print the parsed syntax tree

options:
  -h, --help  print this, and stop
  --version   print which version of Ren this is|}

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

(* Whether the file [path] declares `main`: a program starts there. One
   that can't be read or parsed doesn't, here; it's reported if it's
   loaded. Only those two are caught: any other exception is a bug, and
   goes on. *)
let has_main path =
  match In_channel.with_open_bin path In_channel.input_all with
  | exception Sys_error _ -> false
  | src -> (
      try
        List.exists
          (function
            | Ast.Fn (f : Ast.Parsed.fn_def) -> f.name.name = "main"
            | _ -> false)
          (Driver.parse ~file:path src)
      with Diag.Error _ | Diag.Errors _ -> false)

(* Every `.ren` file under the folder [dir], in sorted order, and the
   folders below it left out because each holds a program of its own: one
   of the files right in it declares `main`. Its imports are found from
   its folder, not [dir], so it can't be a part of [dir]'s program. *)
let rec ren_files ?(top = true) dir =
  let names = Sys.readdir dir |> Array.to_list |> List.sort compare in
  let path name =
    if dir = Filename.current_dir_name then name else Filename.concat dir name
  in
  let here =
    List.filter_map
      (fun name ->
        let p = path name in
        if Filename.check_suffix name ".ren" && not (Sys.is_directory p) then
          Some p
        else None)
      names
  in
  if (not top) && List.exists has_main here then ([], [ dir ])
  else
    List.fold_left
      (fun (files, apart) name ->
        let p = path name in
        if
          Sys.is_directory p
          && not (String.starts_with ~prefix:"." name || name = "_build")
        then
          let f, a = ren_files ~top:false p in
          (files @ f, apart @ a)
        else (files, apart))
      (here, []) names

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
    | "--exact" :: rest -> parse { opts with exact = true } rest
    | [ "--only" ] ->
        prerr_endline
          "error: --only needs the text to look for in the tests' names, like \
           --only \"a deposit\"";
        exit 2
    | [ "--seed" ] ->
        prerr_endline "error: --seed needs a number, like --seed 42";
        exit 2
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
        exact = false;
        seed = None;
        list = false;
        timings = Sys.getenv_opt "REN_NO_TIMINGS" = None;
      }
      args
  in
  let path = if opts.path = "" then "." else opts.path in
  let dir, files =
    if Sys.file_exists path && Sys.is_directory path then (
      (* a folder is written with or without a `/` on the end *)
      let dir =
        if String.length path > 1 && String.ends_with ~suffix:"/" path then
          String.sub path 0 (String.length path - 1)
        else path
      in
      let files, apart = ren_files dir in
      List.iter
        (fun d ->
          prerr_endline
            (Printf.sprintf
               "note: %s holds a program of its own, so its tests aren't run \
                here: run them with `ren test %s`"
               d d))
        apart;
      (dir, files))
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
  (* `ren core --types <file.ren>`: the flag is taken out, and the rest
     read as any command's is *)
  let types, argv =
    match Sys.argv with
    | [| ren; "core"; "--types"; path |] -> (true, [| ren; "core"; path |])
    | argv -> (false, argv)
  in
  match argv with
  | [| _; ("--help" | "-h" | "help") |] ->
      (* asked for, so it's the output, not an error *)
      print_endline usage
  | [| _; "--version" |] -> print_endline version
  | args when Array.length args >= 2 && args.(1) = "test" ->
      test (List.tl (List.tl (Array.to_list args)))
  | args
    when Array.length args >= 3
         && (Array.length args = 3 || args.(3) = "--") -> (
      let cmd = args.(1) and path = args.(2) in
      (* what follows `--`, for `ren run` *)
      let os_args =
        if Array.length args > 3 then
          Array.to_list (Array.sub args 4 (Array.length args - 4))
        else []
      in
      if Array.length args > 3 && cmd <> "run" then (
        prerr_endline usage;
        exit 2);
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
            match Driver.run ~load ~args:os_args ~file:path src with
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
                List.iter (fun f -> print_endline (Core.show_fn ~types f)) m.fns)
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
