/* Pending production-core tests: source checks run in c0; linkage and
   execution stay SKIP until the c3 adapter exists. No model is linked. */
#include "core_hooks.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *case_name;
#define REQUIRE(condition, property) do { \
  if (!(condition)) { \
    fprintf(stderr, "INVARIANT %s: %s at line %d\n", property, case_name, __LINE__); \
    exit(1); \
  } \
} while (0)
#define TASK(f, t) rt_task_state_of(f, t)
#define CALL(f, c) rt_call_state_of(f, c)
#define CORE(f) rt_state(f)

static void clean(rt_fixture *f) {
  rt_drain(f);
  REQUIRE(CORE(f).use_after_frees == 0, "NoUseAfterFree");
  REQUIRE(CORE(f).double_frees == 0, "NoDoubleFree");
  REQUIRE(CORE(f).live_ops == 0, "EndsOnce");
  REQUIRE(CORE(f).live_tasks == 0, "ScopeEndsAfterItsTasks");
  REQUIRE(CORE(f).queued_waiters == 0, "NoLostWaiter");
  rt_destroy(f);
}

/* CALL/SPUR: a spurious/cancel notify queues the waiter before delivery.
   Once the result is visible, an independent executor can finish the task.
   The delivering actor must keep its reference until after its own notify. */
static void deliver_ref(bool cancel) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  if (cancel) rt_cancel_task(f, t);
  else rt_notify(f, t);
  REQUIRE(TASK(f, t).state == RT_QUEUED, "EndsOnce");
  if (cancel) REQUIRE(!rt_pull(f, c), "CancelledTaskWaitsForReply");
  else {
    REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
    REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  }
  rt_pause(f, RT_DELIVER_AFTER_STORE);
  rt_deliver(f);
  REQUIRE(rt_paused(f, RT_DELIVER_AFTER_STORE), "HookReached");
  REQUIRE(TASK(f, t).reply_ready, "StoreBeforeNotify");
  REQUIRE(CALL(f, c).op_frees == 1, "NoDoubleFree");
  rt_finish_ready(f, t);
  REQUIRE(TASK(f, t).finishes == 1, "EndsOnce");
  REQUIRE(TASK(f, t).alive && TASK(f, t).refs >= 1, "NoUseAfterFree");
  rt_continue(f);
  REQUIRE(TASK(f, t).frees == 1, "NoDoubleFree");
  clean(f);
}

static void scope_ref(void) {
  rt_fixture *f = rt_new(1);
  rt_task owner = rt_new_task(f, 0), child = rt_new_task(f, owner);
  rt_scope_wait(f, owner);
  REQUIRE(!TASK(f, owner).reply_ready, "ScopeEndsAfterItsTasks");
  rt_notify(f, owner);
  rt_pause(f, RT_SCOPE_AFTER_LAST_CHILD);
  rt_finish_child(f, child);
  REQUIRE(rt_paused(f, RT_SCOPE_AFTER_LAST_CHILD), "HookReached");
  rt_finish_ready(f, owner);
  REQUIRE(TASK(f, owner).alive && TASK(f, owner).refs >= 1, "NoUseAfterFree");
  rt_continue(f);
  REQUIRE(TASK(f, owner).frees == 1, "EndsOnce");
  clean(f);
}

static void handoff_ref(void) {
  rt_fixture *f = rt_new(1);
  rt_task waiter = rt_new_task(f, 0), holder = rt_new_task(f, 0);
  rt_instance i = rt_instance_new(f);
  REQUIRE(rt_take(f, holder, i), "InstanceHeldByOne");
  REQUIRE(!rt_take(f, waiter, i), "InstanceHeldByOne");
  rt_notify(f, waiter);
  rt_pause(f, RT_HANDOFF_AFTER_GRANT);
  rt_release(f, holder, i);
  REQUIRE(rt_paused(f, RT_HANDOFF_AFTER_GRANT), "HookReached");
  REQUIRE(TASK(f, waiter).holds_instance && !TASK(f, holder).holds_instance,
          "InstanceHeldByOne");
  rt_release(f, waiter, i);
  rt_finish_ready(f, waiter);
  REQUIRE(TASK(f, waiter).alive && TASK(f, waiter).refs >= 1, "NoUseAfterFree");
  rt_continue(f);
  rt_finish_plain(f, holder);
  clean(f);
}

static void until_ref(void) {
  rt_fixture *f = rt_new(1);
  rt_task waiter = rt_new_task(f, 0);
  rt_park_until(f, waiter);
  rt_notify(f, waiter);
  rt_pause(f, RT_UNTIL_AFTER_SIGNAL);
  rt_signal_until(f);
  REQUIRE(rt_paused(f, RT_UNTIL_AFTER_SIGNAL), "HookReached");
  REQUIRE(CORE(f).condition, "NoLostWake");
  rt_finish_ready(f, waiter);
  REQUIRE(TASK(f, waiter).alive && TASK(f, waiter).refs >= 1, "NoUseAfterFree");
  rt_continue(f);
  clean(f);
}

/* RETRACT/RETRACT2/STOPS: the idle driver polls a cancelled unpulled call.
   No OS completion will wake it; retraction itself must leave a permit. */
static void retract(bool other_call, bool stop) {
  rt_fixture *f = rt_new(other_call ? 2 : 1);
  rt_task t = rt_new_task(f, 0), other = 0;
  rt_call_id c = rt_call(f, t), c2 = 0;
  if (other_call) {
    other = rt_new_task(f, 0);
    c2 = rt_call(f, other);
    REQUIRE(rt_pull(f, c2), "AcceptedOnlyWithWaiter");
  }
  if (stop) rt_stop(f); else rt_cancel_task(f, t);
  /* A cancelled resumption checks the outstanding waiter and parks again. */
  rt_step_cancelled(f, t);
  rt_worker_empty_pick(f);
  rt_worker_park(f);
  REQUIRE(CORE(f).worker_parked, "HookReached");
  unsigned wakes = CORE(f).wake_count;
  REQUIRE(!rt_pull(f, c), "CancelledTaskWaitsForReply");
  REQUIRE(CORE(f).inbox_count >= 1, "NoLostWake");
  REQUIRE(CORE(f).wake_count > wakes && CORE(f).sticky_wake, "NoLostWake");
  rt_deliver(f);
  REQUIRE(CALL(f, c).deliveries == 1, "EndsOnce");
  REQUIRE(CALL(f, c).op_frees == 1, "NoDoubleFree");
  rt_finish_ready(f, t);
  if (other_call) {
    REQUIRE(rt_reply(f, c2, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
    rt_deliver(f);
    rt_finish_ready(f, other);
  }
  clean(f);
}

static void stop_until(bool running) {
  rt_fixture *f = rt_new(1);
  rt_task waiter = rt_new_task(f, 0), peer = rt_new_task(f, 0);
  rt_park_until(f, waiter);
  if (running) {
    rt_notify(f, waiter);
    rt_pause(f, RT_TASK_BEFORE_PARK);
    rt_task_decide_park(f, waiter);
    REQUIRE(rt_paused(f, RT_TASK_BEFORE_PARK), "HookReached");
    REQUIRE(TASK(f, waiter).state == RT_RUNNING, "HookReached");
  }
  rt_stop(f);
  rt_finish_plain(f, peer); /* leaves without signalling the condition */
  if (running) {
    REQUIRE(TASK(f, waiter).notified, "NoLostWake");
    rt_continue(f);
    rt_task_park(f, waiter);
  }
  REQUIRE(TASK(f, waiter).state == RT_QUEUED, "NoLostWake");
  REQUIRE(TASK(f, waiter).cancelled, "StopCancelsTree");
  rt_finish_ready(f, waiter);
  clean(f);
}

static void cancel_only_deliver_frees(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  rt_cancel_task(f, t);
  REQUIRE(CALL(f, c).op_frees == 0, "NoDoubleFree");
  REQUIRE(!rt_pull(f, c), "CancelledTaskWaitsForReply");
  rt_deliver(f);
  REQUIRE(CALL(f, c).op_frees == 1 && CORE(f).double_frees == 0, "NoDoubleFree");
  rt_finish_ready(f, t);
  REQUIRE(CALL(f, c).payload_drops == 1, "EndsOnce");
  clean(f);
}

/* DUPS/FINALLY: reply and cancel of generation 1 race reuse as generation 2.
   The FINALLY call is masked, so the stale walk may not cancel that call. */
static void generations(bool stale_cancel) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id old = rt_call(f, t);
  REQUIRE(rt_pull(f, old), "AcceptedOnlyWithWaiter");
  if (stale_cancel) rt_cancel_task(f, t);
  REQUIRE(rt_reply(f, old, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_enter_finally(f, t); /* consumes old reply, stays alive to submit again */
  rt_call_id fresh = rt_call(f, t);
  REQUIRE(CALL(f, old).slot == CALL(f, fresh).slot, "HookReached");
  REQUIRE(CALL(f, old).generation != CALL(f, fresh).generation, "HookReached");
  if (stale_cancel) {
    rt_cancel_id(f, old);
    REQUIRE(CALL(f, fresh).state == RT_ISSUED, "StaleCancelNeverHits");
  } else {
    REQUIRE(rt_reply(f, old, RT_DONE_REPLY) == RT_RELEASE, "StaleReplyNeverAccepted");
    REQUIRE(!TASK(f, t).reply_ready, "StaleReplyNeverAccepted");
  }
  REQUIRE(rt_pull(f, fresh), "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, fresh, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(CALL(f, old).deliveries == 1 && CALL(f, fresh).deliveries == 1, "EndsOnce");
  clean(f);
}

static void store_before_notify(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  rt_notify(f, t); /* queued before the delivering actor's notify */
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_pause(f, RT_DELIVER_BEFORE_STORE);
  rt_deliver(f);
  REQUIRE(rt_paused(f, RT_DELIVER_BEFORE_STORE), "HookReached");
  /* In the mutant the notify has already set NOTIFIED. The next resume
     clears it, sees no result, and successfully parks before the store. */
  rt_step_cancelled(f, t); /* name notwithstanding: also a spurious resume */
  rt_continue(f);
  REQUIRE(TASK(f, t).reply_ready, "NoLostWake");
  REQUIRE(TASK(f, t).state == RT_QUEUED, "NoLostWake");
  rt_finish_ready(f, t);
  clean(f);
}

static void park_recheck(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  rt_worker_empty_pick(f);
  rt_pause(f, RT_WORKER_BEFORE_ANNOUNCE);
  rt_worker_park(f);
  REQUIRE(rt_paused(f, RT_WORKER_BEFORE_ANNOUNCE), "HookReached");
  REQUIRE(!CORE(f).worker_parked, "HookReached");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_continue(f);
  REQUIRE(!CORE(f).worker_parked || CORE(f).sticky_wake, "NoLostWake");
  rt_deliver(f);
  rt_finish_ready(f, t);
  clean(f);
}

static void wait_reply(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  rt_cancel_task(f, t);
  rt_step_cancelled(f, t);
  REQUIRE(TASK(f, t).alive && TASK(f, t).finishes == 0, "CancelledTaskWaitsForReply");
  REQUIRE(TASK(f, t).pending == c && CALL(f, c).waiter_live, "CancelledTaskWaitsForReply");
  REQUIRE(CALL(f, c).driver_owns_buffer && CALL(f, c).buffer_returns == 0,
          "CancelledTaskWaitsForReply");
  REQUIRE(rt_reply(f, c, RT_CANCELLED_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(CALL(f, c).buffer_returns == 1 && !CALL(f, c).driver_owns_buffer, "EndsOnce");
  clean(f);
}

static void take_recheck(void) {
  rt_fixture *f = rt_new(1);
  rt_task holder = rt_new_task(f, 0), waiter = rt_new_task(f, 0);
  rt_instance i = rt_instance_new(f);
  REQUIRE(rt_take(f, holder, i), "InstanceHeldByOne");
  rt_pause(f, RT_TAKE_BEFORE_QUEUE_LOCK);
  (void)rt_take(f, waiter, i);
  REQUIRE(rt_paused(f, RT_TAKE_BEFORE_QUEUE_LOCK), "HookReached");
  rt_release(f, holder, i); /* no queued waiter yet */
  REQUIRE(CORE(f).holder == 0, "HookReached");
  rt_continue(f);
  REQUIRE(CORE(f).queued_waiters == 0 && TASK(f, waiter).holds_instance, "NoLostWaiter");
  REQUIRE(CORE(f).holder == waiter, "InstanceHeldByOne");
  rt_release(f, waiter, i);
  rt_finish_ready(f, waiter);
  rt_finish_plain(f, holder);
  clean(f);
}

static void late_reply(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_RELEASE, "AcceptedOnlyWithWaiter");
  REQUIRE(TASK(f, t).runs == 1 && TASK(f, t).finishes == 1 && TASK(f, t).frees == 1,
          "EndsOnce");
  REQUIRE(CALL(f, c).deliveries == 1 && CALL(f, c).op_frees == 1, "NoDoubleFree");
  clean(f);
}

static void duplicate_reply(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_RELEASE, "EndsOnce");
  REQUIRE(CALL(f, c).op_frees == 0 && CORE(f).inbox_count == 1, "NoDoubleFree");
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(CALL(f, c).deliveries == 1 && CALL(f, c).op_frees == 1, "EndsOnce");
  clean(f);
}

static void stop_call(bool during_publish) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  if (during_publish) rt_pause(f, RT_SUBMIT_AFTER_PUBLISH);
  rt_call_id c = rt_call(f, t);
  if (during_publish) {
    REQUIRE(rt_paused(f, RT_SUBMIT_AFTER_PUBLISH), "HookReached");
    rt_stop(f);
    rt_continue(f);
    REQUIRE(CALL(f, c).state == RT_CANCEL_UNPULLED, "CancelledTaskWaitsForReply");
    REQUIRE(!rt_pull(f, c), "CancelledTaskWaitsForReply");
  } else {
    REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
    rt_stop(f);
    rt_step_cancelled(f, t);
    REQUIRE(TASK(f, t).finishes == 0 && CALL(f, c).driver_owns_buffer,
            "CancelledTaskWaitsForReply");
    REQUIRE(rt_reply(f, c, RT_CANCELLED_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  }
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(rt_host_run(f, 1) == RT_HOST_DONE, "NoLostWake");
  clean(f);
}

static void inline_reply(void) {
  rt_fixture *f = rt_new(1);
  rt_answer_inline(f, true);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(TASK(f, t).reply_ready && !CALL(f, c).driver_owns_buffer, "AcceptedOnlyWithWaiter");
  REQUIRE(CALL(f, c).deliveries == 1 && CALL(f, c).op_frees == 1, "EndsOnce");
  rt_finish_ready(f, t);
  clean(f);
}

static void ping(bool yield) {
  rt_fixture *f = rt_new(1);
  rt_task a = rt_new_task(f, 0), b = rt_new_task(f, 0);
  rt_park_until(f, a);
  rt_notify(f, a); /* unrelated wake must not make a false condition ready */
  rt_step_cancelled(f, a);
  REQUIRE(TASK(f, a).state == RT_PARKED, "NoLostWake");
  rt_signal_until(f);
  if (yield) rt_yield(f, b);
  REQUIRE(TASK(f, a).state == RT_QUEUED, "NoLostWake");
  rt_finish_ready(f, a);
  rt_finish_plain(f, b);
  clean(f);
}

struct reply_arg { rt_fixture *f; rt_call_id call; rt_reply_result result; };
static void *reply_thread(void *arg) {
  struct reply_arg *a = arg;
  a->result = rt_reply(a->f, a->call, RT_DONE_REPLY);
  return NULL;
}
static void two_repliers(void) {
  rt_fixture *f = rt_new(2);
  rt_task a = rt_new_task(f, 0), b = rt_new_task(f, 0);
  struct reply_arg x = { f, rt_call(f, a), RT_RELEASE };
  struct reply_arg y = { f, rt_call(f, b), RT_RELEASE };
  REQUIRE(rt_pull(f, x.call) && rt_pull(f, y.call), "AcceptedOnlyWithWaiter");
  pthread_t first, second;
  REQUIRE(pthread_create(&first, NULL, reply_thread, &x) == 0, "HostThreadStarted");
  REQUIRE(pthread_create(&second, NULL, reply_thread, &y) == 0, "HostThreadStarted");
  REQUIRE(pthread_join(first, NULL) == 0 && pthread_join(second, NULL) == 0, "HostThreadJoined");
  REQUIRE(x.result == RT_ACCEPTED && y.result == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_finish_ready(f, a);
  rt_finish_ready(f, b);
  REQUIRE(CALL(f, x.call).op_frees == 1 && CALL(f, y.call).op_frees == 1, "NoDoubleFree");
  clean(f);
}

static void host_abi(void) {
  rt_fixture *f = rt_new(1); /* ren_start, ren_thread_init */
  uint64_t before = rt_progress(f);
  rt_task t = rt_new_task(f, 0);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_host_run(f, 1) != RT_HOST_DONE, "HostRunResult");
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_ACCEPTED, "AcceptedOnlyWithWaiter");
  rt_deliver(f);
  rt_finish_ready(f, t);
  REQUIRE(rt_progress(f) > before, "ProgressMonotonic");
  rt_stop(f);
  rt_drain(f);
  REQUIRE(rt_host_run(f, 1) == RT_HOST_DONE, "HostRunResult");
  rt_kill(f); /* idempotent even after normal termination */
  rt_free_core(f);
  REQUIRE(CORE(f).host_calls == 511, "AllNineHostFunctions");
  REQUIRE(CORE(f).live_ops == 0 && CORE(f).live_tasks == 0, "EndsOnce");
  rt_destroy(f);
}

static void kill_lease(void) {
  rt_fixture *f = rt_new(1);
  rt_task t = rt_new_task(f, 0);
  rt_mark_finalizer(f, t);
  rt_call_id c = rt_call(f, t);
  REQUIRE(rt_pull(f, c), "AcceptedOnlyWithWaiter");
  rt_kill(f);
  REQUIRE(rt_host_run(f, 1) == RT_HOST_DONE, "KillStopsExecution");
  REQUIRE(CORE(f).finalizers == 0, "KillDoesNotFinalize");
  REQUIRE(CALL(f, c).driver_owns_buffer && CALL(f, c).buffer_returns == 0,
          "KillRetainsDriverLease");
  REQUIRE(CALL(f, c).op_frees == 0, "OnlyDeliveryFreesOp");
  REQUIRE(rt_reply(f, c, RT_DONE_REPLY) == RT_RELEASE, "AcceptedOnlyWithWaiter");
  REQUIRE(!CALL(f, c).driver_owns_buffer && CALL(f, c).buffer_returns == 1,
          "KillRetainsDriverLease");
  /* Host is now quiescent. ren_free performs discard-delivery retirement
     of the retained op, no frame callback and no finally. */
  rt_free_core(f);
  REQUIRE(CALL(f, c).op_frees == 1 && CORE(f).finalizers == 0, "OnlyDeliveryFreesOp");
  REQUIRE(CORE(f).live_ops == 0 && CORE(f).live_tasks == 0, "EndsOnce");
  rt_destroy(f);
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--compiled-mutant") == 0) {
    puts(rt_compiled_mutant());
    return 0;
  }
  if (argc != 3 || strcmp(argv[1], "--case") != 0) return 2;
  case_name = argv[2];
  if (!strcmp(case_name, "deliver-ref-cancel")) deliver_ref(true);
  else if (!strcmp(case_name, "deliver-ref-spurious")) deliver_ref(false);
  else if (!strcmp(case_name, "scope-end-ref")) scope_ref();
  else if (!strcmp(case_name, "instance-handoff-ref")) handoff_ref();
  else if (!strcmp(case_name, "until-signal-ref")) until_ref();
  else if (!strcmp(case_name, "retract-wake")) retract(false, false);
  else if (!strcmp(case_name, "retract-other-call-in-flight")) retract(true, false);
  else if (!strcmp(case_name, "stop-retract-wake")) retract(false, true);
  else if (!strcmp(case_name, "stop-until-notify-all-live")) stop_until(false);
  else if (!strcmp(case_name, "stop-running-before-park")) stop_until(true);
  else if (!strcmp(case_name, "cancel-does-not-free-op")) cancel_only_deliver_frees();
  else if (!strcmp(case_name, "reply-generation-cas")) generations(false);
  else if (!strcmp(case_name, "cancel-generation-cas-finally")) generations(true);
  else if (!strcmp(case_name, "store-before-notify")) store_before_notify();
  else if (!strcmp(case_name, "park-announcement-recheck")) park_recheck();
  else if (!strcmp(case_name, "cancelled-task-waits-for-reply")) wait_reply();
  else if (!strcmp(case_name, "take-lock-recheck")) take_recheck();
  else if (!strcmp(case_name, "late-reply-release")) late_reply();
  else if (!strcmp(case_name, "inline-reply")) inline_reply();
  else if (!strcmp(case_name, "duplicate-before-delivery")) duplicate_reply();
  else if (!strcmp(case_name, "stop-pulled-call")) stop_call(false);
  else if (!strcmp(case_name, "stop-during-publish")) stop_call(true);
  else if (!strcmp(case_name, "PING")) ping(false);
  else if (!strcmp(case_name, "PINGY")) ping(true);
  else if (!strcmp(case_name, "two-host-replier-threads")) two_repliers();
  else if (!strcmp(case_name, "all-nine-host-functions")) host_abi();
  else if (!strcmp(case_name, "kill-driver-lease")) kill_lease();
  else { fprintf(stderr, "unknown case: %s\n", case_name); return 2; }
  printf("PASS %s\n", case_name);
  return 0;
}
