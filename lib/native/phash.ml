(* The perfect hash a string `match` is looked up through (compiler.md,
   "Patterns stage", "The generator"): research/perfect-hash's
   generator (verify/fuzz/gen_fixed.ml), after Lemire's port of gperf,
   with the six fixes its fuzz found, and two fallbacks.

   The hash is gperf's:

     h = (len + A_0[s[p_0]] + A_1[s[p_1]] + ...) & (M - 1)

   M a power of two, each A_i a table of 256 bytes, p_i a byte position
   or the last byte; a position past a key's end adds 0. A key's slot
   holds its length, its number and its bytes, which the lookup compares
   with what it's given (ren_rt.h, "string patterns").

   1. Positions: none if the lengths alone tell the keys apart; else the
      single position with the most distinct (length, byte) pairs; else
      the first and the last byte; else pairs and triples of the 12 best;
      else the best added one at a time, up to [max_positions].
   2. Values: gperf's partition method. Each (position, byte), the most
      frequent first, gets the least value that keeps apart, mod M, the
      keys that agree on every one still unset. A value is never changed.
   3. M: next_pow2(n), doubled up to 8 next_pow2(n), at most 512.
   4. With no hash within that, the 64-bit mix of the first and last 8
      bytes and the length, by each of [mix_constants], into a table of
      next_pow2(n) doubled up to 8 next_pow2(n); then a switch on the
      length, comparing each key of that length in turn.

   It reads only the keys, in order: no hash table's order reaches what
   it gives, and nothing reads the time, so the same keys always give the
   same tables. *)

let max_positions = 4
let last = -1 (* the position "the last byte" *)

let next_pow2 n =
  let rec go p = if p >= n then p else go (2 * p) in
  go 1

(* The byte of [k] at [p], or 256 if it has none there. *)
let byte_at k p =
  let n = String.length k in
  if p = last then if n = 0 then 256 else Char.code k.[n - 1]
  else if p < n then Char.code k.[p]
  else 256

(* How many pairs of [keys] of the same length mod [m] positions [ps]
   don't tell apart. *)
let undistinguished keys ps m =
  let n = Array.length keys in
  let c = ref 0 in
  for i = 0 to n - 1 do
    for j = i + 1 to n - 1 do
      if
        String.length keys.(i) mod m = String.length keys.(j) mod m
        && List.for_all (fun p -> byte_at keys.(i) p = byte_at keys.(j) p) ps
      then incr c
    done
  done;
  !c

(* How many distinct (length mod [m], byte) pairs position [p] gives. *)
let power keys p m =
  List.length
    (List.sort_uniq compare
       (Array.to_list
          (Array.map (fun k -> (String.length k mod m, byte_at k p)) keys)))

let positions keys m =
  if undistinguished keys [] m = 0 then Some []
  else
    let longest = Array.fold_left (fun a k -> max a (String.length k)) 0 keys in
    let ranked =
      List.init longest Fun.id @ [ last ]
      |> List.map (fun p -> (power keys p m, p))
      |> List.stable_sort (fun (a, _) (b, _) -> compare b a)
      |> List.map snd
    in
    let ok ps = undistinguished keys ps m = 0 in
    let top = List.filteri (fun i _ -> i < 12) ranked in
    let pairs =
      List.concat_map
        (fun a -> List.filter_map (fun b -> if a < b then Some [ a; b ] else None) top)
        top
    in
    let triples =
      List.concat_map
        (fun a ->
          List.concat_map
            (fun b ->
              List.filter_map
                (fun c -> if a < b && b < c then Some [ a; b; c ] else None)
                top)
            top)
        top
    in
    match List.find_opt ok ([ [ List.hd ranked ]; [ 0; last ] ] @ pairs @ triples) with
    | Some ps -> Some ps
    | None ->
        let rec greedy ps = function
          | [] -> None
          | _ when List.length ps >= max_positions -> None
          | p :: rest ->
              let ps = ps @ [ p ] in
              if ok ps then Some ps else greedy ps rest
        in
        greedy [] ranked

(* The tables for positions [ps], one per position, and each key's slot:
   step 2. *)
let assign keys ps m =
  let n = Array.length keys in
  let np = List.length ps in
  let ps = Array.of_list ps in
  let bytes = Array.map (fun k -> Array.map (byte_at k) ps) keys in
  let a = Array.make_matrix (max np 1) 257 0 in
  let hash = Array.map String.length keys in
  (* each (position, byte), the most frequent first, ties by position,
     then byte *)
  let count = Hashtbl.create 64 in
  Array.iter
    (fun row ->
      Array.iteri
        (fun p c ->
          if c < 256 then
            Hashtbl.replace count (p, c)
              (1 + Option.value ~default:0 (Hashtbl.find_opt count (p, c))))
        row)
    bytes;
  let symbols =
    Hashtbl.fold (fun s f acc -> (f, s) :: acc) count []
    |> List.sort (fun (f1, s1) (f2, s2) ->
           if f1 <> f2 then compare f2 f1 else compare s1 s2)
    |> List.map snd
  in
  let set = Hashtbl.create 64 in
  (* the symbols of key [k] still unset: the keys that share them are a
     group, which the next value must keep apart *)
  let group k =
    List.filter
      (fun (p, c) -> c < 256 && not (Hashtbl.mem set (p, c)))
      (List.init np (fun p -> (p, bytes.(k).(p))))
  in
  let limit = max 32 m in
  let ok = ref true in
  List.iter
    (fun (sp, sc) ->
      if !ok then (
        Hashtbl.replace set (sp, sc) ();
        let groups = Hashtbl.create 16 in
        for k = 0 to n - 1 do
          let g = group k in
          Hashtbl.replace groups g
            (k :: Option.value ~default:[] (Hashtbl.find_opt groups g))
        done;
        (* whether [v] keeps every group apart: the order the groups are
           looked at doesn't change the answer *)
        let fits v =
          Hashtbl.fold
            (fun _ ks good ->
              good
              && (List.length ks < 2
                 ||
                 let seen = Hashtbl.create 8 in
                 List.for_all
                   (fun k ->
                     let h =
                       (hash.(k) + if bytes.(k).(sp) = sc then v else 0)
                       land (m - 1)
                     in
                     if Hashtbl.mem seen h then false
                     else (
                       Hashtbl.replace seen h ();
                       true))
                   ks))
            groups true
        in
        let rec find v = if v >= limit then None else if fits v then Some v else find (v + 1) in
        match find 0 with
        | None -> ok := false
        | Some v ->
            a.(sp).(sc) <- v;
            Array.iteri
              (fun k row -> if row.(sp) = sc then hash.(k) <- hash.(k) + v)
              bytes))
    symbols;
  if not !ok then None
  else
    let slots = Array.map (fun h -> h land (m - 1)) hash in
    if
      List.length (List.sort_uniq compare (Array.to_list slots)) = n
      && Array.for_all (Array.for_all (fun v -> v < 256)) a
    then Some (a, slots)
    else None

(* ---- the 64-bit mix ---- *)

(* Odd constants, each tried in turn: the first is 2^64 / the golden
   ratio, the rest splitmix64's and murmur3's finalizers', and odd
   numbers made of their halves. *)
let mix_constants =
  [
    0x9E3779B97F4A7C15L; 0xBF58476D1CE4E5B9L; 0x94D049BB133111EBL;
    0xFF51AFD7ED558CCDL; 0xC4CEB9FE1A85EC53L; 0x2545F4914F6CDD1DL;
    0x9FB21C651E98DF25L; 0xD6E8FEB86659FD93L; 0xA0761D6478BD642FL;
    0xE7037ED1A0B428DBL; 0x8EBC6AF09C88C6E3L; 0x589965CC75374CC3L;
    0x1D8E4E27C47D124FL; 0xC2B2AE3D27D4EB4FL; 0x165667B19E3779F9L;
    0x27D4EB2F165667C5L;
  ]

(* Up to 8 bytes of [k] from [i], the first the lowest. *)
let word k i len =
  let w = ref 0L in
  for j = 0 to len - 1 do
    w := Int64.logor !w (Int64.shift_left (Int64.of_int (Char.code k.[i + j])) (8 * j))
  done;
  !w

(* The mix of [k] by [c], its top [bits] bits: the first 8 bytes, the
   last 8 times 2^64 / the golden ratio, and the length, xored. *)
let mix c bits k =
  let n = String.length k in
  let m = min n 8 in
  let a = word k 0 m and b = word k (n - m) m in
  let x =
    Int64.logxor (Int64.logxor a (Int64.mul b 0x9E3779B97F4A7C15L)) (Int64.of_int n)
  in
  Int64.to_int (Int64.shift_right_logical (Int64.mul x c) (64 - bits))

let log2 m =
  let rec go k = if 1 lsl k >= m then k else go (k + 1) in
  go 0

let mixed keys =
  let n = Array.length keys in
  let rec try_m m =
    if m > 8 * next_pow2 n || m > 4096 then None
    else
      let bits = max 1 (log2 m) in
      let fits c =
        let slots = Array.map (mix c bits) keys in
        if List.length (List.sort_uniq compare (Array.to_list slots)) = n then
          Some slots
        else None
      in
      match List.find_map (fun c -> Option.map (fun s -> (c, s)) (fits c)) mix_constants with
      | Some (c, slots) -> Some (1 lsl bits, c, slots)
      | None -> try_m (2 * m)
  in
  try_m (max 2 (next_pow2 n))

(* ---- the plan ---- *)

type plan =
  | Hash of { m : int; ps : int list; a : int array array; slots : int array }
  | Mix of { m : int; c : int64; slots : int array }
  | Lengths

let plan keys =
  let n = Array.length keys in
  let rec try_m m =
    if m > 512 || m > 8 * next_pow2 n then None
    else
      match positions keys m with
      | None -> try_m (2 * m)
      | Some ps -> (
          match assign keys ps m with
          | Some (a, slots) -> Some (Hash { m; ps; a; slots })
          | None -> try_m (2 * m))
  in
  match try_m (max 2 (next_pow2 n)) with
  | Some p -> p
  | None -> (
      match mixed keys with
      | Some (m, c, slots) -> Mix { m; c; slots }
      | None -> Lengths)

(* The number of the key whose slot [h] is, or -1: what the lookup's
   tables say, which the fuzz checks against the keys. *)
let slot_keys m slots =
  let t = Array.make m (-1) in
  Array.iteri (fun k s -> t.(s) <- k) slots;
  t

(* What the hash of [plan] gives [s]: a slot, or [None] where the lookup
   answers -1 before it compares anything. For the fuzz. *)
let slot_of keys plan s =
  let lens = Array.map String.length keys in
  let lo = Array.fold_left min max_int lens and hi = Array.fold_left max 0 lens in
  let n = String.length s in
  if n < lo || n > hi then None
  else
    match plan with
    | Hash { m; ps; a; _ } ->
        let h =
          List.fold_left
            (fun h (i, p) ->
              let c = byte_at s p in
              h + if c < 256 then a.(i).(c) else 0)
            n
            (List.mapi (fun i p -> (i, p)) ps)
        in
        Some (h land (m - 1))
    | Mix { m; c; _ } -> Some (mix c (max 1 (log2 m)) s)
    | Lengths -> None

(* What looking [s] up in [keys] gives, as the C does: the number of the
   key it is, or -1. *)
let lookup keys plan s =
  match plan with
  | Lengths -> (
      match List.find_opt (fun i -> keys.(i) = s) (List.init (Array.length keys) Fun.id) with
      | Some i -> i
      | None -> -1)
  | Hash { m; slots; _ } | Mix { m; slots; _ } -> (
      match slot_of keys plan s with
      | None -> -1
      | Some h ->
          let k = (slot_keys m slots).(h) in
          if k >= 0 && keys.(k) = s then k else -1)

(* ---- the C ---- *)

let sprintf = Printf.sprintf

(* [s] as a C string literal, as emit_c.ml writes one ([Emit_c.c_string],
   which this module comes before). *)
let c_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '?' -> Buffer.add_string b "\\?"
      | ' ' .. '~' -> Buffer.add_char b c
      | c -> Buffer.add_string b (sprintf "\\%03o" (Char.code c)))
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let c_bytes k =
  "{" ^ String.concat "," (List.init (String.length k) (fun j -> string_of_int (Char.code k.[j]))) ^ "}"

(* The C type of a table of values up to [hi] and down to [lo]. *)
let int_type ~lo hi =
  if lo >= 0 then
    if hi <= 0xFF then "uint8_t" else if hi <= 0xFFFF then "uint16_t" else "uint32_t"
  else if hi <= 0x7F then "int8_t"
  else if hi <= 0x7FFF then "int16_t"
  else "int32_t"

let table ty name n values =
  sprintf "static const %s %s[%d] = {%s};\n" ty name n
    (String.concat "," (List.map string_of_int values))

(* The C of the lookup [name] of [keys] by [plan]: its tables, static
   const data, and `static int64_t name(const char *s, uint64_t n)`,
   which gives the number of the key the [n] bytes at [s] are, or -1: a
   string's bytes and length, however the string is kept. *)
let c ~name keys plan =
  let b = Buffer.create 4096 in
  let add = Buffer.add_string b in
  let n = Array.length keys in
  let lens = Array.map String.length keys in
  let lo = Array.fold_left min max_int lens and hi = Array.fold_left max 0 lens in
  let head () =
    (* the number of each key, which the `switch` on what this gives has a
       `case` for: `--emit-c` shows which literal each is *)
    add
      (sprintf "/* %s */\n"
         (String.concat ", "
            (Array.to_list
               (Array.mapi
                  (fun i k ->
                    let k = if String.length k > 24 then String.sub k 0 21 ^ "..." else k in
                    (* no `*/` ends the comment early *)
                    let shown = c_string k in
                    let b = Buffer.create (String.length shown) in
                    String.iteri
                      (fun j ch ->
                        Buffer.add_char b ch;
                        if ch = '*' && j + 1 < String.length shown && shown.[j + 1] = '/' then
                          Buffer.add_char b ' ')
                      shown;
                    sprintf "%d %s" i (Buffer.contents b))
                  keys))));
    add (sprintf "static int64_t %s(const char *s, uint64_t n) {\n" name);
    add (sprintf "  if (n - %d > %d) return -1;\n" lo (hi - lo))
  in
  (* the slot [h]'s compare, once its length is [n]'s: [""]'s answers on
     the length alone, a key over 16 bytes compares with `memcmp`, the
     rest 16 bytes at once (ren_rt.h, [ren_ph_eq16]) *)
  let compare_slot () =
    if lo = 0 then add (sprintf "  if (n == 0) return %s_val[h];\n" name);
    if hi > 16 then
      add
        (sprintf "  if (n > 16) return memcmp(s, %s_key[h], n) == 0 ? %s_val[h] : -1;\n"
           name name);
    add
      (sprintf "  return ren_ph_eq16(s, n, %s_key[h], %s_w[h]) ? %s_val[h] : -1;\n}\n"
         name name name)
  in
  let slot_tables m slots =
    let at = slot_keys m slots in
    let none = hi + 1 in
    add
      (table (int_type ~lo:0 none) (name ^ "_len") m
         (Array.to_list (Array.map (fun k -> if k < 0 then none else lens.(k)) at)));
    add (table (int_type ~lo:(-1) (n - 1)) (name ^ "_val") m (Array.to_list at));
    let width = max 16 ((hi + 15) / 16 * 16) in
    add
      (sprintf "static const uint8_t %s_key[%d][%d] REN_PH_ALIGNED = {%s};\n" name m width
         (String.concat ","
            (Array.to_list (Array.map (fun k -> if k < 0 then "{0}" else c_bytes keys.(k)) at))));
    (* the first 16 bytes as two words, the first byte the lowest, for
       the compare of a build without NEON *)
    let w k i =
      if k < 0 then 0L else word keys.(k) (8 * i) (max 0 (min 8 (lens.(k) - (8 * i))))
    in
    add
      (sprintf "static const uint64_t %s_w[%d][2] = {%s};\n" name m
         (String.concat ","
            (Array.to_list
               (Array.map (fun k -> sprintf "{0x%LxULL,0x%LxULL}" (w k 0) (w k 1)) at))))
  in
  (match plan with
  | Hash { m; ps; a; slots } ->
      add
        (sprintf "/* %d keys, %d to %d bytes: positions [%s], %d slots (phash.ml) */\n" n lo hi
           (String.concat "; " (List.map (fun p -> if p = last then "last" else string_of_int p) ps))
           m);
      List.iteri
        (fun i _ ->
          add (table "uint8_t" (sprintf "%s_a%d" name i) 256 (Array.to_list (Array.sub a.(i) 0 256))))
        ps;
      slot_tables m slots;
      head ();
      add "  uint32_t h = (uint32_t)n";
      List.iteri
        (fun i p ->
          let t = sprintf "%s_a%d" name i in
          if p = last then
            if lo = 0 then add (sprintf " + (n > 0 ? %s[(uint8_t)s[n - 1]] : 0)" t)
            else add (sprintf " + %s[(uint8_t)s[n - 1]]" t)
          else if p < lo then add (sprintf " + %s[(uint8_t)s[%d]]" t p)
          else add (sprintf " + (n > %d ? %s[(uint8_t)s[%d]] : 0)" p t p))
        ps;
      add (sprintf ";\n  h &= %d;\n" (m - 1));
      add (sprintf "  if (%s_len[h] != n) return -1;\n" name);
      compare_slot ()
  | Mix { m; c; slots } ->
      add
        (sprintf "/* %d keys, %d to %d bytes: the 64-bit mix by 0x%LxULL, %d slots (phash.ml) */\n"
           n lo hi c m);
      slot_tables m slots;
      head ();
      add "  uint64_t k = n < 8 ? n : 8, a = 0, b = 0;\n";
      add "  for (uint64_t j = 0; j < k; j++) {\n";
      add "    a |= (uint64_t)(uint8_t)s[j] << (8 * j);\n";
      add "    b |= (uint64_t)(uint8_t)s[n - k + j] << (8 * j);\n";
      add "  }\n";
      add
        (sprintf "  uint64_t h = ((a ^ (b * 0x9E3779B97F4A7C15ULL) ^ n) * 0x%LxULL) >> %d;\n" c
           (64 - max 1 (log2 m)));
      add (sprintf "  if (%s_len[h] != n) return -1;\n" name);
      compare_slot ()
  | Lengths ->
      add (sprintf "/* %d keys, %d to %d bytes: a switch on the length (phash.ml) */\n" n lo hi);
      head ();
      add "  switch (n) {\n";
      List.iter
        (fun l ->
          add (sprintf "  case %d:\n" l);
          Array.iteri
            (fun i k ->
              if String.length k = l then
                add
                  (sprintf "    if (ren_pat_bytes(s, %s, %d)) return %d;\n"
                     (c_string k) l i))
            keys;
          add "    return -1;\n")
        (List.sort_uniq compare (Array.to_list lens));
      add "  default:\n    return -1;\n  }\n}\n");
  Buffer.contents b
