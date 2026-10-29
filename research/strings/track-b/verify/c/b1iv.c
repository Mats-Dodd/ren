/* B1 (layout) and B4 (keys): `b1 <workload> <datadir>`, workloads
   tok, map, sort, group, logs. Each reads its input whole into one Str
   (untimed), then times its kernel, the drops at the end included, and
   prints `check=` (the same in every layout and in the Rust and Go
   twins) and `<phase>_ns=`. */
#include "map.h"

static S load(const char *dir, const char *name) {
  char path[512];
  snprintf(path, sizeof path, "%s/%s", dir, name);
  int64_t n;
  char *buf = read_file(path, &n);
  S s = s_new(buf, n);
  free(buf);
  return s;
}

/* the next line of p[*i..n), without its '\n'; false at the end */
INLINE bool next_line(const char *p, int64_t n, int64_t *i, int64_t *a,
                      int64_t *b) {
  if (*i >= n)
    return false;
  *a = *i;
  const char *q = memchr(p + *i, '\n', (size_t)(n - *i));
  *b = q ? q - p : n;
  *i = *b + 1;
  return true;
}

/* ---- tok: a tokenizer keeping 1M tokens ---- */
typedef struct {
  int64_t kind;
  S text;
} tok;
enum { T_IDENT, T_NUM, T_STR, T_PUNCT };

static void w_tok(const char *dir) {
  S src = load(dir, "tok.txt");
  S kw = s_lit("return");
  uint64_t t0 = now_ns();
  VEC(tok) ts = {0};
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src), i = 0;
  while (i < n) {
    unsigned char c = (unsigned char)p[i];
    if (c == ' ' || c == '\n' || c == '\t') {
      i++;
      continue;
    }
    int64_t j = i + 1, kind;
    if (c == '_' || (c | 32) - 'a' < 26u) {
      while (j < n && (p[j] == '_' || ((unsigned char)p[j] | 32) - 'a' < 26u ||
                       (unsigned char)p[j] - '0' < 10u))
        j++;
      kind = T_IDENT;
    } else if (c - '0' < 10u) {
      while (j < n && (unsigned char)p[j] - '0' < 10u)
        j++;
      kind = T_NUM;
    } else if (c == '"') {
      while (j < n && p[j] != '"')
        j++;
      j++;
      kind = T_STR;
    } else {
      if (j < n && (((c == '=' || c == '!' || c == '<' || c == '>' || c == '+') &&
                     p[j] == '=') ||
                    (c == '-' && p[j] == '>')))
        j++;
      kind = T_PUNCT;
    }
    __asm__("" : "+r"(j));
    tok t = {kind, s_keep(s_slice(&src, i, j))};
    VEC_PUSH(ts, t);
    i = j;
  }
  s_drop(&src); /* the program's own reference: the tokens keep it */
  uint64_t t1 = now_ns();
  int64_t returns = 0, idents = 0, total = 0;
  for (int64_t k = 0; k < ts.len; k++) {
    returns += s_eq(&ts.data[k].text, &kw);
    idents += ts.data[k].kind == T_IDENT;
    total += s_len(&ts.data[k].text);
  }
  uint64_t t2 = now_ns();
  for (int64_t k = 0; k < ts.len; k++)
    s_drop(&ts.data[k].text);
  free(ts.data);
  uint64_t t3 = now_ns();
  printf("check=%lld,%lld,%lld,%lld\n", (long long)ts.len, (long long)returns,
         (long long)idents, (long long)total);
  REPORT("scan", t1 - t0);
  REPORT("use", t2 - t1);
  REPORT("drop", t3 - t2);
  REPORT("total", t3 - t0);
}

/* ---- map: Map<Str, Int> counts of 4M keys, then 4M lookups ---- */
static void w_map(const char *dir) {
  S src = load(dir, "keys.txt");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src);
  uint64_t t0 = now_ns();
  smap m = {0};
  int64_t i = 0, a, b;
  while (next_line(p, n, &i, &a, &b))
    smap_add(&m, &src, a, b, 1);
  uint64_t t1 = now_ns();
  int64_t sum = 0;
  i = 0;
  while (next_line(p, n, &i, &a, &b)) {
    int64_t e = smap_find(&m, p + a, b - a);
    sum += m.e[e].val;
  }
  uint64_t t2 = now_ns();
  int64_t distinct = m.len;
  smap_free(&m);
  s_drop(&src);
  uint64_t t3 = now_ns();
  printf("check=%lld,%lld\n", (long long)distinct, (long long)sum);
  REPORT("build", t1 - t0);
  REPORT("lookup", t2 - t1);
  REPORT("drop", t3 - t2);
  REPORT("total", t3 - t0);
}

/* ---- sort: 1M strings ---- */
INLINE void swap_s(S *a, S *b) {
  S t = *a;
  *a = *b;
  *b = t;
}
static void qsort_s(S *x, int64_t n) {
  while (n > 16) {
    int64_t m = n / 2;
    if (s_cmp(&x[m], &x[0]) < 0)
      swap_s(&x[m], &x[0]);
    if (s_cmp(&x[n - 1], &x[m]) < 0) {
      swap_s(&x[n - 1], &x[m]);
      if (s_cmp(&x[m], &x[0]) < 0)
        swap_s(&x[m], &x[0]);
    }
    S piv = x[m];
    int64_t i = 0, j = n - 1;
    for (;;) {
      while (s_cmp(&x[i], &piv) < 0)
        i++;
      while (s_cmp(&piv, &x[j]) < 0)
        j--;
      if (i >= j)
        break;
      swap_s(&x[i], &x[j]);
      i++;
      j--;
    }
    /* recurse on the smaller part */
    if (j + 1 < n - j - 1) {
      qsort_s(x, j + 1);
      x += j + 1;
      n -= j + 1;
    } else {
      qsort_s(x + j + 1, n - j - 1);
      n = j + 1;
    }
  }
  for (int64_t i = 1; i < n; i++) {
    S v = x[i];
    int64_t j = i;
    while (j > 0 && s_cmp(&v, &x[j - 1]) < 0) {
      x[j] = x[j - 1];
      j--;
    }
    x[j] = v;
  }
}
static void w_sort(const char *dir) {
  S src = load(dir, "sort.txt");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src);
  uint64_t t0 = now_ns();
  VEC(S) xs = {0};
  int64_t i = 0, a, b;
  while (next_line(p, n, &i, &a, &b)) {
    __asm__("" : "+r"(b));
    S s = s_keep(s_slice(&src, a, b));
    VEC_PUSH(xs, s);
  }
  s_drop(&src);
  uint64_t t1 = now_ns();
  qsort_s(xs.data, xs.len);
  uint64_t t2 = now_ns();
  int64_t check = 0;
  for (int64_t k = 0; k < xs.len; k += 1000)
    check += s_len(&xs.data[k]) * k + (unsigned char)s_ptr(&xs.data[k])[0];
  for (int64_t k = 0; k < xs.len; k++)
    s_drop(&xs.data[k]);
  free(xs.data);
  uint64_t t3 = now_ns();
  printf("check=%lld,%lld\n", (long long)xs.len, (long long)check);
  REPORT("slice", t1 - t0);
  REPORT("sort", t2 - t1);
  REPORT("drop", t3 - t2);
  REPORT("total", t3 - t0);
}

/* ---- group: sum of amount by city over 5M CSV rows ---- */
static void w_group(const char *dir) {
  S src = load(dir, "rows.csv");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src);
  uint64_t t0 = now_ns();
  smap m = {0};
  int64_t i = 0, a, b;
  while (next_line(p, n, &i, &a, &b)) {
    const char *c1 = memchr(p + a, ',', (size_t)(b - a));
    int64_t k = b;
    while (p[k - 1] != ',')
      k--;
    int64_t amt = 0;
    for (int64_t q = k; q < b; q++)
      amt = amt * 10 + (p[q] - '0');
    smap_add(&m, &src, a, c1 - p, amt);
  }
  int64_t check = 0, total = 0;
  for (int64_t e = 0; e < m.len; e++) {
    check ^= s_len(&m.e[e].key) * 1000003 + m.e[e].val;
    total += m.e[e].val;
  }
  int64_t groups = m.len;
  smap_free(&m);
  s_drop(&src);
  uint64_t t2 = now_ns();
  printf("check=%lld,%lld,%lld\n", (long long)groups, (long long)total,
         (long long)check);
  REPORT("total", t2 - t0);
}

/* ---- logs: parse 1M lines into records that keep their fields ---- */
typedef struct {
  S ts, level, svc, method, path, req;
  int64_t status, dur;
} rec;

static void w_logs(const char *dir) {
  S src = load(dir, "logs.txt");
  S error = s_lit("ERROR");
  const char *p = s_ptr(&src);
  int64_t n = s_len(&src);
  uint64_t t0 = now_ns();
  VEC(rec) rs = {0};
  int64_t i = 0, a, b;
  while (next_line(p, n, &i, &a, &b)) {
    int64_t f[8][2], nf = 0, q = a;
    while (nf < 7) {
      int64_t e = q;
      while (p[e] != ' ')
        e++;
      __asm__("" : "+r"(e)); /* stop LSR from carrying packed {off,len} IVs through the byte scan */
      f[nf][0] = q;
      f[nf][1] = e;
      nf++;
      q = e + 1;
    }
    f[7][0] = q;
    f[7][1] = b;
    rec r;
    r.ts = s_keep(s_slice(&src, f[0][0], f[0][1]));
    r.level = s_keep(s_slice(&src, f[1][0], f[1][1]));
    r.svc = s_keep(s_slice(&src, f[2][0], f[2][1]));
    r.method = s_keep(s_slice(&src, f[3][0], f[3][1]));
    r.path = s_keep(s_slice(&src, f[4][0], f[4][1]));
    r.status = 0;
    for (int64_t k = f[5][0]; k < f[5][1]; k++)
      r.status = r.status * 10 + (p[k] - '0');
    r.dur = 0;
    for (int64_t k = f[6][0]; k < f[6][1] - 2; k++)
      r.dur = r.dur * 10 + (p[k] - '0');
    r.req = s_keep(s_slice(&src, f[7][0] + 7, f[7][1]));
    VEC_PUSH(rs, r);
  }
  s_drop(&src);
  uint64_t t1 = now_ns();
  int64_t errors = 0, slow = 0, users = 0;
  for (int64_t k = 0; k < rs.len; k++) {
    rec *r = &rs.data[k];
    errors += s_eq(&r->level, &error);
    if (r->status >= 500)
      slow += r->dur;
    users += s_len(&r->path) >= 9 && memcmp(s_ptr(&r->path), "/v1/users", 9) == 0;
  }
  uint64_t t2 = now_ns();
  for (int64_t k = 0; k < rs.len; k++) {
    rec *r = &rs.data[k];
    s_drop(&r->ts);
    s_drop(&r->level);
    s_drop(&r->svc);
    s_drop(&r->method);
    s_drop(&r->path);
    s_drop(&r->req);
  }
  free(rs.data);
  uint64_t t3 = now_ns();
  printf("check=%lld,%lld,%lld,%lld\n", (long long)rs.len, (long long)errors,
         (long long)slow, (long long)users);
  REPORT("parse", t1 - t0);
  REPORT("query", t2 - t1);
  REPORT("drop", t3 - t2);
  REPORT("total", t3 - t0);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: b1 tok|map|sort|group|logs <datadir>\n");
    return 2;
  }
  const char *w = argv[1], *dir = argv[2];
  if (!strcmp(w, "tok"))
    w_tok(dir);
  else if (!strcmp(w, "map"))
    w_map(dir);
  else if (!strcmp(w, "sort"))
    w_sort(dir);
  else if (!strcmp(w, "group"))
    w_group(dir);
  else if (!strcmp(w, "logs"))
    w_logs(dir);
#ifdef STATS
  fprintf(stderr, "stats allocs=%lld frees=%lld dups=%lld drops=%lld copies=%lld copied_bytes=%lld peak_bytes=%lld live=%lld\n",
          (long long)st.allocs, (long long)st.frees, (long long)st.dups,
          (long long)st.drops, (long long)st.copies, (long long)st.copied_bytes,
          (long long)st.peak, (long long)st.live);
#endif
  printf("repr=%s\n", REPR_NAME);
  return 0;
}
