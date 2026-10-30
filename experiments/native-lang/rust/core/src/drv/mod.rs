//! The drivers (SPEC §C, §D): one `Drv` per run, behind slice.h §8.
//! - epoll and io_uring share the loop in `linux.rs` (C.1);
//! - replay and fuzz are in `replay.rs` (D.1, D.4).
use crate::journal::{self, Enc};
use crate::sys::*;
use alloc::boxed::Box;
use alloc::vec::Vec;
use core::cell::UnsafeCell;
use core::ffi::{c_char, c_void};
use core::mem::size_of;
use core::ptr::null_mut;
use core::sync::atomic::{AtomicBool, AtomicPtr, Ordering::*};

mod epoll;
mod linux;
mod replay;
mod uring;

pub enum Backend {
    Epoll(Box<[UnsafeCell<epoll::EpW>]>),
    Uring(Box<[UnsafeCell<uring::UrW>]>),
    Replay(replay::Replay),
    Fuzz(UnsafeCell<replay::Fuzz>),
}

pub struct Drv {
    pub o: ren_drv_opts,
    pub host: ren_host,
    pub be: Backend,
    /// per-worker eventfds (epoll, io_uring): host.wake writes 1
    pub evfd: Vec<i32>,
    /// per-worker storage for answer_now's result (read during the call only)
    now: Box<[UnsafeCell<ren_io_result>]>,
    rec_lock: AtomicBool,
    err_set: AtomicBool,
    err: UnsafeCell<[u8; 256]>,
    /// what J_DRV records as the driver kind (io_uring: | flags << 16 on fallback)
    pub drv_word: u32,
}

// SAFETY: per-worker backend state is touched only by that worker's driver
// thread (`ren_drv_worker(d, c, w)`); replay and fuzz run on one thread;
// the record fd is written under `rec_lock`; `err` is written once (the
// first error wins, guarded by `err_set`) and read after the workers join.
unsafe impl Sync for Drv {}

static GERR: AtomicPtr<c_char> = AtomicPtr::new(c"".as_ptr() as *mut c_char);
fn set_gerr(m: &'static core::ffi::CStr) {
    GERR.store(m.as_ptr() as *mut c_char, Release);
}

pub fn errno() -> i32 {
    // SAFETY: __errno_location is always valid on the calling thread.
    unsafe { *libc::__errno_location() }
}

pub fn mono_ns() -> i64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: ts is a valid out-pointer.
    unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    ts.tv_sec * 1_000_000_000 + ts.tv_nsec
}

pub const RES0: ren_io_result = ren_io_result { res: 0, a: 0, b: 0 };
pub const CANCELLED_RES: ren_io_result = ren_io_result { res: -(REN_ECANCELED as i64), a: 0, b: 0 };
pub fn res1(r: i64) -> ren_io_result {
    ren_io_result { res: r, a: 0, b: 0 }
}

impl Drv {
    pub fn set_err(&self, m: &str) {
        if self.err_set.swap(true, AcqRel) {
            return;
        }
        // SAFETY: only the first caller gets here (err_set).
        let e = unsafe { &mut *self.err.get() };
        let n = core::cmp::min(m.len(), e.len() - 1);
        e[..n].copy_from_slice(&m.as_bytes()[..n]);
        e[n] = 0;
    }
    pub fn has_err(&self) -> bool {
        self.err_set.load(Acquire)
    }
    #[inline]
    pub fn recording(&self) -> bool {
        self.o.record_fd >= 0
    }
    pub fn rec_bytes(&self, b: &[u8]) {
        while self.rec_lock.swap(true, Acquire) {
            core::hint::spin_loop();
        }
        let mut p = b;
        while !p.is_empty() {
            // SAFETY: valid buffer; record_fd belongs to the harness.
            let n = unsafe { libc::write(self.o.record_fd, p.as_ptr().cast(), p.len()) };
            if n < 0 {
                if errno() == libc::EINTR {
                    continue;
                }
                crate::rt::die("record: write failed");
            }
            p = &p[n as usize..];
        }
        self.rec_lock.store(false, Release);
    }
    pub fn rec(&self, kind: u32, w: i32, step: u64, payload: &[u8]) {
        if self.recording() {
            self.rec_bytes(&journal::entry(kind, w, step, payload));
        }
    }
    pub unsafe fn rec_pull(&self, c: *mut ren_core, w: i32, k: &ren_call) {
        if self.recording() {
            let mut e = Enc::new();
            journal::call(&mut e, k);
            self.rec(REN_J_PULL, w, ren_progress(c, w), &e.0);
        }
    }
    /// ren_reply plus its J_REPLY entry. `inout` = what the driver wrote into
    /// a READ buffer; it is encoded before ren_reply, after which the driver
    /// must not read the buffer (SPEC §C.1, the buffer rule).
    pub unsafe fn reply(&self, c: *mut ren_core, w: i32, id: u64, state: u32, r: ren_io_result, inout: &[u8]) -> i32 {
        let mut e = Enc::new();
        if self.recording() {
            journal::reply_body(&mut e, id, state, &r, inout);
        }
        let rp = ren_reply_t {
            id,
            state,
            len: size_of::<ren_io_result>() as u32,
            body: &r as *const ren_io_result as *const c_void,
        };
        let ret = ren_reply(c, &rp);
        if self.recording() {
            e.i32(ret);
            self.rec(REN_J_REPLY, w, ren_progress(c, w), &e.0);
        }
        ret
    }
}

// ---- host callbacks for the Linux drivers ----
unsafe extern "C" fn h_wake(hp: *mut c_void, w: i32) {
    let d = &*(hp as *const Drv);
    if let Some(&fd) = d.evfd.get(w as usize) {
        let one: u64 = 1;
        // Sticky and idempotent: the counter only grows until the worker drains it.
        libc::write(fd, &one as *const u64 as *const c_void, 8);
    }
}
unsafe extern "C" fn h_answer(hp: *mut c_void, w: i32, call: *const ren_call, out: *mut ren_reply_t) -> bool {
    let d = &*(hp as *const Drv);
    if (*call).op != REN_OP_MONO_NOW {
        return false;
    }
    let slot = d.now[w as usize].get();
    *slot = res1(mono_ns());
    *out = ren_reply_t { id: (*call).id, state: REN_DONE, len: size_of::<ren_io_result>() as u32, body: slot as *const c_void };
    true
}
unsafe extern "C" fn h_journal(hp: *mut c_void, _w: i32, e: *const c_void, n: usize) {
    let d = &*(hp as *const Drv);
    d.rec_bytes(core::slice::from_raw_parts(e as *const u8, n));
}

// ================= slice.h §8 =================
#[no_mangle]
pub unsafe extern "C" fn ren_drv_new(o: *const ren_drv_opts) -> *mut ren_drv {
    if o.is_null() {
        set_gerr(c"ren_drv_new: NULL options");
        return null_mut();
    }
    let mut o = *o;
    if o.workers < 1 || o.workers > 64 {
        set_gerr(c"ren_drv_new: workers must be 1..64");
        return null_mut();
    }
    if o.steps == 0 {
        o.steps = 256;
    }
    let nw = o.workers as usize;
    let mut host = ren_host { wake: Some(h_wake), answer_now: Some(h_answer), pages: None, journal: None };
    if o.record_fd >= 0 {
        host.journal = Some(h_journal);
    }
    let mut evfd = Vec::new();
    let mut drv_word = o.kind;
    let be = match o.kind {
        REN_DRV_EPOLL | REN_DRV_URING => {
            for _ in 0..nw {
                let fd = libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC);
                if fd < 0 {
                    set_gerr(c"ren_drv_new: eventfd failed");
                    for f in evfd {
                        libc::close(f);
                    }
                    return null_mut();
                }
                evfd.push(fd);
            }
            if o.kind == REN_DRV_EPOLL {
                Backend::Epoll((0..nw).map(|w| UnsafeCell::new(epoll::EpW::new(evfd[w]))).collect())
            } else {
                match uring::new_rings(&o, &evfd) {
                    Ok((ws, fallback)) => {
                        if fallback {
                            drv_word |= REN_DRV_F_URING_NO_DEFER << 16;
                        }
                        Backend::Uring(ws)
                    }
                    Err(m) => {
                        set_gerr(m);
                        for f in evfd {
                            libc::close(f);
                        }
                        return null_mut();
                    }
                }
            }
        }
        REN_DRV_REPLAY => {
            if o.input.is_null() && o.input_len > 0 {
                set_gerr(c"ren_drv_new: REPLAY without input");
                return null_mut();
            }
            host.wake = Some(replay::h_wake_nop);
            host.answer_now = Some(replay::h_answer_replay);
            host.journal = Some(replay::h_journal_replay);
            Backend::Replay(replay::Replay::new(&o))
        }
        REN_DRV_FUZZ => {
            host.wake = Some(replay::h_wake_nop);
            host.answer_now = None;
            host.journal = None;
            Backend::Fuzz(UnsafeCell::new(replay::Fuzz::new(&o)))
        }
        _ => {
            set_gerr(c"ren_drv_new: unknown driver kind");
            return null_mut();
        }
    };
    let d = Box::new(Drv {
        o,
        host,
        be,
        evfd,
        now: (0..nw).map(|_| UnsafeCell::new(RES0)).collect(),
        rec_lock: AtomicBool::new(false),
        err_set: AtomicBool::new(false),
        err: UnsafeCell::new([0; 256]),
        drv_word,
    });
    Box::into_raw(d) as *mut ren_drv
}

#[no_mangle]
pub unsafe extern "C" fn ren_drv_host(d: *mut ren_drv, hostp: *mut *mut c_void) -> *const ren_host {
    let dr = &*(d as *const Drv);
    if !hostp.is_null() {
        *hostp = d as *mut c_void;
    }
    &dr.host
}

#[no_mangle]
pub unsafe extern "C" fn ren_drv_worker(d: *mut ren_drv, c: *mut ren_core, worker: i32) -> i32 {
    let dr = &*(d as *const Drv);
    match &dr.be {
        Backend::Epoll(_) | Backend::Uring(_) if worker < 0 || worker as usize >= dr.evfd.len() => {
            dr.set_err("ren_drv_worker: the Linux drivers take one worker per thread (worker >= 0)");
            -1
        }
        Backend::Epoll(ws) => linux::drive(dr, c, worker, &mut *ws[worker as usize].get()),
        Backend::Uring(ws) => linux::drive(dr, c, worker, &mut *ws[worker as usize].get()),
        Backend::Replay(r) => r.run(dr, c),
        Backend::Fuzz(f) => (*f.get()).run(dr, c),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ren_drv_finish(d: *mut ren_drv, _c: *mut ren_core) -> i32 {
    let dr = &*(d as *const Drv);
    match &dr.be {
        Backend::Replay(r) => r.result(),
        Backend::Fuzz(f) => (*f.get()).result(),
        _ => {
            if dr.has_err() {
                -1
            } else {
                0
            }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn ren_drv_free(d: *mut ren_drv) {
    if d.is_null() {
        return;
    }
    let dr = Box::from_raw(d as *mut Drv);
    for &fd in dr.evfd.iter() {
        libc::close(fd);
    }
    drop(dr);
}

#[no_mangle]
pub unsafe extern "C" fn ren_drv_last_error(d: *mut ren_drv) -> *const c_char {
    if d.is_null() {
        return GERR.load(Acquire);
    }
    let dr = &*(d as *const Drv);
    match &dr.be {
        Backend::Replay(r) if r.diverged() => r.err_ptr(),
        Backend::Fuzz(f) if (*f.get()).failed() => (*f.get()).err_ptr(),
        _ => {
            if dr.has_err() {
                (*dr.err.get()).as_ptr() as *const c_char
            } else {
                c"".as_ptr()
            }
        }
    }
}
