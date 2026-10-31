(* Exhaustiveness: every `match` handles every case, and has no arm that
   can never match. It runs after type inference (infer.ml), because which
   type a pattern's constructor belongs to is found through the type of the
   value being matched, so it's only known once inference has found it.
   Inference records the constructor each pattern became, and this pass
   reads it (module-build.md, "In the compiler").

   Each problem is reported to the sink (diag.ml), and checking carries on
   with the next `match`. *)

open Ast
open Ast.Resolved

let sprintf = Printf.sprintf

type env = {
  types : (Path.t, Iface.type_decl) Hashtbl.t;
      (** every type the module can see, by path *)
  nodes : Infer.node Infer.Nodes.t;  (** what inference found in the function *)
  names : Path.t -> string;  (** how the module writes a type's name *)
  source : expr -> string option;  (** an expression as it's written *)
  sink : Diag.sink;
}

(* ---- exhaustiveness ----

   Maranget's algorithm ("Warnings for pattern matching", 2007), the one
   OCaml and Rust use. Patterns are simplified to two shapes: [Any] (a
   wildcard or variable), [Ctor] (a constructor with sub-patterns) and [Or]
   (an or-pattern's alternatives, which a row is one of each: Maranget's
   section on or-patterns).
   Literals are constructors too: `true`/`false` of a two-constructor type,
   and each Int a constructor of a type with infinitely many.

   The rows of the match form a matrix, one pattern list per row. The key
   question, [useful rows q], asks: is there a value that [q] matches but no
   row does? An arm that isn't useful against the arms above it can never
   match. A match is exhaustive when a wildcard row wouldn't be useful. *)

(* A constructor of a pattern: its name, and what it belongs to: a type,
   or an error set, whose tags are like a sum type's constructors
   (errors.md, "Keeping an error"). [No_list] for an Int, which isn't one
   of a list of constructors, and for a tag of a set that's still open.

   A `match` with `fail` arms matches an outcome, which is a value or an
   error: [Outcome] is its two constructors, [value] and [fail], each with
   one field, the value or the error (errors.md, "Handling: `match`"). A
   value pattern, `_` too, is [value] of it, so `_` never matches an
   error; `fail _` is [fail] of anything. A tuple of [n] parts is the one
   constructor of [Tuple n], with [n] fields, and a record the one
   constructor of [Record], with its declared fields, by name. A value of
   a variant type, `Order.Placed`, is always its constructor, the one of
   [Of_variant] (compiler.md, "Data stage", "Variant types"). *)
type head = { name : string; owner : owner }

and owner =
  | Of_type of Path.t
  | Of_set of (string * int) list
  | No_list
  | Outcome
  | Tuple of int
  | Record of Path.t * string list
  | Of_variant of Path.t * string
  | Lengths of { split : int; front : int; back : int }
      (** an array's lengths at a column whose patterns are sequences
          (compiler.md, "Patterns stage", "Coverage"): `[n]` for each [n]
          below [split], with [n] fields, and `[split..]`, with [front +
          back], its first [front] elements and its last [back] *)

(* [Seq] is an array's sequence pattern, its pieces in front, whether it
   has a rest, and its pieces at the back, which [lengths] makes
   constructors of [Lengths] at its column. [Str] is a string's pattern,
   a member of a family too big to list, as an Int is: a literal, [exact],
   is its [prefix] and its [suffix]; a sequence matches any string with
   both, at least as long as the two. *)
type space =
  | Any
  | Ctor of head * space list
  | Or of space list
  | Seq of space list * bool * space list
  | Str of str_pat

and str_pat = { prefix : string; suffix : string; exact : bool }

let bool_path = Path.prelude "Bool"
let result_path = Path.prelude "Result"
let value = { name = "value"; owner = Outcome }
let failed = { name = "fail"; owner = Outcome }

(* The tags of [t], an error set, each with its number of payload values:
   [None] if the set is still open. *)
let set_of (t : Ty.ty) =
  match t with
  | Errors { labels; tail = None } ->
      Some
        (List.map
           (fun (l : Ty.label) -> (l.name, List.length l.payload))
           labels)
  | _ -> None

(* The constructor [name] of the sum type [path], as it's declared. *)
let ctor_of env path name =
  match Hashtbl.find_opt env.types path with
  | Some { body = Sum cs; _ } ->
      List.find_opt (fun (k : Iface.ctor) -> k.cname = name) cs
  | _ -> None

(* [p] as a space. With [swap], an or-pattern whose node is listed has
   only the alternatives listed with it: how an alternative of an
   or-pattern is checked on its own (see [alternatives]). *)
let rec simplify ?(swap = []) env (p : pattern) =
  let simplify = simplify ~swap in
  match (List.assoc_opt p.pnode swap, p.pkind) with
  | Some [ q ], POr _ -> simplify env q
  | Some qs, POr _ -> Or (List.map (simplify env) qs)
  | _, POr ps -> Or (List.map (simplify env) ps)
  | _, PAs (q, _) -> simplify env q
  | _ ->
  match p.pkind with
  | PWild | PVar _ -> Any
  | PInt n -> Ctor ({ name = Int64.to_string n; owner = No_list }, [])
  | PStr s -> Str { prefix = s; suffix = s; exact = true }
  | PSeq q when q.bracketed ->
      Seq
        ( List.map (simplify env) q.front,
          q.middle <> None,
          List.map (simplify env) q.back )
  | PSeq q ->
      let text ps =
        String.concat ""
          (List.map
             (fun (p : pattern) -> match p.pkind with PStr s -> s | _ -> "")
             ps)
      in
      Str { prefix = text q.front; suffix = text q.back; exact = false }
  | PBool b -> Ctor ({ name = string_of_bool b; owner = Of_type bool_path }, [])
  | PCon (c, ps) ->
      let node = Infer.Nodes.find p.pnode env.nodes in
      let owner =
        match node.found with
        | Some Error_tag -> (
            (* a tag, of a set inference settled: every tag it can hold *)
            match set_of node.ty with
            | Some tags -> Of_set tags
            | None -> No_list)
        | Some (Ctor_of (path, _)) -> Of_type path
        | _ -> assert false (* inference found it, or reported an error *)
      in
      Ctor ({ name = c.name.name; owner }, List.map (simplify env) ps)
  | PCon_named (c, fs) -> (
      (* a by-name constructor is its positional one, every declared field
         in order, one the pattern leaves out an [Any] *)
      let node = Infer.Nodes.find p.pnode env.nodes in
      match node.found with
      | Some (Ctor_of (path, name)) -> (
          match ctor_of env path name with
          | Some k ->
              let field (d : Iface.field) =
                match
                  List.find_opt (fun ((f : ident), _) -> f.name = d.fname) fs.fpats
                with
                | Some (_, q) -> simplify env q
                | None -> Any
              in
              let owner =
                match node.ty with
                | Variant _ -> Of_variant (path, name)
                | _ -> Of_type path
              in
              Ctor ({ name = c.name.name; owner }, List.map field k.cfields)
          | None -> Any)
      | _ -> Any (* inference reported it *))
  | PTuple ps ->
      let n = List.length ps in
      Ctor ({ name = "(,)"; owner = Tuple n }, List.map (simplify env) ps)
  | PRecord (_, fs) -> (
      (* every declared field, in order, one the pattern leaves out an
         [Any] *)
      match (Infer.Nodes.find p.pnode env.nodes).ty with
      | Variant (path, name, _) -> (
          (* a variant type is a record of its constructor's fields, and
             always that constructor *)
          match ctor_of env path name with
          | Some k ->
              let field (d : Iface.field) =
                match
                  List.find_opt (fun ((f : ident), _) -> f.name = d.fname) fs.fpats
                with
                | Some (_, q) -> simplify env q
                | None -> Any
              in
              Ctor ({ name; owner = Of_variant (path, name) }, List.map field k.cfields)
          | None -> Any)
      | Con (path, _) -> (
          match Hashtbl.find env.types path with
          | { body = Record decl; _ } ->
              let names = List.map (fun (f : Iface.field) -> f.fname) decl in
              let field name =
                match
                  List.find_opt
                    (fun ((f : ident), _) -> f.name = name)
                    fs.fpats
                with
                | Some (_, q) -> simplify env q
                | None -> Any
              in
              Ctor
                ( { name = "{}"; owner = Record (path, names) },
                  List.map field names )
          | _ -> Any (* inference reported it *))
      | _ -> Any)
  | PFail _ | PFail_any | PFail_in _ | POr _ | PAs _ ->
      (* a whole arm's, which [outcomes] simplifies; the others are above *)
      invalid_arg "Exhaust.simplify: a `fail` pattern inside another"

(* Whether [p] is `fail` patterns, an arm's whole pattern. *)
let is_fails (p : pattern) =
  match p.pkind with
  | PFail _ | PFail_any | PFail_in _ -> true
  | POr (q :: _) -> (
      match q.pkind with PFail _ | PFail_any | PFail_in _ -> true | _ -> false)
  | _ -> false

(* The rows an arm's pattern adds to the matrix of a `match` with `fail`
   arms: one per alternative of an or-pattern of `fail` patterns. *)
let rec outcomes ?swap env (p : pattern) =
  let simplify = simplify ?swap in
  match p.pkind with
  | PFail (t, ps) ->
      let owner =
        match set_of (Infer.Nodes.find p.pnode env.nodes).ty with
        | Some tags -> Of_set tags
        | None -> No_list
      in
      [
        Ctor
          ( failed,
            [ Ctor ({ name = t.name; owner }, List.map (simplify env) ps) ] );
      ]
  | PFail_any | PFail_in _ -> [ Ctor (failed, [ Any ]) ]
  | POr ps when is_fails p -> List.concat_map (outcomes ?swap env) ps
  | _ -> [ Ctor (value, [ simplify env p ]) ]

(* A space as a pattern is written, as code that compiles where an arm's
   pattern goes. A record's, and a by-name constructor's, are written in
   braces, by name: the fields that matter, and `..` for the rest, `{
   paid: false, .. }`, `Rect { .. }`; a by-name constructor after its sum,
   `Shape.Rect { .. }`, where a bare one would be a record type in scope
   (Infer_msg.braced_ctor). *)
let rec show_space env = function
  | Any -> "_"
  | Or ss -> String.concat " | " (List.map (show_space env) ss)
  | Ctor ({ owner = Outcome; name = "value" }, [ v ]) -> show_space env v
  | Ctor ({ owner = Outcome; _ }, [ e ]) -> "fail " ^ show_space env e
  | Ctor ({ owner = Tuple _; _ }, args) ->
      "(" ^ String.concat ", " (List.map (show_space env) args) ^ ")"
  | Ctor ({ owner = Record (_, names); _ }, args) ->
      show_named env "{ " names args ~all:false
  | Ctor ({ owner = Lengths { split; front; back }; name }, args)
    when name = sprintf "[%d..]" split ->
      (* as many elements as the shortest it stands for, `[_, _, ..]` *)
      let shown = List.map (show_space env) args in
      let a = List.filteri (fun i _ -> i < front) shown in
      let z = List.filteri (fun i _ -> i >= front) shown in
      let more = List.init (split - front - back) (fun _ -> "_") in
      "[" ^ String.concat ", " (a @ more @ [ ".." ] @ z) ^ "]"
  | Ctor ({ owner = Lengths _; _ }, args) ->
      "[" ^ String.concat ", " (List.map (show_space env) args) ^ "]"
  | Seq (a, rest, z) ->
      let shown = List.map (show_space env) in
      "[" ^ String.concat ", " (shown a @ (if rest then [ ".." ] else []) @ shown z) ^ "]"
  | Str { prefix; exact = true; _ } -> Ast.show_str prefix
  | Str { prefix; suffix; _ } ->
      String.concat " "
        ((if prefix = "" then [] else [ Ast.show_str prefix ])
        @ [ ".." ]
        @ if suffix = "" then [] else [ Ast.show_str suffix ])
  | Ctor ({ name; owner = Of_type p | Of_variant (p, _) }, args)
    when match ctor_of env p name with Some k -> k.cnamed | None -> false ->
      let k = Option.get (ctor_of env p name) in
      let written = Infer_msg.braced_ctor ~types:env.types ~names:env.names p name in
      show_named env (written ^ " { ")
        (List.map (fun (f : Iface.field) -> f.fname) k.cfields)
        args ~all:true
  | Ctor (c, []) -> c.name
  | Ctor (c, args) ->
      c.name ^ "(" ^ String.concat ", " (List.map (show_space env) args) ^ ")"

(* The fields [names] after [start], each of [args] that matters, and
   `..` for the rest, if any are left out or, unless [all], always. *)
and show_named env start names args ~all =
  let named =
    List.filter_map
      (fun (f, a) ->
        match a with Any -> None | a -> Some (f ^ ": " ^ show_space env a))
      (List.combine names args)
  in
  let rest = (not all) || List.length named < List.length names in
  start ^ String.concat ", " (named @ if rest then [ ".." ] else []) ^ " }"

let wilds n = List.init n (fun _ -> Any)

(* Every constructor of the type [c] belongs to, with its number of fields.
   [None] for Int, which has too many values to list. *)
let siblings env c =
  match c.owner with
  | Of_type p when p = bool_path ->
      let b name = { name; owner = Of_type bool_path } in
      Some [ (b "true", 0); (b "false", 0) ]
  | Of_type p -> (
      match Hashtbl.find env.types p with
      | { body = Sum cs; _ } ->
          Some
            (List.map
               (fun (k : Iface.ctor) ->
                 ({ name = k.cname; owner = Of_type p }, List.length k.cfields))
               cs)
      | _ -> None)
  | Of_set tags ->
      Some (List.map (fun (t, n) -> ({ name = t; owner = c.owner }, n)) tags)
  | Outcome -> Some [ (value, 1); (failed, 1) ]
  | Tuple n -> Some [ (c, n) ]
  | Record (_, names) -> Some [ (c, List.length names) ]
  | Of_variant (p, name) ->
      Option.map
        (fun (k : Iface.ctor) -> [ (c, List.length k.cfields) ])
        (ctor_of env p name)
  | Lengths { split; front; back } ->
      Some
        (List.init split (fun n -> ({ name = sprintf "[%d]" n; owner = c.owner }, n))
        @ [ ({ name = sprintf "[%d..]" split; owner = c.owner }, front + back) ])
  | No_list -> None

(* The rows with an or-pattern first made a row for each alternative,
   which is what the row means: any of them. *)
let rec expand rows =
  List.concat_map
    (function
      | Or alts :: rest -> expand (List.map (fun a -> a :: rest) alts)
      | row -> [ row ])
    rows

(* Whether the string pattern [a] matches every string [b] does (rule
   5): a literal only itself; else [a]'s prefix is a prefix of [b]'s,
   its suffix a suffix of [b]'s, and its minimum length no longer. *)
let covers a b =
  let least p = if p.exact then String.length p.prefix else String.length p.prefix + String.length p.suffix in
  if a.exact then b.exact && a.prefix = b.prefix
  else
    String.starts_with ~prefix:a.prefix b.prefix
    && String.ends_with ~suffix:a.suffix b.suffix
    && least a <= least b

(* The first column of [rows] and of [q], an array's lengths made
   constructors where its patterns are sequences (rustc's slice
   patterns): [split] is the larger of the longest fixed length plus one
   and the most pieces any sequence with a rest has in front ([front])
   and at the back ([back]); a fixed length [n] is `[n]`, and one with a
   rest, [f] pieces in front and [b] at the back, each `[n]` from [f +
   b] up to [split] and `[split..]`, the pieces it doesn't have wild
   (compiler.md, "Patterns stage", "Coverage"). Done at each column, so
   the rest of the algorithm is unchanged. *)
let lengths rows q =
  let rec seqs = function
    | Seq (a, rest, z) -> [ (List.length a, rest, List.length z) ]
    | Or ss -> List.concat_map seqs ss
    | _ -> []
  in
  let firsts = List.filter_map (function s :: _ -> Some s | [] -> None) (q :: rows) in
  match List.concat_map seqs firsts with
  | [] -> (rows, q)
  | found ->
      let fixed = List.filter_map (fun (a, rest, _) -> if rest then None else Some a) found in
      let front = List.fold_left (fun m (a, rest, _) -> if rest then max m a else m) 0 found in
      let back = List.fold_left (fun m (_, rest, z) -> if rest then max m z else m) 0 found in
      let split = max (List.fold_left (fun m n -> max m (n + 1)) 0 fixed) (front + back) in
      let owner = Lengths { split; front; back } in
      let ctor n args = Ctor ({ name = sprintf "[%d]" n; owner }, args) in
      let rec conv = function
        | Seq (a, false, z) -> ctor (List.length a + List.length z) (a @ z)
        | Seq (a, true, z) ->
            let f = List.length a and b = List.length z in
            let exact =
              List.init (max 0 (split - f - b)) (fun k ->
                  let n = f + b + k in
                  ctor n (a @ wilds (n - f - b) @ z))
            in
            Or
              (exact
              @ [
                  Ctor
                    ( { name = sprintf "[%d..]" split; owner },
                      a @ wilds (front - f) @ wilds (back - b) @ z );
                ])
        | Or ss -> Or (List.map conv ss)
        | s -> s
      in
      let row = function s :: rest -> conv s :: rest | [] -> [] in
      (List.map row rows, row q)

(* The rows that still apply once we know the first value is matched by
   the string pattern [p]: those whose first pattern covers it, and the
   wild ones. *)
let specialize_str p rows =
  List.filter_map
    (function
      | Str p' :: rest -> if covers p' p then Some rest else None
      | Any :: rest -> Some rest
      | _ -> None)
    (expand rows)

(* The rows that still apply once we know the first value was built with
   constructor [c]: their first pattern is replaced by its [arity]
   sub-patterns, and rows starting with a different constructor drop out. *)
let specialize c arity rows =
  List.filter_map
    (function
      | Ctor (c', args) :: rest -> if c' = c then Some (args @ rest) else None
      | Any :: rest -> Some (wilds arity @ rest)
      | (Or _ | Str _ | Seq _) :: _ | [] -> None)
    (expand rows)

(* The rows that apply when the first value is a constructor no row names. *)
let default rows =
  List.filter_map (function Any :: rest -> Some rest | _ -> None) (expand rows)

let head_ctors rows =
  List.sort_uniq compare
    (List.filter_map
       (function Ctor (c, _) :: _ -> Some c | _ -> None)
       (expand rows))

(* The whole constructor list, if the first column names every constructor
   of its type. *)
let complete env heads =
  match heads with
  | [] -> None
  | c :: _ -> (
      match siblings env c with
      | Some all when List.for_all (fun (k, _) -> List.mem k heads) all ->
          Some all
      | _ -> None)

let rec useful env rows q =
  let rows, q = lengths rows q in
  match q with
  | [] -> rows = []
  | Or alts :: rest -> List.exists (fun a -> useful env rows (a :: rest)) alts
  | Str p :: rest -> useful env (specialize_str p rows) rest
  | Seq _ :: _ -> assert false (* [lengths] made it constructors *)
  | Ctor (c, args) :: rest ->
      useful env (specialize c (List.length args) rows) (args @ rest)
  | Any :: rest -> (
      match complete env (head_ctors rows) with
      | Some all ->
          List.exists
            (fun (c, a) -> useful env (specialize c a rows) (wilds a @ rest))
            all
      | None -> useful env (default rows) rest)

(* Like [useful env rows (wilds n)], but returns the unmatched values found:
   [n] patterns that no row matches, or [None] if the rows cover everything. *)
let rec missing env rows n =
  if n = 0 then if rows = [] then Some [] else None
  else
    let rows, _ = lengths rows [] in
    let heads = head_ctors rows in
    match complete env heads with
    | Some all ->
        List.find_map
          (fun (c, a) ->
            Option.map
              (fun w ->
                let args = List.filteri (fun i _ -> i < a) w in
                let rest = List.filteri (fun i _ -> i >= a) w in
                Ctor (c, args) :: rest)
              (missing env (specialize c a rows) (a + n - 1)))
          all
    | None ->
        Option.map
          (fun w ->
            (* name a constructor nobody handled, if there is a list of them *)
            let first =
              match Option.bind (List.nth_opt heads 0) (siblings env) with
              | Some all ->
                  let k, a =
                    List.find (fun (k, _) -> not (List.mem k heads)) all
                  in
                  Ctor (k, wilds a)
              | None -> Any
            in
            first :: w)
          (missing env (default rows) (n - 1))

(* The or-patterns in [p], at any depth, each one's node, its
   alternatives, and the or-patterns it's inside, the outermost first,
   each with the alternative it's in: an or-pattern of `fail` patterns,
   an arm's whole, isn't one of them (see [alternatives]). *)
let rec ors ?(around = []) (p : pattern) =
  let inner = ors ~around in
  match p.pkind with
  | POr ps when is_fails p -> List.concat_map inner ps
  | POr ps ->
      (p.pnode, ps, around)
      :: List.concat
           (List.mapi
              (fun k q -> ors ~around:(around @ [ (p.pnode, ps, k) ]) q)
              ps)
  | PAs (q, _) -> inner q
  | PCon (_, ps) | PFail (_, ps) | PTuple ps -> List.concat_map inner ps
  | PRecord (_, fs) | PCon_named (_, fs) ->
      List.concat_map (fun (_, q) -> inner q) fs.fpats
  | PSeq q -> List.concat_map inner (Ast.seq_pieces q)
  | PWild | PVar _ | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> []

(* Each alternative of each or-pattern in an arm's pattern [p], which
   matches something new, is checked to: against [rows], the arms above,
   and the alternatives before it. An alternative is checked as [p] with
   its or-pattern swapped for it, and the ones before it as [p] with the
   or-pattern swapped for theirs, so the rest of [p] is what it is. One
   inside another or-pattern is checked in the alternative it's in, so
   the alternatives before it are also each one before that, and none
   after it is (an alternative after it matches only what it doesn't).
   Alternatives of `fail` patterns are each a row of their own. *)
and alternatives env ~handles rows (p : pattern) =
  let never (q : pattern) =
    Diag.report env.sink
      (Diag.make q.ploc
         ~help:
           "the alternatives before it, or the arms above, already match all \
            of it"
         "this alternative never matches")
  in
  let rows_of ?swap (p : pattern) =
    if handles then List.map (fun s -> [ s ]) (outcomes ?swap env p)
    else [ [ simplify ?swap env p ] ]
  in
  let each rows (whole : pattern) =
    List.iter
      (fun (n, (alts : pattern list), around) ->
        (* each or-pattern it's inside at the alternative it's in *)
        let inside = List.map (fun (m, ms, k) -> (m, [ List.nth ms k ])) around in
        (* each one it's inside at the alternatives before that one, the
           ones outside it at theirs *)
        let outer_before =
          List.concat
            (List.mapi
               (fun d (m, ms, k) ->
                 let before = List.filteri (fun j _ -> j < k) ms in
                 if before = [] then []
                 else
                   rows_of
                     ~swap:((m, before) :: List.filteri (fun j _ -> j < d) inside)
                     whole)
               around)
        in
        List.iteri
          (fun i (q : pattern) ->
            let before = List.filteri (fun j _ -> j < i) alts in
            let earlier =
              if before = [] then []
              else rows_of ~swap:((n, before) :: inside) whole
            in
            let these = rows_of ~swap:((n, [ q ]) :: inside) whole in
            if not (List.exists (useful env (rows @ outer_before @ earlier)) these)
            then never q)
          alts)
      (ors whole)
  in
  match p.pkind with
  | POr qs when is_fails p ->
      (* `fail A | fail B`: a row each *)
      ignore
        (List.fold_left
           (fun rows (q : pattern) ->
             let these = rows_of q in
             if not (List.exists (useful env rows) these) then never q
             else each rows q;
             rows @ these)
           rows qs)
  | _ -> each rows p

(* Check one `match`. [passes_on] says it's a `try match`, which passes on
   the errors its arms don't handle, so only its values have to be
   covered. *)
let check_match env ?(passes_on = false) (e : expr) (subject : expr) arms =
  (* the type of the value being matched, for the message *)
  let column =
    match (Infer.Nodes.find subject.node env.nodes).ty with
    | Con (p, _) as t when Ty.is_tuple p ->
        Some
          (Ty.show
             (Ty.printer ~names:env.names
                { ty = t; names = []; reqs = []; row_reqs = []; modes = []; defaults = [] })
             t)
    | Con (p, _) -> Some (env.names p)
    | Variant (p, c, _) -> Some (env.names p ^ "." ^ c)
    | Var _ | Fun _ | Errors _ | Impl _ | Error -> None
  in
  (* With `fail` arms, each row is an outcome (see [owner]), and the error
     set they match is in each `fail` pattern's type *)
  let found id = (Infer.Nodes.find id env.nodes).found in
  let handles = found e.node = Some Infer.Handles in
  let errors =
    match
      List.find_opt (fun a -> found a.arm_pat.pnode = Some Infer.Fail_arm) arms
    with
    | Some a -> Some (Infer.Nodes.find a.arm_pat.pnode env.nodes).ty
    | None -> None
  in
  let rows_of (p : pattern) =
    if handles then List.map (fun s -> [ s ]) (outcomes env p)
    else [ [ simplify env p ] ]
  in
  (* Arms with a guard might not match even when their pattern does, so they
     never count toward covering a case. An or-pattern is a row for each
     alternative, and can match if one of them can. *)
  let rows =
    List.fold_left
      (fun rows a ->
        let alts = rows_of a.arm_pat in
        if not (List.exists (useful env rows) alts) then
          Diag.error a.arm_pat.ploc
            ~help:"the arms above already match everything this one does"
            "this arm can never match"
        else alternatives env ~handles rows a.arm_pat;
        (* `fail on` matches only the tags it's given, which aren't known
           here, so it counts as a guard does *)
        let rec tags_in (p : pattern) =
          match p.pkind with
          | PFail_in _ -> true
          | POr ps -> List.exists tags_in ps
          | _ -> false
        in
        if a.arm_guard = None && not (tags_in a.arm_pat) then rows @ alts
        else rows)
      [] arms
  in
  (* a `try match` passes on any error its arms don't match *)
  let rows =
    if passes_on && handles then rows @ [ [ Ctor (failed, [ Any ]) ] ] else rows
  in
  (* Collect up to three missing cases, adding each one as a row so the next
     search finds a different one. *)
  let rec collect rows k =
    if k = 0 then []
    else
      match missing env rows 1 with
      | Some [ w ] -> w :: collect (rows @ [ [ w ] ]) (k - 1)
      | _ -> []
  in
  (* a missing `Err(_)` of a [Result] whose set is settled is each of its
     tags, which can be named, and so is a missing `fail _` of a set that's
     settled *)
  let result_tags =
    match (Infer.Nodes.find subject.node env.nodes).ty with
    | Con (p, [ _; t ]) when p = result_path -> set_of t
    | _ -> None
  in
  let fail_tags = Option.bind errors set_of in
  let each tags wrap =
    List.map
      (fun (name, n) -> wrap (Ctor ({ name; owner = Of_set tags }, wilds n)))
      tags
  in
  let expand = function
    | Ctor (({ name = "Err"; owner = Of_type p } as err), [ Any ])
      when p = result_path && result_tags <> None && result_tags <> Some [] ->
        each (Option.get result_tags) (fun t -> Ctor (err, [ t ]))
    | Ctor ({ owner = Outcome; name = "fail" }, [ Any ])
      when fail_tags <> None && fail_tags <> Some [] ->
        each (Option.get fail_tags) (fun t -> Ctor (failed, [ t ]))
    | w -> [ w ]
  in
  (* a fourth, if there is one, says more may be missing than are shown *)
  let found = List.concat_map expand (collect rows 4) in
  let is_error = function
    | Ctor ({ owner = Outcome; name = "fail" }, _) -> true
    | _ -> false
  in
  match List.filteri (fun i _ -> i < 3) found with
  | [] -> ()
  | first :: _ as ws ->
      let errors_missing = List.exists is_error ws in
      let values_missing = not (List.for_all is_error ws) in
      let what =
        match (column, errors_missing, values_missing) with
        | _, true, true -> "every value and error"
        | _, true, false -> "every error it can fail with"
        | Some t, _, _ -> sprintf "every `%s`" t
        | None, _, _ -> "every possible value"
      in
      let notes =
        ("missing: " ^ String.concat ", " (List.map (show_space env) ws))
        ::
        (if List.exists (fun a -> a.arm_guard <> None) arms then
           [
             "arms with an `if` guard don't count, since the guard may be false";
           ]
         else [])
        @
        if errors_missing && fail_tags = None then
          [
            "it can fail with whatever a function it was passed fails with, so \
             only `fail _` matches all of it";
          ]
        else []
      in
      let start = e.loc.start in
      let keyword = { e.loc with stop = { start with col = start.col + 5 } } in
      let help =
        match first with
        | Any | Ctor ({ owner = Outcome; name = "value" }, [ Any ]) ->
            "add a `_ =>` arm to cover the remaining values:"
        | Ctor ({ owner = Outcome; name = "fail" }, [ Any ]) ->
            "add a `fail _ =>` arm, or pass the errors on with `try match`:"
        | w when is_error w ->
            "add the missing arms, or a `fail _ =>` arm for the rest, or pass \
             them on with `try match`:"
        | _ -> "add the missing arms, or a `_ =>` arm for the rest:"
      in
      (* The arms to paste after the others, each `PATTERN => todo`: the
         missing ones shown, then, if more may be missing, an arm for the
         rest of the values, or of the errors, that aren't. *)
      let shown = rows @ List.map (fun w -> [ w ]) ws in
      let rest =
        if List.length found <= 3 then []
        else if not handles then [ "_" ]
        else
          (if missing env (shown @ [ [ Ctor (failed, [ Any ]) ] ]) 1 <> None
           then [ "_" ]
           else [])
          @
          if missing env (shown @ [ [ Ctor (value, [ Any ]) ] ]) 1 <> None
          then [ "fail _" ]
          else []
      in
      let code =
        List.map (fun p -> p ^ " => todo") (List.map (show_space env) ws @ rest)
      in
      (* at the column of the arms, to paste under them *)
      let code_at =
        match arms with
        | a :: _ -> a.arm_pat.ploc.start.col
        | [] -> start.col + 2
      in
      Diag.error keyword ~notes ~help ~code ~code_at
        (sprintf "this `match` doesn't handle %s" what)

(* A variable bound to an error, `Err(e)`, would make the error a value of
   its own (errors.md, "Keeping an error"), so it's matched by its tags. *)
let rec no_bound_errors env (p : pattern) =
  match p.pkind with
  | PVar b -> (
      match (Infer.Nodes.find p.pnode env.nodes).ty with
      | Errors _ ->
          Diag.report env.sink (Infer_msg.bound_error p.ploc b.ident.name)
      | _ -> ())
  | PAs (q, b) -> (
      no_bound_errors env q;
      match (Infer.Nodes.find p.pnode env.nodes).ty with
      | Errors _ ->
          Diag.report env.sink (Infer_msg.bound_error b.ident.loc b.ident.name)
      | _ -> ())
  | PCon (_, ps) | PFail (_, ps) | POr ps | PTuple ps ->
      List.iter (no_bound_errors env) ps
  | PRecord (_, fs) | PCon_named (_, fs) ->
      List.iter (fun (_, q) -> no_bound_errors env q) fs.fpats
  | PSeq q -> List.iter (no_bound_errors env) (Ast.seq_pieces q)
  | PWild | PInt _ | PBool _ | PStr _ | PFail_any | PFail_in _ -> ()

(* ---- walking the program ---- *)

(* Run a check; if it finds a problem, report it and carry on. *)
let guard env f = Diag.recover env.sink ~default:() f

let rec check_expr env (e : expr) =
  match e.kind with
  | Int _ | Float _ | Bool _ | Str _ | Unit | Var _ | Break | Todo | Tag_set _
  | Piped ->
      ()
  | Interp ps -> List.iter (check_expr env) (Ast.holes ps)
  | Named (_, a) -> check_expr env a
  | Pipe _ -> List.iter (check_expr env) (children e)
  | Try ({ kind = Match (subject, arms); _ } as m) ->
      check_match_expr env ~passes_on:true m subject arms
  | Unop (_, a, _) | Field (a, _) | Ref a | Try a | Attempt a | Release a
  | Assert a | Yield a | Yield_from a ->
      check_expr env a
  | Return value -> Option.iter (check_expr env) value
  | Fail (_, args) -> List.iter (fun (_, a) -> check_expr env a) args
  | Binop (_, a, b, _) | Index (a, b) ->
      check_expr env a;
      check_expr env b
  | Slice (a, lo, hi) -> List.iter (check_expr env) [ a; lo; hi ]
  | If (c, t, f) -> List.iter (check_expr env) (c :: t :: Option.to_list f)
  | Array xs | Tuple xs -> List.iter (check_expr env) xs
  | Assign { target; value; _ } -> List.iter (check_expr env) [ target; value ]
  | For { pat; _ } ->
      guard env (fun () -> takes_apart env "a `for`" pat);
      List.iter (check_expr env) (children e)
  | While _ -> List.iter (check_expr env) (children e)
  | Call (f, args) -> List.iter (check_expr env) (f :: args)
  | Lambda (_, body) -> check_expr env body
  | Inline_handler l -> check_expr env l
  | Block (stmts, _) ->
      check_stmts env stmts;
      List.iter (check_expr env) (children e)
  | Con (_, args) -> List.iter (fun (_, a) -> check_expr env a) args
  | Record (_, fields) | Con_named (_, fields) ->
      List.iter (fun (_, v) -> check_expr env v) fields
  | Update _ -> List.iter (check_expr env) (children e)
  | Match (subject, arms) -> check_match_expr env e subject arms
  | With { items; body } ->
      List.iter (check_expr env) (with_links items @ [ body ])
  | Handler { state; _ } ->
      check_stmts env state;
      List.iter (check_expr env) (children e)

and check_match_expr env ?passes_on e subject arms =
  check_expr env subject;
  List.iter (fun (a : arm) -> no_bound_errors env a.arm_pat) arms;
  guard env (fun () -> check_match env ?passes_on e subject arms);
  List.iter
    (fun (a : arm) ->
      Option.iter (check_expr env) a.arm_guard;
      check_expr env a.arm_body)
    arms

(* The `let`s among [stmts] that take apart: each pattern always matches,
   unless it has an `else`, and then it might not (compiler.md, "Data
   stage", "Patterns that always match"). A block's parameter taken apart
   is a `let` of it at the start of the body, of a name no program
   writes (parser.ml, [lambda_pattern]). *)
and check_stmts env stmts =
  List.iter
    (function
      | Let_pattern { pat; value; else_ } ->
          guard env (fun () ->
              let shown = pattern_source ~type_name:env.names pat in
              match (else_, value.kind) with
              | None, Var (Local b) when b.ident.name.[0] = '$' ->
                  takes_apart env "a block's parameter" pat
              | None, _ when not (always env pat) ->
                  let v = Option.value (env.source value) ~default:"..." in
                  Diag.error pat.ploc
                    ~help:
                      (sprintf
                         "add one that leaves, `let %s = %s else fail ...`, or \
                          use a `match`"
                         shown v)
                    (sprintf "`%s` might not match, so this `let` needs an `else`"
                       shown)
              | Some _, _ when always env pat ->
                  Diag.error pat.ploc ~help:"remove the `else`"
                    "this pattern always matches, so the `else` never runs"
              | _ -> ())
      | Let _ | Expr _ | Finally _ -> ())
    stmts

(* Whether [p] matches every value of its type. *)
and always env (p : pattern) = missing env [ [ simplify env p ] ] 1 = None

(* [p], the pattern of [what], "a `for`", which only takes apart, so it
   has to always match. *)
and takes_apart env what (p : pattern) =
  if not (always env p) then
    Diag.error p.ploc
      ~help:
        "take it apart with a `match`, which says what happens when it doesn't \
         match"
      (sprintf "%s takes apart only what always matches, but `%s` might not"
         what (pattern_source ~type_name:env.names p))

(* [inferred] is what inference found in the module, and [reachable] the
   interfaces of every module reachable through its imports. *)
let program sink ~reachable (r : Resolve.t) (inferred : Infer.t) =
  let types = Hashtbl.create 16 in
  List.iter
    (fun (td : Iface.type_decl) -> Hashtbl.replace types td.path td)
    (List.concat_map (fun (iface : Iface.t) -> iface.types) reachable @ r.types);
  List.iter
    (fun (f : fn_def) ->
      let nodes = Path.Map.find (Ast.fn_path r.home f) inferred.nodes in
      let names = Resolve.type_name r in
      let source =
        Ast.source ~type_name:names ~value_name:(Resolve.value_name r)
      in
      check_expr { types; nodes; names; source; sink } f.body)
    (Ast.functions r.prog)
