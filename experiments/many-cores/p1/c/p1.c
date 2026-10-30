// P1, the cost of a hop (foundations.md, Staging, phase one of the
// many-cores experiments). One task, one handler instance, operations of
// 10 ns to 10 us of work, run five ways:
//
//   call            the instance isn't shared: the exclusion is skipped
//                   (decision 10, last bullet of "operations don't
//                   interleave"), so an operation is a plain call.
//   take            the instance is shared: the operation takes it
//                   (uncontended acquire of its lock word), runs, lets go.
//   hop_spin        the instance lives on a home core: the operation is a
//                   message pushed on the home core's MPSC queue; the home
//                   core runs it and replies. Both sides spin.
//   hop_park        the same, with the home core parking (os_sync ulock)
//                   whenever its queue is empty; the caller spins for the
//                   reply. Ops back to back.
//   hop_park_cold   hop_park with a 50 us idle gap (untimed) before each
//                   op, so the home core is really asleep when it arrives.
//   hop_park_both   hop_park with the caller also parking (ulock) for its
//                   reply: a worker with nothing else to run.
//   hop_condvar     hop_park_both with pthread mutex + condvar for both
//                   sleeps instead of ulock.
//
// See ../README.md for how this maps to Ren and what is uncertain.

#include <mach/mach_time.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE 128 /* Apple M-series cache line */
#define SEED 0x9E3779B97F4A7C15ull

static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }

/* ---------- time ---------- */
static double tick_ns;
static inline uint64_t now(void) { return mach_absolute_time(); }

/* ---------- the instance: a lock word and the handler's state ---------- */
typedef struct {
  _Atomic uint32_t lock; /* 0 free, 1 held, 2 held with parked waiters */
  uint32_t _pad;
  uint64_t state; /* the handler's var */
  uint64_t ops;   /* operations run, for checking */
  uint64_t slow;  /* lock slow paths taken (must stay 0: one task) */
} __attribute__((aligned(LINE))) instance_t;

static void instance_init(instance_t *in) {
  memset(in, 0, sizeof *in);
  in->state = SEED;
}

/* The operation: `iters` dependent mix steps on the state. Not inlined, as
   a handler operation reached through evidence would not be. */
__attribute__((noinline)) static uint64_t op_run(instance_t *in, uint32_t iters) {
  uint64_t s = in->state;
  for (uint32_t i = 0; i < iters; i++) {
    s ^= s >> 29;
    s *= 0xBF58476D1CE4E5B9ull;
  }
  in->state = s;
  in->ops++;
  return s;
}

/* Taking the instance: decision 10's uncontended path. A CAS to take it, a
   swap to let go; the slow paths park on the lock word (fair queueing is
   P3's subject; here there is one task, so they never run). */
__attribute__((noinline)) static void lock_slow(instance_t *in) {
  while (atomic_exchange_explicit(&in->lock, 2, memory_order_acquire) != 0)
    os_sync_wait_on_address(&in->lock, 2, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
  in->slow++; /* held now */
}
static inline void take(instance_t *in) {
  uint32_t z = 0;
  if (!atomic_compare_exchange_strong_explicit(&in->lock, &z, 1, memory_order_acquire,
                                               memory_order_relaxed))
    lock_slow(in);
}
static inline void let_go(instance_t *in) {
  if (atomic_exchange_explicit(&in->lock, 0, memory_order_release) != 1)
    os_sync_wake_by_address_any(&in->lock, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

/* ---------- the home core ---------- */
enum mode { M_SPIN, M_PARK, M_CONDVAR };

typedef struct waiter {
  pthread_mutex_t m;
  pthread_cond_t c;
} waiter_t;

/* A message lives in the calling task's frame (here, the caller's stack). */
typedef struct msg {
  _Atomic(struct msg *) next;
  instance_t *in;
  uint32_t iters;
  uint64_t result;
  _Atomic uint32_t done; /* 0 pending, 1 done, 2 caller parked */
  waiter_t *w;           /* condvar mode */
} msg_t;

typedef struct {
  /* producers' side */
  _Atomic(msg_t *) tail __attribute__((aligned(LINE)));
  /* consumer's side */
  msg_t *head __attribute__((aligned(LINE)));
  msg_t stub;
  _Atomic uint32_t sleeping __attribute__((aligned(LINE)));
  _Atomic int stop;
  pthread_mutex_t m;
  pthread_cond_t c;
  enum mode mode;
  int caller_park; /* the caller parks for its reply instead of spinning */
  uint64_t handled;
  pthread_t th;
} home_t;

/* Vyukov's intrusive MPSC queue. */
static void q_push(home_t *h, msg_t *n) {
  atomic_store_explicit(&n->next, NULL, memory_order_relaxed);
  msg_t *prev = atomic_exchange_explicit(&h->tail, n, memory_order_seq_cst);
  atomic_store_explicit(&prev->next, n, memory_order_release);
}
static msg_t *q_pop(home_t *h) {
  msg_t *head = h->head;
  msg_t *next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (head == &h->stub) {
    if (!next) return NULL;
    h->head = next;
    head = next;
    next = atomic_load_explicit(&next->next, memory_order_acquire);
  }
  if (next) {
    h->head = next;
    return head;
  }
  if (atomic_load_explicit(&h->tail, memory_order_acquire) != head) return NULL; /* mid-push */
  q_push(h, &h->stub);
  next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (next) {
    h->head = next;
    return head;
  }
  return NULL;
}
static int q_empty(home_t *h) {
  return h->head == &h->stub && atomic_load_explicit(&h->tail, memory_order_seq_cst) == &h->stub;
}

static void deliver(home_t *h, msg_t *m, uint64_t r) {
  m->result = r;
  switch (h->mode == M_CONDVAR ? M_CONDVAR : h->caller_park ? M_PARK : M_SPIN) {
  case M_SPIN:
    atomic_store_explicit(&m->done, 1, memory_order_release);
    break;
  case M_PARK:
    if (atomic_exchange_explicit(&m->done, 1, memory_order_acq_rel) == 2)
      os_sync_wake_by_address_any(&m->done, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    break;
  case M_CONDVAR: {
    waiter_t *w = m->w;
    pthread_mutex_lock(&w->m);
    atomic_store_explicit(&m->done, 1, memory_order_release);
    pthread_cond_signal(&w->c);
    pthread_mutex_unlock(&w->m);
    break;
  }
  }
}

static void *home_main(void *arg) {
  home_t *h = arg;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  for (;;) {
    msg_t *m = q_pop(h);
    if (m) {
      instance_t *in = m->in; /* the home core owns it: no lock */
      uint64_t r = op_run(in, m->iters);
      h->handled++;
      deliver(h, m, r);
      continue;
    }
    if (atomic_load_explicit(&h->stop, memory_order_acquire) && q_empty(h)) break;
    if (!q_empty(h)) { cpu_relax(); continue; } /* a push is mid-way */
    switch (h->mode) {
    case M_SPIN:
      cpu_relax();
      break;
    case M_PARK:
      atomic_store_explicit(&h->sleeping, 1, memory_order_seq_cst);
      if (!q_empty(h) || atomic_load_explicit(&h->stop, memory_order_seq_cst)) {
        atomic_store_explicit(&h->sleeping, 0, memory_order_relaxed);
        break;
      }
      while (atomic_load_explicit(&h->sleeping, memory_order_acquire) == 1)
        os_sync_wait_on_address(&h->sleeping, 1, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
      break;
    case M_CONDVAR:
      pthread_mutex_lock(&h->m);
      atomic_store_explicit(&h->sleeping, 1, memory_order_seq_cst);
      while (q_empty(h) && !atomic_load_explicit(&h->stop, memory_order_seq_cst))
        pthread_cond_wait(&h->c, &h->m);
      atomic_store_explicit(&h->sleeping, 0, memory_order_relaxed);
      pthread_mutex_unlock(&h->m);
      break;
    }
  }
  return NULL;
}

static void home_wake(home_t *h) {
  if (h->mode == M_SPIN) return;
  if (atomic_load_explicit(&h->sleeping, memory_order_seq_cst) != 1) return;
  if (h->mode == M_PARK) {
    if (atomic_exchange_explicit(&h->sleeping, 0, memory_order_acq_rel) == 1)
      os_sync_wake_by_address_any(&h->sleeping, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
  } else {
    pthread_mutex_lock(&h->m);
    pthread_cond_signal(&h->c);
    pthread_mutex_unlock(&h->m);
  }
}

static void home_start(home_t *h, enum mode mode, int caller_park) {
  memset(h, 0, sizeof *h);
  h->mode = mode;
  h->caller_park = caller_park;
  atomic_store(&h->tail, &h->stub);
  h->head = &h->stub;
  pthread_mutex_init(&h->m, NULL);
  pthread_cond_init(&h->c, NULL);
  pthread_attr_t a;
  pthread_attr_init(&a);
  pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
  pthread_create(&h->th, &a, home_main, h);
  pthread_attr_destroy(&a);
}
static void home_stop(home_t *h) {
  atomic_store_explicit(&h->stop, 1, memory_order_seq_cst);
  if (h->mode == M_PARK) {
    atomic_store_explicit(&h->sleeping, 0, memory_order_seq_cst);
    os_sync_wake_by_address_any(&h->sleeping, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
  } else if (h->mode == M_CONDVAR) {
    pthread_mutex_lock(&h->m);
    pthread_cond_signal(&h->c);
    pthread_mutex_unlock(&h->m);
  }
  pthread_join(h->th, NULL);
}

static waiter_t g_waiter;

static uint64_t hop(home_t *h, instance_t *in, uint32_t iters) {
  msg_t m;
  m.in = in;
  m.iters = iters;
  m.w = &g_waiter;
  atomic_store_explicit(&m.done, 0, memory_order_relaxed);
  q_push(h, &m);
  home_wake(h);
  switch (h->mode == M_CONDVAR ? M_CONDVAR : h->caller_park ? M_PARK : M_SPIN) {
  case M_SPIN:
    while (!atomic_load_explicit(&m.done, memory_order_acquire)) cpu_relax();
    break;
  case M_PARK: {
    uint32_t z = 0;
    if (atomic_compare_exchange_strong_explicit(&m.done, &z, 2, memory_order_acq_rel,
                                                memory_order_acquire))
      while (atomic_load_explicit(&m.done, memory_order_acquire) == 2)
        os_sync_wait_on_address(&m.done, 2, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
    break;
  }
  case M_CONDVAR:
    pthread_mutex_lock(&g_waiter.m);
    while (!atomic_load_explicit(&m.done, memory_order_acquire)) pthread_cond_wait(&g_waiter.c, &g_waiter.m);
    pthread_mutex_unlock(&g_waiter.m);
    break;
  }
  return m.result;
}

/* ---------- the harness ---------- */
enum variant { V_CALL, V_TAKE, V_HOP_SPIN, V_HOP_PARK, V_HOP_PARK_COLD, V_HOP_PARK_BOTH, V_HOP_CONDVAR, NVAR };
static const char *vname[NVAR] = {"call",          "take",          "hop_spin",   "hop_park",
                                  "hop_park_cold", "hop_park_both", "hop_condvar"};

static void home_for(home_t *h, enum variant v) {
  home_start(h, v == V_HOP_SPIN ? M_SPIN : v == V_HOP_CONDVAR ? M_CONDVAR : M_PARK,
             v == V_HOP_PARK_BOTH || v == V_HOP_CONDVAR);
}
#define COLD_GAP_NS 50000.0

typedef struct {
  enum variant v;
  instance_t *in;
  home_t *h;
  uint32_t iters;
} ctx_t;

static inline uint64_t one(ctx_t *c) {
  switch (c->v) {
  case V_CALL:
    return op_run(c->in, c->iters);
  case V_TAKE: {
    take(c->in);
    uint64_t r = op_run(c->in, c->iters);
    let_go(c->in);
    return r;
  }
  default:
    return hop(c->h, c->in, c->iters);
  }
}

static void idle_gap(void) {
  uint64_t end = now() + (uint64_t)(COLD_GAP_NS / tick_ns);
  while (now() < end) cpu_relax();
}

static volatile uint64_t sink;

/* Mean ns per op over n back-to-back ops (gap ops: each timed, gap excluded). */
static double batch(ctx_t *c, uint64_t n, int gap) {
  uint64_t acc = 0;
  if (!gap) {
    uint64_t t0 = now();
    for (uint64_t i = 0; i < n; i++) acc ^= one(c);
    uint64_t t1 = now();
    sink = acc;
    return (double)(t1 - t0) * tick_ns / (double)n;
  }
  uint64_t tot = 0;
  for (uint64_t i = 0; i < n; i++) {
    idle_gap();
    uint64_t t0 = now();
    acc ^= one(c);
    tot += now() - t0;
  }
  sink = acc;
  return (double)tot * tick_ns / (double)n;
}
static void sample(ctx_t *c, uint64_t n, int gap, double *out) {
  uint64_t acc = 0;
  for (uint64_t i = 0; i < n; i++) {
    if (gap) idle_gap();
    uint64_t t0 = now();
    acc ^= one(c);
    out[i] = (double)(now() - t0) * tick_ns;
  }
  sink = acc;
}

static int dcmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}
static double pct(double *v, size_t n, double p) {
  qsort(v, n, sizeof *v, dcmp);
  size_t i = (size_t)(p * (double)(n - 1) + 0.5);
  return v[i];
}

static double calibrate(void) {
  instance_t in;
  instance_init(&in);
  double best = 1e9;
  for (int r = 0; r < 5; r++) {
    uint32_t n = 20000000;
    uint64_t t0 = now();
    op_run(&in, n);
    double ns = (double)(now() - t0) * tick_ns / n;
    if (ns < best) best = ns;
  }
  return best;
}

static uint64_t reference(uint32_t iters, uint64_t n) {
  instance_t in;
  instance_init(&in);
  for (uint64_t i = 0; i < n; i++) op_run(&in, iters);
  return in.state;
}

static int failures;

typedef struct {
  double median, p50, p99;
} result_t;

static result_t run_config(enum variant v, uint32_t iters, double work_ns, int reps, double budget_ns,
                           int quiet_label) {
  (void)quiet_label;
  int gap = v == V_HOP_PARK_COLD;
  double per = work_ns + (gap ? COLD_GAP_NS : 300.0);
  uint64_t n = (uint64_t)(budget_ns / per);
  if (n < 200) n = 200;
  uint64_t ns = n < 10000 ? n : 10000;
  uint64_t warm = n / 10 + 1;

  instance_t *in = aligned_alloc(LINE, sizeof(instance_t));
  instance_init(in);
  home_t *h = NULL;
  if (v >= V_HOP_SPIN) {
    h = aligned_alloc(LINE, sizeof(home_t));
    home_for(h, v);
  }
  ctx_t c = {v, in, h, iters};

  double *means = calloc((size_t)reps, sizeof(double));
  double *samples = calloc((size_t)(ns * (uint64_t)reps), sizeof(double));
  batch(&c, warm, gap);
  for (int r = 0; r < reps; r++) {
    means[r] = batch(&c, n, gap);
    sample(&c, ns, gap, samples + (size_t)r * ns);
  }
  if (h) {
    home_stop(h);
  }
  uint64_t total = warm + (uint64_t)reps * (n + ns);
  uint64_t want = reference(iters, total);
  int ok = in->state == want && in->ops == total && in->slow == 0 && (!h || h->handled == total);
  if (!ok) {
    failures++;
    fprintf(stderr, "FAIL %s iters=%u: state %llx want %llx ops %llu total %llu slow %llu handled %llu\n",
            vname[v], iters, (unsigned long long)in->state, (unsigned long long)want,
            (unsigned long long)in->ops, (unsigned long long)total, (unsigned long long)in->slow,
            (unsigned long long)(h ? h->handled : 0));
  }
  result_t res;
  res.median = pct(means, (size_t)reps, 0.5);
  res.p50 = pct(samples, (size_t)(ns * (uint64_t)reps), 0.5);
  res.p99 = pct(samples, (size_t)(ns * (uint64_t)reps), 0.99);
  free(means);
  free(samples);
  free(in);
  free(h);
  return res;
}

int main(int argc, char **argv) {
  int quick = 0, check = 0, reps = 11;
  const char *only = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--quick")) quick = 1;
    else if (!strcmp(argv[i], "--check")) check = 1;
    else if (!strcmp(argv[i], "--reps") && i + 1 < argc) reps = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--variant") && i + 1 < argc) only = argv[++i];
    else {
      fprintf(stderr, "usage: %s [--quick] [--check] [--reps N] [--variant NAME]\n", argv[0]);
      return 2;
    }
  }
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / (double)tb.denom;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  pthread_mutex_init(&g_waiter.m, NULL);
  pthread_cond_init(&g_waiter.c, NULL);

  if (check) {
    /* Cross-language agreement: fixed iterations and op count, every
       variant must land on the same state as the reference. */
    uint64_t want = reference(7, 1000);
    for (int v = 0; v < NVAR; v++) {
      instance_t *in = aligned_alloc(LINE, sizeof(instance_t));
      instance_init(in);
      home_t *h = NULL;
      if (v >= V_HOP_SPIN) {
        h = aligned_alloc(LINE, sizeof(home_t));
        home_for(h, (enum variant)v);
      }
      ctx_t c = {(enum variant)v, in, h, 7};
      for (int i = 0; i < 1000; i++) one(&c);
      if (h) home_stop(h);
      if (in->state != want || in->ops != 1000 || (h && h->handled != 1000)) failures++;
      free(in);
      free(h);
    }
    printf("CHECK lang=c state=%016llx %s\n", (unsigned long long)want, failures ? "FAIL" : "ok");
    return failures ? 1 : 0;
  }

  if (quick) reps = reps < 3 ? reps : 3;
  double budget = quick ? 2e6 : 2e7; /* ns of ops per timed batch */
  double ns_per_iter = calibrate();
  /* 0 ns: an empty operation, so the raw cost of taking shows; at 10 ns and
     up out-of-order execution can overlap the lock word's atomics with the
     work. */
  static const double works[] = {0, 10, 100, 1000, 10000};
  for (int w = 0; w < 5; w++) {
    uint32_t iters = (uint32_t)(works[w] / ns_per_iter + 0.5);
    if (iters < 1 && works[w] > 0) iters = 1;
    double call_median = 0;
    for (int v = 0; v < NVAR; v++) {
      if (only && strcmp(only, vname[v]) && v != V_CALL) continue;
      result_t r = run_config((enum variant)v, iters, works[w], reps, budget, 0);
      if (v == V_CALL) call_median = r.median;
      if (only && strcmp(only, vname[v])) continue;
      printf("P1 lang=c variant=%s work_ns=%g iters=%u workers=1 reps=%d median_ns=%.2f "
             "overhead_ns=%.2f p50_ns=%.1f p99_ns=%.1f qos=user_interactive\n",
             vname[v], works[w], iters, reps, r.median, r.median - call_median, r.p50, r.p99);
      fflush(stdout);
    }
  }
  if (failures) fprintf(stderr, "%d configuration(s) failed their checks\n", failures);
  return failures ? 1 : 0;
}
