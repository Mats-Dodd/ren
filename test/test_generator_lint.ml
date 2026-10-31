(* Deliberately malformed Core, independent of source rejection. Every bad
   case starts from the same valid producer/factory and changes one contract.
   Accepting malformed Core raises instead of becoming a promotable message. *)
open Ren
open Core

let loc = Loc.point ~file:"generator_lint.ren" 1 1
let path name = Path.make "generator_lint" name
let node kind ty = Core.mk kind ty loc
let unit () = Core.unit loc
let int n = node (Int (Int64.of_int n)) Ty.int
let cursor_path = Ty.generator_cursor (path "values")
let cursor item = Ty.Con (cursor_path, [ item ])

let scheme ty : Ty.scheme =
  { ty; tparams = []; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] }

let function_ ?generator ?(params = []) name ret body : fn_def =
  {
    path = path name;
    params;
    ev = Core.evidence 1;
    tys = [];
    dicts = [];
    generator;
    scheme =
      scheme
        (Ty.Fun
           (List.map (fun (p : param) -> { Ty.mode = p.mode; ty = p.var.ty }) params,
            ret, Ty.closed, Ty.closed));
    body;
    test = false;
    loc;
    origin = Written;
    known = [];
  }

let producer () =
  let x : var = { id = 2; name = "x"; ty = Ty.Var 0 } in
  let g : Ty.generator =
    {
      path = path "values";
      cursor_path;
      cursor_args = [ Ty.Var 0 ];
      item = Ty.Var 0;
      errors = Ty.closed;
      uses = Ty.closed;
      kind = Value_gen;
      holds_instance = false;
      replay_unsafe = false;
      params = [ Ty.read (Ty.Var 0) ];
    }
  in
  let f =
    function_ ~generator:g ~params:[ { mode = Read; var = x } ] "values"
      (cursor (Ty.Var 0))
      (node (Yield (Core.local x loc)) Ty.unit)
  in
  { f with tys = [ Core.type_param 0 ]; scheme = { f.scheme with names = [ 0, "T" ] } }

let create ?(args = [ Value (int 1) ]) ?(descs = [ Known Ty.int ]) ?(places = []) () =
  node
    (Gen_create
       { producer = path "values"; type_args = { tys = [ Ty.int ]; rows = [] };
         args; places; tys = descs; dicts = []; ev = Core.evidence 1 })
    (cursor Ty.int)

let program fns : Core.program =
  let td : Iface.type_decl =
    { path = cursor_path; params = [ "T" ]; body = Builtin;
      members = Path.Map.empty; numeric = None; opaque = false; loc = None }
  in
  { home = "generator_lint"; types = [ td ]; fns; values = []; build_values = []; build_asserts = []; shows = [];
    keys = []; ops = []; method_calls = [] }

let lint fns =
  let p = program fns in
  Core_lint.program ~imports:[] ~linked:[ p ] p

let contains text part =
  let rec at i =
    i + String.length part <= String.length text &&
    (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let rejected label reason fns =
  match lint fns with
  | () -> failwith ("Core Lint accepted malformed generator: " ^ label)
  | exception Failure message ->
      if not (String.starts_with ~prefix:"Core Lint:" message && contains message reason)
      then failwith ("wrong Core Lint rejection for " ^ label ^ ": " ^ message);
      print_endline ("rejected: " ^ label)

let%expect_test "a generic generator factory is valid Core" =
  lint [ producer (); function_ "main" (cursor Ty.int) (create ()) ];
  print_endline "valid generator Core";
  [%expect {| valid generator Core |}]

let%expect_test "yield and delegation remain inside their own producer" =
  rejected "yield in an ordinary function" "a yield outside a producer"
    [ function_ "main" Ty.unit (node (Yield (int 1)) Ty.unit) ];
  let f = producer () in
  let block_ty = Ty.Fun ([], Ty.unit, Ty.closed, Ty.closed) in
  let block : var = { id = 3; name = "block"; ty = block_ty } in
  let literal =
    node
      (Lambda
         { name = "nested"; params = []; ev = Core.evidence 4; outer = f.ev;
           given = []; captures = [ f.ev ];
           body = node (Yield (int 1)) Ty.unit })
      block_ty
  in
  rejected "yield in a nested lambda" "a yield outside a producer"
    [ { f with body = node (Let (block, literal, unit ())) Ty.unit } ];
  rejected "yield in cleanup" "a yield outside a producer"
    [ { f with body = node (Finally (unit (), node (Yield (int 1)) Ty.unit)) Ty.unit } ];
  rejected "delegation in an ordinary function" "delegation outside a producer"
    [ function_ "main" Ty.unit (node (Yield_from { pull = int 1; adapter = false }) Ty.unit) ];
  rejected "delegation without a pull block" "delegation without a checked pull block"
    [ { f with body = node (Yield_from { pull = int 1; adapter = false }) Ty.unit } ];
  [%expect {|
    rejected: yield in an ordinary function
    rejected: yield in a nested lambda
    rejected: yield in cleanup
    rejected: delegation in an ordinary function
    rejected: delegation without a pull block
    |}]

let%expect_test "return preserves its target and generators return Unit" =
  rejected "return to another function" "a return outside its function"
    [ function_ "main" Ty.unit (node (Return (path "other", unit ())) Ty.unit) ];
  let f = producer () in
  rejected "generator return with an item" "a returned value"
    [ { f with body = node (Return (f.path, int 1)) Ty.unit } ];
  rejected "return in cleanup" "a return outside its function"
    [ { f with body =
          node (Finally (unit (), node (Return (f.path, unit ())) Ty.unit)) Ty.unit } ];
  [%expect {|
    rejected: return to another function
    rejected: generator return with an item
    rejected: return in cleanup
    |}]

let%expect_test "creation checks arguments descriptors and producer classification" =
  let f = producer () in
  let main body = function_ "main" (cursor Ty.int) body in
  rejected "creation argument count" "wrong number of arguments"
    [ f; main (create ~args:[] ()) ];
  rejected "creation argument type" "a generator argument"
    [ f; main (create ~args:[ Value (node (Bool true) Ty.bool) ] ()) ];
  let r : var = { id = 5; name = "r"; ty = Ty.int } in
  rejected "read argument passed as inout" "a generator read argument passed as inout"
    [ f; { (main (create ())) with params = [ { mode = Read; var = r } ];
           scheme = scheme (Ty.Fun ([ Ty.read Ty.int ], cursor Ty.int, Ty.closed, Ty.closed));
           body = create ~args:[ Ref r ] () } ];
  rejected "creation descriptor mismatch" "described as `Bool`, but is `Int`"
    [ f; main (create ~descs:[ Known Ty.bool ] ()) ];
  rejected "missing creation descriptor" "but 0 descriptors"
    [ f; main (create ~descs:[] ()) ];
  let g = Option.get f.generator in
  rejected "block classification with a cursor factory result"
    "a block generator's factory doesn't return a pull block"
    [ { f with generator = Some { g with kind = Block_gen } } ];
  rejected "producer parameter metadata mismatch" "a producer's parameters don't match its factory"
    [ { f with generator = Some { g with params = [] } } ];
  rejected "direct producer call" "a generator called without creating its frame"
    [ f; main
        (node
           (Call
              (node (Global (f.path, { tys = [ Ty.int ]; rows = [] }, [ Known Ty.int ], []))
                 (Ty.Fun ([ Ty.read Ty.int ], cursor Ty.int, Ty.closed, Ty.closed)),
               [ Value (int 1) ], Core.evidence 1))
           (cursor Ty.int)) ];
  [%expect {|
    rejected: creation argument count
    rejected: creation argument type
    rejected: read argument passed as inout
    rejected: creation descriptor mismatch
    rejected: missing creation descriptor
    rejected: block classification with a cursor factory result
    rejected: producer parameter metadata mismatch
    rejected: direct producer call
    |}]

let%expect_test "generated cursors have no derived equality hash or ordering dictionary" =
  let cty = cursor Ty.int in
  let c : var = { id = 2; name = "cursor"; ty = cty } in
  let dictionary req = Derived { req; dty = cty; ddesc = Known cty; from = [] } in
  let main ret body = function_ ~params:[ { mode = Read; var = c } ] "main" ret body in
  rejected "derived cursor equality" "`eq` to derive"
    [ producer (); main Ty.bool
        (node (Prim (Equal (dictionary "eq"), [ Core.local c loc; Core.local c loc ])) Ty.bool) ];
  let hash_ty = Ty.Fun ([ Ty.read cty ], Ty.int, Ty.closed, Ty.closed) in
  let hash =
    node (Intrinsic (Intrinsic.Hash, { tys = [ cty ]; rows = [ Ty.closed; Ty.closed ] }, [ Known cty ], [ dictionary "hash" ])) hash_ty
  in
  rejected "derived cursor hash" "`hash` to derive"
    [ producer (); main Ty.int (node (Call (hash, [ Value (Core.local c loc) ], Core.evidence 1)) Ty.int) ];
  rejected "derived cursor ordering" "`ord` to derive"
    [ producer (); main Ty.bool
        (node (Prim (Compare (Ast.Lt, dictionary "ord"), [ Core.local c loc; Core.local c loc ])) Ty.bool) ];
  [%expect {|
    rejected: derived cursor equality
    rejected: derived cursor hash
    rejected: derived cursor ordering
    |}]

let%expect_test "generator step rows and delegation adapters cannot bypass their metadata" =
  let f = producer () in
  rejected "forged delegation adapter" "a delegation adapter isn't a generated pull block"
    [ { f with body = node (Yield_from { pull = int 1; adapter = true }) Ty.unit } ];
  let c : var = { id = 8; name = "cursor"; ty = cursor Ty.int } in
  let step errors ty =
    function_ ~params:[ { mode = Inout; var = c } ] "main" ty
      (node (Gen_step { cursor = c; ev = Core.evidence 1; errors; uses = Ty.closed }) ty)
  in
  let bad : Ty.row = { labels = [ { name = "Bad"; payload = [] } ]; tail = None } in
  rejected "step row mismatch" "a generator step's rows don't match its cursor"
    [ f; step bad (Ty.option Ty.int) ];
  rejected "step item mismatch" "a generator step"
    [ f; step Ty.closed (Ty.option Ty.bool) ];
  rejected "closing an ordinary scalar" "closing something that isn't a cursor or pull block"
    [ function_ "main" Ty.unit (node (Gen_close (int 1)) Ty.unit) ];
  let p : var = { id = 9; name = "projected"; ty = Ty.int } in
  rejected "projected place on a data cursor" "a value generator retains a projected inout place"
    [ f; function_ "main" (cursor Ty.int)
        (create ~places:[ { param = p; root = p; read = int 1; write = unit () } ] ()) ];
  [%expect {|
    rejected: forged delegation adapter
    rejected: step row mismatch
    rejected: step item mismatch
    rejected: closing an ordinary scalar
    rejected: projected place on a data cursor
    |}]

let%expect_test "retained inout callbacks preserve the same root and frozen projection" =
  let f = producer () in
  let g = Option.get f.generator in
  let inout ty : Ty.param = { mode = Inout; ty } in
  let pull item = Ty.Fun ([], Ty.option item, Ty.closed, Ty.closed) in
  let f =
    { f with
      params = List.map (fun (p : param) -> { p with mode = Inout }) f.params;
      generator = Some { g with kind = Block_gen; params = [ inout (Ty.Var 0) ] };
      scheme = { f.scheme with ty = Ty.Fun ([ inout (Ty.Var 0) ], pull (Ty.Var 0), Ty.closed, Ty.closed) } }
  in
  let root : var = { id = 10; name = "root"; ty = Ty.array Ty.int } in
  let other : var = { id = 11; name = "other"; ty = root.ty } in
  let index : var = { id = 12; name = "index"; ty = Ty.int } in
  let leaf : var = { id = 13; name = "leaf"; ty = Ty.int } in
  let block : var = { id = 14; name = "frame"; ty = pull Ty.int } in
  let read at = node (Prim (Get_index Checked, [ Core.local root loc; at ])) Ty.int in
  let write target at =
    let value = node (Prim (Set_index Checked,
        [ Core.local target loc; at; Core.local leaf loc ])) target.ty in
    node (Owned_assign { target; value; mode = Advance_value }) Ty.unit
  in
  let place : gen_place =
    { param = leaf; root; read = read (Core.local index loc);
      write = write root (Core.local index loc) }
  in
  let main places =
    let factory =
      node (Gen_create { producer = f.path;
          type_args = { tys = [ Ty.int ]; rows = [] }; args = [ Ref leaf ]; places;
          tys = [ Known Ty.int ]; dicts = []; ev = Core.evidence 1 }) block.ty
    in
    function_ ~params:[ { mode = Inout; var = root }; { mode = Inout; var = other };
                       { mode = Read; var = index }; { mode = Inout; var = leaf } ]
      "main" Ty.unit (node (Let (block, factory, unit ())) Ty.unit)
  in
  lint [ f; main [ place ] ];
  print_endline "valid retained projection";
  let reason = "doesn't read and write the same projection" in
  rejected "write through another root" reason
    [ f; main [ { place with write = write other (Core.local index loc) } ] ];
  rejected "write through another index" reason
    [ f; main [ { place with write = write root (int 1) } ] ];
  rejected "recompute the index on resume" reason
    [ f; main [ { place with read = read (node (Prim (Binop Ast.Add,
          [ Core.local index loc; int 1 ])) Ty.int) } ] ];
  rejected "retain one leaf twice" "a generator retains one parameter place twice"
    [ f; main [ place; place ] ];
  rejected "return through a retained callback" "a return outside its function"
    [ f; main [ { place with read = node (Return (path "main", unit ())) Ty.int } ] ];
  [%expect {|
    valid retained projection
    rejected: write through another root
    rejected: write through another index
    rejected: recompute the index on resume
    rejected: retain one leaf twice
    rejected: return through a retained callback
    |}]

let%expect_test "value-generator metadata cannot retain a scope or instantiate a background capability" =
  let scope = Ty.Con (Path.prelude "Scope", []) in
  let value : var = { id = 2; name = "scope"; ty = scope } in
  let g = Option.get (producer ()).generator in
  let g = { g with params = [ Ty.read scope ]; item = Ty.int; cursor_args = [ Ty.int ] } in
  rejected "scope parameter marked as value data"
    "a value cursor retains a block, inout parameter, dependency or ambient runtime state"
    [ function_ ~generator:g ~params:[ { mode = Read; var = value } ] "values"
        (cursor Ty.int) (node (Yield (int 1)) Ty.unit) ];
  let background = Ty.Con (Path.prelude "Background", [ Ty.Errors Ty.closed ]) in
  let value : var = { id = 2; name = "background"; ty = background } in
  let factory =
    node (Gen_create { producer = path "values";
        type_args = { tys = [ background ]; rows = [] };
        args = [ Value (Core.local value loc) ]; places = []; tys = [ Known background ];
        dicts = []; ev = Core.evidence 1 }) (cursor background)
  in
  rejected "generic value cursor instantiated with a capability"
    "a value cursor is instantiated with a block or capability"
    [ producer (); function_ ~params:[ { mode = Read; var = value } ]
        "main" (cursor background) factory ];
  [%expect {|
    rejected: scope parameter marked as value data
    rejected: generic value cursor instantiated with a capability
    |}]

let%expect_test "ambient runtime behavior cannot be marked as a replayable value generator" =
  let f = producer () in
  let g = Option.get f.generator in
  rejected "ambient behavior marked as replayable value data"
    "a value cursor retains a block, inout parameter, dependency or ambient runtime state"
    [ { f with generator = Some { g with replay_unsafe = true } } ];
  [%expect {| rejected: ambient behavior marked as replayable value data |}]

let%expect_test "an ordinary let expression cannot return a block as a binding value" =
  let block_ty = Ty.Fun ([], Ty.unit, Ty.closed, Ty.closed) in
  let inner : var = { id = 3; name = "inner"; ty = block_ty } in
  let outer : var = { id = 4; name = "outer"; ty = block_ty } in
  let literal =
    node (Lambda { name = "ordinary"; params = []; ev = Core.evidence 2;
        outer = Core.evidence 1; given = []; captures = [ Core.evidence 1 ]; body = unit () }) block_ty
  in
  let alias = node (Let (inner, literal, Core.local inner loc)) block_ty in
  rejected "ordinary block result hidden behind a let"
    "a block that isn't called, passed, or the value of a `let`"
    [ function_ "main" Ty.unit (node (Let (outer, alias, unit ())) Ty.unit) ];
  [%expect {| rejected: ordinary block result hidden behind a let |}]

let%expect_test "pattern statement ownership cannot escape into the continuation or its arguments" =
  let receiving : var = { id = 30; name = "receiving"; ty = Core.owner_ty } in
  let source_owner : var = { id = 31; name = "source_owner"; ty = Core.owner_ty } in
  let bound : var = { id = 32; name = "bound"; ty = Ty.int } in
  let pat = { pkind = PVar bound; pty = Ty.int; ploc = loc } in
  let source = node (Source_view { retained = false; value = int 1 }) Ty.int in
  let scoped ?(receiving = receiving) ?(source = source) ?(on_match = unit ()) ?on_else () =
    node (Cleanup_scope { owner = receiving;
        body = node (Pattern_scope { owner = source_owner; receiving; binding = None; source; pat;
            on_match; on_else }) Ty.unit }) Ty.unit
  in
  lint [ function_ "main" Ty.unit (scoped ()) ];
  print_endline "valid pattern statement owner";
  rejected "source provenance outside a pattern" "a source view outside a pattern source result"
    [ function_ "main" Ty.int source ];
  rejected "source owner referenced after matching" "outside its scope"
    [ function_ "main" Ty.unit
        (scoped ~on_match:(node (Seq (Core.local source_owner loc, unit ())) Ty.unit) ()) ];
  rejected "pattern variable referenced in else" "outside its scope"
    [ function_ "main" Ty.unit
        (scoped ~on_else:(node (Seq (Core.local bound loc, unit ())) Ty.unit) ()) ];
  let argument : var = { id = 2; name = "argument"; ty = Ty.int } in
  let identity = function_ ~params:[ { mode = Read; var = argument } ]
      "identity" Ty.int (Core.local argument loc) in
  let call = node (Call
      (node (Global (identity.path, { tys = []; rows = [] }, [], [])) identity.scheme.ty,
       [ Value source ], Core.evidence 1)) Ty.int in
  rejected "source provenance in a call argument" "a source view outside a pattern source result"
    [ identity; function_ "main" Ty.unit (scoped ~source:call ()) ];
  let invalid : var = { id = 33; name = "not_owner"; ty = Ty.int } in
  let wrong = node (Pattern_scope { owner = source_owner; receiving = invalid; binding = None;
      source; pat; on_match = unit (); on_else = None }) Ty.unit in
  rejected "nonowner receiving binding" "a pattern receiving owner"
    [ function_ ~params:[ { mode = Read; var = invalid } ] "main" Ty.unit wrong ];
  [%expect {|
    valid pattern statement owner
    rejected: source provenance outside a pattern
    rejected: source owner referenced after matching
    rejected: pattern variable referenced in else
    rejected: source provenance in a call argument
    rejected: nonowner receiving binding
    |}]
