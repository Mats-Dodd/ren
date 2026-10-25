(* The prelude: what every Ren program can use without declaring it.

   It's a module like any other, whose interface every program is checked
   against (driver.ml). It comes in two halves. [source] is written in Ren
   itself, and checked like any module. Everything else is built into the
   compiler (intrinsic), because it can't be written in Ren yet, and is
   listed in the tables below: each entry says everything every pass needs
   to know about it, so adding a built-in means adding one entry. *)

let source =
  {|
pub type Option<T> =
  | Some(value: T)
  | None
  ops =
    pub fn is_some(self) -> Bool =
      match self
        Some(_) => true
        None => false
    pub fn unwrap_or(self, d: T) -> T =
      match self
        Some(x) => x
        None => d
|}

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
  ]

(* ---- built-in types ----

   A built-in type's methods are built in too, and listed with it: each is
   called with a dot, its receiver its first parameter, `self`. In a
   method's scheme the type's parameters are its first variables, as in
   any `ops` item's (iface.ml). *)

type builtin_type = {
  name : string;
  arity : int;  (** type arguments *)
  methods : builtin_fn list;
}

let array_methods =
  let open Ty in
  [
    {
      (* fn<T>(self: Array<T>) -> Int *)
      name = "len";
      scheme =
        scheme (Fun ([ read (array (Var 0)) ], int, open_row 0, open_row 1));
      eval =
        (function
        | [ Value.VArray xs ] as args -> (Value.VInt (Array.length xs), args)
        | _ -> bug "len");
    };
    {
      (* fn<T>(inout self: Array<T>, x: T) *)
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

let types =
  [
    { name = "Int"; arity = 0; methods = [] };
    { name = "Bool"; arity = 0; methods = [] };
    { name = "Unit"; arity = 0; methods = [] };
    { name = "Array"; arity = 1; methods = array_methods };
  ]

(* ---- built-in dependencies ----

   What a function can name in its `uses`. For now these are the only
   dependencies there are; dependency types of a program's own come in
   stage 7. *)

let dependencies =
  [ "Io"; "Net"; "Alloc"; "Async"; "Unsafe"; "Clock"; "Random" ]

(* A built-in function, by the name its path has: [print], or a method
   after its type, [Array.push]. *)
let find_fn name =
  match String.index_opt name '.' with
  | None -> List.find_opt (fun (f : builtin_fn) -> f.name = name) fns
  | Some i ->
      let ty = String.sub name 0 i in
      let m = String.sub name (i + 1) (String.length name - i - 1) in
      Option.bind
        (List.find_opt (fun (t : builtin_type) -> t.name = ty) types)
        (fun t -> List.find_opt (fun (f : builtin_fn) -> f.name = m) t.methods)

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
            ops =
              List.map
                (fun (f : builtin_fn) : Iface.op ->
                  {
                    oname = f.name;
                    opub = true;
                    okind = Method;
                    oscheme = f.scheme;
                  })
                t.methods;
            loc = None;
          })
        types;
    values =
      List.map
        (fun (f : builtin_fn) -> { Iface.vname = f.name; scheme = f.scheme })
        fns;
  }
