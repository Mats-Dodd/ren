(* Types every Ren program can use without declaring them, written in Ren
   itself. The driver parses this and puts it in front of the user's code. *)

let source = {|
type Option<T> =
  | Some(value: T)
  | None
|}
