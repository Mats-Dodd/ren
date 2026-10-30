(* The other half of the validator's differential test (diff.c): reads
   the inputs `diff stream` writes, each with what the runtime said, and
   holds that against OCaml's `String.is_valid_utf_8` and against the
   interpreter's own `Str.from_utf8` and `Str.from_utf8_lossy`
   (builtins.ml), which find `at` and `incomplete` with OCaml's decoder.
   So `ren run` and a native build can't disagree on any of them: valid
   or not, `at`, `incomplete`, and the length of lossy's output, which
   is one U+FFFD for each maximal invalid subpart.

   Each record is three 64-bit little-endian integers, the input's
   length, the runtime's `at` (-1 if valid) and lossy's length; a byte,
   `incomplete`; then the input. A length of -1 ends the stream. *)

open Ren

let int64 ic =
  let b = really_input_string ic 8 in
  Int64.to_int (String.get_int64_le b 0)

(* what the interpreter says of [b]: [-1, false] or [at, incomplete],
   and the length of its lossy string *)
let interpreter b =
  let call x =
    fst (Builtins.run x ~dicts:[] ~tys:[] ~made:(fun () -> 0) [ Value.VBytes b ])
  in
  let at, incomplete =
    match call Intrinsic.Str_from_utf8 with
    | _ -> (-1, false)
    | exception Builtins.Fail (VTag { name = "InvalidUtf8"; args = [ VInt at; VBool i ]; _ }) ->
        (Int64.to_int at, i)
  in
  let lossy =
    match call Intrinsic.Str_from_utf8_lossy with
    | VStr s -> String.length s
    | _ -> failwith "lossy gave something that isn't a string"
  in
  (at, incomplete, lossy)

let () =
  let ic = stdin in
  set_binary_mode_in ic true;
  let inputs = ref 0 and bad = ref 0 in
  let rec go () =
    let n = int64 ic in
    if n >= 0 then begin
      let at = int64 ic in
      let lossy = int64 ic in
      let incomplete = input_char ic <> '\000' in
      let b = really_input_string ic n in
      incr inputs;
      let at', incomplete', lossy' = interpreter b in
      let agree =
        String.is_valid_utf_8 b = (at < 0)
        && at = at'
        && (at < 0 || incomplete = incomplete')
        && lossy = lossy'
      in
      if not agree then begin
        incr bad;
        if !bad <= 5 then
          Printf.eprintf
            "disagree, input %d of %d bytes: runtime at %d, incomplete %b, lossy %d; interpreter at %d, incomplete %b, lossy %d\n"
            !inputs n at incomplete lossy at' incomplete' lossy'
      end;
      go ()
    end
  in
  go ();
  Printf.printf "OCaml: %d inputs, %d disagreements\n" !inputs !bad;
  exit (if !bad = 0 then 0 else 1)
