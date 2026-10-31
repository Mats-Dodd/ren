#!/usr/bin/env python3
"""Build X5 on Linux with native clocks and allocator/OS observations.

Usage: python3 -I linux.py /tmp/x5-linux [cc]
The original frames.c is left untouched; generated frames-linux.c is reviewable.
The original bookkeeping arrays are freed after all measurements and checks.
RSS is reported for both former Mach memory columns, and glibc mallinfo2's
uordblks replaces the malloc-zone observation. They are not macOS metrics.
"""
import pathlib
import subprocess
import sys

out = pathlib.Path(sys.argv[1]).resolve()
cc = sys.argv[2] if len(sys.argv) > 2 else "clang"
out.mkdir(parents=True, exist_ok=True)
src = (pathlib.Path(__file__).parent / "frames.c").read_text()
a = src.index("#if defined(__TINYC__) /* tcc can't parse")
b = src.index("#include <stdbool.h>", a)
src = src[:a] + "#include <malloc.h>\n#include <time.h>\n#include <unistd.h>\n" + src[b:]
src = src.replace("static uint64_t now(void) { return mach_absolute_time(); }", """static uint64_t now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}""")
a = src.index("static uint64_t footprint(void)")
b = src.index("static int park_bench", a)
src = src[:a] + """static uint64_t resident(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) abort();
  unsigned long total, pages;
  int got = fscanf(f, "%lu %lu", &total, &pages);
  fclose(f);
  if (got != 2) abort();
  return (uint64_t)pages * (uint64_t)sysconf(_SC_PAGESIZE);
}
static uint64_t footprint(void) { return resident(); }
static uint64_t zone_in_use(void) { return mallinfo2().uordblks; }

""" + src[b:]
src = src.replace("malloc_size(", "malloc_usable_size(")
src = src.replace("zone_B_per_task=", "heap_B_per_task=")
src = src.replace("malloc_size_B_per_task=", "usable_B_per_task=")
src = src.replace("footprint_B_per_task=", "rss1_B_per_task=")
src = src.replace("resident_B_per_task=", "rss2_B_per_task=")
src = src.replace("  mach_timebase_info_data_t tb;\n  mach_timebase_info(&tb);\n  tick_ns = (double)tb.numer / tb.denom;", "  tick_ns = 1.0;")
# The original harness retains ts and waiting until process exit; free these
# after all observations and checks so Linux LeakSanitizer also checks clean.
src = src.replace("  return ok ? 0 : 1;\n}\n\n/* ---------- the chunk boundary", "  free(ts);\n  free(waiting);\n  return ok ? 0 : 1;\n}\n\n/* ---------- the chunk boundary")
path = out / "frames-linux.c"
path.write_text(src)
subprocess.run([cc, "-O2", "-Wall", "-Wextra", str(path), "-o", str(out / "frames")], check=True)
subprocess.run([cc, "-O1", "-g", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", str(path), "-o", str(out / "frames-asan")], check=True)
