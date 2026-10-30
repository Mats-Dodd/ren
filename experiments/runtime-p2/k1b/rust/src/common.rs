// Mirrors c/common.h bit for bit, so the simulator's traces and counts agree with C.
// Copied from phase 1's k1k2/rust/src/common.rs, plus the K1b workloads.
#![allow(dead_code)]

pub fn splitmix64(s: &mut u64) -> u64 {
    *s = s.wrapping_add(0x9e3779b97f4a7c15);
    let mut z = *s;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
    z ^ (z >> 31)
}

#[inline(always)]
pub fn mix64(mut k: u64) -> u64 {
    k ^= k >> 33;
    k = k.wrapping_mul(0xff51afd7ed558ccd);
    k ^= k >> 33;
    k = k.wrapping_mul(0xc4ceb9fe1a85ec53);
    k ^= k >> 33;
    k
}

#[inline(always)]
pub fn part_of(h: u64, parts: u32) -> u32 {
    ((h >> 32) % parts as u64) as u32
}

pub fn uniform_key(x: u64, n: u32) -> u64 {
    1 + (((x >> 32) * n as u64) >> 32)
}

pub struct Zipf {
    pub cdf: Vec<f64>,
}

impl Zipf {
    pub fn new(n: u32, s: f64) -> Zipf {
        let mut cdf = Vec::with_capacity(n as usize);
        let mut sum = 0.0f64;
        for i in 1..=n {
            sum += (i as f64).powf(-s);
            cdf.push(sum);
        }
        for c in cdf.iter_mut() {
            *c /= sum;
        }
        cdf[n as usize - 1] = 1.0;
        Zipf { cdf }
    }
    pub fn key(&self, x: u64) -> u64 {
        let u = (x >> 11) as f64 * (1.0 / (1u64 << 53) as f64);
        let (mut lo, mut hi) = (0usize, self.cdf.len() - 1);
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if self.cdf[mid] >= u {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        lo as u64 + 1
    }
}

pub fn pow2_at_least(x: u32) -> u32 {
    let mut p = 4;
    while p < x {
        p <<= 1;
    }
    p
}

pub fn parse_list<T: std::str::FromStr>(s: &str) -> Vec<T> {
    s.split(',').filter(|x| !x.is_empty()).map(|x| x.parse().ok().expect("bad number")).collect()
}

/// Arguments as (--flag, value) pairs.
pub fn args() -> Vec<(String, String)> {
    let a: Vec<String> = std::env::args().skip(1).collect();
    a.chunks(2).map(|c| (c[0].clone(), c.get(1).cloned().unwrap_or_default())).collect()
}

// ---- K1b workloads: see c/common.h --------------------------------------------
pub const D_UNIFORM: usize = 0;
pub const D_ZIPF99: usize = 1;
pub const D_ZIPF70: usize = 2;
pub const D_SCAN: usize = 3;
pub const DIST_NAMES: [&str; 4] = ["uniform", "zipf99", "zipf70", "scan"];
pub const SCAN_BASE: u32 = 1 << 30;

pub fn dist_of(s: &str) -> usize {
    DIST_NAMES.iter().position(|d| *d == s).unwrap_or_else(|| panic!("unknown dist {}", s))
}

pub struct Workload {
    pub dist: usize,
    pub u: u32,
    pub l: u32,
    pub z: Option<Zipf>,
}

impl Workload {
    pub fn new(dist: usize, u: u32, max: u32) -> Workload {
        let z = if dist != D_UNIFORM { Some(Zipf::new(u, if dist == D_ZIPF70 { 0.7 } else { 0.99 })) } else { None };
        Workload { dist, u, l: max / 2 * 3, z }
    }
    #[inline]
    pub fn next(&self, seed: &mut u64, cursor: &mut u32) -> u32 {
        let x = splitmix64(seed);
        match self.dist {
            D_UNIFORM => uniform_key(x, self.u) as u32,
            D_SCAN if x & 1 == 1 => {
                let c = *cursor;
                *cursor = if c + 1 == self.l { 0 } else { c + 1 };
                SCAN_BASE + c
            }
            _ => self.z.as_ref().unwrap().key(x) as u32,
        }
    }
}

pub const FNV0: u64 = 0xcbf29ce484222325;
pub fn fnv_add(mut h: u64, v: u64) -> u64 {
    for i in 0..8 {
        h ^= (v >> (8 * i)) & 0xff;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

pub fn default_parts(max: u32) -> u32 {
    let mut p = 1;
    while p * 2 <= max / 1024 && p < 64 {
        p *= 2;
    }
    p
}

/// The universe from a factor string, as C's (uint32_t)(atof(uf) * max + 0.5).
pub fn universe(uf: &str, max: u32) -> u32 {
    (uf.parse::<f64>().unwrap() * max as f64 + 0.5) as u32
}
