(* Tests, made into functions (deps.md, "Tests").

   The parser reads a module's tests and groups as items of their own
   (ast.ml, [testing]). Before Resolve sees the module, each becomes an
   ordinary private function, which every pass after it checks, lowers and
   runs like any other, and what the test runner needs to know about them
   is kept on the side:

     test "a deposit is stamped" =      fn $test1() =
       body                               body

     group conforms(c: Clock) with c =  fn conforms$1(c: Clock) =
       test "never goes back" =           with c in
         body                               body

     group "frozen" =                   fn $run1$1() =
       conforms(Clock.frozen(t))          conforms$1(Clock.frozen(t))

   A test's function takes no parameters, and the runner calls it with the
   test implementations installed (eval.ml, [run_test]). A group's tests
   are functions of its parameters, each inside its `with`, and a run of
   it is a function of no parameters for each of them, which calls it
   with the run's arguments. A `$` is in every name made here, which no
   name the program writes can have, so none of them can clash with one.

   Every function made here is test code, [fn_def.test], as a test item,
   `test fn`, is (ast.ml): only test code can call it, and `ren run`
   leaves it out.

   Another module runs a `pub group` by its alias, `conform.clock(c)`, so
   its tests' functions are in its interface's test tier, with the types
   inference found for them (driver.ml): what's here is what that module
   knows about the group, its [group]. *)

open Ast
open Ast.Parsed

let sprintf = Printf.sprintf

(* A group, as a module that runs it sees it. *)
type group = {
  gname : string;
  gpub : bool;
  arity : int;  (** how many arguments a run gives it *)
  gtests : (string * string list) list;
      (** each of its tests, in order: its name, and the built-in dependencies
          it gets the real implementation of *)
}

(* A test, as the runner sees it. *)
type test = {
  name : string;
  label : string option;  (** the label of the group run it's in, if any *)
  group : (string option * string) option;
      (** the group that run runs: the alias of the module it's in, if it's
          another's, and its name *)
  loc : Loc.t;  (** its name, or its run's label *)
  fn : string;  (** the function that runs it, of no parameters *)
  real : string list;
      (** the built-in dependencies it gets the real implementation of, as its
          `uses` lists them; the test implementation of every other one *)
}

type t = {
  prog : Parsed.program;  (** the module, its tests made functions *)
  tests : test list;  (** in source order, each group run's in its group's *)
  groups : group list;  (** the module's own groups *)
  made : string list;  (** the name of every function made here *)
  bodies : string list;
      (** the functions whose body is a test's, a top-level one's or a group's,
          which has to be `Unit` *)
  pub_tests : (string * string) list;
      (** each function made for a public group's test, with the group's name:
          another module calls it, so its parameters are in the interface *)
}

(* The built-in dependencies a test gets the test implementation of, each
   with the dependency that controls it, if one does: a test reads back
   what it wrote through `Fs` itself, and installs `test_os(args)` for
   other args. *)
let defaults =
  [
    ("Clock", Some "TestClock");
    ("Random", Some "TestRandom");
    ("Console", Some "TestConsole");
    ("Fs", None);
    ("Os", None);
    ("Proc", Some "TestProc");
  ]

(* A test's name, after its group run's label if it's in one, as
   `--only` looks for it, its seed comes from, and the runner and errors
   show it. *)
let full_name (t : test) =
  match t.label with Some l -> l ^ " / " ^ t.name | None -> t.name

(* A test's own seed, from its name, so it's the same on every run and
   every machine: FNV-1a's hash of it, kept to four digits to be easy to
   type. [lxor] is exclusive or, and [land] keeps the low 32 bits. *)
let seed_of name =
  let h = ref 0x811c9dc5 in
  String.iter
    (fun c -> h := !h lxor Char.code c * 0x01000193 land 0xffffffff)
    name;
  !h mod 10000

(* The function that runs the [i]th test (from 1) of the group [g], and
   what runs the [i]th of the [k]th group run. *)
let group_fn g i = sprintf "%s$%d" g i
let run_fn k i = sprintf "$run%d$%d" k i

(* The node of the `try` a group run's function puts around its call
   of the group's test, which passes on whatever that test fails with.
   It may fail with nothing, and Infer doesn't report such a `try` as
   covering nothing, as it would one the program writes. The parser
   numbers nodes from zero, and the `with`s of a group from -2 down
   ([program]), so -1 is this one's alone. *)
let passed_on = -1

(* A test's `uses`: the built-ins it asks for the real implementation of,
   by name. *)
let real_of sink (t : test_def) =
  match t.test_uses with
  | None -> []
  | Some u ->
      Option.iter
        (fun (d : ident) ->
          Diag.report sink
            (Diag.make d.loc ~help:"remove it"
               "a test can't name a row: its `uses` lists what it gets the \
                real implementation of"))
        u.dtail;
      List.filter_map
        (fun (d : tyname) ->
          match d.tmod with
          | None when List.mem_assoc d.tid.name defaults -> Some d.tid.name
          | _ ->
              Diag.report sink
                (Diag.make d.tid.loc
                   ~notes:
                     [
                       "a test gets the test implementation of each of them \
                        unless its `uses` asks for the real one";
                     ]
                   ~help:
                     "install an implementation inside the test, with `with`, \
                      and remove it from here"
                   (sprintf
                      "a test's `uses` asks for a real implementation, and \
                       only %s have one, not `%s`"
                      (Infer_msg.and_list (List.map fst defaults))
                      (show_tyname d)));
              None)
        u.deps

(* A function of no parameters, private and test code, made from code at
   [loc]. *)
let fn_of ~name ~loc ?(params = []) body =
  Fn
    {
      pub = false;
      name = { name; loc };
      tparams = [];
      params;
      ret = None;
      errors = None;
      uses = None;
      body;
      owner = None;
      overload = 0;
      test = true;
      loc = Loc.span loc body.loc;
    }

(* Report the second of two things with the same name. *)
let unique sink ~what ?(show = show_str) (items : (string * Loc.t) list) =
  let seen = Hashtbl.create 8 in
  List.iter
    (fun (name, loc) ->
      match Hashtbl.find_opt seen name with
      | Some first ->
          Diag.report sink
            (Diag.make loc ~help:"rename one of them"
               ~labels:[ (first, "the first is here") ]
               (sprintf "there are two %s named %s" what (show name)))
      | None -> Hashtbl.replace seen name loc)
    items

(* The module [prog], its tests made functions. [imported] are the public
   groups of each module it imports, by its alias there. *)
let program sink ~(imported : (string * group list) list) (prog : program) =
  let fn_names =
    List.filter_map (function Fn (f : fn_def) -> Some f.name | _ -> None) prog
  in
  (* the module's own groups, which a run can come before *)
  let groups =
    List.filter_map
      (function
        | Testing (Group g) ->
            List.iter
              (fun (f : ident) ->
                if f.name = g.group_name.name then
                  Diag.report sink
                    (Diag.make g.group_name.loc ~help:"rename one of them"
                       ~labels:[ (f.loc, "the function is here") ]
                       (sprintf "there's a function named `%s` already" f.name)))
              fn_names;
            unique sink ~what:"tests in this group"
              (List.map
                 (fun (t : test_def) -> (t.test_name, t.test_loc))
                 g.group_tests);
            Some
              ( g.group_name.loc,
                {
                  gname = g.group_name.name;
                  gpub = g.group_pub;
                  arity = List.length g.group_params;
                  gtests =
                    List.map
                      (fun t -> (t.test_name, real_of sink t))
                      g.group_tests;
                } )
        | _ -> None)
      prog
  in
  unique sink ~what:"groups" ~show:(sprintf "`%s`")
    (List.map (fun (l, g) -> (g.gname, l)) groups);
  let groups = List.map snd groups in
  unique sink ~what:"tests"
    (List.filter_map
       (function
         | Testing (Test t) -> Some (t.test_name, t.test_loc)
         | Testing (Run_group r) -> Some (r.run_label, r.run_loc)
         | _ -> None)
       prog);
  (* the group a run's call calls, and how to call each of its tests:
     the function's name in its module, written as the run writes the
     group's *)
  let group_of (call : expr) =
    match call.kind with
    | Call (({ kind = Var (Bare g); _ } as f), args) -> (
        match List.find_opt (fun x -> x.gname = g) groups with
        | Some grp ->
            Some (grp, args, None, fun name -> { f with kind = Var (Bare name) })
        | None ->
            Diag.report sink
              (Diag.make f.loc
                 ~help:
                   "declare it with `group name(...) =`, or run one another \
                    module declares, after its alias: `m.name(...)`"
                 (sprintf "there's no group named `%s`" g));
            None)
    | Call
        ( ({ kind = Field (({ kind = Var (Bare m); _ } as alias), g); _ } as f),
          args ) -> (
        match List.assoc_opt m imported with
        | None ->
            Diag.report sink
              (Diag.make alias.loc
                 ~help:
                   (sprintf "import it at the top of the file, like `import %s`"
                      m)
                 (sprintf "there's no module imported as `%s`" m));
            None
        | Some gs -> (
            match List.find_opt (fun x -> x.gname = g.name) gs with
            | Some grp ->
                Some
                  ( grp,
                    args,
                    Some m,
                    fun name -> { f with kind = Field (alias, { g with name }) }
                  )
            | None ->
                Diag.report sink
                  (Diag.make g.loc ~help:"if it's declared there, mark it `pub`"
                     (sprintf "`%s` has no public group `%s`" m g.name));
                None))
    | _ ->
        Diag.report sink
          (Diag.make call.loc ~help:"call a group with its arguments: `g(...)`"
             "a group's run calls a group");
        None
  in
  (* each test, group and run, numbered in source order *)
  let tests = ref [] and made = ref [] and bodies = ref [] in
  let pub_tests = ref [] in
  let make name item =
    made := name :: !made;
    item
  in
  let ntests = ref 0 and nruns = ref 0 in
  let prog =
    List.concat_map
      (function
        | Testing (Test t) ->
            incr ntests;
            let fn = sprintf "$test%d" !ntests in
            tests :=
              {
                name = t.test_name;
                label = None;
                group = None;
                loc = t.test_loc;
                fn;
                real = real_of sink t;
              }
              :: !tests;
            bodies := fn :: !bodies;
            [ make fn (fn_of ~name:fn ~loc:t.test_loc t.test_body) ]
        | Testing (Group g) ->
            (* `with a, b in body`, its node numbered below zero, apart
               from the parser's *)
            let nest (body : expr) : expr =
              match g.group_with with
              | [] -> body
              | first :: _ ->
                  {
                    kind = With { items = g.group_with; body };
                    loc = Loc.span first.iloc body.loc;
                    node = -1;
                  }
            in
            List.mapi
              (fun i (t : test_def) ->
                let name = group_fn g.group_name.name (i + 1) in
                bodies := name :: !bodies;
                if g.group_pub then
                  pub_tests := (name, g.group_name.name) :: !pub_tests;
                make name
                  (fn_of ~name ~loc:t.test_loc ~params:g.group_params
                     (nest t.test_body)))
              g.group_tests
        | Testing (Run_group r) -> (
            incr nruns;
            match group_of r.run_call with
            | None -> []
            | Some (grp, args, from, callee) ->
                if List.length args <> grp.arity then (
                  Diag.report sink
                    (Diag.make r.run_call.loc
                       ~help:
                         (sprintf "give it %d argument%s" grp.arity
                            (if grp.arity = 1 then "" else "s"))
                       (sprintf
                          "the group `%s` takes %d argument%s, but this gives \
                           it %d"
                          grp.gname grp.arity
                          (if grp.arity = 1 then "" else "s")
                          (List.length args)));
                  [])
                else
                  List.mapi
                    (fun i (name, real) ->
                      let fn = run_fn !nruns (i + 1) in
                      tests :=
                        {
                          name;
                          label = Some r.run_label;
                          group = Some (from, grp.gname);
                          loc = r.run_loc;
                          fn;
                          real;
                        }
                        :: !tests;
                      (* `try g$i(args)`, so what the test fails with
                         reaches the runner, as a top-level test's does *)
                      let call =
                        {
                          r.run_call with
                          kind =
                            Try
                              {
                                r.run_call with
                                kind =
                                  Call
                                    (callee (group_fn grp.gname (i + 1)), args);
                              };
                          node = passed_on;
                        }
                      in
                      make fn (fn_of ~name:fn ~loc:r.run_loc call))
                    grp.gtests)
        | item -> [ item ])
      prog
  in
  {
    prog;
    tests = List.rev !tests;
    groups;
    made = List.rev !made;
    bodies = List.rev !bodies;
    pub_tests = List.rev !pub_tests;
  }
