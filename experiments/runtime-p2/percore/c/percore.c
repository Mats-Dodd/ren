// runtime-p2 / percore: per_core against work_stealing on a flottning-shaped
// kernel. See ../PLAN.md for what each variant models and the predictions.
//
// The kernel is a key-value store: put(k, v) and get(k) from client tasks,
// a memtable (an ordered map: a skip list) and a write-ahead log (an
// in-memory buffer, group commit every --group appends or --group-us us;
// --fsync also writes each group to a file and F_FULLFSYNCs it, off by
// default). A put appends to the WAL first, which assigns its sequence
// number, then applies (key, seq, value) to the memtable, keeping the
// highest seq per key. A put does not wait for its group to commit.
//
// Variants (one per run, --variant):
//   ws_one     work_stealing. One memtable instance and one WAL instance,
//              each behind phase 1's hybrid lock (barge, spin --lock-spin
//              polls, then park on the word). Callers run the operation
//              where they are.
//   ws_worker  work_stealing + striped(by: Worker). A memtable stripe per
//              worker, each locked and padded. A put goes to the caller's
//              stripe; a get checks every stripe and keeps the highest
//              seq (the merge). The WAL is one shared instance.
//   ws_keyed   work_stealing + striped(by: Key(n: --stripes)). Stripes are
//              routed by key hash, locked, padded. WAL shared.
//   ws_sharded work_stealing with per_core's layout: a shard per worker by
//              the same key hash, each a memtable AND a WAL segment behind
//              one hybrid lock. Callers take the shard where they are.
//              Against pc_*, only the runtime differs (lock vs hop).
//   pc_spin    per_core. Keys sharded to home cores by hash. Each core owns
//              its memtable and WAL segment, with no locks. A request for a
//              key on another core hops: a message on the owner's MPSC
//              inbox; the reply comes back on the requester's inbox. An
//              idle core spins --spin polls on its inbox, then parks.
//   pc_park    per_core, an idle core parks at once (pure park).
//
// Every core in per_core is both a client and a server: while its own
// request is away it keeps serving its inbox. --inflight M gives each core
// M client tasks (default 1, as work_stealing has one per worker).
//
// Extension (Phase A, owner's request): three task runtimes under open-loop
// arrivals, on the sharded layout, with an optional skewed load (Zipf keys
// plus --heavy-pct percent of requests doing --work-us of pure CPU work):
//   work_stealing  run-to-completion tasks; a worker claims requests that
//                  arrived on its own connections, and an idle worker steals
//                  arrived requests from the others'. Shards behind locks;
//                  pure work runs inline wherever the task runs.
//   per_core       a connection's requests run on its home core; the KV op
//                  hops to the key's owner core; pure work runs inline on
//                  the home core (blocking its inbox). No stealing.
//   place_at_spawn effectful tasks are placed on the least-loaded worker
//                  when spawned and never move (shard locks, as
//                  work_stealing); pure work goes to a separate --pool of
//                  threads that steal from each other; the task resumes on
//                  its home worker.
//
// Platforms. macOS: every thread runs at QOS_CLASS_USER_INTERACTIVE (no
// pinning exists); parking is os_sync_wait_on_address; timer is
// mach_absolute_time. Linux: parking is futex(FUTEX_WAIT/WAKE_PRIVATE);
// timer is clock_gettime(CLOCK_MONOTONIC) in ns; threads are pinned with
// sched_setaffinity, thread t to the t-th allowed CPU, when the run has no
// more threads than allowed CPUs (--pin auto), so per_core's home core is a
// real core; every variant gets the same pinning. Oversubscribed runs are
// left unpinned. --fsync uses F_FULLFSYNC on macOS and fdatasync on Linux.

#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#else
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach_time.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread/qos.h>
#define OS_NAME "macos"
#else
#include <linux/futex.h>
#include <sys/syscall.h>
#include <time.h>
#define OS_NAME "linux"
#endif

/* 128: Apple M-series line; on x86 the adjacent-line prefetcher pairs 64 B
   lines, so 128 is also the right padding there. */
#define LINE 128

static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ volatile("isb" ::: "memory");
#elif defined(__x86_64__) || defined(__i386__)
  __asm__ volatile("pause" ::: "memory");
#else
  atomic_signal_fence(memory_order_seq_cst);
#endif
}
static double tick_ns;
#if defined(__APPLE__)
static inline uint64_t now(void) { return mach_absolute_time(); }
static inline void park_u32(_Atomic uint32_t *a, uint32_t v) {
  os_sync_wait_on_address((void *)a, v, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
}
static inline void wake1_u32(_Atomic uint32_t *a) { os_sync_wake_by_address_any((void *)a, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE); }
static void init_ticks(void) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
}
#else
static inline uint64_t now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000ULL + (uint64_t)t.tv_nsec;
}
static inline void park_u32(_Atomic uint32_t *a, uint32_t v) {
  syscall(SYS_futex, (uint32_t *)a, FUTEX_WAIT_PRIVATE, v, NULL, NULL, 0);
}
static inline void wake1_u32(_Atomic uint32_t *a) { syscall(SYS_futex, (uint32_t *)a, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0); }
static void init_ticks(void) { tick_ns = 1.0; }
#endif

/* ---------- hashing and traces (as k1k2/c/common.h) ---------- */
static inline uint64_t splitmix64(uint64_t *s) {
  uint64_t z = (*s += 0x9e3779b97f4a7c15ULL);
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}
static inline uint64_t mix64(uint64_t k) {
  k ^= k >> 33;
  k *= 0xff51afd7ed558ccdULL;
  k ^= k >> 33;
  k *= 0xc4ceb9fe1a85ec53ULL;
  k ^= k >> 33;
  return k;
}
static inline uint32_t part_of(uint64_t k, uint32_t n) { return (uint32_t)((mix64(k) >> 32) % n); }
static inline uint64_t uniform_key(uint64_t x, uint32_t n) { return 1 + (((x >> 32) * (uint64_t)n) >> 32); }
typedef struct { double *cdf; uint32_t n; } zipf_t;
static void zipf_init(zipf_t *z, uint32_t n, double s) {
  z->n = n;
  z->cdf = malloc(sizeof(double) * n);
  double sum = 0;
  for (uint32_t i = 1; i <= n; i++) { sum += pow((double)i, -s); z->cdf[i - 1] = sum; }
  for (uint32_t i = 0; i < n; i++) z->cdf[i] /= sum;
  z->cdf[n - 1] = 1.0;
}
static inline uint64_t zipf_key(const zipf_t *z, uint64_t x) {
  double u = (double)(x >> 11) * 0x1.0p-53;
  uint32_t lo = 0, hi = z->n - 1;
  while (lo < hi) {
    uint32_t mid = lo + (hi - lo) / 2;
    if (z->cdf[mid] >= u) hi = mid; else lo = mid + 1;
  }
  return (uint64_t)lo + 1; /* rank 1, the hottest key, is key 1 */
}
/* A value is a function of (key, seq), so any value a get returns can be
   checked, and the final state can be checked against the WAL. */
static inline uint64_t valfn(uint64_t k, uint64_t seq) {
  return mix64(k * 0x9E3779B97F4A7C15ULL ^ (seq + 1) * 0xC2B2AE3D27D4EB4FULL);
}

/* ---------- configuration ---------- */
enum variant { V_WS_ONE, V_WS_WORKER, V_WS_KEYED, V_WS_SHARD, V_PC_SPIN, V_PC_PARK, V_X_WS, V_X_PC, V_X_PAS, NV };
static const char *vname[NV] = {"ws_one", "ws_worker", "ws_keyed", "ws_sharded", "pc_spin", "pc_park",
                                "work_stealing", "per_core", "place_at_spawn"};
static struct {
  enum variant v;
  int get_pct;
  int zipf;
  double theta;
  int workers;
  uint32_t keys;
  uint64_t ops; /* per worker */
  int group;
  double group_us;
  int fsync;
  int spin;      /* per_core idle spin polls before parking */
  int lock_spin; /* hybrid lock spin polls before parking */
  int stripes;   /* ws_keyed */
  int inflight;  /* per_core client tasks per core */
  uint64_t seed;
  const char *dir;
  /* extension (work_stealing, per_core, place_at_spawn) */
  int conns;        /* arrival streams; --ops is per stream */
  int shards;       /* 0: = workers */
  int pool;         /* place_at_spawn: pure-work pool threads */
  double rate;      /* total offered requests/s; 0: everything arrives at t=0 */
  double heavy_pct; /* percent of requests that also do pure work */
  double work_us;   /* target length of one pure chunk */
  uint64_t work_iters; /* 0: calibrate at startup */
  int pin;          /* -1 auto, 0 off, 1 on */
} C = {V_WS_ONE, 95, 0, 0.99, 4, 1u << 20, 200000, 64, 100.0, 0, 1000, 64, 16, 1, 42, NULL,
       4, 0, 0, 0.0, 0.0, 200.0, 0, -1};
static int is_pc(void) { return C.v == V_PC_SPIN || C.v == V_PC_PARK; }
static int is_ext(void) { return C.v == V_X_WS || C.v == V_X_PC || C.v == V_X_PAS; }
static int sharded(void) { return is_pc() || C.v == V_WS_SHARD || is_ext(); } /* a WAL per shard */
static int nshards; /* shards / WAL segments when sharded() */

/* ---------- per-thread stats ---------- */
#define NB 1408 /* log-linear histogram over timer ticks, ~3% resolution */
static inline int bucket(uint64_t t) {
  if (t < 64) return (int)t;
  int e = 63 - __builtin_clzll(t);
  int b = 64 + (e - 6) * 32 + (int)((t >> (e - 5)) & 31);
  return b < NB ? b : NB - 1;
}
static inline uint64_t bucket_lo(int b) {
  if (b < 64) return (uint64_t)b;
  int e = (b - 64) / 32 + 6, sub = (b - 64) % 32;
  return (uint64_t)(32 + sub) << (e - 5);
}
typedef struct {
  uint64_t gets, puts, hits, misses, bad, even_miss;
  uint64_t hops, served, lock_slow, lock_parks, lock_wakes, idle_parks, idle_wakes;
  uint64_t finish;
  uint64_t steals, placed_remote, yields, works, work_ticks, work_sum; /* extension */
  uint64_t hg[NB], hp[NB];
  uint64_t hl[NB], hh[NB]; /* extension: light requests, heavy (pure work) requests */
} __attribute__((aligned(LINE))) stat_t;
static stat_t *stats;
static inline void record(stat_t *st, int put, uint64_t dt) {
  if (put) st->hp[bucket(dt)]++; else st->hg[bucket(dt)]++;
}

/* ---------- phase 1's hybrid lock (k3/verify/k3_hybrid.c) ---------- */
/* 0 free, 1 held, 2 held with parked waiters. Barging, no FIFO, no 1 ms
   starvation guard (P3: it fired on <0.05% of releases). */
typedef struct { _Atomic uint32_t w; } hlock_t;
static void hl_slow(hlock_t *l, stat_t *st) {
  st->lock_slow++;
  for (int i = 0; i < C.lock_spin; i++) {
    uint32_t z = 0;
    if (atomic_load_explicit(&l->w, memory_order_relaxed) == 0 &&
        atomic_compare_exchange_weak_explicit(&l->w, &z, 1, memory_order_acquire, memory_order_relaxed))
      return;
    cpu_relax();
  }
  while (atomic_exchange_explicit(&l->w, 2, memory_order_acquire) != 0) {
    st->lock_parks++;
    park_u32(&l->w, 2);
  }
}
static inline void hl_take(hlock_t *l, stat_t *st) {
  uint32_t z = 0;
  if (!atomic_compare_exchange_strong_explicit(&l->w, &z, 1, memory_order_acquire, memory_order_relaxed))
    hl_slow(l, st);
}
static inline void hl_release(hlock_t *l, stat_t *st) {
  if (atomic_exchange_explicit(&l->w, 0, memory_order_release) == 2) {
    st->lock_wakes++;
    wake1_u32(&l->w);
  }
}

/* ---------- the memtable: a skip list in its own arena ---------- */
#define MAXLVL 24
typedef struct node {
  uint64_t key, seq, val;
  uint32_t lvl;
  struct node *next[];
} node_t;
typedef struct { char *bump, *end; } arena_t;
static void *arena_alloc(arena_t *a, size_t n) {
  n = (n + 15) & ~(size_t)15;
  if (a->bump + n > a->end) {
    size_t cs = (size_t)1 << 20;
    a->bump = malloc(cs);
    if (!a->bump) { perror("malloc"); exit(2); }
    a->end = a->bump + cs;
  }
  void *p = a->bump;
  a->bump += n;
  return p;
}
typedef struct {
  node_t *head;
  int lvl;
  uint64_t rng, count;
  arena_t ar;
} skl_t;
static void skl_init(skl_t *s, uint64_t seed) {
  memset(s, 0, sizeof *s);
  s->head = arena_alloc(&s->ar, sizeof(node_t) + MAXLVL * sizeof(node_t *));
  memset(s->head, 0, sizeof(node_t) + MAXLVL * sizeof(node_t *));
  s->head->lvl = MAXLVL;
  s->lvl = 1;
  s->rng = seed;
}
static int skl_put(skl_t *s, uint64_t k, uint64_t seq, uint64_t v) {
  node_t *upd[MAXLVL], *x = s->head;
  for (int i = s->lvl - 1; i >= 0; i--) {
    while (x->next[i] && x->next[i]->key < k) x = x->next[i];
    upd[i] = x;
  }
  node_t *n = x->next[0];
  if (n && n->key == k) {
    if (seq > n->seq) { n->seq = seq; n->val = v; } /* highest seq wins */
    return 0;
  }
  uint64_t r = splitmix64(&s->rng);
  int l = 1;
  while (l < MAXLVL && (r & 3) == 0) { l++; r >>= 2; }
  if (l > s->lvl) {
    for (int i = s->lvl; i < l; i++) upd[i] = s->head;
    s->lvl = l;
  }
  n = arena_alloc(&s->ar, sizeof(node_t) + (size_t)l * sizeof(node_t *));
  n->key = k; n->seq = seq; n->val = v; n->lvl = (uint32_t)l;
  for (int i = 0; i < l; i++) { n->next[i] = upd[i]->next[i]; upd[i]->next[i] = n; }
  s->count++;
  return 1;
}
static const node_t *skl_get(const skl_t *s, uint64_t k) {
  const node_t *x = s->head;
  for (int i = s->lvl - 1; i >= 0; i--)
    while (x->next[i] && x->next[i]->key < k) x = x->next[i];
  x = x->next[0];
  return x && x->key == k ? x : NULL;
}
static int skl_valid(const skl_t *s) { /* every level sorted, count right */
  for (int i = 0; i < MAXLVL; i++) {
    uint64_t prev = 0, n = 0;
    for (const node_t *x = s->head->next[i]; x; x = x->next[i]) {
      if (x->key <= prev || (int)x->lvl <= i) return 0;
      prev = x->key;
      n++;
    }
    if (i == 0 && n != s->count) return 0;
  }
  return 1;
}

/* ---------- the WAL ---------- */
typedef struct { uint64_t key, seq, val; } rec_t;
typedef struct {
  hlock_t lock;     /* work_stealing only */
  uint64_t seq;     /* last seq given */
  rec_t *buf;       /* the group being filled */
  int nbuf;
  uint64_t first;   /* tick of the group's first append */
  rec_t *sink;      /* the log: what's been committed */
  uint64_t nsink, cap, sum, flushes;
  int fd;
} __attribute__((aligned(LINE))) wal_t;
static uint64_t group_ticks;
static inline uint64_t rec_sum(const rec_t *r) { return mix64(r->key ^ mix64(r->seq ^ mix64(r->val))); }
/* Commit the group. Under --fsync the write and F_FULLFSYNC (Linux: fdatasync) happen here,
   inside the operation, so they hold the WAL instance (decision 10: "one
   slow call, an fsync, serializes that handler's operations"). */
static void wal_flush(wal_t *w) {
  if (!w->nbuf) return;
  if (w->nsink + (uint64_t)w->nbuf > w->cap) { fprintf(stderr, "wal overflow\n"); abort(); }
  memcpy(w->sink + w->nsink, w->buf, (size_t)w->nbuf * sizeof(rec_t));
  for (int i = 0; i < w->nbuf; i++) w->sum += rec_sum(&w->buf[i]); /* stands in for a CRC */
  if (w->fd >= 0) {
    size_t len = (size_t)w->nbuf * sizeof(rec_t);
    if (pwrite(w->fd, w->sink + w->nsink, len, (off_t)(w->nsink * sizeof(rec_t))) != (ssize_t)len ||
#if defined(__APPLE__)
        fcntl(w->fd, F_FULLFSYNC) != 0
#else
        fdatasync(w->fd) != 0
#endif
    ) { perror("wal write"); exit(2); }
  }
  w->nsink += (uint64_t)w->nbuf;
  w->nbuf = 0;
  w->flushes++;
}
static inline uint64_t wal_append(wal_t *w, uint64_t k, uint64_t t, uint64_t *val) {
  uint64_t s = ++w->seq, v = valfn(k, s);
  if (w->nbuf == 0) w->first = t;
  w->buf[w->nbuf++] = (rec_t){k, s, v};
  /* Signed: under work_stealing t was read before the lock was taken, so
     it can be a little older than first. */
  if (w->nbuf >= C.group || (int64_t)(t - w->first) >= (int64_t)group_ticks) wal_flush(w);
  *val = v;
  return s;
}
static void wal_init(wal_t *w, uint64_t cap, int idx) {
  memset(w, 0, sizeof *w);
  w->buf = malloc(sizeof(rec_t) * (size_t)C.group);
  w->cap = cap;
  w->sink = malloc(sizeof(rec_t) * (size_t)(cap ? cap : 1));
  w->fd = -1;
  if (C.fsync) {
    char p[1024];
    snprintf(p, sizeof p, "%s/percore-wal-%d-%d.log", C.dir, (int)getpid(), idx);
    w->fd = open(p, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (w->fd < 0) { perror(p); exit(2); }
    unlink(p);
  }
}

/* ---------- shared state ---------- */
static uint32_t **traces; /* per worker: key << 1 | is_put */
static zipf_t Z;
static _Atomic int ready, go;
static uint64_t t_go;

/* work_stealing */
typedef struct { hlock_t lock; skl_t mt; wal_t *wal; } __attribute__((aligned(LINE))) stripe_t;
static stripe_t *stripes;
static int nstripes;
static wal_t *ws_wal;

/* per_core */
typedef struct msg {
  _Atomic(struct msg *) next;
  uint64_t key, seq, val, t0;
  uint32_t from, slot;
  uint8_t put, hit, is_reply;
} msg_t;
typedef struct { msg_t m; int busy; } slot_t;
typedef struct {
  _Atomic(msg_t *) tail __attribute__((aligned(LINE))); /* producers' line */
  msg_t *head __attribute__((aligned(LINE)));           /* the owner's lines */
  msg_t stub;
  skl_t mt;
  wal_t wal;
  slot_t *slots;
  uint64_t next;
  int finished;
  _Atomic uint32_t sleeping __attribute__((aligned(LINE)));
} __attribute__((aligned(LINE))) core_t;
static core_t *cores;
static _Atomic int ndone, stop;

/* Vyukov's intrusive MPSC queue, as p1/c/p1.c. */
static void q_push(core_t *h, msg_t *n) {
  atomic_store_explicit(&n->next, NULL, memory_order_relaxed);
  msg_t *prev = atomic_exchange_explicit(&h->tail, n, memory_order_seq_cst);
  atomic_store_explicit(&prev->next, n, memory_order_release);
}
static msg_t *q_pop(core_t *h) {
  msg_t *head = h->head;
  msg_t *next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (head == &h->stub) {
    if (!next) return NULL;
    h->head = next;
    head = next;
    next = atomic_load_explicit(&next->next, memory_order_acquire);
  }
  if (next) { h->head = next; return head; }
  if (atomic_load_explicit(&h->tail, memory_order_acquire) != head) return NULL; /* mid-push */
  q_push(h, &h->stub);
  next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (next) { h->head = next; return head; }
  return NULL;
}
static int q_empty(core_t *h) {
  return h->head == &h->stub && atomic_load_explicit(&h->tail, memory_order_seq_cst) == &h->stub;
}
static inline void pc_wake(core_t *c, uint64_t *wakes) {
  if (atomic_load_explicit(&c->sleeping, memory_order_seq_cst) == 1 &&
      atomic_exchange_explicit(&c->sleeping, 0, memory_order_acq_rel) == 1) {
    if (wakes) (*wakes)++;
    wake1_u32(&c->sleeping);
  }
}

/* ---------- checking a get ---------- */
static inline void check_get(stat_t *st, uint64_t k, int hit, uint64_t seq, uint64_t val) {
  st->gets++;
  if (hit) {
    st->hits++;
    if (val != valfn(k, seq)) st->bad++;
  } else {
    st->misses++;
    if ((k & 1) == 0) st->even_miss++; /* even keys are preloaded, never removed */
  }
}

/* Thread placement. macOS: QoS only. Linux: thread t pinned to the t-th CPU
   of the process's allowed set when pinning is on. */
static int ncpu = 1, pin_on = 0;
static int cpu_ids[1024];
static void init_cpus(void) {
#if defined(__APPLE__)
  ncpu = (int)sysconf(_SC_NPROCESSORS_ONLN);
#else
  cpu_set_t s;
  ncpu = 0;
  if (sched_getaffinity(0, sizeof s, &s) == 0)
    for (int i = 0; i < CPU_SETSIZE && ncpu < 1024; i++) if (CPU_ISSET(i, &s)) cpu_ids[ncpu++] = i;
  if (ncpu == 0) { ncpu = 1; cpu_ids[0] = 0; }
#endif
}
static void thread_setup(int t) {
#if defined(__APPLE__)
  (void)t;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#else
  if (pin_on && t >= 0) {
    cpu_set_t s;
    CPU_ZERO(&s);
    CPU_SET(cpu_ids[t % ncpu], &s);
    if (sched_setaffinity(0, sizeof s, &s) != 0) { perror("sched_setaffinity"); exit(2); }
  }
#endif
}
/* The start. Waiting threads yield until go, so the main thread gets a CPU
   even when the workers fill every CPU (4 pinned workers on 4 vCPUs starved
   it for ~6 ms in the first cloud smoke runs). The main thread sets t_go 2 ms
   ahead, then go; every thread spins until t_go. start_lag records how late
   the latest thread really started. */
static _Atomic uint64_t start_lag;
static void wait_go(void) {
  atomic_fetch_add(&ready, 1);
  while (!atomic_load_explicit(&go, memory_order_acquire)) sched_yield();
  while (now() < t_go) cpu_relax();
  uint64_t lag = now() - t_go, cur = atomic_load(&start_lag);
  while (lag > cur && !atomic_compare_exchange_weak(&start_lag, &cur, lag)) {}
}

/* ---------- work_stealing worker ---------- */
static stripe_t *stripe_for(int w, uint64_t k) {
  switch (C.v) {
  case V_WS_ONE: return &stripes[0];
  case V_WS_WORKER: return &stripes[w];
  default: return &stripes[part_of(k, (uint32_t)nstripes)];
  }
}
static void *ws_main(void *arg) {
  int w = (int)(intptr_t)arg;
  thread_setup(w);
  stat_t *st = &stats[w];
  uint32_t *tr = traces[w];
  wait_go();
  for (uint64_t i = 0; i < C.ops; i++) {
    uint64_t k = tr[i] >> 1;
    int put = tr[i] & 1;
    uint64_t t0 = now();
    if (put && C.v == V_WS_SHARD) { /* one lock covers the shard's WAL and memtable */
      uint64_t v;
      stripe_t *s = stripe_for(w, k);
      hl_take(&s->lock, st);
      uint64_t seq = wal_append(s->wal, k, t0, &v);
      skl_put(&s->mt, k, seq, v);
      hl_release(&s->lock, st);
      st->puts++;
    } else if (put) {
      uint64_t v;
      hl_take(&ws_wal->lock, st);
      uint64_t seq = wal_append(ws_wal, k, t0, &v);
      hl_release(&ws_wal->lock, st);
      stripe_t *s = stripe_for(w, k);
      hl_take(&s->lock, st);
      skl_put(&s->mt, k, seq, v);
      hl_release(&s->lock, st);
      st->puts++;
    } else if (C.v == V_WS_WORKER) { /* merge: highest seq across stripes */
      int hit = 0;
      uint64_t seq = 0, val = 0;
      for (int j = 0; j < nstripes; j++) {
        stripe_t *s = &stripes[j];
        hl_take(&s->lock, st);
        const node_t *n = skl_get(&s->mt, k);
        if (n && (!hit || n->seq > seq)) { hit = 1; seq = n->seq; val = n->val; }
        hl_release(&s->lock, st);
      }
      check_get(st, k, hit, seq, val);
    } else {
      stripe_t *s = stripe_for(w, k);
      hl_take(&s->lock, st);
      const node_t *n = skl_get(&s->mt, k);
      int hit = n != NULL;
      uint64_t seq = hit ? n->seq : 0, val = hit ? n->val : 0;
      hl_release(&s->lock, st);
      check_get(st, k, hit, seq, val);
    }
    record(st, put, now() - t0);
  }
  st->finish = now();
  return NULL;
}

/* ---------- per_core core ---------- */
static inline void pc_exec(core_t *c, msg_t *m, uint64_t t) {
  if (m->put) {
    uint64_t v, seq = wal_append(&c->wal, m->key, t, &v);
    skl_put(&c->mt, m->key, seq, v);
    m->seq = seq; m->val = v;
  } else {
    const node_t *n = skl_get(&c->mt, m->key);
    m->hit = n != NULL;
    m->seq = n ? n->seq : 0;
    m->val = n ? n->val : 0;
  }
}
static inline void pc_complete(stat_t *st, msg_t *m) {
  if (m->put) st->puts++;
  else check_get(st, m->key, m->hit, m->seq, m->val);
  record(st, m->put, now() - m->t0);
}
static void pc_idle(core_t *c, stat_t *st) {
  if (C.v == V_PC_SPIN)
    for (int i = 0; i < C.spin; i++) {
      if (!q_empty(c) || atomic_load_explicit(&stop, memory_order_relaxed)) return;
      cpu_relax();
    }
  atomic_store_explicit(&c->sleeping, 1, memory_order_seq_cst);
  if (!q_empty(c) || atomic_load_explicit(&stop, memory_order_seq_cst)) {
    atomic_store_explicit(&c->sleeping, 0, memory_order_relaxed);
    return;
  }
  st->idle_parks++;
  while (atomic_load_explicit(&c->sleeping, memory_order_acquire) == 1)
    park_u32(&c->sleeping, 1);
}
static void *pc_main(void *arg) {
  int w = (int)(intptr_t)arg, N = C.workers, M = C.inflight;
  thread_setup(w);
  core_t *c = &cores[w];
  stat_t *st = &stats[w];
  uint32_t *tr = traces[w];
  /* The core makes and fills its own memtable: first touch is local. */
  skl_init(&c->mt, C.seed ^ (0x51ED2700ULL + (uint64_t)w));
  for (uint64_t k = 2; k <= C.keys; k += 2)
    if (part_of(k, (uint32_t)N) == (uint32_t)w) skl_put(&c->mt, k, 0, valfn(k, 0));
  wait_go();
  for (;;) {
    int prog = 0;
    msg_t *m;
    while ((m = q_pop(c))) {
      prog = 1;
      if (m->is_reply) {
        pc_complete(st, m);
        c->slots[m->slot].busy = 0;
      } else {
        pc_exec(c, m, now());
        m->is_reply = 1;
        core_t *to = &cores[m->from];
        q_push(to, m);
        pc_wake(to, &st->idle_wakes);
        st->served++;
      }
    }
    for (int i = 0; i < M && c->next < C.ops; i++) {
      slot_t *s = &c->slots[i];
      if (s->busy) continue;
      prog = 1;
      uint32_t e = tr[c->next++];
      msg_t *q = &s->m;
      q->key = e >> 1; q->put = e & 1; q->t0 = now();
      q->from = (uint32_t)w; q->slot = (uint32_t)i; q->is_reply = 0;
      uint32_t o = part_of(q->key, (uint32_t)N);
      if (o == (uint32_t)w) { pc_exec(c, q, q->t0); pc_complete(st, q); continue; }
      s->busy = 1;
      st->hops++;
      q_push(&cores[o], q);
      pc_wake(&cores[o], &st->idle_wakes);
    }
    if (!c->finished && c->next == C.ops) {
      int busy = 0;
      for (int i = 0; i < M; i++) busy |= c->slots[i].busy;
      if (!busy) {
        c->finished = 1;
        st->finish = now();
        if (atomic_fetch_add(&ndone, 1) + 1 == N) {
          atomic_store_explicit(&stop, 1, memory_order_seq_cst);
          for (int j = 0; j < N; j++) pc_wake(&cores[j], NULL);
        }
      }
    }
    if (atomic_load_explicit(&stop, memory_order_acquire)) break;
    if (c->wal.nbuf && now() - c->wal.first >= group_ticks) { wal_flush(&c->wal); prog = 1; }
    if (!prog) pc_idle(c, st);
  }
  return NULL;
}

/* ---------- extension: three task runtimes under open-loop arrivals ---------- */
/* Requests come from --conns arrival streams. Stream c's i-th request is
   traces[c][i] (the same trace generator as above, so the same keys), with
   heavy flag xheavy[c][i] and arrival time t_go + xarr[c][i] (Poisson at
   --rate/conns per stream, or all 0 with --rate 0). A request is claimed
   from its stream only once it has arrived; latency is from arrival to
   completion, so time spent unclaimed counts (no coordinated omission).
   Stream c is "owned" by worker c % workers: its arrivals are that
   worker's queue. All three runtimes use the sharded layout (--shards, a
   memtable and a WAL segment per shard, routed by part_of). */
enum { XK_NEW, XK_HOP, XK_REPLY, XK_RESUME };
typedef struct xtask {
  _Atomic(struct xtask *) next;
  uint64_t key, t_arr, seq, val, wres;
  uint32_t home, from;
  uint8_t put, heavy, hit, kind;
} xtask_t;
typedef struct {
  _Atomic(xtask_t *) tail __attribute__((aligned(LINE)));
  xtask_t *head __attribute__((aligned(LINE)));
  xtask_t stub;
} xq_t;
static void xq_init(xq_t *q) {
  atomic_store(&q->stub.next, NULL);
  atomic_store(&q->tail, &q->stub);
  q->head = &q->stub;
}
/* Vyukov's intrusive MPSC queue again, over xtask_t. */
static void xq_push(xq_t *q, xtask_t *n) {
  atomic_store_explicit(&n->next, NULL, memory_order_relaxed);
  xtask_t *prev = atomic_exchange_explicit(&q->tail, n, memory_order_acq_rel);
  atomic_store_explicit(&prev->next, n, memory_order_release);
}
static xtask_t *xq_pop(xq_t *q) {
  xtask_t *head = q->head;
  xtask_t *next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (head == &q->stub) {
    if (!next) return NULL;
    q->head = next;
    head = next;
    next = atomic_load_explicit(&next->next, memory_order_acquire);
  }
  if (next) { q->head = next; return head; }
  if (atomic_load_explicit(&q->tail, memory_order_acquire) != head) return NULL; /* mid-push */
  xq_push(q, &q->stub);
  next = atomic_load_explicit(&head->next, memory_order_acquire);
  if (next) { q->head = next; return head; }
  return NULL;
}

typedef struct { _Atomic uint64_t next; } __attribute__((aligned(LINE))) xconn_t;
typedef struct {
  xq_t in;                                   /* per_core: hops and replies; place_at_spawn: placed and resumed tasks */
  _Atomic int load __attribute__((aligned(LINE))); /* place_at_spawn: tasks runnable here (placed or resumed, not done) */
  int resident __attribute__((aligned(LINE)));     /* per_core: own tasks in flight (owner only) */
  int finished;
} __attribute__((aligned(LINE))) xworker_t;
static xconn_t *xconn;
static uint64_t **xarr;   /* per stream: arrival offset from t_go, in ticks */
static uint8_t **xheavy;  /* per stream: 1 if the request also does pure work */
static xtask_t **xtasks;  /* per stream: task storage (per_core, place_at_spawn) */
static xworker_t *xw;
static uint64_t x_total, x_heavy_total;
static _Atomic uint64_t x_completed;
static uint64_t work_iters;

/* The pure work: a dependent chain of mix64, so it can't be vectorised or
   skipped, and its result depends only on (key, iters). */
static uint64_t pure_work(uint64_t k, uint64_t n) {
  uint64_t x = k;
  for (uint64_t i = 0; i < n; i++) x = mix64(x + i);
  return x;
}
static inline uint64_t x_do_work(stat_t *st, uint64_t k) {
  uint64_t t = now();
  uint64_t r = pure_work(k, work_iters);
  st->work_ticks += now() - t;
  st->works++;
  st->work_sum += r;
  return r;
}
/* Iterations of pure_work for about us microseconds: the median of 11
   timed runs, on the calling thread. */
static uint64_t calibrate(double us, int verbose) {
  uint64_t n = 1000;
  for (;;) { /* grow until one run takes >= 2 ms */
    uint64_t t = now();
    volatile uint64_t r = pure_work(7, n);
    (void)r;
    if ((double)(now() - t) * tick_ns >= 2e6) break;
    n *= 2;
  }
  double nsit[11];
  for (int j = 0; j < 11; j++) {
    uint64_t t = now();
    volatile uint64_t r = pure_work((uint64_t)j, n);
    (void)r;
    nsit[j] = (double)(now() - t) * tick_ns / (double)n;
  }
  for (int a = 0; a < 11; a++) for (int b = a + 1; b < 11; b++) if (nsit[b] < nsit[a]) { double x = nsit[a]; nsit[a] = nsit[b]; nsit[b] = x; }
  uint64_t it = (uint64_t)llround(us * 1000.0 / nsit[5]);
  if (it < 1) it = 1;
  /* Refine at the real chunk length (short runs time a little differently
     from 2 ms ones), then check: time 21 chunks of the final length. */
  double ch[21];
  for (int pass = 0; pass < 2; pass++) {
    for (int j = 0; j < 21; j++) {
      uint64_t t = now();
      volatile uint64_t r = pure_work((uint64_t)j, it);
      (void)r;
      ch[j] = (double)(now() - t) * tick_ns / 1e3;
    }
    for (int a = 0; a < 21; a++) for (int b = a + 1; b < 21; b++) if (ch[b] < ch[a]) { double x = ch[a]; ch[a] = ch[b]; ch[b] = x; }
    if (pass == 0) { it = (uint64_t)llround((double)it * us / ch[10]); if (it < 1) it = 1; }
  }
  if (verbose)
    printf("CAL os=%s work_us=%.1f iters=%" PRIu64 " ns_per_iter_2ms_med=%.4f ns_per_iter_2ms_min=%.4f ns_per_iter_2ms_max=%.4f"
           " chunk_us_med=%.2f chunk_us_min=%.2f chunk_us_max=%.2f\n",
           OS_NAME, us, it, nsit[5], nsit[0], nsit[10], ch[10], ch[0], ch[20]);
  return it;
}

static inline void x_idle(int *spins, stat_t *st) {
  if (*spins < C.spin) { (*spins)++; cpu_relax(); return; }
  st->yields++;
  sched_yield();
}
static inline int64_t x_claim(int c, uint64_t rel) {
  xconn_t *q = &xconn[c];
  uint64_t i = atomic_load_explicit(&q->next, memory_order_relaxed);
  while (i < C.ops && xarr[c][i] <= rel)
    if (atomic_compare_exchange_weak_explicit(&q->next, &i, i + 1, memory_order_relaxed, memory_order_relaxed))
      return (int64_t)i;
  return -1;
}
static int x_all_done(void) {
  for (int c = 0; c < C.conns; c++)
    if (atomic_load_explicit(&xconn[c].next, memory_order_relaxed) < C.ops) return 0;
  return 1;
}
/* Claim one arrived request: own streams first (round robin from *rr),
   then, if steal, the other streams from a random start. */
static int64_t x_claim_any(int w, int W, int *rr, int steal, uint64_t *rng, stat_t *st, int *cout) {
  int K = C.conns, nown = w < K ? (K - w + W - 1) / W : 0;
  uint64_t rel = now() - t_go;
  for (int j = 0; j < nown; j++) {
    int c = w + ((*rr + j) % nown) * W;
    int64_t i = x_claim(c, rel);
    if (i >= 0) { *rr = (*rr + j + 1) % nown; *cout = c; return i; }
  }
  if (!steal) return -1;
  int start = (int)(splitmix64(rng) % (uint64_t)K);
  for (int j = 0; j < K; j++) {
    int c = (start + j) % K;
    if (c % W == w) continue;
    int64_t i = x_claim(c, rel);
    if (i >= 0) { st->steals++; *cout = c; return i; }
  }
  return -1;
}
static inline void x_fill(xtask_t *t, int c, uint64_t i) {
  uint32_t e = traces[c][i];
  t->key = e >> 1;
  t->put = (uint8_t)(e & 1);
  t->heavy = xheavy[c][i];
  t->t_arr = t_go + xarr[c][i];
  t->hit = 0;
  t->wres = 0;
}
static inline void x_op_raw(stripe_t *s, xtask_t *t, uint64_t tn) {
  if (t->put) {
    uint64_t v;
    t->seq = wal_append(s->wal, t->key, tn, &v);
    skl_put(&s->mt, t->key, t->seq, v);
    t->val = v;
  } else {
    const node_t *n = skl_get(&s->mt, t->key);
    t->hit = n != NULL;
    t->seq = n ? n->seq : 0;
    t->val = n ? n->val : 0;
  }
}
static inline void x_op_locked(stat_t *st, xtask_t *t) {
  stripe_t *s = &stripes[part_of(t->key, (uint32_t)nshards)];
  uint64_t tn = now();
  hl_take(&s->lock, st);
  x_op_raw(s, t, tn);
  hl_release(&s->lock, st);
}
#ifdef DEBUG_SLOW
static _Atomic int dbg_n;
static uint64_t dbg[100000][4];
#endif
static inline void x_complete(stat_t *st, xtask_t *t) {
  if (t->put) st->puts++;
  else check_get(st, t->key, t->hit, t->seq, t->val);
  uint64_t tn = now(), dt = tn > t->t_arr ? tn - t->t_arr : 0;
  record(st, t->put, dt);
  if (t->heavy) st->hh[bucket(dt)]++; else st->hl[bucket(dt)]++;
  st->finish = tn;
#ifdef DEBUG_SLOW
  if (dt > 500000) {
    int n = atomic_fetch_add(&dbg_n, 1);
    if (n < 100000) { dbg[n][0] = t->t_arr - t_go; dbg[n][1] = dt; dbg[n][2] = t->from; dbg[n][3] = part_of(t->key, (uint32_t)nshards); }
  }
#endif
}

/* work_stealing: run to completion, wherever the request is claimed. */
static void *xws_main(void *arg) {
  int w = (int)(intptr_t)arg, W = C.workers, rr = 0, spins = 0;
  thread_setup(w);
  stat_t *st = &stats[w];
  uint64_t rng = C.seed ^ (0xA5A5ULL + (uint64_t)w);
  wait_go();
  for (;;) {
    int c;
    int64_t i = x_claim_any(w, W, &rr, 1, &rng, st, &c);
    if (i >= 0) {
      xtask_t t;
      x_fill(&t, c, (uint64_t)i);
      if (t.heavy) t.wres = x_do_work(st, t.key);
      x_op_locked(st, &t);
      x_complete(st, &t);
      spins = 0;
      continue;
    }
    if (x_all_done()) break;
    x_idle(&spins, st);
  }
  return NULL;
}

/* per_core: own streams only; the KV op hops to the owner core; pure work
   inline on the home core. Up to --inflight own requests in flight. */
static void *xpc_main(void *arg) {
  int w = (int)(intptr_t)arg, W = C.workers, M = C.inflight, rr = 0, spins = 0;
  thread_setup(w);
  stat_t *st = &stats[w];
  xworker_t *me = &xw[w];
  stripe_t *sh = &stripes[w];
  uint64_t rng = 0;
  /* The core makes and fills its own memtable: first touch is local. */
  skl_init(&sh->mt, C.seed ^ (0x51ED2700ULL + (uint64_t)w));
  for (uint64_t k = 2; k <= C.keys; k += 2)
    if (part_of(k, (uint32_t)nshards) == (uint32_t)w) skl_put(&sh->mt, k, 0, valfn(k, 0));
  wait_go();
  for (;;) {
    int prog = 0;
    xtask_t *m;
    while ((m = xq_pop(&me->in))) {
      prog = 1;
      if (m->kind == XK_HOP) {
        x_op_raw(sh, m, now());
        m->kind = XK_REPLY;
        st->served++;
        xq_push(&xw[m->from].in, m);
      } else {
        x_complete(st, m);
        me->resident--;
      }
    }
    if (me->resident < M) {
      int c;
      int64_t i = x_claim_any(w, W, &rr, 0, &rng, st, &c);
      if (i >= 0) {
        prog = 1;
        xtask_t *t = &xtasks[c][i];
        x_fill(t, c, (uint64_t)i);
        t->from = (uint32_t)w;
        if (t->heavy) t->wres = x_do_work(st, t->key); /* the core serves nothing meanwhile */
        uint32_t o = part_of(t->key, (uint32_t)nshards);
        if (o == (uint32_t)w) {
          x_op_raw(sh, t, now());
          x_complete(st, t);
        } else {
          me->resident++;
          st->hops++;
          t->kind = XK_HOP;
          xq_push(&xw[o].in, t);
        }
      }
    }
    if (!me->finished && me->resident == 0) {
      int done = 1;
      for (int c = w; c < C.conns; c += W)
        if (atomic_load_explicit(&xconn[c].next, memory_order_relaxed) < C.ops) done = 0;
      if (done) {
        me->finished = 1;
        if (atomic_fetch_add(&ndone, 1) + 1 == W) atomic_store_explicit(&stop, 1, memory_order_seq_cst);
      }
    }
    if (atomic_load_explicit(&stop, memory_order_acquire)) break;
    if (sh->wal->nbuf && now() - sh->wal->first >= group_ticks) { wal_flush(sh->wal); prog = 1; }
    if (prog) spins = 0; else x_idle(&spins, st);
  }
  return NULL;
}

/* place_at_spawn: the pure-work pool. One FIFO per pool thread, behind a
   spinlock (pure chunks are rare, 5% of requests, and long, ~200 us, so the
   queue is not the cost). A submit goes round robin; an idle pool thread
   steals from the other queues. */
typedef struct {
  _Atomic int lk __attribute__((aligned(LINE)));
  _Atomic uint64_t head, tail;
  uint64_t cap;
  xtask_t **ring;
} __attribute__((aligned(LINE))) pq_t;
static pq_t *pq;
static _Atomic uint32_t pool_rr;
static inline void pq_lock(pq_t *q) {
  for (;;) {
    if (!atomic_exchange_explicit(&q->lk, 1, memory_order_acquire)) return;
    while (atomic_load_explicit(&q->lk, memory_order_relaxed)) cpu_relax();
  }
}
static inline void pq_unlock(pq_t *q) { atomic_store_explicit(&q->lk, 0, memory_order_release); }
static void pool_submit(xtask_t *t) {
  pq_t *q = &pq[atomic_fetch_add_explicit(&pool_rr, 1, memory_order_relaxed) % (uint32_t)C.pool];
  pq_lock(q);
  uint64_t tl = atomic_load_explicit(&q->tail, memory_order_relaxed);
  if (tl - atomic_load_explicit(&q->head, memory_order_relaxed) >= q->cap) { fprintf(stderr, "pool queue overflow\n"); abort(); }
  q->ring[tl % q->cap] = t;
  atomic_store_explicit(&q->tail, tl + 1, memory_order_relaxed);
  pq_unlock(q);
}
static xtask_t *pq_take(pq_t *q) {
  if (atomic_load_explicit(&q->head, memory_order_relaxed) == atomic_load_explicit(&q->tail, memory_order_relaxed)) return NULL;
  xtask_t *t = NULL;
  pq_lock(q);
  uint64_t h = atomic_load_explicit(&q->head, memory_order_relaxed);
  if (h != atomic_load_explicit(&q->tail, memory_order_relaxed)) {
    t = q->ring[h % q->cap];
    atomic_store_explicit(&q->head, h + 1, memory_order_relaxed);
  }
  pq_unlock(q);
  return t;
}
static void *xpool_main(void *arg) {
  int p = (int)(intptr_t)arg, P = C.pool, spins = 0;
  thread_setup(C.workers + p);
  stat_t *st = &stats[C.workers + p];
  wait_go();
  for (;;) {
    xtask_t *t = pq_take(&pq[p]);
    for (int j = 1; !t && j < P; j++)
      if ((t = pq_take(&pq[(p + j) % P]))) st->steals++;
    if (t) {
      t->wres = x_do_work(st, t->key);
      t->kind = XK_RESUME;
      atomic_fetch_add_explicit(&xw[t->home].load, 1, memory_order_relaxed);
      xq_push(&xw[t->home].in, t);
      spins = 0;
      continue;
    }
    if (atomic_load_explicit(&x_completed, memory_order_acquire) == x_total) break;
    x_idle(&spins, st);
  }
  return NULL;
}
/* Run a task on its home worker w: a new heavy task suspends into the pool;
   anything else does its KV op (shard lock, where it is) and completes. */
static void x_pas_run(stat_t *st, int w, xtask_t *t) {
  atomic_fetch_sub_explicit(&xw[w].load, 1, memory_order_relaxed);
  if (t->kind == XK_NEW && t->heavy) { pool_submit(t); return; }
  x_op_locked(st, t);
  x_complete(st, t);
  atomic_fetch_add_explicit(&x_completed, 1, memory_order_release);
}
static void *xpas_main(void *arg) {
  int w = (int)(intptr_t)arg, W = C.workers, M = C.inflight, rr = 0, spins = 0;
  thread_setup(w);
  stat_t *st = &stats[w];
  xworker_t *me = &xw[w];
  uint64_t rng = C.seed ^ (0x5A5AULL + (uint64_t)w);
  wait_go();
  for (;;) {
    int prog = 0;
    xtask_t *m;
    while ((m = xq_pop(&me->in))) { prog = 1; x_pas_run(st, w, m); }
    /* Spawn: the least-loaded worker (ties: this one), if it has room. */
    int tgt = w, tl = atomic_load_explicit(&me->load, memory_order_relaxed);
    for (int j = 0; j < W; j++) {
      int l = atomic_load_explicit(&xw[j].load, memory_order_relaxed);
      if (l < tl) { tl = l; tgt = j; }
    }
    if (tl < M) {
      int c;
      int64_t i = x_claim_any(w, W, &rr, 1, &rng, st, &c);
      if (i >= 0) {
        prog = 1;
        xtask_t *t = &xtasks[c][i];
        x_fill(t, c, (uint64_t)i);
        t->home = (uint32_t)tgt;
        t->kind = XK_NEW;
        atomic_fetch_add_explicit(&xw[tgt].load, 1, memory_order_relaxed);
        if (tgt == w) x_pas_run(st, w, t);
        else { st->placed_remote++; xq_push(&xw[tgt].in, t); }
      }
    }
    if (atomic_load_explicit(&x_completed, memory_order_acquire) == x_total) break;
    if (prog) spins = 0; else x_idle(&spins, st);
  }
  return NULL;
}

/* ---------- the run ---------- */
static uint64_t pct(const uint64_t *h, double p) {
  uint64_t tot = 0, acc = 0;
  for (int b = 0; b < NB; b++) tot += h[b];
  if (!tot) return 0;
  uint64_t want = (uint64_t)ceil(p * (double)tot);
  if (want == 0) want = 1;
  for (int b = 0; b < NB; b++) {
    acc += h[b];
    if (acc >= want) return bucket_lo(b);
  }
  return bucket_lo(NB - 1);
}
static double cpu_ms(void) {
  struct rusage u;
  getrusage(RUSAGE_SELF, &u);
  return (u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1e3 + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e3;
}
static int fails;
#define FAIL(...) do { fprintf(stderr, "FAIL %s: ", vname[C.v]); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); fails++; } while (0)

/* Look a key up in the final state the way a get would. */
static const node_t *final_get(uint64_t k) {
  if (is_pc()) return skl_get(&cores[part_of(k, (uint32_t)nshards)].mt, k);
  if (C.v == V_WS_WORKER) {
    const node_t *best = NULL;
    for (int j = 0; j < nstripes; j++) {
      const node_t *n = skl_get(&stripes[j].mt, k);
      if (n && (!best || n->seq > best->seq)) best = n;
    }
    return best;
  }
  return skl_get(&stripe_for(0, k)->mt, k);
}

static void usage(void) {
  fprintf(stderr,
          "percore --variant ws_one|ws_worker|ws_keyed|ws_sharded|pc_spin|pc_park\n"
          "  [--get-pct 95] [--dist uniform|zipf] [--theta 0.99] [--workers 4] [--keys 1048576]\n"
          "  [--ops 200000 (per worker)] [--group 64] [--group-us 100] [--fsync --dir D]\n"
          "  [--spin 1000] [--lock-spin 64] [--stripes 16] [--inflight 1] [--seed 42] [--pin auto|on|off]\n"
          "percore --variant work_stealing|per_core|place_at_spawn   (extension, open-loop)\n"
          "  [--conns 4] [--ops N (per stream)] [--shards = workers] [--pool P (place_at_spawn)]\n"
          "  [--rate R (total req/s; 0 = all arrive at start)] [--heavy-pct 0] [--work-us 200]\n"
          "  [--work-iters N (0 = calibrate)] [--inflight M (per_core, place_at_spawn)] + the options above\n"
          "percore --calibrate [--work-us 200] [--pin on]\n"
          "percore --gap-probe   (one pinned spinner per CPU, 400 ms: how often threads lose their CPU)\n");
  exit(2);
}

/* --gap-probe: one pinned spinner per CPU for 400 ms, each reading the clock
   in a loop; a gap between two reads is time the thread didn't run
   (hypervisor steal, interrupts, other tasks). Recorded in result headers. */
static void *gap_main(void *arg) {
  int t = (int)(intptr_t)arg;
  thread_setup(t);
  uint64_t end = now() + (uint64_t)(400e6 / tick_ns), p = now(), n100 = 0, n500 = 0, n1000 = 0, mx = 0, lost = 0;
  while (p < end) {
    uint64_t q = now(), d = (uint64_t)((double)(q - p) * tick_ns);
    if (d > 100000) { n100++; lost += d; }
    if (d > 500000) n500++;
    if (d > 1000000) n1000++;
    if (d > mx) mx = d;
    p = q;
  }
  printf("GAP cpu=%d window_ms=400 gaps_over_100us=%" PRIu64 " over_500us=%" PRIu64 " over_1ms=%" PRIu64
         " max_us=%.0f lost_ms=%.2f\n", t, n100, n500, n1000, (double)mx / 1e3, (double)lost / 1e6);
  return NULL;
}
static double relax_ns(void) {
  uint64_t t = now();
  for (int i = 0; i < 20000; i++) cpu_relax();
  return (double)(now() - t) * tick_ns / 20000.0;
}

int main(int argc, char **argv) {
  int cal = 0;
  for (int i = 1; i < argc; i++) {
#define ARG(s) (strcmp(argv[i], s) == 0 && i + 1 < argc)
    if (ARG("--variant")) {
      const char *s = argv[++i];
      int f = 0;
      for (int v = 0; v < NV; v++) if (!strcmp(s, vname[v])) { C.v = (enum variant)v; f = 1; }
      if (!f) usage();
    } else if (ARG("--get-pct")) C.get_pct = atoi(argv[++i]);
    else if (ARG("--dist")) C.zipf = !strcmp(argv[++i], "zipf");
    else if (ARG("--theta")) C.theta = atof(argv[++i]);
    else if (ARG("--workers")) C.workers = atoi(argv[++i]);
    else if (ARG("--keys")) C.keys = (uint32_t)strtoul(argv[++i], NULL, 10);
    else if (ARG("--ops")) C.ops = strtoull(argv[++i], NULL, 10);
    else if (ARG("--group")) C.group = atoi(argv[++i]);
    else if (ARG("--group-us")) C.group_us = atof(argv[++i]);
    else if (ARG("--dir")) C.dir = argv[++i];
    else if (!strcmp(argv[i], "--fsync")) C.fsync = 1;
    else if (ARG("--spin")) C.spin = atoi(argv[++i]);
    else if (ARG("--lock-spin")) C.lock_spin = atoi(argv[++i]);
    else if (ARG("--stripes")) C.stripes = atoi(argv[++i]);
    else if (ARG("--inflight")) C.inflight = atoi(argv[++i]);
    else if (ARG("--seed")) C.seed = strtoull(argv[++i], NULL, 10);
    else if (ARG("--conns")) C.conns = atoi(argv[++i]);
    else if (ARG("--shards")) C.shards = atoi(argv[++i]);
    else if (ARG("--pool")) C.pool = atoi(argv[++i]);
    else if (ARG("--rate")) C.rate = atof(argv[++i]);
    else if (ARG("--heavy-pct")) C.heavy_pct = atof(argv[++i]);
    else if (ARG("--work-us")) C.work_us = atof(argv[++i]);
    else if (ARG("--work-iters")) C.work_iters = strtoull(argv[++i], NULL, 10);
    else if (ARG("--pin")) {
      const char *s = argv[++i];
      C.pin = !strcmp(s, "on") ? 1 : !strcmp(s, "off") ? 0 : !strcmp(s, "auto") ? -1 : -2;
      if (C.pin == -2) usage();
    } else if (!strcmp(argv[i], "--calibrate")) cal = 1;
    else if (!strcmp(argv[i], "--gap-probe")) cal = 2;
    else usage();
  }
  if (C.workers < 1 || C.workers > 64 || C.group < 1 || C.inflight < 1 || C.stripes < 1 || C.keys < 2 ||
      C.keys > (1u << 30) || C.get_pct < 0 || C.get_pct > 100 || C.ops < 1)
    usage();
  if (C.fsync && !C.dir) C.dir = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
  init_ticks();
  init_cpus();
  if (is_ext()) {
    if (C.conns < 1 || C.conns > 1024 || C.pool < 0 || C.pool > 64 || C.rate < 0 || C.heavy_pct < 0 || C.heavy_pct > 100)
      usage();
    if (C.shards == 0) C.shards = C.workers;
    if (C.v == V_X_PC && C.shards != C.workers) { fprintf(stderr, "per_core: --shards must equal --workers\n"); exit(2); }
    if (C.v == V_X_PAS && C.pool < 1) { fprintf(stderr, "place_at_spawn: needs --pool >= 1\n"); exit(2); }
    if (C.v != V_X_PAS) C.pool = 0;
  } else {
    C.conns = C.workers; C.pool = 0; C.rate = 0; C.heavy_pct = 0;
  }
  int N = C.workers, T = N + C.pool, K = C.conns;
#if defined(__APPLE__)
  pin_on = 0;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#else
  pin_on = C.pin == 1 || (C.pin == -1 && T <= ncpu);
#endif
  if (cal == 2) {
#if !defined(__APPLE__)
    pin_on = 1;
#endif
    pthread_t gt[1024];
    for (int t = 0; t < ncpu; t++) pthread_create(&gt[t], NULL, gap_main, (void *)(intptr_t)t);
    for (int t = 0; t < ncpu; t++) pthread_join(gt[t], NULL);
    return 0;
  }
  if (cal) {
    thread_setup(0);
    calibrate(C.work_us, 1);
    printf("CAL relax_ns=%.2f pin=%d ncpu=%d\n", relax_ns(), pin_on, ncpu);
    return 0;
  }
  double rlx = relax_ns();
  group_ticks = (uint64_t)(C.group_us * 1000.0 / tick_ns);
  nshards = is_ext() ? C.shards : N;
  if (is_ext() && C.heavy_pct > 0) work_iters = C.work_iters ? C.work_iters : calibrate(C.work_us, 0);

  /* Traces, the same for every variant at one (seed, mix, dist, streams):
     the legacy variants have one stream per worker. */
  if (C.zipf) zipf_init(&Z, C.keys, C.theta);
  traces = calloc((size_t)K, sizeof *traces);
  uint64_t trace_sum = 0, total_puts = 0;
  uint64_t *seg_puts = calloc((size_t)nshards, sizeof(uint64_t));
  for (int w = 0; w < K; w++) {
    traces[w] = malloc(sizeof(uint32_t) * C.ops);
    uint64_t r = C.seed * 0x100000001B3ULL + (uint64_t)w * 0x9E3779B97F4A7C15ULL;
    for (uint64_t i = 0; i < C.ops; i++) {
      uint64_t x = splitmix64(&r), y = splitmix64(&r);
      int put = (int)((x >> 32) % 100) >= C.get_pct;
      uint64_t k = C.zipf ? zipf_key(&Z, y) : uniform_key(y, C.keys);
      traces[w][i] = (uint32_t)(k << 1 | (uint64_t)put);
      trace_sum += mix64(traces[w][i] ^ (i << 32));
      if (put) { total_puts++; seg_puts[part_of(k, (uint32_t)nshards)]++; }
    }
  }
  /* Extension: heavy flags and arrival times, from their own streams so
     the key traces (and trace_sum) are unchanged. */
  double sched_ms = 0;
  if (is_ext()) {
    xconn = aligned_alloc(LINE, sizeof(xconn_t) * (size_t)K);
    memset(xconn, 0, sizeof(xconn_t) * (size_t)K);
    xarr = calloc((size_t)K, sizeof *xarr);
    xheavy = calloc((size_t)K, sizeof *xheavy);
    double per_conn = C.rate / K; /* req/s */
    uint64_t thr = (uint64_t)llround(C.heavy_pct * 10000.0); /* of 1e6 */
    for (int w = 0; w < K; w++) {
      xarr[w] = malloc(sizeof(uint64_t) * C.ops);
      xheavy[w] = malloc(C.ops);
      uint64_t rh = (C.seed ^ 0x4EA7F00DULL) * 0x100000001B3ULL + (uint64_t)w * 0xD1B54A32D192ED03ULL;
      uint64_t ra = (C.seed ^ 0xA77A1F00ULL) * 0x100000001B3ULL + (uint64_t)w * 0x8CB92BA72F3D8DD7ULL;
      double t = 0;
      for (uint64_t i = 0; i < C.ops; i++) {
        xheavy[w][i] = (splitmix64(&rh) % 1000000ULL) < thr;
        x_heavy_total += xheavy[w][i];
        if (per_conn > 0) {
          double u = ((double)(splitmix64(&ra) >> 11) + 1.0) * 0x1.0p-53; /* (0, 1] */
          t += -log(u) / per_conn * 1e9 / tick_ns;
        }
        xarr[w][i] = (uint64_t)t;
      }
      double ms = t * tick_ns / 1e6;
      if (ms > sched_ms) sched_ms = ms;
    }
    x_total = (uint64_t)K * C.ops;
  }

  stats = aligned_alloc(LINE, sizeof(stat_t) * (size_t)T);
  memset(stats, 0, sizeof(stat_t) * (size_t)T);
  if (is_pc()) {
    cores = aligned_alloc(LINE, sizeof(core_t) * (size_t)N);
    memset(cores, 0, sizeof(core_t) * (size_t)N);
    for (int w = 0; w < N; w++) {
      core_t *c = &cores[w];
      atomic_store(&c->tail, &c->stub);
      c->head = &c->stub;
      c->slots = aligned_alloc(LINE, ((sizeof(slot_t) * (size_t)C.inflight + LINE - 1) / LINE) * LINE);
      memset(c->slots, 0, sizeof(slot_t) * (size_t)C.inflight);
      wal_init(&c->wal, seg_puts[w], w);
    }
  } else {
    nstripes = is_ext() ? nshards : C.v == V_WS_ONE ? 1 : (C.v == V_WS_WORKER || C.v == V_WS_SHARD) ? N : C.stripes;
    stripes = aligned_alloc(LINE, sizeof(stripe_t) * (size_t)nstripes);
    memset(stripes, 0, sizeof(stripe_t) * (size_t)nstripes);
    if (C.v != V_X_PC) { /* per_core fills its shards on their home cores */
      for (int j = 0; j < nstripes; j++) skl_init(&stripes[j].mt, C.seed ^ (0x51ED2700ULL + (uint64_t)j));
      /* Preload the even keys: ws_worker spreads them over stripes by hash. */
      for (uint64_t k = 2; k <= C.keys; k += 2) {
        stripe_t *s = C.v == V_WS_WORKER ? &stripes[part_of(k, (uint32_t)nstripes)] : stripe_for(0, k);
        skl_put(&s->mt, k, 0, valfn(k, 0));
      }
    }
    if (sharded()) {
      for (int j = 0; j < nstripes; j++) {
        stripes[j].wal = aligned_alloc(LINE, sizeof(wal_t));
        wal_init(stripes[j].wal, seg_puts[j], j);
      }
    } else {
      ws_wal = aligned_alloc(LINE, sizeof(wal_t));
      wal_init(ws_wal, total_puts, 0);
    }
  }
  if (is_ext()) {
    xw = aligned_alloc(LINE, sizeof(xworker_t) * (size_t)N);
    memset(xw, 0, sizeof(xworker_t) * (size_t)N);
    for (int w = 0; w < N; w++) xq_init(&xw[w].in);
    if (C.v != V_X_WS) {
      xtasks = calloc((size_t)K, sizeof *xtasks);
      for (int w = 0; w < K; w++) {
        xtasks[w] = calloc(C.ops, sizeof(xtask_t));
        if (!xtasks[w]) { perror("calloc"); exit(2); }
        memset(xtasks[w], 0, C.ops * sizeof(xtask_t)); /* fault the pages in now, not during the run */
      }
    }
    if (C.pool) {
      pq = aligned_alloc(LINE, sizeof(pq_t) * (size_t)C.pool);
      memset(pq, 0, sizeof(pq_t) * (size_t)C.pool);
      for (int p = 0; p < C.pool; p++) {
        pq[p].cap = x_heavy_total + 1;
        pq[p].ring = malloc(sizeof(xtask_t *) * pq[p].cap);
      }
    }
  }

  pthread_t *th = calloc((size_t)T, sizeof *th);
  pthread_attr_t a;
  pthread_attr_init(&a);
#if defined(__APPLE__)
  pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
#endif
  void *(*fn)(void *) = C.v == V_X_WS ? xws_main : C.v == V_X_PC ? xpc_main : C.v == V_X_PAS ? xpas_main
                        : is_pc() ? pc_main : ws_main;
  for (int w = 0; w < N; w++)
    if (pthread_create(&th[w], &a, fn, (void *)(intptr_t)w) != 0) { perror("pthread_create"); exit(2); }
  for (int p = 0; p < C.pool; p++)
    if (pthread_create(&th[N + p], &a, xpool_main, (void *)(intptr_t)p) != 0) { perror("pthread_create"); exit(2); }
  pthread_attr_destroy(&a);
  while (atomic_load(&ready) < T) usleep(100);
  t_go = now() + (uint64_t)(2e6 / tick_ns);
  atomic_store_explicit(&go, 1, memory_order_release);
  while (now() < t_go) sched_yield();
  double cpu0 = cpu_ms(); /* at (or just after) t_go: the 2 ms wait isn't counted */
  for (int w = 0; w < T; w++) pthread_join(th[w], NULL);
  double cpu1 = cpu_ms();
#ifdef DEBUG_SLOW
  for (int d = 0; d < dbg_n && d < 100000; d++)
    fprintf(stderr, "slow arr_us=%.0f dt_us=%.0f from=%" PRIu64 " owner=%" PRIu64 "\n", dbg[d][0] / 1e3, dbg[d][1] / 1e3, dbg[d][2], dbg[d][3]);
#endif
  uint64_t t_end = 0;
  for (int w = 0; w < T; w++) if (stats[w].finish > t_end) t_end = stats[w].finish;
  double wall_ms = (double)(t_end - t_go) * tick_ns / 1e6;

  /* Sum the stats. */
  stat_t S;
  memset(&S, 0, sizeof S);
  uint64_t hall[NB];
  for (int w = 0; w < T; w++) {
    stat_t *t = &stats[w];
    S.gets += t->gets; S.puts += t->puts; S.hits += t->hits; S.misses += t->misses; S.bad += t->bad;
    S.even_miss += t->even_miss; S.hops += t->hops; S.served += t->served; S.lock_slow += t->lock_slow;
    S.lock_parks += t->lock_parks; S.lock_wakes += t->lock_wakes; S.idle_parks += t->idle_parks;
    S.idle_wakes += t->idle_wakes;
    S.steals += t->steals; S.placed_remote += t->placed_remote; S.yields += t->yields; S.works += t->works;
    S.work_ticks += t->work_ticks; S.work_sum += t->work_sum;
    for (int b = 0; b < NB; b++) { S.hg[b] += t->hg[b]; S.hp[b] += t->hp[b]; S.hl[b] += t->hl[b]; S.hh[b] += t->hh[b]; }
  }
  for (int b = 0; b < NB; b++) hall[b] = S.hg[b] + S.hp[b];

  /* Commit what's left, untimed, then check everything against the WAL. */
  int nw = sharded() ? nshards : 1;
  wal_t **wals = calloc((size_t)nw, sizeof *wals);
  for (int i = 0; i < nw; i++) wals[i] = is_pc() ? &cores[i].wal : sharded() ? stripes[i].wal : ws_wal;
  uint64_t flushes = 0, log_recs = 0;
  for (int i = 0; i < nw; i++) {
    wal_flush(wals[i]);
    flushes += wals[i]->flushes;
    log_recs += wals[i]->nsink;
    if (wals[i]->nsink != wals[i]->cap) FAIL("wal %d holds %" PRIu64 " records, expected %" PRIu64, i, wals[i]->nsink, wals[i]->cap);
  }
  uint64_t ops = (uint64_t)K * C.ops;
  if (S.gets + S.puts != ops) FAIL("ops %" PRIu64 " != %" PRIu64, S.gets + S.puts, ops);
  if (S.puts != total_puts || log_recs != total_puts) FAIL("puts %" PRIu64 " log %" PRIu64 " trace %" PRIu64, S.puts, log_recs, total_puts);
  if (S.hits + S.misses != S.gets) FAIL("hits+misses != gets");
  if (S.bad) FAIL("%" PRIu64 " gets returned a value that isn't valfn(key, seq)", S.bad);
  if (S.even_miss) FAIL("%" PRIu64 " gets missed a preloaded key", S.even_miss);
  if (S.hops != S.served) FAIL("hops %" PRIu64 " != served %" PRIu64, S.hops, S.served);
  if (is_ext()) {
    uint64_t nl = 0, nh = 0;
    for (int b = 0; b < NB; b++) { nl += S.hl[b]; nh += S.hh[b]; }
    if (S.works != x_heavy_total) FAIL("pure chunks run %" PRIu64 " != heavy requests %" PRIu64, S.works, x_heavy_total);
    if (nh != x_heavy_total || nl + nh != ops) FAIL("latency samples light %" PRIu64 " heavy %" PRIu64, nl, nh);
    if (C.v == V_X_PAS && atomic_load(&x_completed) != x_total) FAIL("completed %" PRIu64 " != %" PRIu64, (uint64_t)atomic_load(&x_completed), x_total);
    for (int c = 0; c < K; c++) if (atomic_load(&xconn[c].next) != C.ops) FAIL("stream %d not drained", c);
  }
  /* Replay the log(s): per key, the highest seq. */
  uint64_t *exp_seq = malloc(sizeof(uint64_t) * ((size_t)C.keys + 1));
  for (uint64_t k = 0; k <= C.keys; k++) exp_seq[k] = (k && (k & 1) == 0) ? 0 : UINT64_MAX;
  for (int i = 0; i < nw; i++) {
    wal_t *w = wals[i];
    uint64_t sum = 0, last = 0;
    for (uint64_t j = 0; j < w->nsink; j++) {
      rec_t *r = &w->sink[j];
      sum += rec_sum(r);
      if (r->seq != last + 1) { FAIL("wal %d seq gap at %" PRIu64, i, j); break; }
      last = r->seq;
      if (r->val != valfn(r->key, r->seq)) FAIL("wal %d bad value", i);
      if (sharded() && part_of(r->key, (uint32_t)nshards) != (uint32_t)i) FAIL("wal %d holds a key it doesn't own", i);
      if (exp_seq[r->key] == UINT64_MAX || r->seq > exp_seq[r->key]) exp_seq[r->key] = r->seq;
    }
    if (sum != w->sum) FAIL("wal %d checksum", i);
  }
  uint64_t keyset_sum = 0, present = 0;
  for (uint64_t k = 1; k <= C.keys; k++) {
    const node_t *n = final_get(k);
    if (exp_seq[k] == UINT64_MAX) { if (n) FAIL("key %" PRIu64 " present but never written", k); continue; }
    if (!n) { FAIL("key %" PRIu64 " missing", k); continue; }
    if (n->seq != exp_seq[k] || n->val != valfn(k, n->seq)) FAIL("key %" PRIu64 " seq %" PRIu64 " != log %" PRIu64, k, n->seq, exp_seq[k]);
    keyset_sum += mix64(k);
    present++;
  }
  uint64_t nodes = 0;
  if (is_pc()) {
    for (int w = 0; w < N; w++) { if (!skl_valid(&cores[w].mt)) FAIL("core %d skip list invalid", w); nodes += cores[w].mt.count; }
  } else {
    for (int j = 0; j < nstripes; j++) { if (!skl_valid(&stripes[j].mt)) FAIL("stripe %d skip list invalid", j); nodes += stripes[j].mt.count; }
  }
  if (C.v != V_WS_WORKER && nodes != present) FAIL("nodes %" PRIu64 " != keys present %" PRIu64, nodes, present);

  double cpu = cpu1 - cpu0, opsd = (double)ops, mops = opsd / (wall_ms * 1e3);
  int sustained = !is_ext() || C.rate <= 0 || mops * 1e6 >= 0.97 * C.rate;
  printf("PC lang=c variant=%s get_pct=%d dist=%s theta=%.2f workers=%d inflight=%d stripes=%d keys=%u ops_per_worker=%" PRIu64
         " group=%d group_us=%.0f fsync=%d spin=%d lock_spin=%d"
         " wall_ms=%.2f mops=%.3f p50_ns=%.0f p99_ns=%.0f get_p50_ns=%.0f get_p99_ns=%.0f put_p50_ns=%.0f put_p99_ns=%.0f"
         " cpu_ms=%.1f cpu_per_wall=%.2f hops_per_req=%.3f lock_slow_per_req=%.4f lock_parks_per_req=%.4f"
         " idle_parks_per_req=%.4f wakes_per_req=%.4f gets=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 " puts=%" PRIu64
         " flushes=%" PRIu64 " keys_present=%" PRIu64 " nodes=%" PRIu64 " trace_sum=%016" PRIx64 " keyset_sum=%016" PRIx64,
         vname[C.v], C.get_pct, C.zipf ? "zipf" : "uniform", C.zipf ? C.theta : 0.0, N,
         (is_pc() || C.v == V_X_PC || C.v == V_X_PAS) ? C.inflight : 1,
         C.v == V_WS_KEYED ? C.stripes : nstripes ? nstripes : N, C.keys, C.ops, C.group, C.group_us, C.fsync,
         (C.v == V_PC_SPIN || is_ext()) ? C.spin : 0, is_pc() || C.v == V_X_PC ? 0 : C.lock_spin, wall_ms, mops,
         pct(hall, 0.50) * tick_ns, pct(hall, 0.99) * tick_ns, pct(S.hg, 0.50) * tick_ns, pct(S.hg, 0.99) * tick_ns,
         pct(S.hp, 0.50) * tick_ns, pct(S.hp, 0.99) * tick_ns, cpu, cpu / wall_ms, (double)S.hops / opsd,
         (double)S.lock_slow / opsd, (double)S.lock_parks / opsd, (double)S.idle_parks / opsd,
         (double)(S.lock_wakes + S.idle_wakes) / opsd, S.gets, S.hits, S.misses, S.puts, flushes, present, nodes,
         trace_sum, keyset_sum);
  uint64_t nl = 0, nh = 0;
  for (int b = 0; b < NB; b++) { nl += S.hl[b]; nh += S.hh[b]; }
  printf(" p999_ns=%.0f conns=%d pool=%d rate_rps=%.0f heavy_pct=%.2f work_iters=%" PRIu64 " work_us_mean=%.2f works=%" PRIu64
         " work_sum=%016" PRIx64 " samples=%" PRIu64 " light_samples=%" PRIu64 " heavy_samples=%" PRIu64
         " light_p50_ns=%.0f light_p99_ns=%.0f light_p999_ns=%.0f heavy_p50_ns=%.0f heavy_p99_ns=%.0f heavy_p999_ns=%.0f"
         " sched_ms=%.2f lag_ms=%.2f sustained=%d steals_per_req=%.4f placed_remote_per_req=%.4f yields_per_req=%.4f"
         " start_lag_us=%.1f relax_ns=%.2f os=%s pin=%s ncpu=%d qos=%s ok=%d\n",
         pct(hall, 0.999) * tick_ns, K, C.pool, C.rate, C.heavy_pct, work_iters,
         S.works ? (double)S.work_ticks * tick_ns / 1e3 / (double)S.works : 0.0, S.works, S.work_sum, ops, nl, nh,
         pct(S.hl, 0.50) * tick_ns, pct(S.hl, 0.99) * tick_ns, pct(S.hl, 0.999) * tick_ns,
         pct(S.hh, 0.50) * tick_ns, pct(S.hh, 0.99) * tick_ns, pct(S.hh, 0.999) * tick_ns,
         sched_ms, is_ext() && C.rate > 0 ? wall_ms - sched_ms : 0.0, sustained, (double)S.steals / opsd,
         (double)S.placed_remote / opsd, (double)S.yields / opsd, (double)atomic_load(&start_lag) * tick_ns / 1e3, rlx, OS_NAME, pin_on ? "on" : "off", ncpu,
#if defined(__APPLE__)
         "user_interactive",
#else
         "none",
#endif
         fails == 0);
  return fails == 0 ? 0 : 1;
}
