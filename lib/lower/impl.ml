(* The implementation tier of a module's summary (module-build.md,
   "Interface summaries"): what the modules that import it will need of it
   to generate code, beside its interface, which is what they need to be
   type checked.

   For now it holds one thing: the typed Core of each public function the
   specializer will copy into its callers, when a release build
   specializes the whole program (compiler.md, "Specialization"). Those
   are the generic ones, whose type variables a caller picks, and the
   higher-order ones, which a caller passes blocks to: release copies
   such a function for each block it's given, so the block inlines and
   nothing is allocated (foundations.md, "Lambdas are blocks"). Nothing
   reads it yet.

   It's kept by path in a map, so its order is fixed, and the Core in it
   has no source locations: like the interface, it mustn't change when a
   blank line is added at the top of the file. Binders are numbered per
   function (lower.ml), so editing one function doesn't renumber another's
   body either. *)

type t = { home : string; bodies : Core.fn_def Path.Map.t }

(* Where every node of a recorded body says it came from: nowhere. *)
let nowhere = Loc.point ~file:"" 0 0

(* The same expression with every location in it, its patterns' too,
   [nowhere]. *)
let rec unplaced (e : Core.expr) : Core.expr =
  let go = unplaced in
  let kind : Core.kind =
    match e.kind with
    | ( Int _ | Float _ | Bool _ | Str _ | Unit | Local _ | Global _
      | Global_value _ | Intrinsic _ | Break ) as k ->
        k
    | Dep_call d -> Dep_call { d with args = List.map go d.args }
    | With w -> With { w with impl = go w.impl; body = go w.body }
    | Handler h -> Handler { h with body = go h.body }
    | Instance { impls; finally; exclusive } ->
        Instance
          {
            impls = List.map (fun (d, e) -> (d, go e)) impls;
            finally = Option.map go finally;
            exclusive;
          }
    | Narrowed (d, e) -> Narrowed (d, go e)
    | With_handler w ->
        With_handler { w with handler = go w.handler; body = go w.body }
    | Prim (p, es) -> Prim (p, List.map go es)
    | Let (v, a, b) -> Let (v, go a, go b)
    | Covered c -> Covered { c with body = go c.body; after = go c.after }
    | Assign (v, a) -> Assign (v, go a)
    | If (c, t, f) -> If (go c, go t, go f)
    | Match (s, arms) ->
        Match
          ( go s,
            List.map
              (fun (a : Core.arm) ->
                {
                  Core.pat = pattern a.pat;
                  guard = Option.map go a.guard;
                  body = go a.body;
                })
              arms )
    | While (c, b) -> While (go c, go b)
    | Seq (a, b) -> Seq (go a, go b)
    | Call (f, args, ev) ->
        Call
          ( go f,
            List.map
              (function Core.Value a -> Core.Value (go a) | Ref v -> Ref v)
              args,
            ev )
    | Lambda l -> Lambda { l with body = go l.body }
    | Con (t, c, es) -> Con (t, c, List.map go es)
    | Record (t, fs) -> Record (t, List.map (fun (f, e) -> (f, go e)) fs)
    | Field (r, t, f) -> Field (go r, t, f)
    | Update (r, f, e) -> Update (go r, f, go e)
    | Array es -> Array (List.map go es)
    | Tuple es -> Tuple (List.map go es)
    | Tag (t, es, ds) -> Tag (t, List.map go es, ds)
    | Fail e -> Fail (go e)
    | Handle h ->
        Handle
          {
            h with
            body = go h.body;
            on_value = go h.on_value;
            on_error = go h.on_error;
          }
    | Assert e -> Assert (go e)
    | Assert_equal (a, b, d, q) -> Assert_equal (go a, go b, d, q)
    | Finally (a, b) -> Finally (go a, go b)
  in
  { e with kind; loc = nowhere }

and pattern (p : Core.pattern) : Core.pattern =
  let pkind : Core.pattern_kind =
    match p.pkind with
    | (PWild | PVar _ | PInt _ | PBool _) as k -> k
    | PCon (t, c, ps) -> PCon (t, c, List.map pattern ps)
    | PTag (t, ps) -> PTag (t, List.map pattern ps)
    | POr ps -> POr (List.map pattern ps)
    | PTuple ps -> PTuple (List.map pattern ps)
  in
  { p with pkind; ploc = nowhere }

(* Whether a type has a function's type in it. *)
let rec has_fn (t : Ty.ty) =
  match t with
  | Fun _ -> true
  | Con (_, ts) -> List.exists has_fn ts
  | Errors r ->
      List.exists (fun (l : Ty.label) -> List.exists has_fn l.payload) r.labels
  | Var _ | Impl _ | Error -> false

(* Whether a function's body is one to record: it has a type variable, or
   a parameter or result with a function in it. Every function has row
   variables, for what it fails with and uses, so those don't count. *)
let recorded (f : Core.fn_def) =
  f.tys <> []
  ||
  match f.scheme.ty with
  | Fun (ps, r, _, _) ->
      List.exists (fun (p : Ty.param) -> has_fn p.ty) ps || has_fn r
  | _ -> false

(* The implementation tier of the module lowered to [core], whose
   interface is [iface]: the bodies of its public functions and public
   members' functions that are generic or higher-order. *)
let of_module (iface : Iface.t) (core : Core.program) =
  let public =
    List.map
      (fun (v : Iface.value) -> Path.make iface.home v.vname)
      (iface.values @ iface.tests)
    @ List.concat_map
        (fun (td : Iface.type_decl) ->
          List.filter_map
            (fun (path, (o : Iface.op)) ->
              match o.okind with
              | Method | Function -> Some path
              | Value -> None)
            (Path.Map.bindings td.members))
        iface.types
  in
  let public = Path.Map.of_list (List.map (fun p -> (p, ())) public) in
  {
    home = core.home;
    bodies =
      List.fold_left
        (fun bodies (f : Core.fn_def) ->
          if Path.Map.mem f.path public && recorded f then
            Path.Map.add f.path
              { f with body = unplaced f.body; loc = nowhere }
              bodies
          else bodies)
        Path.Map.empty core.fns;
  }

(* Each body, in the order of its path, as [Core.show_fn] prints it
   typed. *)
let show t =
  String.concat "\n"
    (List.map
       (fun (_, f) -> Core.show_fn ~types:true f)
       (Path.Map.bindings t.bodies))
