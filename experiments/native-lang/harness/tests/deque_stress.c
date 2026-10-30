/* deque_stress.c: the core's Chase-Lev deque (SPEC §A) through ren_dq_*.
   deque_stress empty            take/steal on a fresh deque (P2)
   deque_stress lifo             growth from a 4-slot ring; LIFO order
   deque_stress stress [R] [N]   owner push/take + 3 thieves, R rounds of N
                                 items; every item exactly once (P1)
   Exit 0 = pass. */
#include "../slice.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define EXPECT(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

static void t_empty(void) {
  ren_dq *q = ren_dq_new(2);
  EXPECT(ren_dq_take(q) == REN_DQ_EMPTY);       /* Wingo 2022: 0 - 1 with unsigned indices */
  EXPECT(ren_dq_take(q) == REN_DQ_EMPTY);
  EXPECT(ren_dq_steal(q) == REN_DQ_EMPTY);
  ren_dq_push(q, 1);
  EXPECT(ren_dq_take(q) == 1);
  EXPECT(ren_dq_take(q) == REN_DQ_EMPTY);
  EXPECT(ren_dq_steal(q) == REN_DQ_EMPTY);
  ren_dq_push(q, 2);
  EXPECT(ren_dq_steal(q) == 2);
  EXPECT(ren_dq_take(q) == REN_DQ_EMPTY);
  ren_dq_free(q);
}

static void t_lifo(void) {
  ren_dq *q = ren_dq_new(2);
  for (uint64_t i = 1; i <= 10000; i++) ren_dq_push(q, i);
  for (uint64_t i = 10000; i >= 1; i--) { uint64_t x = ren_dq_take(q); if (x != i) { EXPECT(x == i); break; } }
  EXPECT(ren_dq_take(q) == REN_DQ_EMPTY);
  for (uint64_t i = 1; i <= 1000; i++) ren_dq_push(q, i);
  for (uint64_t i = 1; i <= 1000; i++) { uint64_t x = ren_dq_steal(q); if (x != i) { EXPECT(x == i); break; } }
  ren_dq_free(q);
}

typedef struct { ren_dq *q; int32_t *seen; int64_t owner_done; int64_t steals; } shared;
static void see(shared *s, uint64_t x) { ren_xadd32(&s->seen[x], 1, REN_MO_RELAXED); }
static void *thief(void *p) {
  shared *s = p;
  int64_t n = 0;
  for (;;) {
    uint64_t x = ren_dq_steal(s->q);
    if (x == REN_DQ_ABORT) continue;
    if (x == REN_DQ_EMPTY) { if (ren_ld64(&s->owner_done, REN_MO_ACQUIRE)) break; continue; }
    see(s, x); n++;
  }
  ren_xadd64(&s->steals, n, REN_MO_RELAXED);
  return NULL;
}
static void t_stress(int rounds, long n) {
  long dup = 0, lost = 0, steals = 0;
  for (int r = 0; r < rounds; r++) {
    shared s;
    memset(&s, 0, sizeof s);
    s.q = ren_dq_new(1);
    s.seen = calloc((size_t)n + 1, sizeof(int32_t));
    pthread_t th[3];
    for (int i = 0; i < 3; i++) pthread_create(&th[i], NULL, thief, &s);
    uint64_t x;
    long i = 1;
    /* phase A: a deque of one or two items, the take/steal race on the last element */
    for (; i <= n / 2; i++) {
      ren_dq_push(s.q, (uint64_t)i);
      if (i & 1) { if ((x = ren_dq_take(s.q)) != REN_DQ_EMPTY) see(&s, x); }
    }
    /* phase B: bursts that make the ring grow while thieves read it */
    while (i <= n) {
      for (int k = 0; k < 64 && i <= n; k++, i++) ren_dq_push(s.q, (uint64_t)i);
      for (int k = 0; k < 32; k++) if ((x = ren_dq_take(s.q)) != REN_DQ_EMPTY) see(&s, x);
    }
    while ((x = ren_dq_take(s.q)) != REN_DQ_EMPTY) see(&s, x);
    ren_st64(&s.owner_done, 1, REN_MO_RELEASE);
    for (int k = 0; k < 3; k++) pthread_join(th[k], NULL);
    for (long k = 1; k <= n; k++) { if (s.seen[k] > 1) dup++; if (s.seen[k] == 0) lost++; }
    steals += s.steals;
    free(s.seen);
    ren_dq_free(s.q);
  }
  printf("stress: rounds=%d n=%ld steals=%ld duplicated=%ld lost=%ld\n", rounds, n, steals, dup, lost);
  EXPECT(dup == 0 && lost == 0);
}

int main(int argc, char **argv) {
  const char *m = argc > 1 ? argv[1] : "all";
  if (!strcmp(m, "empty") || !strcmp(m, "all")) t_empty();
  if (!strcmp(m, "lifo") || !strcmp(m, "all")) t_lifo();
  if (!strcmp(m, "stress") || !strcmp(m, "all"))
    t_stress(argc > 2 ? atoi(argv[2]) : 20, argc > 3 ? atol(argv[3]) : 200000);
  printf("deque_stress %s: %s\n", m, fails ? "FAIL" : "ok");
  return fails != 0;
}
