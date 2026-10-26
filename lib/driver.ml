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
    | Eval.Uncaught _ | Internal_error _ ) as e ->
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

let parse ~file src =
  let toks = tokens ~file src in
  checked "parse" (fun sink -> Parser.parse_program sink toks)

(* Check one module against the interfaces it imports, before anything
   runs: first what its names refer to (found through scope), then what may
   change, then types (and what's found through them), then whether every
   import is used, then whether every `match` is exhaustive. Returns the module resolved, its interface and
   what inference found. [imports] are the interfaces of the modules it
   imports, and [reachable] those of every module reachable through them,
   whose types it can meet without naming them. [entry] is set for the
   module the program starts in, which needs a `main`. Before any of it,
   its tests are made functions (test_items.ml); [groups] are the public
   groups of each module it imports, by its alias here. *)
let check_module ~home ~imports ~reachable ?entry ?(groups = []) prog =
  let items =
    checked "tests" (fun sink -> Test_items.program sink ~imported:groups prog)
  in
  let r =
    checked "resolve" (fun sink ->
        Resolve.program sink ~home ~imports ~groups:items.pub_tests items.prog)
  in
  checked "mut" (fun sink -> Mut.program sink r);
  let inferred =
    checked "infer" (fun sink ->
        Infer.program sink ~imports ~reachable ?entry ~tests:items.tests
          ~bodies:items.bodies r)
  in
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
  (* without lambda sets: the interface's are each one of its own, and
     inference's say which lambdas flow where, which the body decides *)
  let check name (said : Ty.scheme) (found : Ty.scheme) =
    if Ty.forget_lams found <> Ty.forget_lams said then mismatch name said found
  in
  List.iter
    (fun (v : Iface.value) ->
      check v.vname v.scheme
        (Path.Map.find (Path.make home v.vname) inferred.schemes))
    iface.values;
  (* and so was each public member's, which is in its type's entry *)
  List.iter
    (fun (td : Iface.type_decl) ->
      Path.Map.iter
        (fun path (o : Iface.op) ->
          let found =
            match (o.okind, Path.Map.find path inferred.schemes) with
            | Value, ({ ty = Fun ([], t, _, _, _); _ } as s) ->
                Ty.canonical { s with ty = t }
            | _, s -> s
          in
          check (Path.local path) o.oscheme found)
        td.members)
    iface.types;
  (* Another module runs a public group's tests by calling them, so they're
     in the interface too, with the types inference found: they have no
     signature to declare one. *)
  let group_tests =
    List.concat_map
      (fun (g : Test_items.group) ->
        if g.gpub then
          List.mapi
            (fun i _ ->
              let vname = Test_items.group_fn g.gname (i + 1) in
              {
                Iface.vname;
                scheme =
                  Ty.forget_lams
                    (Path.Map.find (Path.make home vname) inferred.schemes);
              })
            g.gtests
        else [])
      items.groups
  in
  (r, { iface with values = iface.values @ group_tests }, inferred, items)

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
    (let prog = parse ~file:Prelude.file (String.trim Prelude.source) in
     let imports = [ Prelude.intrinsics ] in
     let r, iface, inferred, _ =
       check_module ~home:Path.prelude_home ~imports ~reachable:imports prog
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
   `main`. *)
let check_roots ~load ~dir ~entry roots =
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
         let resolved, iface, inferred, items =
           check_module ~home:m.home ~imports ~reachable ~groups
             ?entry:(if entry m then Some m.file else None)
             m.parsed
         in
         (* [lazy] delays lowering until something needs it, as for
            [prelude]: checking a program, `ren types`, doesn't *)
         let core = lazy (lower resolved inferred) in
         {
           home = m.home;
           file = m.file;
           prog = m.parsed;
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

(* The whole program in Core, the prelude first. The functions its tests
   were made are left out, unless it's [for_tests]: nothing else calls
   them. *)
let link ?lint ?(for_tests = false) (modules : checked list) =
  let prelude, _, _ = Lazy.force prelude in
  let lowered c =
    let core = Lazy.force c.core in
    if for_tests then core
    else
      {
        core with
        fns =
          List.filter
            (fun (f : Core.fn_def) ->
              not (List.mem (Path.local f.path) c.items.made))
            core.fns;
      }
  in
  link_lowered ?lint
    ~imports:([ Prelude.intrinsics ] :: List.map (fun c -> c.reachable) modules)
    (prelude :: List.map lowered modules)

let linked ?lint ?load ~file src = link ?lint (check_all ?load ~file src)

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
            | { ty = Fun ([], t, _, _, _); _ } as s ->
                "  "
                ^ Ty.value_signature ~names ~pub:f.pub ~name { s with ty = t }
            | _ -> assert false)
      in
      ( home,
        List.concat_map
          (function
            | Ast.Fn ({ body = { kind = Handler { deps; _ }; _ }; _ } as f) ->
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
            | Ast.Fn f -> [ fn_ ~name:f.name.name f ]
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

(* Check every module, lower each to Core, and run them as one program: the prelude, then each module in
   dependency order, starting from the entry's `$start`, which installs
   what `main` uses and calls it. *)
let run ?lint ?load ?(args = []) ~file src =
  let checked = check_all ?load ~file src in
  Builtins.args := args;
  let modules = link ?lint checked in
  try pass "eval" (fun () -> Eval.run modules)
  with Eval.Assert_failed { loc; sides } ->
    raise (Diag.Error (assert_failed loc sides))

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "

(* The help a panic gives for an `Int` that overflowed (Eval.wrap): the
   method that wraps, called on its operands as the source writes them,
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

(* What to print for an exception a pass raised, or [None] if it isn't one
   the compiler knows about. [sources] is the source map (diag.ml). *)
let render_error ~sources = function
  | Diag.Error d -> Some (Diag.render ~sources d)
  | Diag.Errors ds -> Some (Diag.render_all ~sources ds)
  | Eval.Panic { loc; msg; wrap } ->
      Some (Diag.render ~sources (panic_diag ~sources loc msg wrap))
  | Eval.Uncaught err ->
      (* `main` failed: its error, shown as a value is (errors.md, "`main`") *)
      Some ("error: " ^ err ^ "\n")
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None
