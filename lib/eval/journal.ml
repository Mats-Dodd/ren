(* The journal (handlers.md, "The journal"): the calls a program made to
   the world, each with what it gave, and how the program ended. This is
   the one module that knows its format, so the format can change here
   alone; handlers.md says it will, once real journals exist.

     # ren journal 1 · main.ren · deps: Console Fs Os Proc
     1 Fs.read("justfile") → Ok("all: build test\n...")
     2 Os.args() → ["build"]
     3 Console.error("echo base")
     4 Proc.run("sh", ["-c", "echo base"]) → Ok(0)
     ...
     19 exit 0

   A journal is text, one call a line: its number, the call, its
   arguments, and what it gave after `→`, left out when that's `()` or
   `Ok(())`. The last line is how the run ended: `exit 0`, `error`
   and the error nothing handled, written as a value is, or `panic`,
   where, and what it said, in quotes. The header names the program,
   from the journal's folder (or absolutely, if that climbs more than two
   folders up), and the dependencies `main` uses. A line after it that
   starts with `#` is a comment.

   Values are written by the walk `show` and `==` use (walk.ml), as
   they're written in Ren, but that an opaque value is written as what
   it's represented as, a `Path` as its string, and `Bytes` as a string,
   with `\xNN` for a byte that isn't UTF-8. Reading one back is told its
   type, so the two can't be confused. `<redacted>` reads as a value
   that can't be given back, which `secret` types will need.

   The recorder and the replayer are handlers in the prelude, which call
   the intrinsics `journal_gave`, `journal_answer` and the rest
   (prelude.ml); the interpreter runs those (eval.ml) with the journal
   they're given, by its number in [registry], since a Ren program holds
   one as a `Journal`, an opaque `Int`. What they do depends on why it's
   open ([mode]): recording a run, replaying one strictly, standing in
   for the world in a test, or keeping a console session's calls. *)

open Value

let sprintf = Printf.sprintf

(* The version of the format, which a reader checks. *)
let version = 2

(* ---- calls ---- *)

(* A call, as it's written: the task that made it, by its path (`main`,
   `main/run_all:0`), its dependency and operation, its arguments, and
   what it gave, [None] for `()` or `Ok(())`. A call that [waits], which
   the task waited in, is written in two lines, its start and, after the
   poll that completed it, what it gave. [line] is where it is in its
   journal's file, and [gave_line] where what it gave is, 0 for one not
   read from a file. What a call that waits gave is read from its second
   line, once its first has been ([load]). *)
type call = {
  task : string;
  dep : string;
  op : string;
  args : string;
  mutable gave : string option;
  waits : bool;
  line : int;
  mutable gave_line : int;
}

(* `Fs.read("justfile")` *)
let call_text c = sprintf "%s.%s(%s)" c.dep c.op c.args

(* the same, with what it gave *)
let entry_text c =
  match c.gave with None -> call_text c | Some g -> call_text c ^ " → " ^ g

(* The same call, with its task, but for `main`'s, which a program that starts
   no task has all of: how a message shows it. *)
let shown c = if c.task = "main" then call_text c else c.task ^ " " ^ call_text c

(* Two calls are the same if their dependency, operation and arguments
   are. *)
let same a b = a.dep = b.dep && a.op = b.op && a.args = b.args

(* How a run ended. A panic's [at] is its file, from the program's
   folder, its line and its column: `main.ren:3:9`. *)
type ending =
  | Exited
  | Stopped of int
      (** cancelled by the signal numbered so, which nothing stopped for:
          it exits with 128 and the number, `exit 143` *)
  | Errored of string
      (** with this error, nothing having handled it, as the journal writes it
          ([write]) *)
  | Panicked of { at : string; msg : string }

(* How a message says it: `the end, `exit 0``, `panic at main.ren:3:9:
   ...`. *)
let ending_said = function
  | Exited -> "the end, `exit 0`"
  | Stopped n -> sprintf "the end, `exit %d`, stopped by a signal" (128 + n)
  | Errored e -> sprintf "the end, failing with `%s`" e
  | Panicked { at; msg } -> sprintf "panic at %s: %s" at msg

(* How a message says a replayed program ended, where the recording
   didn't. *)
let ended_instead = function
  | Exited -> "this program ended instead, with `exit 0`"
  | Stopped n -> sprintf "this program ended instead, with `exit %d`, stopped by a signal" (128 + n)
  | Errored e -> sprintf "this program ended instead, failing with `%s`" e
  | Panicked { at; msg } ->
      sprintf "this program ended instead, in a panic at %s: %s" at msg

(* ---- writing values ---- *)

(* [s] in quotes, with what would break the line, or isn't UTF-8 in
   [Bytes], escaped. *)
let quote s =
  let utf8 = String.is_valid_utf_8 s in
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | '\\' -> Buffer.add_string b "\\\\"
      | '"' -> Buffer.add_string b "\\\""
      | c
        when Char.code c < 0x20
             || c = '\x7f'
             || (Char.code c >= 0x80 && not utf8) ->
          Printf.bprintf b "\\x%02x" (Char.code c)
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* How a run ended, as its journal's last line: the error's a value,
   written already, and the panic's message is quoted, so neither can
   break the line. *)
let ending_text = function
  | Exited -> "exit 0"
  | Stopped n -> sprintf "exit %d" (128 + n)
  | Errored e -> "error " ^ e
  | Panicked { at; msg } -> sprintf "panic %s %s" at (quote msg)

(* [v], a value of type [t], as the journal writes it. *)
let rec write (types : Walk.types) (t : Ty.ty) (v : Value.t) =
  let write = write types in
  let list xs = String.concat ", " xs in
  match Walk.view types t v with
  | Opaque (_, rep) -> write rep v
  | Leaf -> (
      match v with
      | VInt n -> Int64.to_string n
      | VFloat f when Float.is_nan f -> "nan"
      | VFloat f -> Ast.show_float f
      | VBool b -> string_of_bool b
      | VStr s | VBytes s -> quote s
      | VUnit -> "()"
      | v -> Value.show v)
  | Elems (elem, xs) ->
      "[" ^ list (Array.to_list (Array.map (write elem) xs)) ^ "]"
  | Parts parts -> "(" ^ list (List.map (fun (t, x) -> write t x) parts) ^ ")"
  | Record { name; fields; _ } ->
      name ^ " { "
      ^ list (List.map (fun (f, t, x) -> f ^ ": " ^ write t x) fields)
      ^ " }"
  | Ctor { name; fields = []; _ } | Tag (name, []) -> name
  | Ctor { name; fields; names = Some names; _ } ->
      name ^ " { "
      ^ list (List.map2 (fun f (t, x) -> f ^ ": " ^ write t x) names fields)
      ^ " }"
  | Ctor { name; fields; _ } ->
      name ^ "(" ^ list (List.map (fun (t, x) -> write t x) fields) ^ ")"
  | Tag (name, payload) ->
      name ^ "(" ^ list (List.map (fun (t, x) -> write t x) payload) ^ ")"
  | Entries _ | Members _ | Hidden _ | Shape -> Value.show v

(* A call's arguments, [a] of type [ta], as they're written between its
   parentheses: none is `()`, and several are a tuple. *)
let write_args types (ta : Ty.ty) a =
  match (ta, a) with
  | Con (p, parts), VTuple xs when Ty.is_tuple p ->
      String.concat ", " (List.map2 (write types) parts xs)
  | _, VUnit -> ""
  | _ -> write types ta a

(* What a call gave, [r] of type [tr], as it's written, or [None] if it
   says nothing: it's an [output] (handlers.md, "A journal as a test
   fixture"), whose operation gives `()`, and it gave `()`, or `Ok(())`
   as an operation that can fail does. Which calls are outputs is
   decided once, by the operation's declared type, by the interpreter
   (eval.ml, [gives_nothing]). *)
let rec write_gave types (tr : Ty.ty) r ~output =
  match (tr, r) with
  (* what an operation that can't fail gave, which the recorder kept as
     a `Result` (prelude.ml, `recorder`): its value *)
  | Con (p, [ t; Errors { labels = []; tail = None } ]), VCon { name = "Ok"; args = [ v ]; _ }
    when p = Path.prelude "Result" ->
      write_gave types t v ~output
  | _, VUnit -> None
  | _, VCon { name = "Ok"; args = [ VUnit ]; _ } when output -> None
  | _ -> Some (write types tr r)

(* ---- reading values ---- *)

(* The text isn't a value of the type it's read as. *)
exception Unreadable

(* `<redacted>`: a value the recording left out (handlers.md, "What an
   entry holds"), which can't be given back. *)
exception Redacted

type reader = { text : string; mutable at : int }

let peek r = if r.at < String.length r.text then Some r.text.[r.at] else None

let skip_spaces r =
  while peek r = Some ' ' do
    r.at <- r.at + 1
  done

let expect r s =
  skip_spaces r;
  let n = String.length s in
  if r.at + n <= String.length r.text && String.sub r.text r.at n = s then
    r.at <- r.at + n
  else raise Unreadable

let accept r s =
  skip_spaces r;
  let n = String.length s in
  if r.at + n <= String.length r.text && String.sub r.text r.at n = s then (
    r.at <- r.at + n;
    true)
  else false

(* the characters while [ok] holds *)
let span r ok =
  skip_spaces r;
  let from = r.at in
  while match peek r with Some c -> ok c | None -> false do
    r.at <- r.at + 1
  done;
  String.sub r.text from (r.at - from)

let ident r =
  match
    span r (function
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
      | _ -> false)
  with
  | "" -> raise Unreadable
  | s -> s

(* a string in quotes, with its escapes undone *)
let quoted r =
  expect r "\"";
  let b = Buffer.create 16 in
  let rec go () =
    match peek r with
    | None -> raise Unreadable
    | Some '"' -> r.at <- r.at + 1
    | Some '\\' -> (
        let next i =
          if r.at + i < String.length r.text then r.text.[r.at + i]
          else raise Unreadable
        in
        match next 1 with
        | 'n' ->
            Buffer.add_char b '\n';
            r.at <- r.at + 2;
            go ()
        | 't' ->
            Buffer.add_char b '\t';
            r.at <- r.at + 2;
            go ()
        | 'r' ->
            Buffer.add_char b '\r';
            r.at <- r.at + 2;
            go ()
        | '\\' ->
            Buffer.add_char b '\\';
            r.at <- r.at + 2;
            go ()
        | '"' ->
            Buffer.add_char b '"';
            r.at <- r.at + 2;
            go ()
        | 'x' -> (
            match
              int_of_string_opt
                ("0x" ^ String.make 1 (next 2) ^ String.make 1 (next 3))
            with
            | Some n ->
                Buffer.add_char b (Char.chr n);
                r.at <- r.at + 4;
                go ()
            | None -> raise Unreadable)
        | _ -> raise Unreadable)
    | Some c ->
        Buffer.add_char b c;
        r.at <- r.at + 1;
        go ()
  in
  go ();
  Buffer.contents b

(* [read_list r ~close item]: items with commas between, up to [close] *)
let read_list r ~close item =
  if accept r close then []
  else
    let rec go acc =
      let x = item () in
      if accept r "," then go (x :: acc)
      else (
        expect r close;
        List.rev (x :: acc))
    in
    go []

(* A value of type [t], read from [r]. *)
let rec read (types : Walk.types) (t : Ty.ty) r : Value.t =
  let read = read types in
  skip_spaces r;
  if accept r "<redacted>" then raise Redacted;
  let prim name = t = Ty.Con (Path.prelude name, []) in
  match t with
  | _ when prim "Int" -> (
      match
        Int64.of_string_opt
          (span r (function '-' | '0' .. '9' -> true | _ -> false))
      with
      | Some n -> VInt n
      | None -> raise Unreadable)
  | _ when prim "Float" -> (
      match
        float_of_string_opt
          (span r (function
            | '-' | '+' | '.' | 'e' | 'E'
            | '0' .. '9'
            | 'i' | 'n' | 'f' | 't' | 'y' | 'a' ->
                true
            | _ -> false))
      with
      | Some f -> VFloat f
      | None -> raise Unreadable)
  | _ when prim "Bool" -> (
      match ident r with
      | "true" -> VBool true
      | "false" -> VBool false
      | _ -> raise Unreadable)
  | _ when prim "Str" ->
      let s = quoted r in
      if String.is_valid_utf_8 s then VStr s else raise Unreadable
  | _ when prim "Bytes" -> VBytes (quoted r)
  | _ when prim "Unit" ->
      expect r "()";
      VUnit
  | Con (p, [ elem ]) when p = Path.prelude "Array" ->
      expect r "[";
      Value.array_of_list (read_list r ~close:"]" (fun () -> read elem r))
  | Con (p, parts) when Ty.is_tuple p ->
      expect r "(";
      let xs =
        List.map
          (fun t ->
            let x = read t r in
            ignore (accept r ",");
            x)
          parts
      in
      expect r ")";
      VTuple xs
  | Con (p, args) -> (
      match
        Option.map
          (fun (d : Iface.type_decl) -> d.body)
          (Hashtbl.find_opt types p)
      with
      | Some (Opaque (Rep rep)) -> read (Walk.subst args rep) r
      | Some (Record fs) ->
          ignore (ident r);
          expect r "{";
          let fields =
            List.mapi
              (fun i (f : Iface.field) ->
                if i > 0 then expect r ",";
                expect r f.fname;
                expect r ":";
                (f.fname, read (Walk.subst args f.fty) r))
              fs
          in
          expect r "}";
          VRecord (List.sort (fun (a, _) (b, _) -> String.compare a b) fields)
      | Some (Sum cs) -> (
          let name = ident r in
          match List.find_opt (fun (c : Iface.ctor) -> c.cname = name) cs with
          | Some { cfields = []; _ } -> VCon { ty = p; name; args = [] }
          | Some ({ cnamed = true; _ } as c) ->
              (* by name, in braces, as it's written *)
              expect r "{";
              let xs =
                List.mapi
                  (fun i (f : Iface.field) ->
                    if i > 0 then expect r ",";
                    expect r f.fname;
                    expect r ":";
                    read (Walk.subst args f.fty) r)
                  c.cfields
              in
              expect r "}";
              VCon { ty = p; name; args = xs }
          | Some c ->
              expect r "(";
              let xs =
                List.mapi
                  (fun i (f : Iface.field) ->
                    if i > 0 then expect r ",";
                    read (Walk.subst args f.fty) r)
                  c.cfields
              in
              expect r ")";
              VCon { ty = p; name; args = xs }
          | None -> raise Unreadable)
      | _ -> raise Unreadable)
  | Errors row -> (
      let name = ident r in
      match List.find_opt (fun (l : Ty.label) -> l.name = name) row.labels with
      | Some { payload = []; _ } -> VTag { name; args = []; tys = [] }
      | Some { payload; _ } ->
          expect r "(";
          let xs =
            List.mapi
              (fun i t ->
                if i > 0 then expect r ",";
                read t r)
              payload
          in
          expect r ")";
          VTag { name; args = xs; tys = payload }
      | None -> raise Unreadable)
  | _ -> raise Unreadable

(* A value of type [t], all of [text]. *)
let read_all types t text =
  let r = { text; at = 0 } in
  let v = read types t r in
  skip_spaces r;
  if r.at <> String.length text then raise Unreadable;
  v

(* What a call that said nothing gave: `()`, or `Ok(())`. *)
let nothing (tr : Ty.ty) : Value.t =
  if tr = Ty.unit then VUnit
  else VCon { ty = Path.prelude "Result"; name = "Ok"; args = [ VUnit ] }


(* ---- a journal's file ---- *)

type header = { program : string; deps : string list }

let header_text h =
  sprintf "# ren journal %d · %s · deps: %s" version h.program
    (String.concat " " h.deps)

(* What a journal's first line is, for a message. *)
let header_shape = "# ren journal 2 · <program> · deps: <dependencies>"

(* A line after the header: a call, or the second line of one that waits
   ([Gave], its task's), a poll that woke tasks, by their paths, in the
   order it woke them, a task that saw a cancel, or how the run ended;
   each with its line. *)
type entry =
  | Call of call
  | Gave of string * string option * int
  | Poll of string list * int
  | Cancel of string * int
  | End of ending * int

(* The task an entry is a task's, if it is one's. *)
let entry_task = function
  | Call c -> Some c.task
  | Gave (p, _, _) | Cancel (p, _) -> Some p
  | Poll _ | End _ -> None

let entry_line = function
  | Call c -> c.line
  | Gave (_, _, l) | Poll (_, l) | Cancel (_, l) | End (_, l) -> l

(* How a message shows an entry. *)
let entry_shown = function
  | Call c -> shown c
  | Gave (p, _, _) -> p ^ " →, the end of its call"
  | Poll (ps, _) -> "poll " ^ String.concat " " ps
  | Cancel (p, _) -> p ^ " cancelled"
  | End (e, _) -> ending_said e

(* An entry that can't be read, at its line of [file]: a message that
   shows it. *)
let unreadable ~file line msg ?notes ?help () =
  Diag.Error (Diag.make ?notes ?help (Loc.point ~file line 1) msg)

(* [text] split at the first [sep], if it has one. *)
let cut sep text =
  let n = String.length sep in
  let rec go i =
    if i + n > String.length text then None
    else if String.sub text i n = sep then
      Some
        ( String.sub text 0 i,
          String.sub text (i + n) (String.length text - i - n) )
    else go (i + 1)
  in
  go 0

(* Where the parenthesis that closes the one at [from] is, in [s],
   skipping strings and what's nested. *)
let closing s from =
  let n = String.length s in
  let rec go i depth quoted =
    if i >= n then None
    else
      match s.[i] with
      | '\\' when quoted -> go (i + 2) depth quoted
      | '"' -> go (i + 1) depth (not quoted)
      | _ when quoted -> go (i + 1) depth quoted
      | '(' | '[' | '{' -> go (i + 1) (depth + 1) quoted
      | (')' | ']' | '}') when depth = 1 -> Some i
      | ')' | ']' | '}' -> go (i + 1) (depth - 1) quoted
      | _ -> go (i + 1) depth quoted
  in
  go from 0 false

(* [text]'s first word, and the rest after the space. *)
let first_word text =
  match String.index_opt text ' ' with
  | Some i -> (String.sub text 0 i, String.sub text (i + 1) (String.length text - i - 1))
  | None -> (text, "")

(* Whether [w] can be a task's path, `main/accept:7/handle.op:0`. *)
let is_path w =
  w <> ""
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '/' | ':' | '.' -> true
         | _ -> false)
       w

(* The mark a call's first line ends with when the call waits: what it
   gave is on a line of its own, later. *)
let waiting = "…"

(* One line of a journal, after its number: a call, the end of one that
   waited, a poll, a cancel, or how the run ended. *)
let parse_entry ~file line text =
  let bad () =
    raise
      (unreadable ~file line
         (sprintf "this line of %s isn't a call or how the run ended" file)
         ~help:
           "a call is written `task Dep.op(arguments) → what it gave`, and the \
            last line `main exit 0`, `main error` and the error, or `main \
            panic`, where, and what it said in quotes"
         ())
  in
  let word, rest = first_word text in
  match word with
  | "poll" when rest <> "" ->
      Poll (List.filter (( <> ) "") (String.split_on_char ' ' rest), line)
  | task when not (is_path task) -> bad ()
  | task -> (
      let word, after = first_word rest in
      match word with
      | "cancelled" when after = "" -> Cancel (task, line)
      | "→" -> Gave (task, (if after = "" then None else Some after), line)
      | "exit" when after = "0" -> End (Exited, line)
      | "exit" when (match int_of_string_opt after with Some n -> n > 128 && n < 256 | None -> false) ->
          End (Stopped (int_of_string after - 128), line)
      | "error" when after <> "" -> End (Errored after, line)
      | "panic" -> (
          match String.index_opt after ' ' with
          | Some i -> (
              let r = { text = after; at = i + 1 } in
              match quoted r with
              | msg when r.at = String.length after ->
                  End (Panicked { at = String.sub after 0 i; msg }, line)
              | _ | (exception Unreadable) -> bad ())
          | None -> bad ())
      | _ -> (
          match (String.index_opt rest '.', String.index_opt rest '(') with
          | Some dot, Some paren when dot < paren -> (
              match closing rest paren with
              | Some close ->
                  let after =
                    String.trim
                      (String.sub rest (close + 1) (String.length rest - close - 1))
                  in
                  let gave, waits =
                    if after = "" then (None, false)
                    else if after = waiting then (None, true)
                    else
                      match cut "→" after with
                      | Some ("", g) -> (Some (String.trim g), false)
                      | _ -> bad ()
                  in
                  Call
                    {
                      task;
                      dep = String.sub rest 0 dot;
                      op = String.sub rest (dot + 1) (paren - dot - 1);
                      args = String.sub rest (paren + 1) (close - paren - 1);
                      gave;
                      waits;
                      line;
                      gave_line = line;
                    }
              | None -> bad ())
          | _ -> bad ()))

(* A journal of version 1, which this `ren` doesn't read: its file, as it
   was named, and its program, from the folder [file] is in. *)
exception Version_1 of { file : string; program : string }

(* What `ren replay` says of one, and a test that replays one: how to
   record it again, its program found from where it's run, as `ren run`
   would be given it. *)
let version_1_said ~file ~program =
  ( sprintf "`%s` is a version 1 journal, which this `ren` doesn't read" file,
    "version 2 names the task that made each call",
    sprintf "record it again: `ren run --record %s %s`" file program )

(* [path], from the folder [dir]: `tests/../main.ren` is `main.ren`. *)
let from_folder dir path =
  if not (Filename.is_relative path) then path
  else
    let parts =
      List.fold_left
        (fun acc name ->
          match (name, acc) with
          | ("" | "."), _ -> acc
          | "..", m :: rest when m <> ".." -> rest
          | n, _ -> n :: acc)
        []
        (String.split_on_char '/' (Filename.concat dir path))
    in
    String.concat "/" (List.rev parts)

(* The header, from the journal's first line. *)
let parse_header ~file first =
  let wrong () =
    raise
      (unreadable ~file 1
         (sprintf "%s isn't a journal: it doesn't start as one does" file)
         ~notes:[ "a journal starts `" ^ header_shape ^ "`" ]
         ~help:"record one with `ren run --record <file.journal> <file.ren>`" ())
  in
  let prefix = "# ren journal " in
  if not (String.starts_with ~prefix first) then wrong ();
  let rest =
    String.sub first (String.length prefix)
      (String.length first - String.length prefix)
  in
  let fields () =
    match cut " · " rest with
    | Some (_, rest) -> (
        match cut " · deps:" rest with
        | Some (program, deps) ->
            {
              program;
              deps = List.filter (( <> ) "") (String.split_on_char ' ' deps);
            }
        | None -> wrong ())
    | None -> wrong ()
  in
  match String.split_on_char ' ' rest with
  | "1" :: _ ->
      let h = fields () in
      raise
        (Version_1
           { file; program = from_folder (Filename.dirname file) h.program })
  | v :: _
    when int_of_string_opt v <> Some version && int_of_string_opt v <> None ->
      raise
        (unreadable ~file 1
           (sprintf
              "%s is a journal of version %s, and this ren reads version %d"
              file v version)
           ~help:"record it again with this ren" ())
  | _ -> fields ()

(* ---- a journal ---- *)

(* A console session's calls (testing.md, "The console"): those of the
   lines it kept, each with the line it's in and what it gave, which a
   real dependency gives back rather than being asked again; and those
   past them, made by the line running now, the latest first. [at] is how
   many of [kept] this run has made, and [replayed] says the last of them
   was made again by its test implementation, so what it gave isn't new. *)
type session = {
  real : string list;  (** the dependencies it has the real one of *)
  mutable kept : (int * call * Value.t) array;
  mutable at : int;
  mutable replayed : bool;
  mutable fresh : (call * Value.t) list;
}

(* Why a journal is open: to record a run, written to [out] as it goes;
   to replay one strictly ([Strict], `ren replay`); to stand in for the
   world in a test ([Test]), answering each task's inputs from its own
   calls to each dependency, in order, and keeping each task's outputs,
   to compare with its own at the end; or as a console session's
   ([Session]). [inputs] and [outputs] are the entries' numbers in
   [entries], by task and dependency, and by task. *)
type mode =
  | Record of out_channel
  | Strict
  | Test of {
      inputs : (string * string, int Queue.t) Hashtbl.t;
      outputs : (string, int array) Hashtbl.t;
      mutable made : call list;  (** the latest first *)
    }
  | Session of session

(* A journal. Recording one, [begun] is each task's call to the world
   that's running, by its path, and whether its first line is written
   yet: it is once the task waits in it. Replaying one, [entries] are its
   lines, [consumed] those the replay has come to, and [cursor] the first
   it hasn't; while it [follows] the recording, which `ren replay` always
   does, and a test does until it can't (its schedule prefix), the
   scheduler runs in the recorded order (sched.ml, [journal]), and
   [awaiting] are the tasks waiting in a call that waits for the poll
   that ends it, each with what wakes it. *)
type t = {
  file : string;  (** its file, as it was named, for a message *)
  mutable header : header;
  mode : mode;
  mutable calls : call list;  (** recorded: those made so far, the latest first *)
  mutable made : int;  (** how many calls have been made *)
  mutable lines : int;  (** recorded: how many numbered lines are written *)
  total : int;  (** replayed: how many calls the recording has *)
  ending : (ending * int) option;  (** replayed: how the recording ended *)
  entries : entry array;
  consumed : bool array;
  mutable cursor : int;
  mutable follows : bool;
  begun : (string, call * bool) Hashtbl.t;
  awaiting : (string, unit -> bool) Hashtbl.t;
}

(* A replay went differently from the recording: what to say, without
   where, which the interpreter adds (eval.ml); and, for a test's outputs,
   the two as a diff. [line] is the console session's line it's in. *)
type differs = {
  said : string;
  notes : string list;
  help : string option;
  diff : string list option;
  line : int option;
}

exception Differs of differs

let differs ?(notes = []) ?help ?diff ?line said =
  raise (Differs { said; notes; help; diff; line })

(* The recording ended in a panic at [at], `main.ren:3:9`, and the
   replay has made a call past its last one. If the call is where the
   panic was, the panic was inside it, and the replay panics there too;
   if not, the program went on past where the recording ended, and what
   [instead] gives is raised: the replay went differently, or a test
   went past a bug's end ([Went_past]). Only the interpreter knows where
   the call was made, so it decides (eval.ml), by [at_place]. *)
exception
  Recorded_panic of { at : string; msg : string; instead : (unit -> exn) }

(* A test of a recording that ended in an error or a panic, a bug's
   (handlers.md, "A journal as a test fixture"), went on past where it
   ended, having made the outputs it had made by then: the bug is fixed,
   and the test passes there. *)
exception Went_past

(* Where [loc] is, as a journal writes it, `main.ren:3:9`, with its
   file named [file]. *)
let place ?(file : string option) (loc : Loc.t) =
  let file = Option.value file ~default:loc.file in
  sprintf "%s:%d:%d" file loc.start.line loc.start.col

(* Whether [loc] is the place [at], which is written from the program's
   folder. *)
let at_place ~at (loc : Loc.t) =
  let here = place loc in
  here = at || String.ends_with ~suffix:("/" ^ at) here

(* A journal with no entries, open for [mode]. *)
let opened ~file ~program mode =
  {
    file;
    header = { program; deps = [] };
    mode;
    calls = [];
    made = 0;
    lines = 0;
    total = 0;
    ending = None;
    entries = [||];
    consumed = [||];
    cursor = 0;
    follows = false;
    begun = Hashtbl.create 4;
    awaiting = Hashtbl.create 4;
  }

(* A journal to record a run in, written to [out]: its header once it's
   known what `main` uses ([start]). *)
let recording ~file ~out ~program = opened ~file ~program (Record out)

let start j ~deps =
  j.header <- { j.header with deps };
  match j.mode with
  | Record out ->
      output_string out (header_text j.header ^ "\n");
      flush out
  | _ -> ()

(* The journal in [text], from the file [file], to replay strictly. *)
let load ~file text =
  let lines = String.split_on_char '\n' text in
  let header =
    match lines with
    | first :: _ -> parse_header ~file first
    | [] -> parse_header ~file ""
  in
  let entries =
    List.concat
      (List.mapi
         (fun i l ->
           let l = String.trim l in
           if i = 0 || l = "" || String.starts_with ~prefix:"#" l then []
           else
             match String.index_opt l ' ' with
             | Some sp when int_of_string_opt (String.sub l 0 sp) <> None ->
                 [
                   parse_entry ~file (i + 1)
                     (String.trim
                        (String.sub l (sp + 1) (String.length l - sp - 1)));
                 ]
             | _ -> [ parse_entry ~file (i + 1) "" ])
         lines)
  in
  (* each call that waits gets what it gave from its task's next line,
     which is what it gave, or that it saw a cancel, or nothing, if the
     run ended first *)
  let open_calls = Hashtbl.create 4 in
  List.iter
    (function
      | Call c ->
          if Hashtbl.mem open_calls c.task then
            raise
              (unreadable ~file c.line
                 (sprintf "%s makes this call while it waits in another" c.task)
                 ~help:"a task's call that waits ends before its next one" ());
          if c.waits then Hashtbl.replace open_calls c.task c
      | Gave (p, gave, line) -> (
          match Hashtbl.find_opt open_calls p with
          | Some c ->
              Hashtbl.remove open_calls p;
              c.gave <- gave;
              c.gave_line <- line
          | None ->
              raise
                (unreadable ~file line
                   (sprintf "%s isn't waiting in a call here" p)
                   ~help:
                     "a line `task → what it gave` ends the task's call that \
                      waits, whose first line ends `…`"
                   ()))
      | Cancel (p, _) -> Hashtbl.remove open_calls p
      | Poll _ | End _ -> ())
    entries;
  let ending =
    List.find_map (function End (e, l) -> Some (e, l) | _ -> None) entries
  in
  (* a recording that was stopped, or cut short, doesn't say how the run
     ended, so a replay couldn't say whether it ended the same way *)
  let last =
    List.fold_left max 1
      (List.mapi (fun i l -> if String.trim l = "" then 1 else i + 1) lines)
  in
  if ending = None then
    raise
      (unreadable ~file last
         (sprintf "%s doesn't say how the run ended" file)
         ~notes:
           [
             "its last line is how the run ended: `main exit 0`, `main error \
              ...` or `main panic ...`";
           ]
         ~help:"record the run again, to its end" ());
  let entries = Array.of_list entries in
  {
    (opened ~file ~program:header.program Strict) with
    header;
    total = Array.fold_left (fun n e -> match e with Call _ -> n + 1 | _ -> n) 0 entries;
    ending;
    entries;
    consumed = Array.make (Array.length entries) false;
    follows = true;
  }

(* The header of the journal in the file [path], if there's one there
   that starts as a journal does: what `replay(file)` implements is found
   from it when a test is checked (infer_handlers.ml, [replayed]). *)
let header_at path =
  match In_channel.with_open_bin path In_channel.input_line with
  | Some first -> (
      try Some (parse_header ~file:path first)
      with Diag.Error _ | Version_1 _ -> None)
  | None | (exception Sys_error _) -> None

(* The same journal, standing in for the world in a test: each call is an
   input or an output by what its operation's declared type gives,
   which [gives_nothing] says from the program's types. *)
let for_test (j : t) ~gives_nothing =
  let inputs = Hashtbl.create 8 and outputs = Hashtbl.create 4 in
  Array.iteri
    (fun i e ->
      match e with
      | Call c when gives_nothing c ->
          let outs = Option.value (Hashtbl.find_opt outputs c.task) ~default:[] in
          Hashtbl.replace outputs c.task (i :: outs)
      | Call c ->
          let q =
            match Hashtbl.find_opt inputs (c.task, c.dep) with
            | Some q -> q
            | None ->
                let q = Queue.create () in
                Hashtbl.replace inputs (c.task, c.dep) q;
                q
          in
          Queue.push i q
      | _ -> ())
    j.entries;
  let outputs =
    Hashtbl.fold
      (fun p is acc -> (p, Array.of_list (List.rev is)) :: acc)
      outputs []
  in
  {
    j with
    mode = Test { inputs; outputs = Hashtbl.of_seq (List.to_seq outputs); made = [] };
    consumed = Array.make (Array.length j.entries) false;
    (* a recording with no calls has no order to follow *)
    follows = (match j.entries with [||] | [| End _ |] -> false | _ -> true);
  }

(* A console session's journal, which has the real implementation of
   [real] (testing.md, "The console"). *)
let session ~real =
  opened ~file:"<console>" ~program:""
    (Session { real; kept = [||]; at = 0; replayed = false; fresh = [] })

(* ---- the journals open ----

   A Ren program holds a journal as a number, an opaque `Int`, which only
   the runtime makes: this is what each number is. *)

let registry : (int, t) Hashtbl.t = Hashtbl.create 4

let register j =
  let n = Hashtbl.length registry + 1 in
  Hashtbl.replace registry n j;
  n

let find n =
  match Hashtbl.find_opt registry n with
  | Some j -> j
  | None -> failwith (sprintf "bug: there's no journal %d" n)

(* ---- recording ---- *)

(* The call [dep.op] the task [task] makes with [args], as it's written. *)
let made ~task ~dep ~op ~args =
  { task; dep; op; args; gave = None; waits = false; line = 0; gave_line = 0 }

(* [call], `Fs.read`, as its dependency and operation. *)
let split_call call =
  match String.index_opt call '.' with
  | Some i ->
      (String.sub call 0 i, String.sub call (i + 1) (String.length call - i - 1))
  | None -> failwith ("bug: a journal's call `" ^ call ^ "` without a `.`")

(* A recording's next line, numbered. *)
let write_line j out text =
  j.lines <- j.lines + 1;
  Printf.fprintf out "%d %s\n" j.lines text;
  flush out

(* A console session: the kept line [c] is in, and that the run went
   differently there. *)
let session_differs (s : session) ~expected ~got =
  let line, _, _ = s.kept.(s.at) in
  differs ~line
    ~notes:[ "the session had: " ^ call_text expected; "this run made: " ^ got ]
    ~help:
      "the code changed since that line ran: type it again to run it on the \
       code as it is now"
    (sprintf "the session went differently at line %d" line)

(* `journal_kept`: in a console session, while it's making the calls of
   the lines it kept again, the next of them must be [c]. What it gave
   is given back for a dependency it has the real one of, which isn't
   asked again; a test one is asked again ([None]), which rebuilds its
   state. Otherwise, and in any other journal, [None]; recording, [c]
   has begun, and is written once it waits, or once it's given back
   ([gave]). *)
let kept j c =
  match j.mode with
  | Session s when s.at < Array.length s.kept ->
      let _, expected, v = s.kept.(s.at) in
      if not (same expected c) then
        session_differs s ~expected ~got:(call_text c);
      s.at <- s.at + 1;
      if List.mem c.dep s.real then Some v
      else (
        s.replayed <- true;
        None)
  | Record _ ->
      Hashtbl.replace j.begun c.task (c, false);
      None
  | _ -> None

(* `journal_gave`: [c] gave [v]. A recording writes it down: in one
   line, or, if its task waited in it, on the second of its two. A
   console session keeps it, past the lines it kept, and shows it as it
   happens: a line given to the test `Console`, as the real one would
   print it, [line], and any other call as a journal writes it, with what
   it gave. *)
let gave j c v ~line =
  match j.mode with
  | Record out ->
      (* one whose first line is written was counted then *)
      if Hashtbl.find_opt j.begun c.task |> Option.map snd <> Some true then begin
        j.made <- j.made + 1;
        j.calls <- c :: j.calls
      end;
      let text =
        match Hashtbl.find_opt j.begun c.task with
        | Some (_, true) -> (
            c.task ^ " →" ^ match c.gave with Some g -> " " ^ g | None -> "")
        | _ -> c.task ^ " " ^ entry_text c
      in
      Hashtbl.remove j.begun c.task;
      write_line j out text
  | Session s when s.replayed ->
      j.made <- j.made + 1;
      s.replayed <- false
  | Session s ->
      j.made <- j.made + 1;
      s.fresh <- (c, v) :: s.fresh;
      (match (c.dep, c.op) with
      | "Console", _ when List.mem "Console" s.real -> ()
      | "Console", "write" -> print_endline (line ())
      | "Console", _ ->
          flush stdout;
          prerr_endline (line ())
      | _ -> print_endline ("  " ^ entry_text c));
      flush stdout
  | Strict | Test _ -> j.made <- j.made + 1

(* ---- replaying ---- *)

(* The lines of [a] and [b] as a diff: each line both have, indented,
   and each only one has, after `-` for [a]'s and `+` for [b]'s, by
   their longest common subsequence; with two lines of what they share
   around each change, and what's further away left out. *)
let diff a b =
  let a = Array.of_list a and b = Array.of_list b in
  let n = Array.length a and m = Array.length b in
  (* lcs.(i).(j): the longest common subsequence of a[i..] and b[j..] *)
  let lcs = Array.make_matrix (n + 1) (m + 1) 0 in
  for i = n - 1 downto 0 do
    for j = m - 1 downto 0 do
      lcs.(i).(j) <-
        (if a.(i) = b.(j) then lcs.(i + 1).(j + 1) + 1
         else max lcs.(i + 1).(j) lcs.(i).(j + 1))
    done
  done;
  let rec walk i j =
    if i < n && j < m && a.(i) = b.(j) then (' ', a.(i)) :: walk (i + 1) (j + 1)
    else if i < n && (j = m || lcs.(i + 1).(j) >= lcs.(i).(j + 1)) then
      ('-', a.(i)) :: walk (i + 1) j
    else if j < m then ('+', b.(j)) :: walk i (j + 1)
    else []
  in
  let lines = Array.of_list (walk 0 0) in
  let changed i = i >= 0 && i < Array.length lines && fst lines.(i) <> ' ' in
  let near i = List.exists changed (List.init 5 (fun k -> i + k - 2)) in
  List.filter_map
    (fun i ->
      if near i then
        let c, l = lines.(i) in
        Some (if c = ' ' then "  " ^ l else String.make 1 c ^ " " ^ l)
      else None)
    (List.init (Array.length lines) Fun.id)

let recorded_again = "the code changed since this was recorded; record it again"

(* The entry the replay has come to, if one's left: the first not
   consumed, or how the run ended. *)
let next_entry j =
  if j.cursor < Array.length j.entries then Some j.entries.(j.cursor) else None

(* A test stops following the recording (its schedule prefix ends): the
   seeded tape takes over, and the tasks waiting for a poll to end their
   calls are woken, since none will come. *)
let unfollow j =
  if j.follows then begin
    j.follows <- false;
    let woken = Hashtbl.fold (fun _ wake acc -> wake :: acc) j.awaiting [] in
    Hashtbl.reset j.awaiting;
    List.iter (fun wake -> ignore (wake ())) woken
  end

(* The replay has come to the entry numbered [i]. A test that has come
   to the recording's end stops following it: the seeded tape takes
   over. *)
let consume j i =
  j.consumed.(i) <- true;
  while j.cursor < Array.length j.entries && j.consumed.(j.cursor) do
    j.cursor <- j.cursor + 1
  done;
  match (j.mode, next_entry j) with
  | Test _, (Some (End _) | None) -> unfollow j
  | _ -> ()

(* The first entry not consumed that's the task [p]'s, if one is. *)
let next_of j p =
  let rec go i =
    if i >= Array.length j.entries then None
    else if (not j.consumed.(i)) && entry_task j.entries.(i) = Some p then
      Some j.entries.(i)
    else go (i + 1)
  in
  go j.cursor

(* A strict replay went differently at the entry it's come to: at the
   call it's making, the [made + 1]th, or past them all. *)
let went_differently ?has ?(verb = "made") j ~made =
  let has =
    match has with
    | Some h -> h
    | None -> (
        match next_entry j with Some e -> entry_shown e | None -> "nothing more")
  in
  differs ~help:recorded_again
    ~notes:[ "the recording has: " ^ has; sprintf "this program %s: %s" verb made ]
    (sprintf "the replay went differently at call %d of %d" (j.made + 1) j.total)

(* A call past the recording's last: what [instead] gives, unless the
   recording ended in a panic, which this call may be where it was
   ([Recorded_panic]). *)
let past_the_end j instead =
  match j.ending with
  | Some (Panicked { at; msg }, _) ->
      raise (Recorded_panic { at; msg; instead })
  | _ -> raise (instead ())

(* Whether the recording ended in an error or a panic: a bug's. *)
let failing j =
  match j.ending with
  | Some ((Errored _ | Panicked _), _) -> true
  | Some ((Exited | Stopped _), _) | None -> false

(* The call the entry numbered [i] is. *)
let call_at j i =
  match j.entries.(i) with Call c -> c | _ -> failwith "bug: an entry that isn't a call"

(* In a test, the outputs made so far, if they aren't the recording's:
   all of them, or, for a bug's, those it made before it ended, which a
   fixed program can make more after. Each task's are compared with its
   own, so the order two tasks' outputs came in doesn't matter: they're
   shown task by task, in the order the recording's tasks first made
   one. *)
let outputs_differ j =
  match j.mode with
  | Test t ->
      (* each task's outputs, the recording's and the test's *)
      let recorded =
        Hashtbl.fold
          (fun p is acc -> (p, Array.to_list (Array.map (call_at j) is)) :: acc)
          t.outputs []
      in
      let made = List.rev t.made in
      (* the recording's tasks, by the line of their first output, then
         those only the test has, in the order they made one *)
      let first (p, cs) =
        match cs with (c : call) :: _ -> (c.line, p) | [] -> (max_int, p)
      in
      let tasks =
        List.fold_left
          (fun acc p -> if List.mem p acc then acc else acc @ [ p ])
          []
          (List.map snd (List.sort compare (List.map first recorded))
          @ List.map (fun (c : call) -> c.task) made)
      in
      let pairs =
        List.map
          (fun p ->
            let theirs = Option.value (List.assoc_opt p recorded) ~default:[] in
            let ours = List.filter (fun (c : call) -> c.task = p) made in
            let ours =
              if failing j then
                List.filteri (fun i _ -> i < List.length theirs) ours
              else ours
            in
            (List.map shown theirs, List.map shown ours))
          tasks
      in
      let recorded = List.concat_map fst pairs and made = List.concat_map snd pairs in
      if recorded = made then None
      else
        Some
          {
            said = "the outputs differ from the recording's";
            notes = [];
            help =
              Some
                "if the change is what you meant, record the run again, or \
                 edit the journal";
            diff = Some (diff recorded made);
            line = None;
          }
  | _ -> None

(* The task [task] made a call that waits, whose first line the replay
   has come to: while it follows the recording, it waits, by [wait], for
   the poll that ends it, and then its second line is the one the replay
   comes to. One that doesn't follow, a test past its schedule prefix,
   goes on at once. *)
let waited j task ~wait =
  if j.follows then begin
    (try wait (fun wake -> Hashtbl.replace j.awaiting task wake)
     with e ->
       Hashtbl.remove j.awaiting task;
       raise e);
    Hashtbl.remove j.awaiting task;
    if j.follows then
      match next_entry j with
      | Some (Gave (p, _, _)) when p = task -> consume j j.cursor
      | _ -> (
          match j.mode with
          | Strict -> went_differently j ~made:(task ^ " →, the end of its call")
          | _ -> unfollow j)
  end

(* `journal_answer`: what the recording says [c] gave, read by [read].
   In a strict replay (`ren replay`), [c] has to be the recording's next
   entry, its task's and the same call, and a `Console` line is printed,
   by [print], so the replay shows what the recording printed. In a test,
   an [output] is kept, to compare at the end, and gets what the
   recording's output at the same place among its task's got, if that's
   the same call, or else [nothing]; an input is answered from its task's
   calls to its dependency, in order, and has to be the next of them.
   While the replay follows the recording, a call that waited there waits
   for its poll here ([waited]); a test that makes a call that isn't the
   recording's next stops following it. *)
let answer j c ~output ~read ~print ~nothing ~wait =
  match j.mode with
  | Strict -> (
      match next_entry j with
      | Some (Call e) when e.task = c.task && same e c ->
          (* read first: an entry that can't be read isn't replayed; one
             that waits is read once it's been waited for, since it may
             have been cancelled *)
          let v = if e.waits then None else Some (read e) in
          consume j j.cursor;
          j.made <- j.made + 1;
          print e;
          if e.waits then waited j c.task ~wait;
          (match v with Some v -> v | None -> read e)
      | Some (End _) | None ->
          past_the_end j (fun () ->
              Differs
                {
                  said =
                    (if j.total = 0 then
                       "the program went on past the recording's end, which \
                        has no calls"
                     else
                       sprintf
                         "the program went on past the recording's end, after \
                          call %d"
                         j.total);
                  notes =
                    [
                      ("the recording has: "
                      ^
                      match j.ending with
                      | Some (e, _) -> ending_said e
                      | None -> "nothing more");
                      "this program made: " ^ shown c;
                    ];
                  help = Some recorded_again;
                  diff = None;
                  line = None;
                })
      | Some _ -> went_differently j ~made:(shown c))
  | Test t -> (
      (* the entry the replay has come to, if it follows the recording and
         it's this call *)
      let here =
        match next_entry j with
        | Some (Call e) when j.follows && e.task = c.task && same e c -> Some j.cursor
        | _ ->
            unfollow j;
            None
      in
      let came i =
        if here = Some i then consume j i else unfollow j
      in
      if output then (
        let outs = Option.value (Hashtbl.find_opt t.outputs c.task) ~default:[||] in
        let at = List.length (List.filter (fun (m : call) -> m.task = c.task) t.made) in
        t.made <- c :: t.made;
        j.made <- j.made + 1;
        if at < Array.length outs && same (call_at j outs.(at)) c then (
          let e = call_at j outs.(at) in
          came outs.(at);
          if e.waits then waited j c.task ~wait;
          read e)
        else (
          unfollow j;
          nothing))
      else
        let help =
          "the code changed since this was recorded: record it again, or edit \
           the journal"
        in
        let from = if c.task = "main" then "" else " from " ^ c.task in
        match Option.bind (Hashtbl.find_opt t.inputs (c.task, c.dep)) Queue.take_opt with
        | Some i when same (call_at j i) c ->
            let e = call_at j i in
            came i;
            j.made <- j.made + 1;
            if e.waits then waited j c.task ~wait;
            read e
        | Some i ->
            unfollow j;
            differs ~help
              ~notes:
                [
                  "the recording has: " ^ shown (call_at j i);
                  "this program made: " ^ shown c;
                ]
              (sprintf "this isn't the call to `%s` the recording has next%s" c.dep from)
        | None ->
            unfollow j;
            (* past a bug's end, the bug is fixed if the outputs to there
               are the recording's *)
            past_the_end j (fun () ->
                if failing j then
                  match outputs_differ j with
                  | Some d -> Differs d
                  | None -> Went_past
                else
                  Differs
                    {
                      said =
                        (if Hashtbl.mem t.inputs (c.task, c.dep) then
                           sprintf "the recording has no more calls to `%s`%s" c.dep from
                         else sprintf "the recording has no calls to `%s`%s" c.dep from);
                      notes = [ "this program made: " ^ shown c ];
                      help = Some help;
                      diff = None;
                      line = None;
                    }))
  | Record _ | Session _ ->
      failwith "bug: an answer from a journal that isn't a recording's"

(* ---- the scheduler's part (sched.ml, [journal]) ---- *)

(* What the scheduler is told of, and asks, the journal [j]: recording,
   it writes each poll, each cancel a task sees, each second failure's
   warning as a comment, and a call's first line once its task waits in
   it; replaying, it says the order while it follows the recording.
   [path_of] is a task's path as the journal writes it. *)
let watcher j ~path_of : Sched.journal =
  let ignore_ _ = () in
  match j.mode with
  | Record out ->
      {
        path_of;
        follows = (fun () -> false);
        waits =
          (fun t ->
            let p = path_of t in
            match Hashtbl.find_opt j.begun p with
            | Some (c, false) ->
                Hashtbl.replace j.begun p (c, true);
                j.made <- j.made + 1;
                j.calls <- c :: j.calls;
                write_line j out (p ^ " " ^ call_text c ^ " " ^ waiting)
            | _ -> ());
        polled =
          (fun ts -> write_line j out ("poll " ^ String.concat " " (List.map path_of ts)));
        poll = (fun () -> None);
        cancel_here = (fun _ -> false);
        saw_cancel =
          (fun t ->
            let p = path_of t in
            Hashtbl.remove j.begun p;
            write_line j out (p ^ " cancelled"));
        astray = ignore_;
        note =
          (fun line ->
            Printf.fprintf out "# %s\n" (String.trim line);
            flush out);
      }
  | _ ->
      let strict = j.mode = Strict in
      (* the replay went differently: a strict one says so, and a test
         stops following *)
      let astray ?has ?verb made =
        if strict then went_differently ?has ?verb j ~made else unfollow j
      in
      {
        path_of;
        follows = (fun () -> j.follows);
        waits = ignore_;
        polled = ignore_;
        poll =
          (fun () ->
            match next_entry j with
            | Some (Poll (ps, _) as poll) -> (
                (* each task it woke is waiting in a call it ends, or to
                   see a cancel *)
                let woken p =
                  match next_of j p with
                  | Some (Cancel _) -> Some (p, true)
                  | _ when Hashtbl.mem j.awaiting p -> Some (p, false)
                  | _ -> None
                in
                match List.find_opt (fun p -> woken p = None) ps with
                | Some p ->
                    astray ~has:(entry_shown poll) ~verb:"has"
                      (p ^ " waiting for nothing a poll ends");
                    None
                | None ->
                    consume j j.cursor;
                    Some (List.filter_map woken ps))
            | Some (End _) | None -> None
            | Some _ ->
                astray ~verb:"has" "every task waiting";
                None);
        cancel_here =
          (fun t ->
            match next_entry j with
            | Some (Cancel (p, _)) -> p = path_of t
            | _ -> false);
        saw_cancel =
          (fun t ->
            let p = path_of t in
            Hashtbl.remove j.awaiting p;
            if j.follows then
              match next_entry j with
              | Some (Cancel (q, _)) when q = p -> consume j j.cursor
              | _ -> astray ~verb:"has" (p ^ " seeing a cancel"));
        astray = (fun p -> astray ~verb:"has" (p ^ " waiting for nothing a poll ends"));
        note = ignore_;
      }

(* ---- a test's outputs ---- *)

(* `journal_outputs`, when a test's `with` ends: the outputs it made
   have to be the recording's ([outputs_differ]), or it fails with the
   two as a diff. *)
let outputs j =
  match outputs_differ j with Some d -> raise (Differs d) | None -> ()

(* ---- the end ---- *)

(* A recording, once the run has ended [e]: its last line. *)
let finish_recording j e =
  match j.mode with
  | Record out -> write_line j out ("main " ^ ending_text e)
  | _ -> ()

(* The line of a strict replay's next entry, or of its end: where a
   message about the replay's end is said. *)
let next_line j =
  match (next_entry j, j.ending) with
  | Some e, _ -> entry_line e
  | None, Some (_, l) -> l
  | None, None -> 1

(* Whether a strict replay has come to every entry but how the run
   ended. *)
let replayed_all j =
  match next_entry j with Some (End _) | None -> true | Some _ -> false

(* A strict replay, once the program has ended [e]: the recording ended
   the same way, after the same calls. *)
let finish_replay j e =
  match (next_entry j, j.ending) with
  | Some (End _), Some (recorded, _) when recorded <> e ->
      differs ~help:recorded_again
        ~notes:[ "the recording has: " ^ ending_said recorded; ended_instead e ]
        (sprintf "the replay went differently after call %d of %d" j.made
           j.total)
  | (Some (End _) | None), _ -> ()
  | Some expected, _ ->
      differs ~help:recorded_again
        ~notes:[ "the recording has: " ^ entry_shown expected; ended_instead e ]
        (sprintf "the replay went differently after call %d of %d" j.made
           j.total)

(* How many calls a recording has made to each dependency of its
   header, in its order. *)
let counts j =
  List.map
    (fun d -> (d, List.length (List.filter (fun c -> c.dep = d) j.calls)))
    j.header.deps

(* ---- a console session ---- *)

(* The session's run is starting again, from its first kept line. *)
let rerun j =
  match j.mode with
  | Session s ->
      s.at <- 0;
      s.replayed <- false;
      s.fresh <- []
  | _ -> ()

(* The run has ended: it made every call of the lines kept, or the line
   it stopped making them in went differently. *)
let ran_all j =
  match j.mode with
  | Session s when s.at < Array.length s.kept ->
      let _, expected, _ = s.kept.(s.at) in
      session_differs s ~expected ~got:"nothing more"
  | _ -> ()

(* The line that ran last, the session's [line]th, is kept: what its
   calls gave is given back from now on. *)
let keep j ~line =
  match j.mode with
  | Session s ->
      s.kept <-
        Array.append s.kept
          (Array.of_list (List.rev_map (fun (c, v) -> (line, c, v)) s.fresh));
      s.fresh <- []
  | _ -> ()

(* Lines [line] and after are dropped: so are their calls. *)
let drop_from j ~line =
  match j.mode with
  | Session s ->
      s.kept <-
        Array.of_list
          (List.filter (fun (l, _, _) -> l < line) (Array.to_list s.kept))
  | _ -> ()
