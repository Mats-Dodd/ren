use std::cell::Cell;
use std::sync::Arc;
use std::thread;
struct Worker { stolen_from: Cell<u64> }
fn main() {
    let w: Arc<Vec<Worker>> = Arc::new((0..4).map(|_| Worker { stolen_from: Cell::new(0) }).collect());
    let hs: Vec<_> = (0..3).map(|i| { let w = w.clone(); thread::spawn(move || {
        let c = &w[0 * i].stolen_from; c.set(c.get() + 1);
    })}).collect();
    for h in hs { h.join().unwrap(); }
    println!("{}", w[0].stolen_from.get());
}
