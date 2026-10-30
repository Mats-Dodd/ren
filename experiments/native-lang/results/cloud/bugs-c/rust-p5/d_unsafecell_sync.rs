// What it takes: UnsafeCell + an `unsafe impl Sync` (the slice's Core already has one).
use std::cell::UnsafeCell;
use std::sync::Arc;
use std::thread;
struct Worker { stolen_from: UnsafeCell<u64> }
unsafe impl Sync for Worker {}
fn main() {
    let w: Arc<Vec<Worker>> = Arc::new((0..4).map(|_| Worker { stolen_from: UnsafeCell::new(0) }).collect());
    let hs: Vec<_> = (0..3).map(|i| { let w = w.clone(); thread::spawn(move || {
        unsafe { *w[0 * i].stolen_from.get() += 1; }
    })}).collect();
    for h in hs { h.join().unwrap(); }
    println!("{}", unsafe { *w[0].stolen_from.get() });
}
