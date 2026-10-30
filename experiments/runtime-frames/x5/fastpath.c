// Cost of Ren's stackless call on the fast path (nothing suspends) and on the
// slow path (the leaf suspends and a reply resumes it through step()).
// Modelled on experiments/runtime-p2/switch/c/ren_single.c (frame_push, CALL).
//
//   plain   : D nested noinline C calls; the leaf calls submit() (noinline).
//   ren     : D nested suspending functions (frames on the task's frame stack,
//             CALL macro); the leaf's submit() answers inline -> DONE.
//   ren_s   : same, but submit() never answers inline: the leaf suspends, the
//             chain returns SUSPEND to step(), the bench "driver" writes the
//             reply into the leaf's frame and calls step() again.
//   poll_s  : Rust-style: on a wake, re-enter from the root frame, each level
//             re-polling its child, K suspensions per op.
//   ren_sK  : Ren with K suspensions per op (leaf loops K submits).
//
// Usage: fastpath <depth> <n> <K>
//
// Copied into experiments/runtime-frames/x5 from research r2's scratchpad.
// Changes: (1) the plain chain's leaf repeats its submit K times, as the Ren
// leaves do, so the check no longer prints MISMATCH at K > 1; (2) SPARE=1 keeps
// one emptied overflow chunk for reuse (X7), for use with THRASH=1, which puts
// the chain's first frame just past a 64 B inline segment.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdlib.h>

#if defined(__TINYC__)
#define NOINLINE __attribute__((noinline))
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#else
#define NOINLINE __attribute__((noinline))
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif

static uint64_t now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

/* ---------- frames (as in ren_single.c, minus the heap model) ---------- */
typedef struct task task;
typedef struct frame frame;
typedef enum { DONE = 0, SUSPEND = 1 } rstat;
typedef rstat (*resume_fn)(task *, frame *);
struct frame {
  resume_fn resume;
  frame *parent;
  uint32_t state;
  uint32_t size;
};
typedef struct chunk {
  char *prev_sp, *prev_limit;
  struct chunk *prev;
  uint64_t cap;
} chunk;
struct task {
  frame *top;
  char *sp, *limit;
  chunk *chunk;
  uint64_t result;
  int done;
  _Alignas(16) char frames[4096];
};
#define R16(x) (((x) + 15u) & ~15u)
#define CHUNK 4096

static int use_spare;
static chunk *spare;
static uint64_t n_mallocs;
NOINLINE static void frame_grow(task *t, uint32_t size) {
  uint64_t cap = size + sizeof(chunk) > CHUNK ? R16(size + sizeof(chunk)) : CHUNK;
  chunk *c;
  if (spare && spare->cap >= cap) { c = spare; spare = NULL; cap = c->cap; }
  else { c = malloc(cap); n_mallocs++; }
  c->prev_sp = t->sp; c->prev_limit = t->limit; c->prev = t->chunk; c->cap = cap;
  t->chunk = c; t->sp = (char *)(c + 1); t->limit = (char *)c + cap;
}
static inline frame *frame_push(task *t, uint32_t size, resume_fn r, frame *parent) {
  size = R16(size);
  if (UNLIKELY(t->sp + size > t->limit)) frame_grow(t, size);
  frame *f = (frame *)t->sp;
  t->sp += size;
  f->resume = r; f->parent = parent; f->state = 0; f->size = size;
  return f;
}
static inline void frame_pop(task *t, frame *f) {
  t->sp = (char *)f;
  if (UNLIKELY(t->chunk && t->sp == (char *)(t->chunk + 1))) {
    chunk *c = t->chunk;
    t->sp = c->prev_sp; t->limit = c->prev_limit; t->chunk = c->prev;
    if (use_spare && !spare) spare = c;
    else free(c);
  }
}
/* The core's trampoline: resume the innermost frame; when one finishes,
   pop it and resume its parent. Returns 1 when the task finished. */
static int step(task *t) {
  frame *f = t->top;
  while (f->resume(t, f) == DONE) {
    frame *p = f->parent;
    frame_pop(t, f);
    if (!p) { t->done = 1; return 1; }
    t->top = f = p;
  }
  return 0;
}

/* ---------- the "driver": answers inline or not ---------- */
static int answer_inline;
static int K = 1; /* submits per leaf call */
static uint64_t pending;
static char *stack_lo = (char *)~(uintptr_t)0, *stack_hi;
NOINLINE static int submit(uint64_t *out, uint64_t x) {
  char probe;
  if (&probe < stack_lo) stack_lo = &probe;
  if (&probe > stack_hi) stack_hi = &probe;
  if (answer_inline) { *out = x * 3 + 1; return 1; }
  pending = x * 3 + 1;
  return 0;
}

/* ---------- plain C chain ---------- */
NOINLINE static uint64_t p0(uint64_t x) {
  uint64_t r, acc = 0;
  for (int k = 0; k < K; k++) { submit(&r, x); acc += r; }
  return acc;
}
#define PLAIN(k, km1) NOINLINE static uint64_t p##k(uint64_t x) { return p##km1(x) + 1; }
PLAIN(1, 0) PLAIN(2, 1) PLAIN(3, 2) PLAIN(4, 3) PLAIN(5, 4) PLAIN(6, 5) PLAIN(7, 6)
PLAIN(8, 7) PLAIN(9, 8) PLAIN(10, 9) PLAIN(11, 10) PLAIN(12, 11) PLAIN(13, 12)
PLAIN(14, 13) PLAIN(15, 14)
static uint64_t (*plain_top[16])(uint64_t) = {p0, p1, p2, p3, p4, p5, p6, p7, p8,
                                              p9, p10, p11, p12, p13, p14, p15};

/* ---------- Ren chain ---------- */
typedef struct { frame f; uint64_t x, i, acc; } lf;
typedef struct { frame f; uint64_t x, i, acc; frame *child; } pf;

/* The leaf: a world call whose driver may answer inline. */
NOINLINE static rstat r0(task *t, frame *ff) {
  lf *f = (lf *)ff;
  if (f->f.state == 1) goto resumed;
  f->i = 0; f->acc = 0;
again:
  if (submit(&t->result, f->x)) goto got;
  f->f.state = 1;
  return SUSPEND;
resumed:
  t->result = pending; /* the reply, written by the driver */
got:
  f->acc += t->result;
  if (++f->i < (uint64_t)K) goto again;
  t->result = f->acc;
  return DONE;
}

#define CALL(T, F, FN, X, ST, LABEL)                                     \
  do {                                                                   \
    lf *c_ = (lf *)frame_push(T, sizeof(lf), FN, &(F)->f);               \
    c_->x = (X);                                                         \
    (F)->f.state = ST; (T)->top = &c_->f;                                \
    if (FN(T, &c_->f) == SUSPEND) return SUSPEND;                        \
    (T)->top = &(F)->f; frame_pop(T, &c_->f);                            \
  } while (0);                                                           \
  LABEL:

#define REN(k, km1)                                                      \
  NOINLINE static rstat r##k(task *t, frame *ff) {                                \
    lf *f = (lf *)ff;                                                    \
    if (f->f.state == 1) goto back;                                      \
    CALL(t, f, r##km1, f->x, 1, back)                                    \
    t->result += 1;                                                      \
    return DONE;                                                         \
  }
REN(1, 0) REN(2, 1) REN(3, 2) REN(4, 3) REN(5, 4) REN(6, 5) REN(7, 6) REN(8, 7)
REN(9, 8) REN(10, 9) REN(11, 10) REN(12, 11) REN(13, 12) REN(14, 13) REN(15, 14)
static resume_fn ren_top[16] = {r0, r1, r2, r3, r4, r5, r6, r7, r8,
                                r9, r10, r11, r12, r13, r14, r15};

/* The task body: loop n times calling the chain's top. */
typedef struct { frame f; uint64_t i, n, sum; resume_fn top; } body_f;
static rstat body(task *t, frame *ff) {
  body_f *f = (body_f *)ff;
  if (f->f.state == 1) goto back;
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  {
    lf *c_ = (lf *)frame_push(t, sizeof(pf), f->top, &f->f);
    c_->x = f->i;
    f->f.state = 1; t->top = &c_->f;
    if (f->top(t, &c_->f) == SUSPEND) return SUSPEND;
    t->top = &f->f; frame_pop(t, &c_->f);
  }
back:
  f->sum += t->result;
  f->i++;
  goto loop;
}


/* ---------- Ren chain, lazy headers ----------
   The fast path only bumps and restores sp. A frame's header (resume,
   parent, state) and t->top are written only on the way out of a
   suspension: the suspender sets t->top and its own state; each caller,
   seeing SUSPEND, fills in its child's header and its own state. */
static inline frame *frame_bump(task *t, uint32_t size) {
  size = R16(size);
  if (UNLIKELY(t->sp + size > t->limit)) frame_grow(t, size);
  frame *f = (frame *)t->sp;
  t->sp += size;
  return f;
}
NOINLINE static rstat s0(task *t, frame *ff) {
  lf *f = (lf *)ff;
  if (f->f.state == 1) goto resumed;
  f->f.state = 0;
  f->i = 0; f->acc = 0;
again:
  if (submit(&t->result, f->x)) goto got;
  f->f.state = 1; t->top = &f->f;
  return SUSPEND;
resumed:
  t->result = pending;
got:
  f->acc += t->result;
  if (++f->i < (uint64_t)K) goto again;
  t->result = f->acc;
  return DONE;
}
#define CALL_LAZY(T, F, FN, X, ST, LABEL)                                \
  do {                                                                   \
    lf *c_ = (lf *)frame_bump(T, sizeof(pf));                            \
    c_->x = (X); c_->f.state = 0;                                        \
    if (UNLIKELY(FN(T, &c_->f) == SUSPEND)) {                            \
      c_->f.resume = FN; c_->f.parent = &(F)->f; (F)->f.state = ST;      \
      return SUSPEND;                                                    \
    }                                                                    \
    frame_pop(T, &c_->f);                                                \
  } while (0);                                                           \
  LABEL:
#define LAZY(k, km1)                                                     \
  NOINLINE static rstat s##k(task *t, frame *ff) {                                \
    lf *f = (lf *)ff;                                                    \
    if (f->f.state == 1) goto back;                                      \
    CALL_LAZY(t, f, s##km1, f->x, 1, back)                               \
    t->result += 1;                                                      \
    return DONE;                                                         \
  }
LAZY(1, 0) LAZY(2, 1) LAZY(3, 2) LAZY(4, 3) LAZY(5, 4) LAZY(6, 5) LAZY(7, 6)
LAZY(8, 7) LAZY(9, 8) LAZY(10, 9) LAZY(11, 10) LAZY(12, 11) LAZY(13, 12)
LAZY(14, 13) LAZY(15, 14)
static resume_fn lazy_top[16] = {s0, s1, s2, s3, s4, s5, s6, s7, s8,
                                 s9, s10, s11, s12, s13, s14, s15};
static rstat body_lazy(task *t, frame *ff) {
  body_f *f = (body_f *)ff;
  if (f->f.state == 1) goto back;
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  {
    lf *c_ = (lf *)frame_bump(t, sizeof(pf));
    c_->x = f->i; c_->f.state = 0;
    if (UNLIKELY(f->top(t, &c_->f) == SUSPEND)) {
      c_->f.resume = f->top; c_->f.parent = &f->f; f->f.state = 1;
      return SUSPEND;
    }
    frame_pop(t, &c_->f);
  }
back:
  f->sum += t->result;
  f->i++;
  goto loop;
}


/* ---------- Ren chain, register ABI ----------
   resume(t, f, sp, in) -> {status, value} in two registers. sp is the
   frame stack's top for this call (frames bump from it; nothing is written
   to the task on the fast path). Arguments arrive in registers; locals
   live in C locals and are spilled to the frame only on the suspend path,
   reloaded after the dispatch on resume. On resume, `in` carries the
   finished child's result. The suspender records t->top; each caller, on
   SUSPEND, fills in its child's header and its own state. */
typedef struct { uint64_t st, v; } rv2;
typedef rv2 (*rfn2)(task *, frame *, char *, uint64_t);
static inline char *bump(task *t, char *sp, uint32_t size) {
  if (UNLIKELY(sp + size > t->limit)) abort(); /* real one: frame_grow */
  return sp + size;
}
NOINLINE static rv2 u0(task *t, frame *ff, char *sp, uint64_t in) {
  lf *f = (lf *)ff;
  uint64_t x, i, acc, r;
  (void)sp;
  if (UNLIKELY(f->f.state == 1)) { x = f->x; i = f->i; acc = f->acc; r = pending; goto resumed; }
  x = in; i = 0; acc = 0;
again:
  if (UNLIKELY(!submit(&r, x))) {
    f->x = x; f->i = i; f->acc = acc; f->f.state = 1; f->f.size = R16(sizeof(pf));
    t->top = &f->f;
    return (rv2){SUSPEND, 0};
  }
resumed:
  acc += r;
  if (++i < (uint64_t)K) goto again;
  return (rv2){DONE, acc};
}
#define REG(k, km1)                                                      \
  NOINLINE static rv2 u##k(task *t, frame *ff, char *sp, uint64_t in) {            \
    lf *f = (lf *)ff;                                                    \
    rv2 r;                                                                \
    if (UNLIKELY(f->f.state == 1)) { r.v = in; goto back; }              \
    {                                                                    \
      lf *c_ = (lf *)sp;                                                 \
      char *nsp = bump(t, sp, R16(sizeof(pf)));                          \
      c_->f.state = 0;                                                   \
      r = u##km1(t, &c_->f, nsp, in);                                    \
      if (UNLIKELY(r.st == SUSPEND)) {                                   \
        c_->f.resume = (resume_fn)u##km1; c_->f.parent = &f->f;          \
        f->f.state = 1; f->f.size = R16(sizeof(pf));                     \
        return r;                                                        \
      }                                                                  \
    }                                                                    \
  back:                                                                  \
    return (rv2){DONE, r.v + 1};                                          \
  }
REG(1, 0) REG(2, 1) REG(3, 2) REG(4, 3) REG(5, 4) REG(6, 5) REG(7, 6)
REG(8, 7) REG(9, 8) REG(10, 9) REG(11, 10) REG(12, 11) REG(13, 12)
REG(14, 13) REG(15, 14)
static rfn2 reg_top[16] = {u0, u1, u2, u3, u4, u5, u6, u7, u8,
                           u9, u10, u11, u12, u13, u14, u15};
typedef struct { frame f; uint64_t i, n, sum; rfn2 top; } body2_f;
static rv2 body_reg(task *t, frame *ff, char *sp, uint64_t in) {
  body2_f *f = (body2_f *)ff;
  uint64_t i, n = f->n, sum;
  rfn2 top = f->top;
  rv2 r;
  if (f->f.state == 1) { i = f->i; sum = f->sum; r.v = in; goto back; }
  i = 0; sum = 0;
loop:
  if (i == n) { f->sum = sum; return (rv2){DONE, sum}; }
  {
    lf *c_ = (lf *)sp;
    char *nsp = bump(t, sp, R16(sizeof(pf)));
    c_->f.state = 0;
    r = top(t, &c_->f, nsp, i);
    if (UNLIKELY(r.st == SUSPEND)) {
      c_->f.resume = (resume_fn)top; c_->f.parent = &f->f;
      f->i = i; f->sum = sum; f->f.state = 1; f->f.size = R16(sizeof(body2_f));
      return r;
    }
  }
back:
  sum += r.v;
  i++;
  goto loop;
}
/* The trampoline for the register ABI: a frame's sp is f + f->size. */
static int step2(task *t, uint64_t in) {
  frame *f = t->top;
  for (;;) {
    rv2 r = ((rfn2)f->resume)(t, f, (char *)f + f->size, in);
    if (r.st == SUSPEND) return 0;
    frame *p = f->parent;
    if (!p) { t->done = 1; return 1; }
    t->top = f = p;
    in = r.v;
  }
}

/* ---------- Rust-style poll from the root ---------- */
/* Each level keeps its child frame; on a wake the root is polled and each
   level re-polls its child down to the leaf. */
NOINLINE static rstat q0(task *t, frame *ff) { return r0(t, ff); }
#define POLL(k, km1)                                                     \
  NOINLINE static rstat q##k(task *t, frame *ff) {                                \
    pf *f = (pf *)ff;                                                    \
    if (f->f.state == 0) {                                               \
      pf *c_ = (pf *)frame_push(t, sizeof(pf), q##km1, &f->f);           \
      c_->x = f->x; f->child = &c_->f; f->f.state = 1;                   \
    }                                                                    \
    if (f->child->resume(t, f->child) == SUSPEND) return SUSPEND;        \
    frame_pop(t, f->child);                                              \
    t->result += 1;                                                      \
    return DONE;                                                         \
  }
POLL(1, 0) POLL(2, 1) POLL(3, 2) POLL(4, 3) POLL(5, 4) POLL(6, 5) POLL(7, 6)
POLL(8, 7) POLL(9, 8) POLL(10, 9) POLL(11, 10) POLL(12, 11) POLL(13, 12)
POLL(14, 13) POLL(15, 14)
static resume_fn poll_top[16] = {q0, q1, q2, q3, q4, q5, q6, q7, q8,
                                 q9, q10, q11, q12, q13, q14, q15};

static task T;
static void task_init2(task *t, resume_fn top, uint64_t n, resume_fn bd) {
  t->sp = t->frames; t->limit = t->frames + sizeof t->frames; t->chunk = NULL;
  t->done = 0;
  body_f *b = (body_f *)frame_push(t, sizeof(body_f), bd, NULL);
  b->n = n; b->sum = 0; b->top = top;
  t->top = &b->f;
}
static void task_init(task *t, resume_fn top, uint64_t n) {
  t->sp = t->frames; t->limit = t->frames + sizeof t->frames; if (getenv("THRASH")) t->limit = t->frames + 64; t->chunk = NULL;
  t->done = 0;
  body_f *b = (body_f *)frame_push(t, sizeof(body_f), body, NULL);
  b->n = n; b->sum = 0; b->top = top;
  t->top = &b->f;
}

int main(int argc, char **argv) {
  int d = argc > 1 ? atoi(argv[1]) : 4;
  uint64_t n = argc > 2 ? strtoull(argv[2], 0, 10) : 10000000;
  K = argc > 3 ? atoi(argv[3]) : 1;
  use_spare = getenv("SPARE") != NULL;
  /* THRASH: poll_susp assumes its child sits right after the body frame, so it
     isn't valid (or checked) under THRASH; read only ren and ren_susp then. */
  int thrash = getenv("THRASH") != NULL;
  if (d < 1 || d > 16) return 1;
  for (int rep = 0; rep < 3; rep++) {
    /* plain */
    answer_inline = 1;
    uint64_t s = 0, t0 = now_ns();
    for (uint64_t i = 0; i < n; i++) s += plain_top[d - 1](i);
    double plain = (double)(now_ns() - t0) / n;
    /* ren, inline answer */
    task_init(&T, ren_top[d - 1], n);
    t0 = now_ns();
    step(&T);
    double ren = (double)(now_ns() - t0) / n;
    uint64_t s2 = ((body_f *)T.frames)->sum;
    /* ren, leaf suspends; the reply resumes the innermost frame */
    answer_inline = 0;
    stack_lo = (char *)~(uintptr_t)0; stack_hi = 0;
    task_init(&T, ren_top[d - 1], n);
    t0 = now_ns();
    while (!step(&T)) { /* reply: pending already holds it */ }
    double ren_s = (double)(now_ns() - t0) / n;
    long span = (long)(stack_hi - stack_lo);
    /* lazy headers */
    answer_inline = 1;
    task_init2(&T, lazy_top[d - 1], n, body_lazy);
    t0 = now_ns();
    step(&T);
    double reg, reg_s; uint64_t s6, s7;
    double lazy = (double)(now_ns() - t0) / n;
    uint64_t s3 = ((body_f *)T.frames)->sum;
    answer_inline = 0;
    task_init2(&T, lazy_top[d - 1], n, body_lazy);
    t0 = now_ns();
    while (!step(&T)) { }
    double lazy_s = (double)(now_ns() - t0) / n;
    uint64_t s4 = ((body_f *)T.frames)->sum;
    /* register ABI */
    {
      body2_f *b;
      answer_inline = 1;
      T.done = 0; b = (body2_f *)T.frames; b->n = n; b->top = reg_top[d - 1];
      b->f.resume = (resume_fn)body_reg; b->f.parent = NULL; b->f.state = 0;
      b->f.size = R16(sizeof(body2_f)); T.top = &b->f;
      t0 = now_ns();
      step2(&T, 0);
      reg = (double)(now_ns() - t0) / n;
      s6 = b->sum;
      answer_inline = 0;
      T.done = 0; b->f.state = 0; T.top = &b->f;
      t0 = now_ns();
      while (!step2(&T, 0)) { }
      reg_s = (double)(now_ns() - t0) / n;
      s7 = b->sum;
    }
    /* poll from the root */
    task_init(&T, poll_top[d - 1], n);
    t0 = now_ns();
    for (;;) {
      frame *root = (frame *)T.frames;
      /* the body itself is ren-style; we re-enter at the body's child, i.e.
         the chain's root future, as tokio polls a task's future */
      frame *c = (frame *)(T.frames + R16(sizeof(body_f)));
      if (T.top == root || T.done) { if (step(&T)) break; continue; }
      if (c->resume(&T, c) == DONE) {
        frame_pop(&T, c);
        T.top = root;
        if (step(&T)) break;
      }
    }
    double poll_s = (double)(now_ns() - t0) / n;
    uint64_t s5 = ((body_f *)T.frames)->sum;
    printf("d %2d K %d plain %6.2f ren %6.2f ren_susp %6.2f lazy %6.2f lazy_susp %6.2f reg %6.2f reg_susp %6.2f poll_susp %6.2f ns/op"
           " span %ld B %s\n",
           d, K, plain, ren, ren_s, lazy, lazy_s, reg, reg_s, poll_s, span,
           (s == s2 && s == s3 && s == s6 && s4 == s7 && (thrash || s4 == s5)) ? "ok" : "MISMATCH");
  }
  if (getenv("THRASH")) fprintf(stderr, "chunk mallocs %llu\n", (unsigned long long)n_mallocs);
  return 0;
}
