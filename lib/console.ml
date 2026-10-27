(* `ren console <module>` (testing.md, "The console"): a line at a time,
   inside a module, each a `let`, a `var` or an expression, and what an
   expression gives is printed with its type, `Money(0) : Money`. It runs
   on the test implementations of the built-ins, unless `--real` names
   some. Driver.console checks and runs the session; this is the loop
   around it, which reads each line, says what it gave, and keeps it if it
   checked and ran. *)

let sprintf = Printf.sprintf

(* What the loop needs: the program's loader and folder, the module's
   path, file and source, the built-ins it gets the real one of, what
   they gave so far (Builtins.journal), and how to find any file's text,
   for a message. *)
type session = {
  load : Driver.loader;
  dir : string;
  home : string;
  file : string;
  src : string;
  real : string list;
  journal : Builtins.journal;
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

(* Print what checking or running a line raised, on stderr, with [line]
   the text of the console's own file. Anything else is a bug, and goes
   on. *)
let report s ~line e =
  let sources f = if f = Driver.console_file then Some line else s.sources f in
  match Driver.render_error ~sources e with
  | Some msg -> prerr_string msg
  | None -> raise e

(* Read lines from [input] until it ends or one is `:q`, showing the
   prompt before each, and the line after it when [echo], so a session
   fed from a file reads as one typed in. *)
let run ?(echo = false) s input =
  let prompt = s.home ^ "> " in
  (* the lines kept, and how many lines the session has printed *)
  let history = ref [] and printed = ref 0 in
  let rec loop () =
    print_string prompt;
    flush stdout;
    match In_channel.input_line input with
    | None -> print_newline ()
    | Some line -> (
        if echo then print_endline line;
        let line = String.trim line in
        let starts p = String.starts_with ~prefix:p line in
        let attempt f = try f () with e -> report s ~line e in
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
                  Driver.console ~types_only:true ~col ~journal:s.journal
                    ~load:s.load ~dir:s.dir ~home:s.home ~file:s.file ~src:s.src
                    ~real:s.real ~history:!history (String.trim e)
                in
                print_endline r.ty);
            flush stderr;
            loop ()
        | _ when starts ":" ->
            prerr_endline
              (sprintf "error: there's no console command `%s`"
                 (List.hd (String.split_on_char ' ' line)));
            prerr_endline "  help: `:t <expression>` shows its type, `:q` quits";
            loop ()
        | _ ->
            (* the session runs from its start each time, so only what it
               printed after the last line kept is new *)
            let show_new lines =
              List.iteri
                (fun i l -> if i >= !printed then print_endline l)
                lines
            in
            attempt (fun () ->
                let r =
                  try
                    Driver.console ~journal:s.journal ~load:s.load ~dir:s.dir
                      ~home:s.home ~file:s.file ~src:s.src ~real:s.real
                      ~history:!history line
                  with Driver.Console_failed (lines, e) ->
                    (* what it printed before it failed, then why; it isn't
                       kept, so what it printed isn't counted *)
                    show_new lines;
                    flush stdout;
                    raise e
                in
                show_new r.printed;
                printed := List.length r.printed;
                Option.iter (fun v -> print_endline (v ^ " : " ^ r.ty)) r.shown;
                history := !history @ [ line ]);
            flush stderr;
            loop ())
  in
  loop ()
