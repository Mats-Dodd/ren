// origin-counters: how should a per-origin refcount and fuel be kept across
// cores under per_core? See ../PLAN.md for the design, schemes and
// predictions.
//
// The runtime model (per_core, Seastar-style):
//   - W cores, one thread each, spinning (no parking). Each key has a home
//     core; a post is a 64-byte message shipped to the key's core over a
//     per-core-pair SPSC ring. A post to a key on this core goes on the
//     local run queue.
//   - Rings are published once per scheduler pass (tail and head stores at
//     the end of the pass), as Seastar's smp queues batch. A pass runs at
//     most BUDGET ops from the rings and BUDGET from the run queue, then
//     the edge, then flushes.
//   - The edge: each core opens origins (an outside call: one root op on a
//     key homed on this core) while its run queue is short, at most
//     EDGE_MAX a pass, only while its backlog (run queue + unread inbound
//     ring entries + spill) is under RQ_OPEN, and only with a free slot. N slots are
//     split over the cores (N/W each, remainder to the low cores). A slot
//     is freed when the origin's home learns it closed.
//   - An op spins --spin ns, then makes its posts. Posts are buffered to
//     the op's end, as a runtime would ship them, so an op knows its post
//     count n when it accounts.
//
// Schemes (--scheme):
//   none        no accounting, no admission. The baseline.
//   atomic      one padded 128 B line per origin: low 32 bits live count,
//               high 32 bits posts (fuel). An op with n posts does ONE
//               fetch_add of (n<<32)+(n-1). The core that takes live to 0
//               sends CLOSE to the home. Fuel exact.
//   vector      X10-style: each core keeps, per origin, sent[dest] and done
//               counts, and flushes them to the home at the end of the pass
//               (one message per dirty origin, more if >6 destinations).
//               The home keeps M[p] = spawns to p - completions at p and
//               closes when all are 0. Fuel soft: posts are reported with
//               the flush.
//   credit      Mattern/Huang weight throwing. The root has weight 2^63; an
//               op splits its weight over its n posts (exactly, at op end),
//               a leaf returns its weight; returns are batched per core per
//               pass to the home. Fuel is SPLIT down the tree: an op with
//               fuel f and n posts needs n <= f, children share f-n. Exact
//               per branch, a different semantics.
//   credit_soft credit for close, fuel pooled and soft: each message carries
//               the posts made on its path not yet reported ("debt"); a leaf
//               reports its debt with its weight, and debt >= DEBT_K is
//               reported early so a runaway is noticed.
//   home        home-core ownership: the counter lives on the home core,
//               non-atomic. A post made off the home is ROUTED through the
//               home (home counts it, checks fuel, forwards it). A completion
//               off the home is a DEC batched per pass. Exact fuel. Routing
//               is what makes batched decrements safe: a child's increment
//               reaches the home before the child exists.
//   credit_outbox  credit, with the op's posts MADE DURING the op (spread over
//               its spin) into a per-core outbox, and released together at the
//               op's end. Only then is k known; the op is charged 1 per post
//               (the (f+1)th post panics the op, and its outbox is dropped
//               unsent), and both weight and the remaining fuel f-k split
//               exactly over the k posts, remainder to the earliest.
//   credit_eager   weight throwing WITHOUT an outbox: posts are made during the
//               op as above and sent at once. Each post costs 1 fuel and takes
//               half the op's remaining fuel and half its remaining weight; at
//               the op's end the leftover weight returns (batched per pass) and
//               the leftover fuel is lost. The halving baseline.
//   naive       the home counter with batched NET deltas (posts - done) sent
//               straight from each core, posts sent directly. UNSOUND: a
//               child's decrement can reach the home before its parent's
//               increment. Kept to show the false closes (--check).
//
// Workloads (--wl): 1 doc->index (root posts once to another core), 2
// fan-out (root posts to 16 keys across cores), 3 chain (8 hops, each on a
// different core than the last), 4 hot origin (fan-out 4 to depth 6, 5461 ops, random cores),
// 5 skew (root posts 16, one child relays a chain of 64; fuel tests only),
// 6 relay (a chain of --L hops, each to the next core; fuel tests),
// 7 double (every op posts twice to random cores, to depth 60; fuel tests).
//
// --pub pass|op|post: when ring tails are published. pass (the default, and
// all earlier results) at the end of a scheduler pass; op after every op;
// post after every remote send. Used to show when the outbox's hold matters.
//
// macOS has no pinning: threads run at QOS_CLASS_USER_INTERACTIVE.

#define _DARWIN_C_SOURCE
#include <inttypes.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LINE 128
#define MAXW 16
#define RS 1024u
#define BUDGET 32
#define EDGE_MAX 16
#define RQ_OPEN 64
#define DEBT_K 64
#define TOTALW (1ULL << 63)

static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }
static double tick_ns;
static inline uint64_t now(void) { return mach_absolute_time(); }
static inline uint64_t mix64(uint64_t k) {
  k ^= k >> 33; k *= 0xff51afd7ed558ccdULL; k ^= k >> 33; k *= 0xc4ceb9fe1a85ec53ULL; k ^= k >> 33;
  return k;
}

enum { K_POST = 1, K_ROUTE, K_CLOSE, K_FLUSH, K_RET, K_DEC };
enum { S_NONE, S_ATOMIC, S_VECTOR, S_CREDIT, S_CSOFT, S_HOME, S_NAIVE, S_COUT, S_CEAGER, NS };
static const char *sname[NS] = {"none", "atomic", "vector", "credit", "credit_soft", "home", "naive", "credit_outbox", "credit_eager"};
#define IS_CREDIT(s) ((s) == S_CREDIT || (s) == S_CSOFT || (s) == S_COUT || (s) == S_CEAGER)
#define SPLIT_FUEL(s) ((s) == S_CREDIT || (s) == S_COUT || (s) == S_CEAGER)

typedef struct {
  uint8_t kind, last;
  uint16_t depth;
  uint16_t dest, npairs;
  uint32_t g, gen, node, fuel;
  uint64_t ts;
  int64_t a;
  union { uint64_t weight; uint32_t pairs[6]; };
} msg_t;
_Static_assert(sizeof(msg_t) == 64, "msg is one 64 B slot");

static struct {
  int scheme, wl, W, check, fuellog, pub;
  uint64_t spin_ns, N, F, origins, L;
} C = {S_ATOMIC, 1, 4, 0, 0, 0, 0, 4096, 0x7fffffffULL, 0, 64};
enum { PUB_PASS, PUB_OP, PUB_POST };
static const char *pubname[3] = {"pass", "op", "post"};
/* ops per origin; relay is L+1; double is unbounded (fuel runs only) */
static uint64_t wl_size[8] = {0, 2, 17, 9, 5461, 81, 0, 1ULL << 40};

/* ---------- spin work, calibrated ----------
   A loop of isb (~9 ns each on the M4). isb serializes, so the work can't
   overlap the accounting around it in the out-of-order window, as a chain
   of independent multiplies did (100 ns of it cost ~60 ns). */
static double spin_per_ns = 0.1;
static inline void spin(uint64_t ns) {
  uint64_t n = (uint64_t)((double)ns * spin_per_ns + 0.5);
  for (uint64_t i = 0; i < n; i++) cpu_relax();
}
static inline void spin_iters(uint64_t n) { for (uint64_t i = 0; i < n; i++) cpu_relax(); }
static void calibrate(void) {
  uint64_t n = 2000000;
  for (int r = 0; r < 3; r++) { /* the last of three, once the core has ramped */
    uint64_t t0 = now();
    for (uint64_t i = 0; i < n; i++) cpu_relax();
    spin_per_ns = (double)n / ((double)(now() - t0) * tick_ns);
  }
}

/* ---------- histograms (log-linear over ticks) ---------- */
#define NB 1408
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
static double pct(const uint64_t *h, double p) {
  uint64_t tot = 0, acc = 0;
  for (int b = 0; b < NB; b++) tot += h[b];
  if (!tot) return 0;
  uint64_t want = (uint64_t)(p * (double)tot);
  for (int b = 0; b < NB; b++) { acc += h[b]; if (acc > want) return (double)bucket_lo(b); }
  return 0;
}

/* ---------- state ---------- */
typedef struct { _Atomic uint32_t tail __attribute__((aligned(LINE))); _Atomic uint32_t head __attribute__((aligned(LINE))); } __attribute__((aligned(LINE))) ring_t;
static ring_t rings[MAXW][MAXW];
static msg_t *rbuf[MAXW][MAXW];

typedef struct { msg_t *q; uint32_t h, t, cap; } fifo_t;
typedef struct { uint32_t tail, head_cache, dirty; fifo_t ovf; } out_t;
typedef struct { uint32_t head, tail_cache; } in_t;
/* A core's view of one origin (vector, credit, home, naive). */
typedef struct {
  uint32_t gen, dirty, done, posts;
  uint32_t sent[MAXW];
  uint64_t ret, max_ts;
  int64_t delta;
} loc_t;
/* The home's record of one origin (only the home core touches it). */
typedef struct {
  uint32_t gen, open, noticed, nz;
  int64_t count;
  int32_t M[MAXW];
  uint64_t ret, posts, max_ts, t_open;
} __attribute__((aligned(LINE))) home_t;
typedef struct { _Atomic uint64_t v; } __attribute__((aligned(LINE))) aline_t;
typedef struct { uint32_t g, gen; uint64_t ts; } plog_t;
typedef struct { plog_t *v; size_t n, cap; } plogv_t;

typedef struct {
  int id;
  fifo_t rq;
  out_t out[MAXW];
  in_t in[MAXW];
  loc_t *loc;
  uint32_t *dirty, ndirty;
  uint32_t *freeslots, nfree, nslots, base;
  uint64_t quota, opened, closed, deliv, last_ts;
  uint64_t ctrl, atom, routes, late, premature, badcount, underflow, notices, panics, bug, passes;
  uint64_t hclose[NB], hlife[NB], hdlat[NB];
  uint32_t pdmin, pdmax;
  msg_t ob[16]; /* credit_outbox: this op's posts, held until it ends */
  plogv_t plog, nlog, panlog;
  unsigned rot;
} __attribute__((aligned(LINE))) core_t;

typedef struct { _Atomic uint64_t closed, deliv, last_ts; } __attribute__((aligned(LINE))) pub_t;

static core_t *cores;
static pub_t pub[MAXW];
static home_t *home;
static aline_t *aline;
static uint8_t *home_of;
static uint32_t G;
static _Atomic uint32_t *closed_through, *dcount; /* --check only */
static _Atomic int go, ready, stop;
static uint64_t t_go;

static void fifo_push(fifo_t *f, const msg_t *m) {
  if (f->t - f->h == f->cap) {
    uint32_t nc = f->cap ? f->cap * 2 : 256;
    msg_t *q = malloc(sizeof(msg_t) * nc);
    for (uint32_t i = 0; i < f->t - f->h; i++) q[i] = f->q[(f->h + i) & (f->cap - 1)];
    f->t -= f->h; f->h = 0;
    free(f->q); f->q = q; f->cap = nc;
  }
  f->q[f->t++ & (f->cap - 1)] = *m;
}
static inline uint32_t fifo_len(const fifo_t *f) { return f->t - f->h; }
static void plog_add(plogv_t *p, uint32_t g, uint32_t gen, uint64_t ts) {
  if (p->n == p->cap) { p->cap = p->cap ? p->cap * 2 : 4096; p->v = realloc(p->v, p->cap * sizeof(plog_t)); }
  p->v[p->n++] = (plog_t){g, gen, ts};
}

/* ---------- transport ---------- */
static inline int ring_try(core_t *c, int d, const msg_t *m) {
  out_t *o = &c->out[d];
  if (o->tail - o->head_cache >= RS) {
    o->head_cache = atomic_load_explicit(&rings[c->id][d].head, memory_order_acquire);
    if (o->tail - o->head_cache >= RS) return 0;
  }
  rbuf[c->id][d][o->tail & (RS - 1)] = *m;
  o->tail++;
  o->dirty = 1;
  return 1;
}
static void publish(core_t *c, int d) {
  out_t *o = &c->out[d];
  while (fifo_len(&o->ovf) && ring_try(c, d, &o->ovf.q[o->ovf.h & (o->ovf.cap - 1)])) o->ovf.h++;
  if (o->dirty) { atomic_store_explicit(&rings[c->id][d].tail, o->tail, memory_order_release); o->dirty = 0; }
}
static void send(core_t *c, int d, const msg_t *m) {
  if (d == c->id) { fifo_push(&c->rq, m); return; }
  out_t *o = &c->out[d];
  if (fifo_len(&o->ovf) == 0 && ring_try(c, d, m)) { if (C.pub == PUB_POST && m->kind == K_POST) publish(c, d); return; }
  fifo_push(&o->ovf, m); /* a post never waits: spill, keep FIFO */
}

/* ---------- workloads ---------- */
typedef struct { int dest; uint32_t node; uint16_t depth; } child_t;
static int children(const msg_t *m, int here, child_t *ch) {
  int W = C.W;
  uint64_t seed = ((uint64_t)m->g << 32) | m->gen;
  switch (C.wl) {
  case 1:
    if (m->depth) return 0;
    ch[0] = (child_t){W > 1 ? (here + 1 + (int)(mix64(seed) % (uint64_t)(W - 1))) % W : 0, 1, 1};
    return 1;
  case 2:
    if (m->depth) return 0;
    for (int i = 0; i < 16; i++) ch[i] = (child_t){(here + 1 + i) % W, (uint32_t)i + 1, 1};
    return 16;
  case 3:
    if (m->depth >= 8) return 0; /* each hop on a different core than the last */
    ch[0] = (child_t){W > 1 ? (here + 1 + (int)(mix64(seed ^ m->depth) % (uint64_t)(W - 1))) % W : 0, m->node + 1,
                      (uint16_t)(m->depth + 1)};
    return 1;
  case 4:
    if (m->depth >= 6) return 0;
    for (int i = 0; i < 4; i++) {
      uint32_t node = m->node * 4 + 1 + (uint32_t)i;
      ch[i] = (child_t){(int)(mix64(seed * 0x9E3779B97F4A7C15ULL ^ node) % (uint64_t)W), node, (uint16_t)(m->depth + 1)};
    }
    return 4;
  case 5:
    if (m->depth == 0) {
      for (int i = 0; i < 16; i++) ch[i] = (child_t){(here + 1 + i) % W, (uint32_t)i, 1};
      return 16;
    }
    if (m->node == 0 && m->depth < 65) { ch[0] = (child_t){(here + 1) % W, 0, (uint16_t)(m->depth + 1)}; return 1; }
    return 0;
  case 6:
    if (m->depth >= C.L) return 0;
    ch[0] = (child_t){(here + 1) % W, 0, (uint16_t)(m->depth + 1)};
    return 1;
  case 7:
    if (m->depth >= 60) return 0;
    for (int i = 0; i < 2; i++) {
      uint32_t node = m->node * 2 + 1 + (uint32_t)i;
      ch[i] = (child_t){(int)(mix64(seed * 0x9E3779B97F4A7C15ULL ^ node ^ ((uint64_t)m->depth << 40)) % (uint64_t)W), node,
                        (uint16_t)(m->depth + 1)};
    }
    return 2;
  }
  return 0;
}

/* ---------- the home's side ---------- */
static void home_close(core_t *c, uint32_t g, uint64_t last_ts) {
  home_t *H = &home[g];
  uint64_t t = now();
  c->hclose[bucket(t > last_ts ? t - last_ts : 0)]++;
  c->hlife[bucket(t - H->t_open)]++;
  if (C.check) {
    uint32_t d = atomic_load_explicit(&dcount[g], memory_order_acquire);
    if (!C.fuellog && d != wl_size[C.wl]) c->badcount++;
    atomic_store_explicit(&dcount[g], 0, memory_order_relaxed);
    atomic_store_explicit(&closed_through[g], H->gen, memory_order_release);
  }
  H->open = 0;
  c->closed++;
  c->last_ts = t;
  c->freeslots[c->nfree++] = g - c->base;
}
static inline void fuel_check(core_t *c, home_t *H, uint32_t g) {
  if (H->posts > C.F && !H->noticed) {
    H->noticed = 1; c->notices++;
    if (C.fuellog) plog_add(&c->nlog, g, H->gen, now());
  }
}
static inline void vec_add(home_t *H, int d, int32_t v) {
  int32_t o = H->M[d], n = o + v;
  H->M[d] = n;
  H->nz += (o == 0) - (n == 0);
}

static void run_op(core_t *c, const msg_t *m);
static void handle_ctrl(core_t *c, const msg_t *m, int src) {
  home_t *H = &home[m->g];
  if (!H->open || H->gen != m->gen) { c->late++; return; }
  switch (m->kind) {
  case K_CLOSE: home_close(c, m->g, m->ts); break;
  case K_FLUSH:
    for (int i = 0; i < m->npairs; i++) vec_add(H, (int)(m->pairs[i] >> 24), (int32_t)(m->pairs[i] & 0xffffff));
    if (m->last) {
      vec_add(H, src, -(int32_t)m->a);
      H->posts += m->fuel;
      if (m->ts > H->max_ts) H->max_ts = m->ts;
      fuel_check(c, H, m->g);
      if (H->nz == 0) home_close(c, m->g, H->max_ts);
    }
    break;
  case K_RET:
    H->ret += m->weight;
    H->posts += (uint64_t)m->a;
    if (m->ts > H->max_ts) H->max_ts = m->ts;
    if (C.scheme == S_CSOFT) fuel_check(c, H, m->g);
    if (H->ret == TOTALW) home_close(c, m->g, H->max_ts);
    break;
  case K_DEC:
    if (C.scheme == S_NAIVE) H->count += m->a; else H->count -= m->a;
    if (m->ts > H->max_ts) H->max_ts = m->ts;
    if (H->count == 0) home_close(c, m->g, H->max_ts);
    break;
  case K_ROUTE: {
    H->count++; H->posts++;
    fuel_check(c, H, m->g);
    msg_t k = *m;
    k.kind = K_POST;
    c->routes++;
    if (C.fuellog) plog_add(&c->plog, m->g, m->gen, now());
    send(c, m->dest, &k);
    break;
  }
  }
}

/* ---------- a core's own view ---------- */
static inline loc_t *getloc(core_t *c, const msg_t *m) {
  loc_t *L = &c->loc[m->g];
  if (L->gen != m->gen) {
    if (L->dirty) c->bug++; /* a sound scheme flushed before the origin could close */
    uint32_t d = L->dirty;
    memset(L, 0, sizeof *L);
    L->gen = m->gen; L->dirty = d;
  }
  if (!L->dirty) { L->dirty = 1; c->dirty[c->ndirty++] = m->g; }
  return L;
}

static inline void note_panic(core_t *c, const msg_t *m) {
  c->panics++;
  if (m->depth < c->pdmin) c->pdmin = m->depth;
  if (m->depth > c->pdmax) c->pdmax = m->depth;
  if (C.fuellog) plog_add(&c->panlog, m->g, m->gen, now());
}

static void run_op(core_t *c, const msg_t *m) {
  uint64_t t0 = now();
  if (m->depth) c->hdlat[bucket(t0 > m->ts ? t0 - m->ts : 0)]++; /* parent op start -> this delivery */
  int midpost = C.scheme == S_COUT || C.scheme == S_CEAGER;
  if (!midpost) spin(C.spin_ns);
  c->deliv++;
  uint32_t g = m->g;
  if (C.check && C.scheme != S_NONE) {
    if (atomic_load_explicit(&closed_through[g], memory_order_acquire) >= m->gen) c->premature++;
    atomic_fetch_add_explicit(&dcount[g], 1, memory_order_relaxed);
  }
  uint64_t t = midpost ? 0 : now(); /* midpost schemes take it after their spin */
  child_t ch[16];
  int n = children(m, c->id, ch);
  int h = home_of[g];
  msg_t k;
  memset(&k, 0, sizeof k);
  k.kind = K_POST; k.g = g; k.gen = m->gen; k.ts = t0;
#define FILL(i) (k.dest = (uint16_t)ch[i].dest, k.node = ch[i].node, k.depth = ch[i].depth)
#define LOGPOST() do { if (C.fuellog) plog_add(&c->plog, g, m->gen, now()); } while (0)

  switch (C.scheme) {
  case S_NONE:
    for (int i = 0; i < n; i++) { FILL(i); send(c, ch[i].dest, &k); }
    break;

  case S_ATOMIC: {
    uint64_t add = ((uint64_t)n << 32) + (uint64_t)n - 1;
    uint64_t old = atomic_fetch_add_explicit(&aline[g].v, add, memory_order_acq_rel);
    c->atom++;
    uint64_t pold = old >> 32;
    if (pold <= C.F && pold + (uint64_t)n > C.F) { c->notices++; if (C.fuellog) plog_add(&c->nlog, g, m->gen, now()); }
    for (int i = 0; i < n; i++) { FILL(i); LOGPOST(); send(c, ch[i].dest, &k); }
    if ((uint32_t)old + (uint32_t)n - 1 == 0) {
      if (h == c->id) home_close(c, g, t);
      else { msg_t x = k; x.kind = K_CLOSE; x.ts = t; send(c, h, &x); c->ctrl++; }
    }
    break;
  }

  case S_VECTOR:
    for (int i = 0; i < n; i++) { FILL(i); LOGPOST(); send(c, ch[i].dest, &k); }
    if (h == c->id) {
      home_t *H = &home[g];
      for (int i = 0; i < n; i++) vec_add(H, ch[i].dest, 1);
      vec_add(H, c->id, -1);
      H->posts += (uint64_t)n;
      if (t > H->max_ts) H->max_ts = t;
      fuel_check(c, H, g);
      if (H->nz == 0) home_close(c, g, H->max_ts);
    } else {
      loc_t *L = getloc(c, m);
      for (int i = 0; i < n; i++) L->sent[ch[i].dest]++;
      L->done++; L->posts += (uint32_t)n; L->max_ts = t;
    }
    break;

  case S_CREDIT:
  case S_CSOFT: {
    uint64_t w = m->weight, ret = 0, rposts = 0;
    int nn = n;
    if (C.scheme == S_CREDIT && (uint32_t)n > m->fuel) { nn = 0; note_panic(c, m); }
    if (nn > 0) {
      uint64_t q = w / (uint64_t)nn, r = w - q * (uint64_t)nn;
      if (q == 0) c->underflow++;
      uint32_t fq = 0, fr = 0, debt = 0;
      if (C.scheme == S_CREDIT) { uint32_t rem = m->fuel - (uint32_t)nn; fq = rem / (uint32_t)nn; fr = rem - fq * (uint32_t)nn; }
      else { debt = m->fuel + (uint32_t)nn; if (debt >= DEBT_K) { rposts = debt; debt = 0; } }
      for (int i = 0; i < nn; i++) {
        FILL(i);
        k.weight = q + (i == 0 ? r : 0);
        k.fuel = C.scheme == S_CREDIT ? fq + (i == 0 ? fr : 0) : (i == 0 ? debt : 0);
        LOGPOST();
        send(c, ch[i].dest, &k);
      }
    } else {
      ret = w;
      if (C.scheme == S_CSOFT) rposts = m->fuel;
    }
    if (ret || rposts) {
      if (h == c->id) {
        home_t *H = &home[g];
        H->ret += ret; H->posts += rposts;
        if (t > H->max_ts) H->max_ts = t;
        if (C.scheme == S_CSOFT) fuel_check(c, H, g);
        if (H->ret == TOTALW) home_close(c, g, H->max_ts);
      } else {
        loc_t *L = getloc(c, m);
        L->ret += ret; L->posts += (uint32_t)rposts; L->max_ts = t;
      }
    }
    break;
  }

  case S_COUT:
  case S_CEAGER: {
    /* The op makes its posts while it runs: post i after (i+1)/(n+1) of the
       spin. It does not use n until it ends (outbox) or ever (eager). */
    uint64_t T = (uint64_t)((double)C.spin_ns * spin_per_ns + 0.5), done_it = 0;
    uint64_t w = m->weight, ret = 0;
    uint32_t f = m->fuel;
    int nb = 0, panicked = 0;
    for (int i = 0; i < n; i++) {
      uint64_t to = T * (uint64_t)(i + 1) / (uint64_t)(n + 1);
      spin_iters(to - done_it); done_it = to;
      if (C.scheme == S_COUT) {
        if ((uint32_t)nb + 1 > f) { panicked = 1; break; } /* the (f+1)th post */
        FILL(i);
        c->ob[nb++] = k;
      } else {
        if (f < 1) { panicked = 1; break; }
        f -= 1;
        uint32_t cf = f / 2; f -= cf;
        uint64_t cw = w / 2;
        if (cw == 0) c->underflow++;
        w -= cw;
        FILL(i); k.weight = cw; k.fuel = cf;
        LOGPOST();
        send(c, ch[i].dest, &k);
      }
    }
    if (panicked) note_panic(c, m); /* the op aborts: no more work, no more posts */
    else spin_iters(T - done_it);
    t = now();
    if (C.scheme == S_COUT) {
      if (!panicked && nb > 0) {
        uint64_t q = w / (uint64_t)nb, r = w - q * (uint64_t)nb;
        if (q == 0) c->underflow++;
        uint32_t rem = f - (uint32_t)nb, fq = rem / (uint32_t)nb, fr = rem - fq * (uint32_t)nb;
        for (int i = 0; i < nb; i++) {
          msg_t *o = &c->ob[i];
          o->weight = q + (i == 0 ? r : 0);
          o->fuel = fq + (i == 0 ? fr : 0);
          LOGPOST();
          send(c, o->dest, o);
        }
      } else ret = w; /* a leaf, or a panic: the outbox is dropped unsent */
    } else ret = w; /* eager keeps half of everything: every op returns some */
    if (ret) {
      if (h == c->id) {
        home_t *H = &home[g];
        H->ret += ret;
        if (t > H->max_ts) H->max_ts = t;
        if (H->ret == TOTALW) home_close(c, g, H->max_ts);
      } else {
        loc_t *L = getloc(c, m);
        L->ret += ret; L->max_ts = t;
      }
    }
    break;
  }

  case S_HOME:
    if (h == c->id) {
      home_t *H = &home[g];
      H->count += n - 1;
      H->posts += (uint64_t)n;
      fuel_check(c, H, g);
      for (int i = 0; i < n; i++) { FILL(i); LOGPOST(); send(c, ch[i].dest, &k); }
      if (t > H->max_ts) H->max_ts = t;
      if (H->count == 0) home_close(c, g, H->max_ts);
    } else {
      for (int i = 0; i < n; i++) { FILL(i); k.kind = K_ROUTE; send(c, h, &k); c->ctrl++; }
      loc_t *L = getloc(c, m);
      L->done++; L->max_ts = t;
    }
    break;

  case S_NAIVE:
    for (int i = 0; i < n; i++) { FILL(i); send(c, ch[i].dest, &k); }
    if (h == c->id) {
      home_t *H = &home[g];
      H->count += n - 1;
      if (t > H->max_ts) H->max_ts = t;
      if (H->count == 0) home_close(c, g, H->max_ts);
    } else {
      loc_t *L = getloc(c, m);
      L->delta += n - 1; L->max_ts = t;
    }
    break;
  }
  if (C.pub == PUB_OP)
    for (int d = 0; d < C.W; d++) if (d != c->id && (c->out[d].dirty || fifo_len(&c->out[d].ovf))) publish(c, d);
}

/* End of a pass: flush each dirty origin's batched accounting to its home. */
static void flush_dirty(core_t *c) {
  for (uint32_t j = 0; j < c->ndirty; j++) {
    uint32_t g = c->dirty[j];
    loc_t *L = &c->loc[g];
    int h = home_of[g];
    msg_t x;
    memset(&x, 0, sizeof x);
    x.g = g; x.gen = L->gen; x.ts = L->max_ts;
    switch (C.scheme) {
    case S_VECTOR: {
      x.kind = K_FLUSH;
      for (int d = 0; d < C.W; d++) {
        if (!L->sent[d]) continue;
        if (x.npairs == 6) { send(c, h, &x); c->ctrl++; x.npairs = 0; }
        x.pairs[x.npairs++] = ((uint32_t)d << 24) | L->sent[d];
      }
      x.last = 1; x.a = L->done; x.fuel = L->posts; /* done goes in the last part */
      send(c, h, &x); c->ctrl++;
      break;
    }
    case S_CREDIT: case S_CSOFT: case S_COUT: case S_CEAGER:
      x.kind = K_RET; x.weight = L->ret; x.a = L->posts;
      send(c, h, &x); c->ctrl++;
      break;
    case S_HOME:
      x.kind = K_DEC; x.a = L->done;
      send(c, h, &x); c->ctrl++;
      break;
    case S_NAIVE:
      x.kind = K_DEC; x.a = L->delta;
      send(c, h, &x); c->ctrl++;
      break;
    }
    uint32_t gen = L->gen;
    memset(L, 0, sizeof *L);
    L->gen = gen;
  }
  c->ndirty = 0;
}

static void edge_open(core_t *c) {
  msg_t r;
  memset(&r, 0, sizeof r);
  r.kind = K_POST; r.weight = TOTALW;
  r.fuel = SPLIT_FUEL(C.scheme) ? (uint32_t)(C.F > 0xffffffffULL ? 0xffffffffULL : C.F) : 0;
  if (C.scheme == S_NONE) {
    r.g = c->base + (uint32_t)(c->opened % (c->nslots ? c->nslots : 1));
    r.gen = (uint32_t)c->opened + 1;
  } else {
    uint32_t slot = c->freeslots[--c->nfree];
    uint32_t g = c->base + slot;
    home_t *H = &home[g];
    H->gen++; H->open = 1; H->t_open = now(); H->posts = 0; H->max_ts = 0; H->noticed = 0; H->ret = 0;
    switch (C.scheme) {
    case S_ATOMIC: atomic_store_explicit(&aline[g].v, 1, memory_order_relaxed); break;
    case S_VECTOR: memset(H->M, 0, sizeof H->M); H->M[c->id] = 1; H->nz = 1; break;
    case S_HOME: case S_NAIVE: H->count = 1; break;
    }
    r.g = g; r.gen = H->gen;
  }
  c->opened++;
  run_op(c, &r);
}

static void end_pass(core_t *c) {
  flush_dirty(c);
  for (int d = 0; d < C.W; d++) if (d != c->id) publish(c, d);
}

static void *worker(void *arg) {
  core_t *c = &cores[(intptr_t)arg];
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  int W = C.W, id = c->id;
  atomic_fetch_add(&ready, 1);
  while (!atomic_load_explicit(&go, memory_order_acquire)) cpu_relax();
  uint64_t pclosed = 0, pdeliv = 0;
  while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
    int budget = BUDGET;
    for (int j = 1; j < W && budget > 0; j++) {
      int s = (int)((id + j + c->rot) % (unsigned)W);
      if (s == id) continue;
      in_t *in = &c->in[s];
      if (in->head == in->tail_cache) in->tail_cache = atomic_load_explicit(&rings[s][id].tail, memory_order_acquire);
      uint32_t h0 = in->head;
      while (in->head != in->tail_cache && budget > 0) {
        const msg_t *m = &rbuf[s][id][in->head & (RS - 1)];
        if (m->kind == K_POST) { run_op(c, m); budget--; }
        else handle_ctrl(c, m, s);
        in->head++;
      }
      if (in->head != h0) atomic_store_explicit(&rings[s][id].head, in->head, memory_order_release);
    }
    c->rot++;
    for (int b = 0; b < BUDGET && fifo_len(&c->rq); b++) {
      msg_t m = c->rq.q[c->rq.h++ & (c->rq.cap - 1)];
      run_op(c, &m);
    }
    /* Work before intake: the edge opens only while this core's backlog
       (run queue + unread inbound ring entries + its own spill queues) is
       under RQ_OPEN. The same rule for every scheme; it is what bounds
       `none`, which has no admission. */
    uint32_t backlog = fifo_len(&c->rq);
    for (int s = 0; s < W; s++) if (s != id) {
      c->in[s].tail_cache = atomic_load_explicit(&rings[s][id].tail, memory_order_acquire);
      backlog += c->in[s].tail_cache - c->in[s].head + fifo_len(&c->out[s].ovf);
    }
    for (int e = 0; e < EDGE_MAX && c->opened < c->quota && backlog < RQ_OPEN &&
                    (C.scheme == S_NONE || c->nfree > 0); e++, backlog++)
      edge_open(c);
    end_pass(c);
    c->passes++;
    if (c->deliv != pdeliv || c->closed != pclosed) {
      if (C.scheme == S_NONE) c->last_ts = now();
      pdeliv = c->deliv; pclosed = c->closed;
      atomic_store_explicit(&pub[id].deliv, pdeliv, memory_order_relaxed);
      atomic_store_explicit(&pub[id].closed, pclosed, memory_order_relaxed);
      atomic_store_explicit(&pub[id].last_ts, c->last_ts, memory_order_relaxed);
    }
  }
  return NULL;
}

static int cmp_plog(const void *a, const void *b) {
  const plog_t *x = a, *y = b;
  if (x->g != y->g) return x->g < y->g ? -1 : 1;
  if (x->gen != y->gen) return x->gen < y->gen ? -1 : 1;
  return x->ts < y->ts ? -1 : x->ts > y->ts;
}
/* posts of (g, gen) made strictly before ts */
static uint64_t posts_before(plog_t *v, size_t n, uint32_t g, uint32_t gen, uint64_t ts) {
  size_t lo = 0, hi = n;
  while (lo < hi) { size_t mid = (lo + hi) / 2; plog_t *p = &v[mid];
    if (p->g < g || (p->g == g && (p->gen < gen || (p->gen == gen && p->ts < ts)))) lo = mid + 1; else hi = mid; }
  size_t lo2 = 0, hi2 = n;
  while (lo2 < hi2) { size_t mid = (lo2 + hi2) / 2; plog_t *p = &v[mid];
    if (p->g < g || (p->g == g && p->gen < gen)) lo2 = mid + 1; else hi2 = mid; }
  return lo - lo2;
}
static uint64_t posts_of(plog_t *v, size_t n, uint32_t g, uint32_t gen) { return posts_before(v, n, g, gen, UINT64_MAX); }

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  uint64_t target = 0;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
    if (!strcmp(a, "--scheme")) { for (int s = 0; s < NS; s++) if (!strcmp(v, sname[s])) C.scheme = s; i++; }
    else if (!strcmp(a, "--wl")) { C.wl = atoi(v); i++; }
    else if (!strcmp(a, "--workers")) { C.W = atoi(v); i++; }
    else if (!strcmp(a, "--spin")) { C.spin_ns = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--N")) { C.N = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--F")) { C.F = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--origins")) { C.origins = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--deliveries")) { target = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--check")) C.check = 1;
    else if (!strcmp(a, "--fuellog")) C.fuellog = 1;
    else if (!strcmp(a, "--L")) { C.L = strtoull(v, 0, 10); i++; }
    else if (!strcmp(a, "--pub")) { for (int s = 0; s < 3; s++) if (!strcmp(v, pubname[s])) C.pub = s; i++; }
    else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
  }
  if (C.W < 1 || C.W > MAXW || C.wl < 1 || C.wl > 7 || C.L > 60000) { fprintf(stderr, "bad args\n"); return 2; }
  wl_size[6] = C.L + 1;
  if (!C.origins) C.origins = (target ? target : 200000ULL * C.W) / wl_size[C.wl];
  if (C.origins < C.N) C.origins = C.N;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  calibrate();
  int W = C.W;

  /* Admission slots split over cores; quota of origins follows the slots. */
  cores = aligned_alloc(LINE, sizeof(core_t) * (size_t)W);
  memset(cores, 0, sizeof(core_t) * (size_t)W);
  G = 0;
  uint64_t qsum = 0;
  for (int c = 0; c < W; c++) {
    core_t *k = &cores[c];
    k->id = c; k->pdmin = UINT32_MAX;
    k->nslots = (uint32_t)(C.N / (uint64_t)W + ((uint64_t)c < C.N % (uint64_t)W));
    k->base = G;
    G += k->nslots ? k->nslots : 1;
  }
  for (int c = 0; c < W; c++) {
    core_t *k = &cores[c];
    k->quota = C.origins * k->nslots / C.N;
    if (c == 0) { uint64_t s = 0; for (int j = 0; j < W; j++) s += C.origins * cores[j].nslots / C.N; k->quota += C.origins - s; }
    qsum += k->quota;
    k->freeslots = malloc(sizeof(uint32_t) * (k->nslots + 1));
    for (uint32_t s = 0; s < k->nslots; s++) k->freeslots[s] = k->nslots - 1 - s;
    k->nfree = k->nslots;
    k->loc = calloc(G, sizeof(loc_t));
    k->dirty = malloc(sizeof(uint32_t) * G);
  }
  home = aligned_alloc(LINE, sizeof(home_t) * G); memset(home, 0, sizeof(home_t) * G);
  aline = aligned_alloc(LINE, sizeof(aline_t) * G); memset(aline, 0, sizeof(aline_t) * G);
  home_of = malloc(G);
  for (int c = 0; c < W; c++) for (uint32_t s = 0; s < (cores[c].nslots ? cores[c].nslots : 1); s++) home_of[cores[c].base + s] = (uint8_t)c;
  if (C.check) { closed_through = calloc(G, sizeof *closed_through); dcount = calloc(G, sizeof *dcount); }
  for (int s = 0; s < W; s++) for (int d = 0; d < W; d++) if (s != d) {
    rbuf[s][d] = aligned_alloc(LINE, sizeof(msg_t) * RS);
    memset(rbuf[s][d], 0, sizeof(msg_t) * RS);
  }
  uint64_t exp_deliv = qsum * wl_size[C.wl];

  pthread_t th[MAXW];
  pthread_attr_t at;
  pthread_attr_init(&at);
  pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
  for (int c = 0; c < W; c++) pthread_create(&th[c], &at, worker, (void *)(intptr_t)c);
  while (atomic_load(&ready) < W) usleep(100);
  t_go = now();
  atomic_store_explicit(&go, 1, memory_order_release);
  uint64_t deadline = t_go + (uint64_t)(60e9 / tick_ns);
  int timeout = 0;
  for (;;) {
    usleep(50);
    uint64_t s = 0;
    for (int c = 0; c < W; c++) s += atomic_load_explicit(C.scheme == S_NONE ? &pub[c].deliv : &pub[c].closed, memory_order_relaxed);
    if (s >= (C.scheme == S_NONE ? exp_deliv : qsum)) break;
    if (now() > deadline) { timeout = 1; break; }
  }
  atomic_store(&stop, 1);
  for (int c = 0; c < W; c++) pthread_join(th[c], NULL);
  uint64_t t_end = 0;
  for (int c = 0; c < W; c++) if (pub[c].last_ts > t_end) t_end = pub[c].last_ts;
  double wall_ms = (double)(t_end - t_go) * tick_ns / 1e6;

  core_t S;
  memset(&S, 0, sizeof S);
  for (int c = 0; c < W; c++) {
    core_t *k = &cores[c];
    S.opened += k->opened; S.closed += k->closed; S.deliv += k->deliv; S.ctrl += k->ctrl; S.atom += k->atom;
    S.routes += k->routes; S.late += k->late; S.premature += k->premature; S.badcount += k->badcount;
    S.underflow += k->underflow; S.notices += k->notices; S.panics += k->panics; S.bug += k->bug; S.passes += k->passes;
    for (int b = 0; b < NB; b++) { S.hclose[b] += k->hclose[b]; S.hlife[b] += k->hlife[b]; S.hdlat[b] += k->hdlat[b]; }
    if (c == 0) S.pdmin = UINT32_MAX;
    if (k->pdmin < S.pdmin) S.pdmin = k->pdmin;
    if (k->pdmax > S.pdmax) S.pdmax = k->pdmax;
  }
  int ok = !timeout && S.opened == qsum;
  if (C.scheme != S_NONE && S.closed != qsum) ok = 0;
  if (!C.fuellog && S.deliv != exp_deliv) ok = 0;
  if (S.late || S.premature || S.badcount || S.bug || S.underflow) ok = 0;

  /* Fuel accounting: posts made before each origin's notice/panic. */
  char fuelbuf[512] = "";
  if (C.fuellog) {
    plogv_t P = {0}, Nn = {0}, Pa = {0};
    for (int c = 0; c < W; c++) {
      plogv_t *v[3] = {&cores[c].plog, &cores[c].nlog, &cores[c].panlog}, *o[3] = {&P, &Nn, &Pa};
      for (int j = 0; j < 3; j++) for (size_t i = 0; i < v[j]->n; i++) plog_add(o[j], v[j]->v[i].g, v[j]->v[i].gen, v[j]->v[i].ts);
    }
    qsort(P.v, P.n, sizeof(plog_t), cmp_plog);
    qsort(Nn.v, Nn.n, sizeof(plog_t), cmp_plog);
    qsort(Pa.v, Pa.n, sizeof(plog_t), cmp_plog);
    /* pooled: overshoot = posts before notice - F */
    int64_t omin = INT64_MAX, omax = INT64_MIN; double osum = 0; uint64_t on = 0;
    for (size_t i = 0; i < Nn.n; i++) {
      int64_t o = (int64_t)posts_before(P.v, P.n, Nn.v[i].g, Nn.v[i].gen, Nn.v[i].ts) - (int64_t)C.F;
      if (o < omin) omin = o; if (o > omax) omax = o; osum += (double)o; on++;
    }
    /* split: posts before the first panic, and total posts per origin */
    uint64_t pbmin = UINT64_MAX, pbmax = 0, tmin = UINT64_MAX, tmax = 0, porig = 0;
    for (size_t i = 0; i < Pa.n; i++) {
      if (i && Pa.v[i].g == Pa.v[i - 1].g && Pa.v[i].gen == Pa.v[i - 1].gen) continue; /* first panic per origin */
      uint64_t b = posts_before(P.v, P.n, Pa.v[i].g, Pa.v[i].gen, Pa.v[i].ts);
      uint64_t tt = posts_of(P.v, P.n, Pa.v[i].g, Pa.v[i].gen);
      if (b < pbmin) pbmin = b; if (b > pbmax) pbmax = b; if (tt < tmin) tmin = tt; if (tt > tmax) tmax = tt; porig++;
    }
    snprintf(fuelbuf, sizeof fuelbuf,
             " fuel_noticed=%" PRIu64 " over_min=%" PRId64 " over_mean=%.1f over_max=%" PRId64
             " panic_origins=%" PRIu64 " panic_ops=%" PRIu64 " posts_before_panic_min=%" PRIu64 " posts_before_panic_max=%" PRIu64
             " posts_total_min=%" PRIu64 " posts_total_max=%" PRIu64 " posts_logged=%zu",
             on, on ? omin : 0, on ? osum / (double)on : 0.0, on ? omax : 0, porig, S.panics,
             porig ? pbmin : 0, pbmax, porig ? tmin : 0, tmax, P.n);
  }

  double d = (double)S.deliv;
  printf("OR scheme=%s wl=%d workers=%d spin=%" PRIu64 " N=%" PRIu64 " F=%" PRIu64 " origins=%" PRIu64
         " deliveries=%" PRIu64 " wall_ms=%.2f mdps=%.3f close_p50_ns=%.0f close_p99_ns=%.0f life_p50_ns=%.0f"
         " life_p99_ns=%.0f ctrl_per_deliv=%.3f atom_per_deliv=%.3f routes_per_deliv=%.3f ops_per_pass=%.2f"
         " late=%" PRIu64 " premature=%" PRIu64 " badcount=%" PRIu64 " bug=%" PRIu64 " underflow=%" PRIu64
         " notices=%" PRIu64 " panics=%" PRIu64 "%s dlat_p50_ns=%.0f dlat_p99_ns=%.0f pub=%s L=%" PRIu64
         " panic_depth_min=%u panic_depth_max=%u check=%d spin_per_ns=%.3f ok=%d\n",
         sname[C.scheme], C.wl, W, C.spin_ns, C.N, C.F, qsum, S.deliv, wall_ms, d / (wall_ms * 1e3),
         pct(S.hclose, 0.5) * tick_ns, pct(S.hclose, 0.99) * tick_ns, pct(S.hlife, 0.5) * tick_ns,
         pct(S.hlife, 0.99) * tick_ns, (double)S.ctrl / d, (double)S.atom / d, (double)S.routes / d,
         d / (double)S.passes, S.late, S.premature, S.badcount, S.bug, S.underflow, S.notices, S.panics, fuelbuf,
         pct(S.hdlat, 0.5) * tick_ns, pct(S.hdlat, 0.99) * tick_ns, pubname[C.pub], C.wl == 6 ? C.L : 0,
         S.panics ? S.pdmin : 0, S.pdmax, C.check, spin_per_ns, ok);
  return ok ? 0 : 1;
}
