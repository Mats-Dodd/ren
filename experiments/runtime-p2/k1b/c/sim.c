// K1b's hit-rate simulator: one recorded trace, every eviction policy,
// single-threaded and deterministic. rust/src/sim.rs mirrors it bit for
// bit, and measure.sh fails if their lines differ. See ../PLAN.md.
//
//   lru      exact LRU with one global cap of max (the reference)
//   plru     variant a's policy: parts partitions, cap max/parts each
//            (remainder one each over the first), exact LRU in each
//   s3 s5 s10  variant b's policy: on a full family, sample k live slots
//            (with replacement, seeded splitmix64) and evict the one with
//            the oldest use stamp; the stamp is the access's index
//   clock    variant c's policy: a hand over the slots; a set use bit is
//            cleared and passed, the first clear bit is the victim
//
// Every policy keeps its keys in the same structure the threaded harness
// uses: a slab of max slots and a table split into `parts` shards by the
// key's hash. The victim choice of s* and clock reads only the slab, so the
// shard count can't change it: vh_* (a fingerprint of the victim sequence)
// must be equal at parts 1, 8 and 64. plru's is expected to change.
#include "common.h"

enum { P_LRU, P_PLRU, P_S3, P_S5, P_S10, P_CLOCK, NPOL };
static const char *PNAMES[] = {"lru", "plru", "s3", "s5", "s10", "clock"};

typedef struct {
    uint32_t mask, count, cap;
    uint64_t *keys;
    int32_t *idx;
    int32_t head, tail; // LRU list (lru uses shard 0's list for the whole family)
} shard_t;

typedef struct {
    int pol, k;
    uint32_t max, parts, nalloc;
    uint64_t *key, *stamp; // per slot; stamp is the access index, or the use bit
    int32_t *prev, *next;
    shard_t *S;
    uint64_t rng, hand, evictions, vh;
} cache_t;

static int32_t find(shard_t *p, uint64_t k, uint64_t h) {
    uint32_t s = (uint32_t)h & p->mask;
    for (;;) {
        if (p->keys[s] == k) return p->idx[s];
        if (!p->keys[s]) return -1;
        s = (s + 1) & p->mask;
    }
}
static void insert(shard_t *p, uint64_t k, uint64_t h, int32_t i) {
    uint32_t s = (uint32_t)h & p->mask;
    while (p->keys[s]) s = (s + 1) & p->mask;
    p->keys[s] = k;
    p->idx[s] = i;
    if (++p->count * 4 > (p->mask + 1) * 3) { fprintf(stderr, "FAIL: shard over 3/4\n"); exit(1); }
}
static void delete(shard_t *p, uint64_t k, uint64_t h) {
    uint32_t m = p->mask, s = (uint32_t)h & m;
    while (p->keys[s] != k) {
        if (!p->keys[s]) { fprintf(stderr, "FAIL: delete of absent key\n"); exit(1); }
        s = (s + 1) & m;
    }
    for (uint32_t j = s;;) {
        j = (j + 1) & m;
        uint64_t x = p->keys[j];
        if (!x) break;
        uint32_t home = (uint32_t)mix64(x) & m;
        if (((j - home) & m) >= ((j - s) & m)) {
            p->keys[s] = x;
            p->idx[s] = p->idx[j];
            s = j;
        }
    }
    p->keys[s] = 0;
    p->count--;
}

static void lru_remove(cache_t *c, shard_t *p, int32_t i) {
    if (c->prev[i] >= 0) c->next[c->prev[i]] = c->next[i]; else p->head = c->next[i];
    if (c->next[i] >= 0) c->prev[c->next[i]] = c->prev[i]; else p->tail = c->prev[i];
    c->prev[i] = c->next[i] = -1;
}
static void lru_push(cache_t *c, shard_t *p, int32_t i) {
    c->prev[i] = -1;
    c->next[i] = p->head;
    if (p->head >= 0) c->prev[p->head] = i; else p->tail = i;
    p->head = i;
}

static void cache_init(cache_t *c, int pol, uint32_t max, uint32_t parts) {
    memset(c, 0, sizeof *c);
    c->pol = pol;
    c->k = pol == P_S3 ? 3 : pol == P_S5 ? 5 : pol == P_S10 ? 10 : 0;
    c->max = max;
    c->parts = parts;
    c->key = calloc(max, 8);
    c->stamp = calloc(max, 8);
    c->prev = malloc(4 * max);
    c->next = malloc(4 * max);
    for (uint32_t i = 0; i < max; i++) c->prev[i] = c->next[i] = -1;
    c->S = calloc(parts, sizeof(shard_t));
    uint32_t sz = pow2_at_least((max / parts) * 2 + 256);
    for (uint32_t j = 0; j < parts; j++) {
        c->S[j].mask = sz - 1;
        c->S[j].keys = calloc(sz, 8);
        c->S[j].idx = calloc(sz, 4);
        c->S[j].head = c->S[j].tail = -1;
        c->S[j].cap = max / parts + (j < max % parts);
    }
    c->rng = 0x5eed0000ULL + (uint64_t)c->k * 0x10000; // worker 0's seed in k1b.c
    c->vh = FNV0;
}

static void cache_free(cache_t *c) {
    for (uint32_t j = 0; j < c->parts; j++) { free(c->S[j].keys); free(c->S[j].idx); }
    free(c->S); free(c->key); free(c->stamp); free(c->prev); free(c->next);
}

// The list a slot is on: lru keeps one list (shard 0's); plru one per shard.
static shard_t *list_of(cache_t *c, uint64_t h) { return c->pol == P_LRU ? &c->S[0] : &c->S[part_of(h, c->parts)]; }

static int32_t take_victim(cache_t *c, shard_t *home) {
    int32_t v;
    if (c->pol == P_LRU || c->pol == P_PLRU) {
        shard_t *l = c->pol == P_LRU ? &c->S[0] : home;
        v = l->tail;
        lru_remove(c, l, v);
    } else if (c->pol == P_CLOCK) {
        for (;;) {
            uint32_t s = (uint32_t)(c->hand++ % c->max);
            if (c->stamp[s]) { c->stamp[s] = 0; continue; }
            v = (int32_t)s;
            break;
        }
    } else {
        uint64_t best = UINT64_MAX;
        v = -1;
        for (int i = 0; i < c->k; i++) {
            uint32_t s = (uint32_t)(((splitmix64(&c->rng) >> 32) * (uint64_t)c->max) >> 32);
            if (c->stamp[s] < best) { best = c->stamp[s]; v = (int32_t)s; }
        }
    }
    uint64_t vk = c->key[v], vh = mix64(vk);
    delete(&c->S[part_of(vh, c->parts)], vk, vh);
    c->evictions++;
    c->vh = fnv_add(c->vh, vk);
    return v;
}

// One access at time t. Returns 1 on a hit.
static int cache_access(cache_t *c, uint64_t k, uint64_t t) {
    uint64_t h = mix64(k);
    shard_t *p = &c->S[part_of(h, c->parts)];
    int32_t s = find(p, k, h);
    int ls = c->pol == P_LRU || c->pol == P_PLRU;
    if (s >= 0) {
        if (ls) { shard_t *l = list_of(c, h); lru_remove(c, l, s); lru_push(c, l, s); }
        else c->stamp[s] = c->pol == P_CLOCK ? 1 : t;
        return 1;
    }
    int full = c->pol == P_PLRU ? p->count >= p->cap : c->nalloc >= c->max;
    s = full ? take_victim(c, p) : (int32_t)c->nalloc++;
    c->key[s] = k;
    insert(p, k, h, s);
    if (ls) lru_push(c, list_of(c, h), s);
    else c->stamp[s] = c->pol == P_CLOCK ? 1 : t;
    return 0;
}

static void check(cache_t *c) {
    uint32_t n = c->nalloc, entries = 0;
    if (n > c->max) { fprintf(stderr, "FAIL: %s nalloc %u > max\n", PNAMES[c->pol], n); exit(1); }
    for (uint32_t i = 0; i < n; i++) {
        uint64_t k = c->key[i], h = mix64(k);
        if (!k || find(&c->S[part_of(h, c->parts)], k, h) != (int32_t)i) {
            fprintf(stderr, "FAIL: %s slot %u not mapped\n", PNAMES[c->pol], i);
            exit(1);
        }
    }
    uint32_t listed = 0;
    for (uint32_t j = 0; j < c->parts; j++) {
        uint32_t e = 0;
        for (uint32_t s = 0; s <= c->S[j].mask; s++) e += c->S[j].keys[s] != 0;
        if (e != c->S[j].count) { fprintf(stderr, "FAIL: %s shard count\n", PNAMES[c->pol]); exit(1); }
        entries += e;
        if (c->pol == P_PLRU && c->S[j].count > c->S[j].cap) { fprintf(stderr, "FAIL: plru cap\n"); exit(1); }
        for (int32_t i = c->S[j].head; i >= 0; i = c->next[i]) listed++;
    }
    if (entries != n) { fprintf(stderr, "FAIL: %s entries %u != %u\n", PNAMES[c->pol], entries, n); exit(1); }
    if ((c->pol == P_LRU || c->pol == P_PLRU) && listed != n) {
        fprintf(stderr, "FAIL: %s listed %u != %u\n", PNAMES[c->pol], listed, n);
        exit(1);
    }
}

int main(int argc, char **argv) {
    long max = 10000, parts = 8, warm = -1, measure = -1;
    const char *uf = "2", *dist = "zipf99";
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : "";
        if (!strcmp(a, "--dist")) { dist = v; i++; }
        else if (!strcmp(a, "--max")) { max = atol(v); i++; }
        else if (!strcmp(a, "--universe")) { uf = v; i++; }
        else if (!strcmp(a, "--parts")) { parts = atol(v); i++; }
        else if (!strcmp(a, "--warm")) { warm = atol(v); i++; }
        else if (!strcmp(a, "--measure")) { measure = atol(v); i++; }
        else { fprintf(stderr, "unknown arg %s\n", a); return 2; }
    }
    int di = dist_of(dist);
    uint32_t U = (uint32_t)(atof(uf) * (double)max + 0.5);
    if (warm < 0) warm = 10 * max > 4 * (long)U ? 10 * max : 4 * (long)U;
    if (measure < 0) measure = 20 * max;
    workload_t wl;
    workload_init(&wl, di, U, (uint32_t)max);

    uint64_t hits[NPOL], ev[NPOL], vh[NPOL];
    for (int pol = 0; pol < NPOL; pol++) {
        cache_t c;
        cache_init(&c, pol, (uint32_t)max, (uint32_t)parts);
        uint64_t seed = 0x1234;
        uint32_t cur = 0;
        hits[pol] = 0;
        for (long t = 0; t < warm + measure; t++) {
            int hit = cache_access(&c, workload_next(&wl, &seed, &cur), (uint64_t)t + 1);
            if (t >= warm) hits[pol] += hit;
        }
        check(&c);
        ev[pol] = c.evictions;
        vh[pol] = c.vh;
        cache_free(&c);
    }
    printf("k1b_sim lang=c dist=%s max=%ld universe=%s parts=%ld warm=%ld measure=%ld", dist, max, uf, parts, warm,
           measure);
    for (int pol = 0; pol < NPOL; pol++) printf(" hit_%s=%.6f", PNAMES[pol], (double)hits[pol] / (double)measure);
    for (int pol = 0; pol < NPOL; pol++) printf(" hits_%s=%llu", PNAMES[pol], (unsigned long long)hits[pol]);
    for (int pol = 0; pol < NPOL; pol++) printf(" ev_%s=%llu", PNAMES[pol], (unsigned long long)ev[pol]);
    for (int pol = 0; pol < NPOL; pol++) printf(" vh_%s=%016llx", PNAMES[pol], (unsigned long long)vh[pol]);
    printf(" ok=1\n");
    return 0;
}
