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

let types src =
  let src = clean src in
  report src (fun () ->
      List.iter print_endline (Driver.types ~lint:true ~file src))

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
