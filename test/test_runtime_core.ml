(* Runtime core step 0. Future checks are explicitly skipped: no current
   parser refusal, native refusal or absent C runner counts as a pass.
   Turn each [until] into a direct call when its step lands. The external
   runner variables are executable paths, never shell fragments. *)

open Helpers

let until step _check = Printf.printf "SKIP until %s\n" step

let has text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let refusal src headline help =
  let out, raised = captured (fun () -> check_error src) in
  Option.iter raise raised;
  List.iter
    (fun part -> if not (has out part) then failwith ("missing diagnostic: " ^ part))
    [ "error:"; headline; "help: " ^ help ]

(* A future harness must fail an unknown case, and exit nonzero on a
   violated assertion. Requiring it here prevents an enabled milestone
   from silently succeeding when its runner has not been built. *)
let runner variable cases =
  let executable =
    match Sys.getenv_opt variable with
    | Some path when path <> "" -> path
    | _ -> failwith (variable ^ " must name the built runtime-core test runner")
  in
  List.iter
    (fun name ->
      let command = Filename.quote executable ^ " --case " ^ Filename.quote name in
      if Sys.command command <> 0 then failwith ("runtime-core case failed: " ^ name))
    cases

let%expect_test "[c1 reject] submit and foreign declarations need trust" =
  until "c1" (fun () ->
      refusal "fn main() = Async.submit(1)"
        "Async.submit is only available inside trust"
        "call a dependency whose trust handler submits the world call";
      refusal "foreign fn checksum(x: Int) -> Int\nfn main() = ()"
        "foreign fn is only available inside trust"
        "declare it as trust foreign fn, and keep world effects in a driver";
      refusal "foreign include \"header.h\"\nfn main() = ()"
        "foreign include is only available inside trust"
        "write trust foreign include \"header.h\"";
      refusal "blocking fn work(x: Int) -> Int = x\nfn main() = ()"
        "blocking fn is only available inside trust"
        "declare it as trust blocking fn, and call it through the driver");
  [%expect {| SKIP until c1 |}]

let%expect_test "[c1 reject] trust item, body and row errors have their help" =
  until "c1" (fun () ->
      refusal "trust type Number = Int\nfn main() = ()"
        "this item cannot be marked trust"
        "mark a function or handler trust, or use a trust block";
      refusal "trust foreign fn f(x: Int) -> Int = x\nfn main() = ()"
        "a foreign function has no Ren body"
        "remove its body, or write a blocking fn to run a Ren body on the driver's pool";
      refusal "trust foreign fn f() uses Clock\nfn main() = ()"
        "a foreign function must have an empty dependency row"
        "put world access in a dependency's driver; a foreign fn is a plain C call";
      refusal "trust blocking fn f() uses Clock = Clock.sleep(Duration.ms(1))\nfn main() = ()"
        "a blocking function must have an empty dependency row"
        "pass data to the function and make its foreign calls inside one blocking body";
      refusal "trust fn f() = Async.submit(1)\nfn main() = ()"
        "Async.submit needs a world dependency's Call value"
        "submit the D.Call made by the world dependency's bottom handler");
  [%expect {| SKIP until c1 |}]

let%expect_test "[c1 reject] callback rows, nondata results and ABI types" =
  until "c1" (fun () ->
      refusal
        "trust foreign fn invoke(callback: fn() uses Clock) -> Int\nfn main() = ()"
        "a callback into Ren must have an empty dependency row"
        "handle its dependencies before passing it to C";
      refusal "trust blocking fn work() -> fn() = fn() => ()\nfn main() = ()"
        "a blocking function must return replayable data"
        "keep raw pointers and OS handles inside the driver, and return a data id";
      refusal "trust foreign fn bad(x: Array<Int>) -> Int\nfn main() = ()"
        "this type cannot cross the foreign ABI"
        "pass scalars, raw borrowed pointers, or a callback with an empty row");
  [%expect {| SKIP until c1 |}]

let%expect_test "[c1 reject] fixed ABI, data arguments, captures and raw memory" =
  until "c1" (fun () ->
      refusal "trust foreign fn generic<T>(value: T) -> T\nfn main() = ()"
        "a foreign declaration needs an explicit fixed ABI signature"
        "write each parameter and result type, and put generics or variadics behind a C shim";
      refusal "trust blocking fn work(callback: fn()) = callback()\nfn main() = ()"
        "a blocking function needs data arguments"
        "pass owned data or a lent buffer; keep callbacks, instances and raw pointers in the driver";
      refusal
        "trust foreign fn invoke(callback: fn() -> Int) -> Int\ntrust fn work() -> Int =\n  let value = 42\n  invoke(fn() => value)\nfn main() = ()"
        "this foreign callback captures local values"
        "pass a capture-free function and an explicit borrowed context to a C shim";
      refusal "fn touch(p: Foreign.Ptr<UInt8>) = ()\nfn main() = ()"
        "raw foreign memory is only available inside trust"
        "keep Foreign.Ptr and raw memory operations inside a trust function or block");
  [%expect {| SKIP until c1 |}]

(* Pointer escape is intentionally left in the external c1 inventory:
   the source surface for raw borrowed pointers has not landed yet. *)
let%expect_test "[c1] driver accepts and remaining ABI refusals" =
  until "c1" (fun () ->
      runner "REN_CORE_LANGUAGE_TEST"
        [ "trust-function-handler-and-block"; "foreign-inline-pure";
          "foreign-include-separate-unit"; "blocking-one-world-call";
          "empty-row-callback-accepted"; "callback-nonempty-row-help";
          "blocking-nondata-result-help"; "foreign-memory-escape-help";
          "foreign-unsupported-abi-type-help"; "driver-world-row-help";
          "foreign-explicit-fixed-signature-help"; "blocking-nondata-argument-help";
          "foreign-capturing-callback-help"; "foreign-memory-outside-trust-help";
          "interpreter-world-through-submit" ]);
  [%expect {| SKIP until c1 |}]

let%expect_test "[c2] binary journals, unchanged v3 view and schema checks" =
  until "c2" (fun () ->
      runner "REN_CORE_JOURNAL_TEST"
        [ "binary-order-content-roundtrip"; "shape-table-by-hash";
          "bin-structural-derivation"; "v3-view-byte-identical";
          "post-order-and-call-id"; "cross-build-replay";
          "changed-type-version-error-names-type";
          "truncated-header-refused"; "truncated-record-refused" ]);
  [%expect {| SKIP until c2 |}]

(* MODEL.md's traces and mutants are concrete C bodies in
   bench/runtime_core/core_protocol.c, driven by its official runner.
   REN_CORE_TEST_SOURCES supplies real core/adapter sources when c3 lands. *)
let core_tests extra =
  let script = "../bench/runtime_core/core_tests.py" in
  let command =
    String.concat " " (List.map Filename.quote ("python3" :: script :: "--run" :: extra))
  in
  if Sys.command command <> 0 then failwith "production C core protocol checks failed"

let%expect_test "[c3] model counterexamples and mutants with rule on and off" =
  until "c3" (fun () -> core_tests []);
  [%expect {| SKIP until c3 |}]

let%expect_test "[c3] ends once, host ABI and sanitizer host replies" =
  until "c3" (fun () -> core_tests [ "--sanitizers" ]);
  [%expect {| SKIP until c3 |}]

let%expect_test "[c4] task journals and frames across interpreter and native" =
  until "c4" (fun () ->
      runner "REN_CORE_CONFORMANCE_TEST"
        [ "all-test-tasks-programs-1000-seeds"; "11a-programs-1000-seeds";
          "cancel-tree"; "first-error-up"; "finally-shield-deadline";
          "panic-program-end-journal"; "until-yield-tick"; "isolate-reference-programs";
          "single-fixed-order"; "sim-point-set";
          "lost-update-interpreter-seed-native-replay";
          "x1-roundtrip-within-10-percent"; "x5-parked-bytes-within-10-percent" ]);
  [%expect {| SKIP until c4 |}]

let%expect_test "[c4] channel admission, terminal state and cleanup by journal" =
  until "c4" (fun () ->
      runner "REN_CORE_CONFORMANCE_TEST"
        [ "consumer-exits-full-queue-producer-joined";
          "cancel-send-admission-commit"; "cancel-receive-commit";
          "close-blocked-senders-and-receivers"; "buffered-values-before-failure";
          "merge-first-failure-full-queue-no-terminal-slot";
          "named-generator-partial-consume-scope-finalize";
          "expand-all-workers-frontier-progress" ]);
  [%expect {| SKIP until c4 |}]

let%expect_test "[c5] every services family test and rule 3 by journal" =
  until "c5" (fun () ->
      runner "REN_CORE_CONFORMANCE_TEST"
        [ "all-services-s6-s7-s8-tests-native-journal";
          "all-services-review-family-tests-native-journal";
          "all-structured-actors-10a-10b-tests-native-journal";
          "all-test-actors-tests-native-journal";
          "rule3-backstop-interpreter-message"; "docs-chaos-1000-seeds";
          "services-lost-update-seed-4702"; "services-memory-seed-9904";
          "sampled-eviction-interpreter-tape";
          "family-drain-outward-post-admitted-work-preserved";
          "actor-channel-cycle-deadlock-seed-replay" ]);
  [%expect {| SKIP until c5 |}]

let%expect_test "[c5] declaration edit stability, generic and family fixtures" =
  until "c5" (fun () ->
      runner "REN_CORE_EDIT_TEST"
        [ "generic-unrelated-declaration-byte-identical";
          "family-unrelated-declaration-byte-identical";
          "body-edit-only-own-declaration"; "callee-local-frame-bump";
          "shape-hash-carry-and-dispatcher"; "declaration-relative-resume-lines";
          "interface-colour-dependents-only" ]);
  [%expect {| SKIP until c5 |}]

let%expect_test "[c6] real driver, applications and replay in both directions" =
  until "c6" (fun () ->
      runner "REN_CORE_CONFORMANCE_TEST"
        [ "server-real-driver-native"; "server-sim-native";
          "just-concurrent-recipes-native"; "clock-net-fs-proc-real-driver";
          "native-record-interpreter-replay"; "interpreter-record-native-replay";
          "stall-watchdog-counter" ]);
  [%expect {| SKIP until c6 |}]
