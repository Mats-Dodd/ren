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
  | (Diag.Error _ | Diag.Errors _ | Eval.Panic _ | Internal_error _) as e ->
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
   module the program starts in, which needs a `main`. *)
let check_module ~home ~imports ~reachable ?entry prog =
  let r =
    checked "resolve" (fun sink -> Resolve.program sink ~home ~imports prog)
  in
  checked "mut" (fun sink -> Mut.program sink r);
  let inferred =
    checked "infer" (fun sink ->
        Infer.program sink ~imports ~reachable ?entry r)
  in
  (* only now is it known whether every import is used: a type imported
     by name can be used just by writing one of its constructors bare *)
  checked "imports" (fun sink ->
      Resolve.unused_imports sink r ~found:inferred.in_scope);
  checked "exhaust" (fun sink -> Exhaust.program sink ~reachable r inferred);
  let iface = Iface.of_module ~home r.prog in
  (* A public function's body was checked against its signature, so the
     type inference found for it is the one its interface states. Other
     modules see only the interface, so if the two ever differ, that's a
     bug in the compiler, and it's caught here rather than in whichever
     module trips over it. *)
  let mismatch name (said : Ty.scheme) (found : Ty.scheme) =
    let show (s : Ty.scheme) =
      Ty.show
        (Ty.printer ~show_tail:(fun _ -> true) ~names:(Resolve.type_name r) s)
        s.ty
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
  List.iter
    (fun (v : Iface.value) ->
      let found = List.assoc v.vname inferred.schemes in
      if found <> v.scheme then mismatch v.vname v.scheme found)
    iface.values;
  (* and so was each public member's, which is in its type's entry *)
  List.iter
    (fun (td : Iface.type_decl) ->
      List.iter
        (fun (o : Iface.op) ->
          let name = td.path.name ^ "." ^ o.oname in
          let found =
            match (o.okind, List.assoc name inferred.schemes) with
            | Value, { ty = Fun ([], t, _, _); names } ->
                Ty.canonical { ty = t; names }
            | _, s -> s
          in
          if found <> o.oscheme then mismatch name o.oscheme found)
        td.ops)
    iface.types;
  (r, iface, inferred)

(* A checked module, lowered to Core. With [lint], Core Lint checks the
   result; the tests turn it on for every program. *)
let lower ?(lint = false) ~imports r inferred =
  let core = pass "lower" (fun () -> Lower.program r inferred) in
  if lint then pass "lint" (fun () -> Core_lint.program ~imports core);
  core

(* The prelude, as a module: its source, parsed and checked against the
   intrinsics (prelude.ml) and lowered (and linted), and its whole
   interface. It's checked once, the first time it's needed: [lazy] delays
   a computation and [Lazy.force] runs it (at most once). It's the same for
   every program, so sharing it is safe. *)
let prelude =
  lazy
    (let prog = parse ~file:"<prelude>" (String.trim Prelude.source) in
     let imports = [ Prelude.intrinsics ] in
     let r, iface, inferred =
       check_module ~home:Path.prelude_home ~imports ~reachable:imports prog
     in
     (lower ~lint:true ~imports r inferred, Iface.union Prelude.intrinsics iface))

(* ---- loading a program's modules ----

   A program is its entry module, every module it imports, every module
   those import, and so on: the import graph. The driver never reads a
   file itself. It asks a loader for each module's source, by the module's
   path (`billing/stripe`), and the loader says where that comes from: the
   CLI reads the files next to the entry, the tests keep them in a list. *)

type loader = string -> string option

(* The file module [path] is: its path from the entry's folder, with
   `.ren` on the end. *)
let module_file ~entry path =
  let dir = Filename.dirname entry in
  if dir = Filename.current_dir_name then path ^ ".ren"
  else Filename.concat dir (path ^ ".ren")

let imports_of (prog : Ast.Parsed.program) =
  List.filter_map (function Ast.Import i -> Some i | _ -> None) prog

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
   that could be loaded has been. *)
let load_all ~(load : loader) ~file src =
  let entry = file in
  let sink = Diag.sink () in
  let report ?help ?notes ?labels loc msg =
    Diag.report sink (Diag.make ?help ?notes ?labels loc msg)
  in
  (* each module once it's done, the last one first. A module that didn't
     parse is done too, so it isn't reported again. *)
  let loaded = ref [] in
  let is_loaded path =
    List.exists (fun (m : source) -> m.home = path) !loaded
  in
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
          let ifile = module_file ~entry i.path in
          match load i.path with
          | None ->
              report i.path_loc
                ~help:"check the module's name, or create its file"
                ~notes:[ sprintf "it would be the file `%s`" ifile ]
                (sprintf "there's no module `%s`" i.path)
          | Some isrc -> visit ~path:(path @ [ (home, i) ]) i.path ifile isrc)
      imports;
    loaded := { home; file; parsed } :: !loaded
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
  let home = Path.home_of_file file in
  if home = Path.prelude_home then
    raise
      (Diag.Errors
         [
           Diag.make (Loc.point ~file 1 1) ~help:"rename the file"
             "a file can't be named `prelude.ren`: that's the name of the \
              module every program imports";
         ]);
  visit ~path:[] home file src;
  if Diag.has_errors sink then raise (Diag.Errors (Diag.reported sink));
  List.rev !loaded

(* ---- checking a program ---- *)

(* One module of the program, checked against the interfaces of the
   prelude and of the modules it imports. *)
type checked = {
  home : string;
  prog : Ast.Parsed.program;
  resolved : Resolve.t;
  iface : Iface.t;
  inferred : Infer.t;
  reachable : Iface.t list;
      (** the interfaces of every module reachable through its imports, the
          prelude's first, each once *)
}

(* Load the program, then check each of its modules in dependency order,
   each against the interfaces of what it imports, never their source.
   Returns them in that order, the entry last. A program of one file loads
   nothing else, so the loader is optional. *)
let check_all ?(load = fun _ -> None) ~file src =
  let _, prelude_iface = Lazy.force prelude in
  let sources = pass "load" (fun () -> load_all ~load ~file src) in
  let entry = Path.home_of_file file in
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
           List.fold_left
             (fun acc (c : checked) ->
               List.fold_left
                 (fun acc (i : Iface.t) ->
                   if List.exists (fun (j : Iface.t) -> j.home = i.home) acc
                   then acc
                   else acc @ [ i ])
                 acc
                 (c.reachable @ [ c.iface ]))
             [ prelude_iface ] direct
         in
         let resolved, iface, inferred =
           check_module ~home:m.home ~imports ~reachable
             ?entry:(if m.home = entry then Some m.file else None)
             m.parsed
         in
         {
           home = m.home;
           prog = m.parsed;
           resolved;
           iface;
           inferred;
           reachable;
         }
         :: done_)
       [] sources)

(* The module the program starts in. *)
let entry_of modules = List.nth modules (List.length modules - 1)
let check ?load ~file src = (entry_of (check_all ?load ~file src)).prog
let inferred ?load ~file src = (entry_of (check_all ?load ~file src)).inferred
let schemes ?load ~file src = (inferred ?load ~file src).schemes
let interface ?load ~file src = (entry_of (check_all ?load ~file src)).iface

let lower_module ?lint (c : checked) =
  lower ?lint ~imports:c.reachable c.resolved c.inferred

let core ?lint ?load ~file src =
  lower_module ?lint (entry_of (check_all ?load ~file src))

(* Every module's signatures, as `ren types` prints them: each function's,
   and each type with members, its members indented under it. *)
let types ?(lint = false) ?load ~file src =
  List.map
    (fun ({ home; inferred; resolved; _ } as c) ->
      (* the tests also check that the program lowers, and lints *)
      if lint then ignore (lower_module ~lint:true c);
      let names = Resolve.type_name resolved in
      let fn_ ?outer ~name (f : Ast.Resolved.fn_def) =
        Ty.signature ?outer ~names ~pub:f.pub ~name
          ~params:
            (List.map
               (fun (p : Ast.Resolved.param) -> p.pname.ident.name)
               f.params)
          (List.assoc f.name.name inferred.schemes)
      in
      ( home,
        List.concat_map
          (function
            | Ast.Fn f -> [ fn_ ~name:f.name.name f ]
            | Type ({ type_ops = _ :: _; _ } as td) ->
                let outer =
                  List.map (fun (p : Ast.ident) -> p.name) td.type_params
                in
                let op (o : Ast.Resolved.op) =
                  let f = o.op_fn in
                  let name = Ast.short_name f.name.name in
                  match o.op_kind with
                  | Op_fn -> fn_ ~outer ~name f
                  | Op_value -> (
                      (* a function of no parameters (ast.ml) *)
                      match List.assoc f.name.name inferred.schemes with
                      | { ty = Fun ([], t, _, _); names = tnames } ->
                          Ty.value_signature ~names ~pub:f.pub ~name
                            { ty = t; names = tnames }
                      | _ -> assert false)
                in
                let params =
                  match outer with
                  | [] -> ""
                  | ps -> "<" ^ String.concat ", " ps ^ ">"
                in
                sprintf "%stype %s%s"
                  (if td.type_pub then "pub " else "")
                  td.type_name.name params
                :: List.map (fun o -> "  " ^ op o) td.type_ops
            | Type _ | Import _ -> [])
          resolved.prog ))
    (check_all ?load ~file src)

(* Check every module, lower each to Core, and run them as one program:
   the prelude, then each module in dependency order, starting from the
   entry's `main`. *)
let run ?lint ?load ~file src =
  let modules = List.map (lower_module ?lint) (check_all ?load ~file src) in
  let prelude, _ = Lazy.force prelude in
  pass "eval" (fun () -> Eval.run (prelude :: modules))

let dump_tokens toks =
  toks |> Array.to_list
  |> List.map (fun (t, _) -> Token.show t)
  |> String.concat " "

(* What to print for an exception a pass raised, or [None] if it isn't one
   the compiler knows about. [sources] is the source map (diag.ml). *)
let render_error ~sources = function
  | Diag.Error d -> Some (Diag.render ~sources d)
  | Diag.Errors ds -> Some (Diag.render_all ~sources ds)
  | Eval.Panic (loc, msg) ->
      Some (Diag.render ~sources (Diag.make loc ("panic: " ^ msg)))
  | Internal_error { pass; message } ->
      Some
        (Printf.sprintf
           "internal compiler error in %s: %s\n\
           \  = this is a bug in the Ren compiler, not in your program\n"
           pass message)
  | _ -> None
