// X1: ren_single.c's ping-pong benches in the register calling convention
// (research/runtime-frames/SYNTHESIS.md §2a and §5).
//
//   ren_ret fn(task *t, frame *f, char *sp, uint64_t in) -> {status, value}
//
// - `sp` is a C local passed down; a callee's frame is bumped from it, and
//   nothing is written to the task on the way in.
// - Locals are C locals. They're spilled to the frame only on the way out of
//   a suspension, and reloaded at a cold `dispatch:` block on resume.
// - A frame's header (resume, parent) is written only on the PENDING path,
//   by the caller that sees its callee return PENDING.
// - Only the innermost suspender writes t->top.
// - On resume, `in` carries the finished child's value; a child's result
//   never goes through the task.
//
// Everything else (the heap model, instances, waiter queues, the run queue)
// is ren_single.c's, unchanged, so the only difference between this file and
// ren_single.c's pingpong / pingpong_nested is the calling convention.
//
// -DOPS_NOINLINE keeps put and get out of line (a non-inlined op, what a debug
// build does). Without it clang may inline them into the task body, as it
// does in ren_single.c.
// -DBUMP_NOCHECK drops the frame-stack bounds check (release, when the task's
// inline segment covers the static bound, SYNTHESIS §5's table).

#include "common.h"

#if defined(__TINYC__)
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#define UNREACHABLE() abort()
#else
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#define UNREACHABLE() __builtin_unreachable()
#endif
#ifdef OPS_NOINLINE
#define OPATTR __attribute__((noinline))
#else
#define OPATTR
#endif

/* ---------- Ren's heap (ren_single.c's, unchanged) ---------- */
typedef struct freeblk { struct freeblk *next; } freeblk;
#define NCLASS 600
#define SLAB (64 * 1024)
static freeblk *fl[NCLASS];
static uint64_t n_obj, n_sys, live_bytes;
static void *cur_heap;

__attribute__((noinline)) static freeblk *refill(uint32_t c) {
  size_t sz = (size_t)c << 4;
  char *slab = malloc(SLAB);
  if (!slab) abort();
  n_sys++;
  freeblk *head = NULL;
  for (size_t off = (SLAB / sz) * sz; off >= sz; off -= sz) {
    freeblk *b = (freeblk *)(slab + off - sz);
    b->next = head;
    head = b;
  }
  return head;
}
static inline void *heap_alloc(size_t sz) {
  uint32_t c = (uint32_t)((sz + 15) >> 4);
  if (c >= NCLASS) abort();
  freeblk *b = fl[c];
  if (UNLIKELY(!b)) b = refill(c);
  fl[c] = b->next;
  n_obj++;
  live_bytes += (uint64_t)c << 4;
  return b;
}
static inline void heap_free(void *p, size_t sz) {
  uint32_t c = (uint32_t)((sz + 15) >> 4);
  freeblk *b = p;
  b->next = fl[c];
  fl[c] = b;
  live_bytes -= (uint64_t)c << 4;
}

/* ---------- the register convention ---------- */
typedef struct task task;
typedef struct frame frame;
typedef struct { uintptr_t st; uint64_t v; } ren_ret; /* x0/x1 on arm64 */
enum { DONE = 0, PENDING = 1 };
typedef ren_ret (*ren_resume)(task *, frame *, char *sp, uint64_t in);
typedef bool (*cond_fn)(void *inst, frame *waiting);

struct frame {     /* 32 B, SYNTHESIS §2b */
  ren_resume resume; /* written on the PENDING path only */
  frame *parent;     /* ditto */
  uint32_t state;    /* 0 fresh; 1..n suspension points */
  uint32_t flags;    /* REN_FIRST_IN_CHUNK (unused here: no chunks) */
  char *sp;          /* this frame's stack top when it suspended */
};
typedef struct scope {
  uint32_t live, max;
  task *end_waiter;
} scope;
struct task {
  task *next;
  frame *top;   /* innermost suspended frame: written by the suspender only */
  char *limit;  /* end of the frame stack's inline segment */
  scope *scope;
  cond_fn cond;
  void *heap;
  uint64_t result;
  uint32_t size;
  uint8_t done, _pad[3];
  _Alignas(16) char frames[];
};
#define R16(x) (((x) + 15u) & ~15u)

static task *rq_head, *rq_tail;
static uint64_t take_conflicts, switches;

static inline void rq_push(task *t) {
  t->next = NULL;
  if (rq_tail) rq_tail->next = t;
  else rq_head = t;
  rq_tail = t;
}

/* A callee frame at sp; returns the callee's sp. The tasks here are sized
   to their chains, so the overflow path is never taken (it aborts). */
#ifdef BUMP_NOCHECK
#define BUMP(T, SP, SIZE) ((SP) + (SIZE))
#else
#define BUMP(T, SP, SIZE) (UNLIKELY((SP) + (SIZE) > (T)->limit) ? (abort(), (char *)0) : (SP) + (SIZE))
#endif

static task *task_new(scope *s, uint32_t frames_size, uint32_t body_size) {
  uint32_t sz = (uint32_t)sizeof(task) + R16(frames_size);
  task *t = heap_alloc(sz);
  t->size = sz;
  t->limit = t->frames + R16(frames_size);
  t->scope = s;
  t->cond = NULL;
  t->heap = cur_heap;
  t->result = 0;
  t->done = 0;
  frame *f = (frame *)t->frames;
  f->parent = NULL;
  f->state = 0;
  f->flags = 0;
  f->sp = t->frames + R16(body_size);
  t->top = f;
  s->live++;
  return t;
}
static inline void task_free(task *t) { heap_free(t, t->size); }
static void task_finish(task *t, uint64_t v) {
  scope *s = t->scope;
  t->done = 1;
  t->result = v;
  s->live--;
  if (s->live == 0 && s->end_waiter) {
    rq_push(s->end_waiter);
    s->end_waiter = NULL;
  }
}

/* The trampoline: resume the innermost frame; a frame that finishes hands its
   value to its parent through `in`. */
static inline void step(task *t) {
  frame *f = t->top;
  uint64_t in = 0;
  for (;;) {
    ren_ret r = f->resume(t, f, f->sp, in);
    if (r.st == PENDING) return; /* the suspender set t->top */
    frame *p = f->parent;
    if (!p) {
      task_finish(t, r.v);
      return;
    }
    t->top = f = p;
    in = r.v;
  }
}
static void run_all(void) {
  task *t;
  while ((t = rq_head)) {
    rq_head = t->next;
    if (!rq_head) rq_tail = NULL;
    cur_heap = t->heap;
    switches++;
    step(t);
  }
}

/* ---------- handler instances (ren_single.c's, unchanged) ---------- */
typedef struct {
  uint8_t held;
  task *wq_head, *wq_tail;
} inst_t;
static inline void inst_take(inst_t *in) {
  if (UNLIKELY(in->held)) take_conflicts++;
  in->held = 1;
}
__attribute__((noinline)) static void wake_first(inst_t *in) {
  task *prev = NULL;
  for (task *t = in->wq_head; t; prev = t, t = t->next) {
    if (t->cond(in, t->top)) {
      if (prev) prev->next = t->next;
      else in->wq_head = t->next;
      if (in->wq_tail == t) in->wq_tail = prev;
      t->cond = NULL;
      in->held = 1;
      rq_push(t);
      return;
    }
  }
}
static inline void inst_release(inst_t *in) {
  in->held = 0;
  if (in->wq_head) wake_first(in);
}
static inline void park_until(task *t, inst_t *in, cond_fn c) {
  in->held = 0;
  t->cond = c;
  t->next = NULL;
  if (in->wq_tail) in->wq_tail->next = t;
  else in->wq_head = t;
  in->wq_tail = t;
}

typedef struct {
  inst_t h;
  uint8_t full;
  uint64_t v;
} __attribute__((aligned(128))) chan_t;
static chan_t ping, pong;
static bool c_full(void *in, frame *f) { (void)f; return ((chan_t *)in)->full; }
static bool c_not_full(void *in, frame *f) { (void)f; return !((chan_t *)in)->full; }

typedef struct { frame h; uint64_t i, n, sum; } pp_frame;
typedef struct { frame h; chan_t *c; uint64_t v; } op_frame;

/* ---------- pingpong: put and get inlined into the body, one frame a task --- */
static ren_ret ppA(task *t, frame *hf, char *sp, uint64_t in) {
  pp_frame *f = (pp_frame *)hf;
  uint64_t i, n, sum;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  i = 0; n = f->n; sum = 0;
loop:
  if (i == n) return (ren_ret){DONE, sum};
  inst_take(&ping.h);
  if (ping.full) {
    f->i = i; f->n = n; f->sum = sum; f->h.state = 1; f->h.sp = sp; t->top = hf;
    park_until(t, &ping.h, c_not_full);
    return (ren_ret){PENDING, 0};
  }
s1:
  ping.full = 1; ping.v = i; inst_release(&ping.h);
  inst_take(&pong.h);
  if (!pong.full) {
    f->i = i; f->n = n; f->sum = sum; f->h.state = 2; f->h.sp = sp; t->top = hf;
    park_until(t, &pong.h, c_full);
    return (ren_ret){PENDING, 0};
  }
s2:
  pong.full = 0; sum += pong.v; inst_release(&pong.h);
  i++;
  goto loop;
dispatch:
  i = f->i; n = f->n; sum = f->sum;
  switch (f->h.state) { case 1: goto s1; case 2: goto s2; }
  UNREACHABLE();
}
static ren_ret ppB(task *t, frame *hf, char *sp, uint64_t in) {
  pp_frame *f = (pp_frame *)hf;
  uint64_t i, n, v = 0;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  i = 0; n = f->n;
loop:
  if (i == n) return (ren_ret){DONE, 0};
  inst_take(&ping.h);
  if (!ping.full) {
    f->i = i; f->n = n; f->h.state = 1; f->h.sp = sp; t->top = hf;
    park_until(t, &ping.h, c_full);
    return (ren_ret){PENDING, 0};
  }
s1:
  ping.full = 0; v = ping.v + 1; inst_release(&ping.h);
  inst_take(&pong.h);
  if (pong.full) {
    f->i = i; f->n = n; f->sum = v; f->h.state = 2; f->h.sp = sp; t->top = hf;
    park_until(t, &pong.h, c_not_full);
    return (ren_ret){PENDING, 0};
  }
s2:
  pong.full = 1; pong.v = v; inst_release(&pong.h);
  i++;
  goto loop;
dispatch:
  i = f->i; n = f->n; v = f->sum;
  switch (f->h.state) { case 1: goto s1; case 2: goto s2; }
  UNREACHABLE();
}

/* ---------- pingpong_nested: put and get as child frames ---------- */
/* put(c, v): the channel is written into the frame by the caller, the value
   arrives in `in`. The innermost suspender: the only writer of t->top. */
OPATTR static ren_ret op_put(task *t, frame *hf, char *sp, uint64_t in) {
  op_frame *f = (op_frame *)hf;
  chan_t *c = f->c;
  uint64_t v;
  if (UNLIKELY(f->h.state != 0)) { v = f->v; goto ok; } /* resumed: we hold c */
  v = in;
  inst_take(&c->h);
  if (c->full) {
    f->v = v; f->h.state = 1; f->h.sp = sp; t->top = hf;
    park_until(t, &c->h, c_not_full);
    return (ren_ret){PENDING, 0};
  }
ok:
  c->full = 1; c->v = v; inst_release(&c->h);
  return (ren_ret){DONE, 0};
}
OPATTR static ren_ret op_get(task *t, frame *hf, char *sp, uint64_t in) {
  op_frame *f = (op_frame *)hf;
  chan_t *c = f->c;
  uint64_t v;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) goto ok;
  inst_take(&c->h);
  if (!c->full) {
    f->h.state = 1; f->h.sp = sp; t->top = hf;
    park_until(t, &c->h, c_full);
    return (ren_ret){PENDING, 0};
  }
ok:
  c->full = 0; v = c->v; inst_release(&c->h);
  return (ren_ret){DONE, v};
}

/* A call of a suspending function, as the emitter would write it:
   bump the callee's frame from sp, write its arguments and state 0, call it
   directly; on PENDING (cold) fill in the callee's header, spill what's
   live, record our state and sp, and return PENDING. */
#define CALL(FN, CH, ARG, ST, SPILL)                                      \
  {                                                                       \
    op_frame *c_ = (op_frame *)sp;                                        \
    char *csp_ = BUMP(t, sp, R16(sizeof(op_frame)));                      \
    c_->h.state = 0; c_->h.flags = 0; c_->c = (CH);                       \
    r = FN(t, &c_->h, csp_, (ARG));                                       \
    if (UNLIKELY(r.st == PENDING)) {                                      \
      c_->h.resume = FN; c_->h.parent = hf;                               \
      SPILL; f->h.state = (ST); f->h.sp = sp;                             \
      return r;                                                           \
    }                                                                     \
  }

static ren_ret ppA_nested(task *t, frame *hf, char *sp, uint64_t in) {
  pp_frame *f = (pp_frame *)hf;
  uint64_t i, n, sum;
  ren_ret r;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  i = 0; n = f->n; sum = 0;
loop:
  if (i == n) return (ren_ret){DONE, sum};
  CALL(op_put, &ping, i, 1, (f->i = i, f->n = n, f->sum = sum))
s1:
  CALL(op_get, &pong, 0, 2, (f->i = i, f->n = n, f->sum = sum))
s2:
  sum += r.v;
  i++;
  goto loop;
dispatch: /* cold: reload, then enter the body */
  i = f->i; n = f->n; sum = f->sum;
  r.st = DONE; r.v = in;
  switch (f->h.state) { case 1: goto s1; case 2: goto s2; }
  UNREACHABLE();
}
static ren_ret ppB_nested(task *t, frame *hf, char *sp, uint64_t in) {
  pp_frame *f = (pp_frame *)hf;
  uint64_t i, n;
  ren_ret r;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  i = 0; n = f->n;
loop:
  if (i == n) return (ren_ret){DONE, 0};
  CALL(op_get, &ping, 0, 1, (f->i = i, f->n = n))
s1:
  CALL(op_put, &pong, r.v + 1, 2, (f->i = i, f->n = n))
s2:
  i++;
  goto loop;
dispatch:
  i = f->i; n = f->n;
  r.st = DONE; r.v = in;
  switch (f->h.state) { case 1: goto s1; case 2: goto s2; }
  UNREACHABLE();
}

/* ---------- driver ---------- */
static bool run_once(const char *b, uint64_t n, double *ns) {
  scope root = {0, 2, NULL};
  uint64_t b0 = live_bytes;
  bool nested;
  if (!strcmp(b, "pingpong")) nested = false;
  else if (!strcmp(b, "pingpong_nested")) nested = true;
  else { fprintf(stderr, "unknown bench %s\n", b); exit(2); }
  memset(&ping, 0, sizeof ping);
  memset(&pong, 0, sizeof pong);
  uint32_t fs = R16(sizeof(pp_frame)) + (nested ? R16(sizeof(op_frame)) : 0);
  task *A = task_new(&root, fs, sizeof(pp_frame));
  task *B = task_new(&root, fs, sizeof(pp_frame));
  A->top->resume = nested ? ppA_nested : ppA;
  B->top->resume = nested ? ppB_nested : ppB;
  ((pp_frame *)A->top)->n = ((pp_frame *)B->top)->n = n;
  uint64_t t0 = now();
  rq_push(A);
  rq_push(B);
  run_all();
  *ns = ns_since(t0) / n;
  uint64_t got = A->result, want = n * (n + 1) / 2;
  bool ok = A->done && B->done && got == want && take_conflicts == 0 && root.live == 0 &&
            ping.h.wq_head == NULL && pong.h.wq_head == NULL;
  task_free(A);
  task_free(B);
  ok = ok && live_bytes == b0;
  if (!ok)
    fprintf(stderr, "FAIL %s n=%llu got=%llu want=%llu conflicts=%llu\n", b, (unsigned long long)n,
            (unsigned long long)got, (unsigned long long)want, (unsigned long long)take_conflicts);
  return ok;
}

int main(int argc, char **argv) {
  time_init();
  args_t a = parse_args(argc, argv, 1000000);
  if (a.check) {
    bool ok = true;
    const char *all[] = {"pingpong", "pingpong_nested"};
    uint64_t ns[] = {1, 2, 3, 1000, 100000};
    for (int i = 0; i < 2; i++)
      for (int j = 0; j < 5; j++) {
        double x;
        bool r = run_once(all[i], ns[j], &x);
        printf("CHECK lang=ren_reg bench=%s n=%llu %s\n", all[i], (unsigned long long)ns[j], r ? "ok" : "FAIL");
        ok &= r;
      }
    return ok ? 0 : 1;
  }
  double ns[64];
  bool ok = true;
  uint64_t sw0 = switches;
  for (int i = 0; i < a.reps; i++) ok &= run_once(a.bench, a.n, &ns[i]);
  double sw = (double)(switches - sw0) / ((double)a.n * a.reps);
  double mn = ns[0];
  for (int i = 1; i < a.reps; i++) mn = ns[i] < mn ? ns[i] : mn;
  char rl[64 * 24];
  double mx = reps_list(ns, a.reps, rl, sizeof rl);
  printf("SWITCH lang=ren_reg bench=%s n=%llu reps=%d ns_per_op=%.2f min_ns_per_op=%.2f max_ns_per_op=%.2f "
         "switches_per_op=%.3f task_header=%zu reps_ns=%s check=%s\n",
         a.bench, (unsigned long long)a.n, a.reps, median(ns, a.reps), mn, mx, sw, sizeof(task), rl,
         ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}
