(* What's done with a table (value.ml): a `Map`'s entries, or a `Set`'s
   members. Each key is found by its hash, and told apart from the others
   of that hash by `==`: both come from the `hash` dictionary of the
   keys' type (core.ml, [dict]), which agree, as they go through the
   type's `key` if it has one.

   A table keeps the order its keys were first set in, so a program's
   output never depends on how keys hash (operators.md, "`Map` and
   `Set`"): setting a key that's there keeps its place, and one removed
   then set again goes last. A key keeps the value it was first set
   with, too, as `uniq` keeps the first of equal ones: setting a key equal
   to it by its `key`, `Email.of("ANN@x")` after `Email.of("ann@x")`,
   changes only its value. The hash is mixed with a seed of the runtime's
   own (walk.ml, [seed]), and since nothing is in the order of the
   buckets, nothing a program sees depends on it. *)

open Value

let empty = { frozen = false; entries = Ints.empty; buckets = Hashes.empty; next = 0 }
let len t = Ints.cardinal t.entries

(* The entries, the first set first. *)
let to_list t = List.map snd (Ints.bindings t.entries)

(* The number of [k]'s entry, if it has one, by [d]'s hash and `==`. *)
let find (d : dict) t k =
  match d with
  | Hash { hash; equal } ->
      if t.frozen then
        Option.map fst (List.find_opt (fun (_, (key, _)) -> equal key k)
          (Ints.bindings t.entries))
      else
        let b = hash k in
        List.find_opt
          (fun n -> equal (fst (Ints.find n t.entries)) k)
          (Option.value (Hashes.find_opt b t.buckets) ~default:[])
  | Eq _ | Ord _ | Op _ | Const _ ->
      failwith "bug: a table given a dictionary that isn't a hash's"

let hash_of (d : dict) k =
  match d with
  | Hash { hash; _ } -> hash k
  | Eq _ | Ord _ | Op _ | Const _ ->
      failwith "bug: a table given a dictionary that isn't a hash's"

(* Frozen entries have no seed or dictionary. Looking one up uses the
   key's equality; the first mutation makes this process's ordinary index. *)
let frozen pairs =
  let entries = List.mapi (fun i pair -> (i,pair)) pairs |> Ints.of_list in
  { frozen = true; entries; buckets = Hashes.empty; next = List.length pairs }

let indexed d t =
  if not t.frozen then t
  else
    let buckets = Ints.fold (fun n (k,_) buckets ->
      let b = hash_of d k in
      let others = Option.value (Hashes.find_opt b buckets) ~default:[] in
      Hashes.add b (n :: others) buckets) t.entries Hashes.empty in
    {t with frozen = false; buckets}

(* [k]'s value, if it's there. *)
let get d t k = Option.map (fun n -> snd (Ints.find n t.entries)) (find d t k)

(* [t] with [k] set to [v]: in its place, if it's there, or else last. *)
let set d t k v =
  let t = indexed d t in
  match find d t k with
  | Some n ->
      let first, _ = Ints.find n t.entries in
      { t with entries = Ints.add n (first, v) t.entries }
  | None ->
      let b = hash_of d k in
      let others = Option.value (Hashes.find_opt b t.buckets) ~default:[] in
      {
        frozen = false;
        entries = Ints.add t.next (k, v) t.entries;
        buckets = Hashes.add b (t.next :: others) t.buckets;
        next = t.next + 1;
      }

(* [t] without [k], which may not be there. *)
let remove d t k =
  let t = indexed d t in
  match find d t k with
  | None -> t
  | Some n ->
      let b = hash_of d k in
      let others =
        List.filter (( <> ) n)
          (Option.value (Hashes.find_opt b t.buckets) ~default:[])
      in
      {
        t with
        entries = Ints.remove n t.entries;
        buckets =
          (if others = [] then Hashes.remove b t.buckets
           else Hashes.add b others t.buckets);
      }

(* The pairs, each set in turn: a key given twice has the last value, in
   the first one's place, and is the first one. *)
let of_list d pairs = List.fold_left (fun t (k, v) -> set d t k v) empty pairs
