/* W3: a user stage, dedup_by, over a mapped source.

     gen fn ticks(ds: Array<Int>) -> Int =    // pure: a value cursor
       var v = 0
       for d in ds
         v += d
         yield v

   ds: 16M deltas, 1 with probability 1/16, else 0; the chain runs 8
   times.

     gen fn dedup_by<T, K>(src: fn() -> Option<T>, key: fn(T) -> K) -> T =
       var last: Option<K> = None
       for x in try src
         let k = key(x)
         if Some(k) != last then
           last = Some(k)
           yield x

     var sum = 0
     for x in dedup_by(ticks(ds).map(fn(x) => x / 2), fn(x) => x)
       sum += x

   Variants:
     hand       one loop
     design     what the amended design gives: dedup_by is a gen fn call
                consumed by a for, so it's pushed (its yield calls the for
                body); its source is a pipeline passed to it, so it's
                pulled (ticks' frame, a switch, through the map block)
     full-push  fusion through a gen fn: ticks pushed into dedup_by's loop
                body, pushed into the for body; nothing pulled
     pull       everything pulled: dedup_by's frame and next over the
                source's (what a zip, or passing the whole chain to a user
                function, gives)
     pull-ni    pull, with dedup_by's next not inlined (one call per item) */
#include "common.h"

#define N (16LL << 20)
#define REPS 8
static int64_t* DS;

typedef struct { bool some; int64_t v; } OptI;

static NOINLINE int64_t w3_hand(void) {
  const int64_t* ds = DS;
  int64_t v = 0, sum = 0;
  bool have = false;
  int64_t last = 0;
  for (int64_t i = 0; i < N; i++) {
    v = ren_add(v, ds[i]);
    int64_t x = v / 2;
    if (!have || x != last) {
      have = true;
      last = x;
      sum = ren_add(sum, x);
    }
  }
  return sum;
}

/* ---- the pieces, as the compiler would write them ---- */
static inline int64_t map_blk(const ren_ev* ev, int64_t x) { (void)ev; return x / 2; }
static inline int64_t key_blk(const ren_ev* ev, int64_t x) { (void)ev; return x; }

/* ticks, pulled: its frame and next */
typedef struct { int st; const int64_t* ds; int64_t v, i, n; } TicksFrame;
static inline OptI ticks_next(TicksFrame* restrict f) {
  switch (f->st) {
    case 0: f->i = 0; break;
    case 1: f->i++; break;
    default: return (OptI){false, 0};
  }
  if (f->i < f->n) {
    f->v = ren_add(f->v, f->ds[f->i]);
    f->st = 1;
    return (OptI){true, f->v};
  }
  f->st = 2;
  return (OptI){false, 0};
}
/* the pipeline ticks(N).map(..): a block over ticks' frame */
static inline OptI src_blk(const ren_ev* ev, TicksFrame* restrict g) {
  OptI o = ticks_next(g);
  if (!o.some) return o;
  return (OptI){true, map_blk(ev, o.v)};
}

/* ---- design: dedup_by pushed, its source pulled ---- */
static inline int for_body(const ren_ev* ev, int64_t* restrict sum, int64_t x) {
  (void)ev;
  *sum = ren_add(*sum, x);
  return REN_CONT;
}
/* dedup_by's push twin, specialized for (src_blk, key_blk, for_body) */
static inline int dedup_push(const ren_ev* ev, TicksFrame* restrict src, int64_t* restrict sum) {
  bool have = false;
  int64_t last = 0;
  for (;;) {
    OptI o = src_blk(ev, src);                  /* for x in try src */
    if (!o.some) break;
    int64_t k = key_blk(ev, o.v);
    if (!have || k != last) {
      have = true;
      last = k;
      int c = for_body(ev, sum, o.v);           /* yield x */
      if (c != REN_CONT) return c;
    }
  }
  return REN_CONT;
}
static NOINLINE int64_t w3_design(void) {
  TicksFrame g = {0, DS, 0, 0, N};
  int64_t sum = 0;
  dedup_push(&EV, &g, &sum);
  return sum;
}

/* ---- full push: ticks pushed into dedup_by's body, into the for's ---- */
static inline int dedup_loop_body(const ren_ev* ev, bool* restrict have, int64_t* restrict last,
                                  int64_t* restrict sum, int64_t x) {
  int64_t k = key_blk(ev, x);
  if (!*have || k != *last) {
    *have = true;
    *last = k;
    return for_body(ev, sum, x);
  }
  return REN_CONT;
}
static inline int ticks_push(const int64_t* ds, int64_t n, const ren_ev* ev, bool* restrict have,
                             int64_t* restrict last, int64_t* restrict sum) {
  int64_t v = 0;
  for (int64_t i = 0; i < n; i++) {
    v = ren_add(v, ds[i]);
    int c = dedup_loop_body(ev, have, last, sum, map_blk(ev, v));   /* yield v, through map */
    if (c != REN_CONT) return c;
  }
  return REN_CONT;
}
static NOINLINE int64_t w3_full_push(void) {
  bool have = false;
  int64_t last = 0, sum = 0;
  ticks_push(DS, N, &EV, &have, &last, &sum);
  return sum;
}

/* ---- pull: dedup_by's frame and next, over the source's ---- */
typedef struct { int st; TicksFrame src; bool have; int64_t last, x; } DedupFrame;
#define DEF_DEDUP_NEXT(SUF, ATTR)                                   \
  static ATTR OptI dedup_next##SUF(const ren_ev* ev, DedupFrame* restrict f) { \
    switch (f->st) {                                                \
      case 0: f->have = false; break;                               \
      case 1: break;                                                \
      default: return (OptI){false, 0};                             \
    }                                                               \
    for (;;) {                                                      \
      OptI o = src_blk(ev, &f->src);                                \
      if (!o.some) break;                                           \
      int64_t k = key_blk(ev, o.v);                                 \
      if (!f->have || k != f->last) {                               \
        f->have = true;                                             \
        f->last = k;                                                \
        f->st = 1;                                                  \
        return (OptI){true, o.v};                                   \
      }                                                             \
    }                                                               \
    f->st = 2;                                                      \
    return (OptI){false, 0};                                        \
  }                                                                 \
  static NOINLINE int64_t w3_pull##SUF(void) {                      \
    DedupFrame d = {0, {0, DS, 0, 0, N}, false, 0, 0};            \
    int64_t sum = 0;                                                \
    for (;;) {                                                      \
      OptI o = dedup_next##SUF(&EV, &d);                            \
      if (!o.some) break;                                           \
      sum = ren_add(sum, o.v);                                      \
    }                                                               \
    return sum;                                                     \
  }
DEF_DEDUP_NEXT(, inline)
DEF_DEDUP_NEXT(_ni, NOINLINE)

int main(int argc, char** argv) {
  if (argc < 2) { fprintf(stderr, "usage: w3 variant\n"); return 2; }
  const char* v = argv[1];
  DS = malloc(sizeof(int64_t) * N);
  rng r = {99};
  for (int64_t i = 0; i < N; i++) DS[i] = rnext(&r) % 16 == 0;
  int64_t s = 0;
  uint64_t t0 = now_ns();
  for (int k = 0; k < REPS; k++) {
    __asm__ volatile("" ::: "memory");  /* each rep runs: no CSE of the calls */
    int64_t x;
    if (!strcmp(v, "hand")) x = w3_hand();
    else if (!strcmp(v, "design")) x = w3_design();
    else if (!strcmp(v, "full-push")) x = w3_full_push();
    else if (!strcmp(v, "pull")) x = w3_pull();
    else if (!strcmp(v, "pull-ni")) x = w3_pull_ni();
    else { fprintf(stderr, "variant?\n"); return 2; }
    s = ren_add(s, x);
  }
  uint64_t t1 = now_ns();
  printf("check=%lld\n", (long long)s);
  printf("w3_ns=%llu\n", (unsigned long long)(t1 - t0));
  return 0;
}
