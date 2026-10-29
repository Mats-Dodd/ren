# `python3 -I variants.py <out>`: for each of build.sh's release C files
# in <out>, variants with one cost taken out, built at -O2 as `ren build
# --release` builds, into <out>/var as `<name>.<variant>`. They aren't
# sound programs, only measurements of what each cost is (compiler.md,
# "Bytes stage", "The baseline"):
#
#   base      the C as emitted, built again
#   nob       `Bytes.at` without its bounds check
#   noovf     `+`, `-` and `*` of `Int`s without their overflow checks
#   noarr     arrays' index checks gone
#   none      all three
#   push      an array of records' push inline, its stride a constant
#             (json's tokens are 3 words, pages' records 4)
#   pushnone  push, and none
#   O3        the C as emitted, at -O3
import os, re, subprocess, sys

out = sys.argv[1]
os.makedirs(f"{out}/var", exist_ok=True)
strides = {"json_r": 3, "pages_r": 4}

BYTES_AT = re.compile(
    r"int64_t ren_bytes_at\(ren_obj \*b, int64_t i, const ren_site \*site\) \{.*?\n\}\n", re.S)

def nob(c):
    assert BYTES_AT.search(c)
    return BYTES_AT.sub(
        "int64_t ren_bytes_at(ren_obj *b, int64_t i, const ren_site *site) {\n"
        "  (void)site; return (unsigned char)ren_str_data(b)[i];\n}\n", c)

def noovf(c):
    for op, sym in [("add", "+"), ("sub", "-"), ("mul", "*")]:
        old = f"#define ren_{op}_overflow(a, b, r) __builtin_{op}_overflow(a, b, r)"
        assert old in c
        c = c.replace(old, f"#define ren_{op}_overflow(a, b, r) "
                           f"((*(r) = (int64_t)((uint64_t)(a) {sym} (uint64_t)(b))), 0)")
    return c

def noarr(c):
    old = "if (site != REN_IN_BOUNDS &&"
    assert old in c
    return c.replace(old, "if (0 && site != REN_IN_BOUNDS &&")

def push(c, k):
    helper = f"""
static inline __attribute__((always_inline)) void ren_push_k(ren_obj **cell, const ren_val *v) {{
  ren_obj *a = *cell;
  ren_array *arr = (ren_array *)a;
  if (__builtin_expect(ren_rc(a) == 1 && arr->cap > 0 && arr->len < arr->cap, 1)) {{
    memcpy(&arr->data[arr->len * {k}], v, {k} * sizeof(ren_val));
    arr->len++;
    return;
  }}
  ren_array_push_slots_taking(cell, v);
}}
"""
    # the program's own functions come after the runtime's, from the
    # table of its texts on
    at = c.index("static const char *const ren_text_table")
    return c[:at] + helper + c[at:].replace("ren_array_push_slots_taking(", "ren_push_k(")

def build(c_file, binary, opt="-O2"):
    subprocess.run(["cc", opt, "-ffp-contract=off", "-w", "-o", binary, c_file, "-lm", "-lpthread"],
                   check=True)

for f in sorted(os.listdir(out)):
    if not f.endswith(".c"):
        continue
    name = f[:-2]
    c = open(f"{out}/{f}").read()
    vs = {"base": c, "nob": nob(c), "noovf": noovf(c), "noarr": noarr(c),
          "none": noarr(noovf(nob(c)))}
    k = strides.get(name.split("-")[0])
    if k:
        vs["push"] = push(c, k)
        vs["pushnone"] = noarr(noovf(nob(push(c, k))))
    for v, text in vs.items():
        path = f"{out}/var/{name}.{v}.c"
        open(path, "w").write(text)
        build(path, f"{out}/var/{name}.{v}")
    build(f"{out}/{f}", f"{out}/var/{name}.O3", "-O3")
    print("variants of", name)
