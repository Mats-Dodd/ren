# X1: the register convention end to end

`ren_reg.c` is `ren_single.c`'s `pingpong` and `pingpong_nested` in the
register convention of SYNTHESIS §5: `ren_ret fn(task*, frame*, char *sp,
uint64_t in)` returning `{status, value}` in two registers, `sp` a C local,
locals spilled only on the way out of a suspension, headers written only on
the PENDING path, only the innermost suspender writing `t->top`. The heap,
instances and waiter queues are `ren_single.c`'s, unchanged. The baseline is
`../../runtime-p2/switch/c/ren_single.c` itself, built unmodified.
`common.h` is a copy of the prototype's.

Builds (`./build.sh`):

| binary | what |
|---|---|
| `base_clang`, `base_tcc` | the prototype, clang -O2 and tcc -O2 |
| `reg_clang`, `reg_tcc` | the register convention; clang may inline put/get into the body, as it does in the prototype |
| `reg_noinl_clang` | put and get kept out of line (`-DOPS_NOINLINE`) |
| `reg_nochk_clang` | no frame-stack bounds check (`-DBUMP_NOCHECK`: release, when the inline segment covers the static bound) |
| `*_asan` | ASan + UBSan, for `--check` |

Commands:

    ./build.sh
    build/reg_asan --check; build/reg_noinl_asan --check; build/reg_tcc --check
    build/reg_clang --bench pingpong_nested --n 2000000 --reps 5
    ./measure.sh                         # 7 interleaved rounds -> results/raw-*.txt
    ./summarize.py results/raw-<stamp>.txt
