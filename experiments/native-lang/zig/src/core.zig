//! The sans-I/O core, SPEC §B: the nine host functions, the seven
//! emitted-code functions, the op table, park/wake and the core's journal.
//! Every atomic ordering is SPEC's. Zig 0.17 has no fence builtin: the
//! deque uses SPEC §A.3's SC-access substitution; every other fence(SC) in
//! §B (ren_world, ren_stop, try_park, wake_*) is fenceSC() below, the same
//! instruction C's atomic_thread_fence(seq_cst) lowers to.
const std = @import("std");
const builtin = @import("builtin");
const sl = @import("slice");
const opts = @import("opts");
const A = @import("alloc.zig");
const W_ = @import("wire.zig");
const DQ = @import("dq.zig");

pub const Task = sl.ren_task;
const TaskDeque = DQ.Deque(*Task);

const safety = std.debug.runtime_safety;

// ---- slot states (SPEC §B.3) ----
const FREE: u64 = 0;
const ISSUED: u64 = 1;
const PULLED: u64 = 2;
const CANCEL_UNPULLED: u64 = 3;
const CANCEL_PULLED: u64 = 4;
const REPLIED: u64 = 5;
// ---- task scheduling word (SPEC §B.2) ----
const QUEUED: usize = 1;
const RUNNING: usize = 2;
const PARKED: usize = 3;
const DONE: usize = 4;
const NOTIFIED: usize = 8;

pub fn fenceSC() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("mfence" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb ish" ::: .{ .memory = true }),
        else => @compileError("fenceSC: unsupported architecture"),
    }
}
inline fn cpuRelax() void {
    std.atomic.spinLoopHint();
}

pub const Op = struct {
    next: ?*Op = null,
    slot: u32,
    gen: u32,
    home: u16,
    had_cancel: bool = false,
    task: *Task,
    aw: *sl.ren_await,
    call: sl.ren_call,
    body: sl.ren_io_body,
    reply_state: u32 = 0,
    reply: sl.ren_io_result = .{},
};

const CancelNode = struct {
    next: ?*CancelNode = null,
    id: u64,
};

const Slot = struct {
    word: u64, // gen:32 (high) | state:32 (low)
    op: ?*Op = null, // plain; see SPEC §B.3
};

pub const Ctx = struct {
    core: *Core,
    worker: i32,
    points: u32 = 0,
    cur: ?*Task = null,
};

fn Fifo(comptime T: type) type {
    return struct {
        head: ?*T = null,
        tail: ?*T = null,
        fn pushBack(f: *@This(), x: *T) void {
            x.next = null;
            if (f.tail) |t| t.next = x else f.head = x;
            f.tail = x;
        }
        fn popFront(f: *@This()) ?*T {
            const h = f.head orelse return null;
            f.head = h.next;
            if (f.head == null) f.tail = null;
            h.next = null;
            return h;
        }
        /// append a list already in FIFO order
        fn appendAll(f: *@This(), l: ?*T) void {
            var p = l;
            while (p) |x| {
                p = x.next;
                f.pushBack(x);
            }
        }
    };
}

/// MPSC stack push (SPEC §B.1)
fn mpscPush(comptime T: type, head: *?*T, n: *T) void {
    while (true) {
        const h = @atomicLoad(?*T, head, .monotonic);
        n.next = h;
        if (@cmpxchgWeak(?*T, head, h, n, .release, .monotonic) == null) break;
    }
}
/// take_all: the whole list, reversed into arrival order
fn mpscTakeAll(comptime T: type, head: *?*T) ?*T {
    var l = @atomicRmw(?*T, head, .Xchg, null, .acquire);
    var r: ?*T = null;
    while (l) |x| {
        l = x.next;
        x.next = r;
        r = x;
    }
    return r;
}

const Worker = struct {
    dq: TaskDeque,
    // shared, atomic
    parked: i32 align(std.atomic.cache_line) = 0,
    steps: u64 = 0,
    stolen_from: u64 = 0, // ← P5 makes every access plain (stealAny, run)
    inbox: ?*Op = null,
    remote: ?*CancelNode = null,
    // owner only
    stolen_seen: u64 align(std.atomic.cache_line) = 0,
    cancels: Fifo(CancelNode) = .{},
    outbox: Fifo(Op) = .{},
    free: []u32,
    nfree: u32,
    rng: u64,
    spawn_seq: u32 = 0,
    last_poll: u64 = 0,
    drained: bool = false,
    runs: u64 = 0,
    stack_lo: usize = 0,
    stack_size: usize = 0,
    cancel_done: u64 = 0, // on_cancel_done's plain counter
    cx: Ctx,
};

const Injector = struct {
    lock: i32 align(std.atomic.cache_line) = 0,
    head: ?*Task = null,
    tail: ?*Task = null,
    len: i64 = 0,
};

pub const Core = struct {
    cfg: sl.ren_config,
    host: sl.ren_host,
    hostp: ?*anyopaque,
    nw: i32,
    S: u32,
    B: u32,
    K: u32,
    W: []Worker,
    slots: []Slot,
    inj: Injector = .{},
    live: i64 align(std.atomic.cache_line) = 0,
    stopping: i32 = 0,
    killed: i32 = 0,
    done: i32 = 0,
    idle: i32 = 0,
};

// ------------------------------------------------------------------ casts
pub inline fn coreOf(c: ?*sl.ren_core) *Core {
    return @ptrCast(@alignCast(c.?)); // ptr site: opaque ren_core -> Core
}
inline fn ctxOf(cx: ?*sl.ren_ctx) *Ctx {
    return @ptrCast(@alignCast(cx.?)); // ptr site: opaque ren_ctx -> Ctx
}
inline fn ctxPtr(cx: *Ctx) *sl.ren_ctx {
    return @ptrCast(cx); // ptr site: Ctx -> opaque ren_ctx
}
inline fn taskOf(t: [*c]sl.ren_task) *Task {
    return @ptrCast(t.?); // [*c] -> single pointer (no address arithmetic)
}
inline fn sched(t: *Task) *usize {
    return &t.core[0];
}
inline fn link(t: *Task) *usize {
    return &t.core[1];
}
inline fn wk(c: *Core, w: i32) *Worker {
    return &c.W[@intCast(w)];
}
inline fn nextGen(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}
inline fn word(g: u32, st: u64) u64 {
    return (@as(u64, g) << 32) | st;
}

// ------------------------------------------------------------------ journal (SPEC §B.7)
fn jemit(c: *Core, b: *W_.Buf, kind: u32, w: i32) void {
    const step: u64 = if (w >= 0) @atomicLoad(u64, &wk(c, w).steps, .monotonic) else 0;
    const e = b.finish(kind, w, step);
    c.host.journal.?(c.hostp, w, e.ptr, e.len);
    b.deinit();
}
fn jHeader(c: *Core) void {
    if (c.host.journal == null) return;
    var b: W_.Buf = .{};
    const bid: []const u8 = if (c.cfg.build_id) |p| std.mem.span(p) else "";
    b.u32_(sl.REN_SLICE_VERSION);
    b.u32_(@intCast(c.nw));
    b.u32_(c.B);
    b.u32_(c.K);
    b.u32_(c.cfg.journal_policy);
    b.u32_(@intCast(bid.len));
    b.bytes(bid);
    jemit(c, &b, sl.REN_J_HEADER, -1);
}
fn jCall(c: *Core, w: i32, k: *const sl.ren_call) void {
    if (c.host.journal == null) return;
    var b: W_.Buf = .{};
    W_.wireCall(&b, k);
    jemit(c, &b, sl.REN_J_CALL, w);
}
fn jDeliver(c: *Core, w: i32, id: u64, state: u32, r: *const sl.ren_io_result, in: []const u8) void {
    if (c.host.journal == null) return;
    var b: W_.Buf = .{};
    b.u64_(id);
    b.u32_(state);
    b.u32_(@sizeOf(sl.ren_io_result));
    b.i64_(r.res);
    b.i64_(r.a);
    b.i64_(r.b);
    b.u32_(@intCast(in.len));
    b.bytes(in);
    jemit(c, &b, sl.REN_J_DELIVER, w);
}
fn jIdHow(c: *Core, kind: u32, w: i32, id: u64, how: u32) void {
    if (c.host.journal == null) return;
    var b: W_.Buf = .{};
    b.u64_(id);
    b.u32_(how);
    jemit(c, &b, kind, w);
}
fn jEnd(c: *Core, w: i32, how: u32) void {
    if (c.host.journal == null) return;
    var b: W_.Buf = .{};
    b.u32_(how);
    jemit(c, &b, sl.REN_J_END, w);
}

// ------------------------------------------------------------------ injector
fn injLock(q: *Injector) void {
    while (@atomicRmw(i32, &q.lock, .Xchg, 1, .acquire) != 0) {
        while (@atomicLoad(i32, &q.lock, .monotonic) != 0) cpuRelax();
    }
}
fn injUnlock(q: *Injector) void {
    @atomicStore(i32, &q.lock, 0, .release);
}
fn injPush(c: *Core, t: *Task) void {
    const q = &c.inj;
    injLock(q);
    link(t).* = 0;
    if (q.tail) |tl| link(tl).* = @intFromPtr(t) else q.head = t; // ptr site: link word
    q.tail = t;
    _ = @atomicRmw(i64, &q.len, .Add, 1, .monotonic);
    injUnlock(q);
}
fn injPop(c: *Core) ?*Task {
    const q = &c.inj;
    if (@atomicLoad(i64, &q.len, .monotonic) == 0) return null;
    injLock(q);
    const t = q.head;
    if (t) |x| {
        q.head = @ptrFromInt(link(x).*); // ptr site: link word -> task
        if (q.head == null) q.tail = null;
        _ = @atomicRmw(i64, &q.len, .Add, -1, .monotonic);
    }
    injUnlock(q);
    return t;
}

// ------------------------------------------------------------------ park and wake (SPEC §B.6)
fn tryPark(c: *Core, w: i32) bool {
    const me = wk(c, w);
    @atomicStore(i32, &me.parked, 1, .seq_cst);
    _ = @atomicRmw(i32, &c.idle, .Add, 1, .seq_cst);
    fenceSC();
    var work = @atomicLoad(?*Op, &me.inbox, .acquire) != null or @atomicLoad(i64, &c.inj.len, .monotonic) > 0;
    if (!work) {
        for (c.W) |*v| {
            if (v.dq.nonEmpty()) {
                work = true;
                break;
            }
        }
    }
    if (work or @atomicLoad(i32, &c.done, .acquire) != 0 or @atomicLoad(i32, &c.killed, .acquire) != 0) {
        if (@atomicRmw(i32, &me.parked, .Xchg, 0, .acq_rel) == 1) _ = @atomicRmw(i32, &c.idle, .Add, -1, .monotonic);
        return false;
    }
    return true;
}
fn wakeWorker(c: *Core, v: i32) void {
    fenceSC();
    const x = wk(c, v);
    if (@atomicLoad(i32, &x.parked, .monotonic) == 1 and
        @cmpxchgStrong(i32, &x.parked, 1, 0, .acq_rel, .monotonic) == null)
    {
        _ = @atomicRmw(i32, &c.idle, .Add, -1, .monotonic);
        c.host.wake.?(c.hostp, v);
    }
}
fn wakeOne(c: *Core, w: i32) void {
    fenceSC();
    if (@atomicLoad(i32, &c.idle, .monotonic) == 0) return;
    var i: i32 = 1;
    while (i <= c.nw) : (i += 1) {
        const v = @mod(w + i, c.nw); // w itself last
        const x = wk(c, v);
        if (@atomicLoad(i32, &x.parked, .monotonic) == 1 and
            @cmpxchgStrong(i32, &x.parked, 1, 0, .acq_rel, .monotonic) == null)
        {
            _ = @atomicRmw(i32, &c.idle, .Add, -1, .monotonic);
            c.host.wake.?(c.hostp, v);
            return;
        }
    }
}
fn wakeAll(c: *Core) void {
    var v: i32 = 0;
    while (v < c.nw) : (v += 1) {
        if (@cmpxchgStrong(i32, &wk(c, v).parked, 1, 0, .acq_rel, .monotonic) == null) {
            _ = @atomicRmw(i32, &c.idle, .Add, -1, .monotonic);
            c.host.wake.?(c.hostp, v);
        }
    }
}

// ------------------------------------------------------------------ tasks (SPEC §B.2)
fn finish(c: *Core, w: i32) void {
    jEnd(c, w, 0);
    @atomicStore(i32, &c.done, 1, .release);
    wakeAll(c);
}
fn taskDone(c: *Core, w: i32, t: *Task) void {
    sl.ren_rc_drop(&t.obj); // the core's reference (fin runs inside, at 0)
    if (@atomicRmw(i64, &c.live, .Add, -1, .acq_rel) == 1) finish(c, w);
}
fn notify(c: *Core, w: i32, t: *Task) void {
    const s = @atomicRmw(usize, sched(t), .Or, NOTIFIED, .acq_rel);
    if (s == PARKED) { // exactly one notifier sees PARKED without the flag
        _ = @atomicRmw(usize, sched(t), .Xchg, QUEUED, .acq_rel);
        wk(c, w).dq.push(t);
        wakeOne(c, w);
    }
}
fn runTask(c: *Core, w: i32, t: *Task) void {
    const me = wk(c, w);
    const prev = @atomicRmw(usize, sched(t), .Xchg, RUNNING, .acq_rel);
    if (safety and prev & ~NOTIFIED != QUEUED) {
        var m: [96]u8 = undefined;
        @panic(std.fmt.bufPrint(&m, "run_task: task {d} picked in state {d} (not QUEUED)", .{ t.id, prev }) catch "run_task: bad state");
    }
    const cx = &me.cx;
    cx.points = 0;
    cx.cur = t;
    const r = t.@"resume".?(t, ctxPtr(cx));
    // entries written during the resume carry the old value
    @atomicStore(u64, &me.steps, @atomicLoad(u64, &me.steps, .monotonic) + 1, .monotonic);
    cx.cur = null;
    switch (r) {
        sl.REN_T_DONE => {
            _ = @atomicRmw(usize, sched(t), .Xchg, DONE, .acq_rel);
            taskDone(c, w, t);
        },
        sl.REN_T_PARK => {
            if (@cmpxchgStrong(usize, sched(t), RUNNING, PARKED, .acq_rel, .acquire) != null) {
                // a notify came while running
                _ = @atomicRmw(usize, sched(t), .Xchg, QUEUED, .acq_rel);
                me.dq.push(t);
                wakeOne(c, w);
            }
        },
        sl.REN_T_YIELD => {
            _ = @atomicRmw(usize, sched(t), .Xchg, QUEUED, .acq_rel);
            injPush(c, t);
            wakeOne(c, w);
        },
        else => @panic("ren zig: resume returned an unknown code"),
    }
}

fn xorshift64(s: *u64) u64 {
    var x = s.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    s.* = x;
    return x;
}
fn stealAny(c: *Core, w: i32) ?*Task {
    if (c.nw == 1) return null;
    const nw: u64 = @intCast(c.nw);
    const first = xorshift64(&wk(c, w).rng) % nw;
    var i: u64 = 0;
    while (i < nw) : (i += 1) {
        const v: i32 = @intCast((first + i) % nw);
        if (v == w) continue;
        const victim = wk(c, v);
        switch (victim.dq.steal()) {
            .item => |x| {
                if (opts.plant == 5) {
                    victim.stolen_from += 1; // ← P5: plain read-modify-write by the thief
                } else {
                    _ = @atomicRmw(u64, &victim.stolen_from, .Add, 1, .monotonic);
                }
                return x;
            },
            .empty, .abort => {},
        }
    }
    return null;
}

// ------------------------------------------------------------------ delivery
fn deliver(c: *Core, w: i32, op: *Op) void {
    const me = wk(c, w);
    const aw = op.aw;
    const t = op.task;
    var in: []const u8 = &.{};
    if (op.call.op == sl.REN_OP_READ and op.reply_state == sl.REN_DONE and op.reply.res > 0) {
        // clamp to the call's buffer (a driver must never reply res > len)
        const n: u64 = @min(@as(u64, @intCast(op.reply.res)), op.body.len);
        in = W_.bufPtr(op.body.buf)[0..@intCast(n)];
    }
    jDeliver(c, w, op.call.id, op.reply_state, &op.reply, in);
    // debug: the pending-call mark is cleared before the REL store, so a resume
    // that sees the state never sees a stale mark
    if (safety) _ = @atomicRmw(usize, &t.core[2], .Xchg, 0, .monotonic);
    aw.res = op.reply;
    @atomicStore(i32, &aw.state, @intCast(op.reply_state), .release);
    if (op.had_cancel) {
        me.cancel_done += 1; // on_cancel_done: plain counter only
        if (opts.plant == 4) A.destroy(op); // ← P4: also frees the op; the common path frees it again
    }
    @atomicStore(u64, &c.slots[op.slot].word, word(nextGen(op.gen), FREE), .release);
    me.free[me.nfree] = op.slot - @as(u32, @intCast(w)) * c.S;
    me.nfree += 1;
    A.destroy(op);
    notify(c, w, t);
}
fn drainInbox(c: *Core, w: i32) u32 {
    var n: u32 = 0;
    var l = mpscTakeAll(Op, &wk(c, w).inbox);
    while (l) |op| {
        l = op.next;
        op.next = null;
        deliver(c, w, op);
        n += 1;
    }
    return n;
}

fn cancelSlot(c: *Core, gs: u32, g: u32, by: i32) void {
    const s = &c.slots[gs];
    var how: u32 = sl.REN_JC_LATE;
    while (true) {
        const wd = @atomicLoad(u64, &s.word, .acquire);
        if (@as(u32, @truncate(wd >> 32)) != g) {
            how = sl.REN_JC_LATE;
            break;
        }
        const st = wd & 0xffffffff;
        if (st == ISSUED) {
            if (@cmpxchgStrong(u64, &s.word, wd, word(g, CANCEL_UNPULLED), .acq_rel, .acquire) == null) {
                how = sl.REN_JC_RETRACT;
                break;
            }
        } else if (st == PULLED) {
            if (@cmpxchgStrong(u64, &s.word, wd, word(g, CANCEL_PULLED), .acq_rel, .acquire) == null) {
                const home: i32 = @intCast(gs / c.S);
                const n = A.create(CancelNode);
                n.* = .{ .id = (@as(u64, gs) << 32) | g };
                mpscPush(CancelNode, &wk(c, home).remote, n);
                wakeWorker(c, home);
                how = sl.REN_JC_SENT;
                break;
            }
        } else {
            how = sl.REN_JC_LATE;
            break;
        }
    }
    jIdHow(c, sl.REN_J_CANCEL, by, (@as(u64, gs) << 32) | g, how);
}

// ================================================================== the nine functions
pub fn start(cfgp: [*c]const sl.ren_config, main: sl.ren_main_fn, hostp_: [*c]const sl.ren_host, hostp: ?*anyopaque) ?*sl.ren_core {
    const cfg = cfgp.*;
    if (cfg.workers < 1 or cfg.workers > 64) return null;
    const c = A.create(Core);
    const nw: usize = @intCast(cfg.workers);
    const S: u32 = if (cfg.op_slots == 0) 4096 else cfg.op_slots;
    c.* = .{
        .cfg = cfg,
        .host = hostp_.*,
        .hostp = hostp,
        .nw = cfg.workers,
        .S = S,
        .B = if (cfg.budget_b == 0) 128 else cfg.budget_b,
        .K = if (cfg.poll_k == 0) 61 else cfg.poll_k,
        .W = A.allocSlice(Worker, nw),
        .slots = A.allocSlice(Slot, nw * S),
    };
    for (c.slots) |*s| s.* = .{ .word = word(1, FREE) };
    for (c.W, 0..) |*x, i| {
        x.* = .{
            .dq = undefined,
            .free = A.allocSlice(u32, S),
            .nfree = S,
            .rng = 0x9E3779B97F4A7C15 ^ @as(u64, i + 1),
            .cx = .{ .core = c, .worker = @intCast(i) },
        };
        x.dq.init(cfg.deque_log2);
        // initial pop order 0, 1, 2, ...
        for (x.free, 0..) |*f, k| f.* = S - 1 - @as(u32, @intCast(k));
    }
    c.live = 1;
    jHeader(c);
    const root = taskOf(main.?(&c.cfg)); // the frame; one reference, now the core's
    const w0 = wk(c, 0);
    w0.spawn_seq += 1;
    root.id = (0 << 24) | w0.spawn_seq;
    @atomicStore(usize, sched(root), QUEUED, .monotonic);
    injPush(c, root); // no wake: nobody is parked yet
    return @ptrCast(c); // ptr site: Core -> opaque ren_core
}

pub fn threadInit(c: *Core, w: i32, stack_lo: ?*anyopaque, size: usize) void {
    const x = wk(c, w);
    x.stack_lo = @intFromPtr(stack_lo); // ptr site: stack bound as an integer
    x.stack_size = size;
}

pub fn run(c: *Core, w: i32, steps: u32) i32 {
    const me = wk(c, w);
    if (safety and me.stack_lo != 0) {
        const here = @frameAddress();
        if (here < me.stack_lo or here >= me.stack_lo + me.stack_size)
            @panic("ren zig: ren_run called on a thread that is not this worker's");
    }
    me.drained = false;
    me.runs += 1;
    if (@atomicLoad(i32, &c.killed, .acquire) != 0) return sl.REN_FINISHED;
    if (@atomicRmw(i32, &me.parked, .Xchg, 0, .acq_rel) == 1) _ = @atomicRmw(i32, &c.idle, .Add, -1, .monotonic);
    me.stolen_seen = if (opts.plant == 5) me.stolen_from else @atomicLoad(u64, &me.stolen_from, .monotonic); // ← P5: plain read
    if (@atomicLoad(i32, &c.done, .acquire) != 0) return sl.REN_FINISHED;
    _ = drainInbox(c, w);
    var n: u32 = 0;
    while (true) {
        if (@atomicLoad(i32, &c.done, .acquire) != 0 or @atomicLoad(i32, &c.killed, .acquire) != 0) return sl.REN_FINISHED;
        if (n == steps) return sl.REN_RUNNING;
        var t: ?*Task = null;
        const s = @atomicLoad(u64, &me.steps, .monotonic);
        if (s != 0 and s % c.K == 0 and me.last_poll != s) { // §2.8: the world poll on a count
            me.last_poll = s;
            _ = drainInbox(c, w);
            t = injPop(c);
        }
        if (t == null) t = me.dq.take();
        if (t == null) t = injPop(c);
        if (t == null) t = stealAny(c, w);
        if (t) |x| {
            runTask(c, w, x);
            n += 1;
        } else {
            if (drainInbox(c, w) > 0) continue;
            if (tryPark(c, w)) return if (@atomicLoad(i32, &c.done, .acquire) != 0) sl.REN_FINISHED else sl.REN_IDLE;
            continue;
        }
    }
}

pub fn pollCall(c: *Core, w: i32, out: *sl.ren_call) bool {
    const me = wk(c, w);
    if (@atomicLoad(i32, &c.killed, .acquire) == 0) {
        if (me.cancels.head == null) me.cancels.appendAll(mpscTakeAll(CancelNode, &me.remote));
        if (me.cancels.popFront()) |node| {
            out.* = .{ .id = node.id, .worker = @intCast(w), .kind = sl.REN_CANCEL, .lane = 0, .task = 0, .op = 0, .len = 0, .body = null };
            A.destroy(node);
            return true;
        }
        while (me.outbox.popFront()) |op| {
            const g = op.gen;
            const s = &c.slots[op.slot];
            if (@cmpxchgStrong(u64, &s.word, word(g, ISSUED), word(g, PULLED), .acq_rel, .acquire) == null) {
                out.* = op.call;
                return true;
            }
            // CANCEL_UNPULLED: retract, with no round trip
            if (@cmpxchgStrong(u64, &s.word, word(g, CANCEL_UNPULLED), word(g, REPLIED), .acq_rel, .acquire) != null)
                @panic("ren zig: retract found a slot in an impossible state");
            op.had_cancel = true;
            op.reply_state = sl.REN_CANCELLED;
            op.reply = .{ .res = -sl.REN_ECANCELED, .a = 0, .b = 0 };
            mpscPush(Op, &me.inbox, op); // delivered at the next drain, in order
            // Departure (same as the C entry): a retraction is a reply, and every
            // reply leads to a tick (§2.7). Without this the driver sleeps forever
            // after an IDLE run whose last call was retracted. Not journaled.
            wakeWorker(c, w);
        }
    }
    me.drained = true;
    return false;
}

pub fn reply(c: *Core, r: *const sl.ren_reply_t) i32 {
    if (@atomicLoad(i32, &c.killed, .acquire) != 0) {
        jIdHow(c, sl.REN_J_RELEASE, -1, r.id, sl.REN_JR_DEAD);
        return sl.REN_RELEASE;
    }
    const gs64 = r.id >> 32;
    const g: u32 = @truncate(r.id);
    if (gs64 >= c.slots.len or g == 0) {
        jIdHow(c, sl.REN_J_RELEASE, -1, r.id, sl.REN_JR_STALE);
        return sl.REN_RELEASE;
    }
    const s = &c.slots[@intCast(gs64)];
    var st: u64 = 0;
    while (true) {
        const wd = @atomicLoad(u64, &s.word, .acquire);
        if (opts.plant != 3 and @as(u32, @truncate(wd >> 32)) != g) { // ← P3 deletes this test
            jIdHow(c, sl.REN_J_RELEASE, -1, r.id, sl.REN_JR_STALE);
            return sl.REN_RELEASE;
        }
        st = wd & 0xffffffff;
        if (st == PULLED or st == CANCEL_PULLED) {
            if (@cmpxchgStrong(u64, &s.word, wd, (wd & ~@as(u64, 0xffffffff)) | REPLIED, .acq_rel, .acquire) == null) break;
            continue;
        }
        const why: u32 = if (st == REPLIED) sl.REN_JR_DUP else sl.REN_JR_STALE;
        jIdHow(c, sl.REN_J_RELEASE, -1, r.id, why);
        return sl.REN_RELEASE;
    }
    const op = s.op.?;
    op.had_cancel = (st == CANCEL_PULLED);
    op.reply_state = r.state;
    op.reply = .{};
    if (r.body) |bp| {
        // first 24 bytes of r.body (zero-filled if r.len < 24)
        const n = @min(@as(usize, r.len), @sizeOf(sl.ren_io_result));
        const src: [*]const u8 = @ptrCast(bp); // ptr site: reply body bytes
        const dst: [*]u8 = @ptrCast(&op.reply); // ptr site: result as bytes
        @memcpy(dst[0..n], src[0..n]);
    }
    mpscPush(Op, &wk(c, op.home).inbox, op); // REL
    wakeWorker(c, op.home); // §2.7: every reply leads to a tick
    return sl.REN_ACCEPTED;
}

pub fn stop(c: *Core) void {
    if (@atomicRmw(i32, &c.stopping, .Xchg, 1, .seq_cst) == 1) return;
    fenceSC();
    for (c.slots, 0..) |*s, gs| {
        const wd = @atomicLoad(u64, &s.word, .acquire);
        // Departure (same as the C entry and the stub): FREE slots are skipped,
        // which only drops one LATE CANCEL entry per free slot. A slot that turns
        // ISSUED after this load is caught by ren_world's fence + stopping check.
        if (wd & 0xffffffff == FREE) continue;
        cancelSlot(c, @intCast(gs), @truncate(wd >> 32), -1);
    }
    wakeAll(c);
}

pub fn kill(c: *Core) void {
    if (@atomicRmw(i32, &c.killed, .Xchg, 1, .seq_cst) == 1) return;
    jEnd(c, -1, 1);
    @atomicStore(i32, &c.done, 1, .release);
    wakeAll(c);
}

pub fn free(c: *Core) void {
    // Slots first, so no op's task is read after a queue walk may have freed it.
    for (c.slots) |*s| {
        const wd = @atomicLoad(u64, &s.word, .acquire);
        if (wd & 0xffffffff == FREE) continue;
        if (s.op) |op| {
            // after kill only: a task parked on this call is reachable only from here
            if (@atomicLoad(usize, sched(op.task), .acquire) == PARKED) sl.ren_rc_drop(&op.task.obj);
            A.destroy(op);
            s.op = null;
        }
    }
    for (c.W) |*x| {
        while (x.dq.take()) |t| sl.ren_rc_drop(&t.obj);
    }
    while (injPop(c)) |t| sl.ren_rc_drop(&t.obj);
    for (c.W) |*x| {
        var cn = x.cancels.head;
        while (cn) |n| {
            cn = n.next;
            A.destroy(n);
        }
        cn = mpscTakeAll(CancelNode, &x.remote);
        while (cn) |n| {
            cn = n.next;
            A.destroy(n);
        }
        x.dq.deinit();
        A.freeSlice(u32, x.free);
    }
    A.freeSlice(Slot, c.slots);
    A.freeSlice(Worker, c.W);
    A.destroy(c);
}

pub fn progress(c: *Core, w: i32) u64 {
    return @atomicLoad(u64, &wk(c, w).steps, .monotonic);
}

// ================================================================== emitted-code ABI (SPEC §B.5)
pub fn spawn(cxp: ?*sl.ren_ctx, tp: [*c]sl.ren_task) void {
    const cx = ctxOf(cxp);
    const c = cx.core;
    const w = cx.worker;
    const t = taskOf(tp);
    const me = wk(c, w);
    me.spawn_seq += 1;
    t.id = (@as(u32, @intCast(w)) << 24) | me.spawn_seq;
    @atomicStore(usize, sched(t), QUEUED, .monotonic);
    _ = @atomicRmw(i64, &c.live, .Add, 1, .monotonic); // the spawner is live
    me.dq.push(t);
    wakeOne(c, w);
}

pub fn notifyExport(cxp: ?*sl.ren_ctx, tp: [*c]sl.ren_task) void {
    const cx = ctxOf(cxp);
    notify(cx.core, cx.worker, taskOf(tp));
}

pub fn world(cxp: ?*sl.ren_ctx, selfp: [*c]sl.ren_task, awp: [*c]sl.ren_await, op: u32, bodyp: [*c]const sl.ren_io_body) i32 {
    const cx = ctxOf(cxp);
    const c = cx.core;
    const w = cx.worker;
    const me = wk(c, w);
    const self = taskOf(selfp);
    const aw: *sl.ren_await = @ptrCast(awp.?); // [*c] -> single pointer
    if (@atomicLoad(i32, &c.stopping, .acquire) != 0) {
        aw.id = 0;
        aw.op = op;
        aw.res = .{ .res = -sl.REN_ECANCELED, .a = 0, .b = 0 };
        jDeliver(c, w, 0, sl.REN_CANCELLED, &aw.res, &.{});
        @atomicStore(i32, &aw.state, sl.REN_CANCELLED, .release);
        return sl.REN_W_NOW;
    }
    if (me.nfree == 0) return sl.REN_W_FULL;
    if (safety) {
        if (@atomicLoad(usize, &self.core[2], .monotonic) != 0)
            @panic("ren zig: ren_world: the task already has a pending world call");
    }
    me.nfree -= 1;
    const ls = me.free[me.nfree];
    const gs: u32 = @as(u32, @intCast(w)) * c.S + ls;
    const g: u32 = @truncate(@atomicLoad(u64, &c.slots[gs].word, .monotonic) >> 32);
    const id = (@as(u64, gs) << 32) | g;
    const o = A.create(Op);
    o.* = .{
        .slot = gs,
        .gen = g,
        .home = @intCast(w),
        .task = self,
        .aw = aw,
        .body = bodyp.*,
        .call = .{ .id = id, .worker = @intCast(w), .kind = sl.REN_CALL, .lane = 0, .task = self.id, .op = op, .len = @sizeOf(sl.ren_io_body), .body = null },
    };
    o.call.body = &o.body;
    aw.id = id;
    aw.op = op;
    @atomicStore(i32, &aw.state, 0, .monotonic);
    jCall(c, w, &o.call);
    if (c.host.answer_now) |an| {
        var rep: sl.ren_reply_t = .{};
        if (an(c.hostp, w, &o.call, &rep)) { // inline: same journal path
            var res: sl.ren_io_result = .{};
            if (rep.body) |bp| {
                const n = @min(@as(usize, rep.len), @sizeOf(sl.ren_io_result));
                const src: [*]const u8 = @ptrCast(bp); // ptr site: reply body bytes
                const dst: [*]u8 = @ptrCast(&res); // ptr site: result as bytes
                @memcpy(dst[0..n], src[0..n]);
            }
            jDeliver(c, w, id, rep.state, &res, &.{});
            aw.res = res;
            @atomicStore(i32, &aw.state, @intCast(rep.state), .release);
            @atomicStore(u64, &c.slots[gs].word, word(nextGen(g), FREE), .release);
            me.free[me.nfree] = ls;
            me.nfree += 1;
            A.destroy(o);
            return sl.REN_W_NOW;
        }
    }
    if (safety) _ = @atomicRmw(usize, &self.core[2], .Xchg, @as(usize, gs) + 1, .monotonic);
    c.slots[gs].op = o;
    @atomicStore(u64, &c.slots[gs].word, word(g, ISSUED), .release);
    me.outbox.pushBack(o);
    fenceSC(); // Dekker with ren_stop's xchg(stopping, SC) + fence + walk
    if (@atomicLoad(i32, &c.stopping, .monotonic) != 0) cancelSlot(c, gs, g, w);
    return sl.REN_W_PENDING;
}

pub fn cancel(cxp: ?*sl.ren_ctx, id: u64) void {
    const cx = ctxOf(cxp);
    const c = cx.core;
    if ((id >> 32) >= c.slots.len or @as(u32, @truncate(id)) == 0) {
        jIdHow(c, sl.REN_J_CANCEL, cx.worker, id, sl.REN_JC_LATE);
        return;
    }
    cancelSlot(c, @intCast(id >> 32), @truncate(id), cx.worker);
}

pub fn tick(cxp: ?*sl.ren_ctx) bool {
    const cx = ctxOf(cxp);
    cx.points += 1;
    return cx.points >= cx.core.B;
}
pub fn cancelled(cxp: ?*sl.ren_ctx) bool {
    return @atomicLoad(i32, &ctxOf(cxp).core.stopping, .acquire) != 0;
}
pub fn ctxWorker(cxp: ?*sl.ren_ctx) i32 {
    return ctxOf(cxp).worker;
}
