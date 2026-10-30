/* stub_drv.c: NOT ONE OF THE THREE ENTRIES. The stub's drivers:
   - REN_DRV_EPOLL is a *blocking* stand-in: every pulled call is done
     synchronously with a blocking syscall (no epoll), and SleepUntil
     sleeps. Enough for W1-W3 at one worker; it would deadlock T_PIPE.
   - REN_DRV_REPLAY follows SPEC §D.1.
   - URING and FUZZ are not provided (ren_drv_new returns NULL).
   Recording follows SPEC §C.1. Language entries must not copy this. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../slice.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

typedef struct timer { struct timer *next; uint64_t id; int64_t t; } timer;
typedef struct kept { struct kept *next; ren_call call; } kept;

struct ren_drv {
  ren_drv_opts o;
  ren_host host;
  timer *timers;            /* sorted by (t, id) */
  /* replay */
  const uint8_t *in; size_t in_len;
  size_t core_pos;          /* next recorded core entry (byte offset) */
  size_t entry_no;          /* 1-based index of the entry being checked */
  int diverged;
  char err[256];
  kept *kept;
};

static char g_err[128] = "";
const char *ren_drv_last_error(ren_drv *d) { return d ? d->err : g_err; }

/* ---- recording ---- */
static void rec_write(ren_drv *d, const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    ssize_t k = write(d->o.record_fd, b, n);
    if (k < 0) { if (errno == EINTR) continue; perror("record"); abort(); }
    b += k; n -= (size_t)k;
  }
}
static void rec_entry(ren_drv *d, uint32_t kind, int32_t w, uint64_t step, const void *pl, uint32_t len) {
  if (d->o.record_fd < 0) return;
  uint8_t h[24]; uint32_t pad = 0;
  memcpy(h, &kind, 4); memcpy(h + 4, &len, 4); memcpy(h + 8, &w, 4); memcpy(h + 12, &pad, 4); memcpy(h + 16, &step, 8);
  rec_write(d, h, 24);
  if (len) rec_write(d, pl, len);
}
static void host_journal_rec(void *hp, int32_t w, const void *e, size_t n) {
  ren_drv *d = hp; (void)w;
  if (d->o.record_fd >= 0) rec_write(d, e, n);
}

/* the wire call (SPEC §B.7), shared by J_PULL */
static size_t wire_call(const ren_call *k, uint8_t *b) {
  size_t n = 0;
  uint16_t w = k->worker, kind = k->kind;
  memcpy(b + n, &k->id, 8); n += 8; memcpy(b + n, &w, 2); n += 2; memcpy(b + n, &kind, 2); n += 2;
  memcpy(b + n, &k->lane, 4); n += 4; memcpy(b + n, &k->task, 4); n += 4; memcpy(b + n, &k->op, 4); n += 4;
  memcpy(b + n, &k->len, 4); n += 4;
  uint64_t h = 0;
  if (k->kind == REN_CALL && k->len == sizeof(ren_io_body)) {
    ren_io_body bd = *(const ren_io_body *)k->body;
    if (k->op == REN_OP_WRITE) {
      const unsigned char *p = (const unsigned char *)(uintptr_t)bd.buf;
      h = 0xcbf29ce484222325ull;
      for (uint64_t i = 0; i < bd.len; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
    }
    uint64_t zero = 0;   /* field by field, never the struct (SPEC §B.7) */
    memcpy(b + n, &bd.fd, 8); n += 8; memcpy(b + n, &bd.len, 8); n += 8;
    memcpy(b + n, &zero, 8); n += 8; memcpy(b + n, &bd.arg, 8); n += 8;
  }
  memcpy(b + n, &h, 8); n += 8;
  return n;
}

static void put_reply_entry(ren_drv *d, int32_t w, uint64_t step, uint64_t id, uint32_t state,
                            const ren_io_result *r, const void *in, uint32_t in_len, int32_t ret) {
  if (d->o.record_fd < 0) return;
  size_t n = 8 + 4 + 4 + sizeof *r + 4 + in_len + 4;
  uint8_t *b = malloc(n), *p = b;
  uint32_t len = sizeof *r;
  memcpy(p, &id, 8); p += 8; memcpy(p, &state, 4); p += 4; memcpy(p, &len, 4); p += 4;
  memcpy(p, r, sizeof *r); p += sizeof *r; memcpy(p, &in_len, 4); p += 4;
  if (in_len) memcpy(p, in, in_len);
  p += in_len;
  memcpy(p, &ret, 4);
  rec_entry(d, REN_J_REPLY, w, step, b, (uint32_t)n);
  free(b);
}

static bool host_answer_now(void *hp, int32_t w, const ren_call *c, ren_reply_t *out) {
  (void)hp; (void)w;
  static ren_io_result r; /* the stub is single-threaded (and tcc 0.9.27 has no TLS) */
  if (c->op != REN_OP_MONO_NOW) return false;
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  r.res = (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec; r.a = r.b = 0;
  out->id = c->id; out->state = REN_DONE; out->len = sizeof r; out->body = &r;
  return true;
}
static void host_wake(void *hp, int32_t w) { (void)hp; (void)w; }

/* ================= replay ================= */
static int rd_ent(const uint8_t *in, size_t len, size_t pos, uint32_t *kind, uint32_t *plen, int32_t *w) {
  if (pos + 24 > len) return 0;
  memcpy(kind, in + pos, 4); memcpy(plen, in + pos + 4, 4); memcpy(w, in + pos + 8, 4);
  return pos + 24 + *plen <= len;
}
static void diverge(ren_drv *d, const char *what) {
  if (d->diverged) return;
  d->diverged = (int)d->entry_no ? (int)d->entry_no : 1;
  snprintf(d->err, sizeof d->err, "replay diverged at entry %zu: %s", d->entry_no, what);
}
/* the replaying core's journal: compare with the next recorded core entry */
static void host_journal_replay(void *hp, int32_t w, const void *e, size_t n) {
  ren_drv *d = hp; (void)w;
  uint32_t kind, plen; int32_t ww;
  while (rd_ent(d->in, d->in_len, d->core_pos, &kind, &plen, &ww) && kind >= 16)
    d->core_pos += 24 + plen;
  if (!rd_ent(d->in, d->in_len, d->core_pos, &kind, &plen, &ww)) { diverge(d, "late end: the core wrote more than the recording"); return; }
  if (24 + plen != n || memcmp(d->in + d->core_pos, e, n) != 0) {
    char m[96];
    uint32_t k2; memcpy(&k2, e, 4);
    snprintf(m, sizeof m, "core entry differs (recorded kind %u, replayed kind %u)", kind, k2);
    diverge(d, m);
  }
  d->core_pos += 24 + plen;
}
static bool host_answer_replay(void *hp, int32_t w, const ren_call *c, ren_reply_t *out) {
  ren_drv *d = hp; (void)w;
  static ren_io_result r;
  /* the recorded DELIVER for this id, after the CALL we are comparing against */
  size_t pos = d->core_pos;
  uint32_t kind, plen; int32_t ww;
  while (rd_ent(d->in, d->in_len, pos, &kind, &plen, &ww)) {
    if (kind == REN_J_DELIVER) {
      uint64_t id; memcpy(&id, d->in + pos + 24, 8);
      if (id == c->id) {
        uint32_t st; memcpy(&st, d->in + pos + 32, 4);
        memcpy(&r, d->in + pos + 40, sizeof r);
        out->id = id; out->state = st; out->len = sizeof r; out->body = &r;
        return true;
      }
    }
    if (kind == REN_J_RUN || kind == REN_J_PULL) break;   /* not answered inline */
    pos += 24 + plen;
  }
  return false;
}

static int32_t replay_all(ren_drv *d, ren_core *c) {
  size_t pos = 0;
  uint32_t kind, plen; int32_t w;
  d->entry_no = 0;
  while (!d->diverged && rd_ent(d->in, d->in_len, pos, &kind, &plen, &w)) {
    const uint8_t *p = d->in + pos + 24;
    d->entry_no++;
    if (kind >= 16) {
      if (kind == REN_J_RUN) {
        uint32_t steps; int32_t ret;
        memcpy(&steps, p, 4); memcpy(&ret, p + 4, 4);
        int32_t r = ren_run(c, w, steps);
        if (r != ret) diverge(d, "ren_run returned a different result");
      } else if (kind == REN_J_PULL) {
        ren_call call;
        if (!ren_poll_call(c, w, &call)) diverge(d, "ren_poll_call returned false; recorded a call");
        else {
          uint8_t b[128]; size_t n = wire_call(&call, b);
          if (n != plen || memcmp(b, p, n) != 0) diverge(d, "pulled call differs");
          if (call.kind == REN_CALL) { kept *k = calloc(1, sizeof *k); k->call = call; k->next = d->kept; d->kept = k; }
        }
      } else if (kind == REN_J_DRAINED) {
        ren_call call;
        if (ren_poll_call(c, w, &call)) diverge(d, "ren_poll_call returned a call; recorded drained");
      } else if (kind == REN_J_REPLY) {
        uint64_t id; uint32_t st, len, in_len; int32_t ret;
        memcpy(&id, p, 8); memcpy(&st, p + 8, 4); memcpy(&len, p + 12, 4);
        ren_io_result res; memcpy(&res, p + 16, sizeof res);
        memcpy(&in_len, p + 16 + len, 4);
        const uint8_t *inb = p + 20 + len;
        memcpy(&ret, inb + in_len, 4);
        kept **kp = &d->kept;
        while (*kp && (*kp)->call.id != id) kp = &(*kp)->next;
        if (in_len) {
          if (!*kp) diverge(d, "reply bytes for a call never pulled");
          else memcpy((void *)(uintptr_t)((const ren_io_body *)(*kp)->call.body)->buf, inb, in_len);
        }
        if (*kp) { kept *k = *kp; *kp = k->next; free(k); }   /* the final reply: forget it */
        ren_reply_t r = {.id = id, .state = st, .len = sizeof res, .body = &res};
        if (ren_reply(c, &r) != ret) diverge(d, "ren_reply returned a different result");
      }
      /* J_DRV: nothing to do */
    }
    pos += 24 + plen;
  }
  if (!d->diverged) {
    /* every recorded core entry must have been matched */
    while (rd_ent(d->in, d->in_len, d->core_pos, &kind, &plen, &w) && kind >= 16) d->core_pos += 24 + plen;
    if (d->core_pos < d->in_len) diverge(d, "early end: recorded core entries were not produced");
  }
  return 0;
}

/* ================= the blocking stand-in for epoll ================= */
static int64_t mono_ns(void) {
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000ll + ts.tv_nsec;
}
static void reply(ren_drv *d, ren_core *c, uint64_t id, uint32_t st, int64_t res, int64_t a, int64_t b,
                  const void *in, uint32_t in_len) {
  ren_io_result r = {.res = res, .a = a, .b = b};
  ren_reply_t rp = {.id = id, .state = st, .len = sizeof r, .body = &r};
  int32_t ret = ren_reply(c, &rp);
  put_reply_entry(d, 0, ren_progress(c, 0), id, st, &r, in, in_len, ret);
  /* RELEASE: the stub has nothing to give back */
}
static void submit(ren_drv *d, ren_core *c, const ren_call *k) {
  if (k->kind == REN_CANCEL) {
    for (timer **pp = &d->timers; *pp; pp = &(*pp)->next)
      if ((*pp)->id == k->id) {
        timer *t = *pp; *pp = t->next; free(t);
        reply(d, c, k->id, REN_CANCELLED, -REN_ECANCELED, 0, 0, NULL, 0);
        return;
      }
    return; /* completed already, or blocking: ignore */
  }
  const ren_io_body *b = k->body;
  int64_t r;
  switch (k->op) {
  case REN_OP_SLEEP_UNTIL: {
    timer *t = calloc(1, sizeof *t), **pp = &d->timers;
    t->id = k->id; t->t = b->arg;
    while (*pp && ((*pp)->t < t->t || ((*pp)->t == t->t && (*pp)->id < t->id))) pp = &(*pp)->next;
    t->next = *pp; *pp = t;
    return;
  }
  case REN_OP_PIPE: {
    int fds[2];
    r = pipe2(fds, O_CLOEXEC) < 0 ? -errno : 0;
    reply(d, c, k->id, REN_DONE, r, r ? 0 : fds[0], r ? 0 : fds[1], NULL, 0);
    return;
  }
  case REN_OP_READ:
    r = read((int)b->fd, (void *)(uintptr_t)b->buf, b->len);
    if (r < 0) r = -errno;
    reply(d, c, k->id, REN_DONE, r, 0, 0, (void *)(uintptr_t)b->buf, r > 0 ? (uint32_t)r : 0);
    return;
  case REN_OP_WRITE:
    r = write((int)b->fd, (const void *)(uintptr_t)b->buf, b->len);
    reply(d, c, k->id, REN_DONE, r < 0 ? -errno : r, 0, 0, NULL, 0);
    return;
  case REN_OP_CLOSE:
    r = close((int)b->fd) < 0 ? -errno : 0;
    reply(d, c, k->id, REN_DONE, r, 0, 0, NULL, 0);
    return;
  default:
    reply(d, c, k->id, REN_DONE, -ENOSYS, 0, 0, NULL, 0);
  }
}

ren_drv *ren_drv_new(const ren_drv_opts *o) {
  if (o->kind == REN_DRV_URING || o->kind == REN_DRV_FUZZ) {
    snprintf(g_err, sizeof g_err, "stub: driver kind %u is not provided by the stub", o->kind);
    return NULL;
  }
  if (o->workers != 1) { snprintf(g_err, sizeof g_err, "stub: one worker only"); return NULL; }
  ren_drv *d = calloc(1, sizeof *d);
  d->o = *o;
  if (!d->o.steps) d->o.steps = 256;
  d->host.wake = host_wake;
  if (o->kind == REN_DRV_REPLAY) {
    d->in = o->input; d->in_len = o->input_len;
    d->host.answer_now = host_answer_replay;
    d->host.journal = host_journal_replay;
  } else {
    d->host.answer_now = host_answer_now;
    d->host.journal = o->record_fd >= 0 ? host_journal_rec : NULL;
  }
  return d;
}
const ren_host *ren_drv_host(ren_drv *d, void **hostp) { *hostp = d; return &d->host; }

int32_t ren_drv_worker(ren_drv *d, ren_core *c, int32_t w) {
  if (d->o.kind == REN_DRV_REPLAY) return replay_all(d, c);
  if (w != 0) return -1;
  if (d->o.record_fd >= 0) {
    uint32_t pl[3] = {d->o.kind, (uint32_t)d->o.workers, d->o.steps};
    rec_entry(d, REN_J_DRV, 0, 0, pl, sizeof pl);
  }
  for (;;) {
    int32_t r = ren_run(c, 0, d->o.steps);
    int32_t pl[2] = {(int32_t)d->o.steps, r};
    rec_entry(d, REN_J_RUN, 0, ren_progress(c, 0), pl, sizeof pl);
    ren_call k;
    /* pull everything first, then act: what a driver that batches does */
    ren_call *batch = NULL; size_t nb = 0, cb = 0;
    while (ren_poll_call(c, 0, &k)) {
      uint8_t b[128]; size_t n = wire_call(&k, b);
      rec_entry(d, REN_J_PULL, 0, ren_progress(c, 0), b, (uint32_t)n);
      if (nb == cb) { cb = cb ? 2 * cb : 16; batch = realloc(batch, cb * sizeof *batch); }
      batch[nb++] = k;
    }
    rec_entry(d, REN_J_DRAINED, 0, ren_progress(c, 0), NULL, 0);
    for (size_t i = 0; i < nb; i++) submit(d, c, &batch[i]);
    free(batch);
    if (r == REN_FINISHED && !d->timers) break;
    if (r == REN_FINISHED) { /* after kill: drop the timers */
      while (d->timers) { timer *t = d->timers; d->timers = t->next; reply(d, c, t->id, REN_CANCELLED, -REN_ECANCELED, 0, 0, NULL, 0); free(t); }
      continue;
    }
    if (r == REN_IDLE && nb == 0 && d->timers) {
      int64_t now = mono_ns();
      if (d->timers->t > now) {
        struct timespec ts = {d->timers->t / 1000000000ll, d->timers->t % 1000000000ll};
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
      }
    }
    int64_t now = mono_ns();
    while (d->timers && d->timers->t <= now) {
      timer *t = d->timers; d->timers = t->next;
      reply(d, c, t->id, REN_DONE, 0, 0, 0, NULL, 0);
      free(t);
    }
    if (r == REN_IDLE && nb == 0 && !d->timers) {
      snprintf(d->err, sizeof d->err, "stub driver: idle with nothing in flight (deadlock)");
      return -1;
    }
  }
  return 0;
}
int32_t ren_drv_finish(ren_drv *d, ren_core *c) { (void)c; return d->diverged; }
void ren_drv_free(ren_drv *d) {
  while (d->kept) { kept *k = d->kept; d->kept = k->next; free(k); }
  free(d);
}
