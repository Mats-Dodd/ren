// X3: the request path, from a connection's serve loop to the memtable.
//
// The program (as Ren source would read):
//
//   fn serve(conn) uses Net, Memtable =            // task body
//     loop
//       let req = Net.recv(conn) else return        // a world call
//       respond(conn, encode_resp(handle(req)))
//   fn handle(req) uses Memtable =
//     let k = parse_key(req)
//     if req.op == put then route_put(k, req.val) else route_get(k)
//   fn route_put(k, v) uses Memtable =
//     if validate(k, v) then Memtable.put(k, v) else 0
//   fn route_get(k) uses Memtable = Memtable.get(k)
//   // the handler: one exclusive instance, installed in main above the
//   // spawns, so it's may-be-shared; put and get never suspend
//   op put(k, v) = insert(k, v); hold_work()
//   op get(k) = lookup(k)
//
// Fourteen functions: serve, recv, handle, parse_key, validate, route_put,
// route_get, mt_put, mt_get, mt_insert, mt_lookup, encode_resp,
// respond, hold_work. Counting by construction:
//   suspending in both builds: serve, recv (it reaches a world call).
//   change colour under (a):   handle, route_put, route_get, mt_put, mt_get (5).
//   plain in both:             parse_key, validate, mt_insert, mt_lookup,
//                              hold_work, encode_resp, respond (7, in rt.c).
// Only the five that change colour, plus serve and recv, live in this file,
// so `size` on path_a.o and path_b.o is the code-size difference.
#include "rt.h"

/* ---------- recv: suspending in both builds ---------- */
typedef struct { frame h; uint64_t _l[4]; } recv_frame;
static ren_ret recv(task *t, frame *hf, char *sp, uint64_t in) {
  recv_frame *f = (recv_frame *)hf;
  (void)in;
  if (f->h.state == 1) return (ren_ret){DONE, 0}; /* the reply came */
  if (UNLIKELY(recv_would_block(t))) {             /* every 8th: the driver queues it */
    f->h.state = 1; f->h.sp = sp; t->top = hf;
    requeue(t);                                     /* its reply is immediately ready */
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
/* ================= (a): shared takes are scheduling points ================= */
typedef struct { frame h; uint64_t k, v, _l[2]; } mt_frame;
typedef struct { frame h; uint64_t k, v, _l[2]; } route_frame;
typedef struct { frame h; request req; uint64_t _l; } handle_frame;

/* The take: CAS; on contention spin ~1 us, then park the task. The task is
   queued on the instance; a release either hands the instance over
   (`granted`) or wakes it to try again. */
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

static ren_ret mt_put(task *t, frame *hf, char *sp, uint64_t in) {
  mt_frame *f = (mt_frame *)hf;
  uint64_t k, v;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  k = f->k; v = in;
  TAKE(1, (f->k = k, f->v = v))
  mt_insert(k, v);
  hold_work();
  release(&mt_lock);
  return (ren_ret){DONE, 1};
dispatch:
  k = f->k; v = f->v;
  if (t->granted) { t->granted = 0; goto taken_1; }
  goto retry_1;
}
static ren_ret mt_get(task *t, frame *hf, char *sp, uint64_t in) {
  mt_frame *f = (mt_frame *)hf;
  uint64_t k, v;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) goto dispatch;
  k = f->k;
  TAKE(1, (f->k = k))
  v = mt_lookup(k);
  release(&mt_lock);
  return (ren_ret){DONE, v};
dispatch:
  k = f->k;
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
static ren_ret handle(task *t, frame *hf, char *sp, uint64_t in) {
  handle_frame *f = (handle_frame *)hf;
  ren_ret r;
  (void)in;
  if (UNLIKELY(f->h.state != 0)) { r.v = in; goto s1; }
  uint64_t k = parse_key(&f->req);
  if (f->req.op) CALL(route_frame, route_put, c_->k = k, f->req.val, 1, (void)0)
  else CALL(route_frame, route_get, c_->k = k, 0, 1, (void)0)
s1:
  return (ren_ret){DONE, r.v};
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
  uint64_t k = parse_key(req);
  return req->op ? route_put(k, req->val) : route_get(k);
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
