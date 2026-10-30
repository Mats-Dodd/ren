// Rust twin of the single runtime's task switch: tokio 1.x current_thread
// runtime with a LocalSet (spawn_local), mpsc/Notify/Semaphore as a tokio
// programmer writes them. `pingpong_local` adds a hand-written !Send one-slot
// channel (Cell + Waker), the closest Rust analogue of Ren's single runtime.
// A counting global allocator gives allocations and live bytes.
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::future::poll_fn;
use std::rc::Rc;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::task::{Poll, Waker};
use std::time::Instant;
use tokio::sync::{mpsc, Notify, Semaphore};
use tokio::task;

struct Counting;
static ALLOCS: AtomicU64 = AtomicU64::new(0);
static LIVE: AtomicI64 = AtomicI64::new(0);
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Relaxed);
        LIVE.fetch_add(l.size() as i64, Relaxed);
        System.alloc(l)
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        LIVE.fetch_sub(l.size() as i64, Relaxed);
        System.dealloc(p, l)
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, n: usize) -> *mut u8 {
        ALLOCS.fetch_add(1, Relaxed);
        LIVE.fetch_add(n as i64 - l.size() as i64, Relaxed);
        System.realloc(p, l, n)
    }
}
#[global_allocator]
static GA: Counting = Counting;

async fn pingpong(n: u64) -> (u64, u64) {
    let (ptx, mut prx) = mpsc::channel::<u64>(1);
    let (qtx, mut qrx) = mpsc::channel::<u64>(1);
    let b = task::spawn_local(async move {
        for _ in 0..n {
            let v = prx.recv().await.unwrap();
            qtx.send(v + 1).await.unwrap();
        }
    });
    let mut sum = 0;
    for i in 0..n {
        ptx.send(i).await.unwrap();
        sum += qrx.recv().await.unwrap();
    }
    b.await.unwrap();
    (sum, n * (n + 1) / 2)
}

#[derive(Default)]
struct Slot {
    v: Cell<Option<u64>>,
    rx: Cell<Option<Waker>>,
    tx: Cell<Option<Waker>>,
}
async fn put(s: &Slot, v: u64) {
    poll_fn(|cx| {
        if s.v.get().is_some() {
            s.tx.set(Some(cx.waker().clone()));
            Poll::Pending
        } else {
            s.v.set(Some(v));
            if let Some(w) = s.rx.take() {
                w.wake()
            }
            Poll::Ready(())
        }
    })
    .await
}
async fn get(s: &Slot) -> u64 {
    poll_fn(|cx| match s.v.take() {
        Some(v) => {
            if let Some(w) = s.tx.take() {
                w.wake()
            }
            Poll::Ready(v)
        }
        None => {
            s.rx.set(Some(cx.waker().clone()));
            Poll::Pending
        }
    })
    .await
}
async fn pingpong_local(n: u64) -> (u64, u64) {
    let (p, q) = (Rc::new(Slot::default()), Rc::new(Slot::default()));
    let (p2, q2) = (p.clone(), q.clone());
    let b = task::spawn_local(async move {
        for _ in 0..n {
            let v = get(&p2).await;
            put(&q2, v + 1).await;
        }
    });
    let mut sum = 0;
    for i in 0..n {
        put(&p, i).await;
        sum += get(&q).await;
    }
    b.await.unwrap();
    (sum, n * (n + 1) / 2)
}

async fn spawn_join(n: u64) -> (u64, u64) {
    let mut sum = 0;
    for _ in 0..n {
        sum += task::spawn_local(async { 1u64 }).await.unwrap();
    }
    (sum, n)
}

/// Wait until `live` drops to 0 (the scope's end).
async fn scope_end(live: &Cell<u64>, done: &Notify) {
    while live.get() > 0 {
        done.notified().await;
    }
}

async fn spawn_batch(n: u64, max: u64) -> (u64, u64) {
    let sem = Arc::new(Semaphore::new(max as usize));
    let live = Rc::new(Cell::new(0u64));
    let sum = Rc::new(Cell::new(0u64));
    let done = Rc::new(Notify::new());
    for _ in 0..n {
        let permit = sem.clone().acquire_owned().await.unwrap();
        live.set(live.get() + 1);
        let (l, s, d) = (live.clone(), sum.clone(), done.clone());
        task::spawn_local(async move {
            s.set(s.get() + 1);
            drop(permit);
            l.set(l.get() - 1);
            if l.get() == 0 {
                d.notify_one()
            }
        });
    }
    scope_end(&live, &done).await;
    (sum.get(), n)
}

struct Park {
    wake_ns: f64,
    spawn_ns: f64,
    bytes: f64,
}
async fn park(n: u64) -> (Park, u64, u64) {
    let b0 = LIVE.load(Relaxed);
    let t0 = Instant::now();
    let gate = Rc::new(Notify::new());
    let parked = Rc::new(Cell::new(0u64));
    let count = Rc::new(Cell::new(0u64));
    let live = Rc::new(Cell::new(n));
    let done = Rc::new(Notify::new());
    for _ in 0..n {
        let (g, p, c, l, d) = (gate.clone(), parked.clone(), count.clone(), live.clone(), done.clone());
        task::spawn_local(async move {
            let f = g.notified();
            tokio::pin!(f);
            f.as_mut().enable();
            p.set(p.get() + 1);
            f.await;
            c.set(c.get() + 1);
            l.set(l.get() - 1);
            if l.get() == 0 {
                d.notify_one()
            }
        });
    }
    while parked.get() < n {
        task::yield_now().await; // Async.tick
    }
    let spawn_ns = t0.elapsed().as_nanos() as f64 / n as f64;
    let bytes = (LIVE.load(Relaxed) - b0) as f64 / n as f64;
    let t1 = Instant::now();
    gate.notify_waiters();
    scope_end(&live, &done).await;
    let wake_ns = t1.elapsed().as_nanos() as f64 / n as f64;
    (Park { wake_ns, spawn_ns, bytes }, count.get(), n)
}

async fn fanout(n: u64, yield_: bool) -> (u64, u64) {
    let c = Rc::new(Cell::new(0u64));
    let live = Rc::new(Cell::new(n));
    let done = Rc::new(Notify::new());
    for w in 0..n {
        let (c, l, d) = (c.clone(), live.clone(), done.clone());
        task::spawn_local(async move {
            for k in 0..10 {
                c.set(c.get() + w + k);
                if yield_ {
                    task::yield_now().await;
                }
            }
            l.set(l.get() - 1);
            if l.get() == 0 {
                d.notify_one()
            }
        });
    }
    scope_end(&live, &done).await;
    (c.get(), 10 * (n * (n - 1) / 2) + 45 * n)
}

#[derive(Default, Clone, Copy)]
struct Res {
    ns: f64,
    extra: f64,
    objs: f64,
    bytes: f64,
    ok: bool,
}

async fn run_once(bench: &str, n: u64, max: u64) -> Res {
    let a0 = ALLOCS.load(Relaxed);
    let t0 = Instant::now();
    let mut r = Res::default();
    let mut ops = n;
    let (got, want) = match bench {
        "pingpong" => pingpong(n).await,
        "pingpong_local" => pingpong_local(n).await,
        "spawn_join" => spawn_join(n).await,
        "spawn_batch" => spawn_batch(n, max).await,
        "park" => {
            let (p, g, w) = park(n).await;
            r.ns = p.wake_ns;
            r.extra = p.spawn_ns;
            r.bytes = p.bytes;
            (g, w)
        }
        "fanout" | "fanout_yield" => {
            ops = 10 * n;
            fanout(n, bench == "fanout_yield").await
        }
        _ => {
            eprintln!("rust: no bench {bench}");
            std::process::exit(2)
        }
    };
    let total = t0.elapsed().as_nanos() as f64;
    if bench != "park" {
        r.ns = total / ops as f64;
        r.extra = total / n as f64;
    }
    r.objs = (ALLOCS.load(Relaxed) - a0) as f64 / ops as f64;
    r.ok = got == want;
    if !r.ok {
        eprintln!("FAIL rust {bench} got={got} want={want}");
    }
    r
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (mut bench, mut n, mut max, mut reps, mut check) = ("pingpong".to_string(), 1_000_000u64, 64u64, 7usize, false);
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--bench" => { i += 1; bench = args[i].clone() }
            "--n" => { i += 1; n = args[i].parse().unwrap() }
            "--max" => { i += 1; max = args[i].parse().unwrap() }
            "--reps" => { i += 1; reps = args[i].parse().unwrap() }
            "--check" => check = true,
            a => { eprintln!("unknown arg {a}"); std::process::exit(2) }
        }
        i += 1;
    }
    let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
    let local = task::LocalSet::new();
    let code = local.block_on(&rt, async move {
        if check {
            let mut ok = true;
            for b in ["pingpong", "pingpong_local", "spawn_join", "spawn_batch", "park", "fanout", "fanout_yield"] {
                let nn = if b.starts_with('f') { 100 } else { 1000 };
                let r = run_once(b, nn, 64).await;
                println!("CHECK lang=rust_tokio bench={b} n={nn} {}", if r.ok { "ok" } else { "FAIL" });
                ok &= r.ok;
            }
            return if ok { 0 } else { 1 };
        }
        let mut ns = vec![];
        let mut ex = vec![];
        let mut r0 = Res::default();
        let mut ok = true;
        for k in 0..reps {
            let r = run_once(&bench, n, max).await;
            if k == 0 { r0 = r }
            ns.push(r.ns);
            ex.push(r.extra);
            ok &= r.ok;
        }
        let mn = ns.iter().cloned().fold(f64::INFINITY, f64::min);
        let mx = ns.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let rl = ns.iter().map(|v| format!("{v:.2}")).collect::<Vec<_>>().join(",");
        println!(
            "SWITCH lang=rust_tokio bench={bench} n={n} max={max} reps={reps} ns_per_op={:.2} min_ns_per_op={:.2} \
             extra_ns={:.2} heap_allocs_per_op={:.4} sys_allocs_per_op={:.4} bytes_per_task={:.1} \
             footprint_per_task=0 task_header=0 max_ns_per_op={:.2} reps_ns={} check={}",
            median(&mut ns), mn, median(&mut ex), r0.objs, r0.objs, r0.bytes, mx, rl, if ok { "ok" } else { "FAIL" }
        );
        if ok { 0 } else { 1 }
    });
    std::process::exit(code);
}
