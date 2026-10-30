(* The perfect hash's fuzz (compiler.md, "Patterns stage", "The
   generator"), research/perfect-hash/verify's ported: random key sets
   and the research's adversarial ones, each looked up with random
   queries, hits and near misses, by every form against a plain search
   of the keys, which is what a chain of literal arms answers.

   - In OCaml, the generator's plan (Phash.lookup), every set.
   - In C, the lookups phash.ml writes, compiled with ren_rt.h: the
     two-word compare (cc), `memcmp` (-DREN_PH_MEMCMP, and cc under
     AddressSanitizer, which picks it), and tcc's, if $REN_TCC is set;
     each query copied to the end of a page with a page no one may read
     after it, so a read past it would crash, and `""` at the start of
     that page. *)

open Ren

let alphabet = "abcdefghijklmnopqrstuvwxyz_-0123456789"

(* A random string of [lo] to [hi] bytes over the first [k] letters of
   [alphabet], or of any byte with [k = 0]. *)
let random st ~lo ~hi k =
  String.init
    (lo + Random.State.int st (hi - lo + 1))
    (fun _ ->
      if k = 0 then Char.chr (Random.State.int st 256)
      else alphabet.[Random.State.int st k])

let distinct keys =
  List.fold_left (fun acc k -> if List.mem k acc then acc else acc @ [ k ]) [] keys

(* The research's adversarial sets (research/perfect-hash/verify/fuzz/
   mkkeys.py), and edges of the emitter's six fixes. *)
let adversarial =
  let p = "application/vnd.ren." in
  let st = Random.State.make [| 7 |] in
  let short =
    List.init 5000 (fun _ -> random st ~lo:1 ~hi:9 2)
    |> List.sort_uniq compare
    |> List.filteri (fun i _ -> i < 200)
  in
  [
    ("prefix", List.map (( ^ ) p) [ "a"; "b"; "ab"; "ba"; "abc"; "json"; "jsonl"; "xml" ]
               @ List.map (fun k -> String.sub p 0 k) [ 1; 2; 5; 8; 15; 16; 17 ]);
    ("past16", List.map (( ^ ) (String.make 20 'x')) [ "aaaa"; "aaab"; "aaba"; "abaa"; "baaa" ]
               @ List.init 8 (fun i -> String.make 15 'y' ^ String.make 1 (Char.chr (97 + i)))
               @ [ String.make 17 'q'; String.make 18 'q'; String.make 19 'q' ]);
    ("empty", [ ""; "a"; "b"; "ab"; "ba"; "GET"; "PUT"; String.make 16 'x'; String.make 17 'x' ]);
    ("emptyonly", [ "" ]);
    ("emptypair", [ ""; "z" ]);
    ("k200short", short);
    ("k200prefix", List.init 200 (fun i -> "user.settings." ^ string_of_int i));
    ("lenonly", [ "a"; "bb"; "ccc"; "dddd"; "eeeee"; String.make 16 'f'; String.make 17 'g'; String.make 40 'h' ]);
    ("long300", [ String.make 300 'L'; String.make 44 'L'; "short"; String.make 299 'L' ]);
    ("long255", [ String.make 255 'M'; "abc"; "abd" ]);
    ("arms128", List.init 128 (fun i -> "k" ^ string_of_int i));
    ("utf8", [ "café"; "cafe"; "cafè"; "日本"; "日本語"; "😀"; "😁"; "é"; "è"; "ß"; "ss" ]);
  ]

(* Random sets: few or many keys, short or long, over a few letters or
   any byte. *)
let random_sets n =
  let st = Random.State.make [| 42 |] in
  List.init n (fun i ->
      let count = 2 + Random.State.int st (if i mod 4 = 0 then 199 else 30) in
      let k = [| 2; 4; 26; 38; 0 |].(i mod 5) in
      let hi = [| 4; 12; 24; 40 |].(i mod 4) in
      (Printf.sprintf "random%d" i, distinct (List.init count (fun _ -> random st ~lo:0 ~hi k))))

(* Queries of [keys]: each key, near misses of each (a byte changed,
   added or cut), and random strings. *)
let queries st keys =
  let near k =
    let n = String.length k in
    [ k ^ "_"; "_" ^ k ]
    @ (if n > 0 then [ String.sub k 0 (n - 1); String.mapi (fun i c -> if i = n - 1 then Char.chr ((Char.code c + 1) land 255) else c) k ] else [])
  in
  keys @ List.concat_map near keys
  @ List.init 200 (fun _ -> random st ~lo:0 ~hi:20 (if Random.State.bool st then 4 else 0))

let index keys q =
  let rec go i = function [] -> -1 | k :: rest -> if k = q then i else go (i + 1) rest in
  go 0 keys

let sets () = adversarial @ random_sets 120

let%expect_test "the generator's plans agree with a search of the keys" =
  let st = Random.State.make [| 1 |] in
  let forms = Hashtbl.create 4 in
  let bad = ref 0 and asked = ref 0 in
  List.iter
    (fun (_, keys) ->
      let ks = Array.of_list keys in
      let plan = Phash.plan ks in
      let form = match plan with Hash _ -> "hash" | Mix _ -> "mix" | Lengths -> "lengths" in
      Hashtbl.replace forms form (1 + Option.value ~default:0 (Hashtbl.find_opt forms form));
      List.iter
        (fun q ->
          incr asked;
          if Phash.lookup ks plan q <> index keys q then incr bad)
        (queries st keys))
    (sets ());
  Printf.printf "%d sets, %d disagreements\n" (List.length (sets ())) !bad;
  List.iter
    (fun f -> Printf.printf "%s: %d\n" f (Option.value ~default:0 (Hashtbl.find_opt forms f)))
    [ "hash"; "mix"; "lengths" ];
  [%expect {|
    132 sets, 0 disagreements
    hash: 129
    mix: 2
    lengths: 1
    |}]

let%expect_test "the same keys give the same tables" =
  let same =
    List.for_all
      (fun (_, keys) ->
        let ks = Array.of_list keys in
        Phash.c ~name:"ren_ph0" ks (Phash.plan ks) = Phash.c ~name:"ren_ph0" ks (Phash.plan (Array.copy ks)))
      (sets ())
  in
  print_endline (if same then "the same" else "different");
  [%expect {| the same |}]

(* ---- the C ---- *)

let tmp = Filename.concat (Filename.get_temp_dir_name ()) "ren-phash-fuzz"

(* A C program with every set's lookup, which reads queries, a set's
   number and a string's bytes in hex a line, and prints what the
   lookup gives each; each string copied to the end of a page with a
   page no one may read after it. *)
let program sets =
  let b = Buffer.create 65536 in
  let add = Buffer.add_string b in
  add "#include \"ren_rt.h\"\n#include <sys/mman.h>\n#include <unistd.h>\n\n";
  List.iteri
    (fun i (_, keys) ->
      let ks = Array.of_list keys in
      add (Phash.c ~name:(Printf.sprintf "ren_ph%d" i) ks (Phash.plan ks)))
    sets;
  add "typedef int64_t (*lookup)(const char *, uint64_t);\n";
  add
    (Printf.sprintf "static const lookup lookups[%d] = {%s};\n" (List.length sets)
       (String.concat "," (List.mapi (fun i _ -> Printf.sprintf "ren_ph%d" i) sets)));
  add
    {|
int main(void) {
  long page = sysconf(_SC_PAGESIZE);
  char *mem = mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (mem == MAP_FAILED || mprotect(mem + page, page, PROT_NONE) != 0) return 2;
  char line[1024];
  int set;
  while (scanf("%d %1000s", &set, line) == 2) {
    size_t n = line[0] == '.' ? 0 : strlen(line) / 2;
    /* at the end of the page, the guard page right after it; "" at the
       start of the guard page itself */
    char *s = n == 0 ? mem + page : mem + page - n;
    for (size_t i = 0; i < n; i++) {
      unsigned v;
      sscanf(line + 2 * i, "%2x", &v);
      s[i] = (char)v;
    }
    printf("%lld\n", (long long)lookups[set](s, (uint64_t)n));
  }
  return 0;
}
|};
  Buffer.contents b

let hex s = if s = "" then "." else String.concat "" (List.init (String.length s) (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let run_c ~label ~cc ~flags sets =
  (try Sys.mkdir tmp 0o755 with Sys_error _ -> ());
  let write f s = Out_channel.with_open_bin (Filename.concat tmp f) (fun oc -> output_string oc s) in
  write "ren_rt.h" Runtime_c.header;
  write "fuzz.c" (program sets);
  let st = Random.State.make [| 2 |] in
  let qs = List.concat (List.mapi (fun i (_, keys) -> List.map (fun q -> (i, keys, q)) (queries st keys)) sets) in
  write "queries.txt" (String.concat "" (List.map (fun (i, _, q) -> Printf.sprintf "%d %s\n" i (hex q)) qs));
  let exe = Filename.concat tmp "fuzz" in
  let cmd =
    Printf.sprintf "cd %s && %s %s -I. -o %s fuzz.c > cc.out 2>&1 && %s < queries.txt > answers.txt"
      (Filename.quote tmp) cc flags (Filename.quote exe) (Filename.quote exe)
  in
  if Sys.command cmd <> 0 then
    Printf.printf "%s: failed\n%s" label
      (In_channel.with_open_bin (Filename.concat tmp "cc.out") In_channel.input_all)
  else
    let answers =
      In_channel.with_open_bin (Filename.concat tmp "answers.txt") In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (( <> ) "")
      |> List.map int_of_string
    in
    let bad =
      List.length
        (List.filter (fun ((_, keys, q), a) -> a <> index keys q) (List.combine qs answers))
    in
    Printf.printf "%s: %d queries, %d disagreements\n" label (List.length qs) bad

let%expect_test "the C lookups agree with a search of the keys, in every compare" =
  let sets = sets () in
  run_c ~label:"two words (cc)" ~cc:"cc" ~flags:"-O2" sets;
  run_c ~label:"memcmp (cc -DREN_PH_MEMCMP)" ~cc:"cc" ~flags:"-O2 -DREN_PH_MEMCMP" sets;
  run_c ~label:"memcmp (cc, AddressSanitizer)" ~cc:"cc" ~flags:"-O1 -fsanitize=address,undefined" sets;
  (match Sys.getenv_opt "REN_TCC" with
  | Some tcc when tcc <> "" -> run_c ~label:"two words (tcc)" ~cc:tcc ~flags:"" sets
  | _ -> print_endline "(no tcc)");
  [%expect {|
    two words (cc): 44783 queries, 0 disagreements
    memcmp (cc -DREN_PH_MEMCMP): 44783 queries, 0 disagreements
    memcmp (cc, AddressSanitizer): 44783 queries, 0 disagreements
    two words (tcc): 44783 queries, 0 disagreements
    |}]
