// The Rust twin of `diff.exe bench` (compiler.md, "Bytes stage, part two",
// "Step 1, as built"): std's from_utf8 on a text `diff.exe dump` wrote,
// repeated to 256 MiB, in GB/s.
use std::hint::black_box;
use std::time::Instant;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let p = std::fs::read(&a[1]).unwrap();
    let reps = (256usize << 20) / p.len();
    let mut ok = 0;
    let t = Instant::now();
    for _ in 0..reps {
        ok += std::str::from_utf8(black_box(&p)).is_ok() as usize;
    }
    let s = t.elapsed().as_secs_f64();
    println!("{} rust {:.3} GB/s (ok {})", a[1], (p.len() * reps) as f64 / s * 1e-9, ok);
}
