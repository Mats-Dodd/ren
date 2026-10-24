(* Source locations. Every token and AST node carries one so that errors can
   point at the exact code that caused them. *)

type pos = { line : int; col : int } (* both 1-based *)
type t = { file : string; start : pos; stop : pos }

(* The location covering everything from [a] to [b]. *)
let span a b = { a with stop = b.stop }

let point ~file line col =
  let p = { line; col } in
  { file; start = p; stop = p }
