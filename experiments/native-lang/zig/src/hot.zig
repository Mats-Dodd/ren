//! libren_hot.a: the hot path, SPEC §E, exported for W5 (variants iv, vi).
//! The signed rc protocol: rc > 0 owned and counted plainly, rc == 0
//! immortal, rc < 0 shared with -rc references counted atomically.
const std = @import("std");
const sl = @import("slice");
const opts = @import("opts");

fn renPanic(msg: []const u8, ra: ?usize) noreturn {
    _ = ra;
    _ = std.c.write(2, msg.ptr, msg.len);
    std.c.abort();
}
pub const panic = std.debug.FullPanic(renPanic);

// Zig 0.17's objects carry no .note.GNU-stack section, so GNU ld warns
// ("missing .note.GNU-stack section implies executable stack") and marks the
// whole program's stack executable. Emit the note ourselves.
comptime {
    asm (".section .note.GNU-stack,\"\",@progbits\n.previous");
}

/// The plain read of rc (SPEC §E: the same read ren_rt.h's REN_RC_PLAIN_READ
/// does). Under TSan only, a relaxed atomic load (the same mov on x86-64).
inline fn rcRead(o: *sl.ren_obj) i32 {
    return if (opts.tsan) @atomicLoad(i32, &o.rc, .monotonic) else o.rc;
}

fn dupShared(o: *sl.ren_obj) void {
    _ = @atomicRmw(i32, &o.rc, .Add, -1, .monotonic);
}
fn dropShared(o: *sl.ren_obj) void {
    if (@atomicRmw(i32, &o.rc, .Add, 1, .release) == -1) {
        // fence(ACQ): Zig 0.17 has no fence builtin; an acquire load of the
        // count (Rust's Arc does the same under TSan) synchronizes with every
        // release decrement in the count's release sequence.
        _ = @atomicLoad(i32, &o.rc, .acquire);
        sl.ren_obj_free(o);
    }
}

export fn ren_hot_dup(op: [*c]sl.ren_obj) void {
    const o: *sl.ren_obj = op.?;
    const rc = rcRead(o);
    if (rc > 0) {
        o.rc = rc + 1;
    } else if (rc != 0) {
        @branchHint(.cold);
        dupShared(o);
    }
}

export fn ren_hot_drop(op: [*c]sl.ren_obj) void {
    const o: *sl.ren_obj = op.?;
    const rc = rcRead(o);
    if (rc > 1) {
        o.rc = rc - 1;
    } else if (rc == 1) {
        @branchHint(.cold);
        sl.ren_obj_free(o);
    } else if (rc != 0) {
        @branchHint(.cold);
        dropShared(o);
    }
}

export fn ren_hot_array_grow(ap: [*c]sl.ren_array) void {
    const a: *sl.ren_array = ap.?;
    const cap: u32 = if (a.cap != 0) 2 * a.cap else 8;
    const p = std.c.realloc(a.data, @as(usize, cap) * 8) orelse {
        const m = "ren_hot_array_grow: out of memory\n";
        _ = std.c.write(2, m, m.len);
        std.c.abort();
    };
    a.data = @ptrCast(@alignCast(p)); // ptr site: realloc result -> int64 data
    a.cap = cap;
}

export fn ren_hot_array_push(ap: [*c]sl.ren_array, v: i64) void {
    const a: *sl.ren_array = ap.?;
    if (a.len == a.cap) {
        @branchHint(.unlikely);
        ren_hot_array_grow(a);
    }
    a.data[a.len] = v;
    a.len += 1;
}
