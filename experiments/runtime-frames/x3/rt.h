// X3: shared declarations for the runtime (rt.c) and the request path (path.c).
//
// Two compilations of path.c, one program:
//   SUSP defined   (a) a take of the shared memtable is a scheduling point:
//                  every function from the request to `put` is suspending-
//                  coloured, in X1's register convention. The take is a CAS;
//                  on contention it spins about 1 us, then parks the task.
//   SUSP undefined (b) the take is a thread lock (os_unfair_lock, or a TTAS
//                  spin lock); the callers stay plain C.
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
  int home;            /* worker index */
  uint8_t granted;     /* (a) the instance was handed to this task */
  uint8_t waiting;     /* (a) a wait is in progress (wait_start valid) */
  uint64_t wait_start; /* ticks: first failed attempt of the current take */
  _Alignas(16) char frames[SEG];
};
#define BUMP(T, SP, SIZE) (UNLIKELY((SP) + (SIZE) > (T)->limit) ? (abort(), (char *)0) : (SP) + (SIZE))

/* ---------- the shared instance's lock word ---------- */
enum { L_LOCKED = 1, L_WAITERS = 2 };
typedef struct {
  _Alignas(128) _Atomic uint32_t state; /* (a): L_LOCKED | L_WAITERS; (b) spin: 0/1 */
  uint32_t os_lock;                     /* (b) os_unfair_lock storage */
  _Alignas(128) _Atomic uint32_t qlock; /* (a) protects the waiter queue */
  task *wq_head, *wq_tail;
} inst_lock;

/* ---------- the "world" and the handler state, in rt.c ---------- */
typedef struct { uint64_t op, key, val; } request; /* op: 0 get, 1 put */
extern _Atomic int stop_flag;
extern inst_lock mt_lock;
extern int strategy; /* 0 park, 1 handoff, 2 unfair, 3 spin */
uint64_t now_ticks(void);
uint64_t parse_key(const request *r);      /* plain: ~60 ns of hashing */
bool validate(uint64_t key, uint64_t val); /* plain */
void mt_insert(uint64_t key, uint64_t val);/* plain: the table, under the take */
uint64_t mt_lookup(uint64_t key);          /* plain */
void hold_work(void);                      /* plain: the long-hold knob */
uint64_t encode_resp(uint64_t v);          /* plain */
void respond(task *t, uint64_t resp);      /* plain: accounts the request */
bool next_request(task *t, request *r);    /* false: stop; true: a request */
bool recv_would_block(task *t);            /* every 8th recv suspends */
void requeue(task *t);                     /* push on its home run queue */
/* (a) */
bool take_slow(task *t, inst_lock *l);     /* spin, then park; false = parked */
void release_slow(inst_lock *l);
void note_wait_done(task *t);
/* (b) */
void thread_take(inst_lock *l);
void thread_release(inst_lock *l);

static inline bool take_fast(inst_lock *l) {
  uint32_t s = atomic_load_explicit(&l->state, memory_order_relaxed);
  return !(s & L_LOCKED) &&
         atomic_compare_exchange_strong_explicit(&l->state, &s, s | L_LOCKED, memory_order_acquire,
                                                 memory_order_relaxed);
}
static inline void release(inst_lock *l) {
  uint32_t s = L_LOCKED;
  if (LIKELY(atomic_compare_exchange_strong_explicit(&l->state, &s, 0, memory_order_release,
                                                     memory_order_relaxed)))
    return;
  release_slow(l);
}

ren_ret serve(task *t, frame *f, char *sp, uint64_t in); /* path.c: the task body */
