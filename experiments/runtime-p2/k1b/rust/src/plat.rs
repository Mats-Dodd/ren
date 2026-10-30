// Mirrors c/plat.h: the per-worker clock, the OS lock, QoS, the wall clock and
// cpu_relax, for macOS (the original) and Linux (the cloud machine). No crates:
// the OS lock and QoS are the same C calls the C side makes.
#![allow(dead_code)]
use std::cell::UnsafeCell;
use std::sync::atomic::AtomicU32;
use std::time::Instant;

#[inline(always)]
pub fn cpu_relax() {
    std::hint::spin_loop(); // x86_64: pause; aarch64: isb (as the C)
}

// ---- the OS lock ------------------------------------------------------------
#[cfg(target_os = "macos")]
mod os {
    #[repr(C)]
    pub struct Raw(pub u32); // os_unfair_lock; 0 = OS_UNFAIR_LOCK_INIT
    extern "C" {
        pub fn os_unfair_lock_lock(l: *mut Raw);
        pub fn os_unfair_lock_trylock(l: *mut Raw) -> bool;
        pub fn os_unfair_lock_unlock(l: *mut Raw);
    }
    pub const ZERO: Raw = Raw(0);
    pub const NAME: &str = "os_unfair_lock";
    pub unsafe fn lock(l: *mut Raw) { os_unfair_lock_lock(l) }
    pub unsafe fn trylock(l: *mut Raw) -> bool { os_unfair_lock_trylock(l) }
    pub unsafe fn unlock(l: *mut Raw) { os_unfair_lock_unlock(l) }
}

#[cfg(target_os = "linux")]
mod os {
    // glibc pthread_mutex_t: 40 bytes on x86_64, 48 on aarch64; all zero is
    // PTHREAD_MUTEX_INITIALIZER (the default, non-spinning futex mutex).
    #[cfg(target_arch = "x86_64")]
    const N: usize = 40;
    #[cfg(not(target_arch = "x86_64"))]
    const N: usize = 48;
    #[repr(C, align(8))]
    pub struct Raw(pub [u8; N]);
    extern "C" {
        fn pthread_mutex_lock(l: *mut Raw) -> i32;
        fn pthread_mutex_trylock(l: *mut Raw) -> i32;
        fn pthread_mutex_unlock(l: *mut Raw) -> i32;
    }
    pub const ZERO: Raw = Raw([0; N]);
    pub const NAME: &str = "pthread_mutex";
    pub unsafe fn lock(l: *mut Raw) { pthread_mutex_lock(l); }
    pub unsafe fn trylock(l: *mut Raw) -> bool { pthread_mutex_trylock(l) == 0 }
    pub unsafe fn unlock(l: *mut Raw) { pthread_mutex_unlock(l); }
}

pub const OSLOCK_NAME: &str = os::NAME;

/// One lock word that is either phase 1's TTAS spin lock (its first 4 bytes,
/// as an AtomicU32) or the OS lock, as the C's union. Which one is one
/// predictable branch on a flag the caller passes.
#[repr(C)]
pub struct Lock(UnsafeCell<os::Raw>);
unsafe impl Sync for Lock {}

impl Lock {
    pub const fn new() -> Lock { Lock(UnsafeCell::new(os::ZERO)) }
    #[inline(always)]
    fn spin(&self) -> &AtomicU32 { unsafe { &*(self.0.get() as *const AtomicU32) } }
    #[inline(always)]
    pub fn lock(&self, os: bool) {
        use std::sync::atomic::Ordering::*;
        if os { unsafe { os::lock(self.0.get()) }; return; }
        let s = self.spin();
        loop {
            if s.swap(1, Acquire) == 0 { return; }
            while s.load(Relaxed) != 0 { cpu_relax(); }
        }
    }
    #[inline(always)]
    pub fn try_lock(&self, os: bool) -> bool {
        use std::sync::atomic::Ordering::*;
        if os { return unsafe { os::trylock(self.0.get()) }; }
        let s = self.spin();
        s.load(Relaxed) == 0 && s.swap(1, Acquire) == 0
    }
    #[inline(always)]
    pub fn unlock(&self, os: bool) {
        use std::sync::atomic::Ordering::*;
        if os { unsafe { os::unlock(self.0.get()) }; return; }
        self.spin().store(0, Release);
    }
}

// ---- the per-worker clock -----------------------------------------------------
#[cfg(target_os = "macos")]
mod clk {
    #[repr(C)]
    struct Tb { numer: u32, denom: u32 }
    extern "C" {
        fn mach_absolute_time() -> u64;
        fn mach_timebase_info(tb: *mut Tb) -> i32;
    }
    pub const NAME: &str = "mach";
    pub const HSHIFT: u32 = 0;
    pub const HBUCKETS: usize = 65536;
    #[inline(always)]
    pub fn now() -> u64 { unsafe { mach_absolute_time() } }
    pub fn tick_ns() -> f64 {
        let mut tb = Tb { numer: 0, denom: 0 };
        unsafe { mach_timebase_info(&mut tb) };
        tb.numer as f64 / tb.denom as f64
    }
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
mod clk {
    pub const NAME: &str = "tsc";
    pub const HSHIFT: u32 = 4;
    pub const HBUCKETS: usize = 1 << 20;
    #[inline(always)]
    pub fn now() -> u64 { unsafe { core::arch::x86_64::_rdtsc() } }
    pub fn tick_ns() -> f64 {
        // Calibrate against the monotonic clock over 100 ms, as the C.
        let t0 = std::time::Instant::now();
        let c0 = now();
        std::thread::sleep(std::time::Duration::from_millis(100));
        let c1 = now();
        let dt = t0.elapsed();
        dt.as_nanos() as f64 / (c1 - c0) as f64
    }
}

#[cfg(all(target_os = "linux", target_arch = "aarch64"))]
mod clk {
    pub const NAME: &str = "cntvct";
    pub const HSHIFT: u32 = 0;
    pub const HBUCKETS: usize = 1 << 20;
    #[inline(always)]
    pub fn now() -> u64 {
        let v: u64;
        unsafe { core::arch::asm!("mrs {}, cntvct_el0", out(reg) v) };
        v
    }
    pub fn tick_ns() -> f64 {
        let f: u64;
        unsafe { core::arch::asm!("mrs {}, cntfrq_el0", out(reg) f) };
        1e9 / f as f64
    }
}

pub use clk::{now as clk_now, tick_ns as clk_tick_ns, HBUCKETS, HSHIFT, NAME as CLOCK_NAME};

/// Wall time for the reps (macOS: CLOCK_UPTIME_RAW in the C; Linux:
/// CLOCK_MONOTONIC). Instant is the monotonic clock on both.
pub fn wall() -> Instant { Instant::now() }

// ---- QoS ----------------------------------------------------------------------
#[cfg(target_os = "macos")]
pub fn set_qos(mode: i32) {
    extern "C" {
        fn pthread_set_qos_class_self_np(class: u32, prio: i32) -> i32;
    }
    const USER_INTERACTIVE: u32 = 0x21;
    const BACKGROUND: u32 = 0x09;
    unsafe {
        if mode == 0 { pthread_set_qos_class_self_np(USER_INTERACTIVE, 0); }
        else if mode == 1 { pthread_set_qos_class_self_np(BACKGROUND, 0); }
    }
}
#[cfg(not(target_os = "macos"))]
pub fn set_qos(_mode: i32) {} // Linux: no QoS classes; accepted and ignored
