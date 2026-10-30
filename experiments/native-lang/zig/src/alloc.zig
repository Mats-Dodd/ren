//! Heap allocation (SPEC §B.1): std.heap.c_allocator in ReleaseFast and in
//! the TSan build (TSan intercepts malloc); std.heap.SafeAllocator over
//! c_allocator in Debug and ReleaseSafe. Every Op record and cancel node is
//! its own allocation, so a double free is visible to the safe allocator.
//!
//! The SafeAllocator instance is the one piece of process-wide mutable state
//! in the Zig entry (it is allocator state, like malloc's own; SafeAllocator
//! itself also keeps a global thread counter in std).
const std = @import("std");
const builtin = @import("builtin");
const opts = @import("opts");

pub const use_safe = !opts.tsan and (builtin.mode == .debug or builtin.mode == .safe);

var safe_state: std.heap.SafeAllocator = if (use_safe) .init(std.heap.c_allocator, .{}) else undefined;

pub inline fn gpa() std.mem.Allocator {
    return if (use_safe) safe_state.allocator() else std.heap.c_allocator;
}

pub fn oom() noreturn {
    @panic("ren zig: out of memory");
}

pub fn create(comptime T: type) *T {
    return gpa().create(T) catch oom();
}
pub fn destroy(p: anytype) void {
    gpa().destroy(p);
}
pub fn allocSlice(comptime T: type, n: usize) []T {
    return gpa().alloc(T, n) catch oom();
}
pub fn freeSlice(comptime T: type, s: []T) void {
    gpa().free(s);
}
