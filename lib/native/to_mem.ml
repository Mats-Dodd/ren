(* Core to Mem IR (mem.ml), for the native slice's first-order subset
   (compiler.md, "Native slice").

   Only what `$start` reaches is compiled. Core is expression-shaped and
   Mem is statements in A-normal form, so each expression is compiled
   into the statements that compute it, ending in an atom that holds its
   value: an `if` or a `match` that gives a value sets a variable declared
   before it, in each branch.

   Reference counting is naive, the baseline Perceus is measured against
   (H3): every use of a counted variable is a [Dup], into a fresh
   temporary, which whatever uses it takes. Something that only reads a
   value, a `match` or a field, drops the temporary once it's done. A
   variable is dropped when its scope ends, and so is every value that's
   still held when a [Break] or a [Raise] leaves its scope: the
   function's state keeps, for each scope it's in, the counted values
   held there ([frame]).

   What the subset leaves out, blocks, generic functions, handlers and
   any dependency but the real `Console`, is an [Unsupported] error at
   the code that needs it, which the driver reports. *)

open Mem
module C = Core

let sprintf = Printf.sprintf
let bug what = failwith ("bug: native lowering: " ^ what)

(* [what] isn't in the native slice yet, at [loc]: "a block". *)
exception Unsupported of Loc.t * string

let unsupported loc what = raise (Unsupported (loc, what))

(* ---- the program ---- *)

(* What compiling the whole program shares: every type declared and
   every function, by path; the C name given to each function compiled;
   the functions still to compile, each with the code that first called
   it; and the string literals, panic sites and error tags so far. *)
type ctx = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
  fns : (Path.t, C.fn_def) Hashtbl.t;
  names : (Path.t, string) Hashtbl.t;
  taken : (string, unit) Hashtbl.t;
  mutable todo : (Path.t * Loc.t) list;
  strings : (string, int) Hashtbl.t;
  mutable string_list : string list;  (** most recent first *)
  mutable sites : site list;  (** most recent first *)
  tags : (string, int) Hashtbl.t;
}

(* The C name of the function at [p], given the first time it's asked
   for: its path with anything C doesn't allow in a name made `_`, and a
   number after it if another took that already. *)
let c_name cx (p : Path.t) =
  match Hashtbl.find_opt cx.names p with
  | Some n -> n
  | None ->
      let base =
        "ren_"
        ^ String.map
            (function
              | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_') as c -> c
              | _ -> '_')
            (Path.full p)
      in
      let rec free n =
        let name = if n = 0 then base else base ^ "_" ^ string_of_int n in
        if Hashtbl.mem cx.taken name then free (n + 1) else name
      in
      let name = free 0 in
      Hashtbl.replace cx.taken name ();
      Hashtbl.replace cx.names p name;
      name

let literal cx s =
  match Hashtbl.find_opt cx.strings s with
  | Some n -> Lit n
  | None ->
      let n = Hashtbl.length cx.strings in
      Hashtbl.replace cx.strings s n;
      cx.string_list <- s :: cx.string_list;
      Lit n

let new_site cx ?wrap ?(kind = Panics) loc =
  let s = { sid = List.length cx.sites; loc; wrap; kind } in
  cx.sites <- s :: cx.sites;
  s

(* An error tag's number, the same for every error of that name: two
   tags with one name are one error (errors.md, "Tags are structural"). *)
let tag_id cx name =
  match Hashtbl.find_opt cx.tags name with
  | Some n -> n
  | None ->
      let n = Hashtbl.length cx.tags in
      Hashtbl.replace cx.tags name n;
      n

(* ---- layouts ---- *)

let array_path = match Ty.array Ty.int with Con (p, _) -> p | _ -> bug "Array"

(* [t], a type in a declaration, with its parameters, [Var i], replaced by
   [args]. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | _ -> t

(* What a type is called in a message: `Map<Str, Int>`. *)
let ty_name (t : Ty.ty) =
  Ty.show
    (Ty.printer ~names:Path.full
       { ty = t; names = []; reqs = []; row_reqs = [] })
    t

let rec layout cx loc (t : Ty.ty) : layout =
  match t with
  | _ when t = Ty.int -> Int
  | _ when t = Ty.float -> Float
  | _ when t = Ty.bool -> Bool
  | _ when t = Ty.unit -> Unit
  | _ when t = Ty.str -> Boxed
  | Con (p, [ _ ]) when p = array_path -> Boxed
  | Con (p, _) when Ty.is_tuple p -> Boxed
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      | Some { body = Record _; _ } -> Boxed
      | Some { body = Sum ctors; _ } ->
          if List.for_all (fun (c : Iface.ctor) -> c.cfields = []) ctors then
            Enum
          else Boxed
      | Some { body = Opaque (Rep r); _ } -> layout cx loc (subst args r)
      | _ -> unsupported loc (sprintf "a value of type `%s`" (ty_name t)))
  | Errors _ -> Boxed
  (* in a function that isn't generic, a type variable is one inference
     left undecided, and no value of its type is ever made *)
  | Var _ -> Unit
  | Fun _ -> unsupported loc "a block"
  | Impl _ | Error -> unsupported loc "a handler"

(* Where each field of a constructor goes: its slot, and its layout. The
   counted fields come first, then the scalars, so the runtime frees one
   knowing only how many are counted (ren_rt.h, [ren_obj]). *)
type shape = { tag : int; slots : (int * layout) list; nobjs : int }

let shape tag layouts =
  let nobjs = List.length (List.filter counted layouts) in
  let next_obj = ref 0 and next_scalar = ref nobjs in
  let slot l =
    let r = if counted l then next_obj else next_scalar in
    let s = !r in
    incr r;
    (s, l)
  in
  { tag; slots = List.map slot layouts; nobjs }

(* The declaration of the named type [t], and its arguments. *)
let decl cx loc (t : Ty.ty) =
  match t with
  | Con (p, args) -> (
      match Hashtbl.find_opt cx.types p with
      | Some d -> (d, args)
      | None -> unsupported loc (sprintf "a value of type `%s`" (ty_name t)))
  | _ -> bug "a constructor of a type that isn't named"

(* The constructor [c] of the sum type [t]. *)
let ctor_shape cx loc (t : Ty.ty) c =
  match decl cx loc t with
  | { body = Sum ctors; _ }, args ->
      let rec find i = function
        | [] -> bug ("no constructor " ^ c)
        | (k : Iface.ctor) :: _ when k.cname = c ->
            shape i
              (List.map
                 (fun (f : Iface.field) -> layout cx loc (subst args f.fty))
                 k.cfields)
        | _ :: rest -> find (i + 1) rest
      in
      find 0 ctors
  | _ -> bug ("a constructor of a type that isn't a sum: " ^ c)

(* A sum type's constructors, by tag. *)
let ctors cx (t : Ty.ty) =
  match t with
  | Con (p, _) -> (
      match Hashtbl.find_opt cx.types p with
      | Some { body = Sum cs; _ } -> Some cs
      | _ -> None)
  | _ -> None

(* A record's fields, in the order they're declared, with their types. *)
let record_fields cx loc (t : Ty.ty) =
  match decl cx loc t with
  | { body = Record fs; _ }, args ->
      List.map (fun (f : Iface.field) -> (f.fname, subst args f.fty)) fs
  | { body = Opaque _; _ }, _ ->
      unsupported loc (sprintf "a field of the opaque type `%s`" (ty_name t))
  | _ -> bug "fields of a type that isn't a record"

let record_shape cx loc t =
  shape 0 (List.map (fun (_, ft) -> layout cx loc ft) (record_fields cx loc t))

let tuple_shape cx loc (t : Ty.ty) =
  match t with
  | Con (_, parts) -> shape 0 (List.map (layout cx loc) parts)
  | _ -> bug "a tuple whose type isn't one"

let error_shape cx loc name (payload : Ty.ty list) =
  shape (tag_id cx name) (List.map (layout cx loc) payload)

(* Whether a function returns a status and its value through a pointer:
   whether its type says it can fail with a tag. A row of errors that
   only has a tail, `! ..e`, which every function whose errors are
   inferred has, can't bring one in unless a parameter's type has that
   tail too, and no parameter is a block in the subset: so most
   functions, fib's among them, return their value. *)
let fn_fails (f : C.fn_def) =
  match f.scheme.ty with
  | Fun (ps, _, errs, _) ->
      errs.labels <> []
      || errs.tail <> None
         && List.exists
              (fun (p : Ty.param) ->
                match p.ty with Fun _ -> true | _ -> false)
              ps
  | _ -> false

(* ---- a function ---- *)

(* What a scope holds, which a [Break] or [Raise] that leaves it drops.
   [Catch_frame] is the body of a [Catch], where a [Raise] goes, with the
   [after] of the `Finally` it's for, which a [Break] that leaves it runs
   first. *)
type frame_kind =
  | Fn_frame
  | Loop_frame of int
  | Catch_frame of int * C.expr option
  | Scope

type frame = { kind : frame_kind; mutable live : var list }

module Vars = Map.Make (Int)

(* Where an expression is compiled: Mem's variable for each of Core's in
   scope, by id, and the scopes it's in, the innermost first. *)
type env = { vars : var Vars.t; frames : frame list }

(* A function being compiled: the statements of the block being built,
   last first, the numbers given out, and [here], the call that reached
   it, which a problem in the prelude, whose source can't be shown, is
   said to be at. *)
type fs = {
  cx : ctx;
  mutable out : stmt list;
  mutable next_id : int;
  mutable next_label : int;
  here : Loc.t;
}

let at fs (loc : Loc.t) = if loc.file = Prelude.file then fs.here else loc
let unsupported_at fs loc what = unsupported (at fs loc) what
let layout_at fs loc t = layout fs.cx (at fs loc) t
let emit fs s = fs.out <- s :: fs.out

let fresh fs name layout =
  fs.next_id <- fs.next_id + 1;
  { id = fs.next_id; name; layout }

let label fs =
  fs.next_label <- fs.next_label + 1;
  fs.next_label

(* The statements [f] emits, as a block, and what it gives. *)
let sub fs f =
  let saved = fs.out in
  fs.out <- [];
  let r = f () in
  let b = List.rev fs.out in
  fs.out <- saved;
  (b, r)

let block fs f = fst (sub fs f)

(* [f], whose code may not run: what each scope holds is put back after,
   as it was, for the code that runs instead. *)
let branch env f =
  let saved = List.map (fun fr -> fr.live) env.frames in
  let r = f () in
  List.iter2 (fun fr l -> fr.live <- l) env.frames saved;
  r

(* [v] holds a counted value its scope owns. *)
let own env (v : var) =
  if counted v.layout then
    match env.frames with
    | fr :: _ -> fr.live <- v :: fr.live
    | [] -> bug "a value held outside every scope"

(* [x] has been taken: its scope doesn't own it any more. *)
let consume env (x : atom) =
  match x with
  | Var v when counted v.layout ->
      let rec go = function
        | [] -> bug ("a value taken that nothing held: " ^ show_var v)
        | fr :: rest ->
            if List.memq v fr.live then
              fr.live <- List.filter (fun w -> w != v) fr.live
            else go rest
      in
      go env.frames
  | _ -> ()

(* Done with [x], which was only read. *)
let drop fs env (x : atom) =
  match x with
  | Var v when counted v.layout ->
      emit fs (Drop x);
      consume env x
  | _ -> ()

(* A new variable holding [rhs], which it owns. *)
let owned fs env name layout rhs =
  let v = fresh fs name layout in
  emit fs (Let (v, rhs));
  own env v;
  Var v

(* A new variable holding [rhs], borrowed from something else that holds
   it: a field. *)
let borrowed fs name layout rhs =
  let v = fresh fs name layout in
  emit fs (Let (v, rhs));
  Var v

(* An atom of [layout] for code that never runs, after a [Raise] or a
   [Break]. *)
let dummy (l : layout) : atom =
  match l with
  | Int -> Int 0L
  | Float -> Float 0.
  | Bool -> Bool false
  | Unit -> Unit
  | Enum -> Enum_tag 0
  | Boxed -> Scalar_ctor 0
  | Cell _ -> bug "a cell where nothing runs"

let drop_all fs (fr : frame) =
  List.iter (fun v -> emit fs (Drop (Var v))) fr.live

(* Fail with [err], which has been taken: drop what every scope up to the
   [Catch] that handles it holds, or the function's, and raise it. *)
let raise_error fs env err =
  let rec go = function
    | [] -> bug "a raise outside the function"
    | fr :: rest -> (
        drop_all fs fr;
        match fr.kind with
        | Catch_frame (l, _) -> emit fs (Raise (err, Some l))
        | Fn_frame -> emit fs (Raise (err, None))
        | Loop_frame _ | Scope -> go rest)
  in
  go env.frames

let mem_var env (v : C.var) =
  match Vars.find_opt v.id env.vars with
  | Some m -> m
  | None -> bug ("`" ^ v.name ^ "` used outside its scope")

let bind env (v : C.var) m = { env with vars = Vars.add v.id m env.vars }

(* The variables a pattern binds, each once. *)
let rec pattern_vars (p : C.pattern) =
  match p.pkind with
  | PWild | PInt _ | PBool _ -> []
  | PVar v -> [ v ]
  | PCon (_, _, ps) | PTag (_, ps) | PTuple ps ->
      List.concat_map pattern_vars ps
  | POr (p :: _) -> pattern_vars p
  | POr [] -> []

let cmp_of (op : Ast.binop) =
  match op with
  | Lt -> Some Lt
  | Le -> Some Le
  | Gt -> Some Gt
  | Ge -> Some Ge
  | _ -> None

let wrapping_meth (op : Ast.binop) =
  match op with
  | Add -> Some "wrapping_add"
  | Sub -> Some "wrapping_sub"
  | Mul -> Some "wrapping_mul"
  | _ -> None

(* How the subset shows a value of [t] with `show`. *)
let show_rt fs loc (t : Ty.ty) =
  match layout_at fs loc t with
  | Int -> Some Show_int
  | Float -> Some Show_float
  | Bool -> Some Show_bool
  | Boxed when t = Ty.str -> None
  | _ -> unsupported_at fs loc ("`show` of " ^ Diag.article (ty_name t))

let rec expr fs env (e : C.expr) : atom =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  match e.kind with
  | Int n -> Int n
  | Float f -> Float f
  | Bool b -> Bool b
  | Unit -> Unit
  | Str s -> literal cx s
  | Local v -> (
      let m = mem_var env v in
      match m.layout with
      | Cell l ->
          let t = borrowed fs v.name l (Load m) in
          if counted l then (
            emit fs (Dup t);
            match t with Var tv -> own env tv | _ -> ());
          t
      | l ->
          let t = fresh fs v.name l in
          emit fs (Let (t, Atom (Var m)));
          if counted l then emit fs (Dup (Var t));
          own env t;
          Var t)
  | Let (v, value, body) ->
      let x = expr fs env value in
      let m = fresh fs v.name (lay v.ty) in
      emit fs (Let (m, Atom x));
      consume env x;
      own env m;
      let r = expr fs (bind env v m) body in
      drop fs env (Var m);
      r
  | Assign (v, value) ->
      let x = expr fs env value in
      let m = mem_var env v in
      consume env x;
      (match m.layout with
      | Cell l ->
          if counted l then emit fs (Drop (borrowed fs v.name l (Load m)));
          emit fs (Store (m, x))
      | l ->
          if counted l then emit fs (Drop (Var m));
          emit fs (Set (m, x)));
      Unit
  | Seq (a, b) ->
      drop fs env (expr fs env a);
      expr fs env b
  | If (c, t, f) ->
      let c = expr fs env c in
      let r = fresh fs "$if" (lay e.ty) in
      emit fs (Decl r);
      let arm x =
        block fs (fun () ->
            branch env (fun () ->
                let a = expr fs env x in
                consume env a;
                emit fs (Set (r, a))))
      in
      let t = arm t in
      let f = arm f in
      emit fs (If (c, t, f));
      own env r;
      Var r
  | While (c, body) ->
      let l = label fs in
      let env' =
        { env with frames = { kind = Loop_frame l; live = [] } :: env.frames }
      in
      let b =
        block fs (fun () ->
            let c = expr fs env' c in
            emit fs (If (c, [], block fs (fun () -> break_out fs env')));
            drop fs env' (expr fs env' body))
      in
      emit fs (Loop (l, b));
      Unit
  | Break ->
      break_out fs env;
      dummy (lay e.ty)
  | Call (f, args, _) -> call fs env e f args
  | Dep_call { dep; op; args; _ } -> (
      match (dep, op, args) with
      | dep, ("write" | "error"), [ line ] when dep = Path.prelude "Console" ->
          let x = expr fs env line in
          let rt = if op = "write" then Console_write else Console_error in
          emit fs (Do (Runtime (rt, [ x ], None)));
          drop fs env x;
          Unit
      | _ ->
          unsupported_at fs e.loc
            (sprintf "a call of the dependency operation `%s.%s`"
               (Path.local dep) op))
  | With { dep; impl = { kind = Global_value (real, _); _ }; body; _ }
    when dep = Path.prelude "Console" && real = Path.member dep "real" ->
      (* `$start` installing the real `Console`, which every operation of
         it then calls: the only implementation the subset has *)
      expr fs env body
  | With { dep; impl = { kind = Global_value (real, _); _ }; _ }
    when real = Path.member dep "real" ->
      unsupported_at fs e.loc (sprintf "the real `%s`" (Path.local dep))
  | With _ | With_handler _ ->
      unsupported_at fs e.loc "installing a handler with `with`"
  | Handler _ | Instance _ | Narrowed _ -> unsupported_at fs e.loc "a handler"
  | Lambda _ -> unsupported_at fs e.loc "a block"
  | Global (p, _, _, _) ->
      unsupported_at fs e.loc
        (sprintf "`%s` used as a value, not called" (Path.local p))
  | Global_value (p, _) ->
      unsupported_at fs e.loc
        (sprintf "the associated value `%s`" (Path.local p))
  | Intrinsic (x, _, _, _) ->
      unsupported_at fs e.loc
        (sprintf "`%s` used as a value, not called" (Intrinsic.name x))
  | Prim (p, args) -> prim fs env e p args
  | Con (_, c, args) -> (
      let sh = ctor_shape cx (at fs e.loc) e.ty c in
      match args with
      | [] -> (
          match lay e.ty with
          | Enum -> Enum_tag sh.tag
          | _ -> Scalar_ctor sh.tag)
      | _ -> alloc fs env sh (List.map (expr fs env) args))
  | Record (_, fields) ->
      let decl_fields = record_fields cx (at fs e.loc) e.ty in
      let values = List.map (fun (f, x) -> (f, expr fs env x)) fields in
      alloc fs env
        (record_shape cx (at fs e.loc) e.ty)
        (List.map (fun (f, _) -> List.assoc f values) decl_fields)
  | Field (r, _, f) ->
      let x = expr fs env r in
      let fields = record_fields cx (at fs e.loc) r.ty in
      let sh = record_shape cx (at fs e.loc) r.ty in
      let slot, l =
        List.assoc f (List.combine (List.map fst fields) sh.slots)
      in
      let t = fresh fs f l in
      emit fs (Let (t, Field (x, slot)));
      if counted l then emit fs (Dup (Var t));
      drop fs env x;
      own env t;
      Var t
  | Update (r, f, v) ->
      let x = expr fs env r in
      let y = expr fs env v in
      let fields = record_fields cx (at fs e.loc) r.ty in
      let sh = record_shape cx (at fs e.loc) r.ty in
      let parts =
        List.map2
          (fun (name, _) (slot, l) ->
            if name = f then y
            else
              let t = borrowed fs name l (Field (x, slot)) in
              if counted l then emit fs (Dup t);
              t)
          fields sh.slots
      in
      let r = alloc_taking fs env sh parts in
      consume env y;
      drop fs env x;
      r
  | Array xs ->
      let l = lay (C.elem_ty e.ty) in
      let xs = List.map (expr fs env) xs in
      List.iter (consume env) xs;
      owned fs env "$array" Boxed (Alloc_array (l, xs))
  | Tuple xs ->
      alloc fs env
        (tuple_shape cx (at fs e.loc) e.ty)
        (List.map (expr fs env) xs)
  | Tag (t, [], _) -> Scalar_ctor (tag_id cx t)
  | Tag (t, args, _) ->
      let sh =
        error_shape cx (at fs e.loc) t
          (List.map (fun (a : C.expr) -> a.ty) args)
      in
      alloc fs env sh (List.map (expr fs env) args)
  | Fail x ->
      let err = expr fs env x in
      consume env err;
      raise_error fs env err;
      dummy (lay e.ty)
  | Handle { body; value; on_value; error; on_error } ->
      let r = fresh fs "$handled" (lay e.ty) in
      emit fs (Decl r);
      let l = label fs in
      let err = fresh fs error.name Boxed in
      let inner =
        {
          env with
          frames = { kind = Catch_frame (l, None); live = [] } :: env.frames;
        }
      in
      let body =
        block fs (fun () ->
            let x = expr fs inner body in
            let m = fresh fs value.name (lay value.ty) in
            emit fs (Let (m, Atom x));
            consume inner x;
            own env m;
            let y = expr fs (bind env value m) on_value in
            consume env y;
            emit fs (Set (r, y));
            drop fs env (Var m))
      in
      let handler =
        block fs (fun () ->
            branch env (fun () ->
                own env err;
                let y = expr fs (bind env error err) on_error in
                consume env y;
                emit fs (Set (r, y));
                drop fs env (Var err)))
      in
      emit fs (Catch { label = l; body; error = err; handler });
      own env r;
      Var r
  | Finally (body, after) ->
      let r = fresh fs "$finally" (lay e.ty) in
      emit fs (Decl r);
      let l = label fs in
      let err = fresh fs "$error" Boxed in
      let inner =
        {
          env with
          frames =
            { kind = Catch_frame (l, Some after); live = [] } :: env.frames;
        }
      in
      let body =
        block fs (fun () ->
            let x = expr fs inner body in
            consume inner x;
            emit fs (Set (r, x)))
      in
      let handler =
        block fs (fun () ->
            branch env (fun () ->
                drop fs env (expr fs env after);
                raise_error fs env (Var err)))
      in
      emit fs (Catch { label = l; body; error = err; handler });
      drop fs env (expr fs env after);
      own env r;
      Var r
  | Match (s, arms) -> match_ fs env e s arms
  | Assert x ->
      if x.loc.file = Prelude.file then
        unsupported_at fs e.loc "a call of the prelude that `assert`s";
      let c = expr fs env x in
      emit fs (Assert (c, new_site cx ~kind:Asserts x.loc));
      Unit
  | Assert_equal _ -> unsupported_at fs e.loc "`assert a == b`"

(* Leave the innermost loop: drop what every scope up to it holds, and
   run the [after] of each `Finally` on the way. *)
and break_out fs env =
  let rec go = function
    | [] -> bug "a `break` outside a loop"
    | fr :: rest -> (
        drop_all fs fr;
        match fr.kind with
        | Loop_frame l -> emit fs (Break l)
        | Catch_frame (_, Some after) ->
            let outer = { env with frames = rest } in
            drop fs outer (expr fs outer after);
            go rest
        | Catch_frame (_, None) | Scope -> go rest
        | Fn_frame -> bug "a `break` outside a loop")
  in
  go env.frames

(* A new object of shape [sh], which takes [fields], given in the order
   they're declared. *)
and alloc fs env sh fields =
  let r = alloc_taking fs env sh fields in
  List.iter (consume env) fields;
  r

and alloc_taking fs env sh fields =
  let by_slot =
    List.map snd
      (List.sort compare
         (List.map2 (fun (slot, _) x -> (slot, x)) sh.slots fields))
  in
  owned fs env "$new" Boxed
    (Alloc { tag = sh.tag; fields = by_slot; nobjs = sh.nobjs })

and prim fs env (e : C.expr) (p : C.prim) (args : C.expr list) =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  let site ?wrap () = new_site cx ?wrap (at fs e.loc) in
  match (p, args) with
  | Neg, [ a ] ->
      let x = expr fs env a in
      let wrap =
        if a.ty = Ty.int then
          Some { meth = "wrapping_neg"; recv = a.loc; arg = None }
        else None
      in
      owned fs env "$neg" (lay e.ty) (Neg (x, site ?wrap ()))
  | Not, [ a ] ->
      let x = expr fs env a in
      owned fs env "$not" Bool (Not x)
  | Binop op, [ a; b ] -> (
      let x = expr fs env a in
      let y = expr fs env b in
      match cmp_of op with
      | Some c -> owned fs env "$cmp" Bool (Compare (c, x, y))
      | None ->
          let wrap =
            match wrapping_meth op with
            | Some meth when a.ty = Ty.int ->
                Some { meth; recv = a.loc; arg = Some b.loc }
            | _ -> None
          in
          owned fs env "$arith" (lay e.ty) (Arith (op, x, y, site ?wrap ())))
  | (Equal _ | Not_equal _), [ a; b ] -> (
      let c = match p with Equal _ -> Eq | _ -> Ne in
      let x = expr fs env a in
      let y = expr fs env b in
      match lay a.ty with
      | Int | Float | Bool | Unit | Enum ->
          owned fs env "$eq" Bool (Compare (c, x, y))
      | Boxed when a.ty = Ty.str ->
          let same =
            owned fs env "$eq" Bool (Runtime (Str_eq, [ x; y ], None))
          in
          drop fs env x;
          drop fs env y;
          if c = Eq then same else owned fs env "$ne" Bool (Not same)
      | _ -> unsupported_at fs e.loc ("`==` on " ^ Diag.article (ty_name a.ty)))
  | Length, [ a ] ->
      let x = expr fs env a in
      let n = owned fs env "$len" Int (Runtime (Array_len, [ x ], None)) in
      drop fs env x;
      n
  | Get_index, [ a; i ] ->
      let x = expr fs env a in
      let i = expr fs env i in
      let l = lay e.ty in
      let v =
        owned fs env "$elem" l (Runtime (Array_get l, [ x; i ], Some (site ())))
      in
      drop fs env x;
      v
  | Set_index, [ a; i; v ] ->
      let x = expr fs env a in
      let i = expr fs env i in
      let y = expr fs env v in
      let l = lay v.ty in
      let r =
        owned fs env "$set" Boxed
          (Runtime (Array_set l, [ x; i; y ], Some (site ())))
      in
      drop fs env x;
      drop fs env y;
      r
  | (Compare _ | Op _ | Value_of _), _ ->
      unsupported_at fs e.loc "an operator through a requirement of a type"
  | (Entries | Members), _ -> unsupported_at fs e.loc "a `Map` or a `Set`"
  | (New_cell | Get_cell | Set_cell), _ ->
      unsupported_at fs e.loc "a handler's state"
  | _ -> bug ("`" ^ C.show_prim p ^ "` on the wrong number of operands")

and call fs env (e : C.expr) (f : C.expr) args =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  let value = function
    | C.Value a -> a
    | Ref _ -> unsupported_at fs e.loc "this call with `&`"
  in
  match f.kind with
  | Global (p, a, _, _) when p = Path.prelude "print" -> (
      (* `print` of a scalar or a `Str`: its `show`, to the real
         `Console`, as the prelude's `print` is written *)
      match (a.tys, args) with
      | [ t ], [ arg ] ->
          let x = expr fs env (value arg) in
          let s = show fs env e.loc t x in
          emit fs (Do (Runtime (Console_write, [ s ], None)));
          drop fs env s;
          Unit
      | _ -> bug "a `print` of no value")
  | Global (p, _, descs, dicts) ->
      let callee =
        match Hashtbl.find_opt cx.fns p with
        | Some d -> d
        | None -> bug ("a call of `" ^ Path.local p ^ "`, which isn't there")
      in
      if descs <> [] || dicts <> [] || callee.tys <> [] || callee.dicts <> []
      then
        unsupported_at fs e.loc
          (sprintf "a call of the generic function `%s`" (Path.local p));
      cx.todo <- (p, at fs e.loc) :: cx.todo;
      let xs =
        List.map
          (function
            | C.Value a -> expr fs env a
            | Ref v -> (
                let m = mem_var env v in
                match m.layout with
                | Cell _ -> Var m
                | l -> borrowed fs ("&" ^ v.name) (Cell l) (Addr m)))
          args
      in
      List.iter (consume env) xs;
      let name = c_name cx p in
      let l = lay e.ty in
      if fn_fails callee then (
        let result = fresh fs "$result" l in
        let error = fresh fs "$error" Boxed in
        let on_error = block fs (fun () -> raise_error fs env (Var error)) in
        emit fs (Call_fails { result; fn = name; args = xs; error; on_error });
        own env result;
        Var result)
      else owned fs env "$result" l (Call (name, xs))
  | Intrinsic (x, a, _, _) -> intrinsic fs env e x a.tys args
  | _ -> unsupported_at fs e.loc "a call of a block"

(* `show` of [x], a value of type [t], taken: a [Str] it owns. *)
and show fs env loc t x =
  match show_rt fs loc t with
  | Some rt ->
      let s = owned fs env "$shown" Boxed (Runtime (rt, [ x ], None)) in
      consume env x;
      s
  | None -> x

and intrinsic fs env (e : C.expr) (x : Intrinsic.t) tys args =
  let cx = fs.cx in
  let lay t = layout_at fs e.loc t in
  let site () = new_site cx (at fs e.loc) in
  let values () =
    List.map
      (function
        | C.Value a -> expr fs env a
        | Ref _ -> bug "an intrinsic taking `&` that isn't `push`")
      args
  in
  (* the runtime's [rt] of the arguments, which it only reads *)
  let runtime ?site rt =
    let xs = values () in
    let r =
      owned fs env
        ("$" ^ Intrinsic.member_name x)
        (lay e.ty)
        (Runtime (rt, xs, site))
    in
    List.iter (drop fs env) xs;
    r
  in
  match (x, tys) with
  | Show, [ t ] -> (
      match values () with
      | [ v ] -> show fs env e.loc t v
      | _ -> bug "a `show` of no value")
  | Array_len, _ -> runtime Array_len
  | Array_push, [ t ] -> (
      match args with
      | [ Ref xs; Value v ] ->
          let m = mem_var env xs in
          let cell =
            match m.layout with
            | Cell _ -> Var m
            | l -> borrowed fs ("&" ^ xs.name) (Cell l) (Addr m)
          in
          let y = expr fs env v in
          emit fs (Do (Runtime (Array_push (lay t), [ cell; y ], None)));
          drop fs env y;
          Unit
      | _ -> bug "a `push` without `&`")
  | Str_len, _ -> runtime Str_len
  | Str_concat, _ -> runtime Str_concat
  | Float_of, _ -> runtime Float_of_int
  | Float_sqrt, _ -> runtime ~site:(site ()) Float_sqrt
  | Float_round, _ -> runtime ~site:(site ()) Float_round
  | Float_truncate, _ -> runtime ~site:(site ()) Float_truncate
  | Int_wrapping_add, _ -> runtime (Wrapping Add)
  | Int_wrapping_sub, _ -> runtime (Wrapping Sub)
  | Int_wrapping_mul, _ -> runtime (Wrapping Mul)
  | Int_wrapping_neg, _ -> runtime Wrapping_neg
  | _ -> unsupported_at fs e.loc (sprintf "`%s`" (Intrinsic.name x))

(* A `match`: each arm's body is a join point, its pattern's variables
   declared before the tests that set them. A subject of a sum type is
   switched on by its tag, each case trying in order only the arms that
   can match that constructor; anything else tries every arm in order. A
   subject written as a tuple, `match (a, b)`, isn't made: each arm's
   parts are matched against its parts. *)
and match_ fs env (e : C.expr) (s : C.expr) (arms : C.arm list) =
  let cx = fs.cx in
  let r = fresh fs "$match" (layout_at fs e.loc e.ty) in
  emit fs (Decl r);
  let parts =
    match s.kind with
    | Tuple es
      when List.for_all
             (fun (a : C.arm) ->
               match a.pat.pkind with PTuple _ | PWild -> true | _ -> false)
             arms ->
        Some es
    | _ -> None
  in
  let subjects =
    match parts with
    | Some es -> List.map (expr fs env) es
    | None -> [ expr fs env s ]
  in
  (* what each arm's pattern matches each subject against *)
  let columns (a : C.arm) =
    match (parts, a.pat.pkind) with
    | Some _, PTuple ps -> List.combine ps subjects
    | Some _, _ -> []
    | None, _ -> [ (a.pat, List.hd subjects) ]
  in
  let arms =
    List.map
      (fun (a : C.arm) ->
        let vars =
          List.map
            (fun (v : C.var) ->
              (v, fresh fs v.name (layout_at fs a.pat.ploc v.ty)))
            (pattern_vars a.pat)
        in
        (a, vars, label fs))
      arms
  in
  List.iter
    (fun (_, vars, _) -> List.iter (fun (_, m) -> emit fs (Decl m)) vars)
    arms;
  let arm_env vars = List.fold_left (fun env (v, m) -> bind env v m) env vars in
  let no_arm = new_site cx (at fs e.loc) in
  (* the arm [a] has matched: count what its pattern bound, check its
     guard, and go to its body *)
  let matched ((a : C.arm), vars, l) =
    List.iter
      (fun (_, (m : var)) -> if counted m.layout then emit fs (Dup (Var m)))
      vars;
    let go () =
      List.iter
        (fun x ->
          match x with
          | Var v when counted v.layout -> emit fs (Drop x)
          | _ -> ())
        subjects;
      emit fs (Jump l)
    in
    match a.guard with
    | None -> go ()
    | Some g ->
        let scope = { kind = Scope; live = [] } in
        let genv = { (arm_env vars) with frames = scope :: env.frames } in
        List.iter (fun (_, m) -> own genv m) vars;
        let c = expr fs genv g in
        let yes = block fs go in
        let no =
          block fs (fun () ->
              List.iter
                (fun (_, m) -> if counted m.layout then emit fs (Drop (Var m)))
                vars)
        in
        emit fs (If (c, yes, no))
  in
  (* the statements that test [pats] in order, each a pattern and the atom
     it's matched against, then do [k]; [known] is a subject whose tag a
     switch knows *)
  let rec test ~known vars pats k =
    match pats with
    | [] -> k ()
    | ((p : C.pattern), x) :: rest -> (
        let rest_then () = test ~known vars rest k in
        let check rhs =
          let c = borrowed fs "$test" Bool rhs in
          emit fs (If (c, block fs rest_then, []))
        in
        let fields sh ps =
          List.filter_map
            (fun ((q : C.pattern), (slot, l)) ->
              match q.pkind with
              | PWild -> None
              | _ -> Some (q, borrowed fs "$part" l (Field (x, slot))))
            (List.combine ps sh.slots)
        in
        let tagged sh ps =
          let inner () = test ~known vars (fields sh ps @ rest) k in
          if known = Some (x, sh.tag) then inner ()
          else
            let t = borrowed fs "$tag" Int (Tag_of x) in
            let c =
              borrowed fs "$is" Bool
                (Compare (Eq, t, Int (Int64.of_int sh.tag)))
            in
            emit fs (If (c, block fs inner, []))
        in
        match p.pkind with
        | PWild -> rest_then ()
        | PVar v ->
            emit fs (Set (List.assq v vars, x));
            rest_then ()
        | PInt n -> check (Compare (Eq, x, Int n))
        | PBool true -> emit fs (If (x, block fs rest_then, []))
        | PBool false -> emit fs (If (x, [], block fs rest_then))
        | PCon (_, c, ps) -> tagged (ctor_shape cx (at fs p.ploc) p.pty c) ps
        | PTag (t, ps) ->
            tagged
              (error_shape cx (at fs p.ploc) t
                 (List.map (fun (q : C.pattern) -> q.pty) ps))
              ps
        | PTuple ps ->
            let sh = tuple_shape cx (at fs p.ploc) p.pty in
            test ~known vars (fields sh ps @ rest) k
        | POr alts ->
            (* the first alternative that matches binds the variables, as
               the interpreter does: a guard that fails after it goes on
               to the next arm, not the next alternative *)
            let any = fresh fs "$or" Bool in
            emit fs (Decl any);
            emit fs (Set (any, Bool false));
            List.iter
              (fun alt ->
                emit fs
                  (If
                     ( Var any,
                       [],
                       block fs (fun () ->
                           test ~known vars
                             [ (alt, x) ]
                             (fun () -> emit fs (Set (any, Bool true)))) )))
              alts;
            emit fs (If (Var any, block fs rest_then, [])))
  in
  let try_arms ~known arms =
    List.iter
      (fun ((a, vars, _) as arm) ->
        test ~known vars (columns a) (fun () -> matched arm))
      arms;
    emit fs (Panic (no_arm, "no arm of this `match` matched"))
  in
  (* whether an arm's pattern can match the constructor [tag] *)
  let rec can_match tag (p : C.pattern) =
    match p.pkind with
    | PCon (_, c, _) -> (ctor_shape cx (at fs p.ploc) p.pty c).tag = tag
    | POr alts -> List.exists (can_match tag) alts
    | _ -> true
  in
  let dispatch =
    block fs (fun () ->
        match (parts, subjects, ctors cx s.ty) with
        | None, [ x ], Some cs
          when List.exists
                 (fun ((a : C.arm), _, _) ->
                   match a.pat.pkind with PCon _ -> true | _ -> false)
                 arms ->
            let t = borrowed fs "$tag" Int (Tag_of x) in
            let cases =
              List.mapi
                (fun tag _ ->
                  ( tag,
                    block fs (fun () ->
                        try_arms
                          ~known:(Some (x, tag))
                          (List.filter
                             (fun ((a : C.arm), _, _) -> can_match tag a.pat)
                             arms)) ))
                cs
            in
            emit fs
              (Switch
                 (t, cases, [ Panic (no_arm, "no arm of this `match` matched") ]))
        | _ -> try_arms ~known:None arms)
  in
  (* the subjects were dropped on the way to each arm *)
  List.iter (consume env) subjects;
  let joins =
    List.map
      (fun ((a : C.arm), vars, l) ->
        ( l,
          block fs (fun () ->
              branch env (fun () ->
                  List.iter (fun (_, m) -> own env m) vars;
                  let y = expr fs (arm_env vars) a.body in
                  consume env y;
                  emit fs (Set (r, y));
                  List.iter (fun (_, m) -> drop fs env (Var m)) vars)) ))
      arms
  in
  emit fs (Joins (dispatch, joins));
  own env r;
  Var r

(* The function [f], reached from the code at [here]. *)
let fn cx here (f : C.fn_def) : Mem.fn =
  let fs = { cx; out = []; next_id = 0; next_label = 0; here } in
  let lay t = layout_at fs f.loc t in
  let frame = { kind = Fn_frame; live = [] } in
  let env0 = { vars = Vars.empty; frames = [ frame ] } in
  let env, params =
    List.fold_left_map
      (fun env (p : C.param) ->
        let l = lay p.var.ty in
        let m = fresh fs p.var.name (if p.mode = Inout then Cell l else l) in
        if p.mode = Read then own env m;
        (bind env p.var m, m))
      env0 f.params
  in
  let result =
    match f.scheme.ty with
    | Fun (_, r, _, _) -> lay r
    | _ -> bug "a function without a function type"
  in
  let body =
    block fs (fun () ->
        let r = expr fs env f.body in
        consume env r;
        drop_all fs frame;
        emit fs (Return r))
  in
  {
    name = c_name cx f.path;
    params;
    result;
    fails = fn_fails f;
    body;
    loc = f.loc;
  }

(* How `ren run` shows a value of [t]: `main`'s, or a payload's. *)
let shown cx loc what (t : Ty.ty) =
  match layout cx loc t with
  | Int -> Shows_int
  | Float -> Shows_float
  | Bool -> Shows_bool
  | Unit -> Shows_unit
  | Boxed when t = Ty.str -> Shows_str
  | _ -> unsupported loc (what ^ " " ^ Diag.article (ty_name t))

(* The program [modules], the prelude first and the entry last, with its
   `$start`, compiled from there: only what it reaches. *)
let program (modules : C.program list) : Mem.program =
  let cx =
    {
      types = Hashtbl.create 64;
      fns = Hashtbl.create 256;
      names = Hashtbl.create 64;
      taken = Hashtbl.create 64;
      todo = [];
      strings = Hashtbl.create 16;
      string_list = [];
      sites = [];
      tags = Hashtbl.create 16;
    }
  in
  List.iter
    (fun (m : C.program) ->
      List.iter
        (fun (d : Iface.type_decl) -> Hashtbl.replace cx.types d.path d)
        m.types;
      List.iter (fun (f : C.fn_def) -> Hashtbl.replace cx.fns f.path f) m.fns)
    modules;
  let entry =
    match List.rev modules with m :: _ -> m | [] -> bug "no modules"
  in
  let start_path = Path.make entry.home Lower.start_name in
  let start =
    match Hashtbl.find_opt cx.fns start_path with
    | Some f -> f
    | None -> bug "a program with no `$start`"
  in
  let ret, errs =
    match start.scheme.ty with
    | Fun (_, r, e, _) -> (r, e)
    | _ -> bug "a `$start` without a function type"
  in
  let prints = shown cx start.loc "a `main` that gives" ret in
  let errors =
    List.map
      (fun (l : Ty.label) ->
        let sh = error_shape cx start.loc l.name l.payload in
        ( sh.tag,
          l.name,
          List.map2
            (fun (slot, _) t ->
              (slot, shown cx start.loc "a `main` whose error holds" t))
            sh.slots l.payload ))
      errs.labels
  in
  let overflow = new_site cx start.loc in
  cx.todo <- [ (start_path, start.loc) ];
  let done_ = Hashtbl.create 64 in
  let rec go acc =
    match cx.todo with
    | [] -> List.rev acc
    | (p, here) :: rest ->
        cx.todo <- rest;
        if Hashtbl.mem done_ p then go acc
        else (
          Hashtbl.replace done_ p ();
          go (fn cx here (Hashtbl.find cx.fns p) :: acc))
  in
  let fns = go [] in
  {
    fns;
    start = c_name cx start_path;
    start_result = layout cx start.loc ret;
    start_fails = fn_fails start;
    prints;
    errors;
    strings = List.rev cx.string_list;
    sites = List.rev cx.sites;
    overflow;
  }
