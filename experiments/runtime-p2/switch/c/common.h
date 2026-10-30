// Shared by ren_single.c and raw.c: timing, medians, footprint, arguments.
#pragma once
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double tick_ns;
static void time_init(void) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}
static inline uint64_t now(void) { return mach_absolute_time(); }
static inline double ns_since(uint64_t t0) { return (double)(now() - t0) * tick_ns; }

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double median(double *v, int n) {
  qsort(v, n, sizeof *v, cmp_d);
  return n % 2 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2;
}

/* The process's physical footprint (what Activity Monitor shows). */
__attribute__((unused)) static uint64_t footprint(void) {
  task_vm_info_data_t vi;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) != KERN_SUCCESS) return 0;
  return vi.phys_footprint;
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
