(* Loops cloned per handler (foundations.md, decision 4; compiler.md,
   "Dispatch (step 4)"): in a release build, a loop that calls a method
   on a description it doesn't change is copied once for each handler
   the description can have, when that's two to four and the loop fits
   [budget], each copy under a test of the tag before the loop, and in
   each copy the sites on that description are known to be that
   handler's, so dispatch.ml lowers each to a direct call that clang can
   inline, and the test leaves the loop.

   clang at -O2, Ren's release level, never unswitches, so the switch
   stays in the loop: 14 instructions a call against 8 in
   research/dispatch.md's (b), and 2.7× the time in a loop the copy lets
   it vectorize. Ren knows what clang doesn't: a description is immutable,
   so its tag can't change in the loop.

   It's sound because each copy runs only when the test before it says
   the description has that copy's handler, or, for the last, when it
   has none of the others, and the description is the one the loop
   reads at each site: a variable defined before the loop, which the
   function never [Set]s, or one the loop copies from it ([Let] of an [Atom]). Its
   handler is one of those that implement every dependency a site calls
   it as, since a description of [D] is made only by a handler of [D];
   so the last copy's is the one left. Mem Lint checks every [known]
   site is under such tests ([Mem_lint], "known handlers"). No
   suspension exists before stage 11a, so no copy crosses one.

   A copy's own loops aren't cloned again, so a loop grows at most
   [max_arms] times. It runs before Perceus (driver.ml), so counting is
   placed in each copy for the calls it makes, after [Dispatch.prune]
   has dropped the install a known stateless call never takes. *)

open Mem
module Ids = Set.Make (Int)

let budget = Dispatch.clone_budget

let rec size (b : block) =
  List.fold_left (fun n s -> n + 1 + List.fold_left (fun n b -> n + size b) 0 (Rc.blocks s)) 0 b

(* [b] with the variables and labels it defines made fresh, from the
   counters [next] and [label], and each site on [root], or a copy of it
   [aliases] has, known to be [h]'s. *)
let copy ~next ~label ~(defined : Ids.t) ~(labels : Ids.t) ~root ~h (b : block) =
  let vars = Hashtbl.create 64 and labs = Hashtbl.create 8 in
  let var (v : var) =
    if not (Ids.mem v.id defined) then v
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
    if not (Ids.mem l labels) then l
    else
      match Hashtbl.find_opt labs l with
      | Some m -> m
      | None ->
          let m = !label in
          incr label;
          Hashtbl.replace labs l m;
          m
  in
  (* the copies of [root] in [b], by their ids in [b] *)
  let copies = Hashtbl.create 8 in
  let is_root (x : atom) =
    match x with Var v -> v.id = root || Hashtbl.mem copies v.id | _ -> false
  in
  let atom (x : atom) = match x with Var v -> Var (var v) | x -> x in
  let atoms = List.map atom in
  let key k = { k with kargs = atoms k.kargs } in
  let rhs (r : rhs) : rhs =
    match r with
    | Atom x -> Atom (atom x)
    | Arith (op, x, y, s) -> Arith (op, atom x, atom y, s)
    | Neg (x, s) -> Neg (atom x, s)
    | Compare (c, x, y) -> Compare (c, atom x, atom y)
    | Not x -> Not (atom x)
    | Tag_of x -> Tag_of (atom x)
    | Obj_tag x -> Obj_tag (atom x)
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
        Alloc_array { a with elems = atoms a.elems; desc = Option.map atom a.desc }
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
    | Arg_borrowed (x, n) -> Arg_borrowed (atom x, n)
    | Block_of (f, x) -> Block_of (f, atom x)
    | Impl (d, xs) -> Impl (d, atoms xs)
    | Install { outer; impls; deps; ndeps } ->
        Install
          { outer = atom outer; impls = atoms impls; deps = atom deps; ndeps = atom ndeps }
    | Given { outer; caller; deps } ->
        Given
          {
            outer = atom outer;
            caller = atom caller;
            deps = List.map (fun (d, xs) -> (d, atoms xs)) deps;
          }
    | Method_of m ->
        let known = if m.known = None && is_root m.mdesc then Some h else m.known in
        Method_of { m with mdesc = atom m.mdesc; known }
    | Has_code x -> Has_code (atom x)
    | Tag_is (x, k) -> Tag_is (atom x, k)
    | Op_block (ev, d, xs, op) -> Op_block (atom ev, d, atoms xs, op)
    | Is_unique x -> Is_unique (atom x)
    | Make_struct xs -> Make_struct (atoms xs)
    | Struct_get (x, i) -> Struct_get (atom x, i)
    | Pack ps -> Pack (List.map (fun (x, at, n) -> (atom x, at, n)) ps)
    | Unpack (x, at, n) -> Unpack (atom x, at, n)
    | Hole (x, n) -> Hole (atom x, n)
    | Reset (x, kept) -> Reset (atom x, List.map (fun (i, k) -> (i, atom k)) kept)
  in
  let rec block (b : block) = List.map stmt b
  and stmt (s : stmt) : stmt =
    match s with
    | Let (v, (Atom x as r)) when is_root x ->
        (* a copy of the description: its sites are known too *)
        Hashtbl.replace copies v.id ();
        Let (var v, rhs r)
    | Let (v, r) ->
        let r = rhs r in
        Let (var v, r)
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
    | Call_fails { result; fn; args; error; on_error } ->
        let args = atoms args in
        Call_fails
          { result = var result; fn; args; error = var error; on_error = block on_error }
    | Call_block { result; block = b; ev; args; error; on_error; borrowed } ->
        let b = atom b and ev = atom ev and args = atoms args in
        Call_block
          {
            result = var result;
            block = b;
            ev;
            args;
            error = var error;
            on_error = Option.map block on_error;
            borrowed;
          }
    | Call_handler c ->
        Call_handler
          {
            result = var c.result;
            handler = atom c.handler;
            outer = atom c.outer;
            body = atom c.body;
            desc = atom c.desc;
            deps = List.map key c.deps;
            error = var c.error;
            on_error = Option.map block c.on_error;
            hsite = c.hsite;
          }
    | If (c, t, e) -> If (atom c, block t, block e)
    | Switch (x, cases, d) ->
        Switch (atom x, List.map (fun (t, b) -> (t, block b)) cases, block d)
    | Loop (l, b) -> Loop (lab l, block b)
    | Break l -> Break (lab l)
    | Joins (b, js) ->
        let js = List.map (fun (l, j) -> (lab l, j)) js in
        Joins (block b, List.map (fun (l, j) -> (l, block j)) js)
    | Jump l -> Jump (lab l)
    | Catch { label = l; body; error; handler } ->
        Catch { label = lab l; body = block body; error = var error; handler = block handler }
    | Raise (x, l) -> Raise (atom x, Option.map lab l)
    | Return x -> Return (atom x)
    | Assert (c, s) -> Assert (atom c, s)
    | Panic (s, m) -> Panic (s, m)
  in
  block b

(* The description each site in [b] calls a method on, followed back
   through the copies [b] makes of it to a variable it doesn't define,
   with the site: (root, meth). *)
let sites ~(defined : Ids.t) (b : block) =
  let alias = Hashtbl.create 16 in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Let (v, Atom (Var w)) -> Hashtbl.replace alias v.id w.id
      | _ -> ())
    b;
  let rec root id =
    if Ids.mem id defined then Option.bind (Hashtbl.find_opt alias id) root
    else Some id
  in
  let acc = ref [] in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Let (_, Method_of ({ mdesc = Var x; known = None; _ } as m)) -> (
          match root x.id with Some r -> acc := (r, m) :: !acc | None -> ())
      | _ -> ())
    b;
  List.rev !acc

(* The variables [b] [Set]s, stores into or takes the address of. *)
let changed (b : block) =
  let acc = ref Ids.empty in
  Rc.iter_stmts
    (fun s ->
      match s with
      | Set (v, _) | Let (_, Addr v) | Store (v, _) -> acc := Ids.add v.id !acc
      | _ -> ())
    b;
  !acc

(* The variable [id] of [f], defined before a loop in it. *)
let var_of (f : fn) id =
  let found = ref (List.find_opt (fun (v : var) -> v.id = id) f.params) in
  Rc.iter_stmts
    (fun s ->
      List.iter
        (fun (v : var) -> if v.id = id then found := Some v)
        (Hoist.mentions s))
    f.body;
  match !found with
  | Some v -> v
  | None -> failwith "bug: clone: a description defined nowhere"

let program (p : program) : program =
  let t = Dispatch.make p in
  let notes = ref [] in
  let fn (f : fn) =
    let next, label = Rc.fresh_counters f in
    (* a description the function changes anywhere isn't one the loop's
       test can speak for, as Mem Lint checks *)
    let changed = changed f.body in
    let rec block (b : block) = List.concat_map stmt b
    and stmt (s : stmt) =
      match s with
      | Loop (l, b) -> (
          let defined, labels = Hoist.defined b in
          let roots =
            List.filter (fun (r, _) -> not (Ids.mem r changed)) (sites ~defined b)
          in
          (* the description with the most sites, and the handlers it can
             have: those of every dependency it's called as *)
          let candidates =
            List.sort_uniq compare (List.map fst roots)
            |> List.map (fun r ->
                   let ms = List.filter_map (fun (r', m) -> if r' = r then Some m else None) roots in
                   let hs =
                     List.fold_left
                       (fun hs (m : meth) ->
                         List.filter
                           (fun (h : handler) -> List.memq h (Dispatch.reach t m.mdep))
                           hs)
                       (Dispatch.reach t (List.hd ms).mdep)
                       ms
                   in
                   (r, ms, hs))
            |> List.filter (fun (_, _, hs) ->
                   let n = List.length hs in
                   n >= 2 && n <= Dispatch.max_arms)
            |> List.stable_sort (fun (_, a, _) (_, b, _) ->
                   compare (List.length b) (List.length a))
          in
          match candidates with
          | [] -> [ Loop (l, block b) ]
          | (r, ms, hs) :: _ ->
              let n = size b in
              let note cdone =
                notes :=
                  {
                    csite = (List.hd ms).msite;
                    chandlers = List.map (fun (h : handler) -> h.hid) hs;
                    csize = n;
                    cdone;
                  }
                  :: !notes
              in
              if n > budget then (
                note false;
                [ Loop (l, block b) ])
              else (
                note true;
                let labels = Ids.add l labels in
                let desc = var_of f r in
                let copy_for (h : handler) =
                  match
                    copy ~next ~label ~defined ~labels ~root:r ~h:h.hid
                      [ Loop (l, b) ]
                  with
                  | [ s ] -> s
                  | _ -> assert false
                in
                let rec chain = function
                  | [] -> []
                  | [ h ] -> [ copy_for h ]
                  | (h : handler) :: rest ->
                      let c = { id = !next; name = "$is_" ^ h.hshow; layout = Bool } in
                      incr next;
                      [
                        Let (c, Tag_is (Var desc, h.hid));
                        If (Var c, [ copy_for h ], chain rest);
                      ]
                in
                chain hs))
      | s -> [ Rc.map_blocks block s ]
    in
    { f with body = block f.body }
  in
  let fns = List.map fn p.fns in
  { p with fns; clones = List.rev !notes }
