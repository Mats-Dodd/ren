/* abi_test.c: conformance of a core to SPEC §B, driven by hand through
   the nine-function ABI on one thread (the test is the driver). The same
   binary links against any language's core library.

   abi_test [test ...]     (no argument: all)
   Exit 0 = every selected test passed; a test that cannot run on this
   core (e.g. two workers on the stub) reports SKIP. */
#include "../slice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
static int g_fail, g_skip;
#define CHECK(c)                                                                   \
  do {                                                                             \
    if (!(c)) {                                                                    \
      fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);               \
      g_fail = 1;                                                                  \
      return;                                                                      \
    }                                                                              \
  } while (0)

/* the test host */
typedef struct {
  int wakes[8];
  int answer_mono;
  uint8_t *j; size_t jlen, jcap;
} thost;
static void th_wake(void *h, int32_t w) { ((thost *)h)->wakes[w]++; }
static bool th_answer(void *h, int32_t w, const ren_call *c, ren_reply_t *out) {
  static ren_io_result r;
  (void)w;
  if (!((thost *)h)->answer_mono || c->op != REN_OP_MONO_NOW) return false;
  r.res = 123456789; r.a = r.b = 0;
  out->id = c->id; out->state = REN_DONE; out->len = sizeof r; out->body = &r;
  return true;
}
static void th_journal(void *h, int32_t w, const void *e, size_t n) {
  thost *t = h; (void)w;
  if (t->jlen + n > t->jcap) { t->jcap = (t->jlen + n) * 2; t->j = realloc(t->j, t->jcap); }
  memcpy(t->j + t->jlen, e, n); t->jlen += n;
}
static const ren_host th_vt = {th_wake, th_answer, NULL, th_journal};

/* journal helpers */
static size_t j_kinds(thost *t, uint32_t *out, size_t max) {
  size_t n = 0, pos = 0;
  while (pos + 24 <= t->jlen && n < max) {
    uint32_t k, len; memcpy(&k, t->j + pos, 4); memcpy(&len, t->j + pos + 4, 4);
    out[n++] = k; pos += 24 + len;
  }
  return n;
}
static int j_find_cancel(thost *t, uint64_t id, uint32_t *how) {
  size_t pos = 0;
  while (pos + 24 <= t->jlen) {
    uint32_t k, len; memcpy(&k, t->j + pos, 4); memcpy(&len, t->j + pos + 4, 4);
    if (k == REN_J_CANCEL) {
      uint64_t i; memcpy(&i, t->j + pos + 24, 8);
      if (i == id) { memcpy(how, t->j + pos + 32, 4); return 1; }
    }
    pos += 24 + len;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* Test state shared with the frames. */
#define MAXT 16
typedef struct {
  ren_task *root;
  int64_t left;
  uint64_t id[MAXT];         /* published call ids */
  int32_t state[MAXT][4];    /* reply states seen, per task and call */
  int64_t res[MAXT][4];
  int calls_done[MAXT];
  int64_t count[MAXT];
  int nspawn;
  uint32_t op;               /* the op callers issue */
  int ncalls;                /* calls per caller */
  int cancel_own;            /* callers cancel their own call in the same step */
} tst;

/* a caller: issues [ncalls] calls one after another, records each reply */
typedef struct { ren_task h; tst *s; ren_await aw; int k; int i; uint8_t buf[8]; } caller;
static void caller_fin(ren_task *t) { tst *s = ((caller *)t)->s; if (s->root && t != s->root) ren_rc_drop(&s->root->obj); }
static int32_t caller_resume(ren_task *self, ren_ctx *cx) {
  caller *f = (caller *)self;
  tst *s = f->s;
  for (;;) {
    if (self->pc == 0) {
      if (f->i == s->ncalls) break;
      ren_io_body b = {.fd = 7, .len = sizeof f->buf, .buf = (uint64_t)(uintptr_t)f->buf, .arg = 0};
      int32_t r = ren_world(cx, self, &f->aw, s->op, &b);
      if (r == REN_W_FULL) return REN_T_YIELD;
      s->id[f->k] = f->aw.id;
      self->pc = 1;
      if (s->cancel_own) ren_cancel(cx, f->aw.id);
      if (r == REN_W_PENDING) return REN_T_PARK;
    }
    int32_t st = ren_ld32(&f->aw.state, REN_MO_ACQUIRE);
    if (st == 0) return REN_T_PARK;
    s->state[f->k][f->i] = st;
    s->res[f->k][f->i] = f->aw.res.res;
    f->i++;
    s->calls_done[f->k] = f->i;
    self->pc = 0;
  }
  if (self != s->root && ren_xadd64(&s->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, s->root);
  return REN_T_DONE;
}
static caller *new_caller(tst *s, int k) {
  caller *c = (caller *)ren_task_new(sizeof *c, caller_resume, caller_fin);
  c->s = s; c->k = k;
  return c;
}

/* a parent: spawns [nspawn] callers (k = 1..n) and waits for them */
typedef struct { ren_task h; tst *s; } parent;
static int32_t parent_resume(ren_task *self, ren_ctx *cx) {
  parent *f = (parent *)self;
  tst *s = f->s;
  if (self->pc == 0) {
    s->root = self;
    ren_st64(&s->left, s->nspawn, REN_MO_RELAXED);
    for (int k = 1; k <= s->nspawn; k++) {
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &new_caller(s, k)->h);
    }
    self->pc = 1;
  }
  if (ren_ld64(&s->left, REN_MO_ACQUIRE) != 0) return REN_T_PARK;
  return REN_T_DONE;
}

static ren_task *main_caller(const ren_config *cfg) { tst *s = cfg->user; caller *c = new_caller(s, 0); s->root = &c->h; return &c->h; }
static ren_task *main_parent(const ren_config *cfg) {
  parent *p = (parent *)ren_task_new(sizeof *p, parent_resume, NULL);
  p->s = cfg->user;
  return &p->h;
}

static ren_core *start(thost *h, tst *s, ren_main_fn m, int workers, uint32_t slots, uint32_t B) {
  ren_config cfg;
  memset(&cfg, 0, sizeof cfg);
  cfg.workers = workers; cfg.op_slots = slots; cfg.budget_b = B;
  cfg.build_id = "abi_test"; cfg.journal_policy = REN_JPOL_INPUTS_INLINE | REN_JPOL_OUTPUTS_HASH;
  cfg.user = s;
  ren_core *c = ren_start(&cfg, m, &th_vt, h);
  if (c) for (int w = 0; w < workers; w++) ren_thread_init(c, w, NULL, 0);
  return c;
}
static int32_t reply(ren_core *c, uint64_t id, uint32_t state, int64_t res) {
  ren_io_result r = {.res = res, .a = 0, .b = 0};
  ren_reply_t rp = {.id = id, .state = state, .len = sizeof r, .body = &r};
  return ren_reply(c, &rp);
}
static int run_to_end(ren_core *c, int workers) {
  for (int round = 0; round < 1000; round++) {
    int fin = 0;
    for (int w = 0; w < workers; w++) {
      ren_call k;
      int r = ren_run(c, w, 64);
      while (ren_poll_call(c, w, &k)) {}
      if (r == REN_FINISHED) fin++;
    }
    if (fin == workers) return 1;
  }
  return 0;
}

/* ------------------------------------------------------------------ */
static void t_basic(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 1;
  ren_core *c = start(&h, &s, main_caller, 1, 0, 0);
  CHECK(c);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);
  ren_call k;
  CHECK(ren_poll_call(c, 0, &k));
  CHECK(k.kind == REN_CALL && k.op == REN_OP_READ && k.worker == 0 && k.id != 0);
  CHECK(k.id == s.id[0] && k.task == 1 && k.len == sizeof(ren_io_body));
  CHECK(((const ren_io_body *)k.body)->fd == 7);
  CHECK(!ren_poll_call(c, 0, &k));
  CHECK(h.wakes[0] == 0);
  CHECK(reply(c, s.id[0], REN_DONE, 5) == REN_ACCEPTED);
  CHECK(h.wakes[0] == 1);                       /* every reply leads to a tick; parked → one wake */
  CHECK(reply(c, s.id[0], REN_DONE, 6) == REN_RELEASE);   /* a duplicate */
  CHECK(h.wakes[0] == 1);                       /* wake only for a parked worker, once */
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  CHECK(s.state[0][0] == REN_DONE && s.res[0][0] == 5);
  CHECK(reply(c, s.id[0], REN_DONE, 7) == REN_RELEASE);   /* after delivery: stale */
  CHECK(reply(c, 0, REN_DONE, 7) == REN_RELEASE);          /* id 0 is never valid */
  CHECK(reply(c, ~0ull, REN_DONE, 7) == REN_RELEASE);      /* slot out of range */
  uint32_t kinds[16]; size_t nk = j_kinds(&h, kinds, 16);
  /* HEADER, CALL, RELEASE(dup), DELIVER, END, RELEASE, RELEASE, RELEASE */
  CHECK(nk == 8 && kinds[0] == REN_J_HEADER && kinds[1] == REN_J_CALL && kinds[2] == REN_J_RELEASE &&
        kinds[3] == REN_J_DELIVER && kinds[4] == REN_J_END && kinds[5] == REN_J_RELEASE);
  ren_free(c); free(h.j);
}

/* P3: a stale reply after the slot was reused must be released. */
static void t_stale(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 2;
  ren_core *c = start(&h, &s, main_caller, 1, 0, 0);
  CHECK(c);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);
  ren_call k;
  CHECK(ren_poll_call(c, 0, &k));
  uint64_t a = k.id;
  CHECK(!ren_poll_call(c, 0, &k));
  CHECK(reply(c, a, REN_DONE, 1) == REN_ACCEPTED);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);          /* delivered; the second call issued */
  CHECK(ren_poll_call(c, 0, &k));
  uint64_t b = k.id;
  CHECK((b >> 32) == (a >> 32));                 /* the same slot (LIFO free stack) */
  CHECK((uint32_t)b == (uint32_t)a + 1);         /* the next generation */
  CHECK(reply(c, a, REN_DONE, 0x5A1E5A1E) == REN_RELEASE);  /* stale: must not reach b's waiter */
  CHECK(reply(c, b, REN_DONE, 2) == REN_ACCEPTED);
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  CHECK(s.res[0][0] == 1 && s.res[0][1] == 2);
  ren_free(c); free(h.j);
}

/* P4: cancel sent, then the call completes anyway: the real result is
   delivered (§2.2) and the op record freed exactly once. */
typedef struct { ren_task h; tst *s; ren_await aw; } cancel_after_sleep;
static int32_t cas_resume(ren_task *self, ren_ctx *cx) {
  cancel_after_sleep *f = (cancel_after_sleep *)self;
  if (self->pc == 0) {
    ren_io_body b = {.fd = -1, .len = 0, .buf = 0, .arg = 0};
    if (ren_world(cx, self, &f->aw, REN_OP_SLEEP_UNTIL, &b) == REN_W_FULL) return REN_T_YIELD;
    self->pc = 1;
    return REN_T_PARK;
  }
  if (ren_ld32(&f->aw.state, REN_MO_ACQUIRE) == 0) return REN_T_PARK;
  ren_cancel(cx, f->s->id[0]);
  return REN_T_DONE;
}
typedef struct { ren_task h; tst *s; ren_await aw; uint8_t buf[8]; } race_root;
static int32_t race_root_resume(ren_task *self, ren_ctx *cx) {
  race_root *f = (race_root *)self;
  if (self->pc == 0) {
    ren_io_body b = {.fd = 7, .len = 8, .buf = (uint64_t)(uintptr_t)f->buf, .arg = 0};
    if (ren_world(cx, self, &f->aw, REN_OP_READ, &b) == REN_W_FULL) return REN_T_YIELD;
    f->s->id[0] = f->aw.id;
    cancel_after_sleep *k = (cancel_after_sleep *)ren_task_new(sizeof *k, cas_resume, NULL);
    k->s = f->s;
    ren_spawn(cx, &k->h);
    self->pc = 1;
    return REN_T_PARK;
  }
  if (ren_ld32(&f->aw.state, REN_MO_ACQUIRE) == 0) return REN_T_PARK;
  f->s->state[0][0] = ren_ld32(&f->aw.state, REN_MO_ACQUIRE);
  f->s->res[0][0] = f->aw.res.res;
  return REN_T_DONE;
}
static ren_task *main_race(const ren_config *cfg) {
  race_root *r = (race_root *)ren_task_new(sizeof *r, race_root_resume, NULL);
  r->s = cfg->user;
  return &r->h;
}
static void race(uint32_t final_state, int64_t final_res) {
  thost h = {0}; tst s = {0};
  ren_core *c = start(&h, &s, main_race, 1, 0, 0);
  CHECK(c);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);
  ren_call k1, k2, k;
  CHECK(ren_poll_call(c, 0, &k1) && k1.op == REN_OP_READ);
  CHECK(ren_poll_call(c, 0, &k2) && k2.op == REN_OP_SLEEP_UNTIL);
  CHECK(!ren_poll_call(c, 0, &k));
  CHECK(reply(c, k2.id, REN_DONE, 0) == REN_ACCEPTED);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);          /* the canceller ran */
  CHECK(ren_poll_call(c, 0, &k));
  CHECK(k.kind == REN_CANCEL && k.id == k1.id && k.worker == 0);
  CHECK(!ren_poll_call(c, 0, &k));
  uint32_t how = 99;
  CHECK(j_find_cancel(&h, k1.id, &how) && how == REN_JC_SENT);
  CHECK(reply(c, k1.id, final_state, final_res) == REN_ACCEPTED);
  CHECK(reply(c, k1.id, REN_CANCELLED, -125) == REN_RELEASE);
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  CHECK(s.state[0][0] == (int32_t)final_state && s.res[0][0] == final_res);
  ren_free(c); free(h.j);
}
static void t_cancel_race(void) { race(REN_DONE, 3); }
static void t_cancel_sent(void) { race(REN_CANCELLED, -125); }

/* A cancel before the driver pulled: retracted in the core, no round trip. */
static void t_retract(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 1; s.cancel_own = 1;
  ren_core *c = start(&h, &s, main_caller, 1, 0, 0);
  CHECK(c);
  ren_run(c, 0, 16);
  ren_call k;
  CHECK(!ren_poll_call(c, 0, &k));               /* nothing reaches the driver */
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  CHECK(s.state[0][0] == REN_CANCELLED && s.res[0][0] == -125);
  uint32_t how = 99;
  CHECK(j_find_cancel(&h, s.id[0], &how) && how == REN_JC_RETRACT);
  CHECK(reply(c, s.id[0], REN_DONE, 1) == REN_RELEASE);
  ren_free(c); free(h.j);
}

/* answer_now goes through the journal like any reply. */
static void t_answer_now(void) {
  thost h = {0}; h.answer_mono = 1; tst s = {0}; s.op = REN_OP_MONO_NOW; s.ncalls = 3;
  ren_core *c = start(&h, &s, main_caller, 1, 0, 0);
  CHECK(c);
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  ren_call k;
  CHECK(!ren_poll_call(c, 0, &k));
  CHECK(s.calls_done[0] == 3 && s.state[0][2] == REN_DONE && s.res[0][2] == 123456789);
  uint32_t kinds[16]; size_t nk = j_kinds(&h, kinds, 16);
  CHECK(nk == 8 && kinds[1] == REN_J_CALL && kinds[2] == REN_J_DELIVER && kinds[7] == REN_J_END);
  ren_free(c); free(h.j);
}

/* ren_stop: every pulled call gets a REN_CANCEL; new calls complete Cancelled. */
static void t_stop(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 2; s.nspawn = 3;
  ren_core *c = start(&h, &s, main_parent, 1, 0, 0);
  CHECK(c);
  CHECK(ren_run(c, 0, 16) == REN_IDLE);
  ren_call k, got[3];
  for (int i = 0; i < 3; i++) CHECK(ren_poll_call(c, 0, &got[i]) && got[i].kind == REN_CALL);
  CHECK(!ren_poll_call(c, 0, &k));
  int before = h.wakes[0];
  ren_stop(c);
  CHECK(h.wakes[0] == before + 1);               /* wake_all woke the parked worker */
  for (int i = 0; i < 3; i++) { CHECK(ren_poll_call(c, 0, &k) && k.kind == REN_CANCEL && k.id == got[i].id); }
  CHECK(!ren_poll_call(c, 0, &k));
  for (int i = 0; i < 3; i++) CHECK(reply(c, got[i].id, REN_CANCELLED, -125) == REN_ACCEPTED);
  CHECK(ren_run(c, 0, 64) == REN_FINISHED);
  for (int t = 1; t <= 3; t++) {
    CHECK(s.calls_done[t] == 2);
    CHECK(s.state[t][0] == REN_CANCELLED && s.state[t][1] == REN_CANCELLED);   /* the 2nd never left the core */
  }
  ren_free(c); free(h.j);
}

/* ren_kill: FINISHED at once, late replies released, ren_free cleans up. */
static void t_kill(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 1;
  ren_core *c = start(&h, &s, main_caller, 1, 0, 0);
  CHECK(c);
  ren_run(c, 0, 16);
  ren_call k;
  CHECK(ren_poll_call(c, 0, &k));
  ren_kill(c);
  CHECK(ren_run(c, 0, 16) == REN_FINISHED);
  CHECK(reply(c, k.id, REN_DONE, 1) == REN_RELEASE);
  CHECK(!ren_poll_call(c, 0, &k));
  ren_free(c); free(h.j);
}

/* The counted budget and the step count. */
typedef struct { ren_task h; tst *s; int k; } spinner;
static void spin_fin(ren_task *t) { ren_rc_drop(&((spinner *)t)->s->root->obj); }
static int32_t spin_resume(ren_task *self, ren_ctx *cx) {
  spinner *f = (spinner *)self;
  for (;;) {
    if (++f->s->count[f->k] == 1000) {
      if (ren_xadd64(&f->s->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, f->s->root);
      return REN_T_DONE;
    }
    if (ren_tick(cx)) return REN_T_YIELD;
  }
}
typedef struct { ren_task h; tst *s; } spin_root;
static int32_t spin_root_resume(ren_task *self, ren_ctx *cx) {
  spin_root *f = (spin_root *)self;
  if (self->pc == 0) {
    f->s->root = self;
    ren_st64(&f->s->left, 2, REN_MO_RELAXED);
    for (int k = 0; k < 2; k++) {
      spinner *sp = (spinner *)ren_task_new(sizeof *sp, spin_resume, spin_fin);
      sp->s = f->s; sp->k = k;
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &sp->h);
    }
    self->pc = 1;
  }
  return ren_ld64(&f->s->left, REN_MO_ACQUIRE) ? REN_T_PARK : REN_T_DONE;
}
static ren_task *main_spin(const ren_config *cfg) {
  spin_root *r = (spin_root *)ren_task_new(sizeof *r, spin_root_resume, NULL);
  r->s = cfg->user;
  return &r->h;
}
static void t_budget(void) {
  thost h = {0}; tst s = {0};
  ren_core *c = start(&h, &s, main_spin, 1, 0, 10);
  CHECK(c);
  CHECK(ren_run(c, 0, 1) == REN_RUNNING);
  CHECK(ren_progress(c, 0) == 1);
  CHECK(ren_run(c, 0, 3) == REN_RUNNING);
  CHECK(ren_progress(c, 0) == 4);
  CHECK(s.count[0] + s.count[1] == 30);          /* 3 resumes of 10 ticks each */
  int r;
  while ((r = ren_run(c, 0, 50)) == REN_RUNNING) {}
  CHECK(r == REN_FINISHED);
  CHECK(ren_progress(c, 0) == 202);              /* 1 + 2 x 100 + 1 */
  ren_free(c); free(h.j);
}

/* Op slots run out: REN_W_FULL, then the call goes once a slot frees. */
static void t_full(void) {
  thost h = {0}; tst s = {0}; s.op = REN_OP_READ; s.ncalls = 1; s.nspawn = 3;
  ren_core *c = start(&h, &s, main_parent, 1, 2, 0);
  CHECK(c);
  ren_run(c, 0, 16);
  ren_call k1, k2, k;
  CHECK(ren_poll_call(c, 0, &k1) && ren_poll_call(c, 0, &k2));
  CHECK(!ren_poll_call(c, 0, &k));
  CHECK(reply(c, k1.id, REN_DONE, 1) == REN_ACCEPTED);
  ren_run(c, 0, 16);
  CHECK(ren_poll_call(c, 0, &k) && k.kind == REN_CALL);
  CHECK(reply(c, k2.id, REN_DONE, 1) == REN_ACCEPTED);
  CHECK(reply(c, k.id, REN_DONE, 1) == REN_ACCEPTED);
  CHECK(run_to_end(c, 1));
  ren_free(c); free(h.j);
}

/* Two workers on one thread: worker 1 steals what worker 0 spawned. */
typedef struct { ren_task h; tst *s; } leaf;
static void leaf_fin(ren_task *t) { ren_rc_drop(&((leaf *)t)->s->root->obj); }
static int32_t leaf_resume(ren_task *self, ren_ctx *cx) {
  leaf *f = (leaf *)self;
  ren_xadd64(&f->s->count[ren_ctx_worker(cx)], 1, REN_MO_RELAXED);
  if (ren_xadd64(&f->s->left, -1, REN_MO_ACQ_REL) == 1) ren_notify(cx, f->s->root);
  return REN_T_DONE;
}
typedef struct { ren_task h; tst *s; } fan_root;
static int32_t fan_root_resume(ren_task *self, ren_ctx *cx) {
  fan_root *f = (fan_root *)self;
  if (self->pc == 0) {
    f->s->root = self;
    ren_st64(&f->s->left, 64, REN_MO_RELAXED);
    for (int i = 0; i < 64; i++) {
      leaf *l = (leaf *)ren_task_new(sizeof *l, leaf_resume, leaf_fin);
      l->s = f->s;
      ren_rc_dup(&self->obj);
      ren_spawn(cx, &l->h);
    }
    self->pc = 1;
  }
  return ren_ld64(&f->s->left, REN_MO_ACQUIRE) ? REN_T_PARK : REN_T_DONE;
}
static ren_task *main_fan(const ren_config *cfg) {
  fan_root *r = (fan_root *)ren_task_new(sizeof *r, fan_root_resume, NULL);
  r->s = cfg->user;
  return &r->h;
}
static void t_steal(void) {
  thost h = {0}; tst s = {0};
  ren_core *c = start(&h, &s, main_fan, 2, 0, 1000);
  if (!c) { g_skip = 1; return; }   /* a one-worker core (the stub) */
  CHECK(ren_run(c, 0, 1) == REN_RUNNING);
  CHECK(ren_progress(c, 0) == 1);
  CHECK(ren_run(c, 1, 8) == REN_RUNNING);
  CHECK(ren_progress(c, 1) == 8 && s.count[1] == 8);
  CHECK(run_to_end(c, 2));
  CHECK(s.count[0] + s.count[1] == 64);
  ren_free(c); free(h.j);
}

/* The journal is a deterministic function of the driver's actions. */
static void t_determinism(void) {
  thost h1 = {0}, h2 = {0};
  for (int pass = 0; pass < 2; pass++) {
    thost *h = pass ? &h2 : &h1;
    tst s = {0};
    ren_core *c = start(h, &s, main_race, 1, 0, 0);
    CHECK(c);
    ren_run(c, 0, 16);
    ren_call k1, k2, k;
    CHECK(ren_poll_call(c, 0, &k1) && ren_poll_call(c, 0, &k2));
    while (ren_poll_call(c, 0, &k)) {}
    reply(c, k2.id, REN_DONE, 0);
    ren_run(c, 0, 16);
    while (ren_poll_call(c, 0, &k)) {}
    reply(c, k1.id, REN_DONE, 3);
    CHECK(ren_run(c, 0, 16) == REN_FINISHED);
    ren_free(c);
  }
  CHECK(h1.jlen == h2.jlen && memcmp(h1.j, h2.j, h1.jlen) == 0);
  free(h1.j); free(h2.j);
}

/* ------------------------------------------------------------------ */
typedef struct { const char *name; void (*fn)(void); } test;
static const test tests[] = {
  {"basic", t_basic},   {"stale", t_stale}, {"cancel_race", t_cancel_race}, {"cancel_sent", t_cancel_sent},
  {"retract", t_retract}, {"answer_now", t_answer_now}, {"stop", t_stop}, {"kill", t_kill},
  {"budget", t_budget}, {"full", t_full}, {"steal", t_steal}, {"determinism", t_determinism},
};

int main(int argc, char **argv) {
  int bad = 0, ran = 0;
  for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) {
    int want = argc < 2;
    for (int a = 1; a < argc; a++) if (!strcmp(argv[a], tests[i].name)) want = 1;
    if (!want) continue;
    g_fail = 0; g_skip = 0;
    tests[i].fn();
    int skip = g_skip;
    ran++;
    printf("%s %s\n", skip ? "SKIP" : g_fail ? "FAIL" : "ok  ", tests[i].name);
    fflush(stdout);
    bad |= g_fail;
  }
  if (!ran) { fprintf(stderr, "abi_test: no such test\n"); return 2; }
  return bad;
}
