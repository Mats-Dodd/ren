//! The replay driver (SPEC §D.1) and the fuzz driver (§D.4), which is the
//! replay driver fed random bytes. Neither makes OS calls: each is a host
//! whose callbacks answer from its input.
const std = @import("std");
const sl = @import("slice");
const A = @import("alloc.zig");
const W_ = @import("wire.zig");
const core = @import("core.zig");
const drv = @import("drv.zig");

const JENT = W_.JENT;

pub const State = struct {
    core_pos: usize = 0, // file offset of the next recorded core entry
    last_core_end: usize = 0, // file offset just past the last matched core entry
    core_entry_no: usize = 0,
    diverged: i32 = 0,
    kept: std.AutoHashMapUnmanaged(u64, sl.ren_call) = .empty,
    answer: sl.ren_io_result = .{},
};

pub fn deinit(d: *drv.Drv) void {
    d.rp.kept.deinit(A.gpa());
}

const Ent = struct { kind: u32, len: u32, worker: i32, step: u64, pl: []const u8 };

fn rdEnt(d: *drv.Drv, pos: usize) ?Ent {
    if (pos + JENT > d.in.len) return null;
    const p = d.in[pos..];
    const len = W_.rd32(p[4..]);
    if (len > d.in.len - pos - JENT) return null;
    return .{ .kind = W_.rd32(p), .len = len, .worker = @bitCast(W_.rd32(p[8..])), .step = W_.rd64(p[16..]), .pl = p[JENT..][0..len] };
}

fn diverge(d: *drv.Drv, idx: usize, comptime fmt: []const u8, args: anytype) void {
    if (d.rp.diverged != 0) return;
    const i = if (idx == 0) 1 else idx;
    d.rp.diverged = @intCast(i);
    var m: [200]u8 = undefined;
    const s = std.fmt.bufPrint(&m, fmt, args) catch m[0..];
    drv.setErr(d, "replay diverged at entry {d}: {s}", .{ i, s });
}

/// advance core_pos to the next recorded core entry (kind < 16)
fn nextCore(d: *drv.Drv) ?Ent {
    while (true) {
        const e = rdEnt(d, d.rp.core_pos) orelse return null;
        if (e.kind < 16) return e;
        d.rp.core_pos += JENT + e.len;
        d.rp.core_entry_no += 1;
    }
}

/// the replaying core's journal: compare with the next recorded core entry
pub fn journal(hp: ?*anyopaque, w: i32, bytes_: ?*const anyopaque, n: usize) callconv(.c) void {
    _ = w;
    const d = drv.drvFromHost(hp);
    if (d.rp.diverged != 0) return;
    const bp: [*]const u8 = @ptrCast(bytes_.?); // ptr site: journal entry bytes
    const bytes = bp[0..n];
    const k2: u32 = if (n >= 4) W_.rd32(bytes) else 0;
    const e = nextCore(d) orelse {
        diverge(d, d.rp.core_entry_no + 1, "late end: the core wrote an entry (kind {d}) past the end of the recording", .{k2});
        return;
    };
    const idx = d.rp.core_entry_no + 1;
    const rec = d.in[d.rp.core_pos..][0 .. JENT + e.len];
    if (rec.len != n or !std.mem.eql(u8, rec, bytes)) {
        var what: []const u8 = "a field differs";
        if (k2 != e.kind) {
            what = if (e.kind == sl.REN_J_END or k2 == sl.REN_J_END) "an early or late end" else "a different entry kind";
        } else if (k2 == sl.REN_J_CALL) {
            what = "a call argument";
        } else if (k2 == sl.REN_J_DELIVER) {
            what = "a delivery (point or contents)";
        } else if (n >= 24 and !std.mem.eql(u8, rec[16..24], bytes[16..24])) {
            what = "the step (a delivery point)";
        }
        diverge(d, idx, "core entry differs: {s} (recorded kind {d}, replayed kind {d})", .{ what, e.kind, k2 });
    }
    d.rp.core_pos += JENT + e.len;
    d.rp.core_entry_no += 1;
    d.rp.last_core_end = d.rp.core_pos;
}

/// answer_now: inline iff the recorded entry right after the CALL just
/// matched is a DELIVER for this id (an inline answer is journaled inside
/// ren_world, so nothing can come between them at one worker).
pub fn answerNow(hp: ?*anyopaque, w: i32, k: [*c]const sl.ren_call, out: [*c]sl.ren_reply_t) callconv(.c) bool {
    _ = w;
    const d = drv.drvFromHost(hp);
    if (d.rp.diverged != 0) return false;
    const e = rdEnt(d, d.rp.last_core_end) orelse return false;
    if (e.kind != sl.REN_J_DELIVER or e.len < 40) return false;
    if (W_.rd64(e.pl) != k.*.id) return false;
    const blen = W_.rd32(e.pl[12..]);
    if (blen != @sizeOf(sl.ren_io_result) or e.len < 16 + blen + 4) return false;
    d.rp.answer = .{ .res = @bitCast(W_.rd64(e.pl[16..])), .a = @bitCast(W_.rd64(e.pl[24..])), .b = @bitCast(W_.rd64(e.pl[32..])) };
    out.* = .{ .id = k.*.id, .state = W_.rd32(e.pl[8..]), .len = @sizeOf(sl.ren_io_result), .body = &d.rp.answer };
    return true;
}

fn bodyOf(k: *const sl.ren_call) *const sl.ren_io_body {
    return @ptrCast(@alignCast(k.body.?)); // ptr site: call.body
}

pub fn run(d: *drv.Drv, c: *core.Core) i32 {
    var pos: usize = 0;
    var idx: usize = 0;
    // core_pos is not reset here: ren_start already journaled HEADER
    while (d.rp.diverged == 0) {
        const e = rdEnt(d, pos) orelse break;
        idx += 1;
        if (e.kind >= 16 and e.kind != sl.REN_J_DRV and (e.worker < 0 or e.worker >= d.o.workers)) {
            diverge(d, idx, "a driver entry names a worker out of range", .{});
            break;
        }
        switch (e.kind) {
            sl.REN_J_DRV => {
                if (e.len < 12 or @as(i32, @bitCast(W_.rd32(e.pl[4..]))) != d.o.workers)
                    diverge(d, idx, "J_DRV: a different worker count", .{});
            },
            sl.REN_J_RUN => {
                if (e.len != 8) {
                    diverge(d, idx, "J_RUN: bad length", .{});
                } else {
                    const r = core.run(c, e.worker, W_.rd32(e.pl));
                    if (r != @as(i32, @bitCast(W_.rd32(e.pl[4..])))) diverge(d, idx, "ren_run returned a different result", .{});
                }
            },
            sl.REN_J_PULL => {
                var k: sl.ren_call = .{};
                if (!core.pollCall(c, e.worker, &k)) {
                    diverge(d, idx, "ren_poll_call returned false; the recording pulled a call", .{});
                } else {
                    var b: W_.Buf = .{};
                    defer b.deinit();
                    W_.wireCall(&b, &k);
                    if (!std.mem.eql(u8, b.payload(), e.pl)) diverge(d, idx, "the pulled call differs (a call argument)", .{});
                    if (k.kind == sl.REN_CALL) d.rp.kept.put(A.gpa(), k.id, k) catch A.oom();
                }
            },
            sl.REN_J_DRAINED => {
                var k: sl.ren_call = .{};
                if (core.pollCall(c, e.worker, &k)) diverge(d, idx, "ren_poll_call returned a call; the recording drained", .{});
            },
            sl.REN_J_REPLY => replyEntry(d, c, e, idx),
            else => {}, // core entries are matched through the journal callback
        }
        pos += JENT + e.len;
    }
    if (d.rp.diverged == 0 and pos != d.in.len) diverge(d, idx + 1, "the recording ends inside an entry (truncated)", .{});
    if (d.rp.diverged == 0 and nextCore(d) != null)
        diverge(d, d.rp.core_entry_no + 1, "early end: recorded core entries were never produced", .{});
    return 0;
}

fn replyEntry(d: *drv.Drv, c: *core.Core, e: Ent, idx: usize) void {
    if (e.len < 16) return diverge(d, idx, "J_REPLY: bad length", .{});
    const id = W_.rd64(e.pl);
    const st = W_.rd32(e.pl[8..]);
    const blen = W_.rd32(e.pl[12..]);
    if (blen != @sizeOf(sl.ren_io_result) or e.len < 16 + blen + 4) return diverge(d, idx, "J_REPLY: bad body length", .{});
    const res: sl.ren_io_result = .{ .res = @bitCast(W_.rd64(e.pl[16..])), .a = @bitCast(W_.rd64(e.pl[24..])), .b = @bitCast(W_.rd64(e.pl[32..])) };
    const in_len = W_.rd32(e.pl[16 + blen ..]);
    if (@as(u64, e.len) != 16 + @as(u64, blen) + 4 + in_len + 4) return diverge(d, idx, "J_REPLY: bad inout length", .{});
    const inb = e.pl[20 + blen ..][0..in_len];
    const ret: i32 = @bitCast(W_.rd32(e.pl[20 + blen + in_len ..]));
    const kept = d.rp.kept.get(id);
    if (in_len > 0) {
        const k = kept orelse return diverge(d, idx, "reply bytes for a call that was never pulled", .{});
        const bd = bodyOf(&k);
        if (in_len > bd.len) return diverge(d, idx, "reply bytes longer than the call's buffer", .{});
        @memcpy(W_.bufPtr(bd.buf)[0..in_len], inb); // the driver owns the buffer
    }
    if (kept != null) _ = d.rp.kept.remove(id);
    const rp: sl.ren_reply_t = .{ .id = id, .state = st, .len = @sizeOf(sl.ren_io_result), .body = &res };
    if (core.reply(c, &rp) != ret) diverge(d, idx, "ren_reply returned a different result", .{});
}

// ================================================================== fuzz (SPEC §D.4)
const STALE_MAGIC: i64 = 0x5A1E5A1E;

const Fz = struct {
    d: *drv.Drv,
    c: *core.Core,
    pos: usize = 0,
    pend: std.ArrayList(sl.ren_call) = .empty,
    done_ids: [64]u64 = undefined,
    ndone: usize = 0,
    done_head: usize = 0,

    fn next(f: *Fz) ?u8 {
        if (f.pos >= f.d.in.len) return null;
        f.pos += 1;
        return f.d.in[f.pos - 1];
    }
    fn fail(f: *Fz, what: []const u8, id: u64, got: i32) void {
        if (f.d.fuzz_fail != 0) return;
        f.d.fuzz_fail = 1;
        drv.setErr(f.d, "fuzz oracle: {s} (id {x:0>16}, ren_reply = {d}, input offset {d})", .{ what, id, got, f.pos });
    }
    fn reply(f: *Fz, id: u64, st: u32, res: i64) i32 {
        const r: sl.ren_io_result = .{ .res = res, .a = 0, .b = 0 };
        const rp: sl.ren_reply_t = .{ .id = id, .state = st, .len = @sizeOf(sl.ren_io_result), .body = &r };
        return core.reply(f.c, &rp);
    }
    fn find(f: *Fz, id: u64) ?usize {
        for (f.pend.items, 0..) |k, i| if (k.id == id) return i;
        return null;
    }
    fn donePush(f: *Fz, id: u64) void {
        f.done_ids[f.done_head] = id;
        f.done_head = (f.done_head + 1) % 64;
        if (f.ndone < 64) f.ndone += 1;
    }
    /// RUN rule: run, then poll until false
    fn runW(f: *Fz, w: i32, steps: u32) i32 {
        const r = core.run(f.c, w, steps);
        var k: sl.ren_call = .{};
        while (core.pollCall(f.c, w, &k)) {
            if (k.kind == sl.REN_CALL) {
                f.pend.append(A.gpa(), k) catch A.oom();
            } else if (k.kind == sl.REN_CANCEL) {
                if (f.find(k.id)) |i| {
                    _ = f.pend.orderedRemove(i);
                    const rr = f.reply(k.id, sl.REN_CANCELLED, -sl.REN_ECANCELED);
                    if (rr != sl.REN_ACCEPTED) f.fail("a cancel's Cancelled reply was not ACCEPTED", k.id, rr) else f.donePush(k.id);
                }
            }
        }
        return r;
    }
};

pub fn fuzz(d: *drv.Drv, c: *core.Core) i32 {
    var f: Fz = .{ .d = d, .c = c };
    defer f.pend.deinit(A.gpa());
    const nw: u32 = @intCast(d.o.workers);
    actions: while (d.fuzz_fail == 0) {
        const a = f.next() orelse break;
        switch (a % 8) {
            0, 1 => {
                const x = f.next() orelse break :actions;
                const y = f.next() orelse break :actions;
                _ = f.runW(@intCast(x % nw), 1 + @as(u32, y % 16));
            },
            2 => {
                if (f.pend.items.len == 0) continue;
                const x = f.next() orelse break :actions;
                const k = x % f.pend.items.len;
                const y = f.next() orelse break :actions;
                const call = f.pend.items[k];
                const st: u32 = if (y & 1 != 0) sl.REN_CANCELLED else sl.REN_DONE;
                var res: i64 = -sl.REN_ECANCELED;
                const b = bodyOf(&call);
                if (st == sl.REN_DONE) {
                    const z = f.next() orelse break :actions; // input used up: the action is dropped whole
                    res = @intCast(@as(u64, z) % (b.len + 1));
                    if (call.op == sl.REN_OP_READ) {
                        const buf = W_.bufPtr(b.buf);
                        var i: usize = 0;
                        while (i < res) : (i += 1) buf[i] = @truncate(call.id +% i);
                    }
                }
                _ = f.pend.orderedRemove(k);
                const rr = f.reply(call.id, st, res);
                if (rr != sl.REN_ACCEPTED) f.fail("a reply to a pulled call was not ACCEPTED", call.id, rr) else f.donePush(call.id);
            },
            3, 4 => {
                if (f.ndone == 0) continue;
                const x = f.next() orelse break :actions;
                const id = f.done_ids[x % f.ndone];
                const rr = f.reply(id, sl.REN_DONE, STALE_MAGIC);
                if (rr != sl.REN_RELEASE) f.fail("a stale reply was ACCEPTED", id, rr);
            },
            5 => {
                var id: u64 = 0;
                var i: u6 = 0;
                while (i < 8) : (i += 1) {
                    const x = f.next() orelse break :actions;
                    id |= @as(u64, x) << (8 * i);
                    if (i == 7) break;
                }
                if (f.find(id) == null) {
                    const rr = f.reply(id, sl.REN_DONE, STALE_MAGIC);
                    if (rr != sl.REN_RELEASE) f.fail("a bogus reply was ACCEPTED", id, rr);
                }
            },
            6 => core.stop(c),
            else => {},
        }
    }
    core.stop(c);
    var round: u32 = 0;
    while (round < 10000 and d.fuzz_fail == 0) : (round += 1) {
        var fin: u32 = 0;
        var w: u32 = 0;
        while (w < nw) : (w += 1) {
            if (f.runW(@intCast(w), 64) == sl.REN_FINISHED) fin += 1;
        }
        while (f.pend.items.len != 0) {
            const call = f.pend.orderedRemove(0);
            const rr = f.reply(call.id, sl.REN_CANCELLED, -sl.REN_ECANCELED);
            if (rr != sl.REN_ACCEPTED) f.fail("a final Cancelled reply was not ACCEPTED", call.id, rr);
        }
        if (fin == nw) return 0;
    }
    if (d.fuzz_fail == 0) f.fail("no termination (a lost wakeup or a lost reply)", 0, 0);
    return 0;
}
