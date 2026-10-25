(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet, and is
   listed in the tables below: each entry says everything every pass needs
   to know about it, so adding a built-in means adding one entry. *)

let source = {|
pub type Option<T> =
  | Some(value: T)
  | None
|}

(* ---- built-in types ---- *)

type builtin_type = { name : string; arity : int  (** type arguments *) }

let types =
  [
    { name = "Int"; arity = 0 };
    { name = "Bool"; arity = 0 };
    { name = "Unit"; arity = 0 };
    { name = "Array"; arity = 1 };
  ]

(* ---- built-in functions ---- *)

type builtin_fn = {
  name : string;
  scheme : Ty.scheme;
      (** its type scheme. Each parameter's mode ([inout] or not) is part of the
          type. *)
  eval : Value.t list -> Value.t * Value.t list;
      (** run it: the result, and the final value of every parameter, which the
          interpreter writes back for the arguments passed with `&` *)
}

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug name = failwith ("bug: `" ^ name ^ "` was called with the wrong values")

(* [Ty.Var n] is the scheme's [n]th type variable and [Some n] in a row its
   [n]th row variable, numbered by first appearance (ty.ml). *)
let scheme ty : Ty.scheme = { ty; names = [] }
let open_row n : Ty.row = { labels = []; tail = Some n }

let fns =
  let open Ty in
  [
    {
      (* fn<T>(T) uses Io *)
      name = "print";
      scheme =
        scheme
          (Fun
             ( [ read (Var 0) ],
               unit,
               open_row 0,
               { labels = [ "Io" ]; tail = Some 1 } ));
      eval =
        (fun args ->
          List.iter (fun v -> print_endline (Value.show v)) args;
          (Value.VUnit, args));
    };
    {
      (* fn<T>(Array<T>) -> Int *)
      name = "len";
      scheme =
        scheme (Fun ([ read (array (Var 0)) ], int, open_row 0, open_row 1));
      eval =
        (function
        | [ Value.VArray xs ] as args -> (Value.VInt (Array.length xs), args)
        | _ -> bug "len");
    };
    {
      (* fn<T>(inout Array<T>, T) *)
      name = "push";
      scheme =
        scheme
          (Fun
             ( [ { mode = Inout; ty = array (Var 0) }; read (Var 0) ],
               unit,
               open_row 0,
               open_row 1 ));
      eval =
        (function
        | [ Value.VArray xs; x ] ->
            (Value.VUnit, [ Value.VArray (Array.append xs [| x |]); x ])
        | _ -> bug "push");
    };
  ]

let find_fn name = List.find_opt (fun (f : builtin_fn) -> f.name = name) fns

(* The intrinsic half of the prelude's interface. *)
let intrinsics : Iface.t =
  {
    home = Path.prelude_home;
    types =
      List.map
        (fun (t : builtin_type) : Iface.type_decl ->
          {
            path = Path.prelude t.name;
            params = List.init t.arity (fun i -> "T" ^ string_of_int i);
            body = Builtin;
            loc = None;
          })
        types;
    values = List.map (fun f -> { Iface.vname = f.name; scheme = f.scheme }) fns;
  }
