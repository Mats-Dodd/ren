Generators stage (compiler.md, "Generators stage"). Every disabled specimen
executes and must produce its recorded rejection. Adding g1 ... g5 to
`generators/stages` activates strict targets. The native checks require cc,
ASan/UBSan and tcc (REN_TCC); they never silently skip a missing compiler.

  $ sh generators/check.sh interpreter
  pure: until g1 (recorded rejection)
  cursor_show: until g1 (recorded rejection)
  lifetime: until g1 (recorded rejection)
  part_two: until g1 (recorded rejection)
  stages: until g2 (recorded rejection)
  lifetime_push: until g2 (recorded rejection)
  unique: until g4 (recorded rejection)
  depth_push: until g4 (recorded rejection)
  depth_pull: until g4 (recorded rejection)
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
  cancel_sim: until g1 (recorded rejection)
  merge_sim: until g3 (recorded rejection)
  expand_sim: until g3 (recorded rejection)

  $ sh generators/check.sh replay
  replay: until g3 (recorded rejection)
