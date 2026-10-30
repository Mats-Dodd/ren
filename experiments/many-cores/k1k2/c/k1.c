// K1: the cost of `Docs.at(k) fn() => Doc.op()` on a hit, and how it scales
// with partitions (decision 18). See ../README.md for the model.
//
//   at(k):  lock partition(k); look k up in the partition's map; pin the
//           actor (pins 0 -> 1 takes it off the partition's LRU list, since
//           a pinned actor isn't evictable); unlock.
//   body:   one operation: take the actor's instance for one call
//           (decision 10), state += 1, let it go.
//   exit:   lock partition; unpin (pins 1 -> 0 pushes it at the LRU list's
//           most-recently-released end, exact LRU); unlock.
#include "common.h"
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

#define LINE 128 // M4 cache line
#define STREAM (1u << 16)
#define HBUCKETS 65536

typedef struct {
    _Atomic uint32_t v;
} spin_t;

static inline void cpu_relax(void) { __asm__ volatile("isb" ::: "memory"); }

static inline void spin_lock(spin_t *l) {
    for (;;) {
        if (!atomic_exchange_explicit(&l->v, 1, memory_order_acquire)) return;
        while (atomic_load_explicit(&l->v, memory_order_relaxed)) cpu_relax();
    }
}
static inline void spin_unlock(spin_t *l) { atomic_store_explicit(&l->v, 0, memory_order_release); }

typedef union {
    spin_t spin;
    os_unfair_lock os;
} lock_t;

typedef struct __attribute__((aligned(LINE))) {
    lock_t lock;     // the instance's exclusion (decision 10)
    uint64_t state;  // the actor's state, guarded by lock
    uint64_t key;
    uint32_t pins;   // guarded by the partition's lock
    int32_t prev, next; // LRU links, guarded by the partition's lock
} actor_t;

typedef struct __attribute__((aligned(LINE))) {
    lock_t lock;
    uint32_t mask;
    uint64_t *keys; // open addressing, linear probing; 0 = empty
    int32_t *idx;   // actor index per slot
    int32_t head, tail; // head = most recently released, tail = victim
    uint32_t count;
} part_t;

static actor_t *A;
static part_t *P;
static uint32_t nparts, nkeys;

static void lru_remove(part_t *p, int32_t i) {
    actor_t *a = &A[i];
    if (a->prev >= 0) A[a->prev].next = a->next; else p->head = a->next;
    if (a->next >= 0) A[a->next].prev = a->prev; else p->tail = a->prev;
    a->prev = a->next = -1;
}
static void lru_push(part_t *p, int32_t i) {
    actor_t *a = &A[i];
    a->prev = -1;
    a->next = p->head;
    if (p->head >= 0) A[p->head].prev = i; else p->tail = i;
    p->head = i;
}

static void build(uint32_t parts, uint32_t keys) {
    nparts = parts;
    nkeys = keys;
    A = aligned_alloc(LINE, sizeof(actor_t) * keys);
    memset(A, 0, sizeof(actor_t) * keys);
    P = aligned_alloc(LINE, sizeof(part_t) * parts);
    memset(P, 0, sizeof(part_t) * parts);
    uint32_t per = keys / parts + 1;
    for (uint32_t j = 0; j < parts; j++) {
        uint32_t sz = pow2_at_least(per * 2 + 64);
        P[j].mask = sz - 1;
        P[j].keys = calloc(sz, sizeof(uint64_t));
        P[j].idx = calloc(sz, sizeof(int32_t));
        P[j].head = P[j].tail = -1;
    }
    for (uint32_t i = 0; i < keys; i++) {
        uint64_t k = i + 1, h = mix64(k);
        part_t *p = &P[part_of(h, parts)];
        uint32_t s = (uint32_t)h & p->mask;
        while (p->keys[s]) s = (s + 1) & p->mask;
        p->keys[s] = k;
        p->idx[s] = (int32_t)i;
        A[i].key = k;
        A[i].prev = A[i].next = -1;
        lru_push(p, (int32_t)i);
        p->count++;
    }
}

static void teardown(void) {
    for (uint32_t j = 0; j < nparts; j++) { free(P[j].keys); free(P[j].idx); }
    free(P);
    free(A);
}

typedef struct __attribute__((aligned(LINE))) {
    int id;
    const uint32_t *stream;
    uint64_t ops;
    uint32_t *hist; // latency histogram in mach ticks, one at() per bucket hit
} worker_t;

static _Atomic int ready, go, stop;
static int qos_mode; // 0 = user-interactive (P cores), 1 = background (E), 2 = none

static void set_qos(void) {
    if (qos_mode == 0) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    else if (qos_mode == 1) pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
}

#define DEFINE_AT(NAME, LOCK, UNLOCK)                                          \
    static inline void NAME(uint64_t k) {                                      \
        uint64_t h = mix64(k);                                                 \
        part_t *p = &P[part_of(h, nparts)];                                    \
        LOCK(&p->lock);                                                        \
        uint32_t s = (uint32_t)h & p->mask;                                    \
        while (p->keys[s] != k) {                                              \
            if (!p->keys[s]) abort(); /* a miss: K1 measures hits only */      \
            s = (s + 1) & p->mask;                                             \
        }                                                                      \
        int32_t i = p->idx[s];                                                 \
        actor_t *a = &A[i];                                                    \
        if (a->pins++ == 0) lru_remove(p, i);                                  \
        UNLOCK(&p->lock);                                                      \
        LOCK(&a->lock);                                                        \
        a->state++;                                                            \
        UNLOCK(&a->lock);                                                      \
        LOCK(&p->lock);                                                        \
        if (--a->pins == 0) lru_push(p, i);                                    \
        UNLOCK(&p->lock);                                                      \
    }                                                                          \
    static void *NAME##_worker(void *arg) {                                    \
        worker_t *w = arg;                                                     \
        set_qos();                                                             \
        const uint32_t *st = w->stream;                                        \
        uint32_t pos = 0;                                                      \
        uint64_t ops = 0;                                                      \
        atomic_fetch_add(&ready, 1);                                           \
        while (!atomic_load_explicit(&go, memory_order_acquire)) cpu_relax();  \
        while (!atomic_load_explicit(&stop, memory_order_relaxed)) {           \
            uint64_t t0 = mach_absolute_time();                                \
            NAME(st[pos++ & (STREAM - 1)]);                                    \
            uint64_t dt = mach_absolute_time() - t0;                           \
            w->hist[dt < HBUCKETS ? dt : HBUCKETS - 1]++;                      \
            for (int j = 1; j < 16; j++) NAME(st[pos++ & (STREAM - 1)]);       \
            ops += 16;                                                         \
        }                                                                      \
        w->ops = ops;                                                          \
        return NULL;                                                           \
    }

#define SPIN_LOCK(l) spin_lock(&(l)->spin)
#define SPIN_UNLOCK(l) spin_unlock(&(l)->spin)
#define OS_LOCK(l) os_unfair_lock_lock(&(l)->os)
#define OS_UNLOCK(l) os_unfair_lock_unlock(&(l)->os)
DEFINE_AT(at_spin, SPIN_LOCK, SPIN_UNLOCK)
DEFINE_AT(at_os, OS_LOCK, OS_UNLOCK)

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

// Checks after a rep: every at() did one operation; nothing is left pinned;
// each partition's LRU list holds exactly its actors.
static void verify(uint64_t total_ops, uint64_t state_before) {
    uint64_t st = 0;
    for (uint32_t i = 0; i < nkeys; i++) {
        st += A[i].state;
        if (A[i].pins) { fprintf(stderr, "FAIL: actor %u still pinned\n", i); exit(1); }
    }
    if (st - state_before != total_ops) {
        fprintf(stderr, "FAIL: ops %llu != state delta %llu\n", (unsigned long long)total_ops,
                (unsigned long long)(st - state_before));
        exit(1);
    }
    uint64_t listed = 0;
    for (uint32_t j = 0; j < nparts; j++) {
        uint32_t n = 0;
        for (int32_t i = P[j].head; i >= 0; i = A[i].next) n++;
        if (n != P[j].count) { fprintf(stderr, "FAIL: part %u lru %u != %u\n", j, n, P[j].count); exit(1); }
        listed += n;
    }
    if (listed != nkeys) { fprintf(stderr, "FAIL: listed %llu\n", (unsigned long long)listed); exit(1); }
}

int main(int argc, char **argv) {
    long workers[32], parts[8], keys = 10000, reps = 5, ms = 200;
    int nw = parse_list("1,2,4,8,12,16", workers, 32), np = parse_list("1,8,64", parts, 8);
    const char *dists = "uniform,zipf", *locks = "spin,os";
    double zs = 1.1;
    qos_mode = 0;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--workers")) { nw = parse_list(v, workers, 32); i++; }
        else if (!strcmp(a, "--parts")) { np = parse_list(v, parts, 8); i++; }
        else if (!strcmp(a, "--keys")) { keys = atol(v); i++; }
        else if (!strcmp(a, "--reps")) { reps = atol(v); i++; }
        else if (!strcmp(a, "--ms")) { ms = atol(v); i++; }
        else if (!strcmp(a, "--dist")) { dists = v; i++; }
        else if (!strcmp(a, "--lock")) { locks = v; i++; }
        else if (!strcmp(a, "--zipf-s")) { zs = atof(v); i++; }
        else if (!strcmp(a, "--qos")) { qos_mode = !strcmp(v, "p") ? 0 : !strcmp(v, "e") ? 1 : 2; i++; }
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
    }
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double tick_ns = (double)tb.numer / tb.denom;
    zipf_t z;
    zipf_init(&z, (uint32_t)keys, zs);

    long maxw = 0;
    for (int i = 0; i < nw; i++) if (workers[i] > maxw) maxw = workers[i];
    for (int di = 0; di < 2; di++) {
        const char *dname = di == 0 ? "uniform" : "zipf";
        if (!strstr(dists, dname)) continue;
        // One key stream per worker, made before timing.
        uint32_t **streams = malloc(sizeof(uint32_t *) * maxw);
        for (long w = 0; w < maxw; w++) {
            streams[w] = malloc(sizeof(uint32_t) * STREAM);
            uint64_t seed = 0x1234 + (uint64_t)w * 0x9e3779b9;
            for (uint32_t i = 0; i < STREAM; i++) {
                uint64_t x = splitmix64(&seed);
                streams[w][i] = (uint32_t)(di == 0 ? uniform_key(x, (uint32_t)keys) : zipf_key(&z, x));
            }
        }
        for (int li = 0; li < 2; li++) {
            const char *lname = li == 0 ? "spin" : "os";
            if (!strstr(locks, lname)) continue;
            for (int pi = 0; pi < np; pi++) {
                build((uint32_t)parts[pi], (uint32_t)keys);
                for (int wi = 0; wi < nw; wi++) {
                    int nwk = (int)workers[wi];
                    double *mops = malloc(sizeof(double) * reps), *p50 = malloc(sizeof(double) * reps),
                           *p99 = malloc(sizeof(double) * reps);
                    for (long r = 0; r < reps; r++) {
                        uint64_t before = 0;
                        for (uint32_t i = 0; i < nkeys; i++) before += A[i].state;
                        worker_t *ws = aligned_alloc(LINE, sizeof(worker_t) * nwk);
                        pthread_t *th = malloc(sizeof(pthread_t) * nwk);
                        atomic_store(&ready, 0); atomic_store(&go, 0); atomic_store(&stop, 0);
                        for (int w = 0; w < nwk; w++) {
                            ws[w] = (worker_t){.id = w, .stream = streams[w], .ops = 0,
                                               .hist = calloc(HBUCKETS, sizeof(uint32_t))};
                            pthread_create(&th[w], NULL, li == 0 ? at_spin_worker : at_os_worker, &ws[w]);
                        }
                        while (atomic_load(&ready) < nwk) usleep(100);
                        uint64_t t0 = now_ns();
                        atomic_store_explicit(&go, 1, memory_order_release);
                        usleep((useconds_t)(ms * 1000));
                        atomic_store(&stop, 1);
                        uint64_t t1 = now_ns();
                        uint64_t total = 0, *h = calloc(HBUCKETS, sizeof(uint64_t)), hn = 0;
                        for (int w = 0; w < nwk; w++) {
                            pthread_join(th[w], NULL);
                            total += ws[w].ops;
                            for (uint32_t b = 0; b < HBUCKETS; b++) { h[b] += ws[w].hist[b]; hn += ws[w].hist[b]; }
                            free(ws[w].hist);
                        }
                        verify(total, before);
                        mops[r] = (double)total / (double)(t1 - t0) * 1e3;
                        p50[r] = hist_pct(h, hn, 0.50) * tick_ns;
                        p99[r] = hist_pct(h, hn, 0.99) * tick_ns;
                        free(h); free(ws); free(th);
                    }
                    qsort(mops, reps, sizeof(double), cmp_d);
                    qsort(p50, reps, sizeof(double), cmp_d);
                    qsort(p99, reps, sizeof(double), cmp_d);
                    printf("k1 lang=c lock=%s dist=%s parts=%ld workers=%d keys=%ld reps=%ld ms=%ld "
                           "mops_median=%.2f mops_min=%.2f mops_max=%.2f at_p50_ns=%.0f at_p99_ns=%.0f\n",
                           lname, dname, parts[pi], nwk, keys, reps, ms, mops[reps / 2], mops[0],
                           mops[reps - 1], p50[reps / 2], p99[reps / 2]);
                    fflush(stdout);
                    free(mops); free(p50); free(p99);
                }
                teardown();
            }
        }
        for (long w = 0; w < maxw; w++) free(streams[w]);
        free(streams);
    }
    return 0;
}
