// The single runtime's task switch, as release would emit it (Ren, Async.single()).
//
// Representation (foundations.md decision 12): stackless frames. Only a
// function whose `uses` reaches a dependency can suspend; release compiles it
// to a state machine whose frame lives on its task's frame stack, a bump
// allocator. A task is one heap object: a header plus an inline first segment
// of the frame stack, sized by release to the deepest frame chain it can see
// (here the task body plus any child frame). Deeper or unknown recursion
// grows the stack in 4 KiB chunks. Child frames that release inlines (known
// handler operations, decision 4) cost nothing: `pingpong` has the channel's
// put and get inlined into the task's frame; `pingpong_nested` pushes them as
// child frames, which is what a debug build or a non-inlined op would do.
//
// The single runtime (decision 9): no atomics, no locks. Run queue is an
// intrusive FIFO. An instance has a plain `held` byte (asserted never to
// conflict: no op here suspends while holding it) and a FIFO of waiters,
// each with the condition its `Async.until` passed. Releasing an instance
// resumes the first waiter whose condition holds and hands it the instance
// (decision 7: no lost wakeups, no re-check loop). Each task carries its
// current heap pointer, swapped at each switch (compiler.md, "One current
// heap a task"). Ren's heap is modelled as per-thread size-class free lists
// over 64 KiB slabs; heap_allocs counts objects, sys_allocs counts malloc.

#include "common.h"

/* ---------- Ren's heap (per-thread free lists) ---------- */
typedef struct freeblk { struct freeblk *next; } freeblk;
#define NCLASS 600 /* 16-byte classes up to 9.6 KB */
#define SLAB (64 * 1024)
static freeblk *fl[NCLASS];
static uint64_t n_obj, n_sys, live_bytes;
static void *cur_heap; /* the current task's heap pointer: one store per switch */

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
  if (__builtin_expect(!b, 0)) b = refill(c);
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

/* ---------- tasks and frames ---------- */
typedef struct task task;
typedef struct frame frame;
typedef enum { DONE = 0, SUSPEND = 1 } rstat;
typedef rstat (*resume_fn)(task *, frame *);
typedef bool (*cond_fn)(void *inst, frame *waiting);
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
typedef struct scope {
  uint32_t live, max;
  task *room_waiter, *end_waiter;
} scope;
struct task {
  task *next;      /* run queue or an instance's waiter queue */
  frame *top;      /* innermost frame */
  char *sp, *limit; /* the frame stack's bump pointer */
  chunk *chunk;    /* overflow chunks, NULL while in the inline segment */
  scope *scope;
  task *joiner;
  cond_fn cond;    /* while parked in Async.until */
  void *heap;      /* this task's current heap */
  uint64_t result;
  uint32_t size;   /* allocation size, for the free */
  uint8_t done, has_handle, cancelled, _pad;
  _Alignas(16) char frames[];
};
#define R16(x) (((x) + 15u) & ~15u)
#define CHUNK 4096

static task *rq_head, *rq_tail, *current;
static uint64_t take_conflicts, switches;

static inline void rq_push(task *t) {
  t->next = NULL;
  if (rq_tail) rq_tail->next = t;
  else rq_head = t;
  rq_tail = t;
}

__attribute__((noinline)) static void frame_grow(task *t, uint32_t size) {
  uint64_t cap = size + sizeof(chunk) > CHUNK ? R16(size + sizeof(chunk)) : CHUNK;
  chunk *c = heap_alloc(cap);
  c->prev_sp = t->sp;
  c->prev_limit = t->limit;
  c->prev = t->chunk;
  c->cap = cap;
  t->chunk = c;
  t->sp = (char *)(c + 1);
  t->limit = (char *)c + cap;
}
static inline frame *frame_push(task *t, uint32_t size, resume_fn r, frame *parent) {
  size = R16(size);
  if (__builtin_expect(t->sp + size > t->limit, 0)) frame_grow(t, size);
  frame *f = (frame *)t->sp;
  t->sp += size;
  f->resume = r;
  f->parent = parent;
  f->state = 0;
  f->size = size;
  return f;
}
static inline void frame_pop(task *t, frame *f) {
  t->sp = (char *)f;
  if (__builtin_expect(t->chunk && t->sp == (char *)(t->chunk + 1), 0)) {
    chunk *c = t->chunk;
    t->sp = c->prev_sp;
    t->limit = c->prev_limit;
    t->chunk = c->prev;
    heap_free(c, c->cap);
  }
}

/* A task is one allocation: header + its inline frame segment. */
static task *task_new(scope *s, uint32_t frames_size, uint32_t body_size, resume_fn body, bool handle) {
  uint32_t sz = (uint32_t)sizeof(task) + R16(frames_size);
  task *t = heap_alloc(sz);
  t->size = sz;
  t->sp = t->frames;
  t->limit = t->frames + R16(frames_size);
  t->chunk = NULL;
  t->scope = s;
  t->joiner = NULL;
  t->cond = NULL;
  t->heap = cur_heap;
  t->result = 0;
  t->done = 0;
  t->has_handle = handle;
  t->cancelled = 0;
  t->top = frame_push(t, body_size, body, NULL);
  s->live++;
  return t;
}
static inline void task_free(task *t) { heap_free(t, t->size); }

static void task_finish(task *t) {
  scope *s = t->scope;
  t->done = 1;
  s->live--;
  if (t->joiner) rq_push(t->joiner);
  else if (!t->has_handle) task_free(t);
  if (s->room_waiter && s->live < s->max) {
    rq_push(s->room_waiter);
    s->room_waiter = NULL;
  }
  if (s->live == 0 && s->end_waiter) {
    rq_push(s->end_waiter);
    s->end_waiter = NULL;
  }
}

/* Resume the task's innermost frame; a frame that finishes resumes its parent. */
static inline void step(task *t) {
  frame *f = t->top;
  while (f->resume(t, f) == DONE) {
    frame *p = f->parent;
    frame_pop(t, f);
    if (!p) {
      task_finish(t);
      return;
    }
    t->top = f = p;
  }
}
static void run_all(void) {
  task *t;
  while ((t = rq_head)) {
    rq_head = t->next;
    if (!rq_head) rq_tail = NULL;
    current = t;
    cur_heap = t->heap;
    switches++;
    step(t);
  }
  current = NULL;
}

/* ---------- handler instances (single runtime: no lock) ---------- */
typedef struct {
  uint8_t held;
  task *wq_head, *wq_tail;
} inst_t;

static inline void inst_take(inst_t *in) {
  if (__builtin_expect(in->held, 0)) take_conflicts++; /* invariant: stays 0 */
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
      in->held = 1; /* handed to the waiter */
      rq_push(t);
      return;
    }
  }
}
static inline void inst_release(inst_t *in) {
  in->held = 0;
  if (in->wq_head) wake_first(in);
}
/* Async.until(cond) inside an operation whose condition is false: release the
   instance, then queue. Conditions read only the handler's state, so a release
   after a section that wrote nothing can't make one true: release emits no
   wake check there. Every `until` here is first in its operation, so none
   scans. (The first build scanned on every park: 100k parks took 15 s, O(n^2).) */
static inline void park_until(task *t, inst_t *in, cond_fn c) {
  in->held = 0;
  t->cond = c;
  t->next = NULL;
  if (in->wq_tail) in->wq_tail->next = t;
  else in->wq_head = t;
  in->wq_tail = t;
}

/* =================== bench 1: ping-pong through one-slot channels ========= */
typedef struct {
  inst_t h;
  uint8_t full;
  uint64_t v;
} __attribute__((aligned(128))) chan_t;
static chan_t ping, pong;
static bool c_full(void *in, frame *f) { (void)f; return ((chan_t *)in)->full; }
static bool c_not_full(void *in, frame *f) { (void)f; return !((chan_t *)in)->full; }

typedef struct { frame f; uint64_t i, n, sum; } pp_frame;

/* put and get inlined into the task body: one frame a task. */
static rstat ppA(task *t, frame *ff) {
  pp_frame *f = (pp_frame *)ff;
  switch (f->f.state) { case 1: goto put_ok; case 2: goto get_ok; }
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  inst_take(&ping.h);
  if (ping.full) { f->f.state = 1; park_until(t, &ping.h, c_not_full); return SUSPEND; }
put_ok:
  ping.full = 1; ping.v = f->i; inst_release(&ping.h);
  inst_take(&pong.h);
  if (!pong.full) { f->f.state = 2; park_until(t, &pong.h, c_full); return SUSPEND; }
get_ok:
  pong.full = 0; f->sum += pong.v; inst_release(&pong.h);
  f->i++;
  goto loop;
}
static rstat ppB(task *t, frame *ff) {
  pp_frame *f = (pp_frame *)ff;
  uint64_t v;
  switch (f->f.state) { case 1: goto get_ok; case 2: goto put_ok; }
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  inst_take(&ping.h);
  if (!ping.full) { f->f.state = 1; park_until(t, &ping.h, c_full); return SUSPEND; }
get_ok:
  ping.full = 0; f->sum = ping.v + 1; inst_release(&ping.h);
  inst_take(&pong.h);
  if (pong.full) { f->f.state = 2; park_until(t, &pong.h, c_not_full); return SUSPEND; }
put_ok:
  v = f->sum; pong.full = 1; pong.v = v; inst_release(&pong.h);
  f->i++;
  goto loop;
}

/* The same, with put and get as child frames on the task's frame stack. */
typedef struct { frame f; chan_t *c; uint64_t v; } op_frame;
static rstat op_put(task *t, frame *ff) {
  op_frame *f = (op_frame *)ff;
  if (f->f.state == 1) goto ok;
  inst_take(&f->c->h);
  if (f->c->full) { f->f.state = 1; park_until(t, &f->c->h, c_not_full); return SUSPEND; }
ok:
  f->c->full = 1; f->c->v = f->v; inst_release(&f->c->h);
  return DONE;
}
static rstat op_get(task *t, frame *ff) {
  op_frame *f = (op_frame *)ff;
  if (f->f.state == 1) goto ok;
  inst_take(&f->c->h);
  if (!f->c->full) { f->f.state = 1; park_until(t, &f->c->h, c_full); return SUSPEND; }
ok:
  f->c->full = 0; t->result = f->c->v; inst_release(&f->c->h);
  return DONE;
}
/* A call to a function that can suspend: push its frame, run it directly; if
   it suspends, so does the caller, and the scheduler resumes the child first. */
#define CALL(T, F, FN, CH, VAL, ST, LABEL)                              \
  do {                                                                  \
    op_frame *c_ = (op_frame *)frame_push(T, sizeof(op_frame), FN, &(F)->f); \
    c_->c = (CH); c_->v = (VAL);                                        \
    (F)->f.state = ST; (T)->top = &c_->f;                               \
    if (FN(T, &c_->f) == SUSPEND) return SUSPEND;                       \
    (T)->top = &(F)->f; frame_pop(T, &c_->f);                           \
  } while (0);                                                          \
  LABEL:
static rstat ppA_nested(task *t, frame *ff) {
  pp_frame *f = (pp_frame *)ff;
  switch (f->f.state) { case 1: goto put_ok; case 2: goto get_ok; }
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  CALL(t, f, op_put, &ping, f->i, 1, put_ok)
  CALL(t, f, op_get, &pong, 0, 2, get_ok)
  f->sum += t->result;
  f->i++;
  goto loop;
}
static rstat ppB_nested(task *t, frame *ff) {
  pp_frame *f = (pp_frame *)ff;
  switch (f->f.state) { case 1: goto get_ok; case 2: goto put_ok; }
  f->i = 0;
loop:
  if (f->i == f->n) return DONE;
  CALL(t, f, op_get, &ping, 0, 1, get_ok)
  CALL(t, f, op_put, &pong, t->result + 1, 2, put_ok)
  f->i++;
  goto loop;
}

/* =================== bench 2: spawn + join, and spawn in batches ========== */
static rstat empty_body(task *t, frame *f) { (void)f; t->result = 1; return DONE; }

typedef struct { frame f; uint64_t i, n, sum; scope s; task *h; } sj_frame;
static rstat spawn_join_main(task *t, frame *ff) {
  sj_frame *f = (sj_frame *)ff;
  switch (f->f.state) { case 1: goto room; case 2: goto joined; case 3: return DONE; }
  f->i = 0;
loop:
  if (f->i == f->n) goto end;
room:
  if (f->s.live >= f->s.max) { f->f.state = 1; f->s.room_waiter = t; return SUSPEND; }
  f->h = task_new(&f->s, sizeof(frame), sizeof(frame), empty_body, true);
  rq_push(f->h);
  if (!f->h->done) { f->f.state = 2; f->h->joiner = t; return SUSPEND; }
joined:
  f->sum += f->h->result;
  task_free(f->h);
  f->i++;
  goto loop;
end:
  if (f->s.live) { f->f.state = 3; f->s.end_waiter = t; return SUSPEND; }
  return DONE;
}
static rstat spawn_batch_main(task *t, frame *ff) {
  sj_frame *f = (sj_frame *)ff;
  switch (f->f.state) { case 1: goto room; case 3: return DONE; }
  f->i = 0;
loop:
  if (f->i == f->n) goto end;
room:
  if (f->s.live >= f->s.max) { f->f.state = 1; f->s.room_waiter = t; return SUSPEND; }
  rq_push(task_new(&f->s, sizeof(frame), sizeof(frame), empty_body, false));
  f->i++;
  goto loop;
end:
  if (f->s.live) { f->f.state = 3; f->s.end_waiter = t; return SUSPEND; }
  return DONE;
}

/* =================== bench 3: N tasks parked on a gate ==================== */
typedef struct {
  inst_t h;
  uint8_t open;
  uint64_t count;
} __attribute__((aligned(128))) gate_t;
static gate_t gate;
static bool g_open(void *in, frame *f) { (void)f; return ((gate_t *)in)->open; }
static rstat gate_waiter(task *t, frame *f) {
  if (f->state == 1) goto ok;
  inst_take(&gate.h);
  if (!gate.open) { f->state = 1; park_until(t, &gate.h, g_open); return SUSPEND; }
ok:
  gate.count++;
  inst_release(&gate.h);
  return DONE;
}
static uint64_t park_t0, park_t1, park_t2, park_bytes0, park_bytes1, park_fp0, park_fp1;
static rstat park_main(task *t, frame *ff) {
  sj_frame *f = (sj_frame *)ff;
  switch (f->f.state) { case 1: goto ticked; case 2: goto all_woken; }
  park_t0 = now();
  park_bytes0 = live_bytes;
  park_fp0 = footprint();
  for (f->i = 0; f->i < f->n; f->i++) /* max = n: spawn never waits */
    rq_push(task_new(&f->s, sizeof(frame), sizeof(frame), gate_waiter, false));
  f->f.state = 1; /* Async.tick(): every runnable task runs until it waits */
  rq_push(t);
  return SUSPEND;
ticked:
  park_bytes1 = live_bytes;
  park_fp1 = footprint();
  park_t1 = now();
  inst_take(&gate.h);
  gate.open = 1;
  inst_release(&gate.h);
  if (f->s.live) { f->f.state = 2; f->s.end_waiter = t; return SUSPEND; }
all_woken:
  park_t2 = now();
  return DONE;
}

/* =================== bench 4: fan-out on one instance ===================== */
typedef struct {
  inst_t h;
  uint64_t v;
} __attribute__((aligned(128))) counter_t;
static counter_t counter;
typedef struct { frame f; uint64_t w; uint32_t k; } fo_frame;
static rstat fan_worker(task *t, frame *ff) {
  fo_frame *f = (fo_frame *)ff;
  (void)t;
  for (f->k = 0; f->k < 10; f->k++) {
    inst_take(&counter.h);
    counter.v += f->w + f->k;
    inst_release(&counter.h);
  }
  return DONE;
}
static rstat fan_worker_yield(task *t, frame *ff) {
  fo_frame *f = (fo_frame *)ff;
  if (f->f.state == 1) goto yielded;
  for (f->k = 0; f->k < 10; f->k++) {
    inst_take(&counter.h);
    counter.v += f->w + f->k;
    inst_release(&counter.h);
    f->f.state = 1; /* Async.yield() */
    rq_push(t);
    return SUSPEND;
  yielded:;
  }
  return DONE;
}
static bool fan_yield;
static rstat fan_main(task *t, frame *ff) {
  sj_frame *f = (sj_frame *)ff;
  if (f->f.state == 3) return DONE;
  for (f->i = 0; f->i < f->n; f->i++) {
    task *w = task_new(&f->s, sizeof(fo_frame), sizeof(fo_frame), fan_yield ? fan_worker_yield : fan_worker, false);
    ((fo_frame *)w->top)->w = f->i;
    rq_push(w);
  }
  if (f->s.live) { f->f.state = 3; f->s.end_waiter = t; return SUSPEND; }
  return DONE;
}

/* =================== check-only: deep recursion across a suspension ======= */
typedef struct { frame f; uint32_t d; } deep_frame;
static rstat deep(task *t, frame *ff) {
  deep_frame *f = (deep_frame *)ff;
  switch (f->f.state) { case 1: goto back; case 2: t->result = 0; return DONE; }
  if (f->d == 0) { f->f.state = 2; rq_push(t); return SUSPEND; } /* yield at the bottom */
  {
    deep_frame *c = (deep_frame *)frame_push(t, sizeof(deep_frame), deep, ff);
    c->d = f->d - 1;
    f->f.state = 1;
    t->top = &c->f;
    if (deep(t, &c->f) == SUSPEND) return SUSPEND;
    t->top = ff;
    frame_pop(t, &c->f);
  }
back:
  t->result += f->d;
  return DONE;
}
static bool check_deep(void) {
  scope s = {0, 8, NULL, NULL};
  task *ts[3];
  uint32_t depth[3] = {10, 300, 1000};
  for (int i = 0; i < 3; i++) {
    ts[i] = task_new(&s, sizeof(deep_frame) * 4, sizeof(deep_frame), deep, true);
    ((deep_frame *)ts[i]->top)->d = depth[i];
    rq_push(ts[i]);
  }
  run_all();
  bool ok = true;
  for (int i = 0; i < 3; i++) {
    uint64_t d = depth[i];
    ok &= ts[i]->done && ts[i]->result == d * (d + 1) / 2 && ts[i]->chunk == NULL;
    task_free(ts[i]);
  }
  return ok && s.live == 0;
}

/* =================== driver ============================================== */
typedef struct {
  double ns;       /* the bench's headline ns per op */
  double extra_ns; /* park: spawn+park ns a task; fanout: ns a task */
  double bytes;    /* park: heap bytes a parked task */
  double fp_bytes; /* park: footprint bytes a parked task (first rep) */
  double objs, sys; /* heap objects / mallocs per op */
  bool ok;
} result_t;

static result_t run_once(const args_t *a) {
  result_t r = {0};
  scope root = {0, 1, NULL, NULL};
  uint64_t o0 = n_obj, s0 = n_sys, b0 = live_bytes, n = a->n, ops = n;
  uint64_t t0 = now();
  task *m;
  const char *b = a->bench;
  uint64_t want = 0, got = 0;
  if (!strcmp(b, "pingpong") || !strcmp(b, "pingpong_nested")) {
    bool nested = b[8] == '_';
    memset(&ping, 0, sizeof ping);
    memset(&pong, 0, sizeof pong);
    uint32_t fs = sizeof(pp_frame) + (nested ? R16(sizeof(op_frame)) : 0);
    root.max = 2;
    task *A = task_new(&root, fs, sizeof(pp_frame), nested ? ppA_nested : ppA, true);
    task *B = task_new(&root, fs, sizeof(pp_frame), nested ? ppB_nested : ppB, true);
    ((pp_frame *)A->top)->n = ((pp_frame *)B->top)->n = n;
    ((pp_frame *)A->top)->sum = 0;
    uint64_t *sum = &((pp_frame *)A->top)->sum;
    rq_push(A);
    rq_push(B);
    run_all();
    /* A's frame is popped but its memory is still the task's: read it before the free. */
    got = *sum;
    want = n * (n + 1) / 2;
    r.ok = A->done && B->done;
    task_free(A);
    task_free(B);
  } else if (!strcmp(b, "spawn_join") || !strcmp(b, "spawn_batch")) {
    bool join = b[6] == 'j';
    m = task_new(&root, sizeof(sj_frame), sizeof(sj_frame), join ? spawn_join_main : spawn_batch_main, true);
    sj_frame *f = (sj_frame *)m->top;
    f->n = n;
    f->sum = 0;
    f->s = (scope){0, join ? 64 : (uint32_t)a->max, NULL, NULL};
    rq_push(m);
    run_all();
    got = join ? f->sum : n;
    want = n;
    r.ok = m->done && f->s.live == 0;
    task_free(m);
  } else if (!strcmp(b, "park")) {
    memset(&gate, 0, sizeof gate);
    m = task_new(&root, sizeof(sj_frame), sizeof(sj_frame), park_main, true);
    sj_frame *f = (sj_frame *)m->top;
    f->n = n;
    f->s = (scope){0, (uint32_t)n, NULL, NULL};
    rq_push(m);
    run_all();
    got = gate.count;
    want = n;
    r.ok = m->done && f->s.live == 0 && gate.h.wq_head == NULL;
    task_free(m);
  } else if (!strcmp(b, "fanout") || !strcmp(b, "fanout_yield")) {
    fan_yield = b[6] == '_';
    counter.v = 0;
    m = task_new(&root, sizeof(sj_frame), sizeof(sj_frame), fan_main, true);
    sj_frame *f = (sj_frame *)m->top;
    f->n = n;
    f->s = (scope){0, (uint32_t)n, NULL, NULL};
    rq_push(m);
    run_all();
    got = counter.v;
    want = 10 * (n * (n - 1) / 2) + 45 * n;
    ops = n * 10;
    r.ok = m->done && f->s.live == 0;
    task_free(m);
  } else {
    fprintf(stderr, "unknown bench %s\n", b);
    exit(2);
  }
  double total = ns_since(t0);
  r.ok = r.ok && got == want && take_conflicts == 0 && live_bytes == b0 && root.live == 0;
  if (!r.ok)
    fprintf(stderr, "FAIL %s n=%llu got=%llu want=%llu conflicts=%llu leak=%lld\n", b,
            (unsigned long long)n, (unsigned long long)got, (unsigned long long)want,
            (unsigned long long)take_conflicts, (long long)(live_bytes - b0));
  r.objs = (double)(n_obj - o0) / ops;
  r.sys = (double)(n_sys - s0) / ops;
  if (!strcmp(b, "park")) {
    r.ns = (double)(park_t2 - park_t1) * tick_ns / n;
    r.extra_ns = (double)(park_t1 - park_t0) * tick_ns / n;
    r.bytes = (double)(park_bytes1 - park_bytes0) / n;
    r.fp_bytes = (double)(int64_t)(park_fp1 - park_fp0) / n;
  } else if (!strncmp(b, "fanout", 6)) {
    r.ns = total / ops;
    r.extra_ns = total / n;
  } else {
    r.ns = total / ops;
  }
  return r;
}

int main(int argc, char **argv) {
  time_init();
  args_t a = parse_args(argc, argv, 1000000);
  if (a.check) {
    bool ok = check_deep();
    const char *all[] = {"pingpong", "pingpong_nested", "spawn_join", "spawn_batch", "park", "fanout", "fanout_yield"};
    uint64_t ns[] = {1000, 1000, 1000, 1000, 1000, 100, 100};
    for (int i = 0; i < 7; i++) {
      args_t c = a;
      c.bench = all[i];
      c.n = ns[i];
      c.max = 64;
      result_t r = run_once(&c);
      printf("CHECK lang=ren_c bench=%s n=%llu %s\n", all[i], (unsigned long long)c.n, r.ok ? "ok" : "FAIL");
      ok &= r.ok;
    }
    printf("CHECK lang=ren_c bench=deep_frames %s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
  }
  double ns[64], ex[64];
  result_t r0 = {0};
  bool ok = true;
  for (int i = 0; i < a.reps; i++) {
    result_t r = run_once(&a);
    if (i == 0) r0 = r;
    ns[i] = r.ns;
    ex[i] = r.extra_ns;
    ok &= r.ok;
  }
  double mn = ns[0];
  for (int i = 1; i < a.reps; i++) mn = ns[i] < mn ? ns[i] : mn;
  char rl[64 * 24];
  double mx = reps_list(ns, a.reps, rl, sizeof rl);
  printf("SWITCH lang=ren_c bench=%s n=%llu max=%llu reps=%d ns_per_op=%.2f min_ns_per_op=%.2f "
         "extra_ns=%.2f heap_allocs_per_op=%.4f sys_allocs_per_op=%.5f bytes_per_task=%.1f "
         "footprint_per_task=%.1f task_header=%zu max_ns_per_op=%.2f reps_ns=%s check=%s\n",
         a.bench, (unsigned long long)a.n, (unsigned long long)a.max, a.reps, median(ns, a.reps), mn,
         median(ex, a.reps), r0.objs, r0.sys, r0.bytes, r0.fp_bytes, sizeof(task), mx, rl, ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}
