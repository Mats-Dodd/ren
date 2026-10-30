//! Little-endian field-by-field encoding of journal entries (SPEC §B.7).
//! Never a struct copy: every multi-byte field is written on its own from
//! the translate-c types, so a field inserted into a slice.h struct cannot
//! move the wire.
const std = @import("std");
const sl = @import("slice");
const A = @import("alloc.zig");

pub const JENT: usize = sl.REN_JENT_BYTES;

pub const Buf = struct {
    small: [512]u8 = undefined,
    heap: ?[]u8 = null,
    n: usize = JENT, // the 24-byte header is filled by finish()

    pub fn data(b: *Buf) []u8 {
        return if (b.heap) |h| h else b.small[0..];
    }
    fn room(b: *Buf, k: usize) void {
        const cap = b.data().len;
        if (b.n + k <= cap) return;
        const ncap = (b.n + k) * 2;
        const nb = A.allocSlice(u8, ncap);
        @memcpy(nb[0..b.n], b.data()[0..b.n]);
        if (b.heap) |h| A.freeSlice(u8, h);
        b.heap = nb;
    }
    pub fn deinit(b: *Buf) void {
        if (b.heap) |h| A.freeSlice(u8, h);
        b.heap = null;
    }
    pub fn int(b: *Buf, comptime T: type, v: T) void {
        b.room(@sizeOf(T));
        std.mem.writeInt(T, b.data()[b.n..][0..@sizeOf(T)], v, .little);
        b.n += @sizeOf(T);
    }
    pub fn u16_(b: *Buf, v: u16) void {
        b.int(u16, v);
    }
    pub fn u32_(b: *Buf, v: u32) void {
        b.int(u32, v);
    }
    pub fn u64_(b: *Buf, v: u64) void {
        b.int(u64, v);
    }
    pub fn i64_(b: *Buf, v: i64) void {
        b.int(u64, @bitCast(v));
    }
    pub fn bytes(b: *Buf, s: []const u8) void {
        b.room(s.len);
        @memcpy(b.data()[b.n..][0..s.len], s);
        b.n += s.len;
    }
    /// Write the ren_jent header in place; returns the whole entry.
    pub fn finish(b: *Buf, kind: u32, worker: i32, step: u64) []const u8 {
        const d = b.data();
        std.mem.writeInt(u32, d[0..4], kind, .little);
        std.mem.writeInt(u32, d[4..8], @intCast(b.n - JENT), .little);
        std.mem.writeInt(i32, d[8..12], worker, .little);
        std.mem.writeInt(u32, d[12..16], 0, .little);
        std.mem.writeInt(u64, d[16..24], step, .little);
        return d[0..b.n];
    }
    /// The payload only (for comparisons).
    pub fn payload(b: *Buf) []const u8 {
        return b.data()[JENT..b.n];
    }
};

pub fn fnv1a(p: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (p) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return h;
}

/// A buffer address carried as an integer in ren_io_body.buf (slice.h §4).
pub fn bufPtr(addr: u64) [*]u8 {
    return @ptrFromInt(@as(usize, @intCast(addr))); // ptr site: body.buf -> pointer
}

/// The wire call (REN_JCALL_BYTES) + body (buf = 0) + out_hash: the CALL and
/// J_PULL payload.
pub fn wireCall(b: *Buf, k: *const sl.ren_call) void {
    b.u64_(k.id);
    b.u16_(k.worker);
    b.u16_(k.kind);
    b.u32_(k.lane);
    b.u32_(k.task);
    b.u32_(k.op);
    b.u32_(k.len);
    var h: u64 = 0;
    if (k.kind == sl.REN_CALL) {
        if (k.body) |bp| {
            const body: *const sl.ren_io_body = @ptrCast(@alignCast(bp)); // ptr site: call.body
            b.i64_(body.fd);
            b.u64_(body.len);
            b.u64_(0); // buf: pointers differ between runs
            b.i64_(body.arg);
            if (k.op == sl.REN_OP_WRITE and body.len != 0) h = fnv1a(bufPtr(body.buf)[0..@intCast(body.len)]);
        }
    }
    b.u64_(h);
}

pub fn rd32(p: []const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
pub fn rd64(p: []const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}
