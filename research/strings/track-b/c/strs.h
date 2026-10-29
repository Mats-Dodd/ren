/* Four layouts of a Str value, one API. Pick with -DREPR_A, -DREPR_B,
   -DREPR_SSO or -DREPR_G.

   A    today's (ren_rt.h, ren_str): the value is a pointer to a counted
        object; an owner holds its bytes after a 32-byte header; a slice
        is a 32-byte object of its own {data, root} counting its root.
   B    decision 17's representation B: the value is 16 bytes inline,
        {root, u32 offset, u32 length}; the root is a 16-byte header
        {count, cap} and its bytes. A slice is a count on the root and
        nothing allocated. (Strings of 4 GiB or more would need an escape,
        a flag and an out-of-line {offset, length}; not built here.)
   SSO  B, and a string of at most 15 bytes kept in the value itself: the
        last byte is 0x80 | length (B's length is < 2^31, so its top
        byte's top bit is 0). Canonical: every string of <= 15 bytes is
        inline, its padding zero, so two values are equal iff their 16
        bytes are, when either is inline.
   G    German (Umbra, DuckDB, Arrow's StringView): {u32 length, 4-byte
        prefix, 8 bytes} where up to 12 bytes are all inline (from the
        prefix on), else the last 8 bytes are a pointer. An interior data
        pointer can't find its root to count it, so the pointer is to an
        A-style object: the owner itself, or, for a slice that isn't the
        whole root, a 32-byte slice object {data, root}. Equality is the
        first 8 bytes in one compare, then the rest; ordering compares the
        prefix first.

   Retention policy (B2), any layout: -DRET_N=n copies a slice shorter than
   n bytes when it's made; -DRET_STORE copies a slice when it's stored
   in a collection (s_keep). Default: always share. */
#pragma once
#include "rt.h"

#ifndef RET_N
#define RET_N 0
#endif

#define TAG_STR 2

/* -DATOMIC_RC: every count atomic, as ren_rt.h's REN_RC_ATOMIC (a value
   shared between threads) */
#ifdef ATOMIC_RC
#define RC_INC(o) __atomic_fetch_add(&(o)->h.rc, 1, __ATOMIC_RELAXED)
#define RC_DEC(o) (__atomic_sub_fetch(&(o)->h.rc, 1, __ATOMIC_RELEASE) == 0)
#else
#define RC_INC(o) ((o)->h.rc++)
#define RC_DEC(o) (--(o)->h.rc == 0)
#endif

/* ---------------------------------------------------------------- A */
#if defined(REPR_A) || defined(REPR_G)
typedef struct astr {
  ren_obj h;
  int64_t len;
  const char *data;
  struct astr *root;
  char bytes[];
} astr;

INLINE astr *astr_new(const char *p, int64_t n) {
  astr *s = alloc_bytes(sizeof(astr) + (size_t)n + 1);
  s->h.rc = 1;
  s->h.tag = TAG_STR;
  s->len = n;
  s->data = s->bytes;
  s->root = NULL;
  memcpy(s->bytes, p, (size_t)n);
  s->bytes[n] = 0;
  return s;
}
INLINE void astr_dup(astr *s) {
  STAT(dups);
  if (s->h.rc > 0)
    RC_INC(s);
}
__attribute__((noinline)) static void astr_free(astr *s) {
  if (s->root) {
    astr *r = s->root;
    free_bytes(s, sizeof(astr));
    if (r->h.rc > 0 && RC_DEC(r))
      free_bytes(r, sizeof(astr) + (size_t)r->len + 1);
  } else
    free_bytes(s, sizeof(astr) + (size_t)s->len + 1);
}
INLINE void astr_drop(astr *s) {
  STAT(drops);
#ifdef ATOMIC_RC
  if (s->h.rc > 0 && RC_DEC(s))
    astr_free(s);
#else
  if (s->h.rc > 1)
    s->h.rc--;
  else if (s->h.rc == 1)
    astr_free(s);
#endif
}
/* ren_str_part */
INLINE astr *astr_part(astr *a, int64_t i, int64_t j) {
  if (i == 0 && j == a->len) {
    astr_dup(a);
    return a;
  }
  astr *s = alloc_bytes(sizeof(astr));
  s->h.rc = 1;
  s->h.tag = TAG_STR;
  s->len = j - i;
  s->data = a->data + i;
  s->root = a->root ? a->root : a;
  astr_dup(s->root);
  return s;
}
#endif

#if defined(REPR_A)
#define REPR_NAME "A"
typedef astr *S;
INLINE S s_new(const char *p, int64_t n) { return astr_new(p, n); }
INLINE int64_t s_len(const S *s) { return (*s)->len; }
INLINE const char *s_ptr(const S *s) { return (*s)->data; }
INLINE void s_dup(const S *s) { astr_dup(*s); }
INLINE void s_drop(S *s) { astr_drop(*s); }
INLINE bool s_is_slice(const S *s) { return (*s)->root != NULL; }
INLINE S s_slice_shared(const S *s, int64_t i, int64_t j) { return astr_part(*s, i, j); }
INLINE void s_immortal(S *s) { (*s)->h.rc = 0; }
INLINE bool s_eq(const S *a, const S *b) {
  return (*a)->len == (*b)->len &&
         memcmp((*a)->data, (*b)->data, (size_t)(*a)->len) == 0;
}
INLINE bool s_eq_raw(const S *a, const char *p, int64_t n) {
  return (*a)->len == n && memcmp((*a)->data, p, (size_t)n) == 0;
}
#endif

/* ---------------------------------------------------------- B, SSO */
#if defined(REPR_B) || defined(REPR_SSO) || defined(REPR_B24)
typedef struct bown {
  ren_obj h;
  int64_t cap; /* bytes it holds */
  char bytes[];
} bown;
INLINE bown *bown_new(const char *p, int64_t n) {
  bown *o = alloc_bytes(sizeof(bown) + (size_t)n);
  o->h.rc = 1;
  o->h.tag = TAG_STR;
  o->cap = n;
  memcpy(o->bytes, p, (size_t)n);
  return o;
}
__attribute__((noinline)) static void bown_free(bown *o) {
  free_bytes(o, sizeof(bown) + (size_t)o->cap);
}
#endif

#if defined(REPR_B)
#define REPR_NAME "B"
typedef struct {
  bown *root;
  uint32_t off, len;
} S;
INLINE S s_new(const char *p, int64_t n) {
  S s = {bown_new(p, n), 0, (uint32_t)n};
  return s;
}
INLINE int64_t s_len(const S *s) { return s->len; }
INLINE const char *s_ptr(const S *s) { return s->root->bytes + s->off; }
INLINE void s_dup(const S *s) {
  STAT(dups);
  if (s->root->h.rc > 0)
    RC_INC(s->root);
}
INLINE void s_drop(S *s) {
  STAT(drops);
  bown *o = s->root;
#ifdef ATOMIC_RC
  if (o->h.rc > 0 && RC_DEC(o))
    bown_free(o);
#else
  if (o->h.rc > 1)
    o->h.rc--;
  else if (o->h.rc == 1)
    bown_free(o);
#endif
}
INLINE bool s_is_slice(const S *s) { return s->off != 0 || s->len != s->root->cap; }
INLINE S s_slice_shared(const S *s, int64_t i, int64_t j) {
  S r = {s->root, s->off + (uint32_t)i, (uint32_t)(j - i)};
  s_dup(&r);
  return r;
}
INLINE void s_immortal(S *s) { s->root->h.rc = 0; }
INLINE bool s_eq(const S *a, const S *b) {
  if (a->len != b->len)
    return false;
  if (a->root == b->root && a->off == b->off)
    return true;
  return memcmp(s_ptr(a), s_ptr(b), a->len) == 0;
}
INLINE bool s_eq_raw(const S *a, const char *p, int64_t n) {
  return a->len == n && memcmp(s_ptr(a), p, (size_t)n) == 0;
}
#endif

/* B24: Roc's shape (roc-rust/crates/compiler/builtins/bitcode/src/
   str.zig, RocStr: bytes, length, capacity_or_alloc_ptr), 24 bytes
   {data, len, root}: no 4 GiB limit and no add to find the bytes, a
   word more per value. */
#if defined(REPR_B24)
#define REPR_NAME "B24"
typedef struct {
  const char *data;
  int64_t len;
  bown *root;
} S;
INLINE S s_new(const char *p, int64_t n) {
  bown *o = bown_new(p, n);
  S s = {o->bytes, n, o};
  return s;
}
INLINE int64_t s_len(const S *s) { return s->len; }
INLINE const char *s_ptr(const S *s) { return s->data; }
INLINE void s_dup(const S *s) {
  STAT(dups);
  if (s->root->h.rc > 0)
    RC_INC(s->root);
}
INLINE void s_drop(S *s) {
  STAT(drops);
  bown *o = s->root;
#ifdef ATOMIC_RC
  if (o->h.rc > 0 && RC_DEC(o))
    bown_free(o);
#else
  if (o->h.rc > 1)
    o->h.rc--;
  else if (o->h.rc == 1)
    bown_free(o);
#endif
}
INLINE bool s_is_slice(const S *s) { return s->data != s->root->bytes || s->len != s->root->cap; }
INLINE S s_slice_shared(const S *s, int64_t i, int64_t j) {
  S r = {s->data + i, j - i, s->root};
  s_dup(&r);
  return r;
}
INLINE void s_immortal(S *s) { s->root->h.rc = 0; }
INLINE bool s_eq(const S *a, const S *b) {
  if (a->len != b->len)
    return false;
  if (a->data == b->data)
    return true;
  return memcmp(a->data, b->data, (size_t)a->len) == 0;
}
INLINE bool s_eq_raw(const S *a, const char *p, int64_t n) {
  return a->len == n && memcmp(a->data, p, (size_t)n) == 0;
}
#endif

#if defined(REPR_SSO)
#define REPR_NAME "SSO"
typedef union {
  struct {
    bown *root;
    uint32_t off, len;
  } h;
  unsigned char b[16];
  uint64_t w[2];
} S;
INLINE bool s_inl(const S *s) { return (s->b[15] & 0x80) != 0; }
INLINE S s_inline(const char *p, int64_t n) {
  S s;
  s.w[0] = s.w[1] = 0;
  memcpy(s.b, p, (size_t)n);
  s.b[15] = (unsigned char)(0x80 | n);
  return s;
}
INLINE S s_new(const char *p, int64_t n) {
  if (n <= 15)
    return s_inline(p, n);
  S s;
  s.h.root = bown_new(p, n);
  s.h.off = 0;
  s.h.len = (uint32_t)n;
  return s;
}
INLINE int64_t s_len(const S *s) { return s_inl(s) ? (s->b[15] & 0x7f) : s->h.len; }
INLINE const char *s_ptr(const S *s) {
  return s_inl(s) ? (const char *)s->b : s->h.root->bytes + s->h.off;
}
INLINE void s_dup(const S *s) {
  if (s_inl(s))
    return;
  STAT(dups);
  if (s->h.root->h.rc > 0)
    RC_INC(s->h.root);
}
INLINE void s_drop(S *s) {
  if (s_inl(s))
    return;
  STAT(drops);
  bown *o = s->h.root;
#ifdef ATOMIC_RC
  if (o->h.rc > 0 && RC_DEC(o))
    bown_free(o);
#else
  if (o->h.rc > 1)
    o->h.rc--;
  else if (o->h.rc == 1)
    bown_free(o);
#endif
}
INLINE bool s_is_slice(const S *s) {
  return !s_inl(s) && (s->h.off != 0 || s->h.len != s->h.root->cap);
}
INLINE S s_slice_shared(const S *s, int64_t i, int64_t j) {
  if (j - i <= 15) {
#ifndef SSO_MEMCPY
    /* two 8-byte loads and a mask, when 16 bytes from the start are in
       the root (an allocator that pads every buffer by 15 bytes makes
       it always so); else the byte copy */
    if (!s_inl(s) && s->h.off + i + 16 <= s->h.root->cap) {
      const unsigned char *p = (const unsigned char *)s_ptr(s) + i;
      int64_t n = j - i;
      S r;
      uint64_t a = rd8(p), b = rd8(p + 8);
      if (n <= 8) {
        r.w[0] = n == 8 ? a : a & ((UINT64_C(1) << (8 * n)) - 1);
        r.w[1] = 0;
      } else {
        r.w[0] = a;
        r.w[1] = b & ((UINT64_C(1) << (8 * (n - 8))) - 1);
      }
      r.b[15] = (unsigned char)(0x80 | n);
      return r;
    }
#endif
    return s_inline(s_ptr(s) + i, j - i);
  }
  S r;
  r.h.root = s->h.root;
  r.h.off = s->h.off + (uint32_t)i;
  r.h.len = (uint32_t)(j - i);
  s_dup(&r);
  return r;
}
INLINE void s_immortal(S *s) {
  if (!s_inl(s))
    s->h.root->h.rc = 0;
}
INLINE bool s_eq(const S *a, const S *b) {
  if (a->w[0] == b->w[0] && a->w[1] == b->w[1])
    return true;
  if (s_inl(a) || s_inl(b))
    return false;
  return a->h.len == b->h.len &&
         memcmp(s_ptr(a), s_ptr(b), a->h.len) == 0;
}
INLINE bool s_eq_raw(const S *a, const char *p, int64_t n) {
  if (s_inl(a)) {
    if ((a->b[15] & 0x7f) != n)
      return false;
    S t = s_inline(p, n);
    return a->w[0] == t.w[0] && a->w[1] == t.w[1];
  }
  return a->h.len == n && memcmp(s_ptr(a), p, (size_t)n) == 0;
}
#endif

/* ---------------------------------------------------------------- G */
#if defined(REPR_G)
#define REPR_NAME "G"
typedef union {
  struct {
    uint32_t len;
    uint32_t prefix;
    astr *p;
  } h;
  unsigned char b[16];
  uint64_t w[2];
} S;
INLINE S g_inline(const char *p, int64_t n) {
  S s;
  s.w[0] = s.w[1] = 0;
  s.h.len = (uint32_t)n;
  memcpy(s.b + 4, p, (size_t)n);
  return s;
}
INLINE S g_heap(astr *o, int64_t n) {
  S s;
  s.h.len = (uint32_t)n;
  memcpy(&s.h.prefix, o->data, 4);
  s.h.p = o;
  return s;
}
INLINE S s_new(const char *p, int64_t n) {
  if (n <= 12)
    return g_inline(p, n);
  return g_heap(astr_new(p, n), n);
}
INLINE int64_t s_len(const S *s) { return s->h.len; }
INLINE const char *s_ptr(const S *s) {
  return s->h.len <= 12 ? (const char *)s->b + 4 : s->h.p->data;
}
INLINE void s_dup(const S *s) {
  if (s->h.len > 12)
    astr_dup(s->h.p);
}
INLINE void s_drop(S *s) {
  if (s->h.len > 12)
    astr_drop(s->h.p);
}
INLINE bool s_is_slice(const S *s) { return s->h.len > 12 && s->h.p->root != NULL; }
INLINE S s_slice_shared(const S *s, int64_t i, int64_t j) {
  if (j - i <= 12)
    return g_inline(s_ptr(s) + i, j - i);
  return g_heap(astr_part(s->h.p, i, j), j - i);
}
INLINE void s_immortal(S *s) {
  if (s->h.len > 12)
    s->h.p->h.rc = 0;
}
INLINE bool s_eq(const S *a, const S *b) {
  if (a->w[0] != b->w[0]) /* length and prefix, one compare */
    return false;
  if (a->h.len <= 12)
    return a->w[1] == b->w[1];
  if (a->h.p == b->h.p)
    return true;
  return memcmp(a->h.p->data + 4, b->h.p->data + 4, a->h.len - 4) == 0;
}
INLINE bool s_eq_raw(const S *a, const char *p, int64_t n) {
  if (a->h.len != n)
    return false;
  if (n <= 12) {
    S t = g_inline(p, n);
    return a->w[0] == t.w[0] && a->w[1] == t.w[1];
  }
  uint32_t pre;
  memcpy(&pre, p, 4);
  if (pre != a->h.prefix)
    return false;
  return memcmp(a->h.p->data + 4, p + 4, (size_t)n - 4) == 0;
}
#endif

/* ------------------------------------------------- shared, any layout */

/* `s[i..j]` under the retention policy */
INLINE S s_slice(const S *s, int64_t i, int64_t j) {
#if RET_N > 0
  if (j - i < RET_N) {
    STAT(copies);
#ifdef STATS
    st.copied_bytes += j - i;
#endif
    return s_new(s_ptr(s) + i, j - i);
  }
#endif
  return s_slice_shared(s, i, j);
}
/* `copy()`: cut from its root (free on an owner) */
INLINE S s_copy(S *s) {
  if (!s_is_slice(s)) {
    s_dup(s);
    return *s;
  }
  STAT(copies);
#ifdef STATS
  st.copied_bytes += s_len(s);
#endif
  return s_new(s_ptr(s), s_len(s));
}
/* a value about to be stored in a collection: under RET_STORE, a slice
   is copied (taking [s]) */
INLINE S s_keep(S s) {
#ifdef RET_STORE
  if (s_is_slice(&s)) {
    S c = s_copy(&s);
    s_drop(&s);
    return c;
  }
#endif
  return s;
}
INLINE int s_cmp(const S *a, const S *b) {
#if defined(REPR_G)
  if (a->h.prefix != b->h.prefix) {
    uint32_t x = __builtin_bswap32(a->h.prefix), y = __builtin_bswap32(b->h.prefix);
    return x < y ? -1 : 1;
  }
#endif
  int64_t la = s_len(a), lb = s_len(b);
  int c = memcmp(s_ptr(a), s_ptr(b), (size_t)(la < lb ? la : lb));
  if (c)
    return c;
  return la < lb ? -1 : la > lb;
}
INLINE S s_lit(const char *p) {
  S s = s_new(p, (int64_t)strlen(p));
  s_immortal(&s);
  return s;
}
