/* t_io.c: driver tests T_TIMER, T_PIPE, T_TCP, T_CANCEL and T_BLOCK
   (T_STOP / T_KILL: the host calls ren_stop / ren_kill). SPEC §C.2.
   Each fd has at most one pending READ and one pending WRITE/ACCEPT. */
#include "emit.h"
#include <stdlib.h>
#include <string.h>

/* ---- shared fan-in: children hold the root and notify it ---- */
typedef struct { int64_t left; ren_task *root; int failed; char why[96]; } fan;
static void fan_fail(fan *fn, const char *why) {
  if (!fn->failed) { fn->failed = 1; strncpy(fn->why, why, sizeof fn->why - 1); }
}
static void fan_done(fan *fn, ren_ctx *cx) {
  if (ren_xadd64(&fn->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, fn->root);
}
static void fan_child(fan *fn, ren_ctx *cx, ren_task *c) {
  ren_xadd64(&fn->left, 1, REN_MO_RELAXED);
  ren_rc_dup(&fn->root->obj);
  ren_spawn(cx, c);
}
typedef struct { ren_task h; fan *fn; ren_await aw; } child_hdr;
static void child_fin(ren_task *t) { ren_rc_drop(&((child_hdr *)t)->fn->root->obj); }

/* ================= T_TIMER ================= */
static const int64_t tm_ms[5] = {25, 5, 15, 20, 10};
typedef struct { fan fn; int64_t base; int64_t order[5]; int64_t fin_ns[5]; int64_t next; } tm_st;
typedef struct { ren_task h; fan *fn; ren_await aw; tm_st *st; int k; } tm_child;
typedef struct { ren_task h; tm_st *st; ren_await aw; } tm_root;

static int32_t tm_child_resume(ren_task *self, ren_ctx *cx) {
  tm_child *f = (tm_child *)self;
  switch (self->pc) {
  case 0:
    EM_ISSUE(1, REN_OP_SLEEP_UNTIL, -1, NULL, 0, f->st->base + tm_ms[f->k] * 1000000);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK()) fan_fail(f->fn, "timer: sleep not DONE");
    EM_ISSUE(2, REN_OP_MONO_NOW, -1, NULL, 0, 0);
    /* fallthrough */
  case 2:
    EM_AWAIT();
    f->st->fin_ns[f->k] = f->aw.res.res;
    f->st->order[ren_xadd64(&f->st->next, 1, REN_MO_RELAXED)] = f->k;
    fan_done(f->fn, cx);
    return REN_T_DONE;
  }
  wl_fail("t_timer: pc");
}
static int32_t tm_root_resume(ren_task *self, ren_ctx *cx) {
  tm_root *f = (tm_root *)self;
  tm_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->fn.root = self;
    EM_ISSUE(1, REN_OP_MONO_NOW, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    st->base = f->aw.res.res;
    for (int k = 0; k < 5; k++) {
      tm_child *c = (tm_child *)ren_task_new(sizeof *c, tm_child_resume, child_fin);
      c->fn = &st->fn; c->st = st; c->k = k;
      fan_child(&st->fn, cx, &c->h);
    }
    self->pc = 2;
    /* fallthrough */
  case 2:
    if (ren_ld64(&st->fn.left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    return REN_T_DONE;
  }
  wl_fail("t_timer: pc");
}
static void *tm_init(const wl_args *a) { (void)a; return calloc(1, sizeof(tm_st)); }
static ren_task *tm_main(const ren_config *cfg) {
  tm_root *r = (tm_root *)ren_task_new(sizeof *r, tm_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tm_report(void *u, FILE *res, FILE *met, double wall) {
  tm_st *st = u; int ok = !st->fn.failed && st->next == 5;
  (void)met; (void)wall;
  fprintf(res, "result: t_timer order=");
  for (int i = 0; i < 5; i++) fprintf(res, "%lld%s", (long long)st->order[i], i < 4 ? "," : "");
  fputc('\n', res);
  for (int i = 0; ok && i < 5; i++) {
    int k = (int)st->order[i];
    if (i > 0 && tm_ms[k] < tm_ms[st->order[i - 1]]) ok = 0;
    int64_t dl = st->base + tm_ms[k] * 1000000;
    if (st->fin_ns[k] < dl || st->fin_ns[k] > dl + 200000000) ok = 0;
  }
  if (!ok) fprintf(stderr, "t_timer: %s\n", st->fn.failed ? st->fn.why : "order or timing wrong");
  return ok ? 0 : 1;
}
static void free_u(void *u) { free(u); }
const wl_def wl_t_timer = {"t_timer", tm_init, tm_main, tm_report, free_u};

/* ================= T_PIPE ================= */
#define TP_TOTAL (256 * 1024)
typedef struct { fan fn; int64_t rfd, wfd; uint64_t wsum, rsum; int64_t got; } tp_st;
typedef struct { ren_task h; fan *fn; ren_await aw; tp_st *st; int64_t off; uint8_t buf[4096]; } tp_writer;
typedef struct { ren_task h; fan *fn; ren_await aw; tp_st *st; uint8_t buf[1024]; } tp_reader;
typedef struct { ren_task h; tp_st *st; ren_await aw; } tp_root;

static int32_t tp_writer_resume(ren_task *self, ren_ctx *cx) {
  tp_writer *f = (tp_writer *)self;
  switch (self->pc) {
  case 0:
  loop:
    if (f->off >= TP_TOTAL) { fan_done(f->fn, cx); return REN_T_DONE; }
    for (int i = 0; i < 4096; i++) f->buf[i] = (uint8_t)((f->off + i) * 31 + 7);
    EM_ISSUE(1, REN_OP_WRITE, f->st->wfd, f->buf, 4096, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res <= 0) { fan_fail(f->fn, "pipe: write failed"); fan_done(f->fn, cx); return REN_T_DONE; }
    /* a partial write: account only what went */
    f->st->wsum = wl_fnv1a(f->buf, (size_t)f->aw.res.res, f->st->wsum);
    f->off += f->aw.res.res;
    self->pc = 0;
    goto loop;
  }
  wl_fail("t_pipe: pc");
}
static int32_t tp_reader_resume(ren_task *self, ren_ctx *cx) {
  tp_reader *f = (tp_reader *)self;
  switch (self->pc) {
  case 0:
  loop:
    if (f->st->got >= TP_TOTAL) { fan_done(f->fn, cx); return REN_T_DONE; }
    EM_ISSUE(1, REN_OP_READ, f->st->rfd, f->buf, sizeof f->buf, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res <= 0) { fan_fail(f->fn, "pipe: read failed"); fan_done(f->fn, cx); return REN_T_DONE; }
    f->st->rsum = wl_fnv1a(f->buf, (size_t)f->aw.res.res, f->st->rsum);
    f->st->got += f->aw.res.res;
    self->pc = 0;
    goto loop;
  }
  wl_fail("t_pipe: pc");
}
static int32_t tp_root_resume(ren_task *self, ren_ctx *cx) {
  tp_root *f = (tp_root *)self;
  tp_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->fn.root = self;
    EM_ISSUE(1, REN_OP_PIPE, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK()) { fan_fail(&st->fn, "pipe: PIPE failed"); return REN_T_DONE; }
    st->rfd = f->aw.res.a; st->wfd = f->aw.res.b;
    { tp_writer *w = (tp_writer *)ren_task_new(sizeof *w, tp_writer_resume, child_fin);
      w->fn = &st->fn; w->st = st; fan_child(&st->fn, cx, &w->h); }
    { tp_reader *r = (tp_reader *)ren_task_new(sizeof *r, tp_reader_resume, child_fin);
      r->fn = &st->fn; r->st = st; fan_child(&st->fn, cx, &r->h); }
    self->pc = 2;
    /* fallthrough */
  case 2:
    if (ren_ld64(&st->fn.left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    EM_ISSUE(3, REN_OP_CLOSE, st->rfd, NULL, 0, 0);
    /* fallthrough */
  case 3:
    EM_AWAIT();
    EM_ISSUE(4, REN_OP_CLOSE, st->wfd, NULL, 0, 0);
    /* fallthrough */
  case 4:
    EM_AWAIT();
    return REN_T_DONE;
  }
  wl_fail("t_pipe: pc");
}
static void *tp_init(const wl_args *a) {
  (void)a; tp_st *st = calloc(1, sizeof *st); st->wsum = st->rsum = WL_FNV_BASIS; return st;
}
static ren_task *tp_main(const ren_config *cfg) {
  tp_root *r = (tp_root *)ren_task_new(sizeof *r, tp_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tp_report(void *u, FILE *res, FILE *met, double wall) {
  tp_st *st = u; (void)met; (void)wall;
  fprintf(res, "result: t_pipe got=%lld sum=%016llx\n", (long long)st->got, (unsigned long long)st->rsum);
  int ok = !st->fn.failed && st->got == TP_TOTAL && st->rsum == st->wsum;
  if (!ok) fprintf(stderr, "t_pipe: %s\n", st->fn.failed ? st->fn.why : "checksum/length mismatch");
  return ok ? 0 : 1;
}
const wl_def wl_t_pipe = {"t_pipe", tp_init, tp_main, tp_report, free_u};

/* ================= T_TCP ================= */
typedef struct { fan fn; int64_t lfd, port; char got[5]; } tt_st;
typedef struct { ren_task h; fan *fn; ren_await aw; tt_st *st; int64_t cfd; int64_t n; char buf[8]; } tt_task;
typedef struct { ren_task h; tt_st *st; ren_await aw; } tt_root;

static int32_t tt_server_resume(ren_task *self, ren_ctx *cx) {
  tt_task *f = (tt_task *)self;
  switch (self->pc) {
  case 0:
    EM_ISSUE(1, REN_OP_ACCEPT, f->st->lfd, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res < 0) { fan_fail(f->fn, "tcp: accept"); goto out; }
    f->cfd = f->aw.res.res; f->n = 0;
    /* fallthrough */
  case 2:
  rd:
    EM_ISSUE(3, REN_OP_READ, f->cfd, f->buf + f->n, 4 - (uint64_t)f->n, 0);
    /* fallthrough */
  case 3:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res <= 0) { fan_fail(f->fn, "tcp: server read"); goto out; }
    f->n += f->aw.res.res;
    if (f->n < 4) { self->pc = 2; goto rd; }
    if (memcmp(f->buf, "ping", 4) != 0) fan_fail(f->fn, "tcp: server got wrong bytes");
    memcpy(f->buf, "pong", 4);
    EM_ISSUE(4, REN_OP_WRITE, f->cfd, f->buf, 4, 0);
    /* fallthrough */
  case 4:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 4) fan_fail(f->fn, "tcp: server write");
    EM_ISSUE(5, REN_OP_CLOSE, f->cfd, NULL, 0, 0);
    /* fallthrough */
  case 5:
    EM_AWAIT();
  out:
    fan_done(f->fn, cx);
    return REN_T_DONE;
  }
  wl_fail("t_tcp: pc");
}
static int32_t tt_client_resume(ren_task *self, ren_ctx *cx) {
  tt_task *f = (tt_task *)self;
  switch (self->pc) {
  case 0:
    EM_ISSUE(1, REN_OP_CONNECT, -1, NULL, 0, f->st->port);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res < 0) { fan_fail(f->fn, "tcp: connect"); goto out; }
    f->cfd = f->aw.res.res;
    memcpy(f->buf, "ping", 4);
    EM_ISSUE(2, REN_OP_WRITE, f->cfd, f->buf, 4, 0);
    /* fallthrough */
  case 2:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res != 4) { fan_fail(f->fn, "tcp: client write"); goto cl; }
    f->n = 0;
    /* fallthrough */
  case 3:
  rd:
    EM_ISSUE(4, REN_OP_READ, f->cfd, f->buf + f->n, 4 - (uint64_t)f->n, 0);
    /* fallthrough */
  case 4:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res <= 0) { fan_fail(f->fn, "tcp: client read"); goto cl; }
    f->n += f->aw.res.res;
    if (f->n < 4) { self->pc = 3; goto rd; }
    memcpy(f->st->got, f->buf, 4);
  cl:
    EM_ISSUE(5, REN_OP_CLOSE, f->cfd, NULL, 0, 0);
    /* fallthrough */
  case 5:
    EM_AWAIT();
  out:
    fan_done(f->fn, cx);
    return REN_T_DONE;
  }
  wl_fail("t_tcp: pc");
}
static int32_t tt_root_resume(ren_task *self, ren_ctx *cx) {
  tt_root *f = (tt_root *)self;
  tt_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->fn.root = self;
    EM_ISSUE(1, REN_OP_LISTEN, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    if (!EM_OK() || f->aw.res.res < 0) { fan_fail(&st->fn, "tcp: listen"); return REN_T_DONE; }
    st->lfd = f->aw.res.res; st->port = f->aw.res.a;
    { tt_task *s = (tt_task *)ren_task_new(sizeof *s, tt_server_resume, child_fin);
      s->fn = &st->fn; s->st = st; fan_child(&st->fn, cx, &s->h); }
    { tt_task *c = (tt_task *)ren_task_new(sizeof *c, tt_client_resume, child_fin);
      c->fn = &st->fn; c->st = st; fan_child(&st->fn, cx, &c->h); }
    self->pc = 2;
    /* fallthrough */
  case 2:
    if (ren_ld64(&st->fn.left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    EM_ISSUE(3, REN_OP_CLOSE, st->lfd, NULL, 0, 0);
    /* fallthrough */
  case 3:
    EM_AWAIT();
    return REN_T_DONE;
  }
  wl_fail("t_tcp: pc");
}
static void *tt_init(const wl_args *a) { (void)a; return calloc(1, sizeof(tt_st)); }
static ren_task *tt_main(const ren_config *cfg) {
  tt_root *r = (tt_root *)ren_task_new(sizeof *r, tt_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tt_report(void *u, FILE *res, FILE *met, double wall) {
  tt_st *st = u; (void)met; (void)wall;
  fprintf(res, "result: t_tcp got=%s\n", st->got[0] ? st->got : "-");
  int ok = !st->fn.failed && memcmp(st->got, "pong", 4) == 0;
  if (!ok) fprintf(stderr, "t_tcp: %s\n", st->fn.failed ? st->fn.why : "no pong");
  return ok ? 0 : 1;
}
const wl_def wl_t_tcp = {"t_tcp", tt_init, tt_main, tt_report, free_u};

/* ================= T_CANCEL ================= */
/* (a) READ on an empty pipe, cancelled by a peer after 10 ms.
   (b) READ issued and cancelled in the same step (retracted).
   (c) SleepUntil(+10 s) cancelled by a peer after 5 ms. */
typedef struct { fan fn; int64_t rfd, wfd, rfd2, wfd2; uint64_t a_id, c_id; int32_t st_a, st_b, st_c; int64_t c_elapsed; } tc_st;
typedef struct { ren_task h; fan *fn; ren_await aw; tc_st *st; int role; int64_t t0; uint8_t buf[8]; } tc_task;
typedef struct { ren_task h; tc_st *st; ren_await aw; } tc_root;

static int32_t tc_task_resume(ren_task *self, ren_ctx *cx) {
  tc_task *f = (tc_task *)self;
  tc_st *st = f->st;
  switch (f->role) {
  case 0: /* (a) the reader */
    switch (self->pc) {
    case 0:
      EM_ISSUE_THEN(1, REN_OP_READ, st->rfd, f->buf, sizeof f->buf, 0,
                    ren_st64((int64_t *)&st->a_id, (int64_t)f->aw.id, REN_MO_RELEASE));
      /* fallthrough */
    case 1:
      EM_AWAIT();
      st->st_a = wl_aw_state(&f->aw);
      if (st->st_a == REN_CANCELLED && f->aw.res.res != -REN_ECANCELED) fan_fail(f->fn, "cancel(a): res");
      fan_done(f->fn, cx);
      return REN_T_DONE;
    }
    break;
  case 1: /* (a)/(c) the canceller: sleep, then cancel a, then c */
    switch (self->pc) {
    case 0:
      EM_ISSUE(1, REN_OP_MONO_NOW, -1, NULL, 0, 0);
      /* fallthrough */
    case 1:
      EM_AWAIT();
      f->t0 = f->aw.res.res;
      /* fallthrough */
    case 2:
    again5:
      EM_ISSUE(3, REN_OP_SLEEP_UNTIL, -1, NULL, 0, f->t0 + 5000000);
      /* fallthrough */
    case 3:
      EM_AWAIT();
      if (ren_ld64((int64_t *)&st->c_id, REN_MO_ACQUIRE) == 0) { f->t0 += 1000000; self->pc = 2; goto again5; }
      ren_cancel(cx, (uint64_t)ren_ld64((int64_t *)&st->c_id, REN_MO_ACQUIRE));
      /* fallthrough */
    case 4:
    again10:
      EM_ISSUE(5, REN_OP_SLEEP_UNTIL, -1, NULL, 0, f->t0 + 10000000);
      /* fallthrough */
    case 5:
      EM_AWAIT();
      if (ren_ld64((int64_t *)&st->a_id, REN_MO_ACQUIRE) == 0) { f->t0 += 1000000; self->pc = 4; goto again10; }
      ren_cancel(cx, (uint64_t)ren_ld64((int64_t *)&st->a_id, REN_MO_ACQUIRE));
      fan_done(f->fn, cx);
      return REN_T_DONE;
    }
    break;
  case 2: /* (b) issue and cancel in the same step */
    switch (self->pc) {
    case 0:
      EM_ISSUE_THEN(1, REN_OP_READ, st->rfd2, f->buf, sizeof f->buf, 0, ren_cancel(cx, f->aw.id));
      /* fallthrough */
    case 1:
      EM_AWAIT();
      st->st_b = wl_aw_state(&f->aw);
      fan_done(f->fn, cx);
      return REN_T_DONE;
    }
    break;
  case 3: /* (c) the long sleeper */
    switch (self->pc) {
    case 0:
      EM_ISSUE(1, REN_OP_MONO_NOW, -1, NULL, 0, 0);
      /* fallthrough */
    case 1:
      EM_AWAIT();
      f->t0 = f->aw.res.res;
      EM_ISSUE_THEN(2, REN_OP_SLEEP_UNTIL, -1, NULL, 0, f->t0 + 10000000000ll,
                    ren_st64((int64_t *)&st->c_id, (int64_t)f->aw.id, REN_MO_RELEASE));
      /* fallthrough */
    case 2:
      EM_AWAIT();
      st->st_c = wl_aw_state(&f->aw);
      EM_ISSUE(3, REN_OP_MONO_NOW, -1, NULL, 0, 0);
      /* fallthrough */
    case 3:
      EM_AWAIT();
      st->c_elapsed = f->aw.res.res - f->t0;
      fan_done(f->fn, cx);
      return REN_T_DONE;
    }
    break;
  }
  wl_fail("t_cancel: pc");
}
static int32_t tc_root_resume(ren_task *self, ren_ctx *cx) {
  tc_root *f = (tc_root *)self;
  tc_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->fn.root = self;
    EM_ISSUE(1, REN_OP_PIPE, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    EM_AWAIT();
    st->rfd = f->aw.res.a; st->wfd = f->aw.res.b;
    EM_ISSUE(2, REN_OP_PIPE, -1, NULL, 0, 0);
    /* fallthrough */
  case 2:
    EM_AWAIT();
    st->rfd2 = f->aw.res.a; st->wfd2 = f->aw.res.b;
    for (int role = 0; role < 4; role++) {
      tc_task *t = (tc_task *)ren_task_new(sizeof *t, tc_task_resume, child_fin);
      t->fn = &st->fn; t->st = st; t->role = role;
      fan_child(&st->fn, cx, &t->h);
    }
    self->pc = 3;
    /* fallthrough */
  case 3:
    if (ren_ld64(&st->fn.left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    EM_ISSUE(4, REN_OP_CLOSE, st->rfd, NULL, 0, 0);
    /* fallthrough */
  case 4: EM_AWAIT(); EM_ISSUE(5, REN_OP_CLOSE, st->wfd, NULL, 0, 0);
    /* fallthrough */
  case 5: EM_AWAIT(); EM_ISSUE(6, REN_OP_CLOSE, st->rfd2, NULL, 0, 0);
    /* fallthrough */
  case 6: EM_AWAIT(); EM_ISSUE(7, REN_OP_CLOSE, st->wfd2, NULL, 0, 0);
    /* fallthrough */
  case 7: EM_AWAIT(); return REN_T_DONE;
  }
  wl_fail("t_cancel: pc");
}
static void *tc_init(const wl_args *a) { (void)a; return calloc(1, sizeof(tc_st)); }
static ren_task *tc_main(const ren_config *cfg) {
  tc_root *r = (tc_root *)ren_task_new(sizeof *r, tc_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tc_report(void *u, FILE *res, FILE *met, double wall) {
  tc_st *st = u; (void)met; (void)wall;
  fprintf(res, "result: t_cancel a=%d b=%d c=%d\n", st->st_a, st->st_b, st->st_c);
  int ok = !st->fn.failed && st->st_a == REN_CANCELLED && st->st_b == REN_CANCELLED &&
           st->st_c == REN_CANCELLED && st->c_elapsed < 1000000000ll;
  if (!ok) fprintf(stderr, "t_cancel: %s (c_elapsed=%lld ns)\n", st->fn.failed ? st->fn.why : "a state was not CANCELLED",
                   (long long)st->c_elapsed);
  return ok ? 0 : 1;
}
const wl_def wl_t_cancel = {"t_cancel", tc_init, tc_main, tc_report, free_u};

/* ================= T_BLOCK (T_STOP / T_KILL) ================= */
/* Three readers on three empty pipes and one SleepUntil(+10 s); the host
   stops or kills the core at 50 ms. */
typedef struct { fan fn; int64_t fds[6]; int32_t states[4]; int64_t ncancel; } tb_st;
typedef struct { ren_task h; fan *fn; ren_await aw; tb_st *st; int k; uint8_t buf[8]; } tb_task;
typedef struct { ren_task h; tb_st *st; ren_await aw; int i; } tb_root;

static int32_t tb_task_resume(ren_task *self, ren_ctx *cx) {
  tb_task *f = (tb_task *)self;
  switch (self->pc) {
  case 0:
    if (f->k < 3) EM_ISSUE(2, REN_OP_READ, f->st->fds[2 * f->k], f->buf, sizeof f->buf, 0);
    else EM_ISSUE(1, REN_OP_MONO_NOW, -1, NULL, 0, 0);
    /* fallthrough */
  case 1:
    if (self->pc == 1) {
      EM_AWAIT();
      EM_ISSUE(2, REN_OP_SLEEP_UNTIL, -1, NULL, 0, f->aw.res.res + 10000000000ll);
    }
    /* fallthrough */
  case 2:
    EM_AWAIT();
    f->st->states[f->k] = wl_aw_state(&f->aw);
    if (f->st->states[f->k] == REN_CANCELLED) ren_xadd64(&f->st->ncancel, 1, REN_MO_RELAXED);
    fan_done(f->fn, cx);
    return REN_T_DONE;
  }
  wl_fail("t_block: pc");
}
static int32_t tb_root_resume(ren_task *self, ren_ctx *cx) {
  tb_root *f = (tb_root *)self;
  tb_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->fn.root = self; f->i = 0;
    /* fallthrough */
  case 1:
  pipes:
    if (f->i < 3) { EM_ISSUE(2, REN_OP_PIPE, -1, NULL, 0, 0); }
    else goto spawn;
    /* fallthrough */
  case 2:
    EM_AWAIT();
    st->fds[2 * f->i] = f->aw.res.a; st->fds[2 * f->i + 1] = f->aw.res.b;
    f->i++; self->pc = 1;
    goto pipes;
  spawn:
    for (int k = 0; k < 4; k++) {
      tb_task *t = (tb_task *)ren_task_new(sizeof *t, tb_task_resume, child_fin);
      t->fn = &st->fn; t->st = st; t->k = k;
      fan_child(&st->fn, cx, &t->h);
    }
    self->pc = 3; f->i = 0;
    /* fallthrough */
  case 3:
    if (ren_ld64(&st->fn.left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    /* close the six fds (after a stop, the closes complete Cancelled
       without reaching the driver, so the fds leak in this test; it exits) */
    /* fallthrough */
  case 4:
  closes:
    if (f->i == 6) return REN_T_DONE;
    EM_ISSUE(5, REN_OP_CLOSE, st->fds[f->i], NULL, 0, 0);
    /* fallthrough */
  case 5:
    EM_AWAIT();
    f->i++; self->pc = 4;
    goto closes;
  }
  wl_fail("t_block: pc");
}
static void *tb_init(const wl_args *a) { (void)a; return calloc(1, sizeof(tb_st)); }
static ren_task *tb_main(const ren_config *cfg) {
  tb_root *r = (tb_root *)ren_task_new(sizeof *r, tb_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int tb_report(void *u, FILE *res, FILE *met, double wall) {
  tb_st *st = u; (void)met;
  fprintf(res, "result: t_block cancelled=%lld\n", (long long)st->ncancel);
  /* stop: all four cancelled, finished well within 1 s; kill: the host checks */
  return (st->ncancel == 4 && wall < 1.0) ? 0 : 1;
}
const wl_def wl_t_block = {"t_block", tb_init, tb_main, tb_report, free_u};
