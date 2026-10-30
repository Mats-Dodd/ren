/* wl.h: the workload registry (emitted-style C programs). */
#ifndef REN_WL_H
#define REN_WL_H
#include "../slice.h"
#include <stdio.h>

typedef struct wl_args {
  long n;          /* size; 0 = the workload's default */
  int measure;     /* 1: take timings (clock_gettime); 0 in replay */
  int workers;
} wl_args;

typedef struct wl_def {
  const char *name;
  void *(*init)(const wl_args *a);           /* returns cfg.user */
  ren_main_fn main;
  /* Print "result: ..." (deterministic, compared by replay) and
     "metric: ..." lines; return 0 if the run was correct. */
  int (*report)(void *user, FILE *result, FILE *metric, double wall_s);
  void (*fini)(void *user);
} wl_def;

const wl_def *wl_find(const char *name);
void wl_list(FILE *f);

/* shared helpers for workloads */
static inline uint64_t wl_fnv1a(const void *p, size_t n, uint64_t h) {
  const unsigned char *b = (const unsigned char *)p;
  for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ull; }
  return h;
}
#define WL_FNV_BASIS 0xcbf29ce484222325ull
uint64_t wl_now_ns(void);   /* CLOCK_MONOTONIC */
void wl_fail(const char *what) __attribute__((noreturn)); /* prints and aborts */

/* Await helper: the check every resume does. */
static inline int32_t wl_aw_state(ren_await *aw) { return ren_ld32(&aw->state, REN_MO_ACQUIRE); }

#endif
