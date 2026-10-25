(* Core: the small, explicitly typed language a checked program is lowered
   to (lower.ml), and that the interpreter runs (eval.ml).

   The surface tree has many ways to say "change something": `x.f += 1`,
   `xs[i] = v`, `f(&x.f)`, `for p in &ps`. Core has one: [Assign] to a
   local variable. Everything else is spelled out with plain operations, a
   record update or an array update that builds a new value, and an
   assignment of it back to the variable. So nothing after lowering needs
   to know what a place is.

   Every node says its type, in canonical form (ty.ml), and keeps the
   location of the code it came from, so a panic can point at it. A local
   is known by its binder's id (numbered per top-level function, as in
   ast.ml; lowering numbers its temporaries after the function's own
   locals). Constructors, record types and fields say which type they
   belong to, which inference found. core_lint.ml checks that all of this
   fits together.

   Failing is explicit too (errors.md). [Fail] stops with an error, which
   is a value of its own, a [Tag]. A call whose callee's type says it can
   fail passes on whatever the callee fails with, and nothing else does.
   [Handle] is the one place an error is caught, and [Finally] runs
   something on the way out whether the code before it failed or not. So a
   backend that compiles to C can make each function that can fail return
   its error, and check for one after each call that can fail.

   Dependencies are explicit too (deps.md, "How it runs"). Each dependency
   a function uses is a hidden parameter of its, its evidence: the
   implementation installed by whoever called it. A call passes the
   caller's evidence on, a [Dep_call] calls an operation of the evidence
   it names, and [With] installs an implementation around its body. A
   lambda's evidence is its own, passed where it's called, so it never
   keeps the implementation that was installed where it was made. Nothing
   is looked up by name. Lowering leaves the evidence out; evidence.ml
   threads it through the whole program, and until then an operation is
   a [Dep_op]. *)

type mode = Ty.mode = Read | Inout

(* A local variable. Every use of it carries the same record. *)
type var = { id : int; name : string; ty : Ty.ty }

(* Operations built into the language. Each one's operands are listed in
   the order they're evaluated. *)
type prim =
  | Neg
  | Not  (** on a [Bool] *)
  | Binop of Ast.binop
      (** [==] and [!=] on any two values of the same type, the others on
          [Int]s. Never [&&] or [||]: lowering makes those [If]s, so their right
          side is evaluated only when it's needed *)
  | Length  (** an array's length *)
  | Get_index  (** [xs[i]]: panics if [i] is out of bounds *)
  | Set_index  (** [xs] with element [i] replaced: a new array *)

type param = { mode : mode; var : var }

type expr = { kind : kind; ty : Ty.ty; loc : Loc.t }

and kind =
  | Int of int
  | Bool of bool
  | Str of string
  | Unit
  | Local of var
  | Global of Path.t
      (** a top-level function, or a member's, [Stack.push]; [ty] is the type
          it's used at here, an instance of its scheme. A method call,
          [s.push(1)], is a call of its function, with [s] first. *)
  | Global_value of Path.t
      (** an associated value, [Stack.empty], which the program makes once when
          it starts: its function of no parameters, called then. [ty] is an
          instance of its type. *)
  | Intrinsic of string
      (** a function built into the compiler: [print], or a method, [Array.push]
      *)
  | Dep_op of Path.t * string
      (** an operation of the dependency at the path, [Clock.now], before
          evidence.ml has threaded the evidence: then it's a [Dep_call] *)
  | Dep_call of {
      dep : Path.t;
      op : string;
      fty : Ty.ty;  (** the operation's type, at this call *)
      impl : var;  (** the evidence: the implementation it calls *)
      args : expr list;
    }
      (** [Clock.now()]: a call of an operation of the implementation [impl]
          holds. Kept apart from other calls, so what was called, with what, can
          be recorded (the journal, stage 9). Never with `&` *)
  | With of { ev : var; impl : expr; body : expr }
      (** install [impl], an implementation of the dependency that's [ev]'s
          type, as the evidence [ev] for [body]. The runtime's installs around
          `main` are these *)
  | Prim of prim * expr list
  | Let of var * expr * expr  (** [let x = value in body] *)
  | Assign of var * expr  (** the only way anything changes *)
  | If of expr * expr * expr
  | Match of expr * arm list
  | While of expr * expr  (** the condition, then the body *)
  | Seq of expr * expr  (** the first's value is dropped *)
  | Call of expr * arg list * var list
      (** the callee, its arguments, and the evidence it's passed: one for each
          dependency it uses, in the order of its row's labels *)
  | Lambda of {
      params : param list;
      evidence : var list;
      captures : var list;
      body : expr;
    }
      (** [captures] are the locals from outside the lambda its body uses, in
          order of id; their values are copied when the lambda is made. Its
          [evidence] is passed where it's called, never captured *)
  | Con of Path.t * string * expr list
      (** a constructor: its type, its name, its fields in order *)
  | Record of Path.t * (string * expr) list  (** in the order written *)
  | Field of expr * Path.t * string  (** [r.f], and the record type of [r] *)
  | Update of expr * string * expr
      (** the record with one field replaced: a new record *)
  | Array of expr list
  | Tag of string * expr list
      (** an error, [Short(id, 5)]: its tag and its payload in order. Its type
          is [Errors] of the one tag. An error is a value only in Core, which
          raises one with [Fail] and catches one with [Handle] *)
  | Fail of expr  (** stop with this error; of any type, since it never ends *)
  | Handle of {
      body : expr;
      value : var;
      on_value : expr;
      error : var;
      on_error : expr;
    }
      (** run [body]. If it ends, its value is [value], and the [Handle] is
          [on_value]; if it fails, its error is [error] (of an [Errors] type),
          and the [Handle] is [on_error]. Neither of those is handled here: what
          they fail with goes on *)
  | Finally of expr * expr
      (** [body], then [after], a [Unit], which runs whether [body] fails or
          not, and doesn't change what [body] did: its value, or its error,
          which goes on once [after] has run. Lowering writes a place passed
          with `&` back to it in [after], so a call that fails still changes it
      *)

(* A call's argument. An [inout] argument is always a plain local: the call
   reads it, and writes the parameter's final value back to it. *)
and arg = Value of expr | Ref of var
and arm = { pat : pattern; guard : expr option; body : expr }
and pattern = { pkind : pattern_kind; pty : Ty.ty; ploc : Loc.t }

and pattern_kind =
  | PWild
  | PVar of var
  | PInt of int
  | PBool of bool
  | PCon of Path.t * string * pattern list
  | PTag of string * pattern list  (** an error with this tag, destructured *)
  | POr of pattern list
      (** any of these; each binds the same variables (the same [var]s) *)

type fn_def = {
  path : Path.t;
  params : param list;
  evidence : var list;
      (** its hidden parameters: an implementation of each dependency its type
          uses, in the order of its row's labels *)
  scheme : Ty.scheme;  (** its type, whose variables its nodes' types share *)
  body : expr;
  loc : Loc.t;  (** its name, where it's declared *)
}

(* A module, lowered. [types] are the types it declares. *)
type program = {
  home : string;
  types : Iface.type_decl list;
  fns : fn_def list;
  values : Path.t list;
      (** its associated values, in the order they're made, each after every
          value it uses; each is one of [fns], of no parameters *)
}

(* ---- building ---- *)

let mk kind ty loc = { kind; ty; loc }
let unit loc = mk Unit Ty.unit loc
let local (v : var) loc = mk (Local v) v.ty loc

(* The type of an array's elements, or of what's in an [Option]. *)
let elem_ty (t : Ty.ty) =
  match t with
  | Con (_, [ elem ]) -> elem
  | _ -> invalid_arg "Core.elem_ty: not an array"

(* Whether calling a function of type [t] can fail: whether its errors
   row has a tag, or may have more than it says. *)
let fails (t : Ty.ty) =
  match t with
  | Fun (_, _, errs, _) -> errs.labels <> [] || errs.tail <> None
  | _ -> false

(* The expressions directly inside [e], in the order they're evaluated (a
   lambda's body, which isn't evaluated where the lambda is made, comes
   last). *)
let children (e : expr) =
  match e.kind with
  | Int _ | Bool _ | Str _ | Unit | Local _ | Global _ | Global_value _
  | Intrinsic _ | Dep_op _ ->
      []
  | Prim (_, es)
  | Array es
  | Con (_, _, es)
  | Tag (_, es)
  | Dep_call { args = es; _ } ->
      es
  | With { impl; body; _ } -> [ impl; body ]
  | Let (_, a, b) | While (a, b) | Seq (a, b) | Update (a, _, b) | Finally (a, b)
    ->
      [ a; b ]
  | Assign (_, a) | Field (a, _, _) | Fail a | Lambda { body = a; _ } -> [ a ]
  | If (c, t, f) -> [ c; t; f ]
  | Match (s, arms) ->
      s :: List.concat_map (fun a -> Option.to_list a.guard @ [ a.body ]) arms
  | Call (f, args, _) ->
      f :: List.filter_map (function Value a -> Some a | Ref _ -> None) args
  | Record (_, fs) -> List.map snd fs
  | Handle { body; on_value; on_error; _ } -> [ body; on_value; on_error ]

(* Whether running [e] can fail: whether it can reach a [Fail] or a call
   that can fail, that no [Handle] in it catches. A lambda's body runs only
   when it's called, so only the call can fail. *)
let rec can_fail (e : expr) =
  match e.kind with
  | Fail _ -> true
  | Call (f, _, _) when fails f.ty -> true
  | Dep_call { fty; _ } when fails fty -> true
  | Handle { on_value; on_error; _ } -> can_fail on_value || can_fail on_error
  | Lambda _ -> false
  | _ -> List.exists can_fail (children e)

(* ---- printing, as s-expressions, for tests ----

   A list that fits on its line is printed on it. One that doesn't starts
   its line with as many of its items as fit, but never the last one; the
   rest go on lines of their own, indented. *)

type sexp = Atom of string | List of sexp list

let rec flat = function
  | Atom a -> a
  | List xs -> "(" ^ String.concat " " (List.map flat xs) ^ ")"

let width = 78

let rec render col = function
  | List (head :: rest) as x when col + String.length (flat x) > width ->
      let rec first line = function
        | x :: (_ :: _ as more)
          when String.length line + String.length (flat x) + col < width ->
            first (line ^ " " ^ flat x) more
        | items -> (line, items)
      in
      let line, rest = first ("(" ^ flat head) rest in
      let pad = "\n" ^ String.make (col + 2) ' ' in
      line
      ^ String.concat "" (List.map (fun x -> pad ^ render (col + 2) x) rest)
      ^ ")"
  | x -> flat x

let show_var (v : var) = v.name ^ "/" ^ string_of_int v.id

let show_prim = function
  | Neg -> "neg"
  | Not -> "not"
  | Binop op -> Ast.binop_to_string op
  | Length -> "length"
  | Get_index -> "get"
  | Set_index -> "set"

let atom a = Atom a
let var v = Atom (show_var v)

let rec pattern_sexp p =
  match p.pkind with
  | PWild -> Atom "_"
  | PVar v -> var v
  | PInt n -> Atom (string_of_int n)
  | PBool b -> Atom (string_of_bool b)
  | PCon (_, c, []) -> Atom c
  | PCon (_, c, ps) -> List (Atom c :: List.map pattern_sexp ps)
  | PTag (t, []) -> List [ atom "tag"; Atom t ]
  | PTag (t, ps) -> List (atom "tag" :: Atom t :: List.map pattern_sexp ps)
  | POr ps -> List (atom "or" :: List.map pattern_sexp ps)

let rec sexp e =
  match e.kind with
  | Int n -> Atom (string_of_int n)
  | Bool b -> Atom (string_of_bool b)
  | Str s -> Atom (Ast.show_str s)
  | Unit -> Atom "()"
  | Local v -> var v
  | Global p | Global_value p -> Atom p.name
  | Intrinsic x -> Atom x
  | Dep_op (p, op) -> Atom (Path.full p ^ "." ^ op)
  | Dep_call { dep; op; impl; args; _ } ->
      List
        (atom "dep-call"
        :: Atom (Path.full dep ^ "." ^ op)
        :: var impl :: List.map sexp args)
  | With { ev; impl; body } ->
      List [ atom "with"; var ev; sexp impl; sexp body ]
  | Prim (op, args) -> List (Atom (show_prim op) :: List.map sexp args)
  | Let (v, value, body) -> List [ atom "let"; var v; sexp value; sexp body ]
  | Assign (v, value) -> List [ atom "="; var v; sexp value ]
  | If (c, t, f) -> List [ atom "if"; sexp c; sexp t; sexp f ]
  | Match (s, arms) -> List (atom "match" :: sexp s :: List.map arm_sexp arms)
  | While (c, body) -> List [ atom "while"; sexp c; sexp body ]
  | Seq (a, b) -> List [ atom "seq"; sexp a; sexp b ]
  | Call (f, args, evidence) ->
      let arg = function
        | Value a -> sexp a
        | Ref v -> Atom ("&" ^ show_var v)
      in
      List ((atom "call" :: sexp f :: List.map arg args) @ uses evidence)
  | Lambda { params; evidence; captures; body } ->
      let param p =
        match p.mode with
        | Inout -> Atom ("inout " ^ show_var p.var)
        | Read -> var p.var
      in
      List
        ([
           atom "lambda";
           List (List.map param params);
           List (atom "captures" :: List.map var captures);
         ]
        @ uses evidence
        @ [ sexp body ])
  | Con (_, c, args) -> List (atom "con" :: atom c :: List.map sexp args)
  | Record (_, fields) ->
      List
        (atom "record"
        :: List.map (fun (f, v) -> List [ Atom (f ^ ":"); sexp v ]) fields)
  | Field (r, _, f) -> List [ atom "."; sexp r; atom f ]
  | Update (r, f, v) -> List [ atom "update"; sexp r; Atom (f ^ ":"); sexp v ]
  | Array xs -> List (atom "array" :: List.map sexp xs)
  | Tag (t, args) -> List (atom "tag" :: Atom t :: List.map sexp args)
  | Fail a -> List [ atom "fail"; sexp a ]
  | Handle { body; value; on_value; error; on_error } ->
      List
        [
          atom "handle";
          sexp body;
          List [ var value; atom "=>"; sexp on_value ];
          List [ atom "fail"; var error; atom "=>"; sexp on_error ];
        ]
  | Finally (body, after) -> List [ atom "finally"; sexp body; sexp after ]

and arm_sexp a =
  let guard =
    match a.guard with Some g -> [ atom "if"; sexp g ] | None -> []
  in
  List ((pattern_sexp a.pat :: guard) @ [ atom "=>"; sexp a.body ])

(* Evidence, passed or taken, after what it's passed with: nothing when
   there's none, so code that uses no dependency prints as it always has. *)
and uses = function
  | [] -> []
  | evs -> [ List (atom "uses" :: List.map var evs) ]

let show e = render 0 (sexp e)

let show_fn f =
  render 0
    (List
       ([
          atom "fn";
          Atom f.path.name;
          List (List.map (fun p -> var p.var) f.params);
        ]
       @ uses f.evidence
       @ [ sexp f.body ]))
