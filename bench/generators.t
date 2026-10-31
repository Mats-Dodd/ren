Generators stage (compiler.md, "Generators stage"). Every disabled specimen
executes and must produce its recorded rejection. g1 is enabled in
`generators/stages`; subsequent steps activate strict targets there. The native checks require cc,
ASan/UBSan and tcc (REN_TCC); they never silently skip a missing compiler.

  $ sh generators/check.sh interpreter
  pure: interpreter and ren run --release as specified
  cursor_show: interpreter and ren run --release as specified
  lifetime: interpreter and ren run --release as specified
  part_two: interpreter and ren run --release as specified
  stages: until g2 (recorded rejection)
  lifetime_push: until g2 (recorded rejection)
  unique: interpreter and ren run --release as specified
  depth_push: interpreter and ren run --release as specified
  depth_pull: interpreter and ren run --release as specified
  fs: until g5 (recorded rejection)
  transaction: until g5 (recorded rejection)
  fs_push: until g5 (recorded rejection)
  transaction_push: until g5 (recorded rejection)

  $ sh generators/check.sh native
  pure: native until g4
  cursor_show: native until g4
  stages: native until g4
  lifetime_push: native until g4
  unique: native until g4
  depth_push: native until g4
  depth_pull: native until g4
  fs_push: native until g5
  transaction_push: native until g5
  part_two: native refusal until g4
  cursor operation refusals: native until g4

  $ sh generators/check.sh sim
  queues: existing contracts pass across 1000 seeds
  close_sender: existing closed-send panic as specified
  cancel_sim: all assertions passed across 1000 seeds
  merge_sim: until g3 (recorded rejection)
  expand_sim: until g3 (recorded rejection)

  $ sh generators/check.sh replay
  replay: until g3 (recorded rejection)

Ordinary returns are checked natively at g1; generator lowering remains g4.
The Unit-valued dependency callback boundary must be explicit until then.

  $ sh generators/check.sh compatibility
  returns: interpreter and ren run --release as specified
  returns: perceus agrees, objects live at exit 0
  returns: naive agrees, objects live at exit 0
  returns: release agrees, objects live at exit 0
  returns: tcc agrees, objects live at exit 0
  return_with: interpreter and ren run --release as specified
  return_with: explicit native callback boundary
  native_refusal: interpreter and ren run --release as specified
  generator execution: explicit g1 native refusal
