// Runtime phase 2: spin budget for hops to a parked owner.
//
// Built on phase 1's P1 hop harness (../../many-cores/p1/c/p1.c): the same
// instance, op_run, Vyukov MPSC inbox, Dekker-style sleeping flag and ulock.
//
// The model is `per_core` with N workers. Each worker owns one instance
// (its home) and runs one task. The task loops: sleep for an arrival gap
// (exponential, mean --gap-ns), then hop to a random other worker's
// instance and wait for the reply. A worker always serves its own inbox,
// including while its task waits (so A->B and B->A never deadlock).
//
// When a worker has nothing to do it waits for an event: a message in its
// inbox, the reply its task waits for, or its task's gap timer. The wait
// policy decides how long it spins before parking on its sleeping word:
//
//   fixed  spin --reply-spin-ns on a reply wait, --idle-spin-ns on an
//          idle wait (task sleeping), then park. -1 means never park.
//   ema    glibc's adaptive mutex in time: budget = min(cap, 2*ema + 100ns),
//          ema += (min(wait, budget) - ema) / 8. cap is the fixed budget.
//   pred   the proposed rule: ema of the true wait, per kind, timed to
//          when the event happened (reply finished, message pushed, timer
//          due), not to when a parked waiter noticed it. Spin
//          min(cap, 2*ema) if ema <= cap, else park at once. cap should be
//          about the cost of a park and wake (Karlin's 2-competitive rule).
//   go     Go's gates: a reply wait spins up to cap only if another worker
//          is awake; an idle wait spins up to cap only if
//          2*spinning < awake workers (runtime.findrunnable).
//
// One line per run on stdout (see PLAN.md). Exit status 1 on any failed
// check: replies, per-instance op counts and token sums, served == sent,
// empty inboxes, no hang.

#include <errno.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define LINE 128 /* Apple M-series cache line */
#define SEED 0x9E3779B97F4A7C15ull
#define MAXW 64
#define NB 512 /* histogram buckets */

static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }

/* ---------- time ---------- */
static double tick_ns;
static inline uint64_t now(void) { return mach_absolute_time(); }
static inline uint64_t ns_to_ticks(double ns) { return (uint64_t)ceil(ns / tick_ns); }

static inline uint64_t mix64(uint64_t x) { /* splitmix64 finaliser */
  x += SEED;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
  return x ^ (x >> 31);
}

/* ---------- histogram: 64 linear buckets, then 16 per power of two ---------- */
static inline int bucket(uint64_t v) {
  if (v < 64) return (int)v;
  int e = 63 - __builtin_clzll(v);
  int i = 64 + (e - 6) * 16 + (int)((v >> (e - 4)) & 15);
  return i < NB ? i : NB - 1;
}
static inline double bucket_mid(int i) {
  if (i < 64) return i;
  int e = (i - 64) / 16 + 6, s = (i - 64) % 16;
  double lo = (double)(1ull << e) + (double)s * (double)(1ull << (e - 4));
  return lo + (double)(1ull << (e - 4)) / 2;
}
static double hist_pct(const uint64_t *h, double p) {
  uint64_t tot = 0;
  for (int i = 0; i < NB; i++) tot += h[i];
  if (!tot) return 0;
  uint64_t want = (uint64_t)ceil(p * (double)tot), acc = 0;
  if (want < 1) want = 1;
  for (int i = 0; i < NB; i++) {
    acc += h[i];
    if (acc >= want) return bucket_mid(i) * tick_ns;
  }
  return bucket_mid(NB - 1) * tick_ns;
}

/* ---------- the instance (P1's), owned by its home worker: no lock ---------- */
typedef struct {
  uint64_t state;
  uint64_t ops;
  uint64_t tok_sum; /* sum of mix64(token) over ops run: order-free check */
} __attribute__((aligned(LINE))) instance_t;

__attribute__((noinline)) static uint64_t op_run(instance_t *in, uint32_t iters, uint64_t token) {
  uint64_t s = in->state;
  for (uint32_t i = 0; i < iters; i++) {
    s ^= s >> 29;
    s *= 0xBF58476D1CE4E5B9ull;
  }
  in->state = s;
  in->ops++;
  uint64_t h = mix64(token);
  in->tok_sum += h;
  return h;
}

/* ---------- messages: in the caller's frame ---------- */
typedef struct msg {
  _Atomic(struct msg *) next;
  uint32_t from;
  uint64_t token;
  uint64_t start;  /* owner's clock when it began the op */
  uint64_t done_t; /* owner's clock when it finished */
  uint64_t result;
  _Atomic uint32_t done;
} msg_t;

enum policy { P_FIXED, P_EMA, P_PRED, P_GO };
static const char *pname[] = {"fixed", "ema", "pred", "go"};
enum kind { K_REPLY, K_IDLE, K_FIN };

typedef struct worker {
  _Atomic(msg_t *) tail __attribute__((aligned(LINE))); /* producers */
  _Atomic uint64_t push_t; /* latest producer's push time (pred's event clock) */
  msg_t *head __attribute__((aligned(LINE)));           /* consumer */
  msg_t stub;
  _Atomic uint32_t sleeping __attribute__((aligned(LINE))); /* wakers */
  /* stats: written by the owner only, read by main mid-run */
  _Atomic uint64_t hops __attribute__((aligned(LINE)));
  _Atomic uint64_t served, parks, wakes, spin_ticks, stretches, spin_hits, bad;
  /* private */
  uint32_t id;
  uint64_t rng;
  uint64_t seq;
  double ema[2]; /* ticks, per kind (reply, idle) */
  uint64_t sent_to[MAXW], sent_sum[MAXW];
  uint64_t h_hop[NB], h_reach[NB];
  instance_t inst;
  pthread_t th;
} worker_t;

/* ---------- config and globals ---------- */
static struct {
  int n;
  enum policy pol;
  int64_t spin[2]; /* ticks per kind; -1 = never park */
  uint32_t iters;
  double gap_ticks;   /* mean */
  uint64_t floor_ema; /* 100 ns, glibc's "+10" */
} C;
static worker_t *W[MAXW];
static _Atomic int g_start, g_stop, g_measuring, g_finished, g_all_finished, g_exited;
static _Atomic int g_parked, g_spinning; /* go policy only */

static inline void stat_inc(_Atomic uint64_t *c, uint64_t d) {
  atomic_store_explicit(c, atomic_load_explicit(c, memory_order_relaxed) + d, memory_order_relaxed);
}

/* Vyukov's intrusive MPSC queue (P1's). */
static void q_push(worker_t *h, msg_t *n) {
  atomic_store_explicit(&n->next, NULL, memory_order_relaxed);
  msg_t *prev = atomic_exchange_explicit(&h->tail, n, memory_order_seq_cst);
  atomic_store_explicit(&prev->next, n, memory_order_release);
}
static msg_t *q_pop(worker_t *h) {
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
static inline int q_empty(worker_t *h) {
  return h->head == &h->stub && atomic_load_explicit(&h->tail, memory_order_seq_cst) == &h->stub;
}

/* Wake a worker if it is parked (or about to). Dekker with its sleeping
   store: the caller has already published (seq_cst) what it is waking for. */
static inline void wake(worker_t *me, worker_t *w) {
  if (atomic_load_explicit(&w->sleeping, memory_order_seq_cst) == 1 &&
      atomic_exchange_explicit(&w->sleeping, 0, memory_order_seq_cst) == 1) {
    os_sync_wake_by_address_any(&w->sleeping, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
    stat_inc(&me->wakes, 1);
  }
}

static void serve(worker_t *me, msg_t *x) {
  uint32_t from = x->from;
  x->start = now();
  x->result = op_run(&me->inst, C.iters, x->token);
  x->done_t = now();
  stat_inc(&me->served, 1);
  atomic_store_explicit(&x->done, 1, memory_order_seq_cst); /* x is the caller's again */
  wake(me, W[from]);
}

static inline int ready(worker_t *me, msg_t *m, uint64_t deadline, enum kind k) {
  if (!q_empty(me)) return 1;
  if (m && atomic_load_explicit(&m->done, memory_order_seq_cst)) return 1;
  if (deadline && now() >= deadline) return 1;
  if (k == K_FIN && atomic_load_explicit(&g_all_finished, memory_order_seq_cst)) return 1;
  return 0;
}

/* Spin budget in ticks for this idle stretch; -1 = never park. */
static int64_t budget_for(worker_t *me, enum kind k) {
  int kk = k == K_REPLY ? 0 : 1;
  int64_t cap = C.spin[kk];
  if (k == K_FIN) return 0;
  switch (C.pol) {
  case P_FIXED:
    return cap;
  case P_EMA: {
    double b = 2 * me->ema[kk] + (double)C.floor_ema;
    return cap >= 0 && b > (double)cap ? cap : (int64_t)b;
  }
  case P_PRED: {
    double e = me->ema[kk];
    if (cap >= 0 && e > (double)cap) return 0;
    double b = 2 * e;
    return cap >= 0 && b > (double)cap ? cap : (int64_t)b;
  }
  case P_GO: {
    int awake = C.n - atomic_load_explicit(&g_parked, memory_order_relaxed);
    if (k == K_REPLY) return awake - 1 > 0 ? cap : 0;
    return 2 * atomic_load_explicit(&g_spinning, memory_order_relaxed) < awake ? cap : 0;
  }
  }
  return 0;
}
static void learn(worker_t *me, enum kind k, uint64_t waited, int64_t budget) {
  if (k == K_FIN) return;
  int kk = k == K_REPLY ? 0 : 1;
  if (C.pol == P_EMA) {
    double c = budget >= 0 && (int64_t)waited > budget ? (double)budget : (double)waited;
    me->ema[kk] += (c - me->ema[kk]) / 8;
  } else if (C.pol == P_PRED) {
    me->ema[kk] += ((double)waited - me->ema[kk]) / 8;
  }
}

/* After a park: how long after t0 the event that ended the wait happened
   (not when this worker noticed it), so pred learns the true wait and not
   the wake-up latency its own parking added. ema keeps glibc's rule. */
static uint64_t event_wait(worker_t *me, msg_t *m, uint64_t deadline, uint64_t t0) {
  uint64_t t = now();
  if (C.pol != P_PRED) return t - t0;
  uint64_t ev = t;
  if (m && atomic_load_explicit(&m->done, memory_order_acquire) && m->done_t < ev) ev = m->done_t;
  if (!q_empty(me)) {
    uint64_t p = atomic_load_explicit(&me->push_t, memory_order_relaxed);
    if (p < ev) ev = p;
  }
  if (deadline && deadline <= t && deadline < ev) ev = deadline;
  return ev > t0 ? ev - t0 : 0;
}

/* Serve the inbox and wait until `m` is done, `deadline` passes, or (FIN)
   every worker has finished. */
static void wait_for(worker_t *me, msg_t *m, uint64_t deadline, enum kind k) {
  for (;;) {
    msg_t *x;
    while ((x = q_pop(me))) serve(me, x);
    if (m && atomic_load_explicit(&m->done, memory_order_acquire)) return;
    if (deadline && now() >= deadline) return;
    if (k == K_FIN && atomic_load_explicit(&g_all_finished, memory_order_acquire)) return;

    /* nothing to do: spin, then park */
    uint64_t t0 = now();
    int64_t b = budget_for(me, k);
    int go_spin = C.pol == P_GO && k == K_IDLE && b != 0;
    if (go_spin) atomic_fetch_add_explicit(&g_spinning, 1, memory_order_relaxed);
    uint64_t end = b < 0 ? UINT64_MAX : t0 + (uint64_t)b;
    if (deadline && deadline < end) end = deadline;
    int hit = 0;
    uint64_t t = t0;
    if (b != 0) {
      for (;;) {
        if (ready(me, m, 0, k)) { hit = 1; break; }
        t = now();
        if (t >= end) break;
        cpu_relax();
      }
      t = now();
    }
    if (go_spin) atomic_fetch_sub_explicit(&g_spinning, 1, memory_order_relaxed);
    stat_inc(&me->spin_ticks, t - t0);
    stat_inc(&me->stretches, 1);
    if (hit) {
      stat_inc(&me->spin_hits, 1);
      learn(me, k, t - t0, b);
      continue;
    }
    if (deadline && t >= deadline) continue; /* timer fired while spinning */

    /* park */
    atomic_store_explicit(&me->sleeping, 1, memory_order_seq_cst);
    if (ready(me, m, deadline, k)) {
      atomic_store_explicit(&me->sleeping, 0, memory_order_relaxed);
      learn(me, k, now() - t0, b);
      continue;
    }
    stat_inc(&me->parks, 1);
    if (C.pol == P_GO) atomic_fetch_add_explicit(&g_parked, 1, memory_order_relaxed);
    while (atomic_load_explicit(&me->sleeping, memory_order_acquire) == 1) {
      uint64_t lim = deadline;
      if (k == K_FIN) lim = now() + ns_to_ticks(1e6); /* belt and braces */
      if (lim) {
        uint64_t tn = now();
        if (tn >= lim) break;
        int rc = os_sync_wait_on_address_with_timeout(&me->sleeping, 1, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE,
                                                      OS_CLOCK_MACH_ABSOLUTE_TIME,
                                                      (uint64_t)((double)(lim - tn) * tick_ns));
        if (rc < 0 && errno == ETIMEDOUT) break;
      } else {
        os_sync_wait_on_address(&me->sleeping, 1, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
      }
    }
    atomic_store_explicit(&me->sleeping, 0, memory_order_relaxed);
    if (C.pol == P_GO) atomic_fetch_sub_explicit(&g_parked, 1, memory_order_relaxed);
    learn(me, k, event_wait(me, m, deadline, t0), b);
  }
}

static inline uint64_t rnd(worker_t *me) { /* xorshift64* */
  uint64_t x = me->rng;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  me->rng = x;
  return x * 0x2545F4914F6CDD1Dull;
}

static void hop(worker_t *me) {
  uint32_t tgt = (uint32_t)(rnd(me) % (uint64_t)(C.n - 1));
  if (tgt >= me->id) tgt++;
  msg_t m;
  m.from = me->id;
  m.token = ((uint64_t)me->id << 40) | me->seq++;
  m.start = 0;
  m.result = 0;
  atomic_store_explicit(&m.done, 0, memory_order_relaxed);
  int meas = atomic_load_explicit(&g_measuring, memory_order_relaxed);
  uint64_t t0 = now();
  atomic_store_explicit(&W[tgt]->push_t, t0, memory_order_relaxed);
  q_push(W[tgt], &m);
  wake(me, W[tgt]);
  wait_for(me, &m, 0, K_REPLY);
  uint64_t t1 = now();
  uint64_t want = mix64(m.token);
  if (m.result != want) stat_inc(&me->bad, 1);
  me->sent_to[tgt]++;
  me->sent_sum[tgt] += want;
  if (meas) {
    me->h_hop[bucket(t1 - t0)]++;
    me->h_reach[bucket(m.start > t0 ? m.start - t0 : 0)]++;
  }
  stat_inc(&me->hops, 1);
}

static void *worker_main(void *arg) {
  worker_t *me = arg;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  while (!atomic_load_explicit(&g_start, memory_order_acquire)) sched_yield();
  while (!atomic_load_explicit(&g_stop, memory_order_acquire)) {
    if (C.gap_ticks > 0) {
      double u = (double)((rnd(me) >> 11) + 1) * 0x1.0p-53; /* (0,1] */
      uint64_t g = (uint64_t)(-C.gap_ticks * log(u));
      if (g) wait_for(me, NULL, now() + g, K_IDLE);
    }
    hop(me);
  }
  if (atomic_fetch_add_explicit(&g_finished, 1, memory_order_seq_cst) + 1 == C.n) {
    atomic_store_explicit(&g_all_finished, 1, memory_order_seq_cst);
    for (int i = 0; i < C.n; i++) wake(me, W[i]);
  }
  wait_for(me, NULL, 0, K_FIN);
  /* anything pushed after all finished? nobody hops after finishing */
  atomic_fetch_add_explicit(&g_exited, 1, memory_order_release);
  return NULL;
}

/* ---------- harness ---------- */
static double calibrate(void) {
  instance_t in = {SEED, 0, 0};
  double best = 1e9;
  for (int r = 0; r < 5; r++) {
    uint32_t n = 4000000;
    uint64_t t0 = now();
    op_run(&in, n, 0);
    double ns = (double)(now() - t0) * tick_ns / n;
    if (ns < best) best = ns;
  }
  return best;
}

static void sleep_ms(double ms) {
  struct timespec ts = {(time_t)(ms / 1000), (long)(fmod(ms, 1000) * 1e6)};
  while (nanosleep(&ts, &ts) && errno == EINTR) {
  }
}
static double cpu_ns(struct rusage *r) {
  return ((double)r->ru_utime.tv_sec + (double)r->ru_stime.tv_sec) * 1e9 +
         ((double)r->ru_utime.tv_usec + (double)r->ru_stime.tv_usec) * 1e3;
}

typedef struct {
  uint64_t hops, served, parks, wakes, spin_ticks, stretches, spin_hits;
} snap_t;
static snap_t snap(void) {
  snap_t s = {0};
  for (int i = 0; i < C.n; i++) {
    worker_t *w = W[i];
    s.hops += atomic_load_explicit(&w->hops, memory_order_relaxed);
    s.served += atomic_load_explicit(&w->served, memory_order_relaxed);
    s.parks += atomic_load_explicit(&w->parks, memory_order_relaxed);
    s.wakes += atomic_load_explicit(&w->wakes, memory_order_relaxed);
    s.spin_ticks += atomic_load_explicit(&w->spin_ticks, memory_order_relaxed);
    s.stretches += atomic_load_explicit(&w->stretches, memory_order_relaxed);
    s.spin_hits += atomic_load_explicit(&w->spin_hits, memory_order_relaxed);
  }
  return s;
}

static const char *fmt_budget(double ns, char *buf) {
  if (ns < 0) return "inf";
  snprintf(buf, 32, "%g", ns);
  return buf;
}

/* One run. Returns 0 if every check passed. */
static int run(const char *tag, double reply_ns, double idle_ns, double service_ns, double ns_per_iter,
               double gap_ns, double warm_ms, double window_ms) {
  C.spin[0] = reply_ns < 0 ? -1 : (int64_t)ns_to_ticks(reply_ns);
  C.spin[1] = idle_ns < 0 ? -1 : (int64_t)ns_to_ticks(idle_ns);
  C.iters = (uint32_t)(service_ns / ns_per_iter + 0.5);
  C.gap_ticks = gap_ns / tick_ns;
  C.floor_ema = ns_to_ticks(100);
  atomic_store(&g_start, 0);
  atomic_store(&g_stop, 0);
  atomic_store(&g_measuring, 0);
  atomic_store(&g_finished, 0);
  atomic_store(&g_all_finished, 0);
  atomic_store(&g_exited, 0);
  atomic_store(&g_parked, 0);
  atomic_store(&g_spinning, 0);

  for (int i = 0; i < C.n; i++) {
    worker_t *w = aligned_alloc(LINE, sizeof(worker_t));
    memset(w, 0, sizeof *w);
    w->id = (uint32_t)i;
    w->rng = mix64(0x1234 + (uint64_t)i) | 1;
    w->inst.state = SEED;
    atomic_store(&w->tail, &w->stub);
    w->head = &w->stub;
    W[i] = w;
  }
  pthread_attr_t a;
  pthread_attr_init(&a);
  pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
  for (int i = 0; i < C.n; i++) pthread_create(&W[i]->th, &a, worker_main, W[i]);
  pthread_attr_destroy(&a);

  atomic_store_explicit(&g_start, 1, memory_order_release);
  sleep_ms(warm_ms);
  struct rusage r0, r1;
  snap_t s0 = snap();
  getrusage(RUSAGE_SELF, &r0);
  atomic_store_explicit(&g_measuring, 1, memory_order_relaxed);
  uint64_t t0 = now();
  sleep_ms(window_ms);
  atomic_store_explicit(&g_measuring, 0, memory_order_relaxed);
  uint64_t t1 = now();
  getrusage(RUSAGE_SELF, &r1);
  snap_t s1 = snap();
  atomic_store_explicit(&g_stop, 1, memory_order_release);

  int fails = 0;
  for (int i = 0; i < 10000 && atomic_load_explicit(&g_exited, memory_order_acquire) < C.n; i++) sleep_ms(1);
  if (atomic_load_explicit(&g_exited, memory_order_acquire) < C.n) {
    printf("SPIN tag=%s FAIL hang: %d/%d workers exited\n", tag, atomic_load(&g_exited), C.n);
    fflush(stdout);
    _exit(1);
  }
  for (int i = 0; i < C.n; i++) pthread_join(W[i]->th, NULL);

  /* checks */
  uint64_t tot_hops = 0, tot_served = 0, bad = 0;
  uint64_t hh[NB] = {0}, hr[NB] = {0};
  for (int i = 0; i < C.n; i++) {
    worker_t *w = W[i];
    tot_hops += w->hops;
    tot_served += w->served;
    bad += w->bad;
    uint64_t want_ops = 0, want_sum = 0;
    for (int j = 0; j < C.n; j++) {
      want_ops += W[j]->sent_to[i];
      want_sum += W[j]->sent_sum[i];
    }
    if (w->inst.ops != want_ops || w->inst.tok_sum != want_sum || w->sent_to[i] != 0) {
      fails++;
      fprintf(stderr, "FAIL instance %d: ops %llu want %llu sum %llx want %llx\n", i,
              (unsigned long long)w->inst.ops, (unsigned long long)want_ops,
              (unsigned long long)w->inst.tok_sum, (unsigned long long)want_sum);
    }
    if (!q_empty(w)) {
      fails++;
      fprintf(stderr, "FAIL inbox %d not empty\n", i);
    }
    for (int b = 0; b < NB; b++) {
      hh[b] += w->h_hop[b];
      hr[b] += w->h_reach[b];
    }
  }
  if (bad) fails++, fprintf(stderr, "FAIL %llu bad replies\n", (unsigned long long)bad);
  if (tot_hops != tot_served) fails++, fprintf(stderr, "FAIL hops %llu served %llu\n",
                                              (unsigned long long)tot_hops, (unsigned long long)tot_served);
  if (tot_hops == 0) fails++, fprintf(stderr, "FAIL no hops\n");

  double wall = (double)(t1 - t0) * tick_ns;
  double hops = (double)(s1.hops - s0.hops);
  double cpu = cpu_ns(&r1) - cpu_ns(&r0);
  double svc = C.iters * ns_per_iter;
  double util = cpu / (wall * C.n);
  double work = hops * svc / (wall * C.n);
  double csw = (double)(r1.ru_nvcsw - r0.ru_nvcsw + r1.ru_nivcsw - r0.ru_nivcsw);
  double hd = hops > 0 ? hops : 1;
  char b1[32], b2[32];
  printf("SPIN tag=%s policy=%s reply_spin_ns=%s idle_spin_ns=%s service_ns=%g iters=%u gap_ns=%g workers=%d "
         "window_ms=%.0f hops=%.0f hops_per_s=%.0f hop_p50_ns=%.0f hop_p99_ns=%.0f hop_p999_ns=%.0f "
         "reach_p50_ns=%.0f reach_p99_ns=%.0f cpu_ns_per_hop=%.0f util=%.4f work_util=%.4f waste=%.4f "
         "spin_ns_per_hop=%.0f spin_hit=%.3f parks_per_hop=%.3f wakes_per_hop=%.3f csw_per_hop=%.3f "
         "checked_hops=%llu %s\n",
         tag, pname[C.pol], fmt_budget(reply_ns, b1), fmt_budget(idle_ns, b2), service_ns, C.iters, gap_ns,
         C.n, wall / 1e6, hops, hops / (wall / 1e9), hist_pct(hh, 0.5), hist_pct(hh, 0.99),
         hist_pct(hh, 0.999), hist_pct(hr, 0.5), hist_pct(hr, 0.99), cpu / hd, util, work, util - work,
         (double)(s1.spin_ticks - s0.spin_ticks) * tick_ns / hd,
         (s1.stretches - s0.stretches) ? (double)(s1.spin_hits - s0.spin_hits) / (double)(s1.stretches - s0.stretches) : 0,
         (double)(s1.parks - s0.parks) / hd, (double)(s1.wakes - s0.wakes) / hd, csw / hd,
         (unsigned long long)tot_hops, fails ? "FAIL" : "ok");
  fflush(stdout);
  for (int i = 0; i < C.n; i++) free(W[i]);
  return fails;
}

static double parse_ns(const char *s) {
  if (!strcmp(s, "inf")) return -1;
  return atof(s);
}

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / (double)tb.denom;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

  double reply = 0, idle = 0, service = 1000, gap = 0, warm = 50, window = 400, npi = 0;
  int check = 0, calib = 0, budget_set = 0;
  C.n = 2;
  C.pol = P_FIXED;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
#define ARG(name) (!strcmp(a, name) && v && (i++, 1))
    if (!strcmp(a, "--check")) check = 1;
    else if (!strcmp(a, "--calibrate")) calib = 1;
    else if (ARG("--budget-ns")) reply = idle = parse_ns(v), budget_set = 1;
    else if (ARG("--reply-spin-ns")) reply = parse_ns(v), budget_set = 1;
    else if (ARG("--idle-spin-ns")) idle = parse_ns(v), budget_set = 1;
    else if (ARG("--service-ns")) service = atof(v);
    else if (ARG("--gap-ns")) gap = atof(v);
    else if (ARG("--workers")) C.n = atoi(v);
    else if (ARG("--warm-ms")) warm = atof(v);
    else if (ARG("--window-ms")) window = atof(v);
    else if (ARG("--ns-per-iter")) npi = atof(v);
    else if (ARG("--policy")) {
      int k = -1;
      for (int p = 0; p < 4; p++)
        if (!strcmp(v, pname[p])) k = p;
      if (k < 0) { fprintf(stderr, "unknown policy %s\n", v); return 2; }
      C.pol = (enum policy)k;
    } else {
      fprintf(stderr,
              "usage: %s [--check] [--calibrate] [--policy fixed|ema|pred|go] [--budget-ns N|inf]\n"
              "  [--reply-spin-ns N|inf] [--idle-spin-ns N|inf] [--service-ns N] [--gap-ns N]\n"
              "  [--workers N] [--warm-ms N] [--window-ms N] [--ns-per-iter X]\n",
              argv[0]);
      return 2;
    }
  }
  (void)budget_set;
  if (C.n < 2 || C.n > MAXW) { fprintf(stderr, "workers must be 2..%d\n", MAXW); return 2; }
  if (npi <= 0) npi = calibrate();
  if (calib) { printf("%.6f\n", npi); return 0; }

  if (check) {
    /* Every policy, small and short: the invariants, and no hang. */
    static const struct { enum policy p; double b; int n; double gap; } cs[] = {
        {P_FIXED, 0, 2, 0},      {P_FIXED, 0, 4, 2000},     {P_FIXED, 1000, 4, 2000}, {P_FIXED, -1, 2, 0},
        {P_FIXED, 5000, 4, 0},   {P_EMA, 20000, 4, 2000},   {P_PRED, 20000, 4, 2000}, {P_GO, 20000, 4, 2000},
        {P_PRED, 20000, 3, 20000}, {P_GO, 20000, 2, 0},
    };
    int fails = 0;
    for (size_t i = 0; i < sizeof cs / sizeof cs[0]; i++) {
      C.n = cs[i].n;
      C.pol = cs[i].p;
      fails += run("check", cs[i].b, cs[i].b, 100, npi, cs[i].gap, 5, 20);
    }
    printf("CHECK %s\n", fails ? "FAIL" : "ok");
    return fails ? 1 : 0;
  }
  return run("run", reply, idle, service, npi, gap, warm, window) ? 1 : 0;
}
