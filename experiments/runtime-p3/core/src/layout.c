/* layout.c: ren_layout_table as the C entry sees slice.h (SPEC §0.3).
   In C the "generated bindings" are slice.h itself. */
#include "slice.h"
#include <stddef.h>

#define LX(T, F) {#T "." #F, (uint32_t)offsetof(T, F), 0},
#define LS(T) {"sizeof(" #T ")", (uint32_t)sizeof(T), 0},
static const ren_layout_ent c_layout[] = {REN_LAYOUT_LIST(LX, LS)};

size_t ren_layout_table(const ren_layout_ent **out) {
  *out = c_layout;
  return sizeof c_layout / sizeof c_layout[0];
}
