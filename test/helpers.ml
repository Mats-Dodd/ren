(* Helpers shared by the expect tests, which are split by pass into the
   test_*.ml files. Each test prints something, and [%expect] holds what it
   should print. Workflow:

     dune runtest     shows a diff if output changed
     dune promote     accepts the new output into the test file

   Leave [%expect {||}] empty when writing a new test, then promote. *)

open Ren

let file = "test.ren"

(* Test sources start with a newline for readability; drop it so line numbers
   in error messages match what you'd see in a real file. *)
let clean src =
  if String.starts_with ~prefix:"\n" src then
    String.sub src 1 (String.length src - 1)
  else src

(* Run [f], printing the error it raises, if any. [files] are the sources
   an error can show, by file name. *)
let report_files files f =
  try f ()
  with e -> (
    match Driver.render_error ~sources:(fun f -> List.assoc_opt f files) e with
    | Some msg -> print_string msg
    | None -> raise e)

(* The same, for a program that is the one file [src]. *)
let report src f = report_files [ (file, src) ] f

(* [args] are what `ren run` was given after `--`. *)
let run ?args src =
  let src = clean src in
  report src (fun () ->
      print_endline (Value.show (Driver.run ~lint:true ?args ~file src)))

let tokens src =
  let src = clean src in
  report src (fun () ->
      print_endline (Driver.dump_tokens (Driver.tokens ~file src)))

let ast src =
  let src = clean src in
  report src (fun () ->
      List.iter
        (fun f -> print_endline (Ast.show_item f))
        (Driver.parse ~file src))

(* The entry module's signatures; a program of one file has no other
   module. *)
let types src =
  let src = clean src in
  report src (fun () ->
      List.iter
        (fun (_, sigs) -> List.iter print_endline sigs)
        (Driver.types ~lint:true ~file src))

(* ---- programs of several modules ----

   [files] are the program's files, by name, the entry first:
   [("main.ren", ...); ("billing/stripe.ren", ...)]. A module is loaded
   from the list, as the CLI would load it from disk. *)

let program files =
  let files = List.map (fun (f, src) -> (f, clean src)) files in
  let entry, src = List.hd files in
  let load m = List.assoc_opt (Driver.module_file ~entry m) files in
  (files, entry, src, load)

let run_files files =
  let files, file, src, load = program files in
  report_files files (fun () ->
      print_endline (Value.show (Driver.run ~lint:true ~load ~file src)))

(* Every module's signatures, as `ren types` prints them. *)
let types_files files =
  let files, file, src, load = program files in
  report_files files (fun () ->
      List.iteri
        (fun i (home, sigs) ->
          if i > 0 then print_newline ();
          print_endline ("-- " ^ home);
          List.iter print_endline sigs)
        (Driver.types ~lint:true ~load ~file src))

let plan_types =
  {|
type Plan =
  | Free
  | Pro(seats: Int)
  | Enterprise(contract: Int)

type User = { id: Int, plan: Plan }
|}

(* A function in Core, as [Core.show_fn] prints it, but with each binder
   numbered by where it first appears, from 1: [p/1], [ev/2]. How lowering
   numbers its binders is its own business, and a snapshot shouldn't
   change when that does; which uses are of the same binder still shows.
   They're renumbered before the lines are broken, so how they're broken
   doesn't depend on the old numbers either. *)
let show_fn f =
  let ids = Hashtbl.create 16 in
  let number id =
    match Hashtbl.find_opt ids id with
    | Some n -> n
    | None ->
        let n = Hashtbl.length ids + 1 in
        Hashtbl.add ids id n;
        n
  in
  let digit c = c >= '0' && c <= '9' in
  (* each `/` and the id after it, in an atom: a binder is a name, a `/`
     and its id, and can be inside an atom, as in [&x/3] *)
  let atom s =
    let b = Buffer.create (String.length s) in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '/' && !i > 0 && !i + 1 < n && digit s.[!i + 1] then (
        let j = ref (!i + 1) in
        while !j < n && digit s.[!j] do
          incr j
        done;
        let id = int_of_string (String.sub s (!i + 1) (!j - !i - 1)) in
        Buffer.add_string b ("/" ^ string_of_int (number id));
        i := !j)
      else (
        Buffer.add_char b s.[!i];
        incr i)
    done;
    Buffer.contents b
  in
  let rec go : Core.sexp -> Core.sexp = function
    | Atom a when String.starts_with ~prefix:"\"" a -> Atom a (* a string *)
    | Atom a -> Atom (atom a)
    | List xs -> List (List.map go xs)
  in
  Core.render 0 (go (Core.fn_sexp f))

(* The program lowered to Core (core.ml), one function per line, after
   Core Lint has checked it. *)
let core src =
  let src = clean src in
  report src (fun () ->
      List.iter
        (fun f -> print_endline (show_fn f))
        (Driver.core ~lint:true ~file src).fns)

(* Every module of the program in Core, but the prelude, each after its
   name. *)
let core_files files =
  let files, file, src, load = program files in
  report_files files (fun () ->
      List.iteri
        (fun i (m : Core.program) ->
          if i > 0 then print_newline ();
          print_endline ("-- " ^ m.home);
          List.iter (fun f -> print_endline (show_fn f)) m.fns)
        (List.tl (Driver.linked ~lint:true ~load ~file src)))

(* ---- tests ----

   `ren test` on the program [files], every one a module whose tests run,
   as if they were the files of a folder: what it prints, without how long
   it took, and the status it exits with. [path] is what `ren test` was
   given, which a rerun command repeats. *)
let test_files ?(path = ".") ?only ?(exact = false) ?seed ?(list = false) files
    =
  let files = List.map (fun (f, src) -> (f, clean src)) files in
  let load m = List.assoc_opt (Driver.file_in ~dir:"." m) files in
  report_files files (fun () ->
      let suite = Driver.suite ~lint:true ~load ~dir:"." files in
      let status =
        Test_runner.run
          ~opts:{ path; dir = "."; only; exact; seed; list; timings = false }
          ~sources:(fun f -> List.assoc_opt f files)
          suite
      in
      Printf.printf "[exit %d]\n" status)

(* The same, for a program that is the one file [src]. *)
let test ?only ?exact ?seed ?list src =
  test_files ~path:file ?only ?exact ?seed ?list [ (file, src) ]

(* ---- negative tests ----

   A test that a program is refused prints the error in its [%expect]
   block, and `dune promote` accepts whatever is printed. If a change made
   the program check, the error would vanish from the block and promote
   would accept that silently. These helpers fail the test outright
   instead when nothing is reported, so a lost error can't be promoted
   away: ppx_expect reports an exception the test raises, and accepting it
   takes writing [@@expect.uncaught_exn] by hand. *)

exception No_error of string

(* Run [f], which should report an error, printing it; fail if it
   doesn't. *)
let expecting_error files f =
  let reported = ref false in
  (try f ()
   with e -> (
     match Driver.render_error ~sources:(fun f -> List.assoc_opt f files) e with
     | Some msg ->
         reported := true;
         print_string msg
     | None -> raise e));
  if not !reported then
    raise (No_error "expected an error, but the program checked")

(* The entry module, which should be refused: what `ren check` says. *)
let check_error src =
  let src = clean src in
  expecting_error [ (file, src) ] (fun () -> ignore (Driver.check ~file src))

(* The same, for a program of several files, the entry first. *)
let check_error_files files =
  let files, file, src, load = program files in
  expecting_error files (fun () -> ignore (Driver.check ~load ~file src))

(* A program that should panic, or fail with an error nothing handles,
   when it runs: what `ren run` says. *)
let run_error ?args src =
  let src = clean src in
  expecting_error
    [ (file, src) ]
    (fun () ->
      print_endline (Value.show (Driver.run ~lint:true ?args ~file src)))
