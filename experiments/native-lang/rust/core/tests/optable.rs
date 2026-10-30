//! Op-table and core tests in pure Rust, so they also run under Miri
//! (`cargo +nightly miri test`): no harness C is linked, so this file
//! provides the harness symbols the core imports (ren_rc_dup, ren_rc_drop,
//! ren_obj_free) with SPEC §E's semantics, and frames written in Rust the
//! way Ren's compiler would emit them. Mirrors harness/tests/abi_test.c's
//! basic, stale, retract, cancel_race, stop and full.
#![allow(clippy::missing_safety_doc)]
#[allow(unused_imports)]
use ::ren_core::ffi as _; // the exports; called below through the slice.h declarations
use ::ren_core::sys::*;
use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::ffi::c_void;
use std::ptr::{addr_of_mut, null_mut};
use std::sync::atomic::{AtomicI32, AtomicI64, Ordering::*};

// ---------------- the harness side (rt.c, in Rust) ----------------
const FRAME: Layout = match Layout::from_size_align(256, 16) {
    Ok(l) => l,
    Err(_) => panic!(),
};

#[no_mangle]
pub unsafe extern "C" fn ren_obj_free(o: *mut ren_obj) {
    if (*o).tag as u32 == REN_TAG_TASK {
        let t = o as *mut ren_task;
        if let Some(f) = (*t).fin {
            f(t);
        }
    }
    dealloc(o as *mut u8, FRAME);
}
#[no_mangle]
pub unsafe extern "C" fn ren_rc_dup(o: *mut ren_obj) {
    let c = AtomicI32::from_ptr(addr_of_mut!((*o).rc));
    let rc = c.load(Relaxed);
    if rc > 0 {
        (*o).rc = rc + 1;
    } else if rc != 0 {
        c.fetch_add(-1, Relaxed);
    }
}
#[no_mangle]
pub unsafe extern "C" fn ren_rc_drop(o: *mut ren_obj) {
    let c = AtomicI32::from_ptr(addr_of_mut!((*o).rc));
    let rc = c.load(Relaxed);
    if rc > 1 {
        (*o).rc = rc - 1;
    } else if rc == 1 {
        ren_obj_free(o);
    } else if rc != 0 && c.fetch_add(1, Release) == -1 {
        std::sync::atomic::fence(Acquire);
        ren_obj_free(o);
    }
}
unsafe fn task_new(resume: ren_resume_fn) -> *mut ren_task {
    let t = alloc_zeroed(FRAME) as *mut ren_task;
    (*t).obj.rc = -1;
    (*t).obj.tag = REN_TAG_TASK as u16;
    (*t).resume = resume;
    t
}

// ---------------- the test host ----------------
/// The callbacks are called from any thread (ren_reply, ren_stop, other
/// workers), so the host's state is atomic or locked. (Miri found the first
/// version of this test host appending to a Vec from two workers at once.)
#[derive(Default)]
struct Host {
    wakes: [AtomicI32; 8],
    j: std::sync::Mutex<Vec<u8>>,
}
unsafe extern "C" fn th_wake(h: *mut c_void, w: i32) {
    (*(h as *const Host)).wakes[w as usize].fetch_add(1, Relaxed);
}
unsafe extern "C" fn th_journal(h: *mut c_void, _w: i32, e: *const c_void, n: usize) {
    (*(h as *const Host)).j.lock().unwrap().extend_from_slice(std::slice::from_raw_parts(e as *const u8, n));
}
static VT: ren_host = ren_host { wake: Some(th_wake), answer_now: None, pages: None, journal: Some(th_journal) };

fn kinds(h: &Host) -> Vec<u32> {
    let j = h.j.lock().unwrap();
    let (mut v, mut p) = (Vec::new(), 0);
    while p + 24 <= j.len() {
        let k = u32::from_le_bytes(j[p..p + 4].try_into().unwrap());
        let l = u32::from_le_bytes(j[p + 4..p + 8].try_into().unwrap()) as usize;
        v.push(k);
        p += 24 + l;
    }
    v
}
fn cancel_how(h: &Host, id: u64) -> Option<u32> {
    let j = h.j.lock().unwrap();
    let mut p = 0;
    while p + 24 <= j.len() {
        let k = u32::from_le_bytes(j[p..p + 4].try_into().unwrap());
        let l = u32::from_le_bytes(j[p + 4..p + 8].try_into().unwrap()) as usize;
        if k == REN_J_CANCEL && u64::from_le_bytes(j[p + 24..p + 32].try_into().unwrap()) == id {
            return Some(u32::from_le_bytes(j[p + 32..p + 36].try_into().unwrap()));
        }
        p += 24 + l;
    }
    None
}

// ---------------- frames ----------------
/// Shared test state (cfg.user).
struct St {
    ncalls: i32,
    cancel_own: bool,
    nspawn: i32,
    root: usize,
    left: AtomicI64,
    ids: [u64; 64],
    states: [[i32; 4]; 64],
    res: [[i64; 4]; 64],
    done: [i32; 64],
}
impl Default for St {
    fn default() -> Self {
        // SAFETY: every field is an integer, a bool or an atomic: all-zero is valid.
        unsafe { std::mem::zeroed() }
    }
}
#[repr(C)]
struct Caller {
    h: ren_task,
    st: *mut St,
    aw: ren_await,
    k: usize,
    i: i32,
    buf: [u8; 8],
}
unsafe extern "C" fn caller_resume(me: *mut ren_task, cx: *mut ren_ctx) -> i32 {
    // Raw-pointer access to the shared state: callers on other workers use
    // it at the same time (no &mut St may exist across threads).
    let f = me as *mut Caller;
    let s = (*f).st;
    let k = (*f).k;
    loop {
        if (*me).pc == 0 {
            if (*f).i == (*s).ncalls {
                break;
            }
            let b = ren_io_body { fd: 7, len: 8, buf: addr_of_mut!((*f).buf) as u64, arg: 0 };
            let r = ren_world(cx, me, addr_of_mut!((*f).aw), REN_OP_READ, &b);
            if r == REN_W_FULL as i32 {
                return REN_T_YIELD as i32;
            }
            (*s).ids[k] = (*f).aw.id;
            (*me).pc = 1;
            if (*s).cancel_own {
                ren_cancel(cx, (*f).aw.id);
            }
            if r == REN_W_PENDING as i32 {
                return REN_T_PARK as i32;
            }
        }
        let st = AtomicI32::from_ptr(addr_of_mut!((*f).aw.state)).load(Acquire);
        if st == 0 {
            return REN_T_PARK as i32;
        }
        let i = (*f).i as usize;
        (*s).states[k][i] = st;
        (*s).res[k][i] = (*f).aw.res.res;
        (*f).i += 1;
        (*s).done[k] = (*f).i;
        (*me).pc = 0;
    }
    if me as usize != (*s).root && (*s).left.fetch_sub(1, AcqRel) == 1 {
        ren_notify(cx, (*s).root as *mut ren_task);
    }
    REN_T_DONE as i32
}
unsafe extern "C" fn caller_fin(me: *mut ren_task) {
    let s = (*(me as *mut Caller)).st;
    if (*s).root != 0 && (*s).root != me as usize {
        ren_rc_drop((*s).root as *mut ren_obj);
    }
}
unsafe fn new_caller(s: *mut St, k: usize) -> *mut ren_task {
    let t = task_new(Some(caller_resume));
    (*t).fin = Some(caller_fin);
    let c = t as *mut Caller;
    (*c).st = s;
    (*c).k = k;
    t
}
unsafe extern "C" fn main_caller(cfg: *const ren_config) -> *mut ren_task {
    let s = (*cfg).user as *mut St;
    let t = new_caller(s, 0);
    (*s).root = t as usize;
    t
}
#[repr(C)]
struct Parent {
    h: ren_task,
    st: *mut St,
}
unsafe extern "C" fn parent_resume(me: *mut ren_task, cx: *mut ren_ctx) -> i32 {
    let s = (*(me as *mut Parent)).st;
    if (*me).pc == 0 {
        (*s).root = me as usize;
        (*s).left.store((*s).nspawn as i64, Relaxed);
        for k in 1..=(*s).nspawn as usize {
            ren_rc_dup(me as *mut ren_obj);
            ren_spawn(cx, new_caller(s, k));
        }
        (*me).pc = 1;
    }
    if (*s).left.load(Acquire) != 0 {
        REN_T_PARK as i32
    } else {
        REN_T_DONE as i32
    }
}
unsafe extern "C" fn main_parent(cfg: *const ren_config) -> *mut ren_task {
    let t = task_new(Some(parent_resume));
    (*(t as *mut Parent)).st = (*cfg).user as *mut St;
    t
}

// ---------------- helpers ----------------
/// Host and state live behind raw pointers for the whole test: the core
/// keeps them, so the test must not reborrow them as &mut (Stacked Borrows;
/// Miri caught the first version doing that).
unsafe fn start(h: *mut Host, s: *mut St, m: ren_main_fn, workers: i32, slots: u32) -> *mut ren_core {
    let cfg = ren_config {
        workers,
        budget_b: 0,
        poll_k: 0,
        op_slots: slots,
        deque_log2: 2,
        journal_policy: 0,
        build_id: c"optable".as_ptr(),
        user: s as *mut c_void,
    };
    let c = ren_start(&cfg, m, &VT, h as *mut c_void);
    assert!(!c.is_null());
    for w in 0..workers {
        ren_thread_init(c, w, null_mut(), 0);
    }
    c
}
unsafe fn reply(c: *mut ren_core, id: u64, state: u32, res: i64) -> i32 {
    let r = ren_io_result { res, a: 0, b: 0 };
    let rp = ren_reply_t { id, state, len: 24, body: &r as *const _ as *const c_void };
    ren_reply(c, &rp)
}
unsafe fn poll(c: *mut ren_core, w: i32) -> Option<ren_call> {
    let mut k: ren_call = std::mem::zeroed();
    if ren_poll_call(c, w, &mut k) {
        Some(k)
    } else {
        None
    }
}
const IDLE: i32 = REN_IDLE as i32;
const FIN: i32 = REN_FINISHED as i32;
const ACC: i32 = REN_ACCEPTED as i32;
const REL: i32 = REN_RELEASE as i32;

fn bx<T>(v: T) -> *mut T {
    Box::into_raw(Box::new(v))
}
unsafe fn unbx<T>(p: *mut T) {
    drop(Box::from_raw(p))
}

// ---------------- tests ----------------
#[test]
fn basic() {
    unsafe {
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 1, ..Default::default() }));
        let c = start(h, s, Some(main_caller), 1, 0);
        assert_eq!(ren_run(c, 0, 16), IDLE);
        let k = poll(c, 0).unwrap();
        assert!(k.kind as u32 == REN_CALL && k.op == REN_OP_READ && k.id == (*s).ids[0] && k.task == 1);
        assert!(poll(c, 0).is_none());
        assert_eq!(reply(c, k.id, REN_DONE, 5), ACC);
        assert_eq!((*h).wakes[0].load(Relaxed), 1);
        assert_eq!(reply(c, k.id, REN_DONE, 6), REL); // duplicate
        assert_eq!(ren_run(c, 0, 16), FIN);
        assert_eq!(((*s).states[0][0], (*s).res[0][0]), (REN_DONE as i32, 5));
        assert_eq!(reply(c, k.id, REN_DONE, 7), REL); // stale
        assert_eq!(reply(c, 0, REN_DONE, 7), REL);
        assert_eq!(reply(c, !0, REN_DONE, 7), REL);
        let ks = kinds(&*h);
        assert_eq!(&ks[..5], &[REN_J_HEADER, REN_J_CALL, REN_J_RELEASE, REN_J_DELIVER, REN_J_END]);
        ren_free(c);
        unbx(h);
        unbx(s);
    }
}

#[test]
fn stale_after_reuse() {
    unsafe {
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 2, ..Default::default() }));
        let c = start(h, s, Some(main_caller), 1, 0);
        assert_eq!(ren_run(c, 0, 16), IDLE);
        let a = poll(c, 0).unwrap().id;
        assert!(poll(c, 0).is_none());
        assert_eq!(reply(c, a, REN_DONE, 1), ACC);
        assert_eq!(ren_run(c, 0, 16), IDLE);
        let b = poll(c, 0).unwrap().id;
        assert_eq!(b >> 32, a >> 32); // the same slot
        assert_eq!(b as u32, a as u32 + 1); // next generation
        assert_eq!(reply(c, a, REN_DONE, 0x5A1E5A1E), REL);
        assert_eq!(reply(c, b, REN_DONE, 2), ACC);
        assert_eq!(ren_run(c, 0, 16), FIN);
        assert_eq!(((*s).res[0][0], (*s).res[0][1]), (1, 2));
        ren_free(c);
        unbx(h);
        unbx(s);
    }
}

#[test]
fn retract() {
    unsafe {
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 1, cancel_own: true, ..Default::default() }));
        let c = start(h, s, Some(main_caller), 1, 0);
        ren_run(c, 0, 16);
        assert!(poll(c, 0).is_none());
        assert_eq!(ren_run(c, 0, 16), FIN);
        assert_eq!(((*s).states[0][0], (*s).res[0][0]), (REN_CANCELLED as i32, -125));
        assert_eq!(cancel_how(&*h, (*s).ids[0]), Some(REN_JC_RETRACT));
        assert_eq!(reply(c, (*s).ids[0], REN_DONE, 1), REL);
        ren_free(c);
        unbx(h);
        unbx(s);
    }
}

#[test]
fn stop_cancels_pulled() {
    unsafe {
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 2, nspawn: 3, ..Default::default() }));
        let c = start(h, s, Some(main_parent), 1, 8);
        assert_eq!(ren_run(c, 0, 16), IDLE);
        let got: Vec<ren_call> = (0..3).map(|_| poll(c, 0).unwrap()).collect();
        assert!(poll(c, 0).is_none());
        let before = (*h).wakes[0].load(Relaxed);
        ren_stop(c);
        assert_eq!((*h).wakes[0].load(Relaxed), before + 1);
        for g in &got {
            let k = poll(c, 0).unwrap();
            assert!(k.kind as u32 == REN_CANCEL && k.id == g.id);
        }
        assert!(poll(c, 0).is_none());
        for g in &got {
            assert_eq!(reply(c, g.id, REN_CANCELLED, -125), ACC);
        }
        assert_eq!(ren_run(c, 0, 64), FIN);
        for t in 1..=3 {
            assert_eq!((*s).done[t], 2);
            assert_eq!((*s).states[t][1], REN_CANCELLED as i32);
        }
        ren_free(c);
        unbx(h);
        unbx(s);
    }
}

#[test]
fn full_then_slot_frees() {
    unsafe {
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 1, nspawn: 3, ..Default::default() }));
        let c = start(h, s, Some(main_parent), 1, 2);
        ren_run(c, 0, 16);
        let (k1, k2) = (poll(c, 0).unwrap(), poll(c, 0).unwrap());
        assert!(poll(c, 0).is_none()); // the third caller got REN_W_FULL and yielded
        assert_eq!(reply(c, k1.id, REN_DONE, 1), ACC);
        ren_run(c, 0, 16);
        let k3 = poll(c, 0).unwrap();
        assert_eq!(reply(c, k2.id, REN_DONE, 1), ACC);
        assert_eq!(reply(c, k3.id, REN_DONE, 1), ACC);
        let mut fin = false;
        for _ in 0..100 {
            if ren_run(c, 0, 64) == FIN {
                fin = true;
                break;
            }
            while poll(c, 0).is_some() {}
        }
        assert!(fin);
        ren_free(c);
        unbx(h);
        unbx(s);
    }
}

/// Two workers driven by two real threads, replies from a third: the
/// cross-thread paths (inbox MPSC, wake, steal) under Miri's data-race detector.
#[test]
fn threads_reply_from_elsewhere() {
    unsafe {
        let n = if cfg!(miri) { 6 } else { 40 };
        let (h, s) = (bx(Host::default()), bx(St { ncalls: 1, nspawn: n, ..Default::default() }));
        let c = start(h, s, Some(main_parent), 2, 64) as usize;
        // ren_thread_init(NULL) binds no stack, so the workers may move threads.
        let (tx, rx) = std::sync::mpsc::channel::<u64>();
        let workers: Vec<_> = (0..2)
            .map(|w| {
                let tx = tx.clone();
                std::thread::spawn(move || {
                    let c = c as *mut ren_core;
                    loop {
                        let r = ren_run(c, w, 8);
                        while let Some(k) = poll(c, w) {
                            if k.kind as u32 == REN_CALL {
                                tx.send(k.id).unwrap();
                            }
                        }
                        if r == FIN {
                            break;
                        }
                        std::thread::yield_now();
                    }
                })
            })
            .collect();
        drop(tx);
        let replier = std::thread::spawn(move || {
            for id in rx {
                assert_eq!(reply(c as *mut ren_core, id, REN_DONE, 9), ACC);
            }
        });
        for t in workers {
            t.join().unwrap();
        }
        replier.join().unwrap();
        for t in 1..=n as usize {
            assert_eq!((*s).res[t][0], 9);
        }
        ren_free(c as *mut ren_core);
        unbx(h);
        unbx(s);
    }
}
