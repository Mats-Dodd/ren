//! The Chase-Lev deque, SPEC §A.3 (Lê, Pop, Cohen, Zappa Nardelli, PPoPP
//! 2013, Fig. 1), with signed i64 indices and growth. Items are non-zero
//! u64 words (task pointers in the core). Old rings are retired, never
//! freed while the deque lives (the CDSChecker window, SPEC §A.1 item 4).
use crate::sync::{fence, AtomicI64, AtomicPtr, AtomicU64, Ordering::*};
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::cell::UnsafeCell;

pub const EMPTY: u64 = 0;
pub const ABORT: u64 = u64::MAX;

/// The paper's push publishes with a release fence and a relaxed store of
/// bottom. ThreadSanitizer does not model standalone fences, so under it
/// that edge is invisible and every stolen task frame reports as a race
/// (found on cloud, W1 at 4 workers). The `tsan` feature (the tsan profile
/// only) makes the store itself Release as well; the fence stays.
const PUSH_BOTTOM: crate::sync::Ordering = if cfg!(feature = "tsan") { Release } else { Relaxed };

/// The index type (SPEC §A.1: signed; P2 is what happens without that).
#[cfg(not(feature = "plant2"))]
type Idx = i64;
#[cfg(not(feature = "plant2"))]
type AIdx = AtomicI64;
// PLANT P2 (SPEC §F): unsigned indices, as size_t in the paper.
#[cfg(feature = "plant2")]
type Idx = u64;
#[cfg(feature = "plant2")]
type AIdx = AtomicU64;

/// The fence between bottom and top in take and steal (SPEC §A.3).
/// PLANT P1 (SPEC §F) weakens it to AcqRel: no mfence on x86-64.
const BT_FENCE: crate::sync::Ordering = if cfg!(feature = "plant1") { AcqRel } else { SeqCst };

struct Ring {
    cap: Idx,
    slot: Box<[AtomicU64]>,
}
impl Ring {
    fn new(cap: Idx) -> *mut Ring {
        let slot: Vec<AtomicU64> = (0..cap).map(|_| AtomicU64::new(0)).collect();
        Box::into_raw(Box::new(Ring { cap, slot: slot.into_boxed_slice() }))
    }
    #[inline]
    fn at(&self, i: Idx) -> &AtomicU64 {
        // i >= 0 wherever this is called, and cap is a power of two.
        &self.slot[(i & (self.cap - 1)) as usize]
    }
}

#[repr(align(128))]
struct Line<T>(T);

pub struct Deque {
    top: Line<AIdx>,
    bottom: Line<AIdx>,
    array: AtomicPtr<Ring>,
    /// Plain, owner only; freed with the deque.
    retired: UnsafeCell<Vec<*mut Ring>>,
}

// SAFETY: `retired` is touched only by the owner (push/grow) and by Drop;
// everything else is atomic.
unsafe impl Sync for Deque {}
unsafe impl Send for Deque {}

impl Deque {
    pub fn new(log2: u32) -> Deque {
        Deque {
            top: Line(AIdx::new(0)),
            bottom: Line(AIdx::new(0)),
            array: AtomicPtr::new(Ring::new(1 << log2)),
            retired: UnsafeCell::new(Vec::new()),
        }
    }

    /// Owner only.
    pub fn push(&self, x: u64) {
        let b = self.bottom.0.load(Relaxed);
        let t = self.top.0.load(Acquire);
        let mut a = self.array.load(Relaxed);
        // SAFETY: `a` is the live ring or a retired one; neither is freed before the deque.
        if b - t > unsafe { (*a).cap } - 1 {
            a = self.grow(a, t, b);
        }
        unsafe { (*a).at(b) }.store(x, Relaxed);
        fence(Release);
        self.bottom.0.store(b + 1, PUSH_BOTTOM);
    }

    fn grow(&self, a: *mut Ring, t: Idx, b: Idx) -> *mut Ring {
        // SAFETY: owner only; `a` is live.
        let old = unsafe { &*a };
        let n = Ring::new(2 * old.cap);
        let nr = unsafe { &*n };
        let mut i = t;
        while i < b {
            nr.at(i).store(old.at(i).load(Relaxed), Relaxed);
            i += 1;
        }
        // SAFETY: only the owner touches `retired`.
        unsafe { (*self.retired.get()).push(a) };
        self.array.store(n, Release); // pairs with steal's Acquire load of array
        n
    }

    /// Owner only. EMPTY when there is nothing.
    pub fn take(&self) -> u64 {
        let b = self.bottom.0.load(Relaxed) - 1; // signed: -1 on a fresh deque
        let a = self.array.load(Relaxed);
        self.bottom.0.store(b, Relaxed);
        fence(BT_FENCE);
        let t = self.top.0.load(Relaxed);
        if t <= b {
            // SAFETY: `a` is the owner's current ring.
            let mut x = unsafe { (*a).at(b) }.load(Relaxed);
            if t == b {
                if self.top.0.compare_exchange(t, t + 1, SeqCst, Relaxed).is_err() {
                    x = EMPTY;
                }
                self.bottom.0.store(b + 1, Relaxed);
            }
            x
        } else {
            self.bottom.0.store(b + 1, Relaxed);
            EMPTY
        }
    }

    /// Any thread. EMPTY or ABORT when nothing was taken.
    pub fn steal(&self) -> u64 {
        let t = self.top.0.load(Acquire);
        fence(BT_FENCE);
        let b = self.bottom.0.load(Acquire);
        if t < b {
            let a = self.array.load(Acquire); // the paper's consume
            // SAFETY: rings are never freed while the deque lives.
            let x = unsafe { (*a).at(t) }.load(Relaxed);
            if self.top.0.compare_exchange(t, t + 1, SeqCst, Relaxed).is_err() {
                return ABORT;
            }
            return x;
        }
        EMPTY
    }

    /// bottom - top as seen now (try_park's emptiness test, SPEC §B.6).
    pub fn looks_nonempty(&self) -> bool {
        self.bottom.0.load(Acquire) - self.top.0.load(Acquire) > 0
    }
}

impl Drop for Deque {
    fn drop(&mut self) {
        // SAFETY: no other thread can reach the deque any more.
        unsafe {
            drop(Box::from_raw(self.array.load(Relaxed)));
            for r in (*self.retired.get()).drain(..) {
                drop(Box::from_raw(r));
            }
        }
    }
}

#[cfg(all(test, not(loom)))]
mod tests {
    use super::*;
    #[test]
    fn empty_and_lifo() {
        let q = Deque::new(1);
        assert_eq!(q.take(), EMPTY);
        assert_eq!(q.steal(), EMPTY);
        for i in 1..=100u64 {
            q.push(i);
        }
        for i in (51..=100u64).rev() {
            assert_eq!(q.take(), i);
        }
        for i in 1..=50u64 {
            assert_eq!(q.steal(), i);
        }
        assert_eq!(q.take(), EMPTY);
    }

    #[test]
    fn threads() {
        extern crate std;
        use std::sync::atomic::AtomicBool;
        use std::sync::Arc;
        const N: u64 = if cfg!(miri) { 300 } else { 100_000 };
        let q = Arc::new(Deque::new(1));
        let done = Arc::new(AtomicBool::new(false));
        let seen = Arc::new((0..=N).map(|_| AtomicU64::new(0)).collect::<Vec<_>>());
        let th: Vec<_> = (0..2)
            .map(|_| {
                let (q, done, seen) = (q.clone(), done.clone(), seen.clone());
                std::thread::spawn(move || loop {
                    let x = q.steal();
                    if x == ABORT {
                        continue;
                    }
                    if x == EMPTY {
                        if done.load(Acquire) {
                            break;
                        }
                        std::thread::yield_now();
                        continue;
                    }
                    seen[x as usize].fetch_add(1, Relaxed);
                })
            })
            .collect();
        for i in 1..=N {
            q.push(i);
            if i % 3 == 0 {
                let x = q.take();
                if x != EMPTY {
                    seen[x as usize].fetch_add(1, Relaxed);
                }
            }
        }
        loop {
            let x = q.take();
            if x == EMPTY {
                break;
            }
            seen[x as usize].fetch_add(1, Relaxed);
        }
        done.store(true, Release);
        for t in th {
            t.join().unwrap();
        }
        for i in 1..=N {
            assert_eq!(seen[i as usize].load(Relaxed), 1, "item {i}");
        }
    }
}
