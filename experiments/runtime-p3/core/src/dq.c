/* dq.c: SPEC §A.3, line for line. */
#include "dq.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static dq_ring *ring_new(int64_t cap) {
  dq_ring *r = malloc(sizeof(dq_ring) + (size_t)cap * sizeof(aptr));
  if (!r) { fputs("ren c: deque ring: out of memory\n", stderr); abort(); }
  r->cap = cap;
  for (int64_t i = 0; i < cap; i++) ST(&r->slot[i], (uintptr_t)0, RLX);
  return r;
}

void dq_init(dq *q, uint32_t log2cap) {
  memset(q, 0, sizeof *q);
  ST(&q->top, 0, RLX);
  ST(&q->bottom, 0, RLX);
  ST(&q->array, (uintptr_t)ring_new((int64_t)1 << log2cap), RLX);
}

void dq_destroy(dq *q) {
  free((dq_ring *)LD(&q->array, RLX));
  for (size_t i = 0; i < q->nretired; i++) free(q->retired[i]);
  free(q->retired);
  q->retired = NULL; q->nretired = q->capretired = 0;
}

static dq_ring *grow(dq *q, dq_ring *a, dq_i t, dq_i b) {
  dq_ring *n = ring_new(2 * a->cap);
  for (dq_i i = t; i < b; i++)
    ST(&n->slot[i & (n->cap - 1)], LD(&a->slot[i & (a->cap - 1)], RLX), RLX);
  if (q->nretired == q->capretired) {
    q->capretired = q->capretired ? 2 * q->capretired : 8;
    q->retired = realloc(q->retired, q->capretired * sizeof *q->retired);
    if (!q->retired) { fputs("ren c: deque: out of memory\n", stderr); abort(); }
  }
  q->retired[q->nretired++] = a;          /* never freed while thieves may read it */
  ST(&q->array, (uintptr_t)n, REL);        /* pairs with steal's ACQ load of array */
  return n;
}

void dq_push(dq *q, uintptr_t x) {
  dq_i b = LD(&q->bottom, RLX);
  dq_i t = LD(&q->top, ACQ);
  dq_ring *a = (dq_ring *)LD(&q->array, RLX);
  if (b - t > a->cap - 1) a = grow(q, a, t, b);
  ST(&a->slot[b & (a->cap - 1)], x, RLX);
  FENCE(REL);
#if REN_C_TSAN
  ST(&q->bottom, b + 1, REL);   /* TSan only: the same edge, in a form TSan sees (atom.h) */
#else
  ST(&q->bottom, b + 1, RLX);
#endif
}

uintptr_t dq_take(dq *q) {
  dq_i b = LD(&q->bottom, RLX) - 1;        /* -1 on a fresh deque: fine, signed */
  dq_ring *a = (dq_ring *)LD(&q->array, RLX);
  ST(&q->bottom, b, RLX);
#if REN_PLANT == 1
  FENCE(AR);                               /* PLANT P1: was fence(SC) */
#else
  FENCE(SC);
#endif
  dq_i t = LD(&q->top, RLX);
  if (t <= b) {
    uintptr_t x = LD(&a->slot[b & (a->cap - 1)], RLX);
    if (t == b) {                          /* the last element: race the thieves */
      if (!CAS(&q->top, &t, t + 1, SC, RLX)) x = DQ_EMPTY;
      ST(&q->bottom, b + 1, RLX);
    }
    return x;
  }
  ST(&q->bottom, b + 1, RLX);
  return DQ_EMPTY;
}

uintptr_t dq_steal(dq *q) {
  dq_i t = LD(&q->top, ACQ);
#if REN_PLANT == 1
  FENCE(AR);                               /* PLANT P1: was fence(SC) */
#else
  FENCE(SC);
#endif
  dq_i b = LD(&q->bottom, ACQ);
  if (t < b) {
    dq_ring *a = (dq_ring *)LD(&q->array, ACQ);   /* the paper: consume */
    uintptr_t x = LD(&a->slot[t & (a->cap - 1)], RLX);
    if (!CAS(&q->top, &t, t + 1, SC, RLX)) return DQ_ABORT;
    return x;
  }
  return DQ_EMPTY;
}

int64_t dq_size_hint(dq *q) {
  dq_i b = LD(&q->bottom, ACQ);
  dq_i t = LD(&q->top, ACQ);
  return (int64_t)(b - t);
}

/* ---- the ren_dq_* test ABI (slice.h §9): the same code ---- */
struct ren_dq { dq q; };
ren_dq *ren_dq_new(uint32_t log2_cap) {
  ren_dq *d = aligned_alloc(64, (sizeof(ren_dq) + 63) & ~(size_t)63);
  if (!d) abort();
  dq_init(&d->q, log2_cap);
  return d;
}
void ren_dq_push(ren_dq *d, uint64_t v) { dq_push(&d->q, (uintptr_t)v); }
uint64_t ren_dq_take(ren_dq *d) { return (uint64_t)dq_take(&d->q); }
uint64_t ren_dq_steal(ren_dq *d) {
  uintptr_t x = dq_steal(&d->q);
  return x == DQ_ABORT ? REN_DQ_ABORT : (uint64_t)x;
}
void ren_dq_free(ren_dq *d) { dq_destroy(&d->q); free(d); }
