/* W2 switch: two tasks ping-pong through a channel-like await, 10M times. */
#include "emit.h"
#include <stdlib.h>

typedef struct { int64_t turn; int64_t left; long n; int measure; uint64_t t0, t1; ren_task *p[2]; ren_task *root; } w2_st;
typedef struct { ren_task h; w2_st *st; } w2_root;
typedef struct { ren_task h; w2_st *st; int me; } w2_player;

static void player_fin(ren_task *t) { ren_rc_drop(&((w2_player *)t)->st->root->obj); }

static int32_t player_resume(ren_task *self, ren_ctx *cx) {
  w2_player *f = (w2_player *)self;
  w2_st *st = f->st;
  ren_task *other = st->p[1 - f->me];
  for (;;) {
    int64_t t = ren_ld64(&st->turn, REN_MO_ACQUIRE);
    if (t >= st->n || ren_cancelled(cx)) break;
    if ((t & 1) != f->me) return REN_T_PARK;       /* await my turn */
    ren_st64(&st->turn, t + 1, REN_MO_RELEASE);     /* send */
    ren_notify(cx, other);
    if (ren_tick(cx)) return REN_T_YIELD;
  }
  /* finally: the peer may be parked waiting for a turn that won't come */
  if (ren_ld64(&st->turn, REN_MO_ACQUIRE) < st->n) ren_st64(&st->turn, st->n, REN_MO_RELEASE);
  ren_notify(cx, other);
  if (ren_xadd64(&st->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, st->root);
  return REN_T_DONE;
}

static int32_t root_resume(ren_task *self, ren_ctx *cx) {
  w2_root *f = (w2_root *)self;
  w2_st *st = f->st;
  switch (self->pc) {
  case 0:
    if (st->measure) st->t0 = wl_now_ns();
    st->root = self;
    ren_st64(&st->left, 2, REN_MO_RELAXED);
    for (int i = 0; i < 2; i++) {
      w2_player *p = (w2_player *)ren_task_new(sizeof *p, player_resume, player_fin);
      p->st = st; p->me = i;
      ren_rc_dup(&self->obj);        /* each player holds the root, to notify it */
      st->p[i] = &p->h;
      ren_rc_dup(&p->h.obj);         /* st keeps one reference to each, for notify */
    }
    ren_spawn(cx, st->p[0]);
    ren_spawn(cx, st->p[1]);
    self->pc = 1;
    /* fallthrough */
  case 1:
    if (ren_ld64(&st->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    if (st->measure) st->t1 = wl_now_ns();
    ren_rc_drop(&st->p[0]->obj);
    ren_rc_drop(&st->p[1]->obj);
    return REN_T_DONE;
  }
  wl_fail("w2: bad pc");
}

static void *w2_init(const wl_args *a) {
  w2_st *st = calloc(1, sizeof *st);
  st->n = a->n ? a->n : 10000000; st->measure = a->measure;
  return st;
}
static ren_task *w2_main(const ren_config *cfg) {
  w2_root *r = (w2_root *)ren_task_new(sizeof *r, root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int w2_report(void *u, FILE *res, FILE *met, double wall) {
  w2_st *st = u;
  int64_t turn = ren_ld64(&st->turn, REN_MO_ACQUIRE);
  fprintf(res, "result: w2 n=%ld turn=%lld\n", st->n, (long long)turn);
  if (st->measure && st->t1 > st->t0)
    fprintf(met, "metric: w2 ns_per_switch=%.2f inner_s=%.6f wall_s=%.6f\n",
            (double)(st->t1 - st->t0) / st->n, (st->t1 - st->t0) / 1e9, wall);
  return turn == st->n ? 0 : 1;
}
static void w2_fini(void *u) { free(u); }
const wl_def wl_w2 = {"w2", w2_init, w2_main, w2_report, w2_fini};
