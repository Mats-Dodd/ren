//! ren_hot: the W5 hot path in Rust (SPEC §E), `extern "C"` from a no_std
//! staticlib. Variant (iii) as built with release-hot; variant (v) with
//! lto-hot (-Clinker-plugin-lto, linked by clang-22 -flto=thin / lld-22).
#![no_std]

#[allow(non_camel_case_types, non_upper_case_globals, non_snake_case, dead_code, clippy::all)]
mod sys {
    include!(concat!(env!("OUT_DIR"), "/slice.rs"));
}
use core::ptr::addr_of_mut;
use core::sync::atomic::{fence, AtomicI32, Ordering::*};
use sys::{ren_array, ren_obj, ren_obj_free};

/// The count, read the way ren_rt.h's REN_RC_PLAIN_READ does: a relaxed
/// atomic load (the same `mov` on x86-64) because a negative count may be
/// moving under other threads, and a plain read racing an atomic RMW is a
/// data race in Rust's model.
#[inline(always)]
unsafe fn rc_cell<'a>(o: *mut ren_obj) -> &'a AtomicI32 {
    AtomicI32::from_ptr(addr_of_mut!((*o).rc))
}

#[no_mangle]
pub unsafe extern "C" fn ren_hot_dup(o: *mut ren_obj) {
    let c = rc_cell(o);
    let rc = c.load(Relaxed);
    if rc > 0 {
        (*o).rc = rc + 1; // owned: only this thread can see a positive count
    } else if rc != 0 {
        c.fetch_add(-1, Relaxed);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ren_hot_drop(o: *mut ren_obj) {
    let c = rc_cell(o);
    let rc = c.load(Relaxed);
    if rc > 1 {
        (*o).rc = rc - 1;
    } else if rc == 1 {
        ren_obj_free(o);
    } else if rc != 0 && c.fetch_add(1, Release) == -1 {
        fence(Acquire); // Arc's drop
        ren_obj_free(o);
    }
}

#[no_mangle]
#[inline(never)]
#[cold]
pub unsafe extern "C" fn ren_hot_array_grow(a: *mut ren_array) {
    let cap: u32 = if (*a).cap != 0 { 2 * (*a).cap } else { 8 };
    let d = libc::realloc((*a).data as *mut libc::c_void, cap as usize * 8) as *mut i64;
    if d.is_null() {
        libc::abort();
    }
    (*a).data = d;
    (*a).cap = cap;
}

#[no_mangle]
pub unsafe extern "C" fn ren_hot_array_push(a: *mut ren_array, v: i64) {
    if (*a).len == (*a).cap {
        ren_hot_array_grow(a);
    }
    *(*a).data.add((*a).len as usize) = v;
    (*a).len += 1;
}

#[cfg(not(test))]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    // SAFETY: abort(3) has no preconditions.
    unsafe { libc::abort() }
}

/// Every export has bindgen's type for its slice.h declaration.
#[allow(dead_code)]
fn sig_check(b: bool) {
    let _ = if b { sys::ren_hot_dup } else { ren_hot_dup };
    let _ = if b { sys::ren_hot_drop } else { ren_hot_drop };
    let _ = if b { sys::ren_hot_array_push } else { ren_hot_array_push };
    let _ = if b { sys::ren_hot_array_grow } else { ren_hot_array_grow };
}
