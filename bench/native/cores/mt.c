/* The cost of counting across cores: foundations.md, decision 10, measured.

   Built against the real runtime, lib/native/runtime/ren_rt.{h,c},
   included here as `ren build` includes them in every C file, in one of
   its counting modes (-DREN_RC_SHARED, -DREN_RC_ATOMIC, or plain). The
   tree and both traversals are what `ren build --release` emits for

     type Tree = | Node(left: Tree, key: Int, right: Tree) | Leaf
     fn sum(t: Tree) -> Int =
       match t
         Node(l, k, r) => sum(l) + k + sum(r)
         Leaf => 0

   [sum_borrowed] is that function as Perceus emits it, with `t`
   inferred borrowed: no counting at all. [sum_owned] is the same
   function when `t` is owned, as it is wherever borrow inference can't
   keep it borrowed: the shape the release build gives every owned
   `match` (drop specialization, as in rbtree's C): if the node is unique
   it's freed keeping its children, otherwise its children are dup'd and
   it's dropped. On a tree something else holds that's two dups and a
   drop per node.

     mt <mode> <threads> <depth> <rounds>

   modes:
     a-owned     each thread its own unshared tree, sum_owned
     a-borrowed  each thread its own unshared tree, sum_borrowed
     b           one shared tree, marked shared, sum_owned
     c           one shared tree, marked shared, sum_borrowed
     d           one shared tree, marked shared; each round dups the
                 root, sum_borrowed, drops it
     e           one shared tree frozen as a region: every count set to
                 0, as Lean's persistent objects are (lean.h:640), so
                 dup and drop skip it; then sum_owned, as b
   Every thread runs [rounds] traversals of a tree of 2^depth - 1 nodes,
   so the work per thread is fixed (weak scaling). It prints one line:
   mode, threads, depth, rounds, seconds, nodes visited per second. */

#include "../../../lib/native/runtime/ren_rt.h"
#include "../../../lib/native/runtime/ren_rt.c"

#include <time.h>

/* the parts of a program the runtime expects one to define */
const char *const *ren_tag_names;

/* Every count [o] reaches set to 0: never counted, never freed, what a
   handler's immutable state would be for its `with` if the runtime
   froze it. Recursion is fine at these depths. */
static void freeze(ren_obj *o) {
  if (ren_is_scalar(o) || o->rc == 0)
    return;
  o->rc = 0;
  freeze(ren_fields(o)[0].o);
  freeze(ren_fields(o)[2].o);
}

/* The region's end: free all of it at once. */
static void free_frozen(ren_obj *o) {
  if (ren_is_scalar(o))
    return;
  free_frozen(ren_fields(o)[0].o);
  free_frozen(ren_fields(o)[2].o);
  free(o);
}

static ren_obj *make(int64_t lo, int64_t hi) {
  if (lo >= hi)
    return ren_box(1);
  int64_t mid = lo + (hi - lo) / 2;
  ren_obj *l = make(lo, mid);
  ren_obj *r = make(mid + 1, hi);
  ren_obj *n = ren_alloc_ctor(0, 3, 1u | 4u);
  ren_fields(n)[0].o = l;
  ren_fields(n)[1].i = mid;
  ren_fields(n)[2].o = r;
  return n;
}

/* `ren_add`: Ren's `+` panics on overflow */
static inline int64_t add(int64_t a, int64_t b) {
  int64_t c;
  if (__builtin_add_overflow(a, b, &c))
    abort();
  return c;
}

__attribute__((noinline)) static int64_t sum_borrowed(ren_obj *t) {
  if (ren_tag(t) != 0)
    return 0;
  ren_obj *l = ren_fields(t)[0].o;
  int64_t k = ren_fields(t)[1].i;
  ren_obj *r = ren_fields(t)[2].o;
  return add(add(sum_borrowed(l), k), sum_borrowed(r));
}

__attribute__((noinline)) static int64_t sum_owned(ren_obj *t) {
  if (ren_tag(t) != 0) {
    ren_drop(t);
    return 0;
  }
  ren_obj *l = ren_fields(t)[0].o;
  int64_t k = ren_fields(t)[1].i;
  ren_obj *r = ren_fields(t)[2].o;
  if (ren_is_unique(t)) {
    ren_free_keeping(t, 1u | 4u);
  } else {
    ren_dup(l);
    ren_dup(r);
    ren_drop(t);
  }
  return add(add(sum_owned(l), k), sum_owned(r));
}

typedef struct {
  int mode; /* 'A' a-owned, 'a' a-borrowed, 'b', 'c', 'd' */
  int depth;
  long rounds;
  ren_obj *shared;
  int64_t result;
} job;

/* pthread_barrier_t isn't on macOS: a small one */
typedef struct {
  pthread_mutex_t m;
  pthread_cond_t c;
  int n, waiting;
  long generation;
} barrier;

static barrier gate;

static void gate_wait(void) {
  pthread_mutex_lock(&gate.m);
  long g = gate.generation;
  if (++gate.waiting == gate.n) {
    gate.waiting = 0;
    gate.generation++;
    pthread_cond_broadcast(&gate.c);
  } else {
    while (gate.generation == g)
      pthread_cond_wait(&gate.c, &gate.m);
  }
  pthread_mutex_unlock(&gate.m);
}

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void *worker(void *arg) {
  job *j = arg;
  ren_obj *own = NULL;
  int64_t n = ((int64_t)1 << j->depth) - 1;
  if (j->mode == 'A' || j->mode == 'a')
    own = make(0, n);
  gate_wait();
  int64_t acc = 0;
  for (long i = 0; i < j->rounds; i++) {
    switch (j->mode) {
    case 'A':
      ren_dup(own);
      acc += sum_owned(own);
      break;
    case 'a':
      acc += sum_borrowed(own);
      break;
    case 'b':
      ren_dup(j->shared);
      acc += sum_owned(j->shared);
      break;
    case 'c':
      acc += sum_borrowed(j->shared);
      break;
    case 'd':
      ren_dup(j->shared);
      acc += sum_borrowed(j->shared);
      ren_drop(j->shared);
      break;
    case 'e':
      ren_dup(j->shared);
      acc += sum_owned(j->shared);
      break;
    }
  }
  j->result = acc;
  gate_wait();
  if (own != NULL)
    ren_drop(own);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: mt <a-owned|a-borrowed|b|c|d> <threads> <depth> <rounds>\n");
    return 2;
  }
  const char *m = argv[1];
  int mode = strcmp(m, "a-owned") == 0      ? 'A'
             : strcmp(m, "a-borrowed") == 0 ? 'a'
                                            : m[0];
  int threads = atoi(argv[2]);
  int depth = atoi(argv[3]);
  long rounds = atol(argv[4]);
  int64_t n = ((int64_t)1 << depth) - 1;
#if !defined(REN_RC_SHARED) && !defined(REN_RC_ATOMIC)
  if (threads > 1 && mode != 'a') {
    fprintf(stderr, "mt: plain counting is only sound on one thread\n");
    return 2;
  }
#endif
  ren_obj *shared = NULL;
  if (mode == 'b' || mode == 'c' || mode == 'd') {
    shared = make(0, n);
    ren_mark_shared(shared); /* before any thread sees it */
  } else if (mode == 'e') {
    shared = make(0, n);
    freeze(shared);
  }
  pthread_mutex_init(&gate.m, NULL);
  pthread_cond_init(&gate.c, NULL);
  gate.n = threads + 1;
  pthread_t *ts = calloc((size_t)threads, sizeof(pthread_t));
  job *js = calloc((size_t)threads, sizeof(job));
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 64 << 20);
  for (int i = 0; i < threads; i++) {
    js[i] = (job){mode, depth, rounds, shared, 0};
    pthread_create(&ts[i], &attr, worker, &js[i]);
  }
  /* the clock runs from when every thread has its tree to when the
     last finishes its rounds */
  gate_wait();
  double t0 = now();
  gate_wait();
  double t1 = now();
  for (int i = 0; i < threads; i++)
    pthread_join(ts[i], NULL);
  int64_t expect = (n * (n - 1) / 2) * rounds;
  for (int i = 0; i < threads; i++)
    if (js[i].result != expect) {
      fprintf(stderr, "mt: thread %d summed %" PRId64 ", not %" PRId64 "\n",
              i, js[i].result, expect);
      return 1;
    }
  if (mode == 'e') {
    if (ren_rc(shared) != 0) {
      fprintf(stderr, "mt: the frozen root's count is %d\n", ren_rc(shared));
      return 1;
    }
    free_frozen(shared);
  } else if (shared != NULL) {
    /* every round gave back the reference it took */
    if (ren_rc(shared) != -1 && ren_rc(shared) != 1) {
      fprintf(stderr, "mt: the root's count is %d\n", ren_rc(shared));
      return 1;
    }
    ren_drop(shared);
  }
  double secs = t1 - t0;
  printf("%s,%d,%d,%ld,%.4f,%.4g\n", m, threads, depth, rounds, secs,
         (double)n * (double)rounds * threads / secs);
  return 0;
}
