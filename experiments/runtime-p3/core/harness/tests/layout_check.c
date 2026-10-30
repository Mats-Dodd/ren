/* layout_check.c: the language's view of slice.h (ren_layout_table)
   against C's offsetof/sizeof. SPEC §0.3. Exit 0 = identical. */
#include "slice.h"
#include <stdio.h>
#include <string.h>

#define LX(T, F) {#T "." #F, (uint32_t)offsetof(T, F), 0},
#define LS(T) {"sizeof(" #T ")", (uint32_t)sizeof(T), 0},
static const ren_layout_ent c_view[] = {REN_LAYOUT_LIST(LX, LS)};

int main(void) {
  const ren_layout_ent *t = NULL;
  size_t n = ren_layout_table(&t), want = sizeof c_view / sizeof *c_view;
  int bad = 0;
  for (size_t i = 0; i < want; i++) {
    size_t j = 0;
    while (j < n && strcmp(t[j].name, c_view[i].name) != 0) j++;
    if (j == n) { printf("MISSING %s\n", c_view[i].name); bad++; continue; }
    if (t[j].value != c_view[i].value) { printf("DIFFERS %s: C %u, language %u\n", c_view[i].name, c_view[i].value, t[j].value); bad++; }
  }
  if (n != want) printf("NOTE: language table has %zu entries, C has %zu\n", n, want);
  printf("layout_check: %zu names, %d mismatches: %s\n", want, bad, bad ? "FAIL" : "ok");
  return bad != 0;
}
