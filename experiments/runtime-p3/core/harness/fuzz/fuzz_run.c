/* fuzz_run.c: the fuzz harness without libFuzzer (tcc, Zig's safe
   allocator, plain builds): run files, or N random inputs.
   fuzz_run FILE...            run each file as one input
   fuzz_run --random N SEED    N inputs of 16..4096 random bytes */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int fuzz_one(const uint8_t *data, size_t len);

int main(int argc, char **argv) {
  if (argc >= 2 && !strcmp(argv[1], "--random")) {
    long n = argc > 2 ? atol(argv[2]) : 1000;
    uint64_t x = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
    if (!x) x = 1;
    uint8_t *buf = malloc(4096);
    for (long i = 0; i < n; i++) {
      x ^= x << 13; x ^= x >> 7; x ^= x << 17;
      size_t len = 16 + (size_t)(x % 4081);
      for (size_t j = 0; j < len; j++) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; buf[j] = (uint8_t)x; }
      fuzz_one(buf, len);
    }
    free(buf);
    printf("fuzz_run: %ld random inputs ok\n", n);
    return 0;
  }
  for (int i = 1; i < argc; i++) {
    FILE *f = fopen(argv[i], "rb");
    if (!f) { perror(argv[i]); return 2; }
    uint8_t *b = malloc(1 << 20);
    size_t len = fread(b, 1, 1 << 20, f);
    fclose(f);
    fuzz_one(b, len);
    free(b);
  }
  printf("fuzz_run: %d files ok\n", argc - 1);
  return 0;
}
