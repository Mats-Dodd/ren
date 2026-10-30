/* fuzz.c: check one generated key set's lookups against a reference.
   Build: clang -O1 -DSET=x -DSETH='"gen/x.h"' -DHEX='"keys/x.hex"' fuzz.c
   argv[1] = number of random queries. Placements: (G) garbage after the
   string, random alignment; (K) start at 4080..4095 mod 4096 inside
   mapped memory; (P) ending exactly at a PROT_NONE page. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../bench/phrt.h"
#include SETH
#define CAT_(a, b) a##b
#define CAT(a, b) CAT_(a, b)
#define F(s) CAT(SET, s)

static char *K[4096]; static size_t KL[4096]; static int NK;
static int ref(const char *s, size_t n) {
  for (int i = 0; i < NK; i++) if (KL[i] == n && memcmp(K[i], s, n) == 0) return i;
  return -1;
}
static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static unsigned char alpha[256]; static int na;
static size_t maxl;

static long bad[8], checked;
static const char *fname[] = {"chain","lenswitch","ph_memcmp","ph_neon","ph_pad","ph_word"};
static void report(int f, char where, const char *s, size_t n, int got, int want) {
  if (bad[f]++ < 5) {
    fprintf(stderr, "  MISMATCH %s [%c] n=%zu got %d want %d: ", fname[f], where, n, got, want);
    for (size_t i = 0; i < n && i < 40; i++) fprintf(stderr, "%02x", (unsigned char)s[i]);
    fprintf(stderr, "\n");
  }
}
static char *gbuf, *guard_end, *k4;
static size_t pg;
static void check(const char *q, size_t n) {
  int want = ref(q, n);
  /* G: garbage after, random alignment, >= 16 readable bytes after */
  char *g = gbuf + 64 + (rnd() & 15);
  memcpy(g, q, n); for (int i = 0; i < 24; i++) g[n + i] = (char)rnd();
  g[-1] = (char)rnd();
  int r[6] = {F(_chain)(g, n), F(_lenswitch)(g, n), F(_ph_memcmp)(g, n), F(_ph_neon)(g, n), F(_ph_pad)(g, n), F(_ph_word)(g, n)};
  for (int f = 0; f < 6; f++) if (r[f] != want) report(f, 'G', q, n, r[f], want);
  /* K: start at 4080..4095 mod 4096, garbage after (mapped) */
  char *k = k4 + 4080 + (rnd() % 16);
  memcpy(k, q, n); for (int i = 0; i < 24; i++) k[n + i] = (char)rnd();
  int rk[4] = {F(_chain)(k, n), F(_lenswitch)(k, n), F(_ph_memcmp)(k, n), F(_ph_neon)(k, n)};
  for (int f = 0; f < 4; f++) if (rk[f] != want) report(f, 'K', q, n, rk[f], want);
  /* P: ending exactly at an unmapped page (n == 0 means the pointer is
     one past the end, as an empty slice at a buffer's end would be) */
  char *p = guard_end - n; memcpy(p, q, n);
  if (n >= 1 || getenv("EMPTY_AT_GUARD")) {
    int rp[4] = {F(_chain)(p, n), F(_lenswitch)(p, n), F(_ph_memcmp)(p, n), F(_ph_neon)(p, n)};
    for (int f = 0; f < 4; f++) if (rp[f] != want) report(f, 'P', q, n, rp[f], want);
  }
  checked++;
}
static size_t mutate(char *o, size_t cap) {
  int a = (int)(rnd() % NK); const char *k = K[a]; size_t n = KL[a];
  if (n + 8 > cap) n = cap - 8;
  memcpy(o, k, n);
  switch (rnd() % 10) {
  case 0: return n;                                                  /* exact */
  case 1: case 2: if (n) o[rnd() % n] = (char)rnd(); return n;          /* byte replaced, any value */
  case 3: if (n) o[rnd() % n] = (char)alpha[rnd() % na]; return n;      /* byte from the keys' alphabet */
  case 4: if (n) o[rnd() % n] ^= (char)(1 << (rnd() % 8)); return n;  /* bit flip */
  case 5: return n ? rnd() % n : 0;                                    /* prefix */
  case 6: { size_t e = 1 + rnd() % 3; for (size_t i = 0; i < e; i++) o[n + i] = (char)alpha[rnd() % na]; return n + e; }
  case 7: { if (!n) return 0; size_t at = rnd() % n; memmove(o + at, o + at + 1, n - at - 1); return n - 1; } /* delete */
  case 8: { size_t at = n ? rnd() % (n + 1) : 0; memmove(o + at + 1, o + at, n - at); o[at] = (char)alpha[rnd() % na]; return n + 1; }
  default: { int b = (int)(rnd() % NK); size_t h = n / 2; size_t m = KL[b] / 2; /* halves of two keys */
    size_t tail = KL[b] - m; if (h + tail > cap) tail = cap - h; memcpy(o + h, K[b] + m, tail); return h + tail; }
  }
}
int main(int argc, char **argv) {
  long N = argc > 1 ? atol(argv[1]) : 1000000;
  FILE *f = fopen(HEX, "r"); char line[2048];
  while (fgets(line, sizeof line, f)) {
    size_t l = strlen(line); while (l && (line[l-1] == '\n')) line[--l] = 0;
    if (!l) continue;
    if (!strcmp(line, ".")) { K[NK] = strdup(""); KL[NK++] = 0; continue; }
    K[NK] = malloc(l / 2 + 1); KL[NK] = l / 2;
    for (size_t i = 0; i < l / 2; i++) { unsigned x; sscanf(line + 2 * i, "%2x", &x); K[NK][i] = (char)x; }
    NK++;
  }
  fclose(f);
  int seen[256] = {0};
  for (int i = 0; i < NK; i++) { if (KL[i] > maxl) maxl = KL[i]; for (size_t j = 0; j < KL[i]; j++) seen[(unsigned char)K[i][j]] = 1; }
  for (int c = 0; c < 256; c++) if (seen[c]) alpha[na++] = (unsigned char)c;
  if (!na) alpha[na++] = 'a';
  pg = (size_t)getpagesize();
  gbuf = malloc(1 << 16);
  char *m = mmap(NULL, 3 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
  mprotect(m + 2 * pg, pg, PROT_NONE);
  guard_end = m + 2 * pg; k4 = m;  /* k4 + 4080 + 16 + n stays inside the first 2 pages */
  for (size_t i = 0; i < 2 * pg; i++) m[i] = (char)rnd();
  /* every key, at every placement */
  for (int i = 0; i < NK; i++) check(K[i], KL[i]);
  char q[1024];
  for (long i = 0; i < N; i++) {
    size_t n;
    if (rnd() % 10 == 0) { n = rnd() % (maxl + 3); if (n > 600) n = 600; for (size_t j = 0; j < n; j++) q[j] = (char)(rnd() % 4 == 0 ? rnd() : alpha[rnd() % na]); }
    else n = mutate(q, sizeof q);
    check(q, n);
  }
  printf("%s: %d keys, phash=%d, %ld queries checked x placements;", CAT_STR, NK, F(_PHASH), checked);
  long tot = 0; for (int f = 0; f < 6; f++) { printf(" %s=%ld", fname[f], bad[f]); tot += bad[f]; }
  printf(" -> %s\n", tot ? "FAIL" : "ok");
  return tot != 0;
}
