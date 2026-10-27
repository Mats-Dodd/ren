(* The compiler pipeline, one pass after another. *)

let sprintf = Printf.sprintf

(* Something went wrong inside the compiler itself: an exception that isn't
   a diagnostic or a panic. [pass] names the pass that was running. *)
exception Internal_error of { pass : string; message : string }

(* Run one pass. Diagnostics and panics are about the program, so they pass
   through; anything else is a bug in the compiler, and is reported as one
   so it can't be mistaken for a problem with the program. *)
let pass name f =
  try f () with
  | ( Diag.Error _ | Diag.Errors _ | Eval.Panic _ | Eval.Assert_failed _
    | Eval.Uncaught _ | Eval.Went_differently _ | Internal_error _ ) as e ->
      raise e
  | e -> raise (Internal_error { pass = name; message = Printexc.to_string e })

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
  checked "mut" (fun sink -> Mut.program sink r);
  let inferred =
    checked "infer" (fun sink ->
        Infer.program sink ~imports ~reachable ?entry ?console ?sees_all
          ~tests:items.tests ~bodies:items.bodies r)
  in
  (* exclusivity needs types: which values are copied, which arguments
     are blocks *)
  checked "excl" (fun sink -> Excl.program sink ~reachable r inferred);
  (* only now is it known whether every import is used: a type imported
     by name can be used just by writing one of its constructors bare *)
  checked "imports" (fun sink ->
      Resolve.unused_imports sink r ~found:inferred.in_scope);
  checked "exhaust" (fun sink -> Exhaust.program sink ~reachable r inferred);
  let sets =
    Iface.sets_of
      (List.concat_map (fun (i : Iface.t) -> i.types) reachable @ r.types)
  in
  (* what a public function needs of its type parameters isn't written,
     so the interface takes it from inference (operators.md, "Generic
     code") *)
  let needs path =
    let s = Path.Map.find path inferred.schemes in
    (s.reqs, s.row_reqs)
  in
  let has_eq p = List.mem p inferred.opaque_eq in
  let iface = Iface.of_module ~home ~sets ~needs ~has_eq r.prog in
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
                scheme = Path.Map.find (Path.make home vname) inferred.schemes;
              })
            g.gtests
        else [])
      items.groups
  in
  (r, { iface with tests = iface.tests @ group_tests }, inferred, items)

(* A checked module, lowered to Core. *)
let lower r inferred = pass "lower" (fun () -> Lower.program r inferred)

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
  if lint then
    List.iter2
      (fun imports m ->
        pass "lint" (fun () -> Core_lint.program ~imports ~linked m))
      imports linked;
  linked

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
     let core = lower r inferred in
     ignore (link_lowered ~lint:true ~imports:[ imports ] [ core ]);
     (core, Iface.union Prelude.public iface, r.types))

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
          | None ->
              report i.path_loc
                ~help:"check the module's name, or create its file"
                ~notes:[ sprintf "it would be the file `%s`" ifile ]
                (sprintf "there's no module `%s`" i.path)
          | Some isrc -> visit ~path:(path @ [ (home, i) ]) i.path ifile isrc)
      imports;
    loaded := { home; file; parsed } :: !loaded;
    homes := Homes.add home !homes
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
      if not (is_loaded home) then visit ~path:[] home file src)
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
  core : Core.program Lazy.t;
      (** it lowered to Core, once it's needed, and then only once *)
  impl : Impl.t Lazy.t;
      (** the implementation tier of its summary (impl.ml), beside its interface
      *)
}

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
  let _, prelude_iface, _ = Lazy.force prelude in
  let sources = pass "load" (fun () -> load_all ~load ~dir roots) in
  List.rev
    (List.fold_left
       (fun (done_ : checked list) (m : source) ->
         let checked_ path =
           List.find (fun (c : checked) -> c.home = path) done_
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
         let core = lazy (lower resolved inferred) in
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
           impl = lazy (Impl.of_module iface (Lazy.force core));
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
  let prelude, _, _ = Lazy.force prelude in
  let lowered c =
    let core = Lazy.force c.core in
    if for_tests then core
    else
      {
        core with
        fns = List.filter (fun (f : Core.fn_def) -> not f.test) core.fns;
      }
  in
  link_lowered ?lint
    ~imports:([ Prelude.intrinsics ] :: List.map (fun c -> c.reachable) modules)
    (prelude :: List.map lowered modules)

let linked ?lint ?load ~file src = link ?lint (check_all ?load ~file src)

(* A release build's program (specialize.ml): what [link] makes, with
   what `$start` reaches specialized. Core Lint checks every module of
   it, always, since specialization is what makes it and nothing else
   checks that. *)
let specialize ?lint ?budget (modules : checked list) =
  let linked = link ?lint modules in
  let imports =
    [ Prelude.intrinsics ] :: List.map (fun c -> c.reachable) modules
  in
  let specialized, stats =
    pass "specialize" (fun () -> Specialize.program ?budget linked)
  in
  List.iter2
    (fun imports m ->
      pass "lint" (fun () -> Core_lint.program ~imports ~linked:specialized m))
    imports specialized;
  (specialized, stats)

let specialized ?lint ?load ?budget ~file src =
  specialize ?lint ?budget (check_all ?load ~file src)

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
        Ty.signature ?outer ~names ~pub:f.pub ~name
          ~params:
            (List.map
               (fun (p : Ast.Resolved.param) -> p.pname.ident.name)
               f.params)
          (Path.Map.find (Ast.fn_path home f) inferred.schemes)
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
                           (fun (d : Ast.tname) ->
                             match d.tref with
                             | Named p -> Some p
                             | Param _ -> None)
                           deps)
                      (Path.Map.find (Ast.fn_path home f) inferred.schemes);
                  ]
            | Ast.Fn f when List.mem f.name.name items.made -> []
            | Ast.Fn f -> [ tested f (fn_ ~name:f.name.name f) ]
            | Type ({ type_body = Dep _; _ } as td) ->
                (* a dependency: its operations, each with its type, then
                   its members *)
                let ops =
                  match (decl td).body with
                  | Dep ops ->
                      List.map
                        (fun (o : Iface.field) ->
                          let pr =
                            Ty.printer ~names
                              {
                                ty = o.fty;
                                names = [];
                                reqs = [];
                                row_reqs = [];
                              }
                          in
                          sprintf "  %s: %s" o.fname (Ty.show pr o.fty))
                        ops
                  | _ -> []
                in
                sprintf "%sdep %s"
                  (if td.type_pub then "pub " else "")
                  td.type_name.name
                :: ops
                @ List.map (member ~outer:[]) td.type_ops
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
                    { ty = Error; names = []; reqs = []; row_reqs = [] }
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
            | Type _ | Import _ | Testing _ -> [])
          resolved.prog ))
    modules

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

(* The built-in dependencies the entry's `main` uses, by name, as a
   journal's header has them (Lower.main_uses). *)
let main_uses (modules : Core.program list) =
  let entry = List.nth modules (List.length modules - 1) in
  match
    List.find_opt
      (fun (f : Core.fn_def) -> f.path = Path.make entry.home "main")
      entry.fns
  with
  | Some main -> List.map (fun (p : Path.t) -> p.name) (Lower.main_uses main)
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
  let line =
    match (journal.calls, journal.ending) with
    | c :: _, _ -> c.line
    | [], Some (_, l) -> l
    | [], None -> 1
  in
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
    | Let { value; _ } | Let_tuple { value; _ } | Expr value | Finally value ->
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
      pub = false;
      name = { name = console_fn; loc };
      tparams = [];
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
      | PCon (_, ps) | PFail (_, ps) | PTuple ps | POr ps ->
          List.concat_map names ps
      | PWild | PInt _ | PBool _ | PFail_any -> []
    in
    match parsed text with
    | Some (_, Let { name; _ }) -> [ name.name ]
    | Some (_, Let_tuple { pat; _ }) -> names pat
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
   wrapping method, called on its operands as the source writes them,
   `n.wrapping_add(1)`. The receiver is put in parentheses unless it's a
   name, a literal, a call or a field, which a `.` can follow; and for
   `n += 1`, where what's between the operands ends in `=`, it's put back,
   `n = n.wrapping_add(1)`, since a call on its own line does nothing.
   [None] if an operand isn't on one line of a file [sources] has. *)
let wrap_help ~sources (w : Eval.wrap) =
  let text (l : Loc.t) =
    match sources l.file with
    | Some src when l.start.line = l.stop.line ->
        let line = Diag.line_text src l.start.line in
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
  let call ~assign recv arg =
    let target = if postfix recv then recv else "(" ^ recv ^ ")" in
    let made = Printf.sprintf "%s.%s(%s)" target w.meth arg in
    let made = if assign then recv ^ " = " ^ made else made in
    Some (Printf.sprintf "if wrapping is what you mean, write `%s`" made)
  in
  match (text w.recv, w.arg) with
  | Some recv, None -> call ~assign:false recv ""
  | Some recv, Some a -> Option.bind (text a) (call ~assign:(assigns a) recv)
  | None, _ -> None

(* A panic, as `ren run` reports it. *)
let panic_diag ~sources loc msg wrap =
  let help = Option.bind wrap (wrap_help ~sources) in
  Diag.make ?help loc ("panic: " ^ msg)

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
  | Eval.Panic { loc; msg; wrap } ->
      Some (Diag.render ~sources (panic_diag ~sources loc msg wrap))
  | Eval.Assert_failed { loc; sides } ->
      Some (Diag.render ~sources (assert_failed loc sides))
  | Eval.Went_differently { loc; differs } ->
      Some (went_differently ~sources loc differs)
  | Eval.Uncaught { shown; _ } ->
      (* `main` failed: its error, shown as a value is (errors.md, "`main`") *)
      Some ("error: " ^ shown ^ "\n")
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None

(* ---- `ren build` (compiler.md, "Native slice") ---- *)

(* What a panic at [s] prints around its message, which the binary fills
   in when it panics: `ren run`'s message for a panic there, with a hole
   where the message goes, so the two print the same bytes. An
   `assert`'s whole message is known now. *)
let site_text ~sources (s : Mem.site) =
  match s.kind with
  | Asserts -> (Diag.render ~sources (assert_failed s.loc None), "")
  | Panics -> (
      let wrap =
        Option.map
          (fun (w : Mem.wrap) : Eval.wrap ->
            { meth = w.meth; recv = w.recv; arg = w.arg })
          s.wrap
      in
      let text = Diag.render ~sources (panic_diag ~sources s.loc "\000" wrap) in
      match String.index_opt text '\000' with
      | Some i ->
          ( String.sub text 0 i,
            String.sub text (i + 1) (String.length text - i - 1) )
      | None -> failwith "bug: a panic's message that doesn't hold its message")

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
  let p =
    match rc with
    | Naive -> p
    | Perceus ->
        pass "Perceus" (fun () ->
            let perceus p =
              Rc.prepare p |> Borrow.infer |> Rc.program |> Reuse.program
            in
            let placed = perceus p in
            (* a release build inlines the calls a reuse token was freed
               after, and places the counting again (inline.ml) *)
            match if release then Inline.sites placed else [] with
            | [] -> placed
            | sites -> perceus (Inline.program sites p))
  in
  (* a loop's arrays indexed directly, which needs Perceus's taking writes *)
  let p =
    if release && rc = Perceus then pass "hoisting" (fun () -> Hoist.program p)
    else p
  in
  pass "Mem Lint" (fun () -> Mem_lint.program p);
  p

let native ?lint ?load ?(release = false) ?made ?(restrict = true) ?rc ~sources
    ~file src =
  let p = mem ?lint ?load ~release ?made ?rc ~file src in
  (* each file read once, not once for each place in it that can panic *)
  let read = Hashtbl.create 16 in
  let sources file =
    match Hashtbl.find_opt read file with
    | Some src -> src
    | None ->
        let src = sources file in
        Hashtbl.replace read file src;
        src
  in
  pass "C" (fun () ->
      Emit_c.program ~restrict:(release && restrict)
        ~site_text:(site_text ~sources) p)
