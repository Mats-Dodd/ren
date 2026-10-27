(* `ren console <module>` (testing.md, "The console"): a line at a time,
   inside a module, each a `let`, a `var` or an expression, and what an
   expression gives is printed with its type, `Money(0) : Money`. It runs
   on the test implementations of the built-ins, unless `--real` names
   some. Driver.console checks and runs the session; this is the loop
   around it, which reads each line, says what it gave, and keeps it if it
   checked and ran. *)

let sprintf = Printf.sprintf

(* What the loop needs: the program's loader and folder, the module's
   path, file and source, which `:reload` reads again, the built-ins it
   gets the real one of, the session's journal (journal.ml), and how to
   find any file's text, for a message. *)
type session = {
  load : Driver.loader;
  dir : string;
  home : string;
  file : string;
  mutable src : string;
  real : string list;
  journal : Journal.t;
  sources : string -> string option;
}

(* The built-ins `--real` can name: those with a real implementation. *)
let built_ins = List.map fst Test_items.defaults

(* The `--real` names that aren't one, if any, as the error says it. *)
let unknown_real names =
  match List.filter (fun n -> not (List.mem n built_ins)) names with
  | [] -> None
  | n :: _ ->
      Some
        (sprintf
           "error: `--real` names a built-in dependency with a real \
            implementation, and only %s have one, not `%s`"
           (Infer_msg.and_list built_ins)
           n)

(* Print what checking or running a line raised, on stderr, with [text]
   the text of the console's own file, the session's lines, and the
   module's as the session has it, which `:reload` changes; and [note]
   after its own notes, what the session does about it. Anything else is
   a bug, and goes on. *)
let report ?note s ~text e =
  let sources f =
    if f = Driver.console_file then Some text
    else if f = s.file then Some s.src
    else s.sources f
  in
  let noted (d : Diag.t) = { d with notes = d.notes @ Option.to_list note } in
  let e, after =
    match (e, note) with
    | _, None -> (e, None)
    | Diag.Error d, Some _ -> (Diag.Error (noted d), None)
    | Diag.Errors ds, Some _ ->
        let rev = List.rev ds in
        (Diag.Errors (List.rev (noted (List.hd rev) :: List.tl rev)), None)
    | Eval.Went_differently { loc; differs }, Some n ->
        ( Eval.Went_differently
            { loc; differs = { differs with notes = differs.notes @ [ n ] } },
          None )
    | _, Some n -> (e, Some n)
  in
  match Driver.render_error ~sources e with
  | Some msg ->
      prerr_string msg;
      Option.iter (fun n -> prerr_endline ("  = " ^ n)) after
  | None -> raise e

(* The line of the session that what [e] says is in, if it's in one. *)
let line_of = function
  | Eval.Went_differently { differs = { line = Some n; _ }; _ } -> Some n
  | Diag.Error { loc; _ }
  | Diag.Errors ({ loc; _ } :: _)
  | Eval.Panic { loc; _ }
  | Eval.Assert_failed { loc; _ }
    when loc.file = Driver.console_file ->
      Some loc.start.line
  | _ -> None

let help =
  "`:t <expression>` shows its type, `:reload` checks the module again and \
   runs the session on it, `:spec [name]` turns the session into a test, `:q` \
   quits"

(* Read lines from [input] until it ends or one is `:q`, showing the
   prompt before each, and the line after it when [echo], so a session
   fed from a file reads as one typed in. *)
let run ?(echo = false) s input =
  let prompt = s.home ^ "> " in
  (* the lines kept, each with the value it showed, if it showed one *)
  let history = ref [] in
  let lines () = List.map fst !history in
  let text line = String.concat "\n" (lines () @ [ line ]) in
  let console ?types_only ?col ~history line =
    Driver.console ?types_only ?col ~journal:s.journal ~load:s.load ~dir:s.dir
      ~home:s.home ~file:s.file ~src:s.src ~real:s.real ~history line
  in
  (* `:reload`: the module read again, checked, and the session run on
     it from its first line, each kept call given back; from a line
     that doesn't check, or goes differently, the lines are dropped *)
  let reload () =
    match In_channel.with_open_bin s.file In_channel.input_all with
    | exception Sys_error msg -> prerr_endline ("error: " ^ msg)
    | src -> (
        let old = s.src in
        s.src <- src;
        let all = lines () in
        let run () =
          match List.rev all with
          | [] -> ignore (console ~types_only:true ~history:[] "()")
          | last :: rest -> ignore (console ~history:(List.rev rest) last)
        in
        match run () with
        | () ->
            print_endline
              (sprintf "reloaded %s, and ran the session's %s again" s.file
                 (match all with
                 | [ _ ] -> "line"
                 | _ -> sprintf "%d lines" (List.length all)))
        | exception e -> (
            let text = String.concat "\n" all in
            match line_of e with
            | Some n ->
                report s ~text e
                  ~note:
                    (sprintf
                       "the session goes on from line %d, which is dropped, \
                        and those after it"
                       n);
                history := List.filteri (fun i _ -> i < n - 1) !history;
                Journal.drop_from s.journal ~line:n
            | None ->
                report s ~text e
                  ~note:(sprintf "the session goes on with %s as it was" s.file);
                s.src <- old))
  in
  (* `:spec`: the session as a test, added to the end of the module's
     file, if it's still what the session read: an edit saved since isn't
     overwritten, or tested without being run first *)
  let spec name =
    let name = if name = "" then "a console session" else name in
    match In_channel.with_open_bin s.file In_channel.input_all with
    | exception Sys_error msg -> prerr_endline ("error: " ^ msg)
    | now when now <> s.src ->
        prerr_endline
          (sprintf
             "error: %s has changed since the session read it, so `:spec` adds \
              nothing to it"
             s.file);
        prerr_endline
          "  help: `:reload` first, to run the session on it, then `:spec` \
           again"
    | _ -> (
        match
          Driver.console_spec ~load:s.load ~dir:s.dir ~home:s.home ~file:s.file
            ~src:s.src ~name !history
        with
        | exception e -> report s ~text:(text "") e
        | test, left ->
            let left_out () =
              List.iter
                (fun (n, line, why) ->
                  print_endline
                    (sprintf "  = left out line %d, `%s`: %s" n line
                       (String.uncapitalize_ascii why)))
                left
            in
            (match test with
            | Some test ->
                let added =
                  if String.ends_with ~suffix:"\n" s.src || s.src = "" then test
                  else "\n" ^ test
                in
                Out_channel.with_open_gen
                  [ Open_wronly; Open_append; Open_binary ] 0o644 s.file
                  (fun oc -> output_string oc added);
                s.src <- s.src ^ added;
                print_endline (sprintf "added to %s, to edit or delete:" s.file);
                print_string test
            | None ->
                print_endline
                  (sprintf
                     "nothing added to %s: a test of it can keep none of the \
                      session's lines"
                     s.file));
            left_out ())
  in
  let rec loop () =
    print_string prompt;
    flush stdout;
    match In_channel.input_line input with
    | None -> print_newline ()
    | Some line -> (
        if echo then print_endline line;
        let line = String.trim line in
        let starts p = String.starts_with ~prefix:p line in
        let attempt f = try f () with e -> report s ~text:(text line) e in
        flush stdout;
        match line with
        | "" -> loop ()
        | ":q" -> ()
        | ":t" ->
            prerr_endline "error: `:t` needs an expression to show the type of";
            prerr_endline "  help: write it after `:t`, `:t 1 + 2`";
            loop ()
        | _ when starts ":t " ->
            (* the expression, where it is in the line, so a message
               points into the line as it was typed *)
            let e = String.sub line 3 (String.length line - 3) in
            let col = 3 + String.length e - String.length (String.trim e) in
            attempt (fun () ->
                let r =
                  console ~types_only:true ~col ~history:(lines ())
                    (String.trim e)
                in
                print_endline r.ty);
            flush stderr;
            loop ()
        | ":reload" ->
            reload ();
            flush stdout;
            flush stderr;
            loop ()
        | _ when line = ":spec" || starts ":spec " ->
            spec (String.trim (String.sub line 5 (String.length line - 5)));
            flush stdout;
            flush stderr;
            loop ()
        | _ when starts ":" ->
            prerr_endline
              (sprintf "error: there's no console command `%s`"
                 (List.hd (String.split_on_char ' ' line)));
            prerr_endline ("  help: " ^ help);
            loop ()
        | _ ->
            attempt (fun () ->
                let r = console ~history:(lines ()) line in
                flush stdout;
                Option.iter (fun v -> print_endline (v ^ " : " ^ r.ty)) r.shown;
                history := !history @ [ (line, r.shown) ]);
            flush stdout;
            flush stderr;
            loop ())
  in
  loop ()
