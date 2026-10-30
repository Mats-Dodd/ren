/* W1 spawn: 1M trivial tasks, fan-out and fan-in. */
#include "emit.h"
#include <stdlib.h>

typedef struct { int64_t sum; int64_t left; long n; int measure; uint64_t t0, t1; ren_task *root; } w1_st;
typedef struct { ren_task h; w1_st *st; long i; } w1_root;
typedef struct { ren_task h; w1_st *st; ren_task *parent; long idx; } w1_child;

static void child_fin(ren_task *t) { ren_rc_drop(&((w1_child *)t)->parent->obj); }

static int32_t child_resume(ren_task *self, ren_ctx *cx) {
  w1_child *f = (w1_child *)self;
  ren_xadd64(&f->st->sum, f->idx, REN_MO_RELAXED);
  if (ren_xadd64(&f->st->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, f->parent);
  return REN_T_DONE;
}

static int32_t root_resume(ren_task *self, ren_ctx *cx) {
  w1_root *f = (w1_root *)self;
  w1_st *st = f->st;
  switch (self->pc) {
  case 0:
    if (st->measure) st->t0 = wl_now_ns();
    ren_st64(&st->left, st->n, REN_MO_RELAXED);
    f->i = 0;
    self->pc = 1;
    /* fallthrough */
  case 1:
    while (f->i < st->n) {
      w1_child *c = (w1_child *)ren_task_new(sizeof *c, child_resume, child_fin);
      c->st = st; c->parent = self; c->idx = f->i;
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &c->h);
      f->i++;
      if (ren_tick(cx)) return REN_T_YIELD;
    }
    self->pc = 2;
    /* fallthrough */
  case 2:
    if (ren_ld64(&st->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    if (st->measure) st->t1 = wl_now_ns();
    return REN_T_DONE;
  }
  wl_fail("w1: bad pc");
}

static void *w1_init(const wl_args *a) {
  w1_st *st = calloc(1, sizeof *st);
  st->n = a->n ? a->n : 1000000; st->measure = a->measure;
  return st;
}
static ren_task *w1_main(const ren_config *cfg) {
  w1_root *r = (w1_root *)ren_task_new(sizeof *r, root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int w1_report(void *u, FILE *res, FILE *met, double wall) {
  w1_st *st = u;
  int64_t want = (int64_t)st->n * (st->n - 1) / 2;
  int64_t sum = ren_ld64(&st->sum, REN_MO_ACQUIRE);
  fprintf(res, "result: w1 n=%ld sum=%lld left=%lld\n", st->n, (long long)sum,
          (long long)ren_ld64(&st->left, REN_MO_ACQUIRE));
  if (st->measure && st->t1 > st->t0)
    fprintf(met, "metric: w1 tasks_per_s=%.0f inner_s=%.6f wall_s=%.6f\n",
            st->n / ((st->t1 - st->t0) / 1e9), (st->t1 - st->t0) / 1e9, wall);
  return sum == want && st->left == 0 ? 0 : 1;
}
static void w1_fini(void *u) { free(u); }
const wl_def wl_w1 = {"w1", w1_init, w1_main, w1_report, w1_fini};
