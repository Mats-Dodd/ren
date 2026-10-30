/* hot.c: the C entry's hot library (SPEC §E): ren_hot_dup, ren_hot_drop,
   ren_hot_array_push, ren_hot_array_grow. The plain branch is the owner's;
   the negative (shared) branch is Arc's protocol. */
#include "atom.h"
#include <stdio.h>
#include <stdlib.h>

void ren_hot_dup(ren_obj *o) {
  int32_t rc = o->rc;                    /* plain: only the owner reads a positive count */
  if (REN_LIKELY(rc > 0)) o->rc = rc + 1;
  else if (rc != 0) ren_xadd32(&o->rc, -1, REN_MO_RELAXED);
}

void ren_hot_drop(ren_obj *o) {
  int32_t rc = o->rc;
  if (REN_LIKELY(rc > 1)) o->rc = rc - 1;
  else if (rc == 1) ren_obj_free(o);
  else if (rc != 0) {
    if (ren_xadd32(&o->rc, 1, REN_MO_RELEASE) == -1) {   /* Arc's drop */
      ren_fence(REN_MO_ACQUIRE);
      ren_obj_free(o);
    }
  }
}

void ren_hot_array_grow(ren_array *a) {
  uint32_t cap = a->cap ? 2 * a->cap : 8;
  int64_t *d = realloc(a->data, (size_t)cap * sizeof(int64_t));
  if (!d) { fputs("ren_hot_array_grow: out of memory\n", stderr); abort(); }
  a->data = d;
  a->cap = cap;
}

void ren_hot_array_push(ren_array *a, int64_t v) {
  if (REN_UNLIKELY(a->len == a->cap)) ren_hot_array_grow(a);
  a->data[a->len++] = v;
}
