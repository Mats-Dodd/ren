/* core.h: the C core's private data (SPEC §B.1). Shared by core.c (op
   table, world calls, replies, cancel, stop/kill/free), sched.c (the run
   loop, task states, park/wake, injector, steal) and journal.c. */
#ifndef REN_C_CORE_H
#define REN_C_CORE_H
#include "atom.h"
#include "dq.h"

#ifndef NDEBUG
#define REN_C_DEBUG 1
#endif

/* op-slot states (B.3) */
enum { S_FREE = 0, S_ISSUED = 1, S_PULLED = 2, S_CANCEL_UNPULLED = 3, S_CANCEL_PULLED = 4, S_REPLIED = 5 };
/* task scheduling word (B.2) */
enum { T_QUEUED = 1, T_RUNNING = 2, T_PARKED = 3, T_DONE = 4, T_NOTIFIED = 8 };

typedef struct op {
  aptr next;                 /* MPSC link (inbox); also the outbox FIFO link (owner) */
  uint32_t slot, gen;
  uint16_t home;
  bool had_cancel;
  ren_task *task;
  ren_await *aw;
  ren_call call;             /* call.body -> &body */
  ren_io_body body;
  uint32_t reply_state;
  ren_io_result reply;
} op;

typedef struct cnode {
  aptr next;
  uint64_t id;
} cnode;

typedef struct slot {
  au64 word;                 /* gen:32 (high) | state:32 (low) */
  op *o;                     /* plain: written by home before the REL store of ISSUED */
} slot;

struct ren_ctx {
  ren_core *core;
  int32_t worker;
  uint32_t points;
  ren_task *cur;
};

typedef struct fifo { void *head, *tail; } fifo;   /* owner-only FIFOs, linked through ->next */

typedef struct worker {
  dq dq;                     /* top/bottom on their own lines */
  a64 parked;                /* 1 = returned IDLE and not yet woken */
  au64 steps;                /* st RLX by owner, ld RLX by ren_progress */
#if REN_PLANT == 5
  uint64_t stolen_from;      /* PLANT P5: a plain u64; thieves += 1 */
#else
  au64 stolen_from;          /* thieves xadd RLX */
#endif
  aptr inbox;                /* MPSC stack of op* */
  aptr remote;               /* MPSC stack of cnode* */
  char pad[64];
  /* owner-only from here */
  uint64_t stolen_seen;
  fifo cancels;              /* cnode */
  fifo outbox;               /* op */
  uint32_t *free_stk; uint32_t nfree;
  uint64_t rng;
  uint32_t spawn_seq;
  uint64_t last_poll;
  uint64_t cancel_done;      /* on_cancel_done's plain counter */
  bool drained;              /* debug */
  uint64_t runs;             /* debug */
  void *stack_lo; size_t stack_size;
  ren_ctx cx;
  char pad2[64];
} worker;

typedef struct injector {
  a64 lock;
  ren_task *head, *tail;     /* plain, under lock; linked through core[1] */
  a64 len;
} injector;

struct ren_core {
  ren_config cfg;
  ren_host host;
  void *hostp;
  int32_t nw;
  uint32_t B, K, S;
  worker *W;
  slot *slots;               /* nw * S */
  injector inj;
  char pad0[64];
  a64 live;
  a64 stopping, killed, done;
  a64 idle;
  char pad1[64];
};

/* journal.c */
void j_header(ren_core *c);
void j_call(ren_core *c, int32_t w, const ren_call *k);
void j_deliver(ren_core *c, int32_t w, uint64_t id, uint32_t state, const ren_io_result *r,
               const uint8_t *in, uint32_t in_len);
void j_cancel(ren_core *c, int32_t by, uint64_t id, uint32_t how);
void j_release(ren_core *c, uint64_t id, uint32_t why);
void j_end(ren_core *c, int32_t w, uint32_t how);
uint64_t ren_c_fnv1a(const uint8_t *p, uint64_t n);

/* sched.c */
void inj_push(ren_core *c, ren_task *t);
ren_task *inj_pop(ren_core *c);
void wake_worker(ren_core *c, int32_t v);
void wake_one(ren_core *c, int32_t w);
void wake_all(ren_core *c);
void sched_notify(ren_core *c, int32_t w, ren_task *t);

/* core.c */
size_t drain_inbox(ren_core *c, int32_t w);

static inline au64 *task_sched(ren_task *t) { return ASU64(&t->core[0]); }
static inline uint32_t next_gen(uint32_t g) { return g == UINT32_MAX ? 1u : g + 1u; }
#endif
