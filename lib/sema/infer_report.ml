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

(* The same, without its type's name if it's a member: `push`. *)
let short_of = function
  | Local b -> b.ident.name
  | Global p | Global_value p -> Path.short p
  | Intrinsic x -> Intrinsic.member_name x
  | Dep_op (_, op) -> op

(* The name of the function [f] a call calls, for messages, if it's a
   function's name. *)
let callee_name (f : expr) =
  match f.kind with Var x -> Some (name_of x) | _ -> None

(* The callee [f]'s own name, without a type's in front: `push`. *)
let short_callee (f : expr) =
  match f.kind with Var x -> short_of x | Field (_, m) -> m.name | _ -> "this"

let report env d = Diag.report env.sink d

(* The value an expression produces is its last line, which is where to
   point when that value has the wrong type. *)
let rec result_of (e : expr) =
  match e.kind with Block (_, last) -> result_of last | _ -> e

let result_loc (e : expr) = (result_of e).loc

(* The variables a pattern binds, each where it's bound. *)
let rec binders (p : pattern) =
  match p.pkind with
  | PVar b -> [ (b, p.ploc) ]
  | PCon (_, ps) | PFail (_, ps) -> List.concat_map binders ps
  | POr ps -> List.concat_map binders ps
  | PWild | PInt _ | PBool _ | PFail_any -> []

(* How to explain a mismatch with an expected type, passed down along with
   it: [msg] words the error, [help] suggests a fix and [labels] point at
   other code, each given both types printed (the one found, then the one
   expected); [notes] say where the expectation comes from. A help that
   the printed types don't tell, [help_of], is given the type found, and
   the printer the message prints it with. *)
type why = {
  msg : (string -> string -> string) option;
  notes : string list;
  help : (string -> string -> string) option;
  help_of : (Types.printer -> Types.ty -> string) option;
  labels : string -> string -> (Loc.t * string) list;
}

let explain ?msg ?(notes = []) ?help ?help_of ?(labels = fun _ _ -> []) () =
  { msg; notes; help; help_of; labels }

let plain = explain ()

(* Unify [found] (what the code has) with [expected] (what it needs), and
   say whether that worked. *)
let unifies env why loc ~found ~expected =
  match Unify.unify env.st found expected with
  | () -> true
  | exception ((Unify.Mismatch | Unify.Two_shapes _) as failure) ->
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
      let help =
        match why.help_of with
        | Some h -> Some (h pr found)
        | None -> Option.map (fun h -> h f x) why.help
      in
      (* two implementations of one dependency that need different things,
         themselves or inside the types they're part of, `Box<Rates>` *)
      let rec impls found expected =
        match (repr found, repr expected) with
        | (TCon (p, [ TUses _ ]) as t), TCon (q, [ TUses _ ]) when p = q ->
            Some t
        | TCon (p, fs), TCon (q, xs)
          when p = q && List.length fs = List.length xs ->
            List.find_map Fun.id (List.map2 impls fs xs)
        | _ -> None
      in
      let needs_more =
        match impls found expected with
        | Some t -> [ Needs_more { ty = f; alone = t == repr found } ]
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
        | _ -> []
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
            | Some { body = Opaque None; _ } -> Some p
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
        match blame found expected with Some p -> [ Private p ] | None -> []
      in
      (* a handler of several dependencies where an implementation is
         wanted, at the top or inside the types (`Option<Rates>`): one of
         its own somewhere it wasn't known as it was made (see [as_one]),
         or another one *)
      let rec handler_pair f x =
        match (repr f, repr x) with
        | TCon (h, _), TCon (d, [ TUses _ ]) when h <> d -> (
            match Hashtbl.find_opt env.types h with
            | Some { body = Handler deps; _ } -> Some (h, deps, d)
            | _ -> None)
        | TCon (p, fs), TCon (q, xs)
          when p = q && List.length fs = List.length xs ->
            List.find_map Fun.id (List.map2 handler_pair fs xs)
        | TFun (ps, r, _, _), TFun (qs, r', _, _)
          when List.length ps = List.length qs ->
            List.find_map Fun.id
              (handler_pair r r'
              :: List.map2 (fun p q -> handler_pair p.ty q.ty) ps qs)
        | _ -> None
      in
      let handler =
        match handler_pair found expected with
        | Some (h, deps, d) ->
            let handler = type_name env h
            and deps' = List.map (type_name env) deps
            and dep = type_name env d in
            if List.mem d deps then
              [ Taken_as_one { handler; deps = deps'; dep } ]
            else [ Other_handler { handler; deps = deps'; dep } ]
        | None -> []
      in
      report env
        (mismatch loc ?msg ~notes:why.notes ?help ~labels:(why.labels f x)
           ~found ~expected ~f ~x
           (needs_more @ errors @ private_ @ handler));
      false
  | exception Unify.Infinite ->
      let pr = printer env in
      report env
        (contains_itself loc ~found:(show pr found) ~expected:(show pr expected));
      false

let unify_at env ?msg ?notes ?help ?labels loc ~found ~expected =
  let help = Option.map (fun h _ _ -> h) help in
  ignore
    (unifies env (explain ?msg ?notes ?help ?labels ()) loc ~found ~expected)
