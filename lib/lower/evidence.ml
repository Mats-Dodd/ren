(* Evidence: making every dependency an explicit parameter in Core
   (deps.md, "How it runs").

   Lowering (lower.ml) leaves dependencies implicit: a call of an
   operation is a [Dep_op], and nothing says which implementation it
   calls. This pass threads the implementations through the whole
   program instead, as evidence:

   - each function and lambda takes a hidden parameter for each
     dependency its type uses, in the order of its row's labels
   - each call passes the caller's evidence for each dependency the callee
     takes, so the innermost implementation installed is the one used
   - a call of an operation becomes a [Dep_call] of the evidence for its
     dependency
   - the program starts in `$start`, which installs the real
     implementation of each built-in dependency `main` uses, around a call
     of `main`: what the runtime does (deps.md, "`main`")

   A lambda takes its own evidence, so it uses the implementation
   installed where it's called, never the one installed where it was
   made.

   Which evidence a function takes has to be the same however its type is
   seen. A row variable gets in the way: inside `fn apply(f: fn())`, `f`
   uses `..u`, whatever the caller's row is, so `apply` can't know what to
   pass `f`. So a function whose parameters or result mention a row
   variable of its `uses` gets a copy for each set of dependencies a call
   gives that variable: `apply` called with a closure that uses `Console`
   calls `apply[Console]`, a copy in which `f` uses `Console`. A row
   variable left in a type then never stands for a dependency that has
   evidence, and the evidence of any function value is exactly the
   dependencies its type names. (A row's labels are a finite set, so the
   copies are too.) An associated value is a function of no parameters
   (core.ml), so one whose type mentions a row variable, like
   `let one = fn() => 1`, gets copies the same way, each made at startup
   right after it. The one place a function is seen with more
   dependencies than its own type names is a function used as a value,
   which may be given to something that uses more: there it's wrapped in a
   lambda that takes the evidence its type there names, and passes on what
   the function takes.

   Like lowering, this changes no order of evaluation. *)

open Core

let bug what = failwith ("bug: threading evidence found " ^ what)

(* ---- rows ---- *)

(* What the program declares: its dependencies, which get evidence, and
   its functions, which get copies. A label with no declaration, like
   `Net`, is a dependency with no operations yet, so it has no evidence. *)
type world = {
  deps : (Path.t, unit) Hashtbl.t;
  fns : (Path.t, fn_def) Hashtbl.t;
  copies : (Path.t * string list list, Path.t) Hashtbl.t;
      (** the copy of each function made for each set of dependencies *)
  mutable queue : (fn_def * subst * Path.t) list;
      (** copies asked for and not made yet, the most recent first *)
  mutable made : (Path.t * Path.t) list;
      (** each function or value and a copy of it, the most recent first *)
}

(* What each row variable of a function's own scheme stands for in a copy:
   the dependencies it gets on top of its tail, which stays. *)
and subst = (int * Ty.label list) list

(* The dependencies of [r] that have evidence, in the order of its labels. *)
let deps_of w (r : Ty.row) =
  List.filter_map
    (fun (l : Ty.label) ->
      let p = Ty.dep_path l.name in
      if Hashtbl.mem w.deps p then Some p else None)
    r.labels

(* What a function type uses. Anything else is an opaque type whose
   representation is a function's, which, as it's declared, uses nothing. *)
let uses_of (t : Ty.ty) = match t with Fun (_, _, _, u) -> u | _ -> Ty.closed

let rec subst s (t : Ty.ty) : Ty.ty =
  match t with
  | Var _ | Error -> t
  | Con (p, args) -> Con (p, List.map (subst s) args)
  | Errors e -> Errors (payloads s e)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst s p.ty }) ps,
          subst s r,
          payloads s e,
          uses_row s u )

and payloads s (r : Ty.row) =
  {
    r with
    labels =
      List.map
        (fun (l : Ty.label) ->
          { l with payload = List.map (subst s) l.payload })
        r.labels;
  }

(* Only a `uses` row's tail is replaced: an errors row's variables are
   numbered apart, and have nothing to do with evidence. *)
and uses_row s (r : Ty.row) =
  let r = payloads s r in
  match r.tail with
  | Some n when List.mem_assoc n s ->
      let more =
        List.filter (fun l -> not (List.mem l r.labels)) (List.assoc n s)
      in
      { r with labels = Ty.sort_labels (more @ r.labels) }
  | _ -> r

let subst_var s (v : var) = { v with ty = subst s v.ty }

(* The row variables that end a `uses` row inside [t]. *)
let rec uses_tails (t : Ty.ty) =
  match t with
  | Var _ | Error -> []
  | Con (_, args) -> List.concat_map uses_tails args
  | Errors e -> List.concat_map label_tails e.labels
  | Fun (ps, r, e, u) ->
      List.concat_map (fun (p : Ty.param) -> uses_tails p.ty) ps
      @ uses_tails r
      @ List.concat_map label_tails e.labels
      @ List.concat_map label_tails u.labels
      @ Option.to_list u.tail

and label_tails (l : Ty.label) = List.concat_map uses_tails l.payload

(* The row variables of a function's scheme that a copy is made for: those
   its parameters or result mention. One only in its own `uses` stands for
   whatever its callers use besides, which it never calls anything with. *)
let live (scheme : Ty.ty) =
  match scheme with
  | Fun (ps, r, _, _) ->
      List.sort_uniq compare
        (List.concat_map uses_tails
           (r :: List.map (fun (p : Ty.param) -> p.ty) ps))
  | _ -> []

(* What the instance [t] of the scheme [s] gives each row variable at the
   end of a `uses` row: the labels it has there that [s] doesn't. *)
let rec bindings (s : Ty.ty) (t : Ty.ty) acc =
  match (s, t) with
  | Con (p, a), Con (q, b) when p = q && List.length a = List.length b ->
      List.fold_left2 (fun acc a b -> bindings a b acc) acc a b
  | Fun (ps, r, _, u), Fun (qs, r', _, u') when List.length ps = List.length qs
    -> (
      let acc =
        List.fold_left2
          (fun acc (p : Ty.param) (q : Ty.param) -> bindings p.ty q.ty acc)
          acc ps qs
      in
      let acc = bindings r r' acc in
      match u.tail with
      | Some n when not (List.mem_assoc n acc) ->
          (n, List.filter (fun l -> not (List.mem l u.labels)) u'.labels) :: acc
      | _ -> acc)
  | _ -> acc

(* ---- copies ---- *)

let fn_of w p =
  match Hashtbl.find_opt w.fns p with
  | Some f -> f
  | None -> bug ("no function `" ^ p.name ^ "`")

(* The function a use of [p] at the type [t] refers to, and its scheme's
   type: [p] itself, or its copy for the dependencies [t] gives its live row
   variables, asked for if it hasn't been yet. *)
let refer w (p : Path.t) (t : Ty.ty) =
  let f = fn_of w p in
  let found = bindings f.scheme.ty t [] in
  let s =
    List.map
      (fun n ->
        let ls = Option.value (List.assoc_opt n found) ~default:[] in
        (* only what has evidence: copies for anything else would be the
           same *)
        ( n,
          List.filter
            (fun (l : Ty.label) -> Hashtbl.mem w.deps (Ty.dep_path l.name))
            ls ))
      (live f.scheme.ty)
  in
  if List.for_all (fun (_, ls) -> ls = []) s then (p, f.scheme.ty)
  else
    let key =
      List.map (fun (_, ls) -> Ty.label_names { labels = ls; tail = None }) s
    in
    let copy =
      match Hashtbl.find_opt w.copies (p, key) with
      | Some c -> c
      | None ->
          (* each row variable's dependencies, apart by `;`, and `_` for
             one given none: `f[Console; _]` *)
          let name =
            p.name ^ "["
            ^ String.concat "; "
                (List.map
                   (function [] -> "_" | ls -> String.concat ", " ls)
                   key)
            ^ "]"
          in
          let c = Path.make p.home name in
          Hashtbl.replace w.copies (p, key) c;
          w.queue <- (f, s, c) :: w.queue;
          w.made <- (p, c) :: w.made;
          c
    in
    (copy, subst s f.scheme.ty)

(* ---- threading ---- *)

(* One function's threading: its copy's substitution, and the id of the
   next variable it makes, after every one lowering made. *)
type cx = { w : world; s : subst; mutable next : int }

(* The evidence in scope: each dependency's innermost, by its path. *)
type env = (Path.t * var) list

let fresh cx name ty =
  let v = { id = cx.next; name; ty } in
  cx.next <- cx.next + 1;
  v

let fresh_ev cx (p : Path.t) = fresh cx (Ty.dep_label p) (Con (p, []))

(* Evidence parameters for the dependencies [t], a function type, uses. *)
let takes cx (t : Ty.ty) =
  let deps = deps_of cx.w (uses_of t) in
  let evs = List.map (fresh_ev cx) deps in
  (evs, List.combine deps evs)

let pass (env : env) loc deps =
  List.map
    (fun p ->
      match List.assoc_opt p env with
      | Some v -> v
      | None ->
          bug
            (Printf.sprintf "nothing installs `%s` at %s:%d" (Path.full p)
               loc.Loc.file loc.start.line))
    deps

(* The largest variable id in a function, so the evidence's can come after
   every one lowering made. *)
let max_id (f : fn_def) =
  let m = ref 0 in
  let see (v : var) = m := max !m v.id in
  let rec go (e : expr) =
    (match e.kind with
    | Local v | Assign (v, _) | Let (v, _, _) -> see v
    | Handle { value; error; _ } ->
        see value;
        see error
    | Lambda { params; evidence; captures; _ } ->
        List.iter (fun (p : param) -> see p.var) params;
        List.iter see (evidence @ captures)
    | Call (_, args, evs) ->
        List.iter (function Ref v -> see v | Value _ -> ()) args;
        List.iter see evs
    | Match (_, arms) -> List.iter (fun a -> pat a.pat) arms
    | Dep_call { impl = v; _ } | With { ev = v; _ } -> see v
    | _ -> ());
    List.iter go (children e)
  and pat (p : pattern) =
    match p.pkind with
    | PVar v -> see v
    | PCon (_, _, ps) | PTag (_, ps) | POr ps -> List.iter pat ps
    | PWild | PInt _ | PBool _ -> ()
  in
  List.iter (fun (p : param) -> see p.var) f.params;
  List.iter see f.evidence;
  go f.body;
  !m

(* A lambda of type [t] that calls [call] with its parameters and the
   evidence: a function used as a value, taking the evidence [t] names. *)
let wrap cx loc (t : Ty.ty) call =
  match t with
  | Fun (ps, ret, _, _) ->
      let params =
        List.map
          (fun (p : Ty.param) -> { mode = p.mode; var = fresh cx "$x" p.ty })
          ps
      in
      let evidence, env = takes cx t in
      let args =
        List.map
          (fun p ->
            match p.mode with
            | Read -> Value (local p.var loc)
            | Inout -> Ref p.var)
          params
      in
      mk
        (Lambda { params; evidence; captures = []; body = call ret args env })
        t loc
  | _ -> bug "a function used as a value whose type isn't a function's"

let rec expr cx (env : env) (e : expr) : expr =
  let ty = subst cx.s e.ty in
  let here kind = mk kind ty e.loc in
  let go = expr cx env in
  match e.kind with
  | Int _ | Bool _ | Str _ | Unit -> here e.kind
  | Global_value p ->
      (* an associated value is made once, at startup, with the evidence
         its own type names: one used at a type that gives its row
         variables more, like `let one = fn() => 1` used where `Console`
         is, is a copy made for that *)
      let p', _ = refer cx.w p (Fun ([], ty, Ty.closed, Ty.closed)) in
      here (Global_value p')
  | Local v -> here (Local (subst_var cx.s v))
  | Global p ->
      let p', scheme = refer cx.w p ty in
      let callee = here (Global p') in
      let own = deps_of cx.w (uses_of scheme) in
      if own = deps_of cx.w (uses_of ty) then callee
      else
        wrap cx e.loc ty (fun ret args env ->
            mk (Call (callee, args, pass env e.loc own)) ret e.loc)
  | Intrinsic _ ->
      if deps_of cx.w (uses_of ty) = [] then here e.kind
      else
        wrap cx e.loc ty (fun ret args _ ->
            mk (Call (here e.kind, args, [])) ret e.loc)
  | Dep_op (dep, op) ->
      wrap cx e.loc ty (fun ret args env ->
          let args =
            List.map
              (function Value a -> a | Ref _ -> bug "an operation with `&`")
              args
          in
          mk
            (Dep_call
               {
                 dep;
                 op;
                 fty = ty;
                 impl = List.hd (pass env e.loc [ dep ]);
                 args;
               })
            ret e.loc)
  | Call (f, args, _) -> (
      let fty = subst cx.s f.ty in
      let callee kind = mk kind fty f.loc in
      (* the callee first, then the arguments, as they're evaluated *)
      let args () =
        List.map
          (function Value a -> Value (go a) | Ref v -> Ref (subst_var cx.s v))
          args
      in
      match f.kind with
      | Global p ->
          (* a function takes the evidence its own scheme names *)
          let p', scheme = refer cx.w p fty in
          let args = args () in
          here
            (Call
               ( callee (Global p'),
                 args,
                 pass env e.loc (deps_of cx.w (uses_of scheme)) ))
      | Intrinsic x -> here (Call (callee (Intrinsic x), args (), []))
      | Dep_op (dep, op) ->
          let args =
            List.map
              (function Value a -> a | Ref _ -> bug "an operation with `&`")
              (args ())
          in
          here
            (Dep_call
               { dep; op; fty; impl = List.hd (pass env e.loc [ dep ]); args })
      | _ ->
          (* a function value takes the evidence its type names *)
          let f = go f in
          let args = args () in
          here (Call (f, args, pass env e.loc (deps_of cx.w (uses_of f.ty)))))
  | Lambda { params; captures; body; _ } ->
      (* its body sees only its own evidence: it's passed where it's
         called *)
      let evidence, inner = takes cx ty in
      let params = List.map (param cx) params in
      here
        (Lambda
           {
             params;
             evidence;
             captures = List.map (subst_var cx.s) captures;
             body = expr cx inner body;
           })
  | Dep_call d ->
      here
        (Dep_call
           {
             d with
             fty = subst cx.s d.fty;
             impl = subst_var cx.s d.impl;
             args = List.map go d.args;
           })
  | With { ev; impl; body } ->
      let ev = subst_var cx.s ev in
      let dep =
        match ev.ty with
        | Con (p, _) -> p
        | _ -> bug "evidence of no dependency"
      in
      let impl = go impl in
      here (With { ev; impl; body = expr cx ((dep, ev) :: env) body })
  (* each part in the order it's written, with `let`s: OCaml evaluates a
     constructor's arguments right to left, and the evidence a part makes
     is numbered as it's met *)
  | Prim (op, es) -> here (Prim (op, List.map go es))
  | Let (v, a, b) ->
      let a = go a in
      here (Let (subst_var cx.s v, a, go b))
  | Assign (v, a) -> here (Assign (subst_var cx.s v, go a))
  | If (c, t, f) ->
      let c = go c in
      let t = go t in
      here (If (c, t, go f))
  | Match (s, arms) ->
      let s = go s in
      here (Match (s, List.map (arm cx env) arms))
  | While (c, b) ->
      let c = go c in
      here (While (c, go b))
  | Seq (a, b) ->
      let a = go a in
      here (Seq (a, go b))
  | Con (p, c, es) -> here (Con (p, c, List.map go es))
  | Record (p, fs) -> here (Record (p, List.map (fun (f, v) -> (f, go v)) fs))
  | Field (r, p, f) -> here (Field (go r, p, f))
  | Update (r, f, v) ->
      let r = go r in
      here (Update (r, f, go v))
  | Array es -> here (Array (List.map go es))
  | Tag (t, es) -> here (Tag (t, List.map go es))
  | Fail a -> here (Fail (go a))
  | Handle { body; value; on_value; error; on_error } ->
      let body = go body in
      let on_value = go on_value in
      here
        (Handle
           {
             body;
             value = subst_var cx.s value;
             on_value;
             error = subst_var cx.s error;
             on_error = go on_error;
           })
  | Finally (a, b) ->
      let a = go a in
      here (Finally (a, go b))

and param cx (p : param) = { p with var = subst_var cx.s p.var }

and arm cx env (a : arm) =
  let guard = Option.map (expr cx env) a.guard in
  { pat = pattern cx a.pat; guard; body = expr cx env a.body }

and pattern cx (p : pattern) =
  let pkind =
    match p.pkind with
    | PVar v -> PVar (subst_var cx.s v)
    | PCon (path, c, ps) -> PCon (path, c, List.map (pattern cx) ps)
    | PTag (t, ps) -> PTag (t, List.map (pattern cx) ps)
    | POr ps -> POr (List.map (pattern cx) ps)
    | (PWild | PInt _ | PBool _) as k -> k
  in
  { p with pkind; pty = subst cx.s p.pty }

(* [f], or its copy at [path] for the substitution [s], with its evidence. *)
let fn_def w ~s ~path (f : fn_def) =
  let cx = { w; s; next = max_id f + 1 } in
  let scheme = { f.scheme with ty = subst s f.scheme.ty } in
  let evidence, env = takes cx scheme.ty in
  {
    f with
    path;
    scheme;
    params = List.map (param cx) f.params;
    evidence;
    body = expr cx env f.body;
  }

let start_name = "$start"

(* What the runtime runs: the real implementation of each built-in
   dependency [main] uses, installed around a call of it. The type
   checker made sure it uses no other (infer_top.ml, [check_main]). *)
let start (main : fn_def) =
  let loc = main.loc in
  let ret, errs =
    match main.scheme.ty with
    | Fun (_, ret, errs, _) -> (ret, errs)
    | _ -> bug "a `main` whose type isn't a function's"
  in
  (* the same evidence as [main] takes, numbered from 1: `$start` has no
     other variables *)
  let evs =
    List.mapi (fun i (v : var) -> { v with id = i + 1 }) main.evidence
  in
  let call =
    mk (Call (mk (Global main.path) main.scheme.ty loc, [], evs)) ret loc
  in
  let body =
    List.fold_right
      (fun (ev : var) body ->
        let dep =
          match ev.ty with
          | Con (p, _) -> p
          | _ -> bug "evidence of no dependency"
        in
        let real = Path.make dep.home (dep.name ^ ".real") in
        mk
          (With { ev; impl = mk (Global_value real) ev.ty loc; body })
          body.ty loc)
      evs call
  in
  {
    path = Path.make main.path.home start_name;
    params = [];
    evidence = [];
    scheme = { main.scheme with ty = Fun ([], ret, errs, Ty.closed) };
    body;
    loc;
  }

let program (modules : program list) =
  let w =
    {
      deps = Hashtbl.create 16;
      fns = Hashtbl.create 64;
      copies = Hashtbl.create 16;
      queue = [];
      made = [];
    }
  in
  List.iter
    (fun (m : program) ->
      List.iter
        (fun (td : Iface.type_decl) ->
          match td.body with
          | Dep _ -> Hashtbl.replace w.deps td.path ()
          | _ -> ())
        m.types;
      List.iter (fun (f : fn_def) -> Hashtbl.replace w.fns f.path f) m.fns)
    modules;
  let threaded =
    List.map
      (fun (m : program) ->
        { m with fns = List.map (fun f -> fn_def w ~s:[] ~path:f.path f) m.fns })
      modules
  in
  (* each copy, in the order they were asked for; making one can ask for
     more *)
  let rec copies made =
    match List.rev w.queue with
    | [] -> made
    | queued ->
        w.queue <- [];
        let more = List.map (fun (f, s, path) -> fn_def w ~s ~path f) queued in
        copies (made @ more)
  in
  let copies = copies [] in
  let entry = (List.nth modules (List.length modules - 1)).home in
  List.map
    (fun (m : program) ->
      let fns =
        m.fns @ List.filter (fun (f : fn_def) -> f.path.home = m.home) copies
      in
      (* a value's copies are made right after it, so after every value
         they use too *)
      let values =
        List.concat_map
          (fun v ->
            v
            :: List.rev
                 (List.filter_map
                    (fun (o, c) -> if o = v then Some c else None)
                    w.made))
          m.values
      in
      let start =
        if m.home <> entry then []
        else
          match
            List.find_opt
              (fun (f : fn_def) -> f.path = Path.make m.home "main")
              fns
          with
          | Some main -> [ start main ]
          | None -> []
      in
      { m with fns = fns @ start; values })
    threaded
