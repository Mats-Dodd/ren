//! The C ABI of slice.h §5, §6 and §9: thin `extern "C"` shims over
//! `sched::Core` and `deque::Deque`. `sig_check` makes rustc compare every
//! export's signature with bindgen's declaration of it.
use crate::deque::Deque;
use crate::sched::{self, Core, Ctx};
use crate::sys::*;
use alloc::boxed::Box;
use core::ffi::c_void;

#[inline]
unsafe fn core<'a>(c: *mut ren_core) -> &'a Core {
    &*(c as *const Core)
}

// ---- the nine host functions ----
#[no_mangle]
pub unsafe extern "C" fn ren_start(
    cfg: *const ren_config,
    main: ren_main_fn,
    host: *const ren_host,
    hostp: *mut c_void,
) -> *mut ren_core {
    if cfg.is_null() || host.is_null() {
        return core::ptr::null_mut();
    }
    Core::start(&*cfg, main, &*host, hostp) as *mut ren_core
}
#[no_mangle]
pub unsafe extern "C" fn ren_thread_init(c: *mut ren_core, worker: i32, stack_lo: *mut c_void, stack_size: usize) {
    core(c).thread_init(worker, stack_lo, stack_size)
}
#[no_mangle]
pub unsafe extern "C" fn ren_run(c: *mut ren_core, worker: i32, steps: u32) -> i32 {
    core(c).run(worker, steps)
}
#[no_mangle]
pub unsafe extern "C" fn ren_poll_call(c: *mut ren_core, worker: i32, out: *mut ren_call) -> bool {
    core(c).poll_call(worker, out)
}
#[no_mangle]
pub unsafe extern "C" fn ren_reply(c: *mut ren_core, r: *const ren_reply_t) -> i32 {
    core(c).reply(&*r)
}
#[no_mangle]
pub unsafe extern "C" fn ren_stop(c: *mut ren_core) {
    core(c).stop()
}
#[no_mangle]
pub unsafe extern "C" fn ren_kill(c: *mut ren_core) {
    core(c).kill()
}
#[no_mangle]
pub unsafe extern "C" fn ren_free(c: *mut ren_core) {
    if !c.is_null() {
        Core::free(c as *mut Core)
    }
}
#[no_mangle]
pub unsafe extern "C" fn ren_progress(c: *mut ren_core, worker: i32) -> u64 {
    core(c).progress(worker)
}

// ---- the emitted-code ABI ----
#[no_mangle]
pub unsafe extern "C" fn ren_spawn(cx: *mut ren_ctx, t: *mut ren_task) {
    let x = Ctx::from(cx);
    x.core().spawn(x.worker(), t)
}
#[no_mangle]
pub unsafe extern "C" fn ren_notify(cx: *mut ren_ctx, t: *mut ren_task) {
    sched::notify(Ctx::from(cx), t)
}
#[no_mangle]
pub unsafe extern "C" fn ren_world(
    cx: *mut ren_ctx,
    self_: *mut ren_task,
    aw: *mut ren_await,
    op: u32,
    body: *const ren_io_body,
) -> i32 {
    let x = Ctx::from(cx);
    x.core().world(x.worker(), self_, aw, op, body)
}
#[no_mangle]
pub unsafe extern "C" fn ren_cancel(cx: *mut ren_ctx, id: u64) {
    let x = Ctx::from(cx);
    x.core().cancel(x.worker(), id)
}
#[no_mangle]
pub unsafe extern "C" fn ren_tick(cx: *mut ren_ctx) -> bool {
    Ctx::from(cx).tick()
}
#[no_mangle]
pub unsafe extern "C" fn ren_cancelled(cx: *mut ren_ctx) -> bool {
    Ctx::from(cx).core().cancelled()
}
#[no_mangle]
pub unsafe extern "C" fn ren_ctx_worker(cx: *mut ren_ctx) -> i32 {
    Ctx::from(cx).worker()
}

// ---- the deque test ABI (the same Deque the core uses) ----
#[no_mangle]
pub unsafe extern "C" fn ren_dq_new(log2_cap: u32) -> *mut ren_dq {
    Box::into_raw(Box::new(Deque::new(log2_cap))) as *mut ren_dq
}
#[no_mangle]
pub unsafe extern "C" fn ren_dq_push(q: *mut ren_dq, v: u64) {
    (*(q as *const Deque)).push(v)
}
#[no_mangle]
pub unsafe extern "C" fn ren_dq_take(q: *mut ren_dq) -> u64 {
    (*(q as *const Deque)).take()
}
#[no_mangle]
pub unsafe extern "C" fn ren_dq_steal(q: *mut ren_dq) -> u64 {
    (*(q as *const Deque)).steal()
}
#[no_mangle]
pub unsafe extern "C" fn ren_dq_free(q: *mut ren_dq) {
    if !q.is_null() {
        drop(Box::from_raw(q as *mut Deque))
    }
}

/// Each export must have exactly the type bindgen gives the declaration in
/// slice.h: the `if` forces both fn items to one fn-pointer type.
#[allow(dead_code, unused_assignments)]
fn sig_check(b: bool) {
    macro_rules! same {
        ($($n:ident),*) => { $( let _f = if b { crate::sys::$n } else { $n }; )* };
    }
    same!(ren_start, ren_thread_init, ren_run, ren_poll_call, ren_reply, ren_stop, ren_kill, ren_free,
          ren_progress, ren_spawn, ren_notify, ren_world, ren_cancel, ren_tick, ren_cancelled,
          ren_ctx_worker, ren_dq_new, ren_dq_push, ren_dq_take, ren_dq_steal, ren_dq_free,
          ren_layout_table, ren_drv_new, ren_drv_host, ren_drv_worker, ren_drv_finish, ren_drv_free,
          ren_drv_last_error);
}

pub use crate::drv::{ren_drv_finish, ren_drv_free, ren_drv_host, ren_drv_last_error, ren_drv_new, ren_drv_worker};
pub use crate::layout::ren_layout_table;
