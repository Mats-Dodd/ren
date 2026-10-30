// K1b platform layer: the per-worker clock, the OS lock, thread QoS, the
// wall clock and cpu_relax. macOS (the original, Apple M4 Max) and Linux
// (the cloud machine, x86_64). rust/src/plat.rs mirrors it.
//
//   clock  macOS: mach_absolute_time, 24 MHz (41.7 ns tick).
//          Linux x86_64: rdtsc (invariant TSC; constant_tsc + tsc_known_freq
//          on the cloud guest), about 2.1 GHz (0.48 ns tick). Its rate is
//          calibrated at start against CLOCK_MONOTONIC_RAW over 100 ms.
//          Linux aarch64: cntvct_el0, rate from cntfrq_el0.
//          The histogram buckets are 2^HSHIFT ticks wide: macOS 1 tick
//          (41.7 ns, range 2.7 ms), Linux tsc 16 ticks (about 7.6 ns, range
//          2^20 buckets = about 8 ms, so oversubscribed preemptions fit).
//   lock   "os": macOS os_unfair_lock; Linux pthread_mutex_t (glibc default
//          type: futex, no spinning before it parks).
//   qos    macOS: pthread_set_qos_class_self_np. Linux: no QoS classes; the
//          flag is accepted and ignored (SCHED_OTHER, default nice).
#pragma once
#include <pthread.h>
#include <stdint.h>
#include <time.h>

#if defined(__APPLE__)
#include <mach/mach_time.h>
#include <os/lock.h>
#include <pthread/qos.h>
#endif
#if defined(__x86_64__)
#include <x86intrin.h>
#endif

static inline void cpu_relax(void) {
#if defined(__x86_64__)
    _mm_pause();
#elif defined(__aarch64__)
    __asm__ volatile("isb" ::: "memory");
#endif
}

#if defined(__APPLE__)
typedef os_unfair_lock oslock_t;
static inline void oslock_init(oslock_t *l) { *l = OS_UNFAIR_LOCK_INIT; }
static inline void oslock_lock(oslock_t *l) { os_unfair_lock_lock(l); }
static inline int oslock_trylock(oslock_t *l) { return os_unfair_lock_trylock(l); }
static inline void oslock_unlock(oslock_t *l) { os_unfair_lock_unlock(l); }
#define OSLOCK_NAME "os_unfair_lock"

static inline uint64_t clk_now(void) { return mach_absolute_time(); }
static double clk_tick_ns(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (double)tb.numer / tb.denom;
}
#define CLOCK_NAME "mach"
#define HSHIFT 0
#define HBUCKETS 65536
static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void set_qos(int mode) {
    if (mode == 0) pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    else if (mode == 1) pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
}
#else // Linux
typedef pthread_mutex_t oslock_t;
static inline void oslock_init(oslock_t *l) { pthread_mutex_init(l, NULL); }
static inline void oslock_lock(oslock_t *l) { pthread_mutex_lock(l); }
static inline int oslock_trylock(oslock_t *l) { return pthread_mutex_trylock(l) == 0; }
static inline void oslock_unlock(oslock_t *l) { pthread_mutex_unlock(l); }
#define OSLOCK_NAME "pthread_mutex"

static inline uint64_t raw_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
#if defined(__x86_64__)
static inline uint64_t clk_now(void) { return __rdtsc(); }
#define CLOCK_NAME "tsc"
#define HSHIFT 4
static double clk_tick_ns(void) { // calibrate against CLOCK_MONOTONIC_RAW
    struct timespec d = {0, 100 * 1000 * 1000};
    uint64_t n0 = raw_ns(), c0 = clk_now();
    nanosleep(&d, NULL);
    uint64_t n1 = raw_ns(), c1 = clk_now();
    return (double)(n1 - n0) / (double)(c1 - c0);
}
#elif defined(__aarch64__)
static inline uint64_t clk_now(void) {
    uint64_t v;
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(v));
    return v;
}
#define CLOCK_NAME "cntvct"
#define HSHIFT 0
static double clk_tick_ns(void) {
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return 1e9 / (double)f;
}
#else
#error "K1b needs rdtsc (x86_64) or cntvct (aarch64) on Linux"
#endif
#define HBUCKETS (1u << 20)
static void set_qos(int mode) { (void)mode; }
#endif
