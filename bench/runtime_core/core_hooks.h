#ifndef REN_RUNTIME_CORE_TEST_HOOKS_H
#define REN_RUNTIME_CORE_TEST_HOOKS_H

/* Pending c3 adapter ABI. Implement in lib/native/runtime/ren_core_test.c,
   compiled only with REN_CORE_TEST_HOOKS. These functions MUST drive the
   production core, its verbs, allocator and frame callbacks. No protocol
   model, replacement scheduler or successful stub belongs here.

   Stable numeric handles index a test observation ledger; observing a freed
   handle never dereferences freed storage. The ledger records real dup/drop,
   allocation/free and ownership transitions, not a shadow implementation.
   Pausing holds an actual operation at the named boundary. Other actions
   then execute the competing protocol actor's actual primitive; continuing
   releases that operation. The wake/ref traces reproduce MODEL.md's logical
   actors, including windows not concurrently reachable with one executor;
   this is test interleaving control, not a new production scheduler.

   Tasks are tiny C frame callbacks: rt_call parks on the production submit
   waiter; rt_finish_ready resumes the callback, checks its real waiter or
   instance grant, then finishes through ren_task_finish. rt_park_until uses
   a real empty-row condition over a fixture-owned bool. No Ren is compiled.
   Fixture teardown must assert every owned payload dropped exactly once,
   no outstanding driver leases, no pending op, no live task and no waiter.
*/
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct rt_fixture rt_fixture;
typedef uint64_t rt_task;
typedef uint64_t rt_call_id; /* real slot + generation; not a test ordinal */
typedef uint64_t rt_instance;

typedef enum { RT_RUNNING, RT_QUEUED, RT_PARKED, RT_DONE } rt_task_state;
typedef enum { RT_FREE, RT_ISSUED, RT_PULLED, RT_CANCEL_UNPULLED,
               RT_CANCEL_PULLED, RT_REPLIED } rt_slot_state;
typedef enum { RT_ACCEPTED, RT_RELEASE } rt_reply_result;
typedef enum { RT_DONE_REPLY, RT_CANCELLED_REPLY } rt_reply_kind;
typedef enum {
  RT_SUBMIT_AFTER_PUBLISH, /* after slot publication, before stopping recheck */
  RT_DELIVER_AFTER_STORE, /* result published AND slot/op retired, before notify */
  RT_SCOPE_AFTER_LAST_CHILD, /* count became zero, before owner notify */
  RT_HANDOFF_AFTER_GRANT, /* holder set, before waiter notify */
  RT_UNTIL_AFTER_SIGNAL, /* condition true, before waiter notify */
  RT_DELIVER_BEFORE_STORE, /* notify-first mutant has notified already */
  RT_WORKER_BEFORE_ANNOUNCE, /* empty pick, before parked=1 */
  RT_TAKE_BEFORE_QUEUE_LOCK, /* initial take CAS failed */
  RT_TASK_BEFORE_PARK /* last condition check done, before PARK CAS */
} rt_boundary;

typedef struct {
  rt_task_state state;
  unsigned refs, runs, finishes, frees; /* runs counts post-park callback resumes */
  bool alive, cancelled, notified, reply_ready, holds_instance;
  rt_call_id pending;
} rt_task_view;
typedef struct {
  rt_slot_state state;
  uint32_t slot, generation;
  unsigned deliveries, op_frees, payload_drops, buffer_returns;
  bool driver_owns_buffer, waiter_live;
} rt_call_view;
typedef struct {
  unsigned wake_count, ready_count, inbox_count, queued_waiters;
  unsigned live_tasks, live_ops, double_frees, use_after_frees;
  unsigned finalizers, host_calls;
  bool worker_parked, sticky_wake, condition, stopping;
  rt_task holder;
} rt_core_view;

rt_fixture *rt_new(unsigned slots);
void rt_destroy(rt_fixture *);
rt_task rt_new_task(rt_fixture *, rt_task parent); /* parent 0: scope owner */
rt_call_id rt_call(rt_fixture *, rt_task); /* payload with traced drop + lent buffer */
void rt_cancel_task(rt_fixture *, rt_task); /* real eager cancel walk */
void rt_cancel_id(rt_fixture *, rt_call_id); /* real cancel_slot CAS */
bool rt_pull(rt_fixture *, rt_call_id); /* ren_poll_call, including retract */
/* On RELEASE the host half of this helper drops its reply/body and
   relinquishes the driver lease; it never frees a core operation. */
rt_reply_result rt_reply(rt_fixture *, rt_call_id, rt_reply_kind);
void rt_deliver(rt_fixture *); /* actual worker inbox delivery */
void rt_finish_ready(rt_fixture *, rt_task);
void rt_finish_plain(rt_fixture *, rt_task); /* task with no outstanding wait */
void rt_notify(rt_fixture *, rt_task); /* own temporary ref across ren_notify */
void rt_step_cancelled(rt_fixture *, rt_task); /* spurious cancelled resumption */
void rt_enter_finally(rt_fixture *, rt_task); /* callback masks cancellation */
void rt_scope_wait(rt_fixture *, rt_task owner);
void rt_finish_child(rt_fixture *, rt_task child);
rt_instance rt_instance_new(rt_fixture *);
bool rt_take(rt_fixture *, rt_task, rt_instance);
void rt_release(rt_fixture *, rt_task, rt_instance);
void rt_park_until(rt_fixture *, rt_task);
void rt_signal_until(rt_fixture *);
void rt_stop(rt_fixture *); /* actual ren_stop */
void rt_worker_empty_pick(rt_fixture *);
void rt_worker_park(rt_fixture *); /* announce then production full recheck */
void rt_task_decide_park(rt_fixture *, rt_task);
void rt_task_park(rt_fixture *, rt_task);
void rt_pause(rt_fixture *, rt_boundary); /* next matching boundary only */
bool rt_paused(rt_fixture *, rt_boundary); /* assert hook was reached */
void rt_continue(rt_fixture *);
void rt_drain(rt_fixture *); /* bounded; fail on hang rather than sleep */
void rt_answer_inline(rt_fixture *, bool);
void rt_yield(rt_fixture *, rt_task);
typedef enum { RT_HOST_RUNNING, RT_HOST_IDLE, RT_HOST_DONE } rt_host_result;
rt_host_result rt_host_run(rt_fixture *, unsigned steps); /* actual ren_run */
void rt_kill(rt_fixture *); /* actual ren_kill, never finalizes */
void rt_free_core(rt_fixture *); /* actual ren_free, fixture ledger survives */
void rt_mark_finalizer(rt_fixture *, rt_task); /* fixture callback traces finally */
/* host_calls bits: start1, thread_init2, run4, poll8, reply16, stop32,
   kill64, free128, progress256. rt_new uses start+init. After explicit
   free_core, destroy frees only observation ledger, not the core twice. */
uint64_t rt_progress(rt_fixture *);
rt_task_view rt_task_state_of(rt_fixture *, rt_task);
rt_call_view rt_call_state_of(rt_fixture *, rt_call_id);
rt_core_view rt_state(rt_fixture *);

/* Rule-removal flags consumed by the actual core under TEST_HOOKS only:
   REN_CORE_TEST_DISABLE_DELIVER_REF      rule1 deliver
   REN_CORE_TEST_DISABLE_SCOPE_REF        rule1 last child
   REN_CORE_TEST_DISABLE_HANDOFF_REF      rule1 instance handoff
   REN_CORE_TEST_DISABLE_UNTIL_REF        rule1 until signal
   REN_CORE_TEST_DISABLE_RETRACT_WAKE     rule2
   REN_CORE_TEST_DISABLE_STOP_WALK        rule3 no task walk
   REN_CORE_TEST_STOP_PARKED_ONLY         rule3 mutant walk
   REN_CORE_TEST_CANCEL_FREES_OP          rule4 P4
   REN_CORE_TEST_DISABLE_REPLY_GENERATION rule5 P3 reply
   REN_CORE_TEST_DISABLE_CANCEL_GENERATION rule5 P3 cancel
   REN_CORE_TEST_NOTIFY_BEFORE_STORE      rule1 store/wake order mutant
   REN_CORE_TEST_DISABLE_PARK_RECHECK     rule6
   REN_CORE_TEST_DISABLE_WAIT_REPLY       rule7 old rule4
   REN_CORE_TEST_DISABLE_TAKE_RECHECK     rule8
   The test binary reports the flags it was actually built with, and the
   runner checks them. A flag ignored by production must leave its mutant
   unexpectedly green and fail the runner. */
const char *rt_compiled_mutant(void); /* "none" or the exact flag above */
#endif
