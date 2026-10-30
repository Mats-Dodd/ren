// K1b: the keyed instance family's hit path and eviction, three ways.
// One configuration per run; one key=value line on stdout. See ../PLAN.md.
//
//   a_lru      phase 1's actors model (many-cores/k1k2/c/k1.c), plus misses.
//              at(k): lock partition, find, pin (0 -> 1 unlinks it from the
//              partition's exact LRU list), unlock; take the instance's lock
//              for one call; lock partition, unpin (1 -> 0 pushes it at the
//              most-recently-released end), unlock. Three lock round trips,
//              two on the partition's line. Cap max/parts per partition; a
//              miss evicts its partition's LRU tail.
//   b_sampled  "touch is the runtime's, choose is the library's".
//              at(k): read the shard's table with no lock (optimistic; see
//              below), pin with one atomic add on the instance's own line,
//              check the instance still holds k, take the instance's lock,
//              store a use stamp (relaxed), release, unpin. A miss takes its
//              shard's writer lock; when the family is full it samples K
//              live slots with a seeded RNG and evicts the least recently
//              stamped one that it can claim. One global cap of max.
//   c_clock    as b_sampled, but the take stores a use bit and a miss runs a
//              CLOCK hand over the slots.
//
// The read-mostly map (b, c). Each shard is an open-addressing table
// (linear probing, backward-shift delete) that only writers mutate, under
// the shard's lock. A reader probes it with acquire loads and no lock, so a
// hit writes nothing shared except the instance's own line. A reader can
// see a torn or stale table; it never trusts the slot it finds: it pins the
// slot (fetch_add on ctl), backs off if the evicting bit is set, then checks
// the slot's key is still k. An evictor claims a slot with CAS ctl 0 -> EV,
// which fails if anyone holds a pin, and clears EV with a release fetch_and
// after it has written the new key. ctl's RMWs are totally ordered, so a
// pin either blocks the claim, sees EV, or sees the new key. A reader that
// misses spuriously falls into the miss path, which rechecks under the lock.
#include "common.h"
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

#define LINE 128 // M4 cache line
#define STREAM (1u << 19)
#define HBUCKETS 65536
#define EV 0x80000000u

enum { V_A = 0, V_B = 1, V_C = 2 };
static const char *VNAMES[] = {"a_lru", "b_sampled", "c_clock"};

// ---- locks: phase 1's two kinds -------------------------------------------
typedef struct { _Atomic uint32_t v; } spin_t;
static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }
typedef union { spin_t spin; os_unfair_lock os; } lock_t;
static int lock_os; // 0 = spin (TTAS), 1 = os_unfair_lock; one predictable branch

static inline void lk(lock_t *l) {
    if (lock_os) { os_unfair_lock_lock(&l->os); return; }
    for (;;) {
        if (!atomic_exchange_explicit(&l->spin.v, 1, memory_order_acquire)) return;
        while (atomic_load_explicit(&l->spin.v, memory_order_relaxed)) cpu_relax();
    }
}
static inline int trylk(lock_t *l) {
    if (lock_os) return os_unfair_lock_trylock(&l->os);
    return !atomic_load_explicit(&l->spin.v, memory_order_relaxed) &&
           !atomic_exchange_explicit(&l->spin.v, 1, memory_order_acquire);
}
static inline void unlk(lock_t *l) {
    if (lock_os) { os_unfair_lock_unlock(&l->os); return; }
    atomic_store_explicit(&l->spin.v, 0, memory_order_release);
}

// ---- the family -------------------------------------------------------------
// One instance per cache line: its lock, pin word, key, use stamp and state.
typedef struct __attribute__((aligned(LINE))) {
    lock_t lock;            // the instance's exclusion (decision 10)
    _Atomic uint32_t ctl;   // b, c: pins | EV. a: pins, guarded by the partition lock
    _Atomic uint64_t key;
    _Atomic uint64_t stamp; // b: last-use stamp. c: use bit. a: unused
    uint64_t state;         // guarded by lock; one operation adds 1
    int32_t prev, next;     // a: LRU links, guarded by the partition lock
} inst_t;

typedef struct __attribute__((aligned(LINE))) {
    lock_t lock;            // a: the partition lock (every at). b, c: writer lock (misses)
    uint32_t count, cap;    // live keys in this shard; a: its cap
    int32_t head, tail;     // a: head = most recently released, tail = victim
    // read-only after build, on its own line so writers don't dirty it
    struct __attribute__((aligned(LINE))) {
        uint32_t mask;
        _Atomic uint64_t *keys; // 0 = empty
        _Atomic int32_t *idx;
    } t;
} shard_t;

static int variant, K = 5;
static inst_t *I;
static shard_t *S;
static uint32_t nparts, maxn;
static _Atomic uint32_t nalloc;   // slots handed out (never above max)
static _Atomic uint64_t hand;     // c: the CLOCK hand
static _Atomic uint64_t evicted_sum, evictions; // finally: adds the victim's state

#define LD(p, o) atomic_load_explicit(p, memory_order_##o)
#define ST(p, v, o) atomic_store_explicit(p, v, memory_order_##o)

static inline int32_t tab_find(shard_t *p, uint64_t k, uint64_t h) {
    uint32_t m = p->t.mask, s = (uint32_t)h & m;
    for (;;) {
        uint64_t x = LD(&p->t.keys[s], acquire);
        if (x == k) return LD(&p->t.idx[s], relaxed);
        if (!x) return -1;
        s = (s + 1) & m;
    }
}
static void tab_insert(shard_t *p, uint64_t k, uint64_t h, int32_t i) {
    uint32_t m = p->t.mask, s = (uint32_t)h & m;
    while (LD(&p->t.keys[s], relaxed)) s = (s + 1) & m;
    ST(&p->t.idx[s], i, relaxed);
    ST(&p->t.keys[s], k, release);
    if (++p->count * 4 > (m + 1) * 3) { fprintf(stderr, "FAIL: shard table over 3/4\n"); abort(); }
}
static void tab_delete(shard_t *p, uint64_t k, uint64_t h) {
    uint32_t m = p->t.mask, s = (uint32_t)h & m;
    while (LD(&p->t.keys[s], relaxed) != k) {
        if (!LD(&p->t.keys[s], relaxed)) { fprintf(stderr, "FAIL: delete of absent key\n"); abort(); }
        s = (s + 1) & m;
    }
    for (uint32_t j = s;;) {
        j = (j + 1) & m;
        uint64_t x = LD(&p->t.keys[j], relaxed);
        if (!x) break;
        uint32_t home = (uint32_t)mix64(x) & m;
        if (((j - home) & m) >= ((j - s) & m)) { // x may move back to s
            ST(&p->t.idx[s], LD(&p->t.idx[j], relaxed), relaxed);
            ST(&p->t.keys[s], x, release);
            s = j;
        }
    }
    ST(&p->t.keys[s], 0, release);
    p->count--;
}

static void lru_remove(shard_t *p, int32_t i) {
    inst_t *a = &I[i];
    if (a->prev >= 0) I[a->prev].next = a->next; else p->head = a->next;
    if (a->next >= 0) I[a->next].prev = a->prev; else p->tail = a->prev;
    a->prev = a->next = -1;
}
static void lru_push(shard_t *p, int32_t i) {
    inst_t *a = &I[i];
    a->prev = -1;
    a->next = p->head;
    if (p->head >= 0) I[p->head].prev = i; else p->tail = i;
    p->head = i;
}

static void build(uint32_t parts, uint32_t max) {
    nparts = parts;
    maxn = max;
    I = aligned_alloc(LINE, sizeof(inst_t) * max);
    memset(I, 0, sizeof(inst_t) * max);
    for (uint32_t i = 0; i < max; i++) {
        ST(&I[i].ctl, variant == V_A ? 0 : EV, relaxed); // b, c: unallocated slots are claimed
        I[i].prev = I[i].next = -1;
    }
    S = aligned_alloc(LINE, sizeof(shard_t) * parts);
    memset(S, 0, sizeof(shard_t) * parts);
    uint32_t sz = pow2_at_least((max / parts) * 2 + 256);
    for (uint32_t j = 0; j < parts; j++) {
        S[j].t.mask = sz - 1;
        S[j].t.keys = calloc(sz, sizeof(uint64_t));
        S[j].t.idx = calloc(sz, sizeof(int32_t));
        S[j].head = S[j].tail = -1;
        S[j].cap = max / parts + (j < max % parts); // a only; the caps sum to max
    }
    ST(&nalloc, 0, relaxed);
    ST(&hand, 0, relaxed);
    ST(&evicted_sum, 0, relaxed);
    ST(&evictions, 0, relaxed);
}

typedef struct __attribute__((aligned(LINE))) {
    int id;
    const uint32_t *stream;
    uint64_t ops, hits, misses, retries, rng, now, pos; // pos: stream position, kept between reps
    uint32_t *hist;
} worker_t;

// ---- a: phase 1's partition + exact LRU -----------------------------------
static inline void at_a(worker_t *w, uint64_t k) {
    uint64_t h = mix64(k);
    shard_t *p = &S[part_of(h, nparts)];
    lk(&p->lock);
    int32_t s = tab_find(p, k, h);
    inst_t *a;
    if (s >= 0) {
        w->hits++;
        a = &I[s];
        uint32_t pins = LD(&a->ctl, relaxed);
        ST(&a->ctl, pins + 1, relaxed);
        if (pins == 0) lru_remove(p, s);
    } else {
        w->misses++;
        if (p->count < p->cap) {
            s = (int32_t)atomic_fetch_add_explicit(&nalloc, 1, memory_order_relaxed);
        } else {
            s = p->tail; // the least recently released evictable instance
            if (s < 0) { fprintf(stderr, "FAIL: partition full of pinned instances\n"); abort(); }
            lru_remove(p, s);
            uint64_t vk = LD(&I[s].key, relaxed);
            tab_delete(p, vk, mix64(vk));
            lk(&I[s].lock); // finally runs on the caller's task, holding the victim
            atomic_fetch_add_explicit(&evicted_sum, I[s].state, memory_order_relaxed);
            unlk(&I[s].lock);
            atomic_fetch_add_explicit(&evictions, 1, memory_order_relaxed);
        }
        a = &I[s];
        lk(&a->lock);
        a->state = 0; // setup
        unlk(&a->lock);
        ST(&a->key, k, relaxed);
        ST(&a->ctl, 1, relaxed);
        tab_insert(p, k, h, s);
    }
    unlk(&p->lock);
    lk(&a->lock); // the body: one operation
    a->state++;
    unlk(&a->lock);
    lk(&p->lock);
    uint32_t pins = LD(&a->ctl, relaxed) - 1;
    ST(&a->ctl, pins, relaxed);
    if (pins == 0) lru_push(p, s);
    unlk(&p->lock);
}

// ---- b, c: use stamps or bits, a library's choice -------------------------
static inline uint32_t rnd_slot(worker_t *w, uint32_t n) {
    return (uint32_t)(((splitmix64(&w->rng) >> 32) * (uint64_t)n) >> 32);
}

// Returns a slot with EV set and no pins, whose key is gone from its table
// and whose finally has run. Holds shard p's lock throughout.
static int32_t evict_one(worker_t *w, shard_t *p) {
    for (;;) {
        int32_t v = -1;
        if (variant == V_B) {
            uint64_t best = UINT64_MAX;
            for (int i = 0; i < K; i++) {
                uint32_t s = rnd_slot(w, maxn);
                if (LD(&I[s].ctl, relaxed)) continue; // pinned or being evicted
                uint64_t st = LD(&I[s].stamp, relaxed);
                if (st < best) { best = st; v = (int32_t)s; }
            }
            if (v < 0) { w->retries++; continue; }
        } else {
            for (;;) {
                uint32_t s = (uint32_t)(atomic_fetch_add_explicit(&hand, 1, memory_order_relaxed) % maxn);
                if (LD(&I[s].ctl, relaxed)) continue;
                if (LD(&I[s].stamp, relaxed)) { ST(&I[s].stamp, 0, relaxed); continue; }
                v = (int32_t)s;
                break;
            }
        }
        inst_t *a = &I[v];
        uint32_t z = 0;
        if (!atomic_compare_exchange_strong_explicit(&a->ctl, &z, EV, memory_order_acq_rel, memory_order_relaxed)) {
            w->retries++;
            continue;
        }
        uint64_t vk = LD(&a->key, relaxed), vh = mix64(vk);
        shard_t *q = &S[part_of(vh, nparts)];
        if (q != p && !trylk(&q->lock)) { // never wait holding a lock: give it back, choose again
            atomic_fetch_and_explicit(&a->ctl, ~EV, memory_order_release);
            w->retries++;
            continue;
        }
        tab_delete(q, vk, vh);
        if (q != p) unlk(&q->lock);
        lk(&a->lock); // finally
        atomic_fetch_add_explicit(&evicted_sum, a->state, memory_order_relaxed);
        unlk(&a->lock);
        atomic_fetch_add_explicit(&evictions, 1, memory_order_relaxed);
        return v;
    }
}

// The miss path. Returns k's slot, pinned, or -1 to retry the lookup.
static int32_t miss_bc(worker_t *w, shard_t *p, uint64_t k, uint64_t h) {
    lk(&p->lock);
    int32_t s = tab_find(p, k, h);
    if (s >= 0) { // someone made it, or the lock-free read missed spuriously
        uint32_t c = atomic_fetch_add_explicit(&I[s].ctl, 1, memory_order_acquire);
        unlk(&p->lock);
        if (c & EV) { atomic_fetch_sub_explicit(&I[s].ctl, 1, memory_order_relaxed); return -1; }
        w->hits++;
        return s;
    }
    w->misses++;
    uint32_t n = LD(&nalloc, relaxed);
    while (n < maxn && !atomic_compare_exchange_weak_explicit(&nalloc, &n, n + 1, memory_order_relaxed,
                                                               memory_order_relaxed)) {
    }
    s = n < maxn ? (int32_t)n : evict_one(w, p); // either way we hold EV on s
    inst_t *a = &I[s];
    lk(&a->lock);
    a->state = 0; // setup
    unlk(&a->lock);
    ST(&a->stamp, variant == V_B ? w->now : 1, relaxed); // making it is a use
    ST(&a->key, k, relaxed);
    tab_insert(p, k, h, s);
    atomic_fetch_add_explicit(&a->ctl, 1, memory_order_relaxed);   // our pin
    atomic_fetch_and_explicit(&a->ctl, ~EV, memory_order_release); // publish
    unlk(&p->lock);
    return s;
}

static inline void at_bc(worker_t *w, uint64_t k) {
    uint64_t h = mix64(k);
    shard_t *p = &S[part_of(h, nparts)];
    int32_t s;
    for (;;) {
        s = tab_find(p, k, h);
        if (s < 0) {
            s = miss_bc(w, p, k, h);
            if (s >= 0) break;
            w->retries++;
            continue;
        }
        inst_t *a = &I[s];
        uint32_t c = atomic_fetch_add_explicit(&a->ctl, 1, memory_order_acquire);
        if ((c & EV) || LD(&a->key, relaxed) != k) {
            atomic_fetch_sub_explicit(&a->ctl, 1, memory_order_release);
            w->retries++;
            continue;
        }
        w->hits++;
        break;
    }
    inst_t *a = &I[s];
    lk(&a->lock); // the body: one operation, and the take records the use
    a->state++;
    ST(&a->stamp, variant == V_B ? w->now : 1, relaxed);
    unlk(&a->lock);
    atomic_fetch_sub_explicit(&a->ctl, 1, memory_order_release); // unpin
}

static inline void at(worker_t *w, uint64_t k) {
    if (variant == V_A) at_a(w, k); else at_bc(w, k);
}

// ---- driver -----------------------------------------------------------------
static _Atomic int ready, go, stop;
static int qos_mode;

static void set_qos(void) {
    if (qos_mode == 0) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    else if (qos_mode == 1) pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
}

static void *worker(void *arg) {
    worker_t *w = arg;
    set_qos();
    const uint32_t *st = w->stream;
    uint64_t pos = w->pos;
    uint64_t ops = 0;
    atomic_fetch_add(&ready, 1);
    while (!LD(&go, acquire)) cpu_relax();
    while (!LD(&stop, relaxed)) {
        uint64_t t0 = mach_absolute_time();
        w->now = t0; // the runtime's per-worker clock, refreshed every 16 calls
        at(w, st[pos++ & (STREAM - 1)]);
        uint64_t dt = mach_absolute_time() - t0;
        w->hist[dt < HBUCKETS ? dt : HBUCKETS - 1]++;
        for (int j = 1; j < 16; j++) at(w, st[pos++ & (STREAM - 1)]);
        ops += 16;
    }
    w->ops = ops;
    w->pos = pos;
    return NULL;
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int cmp_d(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static double hist_pct(const uint64_t *h, uint64_t total, double q) {
    uint64_t want = (uint64_t)(q * (double)(total - 1)), acc = 0;
    for (uint32_t i = 0; i < HBUCKETS; i++) {
        acc += h[i];
        if (acc > want) return i;
    }
    return HBUCKETS - 1;
}

#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL: " __VA_ARGS__); fprintf(stderr, "\n"); exit(1); } } while (0)

// Checks at rest (all workers joined): every operation is in some state;
// nothing is pinned or claimed; the tables and slots are a bijection; the
// cap holds; a's LRU lists hold exactly their partitions' instances.
static void verify(uint64_t total_ops) {
    uint32_t n = LD(&nalloc, relaxed);
    CHECK(n <= maxn, "nalloc %u > max %u", n, maxn);
    uint64_t st = 0, listed = 0, entries = 0;
    for (uint32_t i = 0; i < n; i++) {
        st += I[i].state;
        CHECK(LD(&I[i].ctl, relaxed) == 0, "slot %u ctl %x at rest", i, LD(&I[i].ctl, relaxed));
        uint64_t k = LD(&I[i].key, relaxed), h = mix64(k);
        CHECK(k != 0, "slot %u has no key", i);
        CHECK(tab_find(&S[part_of(h, nparts)], k, h) == (int32_t)i, "slot %u key %llu not mapped to it", i,
              (unsigned long long)k);
    }
    CHECK(st + LD(&evicted_sum, relaxed) == total_ops, "live %llu + evicted %llu != ops %llu",
          (unsigned long long)st, (unsigned long long)LD(&evicted_sum, relaxed), (unsigned long long)total_ops);
    for (uint32_t j = 0; j < nparts; j++) {
        uint32_t c = 0;
        for (uint32_t s = 0; s <= S[j].t.mask; s++) c += LD(&S[j].t.keys[s], relaxed) != 0;
        CHECK(c == S[j].count, "shard %u has %u entries, count %u", j, c, S[j].count);
        entries += c;
        if (variant == V_A) {
            CHECK(S[j].count <= S[j].cap, "partition %u over its cap", j);
            uint32_t l = 0;
            for (int32_t i = S[j].head; i >= 0; i = I[i].next) l++;
            CHECK(l == S[j].count, "partition %u lru %u != %u", j, l, S[j].count);
            listed += l;
        }
    }
    CHECK(entries == n, "table entries %llu != slots %u", (unsigned long long)entries, n);
    if (variant == V_A) CHECK(listed == n, "listed %llu != %u", (unsigned long long)listed, n);
}

int main(int argc, char **argv) {
    long workers = 4, reps = 5, ms = 200, warm_ms = -1, max = 10000, parts = 0;
    const char *uf = "0.9", *dist = "zipf99";
    variant = V_B;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--variant")) {
            variant = !strcmp(v, "a_lru") ? V_A : !strcmp(v, "b_sampled") ? V_B : !strcmp(v, "c_clock") ? V_C : -1;
            if (variant < 0) { fprintf(stderr, "unknown variant %s\n", v); return 2; }
            i++;
        } else if (!strcmp(a, "--k")) { K = atoi(v); i++; }
        else if (!strcmp(a, "--lock")) { lock_os = !strcmp(v, "os"); i++; }
        else if (!strcmp(a, "--dist")) { dist = v; i++; }
        else if (!strcmp(a, "--max")) { max = atol(v); i++; }
        else if (!strcmp(a, "--universe")) { uf = v; i++; }
        else if (!strcmp(a, "--parts")) { parts = atol(v); i++; }
        else if (!strcmp(a, "--workers")) { workers = atol(v); i++; }
        else if (!strcmp(a, "--reps")) { reps = atol(v); i++; }
        else if (!strcmp(a, "--ms")) { ms = atol(v); i++; }
        else if (!strcmp(a, "--warm-ms")) { warm_ms = atol(v); i++; }
        else if (!strcmp(a, "--qos")) { qos_mode = !strcmp(v, "p") ? 0 : !strcmp(v, "e") ? 1 : 2; i++; }
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
    }
    if (parts <= 0) parts = default_parts((uint32_t)max);
    if (warm_ms < 0) warm_ms = ms;
    int di = dist_of(dist);
    uint32_t U = (uint32_t)(atof(uf) * (double)max + 0.5);
    workload_t wl;
    workload_init(&wl, di, U, (uint32_t)max);
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double tick_ns = (double)tb.numer / tb.denom;

    // One key stream per worker, made before timing. Scan cursors start
    // spread over the loop so workers don't walk it in step.
    int nw = (int)workers;
    uint32_t **streams = malloc(sizeof(uint32_t *) * nw);
    for (int w = 0; w < nw; w++) {
        streams[w] = malloc(sizeof(uint32_t) * STREAM);
        uint64_t seed = 0x1234 + (uint64_t)w * 0x9e3779b9;
        uint32_t cur = (uint32_t)((uint64_t)wl.L * (uint64_t)w / (uint64_t)nw);
        for (uint32_t i = 0; i < STREAM; i++) streams[w][i] = workload_next(&wl, &seed, &cur);
    }
    build((uint32_t)parts, (uint32_t)max);

    worker_t *ws = aligned_alloc(LINE, sizeof(worker_t) * nw);
    memset(ws, 0, sizeof(worker_t) * nw);
    for (int w = 0; w < nw; w++) {
        ws[w].id = w;
        ws[w].stream = streams[w];
        ws[w].rng = 0x5eed0000ULL + (uint64_t)K * 0x10000 + (uint64_t)w;
        ws[w].hist = calloc(HBUCKETS, sizeof(uint32_t));
    }
    double *mops = malloc(sizeof(double) * reps), *p50 = malloc(sizeof(double) * reps),
           *p99 = malloc(sizeof(double) * reps);
    uint64_t all_ops = 0, t_hits = 0, t_misses = 0, t_ops = 0, t_retries = 0;
    uint64_t *h = calloc(HBUCKETS, sizeof(uint64_t));
    pthread_t *th = malloc(sizeof(pthread_t) * nw);
    for (long r = -1; r < reps; r++) { // rep -1 warms the family up, untimed
        long dur = r < 0 ? warm_ms : ms;
        if (r < 0 && dur == 0) continue;
        atomic_store(&ready, 0); atomic_store(&go, 0); atomic_store(&stop, 0);
        for (int w = 0; w < nw; w++) {
            ws[w].ops = 0;
            ws[w].hits = ws[w].misses = ws[w].retries = 0;
            memset(ws[w].hist, 0, HBUCKETS * sizeof(uint32_t));
            pthread_create(&th[w], NULL, worker, &ws[w]);
        }
        while (atomic_load(&ready) < nw) usleep(100);
        uint64_t t0 = now_ns();
        atomic_store_explicit(&go, 1, memory_order_release);
        usleep((useconds_t)(dur * 1000));
        atomic_store(&stop, 1);
        uint64_t t1 = now_ns();
        uint64_t total = 0, hits = 0, misses = 0, hn = 0;
        memset(h, 0, HBUCKETS * sizeof(uint64_t));
        for (int w = 0; w < nw; w++) {
            pthread_join(th[w], NULL);
            total += ws[w].ops;
            hits += ws[w].hits;
            misses += ws[w].misses;
            t_retries += r >= 0 ? ws[w].retries : 0;
            for (uint32_t b = 0; b < HBUCKETS; b++) { h[b] += ws[w].hist[b]; hn += ws[w].hist[b]; }
        }
        all_ops += total;
        CHECK(hits + misses == total, "hits %llu + misses %llu != ops %llu", (unsigned long long)hits,
              (unsigned long long)misses, (unsigned long long)total);
        verify(all_ops);
        if (r < 0) continue;
        t_hits += hits; t_misses += misses; t_ops += total;
        mops[r] = (double)total / (double)(t1 - t0) * 1e3;
        p50[r] = hist_pct(h, hn, 0.50) * tick_ns;
        p99[r] = hist_pct(h, hn, 0.99) * tick_ns;
    }
    qsort(mops, reps, sizeof(double), cmp_d);
    qsort(p50, reps, sizeof(double), cmp_d);
    qsort(p99, reps, sizeof(double), cmp_d);
    printf("k1b lang=c variant=%s k=%d lock=%s dist=%s max=%ld universe=%s parts=%ld workers=%d reps=%ld ms=%ld "
           "mops_median=%.2f mops_min=%.2f mops_max=%.2f at_p50_ns=%.0f at_p99_ns=%.0f hit_rate=%.4f "
           "hits=%llu misses=%llu evictions=%llu retries=%llu ok=1\n",
           VNAMES[variant], variant == V_B ? K : 0, lock_os ? "os" : "spin", dist, max, uf, parts, nw, reps, ms,
           mops[reps / 2], mops[0], mops[reps - 1], p50[reps / 2], p99[reps / 2],
           t_ops ? (double)t_hits / (double)t_ops : 0.0, (unsigned long long)t_hits, (unsigned long long)t_misses,
           (unsigned long long)LD(&evictions, relaxed),
           (unsigned long long)t_retries);
    return 0;
}
