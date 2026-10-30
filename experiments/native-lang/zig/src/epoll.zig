//! The epoll driver (SPEC §C.1): one epoll fd + an eventfd per worker, a
//! driver-held timer heap ordered by (deadline, id), EPOLLONESHOT readiness
//! keyed by fd, one READ waiter and one WRITE/ACCEPT/CONNECT waiter per fd.
const std = @import("std");
const linux = std.os.linux;
const sl = @import("slice");
const A = @import("alloc.zig");
const W_ = @import("wire.zig");
const core = @import("core.zig");
const drv = @import("drv.zig");

const WAKE_KEY: u64 = std.math.maxInt(u64);

const Dir = enum { none, rd, wr, timer };

const DOp = struct {
    call: sl.ren_call,
    body: sl.ren_io_body,
    dir: Dir = .none,
    deadline: i64 = 0,
    connect_fd: i32 = -1,
};

const FdEnt = struct {
    rd: ?*DOp = null,
    wr: ?*DOp = null,
    added: bool = false, // registered in this worker's epoll
    poisoned: bool = false,
};

const TEnt = struct { t: i64, id: u64 };

const Ew = struct {
    d: *drv.Drv,
    c: *core.Core,
    w: i32,
    epfd: i32 = -1,
    ops: std.AutoHashMapUnmanaged(u64, *DOp) = .empty, // in flight, by call id
    fds: std.AutoHashMapUnmanaged(i32, FdEnt) = .empty,
    heap: std.ArrayList(TEnt) = .empty, // lazy deletion: an entry whose id is gone is skipped
    ntimers: usize = 0,

    fn gpa() std.mem.Allocator {
        return A.gpa();
    }
    fn fdEnt(e: *Ew, fd: i32) *FdEnt {
        const g = e.fds.getOrPut(gpa(), fd) catch A.oom();
        if (!g.found_existing) g.value_ptr.* = .{};
        return g.value_ptr;
    }

    // ---------------- timer heap by (t, id)
    fn less(a: TEnt, b: TEnt) bool {
        return a.t < b.t or (a.t == b.t and a.id < b.id);
    }
    fn heapPush(e: *Ew, x: TEnt) void {
        e.heap.append(gpa(), x) catch A.oom();
        var i = e.heap.items.len - 1;
        const h = e.heap.items;
        while (i > 0) {
            const p = (i - 1) / 2;
            if (!less(h[i], h[p])) break;
            std.mem.swap(TEnt, &h[i], &h[p]);
            i = p;
        }
    }
    fn heapPop(e: *Ew) void {
        const h = e.heap.items;
        const last = h.len - 1;
        h[0] = h[last];
        e.heap.items.len = last;
        var i: usize = 0;
        const n = last;
        while (true) {
            const l = 2 * i + 1;
            const r = l + 1;
            var m = i;
            if (l < n and less(h[l], h[m])) m = l;
            if (r < n and less(h[r], h[m])) m = r;
            if (m == i) break;
            std.mem.swap(TEnt, &h[i], &h[m]);
            i = m;
        }
    }
    /// the earliest live timer, dropping stale heap entries
    fn heapTop(e: *Ew) ?TEnt {
        while (e.heap.items.len != 0) {
            const top = e.heap.items[0];
            if (e.ops.get(top.id)) |o| {
                if (o.dir == .timer and o.deadline == top.t) return top;
            }
            e.heapPop();
        }
        return null;
    }

    // ---------------- epoll registration
    fn ctl(e: *Ew, op: u32, fd: i32, events: u32, key: u64) usize {
        var ev: linux.epoll_event = .{ .events = events, .data = .{ .u64 = key } };
        return linux.epoll_ctl(e.epfd, op, fd, &ev);
    }
    /// (re)arm fd for its current waiters (EPOLLONESHOT)
    fn arm(e: *Ew, fd: i32) void {
        const f = e.fds.getPtr(fd) orelse return;
        var ev: u32 = 0;
        if (f.rd != null) ev |= linux.EPOLL.IN;
        // the WRITE/ACCEPT/CONNECT slot: an ACCEPT waits for readability
        if (f.wr) |o| ev |= if (o.call.op == sl.REN_OP_ACCEPT) linux.EPOLL.IN else linux.EPOLL.OUT;
        if (ev == 0) return;
        ev |= linux.EPOLL.ONESHOT;
        const key: u64 = @intCast(fd);
        if (f.added) {
            const r = e.ctl(linux.EPOLL.CTL_MOD, fd, ev, key);
            if (linux.errno(r) == .NOENT) { // the fd number was closed and reused elsewhere
                _ = e.ctl(linux.EPOLL.CTL_ADD, fd, ev, key);
            }
        } else {
            const r = e.ctl(linux.EPOLL.CTL_ADD, fd, ev, key);
            if (linux.errno(r) == .EXIST) _ = e.ctl(linux.EPOLL.CTL_MOD, fd, ev, key);
            f.added = true;
        }
    }

    // ---------------- completion
    /// reply for o, unlink it, free it
    fn finishOp(e: *Ew, o: *DOp, st: u32, res: i64, a: i64, b: i64) void {
        const fd: i32 = @truncate(o.body.fd);
        switch (o.dir) {
            .rd => if (e.fds.getPtr(fd)) |f| {
                if (f.rd == o) f.rd = null;
            },
            .wr => if (e.fds.getPtr(o.connect_fd)) |f| {
                if (f.wr == o) f.wr = null;
            },
            .timer => e.ntimers -= 1,
            .none => {},
        }
        _ = e.ops.remove(o.call.id);
        var in: []const u8 = &.{};
        if (st == sl.REN_DONE and o.call.op == sl.REN_OP_READ and res > 0) in = W_.bufPtr(o.body.buf)[0..@intCast(res)];
        const rr = drv.doReply(e.d, e.c, e.w, o.call.id, st, res, a, b, in);
        if (rr == sl.REN_RELEASE and st == sl.REN_DONE) {
            if (o.call.op == sl.REN_OP_READ and res > 0) {
                e.fdEnt(fd).poisoned = true; // a READ that consumed bytes: torn handle (§2.2)
            } else {
                drv.releaseFds(o.call.op, res, a, b);
            }
        }
        A.destroy(o);
    }

    /// try the syscall for a waiting op; true when it completed
    fn attempt(e: *Ew, o: *DOp) bool {
        const fd: i32 = @truncate(o.body.fd);
        switch (o.call.op) {
            sl.REN_OP_READ => {
                if (e.fdEnt(fd).poisoned) {
                    e.finishOp(o, sl.REN_DONE, -@as(i64, @intFromEnum(linux.E.IO)), 0, 0);
                    return true;
                }
                const r = linux.read(fd, W_.bufPtr(o.body.buf), @intCast(o.body.len));
                if (linux.errno(r) == .AGAIN) return false;
                e.finishOp(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
                return true;
            },
            sl.REN_OP_WRITE => {
                const r = linux.write(fd, W_.bufPtr(o.body.buf), @intCast(o.body.len));
                if (linux.errno(r) == .AGAIN) return false;
                e.finishOp(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
                return true;
            },
            sl.REN_OP_ACCEPT => {
                const r = linux.accept4(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
                if (linux.errno(r) == .AGAIN) return false;
                e.finishOp(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
                return true;
            },
            sl.REN_OP_CONNECT => {
                var err: i32 = 0;
                var len: linux.socklen_t = 4;
                const r = linux.getsockopt(o.connect_fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err), &len);
                var res: i64 = undefined;
                if (linux.errno(r) != .SUCCESS) res = drv.sysErr(r) else if (err == @intFromEnum(linux.E.INPROGRESS)) return false else if (err != 0) res = -@as(i64, err) else res = o.connect_fd;
                const cfd = o.connect_fd;
                if (res < 0) {
                    e.unlinkWr(o);
                    _ = linux.close(cfd);
                }
                e.finishOp(o, sl.REN_DONE, res, 0, 0);
                return true;
            },
            else => unreachable,
        }
    }
    fn unlinkWr(e: *Ew, o: *DOp) void {
        if (e.fds.getPtr(o.connect_fd)) |f| {
            if (f.wr == o) f.wr = null;
        }
        o.dir = .none;
    }

    fn waitOn(e: *Ew, o: *DOp, fd: i32, dir: Dir) void {
        o.dir = dir;
        const f = e.fdEnt(fd);
        if (dir == .rd) f.rd = o else f.wr = o;
        e.ops.put(gpa(), o.call.id, o) catch A.oom();
        e.arm(fd);
    }

    // ---------------- submit one pulled call
    fn submit(e: *Ew, k: *const sl.ren_call) void {
        if (k.kind == sl.REN_CANCEL) {
            // waiting on readiness or a timer: drop the wait, reply Cancelled; else ignore
            const o = e.ops.get(k.id) orelse return;
            e.finishOp(o, sl.REN_CANCELLED, -sl.REN_ECANCELED, 0, 0);
            return;
        }
        if (k.kind != sl.REN_CALL) return;
        const o = A.create(DOp);
        o.* = .{ .call = k.*, .body = @as(*const sl.ren_io_body, @ptrCast(@alignCast(k.body.?))).* }; // ptr site: call.body
        const fd: i32 = @truncate(o.body.fd);
        switch (k.op) {
            sl.REN_OP_SLEEP_UNTIL => {
                o.dir = .timer;
                o.deadline = o.body.arg;
                e.ntimers += 1;
                e.ops.put(gpa(), k.id, o) catch A.oom();
                e.heapPush(.{ .t = o.deadline, .id = k.id });
            },
            sl.REN_OP_MONO_NOW => e.finishOp(o, sl.REN_DONE, drv.monoNs(), 0, 0),
            sl.REN_OP_PIPE => {
                var a: i64 = 0;
                var b: i64 = 0;
                const r = drv.syncPipe(&a, &b);
                e.finishOp(o, sl.REN_DONE, r, a, b);
            },
            sl.REN_OP_LISTEN => {
                var port: i64 = 0;
                const r = drv.syncListen(o.body.arg, &port);
                e.finishOp(o, sl.REN_DONE, r, port, 0);
            },
            sl.REN_OP_READ => if (!e.attempt(o)) e.waitOn(o, fd, .rd),
            sl.REN_OP_WRITE, sl.REN_OP_ACCEPT => {
                o.connect_fd = fd;
                if (!e.attempt(o)) e.waitOn(o, fd, .wr);
            },
            sl.REN_OP_CONNECT => {
                const r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
                if (linux.errno(r) != .SUCCESS) return e.finishOp(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
                const sfd: i32 = @intCast(r);
                const sa = drv.loopback(o.body.arg);
                const cr = linux.connect(sfd, &sa, @sizeOf(linux.sockaddr.in));
                const ce = linux.errno(cr);
                if (ce == .SUCCESS) return e.finishOp(o, sl.REN_DONE, sfd, 0, 0);
                if (ce != .INPROGRESS) {
                    _ = linux.close(sfd);
                    return e.finishOp(o, sl.REN_DONE, drv.sysErr(cr), 0, 0);
                }
                o.connect_fd = sfd;
                e.waitOn(o, sfd, .wr);
            },
            sl.REN_OP_CLOSE => {
                // cancel every in-flight op on fd held here (each gets Cancelled), then close
                if (e.fds.getPtr(fd)) |f0| {
                    if (f0.rd) |x| e.finishOp(x, sl.REN_CANCELLED, -sl.REN_ECANCELED, 0, 0);
                    if (e.fds.getPtr(fd)) |f2| if (f2.wr) |x| e.finishOp(x, sl.REN_CANCELLED, -sl.REN_ECANCELED, 0, 0);
                    if (e.fds.getPtr(fd)) |f3| if (f3.added) {
                        _ = linux.epoll_ctl(e.epfd, linux.EPOLL.CTL_DEL, fd, null);
                    };
                    _ = e.fds.remove(fd);
                }
                const r = linux.close(fd);
                e.finishOp(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
            },
            else => e.finishOp(o, sl.REN_DONE, -@as(i64, @intFromEnum(linux.E.NOSYS)), 0, 0),
        }
    }

    fn deinit(e: *Ew) void {
        var it = e.ops.valueIterator();
        while (it.next()) |o| A.destroy(o.*);
        e.ops.deinit(gpa());
        e.fds.deinit(gpa());
        e.heap.deinit(gpa());
        if (e.epfd >= 0) _ = linux.close(e.epfd);
    }
};

pub fn run(d: *drv.Drv, c: *core.Core, w: i32) i32 {
    var e: Ew = .{ .d = d, .c = c, .w = w };
    defer e.deinit();
    const r0 = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.errno(r0) != .SUCCESS) {
        drv.setErr(d, "epoll_create1: {s}", .{drv.errName(linux.errno(r0))});
        return -1;
    }
    e.epfd = @intCast(r0);
    const wfd = d.wake_fd[@intCast(w)];
    if (linux.errno(e.ctl(linux.EPOLL.CTL_ADD, wfd, linux.EPOLL.IN, WAKE_KEY)) != .SUCCESS) {
        drv.setErr(d, "epoll_ctl(eventfd) failed", .{});
        return -1;
    }
    if (w == 0) drv.recDrv(d);
    var batch: std.ArrayList(sl.ren_call) = .empty;
    defer batch.deinit(A.gpa());
    var evs: [64]linux.epoll_event = undefined;
    while (true) {
        const r = core.run(c, w, d.o.steps);
        drv.recRun(d, c, w, d.o.steps, r);
        batch.clearRetainingCapacity();
        var k: sl.ren_call = .{};
        while (core.pollCall(c, w, &k)) { // drain until false: the one signal
            drv.recPull(d, c, w, &k);
            batch.append(A.gpa(), k) catch A.oom();
        }
        drv.recDrained(d, c, w);
        for (batch.items) |*x| e.submit(x);
        if (r == sl.REN_FINISHED and e.ops.count() == 0) break;
        if (r == sl.REN_FINISHED) {
            // after kill: nothing is in the kernel; drop the waits
            while (true) {
                var it = e.ops.valueIterator();
                const o = (it.next() orelse break).*;
                const fd: i32 = @truncate(o.body.fd);
                const dir = o.dir;
                const cfd = o.connect_fd;
                e.finishOp(o, sl.REN_CANCELLED, -sl.REN_ECANCELED, 0, 0);
                if (dir == .rd) _ = linux.epoll_ctl(e.epfd, linux.EPOLL.CTL_DEL, fd, null);
                if (dir == .wr) _ = linux.epoll_ctl(e.epfd, linux.EPOLL.CTL_DEL, cfd, null);
            }
            continue;
        }
        var ts: linux.timespec = .{ .sec = 0, .nsec = 0 };
        var tsp: usize = 0; // NULL: forever
        if (r == sl.REN_RUNNING) {
            tsp = @intFromPtr(&ts); // ptr site: syscall argument
        } else if (e.heapTop()) |top| {
            var dl = top.t - drv.monoNs();
            if (dl < 0) dl = 0;
            ts = .{ .sec = @divTrunc(dl, 1_000_000_000), .nsec = @rem(dl, 1_000_000_000) };
            tsp = @intFromPtr(&ts); // ptr site: syscall argument
        }
        const n = linux.syscall6(.epoll_pwait2, @intCast(e.epfd), @intFromPtr(&evs), evs.len, tsp, 0, 0); // ptr site
        const ne = linux.errno(n);
        if (ne != .SUCCESS and ne != .INTR) {
            drv.setErr(d, "epoll_pwait2: {s}", .{drv.errName(ne)});
            return -1;
        }
        const cnt: usize = if (ne == .SUCCESS) n else 0;
        for (evs[0..cnt]) |ev| {
            const key = ev.data.u64;
            if (key == WAKE_KEY) {
                var v: u64 = 0;
                while (linux.read(wfd, std.mem.asBytes(&v), 8) == 8) {}
                continue;
            }
            const fd: i32 = @intCast(key);
            if (e.fds.getPtr(fd)) |f| if (f.rd) |o| {
                _ = e.attempt(o);
            };
            if (e.fds.getPtr(fd)) |f| if (f.wr) |o| {
                _ = e.attempt(o);
            };
            e.arm(fd);
        }
        const now = drv.monoNs();
        while (e.heapTop()) |top| {
            if (top.t > now) break;
            e.heapPop();
            const o = e.ops.get(top.id).?;
            e.finishOp(o, sl.REN_DONE, 0, 0, 0);
        }
    }
    return 0;
}
