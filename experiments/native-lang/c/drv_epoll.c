/* drv_epoll.c: the epoll driver (SPEC §C.1). One epoll fd per worker, an
   eventfd for wakes, a driver-held timer heap for SleepUntil, and
   nonblocking syscalls retried on EPOLLONESHOT readiness. */
#include "drv.h"
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#define WAKE_KEY UINT64_MAX

/* tcc 0.9.27 ignores __attribute__((packed)) on glibc's struct epoll_event
   (x86-64 __EPOLL_PACKED): it lays it out as 16 bytes with data at 8, the
   kernel uses 12 with data at 4 (checked on cloud, NOTES.md). So under tcc
   the events go through a byte buffer in the kernel's layout. */
#if defined(__TINYC__) && defined(__x86_64__)
#define EV_BYTES 12
#else
#define EV_BYTES sizeof(struct epoll_event)
#endif
static int ep_ctl(int epfd, int opn, int fd, uint32_t events, uint64_t key) {
#if defined(__TINYC__) && defined(__x86_64__)
  uint8_t b[16];
  memset(b, 0, sizeof b);
  memcpy(b, &events, 4);
  memcpy(b + 4, &key, 8);
  return epoll_ctl(epfd, opn, fd, (struct epoll_event *)(void *)b);
#else
  struct epoll_event ee;
  memset(&ee, 0, sizeof ee);
  ee.events = events;
  ee.data.u64 = key;
  return epoll_ctl(epfd, opn, fd, &ee);
#endif
}
static uint64_t ev_key(const uint8_t *evbuf, int i) {
#if defined(__TINYC__) && defined(__x86_64__)
  uint64_t k; memcpy(&k, evbuf + (size_t)i * 12 + 4, 8); return k;
#else
  return ((const struct epoll_event *)(const void *)evbuf)[i].data.u64;
#endif
}

typedef struct eop {
  struct eop *next, *prev;     /* the worker's in-flight list */
  ren_call call;
  ren_io_body body;
  int dir;                     /* 0 none, 1 read slot, 2 write/accept/connect slot, 3 timer */
  uint32_t want;               /* EPOLLIN / EPOLLOUT for the fd wait */
  int64_t fd;
  int64_t deadline;
  size_t hidx;                 /* timer heap index */
} eop;

typedef struct efd { eop *rd, *wr; bool poisoned; } efd;

typedef struct ew {
  int epfd;
  eop *head;
  size_t ninflight;
  eop **heap; size_t nheap, capheap;
  efd *fds; size_t nfds;
} ew;

/* ---------------- timer heap by (deadline, id) ---------------- */
static bool tless(const eop *a, const eop *b) {
  return a->deadline < b->deadline || (a->deadline == b->deadline && a->call.id < b->call.id);
}
static void hswap(ew *e, size_t i, size_t j) {
  eop *t = e->heap[i]; e->heap[i] = e->heap[j]; e->heap[j] = t;
  e->heap[i]->hidx = i; e->heap[j]->hidx = j;
}
static void hup(ew *e, size_t i) {
  while (i > 0) { size_t p = (i - 1) / 2; if (!tless(e->heap[i], e->heap[p])) break; hswap(e, i, p); i = p; }
}
static void hdown(ew *e, size_t i) {
  for (;;) {
    size_t l = 2 * i + 1, r = l + 1, m = i;
    if (l < e->nheap && tless(e->heap[l], e->heap[m])) m = l;
    if (r < e->nheap && tless(e->heap[r], e->heap[m])) m = r;
    if (m == i) return;
    hswap(e, i, m); i = m;
  }
}
static void hpush(ew *e, eop *o) {
  if (e->nheap == e->capheap) {
    e->capheap = e->capheap ? 2 * e->capheap : 16;
    e->heap = realloc(e->heap, e->capheap * sizeof *e->heap);
    if (!e->heap) abort();
  }
  o->hidx = e->nheap; e->heap[e->nheap++] = o; hup(e, o->hidx);
}
static void hremove(ew *e, eop *o) {
  size_t i = o->hidx;
  e->nheap--;
  if (i != e->nheap) { e->heap[i] = e->heap[e->nheap]; e->heap[i]->hidx = i; hdown(e, i); hup(e, i); }
}

/* ---------------- in-flight list and fd table ---------------- */
static void ep_link_op(ew *e, eop *o) {
  o->prev = NULL; o->next = e->head;
  if (e->head) e->head->prev = o;
  e->head = o; e->ninflight++;
}
static void ep_unlink_op(ew *e, eop *o) {
  if (o->prev) o->prev->next = o->next; else e->head = o->next;
  if (o->next) o->next->prev = o->prev;
  e->ninflight--;
}
static efd *ep_fdent(ew *e, int64_t fd) {
  if (fd < 0) return NULL;
  if ((size_t)fd >= e->nfds) {
    size_t n = e->nfds ? e->nfds : 64;
    while (n <= (size_t)fd) n *= 2;
    e->fds = realloc(e->fds, n * sizeof *e->fds);
    if (!e->fds) abort();
    memset(e->fds + e->nfds, 0, (n - e->nfds) * sizeof *e->fds);
    e->nfds = n;
  }
  return &e->fds[fd];
}
static void ep_arm(ew *e, int64_t fd) {
  efd *f = ep_fdent(e, fd);
  uint32_t ev = 0;
  if (f->rd) ev |= f->rd->want;
  if (f->wr) ev |= f->wr->want;
  if (!ev) return;           /* oneshot: already disarmed by the last event */
  uint32_t evs = ev | EPOLLONESHOT;
  if (ep_ctl(e->epfd, EPOLL_CTL_MOD, (int)fd, evs, (uint64_t)fd) == 0) return;
  if (errno == ENOENT && ep_ctl(e->epfd, EPOLL_CTL_ADD, (int)fd, evs, (uint64_t)fd) == 0) return;
  if (errno == EEXIST && ep_ctl(e->epfd, EPOLL_CTL_MOD, (int)fd, evs, (uint64_t)fd) == 0) return;
  fprintf(stderr, "ren c epoll: epoll_ctl(fd %lld): %s\n", (long long)fd, strerror(errno));
  abort();
}

/* ---------------- replies ---------------- */
static void ep_release(ew *e, const ren_call *k, int64_t res, int64_t a, int64_t b) {
  if (res < 0) return;
  switch (k->op) {
  case REN_OP_ACCEPT: case REN_OP_CONNECT: case REN_OP_LISTEN: close((int)res); break;
  case REN_OP_PIPE: close((int)a); close((int)b); break;
  case REN_OP_READ:
    if (res > 0) { efd *f = ep_fdent(e, ((const ren_io_body *)k->body)->fd); if (f) f->poisoned = true; }
    break;
  default: break;
  }
}
static void ep_reply(ren_drv *d, ren_core *c, int32_t w, ew *e, const ren_call *k, uint32_t st, int64_t res,
                  int64_t a, int64_t b) {
  const void *in = NULL;
  uint32_t in_len = 0;
  const ren_io_body *bd = (const ren_io_body *)k->body;
  if (k->op == REN_OP_READ && st == REN_DONE && res > 0) { in = (const void *)(uintptr_t)bd->buf; in_len = (uint32_t)res; }
  if (drv_reply(d, c, w, k->id, st, res, a, b, in, in_len) == REN_RELEASE && st == REN_DONE) ep_release(e, k, res, a, b);
}
static void ep_finish_op(ren_drv *d, ren_core *c, int32_t w, ew *e, eop *o, uint32_t st, int64_t res, int64_t a, int64_t b) {
  if (o->dir == 1 || o->dir == 2) {
    efd *f = ep_fdent(e, o->fd);
    if (o->dir == 1) f->rd = NULL; else f->wr = NULL;
  } else if (o->dir == 3) {
    hremove(e, o);
  }
  ep_unlink_op(e, o);
  ep_reply(d, c, w, e, &o->call, st, res, a, b);
  free(o);
}

/* Try the syscall for a waiting op. true: it completed (replied, freed). */
static bool ep_attempt(ren_drv *d, ren_core *c, int32_t w, ew *e, eop *o) {
  const ren_io_body *b = &o->body;
  efd *f = ep_fdent(e, o->fd);
  ssize_t r;
  switch (o->call.op) {
  case REN_OP_READ:
    if (f && f->poisoned) { ep_finish_op(d, c, w, e, o, REN_DONE, -EIO, 0, 0); return true; }
    r = read((int)b->fd, (void *)(uintptr_t)b->buf, b->len);
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return false;
    if (r < 0 && errno == EINTR) return false;
    ep_finish_op(d, c, w, e, o, REN_DONE, r < 0 ? -errno : r, 0, 0);
    return true;
  case REN_OP_WRITE:
    r = write((int)b->fd, (const void *)(uintptr_t)b->buf, b->len);
    if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return false;
    ep_finish_op(d, c, w, e, o, REN_DONE, r < 0 ? -errno : r, 0, 0);
    return true;
  case REN_OP_ACCEPT: {
    int nf = accept4((int)b->fd, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
    if (nf < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return false;
    ep_finish_op(d, c, w, e, o, REN_DONE, nf < 0 ? -errno : nf, 0, 0);
    return true;
  }
  case REN_OP_CONNECT: {          /* EPOLLOUT came: the result is SO_ERROR */
    int err = 0;
    socklen_t sl = sizeof err;
    if (getsockopt((int)o->fd, SOL_SOCKET, SO_ERROR, &err, &sl) < 0) err = errno;
    if (err == EINPROGRESS || err == EALREADY) return false;
    int64_t fd = o->fd;
    if (err) {
      efd *ff = ep_fdent(e, fd);
      ff->wr = NULL; o->dir = 0;
      epoll_ctl(e->epfd, EPOLL_CTL_DEL, (int)fd, NULL);
      close((int)fd);
      ep_unlink_op(e, o);
      ep_reply(d, c, w, e, &o->call, REN_DONE, -err, 0, 0);
      free(o);
      return true;
    }
    ep_finish_op(d, c, w, e, o, REN_DONE, fd, 0, 0);
    return true;
  }
  }
  return false;
}

static void ep_wait_fd(ew *e, eop *o, int dir, uint32_t want) {
  efd *f = ep_fdent(e, o->fd);
  o->dir = dir; o->want = want;
  if (dir == 1) f->rd = o; else f->wr = o;
  ep_arm(e, o->fd);
}

static void ep_submit(ren_drv *d, ren_core *c, int32_t w, ew *e, const ren_call *k) {
  if (k->kind == REN_CANCEL) {
    for (eop *o = e->head; o; o = o->next)
      if (o->call.id == k->id) {
        bool rearm = o->dir == 1 || o->dir == 2;
        int64_t fd = o->fd;
        ep_finish_op(d, c, w, e, o, REN_CANCELLED, -REN_ECANCELED, 0, 0);
        if (rearm) ep_arm(e, fd);
        return;
      }
    return;                          /* completed already, or unknown: ignore */
  }
  if (k->kind != REN_CALL) return;
  const ren_io_body *b = (const ren_io_body *)k->body;
  int64_t r, a = 0, bb = 0;
  switch (k->op) {
  case REN_OP_PIPE:
    r = drv_sync_pipe(&a, &bb);
    ep_reply(d, c, w, e, k, REN_DONE, r, a, bb);
    return;
  case REN_OP_LISTEN:
    r = drv_sync_listen(b->arg, &a);
    ep_reply(d, c, w, e, k, REN_DONE, r, r >= 0 ? a : 0, 0);
    return;
  case REN_OP_MONO_NOW:              /* normally answered by answer_now */
    ep_reply(d, c, w, e, k, REN_DONE, drv_mono_ns(), 0, 0);
    return;
  case REN_OP_CLOSE: {
    efd *f = ep_fdent(e, b->fd);
    if (f) {
      if (f->rd) ep_finish_op(d, c, w, e, f->rd, REN_CANCELLED, -REN_ECANCELED, 0, 0);
      if (f->wr) ep_finish_op(d, c, w, e, f->wr, REN_CANCELLED, -REN_ECANCELED, 0, 0);
      epoll_ctl(e->epfd, EPOLL_CTL_DEL, (int)b->fd, NULL);
      f->poisoned = false;
    }
    r = close((int)b->fd) < 0 ? -errno : 0;
    ep_reply(d, c, w, e, k, REN_DONE, r, 0, 0);
    return;
  }
  default: break;
  }
  eop *o = calloc(1, sizeof *o);
  if (!o) abort();
  o->call = *k;
  o->body = *b;
  o->call.body = &o->body;   /* our copy; buf names the frame's buffer, owned by us until the reply */
  o->fd = b->fd;
  ep_link_op(e, o);
  switch (k->op) {
  case REN_OP_SLEEP_UNTIL:
    o->dir = 3; o->deadline = b->arg;
    hpush(e, o);
    return;
  case REN_OP_READ:
    if (!ep_attempt(d, c, w, e, o)) ep_wait_fd(e, o, 1, EPOLLIN);
    return;
  case REN_OP_WRITE:
    if (!ep_attempt(d, c, w, e, o)) ep_wait_fd(e, o, 2, EPOLLOUT);
    return;
  case REN_OP_ACCEPT:
    if (!ep_attempt(d, c, w, e, o)) ep_wait_fd(e, o, 2, EPOLLIN);
    return;
  case REN_OP_CONNECT: {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) { int er = errno; ep_unlink_op(e, o); ep_reply(d, c, w, e, k, REN_DONE, -er, 0, 0); free(o); return; }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)b->arg);
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    o->fd = fd;
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
      ep_unlink_op(e, o); ep_reply(d, c, w, e, k, REN_DONE, fd, 0, 0); free(o); return;
    }
    if (errno != EINPROGRESS) {
      int er = errno; close(fd);
      ep_unlink_op(e, o); ep_reply(d, c, w, e, k, REN_DONE, -er, 0, 0); free(o); return;
    }
    ep_wait_fd(e, o, 2, EPOLLOUT);
    return;
  }
  default:
    ep_unlink_op(e, o);
    ep_reply(d, c, w, e, k, REN_DONE, -ENOSYS, 0, 0);
    free(o);
    return;
  }
}

int drv_epoll_new(ren_drv *d) {
  for (int32_t w = 0; w < d->o.workers; w++) {
    ew *e = calloc(1, sizeof *e);
    if (!e) abort();
    e->epfd = -1;
    d->wk[w] = e;
  }
  return 0;
}

int32_t drv_epoll_worker(ren_drv *d, ren_core *c, int32_t w) {
  ew *e = d->wk[w];
  e->epfd = epoll_create1(EPOLL_CLOEXEC);
  if (e->epfd < 0) { drv_set_err(d, "epoll_create1: %s", strerror(errno)); return -1; }
  if (ep_ctl(e->epfd, EPOLL_CTL_ADD, d->wake_fd[w], EPOLLIN, WAKE_KEY) < 0) { drv_set_err(d, "epoll_ctl(eventfd): %s", strerror(errno)); return -1; }
  if (w == 0) drv_rec_drv(d);
  ren_call *batch = NULL;
  size_t nb = 0, cb = 0;
  uint8_t evbuf[64 * 16];
  for (;;) {
    int32_t r = ren_run(c, w, d->o.steps);
    drv_rec_run(d, c, w, d->o.steps, r);
    ren_call k;
    nb = 0;
    while (ren_poll_call(c, w, &k)) {         /* drain until false: the one signal */
      drv_rec_pull(d, c, w, &k);
      if (nb == cb) { cb = cb ? 2 * cb : 16; batch = realloc(batch, cb * sizeof *batch); if (!batch) abort(); }
      batch[nb++] = k;
    }
    drv_rec_drained(d, c, w);
    for (size_t i = 0; i < nb; i++) ep_submit(d, c, w, e, &batch[i]);
    if (r == REN_FINISHED && e->ninflight == 0) break;
    if (r == REN_FINISHED) {                  /* after kill: nothing is in the kernel; drop the waits */
      while (e->head) {
        eop *o = e->head;
        int64_t fd = o->fd; int dir = o->dir;
        ep_finish_op(d, c, w, e, o, REN_CANCELLED, -REN_ECANCELED, 0, 0);
        if (dir == 1 || dir == 2) epoll_ctl(e->epfd, EPOLL_CTL_DEL, (int)fd, NULL);
      }
      continue;
    }
    struct timespec ts, *tsp = NULL;
    if (r == REN_RUNNING) { ts.tv_sec = 0; ts.tv_nsec = 0; tsp = &ts; }
    else if (e->nheap) {
      int64_t dl = e->heap[0]->deadline - drv_mono_ns();
      if (dl < 0) dl = 0;
      ts.tv_sec = dl / 1000000000ll; ts.tv_nsec = dl % 1000000000ll; tsp = &ts;
    }
    int n = epoll_pwait2(e->epfd, (struct epoll_event *)(void *)evbuf, (int)(sizeof evbuf / EV_BYTES), tsp, NULL);
    if (n < 0 && errno != EINTR) { drv_set_err(d, "epoll_pwait2: %s", strerror(errno)); free(batch); return -1; }
    for (int i = 0; i < n; i++) {
      uint64_t key = ev_key(evbuf, i);
      if (key == WAKE_KEY) {
        uint64_t v;
        while (read(d->wake_fd[w], &v, sizeof v) == (ssize_t)sizeof v) {}
        continue;
      }
      int64_t fd = (int64_t)key;
      if (ep_fdent(e, fd)->rd) ep_attempt(d, c, w, e, ep_fdent(e, fd)->rd);
      if (ep_fdent(e, fd)->wr) ep_attempt(d, c, w, e, ep_fdent(e, fd)->wr);
      ep_arm(e, fd);
    }
    int64_t now = drv_mono_ns();
    while (e->nheap && e->heap[0]->deadline <= now)
      ep_finish_op(d, c, w, e, e->heap[0], REN_DONE, 0, 0, 0);
  }
  free(batch);
  close(e->epfd);                             /* teardown: only after FINISHED and nothing in flight */
  e->epfd = -1;
  return 0;
}

void drv_epoll_free(ren_drv *d) {
  if (!d->wk) return;
  for (int32_t w = 0; w < d->o.workers; w++) {
    ew *e = d->wk[w];
    if (!e) continue;
    while (e->head) { eop *o = e->head; ep_unlink_op(e, o); free(o); }
    if (e->epfd >= 0) close(e->epfd);
    free(e->heap); free(e->fds); free(e);
    d->wk[w] = NULL;
  }
}
