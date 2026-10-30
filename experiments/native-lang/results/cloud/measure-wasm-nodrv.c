/* wasm32 probe: no kernel drivers on WASI (stubs so the replay driver links) */
#include "drv.h"
int drv_epoll_new(ren_drv *d) { (void)d; return -1; }
int drv_uring_new(ren_drv *d) { (void)d; return -1; }
void drv_epoll_free(ren_drv *d) { (void)d; }
void drv_uring_free(ren_drv *d) { (void)d; }
int drv_epoll_worker(ren_drv *d, ren_core *c, int w) { (void)d; (void)c; (void)w; return -1; }
int drv_uring_worker(ren_drv *d, ren_core *c, int w) { (void)d; (void)c; (void)w; return -1; }
int eventfd(unsigned v, int f) { (void)v; (void)f; return -1; }
