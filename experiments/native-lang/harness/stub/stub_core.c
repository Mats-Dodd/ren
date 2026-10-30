/* stub_core.c: NOT ONE OF THE THREE ENTRIES. A minimal stand-in core so
   the harness has a working example to link and run (W1, W2, W3, W4 at
   one worker). One worker only, no Chase-Lev deque (a plain LIFO stack in
   its place), no atomics beyond what slice.h's protocol needs, no park
   handshake. It follows SPEC §B.4's pick order and journal encoding, so
   at workers = 1 its journal should match a real core's byte for byte.
   Language entries must not copy code from here. */
#include "../slice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { S_FREE, S_ISSUED, S_PULLED, S_CANCEL_UNPULLED, S_CANCEL_PULLED, S_REPLIED };
enum { T_QUEUED = 1, T_RUNNING = 2, T_PARKED = 3, T_DONE = 4, T_NOTIFIED = 8 };

typedef struct op {
  struct op *next;
  uint32_t slot, gen;
  int had_cancel;
  ren_task *task;
  ren_await *aw;
  ren_call call;
  ren_io_body body;
  uint32_t reply_state;
  ren_io_result reply;
} op;

typedef struct cnode { struct cnode *next; uint64_t id; } cnode;

struct ren_ctx { ren_core *core; int32_t worker; uint32_t points; };

struct ren_core {
  ren_config cfg;
  ren_host host;
  void *hostp;
  uint32_t B, K, S;
  uint64_t *word;     /* gen << 32 | state */
  op **slot_op;
  uint32_t *free_stk; uint32_t nfree;
  ren_task **stk; size_t nstk, capstk;          /* stands in for the deque */
  ren_task *inj_head, *inj_tail;                 /* injector, linked through core[1] */
  op *inbox_head, *inbox_tail;                   /* FIFO */
  op *out_head, *out_tail;
  cnode *cq_head, *cq_tail;
  int64_t live;
  int stopping, killed, done, parked;
  uint64_t steps, last_poll;
  uint32_t spawn_seq;
  ren_ctx cx;
};

/* ---- journal encoding (SPEC §B.7) ---- */
typedef struct { uint8_t b[8192]; size_t n; } jbuf;   /* the slice's buffers are <= 4 KiB */
static void jput(jbuf *j, const void *p, size_t n) { if (n) memcpy(j->b + j->n, p, n); j->n += n; }
static void j32(jbuf *j, uint32_t v) { jput(j, &v, 4); }
static void j64(jbuf *j, uint64_t v) { jput(j, &v, 8); }
static void jemit(ren_core *c, uint32_t kind, int32_t worker, jbuf *payload) {
  if (!c->host.journal) return;
  uint8_t *e = malloc(24 + payload->n);
  uint32_t len = (uint32_t)payload->n, pad = 0;
  uint64_t step = worker >= 0 ? c->steps : 0;
  memcpy(e, &kind, 4); memcpy(e + 4, &len, 4); memcpy(e + 8, &worker, 4);
  memcpy(e + 12, &pad, 4); memcpy(e + 16, &step, 8);
  memcpy(e + 24, payload->b, payload->n);
  c->host.journal(c->hostp, worker, e, 24 + payload->n);
  free(e);
}
static void jcall_wire(jbuf *j, const ren_call *k) {
  uint16_t w = k->worker, kind = k->kind;
  j64(j, k->id); jput(j, &w, 2); jput(j, &kind, 2);
  j32(j, k->lane); j32(j, k->task); j32(j, k->op); j32(j, k->len);
  if (k->kind == REN_CALL && k->len == sizeof(ren_io_body)) {
    const ren_io_body *b = k->body;
    uint64_t h = 0;
    j64(j, (uint64_t)b->fd); j64(j, b->len); j64(j, 0); j64(j, (uint64_t)b->arg);
    if (k->op == REN_OP_WRITE) {
      const unsigned char *p = (const unsigned char *)(uintptr_t)b->buf;
      h = 0xcbf29ce484222325ull;
      for (uint64_t i = 0; i < b->len; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
    }
    j64(j, h);
  } else {
    j64(j, 0);
  }
}
static void jdeliver(ren_core *c, int32_t w, uint64_t id, uint32_t state, const ren_io_result *r,
                     const void *in, uint32_t in_len) {
  jbuf j = {.n = 0};
  j64(&j, id); j32(&j, state); j32(&j, sizeof *r); jput(&j, r, sizeof *r);
  if (in_len > 4096) abort();
  j32(&j, in_len); jput(&j, in, in_len);
  jemit(c, REN_J_DELIVER, w, &j);
}

/* ---- scheduling ---- */
static uint64_t *sched(ren_task *t) { return (uint64_t *)&t->core[0]; }
static void inj_push(ren_core *c, ren_task *t) {
  t->core[1] = 0;
  if (c->inj_tail) c->inj_tail->core[1] = (uintptr_t)t; else c->inj_head = t;
  c->inj_tail = t;
}
static ren_task *inj_pop(ren_core *c) {
  ren_task *t = c->inj_head;
  if (t) { c->inj_head = (ren_task *)t->core[1]; if (!c->inj_head) c->inj_tail = NULL; }
  return t;
}
static void stk_push(ren_core *c, ren_task *t) {
  if (c->nstk == c->capstk) {
    c->capstk = c->capstk ? 2 * c->capstk : 256;
    c->stk = realloc(c->stk, c->capstk * sizeof *c->stk);
  }
  c->stk[c->nstk++] = t;
}
static ren_task *stk_take(ren_core *c) { return c->nstk ? c->stk[--c->nstk] : NULL; }

void ren_notify(ren_ctx *cx, ren_task *t) {
  uint64_t s = *sched(t);
  *sched(t) = s | T_NOTIFIED;
  if (s == T_PARKED) { *sched(t) = T_QUEUED; stk_push(cx->core, t); }
}

static void op_free_slot(ren_core *c, op *o) {
  uint32_t g = o->gen + 1; if (g == 0) g = 1;
  c->word[o->slot] = (uint64_t)g << 32 | S_FREE;
  c->free_stk[c->nfree++] = o->slot;
}

static void deliver(ren_core *c, op *o) {
  uint32_t in_len = 0;
  const void *in = NULL;
  if (o->call.op == REN_OP_READ && o->reply_state == REN_DONE && o->reply.res > 0) {
    in = (const void *)(uintptr_t)o->body.buf; in_len = (uint32_t)o->reply.res;
  }
  jdeliver(c, 0, o->call.id, o->reply_state, &o->reply, in, in_len);
  o->aw->res = o->reply;
  ren_st32(&o->aw->state, (int32_t)o->reply_state, REN_MO_RELEASE);
  ren_task *t = o->task;
  op_free_slot(c, o);
  free(o);
  ren_notify(&c->cx, t);
}
static size_t drain_inbox(ren_core *c) {
  size_t n = 0;
  op *o = c->inbox_head;
  c->inbox_head = c->inbox_tail = NULL;
  while (o) { op *nx = o->next; deliver(c, o); o = nx; n++; }
  return n;
}
static void inbox_push(ren_core *c, op *o) {
  o->next = NULL;
  if (c->inbox_tail) c->inbox_tail->next = o; else c->inbox_head = o;
  c->inbox_tail = o;
}

ren_core *ren_start(const ren_config *cfg, ren_main_fn main, const ren_host *host, void *hostp) {
  if (cfg->workers != 1) { fprintf(stderr, "stub core: workers must be 1\n"); return NULL; }
  ren_core *c = calloc(1, sizeof *c);
  c->cfg = *cfg; c->host = *host; c->hostp = hostp;
  c->B = cfg->budget_b ? cfg->budget_b : 128;
  c->K = cfg->poll_k ? cfg->poll_k : 61;
  c->S = cfg->op_slots ? cfg->op_slots : 4096;
  c->word = malloc(c->S * sizeof *c->word);
  c->slot_op = calloc(c->S, sizeof *c->slot_op);
  c->free_stk = malloc(c->S * sizeof *c->free_stk);
  for (uint32_t i = 0; i < c->S; i++) { c->word[i] = 1ull << 32 | S_FREE; c->free_stk[i] = c->S - 1 - i; }
  c->nfree = c->S;
  c->cx.core = c; c->cx.worker = 0;
  c->live = 1;
  jbuf j = {.n = 0};
  const char *bid = cfg->build_id ? cfg->build_id : "";
  uint32_t bl = (uint32_t)strlen(bid);
  j32(&j, 1); j32(&j, 1); j32(&j, c->B); j32(&j, c->K); j32(&j, cfg->journal_policy); j32(&j, bl); jput(&j, bid, bl);
  jemit(c, REN_J_HEADER, -1, &j);
  ren_task *root = main(&c->cfg);
  root->id = (0u << 24) | ++c->spawn_seq;
  *sched(root) = T_QUEUED;
  inj_push(c, root);
  return c;
}

void ren_thread_init(ren_core *c, int32_t w, void *lo, size_t n) { (void)c; (void)w; (void)lo; (void)n; }

static void finish(ren_core *c) {
  jbuf j = {.n = 0}; j32(&j, 0);
  jemit(c, REN_J_END, 0, &j);
  c->done = 1;
}

static void run_task(ren_core *c, ren_task *t) {
  *sched(t) = T_RUNNING;
  c->cx.points = 0;
  int32_t r = t->resume(t, &c->cx);
  c->steps++;
  switch (r) {
  case REN_T_DONE:
    *sched(t) = T_DONE;
    ren_rc_drop(&t->obj);
    if (--c->live == 0) finish(c);
    break;
  case REN_T_PARK:
    if (*sched(t) == T_RUNNING) *sched(t) = T_PARKED;
    else { *sched(t) = T_QUEUED; stk_push(c, t); }
    break;
  case REN_T_YIELD:
    *sched(t) = T_QUEUED;
    inj_push(c, t);
    break;
  default:
    fprintf(stderr, "stub core: bad resume result %d\n", r);
    abort();
  }
}

static void wake0(ren_core *c) { if (c->parked) { c->parked = 0; c->host.wake(c->hostp, 0); } }

int32_t ren_run(ren_core *c, int32_t w, uint32_t steps) {
  (void)w;
  c->parked = 0;
  if (c->killed || c->done) return REN_FINISHED;
  drain_inbox(c);
  uint32_t n = 0;
  for (;;) {
    if (c->done || c->killed) return REN_FINISHED;
    if (n == steps) return REN_RUNNING;
    ren_task *t = NULL;
    uint64_t s = c->steps;
    if (s != 0 && s % c->K == 0 && c->last_poll != s) {
      c->last_poll = s;
      drain_inbox(c);
      t = inj_pop(c);
    }
    if (!t) t = stk_take(c);
    if (!t) t = inj_pop(c);
    if (!t) {
      if (drain_inbox(c) > 0) continue;
      if (c->done) return REN_FINISHED;
      c->parked = 1;
      return REN_IDLE;
    }
    run_task(c, t);
    n++;
  }
}

bool ren_poll_call(ren_core *c, int32_t w, ren_call *out) {
  (void)w;
  if (c->killed) return false;
  if (c->cq_head) {
    cnode *n = c->cq_head;
    c->cq_head = n->next; if (!c->cq_head) c->cq_tail = NULL;
    memset(out, 0, sizeof *out);
    out->id = n->id; out->worker = 0; out->kind = REN_CANCEL;
    free(n);
    return true;
  }
  while (c->out_head) {
    op *o = c->out_head;
    c->out_head = o->next; if (!c->out_head) c->out_tail = NULL;
    uint32_t st = (uint32_t)c->word[o->slot];
    if (st == S_ISSUED) {
      c->word[o->slot] = (uint64_t)o->gen << 32 | S_PULLED;
      *out = o->call;
      return true;
    }
    /* CANCEL_UNPULLED: retract */
    c->word[o->slot] = (uint64_t)o->gen << 32 | S_REPLIED;
    o->had_cancel = 1; o->reply_state = REN_CANCELLED;
    o->reply.res = -REN_ECANCELED; o->reply.a = o->reply.b = 0;
    inbox_push(c, o);
  }
  return false;
}

static void jrelease(ren_core *c, uint64_t id, uint32_t why) {
  jbuf j = {.n = 0}; j64(&j, id); j32(&j, why); jemit(c, REN_J_RELEASE, -1, &j);
}

int32_t ren_reply(ren_core *c, const ren_reply_t *r) {
  if (c->killed) { jrelease(c, r->id, REN_JR_DEAD); return REN_RELEASE; }
  uint64_t gs = r->id >> 32; uint32_t g = (uint32_t)r->id;
  if (gs >= c->S || g == 0) { jrelease(c, r->id, REN_JR_STALE); return REN_RELEASE; }
  uint64_t wd = c->word[gs];
  if ((uint32_t)(wd >> 32) != g) { jrelease(c, r->id, REN_JR_STALE); return REN_RELEASE; }
  uint32_t st = (uint32_t)wd;
  if (st != S_PULLED && st != S_CANCEL_PULLED) {
    jrelease(c, r->id, st == S_REPLIED ? REN_JR_DUP : REN_JR_STALE);
    return REN_RELEASE;
  }
  c->word[gs] = (wd & ~0xffffffffull) | S_REPLIED;
  op *o = c->slot_op[gs];
  o->had_cancel = st == S_CANCEL_PULLED;
  o->reply_state = r->state;
  memset(&o->reply, 0, sizeof o->reply);
  memcpy(&o->reply, r->body, r->len < sizeof o->reply ? r->len : sizeof o->reply);
  inbox_push(c, o);
  wake0(c);
  return REN_ACCEPTED;
}

static void cancel_slot(ren_core *c, uint64_t gs, uint32_t g, int32_t by) {
  uint32_t how = REN_JC_LATE;
  uint64_t wd = c->word[gs];
  if ((uint32_t)(wd >> 32) == g) {
    uint32_t st = (uint32_t)wd;
    if (st == S_ISSUED) { c->word[gs] = (uint64_t)g << 32 | S_CANCEL_UNPULLED; how = REN_JC_RETRACT; }
    else if (st == S_PULLED) {
      c->word[gs] = (uint64_t)g << 32 | S_CANCEL_PULLED;
      cnode *n = calloc(1, sizeof *n);
      n->id = gs << 32 | g;
      if (c->cq_tail) c->cq_tail->next = n; else c->cq_head = n;
      c->cq_tail = n;
      how = REN_JC_SENT;
    }
  }
  jbuf j = {.n = 0}; j64(&j, gs << 32 | g); j32(&j, how); jemit(c, REN_J_CANCEL, by, &j);
}

void ren_cancel(ren_ctx *cx, uint64_t id) {
  ren_core *c = cx->core;
  if ((id >> 32) >= c->S || (uint32_t)id == 0) {
    jbuf j = {.n = 0}; j64(&j, id); j32(&j, REN_JC_LATE); jemit(c, REN_J_CANCEL, 0, &j);
    return;
  }
  cancel_slot(c, id >> 32, (uint32_t)id, 0);
}

int32_t ren_world(ren_ctx *cx, ren_task *self, ren_await *aw, uint32_t opcode, const ren_io_body *body) {
  ren_core *c = cx->core;
  if (c->stopping) {
    aw->id = 0; aw->op = opcode;
    aw->res.res = -REN_ECANCELED; aw->res.a = aw->res.b = 0;
    jdeliver(c, 0, 0, REN_CANCELLED, &aw->res, NULL, 0);
    ren_st32(&aw->state, REN_CANCELLED, REN_MO_RELEASE);
    return REN_W_NOW;
  }
  if (c->nfree == 0) return REN_W_FULL;
  uint32_t gs = c->free_stk[--c->nfree];
  uint32_t g = (uint32_t)(c->word[gs] >> 32);
  op *o = calloc(1, sizeof *o);
  o->slot = gs; o->gen = g; o->task = self; o->aw = aw; o->body = *body;
  o->call.id = (uint64_t)gs << 32 | g; o->call.worker = 0; o->call.kind = REN_CALL;
  o->call.task = self->id; o->call.op = opcode; o->call.len = sizeof(ren_io_body); o->call.body = &o->body;
  aw->id = o->call.id; aw->op = opcode; ren_st32(&aw->state, 0, REN_MO_RELAXED);
  jbuf j = {.n = 0}; jcall_wire(&j, &o->call); jemit(c, REN_J_CALL, 0, &j);
  ren_reply_t rep;
  memset(&rep, 0, sizeof rep);
  if (c->host.answer_now && c->host.answer_now(c->hostp, 0, &o->call, &rep)) {
    ren_io_result res = {.res = 0, .a = 0, .b = 0};
    memcpy(&res, rep.body, rep.len < sizeof res ? rep.len : sizeof res);
    jdeliver(c, 0, o->call.id, rep.state, &res, NULL, 0);
    aw->res = res;
    ren_st32(&aw->state, (int32_t)rep.state, REN_MO_RELEASE);
    op_free_slot(c, o);
    free(o);
    return REN_W_NOW;
  }
  c->slot_op[gs] = o;
  c->word[gs] = (uint64_t)g << 32 | S_ISSUED;
  o->next = NULL;
  if (c->out_tail) c->out_tail->next = o; else c->out_head = o;
  c->out_tail = o;
  return REN_W_PENDING;
}

void ren_spawn(ren_ctx *cx, ren_task *t) {
  ren_core *c = cx->core;
  t->id = (0u << 24) | ++c->spawn_seq;
  *sched(t) = T_QUEUED;
  c->live++;
  stk_push(c, t);
}
bool ren_tick(ren_ctx *cx) { return ++cx->points >= cx->core->B; }
bool ren_cancelled(ren_ctx *cx) { return cx->core->stopping != 0; }
int32_t ren_ctx_worker(ren_ctx *cx) { return cx->worker; }

void ren_stop(ren_core *c) {
  if (c->stopping) return;
  c->stopping = 1;
  for (uint32_t gs = 0; gs < c->S; gs++)
    if ((uint32_t)c->word[gs] != S_FREE) cancel_slot(c, gs, (uint32_t)(c->word[gs] >> 32), -1);
  wake0(c);
}
void ren_kill(ren_core *c) {
  if (c->killed) return;
  c->killed = 1;
  jbuf j = {.n = 0}; j32(&j, 1); jemit(c, REN_J_END, -1, &j);
  c->done = 1;
}
void ren_free(ren_core *c) {
  ren_task *t;
  while ((t = stk_take(c))) ren_rc_drop(&t->obj);
  while ((t = inj_pop(c))) ren_rc_drop(&t->obj);
  for (uint32_t gs = 0; gs < c->S; gs++)
    if ((uint32_t)c->word[gs] != S_FREE && c->slot_op[gs]) {
      ren_rc_drop(&c->slot_op[gs]->task->obj);
      free(c->slot_op[gs]);
    }
  while (c->cq_head) { cnode *n = c->cq_head; c->cq_head = n->next; free(n); }
  free(c->stk); free(c->word); free(c->slot_op); free(c->free_stk); free(c);
}
uint64_t ren_progress(ren_core *c, int32_t w) { (void)w; return c->steps; }

/* ---- the deque test ABI: a mutex-free single-lock stand-in ---- */
#include <pthread.h>
struct ren_dq { pthread_mutex_t mu; uint64_t *v; int64_t top, bot, cap; };
ren_dq *ren_dq_new(uint32_t log2) {
  ren_dq *q = calloc(1, sizeof *q);
  pthread_mutex_init(&q->mu, NULL);
  q->cap = 1 << log2; q->v = malloc((size_t)q->cap * 8);
  return q;
}
void ren_dq_push(ren_dq *q, uint64_t x) {
  pthread_mutex_lock(&q->mu);
  if (q->bot - q->top == q->cap) {
    uint64_t *n = malloc((size_t)q->cap * 16);
    for (int64_t i = q->top; i < q->bot; i++) n[i & (2 * q->cap - 1)] = q->v[i & (q->cap - 1)];
    free(q->v); q->v = n; q->cap *= 2;
  }
  q->v[q->bot++ & (q->cap - 1)] = x;
  pthread_mutex_unlock(&q->mu);
}
uint64_t ren_dq_take(ren_dq *q) {
  uint64_t x = REN_DQ_EMPTY;
  pthread_mutex_lock(&q->mu);
  if (q->bot > q->top) x = q->v[--q->bot & (q->cap - 1)];
  pthread_mutex_unlock(&q->mu);
  return x;
}
uint64_t ren_dq_steal(ren_dq *q) {
  uint64_t x = REN_DQ_EMPTY;
  pthread_mutex_lock(&q->mu);
  if (q->bot > q->top) x = q->v[q->top++ & (q->cap - 1)];
  pthread_mutex_unlock(&q->mu);
  return x;
}
void ren_dq_free(ren_dq *q) { pthread_mutex_destroy(&q->mu); free(q->v); free(q); }

/* ---- the layout table, as C sees it ---- */
#define LX(T, F) {#T "." #F, (uint32_t)offsetof(T, F), 0},
#define LS(T) {"sizeof(" #T ")", (uint32_t)sizeof(T), 0},
static const ren_layout_ent stub_layout[] = {REN_LAYOUT_LIST(LX, LS)};
size_t ren_layout_table(const ren_layout_ent **out) {
  *out = stub_layout;
  return sizeof stub_layout / sizeof *stub_layout;
}
