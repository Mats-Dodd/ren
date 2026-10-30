// X3: the runtime and the harness. See rt.h and path.c.
//
//   server <strategy> <workers> <conns_per_worker> <hold_us> <bg> <seconds>
//
// strategy: park, handoff (built with -DSUSP); unfair, spin (built without).
//   park     (a) CAS; on contention spin ~1 us, then park the task in the
//            instance's queue; a release wakes the first waiter to retry
//            (barging allowed, as Go's normal mode).
//   handoff  park, plus Go's starvation rule: a release whose first waiter
//            has waited 1 ms or more hands the instance straight to it.
//   unfair   (b) os_unfair_lock: the thread blocks in the kernel.
//   spin     (b) a TTAS spin lock: the thread spins until it gets it.
// Each worker is a pthread with a FIFO run queue of tasks; a task stays on
// its home worker. A connection task runs path.c's serve loop: 50% puts,
// 50% gets on one shared memtable (an open-addressing table). Every 8th recv
// suspends and is answered at once (re-queued), so a worker interleaves its
// connections. bg=1 adds one background task a worker that never touches the
// memtable: 2 us of work, then yield. hold_us folds a spin of real work into
// put, under the take.
#include "rt.h"
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double tick_ns;
uint64_t now_ticks(void) { return mach_absolute_time(); }
static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }

_Atomic int stop_flag;
inst_lock mt_lock;
int strategy;
static uint64_t hold_ticks, spin_budget_ticks, handoff_ticks, idle_spin_ticks;
static int nworkers, nconns, nbg;

/* ---------- workers ---------- */
#define MAXSAMP (1u << 21)
typedef struct worker {
  _Alignas(128) pthread_mutex_t m;
  pthread_cond_t c;
  task *head, *tail;
  int sleeping;
  int idx, live;
  uint64_t reqs, puts, gets, bg_ops, chk, contended, parks, handoffs;
  uint64_t spin_ticks, block_ticks, idle_ticks, work_ticks, idle_spin_ticks_used;
  double cpu_ns;
  uint64_t *samp;
  uint32_t nsamp;
  pthread_t th;
} worker;
static worker *W;
static _Thread_local worker *me;

typedef struct conn {
  task t;
  uint64_t rng;
  uint32_t nrecv;
  uint64_t nreq;
} conn;
static uint64_t reqs_limit; /* REQS=N: each connection makes N requests, then ends (checks) */

static inline bool running(void) { return !atomic_load_explicit(&stop_flag, memory_order_relaxed); }

void requeue(task *t) {
  worker *w = &W[t->home];
  pthread_mutex_lock(&w->m);
  t->next = NULL;
  if (w->tail) w->tail->next = t;
  else w->head = t;
  w->tail = t;
  if (w->sleeping) pthread_cond_signal(&w->c);
  pthread_mutex_unlock(&w->m);
}

/* ---------- the world, and plain helpers ---------- */
#define KEYS (1u << 15)
#define SLOTS (1u << 16)
static struct { uint64_t k, v; } table[SLOTS];

static inline uint64_t xorshift(uint64_t *s) {
  uint64_t x = *s;
  x ^= x << 13; x ^= x >> 7; x ^= x << 17;
  return *s = x;
}
bool next_request(task *t, request *r) {
  if (!running()) return false;
  conn *c = (conn *)t;
  if (reqs_limit && c->nreq++ >= reqs_limit) return false;
  uint64_t x = xorshift(&c->rng);
  r->op = x & 1;
  r->key = (x >> 8) & (KEYS - 1);
  r->val = x >> 20;
  return true;
}
bool recv_would_block(task *t) { return (++((conn *)t)->nrecv & 7) == 0; }
uint64_t parse_key(const request *r) { /* FNV-1a over 64 bytes derived from the key */
  uint64_t h = 1469598103934665603ull;
  for (int i = 0; i < 64; i++) {
    h ^= (r->key >> (i & 15)) & 0xff;
    h *= 1099511628211ull;
  }
  return (h & ~(uint64_t)(KEYS * 4 - 1)) | (r->key << 1) | 1; /* distinct, nonzero */
}
bool validate(uint64_t key, uint64_t val) { return key != 0 || val != 0; }
void mt_insert(uint64_t key, uint64_t val) {
  uint32_t i = (uint32_t)(key >> 1) & (SLOTS - 1);
  while (table[i].k && table[i].k != key) i = (i + 1) & (SLOTS - 1);
  table[i].k = key;
  table[i].v = val;
}
uint64_t mt_lookup(uint64_t key) {
  uint32_t i = (uint32_t)(key >> 1) & (SLOTS - 1);
  while (table[i].k) {
    if (table[i].k == key) return table[i].v;
    i = (i + 1) & (SLOTS - 1);
  }
  return 0;
}
static _Thread_local volatile uint64_t sink;
static void work_for(uint64_t ticks) {
  uint64_t t0 = now_ticks(), x = t0;
  while (now_ticks() - t0 < ticks)
    for (int i = 0; i < 16; i++) x = x * 6364136223846793005ull + 1442695040888963407ull;
  sink = x;
  if (running()) me->work_ticks += now_ticks() - t0;
}
void hold_work(void) {
  if (hold_ticks) work_for(hold_ticks);
}
uint64_t encode_resp(uint64_t v) { return v * 31 + 7; }
void respond(task *t, uint64_t resp) {
  (void)t;
  if (!running()) return;
  me->reqs++;
  me->chk ^= resp;
}

static inline void record(uint64_t ticks) {
  if (running() && me->nsamp < MAXSAMP) me->samp[me->nsamp++] = ticks;
}

/* ---------- (a): the task-parking take ---------- */
static inline void qlock(inst_lock *l) {
  uint32_t z;
  for (;;) {
    z = 0;
    if (atomic_compare_exchange_weak_explicit(&l->qlock, &z, 1, memory_order_acquire, memory_order_relaxed)) return;
    while (atomic_load_explicit(&l->qlock, memory_order_relaxed)) cpu_relax();
  }
}
static inline void qunlock(inst_lock *l) { atomic_store_explicit(&l->qlock, 0, memory_order_release); }

bool take_slow(task *t, inst_lock *l) {
  uint64_t t0 = now_ticks();
  bool again = t->waiting; /* woken once already and lost the race: queue at the head (Go) */
  if (!again) { t->waiting = 1; t->wait_start = t0; }
  uint64_t t1;
  do {
    cpu_relax();
    if (take_fast(l)) {
      if (running()) me->spin_ticks += now_ticks() - t0;
      return true;
    }
  } while ((t1 = now_ticks()) - t0 < spin_budget_ticks);
  if (running()) me->spin_ticks += t1 - t0;
  qlock(l);
  uint32_t old = atomic_fetch_or_explicit(&l->state, L_WAITERS, memory_order_acq_rel);
  if (!(old & L_LOCKED)) {
    uint32_t s = old | L_WAITERS;
    if (atomic_compare_exchange_strong_explicit(&l->state, &s, s | L_LOCKED, memory_order_acquire,
                                                memory_order_relaxed)) {
      if (!l->wq_head) atomic_fetch_and_explicit(&l->state, ~(uint32_t)L_WAITERS, memory_order_relaxed);
      qunlock(l);
      return true;
    }
  }
  if (again) {
    t->next = l->wq_head;
    l->wq_head = t;
    if (!l->wq_tail) l->wq_tail = t;
  } else {
    t->next = NULL;
    if (l->wq_tail) l->wq_tail->next = t;
    else l->wq_head = t;
    l->wq_tail = t;
  }
  qunlock(l);
  if (running()) me->parks++;
  return false;
}
void release_slow(inst_lock *l) {
  qlock(l);
  task *w = l->wq_head;
  if (!w) { /* can't happen: WAITERS is cleared whenever the queue empties */
    atomic_fetch_and_explicit(&l->state, ~(uint32_t)(L_LOCKED | L_WAITERS), memory_order_release);
    qunlock(l);
    return;
  }
  l->wq_head = w->next;
  if (!l->wq_head) {
    l->wq_tail = NULL;
    atomic_fetch_and_explicit(&l->state, ~(uint32_t)L_WAITERS, memory_order_relaxed);
  }
  if (strategy == 1 && now_ticks() - w->wait_start >= handoff_ticks) {
    w->granted = 1; /* L_LOCKED stays set: ownership passes to w */
    if (running()) me->handoffs++;
  } else {
    w->granted = 0;
    atomic_fetch_and_explicit(&l->state, ~(uint32_t)L_LOCKED, memory_order_release);
  }
  qunlock(l);
  requeue(w);
}
void note_wait_done(task *t) {
  t->waiting = 0;
  if (running()) me->contended++;
  record(now_ticks() - t->wait_start);
}

/* ---------- (b): thread locks ---------- */
void thread_take(inst_lock *l) {
  if (strategy == 2) {
    os_unfair_lock_t ol = (os_unfair_lock_t)&l->os_lock;
    if (LIKELY(os_unfair_lock_trylock(ol))) return;
    uint64_t t0 = now_ticks();
    os_unfair_lock_lock(ol);
    uint64_t dt = now_ticks() - t0;
    if (running()) { me->block_ticks += dt; me->contended++; }
    record(dt);
  } else {
    uint32_t z = 0;
    if (LIKELY(atomic_compare_exchange_strong_explicit(&l->state, &z, 1, memory_order_acquire, memory_order_relaxed)))
      return;
    uint64_t t0 = now_ticks();
    for (;;) {
      while (atomic_load_explicit(&l->state, memory_order_relaxed)) cpu_relax();
      z = 0;
      if (atomic_compare_exchange_weak_explicit(&l->state, &z, 1, memory_order_acquire, memory_order_relaxed)) break;
    }
    uint64_t dt = now_ticks() - t0;
    if (running()) { me->spin_ticks += dt; me->contended++; }
    record(dt);
  }
}
void thread_release(inst_lock *l) {
  if (strategy == 2) os_unfair_lock_unlock((os_unfair_lock_t)&l->os_lock);
  else atomic_store_explicit(&l->state, 0, memory_order_release);
}

/* ---------- the background task: never touches the memtable ---------- */
static ren_ret bg_body(task *t, frame *hf, char *sp, uint64_t in) {
  (void)in;
  if (!running()) return (ren_ret){DONE, 0};
  if (reqs_limit && ((conn *)t)->nreq++ >= reqs_limit) return (ren_ret){DONE, 0};
  work_for((uint64_t)(2000 / tick_ns));
  if (running()) me->bg_ops++;
  hf->state = 1; hf->sp = sp; t->top = hf; /* Async.yield() */
  requeue(t);
  return (ren_ret){PENDING, 0};
}

/* ---------- trampoline and worker loop ---------- */
static int step(task *t) {
  frame *f = t->top;
  uint64_t in = 0;
  for (;;) {
    ren_ret r = f->resume(t, f, f->sp, in);
    if (r.st == PENDING) return 0;
    frame *p = f->parent;
    if (!p) return 1;
    t->top = f = p;
    in = r.v;
  }
}
static double thread_cpu_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
  return ts.tv_sec * 1e9 + ts.tv_nsec;
}
static _Atomic int ready, go;
static void *worker_main(void *arg) {
  me = arg;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  atomic_fetch_add(&ready, 1);
  while (!atomic_load(&go)) cpu_relax();
  double c0 = thread_cpu_ns();
  bool snap = false;
  while (me->live > 0) {
    if (idle_spin_ticks && !__atomic_load_n(&me->head, __ATOMIC_RELAXED)) {
      /* Go's spinning M: poll the run queue a while before sleeping */
      uint64_t t0 = now_ticks();
      while (!__atomic_load_n(&me->head, __ATOMIC_RELAXED) && now_ticks() - t0 < idle_spin_ticks) cpu_relax();
      if (running()) me->idle_spin_ticks_used += now_ticks() - t0;
    }
    pthread_mutex_lock(&me->m);
    while (!me->head) {
      me->sleeping = 1;
      uint64_t t0 = now_ticks();
      pthread_cond_wait(&me->c, &me->m);
      if (running()) me->idle_ticks += now_ticks() - t0;
      me->sleeping = 0;
    }
    task *t = me->head;
    me->head = t->next;
    if (!me->head) me->tail = NULL;
    pthread_mutex_unlock(&me->m);
    if (step(t)) { me->live--; free(t); }
    if (!snap && !running()) { snap = true; me->cpu_ns = thread_cpu_ns() - c0; }
  }
  if (!snap) me->cpu_ns = thread_cpu_ns() - c0;
  return NULL;
}

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  if (argc < 7) {
    fprintf(stderr, "usage: %s park|handoff|unfair|spin workers conns_per_worker hold_us bg seconds\n", argv[0]);
    return 2;
  }
  const char *names[] = {"park", "handoff", "unfair", "spin"};
  strategy = -1;
  for (int i = 0; i < 4; i++) if (!strcmp(argv[1], names[i])) strategy = i;
#ifdef SUSP
  if (strategy != 0 && strategy != 1) { fprintf(stderr, "this build (a) runs park|handoff\n"); return 2; }
  const char *build = "a_susp";
#else
  if (strategy != 2 && strategy != 3) { fprintf(stderr, "this build (b) runs unfair|spin\n"); return 2; }
  const char *build = "b_plain";
#endif
  if (getenv("REQS")) reqs_limit = strtoull(getenv("REQS"), 0, 10);
  nworkers = atoi(argv[2]);
  nconns = atoi(argv[3]);
  double hold_us = atof(argv[4]);
  nbg = atoi(argv[5]);
  double secs = atof(argv[6]);
  hold_ticks = (uint64_t)(hold_us * 1000 / tick_ns);
  /* SPIN_US: the take's spin before parking (default 1 us, r5's S3).
     IDLE_SPIN_US: a worker with an empty run queue polls it this long before
     sleeping on its condition variable (default 0). Both (a) only. */
  spin_budget_ticks = (uint64_t)((getenv("SPIN_US") ? atof(getenv("SPIN_US")) : 1.0) * 1000 / tick_ns);
  idle_spin_ticks = (uint64_t)((getenv("IDLE_SPIN_US") ? atof(getenv("IDLE_SPIN_US")) : 0.0) * 1000 / tick_ns);
  handoff_ticks = (uint64_t)(1e6 / tick_ns);      /* 1 ms */

  W = calloc(nworkers, sizeof *W);
  for (int i = 0; i < nworkers; i++) {
    worker *w = &W[i];
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
    w->idx = i;
    w->samp = malloc(MAXSAMP * sizeof(uint64_t));
    for (int j = 0; j < nconns + nbg; j++) {
      conn *c = calloc(1, sizeof *c);
      task *t = &c->t;
      t->home = i;
      t->limit = t->frames + SEG;
      frame *f = (frame *)t->frames;
      f->resume = j < nconns ? serve : bg_body;
      f->sp = t->frames + 64;
      t->top = f;
      c->rng = 0x9e3779b97f4a7c15ull * (uint64_t)(i * 1000 + j + 1);
      t->next = NULL;
      if (w->tail) w->tail->next = t;
      else w->head = t;
      w->tail = t;
      w->live++;
    }
  }
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 8u << 20); /* SYNTHESIS §2i */
  for (int i = 0; i < nworkers; i++) pthread_create(&W[i].th, &at, worker_main, &W[i]);
  while (atomic_load(&ready) < nworkers) usleep(100);
  uint64_t t0 = now_ticks();
  atomic_store(&go, 1);
  double wall;
  if (reqs_limit) {
    for (int i = 0; i < nworkers; i++) pthread_join(W[i].th, NULL);
    wall = (now_ticks() - t0) * tick_ns;
  } else {
    usleep((useconds_t)(secs * 1e6));
    atomic_store(&stop_flag, 1);
    wall = (now_ticks() - t0) * tick_ns;
    for (int i = 0; i < nworkers; i++) pthread_join(W[i].th, NULL);
  }

  uint64_t reqs = 0, bg = 0, cont = 0, parks = 0, hand = 0, chk = 0, ns = 0;
  double spin = 0, block = 0, idle = 0, work = 0, cpu = 0, ispin = 0;
  for (int i = 0; i < nworkers; i++) {
    worker *w = &W[i];
    reqs += w->reqs; bg += w->bg_ops; cont += w->contended; parks += w->parks; hand += w->handoffs;
    chk ^= w->chk; ns += w->nsamp;
    spin += w->spin_ticks * tick_ns; block += w->block_ticks * tick_ns;
    idle += w->idle_ticks * tick_ns; ispin += w->idle_spin_ticks_used * tick_ns; work += w->work_ticks * tick_ns; cpu += w->cpu_ns;
  }
  uint64_t *all = malloc((ns + 1) * sizeof *all), k = 0;
  for (int i = 0; i < nworkers; i++)
    for (uint32_t j = 0; j < W[i].nsamp; j++) all[k++] = W[i].samp[j];
  qsort(all, ns, sizeof *all, cmp_u64);
  double p50 = ns ? all[ns / 2] * tick_ns / 1e3 : 0, p99 = ns ? all[(ns * 99) / 100] * tick_ns / 1e3 : 0,
         mx = ns ? all[ns - 1] * tick_ns / 1e3 : 0;
  double cap = wall * nworkers;
  bool ok = atomic_load(&mt_lock.state) == 0 && mt_lock.wq_head == NULL &&
            (!reqs_limit || reqs == reqs_limit * (uint64_t)nworkers * nconns);
  printf("X3 build=%s strategy=%s workers=%d conns=%d hold_us=%g bg=%d secs=%.2f req_per_s=%.0f "
         "ns_per_req_per_worker=%.1f contended_frac=%.4f parks=%llu handoffs=%llu "
         "wait_p50_us=%.2f wait_p99_us=%.2f wait_max_us=%.1f "
         "reqs=%llu spin_pct=%.2f idle_spin_pct=%.2f block_pct=%.2f idle_pct=%.2f work_pct=%.2f cpu_pct=%.2f bg_ops_per_s=%.0f chk=%llx check=%s\n",
         build, names[strategy], nworkers, nconns, hold_us, nbg, wall / 1e9, reqs / (wall / 1e9),
         cap / (reqs ? reqs : 1), reqs ? (double)cont / reqs : 0, (unsigned long long)parks,
         (unsigned long long)hand, p50, p99, mx, (unsigned long long)reqs, 100 * spin / cap, 100 * ispin / cap, 100 * block / cap, 100 * idle / cap,
         100 * work / cap, 100 * cpu / cap, bg / (wall / 1e9), (unsigned long long)chk, ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}
