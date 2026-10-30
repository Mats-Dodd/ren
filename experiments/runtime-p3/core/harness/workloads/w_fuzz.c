/* w_fuzz.c: the workload the fuzz driver (SPEC §D.4) runs. 6 tasks,
   8 world calls each (READ / SLEEP_UNTIL / WRITE in turn); every third
   task cancels its right-hand sibling's pending call. Every reply is
   checked; a failure aborts, which the fuzzer counts as a crash. No OS
   call is ever made: the fuzz driver answers everything. */
#include "emit.h"
#include <stdlib.h>
#include <string.h>

#define FZ_TASKS 6
#define FZ_CALLS 8
#define REN_FUZZ_STALE_MAGIC 0x5A1E5A1Ell

typedef struct { int64_t left; ren_task *root; int64_t pend[FZ_TASKS]; int64_t replies; } fz_st;
typedef struct { ren_task h; fz_st *st; ren_await aw; int k; int i; uint8_t buf[16]; } fz_task;
typedef struct { ren_task h; fz_st *st; } fz_root;

static void fz_fin(ren_task *t) { ren_rc_drop(&((fz_task *)t)->st->root->obj); }

static void fz_check(fz_task *f) {
  int32_t s = wl_aw_state(&f->aw);
  ren_io_result *r = &f->aw.res;
  if (s != REN_DONE && s != REN_CANCELLED) wl_fail("fuzz: reply state");
  if (r->res == REN_FUZZ_STALE_MAGIC) wl_fail("fuzz: a stale reply was delivered (generation check)");
  if (s == REN_CANCELLED && r->res != -REN_ECANCELED) wl_fail("fuzz: CANCELLED without -ECANCELED");
  if (s == REN_DONE && f->aw.op == REN_OP_READ) {
    if (r->res < 0 || r->res > (int64_t)sizeof f->buf) wl_fail("fuzz: READ result out of range");
    for (int64_t j = 0; j < r->res; j++)
      if (f->buf[j] != (uint8_t)((f->aw.id + (uint64_t)j) & 0xff)) wl_fail("fuzz: READ bytes are not this call's");
  }
}

static int32_t fz_task_resume(ren_task *self, ren_ctx *cx) {
  fz_task *f = (fz_task *)self;
  fz_st *st = f->st;
  switch (self->pc) {
  case 0:
  next:
    if (f->i == FZ_CALLS || ren_cancelled(cx)) goto out;
    if (f->k % 3 == 0) {
      int64_t victim = ren_ld64(&st->pend[(f->k + 1) % FZ_TASKS], REN_MO_ACQUIRE);
      if (victim) ren_cancel(cx, (uint64_t)victim);
    }
    memset(f->buf, 0xEE, sizeof f->buf);
    {
      uint32_t op = (f->i % 3 == 0) ? REN_OP_READ : (f->i % 3 == 1) ? REN_OP_SLEEP_UNTIL : REN_OP_WRITE;
      EM_ISSUE_THEN(1, op, 100 + f->k, f->buf, op == REN_OP_SLEEP_UNTIL ? 0 : sizeof f->buf, f->i,
                    ren_st64(&st->pend[f->k], (int64_t)f->aw.id, REN_MO_RELEASE));
    }
    /* fallthrough */
  case 1:
    EM_AWAIT();
    ren_st64(&st->pend[f->k], 0, REN_MO_RELEASE);
    fz_check(f);
    ren_xadd64(&st->replies, 1, REN_MO_RELAXED);
    f->i++;
    self->pc = 0;
    if (ren_tick(cx)) return REN_T_YIELD;
    goto next;
  out:
    if (ren_xadd64(&st->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, st->root);
    return REN_T_DONE;
  }
  wl_fail("w_fuzz: pc");
}
static int32_t fz_root_resume(ren_task *self, ren_ctx *cx) {
  fz_root *f = (fz_root *)self;
  fz_st *st = f->st;
  switch (self->pc) {
  case 0:
    st->root = self;
    ren_st64(&st->left, FZ_TASKS, REN_MO_RELAXED);
    for (int k = 0; k < FZ_TASKS; k++) {
      fz_task *t = (fz_task *)ren_task_new(sizeof *t, fz_task_resume, fz_fin);
      t->st = st; t->k = k;
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &t->h);
    }
    self->pc = 1;
    /* fallthrough */
  case 1:
    if (ren_ld64(&st->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
    return REN_T_DONE;
  }
  wl_fail("w_fuzz: pc");
}
static void *fz_init(const wl_args *a) { (void)a; return calloc(1, sizeof(fz_st)); }
static ren_task *fz_main(const ren_config *cfg) {
  fz_root *r = (fz_root *)ren_task_new(sizeof *r, fz_root_resume, NULL);
  r->st = cfg->user;
  return &r->h;
}
static int fz_report(void *u, FILE *res, FILE *met, double wall) {
  fz_st *st = u; (void)met; (void)wall;
  fprintf(res, "result: w_fuzz replies=%lld left=%lld\n", (long long)st->replies, (long long)st->left);
  return st->left == 0 ? 0 : 1;
}
static void fz_free(void *u) { free(u); }
const wl_def wl_w_fuzz = {"w_fuzz", fz_init, fz_main, fz_report, fz_free};
