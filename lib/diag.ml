(* Diagnostics: compiler errors that explain themselves.

   Errors are raised as an exception and caught once, at the top level, which
   renders them like this:

     error: comparisons can't be chained
       ┌─ test.ren:2:13
     2 │   1 < 2 < 3
       │         ^
       help: split it into two comparisons *)

type t = {
  loc : Loc.t;
  msg : string;
  notes : string list;
  help : string option;
}

exception Error of t

(* [notes] are extra facts printed as `= ...` lines; [help] suggests a fix. *)
let error ?help ?(notes = []) loc msg = raise (Error { loc; msg; notes; help })

let line_text src n =
  match List.nth_opt (String.split_on_char '\n' src) (n - 1) with
  | Some l -> l
  | None -> ""

let render ~src (d : t) =
  let { Loc.file; start; stop } = d.loc in
  let text = line_text src start.line in
  let gutter = string_of_int start.line in
  let pad = String.make (String.length gutter) ' ' in
  (* Underline to the end of the span, or to the end of the line if the span
     continues onto later lines. *)
  let stop_col =
    if stop.line = start.line then stop.col else String.length text + 1
  in
  let width = max 1 (stop_col - start.col) in
  let b = Buffer.create 256 in
  Printf.bprintf b "error: %s\n" d.msg;
  Printf.bprintf b "%s ┌─ %s:%d:%d\n" pad file start.line start.col;
  Printf.bprintf b "%s │ %s\n" gutter text;
  Printf.bprintf b "%s │ %s%s\n" pad
    (String.make (start.col - 1) ' ')
    (String.make width '^');
  List.iter (fun n -> Printf.bprintf b "%s = %s\n" pad n) d.notes;
  Option.iter (fun h -> Printf.bprintf b "%s help: %s\n" pad h) d.help;
  Buffer.contents b
