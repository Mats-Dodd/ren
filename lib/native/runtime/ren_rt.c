/* The Ren runtime's functions (ren_rt.h says what each does). */

#ifdef REN_STATS
ren_stats_t ren_stats;
#endif

char *ren_stack_limit;
const ren_site *ren_overflow_site;

/* ---- panics ---- */

_Noreturn void ren_panic(const ren_site *site, const char *msg) {
  fflush(stdout);
  fputs(site->before, stderr);
  fputs(msg, stderr);
  fputs(site->after, stderr);
  exit(1);
}

_Noreturn void ren_stack_overflowed(void) {
  ren_panic(ren_overflow_site,
            "the stack overflowed: a function called itself too deeply");
}

/* ---- memory ---- */

#ifdef REN_STATS
static void ren_count_alloc(int64_t bytes) {
  ren_stats.allocs++;
  ren_stats.live_bytes += bytes;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
}
#endif

static void *ren_malloc(size_t bytes) {
  void *p = malloc(bytes);
  if (p == NULL) {
    fflush(stdout);
    fputs("error: out of memory\n", stderr);
    exit(1);
  }
  return p;
}

ren_obj *ren_alloc_ctor(uint16_t tag, uint32_t nfields, uint32_t nobjs) {
  size_t bytes = sizeof(ren_ctor) + nfields * sizeof(ren_val);
  ren_obj *o = ren_malloc(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  o->rc = 1;
  o->tag = tag;
  o->kind = REN_CTOR;
  o->boxed_elems = 0;
  o->nobjs = nobjs;
  o->nfields = nfields;
  return o;
}

ren_obj *ren_alloc_array(int64_t len, bool boxed_elems) {
  ren_array *a = ren_malloc(sizeof(ren_array));
  int64_t cap = len > 0 ? len : 1;
  a->data = ren_malloc((size_t)cap * sizeof(ren_val));
#ifdef REN_STATS
  ren_count_alloc((int64_t)(sizeof(ren_array) + (size_t)cap * sizeof(ren_val)));
#endif
  a->h.rc = 1;
  a->h.tag = 0;
  a->h.kind = REN_ARRAY;
  a->h.boxed_elems = boxed_elems;
  a->h.nobjs = 0;
  a->h.nfields = 0;
  a->len = len;
  a->cap = cap;
  return &a->h;
}

static ren_obj *ren_alloc_str(int64_t len) {
  size_t bytes = sizeof(ren_str) + (size_t)len + 1;
  ren_str *s = ren_malloc(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  s->h.rc = 1;
  s->h.tag = 0;
  s->h.kind = REN_STR;
  s->h.boxed_elems = 0;
  s->h.nobjs = 0;
  s->h.nfields = 0;
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
static ren_obj **ren_todo;
static size_t ren_todo_len, ren_todo_cap;

static void ren_todo_push(ren_obj *o) {
  if (ren_todo_len == ren_todo_cap) {
    ren_todo_cap = ren_todo_cap ? ren_todo_cap * 2 : 256;
    ren_todo = realloc(ren_todo, ren_todo_cap * sizeof(ren_obj *));
    if (ren_todo == NULL) {
      fflush(stdout);
      fputs("error: out of memory\n", stderr);
      exit(1);
    }
  }
  ren_todo[ren_todo_len++] = o;
}

/* One reference fewer on a child of an object being freed. */
static void ren_release(ren_obj *o) {
  if (ren_is_scalar(o) || o->rc == 0)
    return;
  REN_STAT(drops);
  if (o->rc > 1)
    o->rc--;
  else
    ren_todo_push(o);
}

/* Free one object whose count reached 0, its children going on the
   list. */
static void ren_free_one(ren_obj *o) {
  int64_t bytes = 0;
  switch (o->kind) {
  case REN_CTOR: {
    ren_val *fs = ren_fields(o);
    for (uint32_t i = 0; i < o->nobjs; i++)
      ren_release(fs[i].o);
    bytes = (int64_t)(sizeof(ren_ctor) + o->nfields * sizeof(ren_val));
    break;
  }
  case REN_ARRAY: {
    ren_array *a = (ren_array *)o;
    if (o->boxed_elems)
      for (int64_t i = 0; i < a->len; i++)
        ren_release(a->data[i].o);
    bytes = (int64_t)(sizeof(ren_array) + (size_t)a->cap * sizeof(ren_val));
    free(a->data);
    break;
  }
  case REN_STR:
    bytes = (int64_t)(sizeof(ren_str) + (size_t)((ren_str *)o)->len + 1);
    break;
  }
#ifdef REN_STATS
  ren_stats.frees++;
  ren_stats.live_bytes -= bytes;
#else
  (void)bytes;
#endif
  free(o);
}

void ren_free(ren_obj *o) {
  ren_free_one(o);
  while (ren_todo_len > 0)
    ren_free_one(ren_todo[--ren_todo_len]);
}

/* ---- arrays ---- */

int64_t ren_array_len(ren_obj *a) { return ((ren_array *)a)->len; }

static void ren_check_index(ren_obj *a, int64_t i, const ren_site *site) {
  int64_t len = ((ren_array *)a)->len;
  if (i < 0 || i >= len) {
    char msg[128];
    snprintf(msg, sizeof msg,
             "index %" PRId64 " is out of bounds for an array of length %" PRId64,
             i, len);
    ren_panic(site, msg);
  }
}

ren_val ren_array_get(ren_obj *a, int64_t i, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_val v = ((ren_array *)a)->data[i];
  if (a->boxed_elems)
    ren_dup(v.o);
  return v;
}

/* A copy of [a] with room for [extra] more, each element counted again. */
static ren_obj *ren_array_copy(ren_obj *a, int64_t extra) {
  ren_array *from = (ren_array *)a;
  ren_obj *b = ren_alloc_array(from->len + extra, a->boxed_elems);
  ren_val *to = ren_elems(b);
  for (int64_t i = 0; i < from->len; i++) {
    to[i] = from->data[i];
    if (a->boxed_elems)
      ren_dup(to[i].o);
  }
  return b;
}

ren_obj *ren_array_set(ren_obj *a, int64_t i, ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_val *to = ren_elems(b);
  if (a->boxed_elems) {
    ren_drop(to[i].o);
    ren_dup(v.o);
  }
  to[i] = v;
  return b;
}

void ren_array_push(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  if (a->boxed_elems)
    ren_dup(v.o);
  ren_elems(b)[((ren_array *)b)->len - 1] = v;
  ren_drop(a);
  *cell = b;
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
          ", drops %" PRId64 ", reuses %" PRId64 ", peak live bytes %" PRId64
          ", objects live at exit %" PRId64 "\n",
          ren_stats.allocs, ren_stats.frees, ren_stats.dups, ren_stats.drops,
          ren_stats.reuses, ren_stats.peak_bytes,
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
  if (pthread_create(&thread, &attr, ren_thread, NULL) != 0) {
    fputs("error: couldn't start the program's thread\n", stderr);
    return 1;
  }
  pthread_join(thread, NULL);
  fflush(stdout);
  return 0;
}
