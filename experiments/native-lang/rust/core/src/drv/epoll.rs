//! The epoll driver (SPEC §C.1 table, epoll column): nonblocking syscalls
//! tried at submit; on EAGAIN a one-shot readiness wait keyed by fd; a
//! driver-held timer heap for SleepUntil; an eventfd for wakes.
use super::linux::{self, Io};
use super::{errno, mono_ns, res1, Drv, CANCELLED_RES, RES0};
use crate::sys::*;
use alloc::collections::{BTreeMap, BTreeSet, BinaryHeap};
use core::cmp::Reverse;
use core::ffi::c_void;
use core::mem::size_of;

const EVKEY: u64 = u64::MAX;

#[derive(Clone, Copy)]
struct Wait {
    op: u32,
    fd: i32,
    body: ren_io_body,
    /// CONNECT: the socket being connected
    sock: i32,
}

#[derive(Default, Clone, Copy)]
struct FdW {
    rd: u64,
    wr: u64,
    reg: bool,
}

pub struct EpW {
    epfd: i32,
    evfd: i32,
    ops: BTreeMap<u64, Wait>,
    fds: BTreeMap<i32, FdW>,
    timers: BinaryHeap<Reverse<(i64, u64)>>,
    poisoned: BTreeSet<i32>,
}

/// What an attempt gave: None = would block.
type Try = Option<ren_io_result>;

impl EpW {
    pub fn new(evfd: i32) -> EpW {
        EpW {
            epfd: -1,
            evfd,
            ops: BTreeMap::new(),
            fds: BTreeMap::new(),
            timers: BinaryHeap::new(),
            poisoned: BTreeSet::new(),
        }
    }

    unsafe fn ctl(&self, op: i32, fd: i32, events: u32, key: u64) -> i32 {
        let mut ev = libc::epoll_event { events, u64: key };
        if libc::epoll_ctl(self.epfd, op, fd, &mut ev) < 0 {
            errno()
        } else {
            0
        }
    }

    /// (Re)arm fd's one-shot registration with the interests it has now.
    unsafe fn arm(&mut self, fd: i32) {
        let f = *self.fds.entry(fd).or_default();
        let mut ev = libc::EPOLLONESHOT as u32;
        if f.rd != 0 {
            ev |= libc::EPOLLIN as u32;
        }
        if f.wr != 0 {
            ev |= libc::EPOLLOUT as u32;
        }
        let e = if f.reg {
            let e = self.ctl(libc::EPOLL_CTL_MOD, fd, ev, fd as u64);
            // the fd was closed and its number reused since: register afresh
            if e == libc::ENOENT {
                self.ctl(libc::EPOLL_CTL_ADD, fd, ev, fd as u64)
            } else {
                e
            }
        } else {
            let e = self.ctl(libc::EPOLL_CTL_ADD, fd, ev, fd as u64);
            if e == libc::EEXIST {
                self.ctl(libc::EPOLL_CTL_MOD, fd, ev, fd as u64)
            } else {
                e
            }
        };
        if e == 0 {
            self.fds.get_mut(&fd).unwrap().reg = true;
        }
    }

    unsafe fn attempt(&self, wt: &Wait) -> Try {
        let b = &wt.body;
        let r: i64 = match wt.op {
            REN_OP_READ => libc::read(wt.fd, b.buf as usize as *mut c_void, b.len as usize) as i64,
            REN_OP_WRITE => libc::write(wt.fd, b.buf as usize as *const c_void, b.len as usize) as i64,
            REN_OP_ACCEPT => libc::accept4(
                wt.fd,
                core::ptr::null_mut(),
                core::ptr::null_mut(),
                libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            ) as i64,
            REN_OP_CONNECT => {
                let mut err: i32 = 0;
                let mut l = size_of::<i32>() as libc::socklen_t;
                if libc::getsockopt(wt.sock, libc::SOL_SOCKET, libc::SO_ERROR, &mut err as *mut i32 as *mut c_void, &mut l) < 0 {
                    err = errno();
                }
                if err == libc::EINPROGRESS || err == libc::EALREADY {
                    return None;
                }
                if err != 0 {
                    libc::close(wt.sock);
                    return Some(res1(-(err as i64)));
                }
                return Some(res1(wt.sock as i64));
            }
            _ => return Some(res1(-(libc::ENOSYS as i64))),
        };
        if r < 0 {
            let e = errno();
            if e == libc::EAGAIN || e == libc::EWOULDBLOCK {
                return None;
            }
            return Some(res1(-(e as i64)));
        }
        Some(res1(r))
    }

    /// Reply to a finished op, then act on RELEASE (SPEC §C.1 release()).
    unsafe fn complete(&mut self, d: &Drv, c: *mut ren_core, w: i32, id: u64, wt: &Wait, r: ren_io_result) {
        let inout: &[u8] = if wt.op == REN_OP_READ && r.res > 0 {
            core::slice::from_raw_parts(wt.body.buf as usize as *const u8, r.res as usize)
        } else {
            &[]
        };
        let ret = d.reply(c, w, id, REN_DONE, r, inout);
        if ret == REN_RELEASE as i32 {
            if wt.op == REN_OP_ACCEPT && r.res >= 0 {
                libc::close(r.res as i32);
            } else if wt.op == REN_OP_READ && r.res > 0 {
                self.poisoned.insert(wt.fd);
            }
        }
    }

    unsafe fn wait_on(&mut self, fd: i32, write: bool, id: u64, wt: Wait) {
        self.ops.insert(id, wt);
        let f = self.fds.entry(fd).or_default();
        if write {
            f.wr = id;
        } else {
            f.rd = id;
        }
        self.arm(fd);
    }

    /// Drop a wait (cancel, close, kill): its fd interest and its op.
    unsafe fn unwait(&mut self, id: u64) -> Option<Wait> {
        let wt = self.ops.remove(&id)?;
        let fd = if wt.op == REN_OP_CONNECT { wt.sock } else { wt.fd };
        if wt.op != REN_OP_SLEEP_UNTIL {
            if let Some(f) = self.fds.get_mut(&fd) {
                if f.rd == id {
                    f.rd = 0;
                }
                if f.wr == id {
                    f.wr = 0;
                }
                if f.reg {
                    self.arm(fd);
                }
            }
        }
        if wt.op == REN_OP_CONNECT {
            libc::close(wt.sock);
        }
        Some(wt)
    }

    unsafe fn ready(&mut self, d: &Drv, c: *mut ren_core, w: i32, fd: i32) {
        let Some(f) = self.fds.get(&fd).copied() else { return };
        for (id, write) in [(f.rd, false), (f.wr, true)] {
            if id == 0 {
                continue;
            }
            let Some(wt) = self.ops.get(&id).copied() else { continue };
            if let Some(r) = self.attempt(&wt) {
                self.ops.remove(&id);
                let fe = self.fds.get_mut(&fd).unwrap();
                if write {
                    fe.wr = 0;
                } else {
                    fe.rd = 0;
                }
                self.complete(d, c, w, id, &wt, r);
            }
        }
        if let Some(f) = self.fds.get(&fd) {
            if f.rd != 0 || f.wr != 0 {
                self.arm(fd);
            }
        }
    }

    fn next_deadline(&mut self) -> Option<i64> {
        while let Some(Reverse((t, id))) = self.timers.peek().copied() {
            if self.ops.contains_key(&id) {
                return Some(t);
            }
            self.timers.pop(); // cancelled: lazy deletion
        }
        None
    }
}

impl Io for EpW {
    unsafe fn setup(&mut self, _d: &Drv, _w: i32) -> Result<(), &'static str> {
        self.epfd = libc::epoll_create1(libc::EPOLL_CLOEXEC);
        if self.epfd < 0 {
            return Err("epoll_create1 failed");
        }
        if self.ctl(libc::EPOLL_CTL_ADD, self.evfd, libc::EPOLLIN as u32, EVKEY) != 0 {
            return Err("epoll_ctl(eventfd) failed");
        }
        Ok(())
    }

    unsafe fn submit(&mut self, d: &Drv, c: *mut ren_core, w: i32, call: &ren_call) {
        let id = call.id;
        if call.kind as u32 == REN_CANCEL {
            // waiting on readiness or a timer: drop the wait, reply Cancelled;
            // completed already or unknown: ignore
            if self.unwait(id).is_some() {
                d.reply(c, w, id, REN_CANCELLED, CANCELLED_RES, &[]);
            }
            return;
        }
        let b = linux::body(call);
        let wt = Wait { op: call.op, fd: b.fd as i32, body: b, sock: -1 };
        match call.op {
            REN_OP_SLEEP_UNTIL => {
                self.ops.insert(id, wt);
                self.timers.push(Reverse((b.arg, id)));
            }
            REN_OP_MONO_NOW => {
                d.reply(c, w, id, REN_DONE, res1(mono_ns()), &[]);
            }
            REN_OP_PIPE => {
                d.reply(c, w, id, REN_DONE, linux::do_pipe(), &[]);
            }
            REN_OP_LISTEN => {
                d.reply(c, w, id, REN_DONE, linux::do_listen(b.arg), &[]);
            }
            REN_OP_READ if self.poisoned.contains(&wt.fd) => {
                d.reply(c, w, id, REN_DONE, res1(-(libc::EIO as i64)), &[]);
            }
            REN_OP_READ | REN_OP_WRITE | REN_OP_ACCEPT => match self.attempt(&wt) {
                Some(r) => self.complete(d, c, w, id, &wt, r),
                None => self.wait_on(wt.fd, call.op == REN_OP_WRITE, id, wt),
            },
            REN_OP_CONNECT => {
                let s = linux::tcp_socket();
                if s < 0 {
                    d.reply(c, w, id, REN_DONE, res1(-(errno() as i64)), &[]);
                    return;
                }
                let a = linux::loopback(b.arg);
                let sl = size_of::<libc::sockaddr_in>() as libc::socklen_t;
                if libc::connect(s, &a as *const _ as *const libc::sockaddr, sl) == 0 {
                    d.reply(c, w, id, REN_DONE, res1(s as i64), &[]);
                } else if errno() == libc::EINPROGRESS {
                    self.wait_on(s, true, id, Wait { sock: s, ..wt });
                } else {
                    let e = errno();
                    libc::close(s);
                    d.reply(c, w, id, REN_DONE, res1(-(e as i64)), &[]);
                }
            }
            REN_OP_CLOSE => {
                let fd = wt.fd;
                if let Some(f) = self.fds.get(&fd).copied() {
                    for oid in [f.rd, f.wr] {
                        if oid != 0 && self.unwait(oid).is_some() {
                            d.reply(c, w, oid, REN_CANCELLED, CANCELLED_RES, &[]);
                        }
                    }
                    if f.reg {
                        self.ctl(libc::EPOLL_CTL_DEL, fd, 0, 0);
                    }
                    self.fds.remove(&fd);
                }
                self.poisoned.remove(&fd);
                let r = if libc::close(fd) < 0 { -(errno() as i64) } else { 0 };
                d.reply(c, w, id, REN_DONE, res1(r), &[]);
            }
            _ => {
                d.reply(c, w, id, REN_DONE, res1(-(libc::ENOSYS as i64)), &[]);
            }
        }
    }

    fn inflight(&self) -> usize {
        self.ops.len()
    }

    unsafe fn cancel_all(&mut self, d: &Drv, c: *mut ren_core, w: i32) {
        let ids: alloc::vec::Vec<u64> = self.ops.keys().copied().collect();
        for id in ids {
            if self.unwait(id).is_some() {
                d.reply(c, w, id, REN_CANCELLED, CANCELLED_RES, &[]);
            }
        }
        self.timers.clear();
    }

    unsafe fn wait(&mut self, d: &Drv, c: *mut ren_core, w: i32, block: bool) {
        let timeout: i32 = if !block {
            0
        } else {
            match self.next_deadline() {
                None => -1,
                Some(t) => {
                    let dt = t - mono_ns();
                    if dt <= 0 {
                        0
                    } else {
                        core::cmp::min((dt + 999_999) / 1_000_000, i32::MAX as i64) as i32
                    }
                }
            }
        };
        let mut evs: [libc::epoll_event; 64] = core::mem::zeroed();
        let n = libc::epoll_wait(self.epfd, evs.as_mut_ptr(), 64, timeout);
        for ev in evs.iter().take(if n > 0 { n as usize } else { 0 }) {
            let key = ev.u64;
            if key == EVKEY {
                let mut v: u64 = 0;
                libc::read(self.evfd, &mut v as *mut u64 as *mut c_void, 8);
            } else {
                self.ready(d, c, w, key as i32);
            }
        }
        if !self.timers.is_empty() {
            let now = mono_ns();
            while let Some(Reverse((t, id))) = self.timers.peek().copied() {
                if t > now {
                    break;
                }
                self.timers.pop();
                if self.ops.remove(&id).is_some() {
                    d.reply(c, w, id, REN_DONE, RES0, &[]); // RELEASE: nothing to give back
                }
            }
        }
    }

    unsafe fn teardown(&mut self) {
        if self.epfd >= 0 {
            libc::close(self.epfd);
            self.epfd = -1;
        }
    }
}
