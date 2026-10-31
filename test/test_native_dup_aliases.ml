(* Consecutive counts can name the same object more than once. Keep every
   count, but don't ask C to compare an expression with itself: Clang reports
   that even when the surrounding runtime equality test is useful. *)

open Ren

let contains text part =
  let rec at i =
    i + String.length part <= String.length text
    && (String.sub text i (String.length part) = part || at (i + 1))
  in
  at 0

let require text part =
  if not (contains text part) then failwith ("C is missing: " ^ part)

let file = "dup_aliases.ren"

let source =
  {|fn duplicate(xs: Array<Int>, ys: Array<Int>) -> Int = xs.len() + ys.len()
fn main() -> Int = duplicate([1], [2])
|}

let check ~release =
  let program = Driver.mem ~lint:true ~release ~file source in
  let fn =
    List.find
      (fun (f : Mem.fn) ->
        f.loc.file = file
        && List.for_all
             (fun name -> List.exists (fun (v : Mem.var) -> v.name = name) f.params)
             [ "xs"; "ys" ])
      program.fns
  in
  let parameter name = List.find (fun (v : Mem.var) -> v.name = name) fn.params in
  let x = parameter "xs" and y = parameter "ys" in
  (* These simple source names need no C escaping. Derive their ids from the
     checked program rather than depending on the allocator's numbering. *)
  let cname (v : Mem.var) = Printf.sprintf "v%d_%s" v.id v.name in
  let a = cname x and b = cname y in
  let cases = [ ("equal", [ x; x ]); ("mixed", [ x; x; y ]); ("distinct", [ x; y ]) ] in
  List.iter
    (fun (name, objects) ->
      (* Balanced counts isolate the emitter from RC placement heuristics;
         the original checked function still owns precisely what it did. *)
      let before = List.map (fun v -> Mem.Dup (Mem.Var v)) objects in
      let after = List.map (fun v -> Mem.Drop (Mem.Var v)) objects in
      let changed = { fn with body = before @ after @ fn.body } in
      let p =
        { program with
          fns = List.map (fun (f : Mem.fn) -> if f.name = fn.name then changed else f) program.fns }
      in
      Mem_lint.program p;
      let verify c =
        if contains c (a ^ " == " ^ a) || contains c (b ^ " == " ^ b) then
          failwith "C compares a counted object expression with itself";
        let n = List.length objects in
        let grouped = Printf.sprintf "ren_dup_by(%s, %d);" a n in
        if name = "equal" then (
          require c grouped;
          if contains c ("if (" ^ b ^ " == " ^ a ^ ") " ^ grouped) then
            failwith "equal expressions still need a runtime equality test")
        else
          require c
            (Printf.sprintf "if (%s == %s) %s else ren_dup_each(%d, %s);"
               b a grouped n (String.concat ", " (List.map cname objects)))
      in
      verify (Emit_c.program ~release ~site_pieces:(fun _ -> []) p);
      if not release then (
        let units = Emit_c.units ~jobs:1 ~site_pieces:(fun _ -> []) p in
        verify (String.concat "\n" (List.map snd units.program))))
    cases;
  Printf.printf "%s: equal, mixed and distinct counts; Mem Lint and C agree\n"
    (if release then "release" else "debug")

let%expect_test "repeated counts keep their multiplicity without self comparisons" =
  check ~release:false;
  check ~release:true;
  [%expect
    {|
    debug: equal, mixed and distinct counts; Mem Lint and C agree
    release: equal, mixed and distinct counts; Mem Lint and C agree
    |}]
