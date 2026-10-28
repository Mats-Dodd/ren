(* Reporting what inference finds wrong (see infer_expr.ml): names as a
   message writes them, and a mismatch between the type some code has and
   the type it needs, explained. The wording of every message is
   infer_msg.ml's. *)

open Ast
open Ast.Resolved
open Types
open Infer_msg
open Infer_env

let printer env = Types.printer ~names:env.names env.st
let type_name env p = env.names p

(* A name as it's written, for messages. *)
let name_of = function
  | Local b -> b.ident.name
  | Global p | Global_value p -> Path.local p
  | Intrinsic x -> Intrinsic.name x
  | Dep_op (p, op) -> p.name ^ "." ^ op
  | Next_op (_, op) -> "next." ^ op
  | Assoc_value (Named p, v) -> p.name ^ "." ^ v
  | Assoc_value (Param _, v) -> v

(* The same, without its type's name if it's a member: `push`. *)
let short_of = function
  | Local b -> b.ident.name
  | Global p | Global_value p -> Path.short p
  | Intrinsic x -> Intrinsic.member_name x
  | Dep_op (_, op) | Next_op (_, op) | Assoc_value (_, op) -> op

(* The name of the function [f] a call calls, for messages, if it's a
   function's name. *)
let callee_name (f : expr) =
  match f.kind with Var x -> Some (name_of x) | _ -> None

(* The callee [f]'s own name, without a type's in front: `push`. *)
let short_callee (f : expr) =
  match f.kind with Var x -> short_of x | Field (_, m) -> m.name | _ -> "this"

let report env d = Diag.report env.sink d

(* Report [d], about test code reaching for [p], one of its module's own
   items it can't see, an opaque type's representation or a private
   method, if nothing about [p] has been reported yet: at the first use
   only, as a private function is, since the fix is the same at every one
   (compiler.md, "Stage 9c"). *)
let report_test_once env (p : Path.t) d =
  if not (Hashtbl.mem env.test_reported p) then (
    Hashtbl.replace env.test_reported p ();
    report env d)

(* Report [d], about reaching [td]'s representation or fields: from test
   code, past its own module's opaque type, at the first use only;
   anything else, at each use. *)
let report_rep env (td : Iface.type_decl) d =
  if tested env td then report_test_once env td.path d else report env d

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_of (e : expr) =
  match e.kind with Block (_, last) -> result_of last | _ -> e

let result_loc (e : expr) = (result_of e).loc

(* The variables a pattern binds, each where it's bound. *)
let rec binders (p : pattern) =
  match p.pkind with
  | PVar b -> [ (b, p.ploc) ]
  | PCon (_, ps) | PFail (_, ps) | PTuple ps -> List.concat_map binders ps
  | POr ps -> List.concat_map binders ps
  | PWild | PInt _ | PBool _ | PFail_any -> []

(* How to explain a mismatch with an expected type, passed down along with
   it: [msg] words the error, [help] suggests a fix and [labels] point at
   other code, each given both types printed (the one found, then the one
   expected); [notes] say where the expectation comes from. [narrowed_help] is
   the help, if the caller knows a better one, where the two are an
   implementation of several dependencies and one of some of them, which
   it's narrowed to only where a written type asks for that: it's given
   that type, printed. [type_params] is whether a note says what a type
   parameter in either type is, unless the caller's notes say what they
   stand for. It's defined in infer_env.ml, since a constraint
   can carry one: [= Infer_env.why] says it's that type, not a new one with
   the same fields. *)
type why = Infer_env.why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  narrowed_help : (string -> string) option;
  labels : string -> string -> (Loc.t * string) list;
  type_params : bool;
}

let explain ?msg ?(notes = []) ?help ?narrowed_help ?(labels = fun _ _ -> [])
    ?(type_params = true) () =
  { msg; notes; help; narrowed_help; labels; type_params }

let plain = explain ()

(* ---- reporting ---- *)

(* Report that [found] (what the code has) didn't unify with [expected]
   (what it needs), which failed with [failure], explained with [why]. *)
let mismatch env why loc ?(behind = []) ~found ~expected failure =
  match failure with
  | Unify.Infinite ->
      let pr = printer env in
      report env
        (contains_itself loc ~found:(show pr found) ~expected:(show pr expected))
  | failure -> (
      let pr = printer env in
      let f = show pr found and x = show pr expected in
      (* two types that print the same differ in a row's tail, which is
         hidden, so show every tail *)
      let pr, f, x =
        if f <> x then (pr, f, x)
        else
          let pr =
            Types.printer ~show_tail:(fun _ -> true) ~names:env.names env.st
          in
          let f = show pr found in
          (pr, f, show pr expected)
      in
      let msg = Option.map (fun m -> m f x) why.msg in
      let help = Option.map (fun h -> h f x) why.help in
      (* two implementations of the same dependencies that need different
         things, themselves or inside the types they're part of,
         `Box<Rates>` *)
      let rec impls found expected =
        match (impl_parts found, impl_parts expected) with
        | Some (ds, _), Some (es, _) when ds = es -> Some (repr found)
        | _ -> (
            match (repr found, repr expected) with
            | TCon (p, fs), TCon (q, xs)
              when p = q && List.length fs = List.length xs ->
                List.find_map Fun.id (List.map2 impls fs xs)
            | _ -> None)
      in
      let needs_more =
        match impls found expected with
        | Some t
          when match (t, impls expected found) with
               | TImpl i, Some (TImpl j) -> i.over <> j.over
               | _ -> false ->
            (* what differs is whether it goes over another *)
            let i = Option.get (impl_of t) in
            [ Over_differs { deps = shown_deps env i.deps; over = i.over } ]
        | Some t ->
            (* it's what they fail to start with that differs, if that
               does, either way round: then the help writes the one that
               can fail, which both fit *)
            let more (i : impl) (j : impl) =
              List.exists
                (fun l -> not (List.mem l (row_names j.fails)))
                (row_names i.fails)
            in
            let fails, ty =
              match (t, impls expected found) with
              | TImpl i, Some (TImpl j) when more i j -> (true, f)
              | TImpl i, Some (TImpl j) when more j i -> (true, x)
              | _ -> (false, f)
            in
            [ Needs_more { ty; alone = t == repr found; fails } ]
        | None -> []
      in
      (* what's about errors: one tag with two shapes, or a function that
         fails where nothing can *)
      let errors =
        match (failure, errors_clash found expected) with
        | Unify.Two_shapes name, _ ->
            [
              Shapes
                ( name,
                  List.sort_uniq compare
                    (List.map (show_label pr)
                       (labels_named name found @ labels_named name expected))
                );
            ]
        | _, Some (extra, []) ->
            [ Fails_where_none (List.map (show_label pr) extra) ]
        | _, Some (extra, wanted) ->
            [
              Fails_beyond
                (List.map (show_label pr) extra, List.map (show_label pr) wanted);
            ]
        | _ -> (
            (* or a `Result` that holds what another can't *)
            match sets_clash found expected with
            | Some (extra, wanted) ->
                [
                  Holds_beyond
                    ( List.map (show_label pr) extra,
                      List.map (show_label pr) wanted );
                ]
            | None -> [])
      in
      (* another module's opaque type can't stand in for what it's
         represented as, or the other way round. [blame] looks for one
         where the two types differ: at the top, inside the same type
         (`Array<UserId>` and `Array<Int>`), or behind one of this module's
         own opaque types, which here is what it's represented as *)
      let foreign t =
        match t with
        | TCon (p, _) -> (
            match Hashtbl.find_opt env.types p with
            | Some { body = Opaque (Hidden _); _ } -> Some p
            | _ -> None)
        | _ -> None
      in
      let own t =
        match t with
        | TCon (p, _) when Hashtbl.mem env.st.reps p -> Some (reveal env.st t)
        | _ -> None
      in
      let rec blame f x =
        let f = repr f and x = repr x in
        let pairs a b =
          if List.length a = List.length b then
            List.find_map Fun.id (List.map2 blame a b)
          else None
        in
        match (f, x) with
        | TCon (p, a), TCon (q, b) when p = q -> pairs a b
        | _ -> (
            match (foreign f, foreign x, own f, own x) with
            | Some _, Some _, _, _ ->
                (* two of them: neither is what the other is represented
                   as *)
                None
            | Some p, _, _, _ | _, Some p, _, _ -> Some p
            | _, _, Some f, _ -> blame f x
            | _, _, _, Some x -> blame f x
            | None, None, None, None -> (
                match (f, x) with
                | TFun (ps, r, _, _), TFun (qs, s, _, _) ->
                    pairs
                      (r :: List.map (fun p -> p.ty) ps)
                      (s :: List.map (fun p -> p.ty) qs)
                | _ -> None))
      in
      let private_ =
        match blame found expected with
        | Some p -> [ Private (p, p.home = env.home) ]
        | None -> []
      in
      (* an implementation of several dependencies where one of others, or
         of some of them, is wanted, or the other way round, at the top or
         inside the types, `Option<Rates>`: its dependencies, the other's,
         and whether it's the one found *)
      let rec all_pair f x =
        (* whether what's wanted is a variable inference solved, to the
           type of another value that came first, not a written type; or
           the caller says where a type that narrows one of the two is
           written, as when two uses of a function of a group differ *)
        let solved =
          why.narrowed_help <> None
          || match x with TVar _ -> true | _ -> false
        in
        let f = repr f and x = repr x in
        let pairs a b =
          if List.length a = List.length b then
            List.find_map Fun.id (List.map2 all_pair a b)
          else None
        in
        match (f, x, impl_parts f, impl_parts x) with
        | TImpl { deps = ds; _ }, _, _, Some (es, _)
          when List.length ds > 1 && not (List.equal same_dep ds es) ->
            Some (ds, es, true, solved)
        | _, TImpl { deps = ds; _ }, Some (es, _), _
          when List.length ds > 1 && not (List.equal same_dep ds es) ->
            Some (ds, es, false, solved)
        | TCon (p, fs), TCon (q, xs), _, _ when p = q -> pairs fs xs
        | TFun (ps, r, _, _), TFun (qs, r', _, _), _, _ ->
            pairs
              (r :: List.map (fun p -> p.ty) ps)
              (r' :: List.map (fun p -> p.ty) qs)
        | _ -> None
      in
      let joined ds = shown_deps env ds in
      let within a b = List.for_all (fun d -> List.exists (same_dep d) b) a in
      let several =
        match all_pair found expected with
        | Some (ds, es, here, solved) when within es ds || within ds es ->
            (* the dependencies of what's found, and of what's wanted *)
            let have, want = if here then (ds, es) else (es, ds) in
            if within want have || solved then
              (* fewer than another value, met first, has: that one is
                 narrowed where a written type asks *)
              let all, part =
                if within want have then (have, want) else (want, have)
              in
              [
                Narrowed_only_written
                  {
                    all = joined all;
                    part = joined part;
                    fix =
                      Option.map (fun h -> h (joined part)) why.narrowed_help;
                  };
              ]
            else
              (* fewer than a written type wants, which no written type
                 can add to: "expected, found" says it *)
              []
        | Some (ds, es, here, _) ->
            [
              Other_handler
                {
                  all = joined ds;
                  deps = List.map (fun d -> shown_deps env [ d ]) ds;
                  dep = joined es;
                  here;
                };
            ]
        | None -> []
      in
      let d =
        mismatch loc ?msg ~notes:why.notes ?help ~labels:(why.labels f x)
          ~type_params:why.type_params ~found ~expected ~f ~x
          (behind @ needs_more @ errors @ private_ @ several)
      in
      (* test code using its module's own opaque type as what it's
         represented as: at the first use only, as [report_rep] *)
      match private_ with
      | [ Private (p, true) ] -> report_test_once env p d
      | _ -> report env d)

(* Unify [found] with [expected], and say whether that worked. *)
let unifies env why loc ~found ~expected =
  match Unify.unify env.st found expected with
  | () -> true
  | exception
      ((Unify.Mismatch | Unify.Two_shapes _ | Unify.Infinite) as failure) ->
      mismatch env why loc ~found ~expected failure;
      false

let unify_at env ?msg ?notes ?help ?labels loc ~found ~expected =
  let help = Option.map (fun h _ _ -> h) help in
  ignore
    (unifies env (explain ?msg ?notes ?help ?labels ()) loc ~found ~expected)
