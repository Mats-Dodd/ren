// Fannkuch-redux, from the Benchmarks Game, on one thread, in the order
// the sequential versions go through the permutations.

use std::env;

fn main() {
    let n: usize = env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(11);
    let mut perm1: Vec<usize> = (0..n).collect();
    let mut perm = vec![0; n];
    let mut count = vec![0; n];
    let mut max_flips = 0;
    let mut checksum: i64 = 0;
    let mut perm_count = 0;
    let mut r = n;
    'outer: loop {
        while r != 1 {
            count[r - 1] = r;
            r -= 1;
        }
        perm.copy_from_slice(&perm1);
        let mut flips = 0;
        let mut k = perm[0];
        while k != 0 {
            perm[..=k].reverse();
            flips += 1;
            k = perm[0];
        }
        max_flips = max_flips.max(flips);
        checksum += if perm_count % 2 == 0 { flips } else { -flips };
        // the next permutation: rotate the first r + 1 elements, until a
        // count is left
        loop {
            if r == n {
                break 'outer;
            }
            perm1[..=r].rotate_left(1);
            count[r] -= 1;
            if count[r] > 0 {
                break;
            }
            r += 1;
        }
        perm_count += 1;
    }
    println!("{}", checksum);
    println!("Pfannkuchen({}) = {}", n, max_flips);
}
