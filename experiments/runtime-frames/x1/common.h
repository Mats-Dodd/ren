// Shared by ren_single.c and raw.c: timing, medians, footprint, arguments.
#pragma once
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#else
#include <time.h>
#include <unistd.h>
#endif
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double tick_ns;
#ifdef __APPLE__
static void time_init(void) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}
static inline uint64_t now(void) { return mach_absolute_time(); }
#else
/* Linux: CLOCK_MONOTONIC through the vDSO (TSC-backed here), in ns. No QoS
   class to set; the process runs at the default nice level, unpinned. */
static void time_init(void) { tick_ns = 1.0; }
static inline uint64_t now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}
#endif
static inline double ns_since(uint64_t t0) { return (double)(now() - t0) * tick_ns; }

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double median(double *v, int n) {
  qsort(v, n, sizeof *v, cmp_d);
  return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

#ifdef __APPLE__
/* The process's physical footprint (what Activity Monitor shows). */
__attribute__((unused)) static uint64_t footprint(void) {
  task_vm_info_data_t vi;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) != KERN_SUCCESS) return 0;
  return vi.phys_footprint;
}
#else
/* Linux: the resident set (second field of /proc/self/statm, in pages).
   Not the same measure as macOS phys_footprint: RSS counts resident file and
   shared pages too, but the park benchmark only uses differences. */
__attribute__((unused)) static uint64_t footprint(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return 0;
  unsigned long size = 0, res = 0;
  int got = fscanf(f, "%lu %lu", &size, &res);
  fclose(f);
  return got == 2 ? (uint64_t)res * (uint64_t)sysconf(_SC_PAGESIZE) : 0;
}
#endif

/* Every rep's ns_per_op in run order ("a,b,c"), and their max, for the
   cloud script's spread check. Call before median(), which sorts in place. */
static double reps_list(const double *v, int n, char *buf, size_t cap) {
  double mx = v[0];
  size_t o = 0;
  buf[0] = 0;
  for (int i = 0; i < n; i++) {
    mx = v[i] > mx ? v[i] : mx;
    if (o < cap) o += (size_t)snprintf(buf + o, cap - o, "%s%.2f", i ? "," : "", v[i]);
  }
  return mx;
}

typedef struct {
  const char *bench;
  uint64_t n;   /* round trips, spawns, parked tasks, or fan-out tasks */
  uint64_t max; /* scope limit (spawn_batch) */
  int reps;
  bool check;
} args_t;

static args_t parse_args(int argc, char **argv, uint64_t default_n) {
  args_t a = {.bench = "pingpong", .n = default_n, .max = 64, .reps = 7, .check = false};
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--bench") && i + 1 < argc) a.bench = argv[++i];
    else if (!strcmp(argv[i], "--n") && i + 1 < argc) a.n = strtoull(argv[++i], 0, 10);
    else if (!strcmp(argv[i], "--max") && i + 1 < argc) a.max = strtoull(argv[++i], 0, 10);
    else if (!strcmp(argv[i], "--reps") && i + 1 < argc) a.reps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--check")) a.check = true;
    else {
      fprintf(stderr,
              "usage: %s --bench pingpong|pingpong_nested|spawn_join|spawn_batch|park|fanout|fanout_yield"
              " [--n N] [--max M] [--reps R] [--check]\n",
              argv[0]);
      exit(2);
    }
  }
  if (a.reps < 1 || a.reps > 64) a.reps = 7;
  return a;
}
