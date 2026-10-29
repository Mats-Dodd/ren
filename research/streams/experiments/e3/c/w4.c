/* W4: zip of two generators, which pulls.

     gen fn thirds(n: Int) -> Int =           // the i in 0..n not divisible by 3
       for i in 0..n
         if i % 3 != 0 then yield i

     gen fn nonneg(xs: Array<Int>) -> Int =   // the xs that are >= 0
       for x in xs
         if x >= 0 then yield x

     var sum = 0
     for (a, b) in thirds(NA).zip(nonneg(bs)).map(fn((a, b)) => a ^ b)
       ...sum += it

   bs: 16M Ints, one in eight negative; NA such that both give ~14.7M.
   Run 8 times.

   Variants:
     hand        one loop, two indices
     pull        both generators' frames, the zip block over both nexts
     push1       what a compiler can do with one side: the first source
                 pushed, the second pulled from inside the body (Go's
                 range plus iter.Pull, without the coroutine)
     pull-ni     pull, with the composed block not inlined */
#include "common.h"

#define NB (16LL << 20)
#define NA (22020096LL)   /* 2/3 of it is 14680064, the bs' expected count */
#define REPS 8
static int64_t* BS;

typedef struct { bool some; int64_t v; } OptI;

static NOINLINE int64_t w4_hand(void) {
  const int64_t* bs = BS;
  int64_t i = 0, j = 0, sum = 0;
  for (;;) {
    while (i < NA && i % 3 == 0) i++;
    if (i >= NA) break;
    while (j < NB && bs[j] < 0) j++;
    if (j >= NB) break;
    sum = ren_add(sum, i ^ bs[j]);
    i++, j++;
  }
  return sum;
}

/* thirds, pulled */
typedef struct { int st; int64_t n, i; } ThirdsFrame;
static inline OptI thirds_next(ThirdsFrame* restrict f) {
  switch (f->st) {
    case 0: f->i = 0; break;
    case 1: f->i++; break;
    default: return (OptI){false, 0};
  }
  for (; f->i < f->n; f->i++)
    if (f->i % 3 != 0) { f->st = 1; return (OptI){true, f->i}; }
  f->st = 2;
  return (OptI){false, 0};
}
/* nonneg, pulled */
typedef struct { int st; const int64_t* xs; int64_t n, i; } NonnegFrame;
static inline OptI nonneg_next(NonnegFrame* restrict f) {
  switch (f->st) {
    case 0: f->i = 0; break;
    case 1: f->i++; break;
    default: return (OptI){false, 0};
  }
  for (; f->i < f->n; f->i++)
    if (f->xs[f->i] >= 0) { f->st = 1; return (OptI){true, f->xs[f->i]}; }
  f->st = 2;
  return (OptI){false, 0};
}

/* the pipeline thirds(..).zip(nonneg(..)).map(..): a block whose hidden
   locals are both frames */
#define DEF_ZIP(SUF, ATTR)                                                       \
  static ATTR OptI zip_blk##SUF(const ren_ev* ev, ThirdsFrame* restrict a,       \
                                NonnegFrame* restrict b) {                       \
    (void)ev;                                                                    \
    OptI x = thirds_next(a);                                                     \
    if (!x.some) return x;                                                       \
    OptI y = nonneg_next(b);                                                     \
    if (!y.some) return y;                                                       \
    return (OptI){true, x.v ^ y.v};                                              \
  }                                                                              \
  static NOINLINE int64_t w4_pull##SUF(void) {                                   \
    ThirdsFrame a = {0, NA, 0};                                                  \
    NonnegFrame b = {0, BS, NB, 0};                                              \
    int64_t sum = 0;                                                             \
    for (;;) {                                                                   \
      OptI o = zip_blk##SUF(&EV, &a, &b);                                        \
      if (!o.some) break;                                                        \
      sum = ren_add(sum, o.v);                                                   \
    }                                                                            \
    return sum;                                                                  \
  }
DEF_ZIP(, inline)
DEF_ZIP(_ni, NOINLINE)

/* one side pushed: thirds' push twin, whose body pulls nonneg */
static inline int push1_body(const ren_ev* ev, NonnegFrame* restrict b, int64_t* restrict sum, int64_t x) {
  (void)ev;
  OptI y = nonneg_next(b);
  if (!y.some) return REN_BREAK;
  *sum = ren_add(*sum, x ^ y.v);
  return REN_CONT;
}
static inline int thirds_push(int64_t n, const ren_ev* ev, NonnegFrame* restrict b, int64_t* restrict sum) {
  for (int64_t i = 0; i < n; i++)
    if (i % 3 != 0) {
      int c = push1_body(ev, b, sum, i);
      if (c != REN_CONT) return c;
    }
  return REN_CONT;
}
static NOINLINE int64_t w4_push1(void) {
  NonnegFrame b = {0, BS, NB, 0};
  int64_t sum = 0;
  thirds_push(NA, &EV, &b, &sum);
  return sum;
}

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: w4 variant\n"); return 2; }
  const char* v = argv[1];
  BS = malloc(sizeof(int64_t) * NB);
  rng r = {5};
  for (int64_t i = 0; i < NB; i++) {
    uint64_t x = rnext(&r);
    BS[i] = (x % 8 == 0) ? -1 - (int64_t)(x >> 3) : (int64_t)(x >> 3);
  }
  int64_t s = 0;
  uint64_t t0 = now_ns();
  for (int k = 0; k < REPS; k++) {
    __asm__ volatile("" ::: "memory");  /* each rep runs: no CSE of the calls */
    int64_t x;
    if (!strcmp(v, "hand")) x = w4_hand();
    else if (!strcmp(v, "pull")) x = w4_pull();
    else if (!strcmp(v, "push1")) x = w4_push1();
    else if (!strcmp(v, "pull-ni")) x = w4_pull_ni();
    else { fprintf(stderr, "variant?\n"); return 2; }
    s = ren_add(s, x);
  }
  uint64_t t1 = now_ns();
  printf("check=%lld\n", (long long)s);
  printf("w4_ns=%llu\n", (unsigned long long)(t1 - t0));
  return 0;
}
