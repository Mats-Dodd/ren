/* W3 world-call round trip: WRITE 1 byte, then time a 1-byte READ of it. */
#include "emit.h"
#include <stdlib.h>
#include <string.h>

typedef struct { long n; int measure; uint64_t *lat; uint64_t csum; long done; int ok; } w3_st;
typedef struct { ren_task h; w3_st *st; ren_await aw; long i; int64_t rfd, wfd; uint64_t t0; uint8_t wbuf[8], rbuf[8]; } w3_root;

static int cmp_u64(const void *a, const void *b) {
  uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
  return x < y ? -1 : x > y;
}

static int32_t root_resume(ren_task *self, ren_ctx *cx) {
  w3_root *f = (w3_root *)self;
  w3_st *st = f->st;
  switch (self->pc) {
  case 0:
    EM_ISSUE(1, REN_OP_PIPE, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 0) { st->ok = 0; return REN_T_DONE; }
    f->rfd = f->aw.res.a; f->wfd = f->aw.res.b; f->i = 0;
    /* fallthrough */
  case 2:
  loop:
    if (f->i == st->n || ren_cancelled(cx)) goto close;
    f->wbuf[0] = (uint8_t)(f->i * 7 + 1);
    EM_ISSUE(3, REN_OP_WRITE, f->wfd, f->wbuf, 1, 0);
    /* fallthrough */
  case 3:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 1) { st->ok = 0; goto close; }
    if (st->measure) f->t0 = wl_now_ns();
    f->rbuf[0] = 0;
    EM_ISSUE(4, REN_OP_READ, f->rfd, f->rbuf, 1, 0);
    /* fallthrough */
  case 4:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 1) { st->ok = 0; goto close; }
    if (st->measure) st->lat[f->i] = wl_now_ns() - f->t0;
    st->csum = wl_fnv1a(f->rbuf, 1, st->csum);
    f->i++;
    st->done = f->i;
    self->pc = 2;
    goto loop;
  close:
    EM_ISSUE(5, REN_OP_CLOSE, f->rfd, NULL, 0, 0);
    /* fallthrough */
  case 5:
    EM_AWAIT();
    EM_ISSUE(6, REN_OP_CLOSE, f->wfd, NULL, 0, 0);
    /* fallthrough */
  case 6:
    EM_AWAIT();
    return REN_T_DONE;
  }
  wl_fail("w3: bad pc");
}

static void *w3_init(const wl_args *a) {
  w3_st *st = calloc(1, sizeof *st);
  st->n = a->n ? a->n : 200000; st->measure = a->measure; st->ok = 1;
  st->csum = WL_FNV_BASIS;
  if (st->measure) st->lat = calloc((size_t)st->n, sizeof(uint64_t));
  return st;
}
static ren_task *w3_main(const ren_config *cfg) {
  w3_root *r = (w3_root *)ren_task_new(sizeof *r, root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int w3_report(void *u, FILE *res, FILE *met, double wall) {
  w3_st *st = u;
  uint64_t want = WL_FNV_BASIS;
  for (long i = 0; i < st->n; i++) { uint8_t b = (uint8_t)(i * 7 + 1); want = wl_fnv1a(&b, 1, want); }
  fprintf(res, "result: w3 n=%ld done=%ld csum=%016llx\n", st->n, st->done, (unsigned long long)st->csum);
  if (st->measure && st->done == st->n && st->n > 0) {
    qsort(st->lat, (size_t)st->n, sizeof(uint64_t), cmp_u64);
    fprintf(met, "metric: w3 p50_ns=%llu p99_ns=%llu p999_ns=%llu min_ns=%llu wall_s=%.6f rtt_per_s=%.0f\n",
            (unsigned long long)st->lat[st->n / 2], (unsigned long long)st->lat[(st->n * 99) / 100],
            (unsigned long long)st->lat[(st->n * 999) / 1000], (unsigned long long)st->lat[0], wall,
            st->n / wall);
  }
  return st->ok && st->done == st->n && st->csum == want ? 0 : 1;
}
static void w3_fini(void *u) { w3_st *st = u; free(st->lat); free(st); }
const wl_def wl_w3 = {"w3", w3_init, w3_main, w3_report, w3_fini};
