// S1 (and S2): stripes against atomics, a counter's add at 1..16 workers.
// See ../README.md for what is modelled and how it maps to Ren.
//
// Variants (--variant):
//   one_lock      one handler instance shared by every worker: {lock word, count}.
//                 The lock is the Ren instance lock as decision 10 describes it
//                 uncontended (CAS on a word) and contended (spin, then yield;
//                 barging allowed: fair-not-FIFO without the starvation guard).
//   one_unfair    the same instance with macOS os_unfair_lock (a parking lock)
//                 instead: what "callers queue and park" costs when the OS parks.
//   atomic        a lockfree handler: one Atomic Int field, fetch_add seq_cst
//                 (decision 10: lockfree handler ops are sequentially consistent).
//   stripe_lock   striped(counter(), by: Worker, merge: Sum) under work_stealing:
//                 one instance per worker, each still locked (another task, or the
//                 merge, may take it), padded to --pad bytes.
//   stripe_owner  the same under per_core: a stripe per core, never locked across
//                 threads. Its owner does load+store (no RMW); the merge reads it
//                 with acquire loads, so it is race-free without a lock.
//
// --pad 0 packs stripes at their natural size (16 B locked, 8 B owner); 64 and 128
// pad each stripe to that many bytes (S2). M4's cache line is 128 B.
//
// --reader 1 adds one more thread that runs the keyless `get` (merge: Sum) in a loop
// while the workers add, timing each merge (S3-lite), and checks merges never go
// backwards.

#define _DARWIN_C_SOURCE
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
#include <os/lock.h>
#include <pthread/qos.h>
#endif

static inline uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static inline void cpu_relax(void) {
#if defined(__aarch64__)
    __asm__ volatile("yield" ::: "memory");
#else
    __asm__ volatile("pause" ::: "memory");
#endif
}

// ---- The Ren instance lock (prototype) ----
typedef _Atomic uint32_t renlock;
#define SPIN_BEFORE_YIELD 128
static inline void rl_acquire(renlock *l) {
    uint32_t z = 0;
    if (atomic_compare_exchange_weak_explicit(l, &z, 1, memory_order_acquire, memory_order_relaxed))
        return;
    for (;;) {
        unsigned n = 0;
        while (atomic_load_explicit(l, memory_order_relaxed)) {
            if (++n < SPIN_BEFORE_YIELD) cpu_relax();
            else { sched_yield(); n = 0; }
        }
        z = 0;
        if (atomic_compare_exchange_weak_explicit(l, &z, 1, memory_order_acquire, memory_order_relaxed))
            return;
    }
}
static inline void rl_release(renlock *l) { atomic_store_explicit(l, 0, memory_order_release); }

// ---- Instances ----
// A locked instance: lock word + state. State is touched only under the lock.
typedef struct { renlock lock; uint32_t _r; int64_t count; } locked_inst;   // 16 B
// An owner-only stripe: state is written by its owner, read by the merge.
typedef struct { _Atomic int64_t count; } owner_inst;                       // 8 B
typedef struct { os_unfair_lock lock; uint32_t _r; int64_t count; } unfair_inst;

enum variant { V_ONE_LOCK, V_ONE_UNFAIR, V_ATOMIC, V_STRIPE_LOCK, V_STRIPE_OWNER };
static const char *vname[] = {"one_lock", "one_unfair", "atomic", "stripe_lock", "stripe_owner"};

typedef struct {
    enum variant v;
    int workers, pad, ms, reps, reader, work;
} config;

// Shared state for one run.
static char *stripes;          // base of the stripe array (128-aligned)
static size_t stride;          // bytes per stripe
static _Alignas(128) locked_inst one_inst;
static _Alignas(128) unfair_inst unfair_one;
static _Alignas(128) _Atomic int64_t atom;
static _Alignas(128) _Atomic int go;
static _Alignas(128) _Atomic int stop;
static _Alignas(128) _Atomic int ready;

typedef struct {
    _Alignas(128) int id;
    const config *cfg;
    int64_t ops;               // adds this worker did (its own tally, for checking)
    // reader results
    uint64_t *lat; size_t nlat, caplat; int64_t last; int backwards; uint64_t rd_total_ns;
} worker_arg;

static inline locked_inst *lstripe(int i) { return (locked_inst *)(stripes + (size_t)i * stride); }
static inline owner_inst *ostripe(int i) { return (owner_inst *)(stripes + (size_t)i * stride); }

// Some caller-side work between adds (default 0): a dependent chain on a register.
static inline uint64_t busy(int k, uint64_t x) {
    for (int i = 0; i < k; i++) { x = x * 6364136223846793005ULL + 1; __asm__ volatile("" : "+r"(x)); }
    return x;
}

// The add operation, as each variant runs it.
static inline void add(const config *c, int me) {
    switch (c->v) {
    case V_ONE_LOCK:
        rl_acquire(&one_inst.lock); one_inst.count += 1; rl_release(&one_inst.lock); break;
    case V_ONE_UNFAIR:
        os_unfair_lock_lock(&unfair_one.lock); unfair_one.count += 1; os_unfair_lock_unlock(&unfair_one.lock); break;
    case V_ATOMIC:
        atomic_fetch_add_explicit(&atom, 1, memory_order_seq_cst); break;
    case V_STRIPE_LOCK: {
        locked_inst *s = lstripe(me);
        rl_acquire(&s->lock); s->count += 1; rl_release(&s->lock); break;
    }
    case V_STRIPE_OWNER: {
        owner_inst *s = ostripe(me);
        int64_t x = atomic_load_explicit(&s->count, memory_order_relaxed);
        atomic_store_explicit(&s->count, x + 1, memory_order_relaxed);
        break;
    }
    }
}

// The keyless `get`, merge: Sum over stripes in stripe order.
static inline int64_t merge(const config *c) {
    int64_t sum = 0;
    switch (c->v) {
    case V_ONE_LOCK:
        rl_acquire(&one_inst.lock); sum = one_inst.count; rl_release(&one_inst.lock); break;
    case V_ONE_UNFAIR:
        os_unfair_lock_lock(&unfair_one.lock); sum = unfair_one.count; os_unfair_lock_unlock(&unfair_one.lock); break;
    case V_ATOMIC:
        sum = atomic_load_explicit(&atom, memory_order_seq_cst); break;
    case V_STRIPE_LOCK:
        for (int i = 0; i < c->workers; i++) {
            locked_inst *s = lstripe(i);
            rl_acquire(&s->lock); sum += s->count; rl_release(&s->lock);
        }
        break;
    case V_STRIPE_OWNER:
        for (int i = 0; i < c->workers; i++) sum += atomic_load_explicit(&ostripe(i)->count, memory_order_acquire);
        break;
    }
    return sum;
}

static void set_qos(void) {
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
}

static void *worker(void *p) {
    worker_arg *a = p;
    const config *c = a->cfg;
    set_qos();
    atomic_fetch_add(&ready, 1);
    while (!atomic_load_explicit(&go, memory_order_acquire)) cpu_relax();
    int64_t ops = 0; uint64_t x = (uint64_t)a->id;
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        for (int k = 0; k < 256; k++) { add(c, a->id); x = busy(c->work, x); }
        ops += 256;
    }
    __asm__ volatile("" ::"r"(x));
    a->ops = ops;
    return NULL;
}

static void *reader(void *p) {
    worker_arg *a = p;
    const config *c = a->cfg;
    set_qos();
    atomic_fetch_add(&ready, 1);
    while (!atomic_load_explicit(&go, memory_order_acquire)) cpu_relax();
    int64_t last = 0;
    uint64_t t_start = now_ns();
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        uint64_t t0 = now_ns();
        int64_t v = merge(c);
        uint64_t t1 = now_ns();
        if (v < last) a->backwards++;
        last = v;
        if (a->nlat == a->caplat) { a->caplat = a->caplat ? a->caplat * 2 : 1 << 16; a->lat = realloc(a->lat, a->caplat * sizeof(uint64_t)); }
        a->lat[a->nlat++] = t1 - t0;
    }
    a->rd_total_ns = now_ns() - t_start;
    a->last = last;
    return NULL;
}

static int cmp_u64(const void *x, const void *y) { uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y; return a < b ? -1 : a > b; }
static int cmp_d(const void *x, const void *y) { double a = *(const double *)x, b = *(const double *)y; return a < b ? -1 : a > b; }

typedef struct { double mops; double rp50, rp99, rmean; int ok; } rep_result;

static rep_result run_once(const config *c) {
    rep_result r = {0};
    size_t natural = (c->v == V_STRIPE_OWNER) ? sizeof(owner_inst) : sizeof(locked_inst);
    stride = c->pad > (int)natural ? (size_t)c->pad : natural;
    stripes = aligned_alloc(128, ((stride * c->workers + 127) / 128) * 128 + 128);
    memset(stripes, 0, stride * c->workers);
    memset(&one_inst, 0, sizeof one_inst);
    unfair_one.lock = OS_UNFAIR_LOCK_INIT; unfair_one.count = 0;
    atomic_store(&atom, 0); atomic_store(&go, 0); atomic_store(&stop, 0); atomic_store(&ready, 0);

    int nthreads = c->workers + (c->reader ? 1 : 0);
    pthread_t th[64]; worker_arg args[64];
    memset(args, 0, sizeof args);
    for (int i = 0; i < nthreads; i++) {
        args[i].id = i; args[i].cfg = c;
        pthread_create(&th[i], NULL, i < c->workers ? worker : reader, &args[i]);
    }
    while (atomic_load(&ready) < nthreads) cpu_relax();
    uint64_t t0 = now_ns();
    atomic_store_explicit(&go, 1, memory_order_release);
    struct timespec ts = {c->ms / 1000, (long)(c->ms % 1000) * 1000000L};
    nanosleep(&ts, NULL);
    atomic_store_explicit(&stop, 1, memory_order_relaxed);
    for (int i = 0; i < nthreads; i++) pthread_join(th[i], NULL);
    uint64_t t1 = now_ns();

    int64_t sum_ops = 0;
    for (int i = 0; i < c->workers; i++) sum_ops += args[i].ops;
    int64_t total = merge(c);
    r.ok = (total == sum_ops);
    if (c->v == V_STRIPE_LOCK || c->v == V_STRIPE_OWNER) {
        // each stripe holds exactly its owner's adds (split law: by: Worker)
        for (int i = 0; i < c->workers; i++) {
            int64_t si = c->v == V_STRIPE_LOCK ? lstripe(i)->count : atomic_load(&ostripe(i)->count);
            if (si != args[i].ops) r.ok = 0;
        }
    }
    if (!r.ok) fprintf(stderr, "CHECK FAILED: variant=%s workers=%d merged=%lld adds=%lld\n", vname[c->v], c->workers, (long long)total, (long long)sum_ops);
    r.mops = (double)sum_ops / (double)(t1 - t0) * 1e3;
    if (c->reader) {
        worker_arg *a = &args[c->workers];
        if (a->backwards) { r.ok = 0; fprintf(stderr, "CHECK FAILED: merge went backwards %d times\n", a->backwards); }
        if (a->last > total) { r.ok = 0; fprintf(stderr, "CHECK FAILED: merge saw more than the final total\n"); }
        if (a->nlat) {
            qsort(a->lat, a->nlat, sizeof(uint64_t), cmp_u64);
            r.rp50 = (double)a->lat[a->nlat / 2];
            r.rp99 = (double)a->lat[(size_t)(a->nlat * 0.99)];
            r.rmean = (double)a->rd_total_ns / (double)a->nlat;
        }
        free(a->lat);
    }
    free(stripes);
    return r;
}

static void usage(void) {
    fprintf(stderr, "usage: s1 --variant one_lock|one_unfair|atomic|stripe_lock|stripe_owner --workers N "
                    "[--pad 0|64|128] [--ms 200] [--reps 5] [--reader 0|1] [--work 0]\n");
    exit(2);
}

int main(int argc, char **argv) {
    config c = {.v = V_ATOMIC, .workers = 1, .pad = 128, .ms = 200, .reps = 5, .reader = 0, .work = 0};
    int have_v = 0;
    for (int i = 1; i < argc; i++) {
        if (i + 1 >= argc) usage();
        const char *k = argv[i], *v = argv[++i];
        if (!strcmp(k, "--variant")) {
            have_v = 0;
            for (int j = 0; j < 5; j++) if (!strcmp(v, vname[j])) { c.v = j; have_v = 1; }
            if (!have_v) usage();
        } else if (!strcmp(k, "--workers")) c.workers = atoi(v);
        else if (!strcmp(k, "--pad")) c.pad = atoi(v);
        else if (!strcmp(k, "--ms")) c.ms = atoi(v);
        else if (!strcmp(k, "--reps")) c.reps = atoi(v);
        else if (!strcmp(k, "--reader")) c.reader = atoi(v);
        else if (!strcmp(k, "--work")) c.work = atoi(v);
        else usage();
    }
    if (!have_v || c.workers < 1 || c.workers > 63 || c.reps < 1) usage();
    set_qos();

    double mops[256], p50[256], p99[256], mean[256];
    int ok = 1, n = c.reps > 256 ? 256 : c.reps;
    for (int i = 0; i < n; i++) {
        rep_result r = run_once(&c);
        mops[i] = r.mops; p50[i] = r.rp50; p99[i] = r.rp99; mean[i] = r.rmean; ok &= r.ok;
    }
    qsort(mops, n, sizeof(double), cmp_d);
    printf("exp=s1 lang=c variant=%s pad=%d workers=%d reader=%d work=%d reps=%d ms=%d "
           "mops_median=%.2f mops_min=%.2f mops_max=%.2f",
           vname[c.v], (c.v == V_STRIPE_LOCK || c.v == V_STRIPE_OWNER) ? c.pad : 0, c.workers, c.reader, c.work, n, c.ms,
           mops[n / 2], mops[0], mops[n - 1]);
    if (c.reader) {
        qsort(p50, n, sizeof(double), cmp_d); qsort(p99, n, sizeof(double), cmp_d); qsort(mean, n, sizeof(double), cmp_d);
        printf(" read_p50_ns=%.0f read_p99_ns=%.0f read_mean_ns=%.1f", p50[n / 2], p99[n / 2], mean[n / 2]);
    }
    printf(" ok=%d\n", ok);
    return ok ? 0 : 1;
}
