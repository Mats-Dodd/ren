(* Running the C compiler on the C emit_c.ml writes (compiler.md, "Native
   slice"; foundations.md, decision 13).

   A release build is one C file, compiled by clang -O2, or $REN_CC. A
   debug build is units of C, compiled apart and in parallel, then
   linked: by tcc, which compiles them 12 to 24 times faster than clang
   -O0 (research/backend.md), found as $REN_TCC or on PATH; by $REN_CC if
   that's set, which bench/build.t's sanitizer builds use; or, with
   neither, by cc -O0, with a note that says how to get tcc. *)

let sprintf = Printf.sprintf

(* The C compiler a debug build runs, whether it's tcc, and a note to
   print if it's the slower fallback. *)
type compiler = { cc : string; tcc : bool; note : string option }

(* [name] on PATH, if it's there. *)
let on_path name =
  let dirs =
    match Sys.getenv_opt "PATH" with
    | Some p -> String.split_on_char ':' p
    | None -> []
  in
  List.find_map
    (fun dir ->
      let f = Filename.concat (if dir = "" then "." else dir) name in
      match Unix.access f [ Unix.X_OK ] with
      | () when not (Sys.is_directory f) -> Some f
      | () | (exception Unix.Unix_error _) | (exception Sys_error _) -> None)
    dirs

let is_tcc cc =
  String.starts_with ~prefix:"tcc" (Filename.basename cc)

let debug_compiler () =
  match Sys.getenv_opt "REN_CC" with
  | Some cc when cc <> "" -> { cc; tcc = is_tcc cc; note = None }
  | _ -> (
      match Sys.getenv_opt "REN_TCC" with
      | Some tcc when tcc <> "" -> { cc = tcc; tcc = true; note = None }
      | _ -> (
          match on_path "tcc" with
          | Some tcc -> { cc = tcc; tcc = true; note = None }
          | None ->
              {
                cc = "cc";
                tcc = false;
                note =
                  Some
                    "note: tcc isn't on PATH or in $REN_TCC, so this debug \
                     build compiles with cc -O0, which is slower; \
                     tools/tcc.sh installs tcc";
              }))

(* How many units compile at once: $REN_JOBS, or one for each core. *)
let jobs () =
  match Option.bind (Sys.getenv_opt "REN_JOBS") int_of_string_opt with
  | Some n when n > 0 -> n
  | _ -> Domain.recommended_domain_count ()

(* $REN_CFLAGS, split at spaces. *)
let extra_flags () =
  match Sys.getenv_opt "REN_CFLAGS" with
  | Some f -> List.filter (( <> ) "") (String.split_on_char ' ' f)
  | None -> []

exception Failed of string list

(* The C compiler, which couldn't be run, and why. *)
exception Missing of string * string

(* Run each command, a program and its arguments, at most [jobs] at a
   time; the commands that failed, if any did, once all have ended. *)
let run_all ~jobs (cmds : (string * string list) list) =
  let running = Hashtbl.create 16 and failed = ref [] in
  let wait () =
    let pid, status =
      let rec go () =
        try Unix.wait () with Unix.Unix_error (Unix.EINTR, _, _) -> go ()
      in
      go ()
    in
    match Hashtbl.find_opt running pid with
    | Some cmd ->
        Hashtbl.remove running pid;
        if status <> Unix.WEXITED 0 then failed := cmd :: !failed
    | None -> ()
  in
  List.iter
    (fun (prog, args) ->
      if Hashtbl.length running >= jobs then wait ();
      (* a compiler that isn't there, `REN_TCC=/no/such/tcc`, is reported
         as that, not as a bug *)
      match
        Unix.create_process prog
          (Array.of_list (prog :: args))
          Unix.stdin Unix.stdout Unix.stderr
      with
      | pid -> Hashtbl.replace running pid (Filename.quote_command prog args)
      | exception Unix.Unix_error (e, _, _) ->
          while Hashtbl.length running > 0 do
            wait ()
          done;
          raise (Missing (prog, Unix.error_message e)))
    cmds;
  while Hashtbl.length running > 0 do
    wait ()
  done;
  match !failed with [] -> () | cmds -> raise (Failed (List.rev cmds))

(* Time [f] as `REN_PASS_TIMES` times the compiler's passes (driver.ml),
   if it's set. *)
let timed name f =
  if Sys.getenv_opt "REN_PASS_TIMES" = None then f ()
  else
    let t0 = Unix.gettimeofday () in
    let r = f () in
    Printf.eprintf "ren pass %s: %.3f s\n%!" name (Unix.gettimeofday () -. t0);
    r

(* Whether the binary [f] is Mach-O, by its first four bytes: a 64-bit
   Mach-O file starts with 0xfeedfacf, written little-endian. *)
let mach_o f =
  In_channel.with_open_bin f (fun ic ->
      In_channel.really_input_string ic 4 = Some "\xcf\xfa\xed\xfe")

(* A debug build of [units], written to [dir], to the binary [out], by
   [c]: each unit compiled to an object, [jobs] at once, then linked. A
   binary clang links from objects has no debug information of its own:
   dsymutil gathers it from them, as clang does when it compiles and
   links at once. That's macOS's Mach-O: an ELF binary, on Linux, carries
   its debug information itself, and dsymutil can't read it. *)
let debug ~(c : compiler) ~jobs ~stats ~dir ~out (u : Emit_c.units) =
  let write name text =
    let f = Filename.concat dir name in
    Out_channel.with_open_bin f (fun oc -> output_string oc text);
    f
  in
  ignore (write "ren_rt.h" u.header);
  let sources =
    write "ren_rt.c" u.runtime
    :: List.map (fun (name, text) -> write (name ^ ".c") text) u.program
  in
  (* -ffp-contract=off, so a `Float` is computed as `ren run` computes
     it, never with a fused multiply and add; tcc never fuses them. tcc
     warns of a function that might not return, which Ren's C never
     does, so its warnings are off *)
  let flags =
    (if c.tcc then [ "-g"; "-w" ] else [ "-O0"; "-g"; "-ffp-contract=off" ])
    @ (if stats then [ "-DREN_STATS" ] else [])
    @ extra_flags ()
  in
  let objects = List.map (fun f -> Filename.remove_extension f ^ ".o") sources in
  timed (sprintf "C compile (%d units, %s)" (List.length sources) c.cc)
    (fun () ->
      run_all ~jobs
        (List.map2 (fun src o -> (c.cc, flags @ [ "-c"; src; "-o"; o ])) sources
           objects));
  timed "link" (fun () ->
      run_all ~jobs:1
        [ (c.cc, flags @ [ "-o"; out ] @ objects @ [ "-lm"; "-lpthread" ]) ]);
  (if (not c.tcc) && mach_o out then
     Option.iter
       (fun dsymutil ->
         timed "dsymutil" (fun () -> run_all ~jobs:1 [ (dsymutil, [ out ]) ]))
       (on_path "dsymutil"));
  List.iter Sys.remove (sources @ objects);
  Sys.remove (Filename.concat dir "ren_rt.h")

(* A release build of [c], one C file, to the binary [out]: by $REN_CC,
   or cc, at -O2. *)
let release ~stats ~dir ~out c =
  let file = Filename.concat dir "main.c" in
  Out_channel.with_open_bin file (fun oc -> output_string oc c);
  let cc = Option.value (Sys.getenv_opt "REN_CC") ~default:"cc" in
  let flags =
    [ "-O2"; "-ffp-contract=off" ]
    @ (if stats then [ "-DREN_STATS" ] else [])
    @ extra_flags ()
  in
  timed "C compile (one file)" (fun () ->
      run_all ~jobs:1
        [ (cc, flags @ [ "-o"; out; file; "-lm"; "-lpthread" ]) ]);
  Sys.remove file
