//! What every Zig driver shares (SPEC §C.1, §D): the ren_drv_* entry points,
//! the recorder, driver-entry encoding, answer_now / wake for the kernel
//! drivers, and the synchronous ops (PIPE, LISTEN).
const std = @import("std");
const linux = std.os.linux;
const sl = @import("slice");
const A = @import("alloc.zig");
const W_ = @import("wire.zig");
const core = @import("core.zig");
const epoll = @import("epoll.zig");
const uring = @import("uring.zig");
const replay = @import("replay.zig");

pub const Drv = struct {
    o: sl.ren_drv_opts,
    host: sl.ren_host = .{},
    err: [256:0]u8 = @splat(0),
    // recording
    rec_mu: std.atomic.Mutex = .unlocked,
    rec_buf: std.ArrayList(u8) = .empty,
    rec_failed: i32 = 0,
    // kernel drivers
    wake_fd: []i32 = &.{},
    ans: []sl.ren_io_result = &.{},
    rings: []linux.IoUring = &.{},
    uring_fallback: bool = false,
    // replay and fuzz
    in: []const u8 = &.{},
    rp: replay.State = .{},
    fuzz_fail: i32 = 0,
};

var global_err: [160:0]u8 = @splat(0); // ren_drv_last_error(NULL): why ren_drv_new failed

pub fn setErr(d: ?*Drv, comptime fmt: []const u8, args: anytype) void {
    const buf: []u8 = if (d) |x| x.err[0 .. x.err.len - 1] else global_err[0 .. global_err.len - 1];
    const s = std.fmt.bufPrint(buf, fmt, args) catch buf[0..buf.len];
    buf.ptr[s.len] = 0;
}
pub fn errName(e: linux.E) []const u8 {
    return @tagName(e);
}
pub fn sysErr(r: usize) i64 {
    // a raw syscall result as res: n >= 0, or -errno
    const e = linux.errno(r);
    if (e != .SUCCESS) return -@as(i64, @intFromEnum(e));
    return @intCast(r);
}

pub inline fn drvOf(d: ?*sl.ren_drv) *Drv {
    return @ptrCast(@alignCast(d.?)); // ptr site: opaque ren_drv -> Drv
}
pub inline fn drvFromHost(hp: ?*anyopaque) *Drv {
    return @ptrCast(@alignCast(hp.?)); // ptr site: host pointer -> Drv
}

// ------------------------------------------------------------------ recording (SPEC §C.1)
pub fn recording(d: *Drv) bool {
    return d.o.record_fd >= 0;
}
fn recLock(d: *Drv) void {
    while (!d.rec_mu.tryLock()) std.atomic.spinLoopHint();
}
fn flushLocked(d: *Drv) void {
    var off: usize = 0;
    const b = d.rec_buf.items;
    while (off < b.len) {
        const r = linux.write(d.o.record_fd, b[off..].ptr, b.len - off);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS) {
            d.rec_failed = @intFromEnum(e);
            break;
        }
        off += r;
    }
    d.rec_buf.clearRetainingCapacity();
}
fn recAppend(d: *Drv, bytes: []const u8) void {
    recLock(d);
    defer d.rec_mu.unlock();
    d.rec_buf.appendSlice(A.gpa(), bytes) catch A.oom();
    if (d.rec_buf.items.len >= 1 << 16) flushLocked(d);
}
pub fn recFlush(d: *Drv) void {
    if (!recording(d)) return;
    recLock(d);
    defer d.rec_mu.unlock();
    flushLocked(d);
}
/// the core's entries, verbatim
fn hostJournalRec(hp: ?*anyopaque, w: i32, e: ?*const anyopaque, n: usize) callconv(.c) void {
    _ = w;
    const d = drvFromHost(hp);
    const p: [*]const u8 = @ptrCast(e.?); // ptr site: journal entry bytes
    recAppend(d, p[0..n]);
}
pub fn recEntry(d: *Drv, b: *W_.Buf, kind: u32, w: i32, step: u64) void {
    const e = b.finish(kind, w, step);
    recAppend(d, e);
    b.deinit();
}
pub fn recDrv(d: *Drv) void {
    if (!recording(d)) return;
    var b: W_.Buf = .{};
    b.u32_(d.o.kind);
    b.u32_(@bitCast(d.o.workers));
    b.u32_(d.o.steps);
    recEntry(d, &b, sl.REN_J_DRV, 0, 0);
}
pub fn recRun(d: *Drv, c: *core.Core, w: i32, steps: u32, ret: i32) void {
    if (!recording(d)) return;
    var b: W_.Buf = .{};
    b.u32_(steps);
    b.u32_(@bitCast(ret));
    recEntry(d, &b, sl.REN_J_RUN, w, core.progress(c, w));
}
pub fn recPull(d: *Drv, c: *core.Core, w: i32, k: *const sl.ren_call) void {
    if (!recording(d)) return;
    var b: W_.Buf = .{};
    W_.wireCall(&b, k);
    recEntry(d, &b, sl.REN_J_PULL, w, core.progress(c, w));
}
pub fn recDrained(d: *Drv, c: *core.Core, w: i32) void {
    if (!recording(d)) return;
    var b: W_.Buf = .{};
    recEntry(d, &b, sl.REN_J_DRAINED, w, core.progress(c, w));
}
/// ren_reply + J_REPLY; returns ren_reply's result
pub fn doReply(d: *Drv, c: *core.Core, w: i32, id: u64, state: u32, res: i64, a: i64, bb: i64, in: []const u8) i32 {
    const r: sl.ren_io_result = .{ .res = res, .a = a, .b = bb };
    const rp: sl.ren_reply_t = .{ .id = id, .state = state, .len = @sizeOf(sl.ren_io_result), .body = &r };
    const ret = core.reply(c, &rp);
    if (recording(d)) {
        var b: W_.Buf = .{};
        b.u64_(id);
        b.u32_(state);
        b.u32_(@sizeOf(sl.ren_io_result));
        b.i64_(r.res);
        b.i64_(r.a);
        b.i64_(r.b);
        b.u32_(@intCast(in.len));
        b.bytes(in);
        b.u32_(@bitCast(ret));
        recEntry(d, &b, sl.REN_J_REPLY, w, core.progress(c, w));
    }
    return ret;
}

// ------------------------------------------------------------------ host callbacks (kernel drivers)
pub fn monoNs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1_000_000_000 + ts.nsec;
}
fn hostAnswerNow(hp: ?*anyopaque, w: i32, k: [*c]const sl.ren_call, out: [*c]sl.ren_reply_t) callconv(.c) bool {
    const d = drvFromHost(hp);
    if (k.*.op != sl.REN_OP_MONO_NOW) return false;
    const r = &d.ans[@intCast(w)]; // per worker: ren_world copies it at once
    r.* = .{ .res = monoNs(), .a = 0, .b = 0 };
    out.* = .{ .id = k.*.id, .state = sl.REN_DONE, .len = @sizeOf(sl.ren_io_result), .body = r };
    return true;
}
fn hostWake(hp: ?*anyopaque, w: i32) callconv(.c) void {
    const d = drvFromHost(hp);
    const one: u64 = 1;
    while (true) {
        const r = linux.write(d.wake_fd[@intCast(w)], std.mem.asBytes(&one), 8);
        if (linux.errno(r) != .INTR) return; // EAGAIN: the counter is already set: still sticky
    }
}
fn wakeNop(hp: ?*anyopaque, w: i32) callconv(.c) void {
    _ = hp;
    _ = w;
}

// ------------------------------------------------------------------ synchronous ops
pub fn syncPipe(a: *i64, b: *i64) i64 {
    var fds: [2]i32 = undefined;
    const r = linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true });
    if (linux.errno(r) != .SUCCESS) return sysErr(r);
    a.* = fds[0];
    b.* = fds[1];
    return 0;
}
pub fn loopback(port: i64) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, @truncate(@as(u64, @bitCast(port)))), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
}
pub fn syncListen(port: i64, bound: *i64) i64 {
    const r = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(r) != .SUCCESS) return sysErr(r);
    const fd: i32 = @intCast(r);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), 4);
    var sa = loopback(port);
    var e = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)); // ptr site: sockaddr_in -> sockaddr
    if (linux.errno(e) == .SUCCESS) e = linux.listen(fd, 128);
    if (linux.errno(e) != .SUCCESS) {
        _ = linux.close(fd);
        return sysErr(e);
    }
    var sl_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    e = linux.getsockname(fd, @ptrCast(&sa), &sl_len); // ptr site: sockaddr_in -> sockaddr
    if (linux.errno(e) != .SUCCESS) {
        _ = linux.close(fd);
        return sysErr(e);
    }
    bound.* = std.mem.bigToNative(u16, sa.port);
    return fd;
}
/// close what the driver created for a call whose reply was RELEASEd (SPEC §C.1
/// release(); as the C entry, also the fds of a released PIPE/LISTEN/CONNECT)
pub fn releaseFds(op: u32, res: i64, a: i64, b: i64) void {
    switch (op) {
        sl.REN_OP_ACCEPT, sl.REN_OP_LISTEN, sl.REN_OP_CONNECT => if (res >= 0) {
            _ = linux.close(@intCast(res));
        },
        sl.REN_OP_PIPE => if (res == 0) {
            _ = linux.close(@intCast(a));
            _ = linux.close(@intCast(b));
        },
        else => {},
    }
}

// ------------------------------------------------------------------ entry points
pub fn new(op: [*c]const sl.ren_drv_opts) ?*sl.ren_drv {
    if (op == null) {
        setErr(null, "ren_drv_new: NULL options", .{});
        return null;
    }
    const o = op.*;
    if (o.workers < 1 or o.workers > 64) {
        setErr(null, "ren_drv_new: workers {d} out of range", .{o.workers});
        return null;
    }
    const d = A.create(Drv);
    d.* = .{ .o = o };
    if (d.o.steps == 0) d.o.steps = 256;
    const nw: usize = @intCast(o.workers);
    switch (o.kind) {
        sl.REN_DRV_EPOLL, sl.REN_DRV_URING => {
            d.host.wake = hostWake;
            d.host.answer_now = hostAnswerNow;
            d.host.journal = if (recording(d)) hostJournalRec else null;
            d.ans = A.allocSlice(sl.ren_io_result, nw);
            d.wake_fd = A.allocSlice(i32, nw);
            for (d.wake_fd) |*f| f.* = -1;
            for (d.wake_fd) |*f| {
                const r = linux.eventfd(0, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
                if (linux.errno(r) != .SUCCESS) {
                    setErr(null, "eventfd: {s}", .{errName(linux.errno(r))});
                    freeDrv(d);
                    return null;
                }
                f.* = @intCast(r);
            }
            if (o.kind == sl.REN_DRV_URING) {
                if (!uring.setup(d)) {
                    setErr(null, "{s}", .{std.mem.sliceTo(&d.err, 0)});
                    freeDrv(d);
                    return null;
                }
            }
        },
        sl.REN_DRV_REPLAY => {
            d.in = if (o.input) |p| p[0..o.input_len] else &.{};
            d.host.wake = wakeNop;
            d.host.answer_now = replay.answerNow;
            d.host.journal = replay.journal;
        },
        sl.REN_DRV_FUZZ => {
            d.in = if (o.input) |p| p[0..o.input_len] else &.{};
            d.host.wake = wakeNop;
        },
        else => {
            setErr(null, "ren_drv_new: unknown driver kind {d}", .{o.kind});
            freeDrv(d);
            return null;
        },
    }
    return @ptrCast(d); // ptr site: Drv -> opaque ren_drv
}

pub fn host(dp: ?*sl.ren_drv, hostp: [*c]?*anyopaque) [*c]const sl.ren_host {
    const d = drvOf(dp);
    hostp.* = d;
    return &d.host;
}

pub fn worker(dp: ?*sl.ren_drv, cp: ?*sl.ren_core, w: i32) i32 {
    const d = drvOf(dp);
    const c = core.coreOf(cp);
    switch (d.o.kind) {
        sl.REN_DRV_EPOLL, sl.REN_DRV_URING => {
            if (w < 0 or w >= d.o.workers) {
                setErr(d, "worker {d} out of range", .{w});
                return -1;
            }
            return if (d.o.kind == sl.REN_DRV_EPOLL) epoll.run(d, c, w) else uring.run(d, c, w);
        },
        sl.REN_DRV_REPLAY, sl.REN_DRV_FUZZ => {
            if (w != -1) {
                setErr(d, "replay/fuzz drive every worker: worker must be -1", .{});
                return -1;
            }
            return if (d.o.kind == sl.REN_DRV_REPLAY) replay.run(d, c) else replay.fuzz(d, c);
        },
        else => return -1,
    }
}

pub fn finish(dp: ?*sl.ren_drv, cp: ?*sl.ren_core) i32 {
    _ = cp;
    const d = drvOf(dp);
    recFlush(d);
    if (d.rec_failed != 0) {
        setErr(d, "record: write failed: errno {d}", .{d.rec_failed});
        return -1;
    }
    if (d.o.kind == sl.REN_DRV_REPLAY) return d.rp.diverged;
    if (d.o.kind == sl.REN_DRV_FUZZ) return d.fuzz_fail;
    return 0;
}

fn freeDrv(d: *Drv) void {
    if (d.o.kind == sl.REN_DRV_URING) uring.teardownAll(d);
    for (d.wake_fd) |f| if (f >= 0) {
        _ = linux.close(f);
    };
    if (d.wake_fd.len != 0) A.freeSlice(i32, d.wake_fd);
    if (d.ans.len != 0) A.freeSlice(sl.ren_io_result, d.ans);
    replay.deinit(d);
    d.rec_buf.deinit(A.gpa());
    A.destroy(d);
}
pub fn free(dp: ?*sl.ren_drv) void {
    if (dp == null) return;
    freeDrv(drvOf(dp));
}
pub fn lastError(dp: ?*sl.ren_drv) [*c]const u8 {
    if (dp == null) return &global_err;
    return &drvOf(dp).err;
}
