//! The io_uring driver (SPEC §C.1) on std.os.linux.IoUring: one ring per
//! worker, created R_DISABLED (+ SINGLE_ISSUER | DEFER_TASKRUN unless
//! REN_DRV_F_URING_NO_DEFER) by ren_drv_new and enabled on the worker's own
//! thread; IORING_OP_TIMEOUT (ABS, CLOCK_MONOTONIC) for SleepUntil;
//! ASYNC_CANCEL by user_data for REN_CANCEL and by fd (FD | ALL) for CLOSE;
//! one READ of the worker's eventfd kept armed for wakes.
const std = @import("std");
const linux = std.os.linux;
const sl = @import("slice");
const A = @import("alloc.zig");
const W_ = @import("wire.zig");
const core = @import("core.zig");
const drv = @import("drv.zig");

const IoUring = linux.IoUring;

// user_data values with bit 63 set are the driver's own (a call id never has
// it: slot < nw * op_slots, far below 2^31)
const UD_WAKE: u64 = 1 << 63;
const UD_IGNORE: u64 = (1 << 63) | 1;

const ENTRIES: u16 = 256;

const UOp = struct {
    call: sl.ren_call,
    body: sl.ren_io_body,
    fd: i32 = -1, // the fd it is in flight on (CONNECT: the new socket)
    ts: linux.kernel_timespec = .{ .sec = 0, .nsec = 0 },
    sa: linux.sockaddr.in = undefined,
    cancel_sent: bool = false,
};

/// ren_drv_new: detect once, fall back whole (§2.10)
pub fn setup(d: *drv.Drv) bool {
    const nw: usize = @intCast(d.o.workers);
    d.rings = A.allocSlice(IoUring, nw);
    for (d.rings) |*r| r.fd = -1;
    for (d.rings) |*r| {
        var flags: u32 = linux.IORING_SETUP_R_DISABLED;
        if (d.o.flags & sl.REN_DRV_F_URING_NO_DEFER == 0 and !d.uring_fallback)
            flags |= linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN;
        var p = std.mem.zeroInit(linux.io_uring_params, .{ .flags = flags });
        r.* = IoUring.init_params(ENTRIES, &p) catch |e| blk: {
            if (e == error.ArgumentsInvalid and flags & linux.IORING_SETUP_DEFER_TASKRUN != 0) {
                d.uring_fallback = true;
                var p2 = std.mem.zeroInit(linux.io_uring_params, .{ .flags = linux.IORING_SETUP_R_DISABLED });
                break :blk IoUring.init_params(ENTRIES, &p2) catch |e2| {
                    drv.setErr(d, "io_uring_setup: {s} (not falling back to epoll)", .{@errorName(e2)});
                    r.fd = -1;
                    return false;
                };
            }
            drv.setErr(d, "io_uring_setup: {s} (not falling back to epoll)", .{@errorName(e)});
            r.fd = -1;
            return false;
        };
    }
    if (d.uring_fallback) {
        const m = "ren zig uring: SINGLE_ISSUER|DEFER_TASKRUN refused (EINVAL); rings set up without them\n";
        _ = linux.write(2, m, m.len);
    }
    return true;
}

pub fn teardownAll(d: *drv.Drv) void {
    for (d.rings) |*r| if (r.fd >= 0) r.deinit();
    if (d.rings.len != 0) A.freeSlice(IoUring, d.rings);
    d.rings = &.{};
}

const Uw = struct {
    d: *drv.Drv,
    c: *core.Core,
    w: i32,
    ring: *IoUring,
    ops: std.AutoHashMapUnmanaged(u64, *UOp) = .empty,
    fdcount: std.AutoHashMapUnmanaged(i32, u32) = .empty, // in-flight ops per fd
    closing: std.AutoHashMapUnmanaged(i32, *UOp) = .empty, // CLOSE waiting for its fd's CQEs
    poisoned: std.AutoHashMapUnmanaged(i32, void) = .empty,
    wake_buf: u64 = 0,
    wake_armed: bool = false,

    fn gpa() std.mem.Allocator {
        return A.gpa();
    }
    fn sqe(u: *Uw) *linux.io_uring_sqe {
        while (true) {
            return u.ring.get_sqe() catch {
                _ = u.ring.submit() catch {};
                continue;
            };
        }
    }
    fn armWake(u: *Uw) void {
        const s = u.sqe();
        s.prep_read(u.d.wake_fd[@intCast(u.w)], std.mem.asBytes(&u.wake_buf), 0);
        s.user_data = UD_WAKE;
        u.wake_armed = true;
    }
    fn fdInc(u: *Uw, fd: i32) void {
        const g = u.fdcount.getOrPut(gpa(), fd) catch A.oom();
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
    }
    /// the last CQE on fd: a CLOSE waiting for it may proceed
    fn fdDec(u: *Uw, fd: i32) void {
        const p = u.fdcount.getPtr(fd) orelse return;
        p.* -= 1;
        if (p.* != 0) return;
        _ = u.fdcount.remove(fd);
        if (u.closing.fetchRemove(fd)) |kv| u.doClose(kv.value);
    }
    fn doClose(u: *Uw, o: *UOp) void {
        const fd: i32 = @truncate(o.body.fd);
        _ = u.poisoned.remove(fd);
        const r = linux.close(fd);
        u.reply(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
    }

    fn reply(u: *Uw, o: *UOp, st: u32, res: i64, a: i64, b: i64) void {
        var in: []const u8 = &.{};
        if (st == sl.REN_DONE and o.call.op == sl.REN_OP_READ and res > 0) in = W_.bufPtr(o.body.buf)[0..@intCast(res)];
        const rr = drv.doReply(u.d, u.c, u.w, o.call.id, st, res, a, b, in);
        if (rr == sl.REN_RELEASE and st == sl.REN_DONE) {
            if (o.call.op == sl.REN_OP_READ and res > 0) {
                u.poisoned.put(gpa(), @truncate(o.body.fd), {}) catch A.oom(); // torn handle (§2.2)
            } else {
                drv.releaseFds(o.call.op, res, a, b);
            }
        }
        A.destroy(o);
    }
    fn inflight(u: *Uw, o: *UOp, fd: i32) void {
        o.fd = fd;
        u.ops.put(gpa(), o.call.id, o) catch A.oom();
        if (fd >= 0) u.fdInc(fd);
    }

    fn submit(u: *Uw, k: *const sl.ren_call) void {
        if (k.kind == sl.REN_CANCEL) {
            const o = u.ops.get(k.id) orelse return; // completed or unknown: ignore
            if (o.cancel_sent) return;
            o.cancel_sent = true;
            const s = u.sqe();
            s.prep_cancel(k.id, 0); // the original op's CQE is the final reply
            s.user_data = UD_IGNORE;
            return;
        }
        if (k.kind != sl.REN_CALL) return;
        const o = A.create(UOp);
        o.* = .{ .call = k.*, .body = @as(*const sl.ren_io_body, @ptrCast(@alignCast(k.body.?))).* }; // ptr site: call.body
        const fd: i32 = @truncate(o.body.fd);
        switch (k.op) {
            sl.REN_OP_SLEEP_UNTIL => {
                const t = o.body.arg;
                o.ts = .{ .sec = @divTrunc(t, 1_000_000_000), .nsec = @rem(t, 1_000_000_000) };
                const s = u.sqe();
                s.prep_timeout(&o.ts, 0, linux.IORING_TIMEOUT_ABS); // CLOCK_MONOTONIC is the default
                s.user_data = k.id;
                u.inflight(o, -1);
            },
            sl.REN_OP_MONO_NOW => u.reply(o, sl.REN_DONE, drv.monoNs(), 0, 0),
            sl.REN_OP_PIPE => {
                var a: i64 = 0;
                var b: i64 = 0;
                const r = drv.syncPipe(&a, &b);
                u.reply(o, sl.REN_DONE, r, a, b);
            },
            sl.REN_OP_LISTEN => {
                var port: i64 = 0;
                const r = drv.syncListen(o.body.arg, &port);
                u.reply(o, sl.REN_DONE, r, port, 0);
            },
            sl.REN_OP_READ => {
                if (u.poisoned.contains(fd)) return u.reply(o, sl.REN_DONE, -@as(i64, @intFromEnum(linux.E.IO)), 0, 0);
                const s = u.sqe();
                s.prep_read(fd, W_.bufPtr(o.body.buf)[0..@intCast(o.body.len)], std.math.maxInt(u64));
                s.user_data = k.id;
                u.inflight(o, fd);
            },
            sl.REN_OP_WRITE => {
                const s = u.sqe();
                s.prep_write(fd, W_.bufPtr(o.body.buf)[0..@intCast(o.body.len)], std.math.maxInt(u64));
                s.user_data = k.id;
                u.inflight(o, fd);
            },
            sl.REN_OP_ACCEPT => {
                const s = u.sqe();
                s.prep_accept(fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
                s.user_data = k.id;
                u.inflight(o, fd);
            },
            sl.REN_OP_CONNECT => {
                const r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
                if (linux.errno(r) != .SUCCESS) return u.reply(o, sl.REN_DONE, drv.sysErr(r), 0, 0);
                const sfd: i32 = @intCast(r);
                o.sa = drv.loopback(o.body.arg); // the sockaddr lives in the op record until the CQE
                const s = u.sqe();
                s.prep_connect(sfd, @ptrCast(&o.sa), @sizeOf(linux.sockaddr.in)); // ptr site: sockaddr_in -> sockaddr
                s.user_data = k.id;
                u.inflight(o, sfd);
            },
            sl.REN_OP_CLOSE => {
                if (u.fdcount.get(fd) orelse 0 == 0) return u.doClose(o);
                // §2.6: cancel everything on fd, close once those CQEs are in
                u.closing.put(gpa(), fd, o) catch A.oom();
                const s = u.sqe();
                s.prep_cancel_fd(fd, linux.IORING_ASYNC_CANCEL_ALL);
                s.user_data = UD_IGNORE;
            },
            else => u.reply(o, sl.REN_DONE, -@as(i64, @intFromEnum(linux.E.NOSYS)), 0, 0),
        }
    }

    fn complete(u: *Uw, cqe: linux.io_uring_cqe) void {
        if (cqe.user_data == UD_WAKE) {
            u.wake_armed = false;
            return;
        }
        if (cqe.user_data & (1 << 63) != 0) return; // a cancel's own CQE: ignored
        const kv = u.ops.fetchRemove(cqe.user_data) orelse return;
        const o = kv.value;
        var res: i64 = cqe.res;
        var st: u32 = sl.REN_DONE;
        if (res == -sl.REN_ECANCELED) {
            st = sl.REN_CANCELLED;
        } else if (o.call.op == sl.REN_OP_SLEEP_UNTIL and res == -@as(i64, @intFromEnum(linux.E.TIME))) {
            res = 0;
        }
        if (o.call.op == sl.REN_OP_CONNECT) {
            if (st == sl.REN_DONE and res == 0) res = o.fd else _ = linux.close(o.fd);
        }
        const fd = o.fd;
        u.reply(o, st, res, 0, 0);
        if (fd >= 0) u.fdDec(fd);
    }

    /// flush SQEs and (maybe) wait; DEFER_TASKRUN needs GETEVENTS to run task work
    fn enter(u: *Uw, wait_nr: u32) !void {
        const n = u.ring.flush_sq();
        _ = u.ring.enter(n, wait_nr, linux.IORING_ENTER_GETEVENTS) catch |e| switch (e) {
            error.SignalInterrupt, error.SystemResources, error.CompletionQueueOvercommitted => {},
            else => return e,
        };
    }
    fn reap(u: *Uw) void {
        var cqes: [64]linux.io_uring_cqe = undefined;
        while (true) {
            const n = u.ring.copy_cqes(&cqes, 0) catch 0;
            for (cqes[0..n]) |cq| u.complete(cq);
            if (n < cqes.len) break;
        }
    }

    fn deinit(u: *Uw) void {
        var it = u.ops.valueIterator();
        while (it.next()) |o| A.destroy(o.*);
        u.ops.deinit(gpa());
        var ic = u.closing.valueIterator();
        while (ic.next()) |o| A.destroy(o.*);
        u.closing.deinit(gpa());
        u.fdcount.deinit(gpa());
        u.poisoned.deinit(gpa());
    }
};

pub fn run(d: *drv.Drv, c: *core.Core, w: i32) i32 {
    const ring = &d.rings[@intCast(w)];
    // enabled here, so SINGLE_ISSUER binds the ring to this thread
    const er = linux.io_uring_register(ring.fd, .REGISTER_ENABLE_RINGS, null, 0);
    if (linux.errno(er) != .SUCCESS) {
        drv.setErr(d, "io_uring_register(ENABLE_RINGS): {s}", .{drv.errName(linux.errno(er))});
        return -1;
    }
    var u: Uw = .{ .d = d, .c = c, .w = w, .ring = ring };
    defer u.deinit();
    u.armWake();
    if (w == 0) drv.recDrv(d);
    var batch: std.ArrayList(sl.ren_call) = .empty;
    defer batch.deinit(A.gpa());
    var cancel_all_sent = false;
    while (true) {
        const r = core.run(c, w, d.o.steps);
        drv.recRun(d, c, w, d.o.steps, r);
        batch.clearRetainingCapacity();
        var k: sl.ren_call = .{};
        while (core.pollCall(c, w, &k)) {
            drv.recPull(d, c, w, &k);
            batch.append(A.gpa(), k) catch A.oom();
        }
        drv.recDrained(d, c, w);
        for (batch.items) |*x| u.submit(x);
        if (r == sl.REN_FINISHED and u.ops.count() == 0 and u.closing.count() == 0) break;
        if (r == sl.REN_FINISHED and !cancel_all_sent) {
            // after kill: cancel every op in flight; their CQEs are the final replies
            cancel_all_sent = true;
            var it = u.ops.valueIterator();
            while (it.next()) |o| {
                if (o.*.cancel_sent) continue;
                o.*.cancel_sent = true;
                const s = u.sqe();
                s.prep_cancel(o.*.call.id, 0);
                s.user_data = UD_IGNORE;
            }
        }
        if (!u.wake_armed) u.armWake();
        u.enter(if (r == sl.REN_RUNNING) 0 else 1) catch |e| {
            drv.setErr(d, "io_uring_enter: {s}", .{@errorName(e)});
            return -1;
        };
        u.reap();
    }
    // teardown: only after FINISHED and nothing in flight. The wake READ is still
    // armed: cancel it and wait for its CQE so the kernel never writes wake_buf
    // after this frame is gone (compio's order: drain, then close the ring).
    if (u.wake_armed) {
        const s = u.sqe();
        s.prep_cancel(UD_WAKE, 0);
        s.user_data = UD_IGNORE;
        while (u.wake_armed) {
            u.enter(1) catch break;
            u.reap();
        }
    }
    ring.deinit();
    return 0;
}
