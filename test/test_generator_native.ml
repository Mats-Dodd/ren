(* Ordinary Return stays usable while generator execution itself waits for
   g4. Covered+Return has no independent source spelling today: finally is
   a handler/generator construct. Exercise that native refusal with valid
   Core rather than letting the generator refusal mask it. *)
open Ren
open Core

let%expect_test "[g1] native return through an outcome-aware finally is an explicit boundary" =
  let src = "fn main() -> Int = 7\n" in
  let linked = Driver.linked ~lint:true ~file:"native_return.ren" src in
  let change (f : fn_def) =
    if Path.local f.path <> "main" then f
    else
      let errors : Ty.row = { labels = [ { name = "Cancelled"; payload = [] } ]; tail = None } in
      let result_ty = Ty.Con (Path.prelude "Result", [ Ty.int; Ty.Errors errors ]) in
      let result : var = { id = 90001; name = "result"; ty = result_ty } in
      let value = Core.mk (Int 7L) Ty.int f.loc in
      let body = Core.mk (Return (f.path, value)) result_ty f.loc in
      { f with body =
          Core.mk (Covered { body; result; after = value; return_target = Some f.path }) Ty.int f.loc }
  in
  let linked = List.map (fun (p : program) -> { p with fns = List.map change p.fns }) linked in
  let entry = List.hd (List.rev linked) in
  Core_lint.program ~imports:[] ~linked entry;
  (match To_mem.program linked with
  | _ -> failwith "native Covered+Return unexpectedly compiled: turn this refusal into a native behavior test"
  | exception To_mem.Unsupported (_, "a `return` through an outcome-aware `finally`") ->
      print_endline "valid Core; native return through outcome-aware finally is explicitly refused");
  [%expect {| valid Core; native return through outcome-aware finally is explicitly refused |}]
