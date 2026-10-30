/* dq.h: the Chase-Lev deque of SPEC §A (Lê et al., PPoPP 2013, Fig. 1),
   signed indices, growth by doubling, old rings retired until free. */
#ifndef REN_C_DQ_H
#define REN_C_DQ_H
#include "atom.h"

/* SPEC §A.3 says top/bottom and every local copy are signed int64_t
   (P2 is the unsigned variant; it is not planted in this build). */
#if REN_PLANT == 2
typedef uint64_t dq_i;       /* PLANT P2: unsigned indices (size_t as in the paper) */
typedef au64 adq_i;
#else
typedef int64_t dq_i;
typedef a64 adq_i;
#endif

typedef struct dq_ring {
  int64_t cap;               /* a power of two */
  aptr slot[];               /* elements: relaxed atomics of pointer width */
} dq_ring;

typedef struct dq {
  adq_i top;                 /* thieves CAS it */
  char pad0[64 - sizeof(adq_i)];
  adq_i bottom;              /* the owner writes it */
  char pad1[64 - sizeof(adq_i)];
  aptr array;                /* dq_ring * */
  dq_ring **retired;         /* plain, owner only */
  size_t nretired, capretired;
} dq;

#define DQ_EMPTY ((uintptr_t)0)
#define DQ_ABORT (~(uintptr_t)0)

void dq_init(dq *q, uint32_t log2cap);
void dq_destroy(dq *q);
void dq_push(dq *q, uintptr_t x);           /* owner */
uintptr_t dq_take(dq *q);                   /* owner: item or DQ_EMPTY */
uintptr_t dq_steal(dq *q);                  /* any: item, DQ_EMPTY or DQ_ABORT */
int64_t dq_size_hint(dq *q);                /* any: ld(bottom, ACQ) - ld(top, ACQ) */
#endif
