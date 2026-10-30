/* slice.h: the single source of truth for the native-lang experiment.

   Everything the three cores (c/, rust/, zig/) and the shared harness
   agree on is here, and nowhere else:
     1. portable atomics (clang/gcc builtins; an x86-64 asm shim for tcc
        0.9.27, which has neither <stdatomic.h> nor __atomic_*)
     2. ren_obj with the signed rc protocol; ren_array; the hot path
     3. the task frame (emitted C: frame struct + resume fn pointer)
     4. the world-call wire: ren_call, ren_reply, op codes, bodies
     5. the host ABI: ren_host, ren_config and the NINE functions of
        research/runtime/SYNTHESIS.md §3
     6. the emitted-code ABI: what a resume function may call
     7. the journal record format (= ren_call/ren_reply wire)
     8. the driver-entry ABI each language exports (ren_drv_*)
     9. the deque test ABI (ren_dq_*) and the layout table
   SPEC.md says what each function must do, with every atomic ordering.

   Rust takes these layouts through bindgen and Zig through
   `zig translate-c`; hand-mirroring is not allowed (SPEC.md §0).
   Static inline functions are for C callers only: bindgen skips them and
   the cores must not need them (they call the exported wrappers
   ren_rc_dup/ren_rc_drop in harness/rt.c instead).

   All integers are fixed-width. No bitfields, no unions, no flexible
   arrays, no statement-expression macros (translate-c cannot take them,
   research/native-lang/l3-zig.md §2.5). */

#ifndef REN_SLICE_H
#define REN_SLICE_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REN_SLICE_VERSION 1u

/* ===================================================================
   1. Atomics. Memory orders are named exactly as C11 names them.
   =================================================================== */

#define REN_MO_RELAXED 0
#define REN_MO_CONSUME 1
#define REN_MO_ACQUIRE 2
#define REN_MO_RELEASE 3
#define REN_MO_ACQ_REL 4
#define REN_MO_SEQ_CST 5

#if defined(__TINYC__)
/* tcc 0.9.27: no __atomic builtins, no <stdatomic.h>, no _Thread_local
   (all three checked on cloud, 2026-10-30). x86-64 TSO: aligned plain
   loads are acquire and plain stores are release; only a seq_cst store
   and a seq_cst fence need an instruction (xchg / mfence); every RMW is
   a locked instruction, which is seq_cst. The "memory" clobber is the
   compiler barrier. Orders below seq_cst are therefore conservative. */
#if !defined(__x86_64__)
#error "slice.h: the tcc atomics shim is x86-64 only"
#endif
static inline void ren_cbar(void) { __asm__ volatile("" ::: "memory"); }
static inline void ren_fence(int mo) {
  if (mo == REN_MO_SEQ_CST) __asm__ volatile("mfence" ::: "memory");
  else ren_cbar();
}
static inline int64_t ren_ld64(const int64_t *p, int mo) {
  int64_t v; (void)mo; ren_cbar(); v = *(volatile const int64_t *)p; ren_cbar(); return v;
}
static inline void ren_st64(int64_t *p, int64_t v, int mo) {
  if (mo == REN_MO_SEQ_CST) { __asm__ volatile("xchgq %0, %1" : "+r"(v), "+m"(*p) :: "memory"); }
  else { ren_cbar(); *(volatile int64_t *)p = v; ren_cbar(); }
}
static inline int64_t ren_xadd64(int64_t *p, int64_t v, int mo) {
  (void)mo; __asm__ volatile("lock; xaddq %0, %1" : "+r"(v), "+m"(*p) :: "memory"); return v;
}
static inline int64_t ren_xchg64(int64_t *p, int64_t v, int mo) {
  (void)mo; __asm__ volatile("xchgq %0, %1" : "+r"(v), "+m"(*p) :: "memory"); return v;
}
static inline bool ren_cas64(int64_t *p, int64_t *expect, int64_t desired, int mo_ok, int mo_fail) {
  int64_t prev = *expect; unsigned char ok; (void)mo_ok; (void)mo_fail;
  __asm__ volatile("lock; cmpxchgq %3, %1\n\tsete %2"
                   : "+a"(prev), "+m"(*p), "=q"(ok) : "r"(desired) : "memory");
  *expect = prev; return ok != 0;
}
static inline int32_t ren_ld32(const int32_t *p, int mo) {
  int32_t v; (void)mo; ren_cbar(); v = *(volatile const int32_t *)p; ren_cbar(); return v;
}
static inline void ren_st32(int32_t *p, int32_t v, int mo) {
  if (mo == REN_MO_SEQ_CST) { __asm__ volatile("xchgl %0, %1" : "+r"(v), "+m"(*p) :: "memory"); }
  else { ren_cbar(); *(volatile int32_t *)p = v; ren_cbar(); }
}
static inline int32_t ren_xadd32(int32_t *p, int32_t v, int mo) {
  (void)mo; __asm__ volatile("lock; xaddl %0, %1" : "+r"(v), "+m"(*p) :: "memory"); return v;
}
static inline bool ren_cas32(int32_t *p, int32_t *expect, int32_t desired, int mo_ok, int mo_fail) {
  int32_t prev = *expect; unsigned char ok; (void)mo_ok; (void)mo_fail;
  __asm__ volatile("lock; cmpxchgl %3, %1\n\tsete %2"
                   : "+a"(prev), "+m"(*p), "=q"(ok) : "r"(desired) : "memory");
  *expect = prev; return ok != 0;
}
#define REN_LIKELY(x) (x)
#define REN_UNLIKELY(x) (x)
#else
/* clang, gcc, zig cc. The REN_* values equal __ATOMIC_* on all three. */
static inline void ren_fence(int mo) { __atomic_thread_fence(mo); }
static inline int64_t ren_ld64(const int64_t *p, int mo) { return __atomic_load_n(p, mo); }
static inline void ren_st64(int64_t *p, int64_t v, int mo) { __atomic_store_n(p, v, mo); }
static inline int64_t ren_xadd64(int64_t *p, int64_t v, int mo) { return __atomic_fetch_add(p, v, mo); }
static inline int64_t ren_xchg64(int64_t *p, int64_t v, int mo) { return __atomic_exchange_n(p, v, mo); }
static inline bool ren_cas64(int64_t *p, int64_t *e, int64_t d, int ok, int fail) {
  return __atomic_compare_exchange_n(p, e, d, false, ok, fail);
}
static inline int32_t ren_ld32(const int32_t *p, int mo) { return __atomic_load_n(p, mo); }
static inline void ren_st32(int32_t *p, int32_t v, int mo) { __atomic_store_n(p, v, mo); }
static inline int32_t ren_xadd32(int32_t *p, int32_t v, int mo) { return __atomic_fetch_add(p, v, mo); }
static inline bool ren_cas32(int32_t *p, int32_t *e, int32_t d, int ok, int fail) {
  return __atomic_compare_exchange_n(p, e, d, false, ok, fail);
}
#define REN_LIKELY(x) __builtin_expect(!!(x), 1)
#define REN_UNLIKELY(x) __builtin_expect(!!(x), 0)
#endif

/* The rc protocol's plain read (SPEC §E) is, by design, a C11 data race
   when the count is shared, and ThreadSanitizer reports it on every
   shared dup/drop. Under TSan only, read it with a relaxed atomic load
   (the same mov on x86-64), so TSan reports are about the cores. */
#if defined(__SANITIZE_THREAD__)
#define REN_TSAN_HARNESS 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define REN_TSAN_HARNESS 1
#endif
#endif
#ifdef REN_TSAN_HARNESS
#define REN_RC_READ(o) __atomic_load_n(&(o)->rc, __ATOMIC_RELAXED)
#else
#define REN_RC_READ(o) ((o)->rc)
#endif

/* ===================================================================
   2. Objects, the signed rc protocol, arrays, the hot path.
   =================================================================== */

/* rc > 0: counted plainly, owned by one thread.
   rc == 0: never freed (a literal).
   rc < 0: shared: -rc references, counted atomically
           (Lean's m_rc < 0; ren_rt.h:135). dup adds -1, drop adds +1;
           the drop that moves -1 to 0 frees. */
typedef struct ren_obj {
  int32_t rc;
  uint16_t tag;    /* REN_TAG_* */
  uint8_t nfields;
  uint8_t objs;
} ren_obj;

#define REN_TAG_PLAIN 1u
#define REN_TAG_ARRAY 2u
#define REN_TAG_TASK  3u

/* An array of Int (int64_t) with separately allocated storage, so
   growth reallocs [data] and the array object does not move. */
typedef struct ren_array {
  ren_obj obj;
  uint32_t len;
  uint32_t cap;
  int64_t *data;
} ren_array;

/* harness/rt.c: frees by tag (TASK: calls fin, then frees; ARRAY: frees
   data, then the object). Every implementation of drop calls this at 0. */
void ren_obj_free(ren_obj *o);
/* harness/rt.c: the C out-of-line grow used by the inline variant. */
void ren_array_grow_c(ren_array *a);

/* Exported, non-inline wrappers of the header's dup/drop, for cores
   written in Rust or Zig (and C) to count task frames "with the header's
   ren_dup/ren_drop" (harness/rt.c). */
void ren_rc_dup(ren_obj *o);
void ren_rc_drop(ren_obj *o);

/* The cold, shared (rc < 0) paths of the inline variant. Out of line,
   as Lean's lean_dec_ref_cold is. harness/rt.c. */
void ren_dup_shared(ren_obj *o);
void ren_drop_shared(ren_obj *o);

/* --- the hot path, variant (i): C static inline in this header --- */
static inline void ren_dup(ren_obj *o) {
  int32_t rc = REN_RC_READ(o);   /* owner thread: plain; see SPEC §E */
  if (REN_LIKELY(rc > 0)) o->rc = rc + 1;
  else if (rc != 0) ren_dup_shared(o);
}
static inline void ren_drop(ren_obj *o) {
  int32_t rc = REN_RC_READ(o);
  if (REN_LIKELY(rc > 1)) o->rc = rc - 1;
  else if (rc == 1) ren_obj_free(o);
  else if (rc != 0) ren_drop_shared(o);
}
static inline void ren_array_push(ren_array *a, int64_t v) {
  if (REN_UNLIKELY(a->len == a->cap)) ren_array_grow_c(a);
  a->data[a->len++] = v;
}

/* --- the hot path, variants (ii)-(vi): out of line, one per language.
   Same semantics as the inlines above (SPEC §E). harness/hot/hot_c.c is
   variant (ii); rust/ and zig/ export the same four symbols from their
   hot library. ren_hot_array_push = inline-style fast path + a call to
   ren_hot_array_grow when full. --- */
void ren_hot_dup(ren_obj *o);
void ren_hot_drop(ren_obj *o);
void ren_hot_array_push(ren_array *a, int64_t v);
void ren_hot_array_grow(ren_array *a);

/* ===================================================================
   3. Tasks: emitted-C heap frames.
   =================================================================== */

typedef struct ren_ctx ren_ctx;    /* per-worker context, owned by the core; opaque */
typedef struct ren_core ren_core;  /* opaque */
typedef struct ren_task ren_task;

/* What a resume function returns. */
#define REN_T_DONE  0   /* finished: the core drops its reference */
#define REN_T_PARK  1   /* wait for ren_notify (or a reply, which notifies) */
#define REN_T_YIELD 2   /* runnable; put me at the back (budget, REN_W_FULL) */

typedef int32_t (*ren_resume_fn)(ren_task *self, ren_ctx *cx);
typedef void (*ren_fin_fn)(ren_task *self); /* drop the frame's fields; called by ren_obj_free */

/* Every frame starts with this header (64 bytes). The emitted code owns
   pc and everything after the header; the core owns id and core[]. */
struct ren_task {
  ren_obj obj;          /* tag REN_TAG_TASK; rc < 0 (shared) from birth */
  uint32_t pc;          /* the emitted state machine's resume point */
  uint32_t id;          /* task path id; set by ren_spawn / ren_start */
  ren_resume_fn resume;
  ren_fin_fn fin;       /* may be NULL */
  uintptr_t core[4];    /* core-private: scheduling state, links. Zeroed at birth. */
};

/* A frame of [size] bytes (>= sizeof(ren_task)), zeroed, rc = -1 (one
   shared reference, which ren_spawn / main's return hands to the core). */
ren_task *ren_task_new(size_t size, ren_resume_fn resume, ren_fin_fn fin); /* harness/rt.c */

/* ===================================================================
   4. The world-call wire. One record format: this struct's, the
      journal's (§7) and the hosted wire's.
   =================================================================== */

#define REN_CALL   1u   /* a world call */
#define REN_CANCEL 2u   /* cancel the call [id]; no reply of its own */
#define REN_RETURN 3u   /* lease return; no reply (unused in the slice) */

#define REN_DONE      1u  /* reply state: the call happened; result in the body */
#define REN_CANCELLED 2u  /* reply state: the call had no effect */

typedef struct ren_call {
  uint64_t id;        /* slot:32 | generation:32 (SPEC §B.3); never 0 */
  uint16_t worker;    /* home worker: cancels are pulled there */
  uint16_t kind;      /* REN_CALL | REN_CANCEL | REN_RETURN */
  uint32_t lane;      /* 0 in the slice */
  uint32_t task;      /* the issuing task's id */
  uint32_t op;        /* dependency << 16 | operation (REN_OP_*) */
  uint32_t len;       /* body bytes: sizeof(ren_io_body) for REN_CALL, 0 otherwise */
  uint32_t _pad;
  const void *body;   /* -> ren_io_body; valid until the call's final reply is delivered */
} ren_call;

typedef struct ren_reply_t {
  uint64_t id;
  uint32_t state;     /* REN_DONE | REN_CANCELLED */
  uint32_t len;       /* sizeof(ren_io_result) */
  const void *body;   /* -> ren_io_result; read during ren_reply only */
} ren_reply_t;  /* the type; ren_reply is the function (C and Zig share one namespace) */

/* Operations: dependency << 16 | op. */
#define REN_DEP_CLOCK 1u
#define REN_DEP_FS    2u
#define REN_DEP_NET   3u
#define REN_OP_SLEEP_UNTIL 0x00010001u /* Clock.Call.SleepUntil{arg = t, CLOCK_MONOTONIC ns}; res 0 */
#define REN_OP_MONO_NOW    0x00010002u /* Clock.Call.Now (monotonic, ns); answered inline by answer_now; res = ns */
#define REN_OP_PIPE        0x00020001u /* res 0, a = read fd, b = write fd (both O_NONBLOCK|O_CLOEXEC) */
#define REN_OP_READ        0x00020002u /* fd, buf, len -> res = n | -errno; driver writes buf[0..n) */
#define REN_OP_WRITE       0x00020003u /* fd, buf, len -> res = n | -errno; driver reads buf[0..len) */
#define REN_OP_CLOSE       0x00020004u /* fd -> res 0 | -errno; the driver cancels the fd's ops first */
#define REN_OP_LISTEN      0x00030001u /* arg = port (0: any) on 127.0.0.1 -> res = fd, a = port */
#define REN_OP_ACCEPT      0x00030002u /* fd -> res = new fd (nonblocking) */
#define REN_OP_CONNECT     0x00030003u /* arg = port on 127.0.0.1 -> res = fd (connected) */

/* Every REN_CALL body. [buf] is a pointer as an integer; the journal
   writes it as 0 (pointers differ between runs). The buffer belongs to
   the driver from submit until the final reply (SPEC §C.1). */
typedef struct ren_io_body {
  int64_t fd;
  uint64_t len;
  uint64_t buf;
  int64_t arg;
} ren_io_body;

/* Every reply body. A cancelled call has res = -ECANCELED (-125). */
typedef struct ren_io_result {
  int64_t res;
  int64_t a;
  int64_t b;
} ren_io_result;

#define REN_ECANCELED 125

/* Where a waiting task finds its reply: it lives in the task's frame.
   [state] is accessed atomically (ren_ld32 acquire by the task; the
   core's release store after filling res). */
typedef struct ren_await {
  uint64_t id;          /* the call's id, set by ren_world */
  int32_t state;        /* 0 = pending, REN_DONE, REN_CANCELLED */
  uint32_t op;
  ren_io_result res;
} ren_await;

/* ===================================================================
   5. The host ABI: research/runtime/SYNTHESIS.md §3, nine functions.
   =================================================================== */

typedef struct ren_host {
  /* Leaf callbacks: none may call any ren_* function. */
  void (*wake)(void *host, int32_t worker);  /* any thread; sticky, idempotent; core calls it only for a parked worker */
  bool (*answer_now)(void *host, int32_t worker, const ren_call *call, ren_reply_t *out); /* worker thread; never blocks; may be NULL */
  void *(*pages)(void *host, size_t n);      /* may be NULL; unused by the slice */
  void (*journal)(void *host, int32_t worker, const void *entry, size_t len); /* NULL = not recording */
} ren_host;

#define REN_JPOL_INPUTS_INLINE 1u  /* reply bytes and inout bytes stored */
#define REN_JPOL_OUTPUTS_HASH  2u  /* call output bytes (WRITE) hashed, FNV-1a 64 */

typedef struct ren_config {
  int32_t workers;        /* what the host allows (1..64) */
  uint32_t budget_b;      /* §2.8 B: non-waiting scheduling points before a forced yield; 0 = 128 */
  uint32_t poll_k;        /* §2.8 K: inbox + injector checked every K steps; 0 = 61 */
  uint32_t op_slots;      /* op-table slots per worker; 0 = 4096 */
  uint32_t deque_log2;    /* initial ring size, log2; 0 = 8 */
  uint32_t journal_policy;/* REN_JPOL_* */
  const char *build_id;   /* journal header */
  void *user;             /* the workload's state; passed to main */
} ren_config;

/* main builds the root frame. (Deviation from §3's `int (*main)(void)`:
   a root that can suspend must be a frame; SPEC §B.0.) */
typedef ren_task *(*ren_main_fn)(const ren_config *cfg);

/* ren_run results */
#define REN_RUNNING 0
#define REN_IDLE    1
#define REN_FINISHED 2       /* §3's DONE (named apart from the reply state REN_DONE) */
#define REN_GREW    0x100    /* flag; never set by the slice (no pages) */
/* ren_reply results */
#define REN_ACCEPTED 0
#define REN_RELEASE  1

ren_core *ren_start(const ren_config *cfg, ren_main_fn main, const ren_host *host, void *hostp);
void      ren_thread_init(ren_core *c, int32_t worker, void *stack_lo, size_t stack_size);
int32_t   ren_run(ren_core *c, int32_t worker, uint32_t steps);
bool      ren_poll_call(ren_core *c, int32_t worker, ren_call *out);
int32_t   ren_reply(ren_core *c, const ren_reply_t *r);
void      ren_stop(ren_core *c);
void      ren_kill(ren_core *c);
void      ren_free(ren_core *c);
uint64_t  ren_progress(ren_core *c, int32_t worker);

/* ===================================================================
   6. The emitted-code ABI: called only from inside a resume function,
      on the worker thread running it, with its ren_ctx.
   =================================================================== */

/* Make [t] runnable. Consumes one reference to t (the core's, dropped
   when t returns REN_T_DONE). Sets t->id. */
void    ren_spawn(ren_ctx *cx, ren_task *t);
/* Wake [t] if parked, else leave a permit so its next REN_T_PARK
   requeues it. Idempotent. The caller must hold a reference to t. */
void    ren_notify(ren_ctx *cx, ren_task *t);

#define REN_W_NOW     0  /* answered inline: aw is filled; carry on */
#define REN_W_PENDING 1  /* return REN_T_PARK; aw->state becomes non-zero before the notify */
#define REN_W_FULL    2  /* no op slot: return REN_T_YIELD and try again */
/* Issue a world call. The body is copied; the buffer it names is not. */
int32_t ren_world(ren_ctx *cx, ren_task *self, ren_await *aw, uint32_t op, const ren_io_body *body);
/* Request cancellation of call [id] (any task, any worker; a stale id is
   a no-op). The waiter stays parked until the final reply (§2.2). */
void    ren_cancel(ren_ctx *cx, uint64_t id);
/* A scheduling point that did not wait. true: budget B is spent; the
   task must return REN_T_YIELD (it holds no instance in the slice). */
bool    ren_tick(ren_ctx *cx);
/* true once ren_stop was called: the task should finish. */
bool    ren_cancelled(ren_ctx *cx);
int32_t ren_ctx_worker(ren_ctx *cx);

/* ===================================================================
   7. The journal. Every entry = header + payload, little-endian,
      packed field by field (no struct padding on the wire). The core
      writes kinds 1-7 through ren_host.journal; drivers write 16-20.
   =================================================================== */

typedef struct ren_jent {    /* 24 bytes on the wire */
  uint32_t kind;
  uint32_t len;              /* payload bytes */
  int32_t worker;            /* -1: not a worker (ren_start, a driver thread) */
  uint32_t _pad;             /* 0 */
  uint64_t step;             /* ren_progress(worker) when written; 0 for worker -1 */
} ren_jent;

#define REN_JENT_BYTES 24u
/* core entries */
#define REN_J_HEADER  1u  /* u32 version, u32 workers, u32 B, u32 K, u32 policy, u32 n, u8 build_id[n] */
#define REN_J_CALL    2u  /* wire call (REN_JCALL_BYTES) + body[len] (buf = 0) + u64 out_hash */
#define REN_J_DELIVER 3u  /* u64 id, u32 state, u32 len, body[len], u32 in_len, in[in_len] */
#define REN_J_CANCEL  4u  /* u64 id, u32 how (REN_JC_*) */
#define REN_J_RELEASE 5u  /* u64 id, u32 why (REN_JR_*) */
#define REN_J_CHOICE  6u  /* reserved (Sched.Call.Pick); unused by the slice */
#define REN_J_END     7u  /* u32 how: 0 finished, 1 killed */
/* driver entries */
#define REN_J_DRV     16u /* u32 driver kind, u32 workers, u32 steps */
#define REN_J_RUN     17u /* u32 steps, i32 ret */
#define REN_J_PULL    18u /* wire call + body[len] (buf = 0) + u64 out_hash: what ren_poll_call returned */
#define REN_J_DRAINED 19u /* (empty) ren_poll_call returned false */
#define REN_J_REPLY   20u /* u64 id, u32 state, u32 len, body[len], u32 in_len, in[in_len], i32 ret */

/* wire call: u64 id, u16 worker, u16 kind, u32 lane, u32 task, u32 op, u32 len = 28 bytes */
#define REN_JCALL_BYTES 28u

#define REN_JC_RETRACT 0u  /* unpulled: retracted in the core, no round trip */
#define REN_JC_SENT    1u  /* pulled: a REN_CANCEL call goes to the driver */
#define REN_JC_LATE    2u  /* already replied, already cancelled, or stale id: no-op */
#define REN_JR_STALE   0u  /* generation or slot did not match a live call */
#define REN_JR_DUP     1u  /* the call had already replied */
#define REN_JR_DEAD    2u  /* the core was killed */

/* ===================================================================
   8. The driver-entry ABI. Each language exports these from its core
      library. The harness (host_main.c) owns threads; the driver owns
      the ren_host callbacks, rings/epoll fds, timers and buffers in
      flight.
   =================================================================== */

#define REN_DRV_EPOLL  1u
#define REN_DRV_URING  2u
#define REN_DRV_REPLAY 3u   /* input = a journal; one thread drives every worker; no OS calls */
#define REN_DRV_FUZZ   4u   /* input = random bytes (SPEC §D.4); one thread; no OS calls */

#define REN_DRV_F_URING_NO_DEFER 1u /* io_uring without SINGLE_ISSUER|DEFER_TASKRUN */

typedef struct ren_drv ren_drv;

typedef struct ren_drv_opts {
  uint32_t kind;          /* REN_DRV_* */
  int32_t workers;
  uint32_t steps;         /* the budget passed to every ren_run; 0 = 256 */
  int32_t record_fd;      /* >= 0: record: write every journal entry (core + driver) to this fd */
  const uint8_t *input;   /* REPLAY: journal bytes; FUZZ: fuzz bytes */
  size_t input_len;
  uint32_t flags;         /* REN_DRV_F_* */
  uint32_t _pad;
} ren_drv_opts;

/* NULL on failure (ren_drv_last_error(NULL) says why, e.g. io_uring unavailable). */
ren_drv       *ren_drv_new(const ren_drv_opts *o);
/* The callbacks and host pointer to pass to ren_start. */
const ren_host *ren_drv_host(ren_drv *d, void **hostp);
/* Run worker [worker]'s loop on this thread until ren_run returns
   REN_FINISHED and the worker's in-flight ops are drained. worker = -1:
   drive all workers from this thread (REPLAY, FUZZ). 0 = ok. */
int32_t        ren_drv_worker(ren_drv *d, ren_core *c, int32_t worker);
/* After every ren_drv_worker returned: the core is finished; release
   driver state. Returns 0 = ok; REPLAY: >0 = 1-based index of the first
   divergent entry; FUZZ: >0 = an oracle failure. <0 = error. */
int32_t        ren_drv_finish(ren_drv *d, ren_core *c);
void           ren_drv_free(ren_drv *d);
/* A static or driver-owned message for the last failure/divergence. */
const char    *ren_drv_last_error(ren_drv *d);

/* ===================================================================
   9. Test ABIs.
   =================================================================== */

/* The core's Chase-Lev deque, exported for harness/tests/deque_stress.c.
   Items are non-zero uint64_t. */
typedef struct ren_dq ren_dq;
#define REN_DQ_EMPTY 0u
#define REN_DQ_ABORT UINT64_MAX
ren_dq  *ren_dq_new(uint32_t log2_cap);
void     ren_dq_push(ren_dq *q, uint64_t v);   /* owner thread */
uint64_t ren_dq_take(ren_dq *q);               /* owner thread; EMPTY */
uint64_t ren_dq_steal(ren_dq *q);              /* any thread; EMPTY | ABORT */
void     ren_dq_free(ren_dq *q);

/* Layout table: each language reports offsets/sizes as ITS generated
   bindings see them; harness/tests/layout_check.c compares against C. */
typedef struct ren_layout_ent {
  const char *name;   /* "ren_call.id", "sizeof(ren_call)", ... see REN_LAYOUT_LIST */
  uint32_t value;
  uint32_t _pad;
} ren_layout_ent;
/* Returns the number of entries and sets *out. */
size_t ren_layout_table(const ren_layout_ent **out);

/* Every name the layout table must carry (X(type, field) and S(type)). */
#define REN_LAYOUT_LIST(X, S) \
  S(ren_obj) X(ren_obj, rc) X(ren_obj, tag) X(ren_obj, nfields) X(ren_obj, objs) \
  S(ren_array) X(ren_array, len) X(ren_array, cap) X(ren_array, data) \
  S(ren_task) X(ren_task, pc) X(ren_task, id) X(ren_task, resume) X(ren_task, fin) X(ren_task, core) \
  S(ren_call) X(ren_call, id) X(ren_call, worker) X(ren_call, kind) X(ren_call, lane) X(ren_call, task) \
              X(ren_call, op) X(ren_call, len) X(ren_call, body) \
  S(ren_reply_t) X(ren_reply_t, id) X(ren_reply_t, state) X(ren_reply_t, len) X(ren_reply_t, body) \
  S(ren_io_body) X(ren_io_body, fd) X(ren_io_body, len) X(ren_io_body, buf) X(ren_io_body, arg) \
  S(ren_io_result) X(ren_io_result, res) X(ren_io_result, a) X(ren_io_result, b) \
  S(ren_await) X(ren_await, id) X(ren_await, state) X(ren_await, op) X(ren_await, res) \
  S(ren_host) X(ren_host, wake) X(ren_host, answer_now) X(ren_host, pages) X(ren_host, journal) \
  S(ren_config) X(ren_config, workers) X(ren_config, budget_b) X(ren_config, poll_k) \
              X(ren_config, op_slots) X(ren_config, deque_log2) X(ren_config, journal_policy) \
              X(ren_config, build_id) X(ren_config, user) \
  S(ren_jent) X(ren_jent, kind) X(ren_jent, len) X(ren_jent, worker) X(ren_jent, step) \
  S(ren_drv_opts) X(ren_drv_opts, kind) X(ren_drv_opts, workers) X(ren_drv_opts, steps) \
              X(ren_drv_opts, record_fd) X(ren_drv_opts, input) X(ren_drv_opts, input_len) X(ren_drv_opts, flags)

/* The layout as C sees it on LP64 (x86-64, aarch64). A deliberate
   change to a struct above must be mirrored here, or this fails the C
   build; the other languages see the change only through their
   generated bindings and the layout table (SPEC §0.3). */
#define REN_SA(c, m) _Static_assert(c, m) /* tcc 0.9.27 has it too */
REN_SA(sizeof(ren_obj) == 8, "ren_obj");
REN_SA(sizeof(ren_array) == 24, "ren_array");
REN_SA(sizeof(ren_task) == 64, "ren_task");
REN_SA(offsetof(ren_task, core) == 32, "ren_task.core");
REN_SA(sizeof(ren_call) == 40, "ren_call");
REN_SA(offsetof(ren_call, body) == 32, "ren_call.body");
REN_SA(sizeof(ren_reply_t) == 24, "ren_reply_t");
REN_SA(sizeof(ren_io_body) == 32, "ren_io_body");
REN_SA(sizeof(ren_io_result) == 24, "ren_io_result");
REN_SA(sizeof(ren_await) == 40, "ren_await");
REN_SA(sizeof(ren_host) == 32, "ren_host");
REN_SA(sizeof(ren_config) == 40, "ren_config");
REN_SA(sizeof(ren_jent) == 24, "ren_jent");
REN_SA(sizeof(ren_drv_opts) == 40, "ren_drv_opts");

#ifdef __cplusplus
}
#endif
#endif /* REN_SLICE_H */
