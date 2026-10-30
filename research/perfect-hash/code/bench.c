/* bench.c: one key set (SET), one lookup form (argv[1]), argv[2] passes
   over the queries in SET.q. Prints the checksum and, on stderr, its own
   ns per lookup (min of passes). Build:
   clang -O2 -DSET=methods -DSETH='"gen/methods.h"' -DSETG='"gen/methods_gperf.c"' */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include "phrt.h"
#include SETH
#include SETG

#define CAT_(a, b) a##b
#define CAT(a, b) CAT_(a, b)
#define F(suffix) CAT(SET, suffix)

/* a general hash map: open addressing, FNV-1a 64, linear probing, keys
   compared by length and memcmp: what a Table<Str, Int> would do */
typedef struct { const char *k; size_t n; int v; } slot;
static slot hm[256];
static inline uint64_t fnv(const char *s, size_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < n; i++) h = (h ^ (uint8_t)s[i]) * 1099511628211ULL;
  return h;
}
static void hm_init(void) {
  for (int i = 0; i < F(_N); i++) {
    const char *k = F(_keys)[i]; size_t n = strlen(k);
    uint64_t h = fnv(k, n) & 255;
    while (hm[h].k) h = (h + 1) & 255;
    hm[h] = (slot){k, n, i};
  }
}
static inline int hm_find(const char *s, size_t n) {
  uint64_t h = fnv(s, n) & 255;
  for (;;) {
    if (!hm[h].k) return -1;
    if (hm[h].n == n && memcmp(hm[h].k, s, n) == 0) return hm[h].v;
    h = (h + 1) & 255;
  }
}
static inline int gp_find(const char *s, size_t n) {
  const struct CAT(SET, _g) *r = F(_gperf_find)(s, (unsigned)n);
  return r ? r->idx : -1;
}
static inline int null_find(const char *s, size_t n) { (void)s; return (int)n; }

typedef struct { const char *p; size_t n; } q_t;

static double now(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e9 + t.tv_nsec;
}

#define LOOP(fn) \
  for (int r = 0; r < reps; r++) { \
    double t0 = now(); int64_t s = 0; \
    for (size_t i = 0; i < nq; i++) s += fn(q[i].p, q[i].n); \
    double t = now() - t0; if (t < best) best = t; sum += s; }

int main(int argc, char **argv) {
  const char *v = argv[1]; int reps = atoi(argv[2]);
  char path[256]; snprintf(path, sizeof path, "gen/%s.q", CAT_STR);
  FILE *f = fopen(path, "r"); if (!f) { perror(path); return 1; }
  /* each query in its own 8-aligned spot, as a Str's bytes are, after a
     32-byte header; no padding promised past its end */
  static char arena[65536 * 64]; static q_t q[65536];
  size_t nq = 0, at = 0; char line[256];
  while (fgets(line, sizeof line, f) && nq < 65536) {
    size_t n = strlen(line); if (n && line[n - 1] == '\n') line[--n] = 0;
    at += 32; memcpy(arena + at, line, n); q[nq].p = arena + at; q[nq].n = n; nq++;
    at = (at + n + 7) & ~(size_t)7;
  }
  fclose(f);
  hm_init();
  /* every form must agree with the chain */
  for (size_t i = 0; i < nq; i++) {
    int a = F(_chain)(q[i].p, q[i].n);
    int b[] = {F(_lenswitch)(q[i].p, q[i].n), F(_ph_memcmp)(q[i].p, q[i].n), F(_ph_neon)(q[i].p, q[i].n),
               F(_ph_pad)(q[i].p, q[i].n), F(_ph_word)(q[i].p, q[i].n), hm_find(q[i].p, q[i].n), gp_find(q[i].p, q[i].n)};
    for (int j = 0; j < 7; j++) if (b[j] != a) { fprintf(stderr, "mismatch form %d on %.*s: %d vs %d\n", j, (int)q[i].n, q[i].p, b[j], a); return 1; }
  }
  double best = 1e30; int64_t sum = 0;
  if (!strcmp(v, "null")) { LOOP(null_find) }
  else if (!strcmp(v, "chain")) { LOOP(F(_chain)) }
  else if (!strcmp(v, "lenswitch")) { LOOP(F(_lenswitch)) }
  else if (!strcmp(v, "ph_memcmp")) { LOOP(F(_ph_memcmp)) }
  else if (!strcmp(v, "ph_neon")) { LOOP(F(_ph_neon)) }
  else if (!strcmp(v, "ph_pad")) { LOOP(F(_ph_pad)) }
  else if (!strcmp(v, "ph_word")) { LOOP(F(_ph_word)) }
  else if (!strcmp(v, "hmap")) { LOOP(hm_find) }
  else if (!strcmp(v, "gperf")) { LOOP(gp_find) }
  else { fprintf(stderr, "unknown form %s\n", v); return 1; }
  printf("%lld\n", (long long)sum);
  fprintf(stderr, "%s %s %.3f ns/lookup (min of %d passes)\n", CAT_STR, v, best / nq, reps);
  return 0;
}
