/* A model of Ren's native runtime (lib/native/runtime/ren_rt.h, ren_rt.c
   at cf7787c), cut to what strings need: the 8-byte object header, the
   non-atomic count with 0 meaning "never freed", the size-class free
   lists over 1 MiB bump chunks (REN_SMALL_WORDS = 64 words, bigger goes
   to malloc), arrays that grow by doubling with realloc, and the
   ren_map shape (entries in order + an int32 index, wyhash, the hash
   kept in the entry). Copied, not linked, so representations can be
   swapped. Not Ren: no checks, no panics, no Perceus elision analysis;
   the caller writes the dups and drops Perceus would emit. */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#define INLINE static inline __attribute__((always_inline))
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* ---- the header and counting (ren_rt.h: ren_obj, ren_dup, ren_drop) ---- */
typedef struct ren_obj {
  int32_t rc; /* > 0 counted; 0 never freed (a literal) */
  uint16_t tag;
  uint8_t nfields, objs;
} ren_obj;

typedef struct {
  int64_t allocs, frees, dups, drops, copies, copied_bytes, live, peak;
} stats_t;
static stats_t st;
#ifdef STATS
#define STAT(x) (st.x++)
#define LIVE(n)                                                                \
  do {                                                                         \
    st.live += (n);                                                            \
    if (st.live > st.peak)                                                     \
      st.peak = st.live;                                                       \
  } while (0)
#else
#define STAT(x) ((void)0)
#define LIVE(n) ((void)0)
#endif

/* ---- memory (ren_rt.h: ren_alloc_bytes, ren_free_bytes; ren_rt.c:
   ren_alloc_slow, ren_alloc_big) ---- */
#define SMALL_WORDS 64
#define CHUNK_BYTES ((size_t)1 << 20)
static struct {
  void *free[SMALL_WORDS + 1];
  char *bump, *end;
} heap;

static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) {
    fputs("out of memory\n", stderr);
    exit(1);
  }
  return p;
}
__attribute__((noinline)) static void *alloc_slow(size_t w) {
  size_t bytes = w * 8;
  if ((size_t)(heap.end - heap.bump) < bytes) {
    heap.bump = xmalloc(CHUNK_BYTES);
    heap.end = heap.bump + CHUNK_BYTES;
  }
  void *p = heap.bump;
  heap.bump += bytes;
  return p;
}
INLINE void *alloc_bytes(size_t bytes) {
  size_t w = (bytes + 7) >> 3;
  STAT(allocs);
  LIVE((int64_t)bytes);
  if (LIKELY(w <= SMALL_WORDS)) {
    void *p = heap.free[w];
    if (LIKELY(p != NULL)) {
      heap.free[w] = *(void **)p;
      return p;
    }
    return alloc_slow(w);
  }
  return xmalloc(bytes);
}
INLINE void free_bytes(void *p, size_t bytes) {
  size_t w = (bytes + 7) >> 3;
  STAT(frees);
  LIVE(-(int64_t)bytes);
  if (LIKELY(w <= SMALL_WORDS)) {
    *(void **)p = heap.free[w];
    heap.free[w] = p;
    return;
  }
  free(p);
}

/* ---- timing ---- */
INLINE uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

/* ---- a file's bytes, whole (what Fs.read gives: one owner) ---- */
static char *read_file(const char *path, int64_t *n) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    perror(path);
    exit(1);
  }
  struct stat sb;
  fstat(fd, &sb);
  char *p = xmalloc((size_t)sb.st_size + 1);
  int64_t got = 0;
  while (got < sb.st_size) {
    ssize_t r = read(fd, p + got, (size_t)(sb.st_size - got));
    if (r <= 0)
      break;
    got += r;
  }
  close(fd);
  p[got] = 0;
  *n = got;
  return p;
}

/* ---- wyhash, as ren_rt.c has it (final v4), and its mix ---- */
#define WY0 UINT64_C(0x2d358dccaa6c78a5)
#define WY1 UINT64_C(0x8bb84b93962eacc9)
static uint64_t map_seed = UINT64_C(0x9e3779b97f4a7c15);
INLINE uint64_t mum(uint64_t a, uint64_t b) {
  __uint128_t r = (__uint128_t)a * b;
  return (uint64_t)r ^ (uint64_t)(r >> 64);
}
INLINE uint64_t rd8(const unsigned char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}
INLINE uint64_t rd4(const unsigned char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}
INLINE uint64_t wyhash(const unsigned char *p, size_t n, uint64_t seed) {
  seed ^= mum(seed ^ WY0, WY1);
  uint64_t a, b;
  if (LIKELY(n <= 16)) {
    if (n >= 4) {
      size_t k = (n >> 3) << 2;
      a = (rd4(p) << 32) | rd4(p + k);
      b = (rd4(p + n - 4) << 32) | rd4(p + n - 4 - k);
    } else if (n > 0) {
      a = ((uint64_t)p[0] << 16) | ((uint64_t)p[n >> 1] << 8) | p[n - 1];
      b = 0;
    } else
      a = b = 0;
  } else {
    size_t i = n;
    while (i > 16) {
      seed = mum(rd8(p) ^ WY1, rd8(p + 8) ^ seed);
      p += 16;
      i -= 16;
    }
    a = rd8(p + i - 16);
    b = rd8(p + i - 8);
  }
  return mum(WY1 ^ n, mum(a ^ WY1, b ^ seed));
}
/* ren_key_hash for a Str: mix(3, wyhash), never 0 */
INLINE uint64_t key_hash_wy(const char *p, int64_t n) {
  uint64_t h = mum(3 ^ wyhash((const unsigned char *)p, (size_t)n, map_seed) ^ WY0,
                   map_seed ^ WY1);
  return h ? h : 1;
}
/* FxHash (rustc-hash 1.x's word-at-a-time multiply-rotate), for B4 */
INLINE uint64_t key_hash_fx(const char *p, int64_t n) {
  const uint64_t K = UINT64_C(0x517cc1b727220a95);
  uint64_t h = 0;
  const unsigned char *s = (const unsigned char *)p;
  while (n >= 8) {
    h = (((h << 5) | (h >> 59)) ^ rd8(s)) * K;
    s += 8;
    n -= 8;
  }
  if (n >= 4) {
    h = (((h << 5) | (h >> 59)) ^ rd4(s)) * K;
    s += 4;
    n -= 4;
  }
  while (n > 0) {
    h = (((h << 5) | (h >> 59)) ^ *s) * K;
    s++;
    n--;
  }
  /* fold the high bits down: the index uses the top bits */
  h = mum(h, WY1);
  return h ? h : 1;
}

/* ---- a growable vector, as ren_array's push: doubling, realloc ---- */
#define VEC(T)                                                                 \
  struct {                                                                     \
    int64_t len, cap;                                                          \
    T *data;                                                                   \
  }
#define VEC_PUSH(v, x)                                                         \
  do {                                                                         \
    if (UNLIKELY((v).len == (v).cap)) {                                        \
      (v).cap = (v).cap ? (v).cap * 2 : 1;                                     \
      (v).data = realloc((v).data, (size_t)(v).cap * sizeof(*(v).data));       \
    }                                                                          \
    (v).data[(v).len++] = (x);                                                 \
  } while (0)

/* a stable output sink */
static uint64_t sink;
#define REPORT(name, ns)                                                       \
  printf("%s_ns=%llu\n", name, (unsigned long long)(ns))
