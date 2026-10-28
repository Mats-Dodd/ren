(* Dispatch over descriptions, in a release build (foundations.md,
   decision 4; compiler.md, "Dispatch (step 4)").

   A release build sees the whole program, so the handlers that implement
   a dependency are a closed set, the program's [handlers] whose [hdeps]
   name it, and a description of the dependency has the tag of one of
   them. An operation called as a method on a description ([Method_of])
   can only reach that set, and is lowered by how many reach it:

   - one: a direct call of its method, which clang may inline, and the
     tag is never read;
   - two to four: compare-and-branch on the tag, each arm a direct call,
     not a jump table, which on the M4 cost twice the branches at four
     arms with shuffled data (research/dispatch.md, (a));
   - more than four, or a site in an arm of a handler of the same
     dependency, recursion through it: a call through the set's own
     table, indexed by the tag. Above four arms an inline jump table was
     5 to 15% slower than such a call, and one switch holding every arm
     of a recursive interpreter up to 53% slower ((a), (d)). For a
     dependency with one operation whose handlers are all stateless and
     implement nothing else, the tag is the arm's code itself, and the
     call goes through it: the fastest lowering measured at 8 or more
     handlers.

   A handler with state has no method; a call reaches it by installing it
   (to_mem.ml, [method_call]), which [Has_code] chooses, and here that's a
   test of the tag too, or a constant where the set says.

   Every lowering calls the code a debug build's record lookup would
   find for the same tag, so each is sound if the tag is one of the set:
   a description of [D] is made only by a handler of [D] ([Handler_tag]
   in to_mem.ml's [handler]), and its tag never changes. clone.ml copies
   a loop once for each handler a description in it can have, under a
   [Tag_is] test, and marks each site of it [known]: there the call is a
   direct one. *)

open Mem

(* The arms a site inlines at most (foundations.md, decision 4). *)
let max_arms = 4

(* The statements a copy of a loop clone.ml makes may have, counted
   through its nested blocks: foundations.md leaves the budget open. 200
   is about twice the largest loop of bench/native's kernels, and copies
   at most [max_arms] of them. *)
let clone_budget = 200

type lowering =
  | Direct of handler
      (** the one handler that reaches it, or the one its loop's copy is for *)
  | Arms of handler list  (** the stateless handlers, compared in turn *)
  | Table  (** a call through the set's table, indexed by the tag *)
  | Code  (** a call through the tag, which is the arm's code *)
  | Installed  (** no handler that reaches it is stateless *)

type t = {
  reach : (int, handler list) Hashtbl.t;
      (** for each dependency, the handlers that implement it, by [hid] *)
  code : (int, string) Hashtbl.t;
      (** the handlers whose tag is their method's code, and that code *)
  code_deps : (int, unit) Hashtbl.t;  (** the dependencies whose are *)
  ops : (int, int) Hashtbl.t;  (** how many operations each dependency has *)
}

let reach t dep = Option.value ~default:[] (Hashtbl.find_opt t.reach dep)

(* [h]'s method for the operation [op] of [dep], if it's stateless. *)
let method_of (h : handler) dep op =
  List.find_map
    (fun (d, o, f) -> if d = dep && o = op then Some f else None)
    h.methods

let make (p : program) =
  let reach = Hashtbl.create 16 in
  List.iter
    (fun (h : handler) ->
      List.iter
        (fun d ->
          Hashtbl.replace reach d
            (Option.value ~default:[] (Hashtbl.find_opt reach d) @ [ h ]))
        h.hdeps)
    p.handlers;
  let ops = Hashtbl.create 16 in
  List.iteri (fun i (d : dep_info) -> Hashtbl.replace ops i (List.length d.dops)) p.dep_infos;
  let code = Hashtbl.create 16 and code_deps = Hashtbl.create 4 in
  Hashtbl.iter
    (fun dep hs ->
      (* a tag is one handler's, so it can be code only if every handler of
         the dependency has its one method, and is no other's handler *)
      if
        List.length hs > max_arms
        && Hashtbl.find_opt ops dep = Some 1
        && List.for_all
             (fun (h : handler) -> h.hdeps = [ dep ] && method_of h dep 0 <> None)
             hs
      then (
        Hashtbl.replace code_deps dep ();
        List.iter
          (fun (h : handler) ->
            Hashtbl.replace code h.hid (Option.get (method_of h dep 0)))
          hs))
    reach;
  { reach; code; code_deps; ops }

(* The handlers of [dep] with a method for [op]. *)
let stateless t dep op =
  List.filter (fun h -> method_of h dep op <> None) (reach t dep)

(* How the call of [m], at the site [s], is lowered, and why. *)
let lowering t (s : dsite) (m : meth) =
  let all = reach t m.mdep in
  let n = List.length all in
  match m.known with
  | Some k -> (
      match List.find_opt (fun (h : handler) -> h.hid = k) all with
      | Some h when method_of h m.mdep m.mop <> None ->
          (Direct h, "its loop copied for this handler")
      | _ -> (Installed, "its loop copied for a handler with state"))
  | None -> (
      match stateless t m.mdep m.mop with
      | [] -> (Installed, "every handler that reaches it keeps state")
      | [ h ] when n = 1 -> (Direct h, "one handler")
      | ms when n <= max_arms && not s.drec ->
          (Arms ms, Printf.sprintf "%d handlers, at most %d" n max_arms)
      | _ ->
          let why =
            if n > max_arms then Printf.sprintf "more than %d" max_arms
            else "recursion through its own dependency"
          in
          if Hashtbl.mem t.code_deps m.mdep then (Code, why) else (Table, why))

(* Whether the method [m]'s handler has code for it: a constant where
   the set decides it, [None] where the tag has to be tested. *)
let has_code t (s : dsite) (m : meth) =
  match lowering t s m with
  | Direct _, _ -> Some true
  | Installed, _ -> Some false
  | _ ->
      if List.length (stateless t m.mdep m.mop) = List.length (reach t m.mdep)
      then Some true
      else None

(* ---- `ren build --release --explain-dispatch D` ----

   Each dependency named [name]: its handlers, where each is declared,
   its operations, how a description of it is laid out, and every site
   that dispatches over it, a line each, with how many handlers reach the
   site, the lowering chosen, and why. [text] is the source at a
   location. Nothing is left out: a site specializing made known isn't a
   dispatch at all, so it isn't here. *)

let plural n one many = if n = 1 then one else many

(* Where [h] is declared, `file:line`, or `:line` after another of the
   same file. *)
let places (hs : handler list) =
  let file = ref "" in
  List.map
    (fun (h : handler) ->
      let f = Filename.basename h.hloc.file in
      let at =
        if f = !file then Printf.sprintf ":%d" h.hloc.start.line
        else Printf.sprintf "%s:%d" f h.hloc.start.line
      in
      file := f;
      h.hshow ^ " " ^ at)
    hs

let by_place (hs : handler list) =
  List.stable_sort
    (fun (a : handler) (b : handler) ->
      compare
        (a.hloc.file, a.hloc.start.line, a.hloc.start.col)
        (b.hloc.file, b.hloc.start.line, b.hloc.start.col))
    hs

let explain (p : program) ~(text : Loc.t -> string) name =
  let t = make p in
  let deps =
    List.filteri (fun _ (_, (d : dep_info)) -> d.dname = name)
      (List.mapi (fun i d -> (i, d)) p.dep_infos)
  in
  let dsites = Array.of_list p.dsites in
  (* each site's [Method_of]s, the copies clone.ml made among them, and
     each [Call_handler]'s *)
  let meths = Hashtbl.create 32 and withs = Hashtbl.create 16 in
  List.iter
    (fun (f : fn) ->
      Rc.iter_stmts
        (fun s ->
          match s with
          | Let (_, Method_of m) ->
              Hashtbl.replace meths m.msite
                (m :: Option.value ~default:[] (Hashtbl.find_opt meths m.msite))
          | Call_handler { hsite = Some n; _ } -> Hashtbl.replace withs n ()
          | _ -> ())
        f.body)
    p.fns;
  let b = Buffer.create 1024 in
  let add = Buffer.add_string b in
  if deps = [] then
    add
      (Printf.sprintf
         "%s: no dependency of this name is dispatched over in the release build\n"
         name);
  List.iter
    (fun (dep, (d : dep_info)) ->
      let hs = by_place (reach t dep) in
      let n = List.length hs in
      let nops = List.length d.dops in
      add
        (Printf.sprintf "%s: %d %s (%s), %d %s (%s)\n" d.dname n
           (plural n "handler" "handlers")
           (String.concat ", " (places hs))
           nops
           (plural nops "operation" "operations")
           (String.concat ", " d.dops));
      let words = List.fold_left (fun w (h : handler) -> max w h.hwords) 0 hs in
      let tag =
        if Hashtbl.mem t.code_deps dep then "tag = code pointer (one operation)"
        else if n = 1 then "one handler, so no site reads its tag"
        else "tag = the handler's number, which indexes each operation's table"
      in
      add
        (Printf.sprintf "  description: %s; boxed, the tag then %d %s at most\n" tag
           words (plural words "word" "words"));
      (* the sites, in the order they're written, each line once *)
      let lines = ref [] in
      Array.iteri
        (fun i (s : dsite) ->
          (* `$start`'s `with` of the real world is the compiler's *)
          if s.ddep = dep && not (String.starts_with ~prefix:"$" s.dfn) then (
            let where =
              Printf.sprintf "%s:%d  %s(): %s" (Filename.basename s.dloc.file)
                s.dloc.start.line s.dfn (text s.dloc)
            in
            let line what why =
              lines :=
                ((s.dloc.file, s.dloc.start.line, s.dloc.start.col),
                 Printf.sprintf "  %s  %s  [%s]\n" where what why)
                :: !lines
            in
            let reach = Printf.sprintf "%d %s" n (plural n "handler reaches" "handlers reach") in
            if s.dwith then (
              if Hashtbl.mem withs i then
                line
                  (Printf.sprintf "%s → installed through its handler's record" reach)
                  "a `with`'s body isn't copied per handler yet")
            else
              match Hashtbl.find_opt meths i with
              | None -> ()
              | Some ms ->
                  let copies = List.filter (fun (m : meth) -> m.known <> None) ms in
                  if copies <> [] then (
                    let size =
                      match List.find_opt (fun c -> c.csite = i && c.cdone) p.clones with
                      | Some c -> Printf.sprintf "; %d statements a copy" c.csize
                      | None -> ""
                    in
                    let names =
                      List.sort_uniq compare
                        (List.filter_map (fun (m : meth) -> m.known) copies)
                      |> List.map (List.nth p.handlers)
                      |> by_place
                      |> List.map (fun (h : handler) -> h.hshow)
                    in
                    line
                      (Printf.sprintf "%s → loop copied per handler (%s%s), a direct call in each"
                         reach (String.concat ", " names) size)
                      "the description doesn't change in the loop");
                  List.iter
                    (fun (m : meth) ->
                      if m.known = None then (
                        let l, why = lowering t s m in
                        let what =
                          match l with
                          | Direct _ -> "direct call"
                          | Arms hs' ->
                              let k = List.length hs' in
                              if k = n then "arms inline, compare-and-branch"
                              else
                                Printf.sprintf
                                  "arms inline, compare-and-branch (%d with state installed)"
                                  (n - k)
                          | Table -> "table call"
                          | Code -> "table call (tag = code pointer)"
                          | Installed -> "installed for the call"
                        in
                        line (Printf.sprintf "%s → %s" reach what) why;
                        match
                          List.find_opt (fun c -> c.csite = i && not c.cdone) p.clones
                        with
                        | Some c ->
                            line (Printf.sprintf "%s → loop not copied" reach)
                              (Printf.sprintf "%d statements, over the budget of %d"
                                 c.csize clone_budget)
                        | None -> ()))
                    ms))
        dsites;
      let lines = List.sort_uniq compare !lines in
      let seen = Hashtbl.create 16 in
      List.iter
        (fun (_, l) ->
          if not (Hashtbl.mem seen l) then (
            Hashtbl.replace seen l ();
            add l))
        lines;
      if lines = [] then add "  no site dispatches over it: each is a known handler's\n")
    deps;
  Buffer.contents b

(* ---- what a release build knows before counting ----

   Where the set decides whether a method's handler has code
   ([has_code]), the branch the [If] on it doesn't take is dropped, and
   the other put in its place, before Perceus places the counting: so a
   call whose every handler is stateless keeps nothing alive for an
   install it can't reach, and a value it passes isn't taken by
   reference for a `with` that never runs. Sound because [has_code] is
   the same answer the [If] would get at run time. *)
let prune (p : program) : program =
  let t = make p in
  let dsites = Array.of_list p.dsites in
  let fn (f : fn) =
    let meths = Hashtbl.create 8 and known = Hashtbl.create 8 in
    let rec block (b : block) = List.concat_map stmt b
    and stmt (s : stmt) =
      match s with
      | Let (v, Method_of m) ->
          Hashtbl.replace meths v.id m;
          [ s ]
      | Let (v, Has_code (Var m)) -> (
          match Hashtbl.find_opt meths m.id with
          | Some meth -> (
              match has_code t dsites.(meth.msite) meth with
              | Some b ->
                  Hashtbl.replace known v.id b;
                  [ s ]
              | None -> [ s ])
          | None -> [ s ])
      | If (Var c, yes, no) when Hashtbl.mem known c.id ->
          block (if Hashtbl.find known c.id then yes else no)
      | s -> [ Rc.map_blocks block s ]
    in
    { f with body = block f.body }
  in
  { p with fns = List.map fn p.fns }
