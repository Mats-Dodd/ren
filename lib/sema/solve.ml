(* The constraint solver (compiler.md, "The constraint solver"). Checking
   a group's bodies leaves constraints, things that have to hold of its
   types and rows but can be decided only once every body is checked
   (Infer_env.constr). The solver decides them, once the group is done.

   Each kind of constraint has a rank, and the solver decides every
   constraint of one rank before it starts the next: a later rank reads
   what an earlier one decides. Within a rank, it takes them in the order
   they were met. Most are decided once; an inclusion is decided again
   whenever the row it adds from has gained a label, until none has: a
   worklist, which ends because rows only ever gain labels, and each has
   finitely many to gain.

   A constraint that fails is reported, and changes nothing: it's tried on
   copies of its types first (Unify.atomically), so a unification that
   fails partway doesn't leave half its changes for the next constraint
   to trip over. *)

open Types
open Infer_msg
open Infer_env
open Infer_report

(* Which constraints the solver decides now. Other passes still run
   between them, so the solver is run in two parts: [Equalities], the uses
   of the group's functions joined and the values thrown away checked, and
   [Error_rows], what each error set holds. *)
type stage = Equalities | Error_rows

(* A constraint's rank: those of a lower one are decided first. A value
   thrown away is checked after the group's uses of each other are joined,
   since a call of another function of the group learns only then what it
   returns; and a set gets the tags written in it before what it includes
   from other sets, so a tag of two shapes is blamed on the inclusion. *)
let rank = function
  | Join _ -> 0
  | Drop _ -> 1
  | Value_tag _ -> 2
  | Include _ -> 3

let stage_of c = if rank c <= 1 then Equalities else Error_rows

(* ---- deciding one ---- *)

(* Unify [found] with [expected], as [Infer_report.unify_at] does, but
   changing nothing if that fails: the mismatch is reported as far as the
   copies got, which is what it would have said unifying the types
   themselves. *)
let equal env ?msg ?notes ?help loc ~found ~expected =
  let c = Unify.copier () in
  match
    Unify.atomically env.st c (fun st (c : Unify.copy) ->
        Unify.unify st (c.ty found) (c.ty expected))
  with
  | Ok () -> ()
  | Error failure ->
      let help = Option.map (fun h _ _ -> h) help in
      mismatch env
        (explain ?msg ?notes ?help ())
        loc ~found:(c.ty found) ~expected:(c.ty expected) failure

(* A use of another function of the group is the type that function's
   own body gave it (see [Infer_env.join]). *)
let join env ~is_value j =
  let msg = used_as j.jname in
  let expected = Hashtbl.find env.globals j.target in
  match (repr j.used, repr expected) with
  | TFun ([], used, _, _), TFun ([], made, _, _) when is_value j.target ->
      (* an associated value, a function of no parameters (ast.ml), is
         used as its result, which is what's shown *)
      equal env j.jloc ~found:used ~expected:made ~msg
        ~notes:[ group_type ~values:true ]
  | _ ->
      equal env j.jloc ~found:j.used ~expected ~msg
        ~notes:[ group_type ~values:false ]

(* A value thrown away is `Unit` (see [Infer_env.drop]). One whose type is
   still unknown, like the result of calling a parameter, becomes `Unit`,
   and is kept in [forced]. *)
let drop env d =
  (match repr d.dty with
  | TVar _ -> env.forced <- (d.dself, d.dloc) :: env.forced
  | _ -> ());
  (* an implementation, or a handler's description, which a handler's
     call makes: it's for installing *)
  let implementation =
    match repr d.dty with TCon (_, [ TUses _ ]) -> true | _ -> false
  in
  equal env d.dloc ~found:d.dty ~expected:unit
    ~msg:(thrown_away ~callee:d.callee ~implementation)
    ~help:(thrown_away_help ~implementation)

(* A tag written as a value, `Err(Right)`, goes in its set if the set is
   one of its own, not what an `attempt` kept or a parameter fails with:
   `if c then Err(Left(1)) else Err(Right)` holds both
   ([Infer_rows.err_row]). Whether it went in: if not, it's checked with
   the tags in patterns, once the kept sets are closed (infer_top.ml). *)
let value_tag env t =
  let kept tl = List.exists (fun (k, _) -> row_tail k = Some tl) env.kept in
  let labels, tail = row_parts t.tset in
  match tail with
  | Some tl
    when (not (kept tl))
         && (not (in_params t.tin tl))
         && not (List.exists (fun (l : label) -> l.name = t.ttag.name) labels)
    -> (
      let l = { name = t.ttag.name; payload = t.tpayload } in
      (* a named row can't learn a tag: it's checked with the patterns,
         and isn't one of the errors *)
      match
        Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
            Unify.unify_row st (c.row t.tset) (extend [ l ] (fresh_row st)))
      with
      | Ok () -> true
      | Error _ -> false)
  | _ -> false

(* Whether the inclusion [i] has anything to do: labels its source has
   that it hasn't added, or a source that stands for what a parameter
   fails with, which isn't linked yet. Rows only gain labels, so once it
   has, it has until it does it. *)
let awake i =
  let labels, src_tail = row_parts i.isrc in
  List.exists (fun (l : label) -> not (List.mem l.name i.ipassed)) labels
  ||
  match src_tail with
  | Some t -> (not i.ilinked) && in_params i.iparams t
  | None -> false

(* Add [r]'s labels to [i]'s destination, as [Infer_rows.add_errors]
   does, but changing nothing if that fails. *)
let add env i r =
  let errs = Infer_rows.without i.iwithout r in
  let c = Unify.copier () in
  (* the labels already there, as the message shows them *)
  let before = fst (row_parts (c.row i.idst)) in
  match
    Unify.atomically env.st c (fun st (c : Unify.copy) ->
        Unify.unify_row st
          (extend (fst (row_parts (c.row errs))) (fresh_row st))
          (c.row i.idst))
  with
  | Ok () -> ()
  | Error failure ->
      Infer_rows.add_failed env ~loc:i.iloc ~here:i.ihere
        ~sources:(i.isources ()) ~fix:i.ifix ~before (c.row errs) failure

(* Do what the inclusion [i] has to do (see [Infer_env.inclusion]): add
   the labels its source has learned since, and end a destination that
   includes a parameter's errors in the same tail as that parameter's.
   Whether it did anything, which may have woken others. *)
let include_ env i =
  (* a row's tail, the variable at its end *)
  let rec tail r =
    match repr_row r with RExtend (_, rest) -> tail rest | r -> r
  in
  let labels, src_tail = row_parts i.isrc in
  let added =
    match
      List.filter (fun (l : label) -> not (List.mem l.name i.ipassed)) labels
    with
    | [] -> false
    | fresh ->
        i.ipassed <- i.ipassed @ List.map (fun (l : label) -> l.name) fresh;
        add env i (extend fresh REmpty);
        true
  in
  match src_tail with
  | Some t when (not i.ilinked) && in_params i.iparams t ->
      (i.ilinked <- true;
       (* an open row takes on the parameter's tail, and stays what it is
         before it; a closed one, a lambda's whose type is written, says
         what the parameter can fail with *)
       let a, b =
         match row_tail i.idst with
         | Some _ -> (tail i.isrc, tail i.idst)
         | None -> (i.isrc, i.idst)
       in
       match
         Unify.atomically env.st (Unify.copier ()) (fun st (c : Unify.copy) ->
             Unify.unify_row st (c.row a) (c.row b))
       with
       | Ok () -> ()
       | Error _ -> report env (param_fails_here i.iloc));
      true
  | _ -> added

(* ---- the worklist ---- *)

(* Decide the inclusions [is], in the order they were met, until none is
   [awake]. Doing one can wake others, any whose source gained a label:
   one met after it is done later in the same round, and one met before
   it in the next, so each round goes through them in order. *)
let includes env is =
  (* arrays, whose cells can be changed in place: [queued.(k)] says
     whether the [k]th is waiting to be done *)
  let is = Array.of_list is in
  let queued = Array.make (Array.length is) true in
  (* [now]: what this round still has to do, sorted; [next]: what the
     next round does *)
  let rec round now next =
    match (now, next) with
    | [], [] -> ()
    | [], next -> round (List.sort compare next) []
    | k :: now, next ->
        queued.(k) <- false;
        (* if it did something, wake each that has something to do now *)
        let woken = ref [] in
        if include_ env is.(k) then
          Array.iteri
            (fun j i ->
              if (not queued.(j)) && awake i then woken := j :: !woken)
            is;
        List.iter (fun j -> queued.(j) <- true) !woken;
        let later, again = List.partition (fun j -> j > k) !woken in
        round (List.merge compare now (List.sort compare later)) (again @ next)
  in
  round (List.init (Array.length is) Fun.id) []

(* Decide every pending constraint of [stage], rank by rank. [is_value]
   says whether a function is an associated value, which a use joins by
   its result. *)
let solve env ~is_value stage =
  let mine, rest =
    List.partition (fun c -> stage_of c = stage) (List.rev env.pending)
  in
  env.pending <- List.rev rest;
  let of_rank r = List.filter (fun c -> rank c = r) mine in
  List.iter (function Join j -> join env ~is_value j | _ -> ()) (of_rank 0);
  List.iter (function Drop d -> drop env d | _ -> ()) (of_rank 1);
  (* the tags that went in are no longer checked with the patterns *)
  let added =
    List.filter_map
      (function Value_tag t when value_tag env t -> Some t | _ -> None)
      (of_rank 2)
  in
  if added <> [] then
    env.tag_patterns <-
      List.filter (fun t -> not (List.memq t added)) env.tag_patterns;
  includes env
    (List.filter_map (function Include i -> Some i | _ -> None) (of_rank 3))
