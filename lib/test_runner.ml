(* `ren test`: run a program's tests, and say how each went (deps.md,
   "`ren test`").

     bank.ren
       ✓ a deposit is stamped with the time
       ✗ an overdraft is refused, and nothing moves

     ──── an overdraft is refused, and nothing moves ── bank.ren:14
        │
     14 │   assert acme == before
        │          ^^^^^^^^^^^^^^
        │
        left:  Bank { accounts: [...], next: 3 }
        right: Bank { accounts: [...], next: 2 }
                                              ^ differs here

        seed 2871 · rerun: ren test bank/ --only "an overdraft" --seed 2871

     1 passed, 1 failed in 5ms

   One line per test, by file, and inside a file by group run, as each
   finishes; then each failure, and a count. Each test runs on its own,
   with fresh test implementations (eval.ml, [run_test]), so the order
   they run in changes nothing, and a test that uses no real dependency
   gives the same output on every run. Only the time it all took can
   differ, which [timings] leaves out. *)

let sprintf = Printf.sprintf

type options = {
  path : string;  (** what `ren test` was given, as it was written *)
  dir : string;  (** the folder the program is in: files are shown from it *)
  only : string option;  (** run only the tests whose name has this in it *)
  exact : bool;
      (** [only] is a whole name, or a group run's label, not part of one: what
          an editor's button beside a test runs *)
  seed : int option;  (** every test's seed, instead of its own *)
  list : bool;  (** list the tests, without running them *)
  timings : bool;  (** say how long running them took *)
}

let full_name = Test_items.full_name

(* A test's own seed, from its name, so it's the same on every run and
   every machine: FNV-1a's hash of it, kept to four digits to be easy to
   type. [lxor] is exclusive or, and [land] keeps the low 32 bits. *)
let seed_of name =
  let h = ref 0x811c9dc5 in
  String.iter
    (fun c -> h := !h lxor Char.code c * 0x01000193 land 0xffffffff)
    name;
  !h mod 10000

(* A file, shown from the program's folder. *)
let shown_file ~dir file =
  let prefix = Filename.concat dir "" in
  if dir <> Filename.current_dir_name && String.starts_with ~prefix file then
    String.sub file (String.length prefix)
      (String.length file - String.length prefix)
  else file

(* ---- values, as a test shows them ----

   A value is shown as it's written, with the names of the types it's
   made of: a record after its type's name, `Account { id: AccountId(1)
   }`, and an opaque value as its type's name around what it is,
   `Money(-100)`, which `show` can't do, since at runtime it's only what
   it's represented as. So a value is shown through its type, and each
   type's declaration, [types], by its path. *)

(* [t] with each of its type's parameters, [Var i], replaced by [args]'s
   [i]th. *)
let rec subst args (t : Ty.ty) : Ty.ty =
  match t with
  | Var i -> ( match List.nth_opt args i with Some a -> a | None -> t)
  | Con (p, ts) -> Con (p, List.map (subst args) ts)
  | Fun (ps, r, e, u) ->
      Fun
        ( List.map (fun (p : Ty.param) -> { p with ty = subst args p.ty }) ps,
          subst args r,
          e,
          u )
  | Errors _ | Uses _ | Error -> t

let rec shown types (t : Ty.ty) (v : Value.t) =
  let list xs = String.concat ", " xs in
  match (t, v) with
  | Con (p, [ elem ]), VArray xs when p = Path.prelude "Array" ->
      "[" ^ list (Array.to_list (Array.map (shown types elem) xs)) ^ "]"
  | Con (p, args), _ -> (
      let d = Hashtbl.find_opt types p in
      match (Option.map (fun (d : Iface.type_decl) -> d.body) d, v) with
      | Some (Record fields), VRecord vs ->
          (* the fields in the order they're declared *)
          p.name ^ " { "
          ^ list
              (List.map
                 (fun (f : Iface.field) ->
                   f.fname ^ ": "
                   ^ shown types (subst args f.fty) (List.assoc f.fname vs))
                 fields)
          ^ " }"
      | Some (Sum ctors), VCon c -> (
          match
            List.find_opt (fun (k : Iface.ctor) -> k.cname = c.name) ctors
          with
          | Some k
            when k.cfields <> [] && List.length k.cfields = List.length c.args
            ->
              c.name ^ "("
              ^ list
                  (List.map2
                     (fun (f : Iface.field) a ->
                       shown types (subst args f.fty) a)
                     k.cfields c.args)
              ^ ")"
          | _ -> Value.show v)
      | Some (Opaque (Some rep)), _ ->
          p.name ^ "(" ^ shown types (subst args rep) v ^ ")"
      | Some (Opaque None), _ -> p.name ^ "(" ^ Value.show v ^ ")"
      | _ -> Value.show v)
  | _ -> Value.show v

(* Where [a] and [b] first differ: an index into both, or the length of
   the shorter if it's the start of the other. *)
let first_difference a b =
  let n = min (String.length a) (String.length b) in
  let rec go i = if i < n && a.[i] = b.[i] then go (i + 1) else i in
  go 0

(* ---- what's printed ---- *)

(* The source line of [loc], with `^`s under it, between empty lines of
   the gutter; nothing if its file can't be shown. Returns the gutter's
   width, which what follows is indented by. *)
let snippet b ~sources (loc : Loc.t) =
  let width = String.length (string_of_int loc.start.line) in
  let gutter = String.make width ' ' ^ " │" in
  (match sources loc.file with
  | Some src ->
      let text = Diag.line_text src loc.start.line in
      let stop =
        if loc.stop.line = loc.start.line then loc.stop.col
        else String.length text + 1
      in
      Printf.bprintf b "%s\n%d │ %s\n%s %s%s\n%s\n" gutter loc.start.line text
        gutter
        (String.make (loc.start.col - 1) ' ')
        (String.make (max 1 (stop - loc.start.col)) '^')
        gutter
  | None -> ());
  String.make (width + 1) ' '

(* The shortest start of [name], in whole words and at least two of them,
   that `--only` finds in no other test's name of [all], so a rerun runs
   just this one; or the whole name, if another has it all. *)
let only_for all name =
  let words = String.split_on_char ' ' name in
  let least = min 2 (List.length words) in
  let has sub n =
    let ls = String.length sub and ln = String.length n in
    let rec at i = i + ls <= ln && (String.sub n i ls = sub || at (i + 1)) in
    at 0
  in
  let rec go n taken = function
    | [] -> name
    | w :: rest ->
        let prefix = if taken = "" then w else taken ^ " " ^ w in
        if
          n >= least
          && List.for_all (fun n -> n = name || not (has prefix n)) all
        then
          if List.length (List.filter (( = ) name) all) > 1 then name
          else prefix
        else go (n + 1) prefix rest
  in
  go 1 "" words

(* A quoted argument for a shell: in double quotes, with what a shell would read
   inside them escaped. *)
let quoted s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      if c = '"' || c = '\\' || c = '$' || c = '`' then Buffer.add_char b '\\';
      Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

(* How a failed test failed, for its details. *)
type failure = {
  test : Test_items.test;
  file : string;  (** the file it's in *)
  seed : int;
  how : Eval.outcome;
  console : string list;
}

let details b ~opts ~sources ~types ~all f =
  let name = full_name f.test in
  let loc =
    match f.how with
    | Panicked (Eval.Panic (loc, _)) | Panicked (Eval.Assert_failed { loc; _ })
      ->
        loc
    | _ -> f.test.loc
  in
  Printf.bprintf b "\n──── %s ── %s:%d\n" name
    (shown_file ~dir:opts.dir loc.file)
    loc.start.line;
  let pad = snippet b ~sources loc in
  (match f.how with
  | Panicked (Eval.Assert_failed { sides = Some (t, l, r); _ }) ->
      let types = types in
      let l = shown types t l and r = shown types t r in
      Printf.bprintf b "%sleft:  %s\n%sright: %s\n%s%s^ differs here\n" pad l
        pad r pad
        (String.make (String.length "right: " + first_difference l r) ' ')
  | Panicked (Eval.Assert_failed { sides = None; _ }) ->
      Printf.bprintf b "%sthis is false\n" pad
  | Panicked (Eval.Panic (_, msg)) -> Printf.bprintf b "%spanic: %s\n" pad msg
  | Failed err -> Printf.bprintf b "%serror: %s\n" pad (Value.show err)
  | Panicked e -> raise e
  | Passed -> ());
  Printf.bprintf b "\n%sseed %d · rerun: ren test %s --only %s --seed %d\n" pad
    f.seed opts.path
    (quoted (only_for all name))
    f.seed;
  if f.console <> [] then (
    Printf.bprintf b "\n%sprinted:\n" pad;
    List.iter (fun l -> Printf.bprintf b "%s  %s\n" pad l) f.console)

(* Run [suite]'s tests, or with [opts.list], list them, printing as it
   goes. Returns the exit status: 1 if a test failed, or if `--only`
   matched none, which is more likely a mistyped name than a pass.
   [sources] gives the text of a file a failure points into. *)
let run ~opts ~sources (suite : Driver.suite) =
  let wanted (t : Test_items.test) =
    match opts.only with
    | None -> true
    | Some text when opts.exact -> full_name t = text || t.label = Some text
    | Some text ->
        let n = full_name t and ls = String.length text in
        let rec at i =
          i + ls <= String.length n && (String.sub n i ls = text || at (i + 1))
        in
        at 0
  in
  let files =
    List.filter_map
      (fun (file, home, tests) ->
        match List.filter wanted tests with
        | [] -> None
        | tests -> Some (file, home, tests))
      suite.files
  in
  let all =
    List.concat_map (fun (_, _, ts) -> List.map full_name ts) suite.files
  in
  let types = Hashtbl.create 64 in
  List.iter
    (fun (d : Iface.type_decl) -> Hashtbl.replace types d.path d)
    suite.types;
  (* a file's tests, each under its group run's label if it has one,
     printed by [line] *)
  let each_line ~line (file, home, tests) =
    print_endline (shown_file ~dir:opts.dir file);
    ignore
      (List.fold_left
         (fun label (t : Test_items.test) ->
           if t.label <> label then
             Option.iter (fun l -> print_endline ("  " ^ l)) t.label;
           line (if t.label = None then "  " else "    ") (file, home) t;
           t.label)
         None tests)
  in
  if opts.list then (
    List.iteri
      (fun i f ->
        if i > 0 then print_newline ();
        each_line f ~line:(fun indent _ t ->
            let real =
              match t.real with
              | [] -> ""
              | ds -> " · uses the real " ^ Infer_msg.and_list ds
            in
            print_endline (indent ^ t.name ^ real)))
      files;
    0)
  else
    let started = Unix.gettimeofday () in
    let cx = Eval.load suite.core in
    let failures = ref [] and passed = ref 0 in
    List.iteri
      (fun i f ->
        if i > 0 then print_newline ();
        each_line f ~line:(fun indent (file, home) t ->
            let seed =
              match opts.seed with Some s -> s | None -> seed_of (full_name t)
            in
            let how, console =
              Eval.run_test cx ~fn:(Path.make home t.fn) ~real:t.real ~seed
            in
            (match how with
            | Passed ->
                incr passed;
                print_endline (indent ^ "✓ " ^ t.name)
            | _ ->
                failures := { test = t; file; seed; how; console } :: !failures;
                print_endline (indent ^ "✗ " ^ t.name));
            flush stdout))
      files;
    let b = Buffer.create 1024 in
    List.iter (details b ~opts ~sources ~types ~all) (List.rev !failures);
    print_string (Buffer.contents b);
    let failed = List.length !failures in
    let counts =
      match (!passed, failed) with
      | 0, 0 -> (
          match opts.only with
          | Some text -> sprintf "no test's name has %s in it" (quoted text)
          | None -> "no tests")
      | p, 0 -> sprintf "%d passed" p
      | p, f -> sprintf "%d passed, %d failed" p f
    in
    let took =
      if opts.timings then
        sprintf " in %dms"
          (int_of_float ((Unix.gettimeofday () -. started) *. 1000.))
      else ""
    in
    Printf.printf "\n%s%s\n" counts took;
    if failed > 0 || (opts.only <> None && !passed = 0) then 1 else 0
