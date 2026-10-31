(* The compiler pipeline, one pass after another. *)

let sprintf = Printf.sprintf

(* Something went wrong inside the compiler itself: an exception that isn't
   a diagnostic or a panic. [pass] names the pass that was running. *)
exception Internal_error of { pass : string; message : string }

(* Run one pass. Diagnostics and panics are about the program, so they pass
   through; anything else is a bug in the compiler, and is reported as one
   so it can't be mistaken for a problem with the program. *)
let pass_times = Sys.getenv_opt "REN_PASS_TIMES" <> None

let pass name f =
  (* `REN_PASS_TIMES` prints each pass's wall time, to see where a build's
     time goes (compiler.md, "Native slice", step 9) *)
  let f =
    if pass_times then (fun () ->
      let t0 = Unix.gettimeofday () in
      let r = f () in
      Printf.eprintf "ren pass %s: %.3f s\n%!" name (Unix.gettimeofday () -. t0);
      r)
    else f
  in
  try f () with
  | ( Diag.Error _ | Diag.Errors _ | Eval.Panic _ | Eval.Assert_failed _
    | Eval.Uncaught _ | Eval.Went_differently _ | Sched.Signalled _
    | Internal_error _ ) as e ->
      raise e
  | e ->
      (* `REN_DEBUG_ICE=1` with `OCAMLRUNPARAM=b` prints where it was *)
      if Sys.getenv_opt "REN_DEBUG_ICE" <> None then Printexc.print_backtrace stderr;
      raise (Internal_error { pass = name; message = Printexc.to_string e })

(* Run a pass that reports diagnostics to a sink. If it reported any, the
   program stops here: later passes would only trip over the same mistakes,
   and could rely on nothing this pass promises. *)
let checked name f =
  let sink = Diag.sink () in
  let result =
    try pass name (fun () -> f sink)
    with Diag.Error d ->
      Diag.report sink d;
      raise (Diag.Errors (Diag.reported sink))
  in
  if Diag.has_errors sink then raise (Diag.Errors (Diag.reported sink));
  result

let tokens ~file src = checked "lex" (fun _ -> Lexer.tokenize ~file src)

let parse ?prelude ~file src =
  let toks = tokens ~file src in
  checked "parse" (fun sink -> Parser.parse_program ?prelude sink toks)

(* every other caller parses a program's module, which can't write a
   built-in type's declaration *)
let parse_prelude () =
  parse ~prelude:true ~file:Prelude.file (String.trim Prelude.source)

let parse ~file src = parse ~file src

(* Check one module against the interfaces it imports, before anything
   runs: first what its names refer to (found through scope), then what may
   change, then types (and what's found through them), then that nothing
   is used while it's being changed (excl.ml), then whether every
   import is used, then whether every `match` is exhaustive. Returns the module resolved, its interface and
   what inference found. [imports] are the interfaces of the modules it
   imports, and [reachable] those of every module reachable through them,
   whose types it can meet without naming them. [entry] is set for the
   module the program starts in, which needs a `main`. Before any of it,
   its tests are made functions (test_items.ml); [groups] are the public
   groups of each module it imports, by its alias here. [console] is a
   `ren console` session's function in it, and what it gets the real
   implementation of (see [console]). With [sees_all], test code sees the
   whole module, as the console checks a program (Resolve.program). *)
let check_module ~home ~imports ~reachable ?entry ?console ?sees_all
    ?(groups = []) prog =
  let items =
    checked "tests" (fun sink -> Test_items.program sink ~imported:groups prog)
  in
  let r =
    checked "resolve" (fun sink ->
        Resolve.program sink ~home ~imports ~groups:items.pub_tests ?sees_all
          items.prog)
  in
  let for_places = ref [] in
  checked "mut" (fun sink ->
      Mut.program ~defer_for:(fun source check ->
          for_places := (source, check) :: !for_places) sink r);
  let inferred =
    checked "infer" (fun sink ->
        let inferred = Infer.program sink ~imports ~reachable ?entry ?console ?sees_all
          ~tests:items.tests ~bodies:items.bodies r in
        (* A block source never takes [&]. Its inferred protocol supplies
           that diagnostic; data sources keep the earlier place diagnostic. *)
        checked "mut" (fun sink ->
            List.iter (fun ((source : Ast.Resolved.expr), check) ->
                let block = Path.Map.exists (fun _ nodes ->
                    match Infer.Nodes.find_opt source.node nodes with
                    | Some { Infer.ty = Ty.Fun _; _ } -> true
                    | _ -> false) inferred.nodes in
                if not block then Diag.recover sink ~default:() check)
              (List.rev !for_places));
        inferred)
  in
  (* exclusivity needs types: which values are copied, which arguments
     are blocks *)
  let schemes = checked "excl" (fun sink -> Excl.program sink ~reachable r inferred) in
  let inferred = { inferred with schemes } in
  (* only now is it known whether every import is used: a type imported
     by name can be used just by writing one of its constructors bare *)
  checked "imports" (fun sink ->
      Resolve.unused_imports sink r ~found:inferred.in_scope);
  checked "exhaust" (fun sink -> Exhaust.program sink ~reachable r inferred);
  let sets =
    Iface.sets_of
      (List.concat_map (fun (i : Iface.t) -> i.types) reachable @ inferred.types)
  in
  (* what a public function needs of its type parameters isn't written,
     so the interface takes it from inference (operators.md, "Generic
     code") *)
  let needs path =
    let s = Path.Map.find path inferred.schemes in
    (s.reqs, s.row_reqs)
  in
  let has_eq p = List.mem p inferred.opaque_eq in
  let found path = Path.Map.find path inferred.schemes in
  let iface = Iface.of_module ~generators:inferred.generators
      ~types:inferred.types ~replay_unsafe:inferred.replay_unsafe
      ~home ~sets ~needs ~has_eq ~found r.prog in
  (* A public function's body was checked against its signature, so the
     type inference found for it is the one its interface states, with
     what it needs of its type parameters. Other modules see only the
     interface, so if the two ever differ, that's a bug in the compiler,
     and it's caught here rather than in whichever module trips over
     it. *)
  let mismatch name (said : Ty.scheme) (found : Ty.scheme) =
    (* the type, then what it needs of each variable, `T has eq` *)
    let show (s : Ty.scheme) =
      let pr =
        Ty.printer ~show_tail:(fun _ -> true) ~names:(Resolve.type_name r) s
      in
      (* the type first, so its variables are named in the order they
         appear *)
      let ty = Ty.show pr s.ty in
      let needs =
        List.map (fun (n, req) -> Ty.show pr (Var n) ^ " has " ^ req) s.reqs
        @ List.map
            (fun (n, req) ->
              Ty.show_row pr ~prefix:"" ~sep:"" ~kind:"e"
                { labels = []; tail = Some n }
              ^ " has " ^ req)
            s.row_reqs
      in
      String.concat ", " (ty :: needs)
    in
    raise
      (Internal_error
         {
           pass = "interface";
           message =
             Printf.sprintf
               "the interface of `%s` says `%s`, but inference found `%s`" name
               (show said) (show found);
         })
  in
  let check name (said : Ty.scheme) (found : Ty.scheme) =
    if found <> said then mismatch name said found
  in
  List.iter
    (fun (v : Iface.value) ->
      check v.vname v.scheme
        (Path.Map.find (Path.make home v.vname) inferred.schemes))
    (iface.values @ iface.tests);
  (* and so was each public member's, which is in its type's entry *)
  List.iter
    (fun (td : Iface.type_decl) ->
      Path.Map.iter
        (fun path (o : Iface.op) ->
          let found =
            match (o.okind, Path.Map.find path inferred.schemes) with
            | Value, ({ ty = Fun ([], t, _, _); _ } as s) ->
                Ty.canonical { s with ty = t }
            | _, s -> s
          in
          check (Path.local path) o.oscheme found)
        td.members)
    iface.types;
  (* Another module runs a public group's tests by calling them, so they're
     in the interface too, among its test code, with the types inference
     found: they have no signature to declare one. *)
  let group_tests =
    List.concat_map
      (fun (g : Test_items.group) ->
        if g.gpub then
          List.mapi
            (fun i _ ->
              let vname = Test_items.group_fn g.gname (i + 1) in
              {
                Iface.vname;
                generator = None;
                scheme = Path.Map.find (Path.make home vname) inferred.schemes;
                vparams = [];
              })
            g.gtests
        else [])
      items.groups
  in
  (* Another module that lists a public wiring calls the functions its
     links were made into (resolve.ml, "Wirings"), so they're in the
     interface too, with the types inference found: they have no
     signature to declare one. So is the wiring's shape, with how each
     link is written, for a message there. *)
  let other (p : Path.t) =
    List.find_map
      (fun (i : Iface.t) ->
        if i.home <> p.home then None
        else
          List.find_map
            (fun (w : Iface.wiring) -> List.assoc_opt p.name w.wwritten)
            i.wirings)
      reachable
  in
  let written = Resolve.written r ~other in
  let wirings = List.filter (fun (w : Iface.wiring) -> w.wpub) r.wirings in
  let made (w : Iface.wiring) =
    List.concat_map
      (fun (wi : Iface.wired_item) ->
        List.filter_map
          (function Iface.Made (f, _) -> Some f | Passed _ -> None)
          wi.links)
      w.witems
  in
  let links =
    List.concat_map
      (fun w ->
        List.map
          (fun f ->
            let params =
              List.find_map
                (function
                  | Ast.Fn (g : Ast.Resolved.fn_def) when g.name.name = f ->
                      Some
                        (List.map
                           (fun (q : Ast.Resolved.param) -> q.pname.ident.name)
                           g.params)
                  | _ -> None)
                r.prog
            in
            {
              Iface.vname = f;
              generator = None;
              scheme = Path.Map.find (Path.make home f) inferred.schemes;
              vparams = Option.value params ~default:[];
            })
          (made w))
      wirings
  in
  ( r,
    {
      iface with
      values = iface.values @ links;
      tests = iface.tests @ group_tests;
      wirings =
        List.map
          (fun (w : Iface.wiring) ->
            {
              w with
              wwritten =
                List.filter_map
                  (fun f -> Option.map (fun t -> (f, t)) (List.assoc_opt f written))
                  (made w);
            })
          wirings;
    },
    inferred,
    items )

(* A checked module, lowered to Core. *)
(* [reachable] are the interfaces the module's imports reach, whose
   types a record pattern or update can be of. *)
let lower ~reachable (r : Resolve.t) inferred =
  let types = Hashtbl.create 64 in
  List.iter
    (fun (d : Iface.type_decl) -> Hashtbl.replace types d.path d)
    (List.concat_map (fun (i : Iface.t) -> i.types) reachable @ r.types);
  pass "lower" (fun () ->
      Lower.program ~types:(Hashtbl.find_opt types) r inferred)

(* A program's modules, lowered, the prelude first, and the entry last,
   which gets `$start` if it has a `main`. With [lint], Core Lint checks
   each one; the tests turn it on for every program. [imports] are the
   interfaces each module sees. *)
let link_lowered ?(lint = false) ~imports modules =
  let linked =
    match List.rev modules with
    | [] -> []
    | (entry : Core.program) :: rest ->
        let main =
          List.find_opt
            (fun (f : Core.fn_def) -> f.path = Path.make entry.home "main")
            entry.fns
        in
        let fns = entry.fns @ Option.to_list (Option.map Lower.start main) in
        List.rev ({ entry with fns } :: rest)
  in
  if lint then pass "lint" (fun () -> Core_lint.programs ~imports linked);
  linked

(* The journal's recorder, made for each built-in dependency, which the
   runtime installs over each that `main` uses when it records a run
   (prelude.ml, "the journal"; eval.ml, [recorded]). *)
let recorders =
  List.map
    (fun d -> Lower.Any_for (Path.prelude "recorder", Path.prelude d))
    Prelude.world_deps

(* The prelude, as a module: its source, parsed and checked against the
   intrinsics (prelude.ml) and lowered, and its whole interface. It's
   checked once, the first time it's needed: [lazy] delays a computation
   and [Lazy.force] runs it (at most once). It's the same for every
   program, so sharing it is safe. It's linted then too, on its own, since
   that costs nothing per program. *)
let prelude =
  lazy
    (let prog = parse_prelude () in
     let imports = [ Prelude.intrinsics ] in
     (* its test code, `replay`, is the runtime's, not a specification of
        it, so it sees the prelude whole, as the console does *)
     let r, iface, inferred, _ =
       check_module ~home:Path.prelude_home ~imports ~reachable:imports
         ~sees_all:true prog
     in
     let core, _ = lower ~reachable:imports r inferred in
     ignore (link_lowered ~lint:true ~imports:[ imports ] [ core ]);
     (* what the standard library's modules see: the whole prelude, the
        runtime's intrinsics among it (std_lib.ml) *)
     let whole = Iface.union Prelude.intrinsics iface in
     (core, Iface.union Prelude.public iface, r, inferred, whole))

(* ---- loading a program's modules ----

   A program is its entry module, every module it imports, every module
   those import, and so on: the import graph. The driver never reads a
   file itself. It asks a loader for each module's source, by the module's
   path (`billing/stripe`), and the loader says where that comes from: the
   CLI reads the files next to the entry, the tests keep them in a list. *)

type loader = string -> string option

(* The file module [path] is: its path from the folder [dir] the program
   is in, with `.ren` on the end. *)
let file_in ~dir path =
  if dir = Filename.current_dir_name then path ^ ".ren"
  else Filename.concat dir (path ^ ".ren")

(* The same, for a program whose entry is the file [entry]: its folder is
   the program's. *)
let module_file ~entry path = file_in ~dir:(Filename.dirname entry) path

let imports_of (prog : Ast.Parsed.program) =
  List.filter_map (function Ast.Import i -> Some i | _ -> None) prog

(* Sets of modules' homes. [Set.Make] is a functor, like [Map.Make]: it makes
   a module of sets whose elements are compared with [String.compare]. *)
module Homes = Set.Make (String)

(* A module, loaded and parsed. *)
type source = { home : string; file : string; parsed : Ast.Parsed.program }

(* Every module of the program, loaded depth-first from the entry, each
   module's imports in the order it writes them. A module comes after
   every module it imports, so this is the order to check them in, and it
   depends on nothing but the program's text. The entry comes last.

   No module may import itself, even by way of others: the graph has no
   cycles, which is what gives it an order at all (module-build.md, "No
   import cycles"). A missing module, a cycle and two imports with the
   same alias are each reported, and the program stops once everything
   that could be loaded has been.

   A program's tests can be in any of its modules, so `ren test` on a
   folder loads every module in it, whether one imports it or not: those
   are [roots], each a module's path, file and source, loaded in order.
   Running a program has one, its entry. *)
let load_all ~(load : loader) ~dir roots =
  let sink = Diag.sink () in
  let report ?help ?notes ?labels loc msg =
    Diag.report sink (Diag.make ?help ?notes ?labels loc msg)
  in
  (* each module once it's done, the last one first. A module that didn't
     parse is done too, so it isn't reported again. *)
  let loaded = ref [] in
  (* the homes in [loaded], to look one up without walking the list *)
  let homes = ref Homes.empty in
  let is_loaded path = Homes.mem path !homes in
  (* [path] is the way here from the entry: each module on it, and its
     import of the next one *)
  let rec visit ~path home file src =
    let parsed =
      try parse ~file src
      with Diag.Errors ds ->
        List.iter (Diag.report sink) ds;
        []
    in
    let imports = imports_of parsed in
    let seen = Hashtbl.create 8 in
    List.iter
      (fun (i : Ast.import) ->
        match Hashtbl.find_opt seen i.alias.name with
        | Some (first : Ast.ident) ->
            report i.alias.loc ~help:"import one of them `as` something else"
              ~labels:
                [ (first.loc, sprintf "the first `%s` is here" first.name) ]
              (sprintf "there are two imports named `%s`" i.alias.name)
        | None -> Hashtbl.replace seen i.alias.name i.alias)
      imports;
    List.iter
      (fun (i : Ast.import) ->
        if i.path = Path.prelude_home then
          report i.path_loc ~help:"remove this import"
            "`prelude` is always imported, so it can't be imported again"
        else if is_loaded i.path then ()
        else if i.path = home || List.mem_assoc i.path path then
          cycle ~path home i
        else
          let ifile = file_in ~dir i.path in
          match load i.path with
          | Some _ when Std_lib.is_home i.path -> mine_is_std i.path_loc i.path
          (* the standard library's, which isn't a file *)
          | None when Option.is_some (Std_lib.source i.path) -> ()
          | None ->
              report i.path_loc
                ~help:"check the module's name, or create its file"
                ~notes:[ sprintf "it would be the file `%s`" ifile ]
                (sprintf "there's no module `%s`" i.path)
          | Some isrc -> visit ~path:(path @ [ (home, i) ]) i.path ifile isrc)
      imports;
    loaded := { home; file; parsed } :: !loaded;
    homes := Homes.add home !homes
  (* a module of the program's own, its file at [loc], has the name of one
     of the standard library's *)
  and mine_is_std loc name =
    report loc
      ~notes:[ sprintf "`import %s` finds the standard library's, not a file" name ]
      ~help:(sprintf "rename the file `%s.ren`, and the imports of it" name)
      (sprintf "`%s` is the standard library's" name)
  (* [i], in module [home], imports a module on the way here: the modules
     from that one to [home] import each other in a circle *)
  and cycle ~path home (i : Ast.import) =
    let rec from = function
      | (h, _) :: _ as rest when h = i.path -> rest
      | _ :: rest -> from rest
      | [] -> []
    in
    let around = from path in
    let modules = List.map fst around @ [ home; i.path ] in
    report i.iloc
      ~labels:
        (List.map
           (fun (h, (imp : Ast.import)) ->
             (imp.iloc, sprintf "`%s` imports `%s` here" h imp.path))
           around)
      ~help:
        (match around with
        | [] ->
            "remove it: a module's own names are in scope without importing it"
        | [ _ ] ->
            "move what both modules need into a third module that both can \
             import"
        | _ ->
            "move what these modules need from each other into a module they \
             can all import")
      (sprintf "import cycle: %s" (String.concat " → " modules))
  in
  List.iter
    (fun (home, file, src) ->
      if home = Path.prelude_home then
        raise
          (Diag.Errors
             [
               Diag.make (Loc.point ~file 1 1) ~help:"rename the file"
                 "a file can't be named `prelude.ren`: that's the name of the \
                  module every program imports";
             ]);
      if Std_lib.is_home home then mine_is_std (Loc.point ~file 1 1) home
      else if not (is_loaded home) then visit ~path:[] home file src)
    roots;
  if Diag.has_errors sink then raise (Diag.Errors (Diag.reported sink));
  List.rev !loaded

(* ---- checking a program ---- *)

(* One module of the program, checked against the interfaces of the
   prelude and of the modules it imports. *)
type checked = {
  home : string;
  file : string;
  prog : Ast.Parsed.program;
  resolved : Resolve.t;
  iface : Iface.t;
  inferred : Infer.t;
  reachable : Iface.t list;
      (** the interfaces of every module reachable through its imports, the
          prelude's first, each once *)
  items : Test_items.t;  (** its tests, and the functions they were made *)
  core : (Core.program * Lower.request list) Lazy.t;
      (** it lowered to Core, once it's needed, and then only once, with what
          it uses that's made for a request (Lower.request) *)
  impl : Impl.t Lazy.t;
      (** the implementation tier of its summary (impl.ml), beside its interface
      *)
}

(* The standard library's modules (std_lib.ml), each checked the first
   time it's needed, against the whole prelude, as the prelude's own
   source is checked against the intrinsics, and then shared, as the
   prelude is. Another module sees one as it sees any it imports, through
   its interface, which reaches only the prelude's public part. *)
let std_modules : (string * checked Lazy.t) list =
  List.map
    (fun (home, src) ->
      ( home,
        lazy
          (let _, prelude_iface, _, _, whole = Lazy.force prelude in
           let parsed = parse ~file:Prelude.file (String.trim src) in
           let resolved, iface, inferred, items =
             check_module ~home ~imports:[ whole ] ~reachable:[ whole ] parsed
           in
           let core = lazy (lower ~reachable:[ whole ] resolved inferred) in
           {
             home;
             file = Prelude.file;
             prog = parsed;
             resolved;
             iface;
             inferred;
             reachable = [ prelude_iface ];
             items;
             core;
             impl = lazy (Impl.of_module iface (fst (Lazy.force core)));
           }) ))
    Std_lib.sources

(* Load the program from its [roots] (see [load_all]), then check each of
   its modules in dependency order, each against the interfaces of what it
   imports, never their source. Returns them in that order. [entry] says
   whether a module is the one the program starts in, which needs a
   `main`. [console] is a `ren console` session: the module it's in, its
   function, added to that module, and the built-ins it gets the real
   implementation of, or [None] if it's only checked (see [console]). In a session, test code sees every
   module whole, so a test that reaches past an interface, which the
   console is the place to explore, doesn't keep it shut. *)
let check_roots ?console ~load ~dir ~entry roots =
  let _, prelude_iface, _, _, _ = Lazy.force prelude in
  let sources = pass "load" (fun () -> load_all ~load ~dir roots) in
  List.rev
    (List.fold_left
       (fun (done_ : checked list) (m : source) ->
         let checked_ path =
           match List.find_opt (fun (c : checked) -> c.home = path) done_ with
           | Some c -> c
           | None -> Lazy.force (List.assoc path std_modules)
         in
         let direct =
           List.map
             (fun (i : Ast.import) -> checked_ i.path)
             (imports_of m.parsed)
         in
         let imports =
           prelude_iface :: List.map (fun (c : checked) -> c.iface) direct
         in
         (* what each import reaches, then the import itself, each module
            once, in the order first met *)
         let reachable =
           (* built most recent first, with the homes already in it in a
              set, then reversed: adding to the end of a list each time
              would copy it each time *)
           let rev, _ =
             List.fold_left
               (fun acc (c : checked) ->
                 List.fold_left
                   (fun (rev, seen) (i : Iface.t) ->
                     if Homes.mem i.home seen then (rev, seen)
                     else (i :: rev, Homes.add i.home seen))
                   acc
                   (c.reachable @ [ c.iface ]))
               ([ prelude_iface ], Homes.singleton prelude_iface.home)
               direct
           in
           List.rev rev
         in
         let groups =
           List.map
             (fun (i : Ast.import) ->
               ( i.alias.name,
                 List.filter
                   (fun (g : Test_items.group) -> g.gpub)
                   (checked_ i.path).items.groups ))
             (imports_of m.parsed)
         in
         let parsed, session =
           match console with
           | Some (home, (f : Ast.Parsed.fn_def), real) when home = m.home ->
               (* a session that isn't run, `:t`, needn't have what it
                  uses installed *)
               (m.parsed @ [ Ast.Fn f ], Some (f.name.name, real))
           | _ -> (m.parsed, None)
         in
         let resolved, iface, inferred, items =
           check_module ~home:m.home ~imports ~reachable ~groups
             ?entry:(if entry m then Some m.file else None)
             ?console:session ~sees_all:(console <> None) parsed
         in
         (* [lazy] delays lowering until something needs it, as for
            [prelude]: checking a program, `ren types`, doesn't *)
         let core = lazy (lower ~reachable resolved inferred) in
         {
           home = m.home;
           file = m.file;
           prog = parsed;
           resolved;
           iface;
           inferred;
           reachable;
           items;
           core;
           impl = lazy (Impl.of_module iface (fst (Lazy.force core)));
         }
         :: done_)
       [] sources)

(* The same, for the program whose entry is [file], with the source [src]:
   it ends with the entry. A program of one file loads nothing else, so the
   loader is optional. *)
let check_all ?(load = fun _ -> None) ~file src =
  let home = Path.home_of_file file in
  check_roots ~load ~dir:(Filename.dirname file)
    ~entry:(fun (m : source) -> m.home = home)
    [ (home, file, src) ]

(* The module the program starts in. *)
let entry_of modules = List.nth modules (List.length modules - 1)
let check ?load ~file src = (entry_of (check_all ?load ~file src)).prog
let inferred ?load ~file src = (entry_of (check_all ?load ~file src)).inferred
let schemes ?load ~file src = (inferred ?load ~file src).schemes
let interface ?load ~file src = (entry_of (check_all ?load ~file src)).iface

let implementation ?load ~file src =
  Lazy.force (entry_of (check_all ?load ~file src)).impl

(* The whole program in Core, the prelude first. Test code, its test
   items and the functions its tests were made, is left out, unless it's
   [for_tests]: nothing else calls it (Core Lint checks that). *)
let link ?lint ?(for_tests = false) (modules : checked list) =
  let prelude, _, pr, pinf, whole = Lazy.force prelude in
  (* the standard library's modules, linked into every program after the
     prelude: `ren test` installs `sim`'s around each test, whether the
     program imports it or not, and a native build compiles only what
     `$start` reaches *)
  let std = List.map (fun (_, m) -> Lazy.force m) std_modules in
  let lowered c =
    let core, requests = Lazy.force c.core in
    if for_tests then (core, requests)
    else
      ( {
          core with
          fns = List.filter (fun (f : Core.fn_def) -> not f.test) core.fns;
        },
        requests )
  in
  (* each module, the prelude first: what checking it found, and it
     lowered, with what it asked to be made *)
  let all =
    (pr, pinf, (prelude, recorders))
    :: List.map (fun c -> (c.resolved, c.inferred, lowered c)) (std @ modules)
  in
  (* every type of the program, which a dependency's operations are
     found in *)
  let types = Hashtbl.create 64 in
  List.iter
    (fun ((r : Resolve.t), _, _) ->
      List.iter
        (fun (d : Iface.type_decl) -> Hashtbl.replace types d.path d)
        r.types)
    all;
  (* what's asked for is made in the module that declares what it's made
     of, once each, and what that asks for in turn (compiler.md, "`over
     any` and `retry`") *)
  let made = Hashtbl.create 16 and extra = Hashtbl.create 4 in
  let rec make = function
    | [] -> ()
    | req :: rest ->
        let p = Lower.made_path req in
        if Hashtbl.mem made p then make rest
        else (
          Hashtbl.replace made p ();
          let r, inferred, _ =
            List.find (fun ((r : Resolve.t), _, _) -> r.home = p.home) all
          in
          let fn, more, calls =
            Lower.made ~types:(Hashtbl.find_opt types) r inferred req
          in
          let fns, calls' =
            Option.value ~default:([], []) (Hashtbl.find_opt extra p.home)
          in
          Hashtbl.replace extra p.home (fn :: fns, calls @ calls');
          make (more @ rest))
  in
  make (List.concat_map (fun (_, _, (_, reqs)) -> reqs) all);
  let linked =
    link_lowered ?lint
      ~imports:
        ([ Prelude.intrinsics ]
        :: List.map (fun _ -> [ whole ]) std
        @ List.map (fun c -> c.reachable) modules)
      (List.map
         (fun (_, _, ((core : Core.program), _)) ->
           let fns, calls =
             Option.value ~default:([], []) (Hashtbl.find_opt extra core.home)
           in
           {
             core with
             fns = core.fns @ List.rev fns;
             method_calls = core.method_calls @ calls;
           })
         all)
  in
  (* which handlers a description may be is the whole program's to say,
     so a method call on one of a handler with state is refused here
     (stateless.ml), before anything runs or builds *)
  pass "stateless" (fun () -> Stateless.check linked);
  linked

let linked ?lint ?load ~file src = link ?lint (check_all ?load ~file src)

(* A release build's program (specialize.ml): what [link] makes, with
   what `$start` reaches specialized. Core Lint checks every module of
   it, always, since specialization is what makes it and nothing else
   checks that. *)
let specialize ?lint ?budget (modules : checked list) =
  let linked = link ?lint modules in
  (* `REN_SPEC_BUDGET` sets the size budget, to see what's past it *)
  let budget =
    match budget with
    | Some _ -> budget
    | None -> Option.bind (Sys.getenv_opt "REN_SPEC_BUDGET") int_of_string_opt
  in
  let _, _, _, _, whole = Lazy.force prelude in
  let imports =
    [ Prelude.intrinsics ]
    :: List.map (fun _ -> [ whole ]) std_modules
    @ List.map (fun c -> c.reachable) modules
  in
  let specialized, stats =
    pass "specialize" (fun () -> Specialize.program ?budget linked)
  in
  (* a copy is in its original's module but at the types of the call that
     asked for it, which may be another module's that this one never
     imports: the prelude's `sum` at a `money.Money`. So each module is
     checked seeing every module's interface, its own imports last, so
     what it does import it sees as it did. *)
  let everyone =
    (* each interface once, where it was last in the list, which is where
       it took effect: an interface reachable from many modules is in many
       of their lists *)
    let seen = Hashtbl.create 64 in
    List.rev
      (List.filter
         (fun (i : Iface.t) ->
           (* the same interface, not just one of the same module's *)
           if List.memq i (Hashtbl.find_all seen i.home) then false
           else (
             Hashtbl.add seen i.home i;
             true))
         (List.rev (List.concat_map (fun c -> c.reachable) modules)))
  in
  pass "lint" (fun () -> Core_lint.programs ~everyone ~imports specialized);
  (specialized, stats)

let specialized ?lint ?load ?budget ~file src =
  specialize ?lint ?budget (check_all ?load ~file src)

(* The note a release build prints when specialization reached its size
   budget: how many calls get the function as written, their arguments
   boxed, and where the first few are. Empty if none do. *)
let budget_notes (s : Specialize.stats) =
  match s.notes with
  | [] -> ""
  | notes ->
      let shown = 10 in
      let n = List.length notes in
      let b = Buffer.create 256 in
      Printf.bprintf b
        "note: specialization reached its size budget, so %d call%s %s \
         compiled as written, %s arguments boxed:\n"
        n
        (if n = 1 then "" else "s")
        (if n = 1 then "is" else "are")
        (if n = 1 then "its" else "their");
      List.iteri
        (fun i ((p : Path.t), (loc : Loc.t)) ->
          if i < shown then
            Printf.bprintf b "  %s:%d:%d: a call of `%s`\n" loc.file
              loc.start.line loc.start.col (Path.full p))
        notes;
      if n > shown then Printf.bprintf b "  and %d more\n" (n - shown);
      Buffer.contents b

(* ---- tests ---- *)

(* A failed `assert`, as `ren run` reports it: a panic, with the sides of
   an `assert a == b` shown through their type, as `ren test` shows them. *)
let assert_failed loc sides =
  let notes =
    match sides with
    | Some (l, r) -> [ "left:  " ^ l; "right: " ^ r ]
    | None -> []
  in
  Diag.make loc ~notes "panic: this `assert` failed"

(* A program's tests, checked and lowered with the functions they were
   made (test_items.ml), ready to run. *)
type suite = {
  core : Core.program list;  (** the program, the prelude first *)
  files : (string * string * Test_items.test list) list;
      (** each module's file, its path (its home) and its tests, in the order
          the files' names sort in *)
}

(* Every test of the program in the folder [dir] whose modules include
   [roots], each a file and its source (see [load_all]). A module that
   has a `main` is checked as the program's entry. *)
let suite ?lint ?(load = fun _ -> None) ~dir roots =
  Walk.fix_seed ();
  let home file =
    let rel =
      if dir = Filename.current_dir_name then file
      else
        let prefix = Filename.concat dir "" in
        if String.starts_with ~prefix file then
          String.sub file (String.length prefix)
            (String.length file - String.length prefix)
        else file
    in
    Filename.remove_extension rel
  in
  let has_main (m : source) =
    List.exists
      (function
        | Ast.Fn (f : Ast.Parsed.fn_def) -> f.name.name = "main" | _ -> false)
      m.parsed
  in
  let modules =
    check_roots ~load ~dir ~entry:has_main
      (List.map (fun (file, src) -> (home file, file, src)) roots)
  in
  let core = link ?lint ~for_tests:true modules in
  {
    core;
    files =
      List.sort compare
        (List.map (fun c -> (c.file, c.home, c.items.tests)) modules);
  }

let core ?lint ?load ~file src = entry_of (linked ?lint ?load ~file src)

(* Every module's signatures, as `ren types` prints them: each function's,
   and each type with members, its members indented under it. *)
let types ?(lint = false) ?load ~file src =
  let modules = check_all ?load ~file src in
  (* the tests also check that the program lowers, and lints *)
  if lint then ignore (link ~lint:true modules);
  List.map
    (fun { home; inferred; resolved; items; _ } ->
      let names = Resolve.type_name resolved in
      let fn_ ?outer ~name (f : Ast.Resolved.fn_def) =
        let path = Ast.fn_path home f in
        let scheme = Path.Map.find path inferred.schemes in
        let scheme =
          match f.fn_kind with
          | Ordinary_fn -> scheme
          | Generator_fn _ ->
              let g = Path.Map.find path inferred.generators in
              { scheme with ty = Ty.Fun (g.params, g.item, g.errors, g.uses) }
        in
        let shown = Ty.signature ?outer ~names ~pub:f.pub ~name
          ~params:
            (List.map
               (fun (p : Ast.Resolved.param) -> p.pname.ident.name)
               f.params)
          scheme
        in
        match f.fn_kind with
        | Ordinary_fn -> shown
        | Generator_fn _ when f.pub ->
            "pub gen " ^ String.sub shown 4 (String.length shown - 4)
        | Generator_fn _ -> "gen " ^ shown
      in
      (* a type's declaration, as Iface has it *)
      let decl (td : Ast.Resolved.type_def) =
        List.find
          (fun (d : Iface.type_decl) -> d.path.name = td.type_name.name)
          resolved.types
      in
      (* one of a type's members, under it *)
      let member ~outer (o : Ast.Resolved.op) =
        let f = o.op_fn in
        let name = f.name.name in
        match o.op_kind with
        | Op_fn -> "  " ^ fn_ ~outer ~name f
        | Op_value -> (
            (* a function of no parameters (ast.ml) *)
            match Path.Map.find (Ast.fn_path home f) inferred.schemes with
            | { ty = Fun ([], t, _, _); _ } as s ->
                "  "
                ^ Ty.value_signature ~names ~pub:f.pub ~name { s with ty = t }
            | _ -> assert false)
      in
      (* a test item is shown with `test` in front of its `fn` or
         `handler`, after any `pub` *)
      let tested (f : Ast.Resolved.fn_def) line =
        if not f.test then line
        else
          let pub, rest =
            if String.starts_with ~prefix:"pub " line then
              ("pub ", String.sub line 4 (String.length line - 4))
            else ("", line)
          in
          pub ^ "test " ^ rest
      in
      ( home,
        List.concat_map
          (function
            | Ast.Fn ({ body = { kind = Handler { deps; _ }; _ }; _ } as f) ->
                List.map (tested f)
                  [
                    Ty.handler_signature ~names ~pub:f.pub ~name:f.name.name
                      ~params:
                        (List.map
                           (fun (p : Ast.Resolved.param) -> p.pname.ident.name)
                           f.params)
                      ~deps:
                        (List.filter_map
                           (fun (d : Ast.tname Ast.dep_ref) ->
                             match d.dep.tref with
                             | Named p -> Some p
                             (* `for D`, what it's given *)
                             | Param _ -> Some Ty.param_path)
                           deps)
                      (Path.Map.find (Ast.fn_path home f) inferred.schemes);
                  ]
            | Ast.Fn f when List.mem f.name.name items.made -> []
            | Ast.Fn f when String.contains f.name.name '$' -> (
                (* a wiring is shown as the function its own `with` is
                   checked in, which says what it uses and fails with
                   (resolve.ml, [wiring_fns]); the functions its links
                   were made into aren't shown *)
                match Resolve.checked_wiring (Ast.fn_path home f) with
                | None -> []
                | Some name ->
                    let w =
                      List.find
                        (fun (w : Iface.wiring) -> w.wname = name)
                        resolved.wirings
                    in
                    let line = fn_ ~name f in
                    (* after `fn name`: its parameters, then the rest *)
                    let rest =
                      String.sub line
                        (String.length name + 3)
                        (String.length line - String.length name - 3)
                    in
                    let close =
                      let rec go i depth =
                        match rest.[i] with
                        | '(' -> go (i + 1) (depth + 1)
                        | ')' when depth = 1 -> i
                        | ')' -> go (i + 1) (depth - 1)
                        | _ -> go (i + 1) depth
                      in
                      go 0 0
                    in
                    let params =
                      if w.wparams = [] then "" else String.sub rest 0 (close + 1)
                    in
                    let after =
                      String.sub rest (close + 1) (String.length rest - close - 1)
                    in
                    [
                      sprintf "%swiring %s%s provides %s%s"
                        (if w.wpub then "pub " else "")
                        name params
                        (String.concat ", " (List.map names w.wprovides))
                        after;
                    ])
            | Ast.Fn f -> [ tested f (fn_ ~name:f.name.name f) ]
            | Type ({ type_body = Dep _; _ } as td) ->
                (* a dependency: its operations, each with its type, then
                   its members *)
                let params =
                  List.map (fun (p : Ast.ident) -> p.name) td.type_params
                in
                let ops =
                  match (decl td).body with
                  | Dep ops ->
                      List.map
                        (fun (o : Iface.field) ->
                          (* a generic one's operations name its parameters
                             as it declares them *)
                          let pr =
                            Ty.printer ~names
                              {
                                ty = o.fty;
                                names = List.mapi (fun i n -> (i, n)) params;
                                reqs = [];
                                row_reqs = [];
                                modes = [];
                                defaults = [];
                              }
                          in
                          sprintf "  %s: %s" o.fname (Ty.show pr o.fty))
                        ops
                  | _ -> []
                in
                sprintf "%sdep %s%s"
                  (if td.type_pub then "pub " else "")
                  td.type_name.name
                  (match params with
                  | [] -> ""
                  | ps -> "<" ^ String.concat ", " ps ^ ">")
                :: ops
                @ List.map (member ~outer:params) td.type_ops
            | Type ({ type_body = Dep_alias _; _ } as td) ->
                (* an alias: the instance it names *)
                let pr =
                  Ty.printer ~names
                    { ty = Error; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }
                in
                [
                  sprintf "%sdep %s = %s"
                    (if td.type_pub then "pub " else "")
                    td.type_name.name
                    (match (decl td).body with
                    | Dep_alias d -> Ty.show_dep pr d
                    | _ -> "?");
                ]
            | Type
                (( { type_ops = _ :: _; _ }
                 | { type_body = Opaque { numeric = Some _; _ }; _ } ) as td) ->
                let outer =
                  List.map (fun (p : Ast.ident) -> p.name) td.type_params
                in
                let params =
                  match outer with
                  | [] -> ""
                  | ps -> "<" ^ String.concat ", " ps ^ ">"
                in
                (* a `with numeric` type says so: it's what gives it its
                   `+`, `-`, `zero` and order *)
                let numeric =
                  match td.type_body with
                  | Opaque { numeric = Some _; _ } -> " with numeric"
                  | _ -> ""
                in
                sprintf "%stype %s%s%s"
                  (if td.type_pub then "pub " else "")
                  td.type_name.name params numeric
                :: List.map (member ~outer) td.type_ops
            | Type ({ type_body = Errors _; _ } as td) ->
                (* a named error set, as it's declared, each tag with its
                   payload's types *)
                let pr =
                  Ty.printer ~names
                    { ty = Error; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }
                in
                let errors =
                  match (decl td).body with
                  | Errors es ->
                      List.map
                        (function
                          | Iface.Tag (name, payload) ->
                              Ty.show_label pr { name; payload }
                          | Set p -> names p)
                        es
                  | _ -> []
                in
                [
                  sprintf "%stype %s = ! %s"
                    (if td.type_pub then "pub " else "")
                    td.type_name.name
                    (String.concat " | " errors);
                ]
            | Type _ | Import _ | Testing _ | Wiring _ | Service _ -> [])
          resolved.prog ))
    modules

(* `ren explain-wiring live [file]` (language.md §5): the wiring [name]
   of the program's entry module, as its own `with` is checked
   (resolve.ml, [wiring_fns]): its items in the order they're installed,
   numbered, each with what it installs and what it needs, met by an item
   of that number or from outside, and the wiring it came through if it
   came through one inside this one; then what the wiring uses, and the
   order of its teardown, the reverse. *)
let explain_wiring ?load ~file ~name src =
  let modules = check_all ?load ~file src in
  let m = entry_of modules in
  let r = m.resolved in
  let names = Resolve.type_name r in
  let w =
    match List.find_opt (fun (w : Iface.wiring) -> w.wname = name) r.wirings with
    | Some w -> w
    | None ->
        raise
          (Diag.Error
             (Diag.make
                (Loc.point ~file 1 1)
                ~help:"name one of its wirings: `ren explain-wiring live main.ren`"
                (sprintf "`%s` has no wiring `%s`" file name)))
  in
  let check = Path.make m.home (name ^ "$wiring") in
  let nodes = Path.Map.find check m.inferred.nodes in
  let f =
    List.find_map
      (function
        | Ast.Fn (f : Ast.Resolved.fn_def) when f.name.name = name ^ "$wiring" ->
            Some f
        | _ -> None)
      r.prog
    |> Option.get
  in
  (* its body: `try with <its items> in ()` *)
  let rec with_of (e : Ast.Resolved.expr) =
    match e.kind with
    | Try e | Block (_, e) -> with_of e
    | With { items; _ } -> (e.node, items)
    | _ -> failwith "a wiring's function is its `with`"
  in
  let node, items = with_of f.body in
  let order =
    match (Infer.Nodes.find node nodes).found with
    | Some (Install_order o) -> o
    | _ -> []
  in
  let written =
    Resolve.written r ~other:(fun (p : Path.t) ->
        List.find_map
          (fun (c : checked) ->
            if c.home <> p.home then None
            else
              List.find_map
                (fun (w : Iface.wiring) -> List.assoc_opt p.name w.wwritten)
                c.iface.wirings)
          modules)
  in
  let text (lk : Ast.Resolved.with_link) =
    match lk.link.kind with
    | Call ({ kind = Var (Global p); _ }, _) ->
        Option.value (List.assoc_opt p.name written) ~default:p.name
    | Var (Local b) -> b.ident.name
    | _ -> "this"
  in
  let dep_name (l : Ty.label) = names (Ty.dep_path l.name) in
  (* each item in the order it's installed: how it's written, what it
     installs and what its links need, and where it came from *)
  let rows =
    List.map
      (fun i ->
        let (it : Ast.Resolved.with_item) = List.nth items i in
        let top = List.hd it.chain in
        let installs =
          match (Infer.Nodes.find top.knode nodes).found with
          | Some (Installs { key; _ }) -> [ key ]
          | Some (Installs_handler keys) -> keys
          | _ -> []
        in
        let needs =
          List.concat_map
            (fun (lk : Ast.Resolved.with_link) ->
              match (Infer.Nodes.find lk.knode nodes).ty with
              | Impl i -> i.needs.labels
              | _ -> [])
            it.chain
          |> List.filter (fun (l : Ty.label) ->
                 not (List.exists (fun (k : Ty.label) -> k.name = l.name) installs))
        in
        let origin =
          match it.from with
          | (v : Ast.via) :: _ :: _ -> Some v.wiring
          | _ -> None
        in
        (text top, installs, needs, origin))
      order
  in
  let number (l : Ty.label) =
    let rec go n = function
      | (_, installs, _, _) :: rest ->
          if List.exists (fun (k : Ty.label) -> k.name = l.name) installs then
            Some n
          else go (n + 1) rest
      | [] -> None
    in
    go 1 rows
  in
  let cells =
    List.map
      (fun (shown, installs, needs, origin) ->
        let met, outside =
          List.partition_map
            (fun l ->
              match number l with
              | Some n -> Left (sprintf "%s (%d)" (dep_name l) n)
              | None -> Right (dep_name l))
            (List.sort_uniq compare needs)
        in
        let needs =
          String.concat "; "
            ((if met = [] then [] else [ "meets " ^ String.concat ", " met ])
            @
            if outside = [] then []
            else [ "needs " ^ String.concat ", " outside ^ ", from outside" ])
        in
        ( shown,
          "installs " ^ String.concat ", " (List.map dep_name installs),
          (if needs = "" then "needs nothing" else needs),
          origin ))
      rows
  in
  let width f = 4 + List.fold_left (fun m c -> max m (String.length (f c))) 0 cells in
  let pad n x = x ^ String.make (n - String.length x) ' ' in
  let w1 = width (fun (a, _, _, _) -> a)
  and w2 = width (fun (_, b, _, _) -> b)
  and w3 = width (fun (_, _, c, _) -> c) in
  let scheme = Path.Map.find check m.inferred.schemes in
  let uses, errors =
    match scheme.ty with
    | Fun (_, _, errs, uses) -> (uses.labels, errs.labels)
    | _ -> ([], [])
  in
  let params =
    match w.wparams with
    | [] -> ""
    | _ ->
        (* as `ren types` writes them *)
        let line =
          Ty.signature ~names ~pub:false ~name
            ~params:
              (List.map (fun (p : Ast.Resolved.param) -> p.pname.ident.name) f.params)
            scheme
        in
        let rest = String.sub line (String.length name + 3) (String.length line - String.length name - 3) in
        let rec close i depth =
          match rest.[i] with
          | '(' -> close (i + 1) (depth + 1)
          | ')' when depth = 1 -> i
          | ')' -> close (i + 1) (depth - 1)
          | _ -> close (i + 1) depth
        in
        String.sub rest 0 (close 0 0 + 1)
  in
  let pr = Ty.printer ~names scheme in
  (sprintf "%s%s, %s:%d, provides %s" name params w.wdeclared.file
     w.wdeclared.start.line
     (String.concat ", " (List.map names w.wprovides)))
  :: List.mapi
       (fun i (a, b, c, o) ->
         let row = sprintf "  %d. %s%s" (i + 1) (pad w1 a) (pad w2 b) in
         match o with
         | Some o -> sprintf "%s%s (%s)" row (pad w3 c) o
         | None -> row ^ c)
       cells
  @ [
      (match uses with
      | [] -> "  uses nothing"
      | ls -> "  uses " ^ String.concat ", " (List.map dep_name ls));
    ]
  @ (match errors with
    | [] -> []
    | ls ->
        [
          "  fails to start with "
          ^ String.concat " | " (List.map (Ty.show_label pr) ls);
        ])
  @ [
      "  teardown: "
      ^ String.concat ", "
          (List.rev (List.mapi (fun i _ -> string_of_int (i + 1)) rows));
    ]

(* [path], a file of the program in the folder [dir], from that folder:
   where a journal says a panic was, so it reads the same wherever the
   program was run from. *)
let from_dir ~dir path =
  let prefix = Filename.concat dir "" in
  if dir <> Filename.current_dir_name && String.starts_with ~prefix path then
    String.sub path (String.length prefix)
      (String.length path - String.length prefix)
  else path

(* Run [run], `main`, and say how it ended, as a journal writes it: with
   what it gave, or what it raised, to raise again. *)
let ended ~dir run : Journal.ending * (Value.t, exn) result =
  let at (loc : Loc.t) = Journal.place ~file:(from_dir ~dir loc.file) loc in
  match run () with
  | v -> (Exited, Ok v)
  | exception (Eval.Panic { loc; msg; _ } as e) ->
      (Panicked { at = at loc; msg }, Error e)
  | exception (Eval.Assert_failed { loc; _ } as e) ->
      (Panicked { at = at loc; msg = "this `assert` failed" }, Error e)
  | exception (Eval.Uncaught { written; _ } as e) -> (Errored written, Error e)
  | exception (Sched.Signalled n as e) -> (Stopped n, Error e)

(* The built-in dependencies the entry's `main` uses, by name, as a
   journal's header has them (Lower.main_uses): those that reach the
   world, so not `Async`, which the runtime installs anyway. *)
let main_uses (modules : Core.program list) =
  let entry = List.nth modules (List.length modules - 1) in
  match
    List.find_opt
      (fun (f : Core.fn_def) -> f.path = Path.make entry.home "main")
      entry.fns
  with
  | Some main ->
      List.filter
        (fun d -> List.mem d Prelude.world_deps)
        (List.map (fun (p : Path.t) -> p.name) (Lower.main_uses main))
  | None -> failwith "bug: a program with no `main`"

(* Check every module, lower each to Core, and run them as one program:
   the prelude, then each module in dependency order, starting from the
   entry's `$start`, which installs what `main` uses and calls it. With
   [record], a journal (journal.ml), the runtime installs a recorder
   over each real implementation instead, and the journal gets how the
   run ended as its last entry. With [trace], each call of an operation
   is added to it (`ren run --trace`). *)
let run ?lint ?load ?(release = false) ?(args = []) ?record ?trace ~file src =
  let checked = check_all ?load ~file src in
  Builtins.args := args;
  let modules =
    if release then fst (specialize ?lint checked) else link ?lint checked
  in
  let start : Eval.start =
    match record with
    | None -> Real
    | Some j ->
        Journal.start j ~deps:(main_uses modules);
        Record j
  in
  let ending, result =
    ended ~dir:(Filename.dirname file) (fun () ->
        pass "eval" (fun () -> Eval.run ~start ?trace modules))
  in
  Option.iter (fun j -> Journal.finish_recording j ending) record;
  match result with Ok v -> v | Error e -> raise e

(* `ren replay` (handlers.md, "Recording and replaying"): run the program
   as [run] does, with the replayer, which answers each call from
   [journal], in place of the real implementations, and stop at the
   first call that isn't the recording's next. Then the run has to have
   ended as the recording did, after the same calls; if it did, it ends
   that way again, a panic raised as it was. *)
let replay ?lint ?load ?trace ~(journal : Journal.t) ~file src =
  Walk.fix_seed ();
  let checked = check_all ?load ~file src in
  let modules = link ?lint checked in
  (* what's replayed is what `main` uses now *)
  let uses = main_uses modules in
  (if List.sort compare uses <> List.sort compare journal.header.deps then
     let said = function [] -> "nothing" | ds -> Infer_msg.and_list ds in
     raise
       (Diag.Error
          (Diag.make
             (Loc.point ~file:journal.file 1 1)
             (sprintf "%s recorded a `main` that uses %s, and this one uses %s"
                journal.file (said journal.header.deps) (said uses))
             ~help:Journal.recorded_again)));
  let ending, result =
    ended ~dir:(Filename.dirname file) (fun () ->
        pass "eval" (fun () -> Eval.run ~start:(Replay journal) ?trace modules))
  in
  (* what's said is at the journal's next call, or its end *)
  let line = Journal.next_line journal in
  (try Journal.finish_replay journal ending
   with Journal.Differs differs ->
     raise
       (Eval.Went_differently
          { loc = Loc.point ~file:journal.file line 1; differs }));
  match result with Ok v -> v | Error e -> raise e

(* ---- the console ----

   `ren console <module>` (testing.md, "The console") reads a line at a
   time, and each is a `let`, a `var` or an expression, as a line of a
   function's body is. The session is a function, `$console`, of no
   parameters, added to the module: so it's inside the module, its private
   items and its opaque types' representations in reach, and its body is
   every line the session kept, then the new one. Each line checks the
   whole program again, with the session one line longer, and runs the
   session again from its first line, as a test is run: on the test
   implementations of the built-ins but those [real] names, `Random` from
   one seed. So the run is the same each time, and only what the new line
   gave, and what it printed, is new (console.ml). A line that doesn't
   check, or fails, or panics, isn't kept. compiler.md says what that
   costs. *)

(* The file a line is in, for a message: each line is its own, line 1. *)
let console_file = "<console>"

(* The session's function, which no name written in a program can be. *)
let console_fn = "$console"

(* What a line gave: its value as it's written, unless it's a `let` or
   a `var`, or its value is `()`; and its type. What it did to the world
   was shown as it happened (journal.ml, [gave]). *)
type console_line = { shown : string option; ty : string }

(* Check the session [history], the lines kept so far, then [line], in
   the module [home] (its file [file], with the source [src]) of the
   program in the folder [dir], and, unless it's [types_only], run it,
   with the session's [journal], which shows each call to a built-in as
   it's made and gives back what a real one gave the lines kept. Line [i]
   of the session is line [i] of `<console>`, and [line] starts [col]
   columns into what was typed, after `:t `, which a message counts in.
   Raises what checking or running it raised; a session that went
   differently from what it kept, as [Eval.Went_differently], at the
   line it went differently in. *)
let console ?(types_only = false) ?(col = 0) ~journal ~load ~dir ~home ~file
    ~src ~real ~history line =
  (* line [i] of the session, 0 the first, is line [i + 1] of
     `<console>`; the last starts [col] columns in *)
  let shift (i, n) (l : Loc.t) =
    {
      l with
      start = { line = l.start.line + i; col = l.start.col + n };
      stop = { line = l.stop.line + i; col = l.stop.col + n };
    }
  in
  let stmts, node =
    List.fold_left
      (fun (stmts, node) (text, n) ->
        let toks =
          try tokens ~file:console_file text
          with Diag.Errors ds ->
            raise
              (Diag.Errors
                 (List.map
                    (fun (d : Diag.t) -> { d with loc = shift n d.loc })
                    ds))
        in
        let toks = Array.map (fun (t, l) -> (t, shift n l)) toks in
        let s, node =
          checked "parse" (fun sink ->
              Parser.parse_session_line sink toks ~node)
        in
        (stmts @ [ s ], node))
      ([], 0)
      (List.mapi (fun i l -> (l, (i, 0))) history
      @ [ (line, (List.length history, col)) ])
  in
  (* every line but the last is kept for what it names or does: the value
     of one that's an expression is dropped *)
  let kept : Ast.Parsed.stmt -> Ast.Parsed.stmt = function
    | Expr e ->
        Let
          {
            name = { name = "_"; loc = e.loc };
            ty = None;
            value = e;
            mut = false;
          }
    | s -> s
  in
  let rev = List.rev stmts in
  let before = List.rev_map kept (List.tl rev) in
  (* where the new line's value is, for a message *)
  let at =
    match List.hd rev with
    | Let { value; _ } | Let_pattern { value; _ } | Expr value | Finally value ->
        value.loc
  in
  let loc = Loc.point ~file:console_file 1 1 in
  let before, value, is_expr =
    match List.hd rev with
    | Expr e -> (before, e, true)
    | s -> (before @ [ s ], Parser.session_unit loc ~node, false)
  in
  let body : Ast.Parsed.expr =
    if before = [] then value
    else { kind = Block (before, value); loc = value.loc; node = node + 2 }
  in
  let fn : Ast.Parsed.fn_def =
    {
      fn_kind = Ast.Ordinary_fn;
      pub = false;
      name = { name = console_fn; loc };
      tparams = [];
      tneeds = [];
      params = [];
      ret = None;
      errors = None;
      uses = None;
      body;
      owner = None;
      overload = 0;
      (* test code, so it can use the module's test items, as a test can;
         and like all test code in a session, it sees everything *)
      test = true;
      loc;
    }
  in
  let modules =
    check_roots
      ~console:(home, fn, if types_only then None else Some real)
      ~load ~dir
      ~entry:(fun _ -> false)
      [ (home, file, src) ]
  in
  let m = List.find (fun (c : checked) -> c.home = home) modules in
  let path = Path.make home console_fn in
  let scheme = Path.Map.find path m.inferred.schemes in
  let ty =
    (Infer.Nodes.find value.node (Path.Map.find path m.inferred.nodes)).ty
  in
  let shown_ty =
    Ty.show
      (Ty.printer ~names:(Resolve.type_name m.resolved) { scheme with ty })
      ty
  in
  let unit = ty = Ty.unit in
  if types_only then { shown = None; ty = shown_ty }
  else
    let cx = pass "eval" (fun () -> Eval.load (link ~for_tests:true modules)) in
    (* the session's line [n], where it went differently *)
    let went_differently (d : Journal.differs) =
      Eval.Went_differently
        {
          loc = Loc.point ~file:console_file (Option.value d.line ~default:1) 1;
          differs = d;
        }
    in
    Journal.rerun journal;
    match
      pass "eval" (fun () ->
          fst (Eval.run_installed ~dir ~journal cx ~fn:path ~real ~seed:0))
    with
    | Ok v ->
        (try Journal.ran_all journal
         with Journal.Differs d -> raise (went_differently d));
        Journal.keep journal ~line:(List.length history + 1);
        {
          shown =
            (if is_expr && not unit then Some (Eval.show cx ty v) else None);
          ty = shown_ty;
        }
    | Error (Failed err) ->
        (* a `try` passed it up, and the session can't: the line, with
           `attempt` in place of its `try`, shows it as a value *)
        let help =
          if not is_expr then None
          else
            let shown =
              if String.starts_with ~prefix:"try " line then
                String.sub line 4 (String.length line - 4)
              else line
            in
            Some (Printf.sprintf "see it as a value: `attempt %s`" shown)
        in
        raise
          (Diag.Error
             (Diag.make ?help at
                (Printf.sprintf "the line failed with `%s`" err)))
    | Error (Panicked (Eval.Assert_failed { loc; sides })) ->
        raise (Diag.Error (assert_failed loc sides))
    | Error
        (Panicked
           (Eval.Went_differently { differs = { line = Some _; _ } as d; _ }))
      ->
        raise (went_differently d)
    | Error (Panicked e) -> raise e
    | Error Passed -> assert false

(* `:spec` (testing.md, "The console"): the session's lines [lines], each
   with what it showed, as a test named [name] of the module [home] (its
   file [file], with the source [src]), which sees what an importer sees.
   Each line is kept if the test checks with it: an expression whose
   value was shown as an `assert` that it's that value, if that checks,
   and otherwise as `let _ = ` and the line, so what it does stays in the
   test. The others are left out, each with its number, its text and
   why. Then the test is run, as `ren test` runs it, on the test
   implementations and `Random` seeded by its name: the session ran on
   its own seed, and maybe on real implementations, so an `assert` that
   fails is written as `let _ = ` and its line, and a line that fails
   or panics is left out, until the test passes. Returns the test, as
   it's written, or [None] if no line could be kept, and what was left
   out. Raises an error if the module has a test named [name] already. *)
let console_spec ~load ~dir ~home ~file ~src ~name lines =
  let src = if String.ends_with ~suffix:"\n" src then src else src ^ "\n" in
  let starts p l = String.starts_with ~prefix:p l in
  (* a test's body ends in a value: `()` after a `let` *)
  let finish body =
    match List.rev body with
    | last :: _ when starts "let " last || starts "var " last -> body @ [ "()" ]
    | _ -> body
  in
  let header = sprintf "\ntest %S =\n" name in
  let test body =
    header
    ^ String.concat "" (List.map (fun l -> "  " ^ l ^ "\n") (finish body))
  in
  (* the module, with the test of [body] added *)
  let with_test body =
    check_roots ~load ~dir
      ~entry:(fun _ -> false)
      [ (home, file, src ^ test body) ]
  in
  let its_test modules =
    let m = List.find (fun (c : checked) -> c.home = home) modules in
    List.find_opt
      (fun (t : Test_items.test) -> t.name = name && t.label = None)
      m.items.tests
  in
  (* a second test of the name wouldn't check, whatever its lines *)
  (match
     its_test
       (check_roots ~load ~dir ~entry:(fun _ -> false) [ (home, file, src) ])
   with
  | Some t ->
      raise
        (Diag.Error
           (Diag.make t.loc ~help:"give this one another name: `:spec <name>`"
              (sprintf "%s has a test named %S already" file name)))
  | None -> ());
  (* whether the test with [body] checks, or the first thing wrong *)
  let checks body =
    match with_test body with
    | _ -> None
    | exception Diag.Errors (d :: _) -> Some d.msg
    | exception Diag.Error d -> Some d.msg
  in
  (* how the test with [body] ends, run as `ren test` runs it *)
  let ran body =
    let modules = with_test body in
    let t = Option.get (its_test modules) in
    pass "eval" (fun () ->
        let cx = Eval.load (link ~for_tests:true modules) in
        fst
          (Eval.run_test ~dir:(Filename.dirname file) cx
             ~fn:(Path.make home t.fn) ~real:t.real
             ~seed:(Test_items.seed_of name)))
  in
  let passed = function Eval.Passed -> true | _ -> false in
  (* the names a line binds, and those it uses *)
  let parsed text =
    match
      let toks = tokens ~file:console_file text in
      ( toks,
        fst
          (checked "parse" (fun sink ->
               Parser.parse_session_line sink toks ~node:0)) )
    with
    | toks, stmt -> Some (toks, stmt)
    | exception _ -> None
  in
  let binds text =
    let rec names (p : Ast.Parsed.pattern) =
      match p.pkind with
      | PVar b -> [ b.name ]
      | PAs (q, b) -> names q @ [ b.name ]
      | PCon (_, ps) | PFail (_, ps) | PTuple ps | POr ps ->
          List.concat_map names ps
      | PRecord (_, fs) | PCon_named (_, fs) ->
          List.concat_map (fun (_, q) -> names q) fs.fpats
      | PSeq q ->
          List.concat_map names q.front
          @ Option.to_list
              (Option.map (fun (x : Ast.ident) -> x.name) (Option.bind q.middle (fun r -> r.rname)))
          @ List.concat_map names q.back
      | PWild | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> []
    in
    match parsed text with
    | Some (_, Let { name; _ }) -> [ name.name ]
    | Some (_, Let_pattern { pat; _ }) -> names pat
    | _ -> []
  in
  let uses text =
    match parsed text with
    | Some (toks, _) ->
        List.filter_map
          (function Token.IDENT n, _ -> Some n | _ -> None)
          (Array.to_list toks)
    | None -> []
  in
  (* why a line was left out once the test ran: how it ended there *)
  let in_a_test : Eval.outcome -> string = function
    | Failed err -> sprintf "in a test it fails with `%s`" err
    | Panicked (Eval.Panic { msg; _ }) -> "in a test it panics: " ^ msg
    | Panicked (Eval.Went_differently { differs; _ }) ->
        "in a test " ^ differs.said
    | _ -> "in a test its `assert` fails"
  in
  (* where the test's body starts in the file *)
  let first = List.length (String.split_on_char '\n' (src ^ header)) in
  (* the lines, kept or left out; [forced] are those running the test
     showed can't be kept as they were, each with an `assert` no longer
     tried ([None]) or left out, and why *)
  let rec build forced =
    let body, left, _ =
      List.fold_left
        (fun (body, left, gone) (i, (text, shown)) ->
          let tries =
            match (List.assoc_opt i forced, shown) with
            | Some (Some _), _ -> []
            | Some None, Some _ -> [ "let _ = " ^ text ]
            | None, Some v ->
                (if v = "true" then [ "assert " ^ text ] else [])
                @ [
                    sprintf "assert %s == %s" text v;
                    sprintf "assert (%s) == %s" text v;
                    "let _ = " ^ text;
                  ]
            | _, None -> [ text ]
          in
          match
            List.find_opt
              (fun t -> checks (body @ [ (i, t) ] |> List.map snd) = None)
              tries
          with
          | Some t ->
              let bound = binds text in
              ( body @ [ (i, t) ],
                left,
                List.filter (fun (n, _) -> not (List.mem n bound)) gone )
          | None ->
              let why =
                match List.assoc_opt i forced with
                | Some (Some why) -> why
                | _ -> (
                    let used = uses text in
                    match
                      List.find_opt (fun (n, _) -> List.mem n used) gone
                    with
                    | Some (n, l) ->
                        sprintf "it uses `%s`, from line %d, which is left out"
                          n l
                    | None ->
                        let last = List.nth tries (List.length tries - 1) in
                        Option.value
                          (checks (List.map snd body @ [ last ]))
                          ~default:"")
              in
              ( body,
                left @ [ (i + 1, text, why) ],
                List.map (fun n -> (n, i + 1)) (binds text) @ gone ))
        ([], [], [])
        (List.mapi (fun i l -> (i, l)) lines)
    in
    if body = [] then (body, left)
    else
      let written = List.map snd body in
      match ran written with
      | Passed -> (body, left)
      | outcome ->
          (* the line it ended at: where it says, or else the first that
             ends it, with the lines before it *)
          let n = List.length body in
          let at (loc : Loc.t) =
            let k = loc.start.line - first in
            if loc.file = file && k >= 0 && k < n then Some k else None
          in
          let k =
            match
              match outcome with
              | Panicked (Eval.Assert_failed { loc; _ })
              | Panicked (Eval.Panic { loc; _ })
              | Panicked (Eval.Went_differently { loc; _ }) ->
                  at loc
              | _ -> None
            with
            | Some k -> k
            | None ->
                let rec go k =
                  if
                    k >= n - 1
                    || not
                         (passed
                            (ran (List.filteri (fun j _ -> j <= k) written)))
                  then k
                  else go (k + 1)
                in
                go 0
          in
          let i, t = List.nth body k in
          let text = fst (List.nth lines i) in
          let fate =
            if starts "assert " t && t <> text then None
            else Some (in_a_test outcome)
          in
          build ((i, fate) :: forced)
  in
  let body, left = build [] in
  (* a `let` at the end binds what nothing uses, and would need a `()`
     after it, since a test's body ends in a value: it's left out, and so
     is a line kept as `let _ = ` and itself *)
  let rec unused body left =
    match List.rev body with
    | (i, t) :: rest when starts "let " t || starts "var " t ->
        let text = fst (List.nth lines i) in
        let why =
          if starts "let " text || starts "var " text then
            "it's at the end, and a test can't end in a `let`"
          else
            "it's at the end, where a test can't keep it as `let _ = ` and the \
             line"
        in
        unused (List.rev rest) (left @ [ (i + 1, text, why) ])
    | _ -> (body, List.sort (fun (a, _, _) (b, _, _) -> compare a b) left)
  in
  let body, left = unused body left in
  ((if body = [] then None else Some (test (List.map snd body))), left)

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "

(* The help a panic gives for an `Int` that overflowed (Eval.wrap): the
   wrapping operator, between its operands as the source writes them,
   `n +% 1` (operators.md, "The wrapping operators"), or, for `-x`, which
   has no operator, the method, `x.wrapping_neg()`. An operand is put in
   parentheses unless it's a name, a literal, a call or a field, so the
   operator binds as the one it replaces did; and for `n += 1`, where
   what's between the operands ends in `=`, it's `n +%= 1`.
   [None] if an operand isn't on one line of a file [lines_of] has. *)
let wrap_help_in ~lines_of (w : Eval.wrap) =
  let text (l : Loc.t) =
    match lines_of l.file with
    | Some lines when l.start.line = l.stop.line ->
        let line = Diag.line lines l.start.line in
        let from = l.start.col - 1 and n = l.stop.col - l.start.col in
        if from >= 0 && n > 0 && from + n <= String.length line then
          Some (String.sub line from n)
        else None
    | _ -> None
  in
  (* whether [s] is names and numbers with `.`s between, each followed by
     any number of `(...)` and `[...]`, which end where they started *)
  let postfix s =
    let n = String.length s in
    let word c =
      match c with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' -> true
      | _ -> false
    in
    (* the index just past the bracket that closes the one at [i] *)
    let rec close i depth =
      if i >= n then None
      else
        match s.[i] with
        | '(' | '[' -> close (i + 1) (depth + 1)
        | (')' | ']') when depth = 1 -> Some (i + 1)
        | ')' | ']' -> close (i + 1) (depth - 1)
        | _ -> close (i + 1) depth
    in
    let rec go i =
      if i >= n then true
      else if word s.[i] then go (i + 1)
      else if (s.[i] = '(' || s.[i] = '[') && i > 0 then
        match close i 0 with Some j -> go j | None -> false
      else false
    in
    n > 0 && word s.[0] && go 0
  in
  (* whether the operator between the operands is `+=` or another `op=` *)
  let assigns (a : Loc.t) =
    a.start.line = w.recv.stop.line
    && a.start.col > w.recv.stop.col
    &&
    match text { a with start = w.recv.stop; stop = a.start } with
    | Some between ->
        let op = String.trim between in
        op <> "" && op.[String.length op - 1] = '='
    | None -> false
  in
  let operand s = if postfix s then s else "(" ^ s ^ ")" in
  let help made =
    Some (Printf.sprintf "if wrapping is what you mean, write `%s`" made)
  in
  let op =
    match w.meth with
    | "wrapping_add" -> Some "+%"
    | "wrapping_sub" -> Some "-%"
    | "wrapping_mul" -> Some "*%"
    | _ -> None
  in
  match (text w.recv, w.arg, op) with
  | Some recv, None, _ -> help (Printf.sprintf "%s.%s()" (operand recv) w.meth)
  | Some recv, Some a, Some op ->
      Option.bind (text a) (fun arg ->
          if assigns a then help (Printf.sprintf "%s %s= %s" recv op arg)
          else help (Printf.sprintf "%s %s %s" (operand recv) op (operand arg)))
  | Some recv, Some a, None ->
      Option.bind (text a) (fun arg ->
          help (Printf.sprintf "%s.%s(%s)" (operand recv) w.meth arg))
  | None, _, _ -> None

(* The same, with the files of the source map [sources] split into lines
   here, or by [lines_of] ([Diag.indexed]), which a caller with many
   panics to render splits once. *)
let wrap_help ~sources w = wrap_help_in ~lines_of:(Diag.indexed sources) w

(* What a help calls the receiver at [recv], as it's written: its name,
   or a path, `self.name`; or `s`, where it isn't one (compiler.md, "Bytes
   stage, part two", "Errors and panics"). *)
let receiver_in ~lines_of (recv : Loc.t) =
  let name s =
    s <> ""
    && List.for_all
         (fun w ->
           w <> ""
           && (match w.[0] with 'a' .. 'z' | 'A' .. 'Z' | '_' -> true | _ -> false)
           && String.for_all
                (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
                w)
         (String.split_on_char '.' s)
  in
  match lines_of recv.file with
  | Some lines when recv.start.line = recv.stop.line -> (
      let line = Diag.line lines recv.start.line in
      let from = recv.start.col - 1 and n = recv.stop.col - recv.start.col in
      if from >= 0 && n > 0 && from + n <= String.length line then
        match String.sub line from n with t when name t -> t | _ -> "s"
      else "s")
  | _ -> "s"

(* [help] with each `\002` in it the receiver at [recv], as it's
   written (Eval.Panic). *)
let recv_help ~lines_of recv help =
  match recv with
  | Some l when String.contains help '\002' ->
      let r = receiver_in ~lines_of l in
      String.concat r (String.split_on_char '\002' help)
  | _ -> help

(* A panic, as `ren run` reports it. *)
let panic_diag ?lines_of ?(notes = []) ?help ?recv ~sources loc msg wrap =
  let lines_of =
    match lines_of with Some f -> f | None -> Diag.indexed sources
  in
  let help =
    match help with
    | Some h -> Some (recv_help ~lines_of recv h)
    | None -> Option.bind wrap (wrap_help_in ~lines_of)
  in
  Diag.make ~notes ?help loc ("panic: " ^ msg)

(* A replay that went differently from its recording (journal.ml), at
   [loc]: the program's call, or the journal's line; with a test's
   outputs as a diff, under it. *)
let went_differently ~sources loc (d : Journal.differs) =
  Diag.render ~sources (Diag.make loc ~notes:d.notes ?help:d.help d.said)
  ^
  match d.diff with
  | None -> ""
  | Some lines -> String.concat "" (List.map (fun l -> "   " ^ l ^ "\n") lines)

(* What to print for an exception a pass raised, or [None] if it isn't one
   the compiler knows about. [sources] is the source map (diag.ml). *)
let render_error ~sources = function
  | Diag.Error d -> Some (Diag.render ~sources d)
  | Diag.Errors ds -> Some (Diag.render_all ~sources ds)
  | Eval.Panic { loc; msg; wrap; notes; help; recv } ->
      Some (Diag.render ~sources (panic_diag ~notes ?help ?recv ~sources loc msg wrap))
  | Eval.Assert_failed { loc; sides } ->
      Some (Diag.render ~sources (assert_failed loc sides))
  | Eval.Went_differently { loc; differs } ->
      Some (went_differently ~sources loc differs)
  | Eval.Uncaught { shown; from; _ } ->
      (* `main` failed: its error, shown as a value is (errors.md, "`main`"),
         and the task it came from, if it wasn't `main` *)
      Some
        ("error: " ^ shown ^ "\n"
        ^ match from with Some p -> "  = from the task " ^ p ^ "\n" | None -> "")
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None

(* ---- `ren build` (compiler.md, "Native slice") ---- *)

(* What a panic at [s] prints, in pieces (Diag.piece), which the binary
   fills in when it panics: `ren run`'s message for a panic there, with a
   [Hole] where the message goes, so the two print the same bytes. An
   `assert`'s whole message is known now. The operands its help suggests
   the wrapping method for are written as slices of the lines they're
   on, which the binary keeps once, for every panic on them. *)
(* Where [sub] first is in [s], if it is. *)
let find_sub sub s =
  let n = String.length sub and m = String.length s in
  let rec at i =
    if i + n > m then None
    else if String.sub s i n = sub then Some i
    else at (i + 1)
  in
  if n = 0 then None else at 0

let site_pieces ~lines_of ~sources (s : Mem.site) : Diag.piece list =
  match s.kind with
  | Caller -> [] (* it's [ren_here], whose pieces are its call's *)
  (* the `+=` report's note (compiler.md, "Bytes stage, part two",
     "Appending in place"): a diagnostic's pieces, `note:` where an
     error's say `error:`, the message, which counts the copies, the
     binary's *)
  | Appends _ ->
      let d =
        Diag.make ~help:"build the string once: join, or keep it unique" s.loc
          "\000"
      in
      List.concat_map
        (fun (p : Diag.piece) : Diag.piece list ->
          match p with
          | Text "error: \000\n" -> [ Text "note: "; Hole; Text "\n" ]
          | p -> [ p ])
        (Diag.pieces_indexed ~lines_of d)
  | Asserts -> Diag.pieces_indexed ~lines_of (assert_failed s.loc None)
  | Panics ->
      let wrap =
        Option.map
          (fun (w : Mem.wrap) : Eval.wrap ->
            { meth = w.meth; recv = w.recv; arg = w.arg })
          s.wrap
      in
      let pieces =
        Diag.pieces_indexed ~lines_of
          (panic_diag ~lines_of ~notes:s.notes ?help:s.help ~sources s.loc "\000" wrap)
      in
      (* the message's hole, and nothing else of the kind *)
      let split_at c (p : Diag.piece) : Diag.piece list =
        match p with
        | Text t -> (
            match String.index_opt t c with
            | Some i ->
                [
                  Text (String.sub t 0 i);
                  Hole;
                  Text (String.sub t (i + 1) (String.length t - i - 1));
                ]
            | None -> [ p ])
        | p -> [ p ]
      in
      let pieces = List.concat_map (split_at '\000') pieces in
      (* a help the binary writes, ["\001"], and the receiver it names *)
      let rec helps (ps : Diag.piece list) : Diag.piece list =
        match ps with
        | Spaces n :: Text t :: rest
          when String.starts_with ~prefix:" help: \001\n" t ->
            let recv =
              match s.recv with Some l -> receiver_in ~lines_of l | None -> "s"
            in
            let after = String.length " help: \001\n" in
            Help_hole (n, recv)
            :: Text (String.sub t after (String.length t - after))
            :: helps rest
        | p :: rest -> p :: helps rest
        | [] -> []
      in
      let pieces = helps pieces in
      if List.length (List.filter (( = ) Diag.Hole) pieces) <> 1 then
        failwith "bug: a panic's message that doesn't hold its message";
      (* each operand, where its text is in the help: a slice of its line *)
      let operands =
        match s.wrap with
        | None -> []
        | Some w ->
            List.filter_map
              (fun (l : Loc.t) ->
                match lines_of l.file with
                | Some lines when l.start.line = l.stop.line ->
                    let line = Diag.line lines l.start.line in
                    let from = l.start.col - 1
                    and n = l.stop.col - l.start.col in
                    if from >= 0 && n > 0 && from + n <= String.length line then
                      Some (String.sub line from n, (line, from, n))
                    else None
                | _ -> None)
              (w.recv :: Option.to_list w.arg)
      in
      let rec slice (p : Diag.piece) : Diag.piece list =
        match p with
        | Text t -> (
            (* the operand found first in [t], the longer where two start
               at one place *)
            let found =
              List.fold_left
                (fun best (op, sl) ->
                  match find_sub op t with
                  | Some i -> (
                      match best with
                      | Some (j, op', _)
                        when j < i
                             || (j = i && String.length op' >= String.length op)
                        ->
                          best
                      | _ -> Some (i, op, sl))
                  | None -> best)
                None operands
            in
            match found with
            | None -> [ p ]
            | Some (i, op, (line, from, n)) ->
                let k = i + String.length op in
                Diag.Text (String.sub t 0 i)
                :: Slice (line, from, n)
                :: slice (Text (String.sub t k (String.length t - k))))
        | p -> [ p ]
      in
      let sliced = List.concat_map slice pieces in
      if Diag.expand sliced <> Diag.expand pieces then
        failwith "bug: a panic's operands sliced into other text";
      sliced

(* What the native slice can't compile yet, at [loc]: an error that says
   so, and how to run the program anyway. *)
let not_native ~file loc what =
  Diag.Error
    (Diag.make loc ~says:"`ren build` can't compile this yet"
       ~help:(sprintf "run it with `ren run %s`" file)
       (what ^ " isn't in the native slice yet"))

type rc = Naive | Perceus

let mem ?lint ?load ?(release = false) ?(made = ignore) ?(rc = Perceus) ~file
    src =
  let modules =
    if release then (
      let modules, stats = specialized ?lint ?load ~file src in
      made stats;
      modules)
    else linked ?lint ?load ~file src
  in
  let p =
    pass "native lowering" (fun () ->
        try To_mem.program ~release modules
        with To_mem.Unsupported (loc, what) ->
          raise (not_native ~file loc what))
  in
  (* identical copies made one (fold.ml), before anything else works on
     each of them; `REN_NO_FOLD` (env) leaves them apart, to measure *)
  let p =
    if release && Sys.getenv_opt "REN_NO_FOLD" = None then
      pass "folding" (fun () -> Fold.program p)
    else p
  in
  (* dispatch over descriptions, as decision 4 says (dispatch.ml): a loop
     over a description that doesn't change copied for each handler it
     can have (clone.ml), and what the closed set decides of each call
     made, before and after, all before counting is placed, so each
     copy, and each call, is counted for what it can do. `REN_NO_CLONE` (env) leaves loops whole,
     to measure *)
  let p =
    if release then
      pass "dispatch" (fun () ->
          let p = Dispatch.prune p in
          if Sys.getenv_opt "REN_NO_CLONE" = None then
            Dispatch.prune (Clone.program p)
          else p)
    else p
  in
  let p =
    match rc with
    | Naive -> p
    | Perceus ->
        pass "Perceus" (fun () ->
            let perceus p =
              Rc.prepare p
              (* a call whose result is only put in a constructor and
                 returned made a turn of a loop (trmc.ml), which Perceus
                 then counts as anything else *)
              |> Trmc.program
              |> Borrow.infer |> Rc.program
              |> Reuse.program
            in
            let placed = perceus p in
            (* a release build inlines the calls a reuse token was freed
               after, and places the counting again (inline.ml) *)
            match if release then Inline.sites placed else [] with
            | [] -> placed
            | sites -> perceus (Inline.program sites p))
  in
  (* an element written back where it was moved out of its array, not
     counted again (swap.ml), which needs Perceus's taking writes *)
  let p =
    if rc = Perceus then pass "swap-out" (fun () -> Swap.program p) else p
  in
  (* a loop's arrays indexed directly, which needs Perceus's taking writes *)
  let p =
    if release && rc = Perceus then pass "hoisting" (fun () -> Hoist.program p)
    else p
  in
  pass "Mem Lint" (fun () -> Mem_lint.program p);
  p

(* What a panic at each site prints, each file read once, not once for
   each place in it that can panic. *)
let site_pieces_of sources =
  let read = Hashtbl.create 16 in
  let sources file =
    match Hashtbl.find_opt read file with
    | Some src -> src
    | None ->
        let src = sources file in
        Hashtbl.replace read file src;
        src
  in
  site_pieces ~lines_of:(Diag.indexed sources) ~sources

let native ?lint ?load ?(release = false) ?made ?(restrict = true) ?rc
    ?(explain = ignore) ~sources ~file src =
  let p = mem ?lint ?load ~release ?made ?rc ~file src in
  explain p;
  pass "C" (fun () ->
      Emit_c.program ~restrict:(release && restrict) ~release
        ~site_pieces:(site_pieces_of sources) p)

let native_units ?lint ?load ?rc ~jobs ~sources ~file src =
  let p = mem ?lint ?load ?rc ~file src in
  pass "C" (fun () ->
      Emit_c.units ~jobs ~site_pieces:(site_pieces_of sources) p)
