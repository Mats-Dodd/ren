// X3b: the request path, from a connection's serve loop to the memtable.
//
// X3's path (x3/path.c), with two changes: a request may be local work that
// never touches the table (SHARE_PCT), and a request that does touch it makes
// an `at` block of OPS operations (OPS=1 is X3's request):
//
//   fn handle(req) uses Memtable =
//     if req.local then local_work(req) else
//     let k = parse_key(req)
//     at Memtable:                                   // OPS operations
//       for i in 0..OPS: acc ^= if put then route_put(key_at(k, i), v + i)
//                                       else route_get(key_at(k, i))
//
// Under (a) the operation call `mt_put`/`mt_get` is one of:
//   park, handoff, p2   X3's take: CAS, spin, park (rt.c's take_slow);
//   ship, shipded       on the home worker a direct call; elsewhere a D.Call
//                       shipped to the home and the task suspends until the
//                       reply (one round trip per operation);
//   move                `handle` hops the task to the home worker before the
//                       block and back after it (two hops per block); inside
//                       it every operation is a direct call.
#include "rt.h"

/* ---------- recv: suspending in both builds ---------- */
typedef struct { frame h; uint64_t _l[4]; } recv_frame;
static ren_ret recv(task *t, frame *hf, char *sp, uint64_t in) {
  recv_frame *f = (recv_frame *)hf;
  (void)in;
  if (f->h.state == 1) return (ren_ret){DONE, 0};
  point(); /* FAST: the home answers calls at every scheduling point */
  if (UNLIKELY(recv_would_block(t))) {
    f->h.state = 1; f->h.sp = sp; t->top = hf;
    requeue(t);
    return (ren_ret){PENDING, 0};
  }
  return (ren_ret){DONE, 0};
}

#define CALL(FT, FN, SETARGS, ARG, ST, SPILL)                             \
  {                                                                       \
    FT *c_ = (FT *)sp;                                                    \
    char *csp_ = BUMP(t, sp, R16(sizeof(FT)));                            \
    c_->h.state = 0; c_->h.flags = 0;                                     \
    SETARGS;                                                              \
    r = FN(t, &c_->h, csp_, (ARG));                                       \
    if (UNLIKELY(r.st == PENDING)) {                                      \
      c_->h.resume = FN; c_->h.parent = hf;                               \
      SPILL; f->h.state = (ST); f->h.sp = sp;                             \
      return r;                                                           \
    }                                                                     \
  }

#ifdef SUSP
/* ================= (a): the operation call is a scheduling point ================= */
typedef struct { frame h; uint64_t k, v, _l[2]; } mt_frame;
typedef struct { frame h; uint64_t k, v, _l[2]; } route_frame;
typedef struct { frame h; request req; uint64_t k, i, acc, hopped; } handle_frame; /* hopped: unused */

/* parking take (park, handoff, p2) */
#define TAKE(ST, SPILL)                                                   \
  retry_##ST:                                                             \
  if (UNLIKELY(!take_fast(&mt_lock))) {                                   \
    if (!take_slow(t, &mt_lock)) {                                        \
      SPILL; f->h.state = (ST); f->h.sp = sp; t->top = hf;                \
      return (ren_ret){PENDING, 0};                                       \
    }                                                                     \
  }                                                                       \
  taken_##ST:                                                             \
  if (UNLIKELY(t->waiting)) note_wait_done(t);

/* (H) off the home worker: ship the call and suspend until the reply
   (state 3), or wait for room in a full ring (state 2). The reply is
   consumed by this same worker, after this function has returned. */
#define SHIP(OP, SPILL)                                                   \
  ship_##OP:                                                              \
  if (cur_worker != HOME) {                                               \
    SPILL; f->h.sp = sp; t->top = hf;                                     \
    if (LIKELY(ship_call(t, (OP), k, v))) { f->h.state = 3; return (ren_ret){PENDING, 0}; } \
    f->h.state = 2; note_ring_full(); requeue(t);                         \
    return (ren_ret){PENDING, 0};                                         \
  }

static ren_ret mt_put(task *t, frame *hf, char *sp, uint64_t in) {
  mt_frame *f = (mt_frame *)hf;
  uint64_t k, v;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  k = f->k; v = in;
  if (SHIPPING) {
    SHIP(1, (f->k = k, f->v = v))
    mt_insert(k, v); /* on the home worker: a direct call */
    hold_work();
    return (ren_ret){DONE, 1};
  }
  TAKE(1, (f->k = k, f->v = v))
  mt_insert(k, v);
  hold_work();
  release(&mt_lock);
  return (ren_ret){DONE, 1};
dispatch:
  k = f->k; v = f->v;
  if (f->h.state == 3) return (ren_ret){DONE, t->reply};
  if (f->h.state == 2) goto ship_1;
  if (t->granted) { t->granted = 0; goto taken_1; }
  goto retry_1;
}
static ren_ret mt_get(task *t, frame *hf, char *sp, uint64_t in) {
  mt_frame *f = (mt_frame *)hf;
  uint64_t k, v = 0;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  k = f->k;
  if (SHIPPING) {
    SHIP(0, (f->k = k))
    return (ren_ret){DONE, mt_lookup(k)};
  }
  TAKE(1, (f->k = k))
  v = mt_lookup(k);
  release(&mt_lock);
  return (ren_ret){DONE, v};
dispatch:
  k = f->k;
  if (f->h.state == 3) return (ren_ret){DONE, t->reply};
  if (f->h.state == 2) goto ship_0;
  if (t->granted) { t->granted = 0; goto taken_1; }
  goto retry_1;
}
static ren_ret route_put(task *t, frame *hf, char *sp, uint64_t in) {
  route_frame *f = (route_frame *)hf;
  uint64_t k, v;
  ren_ret r;
  if (UNLIKELY(f->h.state != 0)) { r.v = in; goto s1; }
  k = f->k; v = in;
  if (!validate(k, v)) return (ren_ret){DONE, 0};
  CALL(mt_frame, mt_put, c_->k = k, v, 1, (void)0)
s1:
  return (ren_ret){DONE, r.v};
}
static ren_ret route_get(task *t, frame *hf, char *sp, uint64_t in) {
  route_frame *f = (route_frame *)hf;
  uint64_t k;
  ren_ret r;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) { r.v = in; goto s1; }
  k = f->k;
  CALL(mt_frame, mt_get, c_->k = k, 0, 1, (void)0)
s1:
  return (ren_ret){DONE, r.v};
}

/* The `at` block. Under move the task is pushed to the home worker before it
   (state 1 resumes there) and back after it (state 3 resumes at its own
   worker). The worker does the push after the task has suspended. */
static ren_ret handle(task *t, frame *hf, char *sp, uint64_t in) {
  handle_frame *f = (handle_frame *)hf;
  ren_ret r;
  uint64_t k0, i, acc; /* the block's loop state lives in C locals, spilled at a suspension */
  switch (f->h.state) {
  case 0: break;
  case 1: k0 = f->k; i = 0; acc = 0; goto there;
  case 2: k0 = f->k; i = f->i; acc = f->acc; r.v = in; goto op_done;
  case 3: return (ren_ret){DONE, f->acc};
  }
  if (f->req.op == 2) return (ren_ret){DONE, local_work(&f->req)};
  k0 = parse_key(&f->req); i = 0; acc = 0;
  if (MOVING && cur_worker != HOME) {
    f->k = k0; f->hopped = 1;
    f->h.state = 1; f->h.sp = sp; t->top = hf;
    hop(t, HOME);
    return (ren_ret){PENDING, 0};
  }
there:
  for (; i < (uint64_t)nops; i++) {
    {
      uint64_t k = key_at(k0, i), v = f->req.val + i;
      if ((f->req.op ^ i) & 1) CALL(route_frame, route_put, c_->k = k, v, 2, (f->k = k0, f->i = i, f->acc = acc))
      else CALL(route_frame, route_get, c_->k = k, 0, 2, (f->k = k0, f->i = i, f->acc = acc))
    }
  op_done:
    acc ^= r.v + i;
  }
  if (f->h.state == 1) { /* moved: hop back */
    f->acc = acc;
    f->h.state = 3; f->h.sp = sp; t->top = hf;
    hop(t, t->home);
    return (ren_ret){PENDING, 0};
  }
  return (ren_ret){DONE, acc};
}

typedef struct { frame h; uint64_t _l[4]; } serve_frame;
ren_ret serve(task *t, frame *hf, char *sp, uint64_t in) {
  serve_frame *f = (serve_frame *)hf;
  ren_ret r;
  request req;
  if (UNLIKELY(f->h.state != 0)) { r.v = in; if (f->h.state == 1) goto s1; goto s2; }
loop:
  CALL(recv_frame, recv, (void)0, 0, 1, (void)0)
s1:
  if (!next_request(t, &req)) return (ren_ret){DONE, 0};
  CALL(handle_frame, handle, c_->req = req, 0, 2, (void)0)
s2:
  respond(t, encode_resp(r.v));
  goto loop;
}

#else
/* ================= (b): a thread lock; callers stay plain ================= */
static uint64_t mt_put(uint64_t k, uint64_t v) {
  thread_take(&mt_lock);
  mt_insert(k, v);
  hold_work();
  thread_release(&mt_lock);
  return 1;
}
static uint64_t mt_get(uint64_t k) {
  thread_take(&mt_lock);
  uint64_t v = mt_lookup(k);
  thread_release(&mt_lock);
  return v;
}
static uint64_t route_put(uint64_t k, uint64_t v) {
  if (!validate(k, v)) return 0;
  return mt_put(k, v);
}
static uint64_t route_get(uint64_t k) { return mt_get(k); }
static uint64_t handle(const request *req) {
  if (req->op == 2) return local_work(req);
  uint64_t k = parse_key(req), acc = 0;
  for (uint64_t i = 0; i < (uint64_t)nops; i++) {
    uint64_t ki = key_at(k, i);
    acc ^= (((req->op ^ i) & 1) ? route_put(ki, req->val + i) : route_get(ki)) + i;
  }
  return acc;
}

typedef struct { frame h; uint64_t _l[4]; } serve_frame;
ren_ret serve(task *t, frame *hf, char *sp, uint64_t in) {
  serve_frame *f = (serve_frame *)hf;
  ren_ret r;
  request req;
  if (UNLIKELY(f->h.state != 0)) { r.v = in; goto s1; }
loop:
  CALL(recv_frame, recv, (void)0, 0, 1, (void)0)
s1:
  if (!next_request(t, &req)) return (ren_ret){DONE, 0};
  respond(t, encode_resp(handle(&req)));
  goto loop;
}
#endif
