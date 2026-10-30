/* jdump.c: print a journal (SPEC §B.7), one entry per line. */
#include "slice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static const char *kname(uint32_t k) {
  switch (k) {
  case REN_J_HEADER: return "HEADER"; case REN_J_CALL: return "CALL"; case REN_J_DELIVER: return "DELIVER";
  case REN_J_CANCEL: return "CANCEL"; case REN_J_RELEASE: return "RELEASE"; case REN_J_CHOICE: return "CHOICE";
  case REN_J_END: return "END"; case REN_J_DRV: return "DRV"; case REN_J_RUN: return "RUN";
  case REN_J_PULL: return "PULL"; case REN_J_DRAINED: return "DRAINED"; case REN_J_REPLY: return "REPLY";
  default: return "?";
  }
}
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: jdump FILE [max]\n"); return 2; }
  FILE *f = fopen(argv[1], "rb");
  if (!f) { perror(argv[1]); return 2; }
  long max = argc > 2 ? atol(argv[2]) : -1, i = 0;
  uint8_t h[24];
  while (fread(h, 1, 24, f) == 24 && (max < 0 || i < max)) {
    uint32_t k, len; int32_t w; uint64_t step;
    memcpy(&k, h, 4); memcpy(&len, h + 4, 4); memcpy(&w, h + 8, 4); memcpy(&step, h + 16, 8);
    uint8_t *p = malloc(len ? len : 1);
    if (fread(p, 1, len, f) != len) { fprintf(stderr, "truncated\n"); return 1; }
    printf("%6ld %-8s w=%-2d step=%-8llu len=%-4u", ++i, kname(k), w, (unsigned long long)step, len);
    if ((k == REN_J_CALL || k == REN_J_PULL) && len >= 28) {
      uint64_t id; uint16_t kind; uint32_t task, op; memcpy(&id, p, 8); memcpy(&kind, p + 10, 2);
      memcpy(&task, p + 16, 4); memcpy(&op, p + 20, 4);
      printf(" id=%llx kind=%u task=%x op=%x", (unsigned long long)id, kind, task, op);
    } else if ((k == REN_J_DELIVER || k == REN_J_REPLY) && len >= 40) {
      uint64_t id; uint32_t st; int64_t res; memcpy(&id, p, 8); memcpy(&st, p + 8, 4); memcpy(&res, p + 16, 8);
      printf(" id=%llx state=%u res=%lld", (unsigned long long)id, st, (long long)res);
      if (k == REN_J_REPLY) { uint32_t il; int32_t ret; memcpy(&il, p + 40, 4); memcpy(&ret, p + 44 + il, 4); printf(" in=%u ret=%d", il, ret); }
    } else if ((k == REN_J_CANCEL || k == REN_J_RELEASE) && len >= 12) {
      uint64_t id; uint32_t x; memcpy(&id, p, 8); memcpy(&x, p + 8, 4);
      printf(" id=%llx %s=%u", (unsigned long long)id, k == REN_J_CANCEL ? "how" : "why", x);
    } else if (k == REN_J_RUN && len >= 8) {
      uint32_t s; int32_t r; memcpy(&s, p, 4); memcpy(&r, p + 4, 4); printf(" steps=%u ret=%d", s, r);
    }
    putchar('\n');
    free(p);
  }
  fclose(f);
  return 0;
}
