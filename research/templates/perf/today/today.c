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

/* The Ren runtime's functions (ren_rt.h says what each does). */

#ifdef REN_STATS
ren_stats_t ren_stats;
#endif

char *ren_stack_limit;
const ren_site *ren_overflow_site;
const ren_site *ren_here;

/* ---- panics ---- */

const char *const *ren_texts;

/* The number at [*p] in a site's pieces, and [*p] moved past it. */
static uint64_t ren_site_num(const unsigned char **p) {
  uint64_t n = 0;
  int shift = 0;
  unsigned char c;
  do {
    c = *(*p)++;
    n |= (uint64_t)(c & 0x7f) << shift;
    shift += 7;
  } while (c & 0x80);
  return n;
}

static void ren_repeat(int c, uint64_t n) {
  for (uint64_t i = 0; i < n; i++) fputc(c, stderr);
}

_Noreturn void ren_panic(const ren_site *site, const char *msg) {
  fflush(stdout);
  const unsigned char *p = site->ops;
  for (;;) {
    switch (*p++) {
    case 1:
      fputs(ren_texts[ren_site_num(&p)], stderr);
      break;
    case 2:
      ren_repeat(' ', ren_site_num(&p));
      break;
    case 3: {
      int c = *p++;
      ren_repeat(c, ren_site_num(&p));
      break;
    }
    case 4:
      fprintf(stderr, "%llu", (unsigned long long)ren_site_num(&p));
      break;
    case 5:
      fputs(msg, stderr);
      break;
    case 6: {
      const char *t = ren_texts[ren_site_num(&p)];
      uint64_t i = ren_site_num(&p);
      uint64_t n = ren_site_num(&p);
      fwrite(t + i, 1, n, stderr);
      break;
    }
    default:
      exit(1);
    }
  }
}

_Noreturn void ren_stack_overflowed(void) {
  ren_panic(ren_overflow_site,
            "the stack overflowed: a function called itself too deeply");
}

/* ---- memory ---- */

#ifdef REN_STATS
void ren_count_alloc(int64_t bytes) {
  ren_stats.allocs++;
  ren_stats.live_bytes += bytes;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
}
#endif

_Noreturn static void ren_out_of_memory(void) {
  fflush(stdout);
  fputs("error: out of memory\n", stderr);
  exit(1);
}

static void *ren_malloc(size_t bytes) {
  void *p = malloc(bytes);
  if (p == NULL)
    ren_out_of_memory();
  return p;
}

REN_THREAD_LOCAL ren_heap_t ren_heap;

void *ren_alloc_big(size_t bytes) { return ren_malloc(bytes); }

/* The list for [words] is empty: a bump from the chunk, or a new chunk
   first. What's left of the old one is too small for this object, and
   is lost; at most [REN_SMALL_WORDS] words of each chunk. */
void *ren_alloc_slow(size_t words) {
  size_t bytes = words * 8;
  if ((size_t)(ren_heap.end - ren_heap.bump) < bytes) {
    ren_heap.bump = ren_malloc(REN_CHUNK_BYTES);
    ren_heap.end = ren_heap.bump + REN_CHUNK_BYTES;
  }
  void *p = ren_heap.bump;
  ren_heap.bump += bytes;
  return p;
}

/* The bytes an element of [a] takes: a sized type's width, or its
   stride's words. */
static size_t ren_elem_bytes(ren_obj *a) {
  return a->nfields ? ren_elem_size[a->nfields]
                    : (size_t)ren_stride(a) * sizeof(ren_val);
}

static ren_obj *ren_alloc_array_c(int64_t len, int64_t cap, uint8_t objs,
                                  uint32_t stride, uint8_t kind) {
  ren_array *a = ren_alloc_bytes(sizeof(ren_array));
  cap = cap > len ? cap : len;
  cap = cap > 0 ? cap : 1;
  a->h.nfields = kind;
  a->stride = stride > 1 ? stride : 1;
  size_t bytes = (size_t)cap * ren_elem_bytes(&a->h);
  a->data = ren_malloc(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)(sizeof(ren_array) + bytes));
#endif
  a->h.rc = 1;
  a->h.tag = REN_TAG_ARRAY;
  a->h.objs = objs;
  a->len = len;
  a->cap = cap;
  a->root = NULL;
  return &a->h;
}

ren_obj *ren_array_reserve(int64_t cap, uint8_t objs, uint32_t stride) {
  return ren_alloc_array_c(0, cap, objs, stride, 0);
}

ren_obj *ren_alloc_array(int64_t len, bool boxed_elems) {
  return ren_alloc_array_c(len, len, boxed_elems, 0, 0);
}

ren_obj *ren_alloc_array_n(int64_t len, uint32_t stride, uint8_t objs) {
  return ren_alloc_array_c(len, len, objs, stride, 0);
}

/* Each object the [n] elements of [a]'s kind from [e] hold, [x] in
   [body]: a counted word's element, or the slots of an element of
   structs that [a]'s mask says (ren_rt.h, [ren_obj]'s [objs]). */
#define REN_ELEM_OBJS(a, e, n, x, body)                                        \
  do {                                                                         \
    int64_t ren_k_ = ren_stride(a), ren_n_ = (n);                              \
    ren_val *ren_e_ = (e);                                                     \
    unsigned ren_m_ = (a)->objs;                                               \
    if (ren_m_ == 0)                                                           \
      break;                                                                   \
    if (ren_k_ == 1)                                                           \
      for (int64_t ren_i_ = 0; ren_i_ < ren_n_; ren_i_++) {                    \
        ren_obj *x = ren_e_[ren_i_].o;                                         \
        body;                                                                  \
      }                                                                        \
    else                                                                       \
      for (int64_t ren_i_ = 0; ren_i_ < ren_n_; ren_i_++)                      \
        for (unsigned m = ren_m_; m != 0; m &= m - 1) {                        \
          ren_obj *x = ren_e_[ren_i_ * ren_k_ + __builtin_ctz(m)].o;           \
          body;                                                                \
        }                                                                      \
  } while (0)

ren_obj *ren_alloc_array_k(int64_t len, uint8_t kind) {
  return ren_alloc_array_c(len, len, false, 0, kind);
}

ren_obj *ren_array_reserve_k(int64_t cap, uint8_t kind) {
  return ren_alloc_array_c(0, cap, false, 0, kind);
}

ren_obj *ren_alloc_array_d(int64_t len, ren_obj *d) {
  return ren_alloc_array_c(len, len, ren_desc_counted(d), 0, ren_desc_elem(d));
}

ren_obj *ren_array_reserve_d(int64_t cap, ren_obj *d) {
  return ren_alloc_array_c(0, cap, ren_desc_counted(d), 0, ren_desc_elem(d));
}

static ren_obj *ren_alloc_str(int64_t len) {
  size_t bytes = sizeof(ren_str) + (size_t)len + 1;
  ren_str *s = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_STR;
  s->h.nfields = 0;
  s->h.objs = 0;
  s->len = len;
  s->data = s->bytes;
  s->root = NULL;
  s->bytes[len] = 0;
  return &s->h;
}

/* Objects whose count reached 0, waiting to have their fields dropped
   and be freed. Freeing goes through this list rather than recursing,
   so dropping a long list doesn't overflow the stack. Lean's
   `lean_dec_ref_cold` keeps the same list (runtime/object.cpp:311-331,
   `push_back`), threaded through the freed objects' headers; this one
   is an array, which is simpler and costs a little more. */
typedef struct {
  ren_obj **objs;
  size_t len, cap;
} ren_todo_t;
static REN_THREAD_LOCAL ren_todo_t ren_todo;

static void ren_todo_push(ren_todo_t *t, ren_obj *o) {
  if (t->len == t->cap) {
    t->cap = t->cap ? t->cap * 2 : 256;
    t->objs = realloc(t->objs, t->cap * sizeof(ren_obj *));
    if (t->objs == NULL) {
      fflush(stdout);
      fputs("error: out of memory\n", stderr);
      exit(1);
    }
  }
  t->objs[t->len++] = o;
}

#ifndef REN_RC_SHARED
_Noreturn void ren_shared_count(ren_obj *o) {
  (void)o;
  fflush(stdout);
  fputs("error: an object's count is negative, which marks it shared, "
        "and nothing shares one yet\n",
        stderr);
  abort();
}
#endif

/* One reference fewer on a child of an object being freed. */
static void ren_release(ren_todo_t *t, ren_obj *o) {
#if defined(REN_RC_SHARED)
  if (ren_is_scalar(o))
    return;
  int32_t rc = ren_rc(o);
  if (rc > 1) {
    REN_STAT(drops);
    o->rc = rc - 1;
  } else if (rc == 1) {
    REN_STAT(drops);
    ren_todo_push(t, o);
  } else if (rc != 0 && __atomic_add_fetch(&o->rc, 1, __ATOMIC_ACQ_REL) == 0) {
    ren_todo_push(t, o);
  }
#elif defined(REN_RC_ATOMIC)
  if (ren_is_scalar(o) || ren_rc(o) == 0)
    return;
  REN_STAT(drops);
  if (__atomic_sub_fetch(&o->rc, 1, __ATOMIC_RELEASE) == 0) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    ren_todo_push(t, o);
  }
#else
  if (ren_is_scalar(o) || o->rc == 0)
    return;
  REN_STAT(drops);
  if (o->rc > 1)
    o->rc--;
  else if (o->rc == 1)
    ren_todo_push(t, o);
  else
    ren_shared_count(o);
#endif
}

/* Free one object whose count reached 0, its children going on the
   list. */
static void ren_free_one(ren_todo_t *t, ren_obj *o) {
  int64_t bytes = 0; /* what it held, for the statistics */
  size_t size = 0;   /* its own memory */
  switch (o->tag) {
  default: { /* a constructor */
    ren_val *fs = ren_fields(o);
    for (uint64_t m = ren_ctor_objs(o); m != 0; m &= m - 1)
      ren_release(t, fs[__builtin_ctzll(m)].o);
    size = ren_ctor_size(o->nfields);
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_DESC: {
    ren_desc *d = (ren_desc *)o;
    for (uint16_t i = 0; i < d->nargs; i++)
      ren_release(t, &d->args[i]->h);
    size = sizeof(ren_desc) + d->nargs * sizeof(ren_desc *);
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_ARRAY: {
    ren_array *a = (ren_array *)o;
    if (a->root != NULL) { /* a slice: its root holds the elements */
      ren_release(t, a->root);
      size = sizeof(ren_array);
      bytes = (int64_t)size;
      break;
    }
    REN_ELEM_OBJS(o, a->data, a->len, x, ren_release(t, x));
    bytes = (int64_t)(sizeof(ren_array) + (size_t)a->cap * ren_elem_bytes(o));
    free(a->data);
    size = sizeof(ren_array);
    break;
  }
  case REN_TAG_STR: {
    ren_str *s = (ren_str *)o;
    if (s->root != NULL) {
      ren_release(t, s->root);
      size = sizeof(ren_str);
    } else
      size = sizeof(ren_str) + (size_t)s->len + 1;
    bytes = (int64_t)size;
    break;
  }
  case REN_TAG_MAP: {
    ren_map *m = (ren_map *)o;
    for (int64_t e = 0; e < m->used; e++) {
      ren_val *ent = &m->entries[e * m->width];
      if (ent[0].i == 0)
        continue;
      if (o->objs & 1)
        ren_release(t, ent[1].o);
      if ((o->objs & 2) && m->width > 2)
        ren_release(t, ent[2].o);
    }
    bytes = (int64_t)sizeof(ren_map) +
            m->cap * m->width * (int64_t)sizeof(ren_val) +
            (m->shift ? ((int64_t)1 << m->shift) * (int64_t)sizeof(int32_t) : 0);
    free(m->entries);
    free(m->index);
    size = sizeof(ren_map);
    break;
  }
  }
#ifdef REN_STATS
  ren_stats.frees++;
  ren_stats.live_bytes -= bytes;
#else
  (void)bytes;
#endif
  ren_free_bytes(o, size);
}

void ren_free(ren_obj *o) {
  /* the list's address once, since a thread-local one costs a call on
     Mach-O to find */
  ren_todo_t *t = &ren_todo;
  ren_free_one(t, o);
  while (t->len > 0)
    ren_free_one(t, t->objs[--t->len]);
}

#ifdef REN_RC_SHARED
/* A shared count runs down from -1: one more reference is one lower,
   relaxed as in `lean_inc_ref_n` (lean.h:722), since whoever dups
   already holds a reference that keeps the object alive. */
void ren_dup_shared(ren_obj *o) {
  __atomic_fetch_sub(&o->rc, 1, __ATOMIC_RELAXED);
}

/* One fewer, and the thread that takes the last frees it: acq_rel, so
   every other thread's writes before its drop happen before the free
   (runtime/object.cpp:461, `lean_dec_ref_cold`). */
void ren_drop_shared(ren_obj *o) {
  if (__atomic_add_fetch(&o->rc, 1, __ATOMIC_ACQ_REL) == 0)
    ren_free(o);
}

/* `lean_mark_mt` (runtime/object.cpp:663): an object and all it reaches
   that one thread owns get their counts negated. One already shared or
   never freed stops the walk, since what it reaches is too. It runs
   before the object is published, so the plain writes are seen by the
   thread that receives it through whatever hands it over. */
void ren_mark_shared(ren_obj *o) {
  if (ren_is_scalar(o) || o->rc <= 0)
    return;
  size_t len = 0, cap = 64;
  ren_obj **todo = malloc(cap * sizeof(ren_obj *));
  if (todo == NULL)
    abort();
  todo[len++] = o;
  while (len > 0) {
    ren_obj *x = todo[--len];
    if (ren_is_scalar(x) || x->rc <= 0)
      continue;
    x->rc = -x->rc;
    size_t n = 0; /* at most this many children */
    switch (x->tag) {
    default:
      n = x->nfields;
      break;
    case REN_TAG_ARRAY:
      if (((ren_array *)x)->root != NULL)
        n = 1; /* a slice reaches its root, which reaches the elements */
      else
        n = (size_t)((ren_array *)x)->len * (size_t)__builtin_popcount(x->objs);
      break;
    case REN_TAG_DESC:
      n = ((ren_desc *)x)->nargs;
      break;
    case REN_TAG_STR:
      n = ((ren_str *)x)->root != NULL;
      break;
    case REN_TAG_MAP:
      n = (size_t)((ren_map *)x)->len * 2;
      break;
    }
    if (len + n > cap) {
      while (len + n > cap)
        cap *= 2;
      todo = realloc(todo, cap * sizeof(ren_obj *));
      if (todo == NULL)
        abort();
    }
    switch (x->tag) {
    default:
      for (uint64_t m = ren_ctor_objs(x); m != 0; m &= m - 1)
        todo[len++] = ren_fields(x)[__builtin_ctzll(m)].o;
      break;
    case REN_TAG_ARRAY:
      if (((ren_array *)x)->root != NULL)
        todo[len++] = ((ren_array *)x)->root;
      else
        REN_ELEM_OBJS(x, ((ren_array *)x)->data, ((ren_array *)x)->len, e,
                      todo[len++] = e);
      break;
    case REN_TAG_DESC:
      for (size_t i = 0; i < n; i++)
        todo[len++] = &((ren_desc *)x)->args[i]->h;
      break;
    case REN_TAG_STR:
      if (n)
        todo[len++] = ((ren_str *)x)->root;
      break;
    case REN_TAG_MAP: {
      ren_map *m = (ren_map *)x;
      for (int64_t e = 0; e < m->used; e++) {
        ren_val *ent = &m->entries[e * m->width];
        if (ent[0].i == 0)
          continue;
        if (x->objs & 1)
          todo[len++] = ent[1].o;
        if ((x->objs & 2) && m->width > 2)
          todo[len++] = ent[2].o;
      }
      break;
    }
    }
  }
  free(todo);
}
#endif

/* ---- reuse ---- */

void ren_drop_unkept(ren_obj *o, uint64_t kept) {
  ren_val *fs = ren_fields(o);
  for (uint64_t m = ren_ctor_objs(o) & ~kept; m != 0; m &= m - 1)
    ren_drop(fs[__builtin_ctzll(m)].o);
}

static void ren_free_cell(ren_obj *o) {
  size_t size = ren_ctor_size(o->nfields);
#ifdef REN_STATS
  ren_stats.frees++;
  ren_stats.live_bytes -= (int64_t)size;
#endif
  ren_free_bytes(o, size);
}

void ren_free_keeping(ren_obj *o, uint64_t kept) {
  ren_drop_unkept(o, kept);
  ren_free_cell(o);
}

void ren_free_token(ren_obj *tok) {
  if (tok != NULL)
    ren_free_cell(tok);
}

/* ---- arrays ---- */

_Noreturn void ren_index_panic_len(int64_t len, int64_t i, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "index %" PRId64 " is out of bounds for an array of length %" PRId64,
           i, len);
  ren_panic(site, msg);
}

_Noreturn void ren_index_panic(ren_obj *a, int64_t i, const ren_site *site) {
  ren_index_panic_len(((ren_array *)a)->len, i, site);
}

static void ren_check_index(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
}

/* A copy of [a] with room for [extra] more, each element counted again. */
static ren_obj *ren_array_copy(ren_obj *a, int64_t extra) {
  ren_array *from = (ren_array *)a;
  ren_obj *b = ren_alloc_array_c(from->len + extra, from->len + extra, a->objs,
                                 (uint32_t)from->stride, a->nfields);
  ren_val *to = ren_elems(b);
  if (a->objs && from->stride == 1)
    for (int64_t i = 0; i < from->len; i++) {
      to[i] = from->data[i];
      ren_dup(to[i].o);
    }
  else {
    memcpy(to, from->data, (size_t)from->len * ren_elem_bytes(a));
    REN_ELEM_OBJS(a, to, from->len, x, ren_dup(x));
  }
  return b;
}

ren_obj *ren_array_set(ren_obj *a, int64_t i, ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_val *to = ren_elems(b);
  if (a->objs) {
    ren_drop(to[i].o);
    ren_dup(v.o);
  }
  to[i] = v;
  return b;
}

void ren_array_push(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  if (a->objs)
    ren_dup(v.o);
  ren_elems(b)[((ren_array *)b)->len - 1] = v;
  ren_drop(a);
  *cell = b;
}

ren_obj *ren_array_unshare(ren_obj *a) {
  ren_obj *b = ren_array_copy(a, 0);
  ren_drop(a);
  return b;
}

/* Room for one element more in a unique array: its buffer doubled if
   it's full. Out of line: inlined into [ren_array_push_taking], which
   it was once the out-of-memory path's extra call stopped, it made
   blocks 24% slower in cycles on fewer instructions, and splitting off
   only the doubling didn't help (RESULTS.md, "Frames and late overflow
   cut"). */
__attribute__((noinline)) static void ren_array_grow(ren_array *arr) {
  if (arr->len < arr->cap)
    return;
  size_t k = ren_elem_bytes(&arr->h);
  int64_t cap = arr->cap * 2;
  ren_val *data = realloc(arr->data, (size_t)cap * k);
  if (data == NULL) {
    fflush(stdout);
    fputs("error: out of memory\n", stderr);
    exit(1);
  }
#ifdef REN_STATS
  ren_stats.grows++;
  ren_stats.live_bytes += (cap - arr->cap) * (int64_t)k;
  if (ren_stats.live_bytes > ren_stats.peak_bytes)
    ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
  arr->data = data;
  arr->cap = cap;
}

void ren_array_push_taking(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!ren_array_unique(a)) {
    ren_obj *b = ren_array_copy(a, 1);
    ren_elems(b)[((ren_array *)b)->len - 1] = v;
    ren_drop(a);
    *cell = b;
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  arr->data[arr->len++] = v;
}

/* ---- arrays of a type variable's elements, or a sized type's ---- */

ren_obj *ren_array_set_w(ren_obj *a, int64_t i, ren_val v, const ren_site *site) {
  if (!a->nfields)
    return ren_array_set(a, i, v, site);
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_sized_store(b, i, v);
  return b;
}

void ren_array_push_w(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!a->nfields) {
    ren_array_push(cell, v);
    return;
  }
  ren_obj *b = ren_array_copy(a, 1);
  ren_sized_store(b, ((ren_array *)b)->len - 1, v);
  ren_drop(a);
  *cell = b;
}

void ren_array_push_taking_w(ren_obj **cell, ren_val v) {
  ren_obj *a = *cell;
  if (!a->nfields) {
    ren_array_push_taking(cell, v);
    return;
  }
  if (!ren_array_unique(a)) {
    ren_array_push_w(cell, v);
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  ren_sized_store(a, arr->len++, v);
}

/* ---- arrays of structs ---- */

ren_obj *ren_array_set_slots(ren_obj *a, int64_t i, const ren_val *v,
                             const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  int64_t k = ren_stride(a);
  ren_val *e = &ren_elems(b)[i * k];
  ren_slots_drop(e, a->objs);
  memcpy(e, v, (size_t)k * sizeof(ren_val));
  ren_slots_dup(e, a->objs);
  return b;
}

ren_obj *ren_array_set_field(ren_obj *a, int64_t i, int64_t off, int64_t k,
                             ren_val v, const ren_site *site) {
  ren_check_index(a, i, site);
  ren_obj *b = ren_array_copy(a, 0);
  ren_val *at = &ren_elems(b)[i * k + off];
  if (a->objs & (1u << off)) {
    ren_drop(at->o);
    ren_dup(v.o);
  }
  *at = v;
  return b;
}

void ren_array_push_slots(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  ren_obj *b = ren_array_copy(a, 1);
  int64_t k = ren_stride(a);
  ren_val *e = &ren_elems(b)[(((ren_array *)b)->len - 1) * k];
  memcpy(e, v, (size_t)k * sizeof(ren_val));
  ren_slots_dup(e, a->objs);
  ren_drop(a);
  *cell = b;
}

void ren_array_push_slots_taking(ren_obj **cell, const ren_val *v) {
  ren_obj *a = *cell;
  int64_t k = ren_stride(a);
  if (!ren_array_unique(a)) {
    ren_obj *b = ren_array_copy(a, 1);
    memcpy(&ren_elems(b)[(((ren_array *)b)->len - 1) * k], v,
           (size_t)k * sizeof(ren_val));
    ren_drop(a);
    *cell = b;
    return;
  }
  ren_array *arr = (ren_array *)a;
  ren_array_grow(arr);
  memcpy(&arr->data[arr->len * k], v, (size_t)k * sizeof(ren_val));
  arr->len++;
}

/* ---- strings ---- */

ren_obj *ren_str_of(const char *s, int64_t len) {
  ren_obj *o = ren_alloc_str(len);
  memcpy(((ren_str *)o)->bytes, s, (size_t)len);
  return o;
}

ren_obj *ren_str_concat(ren_obj *a, ren_obj *b) {
  int64_t la = ren_str_len(a), lb = ren_str_len(b);
  ren_obj *o = ren_alloc_str(la + lb);
  memcpy(((ren_str *)o)->bytes, ren_str_data(a), (size_t)la);
  memcpy(((ren_str *)o)->bytes + la, ren_str_data(b), (size_t)lb);
  return o;
}

bool ren_str_eq(ren_obj *a, ren_obj *b) {
  return ren_str_len(a) == ren_str_len(b) &&
         memcmp(ren_str_data(a), ren_str_data(b), (size_t)ren_str_len(a)) == 0;
}

/* ---- slices (foundations.md, decision 17) ----

   Roc's seamless slices (crates/compiler/builtins/bitcode/src/list.zig,
   `seamlessSlice`; str.zig, `SEAMLESS_SLICE_BIT`): a slice shares its
   root's buffer and counts the root, not each element, so making one is
   O(1) whatever it holds. Roc tags a slice in the high bit of its
   capacity; this runtime has room in the header for a pointer to the
   root, which is simpler, and frees the slice's header on its own. A
   slice's root is always an owner, so dropping a slice never walks a
   chain of them. The checks, and what they say, are the interpreter's
   (builtins.ml, [slice_value] and [split_halves]). */

static const char *ren_sliced_what(ren_obj *a, bool str) {
  return a->tag == REN_TAG_ARRAY ? "an array" : str ? "a string" : "bytes";
}

/* Panics unless [i..j] is a range in [a], of length [len]. */
static void ren_slice_check(ren_obj *a, int64_t len, int64_t i, int64_t j,
                            bool str, const ren_site *site) {
  char msg[160];
  if (i > j) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " ends before it starts", i, j);
    ren_panic(site, msg);
  }
  if (i < 0 || j > len) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64
             " is out of bounds for %s of length %" PRId64,
             i, j, ren_sliced_what(a, str), len);
    ren_panic(site, msg);
  }
}

/* Whether byte [i] of a string begins a character, or is its end: UTF-8's
   continuation bytes are 10xxxxxx. */
static bool ren_boundary(ren_obj *s, int64_t i) {
  return i == ren_str_len(s) ||
         ((unsigned char)ren_str_data(s)[i] & 0xc0) != 0x80;
}

/* Panics, for a `Str`, if [i] or [j] is inside a character; [from] and
   [to] are the range said, which a `split_at`'s is 0 to [j]. */
static void ren_chars_check(ren_obj *s, int64_t i, int64_t j,
                            const ren_site *site) {
  char msg[160];
  if (!ren_boundary(s, i)) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " starts inside a character", i,
             j);
    ren_panic(site, msg);
  }
  if (!ren_boundary(s, j)) {
    snprintf(msg, sizeof msg,
             "slice %" PRId64 " to %" PRId64 " ends inside a character", i, j);
    ren_panic(site, msg);
  }
}

/* Where element [i] of [a] is. */
static void *ren_elem_at(ren_obj *a, int64_t i) {
  return (char *)((ren_array *)a)->data + (size_t)i * ren_elem_bytes(a);
}

/* Whether [a] is a lent slice ([ren_array_writable]). */
static bool ren_lent(ren_obj *a) {
  return ((ren_array *)a)->cap < 0;
}

/* [a] not lent any more: something else sees its range now, or will. A
   shared one, whose count another thread may be changing, is never
   written in place anyway, and isn't written to here. */
static void ren_unlend(ren_obj *a) {
  ren_array *arr = (ren_array *)a;
  if (arr->cap < 0 && ren_rc(a) > 0)
    arr->cap = 0;
}

/* A new header for [len] of [a]'s elements from where [at] points, in
   [a]'s buffer, counting [a]'s root; lent if [lent]. */
static ren_obj *ren_array_view(ren_obj *a, void *at, int64_t len, bool lent) {
  ren_array *from = (ren_array *)a;
  ren_array *s = ren_alloc_bytes(sizeof(ren_array));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_array));
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_ARRAY;
  s->h.nfields = a->nfields;
  s->h.objs = a->objs;
  s->stride = from->stride;
  s->data = at;
  s->len = len;
  s->cap = lent ? -1 : 0;
  s->root = from->root != NULL ? from->root : a;
  ren_dup(s->root);
  return &s->h;
}

/* [a]'s elements from [i] up to [j], in range: a slice, which ends [a]'s
   lending, or [a] itself, counted again, for all of it. */
static ren_obj *ren_array_part(ren_obj *a, int64_t i, int64_t j) {
  ren_unlend(a);
  if (i == 0 && j == ren_array_len(a)) {
    ren_dup(a);
    return a;
  }
  return ren_array_view(a, ren_elem_at(a, i), j - i, false);
}

static ren_obj *ren_str_part(ren_obj *a, int64_t i, int64_t j) {
  ren_str *from = (ren_str *)a;
  if (i == 0 && j == from->len) {
    ren_dup(a);
    return a;
  }
  ren_str *s = ren_alloc_bytes(sizeof(ren_str));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_str));
#endif
  s->h.rc = 1;
  s->h.tag = REN_TAG_STR;
  s->h.nfields = 0;
  s->h.objs = 0;
  s->len = j - i;
  s->data = from->data + i;
  s->root = from->root != NULL ? from->root : a;
  ren_dup(s->root);
  return &s->h;
}

ren_obj *ren_array_slice(ren_obj *a, int64_t i, int64_t j,
                         const ren_site *site) {
  ren_slice_check(a, ren_array_len(a), i, j, false, site);
  return ren_array_part(a, i, j);
}

ren_obj *ren_str_slice(ren_obj *s, int64_t i, int64_t j, bool str,
                       const ren_site *site) {
  ren_slice_check(s, ren_str_len(s), i, j, str, site);
  if (str)
    ren_chars_check(s, i, j, site);
  return ren_str_part(s, i, j);
}

/* Panics unless [n] is where `split_at` can split [a], of length [len]. */
static void ren_split_check(ren_obj *a, int64_t len, int64_t n, bool str,
                            const ren_site *site) {
  if (n < 0 || n > len) {
    char msg[160];
    snprintf(msg, sizeof msg,
             "`split_at` %" PRId64 " is out of bounds for %s of length %" PRId64,
             n, ren_sliced_what(a, str), len);
    ren_panic(site, msg);
  }
  if (str)
    ren_chars_check(a, 0, n, site);
}

/* A `split_at`'s halves are lent, each a header of its own, if [a] is
   writable: nothing else sees its range, and, since its place is vacant
   while the block has them, nothing else will. A slice of either ends
   its lending ([ren_array_part]), and so does the join after
   ([ren_array_join]), so each lent slice is the only way to its range.
   [ren_array_after] lends its half if [lo] was: it's made right after,
   [a] the same, and [lo] holds a count of [a]'s root, so [a] isn't
   writable itself any more. */
ren_obj *ren_array_before(ren_obj *a, int64_t n, const ren_site *site) {
  ren_split_check(a, ren_array_len(a), n, false, site);
  if (ren_array_writable(a))
    return ren_array_view(a, ren_elem_at(a, 0), n, true);
  return ren_array_part(a, 0, n);
}

ren_obj *ren_array_after(ren_obj *a, int64_t n, ren_obj *lo) {
  int64_t len = ren_array_len(a);
  if (ren_lent(lo) && ((ren_array *)lo)->data == ((ren_array *)a)->data) {
    ren_obj *hi = ren_array_view(a, ren_elem_at(a, n), len - n, true);
    ren_unlend(a);
    return hi;
  }
  return ren_array_part(a, n, len);
}

ren_obj *ren_str_before(ren_obj *s, int64_t n, bool str, const ren_site *site) {
  ren_split_check(s, ren_str_len(s), n, str, site);
  return ren_str_part(s, 0, n);
}

ren_obj *ren_str_after(ren_obj *s, int64_t n) {
  return ren_str_part(s, n, ren_str_len(s));
}

/* Copies [n] of [from]'s elements from [i] to [to], each counted again. */
static void ren_elems_copy(ren_obj *to, int64_t at, ren_obj *from, int64_t i,
                           int64_t n) {
  if (n <= 0)
    return;
  memcpy(ren_elem_at(to, at), ren_elem_at(from, i),
         (size_t)n * ren_elem_bytes(from));
  REN_ELEM_OBJS(from, (ren_val *)ren_elem_at(from, i), n, x, ren_dup(x));
}

ren_obj *ren_array_splice(ren_obj *a, int64_t i, int64_t j, ren_obj *b) {
  int64_t la = ren_array_len(a), lb = ren_array_len(b);
  ren_obj *o = ren_alloc_array_c(la - (j - i) + lb, la - (j - i) + lb, a->objs,
                                 (uint32_t)((ren_array *)a)->stride,
                                 a->nfields);
  ren_elems_copy(o, 0, a, 0, i);
  ren_elems_copy(o, i, b, 0, lb);
  ren_elems_copy(o, i + lb, a, j, la - j);
  return o;
}

/* A `split_at`'s halves joined. If they're slices of one root, next to
   each other, their elements are already in order there: all of the
   root, if they cover it and are all that hold it, or else a slice of
   it, lent if both were and nothing else holds either, since then
   nothing else sees its range. Either ends the halves' lending. */
ren_obj *ren_array_join(ren_obj *a, ren_obj *b) {
  ren_array *x = (ren_array *)a, *y = (ren_array *)b;
  if (x->root != NULL && x->root == y->root &&
      (char *)x->data + (size_t)x->len * ren_elem_bytes(a) == (char *)y->data) {
    ren_obj *root = x->root;
    bool lent = ren_lent(a) && ren_lent(b) && ren_rc(a) == 1 && ren_rc(b) == 1;
    ren_unlend(a);
    ren_unlend(b);
    if (x->data == ((ren_array *)root)->data &&
        x->len + y->len == ren_array_len(root) && ren_rc(root) == 2) {
      ren_dup(root);
      return root;
    }
    return ren_array_view(a, x->data, x->len + y->len, lent);
  }
  int64_t la = ren_array_len(a);
  return ren_array_splice(a, la, la, b);
}

ren_obj *ren_str_splice(ren_obj *s, int64_t i, int64_t j, ren_obj *b) {
  int64_t ls = ren_str_len(s), lb = ren_str_len(b);
  ren_obj *o = ren_alloc_str(ls - (j - i) + lb);
  char *to = ((ren_str *)o)->bytes;
  memcpy(to, ren_str_data(s), (size_t)i);
  memcpy(to + i, ren_str_data(b), (size_t)lb);
  memcpy(to + i + lb, ren_str_data(s) + j, (size_t)(ls - j));
  return o;
}

/* Strings never change, so their halves are never lent: joined, they're
   their root, or a slice of it, if they're next to each other in it. */
ren_obj *ren_str_join(ren_obj *a, ren_obj *b) {
  ren_str *x = (ren_str *)a, *y = (ren_str *)b;
  if (x->root != NULL && x->root == y->root && x->data + x->len == y->data) {
    ren_obj *root = x->root;
    if (x->data == ((ren_str *)root)->data &&
        x->len + y->len == ren_str_len(root)) {
      ren_dup(root);
      return root;
    }
    ren_str *s = ren_alloc_bytes(sizeof(ren_str));
#ifdef REN_STATS
    ren_count_alloc((int64_t)sizeof(ren_str));
#endif
    s->h = x->h;
    s->h.rc = 1;
    s->len = x->len + y->len;
    s->data = x->data;
    s->root = root;
    ren_dup(root);
    return &s->h;
  }
  return ren_str_concat(a, b);
}

ren_obj *ren_str_split(ren_obj *s, ren_obj *sep, const ren_site *site) {
  int64_t n = ren_str_len(s), m = ren_str_len(sep);
  const char *d = ren_str_data(s), *p = ren_str_data(sep);
  if (m == 0)
    ren_panic(site, "`split` needs a separator that isn't empty");
  /* the parts: one more than the separators found, left to right */
  int64_t parts = 1;
  for (int64_t i = 0; i + m <= n;)
    if (memcmp(d + i, p, (size_t)m) == 0) {
      parts++;
      i += m;
    } else
      i++;
  ren_obj *out = ren_alloc_array(parts, true);
  ren_val *xs = ren_elems(out);
  int64_t from = 0, k = 0;
  for (int64_t i = 0; i + m <= n;)
    if (memcmp(d + i, p, (size_t)m) == 0) {
      xs[k++].o = ren_str_part(s, from, i);
      i += m;
      from = i;
    } else
      i++;
  xs[k].o = ren_str_part(s, from, n);
  return out;
}

static bool ren_trimmed(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';
}

ren_obj *ren_str_trim(ren_obj *s) {
  int64_t i = 0, j = ren_str_len(s);
  const char *d = ren_str_data(s);
  while (i < j && ren_trimmed(d[i]))
    i++;
  while (j > i && ren_trimmed(d[j - 1]))
    j--;
  return ren_str_part(s, i, j);
}

ren_obj *ren_str_lower(ren_obj *s) {
  int64_t n = ren_str_len(s);
  const char *from = ren_str_data(s);
  ren_obj *o = ren_alloc_str(n);
  char *to = ((ren_str *)o)->bytes;
  for (int64_t i = 0; i < n; i++) {
    char c = from[i];
    to[i] = c >= 'A' && c <= 'Z' ? (char)(c + ('a' - 'A')) : c;
  }
  to[n] = 0;
  return o;
}

ren_obj *ren_array_copied(ren_obj *a) {
  if (((ren_array *)a)->root == NULL) {
    ren_dup(a);
    return a;
  }
  return ren_array_copy(a, 0);
}

ren_obj *ren_str_copied(ren_obj *s) {
  if (((ren_str *)s)->root == NULL) {
    ren_dup(s);
    return s;
  }
  return ren_str_of(ren_str_data(s), ren_str_len(s));
}

void ren_bytes_index_panic(int64_t len, int64_t i, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "index %" PRId64 " is out of bounds for bytes of length %" PRId64,
           i, len);
  ren_panic(site, msg);
}

ren_obj *ren_bytes_of(ren_obj *a, const ren_site *site) {
  int64_t n = ren_array_len(a);
  ren_obj *o = ren_alloc_str(n);
  for (int64_t i = 0; i < n; i++) {
    int64_t x = ren_elems(a)[i].i;
    if (x < 0 || x > 255) {
      char msg[96];
      snprintf(msg, sizeof msg, "%" PRId64 " isn't a byte, 0 to 255", x);
      ren_drop(o);
      ren_panic(site, msg);
    }
    ((ren_str *)o)->bytes[i] = (char)x;
  }
  return o;
}

void ren_bytes_range_panic(int64_t len, int64_t at, int width,
                           const ren_site *site) {
  if (width == 1)
    ren_bytes_index_panic(len, at, site);
  char msg[160];
  snprintf(msg, sizeof msg,
           "%d bytes at %" PRId64 " are out of bounds for bytes of length %" PRId64,
           width, at, len);
  ren_panic(site, msg);
}

void ren_bytes_u64_panic(int64_t at, uint64_t x, bool big, const ren_site *site) {
  char msg[160];
  snprintf(msg, sizeof msg,
           "`u64_%s` at %" PRId64 " read %" PRIu64 ", which is more than an `Int` holds",
           big ? "be" : "le", at, x);
  ren_panic(site, msg);
}

void ren_varuint_panic(int64_t x, const ren_site *site) {
  char msg[128];
  snprintf(msg, sizeof msg,
           "%" PRId64 " doesn't fit in a `VarUInt`, which holds 0 to 9223372036854775807", x);
  ren_panic(site, msg);
}

ren_obj *ren_bytes_unshare(ren_obj *b) {
  ren_obj *c = ren_str_of(ren_str_data(b), ren_str_len(b));
  ren_drop(b);
  return c;
}

bool ren_utf8_valid(ren_obj *s) {
  const unsigned char *p = (const unsigned char *)ren_str_data(s);
  int64_t n = ren_str_len(s), i = 0;
  while (i < n) {
    unsigned c = p[i];
    if (c < 0x80) {
      i++;
      continue;
    }
    /* how many bytes follow, and the range the second is in, which rules
       out overlong forms, surrogates and what's past U+10FFFF */
    int more;
    unsigned lo = 0x80, hi = 0xbf;
    if (c >= 0xc2 && c <= 0xdf)
      more = 1;
    else if (c >= 0xe0 && c <= 0xef) {
      more = 2;
      if (c == 0xe0)
        lo = 0xa0;
      else if (c == 0xed)
        hi = 0x9f;
    } else if (c >= 0xf0 && c <= 0xf4) {
      more = 3;
      if (c == 0xf0)
        lo = 0x90;
      else if (c == 0xf4)
        hi = 0x8f;
    } else
      return false;
    if (n - i <= more)
      return false;
    if (p[i + 1] < lo || p[i + 1] > hi)
      return false;
    for (int k = 2; k <= more; k++)
      if ((p[i + k] & 0xc0) != 0x80)
        return false;
    i += more + 1;
  }
  return true;
}

ren_obj *ren_bytes_zeros(int64_t n, const ren_site *site) {
  if (n < 0) {
    char msg[96];
    snprintf(msg, sizeof msg, "`Bytes.zeros(%" PRId64 ")`: a length is 0 or more", n);
    ren_panic(site, msg);
  }
  ren_obj *o = ren_alloc_str(n);
  memset(((ren_str *)o)->bytes, 0, (size_t)n);
  return o;
}

ren_obj *ren_show_int(int64_t n) {
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%" PRId64, n);
  return ren_str_of(buf, len);
}

ren_obj *ren_show_bool(bool b) {
  return b ? ren_str_of("true", 4) : ren_str_of("false", 5);
}

/* [s], a number as `%g` writes it, with its digits written out instead of
   an exponent: token.ml's `without_exponent`. */
static void ren_without_exponent(char *out, const char *s) {
  const char *e = strchr(s, 'e');
  if (e == NULL) {
    strcpy(out, s);
    return;
  }
  int exp = atoi(e + 1);
  const char *m = s;
  bool neg = *m == '-';
  if (neg)
    m++;
  /* the mantissa's digits, and how many come before the point */
  char digits[64];
  int n = 0, whole = 0;
  bool seen_point = false;
  for (const char *p = m; p < e; p++) {
    if (*p == '.')
      seen_point = true;
    else {
      digits[n++] = *p;
      if (!seen_point)
        whole++;
    }
  }
  int point = whole + exp;
  char *o = out;
  if (neg)
    *o++ = '-';
  if (point <= 0) {
    *o++ = '0';
    *o++ = '.';
    for (int i = 0; i < -point; i++)
      *o++ = '0';
    for (int i = 0; i < n; i++)
      *o++ = digits[i];
  } else if (point >= n) {
    for (int i = 0; i < n; i++)
      *o++ = digits[i];
    for (int i = 0; i < point - n; i++)
      *o++ = '0';
  } else {
    for (int i = 0; i < point; i++)
      *o++ = digits[i];
    *o++ = '.';
    for (int i = point; i < n; i++)
      *o++ = digits[i];
  }
  *o = 0;
}

void ren_format_float(char *buf, double f) {
  if (f == trunc(f) && fabs(f) < 1e16) {
    snprintf(buf, 400, "%.1f", f);
  } else if (isinf(f)) {
    strcpy(buf, f > 0 ? "inf" : "-inf");
  } else {
    char g[64];
    for (int digits = 1;; digits++) {
      snprintf(g, sizeof g, "%.*g", digits, f);
      if (digits >= 17 || strtod(g, NULL) == f)
        break;
    }
    ren_without_exponent(buf, g);
    if (strchr(buf, '.') == NULL)
      strcat(buf, ".0");
  }
}

ren_obj *ren_show_float(double f, const ren_site *site) {
  if (isnan(f))
    ren_nan_panic(site, "`show` of a NaN", f);
  char buf[400];
  ren_format_float(buf, f);
  return ren_str_of(buf, (int64_t)strlen(buf));
}

void ren_print_quoted(FILE *out, ren_obj *s) {
  fputc('"', out);
  const char *d = ren_str_data(s);
  for (int64_t i = 0; i < ren_str_len(s); i++) {
    switch (d[i]) {
    case '\n':
      fputs("\\n", out);
      break;
    case '\t':
      fputs("\\t", out);
      break;
    case '\\':
      fputs("\\\\", out);
      break;
    case '"':
      fputs("\\\"", out);
      break;
    default:
      fputc(d[i], out);
    }
  }
  fputc('"', out);
}

/* ---- arithmetic ---- */

_Noreturn void ren_int_overflowed(const ren_site *site, const char *op,
                                  int64_t a, int64_t b) {
  char msg[128];
  snprintf(msg, sizeof msg, "`%s` overflowed: %" PRId64 " %s %" PRId64, op, a,
           op, b);
  ren_panic(site, msg);
}

_Noreturn void ren_shift_panic(const ren_site *site, const char *op,
                               int64_t k) {
  char msg[96];
  snprintf(msg, sizeof msg, "`%s` by %" PRId64 ": a shift is by 0 to 63", op,
           k);
  ren_panic(site, msg);
}

/* ---- NaN ---- */

const char *const *ren_nan_where;
int32_t ren_nan_nwhere;

_Noreturn void ren_nan_panic(const ren_site *site, const char *what, double f) {
  uint64_t bits;
  memcpy(&bits, &f, sizeof bits);
  uint32_t tag = (uint32_t)((bits >> 29) & 0x3FFFFF);
  if (ren_nan_where != NULL && tag > 0 && (int32_t)tag < ren_nan_nwhere &&
      ren_nan_where[tag] != NULL) {
    char msg[600];
    snprintf(msg, sizeof msg, "%s made %s", what, ren_nan_where[tag]);
    ren_panic(site, msg);
  }
  ren_panic(site, what);
}

_Noreturn void ren_narrow_panic(const ren_site *site, uint8_t kind, ren_val v) {
  static const char *const names[] = {"",       "Int8",   "UInt8",
                                      "Int16",  "UInt16", "Int32",
                                      "UInt32", "UInt64", "Float32"};
  static const int64_t lo[] = {0, INT8_MIN, 0, INT16_MIN, 0, INT32_MIN, 0, 0};
  static const int64_t hi[] = {0,         INT8_MAX,   UINT8_MAX,
                               INT16_MAX, UINT16_MAX, INT32_MAX,
                               UINT32_MAX, INT64_MAX};
  char num[400], msg[600];
  if (kind == REN_ELEM_F32) {
    ren_format_float(num, v.f);
    snprintf(msg, sizeof msg,
             "%s doesn't fit in a `Float32`, which holds up to about 3.4e38",
             num);
  } else {
    bool sign = kind == REN_ELEM_I8 || kind == REN_ELEM_I16 ||
                kind == REN_ELEM_I32;
    snprintf(msg, sizeof msg,
             "%" PRId64 " doesn't fit in %s `%s`, which holds %" PRId64
             " to %" PRId64,
             v.i, sign ? "an" : "a", names[kind], lo[kind], hi[kind]);
  }
  ren_panic(site, msg);
}

int64_t ren_div(int64_t a, int64_t b, const ren_site *site) {
  if (b == 0)
    ren_panic(site, "division by zero");
  if (a == INT64_MIN && b == -1) {
    char msg[128];
    snprintf(msg, sizeof msg, "`/` overflowed: %" PRId64 " / %" PRId64, a, b);
    ren_panic(site, msg);
  }
  return a / b;
}

int64_t ren_rem(int64_t a, int64_t b, const ren_site *site) {
  if (b == 0)
    ren_panic(site, "division by zero");
  /* INT64_MIN % -1 traps in C; it's 0, as OCaml's Int64.rem says */
  if (b == -1)
    return 0;
  return a % b;
}

int64_t ren_neg(int64_t a, const ren_site *site) {
  if (a == INT64_MIN) {
    char msg[128];
    snprintf(msg, sizeof msg, "`-` overflowed: -(%" PRId64 ")", a);
    ren_panic(site, msg);
  }
  return -a;
}

/* [r], [f] rounded by [how], if it's an `Int`: builtins.ml's `to_int`. */
static int64_t ren_to_int(double r, double f, const char *how,
                          const ren_site *site) {
  if (isnan(f)) {
    char what[64];
    snprintf(what, sizeof what, "`%s` of a NaN", how);
    ren_nan_panic(site, what, f);
  }
  if (isfinite(r) && r >= -9.223372036854775808e18 &&
      r < 9.223372036854775808e18)
    return (int64_t)r;
  char x[400], msg[500];
  ren_format_float(x, f);
  snprintf(msg, sizeof msg, "`%s` of %s doesn't fit in an `Int`", how, x);
  ren_panic(site, msg);
}

int64_t ren_fround(double a, const ren_site *site) {
  return ren_to_int(round(a), a, "round", site);
}

int64_t ren_ftruncate(double a, const ren_site *site) {
  return ren_to_int(trunc(a), a, "truncate", site);
}

/* ---- descriptors ---- */

const char *const *ren_tag_names;

/* [d] with each parameter it names replaced by what [*env] gives it, and
   [*env] made what that's read under. */
static const ren_desc *ren_resolve(const ren_desc *d, const ren_tenv **env) {
  while (d->kind == REN_D_VAR) {
    d = (*env)->args[d->var];
    *env = (*env)->up;
  }
  return d;
}

static bool ren_counted_in(const ren_desc *d, const ren_tenv *env) {
  d = ren_resolve(d, &env);
  if (d->kind == REN_D_NAMED && d->decl->kind == REN_DECL_REP) {
    ren_tenv inner = {d->args, env};
    return ren_counted_in(d->decl->rep, &inner);
  }
  return d->counted;
}

ren_obj *ren_desc_new(uint8_t kind, const ren_decl *decl, int64_t nargs,
                      ren_obj *const *args) {
  size_t bytes = sizeof(ren_desc) + (size_t)nargs * sizeof(ren_desc *);
  ren_desc *d = ren_alloc_bytes(bytes);
#ifdef REN_STATS
  ren_count_alloc((int64_t)bytes);
#endif
  ren_desc **kept = (ren_desc **)(d + 1);
  for (int64_t i = 0; i < nargs; i++) {
    ren_dup(args[i]);
    kept[i] = (ren_desc *)args[i];
  }
  d->h.rc = 1;
  d->h.tag = REN_TAG_DESC;
  d->h.nfields = 0;
  d->h.objs = 0;
  d->kind = kind;
  d->nargs = (uint16_t)nargs;
  d->var = 0;
  d->decl = decl;
  d->args = kept;
  switch (kind) {
  case REN_D_NAMED: {
    ren_tenv env = {d->args, NULL};
    if (decl->kind == REN_DECL_REP)
      d->counted = ren_counted_in(decl->rep, &env);
    else
      d->counted = !decl->enumlike;
    break;
  }
  default: /* an array or a tuple */
    d->counted = 1;
  }
  return &d->h;
}

/* A string being built, which grows as it's written to. */
typedef struct {
  char *data;
  size_t len, cap;
} ren_buf;

static void ren_put(ren_buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    while (b->len + n + 1 > b->cap)
      b->cap = b->cap ? b->cap * 2 : 64;
    b->data = realloc(b->data, b->cap);
    if (b->data == NULL) {
      fflush(stdout);
      fputs("error: out of memory\n", stderr);
      exit(1);
    }
  }
  memcpy(b->data + b->len, s, n);
  b->len += n;
  b->data[b->len] = 0;
}

static void ren_puts(ren_buf *b, const char *s) { ren_put(b, s, strlen(s)); }

/* A `Str` as it's written, in quotes: token.ml's `show_str`. */
static void ren_put_quoted(ren_buf *b, ren_obj *s) {
  ren_puts(b, "\"");
  const char *d = ren_str_data(s);
  for (int64_t i = 0; i < ren_str_len(s); i++) {
    switch (d[i]) {
    case '\n':
      ren_puts(b, "\\n");
      break;
    case '\t':
      ren_puts(b, "\\t");
      break;
    case '\\':
      ren_puts(b, "\\\\");
      break;
    case '"':
      ren_puts(b, "\\\"");
      break;
    default:
      ren_put(b, &d[i], 1);
    }
  }
  ren_puts(b, "\"");
}

/* The tag of a sum type's value, an object's or the scalar's. */
static int64_t ren_ctor_tag(const ren_decl *decl, ren_val v) {
  return decl->enumlike ? v.i : ren_tag(v.o);
}

/* A walk's site: where a NaN it finds panics, and what it says; whether
   it goes through a type's `key` ([keyed]), as `==`, ordering and `hash`
   do, and, hashing, whether it's `x.hash()`'s, with no seed ([fixed]). */
typedef struct {
  const ren_site *site;
  const char *what;
  bool keyed;
  bool fixed;
} ren_walk;

/* [v]'s key, a word the caller owns, through its type's [decl]. */
static inline ren_val ren_key_of(const ren_decl *decl, ren_val v) {
  return decl->key(v);
}
static inline void ren_key_done(const ren_decl *decl, ren_val k) {
  ren_drop_val(k, &decl->keyd->h);
}

/* A map's live entries, in order: [e] each one's words, its hash first. */
#define REN_MAP_EACH(map, e)                                                  \
  for (ren_val *e = (map)->entries,                                           \
               *e##_end = e == NULL ? e : e + (map)->used * (map)->width;     \
       e < e##_end; e += (map)->width)                                        \
    if (e[0].i != 0)

static int64_t ren_map_find_in(ren_map *m, ren_val k, const ren_desc *kd,
                               const ren_tenv *env, const ren_walk *w);

/* [f], unless it's a NaN, which panics as [w] says. */
static inline void ren_walk_float(const ren_walk *w, double f) {
  if (__builtin_expect(isnan(f), 0))
    ren_nan_panic(w->site, w->what, f);
}

static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v, const ren_walk *w);

/* Each of [n] fields of [o], of the types [types] read under [env], with
   [names] before them if there are any; where they are is [c]'s, if
   there's one. */
static void ren_show_fields(ren_buf *b, ren_obj *o, const ren_ctor_info *c,
                            int32_t n, const char *const *names,
                            ren_desc *const *types, const ren_tenv *env,
                            const ren_walk *w) {
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    if (names != NULL) {
      ren_puts(b, names[i]);
      ren_puts(b, ": ");
    }
    ren_show_val(b, types[i], env, ren_ctor_field(o, c, i), w);
  }
}

/* An error: its tag, and its payload, through the descriptors it keeps
   after it. */
static void ren_show_error(ren_buf *b, ren_obj *e, const ren_walk *w) {
  ren_puts(b, ren_tag_names[ren_tag(e)]);
  if (ren_is_scalar(e))
    return;
  int32_t n = (int32_t)e->nfields / 2;
  ren_puts(b, "(");
  for (int32_t i = 0; i < n; i++) {
    if (i > 0)
      ren_puts(b, ", ");
    ren_show_val(b, (ren_desc *)ren_fields(e)[n + i].o, NULL,
                 ren_fields(e)[i], w);
  }
  ren_puts(b, ")");
}

/* [v] as it's written: shown.ml's `value`. */
static void ren_show_val(ren_buf *b, const ren_desc *d, const ren_tenv *env,
                         ren_val v, const ren_walk *w) {
  char num[400];
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_INT:
    snprintf(num, sizeof num, "%" PRId64, v.i);
    ren_puts(b, num);
    break;
  case REN_D_FLOAT:
    ren_walk_float(w, v.f);
    ren_format_float(num, v.f);
    ren_puts(b, num);
    break;
  /* a sized type's value, as a word, is the number it holds */
  case REN_D_SIZED:
    if (d->var == REN_ELEM_F32) {
      ren_walk_float(w, v.f);
      ren_format_float(num, v.f);
    } else
      snprintf(num, sizeof num, "%" PRId64, v.i);
    ren_puts(b, num);
    break;
  case REN_D_BOOL:
    ren_puts(b, v.i ? "true" : "false");
    break;
  case REN_D_UNIT:
  case REN_D_UNKNOWN:
    ren_puts(b, "()");
    break;
  case REN_D_STR:
    ren_put_quoted(b, v.o);
    break;
  case REN_D_BYTES: { /* value.ml's `show`: each byte in hex */
    ren_puts(b, "<bytes");
    for (int64_t i = 0; i < ren_str_len(v.o); i++) {
      char hex[8];
      snprintf(hex, sizeof hex, " %02x",
               (unsigned char)ren_str_data(v.o)[i]);
      ren_puts(b, hex);
    }
    ren_puts(b, ">");
    break;
  }
  case REN_D_ARRAY: {
    ren_array *a = (ren_array *)v.o;
    ren_puts(b, "[");
    for (int64_t i = 0; i < a->len; i++) {
      if (i > 0)
        ren_puts(b, ", ");
      ren_show_val(b, d->args[0], env, ren_array_load(v.o, i), w);
    }
    ren_puts(b, "]");
    break;
  }
  case REN_D_TUPLE:
    ren_puts(b, "(");
    ren_show_fields(b, v.o, NULL, d->nargs, NULL, d->args, env, w);
    ren_puts(b, ")");
    break;
  case REN_D_ERRORS:
    ren_show_error(b, v.o, w);
    break;
  /* as value.ml shows one */
  case REN_D_HANDLER:
    ren_puts(b, "<handler>");
    break;
  /* as it's made, in order (shown.ml) */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    bool set = d->kind == REN_D_SET;
    ren_puts(b, set ? "Set.of([" : "Map.of([");
    bool first = true;
    REN_MAP_EACH(m, e) {
      if (!first)
        ren_puts(b, ", ");
      first = false;
      if (set)
        ren_show_val(b, d->args[0], env, e[1], w);
      else {
        ren_puts(b, "(");
        ren_show_val(b, d->args[0], env, e[1], w);
        ren_puts(b, ", ");
        ren_show_val(b, d->args[1], env, e[2], w);
        ren_puts(b, ")");
      }
    }
    ren_puts(b, "])");
    break;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->kind == REN_DECL_REP) {
      ren_puts(b, decl->name);
      ren_puts(b, "(");
      ren_show_val(b, decl->rep, &inner, v, w);
      ren_puts(b, ")");
    } else if (decl->kind == REN_DECL_RECORD) {
      const ren_ctor_info *c = &decl->ctors[0];
      ren_puts(b, decl->name);
      ren_puts(b, decl->opaque ? "(" : " { ");
      ren_show_fields(b, v.o, c, c->nfields, c->fields, c->types, &inner, w);
      ren_puts(b, decl->opaque ? ")" : " }");
    } else {
      /* a by-name constructor's fields after their names, in braces,
         as it's built: `Rect { w: 2, h: 3 }` */
      const ren_ctor_info *c = &decl->ctors[ren_ctor_tag(decl, v)];
      ren_puts(b, c->name);
      if (c->nfields > 0) {
        ren_puts(b, c->fields != NULL ? " { " : "(");
        ren_show_fields(b, v.o, c, c->nfields, c->fields, c->types, &inner, w);
        ren_puts(b, c->fields != NULL ? " }" : ")");
      }
    }
    break;
  }
  }
}

ren_obj *ren_show_any(ren_obj *d, ren_val v, const ren_site *site) {
  if (((ren_desc *)d)->kind == REN_D_STR) {
    ren_dup(v.o);
    return v.o;
  }
  ren_walk w = {site, "`show` of a NaN", false, false};
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v, &w);
  ren_obj *s = ren_str_of(b.data, (int64_t)b.len);
  free(b.data);
  return s;
}

void ren_print_value(FILE *out, ren_obj *d, ren_val v, const ren_site *site) {
  ren_walk w = {site, "`show` of a NaN", false, false};
  ren_buf b = {NULL, 0, 0};
  ren_show_val(&b, (ren_desc *)d, NULL, v, &w);
  fwrite(b.data, 1, b.len, out);
  free(b.data);
}

void ren_print_result(ren_obj *d, ren_val v, const ren_site *site) {
  ren_print_value(stdout, d, v, site);
  fputc('\n', stdout);
}

static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b, const ren_walk *w);

static bool ren_equal_fields(ren_obj *a, ren_obj *b, const ren_ctor_info *c,
                             int32_t n, ren_desc *const *types,
                             const ren_tenv *env, const ren_walk *w) {
  for (int32_t i = 0; i < n; i++)
    if (!ren_equal_in(types[i], env, ren_ctor_field(a, c, i),
                      ren_ctor_field(b, c, i), w))
      return false;
  return true;
}

/* walk.ml's `equal`, part by part. */
static bool ren_equal_in(const ren_desc *d, const ren_tenv *env, ren_val a,
                         ren_val b, const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return a.f == b.f;
  case REN_D_SIZED:
    if (d->var != REN_ELEM_F32)
      return a.i == b.i;
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return a.f == b.f;
  case REN_D_STR:
  case REN_D_BYTES:
    return ren_str_eq(a.o, b.o);
  case REN_D_ARRAY: {
    ren_array *x = (ren_array *)a.o, *y = (ren_array *)b.o;
    if (x->len != y->len)
      return false;
    for (int64_t i = 0; i < x->len; i++)
      if (!ren_equal_in(d->args[0], env, ren_array_load(a.o, i),
                        ren_array_load(b.o, i), w))
        return false;
    return true;
  }
  case REN_D_TUPLE:
    return ren_equal_fields(a.o, b.o, NULL, d->nargs, d->args, env, w);
  case REN_D_ERRORS: {
    if (ren_tag(a.o) != ren_tag(b.o))
      return false;
    if (ren_is_scalar(a.o))
      return true;
    int32_t n = (int32_t)a.o->nfields / 2;
    for (int32_t i = 0; i < n; i++)
      if (!ren_equal_in((ren_desc *)ren_fields(a.o)[n + i].o, NULL,
                        ren_fields(a.o)[i], ren_fields(b.o)[i], w))
        return false;
    return true;
  }
  /* the same keys, each with an equal value, in any order (walk.ml) */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *x = (ren_map *)a.o, *y = (ren_map *)b.o;
    if (x->len != y->len)
      return false;
    REN_MAP_EACH(x, e) {
      int64_t i = ren_map_find_in(y, e[1], d->args[0], env, w);
      if (i < 0)
        return false;
      if (d->kind == REN_D_MAP &&
          !ren_equal_in(d->args[1], env, e[2], y->entries[i * y->width + 2], w))
        return false;
    }
    return true;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    /* through its key, the one way to change what equal means */
    if (decl->key != NULL) {
      ren_val ka = ren_key_of(decl, a), kb = ren_key_of(decl, b);
      bool same = ren_equal_in(decl->keyd, NULL, ka, kb, w);
      ren_key_done(decl, ka);
      ren_key_done(decl, kb);
      return same;
    }
    if (decl->kind == REN_DECL_REP)
      return ren_equal_in(decl->rep, &inner, a, b, w);
    if (decl->kind == REN_DECL_RECORD)
      return ren_equal_fields(a.o, b.o, &decl->ctors[0],
                              decl->ctors[0].nfields, decl->ctors[0].types,
                              &inner, w);
    int64_t tag = ren_ctor_tag(decl, a);
    if (tag != ren_ctor_tag(decl, b))
      return false;
    const ren_ctor_info *c = &decl->ctors[tag];
    return c->nfields == 0 ||
           ren_equal_fields(a.o, b.o, c, c->nfields, c->types, &inner, w);
  }
  default: /* an `Int`, a `Bool` or `Unit` */
    return a.i == b.i;
  }
}

static void ren_nan_val(const ren_desc *d, const ren_tenv *env, ren_val v,
                        const ren_walk *w);

/* walk.ml's [equal]: a comparison that ends early, unequal, hasn't met
   every leaf, so it looks through both values for a NaN, [a]'s first;
   comparing a value with one in it panics, met or not. */
bool ren_equal_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                   const ren_site *site) {
  ren_walk w = {site, what, true, false};
  bool same = ren_equal_in((ren_desc *)d, NULL, a, b, &w);
  if (!same) {
    ren_nan_val((ren_desc *)d, NULL, a, &w);
    ren_nan_val((ren_desc *)d, NULL, b, &w);
  }
  return same;
}

#define REN_CMP(x, y) ((x) < (y) ? -1 : (x) > (y) ? 1 : 0)

/* walk.ml's `compare`: what inference allows an order on. */
static int64_t ren_compare_in(const ren_desc *d, const ren_tenv *env,
                              ren_val a, ren_val b, const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return REN_CMP(a.f, b.f);
  case REN_D_SIZED:
    if (d->var != REN_ELEM_F32)
      return REN_CMP(a.i, b.i);
    ren_walk_float(w, a.f);
    ren_walk_float(w, b.f);
    return REN_CMP(a.f, b.f);
  case REN_D_STR:
  case REN_D_BYTES: {
    int64_t la = ren_str_len(a.o), lb = ren_str_len(b.o);
    int c = memcmp(ren_str_data(a.o), ren_str_data(b.o),
                   (size_t)(la < lb ? la : lb));
    return c != 0 ? c : REN_CMP(la, lb);
  }
  case REN_D_TUPLE:
    for (uint16_t i = 0; i < d->nargs; i++) {
      int64_t c = ren_compare_in(d->args[i], env, ren_fields(a.o)[i],
                                 ren_fields(b.o)[i], w);
      if (c != 0)
        return c;
    }
    return 0;
  case REN_D_NAMED: {
    ren_tenv inner = {d->args, env};
    if (d->decl->key != NULL) {
      ren_val ka = ren_key_of(d->decl, a), kb = ren_key_of(d->decl, b);
      int64_t c = ren_compare_in(d->decl->keyd, NULL, ka, kb, w);
      ren_key_done(d->decl, ka);
      ren_key_done(d->decl, kb);
      return c;
    }
    if (d->decl->kind == REN_DECL_REP)
      return ren_compare_in(d->decl->rep, &inner, a, b, w);
    return REN_CMP(ren_ctor_tag(d->decl, a), ren_ctor_tag(d->decl, b));
  }
  default: /* an `Int` or a `Bool` */
    return REN_CMP(a.i, b.i);
  }
}

int64_t ren_compare_any(ren_obj *d, ren_val a, ren_val b, const char *what,
                        const ren_site *site) {
  ren_walk w = {site, what, true, false};
  int64_t c = ren_compare_in((ren_desc *)d, NULL, a, b, &w);
  /* as [ren_equal_any]: an order decided early looks for a NaN */
  if (c != 0) {
    ren_nan_val((ren_desc *)d, NULL, a, &w);
    ren_nan_val((ren_desc *)d, NULL, b, &w);
  }
  return c;
}

/* [xs], [n] words, sorted, through [tmp], as much room again. */
static void ren_merge_sort(ren_obj *d, ren_val *xs, ren_val *tmp, int64_t n,
                           const char *what, const ren_site *site) {
  if (n < 2)
    return;
  int64_t h = n / 2;
  ren_merge_sort(d, xs, tmp, h, what, site);
  ren_merge_sort(d, xs + h, tmp, n - h, what, site);
  int64_t i = 0, j = h, k = 0;
  /* the right one first only if it's less, so equal ones keep their
     order */
  while (i < h && j < n)
    tmp[k++] = ren_compare_any(d, xs[j], xs[i], what, site) < 0 ? xs[j++]
                                                                 : xs[i++];
  while (i < h)
    tmp[k++] = xs[i++];
  while (j < n)
    tmp[k++] = xs[j++];
  memcpy(xs, tmp, (size_t)n * sizeof(ren_val));
}

ren_obj *ren_array_sort(ren_obj *a, ren_obj *d, const char *what,
                        const ren_site *site) {
  int64_t n = ren_array_len(a);
  ren_val *xs = malloc((size_t)(2 * n + 1) * sizeof(ren_val));
  if (xs == NULL)
    ren_out_of_memory();
  for (int64_t i = 0; i < n; i++)
    xs[i] = ren_array_load(a, i);
  ren_merge_sort(d, xs, xs + n, n, what, site);
  ren_obj *r = ren_alloc_array_d(n, d);
  for (int64_t i = 0; i < n; i++) {
    if (r->objs)
      ren_dup(xs[i].o);
    ren_array_init_w(r, i, xs[i]);
  }
  free(xs);
  return r;
}

_Noreturn void ren_panic_str(const ren_site *site, ren_obj *s) {
  int64_t n = ren_str_len(s);
  char *msg = malloc((size_t)n + 1);
  if (msg == NULL)
    ren_out_of_memory();
  memcpy(msg, ren_str_data(s), (size_t)n);
  msg[n] = 0;
  ren_panic(site, msg);
}

/* walk.ml's [nan_in]: the first NaN in [v], in the order its parts are
   declared. */
static void ren_nan_val(const ren_desc *d, const ren_tenv *env, ren_val v,
                        const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_FLOAT:
    ren_walk_float(w, v.f);
    break;
  case REN_D_SIZED:
    if (d->var == REN_ELEM_F32)
      ren_walk_float(w, v.f);
    break;
  case REN_D_ARRAY: {
    ren_array *a = (ren_array *)v.o;
    for (int64_t i = 0; i < a->len; i++)
      ren_nan_val(d->args[0], env, ren_array_load(v.o, i), w);
    break;
  }
  case REN_D_TUPLE:
    for (uint16_t i = 0; i < d->nargs; i++)
      ren_nan_val(d->args[i], env, ren_fields(v.o)[i], w);
    break;
  case REN_D_ERRORS:
    if (!ren_is_scalar(v.o)) {
      int32_t n = (int32_t)v.o->nfields / 2;
      for (int32_t i = 0; i < n; i++)
        ren_nan_val((ren_desc *)ren_fields(v.o)[n + i].o, NULL,
                    ren_fields(v.o)[i], w);
    }
    break;
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    REN_MAP_EACH(m, e) {
      ren_nan_val(d->args[0], env, e[1], w);
      if (d->kind == REN_D_MAP)
        ren_nan_val(d->args[1], env, e[2], w);
    }
    break;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    /* what's compared is seen through its key (walk.ml, [nan_compared]);
       what's given to an operation isn't */
    if (w->keyed && decl->key != NULL) {
      ren_val k = ren_key_of(decl, v);
      ren_nan_val(decl->keyd, NULL, k, w);
      ren_key_done(decl, k);
      break;
    }
    if (decl->kind == REN_DECL_REP) {
      ren_nan_val(decl->rep, &inner, v, w);
      break;
    }
    const ren_ctor_info *c =
        decl->kind == REN_DECL_RECORD ? &decl->ctors[0]
                                      : &decl->ctors[ren_ctor_tag(decl, v)];
    for (int32_t i = 0; i < c->nfields; i++)
      ren_nan_val(c->types[i], &inner, ren_ctor_field(v.o, c, i), w);
    break;
  }
  default:
    break;
  }
}

void ren_nan_in(ren_obj *d, ren_val v, const char *what, const ren_site *site) {
  ren_walk w = {site, what, false, false};
  ren_nan_val((ren_desc *)d, NULL, v, &w);
}

/* ---- hashing ----

   Two walks over a value, which agree with `==` (walk.ml, [hash]): by
   its key if its type has one; an `Int` as its 64 bits; a `Float` as its
   bits, `-0.0` as `0.0`, a NaN panicking; a `Str` or `Bytes` by its
   bytes; a record, a tuple, a constructor, an array, an error by its
   parts in order, each mixed in; a map or a set by its entries' hashes
   added, so the same in any order. [fixed] is `x.hash()`'s, walk.ml's
   with the seed 0, FNV-1a's step, the same bits as the interpreter's.
   The other is a map's, a wyhash-class mix with [ren_map_seed]. */

uint64_t ren_map_seed;

#define REN_FNV_PRIME UINT64_C(0x100000001b3)
#define REN_FNV_BASIS UINT64_C(0xcbf29ce484222325)
#define REN_WY0 UINT64_C(0x2d358dccaa6c78a5)
#define REN_WY1 UINT64_C(0x8bb84b93962eacc9)
#define REN_WY2 UINT64_C(0x4b33a62ed433d4a3)

/* [a] times [b], 128 bits, its halves xored: wyhash's `mum`. tcc has no
   128-bit type, so it multiplies the halves; both give the same bits. */
static inline uint64_t ren_mum(uint64_t a, uint64_t b) {
#ifdef __SIZEOF_INT128__
  __uint128_t r = (__uint128_t)a * b;
  return (uint64_t)r ^ (uint64_t)(r >> 64);
#else
  uint64_t ha = a >> 32, la = (uint32_t)a, hb = b >> 32, lb = (uint32_t)b;
  uint64_t rh = ha * hb, rm0 = ha * lb, rm1 = hb * la, rl = la * lb;
  uint64_t t = rl + (rm0 << 32), c = t < rl;
  uint64_t lo = t + (rm1 << 32);
  c += lo < t;
  uint64_t hi = rh + (rm0 >> 32) + (rm1 >> 32) + c;
  return lo ^ hi;
#endif
}

static inline uint64_t ren_read8(const unsigned char *p) {
  uint64_t v;
  memcpy(&v, p, 8);
  return v;
}
static inline uint64_t ren_read4(const unsigned char *p) {
  uint32_t v;
  memcpy(&v, p, 4);
  return v;
}

/* [n] bytes at [p], seeded: wyhash's (final version 4), which reads 16
   bytes a step and at most two overlapping loads for what's left. */
static uint64_t ren_wyhash(const unsigned char *p, size_t n, uint64_t seed) {
  seed ^= ren_mum(seed ^ REN_WY0, REN_WY1);
  uint64_t a, b;
  if (n <= 16) {
    if (n >= 4) {
      size_t k = (n >> 3) << 2;
      a = (ren_read4(p) << 32) | ren_read4(p + k);
      b = (ren_read4(p + n - 4) << 32) | ren_read4(p + n - 4 - k);
    } else if (n > 0) {
      a = ((uint64_t)p[0] << 16) | ((uint64_t)p[n >> 1] << 8) | p[n - 1];
      b = 0;
    } else
      a = b = 0;
  } else {
    size_t i = n;
    while (i > 16) {
      seed = ren_mum(ren_read8(p) ^ REN_WY1, ren_read8(p + 8) ^ seed);
      p += 16;
      i -= 16;
    }
    a = ren_read8(p + i - 16);
    b = ren_read8(p + i - 8);
  }
  return ren_mum(REN_WY1 ^ n, ren_mum(a ^ REN_WY1, b ^ seed));
}

/* Two hashes made one, so each part's place counts: walk.ml's [mix]. */
static inline uint64_t ren_mix(const ren_walk *w, uint64_t h, uint64_t x) {
  return w->fixed ? (h ^ x) * REN_FNV_PRIME
                  : ren_mum(h ^ x ^ REN_WY0, ren_map_seed ^ REN_WY1);
}

/* A string's bytes: walk.ml's [hash_string], or seeded. */
static uint64_t ren_hash_chars(const ren_walk *w, const char *s, int64_t n) {
  if (!w->fixed)
    return ren_wyhash((const unsigned char *)s, (size_t)n, ren_map_seed);
  uint64_t h = REN_FNV_BASIS;
  for (int64_t i = 0; i < n; i++)
    h = (h ^ (unsigned char)s[i]) * REN_FNV_PRIME;
  return h;
}

static uint64_t ren_hash_in(const ren_desc *d, const ren_tenv *env, ren_val v,
                            const ren_walk *w);

/* A `Float`'s: `-0.0` is `0.0`, which `==` says it equals. */
static inline uint64_t ren_hash_float(const ren_walk *w, double f) {
  ren_walk_float(w, f);
  uint64_t bits;
  if (f == 0)
    f = 0;
  memcpy(&bits, &f, 8);
  return ren_mix(w, 2, bits);
}

/* [h] with each of [n] fields of [o] mixed in, in order. */
static uint64_t ren_hash_fields(uint64_t h, ren_obj *o, const ren_ctor_info *c,
                                int32_t n, ren_desc *const *types,
                                const ren_tenv *env, const ren_walk *w) {
  for (int32_t i = 0; i < n; i++)
    h = ren_mix(w, h, ren_hash_in(types[i], env, ren_ctor_field(o, c, i), w));
  return h;
}

static uint64_t ren_hash_in(const ren_desc *d, const ren_tenv *env, ren_val v,
                            const ren_walk *w) {
  d = ren_resolve(d, &env);
  switch (d->kind) {
  case REN_D_INT:
    return ren_mix(w, 1, (uint64_t)v.i);
  case REN_D_FLOAT:
    return ren_hash_float(w, v.f);
  case REN_D_SIZED:
    return d->var == REN_ELEM_F32 ? ren_hash_float(w, v.f)
                                  : ren_mix(w, 1, (uint64_t)v.i);
  case REN_D_STR:
    return ren_mix(w, 3, ren_hash_chars(w, ren_str_data(v.o), ren_str_len(v.o)));
  case REN_D_BYTES:
    return ren_mix(w, 4, ren_hash_chars(w, ren_str_data(v.o), ren_str_len(v.o)));
  case REN_D_BOOL:
    return ren_mix(w, 5, v.i ? 1 : 0);
  case REN_D_ARRAY: {
    uint64_t h = 9;
    for (int64_t i = 0; i < ren_array_len(v.o); i++)
      h = ren_mix(w, h, ren_hash_in(d->args[0], env, ren_array_load(v.o, i), w));
    return h;
  }
  case REN_D_TUPLE:
    return ren_hash_fields(11, v.o, NULL, d->nargs, d->args, env, w);
  case REN_D_ERRORS: {
    const char *name = ren_tag_names[ren_tag(v.o)];
    uint64_t h = ren_mix(w, 10, ren_hash_chars(w, name, (int64_t)strlen(name)));
    if (ren_is_scalar(v.o))
      return h;
    int32_t n = (int32_t)v.o->nfields / 2;
    for (int32_t i = 0; i < n; i++)
      h = ren_mix(w, h,
                  ren_hash_in((ren_desc *)ren_fields(v.o)[n + i].o, NULL,
                              ren_fields(v.o)[i], w));
    return h;
  }
  /* each entry's hash, added, so the same in any order, as `==` is */
  case REN_D_MAP:
  case REN_D_SET: {
    ren_map *m = (ren_map *)v.o;
    uint64_t h = d->kind == REN_D_MAP ? 12 : 13;
    REN_MAP_EACH(m, e) {
      uint64_t k = ren_hash_in(d->args[0], env, e[1], w);
      h += d->kind == REN_D_MAP
               ? ren_mix(w, k, ren_hash_in(d->args[1], env, e[2], w))
               : k;
    }
    return h;
  }
  case REN_D_NAMED: {
    const ren_decl *decl = d->decl;
    ren_tenv inner = {d->args, env};
    if (decl->key != NULL) {
      ren_val k = ren_key_of(decl, v);
      uint64_t h = ren_hash_in(decl->keyd, NULL, k, w);
      ren_key_done(decl, k);
      return h;
    }
    if (decl->kind == REN_DECL_REP)
      return ren_hash_in(decl->rep, &inner, v, w);
    if (decl->kind == REN_DECL_RECORD)
      return ren_hash_fields(7, v.o, &decl->ctors[0], decl->ctors[0].nfields,
                             decl->ctors[0].types, &inner, w);
    int64_t tag = ren_ctor_tag(decl, v);
    const ren_ctor_info *c = &decl->ctors[tag];
    uint64_t h = ren_mix(w, 8, (uint64_t)tag);
    return c->nfields == 0
               ? h
               : ren_hash_fields(h, v.o, c, c->nfields, c->types, &inner, w);
  }
  default: /* `Unit`, and a type variable nothing decided */
    return 6;
  }
}

int64_t ren_hash_fixed(ren_obj *d, ren_val v, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, true};
  return (int64_t)ren_hash_in((ren_desc *)d, NULL, v, &w);
}

/* ---- maps and sets ---- */

/* A key's hash, as a map keeps it: never 0, which marks a removed
   entry. An `Int`'s and a `Str`'s without the walk's switch. */
static inline uint64_t ren_key_hash(const ren_desc *kd, const ren_tenv *env,
                                    ren_val k, const ren_walk *w) {
  uint64_t h;
  switch (kd->kind) {
  case REN_D_INT:
    h = ren_mix(w, 1, (uint64_t)k.i);
    break;
  case REN_D_STR:
    h = ren_mix(w, 3, ren_wyhash((const unsigned char *)ren_str_data(k.o),
                                 (size_t)ren_str_len(k.o), ren_map_seed));
    break;
  default:
    h = ren_hash_in(kd, env, k, w);
  }
  return h ? h : 1;
}

/* Two keys the same: [ren_equal_in], an `Int`'s and a `Str`'s without
   its switch. */
static inline bool ren_key_eq(const ren_desc *kd, const ren_tenv *env,
                              ren_val a, ren_val b, const ren_walk *w) {
  switch (kd->kind) {
  case REN_D_INT:
    return a.i == b.i;
  case REN_D_STR:
    return ren_str_eq(a.o, b.o);
  default:
    return ren_equal_in(kd, env, a, b, w);
  }
}

/* [n] entries' and [slots] slots' bytes, for the statistics. */
static inline int64_t ren_map_bytes(int64_t cap, int32_t width, int32_t shift) {
  return cap * width * (int64_t)sizeof(ren_val) +
         (shift ? ((int64_t)1 << shift) * (int64_t)sizeof(int32_t) : 0);
}

ren_obj *ren_map_new(bool set) {
  ren_map *m = ren_alloc_bytes(sizeof(ren_map));
#ifdef REN_STATS
  ren_count_alloc((int64_t)sizeof(ren_map));
#endif
  m->h.rc = 1;
  m->h.tag = REN_TAG_MAP;
  m->h.nfields = set;
  m->h.objs = 0;
  m->len = m->used = m->cap = 0;
  m->shift = 0;
  m->width = set ? 2 : 3;
  m->entries = NULL;
  m->index = NULL;
  return &m->h;
}

/* The index made again for [m]'s entries, its size for [m->cap] of them,
   at most 2/3 full: each entry's slot found from the hash it keeps. */
static void ren_map_reindex(ren_map *m) {
  int32_t shift = 3;
  while (((int64_t)1 << shift) * 2 < m->cap * 3)
    shift++;
  if (shift != m->shift) {
#ifdef REN_STATS
    ren_stats.live_bytes += ren_map_bytes(0, 0, shift) - ren_map_bytes(0, 0, m->shift);
    if (ren_stats.live_bytes > ren_stats.peak_bytes)
      ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
    free(m->index);
    m->index = ren_malloc(((size_t)1 << shift) * sizeof(int32_t));
    m->shift = shift;
  }
  uint64_t mask = ((uint64_t)1 << shift) - 1;
  memset(m->index, 0xFF, ((size_t)1 << shift) * sizeof(int32_t));
  for (int64_t e = 0; e < m->used; e++) {
    uint64_t h = (uint64_t)m->entries[e * m->width].i;
    if (h == 0)
      continue;
    uint64_t i = h >> (64 - shift);
    while (m->index[i] != REN_MAP_EMPTY)
      i = (i + 1) & mask;
    m->index[i] = (int32_t)e;
  }
}

/* The removed entries taken out, the live ones kept in order. */
static void ren_map_compact(ren_map *m) {
  int64_t to = 0;
  for (int64_t e = 0; e < m->used; e++)
    if (m->entries[e * m->width].i != 0) {
      if (to != e)
        memcpy(&m->entries[to * m->width], &m->entries[e * m->width],
               (size_t)m->width * sizeof(ren_val));
      to++;
    }
  m->used = to;
}

/* Room for one entry more in [m], unique: its entries compacted if a
   third or more are removed, or else doubled, and the index made again.
   The index's slots are 32 bits, so a map has at most 2^31 - 1. */
static void ren_map_room(ren_map *m) {
  if (m->used < m->cap)
    return;
  int64_t removed = m->used - m->len;
  int64_t cap = m->cap;
  if (m->used == 0 || removed * 3 < m->used)
    cap = cap < 8 ? 8 : cap * 2;
  if (cap > INT32_MAX) {
    fflush(stdout);
    fputs("error: a `Map` or a `Set` of more than 2^31 - 1 entries isn't "
          "built yet\n",
          stderr);
    exit(1);
  }
  ren_map_compact(m);
  if (cap != m->cap) {
    ren_val *entries =
        realloc(m->entries, (size_t)cap * (size_t)m->width * sizeof(ren_val));
    if (entries == NULL)
      ren_out_of_memory();
#ifdef REN_STATS
    ren_stats.grows++;
    ren_stats.live_bytes += (cap - m->cap) * m->width * (int64_t)sizeof(ren_val);
    if (ren_stats.live_bytes > ren_stats.peak_bytes)
      ren_stats.peak_bytes = ren_stats.live_bytes;
#endif
    m->entries = entries;
    m->cap = cap;
  }
  ren_map_reindex(m);
}

/* The entry whose key is [k], of hash [h], or -1, with [*slot] the
   empty slot the probe ended at. */
static inline int64_t ren_map_probe(ren_map *m, uint64_t h, ren_val k,
                                    const ren_desc *kd, const ren_tenv *env,
                                    const ren_walk *w, uint64_t *slot) {
  if (m->shift == 0)
    return -1;
  uint64_t mask = ((uint64_t)1 << m->shift) - 1;
  uint64_t i = h >> (64 - m->shift);
  for (;; i = (i + 1) & mask) {
    int32_t e = m->index[i];
    if (e == REN_MAP_EMPTY) {
      *slot = i;
      return -1;
    }
    if (e >= 0) {
      ren_val *ent = &m->entries[(int64_t)e * m->width];
      if ((uint64_t)ent[0].i == h && ren_key_eq(kd, env, ent[1], k, w))
        return e;
    }
  }
}

static int64_t ren_map_find_in(ren_map *m, ren_val k, const ren_desc *kd,
                               const ren_tenv *env, const ren_walk *w) {
  uint64_t slot;
  /* a key's type's descriptor read under [env] hashes as the map's own
     did, which had it resolved */
  const ren_desc *rd = ren_resolve(kd, &env);
  return ren_map_probe(m, ren_key_hash(rd, env, k, w), k, rd, env, w, &slot);
}

int64_t ren_map_find(ren_obj *m, ren_val k, ren_obj *kd, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  uint64_t slot;
  const ren_desc *d = (const ren_desc *)kd;
  return ren_map_probe((ren_map *)m, ren_key_hash(d, NULL, k, &w), k, d, NULL,
                       &w, &slot);
}

/* A copy of [m] with room for [extra] entries more, its removed ones
   left out, each key and value counted again. */
static ren_map *ren_map_copy(ren_map *m, int64_t extra) {
  ren_map *c = (ren_map *)ren_map_new(m->h.nfields);
  c->h.objs = m->h.objs;
  int64_t cap = m->len + extra;
  c->cap = cap < 8 ? 8 : cap;
  c->entries = ren_malloc((size_t)c->cap * (size_t)c->width * sizeof(ren_val));
#ifdef REN_STATS
  ren_stats.live_bytes += c->cap * c->width * (int64_t)sizeof(ren_val);
#endif
  int64_t to = 0;
  REN_MAP_EACH(m, e) {
    memcpy(&c->entries[to * c->width], e, (size_t)c->width * sizeof(ren_val));
    if (m->h.objs & 1)
      ren_dup(e[1].o);
    if ((m->h.objs & 2) && c->width > 2)
      ren_dup(e[2].o);
    to++;
  }
  c->len = c->used = to;
  ren_map_reindex(c);
  return c;
}

/* [*cell], which is to change: itself if it's unique and [taking], and
   otherwise a copy, with room for one entry more, put in the cell. */
static ren_map *ren_map_writable(ren_obj **cell, bool taking) {
  ren_obj *o = *cell;
  if (taking && ren_is_unique(o))
    return (ren_map *)o;
  ren_map *c = ren_map_copy((ren_map *)o, 1);
  ren_drop(o);
  *cell = &c->h;
  return c;
}

/* [k] set to [v] in [m], unique, [k] of hash [h]: [owned] says whether
   [k] and [v] are taken or counted again where they're kept. */
static void ren_map_put(ren_map *m, uint64_t h, ren_val k, ren_val v,
                        const ren_desc *kd, const ren_walk *w, bool owned) {
  uint64_t slot;
  int64_t e = ren_map_probe(m, h, k, kd, NULL, w, &slot);
  bool kobj = m->h.objs & 1, vobj = m->h.objs & 2;
  if (e >= 0) {
    /* there: its first key stays, with the new value */
    if (owned && kobj)
      ren_drop(k.o);
    if (m->width > 2) {
      ren_val *at = &m->entries[e * m->width + 2];
      if (!owned && vobj)
        ren_dup(v.o);
      if (vobj)
        ren_drop(at->o);
      *at = v;
    } else if (owned && vobj)
      ren_drop(v.o);
    return;
  }
  if (m->used == m->cap) {
    ren_map_room(m);
    ren_map_probe(m, h, k, kd, NULL, w, &slot);
  }
  if (!owned) {
    if (kobj)
      ren_dup(k.o);
    if (vobj && m->width > 2)
      ren_dup(v.o);
  }
  ren_val *ent = &m->entries[m->used * m->width];
  ent[0].i = (int64_t)h;
  ent[1] = k;
  if (m->width > 2)
    ent[2] = v;
  m->index[slot] = (int32_t)m->used;
  m->used++;
  m->len++;
}

/* Whether a map of keys [kd] and values [vd] counts them. */
static inline uint8_t ren_map_objs(ren_obj *kd, ren_obj *vd) {
  return (uint8_t)((ren_desc_counted(kd) ? 1 : 0) |
                   (vd != NULL && ren_desc_counted(vd) ? 2 : 0));
}

void ren_map_set(ren_obj **cell, ren_val k, ren_val v, ren_obj *kd,
                 ren_obj *vd, bool taking, const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  /* hashed first, so a NaN panics before anything changes */
  uint64_t h = ren_key_hash((ren_desc *)kd, NULL, k, &w);
  ren_map *m = ren_map_writable(cell, taking);
  m->h.objs = ren_map_objs(kd, vd);
  ren_map_put(m, h, k, v, (ren_desc *)kd, &w, taking);
}

void ren_map_remove(ren_obj **cell, ren_val k, ren_obj *kd, bool taking,
                    const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  const ren_desc *d = (const ren_desc *)kd;
  uint64_t h = ren_key_hash(d, NULL, k, &w), slot;
  if (ren_map_probe((ren_map *)*cell, h, k, d, NULL, &w, &slot) < 0)
    return;
  ren_map *m = ren_map_writable(cell, taking);
  int64_t e = ren_map_probe(m, h, k, d, NULL, &w, &slot);
  /* its slot is the one the probe found it at, marked removed */
  uint64_t mask = ((uint64_t)1 << m->shift) - 1;
  uint64_t i = h >> (64 - m->shift);
  while (m->index[i] != (int32_t)e)
    i = (i + 1) & mask;
  m->index[i] = REN_MAP_GONE;
  ren_val *ent = &m->entries[e * m->width];
  if (m->h.objs & 1)
    ren_drop(ent[1].o);
  if ((m->h.objs & 2) && m->width > 2)
    ren_drop(ent[2].o);
  ent[0].i = 0;
  m->len--;
}

ren_obj *ren_map_of(ren_obj *pairs, ren_obj *kd, ren_obj *vd, bool flat,
                    const ren_site *site) {
  ren_walk w = {site, "`hash` of a NaN", true, false};
  bool set = vd == NULL;
  ren_map *m = (ren_map *)ren_map_new(set);
  m->h.objs = ren_map_objs(kd, vd);
  int64_t n = ren_array_len(pairs);
  for (int64_t i = 0; i < n; i++) {
    ren_val k, v = {0};
    if (set)
      k = ren_array_load(pairs, i);
    else if (flat) {
      k = ren_elems(pairs)[2 * i];
      v = ren_elems(pairs)[2 * i + 1];
    } else {
      ren_obj *t = ren_elems(pairs)[i].o;
      k = ren_fields(t)[0];
      v = ren_fields(t)[1];
    }
    ren_map_put(m, ren_key_hash((ren_desc *)kd, NULL, k, &w), k, v,
                (ren_desc *)kd, &w, false);
  }
  return &m->h;
}

ren_obj *ren_map_entries(ren_obj *o, bool flat) {
  ren_map *m = (ren_map *)o;
  if (flat) {
    /* never counted: [flat] only for two words that hold no object */
    ren_obj *a = ren_alloc_array_n(m->len, 2, 0);
    int64_t i = 0;
    REN_MAP_EACH(m, e) {
      ren_elems(a)[2 * i] = e[1];
      ren_elems(a)[2 * i + 1] = e[2];
      i++;
    }
    return a;
  }
  ren_obj *a = ren_alloc_array(m->len, true);
  int64_t i = 0;
  REN_MAP_EACH(m, e) {
    /* a tuple's fields that hold objects, as the map's do */
    ren_obj *t = ren_alloc_ctor(0, 2, o->objs);
    ren_fields(t)[0] = e[1];
    ren_fields(t)[1] = e[2];
    if (o->objs & 1)
      ren_dup(e[1].o);
    if (o->objs & 2)
      ren_dup(e[2].o);
    ren_elems(a)[i++].o = t;
  }
  return a;
}

/* Word [at] of each live entry of [o], as an array of [d]'s, counted
   again if [counted]. */
static ren_obj *ren_map_column(ren_obj *o, ren_obj *d, int at, bool counted) {
  ren_map *m = (ren_map *)o;
  ren_obj *a = ren_alloc_array_d(m->len, d);
  int64_t i = 0;
  REN_MAP_EACH(m, e) {
    if (counted)
      ren_dup(e[at].o);
    ren_array_init_w(a, i++, e[at]);
  }
  return a;
}

ren_obj *ren_map_keys(ren_obj *m, ren_obj *d) {
  return ren_map_column(m, d, 1, m->objs & 1);
}

ren_obj *ren_map_values(ren_obj *m, ren_obj *d) {
  return ren_map_column(m, d, 2, m->objs & 2);
}

/* The seed, from the system's randomness, once, when the program
   starts: /dev/urandom, which every system the runtime builds on has; if
   it can't be read, two addresses, which differ from run to run where
   the system places a program at random. */
static void ren_map_seed_init(void) {
  FILE *f = fopen("/dev/urandom", "rb");
  uint64_t s = 0;
  if (f == NULL || fread(&s, sizeof s, 1, f) != 1)
    s = (uint64_t)(uintptr_t)&s ^ ((uint64_t)(uintptr_t)&ren_map_seed << 17);
  if (f != NULL)
    fclose(f);
  ren_map_seed = s;
}

/* Whether a number type is a `Float`, or represented as one, rather
   than an `Int`. */
static bool ren_is_float(const ren_desc *d, const ren_tenv *env) {
  d = ren_resolve(d, &env);
  if (d->kind == REN_D_NAMED) {
    ren_tenv inner = {d->args, env};
    return ren_is_float(d->decl->rep, &inner);
  }
  return d->kind == REN_D_FLOAT;
}

ren_val ren_op_any(ren_obj *d, int op, ren_val a, ren_val b,
                   const ren_site *site, uint32_t tag) {
  ren_val r;
  if (ren_is_float((ren_desc *)d, NULL)) {
    switch (op) {
    case REN_OP_ADD:
      r.f = ren_fadd_d(a.f, b.f, tag);
      break;
    case REN_OP_SUB:
      r.f = ren_fsub_d(a.f, b.f, tag);
      break;
    case REN_OP_MUL:
      r.f = ren_fmul_d(a.f, b.f, tag);
      break;
    case REN_OP_DIV:
      r.f = ren_fdiv_d(a.f, b.f, tag);
      break;
    case REN_OP_REM:
      r.f = ren_frem_d(a.f, b.f, tag);
      break;
    default:
      r.f = -a.f;
    }
  } else {
    switch (op) {
    case REN_OP_ADD:
      r.i = ren_add(a.i, b.i, site);
      break;
    case REN_OP_SUB:
      r.i = ren_sub(a.i, b.i, site);
      break;
    case REN_OP_MUL:
      r.i = ren_mul(a.i, b.i, site);
      break;
    case REN_OP_DIV:
      r.i = ren_div(a.i, b.i, site);
      break;
    case REN_OP_REM:
      r.i = ren_rem(a.i, b.i, site);
      break;
    default:
      r.i = ren_neg(a.i, site);
    }
  }
  return r;
}

ren_val ren_value_any(ren_obj *d, bool one) {
  ren_val r;
  if (ren_is_float((ren_desc *)d, NULL))
    r.f = one ? 1.0 : 0.0;
  else
    r.i = one ? 1 : 0;
  return r;
}

/* Any error: one keeps its payload's descriptors. */
static ren_desc ren_errors_desc = {
    {0, REN_TAG_DESC, 0, 0}, REN_D_ERRORS, 1, 0, 0, NULL, NULL};

_Noreturn void ren_uncaught(ren_obj *e) {
  fflush(stdout);
  fputs("error: ", stderr);
  ren_print_value(stderr, &ren_errors_desc.h, (ren_val){.o = e},
                  ren_overflow_site);
  fputc('\n', stderr);
  exit(1);
}

/* ---- evidence ---- */

bool ren_desc_same(const ren_desc *a, const ren_desc *b) {
  if (a == b)
    return true;
  if (a->kind != b->kind || a->var != b->var || a->decl != b->decl ||
      a->nargs != b->nargs)
    return false;
  for (int i = 0; i < a->nargs; i++)
    if (!ren_desc_same(a->args[i], b->args[i]))
      return false;
  return true;
}

const ren_ev *ren_install(ren_ev *nodes, const ren_ev *outer, void *deps,
                          int64_t ndeps, const ren_impl *const *impls,
                          int nimpls) {
  const ren_key *wanted = deps;
  const ren_ev *ev = outer;
  for (int64_t i = 0; i < ndeps; i++)
    for (int j = 0; j < nimpls; j++)
      /* a description of one dependency has one implementation, which
         is it whichever it was made for: `let q: Jobs = queue()` made a
         `Chan<Job>`'s a `Jobs`'s */
      if (impls[j]->dep == wanted[i].from || (nimpls == 1 && ndeps == 1)) {
        nodes[i].dep = wanted[i].dep;
        nodes[i].nargs = wanted[i].nargs;
        nodes[i].args = wanted[i].args;
        nodes[i].impl = impls[j];
        nodes[i].next = ev;
        ev = &nodes[i];
      }
  return ev;
}

const ren_ev *ren_given(ren_ev *nodes, const ren_ev *outer, const ren_ev *from,
                        const ren_key *deps, int n) {
  const ren_ev *ev = outer;
  for (int i = 0; i < n; i++) {
    nodes[i].dep = deps[i].dep;
    nodes[i].nargs = deps[i].nargs;
    nodes[i].args = deps[i].args;
    nodes[i].impl =
        deps[i].nargs == 0
            ? ren_find(from, deps[i].dep)
            : ren_find_args(from, deps[i].dep, deps[i].args, deps[i].nargs);
    nodes[i].next = ev;
    ev = &nodes[i];
  }
  return ev;
}

/* ---- the world ---- */

void ren_console_write(ren_obj *line) {
  fwrite(ren_str_data(line), 1, (size_t)ren_str_len(line), stdout);
  fputc('\n', stdout);
}

void ren_console_error(ren_obj *line) {
  fflush(stdout);
  fwrite(ren_str_data(line), 1, (size_t)ren_str_len(line), stderr);
  fputc('\n', stderr);
}

/* ---- running ---- */

/* The program's stack: 1 GiB, as the Rust twins' (bench/native/README.md,
   "Deep recursion"), which the system only maps as it's used. A frame
   that starts in the last [REN_STACK_MARGIN] bytes panics, which leaves
   room to print the panic. */
#define REN_STACK_SIZE ((size_t)1 << 30)
#define REN_STACK_MARGIN ((size_t)1 << 20)

static void (*ren_entry)(void);

static void *ren_thread(void *unused) {
  char top;
  (void)unused;
  ren_stack_limit =
      (char *)((uintptr_t)&top - REN_STACK_SIZE + REN_STACK_MARGIN);
  ren_entry();
  return NULL;
}

#ifdef REN_STATS
static void ren_print_stats(void) {
  fprintf(stderr,
          "ren stats: allocations %" PRId64 ", frees %" PRId64 ", dups %" PRId64
          ", drops %" PRId64 ", reuses %" PRId64 ", grows %" PRId64
          ", peak live bytes %" PRId64 ", block calls %" PRId64
          ", objects live at exit %" PRId64 "\n",
          ren_stats.allocs, ren_stats.frees, ren_stats.dups, ren_stats.drops,
          ren_stats.reuses, ren_stats.grows, ren_stats.peak_bytes,
          ren_stats.block_calls,
          ren_stats.allocs - ren_stats.frees);
}
#endif

int ren_run(void (*program)(void)) {
#ifdef REN_STATS
  atexit(ren_print_stats);
#endif
  pthread_attr_t attr;
  pthread_t thread;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, REN_STACK_SIZE);
  ren_entry = program;
  ren_map_seed_init();
  if (pthread_create(&thread, &attr, ren_thread, NULL) != 0) {
    fputs("error: couldn't start the program's thread\n", stderr);
    return 1;
  }
  pthread_join(thread, NULL);
  fflush(stdout);
  return 0;
}

/* ---- the program ---- */

static struct ren_lit_0 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[5]; } ren_lit_0 = { { 0, REN_TAG_STR, 0, 0 }, 4, ren_lit_0.bytes, 0, "info" };
static struct ren_lit_1 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[5]; } ren_lit_1 = { { 0, REN_TAG_STR, 0, 0 }, 4, ren_lit_1.bytes, 0, "warn" };
static struct ren_lit_2 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[10]; } ren_lit_2 = { { 0, REN_TAG_STR, 0, 0 }, 9, ren_lit_2.bytes, 0, "/api/jobs" };
static struct ren_lit_3 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[7]; } ren_lit_3 = { { 0, REN_TAG_STR, 0, 0 }, 6, ren_lit_3.bytes, 0, "level=" };
static struct ren_lit_4 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[7]; } ren_lit_4 = { { 0, REN_TAG_STR, 0, 0 }, 6, ren_lit_4.bytes, 0, " path=" };
static struct ren_lit_5 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[9]; } ren_lit_5 = { { 0, REN_TAG_STR, 0, 0 }, 8, ren_lit_5.bytes, 0, " status=" };
static struct ren_lit_6 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[5]; } ren_lit_6 = { { 0, REN_TAG_STR, 0, 0 }, 4, ren_lit_6.bytes, 0, " ms=" };
static struct ren_lit_7 { ren_obj h; int64_t len; const char *data; ren_obj *root; char bytes[2]; } ren_lit_7 = { { 0, REN_TAG_STR, 0, 0 }, 1, ren_lit_7.bytes, 0, "\n" };
static const char *const ren_text_table[18] = {"error: panic: ", "\n", " \342\224\214\342\224\200 ", "main.ren", ":", " \342\224\202 ", "fn main() uses Console =", "    let s = line(levels[i % 2], \"/api/jobs\", 200 + i % 7, i % 1000)", " help: if wrapping is what you mean, write `", " +% (", ")`\n", "    total += s.len()", " +%= ", "`\n", "    chk += s.bytes().at(s.len() - 2)", " -% ", "  print(total)", "  print(chk)"};
static const char *const ren_tag_table[1] = {NULL};
static ren_desc ren_desc_0;
static ren_desc ren_desc_0 = {{0, REN_TAG_DESC, 0, 0}, REN_D_UNIT, false, 0, 0, NULL, NULL};
static const ren_handler ren_handlers[1];
static const ren_code ren_mtab_0_0[1];
static const ren_code ren_mtab_0_1[1];
static ren_obj* ren_Console_real_value;
static const ren_site ren_site_0 = { (const unsigned char *)"\001\000\005\001\001\002\001\001\002\001\003\001\004\004\010\001\004\004\004\001\001\002\000\004\010\001\005\001\006\001\001\002\001\001\005\002\003\003^\004\001\001\000" };
static const ren_site ren_site_1 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\015\001\004\004\031\001\001\002\000\004\015\001\005\001\007\001\001\002\002\001\005\002\030\003^\005\001\001\000" };
static const ren_site ren_site_2 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\015\001\004\004\022\001\001\002\000\004\015\001\005\001\007\001\001\002\002\001\005\002\021\003^\015\001\001\000" };
static const ren_site ren_site_3 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\015\001\004\0044\001\001\002\000\004\015\001\005\001\007\001\001\002\002\001\005\0023\003^\005\001\001\000" };
static const ren_site ren_site_4 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\015\001\004\004.\001\001\002\000\004\015\001\005\001\007\001\001\002\002\001\005\002-\003^\013\001\001\002\002\001\010\006\007-\003\001\011\006\0073\005\001\n\000" };
static const ren_site ren_site_5 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\015\001\004\004;\001\001\002\000\004\015\001\005\001\007\001\001\002\002\001\005\002:\003^\010\001\001\000" };
static const ren_site ren_site_6 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\016\001\004\004\005\001\001\002\000\004\016\001\005\001\013\001\001\002\002\001\005\002\004\003^\020\001\001\002\002\001\010\006\013\004\005\001\014\006\013\015\007\001\015\000" };
static const ren_site ren_site_7 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\017\001\004\004\014\001\001\002\000\004\017\001\005\001\016\001\001\002\002\001\005\002\013\003^\031\001\001\000" };
static const ren_site ren_site_8 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\017\001\004\004\031\001\001\002\000\004\017\001\005\001\016\001\001\002\002\001\005\002\030\003^\013\001\001\002\002\001\010\006\016\030\007\001\017\006\016\"\001\001\015\000" };
static const ren_site ren_site_9 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\017\001\004\004\005\001\001\002\000\004\017\001\005\001\016\001\001\002\002\001\005\002\004\003^ \001\001\002\002\001\010\006\016\004\003\001\014\006\016\013\031\001\015\000" };
static const ren_site ren_site_10 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\020\001\004\004\003\001\001\002\000\004\020\001\005\001\020\001\001\002\002\001\005\002\002\003^\014\001\001\000" };
static const ren_site ren_site_11 = { (const unsigned char *)"\001\000\005\001\001\002\002\001\002\001\003\001\004\004\021\001\004\004\003\001\001\002\000\004\021\001\005\001\021\001\001\002\002\001\005\002\002\003^\n\001\001\000" };

static ren_unit ren_main__start(const ren_ev* v1_ev);
static ren_unit ren_main_main_1(const ren_ev* v1_ev);
static ren_unit ren_print_1(const ren_ev* v1_ev, int64_t v2_x);
static ren_obj* ren_main_line_1(const ren_ev* v1_ev, ren_obj* v2_level, ren_obj* v3_path, int64_t v4_status, int64_t v5_ms);
static REN_INLINE ren_obj* ren_Console_real(const ren_ev* v1_ev);
static REN_INLINE ren_obj* ren_real_console(const ren_ev* v1_ev);
static ren_obj* ren_main__start_with(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out);
static ren_obj* ren_real_console_1(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out);
static ren_obj* ren_real_console_2(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out);
static ren_obj* ren_real_console_write(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out);
static ren_obj* ren_real_console_error(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out);
static ren_obj* ren_real_console_handler(ren_obj* v1_self, const ren_ev* v2_outer, ren_block v3_body, ren_obj* v4_body_desc, void* v5_deps, int64_t v6_ndeps, ren_val* ren_out);

static ren_unit ren_main__start(const ren_ev* v1_ev) {
  REN_STACK_CHECK();
  ren_obj* v2_Console = ren_Console_real_value;
  void* v3_env = NULL;
  ren_block v4_block = ((ren_block){ren_main__start_with, v3_env});
  static const ren_key v5_with_keys[1] = {{0, 0, 0, NULL}};
  ren_val v5_with_out = {0};
  ren_obj* v6_error = (&ren_handlers[(intptr_t)ren_fields(v2_Console)[0].p])->install(v2_Console, v1_ev, v4_block, ((ren_obj*)&ren_desc_0), (void*)v5_with_keys, 1, &v5_with_out);
  ren_unit v5_with = (ren_unit)v5_with_out.i;
  (void)v6_error;
  return v5_with;
}

static inline __attribute__((always_inline)) void ren_main_main_1_loop_1(const ren_ev* v1_ev, int64_t* v2_total, int64_t* v3_chk, ren_obj* v4_array, int64_t* v6_i, int64_t v7_stop, int64_t v46_len, ren_val* restrict v48_buf) {
  for (;;) {
    int64_t v8_i = (*v6_i);
    int64_t v9_stop = v7_stop;
    bool v10_cmp = (v8_i < v9_stop);
    if (v10_cmp) {
    } else {
      ren_drop(v4_array);
      goto ren_break_1;
    }
    int64_t v11_i = (*v6_i);
    int64_t v12_i = v11_i;
    int64_t v14_i = v12_i;
    int64_t v15_arith = (v14_i % INT64_C(2));
    ren_obj* v16_elem = ren_buf_get_o(v48_buf, v46_len, v15_arith, &ren_site_2).o;
    int64_t v17_i = v12_i;
    int64_t v18_arith = (v17_i % INT64_C(7));
    int64_t v19_arith = ren_add(INT64_C(200), v18_arith, &ren_site_4);
    int64_t v20_i = v12_i;
    int64_t v21_arith = (v20_i % INT64_C(1000));
    ren_obj* v22_result = ren_main_line_1(v1_ev, v16_elem, ((ren_obj*)&ren_lit_2), v19_arith, v21_arith);
    ren_drop(v16_elem);
    ren_obj* v23_s = v22_result;
    ren_obj* v24_s = v23_s;
    int64_t v25_len = ren_str_len(v24_s);
    int64_t v26_v = v25_len;
    int64_t v27_total = (*v2_total);
    int64_t v28_v = v26_v;
    int64_t v29_arith = ren_add(v27_total, v28_v, &ren_site_6);
    (*v2_total) = v29_arith;
    ren_obj* v30_s = v23_s;
    ren_obj* v31_s = v23_s;
    int64_t v32_len = ren_str_len(v31_s);
    int64_t v33_arith = ren_sub(v32_len, INT64_C(2), &ren_site_8);
    int64_t v34_at = ren_bytes_at(v30_s, v33_arith, &ren_site_7);
    ren_drop(v22_result);
    int64_t v35_v = v34_at;
    int64_t v36_chk = (*v3_chk);
    int64_t v37_v = v35_v;
    int64_t v38_arith = ren_add(v36_chk, v37_v, &ren_site_9);
    (*v3_chk) = v38_arith;
    int64_t v39_i = (*v6_i);
    int64_t v40_step = (v39_i + 1);
    (*v6_i) = v40_step;
  }
  ren_break_1: ;
}

static ren_unit ren_main_main_1(const ren_ev* v1_ev) {
  REN_STACK_CHECK();
  int64_t v2_total = INT64_C(0);
  int64_t v3_chk = INT64_C(0);
  ren_obj* v4_array = ren_alloc_array(2, true);
  ren_elems(v4_array)[0] = (ren_val){.o = ((ren_obj*)&ren_lit_0)};
  ren_elems(v4_array)[1] = (ren_val){.o = ((ren_obj*)&ren_lit_1)};
  ren_obj* v5_levels = v4_array;
  int64_t v6_i = INT64_C(0);
  int64_t v7_stop = INT64_C(10000000);
  ren_obj* v45_levels = v5_levels;
  int64_t v46_len = ren_array_len(v45_levels);
  ren_obj* v47_levels = v5_levels;
  ren_val* v48_buf = ((void*)ren_elems(v47_levels));
  ren_main_main_1_loop_1(v1_ev, &v2_total, &v3_chk, v4_array, &v6_i, v7_stop, v46_len, v48_buf);
  int64_t v41_total = v2_total;
  (void)(ren_here = &ren_site_10);
  ren_unit v42_result = ren_print_1(v1_ev, v41_total);
  int64_t v43_chk = v3_chk;
  (void)(ren_here = &ren_site_11);
  ren_unit v44_result = ren_print_1(v1_ev, v43_chk);
  return v44_result;
}

static ren_unit ren_print_1(const ren_ev* v1_ev, int64_t v2_x) {
  REN_STACK_CHECK();
  void* v8_here = (void *)ren_here;
  int64_t v3_x = v2_x;
  ren_obj* v4_shown = ren_show_int(v3_x);
  ren_block v5_write = ren_find(v1_ev, 0)->ops[0];
  REN_STAT(block_calls);
  ren_val v6_result_args[1] = {(ren_val){.o = v4_shown}};
  ren_val v6_result_out = {0};
  ren_obj* v7_error = v5_write.code(v5_write.env, v1_ev, v6_result_args, &v6_result_out);
  ren_unit v6_result = (ren_unit)v6_result_out.i;
  (void)v7_error;
  (void)(ren_here = (const ren_site *)v8_here);
  return v6_result;
}

static ren_obj* ren_main_line_1(const ren_ev* v1_ev, ren_obj* v2_level, ren_obj* v3_path, int64_t v4_status, int64_t v5_ms) {
  ren_obj* v6_level = v2_level;
  ren_obj* v7_concat = ren_str_concat(((ren_obj*)&ren_lit_3), v6_level);
  ren_obj* v8_concat = ren_str_concat(v7_concat, ((ren_obj*)&ren_lit_4));
  ren_drop(v7_concat);
  ren_obj* v9_path = v3_path;
  ren_obj* v10_concat = ren_str_concat(v8_concat, v9_path);
  ren_drop(v8_concat);
  ren_obj* v11_concat = ren_str_concat(v10_concat, ((ren_obj*)&ren_lit_5));
  ren_drop(v10_concat);
  int64_t v12_status = v4_status;
  ren_obj* v13_shown = ren_show_int(v12_status);
  ren_obj* v14_concat = ren_str_concat(v11_concat, v13_shown);
  ren_drop(v11_concat);
  ren_drop(v13_shown);
  ren_obj* v15_concat = ren_str_concat(v14_concat, ((ren_obj*)&ren_lit_6));
  ren_drop(v14_concat);
  int64_t v16_ms = v5_ms;
  ren_obj* v17_shown = ren_show_int(v16_ms);
  ren_obj* v18_concat = ren_str_concat(v15_concat, v17_shown);
  ren_drop(v15_concat);
  ren_drop(v17_shown);
  ren_obj* v19_concat = ren_str_concat(v18_concat, ((ren_obj*)&ren_lit_7));
  ren_drop(v18_concat);
  return v19_concat;
}

static REN_INLINE ren_obj* ren_Console_real(const ren_ev* v1_ev) {
  ren_obj* v2_result = ren_real_console(v1_ev);
  return v2_result;
}

static REN_INLINE ren_obj* ren_real_console(const ren_ev* v1_ev) {
  ren_obj* v2_new = ren_alloc_ctor(0, 1, 0);
  ren_fields(v2_new)[0] = (ren_val){.p = (void*)((void*)(intptr_t)0)};
  return v2_new;
}

static ren_obj* ren_main__start_with(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out) {
  REN_STACK_CHECK();
  ren_unit v4_result = ren_main_main_1(v2_caller);
  ren_val v5_word = (ren_val){.i = (int64_t)v4_result};
  *ren_out = v5_word;
  return NULL;
}

static ren_obj* ren_real_console_1(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out) {
  ren_obj* v6_line = ((ren_val*)v3_args)[0].o;
  ren_obj* v7_line = v6_line;
  ren_unit v8_console_write = (ren_console_write(v7_line), (ren_unit)0);
  ren_drop(v6_line);
  ren_val v9_word = (ren_val){.i = (int64_t)v8_console_write};
  *ren_out = v9_word;
  return NULL;
}

static ren_obj* ren_real_console_2(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out) {
  ren_obj* v6_line = ((ren_val*)v3_args)[0].o;
  ren_obj* v7_line = v6_line;
  ren_unit v8_console_error = (ren_console_error(v7_line), (ren_unit)0);
  ren_drop(v6_line);
  ren_val v9_word = (ren_val){.i = (int64_t)v8_console_error};
  *ren_out = v9_word;
  return NULL;
}

static ren_obj* ren_real_console_write(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out) {
  ren_obj* v4_self = ((ren_val*)v3_args)[0].o;
  ren_obj* v5_line = ((ren_val*)v3_args)[1].o;
  ren_obj* v6_line = v5_line;
  ren_unit v7_console_write = (ren_console_write(v6_line), (ren_unit)0);
  ren_val v8_word = (ren_val){.i = (int64_t)v7_console_write};
  *ren_out = v8_word;
  return NULL;
}

static ren_obj* ren_real_console_error(void* v1_env, const ren_ev* v2_caller, void* v3_args, ren_val* ren_out) {
  ren_obj* v4_self = ((ren_val*)v3_args)[0].o;
  ren_obj* v5_line = ((ren_val*)v3_args)[1].o;
  ren_obj* v6_line = v5_line;
  ren_unit v7_console_error = (ren_console_error(v6_line), (ren_unit)0);
  ren_val v8_word = (ren_val){.i = (int64_t)v7_console_error};
  *ren_out = v8_word;
  return NULL;
}

static ren_obj* ren_real_console_handler(ren_obj* v1_self, const ren_ev* v2_outer, ren_block v3_body, ren_obj* v4_body_desc, void* v5_deps, int64_t v6_ndeps, ren_val* ren_out) {
  REN_STACK_CHECK();
  const ren_ev** v7_outer = (&v2_outer);
  void* v8_env_env[1] = {(void*)v7_outer};
  void* v8_env = v8_env_env;
  ren_block v9_block = ((ren_block){ren_real_console_1, v8_env});
  const ren_ev** v10_outer = (&v2_outer);
  void* v11_env_env[1] = {(void*)v10_outer};
  void* v11_env = v11_env_env;
  ren_block v12_block = ((ren_block){ren_real_console_2, v11_env});
  ren_block v13_Console_ops[2] = {v9_block, v12_block};
  ren_impl v13_Console_impl = {0, 2, v13_Console_ops};
  void* v13_Console = &v13_Console_impl;
  ren_ev v14_installed_nodes[1];
  const ren_impl* v14_installed_impls[1] = {(const ren_impl*)v13_Console};
  const ren_ev* v14_installed = ren_install(v14_installed_nodes, v2_outer, v5_deps, v6_ndeps, v14_installed_impls, 1);
  REN_STAT(block_calls);
  ren_val v15_result_out = {0};
  ren_obj* v16_error = v3_body.code(v3_body.env, v14_installed, NULL, &v15_result_out);
  ren_val v15_result = v15_result_out;
  if (v16_error != NULL) {
    return v16_error;
  }
  *ren_out = v15_result;
  return NULL;
}

static const ren_method ren_methods_0[2] = {{0, 0, (ren_code)ren_real_console_write}, {0, 1, (ren_code)ren_real_console_error}};
static const ren_handler ren_handlers[1] = {{0, 0, "real_console", (ren_hcode)ren_real_console_handler, 2, ren_methods_0}};
static const ren_code ren_mtab_0_0[1] = {(ren_code)ren_real_console_write};
static const ren_code ren_mtab_0_1[1] = {(ren_code)ren_real_console_error};
static void ren_program(void) {
  ren_Console_real_value = ren_Console_real(NULL);
  ren_unit r = ren_main__start(NULL);
  ren_drop(ren_Console_real_value);
}

int main(void) {
  ren_overflow_site = &ren_site_0;
  ren_texts = ren_text_table;
  ren_tag_names = ren_tag_table;
  return ren_run(ren_program);
}
