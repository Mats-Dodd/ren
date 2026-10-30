// The raw C floor: hand-written state machines with no general runtime.
// What a C programmer writes for exactly these four programs: each task is a
// small struct with a state int and a fixed step function, the run queue is
// intrusive, a wait is one pointer on the thing waited for, and the wakeup
// knows who to wake. No frames, no scopes, no conditions, no heap pointer,
// no held byte. Tasks come from a free list; mallocs are counted.
#include "common.h"

typedef struct rtask rtask;
typedef void (*step_fn)(rtask *);
struct rtask {
  rtask *next;
  step_fn step;
  uint32_t state, k;
  uint64_t a, b; /* per-task data */
};
static rtask *rq_head, *rq_tail, *freel;
static uint64_t n_obj, n_sys;
static inline void push(rtask *t) {
  t->next = NULL;
  if (rq_tail) rq_tail->next = t;
  else rq_head = t;
  rq_tail = t;
}
static void run(void) {
  rtask *t;
  while ((t = rq_head)) {
    rq_head = t->next;
    if (!rq_head) rq_tail = NULL;
    t->step(t);
  }
}
static inline rtask *alloc_task(void) {
  n_obj++;
  if (__builtin_expect(!freel, 0)) {
    enum { K = 1024 };
    rtask *slab = malloc(K * sizeof(rtask));
    n_sys++;
    for (int i = 0; i < K; i++) { slab[i].next = freel; freel = &slab[i]; }
  }
  rtask *t = freel;
  freel = t->next;
  return t;
}
static inline void free_task(rtask *t) { t->next = freel; freel = t; }

/* ---- ping-pong: one-slot channels whose waiter is one pointer ---- */
typedef struct { int full; uint64_t v; rtask *waiter; } __attribute__((aligned(128))) rchan;
static rchan ping, pong;
static uint64_t N, sumA;
static inline void wake(rchan *c) { if (c->waiter) { push(c->waiter); c->waiter = NULL; } }
static void stepA(rtask *t) {
  for (;;) {
    if (t->state == 0) {
      if (t->a == N) return;
      if (ping.full) { ping.waiter = t; return; }
      ping.full = 1; ping.v = t->a; wake(&ping); t->state = 1;
    }
    if (!pong.full) { pong.waiter = t; return; }
    pong.full = 0; sumA += pong.v; wake(&pong); t->state = 0; t->a++;
  }
}
static void stepB(rtask *t) {
  for (;;) {
    if (t->state == 0) {
      if (t->a == N) return;
      if (!ping.full) { ping.waiter = t; return; }
      ping.full = 0; t->b = ping.v + 1; wake(&ping); t->state = 1;
    }
    if (pong.full) { pong.waiter = t; return; }
    pong.full = 1; pong.v = t->b; wake(&pong); t->state = 0; t->a++;
  }
}

/* ---- spawn + join / batch ---- */
static uint64_t live, joined_sum;
static rtask *parent;
static int parent_waits;
static void child(rtask *t) {
  joined_sum += 1;
  live--;
  free_task(t);
  if (parent_waits) { parent_waits = 0; push(parent); }
}
static uint64_t MAXL;
static void spawner(rtask *t) { /* a = i; one at a time if MAXL==1 */
  while (t->a < N) {
    if (live >= MAXL) { parent_waits = 1; return; }
    rtask *c = alloc_task();
    c->step = child;
    live++;
    push(c);
    t->a++;
  }
  if (live) { parent_waits = 1; return; }
  t->state = 9; /* done */
}

/* ---- park: N tasks on one gate, a list of waiters ---- */
typedef struct { int open; uint64_t count; rtask *head; } rgate;
static rgate gate;
static void gwaiter(rtask *t) {
  if (!gate.open) { t->next = gate.head; gate.head = t; return; }
  gate.count++;
  live--;
  free_task(t);
}

/* ---- fan-out ---- */
static uint64_t counter;
static void fworker(rtask *t) {
  for (uint32_t k = 0; k < 10; k++) counter += t->a + k;
  live--;
  free_task(t);
}
static void fworker_yield(rtask *t) {
  counter += t->a + t->k;
  if (++t->k < 10) { push(t); return; }
  live--;
  free_task(t);
}

typedef struct { double ns, extra; double objs, sys, bytes; bool ok; } res;
static res run_once(const args_t *a) {
  res r = {0};
  uint64_t o0 = n_obj, s0 = n_sys, n = a->n, ops = n, got = 0, want = 0;
  N = n;
  uint64_t t0 = now();
  const char *b = a->bench;
  if (!strcmp(b, "pingpong")) {
    memset(&ping, 0, sizeof ping); memset(&pong, 0, sizeof pong); sumA = 0;
    rtask A = {.step = stepA}, B = {.step = stepB};
    push(&A); push(&B); run();
    got = sumA; want = n * (n + 1) / 2;
    r.ok = A.a == n && B.a == n;
  } else if (!strcmp(b, "spawn_join") || !strcmp(b, "spawn_batch")) {
    MAXL = b[6] == 'j' ? 1 : a->max;
    live = 0; joined_sum = 0; parent_waits = 0;
    rtask P = {.step = spawner};
    parent = &P;
    push(&P); run();
    got = joined_sum; want = n;
    r.ok = P.state == 9 && live == 0;
  } else if (!strcmp(b, "park")) {
    memset(&gate, 0, sizeof gate);
    live = n;
    for (uint64_t i = 0; i < n; i++) { rtask *t = alloc_task(); t->step = gwaiter; push(t); }
    run(); /* all park */
    uint64_t t1 = now();
    r.extra = (double)(t1 - t0) * tick_ns / n;
    gate.open = 1; /* wake all: walk the list */
    for (rtask *t = gate.head, *nx; t; t = nx) { nx = t->next; push(t); }
    gate.head = NULL;
    run();
    r.ns = ns_since(t1) / n;
    r.bytes = sizeof(rtask);
    got = gate.count; want = n;
    r.ok = live == 0;
  } else if (!strcmp(b, "fanout") || !strcmp(b, "fanout_yield")) {
    bool y = b[6] == '_';
    counter = 0; live = n;
    for (uint64_t i = 0; i < n; i++) {
      rtask *t = alloc_task(); t->step = y ? fworker_yield : fworker; t->a = i; t->k = 0; push(t);
    }
    run();
    got = counter; want = 10 * (n * (n - 1) / 2) + 45 * n; ops = 10 * n;
    r.ok = live == 0;
  } else {
    fprintf(stderr, "raw: no bench %s\n", b);
    exit(2);
  }
  double total = ns_since(t0);
  if (strcmp(b, "park")) { r.ns = total / ops; r.extra = total / n; }
  r.ok = r.ok && got == want;
  if (!r.ok) fprintf(stderr, "FAIL raw %s got=%llu want=%llu\n", b, (unsigned long long)got, (unsigned long long)want);
  r.objs = (double)(n_obj - o0) / ops;
  r.sys = (double)(n_sys - s0) / ops;
  return r;
}

int main(int argc, char **argv) {
  time_init();
  args_t a = parse_args(argc, argv, 1000000);
  if (a.check) {
    const char *all[] = {"pingpong", "spawn_join", "spawn_batch", "park", "fanout", "fanout_yield"};
    uint64_t ns[] = {1000, 1000, 1000, 1000, 100, 100};
    bool ok = true;
    for (int i = 0; i < 6; i++) {
      args_t c = a; c.bench = all[i]; c.n = ns[i]; c.max = 64;
      res r = run_once(&c);
      printf("CHECK lang=raw_c bench=%s n=%llu %s\n", all[i], (unsigned long long)c.n, r.ok ? "ok" : "FAIL");
      ok &= r.ok;
    }
    return ok ? 0 : 1;
  }
  double ns[64], ex[64];
  res r0 = {0};
  bool ok = true;
  for (int i = 0; i < a.reps; i++) {
    res r = run_once(&a);
    if (!i) r0 = r;
    ns[i] = r.ns; ex[i] = r.extra; ok &= r.ok;
  }
  double mn = ns[0];
  for (int i = 1; i < a.reps; i++) mn = ns[i] < mn ? ns[i] : mn;
  char rl[64 * 24];
  double mx = reps_list(ns, a.reps, rl, sizeof rl);
  printf("SWITCH lang=raw_c bench=%s n=%llu max=%llu reps=%d ns_per_op=%.2f min_ns_per_op=%.2f "
         "extra_ns=%.2f heap_allocs_per_op=%.4f sys_allocs_per_op=%.5f bytes_per_task=%.1f "
         "footprint_per_task=0 task_header=%zu max_ns_per_op=%.2f reps_ns=%s check=%s\n",
         a.bench, (unsigned long long)a.n, (unsigned long long)a.max, a.reps, median(ns, a.reps), mn,
         median(ex, a.reps), r0.objs, r0.sys, r0.bytes, sizeof(rtask), mx, rl, ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}
