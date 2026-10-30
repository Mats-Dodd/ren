//! ren_core, the Rust entry of the native-lang slice (SPEC.md).
//!
//! One staticlib exporting, with the C ABI of harness/slice.h:
//! the nine host functions and the seven emitted-code functions (`sched`),
//! the Chase-Lev deque (`deque`, plus `ren_dq_*`), the Linux epoll and
//! io_uring drivers, the replay/fuzz driver (`drv`), and the layout table.
//!
//! Feature `std` (default) links Rust std; without it the crate is
//! `no_std + alloc` over libc malloc. Either way the code below only uses
//! `core`, `alloc` and the `libc` crate, so the two variants differ only in
//! the runtime around them. Under `--cfg loom` only the deque is built
//! (with loom's atomics) for the model test in tests/loom_deque.rs.
#![cfg_attr(not(feature = "std"), no_std)]
#![allow(clippy::missing_safety_doc, clippy::new_without_default)]

extern crate alloc;

/// The bindgen view of harness/slice.h (generated into OUT_DIR, never checked in).
#[allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, clippy::all)]
pub mod sys {
    include!(concat!(env!("OUT_DIR"), "/slice.rs"));
}

pub mod sync;
pub mod deque;

#[cfg(not(loom))]
mod rt;
#[cfg(not(loom))]
pub mod journal;
#[cfg(not(loom))]
pub mod sched;
#[cfg(not(loom))]
pub mod drv;
#[cfg(not(loom))]
pub mod ffi;
#[cfg(not(loom))]
pub mod layout;
