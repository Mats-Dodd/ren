/* B3: building output. `b3 <json|logs|http> <datadir> <variant> [out]`,
   variant one of
     concat   `s = s + x`, a new string each time: what ren_str_concat
              does today (quadratic when s grows)
     inplace  `s += x`, in place when s is unique and a whole owner,
              growing its owner by doubling (realloc), else a copy
     builder  a Builder: a buffer with no count to test, `finish()` hands
              its bytes to a Str
     iolist   pieces kept (literals, slices of the input, small numbers
              inline in the value), written with writev, nothing joined
   The inputs are parsed first, untimed, into records whose text fields
   are slices of the input (SSO layout). Output goes to [out], /dev/null
   by default. */
#define REPR_SSO
#include "strs.h"
#include <sys/uio.h>
#include <limits.h>

static int out_fd;
static const char *variant;
/* the variant, fixed at build time (-DV=n): 0 concat, 1 inplace, 2
   builder, 3 iolist */
#ifndef V
#define V 1
#endif

/* ---- inplace: B's value {root, off, len} over an owner with room ---- */
typedef struct {
  bown *root;
  uint32_t off, len;
} gs;
static gs gs_empty(void) {
  gs s = {bown_new("", 0), 0, 0};
  return s;
}
__attribute__((noinline)) static void gs_grow(gs *s, int64_t need) {
  bown *o = s->root;
  int64_t cap = o->cap * 2;
  if (cap < need)
    cap = need;
  if (cap < 16)
    cap = 16;
  if (o->h.rc == 1 && s->off == 0) {
    /* unique: grow in place (realloc may move it; nothing else sees it) */
    if (sizeof(bown) + (size_t)o->cap <= SMALL_WORDS * 8) {
      bown *n = alloc_bytes(sizeof(bown) + (size_t)cap);
      memcpy(n, o, sizeof(bown) + s->len);
      free_bytes(o, sizeof(bown) + (size_t)o->cap);
      o = n;
    } else
      o = realloc(o, sizeof(bown) + (size_t)cap);
    o->cap = cap;
    s->root = o;
  } else {
    bown *n = alloc_bytes(sizeof(bown) + (size_t)cap);
    n->h.rc = 1;
    n->cap = cap;
    memcpy(n->bytes, o->bytes + s->off, s->len);
    if (o->h.rc > 1)
      o->h.rc--;
    s->root = n;
    s->off = 0;
  }
}
INLINE void gs_append(gs *s, const char *p, int64_t n) {
  bown *o = s->root;
  /* unique, a whole owner from its start, with room: Perceus's test */
  if (UNLIKELY(!(o->h.rc == 1 && s->off == 0 && s->len + n <= o->cap)))
    gs_grow(s, s->len + n);
  memcpy(s->root->bytes + s->len, p, (size_t)n);
  s->len += (uint32_t)n;
}
static void gs_free(gs *s) {
  bown *o = s->root;
  if (sizeof(bown) + (size_t)o->cap <= SMALL_WORDS * 8)
    free_bytes(o, sizeof(bown) + (size_t)o->cap);
  else
    free(o);
}

/* ---- concat: a new owner, exactly as long, each time ---- */
typedef struct {
  char *p;
  int64_t len;
} cs;
INLINE void cs_append(cs *s, const char *p, int64_t n) {
  char *q = alloc_bytes(16 + (size_t)(s->len + n));
  memcpy(q + 16, s->p ? s->p + 16 : "", (size_t)s->len);
  memcpy(q + 16 + s->len, p, (size_t)n);
  if (s->p)
    free_bytes(s->p, 16 + (size_t)s->len);
  s->p = q;
  s->len += n;
}

/* ---- builder ---- */
typedef struct {
  char *p;
  int64_t len, cap;
} bld;
__attribute__((noinline)) static void bld_grow(bld *b, int64_t need) {
  int64_t cap = b->cap * 2;
  if (cap < need)
    cap = need;
  if (cap < 64)
    cap = 64;
  b->p = realloc(b->p, (size_t)cap);
  b->cap = cap;
}
INLINE void bld_append(bld *b, const char *p, int64_t n) {
  if (UNLIKELY(b->len + n > b->cap))
    bld_grow(b, b->len + n);
  memcpy(b->p + b->len, p, (size_t)n);
  b->len += n;
}

/* ---- iolist: pieces, each a Str value ---- */
typedef VEC(S) iol;
INLINE void iol_lit(iol *v, const S *lit) { VEC_PUSH(*v, *lit); }
INLINE void iol_str(iol *v, const S *s, int64_t i, int64_t j) {
  S x = s_slice(s, i, j);
  VEC_PUSH(*v, x);
}
static int64_t written;
static void iol_write(iol *v) {
  struct iovec iov[1024];
  int64_t k = 0;
  while (k < v->len) {
    int c = 0;
    for (; c < 1024 && k < v->len; c++, k++) {
      iov[c].iov_base = (void *)s_ptr(&v->data[k]);
      iov[c].iov_len = (size_t)s_len(&v->data[k]);
    }
    ssize_t r = writev(out_fd, iov, c);
    if (r > 0)
      written += r;
  }
  for (int64_t i = 0; i < v->len; i++)
    s_drop(&v->data[i]);
  v->len = 0;
}
static void write_all(const char *p, int64_t n) {
  while (n > 0) {
    ssize_t r = write(out_fd, p, (size_t)n);
    if (r <= 0)
      break;
    written += r;
    p += r;
    n -= r;
  }
}

/* the one sink every variant appends to */
typedef struct {
  gs g;
  cs c;
  bld b;
  iol v;
} out_t;
static void out_init(out_t *o) {
  memset(o, 0, sizeof *o);
  if (V == 1)
    o->g = gs_empty();
}
/* bytes that already exist as a Str (a field, a literal) */
INLINE void put_s(out_t *o, const S *s, int64_t i, int64_t j) {
  switch (V) {
  case 0: cs_append(&o->c, s_ptr(s) + i, j - i); break;
  case 1: gs_append(&o->g, s_ptr(s) + i, j - i); break;
  case 2: bld_append(&o->b, s_ptr(s) + i, j - i); break;
  default: iol_str(&o->v, s, i, j);
  }
}
INLINE void put_lit(out_t *o, const S *s) {
  if (V == 3)
    iol_lit(&o->v, s);
  else
    put_s(o, s, 0, s_len(s));
}
static int itoa_(char *b, int64_t x) {
  char t[24];
  int n = 0;
  bool neg = x < 0;
  uint64_t u = neg ? -(uint64_t)x : (uint64_t)x;
  do {
    t[n++] = (char)('0' + u % 10);
    u /= 10;
  } while (u);
  int k = 0;
  if (neg)
    b[k++] = '-';
  while (n)
    b[k++] = t[--n];
  return k;
}
/* a number: formatted into a new Str (inline: at most 15 bytes) */
INLINE void put_int(out_t *o, int64_t x) {
  char b[24];
  int n = itoa_(b, x);
  if (V == 3) {
    S s = s_new(b, n);
    VEC_PUSH(o->v, s);
  } else {
    S s = s_inline(b, n);
    put_s(o, &s, 0, n);
  }
}
/* the finished output, written */
static void out_flush(out_t *o) {
  switch (V) {
  case 0:
    write_all(o->c.p + 16, o->c.len);
    if (o->c.p)
      free_bytes(o->c.p, 16 + (size_t)o->c.len);
    o->c.p = NULL;
    o->c.len = 0;
    break;
  case 1:
    write_all(o->g.root->bytes, o->g.len);
    gs_free(&o->g);
    o->g = gs_empty();
    break;
  case 2:
    write_all(o->b.p, o->b.len);
    o->b.len = 0; /* a builder can be reused, its room kept */
    break;
  default:
    iol_write(&o->v);
  }
}

static S lit_q, lit_esc_q, lit_esc_bs, lit_comma, lit_open, lit_close;

/* a JSON string: the runs that need no escape go out as they are */
static void put_json_str(out_t *o, const S *s) {
  put_lit(o, &lit_q);
  const char *p = s_ptr(s);
  int64_t n = s_len(s), run = 0;
  for (int64_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)p[i];
    if (c == '"' || c == '\\' || c < 0x20) {
      if (i > run)
        put_s(o, s, run, i);
      put_lit(o, c == '"' ? &lit_esc_q : &lit_esc_bs); /* (no control bytes in the input) */
      run = i + 1;
    }
  }
  if (n > run)
    put_s(o, s, run, n);
  put_lit(o, &lit_q);
}

static S load(const char *dir, const char *name) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  int64_t n;
  char *buf = read_file(path, &n);
  S s = s_new(buf, n);
  free(buf);
  return s;
}

/* ---- json: 1M people as one JSON array ---- */
typedef struct {
  int64_t id, score, ntags;
  S name, email, tags[3];
} person;

static void w_json(const char *dir, int64_t limit) {
  S src = load(dir, "people.csv");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src), i = 0;
  VEC(person) ps = {0};
  while (i < n && ps.len < limit) {
    int64_t f[5][2], q = i;
    for (int k = 0; k < 5; k++) {
      int64_t e = q;
      while (p[e] != '\t' && p[e] != '\n')
        e++;
      f[k][0] = q;
      f[k][1] = e;
      q = e + 1;
    }
    person r = {0};
    for (int64_t k = f[0][0]; k < f[0][1]; k++)
      r.id = r.id * 10 + p[k] - '0';
    for (int64_t k = f[3][0]; k < f[3][1]; k++)
      r.score = r.score * 10 + p[k] - '0';
    r.name = s_slice(&src, f[1][0], f[1][1]);
    r.email = s_slice(&src, f[2][0], f[2][1]);
    int64_t a = f[4][0];
    for (int64_t k = f[4][0]; k <= f[4][1]; k++)
      if (k == f[4][1] || p[k] == ';') {
        if (k > a)
          r.tags[r.ntags++] = s_slice(&src, a, k);
        a = k + 1;
      }
    VEC_PUSH(ps, r);
    i = q;
  }
  S k_id = s_lit("{\"id\":"), k_name = s_lit(",\"name\":"),
    k_email = s_lit(",\"email\":"), k_score = s_lit(",\"score\":"),
    k_tags = s_lit(",\"tags\":["), k_end = s_lit("]}");
  uint64_t t0 = now_ns();
  out_t o;
  out_init(&o);
  put_lit(&o, &lit_open);
  for (int64_t r = 0; r < ps.len; r++) {
    person *x = &ps.data[r];
    if (r)
      put_lit(&o, &lit_comma);
    put_lit(&o, &k_id);
    put_int(&o, x->id);
    put_lit(&o, &k_name);
    put_json_str(&o, &x->name);
    put_lit(&o, &k_email);
    put_json_str(&o, &x->email);
    put_lit(&o, &k_score);
    put_int(&o, x->score);
    put_lit(&o, &k_tags);
    for (int t = 0; t < x->ntags; t++) {
      if (t)
        put_lit(&o, &lit_comma);
      put_json_str(&o, &x->tags[t]);
    }
    put_lit(&o, &k_end);
  }
  put_lit(&o, &lit_close);
  out_flush(&o);
  uint64_t t1 = now_ns();
  printf("check=%lld,%lld\n", (long long)ps.len, (long long)written);
  REPORT("total", t1 - t0);
}

/* ---- logs: 1M log records re-emitted as logfmt, one output ---- */
static void w_logs(const char *dir, int64_t limit) {
  S src = load(dir, "logs.txt");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src), i = 0;
  typedef struct {
    int64_t f[8][2];
    int64_t status, dur;
  } lrec;
  VEC(lrec) rs = {0};
  while (i < n && rs.len < limit) {
    lrec r;
    int64_t q = i;
    for (int k = 0; k < 8; k++) {
      int64_t e = q;
      while (p[e] != ' ' && p[e] != '\n')
        e++;
      r.f[k][0] = q;
      r.f[k][1] = e;
      q = e + 1;
    }
    r.status = r.dur = 0;
    for (int64_t k = r.f[5][0]; k < r.f[5][1]; k++)
      r.status = r.status * 10 + p[k] - '0';
    for (int64_t k = r.f[6][0]; k < r.f[6][1] - 2; k++)
      r.dur = r.dur * 10 + p[k] - '0';
    VEC_PUSH(rs, r);
    i = q;
  }
  S k_ts = s_lit("ts="), k_level = s_lit(" level="), k_svc = s_lit(" svc="),
    k_m = s_lit(" method="), k_path = s_lit(" path=\""),
    k_status = s_lit("\" status="), k_dur = s_lit(" dur_ms="),
    k_req = s_lit(" req_id="), k_nl = s_lit("\n");
  uint64_t t0 = now_ns();
  out_t o;
  out_init(&o);
  for (int64_t r = 0; r < rs.len; r++) {
    lrec *x = &rs.data[r];
    put_lit(&o, &k_ts);
    put_s(&o, &src, x->f[0][0], x->f[0][1]);
    put_lit(&o, &k_level);
    put_s(&o, &src, x->f[1][0], x->f[1][1]);
    put_lit(&o, &k_svc);
    put_s(&o, &src, x->f[2][0], x->f[2][1]);
    put_lit(&o, &k_m);
    put_s(&o, &src, x->f[3][0], x->f[3][1]);
    put_lit(&o, &k_path);
    put_s(&o, &src, x->f[4][0], x->f[4][1]);
    put_lit(&o, &k_status);
    put_int(&o, x->status);
    put_lit(&o, &k_dur);
    put_int(&o, x->dur);
    put_lit(&o, &k_req);
    put_s(&o, &src, x->f[7][0] + 7, x->f[7][1]);
    put_lit(&o, &k_nl);
  }
  out_flush(&o);
  uint64_t t1 = now_ns();
  printf("check=%lld,%lld\n", (long long)rs.len, (long long)written);
  REPORT("total", t1 - t0);
}

/* ---- http: 100k responses, each written on its own ---- */
static void w_http(const char *dir, int64_t count) {
  S body = load(dir, "body.html");
  S h1 = s_lit("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: "),
    h2 = s_lit("\r\nDate: Thu, 29 Oct 2026 09:05:00 GMT\r\nServer: ren\r\nX-Request-Id: "),
    h3 = s_lit("\r\nCache-Control: no-store\r\nConnection: keep-alive\r\n\r\n");
  int64_t bl = s_len(&body);
  uint64_t t0 = now_ns();
  out_t o;
  out_init(&o);
  for (int64_t r = 0; r < count; r++) {
    int64_t len = 512 + (r * 7919) % 1024;
    int64_t at = (r * 104729) % (bl - len);
    put_lit(&o, &h1);
    put_int(&o, len);
    put_lit(&o, &h2);
    put_int(&o, 1000000007LL * r % 9999991);
    put_lit(&o, &h3);
    put_s(&o, &body, at, at + len);
    out_flush(&o);
  }
  uint64_t t1 = now_ns();
  printf("check=%lld,%lld\n", (long long)count, (long long)written);
  REPORT("total", t1 - t0);
}

int main(int argc, char **argv) {
  const char *w = argv[1], *dir = argv[2];
  variant = argv[3];
  static const char *names[] = {"concat", "inplace", "builder", "iolist"};
  if (strcmp(variant, names[V])) {
    fprintf(stderr, "this binary is %s\n", names[V]);
    return 2;
  }
  int64_t limit = argc > 4 ? atoll(argv[4]) : INT64_MAX;
  out_fd = open(argc > 5 ? argv[5] : "/dev/null", O_WRONLY | O_CREAT | O_TRUNC, 0644);
  lit_q = s_lit("\"");
  lit_esc_q = s_lit("\\\"");
  lit_esc_bs = s_lit("\\\\");
  lit_comma = s_lit(",");
  lit_open = s_lit("[");
  lit_close = s_lit("]");
  if (!strcmp(w, "json"))
    w_json(dir, limit);
  else if (!strcmp(w, "logs"))
    w_logs(dir, limit);
  else
    w_http(dir, limit == INT64_MAX ? 100000 : limit);
  printf("variant=%s\n", variant);
  return 0;
}
