// P3: handing off against barging. Rust port of ../p3.c; same algorithm,
// same scheduler shape, same output line (impl=rust). See ../README.md.
//
// Raw pointers and UnsafeCell stand in for what Ren's runtime would do with
// its own scheduler; every shared field is either atomic or guarded by a
// spinlock / mutex, as in the C.

use std::cell::UnsafeCell;
use std::ptr;
use std::sync::atomic::{fence, AtomicBool, AtomicI32, AtomicPtr, AtomicU64, Ordering::*};
use std::sync::{Condvar, Mutex};

const MAXW: usize = 64;
const QCAP: usize = 8192;
const SW: usize = 16;
const HB: usize = 1024;
const SPIN_ROUNDS: usize = 64;
const MUL: u64 = 6364136223846793005;

#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}
extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebase) -> i32;
    fn pthread_set_qos_class_self_np(qos: u32, rel: i32) -> i32;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

#[inline]
fn now_ticks() -> u64 {
    unsafe { mach_absolute_time() }
}
#[inline]
fn cpu_relax() {
    std::hint::spin_loop();
}

struct Spin(AtomicBool);
impl Spin {
    const fn new() -> Self {
        Spin(AtomicBool::new(false))
    }
    #[inline]
    fn lock(&self) {
        loop {
            if !self.0.swap(true, Acquire) {
                return;
            }
            while self.0.load(Relaxed) {
                cpu_relax();
            }
        }
    }
    #[inline]
    fn unlock(&self) {
        self.0.store(false, Release);
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Fifo,
    Barge,
}

#[derive(Clone, Copy)]
struct Cfg {
    mode: Mode,
    workers: usize,
    tasks: usize,
    cs_ns: u64,
    out_ns: u64,
    cs_rounds: u64,
    out_iters: u64,
    ms: u64,
    ops_per_task: u64,
    guard_ticks: u64,
    reps: usize,
}

#[repr(C, align(128))]
struct Task {
    next: *mut Task,
    t_req: u64,
    resuming: bool,
    granted: bool,
    ops: u64,
    rng: u64,
}

#[repr(C, align(128))]
struct Inst {
    state: AtomicU64, // bit 0 held, bits 1.. queued waiters
    qlock: Spin,
    q: UnsafeCell<InstQ>,
    data: UnsafeCell<InstData>,
}
struct InstQ {
    head: *mut Task,
    tail: *mut Task,
    woken: bool,
    guard_handoffs: u64,
}
#[repr(C, align(128))]
struct InstData {
    in_cs: AtomicI32,
    counter: u64,
    a: [u64; SW],
}

#[repr(C, align(128))]
struct Worker {
    lock: Spin,
    ring: UnsafeCell<Ring>,
    runnext: AtomicPtr<Task>,
    park: Mutex<bool>, // notified
    cv: Condvar,
    local: UnsafeCell<WLocal>,
}
struct Ring {
    head: usize,
    tail: usize,
    buf: Box<[*mut Task]>,
}
struct WLocal {
    spinning: bool,
    window_ops: u64,
    hist: Box<[u64; HB]>,
    maxwait_ns: u64,
    rng: u64,
}

struct Sched {
    cfg: Cfg,
    ns_per_tick: f64,
    inst: Inst,
    workers: Vec<Worker>,
    tasks: Vec<UnsafeCell<Task>>,
    idle: Mutex<Vec<usize>>,
    nidle: AtomicI32,
    nspinning: AtomicI32,
    done_tasks: AtomicU64,
    stop: AtomicBool,
    shutdown: AtomicBool,
}
unsafe impl Sync for Sched {}
unsafe impl Send for Sched {}

fn hidx(v: u64) -> usize {
    if v < 16 {
        return v as usize;
    }
    let e = 63 - v.leading_zeros() as i64;
    let sub = ((v >> (e - 4)) & 15) as i64;
    ((e - 3) * 16 + sub) as usize
}
fn hval(i: usize) -> u64 {
    if i < 16 {
        return i as u64;
    }
    let e = i / 16 + 3;
    let sub = i % 16;
    ((16 + sub) as u64) << (e - 4)
}

#[inline]
fn outside(mut x: u64, iters: u64) -> u64 {
    for _ in 0..iters {
        x = x.wrapping_mul(MUL).wrapping_add(1);
    }
    x
}

impl Sched {
    fn wakep(&self) {
        fence(SeqCst);
        if self.nidle.load(SeqCst) == 0 || self.nspinning.load(SeqCst) != 0 {
            return;
        }
        let id = {
            let mut idle = self.idle.lock().unwrap();
            match idle.pop() {
                None => return,
                Some(id) => {
                    self.nidle.fetch_sub(1, SeqCst);
                    self.nspinning.fetch_add(1, SeqCst);
                    id
                }
            }
        };
        let w = &self.workers[id];
        *w.park.lock().unwrap() = true;
        w.cv.notify_one();
    }

    fn wake_all(&self) {
        for w in &self.workers[..self.cfg.workers] {
            *w.park.lock().unwrap() = true;
            w.cv.notify_one();
        }
    }

    fn push_local(&self, w: &Worker, mut t: *mut Task, front: bool) {
        if front {
            let old = w.runnext.swap(t, AcqRel);
            if old.is_null() {
                self.wakep();
                return;
            }
            t = old;
        }
        w.lock.lock();
        unsafe {
            let r = &mut *w.ring.get();
            r.buf[r.tail & (QCAP - 1)] = t;
            r.tail += 1;
        }
        w.lock.unlock();
        self.wakep();
    }

    fn pop_ring(w: &Worker) -> *mut Task {
        let mut t = ptr::null_mut();
        w.lock.lock();
        unsafe {
            let r = &mut *w.ring.get();
            if r.head != r.tail {
                t = r.buf[r.head & (QCAP - 1)];
                r.head += 1;
            }
        }
        w.lock.unlock();
        t
    }

    fn pop_local(&self, w: &Worker) -> *mut Task {
        let t = w.runnext.swap(ptr::null_mut(), AcqRel);
        if !t.is_null() {
            return t;
        }
        Self::pop_ring(w)
    }

    fn steal(&self, me: usize, take_runnext: bool) -> *mut Task {
        let n = self.cfg.workers;
        let wl = unsafe { &mut *self.workers[me].local.get() };
        wl.rng = wl.rng.wrapping_mul(MUL).wrapping_add(1442695040888963407);
        let start = ((wl.rng >> 33) % n as u64) as usize;
        for k in 0..n {
            let vi = (start + k) % n;
            if vi == me {
                continue;
            }
            let v = &self.workers[vi];
            let t = Self::pop_ring(v);
            if !t.is_null() {
                return t;
            }
            if take_runnext && !v.runnext.load(Relaxed).is_null() {
                let t = v.runnext.swap(ptr::null_mut(), AcqRel);
                if !t.is_null() {
                    return t;
                }
            }
        }
        ptr::null_mut()
    }

    fn find_work(&self, me: usize, take_runnext: bool) -> *mut Task {
        let t = self.pop_local(&self.workers[me]);
        if !t.is_null() {
            return t;
        }
        self.steal(me, take_runnext)
    }

    // ---- the instance ----
    unsafe fn acquire_slow(&self, t: *mut Task, retry: bool) -> bool {
        let inst = &self.inst;
        inst.qlock.lock();
        let q = &mut *inst.q.get();
        if retry {
            q.woken = false;
        }
        loop {
            let s = inst.state.load(Relaxed);
            let may_take = match self.cfg.mode {
                Mode::Barge => s & 1 == 0,
                Mode::Fifo => s == 0,
            };
            if may_take {
                if inst.state.compare_exchange(s, s | 1, Acquire, Relaxed).is_ok() {
                    inst.qlock.unlock();
                    return true;
                }
                continue;
            }
            if inst.state.compare_exchange(s, s + 2, Relaxed, Relaxed).is_ok() {
                (*t).resuming = true;
                (*t).next = ptr::null_mut();
                if retry && self.cfg.mode == Mode::Barge {
                    (*t).next = q.head;
                    q.head = t;
                    if q.tail.is_null() {
                        q.tail = t;
                    }
                } else {
                    if q.tail.is_null() {
                        q.head = t;
                    } else {
                        (*q.tail).next = t;
                    }
                    q.tail = t;
                }
                inst.qlock.unlock();
                return false;
            }
        }
    }

    #[inline]
    unsafe fn acquire(&self, t: *mut Task) -> bool {
        if self.inst.state.compare_exchange(0, 1, Acquire, Relaxed).is_ok() {
            return true;
        }
        self.acquire_slow(t, false)
    }

    unsafe fn release(&self, w: &Worker) {
        let inst = &self.inst;
        if inst.state.compare_exchange(1, 0, Release, Relaxed).is_ok() {
            return;
        }
        inst.qlock.lock();
        let q = &mut *inst.q.get();
        let s = inst.state.load(Relaxed);
        if s >> 1 == 0 {
            inst.state.fetch_sub(1, Release);
            inst.qlock.unlock();
            return;
        }
        let h = q.head;
        let mut handoff = self.cfg.mode == Mode::Fifo;
        if !handoff && now_ticks().wrapping_sub((*h).t_req) > self.cfg.guard_ticks {
            handoff = true;
            q.guard_handoffs += 1;
        }
        if !handoff && q.woken {
            inst.state.fetch_sub(1, Release);
            inst.qlock.unlock();
            return;
        }
        q.head = (*h).next;
        if q.head.is_null() {
            q.tail = ptr::null_mut();
        }
        (*h).next = ptr::null_mut();
        if handoff {
            (*h).granted = true;
            inst.state.fetch_sub(2, Release);
        } else {
            q.woken = true;
            inst.state.fetch_sub(3, Release);
        }
        inst.qlock.unlock();
        self.push_local(w, h, true);
    }

    #[inline]
    unsafe fn critical(&self) {
        let d = &mut *self.inst.data.get();
        if d.in_cs.swap(1, Relaxed) != 0 {
            eprintln!("exclusion violated");
            std::process::abort();
        }
        d.counter += 1;
        for _ in 0..self.cfg.cs_rounds {
            for j in 0..SW {
                d.a[j] = d.a[j].wrapping_mul(MUL).wrapping_add(j as u64 + 1);
            }
        }
        d.in_cs.store(0, Relaxed);
    }

    fn finish_task(&self) {
        if self.done_tasks.fetch_add(1, SeqCst) + 1 == self.cfg.tasks as u64 {
            self.shutdown.store(true, SeqCst);
            self.wake_all();
        }
    }

    unsafe fn run_task(&self, me: usize, t: *mut Task) {
        let w = &self.workers[me];
        let have;
        if (*t).resuming {
            (*t).resuming = false;
            if (*t).granted {
                (*t).granted = false;
                have = true;
            } else {
                have = self.acquire_slow(t, true);
            }
            if !have {
                return;
            }
        } else {
            let finished = if self.cfg.ms > 0 {
                self.stop.load(Relaxed)
            } else {
                (*t).ops >= self.cfg.ops_per_task
            };
            if finished {
                self.finish_task();
                return;
            }
            (*t).rng = outside((*t).rng, self.cfg.out_iters);
            (*t).t_req = now_ticks();
            if !self.acquire(t) {
                return;
            }
        }
        let wait = ((now_ticks() - (*t).t_req) as f64 * self.ns_per_tick) as u64;
        self.critical();
        self.release(w);
        (*t).ops += 1;
        let wl = &mut *w.local.get();
        wl.hist[hidx(wait)] += 1;
        if wait > wl.maxwait_ns {
            wl.maxwait_ns = wait;
        }
        if !self.stop.load(Relaxed) {
            wl.window_ops += 1;
        }
        self.push_local(w, t, false);
    }

    fn set_spinning(&self, me: usize, on: bool) {
        let wl = unsafe { &mut *self.workers[me].local.get() };
        if wl.spinning == on {
            return;
        }
        wl.spinning = on;
        if on {
            self.nspinning.fetch_add(1, SeqCst);
        } else {
            self.nspinning.fetch_sub(1, SeqCst);
        }
    }
    fn spinning(&self, me: usize) -> bool {
        unsafe { (*self.workers[me].local.get()).spinning }
    }

    fn worker_main(&self, me: usize) {
        unsafe {
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        }
        let w = &self.workers[me];
        loop {
            let mut t = self.find_work(me, false);
            if t.is_null() && !self.shutdown.load(SeqCst) {
                self.set_spinning(me, true);
                let mut i = 0;
                while i < SPIN_ROUNDS && t.is_null() {
                    cpu_relax();
                    t = self.find_work(me, i == SPIN_ROUNDS - 1);
                    i += 1;
                }
            }
            if !t.is_null() {
                if self.spinning(me) {
                    self.set_spinning(me, false);
                    self.wakep();
                }
                unsafe { self.run_task(me, t) };
                continue;
            }
            if self.shutdown.load(SeqCst) {
                break;
            }
            // park
            self.set_spinning(me, false);
            {
                let mut idle = self.idle.lock().unwrap();
                idle.push(me);
                self.nidle.fetch_add(1, SeqCst);
            }
            fence(SeqCst);
            let t = self.find_work(me, true);
            if !t.is_null() || self.shutdown.load(SeqCst) {
                let removed = self.remove_idle(me);
                if !removed {
                    *w.park.lock().unwrap() = false;
                    // the waker counted us spinning
                    unsafe { (*w.local.get()).spinning = true };
                }
                if !t.is_null() {
                    if self.spinning(me) {
                        self.set_spinning(me, false);
                        self.wakep();
                    }
                    unsafe { self.run_task(me, t) };
                }
                continue;
            }
            let notified = {
                let mut g = w.park.lock().unwrap();
                while !*g && !self.shutdown.load(SeqCst) {
                    g = w.cv.wait(g).unwrap();
                }
                let n = *g;
                *g = false;
                n
            };
            if notified {
                unsafe { (*w.local.get()).spinning = true };
            } else {
                self.remove_idle(me);
            }
        }
        if self.spinning(me) {
            self.set_spinning(me, false);
        }
    }

    fn remove_idle(&self, me: usize) -> bool {
        let mut idle = self.idle.lock().unwrap();
        if let Some(pos) = idle.iter().position(|&x| x == me) {
            idle.swap_remove(pos);
            self.nidle.fetch_sub(1, SeqCst);
            true
        } else {
            false
        }
    }
}

fn affine_pow(c: u64, mut n: u64) -> u64 {
    let (mut rb, mut bm, mut bb) = (0u64, MUL, c);
    while n > 0 {
        if n & 1 == 1 {
            rb = bm.wrapping_mul(rb).wrapping_add(bb);
        }
        bb = bm.wrapping_mul(bb).wrapping_add(bb);
        bm = bm.wrapping_mul(bm);
        n >>= 1;
    }
    rb
}

struct Res {
    ops_s: f64,
    p50: u64,
    p99: u64,
    max: u64,
    guard_frac: f64,
    ok: bool,
}

fn pct(h: &[u64], n: u64, q: f64) -> u64 {
    let mut want = (q * n as f64) as u64;
    if want >= n {
        want = n.saturating_sub(1);
    }
    let mut acc = 0;
    for (i, &c) in h.iter().enumerate() {
        acc += c;
        if acc > want {
            return hval(i);
        }
    }
    0
}

fn new_sched(cfg: Cfg, ns_per_tick: f64, rep: usize) -> &'static Sched {
    let workers = (0..cfg.workers)
        .map(|i| Worker {
            lock: Spin::new(),
            ring: UnsafeCell::new(Ring { head: 0, tail: 0, buf: vec![ptr::null_mut(); QCAP].into_boxed_slice() }),
            runnext: AtomicPtr::new(ptr::null_mut()),
            park: Mutex::new(false),
            cv: Condvar::new(),
            local: UnsafeCell::new(WLocal {
                spinning: false,
                window_ops: 0,
                hist: Box::new([0; HB]),
                maxwait_ns: 0,
                rng: 0x9e3779b97f4a7c15u64.wrapping_mul((i + 1 + rep * 131) as u64),
            }),
        })
        .collect();
    let tasks = (0..cfg.tasks)
        .map(|i| {
            UnsafeCell::new(Task {
                next: ptr::null_mut(),
                t_req: 0,
                resuming: false,
                granted: false,
                ops: 0,
                rng: (i as u64).wrapping_mul(0x2545F4914F6CDD1D).wrapping_add(1),
            })
        })
        .collect();
    let s = Box::leak(Box::new(Sched {
        cfg,
        ns_per_tick,
        inst: Inst {
            state: AtomicU64::new(0),
            qlock: Spin::new(),
            q: UnsafeCell::new(InstQ { head: ptr::null_mut(), tail: ptr::null_mut(), woken: false, guard_handoffs: 0 }),
            data: UnsafeCell::new(InstData { in_cs: AtomicI32::new(0), counter: 0, a: [0; SW] }),
        },
        workers,
        tasks,
        idle: Mutex::new(Vec::with_capacity(MAXW)),
        nidle: AtomicI32::new(0),
        nspinning: AtomicI32::new(0),
        done_tasks: AtomicU64::new(0),
        stop: AtomicBool::new(false),
        shutdown: AtomicBool::new(false),
    }));
    for i in 0..cfg.tasks {
        let w = &s.workers[i % cfg.workers];
        let r = unsafe { &mut *w.ring.get() };
        r.buf[r.tail & (QCAP - 1)] = s.tasks[i].get();
        r.tail += 1;
    }
    s
}

fn run_once(cfg: Cfg, ns_per_tick: f64, rep: usize) -> Res {
    let s = new_sched(cfg, ns_per_tick, rep);
    let t0 = now_ticks();
    let hs: Vec<_> = (0..cfg.workers).map(|i| std::thread::spawn(move || s.worker_main(i))).collect();
    let mut t1 = 0;
    if cfg.ms > 0 {
        std::thread::sleep(std::time::Duration::from_millis(cfg.ms));
        s.stop.store(true, SeqCst);
        t1 = now_ticks();
    }
    for h in hs {
        h.join().unwrap();
    }
    if cfg.ms == 0 {
        t1 = now_ticks();
    }
    let mut h = vec![0u64; HB];
    let (mut n, mut wops, mut mx) = (0u64, 0u64, 0u64);
    for w in &s.workers {
        let wl = unsafe { &*w.local.get() };
        for b in 0..HB {
            h[b] += wl.hist[b];
            n += wl.hist[b];
        }
        wops += wl.window_ops;
        mx = mx.max(wl.maxwait_ns);
    }
    let task_ops: u64 = s.tasks.iter().map(|t| unsafe { (*t.get()).ops }).sum();
    let d = unsafe { &*s.inst.data.get() };
    let q = unsafe { &*s.inst.q.get() };
    let mut ok = task_ops == d.counter && n == d.counter;
    if cfg.ms == 0 && d.counter != cfg.ops_per_task * cfg.tasks as u64 {
        ok = false;
    }
    for j in 0..SW {
        if d.a[j] != affine_pow(j as u64 + 1, d.counter * cfg.cs_rounds) {
            ok = false;
        }
    }
    if s.inst.state.load(SeqCst) != 0 || !q.head.is_null() {
        ok = false;
    }
    if cfg.mode == Mode::Fifo && q.guard_handoffs != 0 {
        ok = false;
    }
    if !ok {
        eprintln!("CHECK FAILED: counter={} task_ops={} hist={}", d.counter, task_ops, n);
    }
    let secs = (t1 - t0) as f64 * ns_per_tick / 1e9;
    Res {
        ops_s: (if cfg.ms > 0 { wops } else { d.counter }) as f64 / secs,
        p50: pct(&h, n, 0.50),
        p99: pct(&h, n, 0.99),
        max: mx,
        guard_frac: if d.counter > 0 { q.guard_handoffs as f64 / d.counter as f64 } else { 0.0 },
        ok,
    }
    // the leaked Sched is a few hundred KB per rep; fine for a benchmark
}

fn calibrate(cfg: Cfg, ns_per_tick: f64, which: u32) -> u64 {
    // iterations per microsecond, timed on the same code the run uses
    let iters = 2_000_000u64;
    let mut c = cfg;
    c.cs_rounds = iters;
    c.workers = 1;
    c.tasks = 1;
    let s = new_sched(c, ns_per_tick, 0);
    let t0 = now_ticks();
    if which == 0 {
        unsafe { s.critical() };
    } else {
        std::hint::black_box(outside(std::hint::black_box(1), iters));
    }
    let ns = (now_ticks() - t0) as f64 * ns_per_tick;
    (iters as f64 * 1000.0 / ns) as u64
}

fn fmt_g4(x: f64) -> String {
    // like printf("%.4g") for the magnitudes we print
    if x == 0.0 {
        return "0".into();
    }
    let e = x.abs().log10().floor() as i32;
    if (-4..4).contains(&e) {
        let dec = (3 - e).max(0) as usize;
        let s = format!("{:.*}", dec, x);
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s }
    } else {
        let m = x / 10f64.powi(e);
        format!("{:.3}e{}{:02}", m, if e < 0 { '-' } else { '+' }, e.abs())
    }
}

fn main() {
    let mut tb = MachTimebase { numer: 0, denom: 0 };
    unsafe {
        mach_timebase_info(&mut tb);
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
    let ns_per_tick = tb.numer as f64 / tb.denom as f64;
    let mut cfg = Cfg {
        mode: Mode::Barge,
        workers: 8,
        tasks: 64,
        cs_ns: 200,
        out_ns: 1000,
        cs_rounds: 0,
        out_iters: 0,
        ms: 1000,
        ops_per_task: 0,
        guard_ticks: 0,
        reps: 5,
    };
    let mut guard_us = 1000u64;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        let v = args.get(i + 1).cloned().unwrap_or_default();
        match args[i].as_str() {
            "--mode" => cfg.mode = if v == "fifo" { Mode::Fifo } else { Mode::Barge },
            "--workers" => cfg.workers = v.parse().unwrap(),
            "--tasks" => cfg.tasks = v.parse().unwrap(),
            "--cs-ns" => cfg.cs_ns = v.parse().unwrap(),
            "--out-ns" => cfg.out_ns = v.parse().unwrap(),
            "--ms" => cfg.ms = v.parse().unwrap(),
            "--ops" => {
                cfg.ops_per_task = v.parse().unwrap();
                cfg.ms = 0;
            }
            "--guard-us" => guard_us = v.parse().unwrap(),
            "--reps" => cfg.reps = v.parse().unwrap(),
            a => {
                eprintln!("unknown arg {a}");
                std::process::exit(2);
            }
        }
        i += 2;
    }
    assert!(cfg.workers >= 1 && cfg.workers <= MAXW && cfg.tasks >= 1 && cfg.tasks < QCAP);
    cfg.guard_ticks = (guard_us as f64 * 1000.0 / ns_per_tick) as u64;
    let cs_per_us = calibrate(cfg, ns_per_tick, 0);
    let out_per_us = calibrate(cfg, ns_per_tick, 1);
    cfg.cs_rounds = (cfg.cs_ns * cs_per_us / 1000).max(1);
    cfg.out_iters = cfg.out_ns * out_per_us / 1000;

    let reps = cfg.reps.clamp(1, 64);
    let mut ops = vec![];
    let mut p50 = vec![];
    let mut p99 = vec![];
    let mut gf = vec![];
    let mut mx = 0;
    let mut ok = true;
    for r in 0..reps {
        let x = run_once(cfg, ns_per_tick, r);
        ops.push(x.ops_s);
        p50.push(x.p50 as f64);
        p99.push(x.p99 as f64);
        gf.push(x.guard_frac);
        mx = mx.max(x.max);
        ok &= x.ok;
    }
    for v in [&mut ops, &mut p50, &mut p99, &mut gf] {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    }
    let m = reps / 2;
    println!(
        "p3 impl=rust mode={} workers={} tasks={} cs_ns={} out_ns={} reps={} ops_per_s={} wait_p50_ns={:.0} wait_p99_ns={:.0} wait_max_ns={} guard_handoff_frac={:.4} ok={}",
        if cfg.mode == Mode::Fifo { "fifo" } else { "barge" },
        cfg.workers, cfg.tasks, cfg.cs_ns, cfg.out_ns, reps,
        fmt_g4(ops[m]), p50[m], p99[m], mx, gf[m], ok as i32
    );
    std::process::exit(if ok { 0 } else { 1 });
}
