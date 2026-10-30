/* ren_e1.h: what the Phase C C core exports beyond slice.h's nine
   functions. None of it is part of the ABI of research/runtime/SYNTHESIS.md
   §3: it is instrumentation for experiments and tests (machine "cloud").

   - ren_e1_set_hooks: test-only delay points inside the protocol, used to
     widen race windows (E1's §B.5 test, the lost-wake stress, E5).
   - ren_e1_stats: per-worker counters the core keeps anyway (plain, owner
     written; read them after the workers stopped, or accept a torn read).
   - ren_e1_contract_checks: 1 if this build has the §2.7 contract asserts
     (profiles check, debug, asan, tsan), 0 in release.
   - ren_e1_dump: print the core's state (debugging a hang). */
#ifndef REN_E1_H
#define REN_E1_H
#include "slice.h"
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ren_e1_hooks {
  void *p;
  /* deliver(), home worker: after the waiter's aw.state store, before
     the task is notified (the SPEC §B.5 window). */
  void (*deliver_gap)(void *p, int32_t worker);
  /* ren_reply(), any thread: after the op is pushed to the home inbox,
     before the home worker is woken. */
  void (*reply_gap)(void *p, int32_t home);
  /* try_park(): after parked=1 is published, before the re-check. */
  void (*park_gap)(void *p, int32_t worker);
} ren_e1_hooks;

/* Call after ren_start and before any thread calls ren_run. NULL clears. */
void ren_e1_set_hooks(ren_core *c, const ren_e1_hooks *h);

typedef struct ren_e1_wstats {
  uint64_t runs;          /* ren_run calls */
  uint64_t idle;          /* ren_run returned IDLE (the worker parked) */
  uint64_t delivered;     /* replies delivered to waiters (incl. inline answers) */
  uint64_t delivered_after_cancel; /* ... whose call had a cancel (§2.2: the waiter still got it) */
  uint64_t retracted;     /* cancels retracted before the driver pulled the call */
  uint64_t slow_notify;   /* deliveries that found the task not PARKED (a spurious wake was in flight) */
} ren_e1_wstats;

typedef struct ren_e1_stats {
  int32_t workers;
  uint64_t wakes;         /* host.wake calls */
  uint64_t steps[64];
  ren_e1_wstats w[64];
} ren_e1_stats;

void ren_e1_stats_get(ren_core *c, ren_e1_stats *out);
int  ren_e1_contract_checks(void);
void ren_e1_dump(ren_core *c, FILE *f);

#ifdef __cplusplus
}
#endif
#endif
