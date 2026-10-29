/* B2: retention. `b2 <datadir> [chunks]`: reads big/000.txt.. (8 MiB
   each) one at a time, each whole into one Str; keeps the first field of
   every 268th line (about 10k keys over 512 MiB) in a Map<Str, Int>;
   drops the chunk. Which chunks stay alive is the retention policy's
   (strs.h: RET_N, RET_STORE). Peak RSS is /usr/bin/time's. */
#include "map.h"

int main(int argc, char **argv) {
  const char *dir = argv[1];
  int chunks = argc > 2 ? atoi(argv[2]) : 64;
  uint64_t t0 = now_ns();
  smap m = {0};
  int64_t line = 0;
  for (int c = 0; c < chunks; c++) {
    char path[512];
    snprintf(path, sizeof path, "%s/big/%03d.txt", dir, c);
    int64_t n;
    char *buf = read_file(path, &n);
    S chunk = s_new(buf, n);
    free(buf);
    const char *p = s_ptr(&chunk);
    int64_t i = 0;
    while (i < n) {
      const char *q = memchr(p + i, '\n', (size_t)(n - i));
      int64_t b = q - p;
      if (line++ % 268 == 0) {
        const char *sp = memchr(p + i, ' ', (size_t)(b - i));
        smap_add(&m, &chunk, i, sp - p, 1);
      }
      i = b + 1;
    }
    s_drop(&chunk);
  }
  uint64_t t1 = now_ns();
  int64_t total = 0;
  for (int64_t e = 0; e < m.len; e++)
    total += s_len(&m.e[e].key);
  printf("check=%lld,%lld,%lld\n", (long long)m.len, (long long)total, (long long)line);
#ifdef STATS
  fprintf(stderr, "stats allocs=%lld copies=%lld copied_bytes=%lld peak_bytes=%lld live_end=%lld\n",
          (long long)st.allocs, (long long)st.copies, (long long)st.copied_bytes,
          (long long)st.peak, (long long)st.live);
#endif
  smap_free(&m);
  REPORT("total", t1 - t0);
  printf("repr=%s\n", REPR_NAME);
  return 0;
}
