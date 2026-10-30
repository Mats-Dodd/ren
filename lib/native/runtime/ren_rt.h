/* The Ren runtime: what every program `ren build` makes is linked with.

   A value is a scalar, an `Int` (int64_t), a `Float` (double), a `Bool`
   or a `Unit`, or a pointer to a counted object: a record, a tuple, a
   constructor with fields, an error, an array or a `Str`. A sum type's
   constructor with no fields is a small scalar in the pointer instead,
   its tag shifted left with the low bit set, so it's never counted.
   That's Lean's `lean_box` (lean.h, `lean_is_scalar`).

   Every object starts with a header word, eight bytes: its count, and
   enough to free it without knowing its type. A count of 0 marks an
   object that's never freed, as Lean's `m_rc == 0` does: a string
   literal, made once in the C file. Counts are plain, never atomic,
   since a program has one thread. A negative count is kept for the
   shared mark foundations.md's many-cores decision needs, as Lean's
   is (lean.h:146, `m_rc < 0`: multi-threaded, counted
   atomically): every fast path below tests for a positive count, and
   the rest goes to a cold path, so marking an object shared later
   costs the single-threaded code nothing. Nothing makes a count
   negative yet.

   A release build's C file holds this header, then ren_rt.c, then the
   program, so a binary needs nothing installed. A debug build writes
   this header, ren_rt.c as a unit of its own, and the program in units
   of a few modules each, which it compiles in parallel (foundations.md,
   decision 13). Building it with -DREN_STATS adds counters, printed to
   stderr when it exits. */

#ifndef REN_UNIT
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#else
/* A unit of the program's code (REN_UNIT) includes no system header:
   they were most of the time tcc took on a unit of one module, 6.7 of
   8.1 ms (research/backend.md, 4b). What this header and the program's
   code use of them is declared here instead, as the C library declares
   it; the runtime's own unit, ren_rt.c, includes the headers. */
typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef short int16_t;
typedef unsigned short uint16_t;
typedef int int32_t;
typedef unsigned int uint32_t;
#ifdef __INT64_TYPE__
typedef __INT64_TYPE__ int64_t;
typedef unsigned __INT64_TYPE__ uint64_t;
#else
typedef long long int64_t;
typedef unsigned long long uint64_t;
#endif
typedef __SIZE_TYPE__ size_t;
typedef __UINTPTR_TYPE__ uintptr_t;
#define bool _Bool
#define true 1
#define false 0
#define NULL ((void *)0)
#define INT8_MIN (-128)
#define INT8_MAX 127
#define UINT8_MAX 255
#define INT16_MIN (-32768)
#define INT16_MAX 32767
#define UINT16_MAX 65535
#define INT32_MIN (-2147483647 - 1)
#define INT32_MAX 2147483647
#define UINT32_MAX 4294967295U
#define INT64_MAX 9223372036854775807LL
#define INT64_MIN (-INT64_MAX - 1)
#define UINT64_MAX 18446744073709551615ULL
#define INT64_C(c) c##LL
#define UINT64_C(c) c##ULL
#ifdef __TINYC__
#define INFINITY (1.0f / 0.0f)
#else
#define INFINITY (__builtin_inff())
#endif
/* a NaN is the one value not equal to itself; no unit is compiled with
   -ffast-math, which would make it equal */
#define isnan(x) ((x) != (x))
void *memcpy(void *restrict dst, const void *restrict src, size_t n);
void *malloc(size_t n);
void *realloc(void *p, size_t n);
void free(void *p);
double fabs(double x);
double sqrt(double x);
double fmod(double x, double y);
#endif

typedef uint8_t ren_unit;

/* What an object holds, which says how to free it, is its tag: a
   constructor's, a record's (0) or an error's, or one of these three
   at the top, as Lean's tags above `LeanMaxCtorTag` are its arrays and
   strings (lean.h:113-125) and kklib's `KK_TAG_STRING` and the rest
   theirs. */
enum {
  REN_TAG_MAP = 0xFFFC,
  REN_TAG_ARRAY = 0xFFFD,
  REN_TAG_STR = 0xFFFE,
  REN_TAG_DESC = 0xFFFF,
};

/* The header, after Lean's `lean_object` (lean.h:174) and kklib's
   `kk_header_t` (kklib.h:136): a 32-bit count, a 16-bit tag and two
   bytes. A constructor's fields are in the order they're declared,
   [nfields] of them, and [objs] has a bit for each of the first eight
   that holds an object, so freeing it drops those. A constructor of
   more than eight fields keeps that mask in a word after its fields,
   ren_ctor_objs's, 64 fields at most.

   A mask, where Koka and Lean put the fields that hold objects first
   and keep their count (kklib's `scan_fsize`, Lean's `m_other`): both
   box a value of a type variable's type, so a field holds an object or
   doesn't whatever the value. Ren keeps an `Int` there unboxed (a
   [ren_val] word), so whether that field holds an object is the
   value's, which its maker knows from the type's descriptor, and
   moving it would make where a field is the value's too, which generic
   code couldn't find without reading the header. The order stays the
   declaration's, and the mask goes in the byte the count would.

   An array keeps which of its elements' words hold objects in [objs]:
   1 if its elements are words that are counted, and for an array of
   structs (a release build's small values, Mem's [Struct]) the
   struct's mask, bit [i] set if slot [i] holds an object, which fits,
   since a struct that holds one has at most four slots (to_mem.ml,
   [small]). In [nfields] it keeps whether they're of a sized type
   (sized.ml), kept at its width, and which ([REN_ELEM_U8] and the
   rest), or words, 0. A string and a descriptor use neither byte. */
typedef struct ren_obj {
  int32_t rc;      /* > 0: counted; 0: never freed; < 0: kept, shared */
  uint16_t tag;    /* a constructor's, or REN_TAG_ARRAY, _STR or _DESC */
  uint8_t nfields; /* a constructor's fields; an array's [REN_ELEM_*] */
  uint8_t objs;    /* its first eight that hold objects; an array's: which
                      words of an element hold objects */
} ren_obj;

/* A field or an array element: eight bytes, whatever it holds. A `Bool`,
   a `Unit` and a constructor with no fields of a sum without fields are
   kept in [i]. It's also what a type variable's value is, a word: a
   `Float` as its bits, an object as its pointer (Koka boxes what isn't a
   word at that boundary, Backend/C/Box.hs, `boxExpr`; every Ren value
   but a block is one, and a block is never a type's argument). [p] is
   a raw pointer: a handler's code. */
typedef union {
  int64_t i;
  double f;
  ren_obj *o;
  void *p;
} ren_val;

typedef struct {
  ren_obj h;
  ren_val fields[];
} ren_ctor;

/* An array, or a slice of one (foundations.md, decision 17): Roc's
   seamless slices, a slice the same type as what it slices. An owner
   holds its buffer, [data], and [root] is NULL. A slice's [data] points
   into its root's buffer, [len] elements from where it starts, and
   [root] is the owner, counted: a slice keeps its whole root alive, and
   a slice of a slice has the first one's root, so roots never chain.
   Readers can't tell one from the other, since each reads through
   [data].

   An owner whose count is 1 is changed in place ([ren_array_unique]);
   so is a slice whose count is 1 if it's lent ([ren_array_writable]): a
   half of a `split_at` of a value nothing else held, the range of which
   nothing else sees. Writing to any other slice copies its range first,
   into an owner of its own. An owner's [cap] is at least 1, a slice's
   is 0, and a lent slice's is -1, so the tests of both read [cap] and
   not [root]: reading [root] on every push and write made blocks' map
   14% slower in cycles, and inout's array kernels 2% (RESULTS.md,
   "Slices"). */
typedef struct {
  ren_obj h;
  int64_t len;
  int64_t cap;    /* an owner's room, at least 1; a slice's 0, -1 if lent */
  ren_val *data;
  int64_t stride; /* words an element, 1 but for an array of structs; 1
                     for one of a sized type, whose width its kind says */
  ren_obj *root;  /* NULL, or the owner of the buffer [data] is in */
} ren_array;

/* The kinds of an array's elements: words, or a sized type's, each kept
   at its width (sized.ml), as Lean keeps a `ByteArray` and a
   `FloatArray`'s elements unboxed (lean.h, `lean_sarray_object`), but
   for every sized type, and decided by the element type, so an array's
   kind is always its type's: code that knows the type indexes it
   directly, and only code that doesn't, a generic function in a debug
   build, asks the array ([ren_array_get_w]). A `UInt64` holds what an
   `Int` can that isn't negative, so it's a word too, but one that says
   it's sized. */
enum {
  REN_ELEM_WORD,
  REN_ELEM_I8,
  REN_ELEM_U8,
  REN_ELEM_I16,
  REN_ELEM_U16,
  REN_ELEM_I32,
  REN_ELEM_U32,
  REN_ELEM_U64,
  REN_ELEM_F32,
};
static const uint8_t ren_elem_size[] = {8, 1, 1, 2, 2, 4, 4, 8, 4};

/* A `Float32`'s bits, and the `Float32` of bits, for packing one. */
static inline uint32_t ren_f32_bits(float f) {
  uint32_t b;
  memcpy(&b, &f, sizeof b);
  return b;
}
static inline float ren_f32_of_bits(uint32_t b) {
  float f;
  memcpy(&f, &b, sizeof f);
  return f;
}

/* The [bits] of a value of the sized type [kind] kept at its width, as a
   word: the number it is, as an `Int` (or a `Float`), which is how
   generic code and the walks see one. */
static inline ren_val ren_sized_word(uint8_t kind, uint64_t bits) {
  ren_val v;
  switch (kind) {
  case REN_ELEM_I8:
    v.i = (int8_t)(uint8_t)bits;
    break;
  case REN_ELEM_I16:
    v.i = (int16_t)(uint16_t)bits;
    break;
  case REN_ELEM_I32:
    v.i = (int32_t)(uint32_t)bits;
    break;
  case REN_ELEM_F32:
    v.f = (double)ren_f32_of_bits((uint32_t)bits);
    break;
  default:
    v.i = (int64_t)bits;
  }
  return v;
}

/* A `Str` or `Bytes`, the same in memory: an owner, whose [data] is its
   own [bytes], [len] of them then a 0, and whose [root] is NULL; or a
   slice, whose [data] points into its root's bytes, not followed by a 0,
   and whose [root] is that owner, counted, as an array's is. Nothing
   writes a string's bytes once it's made, so a slice is never copied. */
typedef struct {
  ren_obj h;
  int64_t len;
  const char *data;
  ren_obj *root;
  char bytes[];
} ren_str;

/* Where a panic is, and what it prints: the compiler renders `ren run`'s
   message in pieces (diag.ml, [piece]), with a hole where the message
   goes, so the two print the same bytes. [ops] are the pieces, each a
   byte that says which and its numbers after it, 7 bits a byte, least
   first, the top bit set on all but the last (LEB128), ending in a 0:

     1 t        the program's text [t] (ren_texts)
     2 n        [n] spaces
     3 c n      the byte [c], [n] times: a `^` or a `-` under the code
     4 n        the number [n]: a line or a column
     5          the message
     6 t i n    the [n] bytes from [i] of text [t]: code an operand is

   A file's name and each of its lines are one text, which every panic in
   them shares: a panic costs a few bytes, not the line it's on (60% of a
   binary, when each kept its message whole). */
typedef struct {
  const unsigned char *ops;
} ren_site;

/* The program's texts, which its sites' pieces print. */
extern const char *const *ren_texts;

/* ---- statistics ---- */

#ifdef REN_STATS
/* [allocs] counts the objects made and [frees] those given back, so
   their difference is what's live; [reuses] counts objects built in the
   memory of one that died, which is neither, and [grows] an array's
   buffer made bigger in place, which [peak_bytes] counts but isn't an
   object. */
typedef struct {
  int64_t allocs, frees, dups, drops, reuses, grows, live_bytes, peak_bytes,
      block_calls;
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

/* The same, with the message a `Str`, [s]: a failed `assert` of the
   prelude's, which shows the values it's about. */
_Noreturn void ren_panic_str(const ren_site *site, ren_obj *s);

/* Where a panic in the prelude is said to be: the program's call that
   reached it, as `ren run` says, since the prelude's source isn't shown.
   Set before each call of the prelude from the program's code (Mem's
   [Here_set]), and put back by prelude code after a block it called
   returns. */
extern const ren_site *ren_here;

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

/* The tag of a small value kept with a pointer niche (mem.mli, `Niche`),
   from its object slot `o`: constructor `t` without fields is
   `ren_box(UINT32_MAX - t)`, for each `t` up to `most`, and anything
   else, an object or a boxed sum's constructor without fields, a scalar
   of a small tag, is the constructor `obj` with fields. */
static inline int64_t ren_niche_tag(ren_obj *o, int64_t obj, uint32_t most) {
  uintptr_t w = (uintptr_t)o;
  return (w & 1) && (w >> 1) >= (uintptr_t)(UINT32_MAX - most)
             ? (int64_t)(UINT32_MAX - (w >> 1))
             : obj;
}

void ren_free(ren_obj *o);

/* Counting has three modes, chosen when the C is compiled, and the
   default is the first. They're an experiment for decision 10 of
   foundations.md, which has no runtime with threads yet: the other two
   exist to measure what threads would cost (bench/native/cores).

   - plain (the default): counts are plain, as a program has one thread.
     A negative count, which nothing makes, goes to [ren_shared_count],
     which aborts.
   - -DREN_RC_SHARED: Lean's scheme (lean.h:631-745). A count above 0 is
     one thread's and plain, one below 0 is shared and atomic, counted
     down from -1, and 0 is never freed. The negative counts the plain
     mode keeps cold are these: [ren_shared_count]'s place is taken by
     [ren_dup_shared] and [ren_drop_shared], so the hot paths are the
     plain mode's. [ren_mark_shared] negates the counts of everything an
     object reaches before it's handed to another thread, as
     `lean_mark_mt` does (runtime/object.cpp:663). Lean's sticky range
     for counts that overflow isn't copied.
   - -DREN_RC_ATOMIC: every count is atomic, Swift's and Rust's `Arc`'s
     way: the worst case, to compare against.

   Either of the last two also makes the heap and the list [ren_free]
   keeps thread local, unless -DREN_RC_NO_TLS, which is only sound with
   one thread and measures the counting alone. */

#if defined(REN_RC_SHARED) && defined(REN_RC_ATOMIC)
#error "REN_RC_SHARED and REN_RC_ATOMIC are two modes: give one"
#endif

#if (defined(REN_RC_SHARED) || defined(REN_RC_ATOMIC)) &&                     \
    !defined(REN_RC_NO_TLS)
#define REN_THREAD_LOCAL _Thread_local
#else
#define REN_THREAD_LOCAL
#endif

#if (defined(REN_RC_SHARED) || defined(REN_RC_ATOMIC)) &&                     \
    !defined(REN_RC_PLAIN_READ)
/* Read a count that another thread may change: relaxed, a plain load on
   arm64 and x86-64, but not a data race in C11. It costs something all
   the same, since the C compiler may not merge two such loads, as it
   does the plain ones of an `ren_is_unique` and the drop after it.
   Lean reads it plainly (lean.h:387) outside TSan, a race C11 calls
   undefined; -DREN_RC_PLAIN_READ does the same, to measure the
   difference. */
static inline int32_t ren_rc(ren_obj *o) {
  return __atomic_load_n(&o->rc, __ATOMIC_RELAXED);
}
#else
static inline int32_t ren_rc(ren_obj *o) { return o->rc; }
#endif

#ifdef REN_RC_SHARED
/* The shared paths, out of line as Lean's `lean_dec_ref_cold` is. */
void ren_dup_shared(ren_obj *o);
void ren_drop_shared(ren_obj *o);
/* Mark everything [o] reaches shared, while one thread still owns it. */
void ren_mark_shared(ren_obj *o);
#define ren_dup_cold ren_dup_shared
#define ren_drop_cold ren_drop_shared
#else
/* A shared object's count, which is negative: what a thread that
   isn't its owner's does, atomically, once there are tasks. */
_Noreturn void ren_shared_count(ren_obj *o);
static inline void ren_mark_shared(ren_obj *o) { (void)o; }
#define ren_dup_cold ren_shared_count
#define ren_drop_cold ren_shared_count
#endif

/* One more reference: lean.h's `lean_inc_ref` (a positive count, then
   `lean_inc_ref_cold`), and kklib's `kk_block_dup`. */
static inline void ren_dup(ren_obj *o) {
  if (ren_is_scalar(o))
    return;
#if defined(REN_RC_ATOMIC)
  if (ren_rc(o) == 0)
    return;
  REN_STAT(dups);
  __atomic_fetch_add(&o->rc, 1, __ATOMIC_RELAXED);
#else
  int32_t rc = ren_rc(o);
  if (__builtin_expect(rc > 0, 1)) {
    REN_STAT(dups);
    o->rc = rc + 1;
  } else if (rc != 0)
    ren_dup_cold(o);
#endif
}

/* One reference fewer, freeing the object with the last: lean.h's
   `lean_dec_ref`, whose fast path is a count above 1. */
static inline void ren_drop(ren_obj *o) {
  if (ren_is_scalar(o))
    return;
#if defined(REN_RC_ATOMIC)
  if (ren_rc(o) == 0)
    return;
  REN_STAT(drops);
  /* Arc's drop: release, and acquire only for the last */
  if (__atomic_sub_fetch(&o->rc, 1, __ATOMIC_RELEASE) == 0) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    ren_free(o);
  }
#else
  int32_t rc = ren_rc(o);
  if (__builtin_expect(rc > 1, 1)) {
    REN_STAT(drops);
    o->rc = rc - 1;
  } else if (rc == 1) {
    REN_STAT(drops);
    ren_free(o);
  } else if (rc != 0)
    ren_drop_cold(o);
#endif
}

/* Whether [o] is held by nothing else, so it can be changed in place:
   Lean's `lean_is_exclusive`, kklib's `kk_block_is_unique`. A shared
   object never is, as in Lean (lean.h:776), since another thread may
   take a reference while this one looks. */
static inline bool ren_is_unique(ren_obj *o) {
#if defined(REN_RC_ATOMIC)
  return !ren_is_scalar(o) && __atomic_load_n(&o->rc, __ATOMIC_ACQUIRE) == 1;
#else
  return !ren_is_scalar(o) && ren_rc(o) == 1;
#endif
}

/* ---- the heap ----

   Objects of up to [REN_SMALL_WORDS] words come from free lists, one
   for each size in words, as kklib gets them from mimalloc
   (kklib.h:511, `kk_malloc_small`, `mi_theap_wmalloc_small` by word
   size) and Lean through `lean_alloc_small_object` (lean.h:522, also
   mimalloc's now), whose size the compiler knows at most calls, so the
   branch on it folds away, as it does here. A free object's first word
   points to the next; a list that's empty is refilled from a chunk of
   memory taken a bump at a time, and a chunk used up is replaced by a
   new one from the system. Nothing is zeroed: every allocation's
   caller writes all of what it reads.

   Freeing is told the size, which every object's header gives
   (ren_free_one), so it needs no lookup. Memory freed to a list stays
   with that size for the rest of the program, and chunks are never
   given back, so a program whose live objects change size over time
   can hold more than malloc would; Lean's and mimalloc's pages, which
   go back to a shared pool when empty, are the fix if that shows.

   One heap, since a program has one thread (the counting modes for
   threads make it thread local, REN_THREAD_LOCAL: a chunk is never
   given back, so a block freed on another thread than the one it came
   from can go on that thread's list): with tasks, each thread
   gets its own, as kklib's context holds one (kklib.h:367), and an
   object freed on a thread that isn't its own goes back to its owner's,
   as mimalloc's delayed free does. Bigger objects, and an array's
   elements, which grow with realloc, use malloc. Building with
   -DREN_SYSTEM_MALLOC sends everything to malloc, for tools that
   check it; AddressSanitizer does, so a build under it does too, and a
   use after free is still caught (bench/build.t). */

#if defined(__SANITIZE_ADDRESS__)
#define REN_SYSTEM_MALLOC 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define REN_SYSTEM_MALLOC 1
#endif
#endif

#define REN_SMALL_WORDS 64
#define REN_CHUNK_BYTES ((size_t)1 << 20)

typedef struct {
  void *free[REN_SMALL_WORDS + 1]; /* by size in words; [0] unused */
  char *bump, *end;                /* what's left of the chunk */
} ren_heap_t;
extern REN_THREAD_LOCAL ren_heap_t ren_heap;

void *ren_alloc_slow(size_t words);
void *ren_alloc_big(size_t bytes);

static inline size_t ren_words(size_t bytes) { return (bytes + 7) >> 3; }

/* [bytes] of memory, not zeroed. */
static inline void *ren_alloc_bytes(size_t bytes) {
#ifndef REN_SYSTEM_MALLOC
  size_t w = ren_words(bytes);
  if (__builtin_expect(w <= REN_SMALL_WORDS, 1)) {
    void *p = ren_heap.free[w];
    if (__builtin_expect(p != NULL, 1)) {
      ren_heap.free[w] = *(void **)p;
      return p;
    }
    return ren_alloc_slow(w);
  }
#endif
  return ren_alloc_big(bytes);
}

/* Memory [ren_alloc_bytes] gave, of the same [bytes]. */
static inline void ren_free_bytes(void *p, size_t bytes) {
#ifndef REN_SYSTEM_MALLOC
  size_t w = ren_words(bytes);
  if (__builtin_expect(w <= REN_SMALL_WORDS, 1)) {
    *(void **)p = ren_heap.free[w];
    ren_heap.free[w] = p;
    return;
  }
#else
  (void)bytes;
#endif
  free(p);
}

#ifdef REN_STATS
void ren_count_alloc(int64_t bytes);
#endif

/* ---- objects ---- */

static inline ren_val *ren_fields(ren_obj *o) { return ((ren_ctor *)o)->fields; }

/* A constructor's size: the header, its fields, and the mask's word if
   it has more than eight. */
static inline size_t ren_ctor_size(uint32_t nfields) {
  return sizeof(ren_ctor) + (nfields + (nfields > 8)) * sizeof(ren_val);
}

/* Which of a constructor's fields hold objects, a bit each. */
static inline uint64_t ren_ctor_objs(ren_obj *o) {
  return o->nfields <= 8 ? o->objs
                         : (uint64_t)ren_fields(o)[o->nfields].i;
}

static inline void ren_set_objs(ren_obj *o, uint32_t nfields, uint64_t objs) {
  if (nfields <= 8)
    o->objs = (uint8_t)objs;
  else
    ren_fields(o)[nfields].i = (int64_t)objs;
}

/* A constructor of [nfields] fields, those with a bit in [objs]
   counted, with its count at 1. The caller fills in the fields. The
   compiler passes [nfields] as a constant, so the branches on it fold. */
static inline ren_obj *ren_alloc_ctor(uint16_t tag, uint32_t nfields,
                                      uint64_t objs) {
  size_t bytes = ren_ctor_size(nfields);
  ren_obj *o = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  o->rc = 1;
  o->tag = tag;
  o->nfields = (uint8_t)nfields;
  ren_set_objs(o, nfields, objs);
  return o;
}

/* ---- reuse ----

   What Perceus does with an object that dies unique (compiler.md,
   "Native slice"). [kept] has a bit for each field the program took
   out of it, whose reference is now the program's: every other field
   that holds an object is dropped. */

/* Free [o], whose count is 1, and drop the fields it doesn't keep: Koka's
   drop specialization (Parc.hs, `specializeDrop`), so taking the fields
   of a constructor that dies costs no counting. */
void ren_free_keeping(ren_obj *o, uint64_t kept);

/* The fields of [o] that hold objects and aren't in [kept], dropped. */
void ren_drop_unkept(ren_obj *o, uint64_t kept);

/* The same, but keep [o]'s memory to build a constructor of as many
   fields in: a reuse token (Lean's `reset`, kklib.h's
   `kk_block_alloc_at`). Inline, since it usually keeps every field that
   holds an object, and then does nothing. */
static inline ren_obj *ren_reset(ren_obj *o, uint64_t kept) {
  if ((ren_ctor_objs(o) & ~kept) != 0)
    ren_drop_unkept(o, kept);
  return o;
}

/* A token's memory as a constructor of [tag] again, of the same
   [nfields], with a count of 1; the caller writes the fields that
   changed. */
static inline ren_obj *ren_reuse(ren_obj *tok, uint16_t tag, uint32_t nfields,
                                 uint64_t objs) {
  REN_STAT(reuses);
  tok->rc = 1;
  tok->tag = tag;
  ren_set_objs(tok, nfields, objs);
  return tok;
}

/* A token nothing was built in: its memory, if it has some, given back. */
void ren_free_token(ren_obj *tok);

/* An array of [len] elements, which the caller fills in. */
ren_obj *ren_alloc_array(int64_t len, bool boxed_elems);
static inline ren_val *ren_elems(ren_obj *o) { return ((ren_array *)o)->data; }

/* An empty array with room for [cap] elements of [stride] words each,
   0 meaning 1, [objs] the words of each that hold objects ([ren_obj]):
   what `map` makes when it can't reuse its input. */
ren_obj *ren_array_reserve(int64_t cap, uint8_t objs, uint32_t stride);

/* The same, of a sized type's elements, of the kind [REN_ELEM_U8] and
   the rest. */
ren_obj *ren_alloc_array_k(int64_t len, uint8_t kind);
ren_obj *ren_array_reserve_k(int64_t cap, uint8_t kind);

/* An array of [len] elements of [stride] words each, a release build's
   structs (a copied record's fields, Mem's [Struct]), kept in the
   elements, the slots in [objs]'s mask holding objects, which the array
   counts, as it counts an array of objects' elements (the data stage's
   second layout fix, compiler.md, "The layout fixes (step 7)"). Never
   walked, since nothing that walks a value is given a struct. */
ren_obj *ren_alloc_array_n(int64_t len, uint32_t stride, uint8_t objs);
static inline int64_t ren_stride(ren_obj *a) { return ((ren_array *)a)->stride; }

/* ---- arrays ----

   Reading an element and changing one in place are inline: the index
   checked, the array made unique if it isn't, and the element read or
   written, with what's rare, a panic or a copy, out of line. That's
   lean.h's `lean_array_uset` over `lean_ensure_exclusive_array`
   (lean.h:1142-1182). A function named with `_s` is for elements that
   are never counted, a scalar's, which the compiler knows; `_k` for an
   array of structs whose stride the compiler knows, [k] words. */

static inline int64_t ren_array_len(ren_obj *a) { return ((ren_array *)a)->len; }

/* Panics: [i] is out of bounds for [a], or for an array of [len]. */
_Noreturn void ren_index_panic(ren_obj *a, int64_t i, const ren_site *site);
_Noreturn void ren_index_panic_len(int64_t len, int64_t i, const ren_site *site);

/* The site of an index the compiler proved in bounds (bounds.ml): a
   loop's count, below the length of every array it indexes, which
   nothing in the loop changes. Each check below is skipped for it, and
   with it constant, C drops the compare. It's a site of its own, not
   NULL, so no site the program computes can be it. */
static const ren_site ren_in_bounds_site;
#define REN_IN_BOUNDS (&ren_in_bounds_site)

/* Panics, as `xs[i]` does, if [i] is out of bounds; one unsigned
   compare, since a length is never below 0. */
static inline void ren_array_check(ren_obj *a, int64_t i, const ren_site *site) {
  if (site != REN_IN_BOUNDS &&
      __builtin_expect((uint64_t)i >= (uint64_t)((ren_array *)a)->len, 0))
    ren_index_panic(a, i, site);
}

/* A copy of [a], which is shared, each element counted again; [a]'s
   reference is dropped. */
ren_obj *ren_array_unshare(ren_obj *a);

/* Whether [a] can grow in place: unique, and an owner, not a slice of
   another's buffer, which another slice's elements may follow. */
static inline bool ren_array_unique(ren_obj *a) {
  return ren_rc(a) == 1 && ((ren_array *)a)->cap > 0;
}

/* Whether [a]'s elements can be changed in place: unique, and an owner or
   a lent slice. Every change in place of an element asks this. */
static inline bool ren_array_writable(ren_obj *a) {
  return ren_rc(a) == 1 && ((ren_array *)a)->cap != 0;
}

/* [a], taken, made writable: itself if it is, else a copy, which a
   slice's write makes of its range. */
static inline ren_obj *ren_array_own(ren_obj *a) {
  return __builtin_expect(ren_array_writable(a), 1) ? a : ren_array_unshare(a);
}

/* Element [i], counted again if it's an object: panics if [i] is out of
   bounds, as `xs[i]` does. */
static inline ren_val ren_array_get(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
  ren_val v = ((ren_array *)a)->data[i];
  if (a->objs)
    ren_dup(v.o);
  return v;
}
static inline ren_val ren_array_get_s(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
  return ((ren_array *)a)->data[i];
}

/* Element [i], for swap.ml's take: a write puts what it's changed into
   back at [i] before anything else can see [a]. If [a] is unique, and
   its elements are counted, the element is moved out, its count left
   as it is, and a scalar, which drops ignore, left in its place, so the
   element is unique if [a] held the only reference to it, and changing
   it doesn't copy it (Lean's swap-out, `Array.modify`'s `swapAt` and
   `mapMUnsafe`'s `uset i default`, Init/Data/Array/Basic.lean:774).
   [a] is unique exactly when the write after would change it in place,
   which tests the same way ([ren_array_own]), so nothing but
   that write sees the scalar. Otherwise it's counted again, as
   [ren_array_get] does. */
static inline ren_val ren_array_take(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
  ren_val *at = &((ren_array *)a)->data[i];
  ren_val v = *at;
  if (a->objs) {
    if (__builtin_expect(ren_array_writable(a), 1))
      at->o = ren_box(0);
    else
      ren_dup(v.o);
  }
  return v;
}

/* An array of a sized type's elements: element [i] as a word, and [v],
   a word, stored at [i], at the array's width. [v] fits, since storing
   into a sized type checked that it does where it was made (eval.ml,
   [stored]). */
static inline ren_val ren_sized_load(ren_obj *a, int64_t i) {
  void *p = ((ren_array *)a)->data;
  switch (a->nfields) {
  case REN_ELEM_I8:
    return (ren_val){.i = ((int8_t *)p)[i]};
  case REN_ELEM_U8:
    return (ren_val){.i = ((uint8_t *)p)[i]};
  case REN_ELEM_I16:
    return (ren_val){.i = ((int16_t *)p)[i]};
  case REN_ELEM_U16:
    return (ren_val){.i = ((uint16_t *)p)[i]};
  case REN_ELEM_I32:
    return (ren_val){.i = ((int32_t *)p)[i]};
  case REN_ELEM_U32:
    return (ren_val){.i = ((uint32_t *)p)[i]};
  case REN_ELEM_F32:
    return (ren_val){.f = ((float *)p)[i]};
  default:
    return ((ren_val *)p)[i];
  }
}
static inline void ren_sized_store(ren_obj *a, int64_t i, ren_val v) {
  void *p = ((ren_array *)a)->data;
  switch (a->nfields) {
  case REN_ELEM_I8:
    ((int8_t *)p)[i] = (int8_t)v.i;
    break;
  case REN_ELEM_U8:
    ((uint8_t *)p)[i] = (uint8_t)v.i;
    break;
  case REN_ELEM_I16:
    ((int16_t *)p)[i] = (int16_t)v.i;
    break;
  case REN_ELEM_U16:
    ((uint16_t *)p)[i] = (uint16_t)v.i;
    break;
  case REN_ELEM_I32:
    ((int32_t *)p)[i] = (int32_t)v.i;
    break;
  case REN_ELEM_U32:
    ((uint32_t *)p)[i] = (uint32_t)v.i;
    break;
  case REN_ELEM_F32:
    ((float *)p)[i] = (float)v.f;
    break;
  default:
    ((ren_val *)p)[i] = v;
  }
}

/* Element [i] as a word, of whatever kind the array's elements are:
   what the walks read. */
static inline ren_val ren_array_load(ren_obj *a, int64_t i) {
  return a->nfields ? ren_sized_load(a, i) : ((ren_array *)a)->data[i];
}

/* [ren_array_get] and [ren_array_take] for a type variable's elements,
   whose array says how they're kept. */
static inline ren_val ren_array_get_w(ren_obj *a, int64_t i,
                                      const ren_site *site) {
  if (__builtin_expect(a->nfields != 0, 0)) {
    ren_array_check(a, i, site);
    return ren_sized_load(a, i);
  }
  return ren_array_get(a, i, site);
}
static inline ren_val ren_array_take_w(ren_obj *a, int64_t i,
                                       const ren_site *site) {
  if (__builtin_expect(a->nfields != 0, 0)) {
    ren_array_check(a, i, site);
    return ren_sized_load(a, i);
  }
  return ren_array_take(a, i, site);
}

/* A new array, [a] with element [i] replaced by [v]: the naive
   semantics, which copies. Neither argument is taken. */
ren_obj *ren_array_set(ren_obj *a, int64_t i, ren_val v, const ren_site *site);

/* `&xs.push(v)`: what [cell] holds, copied, with [v] after it, put back
   in [cell]. [v] isn't taken. */
void ren_array_push(ren_obj **cell, ren_val v);

/* What Perceus calls instead, which take the array and [v]: the array
   changed in place if it's unique, and copied first if it isn't. A
   push grows the buffer by doubling it, so pushing n elements onto a
   unique array copies O(n) of them in all. */
static inline ren_obj *ren_array_set_taking(ren_obj *a, int64_t i, ren_val v,
                                            const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  ren_val *to = ren_elems(a);
  if (a->objs)
    ren_drop(to[i].o);
  to[i] = v;
  return a;
}
static inline ren_obj *ren_array_set_taking_s(ren_obj *a, int64_t i, ren_val v,
                                              const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  ren_elems(a)[i] = v;
  return a;
}
void ren_array_push_taking(ren_obj **cell, ren_val v);

/* The same for a type variable's elements, whose array says how they're
   kept, or a sized type's, given as words; and element [i] of a new
   array written ([ren_alloc_array_d]). */
ren_obj *ren_array_set_w(ren_obj *a, int64_t i, ren_val v, const ren_site *site);
void ren_array_push_w(ren_obj **cell, ren_val v);
void ren_array_push_taking_w(ren_obj **cell, ren_val v);
static inline ren_obj *ren_array_set_taking_w(ren_obj *a, int64_t i, ren_val v,
                                              const ren_site *site) {
  if (__builtin_expect(a->nfields != 0, 0)) {
    ren_array_check(a, i, site);
    a = ren_array_own(a);
    ren_sized_store(a, i, v);
    return a;
  }
  return ren_array_set_taking(a, i, v, site);
}
static inline void ren_array_init_w(ren_obj *a, int64_t i, ren_val v) {
  if (a->nfields)
    ren_sized_store(a, i, v);
  else
    ren_elems(a)[i] = v;
}

/* An array of a sized type's elements whose type the compiler knows,
   [T] each: element [i] read, and written in place, as [ren_array_get_s]
   and [ren_array_set_taking_s] are for words. */
#define REN_SIZED_ARRAY(N, T)                                                  \
  static inline T ren_array_get_##N(ren_obj *a, int64_t i,                    \
                                    const ren_site *site) {                   \
    ren_array_check(a, i, site);                                              \
    return ((T *)((ren_array *)a)->data)[i];                                  \
  }                                                                           \
  static inline ren_obj *ren_array_set_taking_##N(ren_obj *a, int64_t i, T v, \
                                                  const ren_site *site) {     \
    ren_array_check(a, i, site);                                              \
    a = ren_array_own(a);                                                     \
    ((T *)ren_elems(a))[i] = v;                                               \
    return a;                                                                 \
  }
REN_SIZED_ARRAY(i8, int8_t)
REN_SIZED_ARRAY(u8, uint8_t)
REN_SIZED_ARRAY(i16, int16_t)
REN_SIZED_ARRAY(u16, uint16_t)
REN_SIZED_ARRAY(i32, int32_t)
REN_SIZED_ARRAY(u32, uint32_t)
REN_SIZED_ARRAY(u64, int64_t)
REN_SIZED_ARRAY(f32, float)

/* The same for an array of structs, each element [v], its words: [get]
   gives where element [i] is, which the caller copies. */
static inline ren_val *ren_array_slots(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
  return &((ren_array *)a)->data[i * ren_stride(a)];
}
static inline ren_val *ren_array_slots_k(ren_obj *a, int64_t i, int64_t k,
                                         const ren_site *site) {
  ren_array_check(a, i, site);
  return &((ren_array *)a)->data[i * k];
}
ren_obj *ren_array_set_slots(ren_obj *a, int64_t i, const ren_val *v,
                             const ren_site *site);
void ren_array_push_slots(ren_obj **cell, const ren_val *v);
static inline ren_obj *ren_array_set_slots_taking_k(ren_obj *a, int64_t i,
                                                    const ren_val *v, int64_t k,
                                                    const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  memcpy(&ren_elems(a)[i * k], v, (size_t)k * sizeof(ren_val));
  return a;
}
static inline ren_obj *ren_array_set_slots_taking(ren_obj *a, int64_t i,
                                                  const ren_val *v,
                                                  const ren_site *site) {
  return ren_array_set_slots_taking_k(a, i, v, ren_stride(a), site);
}
void ren_array_push_slots_taking(ren_obj **cell, const ren_val *v);
/* The same, of [k] words, a constant the C knows: inline when the array
   is unique, an owner and has room, which is most pushes, so the struct's
   words are stored directly and no call is made; otherwise
   [ren_array_push_slots_taking], whose cases, a copy and growing, are
   tested in the same order. Out of line, every push of a token was a
   call, a capacity test in another, and a `memcpy` of a stride read from
   the array (compiler.md, "Bytes stage", "The baseline"). */
static inline void ren_array_push_slots_taking_k(ren_obj **cell, const ren_val *v,
                                                 int64_t k) {
  ren_obj *a = *cell;
  ren_array *arr = (ren_array *)a;
  if (__builtin_expect(ren_array_unique(a) && arr->len < arr->cap, 1)) {
    memcpy(&arr->data[arr->len * k], v, (size_t)k * sizeof(ren_val));
    arr->len++;
    return;
  }
  ren_array_push_slots_taking(cell, v);
}

/* The same for an array of structs that hold objects, those in the
   slots [objs]'s mask says, which the compiler knows, so each loop over
   it unrolls: element [i] counted again where it is, for the caller to
   copy, as [ren_array_get] counts an object again; and changed in
   place, the old element's objects dropped, as [ren_array_set_taking]
   drops the old object. A copy of the array, and a push, count the
   elements by the array's own [objs], the same mask. */
static inline void ren_slots_dup(ren_val *e, uint8_t objs) {
  for (unsigned m = objs; m != 0; m &= m - 1)
    ren_dup(e[__builtin_ctz(m)].o);
}
static inline void ren_slots_drop(ren_val *e, uint8_t objs) {
  for (unsigned m = objs; m != 0; m &= m - 1)
    ren_drop(e[__builtin_ctz(m)].o);
}
static inline ren_val *ren_array_slots_dup_k(ren_obj *a, int64_t i, int64_t k,
                                             uint8_t objs,
                                             const ren_site *site) {
  ren_val *e = ren_array_slots_k(a, i, k, site);
  ren_slots_dup(e, objs);
  return e;
}
static inline ren_obj *ren_array_set_slots_taking_ko(ren_obj *a, int64_t i,
                                                     const ren_val *v,
                                                     int64_t k, uint8_t objs,
                                                     const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  ren_val *e = &ren_elems(a)[i * k];
  ren_slots_drop(e, objs);
  memcpy(e, v, (size_t)k * sizeof(ren_val));
  return a;
}

/* Field [off] of element [i] of an array of structs of [k] words
   changed to [v], the rest of the element as it was: a copy, which
   takes neither, and in place, which takes the array; [_o] for a field
   that holds an object, the old one dropped. */
ren_obj *ren_array_set_field(ren_obj *a, int64_t i, int64_t off, int64_t k,
                             ren_val v, const ren_site *site);
static inline ren_obj *ren_array_set_field_taking(ren_obj *a, int64_t i,
                                                  int64_t off, int64_t k,
                                                  ren_val v,
                                                  const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  ren_elems(a)[i * k + off] = v;
  return a;
}
static inline ren_obj *ren_array_set_field_taking_o(ren_obj *a, int64_t i,
                                                    int64_t off, int64_t k,
                                                    ren_val v,
                                                    const ren_site *site) {
  ren_array_check(a, i, site);
  a = ren_array_own(a);
  ren_val *at = &ren_elems(a)[i * k + off];
  ren_drop(at->o);
  *at = v;
  return a;
}

/* An array's elements, once a loop knows the array is unique and won't
   change its length: hoist.ml's. [p] is where the elements are and
   [len] how many, read before the loop; each access checks the index
   against [len], and the rest is a load or a store.

   They're macros, not functions, so each load and store is written in
   the function emit_c.ml moves the loop to ([outline]), whose `restrict`
   parameters [p] are: C carries `restrict` over when it inlines that
   function only to the loads and stores in it then, and a function of
   the runtime's it hasn't inlined yet would get none of it. Their
   arguments are variables and constants, so each is read once. */
static inline void ren_buf_check(int64_t len, int64_t i, const ren_site *site) {
  if (site != REN_IN_BOUNDS && __builtin_expect((uint64_t)i >= (uint64_t)len, 0))
    ren_index_panic_len(len, i, site);
}
static inline ren_val ren_dup_elem(ren_val v) {
  ren_dup(v.o);
  return v;
}
#define ren_buf_get_s(p, len, i, site) (ren_buf_check(len, i, site), (p)[i])
/* of a sized type's elements, [T] each */
#define ren_buf_get_n(T, p, len, i, site)                                      \
  (ren_buf_check(len, i, site), ((T *)(p))[i])
#define ren_buf_set_n(T, p, len, i, v, site)                                   \
  (ren_buf_check(len, i, site), (void)(((T *)(p))[i] = (v)))
#define ren_buf_get_o(p, len, i, site)                                         \
  (ren_buf_check(len, i, site), ren_dup_elem((p)[i]))
/* [ren_array_take] once the array is known unique, of objects: the
   element moved out, a scalar left in its place */
#define ren_buf_take_o(p, len, i, site)                                        \
  ({                                                                           \
    ren_buf_check(len, i, site);                                               \
    ren_val ren_taken_ = (p)[i];                                               \
    (p)[i].o = ren_box(0);                                                     \
    ren_taken_;                                                                \
  })
#define ren_buf_slots(p, len, i, k, site)                                      \
  (ren_buf_check(len, i, site), &(p)[(i) * (k)])
#define ren_buf_set_s(p, len, i, v, site)                                      \
  (ren_buf_check(len, i, site), (void)((p)[i] = (v)))
#define ren_buf_set_o(p, len, i, v, site)                                      \
  ({                                                                           \
    ren_buf_check(len, i, site);                                               \
    ren_obj *ren_old_ = (p)[i].o;                                              \
    (p)[i] = (v);                                                              \
    ren_drop(ren_old_);                                                        \
  })
#define ren_buf_set_slots(p, len, i, v, k, site)                               \
  (ren_buf_check(len, i, site),                                                \
   (void)memcpy(&(p)[(i) * (k)], (v), (size_t)(k) * sizeof(ren_val)))
#define ren_buf_set_field(p, len, i, off, k, v, site)                          \
  (ren_buf_check(len, i, site), (void)((p)[(i) * (k) + (off)] = (v)))
/* of structs that hold objects, in the slots of the mask [objs]: an
   element counted again, and one, or a field that's an object, changed,
   the old one's objects dropped */
#define ren_buf_slots_dup(p, len, i, k, objs, site)                            \
  ({                                                                           \
    ren_buf_check(len, i, site);                                               \
    ren_val *ren_at_ = &(p)[(i) * (k)];                                        \
    ren_slots_dup(ren_at_, objs);                                              \
    ren_at_;                                                                   \
  })
#define ren_buf_set_slots_o(p, len, i, v, k, objs, site)                       \
  ({                                                                           \
    ren_buf_check(len, i, site);                                               \
    ren_val *ren_at_ = &(p)[(i) * (k)];                                        \
    ren_slots_drop(ren_at_, objs);                                             \
    (void)memcpy(ren_at_, (v), (size_t)(k) * sizeof(ren_val));                 \
  })
#define ren_buf_set_field_o(p, len, i, off, k, v, site)                        \
  ({                                                                           \
    ren_buf_check(len, i, site);                                               \
    ren_obj *ren_old_ = (p)[(i) * (k) + (off)].o;                              \
    (p)[(i) * (k) + (off)] = (v);                                              \
    ren_drop(ren_old_);                                                        \
  })

/* ---- strings ---- */

ren_obj *ren_str_of(const char *s, int64_t len);
static inline int64_t ren_str_len(ren_obj *s) { return ((ren_str *)s)->len; }
static inline const char *ren_str_data(ren_obj *s) { return ((ren_str *)s)->data; }
ren_obj *ren_str_concat(ren_obj *a, ren_obj *b);
bool ren_str_eq(ren_obj *a, ren_obj *b);

/* ---- slices (foundations.md, decision 17) ----

   Each borrows what it's given and counts what it keeps, as the rest of
   the runtime's functions do. [str] says a string's slice is a `Str`'s,
   which checks it doesn't cut a character, and not `Bytes`'; both are
   [ren_str]s. The panics are the interpreter's (builtins.ml,
   [slice_value] and [split_halves]). */

/* `a[i..j]`: a slice of [a]'s root, counting it; panics if the range
   ends before it starts, isn't in [a], or cuts a `Str`'s character. */
ren_obj *ren_array_slice(ren_obj *a, int64_t i, int64_t j, const ren_site *site);
ren_obj *ren_str_slice(ren_obj *s, int64_t i, int64_t j, bool str,
                       const ren_site *site);

/* The halves of `a.split_at(n)`, `a[0..n]` and `a[n..len]`: the first
   panics if [n] isn't in [a], or cuts a `Str`'s character, which the
   second, made right after it, and given it, [lo], doesn't check again.
   An array's halves are lent if [a] can be changed in place, which its
   place, vacant meanwhile, doesn't stop (Core's [Vacant]). */
ren_obj *ren_array_before(ren_obj *a, int64_t n, const ren_site *site);
ren_obj *ren_array_after(ren_obj *a, int64_t n, ren_obj *lo);
ren_obj *ren_str_before(ren_obj *s, int64_t n, bool str, const ren_site *site);
ren_obj *ren_str_after(ren_obj *s, int64_t n);

/* [a] with its range from [i] up to [j] replaced by [b]'s elements, or
   bytes: what `&a[i..j]` writes back, a new owner; and [a] followed by
   [b], what a `split_at` writes back: if they're still next to each
   other in one root, what they're slices of, without a copy, else a new
   owner. None of them is taken. */
ren_obj *ren_array_splice(ren_obj *a, int64_t i, int64_t j, ren_obj *b);
ren_obj *ren_str_splice(ren_obj *s, int64_t i, int64_t j, ren_obj *b);
ren_obj *ren_array_join(ren_obj *a, ren_obj *b);
ren_obj *ren_str_join(ren_obj *a, ren_obj *b);

/* `s.split(sep)`, an array of slices of [s], panicking as the
   interpreter does on an empty [sep]; and `s.trim()`, a slice of [s]
   without the spaces, tabs and newlines at its ends (OCaml's
   `String.trim`, builtins.ml's). Neither checks its cuts: they're next to
   bytes it found, which no character continues. */
ren_obj *ren_str_split(ren_obj *s, ren_obj *sep, const ren_site *site);
ren_obj *ren_str_trim(ren_obj *s);

/* `s.lower()`: a new string, each ASCII letter of [s] lower case. */
ren_obj *ren_str_lower(ren_obj *s);

/* `copy()`: [a] with a buffer of its own, counted again if it already
   has one (an owner), else a copy of its range. */
ren_obj *ren_array_copied(ren_obj *a);
ren_obj *ren_str_copied(ren_obj *s);

/* `Bytes`' byte [i], 0 to 255, panicking as `b.at(i)` does if it isn't
   one, unless bounds.ml proved it is ([REN_IN_BOUNDS]). Inline, as
   [ren_array_check] is: one unsigned compare, and the message made out
   of line, in a cold function. Built in place, the panic's buffer and
   its `snprintf` came into every loop that read a byte, and with them a
   call that, as far as C knew, might change the bytes' object, so the
   loop read their length and data from it again on every byte
   (compiler.md, "Bytes stage", "The baseline"). */
__attribute__((cold, noinline)) _Noreturn void
ren_bytes_index_panic(int64_t len, int64_t i, const ren_site *site);
static inline int64_t ren_bytes_at(ren_obj *b, int64_t i, const ren_site *site) {
  if (site != REN_IN_BOUNDS &&
      __builtin_expect((uint64_t)i >= (uint64_t)ren_str_len(b), 0))
    ren_bytes_index_panic(ren_str_len(b), i, site);
  return (unsigned char)ren_str_data(b)[i];
}

/* [ren_bytes_at] of [len] bytes at [data], which hoist.ml read before a
   loop: a string's length and where its bytes are never change once
   it's made, but a loop that calls a function or stores anything would
   read them again on every pass, since C can't know that. */
static inline int64_t ren_buf_byte(const void *data, int64_t len, int64_t i,
                                   const ren_site *site) {
  if (site != REN_IN_BOUNDS && __builtin_expect((uint64_t)i >= (uint64_t)len, 0))
    ren_bytes_index_panic(len, i, site);
  return ((const unsigned char *)data)[i];
}

/* `Bytes.of(xs)`, panicking at an element that isn't a byte. */
ren_obj *ren_bytes_of(ren_obj *a, const ren_site *site);

/* What `show` makes of a scalar, as Ren writes it; a NaN can't be shown,
   and panics at [site] (nan.ml). */
ren_obj *ren_show_int(int64_t n);
ren_obj *ren_show_float(double f, const ren_site *site);
ren_obj *ren_show_bool(bool b);

/* [f] as Ren writes it, into [buf] (at least 400 bytes): the fewest
   digits that read back as [f], with no exponent (token.ml,
   `show_float`). */
void ren_format_float(char *buf, double f);

/* A `Str` as it's written in source, in quotes, with its escapes, to
   [out]: how `ren run` prints a `main` that gives one. */
#ifndef REN_UNIT
void ren_print_quoted(FILE *out, ren_obj *s);
#endif

/* ---- arithmetic ----

   An `Int` that overflows panics, with the interpreter's message
   (lib/eval/arith.ml), where it happens (foundations.md, decision 15).
   A `Float` operation that has no answer
   gives a NaN, which panics where it's observed ("NaN", below). */

_Noreturn void ren_int_overflowed(const ren_site *site, const char *op,
                                  int64_t a, int64_t b);

/* An `Int` or a `Float` stored into a sized type (sized.ml): checked
   that it fits, panicking with the interpreter's message (eval.ml,
   [stored]) if it doesn't, then kept at the type's width. A `Float`
   that's finite has to stay finite as a `Float32`: it does if it's less
   than halfway from `Float32`'s largest to the next power of two,
   2^128 - 2^103, since it rounds to the nearest. That's checked before
   converting, since converting a `double` outside `float`'s range is
   undefined in C. */
_Noreturn void ren_narrow_panic(const ren_site *site, uint8_t kind, ren_val v);
#define REN_NARROW(N, T, KIND, LO, HI)                                         \
  static inline T ren_narrow_##N(int64_t x, const ren_site *site) {           \
    if (__builtin_expect(x < (LO) || x > (HI), 0))                            \
      ren_narrow_panic(site, KIND, (ren_val){.i = x});                        \
    return (T)x;                                                              \
  }
REN_NARROW(i8, int8_t, REN_ELEM_I8, INT8_MIN, INT8_MAX)
REN_NARROW(u8, uint8_t, REN_ELEM_U8, 0, UINT8_MAX)
REN_NARROW(i16, int16_t, REN_ELEM_I16, INT16_MIN, INT16_MAX)
REN_NARROW(u16, uint16_t, REN_ELEM_U16, 0, UINT16_MAX)
REN_NARROW(i32, int32_t, REN_ELEM_I32, INT32_MIN, INT32_MAX)
REN_NARROW(u32, uint32_t, REN_ELEM_U32, 0, UINT32_MAX)
REN_NARROW(u64, int64_t, REN_ELEM_U64, 0, INT64_MAX)
static inline float ren_narrow_f32(double x, const ren_site *site) {
  if (__builtin_expect(fabs(x) >= 0x1.ffffffp127 && fabs(x) != INFINITY, 0))
    ren_narrow_panic(site, REN_ELEM_F32, (ren_val){.f = x});
  return (float)x;
}

/* What a release build marks the prelude's small functions with, so C
   inlines them wherever they're called (emit_c.ml, [small_prelude]). */
#define REN_INLINE inline __attribute__((always_inline))

/* ---- layer 3: reads and writes at an offset (formats.md; compiler.md,
   "Bytes stage", "Layer 3: the API") ----

   Each is given its width in bytes, whether it's signed and whether it's
   big-endian as constants the C emitter writes, so clang folds the
   switches away: a read is a bounds check, an unaligned load (`memcpy`
   of the width, one `ldr`) and for `be` a byte swap, as Rust's
   `from_le_bytes` and Go's `binary.LittleEndian` are. The machine is
   little-endian (arm64, x86-64). Out of range panics as the interpreter
   does (builtins.ml, [room]), the message made out of line. */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error "the runtime's layer 3 reads assume a little-endian machine"
#endif

__attribute__((cold, noinline)) _Noreturn void
ren_bytes_range_panic(int64_t len, int64_t at, int width, const ren_site *site);
__attribute__((cold, noinline)) _Noreturn void
ren_bytes_u64_panic(int64_t at, uint64_t x, bool big, const ren_site *site);
__attribute__((cold, noinline)) _Noreturn void
ren_varuint_panic(int64_t x, const ren_site *site);

/* Panics unless [width] bytes at [at] are in [len]: [at] in 0 to [len]
   first, so [len - at] can't overflow, and a huge [at] can't wrap round
   to a small one. */
static inline void ren_bytes_room(int64_t len, int64_t at, int width,
                                  const ren_site *site) {
  if (__builtin_expect((uint64_t)at > (uint64_t)len || len - at < width, 0))
    ren_bytes_range_panic(len, at, width, site);
}

static inline uint64_t ren_bswap(uint64_t x, int width) {
#if defined(__GNUC__) && !defined(__TINYC__)
  switch (width) {
  case 2:
    return __builtin_bswap16((uint16_t)x);
  case 4:
    return __builtin_bswap32((uint32_t)x);
  default:
    return __builtin_bswap64(x);
  }
#else
  uint64_t r = 0;
  for (int i = 0; i < width; i++)
    r |= ((x >> (8 * i)) & 0xff) << (8 * (width - 1 - i));
  return r;
#endif
}

/* The number at [at] of [b]: `b.u8(at)` to `b.i64_be(at)`; a `u64`'s
   is an `i64`'s, then [ren_u64_read]. */
static inline int64_t ren_bytes_load(ren_obj *b, int64_t at, int width, bool sgn,
                                     bool big, const ren_site *site) {
  ren_bytes_room(ren_str_len(b), at, width, site);
  const char *p = ren_str_data(b) + at;
  switch (width) {
  case 1: {
    uint8_t v = (uint8_t)p[0];
    return sgn ? (int64_t)(int8_t)v : (int64_t)v;
  }
  case 2: {
    uint16_t v;
    memcpy(&v, p, 2);
    if (big)
      v = (uint16_t)ren_bswap(v, 2);
    return sgn ? (int64_t)(int16_t)v : (int64_t)v;
  }
  case 4: {
    uint32_t v;
    memcpy(&v, p, 4);
    if (big)
      v = (uint32_t)ren_bswap(v, 4);
    return sgn ? (int64_t)(int32_t)v : (int64_t)v;
  }
  default: {
    uint64_t v;
    memcpy(&v, p, 8);
    if (big)
      v = ren_bswap(v, 8);
    return (int64_t)v;
  }
  }
}

/* [x], the bits a `u64_le` (or `_be`) read at [at], which panics if
   they're 2^63 or more, no `Int`. */
static inline int64_t ren_u64_read(int64_t x, int64_t at, bool big,
                                   const ren_site *site) {
  if (__builtin_expect(x < 0, 0))
    ren_bytes_u64_panic(at, (uint64_t)x, big, site);
  return x;
}

/* Panics unless [x] fits a write of [width] bytes, as storing it into the
   sized type of that width does (sized.ml): an `i64` takes any `Int`. */
static inline void ren_bytes_fits(int64_t x, int width, bool sgn,
                                  const ren_site *site) {
  switch (width) {
  case 1:
    sgn ? (void)ren_narrow_i8(x, site) : (void)ren_narrow_u8(x, site);
    break;
  case 2:
    sgn ? (void)ren_narrow_i16(x, site) : (void)ren_narrow_u16(x, site);
    break;
  case 4:
    sgn ? (void)ren_narrow_i32(x, site) : (void)ren_narrow_u32(x, site);
    break;
  default:
    if (!sgn)
      (void)ren_narrow_u64(x, site);
  }
}

/* [*cell]'s bytes, a copy of them put in the cell first unless they can
   be written in place ([taking], and unique and an owner: a slice's
   bytes are its root's, and a literal's, whose count is 0, are never
   unique), so writing one leaves every other value as it was. */
ren_obj *ren_bytes_unshare(ren_obj *b);
static inline char *ren_bytes_writable(ren_obj **cell, bool taking) {
  ren_obj *b = *cell;
  if (!taking ||
      __builtin_expect(!(ren_rc(b) == 1 && ((ren_str *)b)->root == NULL), 0))
    *cell = b = ren_bytes_unshare(b);
  return ((ren_str *)b)->bytes;
}

/* `&b.set_u8(at, x)` to `&b.set_i64_be(at, x)`: the value checked, then
   the offset, as the interpreter does (builtins.ml, [write_at]). */
static inline void ren_bytes_store(ren_obj **cell, int64_t at, int64_t x, int width,
                                   bool sgn, bool big, bool taking,
                                   const ren_site *site) {
  ren_bytes_fits(x, width, sgn, site);
  ren_bytes_room(ren_str_len(*cell), at, width, site);
  char *p = ren_bytes_writable(cell, taking) + at;
  uint64_t v = (uint64_t)x;
  switch (width) {
  case 1:
    p[0] = (char)(uint8_t)v;
    break;
  case 2: {
    uint16_t w = (uint16_t)(big ? ren_bswap(v, 2) : v);
    memcpy(p, &w, 2);
    break;
  }
  case 4: {
    uint32_t w = (uint32_t)(big ? ren_bswap(v, 4) : v);
    memcpy(p, &w, 4);
    break;
  }
  default: {
    uint64_t w = big ? ren_bswap(v, 8) : v;
    memcpy(p, &w, 8);
  }
  }
}

/* The bits a `VarInt` ([sgn], zigzag) or a `VarUInt` of [x] is, the
   latter panicking if [x] is negative; and how many bytes LEB128 writes
   them in, 7 bits a byte, 1 to 10. */
static inline uint64_t ren_var_bits(int64_t x, bool sgn, const ren_site *site) {
  if (sgn)
    return ((uint64_t)x << 1) ^ (uint64_t)(x >> 63);
  if (__builtin_expect(x < 0, 0))
    ren_varuint_panic(x, site);
  return (uint64_t)x;
}
static inline int ren_var_len(uint64_t z) {
  int n = 1;
  while (z >= 0x80) {
    z >>= 7;
    n++;
  }
  return n;
}
static inline int64_t ren_var_size(int64_t x, bool sgn, const ren_site *site) {
  return ren_var_len(ren_var_bits(x, sgn, site));
}

/* `&b.set_varuint(at, x)` and `&b.set_varint(at, x)`: how many bytes
   they wrote. */
static inline int64_t ren_bytes_set_var(ren_obj **cell, int64_t at, int64_t x,
                                        bool sgn, bool taking,
                                        const ren_site *site) {
  uint64_t z = ren_var_bits(x, sgn, site);
  int n = ren_var_len(z);
  ren_bytes_room(ren_str_len(*cell), at, n, site);
  unsigned char *p = (unsigned char *)ren_bytes_writable(cell, taking) + at;
  for (int i = 0; i < n - 1; i++) {
    p[i] = (unsigned char)(z | 0x80);
    z >>= 7;
  }
  p[n - 1] = (unsigned char)z;
  return n;
}

/* Whether [s]'s bytes are UTF-8: no overlong form, no surrogate, nothing
   past U+10FFFF, as OCaml's `String.is_valid_utf_8` says. */
bool ren_utf8_valid(ren_obj *s);

/* `Bytes.zeros(n)`, panicking if [n] is negative. */
ren_obj *ren_bytes_zeros(int64_t n, const ren_site *site);

/* [a op b], wrapped, into [*r], and whether it overflowed: clang's and
   GCC's builtins, or for tcc, which has none, two's-complement tests
   that give the same answers. A sum overflowed if both operands' signs
   differ from its sign, a difference if [a]'s differs from [b]'s and
   from the difference's (Hacker's Delight, 2-13). A product overflowed
   if dividing it by [b] doesn't give [a] back, but for the one division
   that itself overflows. Measured under tcc on an M4, that division
   costs nothing over a loop's other work; a check without it, of four
   32-bit products (Hacker's Delight, 8-2, [mulhs]) behind a test for
   operands that fit in 32 bits, was up to 1.9 times slower. */
#ifdef __TINYC__
static inline bool ren_add_overflow(int64_t a, int64_t b, int64_t *r) {
  int64_t s = (int64_t)((uint64_t)a + (uint64_t)b);
  *r = s;
  return ((a ^ s) & (b ^ s)) < 0;
}
static inline bool ren_sub_overflow(int64_t a, int64_t b, int64_t *r) {
  int64_t s = (int64_t)((uint64_t)a - (uint64_t)b);
  *r = s;
  return ((a ^ b) & (a ^ s)) < 0;
}
static inline bool ren_mul_overflow(int64_t a, int64_t b, int64_t *r) {
  int64_t s = (int64_t)((uint64_t)a * (uint64_t)b);
  *r = s;
  if (b == 0)
    return false;
  if (b == -1)
    return a == INT64_MIN;
  return s / b != a;
}
#else
#define ren_add_overflow(a, b, r) __builtin_add_overflow(a, b, r)
#define ren_sub_overflow(a, b, r) __builtin_sub_overflow(a, b, r)
#define ren_mul_overflow(a, b, r) __builtin_mul_overflow(a, b, r)
#endif

static inline int64_t ren_add(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (ren_add_overflow(a, b, &r))
    ren_int_overflowed(site, "+", a, b);
  return r;
}

static inline int64_t ren_sub(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (ren_sub_overflow(a, b, &r))
    ren_int_overflowed(site, "-", a, b);
  return r;
}

static inline int64_t ren_mul(int64_t a, int64_t b, const ren_site *site) {
  int64_t r;
  if (ren_mul_overflow(a, b, &r))
    ren_int_overflowed(site, "*", a, b);
  return r;
}

/* `Int`'s shifts (foundations.md, decision 15): `shl` loses the bits
   shifted out, as a shift of the `uint64_t` does, and `shr` is
   arithmetic. C leaves a negative signed `>>` to the implementation
   (C11 6.5.7p5); clang, GCC and tcc each define it as arithmetic, which
   the assertion below checks of whichever compiles this, so `>>` is one
   `asr`. Written without it, `x < 0 ? ~(~x >> k) : x >> k`, clang 16
   doesn't fold it back to one: five instructions. An amount outside 0
   to 63 panics with the interpreter's message (lib/eval/builtins.ml,
   [shift]): one unsigned compare, gone when [k] is a constant. */
_Static_assert(((int64_t)-1 >> 1) == -1, "`shr` needs an arithmetic `>>`");
_Noreturn void ren_shift_panic(const ren_site *site, const char *op,
                               int64_t k);

static inline int64_t ren_shl(int64_t x, int64_t k, const ren_site *site) {
  if (__builtin_expect((uint64_t)k > 63, 0))
    ren_shift_panic(site, "shl", k);
  return (int64_t)((uint64_t)x << k);
}

static inline int64_t ren_shr(int64_t x, int64_t k, const ren_site *site) {
  if (__builtin_expect((uint64_t)k > 63, 0))
    ren_shift_panic(site, "shr", k);
  return x >> k;
}

int64_t ren_div(int64_t a, int64_t b, const ren_site *site);
int64_t ren_rem(int64_t a, int64_t b, const ren_site *site);
int64_t ren_neg(int64_t a, const ren_site *site);

/* `Float`'s methods that can panic: a rounding that isn't an `Int`, a
   NaN's or one too big (lib/eval/builtins.ml). */
int64_t ren_fround(double a, const ren_site *site);
int64_t ren_ftruncate(double a, const ren_site *site);

/* ---- NaN (lib/core/nan.ml) ----

   Arithmetic and stores carry a NaN; comparing one, showing one,
   rounding one to an `Int` or giving one to a dependency's operation
   panics, at the same places in every build and in the interpreter. A
   debug build also says where it was made: an operation that makes one
   from operands that aren't puts a tag in its payload, bits 29 to 50,
   which survive a `Float32`, and [ren_nan_where] says where each tag is,
   "at x.ren:3:9". A release build makes no tags, and its table is NULL,
   so it says nothing more. Each operation given NaNs gives the first,
   as nan.ml's [carried] says, not as the machine would. */

extern const char *const *ren_nan_where;
extern int32_t ren_nan_nwhere;

static inline double ren_nan_tagged(uint32_t tag) {
  uint64_t bits = UINT64_C(0x7FF8000000000000) | ((uint64_t)tag << 29);
  double d;
  memcpy(&d, &bits, sizeof d);
  return d;
}

/* [r], what an operation on [a] and [b] gave, as nan.ml's [carried]. */
static inline double ren_fmade(double r, double a, double b, uint32_t tag) {
  if (__builtin_expect(isnan(r), 0))
    return isnan(a) ? a : isnan(b) ? b : ren_nan_tagged(tag);
  return r;
}

/* A debug build's `Float` operations, which tag a NaN they make; a
   release build's are C's own. */
static inline double ren_fadd_d(double a, double b, uint32_t tag) {
  return ren_fmade(a + b, a, b, tag);
}
static inline double ren_fsub_d(double a, double b, uint32_t tag) {
  return ren_fmade(a - b, a, b, tag);
}
static inline double ren_fmul_d(double a, double b, uint32_t tag) {
  return ren_fmade(a * b, a, b, tag);
}
static inline double ren_fdiv_d(double a, double b, uint32_t tag) {
  return ren_fmade(a / b, a, b, tag);
}
static inline double ren_frem_d(double a, double b, uint32_t tag) {
  return ren_fmade(fmod(a, b), a, b, tag);
}
static inline double ren_fsqrt_d(double a, uint32_t tag) {
  return ren_fmade(sqrt(a), a, a, tag);
}

/* [what] observed the NaN [f], at [site]: the panic, with where [f] was
   made if a debug build's tag says. */
_Noreturn void ren_nan_panic(const ren_site *site, const char *what, double f);

/* Panics if [a] or [b] is a NaN, the first that is: a comparison's
   check, or, given one twice, a value's. */
static inline void ren_nan_check(double a, double b, const char *what,
                                 const ren_site *site) {
  if (__builtin_expect(isnan(a) || isnan(b), 0))
    ren_nan_panic(site, what, isnan(a) ? a : b);
}

/* `sum` of an array of `Float`s (prelude.ml, [float_sum]): element i
   into lane i % 8, each from 0.0, then the lanes pairwise,
   ((0 + 1) + (2 + 3)) + ((4 + 5) + (6 + 7)). A release build's, [tag]
   0, adds eight at a time, which the compiler makes vector additions;
   a debug build's carries NaNs one addition at a time, as the
   interpreter does, and the two give the same number. */
static inline double ren_float_sum(ren_obj *xs, uint32_t tag) {
  const ren_val *e = (const ren_val *)ren_elems(xs);
  int64_t n = ((ren_array *)xs)->len, i = 0;
  double l[8] = {0, 0, 0, 0, 0, 0, 0, 0};
  if (tag == 0) {
    for (; i + 8 <= n; i += 8)
      for (int k = 0; k < 8; k++)
        l[k] += e[i + k].f;
    for (int k = 0; i < n; i++, k++)
      l[k] += e[i].f;
    return ((l[0] + l[1]) + (l[2] + l[3])) + ((l[4] + l[5]) + (l[6] + l[7]));
  }
  for (; i < n; i++)
    l[i % 8] = ren_fadd_d(l[i % 8], e[i].f, tag);
  return ren_fadd_d(
      ren_fadd_d(ren_fadd_d(l[0], l[1], tag), ren_fadd_d(l[2], l[3], tag), tag),
      ren_fadd_d(ren_fadd_d(l[4], l[5], tag), ren_fadd_d(l[6], l[7], tag), tag),
      tag);
}

/* ---- descriptors ----

   A type as the running program knows it (Core's `desc`): what a generic
   function is given for each of its type variables, and what an error
   keeps of its payload's types. A dictionary is one too: the descriptor
   of the type it's for, since every requirement the slice has, `==`,
   ordering, an operator, `zero` and `one`, is found by walking the type
   (walk.ml), and which requirement is known where it's used.

   A descriptor is an object, so it can be counted. One the compiler
   knows, a type with none of a function's type variables in it, is
   static data whose count is 0, never freed; one built from a
   function's own, `Option<T>`, is made where it's passed. A named type's
   fields are described by templates, static descriptors that name its
   parameters ([REN_D_VAR]), each read under the arguments it's given
   ([ren_tenv]), so walking a value never builds a descriptor. */

enum {
  REN_D_INT,
  REN_D_FLOAT,
  REN_D_BOOL,
  REN_D_UNIT,
  REN_D_STR,
  REN_D_NAMED,   /* a record, a sum or an opaque type: [decl], given [args] */
  REN_D_ARRAY,   /* [args][0]'s */
  REN_D_TUPLE,   /* of [args] */
  REN_D_ERRORS,  /* an error, which keeps its payload's own */
  REN_D_VAR,     /* in a template: the parameter [var] */
  REN_D_UNKNOWN, /* a type variable nothing decided: no value has it */
  REN_D_SIZED,   /* a sized type's, [var] its kind, [REN_ELEM_U8]... */
  REN_D_HANDLER, /* a handler's description, an object nothing looks into */
  REN_D_BYTES,   /* `Bytes`, a string the walk shows each byte of */
  REN_D_MAP,     /* a `Map` of [args][0]'s to [args][1]'s */
  REN_D_SET,     /* a `Set` of [args][0]'s */
};

struct ren_decl;

typedef struct ren_desc {
  ren_obj h;
  uint8_t kind;
  uint8_t counted; /* whether a value of it is an object */
  uint16_t nargs;
  int32_t var;
  const struct ren_decl *decl;
  struct ren_desc *const *args;
} ren_desc;

/* A constructor, or a record's fields, as declared: each field's type is
   a template over the type's parameters. [at] says where each field is
   kept, if the type packs its small scalars (to_mem.ml, [pack]): the
   word's number shifted left 16, the bit it starts at shifted left 8,
   and how many bits, 64 for a word of its own. NULL: field i is word i. */
typedef struct {
  const char *name;
  int32_t nfields;
  const char *const *fields; /* a record's field names, or a by-name
                                constructor's; NULL for a positional one */
  ren_desc *const *types;
  const uint32_t *at;
} ren_ctor_info;

/* The same as [ren_alloc_array] and [ren_array_reserve] for a type
   variable's elements, described by [d]: kept at a sized type's width
   if it's one. */
ren_obj *ren_alloc_array_d(int64_t len, ren_obj *d);
ren_obj *ren_array_reserve_d(int64_t cap, ren_obj *d);

enum { REN_DECL_RECORD, REN_DECL_SUM, REN_DECL_REP };

/* A type's `key` (operators.md, "`key`"), which `==`, ordering and
   `hash` go through: [key] of a value, a word it borrows, is its key, a
   word the caller owns, of the type [keyd] describes. The program's
   code, given the type's values as words (emit_c.ml, [key_wrapper]). */
typedef ren_val (*ren_key_fn)(ren_val v);

typedef struct ren_decl {
  const char *name;
  uint8_t kind;
  uint8_t opaque;   /* declared `opaque`, shown as `Name(...)` */
  uint8_t enumlike; /* a sum none of whose constructors has fields */
  int32_t nctors;
  const ren_ctor_info *ctors; /* a record's one, or a sum's, by tag */
  ren_desc *rep;              /* an opaque type's representation */
  ren_key_fn key;             /* its own `key`, or NULL */
  ren_desc *keyd;             /* what [key] gives */
} ren_decl;

/* The kind of a sized type [d] describes, [REN_ELEM_U8] and the rest,
   looking through what an opaque type is represented as; 0 for any other
   type, whose values are words. How an array of them keeps its elements.
   [d] is a type's, never a template. */
static inline uint8_t ren_desc_elem(ren_obj *o) {
  const ren_desc *d = (const ren_desc *)o;
  while (d->kind == REN_D_NAMED && d->decl->kind == REN_DECL_REP) {
    const ren_desc *r = d->decl->rep;
    d = r->kind == REN_D_VAR ? d->args[r->var] : r;
  }
  return d->kind == REN_D_SIZED ? (uint8_t)d->var : 0;
}

/* Field [i] of [o], a constructor or a record of [c], as a word: a packed
   one's bits, unsigned, or the number a sized type's are. [c] NULL is a
   tuple's, never packed. */
static inline ren_val ren_ctor_field(ren_obj *o, const ren_ctor_info *c,
                                     int32_t i) {
  if (c == NULL || c->at == NULL)
    return ren_fields(o)[i];
  uint32_t at = c->at[i], bits = at & 0xFF;
  ren_val v = ren_fields(o)[at >> 16];
  if (bits < 64) {
    v.i = (int64_t)(((uint64_t)v.i >> ((at >> 8) & 0xFF)) &
                    ((UINT64_C(1) << bits) - 1));
    uint8_t kind = ren_desc_elem((ren_obj *)c->types[i]);
    if (kind)
      v = ren_sized_word(kind, (uint64_t)v.i);
  }
  return v;
}

/* The arguments a template is read under: [args] for its [REN_D_VAR]s,
   each of which is read under [up]. */
typedef struct ren_tenv {
  ren_desc *const *args;
  const struct ren_tenv *up;
} ren_tenv;

/* A descriptor of [decl] given [args], or of an array or a tuple
   ([kind]), which keeps the arguments; it's counted. */
ren_obj *ren_desc_new(uint8_t kind, const ren_decl *decl, int64_t nargs,
                      ren_obj *const *args);

static inline bool ren_desc_counted(ren_obj *d) {
  return ((ren_desc *)d)->counted;
}

/* A value of a type variable, counted through its descriptor. */
static inline void ren_dup_val(ren_val v, ren_obj *d) {
  if (ren_desc_counted(d))
    ren_dup(v.o);
}
static inline void ren_drop_val(ren_val v, ren_obj *d) {
  if (ren_desc_counted(d))
    ren_drop(v.o);
}

/* The names of the error tags, by number, which the program sets. */
extern const char *const *ren_tag_names;

/* What `main` failed with, as `ren run` says it, to stderr, then the end
   of the program, with exit code 1. */
_Noreturn void ren_uncaught(ren_obj *e);

/* `show` of [v], a value of the type [d] describes, as shown.ml shows
   it: a `Str` is itself. Through a type's own `show` the walk never
   goes: a type that has one isn't in the native slice yet. A `key` is
   for `==`, ordering and hashing, never `show`. */
ren_obj *ren_show_any(ren_obj *d, ren_val v, const ren_site *site);

/* [v] as it's written, a `Str` in quotes: how `ren run` prints what
   `main` gives, or an error nothing handled; a NaN in it panics at
   [site]. */
#ifndef REN_UNIT
void ren_print_value(FILE *out, ren_obj *d, ren_val v, const ren_site *site);
#endif

/* What `main` gave, [v] of [d]'s type, printed to stdout as
   [ren_print_value] prints it, and a newline. */
void ren_print_result(ren_obj *d, ren_val v, const ren_site *site);

/* `==` on two values of [d]'s type, and their order: negative if [a]
   comes first (walk.ml, `equal` and `compare`). A NaN in either panics
   at [site], saying [what] compared it. */
bool ren_equal_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                   const ren_site *site);
int64_t ren_compare_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                        const ren_site *site);

/* `xs.sort()`: a new array of [a]'s elements, of [d]'s type, by its
   order, a merge sort, which keeps equal ones in the order they were, as
   walk.ml's [List.stable_sort] does. A NaN compared panics at [site],
   saying [what] compared it. */
ren_obj *ren_array_sort(ren_obj *a, ren_obj *d, const char *what,
                        const ren_site *site);

/* Panics at [site] if a NaN is anywhere in [v], of [d]'s type, saying
   [what] was given it (walk.ml, [nan_in]). */
void ren_nan_in(ren_obj *d, ren_val v, const char *what, const ren_site *site);

/* Whether [d] describes `Float`, whose `sum` adds in lanes. */
static inline bool ren_desc_is_float(ren_obj *d) {
  return ((ren_desc *)d)->kind == REN_D_FLOAT;
}

/* An operator, by its requirement, on values of [d]'s type, an `Int`, a
   `Float` or one represented as either, and `zero` and `one`. */
enum { REN_OP_ADD, REN_OP_SUB, REN_OP_MUL, REN_OP_DIV, REN_OP_REM, REN_OP_NEG };
ren_val ren_op_any(ren_obj *d, int op, ren_val a, ren_val b,
                   const ren_site *site, uint32_t tag);
ren_val ren_value_any(ren_obj *d, bool one);

/* ---- maps and sets (compiler.md, "Bytes stage", "`Map` and `Set`
   natively") ----

   Python's dict and Rust's indexmap: a dense array of entries in the
   order each key was first set, and an index of where each is, found by
   the key's hash. An entry is its hash, its key and, a map's, its value,
   each a word, counted through the map's [objs]; a removed one's hash is
   0, which no live one's is, and its key and value are gone. The index
   has 2^[shift] slots, each an entry's number, [REN_MAP_EMPTY], or
   [REN_MAP_GONE] for a removed one's, probed linearly from the hash's
   top bits, and never more than 2/3 full, removed ones included, since
   [used] counts them. When the entries are full they're compacted, if
   a third or more are removed, keeping their order, or else doubled,
   and the index is made again from the hashes they keep.

   A map is a value, as an array is (rule U): a change is in place only
   when nothing else holds it, and otherwise to a copy, which is put
   back in the variable's cell. A loop over a map goes over the array
   its entries were copied into ([ren_map_entries]), so what its body
   sets or removes changes nothing it goes over.

   The hash a map keeps is seeded ([ren_map_seed]): which keys share one
   changes from run to run, so keys can't be chosen ahead of time to
   collide, as Go's maps do. Nothing a program sees depends on it, since
   entries are in the order they were set. `x.hash()` is another walk,
   with no seed ([ren_hash_fixed]). */

typedef struct {
  ren_obj h;      /* [objs]: 1 if keys are objects, 2 if values are;
                     [nfields]: 1 for a `Set`, whose entries have no value */
  int64_t len;    /* live entries */
  int64_t used;   /* entries used, removed ones included */
  int64_t cap;    /* room for entries */
  int32_t shift;  /* the index has 1 << shift slots, or none if 0 */
  int32_t width;  /* words an entry: 3, or 2 for a set's */
  ren_val *entries;
  int32_t *index;
} ren_map;

enum { REN_MAP_EMPTY = -1, REN_MAP_GONE = -2 };

/* What every map's hash is mixed with, drawn when the program starts. */
extern uint64_t ren_map_seed;

/* A new empty map, or set if [set]: `Map.empty`. */
ren_obj *ren_map_new(bool set);

static inline int64_t ren_map_len(ren_obj *m) { return ((ren_map *)m)->len; }

/* The number of the entry whose key is [k], of the type [kd] describes,
   or -1. A NaN in [k] panics at [site], as hashing one does. */
int64_t ren_map_find(ren_obj *m, ren_val k, ren_obj *kd, const ren_site *site);

/* Entry [i]'s value, counted again: [i] is one [ren_map_find] gave. */
static inline ren_val ren_map_value(ren_obj *m, int64_t i) {
  ren_map *map = (ren_map *)m;
  ren_val v = map->entries[i * map->width + 2];
  if (m->objs & 2)
    ren_dup(v.o);
  return v;
}

/* `&m.set(k, v)`, of keys and values [kd] and [vd] describe, and a
   set's `&s.add(k)` with [vd] NULL: in place if [taking] and the map is
   unique, taking [k] and [v], and otherwise into a copy put back in the
   cell, counting them again. A key that's there keeps its place and its
   first key, and gets [v]. */
void ren_map_set(ren_obj **cell, ren_val k, ren_val v, ren_obj *kd,
                 ren_obj *vd, bool taking, const ren_site *site);

/* `&m.remove(k)`, the same way, which borrows [k]: removing a key
   that isn't there changes nothing, and copies nothing. */
void ren_map_remove(ren_obj **cell, ren_val k, ren_obj *kd, bool taking,
                    const ren_site *site);

/* `Map.of(pairs)`, an array of tuples, each its own object or, with
   [flat], two words in the array (a release build's struct); or
   `Set.of(xs)` if [vd] is NULL. */
ren_obj *ren_map_of(ren_obj *pairs, ren_obj *kd, ren_obj *vd, bool flat,
                    const ren_site *site);

/* A map's keys and values, in order, as an array of tuples, each its own
   object or, with [flat], two words in the array: what a `for` goes
   over. */
ren_obj *ren_map_entries(ren_obj *m, bool flat);

/* Its keys, or a set's members, or a map's values, in order, as an array
   of elements [d] describes. */
ren_obj *ren_map_keys(ren_obj *m, ren_obj *d);
ren_obj *ren_map_values(ren_obj *m, ren_obj *d);

/* `x.hash()` of [v], of the type [d] describes: walk.ml's [fixed_hash],
   the same bits. A NaN in it panics at [site]. */
int64_t ren_hash_fixed(ren_obj *d, ren_val v, const ren_site *site);

/* ---- blocks and evidence ----

   A block is a pair of words passed by value: its code, and its
   environment, an array on the stack of the function it's written in
   holding the address of each local it captures. Calling one is an
   indirect call, and nothing is allocated (foundations.md, decisions 1
   and 13). Every block's code has one signature: its environment, the
   evidence of its caller, its arguments as words, and where its value
   goes; it returns its error, or NULL.

   Evidence is a chain of nodes, each a dependency's number and the
   implementation of it installed there, after Koka's evidence vectors
   (std/core/hnd.kk, the `Ev` record), kept on the stack of whatever
   installed it. An implementation is a record of blocks, one for each
   operation, whose environments hold the evidence the handler was
   installed with, so `next` and the handler's own calls find theirs.

   A generic dependency's node keeps the descriptors of its type
   arguments too, `Chan<Job>`'s `Job`, so `Chan<Job>` and `Chan<Int>`,
   installed together, are found apart (foundations.md, decisions 5 and
   6); a dependency that isn't generic has none. */

typedef struct ren_ev ren_ev;
typedef ren_obj *(*ren_code)(void *env, const ren_ev *ev, void *args,
                             ren_val *out);
typedef struct {
  ren_code code;
  void *env;
} ren_block;

typedef struct {
  int32_t dep;
  int32_t nops;
  const ren_block *ops;
} ren_impl;

struct ren_ev {
  int32_t dep;
  int32_t nargs;
  ren_obj *const *args; /* its type arguments' descriptors */
  const ren_impl *impl;
  const ren_ev *next;
};

/* A dependency a `with` installs, or a block is given: its number and
   its type arguments' descriptors. [from] is the number of the
   dependency the implementation installed for it implements: [dep]
   itself, or the one an alias names (`with queue() as Jobs`). */
typedef struct {
  int32_t dep;
  int32_t from;
  int32_t nargs;
  ren_obj *const *args;
} ren_key;

/* The innermost implementation of [dep], one that isn't generic: typing
   makes sure there's one. */
static inline const ren_impl *ren_find(const ren_ev *ev, int32_t dep) {
  while (ev->dep != dep)
    ev = ev->next;
  return ev->impl;
}

/* Whether two descriptors describe the same type. */
bool ren_desc_same(const ren_desc *a, const ren_desc *b);

/* The innermost implementation of the generic [dep] at the type
   arguments [args] describe. */
static inline const ren_impl *ren_find_args(const ren_ev *ev, int32_t dep,
                                            ren_obj *const *args, int nargs) {
  for (;; ev = ev->next) {
    if (ev->dep != dep || ev->nargs != nargs)
      continue;
    int i = 0;
    while (i < nargs && ren_desc_same((const ren_desc *)ev->args[i],
                                      (const ren_desc *)args[i]))
      i++;
    if (i == nargs)
      return ev->impl;
  }
}

/* [outer] with each of the keys [deps] installed on top, its
   implementation the one of [impls] for its [from], in [nodes]: a
   `with` installing a handler's instance. */
const ren_ev *ren_install(ren_ev *nodes, const ren_ev *outer, void *deps,
                          int64_t ndeps, const ren_impl *const *impls,
                          int nimpls);

/* [outer] with the implementations of the keys [deps] its caller has, in
   [from], on top, in [nodes]: what a block's parameter's type lists,
   which its callee provides (foundations.md, decision 5). */
const ren_ev *ren_given(ren_ev *nodes, const ren_ev *outer, const ren_ev *from,
                        const ren_key *deps, int n);

/* A handler's description is an object: its tag, then what it
   captured. The tag finds the handler's static record ([ren_handler]),
   which holds its code: [install] makes the handler's state as its own
   locals, makes its instance, installs it on [outer] for [deps], calls
   [body] with that evidence, and runs its `finally` with the outcome,
   given [body_desc], the descriptor of what [body] gives. */
typedef ren_obj *(*ren_hcode)(ren_obj *self, const ren_ev *outer,
                              ren_block body, ren_obj *body_desc, void *deps,
                              int64_t ndeps, ren_val *out);

/* An operation of a stateless handler called as a method, `d.op(x)`
   (compiler.md, "Descriptions (step 3)"): a block's code, which takes the
   description as its first word, then the operation's arguments, and
   runs the arm with the caller's evidence, making no instance. */
typedef struct {
  int32_t dep;
  int32_t op;
  ren_code code;
} ren_method;

/* A handler's static record, which a debug build's tag points at, and
   a release build's indexes in the program's table: its number, its
   name, how many words its description holds after the tag, the code
   that installs it, and its methods, if it's stateless. */
typedef struct {
  int32_t id;
  int32_t nwords;
  const char *name;
  ren_hcode install;
  int32_t nmethods;
  const ren_method *methods;
} ren_handler;

/* The code of [h]'s operation [op] of [dep] called as a method, or NULL
   if [h] keeps state, so it's installed for the call instead. */
static inline ren_code ren_method_of(const ren_handler *h, int32_t dep,
                                     int32_t op) {
  for (int32_t i = 0; i < h->nmethods; i++)
    if (h->methods[i].dep == dep && h->methods[i].op == op)
      return h->methods[i].code;
  return NULL;
}

/* ---- the world ---- */

/* The real `Console`: a line to stdout, or to stderr. */
void ren_console_write(ren_obj *line);
void ren_console_error(ren_obj *line);

/* Run [program] on a thread whose stack is big enough for deep
   recursion, then flush stdout and print the statistics, if they're on.
   What `main` returns. */
int ren_run(void (*program)(void));
