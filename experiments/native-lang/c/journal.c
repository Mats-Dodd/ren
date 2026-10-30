/* journal.c: the core's journal entries (SPEC §B.7). Every field is
   written on its own, little-endian, from the slice.h types: never a
   struct copy, so a field inserted into a slice.h struct cannot move the
   wire. */
#include "core.h"
#include <stdlib.h>
#include <string.h>

typedef struct jb {
  uint8_t *p;
  size_t n, cap;
  uint8_t small[256];
} jb;

static void jb_init(jb *j) { j->p = j->small; j->n = REN_JENT_BYTES; j->cap = sizeof j->small; }
static void jb_room(jb *j, size_t k) {
  if (j->n + k <= j->cap) return;
  size_t cap = (j->n + k) * 2;
  uint8_t *np = malloc(cap);
  if (!np) abort();
  memcpy(np, j->p, j->n);
  if (j->p != j->small) free(j->p);
  j->p = np; j->cap = cap;
}
static void put8(jb *j, uint8_t v) { jb_room(j, 1); j->p[j->n++] = v; }
static void put16(jb *j, uint16_t v) { put8(j, (uint8_t)(v & 0xffu)); put8(j, (uint8_t)(v >> 8)); }
static void put32(jb *j, uint32_t v) { for (int i = 0; i < 4; i++) put8(j, (uint8_t)((v >> (8 * i)) & 0xffu)); }
static void put64(jb *j, uint64_t v) { for (int i = 0; i < 8; i++) put8(j, (uint8_t)((v >> (8 * i)) & 0xffu)); }
static void putb(jb *j, const uint8_t *b, size_t n) { jb_room(j, n); if (n) memcpy(j->p + j->n, b, n); j->n += n; }
static void wr32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)((v >> (8 * i)) & 0xffu); }
static void wr64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)((v >> (8 * i)) & 0xffu); }

static void jb_emit(ren_core *c, jb *j, uint32_t kind, int32_t w) {
  uint64_t step = w >= 0 ? LD(&c->W[w].steps, RLX) : 0;
  wr32(j->p + 0, kind);
  wr32(j->p + 4, (uint32_t)(j->n - REN_JENT_BYTES));
  wr32(j->p + 8, (uint32_t)w);
  wr32(j->p + 12, 0);
  wr64(j->p + 16, step);
  c->host.journal(c->hostp, w, j->p, j->n);
  if (j->p != j->small) free(j->p);
}

NO_SAN_INT uint64_t ren_c_fnv1a(const uint8_t *p, uint64_t n) {
  uint64_t h = 0xcbf29ce484222325ull;
  for (uint64_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; }
  return h;
}

void j_header(ren_core *c) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  const char *bid = c->cfg.build_id ? c->cfg.build_id : "";
  size_t n = strlen(bid);
  put32(&j, REN_SLICE_VERSION);
  put32(&j, (uint32_t)c->nw);
  put32(&j, c->B);
  put32(&j, c->K);
  put32(&j, c->cfg.journal_policy);
  put32(&j, (uint32_t)n);
  putb(&j, (const uint8_t *)bid, n);
  jb_emit(c, &j, REN_J_HEADER, -1);
}

void j_call(ren_core *c, int32_t w, const ren_call *k) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  put64(&j, k->id);
  put16(&j, k->worker);
  put16(&j, k->kind);
  put32(&j, k->lane);
  put32(&j, k->task);
  put32(&j, k->op);
  put32(&j, k->len);
  uint64_t h = 0;
  if (k->kind == REN_CALL) {
    const ren_io_body *b = (const ren_io_body *)k->body;
    put64(&j, (uint64_t)b->fd);
    put64(&j, b->len);
    put64(&j, 0);                      /* buf: pointers differ between runs */
    put64(&j, (uint64_t)b->arg);
    if (k->op == REN_OP_WRITE && b->len) h = ren_c_fnv1a((const uint8_t *)(uintptr_t)b->buf, b->len);
  }
  put64(&j, h);
  jb_emit(c, &j, REN_J_CALL, w);
}

void j_deliver(ren_core *c, int32_t w, uint64_t id, uint32_t state, const ren_io_result *r,
               const uint8_t *in, uint32_t in_len) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  put64(&j, id);
  put32(&j, state);
  put32(&j, (uint32_t)sizeof(ren_io_result));
  put64(&j, (uint64_t)r->res);
  put64(&j, (uint64_t)r->a);
  put64(&j, (uint64_t)r->b);
  put32(&j, in_len);
  putb(&j, in, in_len);
  jb_emit(c, &j, REN_J_DELIVER, w);
}

void j_cancel(ren_core *c, int32_t by, uint64_t id, uint32_t how) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  put64(&j, id);
  put32(&j, how);
  jb_emit(c, &j, REN_J_CANCEL, by);
}

void j_release(ren_core *c, uint64_t id, uint32_t why) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  put64(&j, id);
  put32(&j, why);
  jb_emit(c, &j, REN_J_RELEASE, -1);
}

void j_end(ren_core *c, int32_t w, uint32_t how) {
  if (!c->host.journal) return;
  jb j; jb_init(&j);
  put32(&j, how);
  jb_emit(c, &j, REN_J_END, w);
}
