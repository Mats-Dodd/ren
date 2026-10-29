/* W1 and W5 over a 100 MB log in memory.

   W1, in Ren:

     gen fn lines(b: Bytes) -> Str =
       var i = 0
       while i < b.len()
         let j = b.find('\n', from: i) ?? b.len()
         yield b[i..j]
         i = j + 1

     var n = 0
     for e in lines(log).map(parse).select(fn(e) => e.level == Error).take(TAKE)
       n += 1; ids += e.id

   W5, the same chain without take, consumed by a user function:

     fn total(rows: fn() -> Option<Entry>) -> (Int, Int) =
       for e in rows ...
     total(lines(log).map(parse).select(fn(e) => e.level == Error))

   against the chain inlined: `for e in lines(log).map(parse).select(..)`. */
#include "common.h"

#define TAKE 40000
#define REPS 5

typedef struct { int64_t n, ids; } Acc;

/* ---------------- hand-written loop ---------------- */
static NOINLINE Acc w1_hand(const uint8_t* b, size_t len) {
  Acc a = {0, 0};
  int64_t left = TAKE;
  size_t i = 0;
  while (i < len) {
    const uint8_t* q = memchr(b + i, '\n', len - i);
    size_t j = q ? (size_t)(q - b) : len;
    Entry e = parse((Str){b, (uint32_t)i, (uint32_t)(j - i)});
    if (e.level == ERROR) {
      a.n = ren_add(a.n, 1);
      a.ids = ren_add(a.ids, e.id);
      if (--left == 0) break;
    }
    i = j + 1;
  }
  return a;
}

/* ---------------- push ----------------
   lines_push is the twin of `lines`; its yield calls the body. The body
   is the chain's one-input stages folded into the for body: map, select,
   take, then the loop's own statements. take's counter is a hidden local
   of the caller, captured by pointer. */
#define DEF_PUSH(SUF, ATTR)                                                          \
  static ATTR int w1_body##SUF(const ren_ev* ev, int64_t* restrict left,            \
                               int64_t* restrict n, int64_t* restrict ids, Str l) {  \
    (void)ev;                                                                        \
    Entry e = parse(l);                         /* map(parse) */                     \
    if (!(e.level == ERROR)) return REN_CONT;   /* select */                         \
    *n = ren_add(*n, 1);                        /* the for body */                   \
    *ids = ren_add(*ids, e.id);                                                      \
    if (--*left == 0) return REN_BREAK;         /* take: stop once it has n */       \
    return REN_CONT;                                                                 \
  }                                                                                  \
  static int lines_push##SUF(const uint8_t* b, size_t len, const ren_ev* ev,        \
                             int64_t* restrict left, int64_t* restrict n,           \
                             int64_t* restrict ids) {                                \
    size_t i = 0;                                                                    \
    while (i < len) {                                                                \
      const uint8_t* q = memchr(b + i, '\n', len - i);                               \
      size_t j = q ? (size_t)(q - b) : len;                                          \
      int c = w1_body##SUF(ev, left, n, ids, (Str){b, (uint32_t)i, (uint32_t)(j - i)}); \
      if (c != REN_CONT) return c;                                                   \
      i = j + 1;                                                                     \
    }                                                                                \
    return REN_CONT;                                                                 \
  }                                                                                  \
  static NOINLINE Acc w1_push##SUF(const uint8_t* b, size_t len) {                   \
    int64_t left = TAKE, n = 0, ids = 0;                                             \
    if (left > 0) lines_push##SUF(b, len, &EV, &left, &n, &ids);                     \
    return (Acc){n, ids};                                                            \
  }
DEF_PUSH(, inline)
DEF_PUSH(_ni, NOINLINE)

/* ---------------- pull ----------------
   `lines`' frame and its next, a switch on the resume point. */
typedef struct { int st; const uint8_t* b; size_t len, i, j; } LinesFrame;
typedef struct { bool some; Str v; } OptStr;
typedef struct { bool some; Entry v; } OptEntry;

#define DEF_LINES_NEXT(SUF, ATTR)                                   \
  static ATTR OptStr lines_next##SUF(LinesFrame* restrict f) {      \
    switch (f->st) {                                                \
      case 0: f->i = 0; break;                                      \
      case 1: f->i = f->j + 1; break;                               \
      default: return (OptStr){false, {0}};                         \
    }                                                               \
    if (f->i < f->len) {                                            \
      const uint8_t* q = memchr(f->b + f->i, '\n', f->len - f->i);  \
      f->j = q ? (size_t)(q - f->b) : f->len;                       \
      f->st = 1;                                                    \
      return (OptStr){true, {f->b, (uint32_t)f->i, (uint32_t)(f->j - f->i)}}; \
    }                                                               \
    f->st = 2;                                                      \
    return (OptStr){false, {0}};                                    \
  }
DEF_LINES_NEXT(, inline)
DEF_LINES_NEXT(_ni, NOINLINE)

/* the pipeline: a block fn() -> Option<Entry> written where the chain is,
   whose hidden locals are the generator's frame and take's counter */
#define DEF_PIPE(SUF, ATTR, NEXT)                                              \
  static ATTR OptEntry w1_pipe##SUF(const ren_ev* ev, LinesFrame* restrict g, \
                                    int64_t* restrict left) {                  \
    (void)ev;                                                                  \
    if (*left <= 0) return (OptEntry){false, {0}};                             \
    for (;;) {                                                                 \
      OptStr l = NEXT(g);                                                      \
      if (!l.some) return (OptEntry){false, {0}};                              \
      Entry e = parse(l.v);                                                    \
      if (!(e.level == ERROR)) continue;                                       \
      --*left;                                                                 \
      return (OptEntry){true, e};                                              \
    }                                                                          \
  }                                                                            \
  static NOINLINE Acc w1_pull##SUF(const uint8_t* b, size_t len) {             \
    LinesFrame g = {0, b, len, 0, 0};                                          \
    int64_t left = TAKE, n = 0, ids = 0;                                       \
    for (;;) {                                                                 \
      OptEntry o = w1_pipe##SUF(&EV, &g, &left);                               \
      if (!o.some) break;                                                      \
      n = ren_add(n, 1);                                                       \
      ids = ren_add(ids, o.v.id);                                              \
    }                                                                          \
    return (Acc){n, ids};                                                      \
  }
DEF_PIPE(, inline, lines_next)        /* everything inlinable */
DEF_PIPE(_ni, NOINLINE, lines_next)          /* one call per item */
DEF_PIPE(_ni2, NOINLINE, lines_next_ni)      /* two calls per item */

/* ---------------- W5: a pipeline passed to a user function ---------------- */
typedef struct { int64_t n, ids; } Tot;

/* inlined: the chain consumed by a for in place, pushed */
static inline int w5_body(const ren_ev* ev, int64_t* restrict n, int64_t* restrict ids, Str l) {
  (void)ev;
  Entry e = parse(l);
  if (!(e.level == ERROR)) return REN_CONT;
  *n = ren_add(*n, 1);
  *ids = ren_add(*ids, e.id);
  return REN_CONT;
}
static inline int w5_lines_push(const uint8_t* b, size_t len, const ren_ev* ev,
                                int64_t* restrict n, int64_t* restrict ids) {
  size_t i = 0;
  while (i < len) {
    const uint8_t* q = memchr(b + i, '\n', len - i);
    size_t j = q ? (size_t)(q - b) : len;
    int c = w5_body(ev, n, ids, (Str){b, (uint32_t)i, (uint32_t)(j - i)});
    if (c != REN_CONT) return c;
    i = j + 1;
  }
  return REN_CONT;
}
static NOINLINE Tot w5_inline(const uint8_t* b, size_t len) {
  int64_t n = 0, ids = 0;
  w5_lines_push(b, len, &EV, &n, &ids);
  return (Tot){n, ids};
}

/* passed: the pipeline block, and `total` specialized for it (decision 1) */
static inline OptEntry w5_pipe(const ren_ev* ev, LinesFrame* restrict g) {
  (void)ev;
  for (;;) {
    OptStr l = lines_next(g);
    if (!l.some) return (OptEntry){false, {0}};
    Entry e = parse(l.v);
    if (!(e.level == ERROR)) continue;
    return (OptEntry){true, e};
  }
}
#define DEF_TOTAL(SUF, ATTR)                                              \
  static ATTR Tot total##SUF(const ren_ev* ev, LinesFrame* restrict g) {  \
    int64_t n = 0, ids = 0;                                               \
    for (;;) {                                                            \
      OptEntry o = w5_pipe(ev, g);                                        \
      if (!o.some) break;                                                 \
      n = ren_add(n, 1);                                                  \
      ids = ren_add(ids, o.v.id);                                         \
    }                                                                     \
    return (Tot){n, ids};                                                 \
  }
DEF_TOTAL(, inline)
DEF_TOTAL(_ni, NOINLINE)
static NOINLINE Tot w5_passed(const uint8_t* b, size_t len) {
  LinesFrame g = {0, b, len, 0, 0};
  return total(&EV, &g);
}
static NOINLINE Tot w5_passed_ni(const uint8_t* b, size_t len) {
  LinesFrame g = {0, b, len, 0, 0};
  return total_ni(&EV, &g);
}

/* indirect: the block as code and frame, Ren's ren_block, called through
   a pointer, as a debug build passes blocks (and release past the
   specialization budget): `total` is compiled once for every block */
typedef struct { OptEntry (*code)(void* env, const ren_ev* ev); void* env; } Block;
static NOINLINE OptEntry w5_pipe_code(void* env, const ren_ev* ev) {
  return w5_pipe(ev, (LinesFrame*)env);
}
static NOINLINE Tot total_dyn(const ren_ev* ev, Block rows) {
  int64_t n = 0, ids = 0;
  for (;;) {
    OptEntry o = rows.code(rows.env, ev);
    if (!o.some) break;
    n = ren_add(n, 1);
    ids = ren_add(ids, o.v.id);
  }
  return (Tot){n, ids};
}
static NOINLINE Tot w5_indirect(const uint8_t* b, size_t len) {
  LinesFrame g = {0, b, len, 0, 0};
  return total_dyn(&EV, (Block){w5_pipe_code, &g});
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: w1 w1|w5 variant\n"); return 2; }
  const char* w = argv[1]; const char* v = argv[2];
  size_t len;
  uint8_t* b = make_log(LOG_BYTES, &len);
  int64_t n = 0, ids = 0;
  uint64_t t0 = now_ns();
  for (int r = 0; r < REPS; r++) {
    __asm__ volatile("" ::: "memory");  /* each rep runs: no CSE of the calls */
    Acc a = {0, 0};
    if (!strcmp(w, "w1")) {
      if (!strcmp(v, "hand")) a = w1_hand(b, len);
      else if (!strcmp(v, "push")) a = w1_push(b, len);
      else if (!strcmp(v, "push-ni")) a = w1_push_ni(b, len);
      else if (!strcmp(v, "pull")) a = w1_pull(b, len);
      else if (!strcmp(v, "pull-ni")) a = w1_pull_ni(b, len);
      else if (!strcmp(v, "pull-ni2")) a = w1_pull_ni2(b, len);
      else { fprintf(stderr, "variant?\n"); return 2; }
    } else {
      Tot t;
      if (!strcmp(v, "inline")) t = w5_inline(b, len);
      else if (!strcmp(v, "passed")) t = w5_passed(b, len);
      else if (!strcmp(v, "passed-ni")) t = w5_passed_ni(b, len);
      else if (!strcmp(v, "indirect")) t = w5_indirect(b, len);
      else { fprintf(stderr, "variant?\n"); return 2; }
      a = (Acc){t.n, t.ids};
    }
    n += a.n; ids += a.ids;
  }
  uint64_t t1 = now_ns();
  printf("bytes=%zu\n", len);
  printf("check=%lld:%lld\n", (long long)n, (long long)ids);
  printf("%s_ns=%llu\n", w, (unsigned long long)(t1 - t0));
  return 0;
}
