// Layer 3: a stream of length-prefixed records, little-endian, each a
// u32 length, then a kind (u8), an id (LEB128), a time (i64), a value
// (i32) and a name (a u8 length and its bytes), written into a Vec<u8>
// and read back through a cursor over a &[u8], whose reads fail with
// `Short` when the input runs out, as Ren's do. Arithmetic is i64, as
// Ren's is, wrapping where Ren's does.

use std::convert::{TryFrom, TryInto};
use std::env;

#[derive(Debug)]
#[allow(dead_code)]
enum FormatError {
    Short { at: usize, need: usize },
    Malformed { at: usize, why: &'static str },
}

struct Cursor<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn left(&self) -> usize {
        self.b.len() - self.pos
    }
    fn take<const N: usize>(&mut self) -> Result<[u8; N], FormatError> {
        match self.b.get(self.pos..self.pos + N) {
            Some(s) => {
                self.pos += N;
                Ok(s.try_into().unwrap())
            }
            None => Err(FormatError::Short { at: self.pos, need: N - self.left() }),
        }
    }
    fn u8(&mut self) -> Result<i64, FormatError> {
        Ok(self.take::<1>()?[0] as i64)
    }
    fn u32_le(&mut self) -> Result<i64, FormatError> {
        Ok(u32::from_le_bytes(self.take::<4>()?) as i64)
    }
    fn i32_le(&mut self) -> Result<i64, FormatError> {
        Ok(i32::from_le_bytes(self.take::<4>()?) as i64)
    }
    fn i64_le(&mut self) -> Result<i64, FormatError> {
        Ok(i64::from_le_bytes(self.take::<8>()?))
    }
    fn varuint(&mut self) -> Result<i64, FormatError> {
        let start = self.pos;
        let mut i = start;
        let mut z: u64 = 0;
        let mut shift = 0;
        loop {
            let v = match self.b.get(i) {
                Some(&v) => v,
                None => return Err(FormatError::Short { at: start, need: 1 }),
            };
            if shift == 63 && v > 1 {
                return Err(FormatError::Malformed { at: start, why: "too large" });
            }
            z |= ((v & 127) as u64) << shift;
            shift += 7;
            i += 1;
            if v < 128 {
                break;
            }
        }
        if z >= 1 << 63 {
            return Err(FormatError::Malformed { at: start, why: "too large" });
        }
        self.pos = i;
        Ok(z as i64)
    }
    fn skip(&mut self, n: usize) -> Result<(), FormatError> {
        if self.left() < n {
            return Err(FormatError::Short { at: self.pos, need: n - self.left() });
        }
        self.pos += n;
        Ok(())
    }
}

fn id_of(i: i64) -> i64 {
    let bits = 7 * (1 + i % 6);
    i * 2_654_435_761 % (1i64 << bits)
}

fn varuint_size(x: i64) -> i64 {
    let mut n = 1;
    let mut z = x as u64;
    while z >= 128 {
        z >>= 7;
        n += 1;
    }
    n
}

fn body_size(i: i64) -> i64 {
    1 + varuint_size(id_of(i)) + 8 + 4 + 1 + i % 13
}

fn input(n: i64) -> Vec<u8> {
    let mut b = Vec::new();
    for i in 0..n {
        b.extend_from_slice(&u32::try_from(body_size(i)).unwrap().to_le_bytes());
        b.push((i % 7) as u8);
        let mut z = id_of(i) as u64;
        while z >= 128 {
            b.push((z as u8) | 128);
            z >>= 7;
        }
        b.push(z as u8);
        b.extend_from_slice(&(i * 1_000_003).to_le_bytes());
        b.extend_from_slice(&i32::try_from(i % 1000 - 500).unwrap().to_le_bytes());
        let name = i % 13;
        b.push(name as u8);
        for j in 0..name {
            b.push(((i + j) % 256) as u8);
        }
    }
    b
}

fn decode(b: &[u8]) -> Result<i64, FormatError> {
    let mut c = Cursor { b, pos: 0 };
    let mut h: i64 = 0;
    while c.left() > 0 {
        let len = c.u32_le()? as usize;
        let start = c.pos;
        let kind = c.u8()?;
        let id = c.varuint()?;
        let time = c.i64_le()?;
        let value = c.i32_le()?;
        let name = c.u8()?;
        let mut s: i64 = 0;
        for _ in 0..name {
            s += c.u8()?;
        }
        c.skip(start + len - c.pos)?;
        h = h.wrapping_mul(31).wrapping_add(kind + id % 1000 + value + s) ^ time;
    }
    Ok(h)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let n: i64 = args.get(1).map_or(1_000_000, |s| s.parse().unwrap());
    let rounds: i64 = args.get(2).map_or(20, |s| s.parse().unwrap());
    let b = input(n);
    let mut x: i64 = 0;
    for _ in 0..rounds {
        match decode(&b) {
            Ok(h) => x = x.wrapping_add(h),
            Err(_) => x = -1,
        }
    }
    println!("{}", b.len());
    println!("{}", x);
}
