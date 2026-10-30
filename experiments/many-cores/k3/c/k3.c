/* K3, marking: one actor's state marked shared, against marked only at
   its edge. foundations.md decision 10 ("Whether a shared handler's state
   is marked is open") and Staging item 6, phase one of the many-cores
   experiments.

   The actor is one handler instance: a lock and its state,
     var subs: Array<Sub>     (subs.push(s); cleared when it reaches --subs-cap)
     var text: Rope           (an array of --chunks strings of --chunk-bytes)
   and one operation, edit(sub, at, delta), which pushes sub and applies a
   one-byte edit to the text. Callers take the instance for the call and
   run it where they are (decision 18, "No home core").

   Objects are the runtime model's (compiler.md "The runtime model",
   ren_rt.h): an 8-byte header whose 32-bit count is local (>0, plain),
   shared (<0, atomic, Lean's encoding) or immortal (0); rule U, an object
   changes in place only at a local count of 1; rule M, marking negates
   counts through everything reachable, stopping at what's already
   marked; rule H, a free goes to the heap its chunk names, through that
   heap's remote list when it's another thread's (mimalloc's delayed
   free). One heap per worker thread.

   --variant shared: the state is marked shared. What the operation stores
     into the instance (the new subs array, the new rope, the new chunk)
     is marked, and since a marked object is never unique, every push
     copies subs and every edit copies the rope and a chunk, counting each
     element atomically on the copy and on the old array's drop.
   --variant edge: the state keeps plain counts, since only the task
     holding the instance reaches it. Only what crosses the edge is marked:
     the Sub argument the instance keeps. Push and edit are in place.
*/
#define _DARWIN_C_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread/qos.h>
#endif

/* ---- objects ---- */

enum { TAG_STR = 1, TAG_ARR = 2, TAG_SUB = 3 };

typedef struct obj {
  int32_t rc;     /* >0 local, <0 shared (atomic), 0 immortal */
  uint16_t tag;
  uint8_t words;  /* size class, so a free needs no lookup */
  uint8_t pad;
} obj;

typedef struct { obj h; uint32_t len, cap; uint8_t b[]; } str;
typedef struct { obj h; uint32_t len, cap; obj *e[]; } arr;
typedef struct { obj h; uint64_t id; obj *name; } sub;

/* ---- the heap: per thread, chunks name their owner (rule H) ---- */

#define SMALL_WORDS 64
#define CHUNK_BYTES ((size_t)1 << 20)

typedef struct heap {
  void *free[SMALL_WORDS + 1];
  char *bump, *end;
  _Atomic(void *) remote;  /* frees from other threads, any size */
  uint64_t allocs, frees, remote_frees;  /* by the thread using this heap */
  char pad[64];
} heap;

typedef struct { heap *owner; } chunk_hdr;

static _Thread_local heap *cur;

static void *heap_slow(heap *h, size_t words) {
  /* drain the remote list first */
  void *r = atomic_exchange_explicit(&h->remote, NULL, memory_order_acquire);
  while (r) {
    void *next = *(void **)((char *)r + 8);
    size_t w = ((obj *)r)->words;
    *(void **)r = h->free[w];
    h->free[w] = r;
    r = next;
  }
  if (h->free[words]) {
    void *p = h->free[words];
    h->free[words] = *(void **)p;
    return p;
  }
  size_t bytes = words * 8;
  if (h->bump == NULL || h->bump + bytes > h->end) {
    void *c;
    if (posix_memalign(&c, CHUNK_BYTES, CHUNK_BYTES) != 0)
      abort();
    ((chunk_hdr *)c)->owner = h;
    h->bump = (char *)c + 64;
    h->end = (char *)c + CHUNK_BYTES;
  }
  void *p = h->bump;
  h->bump += bytes;
  return p;
}

static inline obj *alloc_obj(size_t bytes, uint16_t tag) {
  size_t words = (bytes + 7) / 8;
  if (words < 2) words = 2;  /* a remote free uses word 1 as its link */
  if (words > SMALL_WORDS) {
    fprintf(stderr, "object of %zu words is too big\n", words);
    abort();
  }
  heap *h = cur;
  void *p = h->free[words];
  if (p)
    h->free[words] = *(void **)p;
  else
    p = heap_slow(h, words);
  h->allocs++;
  obj *o = p;
  o->rc = 1;
  o->tag = tag;
  o->words = (uint8_t)words;
  o->pad = 0;
  return o;
}

static inline void free_obj(obj *o) {
  heap *h = cur;
  h->frees++;
  heap *owner = ((chunk_hdr *)((uintptr_t)o & ~(CHUNK_BYTES - 1)))->owner;
  if (owner == h) {
    *(void **)o = h->free[o->words];
    h->free[o->words] = o;
  } else {
    h->remote_frees++;
    void **link = (void **)((char *)o + 8);  /* keep the header's size */
    void *head = atomic_load_explicit(&owner->remote, memory_order_relaxed);
    do
      *link = head;
    while (!atomic_compare_exchange_weak_explicit(
        &owner->remote, &head, o, memory_order_release, memory_order_relaxed));
  }
}

/* ---- counting (ren_rt.h's ren_dup / ren_drop under -DREN_RC_SHARED) ---- */

static inline int32_t rc_of(obj *o) {
  return __atomic_load_n(&o->rc, __ATOMIC_RELAXED);
}

static void rc_drop(obj *o);

static void free_tree(obj *o) {
  switch (o->tag) {
  case TAG_ARR: {
    arr *a = (arr *)o;
    for (uint32_t i = 0; i < a->len; i++)
      rc_drop(a->e[i]);
    break;
  }
  case TAG_SUB:
    rc_drop(((sub *)o)->name);
    break;
  default:
    break;
  }
  free_obj(o);
}

static inline void rc_dup(obj *o) {
  int32_t rc = rc_of(o);
  if (__builtin_expect(rc > 0, 1))
    o->rc = rc + 1;
  else if (rc != 0)
    __atomic_fetch_sub(&o->rc, 1, __ATOMIC_RELAXED);  /* shared: more negative */
}

static void rc_drop(obj *o) {
  int32_t rc = rc_of(o);
  if (__builtin_expect(rc > 1, 1))
    o->rc = rc - 1;
  else if (rc == 1)
    free_tree(o);
  else if (rc != 0) {
    /* Lean's lean_dec_ref_cold: -1 is the last reference */
    if (__atomic_fetch_add(&o->rc, 1, __ATOMIC_RELEASE) == -1) {
      __atomic_thread_fence(__ATOMIC_ACQUIRE);
      free_tree(o);
    }
  }
}

static inline bool is_unique(obj *o) { return rc_of(o) == 1; }

/* rule M: ren_mark_shared, with a fixed stack (the runtime's mallocs one) */
static void mark_shared(obj *o) {
  obj *todo[256];
  size_t n = 0;
  if (rc_of(o) <= 0)
    return;
  todo[n++] = o;
  while (n) {
    obj *x = todo[--n];
    if (rc_of(x) <= 0)
      continue;
    x->rc = -x->rc;
    if (x->tag == TAG_ARR) {
      arr *a = (arr *)x;
      for (uint32_t i = 0; i < a->len; i++)
        if (n < 256) todo[n++] = a->e[i]; else abort();
    } else if (x->tag == TAG_SUB) {
      todo[n++] = ((sub *)x)->name;
    }
  }
}

/* ---- values ---- */

static arr *arr_new(uint32_t cap) {
  arr *a = (arr *)alloc_obj(sizeof(arr) + cap * sizeof(obj *), TAG_ARR);
  a->len = 0;
  a->cap = cap;
  return a;
}

static str *str_new(uint32_t len) {
  str *s = (str *)alloc_obj(sizeof(str) + len, TAG_STR);
  s->len = s->cap = len;
  return s;
}

static uint32_t subs_cap_limit, n_chunks, chunk_bytes;

/* subs.push(s), consuming both: in place when unique, else a copy that
   counts every element (rule U) */
static arr *arr_push(arr *a, obj *x) {
  if (is_unique(&a->h)) {
    if (a->len < a->cap) {
      a->e[a->len++] = x;
      return a;
    }
    uint32_t cap = a->cap * 2;
    if (cap > subs_cap_limit) cap = subs_cap_limit;
    arr *b = arr_new(cap);
    memcpy(b->e, a->e, a->len * sizeof(obj *));  /* moved, no counts */
    b->len = a->len;
    free_obj(&a->h);
    b->e[b->len++] = x;
    return b;
  }
  uint32_t cap = a->len < a->cap ? a->cap : a->cap * 2;
  if (cap > subs_cap_limit) cap = subs_cap_limit;
  arr *b = arr_new(cap);
  for (uint32_t i = 0; i < a->len; i++) {
    rc_dup(a->e[i]);
    b->e[i] = a->e[i];
  }
  b->len = a->len;
  rc_drop(&a->h);
  b->e[b->len++] = x;
  return b;
}

/* subs.clear() */
static arr *arr_clear(arr *a) {
  if (is_unique(&a->h)) {
    for (uint32_t i = 0; i < a->len; i++)
      rc_drop(a->e[i]);
    a->len = 0;
    return a;
  }
  arr *b = arr_new(a->cap);
  rc_drop(&a->h);
  return b;
}

/* text.apply(at, delta): rope[at / chunk_bytes][at % chunk_bytes] += delta */
static arr *rope_apply(arr *r, uint32_t at, uint8_t delta) {
  uint32_t ci = at / chunk_bytes, off = at % chunk_bytes;
  if (!is_unique(&r->h)) {
    arr *b = arr_new(r->cap);
    for (uint32_t i = 0; i < r->len; i++) {
      rc_dup(r->e[i]);
      b->e[i] = r->e[i];
    }
    b->len = r->len;
    rc_drop(&r->h);
    r = b;
  }
  str *c = (str *)r->e[ci];
  if (!is_unique(&c->h)) {
    str *d = str_new(c->len);
    memcpy(d->b, c->b, c->len);
    rc_drop(&c->h);
    c = d;
    r->e[ci] = &c->h;
  }
  c->b[off] = (uint8_t)(c->b[off] + delta);
  return r;
}

/* ---- the instance ---- */

typedef enum { LOCK_UNFAIR, LOCK_SPIN } lock_kind;
static lock_kind lockk = LOCK_UNFAIR;

typedef struct {
  _Alignas(128) os_unfair_lock ul;
  atomic_int spin;
  bool shared;  /* the variant */
  arr *subs;
  arr *text;
  uint64_t ops, pushes, id_sum;
} instance;

static inline void take(instance *in) {
  if (lockk == LOCK_UNFAIR) {
    os_unfair_lock_lock(&in->ul);
    return;
  }
  for (;;) {
    if (!atomic_exchange_explicit(&in->spin, 1, memory_order_acquire))
      return;
    while (atomic_load_explicit(&in->spin, memory_order_relaxed))
      __builtin_arm_yield();
  }
}

static inline void let_go(instance *in) {
  if (lockk == LOCK_UNFAIR)
    os_unfair_lock_unlock(&in->ul);
  else
    atomic_store_explicit(&in->spin, 0, memory_order_release);
}

/* edit(s, at, delta): the operation. s is owned, moved in. */
static void op_edit(instance *in, sub *s, uint32_t at, uint8_t delta) {
  take(in);
  in->ops++;
  in->pushes++;
  in->id_sum += s->id;
  arr *subs = in->subs;          /* swap-out: the slot's reference */
  if (subs->len == subs_cap_limit)
    subs = arr_clear(subs);
  if (!in->shared)
    mark_shared(&s->h);          /* edge: the argument it keeps */
  subs = arr_push(subs, &s->h);
  arr *text = rope_apply(in->text, at, delta);
  if (in->shared) {              /* everything stored is marked */
    mark_shared(&subs->h);
    mark_shared(&text->h);
  }
  in->subs = subs;
  in->text = text;
  let_go(in);
}

/* ---- the run ---- */

static inline uint64_t xs(uint64_t *s) {
  uint64_t x = *s;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  *s = x;
  return x * 0x2545F4914F6CDD1DULL;
}

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static mach_timebase_info_data_t tb;
static inline uint64_t ticks(void) { return mach_absolute_time(); }

#define MAX_WORKERS 64
#define SAMPLE_EVERY 16
#define MAX_SAMPLES (1u << 20)

typedef struct {
  _Alignas(128) int id;
  uint64_t seed;
  uint64_t ops;          /* done */
  uint64_t id_sum;
  uint8_t *tally;        /* per text byte, sum of deltas mod 256 */
  uint32_t *lat;         /* sampled latencies, in ticks */
  size_t nlat;
  uint32_t think;
} worker;

static instance inst;
static heap heaps[MAX_WORKERS + 1];
static atomic_int go, stop;
static uint64_t fixed_ops;  /* 0: run until stop */

static void *work(void *arg) {
  worker *w = arg;
  cur = &heaps[w->id];
#ifdef __APPLE__
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
  uint32_t text_len = n_chunks * chunk_bytes;
  uint64_t seq = 0;
  while (!atomic_load_explicit(&go, memory_order_acquire))
    ;
  for (;;) {
    if (fixed_ops ? seq >= fixed_ops
                  : atomic_load_explicit(&stop, memory_order_relaxed))
      break;
    uint64_t r = xs(&w->seed);
    uint32_t at = (uint32_t)(r % text_len);
    uint8_t delta = (uint8_t)(r >> 40) | 1;
    uint64_t id = ((uint64_t)(w->id + 1) << 40) | seq;
    /* the argument: a Sub record with a name string, built by the caller */
    sub *s = (sub *)alloc_obj(sizeof(sub), TAG_SUB);
    s->id = id;
    str *nm = str_new(16);
    memcpy(nm->b, "subscriber-0000", 16);
    nm->b[11] = (uint8_t)('0' + (seq & 7));
    s->name = &nm->h;
    for (volatile uint32_t k = 0; k < w->think; k++)
      ;
    if (seq % SAMPLE_EVERY == 0 && w->nlat < MAX_SAMPLES) {
      uint64_t t0 = ticks();
      op_edit(&inst, s, at, delta);
      w->lat[w->nlat++] = (uint32_t)(ticks() - t0);
    } else {
      op_edit(&inst, s, at, delta);
    }
    w->tally[at] = (uint8_t)(w->tally[at] + delta);
    w->id_sum += id;
    seq++;
  }
  w->ops = seq;
  return NULL;
}

static int cmp_u32(const void *a, const void *b) {
  uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
  return x < y ? -1 : x > y;
}
static int cmp_d(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return x < y ? -1 : x > y;
}

static uint8_t init_byte(uint32_t i, uint32_t j) {
  return (uint8_t)(i * 131 + j * 7);
}

typedef struct {
  double ops_s;
  double p50_ns, p99_ns;
  uint64_t digest;
  bool ok;
  uint64_t remote_frees, ops;
} rep_result;

static rep_result one_rep(bool shared, int nw, unsigned ms, uint64_t seed,
                          uint32_t think) {
  rep_result rr = {0};
  cur = &heaps[MAX_WORKERS];
  uint64_t a0 = 0, f0 = 0, rf0 = 0;
  for (int i = 0; i <= MAX_WORKERS; i++) {
    a0 += heaps[i].allocs;
    f0 += heaps[i].frees;
    rf0 += heaps[i].remote_frees;
  }
  /* the state, built by the installer; marked when tasks may share it */
  inst.shared = shared;
  inst.subs = arr_new(4);
  arr *rope = arr_new(n_chunks);
  for (uint32_t i = 0; i < n_chunks; i++) {
    str *c = str_new(chunk_bytes);
    for (uint32_t j = 0; j < chunk_bytes; j++)
      c->b[j] = init_byte(i, j);
    rope->e[i] = &c->h;
  }
  rope->len = n_chunks;
  inst.text = rope;
  if (shared) {
    mark_shared(&inst.subs->h);
    mark_shared(&inst.text->h);
  }
  inst.ops = inst.pushes = inst.id_sum = 0;
  atomic_store(&go, 0);
  atomic_store(&stop, 0);

  uint32_t text_len = n_chunks * chunk_bytes;
  worker *ws = aligned_alloc(128, ((size_t)nw * sizeof(worker) + 127) / 128 * 128);
  memset(ws, 0, (size_t)nw * sizeof(worker));
  pthread_t th[MAX_WORKERS];
  for (int i = 0; i < nw; i++) {
    ws[i].id = i;
    ws[i].seed = seed ^ (0x9E3779B97F4A7C15ULL * (uint64_t)(i + 1));
    if (ws[i].seed == 0) ws[i].seed = 1;
    ws[i].tally = calloc(text_len, 1);
    ws[i].lat = malloc(MAX_SAMPLES * sizeof(uint32_t));
    ws[i].think = think;
    pthread_create(&th[i], NULL, work, &ws[i]);
  }
  usleep(20000);  /* let them reach the gate */
  uint64_t t0 = now_ns();
  atomic_store_explicit(&go, 1, memory_order_release);
  if (!fixed_ops) {
    usleep(ms * 1000u);
    atomic_store_explicit(&stop, 1, memory_order_relaxed);
  }
  for (int i = 0; i < nw; i++)
    pthread_join(th[i], NULL);
  uint64_t t1 = now_ns();

  /* check: counters add up, text is the initial text plus every delta */
  uint64_t ops = 0, id_sum = 0;
  size_t nlat = 0;
  for (int i = 0; i < nw; i++) {
    ops += ws[i].ops;
    id_sum += ws[i].id_sum;
    nlat += ws[i].nlat;
  }
  bool ok = inst.ops == ops && inst.pushes == ops && inst.id_sum == id_sum &&
            inst.subs->len == (ops == 0 ? 0 : (ops - 1) % subs_cap_limit + 1);
  uint64_t h = 1469598103934665603ULL;
  for (uint32_t i = 0; i < n_chunks; i++) {
    str *c = (str *)inst.text->e[i];
    for (uint32_t j = 0; j < chunk_bytes; j++) {
      uint8_t want = init_byte(i, j);
      for (int k = 0; k < nw; k++)
        want = (uint8_t)(want + ws[k].tally[i * chunk_bytes + j]);
      if (c->b[j] != want) ok = false;
      h = (h ^ c->b[j]) * 1099511628211ULL;
    }
  }
  h = (h ^ ops) * 1099511628211ULL;
  h = (h ^ id_sum) * 1099511628211ULL;
  /* the shared variant's state is all marked, the edge variant's isn't */
  if (shared && (rc_of(&inst.subs->h) >= 0 || rc_of(&inst.text->h) >= 0))
    ok = false;
  if (!shared && (rc_of(&inst.subs->h) != 1 || rc_of(&inst.text->h) != 1))
    ok = false;

  /* latencies */
  uint32_t *all = malloc((nlat ? nlat : 1) * sizeof(uint32_t));
  size_t k = 0;
  for (int i = 0; i < nw; i++) {
    memcpy(all + k, ws[i].lat, ws[i].nlat * sizeof(uint32_t));
    k += ws[i].nlat;
  }
  qsort(all, nlat, sizeof(uint32_t), cmp_u32);
  double tick_ns = (double)tb.numer / tb.denom;
  rr.p50_ns = nlat ? all[nlat / 2] * tick_ns : 0;
  rr.p99_ns = nlat ? all[(nlat * 99) / 100] * tick_ns : 0;
  free(all);

  /* end the instance: drop its state; nothing may leak */
  cur = &heaps[MAX_WORKERS];
  rc_drop(&inst.subs->h);
  rc_drop(&inst.text->h);
  uint64_t a1 = 0, f1 = 0, rf1 = 0;
  for (int i = 0; i <= MAX_WORKERS; i++) {
    a1 += heaps[i].allocs;
    f1 += heaps[i].frees;
    rf1 += heaps[i].remote_frees;
  }
  if (a1 - a0 != f1 - f0) {
    fprintf(stderr, "leak: %" PRIu64 " allocs, %" PRIu64 " frees\n", a1 - a0,
            f1 - f0);
    ok = false;
  }
  for (int i = 0; i < nw; i++) {
    free(ws[i].tally);
    free(ws[i].lat);
  }
  free(ws);
  rr.ops_s = (double)ops / ((double)(t1 - t0) / 1e9);
  rr.digest = h;
  rr.ok = ok;
  rr.remote_frees = rf1 - rf0;
  rr.ops = ops;
  return rr;
}

static void usage(void) {
  fprintf(stderr,
          "k3 --variant shared|edge [--workers N] [--ms M | --ops N] [--reps R]\n"
          "   [--lock unfair|spin] [--subs-cap 32] [--chunks 16]\n"
          "   [--chunk-bytes 64] [--think 0] [--seed S]\n");
  exit(2);
}

int main(int argc, char **argv) {
  const char *variant = NULL;
  int nw = 8, reps = 5;
  unsigned ms = 1000;
  uint64_t seed = 42;
  uint32_t think = 0;
  subs_cap_limit = 32;
  n_chunks = 16;
  chunk_bytes = 64;
  for (int i = 1; i < argc; i++) {
#define ARG(name) (strcmp(argv[i], name) == 0 && i + 1 < argc)
    if (ARG("--variant")) variant = argv[++i];
    else if (ARG("--workers")) nw = atoi(argv[++i]);
    else if (ARG("--ms")) ms = (unsigned)atoi(argv[++i]);
    else if (ARG("--ops")) fixed_ops = strtoull(argv[++i], NULL, 10);
    else if (ARG("--reps")) reps = atoi(argv[++i]);
    else if (ARG("--subs-cap")) subs_cap_limit = (uint32_t)atoi(argv[++i]);
    else if (ARG("--chunks")) n_chunks = (uint32_t)atoi(argv[++i]);
    else if (ARG("--chunk-bytes")) chunk_bytes = (uint32_t)atoi(argv[++i]);
    else if (ARG("--think")) think = (uint32_t)atoi(argv[++i]);
    else if (ARG("--seed")) seed = strtoull(argv[++i], NULL, 10);
    else if (ARG("--lock")) {
      const char *l = argv[++i];
      lockk = strcmp(l, "spin") == 0 ? LOCK_SPIN : LOCK_UNFAIR;
    } else usage();
  }
  if (!variant || (strcmp(variant, "shared") && strcmp(variant, "edge")) ||
      nw < 1 || nw > MAX_WORKERS || reps < 1 || subs_cap_limit < 4 ||
      subs_cap_limit > 62 || n_chunks < 1 || n_chunks > 62 ||
      chunk_bytes < 1 || chunk_bytes > 400)
    usage();
  bool shared = strcmp(variant, "shared") == 0;
  mach_timebase_info(&tb);
  inst.ul = OS_UNFAIR_LOCK_INIT;
#ifdef __APPLE__
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif

  double *t = calloc((size_t)reps, sizeof(double));
  double *p50 = calloc((size_t)reps, sizeof(double));
  double *p99 = calloc((size_t)reps, sizeof(double));
  bool ok = true;
  uint64_t digest = 0, rfrees = 0, allops = 0;
  for (int r = 0; r < reps; r++) {
    rep_result rr = one_rep(shared, nw, ms, seed, think);
    t[r] = rr.ops_s;
    p50[r] = rr.p50_ns;
    p99[r] = rr.p99_ns;
    if (r == 0) digest = rr.digest;
    else if (fixed_ops && rr.digest != digest) ok = false;
    ok = ok && rr.ok;
    rfrees += rr.remote_frees;
    allops += rr.ops;
  }
  qsort(t, (size_t)reps, sizeof(double), cmp_d);
  qsort(p50, (size_t)reps, sizeof(double), cmp_d);
  qsort(p99, (size_t)reps, sizeof(double), cmp_d);
  printf("k3 impl=c variant=%s lock=%s workers=%d reps=%d %s=%" PRIu64
         " subs_cap=%u chunks=%u chunk_bytes=%u think=%u"
         " ops_s_median=%.0f ops_s_min=%.0f ops_s_max=%.0f"
         " p50_ns=%.0f p99_ns=%.0f remote_frees_per_op=%.2f digest=%016" PRIx64
         " ok=%d\n",
         variant, lockk == LOCK_SPIN ? "spin" : "unfair", nw, reps,
         fixed_ops ? "ops_per_worker" : "ms", fixed_ops ? fixed_ops : ms,
         subs_cap_limit, n_chunks, chunk_bytes, think, t[reps / 2], t[0],
         t[reps - 1], p50[reps / 2], p99[reps / 2],
         allops ? (double)rfrees / (double)allops : 0.0,
         fixed_ops ? digest : 0, ok ? 1 : 0);
  return ok ? 0 : 1;
}
