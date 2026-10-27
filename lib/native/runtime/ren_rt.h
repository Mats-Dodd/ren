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

/* What an object holds, which says how to free it, is its tag: a
   constructor's, a record's (0) or an error's, or one of these three
   at the top, as Lean's tags above `LeanMaxCtorTag` are its arrays and
   strings (lean.h:113-125) and kklib's `KK_TAG_STRING` and the rest
   theirs. */
enum {
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

   An array keeps whether its elements are counted in [objs], and a
   string and a descriptor use neither byte. */
typedef struct ren_obj {
  int32_t rc;      /* > 0: counted; 0: never freed; < 0: kept, shared */
  uint16_t tag;    /* a constructor's, or REN_TAG_ARRAY, _STR or _DESC */
  uint8_t nfields; /* a constructor's fields */
  uint8_t objs;    /* its first eight that hold objects; an array's: 1 if
                      its elements are counted */
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

typedef struct {
  ren_obj h;
  int64_t len;
  int64_t cap;
  ren_val *data;
  int64_t stride; /* words an element, 1 but for an array of structs */
} ren_array;

typedef struct {
  ren_obj h;
  int64_t len;
  char data[]; /* [len] bytes, then a 0 */
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
      block_calls, stack_allocs;
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
   one thread and measures the counting alone. An object in a frame
   (stack.ml) is never handed to another thread, since that would be an
   escape, so it's never marked. */

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

/* ---- objects in a frame ----

   A release build keeps an object that never outlives the call that
   builds it in that call's frame (stack.ml, after Swift's
   StackPromotion.swift). Its count is 1 and stays 1, since nothing
   counts it again, so it's unique as one on the heap is. Where Perceus
   would free it, its fields that hold objects are dropped, but those in
   [kept], and its memory, the frame's, is left alone. */

/* [h], the frame's memory for a constructor of [nfields] fields, as one
   with a count of 1: the header, the fields, and past eight the mask's
   word (emit_c.ml sizes the frame so). The caller fills in the fields. */
static inline ren_obj *ren_stack_ctor(ren_obj *h, uint16_t tag,
                                      uint32_t nfields, uint64_t objs) {
  REN_STAT(stack_allocs);
  h->rc = 1;
  h->tag = tag;
  h->nfields = (uint8_t)nfields;
  ren_set_objs(h, nfields, objs);
  return h;
}

/* Where an object in a frame dies: its fields dropped, but those in
   [kept]. It may be a constructor without fields, a scalar. */
static inline void ren_stack_drop(ren_obj *o, uint64_t kept) {
  if (ren_is_scalar(o))
    return;
  ren_val *fs = ren_fields(o);
  for (uint64_t m = ren_ctor_objs(o) & ~kept; m != 0; m &= m - 1)
    ren_drop(fs[__builtin_ctzll(m)].o);
}

/* A token nothing was built in: its memory, if it has some, given back. */
void ren_free_token(ren_obj *tok);

/* An array of [len] elements, which the caller fills in. */
ren_obj *ren_alloc_array(int64_t len, bool boxed_elems);
static inline ren_val *ren_elems(ren_obj *o) { return ((ren_array *)o)->data; }

/* An empty array with room for [cap] elements of [stride] words each,
   0 meaning 1: what `map` makes when it can't reuse its input. */
ren_obj *ren_array_reserve(int64_t cap, bool boxed_elems, uint32_t stride);

/* An array of [len] elements of [stride] words each, a release build's
   structs (a copied record's fields, Mem's [Struct]), kept in the
   elements: never counted, and never walked, since nothing that walks a
   value is given one. */
ren_obj *ren_alloc_array_n(int64_t len, uint32_t stride);
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

/* Panics, as `xs[i]` does, if [i] is out of bounds; one unsigned
   compare, since a length is never below 0. */
static inline void ren_array_check(ren_obj *a, int64_t i, const ren_site *site) {
  if (__builtin_expect((uint64_t)i >= (uint64_t)((ren_array *)a)->len, 0))
    ren_index_panic(a, i, site);
}

/* A copy of [a], which is shared, each element counted again; [a]'s
   reference is dropped. */
ren_obj *ren_array_unshare(ren_obj *a);

/* [a], taken, made unique: itself if its count is 1, else a copy. */
static inline ren_obj *ren_array_own(ren_obj *a) {
  return __builtin_expect(ren_rc(a) == 1, 1) ? a : ren_array_unshare(a);
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
   which tests the count the same way ([ren_array_own]), so nothing but
   that write sees the scalar. Otherwise it's counted again, as
   [ren_array_get] does. */
static inline ren_val ren_array_take(ren_obj *a, int64_t i, const ren_site *site) {
  ren_array_check(a, i, site);
  ren_val *at = &((ren_array *)a)->data[i];
  ren_val v = *at;
  if (a->objs) {
    if (__builtin_expect(ren_rc(a) == 1, 1))
      at->o = ren_box(0);
    else
      ren_dup(v.o);
  }
  return v;
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

/* Field [off] of element [i] of an array of structs of [k] words
   changed to [v], the rest of the element as it was: a copy, which
   takes neither, and in place, which takes the array. */
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
  if (__builtin_expect((uint64_t)i >= (uint64_t)len, 0))
    ren_index_panic_len(len, i, site);
}
static inline ren_val ren_dup_elem(ren_val v) {
  ren_dup(v.o);
  return v;
}
#define ren_buf_get_s(p, len, i, site) (ren_buf_check(len, i, site), (p)[i])
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
  const char *const *fields; /* a record's field names; NULL for a sum */
  ren_desc *const *types;
  const uint32_t *at;
} ren_ctor_info;

/* Field [i] of [o], a constructor or a record of [c], as a word: a packed
   one's bits, unsigned. [c] NULL is a tuple's, never packed. */
static inline ren_val ren_ctor_field(ren_obj *o, const ren_ctor_info *c,
                                     int32_t i) {
  if (c == NULL || c->at == NULL)
    return ren_fields(o)[i];
  uint32_t at = c->at[i], bits = at & 0xFF;
  ren_val v = ren_fields(o)[at >> 16];
  if (bits < 64)
    v.i = (int64_t)(((uint64_t)v.i >> ((at >> 8) & 0xFF)) &
                    ((UINT64_C(1) << bits) - 1));
  return v;
}

enum { REN_DECL_RECORD, REN_DECL_SUM, REN_DECL_REP };

typedef struct ren_decl {
  const char *name;
  uint8_t kind;
  uint8_t opaque;   /* declared `opaque`, shown as `Name(...)` */
  uint8_t enumlike; /* a sum none of whose constructors has fields */
  int32_t nctors;
  const ren_ctor_info *ctors; /* a record's one, or a sum's, by tag */
  ren_desc *rep;              /* an opaque type's representation */
} ren_decl;

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
   it: a `Str` is itself. Through a type's own `show` or `key` the walk
   never goes: a type that has one isn't in the native slice yet. */
ren_obj *ren_show_any(ren_obj *d, ren_val v);

/* [v] as it's written, a `Str` in quotes: how `ren run` prints what
   `main` gives, or an error nothing handled. */
void ren_print_value(FILE *out, ren_obj *d, ren_val v);

/* `==` on two values of [d]'s type, and their order: negative if [a]
   comes first (walk.ml, `equal` and `compare`). */
bool ren_equal_any(ren_obj *d, ren_val a, ren_val b);
int64_t ren_compare_any(ren_obj *d, ren_val a, ren_val b);

/* An operator, by its requirement, on values of [d]'s type, an `Int`, a
   `Float` or one represented as either, and `zero` and `one`. */
enum { REN_OP_ADD, REN_OP_SUB, REN_OP_MUL, REN_OP_DIV, REN_OP_REM, REN_OP_NEG };
ren_val ren_op_any(ren_obj *d, int op, ren_val a, ren_val b,
                   const ren_site *site);
ren_val ren_value_any(ren_obj *d, bool one);

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
   installed with, so `next` and the handler's own calls find theirs. */

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
  const ren_impl *impl;
  const ren_ev *next;
};

/* The innermost implementation of [dep]: typing makes sure there's one. */
static inline const ren_impl *ren_find(const ren_ev *ev, int32_t dep) {
  while (ev->dep != dep)
    ev = ev->next;
  return ev->impl;
}

/* [outer] with each of [deps] installed on top, its implementation one
   of [impls], in [nodes]: a `with` installing a handler's instance. */
const ren_ev *ren_install(ren_ev *nodes, const ren_ev *outer, void *deps,
                          int64_t ndeps, const ren_impl *const *impls,
                          int nimpls);

/* [outer] with the implementations of [deps] its caller has, in [from],
   on top, in [nodes]: what a block's parameter's type lists, which its
   callee provides (foundations.md, decision 5). */
const ren_ev *ren_given(ren_ev *nodes, const ren_ev *outer, const ren_ev *from,
                        const int32_t *deps, int n);

/* A handler's description is an object: its code, then what it
   captured. Its code makes the handler's state as its own locals, makes
   its instance, installs it on [outer] for [deps], calls [body] with
   that evidence, and runs its `finally` with the outcome, given
   [body_desc], the descriptor of what [body] gives. */
typedef ren_obj *(*ren_hcode)(ren_obj *self, const ren_ev *outer,
                              ren_block body, ren_obj *body_desc, void *deps,
                              int64_t ndeps, ren_val *out);

/* ---- the world ---- */

/* The real `Console`: a line to stdout, or to stderr. */
void ren_console_write(ren_obj *line);
void ren_console_error(ren_obj *line);

/* Run [program] on a thread whose stack is big enough for deep
   recursion, then flush stdout and print the statistics, if they're on.
   What `main` returns. */
int ren_run(void (*program)(void));
