//! Chase-Lev deque, SPEC §A.3 line for line (Lê, Pop, Cohen, Zappa Nardelli,
//! PPoPP 2013, Fig. 1), with the spec's choices on top: signed i64 indices,
//! power-of-two rings, growth by doubling with old rings retired (never freed
//! while thieves may read them), consume as acquire.
//!
//! Zig 0.17 has no fence builtin, so (SPEC §A.3 "Zig substitution"):
//!   take:  st(bottom, b, SC) then ld(top, SC)
//!   steal: ld(top, SC)       then ld(bottom, SC)
//!   push:  fence(REL); st(bottom, RLX)  ->  st(bottom, b+1, REL)
const std = @import("std");
const opts = @import("opts");
const A = @import("alloc.zig");

/// P2 (SPEC §F) is the type of top/bottom and of every local copy (b, t).
/// PLANT=P2 makes only those u64, as SPEC §F says; Ring.cap stays i64, which
/// Zig refuses to mix with u64 (compile error). PLANT=P2u (zig-only variant,
/// bugs-zig.md) makes cap u64 too, the paper's size_t everywhere, so the
/// runtime behaviour of the plant can be tested.
pub const Idx = if (opts.plant == 2 or opts.p2u) u64 else i64;
pub const Cap = if (opts.p2u) u64 else i64;
/// P1 (SPEC §F, Zig: REL store / ACQ loads instead of the SC substitution)
const p1 = opts.plant == 1;
const ord_take_st: std.builtin.AtomicOrder = if (p1) .release else .seq_cst;
const ord_sc_ld: std.builtin.AtomicOrder = if (p1) .acquire else .seq_cst;

pub fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Ring = struct {
            cap: Cap,
            slot: []T,
            next_retired: ?*Ring,
        };
        pub const Steal = union(enum) { empty, abort, item: T };

        // top and bottom each on their own cache line
        top: Idx align(std.atomic.cache_line) = 0,
        bottom: Idx align(std.atomic.cache_line) = 0,
        array: *Ring align(std.atomic.cache_line),
        retired: ?*Ring = null, // plain, owner only

        fn newRing(cap: Cap) *Ring {
            const r = A.create(Ring);
            r.* = .{ .cap = cap, .slot = A.allocSlice(T, @intCast(cap)), .next_retired = null };
            return r;
        }

        pub fn init(self: *Self, log2: u32) void {
            const l: u6 = @intCast(if (log2 == 0) 8 else log2);
            self.* = .{ .array = newRing(@as(Cap, 1) << l) };
        }

        pub fn deinit(self: *Self) void {
            var r: ?*Ring = self.retired;
            while (r) |x| {
                r = x.next_retired;
                A.freeSlice(T, x.slot);
                A.destroy(x);
            }
            const a = self.array;
            A.freeSlice(T, a.slot);
            A.destroy(a);
        }

        inline fn at(a: *Ring, i: Idx) *T {
            return &a.slot[@intCast(i & (a.cap - 1))];
        }

        pub fn push(q: *Self, x: T) void {
            const b = @atomicLoad(Idx, &q.bottom, .monotonic);
            const t = @atomicLoad(Idx, &q.top, .acquire);
            var a = @atomicLoad(*Ring, &q.array, .monotonic);
            if (b - t > a.cap - 1) a = q.grow(a, t, b);
            @atomicStore(T, at(a, b), x, .monotonic);
            // fence(REL); st(bottom, b+1, RLX)  ==  st(bottom, b+1, REL) in Zig
            @atomicStore(Idx, &q.bottom, b + 1, .release);
        }

        fn grow(q: *Self, a: *Ring, t: Idx, b: Idx) *Ring {
            const n = newRing(2 * a.cap);
            var i = t;
            while (i < b) : (i += 1) {
                @atomicStore(T, at(n, i), @atomicLoad(T, at(a, i), .monotonic), .monotonic);
            }
            a.next_retired = q.retired;
            q.retired = a; // never freed while thieves may read it
            @atomicStore(*Ring, &q.array, n, .release); // pairs with steal's ACQ load
            return n;
        }

        pub fn take(q: *Self) ?T {
            const b = @atomicLoad(Idx, &q.bottom, .monotonic) - 1; // -1 on a fresh deque: fine
            const a = @atomicLoad(*Ring, &q.array, .monotonic);
            @atomicStore(Idx, &q.bottom, b, ord_take_st); // fence(SC) substitute, part 1 (← P1: .release)
            const t = @atomicLoad(Idx, &q.top, ord_sc_ld); // fence(SC) substitute, part 2 (← P1: .acquire)
            if (t <= b) {
                var x: ?T = @atomicLoad(T, at(a, b), .monotonic);
                if (t == b) {
                    if (@cmpxchgStrong(Idx, &q.top, t, t + 1, .seq_cst, .monotonic) != null) x = null;
                    @atomicStore(Idx, &q.bottom, b + 1, .monotonic);
                }
                return x;
            } else {
                @atomicStore(Idx, &q.bottom, b + 1, .monotonic);
                return null;
            }
        }

        pub fn steal(q: *Self) Steal {
            const t = @atomicLoad(Idx, &q.top, ord_sc_ld); // ld(top, ACQ) + fence(SC) substitute (← P1: .acquire)
            const b = @atomicLoad(Idx, &q.bottom, ord_sc_ld); // ld(bottom, ACQ) + fence(SC) substitute (← P1: .acquire)
            if (t < b) {
                const a = @atomicLoad(*Ring, &q.array, .acquire); // paper: consume
                const x = @atomicLoad(T, at(a, t), .monotonic);
                if (@cmpxchgStrong(Idx, &q.top, t, t + 1, .seq_cst, .monotonic) != null) return .abort;
                return .{ .item = x };
            }
            return .empty;
        }

        /// try_park's emptiness probe (SPEC §B.6)
        pub fn nonEmpty(q: *Self) bool {
            return @atomicLoad(Idx, &q.bottom, .acquire) - @atomicLoad(Idx, &q.top, .acquire) > 0;
        }
    };
}
