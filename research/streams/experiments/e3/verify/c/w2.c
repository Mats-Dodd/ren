/* W2: a recursive tree walk.

     type Tree = { val: Int, kids: Array<Tree> }

     gen fn walk(t: Tree) -> Int =
       yield t.val
       for c in t.kids
         yield from walk(c)

     var sum = 0
     for v in walk(root).select(fn(v) => v % 7 == 0).take(TAKE)
       sum += v

   21 levels (depth 20), two children a node, three at depths 2, 7, 12
   and 17: 10.2M nodes, each a counted object whose kids are an array of
   pointers to counted objects.

   Variants:
     hand        a recursive function, the select, take and sum inline
     hand-stack  an explicit stack of (node, next kid), a loop
     push        walk_push(t, body): the yield calls the body, recursion on
                 the native stack (amendments: "recursion moves to the
                 native stack")
     pull-box    the draft: each `yield from` child's frame is boxed, a
                 malloc per node, and each item is passed up through
                 every level's next: O(depth) per item
     pull-reuse  the same, with the dropped child box reused for the next
                 child (Perceus-style reuse): a malloc per level, still
                 O(depth) per item
     pull-stack  the frames on a stack the consumer owns (the task's frame
                 allocator), and next resumes the top one: O(1) per item */
#include "common.h"

#define TAKE 1300000
#define REPS 3

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

typedef struct { bool some; int64_t v; } OptI;

/* ---------------- hand ---------------- */
typedef struct { int64_t left, sum; } St;
static int hand_rec(const Tree* t, St* restrict s) {
  REN_STACK_CHECK();
  if (t->val % 7 == 0) {
    s->sum = ren_add(s->sum, t->val);
    if (--s->left == 0) return 1;
  }
  for (int64_t i = 0; i < t->n; i++)
    if (hand_rec(t->kids[i], s)) return 1;
  return 0;
}
static NOINLINE int64_t w2_hand(const Tree* root) {
  St s = {TAKE, 0};
  hand_rec(root, &s);
  return s.sum;
}

typedef struct { const Tree* t; int64_t i; } HS;
static NOINLINE int64_t w2_hand_stack(const Tree* root) {
  HS stk[64];
  int top = 0;
  int64_t left = TAKE, sum = 0;
  stk[0] = (HS){root, -1};
  while (top >= 0) {
    HS* f = &stk[top];
    if (f->i < 0) {
      f->i = 0;
      int64_t v = f->t->val;
      if (v % 7 == 0) {
        sum = ren_add(sum, v);
        if (--left == 0) break;
      }
    }
    if (f->i < f->t->n) {
      const Tree* c = f->t->kids[f->i++];
      stk[++top] = (HS){c, -1};
    } else top--;
  }
  return sum;
}

/* ---------------- push ---------------- */
static inline int w2_body(const ren_ev* ev, int64_t* restrict left, int64_t* restrict sum, int64_t v) {
  (void)ev;
  if (!(v % 7 == 0)) return REN_CONT;   /* select */
  *sum = ren_add(*sum, v);              /* the for body */
  if (--*left == 0) return REN_BREAK;   /* take */
  return REN_CONT;
}
static int walk_push(const Tree* t, const ren_ev* ev, int64_t* restrict left, int64_t* restrict sum) {
  REN_STACK_CHECK();
  int c = w2_body(ev, left, sum, t->val);              /* yield t.val */
  if (c != REN_CONT) return c;
  for (int64_t i = 0; i < t->n; i++) {                 /* for c in t.kids */
    c = walk_push(t->kids[i], ev, left, sum);          /* yield from walk(c) */
    if (c != REN_CONT) return c;
  }
  return REN_CONT;
}
static NOINLINE int64_t w2_push(const Tree* root) {
  int64_t left = TAKE, sum = 0;
  if (left > 0) walk_push(root, &EV, &left, &sum);
  return sum;
}

/* ---------------- pull, boxed yield from ---------------- */
typedef struct WalkFrame { int st; const Tree* t; int64_t i; struct WalkFrame* child; } WalkFrame;

static inline WalkFrame* frame_new(WalkFrame* reuse, const Tree* t) {
  WalkFrame* f = reuse ? reuse : malloc(sizeof(WalkFrame));
  f->st = 0; f->t = t; f->i = 0;
  if (!reuse) f->child = NULL;
  return f;
}
/* the frame's cleanup, at the end of the binding's scope or at break */
static void frame_free(WalkFrame* f) {
  while (f) { WalkFrame* c = f->child; free(f); f = c; }
}

#define DEF_WALK_NEXT(SUF, REUSE)                                         \
  static OptI walk_next##SUF(WalkFrame* restrict f) {                     \
    REN_STACK_CHECK();                                                    \
    switch (f->st) {                                                      \
      case 0: f->st = 1; return (OptI){true, f->t->val};                  \
      case 1: f->i = 0; goto loop;                                        \
      case 2: goto resume;                                                \
      default: return (OptI){false, 0};                                   \
    }                                                                     \
  loop:                                                                   \
    if (f->i < f->t->n) {                                                 \
      f->child = frame_new(REUSE ? f->child : NULL, f->t->kids[f->i]);    \
    resume:;                                                              \
      OptI o = walk_next##SUF(f->child);                                  \
      if (o.some) { f->st = 2; return o; }                                \
      if (!REUSE) { free(f->child); f->child = NULL; }                    \
      f->i++;                                                             \
      goto loop;                                                          \
    }                                                                     \
    f->st = 3;                                                            \
    return (OptI){false, 0};                                              \
  }                                                                       \
  static inline OptI w2_pipe##SUF(const ren_ev* ev, WalkFrame* restrict g, int64_t* restrict left) { \
    (void)ev;                                                             \
    if (*left <= 0) return (OptI){false, 0};                              \
    for (;;) {                                                            \
      OptI o = walk_next##SUF(g);                                         \
      if (!o.some) return o;                                              \
      if (!(o.v % 7 == 0)) continue;                                      \
      --*left;                                                            \
      return o;                                                           \
    }                                                                     \
  }                                                                       \
  static NOINLINE int64_t w2_pull##SUF(const Tree* root) {                \
    WalkFrame g = {0, root, 0, NULL};                                     \
    int64_t left = TAKE, sum = 0;                                         \
    for (;;) {                                                            \
      OptI o = w2_pipe##SUF(&EV, &g, &left);                              \
      if (!o.some) break;                                                 \
      sum = ren_add(sum, o.v);                                            \
    }                                                                     \
    frame_free(g.child);                                                  \
    return sum;                                                           \
  }
DEF_WALK_NEXT(_box, 0)
DEF_WALK_NEXT(_reuse, 1)

/* ---------------- pull, frames on a stack the consumer owns ---------------- */
typedef struct { int st; const Tree* t; int64_t i; } SFrame;
typedef struct { SFrame* s; int64_t top, cap; } WalkStack;

static inline OptI walk_next_stack(WalkStack* restrict w) {
  for (;;) {
    if (w->top < 0) return (OptI){false, 0};
    SFrame* f = &w->s[w->top];
    switch (f->st) {
      case 0: f->st = 1; return (OptI){true, f->t->val};    /* yield t.val */
      case 1:
        if (f->i < f->t->n) {                               /* yield from walk(c) */
          const Tree* c = f->t->kids[f->i++];
          if (w->top + 1 == w->cap) {
            w->cap *= 2;
            w->s = realloc(w->s, sizeof(SFrame) * w->cap);
          }
          w->s[++w->top] = (SFrame){0, c, 0};
        } else w->top--;                                    /* the frame returns */
        continue;
    }
  }
}
static NOINLINE int64_t w2_pull_stack(const Tree* root) {
  WalkStack w = {malloc(sizeof(SFrame) * 16), 0, 16};
  w.s[0] = (SFrame){0, root, 0};
  int64_t left = TAKE, sum = 0;
  while (left > 0) {
    OptI o;
    do o = walk_next_stack(&w); while (o.some && !(o.v % 7 == 0));
    if (!o.some) break;
    --left;
    sum = ren_add(sum, o.v);
  }
  free(w.s);
  return sum;
}


/* VERIFY: the same frame stack, with the child's entry (state 0, which
   only yields t.val) run at the `yield from` instead of on the next
   resume: the jump threading a compiler does when it lowers `yield from`
   into its own resume loop. Same frames, same order, same work. */
static inline OptI walk_next_stack2(WalkStack* restrict w) {
  for (;;) {
    if (w->top < 0) return (OptI){false, 0};
    SFrame* f = &w->s[w->top];
    if (f->st == 0) { f->st = 1; return (OptI){true, f->t->val}; }
    if (f->i < f->t->n) {
      const Tree* c = f->t->kids[f->i++];
      if (w->top + 1 == w->cap) {
        w->cap *= 2;
        w->s = realloc(w->s, sizeof(SFrame) * w->cap);
      }
      w->s[++w->top] = (SFrame){1, c, 0};
      return (OptI){true, c->val};          /* the child's first yield */
    }
    w->top--;
  }
}
static NOINLINE int64_t w2_pull_stack2(const Tree* root) {
  WalkStack w = {malloc(sizeof(SFrame) * 16), 0, 16};
  w.s[0] = (SFrame){0, root, 0};
  int64_t left = TAKE, sum = 0;
  while (left > 0) {
    OptI o;
    do o = walk_next_stack2(&w); while (o.some && !(o.v % 7 == 0));
    if (!o.some) break;
    --left;
    sum = ren_add(sum, o.v);
  }
  free(w.s);
  return sum;
}

int main(int argc, char** argv) {
  ren_stack_init();
  if (argc < 2) { fprintf(stderr, "usage: w2 variant\n"); return 2; }
  const char* v = argv[1];
  Tree* root = build(0);
  int64_t sum = 0;
  uint64_t t0 = now_ns();
  for (int r = 0; r < REPS; r++) {
    __asm__ volatile("" ::: "memory");  /* each rep runs: no CSE of the calls */
    int64_t s;
    if (!strcmp(v, "hand")) s = w2_hand(root);
    else if (!strcmp(v, "hand-stack")) s = w2_hand_stack(root);
    else if (!strcmp(v, "push")) s = w2_push(root);
    else if (!strcmp(v, "pull-box")) s = w2_pull_box(root);
    else if (!strcmp(v, "pull-reuse")) s = w2_pull_reuse(root);
    else if (!strcmp(v, "pull-stack")) s = w2_pull_stack(root);
    else if (!strcmp(v, "pull-stack2")) s = w2_pull_stack2(root);
    else { fprintf(stderr, "variant?\n"); return 2; }
    sum += s;
  }
  uint64_t t1 = now_ns();
  printf("check=%lld\n", (long long)sum);
  printf("w2_ns=%llu\n", (unsigned long long)(t1 - t0));
  return 0;
}
