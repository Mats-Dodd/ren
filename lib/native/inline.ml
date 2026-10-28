(* Inlining for reuse (compiler.md, "Native slice"): a release build's
   call of a small function that builds, inlined where the caller frees a
   reuse token after it, so the token reaches the builds.

   Reuse is within a function: a token is the memory of an object the
   function took apart, and only a build in the same function can take
   it. rbtree's `ins` takes a node apart and calls `balance_left` with
   its fields, which builds nodes, and the token of the node `ins` took
   apart is freed after the call. Koka gets the token there by inlining
   `balance-left` into `ins` before Perceus runs: its inliner takes any
   function that costs at most twice `--inline`, 10 by default, within a
   module (Compile/Optimize.hs:81, Options.hs:506), where a cost is a
   call or a constructor applied, and a `match`'s branches but one
   (Core/Core.hs, [costExpr] :888). Lean doesn't: its reset and reuse are
   within a function too (LCNF/ResetReuse.lean), and a token is never
   passed.

   Here it's targeted rather than by size alone. Perceus and reuse run
   once; a call is inlined only where they freed a token after it in the
   same block, unused, and the callee builds a constructor of the token's
   size. Then the program as to_mem.ml made it, with those calls inlined,
   goes through Perceus again. The callee must be small, at most [budget]
   by Koka's measure ([cost]), not the caller nor recursive, and simple:
   it can't fail, has no loops, catches, blocks, handlers or cells, and
   no type variable's words. Each call is inlined once, one level deep.

   Inlining is only an optimization (compiler.md, rule 1): the inlined
   body is the callee's, its parameters bound to the arguments, each
   [Return] a [Set] of the result and a [Jump] past it, so what the
   program computes doesn't change. *)

open Mem

(* Koka's within a module: twice its default `--inline` of 10. *)
let budget = 20

(* What Koka's [costExpr] counts: a call or a build, 1, and each branch of
   a choice but the first. *)
let cost (b : block) =
  let n = ref 0 in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Let (_, (Call _ | Runtime _ | Alloc _ | Alloc_array _))
      | Do (Call _ | Runtime _) ->
          incr n
      | If _ -> incr n
      | Switch (_, cases, _) -> n := !n + List.length cases
      | _ -> ())
    b;
  !n

(* Whether [f] is simple enough to inline into another function. *)
let simple (f : fn) =
  (not f.fails) && f.inout = [] && f.words = []
  && List.for_all
       (fun (v : var) ->
         match v.layout with Cell _ | Word _ -> false | _ -> true)
       f.params
  &&
  let ok = ref true in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Loop _ | Catch _ | Raise _ | Break _ | Call_fails _ | Call_block _
      | Call_handler _ | Store _ ->
          ok := false
      | Let (_, r) | Do r -> (
          match r with
          | Call (name, _) when name = f.name -> ok := false
          | Load _ | Addr _ | Env_new _ | Env_get _ | Arg _ | Block_of _
          | Impl _ | Install _ | Given _ | Op_block _ | To_word _ | Of_word _
          | Reset _ ->
              ok := false
          | _ -> ())
      | _ -> ())
    f.body;
  !ok

(* Whether [f] builds a constructor of [n] fields. *)
let builds n (f : fn) =
  let found = ref false in
  Rc.iter_stmts
    (function
      | Let (_, Alloc { fields; _ }) when List.length fields = n ->
          found := true
      | _ -> ())
    f.body;
  !found

(* The calls Perceus and reuse wasted a token after, in a program they
   placed: each caller's name and the call's result's id. *)
let sites (p : program) : (string * int) list =
  let fns = Hashtbl.create 64 in
  List.iter (fun (f : fn) -> Hashtbl.replace fns f.name f) p.fns;
  List.concat_map
    (fun (g : fn) ->
      let toks = Reuse.token_sizes g in
      let found = ref [] in
      let rec block (b : block) =
        let rec go calls = function
          | [] -> ()
          | s :: rest ->
              let calls =
                match s with
                | Let (r, Call (name, _)) -> (r, name) :: calls
                | Free_token (Var t) -> (
                    match Hashtbl.find_opt toks t.id with
                    | Some n ->
                        List.iter
                          (fun ((r : var), name) ->
                            match Hashtbl.find_opt fns name with
                            | Some f when f.name <> g.name && builds n f ->
                                found := (g.name, r.id) :: !found
                            | _ -> ())
                          calls;
                        calls
                    | None -> calls)
                | _ -> calls
              in
              List.iter block (Rc.blocks s);
              go calls rest
        in
        go [] b
      in
      block g.body;
      List.sort_uniq compare !found)
    p.fns

(* [f]'s body, its variables and labels made fresh in the caller whose
   counters are [next] and [label], its parameters bound to [args], and
   each [Return] a [Set] of [res] and a [Jump] to [exit]. *)
let body ~next ~label (f : fn) (args : atom list) (res : var) exit : block =
  let vars = Hashtbl.create 64 and labels = Hashtbl.create 8 in
  let var (v : var) =
    match Hashtbl.find_opt vars v.id with
    | Some w -> w
    | None ->
        let w = { v with id = !next } in
        incr next;
        Hashtbl.replace vars v.id w;
        w
  in
  let lab l =
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
    | Global g -> Global g
    | Is_unique x -> Is_unique (atom x)
    | Make_struct xs -> Make_struct (atoms xs)
    | Struct_get (x, i) -> Struct_get (atom x, i)
    | Pack ps -> Pack (List.map (fun (x, at, n) -> (atom x, at, n)) ps)
    | Unpack (x, at, n) -> Unpack (atom x, at, n)
    | Load _ | Addr _ | To_word _ | Of_word _ | Env_new _ | Env_get _ | Arg _
    | Block_of _ | Impl _ | Install _ | Given _ | Op_block _ | Reset _ | Hole _ ->
        failwith "bug: inline: a statement [simple] doesn't allow"
  in
  let rec block (b : block) = List.concat_map stmt b
  and stmt (s : stmt) : stmt list =
    match s with
    | Let (v, r) ->
        let r = rhs r in
        [ Let (var v, r) ]
    | Do r -> [ Do (rhs r) ]
    | Decl v -> [ Decl (var v) ]
    | Set (v, x) -> [ Set (var v, atom x) ]
    | Dup x -> [ Dup (atom x) ]
    | Drop x -> [ Drop (atom x) ]
    | Dup_word (x, d) -> [ Dup_word (atom x, atom d) ]
    | Drop_word (x, d) -> [ Drop_word (atom x, atom d) ]
    | Free (x, kept) ->
        [ Free (atom x, List.map (fun (i, k) -> (i, atom k)) kept) ]
    | Free_token x -> [ Free_token (atom x) ]
    | If (c, t, e) -> [ If (atom c, block t, block e) ]
    | Switch (x, cases, d) ->
        [ Switch (atom x, List.map (fun (t, b) -> (t, block b)) cases, block d) ]
    | Joins (d, js) ->
        let js = List.map (fun (l, j) -> (lab l, j)) js in
        [ Joins (block d, List.map (fun (l, j) -> (l, block j)) js) ]
    | Jump l -> [ Jump (lab l) ]
    | Return x -> [ Set (res, atom x); Jump exit ]
    | Assert (c, site) -> [ Assert (atom c, site) ]
    | Panic (site, msg) -> [ Panic (site, msg) ]
    | Store _ | Call_fails _ | Call_block _ | Call_handler _ | Loop _ | Break _
    | Catch _ | Raise _ | Fill _ ->
        failwith "bug: inline: a statement [simple] doesn't allow"
  in
  (* the arguments are the caller's: bound, not renamed *)
  List.map2 (fun (p : var) (x : atom) -> Let (var p, Atom x)) f.params args
  @ block f.body

(* The program, as to_mem.ml made it, with the calls [sites] names
   inlined, where the callee is simple and within the budget. *)
let program (sites : (string * int) list) (p : program) : program =
  let fns = Hashtbl.create 64 in
  List.iter (fun (f : fn) -> Hashtbl.replace fns f.name f) p.fns;
  let inlinable g name =
    match Hashtbl.find_opt fns name with
    | Some f when f.name <> g && simple f && cost f.body <= budget -> Some f
    | _ -> None
  in
  let fn (g : fn) =
    if not (List.exists (fun (c, _) -> c = g.name) sites) then g
    else
      let next, label = Rc.fresh_counters g in
      let rec block (b : block) =
        List.concat_map
          (fun s ->
            match s with
            | Let (r, Call (name, args)) when List.mem (g.name, r.id) sites -> (
                match inlinable g.name name with
                | Some f ->
                    let res = { r with id = !next; name = "$inlined" } in
                    incr next;
                    let exit = !label in
                    incr label;
                    [
                      Decl res;
                      Joins (body ~next ~label f args res exit, [ (exit, []) ]);
                      Let (r, Atom (Var res));
                    ]
                | None -> [ s ])
            | s -> [ Rc.map_blocks block s ])
          b
      in
      { g with body = block g.body }
  in
  { p with fns = List.map fn p.fns }
