//! The journal wire (SPEC §B.7): little-endian, field by field, never a
//! struct copy. Shared by the core (CALL, DELIVER, ...) and the drivers
//! (J_PULL, J_REPLY, ...).
use crate::sys::*;
use alloc::vec::Vec;

pub struct Enc(pub Vec<u8>);

impl Enc {
    #[inline]
    pub fn new() -> Enc {
        Enc(Vec::with_capacity(96))
    }
    #[inline]
    pub fn u16(&mut self, v: u16) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    #[inline]
    pub fn u32(&mut self, v: u32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    #[inline]
    pub fn i32(&mut self, v: i32) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    #[inline]
    pub fn u64(&mut self, v: u64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    #[inline]
    pub fn i64(&mut self, v: i64) -> &mut Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    #[inline]
    pub fn bytes(&mut self, b: &[u8]) -> &mut Self {
        self.0.extend_from_slice(b);
        self
    }
    /// A ren_io_result, field by field.
    pub fn result(&mut self, r: &ren_io_result) -> &mut Self {
        self.i64(r.res).i64(r.a).i64(r.b)
    }
}

/// The 24-byte entry header followed by the payload.
pub fn entry(kind: u32, worker: i32, step: u64, payload: &[u8]) -> Vec<u8> {
    let mut e = Enc(Vec::with_capacity(REN_JENT_BYTES as usize + payload.len()));
    e.u32(kind).u32(payload.len() as u32).i32(worker).u32(0).u64(step).bytes(payload);
    e.0
}

pub fn fnv1a(b: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for &x in b {
        h ^= x as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// The wire call, then for REN_CALL the body (buf written as 0) and
/// out_hash (FNV-1a 64 of the WRITE bytes, else 0). CALL and J_PULL.
///
/// # Safety
/// For a REN_CALL, `k.body` points at a live ren_io_body and, for WRITE,
/// its `buf` at `len` readable bytes.
pub unsafe fn call(e: &mut Enc, k: &ren_call) {
    e.u64(k.id).u16(k.worker).u16(k.kind).u32(k.lane).u32(k.task).u32(k.op).u32(k.len);
    let mut h = 0u64;
    if k.kind as u32 == REN_CALL && !k.body.is_null() {
        let b = &*(k.body as *const ren_io_body);
        e.i64(b.fd).u64(b.len).u64(0).i64(b.arg);
        if k.op == REN_OP_WRITE && b.len > 0 {
            h = fnv1a(core::slice::from_raw_parts(b.buf as usize as *const u8, b.len as usize));
        } else if k.op == REN_OP_WRITE {
            h = fnv1a(&[]);
        }
    }
    e.u64(h);
}

/// DELIVER and J_REPLY share this prefix: u64 id, u32 state, u32 len, the
/// result, u32 in_len, the inout bytes.
pub fn reply_body(e: &mut Enc, id: u64, state: u32, r: &ren_io_result, inout: &[u8]) {
    e.u64(id).u32(state).u32(core::mem::size_of::<ren_io_result>() as u32).result(r);
    e.u32(inout.len() as u32).bytes(inout);
}
