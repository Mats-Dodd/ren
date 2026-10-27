(* `ren run --trace` (handlers.md, "Tracing"): the tree of calls the
   program made to dependencies, the built-in ones and its own, each with
   its arguments, how long it took and what it gave, printed once the run
   ends:

     main                                   41ms
     ├─ Fs.read("justfile")                0.2ms  → 61 bytes
     ├─ Os.args()                          0.0ms  → ["build"]
     └─ Proc.run("sh", ["-c", "fmt a.c"])   18ms  → 0

   A call is under the call that made it: what a handler's operation
   calls is under that operation. The interpreter adds each call as it's
   made (eval.ml, [traced]); this keeps the tree, and draws it. *)

let sprintf = Printf.sprintf

(* A call: what was called, with its arguments, when, how long it took,
   what it gave, and the calls it made, the latest first. *)
type node = {
  call : string;
  started : float;
  mutable took : float;
  mutable gave : string;
  mutable under : node list;
}

(* The tree, from `main`, and the calls still running, the innermost
   first. *)
type t = { root : node; mutable running : node list }

let now = Unix.gettimeofday
let node call = { call; started = now (); took = 0.; gave = ""; under = [] }

let create () =
  let root = node "main" in
  { root; running = [ root ] }

(* A call [call] is made, under the one running. *)
let enter t call =
  let n = node call in
  (match t.running with p :: _ -> p.under <- n :: p.under | [] -> ());
  t.running <- n :: t.running;
  n

(* [n] has ended, giving [gave]: nothing for `()`. *)
let leave t n ~gave =
  n.took <- now () -. n.started;
  n.gave <- gave;
  let rec pop = function
    | m :: rest when m == n -> rest
    | _ :: rest -> pop rest
    | [] -> []
  in
  t.running <- pop t.running

(* How many characters [s] is: its bytes but those that continue one,
   10xxxxxx, as a terminal shows it. *)
let width s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xc0 <> 0x80 then incr n) s;
  !n

(* [s], cut to 40 characters with `...` if it's longer, so a line stays
   readable: a trace is for reading, and the journal has it all. *)
let short s =
  if width s <= 40 then s
  else
    (* the byte where the 38th character starts *)
    let rec at i chars =
      if i >= String.length s then i
      else if Char.code s.[i] land 0xc0 <> 0x80 then
        if chars = 37 then i else at (i + 1) (chars + 1)
      else at (i + 1) chars
    in
    String.sub s 0 (at 0 0) ^ "..."

(* A time, as a person reads it. *)
let shown_time secs =
  let ms = secs *. 1000. in
  if ms < 10. then sprintf "%.1fms" ms
  else if ms < 1000. then sprintf "%.0fms" ms
  else sprintf "%.1fs" secs

(* The tree, drawn, the whole run having taken what [root] did; with
   [timings] off, without the times, as `ren test`'s REN_NO_TIMINGS
   has it. *)
let render ~timings t =
  t.root.took <- now () -. t.root.started;
  (* each line: what's before the call, the call, its time, what it
     gave *)
  let rec lines prefix child_prefix (n : node) =
    (prefix ^ n.call, n)
    :: List.concat
         (List.mapi
            (fun i m ->
              let last = i = List.length n.under - 1 in
              lines
                (child_prefix ^ if last then "└─ " else "├─ ")
                (child_prefix ^ if last then "   " else "│  ")
                m)
            (List.rev n.under))
  in
  let all = lines "" "" t.root in
  let wide = List.fold_left (fun w (s, _) -> max w (width s)) 0 all in
  let b = Buffer.create 256 in
  List.iter
    (fun (s, n) ->
      Buffer.add_string b s;
      let pad = String.make (wide - width s + 2) ' ' in
      let time = if timings then sprintf "%6s" (shown_time n.took) else "" in
      let gave = if n.gave = "" then "" else "  → " ^ n.gave in
      let line =
        if timings then pad ^ time ^ gave
        else if gave = "" then ""
        else pad ^ String.trim gave
      in
      Buffer.add_string b line;
      Buffer.add_char b '\n')
    all;
  Buffer.contents b
