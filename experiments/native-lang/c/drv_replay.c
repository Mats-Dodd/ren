/* drv_replay.c: the replay driver (SPEC §D.1) and the fuzz driver (§D.4),
   which is the replay driver fed random bytes. Neither makes OS calls:
   each is a host whose callbacks answer from its input. */
#include "drv.h"
#include <stdlib.h>
#include <string.h>

/* ================= replay ================= */
typedef struct ent { uint32_t kind, len; int32_t worker; uint64_t step; const uint8_t *pl; } ent;

static bool rd_ent(const ren_drv *d, size_t pos, ent *e) {
  if (pos + REN_JENT_BYTES > d->in_len) return false;
  const uint8_t *p = d->in + pos;
  e->kind = rd32(p); e->len = rd32(p + 4); e->worker = (int32_t)rd32(p + 8); e->step = rd64(p + 16);
  if ((uint64_t)e->len > d->in_len - pos - REN_JENT_BYTES) return false;
  e->pl = p + REN_JENT_BYTES;
  return true;
}

static void diverge(ren_drv *d, size_t idx, const char *what) {
  if (d->diverged) return;
  d->diverged = idx ? (int32_t)idx : 1;
  snprintf(d->err, sizeof d->err, "replay diverged at entry %zu: %s", idx ? idx : (size_t)1, what);
}

/* advance core_pos to the next recorded core entry (kind < 16) */
static bool next_core(ren_drv *d, ent *e) {
  for (;;) {
    if (!rd_ent(d, d->core_pos, e)) return false;
    if (e->kind < 16) return true;
    d->core_pos += REN_JENT_BYTES + e->len;
    d->core_entry_no++;
  }
}

/* the replaying core's journal: compare with the next recorded core entry */
void drv_replay_journal(void *hp, int32_t w, const void *bytes, size_t n) {
  ren_drv *d = hp; (void)w;
  if (d->diverged) return;
  ent e;
  if (!next_core(d, &e)) {
    uint32_t k = n >= 4 ? rd32(bytes) : 0;
    char m[128];
    snprintf(m, sizeof m, "late end: the core wrote an entry (kind %u) past the end of the recording", k);
    diverge(d, d->core_entry_no + 1, m);
    return;
  }
  size_t idx = d->core_entry_no + 1;
  if (REN_JENT_BYTES + (size_t)e.len != n || memcmp(d->in + d->core_pos, bytes, n) != 0) {
    char m[200];
    uint32_t k2 = n >= 4 ? rd32(bytes) : 0;
    const char *what = "a field differs";
    if (k2 != e.kind) what = (e.kind == REN_J_END || k2 == REN_J_END) ? "an early or late end" : "a different entry kind";
    else if (k2 == REN_J_CALL) what = "a call argument";
    else if (k2 == REN_J_DELIVER) what = "a delivery (point or contents)";
    else if (n >= 24 && memcmp(d->in + d->core_pos + 16, (const uint8_t *)bytes + 16, 8) != 0) what = "the step (a delivery point)";
    snprintf(m, sizeof m, "core entry differs: %s (recorded kind %u, replayed kind %u)", what, e.kind, k2);
    diverge(d, idx, m);
  }
  d->core_pos += REN_JENT_BYTES + e.len;
  d->core_entry_no++;
  d->last_core_end = d->core_pos;
}

/* answer_now: inline iff the recorded entry right after the CALL just
   matched is a DELIVER for this id (an inline answer is journaled inside
   ren_world, so nothing can come between them at one worker). */
bool drv_replay_answer(void *hp, int32_t w, const ren_call *k, ren_reply_t *out) {
  ren_drv *d = hp; (void)w;
  if (d->diverged) return false;
  ent e;
  if (!rd_ent(d, d->last_core_end, &e) || e.kind != REN_J_DELIVER || e.len < 40) return false;
  if (rd64(e.pl) != k->id) return false;
  uint32_t blen = rd32(e.pl + 12);
  if (blen != sizeof(ren_io_result) || e.len < 16 + blen + 4) return false;
  d->answer.res = (int64_t)rd64(e.pl + 16);
  d->answer.a = (int64_t)rd64(e.pl + 24);
  d->answer.b = (int64_t)rd64(e.pl + 32);
  out->id = k->id; out->state = rd32(e.pl + 8); out->len = (uint32_t)sizeof d->answer; out->body = &d->answer;
  return true;
}

static kept **find_kept(ren_drv *d, uint64_t id) {
  kept **kp = &d->kept;
  while (*kp && (*kp)->call.id != id) kp = &(*kp)->next;
  return kp;
}

int32_t drv_replay_run(ren_drv *d, ren_core *c) {
  size_t pos = 0, idx = 0;
  ent e;
  /* core_pos etc. are not reset here: ren_start already journaled HEADER */
  while (!d->diverged && rd_ent(d, pos, &e)) {
    idx++;
    d->entry_no = idx;
    if (e.kind >= 16 && e.kind != REN_J_DRV && (e.worker < 0 || e.worker >= d->o.workers)) {
      diverge(d, idx, "a driver entry names a worker out of range");
      break;
    }
    switch (e.kind) {
    case REN_J_DRV:
      if (e.len < 12 || (int32_t)rd32(e.pl + 4) != d->o.workers) diverge(d, idx, "J_DRV: a different worker count");
      break;
    case REN_J_RUN: {
      if (e.len != 8) { diverge(d, idx, "J_RUN: bad length"); break; }
      int32_t r = ren_run(c, e.worker, rd32(e.pl));
      if (r != (int32_t)rd32(e.pl + 4)) diverge(d, idx, "ren_run returned a different result");
      break;
    }
    case REN_J_PULL: {
      ren_call k;
      if (!ren_poll_call(c, e.worker, &k)) { diverge(d, idx, "ren_poll_call returned false; the recording pulled a call"); break; }
      db b; db_init(&b);
      drv_wire_call(&b, &k);
      if (b.n != e.len || memcmp(db_data(&b), e.pl, b.n) != 0) diverge(d, idx, "the pulled call differs (a call argument)");
      db_free(&b);
      if (k.kind == REN_CALL) {
        kept *kk = calloc(1, sizeof *kk);
        if (!kk) abort();
        kk->call = k; kk->next = d->kept; d->kept = kk;
      }
      break;
    }
    case REN_J_DRAINED: {
      ren_call k;
      if (ren_poll_call(c, e.worker, &k)) diverge(d, idx, "ren_poll_call returned a call; the recording drained");
      break;
    }
    case REN_J_REPLY: {
      if (e.len < 16) { diverge(d, idx, "J_REPLY: bad length"); break; }
      uint64_t id = rd64(e.pl);
      uint32_t st = rd32(e.pl + 8), blen = rd32(e.pl + 12);
      if (blen != sizeof(ren_io_result) || e.len < 16 + blen + 4) { diverge(d, idx, "J_REPLY: bad body length"); break; }
      ren_io_result res;
      res.res = (int64_t)rd64(e.pl + 16); res.a = (int64_t)rd64(e.pl + 24); res.b = (int64_t)rd64(e.pl + 32);
      uint32_t in_len = rd32(e.pl + 16 + blen);
      if ((uint64_t)e.len != 16 + (uint64_t)blen + 4 + in_len + 4) { diverge(d, idx, "J_REPLY: bad inout length"); break; }
      const uint8_t *inb = e.pl + 20 + blen;
      int32_t ret = (int32_t)rd32(inb + in_len);
      kept **kp = find_kept(d, id);
      if (in_len) {
        if (!*kp) { diverge(d, idx, "reply bytes for a call that was never pulled"); break; }
        const ren_io_body *bd = (const ren_io_body *)(*kp)->call.body;
        if (in_len > bd->len) { diverge(d, idx, "reply bytes longer than the call's buffer"); break; }
        memcpy((void *)(uintptr_t)bd->buf, inb, in_len);   /* the driver owns the buffer */
      }
      if (*kp) { kept *kk = *kp; *kp = kk->next; free(kk); }
      ren_reply_t r;
      r.id = id; r.state = st; r.len = (uint32_t)sizeof res; r.body = &res;
      if (ren_reply(c, &r) != ret) diverge(d, idx, "ren_reply returned a different result");
      break;
    }
    default:
      break;                                  /* core entries are matched through the journal callback */
    }
    pos += REN_JENT_BYTES + e.len;
  }
  if (!d->diverged && pos != d->in_len) diverge(d, idx + 1, "the recording ends inside an entry (truncated)");
  if (!d->diverged && next_core(d, &e))
    diverge(d, d->core_entry_no + 1, "early end: recorded core entries were never produced");
  return 0;
}

/* ================= fuzz (SPEC §D.4) ================= */
#define REN_FUZZ_STALE_MAGIC 0x5A1E5A1Ell

typedef struct fz {
  ren_drv *d; ren_core *c;
  size_t pos;
  ren_call *pend; size_t npend, cappend;
  uint64_t done_ids[64]; size_t ndone, done_head;
} fz;

static int fz_next(fz *f) { return f->pos < f->d->in_len ? f->d->in[f->pos++] : -1; }
static void fz_fail(fz *f, const char *what, uint64_t id, int32_t got) {
  if (f->d->fuzz_fail) return;
  f->d->fuzz_fail = 1;
  snprintf(f->d->err, sizeof f->d->err, "fuzz oracle: %s (id %016llx, ren_reply = %d, input offset %zu)", what,
           (unsigned long long)id, got, f->pos);
}
static int32_t fz_reply(fz *f, uint64_t id, uint32_t st, int64_t res) {
  ren_io_result r;
  r.res = res; r.a = 0; r.b = 0;
  ren_reply_t rp;
  rp.id = id; rp.state = st; rp.len = (uint32_t)sizeof r; rp.body = &r;
  return ren_reply(f->c, &rp);
}
static ptrdiff_t fz_find(fz *f, uint64_t id) {
  for (size_t i = 0; i < f->npend; i++) if (f->pend[i].id == id) return (ptrdiff_t)i;
  return -1;
}
static void fz_remove(fz *f, size_t i) {
  memmove(&f->pend[i], &f->pend[i + 1], (f->npend - i - 1) * sizeof *f->pend);
  f->npend--;
}
static void fz_done_push(fz *f, uint64_t id) {
  f->done_ids[f->done_head] = id;
  f->done_head = (f->done_head + 1) % 64;
  if (f->ndone < 64) f->ndone++;
}
/* RUN rule: run, then poll until false */
static int32_t fz_run(fz *f, int32_t w, uint32_t steps) {
  int32_t r = ren_run(f->c, w, steps);
  ren_call k;
  while (ren_poll_call(f->c, w, &k)) {
    if (k.kind == REN_CALL) {
      if (f->npend == f->cappend) {
        f->cappend = f->cappend ? 2 * f->cappend : 32;
        f->pend = realloc(f->pend, f->cappend * sizeof *f->pend);
        if (!f->pend) abort();
      }
      f->pend[f->npend++] = k;
    } else if (k.kind == REN_CANCEL) {
      ptrdiff_t i = fz_find(f, k.id);
      if (i >= 0) {
        fz_remove(f, (size_t)i);
        int32_t rr = fz_reply(f, k.id, REN_CANCELLED, -REN_ECANCELED);
        if (rr != REN_ACCEPTED) fz_fail(f, "a cancel's Cancelled reply was not ACCEPTED", k.id, rr);
        else fz_done_push(f, k.id);
      }
    }
  }
  return r;
}

int32_t drv_fuzz_run(ren_drv *d, ren_core *c) {
  fz f;
  memset(&f, 0, sizeof f);
  f.d = d; f.c = c;
  int32_t nw = d->o.workers;
  for (;;) {
    if (d->fuzz_fail) goto out;
    int a = fz_next(&f);
    if (a < 0) break;
    switch (a % 8) {
    case 0: case 1: {
      int x = fz_next(&f); if (x < 0) goto end;
      int y = fz_next(&f); if (y < 0) goto end;
      fz_run(&f, x % nw, 1u + (uint32_t)(y % 16));
      break;
    }
    case 2: {
      if (!f.npend) break;
      int x = fz_next(&f); if (x < 0) goto end;
      size_t k = (size_t)x % f.npend;
      int y = fz_next(&f); if (y < 0) goto end;
      ren_call call = f.pend[k];
      uint32_t st = (y & 1) ? REN_CANCELLED : REN_DONE;
      int64_t res = -REN_ECANCELED;
      const ren_io_body *b = (const ren_io_body *)call.body;
      if (st == REN_DONE) {
        int z = fz_next(&f); if (z < 0) goto end;   /* input used up: the action is dropped whole */
        res = (int64_t)((uint64_t)z % (b->len + 1));
        if (call.op == REN_OP_READ)
          for (int64_t i = 0; i < res; i++)
            ((uint8_t *)(uintptr_t)b->buf)[i] = (uint8_t)((call.id + (uint64_t)i) & 0xffu);
      }
      fz_remove(&f, k);
      int32_t rr = fz_reply(&f, call.id, st, res);
      if (rr != REN_ACCEPTED) fz_fail(&f, "a reply to a pulled call was not ACCEPTED", call.id, rr);
      else fz_done_push(&f, call.id);
      break;
    }
    case 3: case 4: {
      if (!f.ndone) break;
      int x = fz_next(&f); if (x < 0) goto end;
      uint64_t id = f.done_ids[(size_t)x % f.ndone];
      int32_t rr = fz_reply(&f, id, REN_DONE, REN_FUZZ_STALE_MAGIC);
      if (rr != REN_RELEASE) fz_fail(&f, "a stale reply was ACCEPTED", id, rr);
      break;
    }
    case 5: {
      uint64_t id = 0;
      for (int i = 0; i < 8; i++) { int x = fz_next(&f); if (x < 0) goto end; id |= (uint64_t)x << (8 * i); }
      if (fz_find(&f, id) < 0) {
        int32_t rr = fz_reply(&f, id, REN_DONE, REN_FUZZ_STALE_MAGIC);
        if (rr != REN_RELEASE) fz_fail(&f, "a bogus reply was ACCEPTED", id, rr);
      }
      break;
    }
    case 6: ren_stop(c); break;
    default: break;
    }
  }
end:
  ren_stop(c);
  for (int round = 0; round < 10000 && !d->fuzz_fail; round++) {
    int fin = 0;
    for (int32_t w = 0; w < nw; w++) if (fz_run(&f, w, 64) == REN_FINISHED) fin++;
    while (f.npend) {
      ren_call call = f.pend[0];
      fz_remove(&f, 0);
      int32_t rr = fz_reply(&f, call.id, REN_CANCELLED, -REN_ECANCELED);
      if (rr != REN_ACCEPTED) fz_fail(&f, "a final Cancelled reply was not ACCEPTED", call.id, rr);
    }
    if (fin == nw) goto out;
  }
  if (!d->fuzz_fail) {
    fz_fail(&f, "no termination (a lost wakeup or a lost reply)", 0, 0);
    if (getenv("REN_C_DUMP")) { extern void ren_c_dump(ren_core *, FILE *); ren_c_dump(c, stderr); }
  }
out:
  free(f.pend);
  return 0;
}
