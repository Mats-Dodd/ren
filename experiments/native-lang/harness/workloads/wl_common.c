/* wl_common.c: registry and helpers shared by the workloads. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "wl.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef WL_ONLY
/* E1 unity builds: one workload in the translation unit. */
extern const wl_def WL_ONLY;
static const wl_def *const all[] = {&WL_ONLY};
#else
extern const wl_def wl_w1, wl_w2, wl_w3, wl_t_timer, wl_t_pipe, wl_t_tcp,
    wl_t_cancel, wl_t_block, wl_w_fuzz;
static const wl_def *const all[] = {&wl_w1, &wl_w2, &wl_w3, &wl_t_timer, &wl_t_pipe,
                                    &wl_t_tcp, &wl_t_cancel, &wl_t_block, &wl_w_fuzz};
#endif

const wl_def *wl_find(const char *name) {
  for (size_t i = 0; i < sizeof all / sizeof *all; i++)
    if (strcmp(all[i]->name, name) == 0) return all[i];
  return NULL;
}
void wl_list(FILE *f) {
  for (size_t i = 0; i < sizeof all / sizeof *all; i++) fprintf(f, " %s", all[i]->name);
  fputc('\n', f);
}
uint64_t wl_now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
void wl_fail(const char *what) {
  fprintf(stderr, "workload check failed: %s\n", what);
  fflush(stderr);
  abort();
}
