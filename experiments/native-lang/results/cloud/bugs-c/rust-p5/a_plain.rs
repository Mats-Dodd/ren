// P5 in safe Rust, standalone: a plain u64 counter shared by thieves.
use std::sync::Arc;
use std::thread;
struct Worker { stolen_from: u64 }
fn main() {
    let w: Arc<Vec<Worker>> = Arc::new((0..4).map(|_| Worker { stolen_from: 0 }).collect());
    let hs: Vec<_> = (0..3).map(|i| { let w = w.clone(); thread::spawn(move || {
        w[0 * i].stolen_from += 1;          // thief: plain += on a shared Worker
    })}).collect();
    for h in hs { h.join().unwrap(); }
    println!("{}", w[0].stolen_from);              // owner: plain read
}
