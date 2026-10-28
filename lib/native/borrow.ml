(* Borrow inference (compiler.md, "Native slice"): which of a function's
   parameters it borrows, so a caller lends it a value without counting
   it again, after Lean's InferBorrow.lean and Roc's borrow.rs.

   Every counted parameter of a function only the program's own calls
   reach starts borrowed (Lean's [mkInitParamMap], InferBorrow.lean:86).
   One the body consumes is owned: one it returns, raises, stores in an
   object, an array or a cell, gives to a parameter that's owned, or
   changes, as is one a part of it, or a view of it, is consumed through
   (Lean's [ownVar] of a projection's parent). That's done again until
   nothing changes, since making one parameter owned can make the
   callers' own (Lean's [infer], InferBorrow.lean:263). A function a
   block, a handler or an associated value is made of keeps the modes
   to_mem.ml gave it: its callers don't know which function they call.

   Which parameters are borrowed is only an optimization: a borrowed one
   is counted again where it's kept, so what the program computes never
   depends on it (compiler.md, "What it has to do", rule 1). *)

open Mem

(* The functions whose callers all know them by name. *)
let inferred (p : program) =
  let fixed = Hashtbl.create 16 in
  Hashtbl.replace fixed p.start ();
  List.iter (fun (v : value) -> Hashtbl.replace fixed v.vfn ()) p.values;
  (* a handler's record points at its code *)
  List.iter
    (fun (h : handler) ->
      Hashtbl.replace fixed h.install ();
      List.iter (fun (_, _, f) -> Hashtbl.replace fixed f ()) h.methods)
    p.handlers;
  let see (x : atom) =
    match x with Fn_ptr f -> Hashtbl.replace fixed f () | _ -> ()
  in
  List.iter
    (fun (f : fn) ->
      Rc.iter_stmts
        (fun s ->
          (match s with
          | Let (_, Block_of (name, _)) | Do (Block_of (name, _)) ->
              Hashtbl.replace fixed name ()
          | _ -> ());
          List.iter see (Rc.stmt_atoms s))
        f.body)
    p.fns;
  fun (f : fn) -> not (Hashtbl.mem fixed f.name)

(* The program with each function's parameters' modes decided. *)
let infer (p : program) : program =
  let inferred = inferred p in
  let fns = Hashtbl.create 64 in
  let start (f : fn) =
    if inferred f then
      {
        f with
        modes =
          List.map
            (fun (v : var) -> if counted v.layout then Borrowed else Owned)
            f.params;
      }
    else f
  in
  List.iter (fun (f : fn) -> Hashtbl.replace fns f.name (start f)) p.fns;
  let rec fix () =
    let changed = ref false in
    List.iter
      (fun (f : fn) ->
        let f = Hashtbl.find fns f.name in
        if inferred f then
          let consumed = Rc.consumed fns f in
          let modes =
            List.map2
              (fun (v : var) (m : mode) ->
                match m with
                | Borrowed when consumed v ->
                    changed := true;
                    Owned
                | m -> m)
              f.params f.modes
          in
          Hashtbl.replace fns f.name { f with modes })
      p.fns;
    if !changed then fix ()
  in
  fix ();
  { p with fns = List.map (fun (f : fn) -> Hashtbl.find fns f.name) p.fns }
