#define main b5_main
#include "b5.c"
#undef main
/* long inputs: an ASCII run of k blocks then a truncated or bad sequence
   at every offset around 64-byte boundaries, plus random mutations of
   1 MiB texts */
int main(void) {
  int64_t bad = 0, inv = 0, tot = 0;
  const char *kinds[] = {"ascii", "latin", "cjk", "emoji", "mixed"};
  for (int k = 0; k < 5; k++) {
    unsigned char *p = text(kinds[k], 1 << 20);
    for (int t = 0; t < 3000; t++) {
      int64_t n = 1 + (int64_t)(rnd() % (1 << 20));
      int64_t at = (int64_t)(rnd() % (uint64_t)n);
      unsigned char save = p[at];
      if (t % 3) p[at] = (unsigned char)rnd();
      bool a = v_ren(p, n), c = v_neon(p, n);
      inv += !a; tot++;
      if (a != c) bad++;
      p[at] = save;
    }
    free(p);
  }
  /* boundary sweep: ASCII prefix of length L then a lead byte(s) */
  unsigned char buf[512];
  const unsigned char seqs[][4] = {{0xc3,0xa9},{0xe6,0x97,0xa5},{0xf0,0x9f,0x98,0x80},{0xed,0xa0,0x80},{0xc0,0x80},{0xf4,0x90,0x80,0x80}};
  const int sl[] = {2,3,4,3,2,4};
  for (int L = 0; L < 300; L++)
    for (int s = 0; s < 6; s++)
      for (int cut = 1; cut <= sl[s]; cut++)
        for (int tail = 0; tail < 70; tail += 7) {
          memset(buf, 'a', sizeof buf);
          memcpy(buf + L, seqs[s], (size_t)cut);
          int64_t n = L + cut + tail;
          bool a = v_ren(buf, n), c = v_neon(buf, n);
          inv += !a; tot++;
          if (a != c) { bad++; if (bad < 5) fprintf(stderr, "L=%d s=%d cut=%d tail=%d ren=%d neon=%d\n", L, s, cut, tail, a, c); }
        }
  printf("big test: %lld disagreements of %lld, %lld invalid\n", (long long)bad, (long long)tot, (long long)inv);
  return bad != 0;
}
