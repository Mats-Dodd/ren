//! Replay (SPEC §D.1) and fuzz (SPEC §D.4): one thread drives every
//! worker, no OS calls. Replay is a host whose journal callback compares
//! the replaying core's entries with the recording, byte for byte; the
//! fuzz driver is the same seat fed random bytes, with oracles.
use super::{res1, Drv, CANCELLED_RES};
use crate::journal::{self, Enc};
use crate::sys::*;
use alloc::collections::BTreeMap;
use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::{Cell, UnsafeCell};
use core::ffi::{c_char, c_void};
use core::mem::{size_of, zeroed};

const JENT: usize = REN_JENT_BYTES as usize;
const RES_BYTES: usize = size_of::<ren_io_result>();

fn rd32(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}
fn rd64(b: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(b[at..at + 8].try_into().unwrap())
}
fn rd_result(b: &[u8], at: usize) -> ren_io_result {
    ren_io_result { res: rd64(b, at) as i64, a: rd64(b, at + 8) as i64, b: rd64(b, at + 16) as i64 }
}

/// A view of one journal entry: (kind, worker, payload range, next position).
fn entry_at(b: &[u8], pos: usize) -> Option<(u32, i32, usize, usize)> {
    if pos + JENT > b.len() {
        return None;
    }
    let kind = rd32(b, pos);
    let len = rd32(b, pos + 4) as usize;
    let w = rd32(b, pos + 8) as i32;
    if pos + JENT + len > b.len() {
        return None;
    }
    Some((kind, w, pos + JENT, pos + JENT + len))
}

fn cstr(s: String) -> Vec<u8> {
    let mut v = s.into_bytes();
    v.push(0);
    v
}

pub unsafe extern "C" fn h_wake_nop(_hp: *mut c_void, _w: i32) {}

// ================= replay =================
pub struct Replay {
    input: &'static [u8],
    workers: i32,
    core_pos: Cell<usize>,
    entry_no: Cell<usize>,
    diverged: Cell<i32>,
    err: UnsafeCell<Vec<u8>>,
    ans: UnsafeCell<ren_io_result>,
    kept: UnsafeCell<BTreeMap<u64, ren_call>>,
}

impl Replay {
    pub unsafe fn new(o: &ren_drv_opts) -> Replay {
        let input: &'static [u8] =
            if o.input.is_null() { &[] } else { core::slice::from_raw_parts(o.input, o.input_len) };
        Replay {
            input,
            workers: o.workers,
            core_pos: Cell::new(0),
            entry_no: Cell::new(0),
            diverged: Cell::new(0),
            err: UnsafeCell::new(cstr(String::new())),
            ans: UnsafeCell::new(super::RES0),
            kept: UnsafeCell::new(BTreeMap::new()),
        }
    }
    pub fn diverged(&self) -> bool {
        self.diverged.get() != 0
    }
    pub fn err_ptr(&self) -> *const c_char {
        // SAFETY: single-threaded driver; the buffer lives as long as the driver.
        unsafe { (*self.err.get()).as_ptr() as *const c_char }
    }
    pub fn result(&self) -> i32 {
        self.diverged.get()
    }
    fn diverge(&self, what: &str) {
        if self.diverged.get() != 0 {
            return;
        }
        let n = core::cmp::max(self.entry_no.get(), 1);
        self.diverged.set(n as i32);
        // SAFETY: single-threaded; no reference to err is held.
        // SPEC §D.1: above one worker, arrival interleaving is not recorded.
        let sched = if self.workers > 1 { "schedule divergence (workers > 1; replay is promised at 1): " } else { "" };
        unsafe { *self.err.get() = cstr(format!("replay diverged at entry {n}: {sched}{what}")) };
    }
    /// The next recorded core entry (kind < 16) at or after core_pos.
    fn next_core(&self) -> Option<(usize, usize)> {
        let mut pos = self.core_pos.get();
        while let Some((kind, _, _, next)) = entry_at(self.input, pos) {
            if kind < 16 {
                return Some((pos, next));
            }
            pos = next;
        }
        None
    }

    unsafe fn journal(&self, e: &[u8]) {
        if self.diverged() {
            return;
        }
        let Some((pos, next)) = self.next_core() else {
            self.diverge("late end: the replaying core wrote more than the recording");
            return;
        };
        let rec = &self.input[pos..next];
        if rec != e {
            let rk = rd32(rec, 0);
            let pk = if e.len() >= 4 { rd32(e, 0) } else { 0 };
            let what = if rk != pk {
                format!("core entry kind differs (recorded {rk}, replayed {pk})")
            } else {
                let field = match rk {
                    REN_J_CALL => "a call argument differs",
                    REN_J_DELIVER => "a delivery differs (point, result or inout bytes)",
                    REN_J_CANCEL => "a cancel differs",
                    REN_J_RELEASE => "a release differs",
                    REN_J_END => "the end differs",
                    REN_J_HEADER => "the header differs",
                    _ => "an entry differs",
                };
                let step = |b: &[u8]| if b.len() >= 24 { rd64(b, 16) } else { 0 };
                format!("{field} (kind {rk}; recorded step {}, replayed step {})", step(rec), step(e))
            };
            self.diverge(&what);
        }
        self.core_pos.set(next);
    }

    unsafe fn answer(&self, call: &ren_call, out: &mut ren_reply_t) -> bool {
        // Inline only if the recorded DELIVER for this id follows its CALL
        // directly, before any driver action (RUN, PULL, DRAINED, REPLY).
        let mut pos = self.core_pos.get();
        while let Some((kind, _, pl, next)) = entry_at(self.input, pos) {
            match kind {
                REN_J_DELIVER if rd64(self.input, pl) == call.id => {
                    *self.ans.get() = rd_result(self.input, pl + 16);
                    *out = ren_reply_t {
                        id: call.id,
                        state: rd32(self.input, pl + 8),
                        len: RES_BYTES as u32,
                        body: self.ans.get() as *const c_void,
                    };
                    return true;
                }
                REN_J_RUN | REN_J_PULL | REN_J_DRAINED | REN_J_REPLY => return false,
                k if k < 16 => return false,
                _ => pos = next,
            }
        }
        false
    }

    pub unsafe fn run(&self, d: &Drv, c: *mut ren_core) -> i32 {
        let inp = self.input;
        let mut pos = 0usize;
        while self.diverged.get() == 0 {
            let Some((kind, w, pl, next)) = entry_at(inp, pos) else { break };
            self.entry_no.set(self.entry_no.get() + 1);
            let p = &inp[pl..next];
            if (16..=20).contains(&kind) && kind != REN_J_DRV && (w < 0 || w >= d.o.workers) {
                self.diverge("a driver entry names a worker this run does not have");
                break;
            }
            match kind {
                REN_J_DRV => {
                    if p.len() >= 8 && rd32(p, 4) as i32 != d.o.workers {
                        self.diverge("the recording has a different number of workers");
                    }
                }
                REN_J_RUN if p.len() < 8 => self.diverge("a malformed J_RUN entry"),
                REN_J_REPLY if p.len() < 16 + RES_BYTES + 8 || p.len() < 24 + rd32(p, 12) as usize
                    || p.len() != 24 + rd32(p, 12) as usize + rd32(p, 16 + rd32(p, 12) as usize) as usize =>
                {
                    self.diverge("a malformed J_REPLY entry")
                }
                REN_J_RUN => {
                    let (steps, ret) = (rd32(p, 0), rd32(p, 4) as i32);
                    if ren_run(c, w, steps) != ret {
                        self.diverge("ren_run returned a different result");
                    }
                }
                REN_J_PULL => {
                    let mut call: ren_call = zeroed();
                    if !ren_poll_call(c, w, &mut call) {
                        self.diverge("ren_poll_call returned false; the recording pulled a call");
                    } else {
                        let mut e = Enc::new();
                        journal::call(&mut e, &call);
                        if e.0 != p {
                            self.diverge("the pulled call differs (a call argument)");
                        }
                        if call.kind as u32 == REN_CALL {
                            (*self.kept.get()).insert(call.id, call);
                        }
                    }
                }
                REN_J_DRAINED => {
                    let mut call: ren_call = zeroed();
                    if ren_poll_call(c, w, &mut call) {
                        self.diverge("ren_poll_call returned a call; the recording drained");
                    }
                }
                REN_J_REPLY => {
                    let id = rd64(p, 0);
                    let st = rd32(p, 8);
                    let blen = rd32(p, 12) as usize;
                    let res = rd_result(p, 16);
                    let in_len = rd32(p, 16 + blen) as usize;
                    let inb = &p[20 + blen..20 + blen + in_len];
                    let ret = rd32(p, 20 + blen + in_len) as i32;
                    let kept = (*self.kept.get()).remove(&id);
                    if in_len > 0 {
                        match kept {
                            None => {
                                self.diverge("reply bytes for a call never pulled");
                                break;
                            }
                            Some(k) => {
                                let b = &*(k.body as *const ren_io_body);
                                if (in_len as u64) > b.len {
                                    self.diverge("reply bytes longer than the call's buffer");
                                    break;
                                }
                                // the driver owns the buffer until the final reply
                                core::ptr::copy_nonoverlapping(inb.as_ptr(), b.buf as usize as *mut u8, in_len);
                            }
                        }
                    }
                    let rp = ren_reply_t {
                        id,
                        state: st,
                        len: RES_BYTES as u32,
                        body: &res as *const ren_io_result as *const c_void,
                    };
                    if ren_reply(c, &rp) != ret {
                        self.diverge("ren_reply returned a different result");
                    }
                }
                _ => {} // core entries: compared through the journal callback
            }
            pos = next;
        }
        if self.diverged.get() == 0 {
            if pos < inp.len() {
                self.entry_no.set(self.entry_no.get() + 1);
                self.diverge("early end: the recording is truncated");
            } else if self.next_core().is_some() {
                self.diverge("early end: recorded core entries were not produced");
            }
        }
        0
    }
}

pub unsafe extern "C" fn h_answer_replay(hp: *mut c_void, _w: i32, call: *const ren_call, out: *mut ren_reply_t) -> bool {
    let d = &*(hp as *const Drv);
    match &d.be {
        super::Backend::Replay(r) => r.answer(&*call, &mut *out),
        _ => false,
    }
}
pub unsafe extern "C" fn h_journal_replay(hp: *mut c_void, _w: i32, e: *const c_void, n: usize) {
    let d = &*(hp as *const Drv);
    if let super::Backend::Replay(r) = &d.be {
        r.journal(core::slice::from_raw_parts(e as *const u8, n));
    }
}

// ================= fuzz =================
pub const REN_FUZZ_STALE_MAGIC: i64 = 0x5A1E5A1E;

pub struct Fuzz {
    input: &'static [u8],
    pos: usize,
    pending: Vec<ren_call>,
    done_ids: [u64; 64],
    n_done: usize,
    done_at: usize,
    fail: i32,
    err: Vec<u8>,
}

/// The input is used up: the action loop ends.
struct Eof;

impl Fuzz {
    pub unsafe fn new(o: &ren_drv_opts) -> Fuzz {
        let input: &'static [u8] =
            if o.input.is_null() { &[] } else { core::slice::from_raw_parts(o.input, o.input_len) };
        Fuzz { input, pos: 0, pending: Vec::new(), done_ids: [0; 64], n_done: 0, done_at: 0, fail: 0, err: cstr(String::new()) }
    }
    pub fn failed(&self) -> bool {
        self.fail != 0
    }
    pub fn err_ptr(&self) -> *const c_char {
        self.err.as_ptr() as *const c_char
    }
    pub fn result(&self) -> i32 {
        self.fail
    }
    fn next(&mut self) -> Result<u8, Eof> {
        let b = *self.input.get(self.pos).ok_or(Eof)?;
        self.pos += 1;
        Ok(b)
    }
    fn oracle(&mut self, ok: bool, what: &str) {
        if !ok && self.fail == 0 {
            self.fail = 1;
            self.err = cstr(format!("fuzz oracle failed at input byte {}: {what}", self.pos));
        }
    }
    fn push_done(&mut self, id: u64) {
        self.done_ids[self.done_at] = id;
        self.done_at = (self.done_at + 1) % 64;
        if self.n_done < 64 {
            self.n_done += 1;
        }
    }
    unsafe fn reply(&mut self, c: *mut ren_core, id: u64, state: u32, res: i64) -> i32 {
        let r = res1(res);
        let rp = ren_reply_t { id, state, len: RES_BYTES as u32, body: &r as *const ren_io_result as *const c_void };
        ren_reply(c, &rp)
    }
    /// RUN rule: run, then poll until false.
    unsafe fn run_worker(&mut self, c: *mut ren_core, w: i32, steps: u32) -> i32 {
        let r = ren_run(c, w, steps);
        let mut call: ren_call = zeroed();
        while ren_poll_call(c, w, &mut call) {
            if call.kind as u32 == REN_CALL {
                self.pending.push(call);
            } else if call.kind as u32 == REN_CANCEL {
                if let Some(k) = self.pending.iter().position(|p| p.id == call.id) {
                    self.pending.remove(k);
                    let ret = self.reply(c, call.id, REN_CANCELLED, CANCELLED_RES.res);
                    self.oracle(ret == REN_ACCEPTED as i32, "a reply to a cancelled pending call was not ACCEPTED");
                    self.push_done(call.id);
                }
            }
        }
        r
    }
    unsafe fn actions(&mut self, c: *mut ren_core, nw: i32) -> Result<(), Eof> {
        while self.fail == 0 {
            match self.next()? % 8 {
                0 | 1 => {
                    let w = (self.next()? as i32) % nw;
                    let steps = 1 + (self.next()? % 16) as u32;
                    self.run_worker(c, w, steps);
                }
                2 => {
                    if !self.pending.is_empty() {
                        // Read every byte of the action before taking the call out of
                        // `pending`: input that ends mid-action must not lose a pulled
                        // call (libFuzzer found the first version doing that: "no
                        // termination" on a 5-byte input).
                        let k = self.next()? as usize % self.pending.len();
                        let cancelled = self.next()? & 1 != 0;
                        let blen = (*(self.pending[k].body as *const ren_io_body)).len;
                        let (state, res) = if cancelled {
                            (REN_CANCELLED, CANCELLED_RES.res)
                        } else {
                            (REN_DONE, (self.next()? as u64 % (blen + 1)) as i64)
                        };
                        let call = self.pending.remove(k);
                        let b = &*(call.body as *const ren_io_body);
                        if call.op == REN_OP_READ && state == REN_DONE {
                            let p = b.buf as usize as *mut u8;
                            for i in 0..res as u64 {
                                *p.add(i as usize) = (call.id.wrapping_add(i) & 0xff) as u8;
                            }
                        }
                        let ret = self.reply(c, call.id, state, res);
                        self.oracle(ret == REN_ACCEPTED as i32, "a reply to a pending call was not ACCEPTED");
                        self.push_done(call.id);
                    }
                }
                3 | 4 => {
                    if self.n_done > 0 {
                        let id = self.done_ids[self.next()? as usize % self.n_done];
                        let ret = self.reply(c, id, REN_DONE, REN_FUZZ_STALE_MAGIC);
                        self.oracle(ret == REN_RELEASE as i32, "a stale reply was not RELEASEd");
                    }
                }
                5 => {
                    let mut id = 0u64;
                    for i in 0..8 {
                        id |= (self.next()? as u64) << (8 * i);
                    }
                    if !self.pending.iter().any(|p| p.id == id) {
                        let ret = self.reply(c, id, REN_DONE, REN_FUZZ_STALE_MAGIC);
                        self.oracle(ret == REN_RELEASE as i32, "a bogus reply was not RELEASEd");
                    }
                }
                6 => ren_stop(c),
                _ => {}
            }
        }
        Ok(())
    }
    pub unsafe fn run(&mut self, d: &Drv, c: *mut ren_core) -> i32 {
        let nw = d.o.workers;
        let _ = self.actions(c, nw);
        ren_stop(c);
        let mut finished = false;
        for _ in 0..10000 {
            if self.fail != 0 {
                break;
            }
            let mut fin = 0;
            for w in 0..nw {
                if self.run_worker(c, w, 64) == REN_FINISHED as i32 {
                    fin += 1;
                }
            }
            for call in core::mem::take(&mut self.pending) {
                let ret = self.reply(c, call.id, REN_CANCELLED, CANCELLED_RES.res);
                self.oracle(ret == REN_ACCEPTED as i32, "a final cancel reply was not ACCEPTED");
            }
            if fin == nw {
                finished = true;
                break;
            }
        }
        if self.fail == 0 && !finished {
            self.fail = 2;
            self.err = cstr(String::from("fuzz oracle failed: no termination (a lost wakeup or a lost reply)"));
        }
        0
    }
}
