Every benchmark runs in the interpreter at its small size and prints its
checksum. Each is the one its Rust and Go twins print given that size
(build.sh builds them; README.md says how they were compared), so a
change here is a change in what the program computes.

  $ for f in */small.ren; do echo "== ${f%/small.ren}"; (cd "$(dirname "$f")" && ren run small.ren); done
  == binary-trees
  stretch tree of depth 7	 check: 255
  64	 trees of depth 4	 check: 1984
  16	 trees of depth 6	 check: 2032
  long lived tree of depth 6	 check: 127
  == blocks
  map 437 437
  reduce 6493500 6493500
  each 6493500 6493500
  fold 6493500 6493500
  attempt 29999 29999
  == bytes
  124394
  29366541
  3499174900
  == cfold
  2386
  2386
  == deriv
  1 count: 6
  2 count: 22
  3 count: 90
  4 count: 420
  5 count: 2202
  done
  == dispatch
  1796853846
  1836285161
  783651312
  241444348
  206923200
  514636
  105
  == fannkuch
  228
  Pfannkuchen(7) = 16
  == frames
  27482
  1549781985402896218
  == handlers
  2997
  2997
  == inout
  60809898
  == nbody
  -0.169075164
  -0.169087605
  == nested
  996055
  664567
  997991
  == nqueens
  92
  == rbtree
  100
  == slices
  47437
  287592
  287592
  58208
  5414172
  5414172
  81920
  23252
  23252
  == stack
  22446
  33334
  504000
  34530
  == vec
  576172
  773438
  73750
  73750
  -967413
  49500
  11785
