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
// macOS has no thread pinning: every thread runs at
// QOS_CLASS_USER_INTERACTIVE, which prefers P cores but does not pin.

#define _DARWIN_C_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#define LINE 128 /* Apple M-series cache line */

static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }
static double tick_ns;
static inline uint64_t now(void) { return mach_absolute_time(); }

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
enum variant { V_WS_ONE, V_WS_WORKER, V_WS_KEYED, V_WS_SHARD, V_PC_SPIN, V_PC_PARK, NV };
static const char *vname[NV] = {"ws_one", "ws_worker", "ws_keyed", "ws_sharded", "pc_spin", "pc_park"};
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
} C = {V_WS_ONE, 95, 0, 0.99, 4, 1u << 20, 200000, 64, 100.0, 0, 1000, 64, 16, 1, 42, NULL};
static int is_pc(void) { return C.v == V_PC_SPIN || C.v == V_PC_PARK; }
static int sharded(void) { return is_pc() || C.v == V_WS_SHARD; } /* a WAL per shard */

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
  uint64_t hg[NB], hp[NB];
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
    os_sync_wait_on_address(&l->w, 2, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
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
    os_sync_wake_by_address_any(&l->w, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
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
/* Commit the group. Under --fsync the write and F_FULLFSYNC happen here,
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
        fcntl(w->fd, F_FULLFSYNC) != 0) { perror("wal write"); exit(2); }
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
    os_sync_wake_by_address_any(&c->sleeping, 4, OS_SYNC_WAKE_BY_ADDRESS_NONE);
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

static void set_qos(void) { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); }
static void wait_go(void) {
  atomic_fetch_add(&ready, 1);
  while (!atomic_load_explicit(&go, memory_order_acquire)) cpu_relax();
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
  set_qos();
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
    os_sync_wait_on_address(&c->sleeping, 1, 4, OS_SYNC_WAIT_ON_ADDRESS_NONE);
}
static void *pc_main(void *arg) {
  int w = (int)(intptr_t)arg, N = C.workers, M = C.inflight;
  set_qos();
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
  if (is_pc()) return skl_get(&cores[part_of(k, (uint32_t)C.workers)].mt, k);
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
          "  [--spin 1000] [--lock-spin 64] [--stripes 16] [--inflight 1] [--seed 42]\n");
  exit(2);
}

int main(int argc, char **argv) {
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
    else usage();
  }
  if (C.workers < 1 || C.workers > 64 || C.group < 1 || C.inflight < 1 || C.stripes < 1 || C.keys < 2 ||
      C.keys > (1u << 30) || C.get_pct < 0 || C.get_pct > 100)
    usage();
  if (C.fsync && !C.dir) C.dir = getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp";
  set_qos();
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  group_ticks = (uint64_t)(C.group_us * 1000.0 / tick_ns);
  int N = C.workers;

  /* Traces, the same for every variant at one (seed, mix, dist, workers). */
  if (C.zipf) zipf_init(&Z, C.keys, C.theta);
  traces = calloc((size_t)N, sizeof *traces);
  uint64_t trace_sum = 0, total_puts = 0;
  uint64_t *seg_puts = calloc((size_t)N, sizeof(uint64_t));
  for (int w = 0; w < N; w++) {
    traces[w] = malloc(sizeof(uint32_t) * C.ops);
    uint64_t r = C.seed * 0x100000001B3ULL + (uint64_t)w * 0x9E3779B97F4A7C15ULL;
    for (uint64_t i = 0; i < C.ops; i++) {
      uint64_t x = splitmix64(&r), y = splitmix64(&r);
      int put = (int)((x >> 32) % 100) >= C.get_pct;
      uint64_t k = C.zipf ? zipf_key(&Z, y) : uniform_key(y, C.keys);
      traces[w][i] = (uint32_t)(k << 1 | (uint64_t)put);
      trace_sum += mix64(traces[w][i] ^ (i << 32));
      if (put) { total_puts++; seg_puts[part_of(k, (uint32_t)N)]++; }
    }
  }

  stats = aligned_alloc(LINE, sizeof(stat_t) * (size_t)N);
  memset(stats, 0, sizeof(stat_t) * (size_t)N);
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
    nstripes = C.v == V_WS_ONE ? 1 : (C.v == V_WS_WORKER || C.v == V_WS_SHARD) ? N : C.stripes;
    stripes = aligned_alloc(LINE, sizeof(stripe_t) * (size_t)nstripes);
    memset(stripes, 0, sizeof(stripe_t) * (size_t)nstripes);
    for (int j = 0; j < nstripes; j++) skl_init(&stripes[j].mt, C.seed ^ (0x51ED2700ULL + (uint64_t)j));
    /* Preload the even keys: ws_worker spreads them over stripes by hash. */
    for (uint64_t k = 2; k <= C.keys; k += 2) {
      stripe_t *s = C.v == V_WS_WORKER ? &stripes[part_of(k, (uint32_t)nstripes)] : stripe_for(0, k);
      skl_put(&s->mt, k, 0, valfn(k, 0));
    }
    if (C.v == V_WS_SHARD) {
      for (int j = 0; j < nstripes; j++) {
        stripes[j].wal = aligned_alloc(LINE, sizeof(wal_t));
        wal_init(stripes[j].wal, seg_puts[j], j);
      }
    } else {
      ws_wal = aligned_alloc(LINE, sizeof(wal_t));
      wal_init(ws_wal, total_puts, 0);
    }
  }

  pthread_t *th = calloc((size_t)N, sizeof *th);
  pthread_attr_t a;
  pthread_attr_init(&a);
  pthread_attr_set_qos_class_np(&a, QOS_CLASS_USER_INTERACTIVE, 0);
  for (int w = 0; w < N; w++)
    pthread_create(&th[w], &a, is_pc() ? pc_main : ws_main, (void *)(intptr_t)w);
  pthread_attr_destroy(&a);
  while (atomic_load(&ready) < N) usleep(100);
  double cpu0 = cpu_ms();
  t_go = now();
  atomic_store_explicit(&go, 1, memory_order_release);
  for (int w = 0; w < N; w++) pthread_join(th[w], NULL);
  double cpu1 = cpu_ms();
  uint64_t t_end = 0;
  for (int w = 0; w < N; w++) if (stats[w].finish > t_end) t_end = stats[w].finish;
  double wall_ms = (double)(t_end - t_go) * tick_ns / 1e6;

  /* Sum the stats. */
  stat_t S;
  memset(&S, 0, sizeof S);
  uint64_t hall[NB];
  for (int w = 0; w < N; w++) {
    stat_t *t = &stats[w];
    S.gets += t->gets; S.puts += t->puts; S.hits += t->hits; S.misses += t->misses; S.bad += t->bad;
    S.even_miss += t->even_miss; S.hops += t->hops; S.served += t->served; S.lock_slow += t->lock_slow;
    S.lock_parks += t->lock_parks; S.lock_wakes += t->lock_wakes; S.idle_parks += t->idle_parks;
    S.idle_wakes += t->idle_wakes;
    for (int b = 0; b < NB; b++) { S.hg[b] += t->hg[b]; S.hp[b] += t->hp[b]; }
  }
  for (int b = 0; b < NB; b++) hall[b] = S.hg[b] + S.hp[b];

  /* Commit what's left, untimed, then check everything against the WAL. */
  int nw = sharded() ? N : 1;
  wal_t **wals = calloc((size_t)nw, sizeof *wals);
  for (int i = 0; i < nw; i++) wals[i] = is_pc() ? &cores[i].wal : C.v == V_WS_SHARD ? stripes[i].wal : ws_wal;
  uint64_t flushes = 0, log_recs = 0;
  for (int i = 0; i < nw; i++) {
    wal_flush(wals[i]);
    flushes += wals[i]->flushes;
    log_recs += wals[i]->nsink;
    if (wals[i]->nsink != wals[i]->cap) FAIL("wal %d holds %" PRIu64 " records, expected %" PRIu64, i, wals[i]->nsink, wals[i]->cap);
  }
  uint64_t ops = (uint64_t)N * C.ops;
  if (S.gets + S.puts != ops) FAIL("ops %" PRIu64 " != %" PRIu64, S.gets + S.puts, ops);
  if (S.puts != total_puts || log_recs != total_puts) FAIL("puts %" PRIu64 " log %" PRIu64 " trace %" PRIu64, S.puts, log_recs, total_puts);
  if (S.hits + S.misses != S.gets) FAIL("hits+misses != gets");
  if (S.bad) FAIL("%" PRIu64 " gets returned a value that isn't valfn(key, seq)", S.bad);
  if (S.even_miss) FAIL("%" PRIu64 " gets missed a preloaded key", S.even_miss);
  if (S.hops != S.served) FAIL("hops %" PRIu64 " != served %" PRIu64, S.hops, S.served);
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
      if (sharded() && part_of(r->key, (uint32_t)N) != (uint32_t)i) FAIL("wal %d holds a key it doesn't own", i);
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

  double cpu = cpu1 - cpu0, opsd = (double)ops;
  printf("PC lang=c variant=%s get_pct=%d dist=%s theta=%.2f workers=%d inflight=%d stripes=%d keys=%u ops_per_worker=%" PRIu64
         " group=%d group_us=%.0f fsync=%d spin=%d lock_spin=%d"
         " wall_ms=%.2f mops=%.3f p50_ns=%.0f p99_ns=%.0f get_p50_ns=%.0f get_p99_ns=%.0f put_p50_ns=%.0f put_p99_ns=%.0f"
         " cpu_ms=%.1f cpu_per_wall=%.2f hops_per_req=%.3f lock_slow_per_req=%.4f lock_parks_per_req=%.4f"
         " idle_parks_per_req=%.4f wakes_per_req=%.4f gets=%" PRIu64 " hits=%" PRIu64 " misses=%" PRIu64 " puts=%" PRIu64
         " flushes=%" PRIu64 " keys_present=%" PRIu64 " nodes=%" PRIu64 " trace_sum=%016" PRIx64 " keyset_sum=%016" PRIx64
         " qos=user_interactive ok=%d\n",
         vname[C.v], C.get_pct, C.zipf ? "zipf" : "uniform", C.zipf ? C.theta : 0.0, N, is_pc() ? C.inflight : 1,
         C.v == V_WS_KEYED ? C.stripes : nstripes ? nstripes : N, C.keys, C.ops, C.group, C.group_us, C.fsync,
         C.v == V_PC_SPIN ? C.spin : 0, is_pc() ? 0 : C.lock_spin, wall_ms, opsd / (wall_ms * 1e3),
         pct(hall, 0.50) * tick_ns, pct(hall, 0.99) * tick_ns, pct(S.hg, 0.50) * tick_ns, pct(S.hg, 0.99) * tick_ns,
         pct(S.hp, 0.50) * tick_ns, pct(S.hp, 0.99) * tick_ns, cpu, cpu / wall_ms, (double)S.hops / opsd,
         (double)S.lock_slow / opsd, (double)S.lock_parks / opsd, (double)S.idle_parks / opsd,
         (double)(S.lock_wakes + S.idle_wakes) / opsd, S.gets, S.hits, S.misses, S.puts, flushes, present, nodes,
         trace_sum, keyset_sum, fails == 0);
  return fails == 0 ? 0 : 1;
}
