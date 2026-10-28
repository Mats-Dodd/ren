(* The `ren` command-line tool. *)

open Ren

(* What `ren --version` prints. *)
let version = "ren 0.1.0"

let usage =
  {|usage: ren <command> <file.ren>
       ren run [--record <file.journal>] [--trace] [--release] <file.ren>
               [-- <args>...]
       ren replay <file.journal> [--trace]
       ren build <file.ren> [-o <out>] [--debug | --release] [--emit-c]
                 [--emit-mem] [--stats] [--no-restrict]
                 [--rc naive | --rc perceus] [--explain-dispatch <D>]
       ren core [--types] [--release] <file.ren>
       ren test [<folder or file.ren>] [--only <text> [--exact]] [--seed <n>]
                [--list]
       ren test --keep <file.journal>
       ren console <module> [--real <dependency>,...]
       ren --help | --version

The file is the program's entry module. A module it imports is found from
the file's folder: `import billing/stripe` is the file billing/stripe.ren.

commands:
  run     run the program's `main` function, with the <args> after `--`
          as `Os.args()`:
            --record <file.journal>  write each call it makes to the world,
                                     and what it gave, to the journal
            --trace                  print the tree of calls it made to
                                     dependencies, once it ends, with how
                                     long each took (REN_NO_TIMINGS set
                                     leaves that out)
            --release                run the program `ren build --release`
                                     compiles, specialized, which does
                                     just what it does
  replay  run the program a journal recorded again, each call to the world
          answered from the journal, so nothing touches the disk and
          nothing runs; it stops at the first call that isn't the
          recording's. Its arguments are those the journal recorded:
            --trace  print the tree of calls it made, as `ren run --trace`
  build   compile the program to a native binary, through C, which prints
          what `main` gives as `ren run` does. Only the native slice's
          subset compiles yet (compiler.md, "Native slice"); anything
          else is an error that says to use `ren run`:
            -o <out>   the binary to write, the file's name without
                       `.ren` if not given
            --debug    the default: the C in units, a few modules each,
                       compiled in parallel by tcc, with lines that say
                       which line of Ren each comes from, so a debugger
                       steps through Ren
            --release  -O2, and the program specialized: a copy of each
                       generic function for each type it's used at,
                       each block given lifted into a function, and
                       each call of an operation whose handler is known
                       made directly
            --emit-c   print the C instead of building it, as one
                       file, without the lines of Ren
            --emit-mem print the Mem IR instead, its counting placed
            --stats    count allocations, frees and reference counting,
                       printed to stderr when the binary exits, and,
                       with --release, print what specializing made
            --no-restrict
                       with --release, don't promise C that an `inout`
                       parameter is the only way to what it points to
            --explain-dispatch <D>
                       with --release, list each place that calls an
                       operation of the dependency D on a description,
                       or installs one, and how it's compiled: a direct
                       call, arms inline, a call through a table, or a
                       loop copied for each handler, and why
            --rc perceus
                       place the counting precisely, borrowing what's
                       only read and changing what's unique in place,
                       the default
            --rc naive count a value at every use and drop it where its
                       scope ends, the baseline Perceus is measured
                       against
          A debug build runs $REN_CC if it's set, or tcc, found as
          $REN_TCC or on PATH (tools/tcc.sh installs it), or else cc
          -O0, with a note; $REN_JOBS units compile at once, one for
          each core if it's not set. A release build runs $REN_CC, or
          cc, -O2. Both add $REN_CFLAGS
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
            --keep <file.journal>
                           move a journal to the `tests` folder next to
                           its program, and add a test that replays it
          REN_NO_TIMINGS set leaves out how long they took
  console a line at a time inside <module>, its file's path without
          `.ren`, whose folder is the program's (`ren console
          bank/account`): each line is a `let`, a `var` or an expression, whose
          value is printed with its type, on the test implementations of
          the built-in dependencies:
            --real <dependency>,...  the real one of each of these instead;
                                     each real call is made once, and what
                                     it gave is kept for its line
            :t <expression>          its type, without running it
            :reload                  read the module again after an edit,
                                     and run the session on it
            :spec [name]             add the session to the module as a
                                     test, leaving out what a test can't do
            :q                       quit, as the end of the input does
  check   check the program and its tests without running them
  types   print every function's inferred signature, module by module,
          and each type's members under it
  core    print every module in Core, the language it's lowered to,
          with the evidence of what's installed passed explicitly:
            --types    also each function's type, and the type arguments
                       each use of a generic function picks
            --release  the program `ren build --release` compiles,
                       specialized
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

(* The source at [loc], on one line: what's written there, or its first
   line and `...` if it's longer. *)
let source_text ~known (loc : Loc.t) =
  match sources ~known loc.file with
  | None -> "?"
  | Some src -> (
      let lines = String.split_on_char '\n' src in
      match List.nth_opt lines (loc.start.line - 1) with
      | None -> "?"
      | Some l ->
          let from = max 0 (loc.start.col - 1) in
          let upto =
            if loc.stop.line = loc.start.line then min (String.length l) loc.stop.col
            else String.length l
          in
          let s =
            String.trim
              (if upto > from then String.sub l from (upto - from) else l)
          in
          (* a call's location may take in the `)` that closes what it's
             in, or the `.` of a method called on its result *)
          let count c = String.fold_left (fun n d -> if c = d then n + 1 else n) 0 in
          let rec balanced s =
            if
              String.ends_with ~suffix:")" s
              && count ')' s > count '(' s
            then balanced (String.sub s 0 (String.length s - 1))
            else if String.ends_with ~suffix:"." s then
              balanced (String.sub s 0 (String.length s - 1))
            else s
          in
          let s = balanced s in
          if loc.stop.line > loc.start.line then s ^ " ..." else s)

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

(* The modules the program whose entry is [path] imports, each read from
   its file, which is next to the entry's or in a folder below it. *)
let loader path m =
  try
    Some
      (In_channel.with_open_bin
         (Driver.module_file ~entry:path m)
         In_channel.input_all)
  with Sys_error _ -> None

(* [path] as a list of names, from the root, with `.` and `..` worked
   out: [path] from the current folder if it's relative. *)
let names path =
  let path =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  List.fold_left
    (fun acc name ->
      match name with
      | "" | "." -> acc
      | ".." -> ( match acc with _ :: rest -> rest | [] -> [])
      | n -> n :: acc)
    []
    (String.split_on_char '/' path)
  |> List.rev

(* The file [path] from the folder [dir]: what a journal's header says
   the program is, so it's found from wherever the journal is. *)
let relative ~dir path =
  let rec drop a b =
    match (a, b) with x :: a', y :: b' when x = y -> drop a' b' | _ -> (a, b)
  in
  let up, down = drop (names dir) (names path) in
  String.concat "/" (List.map (fun _ -> "..") up @ down)

(* [path] as a journal's header says it, from the journal's folder [dir]:
   relative, unless that climbs more than two folders up, the journal
   being far from the program, and then absolute. *)
let header_path ~dir path =
  let from = relative ~dir path in
  if String.starts_with ~prefix:"../../../" from then
    "/" ^ String.concat "/" (names path)
  else from

(* The file [path] in the folder [dir], as a person would write it:
   `tests/../main.ren` is `main.ren`; [path] itself if it's absolute. *)
let joined dir path =
  if not (Filename.is_relative path) then path
  else
    let up = Filename.parent_dir_name in
    let parts =
      List.fold_left
        (fun acc name ->
          match (name, acc) with
          | ("" | "."), _ -> acc
          | n, m :: rest when n = up && m <> up -> rest
          | n, _ -> n :: acc)
        []
        (String.split_on_char '/' (Filename.concat dir path))
      |> List.rev
    in
    let root = if Filename.is_relative dir then "" else "/" in
    match parts with [] -> "." | _ -> root ^ String.concat "/" parts

(* The trace [t], drawn on stderr, once the run has ended. *)
let print_trace = function
  | Some t ->
      prerr_string
        (Trace.render ~timings:(Sys.getenv_opt "REN_NO_TIMINGS" = None) t)
  | None -> ()

(* [n] calls, or one. *)
let calls n = if n = 1 then "1 call" else Printf.sprintf "%d calls" n

(* How many calls a journal holds, to each dependency it has calls to:
   `Fs 1, Os 1`. *)
let counts j =
  String.concat ", "
    (List.filter_map
       (fun (d, n) -> if n = 0 then None else Some (Printf.sprintf "%s %d" d n))
       (Journal.counts j))

(* The text of the journal [file], or a message that it isn't there. *)
let read_journal file =
  if not (Sys.file_exists file) then (
    prerr_endline (Printf.sprintf "error: there's no journal %s" file);
    prerr_endline
      "  help: record one with `ren run --record <file.journal> <file.ren>`";
    exit 1);
  read file

(* `ren test --keep <file.journal>` (handlers.md, "A journal as a test
   fixture"): the journal, moved to the `tests` folder next to the
   program it recorded, and a test that replays it, added to the
   program's file. *)
let keep file =
  let text = read_journal file in
  let journal =
    try Journal.load ~file text with e -> fail ~known:[ (file, text) ] e
  in
  let program = joined (Filename.dirname file) journal.header.program in
  let src =
    try In_channel.with_open_bin program In_channel.input_all
    with Sys_error _ ->
      prerr_endline
        (Printf.sprintf
           "error: the program %s recorded, %s, isn't there: a journal's \
            program is found from the journal's folder"
           file program);
      exit 1
  in
  let main =
    try
      List.find_map
        (function
          | Ast.Fn (f : Ast.Parsed.fn_def) when f.name.name = "main" -> Some f
          | _ -> None)
        (Driver.parse ~file:program src)
    with e -> fail ~known:[ (program, src) ] e
  in
  let main =
    match main with
    | Some f -> f
    | None ->
        prerr_endline
          (Printf.sprintf "error: %s has no `main` for a test to run" program);
        exit 1
  in
  if not main.pub then (
    prerr_endline
      (Printf.sprintf
         "error: `main` in %s is private, and a test sees what an importer sees\n\
         \  help: make it `pub fn main()`, so the test can call it"
         program);
    exit 1);
  let tests = joined (Filename.dirname program) "tests" in
  let name = Filename.basename file in
  let dest = Filename.concat tests name in
  if names dest = names file then (
    prerr_endline
      (Printf.sprintf
         "error: %s is in the `tests` folder already, where --keep moves a \
          journal\n\
         \  help: a test replays it with `with replay(\"tests/%s\") in`, then \
          a call of `main`"
         file name);
    exit 1);
  if Sys.file_exists dest then (
    prerr_endline
      (Printf.sprintf
         "error: %s is already there\n\
         \  help: give the journal another name, or remove the one there"
         dest);
    exit 1);
  if not (Sys.file_exists tests) then Sys.mkdir tests 0o755;
  (* the header says the program from the journal's new folder *)
  let header =
    Journal.header_text
      { journal.header with program = header_path ~dir:tests program }
  in
  let rest =
    match String.index_opt text '\n' with
    | Some i -> String.sub text i (String.length text - i)
    | None -> "\n"
  in
  let write path text =
    try Out_channel.with_open_bin path (fun oc -> output_string oc text)
    with Sys_error msg ->
      prerr_endline ("error: can't write " ^ msg);
      exit 1
  in
  write dest (header ^ rest);
  Sys.remove file;
  let label = "replays " ^ name in
  let call = if main.errors = None then "main()" else "try main()" in
  let test =
    Printf.sprintf "\ntest \"%s\" =\n  with replay(\"tests/%s\") in\n    %s\n"
      label name call
  in
  let src = if String.ends_with ~suffix:"\n" src then src else src ^ "\n" in
  write program (src ^ test);
  print_endline (Printf.sprintf "moved %s to %s" file dest);
  print_endline (Printf.sprintf "added the test \"%s\" to %s" label program);
  print_endline
    (Printf.sprintf "run it with `ren test %s --only \"%s\"`: %s" program label
       (if Journal.failing journal then
          "it fails while the program ends as the recording did, and passes \
           once it goes on past there, with the same outputs to there"
        else "it replays what the journal recorded, and fails with what changed"))

(* `ren test [path] [flags]` (deps.md, "`ren test`"). *)
let test args =
  (match args with
  | [ "--keep"; file ] ->
      keep file;
      exit 0
  | "--keep" :: _ ->
      prerr_endline
        "error: --keep needs the journal to keep, and nothing else, like \
         --keep bug.journal";
      exit 2
  | _ -> ());
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

(* `ren run [--record <file>] [--trace] [--release] <file.ren>
   [-- <args>...]` (handlers.md, "The journal"). *)
let run args =
  let release = ref false in
  (* the flags come before or after the file, but before `--` *)
  let rec parse (record, trace, path) = function
    | "--record" :: file :: rest
      when not
             (String.starts_with ~prefix:"-" file
             || Filename.check_suffix file ".ren") ->
        parse (Some file, trace, path) rest
    | "--record" :: _ ->
        prerr_endline
          "error: --record needs the file to write the journal to, like \
           --record run.journal";
        exit 2
    | "--trace" :: rest -> parse (record, true, path) rest
    | "--release" :: rest ->
        release := true;
        parse (record, trace, path) rest
    | ("--" :: _ | []) as rest -> (
        let os_args = match rest with _ :: a -> a | [] -> [] in
        match path with
        | Some path -> (record, trace, path, os_args)
        | None ->
            prerr_endline usage;
            exit 2)
    | flag :: _ when String.starts_with ~prefix:"-" flag ->
        prerr_endline ("error: `ren run` has no option " ^ flag);
        prerr_endline usage;
        exit 2
    | file :: rest when path = None -> parse (record, trace, Some file) rest
    | extra :: _ ->
        prerr_endline
          (Printf.sprintf
             "error: `ren run` runs one file, and %s is a second\n\
             \  help: the program's arguments go after `--`, like `ren run \
              main.ren -- %s`"
             extra extra);
        exit 2
  in
  let record, trace, path, os_args = parse (None, false, None) args in
  let src = read path in
  let known = [ (path, src) ] in
  let trace = if trace then Some (Trace.create ()) else None in
  let record =
    Option.map
      (fun file ->
        let dir = Filename.dirname file in
        if not (Sys.file_exists dir && Sys.is_directory dir) then (
          prerr_endline
            (Printf.sprintf
               "error: can't write the journal %s: there's no folder %s" file
               dir);
          exit 1);
        let out =
          try open_out_bin file
          with Sys_error msg ->
            prerr_endline ("error: can't write the journal: " ^ msg);
            exit 1
        in
        Journal.recording ~file ~out
          ~program:(header_path ~dir:(Filename.dirname file) path))
      record
  in
  let summary () =
    Option.iter
      (fun (j : Journal.t) ->
        prerr_endline
          (Printf.sprintf "recorded %s to %s%s" (calls j.made) j.file
             (match counts j with "" -> "" | c -> " (" ^ c ^ ")"));
        prerr_endline
          (Printf.sprintf
             "warning: %s holds everything the program read, files and \
              arguments included: read it before you share it"
             j.file))
      record
  in
  match
    Driver.run ~load:(loader path) ~release:!release ~args:os_args ?record
      ?trace ~file:path src
  with
  | v ->
      print_trace trace;
      summary ();
      if v <> VUnit then print_endline (Value.show v)
  | exception ((Diag.Error _ | Diag.Errors _) as e) ->
      (* it didn't run, so there's nothing to keep *)
      Option.iter
        (fun (j : Journal.t) -> try Sys.remove j.file with Sys_error _ -> ())
        record;
      fail ~known e
  | exception e ->
      print_trace trace;
      summary ();
      fail ~known e

(* `ren replay <file.journal> [--trace]` (handlers.md, "Recording and
   replaying"): the program it recorded, run again on what it recorded. *)
let replay args =
  let file, trace =
    match args with
    | [ file ] -> (file, None)
    | [ file; "--trace" ] | [ "--trace"; file ] -> (file, Some (Trace.create ()))
    | _ when List.mem "--" args ->
        prerr_endline
          "error: a replay runs on the arguments the journal recorded, so it \
           can't be given others\n\
          \  help: record the run again with the arguments you want: `ren run \
           --record <file.journal> <file.ren> -- <args>...`";
        exit 2
    | _ ->
        prerr_endline usage;
        exit 2
  in
  let text = read_journal file in
  let journal =
    try Journal.load ~file text with e -> fail ~known:[ (file, text) ] e
  in
  let path = joined (Filename.dirname file) journal.header.program in
  let src =
    try In_channel.with_open_bin path In_channel.input_all
    with Sys_error _ ->
      prerr_endline
        (Printf.sprintf
           "error: the program %s recorded, %s, isn't there: a journal's \
            program is found from the journal's folder"
           file path);
      exit 1
  in
  let known = [ (path, src); (file, text) ] in
  let replayed what =
    prerr_endline
      (Printf.sprintf "replayed %s%s: nothing touched the disk, and nothing ran"
         (calls journal.made) what)
  in
  match Driver.replay ~load:(loader path) ?trace ~journal ~file:path src with
  | v ->
      print_trace trace;
      replayed "";
      if v <> VUnit then print_endline (Value.show v)
  | exception ((Eval.Panic _ | Eval.Assert_failed _ | Eval.Uncaught _) as e)
    when journal.calls = [] && journal.ending <> None ->
      (* it ended as the recording did *)
      print_trace trace;
      replayed
        (match journal.ending with
        | Some (Panicked _, _) -> ", to the panic it ended in"
        | _ -> ", to the error it ended in");
      fail ~known e
  | exception e ->
      print_trace trace;
      fail ~known e

(* `ren build <file.ren> [-o <out>] [--debug | --release] [--emit-c]
   [--emit-mem] [--stats] [--rc naive | --rc perceus]` (compiler.md,
   "Native slice"): the program as C, compiled in a temporary folder
   (cc.ml): a debug build's in units, by tcc in parallel, a release
   build's as one file, by $REN_CC, or cc. `--emit-c` prints one file. *)
let build args =
  let rc = ref Driver.Perceus and restrict = ref true and explain = ref None in
  let rec parse ((out, release, emit, stats, path) as o) = function
    | "-o" :: file :: rest -> parse (Some file, release, emit, stats, path) rest
    | "--debug" :: rest -> parse (out, false, emit, stats, path) rest
    | "--release" :: rest -> parse (out, true, emit, stats, path) rest
    | "--emit-c" :: rest -> parse (out, release, `C, stats, path) rest
    | "--emit-mem" :: rest -> parse (out, release, `Mem, stats, path) rest
    | "--stats" :: rest -> parse (out, release, emit, true, path) rest
    | "--no-restrict" :: rest ->
        restrict := false;
        parse o rest
    | "--explain-dispatch" :: name :: rest when not (String.starts_with ~prefix:"-" name) ->
        explain := Some name;
        parse o rest
    | "--explain-dispatch" :: _ ->
        prerr_endline "error: `--explain-dispatch` takes a dependency's name";
        exit 2
    | "--rc" :: "naive" :: rest ->
        rc := Driver.Naive;
        parse o rest
    | "--rc" :: "perceus" :: rest ->
        rc := Driver.Perceus;
        parse o rest
    | "--rc" :: _ ->
        prerr_endline "error: `--rc` is `naive` or `perceus`";
        exit 2
    | flag :: _ when String.starts_with ~prefix:"-" flag ->
        prerr_endline ("error: `ren build` has no option " ^ flag);
        prerr_endline usage;
        exit 2
    | file :: rest when path = None ->
        parse (out, release, emit, stats, Some file) rest
    | _ :: _ ->
        prerr_endline "error: `ren build` builds one file";
        exit 2
    | [] -> o
  in
  let out, release, emit, stats, path =
    parse (None, false, `Binary, false, None) args
  in
  let path =
    match path with
    | Some p -> p
    | None ->
        prerr_endline usage;
        exit 2
  in
  if !explain <> None && not release then (
    prerr_endline
      "error: `--explain-dispatch` lists a release build's dispatch\n\
      \  help: add `--release`";
    exit 2);
  let src = read path in
  let known = [ (path, src) ] in
  (* what specializing made, which `--stats` prints, and the calls past
     its size budget, which a build always reports (foundations.md,
     decision 4): each is a dispatch the program didn't ask for *)
  let made (s : Specialize.stats) =
    if stats then
      prerr_endline
        (Printf.sprintf
           "ren specialized: %d copies, %d blocks lifted, %d handlers known, \
            %d calls past the size budget"
           s.copies s.blocks s.handlers s.past_budget);
    prerr_string (Driver.budget_notes s)
  in
  if emit = `Mem then
    let p =
      try Driver.mem ~load:(loader path) ~release ~made ~rc:!rc ~file:path src
      with e -> fail ~known e
    in
    List.iter (fun f -> print_endline (Mem.show_fn f)) p.fns
  else
    (* the listing of each dispatch site, printed before the build *)
    let explain =
      Option.map
        (fun name p ->
          print_string
            (Dispatch.explain p ~text:(source_text ~known) name);
          flush stdout)
        !explain
    in
    let native () =
      Driver.native ~load:(loader path) ~release ~made ~restrict:!restrict
        ~rc:!rc ?explain ~sources:(sources ~known) ~file:path src
    in
    if emit = `C then print_string (try native () with e -> fail ~known e)
    else
      let out =
        match out with
        | Some o -> o
        | None -> Filename.remove_extension (Filename.basename path)
      in
      let dir = Filename.temp_dir "ren-build" "" in
      let built =
        if release then
          let c = try native () with e -> fail ~known e in
          fun () -> Cc.release ~stats ~dir ~out c
        else
          let c = Cc.debug_compiler () and jobs = Cc.jobs () in
          let units =
            try
              Driver.native_units ~load:(loader path) ~rc:!rc ~jobs
                ~sources:(sources ~known) ~file:path src
            with e -> fail ~known e
          in
          Option.iter prerr_endline c.note;
          fun () -> Cc.debug ~c ~jobs ~stats ~dir ~out units
      in
      match built () with
      | () -> ( try Sys.rmdir dir with Sys_error _ -> ())
      | exception Cc.Missing (cc, why) ->
          prerr_endline
            (Printf.sprintf "error: can't run the C compiler `%s`: %s" cc why);
          (try Sys.rmdir dir with Sys_error _ -> ());
          exit 1
      | exception Cc.Failed _ ->
          prerr_endline
            (Printf.sprintf
               "error: the C compiler failed on the C `ren build` wrote, which \
                is a bug in the Ren compiler; the C is in %s"
               dir);
          exit 1

(* `ren console <module> [--real Clock,Fs]` (testing.md, "The console"). *)
let console args =
  let home, real =
    match args with
    | [ home ] -> (home, [])
    | [ home; "--real"; names ] -> (home, String.split_on_char ',' names)
    | _ ->
        prerr_endline usage;
        exit 2
  in
  (match Console.unknown_real real with
  | Some msg ->
      prerr_endline msg;
      exit 2
  | None -> ());
  let path =
    if Filename.check_suffix home ".ren" then Filename.chop_suffix home ".ren"
    else home
  in
  (* the module's folder is the program's, as `ren check dir/main.ren`'s is *)
  let dir = Filename.dirname path and home = Filename.basename path in
  let file = Driver.file_in ~dir home in
  let src =
    try In_channel.with_open_bin file In_channel.input_all
    with Sys_error _ ->
      prerr_endline
        (Printf.sprintf
           "error: there's no module `%s` here: it would be the file `%s`" home
           file);
      exit 1
  in
  let load m =
    try
      Some
        (In_channel.with_open_bin (Driver.file_in ~dir m) In_channel.input_all)
    with Sys_error _ -> None
  in
  let s : Console.session =
    {
      load;
      dir;
      home;
      file;
      src;
      real;
      journal = Journal.session ~real;
      sources = sources ~known:[ (file, src) ];
    }
  in
  (* the module is checked once first, so a mistake in it is said once *)
  (try
     ignore
       (Driver.console ~types_only:true ~journal:s.journal ~load ~dir ~home
          ~file ~src ~real ~history:[] "()")
   with e -> fail ~known:[ (file, src) ] e);
  Console.run ~echo:(not (Unix.isatty Unix.stdin)) s stdin

let () =
  (* `ren core [--types] [--release] <file.ren>`: the flags are taken
     out, and the rest read as any command's is *)
  let types, release, argv =
    match Sys.argv with
    | [| ren; "core"; "--types"; path |] ->
        (true, false, [| ren; "core"; path |])
    | [| ren; "core"; "--release"; path |] ->
        (false, true, [| ren; "core"; path |])
    | [| ren; "core"; "--types" | "--release"; "--types" | "--release"; path |]
      ->
        (true, true, [| ren; "core"; path |])
    | argv -> (false, false, argv)
  in
  match argv with
  | [| _; "--help" | "-h" | "help" |] ->
      (* asked for, so it's the output, not an error *)
      print_endline usage
  | [| _; "--version" |] -> print_endline version
  | args when Array.length args >= 2 && args.(1) = "test" ->
      test (List.tl (List.tl (Array.to_list args)))
  | args when Array.length args >= 2 && args.(1) = "run" ->
      run (List.tl (List.tl (Array.to_list args)))
  | args when Array.length args >= 2 && args.(1) = "replay" ->
      replay (List.tl (List.tl (Array.to_list args)))
  | args when Array.length args >= 2 && args.(1) = "build" ->
      build (List.tl (List.tl (Array.to_list args)))
  | args when Array.length args >= 2 && args.(1) = "console" ->
      console (List.tl (List.tl (Array.to_list args)))
  | [| _; cmd; path |] -> (
      let src = read path in
      let load = loader path in
      try
        match cmd with
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
              (List.tl
                 (if release then fst (Driver.specialized ~load ~file:path src)
                  else Driver.linked ~load ~file:path src))
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
