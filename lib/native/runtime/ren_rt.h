/* The Ren runtime: what every program `ren build` makes is linked with.

   A value is a scalar, an `Int` (int64_t), a `Float` (double), a `Bool`
   or a `Unit`, or a pointer to a counted object: a record, a tuple, a
   constructor with fields, an error, an array or a `Str`. A sum type's
   constructor with no fields is a small scalar in the pointer instead,
   its tag shifted left with the low bit set, so it's never counted.
   That's Lean's `lean_box` (lean.h, `lean_is_scalar`).

   Every object starts with a header word: its count, and enough to free
   it without knowing its type. A count of 0 marks an object that's never
   freed, as Lean's `m_rc == 0` does: a string literal, made once in the
   C file. Counts are plain, never atomic, since a program has one
   thread (foundations.md, decision 10, makes them atomic only on
   shared objects, once there are tasks).

   The C file `ren build` writes holds this header, then ren_rt.c, then
   the program, so a binary needs nothing installed. Building it with
   -DREN_STATS adds counters, printed to stderr when it exits. */

#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t ren_unit;

/* What an object holds, which says how to free it. */
enum { REN_CTOR = 0, REN_ARRAY = 1, REN_STR = 2 };

/* The header. A constructor keeps its counted fields first, then its
   scalars, so freeing it drops the first [nobjs] of its [nfields], as
   Lean's `m_other` says how many of a constructor's fields are objects
   (lean.h, `lean_ctor_object`). */
typedef struct ren_obj {
  int32_t rc;          /* > 0: counted; 0: never freed */
  uint16_t tag;        /* a constructor's, a record's (0) or an error's */
  uint8_t kind;        /* REN_CTOR, REN_ARRAY or REN_STR */
  uint8_t boxed_elems; /* an array's: whether its elements are counted */
  uint32_t nobjs;      /* a constructor's counted fields */
  uint32_t nfields;    /* a constructor's fields */
} ren_obj;

/* A field or an array element: eight bytes, whatever it holds. A `Bool`,
   a `Unit` and a constructor with no fields of a sum without fields are
   kept in [i]. */
typedef union {
  int64_t i;
  double f;
  ren_obj *o;
} ren_val;

typedef struct {
  ren_obj h;
  ren_val fields[];
} ren_ctor;

typedef struct {
  ren_obj h;
  int64_t len;
  int64_t cap;
  ren_val *data;
} ren_array;

typedef struct {
  ren_obj h;
  int64_t len;
  char data[]; /* [len] bytes, then a 0 */
} ren_str;

/* Where a panic is, and what's printed around its message: the
   compiler renders `ren run`'s message with a hole where the message
   goes, so the two print the same bytes. */
typedef struct {
  const char *before;
  const char *after;
} ren_site;

/* ---- statistics ---- */

#ifdef REN_STATS
typedef struct {
  int64_t allocs, frees, dups, drops, reuses, live_bytes, peak_bytes;
} ren_stats_t;
extern ren_stats_t ren_stats;
#define REN_STAT(field) (ren_stats.field++)
#else
#define REN_STAT(field) ((void)0)
#endif

/* ---- panics ---- */

/* Print `before`, the message and `after` to stderr, and end the program
   with exit code 1, as `ren run` does. Values still held are leaked
   (foundations.md, decision 8). */
_Noreturn void ren_panic(const ren_site *site, const char *msg);

/* The stack overflowed: [ren_stack_limit] is the lowest address a frame
   may start below, a margin above the end of the stack the program runs
   on, which [ren_run] sets. Every function checks it when it starts, as
   Go's do. */
extern char *ren_stack_limit;
extern const ren_site *ren_overflow_site;
_Noreturn void ren_stack_overflowed(void);
#define REN_STACK_CHECK()                                                      \
  do {                                                                         \
    if ((char *)__builtin_frame_address(0) < ren_stack_limit)                 \
      ren_stack_overflowed();                                                  \
  } while (0)

/* ---- counting ---- */

static inline bool ren_is_scalar(ren_obj *o) { return ((uintptr_t)o & 1) == 1; }
static inline ren_obj *ren_box(uint32_t tag) {
  return (ren_obj *)(((uintptr_t)tag << 1) | 1);
}

/* The tag of a sum type's value: a constructor with fields keeps it in
   its header, one without is the scalar itself (lean.h,
   `lean_obj_tag`). */
static inline int64_t ren_tag(ren_obj *o) {
  return ren_is_scalar(o) ? (int64_t)((uintptr_t)o >> 1) : (int64_t)o->tag;
}

void ren_free(ren_obj *o);

/* One more reference: lean.h's `lean_inc_ref`, and kklib's
   `kk_block_dup`, without their thread-shared paths. */
static inline void ren_dup(ren_obj *o) {
  if (ren_is_scalar(o) || o->rc == 0)
    return;
  REN_STAT(dups);
  o->rc++;
}

/* One reference fewer, freeing the object with the last: lean.h's
   `lean_dec_ref`, whose fast path is a count above 1. */
static inline void ren_drop(ren_obj *o) {
  if (ren_is_scalar(o))
    return;
  if (o->rc > 1) {
    REN_STAT(drops);
    o->rc--;
  } else if (o->rc != 0) {
    REN_STAT(drops);
    ren_free(o);
  }
}

/* Whether [o] is held by nothing else, so it can be changed in place:
   Lean's `lean_is_exclusive`, kklib's `kk_block_is_unique`. Nothing in
   the naive backend asks yet. */
static inline bool ren_is_unique(ren_obj *o) {
  return !ren_is_scalar(o) && o->rc == 1;
}

/* ---- objects ---- */

/* A constructor of [nfields] fields, the first [nobjs] of them counted,
   with its count at 1. The caller fills in the fields. */
ren_obj *ren_alloc_ctor(uint16_t tag, uint32_t nfields, uint32_t nobjs);

static inline ren_val *ren_fields(ren_obj *o) { return ((ren_ctor *)o)->fields; }

/* An array of [len] elements, which the caller fills in. */
ren_obj *ren_alloc_array(int64_t len, bool boxed_elems);
static inline ren_val *ren_elems(ren_obj *o) { return ((ren_array *)o)->data; }

/* ---- arrays ---- */

int64_t ren_array_len(ren_obj *a);

/* Element [i], counted again if it's an object: panics if [i] is out of
   bounds, as `xs[i]` does. */
ren_val ren_array_get(ren_obj *a, int64_t i, const ren_site *site);

/* A new array, [a] with element [i] replaced by [v]: the naive
   semantics, which copies. Neither argument is taken. */
ren_obj *ren_array_set(ren_obj *a, int64_t i, ren_val v, const ren_site *site);

/* `&xs.push(v)`: what [cell] holds, copied, with [v] after it, put back
   in [cell]. [v] isn't taken. */
void ren_array_push(ren_obj **cell, ren_val v);

/* ---- strings ---- */

ren_obj *ren_str_of(const char *s, int64_t len);
static inline int64_t ren_str_len(ren_obj *s) { return ((ren_str *)s)->len; }
static inline const char *ren_str_data(ren_obj *s) { return ((ren_str *)s)->data; }
ren_obj *ren_str_concat(ren_obj *a, ren_obj *b);
bool ren_str_eq(ren_obj *a, ren_obj *b);

/* What `show` makes of a scalar, as Ren writes it. */
ren_obj *ren_show_int(int64_t n);
ren_obj *ren_show_float(double f);
ren_obj *ren_show_bool(bool b);

/* [f] as Ren writes it, into [buf] (at least 400 bytes): the fewest
   digits that read back as [f], with no exponent (token.ml,
   `show_float`). */
void ren_format_float(char *buf, double f);

/* A `Str` as it's written in source, in quotes, with its escapes, to
   [out]: how `ren run` prints a `main` that gives one. */
void ren_print_quoted(FILE *out, ren_obj *s);

/* ---- arithmetic ----

   An `Int` that overflows panics, and so does a `Float` operation that
   would make a NaN (operators.md, "`Int` and `Float`"), with the
   interpreter's messages (lib/eval/arith.ml). */

_Noreturn void ren_int_overflowed(const ren_site *site, const char *op,
                                  int64_t a, int64_t b);
_Noreturn void ren_float_undefined(const ren_site *site, const char *op,
                                   double a, double b);

static inline int64_t ren_add(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (__builtin_add_overflow(a, b, &r))
    ren_int_overflowed(site, "+", a, b);
  return r;
}

static inline int64_t ren_sub(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (__builtin_sub_overflow(a, b, &r))
    ren_int_overflowed(site, "-", a, b);
  return r;
}

static inline int64_t ren_mul(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (__builtin_mul_overflow(a, b, &r))
    ren_int_overflowed(site, "*", a, b);
  return r;
}

int64_t ren_div(int64_t a, int64_t b, const ren_site *site);
int64_t ren_rem(int64_t a, int64_t b, const ren_site *site);
int64_t ren_neg(int64_t a, const ren_site *site);

static inline double ren_fcheck(double r, const char *op, double a, double b,
                                const ren_site *site) {
  if (isnan(r))
    ren_float_undefined(site, op, a, b);
  return r;
}

static inline double ren_fadd(double a, double b, const ren_site *site) {
  return ren_fcheck(a + b, "+", a, b, site);
}
static inline double ren_fsub(double a, double b, const ren_site *site) {
  return ren_fcheck(a - b, "-", a, b, site);
}
static inline double ren_fmul(double a, double b, const ren_site *site) {
  return ren_fcheck(a * b, "*", a, b, site);
}
static inline double ren_fdiv(double a, double b, const ren_site *site) {
  return ren_fcheck(a / b, "/", a, b, site);
}
static inline double ren_frem(double a, double b, const ren_site *site) {
  return ren_fcheck(fmod(a, b), "%", a, b, site);
}

/* `Float`'s methods that can panic: a square root of a negative number,
   or a rounding that doesn't fit in an `Int` (lib/eval/builtins.ml). */
double ren_fsqrt(double a, const ren_site *site);
int64_t ren_fround(double a, const ren_site *site);
int64_t ren_ftruncate(double a, const ren_site *site);

/* ---- the world ---- */

/* The real `Console`: a line to stdout, or to stderr. */
void ren_console_write(ren_obj *line);
void ren_console_error(ren_obj *line);

/* Run [program] on a thread whose stack is big enough for deep
   recursion, then flush stdout and print the statistics, if they're on.
   What `main` returns. */
int ren_run(void (*program)(void));
