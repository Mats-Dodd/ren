/* hot_c.c: W5 variant (ii), the hot path in C, out of line in its own
   unit. Same semantics as slice.h's inlines (SPEC §E). */
#include "../slice.h"

void ren_hot_dup(ren_obj *o) {
  int32_t rc = o->rc;
  if (REN_LIKELY(rc > 0)) o->rc = rc + 1;
  else if (rc != 0) ren_xadd32(&o->rc, -1, REN_MO_RELAXED);
}
void ren_hot_drop(ren_obj *o) {
  int32_t rc = o->rc;
  if (REN_LIKELY(rc > 1)) o->rc = rc - 1;
  else if (rc == 1) ren_obj_free(o);
  else if (rc != 0) {
    if (ren_xadd32(&o->rc, 1, REN_MO_RELEASE) == -1) {
      ren_fence(REN_MO_ACQUIRE);
      ren_obj_free(o);
    }
  }
}
void ren_hot_array_grow(ren_array *a) { ren_array_grow_c(a); }
void ren_hot_array_push(ren_array *a, int64_t v) {
  if (REN_UNLIKELY(a->len == a->cap)) ren_hot_array_grow(a);
  a->data[a->len++] = v;
}
