// main.rs with FxHash in std's SipHash's place (the bytes stage, part
// two, scope 7: Rust as it's written for speed), the rest the same:
// accounts kept in a map keyed by i64 id and one keyed by name, each
// round built, looked up, a third removed and iterated in insertion
// order, into a checksum. Each map is std's HashMap, hashed with FxHash,
// rustc's hasher (rustc-hash 1's, written here; unseeded, where Ren's
// is seeded), of a key to its entry's place in a Vec of entries, in
// insertion order, a removed one left a hole until a third are holes,
// then compacted: indexmap's shape, which Ren's map has (ren_rt.h,
// [ren_map]), without a crate. A name is an Rc<str>, counted, as a Ren
// `Str` is. Arithmetic is i64, wrapping where Ren's does.

use std::collections::HashMap;
use std::convert::TryInto;
use std::env;
use std::hash::{BuildHasherDefault, Hash, Hasher};
use std::rc::Rc;

// FxHash: a rotate, an xor and a multiply a word
#[derive(Default)]
struct Fx(u64);

impl Fx {
    fn add(&mut self, w: u64) {
        self.0 = (self.0.rotate_left(5) ^ w).wrapping_mul(0x517cc1b727220a95);
    }
}

impl Hasher for Fx {
    fn write(&mut self, bytes: &[u8]) {
        let mut c = bytes.chunks_exact(8);
        for w in &mut c {
            self.add(u64::from_le_bytes(w.try_into().unwrap()));
        }
        let mut r = c.remainder();
        if r.len() >= 4 {
            self.add(u32::from_le_bytes(r[..4].try_into().unwrap()) as u64);
            r = &r[4..];
        }
        if r.len() >= 2 {
            self.add(u16::from_le_bytes(r[..2].try_into().unwrap()) as u64);
            r = &r[2..];
        }
        if let Some(&b) = r.first() {
            self.add(b as u64);
        }
    }
    fn write_u8(&mut self, x: u8) {
        self.add(x as u64);
    }
    fn write_u64(&mut self, x: u64) {
        self.add(x);
    }
    fn write_i64(&mut self, x: i64) {
        self.add(x as u64);
    }
    fn write_usize(&mut self, x: usize) {
        self.add(x as u64);
    }
    fn finish(&self) -> u64 {
        self.0
    }
}

type FxMap<K, V> = HashMap<K, V, BuildHasherDefault<Fx>>;

struct Ordered<K, V> {
    index: FxMap<K, usize>,
    entries: Vec<Option<(K, V)>>,
    len: usize,
}

impl<K: Hash + Eq + Clone, V> Ordered<K, V> {
    fn new() -> Self {
        Ordered { index: FxMap::default(), entries: Vec::new(), len: 0 }
    }
    // a key that's there keeps its place and gets the value
    fn set(&mut self, k: K, v: V) {
        match self.index.get(&k) {
            Some(&i) => self.entries[i].as_mut().unwrap().1 = v,
            None => {
                self.index.insert(k.clone(), self.entries.len());
                self.entries.push(Some((k, v)));
                self.len += 1;
            }
        }
    }
    fn get(&self, k: &K) -> Option<&V> {
        self.index.get(k).map(|&i| &self.entries[i].as_ref().unwrap().1)
    }
    fn remove(&mut self, k: &K) {
        if let Some(i) = self.index.remove(k) {
            self.entries[i] = None;
            self.len -= 1;
            if (self.entries.len() - self.len) * 3 >= self.entries.len() && self.entries.len() >= 8 {
                self.compact();
            }
        }
    }
    fn compact(&mut self) {
        self.entries.retain(|e| e.is_some());
        for (i, e) in self.entries.iter().enumerate() {
            *self.index.get_mut(&e.as_ref().unwrap().0).unwrap() = i;
        }
    }
    fn iter(&self) -> impl Iterator<Item = &(K, V)> {
        self.entries.iter().filter_map(|e| e.as_ref())
    }
}

struct Account {
    id: i64,
    name: Rc<str>,
    balance: i64,
}

fn id_of(i: i64, n: i64) -> i64 {
    i * 2_654_435_761 % (2 * n)
}

fn names(n: i64) -> Vec<Rc<str>> {
    (0..n).map(|i| Rc::from(format!("user-{}", i * 7_919 % n))).collect()
}

fn round(names: &[Rc<str>], n: i64) -> i64 {
    let mut by_id: Ordered<i64, Account> = Ordered::new();
    let mut by_name: Ordered<Rc<str>, i64> = Ordered::new();
    for i in 0..n {
        let id = id_of(i, n);
        let name = names[i as usize].clone();
        by_id.set(id, Account { id, name: name.clone(), balance: i % 1000 });
        by_name.set(name, id);
    }
    let mut h: i64 = 0;
    for i in 0..n {
        match by_id.get(&(i * 3)) {
            Some(a) => h += a.balance,
            None => h += 1,
        }
        match by_name.get(&names[(i * 31 % n) as usize]) {
            Some(&id) => h = h.wrapping_add(id),
            None => h -= 1,
        }
    }
    for i in 0..n {
        if i % 3 == 0 {
            by_id.remove(&id_of(i, n));
            by_name.remove(&names[i as usize]);
        }
    }
    for (k, a) in by_id.iter() {
        debug_assert_eq!(*k, a.id);
        h = h.wrapping_mul(31).wrapping_add(k + a.balance + a.name.len() as i64);
    }
    for (s, id) in by_name.iter() {
        h = h.wrapping_mul(17).wrapping_add(id + s.len() as i64);
    }
    h.wrapping_add(by_id.len as i64 * 1_000 + by_name.len as i64)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let n: i64 = args.get(1).map_or(200_000, |s| s.parse().unwrap());
    let rounds: i64 = args.get(2).map_or(20, |s| s.parse().unwrap());
    let ns = names(n);
    let mut x: i64 = 0;
    for _ in 0..rounds {
        x = x.wrapping_add(round(&ns, n));
    }
    println!("{}", ns.len());
    println!("{}", x);
}
