(* The prelude: what every Ren program can use without declaring it.

   It comes in two halves. [source] is written in Ren itself: the driver
   parses it and puts it in front of the user's code. Everything else is
   built into the compiler, because it can't be written in Ren yet, and is
   listed in the tables below: each entry says everything every pass needs
   to know about it, so adding a built-in means adding one entry. *)

let source = {|
type Option<T> =
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

let find_type name =
  List.find_opt (fun (t : builtin_type) -> t.name = name) types

let is_type name = find_type name <> None

(* ---- built-in functions ---- *)

type builtin_fn = {
  name : string;
  scheme : Types.state -> Types.ty;
      (** its type scheme, built from the compilation's inference state so its
          generic variables are that compilation's own. Each parameter's mode
          ([inout] or not) is part of the type. *)
  eval : Value.t list -> Value.t * Value.t list;
      (** run it: the result, and the final value of every parameter, which the
          interpreter writes back for the arguments passed with `&` *)
}

(* The type checker rules these out, so reaching one is a compiler bug. *)
let bug name = failwith ("bug: `" ^ name ^ "` was called with the wrong values")

let fns =
  let open Types in
  [
    {
      (* fn<T>(T) uses Io *)
      name = "print";
      scheme =
        (fun st ->
          TFun
            ( [ read (generic_var st) ],
              unit,
              generic_row st,
              RExtend ("Io", generic_row st) ));
      eval =
        (fun args ->
          List.iter (fun v -> print_endline (Value.show v)) args;
          (Value.VUnit, args));
    };
    {
      (* fn<T>(Array<T>) -> Int *)
      name = "len";
      scheme =
        (fun st ->
          TFun
            ( [ read (array (generic_var st)) ],
              int,
              generic_row st,
              generic_row st ));
      eval =
        (function
        | [ Value.VArray xs ] as args -> (Value.VInt (Array.length xs), args)
        | _ -> bug "len");
    };
    {
      (* fn<T>(inout Array<T>, T) *)
      name = "push";
      scheme =
        (fun st ->
          let t = generic_var st in
          TFun
            ( [ { mode = Inout; ty = array t }; read t ],
              unit,
              generic_row st,
              generic_row st ));
      eval =
        (function
        | [ Value.VArray xs; x ] ->
            (Value.VUnit, [ Value.VArray (Array.append xs [| x |]); x ])
        | _ -> bug "push");
    };
  ]

let find_fn name = List.find_opt (fun (f : builtin_fn) -> f.name = name) fns
let is_fn name = find_fn name <> None
