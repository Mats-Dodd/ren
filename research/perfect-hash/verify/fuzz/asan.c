#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../bench/phrt.h"
#include "gen/orig_methods.h"
int main(int argc, char **argv) {
  const char *k = "GET"; char *p = malloc(3); memcpy(p, k, 3);
  int which = atoi(argv[1]); int r;
  if (which == 0) r = orig_methods_ph_neon(p, 3);
  else if (which == 1) r = orig_methods_ph_pad(p, 3);
  else r = orig_methods_ph_word(p, 3);
  printf("form %d -> %d\n", which, r); return 0;
}
