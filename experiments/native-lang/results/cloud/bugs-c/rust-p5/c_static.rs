use std::thread;
static mut STOLEN_FROM: [u64; 4] = [0; 4];
fn main() {
    let hs: Vec<_> = (0..3).map(|i| thread::spawn(move || {
        STOLEN_FROM[0 * i] += 1;
    })).collect();
    for h in hs { h.join().unwrap(); }
    println!("{}", STOLEN_FROM[0]);
}
