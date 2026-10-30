// K2: what a cap per partition (max / parts) wastes against one global cap
// (decision 18). One trace of key accesses runs through one exact LRU with
// cap max, and through `parts` exact LRUs, each with cap max/parts (the
// remainder spread one each over the first partitions, so total capacity is
// max exactly). Single-threaded and deterministic: the Rust twin must print
// the same counts.
#include "common.h"

typedef struct {
    uint32_t cap, count, mask;
    uint64_t *keys; // table: key per slot, 0 = empty
    int32_t *slot;  // table: node per slot
    uint64_t *nkey; // node: key
    int32_t *prev, *next;
    int32_t head, tail; // head = most recent
    uint64_t misses, evictions;
} lru_t;

static void lru_init(lru_t *l, uint32_t cap) {
    memset(l, 0, sizeof *l);
    l->cap = cap;
    uint32_t sz = pow2_at_least(cap * 2);
    l->mask = sz - 1;
    l->keys = calloc(sz, sizeof(uint64_t));
    l->slot = calloc(sz, sizeof(int32_t));
    l->nkey = calloc(cap ? cap : 1, sizeof(uint64_t));
    l->prev = calloc(cap ? cap : 1, sizeof(int32_t));
    l->next = calloc(cap ? cap : 1, sizeof(int32_t));
    l->head = l->tail = -1;
}
static void lru_free(lru_t *l) { free(l->keys); free(l->slot); free(l->nkey); free(l->prev); free(l->next); }

static void unlink_node(lru_t *l, int32_t i) {
    if (l->prev[i] >= 0) l->next[l->prev[i]] = l->next[i]; else l->head = l->next[i];
    if (l->next[i] >= 0) l->prev[l->next[i]] = l->prev[i]; else l->tail = l->prev[i];
}
static void push_front(lru_t *l, int32_t i) {
    l->prev[i] = -1;
    l->next[i] = l->head;
    if (l->head >= 0) l->prev[l->head] = i; else l->tail = i;
    l->head = i;
}

// Backward-shift deletion for linear probing (no tombstones).
static void table_delete(lru_t *l, uint64_t k) {
    uint32_t i = (uint32_t)mix64(k) & l->mask;
    while (l->keys[i] != k) i = (i + 1) & l->mask;
    uint32_t j = i;
    for (;;) {
        j = (j + 1) & l->mask;
        if (!l->keys[j]) break;
        uint32_t ideal = (uint32_t)mix64(l->keys[j]) & l->mask;
        // move j into hole i unless ideal lies cyclically in (i, j]
        int in = (i <= j) ? (ideal > i && ideal <= j) : (ideal > i || ideal <= j);
        if (!in) {
            l->keys[i] = l->keys[j];
            l->slot[i] = l->slot[j];
            i = j;
        }
    }
    l->keys[i] = 0;
}

// Returns 1 on a hit.
static int lru_access(lru_t *l, uint64_t k, uint64_t h) {
    uint32_t s = (uint32_t)h & l->mask;
    while (l->keys[s]) {
        if (l->keys[s] == k) {
            int32_t i = l->slot[s];
            if (l->head != i) { unlink_node(l, i); push_front(l, i); }
            return 1;
        }
        s = (s + 1) & l->mask;
    }
    l->misses++;
    if (l->cap == 0) return 0;
    int32_t i;
    if (l->count == l->cap) {
        i = l->tail;
        unlink_node(l, i);
        table_delete(l, l->nkey[i]);
        l->evictions++;
        // the hole may have moved our probe position; re-probe
        s = (uint32_t)h & l->mask;
        while (l->keys[s]) s = (s + 1) & l->mask;
    } else {
        i = (int32_t)l->count++;
    }
    l->nkey[i] = k;
    l->keys[s] = k;
    l->slot[s] = i;
    push_front(l, i);
    return 0;
}

static int check(lru_t *l) {
    uint32_t n = 0;
    for (int32_t i = l->head; i >= 0; i = l->next[i]) n++;
    return n == l->count && l->count <= l->cap;
}

int main(int argc, char **argv) {
    long maxes[8], partsl[8], nm = 0, np = 0;
    double factors[16];
    int nf = 0;
    const char *dists = "uniform,zipf";
    double zs = 1.1, warm_x = 12, meas_x = 10;
    nm = parse_list("1000,10000,100000", maxes, 8);
    np = parse_list("8,64", partsl, 8);
    double fdef[] = {1.0, 1.1, 1.5, 2, 4, 10};
    nf = 6;
    memcpy(factors, fdef, sizeof fdef);
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--max")) { nm = parse_list(v, maxes, 8); i++; }
        else if (!strcmp(a, "--parts")) { np = parse_list(v, partsl, 8); i++; }
        else if (!strcmp(a, "--dist")) { dists = v; i++; }
        else if (!strcmp(a, "--zipf-s")) { zs = atof(v); i++; }
        else if (!strcmp(a, "--warm")) { warm_x = atof(v); i++; }
        else if (!strcmp(a, "--measure")) { meas_x = atof(v); i++; }
        else if (!strcmp(a, "--factors")) {
            nf = 0;
            const char *s = v;
            while (*s && nf < 16) { factors[nf++] = strtod(s, (char **)&s); if (*s == ',') s++; }
            i++;
        } else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
    }
    for (int di = 0; di < 2; di++) {
        const char *dname = di == 0 ? "uniform" : "zipf";
        if (!strstr(dists, dname)) continue;
        for (long mi = 0; mi < nm; mi++) {
            uint32_t max = (uint32_t)maxes[mi];
            for (int fi = 0; fi < nf; fi++) {
                uint32_t universe = (uint32_t)(max * factors[fi] + 0.5);
                zipf_t z = {0};
                if (di == 1) zipf_init(&z, universe, zs);
                uint64_t warm = (uint64_t)(warm_x * universe), meas = (uint64_t)(meas_x * universe);
                if (meas < 20ull * max) meas = 20ull * max;
                // global plus one partitioned LRU set per parts value, one pass
                lru_t g;
                lru_init(&g, max);
                lru_t *ps[8];
                for (long pi = 0; pi < np; pi++) {
                    uint32_t n = (uint32_t)partsl[pi];
                    ps[pi] = malloc(sizeof(lru_t) * n);
                    for (uint32_t j = 0; j < n; j++) lru_init(&ps[pi][j], max / n + (j < max % n ? 1 : 0));
                }
                uint64_t seed = 0xC0FFEEull ^ ((uint64_t)max << 20) ^ universe;
                uint64_t gm0 = 0, ge0 = 0, pm0[8] = {0}, pe0[8] = {0};
                for (uint64_t t = 0; t < warm + meas; t++) {
                    if (t == warm) {
                        gm0 = g.misses; ge0 = g.evictions;
                        for (long pi = 0; pi < np; pi++) {
                            pm0[pi] = pe0[pi] = 0;
                            for (uint32_t j = 0; j < partsl[pi]; j++) { pm0[pi] += ps[pi][j].misses; pe0[pi] += ps[pi][j].evictions; }
                        }
                    }
                    uint64_t x = splitmix64(&seed);
                    uint64_t k = di == 0 ? uniform_key(x, universe) : zipf_key(&z, x);
                    uint64_t h = mix64(k);
                    int gh = lru_access(&g, k, h);
                    for (long pi = 0; pi < np; pi++) {
                        int ph = lru_access(&ps[pi][part_of(h, (uint32_t)partsl[pi])], k, h);
                        // inclusion: a partitioned hit with a global miss can happen
                        // (LRU isn't a stack algorithm across different partitionings),
                        // so neither is asserted; both are counted below.
                        (void)ph;
                    }
                    (void)gh;
                }
                if (!check(&g)) { fprintf(stderr, "FAIL: global lru inconsistent\n"); return 1; }
                uint64_t gm = g.misses - gm0, ge = g.evictions - ge0;
                for (long pi = 0; pi < np; pi++) {
                    uint32_t n = (uint32_t)partsl[pi];
                    uint64_t pm = 0, pe = 0, resident = 0, minc = UINT64_MAX, maxc = 0;
                    for (uint32_t j = 0; j < n; j++) {
                        if (!check(&ps[pi][j])) { fprintf(stderr, "FAIL: part lru inconsistent\n"); return 1; }
                        pm += ps[pi][j].misses; pe += ps[pi][j].evictions; resident += ps[pi][j].count;
                        if (ps[pi][j].cap < minc) minc = ps[pi][j].cap;
                        if (ps[pi][j].cap > maxc) maxc = ps[pi][j].cap;
                    }
                    pm -= pm0[pi]; pe -= pe0[pi];
                    double rel = gm ? 100.0 * ((double)pm - (double)gm) / (double)gm : (pm ? INFINITY : 0);
                    double abs_ = 100.0 * ((double)pm - (double)gm) / (double)meas;
                    printf("k2 lang=c dist=%s max=%u parts=%u cap_per_part=%llu-%llu universe=%u accesses=%llu "
                           "global_misses=%llu part_misses=%llu global_evictions=%llu part_evictions=%llu "
                           "global_resident=%u part_resident=%llu global_miss_pct=%.4f part_miss_pct=%.4f "
                           "extra_miss_pct_of_global=%.3f extra_miss_pct_of_accesses=%.4f\n",
                           dname, max, n, (unsigned long long)minc, (unsigned long long)maxc, universe,
                           (unsigned long long)meas, (unsigned long long)gm, (unsigned long long)pm,
                           (unsigned long long)ge, (unsigned long long)pe, g.count, (unsigned long long)resident,
                           100.0 * gm / meas, 100.0 * pm / meas, rel, abs_);
                    for (uint32_t j = 0; j < n; j++) lru_free(&ps[pi][j]);
                    free(ps[pi]);
                }
                fflush(stdout);
                lru_free(&g);
                if (z.cdf) free(z.cdf);
            }
        }
    }
    return 0;
}
