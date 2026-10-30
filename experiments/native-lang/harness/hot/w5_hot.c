/* w5_hot.c: W5, the hot path called from emitted-style C (SPEC §E).
   Built with -DHOT_INLINE (variant i: slice.h's static inlines) or
   without (variants ii-vi: ren_hot_* from another unit or language).
   w5 dup N        N dup/drop pairs on an owned object (rc > 0)
   w5 dupshared N  N dup/drop pairs on a shared object (rc < 0, atomic)
   w5 push N       N pushes into arrays of 1024 grown from 0 */
#include "../slice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef HOT_INLINE
#define DUP(o) ren_dup(o)
#define DROP(o) ren_drop(o)
#define PUSH(a, v) ren_array_push(a, v)
#define VARIANT "inline"
#else
#define DUP(o) ren_hot_dup(o)
#define DROP(o) ren_hot_drop(o)
#define PUSH(a, v) ren_hot_array_push(a, v)
#ifndef VARIANT
#define VARIANT "extern"
#endif
#endif

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: w5 dup|dupshared|push N\n"); return 2; }
  long n = atol(argv[2]);
  double t0, t1;
  long check = 0;
  if (!strcmp(argv[1], "dup") || !strcmp(argv[1], "dupshared")) {
    ren_obj *o = calloc(1, sizeof(ren_obj));
    o->tag = REN_TAG_PLAIN;
    o->rc = !strcmp(argv[1], "dup") ? 1 : -1;
    t0 = now();
    for (long i = 0; i < n; i++) {
      DUP(o);
      __asm__ volatile("" ::"r"(o) : "memory");
      DROP(o);
    }
    t1 = now();
    check = o->rc;
    DROP(o); /* the last reference: frees */
    if (check != 1 && check != -1) { fprintf(stderr, "w5: rc ended at %ld\n", check); return 1; }
  } else if (!strcmp(argv[1], "push")) {
    long per = 1024, arrays = n / per;
    t0 = now();
    for (long k = 0; k < arrays; k++) {
      ren_array *a = calloc(1, sizeof(ren_array));
      a->obj.rc = 1; a->obj.tag = REN_TAG_ARRAY;
      for (long i = 0; i < per; i++) PUSH(a, i);
      __asm__ volatile("" ::"r"(a) : "memory");
      check += a->data[per - 1] + a->len;
      DROP(&a->obj);
    }
    t1 = now();
    if (check != arrays * (per - 1 + per)) { fprintf(stderr, "w5: push check failed\n"); return 1; }
  } else {
    fprintf(stderr, "w5: unknown mode\n");
    return 2;
  }
  printf("metric: w5 variant=%s mode=%s n=%ld s=%.6f ns_per_op=%.3f\n", VARIANT, argv[1], n, t1 - t0,
         (t1 - t0) * 1e9 / (double)n);
  return 0;
}
