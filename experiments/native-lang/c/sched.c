/* sched.c: the scheduler unit. ren_run's pick loop (SPEC §B.4), the task
   scheduling word (§B.2), park and wake (§B.6), the injector and the
   steal path. The op table and world calls are in core.c. */
#include "core.h"
#include <stdio.h>
#include <stdlib.h>

/* ---------------- injector: a spinlock-protected FIFO ---------------- */
static void inj_lock(injector *q) {
  while (XCHG(&q->lock, 1, ACQ) != 0)
    while (LD(&q->lock, RLX) != 0) CPU_RELAX();
}
static void inj_unlock(injector *q) { ST(&q->lock, 0, REL); }

void inj_push(ren_core *c, ren_task *t) {
  injector *q = &c->inj;
  inj_lock(q);
  t->core[1] = 0;
  if (q->tail) q->tail->core[1] = (uintptr_t)t;
  else q->head = t;
  q->tail = t;
  XADD(&q->len, 1, RLX);
  inj_unlock(q);
}

ren_task *inj_pop(ren_core *c) {
  injector *q = &c->inj;
  if (LD(&q->len, RLX) == 0) return NULL;
  inj_lock(q);
  ren_task *t = q->head;
  if (t) {
    q->head = (ren_task *)t->core[1];
    if (!q->head) q->tail = NULL;
    t->core[1] = 0;
    XADD(&q->len, -1, RLX);
  }
  inj_unlock(q);
  return t;
}

/* ---------------- park and wake (§B.6) ---------------- */
static bool try_park(ren_core *c, int32_t w) {
  worker *W = &c->W[w];
  ST(&W->parked, 1, SC);
  XADD(&c->idle, 1, SC);
  FENCE(SC);
  bool work = LD(&W->inbox, ACQ) != 0 || LD(&c->inj.len, RLX) > 0 ||
              LD(&c->done, ACQ) != 0 || LD(&c->killed, ACQ) != 0;
  for (int32_t v = 0; !work && v < c->nw; v++)
    if (dq_size_hint(&c->W[v].dq) > 0) work = true;
  if (work) {
    if (XCHG(&W->parked, 0, AR) == 1) XADD(&c->idle, -1, RLX);
    return false;   /* someone may already have woken us: harmless, the permit is sticky */
  }
  return true;
}

void wake_worker(ren_core *c, int32_t v) {
  FENCE(SC);
  int64_t one = 1;
  if (LD(&c->W[v].parked, RLX) == 1 && CAS(&c->W[v].parked, &one, 0, AR, RLX)) {
    XADD(&c->idle, -1, RLX);
    c->host.wake(c->hostp, v);
  }
}

void wake_one(ren_core *c, int32_t w) {
  FENCE(SC);
  if (LD(&c->idle, RLX) == 0) return;
  for (int32_t i = 1; i <= c->nw; i++) {           /* w itself last */
    int32_t v = (w + i) % c->nw;
    int64_t one = 1;
    if (LD(&c->W[v].parked, RLX) == 1 && CAS(&c->W[v].parked, &one, 0, AR, RLX)) {
      XADD(&c->idle, -1, RLX);
      c->host.wake(c->hostp, v);
      return;
    }
  }
}

void wake_all(ren_core *c) {
  for (int32_t v = 0; v < c->nw; v++) {
    int64_t one = 1;
    if (CAS(&c->W[v].parked, &one, 0, AR, RLX)) {
      XADD(&c->idle, -1, RLX);
      c->host.wake(c->hostp, v);
    }
  }
}

/* ---------------- the task scheduling word (§B.2) ---------------- */
void sched_notify(ren_core *c, int32_t w, ren_task *t) {
  uint64_t s = FETCH_OR(task_sched(t), (uint64_t)T_NOTIFIED, AR);
  if (s == T_PARKED) {            /* exactly one notifier sees PARKED without the flag */
    XCHG(task_sched(t), (uint64_t)T_QUEUED, AR);
    dq_push(&c->W[w].dq, (uintptr_t)t);
    wake_one(c, w);
  }
}

void ren_notify(ren_ctx *cx, ren_task *t) { sched_notify(cx->core, cx->worker, t); }

static void finish(ren_core *c, int32_t w) {
  j_end(c, w, 0);
  ST(&c->done, 1, REL);
  wake_all(c);
}

static void task_done(ren_core *c, int32_t w, ren_task *t) {
  ren_rc_drop(&t->obj);                 /* the core's reference (fin runs inside, at 0) */
  if (XADD(&c->live, -1, AR) == 1) finish(c, w);
}

static void run_task(ren_core *c, int32_t w, ren_task *t) {
  worker *W = &c->W[w];
  XCHG(task_sched(t), (uint64_t)T_RUNNING, AR);  /* clears NOTIFIED; syncs with every notify before */
  ren_ctx *cx = &W->cx;
  cx->points = 0;
  cx->cur = t;
  int32_t r = t->resume(t, cx);
  cx->cur = NULL;
  ST(&W->steps, LD(&W->steps, RLX) + 1, RLX);   /* entries written during the resume carry the old value */
  switch (r) {
  case REN_T_DONE:
    XCHG(task_sched(t), (uint64_t)T_DONE, AR);
    task_done(c, w, t);
    break;
  case REN_T_PARK: {
    uint64_t e = T_RUNNING;
    if (!CAS(task_sched(t), &e, (uint64_t)T_PARKED, AR, ACQ)) {   /* a notify came while running */
      XCHG(task_sched(t), (uint64_t)T_QUEUED, AR);
      dq_push(&W->dq, (uintptr_t)t);
      wake_one(c, w);
    }
    break;
  }
  case REN_T_YIELD:
    XCHG(task_sched(t), (uint64_t)T_QUEUED, AR);
    inj_push(c, t);
    wake_one(c, w);
    break;
  default:
    fprintf(stderr, "ren c: resume returned %d\n", r);
    abort();
  }
}

NO_SAN_INT static uint64_t xorshift64(uint64_t *s) {
  uint64_t x = *s;
  x ^= x << 13; x ^= x >> 7; x ^= x << 17;
  *s = x;
  return x;
}

static ren_task *steal_any(ren_core *c, int32_t w) {
  if (c->nw == 1) return NULL;
  uint32_t nw = (uint32_t)c->nw;
  uint32_t start = (uint32_t)(xorshift64(&c->W[w].rng) % nw);
  for (uint32_t i = 0; i < nw; i++) {
    uint32_t v = (start + i) % nw;
    if (v == (uint32_t)w) continue;
    uintptr_t x = dq_steal(&c->W[v].dq);
    if (x != DQ_EMPTY && x != DQ_ABORT) {
#if REN_PLANT == 5
      c->W[v].stolen_from += 1;            /* PLANT P5: plain increment by a thief */
#else
      XADD(&c->W[v].stolen_from, 1, RLX);
#endif
      return (ren_task *)x;
    }
  }
  return NULL;                           /* EMPTY and ABORT both move on */
}

int32_t ren_run(ren_core *c, int32_t w, uint32_t steps) {
  worker *W = &c->W[w];
#if REN_C_DEBUG
  if (W->stack_lo) {
    char here;
    if ((char *)&here < (char *)W->stack_lo || (char *)&here >= (char *)W->stack_lo + W->stack_size) {
      fprintf(stderr, "ren c: ren_run(worker %d) called off the thread bound by ren_thread_init\n", w);
      abort();
    }
  }
  W->drained = false;
  W->runs++;
#endif
  if (LD(&c->killed, ACQ)) return REN_FINISHED;
  if (XCHG(&W->parked, 0, AR) == 1) XADD(&c->idle, -1, RLX);
#if REN_PLANT == 5
  W->stolen_seen = W->stolen_from;         /* PLANT P5: plain read by the owner */
#else
  W->stolen_seen = LD(&W->stolen_from, RLX);
#endif
  if (LD(&c->done, ACQ)) return REN_FINISHED;
  drain_inbox(c, w);
  uint32_t n = 0;
  for (;;) {
    if (LD(&c->done, ACQ) || LD(&c->killed, ACQ)) return REN_FINISHED;
    if (n == steps) return REN_RUNNING;
    ren_task *t = NULL;
    uint64_t s = LD(&W->steps, RLX);
    if (s != 0 && s % c->K == 0 && W->last_poll != s) {   /* §2.8: the world poll on a count */
      W->last_poll = s;
      drain_inbox(c, w);
      t = inj_pop(c);
    }
    if (!t) t = (ren_task *)dq_take(&W->dq);
    if (!t) t = inj_pop(c);
    if (!t) t = steal_any(c, w);
    if (!t) {
      if (drain_inbox(c, w) > 0) continue;
      if (try_park(c, w)) return LD(&c->done, ACQ) ? REN_FINISHED : REN_IDLE;
      continue;
    }
    run_task(c, w, t);
    n++;
  }
}

void ren_spawn(ren_ctx *cx, ren_task *t) {
  ren_core *c = cx->core;
  int32_t w = cx->worker;
  t->id = ((uint32_t)w << 24) | ++c->W[w].spawn_seq;
  ST(task_sched(t), (uint64_t)T_QUEUED, RLX);
  XADD(&c->live, 1, RLX);                /* the spawner is live, so live can't reach 0 meanwhile */
  dq_push(&c->W[w].dq, (uintptr_t)t);
  wake_one(c, w);
}

void ren_thread_init(ren_core *c, int32_t w, void *stack_lo, size_t stack_size) {
  c->W[w].stack_lo = stack_lo;
  c->W[w].stack_size = stack_size;
}

bool ren_tick(ren_ctx *cx) { cx->points += 1; return cx->points >= cx->core->B; }
bool ren_cancelled(ren_ctx *cx) { return LD(&cx->core->stopping, ACQ) != 0; }
int32_t ren_ctx_worker(ren_ctx *cx) { return cx->worker; }
uint64_t ren_progress(ren_core *c, int32_t w) { return LD(&c->W[w].steps, RLX); }
