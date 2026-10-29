/* B5: UTF-8 validation, what `Str.from_utf8` costs.
     b5 test                     the validators agree, on 2M random and
                                 mutated inputs
     b5 bench <kind> <size> <v>  validate a [size]-byte text of [kind]
                                 (ascii, latin, cjk, emoji, mixed),
                                 repeated to 256 MiB of work; prints GB/s
     b5 rpr <file> <v>           read-parse-respond: read [file], make it
                                 a Str (validate), split lines and fields,
                                 build a response line for each, write it
   v: none, ren (ren_rt.c's ren_utf8_valid as it is at cf7787c), ascii
   (the same with an 8-bytes-at-a-time ASCII skip), neon (Keiser and
   Lemire's lookup algorithm, "Validating UTF-8 In Less Than One
   Instruction Per Byte", SPE 2021, as simdjson/simdutf implement it,
   written here in NEON intrinsics). */
#include "rt.h"
#include <arm_neon.h>

/* ---- ren: ren_rt.c's, verbatim but for the signature ---- */
__attribute__((noinline)) static bool v_ren(const unsigned char *p, int64_t n) {
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

/* ---- ascii: the same, skipping 16 ASCII bytes at a time ---- */
__attribute__((noinline)) static bool v_ascii(const unsigned char *p, int64_t n) {
  int64_t i = 0;
  while (i < n) {
    if (i + 16 <= n && ((rd8(p + i) | rd8(p + i + 8)) & 0x8080808080808080ULL) == 0) {
      i += 16;
      continue;
    }
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

/* ---- neon: the lookup algorithm ---- */
#define TOO_SHORT (1 << 0)
#define TOO_LONG (1 << 1)
#define OVERLONG_3 (1 << 2)
#define TOO_LARGE (1 << 3)
#define SURROGATE (1 << 4)
#define OVERLONG_2 (1 << 5)
#define TOO_LARGE_1000 (1 << 6)
#define OVERLONG_4 (1 << 6)
#define TWO_CONTS (1 << 7)
#define CARRY (TOO_SHORT | TOO_LONG | TWO_CONTS)

static const uint8_t T1H[16] = {
    TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
    TWO_CONTS, TWO_CONTS, TWO_CONTS, TWO_CONTS, TOO_SHORT | OVERLONG_2, TOO_SHORT,
    TOO_SHORT | OVERLONG_3 | SURROGATE,
    TOO_SHORT | TOO_LARGE | TOO_LARGE_1000 | OVERLONG_4};
static const uint8_t T1L[16] = {
    CARRY | OVERLONG_3 | OVERLONG_2 | OVERLONG_4, CARRY | OVERLONG_2, CARRY, CARRY,
    CARRY | TOO_LARGE, CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000, CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000, CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000, CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000 | SURROGATE,
    CARRY | TOO_LARGE | TOO_LARGE_1000, CARRY | TOO_LARGE | TOO_LARGE_1000};
static const uint8_t T2H[16] = {
    TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE_1000 | OVERLONG_4,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
    TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT};
static const uint8_t MAXV[16] = {255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
                                 255, 255, 255, 0xf0 - 1, 0xe0 - 1, 0xc0 - 1};

typedef struct {
  uint8x16_t err, prev, prev_incomplete;
  uint8x16_t t1h, t1l, t2h, maxv;
} nstate;

INLINE void n_step(nstate *s, uint8x16_t in) {
  uint8x16_t prev1 = vextq_u8(s->prev, in, 15);
  uint8x16_t b1h = vqtbl1q_u8(s->t1h, vshrq_n_u8(prev1, 4));
  uint8x16_t b1l = vqtbl1q_u8(s->t1l, vandq_u8(prev1, vdupq_n_u8(0x0f)));
  uint8x16_t b2h = vqtbl1q_u8(s->t2h, vshrq_n_u8(in, 4));
  uint8x16_t sc = vandq_u8(vandq_u8(b1h, b1l), b2h);
  uint8x16_t prev2 = vextq_u8(s->prev, in, 14);
  uint8x16_t prev3 = vextq_u8(s->prev, in, 13);
  uint8x16_t third = vqsubq_u8(prev2, vdupq_n_u8(0xe0 - 0x80));
  uint8x16_t fourth = vqsubq_u8(prev3, vdupq_n_u8(0xf0 - 0x80));
  uint8x16_t must23 = vandq_u8(vorrq_u8(third, fourth), vdupq_n_u8(0x80));
  s->err = vorrq_u8(s->err, veorq_u8(must23, sc));
  s->prev = in;
}
INLINE void n_block(nstate *s, const unsigned char *p) {
  uint8x16_t a = vld1q_u8(p), b = vld1q_u8(p + 16), c = vld1q_u8(p + 32),
             d = vld1q_u8(p + 48);
  uint8x16_t any = vorrq_u8(vorrq_u8(a, b), vorrq_u8(c, d));
  if (vmaxvq_u8(any) < 0x80) {
    /* all ASCII: only a sequence the last block left open is an error */
    s->err = vorrq_u8(s->err, s->prev_incomplete);
    s->prev = d;
    s->prev_incomplete = vdupq_n_u8(0);
    return;
  }
  n_step(s, a);
  n_step(s, b);
  n_step(s, c);
  n_step(s, d);
  s->prev_incomplete = vqsubq_u8(d, s->maxv);
}
__attribute__((noinline)) static bool v_neon(const unsigned char *p, int64_t n) {
  nstate s;
  s.err = s.prev = s.prev_incomplete = vdupq_n_u8(0);
  s.t1h = vld1q_u8(T1H);
  s.t1l = vld1q_u8(T1L);
  s.t2h = vld1q_u8(T2H);
  s.maxv = vld1q_u8(MAXV);
  int64_t i = 0;
  for (; i + 64 <= n; i += 64)
    n_block(&s, p + i);
  if (i < n) {
    unsigned char tail[64];
    memset(tail, 0, 64);
    memcpy(tail, p + i, (size_t)(n - i));
    n_block(&s, tail);
  }
  s.err = vorrq_u8(s.err, s.prev_incomplete);
  return vmaxvq_u8(s.err) == 0;
}

static bool (*pick(const char *v))(const unsigned char *, int64_t) {
  if (!strcmp(v, "ren"))
    return v_ren;
  if (!strcmp(v, "ascii"))
    return v_ascii;
  if (!strcmp(v, "neon"))
    return v_neon;
  return NULL;
}

/* ---- inputs ---- */
static uint64_t rs = 42;
static uint64_t rnd(void) {
  uint64_t z = (rs += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}
static int put_cp(unsigned char *o, uint32_t c) {
  if (c < 0x80) {
    o[0] = (unsigned char)c;
    return 1;
  }
  if (c < 0x800) {
    o[0] = (unsigned char)(0xc0 | c >> 6);
    o[1] = (unsigned char)(0x80 | (c & 63));
    return 2;
  }
  if (c < 0x10000) {
    o[0] = (unsigned char)(0xe0 | c >> 12);
    o[1] = (unsigned char)(0x80 | ((c >> 6) & 63));
    o[2] = (unsigned char)(0x80 | (c & 63));
    return 3;
  }
  o[0] = (unsigned char)(0xf0 | c >> 18);
  o[1] = (unsigned char)(0x80 | ((c >> 12) & 63));
  o[2] = (unsigned char)(0x80 | ((c >> 6) & 63));
  o[3] = (unsigned char)(0x80 | (c & 63));
  return 4;
}
/* a text of [kind], [n] bytes, ending on a character */
static unsigned char *text(const char *kind, int64_t n) {
  unsigned char *o = xmalloc((size_t)n + 8);
  int64_t i = 0;
  while (i < n - 4) {
    uint32_t c, r = (uint32_t)(rnd() % 100);
    if (r == 99 && (rnd() & 1)) /* lines of about 200 characters */
      c = '\n';
    else if (!strcmp(kind, "ascii"))
      c = r < 15 ? ' ' : 'a' + rnd() % 26;
    else if (!strcmp(kind, "latin")) /* French/German-like: 1 in 12 accented */
      c = r < 15 ? ' ' : r < 23 ? 0xe0 + rnd() % 32 : 'a' + rnd() % 26;
    else if (!strcmp(kind, "cjk"))
      c = r < 10 ? ' ' : 0x4e00 + rnd() % 20000;
    else if (!strcmp(kind, "emoji"))
      c = r < 50 ? 'a' + rnd() % 26 : 0x1f300 + rnd() % 700;
    else /* mixed: mostly ASCII, 2% non-ASCII, as logs with names */
      c = r < 98 ? (r < 15 ? ' ' : 'a' + rnd() % 26) : r < 99 ? 0xe9 : 0x65e5;
    i += put_cp(o + i, c);
  }
  while (i < n)
    o[i++] = ' ';
  return o;
}

static int test(void) {
  int64_t bad = 0, invalid = 0;
  const char *kinds[] = {"ascii", "latin", "cjk", "emoji", "mixed"};
  for (int t = 0; t < 2000000; t++) {
    int64_t n = 1 + (int64_t)(rnd() % 200);
    unsigned char *p = text(kinds[t % 5], n + 8);
    int muts = (int)(rnd() % 3);
    for (int m = 0; m < muts; m++) {
      int64_t at = (int64_t)(rnd() % (uint64_t)n);
      uint64_t r = rnd() % 4;
      p[at] = r == 0 ? (unsigned char)rnd() : r == 1 ? 0x80 + rnd() % 64
              : r == 2 ? 0xc0 + rnd() % 64 : (unsigned char[]){0xed, 0xf4, 0xe0, 0xf0, 0xc0, 0xc1, 0xf5, 0xff}[rnd() % 8];
    }
    bool a = v_ren(p, n), b = v_ascii(p, n), c = v_neon(p, n);
    invalid += !a;
    if (a != b || a != c) {
      bad++;
      if (bad < 5) {
        fprintf(stderr, "disagree ren=%d ascii=%d neon=%d n=%lld:", a, b, c, (long long)n);
        for (int64_t i = 0; i < n; i++)
          fprintf(stderr, " %02x", p[i]);
        fputc('\n', stderr);
      }
    }
    free(p);
  }
  printf("test: %lld disagreements, %lld of 2000000 inputs invalid\n", (long long)bad,
         (long long)invalid);
  return bad != 0;
}

static void bench(const char *kind, int64_t size, const char *v) {
  bool (*f)(const unsigned char *, int64_t) = pick(v);
  /* enough distinct copies that a small size isn't all in L1 */
  int64_t copies = size >= (1 << 20) ? 1 : (int64_t)(4 << 20) / size;
  unsigned char *p = text(kind, size * copies);
  int64_t reps = (int64_t)(256LL << 20) / size;
  int64_t ok = 0;
  uint64_t t0 = now_ns();
  for (int64_t r = 0; r < reps; r++)
    ok += f(p + (r % copies) * size, size);
  uint64_t t1 = now_ns();
  printf("ok=%lld\n", (long long)ok);
  printf("gbps=%.3f\n", (double)size * (double)reps / (double)(t1 - t0));
  REPORT("total", t1 - t0);
}

/* read, validate, parse, respond */
static void rpr(const char *path, const char *v) {
  bool (*f)(const unsigned char *, int64_t) = pick(v);
  uint64_t t0 = now_ns();
  int64_t n;
  char *buf = read_file(path, &n); /* Fs.read: Bytes */
  uint64_t t1 = now_ns();
  if (f && !f((unsigned char *)buf, n)) { /* Str.from_utf8 */
    fputs("invalid\n", stderr);
    exit(1);
  }
  uint64_t t2 = now_ns();
  /* parse each line into its fields, respond with them reversed and
     joined by '|', plus each line's digit sum */
  char *out = xmalloc((size_t)n + (size_t)n / 4 + 64);
  int64_t o = 0, lines = 0, digits = 0;
  int64_t i = 0;
  while (i < n) {
    const char *q = memchr(buf + i, '\n', (size_t)(n - i));
    int64_t e = q ? q - buf : n;
    int64_t fs[16][2], nf = 0, a = i;
    for (int64_t k = i; k <= e && nf < 16; k++)
      if (k == e || buf[k] == ' ' || buf[k] == '\t') {
        fs[nf][0] = a;
        fs[nf][1] = k;
        nf++;
        a = k + 1;
      }
    for (int64_t k = nf - 1; k >= 0; k--) {
      memcpy(out + o, buf + fs[k][0], (size_t)(fs[k][1] - fs[k][0]));
      o += fs[k][1] - fs[k][0];
      out[o++] = k ? '|' : '\n';
    }
    for (int64_t k = i; k < e; k++)
      digits += (unsigned char)buf[k] - '0' < 10u;
    lines++;
    i = e + 1;
  }
  uint64_t t3 = now_ns();
  int fd = open("/dev/null", O_WRONLY);
  write(fd, out, (size_t)o);
  close(fd);
  uint64_t t4 = now_ns();
  printf("check=%lld,%lld,%lld\n", (long long)lines, (long long)digits, (long long)o);
  REPORT("read", t1 - t0);
  REPORT("validate", t2 - t1);
  REPORT("parse_respond", t3 - t2);
  REPORT("write", t4 - t3);
  REPORT("total", t4 - t0);
}

int main(int argc, char **argv) {
  if (!strcmp(argv[1], "test"))
    return test();
  if (!strcmp(argv[1], "dump")) { /* the bench's text, for the twins */
    int64_t size = atoll(argv[3]);
    int64_t copies = size >= (1 << 20) ? 1 : (int64_t)(4 << 20) / size;
    unsigned char *p = text(argv[2], size * copies);
    FILE *f = fopen(argv[4], "wb");
    fwrite(p, 1, (size_t)(size * copies), f);
    fclose(f);
    return 0;
  }
  if (!strcmp(argv[1], "bench"))
    bench(argv[2], atoll(argv[3]), argv[4]);
  else
    rpr(argv[2], argv[3]);
  return 0;
}
