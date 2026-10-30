//! The sans-I/O core, SPEC §B: the nine host functions, the emitted-code
//! ABI, the op table, park/wake and the journal. Every atomic ordering is
//! the one SPEC §B names; fields marked "owner" live in `Local` and are
//! touched only by the worker's own thread (between ren_thread_init and
//! the end of its ren_runs), which is what makes the `UnsafeCell`s sound.
use crate::deque::{Deque, ABORT, EMPTY};
use crate::journal::{self, Enc};
use crate::sys::*;
use alloc::boxed::Box;
use alloc::collections::VecDeque;
use alloc::vec::Vec;
use core::cell::UnsafeCell;
use core::ffi::c_void;
use core::mem::size_of;
use core::ptr::{self, addr_of_mut, null_mut};
use core::sync::atomic::{fence, AtomicI32, AtomicI64, AtomicPtr, AtomicU64, AtomicUsize, Ordering::*};

// ---- op-table slot states (SPEC §B.3) ----
const S_FREE: u32 = 0;
const S_ISSUED: u32 = 1;
const S_PULLED: u32 = 2;
const S_CANCEL_UNPULLED: u32 = 3;
const S_CANCEL_PULLED: u32 = 4;
const S_REPLIED: u32 = 5;

// ---- task scheduling word, task.core[0] (SPEC §B.2) ----
const T_QUEUED: usize = 1;
const T_RUNNING: usize = 2;
const T_PARKED: usize = 3;
const T_DONE: usize = 4;
const T_NOTIFIED: usize = 8;

const ECANCELED_RES: ren_io_result = ren_io_result { res: -(REN_ECANCELED as i64), a: 0, b: 0 };

#[inline]
fn next_gen(g: u32) -> u32 {
    let n = g.wrapping_add(1);
    if n == 0 {
        1
    } else {
        n
    }
}
#[inline]
fn word(g: u32, st: u32) -> u64 {
    (g as u64) << 32 | st as u64
}

/// One world call in flight. Heap-allocated per call (SPEC §B.1: never a pool).
pub struct Op {
    next: *mut Op,
    slot: u32,
    gen: u32,
    home: u16,
    had_cancel: bool,
    task: *mut ren_task,
    aw: *mut ren_await,
    call: ren_call,
    body: ren_io_body,
    reply_state: u32,
    reply: ren_io_result,
}

pub struct CancelNode {
    next: *mut CancelNode,
    id: u64,
}

trait Linked {
    fn next(&mut self) -> &mut *mut Self;
}
impl Linked for Op {
    fn next(&mut self) -> &mut *mut Self {
        &mut self.next
    }
}
impl Linked for CancelNode {
    fn next(&mut self) -> &mut *mut Self {
        &mut self.next
    }
}

/// An MPSC stack (SPEC §B.1): push from any thread, take_all by the owner.
struct Mpsc<T: Linked> {
    head: AtomicPtr<T>,
}
impl<T: Linked> Mpsc<T> {
    fn new() -> Self {
        Mpsc { head: AtomicPtr::new(null_mut()) }
    }
    /// # Safety
    /// `n` is a live node no other thread is using.
    unsafe fn push(&self, n: *mut T) {
        loop {
            let h = self.head.load(Relaxed);
            *(*n).next() = h;
            if self.head.compare_exchange(h, n, Release, Relaxed).is_ok() {
                break;
            }
        }
    }
    /// The whole list, in arrival order.
    fn take_all(&self) -> Vec<*mut T> {
        let mut l = self.head.swap(null_mut(), Acquire);
        let mut v = Vec::new();
        while !l.is_null() {
            v.push(l);
            // SAFETY: the nodes are ours now (taken with the swap).
            l = unsafe { *(*l).next() };
        }
        v.reverse();
        v
    }
    fn is_empty(&self) -> bool {
        self.head.load(Acquire).is_null()
    }
}

/// What a resume function gets as its `ren_ctx *`.
#[repr(C)]
pub struct Ctx {
    core: *const Core,
    worker: i32,
    points: u32,
    cur: *mut ren_task,
}

/// Owner-only worker state.
struct Local {
    stolen_seen: u64,
    cancels: VecDeque<*mut CancelNode>,
    outbox: VecDeque<*mut Op>,
    free: Vec<u32>,
    rng: u64,
    spawn_seq: u32,
    last_poll: u64,
    cancel_done: u64,
    stack_lo: usize,
    stack_size: usize,
    cx: Ctx,
}

#[repr(align(128))]
struct Worker {
    dq: Deque,
    parked: AtomicI32,
    steps: AtomicU64,
    #[cfg(not(feature = "plant5"))]
    stolen_from: AtomicU64,
    // PLANT P5 (SPEC §F): a plain u64, thieves `+= 1`, owner plain read.
    // A bare `u64` field fails to compile (E0594, behind `&`); UnsafeCell is
    // what it takes, and Core's existing `unsafe impl Sync` covers it.
    #[cfg(feature = "plant5")]
    stolen_from: UnsafeCell<u64>,
    inbox: Mpsc<Op>,
    remote: Mpsc<CancelNode>,
    local: UnsafeCell<Local>,
}

struct Slot {
    word: AtomicU64,
    /// Written by home before the REL store of ISSUED; read only by a thread
    /// whose ACQ load or CAS saw ISSUED-or-later with the same generation.
    op: UnsafeCell<*mut Op>,
}

struct Injector {
    lock: AtomicI32,
    head: UnsafeCell<*mut ren_task>,
    tail: UnsafeCell<*mut ren_task>,
    len: AtomicI64,
}

pub struct Core {
    cfg: ren_config,
    host: ren_host,
    hostp: *mut c_void,
    nw: i32,
    s: u32,
    b: u32,
    k: u32,
    w: Box<[Worker]>,
    slots: Box<[Slot]>,
    inj: Injector,
    live: AtomicI64,
    stopping: AtomicI32,
    killed: AtomicI32,
    done: AtomicI32,
    idle: AtomicI32,
}

// SAFETY: shared fields are atomics; owner-only fields sit in UnsafeCells
// that only the owning worker's thread dereferences (SPEC §B.1), the
// injector's plain fields only under its spinlock, and `Slot.op` follows
// the publication rule above.
unsafe impl Sync for Core {}
unsafe impl Send for Core {}

#[inline]
unsafe fn sched(t: *mut ren_task) -> &'static AtomicUsize {
    AtomicUsize::from_ptr(addr_of_mut!((*t).core[0]))
}
#[inline]
unsafe fn aw_state(aw: *mut ren_await) -> &'static AtomicI32 {
    AtomicI32::from_ptr(addr_of_mut!((*aw).state))
}
/// Copy the first sizeof(ren_io_result) bytes of a reply body, zero-filled.
unsafe fn result_of(body: *const c_void, len: u32) -> ren_io_result {
    let mut r = ren_io_result { res: 0, a: 0, b: 0 };
    let n = core::cmp::min(len as usize, size_of::<ren_io_result>());
    if n > 0 && !body.is_null() {
        ptr::copy_nonoverlapping(body as *const u8, addr_of_mut!(r) as *mut u8, n);
    }
    r
}

impl Core {
    #[inline]
    fn worker(&self, w: i32) -> &Worker {
        &self.w[w as usize]
    }
    /// # Safety
    /// Only worker `w`'s thread may call this, and must not hold another
    /// reference into the same Local across a call back into the core.
    #[inline]
    #[allow(clippy::mut_from_ref)]
    unsafe fn local(&self, w: i32) -> &mut Local {
        &mut *self.w[w as usize].local.get()
    }
    #[inline]
    fn recording(&self) -> bool {
        self.host.journal.is_some()
    }

    fn journal(&self, kind: u32, worker: i32, payload: &[u8]) {
        if let Some(j) = self.host.journal {
            let step = if worker >= 0 { self.worker(worker).steps.load(Relaxed) } else { 0 };
            let e = journal::entry(kind, worker, step, payload);
            // SAFETY: the host's leaf callback, given a valid buffer.
            unsafe { j(self.hostp, worker, e.as_ptr().cast(), e.len()) };
        }
    }
    fn j_release(&self, id: u64, why: u32) {
        if self.recording() {
            let mut e = Enc::new();
            e.u64(id).u32(why);
            self.journal(REN_J_RELEASE, -1, &e.0);
        }
    }
    fn j_deliver(&self, w: i32, id: u64, state: u32, r: &ren_io_result, inout: &[u8]) {
        if self.recording() {
            let mut e = Enc::new();
            journal::reply_body(&mut e, id, state, r, inout);
            self.journal(REN_J_DELIVER, w, &e.0);
        }
    }

    // ---- the injector (the core's only lock) ----
    fn inj_lock(&self) {
        while self.inj.lock.swap(1, Acquire) != 0 {
            while self.inj.lock.load(Relaxed) != 0 {
                core::hint::spin_loop();
            }
        }
    }
    fn inj_unlock(&self) {
        self.inj.lock.store(0, Release);
    }
    unsafe fn inj_push(&self, t: *mut ren_task) {
        self.inj_lock();
        (*t).core[1] = 0;
        let tail = *self.inj.tail.get();
        if tail.is_null() {
            *self.inj.head.get() = t;
        } else {
            (*tail).core[1] = t as usize;
        }
        *self.inj.tail.get() = t;
        self.inj.len.fetch_add(1, Relaxed);
        self.inj_unlock();
    }
    unsafe fn inj_pop(&self) -> *mut ren_task {
        if self.inj.len.load(Relaxed) == 0 {
            return null_mut();
        }
        self.inj_lock();
        let t = *self.inj.head.get();
        if !t.is_null() {
            *self.inj.head.get() = (*t).core[1] as *mut ren_task;
            if (*t).core[1] == 0 {
                *self.inj.tail.get() = null_mut();
            }
            self.inj.len.fetch_sub(1, Relaxed);
        }
        self.inj_unlock();
        t
    }

    // ---- park and wake (SPEC §B.6) ----
    fn try_park(&self, w: i32) -> bool {
        let me = self.worker(w);
        me.parked.store(1, SeqCst);
        self.idle.fetch_add(1, SeqCst);
        fence(SeqCst);
        let work = !me.inbox.is_empty()
            || self.inj.len.load(Relaxed) > 0
            || self.w.iter().any(|v| v.dq.looks_nonempty())
            || self.done.load(Acquire) != 0
            || self.killed.load(Acquire) != 0;
        if work {
            if me.parked.swap(0, AcqRel) == 1 {
                self.idle.fetch_sub(1, Relaxed);
            }
            return false;
        }
        true
    }
    fn host_wake(&self, v: i32) {
        if let Some(f) = self.host.wake {
            // SAFETY: the host's leaf callback.
            unsafe { f(self.hostp, v) };
        }
    }
    fn wake_worker(&self, v: i32) {
        fence(SeqCst);
        let p = &self.worker(v).parked;
        if p.load(Relaxed) == 1 && p.compare_exchange(1, 0, AcqRel, Relaxed).is_ok() {
            self.idle.fetch_sub(1, Relaxed);
            self.host_wake(v);
        }
    }
    fn wake_one(&self, w: i32) {
        fence(SeqCst);
        if self.idle.load(Relaxed) == 0 {
            return;
        }
        for i in 1..=self.nw {
            let v = (w + i) % self.nw;
            let p = &self.worker(v).parked;
            if p.load(Relaxed) == 1 && p.compare_exchange(1, 0, AcqRel, Relaxed).is_ok() {
                self.idle.fetch_sub(1, Relaxed);
                self.host_wake(v);
                return;
            }
        }
    }
    fn wake_all(&self) {
        for v in 0..self.nw {
            if self.worker(v).parked.compare_exchange(1, 0, AcqRel, Relaxed).is_ok() {
                self.idle.fetch_sub(1, Relaxed);
                self.host_wake(v);
            }
        }
    }

    // ---- tasks ----
    unsafe fn notify(&self, w: i32, t: *mut ren_task) {
        let s = sched(t).fetch_or(T_NOTIFIED, AcqRel);
        if s == T_PARKED {
            sched(t).swap(T_QUEUED, AcqRel);
            self.worker(w).dq.push(t as u64);
            self.wake_one(w);
        }
    }
    fn finish(&self, w: i32) {
        let mut e = Enc::new();
        e.u32(0);
        self.journal(REN_J_END, w, &e.0);
        self.done.store(1, Release);
        self.wake_all();
    }
    unsafe fn task_done(&self, w: i32, t: *mut ren_task) {
        ren_rc_drop(addr_of_mut!((*t).obj));
        if self.live.fetch_sub(1, AcqRel) == 1 {
            self.finish(w);
        }
    }
    unsafe fn run_task(&self, w: i32, t: *mut ren_task) {
        sched(t).swap(T_RUNNING, AcqRel);
        let cx: *mut Ctx = addr_of_mut!((*self.w[w as usize].local.get()).cx);
        (*cx).points = 0;
        (*cx).cur = t;
        let resume = match (*t).resume {
            Some(f) => f,
            None => crate::rt::die("task without a resume function"),
        };
        let r = resume(t, cx as *mut ren_ctx);
        let st = &self.worker(w).steps;
        st.store(st.load(Relaxed) + 1, Relaxed);
        match r as u32 {
            REN_T_DONE => {
                sched(t).swap(T_DONE, AcqRel);
                self.task_done(w, t);
            }
            REN_T_PARK => {
                if sched(t).compare_exchange(T_RUNNING, T_PARKED, AcqRel, Acquire).is_err() {
                    // a notify came while it ran
                    sched(t).swap(T_QUEUED, AcqRel);
                    self.worker(w).dq.push(t as u64);
                    self.wake_one(w);
                }
            }
            REN_T_YIELD => {
                sched(t).swap(T_QUEUED, AcqRel);
                self.inj_push(t);
                self.wake_one(w);
            }
            _ => crate::rt::die("resume returned an unknown code"),
        }
    }
    unsafe fn steal_any(&self, w: i32) -> *mut ren_task {
        if self.nw == 1 {
            return null_mut();
        }
        let l = self.local(w);
        let mut x = l.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        l.rng = x;
        let start = (x % self.nw as u64) as i32;
        for i in 0..self.nw {
            let v = (start + i) % self.nw;
            if v == w {
                continue;
            }
            let x = self.worker(v).dq.steal();
            if x != EMPTY && x != ABORT {
                #[cfg(not(feature = "plant5"))]
                self.worker(v).stolen_from.fetch_add(1, Relaxed);
                #[cfg(feature = "plant5")]
                {
                    *self.worker(v).stolen_from.get() += 1;
                }
                return x as *mut ren_task;
            }
        }
        null_mut()
    }

    // ---- delivery (SPEC §B.5 deliver) ----
    unsafe fn deliver(&self, w: i32, op: *mut Op) {
        let o = &mut *op;
        let (aw, t) = (o.aw, o.task);
        if self.recording() {
            let inout: &[u8] = if o.call.op == REN_OP_READ && o.reply_state == REN_DONE && o.reply.res > 0 {
                core::slice::from_raw_parts(o.body.buf as usize as *const u8, o.reply.res as usize)
            } else {
                &[]
            };
            self.j_deliver(w, o.call.id, o.reply_state, &o.reply, inout);
        }
        (*aw).res = o.reply;
        aw_state(aw).store(o.reply_state as i32, Release);
        if o.had_cancel {
            self.on_cancel_done(w, op);
        }
        let (slot, gen) = (o.slot, o.gen);
        #[cfg(debug_assertions)]
        {
            (*t).core[2] = 0;
        }
        self.slots[slot as usize].word.store(word(next_gen(gen), S_FREE), Release);
        self.local(w).free.push(slot - w as u32 * self.s);
        drop(Box::from_raw(op));
        self.notify(w, t);
    }
    unsafe fn on_cancel_done(&self, w: i32, _op: *mut Op) {
        self.local(w).cancel_done += 1;
        // PLANT P4 (SPEC §F): also free the op record; deliver frees it again.
        #[cfg(feature = "plant4")]
        drop(Box::from_raw(_op));
    }
    unsafe fn drain_inbox(&self, w: i32) -> usize {
        let l = self.worker(w).inbox.take_all();
        let n = l.len();
        for op in l {
            self.deliver(w, op);
        }
        n
    }

    // ---- cancellation (SPEC §B.5 cancel_slot) ----
    unsafe fn cancel_slot(&self, gs: u32, g: u32, by: i32) {
        let s = &self.slots[gs as usize];
        let how;
        loop {
            let wd = s.word.load(Acquire);
            if (wd >> 32) as u32 != g {
                how = REN_JC_LATE;
                break;
            }
            let st = wd as u32;
            if st == S_ISSUED {
                if s.word.compare_exchange(wd, word(g, S_CANCEL_UNPULLED), AcqRel, Acquire).is_ok() {
                    how = REN_JC_RETRACT;
                    break;
                }
            } else if st == S_PULLED {
                if s.word.compare_exchange(wd, word(g, S_CANCEL_PULLED), AcqRel, Acquire).is_ok() {
                    let home = (gs / self.s) as i32;
                    let n = Box::into_raw(Box::new(CancelNode { next: null_mut(), id: word(gs, g) }));
                    self.worker(home).remote.push(n);
                    self.wake_worker(home);
                    how = REN_JC_SENT;
                    break;
                }
            } else {
                how = REN_JC_LATE;
                break;
            }
        }
        if self.recording() {
            let mut e = Enc::new();
            e.u64(word(gs, g)).u32(how);
            self.journal(REN_J_CANCEL, by, &e.0);
        }
    }

    // ================= the nine host functions =================
    pub unsafe fn start(cfg: &ren_config, main: ren_main_fn, host: &ren_host, hostp: *mut c_void) -> *mut Core {
        if cfg.workers < 1 || cfg.workers > 64 {
            return null_mut();
        }
        let Some(main) = main else { return null_mut() };
        let nw = cfg.workers;
        let mut c = *cfg;
        if c.budget_b == 0 {
            c.budget_b = 128;
        }
        if c.poll_k == 0 {
            c.poll_k = 61;
        }
        if c.op_slots == 0 {
            c.op_slots = 4096;
        }
        if c.deque_log2 == 0 {
            c.deque_log2 = 8;
        }
        let s = c.op_slots;
        let mut ws = Vec::with_capacity(nw as usize);
        for w in 0..nw {
            ws.push(Worker {
                dq: Deque::new(c.deque_log2),
                parked: AtomicI32::new(0),
                steps: AtomicU64::new(0),
                #[cfg(not(feature = "plant5"))]
                stolen_from: AtomicU64::new(0),
                #[cfg(feature = "plant5")]
                stolen_from: UnsafeCell::new(0),
                inbox: Mpsc::new(),
                remote: Mpsc::new(),
                local: UnsafeCell::new(Local {
                    stolen_seen: 0,
                    cancels: VecDeque::new(),
                    outbox: VecDeque::new(),
                    free: (0..s).rev().collect(), // pops 0, 1, 2, ...
                    rng: 0x9E3779B97F4A7C15u64 ^ (w as u64 + 1),
                    spawn_seq: 0,
                    last_poll: 0,
                    cancel_done: 0,
                    stack_lo: 0,
                    stack_size: 0,
                    cx: Ctx { core: ptr::null(), worker: w, points: 0, cur: null_mut() },
                }),
            });
        }
        let total = nw as usize * s as usize;
        let slots: Vec<Slot> =
            (0..total).map(|_| Slot { word: AtomicU64::new(word(1, S_FREE)), op: UnsafeCell::new(null_mut()) }).collect();
        let core = Box::into_raw(Box::new(Core {
            cfg: c,
            host: *host,
            hostp,
            nw,
            s,
            b: c.budget_b,
            k: c.poll_k,
            w: ws.into_boxed_slice(),
            slots: slots.into_boxed_slice(),
            inj: Injector {
                lock: AtomicI32::new(0),
                head: UnsafeCell::new(null_mut()),
                tail: UnsafeCell::new(null_mut()),
                len: AtomicI64::new(0),
            },
            live: AtomicI64::new(1),
            stopping: AtomicI32::new(0),
            killed: AtomicI32::new(0),
            done: AtomicI32::new(0),
            idle: AtomicI32::new(0),
        }));
        let cr = &*core;
        for w in 0..nw {
            cr.local(w).cx.core = core;
        }
        if cr.recording() {
            let bid: &[u8] = if c.build_id.is_null() {
                &[]
            } else {
                core::ffi::CStr::from_ptr(c.build_id).to_bytes()
            };
            let mut e = Enc::new();
            e.u32(REN_SLICE_VERSION).u32(nw as u32).u32(cr.b).u32(cr.k).u32(c.journal_policy);
            e.u32(bid.len() as u32).bytes(bid);
            cr.journal(REN_J_HEADER, -1, &e.0);
        }
        let root = main(addr_of_mut!((*core).cfg));
        if root.is_null() {
            drop(Box::from_raw(core));
            return null_mut();
        }
        let l0 = cr.local(0);
        l0.spawn_seq += 1;
        (*root).id = l0.spawn_seq;
        sched(root).store(T_QUEUED, Relaxed);
        cr.inj_push(root); // no wake: nobody is parked yet
        core
    }

    pub unsafe fn thread_init(&self, w: i32, lo: *mut c_void, size: usize) {
        if w < 0 || w >= self.nw {
            crate::rt::die("ren_thread_init: worker out of range");
        }
        let l = self.local(w);
        l.stack_lo = lo as usize;
        l.stack_size = size;
    }

    pub unsafe fn run(&self, w: i32, steps: u32) -> i32 {
        if cfg!(debug_assertions) {
            // ren_thread_init bound this worker to a stack: we must be on it.
            let l = self.local(w);
            let probe = 0u8;
            let a = &probe as *const u8 as usize;
            if l.stack_lo != 0 && !(a >= l.stack_lo && a < l.stack_lo + l.stack_size) {
                crate::rt::die("ren_run: called on a thread that is not this worker's (ren_thread_init)");
            }
        }
        if self.killed.load(Acquire) != 0 {
            return REN_FINISHED as i32;
        }
        let me = self.worker(w);
        if me.parked.swap(0, AcqRel) == 1 {
            self.idle.fetch_sub(1, Relaxed);
        }
        #[cfg(not(feature = "plant5"))]
        {
            self.local(w).stolen_seen = me.stolen_from.load(Relaxed);
        }
        #[cfg(feature = "plant5")]
        {
            self.local(w).stolen_seen = *me.stolen_from.get();
        }
        if self.done.load(Acquire) != 0 {
            return REN_FINISHED as i32;
        }
        self.drain_inbox(w);
        let mut n = 0u32;
        loop {
            if self.done.load(Acquire) != 0 || self.killed.load(Acquire) != 0 {
                return REN_FINISHED as i32;
            }
            if n == steps {
                return REN_RUNNING as i32;
            }
            let mut t: *mut ren_task = null_mut();
            let s = me.steps.load(Relaxed);
            if s != 0 && s % self.k as u64 == 0 && self.local(w).last_poll != s {
                self.local(w).last_poll = s;
                self.drain_inbox(w);
                t = self.inj_pop();
            }
            if t.is_null() {
                let x = me.dq.take();
                if x != EMPTY {
                    t = x as *mut ren_task;
                }
            }
            if t.is_null() {
                t = self.inj_pop();
            }
            if t.is_null() {
                t = self.steal_any(w);
            }
            if t.is_null() {
                if self.drain_inbox(w) > 0 {
                    continue;
                }
                if self.try_park(w) {
                    return if self.done.load(Acquire) != 0 { REN_FINISHED } else { REN_IDLE } as i32;
                }
                continue;
            }
            self.run_task(w, t);
            n += 1;
        }
    }

    pub unsafe fn poll_call(&self, w: i32, out: *mut ren_call) -> bool {
        if self.killed.load(Acquire) != 0 {
            return false;
        }
        let me = self.worker(w);
        let l = self.local(w);
        if l.cancels.is_empty() {
            l.cancels.extend(me.remote.take_all());
        }
        if let Some(n) = l.cancels.pop_front() {
            let id = (*n).id;
            drop(Box::from_raw(n));
            *out = ren_call {
                id,
                worker: w as u16,
                kind: REN_CANCEL as u16,
                lane: 0,
                task: 0,
                op: 0,
                len: 0,
                _pad: 0,
                body: ptr::null(),
            };
            return true;
        }
        while let Some(op) = l.outbox.pop_front() {
            let (g, gs) = ((*op).gen, (*op).slot);
            let s = &self.slots[gs as usize];
            if s.word.compare_exchange(word(g, S_ISSUED), word(g, S_PULLED), AcqRel, Acquire).is_ok() {
                *out = (*op).call;
                return true;
            }
            // CANCEL_UNPULLED: retract, with no round trip. Only home moves it from here.
            let r = s.word.compare_exchange(word(g, S_CANCEL_UNPULLED), word(g, S_REPLIED), AcqRel, Acquire);
            debug_assert!(r.is_ok(), "retract: slot not CANCEL_UNPULLED");
            let _ = r;
            (*op).had_cancel = true;
            (*op).reply_state = REN_CANCELLED;
            (*op).reply = ECANCELED_RES;
            me.inbox.push(op); // delivered at the next drain, in order
        }
        false
    }

    pub unsafe fn reply(&self, r: &ren_reply_t) -> i32 {
        if self.killed.load(Acquire) != 0 {
            self.j_release(r.id, REN_JR_DEAD);
            return REN_RELEASE as i32;
        }
        let gs = r.id >> 32;
        let g = r.id as u32;
        if gs >= self.slots.len() as u64 || g == 0 {
            self.j_release(r.id, REN_JR_STALE);
            return REN_RELEASE as i32;
        }
        let s = &self.slots[gs as usize];
        let st;
        loop {
            let wd = s.word.load(Acquire);
            // PLANT P3 (SPEC §F) deletes this generation test.
            #[cfg(not(feature = "plant3"))]
            if (wd >> 32) as u32 != g {
                self.j_release(r.id, REN_JR_STALE);
                return REN_RELEASE as i32;
            }
            let cur = wd as u32;
            if cur == S_PULLED || cur == S_CANCEL_PULLED {
                if s.word.compare_exchange(wd, (wd & !0xffff_ffff) | S_REPLIED as u64, AcqRel, Acquire).is_ok() {
                    st = cur;
                    break;
                }
                continue;
            }
            let why = if cur == S_REPLIED { REN_JR_DUP } else { REN_JR_STALE };
            self.j_release(r.id, why);
            return REN_RELEASE as i32;
        }
        let op = *s.op.get();
        (*op).had_cancel = st == S_CANCEL_PULLED;
        (*op).reply_state = r.state;
        (*op).reply = result_of(r.body, r.len);
        let home = (*op).home as i32;
        self.worker(home).inbox.push(op);
        self.wake_worker(home); // §2.7: every reply leads to a tick
        REN_ACCEPTED as i32
    }

    pub unsafe fn stop(&self) {
        if self.stopping.swap(1, SeqCst) == 1 {
            return;
        }
        fence(SeqCst);
        for gs in 0..self.slots.len() as u32 {
            let wd = self.slots[gs as usize].word.load(Acquire);
            // SPEC §B.4 walks every slot; on a FREE one cancel_slot can only
            // be LATE, so it is skipped rather than journaled (as the C entry
            // and the stub do: otherwise a stop writes nw*S CANCEL entries and
            // the journals of the languages differ). A slot that turns ISSUED
            // after this read is cancelled by ren_world's own stopping check.
            if wd as u32 != S_FREE {
                self.cancel_slot(gs, (wd >> 32) as u32, -1);
            }
        }
        self.wake_all();
    }

    pub unsafe fn kill(&self) {
        if self.killed.swap(1, SeqCst) == 1 {
            return;
        }
        let mut e = Enc::new();
        e.u32(1);
        self.journal(REN_J_END, -1, &e.0);
        self.done.store(1, Release);
        self.wake_all();
    }

    /// After every worker's ren_run returned FINISHED and every driver finished.
    pub unsafe fn free(c: *mut Core) {
        let cr = &*c;
        let mut tasks: Vec<*mut ren_task> = Vec::new();
        for w in cr.w.iter() {
            loop {
                let x = w.dq.take();
                if x == EMPTY {
                    break;
                }
                tasks.push(x as *mut ren_task);
            }
        }
        loop {
            let t = cr.inj_pop();
            if t.is_null() {
                break;
            }
            tasks.push(t);
        }
        for s in cr.slots.iter() {
            if (s.word.load(Acquire) as u32) != S_FREE {
                let op = *s.op.get();
                if !op.is_null() {
                    tasks.push((*op).task);
                    drop(Box::from_raw(op));
                }
            }
        }
        // A task that was both queued and waiting on a call (possible after a
        // kill) holds one core reference, not two.
        tasks.sort_unstable();
        tasks.dedup();
        for t in tasks {
            ren_rc_drop(addr_of_mut!((*t).obj));
        }
        for w in cr.w.iter() {
            let l = &mut *w.local.get();
            for n in l.cancels.drain(..) {
                drop(Box::from_raw(n));
            }
            for n in w.remote.take_all() {
                drop(Box::from_raw(n));
            }
        }
        drop(Box::from_raw(c));
    }

    pub fn progress(&self, w: i32) -> u64 {
        self.worker(w).steps.load(Relaxed)
    }

    // ================= the emitted-code ABI =================
    pub unsafe fn spawn(&self, w: i32, t: *mut ren_task) {
        let l = self.local(w);
        l.spawn_seq += 1;
        (*t).id = (w as u32) << 24 | l.spawn_seq;
        sched(t).store(T_QUEUED, Relaxed);
        self.live.fetch_add(1, Relaxed);
        self.worker(w).dq.push(t as u64);
        self.wake_one(w);
    }

    pub unsafe fn world(&self, w: i32, me: *mut ren_task, aw: *mut ren_await, opc: u32, body: *const ren_io_body) -> i32 {
        #[cfg(debug_assertions)]
        if (*me).core[2] != 0 {
            crate::rt::die("ren_world: the task already has a pending world call");
        }
        if self.stopping.load(Acquire) != 0 {
            (*aw).id = 0;
            (*aw).op = opc;
            (*aw).res = ECANCELED_RES;
            self.j_deliver(w, 0, REN_CANCELLED, &ECANCELED_RES, &[]);
            aw_state(aw).store(REN_CANCELLED as i32, Release);
            return REN_W_NOW as i32;
        }
        let l = self.local(w);
        let Some(ls) = l.free.pop() else { return REN_W_FULL as i32 };
        let gs = w as u32 * self.s + ls;
        let g = (self.slots[gs as usize].word.load(Relaxed) >> 32) as u32;
        let id = word(gs, g);
        let o = Box::into_raw(Box::new(Op {
            next: null_mut(),
            slot: gs,
            gen: g,
            home: w as u16,
            had_cancel: false,
            task: me,
            aw,
            call: ren_call {
                id,
                worker: w as u16,
                kind: REN_CALL as u16,
                lane: 0,
                task: (*me).id,
                op: opc,
                len: size_of::<ren_io_body>() as u32,
                _pad: 0,
                body: ptr::null(),
            },
            body: *body,
            reply_state: 0,
            reply: ren_io_result { res: 0, a: 0, b: 0 },
        }));
        (*o).call.body = addr_of_mut!((*o).body) as *const c_void;
        (*aw).id = id;
        (*aw).op = opc;
        aw_state(aw).store(0, Relaxed);
        if self.recording() {
            let mut e = Enc::new();
            journal::call(&mut e, &(*o).call);
            self.journal(REN_J_CALL, w, &e.0);
        }
        if let Some(an) = self.host.answer_now {
            let mut rep = ren_reply_t { id: 0, state: 0, len: 0, body: ptr::null() };
            if an(self.hostp, w, &(*o).call, &mut rep) {
                let res = result_of(rep.body, rep.len);
                self.j_deliver(w, id, rep.state, &res, &[]);
                (*aw).res = res;
                aw_state(aw).store(rep.state as i32, Release);
                self.slots[gs as usize].word.store(word(next_gen(g), S_FREE), Release);
                self.local(w).free.push(ls);
                drop(Box::from_raw(o));
                return REN_W_NOW as i32;
            }
        }
        #[cfg(debug_assertions)]
        {
            (*me).core[2] = id as usize;
        }
        *self.slots[gs as usize].op.get() = o;
        self.slots[gs as usize].word.store(word(g, S_ISSUED), Release);
        self.local(w).outbox.push_back(o);
        fence(SeqCst); // Dekker with ren_stop's xchg + fence + walk
        if self.stopping.load(Relaxed) != 0 {
            self.cancel_slot(gs, g, w);
        }
        REN_W_PENDING as i32
    }

    pub unsafe fn cancel(&self, w: i32, id: u64) {
        if (id >> 32) >= self.slots.len() as u64 || id as u32 == 0 {
            if self.recording() {
                let mut e = Enc::new();
                e.u64(id).u32(REN_JC_LATE);
                self.journal(REN_J_CANCEL, w, &e.0);
            }
            return;
        }
        self.cancel_slot((id >> 32) as u32, id as u32, w);
    }

    pub fn cancelled(&self) -> bool {
        self.stopping.load(Acquire) != 0
    }
    pub fn workers(&self) -> i32 {
        self.nw
    }
    pub fn config(&self) -> &ren_config {
        &self.cfg
    }
}

// ---- ren_ctx helpers for the emitted-code ABI ----
impl Ctx {
    /// # Safety
    /// `cx` is a `ren_ctx *` the core handed to a resume function.
    #[inline]
    pub unsafe fn from<'a>(cx: *mut ren_ctx) -> &'a mut Ctx {
        &mut *(cx as *mut Ctx)
    }
    #[inline]
    pub unsafe fn core<'a>(&self) -> &'a Core {
        &*self.core
    }
    #[inline]
    pub fn worker(&self) -> i32 {
        self.worker
    }
    /// ren_tick: a scheduling point that did not wait.
    #[inline]
    pub unsafe fn tick(&mut self) -> bool {
        self.points += 1;
        self.points >= (*self.core).b
    }
}

/// notify through a context (ren_notify).
pub unsafe fn notify(cx: &Ctx, t: *mut ren_task) {
    cx.core().notify(cx.worker, t);
}
