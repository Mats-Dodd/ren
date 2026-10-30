/* drv_uring.c: the io_uring driver (SPEC §C.1), on liburing 2.5. One ring
   per worker, created R_DISABLED (+ SINGLE_ISSUER | DEFER_TASKRUN unless
   REN_DRV_F_URING_NO_DEFER) by ren_drv_new and enabled on the worker's own
   thread. One READ of the worker's eventfd stays armed for wakes. */
#include "drv.h"
#include <arpa/inet.h>
#include <errno.h>
#include <liburing.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define UD_WAKE   1ull
#define UD_IGNORE 2ull

typedef struct uop {
  struct uop *next, *prev;
  ren_call call;
  ren_io_body body;
  bool in_kernel;              /* SQE submitted, final CQE not yet in */
  bool cancel_sent;
  bool closing;                /* a CLOSE waiting for the fd's ops to come back */
  int64_t fd;
  struct __kernel_timespec ts;
  struct sockaddr_in sa;
} uop;

typedef struct uw {
  struct io_uring ring;
  bool ring_ok, enabled;
  uop *head;
  size_t ninflight;
  uint64_t wake_buf;
  bool *poisoned; size_t npois;
} uw;

static void ur_link_op(uw *u, uop *o) {
  o->prev = NULL; o->next = u->head;
  if (u->head) u->head->prev = o;
  u->head = o; u->ninflight++;
}
static void ur_unlink_op(uw *u, uop *o) {
  if (o->prev) o->prev->next = o->next; else u->head = o->next;
  if (o->next) o->next->prev = o->prev;
  u->ninflight--;
}
static bool *ur_poison_ent(uw *u, int64_t fd) {
  if (fd < 0) return NULL;
  if ((size_t)fd >= u->npois) {
    size_t n = u->npois ? u->npois : 64;
    while (n <= (size_t)fd) n *= 2;
    u->poisoned = realloc(u->poisoned, n);
    if (!u->poisoned) abort();
    memset(u->poisoned + u->npois, 0, n - u->npois);
    u->npois = n;
  }
  return &u->poisoned[fd];
}

static struct io_uring_sqe *ur_sqe_get(uw *u) {
  struct io_uring_sqe *s;
  while (!(s = io_uring_get_sqe(&u->ring))) io_uring_submit(&u->ring);
  return s;
}
static void ur_arm_wake(ren_drv *d, uw *u, int32_t w) {
  struct io_uring_sqe *s = ur_sqe_get(u);
  io_uring_prep_read(s, d->wake_fd[w], &u->wake_buf, sizeof u->wake_buf, 0);
  io_uring_sqe_set_data64(s, UD_WAKE);
}

static void ur_release(uw *u, const ren_call *k, int64_t res, int64_t a, int64_t b) {
  if (res < 0) return;
  switch (k->op) {
  case REN_OP_ACCEPT: case REN_OP_CONNECT: case REN_OP_LISTEN: close((int)res); break;
  case REN_OP_PIPE: close((int)a); close((int)b); break;
  case REN_OP_READ:
    if (res > 0) { bool *p = ur_poison_ent(u, ((const ren_io_body *)k->body)->fd); if (p) *p = true; }
    break;
  default: break;
  }
}
static void ur_reply(ren_drv *d, ren_core *c, int32_t w, uw *u, const ren_call *k, uint32_t st, int64_t res,
                  int64_t a, int64_t b) {
  const void *in = NULL;
  uint32_t in_len = 0;
  const ren_io_body *bd = (const ren_io_body *)k->body;
  if (k->op == REN_OP_READ && st == REN_DONE && res > 0) { in = (const void *)(uintptr_t)bd->buf; in_len = (uint32_t)res; }
  if (drv_reply(d, c, w, k->id, st, res, a, b, in, in_len) == REN_RELEASE && st == REN_DONE) ur_release(u, k, res, a, b);
}

static uop *ur_new_op(uw *u, const ren_call *k) {
  uop *o = calloc(1, sizeof *o);
  if (!o) abort();
  o->call = *k;
  if (k->kind == REN_CALL && k->body) o->body = *(const ren_io_body *)k->body;
  o->call.body = &o->body;
  o->fd = o->body.fd;
  ur_link_op(u, o);
  return o;
}
static void ur_to_kernel(uw *u, uop *o, struct io_uring_sqe *s) {
  (void)u;
  io_uring_sqe_set_data(s, o);
  o->in_kernel = true;
}

static size_t ur_fd_ops_in_kernel(uw *u, int64_t fd) {
  size_t n = 0;
  for (uop *o = u->head; o; o = o->next) if (o->in_kernel && o->fd == fd) n++;
  return n;
}

static void ur_submit(ren_drv *d, ren_core *c, int32_t w, uw *u, const ren_call *k) {
  if (k->kind == REN_CANCEL) {
    for (uop *o = u->head; o; o = o->next)
      if (o->call.id == k->id && o->in_kernel && !o->closing) {
        if (!o->cancel_sent) {
          struct io_uring_sqe *s = ur_sqe_get(u);
          io_uring_prep_cancel(s, o, 0);       /* the original op's CQE is the final reply */
          io_uring_sqe_set_data64(s, UD_IGNORE);
          o->cancel_sent = true;
        }
        return;
      }
    return;
  }
  if (k->kind != REN_CALL) return;
  const ren_io_body *b = (const ren_io_body *)k->body;
  int64_t r, a = 0, bb = 0;
  switch (k->op) {
  case REN_OP_PIPE:
    r = drv_sync_pipe(&a, &bb);
    ur_reply(d, c, w, u, k, REN_DONE, r, a, bb);
    return;
  case REN_OP_LISTEN:
    r = drv_sync_listen(b->arg, &a);
    ur_reply(d, c, w, u, k, REN_DONE, r, r >= 0 ? a : 0, 0);
    return;
  case REN_OP_MONO_NOW:
    ur_reply(d, c, w, u, k, REN_DONE, drv_mono_ns(), 0, 0);
    return;
  case REN_OP_READ: {
    bool *p = ur_poison_ent(u, b->fd);
    if (p && *p) { ur_reply(d, c, w, u, k, REN_DONE, -EIO, 0, 0); return; }
    uop *o = ur_new_op(u, k);
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_read(s, (int)b->fd, (void *)(uintptr_t)b->buf, (unsigned)b->len, (uint64_t)-1);
    ur_to_kernel(u, o, s);
    return;
  }
  case REN_OP_WRITE: {
    uop *o = ur_new_op(u, k);
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_write(s, (int)b->fd, (const void *)(uintptr_t)b->buf, (unsigned)b->len, (uint64_t)-1);
    ur_to_kernel(u, o, s);
    return;
  }
  case REN_OP_ACCEPT: {
    uop *o = ur_new_op(u, k);
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_accept(s, (int)b->fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    ur_to_kernel(u, o, s);
    return;
  }
  case REN_OP_CONNECT: {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) { ur_reply(d, c, w, u, k, REN_DONE, -errno, 0, 0); return; }
    uop *o = ur_new_op(u, k);
    o->fd = fd;
    o->sa.sin_family = AF_INET;
    o->sa.sin_port = htons((uint16_t)b->arg);
    o->sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_connect(s, fd, (struct sockaddr *)&o->sa, sizeof o->sa);  /* the sockaddr lives in o */
    ur_to_kernel(u, o, s);
    return;
  }
  case REN_OP_SLEEP_UNTIL: {
    uop *o = ur_new_op(u, k);
    o->fd = -1;
    o->ts.tv_sec = b->arg / 1000000000ll;
    o->ts.tv_nsec = b->arg % 1000000000ll;
    if (o->ts.tv_nsec < 0) { o->ts.tv_sec -= 1; o->ts.tv_nsec += 1000000000ll; }
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_timeout(s, &o->ts, 0, IORING_TIMEOUT_ABS);   /* CLOCK_MONOTONIC is the default */
    ur_to_kernel(u, o, s);
    return;
  }
  case REN_OP_CLOSE: {
    bool *p = ur_poison_ent(u, b->fd);
    if (ur_fd_ops_in_kernel(u, b->fd) == 0) {
      if (p) *p = false;
      r = close((int)b->fd) < 0 ? -errno : 0;
      ur_reply(d, c, w, u, k, REN_DONE, r, 0, 0);
      return;
    }
    uop *o = ur_new_op(u, k);
    o->closing = true;
    struct io_uring_sqe *s = ur_sqe_get(u);
    io_uring_prep_cancel_fd(s, (int)b->fd, IORING_ASYNC_CANCEL_ALL);   /* §2.6: then close once those CQEs are in */
    io_uring_sqe_set_data64(s, UD_IGNORE);
    return;
  }
  default:
    ur_reply(d, c, w, u, k, REN_DONE, -ENOSYS, 0, 0);
    return;
  }
}

static void ur_complete(ren_drv *d, ren_core *c, int32_t w, uw *u, uop *o, int32_t res) {
  o->in_kernel = false;
  ur_unlink_op(u, o);
  uint32_t st = res == -ECANCELED ? REN_CANCELLED : REN_DONE;
  int64_t rr = st == REN_CANCELLED ? -REN_ECANCELED : res;
  switch (o->call.op) {
  case REN_OP_SLEEP_UNTIL:
    if (res == -ETIME) rr = 0;
    break;
  case REN_OP_CONNECT:
    if (res == 0) rr = o->fd;
    else close((int)o->fd);
    break;
  default: break;
  }
  ur_reply(d, c, w, u, &o->call, st, rr, 0, 0);
  free(o);
}

static void ur_finish_closes(ren_drv *d, ren_core *c, int32_t w, uw *u) {
  for (uop *o = u->head, *nx; o; o = nx) {
    nx = o->next;
    if (!o->closing || ur_fd_ops_in_kernel(u, o->fd) != 0) continue;
    bool *p = ur_poison_ent(u, o->fd);
    if (p) *p = false;
    int64_t r = close((int)o->fd) < 0 ? -errno : 0;
    ur_unlink_op(u, o);
    ur_reply(d, c, w, u, &o->call, REN_DONE, r, 0, 0);
    free(o);
    nx = u->head;           /* replies do not touch the list, but restart to be safe */
  }
}

int drv_uring_new(ren_drv *d) {
  for (int32_t w = 0; w < d->o.workers; w++) {
    uw *u = calloc(1, sizeof *u);
    if (!u) abort();
    d->wk[w] = u;
    struct io_uring_params p;
    memset(&p, 0, sizeof p);
    p.flags = IORING_SETUP_R_DISABLED;
    if (!(d->o.flags & REN_DRV_F_URING_NO_DEFER) && !d->uring_fallback)
      p.flags |= IORING_SETUP_SINGLE_ISSUER | IORING_SETUP_DEFER_TASKRUN;
    int r = io_uring_queue_init_params(256, &u->ring, &p);
    if (r == -EINVAL && (p.flags & IORING_SETUP_DEFER_TASKRUN)) {
      d->uring_fallback = 1;               /* detect once, fall back whole: every worker without them */
      memset(&p, 0, sizeof p);
      p.flags = IORING_SETUP_R_DISABLED;
      r = io_uring_queue_init_params(256, &u->ring, &p);
    }
    if (r < 0) {
      drv_set_err(d, "io_uring unavailable: io_uring_setup failed: %s%s", strerror(-r),
                  (r == -ENOSYS || r == -EPERM) ? " (not falling back to epoll)" : "");
      return -1;
    }
    d->uring_setup_flags = p.flags;
    u->ring_ok = true;
  }
  if (d->uring_fallback)
    fprintf(stderr, "ren c uring: SINGLE_ISSUER|DEFER_TASKRUN refused (EINVAL); rings set up without them\n");
  return 0;
}

int32_t drv_uring_worker(ren_drv *d, ren_core *c, int32_t w) {
  uw *u = d->wk[w];
  int r0 = io_uring_enable_rings(&u->ring);   /* on its own thread: this thread becomes the single issuer */
  if (r0 < 0) { drv_set_err(d, "io_uring_enable_rings: %s", strerror(-r0)); return -1; }
  u->enabled = true;
  ur_arm_wake(d, u, w);
  if (w == 0) drv_rec_drv(d);
  ren_call *batch = NULL;
  size_t nb, cb = 0;
  bool finished = false;
  for (;;) {
    int32_t r = ren_run(c, w, d->o.steps);
    drv_rec_run(d, c, w, d->o.steps, r);
    ren_call k;
    nb = 0;
    while (ren_poll_call(c, w, &k)) {
      drv_rec_pull(d, c, w, &k);
      if (nb == cb) { cb = cb ? 2 * cb : 16; batch = realloc(batch, cb * sizeof *batch); if (!batch) abort(); }
      batch[nb++] = k;
    }
    drv_rec_drained(d, c, w);
    for (size_t i = 0; i < nb; i++) ur_submit(d, c, w, u, &batch[i]);
    ur_finish_closes(d, c, w, u);
    if (r == REN_FINISHED && u->ninflight == 0) break;
    if (r == REN_FINISHED && !finished) {   /* after kill: cancel what the kernel holds, then drain it */
      finished = true;
      for (uop *o = u->head; o; o = o->next)
        if (o->in_kernel && !o->cancel_sent) {
          struct io_uring_sqe *s = ur_sqe_get(u);
          io_uring_prep_cancel(s, o, 0);
          io_uring_sqe_set_data64(s, UD_IGNORE);
          o->cancel_sent = true;
        }
    }
    int sr = (r == REN_RUNNING) ? io_uring_submit_and_get_events(&u->ring) : io_uring_submit_and_wait(&u->ring, 1);
    if (sr < 0 && sr != -EINTR && sr != -EAGAIN && sr != -EBUSY && sr != -ETIME) {
      drv_set_err(d, "io_uring_submit: %s", strerror(-sr));
      free(batch);
      return -1;
    }
    struct io_uring_cqe *cqe;
    unsigned head, seen = 0;
    /* copy out first: replies may submit nothing, but keep the CQ walk simple */
    struct { uint64_t ud; int32_t res; } done[256];
    size_t nd = 0;
    io_uring_for_each_cqe(&u->ring, head, cqe) {
      if (nd == sizeof done / sizeof done[0]) break;
      done[nd].ud = cqe->user_data; done[nd].res = cqe->res; nd++;
      seen++;
    }
    io_uring_cq_advance(&u->ring, seen);
    for (size_t i = 0; i < nd; i++) {
      if (done[i].ud == UD_WAKE) {
        ur_arm_wake(d, u, w);                   /* kept armed until teardown; queue_exit cancels it */
        continue;
      }
      if (done[i].ud == UD_IGNORE) continue;
      ur_complete(d, c, w, u, (uop *)(uintptr_t)done[i].ud, done[i].res);
    }
    ur_finish_closes(d, c, w, u);
  }
  free(batch);
  io_uring_queue_exit(&u->ring);             /* teardown: only after FINISHED and nothing in flight */
  u->ring_ok = false;
  return 0;
}

void drv_uring_free(ren_drv *d) {
  if (!d->wk) return;
  for (int32_t w = 0; w < d->o.workers; w++) {
    uw *u = d->wk[w];
    if (!u) continue;
    if (u->ring_ok) io_uring_queue_exit(&u->ring);
    while (u->head) { uop *o = u->head; ur_unlink_op(u, o); free(o); }
    free(u->poisoned);
    free(u);
    d->wk[w] = NULL;
  }
}
