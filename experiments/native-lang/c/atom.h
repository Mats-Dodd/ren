/* atom.h: the C entry's atomics. Every operation names its memory order.
   clang/gcc: C11 <stdatomic.h> on _Atomic objects.
   tcc 0.9.27: no <stdatomic.h>, no _Atomic keyword (both checked on cloud,
   NOTES.md), so the same macros map onto slice.h's x86-64 asm shim
   (ren_ld64 / ren_cas64 / ren_fence ...). The objects are then plain
   int64_t-sized words and every access still goes through the shim. */
#ifndef REN_C_ATOM_H
#define REN_C_ATOM_H
#include "slice.h"

#if defined(__TINYC__)
typedef int64_t a64;          /* signed 64-bit word */
typedef uint64_t au64;        /* unsigned 64-bit word */
typedef uint64_t aptr;        /* pointer as a 64-bit word */
#define RLX REN_MO_RELAXED
#define ACQ REN_MO_ACQUIRE
#define REL REN_MO_RELEASE
#define AR  REN_MO_ACQ_REL
#define SC  REN_MO_SEQ_CST
/* All of the core's own atomics are 64-bit; aw.state is 32-bit (slice.h). */
#define LD(p, mo)        ren_ld64((const int64_t *)(p), (mo))
#define ST(p, v, mo)     ren_st64((int64_t *)(p), (int64_t)(v), (mo))
#define XADD(p, v, mo)   ren_xadd64((int64_t *)(p), (int64_t)(v), (mo))
#define XCHG(p, v, mo)   ren_xchg64((int64_t *)(p), (int64_t)(v), (mo))
#define CAS(p, e, d, ok, fail) ren_cas64((int64_t *)(p), (int64_t *)(e), (int64_t)(d), (ok), (fail))
#define FETCH_OR(p, v, mo) ren_fetch_or64((int64_t *)(p), (int64_t)(v), (mo))
#define FENCE(mo)        ren_fence(mo)
#define ST32(p, v, mo)   ren_st32((int32_t *)(p), (int32_t)(v), (mo))
#define AS64(p)  (p)
#define ASU64(p) (p)
static inline int64_t ren_fetch_or64(int64_t *p, int64_t v, int mo) {
  int64_t old = ren_ld64(p, REN_MO_RELAXED);
  while (!ren_cas64(p, &old, old | v, mo, REN_MO_RELAXED)) {}
  return old;
}
#define CPU_RELAX() __asm__ volatile("pause" ::: "memory")
#define NO_SAN_INT
#else
#include <stdatomic.h>
typedef _Atomic int64_t a64;
typedef _Atomic uint64_t au64;
typedef _Atomic uintptr_t aptr;
#define RLX memory_order_relaxed
#define ACQ memory_order_acquire
#define REL memory_order_release
#define AR  memory_order_acq_rel
#define SC  memory_order_seq_cst
#define LD(p, mo)        atomic_load_explicit((p), (mo))
#define ST(p, v, mo)     atomic_store_explicit((p), (v), (mo))
#define XADD(p, v, mo)   atomic_fetch_add_explicit((p), (v), (mo))
#define XCHG(p, v, mo)   atomic_exchange_explicit((p), (v), (mo))
#define CAS(p, e, d, ok, fail) atomic_compare_exchange_strong_explicit((p), (e), (d), (ok), (fail))
#define FETCH_OR(p, v, mo) atomic_fetch_or_explicit((p), (v), (mo))
#define FENCE(mo)        atomic_thread_fence(mo)
/* slice.h fields that are plain integers in the shared layout but are
   accessed atomically by the protocol (aw.state, task.core[0]). Same size
   and alignment as the _Atomic type on x86-64 and aarch64. */
#define ST32(p, v, mo)   atomic_store_explicit((_Atomic int32_t *)(p), (v), (mo))
#define ASU64(p) ((au64 *)(p))
#if defined(__x86_64__)
#define CPU_RELAX() __asm__ volatile("pause" ::: "memory")
#elif defined(__aarch64__)
#define CPU_RELAX() __asm__ volatile("yield" ::: "memory")
#else
#define CPU_RELAX() do {} while (0)
#endif
/* intentional modular arithmetic (FNV-1a, xorshift): exempt from
   -fsanitize=integer, which reports well-defined unsigned wrap too */
#define NO_SAN_INT __attribute__((no_sanitize("integer")))
#endif

/* ThreadSanitizer does not model atomic_thread_fence (LLVM ignores it), so
   a happens-before edge made by "fence(REL); store(RLX)" -> "load(ACQ)"
   is invisible to it. REN_C_TSAN builds strengthen exactly those stores to
   REL as well (keeping the fence); NOTES.md lists where. */
#if defined(__SANITIZE_THREAD__)
#define REN_C_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define REN_C_TSAN 1
#endif
#endif
#ifndef REN_C_TSAN
#define REN_C_TSAN 0
#endif

#endif
