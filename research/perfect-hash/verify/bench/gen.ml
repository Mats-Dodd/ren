(* gen.ml: the build-time half of a string `match` compiled to a perfect
   hash, as the Ren compiler would run it on the literal arms of one
   `match`. After Lemire's ConstexprCore/perfect_hash (gperf_generator.h),
   cut down to what a compiler needs.

   The hash is gperf's:

     h = (len + A_0[s[p_0]] + A_1[s[p_1]] + ...) & (M - 1)

   M a power of two, each A_i a 256-entry byte table, p_i a byte position
   or "the last byte". A position past a key's end adds 0.

   Steps:
   1. Positions: none if the lengths alone separate the keys; else the
      single position with most distinct (len mod M, byte) pairs; else
      {0, last}; else a bounded search over pairs and triples of the best
      candidates; else add candidates greedily, up to [max_positions].
   2. Values: gperf's partition method. Take (position, byte) symbols most
      frequent first; give each the smallest value that keeps every
      group of keys that agree on all symbols still unset apart mod M.
      A value is never changed once set.
   3. Table size: next_pow2(n), then doubled, up to 8n (at most 512).
   4. Fallback: no hash within that budget, emit a length switch.

   Usage: gen <name> <keys-file> <out-dir>
   Writes <name>.h (C lookups), <name>.gperf, <name>.rs (the Rust twin)
   and <name>.q (the queries, 90% hits, 10% near misses). *)

let max_positions = 4
let last = -1 (* the position "last byte" *)

let char_at k p =
  let n = String.length k in
  if p = last then (if n = 0 then 256 else Char.code k.[n - 1])
  else if p < n then Char.code k.[p]
  else 256

(* Do positions [ps] tell apart every pair of keys whose lengths are
   equal mod m? *)
let undistinguished keys ps m =
  let n = Array.length keys in
  let c = ref 0 in
  for i = 0 to n - 1 do
    for j = i + 1 to n - 1 do
      if String.length keys.(i) mod m = String.length keys.(j) mod m
         && List.for_all (fun p -> char_at keys.(i) p = char_at keys.(j) p) ps
      then incr c
    done
  done;
  !c

let power keys p m =
  let t = Hashtbl.create 64 in
  Array.iter (fun k -> Hashtbl.replace t (String.length k mod m, char_at k p) ()) keys;
  Hashtbl.length t

let select_positions keys m =
  if undistinguished keys [] m = 0 then Some []
  else begin
    let maxlen = Array.fold_left (fun a k -> max a (String.length k)) 0 keys in
    let cands = List.init maxlen Fun.id @ [ last ] in
    let ranked =
      List.map (fun p -> (power keys p m, p)) cands
      |> List.stable_sort (fun (a, _) (b, _) -> compare b a)
      |> List.map snd
    in
    let ok ps = undistinguished keys ps m = 0 in
    let top = List.filteri (fun i _ -> i < 12) ranked in
    let pairs =
      List.concat_map (fun a -> List.filter_map (fun b -> if a < b then Some [ a; b ] else None) top) top
    in
    let triples =
      List.concat_map
        (fun a ->
          List.concat_map
            (fun b ->
              List.filter_map (fun c -> if a < b && b < c then Some [ a; b; c ] else None) top)
            top)
        top
    in
    let tries = [ [ List.hd ranked ]; [ 0; last ] ] @ pairs @ triples in
    match List.find_opt ok tries with
    | Some ps -> Some ps
    | None ->
        (* greedy *)
        let rec go ps = function
          | [] -> None
          | _ when List.length ps >= max_positions -> None
          | p :: rest ->
              let ps = ps @ [ p ] in
              if ok ps then Some ps else go ps rest
        in
        go [] ranked
  end

(* Step 2. Returns the tables, one per position, and each key's slot. *)
let assign keys ps m =
  let n = Array.length keys in
  let np = List.length ps in
  let ps = Array.of_list ps in
  let kch = Array.map (fun k -> Array.map (char_at k) ps) keys in
  let a = Array.make_matrix (max np 1) 257 0 in
  let ph = Array.map String.length keys in
  (* symbols, most frequent first *)
  let freq = Hashtbl.create 64 in
  Array.iter
    (fun row ->
      Array.iteri
        (fun p c -> if c < 256 then Hashtbl.replace freq (p, c) (1 + Option.value ~default:0 (Hashtbl.find_opt freq (p, c))))
        row)
    kch;
  let syms =
    Hashtbl.fold (fun s f acc -> (f, s) :: acc) freq []
    |> List.sort (fun (f1, s1) (f2, s2) -> if f1 <> f2 then compare f2 f1 else compare s1 s2)
    |> List.map snd
  in
  let set = Hashtbl.create 64 in
  (* the symbols of key k still unset, as a sorted list: its group *)
  let group k =
    List.filter (fun (p, c) -> c < 256 && not (Hashtbl.mem set (p, c)))
      (List.init np (fun p -> (p, kch.(k).(p))))
  in
  let limit = max 32 m in
  let ok = ref true in
  List.iter
    (fun (sp, sc) ->
      if !ok then begin
        Hashtbl.replace set (sp, sc) ();
        let groups = Hashtbl.create 16 in
        for k = 0 to n - 1 do
          let g = group k in
          Hashtbl.replace groups g (k :: Option.value ~default:[] (Hashtbl.find_opt groups g))
        done;
        let fits v =
          Hashtbl.fold
            (fun _ ks good ->
              good
              && (List.length ks < 2
                 ||
                 let seen = Hashtbl.create 8 in
                 List.for_all
                   (fun k ->
                     let h = (ph.(k) + if kch.(k).(sp) = sc then v else 0) land (m - 1) in
                     if Hashtbl.mem seen h then false else (Hashtbl.replace seen h (); true))
                   ks))
            groups true
        in
        let rec find v = if v >= limit then None else if fits v then Some v else find (v + 1) in
        match find 0 with
        | None -> ok := false
        | Some v ->
            a.(sp).(sc) <- v;
            Array.iteri (fun k row -> if row.(sp) = sc then ph.(k) <- ph.(k) + v) kch
      end)
    syms;
  if not !ok then None
  else begin
    let slots = Array.map (fun h -> h land (m - 1)) ph in
    let distinct = Hashtbl.create 16 in
    Array.iter (fun s -> Hashtbl.replace distinct s ()) slots;
    if Hashtbl.length distinct = n && Array.for_all (fun row -> Array.for_all (fun v -> v < 256) row) a then
      Some (a, slots)
    else None
  end

let next_pow2 n =
  let rec go p = if p >= n then p else go (2 * p) in
  go 1

type plan = Hash of { m : int; ps : int list; a : int array array; slots : int array } | Switch

let plan keys =
  let n = Array.length keys in
  let rec try_m m =
    if m > 512 || m > 8 * next_pow2 n then Switch
    else
      match select_positions keys m with
      | None -> try_m (2 * m)
      | Some ps -> (
          match assign keys ps m with
          | Some (a, slots) -> Hash { m; ps; a; slots }
          | None -> try_m (2 * m))
  in
  try_m (max 2 (next_pow2 n))

(* ---- emitting C ---- *)

let c_str s =
  let b = Buffer.create 16 in
  Buffer.add_char b '"';
  String.iter (fun c -> if c = '"' || c = '\\' then Printf.bprintf b "\\%c" c else Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let emit_c oc name keys plan =
  let pr fmt = Printf.fprintf oc fmt in
  let n = Array.length keys in
  let lens = Array.map String.length keys in
  let minl = Array.fold_left min max_int lens and maxl = Array.fold_left max 0 lens in
  pr "/* generated by gen.ml for %s: %d keys, lengths %d..%d */\n" name n minl maxl;
  pr "#define %s_N %d\n" name n;
  pr "static const char *const %s_keys[%d] = {" name n;
  Array.iter (fun k -> pr "%s," (c_str k)) keys;
  pr "};\n\n";
  (* Ren today: a chain of `==`, each len then bytes (ren_str_eq). *)
  pr "static inline int %s_chain(const char *s, size_t n) {\n" name;
  Array.iteri (fun i k -> pr "  if (n == %d && memcmp(s, %s, %d) == 0) return %d;\n" (String.length k) (c_str k) (String.length k) i) keys;
  pr "  return -1;\n}\n\n";
  (* rustc's shape: switch on length, then compare within it *)
  pr "static inline int %s_lenswitch(const char *s, size_t n) {\n  switch (n) {\n" name;
  let bylen = Hashtbl.create 8 in
  Array.iteri (fun i k -> Hashtbl.replace bylen (String.length k) ((i, k) :: Option.value ~default:[] (Hashtbl.find_opt bylen (String.length k)))) keys;
  List.iter
    (fun l ->
      pr "  case %d:\n" l;
      List.iter (fun (i, k) -> pr "    if (memcmp(s, %s, %d) == 0) return %d;\n" (c_str k) l i) (List.rev (Hashtbl.find bylen l));
      pr "    return -1;\n")
    (List.sort compare (Hashtbl.fold (fun l _ acc -> l :: acc) bylen []));
  pr "  default: return -1;\n  }\n}\n\n";
  match plan with
  | Switch ->
      pr "#define %s_PHASH 0\n" name;
      List.iter (fun v -> pr "#define %s_%s %s_lenswitch\n" name v name) [ "ph_memcmp"; "ph_neon"; "ph_pad"; "ph_word" ]
  | Hash { m; ps; a; slots } ->
      pr "#define %s_PHASH 1\n" name;
      let w = (maxl + 15) / 16 * 16 in
      let slotkey = Array.make m (-1) in
      Array.iteri (fun k s -> slotkey.(s) <- k) slots;
      pr "/* M = %d, positions = [%s] */\n" m (String.concat "; " (List.map (fun p -> if p = last then "last" else string_of_int p) ps));
      List.iteri
        (fun i _ ->
          pr "static const uint8_t %s_A%d[256] = {" name i;
          for c = 0 to 255 do pr "%d," a.(i).(c) done;
          pr "};\n")
        ps;
      pr "static const uint8_t %s_len[%d] = {" name m;
      Array.iter (fun k -> pr "%d," (if k < 0 then 255 else lens.(k))) slotkey;
      pr "};\nstatic const int8_t %s_val[%d] = {" name m;
      Array.iter (fun k -> pr "%d," k) slotkey;
      pr "};\nstatic const uint8_t %s_key[%d][%d] __attribute__((aligned(16))) = {" name m w;
      Array.iter (fun k -> if k < 0 then pr "{0}," else pr "{%s}," (String.concat "," (List.init (String.length keys.(k)) (fun j -> string_of_int (Char.code keys.(k).[j]))))) slotkey;
      pr "};\n";
      let hash () =
        pr "  if (n - %d > %d) return -1;\n" minl (maxl - minl);
        pr "  uint32_t h = (uint32_t)n";
        List.iteri
          (fun i p ->
            if p = last then pr " + %s_A%d[(uint8_t)s[n - 1]]" name i
            else if p < minl then pr " + %s_A%d[(uint8_t)s[%d]]" name i p
            else pr " + (n > %d ? %s_A%d[(uint8_t)s[%d]] : 0)" p name i p)
          ps;
        pr ";\n  h &= %d;\n  if (%s_len[h] != n) return -1;\n" (m - 1) name
      in
      pr "static inline int %s_ph_memcmp(const char *s, size_t n) {\n" name;
      hash ();
      pr "  return memcmp(s, %s_key[h], n) == 0 ? %s_val[h] : -1;\n}\n" name name;
      let neon fn load =
        pr "static inline int %s_%s(const char *s, size_t n) {\n" name fn;
        hash ();
        if maxl > 16 then pr "  if (n > 16) return memcmp(s, %s_key[h], n) == 0 ? %s_val[h] : -1;\n" name name;
        pr "  return ph_eq16(%s(s, n), n, %s_key[h]) ? %s_val[h] : -1;\n}\n" load name name
      in
      neon "ph_neon" "ph_load_paged";
      neon "ph_pad" "ph_load_padded";
      (* the same without intrinsics: two 8-byte words, masked, which any
         C compiler and any 64-bit target take; needs the padding *)
      let word k i =
        if k < 0 then 0L
        else begin
          let w = ref 0L in
          String.iteri (fun j c -> if j >= 8 * i && j < 8 * i + 8 then w := Int64.logor !w (Int64.shift_left (Int64.of_int (Char.code c)) (8 * (j - 8 * i)))) keys.(k);
          !w
        end
      in
      List.iter
        (fun i ->
          pr "static const uint64_t %s_w%d[%d] = {" name i m;
          Array.iter (fun k -> pr "0x%LxULL," (word k i)) slotkey;
          pr "};\n")
        [ 0; 1 ];
      pr "static inline int %s_ph_word(const char *s, size_t n) {\n" name;
      hash ();
      if maxl > 16 then pr "  if (n > 16) return memcmp(s, %s_key[h], n) == 0 ? %s_val[h] : -1;\n" name name;
      pr "  uint64_t a, b; memcpy(&a, s, 8); memcpy(&b, s + 8, 8);\n";
      pr "  return ((a & ph_lo[n]) == %s_w0[h]) & ((b & ph_hi[n]) == %s_w1[h]) ? %s_val[h] : -1;\n}\n" name name name

(* ---- the Rust twin: a plain `match` ---- *)
let emit_rs oc name keys =
  Printf.fprintf oc "#[inline]\npub fn %s(s: &str) -> i64 {\n    match s {\n" name;
  Array.iteri (fun i k -> Printf.fprintf oc "        %S => %d,\n" k i) keys;
  Printf.fprintf oc "        _ => -1,\n    }\n}\n"

(* ---- gperf input ---- *)
let emit_gperf oc name keys =
  Printf.fprintf oc "%%{\n#include <string.h>\n%%}\n%%struct-type\n%%define hash-function-name %s_ghash\n%%define lookup-function-name %s_gperf_find\n%%compare-strncmp\nstruct %s_g { const char *name; int idx; };\n%%%%\n" name name name;
  Array.iteri (fun i k -> Printf.fprintf oc "%s, %d\n" k i) keys;
  Printf.fprintf oc "%%%%\n"

(* ---- queries: 90% hits, 10% near misses ---- *)
let emit_queries oc keys =
  let st = Random.State.make [| 42 |] in
  let alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_" in
  let set = Hashtbl.create 64 in
  Array.iter (fun k -> Hashtbl.replace set k ()) keys;
  let rec miss () =
    let k = keys.(Random.State.int st (Array.length keys)) in
    let b = Bytes.of_string k in
    (match Random.State.int st 3 with
    | 0 -> Bytes.set b (Random.State.int st (Bytes.length b)) alpha.[Random.State.int st (String.length alpha)]
    | 1 -> Bytes.set b (Bytes.length b - 1) alpha.[Random.State.int st (String.length alpha)]
    | _ -> ());
    let s = Bytes.to_string b in
    let s = if Random.State.int st 3 = 2 then s ^ String.make 1 alpha.[Random.State.int st 26] else s in
    if Hashtbl.mem set s || String.contains s '\n' then miss () else s
  in
  for _ = 1 to 65536 do
    let q = if Random.State.int st 10 = 0 then miss () else keys.(Random.State.int st (Array.length keys)) in
    output_string oc q;
    output_char oc '\n'
  done

let () =
  let name = Sys.argv.(1) and file = Sys.argv.(2) and dir = Sys.argv.(3) in
  let ic = open_in file in
  let rec read acc = match input_line ic with l when l = "" -> read acc | l -> read (l :: acc) | exception End_of_file -> List.rev acc in
  let keys = Array.of_list (read []) in
  close_in ic;
  let p = plan keys in
  let with_out f g = let oc = open_out (Filename.concat dir f) in g oc; close_out oc in
  with_out (name ^ ".h") (fun oc -> emit_c oc name keys p);
  with_out (name ^ ".rs") (fun oc -> emit_rs oc name keys);
  with_out (name ^ ".gperf") (fun oc -> emit_gperf oc name keys);
  with_out (name ^ ".q") (fun oc -> emit_queries oc keys);
  match p with
  | Switch -> Printf.printf "%s: %d keys, no hash found: length switch\n" name (Array.length keys)
  | Hash { m; ps; a; _ } ->
      let used = Array.fold_left (fun acc row -> Array.fold_left (fun acc v -> if v > 0 then acc + 1 else acc) acc row) 0 a in
      Printf.printf "%s: %d keys, M=%d, positions=[%s], nonzero assoc values=%d\n" name (Array.length keys) m
        (String.concat ";" (List.map (fun p -> if p = last then "last" else string_of_int p) ps))
        used
