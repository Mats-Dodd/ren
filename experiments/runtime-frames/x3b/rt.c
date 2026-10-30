// X3b: the runtime and the harness. See rt.h and path.c.
//
//   server <strategy> <workers> <conns_per_worker> <hold_us> <bg> <seconds>
//
// strategy, built with -DSUSP (a):
//   park     X3's parking take: CAS; on contention spin ~1 us, then park the
//            task in the instance's queue; a release wakes the first waiter.
//   handoff  park, plus Go's rule: a first waiter that has waited 1 ms gets
//            the instance handed to it.
//   p2       adaptive parking: spin while the holder's worker is running, up
//            to SPIN_US (default 4), then park; hand-off on; a worker with an
//            empty run queue polls it IDLE_SPIN_US (default 5) before sleeping
//            (ship, shipded and move too; park and handoff default to 0, as X3).
//   ship     (H) the memtable lives on worker 0, its home. An operation from
//            another worker is a D.Call pushed to the home's inbound SPSC ring
//            for that worker; the task suspends until the reply. The home
//            drains its rings in batches (BATCH per ring, default 16) between
//            its own tasks and pushes replies on the reverse rings. A request
//            on the home worker calls the operation directly.
//   shipded  ship, with the home worker dedicated: it has no connections.
//   move     an `at` block's task hops to the home worker (a task pushed on the
//            same rings), runs its OPS operations there directly, and hops back.
//   moveded  move, with the home worker dedicated.
// strategy, built without (b): unfair (os_unfair_lock), spin (TTAS).
//
// Environment: OPS=N shared operations a request (an `at` block, default 1);
// SHARE_PCT=P only P% of requests touch the table, the rest do LOCAL_US
// (default 2) of local work; REQS=N each connection makes N requests and
// stops (checks); DISJOINT=1 each connection owns its own keys, so the final
// table and the response checksum are independent of interleaving.
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
int nops = 1;
int fast;
_Thread_local int cur_worker;
static uint64_t hold_ticks, spin_budget_ticks, handoff_ticks, idle_spin_ticks, local_ticks;
static int nworkers, nconns, nbg, share_pct = 100, batch = 16, disjoint;
static uint32_t key_range = 0; /* DISJOINT: keys per connection (a power of two) */
static _Atomic int global_live;

/* ---------- workers ---------- */
#define MAXSAMP (1u << 20)
typedef struct worker {
  _Alignas(128) pthread_mutex_t m;
  pthread_cond_t c;
  task *head, *tail;
  _Atomic int sleeping;
  _Atomic int on_cpu;
  int idx, live;
  uint64_t reqs, sh_reqs, bg_ops, chk, contended, parks, handoffs;
  uint64_t spin_ticks, idle_spin_ticks, block_ticks, idle_ticks, work_ticks;
  uint64_t xmsgs, xwakes, ring_full, home_ops, home_busy_ticks;
  double cpu_ns;
  uint64_t *samp; /* request latency in ticks << 1 | touched-the-table */
  uint32_t nsamp;
  uint64_t nseen, srng;
  pthread_t th;
} worker;
static worker *W;
static _Thread_local worker *me;

typedef struct conn {
  task t;
  uint64_t rng;
  uint32_t nrecv;
  uint64_t nreq;
  uint64_t g;     /* global connection number */
  uint64_t t0;    /* the current request's start */
  uint8_t shared; /* the current request touches the table */
} conn;
static uint64_t reqs_limit;

static inline bool running(void) { return !atomic_load_explicit(&stop_flag, memory_order_relaxed); }

static void wake(worker *w) {
  pthread_mutex_lock(&w->m);
  pthread_cond_signal(&w->c);
  pthread_mutex_unlock(&w->m);
  if (running()) me->xwakes++;
}
void requeue(task *t) {
  worker *w = &W[t->cur];
  pthread_mutex_lock(&w->m);
  t->next = NULL;
  if (w->tail) w->tail->next = t;
  else __atomic_store_n(&w->head, t, __ATOMIC_RELAXED);
  w->tail = t;
  bool sl = atomic_load_explicit(&w->sleeping, memory_order_relaxed);
  if (sl) pthread_cond_signal(&w->c);
  pthread_mutex_unlock(&w->m);
  if (w != me && running()) { me->xmsgs++; if (sl) me->xwakes++; }
}

/* ---------- (H) the rings: one SPSC ring per (source, destination) ----------
   Seastar's choice. Each worker that calls the home has its own ring to it,
   so a push is a plain slot write and a release store of the tail: no
   read-modify-write, and the 7 producers never contend on one tail line (an
   MPSC queue's shared tail is the contended word we are trying to remove).
   The home polls one ring per source, which is cheap: a source's tail line
   only moves when it has pushed. Replies go back on the reverse ring, and
   the home publishes each destination's tail once per drain (batched).
   Bounded: a full ring fails the push, and the caller waits for room. */
#define RCAP 64
enum { M_GET = 0, M_PUT = 1, M_REPLY = 2, M_TASK = 3 };
typedef struct { uint64_t kind, k, v; task *t; } msg;
typedef struct ring {
  _Alignas(128) _Atomic uint64_t tail; /* published by the producer */
  _Alignas(128) uint64_t ptail, phead; /* producer's own: unpublished tail, cached head */
  _Alignas(128) _Atomic uint64_t head; /* published by the consumer */
  _Alignas(128) uint64_t chead;        /* consumer's own head */
  _Alignas(128) msg slot[RCAP];
} ring;
static ring *R;
#define RING(src, dst) (&R[(src) * nworkers + (dst)])

static bool ring_push(int src, int dst, msg m) {
  ring *r = RING(src, dst);
  if (UNLIKELY(r->ptail - r->phead >= RCAP)) {
    r->phead = atomic_load_explicit(&r->head, memory_order_acquire);
    if (r->ptail - r->phead >= RCAP) return false;
  }
  r->slot[r->ptail % RCAP] = m;
  r->ptail++;
  if (running()) me->xmsgs++;
  return true;
}
static void ring_flush(int src, int dst) {
  ring *r = RING(src, dst);
  atomic_store_explicit(&r->tail, r->ptail, memory_order_release);
  atomic_thread_fence(memory_order_seq_cst); /* Dekker with the sleeper's fence */
  worker *w = &W[dst];
  if (atomic_load_explicit(&w->sleeping, memory_order_relaxed)) wake(w);
}
bool ship_call(task *t, uint64_t op, uint64_t k, uint64_t v) {
  if (!ring_push(cur_worker, HOME, (msg){op, k, v, t})) return false;
  ring_flush(cur_worker, HOME);
  return true;
}
/* A hop is carried out by the worker after `step` returns, once the task has
   fully suspended: the callers above `handle` still write their frames on the
   way out (Go's gopark-with-unlock, for the same reason). */
static _Thread_local task *hop_t;
static _Thread_local int hop_to;
void hop(task *t, int to) { hop_t = t; hop_to = to; }
static void do_hop(void) {
  task *t = hop_t;
  int from = cur_worker;
  hop_t = NULL;
  t->cur = hop_to; /* published by the ring's release */
  while (!ring_push(from, hop_to, (msg){M_TASK, 0, 0, t})) { note_ring_full(); drain(); } /* wait for room */
  ring_flush(from, hop_to);
}
void note_ring_full(void) { if (running()) me->ring_full++; }

static inline bool polls(void) { return SHIPPING; }
static bool rings_ready(void) {
  int i = me->idx;
  for (int s = 0; s < nworkers; s++) {
    if (s == i || (i != HOME && s != HOME)) continue;
    ring *r = RING(s, i);
    if (atomic_load_explicit(&r->tail, memory_order_acquire) != r->chead) return true;
  }
  return false;
}
/* FAST: a task resumed by a reply or a hop runs next (Go's runnext), rather
   than queueing behind every task on the worker. */
static void local_push(task *t) {
  if (!fast) { requeue(t); return; }
  worker *w = me;
  pthread_mutex_lock(&w->m);
  t->next = w->head;
  if (!w->tail) w->tail = t;
  __atomic_store_n(&w->head, t, __ATOMIC_RELAXED);
  pthread_mutex_unlock(&w->m);
}
void drain(void) {
  int i = me->idx;
  uint64_t dirty = 0, t0 = 0, nops_done = 0;
  for (int s = 0; s < nworkers; s++) {
    if (s == i || (i != HOME && s != HOME)) continue;
    ring *r = RING(s, i);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire), h = r->chead;
    if (tail == h) continue;
    if (tail - h > (uint64_t)batch) tail = h + batch;
    if (i == HOME && !t0) t0 = now_ticks();
    for (; h != tail; h++) {
      msg m = r->slot[h % RCAP];
      switch (m.kind) {
      case M_PUT:
      case M_GET: {
        uint64_t v;
        if (m.kind == M_PUT) { mt_insert(m.k, m.v); hold_work(); v = 1; }
        else v = mt_lookup(m.k);
        if (!ring_push(i, s, (msg){M_REPLY, 0, v, m.t})) abort(); /* replies <= calls in flight < RCAP */
        dirty |= 1ull << s;
        nops_done++;
        break;
      }
      case M_REPLY: m.t->reply = m.v; local_push(m.t); break;
      case M_TASK: local_push(m.t); break;
      }
    }
    r->chead = h;
    atomic_store_explicit(&r->head, h, memory_order_release);
  }
  for (int d = 0; dirty; d++, dirty >>= 1)
    if (dirty & 1) ring_flush(i, d);
  if (t0 && running()) { me->home_busy_ticks += now_ticks() - t0; me->home_ops += nops_done; }
}

/* ---------- the world, and plain helpers ---------- */
#define KEYS (1u << 15)
#define SLOTS (1u << 16)
static struct { uint64_t k, v; } table[SLOTS];
#define GOLD 0x9e3779b97f4a7c15ull
static inline uint64_t mk_key(uint64_t idx) { return ((idx * GOLD) & ~(uint64_t)(KEYS * 4 - 1)) | (idx << 1) | 1; }

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
  if (disjoint) r->key = c->g * key_range + (r->key & (key_range - 1));
  r->val = x >> 20;
  if (share_pct < 100 && (x >> 44) % 100 >= (uint64_t)share_pct) r->op = 2;
  c->shared = r->op != 2;
  c->t0 = now_ticks();
  return true;
}
bool recv_would_block(task *t) { return (++((conn *)t)->nrecv & 7) == 0; }
uint64_t parse_key(const request *r) { /* FNV-1a over 64 bytes derived from the key */
  uint64_t h = 1469598103934665603ull;
  for (int i = 0; i < 64; i++) {
    h ^= (r->key >> (i & 15)) & 0xff;
    h *= 1099511628211ull;
  }
  return mk_key(r->key) ^ ((uint64_t)(h == 0) << 63); /* keep the hash live; h is never 0 here */
}
uint64_t key_at(uint64_t k, uint64_t i) { return i ? mk_key(((k >> 1) & (KEYS - 1)) ^ i) : k; }
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
uint64_t local_work(const request *r) {
  work_for(local_ticks);
  return r->key * 3 + r->val;
}
uint64_t encode_resp(uint64_t v) { return v * 31 + 7; }
static inline void record(uint64_t s) {
  worker *w = me;
  w->nseen++;
  if (w->nsamp < MAXSAMP) w->samp[w->nsamp++] = s;
  else {
    uint64_t j = xorshift(&w->srng) % w->nseen; /* reservoir */
    if (j < MAXSAMP) w->samp[j] = s;
  }
}
void respond(task *t, uint64_t resp) {
  conn *c = (conn *)t;
  if (reqs_limit) me->chk += resp * (c->g * 2 + 1) + c->nreq; /* order-independent across connections */
  if (!running()) return;
  me->reqs++;
  me->sh_reqs += c->shared;
  if (!reqs_limit) me->chk ^= resp;
  record((now_ticks() - c->t0) << 1 | c->shared);
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
    /* P2: spin only while the holder is running. In this model a holder never
       waits inside an operation (operations are plain), so this is false
       only when the holder's worker is asleep, i.e. never while it holds. */
    if (strategy == S_P2 &&
        !atomic_load_explicit(&W[atomic_load_explicit(&l->holder, memory_order_relaxed)].on_cpu,
                              memory_order_relaxed))
      break;
  } while ((t1 = now_ticks()) - t0 < spin_budget_ticks);
  t1 = now_ticks();
  if (running()) me->spin_ticks += t1 - t0;
  qlock(l);
  uint32_t old = atomic_fetch_or_explicit(&l->state, L_WAITERS, memory_order_acq_rel);
  if (!(old & L_LOCKED)) {
    uint32_t s = old | L_WAITERS;
    if (atomic_compare_exchange_strong_explicit(&l->state, &s, s | L_LOCKED, memory_order_acquire,
                                                memory_order_relaxed)) {
      if (strategy == S_P2) atomic_store_explicit(&l->holder, cur_worker, memory_order_relaxed);
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
  if (!w) {
    atomic_fetch_and_explicit(&l->state, ~(uint32_t)(L_LOCKED | L_WAITERS), memory_order_release);
    qunlock(l);
    return;
  }
  l->wq_head = w->next;
  if (!l->wq_head) {
    l->wq_tail = NULL;
    atomic_fetch_and_explicit(&l->state, ~(uint32_t)L_WAITERS, memory_order_relaxed);
  }
  if ((strategy == S_HANDOFF || strategy == S_P2) && now_ticks() - w->wait_start >= handoff_ticks) {
    w->granted = 1; /* L_LOCKED stays set: ownership passes to w */
    if (strategy == S_P2) atomic_store_explicit(&l->holder, w->cur, memory_order_relaxed);
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
}

/* ---------- (b): thread locks ---------- */
void thread_take(inst_lock *l) {
  if (strategy == S_UNFAIR) {
    os_unfair_lock_t ol = (os_unfair_lock_t)&l->os_lock;
    if (LIKELY(os_unfair_lock_trylock(ol))) return;
    uint64_t t0 = now_ticks();
    os_unfair_lock_lock(ol);
    uint64_t dt = now_ticks() - t0;
    if (running()) { me->block_ticks += dt; me->contended++; }
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
  }
}
void thread_release(inst_lock *l) {
  if (strategy == S_UNFAIR) os_unfair_lock_unlock((os_unfair_lock_t)&l->os_lock);
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
static inline bool finished(void) {
  if (me->live > 0) return false;
  /* the home serves calls and moved tasks until every task has ended */
  return !(polls() && me->idx == HOME) || atomic_load(&global_live) == 0;
}
static inline bool has_work(void) {
  return __atomic_load_n(&me->head, __ATOMIC_RELAXED) || (polls() && rings_ready());
}
static _Atomic int ready, go;
static void *worker_main(void *arg) {
  me = arg;
  cur_worker = me->idx;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  atomic_store(&me->on_cpu, 1);
  atomic_fetch_add(&ready, 1);
  while (!atomic_load(&go)) cpu_relax();
  double c0 = thread_cpu_ns();
  bool snap = false;
  while (!finished()) {
    if (polls()) drain();
    task *t = NULL;
    if (__atomic_load_n(&me->head, __ATOMIC_RELAXED)) {
      pthread_mutex_lock(&me->m);
      t = me->head;
      if (t) {
        __atomic_store_n(&me->head, t->next, __ATOMIC_RELAXED);
        if (!me->head) me->tail = NULL;
      }
      pthread_mutex_unlock(&me->m);
    }
    if (t) {
      int fin = step(t);
      if (hop_t) do_hop();
      if (fin) {
        me->live--;
        if (atomic_fetch_sub(&global_live, 1) == 1)
          for (int i = 0; i < nworkers; i++) wake(&W[i]);
        free(t);
      }
    } else if (!finished()) {
      if (idle_spin_ticks) { /* spin briefly before sleeping */
        uint64_t t0 = now_ticks();
        while (!has_work() && !finished() && now_ticks() - t0 < idle_spin_ticks) cpu_relax();
        if (running()) me->idle_spin_ticks += now_ticks() - t0;
      }
      if (!has_work() && !finished()) {
        pthread_mutex_lock(&me->m);
        atomic_store(&me->sleeping, 1);
        atomic_thread_fence(memory_order_seq_cst);
        while (!has_work() && !finished()) {
          uint64_t t0 = now_ticks();
          atomic_store_explicit(&me->on_cpu, 0, memory_order_relaxed);
          pthread_cond_wait(&me->c, &me->m);
          atomic_store_explicit(&me->on_cpu, 1, memory_order_relaxed);
          if (running()) me->idle_ticks += now_ticks() - t0;
        }
        atomic_store(&me->sleeping, 0);
        pthread_mutex_unlock(&me->m);
      }
    }
    if (!snap && !running()) { snap = true; me->cpu_ns = thread_cpu_ns() - c0; }
  }
  if (!snap) me->cpu_ns = thread_cpu_ns() - c0;
  return NULL;
}

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}
static double envf(const char *k, double d) { return getenv(k) ? atof(getenv(k)) : d; }

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  const char *names[S_N] = {"park", "handoff", "p2", "ship", "shipded", "move", "moveded", "unfair", "spin"};
  if (argc < 7) {
    fprintf(stderr, "usage: %s park|handoff|p2|ship|shipded|move|moveded|unfair|spin workers conns_per_worker hold_us bg seconds\n", argv[0]);
    return 2;
  }
  strategy = -1;
  for (int i = 0; i < S_N; i++) if (!strcmp(argv[1], names[i])) strategy = i;
#ifdef SUSP
  if (strategy < 0 || strategy >= S_UNFAIR) { fprintf(stderr, "this build (a) runs park|handoff|p2|ship|shipded|move|moveded\n"); return 2; }
  const char *build = "a_susp";
#else
  if (strategy != S_UNFAIR && strategy != S_SPIN) { fprintf(stderr, "this build (b) runs unfair|spin\n"); return 2; }
  const char *build = "b_plain";
#endif
  if (getenv("REQS")) reqs_limit = strtoull(getenv("REQS"), 0, 10);
  nworkers = atoi(argv[2]);
  nconns = atoi(argv[3]);
  double hold_us = atof(argv[4]);
  nbg = atoi(argv[5]);
  double secs = atof(argv[6]);
  if (DEDICATED && nworkers < 2) { fprintf(stderr, "a dedicated home needs 2+ workers\n"); return 2; }
  nops = (int)envf("OPS", 1);
  share_pct = (int)envf("SHARE_PCT", 100);
  batch = (int)envf("BATCH", 16);
  disjoint = (int)envf("DISJOINT", 0);
  fast = (int)envf("FAST", 0);
  hold_ticks = (uint64_t)(hold_us * 1000 / tick_ns);
  local_ticks = (uint64_t)(envf("LOCAL_US", 2) * 1000 / tick_ns);
  bool adaptive = strategy == S_P2 || SHIPPING;
  double spin_us = envf("SPIN_US", strategy == S_P2 ? 4.0 : 1.0);
  double idle_us = envf("IDLE_SPIN_US", adaptive ? 5.0 : 0.0);
  spin_budget_ticks = (uint64_t)(spin_us * 1000 / tick_ns);
  idle_spin_ticks = (uint64_t)(idle_us * 1000 / tick_ns);
  handoff_ticks = (uint64_t)(1e6 / tick_ns); /* 1 ms */

  int serving = DEDICATED ? nworkers - 1 : nworkers;
  uint64_t total_conns = (uint64_t)serving * nconns;
  if (disjoint) {
    key_range = 1;
    while ((uint64_t)key_range * 2 * total_conns <= KEYS) key_range *= 2;
    if (key_range < 16) { fprintf(stderr, "DISJOINT: too many connections\n"); return 2; }
  }
  R = calloc((size_t)nworkers * nworkers, sizeof(ring));
  W = calloc(nworkers, sizeof *W);
  uint64_t g = 0;
  for (int i = 0; i < nworkers; i++) {
    worker *w = &W[i];
    pthread_mutex_init(&w->m, NULL);
    pthread_cond_init(&w->c, NULL);
    w->idx = i;
    w->srng = 0x2545f4914f6cdd1dull * (i + 1);
    w->samp = malloc(MAXSAMP * sizeof(uint64_t));
    if (DEDICATED && i == HOME) continue; /* the dedicated home has no tasks */
    for (int j = 0; j < nconns + nbg; j++) {
      conn *c = calloc(1, sizeof *c);
      task *t = &c->t;
      t->home = t->cur = i;
      t->limit = t->frames + SEG;
      frame *f = (frame *)t->frames;
      f->resume = j < nconns ? serve : bg_body;
      f->sp = t->frames + 64;
      t->top = f;
      c->g = j < nconns ? g++ : 0;
      c->rng = GOLD * (c->g + 1) + (j < nconns ? 0 : 7919 * (i + 1));
      t->next = NULL;
      if (w->tail) w->tail->next = t;
      else w->head = t;
      w->tail = t;
      w->live++;
      global_live++;
    }
  }
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_setstacksize(&at, 8u << 20);
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

  uint64_t reqs = 0, sh = 0, bg = 0, cont = 0, parks = 0, hand = 0, chk = 0, ns = 0, xm = 0, xw = 0, rf = 0;
  double spin = 0, ispin = 0, block = 0, idle = 0, work = 0, cpu = 0;
  for (int i = 0; i < nworkers; i++) {
    worker *w = &W[i];
    reqs += w->reqs; sh += w->sh_reqs; bg += w->bg_ops; cont += w->contended; parks += w->parks; hand += w->handoffs;
    chk = reqs_limit ? chk + w->chk : chk ^ w->chk;
    ns += w->nsamp; xm += w->xmsgs; xw += w->xwakes; rf += w->ring_full;
    spin += w->spin_ticks * tick_ns; ispin += w->idle_spin_ticks * tick_ns; block += w->block_ticks * tick_ns;
    idle += w->idle_ticks * tick_ns; work += w->work_ticks * tick_ns; cpu += w->cpu_ns;
  }
  /* percentiles over each worker's reservoir, weighted by the requests it saw */
  uint64_t *all = malloc((ns + 1) * sizeof *all), *shs = malloc((ns + 1) * sizeof *shs), na = 0, nsh = 0;
  for (int i = 0; i < nworkers; i++)
    for (uint32_t j = 0; j < W[i].nsamp; j++) {
      uint64_t s = W[i].samp[j];
      all[na++] = s >> 1;
      if (s & 1) shs[nsh++] = s >> 1;
    }
  qsort(all, na, sizeof *all, cmp_u64);
  qsort(shs, nsh, sizeof *shs, cmp_u64);
#define PCT(a, n, p) ((n) ? (a)[(uint64_t)((n) - 1) * (p) / 100] * tick_ns / 1e3 : 0)
  double cap = wall * nworkers;
  uint64_t table_hash = 0;
  for (uint32_t i = 0; i < SLOTS; i++) if (table[i].k) table_hash += table[i].k * 31 + table[i].v * 0x100000001b3ull;
  bool rings_clean = true;
  for (int i = 0; i < nworkers * nworkers; i++)
    if (atomic_load(&R[i].tail) != R[i].chead || R[i].ptail != atomic_load(&R[i].tail)) rings_clean = false;
  bool ok = atomic_load(&mt_lock.state) == 0 && mt_lock.wq_head == NULL && rings_clean && global_live == 0 &&
            (!reqs_limit || reqs == reqs_limit * total_conns);
  printf("X3b build=%s strategy=%s workers=%d conns=%d hold_us=%g bg=%d ops=%d share_pct=%d spin_us=%g idle_spin_us=%g batch=%d "
         "fast=%d secs=%.2f req_per_s=%.0f remote_req_per_s=%.0f sh_req_per_s=%.0f "
         "lat_p50_us=%.2f lat_p99_us=%.2f lat_max_us=%.1f sh_lat_p50_us=%.2f sh_lat_p99_us=%.2f sh_lat_max_us=%.1f "
         "contended_frac=%.4f parks=%llu handoffs=%llu xmsgs_per_req=%.3f xwakes_per_req=%.4f ring_full=%llu "
         "home_ops=%llu home_busy_pct=%.2f home_cpu_pct=%.2f "
         "reqs=%llu spin_pct=%.2f idle_spin_pct=%.2f block_pct=%.2f idle_pct=%.2f work_pct=%.2f cpu_pct=%.2f "
         "bg_ops_per_s=%.0f chk=%llx table=%llx check=%s",
         build, names[strategy], nworkers, nconns, hold_us, nbg, nops, share_pct, spin_us, idle_us, batch, fast,
         wall / 1e9, reqs / (wall / 1e9), (reqs - W[HOME].reqs) / (wall / 1e9), sh / (wall / 1e9),
         PCT(all, na, 50), PCT(all, na, 99), PCT(all, na, 100), PCT(shs, nsh, 50), PCT(shs, nsh, 99), PCT(shs, nsh, 100),
         reqs ? (double)cont / reqs : 0, (unsigned long long)parks, (unsigned long long)hand,
         reqs ? (double)xm / reqs : 0, reqs ? (double)xw / reqs : 0, (unsigned long long)rf,
         (unsigned long long)W[HOME].home_ops, 100 * W[HOME].home_busy_ticks * tick_ns / wall, 100 * W[HOME].cpu_ns / wall,
         (unsigned long long)reqs, 100 * spin / cap, 100 * ispin / cap, 100 * block / cap, 100 * idle / cap,
         100 * work / cap, 100 * cpu / cap, bg / (wall / 1e9), (unsigned long long)chk, (unsigned long long)table_hash,
         ok ? "ok" : "FAIL");
  printf("  idle_pct_by_worker=");
  for (int i = 0; i < nworkers; i++) printf("%s%.1f", i ? "," : "", 100 * W[i].idle_ticks * tick_ns / wall);
  printf(" reqs_by_worker=");
  for (int i = 0; i < nworkers; i++) printf("%s%llu", i ? "," : "", (unsigned long long)W[i].reqs);
  printf("\n");
  return ok ? 0 : 1;
}
