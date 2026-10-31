Stage 12a's disabled cases are explicit skips. Each enabled case must
match its fixed output before comparison with native debug (both counting
modes), release, sanitizers, tcc and `ren run --release`. Missing tools
fail an enabled case. See shapes/README.md for the remaining coverage.

  $ python3 shapes/check.py
  front_end: until s1
  static_data: until s2
  template: until s3
  json: until s7
  bin: until s7
  freezing: until s8
  static C: until s2
  template allocations: until s3
  copy names: until s7
  walk and explain: until s4
  unit runtime targets: native until s7
