/* drv_common.c: what every C driver shares: ren_drv_* entry points, the
   recorder (SPEC §C.1 "Recording"), field-by-field entry encoding, the
   answer_now and wake callbacks, and the synchronous ops. */
#include "drv.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

char ren_c_drv_global_err[160] = "";

/* ---------------- encoding ---------------- */
void db_init(db *d) { d->n = 0; d->big = NULL; d->cap = sizeof d->b; }
static void db_room(db *d, size_t k) {
  if (d->n + k <= d->cap) return;
  size_t cap = (d->n + k) * 2;
  uint8_t *nb = malloc(cap);
  if (!nb) abort();
  memcpy(nb, db_data(d), d->n);
  free(d->big);
  d->big = nb; d->cap = cap;
}
uint8_t *db_data(db *d) { return d->big ? d->big : d->b; }
void db_put8(db *d, uint8_t v) { db_room(d, 1); db_data(d)[d->n++] = v; }
void db_put16(db *d, uint16_t v) { db_put8(d, (uint8_t)(v & 0xffu)); db_put8(d, (uint8_t)(v >> 8)); }
void db_put32(db *d, uint32_t v) { for (int i = 0; i < 4; i++) db_put8(d, (uint8_t)((v >> (8 * i)) & 0xffu)); }
void db_put64(db *d, uint64_t v) { for (int i = 0; i < 8; i++) db_put8(d, (uint8_t)((v >> (8 * i)) & 0xffu)); }
void db_putb(db *d, const void *p, size_t n) { db_room(d, n); if (n) memcpy(db_data(d) + d->n, p, n); d->n += n; }
void db_free(db *d) { free(d->big); d->big = NULL; }
uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }

void drv_wire_call(db *d, const ren_call *k) {
  db_put64(d, k->id);
  db_put16(d, k->worker);
  db_put16(d, k->kind);
  db_put32(d, k->lane);
  db_put32(d, k->task);
  db_put32(d, k->op);
  db_put32(d, k->len);
  uint64_t h = 0;
  if (k->kind == REN_CALL && k->body) {
    const ren_io_body *b = (const ren_io_body *)k->body;
    db_put64(d, (uint64_t)b->fd);
    db_put64(d, b->len);
    db_put64(d, 0);
    db_put64(d, (uint64_t)b->arg);
    if (k->op == REN_OP_WRITE && b->len) {
      extern uint64_t ren_c_fnv1a(const uint8_t *p, uint64_t n);
      h = ren_c_fnv1a((const uint8_t *)(uintptr_t)b->buf, b->len);
    }
  }
  db_put64(d, h);
}

/* ---------------- recording ---------------- */
bool drv_recording(ren_drv *d) { return d->o.record_fd >= 0; }

static void rec_flush_locked(ren_drv *d) {
  size_t off = 0;
  while (off < d->rec_n) {
    ssize_t k = write(d->o.record_fd, d->rec_buf + off, d->rec_n - off);
    if (k < 0) { if (errno == EINTR) continue; d->rec_failed = errno; break; }
    off += (size_t)k;
  }
  d->rec_n = 0;
}
static void rec_append(ren_drv *d, const uint8_t *p, size_t n) {
  if (d->rec_n + n > d->rec_cap) {
    if (d->rec_n) rec_flush_locked(d);
    if (n > d->rec_cap) {
      d->rec_cap = n * 2;
      free(d->rec_buf);
      d->rec_buf = malloc(d->rec_cap);
      if (!d->rec_buf) abort();
    }
  }
  memcpy(d->rec_buf + d->rec_n, p, n);
  d->rec_n += n;
}
void drv_rec_flush(ren_drv *d) {
  if (!drv_recording(d)) return;
  pthread_mutex_lock(&d->rec_mu);
  rec_flush_locked(d);
  pthread_mutex_unlock(&d->rec_mu);
}
/* the core's entries, verbatim */
static void host_journal_rec(void *hp, int32_t w, const void *e, size_t n) {
  ren_drv *d = hp; (void)w;
  pthread_mutex_lock(&d->rec_mu);
  rec_append(d, e, n);
  pthread_mutex_unlock(&d->rec_mu);
}
void drv_rec_entry(ren_drv *d, uint32_t kind, int32_t w, uint64_t step, const uint8_t *pl, size_t len) {
  if (!drv_recording(d)) return;
  db h; db_init(&h);
  db_put32(&h, kind);
  db_put32(&h, (uint32_t)len);
  db_put32(&h, (uint32_t)w);
  db_put32(&h, 0);
  db_put64(&h, step);
  db_putb(&h, pl, len);
  pthread_mutex_lock(&d->rec_mu);
  rec_append(d, db_data(&h), h.n);
  pthread_mutex_unlock(&d->rec_mu);
  db_free(&h);
}
void drv_rec_drv(ren_drv *d) {
  if (!drv_recording(d)) return;
  db p; db_init(&p);
  db_put32(&p, d->o.kind);
  db_put32(&p, (uint32_t)d->o.workers);
  db_put32(&p, d->o.steps);
  drv_rec_entry(d, REN_J_DRV, 0, 0, db_data(&p), p.n);
  db_free(&p);
}
void drv_rec_run(ren_drv *d, ren_core *c, int32_t w, uint32_t steps, int32_t ret) {
  if (!drv_recording(d)) return;
  db p; db_init(&p);
  db_put32(&p, steps);
  db_put32(&p, (uint32_t)ret);
  drv_rec_entry(d, REN_J_RUN, w, ren_progress(c, w), db_data(&p), p.n);
  db_free(&p);
}
void drv_rec_pull(ren_drv *d, ren_core *c, int32_t w, const ren_call *k) {
  if (!drv_recording(d)) return;
  db p; db_init(&p);
  drv_wire_call(&p, k);
  drv_rec_entry(d, REN_J_PULL, w, ren_progress(c, w), db_data(&p), p.n);
  db_free(&p);
}
void drv_rec_drained(ren_drv *d, ren_core *c, int32_t w) {
  if (!drv_recording(d)) return;
  drv_rec_entry(d, REN_J_DRAINED, w, ren_progress(c, w), NULL, 0);
}
int32_t drv_reply(ren_drv *d, ren_core *c, int32_t w, uint64_t id, uint32_t state, int64_t res, int64_t a,
                  int64_t b, const void *in, uint32_t in_len) {
  ren_io_result r;
  r.res = res; r.a = a; r.b = b;
  ren_reply_t rp;
  rp.id = id; rp.state = state; rp.len = (uint32_t)sizeof r; rp.body = &r;
  int32_t ret = ren_reply(c, &rp);
  if (drv_recording(d)) {
    db p; db_init(&p);
    db_put64(&p, id);
    db_put32(&p, state);
    db_put32(&p, (uint32_t)sizeof r);
    db_put64(&p, (uint64_t)r.res);
    db_put64(&p, (uint64_t)r.a);
    db_put64(&p, (uint64_t)r.b);
    db_put32(&p, in_len);
    db_putb(&p, in, in_len);
    db_put32(&p, (uint32_t)ret);
    drv_rec_entry(d, REN_J_REPLY, w, ren_progress(c, w), db_data(&p), p.n);
    db_free(&p);
  }
  return ret;
}

void drv_set_err(ren_drv *d, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  if (d) vsnprintf(d->err, sizeof d->err, fmt, ap);
  else vsnprintf(ren_c_drv_global_err, sizeof ren_c_drv_global_err, fmt, ap);
  va_end(ap);
}

int64_t drv_mono_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}

/* ---------------- host callbacks (kernel drivers) ---------------- */
bool drv_answer_now(void *hp, int32_t w, const ren_call *k, ren_reply_t *out) {
  ren_drv *d = hp;
  if (k->op != REN_OP_MONO_NOW) return false;
  ren_io_result *r = &d->ans[w];         /* per worker: ren_world copies it at once */
  r->res = drv_mono_ns(); r->a = 0; r->b = 0;
  out->id = k->id; out->state = REN_DONE; out->len = (uint32_t)sizeof *r; out->body = r;
  return true;
}
void drv_wake(void *hp, int32_t w) {
  ren_drv *d = hp;
  uint64_t one = 1;
  for (;;) {
    ssize_t k = write(d->wake_fd[w], &one, sizeof one);
    if (k >= 0 || errno != EINTR) return;  /* EAGAIN: the counter is already set: still sticky */
  }
}
static void wake_nop(void *hp, int32_t w) { (void)hp; (void)w; }

/* ---------------- synchronous ops ---------------- */
int64_t drv_sync_pipe(int64_t *a, int64_t *b) {
  int fds[2];
  if (pipe2(fds, O_NONBLOCK | O_CLOEXEC) < 0) return -errno;
  *a = fds[0]; *b = fds[1];
  return 0;
}
int64_t drv_sync_listen(int64_t port, int64_t *bound_port) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
  if (fd < 0) return -errno;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof sa);
  sa.sin_family = AF_INET;
  sa.sin_port = htons((uint16_t)port);
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(fd, 128) < 0) {
    int e = errno; close(fd); return -e;
  }
  socklen_t sl = sizeof sa;
  if (getsockname(fd, (struct sockaddr *)&sa, &sl) < 0) { int e = errno; close(fd); return -e; }
  *bound_port = ntohs(sa.sin_port);
  return fd;
}

/* ---------------- the entry points ---------------- */
ren_drv *ren_drv_new(const ren_drv_opts *o) {
  if (!o) { drv_set_err(NULL, "ren_drv_new: NULL options"); return NULL; }
  if (o->workers < 1 || o->workers > 64) { drv_set_err(NULL, "ren_drv_new: workers %d out of range", o->workers); return NULL; }
  ren_drv *d = calloc(1, sizeof *d);
  if (!d) abort();
  d->o = *o;
  if (!d->o.steps) d->o.steps = 256;
  pthread_mutex_init(&d->rec_mu, NULL);
  if (drv_recording(d)) {
    d->rec_cap = 1u << 16;
    d->rec_buf = malloc(d->rec_cap);
    if (!d->rec_buf) abort();
  }
  switch (o->kind) {
  case REN_DRV_EPOLL:
  case REN_DRV_URING: {
    d->host.wake = drv_wake;
    d->host.answer_now = drv_answer_now;
    d->host.journal = drv_recording(d) ? host_journal_rec : NULL;
    d->ans = calloc((size_t)o->workers, sizeof *d->ans);
    d->wake_fd = malloc((size_t)o->workers * sizeof(int));
    d->wk = calloc((size_t)o->workers, sizeof(void *));
    if (!d->ans || !d->wake_fd || !d->wk) abort();
    for (int32_t w = 0; w < o->workers; w++) d->wake_fd[w] = -1;
    for (int32_t w = 0; w < o->workers; w++) {
      d->wake_fd[w] = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
      if (d->wake_fd[w] < 0) { drv_set_err(NULL, "eventfd: %s", strerror(errno)); ren_drv_free(d); return NULL; }
    }
    int r = o->kind == REN_DRV_EPOLL ? drv_epoll_new(d) : drv_uring_new(d);
    if (r != 0) {
      drv_set_err(NULL, "%s", d->err);
      ren_drv_free(d);
      return NULL;
    }
    break;
  }
  case REN_DRV_REPLAY:
    d->in = o->input; d->in_len = o->input_len;
    d->host.wake = wake_nop;
    d->host.answer_now = drv_replay_answer;
    d->host.journal = drv_replay_journal;
    break;
  case REN_DRV_FUZZ:
    d->in = o->input; d->in_len = o->input_len;
    d->host.wake = wake_nop;
    d->host.answer_now = NULL;
    d->host.journal = NULL;
    break;
  default:
    drv_set_err(NULL, "ren_drv_new: unknown driver kind %u", o->kind);
    ren_drv_free(d);
    return NULL;
  }
  return d;
}

const ren_host *ren_drv_host(ren_drv *d, void **hostp) { *hostp = d; return &d->host; }

int32_t ren_drv_worker(ren_drv *d, ren_core *c, int32_t w) {
  switch (d->o.kind) {
  case REN_DRV_EPOLL:
    if (w < 0 || w >= d->o.workers) { drv_set_err(d, "epoll: worker %d out of range", w); return -1; }
    return drv_epoll_worker(d, c, w);
  case REN_DRV_URING:
    if (w < 0 || w >= d->o.workers) { drv_set_err(d, "uring: worker %d out of range", w); return -1; }
    return drv_uring_worker(d, c, w);
  case REN_DRV_REPLAY:
    if (w != -1) { drv_set_err(d, "replay drives every worker: worker must be -1"); return -1; }
    return drv_replay_run(d, c);
  case REN_DRV_FUZZ:
    if (w != -1) { drv_set_err(d, "fuzz drives every worker: worker must be -1"); return -1; }
    return drv_fuzz_run(d, c);
  }
  return -1;
}

int32_t ren_drv_finish(ren_drv *d, ren_core *c) {
  (void)c;
  drv_rec_flush(d);
  if (d->rec_failed) { drv_set_err(d, "record: write failed: %s", strerror(d->rec_failed)); return -1; }
  if (d->o.kind == REN_DRV_REPLAY) return d->diverged;
  if (d->o.kind == REN_DRV_FUZZ) return d->fuzz_fail;
  return 0;
}

void ren_drv_free(ren_drv *d) {
  if (!d) return;
  if (d->o.kind == REN_DRV_EPOLL) drv_epoll_free(d);
  if (d->o.kind == REN_DRV_URING) drv_uring_free(d);
  if (d->wake_fd)
    for (int32_t w = 0; w < d->o.workers; w++) if (d->wake_fd[w] >= 0) close(d->wake_fd[w]);
  free(d->wake_fd);
  free(d->wk);
  free(d->ans);
  while (d->kept) { kept *k = d->kept; d->kept = k->next; free(k); }
  free(d->rec_buf);
  pthread_mutex_destroy(&d->rec_mu);
  free(d);
}

const char *ren_drv_last_error(ren_drv *d) { return d ? d->err : ren_c_drv_global_err; }
