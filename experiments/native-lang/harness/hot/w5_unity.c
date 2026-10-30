/* w5_unity.c: variant (i) in release: the workload, the header's inlines
   and the C grow in one translation unit, as a Ren release build is. */
#define HOT_INLINE 1
#include "w5_hot.c"
#include "../rt.c"
