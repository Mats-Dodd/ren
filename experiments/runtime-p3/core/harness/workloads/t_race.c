/* t_race.c: two E1 workloads for the real drivers (machine "cloud").

   T_RACE (E1 (c), SYNTHESIS §2.2): a reply racing a cancel, n rounds.
     Each round a reader R issues READ(1 byte) on an empty pipe and a peer
     C writes one byte to that pipe and, as soon as its WRITE is done,
     cancels R's READ. The kernel completing the READ races the cancel.
     Rule (§2.2): cancellation waits, and the reply goes to the waiter. R
     sees DONE with the byte, or CANCELLED with res -125 and the byte still
     in the pipe, which R then reads with a second, uncancelled READ.
     A byte lost or read twice fails the run. The result line counts the
     two outcomes, so a replay must reproduce the same split.

   T_SPUR (the SPEC §B.5 window): m pairs per round, n rounds. A issues
     SleepUntil(0) (due at once) and awaits it; S holds a reference to A
     and notifies it over and over (spurious wakes) until A says it saw its
     reply, then drops that reference. When deliver() stores A's result
     while S has A running on another worker, A can finish and be freed
     before deliver's notify: a use-after-free in the Phase B core, which
     ASan reports when the REN_E1_DELIVER_GAP_NS hook widens the window. */
#include "emit.h"
#include <stdlib.h>
#include <string.h>

/* ================= T_RACE ================= */
typedef struct {
  long n, round;
  int64_t rfd, wfd;
  int64_t left;           /* tasks of this round still running */
  uint64_t r_id;          /* R's READ id, published for C */
  int64_t done, cancelled, failed;
  char why[96];
  ren_task *root;
} tr_st;
typedef struct { ren_task h; tr_st *st; ren_await aw; uint8_t buf[4]; } tr_task;
typedef struct { ren_task h; tr_st *st; ren_await aw; } tr_root;

static void tr_fail(tr_st *st, const char *why) {
  if (!st->failed) { st->failed = 1; strncpy(st->why, why, sizeof st->why - 1); }
}
static void tr_fin(ren_task *t) { ren_rc_drop(&((tr_task *)t)->st->root->obj); }
static void tr_done(tr_st *st, ren_ctx *cx) {
  if (ren_xadd64(&st->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, st->root);
}

static int32_t tr_reader(ren_task *self, ren_ctx *cx) {
  tr_task *f = (tr_task *)self;
  tr_st *st = f->st;
  uint8_t want = (uint8_t)(st->round & 0xff);
  switch (self->pc) {
  case 0:
    EM_ISSUE_THEN(1, REN_OP_READ, st->rfd, f->buf, 1, 0,
                  ren_st64((int64_t *)&st->r_id, (int64_t)f->aw.id, REN_MO_RELEASE));
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (EM_OK()) {
      if (f->aw.res.res != 1 || f->buf[0] != want) tr_fail(st, "race: DONE but not the byte");
      st->done++;
      tr_done(st, cx);
      return REN_T_DONE;
    }
    if (f->aw.res.res != -REN_ECANCELED) tr_fail(st, "race: CANCELLED with res != -125");
    st->cancelled++;
    /* the byte must still be in the pipe: a cancelled call had no effect */
    EM_ISSUE(2, REN_OP_READ, st->rfd, f->buf, 1, 0);
    /* fallthrough */
  case 2:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 1 || f->buf[0] != want) tr_fail(st, "race: the cancelled READ lost the byte");
    tr_done(st, cx);
    return REN_T_DONE;
  }
  wl_fail("t_race: reader pc");
}

static int32_t tr_canceller(ren_task *self, ren_ctx *cx) {
  tr_task *f = (tr_task *)self;
  tr_st *st = f->st;
  switch (self->pc) {
  case 0:
    f->buf[0] = (uint8_t)(st->round & 0xff);
    EM_ISSUE(1, REN_OP_WRITE, st->wfd, f->buf, 1, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 1) tr_fail(st, "race: write failed");
    self->pc = 2;
    /* fallthrough */
  case 2: {
    uint64_t id = (uint64_t)ren_ld64((int64_t *)&st->r_id, REN_MO_ACQUIRE);
    if (id == 0) return REN_T_YIELD;   /* R has not issued yet */
    ren_cancel(cx, id);
    tr_done(st, cx);
    return REN_T_DONE;
  }
  }
  wl_fail("t_race: canceller pc");
}

static int32_t tr_root_resume(ren_task *self, ren_ctx *cx) {
  tr_root *f = (tr_root *)self;
  tr_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->root = self;
    EM_ISSUE(1, REN_OP_PIPE, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    st->rfd = f->aw.res.a; st->wfd = f->aw.res.b;
    st->round = 0;
    /* fallthrough */
  case 2:
  next_round:
    if (st->round >= st->n || st->failed) {
      EM_ISSUE(4, REN_OP_CLOSE, st->rfd, NULL, 0, 0);
      goto close_w;
    }
    ren_st64((int64_t *)&st->r_id, 0, REN_MO_RELAXED);
    ren_st64(&st->left, 2, REN_MO_RELAXED);
    for (int k = 0; k < 2; k++) {
      tr_task *t = (tr_task *)ren_task_new(sizeof *t, k ? tr_canceller : tr_reader, tr_fin);
      t->st = st;
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &t->h);
    }
    self->pc = 3;
    /* fallthrough */
  case 3:
    if (ren_ld64(&st->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    st->round++;
    self->pc = 2;
    goto next_round;
  case 4:
  close_w:
    EM_AWAIT();
    EM_ISSUE(5, REN_OP_CLOSE, st->wfd, NULL, 0, 0);
    /* fallthrough */
  case 5:
    EM_AWAIT();
    return REN_T_DONE;
  }
  wl_fail("t_race: root pc");
}
static void *tr_init(const wl_args *a) {
  tr_st *st = calloc(1, sizeof *st);
  st->n = a->n ? a->n : 300;
  return st;
}
static ren_task *tr_main(const ren_config *cfg) {
  tr_root *r = (tr_root *)ren_task_new(sizeof *r, tr_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tr_report(void *u, FILE *res, FILE *met, double wall) {
  tr_st *st = u; (void)wall;
  fprintf(res, "result: t_race n=%ld rounds=%ld done=%lld cancelled=%lld\n", st->n, st->round,
          (long long)st->done, (long long)st->cancelled);
  fprintf(met, "metric: t_race reply_won=%lld cancel_won=%lld\n", (long long)st->done, (long long)st->cancelled);
  int ok = !st->failed && st->round == st->n && st->done + st->cancelled == st->n;
  if (!ok) fprintf(stderr, "t_race: %s\n", st->failed ? st->why : "rounds missing");
  return ok ? 0 : 1;
}
static void tr_free(void *u) { free(u); }
const wl_def wl_t_race = {"t_race", tr_init, tr_main, tr_report, tr_free};

/* ================= T_SPUR ================= */
#define SP_M 8
typedef struct {
  long n, round;
  int64_t left;
  int64_t saw[SP_M];       /* A[i] saw its reply (S[i] may stop) */
  int64_t spurious;        /* resumes of A that found no reply */
  ren_task *root;
} sp_st;
typedef struct { ren_task h; sp_st *st; ren_await aw; int i; } sp_a;
typedef struct { ren_task h; sp_st *st; ren_task *a; int i; } sp_s;
typedef struct { ren_task h; sp_st *st; } sp_root;

static void sp_done(sp_st *st, ren_ctx *cx) {
  if (ren_xadd64(&st->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, st->root);
}
static void sp_a_fin(ren_task *t) { ren_rc_drop(&((sp_a *)t)->st->root->obj); }
static void sp_s_fin(ren_task *t) { ren_rc_drop(&((sp_s *)t)->st->root->obj); }

static int32_t sp_a_resume(ren_task *self, ren_ctx *cx) {
  sp_a *f = (sp_a *)self;
  switch (self->pc) {
  case 0:
    EM_ISSUE(1, REN_OP_SLEEP_UNTIL, -1, NULL, 0, 0);   /* due at once: the driver replies next loop */
    /* fallthrough */
  case 1:
    if (wl_aw_state(&f->aw) == 0) { ren_xadd64(&f->st->spurious, 1, REN_MO_RELAXED); return REN_T_PARK; }
    ren_st64(&f->st->saw[f->i], 1, REN_MO_RELEASE);
    sp_done(f->st, cx);
    return REN_T_DONE;          /* the core drops its reference: A may be freed now */
  }
  wl_fail("t_spur: a pc");
}
static int32_t sp_s_resume(ren_task *self, ren_ctx *cx) {
  sp_s *f = (sp_s *)self;
  if (ren_ld64(&f->st->saw[f->i], REN_MO_ACQUIRE)) {
    ren_rc_drop(&f->a->obj);    /* S's reference to A */
    f->a = NULL;
    sp_done(f->st, cx);
    return REN_T_DONE;
  }
  ren_notify(cx, f->a);         /* a spurious wake: A's call is still pending */
  return REN_T_YIELD;
}
static int32_t sp_root_resume(ren_task *self, ren_ctx *cx) {
  sp_root *f = (sp_root *)self;
  sp_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->root = self;
    /* fallthrough */
  case 1:
  again:
    if (st->round >= st->n) return REN_T_DONE;
    ren_st64(&st->left, 2 * SP_M, REN_MO_RELAXED);
    for (int i = 0; i < SP_M; i++) {
      ren_st64(&st->saw[i], 0, REN_MO_RELAXED);
      sp_a *a = (sp_a *)ren_task_new(sizeof *a, sp_a_resume, sp_a_fin);
      a->st = st; a->i = i;
      sp_s *s = (sp_s *)ren_task_new(sizeof *s, sp_s_resume, sp_s_fin);
      s->st = st; s->i = i; s->a = &a->h;
      ren_rc_dup(&a->h.obj);    /* S's reference */
      ren_rc_dup(&self->obj); ren_rc_dup(&self->obj);
      ren_spawn(cx, &a->h);
      ren_spawn(cx, &s->h);
    }
    self->pc = 2;
    /* fallthrough */
  case 2:
    if (ren_ld64(&st->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    st->round++;
    self->pc = 1;
    goto again;
  }
  wl_fail("t_spur: root pc");
}
static void *sp_init(const wl_args *a) {
  sp_st *st = calloc(1, sizeof *st);
  st->n = a->n ? a->n : 2000;
  return st;
}
static ren_task *sp_main(const ren_config *cfg) {
  sp_root *r = (sp_root *)ren_task_new(sizeof *r, sp_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int sp_report(void *u, FILE *res, FILE *met, double wall) {
  sp_st *st = u; (void)wall;
  fprintf(res, "result: t_spur n=%ld rounds=%ld\n", st->n, st->round);
  fprintf(met, "metric: t_spur spurious_resumes=%lld\n", (long long)st->spurious);
  return st->round == st->n ? 0 : 1;
}
const wl_def wl_t_spur = {"t_spur", sp_init, sp_main, sp_report, tr_free};
