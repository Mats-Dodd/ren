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

let run src =
  let src = clean src in
  report src (fun () ->
      print_endline (Value.show (Driver.run ~lint:true ~file src)))

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

(* The program lowered to Core (core.ml), one function per line, after
   Core Lint has checked it. *)
let core src =
  let src = clean src in
  report src (fun () ->
      List.iter
        (fun f -> print_endline (Core.show_fn f))
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
          List.iter (fun f -> print_endline (Core.show_fn f)) m.fns)
        (List.tl (Driver.linked ~lint:true ~load ~file src)))
