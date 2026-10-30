// S1 (and S2): stripes against atomics. The Rust twin of ../c/s1.c; same variants,
// same flags, same output line (lang=rust). See ../README.md.

use std::alloc::{alloc_zeroed, dealloc, Layout};
use std::cell::UnsafeCell;
use std::hint::spin_loop;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, AtomicUsize, Ordering::*};
use std::sync::Arc;
use std::time::{Duration, Instant};

extern "C" {
    fn pthread_set_qos_class_self_np(qos: u32, rel: i32) -> i32;
    fn os_unfair_lock_lock(l: *mut u32);
    fn os_unfair_lock_unlock(l: *mut u32);
    fn sched_yield() -> i32;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
fn set_qos() {
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) };
}

// ---- The Ren instance lock (prototype): CAS fast path, spin then yield, barging. ----
#[repr(transparent)]
struct RenLock(AtomicU32);
const SPIN_BEFORE_YIELD: u32 = 128;
impl RenLock {
    #[inline(always)]
    fn acquire(&self) {
        if self.0.compare_exchange_weak(0, 1, Acquire, Relaxed).is_ok() {
            return;
        }
        loop {
            let mut n = 0;
            while self.0.load(Relaxed) != 0 {
                n += 1;
                if n < SPIN_BEFORE_YIELD {
                    spin_loop();
                } else {
                    unsafe { sched_yield() };
                    n = 0;
                }
            }
            if self.0.compare_exchange_weak(0, 1, Acquire, Relaxed).is_ok() {
                return;
            }
        }
    }
    #[inline(always)]
    fn release(&self) {
        self.0.store(0, Release);
    }
}

// A locked instance: lock word + state, state only touched under the lock. 16 B.
#[repr(C)]
struct LockedInst {
    lock: RenLock,
    _r: u32,
    count: UnsafeCell<i64>,
}
unsafe impl Sync for LockedInst {}
impl LockedInst {
    #[inline(always)]
    fn add(&self) {
        self.lock.acquire();
        unsafe { *self.count.get() += 1 };
        self.lock.release();
    }
    #[inline(always)]
    fn get(&self) -> i64 {
        self.lock.acquire();
        let v = unsafe { *self.count.get() };
        self.lock.release();
        v
    }
}
// An owner-only stripe: written by its owner (load+store, no RMW), read by the merge. 8 B.
#[repr(C)]
struct OwnerInst {
    count: AtomicI64,
}
#[repr(C, align(128))]
struct UnfairInst {
    lock: UnsafeCell<u32>, // os_unfair_lock
    count: UnsafeCell<i64>,
}
unsafe impl Sync for UnfairInst {}
#[repr(C, align(128))]
struct Padded<T>(T);

#[derive(Clone, Copy, PartialEq, Debug)]
enum V {
    OneLock,
    OneUnfair,
    Atomic,
    StripeLock,
    StripeOwner,
}
const NAMES: [(&str, V); 5] = [
    ("one_lock", V::OneLock),
    ("one_unfair", V::OneUnfair),
    ("atomic", V::Atomic),
    ("stripe_lock", V::StripeLock),
    ("stripe_owner", V::StripeOwner),
];

#[derive(Clone, Copy)]
struct Config {
    v: V,
    workers: usize,
    pad: usize,
    ms: u64,
    reps: usize,
    reader: bool,
    work: u32,
}

// Stripes: a 128-aligned block, `stride` bytes per stripe.
struct Stripes {
    base: *mut u8,
    stride: usize,
    layout: Layout,
}
unsafe impl Sync for Stripes {}
unsafe impl Send for Stripes {}
impl Stripes {
    fn new(n: usize, stride: usize) -> Self {
        let layout = Layout::from_size_align(((stride * n + 127) / 128) * 128 + 128, 128).unwrap();
        let base = unsafe { alloc_zeroed(layout) };
        Stripes { base, stride, layout }
    }
    #[inline(always)]
    fn locked(&self, i: usize) -> &LockedInst {
        unsafe { &*(self.base.add(i * self.stride) as *const LockedInst) }
    }
    #[inline(always)]
    fn owner(&self, i: usize) -> &OwnerInst {
        unsafe { &*(self.base.add(i * self.stride) as *const OwnerInst) }
    }
}
impl Drop for Stripes {
    fn drop(&mut self) {
        unsafe { dealloc(self.base, self.layout) }
    }
}

struct Shared {
    cfg: Config,
    stripes: Stripes,
    one: Padded<LockedInst>,
    unfair: UnfairInst,
    atom: Padded<AtomicI64>,
    go: Padded<AtomicBool>,
    stop: Padded<AtomicBool>,
    ready: Padded<AtomicUsize>,
}

impl Shared {
    #[inline(always)]
    fn add(&self, me: usize) {
        match self.cfg.v {
            V::OneLock => self.one.0.add(),
            V::OneUnfair => unsafe {
                os_unfair_lock_lock(self.unfair.lock.get());
                *self.unfair.count.get() += 1;
                os_unfair_lock_unlock(self.unfair.lock.get());
            },
            V::Atomic => {
                self.atom.0.fetch_add(1, SeqCst);
            }
            V::StripeLock => self.stripes.locked(me).add(),
            V::StripeOwner => {
                let s = self.stripes.owner(me);
                let x = s.count.load(Relaxed);
                s.count.store(x + 1, Relaxed);
            }
        }
    }
    // The keyless `get`, merge: Sum, in stripe order.
    #[inline(always)]
    fn merge(&self) -> i64 {
        match self.cfg.v {
            V::OneLock => self.one.0.get(),
            V::OneUnfair => unsafe {
                os_unfair_lock_lock(self.unfair.lock.get());
                let v = *self.unfair.count.get();
                os_unfair_lock_unlock(self.unfair.lock.get());
                v
            },
            V::Atomic => self.atom.0.load(SeqCst),
            V::StripeLock => (0..self.cfg.workers).map(|i| self.stripes.locked(i).get()).sum(),
            V::StripeOwner => (0..self.cfg.workers).map(|i| self.stripes.owner(i).count.load(Acquire)).sum(),
        }
    }
}

#[inline(always)]
fn busy(k: u32, mut x: u64) -> u64 {
    for _ in 0..k {
        x = std::hint::black_box(x.wrapping_mul(6364136223846793005).wrapping_add(1));
    }
    x
}

struct ReaderOut {
    lat: Vec<u64>,
    backwards: u64,
    last: i64,
    total_ns: u64,
}

struct Rep {
    mops: f64,
    p50: f64,
    p99: f64,
    mean: f64,
    ok: bool,
}

fn run_once(cfg: Config) -> Rep {
    let natural = if cfg.v == V::StripeOwner { 8 } else { 16 };
    let stride = cfg.pad.max(natural);
    let sh = Arc::new(Shared {
        cfg,
        stripes: Stripes::new(cfg.workers, stride),
        one: Padded(LockedInst { lock: RenLock(AtomicU32::new(0)), _r: 0, count: UnsafeCell::new(0) }),
        unfair: UnfairInst { lock: UnsafeCell::new(0), count: UnsafeCell::new(0) },
        atom: Padded(AtomicI64::new(0)),
        go: Padded(AtomicBool::new(false)),
        stop: Padded(AtomicBool::new(false)),
        ready: Padded(AtomicUsize::new(0)),
    });
    let mut ws = Vec::new();
    for id in 0..cfg.workers {
        let sh = sh.clone();
        ws.push(std::thread::spawn(move || {
            set_qos();
            sh.ready.0.fetch_add(1, SeqCst);
            while !sh.go.0.load(Acquire) {
                spin_loop();
            }
            let mut ops: i64 = 0;
            let mut x = id as u64;
            while !sh.stop.0.load(Relaxed) {
                for _ in 0..256 {
                    sh.add(id);
                    x = busy(sh.cfg.work, x);
                }
                ops += 256;
            }
            std::hint::black_box(x);
            ops
        }));
    }
    let rd = if cfg.reader {
        let sh = sh.clone();
        Some(std::thread::spawn(move || {
            set_qos();
            sh.ready.0.fetch_add(1, SeqCst);
            while !sh.go.0.load(Acquire) {
                spin_loop();
            }
            let mut out = ReaderOut { lat: Vec::with_capacity(1 << 16), backwards: 0, last: 0, total_ns: 0 };
            let start = Instant::now();
            while !sh.stop.0.load(Relaxed) {
                let t0 = Instant::now();
                let v = sh.merge();
                let dt = t0.elapsed().as_nanos() as u64;
                if v < out.last {
                    out.backwards += 1;
                }
                out.last = v;
                out.lat.push(dt);
            }
            out.total_ns = start.elapsed().as_nanos() as u64;
            out
        }))
    } else {
        None
    };
    let nthreads = cfg.workers + cfg.reader as usize;
    while sh.ready.0.load(SeqCst) < nthreads {
        spin_loop();
    }
    let t0 = Instant::now();
    sh.go.0.store(true, Release);
    std::thread::sleep(Duration::from_millis(cfg.ms));
    sh.stop.0.store(true, Relaxed);
    let per: Vec<i64> = ws.into_iter().map(|h| h.join().unwrap()).collect();
    let rdout = rd.map(|h| h.join().unwrap());
    let elapsed = t0.elapsed().as_nanos() as f64;

    let sum_ops: i64 = per.iter().sum();
    let total = sh.merge();
    let mut ok = total == sum_ops;
    if matches!(cfg.v, V::StripeLock | V::StripeOwner) {
        for (i, &o) in per.iter().enumerate() {
            let si = if cfg.v == V::StripeLock { sh.stripes.locked(i).get() } else { sh.stripes.owner(i).count.load(SeqCst) };
            if si != o {
                ok = false;
            }
        }
    }
    if !ok {
        eprintln!("CHECK FAILED: variant={:?} workers={} merged={} adds={}", cfg.v, cfg.workers, total, sum_ops);
    }
    let mut rep = Rep { mops: sum_ops as f64 / elapsed * 1e3, p50: 0.0, p99: 0.0, mean: 0.0, ok };
    if let Some(mut r) = rdout {
        if r.backwards > 0 || r.last > total {
            eprintln!("CHECK FAILED: merge went backwards {} times or overshot", r.backwards);
            rep.ok = false;
        }
        if !r.lat.is_empty() {
            r.lat.sort_unstable();
            rep.p50 = r.lat[r.lat.len() / 2] as f64;
            rep.p99 = r.lat[(r.lat.len() as f64 * 0.99) as usize] as f64;
            rep.mean = r.total_ns as f64 / r.lat.len() as f64;
        }
    }
    rep
}

fn usage() -> ! {
    eprintln!("usage: s1 --variant one_lock|one_unfair|atomic|stripe_lock|stripe_owner --workers N [--pad 0|64|128] [--ms 200] [--reps 5] [--reader 0|1] [--work 0]");
    std::process::exit(2)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut cfg = Config { v: V::Atomic, workers: 1, pad: 128, ms: 200, reps: 5, reader: false, work: 0 };
    let mut have_v = false;
    let mut i = 0;
    while i < args.len() {
        if i + 1 >= args.len() {
            usage()
        }
        let (k, v) = (&args[i], &args[i + 1]);
        let num = || v.parse::<u64>().unwrap_or_else(|_| usage());
        match k.as_str() {
            "--variant" => {
                cfg.v = NAMES.iter().find(|(n, _)| n == v).map(|(_, x)| *x).unwrap_or_else(|| usage());
                have_v = true;
            }
            "--workers" => cfg.workers = num() as usize,
            "--pad" => cfg.pad = num() as usize,
            "--ms" => cfg.ms = num(),
            "--reps" => cfg.reps = num() as usize,
            "--reader" => cfg.reader = num() != 0,
            "--work" => cfg.work = num() as u32,
            _ => usage(),
        }
        i += 2;
    }
    if !have_v || cfg.workers < 1 || cfg.workers > 63 || cfg.reps < 1 {
        usage()
    }
    set_qos();
    let reps: Vec<Rep> = (0..cfg.reps).map(|_| run_once(cfg)).collect();
    let ok = reps.iter().all(|r| r.ok);
    let med = |f: &dyn Fn(&Rep) -> f64| {
        let mut v: Vec<f64> = reps.iter().map(f).collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        (v[v.len() / 2], v[0], v[v.len() - 1])
    };
    let (m, lo, hi) = med(&|r| r.mops);
    let name = NAMES.iter().find(|(_, x)| *x == cfg.v).unwrap().0;
    let pad = if matches!(cfg.v, V::StripeLock | V::StripeOwner) { cfg.pad } else { 0 };
    print!(
        "exp=s1 lang=rust variant={} pad={} workers={} reader={} work={} reps={} ms={} mops_median={:.2} mops_min={:.2} mops_max={:.2}",
        name, pad, cfg.workers, cfg.reader as u8, cfg.work, cfg.reps, cfg.ms, m, lo, hi
    );
    if cfg.reader {
        print!(
            " read_p50_ns={:.0} read_p99_ns={:.0} read_mean_ns={:.1}",
            med(&|r| r.p50).0,
            med(&|r| r.p99).0,
            med(&|r| r.mean).0
        );
    }
    println!(" ok={}", ok as u8);
    std::process::exit(if ok { 0 } else { 1 });
}
