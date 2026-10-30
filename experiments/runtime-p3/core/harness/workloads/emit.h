/* emit.h: what Ren's compiler would emit around an await. A resume
   function is a switch on self->pc; an await is "issue, set pc, park",
   and the resume re-checks the await's state (a wake may be spurious). */
#ifndef REN_EMIT_H
#define REN_EMIT_H
#include "wl.h"

/* Issue a world call and move to [next]. Returns -1 to fall through
   (answered inline), or the resume code to return now. REN_W_FULL
   leaves pc unchanged, so the resume re-issues. */
static inline int32_t em_issue(ren_ctx *cx, ren_task *self, ren_await *aw, uint32_t next,
                               uint32_t op, int64_t fd, void *buf, uint64_t len, int64_t arg) {
  ren_io_body b;
  b.fd = fd; b.len = len; b.buf = (uint64_t)(uintptr_t)buf; b.arg = arg;
  int32_t r = ren_world(cx, self, aw, op, &b);
  if (r == REN_W_FULL) return REN_T_YIELD;
  self->pc = next;
  return r == REN_W_NOW ? -1 : REN_T_PARK;
}
#define EM_ISSUE(next, op, fd, buf, len, arg)                                          \
  do {                                                                                  \
    int32_t em_r_ = em_issue(cx, &f->h, &f->aw, (next), (op), (fd), (buf), (len), (arg)); \
    if (em_r_ >= 0) return em_r_;                                                       \
  } while (0)
/* The same, running [stmt] once the call is issued (aw->id is valid),
   before parking: publish the id, or cancel it in the same step. */
#define EM_ISSUE_THEN(next, op, fd, buf, len, arg, stmt)                               \
  do {                                                                                  \
    int32_t em_r_ = em_issue(cx, &f->h, &f->aw, (next), (op), (fd), (buf), (len), (arg)); \
    if (em_r_ == REN_T_YIELD) return em_r_;                                             \
    stmt;                                                                               \
    if (em_r_ >= 0) return em_r_;                                                       \
  } while (0)
/* At the resume point of an await: park again until the reply is in. */
#define EM_AWAIT() do { if (wl_aw_state(&f->aw) == 0) return REN_T_PARK; } while (0)
#define EM_OK() (wl_aw_state(&f->aw) == REN_DONE)
#endif
