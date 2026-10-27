/* The Ren runtime's functions (ren_rt.h says what each does). */

#ifdef REN_STATS
ren_stats_t ren_stats;
#endif

char *ren_stack_limit;
const ren_site *ren_overflow_site;

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
  fflush(stdout);
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

static ren_obj *ren_alloc_array_c(int64_t len, int64_t cap, bool boxed_elems,
                                  uint32_t stride) {
  ren_array *a = ren_alloc_bytes(sizeof(ren_array));
  cap = cap > len ? cap : len;
  cap = cap > 0 ? cap : 1;
  size_t bytes = (size_t)cap * (stride > 1 ? stride : 1) * sizeof(ren_val);
  a->data = ren_malloc(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)(sizeof(ren_array) + bytes));
#endif
  a->h.rc = 1;
  a->h.tag = REN_TAG_ARRAY;
  a->h.nfields = 0;
  a->h.objs = boxed_elems;
  a->len = len;
  a->cap = cap;
  a->stride = stride > 1 ? stride : 1;
  return &a->h;
}

static ren_obj *ren_alloc_array_s(int64_t len, bool boxed_elems,
                                  uint32_t stride) {
  return ren_alloc_array_c(len, len, boxed_elems, stride);
}

ren_obj *ren_array_reserve(int64_t cap, bool boxed_elems, uint32_t stride) {
  return ren_alloc_array_c(0, cap, boxed_elems, stride);
}

ren_obj *ren_alloc_array(int64_t len, bool boxed_elems) {
  return ren_alloc_array_s(len, boxed_elems, 0);
}

ren_obj *ren_alloc_array_n(int64_t len, uint32_t stride) {
  return ren_alloc_array_s(len, false, stride);
}

static ren_obj *ren_alloc_str(int64_t len) {
  size_t bytes = sizeof(ren_str) + (size_t)len + 1;
  ren_str *s = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_STR;
  s->h.nfields = 0;
  s->h.objs = 0;
  s->len = len;
  s->data[len] = 0;
  return &s->h;
}

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
    if (o->objs)
      for (int64_t i = 0; i < a->len; i++)
        ren_release(t, a->data[i].o);
    bytes = (int64_t)(sizeof(ren_array) +
                      (size_t)(a->cap * ren_stride(o)) * sizeof(ren_val));
    free(a->data);
    size = sizeof(ren_array);
    break;
  }
  case REN_TAG_STR:
    size = sizeof(ren_str) + (size_t)((ren_str *)o)->len + 1;
    bytes = (int64_t)size;
    break;
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
      n = x->objs ? (size_t)((ren_array *)x)->len : 0;
      break;
    case REN_TAG_DESC:
      n = ((ren_desc *)x)->nargs;
      break;
    case REN_TAG_STR:
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
      for (size_t i = 0; i < n; i++)
        todo[len++] = ((ren_array *)x)->data[i].o;
      break;
    case REN_TAG_DESC:
      for (size_t i = 0; i < n; i++)
        todo[len++] = &((ren_desc *)x)->args[i]->h;
      break;
    case REN_TAG_STR:
      break;
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
  ren_obj *b = ren_alloc_array_s(from->len + extra, a->objs, (uint32_t)from->stride);
  ren_val *to = ren_elems(b);
  int64_t words = from->len * ren_stride(a);
  for (int64_t i = 0; i < words; i++) {
    to[i] = from->data[i];
    if (a->objs)
      ren_dup(to[i].o);
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
   it's full. */
static void ren_array_grow(ren_array *arr) {
  if (arr->len < arr->cap)
    return;
  int64_t k = ren_stride(&arr->h);
  int64_t cap = arr->cap * 2;
  ren_val *data = realloc(arr->data, (size_t)(cap * k) * sizeof(ren_val));
  if (data == NULL) {
    fflush(stdout);
    fputs("error: out of memory\n", stderr);
    exit(1);
  }
#ifdef REN_STATS
  ren_stats.grows++;
  ren_stats.live_bytes += (cap - arr->cap) * k * (int64_t)sizeof(ren_val);
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
  arr->data = data;
  arr->cap = cap;
}

void ren_array_push_taking(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!ren_is_unique(a)) {
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

/* ---- arrays of structs ---- */

ren_obj *ren_array_set_slots(ren_obj *a, int64_t i, const ren_val *v,
                             const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  int64_t k = ren_stride(a);
  memcpy(&ren_elems(b)[i * k], v, (size_t)k * sizeof(ren_val));
  return b;
}

ren_obj *ren_array_set_field(ren_obj *a, int64_t i, int64_t off, int64_t k,
                             ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_elems(b)[i * k + off] = v;
  return b;
}

void ren_array_push_slots(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  int64_t k = ren_stride(a);
  memcpy(&ren_elems(b)[(((ren_array *)b)->len - 1) * k], v,
         (size_t)k * sizeof(ren_val));
  ren_drop(a);
  *cell = b;
}

void ren_array_push_slots_taking(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  int64_t k = ren_stride(a);
  if (!ren_is_unique(a)) {
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
  memcpy(((ren_str *)o)->data, s, (size_t)len);
  return o;
}

ren_obj *ren_str_concat(ren_obj *a, ren_obj *b) {
  int64_t la = ren_str_len(a), lb = ren_str_len(b);
  ren_obj *o = ren_alloc_str(la + lb);
  memcpy(((ren_str *)o)->data, ren_str_data(a), (size_t)la);
  memcpy(((ren_str *)o)->data + la, ren_str_data(b), (size_t)lb);
  return o;
}

bool ren_str_eq(ren_obj *a, ren_obj *b) {
  return ren_str_len(a) == ren_str_len(b) &&
         memcmp(ren_str_data(a), ren_str_data(b), (size_t)ren_str_len(a)) == 0;
}

ren_obj *ren_show_int(int64_t n) {
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%" PRId64, n);
  return ren_str_of(buf, len);
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

ren_obj *ren_show_float(double f) {
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

_Noreturn void ren_float_undefined(const ren_site *site, const char *op,
                                   double a, double b) {
  char x[400], y[400], msg[900];
  ren_format_float(x, a);
  ren_format_float(y, b);
  snprintf(msg, sizeof msg, "`%s` has no answer here: %s %s %s", op, x, op, y);
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

double ren_fsqrt(double a, const ren_site *site) {
  if (a < 0) {
    char x[400], msg[500];
    ren_format_float(x, a);
    snprintf(msg, sizeof msg, "`sqrt` of a negative number: %s", x);
    ren_panic(site, msg);
  }
  return sqrt(a);
}

/* [r], [f] rounded by [how], if it's an `Int`: builtins.ml's `to_int`. */
static int64_t ren_to_int(double r, double f, const char *how,
                          const ren_site *site) {
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

static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v);

/* Each of [n] fields of [o], of the types [types] read under [env], with
   [names] before them if there are any; where they are is [c]'s, if
   there's one. */
static void ren_show_fields(ren_buf *b, ren_obj *o, const ren_ctor_info *c,
                            int32_t n, const char *const *names,
                            ren_desc *const *types, const ren_tenv *env) {
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    if (names != NULL) {
      ren_puts(b, names[i]);
      ren_puts(b, ": ");
    }
    ren_show_val(b, types[i], env, ren_ctor_field(o, c, i));
  }
}

/* An error: its tag, and its payload, through the descriptors it keeps
   after it. */
static void ren_show_error(ren_buf *b, ren_obj *e) {
  ren_puts(b, ren_tag_names[ren_tag(e)]);
  if (ren_is_scalar(e))
    return;
  int32_t n = (int32_t)e->nfields / 2;
  ren_puts(b, "(");
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    ren_show_val(b, (ren_desc *)ren_fields(e)[n + i].o, NULL,
                 ren_fields(e)[i]);
  }
  ren_puts(b, ")");
}

/* [v] as it's written: shown.ml's `value`. */
static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v) {
  char num[400];
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_INT:
    snprintf(num, sizeof num, "%" PRId64, v.i);
    ren_puts(b, num);
    break;
  case REN_D_FLOAT:
    ren_format_float(num, v.f);
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
  case REN_D_ARRAY: {
    ren_array *a = (ren_array *)v.o;
    ren_puts(b, "[");
    for (int64_t i = 0; i < a->len; i++) {
      if (i > 0)
        ren_puts(b, ", ");
      ren_show_val(b, d->args[0], env, a->data[i]);
    }
    ren_puts(b, "]");
    break;
  }
  case REN_D_TUPLE:
    ren_puts(b, "(");
    ren_show_fields(b, v.o, NULL, d->nargs, NULL, d->args, env);
    ren_puts(b, ")");
    break;
  case REN_D_ERRORS:
    ren_show_error(b, v.o);
    break;
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->kind == REN_DECL_REP) {
      ren_puts(b, decl->name);
      ren_puts(b, "(");
      ren_show_val(b, decl->rep, &inner, v);
      ren_puts(b, ")");
    } else if (decl->kind == REN_DECL_RECORD) {
      const ren_ctor_info *c = &decl->ctors[0];
      ren_puts(b, decl->name);
      ren_puts(b, decl->opaque ? "(" : " { ");
      ren_show_fields(b, v.o, c, c->nfields, c->fields, c->types, &inner);
      ren_puts(b, decl->opaque ? ")" : " }");
    } else {
      const ren_ctor_info *c = &decl->ctors[ren_ctor_tag(decl, v)];
      ren_puts(b, c->name);
      if (c->nfields > 0) {
        ren_puts(b, "(");
        ren_show_fields(b, v.o, c, c->nfields, NULL, c->types, &inner);
        ren_puts(b, ")");
      }
    }
    break;
  }
  }
}

ren_obj *ren_show_any(ren_obj *d, ren_val v) {
  if (((ren_desc *)d)->kind == REN_D_STR) {
    ren_dup(v.o);
    return v.o;
  }
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v);
  ren_obj *s = ren_str_of(b.data, (int64_t)b.len);
  free(b.data);
  return s;
}

void ren_print_value(FILE *out, ren_obj *d, ren_val v) {
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v);
  fwrite(b.data, 1, b.len, out);
  free(b.data);
}

static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b);

static bool ren_equal_fields(ren_obj *a, ren_obj *b, const ren_ctor_info *c,
                             int32_t n, ren_desc *const *types,
                             const ren_tenv *env) {
  for (int32_t i = 0; i < n; i++)
    if (!ren_equal_in(types[i], env, ren_ctor_field(a, c, i),
                      ren_ctor_field(b, c, i)))
      return false;
  return true;
}

/* walk.ml's `equal`, part by part. */
static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    return a.f == b.f;
  case REN_D_STR:
    return ren_str_eq(a.o, b.o);
  case REN_D_ARRAY: {
    ren_array *x = (ren_array *)a.o, *y = (ren_array *)b.o;
    if (x->len != y->len)
      return false;
    for (int64_t i = 0; i < x->len; i++)
      if (!ren_equal_in(d->args[0], env, x->data[i], y->data[i]))
        return false;
    return true;
  }
  case REN_D_TUPLE:
    return ren_equal_fields(a.o, b.o, NULL, d->nargs, d->args, env);
  case REN_D_ERRORS: {
    if (ren_tag(a.o) != ren_tag(b.o))
      return false;
    if (ren_is_scalar(a.o))
      return true;
    int32_t n = (int32_t)a.o->nfields / 2;
    for (int32_t i = 0; i < n; i++)
      if (!ren_equal_in((ren_desc *)ren_fields(a.o)[n + i].o, NULL,
                        ren_fields(a.o)[i], ren_fields(b.o)[i]))
        return false;
    return true;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->kind == REN_DECL_REP)
      return ren_equal_in(decl->rep, &inner, a, b);
    if (decl->kind == REN_DECL_RECORD)
      return ren_equal_fields(a.o, b.o, &decl->ctors[0],
                              decl->ctors[0].nfields, decl->ctors[0].types,
                              &inner);
    int64_t tag = ren_ctor_tag(decl, a);
    if (tag != ren_ctor_tag(decl, b))
      return false;
    const ren_ctor_info *c = &decl->ctors[tag];
    return c->nfields == 0 ||
           ren_equal_fields(a.o, b.o, c, c->nfields, c->types, &inner);
  }
  default: /* an `Int`, a `Bool` or `Unit` */
    return a.i == b.i;
  }
}

bool ren_equal_any(ren_obj *d, ren_val a, ren_val b) {
  return ren_equal_in((ren_desc *)d, NULL, a, b);
}

#define REN_CMP(x, y) ((x) < (y) ? -1 : (x) > (y) ? 1 : 0)

/* walk.ml's `compare`: what inference allows an order on. */
static int64_t ren_compare_in(const ren_desc *d, const ren_tenv *env,
                              ren_val a, ren_val b) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    return REN_CMP(a.f, b.f);
  case REN_D_STR: {
    int64_t la = ren_str_len(a.o), lb = ren_str_len(b.o);
    int c = memcmp(ren_str_data(a.o), ren_str_data(b.o),
                   (size_t)(la < lb ? la : lb));
    return c != 0 ? c : REN_CMP(la, lb);
  }
  case REN_D_TUPLE:
    for (uint16_t i = 0; i < d->nargs; i++) {
      int64_t c = ren_compare_in(d->args[i], env, ren_fields(a.o)[i],
                                 ren_fields(b.o)[i]);
      if (c != 0)
        return c;
    }
    return 0;
  case REN_D_NAMED: {
    ren_tenv inner = {d->args, env};
    if (d->decl->kind == REN_DECL_REP)
      return ren_compare_in(d->decl->rep, &inner, a, b);
    return REN_CMP(ren_ctor_tag(d->decl, a), ren_ctor_tag(d->decl, b));
  }
  default: /* an `Int` or a `Bool` */
    return REN_CMP(a.i, b.i);
  }
}

int64_t ren_compare_any(ren_obj *d, ren_val a, ren_val b) {
  return ren_compare_in((ren_desc *)d, NULL, a, b);
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
                   const ren_site *site) {
  ren_val r;
  if (ren_is_float((ren_desc *)d, NULL)) {
    switch (op) {
    case REN_OP_ADD:
      r.f = ren_fadd(a.f, b.f, site);
      break;
    case REN_OP_SUB:
      r.f = ren_fsub(a.f, b.f, site);
      break;
    case REN_OP_MUL:
      r.f = ren_fmul(a.f, b.f, site);
      break;
    case REN_OP_DIV:
      r.f = ren_fdiv(a.f, b.f, site);
      break;
    case REN_OP_REM:
      r.f = ren_frem(a.f, b.f, site);
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
  ren_print_value(stderr, &ren_errors_desc.h, (ren_val){.o = e});
  fputc('\n', stderr);
  exit(1);
}

/* ---- evidence ---- */

const ren_ev *ren_install(ren_ev *nodes, const ren_ev *outer, void *deps,
                          int64_t ndeps, const ren_impl *const *impls,
                          int nimpls) {
  const int32_t *wanted = deps;
  const ren_ev *ev = outer;
  for (int64_t i = 0; i < ndeps; i++)
    for (int j = 0; j < nimpls; j++)
      if (impls[j]->dep == wanted[i]) {
        nodes[i].dep = wanted[i];
        nodes[i].impl = impls[j];
        nodes[i].next = ev;
        ev = &nodes[i];
      }
  return ev;
}

const ren_ev *ren_given(ren_ev *nodes, const ren_ev *outer, const ren_ev *from,
                        const int32_t *deps, int n) {
  const ren_ev *ev = outer;
  for (int i = 0; i < n; i++) {
    nodes[i].dep = deps[i];
    nodes[i].impl = ren_find(from, deps[i]);
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
  if (ren_stats.stack_allocs > 0)
    fprintf(stderr, "ren stats: objects kept in a frame %" PRId64 "\n",
            ren_stats.stack_allocs);
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
  if (pthread_create(&thread, &attr, ren_thread, NULL) != 0) {
    fputs("error: couldn't start the program's thread\n", stderr);
    return 1;
  }
  pthread_join(thread, NULL);
  fflush(stdout);
  return 0;
}
