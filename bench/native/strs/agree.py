# `python3 -I agree.py <twin> <n> <records> <rounds>`: what the twin
# prints given the sizes `bench.run(n, records, rounds)` runs, in its
# order, so it can be compared with the Ren's: `ren run small.ren` is
# `agree.py <twin> 200 10 2`, and main.ren `1000000 5000 1`.
import subprocess, sys

twin, n, records, rounds = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
size = str(int(n) * 1048576 // 1000000)
for w, k in [("tok", n), ("map", n), ("sort", n), ("group", n), ("logs", n),
             ("out_json", records), ("out_json", records), ("out_logs", records),
             ("out_logs", records), ("utf8_ascii", size), ("utf8_cjk", size), ("utf8_mixed", size)]:
    sys.stdout.write(subprocess.run([twin, w, k, rounds], capture_output=True, text=True, check=True).stdout)
