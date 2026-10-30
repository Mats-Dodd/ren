// cache3.c: "The same cache three ways" (foundations.md, Staging, phase one
// of the many-cores experiments). A read-mostly cache whose misses fetch,
// modelled as Ren's runtime would run it:
//
//   one_hold  one handler instance, one lock; a miss fetches while holding
//             the instance (decision 10: an operation keeps its instance
//             across calls to handlers installed outside it).
//   one       one handler instance; a miss does `release store.fetch(k)`:
//             the instance is let go for the fetch and taken back after it.
//   striped   striped(cache(), n: 16, by: Key): 16 independent instances of
//             the same handler (each with release), routed by hash of key,
//             each with its own exact LRU and cap max/16.
//   striped_hold  as striped, without release.
//   actors    actors(entry, max: C, parts: P): one actor per key, made on
//             demand; setup fetches (so callers of a key being set up wait
//             for that setup); partitions each with a lock, a map, an exact
//             LRU and cap max/P; at() pins, each operation takes the
//             actor's lock for one call, leaving at() unpins and makes the
//             actor most recently released.
//
// Every variant runs the same deterministic per-worker op streams, so the
// checksum of values read agrees across variants (and with the Rust build).
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread/qos.h>
#endif

// ---------------------------------------------------------------- config
static uint64_t KEYS = 20000, CAP = 16000, OPS = 200000, SEED = 42;
static double ZIPF = 1.1;
static int WRITE_PCT = 5, WORKERS = 4, REPS = 1, STRIPES = 16, PARTS = 16;
static int FETCH_US = 50, FETCH_SPIN = 1, QOS = 1, VERBOSE = 0;
static const char *VARIANT = "striped";

// ---------------------------------------------------------------- utils
static inline uint64_t mix64(uint64_t z) {
  z += 0x9e3779b97f4a7c15ULL;
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}
static inline uint64_t splitmix(uint64_t *s) { *s += 0x9e3779b97f4a7c15ULL; uint64_t z = *s;
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL; z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL; return z ^ (z >> 31); }

static mach_timebase_info_data_t TB;
static inline uint64_t now_ticks(void) { return mach_absolute_time(); }
static inline uint64_t ticks_ns(uint64_t t) { return t * TB.numer / TB.denom; }

typedef os_unfair_lock lock_t;
#define LOCK_INIT OS_UNFAIR_LOCK_INIT
static inline void lk(lock_t *l) { os_unfair_lock_lock(l); }
static inline void ulk(lock_t *l) { os_unfair_lock_unlock(l); }

// ---------------------------------------------------------------- values
typedef struct { uint64_t key, check, stamp, stamp_chk; } val_t;
static inline uint64_t check_of(uint64_t k) { return mix64(k ^ 0x5eedULL); }
static inline uint64_t stamp_chk_of(uint64_t k, uint64_t s) { return mix64(s ^ (k << 1)); }

// Per-worker counters: plain, written only by their worker.
typedef struct {
  uint64_t reads, writes, hits, misses, fetches, dup_fills, coalesced, evictions, bad, fetch_ticks;
  uint64_t checksum;
  uint64_t stamp_seq;
  char pad[64];
} ctr_t;

// The fetch: a call to a store installed outside the cache, 50 us.
// spin (default): busy-waits on mach_absolute_time to 50 us. One task per
// worker, so a parked worker would have nothing else to run anyway.
// sleep: nanosleep; on this macOS a 50 us nanosleep from a non-realtime
// thread takes ~250 us (timer slack), so the measured mean is reported.
static val_t fetch(uint64_t k, ctr_t *c) {
  uint64_t t0 = now_ticks();
  if (FETCH_US > 0) {
    if (FETCH_SPIN) {
      uint64_t end_ns = ticks_ns(t0) + (uint64_t)FETCH_US * 1000;
      while (ticks_ns(now_ticks()) < end_ns) __asm__ volatile("" ::: "memory");
    } else {
      struct timespec ts = {0, (long)FETCH_US * 1000};
      while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
    }
  }
  c->fetches++;
  c->fetch_ticks += now_ticks() - t0;
  val_t v = {k, check_of(k), 0, stamp_chk_of(k, 0)};
  return v;
}

static inline void apply_write(val_t *v, uint64_t k, ctr_t *c) {
  uint64_t s = ++c->stamp_seq;
  v->stamp = s;
  v->stamp_chk = stamp_chk_of(k, s);
}
static inline void observe(const val_t *v, uint64_t k, int is_write, ctr_t *c) {
  if (v->key != k || v->check != check_of(k) || v->stamp_chk != stamp_chk_of(k, v->stamp)) c->bad++;
  if (!is_write) c->checksum += v->check;
}

// ---------------------------------------------------------------- LRU map
// Chained hash + intrusive doubly linked list, front = most recent.
typedef struct node {
  uint64_t key;
  struct node *hnext, *prev, *next;
  // payload follows in the containing struct
} node_t;

typedef struct {
  node_t **b; uint64_t mask; node_t head; uint64_t count, cap;
} lru_t;

static void lru_init(lru_t *m, uint64_t cap) {
  uint64_t n = 16; while (n < cap * 2) n <<= 1;
  m->b = calloc(n, sizeof(node_t *)); m->mask = n - 1;
  m->head.prev = m->head.next = &m->head; m->count = 0; m->cap = cap;
}
static inline node_t *lru_find(lru_t *m, uint64_t k) {
  node_t *n = m->b[mix64(k) & m->mask];
  while (n && n->key != k) n = n->hnext;
  return n;
}
static inline void lru_unlink(node_t *n) { n->prev->next = n->next; n->next->prev = n->prev; }
static inline void lru_front(lru_t *m, node_t *n) {
  n->next = m->head.next; n->prev = &m->head; m->head.next->prev = n; m->head.next = n;
}
static inline void lru_touch(lru_t *m, node_t *n) { if (m->head.next != n) { lru_unlink(n); lru_front(m, n); } }
static void lru_insert(lru_t *m, node_t *n) {
  node_t **s = &m->b[mix64(n->key) & m->mask];
  n->hnext = *s; *s = n; lru_front(m, n); m->count++;
}
static void lru_remove(lru_t *m, node_t *n) {
  node_t **s = &m->b[mix64(n->key) & m->mask];
  while (*s != n) s = &(*s)->hnext;
  *s = n->hnext; lru_unlink(n); m->count--;
}

// ---------------------------------------------------------------- handler (one / striped)
typedef struct { node_t n; val_t v; } entry_t;

typedef struct {
  lock_t lock;     // the instance's exclusion (decision 10)
  lru_t map;       // the handler's state: var map, with an exact LRU
  char pad[128];
} __attribute__((aligned(128))) inst_t;

static inst_t *insts; static int ninst; static int hold;

static void handler_setup(int n, uint64_t cap_total, int hold_) {
  ninst = n; hold = hold_;
  posix_memalign((void **)&insts, 128, sizeof(inst_t) * n);
  for (int i = 0; i < n; i++) { insts[i].lock = (lock_t)LOCK_INIT; lru_init(&insts[i].map, cap_total / n ? cap_total / n : 1); }
}
static void handler_teardown(void) {
  for (int i = 0; i < ninst; i++) {
    node_t *h = &insts[i].map.head, *n = h->next;
    while (n != h) { node_t *nx = n->next; free(n); n = nx; }
    free(insts[i].map.b);
  }
  free(insts);
}
static inline inst_t *route(uint64_t k) { return &insts[ninst == 1 ? 0 : (mix64(k ^ 0xabcdULL) >> 32) % ninst]; }

// insert with eviction of the LRU tail; called holding the instance.
static void handler_insert(inst_t *in, uint64_t k, val_t v, ctr_t *c, entry_t **out) {
  if (in->map.count >= in->map.cap) {
    node_t *t = in->map.head.prev; lru_remove(&in->map, t); free(t); c->evictions++;
  }
  entry_t *e = malloc(sizeof *e); e->n.key = k; e->v = v; lru_insert(&in->map, &e->n); *out = e;
}
static void handler_prefill(uint64_t k) {
  inst_t *in = route(k); ctr_t dummy = {0};
  if (lru_find(&in->map, k)) return;
  entry_t *e; val_t v = {k, check_of(k), 0, stamp_chk_of(k, 0)};
  handler_insert(in, k, v, &dummy, &e);
}

// get(k) / update(k): one operation of the cache handler.
static void handler_op(uint64_t k, int is_write, ctr_t *c) {
  inst_t *in = route(k);
  val_t out;
  lk(&in->lock);
  entry_t *e = (entry_t *)lru_find(&in->map, k);
  if (e) {
    c->hits++; lru_touch(&in->map, &e->n);
  } else {
    c->misses++;
    if (hold) {
      val_t v = fetch(k, c);                 // instance held across the call
      handler_insert(in, k, v, c, &e);
    } else {
      ulk(&in->lock);                        // release store.fetch(k)
      val_t v = fetch(k, c);
      lk(&in->lock);                         // taken back, queueing like any caller
      e = (entry_t *)lru_find(&in->map, k);  // state may have changed under release
      if (e) { c->dup_fills++; lru_touch(&in->map, &e->n); }
      else handler_insert(in, k, v, c, &e);
    }
  }
  if (is_write) apply_write(&e->v, k, c);
  out = e->v;                                // the result is copied out
  ulk(&in->lock);
  observe(&out, k, is_write, c);
}
static uint64_t handler_resident(void) { uint64_t r = 0; for (int i = 0; i < ninst; i++) r += insts[i].map.count; return r; }

// ---------------------------------------------------------------- actors
typedef struct actor {
  node_t n;            // in its partition's map and LRU (by last release)
  lock_t lock;         // the actor instance's exclusion, one call at a time
  _Atomic int ready;   // setup done
  int pins;            // under the partition lock
  val_t v;             // the actor's state
} actor_t;

typedef struct {
  lock_t lock;
  lru_t map;
  pthread_mutex_t setup_mu; pthread_cond_t setup_cv;   // waiters on a setup (rare path)
  char pad[128];
} __attribute__((aligned(128))) part_t;

static part_t *parts; static int nparts;

static void actors_setup(int p, uint64_t max) {
  nparts = p;
  posix_memalign((void **)&parts, 128, sizeof(part_t) * p);
  for (int i = 0; i < p; i++) {
    parts[i].lock = (lock_t)LOCK_INIT; lru_init(&parts[i].map, max / p ? max / p : 1);
    pthread_mutex_init(&parts[i].setup_mu, NULL); pthread_cond_init(&parts[i].setup_cv, NULL);
  }
}
static void actors_teardown(void) {   // reverse creation order would run finallys; ours are no-ops
  for (int i = 0; i < nparts; i++) {
    node_t *h = &parts[i].map.head, *n = h->next;
    while (n != h) { node_t *nx = n->next; free(n); n = nx; }
    free(parts[i].map.b);
    pthread_mutex_destroy(&parts[i].setup_mu); pthread_cond_destroy(&parts[i].setup_cv);
  }
  free(parts);
}
static inline part_t *part_of(uint64_t k) { return &parts[nparts == 1 ? 0 : (mix64(k ^ 0xabcdULL) >> 32) % nparts]; }

static actor_t *new_actor(uint64_t k) {
  actor_t *a = malloc(sizeof *a);
  a->n.key = k; a->lock = (lock_t)LOCK_INIT; atomic_init(&a->ready, 0); a->pins = 0;
  return a;
}
static void actors_prefill(uint64_t k) {
  part_t *p = part_of(k);
  if (lru_find(&p->map, k) || p->map.count >= p->map.cap) return;
  actor_t *a = new_actor(k); a->v = (val_t){k, check_of(k), 0, stamp_chk_of(k, 0)};
  atomic_store(&a->ready, 1); lru_insert(&p->map, &a->n);
}

// Docs.at(k): find or make k's actor, pinned for the block.
static actor_t *actors_at(part_t *p, uint64_t k, ctr_t *c) {
  actor_t *victims = NULL;
  for (;;) {
    lk(&p->lock);
    actor_t *a = (actor_t *)lru_find(&p->map, k);
    if (a) {
      a->pins++;
      int r = atomic_load_explicit(&a->ready, memory_order_acquire);
      if (r) c->hits++; else c->coalesced++;
      ulk(&p->lock);
      if (!r) {   // wait for the setup another caller is running
        pthread_mutex_lock(&p->setup_mu);
        while (!atomic_load_explicit(&a->ready, memory_order_acquire)) pthread_cond_wait(&p->setup_cv, &p->setup_mu);
        pthread_mutex_unlock(&p->setup_mu);
      }
      return a;
    }
    // make it: evict the least recently released evictable actor if full
    int stuck = 0;
    while (p->map.count >= p->map.cap) {
      node_t *t = p->map.head.prev;
      while (t != &p->map.head && ((actor_t *)t)->pins > 0) t = t->prev;
      if (t == &p->map.head) { stuck = 1; break; }
      lru_remove(&p->map, t); ((actor_t *)t)->n.hnext = (node_t *)victims; victims = (actor_t *)t;
      c->evictions++;
    }
    if (stuck) { ulk(&p->lock); sched_yield(); continue; }   // none evictable: wait
    c->misses++;
    a = new_actor(k); a->pins = 1; lru_insert(&p->map, &a->n);
    ulk(&p->lock);
    while (victims) { actor_t *nx = (actor_t *)victims->n.hnext; free(victims); victims = nx; }  // finally, on the caller's task
    val_t v = fetch(k, c);               // setup: the actor's with fetches its state
    pthread_mutex_lock(&p->setup_mu);
    a->v = v;
    atomic_store_explicit(&a->ready, 1, memory_order_release);
    pthread_cond_broadcast(&p->setup_cv);
    pthread_mutex_unlock(&p->setup_mu);
    return a;
  }
}
static inline void actors_leave(part_t *p, actor_t *a) {
  lk(&p->lock); a->pins--; lru_touch(&p->map, &a->n); ulk(&p->lock);
}
static void actors_op(uint64_t k, int is_write, ctr_t *c) {
  part_t *p = part_of(k);
  actor_t *a = actors_at(p, k, c);
  val_t out;
  lk(&a->lock);                      // Entry.get() / Entry.update(): one call
  if (is_write) apply_write(&a->v, k, c);
  out = a->v;
  ulk(&a->lock);
  actors_leave(p, a);
  observe(&out, k, is_write, c);
}
static uint64_t actors_resident(void) { uint64_t r = 0; for (int i = 0; i < nparts; i++) r += parts[i].map.count; return r; }

// ---------------------------------------------------------------- histogram
#define HSUB 6
#define HBUCKETS (128 + 64 * 48)
static inline int hbucket(uint64_t v) {
  if (v < 128) return (int)v;
  int e = 63 - __builtin_clzll(v);          // >= 7
  return 128 + (e - 7) * 64 + (int)((v >> (e - HSUB)) & 63);
}
static inline uint64_t hvalue(int b) {
  if (b < 128) return (uint64_t)b;
  int e = (b - 128) / 64 + 7, s = (b - 128) % 64;
  return ((uint64_t)(64 + s) << (e - HSUB));
}
static uint64_t hpct(const uint64_t *h, uint64_t total, double q) {
  uint64_t want = (uint64_t)ceil(q * (double)total), acc = 0;
  if (want == 0) want = 1;
  for (int b = 0; b < HBUCKETS; b++) { acc += h[b]; if (acc >= want) return hvalue(b); }
  return hvalue(HBUCKETS - 1);
}

// ---------------------------------------------------------------- workload
static double *cdf;
static uint32_t **streams;    // per worker: key | write<<31
static void make_workload(void) {
  cdf = malloc(sizeof(double) * KEYS);
  double t = 0; for (uint64_t i = 0; i < KEYS; i++) { t += 1.0 / pow((double)(i + 1), ZIPF); cdf[i] = t; }
  for (uint64_t i = 0; i < KEYS; i++) cdf[i] /= t;
  streams = malloc(sizeof(uint32_t *) * WORKERS);
  for (int w = 0; w < WORKERS; w++) {
    streams[w] = malloc(sizeof(uint32_t) * OPS);
    uint64_t s = SEED ^ ((uint64_t)(w + 1) * 0x9e3779b97f4a7c15ULL);
    for (uint64_t i = 0; i < OPS; i++) {
      double u = (double)(splitmix(&s) >> 11) * 0x1.0p-53;
      uint64_t lo = 0, hi = KEYS - 1;
      while (lo < hi) { uint64_t mid = (lo + hi) / 2; if (cdf[mid] > u) hi = mid; else lo = mid + 1; }
      int wr = (int)(splitmix(&s) % 100) < WRITE_PCT;
      streams[w][i] = (uint32_t)lo | ((uint32_t)wr << 31);
    }
  }
}

// ---------------------------------------------------------------- run
typedef struct { int w; ctr_t *c; uint64_t *hist, *hhit; uint64_t t_end; } warg_t;
static _Atomic int ready_count, go;
static int is_actors;

static void *worker(void *arg) {
  warg_t *a = arg;
#ifdef __APPLE__
  if (QOS) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
  ctr_t *c = a->c; uint64_t *h = a->hist, *hh = a->hhit; uint32_t *st = streams[a->w];
  atomic_fetch_add(&ready_count, 1);
  while (!atomic_load_explicit(&go, memory_order_acquire)) {}
  uint64_t prev = now_ticks();
  for (uint64_t i = 0; i < OPS; i++) {
    uint64_t k = st[i] & 0x7fffffffu; int wr = (int)(st[i] >> 31);
    if (wr) c->writes++; else c->reads++;
    uint64_t hits0 = c->hits;
    if (is_actors) actors_op(k, wr, c); else handler_op(k, wr, c);
    uint64_t t = now_ticks();
    int b = hbucket(ticks_ns(t - prev));
    h[b]++;
    if (c->hits != hits0) hh[b]++;
    prev = t;
  }
  a->t_end = prev;
  return NULL;
}

typedef struct { double mops, p50, p99, p999; } rep_t;
static int cmpd(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i]; const char *v = i + 1 < argc ? argv[i + 1] : "";
#define OPT(name, stmt) if (!strcmp(a, name)) { stmt; i++; continue; }
    OPT("--variant", VARIANT = v) OPT("--workers", WORKERS = atoi(v)) OPT("--ops", OPS = strtoull(v, 0, 10))
    OPT("--reps", REPS = atoi(v)) OPT("--keys", KEYS = strtoull(v, 0, 10)) OPT("--cap", CAP = strtoull(v, 0, 10))
    OPT("--zipf", ZIPF = atof(v)) OPT("--write-pct", WRITE_PCT = atoi(v)) OPT("--fetch-us", FETCH_US = atoi(v))
    OPT("--fetch", FETCH_SPIN = strcmp(v, "sleep") != 0) OPT("--stripes", STRIPES = atoi(v)) OPT("--parts", PARTS = atoi(v))
    OPT("--seed", SEED = strtoull(v, 0, 10)) OPT("--qos", QOS = atoi(v))
    if (!strcmp(a, "-v")) { VERBOSE = 1; continue; }
    fprintf(stderr, "unknown arg %s\n", a); return 2;
  }
  mach_timebase_info(&TB);
  if (KEYS >= (1u << 31)) { fprintf(stderr, "keys too large\n"); return 2; }
  is_actors = !strcmp(VARIANT, "actors");
  int n = 1, hold_ = 0; char vname[64];
  if (!strcmp(VARIANT, "one_hold")) { n = 1; hold_ = 1; }
  else if (!strcmp(VARIANT, "one")) { n = 1; }
  else if (!strcmp(VARIANT, "striped")) { n = STRIPES; }
  else if (!strcmp(VARIANT, "striped_hold")) { n = STRIPES; hold_ = 1; }
  else if (!is_actors) { fprintf(stderr, "unknown variant %s\n", VARIANT); return 2; }
  if (is_actors) snprintf(vname, sizeof vname, "actors_p%d", PARTS);
  else if (n > 1) snprintf(vname, sizeof vname, "%s%d", VARIANT, n);
  else snprintf(vname, sizeof vname, "%s", VARIANT);

  make_workload();
  rep_t *reps = calloc(REPS, sizeof(rep_t));
  double *h99 = calloc(REPS, sizeof(double));
  ctr_t tot = {0}; uint64_t checksum0 = 0; int ok = 1; uint64_t resident = 0, prefilled = 0;
  for (int r = 0; r < REPS; r++) {
    if (is_actors) actors_setup(PARTS, CAP); else handler_setup(n, CAP, hold_);
    for (uint64_t k = 0; k < CAP && k < KEYS; k++) { if (is_actors) actors_prefill(k); else handler_prefill(k); }
    prefilled = is_actors ? actors_resident() : handler_resident();
    ctr_t *cs; posix_memalign((void **)&cs, 128, sizeof(ctr_t) * WORKERS); memset(cs, 0, sizeof(ctr_t) * WORKERS);
    uint64_t **hs = malloc(sizeof(uint64_t *) * WORKERS), **hh = malloc(sizeof(uint64_t *) * WORKERS);
    warg_t *args = calloc(WORKERS, sizeof(warg_t)); pthread_t *th = malloc(sizeof(pthread_t) * WORKERS);
    atomic_store(&ready_count, 0); atomic_store(&go, 0);
    for (int w = 0; w < WORKERS; w++) {
      hs[w] = calloc(HBUCKETS, sizeof(uint64_t)); hh[w] = calloc(HBUCKETS, sizeof(uint64_t)); cs[w].stamp_seq = (uint64_t)w << 40;
      args[w] = (warg_t){w, &cs[w], hs[w], hh[w], 0};
      pthread_create(&th[w], NULL, worker, &args[w]);
    }
    while (atomic_load(&ready_count) < WORKERS) sched_yield();
    uint64_t t0 = now_ticks();
    atomic_store_explicit(&go, 1, memory_order_release);
    uint64_t tend = t0;
    for (int w = 0; w < WORKERS; w++) { pthread_join(th[w], NULL); if (args[w].t_end > tend) tend = args[w].t_end; }
    double secs = (double)ticks_ns(tend - t0) / 1e9;
    uint64_t *hall = calloc(HBUCKETS, sizeof(uint64_t)), *hhit = calloc(HBUCKETS, sizeof(uint64_t));
    ctr_t s = {0};
    for (int w = 0; w < WORKERS; w++) {
      for (int b = 0; b < HBUCKETS; b++) { hall[b] += hs[w][b]; hhit[b] += hh[w][b]; }
      ctr_t *c = &cs[w];
      s.reads += c->reads; s.writes += c->writes; s.hits += c->hits; s.misses += c->misses; s.fetches += c->fetches;
      s.dup_fills += c->dup_fills; s.coalesced += c->coalesced; s.evictions += c->evictions; s.bad += c->bad;
      s.fetch_ticks += c->fetch_ticks; s.checksum += c->checksum;
    }
    uint64_t total = s.reads + s.writes;
    resident = is_actors ? actors_resident() : handler_resident();
    // invariants
    int rok = 1;
    if (s.bad) rok = 0;
    if (total != (uint64_t)WORKERS * OPS) rok = 0;
    if (s.hits + s.misses + s.coalesced != total) rok = 0;
    if (s.fetches != s.misses) rok = 0;
    uint64_t inserts = is_actors ? s.misses : s.misses - s.dup_fills;
    if (prefilled + inserts - s.evictions != resident) rok = 0;
    if (resident > CAP) rok = 0;
    if (r == 0) checksum0 = s.checksum; else if (s.checksum != checksum0) rok = 0;
    if (!rok) ok = 0;
    reps[r] = (rep_t){(double)total / secs / 1e6, (double)hpct(hall, total, 0.50), (double)hpct(hall, total, 0.99), (double)hpct(hall, total, 0.999)};
    h99[r] = (double)hpct(hhit, s.hits, 0.99);
    if (VERBOSE)
      fprintf(stderr, "rep %d: %.3f Mops/s hits=%llu misses=%llu coalesced=%llu dup=%llu evict=%llu resident=%llu bad=%llu ok=%d\n", r,
              reps[r].mops, (unsigned long long)s.hits, (unsigned long long)s.misses, (unsigned long long)s.coalesced,
              (unsigned long long)s.dup_fills, (unsigned long long)s.evictions, (unsigned long long)resident, (unsigned long long)s.bad, rok);
    tot = s;
    if (is_actors) actors_teardown(); else handler_teardown();
    for (int w = 0; w < WORKERS; w++) { free(hs[w]); free(hh[w]); }
    free(hs); free(hh); free(hhit); free(hall); free(args); free(th); free(cs);
  }
  double m[REPS], a50[REPS], a99[REPS], a999[REPS];
  for (int r = 0; r < REPS; r++) { m[r] = reps[r].mops; a50[r] = reps[r].p50; a99[r] = reps[r].p99; a999[r] = reps[r].p999; }
  qsort(m, REPS, sizeof(double), cmpd); qsort(a50, REPS, sizeof(double), cmpd);
  qsort(a99, REPS, sizeof(double), cmpd); qsort(h99, REPS, sizeof(double), cmpd); qsort(a999, REPS, sizeof(double), cmpd);
  uint64_t total = tot.reads + tot.writes;
  printf("impl=c variant=%s workers=%d reps=%d ops=%llu mops_median=%.4f mops_min=%.4f mops_max=%.4f "
         "p50_ns=%.0f p99_ns=%.0f p999_ns=%.0f p99_hit_ns=%.0f hit_pct=%.3f misses=%llu fetches=%llu coalesced=%llu dup_fills=%llu "
         "evictions=%llu resident=%llu fetch_avg_us=%.1f checksum=%016llx ok=%d\n",
         vname, WORKERS, REPS, (unsigned long long)total, m[REPS / 2], m[0], m[REPS - 1], a50[REPS / 2], a99[REPS / 2],
         a999[REPS / 2], h99[REPS / 2], 100.0 * (double)tot.hits / (double)total, (unsigned long long)tot.misses,
         (unsigned long long)tot.fetches, (unsigned long long)tot.coalesced, (unsigned long long)tot.dup_fills,
         (unsigned long long)tot.evictions, (unsigned long long)resident,
         tot.fetches ? (double)ticks_ns(tot.fetch_ticks) / (double)tot.fetches / 1000.0 : 0.0,
         (unsigned long long)tot.checksum, ok);
  return ok ? 0 : 1;
}
