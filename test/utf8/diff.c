/* The validator's differential test (compiler.md, "Bytes stage, part
   two", "The validator"): research/strings/track-b's agreement test
   (VERIFY.md; c/b5.c's 2M random and mutated inputs, and verify/c/
   b5big.c's 1 MiB texts and the sweep of sequences around 64-byte block
   edges), of the runtime's `ren_utf8_check` (the NEON block validator
   where the target has NEON, the scalar path otherwise) and its scalar
   path, against a plain reference written here, which decodes each code
   point in full. They must agree on whether the bytes are UTF-8, on
   `at` and on `incomplete`.

     diff            checks; prints how many inputs, and how many invalid
     diff stream     the same, and writes each input with the runtime's
                     answer to stdout, for check.ml to hold against
                     OCaml's decoder and the interpreter's built-ins
     diff bench K N  GB/s of `ren_utf8_check` and of the byte loop it
                     replaced, on a text of kind K (ascii, cjk, mixed)
                     of N bytes, b5.c's bench
     diff dump K N F that text, written to the file F, for a twin

   It's linked with ren_rt.c itself (test/utf8/dune), and cross-compiled
   for aarch64 and run under qemu by neon.sh, so the NEON path is checked
   where it can't run natively. */
#include "ren_rt.h"
#include <time.h>

/* ---- the reference: a code point at a time ---- */

/* The length of the character at [p + i] if it's one, else 0: its bits
   gathered and then held against the ranges, not the runtime's tables
   of second bytes. */
static int ref_char(const unsigned char *p, int64_t i, int64_t n) {
  unsigned c = p[i];
  int len;
  uint32_t cp, min;
  if (c < 0x80)
    return 1;
  if ((c & 0xe0) == 0xc0)
    len = 2, cp = c & 0x1f, min = 0x80;
  else if ((c & 0xf0) == 0xe0)
    len = 3, cp = c & 0x0f, min = 0x800;
  else if ((c & 0xf8) == 0xf0)
    len = 4, cp = c & 0x07, min = 0x10000;
  else
    return 0;
  if (i + len > n)
    return 0;
  for (int k = 1; k < len; k++) {
    if ((p[i + k] & 0xc0) != 0x80)
      return 0;
    cp = cp << 6 | (p[i + k] & 0x3f);
  }
  if (cp < min || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff))
    return 0;
  return len;
}

/* Every proper prefix of every scalar value's encoding, found by
   encoding them all: 1, 2 or 3 bytes, by length and bytes. */
static uint8_t prefix1[256], prefix2[65536], prefix3[1 << 21];

static int encode(unsigned char *o, uint32_t c) {
  if (c < 0x80)
    return o[0] = (unsigned char)c, 1;
  if (c < 0x800)
    return o[0] = (unsigned char)(0xc0 | c >> 6), o[1] = (unsigned char)(0x80 | (c & 63)), 2;
  if (c < 0x10000)
    return o[0] = (unsigned char)(0xe0 | c >> 12),
           o[1] = (unsigned char)(0x80 | ((c >> 6) & 63)),
           o[2] = (unsigned char)(0x80 | (c & 63)), 3;
  o[0] = (unsigned char)(0xf0 | c >> 18);
  o[1] = (unsigned char)(0x80 | ((c >> 12) & 63));
  o[2] = (unsigned char)(0x80 | ((c >> 6) & 63));
  o[3] = (unsigned char)(0x80 | (c & 63));
  return 4;
}

static void prefixes(void) {
  for (uint32_t c = 0; c <= 0x10ffff; c++) {
    if (c >= 0xd800 && c <= 0xdfff)
      continue;
    unsigned char e[4];
    int len = encode(e, c);
    if (len > 1)
      prefix1[e[0]] = 1;
    if (len > 2)
      prefix2[e[0] << 8 | e[1]] = 1;
    if (len > 3) {
      uint32_t k = (uint32_t)e[0] << 16 | (uint32_t)e[1] << 8 | e[2];
      prefix3[k >> 3] |= (uint8_t)(1 << (k & 7));
    }
  }
}

static bool proper_prefix(const unsigned char *t, int64_t m) {
  if (m == 1)
    return prefix1[t[0]];
  if (m == 2)
    return prefix2[t[0] << 8 | t[1]];
  if (m == 3) {
    uint32_t k = (uint32_t)t[0] << 16 | (uint32_t)t[1] << 8 | t[2];
    return prefix3[k >> 3] >> (k & 7) & 1;
  }
  return false;
}

static int64_t ref_check(const unsigned char *p, int64_t n, bool *incomplete) {
  *incomplete = false;
  for (int64_t i = 0; i < n;) {
    int k = ref_char(p, i, n);
    if (k == 0) {
      *incomplete = proper_prefix(p + i, n - i);
      return i;
    }
    i += k;
  }
  return -1;
}

/* ---- the byte loop the block validator replaced: ren_rt.c's
   `ren_utf8_valid` at 9ec5fb9, for `bench` only ---- */
__attribute__((noinline)) static bool before(const unsigned char *p, int64_t n) {
  int64_t i = 0;
  while (i < n) {
    unsigned c = p[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    int more;
    unsigned lo = 0x80, hi = 0xbf;
    if (c >= 0xc2 && c <= 0xdf)
      more = 1;
    else if (c >= 0xe0 && c <= 0xef) {
      more = 2;
      if (c == 0xe0)
        lo = 0xa0;
      else if (c == 0xed)
        hi = 0x9f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      more = 3;
      if (c == 0xf0)
        lo = 0x90;
      else if (c == 0xf4)
        hi = 0x8f;
    } else
      return false;
    if (n - i <= more)
      return false;
    if (p[i + 1] < lo || p[i + 1] > hi)
      return false;
    for (int k = 2; k <= more; k++)
      if ((p[i + k] & 0xc0) != 0x80)
        return false;
    i += more + 1;
  }
  return true;
}

/* ---- the inputs: b5.c's, the same generator and seed ---- */
static uint64_t rs = 42;
static uint64_t rnd(void) {
  uint64_t z = (rs += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}

static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) {
    fputs("out of memory\n", stderr);
    exit(2);
  }
  return p;
}

/* a text of [kind], [n] bytes, ending on a character */
static unsigned char *text(const char *kind, int64_t n) {
  unsigned char *o = xmalloc((size_t)n + 8);
  int64_t i = 0;
  while (i < n - 4) {
    uint32_t c, r = (uint32_t)(rnd() % 100);
    if (r == 99 && (rnd() & 1))
      c = '\n';
    else if (!strcmp(kind, "ascii"))
      c = r < 15 ? ' ' : 'a' + rnd() % 26;
    else if (!strcmp(kind, "latin"))
      c = r < 15 ? ' ' : r < 23 ? 0xe0 + rnd() % 32 : 'a' + rnd() % 26;
    else if (!strcmp(kind, "cjk"))
      c = r < 10 ? ' ' : 0x4e00 + rnd() % 20000;
    else if (!strcmp(kind, "emoji"))
      c = r < 50 ? 'a' + rnd() % 26 : 0x1f300 + rnd() % 700;
    else
      c = r < 98 ? (r < 15 ? ' ' : 'a' + rnd() % 26) : r < 99 ? 0xe9 : 0x65e5;
    i += encode(o + i, c);
  }
  while (i < n)
    o[i++] = ' ';
  return o;
}

/* ---- checking one input ---- */
static int64_t inputs, invalid, bad;
static bool streaming;

static void put(const void *p, size_t n) {
  if (fwrite(p, 1, n, stdout) != n) {
    fputs("diff: can't write the stream\n", stderr);
    exit(2);
  }
}

static void check(const unsigned char *p, int64_t n) {
  bool ri, ci, si;
  int64_t r = ref_check(p, n, &ri);
  int64_t c = ren_utf8_check((const char *)p, n, &ci);
  int64_t s = ren_utf8_check_scalar((const char *)p, n, &si);
  inputs++;
  invalid += r >= 0;
  if (c != r || s != r || (r >= 0 && (ci != ri || si != ri))) {
    bad++;
    if (bad <= 5) {
      fprintf(stderr,
              "disagree: reference %lld %d, ren_utf8_check %lld %d, scalar %lld %d, n=%lld:",
              (long long)r, ri, (long long)c, ci, (long long)s, si, (long long)n);
      for (int64_t i = 0; i < n && i < 300; i++)
        fprintf(stderr, " %02x", p[i]);
      fputc('\n', stderr);
    }
  }
  if (streaming) {
    /* the input, then the runtime's answer: `at` or -1, `incomplete`,
       and how long `from_utf8_lossy` made it */
    ren_obj *b = ren_str_of((const char *)p, n);
    ren_obj *l = ren_utf8_lossy(b);
    int64_t head[3] = {n, c, ren_str_len(l)};
    ren_drop(l);
    ren_drop(b);
    unsigned char inc = ci;
    put(head, sizeof head);
    put(&inc, 1);
    put(p, (size_t)n);
  }
}

/* b5.c's test: 2M texts of 1 to 200 bytes, of each kind in turn, with up
   to two bytes changed to a random one, a continuation, a lead, or one
   of the bytes the tables single out */
static void random_inputs(void) {
  const char *kinds[] = {"ascii", "latin", "cjk", "emoji", "mixed"};
  for (int t = 0; t < 2000000; t++) {
    int64_t n = 1 + (int64_t)(rnd() % 200);
    unsigned char *p = text(kinds[t % 5], n + 8);
    int muts = (int)(rnd() % 3);
    for (int m = 0; m < muts; m++) {
      int64_t at = (int64_t)(rnd() % (uint64_t)n);
      uint64_t r = rnd() % 4;
      static const unsigned char special[] = {0xed, 0xf4, 0xe0, 0xf0, 0xc0, 0xc1, 0xf5, 0xff};
      p[at] = r == 0   ? (unsigned char)rnd()
              : r == 1 ? (unsigned char)(0x80 + rnd() % 64)
              : r == 2 ? (unsigned char)(0xc0 + rnd() % 64)
                       : special[rnd() % 8];
    }
    check(p, n);
    free(p);
  }
}

/* b5big.c's long inputs: prefixes of 1 MiB texts of each kind, one byte
   in two of three changed to a random one; [per] of them a kind (b5big.c
   ran 3,000) */
static void long_inputs(int per) {
  const char *kinds[] = {"ascii", "latin", "cjk", "emoji", "mixed"};
  for (int k = 0; k < 5; k++) {
    unsigned char *p = text(kinds[k], 1 << 20);
    for (int t = 0; t < per; t++) {
      int64_t n = 1 + (int64_t)(rnd() % (1 << 20));
      int64_t at = (int64_t)(rnd() % (uint64_t)n);
      unsigned char save = p[at];
      if (t % 3)
        p[at] = (unsigned char)rnd();
      check(p, n);
      p[at] = save;
    }
    free(p);
  }
}

/* b5big.c's sweep: an ASCII run of 0 to 299 bytes, so every offset mod
   64, then each prefix of a 2-, 3- and 4-byte character, a surrogate,
   an overlong and one past U+10FFFF, then 0 to 63 bytes of ASCII; and
   the same after a run of 3-byte characters, so that a block's edge
   cuts a valid character too */
static void edges(void) {
  unsigned char buf[512];
  static const unsigned char seqs[][4] = {{0xc3, 0xa9}, {0xe6, 0x97, 0xa5}, {0xf0, 0x9f, 0x98, 0x80},
                                          {0xed, 0xa0, 0x80}, {0xc0, 0x80}, {0xf4, 0x90, 0x80, 0x80}};
  static const int sl[] = {2, 3, 4, 3, 2, 4};
  for (int wide = 0; wide < 2; wide++)
    for (int L = 0; L < 300; L++)
      for (int s = 0; s < 6; s++)
        for (int cut = 1; cut <= sl[s]; cut++)
          for (int tail = 0; tail < 70; tail += 7) {
            memset(buf, 'a', sizeof buf);
            if (wide)
              for (int i = 0; i + 3 <= L; i += 3)
                memcpy(buf + i, "\xe6\x97\xa5", 3);
            memcpy(buf + L, seqs[s], (size_t)cut);
            check(buf, L + cut + tail);
          }
}

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

/* b5.c's bench: [size] bytes of [kind], validated until 256 MiB are */
static void bench(const char *kind, int64_t size) {
  unsigned char *p = text(kind, size);
  int64_t reps = (int64_t)(256LL << 20) / size, ok = 0;
  bool inc;
  double t0 = now();
  for (int64_t r = 0; r < reps; r++)
    ok += ren_utf8_check((const char *)p, size, &inc) < 0;
  double t1 = now();
  for (int64_t r = 0; r < reps; r++)
    ok += before(p, size);
  double t2 = now();
  printf("%s %lld bytes: ren_utf8_check %.3f GB/s, before %.3f GB/s (ok %lld)\n", kind,
         (long long)size, (double)size * reps / (t1 - t0) * 1e-9,
         (double)size * reps / (t2 - t1) * 1e-9, (long long)ok);
}

int main(int argc, char **argv) {
  if (argc >= 4 && !strcmp(argv[1], "bench")) {
    bench(argv[2], atoll(argv[3]));
    return 0;
  }
  if (argc >= 5 && !strcmp(argv[1], "dump")) {
    unsigned char *p = text(argv[2], atoll(argv[3]));
    FILE *f = fopen(argv[4], "wb");
    if (!f || fwrite(p, 1, (size_t)atoll(argv[3]), f) != (size_t)atoll(argv[3]))
      return 2;
    fclose(f);
    return 0;
  }
  streaming = argc >= 2 && !strcmp(argv[1], "stream");
  int per = argc >= 3 ? atoi(argv[2]) : 100;
  prefixes();
  random_inputs();
  edges();
  long_inputs(per);
  if (streaming) {
    int64_t end = -1;
    put(&end, sizeof end);
    fflush(stdout);
  }
  fprintf(stderr, "%s: %lld inputs, %lld invalid, %lld disagreements\n",
#if defined(__ARM_NEON) && !defined(__TINYC__)
          "neon",
#else
          "scalar",
#endif
          (long long)inputs, (long long)invalid, (long long)bad);
  return bad != 0;
}
