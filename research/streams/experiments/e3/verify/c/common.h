/* E3: push against pull. A C model of what Ren's C backend would emit
   for a stream chain, in the style `ren build --release --emit-c` emits
   today (see ../RESULTS.md, "How the C models Ren"):

   - a block is a static function, specialized per call site (decision
     1); its captures are passed as `restrict` pointers to the caller's
     locals, plus the evidence pointer `ev` (unused here, kept so the
     signatures have the shape Ren's do);
   - Int arithmetic that can overflow goes through ren_add, which traps,
     as the runtime's does;
   - a pushed generator is a twin `G_push(args, ev, captures...)` whose
     `yield e` is a call of the specialized body, returning a control
     value (REN_CONT, REN_BREAK);
   - a pulled generator is its frame in a struct (a hidden local of the
     caller, decision 12 under B+R) and a `next` that switches on the
     resume point, returning an Option by value.

   clang -O2 then inlines what it likes, as it does for Ren's output.
   NOINLINE variants pin a call in place, to show what a call costs when
   clang doesn't inline it (a big body, or a block past the budget). */
#ifndef E3_COMMON_H
#define E3_COMMON_H
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>

#define NOINLINE __attribute__((noinline))
#define INLINE static inline __attribute__((always_inline))

typedef struct { int unused; } ren_ev;
static const ren_ev EV = {0};

enum { REN_CONT = 0, REN_BREAK = 1 };

static NOINLINE void ren_overflow(void) {
  fprintf(stderr, "overflow\n");
  exit(3);
}
static inline int64_t ren_add(int64_t a, int64_t b) {
  int64_t r;
  if (__builtin_add_overflow(a, b, &r)) ren_overflow();
  return r;
}

/* Ren puts this in every function that can recurse */
static char* ren_stack_limit;
static NOINLINE void ren_stack_overflowed(void) {
  fprintf(stderr, "stack overflow\n");
  exit(4);
}
#define REN_STACK_CHECK()                                         \
  do {                                                            \
    if ((char*)__builtin_frame_address(0) < ren_stack_limit)      \
      ren_stack_overflowed();                                     \
  } while (0)
static inline void ren_stack_init(void) {
  char here;
  ren_stack_limit = &here - (7u << 20);
}

static inline uint64_t now_ns(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

/* the LCG every language's twin uses, so the data agree byte for byte */
typedef struct { uint64_t s; } rng;
static inline uint64_t rnext(rng* r) {
  r->s = r->s * 6364136223846793005ull + 1442695040888963407ull;
  return r->s >> 33;
}

/* a Str, strings.md's decided layout: a root, a 32-bit offset and a
   32-bit length (the root's count is not touched: the buffer outlives
   the loop, which borrow inference sees) */
typedef struct { const uint8_t* root; uint32_t off; uint32_t len; } Str;

/* the log of W1 and W5: lines of
   "2026-10-29T11:43:SS.mmmZ LEVEL svc=SVC id=ID msg=MSG\n" */
static uint8_t* make_log(size_t target, size_t* out_len) {
  uint8_t* b = malloc(target + 256);
  size_t n = 0;
  rng r = {42};
  static const char* lv[4] = {"DEBUG", "INFO", "WARN", "ERROR"};
  static const char* sv[4] = {"api", "db", "auth", "cache"};
  while (n < target) {
    uint64_t x = rnext(&r);
    unsigned sec = x % 60, ms = (x >> 8) % 1000, p = (x >> 20) % 100;
    const char* l = p < 30 ? lv[0] : p < 80 ? lv[1] : p < 95 ? lv[2] : lv[3];
    const char* s = sv[(x >> 27) % 4];
    uint64_t id = rnext(&r) % 1000000000ull;
    unsigned mlen = 20 + rnext(&r) % 60;
    memcpy(b + n, "2026-10-29T11:43:", 17); n += 17;
    b[n++] = '0' + sec / 10; b[n++] = '0' + sec % 10; b[n++] = '.';
    b[n++] = '0' + ms / 100; b[n++] = '0' + ms / 10 % 10; b[n++] = '0' + ms % 10;
    b[n++] = 'Z'; b[n++] = ' ';
    size_t k = strlen(l); memcpy(b + n, l, k); n += k; b[n++] = ' ';
    memcpy(b + n, "svc=", 4); n += 4;
    k = strlen(s); memcpy(b + n, s, k); n += k; b[n++] = ' ';
    memcpy(b + n, "id=", 3); n += 3;
    char d[24]; int nd = 0;
    do { d[nd++] = '0' + id % 10; id /= 10; } while (id);
    while (nd) b[n++] = d[--nd];
    b[n++] = ' ';
    memcpy(b + n, "msg=", 4); n += 4;
    for (unsigned i = 0; i < mlen; i++) b[n++] = 'a' + rnext(&r) % 26;
    b[n++] = '\n';
  }
  *out_len = n;
  return b;
}

/* parse: a line to an entry; the same byte loop in every twin */
typedef struct { int64_t level; int64_t id; } Entry;
enum { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3, BAD = -1 };

static inline Entry parse(Str s) {
  const uint8_t* p = s.root + s.off;
  uint32_t n = s.len, i = 25;
  Entry e = {BAD, 0};
  if (n <= i) return e;
  switch (p[i]) {
    case 'D': e.level = DEBUG; break;
    case 'I': e.level = INFO; break;
    case 'W': e.level = WARN; break;
    case 'E': e.level = ERROR; break;
    default: return e;
  }
  while (i < n && p[i] != ' ') i++;   /* the level */
  i++;
  while (i < n && p[i] != ' ') i++;   /* svc=... */
  i += 4;                             /* " id=" */
  int64_t id = 0;
  while (i < n && p[i] >= '0' && p[i] <= '9') id = id * 10 + (p[i++] - '0');
  e.id = id;
  return e;
}

#define LOG_BYTES (100u << 20)
#endif
