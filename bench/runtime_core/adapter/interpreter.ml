(* A sim reference adapter over unchanged Core. [run_installed] is exactly
   the interpreter's test entry; optional order recording observes it. *)
open Ren

let read path = In_channel.with_open_bin path In_channel.input_all
let source path = try Some (read path) with Sys_error _ -> None

let ending ~dir =
  let place (loc : Loc.t) =
    let prefix = Filename.concat dir "" in
    let file =
      if String.starts_with ~prefix loc.file then
        String.sub loc.file (String.length prefix) (String.length loc.file - String.length prefix)
      else loc.file
    in
    Journal.place ~file loc
  in
  function
  | Ok _ -> Journal.Exited
  | Error (Eval.Failed text) -> Journal.Errored text
  | Error (Eval.Panicked (Eval.Panic { loc; msg; _ })) ->
      Journal.Panicked { at = place loc; msg }
  | Error (Eval.Panicked (Eval.Assert_failed { loc; _ })) ->
      Journal.Panicked { at = place loc; msg = "this `assert` failed" }
  | Error (Eval.Panicked e) -> raise e
  | Error Eval.Passed -> failwith "a value-returning entry reported Passed"

let signature = function
  | Ok value, lines -> ("ok:" ^ Value.show value, lines)
  | Error (Eval.Failed text), lines -> ("failed:" ^ text, lines)
  | Error (Eval.Panicked e), lines ->
      let text = Option.value (Driver.render_error ~sources:source e) ~default:(Printexc.to_string e) in
      (text, lines)
  | Error Eval.Passed, _ -> failwith "unexpected Passed"

let run ~program ~seed ~journal ~test ~parity =
  let dir = Filename.dirname program in
  let suite = Driver.suite ~lint:true ~load:source ~dir [ (program, read program) ] in
  let _, home, tests = List.find (fun (file, _, _) -> file = program) suite.files in
  let fn, real, root =
    match test with
    | None -> (Path.make home "main", [ "Console" ], "main")
    | Some name ->
        let matches = List.filter (fun (t : Test_items.test) -> t.name = name) tests in
        (match matches with
        | [ t ] -> (Path.make home t.fn, t.real, "test")
        | _ -> failwith ("expected one original test named " ^ name))
  in
  let entry =
    List.find_map
      (fun (p : Core.program) -> List.find_opt (fun (f : Core.fn_def) -> f.path = fn) p.fns)
      suite.core |> Option.get
  in
  let deps =
    Lower.main_uses entry
    |> List.filter_map (fun (p : Path.t) -> if List.mem p.name Prelude.world_deps then Some p.name else None)
  in
  let cx = Eval.load suite.core in
  let once record_order path =
    Out_channel.with_open_bin path (fun out ->
        let journal = Journal.recording ~file:path ~out ~program in
        Journal.start journal ~deps;
        let result = Eval.run_installed ~dir ~journal ~seed ~fn ~real ~root ~record_order cx in
        Journal.finish_recording journal (ending ~dir (fst result));
        result)
  in
  if parity then (
    (* Real Console writes externally; use test entries for parity so the
       console and every dependency match [ren test]'s exact reference. *)
    if test = None || real <> [] then
      failwith "reference parity requires a test with no real dependencies";
    let plain = Filename.temp_file "ren-core-reference" ".journal" in
    let calls file =
      let recording = Journal.load ~file (read file) in
      Array.to_list recording.entries
      |> List.filter_map (function
           | Journal.Call c -> Some (c.task, c.dep, c.op, c.args, c.gave)
           | _ -> None)
    in
    Fun.protect ~finally:(fun () -> Sys.remove plain) (fun () ->
        let reference = once false plain in
        let observed = once true journal in
        if signature reference <> signature observed then
          failwith "order observer changed the reference outcome or console";
        if calls plain <> calls journal then
          failwith "order observer changed world calls, their task paths or results");
    print_endline "reference parity: unchanged outcome, console, task paths, panic site and seed";
    0)
  else
    let outcome, lines = once true journal in
    List.iter print_endline lines;
    match outcome with
    | Ok value -> if value <> Value.VUnit then print_endline (Value.show value); 0
    | Error (Eval.Failed text) -> prerr_endline ("error: " ^ text); 1
    | Error (Eval.Panicked e) ->
        (match Driver.render_error ~sources:source e with
        | Some text -> prerr_string text
        | None -> raise e);
        1
    | Error Eval.Passed -> failwith "unexpected Passed"

let () =
  let test = ref None and parity = ref false and positional = ref [] in
  Arg.parse
    [ ("--test", Arg.String (fun name -> test := Some name), "original test name");
      ("--check-reference-parity", Arg.Set parity, "compare optional observer with unchanged test reference") ]
    (fun value -> positional := !positional @ [ value ])
    "interpreter PROGRAM SEED JOURNAL [--test NAME]";
  try
    let status =
      match !positional with
      | [ program; seed; journal ] ->
          run ~program ~seed:(int_of_string seed) ~journal ~test:!test ~parity:!parity
      | _ -> failwith "expected PROGRAM SEED JOURNAL"
    in
    exit status
  with e ->
    (match Driver.render_error ~sources:source e with
    | Some text -> prerr_string text
    | None -> prerr_endline (Printexc.to_string e));
    exit 2
