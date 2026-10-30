// Shared pieces of K1 and K2 (C side). Rust mirrors these bit for bit in
// rust/src/common.rs, so K2's traces and miss counts agree exactly.
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

static void zipf_init(zipf_t *z, uint32_t n, double s) {
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
static int parse_list(const char *s, long *out, int cap) {
    int n = 0;
    while (*s && n < cap) {
        out[n++] = strtol(s, (char **)&s, 10);
        if (*s == ',') s++;
    }
    return n;
}
