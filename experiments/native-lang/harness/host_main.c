/* host_main.c: the default host. It starts one thread per worker, binds
   each to its worker with ren_thread_init, runs the language's driver
   loop on it, then finishes, frees and reports. The core never creates
   threads (research/runtime/SYNTHESIS.md §2.3).

   harness <workload> [--driver epoll|uring|replay] [--workers N] [--n N]
           [--steps S] [--record FILE] [--replay FILE] [--stop-ms MS]
           [--kill-ms MS] [--no-defer] [--quiet]

   stdout: "result: ..." (deterministic; replay compares it) and
           "metric: ..." lines. Exit 0 = correct run. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "slice.h"
#include "workloads/wl.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define STACK_SIZE (8u << 20)

typedef struct {
  ren_drv *drv;
  ren_core *core;
  int worker;
  void *stack;
  int rc;
} wthread;

static void *worker_main(void *p) {
  wthread *w = p;
  ren_thread_init(w->core, w->worker, w->stack, STACK_SIZE);
  w->rc = ren_drv_worker(w->drv, w->core, w->worker);
  return NULL;
}

typedef struct { ren_core *core; int ms; int kill; } stopper;
static void *stopper_main(void *p) {
  stopper *s = p;
  struct timespec ts = {s->ms / 1000, (long)(s->ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
  if (s->kill) ren_kill(s->core); else ren_stop(s->core);
  return NULL;
}

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

static uint8_t *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc(n > 0 ? (size_t)n : 1);
  if (n > 0 && fread(b, 1, (size_t)n, f) != (size_t)n) { perror("fread"); exit(2); }
  fclose(f);
  *len = (size_t)n;
  return b;
}

static void usage(void) {
  fprintf(stderr, "usage: harness <workload> [--driver epoll|uring|replay] [--workers N] [--n N]\n"
                  "       [--steps S] [--record F] [--replay F] [--stop-ms MS] [--kill-ms MS]\n"
                  "       [--no-defer] [--quiet]\nworkloads:");
  wl_list(stderr);
  exit(2);
}

int main(int argc, char **argv) {
  if (argc < 2) usage();
  const wl_def *wl = wl_find(argv[1]);
  if (!wl) usage();
  const char *driver = "epoll", *record = NULL, *replay = NULL;
  int workers = 1, stop_ms = -1, kill_ms = -1, quiet = 0;
  long n = 0;
  uint32_t steps = 0, flags = 0;
  for (int i = 2; i < argc; i++) {
    const char *a = argv[i];
#define ARG() (i + 1 < argc ? argv[++i] : (usage(), ""))
    if (!strcmp(a, "--driver")) driver = ARG();
    else if (!strcmp(a, "--workers")) workers = atoi(ARG());
    else if (!strcmp(a, "--n")) n = atol(ARG());
    else if (!strcmp(a, "--steps")) steps = (uint32_t)atol(ARG());
    else if (!strcmp(a, "--record")) record = ARG();
    else if (!strcmp(a, "--replay")) { replay = ARG(); driver = "replay"; }
    else if (!strcmp(a, "--stop-ms")) stop_ms = atoi(ARG());
    else if (!strcmp(a, "--kill-ms")) kill_ms = atoi(ARG());
    else if (!strcmp(a, "--no-defer")) flags |= REN_DRV_F_URING_NO_DEFER;
    else if (!strcmp(a, "--quiet")) quiet = 1;
    else usage();
  }
  ren_drv_opts o;
  memset(&o, 0, sizeof o);
  o.workers = workers;
  o.steps = steps;
  o.record_fd = -1;
  o.flags = flags;
  if (!strcmp(driver, "epoll")) o.kind = REN_DRV_EPOLL;
  else if (!strcmp(driver, "uring")) o.kind = REN_DRV_URING;
  else if (!strcmp(driver, "replay")) o.kind = REN_DRV_REPLAY;
  else usage();
  if (o.kind == REN_DRV_REPLAY) {
    if (!replay) usage();
    o.input = read_file(replay, &o.input_len);
  }
  if (record) {
    o.record_fd = open(record, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (o.record_fd < 0) { perror(record); return 2; }
  }

  wl_args wa = {n, o.kind == REN_DRV_REPLAY ? 0 : 1, workers};
  void *user = wl->init(&wa);
  ren_config cfg;
  memset(&cfg, 0, sizeof cfg);
  cfg.workers = workers;
  cfg.build_id = "native-lang-harness-v1";
  cfg.journal_policy = REN_JPOL_INPUTS_INLINE | REN_JPOL_OUTPUTS_HASH;
  cfg.user = user;

  ren_drv *drv = ren_drv_new(&o);
  if (!drv) {
    fprintf(stderr, "harness: ren_drv_new(%s) failed: %s\n", driver, ren_drv_last_error(NULL));
    return 3;
  }
  void *hostp = NULL;
  const ren_host *host = ren_drv_host(drv, &hostp);
  double t0 = now_s();
  ren_core *core = ren_start(&cfg, wl->main, host, hostp);
  if (!core) { fprintf(stderr, "harness: ren_start failed\n"); return 3; }

  int rc = 0;
  pthread_t stopth;
  stopper sp = {core, stop_ms >= 0 ? stop_ms : kill_ms, kill_ms >= 0};
  int have_stopper = stop_ms >= 0 || kill_ms >= 0;
  if (have_stopper) pthread_create(&stopth, NULL, stopper_main, &sp);

  if (o.kind == REN_DRV_REPLAY) {
    /* one thread drives every worker, so every worker is bound to it */
    for (int w = 0; w < workers; w++) ren_thread_init(core, w, NULL, 0);
    rc = ren_drv_worker(drv, core, -1);
  } else {
    wthread *ws = calloc((size_t)workers, sizeof *ws);
    pthread_t *th = calloc((size_t)workers, sizeof *th);
    for (int w = 0; w < workers; w++) {
      ws[w].drv = drv; ws[w].core = core; ws[w].worker = w;
      ws[w].stack = mmap(NULL, STACK_SIZE, PROT_READ | PROT_WRITE,
                         MAP_PRIVATE | MAP_ANONYMOUS | MAP_STACK, -1, 0);
      if (ws[w].stack == MAP_FAILED) { perror("mmap stack"); return 3; }
      pthread_attr_t at;
      pthread_attr_init(&at);
      pthread_attr_setstack(&at, ws[w].stack, STACK_SIZE);
      if (pthread_create(&th[w], &at, worker_main, &ws[w]) != 0) { perror("pthread_create"); return 3; }
      pthread_attr_destroy(&at);
    }
    for (int w = 0; w < workers; w++) {
      pthread_join(th[w], NULL);
      if (ws[w].rc != 0) { fprintf(stderr, "harness: worker %d driver returned %d\n", w, ws[w].rc); rc = ws[w].rc; }
      munmap(ws[w].stack, STACK_SIZE);
    }
    free(ws); free(th);
  }
  if (have_stopper) pthread_join(stopth, NULL);
  int fin = ren_drv_finish(drv, core);
  double wall = now_s() - t0;
  if (fin != 0) {
    fprintf(stderr, "harness: ren_drv_finish = %d: %s\n", fin, ren_drv_last_error(drv));
    rc = rc ? rc : (fin > 0 ? 4 : 3);
  }
  ren_free(core);
  ren_drv_free(drv);
  if (o.record_fd >= 0) close(o.record_fd);

  int bad = 0;
  if (kill_ms >= 0) {
    printf("result: %s killed\n", wl->name);   /* nothing of the workload is promised */
  } else {
    bad = wl->report(user, stdout, quiet ? fopen("/dev/null", "w") : stdout, wall);
    if (bad) fprintf(stderr, "harness: %s: workload check failed\n", wl->name);
  }
  printf("metric: harness workload=%s driver=%s workers=%d wall_s=%.6f\n", wl->name, driver, workers, wall);
  wl->fini(user);
  free((void *)o.input);
  return rc ? rc : (bad ? 1 : 0);
}
