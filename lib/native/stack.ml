(* Stack promotion (H8): an object a function builds that never outlives
   the call is kept in the function's frame, not on the heap, after
   Swift's StackPromotion.swift and Go's escape analysis
   (cmd/compile/internal/escape). A release build's pass, between
   Perceus's counting (rc.ml) and reuse (reuse.ml).

   What's promoted is a class of variables: an [Alloc] and the other
   names it goes by, a [Let] of it, or a [Set] of a variable declared
   first, whose every definition is one of those, or a constructor
   without fields (a scalar, never counted). It's promoted if no use of
   any of them lets the object outlive the frame. A use that doesn't:
   - reading a field or its tag, or asking if it's unique;
   - the drop Perceus placed where it dies, plain or specialized;
   - passing it to a parameter that doesn't let it escape: one a
     function only the program's own calls reach borrows (borrow.ml), and
     whose own uses, by these same rules, are all of these. That's a
     greatest fixpoint over the program, as Go's is over its graph
     (escape/solve.go) and Swift's argument effects are
     (EscapeUtils.swift, [walkDownArgument]);
   - a runtime function that only reads it.
   Anything else lets it escape: returning or raising it, storing it in
   an object, an array or a cell, counting it again ([Dup], which means
   some use took a reference), making a word of it, or giving it to a
   block or a handler, whose code is called through a pointer.

   One escape is taken back: a function whose result is always the one
   object it builds, or a constructor without fields, and which lets it
   escape no other way, gets a second version that builds it in memory
   its caller gives, the caller's frame (destination passing; what Go
   gets by inlining such a function first, escape.go's comment on
   [inlining]). A call's result is then a definition like an [Alloc] in
   the caller, promoted by the same rules.

   Each object of a class is built once per entry of its storage's
   scope, the frame: an [Alloc] in a loop is promoted only if every
   variable of its class is defined in that loop, so no value of one
   iteration is alive when the next builds over it (Swift's check for a
   back edge from the inner liverange to the outer, StackPromotion.swift,
   [hasControlFlowEdge]).

   Why it's sound. A promoted object's count starts at 1 and stays 1:
   nothing counts it again, so Perceus's [Is_unique] is still true and
   its drop is still where the object dies, which emit_c.ml turns into
   dropping its fields, the ones not kept, and no free. A callee given it
   borrows it, so never drops it, and doesn't keep it, by the fixpoint.
   Its fields are counted objects as before, owned by it until it dies.
   Like the rest of the counting, it's only an optimization: what the
   program computes doesn't depend on it.

   For measuring it (H8): `REN_NO_STACK` in the environment turns the
   pass off, `REN_NO_SLOT` only its second versions, and
   `REN_STACK_REPORT` prints each allocation site and call it looked at,
   and why what it didn't promote escapes, to stderr. *)

open Mem

(* Why a class isn't promoted, for [report]. *)
type why = string

(* ---- union-find over a function's variable ids ---- *)

let rec find uf id =
  match Hashtbl.find_opt uf id with
  | Some p when p <> id ->
      let r = find uf p in
      Hashtbl.replace uf id r;
      r
  | _ -> id

let union uf a b =
  let ra = find uf a and rb = find uf b in
  if ra <> rb then Hashtbl.replace uf ra rb

(* ---- how a statement uses each object it names ---- *)

type use = Local | Returned | Escape of why

(* The variables followed: objects, and words, which may be one. *)
let tracked (l : layout) = match l with Boxed | Word _ -> true | _ -> false

(* The runtime's functions that only read an object they're given. *)
let rt_reads (rt : rt) =
  match rt with
  | Array_len | Array_get _ | Str_len | Str_concat | Str_eq | Show_int
  | Show_float | Show_bool | Float_of_int | Float_sqrt | Float_round
  | Float_truncate | Wrapping _ | Wrapping_neg | Console_write | Console_error
  | Show_any | Equal_any | Compare_any ->
      true
  | Array_set _ | Array_push _ | Array_set_taking _ | Array_push_taking _
  | Op_any _ | Value_any _ | New_desc _ ->
      false

(* Each counted variable [s] itself names, with how it uses it, and the
   variable a [Let] or a [Set] makes another name for it. [local f i]
   says whether [f]'s [i]-th parameter lets nothing escape. *)
let uses ~local (s : stmt) : (var * use) list * (var * var) list =
  let vars u xs =
    List.filter_map
      (fun (x : atom) ->
        match x with Var v when tracked v.layout -> Some (v, u) | _ -> None)
      xs
  in
  let call f args =
    List.concat
      (List.mapi
         (fun i (x : atom) ->
           match x with
           | Var v when tracked v.layout ->
               if local f i then [ (v, Local) ]
               else [ (v, Escape ("given to `" ^ f ^ "`, which keeps it")) ]
           | _ -> [])
         args)
  in
  let rhs (r : rhs) =
    let all u = vars u (Rc.stmt_atoms (Do r)) in
    match r with
    | Field (x, _, _) | Tag_of x | Is_unique x -> vars Local [ x ]
    | Call (f, args) -> call f args
    | Runtime (rt, args, _) ->
        vars
          (if rt_reads rt then Local
           else Escape ("given to the runtime's " ^ show_rt rt))
          args
    | Alloc _ -> all (Escape "stored in an object")
    | Alloc_array _ -> all (Escape "stored in an array")
    | To_word _ -> all (Escape "made a word")
    | Reset _ -> all (Escape "reused")
    | _ -> all (Escape "used otherwise")
  in
  match s with
  | Let (v, Atom (Var x)) when x.layout = Boxed -> ([ (x, Local) ], [ (v, x) ])
  | Set (v, Var x) when x.layout = Boxed -> ([ (x, Local) ], [ (v, x) ])
  | Let (w, To_word (Var x)) when x.layout = Boxed ->
      ([ (x, Local) ], [ (w, x) ])
  | Drop_word (x, _) -> (vars (Escape "dropped as a word") [ x ], [])
  | Let (_, r) | Do r -> (rhs r, [])
  | Drop x -> (vars Local [ x ], [])
  | Free (x, kept) -> (vars Local (x :: List.map snd kept), [])
  | Call_fails { fn; args; _ } -> (call fn args, [])
  | Dup x -> (vars (Escape "counted again") [ x ], [])
  | Return x -> (vars Returned [ x ], [])
  | Raise (x, _) -> (vars (Escape "raised") [ x ], [])
  | Store (_, x) -> (vars (Escape "stored in a cell") [ x ], [])
  | Call_block { args; _ } -> (vars (Escape "given to a block") args, [])
  | Call_handler { body; _ } -> (vars (Escape "given to a handler") [ body ], [])
  | s -> (vars (Escape "used otherwise") (Rc.stmt_atoms s), [])

(* How a variable is defined, for whether its class is only objects the
   function builds. *)
type def =
  | Built of int  (** an [Alloc] of these many fields, not in a token *)
  | Slot of string
      (** the result of a call of a function that can build it in the caller's
          frame ([builders]) *)
  | Named  (** another name for one of the class, or a [Decl] *)
  | Scalar  (** a constructor without fields: never counted *)
  | Other of why

(* ---- one function ---- *)

type cls = {
  mutable escape : why option;  (** the first use that lets it escape *)
  mutable returned : bool;
  mutable defs : (var * def * int list) list;
      (** each member's definitions, with the loops around each *)
}

type info = {
  uf : (int, int) Hashtbl.t;
  classes : (int, cls) Hashtbl.t;  (** by the class's root id *)
}

let class_of info (v : var) = Hashtbl.find_opt info.classes (find info.uf v.id)

(* [builds f] says whether [f] has a version that builds its result in
   the caller's frame. *)
let analyze ~local ~builds (f : fn) : info =
  let uf = Hashtbl.create 64 in
  let defs = ref [] and useds = ref [] in
  let def loops v d = defs := (v, d, loops) :: !defs in
  List.iter (fun (v : var) -> def [] v (Other "a parameter")) f.params;
  let called loops (v : var) name =
    def loops v (if builds name then Slot name else Other "a call's result")
  in
  let rec walk loops (b : block) =
    List.iter
      (fun s ->
        let us, names = uses ~local s in
        useds := us @ !useds;
        List.iter (fun ((v : var), (x : var)) -> union uf v.id x.id) names;
        (match s with
        | Let (v, Atom (Var x)) when x.layout = Boxed -> def loops v Named
        | Set (v, Var x) when x.layout = Boxed -> def loops v Named
        | Let (w, To_word (Var x)) when x.layout = Boxed -> def loops w Named
        | Decl v -> def loops v Named
        | Let (v, Alloc { fields; at = None; _ }) when fields <> [] ->
            def loops v (Built (List.length fields))
        | Let (v, Atom (Scalar_ctor _)) | Set (v, Scalar_ctor _) ->
            def loops v Scalar
        | Let (v, Call (name, _)) -> called loops v name
        | Call_fails { result; fn; error; _ } ->
            called loops result fn;
            def loops error (Other "an error")
        | Let (v, _) | Set (v, _) ->
            def loops v (Other "a value from elsewhere")
        | Call_block { result; error; _ } | Call_handler { result; error; _ } ->
            def loops result (Other "a block's result");
            def loops error (Other "an error")
        | Catch { error; _ } -> def loops error (Other "an error")
        | _ -> ());
        let inner = match s with Loop (l, _) -> l :: loops | _ -> loops in
        List.iter (walk inner) (Rc.blocks s))
      b
  in
  walk [] f.body;
  let classes = Hashtbl.create 32 in
  let cls_of (v : var) =
    let r = find uf v.id in
    match Hashtbl.find_opt classes r with
    | Some c -> c
    | None ->
        let c = { escape = None; returned = false; defs = [] } in
        Hashtbl.replace classes r c;
        c
  in
  List.iter
    (fun ((v : var), d, loops) ->
      if tracked v.layout then
        let c = cls_of v in
        c.defs <- (v, d, loops) :: c.defs)
    !defs;
  List.iter
    (fun ((v : var), u) ->
      let c = cls_of v in
      match u with
      | Local -> ()
      | Returned -> c.returned <- true
      | Escape why -> if c.escape = None then c.escape <- Some why)
    !useds;
  { uf; classes }

let is_built d = match d with Built _ | Slot _ -> true | _ -> false

(* Whether a class's objects can be kept in a frame, if it's not
   returned ([returns]) or if it is, and if not, why. *)
let keepable ~returns (c : cls) : (unit, why) result =
  let built =
    List.filter_map
      (fun (_, d, loops) -> if is_built d then Some loops else None)
      c.defs
  in
  let other =
    List.find_map
      (fun (_, d, _) -> match d with Other w -> Some w | _ -> None)
      c.defs
  in
  match (c.escape, other) with
  | _ when built = [] -> Error "builds nothing"
  | Some w, _ -> Error w
  | _ when c.returned && not returns -> Error "returned"
  | None, Some w -> Error ("mixed with " ^ w)
  | None, None ->
      (* each object built in a loop: every name of it defined in the
         loop too, so none is alive when the loop comes round *)
      if
        List.for_all
          (fun loops ->
            match loops with
            | [] -> true
            | l :: _ -> List.for_all (fun (_, _, ls) -> List.mem l ls) c.defs)
          built
      then Ok ()
      else Error "alive across a loop's iterations"

(* ---- functions that build their result in their caller's frame ---- *)

(* Where a statement is: for each statement on the way to it, its index
   in its block and which of its blocks the way goes into, with whether
   that statement is an `if` or a `switch`, whose blocks no run goes
   through two of; then its own index. *)
type place = (int * (int * bool) option) list

(* Each statement of [b] and those in it, with its place and the block
   it's in. *)
let places (b : block) : (stmt * place * block) list =
  let acc = ref [] in
  let rec go prefix (b : block) =
    List.iteri
      (fun i s ->
        acc := (s, List.rev ((i, None) :: prefix), b) :: !acc;
        let arms = match s with If _ | Switch _ -> true | _ -> false in
        List.iteri
          (fun k sub -> go ((i, Some (k, arms)) :: prefix) sub)
          (Rc.blocks s))
      b
  in
  go [] b;
  !acc

(* Whether no run reaches both of two statements, at [p] in the block
   [pb] and at [q] in [qb]. Either they're in two blocks of one `if` or
   `switch`, or one is in a block of one, [s], which ends by leaving
   what's around [s]: returning, raising, or a jump, a break or a raise
   to a label of something [s] is in the body of; and the other is after
   [s] in [s]'s block. Nothing after the first comes back to [s]'s
   block, then, since a jump goes only forward, to the end of what it's
   in. [stmt_at] finds the statement at a place. *)
let exclusive ~stmt_at (p, pb) (q, qb) =
  (* [prefix], reversed, is the way to [s]'s block: whether [l] is the
     label of a statement on it whose body the way goes into *)
  let around l prefix =
    let rec go = function
      | [] -> false
      | (i, Some (k, _)) :: rest -> (
          match stmt_at (List.rev ((i, None) :: rest)) with
          | Some (Joins (_, js)) when k = 0 && List.mem_assoc l js -> true
          | Some (Loop (l', _)) when l' = l -> true
          | Some (Catch { label; _ }) when k = 0 && label = l -> true
          | _ -> go rest)
      | (_, None) :: rest -> go rest
    in
    go prefix
  in
  let leaves (b : block) prefix =
    match List.rev b with
    | (Return _ | Panic _ | Raise (_, None)) :: _ -> true
    | (Jump l | Break l | Raise (_, Some l)) :: _ -> around l prefix
    | _ -> false
  in
  let rec go prefix p q =
    match (p, q) with
    | x :: p, y :: q when x = y -> go (x :: prefix) p q
    | (i, Some (a, true)) :: _, (j, Some (b, true)) :: _ when i = j -> a <> b
    | (i, Some (_, true)) :: _, (j, _) :: _ when i < j -> leaves pb prefix
    | (i, _) :: _, (j, Some (_, true)) :: _ when j < i -> leaves qb prefix
    | _ -> false
  in
  go [] p q

(* The objects [f] builds in its caller's frame, if it has a version that
   does: every value it returns is a constructor without fields or of
   one class, whose objects are all built by [Alloc]s, no two in one
   run, and which lets them escape no other way. *)
let builder ~local (f : fn) : var list option =
  if f.result <> Boxed then None
  else
    let info = analyze ~local ~builds:(fun _ -> false) f in
    let returned = ref [] and ok = ref true in
    Rc.iter_stmts
      (function
        | Return (Var v) -> (
            match class_of info v with
            | Some c ->
                if not (List.memq c !returned) then returned := c :: !returned
            | None -> ok := false)
        | Return (Scalar_ctor _) -> ()
        | Return _ -> ok := false
        | _ -> ())
      f.body;
    match (!ok, !returned) with
    | true, [ c ] -> (
        let built =
          List.filter_map
            (fun ((v : var), d, _) ->
              match d with Built _ -> Some v | _ -> None)
            c.defs
        in
        let ps = places f.body in
        let stmt_at place =
          List.find_map (fun (s, p, _) -> if p = place then Some s else None) ps
        in
        let at =
          List.filter_map
            (fun (s, place, b) ->
              match s with
              | Let (v, Alloc _)
                when List.exists (fun (w : var) -> w.id = v.id) built ->
                  Some (place, b)
              | _ -> None)
            ps
        in
        let rec apart = function
          | [] -> true
          | p :: rest -> List.for_all (exclusive ~stmt_at p) rest && apart rest
        in
        match keepable ~returns:true c with
        | Ok () when built <> [] && apart at -> Some built
        | _ -> None)
    | _ -> None

(* ---- the program ---- *)

let enabled () = Sys.getenv_opt "REN_NO_STACK" = None

(* Each allocation site and call, by function, with whether it was
   promoted, for `REN_STACK_REPORT`. *)
let report (p : program) ~local ~builds =
  List.iter
    (fun (f : fn) ->
      let info = analyze ~local ~builds f in
      Hashtbl.iter
        (fun _ c ->
          List.iter
            (fun ((v : var), d, _) ->
              let say what =
                Printf.eprintf "stack %s %s/%d (%s): %s\n" f.name v.name v.id
                  what
                  (match keepable ~returns:false c with
                  | Ok () -> "promoted"
                  | Error w -> "heap, " ^ w)
              in
              match d with
              | Built n -> say (Printf.sprintf "%d fields" n)
              | Slot g -> say ("built by " ^ g)
              | _ -> ())
            c.defs)
        info.classes)
    p.fns

let program (p : program) : program =
  if not (enabled ()) then p
  else
    let inferred = Borrow.inferred p in
    (* whether each parameter lets nothing escape: start from every
       borrowed one of a function whose modes were inferred, and take
       away each one a use lets escape, until nothing changes *)
    let summary = Hashtbl.create 64 in
    List.iter
      (fun (f : fn) ->
        let borrowed =
          List.length f.modes = List.length f.params && inferred f
        in
        Hashtbl.replace summary f.name
          (Array.of_list
             (List.map2
                (fun (v : var) (m : mode) ->
                  borrowed && v.layout = Boxed && m = Borrowed)
                f.params
                (if borrowed then f.modes
                 else List.map (fun _ -> Owned) f.params))))
      p.fns;
    let local name i =
      match Hashtbl.find_opt summary name with
      | Some a when i < Array.length a -> a.(i)
      | _ -> false
    in
    let rec fix () =
      let changed = ref false in
      List.iter
        (fun (f : fn) ->
          let a = Hashtbl.find summary f.name in
          if Array.exists Fun.id a then
            let info = analyze ~local ~builds:(fun _ -> false) f in
            List.iteri
              (fun i (v : var) ->
                if a.(i) then
                  match class_of info v with
                  | Some { escape = None; returned = false; _ } -> ()
                  | _ ->
                      a.(i) <- false;
                      changed := true)
              f.params)
        p.fns;
      if !changed then fix ()
    in
    fix ();
    (* the functions that can build their result in their caller's frame:
       only the program's own calls reach them, so each call is known *)
    let builders = Hashtbl.create 16 in
    if Sys.getenv_opt "REN_NO_SLOT" = None then
      List.iter
        (fun (f : fn) ->
          if inferred f then
            match builder ~local f with
            | Some v -> Hashtbl.replace builders f.name v
            | None -> ())
        p.fns;
    let builds name = Hashtbl.mem builders name in
    if Sys.getenv_opt "REN_STACK_REPORT" <> None then (
      Hashtbl.iter
        (fun name _ ->
          Printf.eprintf "stack %s: builds its result in its caller's frame\n"
            name)
        builders;
      report p ~local ~builds);
    (* the second versions some caller's frame is given to *)
    let used = Hashtbl.create 16 in
    let fn (f : fn) =
      let info = analyze ~local ~builds f in
      let stack =
        Hashtbl.fold
          (fun _ c acc ->
            match keepable ~returns:false c with
            | Ok () ->
                List.iter
                  (fun (_, d, _) ->
                    match d with Slot g -> Hashtbl.replace used g () | _ -> ())
                  c.defs;
                List.map (fun ((v : var), _, _) -> v.id) c.defs @ acc
            | Error _ -> acc)
          info.classes []
      in
      (info, { f with stack = List.sort_uniq compare stack })
    in
    let fns = List.map fn p.fns in
    let slot (info, (f : fn)) =
      match Hashtbl.find_opt builders f.name with
      | Some v when Hashtbl.mem used f.name ->
          let c = Option.get (class_of info (List.hd v)) in
          {
            f with
            slot =
              Some
                ( List.map (fun (w : var) -> w.id) v,
                  List.map (fun ((w : var), _, _) -> w.id) c.defs );
          }
      | _ -> f
    in
    { p with fns = List.map slot fns }
