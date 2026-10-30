/* The Ren runtime's functions (ren_rt.h says what each does). */

#ifdef REN_STATS
ren_stats_t ren_stats;
#endif

char *ren_stack_limit;
const ren_site *ren_overflow_site;
const ren_site *ren_here;

/* ---- panics ---- */

const char *const *ren_texts;

/* The number at [*p] in a site's pieces, and [*p] moved past it. */
static uint64_t ren_site_num(const unsigned char **p) {
  uint64_t n = 0;
  int shift = 0;
  unsigned char c;
  do {
    c = *(*p)++;
    n |= (uint64_t)(c & 0x7f) << shift;
    shift += 7;
  } while (c & 0x80);
  return n;
}

static void ren_repeat(int c, uint64_t n) {
  for (uint64_t i = 0; i < n; i++) fputc(c, stderr);
}

_Noreturn void ren_panic(const ren_site *site, const char *msg) {
  ren_panic_help(site, msg, NULL);
}

_Noreturn void ren_panic_help(const ren_site *site, const char *msg,
                              const char *help) {
  fflush(stdout);
  ren_site_print(site, msg, help);
  exit(1);
}

void ren_site_print(const ren_site *site, const char *msg, const char *help) {
  const unsigned char *p = site->ops;
  for (;;) {
    switch (*p++) {
    case 1:
      fputs(ren_texts[ren_site_num(&p)], stderr);
      break;
    case 2:
      ren_repeat(' ', ren_site_num(&p));
      break;
    case 3: {
      int c = *p++;
      ren_repeat(c, ren_site_num(&p));
      break;
    }
    case 4:
      fprintf(stderr, "%llu", (unsigned long long)ren_site_num(&p));
      break;
    case 5:
      fputs(msg, stderr);
      break;
    case 6: {
      const char *t = ren_texts[ren_site_num(&p)];
      uint64_t i = ren_site_num(&p);
      uint64_t n = ren_site_num(&p);
      fwrite(t + i, 1, n, stderr);
      break;
    }
    case 7: {
      uint64_t n = ren_site_num(&p);
      const char *recv = ren_texts[ren_site_num(&p)];
      if (help) {
        ren_repeat(' ', n);
        fputs(" help: ", stderr);
        for (const char *h = help; *h; h++)
          if (*h == '\002')
            fputs(recv, stderr);
          else
            fputc(*h, stderr);
        fputc('\n', stderr);
      }
      break;
    }
    case 0:
      return;
    default:
      exit(1);
    }
  }
}

_Noreturn void ren_stack_overflowed(void) {
  ren_panic(ren_overflow_site,
            "the stack overflowed: a function called itself too deeply");
}

/* ---- memory ---- */

#ifdef REN_STATS
void ren_count_alloc(int64_t bytes) {
  ren_stats.allocs++;
  ren_stats.live_bytes += bytes;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
}
#endif

_Noreturn static void ren_out_of_memory(void) {
  fflush(stdout);
  fputs("error: out of memory\n", stderr);
  exit(1);
}

static void *ren_malloc(size_t bytes) {
  void *p = malloc(bytes);
  if (p == NULL)
    ren_out_of_memory();
  return p;
}

REN_THREAD_LOCAL ren_heap_t ren_heap;

void *ren_alloc_big(size_t bytes) { return ren_malloc(bytes); }

/* The list for [words] is empty: a bump from the chunk, or a new chunk
   first. What's left of the old one is too small for this object, and
   is lost; at most [REN_SMALL_WORDS] words of each chunk. */
void *ren_alloc_slow(size_t words) {
  size_t bytes = words * 8;
  if ((size_t)(ren_heap.end - ren_heap.bump) < bytes) {
    ren_heap.bump = ren_malloc(REN_CHUNK_BYTES);
    ren_heap.end = ren_heap.bump + REN_CHUNK_BYTES;
  }
  void *p = ren_heap.bump;
  ren_heap.bump += bytes;
  return p;
}

/* The bytes an element of [a] takes: a sized type's width, or its
   stride's words. */
static size_t ren_elem_bytes(ren_obj *a) {
  return a->nfields ? ren_elem_size[a->nfields]
                    : (size_t)ren_stride(a) * sizeof(ren_val);
}

static ren_obj *ren_alloc_array_c(int64_t len, int64_t cap, uint8_t objs,
                                  uint32_t stride, uint8_t kind) {
  ren_array *a = ren_alloc_bytes(sizeof(ren_array));
  cap = cap > len ? cap : len;
  cap = cap > 0 ? cap : 1;
  a->h.nfields = kind;
  a->stride = stride > 1 ? stride : 1;
  size_t bytes = (size_t)cap * ren_elem_bytes(&a->h);
  a->data = ren_malloc(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)(sizeof(ren_array) + bytes));
#endif
  a->h.rc = 1;
  a->h.tag = REN_TAG_ARRAY;
  a->h.objs = objs;
  a->len = len;
  a->cap = cap;
  a->root = NULL;
  return &a->h;
}

ren_obj *ren_array_reserve(int64_t cap, uint8_t objs, uint32_t stride) {
  return ren_alloc_array_c(0, cap, objs, stride, 0);
}

ren_obj *ren_alloc_array(int64_t len, bool boxed_elems) {
  return ren_alloc_array_c(len, len, boxed_elems, 0, 0);
}

ren_obj *ren_alloc_array_n(int64_t len, uint32_t stride, uint8_t objs) {
  return ren_alloc_array_c(len, len, objs, stride, 0);
}

/* Each object the [n] elements of [a]'s kind from [e] hold, [x] in
   [body]: a counted word's element, or the slots of an element of
   structs that [a]'s mask says (ren_rt.h, [ren_obj]'s [objs]). */
#define REN_ELEM_OBJS(a, e, n, x, body)                                        \
  do {                                                                         \
    int64_t ren_k_ = ren_stride(a), ren_n_ = (n);                              \
    ren_val *ren_e_ = (e);                                                     \
    unsigned ren_m_ = (a)->objs;                                               \
    if (ren_m_ == 0)                                                           \
      break;                                                                   \
    if (ren_k_ == 1)                                                           \
      for (int64_t ren_i_ = 0; ren_i_ < ren_n_; ren_i_++) {                    \
        ren_obj *x = ren_e_[ren_i_].o;                                         \
        body;                                                                  \
      }                                                                        \
    else                                                                       \
      for (int64_t ren_i_ = 0; ren_i_ < ren_n_; ren_i_++)                      \
        for (unsigned m = ren_m_; m != 0; m &= m - 1) {                        \
          ren_obj *x = ren_e_[ren_i_ * ren_k_ + __builtin_ctz(m)].o;           \
          body;                                                                \
        }                                                                      \
  } while (0)

ren_obj *ren_alloc_array_k(int64_t len, uint8_t kind) {
  return ren_alloc_array_c(len, len, false, 0, kind);
}

ren_obj *ren_array_reserve_k(int64_t cap, uint8_t kind) {
  return ren_alloc_array_c(0, cap, false, 0, kind);
}

ren_obj *ren_alloc_array_d(int64_t len, ren_obj *d) {
  return ren_alloc_array_c(len, len, ren_desc_counted(d), 0, ren_desc_elem(d));
}

ren_obj *ren_array_reserve_d(int64_t cap, ren_obj *d) {
  return ren_alloc_array_c(0, cap, ren_desc_counted(d), 0, ren_desc_elem(d));
}

/* The memory an owner of room [cap] takes: its header and its bytes. */
static size_t ren_str_size(int64_t cap) { return sizeof(ren_str) + (size_t)cap; }

/* An owner of [len] bytes, not yet written, with room for [cap] (at
   least [len]), rounded up to the word its memory ends in, which is
   room it has anyway. */
static ren_obj *ren_alloc_str_cap(int64_t len, int64_t cap) {
  cap = (int64_t)(ren_words(ren_str_size(cap)) * 8 - sizeof(ren_str));
  size_t bytes = ren_str_size(cap);
  ren_str *s = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_STR;
  s->h.nfields = 0;
  s->h.objs = 0;
  s->len = len;
  s->data = s->bytes;
  s->cap = cap;
  return &s->h;
}

static ren_obj *ren_alloc_str(int64_t len) { return ren_alloc_str_cap(len, len); }

/* Objects whose count reached 0, waiting to have their fields dropped
   and be freed. Freeing goes through this list rather than recursing,
   so dropping a long list doesn't overflow the stack. Lean's
   `lean_dec_ref_cold` keeps the same list (runtime/object.cpp:311-331,
   `push_back`), threaded through the freed objects' headers; this one
   is an array, which is simpler and costs a little more. */
typedef struct {
  ren_obj **objs;
  size_t len, cap;
} ren_todo_t;
static REN_THREAD_LOCAL ren_todo_t ren_todo;

static void ren_todo_push(ren_todo_t *t, ren_obj *o) {
  if (t->len == t->cap) {
    t->cap = t->cap ? t->cap * 2 : 256;
    t->objs = realloc(t->objs, t->cap * sizeof(ren_obj *));
    if (t->objs == NULL) {
      fflush(stdout);
      fputs("error: out of memory\n", stderr);
      exit(1);
    }
  }
  t->objs[t->len++] = o;
}

#ifndef REN_RC_SHARED
_Noreturn void ren_shared_count(ren_obj *o) {
  (void)o;
  fflush(stdout);
  fputs("error: an object's count is negative, which marks it shared, "
        "and nothing shares one yet\n",
        stderr);
  abort();
}
#endif

/* One reference fewer on a child of an object being freed. */
static void ren_release(ren_todo_t *t, ren_obj *o) {
#if defined(REN_RC_SHARED)
  if (ren_is_scalar(o))
    return;
  int32_t rc = ren_rc(o);
  if (rc > 1) {
    REN_STAT(drops);
    o->rc = rc - 1;
  } else if (rc == 1) {
    REN_STAT(drops);
    ren_todo_push(t, o);
  } else if (rc != 0 && __atomic_add_fetch(&o->rc, 1, __ATOMIC_ACQ_REL) == 0) {
    ren_todo_push(t, o);
  }
#elif defined(REN_RC_ATOMIC)
  if (ren_is_scalar(o) || ren_rc(o) == 0)
    return;
  REN_STAT(drops);
  if (__atomic_sub_fetch(&o->rc, 1, __ATOMIC_RELEASE) == 0) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    ren_todo_push(t, o);
  }
#else
  if (ren_is_scalar(o) || o->rc == 0)
    return;
  REN_STAT(drops);
  if (o->rc > 1)
    o->rc--;
  else if (o->rc == 1)
    ren_todo_push(t, o);
  else
    ren_shared_count(o);
#endif
}

/* Free one object whose count reached 0, its children going on the
   list. */
static void ren_free_one(ren_todo_t *t, ren_obj *o) {
  int64_t bytes = 0; /* what it held, for the statistics */
  size_t size = 0;   /* its own memory */
  switch (o->tag) {
  default: { /* a constructor */
    ren_val *fs = ren_fields(o);
    for (uint64_t m = ren_ctor_objs(o); m != 0; m &= m - 1)
      ren_release(t, fs[__builtin_ctzll(m)].o);
    size = ren_ctor_size(o->nfields);
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_DESC: {
    ren_desc *d = (ren_desc *)o;
    for (uint16_t i = 0; i < d->nargs; i++)
      ren_release(t, &d->args[i]->h);
    size = sizeof(ren_desc) + d->nargs * sizeof(ren_desc *);
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_ARRAY: {
    ren_array *a = (ren_array *)o;
    if (a->root != NULL) { /* a slice: its root holds the elements */
      ren_release(t, a->root);
      size = sizeof(ren_array);
      bytes = (int64_t)size;
      break;
    }
    REN_ELEM_OBJS(o, a->data, a->len, x, ren_release(t, x));
    bytes = (int64_t)(sizeof(ren_array) + (size_t)a->cap * ren_elem_bytes(o));
    free(a->data);
    size = sizeof(ren_array);
    break;
  }
  case REN_TAG_STR: {
    ren_str *s = (ren_str *)o;
    if (ren_str_is_slice(o)) {
      ren_release(t, s->root);
      size = sizeof(ren_str);
    } else
      size = ren_str_size(s->cap);
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_MAP: {
    ren_map *m = (ren_map *)o;
    for (int64_t e = 0; e < m->used; e++) {
      ren_val *ent = &m->entries[e * m->width];
      if (ent[0].i == 0)
        continue;
      if (o->objs & 1)
        ren_release(t, ent[1].o);
      if ((o->objs & 2) && m->width > 2)
        ren_release(t, ent[2].o);
    }
    bytes = (int64_t)sizeof(ren_map) +
            m->cap * m->width * (int64_t)sizeof(ren_val) +
            (m->shift ? ((int64_t)1 << m->shift) * (int64_t)sizeof(int32_t) : 0);
    free(m->entries);
    free(m->index);
    size = sizeof(ren_map);
    break;
  }
  }
#ifdef REN_STATS
  ren_stats.frees++;
  ren_stats.live_bytes -= bytes;
#else
  (void)bytes;
#endif
  ren_free_bytes(o, size);
}

void ren_free(ren_obj *o) {
  /* the list's address once, since a thread-local one costs a call on
     Mach-O to find */
  ren_todo_t *t = &ren_todo;
  ren_free_one(t, o);
  while (t->len > 0)
    ren_free_one(t, t->objs[--t->len]);
}

#ifdef REN_RC_SHARED
/* A shared count runs down from -1: one more reference is one lower,
   relaxed as in `lean_inc_ref_n` (lean.h:722), since whoever dups
   already holds a reference that keeps the object alive. */
void ren_dup_shared(ren_obj *o) {
  __atomic_fetch_sub(&o->rc, 1, __ATOMIC_RELAXED);
}

/* One fewer, and the thread that takes the last frees it: acq_rel, so
   every other thread's writes before its drop happen before the free
   (runtime/object.cpp:461, `lean_dec_ref_cold`). */
void ren_drop_shared(ren_obj *o) {
  if (__atomic_add_fetch(&o->rc, 1, __ATOMIC_ACQ_REL) == 0)
    ren_free(o);
}

/* `lean_mark_mt` (runtime/object.cpp:663): an object and all it reaches
   that one thread owns get their counts negated. One already shared or
   never freed stops the walk, since what it reaches is too. It runs
   before the object is published, so the plain writes are seen by the
   thread that receives it through whatever hands it over. */
void ren_mark_shared(ren_obj *o) {
  if (ren_is_scalar(o) || o->rc <= 0)
    return;
  size_t len = 0, cap = 64;
  ren_obj **todo = malloc(cap * sizeof(ren_obj *));
  if (todo == NULL)
    abort();
  todo[len++] = o;
  while (len > 0) {
    ren_obj *x = todo[--len];
    if (ren_is_scalar(x) || x->rc <= 0)
      continue;
    x->rc = -x->rc;
    size_t n = 0; /* at most this many children */
    switch (x->tag) {
    default:
      n = x->nfields;
      break;
    case REN_TAG_ARRAY:
      if (((ren_array *)x)->root != NULL)
        n = 1; /* a slice reaches its root, which reaches the elements */
      else
        n = (size_t)((ren_array *)x)->len * (size_t)__builtin_popcount(x->objs);
      break;
    case REN_TAG_DESC:
      n = ((ren_desc *)x)->nargs;
      break;
    case REN_TAG_STR:
      n = ren_str_is_slice(x);
      break;
    case REN_TAG_MAP:
      n = (size_t)((ren_map *)x)->len * 2;
      break;
    }
    if (len + n > cap) {
      while (len + n > cap)
        cap *= 2;
      todo = realloc(todo, cap * sizeof(ren_obj *));
      if (todo == NULL)
        abort();
    }
    switch (x->tag) {
    default:
      for (uint64_t m = ren_ctor_objs(x); m != 0; m &= m - 1)
        todo[len++] = ren_fields(x)[__builtin_ctzll(m)].o;
      break;
    case REN_TAG_ARRAY:
      if (((ren_array *)x)->root != NULL)
        todo[len++] = ((ren_array *)x)->root;
      else
        REN_ELEM_OBJS(x, ((ren_array *)x)->data, ((ren_array *)x)->len, e,
                      todo[len++] = e);
      break;
    case REN_TAG_DESC:
      for (size_t i = 0; i < n; i++)
        todo[len++] = &((ren_desc *)x)->args[i]->h;
      break;
    case REN_TAG_STR:
      if (n)
        todo[len++] = ((ren_str *)x)->root;
      break;
    case REN_TAG_MAP: {
      ren_map *m = (ren_map *)x;
      for (int64_t e = 0; e < m->used; e++) {
        ren_val *ent = &m->entries[e * m->width];
        if (ent[0].i == 0)
          continue;
        if (x->objs & 1)
          todo[len++] = ent[1].o;
        if ((x->objs & 2) && m->width > 2)
          todo[len++] = ent[2].o;
      }
      break;
    }
    }
  }
  free(todo);
}
#endif

/* ---- reuse ---- */

void ren_drop_unkept(ren_obj *o, uint64_t kept) {
  ren_val *fs = ren_fields(o);
  for (uint64_t m = ren_ctor_objs(o) & ~kept; m != 0; m &= m - 1)
    ren_drop(fs[__builtin_ctzll(m)].o);
}

static void ren_free_cell(ren_obj *o) {
  size_t size = ren_ctor_size(o->nfields);
#ifdef REN_STATS
  ren_stats.frees++;
  ren_stats.live_bytes -= (int64_t)size;
#endif
  ren_free_bytes(o, size);
}

void ren_free_keeping(ren_obj *o, uint64_t kept) {
  ren_drop_unkept(o, kept);
  ren_free_cell(o);
}

void ren_free_token(ren_obj *tok) {
  if (tok != NULL)
    ren_free_cell(tok);
}

/* ---- arrays ---- */

_Noreturn void ren_index_panic_len(int64_t len, int64_t i, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "index %" PRId64 " is out of bounds for an array of length %" PRId64,
           i, len);
  ren_panic(site, msg);
}

_Noreturn void ren_index_panic(ren_obj *a, int64_t i, const ren_site *site) {
  ren_index_panic_len(((ren_array *)a)->len, i, site);
}

static void ren_check_index(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
}

/* A copy of [a] with room for [extra] more, each element counted again. */
static ren_obj *ren_array_copy(ren_obj *a, int64_t extra) {
  ren_array *from = (ren_array *)a;
  ren_obj *b = ren_alloc_array_c(from->len + extra, from->len + extra, a->objs,
                                 (uint32_t)from->stride, a->nfields);
  ren_val *to = ren_elems(b);
  if (a->objs && from->stride == 1)
    for (int64_t i = 0; i < from->len; i++) {
      to[i] = from->data[i];
      ren_dup(to[i].o);
    }
  else {
    memcpy(to, from->data, (size_t)from->len * ren_elem_bytes(a));
    REN_ELEM_OBJS(a, to, from->len, x, ren_dup(x));
  }
  return b;
}

ren_obj *ren_array_set(ren_obj *a, int64_t i, ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_val *to = ren_elems(b);
  if (a->objs) {
    ren_drop(to[i].o);
    ren_dup(v.o);
  }
  to[i] = v;
  return b;
}

void ren_array_push(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  if (a->objs)
    ren_dup(v.o);
  ren_elems(b)[((ren_array *)b)->len - 1] = v;
  ren_drop(a);
  *cell = b;
}

ren_obj *ren_array_unshare(ren_obj *a) {
  ren_obj *b = ren_array_copy(a, 0);
  ren_drop(a);
  return b;
}

/* Room for one element more in a unique array: its buffer doubled if
   it's full. Out of line: inlined into [ren_array_push_taking], which
   it was once the out-of-memory path's extra call stopped, it made
   blocks 24% slower in cycles on fewer instructions, and splitting off
   only the doubling didn't help (RESULTS.md, "Frames and late overflow
   cut"). */
__attribute__((noinline)) static void ren_array_grow(ren_array *arr) {
  if (arr->len < arr->cap)
    return;
  size_t k = ren_elem_bytes(&arr->h);
  int64_t cap = arr->cap * 2;
  ren_val *data = realloc(arr->data, (size_t)cap * k);
  if (data == NULL) {
    fflush(stdout);
    fputs("error: out of memory\n", stderr);
    exit(1);
  }
#ifdef REN_STATS
  ren_stats.grows++;
  ren_stats.live_bytes += (cap - arr->cap) * (int64_t)k;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
  arr->data = data;
  arr->cap = cap;
}

void ren_array_push_taking(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!ren_array_unique(a)) {
    ren_obj *b = ren_array_copy(a, 1);
    ren_elems(b)[((ren_array *)b)->len - 1] = v;
    ren_drop(a);
    *cell = b;
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  arr->data[arr->len++] = v;
}

/* ---- arrays of a type variable's elements, or a sized type's ---- */

ren_obj *ren_array_set_w(ren_obj *a, int64_t i, ren_val v, const ren_site *site) {
  if (!a->nfields)
    return ren_array_set(a, i, v, site);
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_sized_store(b, i, v);
  return b;
}

void ren_array_push_w(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!a->nfields) {
    ren_array_push(cell, v);
    return;
  }
  ren_obj *b = ren_array_copy(a, 1);
  ren_sized_store(b, ((ren_array *)b)->len - 1, v);
  ren_drop(a);
  *cell = b;
}

void ren_array_push_taking_w(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!a->nfields) {
    ren_array_push_taking(cell, v);
    return;
  }
  if (!ren_array_unique(a)) {
    ren_array_push_w(cell, v);
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  ren_sized_store(a, arr->len++, v);
}

/* ---- arrays of structs ---- */

ren_obj *ren_array_set_slots(ren_obj *a, int64_t i, const ren_val *v,
                             const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  int64_t k = ren_stride(a);
  ren_val *e = &ren_elems(b)[i * k];
  ren_slots_drop(e, a->objs);
  memcpy(e, v, (size_t)k * sizeof(ren_val));
  ren_slots_dup(e, a->objs);
  return b;
}

ren_obj *ren_array_set_field(ren_obj *a, int64_t i, int64_t off, int64_t k,
                             ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_val *at = &ren_elems(b)[i * k + off];
  if (a->objs & (1u << off)) {
    ren_drop(at->o);
    ren_dup(v.o);
  }
  *at = v;
  return b;
}

void ren_array_push_slots(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  int64_t k = ren_stride(a);
  ren_val *e = &ren_elems(b)[(((ren_array *)b)->len - 1) * k];
  memcpy(e, v, (size_t)k * sizeof(ren_val));
  ren_slots_dup(e, a->objs);
  ren_drop(a);
  *cell = b;
}

void ren_array_push_slots_taking(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  int64_t k = ren_stride(a);
  if (!ren_array_unique(a)) {
    ren_obj *b = ren_array_copy(a, 1);
    memcpy(&ren_elems(b)[(((ren_array *)b)->len - 1) * k], v,
           (size_t)k * sizeof(ren_val));
    ren_drop(a);
    *cell = b;
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  memcpy(&arr->data[arr->len * k], v, (size_t)k * sizeof(ren_val));
  arr->len++;
}

/* ---- strings ---- */

ren_obj *ren_str_of(const char *s, int64_t len) {
  ren_obj *o = ren_alloc_str(len);
  memcpy(((ren_str *)o)->bytes, s, (size_t)len);
  return o;
}

ren_obj *ren_str_concat(ren_obj *a, ren_obj *b) {
  int64_t la = ren_str_len(a), lb = ren_str_len(b);
  ren_obj *o = ren_alloc_str(la + lb);
  memcpy(((ren_str *)o)->bytes, ren_str_data(a), (size_t)la);
  memcpy(((ren_str *)o)->bytes + la, ren_str_data(b), (size_t)lb);
  return o;
}

/* ---- appending in place (compiler.md, "Bytes stage, part two",
   "Appending in place") ---- */

/* The sites that copied, the last first, for the report: the program's
   thread's, which [ren_run] reads once it has ended. */
static ren_append *ren_appends;

/* What [ren_str_concat_taking] grows to, or copies into: twice [cap] or
   [need], whichever is more, and 32 bytes at least. */
static int64_t ren_str_room(int64_t cap, int64_t need) {
  int64_t room = cap > INT64_MAX / 2 ? INT64_MAX : cap * 2;
  if (room < need)
    room = need;
  return room < 32 ? 32 : room;
}

/* [a], a unique owner, made a new one with room for [cap] bytes, its
   [len] kept: in its memory if the allocator can, as an array's buffer
   grows ([ren_array_grow]), and not an object made, which the statistics
   count as a grow. */
__attribute__((noinline)) static ren_obj *ren_str_grow(ren_obj *a, int64_t cap) {
  ren_str *s = (ren_str *)a;
  size_t old = ren_str_size(s->cap);
  cap = (int64_t)(ren_words(ren_str_size(cap)) * 8 - sizeof(ren_str));
  size_t bytes = ren_str_size(cap);
  ren_str *t;
#ifndef REN_SYSTEM_MALLOC
  if (ren_words(old) <= REN_SMALL_WORDS) {
    /* a small object's memory is from a free list, which realloc can't
       take back */
    t = ren_alloc_bytes(bytes);
    memcpy(t, s, sizeof(ren_str) + (size_t)s->len);
    ren_free_bytes(s, old);
  } else
#endif
  {
    t = realloc(s, bytes);
    if (t == NULL)
      ren_out_of_memory();
  }
#ifdef REN_STATS
  ren_stats.grows++;
  ren_stats.live_bytes += (int64_t)bytes - (int64_t)old;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
  t->data = t->bytes;
  t->cap = cap;
  return &t->h;
}

ren_obj *ren_str_concat_slow(ren_obj *a, ren_obj *b, ren_append *site) {
  ren_str *x = (ren_str *)a;
  int64_t la = x->len, lb = ren_str_len(b);
  if (ren_rc(a) == 1 && !ren_str_is_slice(a)) {
    if (lb <= x->cap - la) {
      memcpy(x->bytes + la, ren_str_data(b), (size_t)lb);
      x->len = la + lb;
      return a;
    }
    /* [b] may be [a] itself, or a part of its bytes nothing counted, which
       growing moves: where it starts in them is read first */
    const char *from = ren_str_data(b);
    bool inside = from >= x->bytes && from < x->bytes + la;
    int64_t at = inside ? from - x->bytes : 0;
    ren_str *y = (ren_str *)ren_str_grow(a, ren_str_room(x->cap, la + lb));
    from = inside ? y->bytes + at : from;
    memcpy(y->bytes + la, from, (size_t)lb);
    y->len = la + lb;
    return &y->h;
  }
  /* shared, a literal or a slice: its range copied, with room to grow,
     twice its length, not its room, which a loop that copies on every
     pass would double each time. The report counts a copy of what
     something else holds, the one that makes a loop quadratic; not a
     literal's or a slice's, which a loop that starts each string from
     `""` makes once a string */
  if (site != NULL && ren_rc(a) != 0 && ren_rc(a) != 1 && site->copies++ == 0) {
    site->next = ren_appends;
    ren_appends = site;
  }
  ren_obj *o = ren_alloc_str_cap(la + lb, ren_str_room(la, la + lb));
  memcpy(((ren_str *)o)->bytes, x->data, (size_t)la);
  memcpy(((ren_str *)o)->bytes + la, ren_str_data(b), (size_t)lb);
  ren_drop(a);
  return o;
}

static int ren_append_order(const void *p, const void *q) {
  uint32_t a = (*(ren_append *const *)p)->order, b = (*(ren_append *const *)q)->order;
  return a < b ? -1 : a > b;
}

/* The report: a note for each site that copied on more than one pass, in
   the order of the program's sites, unless REN_NOTES is 0. */
static void ren_append_report(void) {
  const char *on = getenv("REN_NOTES");
  if (ren_appends == NULL || (on != NULL && strcmp(on, "0") == 0))
    return;
  size_t n = 0;
  for (ren_append *s = ren_appends; s != NULL; s = s->next)
    n++;
  ren_append **all = malloc(n * sizeof *all);
  if (all == NULL)
    return;
  n = 0;
  for (ren_append *s = ren_appends; s != NULL; s = s->next)
    all[n++] = s;
  qsort(all, n, sizeof *all, ren_append_order);
  fflush(stdout);
  for (size_t i = 0; i < n; i++) {
    if (all[i]->copies < 2)
      continue;
    char msg[160];
    snprintf(msg, sizeof msg,
             "this `%s` copied its %s on %" PRId64
             " passes, since something else held it",
             all[i]->compound ? "+=" : "+",
             all[i]->compound ? "string" : "left side", all[i]->copies);
    ren_site_print(all[i]->site, msg, NULL);
  }
  free(all);
}

bool ren_str_eq(ren_obj *a, ren_obj *b) {
  return ren_str_len(a) == ren_str_len(b) &&
         memcmp(ren_str_data(a), ren_str_data(b), (size_t)ren_str_len(a)) == 0;
}

/* ---- slices (foundations.md, decision 17) ----

   Roc's seamless slices (crates/compiler/builtins/bitcode/src/list.zig,
   `seamlessSlice`; str.zig, `SEAMLESS_SLICE_BIT`): a slice shares its
   root's buffer and counts the root, not each element, so making one is
   O(1) whatever it holds. Roc tags a slice in the high bit of its
   capacity; this runtime has room in the header for a pointer to the
   root, which is simpler, and frees the slice's header on its own. A
   slice's root is always an owner, so dropping a slice never walks a
   chain of them. The checks, and what they say, are the interpreter's
   (builtins.ml, [slice_value] and [split_halves]). */

static const char *ren_sliced_what(ren_obj *a, bool str) {
  return a->tag == REN_TAG_ARRAY ? "an array" : str ? "a string" : "bytes";
}

/* Panics unless [i..j] is a range in [a], of length [len]. */
static void ren_slice_check(ren_obj *a, int64_t len, int64_t i, int64_t j,
                            bool str, const ren_site *site) {
  char msg[160];
  if (i > j) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " ends before it starts", i, j);
    ren_panic(site, msg);
  }
  if (i < 0 || j > len) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64
             " is out of bounds for %s of length %" PRId64,
             i, j, ren_sliced_what(a, str), len);
    ren_panic(site, msg);
  }
}

/* Whether byte [i] of a string begins a character, or is its end: UTF-8's
   continuation bytes are 10xxxxxx. */
static bool ren_boundary(ren_obj *s, int64_t i) {
  return i == ren_str_len(s) ||
         ((unsigned char)ren_str_data(s)[i] & 0xc0) != 0x80;
}

/* Panics, for a `Str`, if [i] or [j] is inside a character; [from] and
   [to] are the range said, which a `split_at`'s is 0 to [j]. */
static void ren_chars_check(ren_obj *s, int64_t i, int64_t j,
                            const ren_site *site) {
  /* the help names `char_floor` on the string as it's written, a 0x02,
     as the interpreter's does (builtins.ml, [check_chars]) */
  char msg[160], help[200];
  if (!ren_boundary(s, i)) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " starts inside a character", i,
             j);
    snprintf(help, sizeof help,
             "to start where a character does, use `\002.char_floor(%" PRId64
             ")` or `\002.char_ceil(%" PRId64 ")`",
             i, i);
    ren_panic_help(site, msg, help);
  }
  if (!ren_boundary(s, j)) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " ends inside a character", i, j);
    snprintf(help, sizeof help,
             "to cut at most %" PRId64 " bytes, end at `\002.char_floor(%" PRId64
             ")`",
             j - i, j);
    ren_panic_help(site, msg, help);
  }
}

/* Where element [i] of [a] is. */
static void *ren_elem_at(ren_obj *a, int64_t i) {
  return (char *)((ren_array *)a)->data + (size_t)i * ren_elem_bytes(a);
}

/* Whether [a] is a lent slice ([ren_array_writable]). */
static bool ren_lent(ren_obj *a) {
  return ((ren_array *)a)->cap < 0;
}

/* [a] not lent any more: something else sees its range now, or will. A
   shared one, whose count another thread may be changing, is never
   written in place anyway, and isn't written to here. */
static void ren_unlend(ren_obj *a) {
  ren_array *arr = (ren_array *)a;
  if (arr->cap < 0 && ren_rc(a) > 0)
    arr->cap = 0;
}

/* A new header for [len] of [a]'s elements from where [at] points, in
   [a]'s buffer, counting [a]'s root; lent if [lent]. */
static ren_obj *ren_array_view(ren_obj *a, void *at, int64_t len, bool lent) {
  ren_array *from = (ren_array *)a;
  ren_array *s = ren_alloc_bytes(sizeof(ren_array));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_array));
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_ARRAY;
  s->h.nfields = a->nfields;
  s->h.objs = a->objs;
  s->stride = from->stride;
  s->data = at;
  s->len = len;
  s->cap = lent ? -1 : 0;
  s->root = from->root != NULL ? from->root : a;
  ren_dup(s->root);
  return &s->h;
}

/* [a]'s elements from [i] up to [j], in range: a slice, which ends [a]'s
   lending, or [a] itself, counted again, for all of it. */
static ren_obj *ren_array_part(ren_obj *a, int64_t i, int64_t j) {
  ren_unlend(a);
  if (i == 0 && j == ren_array_len(a)) {
    ren_dup(a);
    return a;
  }
  return ren_array_view(a, ren_elem_at(a, i), j - i, false);
}

static ren_obj *ren_str_part(ren_obj *a, int64_t i, int64_t j) {
  ren_str *from = (ren_str *)a;
  if (i == 0 && j == from->len) {
    ren_dup(a);
    return a;
  }
  ren_str *s = ren_alloc_bytes(sizeof(ren_str));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_str));
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_STR;
  s->h.nfields = REN_STR_SLICE;
  s->h.objs = 0;
  s->len = j - i;
  s->data = from->data + i;
  s->root = ren_str_is_slice(a) ? from->root : a;
  ren_dup(s->root);
  return &s->h;
}

ren_obj *ren_array_slice(ren_obj *a, int64_t i, int64_t j,
                         const ren_site *site) {
  ren_slice_check(a, ren_array_len(a), i, j, false, site);
  return ren_array_part(a, i, j);
}

ren_obj *ren_str_slice(ren_obj *s, int64_t i, int64_t j, bool str,
                       const ren_site *site) {
  ren_slice_check(s, ren_str_len(s), i, j, str, site);
  if (str)
    ren_chars_check(s, i, j, site);
  return ren_str_part(s, i, j);
}

/* Panics unless [n] is where `split_at` can split [a], of length [len]. */
static void ren_split_check(ren_obj *a, int64_t len, int64_t n, bool str,
                            const ren_site *site) {
  if (n < 0 || n > len) {
    char msg[160];
    snprintf(msg, sizeof msg,
             "`split_at` %" PRId64 " is out of bounds for %s of length %" PRId64,
             n, ren_sliced_what(a, str), len);
    ren_panic(site, msg);
  }
  if (str)
    ren_chars_check(a, 0, n, site);
}

/* A `split_at`'s halves are lent, each a header of its own, if [a] is
   writable: nothing else sees its range, and, since its place is vacant
   while the block has them, nothing else will. A slice of either ends
   its lending ([ren_array_part]), and so does the join after
   ([ren_array_join]), so each lent slice is the only way to its range.
   [ren_array_after] lends its half if [lo] was: it's made right after,
   [a] the same, and [lo] holds a count of [a]'s root, so [a] isn't
   writable itself any more. */
ren_obj *ren_array_before(ren_obj *a, int64_t n, const ren_site *site) {
  ren_split_check(a, ren_array_len(a), n, false, site);
  if (ren_array_writable(a))
    return ren_array_view(a, ren_elem_at(a, 0), n, true);
  return ren_array_part(a, 0, n);
}

ren_obj *ren_array_after(ren_obj *a, int64_t n, ren_obj *lo) {
  int64_t len = ren_array_len(a);
  if (ren_lent(lo) && ((ren_array *)lo)->data == ((ren_array *)a)->data) {
    ren_obj *hi = ren_array_view(a, ren_elem_at(a, n), len - n, true);
    ren_unlend(a);
    return hi;
  }
  return ren_array_part(a, n, len);
}

ren_obj *ren_str_before(ren_obj *s, int64_t n, bool str, const ren_site *site) {
  ren_split_check(s, ren_str_len(s), n, str, site);
  return ren_str_part(s, 0, n);
}

ren_obj *ren_str_after(ren_obj *s, int64_t n) {
  return ren_str_part(s, n, ren_str_len(s));
}

/* Copies [n] of [from]'s elements from [i] to [to], each counted again. */
static void ren_elems_copy(ren_obj *to, int64_t at, ren_obj *from, int64_t i,
                           int64_t n) {
  if (n <= 0)
    return;
  memcpy(ren_elem_at(to, at), ren_elem_at(from, i),
         (size_t)n * ren_elem_bytes(from));
  REN_ELEM_OBJS(from, (ren_val *)ren_elem_at(from, i), n, x, ren_dup(x));
}

ren_obj *ren_array_splice(ren_obj *a, int64_t i, int64_t j, ren_obj *b) {
  int64_t la = ren_array_len(a), lb = ren_array_len(b);
  ren_obj *o = ren_alloc_array_c(la - (j - i) + lb, la - (j - i) + lb, a->objs,
                                 (uint32_t)((ren_array *)a)->stride,
                                 a->nfields);
  ren_elems_copy(o, 0, a, 0, i);
  ren_elems_copy(o, i, b, 0, lb);
  ren_elems_copy(o, i + lb, a, j, la - j);
  return o;
}

/* A `split_at`'s halves joined. If they're slices of one root, next to
   each other, their elements are already in order there: all of the
   root, if they cover it and are all that hold it, or else a slice of
   it, lent if both were and nothing else holds either, since then
   nothing else sees its range. Either ends the halves' lending. */
ren_obj *ren_array_join(ren_obj *a, ren_obj *b) {
  ren_array *x = (ren_array *)a, *y = (ren_array *)b;
  if (x->root != NULL && x->root == y->root &&
      (char *)x->data + (size_t)x->len * ren_elem_bytes(a) == (char *)y->data) {
    ren_obj *root = x->root;
    bool lent = ren_lent(a) && ren_lent(b) && ren_rc(a) == 1 && ren_rc(b) == 1;
    ren_unlend(a);
    ren_unlend(b);
    if (x->data == ((ren_array *)root)->data &&
        x->len + y->len == ren_array_len(root) && ren_rc(root) == 2) {
      ren_dup(root);
      return root;
    }
    return ren_array_view(a, x->data, x->len + y->len, lent);
  }
  int64_t la = ren_array_len(a);
  return ren_array_splice(a, la, la, b);
}

ren_obj *ren_str_splice(ren_obj *s, int64_t i, int64_t j, ren_obj *b) {
  int64_t ls = ren_str_len(s), lb = ren_str_len(b);
  ren_obj *o = ren_alloc_str(ls - (j - i) + lb);
  char *to = ((ren_str *)o)->bytes;
  memcpy(to, ren_str_data(s), (size_t)i);
  memcpy(to + i, ren_str_data(b), (size_t)lb);
  memcpy(to + i + lb, ren_str_data(s) + j, (size_t)(ls - j));
  return o;
}

/* Strings change only where one reference holds them (an append in
   place), so their halves are never lent: joined, they're
   their root, or a slice of it, if they're next to each other in it. */
ren_obj *ren_str_join(ren_obj *a, ren_obj *b) {
  ren_str *x = (ren_str *)a, *y = (ren_str *)b;
  if (ren_str_is_slice(a) && ren_str_is_slice(b) && x->root == y->root &&
      x->data + x->len == y->data) {
    ren_obj *root = x->root;
    if (x->data == ((ren_str *)root)->data &&
        x->len + y->len == ren_str_len(root)) {
      ren_dup(root);
      return root;
    }
    ren_str *s = ren_alloc_bytes(sizeof(ren_str));
#ifdef REN_STATS
    ren_count_alloc((int64_t)sizeof(ren_str));
#endif
    s->h = x->h;
    s->h.rc = 1;
    s->len = x->len + y->len;
    s->data = x->data;
    s->root = root;
    ren_dup(root);
    return &s->h;
  }
  return ren_str_concat(a, b);
}

ren_obj *ren_str_split(ren_obj *s, ren_obj *sep, const ren_site *site) {
  int64_t n = ren_str_len(s), m = ren_str_len(sep);
  const char *d = ren_str_data(s), *p = ren_str_data(sep);
  if (m == 0)
    ren_panic(site, "`split` needs a separator that isn't empty");
  /* the parts: one more than the separators found, left to right */
  int64_t parts = 1;
  for (int64_t i = 0; i + m <= n;)
    if (memcmp(d + i, p, (size_t)m) == 0) {
      parts++;
      i += m;
    } else
      i++;
  ren_obj *out = ren_alloc_array(parts, true);
  ren_val *xs = ren_elems(out);
  int64_t from = 0, k = 0;
  for (int64_t i = 0; i + m <= n;)
    if (memcmp(d + i, p, (size_t)m) == 0) {
      xs[k++].o = ren_str_part(s, from, i);
      i += m;
      from = i;
    } else
      i++;
  xs[k].o = ren_str_part(s, from, n);
  return out;
}

static bool ren_trimmed(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

ren_obj *ren_str_trim(ren_obj *s) {
  int64_t i = 0, j = ren_str_len(s);
  const char *d = ren_str_data(s);
  while (i < j && ren_trimmed(d[i]))
    i++;
  while (j > i && ren_trimmed(d[j - 1]))
    j--;
  return ren_str_part(s, i, j);
}

int64_t ren_char_bound(ren_obj *s, int64_t i, bool ceil, const ren_site *site) {
  int64_t n = ren_str_len(s);
  if (i < 0 || i > n) {
    char msg[160];
    snprintf(msg, sizeof msg,
             "`%s` %" PRId64 " is out of bounds for a string of length %" PRId64,
             ceil ? "char_ceil" : "char_floor", i, n);
    ren_panic(site, msg);
  }
  while (!ren_boundary(s, i))
    i += ceil ? 1 : -1;
  return i;
}

int64_t ren_str_code(ren_obj *s, const ren_site *site) {
  int64_t n = ren_str_len(s);
  const unsigned char *d = (const unsigned char *)ren_str_data(s);
  if (n == 0)
    ren_panic(site, "`code()` takes one code point, and this string is empty");
  /* a `Str` is UTF-8, so its first byte says how long its first
     character is */
  int64_t w = d[0] < 0x80 ? 1 : d[0] < 0xE0 ? 2 : d[0] < 0xF0 ? 3 : 4;
  if (w != n) {
    int64_t k = 0;
    for (int64_t i = 0; i < n; i++)
      k += (d[i] & 0xC0) != 0x80;
    char msg[160];
    snprintf(msg, sizeof msg,
             "`code()` takes one code point, and this string has %" PRId64, k);
    /* the help's `(` is written \x28: build.t looks for a block's call,
       which is `.code` and a `(`, in the C a build makes */
    ren_panic_help(site, msg,
                   "for each code point: `for c in \002.chars()`, and `c.code\x28)`");
  }
  switch (w) {
  case 1:
    return d[0];
  case 2:
    return ((int64_t)(d[0] & 0x1F) << 6) | (d[1] & 0x3F);
  case 3:
    return ((int64_t)(d[0] & 0x0F) << 12) | ((int64_t)(d[1] & 0x3F) << 6) |
           (d[2] & 0x3F);
  default:
    return ((int64_t)(d[0] & 0x07) << 18) | ((int64_t)(d[1] & 0x3F) << 12) |
           ((int64_t)(d[2] & 0x3F) << 6) | (d[3] & 0x3F);
  }
}

ren_obj *ren_str_of_code(int64_t n, const ren_site *site) {
  if (n < 0 || n > 0x10FFFF || (n >= 0xD800 && n <= 0xDFFF)) {
    char msg[160];
    snprintf(msg, sizeof msg,
             "`Str.of_code(%" PRId64 ")` isn't a Unicode scalar value", n);
    ren_panic_help(site, msg,
                   "a scalar value is 0 to 0x10FFFF, but not 0xD800 to 0xDFFF, "
                   "the surrogates");
  }
  char b[4];
  int64_t w;
  if (n < 0x80) {
    b[0] = (char)n;
    w = 1;
  } else if (n < 0x800) {
    b[0] = (char)(0xC0 | (n >> 6));
    b[1] = (char)(0x80 | (n & 0x3F));
    w = 2;
  } else if (n < 0x10000) {
    b[0] = (char)(0xE0 | (n >> 12));
    b[1] = (char)(0x80 | ((n >> 6) & 0x3F));
    b[2] = (char)(0x80 | (n & 0x3F));
    w = 3;
  } else {
    b[0] = (char)(0xF0 | (n >> 18));
    b[1] = (char)(0x80 | ((n >> 12) & 0x3F));
    b[2] = (char)(0x80 | ((n >> 6) & 0x3F));
    b[3] = (char)(0x80 | (n & 0x3F));
    w = 4;
  }
  return ren_str_of(b, w);
}

ren_obj *ren_strs_join(ren_obj *xs, ren_obj *sep) {
  int64_t n = ren_array_len(xs), m = ren_str_len(sep);
  ren_val *e = ren_elems(xs);
  int64_t len = n > 0 ? (n - 1) * m : 0;
  for (int64_t i = 0; i < n; i++)
    len += ren_str_len(e[i].o);
  ren_obj *o = ren_alloc_str(len);
  char *to = ((ren_str *)o)->bytes;
  for (int64_t i = 0; i < n; i++) {
    if (i > 0) {
      memcpy(to, ren_str_data(sep), (size_t)m);
      to += m;
    }
    int64_t k = ren_str_len(e[i].o);
    memcpy(to, ren_str_data(e[i].o), (size_t)k);
    to += k;
  }
  return o;
}

ren_obj *ren_str_lower(ren_obj *s) {
  int64_t n = ren_str_len(s);
  const char *from = ren_str_data(s);
  ren_obj *o = ren_alloc_str(n);
  char *to = ((ren_str *)o)->bytes;
  for (int64_t i = 0; i < n; i++) {
    char c = from[i];
    to[i] = c >= 'A' && c <= 'Z' ? (char)(c + ('a' - 'A')) : c;
  }
  return o;
}

ren_obj *ren_array_copied(ren_obj *a) {
  if (((ren_array *)a)->root == NULL) {
    ren_dup(a);
    return a;
  }
  return ren_array_copy(a, 0);
}

ren_obj *ren_str_copied(ren_obj *s) {
  if (!ren_str_is_slice(s)) {
    ren_dup(s);
    return s;
  }
  return ren_str_of(ren_str_data(s), ren_str_len(s));
}

void ren_bytes_index_panic(int64_t len, int64_t i, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "index %" PRId64 " is out of bounds for bytes of length %" PRId64,
           i, len);
  ren_panic(site, msg);
}

ren_obj *ren_bytes_of(ren_obj *a, const ren_site *site) {
  int64_t n = ren_array_len(a);
  ren_obj *o = ren_alloc_str(n);
  for (int64_t i = 0; i < n; i++) {
    int64_t x = ren_elems(a)[i].i;
    if (x < 0 || x > 255) {
      char msg[96];
      snprintf(msg, sizeof msg, "%" PRId64 " isn't a byte, 0 to 255", x);
      ren_drop(o);
      ren_panic(site, msg);
    }
    ((ren_str *)o)->bytes[i] = (char)x;
  }
  return o;
}

void ren_bytes_range_panic(int64_t len, int64_t at, int width,
                           const ren_site *site) {
  if (width == 1)
    ren_bytes_index_panic(len, at, site);
  char msg[160];
  snprintf(msg, sizeof msg,
           "%d bytes at %" PRId64 " are out of bounds for bytes of length %" PRId64,
           width, at, len);
  ren_panic(site, msg);
}

void ren_bytes_u64_panic(int64_t at, uint64_t x, bool big, const ren_site *site) {
  char msg[160];
  snprintf(msg, sizeof msg,
           "`u64_%s` at %" PRId64 " read %" PRIu64 ", which is more than an `Int` holds",
           big ? "be" : "le", at, x);
  ren_panic(site, msg);
}

void ren_varuint_panic(int64_t x, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "%" PRId64 " doesn't fit in a `VarUInt`, which holds 0 to 9223372036854775807", x);
  ren_panic(site, msg);
}

ren_obj *ren_bytes_unshare(ren_obj *b) {
  ren_obj *c = ren_str_of(ren_str_data(b), ren_str_len(b));
  ren_drop(b);
  return c;
}

/* ---- UTF-8 (compiler.md, "Bytes stage, part two", "The validator") ----

   `Str.from_utf8` accepts what OCaml's `String.is_valid_utf_8` does, and
   nothing else: no overlong form, no surrogate, nothing past U+10FFFF, no
   byte C0, C1 or F5 to FF. Where there's NEON a block validator finds
   whether there's an error and in which block; the scalar decoder, which
   is the whole path elsewhere, says where it is. */

/* The character at [p + i], of [n] bytes: its length if it's UTF-8, else
   minus the length of its maximal invalid subpart, at least 1 (Unicode's
   "best practice", what OCaml's `String.get_utf_8_uchar` decodes as one
   invalid character). The range the second byte is in rules out overlong
   forms, surrogates and what's past U+10FFFF. */
static int ren_utf8_char(const unsigned char *p, int64_t i, int64_t n) {
  unsigned c = p[i];
  if (c < 0x80)
    return 1;
  int more;
  unsigned lo = 0x80, hi = 0xbf;
  if (c >= 0xc2 && c <= 0xdf)
    more = 1;
  else if (c >= 0xe0 && c <= 0xef) {
    more = 2;
    if (c == 0xe0)
      lo = 0xa0;
    else if (c == 0xed)
      hi = 0x9f;
  } else if (c >= 0xf0 && c <= 0xf4) {
    more = 3;
    if (c == 0xf0)
      lo = 0x90;
    else if (c == 0xf4)
      hi = 0x8f;
  } else
    return -1;
  if (i + 1 >= n || p[i + 1] < lo || p[i + 1] > hi)
    return -1;
  for (int k = 2; k <= more; k++)
    if (i + k >= n || (p[i + k] & 0xc0) != 0x80)
      return -k;
  return more + 1;
}

/* Whether the [n - at] bytes from [at] are a proper prefix of a
   character: the end cut it off. `C3` at the end is; `E0 80` and `F5`
   aren't. */
static bool ren_utf8_cut(const unsigned char *p, int64_t at, int64_t n) {
  int k = ren_utf8_char(p, at, n);
  return k < 0 && at - k == n && p[at] >= 0xc2 && p[at] <= 0xf4;
}

/* From [i], where a character starts, to [n]: -1 if the bytes are UTF-8,
   else where the first that isn't part of a character is, and in
   [*incomplete] whether the end cut that character off. A run of ASCII
   eight bytes at a time; a character with 3 bytes after it decoded with
   no test of the end; else [ren_utf8_char], which says where an error
   is. */
static int64_t ren_utf8_from(const unsigned char *p, int64_t i, int64_t n,
                             bool *incomplete) {
  while (i < n) {
    unsigned c = p[i];
    if (c < 0x80) {
      uint64_t w;
      i++;
      while (i + 8 <= n && (memcpy(&w, p + i, 8), (w & 0x8080808080808080ULL) == 0))
        i += 8;
      while (i < n && p[i] < 0x80)
        i++;
      continue;
    }
    if (i + 4 <= n) {
      unsigned c1 = p[i + 1];
      if (c >= 0xc2 && c <= 0xdf) {
        if ((c1 & 0xc0) == 0x80) {
          i += 2;
          continue;
        }
      } else if (c >= 0xe0 && c <= 0xef) {
        unsigned lo = c == 0xe0 ? 0xa0 : 0x80, hi = c == 0xed ? 0x9f : 0xbf;
        if (c1 >= lo && c1 <= hi && (p[i + 2] & 0xc0) == 0x80) {
          i += 3;
          continue;
        }
      } else if (c >= 0xf0 && c <= 0xf4) {
        unsigned lo = c == 0xf0 ? 0x90 : 0x80, hi = c == 0xf4 ? 0x8f : 0xbf;
        if (c1 >= lo && c1 <= hi && (p[i + 2] & 0xc0) == 0x80 && (p[i + 3] & 0xc0) == 0x80) {
          i += 4;
          continue;
        }
      }
    }
    int k = ren_utf8_char(p, i, n);
    if (k < 0) {
      *incomplete = ren_utf8_cut(p, i, n);
      return i;
    }
    i += k;
  }
  return -1;
}

int64_t ren_utf8_check_scalar(const char *s, int64_t n, bool *incomplete) {
  *incomplete = false;
  return ren_utf8_from((const unsigned char *)s, 0, n, incomplete);
}

#if defined(__ARM_NEON) && !defined(__TINYC__)
#include <arm_neon.h>

/* Keiser and Lemire's lookup algorithm ("Validating UTF-8 in less than
   one instruction per byte", 2021), as simdjson and simdutf build it,
   in NEON: research/strings/track-b/c/b5.c, whose agreement test
   test/utf8/ runs. Each byte's error is found from it and the three
   before it, by three 16-byte tables looked up by the previous byte's
   nibbles and this byte's high one, and the 3- and 4-byte sequences'
   continuations checked apart. 64 bytes a block, all-ASCII blocks
   skipped, the error tested once a block, so that the block an error
   is found in is known. */
#define REN_U8_TOO_SHORT (1 << 0)
#define REN_U8_TOO_LONG (1 << 1)
#define REN_U8_OVERLONG_3 (1 << 2)
#define REN_U8_TOO_LARGE (1 << 3)
#define REN_U8_SURROGATE (1 << 4)
#define REN_U8_OVERLONG_2 (1 << 5)
#define REN_U8_TOO_LARGE_1000 (1 << 6)
#define REN_U8_OVERLONG_4 (1 << 6)
#define REN_U8_TWO_CONTS (1 << 7)
#define REN_U8_CARRY (REN_U8_TOO_SHORT | REN_U8_TOO_LONG | REN_U8_TWO_CONTS)

static const uint8_t ren_u8_t1h[16] = {
    REN_U8_TOO_LONG, REN_U8_TOO_LONG, REN_U8_TOO_LONG, REN_U8_TOO_LONG,
    REN_U8_TOO_LONG, REN_U8_TOO_LONG, REN_U8_TOO_LONG, REN_U8_TOO_LONG,
    REN_U8_TWO_CONTS, REN_U8_TWO_CONTS, REN_U8_TWO_CONTS, REN_U8_TWO_CONTS,
    REN_U8_TOO_SHORT | REN_U8_OVERLONG_2, REN_U8_TOO_SHORT,
    REN_U8_TOO_SHORT | REN_U8_OVERLONG_3 | REN_U8_SURROGATE,
    REN_U8_TOO_SHORT | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000 | REN_U8_OVERLONG_4};
static const uint8_t ren_u8_t1l[16] = {
    REN_U8_CARRY | REN_U8_OVERLONG_3 | REN_U8_OVERLONG_2 | REN_U8_OVERLONG_4,
    REN_U8_CARRY | REN_U8_OVERLONG_2,
    REN_U8_CARRY,
    REN_U8_CARRY,
    REN_U8_CARRY | REN_U8_TOO_LARGE,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000 | REN_U8_SURROGATE,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000,
    REN_U8_CARRY | REN_U8_TOO_LARGE | REN_U8_TOO_LARGE_1000};
static const uint8_t ren_u8_t2h[16] = {
    REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT,
    REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT,
    REN_U8_TOO_LONG | REN_U8_OVERLONG_2 | REN_U8_TWO_CONTS | REN_U8_OVERLONG_3 |
        REN_U8_TOO_LARGE_1000 | REN_U8_OVERLONG_4,
    REN_U8_TOO_LONG | REN_U8_OVERLONG_2 | REN_U8_TWO_CONTS | REN_U8_OVERLONG_3 |
        REN_U8_TOO_LARGE,
    REN_U8_TOO_LONG | REN_U8_OVERLONG_2 | REN_U8_TWO_CONTS | REN_U8_SURROGATE |
        REN_U8_TOO_LARGE,
    REN_U8_TOO_LONG | REN_U8_OVERLONG_2 | REN_U8_TWO_CONTS | REN_U8_SURROGATE |
        REN_U8_TOO_LARGE,
    REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT, REN_U8_TOO_SHORT};
/* a block's last bytes from which a character is still open: a lead of
   2 bytes in the last, of 3 in the last two, of 4 in the last three */
static const uint8_t ren_u8_maxv[16] = {255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
                                        255, 255, 255, 0xf0 - 1, 0xe0 - 1, 0xc0 - 1};

typedef struct {
  uint8x16_t prev; /* the last 16 bytes checked */
  uint8x16_t open; /* 0xff where [prev] leaves a character open */
  uint8x16_t t1h, t1l, t2h, maxv;
} ren_u8_state;

/* The errors of the 16 bytes [in], after [s->prev]: 0 where none */
static inline uint8x16_t ren_u8_step(ren_u8_state *s, uint8x16_t in) {
  uint8x16_t prev1 = vextq_u8(s->prev, in, 15);
  uint8x16_t b1h = vqtbl1q_u8(s->t1h, vshrq_n_u8(prev1, 4));
  uint8x16_t b1l = vqtbl1q_u8(s->t1l, vandq_u8(prev1, vdupq_n_u8(0x0f)));
  uint8x16_t b2h = vqtbl1q_u8(s->t2h, vshrq_n_u8(in, 4));
  uint8x16_t sc = vandq_u8(vandq_u8(b1h, b1l), b2h);
  uint8x16_t prev2 = vextq_u8(s->prev, in, 14);
  uint8x16_t prev3 = vextq_u8(s->prev, in, 13);
  uint8x16_t third = vqsubq_u8(prev2, vdupq_n_u8(0xe0 - 0x80));
  uint8x16_t fourth = vqsubq_u8(prev3, vdupq_n_u8(0xf0 - 0x80));
  uint8x16_t must23 = vandq_u8(vorrq_u8(third, fourth), vdupq_n_u8(0x80));
  s->prev = in;
  return veorq_u8(must23, sc);
}

/* Whether the 64 bytes at [p] are free of errors, given the block
   before them, which was. An all-ASCII block is one when the block
   before left nothing open, which one test of both finds. */
static inline bool ren_u8_block(ren_u8_state *s, const unsigned char *p) {
  uint8x16_t a = vld1q_u8(p), b = vld1q_u8(p + 16), c = vld1q_u8(p + 32),
             d = vld1q_u8(p + 48);
  uint8x16_t any = vorrq_u8(vorrq_u8(a, b), vorrq_u8(c, d));
  if (vmaxvq_u8(vorrq_u8(any, s->open)) < 0x80) {
    s->prev = d;
    return true;
  }
  if (vmaxvq_u8(any) < 0x80)
    return false; /* ASCII after a character left open */
  uint8x16_t err = vorrq_u8(vorrq_u8(ren_u8_step(s, a), ren_u8_step(s, b)),
                            vorrq_u8(ren_u8_step(s, c), ren_u8_step(s, d)));
  s->open = vcgtq_u8(d, s->maxv);
  return vmaxvq_u8(err) == 0;
}

/* Where a rescan of a block at [i] starts, when every byte before it was
   found free of errors but a character [i] cuts may be left open: the
   start of the character with one of the 3 bytes before [i], if one
   starts there, which may run past [i]; else [i], since what's before it
   is whole characters. */
static int64_t ren_u8_back(const unsigned char *p, int64_t i) {
  for (int64_t k = i - 1; k >= 0 && k >= i - 3; k--)
    if ((p[k] & 0xc0) != 0x80)
      return k;
  return i;
}

int64_t ren_utf8_check(const char *str, int64_t n, bool *incomplete) {
  const unsigned char *p = (const unsigned char *)str;
  ren_u8_state s;
  s.prev = s.open = vdupq_n_u8(0);
  s.t1h = vld1q_u8(ren_u8_t1h);
  s.t1l = vld1q_u8(ren_u8_t1l);
  s.t2h = vld1q_u8(ren_u8_t2h);
  s.maxv = vld1q_u8(ren_u8_maxv);
  *incomplete = false;
  int64_t i = 0;
  for (; i + 64 <= n; i += 64)
    if (!ren_u8_block(&s, p + i))
      return ren_utf8_from(p, ren_u8_back(p, i), n, incomplete);
  if (i < n) {
    /* the last bytes, padded with zeros, after which a character left
       open is an error */
    unsigned char tail[64];
    memset(tail, 0, 64);
    memcpy(tail, p + i, (size_t)(n - i));
    if (!ren_u8_block(&s, tail))
      return ren_utf8_from(p, ren_u8_back(p, i), n, incomplete);
  } else if (n > 0 && vmaxvq_u8(s.open) != 0)
    /* the end cut the last block's last character */
    return ren_utf8_from(p, ren_u8_back(p, n - 64), n, incomplete);
  return -1;
}
#else
int64_t ren_utf8_check(const char *s, int64_t n, bool *incomplete) {
  return ren_utf8_check_scalar(s, n, incomplete);
}
#endif

int64_t ren_utf8_error(ren_obj *s) {
  bool incomplete;
  return ren_utf8_check(ren_str_data(s), ren_str_len(s), &incomplete);
}

bool ren_utf8_incomplete(ren_obj *s, int64_t at) {
  return ren_utf8_cut((const unsigned char *)ren_str_data(s), at, ren_str_len(s));
}

ren_obj *ren_utf8_lossy(ren_obj *b) {
  int64_t n = ren_str_len(b);
  const unsigned char *p = (const unsigned char *)ren_str_data(b);
  bool incomplete;
  int64_t at = ren_utf8_check((const char *)p, n, &incomplete);
  if (at < 0)
    return ren_str_part(b, 0, n);
  /* how long it is: each maximal invalid subpart becomes U+FFFD's 3
     bytes, then the same walk writes it */
  int64_t len = at;
  for (int64_t i = at; i < n;) {
    int k = ren_utf8_char(p, i, n);
    len += k > 0 ? k : 3;
    i += k > 0 ? k : -k;
  }
  ren_obj *o = ren_alloc_str(len);
  char *to = ((ren_str *)o)->bytes;
  memcpy(to, p, (size_t)at);
  int64_t j = at;
  for (int64_t i = at; i < n;) {
    int k = ren_utf8_char(p, i, n);
    if (k > 0) {
      memcpy(to + j, p + i, (size_t)k);
      j += k;
      i += k;
    } else {
      memcpy(to + j, "\xef\xbf\xbd", 3);
      j += 3;
      i -= k;
    }
  }
  return o;
}

ren_obj *ren_bytes_zeros(int64_t n, const ren_site *site) {
  if (n < 0) {
    char msg[96];
    snprintf(msg, sizeof msg, "`Bytes.zeros(%" PRId64 ")`: a length is 0 or more", n);
    ren_panic(site, msg);
  }
  ren_obj *o = ren_alloc_str(n);
  memset(((ren_str *)o)->bytes, 0, (size_t)n);
  return o;
}

/* `%lld`'s digits, written from the last: snprintf's took a fifth of
   building JSON with `+=` (compiler.md, "Bytes stage, part two", "Step
   3, as built"). */
ren_obj *ren_show_int(int64_t n) {
  char buf[24];
  char *end = buf + sizeof buf, *p = end;
  /* the magnitude as unsigned, which INT64_MIN's has room for */
  uint64_t u = n < 0 ? (uint64_t)0 - (uint64_t)n : (uint64_t)n;
  do {
    *--p = (char)('0' + u % 10);
    u /= 10;
  } while (u != 0);
  if (n < 0)
    *--p = '-';
  return ren_str_of(p, end - p);
}

ren_obj *ren_show_bool(bool b) {
  return b ? ren_str_of("true", 4) : ren_str_of("false", 5);
}

/* [s], a number as `%g` writes it, with its digits written out instead of
   an exponent: token.ml's `without_exponent`. */
static void ren_without_exponent(char *out, const char *s) {
  const char *e = strchr(s, 'e');
  if (e == NULL) {
    strcpy(out, s);
    return;
  }
  int exp = atoi(e + 1);
  const char *m = s;
  bool neg = *m == '-';
  if (neg)
    m++;
  /* the mantissa's digits, and how many come before the point */
  char digits[64];
  int n = 0, whole = 0;
  bool seen_point = false;
  for (const char *p = m; p < e; p++) {
    if (*p == '.')
      seen_point = true;
    else {
      digits[n++] = *p;
      if (!seen_point)
        whole++;
    }
  }
  int point = whole + exp;
  char *o = out;
  if (neg)
    *o++ = '-';
  if (point <= 0) {
    *o++ = '0';
    *o++ = '.';
    for (int i = 0; i < -point; i++)
      *o++ = '0';
    for (int i = 0; i < n; i++)
      *o++ = digits[i];
  } else if (point >= n) {
    for (int i = 0; i < n; i++)
      *o++ = digits[i];
    for (int i = 0; i < point - n; i++)
      *o++ = '0';
  } else {
    for (int i = 0; i < point; i++)
      *o++ = digits[i];
    *o++ = '.';
    for (int i = point; i < n; i++)
      *o++ = digits[i];
  }
  *o = 0;
}

void ren_format_float(char *buf, double f) {
  if (f == trunc(f) && fabs(f) < 1e16) {
    snprintf(buf, 400, "%.1f", f);
  } else if (isinf(f)) {
    strcpy(buf, f > 0 ? "inf" : "-inf");
  } else {
    char g[64];
    for (int digits = 1;; digits++) {
      snprintf(g, sizeof g, "%.*g", digits, f);
      if (digits >= 17 || strtod(g, NULL) == f)
        break;
    }
    ren_without_exponent(buf, g);
    if (strchr(buf, '.') == NULL)
      strcat(buf, ".0");
  }
}

ren_obj *ren_show_float(double f, const ren_site *site) {
  if (isnan(f))
    ren_nan_panic(site, "`show` of a NaN", f);
  char buf[400];
  ren_format_float(buf, f);
  return ren_str_of(buf, (int64_t)strlen(buf));
}

void ren_print_quoted(FILE *out, ren_obj *s) {
  fputc('"', out);
  const char *d = ren_str_data(s);
  for (int64_t i = 0; i < ren_str_len(s); i++) {
    switch (d[i]) {
    case '\n':
      fputs("\\n", out);
      break;
    case '\t':
      fputs("\\t", out);
      break;
    case '\\':
      fputs("\\\\", out);
      break;
    case '"':
      fputs("\\\"", out);
      break;
    default:
      fputc(d[i], out);
    }
  }
  fputc('"', out);
}

/* ---- arithmetic ---- */

_Noreturn void ren_int_overflowed(const ren_site *site, const char *op,
                                  int64_t a, int64_t b) {
  char msg[128];
  snprintf(msg, sizeof msg, "`%s` overflowed: %" PRId64 " %s %" PRId64, op, a,
           op, b);
  ren_panic(site, msg);
}

_Noreturn void ren_shift_panic(const ren_site *site, const char *op,
                               int64_t k) {
  char msg[96];
  snprintf(msg, sizeof msg, "`%s` by %" PRId64 ": a shift is by 0 to 63", op,
           k);
  ren_panic(site, msg);
}

/* ---- NaN ---- */

const char *const *ren_nan_where;
int32_t ren_nan_nwhere;

_Noreturn void ren_nan_panic(const ren_site *site, const char *what, double f) {
  uint64_t bits;
  memcpy(&bits, &f, sizeof bits);
  uint32_t tag = (uint32_t)((bits >> 29) & 0x3FFFFF);
  if (ren_nan_where != NULL && tag > 0 && (int32_t)tag < ren_nan_nwhere &&
      ren_nan_where[tag] != NULL) {
    char msg[600];
    snprintf(msg, sizeof msg, "%s made %s", what, ren_nan_where[tag]);
    ren_panic(site, msg);
  }
  ren_panic(site, what);
}

_Noreturn void ren_narrow_panic(const ren_site *site, uint8_t kind, ren_val v) {
  static const char *const names[] = {"",       "Int8",   "UInt8",
                                      "Int16",  "UInt16", "Int32",
                                      "UInt32", "UInt64", "Float32"};
  static const int64_t lo[] = {0, INT8_MIN, 0, INT16_MIN, 0, INT32_MIN, 0, 0};
  static const int64_t hi[] = {0,         INT8_MAX,   UINT8_MAX,
                               INT16_MAX, UINT16_MAX, INT32_MAX,
                               UINT32_MAX, INT64_MAX};
  char num[400], msg[600];
  if (kind == REN_ELEM_F32) {
    ren_format_float(num, v.f);
    snprintf(msg, sizeof msg,
             "%s doesn't fit in a `Float32`, which holds up to about 3.4e38",
             num);
  } else {
    bool sign = kind == REN_ELEM_I8 || kind == REN_ELEM_I16 ||
                kind == REN_ELEM_I32;
    snprintf(msg, sizeof msg,
             "%" PRId64 " doesn't fit in %s `%s`, which holds %" PRId64
             " to %" PRId64,
             v.i, sign ? "an" : "a", names[kind], lo[kind], hi[kind]);
  }
  ren_panic(site, msg);
}

int64_t ren_div(int64_t a, int64_t b, const ren_site *site) {
  if (b == 0)
    ren_panic(site, "division by zero");
  if (a == INT64_MIN && b == -1) {
    char msg[128];
    snprintf(msg, sizeof msg, "`/` overflowed: %" PRId64 " / %" PRId64, a, b);
    ren_panic(site, msg);
  }
  return a / b;
}

int64_t ren_rem(int64_t a, int64_t b, const ren_site *site) {
  if (b == 0)
    ren_panic(site, "division by zero");
  /* INT64_MIN % -1 traps in C; it's 0, as OCaml's Int64.rem says */
  if (b == -1)
    return 0;
  return a % b;
}

int64_t ren_neg(int64_t a, const ren_site *site) {
  if (a == INT64_MIN) {
    char msg[128];
    snprintf(msg, sizeof msg, "`-` overflowed: -(%" PRId64 ")", a);
    ren_panic(site, msg);
  }
  return -a;
}

/* [r], [f] rounded by [how], if it's an `Int`: builtins.ml's `to_int`. */
static int64_t ren_to_int(double r, double f, const char *how,
                          const ren_site *site) {
  if (isnan(f)) {
    char what[64];
    snprintf(what, sizeof what, "`%s` of a NaN", how);
    ren_nan_panic(site, what, f);
  }
  if (isfinite(r) && r >= -9.223372036854775808e18 &&
      r < 9.223372036854775808e18)
    return (int64_t)r;
  char x[400], msg[500];
  ren_format_float(x, f);
  snprintf(msg, sizeof msg, "`%s` of %s doesn't fit in an `Int`", how, x);
  ren_panic(site, msg);
}

int64_t ren_fround(double a, const ren_site *site) {
  return ren_to_int(round(a), a, "round", site);
}

int64_t ren_ftruncate(double a, const ren_site *site) {
  return ren_to_int(trunc(a), a, "truncate", site);
}

/* ---- descriptors ---- */

const char *const *ren_tag_names;

/* [d] with each parameter it names replaced by what [*env] gives it, and
   [*env] made what that's read under. */
static const ren_desc *ren_resolve(const ren_desc *d, const ren_tenv **env) {
  while (d->kind == REN_D_VAR) {
    d = (*env)->args[d->var];
    *env = (*env)->up;
  }
  return d;
}

static bool ren_counted_in(const ren_desc *d, const ren_tenv *env) {
  d = ren_resolve(d, &env);
  if (d->kind == REN_D_NAMED && d->decl->kind == REN_DECL_REP) {
    ren_tenv inner = {d->args, env};
    return ren_counted_in(d->decl->rep, &inner);
  }
  return d->counted;
}

ren_obj *ren_desc_new(uint8_t kind, const ren_decl *decl, int64_t nargs,
                      ren_obj *const *args) {
  size_t bytes = sizeof(ren_desc) + (size_t)nargs * sizeof(ren_desc *);
  ren_desc *d = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  ren_desc **kept = (ren_desc **)(d + 1);
  for (int64_t i = 0; i < nargs; i++) {
    ren_dup(args[i]);
    kept[i] = (ren_desc *)args[i];
  }
  d->h.rc = 1;
  d->h.tag = REN_TAG_DESC;
  d->h.nfields = 0;
  d->h.objs = 0;
  d->kind = kind;
  d->nargs = (uint16_t)nargs;
  d->var = 0;
  d->decl = decl;
  d->args = kept;
  switch (kind) {
  case REN_D_NAMED: {
    ren_tenv env = {d->args, NULL};
    if (decl->kind == REN_DECL_REP)
      d->counted = ren_counted_in(decl->rep, &env);
    else
      d->counted = !decl->enumlike;
    break;
  }
  default: /* an array or a tuple */
    d->counted = 1;
  }
  return &d->h;
}

/* A string being built, which grows as it's written to. */
typedef struct {
  char *data;
  size_t len, cap;
} ren_buf;

static void ren_put(ren_buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    while (b->len + n + 1 > b->cap)
      b->cap = b->cap ? b->cap * 2 : 64;
    b->data = realloc(b->data, b->cap);
    if (b->data == NULL) {
      fflush(stdout);
      fputs("error: out of memory\n", stderr);
      exit(1);
    }
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void ren_puts(ren_buf *b, const char *s) { ren_put(b, s, strlen(s)); }

/* A `Str` as it's written, in quotes: token.ml's `show_str`. */
static void ren_put_quoted(ren_buf *b, ren_obj *s) {
  ren_puts(b, "\"");
  const char *d = ren_str_data(s);
  for (int64_t i = 0; i < ren_str_len(s); i++) {
    switch (d[i]) {
    case '\n':
      ren_puts(b, "\\n");
      break;
    case '\t':
      ren_puts(b, "\\t");
      break;
    case '\\':
      ren_puts(b, "\\\\");
      break;
    case '"':
      ren_puts(b, "\\\"");
      break;
    default:
      ren_put(b, &d[i], 1);
    }
  }
  ren_puts(b, "\"");
}

/* The tag of a sum type's value, an object's or the scalar's. */
static int64_t ren_ctor_tag(const ren_decl *decl, ren_val v) {
  return decl->enumlike ? v.i : ren_tag(v.o);
}

/* A walk's site: where a NaN it finds panics, and what it says; whether
   it goes through a type's `key` ([keyed]), as `==`, ordering and `hash`
   do, and, hashing, whether it's `x.hash()`'s, with no seed ([fixed]). */
typedef struct {
  const ren_site *site;
  const char *what;
  bool keyed;
  bool fixed;
} ren_walk;

/* [v]'s key, a word the caller owns, through its type's [decl]. */
static inline ren_val ren_key_of(const ren_decl *decl, ren_val v) {
  return decl->key(v);
}
static inline void ren_key_done(const ren_decl *decl, ren_val k) {
  ren_drop_val(k, &decl->keyd->h);
}

/* A map's live entries, in order: [e] each one's words, its hash first. */
#define REN_MAP_EACH(map, e)                                                  \
  for (ren_val *e = (map)->entries,                                           \
               *e##_end = e == NULL ? e : e + (map)->used * (map)->width;     \
       e < e##_end; e += (map)->width)                                        \
    if (e[0].i != 0)

static int64_t ren_map_find_in(ren_map *m, ren_val k, const ren_desc *kd,
                               const ren_tenv *env, const ren_walk *w);

/* [f], unless it's a NaN, which panics as [w] says. */
static inline void ren_walk_float(const ren_walk *w, double f) {
  if (__builtin_expect(isnan(f), 0))
    ren_nan_panic(w->site, w->what, f);
}

static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v, const ren_walk *w);

/* Each of [n] fields of [o], of the types [types] read under [env], with
   [names] before them if there are any; where they are is [c]'s, if
   there's one. */
static void ren_show_fields(ren_buf *b, ren_obj *o, const ren_ctor_info *c,
                            int32_t n, const char *const *names,
                            ren_desc *const *types, const ren_tenv *env,
                            const ren_walk *w) {
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    if (names != NULL) {
      ren_puts(b, names[i]);
      ren_puts(b, ": ");
    }
    ren_show_val(b, types[i], env, ren_ctor_field(o, c, i), w);
  }
}

/* An error: its tag, and its payload, through the descriptors it keeps
   after it. */
static void ren_show_error(ren_buf *b, ren_obj *e, const ren_walk *w) {
  ren_puts(b, ren_tag_names[ren_tag(e)]);
  if (ren_is_scalar(e))
    return;
  int32_t n = (int32_t)e->nfields / 2;
  ren_puts(b, "(");
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    ren_show_val(b, (ren_desc *)ren_fields(e)[n + i].o, NULL,
                 ren_fields(e)[i], w);
  }
  ren_puts(b, ")");
}

/* [v] as it's written: shown.ml's `value`. */
static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v, const ren_walk *w) {
  char num[400];
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_INT:
    snprintf(num, sizeof num, "%" PRId64, v.i);
    ren_puts(b, num);
    break;
  case REN_D_FLOAT:
    ren_walk_float(w, v.f);
    ren_format_float(num, v.f);
    ren_puts(b, num);
    break;
  /* a sized type's value, as a word, is the number it holds */
  case REN_D_SIZED:
    if (d->var == REN_ELEM_F32) {
      ren_walk_float(w, v.f);
      ren_format_float(num, v.f);
    } else
      snprintf(num, sizeof num, "%" PRId64, v.i);
    ren_puts(b, num);
    break;
  case REN_D_BOOL:
    ren_puts(b, v.i ? "true" : "false");
    break;
  case REN_D_UNIT:
  case REN_D_UNKNOWN:
    ren_puts(b, "()");
    break;
  case REN_D_STR:
    ren_put_quoted(b, v.o);
    break;
  case REN_D_BYTES: { /* value.ml's `show`: each byte in hex */
    ren_puts(b, "<bytes");
    for (int64_t i = 0; i < ren_str_len(v.o); i++) {
      char hex[8];
      snprintf(hex, sizeof hex, " %02x",
               (unsigned char)ren_str_data(v.o)[i]);
      ren_puts(b, hex);
    }
    ren_puts(b, ">");
    break;
  }
  case REN_D_ARRAY: {
    ren_array *a = (ren_array *)v.o;
    ren_puts(b, "[");
    for (int64_t i = 0; i < a->len; i++) {
      if (i > 0)
        ren_puts(b, ", ");
      ren_show_val(b, d->args[0], env, ren_array_load(v.o, i), w);
    }
    ren_puts(b, "]");
    break;
  }
  case REN_D_TUPLE:
    ren_puts(b, "(");
    ren_show_fields(b, v.o, NULL, d->nargs, NULL, d->args, env, w);
    ren_puts(b, ")");
    break;
  case REN_D_ERRORS:
    ren_show_error(b, v.o, w);
    break;
  /* as value.ml shows one */
  case REN_D_HANDLER:
    ren_puts(b, "<handler>");
    break;
  /* as it's made, in order (shown.ml) */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    bool set = d->kind == REN_D_SET;
    ren_puts(b, set ? "Set.of([" : "Map.of([");
    bool first = true;
    REN_MAP_EACH(m, e) {
      if (!first)
        ren_puts(b, ", ");
      first = false;
      if (set)
        ren_show_val(b, d->args[0], env, e[1], w);
      else {
        ren_puts(b, "(");
        ren_show_val(b, d->args[0], env, e[1], w);
        ren_puts(b, ", ");
        ren_show_val(b, d->args[1], env, e[2], w);
        ren_puts(b, ")");
      }
    }
    ren_puts(b, "])");
    break;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->kind == REN_DECL_REP) {
      ren_puts(b, decl->name);
      ren_puts(b, "(");
      ren_show_val(b, decl->rep, &inner, v, w);
      ren_puts(b, ")");
    } else if (decl->kind == REN_DECL_RECORD) {
      const ren_ctor_info *c = &decl->ctors[0];
      ren_puts(b, decl->name);
      ren_puts(b, decl->opaque ? "(" : " { ");
      ren_show_fields(b, v.o, c, c->nfields, c->fields, c->types, &inner, w);
      ren_puts(b, decl->opaque ? ")" : " }");
    } else {
      /* a by-name constructor's fields after their names, in braces,
         as it's built: `Rect { w: 2, h: 3 }` */
      const ren_ctor_info *c = &decl->ctors[ren_ctor_tag(decl, v)];
      ren_puts(b, c->name);
      if (c->nfields > 0) {
        ren_puts(b, c->fields != NULL ? " { " : "(");
        ren_show_fields(b, v.o, c, c->nfields, c->fields, c->types, &inner, w);
        ren_puts(b, c->fields != NULL ? " }" : ")");
      }
    }
    break;
  }
  }
}

ren_obj *ren_show_any(ren_obj *d, ren_val v, const ren_site *site) {
  if (((ren_desc *)d)->kind == REN_D_STR) {
    ren_dup(v.o);
    return v.o;
  }
  ren_walk w = {site, "`show` of a NaN", false, false};
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v, &w);
  ren_obj *s = ren_str_of(b.data, (int64_t)b.len);
  free(b.data);
  return s;
}

void ren_print_value(FILE *out, ren_obj *d, ren_val v, const ren_site *site) {
  ren_walk w = {site, "`show` of a NaN", false, false};
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v, &w);
  fwrite(b.data, 1, b.len, out);
  free(b.data);
}

void ren_print_result(ren_obj *d, ren_val v, const ren_site *site) {
  ren_print_value(stdout, d, v, site);
  fputc('\n', stdout);
}

static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b, const ren_walk *w);

static bool ren_equal_fields(ren_obj *a, ren_obj *b, const ren_ctor_info *c,
                             int32_t n, ren_desc *const *types,
                             const ren_tenv *env, const ren_walk *w) {
  for (int32_t i = 0; i < n; i++)
    if (!ren_equal_in(types[i], env, ren_ctor_field(a, c, i),
                      ren_ctor_field(b, c, i), w))
      return false;
  return true;
}

/* walk.ml's `equal`, part by part. */
static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b, const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return a.f == b.f;
  case REN_D_SIZED:
    if (d->var != REN_ELEM_F32)
      return a.i == b.i;
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return a.f == b.f;
  case REN_D_STR:
  case REN_D_BYTES:
    return ren_str_eq(a.o, b.o);
  case REN_D_ARRAY: {
    ren_array *x = (ren_array *)a.o, *y = (ren_array *)b.o;
    if (x->len != y->len)
      return false;
    for (int64_t i = 0; i < x->len; i++)
      if (!ren_equal_in(d->args[0], env, ren_array_load(a.o, i),
                        ren_array_load(b.o, i), w))
        return false;
    return true;
  }
  case REN_D_TUPLE:
    return ren_equal_fields(a.o, b.o, NULL, d->nargs, d->args, env, w);
  case REN_D_ERRORS: {
    if (ren_tag(a.o) != ren_tag(b.o))
      return false;
    if (ren_is_scalar(a.o))
      return true;
    int32_t n = (int32_t)a.o->nfields / 2;
    for (int32_t i = 0; i < n; i++)
      if (!ren_equal_in((ren_desc *)ren_fields(a.o)[n + i].o, NULL,
                        ren_fields(a.o)[i], ren_fields(b.o)[i], w))
        return false;
    return true;
  }
  /* the same keys, each with an equal value, in any order (walk.ml) */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *x = (ren_map *)a.o, *y = (ren_map *)b.o;
    if (x->len != y->len)
      return false;
    REN_MAP_EACH(x, e) {
      int64_t i = ren_map_find_in(y, e[1], d->args[0], env, w);
      if (i < 0)
        return false;
      if (d->kind == REN_D_MAP &&
          !ren_equal_in(d->args[1], env, e[2], y->entries[i * y->width + 2], w))
        return false;
    }
    return true;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    /* through its key, the one way to change what equal means */
    if (decl->key != NULL) {
      ren_val ka = ren_key_of(decl, a), kb = ren_key_of(decl, b);
      bool same = ren_equal_in(decl->keyd, NULL, ka, kb, w);
      ren_key_done(decl, ka);
      ren_key_done(decl, kb);
      return same;
    }
    if (decl->kind == REN_DECL_REP)
      return ren_equal_in(decl->rep, &inner, a, b, w);
    if (decl->kind == REN_DECL_RECORD)
      return ren_equal_fields(a.o, b.o, &decl->ctors[0],
                              decl->ctors[0].nfields, decl->ctors[0].types,
                              &inner, w);
    int64_t tag = ren_ctor_tag(decl, a);
    if (tag != ren_ctor_tag(decl, b))
      return false;
    const ren_ctor_info *c = &decl->ctors[tag];
    return c->nfields == 0 ||
           ren_equal_fields(a.o, b.o, c, c->nfields, c->types, &inner, w);
  }
  default: /* an `Int`, a `Bool` or `Unit` */
    return a.i == b.i;
  }
}

static void ren_nan_val(const ren_desc *d, const ren_tenv *env, ren_val v,
                        const ren_walk *w);

/* walk.ml's [equal]: a comparison that ends early, unequal, hasn't met
   every leaf, so it looks through both values for a NaN, [a]'s first;
   comparing a value with one in it panics, met or not. */
bool ren_equal_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                   const ren_site *site) {
  ren_walk w = {site, what, true, false};
  bool same = ren_equal_in((ren_desc *)d, NULL, a, b, &w);
  if (!same) {
    ren_nan_val((ren_desc *)d, NULL, a, &w);
    ren_nan_val((ren_desc *)d, NULL, b, &w);
  }
  return same;
}

#define REN_CMP(x, y) ((x) < (y) ? -1 : (x) > (y) ? 1 : 0)

/* walk.ml's `compare`: what inference allows an order on. */
static int64_t ren_compare_in(const ren_desc *d, const ren_tenv *env,
                              ren_val a, ren_val b, const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return REN_CMP(a.f, b.f);
  case REN_D_SIZED:
    if (d->var != REN_ELEM_F32)
      return REN_CMP(a.i, b.i);
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return REN_CMP(a.f, b.f);
  case REN_D_STR:
  case REN_D_BYTES: {
    int64_t la = ren_str_len(a.o), lb = ren_str_len(b.o);
    int c = memcmp(ren_str_data(a.o), ren_str_data(b.o),
                   (size_t)(la < lb ? la : lb));
    return c != 0 ? c : REN_CMP(la, lb);
  }
  case REN_D_TUPLE:
    for (uint16_t i = 0; i < d->nargs; i++) {
      int64_t c = ren_compare_in(d->args[i], env, ren_fields(a.o)[i],
                                 ren_fields(b.o)[i], w);
      if (c != 0)
        return c;
    }
    return 0;
  case REN_D_NAMED: {
    ren_tenv inner = {d->args, env};
    if (d->decl->key != NULL) {
      ren_val ka = ren_key_of(d->decl, a), kb = ren_key_of(d->decl, b);
      int64_t c = ren_compare_in(d->decl->keyd, NULL, ka, kb, w);
      ren_key_done(d->decl, ka);
      ren_key_done(d->decl, kb);
      return c;
    }
    if (d->decl->kind == REN_DECL_REP)
      return ren_compare_in(d->decl->rep, &inner, a, b, w);
    return REN_CMP(ren_ctor_tag(d->decl, a), ren_ctor_tag(d->decl, b));
  }
  default: /* an `Int` or a `Bool` */
    return REN_CMP(a.i, b.i);
  }
}

int64_t ren_compare_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                        const ren_site *site) {
  ren_walk w = {site, what, true, false};
  int64_t c = ren_compare_in((ren_desc *)d, NULL, a, b, &w);
  /* as [ren_equal_any]: an order decided early looks for a NaN */
  if (c != 0) {
    ren_nan_val((ren_desc *)d, NULL, a, &w);
    ren_nan_val((ren_desc *)d, NULL, b, &w);
  }
  return c;
}

/* [xs], [n] words, sorted, through [tmp], as much room again. */
static void ren_merge_sort(ren_obj *d, ren_val *xs, ren_val *tmp, int64_t n,
                           const char *what, const ren_site *site) {
  if (n < 2)
    return;
  int64_t h = n / 2;
  ren_merge_sort(d, xs, tmp, h, what, site);
  ren_merge_sort(d, xs + h, tmp, n - h, what, site);
  int64_t i = 0, j = h, k = 0;
  /* the right one first only if it's less, so equal ones keep their
     order */
  while (i < h && j < n)
    tmp[k++] = ren_compare_any(d, xs[j], xs[i], what, site) < 0 ? xs[j++]
                                                                 : xs[i++];
  while (i < h)
    tmp[k++] = xs[i++];
  while (j < n)
    tmp[k++] = xs[j++];
  memcpy(xs, tmp, (size_t)n * sizeof(ren_val));
}

ren_obj *ren_array_sort(ren_obj *a, ren_obj *d, const char *what,
                        const ren_site *site) {
  int64_t n = ren_array_len(a);
  ren_val *xs = malloc((size_t)(2 * n + 1) * sizeof(ren_val));
  if (xs == NULL)
    ren_out_of_memory();
  for (int64_t i = 0; i < n; i++)
    xs[i] = ren_array_load(a, i);
  ren_merge_sort(d, xs, xs + n, n, what, site);
  ren_obj *r = ren_alloc_array_d(n, d);
  for (int64_t i = 0; i < n; i++) {
    if (r->objs)
      ren_dup(xs[i].o);
    ren_array_init_w(r, i, xs[i]);
  }
  free(xs);
  return r;
}

_Noreturn void ren_panic_str(const ren_site *site, ren_obj *s) {
  int64_t n = ren_str_len(s);
  char *msg = malloc((size_t)n + 1);
  if (msg == NULL)
    ren_out_of_memory();
  memcpy(msg, ren_str_data(s), (size_t)n);
  msg[n] = 0;
  ren_panic(site, msg);
}

/* walk.ml's [nan_in]: the first NaN in [v], in the order its parts are
   declared. */
static void ren_nan_val(const ren_desc *d, const ren_tenv *env, ren_val v,
                        const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, v.f);
    break;
  case REN_D_SIZED:
    if (d->var == REN_ELEM_F32)
      ren_walk_float(w, v.f);
    break;
  case REN_D_ARRAY: {
    ren_array *a = (ren_array *)v.o;
    for (int64_t i = 0; i < a->len; i++)
      ren_nan_val(d->args[0], env, ren_array_load(v.o, i), w);
    break;
  }
  case REN_D_TUPLE:
    for (uint16_t i = 0; i < d->nargs; i++)
      ren_nan_val(d->args[i], env, ren_fields(v.o)[i], w);
    break;
  case REN_D_ERRORS:
    if (!ren_is_scalar(v.o)) {
      int32_t n = (int32_t)v.o->nfields / 2;
      for (int32_t i = 0; i < n; i++)
        ren_nan_val((ren_desc *)ren_fields(v.o)[n + i].o, NULL,
                    ren_fields(v.o)[i], w);
    }
    break;
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    REN_MAP_EACH(m, e) {
      ren_nan_val(d->args[0], env, e[1], w);
      if (d->kind == REN_D_MAP)
        ren_nan_val(d->args[1], env, e[2], w);
    }
    break;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    /* what's compared is seen through its key (walk.ml, [nan_compared]);
       what's given to an operation isn't */
    if (w->keyed && decl->key != NULL) {
      ren_val k = ren_key_of(decl, v);
      ren_nan_val(decl->keyd, NULL, k, w);
      ren_key_done(decl, k);
      break;
    }
    if (decl->kind == REN_DECL_REP) {
      ren_nan_val(decl->rep, &inner, v, w);
      break;
    }
    const ren_ctor_info *c =
        decl->kind == REN_DECL_RECORD ? &decl->ctors[0]
                                      : &decl->ctors[ren_ctor_tag(decl, v)];
    for (int32_t i = 0; i < c->nfields; i++)
      ren_nan_val(c->types[i], &inner, ren_ctor_field(v.o, c, i), w);
    break;
  }
  default:
    break;
  }
}

void ren_nan_in(ren_obj *d, ren_val v, const char *what, const ren_site *site) {
  ren_walk w = {site, what, false, false};
  ren_nan_val((ren_desc *)d, NULL, v, &w);
}

/* ---- hashing ----

   Two walks over a value, which agree with `==` (walk.ml, [hash]): by
   its key if its type has one; an `Int` as its 64 bits; a `Float` as its
   bits, `-0.0` as `0.0`, a NaN panicking; a `Str` or `Bytes` by its
   bytes; a record, a tuple, a constructor, an array, an error by its
   parts in order, each mixed in; a map or a set by its entries' hashes
   added, so the same in any order. [fixed] is `x.hash()`'s, walk.ml's
   with the seed 0, FNV-1a's step, the same bits as the interpreter's.
   The other is a map's, a wyhash-class mix with [ren_map_seed]. */

uint64_t ren_map_seed;

#define REN_FNV_PRIME UINT64_C(0x100000001b3)
#define REN_FNV_BASIS UINT64_C(0xcbf29ce484222325)
#define REN_WY0 UINT64_C(0x2d358dccaa6c78a5)
#define REN_WY1 UINT64_C(0x8bb84b93962eacc9)
#define REN_WY2 UINT64_C(0x4b33a62ed433d4a3)

/* [a] times [b], 128 bits, its halves xored: wyhash's `mum`. tcc has no
   128-bit type, so it multiplies the halves; both give the same bits. */
static inline uint64_t ren_mum(uint64_t a, uint64_t b) {
#ifdef __SIZEOF_INT128__
  __uint128_t r = (__uint128_t)a * b;
  return (uint64_t)r ^ (uint64_t)(r >> 64);
#else
  uint64_t ha = a >> 32, la = (uint32_t)a, hb = b >> 32, lb = (uint32_t)b;
  uint64_t rh = ha * hb, rm0 = ha * lb, rm1 = hb * la, rl = la * lb;
  uint64_t t = rl + (rm0 << 32), c = t < rl;
  uint64_t lo = t + (rm1 << 32);
  c += lo < t;
  uint64_t hi = rh + (rm0 >> 32) + (rm1 >> 32) + c;
  return lo ^ hi;
#endif
}

static inline uint64_t ren_read8(const unsigned char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}
static inline uint64_t ren_read4(const unsigned char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

/* [n] bytes at [p], seeded: wyhash's (final version 4), which reads 16
   bytes a step and at most two overlapping loads for what's left. */
static uint64_t ren_wyhash(const unsigned char *p, size_t n, uint64_t seed) {
  seed ^= ren_mum(seed ^ REN_WY0, REN_WY1);
  uint64_t a, b;
  if (n <= 16) {
    if (n >= 4) {
      size_t k = (n >> 3) << 2;
      a = (ren_read4(p) << 32) | ren_read4(p + k);
      b = (ren_read4(p + n - 4) << 32) | ren_read4(p + n - 4 - k);
    } else if (n > 0) {
      a = ((uint64_t)p[0] << 16) | ((uint64_t)p[n >> 1] << 8) | p[n - 1];
      b = 0;
    } else
      a = b = 0;
  } else {
    size_t i = n;
    while (i > 16) {
      seed = ren_mum(ren_read8(p) ^ REN_WY1, ren_read8(p + 8) ^ seed);
      p += 16;
      i -= 16;
    }
    a = ren_read8(p + i - 16);
    b = ren_read8(p + i - 8);
  }
  return ren_mum(REN_WY1 ^ n, ren_mum(a ^ REN_WY1, b ^ seed));
}

/* Two hashes made one, so each part's place counts: walk.ml's [mix]. */
static inline uint64_t ren_mix(const ren_walk *w, uint64_t h, uint64_t x) {
  return w->fixed ? (h ^ x) * REN_FNV_PRIME
                  : ren_mum(h ^ x ^ REN_WY0, ren_map_seed ^ REN_WY1);
}

/* A string's bytes: walk.ml's [hash_string], or seeded. */
static uint64_t ren_hash_chars(const ren_walk *w, const char *s, int64_t n) {
  if (!w->fixed)
    return ren_wyhash((const unsigned char *)s, (size_t)n, ren_map_seed);
  uint64_t h = REN_FNV_BASIS;
  for (int64_t i = 0; i < n; i++)
    h = (h ^ (unsigned char)s[i]) * REN_FNV_PRIME;
  return h;
}

static uint64_t ren_hash_in(const ren_desc *d, const ren_tenv *env, ren_val v,
                            const ren_walk *w);

/* A `Float`'s: `-0.0` is `0.0`, which `==` says it equals. */
static inline uint64_t ren_hash_float(const ren_walk *w, double f) {
  ren_walk_float(w, f);
  uint64_t bits;
  if (f == 0)
    f = 0;
  memcpy(&bits, &f, 8);
  return ren_mix(w, 2, bits);
}

/* [h] with each of [n] fields of [o] mixed in, in order. */
static uint64_t ren_hash_fields(uint64_t h, ren_obj *o, const ren_ctor_info *c,
                                int32_t n, ren_desc *const *types,
                                const ren_tenv *env, const ren_walk *w) {
  for (int32_t i = 0; i < n; i++)
    h = ren_mix(w, h, ren_hash_in(types[i], env, ren_ctor_field(o, c, i), w));
  return h;
}

static uint64_t ren_hash_in(const ren_desc *d, const ren_tenv *env, ren_val v,
                            const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_INT:
    return ren_mix(w, 1, (uint64_t)v.i);
  case REN_D_FLOAT:
    return ren_hash_float(w, v.f);
  case REN_D_SIZED:
    return d->var == REN_ELEM_F32 ? ren_hash_float(w, v.f)
                                  : ren_mix(w, 1, (uint64_t)v.i);
  case REN_D_STR:
    return ren_mix(w, 3, ren_hash_chars(w, ren_str_data(v.o), ren_str_len(v.o)));
  case REN_D_BYTES:
    return ren_mix(w, 4, ren_hash_chars(w, ren_str_data(v.o), ren_str_len(v.o)));
  case REN_D_BOOL:
    return ren_mix(w, 5, v.i ? 1 : 0);
  case REN_D_ARRAY: {
    uint64_t h = 9;
    for (int64_t i = 0; i < ren_array_len(v.o); i++)
      h = ren_mix(w, h, ren_hash_in(d->args[0], env, ren_array_load(v.o, i), w));
    return h;
  }
  case REN_D_TUPLE:
    return ren_hash_fields(11, v.o, NULL, d->nargs, d->args, env, w);
  case REN_D_ERRORS: {
    const char *name = ren_tag_names[ren_tag(v.o)];
    uint64_t h = ren_mix(w, 10, ren_hash_chars(w, name, (int64_t)strlen(name)));
    if (ren_is_scalar(v.o))
      return h;
    int32_t n = (int32_t)v.o->nfields / 2;
    for (int32_t i = 0; i < n; i++)
      h = ren_mix(w, h,
                  ren_hash_in((ren_desc *)ren_fields(v.o)[n + i].o, NULL,
                              ren_fields(v.o)[i], w));
    return h;
  }
  /* each entry's hash, added, so the same in any order, as `==` is */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    uint64_t h = d->kind == REN_D_MAP ? 12 : 13;
    REN_MAP_EACH(m, e) {
      uint64_t k = ren_hash_in(d->args[0], env, e[1], w);
      h += d->kind == REN_D_MAP
               ? ren_mix(w, k, ren_hash_in(d->args[1], env, e[2], w))
               : k;
    }
    return h;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->key != NULL) {
      ren_val k = ren_key_of(decl, v);
      uint64_t h = ren_hash_in(decl->keyd, NULL, k, w);
      ren_key_done(decl, k);
      return h;
    }
    if (decl->kind == REN_DECL_REP)
      return ren_hash_in(decl->rep, &inner, v, w);
    if (decl->kind == REN_DECL_RECORD)
      return ren_hash_fields(7, v.o, &decl->ctors[0], decl->ctors[0].nfields,
                             decl->ctors[0].types, &inner, w);
    int64_t tag = ren_ctor_tag(decl, v);
    const ren_ctor_info *c = &decl->ctors[tag];
    uint64_t h = ren_mix(w, 8, (uint64_t)tag);
    return c->nfields == 0
               ? h
               : ren_hash_fields(h, v.o, c, c->nfields, c->types, &inner, w);
  }
  default: /* `Unit`, and a type variable nothing decided */
    return 6;
  }
}

int64_t ren_hash_fixed(ren_obj *d, ren_val v, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, true};
  return (int64_t)ren_hash_in((ren_desc *)d, NULL, v, &w);
}

/* ---- maps and sets ---- */

/* A key's hash, as a map keeps it: never 0, which marks a removed
   entry. An `Int`'s and a `Str`'s without the walk's switch. */
static inline uint64_t ren_key_hash(const ren_desc *kd, const ren_tenv *env,
                                    ren_val k, const ren_walk *w) {
  uint64_t h;
  switch (kd->kind) {
  case REN_D_INT:
    h = ren_mix(w, 1, (uint64_t)k.i);
    break;
  case REN_D_STR:
    h = ren_mix(w, 3, ren_wyhash((const unsigned char *)ren_str_data(k.o),
                                 (size_t)ren_str_len(k.o), ren_map_seed));
    break;
  default:
    h = ren_hash_in(kd, env, k, w);
  }
  return h ? h : 1;
}

/* Two keys the same: [ren_equal_in], an `Int`'s and a `Str`'s without
   its switch. */
static inline bool ren_key_eq(const ren_desc *kd, const ren_tenv *env,
                              ren_val a, ren_val b, const ren_walk *w) {
  switch (kd->kind) {
  case REN_D_INT:
    return a.i == b.i;
  case REN_D_STR:
    return ren_str_eq(a.o, b.o);
  default:
    return ren_equal_in(kd, env, a, b, w);
  }
}

/* [n] entries' and [slots] slots' bytes, for the statistics. */
static inline int64_t ren_map_bytes(int64_t cap, int32_t width, int32_t shift) {
  return cap * width * (int64_t)sizeof(ren_val) +
         (shift ? ((int64_t)1 << shift) * (int64_t)sizeof(int32_t) : 0);
}

ren_obj *ren_map_new(bool set) {
  ren_map *m = ren_alloc_bytes(sizeof(ren_map));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_map));
#endif
  m->h.rc = 1;
  m->h.tag = REN_TAG_MAP;
  m->h.nfields = set;
  m->h.objs = 0;
  m->len = m->used = m->cap = 0;
  m->shift = 0;
  m->width = set ? 2 : 3;
  m->entries = NULL;
  m->index = NULL;
  return &m->h;
}

/* The index made again for [m]'s entries, its size for [m->cap] of them,
   at most 2/3 full: each entry's slot found from the hash it keeps. */
static void ren_map_reindex(ren_map *m) {
  int32_t shift = 3;
  while (((int64_t)1 << shift) * 2 < m->cap * 3)
    shift++;
  if (shift != m->shift) {
#ifdef REN_STATS
    ren_stats.live_bytes += ren_map_bytes(0, 0, shift) - ren_map_bytes(0, 0, m->shift);
    if (ren_stats.live_bytes > ren_stats.peak_bytes)
      ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
    free(m->index);
    m->index = ren_malloc(((size_t)1 << shift) * sizeof(int32_t));
    m->shift = shift;
  }
  uint64_t mask = ((uint64_t)1 << shift) - 1;
  memset(m->index, 0xFF, ((size_t)1 << shift) * sizeof(int32_t));
  for (int64_t e = 0; e < m->used; e++) {
    uint64_t h = (uint64_t)m->entries[e * m->width].i;
    if (h == 0)
      continue;
    uint64_t i = h >> (64 - shift);
    while (m->index[i] != REN_MAP_EMPTY)
      i = (i + 1) & mask;
    m->index[i] = (int32_t)e;
  }
}

/* The removed entries taken out, the live ones kept in order. */
static void ren_map_compact(ren_map *m) {
  int64_t to = 0;
  for (int64_t e = 0; e < m->used; e++)
    if (m->entries[e * m->width].i != 0) {
      if (to != e)
        memcpy(&m->entries[to * m->width], &m->entries[e * m->width],
               (size_t)m->width * sizeof(ren_val));
      to++;
    }
  m->used = to;
}

/* Room for one entry more in [m], unique: its entries compacted if a
   third or more are removed, or else doubled, and the index made again.
   The index's slots are 32 bits, so a map has at most 2^31 - 1. */
static void ren_map_room(ren_map *m) {
  if (m->used < m->cap)
    return;
  int64_t removed = m->used - m->len;
  int64_t cap = m->cap;
  if (m->used == 0 || removed * 3 < m->used)
    cap = cap < 8 ? 8 : cap * 2;
  if (cap > INT32_MAX) {
    fflush(stdout);
    fputs("error: a `Map` or a `Set` of more than 2^31 - 1 entries isn't "
          "built yet\n",
          stderr);
    exit(1);
  }
  ren_map_compact(m);
  if (cap != m->cap) {
    ren_val *entries =
        realloc(m->entries, (size_t)cap * (size_t)m->width * sizeof(ren_val));
    if (entries == NULL)
      ren_out_of_memory();
#ifdef REN_STATS
    ren_stats.grows++;
    ren_stats.live_bytes += (cap - m->cap) * m->width * (int64_t)sizeof(ren_val);
    if (ren_stats.live_bytes > ren_stats.peak_bytes)
      ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
    m->entries = entries;
    m->cap = cap;
  }
  ren_map_reindex(m);
}

/* The entry whose key is [k], of hash [h], or -1, with [*slot] the
   empty slot the probe ended at. */
static inline int64_t ren_map_probe(ren_map *m, uint64_t h, ren_val k,
                                    const ren_desc *kd, const ren_tenv *env,
                                    const ren_walk *w, uint64_t *slot) {
  if (m->shift == 0)
    return -1;
  uint64_t mask = ((uint64_t)1 << m->shift) - 1;
  uint64_t i = h >> (64 - m->shift);
  for (;; i = (i + 1) & mask) {
    int32_t e = m->index[i];
    if (e == REN_MAP_EMPTY) {
      *slot = i;
      return -1;
    }
    if (e >= 0) {
      ren_val *ent = &m->entries[(int64_t)e * m->width];
      if ((uint64_t)ent[0].i == h && ren_key_eq(kd, env, ent[1], k, w))
        return e;
    }
  }
}

static int64_t ren_map_find_in(ren_map *m, ren_val k, const ren_desc *kd,
                               const ren_tenv *env, const ren_walk *w) {
  uint64_t slot;
  /* a key's type's descriptor read under [env] hashes as the map's own
     did, which had it resolved */
  const ren_desc *rd = ren_resolve(kd, &env);
  return ren_map_probe(m, ren_key_hash(rd, env, k, w), k, rd, env, w, &slot);
}

int64_t ren_map_find(ren_obj *m, ren_val k, ren_obj *kd, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  uint64_t slot;
  const ren_desc *d = (const ren_desc *)kd;
  return ren_map_probe((ren_map *)m, ren_key_hash(d, NULL, k, &w), k, d, NULL,
                       &w, &slot);
}

/* A copy of [m] with room for [extra] entries more, its removed ones
   left out, each key and value counted again. */
static ren_map *ren_map_copy(ren_map *m, int64_t extra) {
  ren_map *c = (ren_map *)ren_map_new(m->h.nfields);
  c->h.objs = m->h.objs;
  int64_t cap = m->len + extra;
  c->cap = cap < 8 ? 8 : cap;
  c->entries = ren_malloc((size_t)c->cap * (size_t)c->width * sizeof(ren_val));
#ifdef REN_STATS
  ren_stats.live_bytes += c->cap * c->width * (int64_t)sizeof(ren_val);
#endif
  int64_t to = 0;
  REN_MAP_EACH(m, e) {
    memcpy(&c->entries[to * c->width], e, (size_t)c->width * sizeof(ren_val));
    if (m->h.objs & 1)
      ren_dup(e[1].o);
    if ((m->h.objs & 2) && c->width > 2)
      ren_dup(e[2].o);
    to++;
  }
  c->len = c->used = to;
  ren_map_reindex(c);
  return c;
}

/* [*cell], which is to change: itself if it's unique and [taking], and
   otherwise a copy, with room for one entry more, put in the cell. */
static ren_map *ren_map_writable(ren_obj **cell, bool taking) {
  ren_obj *o = *cell;
  if (taking && ren_is_unique(o))
    return (ren_map *)o;
  ren_map *c = ren_map_copy((ren_map *)o, 1);
  ren_drop(o);
  *cell = &c->h;
  return c;
}

/* [k] set to [v] in [m], unique, [k] of hash [h]: [owned] says whether
   [k] and [v] are taken or counted again where they're kept. */
static void ren_map_put(ren_map *m, uint64_t h, ren_val k, ren_val v,
                        const ren_desc *kd, const ren_walk *w, bool owned) {
  uint64_t slot;
  int64_t e = ren_map_probe(m, h, k, kd, NULL, w, &slot);
  bool kobj = m->h.objs & 1, vobj = m->h.objs & 2;
  if (e >= 0) {
    /* there: its first key stays, with the new value */
    if (owned && kobj)
      ren_drop(k.o);
    if (m->width > 2) {
      ren_val *at = &m->entries[e * m->width + 2];
      if (!owned && vobj)
        ren_dup(v.o);
      if (vobj)
        ren_drop(at->o);
      *at = v;
    } else if (owned && vobj)
      ren_drop(v.o);
    return;
  }
  if (m->used == m->cap) {
    ren_map_room(m);
    ren_map_probe(m, h, k, kd, NULL, w, &slot);
  }
  if (!owned) {
    if (kobj)
      ren_dup(k.o);
    if (vobj && m->width > 2)
      ren_dup(v.o);
  }
  ren_val *ent = &m->entries[m->used * m->width];
  ent[0].i = (int64_t)h;
  ent[1] = k;
  if (m->width > 2)
    ent[2] = v;
  m->index[slot] = (int32_t)m->used;
  m->used++;
  m->len++;
}

/* Whether a map of keys [kd] and values [vd] counts them. */
static inline uint8_t ren_map_objs(ren_obj *kd, ren_obj *vd) {
  return (uint8_t)((ren_desc_counted(kd) ? 1 : 0) |
                   (vd != NULL && ren_desc_counted(vd) ? 2 : 0));
}

void ren_map_set(ren_obj **cell, ren_val k, ren_val v, ren_obj *kd,
                 ren_obj *vd, bool taking, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  /* hashed first, so a NaN panics before anything changes */
  uint64_t h = ren_key_hash((ren_desc *)kd, NULL, k, &w);
  ren_map *m = ren_map_writable(cell, taking);
  m->h.objs = ren_map_objs(kd, vd);
  ren_map_put(m, h, k, v, (ren_desc *)kd, &w, taking);
}

void ren_map_remove(ren_obj **cell, ren_val k, ren_obj *kd, bool taking,
                    const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  const ren_desc *d = (const ren_desc *)kd;
  uint64_t h = ren_key_hash(d, NULL, k, &w), slot;
  if (ren_map_probe((ren_map *)*cell, h, k, d, NULL, &w, &slot) < 0)
    return;
  ren_map *m = ren_map_writable(cell, taking);
  int64_t e = ren_map_probe(m, h, k, d, NULL, &w, &slot);
  /* its slot is the one the probe found it at, marked removed */
  uint64_t mask = ((uint64_t)1 << m->shift) - 1;
  uint64_t i = h >> (64 - m->shift);
  while (m->index[i] != (int32_t)e)
    i = (i + 1) & mask;
  m->index[i] = REN_MAP_GONE;
  ren_val *ent = &m->entries[e * m->width];
  if (m->h.objs & 1)
    ren_drop(ent[1].o);
  if ((m->h.objs & 2) && m->width > 2)
    ren_drop(ent[2].o);
  ent[0].i = 0;
  m->len--;
}

ren_obj *ren_map_of(ren_obj *pairs, ren_obj *kd, ren_obj *vd, bool flat,
                    const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  bool set = vd == NULL;
  ren_map *m = (ren_map *)ren_map_new(set);
  m->h.objs = ren_map_objs(kd, vd);
  int64_t n = ren_array_len(pairs);
  for (int64_t i = 0; i < n; i++) {
    ren_val k, v = {0};
    if (set)
      k = ren_array_load(pairs, i);
    else if (flat) {
      k = ren_elems(pairs)[2 * i];
      v = ren_elems(pairs)[2 * i + 1];
    } else {
      ren_obj *t = ren_elems(pairs)[i].o;
      k = ren_fields(t)[0];
      v = ren_fields(t)[1];
    }
    ren_map_put(m, ren_key_hash((ren_desc *)kd, NULL, k, &w), k, v,
                (ren_desc *)kd, &w, false);
  }
  return &m->h;
}

ren_obj *ren_map_entries(ren_obj *o, bool flat) {
  ren_map *m = (ren_map *)o;
  if (flat) {
    /* never counted: [flat] only for two words that hold no object */
    ren_obj *a = ren_alloc_array_n(m->len, 2, 0);
    int64_t i = 0;
    REN_MAP_EACH(m, e) {
      ren_elems(a)[2 * i] = e[1];
      ren_elems(a)[2 * i + 1] = e[2];
      i++;
    }
    return a;
  }
  ren_obj *a = ren_alloc_array(m->len, true);
  int64_t i = 0;
  REN_MAP_EACH(m, e) {
    /* a tuple's fields that hold objects, as the map's do */
    ren_obj *t = ren_alloc_ctor(0, 2, o->objs);
    ren_fields(t)[0] = e[1];
    ren_fields(t)[1] = e[2];
    if (o->objs & 1)
      ren_dup(e[1].o);
    if (o->objs & 2)
      ren_dup(e[2].o);
    ren_elems(a)[i++].o = t;
  }
  return a;
}

/* Word [at] of each live entry of [o], as an array of [d]'s, counted
   again if [counted]. */
static ren_obj *ren_map_column(ren_obj *o, ren_obj *d, int at, bool counted) {
  ren_map *m = (ren_map *)o;
  ren_obj *a = ren_alloc_array_d(m->len, d);
  int64_t i = 0;
  REN_MAP_EACH(m, e) {
    if (counted)
      ren_dup(e[at].o);
    ren_array_init_w(a, i++, e[at]);
  }
  return a;
}

ren_obj *ren_map_keys(ren_obj *m, ren_obj *d) {
  return ren_map_column(m, d, 1, m->objs & 1);
}

ren_obj *ren_map_values(ren_obj *m, ren_obj *d) {
  return ren_map_column(m, d, 2, m->objs & 2);
}

/* The seed, from the system's randomness, once, when the program
   starts: /dev/urandom, which every system the runtime builds on has; if
   it can't be read, two addresses, which differ from run to run where
   the system places a program at random. */
static void ren_map_seed_init(void) {
  FILE *f = fopen("/dev/urandom", "rb");
  uint64_t s = 0;
  if (f == NULL || fread(&s, sizeof s, 1, f) != 1)
    s = (uint64_t)(uintptr_t)&s ^ ((uint64_t)(uintptr_t)&ren_map_seed << 17);
  if (f != NULL)
    fclose(f);
  ren_map_seed = s;
}

/* Whether a number type is a `Float`, or represented as one, rather
   than an `Int`. */
static bool ren_is_float(const ren_desc *d, const ren_tenv *env) {
  d = ren_resolve(d, &env);
  if (d->kind == REN_D_NAMED) {
    ren_tenv inner = {d->args, env};
    return ren_is_float(d->decl->rep, &inner);
  }
  return d->kind == REN_D_FLOAT;
}

ren_val ren_op_any(ren_obj *d, int op, ren_val a, ren_val b,
                   const ren_site *site, uint32_t tag) {
  ren_val r;
  if (ren_is_float((ren_desc *)d, NULL)) {
    switch (op) {
    case REN_OP_ADD:
      r.f = ren_fadd_d(a.f, b.f, tag);
      break;
    case REN_OP_SUB:
      r.f = ren_fsub_d(a.f, b.f, tag);
      break;
    case REN_OP_MUL:
      r.f = ren_fmul_d(a.f, b.f, tag);
      break;
    case REN_OP_DIV:
      r.f = ren_fdiv_d(a.f, b.f, tag);
      break;
    case REN_OP_REM:
      r.f = ren_frem_d(a.f, b.f, tag);
      break;
    default:
      r.f = -a.f;
    }
  } else {
    switch (op) {
    case REN_OP_ADD:
      r.i = ren_add(a.i, b.i, site);
      break;
    case REN_OP_SUB:
      r.i = ren_sub(a.i, b.i, site);
      break;
    case REN_OP_MUL:
      r.i = ren_mul(a.i, b.i, site);
      break;
    case REN_OP_DIV:
      r.i = ren_div(a.i, b.i, site);
      break;
    case REN_OP_REM:
      r.i = ren_rem(a.i, b.i, site);
      break;
    default:
      r.i = ren_neg(a.i, site);
    }
  }
  return r;
}

ren_val ren_value_any(ren_obj *d, bool one) {
  ren_val r;
  if (ren_is_float((ren_desc *)d, NULL))
    r.f = one ? 1.0 : 0.0;
  else
    r.i = one ? 1 : 0;
  return r;
}

/* Any error: one keeps its payload's descriptors. */
static ren_desc ren_errors_desc = {
    {0, REN_TAG_DESC, 0, 0}, REN_D_ERRORS, 1, 0, 0, NULL, NULL};

_Noreturn void ren_uncaught(ren_obj *e) {
  fflush(stdout);
  fputs("error: ", stderr);
  ren_print_value(stderr, &ren_errors_desc.h, (ren_val){.o = e},
                  ren_overflow_site);
  fputc('\n', stderr);
  exit(1);
}

/* ---- evidence ---- */

bool ren_desc_same(const ren_desc *a, const ren_desc *b) {
  if (a == b)
    return true;
  if (a->kind != b->kind || a->var != b->var || a->decl != b->decl ||
      a->nargs != b->nargs)
    return false;
  for (int i = 0; i < a->nargs; i++)
    if (!ren_desc_same(a->args[i], b->args[i]))
      return false;
  return true;
}

const ren_ev *ren_install(ren_ev *nodes, const ren_ev *outer, void *deps,
                          int64_t ndeps, const ren_impl *const *impls,
                          int nimpls) {
  const ren_key *wanted = deps;
  const ren_ev *ev = outer;
  for (int64_t i = 0; i < ndeps; i++)
    for (int j = 0; j < nimpls; j++)
      /* a description of one dependency has one implementation, which
         is it whichever it was made for: `let q: Jobs = queue()` made a
         `Chan<Job>`'s a `Jobs`'s */
      if (impls[j]->dep == wanted[i].from || (nimpls == 1 && ndeps == 1)) {
        nodes[i].dep = wanted[i].dep;
        nodes[i].nargs = wanted[i].nargs;
        nodes[i].args = wanted[i].args;
        nodes[i].impl = impls[j];
        nodes[i].next = ev;
        ev = &nodes[i];
      }
  return ev;
}

const ren_ev *ren_given(ren_ev *nodes, const ren_ev *outer, const ren_ev *from,
                        const ren_key *deps, int n) {
  const ren_ev *ev = outer;
  for (int i = 0; i < n; i++) {
    nodes[i].dep = deps[i].dep;
    nodes[i].nargs = deps[i].nargs;
    nodes[i].args = deps[i].args;
    nodes[i].impl =
        deps[i].nargs == 0
            ? ren_find(from, deps[i].dep)
            : ren_find_args(from, deps[i].dep, deps[i].args, deps[i].nargs);
    nodes[i].next = ev;
    ev = &nodes[i];
  }
  return ev;
}

/* ---- the world ---- */

void ren_console_write(ren_obj *line) {
  fwrite(ren_str_data(line), 1, (size_t)ren_str_len(line), stdout);
  fputc('\n', stdout);
}

void ren_console_error(ren_obj *line) {
  fflush(stdout);
  fwrite(ren_str_data(line), 1, (size_t)ren_str_len(line), stderr);
  fputc('\n', stderr);
}

/* ---- running ---- */

/* The program's stack: 1 GiB, as the Rust twins' (bench/native/README.md,
   "Deep recursion"), which the system only maps as it's used. A frame
   that starts in the last [REN_STACK_MARGIN] bytes panics, which leaves
   room to print the panic. */
#define REN_STACK_SIZE ((size_t)1 << 30)
#define REN_STACK_MARGIN ((size_t)1 << 20)

static void (*ren_entry)(void);

static void *ren_thread(void *unused) {
  char top;
  (void)unused;
  ren_stack_limit =
      (char *)((uintptr_t)&top - REN_STACK_SIZE + REN_STACK_MARGIN);
  ren_entry();
  return NULL;
}

#ifdef REN_STATS
static void ren_print_stats(void) {
  fprintf(stderr,
          "ren stats: allocations %" PRId64 ", frees %" PRId64 ", dups %" PRId64
          ", drops %" PRId64 ", reuses %" PRId64 ", grows %" PRId64
          ", peak live bytes %" PRId64 ", block calls %" PRId64
          ", objects live at exit %" PRId64 "\n",
          ren_stats.allocs, ren_stats.frees, ren_stats.dups, ren_stats.drops,
          ren_stats.reuses, ren_stats.grows, ren_stats.peak_bytes,
          ren_stats.block_calls,
          ren_stats.allocs - ren_stats.frees);
}
#endif

int ren_run(void (*program)(void)) {
#ifdef REN_STATS
  atexit(ren_print_stats);
#endif
  pthread_attr_t attr;
  pthread_t thread;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, REN_STACK_SIZE);
  ren_entry = program;
  ren_map_seed_init();
  if (pthread_create(&thread, &attr, ren_thread, NULL) != 0) {
    fputs("error: couldn't start the program's thread\n", stderr);
    return 1;
  }
  pthread_join(thread, NULL);
  fflush(stdout);
  ren_append_report();
  return 0;
}
