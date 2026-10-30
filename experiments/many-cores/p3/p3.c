// P3: handing off against barging.
//
// 64 tasks, modelled green-thread style on N worker threads, contend for one
// handler instance. A task is a small state machine (an operation needs no
// stack across the wait here, so a task's "continuation" is its phase).
// Workers have local run queues with a runnext slot, steal from each other,
// spin briefly when out of work and then park on a condition variable (Go's
// scheduler shape). A task that can't take the instance is parked on the
// instance's waiter queue; its worker moves on to another task, so a thread
// never blocks while its task is parked (decision 10).
//
// Two release policies:
//   fifo  : strict first-in-first-out handoff. An arrival may take the
//           instance only if it is free AND nobody waits; release hands the
//           instance (still held) to the head waiter and makes it runnable.
//   barge : release frees the instance and wakes one waiter (at most one
//           woken waiter outstanding, as Go's mutexWoken); any arriving task
//           may take a free instance; a woken waiter that loses requeues at
//           the head. Starvation guard: if the head waiter has waited longer
//           than the guard (1 ms), release hands off to it directly instead.
//
// See README.md for how this maps to Ren.

#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXW 64
#define MAXT 4096
#define QCAP 8192 /* power of two, > MAXT */
#define SW 16     /* words of instance state touched per round */
#define HB 1024   /* histogram buckets */
#define SPIN_ROUNDS 64

static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __builtin_arm_yield();
#endif
}

static double ns_per_tick;
static inline uint64_t now_ticks(void) { return mach_absolute_time(); }

/* ---------- spinlock (test and test-and-set) ---------- */
typedef struct { atomic_int f; } spin_t;
static inline void spin_lock(spin_t *s) {
  for (;;) {
    if (!atomic_exchange_explicit(&s->f, 1, memory_order_acquire)) return;
    while (atomic_load_explicit(&s->f, memory_order_relaxed)) cpu_relax();
  }
}
static inline void spin_unlock(spin_t *s) {
  atomic_store_explicit(&s->f, 0, memory_order_release);
}

/* ---------- configuration ---------- */
enum { FIFO = 0, BARGE = 1 };
typedef struct {
  int mode, workers, tasks;
  uint64_t cs_ns, out_ns;
  uint64_t cs_rounds, out_iters;
  uint64_t ms;          /* timed run length; 0 = fixed ops */
  uint64_t ops_per_task;/* fixed ops mode */
  uint64_t guard_ticks;
  int reps;
} cfg_t;
static cfg_t cfg;

/* ---------- tasks ---------- */
typedef struct task {
  _Alignas(128) struct task *next; /* waiter-queue link */
  uint64_t t_req;   /* when it asked for the instance (wait start, guard age) */
  int resuming;     /* parked on the instance; next run resumes there */
  int granted;      /* handed the instance by its releaser */
  uint64_t ops;
  uint64_t rng;
  int id;
} rtask_t;

/* ---------- the instance: owner word + waiter queue + state ---------- */
typedef struct {
  /* bit 0: held; bits 1..: number of queued waiters */
  _Alignas(128) atomic_uint_fast64_t state;
  spin_t qlock;          /* guards the waiter queue and fields below */
  rtask_t *head, *tail;
  int woken;             /* barge: a woken waiter has not retried yet */
  uint64_t guard_handoffs, wakes, handoffs;
  _Alignas(128) atomic_int in_cs; /* exclusion checker */
  uint64_t counter;      /* the handler's state: plain, only the holder */
  uint64_t a[SW];
} instance_t;
static instance_t inst;

/* ---------- workers ---------- */
typedef struct {
  _Alignas(128) spin_t lock;
  uint32_t head, tail;
  rtask_t *buf[QCAP];
  _Alignas(128) _Atomic(rtask_t *) runnext;
  pthread_mutex_t m;
  pthread_cond_t c;
  int notified;
  int spinning;
  int id;
  uint64_t window_ops;
  uint64_t hist[HB];
  uint64_t maxwait_ns;
  uint64_t rng;
  pthread_t th;
} worker_t;
static worker_t W[MAXW];
static rtask_t T[MAXT];

static pthread_mutex_t sched_m = PTHREAD_MUTEX_INITIALIZER;
static int idle_stack[MAXW];
static int idle_n;
static atomic_int nidle, nspinning, done_tasks, stop, shutdown_;

/* ---------- histogram ---------- */
static inline int hidx(uint64_t v) {
  if (v < 16) return (int)v;
  int e = 63 - __builtin_clzll(v);
  int sub = (int)((v >> (e - 4)) & 15);
  return (e - 3) * 16 + sub;
}
static inline uint64_t hval(int i) {
  if (i < 16) return (uint64_t)i;
  int e = i / 16 + 3, sub = i % 16;
  return (uint64_t)(16 + sub) << (e - 4);
}

/* ---------- run queues ---------- */
static void wakep(void);

static void push_local(worker_t *w, rtask_t *t, int front) {
  if (front) {
    rtask_t *old = atomic_exchange_explicit(&w->runnext, t, memory_order_acq_rel);
    if (!old) { wakep(); return; }
    t = old;
  }
  spin_lock(&w->lock);
  w->buf[w->tail++ & (QCAP - 1)] = t;
  spin_unlock(&w->lock);
  wakep();
}

static rtask_t *pop_local(worker_t *w) {
  rtask_t *t = atomic_exchange_explicit(&w->runnext, NULL, memory_order_acq_rel);
  if (t) return t;
  spin_lock(&w->lock);
  if (w->head != w->tail) t = w->buf[w->head++ & (QCAP - 1)];
  spin_unlock(&w->lock);
  return t;
}

static rtask_t *steal(worker_t *w, int take_runnext) {
  int n = cfg.workers;
  w->rng = w->rng * 6364136223846793005ULL + 1442695040888963407ULL;
  int start = (int)((w->rng >> 33) % (uint64_t)n);
  for (int k = 0; k < n; k++) {
    worker_t *v = &W[(start + k) % n];
    if (v == w) continue;
    rtask_t *t = NULL;
    spin_lock(&v->lock);
    if (v->head != v->tail) t = v->buf[v->head++ & (QCAP - 1)];
    spin_unlock(&v->lock);
    if (t) return t;
    if (take_runnext && atomic_load_explicit(&v->runnext, memory_order_relaxed)) {
      t = atomic_exchange_explicit(&v->runnext, NULL, memory_order_acq_rel);
      if (t) return t;
    }
  }
  return NULL;
}

/* Wake an idle worker if work was made and nobody is spinning to find it. */
static void wakep(void) {
  atomic_thread_fence(memory_order_seq_cst);
  if (atomic_load(&nidle) == 0 || atomic_load(&nspinning) != 0) return;
  pthread_mutex_lock(&sched_m);
  if (idle_n == 0) { pthread_mutex_unlock(&sched_m); return; }
  int id = idle_stack[--idle_n];
  atomic_fetch_sub(&nidle, 1);
  atomic_fetch_add(&nspinning, 1); /* the woken worker starts spinning */
  pthread_mutex_unlock(&sched_m);
  worker_t *v = &W[id];
  pthread_mutex_lock(&v->m);
  v->notified = 1;
  pthread_cond_signal(&v->c);
  pthread_mutex_unlock(&v->m);
}

static void wake_all(void) {
  for (int i = 0; i < cfg.workers; i++) {
    pthread_mutex_lock(&W[i].m);
    W[i].notified = 1;
    pthread_cond_signal(&W[i].c);
    pthread_mutex_unlock(&W[i].m);
  }
}

/* ---------- the instance's operations ---------- */
static inline void enqueue_waiter(rtask_t *t, int front) {
  t->next = NULL;
  if (front) {
    t->next = inst.head;
    inst.head = t;
    if (!inst.tail) inst.tail = t;
  } else {
    if (inst.tail) inst.tail->next = t; else inst.head = t;
    inst.tail = t;
  }
}
static inline rtask_t *pop_waiter(void) {
  rtask_t *t = inst.head;
  inst.head = t->next;
  if (!inst.head) inst.tail = NULL;
  t->next = NULL;
  return t;
}

/* Returns 1 if the task now holds the instance, 0 if it parked (after which
   the caller must not touch the task: another worker may already run it). */
static int acquire_slow(rtask_t *t, int retry) {
  spin_lock(&inst.qlock);
  if (retry) inst.woken = 0;
  for (;;) {
    uint64_t s = atomic_load_explicit(&inst.state, memory_order_relaxed);
    int may_take = cfg.mode == BARGE ? !(s & 1) : (s == 0);
    if (may_take) {
      if (atomic_compare_exchange_strong_explicit(&inst.state, &s, s | 1,
              memory_order_acquire, memory_order_relaxed)) {
        spin_unlock(&inst.qlock);
        return 1;
      }
      continue;
    }
    /* count ourselves as a waiter while the instance is still held, so the
       holder's fast release fails and it comes through qlock */
    if (atomic_compare_exchange_strong_explicit(&inst.state, &s, s + 2,
            memory_order_relaxed, memory_order_relaxed)) {
      t->resuming = 1;
      enqueue_waiter(t, retry && cfg.mode == BARGE);
      spin_unlock(&inst.qlock);
      return 0;
    }
  }
}

static inline int acquire(rtask_t *t) {
  uint_fast64_t z = 0;
  if (atomic_compare_exchange_strong_explicit(&inst.state, &z, 1,
          memory_order_acquire, memory_order_relaxed))
    return 1;
  return acquire_slow(t, 0);
}

static void release(worker_t *w) {
  uint_fast64_t one = 1;
  if (atomic_compare_exchange_strong_explicit(&inst.state, &one, 0,
          memory_order_release, memory_order_relaxed))
    return;
  spin_lock(&inst.qlock);
  uint64_t s = atomic_load_explicit(&inst.state, memory_order_relaxed);
  if ((s >> 1) == 0) {
    atomic_fetch_sub_explicit(&inst.state, 1, memory_order_release);
    spin_unlock(&inst.qlock);
    return;
  }
  rtask_t *h = inst.head;
  int handoff = cfg.mode == FIFO;
  if (!handoff && now_ticks() - h->t_req > cfg.guard_ticks) {
    handoff = 1;
    inst.guard_handoffs++;
  }
  if (handoff) {
    pop_waiter();
    inst.handoffs++;
    h->granted = 1;
    /* still held: ownership moves to h. Acquire/release pairing for the
       state goes through qlock and the run queue's lock. */
    atomic_fetch_sub_explicit(&inst.state, 2, memory_order_release);
    spin_unlock(&inst.qlock);
    push_local(w, h, 1);
    return;
  }
  if (inst.woken) { /* someone is already on its way; just let go */
    atomic_fetch_sub_explicit(&inst.state, 1, memory_order_release);
    spin_unlock(&inst.qlock);
    return;
  }
  pop_waiter();
  inst.woken = 1;
  inst.wakes++;
  atomic_fetch_sub_explicit(&inst.state, 3, memory_order_release);
  spin_unlock(&inst.qlock);
  push_local(w, h, 1);
}

/* ---------- work ---------- */
#define MUL 6364136223846793005ULL
static inline void critical(void) {
  if (atomic_exchange_explicit(&inst.in_cs, 1, memory_order_relaxed)) {
    fprintf(stderr, "exclusion violated\n");
    abort();
  }
  inst.counter++;
  for (uint64_t r = 0; r < cfg.cs_rounds; r++)
    for (int j = 0; j < SW; j++) inst.a[j] = inst.a[j] * MUL + (uint64_t)(j + 1);
  atomic_store_explicit(&inst.in_cs, 0, memory_order_relaxed);
}

static inline uint64_t outside(uint64_t x, uint64_t iters) {
  for (uint64_t i = 0; i < iters; i++) x = x * MUL + 1;
  return x;
}

/* ---------- running a task ---------- */
static void finish_task(void) {
  if (atomic_fetch_add(&done_tasks, 1) + 1 == cfg.tasks) {
    atomic_store(&shutdown_, 1);
    wake_all();
  }
}

static void run_task(worker_t *w, rtask_t *t) {
  if (t->resuming) {
    t->resuming = 0;
    if (t->granted) { t->granted = 0; goto have; }
    if (acquire_slow(t, 1)) goto have;
    return; /* parked again at the head */
  }
  if (cfg.ms ? atomic_load_explicit(&stop, memory_order_relaxed)
             : t->ops >= cfg.ops_per_task) {
    finish_task();
    return;
  }
  t->rng = outside(t->rng, cfg.out_iters);
  t->t_req = now_ticks();
  if (!acquire(t)) return;
have:;
  uint64_t wait = (uint64_t)((double)(now_ticks() - t->t_req) * ns_per_tick);
  critical();
  release(w);
  t->ops++;
  w->hist[hidx(wait)]++;
  if (wait > w->maxwait_ns) w->maxwait_ns = wait;
  if (!atomic_load_explicit(&stop, memory_order_relaxed)) w->window_ops++;
  push_local(w, t, 0); /* yield: back of this worker's queue */
}

static rtask_t *find_work(worker_t *w, int take_runnext) {
  rtask_t *t = pop_local(w);
  if (!t) t = steal(w, take_runnext);
  return t;
}

static void *worker_main(void *arg) {
  worker_t *w = arg;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  for (;;) {
    rtask_t *t = find_work(w, 0);
    if (!t && !atomic_load(&shutdown_)) {
      if (!w->spinning) { w->spinning = 1; atomic_fetch_add(&nspinning, 1); }
      for (int i = 0; i < SPIN_ROUNDS && !t; i++) {
        cpu_relax();
        t = find_work(w, i == SPIN_ROUNDS - 1);
      }
    }
    if (t) {
      if (w->spinning) {
        w->spinning = 0;
        atomic_fetch_sub(&nspinning, 1);
        wakep(); /* as Go's resetspinning */
      }
      run_task(w, t);
      continue;
    }
    if (atomic_load(&shutdown_)) break;
    /* park */
    if (w->spinning) { w->spinning = 0; atomic_fetch_sub(&nspinning, 1); }
    pthread_mutex_lock(&sched_m);
    idle_stack[idle_n++] = w->id;
    atomic_fetch_add(&nidle, 1);
    pthread_mutex_unlock(&sched_m);
    atomic_thread_fence(memory_order_seq_cst);
    t = find_work(w, 1);
    if (t || atomic_load(&shutdown_)) {
      int removed = 0;
      pthread_mutex_lock(&sched_m);
      for (int i = 0; i < idle_n; i++)
        if (idle_stack[i] == w->id) {
          idle_stack[i] = idle_stack[--idle_n];
          atomic_fetch_sub(&nidle, 1);
          removed = 1;
          break;
        }
      pthread_mutex_unlock(&sched_m);
      if (!removed) { /* a waker took us: consume its notification */
        pthread_mutex_lock(&w->m);
        w->notified = 0;
        pthread_mutex_unlock(&w->m);
        w->spinning = 1;
      }
      if (t) {
        if (w->spinning) { w->spinning = 0; atomic_fetch_sub(&nspinning, 1); wakep(); }
        run_task(w, t);
      }
      continue;
    }
    pthread_mutex_lock(&w->m);
    while (!w->notified && !atomic_load(&shutdown_)) pthread_cond_wait(&w->c, &w->m);
    int was_notified = w->notified;
    w->notified = 0;
    pthread_mutex_unlock(&w->m);
    if (was_notified) w->spinning = 1; /* the waker counted us spinning */
    else {
      /* shutdown without notification: still on the idle stack */
      pthread_mutex_lock(&sched_m);
      for (int i = 0; i < idle_n; i++)
        if (idle_stack[i] == w->id) {
          idle_stack[i] = idle_stack[--idle_n];
          atomic_fetch_sub(&nidle, 1);
          break;
        }
      pthread_mutex_unlock(&sched_m);
    }
  }
  if (w->spinning) { w->spinning = 0; atomic_fetch_sub(&nspinning, 1); }
  return NULL;
}

/* ---------- verification: n applications of x -> x*MUL + c ---------- */
static uint64_t affine_pow(uint64_t c, uint64_t n) {
  /* compose (m, b) : x -> m x + b */
  uint64_t rm = 1, rb = 0, bm = MUL, bb = c;
  while (n) {
    if (n & 1) { rb = bm * rb + bb; rm = bm * rm; }
    bb = bm * bb + bb; bm = bm * bm;
    n >>= 1;
  }
  (void)rm;
  return rb; /* starting from x = 0 */
}

typedef struct {
  double ops_s;
  uint64_t p50, p99, max, total_ops;
  double guard_frac;
  int ok;
} result_t;

static uint64_t pct(uint64_t *h, uint64_t n, double q) {
  uint64_t want = (uint64_t)(q * (double)n);
  if (want >= n) want = n - 1;
  uint64_t acc = 0;
  for (int i = 0; i < HB; i++) {
    acc += h[i];
    if (acc > want) return hval(i);
  }
  return 0;
}

static result_t run_once(int rep) {
  memset(&inst, 0, sizeof inst);
  memset(T, 0, sizeof(T[0]) * (size_t)cfg.tasks);
  atomic_store(&nidle, 0); atomic_store(&nspinning, 0);
  atomic_store(&done_tasks, 0); atomic_store(&stop, 0); atomic_store(&shutdown_, 0);
  idle_n = 0;
  for (int i = 0; i < cfg.workers; i++) {
    worker_t *w = &W[i];
    w->head = w->tail = 0;
    atomic_store(&w->runnext, NULL);
    w->notified = 0; w->spinning = 0; w->id = i;
    w->window_ops = 0; w->maxwait_ns = 0;
    memset(w->hist, 0, sizeof w->hist);
    w->rng = 0x9e3779b97f4a7c15ULL * (uint64_t)(i + 1 + rep * 131);
    atomic_store(&w->lock.f, 0);
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
  }
  for (int i = 0; i < cfg.tasks; i++) {
    T[i].id = i;
    T[i].rng = (uint64_t)i * 0x2545F4914F6CDD1DULL + 1;
    worker_t *w = &W[i % cfg.workers];
    w->buf[w->tail++ & (QCAP - 1)] = &T[i];
  }
  uint64_t t0 = now_ticks();
  for (int i = 0; i < cfg.workers; i++) pthread_create(&W[i].th, NULL, worker_main, &W[i]);
  uint64_t t1;
  if (cfg.ms) {
    struct timespec ts = {(time_t)(cfg.ms / 1000), (long)((cfg.ms % 1000) * 1000000)};
    nanosleep(&ts, NULL);
    atomic_store(&stop, 1);
    t1 = now_ticks();
  }
  for (int i = 0; i < cfg.workers; i++) pthread_join(W[i].th, NULL);
  if (!cfg.ms) t1 = now_ticks();

  result_t r = {0};
  static uint64_t h[HB];
  memset(h, 0, sizeof h);
  uint64_t n = 0, wops = 0, mx = 0;
  for (int i = 0; i < cfg.workers; i++) {
    for (int b = 0; b < HB; b++) { h[b] += W[i].hist[b]; n += W[i].hist[b]; }
    wops += W[i].window_ops;
    if (W[i].maxwait_ns > mx) mx = W[i].maxwait_ns;
    pthread_mutex_destroy(&W[i].m);
    pthread_cond_destroy(&W[i].c);
  }
  uint64_t task_ops = 0;
  for (int i = 0; i < cfg.tasks; i++) task_ops += T[i].ops;
  int ok = 1;
  if (task_ops != inst.counter || n != inst.counter) ok = 0;
  if (!cfg.ms && inst.counter != cfg.ops_per_task * (uint64_t)cfg.tasks) ok = 0;
  for (int j = 0; j < SW; j++)
    if (inst.a[j] != affine_pow((uint64_t)(j + 1), inst.counter * cfg.cs_rounds)) ok = 0;
  if (atomic_load(&inst.state) != 0 || inst.head) ok = 0;
  if (cfg.mode == FIFO && inst.guard_handoffs) ok = 0;
  if (!ok)
    fprintf(stderr, "CHECK FAILED: counter=%llu task_ops=%llu hist=%llu state=%llu\n",
            (unsigned long long)inst.counter, (unsigned long long)task_ops,
            (unsigned long long)n, (unsigned long long)atomic_load(&inst.state));
  double secs = (double)(t1 - t0) * ns_per_tick / 1e9;
  r.total_ops = inst.counter;
  r.ops_s = (double)(cfg.ms ? wops : inst.counter) / secs;
  r.p50 = pct(h, n, 0.50);
  r.p99 = pct(h, n, 0.99);
  r.max = mx;
  r.guard_frac = inst.counter ? (double)inst.guard_handoffs / (double)inst.counter : 0;
  r.ok = ok;
  return r;
}

static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

static uint64_t calibrate(int which) {
  /* iterations per microsecond */
  uint64_t iters = 2000000, t0 = now_ticks();
  if (which == 0) {
    cfg.cs_rounds = iters;
    critical();
    memset(&inst, 0, sizeof inst);
  } else {
    volatile uint64_t sink = outside(1, iters);
    (void)sink;
  }
  double ns = (double)(now_ticks() - t0) * ns_per_tick;
  return (uint64_t)((double)iters * 1000.0 / ns);
}

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  ns_per_tick = (double)tb.numer / (double)tb.denom;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  cfg = (cfg_t){.mode = BARGE, .workers = 8, .tasks = 64, .cs_ns = 200, .out_ns = 1000,
                .ms = 1000, .ops_per_task = 0, .reps = 5};
  uint64_t guard_us = 1000;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    const char *v = i + 1 < argc ? argv[i + 1] : "";
    if (!strcmp(a, "--mode")) { cfg.mode = !strcmp(v, "fifo") ? FIFO : BARGE; i++; }
    else if (!strcmp(a, "--workers")) { cfg.workers = atoi(v); i++; }
    else if (!strcmp(a, "--tasks")) { cfg.tasks = atoi(v); i++; }
    else if (!strcmp(a, "--cs-ns")) { cfg.cs_ns = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--out-ns")) { cfg.out_ns = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--ms")) { cfg.ms = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--ops")) { cfg.ops_per_task = strtoull(v, 0, 10); cfg.ms = 0; i++; }
    else if (!strcmp(a, "--guard-us")) { guard_us = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--reps")) { cfg.reps = atoi(v); i++; }
    else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
  }
  if (cfg.workers < 1 || cfg.workers > MAXW || cfg.tasks < 1 || cfg.tasks > MAXT) {
    fprintf(stderr, "bad workers/tasks\n");
    return 2;
  }
  cfg.guard_ticks = (uint64_t)((double)guard_us * 1000.0 / ns_per_tick);
  uint64_t cs_per_us = calibrate(0), out_per_us = calibrate(1);
  cfg.cs_rounds = cfg.cs_ns * cs_per_us / 1000;
  if (cfg.cs_rounds == 0) cfg.cs_rounds = 1;
  cfg.out_iters = cfg.out_ns * out_per_us / 1000;

  double ops[64], p50[64], p99[64], gf[64];
  uint64_t mx = 0;
  int ok = 1, reps = cfg.reps > 64 ? 64 : cfg.reps;
  for (int r = 0; r < reps; r++) {
    result_t x = run_once(r);
    ops[r] = x.ops_s; p50[r] = (double)x.p50; p99[r] = (double)x.p99; gf[r] = x.guard_frac;
    if (x.max > mx) mx = x.max;
    ok &= x.ok;
  }
  qsort(ops, (size_t)reps, sizeof(double), cmp_d);
  qsort(p50, (size_t)reps, sizeof(double), cmp_d);
  qsort(p99, (size_t)reps, sizeof(double), cmp_d);
  qsort(gf, (size_t)reps, sizeof(double), cmp_d);
  printf("p3 impl=c mode=%s workers=%d tasks=%d cs_ns=%llu out_ns=%llu reps=%d "
         "ops_per_s=%.4g wait_p50_ns=%.0f wait_p99_ns=%.0f wait_max_ns=%llu "
         "guard_handoff_frac=%.4f ok=%d\n",
         cfg.mode == FIFO ? "fifo" : "barge", cfg.workers, cfg.tasks,
         (unsigned long long)cfg.cs_ns, (unsigned long long)cfg.out_ns, reps,
         ops[reps / 2], p50[reps / 2], p99[reps / 2], (unsigned long long)mx,
         gf[reps / 2], ok);
  return ok ? 0 : 1;
}
