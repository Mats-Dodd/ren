/* drv.h: the C entry's drivers (SPEC §C, §D). One ren_drv for every kind;
   per-worker state for the kernel drivers lives in drv_epoll.c and
   drv_uring.c. */
#ifndef REN_C_DRV_H
#define REN_C_DRV_H
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "atom.h"
#include <pthread.h>
#include <stdio.h>

typedef struct kept { struct kept *next; ren_call call; } kept;

struct ren_drv {
  ren_drv_opts o;
  ren_host host;
  char err[256];
  /* recording */
  pthread_mutex_t rec_mu;
  uint8_t *rec_buf; size_t rec_n, rec_cap;
  int rec_failed;
  /* kernel drivers */
  int *wake_fd;                   /* per worker eventfd (EFD_NONBLOCK) */
  void **wk;                      /* per worker driver state */
  uint32_t uring_setup_flags;     /* what io_uring_setup accepted */
  int uring_fallback;             /* 1: SINGLE_ISSUER|DEFER_TASKRUN refused (EINVAL) */
  /* replay and fuzz */
  const uint8_t *in; size_t in_len;
  size_t core_pos;                /* file offset of the next recorded core entry */
  size_t last_core_end;           /* file offset just past the last matched core entry */
  size_t entry_no;                /* 1-based index of the entry being worked on */
  size_t core_entry_no;           /* 1-based index of the recorded core entry being compared */
  int32_t diverged;
  kept *kept;
  ren_io_result answer;           /* replay answer_now reply body (one driving thread) */
  ren_io_result *ans;             /* kernel drivers: answer_now reply body, per worker */
  int32_t fuzz_fail;
};

/* little-endian field writers for driver entries */
typedef struct db { uint8_t b[64 + 4096 + 64]; size_t n; uint8_t *big; size_t cap; } db;
void db_init(db *d);
void db_put8(db *d, uint8_t v);
void db_put16(db *d, uint16_t v);
void db_put32(db *d, uint32_t v);
void db_put64(db *d, uint64_t v);
void db_putb(db *d, const void *p, size_t n);
uint8_t *db_data(db *d);
void db_free(db *d);
uint32_t rd32(const uint8_t *p);
uint64_t rd64(const uint8_t *p);

void drv_wire_call(db *d, const ren_call *k);         /* J_PULL payload (= CALL payload) */
bool drv_recording(ren_drv *d);
void drv_rec_entry(ren_drv *d, uint32_t kind, int32_t w, uint64_t step, const uint8_t *pl, size_t len);
void drv_rec_drv(ren_drv *d);
void drv_rec_run(ren_drv *d, ren_core *c, int32_t w, uint32_t steps, int32_t ret);
void drv_rec_pull(ren_drv *d, ren_core *c, int32_t w, const ren_call *k);
void drv_rec_drained(ren_drv *d, ren_core *c, int32_t w);
/* ren_reply + J_REPLY; returns ren_reply's result */
int32_t drv_reply(ren_drv *d, ren_core *c, int32_t w, uint64_t id, uint32_t state, int64_t res, int64_t a,
                  int64_t b, const void *in, uint32_t in_len);
void drv_rec_flush(ren_drv *d);
void drv_set_err(ren_drv *d, const char *fmt, ...);
int64_t drv_mono_ns(void);
bool drv_answer_now(void *hp, int32_t w, const ren_call *k, ren_reply_t *out);
void drv_wake(void *hp, int32_t w);

/* per kind */
int drv_epoll_new(ren_drv *d);
int32_t drv_epoll_worker(ren_drv *d, ren_core *c, int32_t w);
void drv_epoll_free(ren_drv *d);
int drv_uring_new(ren_drv *d);
int32_t drv_uring_worker(ren_drv *d, ren_core *c, int32_t w);
void drv_uring_free(ren_drv *d);
int32_t drv_replay_run(ren_drv *d, ren_core *c);
int32_t drv_fuzz_run(ren_drv *d, ren_core *c);
bool drv_replay_answer(void *hp, int32_t w, const ren_call *k, ren_reply_t *out);
void drv_replay_journal(void *hp, int32_t w, const void *e, size_t n);

/* shared synchronous ops (PIPE, LISTEN, CONNECT socket creation) */
int64_t drv_sync_pipe(int64_t *a, int64_t *b);
int64_t drv_sync_listen(int64_t port, int64_t *bound_port);

extern char ren_c_drv_global_err[160];
#endif
