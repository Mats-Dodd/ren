/* rt.c: the C runtime pieces every build links (not part of any core).
   ren_obj_free, the shared rc paths, the exported dup/drop wrappers the
   cores count frames with, the C grow, and frame allocation. */
#include "slice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ren_obj_free(ren_obj *o) {
  switch (o->tag) {
  case REN_TAG_TASK: {
    ren_task *t = (ren_task *)o;
    if (t->fin) t->fin(t);
    break;
  }
  case REN_TAG_ARRAY:
    free(((ren_array *)o)->data);
    break;
  default:
    break;
  }
  free(o);
}

void ren_array_grow_c(ren_array *a) {
  uint32_t cap = a->cap ? 2 * a->cap : 8;
  int64_t *d = (int64_t *)realloc(a->data, (size_t)cap * sizeof(int64_t));
  if (!d) { fputs("ren_array_grow_c: out of memory\n", stderr); abort(); }
  a->data = d;
  a->cap = cap;
}

/* SPEC §E: Arc's protocol on a negative count. */
void ren_dup_shared(ren_obj *o) { ren_xadd32(&o->rc, -1, REN_MO_RELAXED); }
void ren_drop_shared(ren_obj *o) {
  if (ren_xadd32(&o->rc, 1, REN_MO_RELEASE) == -1) {
#ifdef REN_TSAN_HARNESS
    (void)ren_ld32(&o->rc, REN_MO_ACQUIRE);  /* TSan ignores fences: Rust's Arc does the same */
#else
    ren_fence(REN_MO_ACQUIRE);
#endif
    ren_obj_free(o);
  }
}

void ren_rc_dup(ren_obj *o) { ren_dup(o); }
void ren_rc_drop(ren_obj *o) { ren_drop(o); }

ren_task *ren_task_new(size_t size, ren_resume_fn resume, ren_fin_fn fin) {
  if (size < sizeof(ren_task)) size = sizeof(ren_task);
  ren_task *t = (ren_task *)calloc(1, size);
  if (!t) { fputs("ren_task_new: out of memory\n", stderr); abort(); }
  t->obj.rc = -1; /* shared from birth: frames cross workers */
  t->obj.tag = REN_TAG_TASK;
  t->resume = resume;
  t->fin = fin;
  return t;
}
