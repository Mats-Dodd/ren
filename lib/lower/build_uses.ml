(* Dependency identities and the inferred reach of a function are ordinary
   data. Queries are resolved before build evaluation; declaration upper
   bounds never supply an edge in this graph. *)
open Core

let uses_path = Path.make "shape" "Uses"
let dep_id_path = Path.make "shape" "DepId"
let shape_path = Path.make "shape" "Shape"
let uses_ty = Ty.Con (uses_path, [])
let dep_id_ty = Ty.Con (dep_id_path, [])
let shape_ty = Ty.Con (shape_path, [])
let data cty ckind = { cty; ckind }
let text s = data Ty.str (CStr s)
let array ty xs = data (Ty.array ty) (CArray xs)

let type_name ty =
  let scheme : Ty.scheme =
    { ty; names = []; reqs = []; row_reqs = []; tparams = [];
      modes = []; defaults = [] } in
  Ty.show (Ty.printer ~names:Path.full scheme) ty

(* Collect the declarations reachable from an argument without depending on
   modules that the argument cannot see. Shape_facts owns the representation. *)
let argument_types lookup args =
  let types = Hashtbl.create 16 in
  let rec walk = function
    | Ty.Con (p, ts) | Variant (p, _, ts) ->
        List.iter walk ts;
        if not (Hashtbl.mem types p) then
          (match lookup p with
          | None -> ()
          | Some (d : Iface.type_decl) ->
              Hashtbl.add types p d;
              let fields fs = List.iter (fun (f : Iface.field) -> walk f.fty) fs in
              (match d.body with
              | Record fs | Dep fs -> fields fs
              | Sum cs -> List.iter (fun (c : Iface.ctor) -> fields c.cfields) cs
              | Opaque (Rep t) -> walk t
              | Dep_alias d -> List.iter walk d.dargs
              | _ -> ()))
    | _ -> () in
  List.iter walk args;
  types

let rec closed = function
  | Ty.Var _ | Fun _ | Impl _ | Error -> false
  | Con (_, ts) | Variant (_, _, ts) -> List.for_all closed ts
  | Errors r -> r.tail = None && List.for_all
      (fun (l : Ty.label) -> List.for_all closed l.payload) r.labels

let dep_constant ?(lookup = fun _ -> None) ?(home = "") ~loc path args =
  if not (List.for_all closed args) then
    Diag.error loc
      ~help:"inspect the dependency at concrete type arguments"
      "a dependency identity needs concrete data type arguments";
  let types = argument_types lookup args in
  data dep_id_ty
    (CRecord ["name", text (Path.full path);
              "args", array shape_ty
                (let _ = home in
                 List.map (Shape_facts.shape ~types ~home:"") args)])

type reach = { dep : Ty.dep; via : string list }

(* Callable values are latent. In particular a block generator's pull row
   need not mention the evidence its frame captured when it was created.
   Keep the producer and its actual arguments until a pull activates it.
   Cells are shared by aliases and captured blocks, just as in Eval. *)
type origin = {
  identity : int;
  code : expr;
  context : context;
  inputs : origin list list;
}
and context = {
  owner : fn_def;
  arguments : Ty.args;
  installed : Ty.dep list;
  locals : (int * origin list ref) list;
  returned : origin list ref;
}

let collector (modules : program list) =
  let fns = Hashtbl.create 128 in
  List.iter (fun (m : program) ->
      List.iter (fun (f : fn_def) -> Hashtbl.replace fns f.path f) m.fns) modules;
  let paths p args ?(bindings = []) ?expression ?(visit = fun _ -> ()) () =
    let found = ref [] and active = Hashtbl.create 16 in
    let add dep via =
      match List.find_opt (fun r -> r.dep = dep) !found with
      | Some old when List.length old.via <= List.length via -> ()
      | _ -> found := List.filter (fun r -> r.dep <> dep) !found @ [{dep; via}]
    in
    let serial = ref 0 in
    (* Recursive calls can carry different blocks/cursors. Their finite set
       of source sites and captured evidence distinguishes those calls without
       unrolling a fresh closure tree on every recursive visit. *)
    let fingerprint values =
      let seen = Hashtbl.create 8 and sites = ref [] and edges = ref [] in
      let site o =
        let kind = match o.code.kind with
          | Global (p, _, _, _) -> `Global p
          | Gen_create g -> `Generator g.producer
          | Lambda l -> `Lambda l.name
          | _ -> assert false in
        o.context.owner.path, o.code.loc, kind, o.context.arguments,
        List.sort_uniq compare o.context.installed in
      let rec visit o =
        if not (Hashtbl.mem seen o.identity) then (
          Hashtbl.add seen o.identity ();
          let source = site o in
          sites := source :: !sites;
          let children slot values = List.iter (fun child ->
              edges := (source, slot, site child) :: !edges; visit child) values in
          List.iteri (fun i -> children (`Argument i)) o.inputs;
          List.iter (fun (id, cell) -> children (`Local id) !cell) o.context.locals)
      in
      List.iter visit values;
      List.sort_uniq compare !sites, List.sort_uniq compare !edges
    in
    let union a b =
      List.fold_left (fun result o ->
          if List.exists (fun old -> old.identity = o.identity) result then result
          else o :: result) a b in
    let origin cx e inputs =
      incr serial;
      [{ identity = !serial; code = e; context = cx; inputs }]
    in
    let get cx v = match List.assoc_opt v.id cx.locals with
      | Some cell -> !cell | None -> [] in
    let bind cx v value = { cx with locals = (v.id, ref value) :: cx.locals } in
    let update cx v value = match List.assoc_opt v.id cx.locals with
      | Some cell -> cell := union !cell value | None -> () in
    let rec pattern cx p value = match p.pkind with
      | PVar v -> bind cx v value
      | PAs (p, v) -> bind (pattern cx p value) v value
      | PCon (_, _, ps) | PTag (_, ps) | PTuple ps | PRecord (_, ps) | POr ps ->
          List.fold_left (fun cx p -> pattern cx p value) cx ps
      | PArray {front; rest; back} ->
          let cx = List.fold_left (fun cx p -> pattern cx p value) cx (front @ back) in
          (match rest with Rest (Some v) -> bind cx v value | _ -> cx)
      | PStr_rest {rest = Some v; _} -> bind cx v value
      | _ -> cx in
    let apply (args : Ty.args) ty =
      (* Inference-local ambient row extensions are not parameters of the
         enclosing function. Close those extensions, retaining their heads;
         actual quantified rows still use the caller's supplied labels. *)
      let own = Ty.own_args ty in
      let padded : Ty.args = {
        tys = List.mapi (fun n identity ->
            Option.value (List.nth_opt args.tys n) ~default:identity) own.tys;
        rows = List.mapi (fun n _ ->
            Option.value (List.nth_opt args.rows n) ~default:Ty.closed) own.rows } in
      Ty.apply padded ty in
    let apply_row args row = match apply args (Ty.Errors row) with
      | Ty.Errors row -> row | _ -> assert false in
    let instantiate cx (a : Ty.args) : Ty.args =
      { tys = List.map (apply cx.arguments) a.tys;
        rows = List.map (apply_row cx.arguments) a.rows } in
    let rec fn installed via p args inputs =
      let installed = List.sort_uniq compare installed in
      let key = `Function p, args, installed, List.map fingerprint inputs in
      if not (Hashtbl.mem active key) then
        match Hashtbl.find_opt fns p with
        | None -> []
        | Some f ->
            Hashtbl.add active key ();
            let cx = { owner = f; arguments = args; installed; locals = [];
                       returned = ref [] } in
            let rec parameters cx ps xs = match ps, xs with
              | (p : param) :: ps, x :: xs -> parameters (bind cx p.var x) ps xs
              | _ -> cx in
            let cx = parameters cx f.params inputs in
            let value = expr cx (via @ [Path.local p]) f.body in
            Hashtbl.remove active key;
            union value !(cx.returned)
      else []
    and desc f args = function
      | Known t -> apply args t
      | Param v ->
          let rec index i = function
            | [] -> Ty.Error
            | (x : var) :: rest ->
                if x.id = v.id then apply args (Ty.Var i) else index (i + 1) rest in
          index 0 f.tys
      | Applied (p, ds) -> Ty.Con (p, List.map (desc f args) ds)
      | Applied_variant (p, c, ds) -> Ty.Variant (p, c, List.map (desc f args) ds)
      | Errs r ->
          let labels = List.map (fun (name, ds) ->
              { Ty.name; payload = List.map (desc f args) ds }) r.dlabels in
          let rest = apply_row args {Ty.labels = []; tail = r.dtail} in
          Ty.Errors {labels = Ty.sort_labels (labels @
              List.filter (fun l -> not (List.exists (Ty.same_label l) labels)) rest.labels);
                     tail = rest.tail}
    and activate cx via inputs o =
      let captured = o.context in
      match o.code.kind with
      | Global (p, a, _, _) -> fn cx.installed via p (instantiate captured a) inputs
      | Gen_create g ->
          let installed = match Hashtbl.find_opt fns g.producer with
            | Some {generator = Some {kind = Ty.Block_gen; _}; _} -> captured.installed
            | _ -> cx.installed in
          List.iter (fun (p : gen_place) ->
              ignore (expr captured via p.read);
              ignore (expr captured via p.write)) g.places;
          ignore (fn installed via g.producer (instantiate captured g.type_args) o.inputs);
          []
      | Lambda l ->
          let installed = List.fold_left (fun ds (k : dkey) ->
              let dep = {Ty.dpath = k.kpath;
                         dargs = List.map (desc captured.owner captured.arguments) k.kargs} in
              let ds = List.filter ((<>) dep) ds in
              if List.mem dep cx.installed then dep :: ds else ds) captured.installed l.given
              |> List.sort_uniq compare in
          let key = `Block (captured.owner.path, o.code.loc), captured.arguments,
                    installed, List.map fingerprint (inputs @ [ [o] ]) in
          if Hashtbl.mem active key then [] else (
            Hashtbl.add active key ();
            let inner = {captured with installed; returned = ref []} in
            let rec parameters cx ps xs = match ps, xs with
              | (p : param) :: ps, x :: xs -> parameters (bind cx p.var x) ps xs
              | _ -> cx in
            let inner = parameters inner l.params inputs in
            let value = expr inner via l.body in
            Hashtbl.remove active key;
            union value !(inner.returned))
      | _ -> []
    and expr cx via (e : expr) =
      visit e;
      let f = cx.owner and args = cx.arguments and installed = cx.installed in
      let go = expr cx via in
      let row via row = List.iter (fun (l : Ty.label) ->
          let dep = { Ty.dpath = Ty.dep_path l.name; dargs = l.payload } in
          if not (List.mem dep installed) then add dep via) row.Ty.labels in
      let needs (x : expr) = match apply args x.ty with
        | Ty.Impl i -> row (via @ ["installing handler"]) i.needs
        | _ -> () in
      match e.kind with
      | Function_uses _ -> []
      | Local v -> get cx v
      | Global _ -> origin {cx with locals = []} e []
      | Lambda l ->
          let locals = List.filter (fun (id, _) ->
              List.exists (fun (v : var) -> v.id = id) l.captures) cx.locals in
          origin {cx with locals} e []
      | Gen_create g ->
          let inputs = List.map (function Value x -> go x | Ref v -> get cx v) g.args in
          origin cx e inputs
      | Let (v, a, b) -> expr (bind cx v (go a)) via b
      | Assign (v, x) | Owned_assign {target = v; value = x; _} ->
          update cx v (go x); []
      | Seq (a, b) -> ignore (go a); go b
      | Finally (a, b) -> let value = go a in ignore (go b); value
      | Return (_, x) ->
          cx.returned := union !(cx.returned) (go x); []
      | If (condition, a, b) -> ignore (go condition); union (go a) (go b)
      | Match (source, arms) ->
          let value = go source in
          List.fold_left (fun values arm ->
              let inner = pattern cx arm.pat value in
              Option.iter (fun guard -> ignore (expr inner via guard)) arm.guard;
              union values (expr inner via arm.body)) [] arms
      | Pattern_scope p ->
          let inner = pattern cx p.pat (go p.source) in
          let value = expr inner via p.on_match in
          union value (match p.on_else with None -> [] | Some x -> go x)
      | Handle h ->
          let value = go h.body in
          union (expr (bind cx h.value value) via h.on_value) (go h.on_error)
      | Covered c -> expr (bind cx c.result (go c.body)) via c.after
      | While (condition, body) ->
          let state () = List.map (fun (id, cell) -> id, fingerprint !cell) cx.locals in
          let rec loop () =
            let before = state () in
            ignore (go condition); ignore (go body);
            if state () <> before then loop () in
          loop (); []
      | Own {value; _} | Source_view {value; _} | Of_variant value
      | Cleanup_scope {body = value; _} | Instance_scope {body = value; _}
      | Owner_alias {body = value; _} -> go value
      | Gen_step g ->
          let origins = get cx g.cursor in
          if origins = [] then row (via @ ["pulling generator"]) (apply_row args g.uses);
          List.fold_left (fun values o -> union values (activate cx via [] o)) [] origins
      | Gen_close x -> ignore (go x); []
      | Yield_from y ->
          let origins = go y.pull in
          List.iter (fun o -> ignore (activate cx via [] o)) origins; []
      | Dep_call d ->
          List.iter (fun x -> ignore (go x)) d.args;
          let dep : Ty.dep = { dpath = d.dep; dargs = List.map (desc f args) d.dargs } in
          if not (List.mem dep installed) then
            add dep (via @ [Path.local d.dep ^ "." ^ d.op]);
          []
      | Call (callee, xs, _) ->
          let origins = go callee in
          let inputs = List.map (function Value x -> go x | Ref v -> get cx v) xs in
          if origins = [] then (
            (match apply args callee.ty with
            | Ty.Fun (_, _, _, uses) -> row (via @ ["calling block"]) uses
            | _ -> ());
            (* An intrinsic or an unknown block can invoke its callbacks. *)
            List.iter (List.iter (fun o -> ignore (activate cx via [] o))) inputs);
          List.fold_left (fun values o -> union values (activate cx via inputs o)) [] origins
      | With w ->
          ignore (go w.impl);
          needs w.impl;
          let dep : Ty.dep = { dpath = w.dep; dargs = List.map (desc f args) w.dargs } in
          expr {cx with installed = dep :: installed} via w.body
      | With_handler w ->
          ignore (go w.handler);
          needs w.handler;
          let ds = List.map (fun ((k : dkey), _) ->
              { Ty.dpath = k.kpath; dargs = List.map (desc f args) k.kargs }) w.deps in
          expr {cx with installed = ds @ installed} via w.body
      | Instance i ->
          List.iter (fun (_, x) -> ignore (go x)) i.impls;
          Option.iter (fun x -> ignore (go x)) i.finally; []
      | _ -> List.fold_left (fun values x -> union values (go x)) [] (children e)
    in
    (match expression with
    | None -> ignore (fn [] [] p args [])
    | Some expression ->
        (match Hashtbl.find_opt fns p with
        | None -> ()
        | Some owner ->
            let cx = {owner; arguments = args; installed = []; locals = [];
                      returned = ref []} in
            let cx = List.fold_left (fun cx (v, value) ->
                bind cx v (expr cx [Path.local p] value)) cx bindings in
            ignore (expr cx [Path.local p] expression)));
    List.sort (fun a b -> compare a.dep b.dep) !found
  in
  paths

(* Signature bindings use the same latent-value analysis as architecture
   assertions. Bindings are evaluated in source order in the owner's scope. *)
let expression modules ~(owner : fn_def) ~arguments ?bindings ?visit value =
  collector modules owner.path arguments ?bindings ?visit ~expression:value ()

let program (modules : program list) =
  let fns = Hashtbl.create 128 and types = Hashtbl.create 64 in
  List.iter (fun (m : program) ->
      List.iter (fun (d : Iface.type_decl) -> Hashtbl.replace types d.path d) m.types;
      List.iter (fun (f : fn_def) -> Hashtbl.replace fns f.path f) m.fns) modules;
  let collect = collector modules in
  let paths p args = collect p args () in
  (* New build roots are checked against actual inferred reach. A private
     helper's written row can be wider than its body; its upper bound is
     therefore insufficient to decide whether an initializer is pure. *)
  List.iter (fun (m : program) -> List.iter (fun p ->
      match Hashtbl.find_opt fns p with
      | None -> ()
      | Some f ->
          let reached = paths p (Ty.own_args f.scheme.ty) in
          if reached <> [] then
            let names = List.map (fun r -> Path.full r.dep.dpath) reached in
            Diag.error f.loc
              ~notes:(List.map (fun r -> String.concat " → " r.via) reached)
              ~help:"the build's world comes with packages; use pure data while building"
              ("the build-time value `" ^ Path.local p ^ "` uses " ^
               String.concat ", " names))
      (m.build_values @ m.build_asserts)) modules;
  let queries (root : expr) =
    let seen = Hashtbl.create 8 in
    let rec walk (e : expr) =
      match e.kind with
      | Function_uses (p, args) -> paths p args
      | Global_value (p, _) when not (Hashtbl.mem seen p) ->
          Hashtbl.add seen p ();
          (match Hashtbl.find_opt fns p with Some f -> walk f.body | None -> [])
      | _ -> List.concat_map walk (children e)
    in walk root
  in
  let traces = ref [] in
  let rec replace (e : expr) =
    (match e.kind with
    | Assert checked | Assert_equal (checked, _, _, _) ->
        let notes = List.map
            (fun r -> Path.full r.dep.dpath ^ ": " ^ String.concat " → " r.via)
            (queries checked) |> List.sort_uniq String.compare in
        if notes <> [] then
          let loc = match e.kind with Assert a -> a.loc | _ -> e.loc in
          traces := (loc, notes) :: !traces
    | _ -> ());
    match e.kind with
    | Function_uses (p, args) ->
        let values = List.map (fun r -> dep_constant
            ~lookup:(Hashtbl.find_opt types) ~home:p.home ~loc:e.loc
            r.dep.dpath r.dep.dargs) (paths p args) in
        { e with kind = Const (data uses_ty (CArray values)) }
    | _ -> Core.map_children replace e
  in
  let modules = List.map (fun (m : program) ->
      { m with fns = List.map (fun (f : fn_def) ->
          { f with body = replace f.body }) m.fns }) modules in
  modules, List.rev !traces
