/* fuzz_common.c: one fuzz case (SPEC §D.4): the language's FUZZ driver
   runs w_fuzz on two workers from one thread, fed [data]. */
#include "slice.h"
#include "../workloads/wl.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int fuzz_one(const uint8_t *data, size_t len) {
  const wl_def *wl = wl_find("w_fuzz");
  wl_args wa = {0, 0, 2};
  void *user = wl->init(&wa);
  ren_drv_opts o;
  memset(&o, 0, sizeof o);
  o.kind = REN_DRV_FUZZ; o.workers = 2; o.record_fd = -1; o.input = data; o.input_len = len;
  ren_drv *d = ren_drv_new(&o);
  if (!d) { fprintf(stderr, "fuzz: ren_drv_new(FUZZ): %s\n", ren_drv_last_error(NULL)); abort(); }
  void *hp;
  const ren_host *h = ren_drv_host(d, &hp);
  ren_config cfg;
  memset(&cfg, 0, sizeof cfg);
  cfg.workers = 2; cfg.op_slots = 8; cfg.budget_b = 4; cfg.poll_k = 5;  /* small: reuse slots, yield, poll */
  cfg.build_id = "fuzz"; cfg.user = user;
  ren_core *c = ren_start(&cfg, wl->main, h, hp);
  if (!c) abort();
  ren_thread_init(c, 0, NULL, 0);
  ren_thread_init(c, 1, NULL, 0);
  int32_t r = ren_drv_worker(d, c, -1);
  int32_t f = ren_drv_finish(d, c);
  if (r != 0 || f != 0) {
    fprintf(stderr, "fuzz: oracle failure (worker %d, finish %d): %s\n", r, f, ren_drv_last_error(d));
    abort();
  }
  ren_free(c);
  ren_drv_free(d);
  wl->fini(user);
  return 0;
}
