(* Diagnostics: compiler errors that explain themselves.

   A diagnostic points at the code that caused it, and can point at other
   code too, with a label saying why:

     error: there are two functions named `f`
       ┌─ test.ren:2:4
     1 │ fn f() = 1
       │    - the first `f` is here
     2 │ fn f() = 2
       │    ^
       help: rename one of them

   A pass doesn't stop at its first error. It reports each one to a [sink]
   and carries on, so one run shows every independent mistake. Code that
   can't go on after an error raises [Error], and the pass catches it at the
   next point where it can carry on (the next function, say) with
   [recover]. Once a pass finishes, the driver raises [Errors] with
   everything it reported, and later passes never run. *)

type t = {
  loc : Loc.t;
  msg : string;
  says : string option;  (** text beside the error's own `^`s *)
  notes : string list;
  help : string option;
  labels : (Loc.t * string) list;  (** other code worth pointing at *)
}

exception Error of t
exception Errors of t list

(* [says] is printed beside the error's own underline; [notes] are extra
   facts printed as `= ...` lines; [help] suggests a fix; [labels] point at
   other code. *)
let make ?says ?help ?(notes = []) ?(labels = []) loc msg =
  { loc; msg; says; notes; help; labels }

let error ?says ?help ?notes ?labels loc msg =
  raise (Error (make ?says ?help ?notes ?labels loc msg))

(* ---- collecting ---- *)

(* A record with a [mutable] field: [report] changes it in place, so every
   function holding the sink sees what the others reported. *)
type sink = { mutable reported : t list  (** most recent first *) }

let sink () = { reported = [] }
let report sink d = sink.reported <- d :: sink.reported
let has_errors sink = sink.reported <> []

(* Run [f]; if it raises a diagnostic, report it and return [default]. *)
let recover sink ~default f =
  try f ()
  with Error d ->
    report sink d;
    default

(* Everything reported, in source order. [List.stable_sort] keeps
   diagnostics at the same place in the order they were reported. *)
let reported sink =
  let pos d = (d.loc.file, d.loc.start.line, d.loc.start.col) in
  List.stable_sort (fun a b -> compare (pos a) (pos b)) (List.rev sink.reported)

(* ---- rendering ---- *)

let line_text src n =
  match List.nth_opt (String.split_on_char '\n' src) (n - 1) with
  | Some l -> l
  | None -> ""

(* [sources] is the source map: the text of each file a diagnostic can
   point into, by its name. A label in a file it doesn't have (the
   prelude's) can't be shown as source, so it's a `= note` line instead. A
   label in another file it does have gets a `┌─` header of its own:

     error: import cycle: a → b → a
       ┌─ b.ren:1:1
     1 │ import a
       │ ^^^^^^^^
       ┌─ a.ren:1:1
     1 │ import b
       │ -------- `a` imports `b` here *)
let render ~(sources : string -> string option) (d : t) =
  let shown, elsewhere =
    List.partition (fun ((l : Loc.t), _) -> sources l.file <> None) d.labels
  in
  let spans = (d.loc, None) :: List.map (fun (l, s) -> (l, Some s)) shown in
  (* the files in the order they come up, the error's own first *)
  let files =
    List.fold_left
      (fun acc ((l : Loc.t), _) ->
        if List.mem l.file acc then acc else acc @ [ l.file ])
      [] spans
  in
  let width =
    List.fold_left
      (fun w ((l : Loc.t), _) ->
        max w (String.length (string_of_int l.start.line)))
      0 spans
  in
  let pad = String.make width ' ' in
  let b = Buffer.create 256 in
  Printf.bprintf b "error: %s\n" d.msg;
  List.iter
    (fun file ->
      let src = Option.value (sources file) ~default:"" in
      (* Each span in line order, the source line printed once above its
         underlines: `^` for the error itself, `-` and the text for a
         label. *)
      let by_line =
        List.stable_sort
          (fun ((a : Loc.t), _) ((b : Loc.t), _) ->
            compare a.start.line b.start.line)
          (List.filter (fun ((l : Loc.t), _) -> l.file = file) spans)
      in
      (* the header points at the error itself, or, in another file, at
         its first label *)
      let first = if file = d.loc.file then d.loc else fst (List.hd by_line) in
      Printf.bprintf b "%s ┌─ %s:%d:%d\n" pad file first.start.line
        first.start.col;
      let last = ref 0 in
      List.iter
        (fun ((l : Loc.t), label) ->
          let text = line_text src l.start.line in
          if l.start.line <> !last then
            Printf.bprintf b "%*d │ %s\n" width l.start.line text;
          last := l.start.line;
          (* Underline to the end of the span, or to the end of the line if
             the span continues onto later lines. *)
          let stop_col =
            if l.stop.line = l.start.line then l.stop.col
            else String.length text + 1
          in
          let n = max 1 (stop_col - l.start.col) in
          let mark, text =
            match label with
            | None ->
                ( String.make n '^',
                  match d.says with Some s -> " " ^ s | None -> "" )
            | Some s -> (String.make n '-', " " ^ s)
          in
          Printf.bprintf b "%s │ %s%s%s\n" pad
            (String.make (l.start.col - 1) ' ')
            mark text)
        by_line)
    files;
  List.iter
    (fun ((l : Loc.t), s) ->
      Printf.bprintf b "%s = %s: %s:%d:%d\n" pad s l.file l.start.line
        l.start.col)
    elsewhere;
  List.iter (fun n -> Printf.bprintf b "%s = %s\n" pad n) d.notes;
  Option.iter (fun h -> Printf.bprintf b "%s help: %s\n" pad h) d.help;
  Buffer.contents b

(* Several diagnostics, a blank line between each. *)
let render_all ~sources ds = String.concat "\n" (List.map (render ~sources) ds)
