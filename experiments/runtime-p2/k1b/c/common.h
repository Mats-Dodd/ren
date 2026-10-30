// Shared pieces of K1b (C side). Copied from phase 1's k1k2/c/common.h, plus
// the K1b workloads at the end. Rust mirrors these bit for bit in
// rust/src/common.rs, so the simulator's traces and hit counts agree exactly.
#pragma once
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// splitmix64: the trace generator. Same constants in Rust.
static inline uint64_t splitmix64(uint64_t *s) {
    uint64_t z = (*s += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

// The key hash (murmur3's finalizer). Partition = high 32 bits mod parts,
// table slot = low bits, so the two are independent.
static inline uint64_t mix64(uint64_t k) {
    k ^= k >> 33;
    k *= 0xff51afd7ed558ccdULL;
    k ^= k >> 33;
    k *= 0xc4ceb9fe1a85ec53ULL;
    k ^= k >> 33;
    return k;
}

static inline uint32_t part_of(uint64_t h, uint32_t parts) {
    return (uint32_t)((h >> 32) % parts);
}

// Keys are 1..n (0 is the empty slot).
static inline uint64_t uniform_key(uint64_t x, uint32_t n) {
    return 1 + (((x >> 32) * (uint64_t)n) >> 32);
}

typedef struct {
    double *cdf;
    uint32_t n;
} zipf_t;

__attribute__((unused)) static void zipf_init(zipf_t *z, uint32_t n, double s) {
    z->n = n;
    z->cdf = malloc(sizeof(double) * n);
    double sum = 0;
    for (uint32_t i = 1; i <= n; i++) {
        sum += pow((double)i, -s);
        z->cdf[i - 1] = sum;
    }
    for (uint32_t i = 0; i < n; i++) z->cdf[i] /= sum;
    z->cdf[n - 1] = 1.0;
}

// Rank 1 is the hottest key; the hash spreads ranks over partitions.
static inline uint64_t zipf_key(const zipf_t *z, uint64_t x) {
    double u = (double)(x >> 11) * 0x1.0p-53;
    uint32_t lo = 0, hi = z->n - 1;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        if (z->cdf[mid] >= u) hi = mid; else lo = mid + 1;
    }
    return (uint64_t)lo + 1;
}

static inline uint32_t pow2_at_least(uint32_t x) {
    uint32_t p = 4;
    while (p < x) p <<= 1;
    return p;
}

// Parse "1,2,4" into out (max cap entries); returns count.
__attribute__((unused)) static int parse_list(const char *s, long *out, int cap) {
    int n = 0;
    while (*s && n < cap) {
        out[n++] = strtol(s, (char **)&s, 10);
        if (*s == ',') s++;
    }
    return n;
}

// ---- K1b workloads ---------------------------------------------------------
// uniform:  keys uniform over 1..U.
// zipf99:   Zipf(0.99) over 1..U, rank r is key r (the hash scatters ranks).
// zipf70:   Zipf(0.7) over 1..U.
// scan:     half the accesses are zipf99 over 1..U, half walk a cyclic loop of
//           L = 1.5 * max keys (SCAN_BASE + 0 .. L-1), disjoint from the hot
//           keys. The loop is larger than max, so exact LRU never hits on it.
enum { D_UNIFORM = 0, D_ZIPF99 = 1, D_ZIPF70 = 2, D_SCAN = 3 };
static const char *DIST_NAMES[] = {"uniform", "zipf99", "zipf70", "scan"};
#define SCAN_BASE (1u << 30)

__attribute__((unused)) static int dist_of(const char *s) {
    for (int i = 0; i < 4; i++)
        if (!strcmp(s, DIST_NAMES[i])) return i;
    fprintf(stderr, "unknown dist %s\n", s);
    exit(2);
}

typedef struct {
    int dist;
    uint32_t U, L;
    zipf_t z;
} workload_t;

__attribute__((unused)) static void workload_init(workload_t *w, int dist, uint32_t U, uint32_t max) {
    w->dist = dist;
    w->U = U;
    w->L = max / 2 * 3;
    w->z.cdf = NULL;
    if (dist != D_UNIFORM) zipf_init(&w->z, U, dist == D_ZIPF70 ? 0.7 : 0.99);
}

// One draw of splitmix64 per access. For scan, bit 0 picks the half and the
// Zipf draw uses bits 11..63, so the two are independent.
static inline uint32_t workload_next(const workload_t *w, uint64_t *seed, uint32_t *cursor) {
    uint64_t x = splitmix64(seed);
    switch (w->dist) {
    case D_UNIFORM: return (uint32_t)uniform_key(x, w->U);
    case D_SCAN:
        if (x & 1) {
            uint32_t c = *cursor;
            *cursor = c + 1 == w->L ? 0 : c + 1;
            return SCAN_BASE + c;
        }
        return (uint32_t)zipf_key(&w->z, x);
    default: return (uint32_t)zipf_key(&w->z, x);
    }
}

// FNV-1a over 64-bit words: the victim-sequence fingerprint.
static inline uint64_t fnv_add(uint64_t h, uint64_t v) {
    for (int i = 0; i < 8; i++) { h ^= (v >> (8 * i)) & 0xff; h *= 0x100000001b3ULL; }
    return h;
}
#define FNV0 0xcbf29ce484222325ULL

// Phase 1's suggested default for parts: the largest power of two at most
// max / 1024, clamped to 1..64 (10_000 -> 8, 50_000 -> 32).
static inline uint32_t default_parts(uint32_t max) {
    uint32_t p = 1;
    while (p * 2 <= max / 1024 && p < 64) p *= 2;
    return p;
}
