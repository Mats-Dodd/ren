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
  code : string list;
      (** code the help writes, printed under it a line each: the `match`
          that takes a field from a sum's variants *)
  code_at : int option;
      (** the column [code] is to be pasted at, if it's lines to add to the
          source as they are: the arms a `match` misses, `Some(Closed) =>
          todo`, start at its arms' column, so a whole line copied from the
          terminal pastes in place *)
  labels : (Loc.t * string) list;  (** other code worth pointing at *)
}

exception Error of t
exception Errors of t list

(* [says] is printed beside the error's own underline; [notes] are extra
   facts printed as `= ...` lines; [help] suggests a fix, and [code] is
   code it writes, each line printed under it; [labels] point at other
   code. *)
let make ?says ?help ?(code = []) ?code_at ?(notes = []) ?(labels = []) loc
    msg =
  { loc; msg; says; notes; help; code; code_at; labels }

let error ?says ?help ?code ?code_at ?notes ?labels loc msg =
  raise (Error (make ?says ?help ?code ?code_at ?notes ?labels loc msg))

(* "a `Bool`", "an `Int`", and by the sound: "a `Unit`", "a `User`", but
   "an `Undo`", "an `Update`" *)
let article name =
  let starts p = String.starts_with ~prefix:p name in
  let vowel =
    match name.[0] with
    | 'A' | 'E' | 'I' | 'O' -> true
    | 'U' -> (starts "Un" && not (starts "Uni")) || starts "Up" || starts "Ul"
    | _ -> false
  in
  if vowel then Printf.sprintf "an `%s`" name else Printf.sprintf "a `%s`" name

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
   diagnostics at the same place in the order they were reported.

   Some code is checked more than once: a group's parameters and `with`,
   and a run's arguments, are part of the function made for each of its
   tests (test_items.ml). The same error at the same place is shown once:
   the table of those already kept compares every field, as [=] does, so
   only an exact copy of one reported earlier is dropped. It's only looked
   up, never walked, so its order never shows. *)
let reported sink =
  let pos d = (d.loc.file, d.loc.start.line, d.loc.start.col) in
  let seen = Hashtbl.create 16 in
  let once =
    List.fold_left
      (fun kept d ->
        if Hashtbl.mem seen d then kept
        else (
          Hashtbl.replace seen d ();
          d :: kept))
      [] (List.rev sink.reported)
  in
  List.stable_sort (fun a b -> compare (pos a) (pos b)) (List.rev once)

(* ---- rendering ---- *)

(* A file's lines, split once, so that each can be found by its number
   without splitting the whole file again. *)
let lines src = Array.of_list (String.split_on_char '\n' src)

(* Line [n] of [lines], counting from 1; empty if there's no such line. *)
let line lines n =
  if n >= 1 && n <= Array.length lines then lines.(n - 1) else ""

(* Line [n] of the text [src]. It splits all of [src], so code that shows
   several lines of one file splits it once with [lines] instead. *)
let line_text src n = line (lines src) n

(* The source map [sources], with each file's lines split the first time
   they're asked for and kept for the next time. Keyed by file name and
   only ever looked up, so the table's order never shows. *)
let indexed (sources : string -> string option) =
  let split = Hashtbl.create 4 in
  fun file ->
    match Hashtbl.find_opt split file with
    | Some ls -> ls
    | None ->
        let ls = Option.map lines (sources file) in
        Hashtbl.replace split file ls;
        ls

(* A rendered diagnostic, in pieces: what [render] prints, and what a
   native binary keeps of a panic's message (driver.ml, [site_pieces]),
   which shares the pieces many panics have, a file's name and a line of
   its source, instead of keeping each message whole. [Hole] is where the
   message of a panic goes, which only the running program knows. *)
type piece =
  | Text of string
  | Shared of string
      (** text that many diagnostics have: a file's name, or a line of it *)
  | Spaces of int
  | Marks of char * int  (** a `^` or a `-`, this many times *)
  | Num of int
  | Slice of string * int * int
      (** the [n] bytes from [i] of a [Shared] text: an operand, as the source
          writes it *)
  | Hole

(* The text [pieces] stand for, with [hole] in the [Hole]. *)
let expand ?(hole = "") pieces =
  let b = Buffer.create 256 in
  List.iter
    (function
      | Text s | Shared s -> Buffer.add_string b s
      | Spaces n -> Buffer.add_string b (String.make n ' ')
      | Marks (c, n) -> Buffer.add_string b (String.make n c)
      | Num n -> Buffer.add_string b (string_of_int n)
      | Slice (s, i, n) -> Buffer.add_string b (String.sub s i n)
      | Hole -> Buffer.add_string b hole)
    pieces;
  Buffer.contents b

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
       │ -------- `a` imports `b` here

   [lines_of] is the source map [indexed]: each file's lines, split once
   (see [render] and [render_all]). The diagnostic comes as [piece]s,
   which [expand] makes text. *)
let pieces_indexed ~(lines_of : string -> string array option) (d : t) =
  let shown, elsewhere =
    List.partition (fun ((l : Loc.t), _) -> lines_of l.file <> None) d.labels
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
  (* the pieces, most recent first *)
  let out = ref [] in
  let add p = out := p :: !out in
  let pad () = add (Spaces width) in
  add (Text (Printf.sprintf "error: %s\n" d.msg));
  List.iter
    (fun file ->
      let src = Option.value (lines_of file) ~default:(lines "") in
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
      pad ();
      List.iter add
        [
          Text " ┌─ ";
          Shared file;
          Text ":";
          Num first.start.line;
          Text ":";
          Num first.start.col;
          Text "\n";
        ];
      let last = ref 0 in
      (* a file the map doesn't have, the prelude's, has only its header *)
      if lines_of file <> None then
        List.iter
          (fun ((l : Loc.t), label) ->
            let text = line src l.start.line in
            if l.start.line <> !last then (
              (* the line's number, right-aligned in [width] *)
              add
                (Spaces
                   (max 0 (width - String.length (string_of_int l.start.line))));
              List.iter add
                [ Num l.start.line; Text " │ "; Shared text; Text "\n" ]);
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
              | None -> ('^', match d.says with Some s -> " " ^ s | None -> "")
              | Some s -> ('-', " " ^ s)
            in
            pad ();
            List.iter add
              [
                Text " │ ";
                (* [String.make]'s, which fails on a column before the first,
                   as it did when this was text *)
                Spaces (String.length (String.make (l.start.col - 1) ' '));
                Marks (mark, n);
                Text (text ^ "\n");
              ])
          by_line)
    files;
  List.iter
    (fun ((l : Loc.t), s) ->
      pad ();
      List.iter add
        [
          Text (" = " ^ s ^ ": ");
          Shared l.file;
          Text ":";
          Num l.start.line;
          Text ":";
          Num l.start.col;
          Text "\n";
        ])
    elsewhere;
  List.iter
    (fun n ->
      pad ();
      add (Text (" = " ^ n ^ "\n")))
    d.notes;
  Option.iter
    (fun h ->
      pad ();
      add (Text (" help: " ^ h ^ "\n")))
    d.help;
  (* the help's code, four spaces in from `help:`, or at the column it's
     to be pasted at *)
  List.iter
    (fun l ->
      match d.code_at with
      | Some col -> add (Text (String.make (max 0 (col - 1)) ' ' ^ l ^ "\n"))
      | None ->
          pad ();
          add (Text ("     " ^ l ^ "\n")))
    d.code;
  List.rev !out

let render_indexed ~lines_of d = expand (pieces_indexed ~lines_of d)

(* One diagnostic, in pieces, with the source map [sources]. *)
let pieces ~sources d = pieces_indexed ~lines_of:(indexed sources) d

(* One diagnostic, with the source map [sources]. *)
let render ~sources d = render_indexed ~lines_of:(indexed sources) d

(* Several diagnostics, a blank line between each. Each file is split into
   lines once, for all of them. *)
let render_all ~sources ds =
  let lines_of = indexed sources in
  String.concat "\n" (List.map (render_indexed ~lines_of) ds)
