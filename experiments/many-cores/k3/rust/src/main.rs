//! K3, marking, as Rust gives it. The same actor and operation as
//! ../c/k3.c, written the way a Rust programmer would get each variant:
//!
//! - `shared`: the state is persistent data behind `Arc`, and an update
//!   never changes it in place (Ren's rule: a marked object is never
//!   unique, so no `Arc::make_mut`). Every push copies the subs vector and
//!   every edit copies the rope and one chunk, each element's `Arc`
//!   counted atomically on the copy and again on the old one's drop.
//! - `edge`: `Mutex<State>` whose interior is plain `Vec`s changed in
//!   place, as a Rust `Mutex<T>` needs only `T: Send`. The `Sub` argument
//!   the instance keeps is an `Arc` (it crossed the edge) in both.
//!
//! Allocation is the system allocator (macOS libmalloc), not Ren's
//! per-thread heaps; the C model has those.

use std::cell::UnsafeCell;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

extern "C" {
    fn pthread_set_qos_class_self_np(qos: u32, rel: i32) -> i32;
    fn mach_absolute_time() -> u64;
    fn mach_timebase_info(info: *mut [u32; 2]) -> i32;
}
const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;

#[allow(dead_code)]
struct Sub {
    id: u64,
    name: Arc<str>,
}

enum State {
    Shared {
        subs: Arc<Vec<Arc<Sub>>>,
        text: Arc<Vec<Arc<[u8]>>>,
    },
    Edge {
        subs: Vec<Arc<Sub>>,
        text: Vec<Box<[u8]>>,
    },
}

struct Body {
    state: State,
    ops: u64,
    pushes: u64,
    id_sum: u64,
}

#[derive(Clone, Copy, PartialEq)]
enum LockKind {
    Mutex,
    Spin,
}

/// One handler instance: a lock and its state.
#[repr(align(128))]
struct Instance {
    kind: LockKind,
    m: Mutex<()>,
    spin: AtomicBool,
    body: UnsafeCell<Body>,
}
unsafe impl Sync for Instance {}

enum Held<'a> {
    M(#[allow(dead_code)] MutexGuard<'a, ()>),
    S(&'a AtomicBool),
}
impl Drop for Held<'_> {
    fn drop(&mut self) {
        if let Held::S(s) = self {
            s.store(false, Ordering::Release);
        }
    }
}

impl Instance {
    fn take(&self) -> Held<'_> {
        match self.kind {
            LockKind::Mutex => Held::M(self.m.lock().unwrap()),
            LockKind::Spin => loop {
                if !self.spin.swap(true, Ordering::Acquire) {
                    return Held::S(&self.spin);
                }
                while self.spin.load(Ordering::Relaxed) {
                    std::hint::spin_loop();
                }
            },
        }
    }
}

struct Cfg {
    subs_cap: usize,
    chunks: usize,
    chunk_bytes: usize,
}

fn edit(inst: &Instance, cfg: &Cfg, s: Arc<Sub>, at: usize, delta: u8) {
    let _held = inst.take();
    // SAFETY: the lock is held
    let b = unsafe { &mut *inst.body.get() };
    b.ops += 1;
    b.pushes += 1;
    b.id_sum = b.id_sum.wrapping_add(s.id);
    let (ci, off) = (at / cfg.chunk_bytes, at % cfg.chunk_bytes);
    match &mut b.state {
        State::Shared { subs, text } => {
            let mut v: Vec<Arc<Sub>>;
            if subs.len() == cfg.subs_cap {
                v = Vec::with_capacity(subs.capacity());
            } else {
                let cap = if subs.len() < subs.capacity() {
                    subs.capacity()
                } else {
                    (subs.capacity() * 2).min(cfg.subs_cap)
                };
                v = Vec::with_capacity(cap);
                v.extend(subs.iter().cloned());
            }
            v.push(s);
            *subs = Arc::new(v);
            let mut r: Vec<Arc<[u8]>> = (**text).clone();
            let mut c: Arc<[u8]> = Arc::from(&r[ci][..]);
            let cm = Arc::get_mut(&mut c).unwrap();
            cm[off] = cm[off].wrapping_add(delta);
            r[ci] = c;
            *text = Arc::new(r);
        }
        State::Edge { subs, text } => {
            if subs.len() == cfg.subs_cap {
                subs.clear();
            }
            subs.push(s);
            text[ci][off] = text[ci][off].wrapping_add(delta);
        }
    }
}

fn xs(s: &mut u64) -> u64 {
    let mut x = *s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *s = x;
    x.wrapping_mul(0x2545F4914F6CDD1D)
}

fn init_byte(i: usize, j: usize) -> u8 {
    (i as u32).wrapping_mul(131).wrapping_add((j as u32) * 7) as u8
}

const SAMPLE_EVERY: u64 = 16;
const MAX_SAMPLES: usize = 1 << 20;

struct Out {
    ops: u64,
    id_sum: u64,
    tally: Vec<u8>,
    lat: Vec<u32>,
}

struct Rep {
    ops_s: f64,
    p50: f64,
    p99: f64,
    digest: u64,
    ok: bool,
}

fn one_rep(
    shared: bool,
    kind: LockKind,
    nw: usize,
    ms: u64,
    fixed_ops: u64,
    seed: u64,
    think: u32,
    cfg: &Arc<Cfg>,
    tick_ns: f64,
) -> Rep {
    let text0: Vec<Vec<u8>> = (0..cfg.chunks)
        .map(|i| (0..cfg.chunk_bytes).map(|j| init_byte(i, j)).collect())
        .collect();
    let state = if shared {
        State::Shared {
            subs: Arc::new(Vec::with_capacity(4)),
            text: Arc::new(text0.iter().map(|c| Arc::from(&c[..])).collect()),
        }
    } else {
        State::Edge {
            subs: Vec::with_capacity(4),
            text: text0.iter().map(|c| c.clone().into_boxed_slice()).collect(),
        }
    };
    let inst = Arc::new(Instance {
        kind,
        m: Mutex::new(()),
        spin: AtomicBool::new(false),
        body: UnsafeCell::new(Body { state, ops: 0, pushes: 0, id_sum: 0 }),
    });
    let go = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let ready = Arc::new(AtomicU64::new(0));
    let text_len = cfg.chunks * cfg.chunk_bytes;
    let mut hs = Vec::new();
    for w in 0..nw {
        let (inst, go, stop, ready, cfg) =
            (inst.clone(), go.clone(), stop.clone(), ready.clone(), cfg.clone());
        hs.push(std::thread::spawn(move || {
            unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) };
            let mut rng = seed ^ 0x9E3779B97F4A7C15u64.wrapping_mul(w as u64 + 1);
            if rng == 0 {
                rng = 1;
            }
            let mut out = Out { ops: 0, id_sum: 0, tally: vec![0; text_len], lat: Vec::with_capacity(MAX_SAMPLES) };
            ready.fetch_add(1, Ordering::Release);
            while !go.load(Ordering::Acquire) {
                std::hint::spin_loop();
            }
            let mut seq: u64 = 0;
            loop {
                if if fixed_ops > 0 { seq >= fixed_ops } else { stop.load(Ordering::Relaxed) } {
                    break;
                }
                let r = xs(&mut rng);
                let at = (r % text_len as u64) as usize;
                let delta = ((r >> 40) as u8) | 1;
                let id = ((w as u64 + 1) << 40) | seq;
                let s = Arc::new(Sub { id, name: Arc::from("subscriber-0000") });
                for k in 0..think {
                    std::hint::black_box(k);
                }
                if seq % SAMPLE_EVERY == 0 && out.lat.len() < MAX_SAMPLES {
                    let t0 = unsafe { mach_absolute_time() };
                    edit(&inst, &cfg, s, at, delta);
                    out.lat.push((unsafe { mach_absolute_time() } - t0) as u32);
                } else {
                    edit(&inst, &cfg, s, at, delta);
                }
                out.tally[at] = out.tally[at].wrapping_add(delta);
                out.id_sum = out.id_sum.wrapping_add(id);
                seq += 1;
            }
            out.ops = seq;
            out
        }));
    }
    while ready.load(Ordering::Acquire) < nw as u64 {
        std::thread::yield_now();
    }
    let t0 = Instant::now();
    go.store(true, Ordering::Release);
    if fixed_ops == 0 {
        std::thread::sleep(std::time::Duration::from_millis(ms));
        stop.store(true, Ordering::Relaxed);
    }
    let outs: Vec<Out> = hs.into_iter().map(|h| h.join().unwrap()).collect();
    let el = t0.elapsed().as_secs_f64();

    let ops: u64 = outs.iter().map(|o| o.ops).sum();
    let id_sum = outs.iter().fold(0u64, |a, o| a.wrapping_add(o.id_sum));
    let b = unsafe { &*inst.body.get() };
    let want_len = if ops == 0 { 0 } else { ((ops - 1) % cfg.subs_cap as u64 + 1) as usize };
    let mut ok = b.ops == ops && b.pushes == ops && b.id_sum == id_sum;
    let chunk = |i: usize| -> &[u8] {
        match &b.state {
            State::Shared { text, .. } => &text[i][..],
            State::Edge { text, .. } => &text[i][..],
        }
    };
    let slen = match &b.state {
        State::Shared { subs, .. } => subs.len(),
        State::Edge { subs, .. } => subs.len(),
    };
    ok &= slen == want_len;
    let mut h: u64 = 1469598103934665603;
    for i in 0..cfg.chunks {
        let c = chunk(i);
        for j in 0..cfg.chunk_bytes {
            let mut want = init_byte(i, j);
            for o in &outs {
                want = want.wrapping_add(o.tally[i * cfg.chunk_bytes + j]);
            }
            ok &= c[j] == want;
            h = (h ^ c[j] as u64).wrapping_mul(1099511628211);
        }
    }
    h = (h ^ ops).wrapping_mul(1099511628211);
    h = (h ^ id_sum).wrapping_mul(1099511628211);
    let mut lat: Vec<u32> = outs.iter().flat_map(|o| o.lat.iter().copied()).collect();
    lat.sort_unstable();
    let pick = |q: usize| if lat.is_empty() { 0.0 } else { lat[lat.len() * q / 100] as f64 * tick_ns };
    Rep { ops_s: ops as f64 / el, p50: pick(50), p99: pick(99), digest: h, ok }
}

fn usage() -> ! {
    eprintln!("k3 --variant shared|edge [--workers N] [--ms M | --ops N] [--reps R] [--lock mutex|spin] [--subs-cap 32] [--chunks 16] [--chunk-bytes 64] [--think 0] [--seed S]");
    std::process::exit(2)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (mut variant, mut nw, mut ms, mut fixed, mut reps) = (String::new(), 8usize, 1000u64, 0u64, 5usize);
    let (mut subs_cap, mut chunks, mut chunk_bytes, mut think, mut seed) = (32usize, 16usize, 64usize, 0u32, 42u64);
    let mut kind = LockKind::Mutex;
    let mut i = 1;
    while i < a.len() {
        let v = a.get(i + 1).cloned().unwrap_or_else(|| usage());
        let n = || v.parse::<u64>().unwrap_or_else(|_| usage());
        match a[i].as_str() {
            "--variant" => variant = v.clone(),
            "--workers" => nw = n() as usize,
            "--ms" => ms = n(),
            "--ops" => fixed = n(),
            "--reps" => reps = n() as usize,
            "--subs-cap" => subs_cap = n() as usize,
            "--chunks" => chunks = n() as usize,
            "--chunk-bytes" => chunk_bytes = n() as usize,
            "--think" => think = n() as u32,
            "--seed" => seed = n(),
            "--lock" => kind = if v == "spin" { LockKind::Spin } else { LockKind::Mutex },
            _ => usage(),
        }
        i += 2;
    }
    if (variant != "shared" && variant != "edge") || nw < 1 || reps < 1 || subs_cap < 4 || chunks < 1 || chunk_bytes < 1 {
        usage();
    }
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) };
    let mut tb = [0u32; 2];
    unsafe { mach_timebase_info(&mut tb) };
    let tick_ns = tb[0] as f64 / tb[1] as f64;
    let cfg = Arc::new(Cfg { subs_cap, chunks, chunk_bytes });
    let shared = variant == "shared";
    let mut t = Vec::new();
    let mut p50 = Vec::new();
    let mut p99 = Vec::new();
    let mut ok = true;
    let mut digest = 0;
    for r in 0..reps {
        let rr = one_rep(shared, kind, nw, ms, fixed, seed, think, &cfg, tick_ns);
        if r == 0 {
            digest = rr.digest;
        } else if fixed > 0 && rr.digest != digest {
            ok = false;
        }
        ok &= rr.ok;
        t.push(rr.ops_s);
        p50.push(rr.p50);
        p99.push(rr.p99);
    }
    let srt = |v: &mut Vec<f64>| v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    srt(&mut t);
    srt(&mut p50);
    srt(&mut p99);
    println!(
        "k3 impl=rust variant={} lock={} workers={} reps={} {}={} subs_cap={} chunks={} chunk_bytes={} think={} ops_s_median={:.0} ops_s_min={:.0} ops_s_max={:.0} p50_ns={:.0} p99_ns={:.0} digest={:016x} ok={}",
        variant,
        if kind == LockKind::Spin { "spin" } else { "mutex" },
        nw, reps,
        if fixed > 0 { "ops_per_worker" } else { "ms" },
        if fixed > 0 { fixed } else { ms },
        subs_cap, chunks, chunk_bytes, think,
        t[reps / 2], t[0], t[reps - 1], p50[reps / 2], p99[reps / 2],
        if fixed > 0 { digest } else { 0 },
        ok as u8
    );
    std::process::exit(if ok { 0 } else { 1 });
}
