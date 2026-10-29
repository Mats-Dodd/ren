/* the item counts RESULTS.md divides by: lines in the log, lines W1
   reads before take stops it, nodes W2 visits before take stops it */
#include "common.h"
typedef struct Tree { int64_t val; int64_t n; struct Tree** kids; } Tree;
static rng R = {7};
static Tree* build(int d) {
  Tree* t = malloc(sizeof(Tree));
  t->val = (int64_t)rnext(&R);
  t->n = d >= 20 ? 0 : (d % 5 == 2 ? 3 : 2);
  t->kids = t->n ? malloc(sizeof(Tree*) * t->n) : NULL;
  for (int64_t i = 0; i < t->n; i++) t->kids[i] = build(d + 1);
  return t;
}
static int64_t seen, left, total;
static int walk(Tree* t) {
  total++;
  if (left) { seen++; if (t->val % 7 == 0 && --left == 0) {} }
  for (int64_t i = 0; i < t->n; i++) walk(t->kids[i]);
  return 0;
}
int main(void) {
  size_t len; uint8_t* b = make_log(LOG_BYTES, &len);
  int64_t lines = 0, before = 0, errs = 0;
  for (size_t i = 0; i < len; i++) if (b[i] == '\n') {
    lines++;
  }
  size_t i = 0;
  while (i < len) {
    const uint8_t* q = memchr(b + i, '\n', len - i); size_t j = q - b;
    before++;
    if (parse((Str){b, i, j - i}).level == ERROR && ++errs == 40000) break;
    i = j + 1;
  }
  left = 1300000; walk(build(0));
  printf("log_lines=%lld w1_lines_read=%lld w2_nodes=%lld w2_visited=%lld\n",
         (long long)lines, (long long)before, (long long)total, (long long)seen);
}
