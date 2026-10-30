/* Templates, Track A perf prototype: what Ren's release build would emit
   for three workloads under several lowerings. Built against Ren's real
   runtime (ren_rt.h / ren_rt.c, included whole, as `ren build` does), at
   Ren's release flags: cc -O2 -ffp-contract=off.

     interp <variant> [n]

   Variants (see perf.md):
     log-today      today's Str: holes through show, concat chain, then out += s
     log-today-snp  the same with ren_show_int (snprintf), exactly as emitted
     log-boxed      candidate A: the hole tuple boxed (one object), consumer walks it
     log-passed     candidate C: site pointer + pointer to holes in the frame,
                    consumer specialized per H, writes straight into `out`
     log-passed-site  candidate C specialized per site: the site a constant
     log-walk       candidate C, not specialized: consumer loops over the
                    site's pieces and switches on each hole's kind (debug-like)
     log-handler    C#-style: handler(literal_len, n) then AppendLiteral /
                    AppendFormatted calls into the consumer's buffer
     sql-today      no templates: constant text with $n, params an Array
     sql-inline     today's interpolation into SQL text (unsafe; cost only)
     sql-handler    text built per call ($n appended), params into a reused array
     sql-boxed      candidate A: holes boxed, text from the build-time plan
     sql-plan       candidate C + signature let: text is the plan's constant,
                    params written into the consumer's reused array
     html-today     today's Str: each Str hole escaped into a new Str, concat
     html-boxed     candidate A + plan
     html-plan      candidate C + plan: chunks constant, holes escaped into `out`
     html-handler   C#-style handler calls, escaping in AppendFormatted
*/
#include "ren_rt.h"
#include "ren_rt.c"

#define NOINLINE __attribute__((noinline))

static int64_t n_ops = 10000000;
static const char *variant;
static int64_t buf_grows;

/* ---- the consumer's buffer: what `&Str` with a capacity is ---- */
typedef struct {
  char *d;
  int64_t len, cap;
} buf;

static NOINLINE void buf_grow(buf *b, int64_t need) {
  int64_t c = b->cap ? b->cap : 64;
  while (c < need) c *= 2;
  b->d = realloc(b->d, (size_t)c);
  b->cap = c;
  buf_grows++;
}
static inline void buf_reserve(buf *b, int64_t extra) {
  if (__builtin_expect(b->len + extra > b->cap, 0)) buf_grow(b, b->len + extra);
}
static inline void buf_put(buf *b, const char *s, int64_t n) {
  buf_reserve(b, n);
  memcpy(b->d + b->len, s, (size_t)n);
  b->len += n;
}
/* without the check: the caller reserved */
static inline void buf_put_r(buf *b, const char *s, int64_t n) {
  memcpy(b->d + b->len, s, (size_t)n);
  b->len += n;
}

/* ---- Int to decimal, the digit-pair table (what Rust's itoa does) ---- */
static const char digits2[201] =
    "00010203040506070809101112131415161718192021222324252627282930313233343536373839"
    "40414243444546474849505152535455565758596061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899";
static inline int fmt_i64(char *out, int64_t v) { /* out has 20 bytes */
  char tmp[24];
  char *p = tmp + 24;
  uint64_t u = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
  while (u >= 100) {
    unsigned r = (unsigned)(u % 100);
    u /= 100;
    p -= 2;
    memcpy(p, digits2 + 2 * r, 2);
  }
  if (u >= 10) {
    p -= 2;
    memcpy(p, digits2 + 2 * u, 2);
  } else
    *--p = (char)('0' + u);
  if (v < 0) *--p = '-';
  int n = (int)(tmp + 24 - p);
  memcpy(out, p, (size_t)n);
  return n;
}
static inline void buf_int(buf *b, int64_t v) {
  buf_reserve(b, 20);
  b->len += fmt_i64(b->d + b->len, v);
}
/* `show` of an Int with the same digits, as a new Str (what a faster
   ren_show_int would be) */
static ren_obj *show_int_fast(int64_t v) {
  char t[24];
  int n = fmt_i64(t, v);
  return ren_str_of(t, n);
}

/* ---- HTML escaping: runs copied, five bytes replaced ---- */
static const uint8_t esc_tab[256] = {['&'] = 1, ['<'] = 2, ['>'] = 3, ['"'] = 4, ['\''] = 5};
static const char *esc_rep[6] = {0, "&amp;", "&lt;", "&gt;", "&quot;", "&#39;"};
static const uint8_t esc_len[6] = {0, 5, 4, 4, 6, 5};
static inline void buf_esc(buf *b, const char *s, int64_t n) {
  buf_reserve(b, n);
  int64_t from = 0;
  for (int64_t i = 0; i < n; i++) {
    uint8_t k = esc_tab[(uint8_t)s[i]];
    if (__builtin_expect(k != 0, 0)) {
      buf_put(b, s + from, i - from);
      buf_put(b, esc_rep[k], esc_len[k]);
      from = i + 1;
    }
  }
  buf_put(b, s + from, n - from);
}
/* today's html.escape: a new Str */
static ren_obj *escape_str(ren_obj *s) {
  buf t = {0};
  char stack[256];
  t.d = stack;
  t.cap = sizeof stack; /* never grows here: inputs are short */
  buf_esc(&t, ren_str_data(s), ren_str_len(s));
  return ren_str_of(t.d, t.len);
}

/* ---- constant strings, as the compiler emits literals ---- */
#define LIT(name, s)                                                                    \
  static struct {                                                                       \
    ren_obj h;                                                                          \
    int64_t len;                                                                        \
    const char *data;                                                                   \
    ren_obj *root;                                                                      \
    char bytes[sizeof(s)];                                                              \
  } name = {{0, REN_TAG_STR, 0, 0}, sizeof(s) - 1, name.bytes, 0, s}
#define O(x) ((ren_obj *)&(x))

LIT(l_info, "info");
LIT(l_warn, "warn");
LIT(l_path, "/api/jobs");
LIT(l_p0, "level=");
LIT(l_p1, " path=");
LIT(l_p2, " status=");
LIT(l_p3, " ms=");
LIT(l_p4, "\n");

/* ---- templates: the site is a constant, built while building ---- */
typedef struct {
  const char *s;
  int64_t n;
} part;
enum { K_STR, K_INT };
typedef struct {
  int64_t id;
  int nparts;
  const part *parts;   /* nparts = nholes + 1 */
  const uint8_t *kinds; /* the hole's static type, as the shape */
  int64_t literal_len;
} site;
/* candidate C: site pointer + pointer to the holes in the caller's frame */
typedef struct {
  const site *site;
  const void *holes;
} templ;

/* ===================== workload 1: a log line, 4 fields ===================== */

static const part log_parts[5] = {{"level=", 6}, {" path=", 6}, {" status=", 8}, {" ms=", 4}, {"\n", 1}};
static const uint8_t log_kinds[4] = {K_STR, K_STR, K_INT, K_INT};
static const site log_site = {1, 5, log_parts, log_kinds, 25};
typedef struct {
  ren_obj *level, *path;
  int64_t status, ms;
} log_H; /* H = (Str, Str, Int, Int) */

#define FLUSH(out, total)                                                               \
  if (out.len > 4096) {                                                                 \
    total += out.len + (uint8_t)out.d[out.len - 2] + check_hash(out.d, out.len);        \
    out.len = 0;                                                                        \
  }
#ifdef CHECK /* every byte, to check the variants write the same text */
static int64_t check_hash(const char *d, int64_t n) {
  uint64_t h = 1469598103934665603ull;
  for (int64_t i = 0; i < n; i++) h = (h ^ (uint8_t)d[i]) * 1099511628211ull;
  return (int64_t)(h >> 1);
}
#else
#define check_hash(d, n) 0
#endif

/* today, as emitted for "level=\{level} ..." (show of a Str is itself) */
static NOINLINE ren_obj *log_line_today(ren_obj *level, ren_obj *path, int64_t status,
                                        int64_t ms, ren_obj *(*show_int)(int64_t)) {
  ren_obj *v7 = ren_str_concat(O(l_p0), level);
  ren_obj *v8 = ren_str_concat(v7, O(l_p1));
  ren_drop(v7);
  ren_obj *v10 = ren_str_concat(v8, path);
  ren_drop(v8);
  ren_obj *v11 = ren_str_concat(v10, O(l_p2));
  ren_drop(v10);
  ren_obj *v13 = show_int(status);
  ren_obj *v14 = ren_str_concat(v11, v13);
  ren_drop(v11);
  ren_drop(v13);
  ren_obj *v15 = ren_str_concat(v14, O(l_p3));
  ren_drop(v14);
  ren_obj *v17 = show_int(ms);
  ren_obj *v18 = ren_str_concat(v15, v17);
  ren_drop(v15);
  ren_drop(v17);
  ren_obj *v19 = ren_str_concat(v18, O(l_p4));
  ren_drop(v18);
  return v19;
}

/* candidate C, the consumer `log.write<H>(out: &Str, t: Template<H>)`
   specialized for H = (Str, Str, Int, Int): pieces() unrolled */
static inline __attribute__((always_inline)) void log_write_body(buf *out, templ t) {
  const site *st = t.site;
  const log_H *h = t.holes;
  buf_reserve(out, st->literal_len + ren_str_len(h->level) + ren_str_len(h->path) + 40);
  buf_put_r(out, st->parts[0].s, st->parts[0].n);
  buf_put_r(out, ren_str_data(h->level), ren_str_len(h->level));
  buf_put_r(out, st->parts[1].s, st->parts[1].n);
  buf_put_r(out, ren_str_data(h->path), ren_str_len(h->path));
  buf_put_r(out, st->parts[2].s, st->parts[2].n);
  out->len += fmt_i64(out->d + out->len, h->status);
  buf_put_r(out, st->parts[3].s, st->parts[3].n);
  out->len += fmt_i64(out->d + out->len, h->ms);
  buf_put_r(out, st->parts[4].s, st->parts[4].n);
}

/* specialized per H only: the site is a run-time pointer, so each
   literal part is a load and a memcpy call */
static NOINLINE void log_write_passed(buf *out, templ t) { log_write_body(out, t); }
/* specialized per site too (what inlining the consumer at the literal
   gives): the site is a constant, so each part's length and bytes fold */
static NOINLINE void log_write_passed_site(buf *out, const log_H *h) {
  log_write_body(out, (templ){&log_site, h});
}

/* candidate C, not specialized: walk the site, switch on each hole's kind;
   holes as an array of words, as a dictionary-driven walk sees them */
static NOINLINE void log_write_walk(buf *out, const site *st, const ren_val *holes) {
  buf_reserve(out, st->literal_len);
  for (int i = 0; i < st->nparts; i++) {
    buf_put(out, st->parts[i].s, st->parts[i].n);
    if (i + 1 == st->nparts) break;
    switch (st->kinds[i]) {
    case K_STR:
      buf_put(out, ren_str_data(holes[i].o), ren_str_len(holes[i].o));
      break;
    case K_INT:
      buf_int(out, holes[i].i);
      break;
    }
  }
}

/* candidate A: the template is a value; its holes don't fit in two words,
   so they're boxed: one counted object of four fields, two of them counted */
static NOINLINE ren_obj *log_template_boxed(ren_obj *level, ren_obj *path, int64_t status,
                                            int64_t ms) {
  ren_obj *o = ren_alloc_ctor(0, 4, 0x3);
  ren_dup(level);
  ren_dup(path);
  ren_fields(o)[0].o = level;
  ren_fields(o)[1].o = path;
  ren_fields(o)[2].i = status;
  ren_fields(o)[3].i = ms;
  return o;
}
static NOINLINE void log_write_boxed(buf *out, const site *st, ren_obj *box) {
  ren_val *f = ren_fields(box);
  buf_reserve(out, st->literal_len + ren_str_len(f[0].o) + ren_str_len(f[1].o) + 40);
  buf_put_r(out, st->parts[0].s, st->parts[0].n);
  buf_put_r(out, ren_str_data(f[0].o), ren_str_len(f[0].o));
  buf_put_r(out, st->parts[1].s, st->parts[1].n);
  buf_put_r(out, ren_str_data(f[1].o), ren_str_len(f[1].o));
  buf_put_r(out, st->parts[2].s, st->parts[2].n);
  out->len += fmt_i64(out->d + out->len, f[2].i);
  buf_put_r(out, st->parts[3].s, st->parts[3].n);
  out->len += fmt_i64(out->d + out->len, f[3].i);
  buf_put_r(out, st->parts[4].s, st->parts[4].n);
}

/* C#'s handler: constructed with literal length and hole count, then one
   call per part, literals as immediates, AppendFormatted generic per type */
typedef struct {
  buf *out;
} handler;
static inline handler h_new(buf *out, int64_t literal_len, int nholes) {
  buf_reserve(out, literal_len + nholes * 16);
  return (handler){out};
}
static inline void h_lit(handler *h, const char *s, int64_t n) { buf_put(h->out, s, n); }
static inline void h_str(handler *h, ren_obj *s) { buf_put(h->out, ren_str_data(s), ren_str_len(s)); }
static inline void h_int(handler *h, int64_t v) { buf_int(h->out, v); }
static NOINLINE void log_write_handler(buf *out, ren_obj *level, ren_obj *path, int64_t status,
                                       int64_t ms) {
  handler h = h_new(out, 25, 4);
  h_lit(&h, "level=", 6);
  h_str(&h, level);
  h_lit(&h, " path=", 6);
  h_str(&h, path);
  h_lit(&h, " status=", 8);
  h_int(&h, status);
  h_lit(&h, " ms=", 4);
  h_int(&h, ms);
  h_lit(&h, "\n", 1);
}

static void run_log(void) {
  ren_obj *levels[2] = {O(l_info), O(l_warn)};
  ren_obj *path = O(l_path);
  buf out = {0};
  buf_grow(&out, 8192);
  int64_t total = 0;
  int mode = !strcmp(variant, "log-today")       ? 0
             : !strcmp(variant, "log-today-snp") ? 1
             : !strcmp(variant, "log-boxed")     ? 2
             : !strcmp(variant, "log-passed")    ? 3
             : !strcmp(variant, "log-walk")      ? 4
             : !strcmp(variant, "log-handler")   ? 5
             : !strcmp(variant, "log-passed-site") ? 6
                                                 : -1;
  for (int64_t i = 0; i < n_ops; i++) {
    ren_obj *level = levels[i & 1];
    int64_t status = 200 + i % 7, ms = i % 1000;
    switch (mode) {
    case 0:
    case 1: {
      ren_obj *s = log_line_today(level, path, status, ms, mode == 0 ? show_int_fast : ren_show_int);
      buf_put(&out, ren_str_data(s), ren_str_len(s)); /* out += s, in place */
      ren_drop(s);
      break;
    }
    case 2: {
      ren_obj *t = log_template_boxed(level, path, status, ms);
      log_write_boxed(&out, &log_site, t);
      ren_drop(t);
      break;
    }
    case 3: {
      log_H h = {level, path, status, ms}; /* temporaries in the frame */
      log_write_passed(&out, (templ){&log_site, &h});
      break;
    }
    case 4: {
      ren_val h[4] = {{.o = level}, {.o = path}, {.i = status}, {.i = ms}};
      log_write_walk(&out, &log_site, h);
      break;
    }
    case 5:
      log_write_handler(&out, level, path, status, ms);
      break;
    case 6: {
      log_H h = {level, path, status, ms};
      log_write_passed_site(&out, &h);
      break;
    }
    default:
      fprintf(stderr, "unknown variant %s\n", variant);
      exit(2);
    }
    FLUSH(out, total);
  }
  printf("%lld\n", (long long)(total + out.len));
}

/* ============ workload 2: SQL, rendered to (text with $n, params) ============
   t"select id, name, state from jobs where owner = \{owner} and state = \{state}
     and created_at > \{since} order by id limit \{n}"                          */

LIT(q_text, "select id, name, state from jobs where owner = $1 and state = $2 and "
            "created_at > $3 order by id limit $4");
LIT(s_queued, "queued");
LIT(s_running, "running");
LIT(qp0, "select id, name, state from jobs where owner = ");
LIT(qp1, " and state = ");
LIT(qp2, " and created_at > ");
LIT(qp3, " order by id limit ");
static const part sql_parts[5] = {{"select id, name, state from jobs where owner = ", 47},
                                  {" and state = ", 13},
                                  {" and created_at > ", 18},
                                  {" order by id limit ", 19},
                                  {"", 0}};
static const uint8_t sql_kinds[4] = {K_INT, K_STR, K_INT, K_INT};
static const site sql_site = {2, 5, sql_parts, sql_kinds, 97};
/* the plan sql.plan made while building: text and bind order */
typedef struct {
  const char *text;
  int64_t text_len;
  int nparams;
} sql_plan;
static const sql_plan q_plan = {"select id, name, state from jobs where owner = $1 and state = $2 and "
                                "created_at > $3 order by id limit $4",
                                sizeof("select id, name, state from jobs where owner = $1 and state = "
                                       "$2 and created_at > $3 order by id limit $4") -
                                    1,
                                4};
/* a param, as the consumer's own data: a tag and a word */
typedef struct {
  int64_t tag; /* 0 Int, 1 Str */
  ren_val v;
} param;
typedef struct {
  const char *text;
  int64_t text_len;
  param *params;
  int nparams;
} query; /* what the driver gets: text, params */

static int64_t consume(query q) { /* what a driver reads: stands for the send */
  int64_t x = q.text_len + q.text[q.text_len - 1];
  for (int i = 0; i < q.nparams; i++)
    x += q.params[i].tag ? ren_str_len(q.params[i].v.o) : q.params[i].v.i;
  return x;
}

/* today: the programmer writes the text with $n, and the params as an
   Array of a sum type, `[P.Int(owner), P.Str(state), ...]`: one array */
static NOINLINE int64_t sql_today(int64_t owner, ren_obj *state, int64_t since, int64_t n) {
  /* as Ren emits `[PInt(owner), PStr(state), ...]` today: stride 3 (tag,
     Int slot, counted slot), one array object plus its data */
  ren_obj *a = ren_alloc_array_n(4, 3, 4);
  ren_val *e = ren_elems(a);
  ren_dup(state);
  e[0].i = 0, e[1].i = owner, e[2].o = ren_box(0);
  e[3].i = 1, e[4].i = 0, e[5].o = state;
  e[6].i = 0, e[7].i = since, e[8].o = ren_box(0);
  e[9].i = 0, e[10].i = n, e[11].o = ren_box(0);
  const char *text = ren_str_data(O(q_text));
  int64_t len = ren_str_len(O(q_text));
  int64_t x = len + text[len - 1];
  for (int i = 0; i < 4; i++)
    x += e[3 * i].i ? ren_str_len(e[3 * i + 2].o) : e[3 * i + 1].i;
  ren_drop(a);
  return x;
}
/* today's interpolation into SQL text: the injection-prone thing, for cost */
static NOINLINE int64_t sql_inline(int64_t owner, ren_obj *state, int64_t since, int64_t n) {
  ren_obj *s0 = show_int_fast(owner);
  ren_obj *a = ren_str_concat(O(qp0), s0);
  ren_drop(s0);
  ren_obj *b = ren_str_concat(a, O(qp1));
  ren_drop(a);
  ren_obj *c = ren_str_concat(b, state);
  ren_drop(b);
  ren_obj *d = ren_str_concat(c, O(qp2));
  ren_drop(c);
  ren_obj *s2 = show_int_fast(since);
  ren_obj *e = ren_str_concat(d, s2);
  ren_drop(d);
  ren_drop(s2);
  ren_obj *f = ren_str_concat(e, O(qp3));
  ren_drop(e);
  ren_obj *s3 = show_int_fast(n);
  ren_obj *g = ren_str_concat(f, s3);
  ren_drop(f);
  ren_drop(s3);
  query q = {ren_str_data(g), ren_str_len(g), NULL, 0};
  int64_t x = consume(q);
  ren_drop(g);
  return x;
}
/* C#-handler style without a build-time plan: AppendLiteral copies the
   text, AppendFormatted appends "$k" and pushes the param; both buffers
   the consumer's, reused */
static NOINLINE int64_t sql_handler(buf *text, param *ps, int64_t owner, ren_obj *state,
                                    int64_t since, int64_t n) {
  text->len = 0;
  int k = 0;
#define HOLE(tg, field, val)                                                            \
  do {                                                                                  \
    char ph[4] = {'$', (char)('1' + k)};                                                \
    buf_put(text, ph, 2);                                                               \
    ps[k].tag = tg;                                                                     \
    ps[k].v.field = val;                                                                \
    k++;                                                                                \
  } while (0)
  buf_reserve(text, sql_site.literal_len + 8);
  buf_put(text, sql_site.parts[0].s, sql_site.parts[0].n);
  HOLE(0, i, owner);
  buf_put(text, sql_site.parts[1].s, sql_site.parts[1].n);
  HOLE(1, o, state);
  buf_put(text, sql_site.parts[2].s, sql_site.parts[2].n);
  HOLE(0, i, since);
  buf_put(text, sql_site.parts[3].s, sql_site.parts[3].n);
  HOLE(0, i, n);
#undef HOLE
  query q = {text->d, text->len, ps, k};
  return consume(q);
}
/* candidate C with a signature let: `DB.rows(t"...")`; the plan is a
   constant, the holes are read from the caller's frame into the
   consumer's reused params (borrowed: the template can't outlive them) */
typedef struct {
  int64_t owner;
  ren_obj *state;
  int64_t since, n;
} sql_H;
static NOINLINE int64_t sql_plan_c(param *ps, const sql_plan *plan, templ t) {
  const sql_H *h = t.holes;
  ps[0] = (param){0, {.i = h->owner}};
  ps[1] = (param){1, {.o = h->state}};
  ps[2] = (param){0, {.i = h->since}};
  ps[3] = (param){0, {.i = h->n}};
  query q = {plan->text, plan->text_len, ps, plan->nparams};
  return consume(q);
}
/* candidate A: the holes boxed, then the same plan */
static NOINLINE int64_t sql_boxed(param *ps, const sql_plan *plan, ren_obj *box) {
  ren_val *f = ren_fields(box);
  ps[0] = (param){0, {.i = f[0].i}};
  ps[1] = (param){1, {.o = f[1].o}};
  ps[2] = (param){0, {.i = f[2].i}};
  ps[3] = (param){0, {.i = f[3].i}};
  query q = {plan->text, plan->text_len, ps, plan->nparams};
  return consume(q);
}

static void run_sql(void) {
  ren_obj *states[2] = {O(s_queued), O(s_running)};
  buf text = {0};
  buf_grow(&text, 256);
  param ps[8];
  int64_t total = 0;
  int mode = !strcmp(variant, "sql-today")     ? 0
             : !strcmp(variant, "sql-inline")  ? 1
             : !strcmp(variant, "sql-handler") ? 2
             : !strcmp(variant, "sql-boxed")   ? 3
             : !strcmp(variant, "sql-plan")    ? 4
                                               : -1;
  for (int64_t i = 0; i < n_ops; i++) {
    int64_t owner = i % 977, since = 1700000000 + i, n = 50 + (i & 15);
    ren_obj *state = states[i & 1];
    switch (mode) {
    case 0: total += sql_today(owner, state, since, n); break;
    case 1: total += sql_inline(owner, state, since, n); break;
    case 2: total += sql_handler(&text, ps, owner, state, since, n); break;
    case 3: {
      ren_obj *o = ren_alloc_ctor(0, 4, 0x2);
      ren_dup(state);
      ren_fields(o)[0].i = owner;
      ren_fields(o)[1].o = state;
      ren_fields(o)[2].i = since;
      ren_fields(o)[3].i = n;
      total += sql_boxed(ps, &q_plan, o);
      ren_drop(o);
      break;
    }
    case 4: {
      sql_H h = {owner, state, since, n};
      total += sql_plan_c(ps, &q_plan, (templ){&sql_site, &h});
      break;
    }
    default:
      fprintf(stderr, "unknown variant %s\n", variant);
      exit(2);
    }
  }
  printf("%lld\n", (long long)total);
}

/* ============ workload 3: HTML, 5 escaped holes ============
   t"<li class=\"\{cls}\"><a href=\"/u/\{id}\">\{name}</a><span title=\"\{title}\">\{bio}</span></li>\n" */

LIT(h_c0, "row");
LIT(h_c1, "row odd");
LIT(h_n0, "Ada Lovelace");
LIT(h_n1, "Tom & Jerry");
LIT(h_n2, "<script>x</script>");
LIT(h_n3, "Grace Hopper");
LIT(h_t0, "Engineer");
LIT(h_t1, "\"Lead\" dev");
LIT(h_b0, "Writes compilers and likes plain C.");
LIT(h_b1, "Ships fast, tests later; 5 > 3.");
LIT(hp0, "<li class=\"");
LIT(hp1, "\"><a href=\"/u/");
LIT(hp2, "\">");
LIT(hp3, "</a><span title=\"");
LIT(hp4, "\">");
LIT(hp5, "</span></li>\n");
/* html.plan's output: static chunks, and each hole's context */
static const part html_chunks[6] = {{"<li class=\"", 11}, {"\"><a href=\"/u/", 14}, {"\">", 2},
                                    {"</a><span title=\"", 17}, {"\">", 2}, {"</span></li>\n", 13}};
static const int64_t html_literal_len = 59;
typedef struct {
  ren_obj *cls;
  int64_t id;
  ren_obj *name, *title, *bio;
} html_H;

static NOINLINE ren_obj *html_today(ren_obj *cls, int64_t id, ren_obj *name, ren_obj *title,
                                    ren_obj *bio) {
  /* "<li class=\"\{html.escape(cls)}\">...": an escape is a new Str */
  ren_obj *e0 = escape_str(cls);
  ren_obj *a = ren_str_concat(O(hp0), e0);
  ren_drop(e0);
  ren_obj *b = ren_str_concat(a, O(hp1));
  ren_drop(a);
  ren_obj *s1 = show_int_fast(id);
  ren_obj *c = ren_str_concat(b, s1);
  ren_drop(b);
  ren_drop(s1);
  ren_obj *d = ren_str_concat(c, O(hp2));
  ren_drop(c);
  ren_obj *e2 = escape_str(name);
  ren_obj *e = ren_str_concat(d, e2);
  ren_drop(d);
  ren_drop(e2);
  ren_obj *f = ren_str_concat(e, O(hp3));
  ren_drop(e);
  ren_obj *e3 = escape_str(title);
  ren_obj *g = ren_str_concat(f, e3);
  ren_drop(f);
  ren_drop(e3);
  ren_obj *h = ren_str_concat(g, O(hp4));
  ren_drop(g);
  ren_obj *e4 = escape_str(bio);
  ren_obj *k = ren_str_concat(h, e4);
  ren_drop(h);
  ren_drop(e4);
  ren_obj *l = ren_str_concat(k, O(hp5));
  ren_drop(k);
  return l;
}
static inline void html_body(buf *out, ren_obj *cls, int64_t id, ren_obj *name, ren_obj *title,
                             ren_obj *bio) {
  buf_reserve(out, html_literal_len + 64);
  buf_put_r(out, html_chunks[0].s, html_chunks[0].n);
  buf_esc(out, ren_str_data(cls), ren_str_len(cls)); /* attribute */
  buf_put(out, html_chunks[1].s, html_chunks[1].n);
  buf_int(out, id); /* an Int in a URL: digits need no escape, the plan knows */
  buf_put(out, html_chunks[2].s, html_chunks[2].n);
  buf_esc(out, ren_str_data(name), ren_str_len(name)); /* text */
  buf_put(out, html_chunks[3].s, html_chunks[3].n);
  buf_esc(out, ren_str_data(title), ren_str_len(title)); /* attribute */
  buf_put(out, html_chunks[4].s, html_chunks[4].n);
  buf_esc(out, ren_str_data(bio), ren_str_len(bio)); /* text */
  buf_put(out, html_chunks[5].s, html_chunks[5].n);
}
static NOINLINE void html_write_plan(buf *out, templ t) {
  const html_H *h = t.holes;
  html_body(out, h->cls, h->id, h->name, h->title, h->bio);
}
static NOINLINE void html_write_boxed(buf *out, ren_obj *box) {
  ren_val *f = ren_fields(box);
  html_body(out, f[0].o, f[1].i, f[2].o, f[3].o, f[4].o);
}
static NOINLINE void html_write_handler(buf *out, ren_obj *cls, int64_t id, ren_obj *name,
                                        ren_obj *title, ren_obj *bio) {
  handler h = h_new(out, html_literal_len, 5);
  h_lit(&h, "<li class=\"", 11);
  buf_esc(h.out, ren_str_data(cls), ren_str_len(cls));
  h_lit(&h, "\"><a href=\"/u/", 14);
  h_int(&h, id);
  h_lit(&h, "\">", 2);
  buf_esc(h.out, ren_str_data(name), ren_str_len(name));
  h_lit(&h, "</a><span title=\"", 17);
  buf_esc(h.out, ren_str_data(title), ren_str_len(title));
  h_lit(&h, "\">", 2);
  buf_esc(h.out, ren_str_data(bio), ren_str_len(bio));
  h_lit(&h, "</span></li>\n", 13);
}

static void run_html(void) {
  ren_obj *clss[2] = {O(h_c0), O(h_c1)};
  ren_obj *names[4] = {O(h_n0), O(h_n1), O(h_n2), O(h_n3)};
  ren_obj *titles[2] = {O(h_t0), O(h_t1)};
  ren_obj *bios[2] = {O(h_b0), O(h_b1)};
  buf out = {0};
  buf_grow(&out, 8192);
  int64_t total = 0;
  int mode = !strcmp(variant, "html-today")     ? 0
             : !strcmp(variant, "html-boxed")   ? 1
             : !strcmp(variant, "html-plan")    ? 2
             : !strcmp(variant, "html-handler") ? 3
                                                : -1;
  for (int64_t i = 0; i < n_ops; i++) {
    ren_obj *cls = clss[i & 1], *name = names[i & 3], *title = titles[(i >> 2) & 1],
            *bio = bios[(i >> 1) & 1];
    int64_t id = i % 100000;
    switch (mode) {
    case 0: {
      ren_obj *s = html_today(cls, id, name, title, bio);
      buf_put(&out, ren_str_data(s), ren_str_len(s));
      ren_drop(s);
      break;
    }
    case 1: {
      ren_obj *o = ren_alloc_ctor(0, 5, 0x1d);
      ren_dup(cls), ren_dup(name), ren_dup(title), ren_dup(bio);
      ren_val *f = ren_fields(o);
      f[0].o = cls, f[1].i = id, f[2].o = name, f[3].o = title, f[4].o = bio;
      html_write_boxed(&out, o);
      ren_drop(o);
      break;
    }
    case 2: {
      html_H h = {cls, id, name, title, bio};
      html_write_plan(&out, (templ){NULL, &h});
      break;
    }
    case 3:
      html_write_handler(&out, cls, id, name, title, bio);
      break;
    default:
      fprintf(stderr, "unknown variant %s\n", variant);
      exit(2);
    }
    FLUSH(out, total);
  }
  printf("%lld\n", (long long)(total + out.len));
}

static void program(void) {
  if (!strncmp(variant, "log", 3)) run_log();
  else if (!strncmp(variant, "sql", 3)) run_sql();
  else if (!strncmp(variant, "html", 4)) run_html();
  else {
    fprintf(stderr, "unknown variant %s\n", variant);
    exit(2);
  }
#ifdef REN_STATS
  fprintf(stderr, "buf_grows %lld\n", (long long)buf_grows);
#endif
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: interp <variant> [n]\n");
    return 2;
  }
  variant = argv[1];
  if (argc > 2) n_ops = atoll(argv[2]);
  return ren_run(program);
}
