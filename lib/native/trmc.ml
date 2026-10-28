(* Tail recursion modulo cons (compiler.md, "Native slice"): a function
   whose recursive call is the last thing it does but for building a
   constructor around its result runs as a loop instead, which builds
   each constructor first, with a hole where the call's result goes,
   and fills that hole on the next turn. So building a list or the
   spine of a tree takes no stack, however long it is:

     fn build(i: Int, n: Int) -> List =
       if i == n then Nil else Cons(i, build(i + 1, n))

   It's Koka's (Leijen and Lorenzen, "Tail Recursion Modulo Context",
   POPL'22): CTail.hs finds the call ([ctailExpr], koka
   src/Core/CTail.hs:264, and [ctailTryArg], :364), and builds the
   constructor with the hole first ([ctailFoundArg], :436). Koka's
   context is a value, the result and the hole, because a program can
   hold one; here only the loop does, as in Koka's own linear case
   ([kk_cctx_apply_linear], lib/std/core/inline/types-cctx.h:66).

   Prepared, before Perceus counts it, a call this pass takes is

     (let $result (call f a1 .. an))
     (let $new (alloc #k x .. $result .. y))
     then (return $new), or (set r $new) where all that's left to do
     is return r: at the end of a block, or before a jump to a join,
     after which that's all, perhaps through other names for r

   and the function becomes

     (decl p1) .. (decl pn) (decl root) (decl hole)
     (joins
       (do the body, the first turn, a copy with names of its own,
           each such call
             (let $new (alloc #k x .. #0* .. y))   #0* where $result went
             (let h (hole $new slot))
             (set root $new) (set hole h)
             (set p1 a1) .. (set pn an)            the call's arguments
             (jump go))
       (go: (loop (joins (do (let a1' p1) .. (let an' pn)  the parameters
                             the body, each such call
                               (let $new (alloc #k x .. #0* .. y))
                               (let h (hole $new slot))
                               (fill hole $new) (set hole h)
                               (set p1 a1) .. (set pn an)
                               (jump next)
                             and each (return v)
                               (fill hole v) (return root))
                         (next: (do))))))

   The first turn is a copy so that [root] holds the chain on every
   path through the loop, counted 1, with no flag to say which turn
   it is, which Perceus and Mem Lint, which follow counts path by
   path, couldn't see through. The body is twice in the C.

   Why it's sound. The constructor is built before the call's work
   instead of after it, which no one can see: its other fields were
   computed before the call, nothing comes between the call and it,
   and an [Alloc] can't fail. Its slot holds a scalar ([Scalar_ctor
   0]) till it's filled, which a [Drop] of it ignores.

   - Only this function can reach the hole. The constructor is made
     here, and goes nowhere but into [root] or the hole before, and its
     hole's address into [hole]: the chain from [root] to the
     newest is reachable only from [root], which the function owns, and
     every object on it has count 1 (Perceus counts [root] and the
     constructor as any other value: mem_lint.ml checks [Fill] takes
     it). So filling a hole writes into an object no one else sees,
     and over a scalar, so nothing is lost: what [kk_cctx_apply_linear]
     does without testing, because, as here, the context is never
     shared.
   - Every way out gives what the recursion would have. A [Return v]
     in the first turn is the original call's; in a later turn it's
     what the innermost call would have returned, put where the call's
     result went, and [root] is what the outermost would have. A
     failure on any turn returns the error, as the innermost call's
     error would have been passed on by each caller: so a call that
     can fail is taken only if all it does with an error is return it
     ([Raise] to no [Catch]), and Perceus drops [root], the chain built
     so far, as it drops whatever dies there. A panic ends the program.
   - The turn's arguments are the call's, evaluated where it was, and
     the parameters' names are bound again from the variables at the
     top of each turn, so the body sees each turn what the call would
     have. A call whose result is returned as it is, in a later turn,
     is a turn too, which leaves the hole for the next ([Tail]).

   Not taken: a function whose values are words (its type variables'
   descriptors would have to go round the loop), with a cell or `inout`
   parameter, or whose result isn't an object. A call in a loop or a
   catch, or with anything after it but naming its result, stays a call;
   so does every call but the last in a constructor, `Node(f(l), f(r))`
   makes its left side by recursion still. A Perceus build's pass, after
   [Rc.prepare] and before [Borrow.infer]: what it makes is counted, and
   reused, as anything else is. *)

open Mem

(* A call of [f] itself, with the arguments it's given, the variable
   its result goes in, and what it does if it fails. *)
let self_call (f : fn) (s : stmt) : (var * atom list) option =
  match s with
  | Let (res, Call (g, args)) when g = f.name -> Some (res, args)
  | Call_fails
      { result; fn = g; args; error; on_error = [ Raise (Var e, None) ] }
    when g = f.name && e.id = error.id ->
      Some (result, args)
  | _ -> None

(* What runs when control falls off the end of a block: a [Return] of
   this variable and nothing else, or something else. *)
type cont = Ret of int | Other

(* What happens after [rest], the statements left in a block, given
   [k], what happens after the block, and [labels], what happens after
   a jump to each join: a [Return] of a variable, if all [rest] does is
   return one, or name it again, or set another to it, that's returned. *)
let rec after (k : cont) labels (rest : block) : cont =
  match rest with
  | [] -> k
  | [ Return (Var r) ] -> Ret r.id
  | [ Jump l ] -> Option.value (List.assoc_opt l labels) ~default:Other
  | (Set (r', Var r) | Let (r', Atom (Var r))) :: rest
    when r.layout = Boxed && after k labels rest = Ret r'.id ->
      Ret r.id
  | _ -> Other

(* How many times each variable is read in a function's body. *)
let reads (b : block) =
  let n = Hashtbl.create 64 in
  Rc.iter_stmts
    (fun s ->
      List.iter
        (function
          | Var (v : var) ->
              Hashtbl.replace n v.id
                (1 + Option.value (Hashtbl.find_opt n v.id) ~default:0)
          | _ -> ())
        (Rc.stmt_atoms s))
    b;
  fun (v : var) -> Option.value (Hashtbl.find_opt n v.id) ~default:0

(* A call this pass takes. *)
type site =
  | Cons of atom list * var * int * atom list * int
      (** a call whose result is put in a constructor, which is returned: the
          call's arguments, the constructor's variable, its tag and fields, and
          the slot the call's result goes in *)
  | Tail of atom list
      (** a call whose result is returned as it is, with these arguments: a
          later turn's ends by going round again, its hole still to fill *)

(* Whether [tail], the statements after where [v] is made, only return
   it. *)
let finishes (k : cont) labels (v : var) (tail : block) =
  after k labels tail = Ret v.id

(* The call this pass takes that [b] starts with, if it does. *)
let site f ~read (k : cont) labels (b : block) : site option =
  let is (res : var) (x : atom) =
    match x with Var v -> v.id = res.id | _ -> false
  in
  match b with
  | call :: Let (c, Alloc { tag; fields; words = []; at = None }) :: tail -> (
      match self_call f call with
      | Some (res, args)
        when List.length (List.filter (is res) fields) = 1
             && read res = 1
             && read c = 1
             && finishes k labels c tail ->
          Option.map
            (fun n -> Cons (args, c, tag, fields, n))
            (List.find_index (is res) fields)
      | _ -> None)
  | call :: tail -> (
      match self_call f call with
      | Some (res, args) when read res = 1 && finishes k labels res tail ->
          Some (Tail args)
      | _ -> None)
  | _ -> None

(* The new variables the loop needs. *)
type loop = {
  params : var list;  (** the parameters, as variables the loop sets *)
  root : var;  (** the outermost constructor *)
  hole : var;  (** where the next turn's value goes *)
  go : int;  (** the join the first turn ends by jumping to, the loop *)
  next : int;  (** the join each later turn ends by jumping to *)
}

(* Whether a block is the first turn's, or a later one's. *)
type which = First | Later

(* [b] with each call it takes made the end of a turn, and, in a later
   turn, each [Return] filling the hole. [k] is what runs after it,
   [labels] what runs after each join, [taken] whether a call was. *)
let rec turn f ~read ~fresh lp which taken (k : cont) labels (b : block) : block
    =
  let again = turn f ~read ~fresh lp which taken in
  match site f ~read k labels b with
  | Some (Tail args) when which = Later ->
      List.map2 (fun p x -> Set (p, x)) lp.params args @ [ Jump lp.next ]
  | Some (Cons (args, c, tag, fields, n)) ->
      taken := true;
      let h = fresh "hole" Ptr in
      let fields =
        List.mapi (fun i x -> if i = n then Scalar_ctor 0 else x) fields
      in
      [
        Let (c, Alloc { tag; fields; words = []; at = None });
        Let (h, Hole (Var c, n));
        (match which with
        | First -> Set (lp.root, Var c)
        | Later -> Fill (Var lp.hole, Var c));
        Set (lp.hole, Var h);
      ]
      @ List.map2 (fun p x -> Set (p, x)) lp.params args
      @ [ Jump (match which with First -> lp.go | Later -> lp.next) ]
  | Some (Tail _) | None -> (
      match b with
      | [] -> []
      | s :: rest ->
          let k' = after k labels rest in
          let s =
            match s with
            | Return _ -> returns lp which [ s ]
            | If (x, b1, b2) ->
                [ If (x, again k' labels b1, again k' labels b2) ]
            | Switch (x, cases, d) ->
                [
                  Switch
                    ( x,
                      List.map (fun (t, b) -> (t, again k' labels b)) cases,
                      again k' labels d );
                ]
            | Joins (d, js) ->
                (* a jump to an empty join goes on as the [Joins] does *)
                let into j = after k' labels j in
                let labels' =
                  List.map (fun (l, j) -> (l, into j)) js @ labels
                in
                [
                  Joins
                    ( again Other labels' d,
                      List.map (fun (l, j) -> (l, again k' labels j)) js );
                ]
            | s ->
                (* in a loop, a catch or an error path, no call is taken,
                   but every [Return] still fills the hole *)
                [ Rc.map_blocks (returns lp which) s ]
          in
          s @ again k labels rest)

(* [b] with each [Return] in a later turn filling the hole and returning
   the outermost constructor. *)
and returns lp which (b : block) : block =
  match which with
  | First -> b
  | Later ->
      List.concat_map
        (function
          | Return x -> [ Fill (Var lp.hole, x); Return (Var lp.root) ]
          | s -> [ Rc.map_blocks (returns lp which) s ])
        b

(* [b] with every variable and label it defines made fresh, and the
   variables [also] names too: the first turn's copy of the body,
   which the later turns' can't share names with. *)
let rename ~next ~label (also : var list) (b : block) : block * var list =
  let defined = Hashtbl.create 64 and owned = Hashtbl.create 8 in
  let def (v : var) = Hashtbl.replace defined v.id () in
  List.iter def also;
  Rc.iter_stmts
    (function
      | Let (v, _) | Decl v -> def v
      | Call_fails { result; error; _ }
      | Call_block { result; error; _ }
      | Call_handler { result; error; _ } ->
          def result;
          def error
      | Catch { error; label; _ } ->
          def error;
          Hashtbl.replace owned label ()
      | Loop (l, _) -> Hashtbl.replace owned l ()
      | Joins (_, js) -> List.iter (fun (l, _) -> Hashtbl.replace owned l ()) js
      | _ -> ())
    b;
  let vars = Hashtbl.create 64 and labels = Hashtbl.create 8 in
  let var (v : var) =
    if not (Hashtbl.mem defined v.id) then v
    else
      match Hashtbl.find_opt vars v.id with
      | Some w -> w
      | None ->
          let w = { v with id = !next } in
          incr next;
          Hashtbl.replace vars v.id w;
          w
  in
  let lab l =
    if not (Hashtbl.mem owned l) then l
    else
      match Hashtbl.find_opt labels l with
      | Some m -> m
      | None ->
          let m = !label in
          incr label;
          Hashtbl.replace labels l m;
          m
  in
  let atom (x : atom) = match x with Var v -> Var (var v) | x -> x in
  let atoms = List.map atom in
  let rhs (r : rhs) : rhs =
    match r with
    | Atom x -> Atom (atom x)
    | Arith (op, x, y, s) -> Arith (op, atom x, atom y, s)
    | Late (op, x, y, s) -> Late (op, atom x, atom y, s)
    | Neg (x, s) -> Neg (atom x, s)
    | Compare (c, x, y) -> Compare (c, atom x, atom y)
    | Not x -> Not (atom x)
    | Tag_of x -> Tag_of (atom x)
    | Field (x, i, n) -> Field (atom x, i, n)
    | Alloc a ->
        Alloc
          {
            a with
            fields = atoms a.fields;
            words = atoms a.words;
            at = Option.map (fun (t, same) -> (atom t, same)) a.at;
          }
    | Alloc_array a ->
        Alloc_array
          { a with elems = atoms a.elems; desc = Option.map atom a.desc }
    | Call (name, xs) -> Call (name, atoms xs)
    | Runtime (rt, xs, s) -> Runtime (rt, atoms xs, s)
    | Load v -> Load (var v)
    | Addr v -> Addr (var v)
    | To_word x -> To_word (atom x)
    | Of_word (x, l) -> Of_word (atom x, l)
    | Global g -> Global g
    | Env_new xs -> Env_new (atoms xs)
    | Env_get (x, n) -> Env_get (atom x, n)
    | Arg (x, n) -> Arg (atom x, n)
    | Block_of (g, x) -> Block_of (g, atom x)
    | Impl (n, xs) -> Impl (n, atoms xs)
    | Install i ->
        Install
          {
            outer = atom i.outer;
            impls = atoms i.impls;
            deps = atom i.deps;
            ndeps = atom i.ndeps;
          }
    | Given g -> Given { g with outer = atom g.outer; caller = atom g.caller }
    | Op_block (x, d, n) -> Op_block (atom x, d, n)
    | Is_unique x -> Is_unique (atom x)
    | Make_struct xs -> Make_struct (atoms xs)
    | Struct_get (x, i) -> Struct_get (atom x, i)
    | Pack ps -> Pack (List.map (fun (x, at, n) -> (atom x, at, n)) ps)
    | Unpack (x, at, n) -> Unpack (atom x, at, n)
    | Hole (x, n) -> Hole (atom x, n)
    | Reset (x, kept) ->
        Reset (atom x, List.map (fun (i, k) -> (i, atom k)) kept)
  in
  let rec block (b : block) = List.map stmt b
  and stmt (s : stmt) : stmt =
    match s with
    | Let (v, r) -> Let (var v, rhs r)
    | Do r -> Do (rhs r)
    | Decl v -> Decl (var v)
    | Set (v, x) -> Set (var v, atom x)
    | Store (v, x) -> Store (var v, atom x)
    | Dup x -> Dup (atom x)
    | Drop x -> Drop (atom x)
    | Dup_word (x, d) -> Dup_word (atom x, atom d)
    | Drop_word (x, d) -> Drop_word (atom x, atom d)
    | Free (x, kept) -> Free (atom x, List.map (fun (i, k) -> (i, atom k)) kept)
    | Free_token x -> Free_token (atom x)
    | Fill (p, x) -> Fill (atom p, atom x)
    | Call_fails c ->
        Call_fails
          {
            result = var c.result;
            fn = c.fn;
            args = atoms c.args;
            error = var c.error;
            on_error = block c.on_error;
          }
    | Call_block c ->
        Call_block
          {
            result = var c.result;
            block = atom c.block;
            ev = atom c.ev;
            args = atoms c.args;
            error = var c.error;
            on_error = Option.map block c.on_error;
          }
    | Call_handler c ->
        Call_handler
          {
            c with
            result = var c.result;
            handler = atom c.handler;
            outer = atom c.outer;
            body = atom c.body;
            desc = atom c.desc;
            error = var c.error;
            on_error = Option.map block c.on_error;
          }
    | If (c, t, e) -> If (atom c, block t, block e)
    | Switch (x, cases, d) ->
        Switch (atom x, List.map (fun (t, b) -> (t, block b)) cases, block d)
    | Loop (l, b) -> Loop (lab l, block b)
    | Break l -> Break (lab l)
    | Joins (d, js) ->
        Joins (block d, List.map (fun (l, j) -> (lab l, block j)) js)
    | Jump l -> Jump (lab l)
    | Catch c ->
        Catch
          {
            label = lab c.label;
            body = block c.body;
            error = var c.error;
            handler = block c.handler;
          }
    | Raise (x, l) -> Raise (atom x, Option.map lab l)
    | Return x -> Return (atom x)
    | Assert (c, site) -> Assert (atom c, site)
    | Panic (site, msg) -> Panic (site, msg)
  in
  (block b, List.map var also)

let fn (f : fn) : fn =
  let plain (v : var) = match v.layout with Cell _ -> false | _ -> true in
  if
    f.result <> Boxed || f.words <> [] || f.inout <> []
    || not (List.for_all plain f.params)
  then f
  else
    let next, label = Rc.fresh_counters f in
    let fresh name layout =
      let v = { id = !next; name; layout } in
      incr next;
      v
    in
    let new_label () =
      let l = !label in
      incr label;
      l
    in
    let lp =
      {
        params = List.map (fun (p : var) -> fresh p.name p.layout) f.params;
        root = fresh "root" Boxed;
        hole = fresh "hole" Ptr;
        go = new_label ();
        next = new_label ();
      }
    in
    let read = reads f.body in
    let taken = ref false in
    let later = turn f ~read ~fresh lp Later taken Other [] f.body in
    if not !taken then f
    else
      let first = turn f ~read ~fresh lp First (ref false) Other [] f.body in
      (* the first turn is a copy, with names of its own, the function's
         parameters among them; the later turns' parameters are bound,
         each turn, to what the call that ended the turn before gave *)
      let first, params = rename ~next ~label f.params first in
      let bind =
        List.map2 (fun p v -> Let (p, Atom (Var v))) f.params lp.params
      in
      let loop = new_label () in
      {
        f with
        params;
        body =
          List.map (fun v -> Decl v) lp.params
          @ [ Decl lp.root; Decl lp.hole ]
          @ [
              Joins
                ( first,
                  [
                    ( lp.go,
                      [
                        Loop (loop, [ Joins (bind @ later, [ (lp.next, []) ]) ]);
                      ] );
                  ] );
            ];
      }

let enabled () = Sys.getenv_opt "REN_NO_TRMC" = None

let program (p : program) : program =
  if enabled () then { p with fns = List.map fn p.fns } else p
