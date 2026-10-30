/* core.c: the sans-I/O core's op table and world calls (SPEC §B.3-§B.5):
   ren_start, ren_poll_call, ren_reply, ren_stop, ren_kill, ren_free and
   ren_world, ren_cancel, deliver. The run loop is in sched.c. */
#include "core.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *xmalloc(size_t n) {
  void *p = malloc(n);
  if (!p) { fputs("ren c: out of memory\n", stderr); abort(); }
  return p;
}
static void *xalloc64(size_t n) {
  void *p = aligned_alloc(64, (n + 63) & ~(size_t)63);
  if (!p) { fputs("ren c: out of memory\n", stderr); abort(); }
  memset(p, 0, n);
  return p;
}

/* ---------------- MPSC stacks (inbox: op, remote: cnode) ---------------- */
static void op_push(aptr *head, op *n) {
  uintptr_t h = LD(head, RLX);
  for (;;) {
    ST(&n->next, h, RLX);
    if (CAS(head, &h, (uintptr_t)n, REL, RLX)) return;
  }
}
static op *op_take_all(aptr *head) {             /* FIFO in arrival order */
  op *l = (op *)XCHG(head, (uintptr_t)0, ACQ), *r = NULL;
  while (l) { op *nx = (op *)LD(&l->next, RLX); ST(&l->next, (uintptr_t)r, RLX); r = l; l = nx; }
  return r;
}
static void cn_push(aptr *head, cnode *n) {
  uintptr_t h = LD(head, RLX);
  for (;;) {
    ST(&n->next, h, RLX);
    if (CAS(head, &h, (uintptr_t)n, REL, RLX)) return;
  }
}
static cnode *cn_take_all(aptr *head) {
  cnode *l = (cnode *)XCHG(head, (uintptr_t)0, ACQ), *r = NULL;
  while (l) { cnode *nx = (cnode *)LD(&l->next, RLX); ST(&l->next, (uintptr_t)r, RLX); r = l; l = nx; }
  return r;
}

/* owner FIFOs */
static void op_fifo_push(fifo *f, op *o) {
  ST(&o->next, (uintptr_t)0, RLX);
  if (f->tail) ST(&((op *)f->tail)->next, (uintptr_t)o, RLX); else f->head = o;
  f->tail = o;
}
static op *op_fifo_pop(fifo *f) {
  op *o = f->head;
  if (o) { f->head = (op *)LD(&o->next, RLX); if (!f->head) f->tail = NULL; }
  return o;
}
static void cn_fifo_append(fifo *f, cnode *l) {
  while (l) {
    cnode *nx = (cnode *)LD(&l->next, RLX);
    ST(&l->next, (uintptr_t)0, RLX);
    if (f->tail) ST(&((cnode *)f->tail)->next, (uintptr_t)l, RLX); else f->head = l;
    f->tail = l;
    l = nx;
  }
}
static cnode *cn_fifo_pop(fifo *f) {
  cnode *n = f->head;
  if (n) { f->head = (cnode *)LD(&n->next, RLX); if (!f->head) f->tail = NULL; }
  return n;
}

static inline uint64_t mkword(uint32_t g, uint32_t st) { return (uint64_t)g << 32 | st; }
static inline uint32_t wgen(uint64_t wd) { return (uint32_t)(wd >> 32); }
static inline uint32_t wstate(uint64_t wd) { return (uint32_t)(wd & 0xffffffffu); }

/* ---------------- ren_start ---------------- */
ren_core *ren_start(const ren_config *cfg, ren_main_fn main_fn, const ren_host *host, void *hostp) {
  if (!cfg || !host || !main_fn || cfg->workers < 1 || cfg->workers > 64) return NULL;
  if (cfg->deque_log2 > 30) return NULL;
  ren_core *c = xalloc64(sizeof *c);
  c->cfg = *cfg;
  c->host = *host;
  c->hostp = hostp;
  c->nw = cfg->workers;
  c->B = cfg->budget_b ? cfg->budget_b : 128;
  c->K = cfg->poll_k ? cfg->poll_k : 61;
  c->S = cfg->op_slots ? cfg->op_slots : 4096;
  c->cfg.budget_b = c->B; c->cfg.poll_k = c->K; c->cfg.op_slots = c->S;
  if (!c->cfg.deque_log2) c->cfg.deque_log2 = 8;
  size_t nslots = (size_t)c->nw * c->S;
  c->W = xalloc64((size_t)c->nw * sizeof(worker));
  c->slots = xmalloc(nslots * sizeof(slot));
  for (size_t i = 0; i < nslots; i++) { ST(&c->slots[i].word, mkword(1, S_FREE), RLX); c->slots[i].o = NULL; }
  for (int32_t w = 0; w < c->nw; w++) {
    worker *W = &c->W[w];
    dq_init(&W->dq, c->cfg.deque_log2);
    ST(&W->parked, 0, RLX);
    ST(&W->steps, 0, RLX);
#if REN_PLANT == 5
    W->stolen_from = 0;                    /* PLANT P5: the field is plain (init only, before threads) */
#else
    ST(&W->stolen_from, 0, RLX);
#endif
    ST(&W->inbox, (uintptr_t)0, RLX);
    ST(&W->remote, (uintptr_t)0, RLX);
    W->free_stk = xmalloc(c->S * sizeof(uint32_t));
    for (uint32_t i = 0; i < c->S; i++) W->free_stk[i] = c->S - 1 - i;   /* pops 0, 1, 2, ... */
    W->nfree = c->S;
    W->rng = 0x9E3779B97F4A7C15ull ^ (uint64_t)(w + 1);
    W->cx.core = c;
    W->cx.worker = w;
  }
  ST(&c->inj.lock, 0, RLX);
  ST(&c->inj.len, 0, RLX);
  ST(&c->live, 1, RLX);
  ST(&c->stopping, 0, RLX); ST(&c->killed, 0, RLX); ST(&c->done, 0, RLX); ST(&c->idle, 0, RLX);
  j_header(c);
  ren_task *root = main_fn(&c->cfg);      /* the frame; its one reference is now the core's */
  if (!root) { ren_free(c); return NULL; }
  root->id = (0u << 24) | ++c->W[0].spawn_seq;
  ST(task_sched(root), (uint64_t)T_QUEUED, RLX);
  inj_push(c, root);                      /* no wake: nobody is parked yet */
  return c;
}

/* ---------------- delivery (home worker, inside ren_run) ---------------- */
static void deliver(ren_core *c, int32_t w, op *o) {
  ren_await *aw = o->aw;
  ren_task *t = o->task;
  const uint8_t *in = NULL;
  uint32_t in_len = 0;
  if (o->call.op == REN_OP_READ && o->reply_state == REN_DONE && o->reply.res > 0) {
    uint64_t n = (uint64_t)o->reply.res;
    if (n > o->body.len) n = o->body.len;      /* never past the buffer the call named */
    in = (const uint8_t *)(uintptr_t)o->body.buf;
    in_len = (uint32_t)n;
  }
  j_deliver(c, w, o->call.id, o->reply_state, &o->reply, in, in_len);
#if REN_C_DEBUG
  ST(ASU64(&t->core[2]), (uint64_t)0, RLX);   /* debug: no pending call (before the REL below) */
#endif
  aw->res = o->reply;
  ST32(&aw->state, (int32_t)o->reply_state, REL);
#if REN_PLANT == 4
  if (o->had_cancel) { c->W[w].cancel_done++; free(o); }  /* PLANT P4: on_cancel_done also frees the op */
#else
  if (o->had_cancel) c->W[w].cancel_done++;  /* on_cancel_done: a plain counter only */
#endif
  ST(&c->slots[o->slot].word, mkword(next_gen(o->gen), S_FREE), REL);
  worker *W = &c->W[w];
  W->free_stk[W->nfree++] = o->slot - (uint32_t)w * c->S;
  free(o);
  sched_notify(c, w, t);
}

size_t drain_inbox(ren_core *c, int32_t w) {
  size_t n = 0;
  op *o = op_take_all(&c->W[w].inbox);
  while (o) {
    op *nx = (op *)LD(&o->next, RLX);
    deliver(c, w, o);
    o = nx;
    n++;
  }
  return n;
}

/* ---------------- ren_poll_call ---------------- */
bool ren_poll_call(ren_core *c, int32_t w, ren_call *out) {
  worker *W = &c->W[w];
  if (LD(&c->killed, ACQ)) goto none;
  if (!W->cancels.head) cn_fifo_append(&W->cancels, cn_take_all(&W->remote));
  cnode *n = cn_fifo_pop(&W->cancels);
  if (n) {
    memset(out, 0, sizeof *out);
    out->id = n->id;
    out->worker = (uint16_t)w;
    out->kind = REN_CANCEL;
    out->lane = 0; out->task = 0; out->op = 0; out->len = 0; out->body = NULL;
    free(n);
    return true;
  }
  op *o;
  while ((o = op_fifo_pop(&W->outbox))) {
    uint32_t g = o->gen;
    slot *s = &c->slots[o->slot];
    uint64_t e = mkword(g, S_ISSUED);
    if (CAS(&s->word, &e, mkword(g, S_PULLED), AR, ACQ)) { *out = o->call; return true; }
    /* otherwise CANCEL_UNPULLED: retract, with no round trip (glommio's Enqueued) */
    e = mkword(g, S_CANCEL_UNPULLED);
    if (!CAS(&s->word, &e, mkword(g, S_REPLIED), AR, ACQ)) {
      fprintf(stderr, "ren c: retract found slot word %016llx\n", (unsigned long long)e);
      abort();                            /* cannot fail: only home moves it from here */
    }
    o->had_cancel = true;
    o->reply_state = REN_CANCELLED;
    o->reply.res = -REN_ECANCELED; o->reply.a = 0; o->reply.b = 0;
    op_push(&W->inbox, o);                /* delivered at the next drain, in order */
    /* NOTES.md: not in SPEC's pseudocode. A retraction is a reply, and §2.7
       says every reply leads to a tick: without this wake a worker that
       returned IDLE before its driver pulled would sleep on it forever. */
    wake_worker(c, w);
  }
none:
#if REN_C_DEBUG
  W->drained = true;
#endif
  return false;
}

/* ---------------- ren_reply (any thread) ---------------- */
int32_t ren_reply(ren_core *c, const ren_reply_t *r) {
  if (LD(&c->killed, ACQ)) { j_release(c, r->id, REN_JR_DEAD); return REN_RELEASE; }
  uint64_t gs = r->id >> 32;
  uint32_t g = (uint32_t)(r->id & 0xffffffffu);
  if (gs >= (uint64_t)c->nw * c->S || g == 0) { j_release(c, r->id, REN_JR_STALE); return REN_RELEASE; }
  slot *s = &c->slots[gs];
  uint32_t st;
  for (;;) {
    uint64_t wd = LD(&s->word, ACQ);
#if REN_PLANT != 3                         /* PLANT P3 deletes the generation test */
    if (wgen(wd) != g) { j_release(c, r->id, REN_JR_STALE); return REN_RELEASE; }
#endif
    st = wstate(wd);
    if (st == S_PULLED || st == S_CANCEL_PULLED) {
      if (CAS(&s->word, &wd, (wd & ~(uint64_t)0xffffffffu) | S_REPLIED, AR, ACQ)) break;
      continue;
    }
    j_release(c, r->id, st == S_REPLIED ? REN_JR_DUP : REN_JR_STALE);
    return REN_RELEASE;
  }
  op *o = s->o;
  o->had_cancel = (st == S_CANCEL_PULLED);
  o->reply_state = r->state;
  ren_io_result res = {0, 0, 0};
  if (r->body) {
    size_t n = r->len < sizeof res ? r->len : sizeof res;
    memcpy(&res, r->body, n);              /* the first 24 bytes, zero-filled */
  }
  o->reply = res;
  op_push(&c->W[o->home].inbox, o);        /* REL */
  wake_worker(c, o->home);                 /* §2.7: every reply leads to a tick */
  return REN_ACCEPTED;
}

/* ---------------- cancel ---------------- */
static void cancel_slot(ren_core *c, uint64_t gs, uint32_t g, int32_t by) {
  slot *s = &c->slots[gs];
  uint32_t how;
  for (;;) {
    uint64_t wd = LD(&s->word, ACQ);
    if (wgen(wd) != g) { how = REN_JC_LATE; break; }
    uint32_t st = wstate(wd);
    if (st == S_ISSUED) {
      if (CAS(&s->word, &wd, mkword(g, S_CANCEL_UNPULLED), AR, ACQ)) { how = REN_JC_RETRACT; break; }
    } else if (st == S_PULLED) {
      if (CAS(&s->word, &wd, mkword(g, S_CANCEL_PULLED), AR, ACQ)) {
        int32_t home = (int32_t)(gs / c->S);
        cnode *n = xmalloc(sizeof *n);
        n->id = gs << 32 | g;
        cn_push(&c->W[home].remote, n);
        wake_worker(c, home);
        how = REN_JC_SENT;
        break;
      }
    } else { how = REN_JC_LATE; break; }
  }
  j_cancel(c, by, gs << 32 | g, how);       /* by = -1 from ren_stop: step 0 */
}

void ren_cancel(ren_ctx *cx, uint64_t id) {
  ren_core *c = cx->core;
  if ((id >> 32) >= (uint64_t)c->nw * c->S || (uint32_t)(id & 0xffffffffu) == 0) {
    j_cancel(c, cx->worker, id, REN_JC_LATE);
    return;
  }
  cancel_slot(c, id >> 32, (uint32_t)(id & 0xffffffffu), cx->worker);
}

/* ---------------- ren_world ---------------- */
int32_t ren_world(ren_ctx *cx, ren_task *self, ren_await *aw, uint32_t opcode, const ren_io_body *body) {
  ren_core *c = cx->core;
  int32_t w = cx->worker;
  worker *W = &c->W[w];
#if REN_C_DEBUG
  if (LD(ASU64(&self->core[2]), RLX) != 0) {
    fprintf(stderr, "ren c: task %u issued a world call with one already pending\n", self->id);
    abort();
  }
#endif
  if (LD(&c->stopping, ACQ)) {
    aw->id = 0; aw->op = opcode;
    aw->res.res = -REN_ECANCELED; aw->res.a = 0; aw->res.b = 0;
    j_deliver(c, w, 0, REN_CANCELLED, &aw->res, NULL, 0);
    ST32(&aw->state, REN_CANCELLED, REL);
    return REN_W_NOW;
  }
  if (W->nfree == 0) return REN_W_FULL;
  uint32_t ls = W->free_stk[--W->nfree];
  uint32_t gs = (uint32_t)w * c->S + ls;
  uint32_t g = wgen(LD(&c->slots[gs].word, RLX));
  uint64_t id = (uint64_t)gs << 32 | g;
  op *o = xmalloc(sizeof *o);
  memset(o, 0, sizeof *o);
  o->slot = gs; o->gen = g; o->home = (uint16_t)w; o->had_cancel = false;
  o->task = self; o->aw = aw; o->body = *body;
  o->call.id = id; o->call.worker = (uint16_t)w; o->call.kind = REN_CALL; o->call.lane = 0;
  o->call.task = self->id; o->call.op = opcode; o->call.len = (uint32_t)sizeof(ren_io_body);
  o->call.body = &o->body;
  aw->id = id; aw->op = opcode;
  ST32(&aw->state, 0, RLX);
  j_call(c, w, &o->call);
  ren_reply_t rep;
  memset(&rep, 0, sizeof rep);
  if (c->host.answer_now && c->host.answer_now(c->hostp, w, &o->call, &rep)) {   /* inline: same journal path */
    ren_io_result res = {0, 0, 0};
    if (rep.body) memcpy(&res, rep.body, rep.len < sizeof res ? rep.len : sizeof res);
    j_deliver(c, w, id, rep.state, &res, NULL, 0);
    aw->res = res;
    ST32(&aw->state, (int32_t)rep.state, REL);
    ST(&c->slots[gs].word, mkword(next_gen(g), S_FREE), REL);
    W->free_stk[W->nfree++] = ls;
    free(o);
    return REN_W_NOW;
  }
#if REN_C_DEBUG
  ST(ASU64(&self->core[2]), (uint64_t)1, RLX);
#endif
  c->slots[gs].o = o;
  ST(&c->slots[gs].word, mkword(g, S_ISSUED), REL);
  op_fifo_push(&W->outbox, o);
  FENCE(SC);                                /* Dekker with ren_stop's xchg + fence + walk */
  if (LD(&c->stopping, RLX)) cancel_slot(c, gs, g, w);
  return REN_W_PENDING;
}

/* ---------------- stop, kill, free ---------------- */
void ren_stop(ren_core *c) {
  if (XCHG(&c->stopping, 1, SC) == 1) return;
  FENCE(SC);
  uint64_t n = (uint64_t)c->nw * c->S;
  for (uint64_t gs = 0; gs < n; gs++) {
    uint64_t wd = LD(&c->slots[gs].word, ACQ);
    /* NOTES.md: FREE slots are skipped (SPEC walks every slot, which would
       journal one LATE cancel per free slot). A slot that becomes ISSUED
       after this read is caught by ren_world's fence + stopping check. */
    if (wstate(wd) == S_FREE) continue;
    cancel_slot(c, gs, wgen(wd), -1);
  }
  wake_all(c);
}

void ren_kill(ren_core *c) {
  if (XCHG(&c->killed, 1, SC) == 1) return;
  j_end(c, -1, 1);
  ST(&c->done, 1, REL);
  wake_all(c);
}

/* After every worker's ren_run returned FINISHED and every driver finished
   (or, after a replay divergence, whenever the host gives up). */
void ren_free(ren_core *c) {
  if (!c) return;
  /* Slots first: a parked-on-a-call task is reachable only from its op,
     and its core reference keeps it alive until we drop it here. A task
     that is also queued (a spurious wake) is dropped by the queue walk. */
  uint64_t n = (uint64_t)c->nw * c->S;
  for (uint64_t gs = 0; gs < n; gs++) {
    if (wstate(LD(&c->slots[gs].word, RLX)) == S_FREE || !c->slots[gs].o) continue;
    op *o = c->slots[gs].o;
    if (LD(task_sched(o->task), RLX) == T_PARKED) {
      ST(task_sched(o->task), (uint64_t)T_DONE, RLX);
      ren_rc_drop(&o->task->obj);
    }
    free(o);
  }
  ren_task *t;
  for (int32_t w = 0; w < c->nw; w++) {
    uintptr_t x;
    while ((x = dq_take(&c->W[w].dq)) != DQ_EMPTY) ren_rc_drop(&((ren_task *)x)->obj);
  }
  while ((t = inj_pop(c))) ren_rc_drop(&t->obj);
  for (int32_t w = 0; w < c->nw; w++) {
    worker *W = &c->W[w];
    cnode *cn;
    cn_fifo_append(&W->cancels, cn_take_all(&W->remote));
    while ((cn = cn_fifo_pop(&W->cancels))) free(cn);
    dq_destroy(&W->dq);
    free(W->free_stk);
  }
  free(c->slots);
  free(c->W);
  free(c);
}

/* Debug aid (not part of the ABI): print the core's state. The fuzz
   driver calls it on "no termination" when REN_C_DUMP is set. */
void ren_c_dump(ren_core *c, FILE *f) {
  fprintf(f, "core: live=%lld stopping=%lld killed=%lld done=%lld idle=%lld inj.len=%lld\n",
          (long long)LD(&c->live, RLX), (long long)LD(&c->stopping, RLX), (long long)LD(&c->killed, RLX),
          (long long)LD(&c->done, RLX), (long long)LD(&c->idle, RLX), (long long)LD(&c->inj.len, RLX));
  for (int32_t w = 0; w < c->nw; w++) {
    worker *W = &c->W[w];
    fprintf(f, " W%d: parked=%lld steps=%llu dq=%lld inbox=%p remote=%p cancels=%p outbox=%p nfree=%u\n", w,
            (long long)LD(&W->parked, RLX), (unsigned long long)LD(&W->steps, RLX), (long long)dq_size_hint(&W->dq),
            (void *)LD(&W->inbox, RLX), (void *)LD(&W->remote, RLX), W->cancels.head, W->outbox.head, W->nfree);
  }
  uint64_t n = (uint64_t)c->nw * c->S;
  for (uint64_t gs = 0; gs < n; gs++) {
    uint64_t wd = LD(&c->slots[gs].word, RLX);
    if (wstate(wd) == S_FREE) continue;
    op *o = c->slots[gs].o;
    fprintf(f, " slot %llu gen %u state %u task %u sched %llu op %08x\n", (unsigned long long)gs, wgen(wd), wstate(wd),
            o ? o->task->id : 0, o ? (unsigned long long)LD(task_sched(o->task), RLX) : 0ull, o ? o->call.op : 0);
  }
}
