/* Ren's Map<Str, Int> (ren_rt.h ren_map, ren_rt.c ren_map_probe,
   ren_map_room, ren_map_reindex): entries in insertion order, each
   {hash, key, value}, and an index of int32 entry numbers, 2^shift
   slots at most 2/3 full, probed linearly from the hash's top bits; an
   entry's hash is compared before its key. No removal here.

   B4 knobs: -DHASH_FX (FxHash instead of wyhash), -DHASH_PREFIX (hash
   only the length and first 8 bytes: what a "prefix-first" key would
   hash), -DNO_HASH_CMP (don't compare the kept hash first: the key's own
   equality, prefix-first for G, is the first test). */
#pragma once
#include "strs.h"

#if defined(HASH_FX)
#define KHASH(p, n) key_hash_fx(p, n)
#elif defined(HASH_PREFIX)
INLINE uint64_t key_hash_prefix(const char *p, int64_t n) {
  uint64_t x = 0;
  memcpy(&x, p, n < 8 ? (size_t)n : 8);
  uint64_t h = mum(x ^ WY0 ^ (uint64_t)n, map_seed ^ WY1);
  return h ? h : 1;
}
#define KHASH(p, n) key_hash_prefix(p, n)
#else
#define KHASH(p, n) key_hash_wy(p, n)
#endif

typedef struct {
  uint64_t hash;
  S key;
  int64_t val;
} entry;

typedef struct {
  int64_t len, cap;
  int32_t shift;
  entry *e;
  int32_t *index;
} smap;

static void smap_reindex(smap *m) {
  int32_t shift = 3;
  while (((int64_t)1 << shift) * 2 < m->cap * 3)
    shift++;
  if (shift != m->shift) {
    free(m->index);
    m->index = xmalloc(((size_t)1 << shift) * sizeof(int32_t));
    m->shift = shift;
  }
  uint64_t mask = ((uint64_t)1 << shift) - 1;
  memset(m->index, 0xFF, ((size_t)1 << shift) * sizeof(int32_t));
  for (int64_t e = 0; e < m->len; e++) {
    uint64_t i = m->e[e].hash >> (64 - shift);
    while (m->index[i] != -1)
      i = (i + 1) & mask;
    m->index[i] = (int32_t)e;
  }
}
__attribute__((noinline)) static void smap_room(smap *m) {
  int64_t cap = m->cap < 8 ? 8 : m->cap * 2;
  m->e = realloc(m->e, (size_t)cap * sizeof(entry));
  m->cap = cap;
  smap_reindex(m);
}

/* the entry of the key p[0..n), of hash h, or -1 with [*slot] the empty
   slot the probe ended at */
INLINE int64_t smap_probe(const smap *m, uint64_t h, const char *p, int64_t n,
                          uint64_t *slot) {
  if (m->shift == 0) {
    *slot = 0;
    return -1;
  }
  uint64_t mask = ((uint64_t)1 << m->shift) - 1;
  uint64_t i = h >> (64 - m->shift);
  for (;; i = (i + 1) & mask) {
    int32_t e = m->index[i];
    if (e == -1) {
      *slot = i;
      return -1;
    }
#ifdef NO_HASH_CMP
    if (s_eq_raw(&m->e[e].key, p, n))
      return e;
#else
    if (m->e[e].hash == h && s_eq_raw(&m->e[e].key, p, n))
      return e;
#endif
  }
}

INLINE int64_t smap_find(const smap *m, const char *p, int64_t n) {
  uint64_t slot;
  return smap_probe(m, KHASH(p, n), p, n, &slot);
}

/* m[src[i..j]] += add: the key, if new, is a slice of [src] (counted,
   or copied under the retention policy) */
INLINE void smap_add(smap *m, const S *src, int64_t i, int64_t j, int64_t add) {
  const char *p = s_ptr(src) + i;
  int64_t n = j - i;
  uint64_t h = KHASH(p, n), slot;
  int64_t e = smap_probe(m, h, p, n, &slot);
  if (e >= 0) {
    m->e[e].val += add;
    return;
  }
  if (m->len == m->cap) {
    smap_room(m);
    smap_probe(m, h, p, n, &slot);
  }
  entry *en = &m->e[m->len];
  en->hash = h;
  en->key = s_keep(s_slice(src, i, j));
  en->val = add;
  m->index[slot] = (int32_t)m->len;
  m->len++;
}

static void smap_free(smap *m) {
  for (int64_t e = 0; e < m->len; e++)
    s_drop(&m->e[e].key);
  free(m->e);
  free(m->index);
}
