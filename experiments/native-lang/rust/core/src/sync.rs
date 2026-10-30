//! Atomics for the deque: core's, or loom's under `--cfg loom`.
#[cfg(loom)]
pub use loom::sync::atomic::{fence, AtomicI64, AtomicPtr, AtomicU64, Ordering};
#[cfg(not(loom))]
pub use core::sync::atomic::{fence, AtomicI64, AtomicPtr, AtomicU64, Ordering};
