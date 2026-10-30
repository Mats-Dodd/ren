// X3c (from X3b): shared declarations for the runtime (rt.c) and the request path (path.c).
//
// X3's server model (x3/), extended with two ways for a request on one
// worker to reach a shared, stateful instance (the memtable) under
// `per_core`:
//   (H) home-core shipping: the memtable lives on one worker, its home. An
//       operation from another worker is a D.Call record pushed to the home
//       worker's inbound ring; the calling task suspends until the reply. A
//       request on the home worker calls the operation directly.
//   (M) moving the task: for an `at` block the task hops to the home worker,
//       runs the block's operations there directly, and hops back.
//   (P2) adaptive parking: X3's parking take, but spinning while the holder
//       is running (bounded), with workers that spin before sleeping and the
//       1 ms hand-off on.
// and X3's references: plain parking (park, handoff) and thread locks
// (os_unfair_lock, TTAS spin) with plain callers.
//
// Two compilations of path.c, one program:
//   SUSP defined   (a) every function from the request to the operation is
//                  suspending-coloured, in X1's register convention.
//   SUSP undefined (b) the take is a thread lock; the callers stay plain C.
#pragma once
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#define LIKELY(x) __builtin_expect(!!(x), 1)
#define UNLIKELY(x) __builtin_expect(!!(x), 0)
#define R16(x) (((x) + 15u) & ~15u)

/* ---------- the register convention (x1/ren_reg.c) ---------- */
typedef struct task task;
typedef struct frame frame;
typedef struct { uintptr_t st; uint64_t v; } ren_ret;
enum { DONE = 0, PENDING = 1 };
typedef ren_ret (*ren_resume)(task *, frame *, char *sp, uint64_t in);
struct frame {
  ren_resume resume;
  frame *parent;
  uint32_t state, flags;
  char *sp;
};
#define SEG 512
struct task {
  task *next;
  frame *top;
  char *limit;
  int home;            /* the worker that owns this task (its connection) */
  int cur;             /* the worker it is on now (differs only inside a moved `at` block) */
  uint8_t granted;     /* (a) the instance was handed to this task */
  uint8_t waiting;     /* (a) a wait is in progress (wait_start valid) */
  uint64_t wait_start; /* ticks: first failed attempt of the current take */
  uint64_t reply;      /* (H) the reply's value, written by the reply's consumer */
  uint32_t seq;        /* X3c: this task's operation count (contract 1's check) */
  uint16_t inflight;   /* X3c: shipped calls and posts not yet answered */
  uint8_t drain_wait;  /* X3c: the task ended and waits for its posts' acks */
  uint64_t op_t0;      /* X3c: the current operation's start (ticks) */
  _Alignas(16) char frames[SEG];
};
#define BUMP(T, SP, SIZE) (UNLIKELY((SP) + (SIZE) > (T)->limit) ? (abort(), (char *)0) : (SP) + (SIZE))

/* ---------- the shared instance's lock word ---------- */
enum { L_LOCKED = 1, L_WAITERS = 2, L_HOME = 4 }; /* L_HOME: (HY) the home holds it */
typedef struct {
  _Alignas(128) _Atomic uint32_t state; /* (a): L_LOCKED | L_WAITERS; (b) spin: 0/1 */
  uint32_t os_lock;                     /* (b) os_unfair_lock storage */
  _Atomic int32_t holder;               /* (P2) worker of the holder */
  _Atomic int32_t lw_last;              /* X3c: the last core to RMW `state` (same line: an estimate) */
  _Alignas(128) _Atomic uint32_t qlock; /* (a) protects the waiter queue */
  task *wq_head, *wq_tail;
} inst_lock;

/* ---------- strategies ---------- */
enum { S_PARK, S_HANDOFF, S_P2, S_SHIP, S_SHIPDED, S_MOVE, S_MOVEDED, S_HY, S_UNFAIR, S_SPIN, S_N };
extern int strategy;
#define SHIPPING (strategy >= S_SHIP && strategy <= S_HY)
#define HYBRID (strategy == S_HY)
#define MOVING (strategy == S_MOVE || strategy == S_MOVEDED)
#define DEDICATED (strategy == S_SHIPDED || strategy == S_MOVEDED)
#define HOME 0 /* the memtable's home worker */

/* ---------- the "world" and the handler state, in rt.c ---------- */
typedef struct { uint64_t op, key, val; } request; /* op: 0 get, 1 put, 2 local work */
extern _Atomic int stop_flag;
extern inst_lock mt_lock;
extern int nops;                           /* OPS: shared operations a request makes (an `at` block) */
extern _Thread_local int cur_worker;
uint64_t now_ticks(void);
uint64_t parse_key(const request *r);      /* plain: ~60 ns of hashing */
uint64_t key_at(uint64_t k, uint64_t i);   /* plain: the block's i-th key */
bool validate(uint64_t key, uint64_t val); /* plain */
void mt_insert(uint64_t key, uint64_t val);/* plain: the table, under the take */
uint64_t mt_lookup(uint64_t key);          /* plain */
void hold_work(void);                      /* plain: the long-hold knob */
uint64_t local_work(const request *r);     /* plain: a request that never touches the table */
uint64_t encode_resp(uint64_t v);          /* plain */
void respond(task *t, uint64_t resp);      /* plain: accounts the request */
bool next_request(task *t, request *r);    /* false: stop; true: a request */
bool recv_would_block(task *t);            /* every 8th recv suspends */
void requeue(task *t);                     /* push on its current worker's run queue */
extern int fast;                           /* FAST=1: drain rings at every point; resumed tasks run next */
void drain(void);
static inline void point(void) { if (fast && SHIPPING) drain(); }
/* (a) parking */
bool take_slow(task *t, inst_lock *l);     /* spin, then park; false = parked */
void release_slow(inst_lock *l);
void note_wait_done(task *t);
/* (H) shipping: false = the ring is full (wait for room) */
bool ship_call(task *t, uint64_t op, uint64_t k, uint64_t v, uint32_t seq);
/* (M) moving: the worker pushes the task to `to` once it has suspended */
void hop(task *t, int to);
/* X3c (HY) the hybrid: how one operation from t reaches the instance */
enum { HY_DIRECT, HY_INPLACE, HY_SHIP };
int hy_enter(task *t);                     /* HY_INPLACE: run it, then hy_release() */
void hy_release(void);
extern int post;                           /* POST=1: a shipped put is posted (the task doesn't wait) */
#define POST_MAX 3                         /* posts in flight a task (16 x (3 + 1) <= a ring's 64) */
bool ship_post(task *t, uint64_t k, uint64_t v, uint32_t seq);
void op_exec(task *t, uint32_t seq);       /* under the instance: contract 1's check, migrations */
void op_begin(task *t);
void op_end(task *t);                      /* records the operation's wait */
void count_op(int how);                    /* HY_DIRECT, HY_INPLACE, HY_SHIP */
bool must_wait_acks(task *t);              /* a task about to end waits for its posts' acks */
void note_ring_full(void);
/* (b) */
void thread_take(inst_lock *l);
void thread_release(inst_lock *l);

static inline void lw_touch(inst_lock *l) { /* X3c: estimate the lock line's moves */
  extern _Thread_local uint64_t lw_moves;
  if (atomic_load_explicit(&l->lw_last, memory_order_relaxed) != cur_worker) {
    atomic_store_explicit(&l->lw_last, cur_worker, memory_order_relaxed);
    lw_moves++;
  }
}
static inline bool take_fast(inst_lock *l) {
  uint32_t s = atomic_load_explicit(&l->state, memory_order_relaxed);
  if (s & L_LOCKED) return false;
  bool ok = atomic_compare_exchange_strong_explicit(&l->state, &s, s | L_LOCKED, memory_order_acquire,
                                                    memory_order_relaxed);
  lw_touch(l);
  if (ok && strategy == S_P2) atomic_store_explicit(&l->holder, cur_worker, memory_order_relaxed);
  return ok;
}
static inline void release(inst_lock *l) {
  uint32_t s = L_LOCKED;
  lw_touch(l);
  if (LIKELY(atomic_compare_exchange_strong_explicit(&l->state, &s, 0, memory_order_release,
                                                     memory_order_relaxed)))
    return;
  release_slow(l);
}

ren_ret serve(task *t, frame *f, char *sp, uint64_t in); /* path.c: the task body */
