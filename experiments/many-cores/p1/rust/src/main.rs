//! P1, the cost of a hop. A port of ../c/p1.c, variant for variant; see
//! ../README.md. std only; the ulock, QoS and clock calls are declared here.

use std::cell::UnsafeCell;
use std::hint::spin_loop;
use std::ptr;
use std::sync::atomic::{fence, AtomicBool, AtomicPtr, AtomicU32, Ordering::*};
use std::sync::{Condvar, Mutex};

const SEED: u64 = 0x9E37_79B9_7F4A_7C15;
const COLD_GAP_NS: f64 = 50_000.0;

// ---------- the OS ----------
#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
extern "C" {
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut Timebase) -> i32;
    fn pthread_set_qos_class_self_np(qos: u32, rel: i32) -> i32;
    fn os_sync_wait_on_address(addr: *mut u8, value: u64, size: usize, flags: u32) -> i32;
    fn os_sync_wake_by_address_any(addr: *mut u8, size: usize, flags: u32) -> i32;
}
fn now() -> u64 {
    unsafe { mach_absolute_time() }
}
fn wait_on(a: &AtomicU32, v: u32) {
    unsafe { os_sync_wait_on_address(a.as_ptr() as *mut u8, v as u64, 4, 0) };
}
fn wake_one(a: &AtomicU32) {
    unsafe { os_sync_wake_by_address_any(a.as_ptr() as *mut u8, 4, 0) };
}
fn set_qos() {
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) };
}

// ---------- the instance: a lock word and the handler's state ----------
#[repr(C, align(128))]
struct Instance {
    lock: AtomicU32, // 0 free, 1 held, 2 held with parked waiters
    st: UnsafeCell<State>,
}
struct State {
    state: u64,
    ops: u64,
    slow: u64,
}
unsafe impl Sync for Instance {}

impl Instance {
    fn new() -> Box<Self> {
        Box::new(Instance {
            lock: AtomicU32::new(0),
            st: UnsafeCell::new(State { state: SEED, ops: 0, slow: 0 }),
        })
    }
    fn get(&self) -> &State {
        unsafe { &*self.st.get() }
    }
}

/// The operation. Caller guarantees exclusive access (unshared, taken, or
/// on the home core).
#[inline(never)]
unsafe fn op_run(inst: &Instance, iters: u32) -> u64 {
    let st = &mut *inst.st.get();
    let mut s = st.state;
    for _ in 0..iters {
        s ^= s >> 29;
        s = s.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    }
    st.state = s;
    st.ops += 1;
    s
}

#[inline(never)]
#[cold]
fn lock_slow(inst: &Instance) {
    // Only reached with the lock held, so the held state is ours to note
    // after we get it.
    while inst.lock.swap(2, Acquire) != 0 {
        wait_on(&inst.lock, 2);
    }
    unsafe { (*inst.st.get()).slow += 1 };
}
#[inline(always)]
fn take(inst: &Instance) {
    if inst.lock.compare_exchange(0, 1, Acquire, Relaxed).is_err() {
        lock_slow(inst);
    }
}
#[inline(always)]
fn let_go(inst: &Instance) {
    if inst.lock.swap(0, Release) != 1 {
        wake_one(&inst.lock);
    }
}

// ---------- the home core ----------
#[derive(Clone, Copy, PartialEq)]
enum Mode {
    Spin,
    Park,
    Condvar,
}

struct Waiter {
    m: Mutex<()>,
    c: Condvar,
}

/// A message lives in the calling task's frame (here, the caller's stack).
struct Msg {
    next: AtomicPtr<Msg>,
    inst: *const Instance,
    iters: u32,
    result: UnsafeCell<u64>,
    done: AtomicU32, // 0 pending, 1 done, 2 caller parked
    w: *const Waiter,
}
impl Msg {
    fn stub() -> Msg {
        Msg {
            next: AtomicPtr::new(ptr::null_mut()),
            inst: ptr::null(),
            iters: 0,
            result: UnsafeCell::new(0),
            done: AtomicU32::new(0),
            w: ptr::null(),
        }
    }
}

#[repr(C, align(128))]
struct Pad<T>(T);

struct Home {
    tail: Pad<AtomicPtr<Msg>>,
    head: Pad<UnsafeCell<*mut Msg>>, // consumer only
    stub: Box<Msg>,
    sleeping: Pad<AtomicU32>,
    stop: AtomicBool,
    m: Mutex<()>,
    c: Condvar,
    mode: Mode,
    caller_park: bool,
    handled: UnsafeCell<u64>, // consumer only; read after join
}
unsafe impl Sync for Home {}
unsafe impl Send for Home {}

impl Home {
    fn new(mode: Mode, caller_park: bool) -> Box<Home> {
        let mut stub = Box::new(Msg::stub());
        let sp: *mut Msg = &mut *stub;
        Box::new(Home {
            tail: Pad(AtomicPtr::new(sp)),
            head: Pad(UnsafeCell::new(sp)),
            stub,
            sleeping: Pad(AtomicU32::new(0)),
            stop: AtomicBool::new(false),
            m: Mutex::new(()),
            c: Condvar::new(),
            mode,
            caller_park,
            handled: UnsafeCell::new(0),
        })
    }
    fn stub_ptr(&self) -> *mut Msg {
        &*self.stub as *const Msg as *mut Msg
    }
    // Vyukov's intrusive MPSC queue.
    fn push(&self, n: *mut Msg) {
        unsafe {
            (*n).next.store(ptr::null_mut(), Relaxed);
            let prev = self.tail.0.swap(n, SeqCst);
            (*prev).next.store(n, Release);
        }
    }
    unsafe fn pop(&self) -> *mut Msg {
        let hp = self.head.0.get();
        let mut head = *hp;
        let mut next = (*head).next.load(Acquire);
        if head == self.stub_ptr() {
            if next.is_null() {
                return ptr::null_mut();
            }
            *hp = next;
            head = next;
            next = (*next).next.load(Acquire);
        }
        if !next.is_null() {
            *hp = next;
            return head;
        }
        if self.tail.0.load(Acquire) != head {
            return ptr::null_mut();
        }
        self.push(self.stub_ptr());
        next = (*head).next.load(Acquire);
        if !next.is_null() {
            *hp = next;
            return head;
        }
        ptr::null_mut()
    }
    unsafe fn empty(&self) -> bool {
        *self.head.0.get() == self.stub_ptr() && self.tail.0.load(SeqCst) == self.stub_ptr()
    }
    fn reply_mode(&self) -> Mode {
        if self.mode == Mode::Condvar {
            Mode::Condvar
        } else if self.caller_park {
            Mode::Park
        } else {
            Mode::Spin
        }
    }
    unsafe fn deliver(&self, m: *mut Msg, r: u64) {
        *(*m).result.get() = r;
        match self.reply_mode() {
            Mode::Spin => (*m).done.store(1, Release),
            Mode::Park => {
                let d: *const AtomicU32 = &(*m).done;
                if (*d).swap(1, AcqRel) == 2 {
                    wake_one(&*d);
                }
            }
            Mode::Condvar => {
                let w = &*(*m).w;
                let g = w.m.lock().unwrap();
                (*m).done.store(1, Release);
                w.c.notify_one();
                drop(g);
            }
        }
    }
    unsafe fn run(&self) {
        set_qos();
        loop {
            let m = self.pop();
            if !m.is_null() {
                let r = op_run(&*(*m).inst, (*m).iters); // the home core owns it: no lock
                *self.handled.get() += 1;
                self.deliver(m, r);
                continue;
            }
            if self.stop.load(Acquire) && self.empty() {
                break;
            }
            if !self.empty() {
                spin_loop();
                continue;
            }
            match self.mode {
                Mode::Spin => spin_loop(),
                Mode::Park => {
                    self.sleeping.0.store(1, SeqCst);
                    if !self.empty() || self.stop.load(SeqCst) {
                        self.sleeping.0.store(0, Relaxed);
                        continue;
                    }
                    while self.sleeping.0.load(Acquire) == 1 {
                        wait_on(&self.sleeping.0, 1);
                    }
                }
                Mode::Condvar => {
                    let mut g = self.m.lock().unwrap();
                    self.sleeping.0.store(1, SeqCst);
                    while self.empty() && !self.stop.load(SeqCst) {
                        g = self.c.wait(g).unwrap();
                    }
                    self.sleeping.0.store(0, Relaxed);
                    drop(g);
                }
            }
        }
    }
    fn wake(&self) {
        if self.mode == Mode::Spin {
            return;
        }
        fence(SeqCst);
        if self.sleeping.0.load(SeqCst) != 1 {
            return;
        }
        if self.mode == Mode::Park {
            if self.sleeping.0.swap(0, AcqRel) == 1 {
                wake_one(&self.sleeping.0);
            }
        } else {
            let g = self.m.lock().unwrap();
            self.c.notify_one();
            drop(g);
        }
    }
    fn hop(&self, inst: &Instance, iters: u32, w: &Waiter) -> u64 {
        let mut m = Msg {
            next: AtomicPtr::new(ptr::null_mut()),
            inst,
            iters,
            result: UnsafeCell::new(0),
            done: AtomicU32::new(0),
            w,
        };
        self.push(&mut m);
        self.wake();
        match self.reply_mode() {
            Mode::Spin => {
                while m.done.load(Acquire) == 0 {
                    spin_loop();
                }
            }
            Mode::Park => {
                if m.done.compare_exchange(0, 2, AcqRel, Acquire).is_ok() {
                    while m.done.load(Acquire) == 2 {
                        wait_on(&m.done, 2);
                    }
                }
            }
            Mode::Condvar => {
                let mut g = w.m.lock().unwrap();
                while m.done.load(Acquire) == 0 {
                    g = w.c.wait(g).unwrap();
                }
                drop(g);
            }
        }
        unsafe { *m.result.get() }
    }
}

struct Running {
    home: &'static Home,
    th: std::thread::JoinHandle<()>,
}
fn home_start(mode: Mode, caller_park: bool) -> Running {
    let home: &'static Home = Box::leak(Home::new(mode, caller_park));
    let hp = home as *const Home as usize;
    let th = std::thread::Builder::new()
        .name("home".into())
        .spawn(move || unsafe { (*(hp as *const Home)).run() })
        .unwrap();
    Running { home, th }
}
fn home_stop(r: Running) -> u64 {
    let h = r.home;
    h.stop.store(true, SeqCst);
    match h.mode {
        Mode::Park => {
            h.sleeping.0.store(0, SeqCst);
            wake_one(&h.sleeping.0);
        }
        Mode::Condvar => {
            let g = h.m.lock().unwrap();
            h.c.notify_one();
            drop(g);
        }
        Mode::Spin => {}
    }
    r.th.join().unwrap();
    unsafe { *h.handled.get() }
}

// ---------- the harness ----------
const VNAMES: [&str; 7] = [
    "call",
    "take",
    "hop_spin",
    "hop_park",
    "hop_park_cold",
    "hop_park_both",
    "hop_condvar",
];
fn home_for(v: usize) -> Running {
    let mode = match VNAMES[v] {
        "hop_spin" => Mode::Spin,
        "hop_condvar" => Mode::Condvar,
        _ => Mode::Park,
    };
    home_start(mode, matches!(VNAMES[v], "hop_park_both" | "hop_condvar"))
}

struct Ctx<'a> {
    v: usize,
    inst: &'a Instance,
    home: Option<&'static Home>,
    iters: u32,
    w: &'a Waiter,
}
impl Ctx<'_> {
    #[inline(always)]
    fn one(&self) -> u64 {
        match self.v {
            0 => unsafe { op_run(self.inst, self.iters) },
            1 => {
                take(self.inst);
                let r = unsafe { op_run(self.inst, self.iters) };
                let_go(self.inst);
                r
            }
            _ => self.home.unwrap().hop(self.inst, self.iters, self.w),
        }
    }
}

struct Clock {
    tick_ns: f64,
}
impl Clock {
    fn idle_gap(&self) {
        let end = now() + (COLD_GAP_NS / self.tick_ns) as u64;
        while now() < end {
            spin_loop();
        }
    }
    fn batch(&self, c: &Ctx, n: u64, gap: bool) -> f64 {
        let mut acc = 0u64;
        if !gap {
            let t0 = now();
            for _ in 0..n {
                acc ^= c.one();
            }
            let t1 = now();
            std::hint::black_box(acc);
            return (t1 - t0) as f64 * self.tick_ns / n as f64;
        }
        let mut tot = 0u64;
        for _ in 0..n {
            self.idle_gap();
            let t0 = now();
            acc ^= c.one();
            tot += now() - t0;
        }
        std::hint::black_box(acc);
        tot as f64 * self.tick_ns / n as f64
    }
    fn sample(&self, c: &Ctx, n: u64, gap: bool, out: &mut Vec<f64>) {
        let mut acc = 0u64;
        for _ in 0..n {
            if gap {
                self.idle_gap();
            }
            let t0 = now();
            acc ^= c.one();
            out.push((now() - t0) as f64 * self.tick_ns);
        }
        std::hint::black_box(acc);
    }
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    v[(p * (v.len() - 1) as f64 + 0.5) as usize]
}

fn calibrate(clk: &Clock) -> f64 {
    let inst = Instance::new();
    let mut best = 1e9f64;
    for _ in 0..5 {
        let n = 20_000_000u32;
        let t0 = now();
        unsafe { op_run(&inst, std::hint::black_box(n)) };
        best = best.min((now() - t0) as f64 * clk.tick_ns / n as f64);
    }
    best
}

fn reference(iters: u32, n: u64) -> u64 {
    let inst = Instance::new();
    for _ in 0..n {
        unsafe { op_run(&inst, iters) };
    }
    inst.get().state
}

struct Res {
    median: f64,
    p50: f64,
    p99: f64,
    ok: bool,
}

fn run_config(clk: &Clock, v: usize, iters: u32, work_ns: f64, reps: usize, budget: f64, w: &Waiter) -> Res {
    let gap = VNAMES[v] == "hop_park_cold";
    let per = work_ns + if gap { COLD_GAP_NS } else { 300.0 };
    let n = ((budget / per) as u64).max(200);
    let ns = n.min(10_000);
    let warm = n / 10 + 1;
    let inst = Instance::new();
    let running = if v >= 2 { Some(home_for(v)) } else { None };
    let c = Ctx { v, inst: &inst, home: running.as_ref().map(|r| r.home), iters, w };
    let mut means = Vec::with_capacity(reps);
    let mut samples = Vec::with_capacity(ns as usize * reps);
    clk.batch(&c, warm, gap);
    for _ in 0..reps {
        means.push(clk.batch(&c, n, gap));
        clk.sample(&c, ns, gap, &mut samples);
    }
    drop(c);
    let handled = running.map(home_stop);
    let total = warm + reps as u64 * (n + ns);
    let want = reference(iters, total);
    let st = inst.get();
    let ok = st.state == want && st.ops == total && st.slow == 0 && handled.map_or(true, |h| h == total);
    if !ok {
        eprintln!(
            "FAIL {} iters={}: state {:x} want {:x} ops {} total {} slow {} handled {:?}",
            VNAMES[v], iters, st.state, want, st.ops, total, st.slow, handled
        );
    }
    Res { median: pct(&mut means, 0.5), p50: pct(&mut samples, 0.5), p99: pct(&mut samples, 0.99), ok }
}

fn main() {
    let mut quick = false;
    let mut check = false;
    let mut reps = 11usize;
    let mut only: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--quick" => quick = true,
            "--check" => check = true,
            "--reps" => reps = args.next().and_then(|s| s.parse().ok()).expect("--reps N"),
            "--variant" => only = args.next(),
            _ => {
                eprintln!("usage: p1 [--quick] [--check] [--reps N] [--variant NAME]");
                std::process::exit(2);
            }
        }
    }
    let mut tb = Timebase { numer: 0, denom: 0 };
    unsafe { mach_timebase_info(&mut tb) };
    let clk = Clock { tick_ns: tb.numer as f64 / tb.denom as f64 };
    set_qos();
    let w = Waiter { m: Mutex::new(()), c: Condvar::new() };

    if check {
        let want = reference(7, 1000);
        let mut fails = 0;
        for v in 0..VNAMES.len() {
            let inst = Instance::new();
            let running = if v >= 2 { Some(home_for(v)) } else { None };
            let c = Ctx { v, inst: &inst, home: running.as_ref().map(|r| r.home), iters: 7, w: &w };
            for _ in 0..1000 {
                c.one();
            }
            drop(c);
            let handled = running.map(home_stop);
            let st = inst.get();
            if st.state != want || st.ops != 1000 || handled.map_or(false, |h| h != 1000) {
                fails += 1;
            }
        }
        println!("CHECK lang=rust state={:016x} {}", want, if fails > 0 { "FAIL" } else { "ok" });
        std::process::exit(if fails > 0 { 1 } else { 0 });
    }

    if quick {
        reps = reps.min(3);
    }
    let budget = if quick { 2e6 } else { 2e7 };
    let ns_per_iter = calibrate(&clk);
    let mut fails = 0;
    for &work in &[0.0f64, 10.0, 100.0, 1000.0, 10000.0] {
        let mut iters = (work / ns_per_iter + 0.5) as u32;
        if iters < 1 && work > 0.0 {
            iters = 1;
        }
        let mut call_median = 0.0;
        for v in 0..VNAMES.len() {
            let selected = only.as_deref().map_or(true, |o| o == VNAMES[v]);
            if !selected && v != 0 {
                continue;
            }
            let r = run_config(&clk, v, iters, work, reps, budget, &w);
            if !r.ok {
                fails += 1;
            }
            if v == 0 {
                call_median = r.median;
            }
            if !selected {
                continue;
            }
            println!(
                "P1 lang=rust variant={} work_ns={} iters={} workers=1 reps={} median_ns={:.2} \
                 overhead_ns={:.2} p50_ns={:.1} p99_ns={:.1} qos=user_interactive",
                VNAMES[v], work, iters, reps, r.median, r.median - call_median, r.p50, r.p99
            );
        }
    }
    if fails > 0 {
        eprintln!("{} configuration(s) failed their checks", fails);
        std::process::exit(1);
    }
}
