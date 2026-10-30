// X5: static frame-stack sizing, and the chunk-boundary case with and without
// one spare chunk (research/runtime-frames/SYNTHESIS.md §2f, §2g; X5 and X7).
//
// Frames use X1's register convention (x1/ren_reg.c). A task is one malloc:
// a header plus an inline segment of its frame stack. A frame that doesn't
// fit in the current region goes in an overflow chunk (4 KiB, or bigger if
// one frame needs it).
//
//   park  <policy> <N>    N tasks run serve -> read -> recv and park in recv,
//                         waiting for a reply. Prints bytes per parked task.
//   bound <policy> <n>    one task calls a leaf n times, with the leaf's frame
//                         in the segment (policy inseg) or just past it.
//
// Policies:
//   today      inline segment = the body's frame only (as ren_single.c sizes
//              a spawned task); read and recv go in a 4 KiB chunk; a chunk is
//              freed as soon as it empties.
//   static     inline segment = the chain's static bound, capped at 256 B;
//              one spare chunk kept, and freed when the task parks.
//   static_x   static, but serve first makes one deep call (past the segment)
//              that completes inline, so a spare exists when the task parks.
//   static_xk  static_x, but the spare is kept at park (shows why it's freed).
//   inseg      (bound only) the leaf's frame fits in the segment.
//   free       (bound only) leaf just past the segment; chunk freed on empty.
//   spare      (bound only) leaf just past the segment; one spare kept.
//
// Chunk retirement. SYNTHESIS §5 retires a chunk in the trampoline, by the
// REN_FIRST_IN_CHUNK flag of the frame that finishes. That covers only the
// resume path. On the fast path a callee in a chunk returns DONE straight to
// its caller, so the caller that grew must retire it: the call site keeps a
// `grew` flag (a register) and tests it after the call. t->limit is the
// current region's limit, set by grow and restored by retire.

#if defined(__TINYC__) /* tcc can't parse <malloc/malloc.h>'s TargetConditionals.h */
#include <stddef.h>
typedef struct { unsigned blocks_in_use; size_t size_in_use, max_size_in_use, size_allocated; } malloc_statistics_t;
size_t malloc_size(const void *);
void malloc_zone_statistics(void *zone, malloc_statistics_t *stats);
#else
#include <malloc/malloc.h>
#endif
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__TINYC__)
#define LIKELY(x) (x)
#define UNLIKELY(x) (x)
#else
#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif
#define NOINLINE __attribute__((noinline))
/* -DGROW_INLINE: the grow and retire paths inlined at the call site (more code
   at each call that can overflow; tests how much of the boundary cost is the
   two out-of-line calls rather than the policy). */
#if defined(GROW_INLINE) && !defined(__TINYC__)
#define GROWATTR static inline __attribute__((always_inline))
#else
#define GROWATTR NOINLINE static
#endif
#define R16(x) (((x) + 15u) & ~15u)
#define CHUNK 4096
#define INLINE_CAP 256

static double tick_ns;
static uint64_t now(void) { return mach_absolute_time(); }

/* ---------- the convention (x1/ren_reg.c) ---------- */
typedef struct task task;
typedef struct frame frame;
typedef struct { uintptr_t st; uint64_t v; } ren_ret;
enum { DONE = 0, PENDING = 1 };
enum { FIRST_IN_CHUNK = 1 };
typedef ren_ret (*ren_resume)(task *, frame *, char *sp, uint64_t in);
struct frame {
  ren_resume resume;
  frame *parent;
  uint32_t state, flags;
  char *sp;
};
typedef struct chunk {
  struct chunk *prev;
  char *prev_limit;
  uint32_t cap, _pad;
  uint64_t _pad2; /* 32 B: frames after it stay 16-aligned */
} chunk;
struct task {
  frame *top;
  char *limit;   /* end of the current region (segment or chunk) */
  chunk *chunk;  /* chunks in use, innermost first */
  chunk *spare;  /* one emptied chunk, kept for reuse */
  uint64_t result;
  uint32_t seg;  /* inline segment bytes */
  uint8_t done, keep_spare, keep_at_park, _pad;
  _Alignas(16) char frames[];
};

static uint64_t n_chunk_malloc, n_chunk_free;

GROWATTR char *ren_grow(task *t, uint32_t size, char **frame_out) {
  uint32_t need = size + (uint32_t)sizeof(chunk);
  chunk *c = t->spare;
  if (c && c->cap >= need) t->spare = NULL;
  else {
    uint32_t cap = need > CHUNK ? R16(need) : CHUNK;
    c = malloc(cap);
    if (!c) abort();
    c->cap = cap;
    n_chunk_malloc++;
  }
  c->prev = t->chunk;
  c->prev_limit = t->limit;
  t->chunk = c;
  t->limit = (char *)c + c->cap;
  char *f = (char *)(c + 1);
  *frame_out = f;
  ((frame *)f)->flags = FIRST_IN_CHUNK;
  return f + size;
}
GROWATTR void ren_chunk_done(task *t) {
  chunk *c = t->chunk;
  t->chunk = c->prev;
  t->limit = c->prev_limit;
  if (t->keep_spare && !t->spare) t->spare = c;
  else { free(c); n_chunk_free++; }
}
static void ren_park_hook(task *t) { /* the task just parked */
  if (t->spare && !t->keep_at_park) { free(t->spare); n_chunk_free++; t->spare = NULL; }
}

/* A call: frame bumped from sp, or placed in a chunk past the region. */
#define CALL(FT, FN, SETARGS, ARG, ST, SPILL)                             \
  {                                                                       \
    FT *c_;                                                               \
    char *csp_;                                                           \
    bool grew_ = false;                                                   \
    if (LIKELY(sp + R16(sizeof(FT)) <= t->limit)) {                       \
      c_ = (FT *)sp; csp_ = sp + R16(sizeof(FT)); c_->h.flags = 0;        \
    } else {                                                              \
      csp_ = ren_grow(t, R16(sizeof(FT)), (char **)&c_); grew_ = true;    \
    }                                                                     \
    c_->h.state = 0;                                                      \
    SETARGS;                                                              \
    r = FN(t, &c_->h, csp_, (ARG));                                       \
    if (UNLIKELY(r.st == PENDING)) {                                      \
      c_->h.resume = FN; c_->h.parent = hf;                               \
      SPILL; f->h.state = (ST); f->h.sp = sp;                             \
      return r;                                                           \
    }                                                                     \
    if (UNLIKELY(grew_)) ren_chunk_done(t);                               \
  }

/* The trampoline. Returns 1 when the task finished. */
static int step(task *t, uint64_t in) {
  frame *f = t->top;
  for (;;) {
    ren_ret r = f->resume(t, f, f->sp, in);
    if (r.st == PENDING) { ren_park_hook(t); return 0; }
    frame *p = f->parent;
    if (UNLIKELY(f->flags & FIRST_IN_CHUNK)) ren_chunk_done(t);
    if (!p) { t->done = 1; t->result = r.v; return 1; }
    t->top = f = p;
    in = r.v;
  }
}

static task *task_new(uint32_t seg, ren_resume body, uint32_t body_size) {
  task *t = malloc(sizeof(task) + seg);
  if (!t) abort();
  t->limit = t->frames + seg;
  t->chunk = t->spare = NULL;
  t->seg = seg;
  t->done = 0;
  t->keep_spare = 0;
  t->keep_at_park = 0;
  frame *f = (frame *)t->frames;
  f->resume = body;
  f->parent = NULL;
  f->state = 0;
  f->flags = 0;
  f->sp = t->frames + R16(body_size);
  if (f->sp > t->limit) abort();
  t->top = f;
  return t;
}
static void task_free(task *t) {
  if (t->spare) { free(t->spare); n_chunk_free++; }
  free(t);
}

/* ---------- the parked chain: serve -> read -> recv ---------- */
/* 32 B of locals each, after the 32 B header: 64 B frames, 192 B chain. */
typedef struct { frame h; uint64_t conn, total, n, _l; } serve_frame;
typedef struct { frame h; uint64_t conn, buf, len, _l; } read_frame;
typedef struct { frame h; uint64_t conn, call_id, len, _l; } recv_frame;
typedef struct { frame h; uint64_t d, a, b, c; } deep_frame;
_Static_assert(sizeof(serve_frame) == 64 && sizeof(read_frame) == 64 && sizeof(recv_frame) == 64, "64 B frames");

/* The "driver": recv never answers inline; it records the waiting task. */
static task **waiting;
static uint64_t n_waiting;

static ren_ret recv_fn(task *t, frame *hf, char *sp, uint64_t in) {
  recv_frame *f = (recv_frame *)hf;
  if (f->h.state == 1) return (ren_ret){DONE, in}; /* resumed with the reply */
  f->call_id = n_waiting;
  waiting[n_waiting++] = t;
  f->h.state = 1; f->h.sp = sp; t->top = hf;
  return (ren_ret){PENDING, 0};
}
static ren_ret read_fn(task *t, frame *hf, char *sp, uint64_t in) {
  read_frame *f = (read_frame *)hf;
  uint64_t conn, len;
  ren_ret r;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  conn = in; len = 0;
  CALL(recv_frame, recv_fn, c_->conn = conn, 0, 1, (f->conn = conn, f->len = len))
s1:
  return (ren_ret){DONE, r.v + len};
dispatch:
  conn = f->conn; len = f->len; r.v = in;
  (void)conn;
  goto s1;
}
/* A deep path that completes inline: depth d chain of deep frames. */
static ren_ret deep_fn(task *t, frame *hf, char *sp, uint64_t in) {
  deep_frame *f = (deep_frame *)hf;
  ren_ret r;
  if (in == 0) return (ren_ret){DONE, 1};
  CALL(deep_frame, deep_fn, (void)0, in - 1, 1, (void)0)
  return (ren_ret){DONE, r.v + 1};
}
static int deep_depth; /* 0: no excursion */
static ren_ret serve_fn(task *t, frame *hf, char *sp, uint64_t in) {
  serve_frame *f = (serve_frame *)hf;
  uint64_t conn, total;
  ren_ret r;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  conn = f->conn; total = 0;
  if (deep_depth) {
    CALL(deep_frame, deep_fn, (void)0, (uint64_t)deep_depth, 2, (f->conn = conn, f->total = total))
    if (r.v != (uint64_t)deep_depth + 1) abort();
  }
loop:
  CALL(read_frame, read_fn, (void)0, conn, 1, (f->conn = conn, f->total = total))
s1:
  if (r.v == 0) return (ren_ret){DONE, total};
  total += r.v;
  goto loop;
dispatch:
  conn = f->conn; total = f->total; r.v = in;
  if (f->h.state == 1) goto s1;
  abort(); /* state 2: deep never suspends */
}

/* ---------- memory accounting ---------- */
static uint64_t footprint(void) {
  task_vm_info_data_t vi;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) != KERN_SUCCESS) return 0;
  return vi.phys_footprint;
}
static uint64_t resident(void) {
  task_vm_info_data_t vi;
  mach_msg_type_number_t c = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &c) != KERN_SUCCESS) return 0;
  return vi.resident_size;
}
static uint64_t zone_in_use(void) {
  malloc_statistics_t s;
  malloc_zone_statistics(NULL, &s);
  return s.size_in_use;
}

static int park_bench(const char *policy, uint64_t N) {
  uint32_t chain = R16(sizeof(serve_frame)) + R16(sizeof(read_frame)) + R16(sizeof(recv_frame));
  uint32_t seg;
  bool keep_spare = false, keep_at_park = false;
  deep_depth = 0;
  if (!strcmp(policy, "today")) seg = R16(sizeof(serve_frame));
  else if (!strcmp(policy, "static")) seg = chain < INLINE_CAP ? chain : INLINE_CAP, keep_spare = true;
  else if (!strcmp(policy, "static_x")) seg = chain < INLINE_CAP ? chain : INLINE_CAP, keep_spare = true, deep_depth = 6;
  else if (!strcmp(policy, "static_xk")) seg = chain < INLINE_CAP ? chain : INLINE_CAP, keep_spare = true, keep_at_park = true, deep_depth = 6;
  else { fprintf(stderr, "unknown policy %s\n", policy); return 2; }
  task **ts = malloc(N * sizeof *ts);
  waiting = malloc(N * sizeof *waiting);
  /* Touch the bookkeeping arrays first, so they aren't in the delta. */
  memset(ts, 0, N * sizeof *ts);
  memset(waiting, 0, N * sizeof *waiting);
  uint64_t fp0 = footprint(), rs0 = resident(), z0 = zone_in_use();
  uint64_t sized = 0;
  for (uint64_t i = 0; i < N; i++) {
    task *t = task_new(seg, serve_fn, sizeof(serve_frame));
    t->keep_spare = keep_spare;
    t->keep_at_park = keep_at_park;
    ((serve_frame *)t->top)->conn = i;
    ts[i] = t;
    if (step(t, 0)) abort(); /* runs until it parks in recv */
  }
  uint64_t fp1 = footprint(), rs1 = resident(), z1 = zone_in_use();
  for (uint64_t i = 0; i < N; i++) {
    task *t = ts[i];
    sized += malloc_size(t);
    for (chunk *c = t->chunk; c; c = c->prev) sized += malloc_size(c);
    if (t->spare) sized += malloc_size(t->spare);
  }
  /* Replies: two rounds of data, then EOF; each task must total 2*conn+3. */
  bool ok = n_waiting == N;
  for (int round = 0; round < 3; round++) {
    uint64_t m = n_waiting;
    task **w = malloc(m * sizeof *w);
    memcpy(w, waiting, m * sizeof *w);
    n_waiting = 0;
    for (uint64_t k = 0; k < m; k++) {
      task *t = w[k];
      uint64_t conn = ((serve_frame *)t->frames)->conn;
      uint64_t reply = round == 2 ? 0 : conn + 1 + (uint64_t)round;
      int fin = step(t, reply);
      ok &= fin == (round == 2);
    }
    free(w);
  }
  for (uint64_t i = 0; i < N; i++) {
    ok &= ts[i]->done && ts[i]->result == 2 * i + 3 && ts[i]->chunk == NULL;
    task_free(ts[i]);
  }
  ok &= n_chunk_malloc == n_chunk_free;
  printf("PARK policy=%s N=%llu seg=%u task_alloc=%zu chunk_mallocs=%llu "
         "zone_B_per_task=%.1f malloc_size_B_per_task=%.1f footprint_B_per_task=%.1f resident_B_per_task=%.1f check=%s\n",
         policy, (unsigned long long)N, seg, sizeof(task) + seg, (unsigned long long)n_chunk_malloc,
         (double)(int64_t)(z1 - z0) / N, (double)sized / N, (double)(int64_t)(fp1 - fp0) / N,
         (double)(int64_t)(rs1 - rs0) / N, ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}

/* ---------- the chunk boundary ---------- */
typedef struct { frame h; uint64_t x, a, b, c; } leaf_frame;
typedef struct { frame h; uint64_t i, n, sum, _l; } body_frame;
NOINLINE static ren_ret leaf_fn(task *t, frame *hf, char *sp, uint64_t in) {
  (void)t; (void)hf; (void)sp;
  return (ren_ret){DONE, in * 3 + 1}; /* a world call answered inline */
}
static ren_ret bbody(task *t, frame *hf, char *sp, uint64_t in) {
  body_frame *f = (body_frame *)hf;
  uint64_t i, n, sum;
  ren_ret r;
  (void)in;
  if (f->h.state) abort();
  i = 0; n = f->n; sum = 0;
  for (; i < n; i++) {
    CALL(leaf_frame, leaf_fn, (void)0, i, 1, (void)0)
    sum += r.v;
  }
  return (ren_ret){DONE, sum};
}
static int bound_bench(const char *policy, uint64_t n, int reps) {
  uint32_t seg = R16(sizeof(body_frame));
  bool spare = false;
  if (!strcmp(policy, "inseg")) seg += R16(sizeof(leaf_frame));
  else if (!strcmp(policy, "spare")) spare = true;
  else if (strcmp(policy, "free")) { fprintf(stderr, "unknown policy %s\n", policy); return 2; }
  double ns[64];
  bool ok = true;
  uint64_t m0 = n_chunk_malloc;
  for (int k = 0; k < reps; k++) {
    task *t = task_new(seg, bbody, sizeof(body_frame));
    t->keep_spare = spare;
    ((body_frame *)t->top)->n = n;
    uint64_t t0 = now();
    int fin = step(t, 0);
    ns[k] = (double)(now() - t0) * tick_ns / n;
    ok &= fin && t->result == 3 * (n * (n - 1) / 2) + n && t->chunk == NULL;
    task_free(t);
  }
  double mallocs = (double)(n_chunk_malloc - m0) / ((double)n * reps);
  for (int i = 0; i < reps; i++)
    for (int j = i + 1; j < reps; j++)
      if (ns[j] < ns[i]) { double x = ns[i]; ns[i] = ns[j]; ns[j] = x; }
  ok &= n_chunk_malloc == n_chunk_free;
  printf("BOUND policy=%s n=%llu reps=%d ns_per_call=%.2f min=%.2f max=%.2f mallocs_per_call=%.4f check=%s\n", policy,
         (unsigned long long)n, reps, ns[reps / 2], ns[0], ns[reps - 1], mallocs, ok ? "ok" : "FAIL");
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  mach_timebase_info_data_t tb;
  mach_timebase_info(&tb);
  tick_ns = (double)tb.numer / tb.denom;
  if (argc >= 4 && !strcmp(argv[1], "park")) return park_bench(argv[2], strtoull(argv[3], 0, 10));
  if (argc >= 4 && !strcmp(argv[1], "bound")) return bound_bench(argv[2], strtoull(argv[3], 0, 10), 7);
  fprintf(stderr, "usage: %s park today|static|static_x|static_xk N | bound inseg|free|spare n\n", argv[0]);
  return 2;
}
