// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! An installed extension running as gtty's child process
//! (docs/protocol.md). Host owns it: it sends gtty's messages
//! (`send*`), and once a frame `pump` writes what waits, reads the
//! extension's lines and hands them to Host (`Host.procMessage`), and
//! turns its stdout / stderr into log lines. Nothing here blocks.
//!
//! Or one an IDE started under its debugger, connected to the developer
//! socket (`accept`, docs/protocol.md "Development"): not gtty's child, so
//! never signalled or reaped; it ends when its socket closes. While it
//! may sit at a breakpoint, gtty's limits relax (`dev_*`).

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;
const ExtLog = @import("../core/ExtLog.zig");
const Extensions = @import("../core/Extensions.zig");

const Proc = @This();

/// What may wait to be written; past it events are dropped.
pub const max_out = 4 * 1024 * 1024;
/// The same for an extension being debugged: it may stop at a breakpoint.
pub const dev_max_out = 64 * 1024 * 1024;
/// How long a connection may take to say who it is.
pub const attach_ms = 10_000;
/// The longest line taken from an extension.
pub const max_line = 8 * 1024 * 1024;
/// Lines handled per frame.
pub const lines_per_pump = 256;
/// After `gttyClose`: SIGTERM, then SIGKILL.
pub const term_ms = 1000;
pub const kill_ms = 3000;
/// How long a user's click lets the extension open a peek or dialog with
/// the keyboard.
pub const user_click_ms = 5000;
/// The same while debugging: stepping from the click to the dialog.
pub const dev_user_click_ms = 10 * 60 * 1000;

/// `attaching`: a developer connection that hasn't said who it is yet.
pub const State = enum { attaching, running, stopping, ended };

gpa: std.mem.Allocator,
name: []u8,
/// The manifest's stamp when started: a reinstall restarts it.
stamp: i64,
/// Host's chip index for it.
chip: usize,
pid: c_int = 0,
sock: c_int = -1,
out_fd: c_int = -1,
err_fd: c_int = -1,
state: State = .running,
/// Connected through the developer socket (`accept`).
dev: bool = false,
/// Stopped to make room for a debugged run of it: starts again after.
replaced: bool = false,
/// Its pid as the socket tells (dev; 0 unknown). `pid` stays 0: not ours.
peer_pid: c_int = 0,
/// When it connected (dev).
start_ms: u64 = 0,
exit_code: c_int = 0,
/// When stopping began (SDL ticks).
stop_ms: u64 = 0,
inbuf: std.ArrayList(u8) = .empty,
outbuf: std.ArrayList(u8) = .empty,
skipping: bool = false,
out_line: std.ArrayList(u8) = .empty,
err_line: std.ArrayList(u8) = .empty,
/// Registered events per window.
masks: std.AutoHashMapUnmanaged(u32, u32) = .empty,
/// Recent clicks the user made: their event ids.
user_clicks: [8]struct { id: u32 = 0, ms: u64 = 0 } = @splat(.{}),
user_at: usize = 0,
dropped: u64 = 0,
log: ?*ExtLog = null,

/// Start `x`'s program. Error: the runtime is missing or it can't start
/// (logged by the caller).
pub fn start(gpa: std.mem.Allocator, x: Extensions.Installed, chip: usize, log: ?*ExtLog) !*Proc {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = (try Extensions.command(a, x)) orelse return error.NoRuntime;
    var args = try a.alloc(?[*:0]const u8, argv.len + 1);
    for (argv, 0..) |s, i| args[i] = (try a.dupeZ(u8, s)).ptr;
    args[argv.len] = null;
    // gtty's environment, without gtty's own GTTY_ variables, and the three
    // the protocol sets.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "GTTY_EXT_")) continue;
        try env.append(a, e);
    }
    try env.append(a, "GTTY_EXT_FD=3");
    try env.append(a, (try std.fmt.allocPrintSentinel(a, "GTTY_EXT_NAME={s}", .{x.manifest.name}, 0)).ptr);
    try env.append(a, (try std.fmt.allocPrintSentinel(a, "GTTY_EXT_DIR={s}", .{x.code}, 0)).ptr);
    try env.append(a, null);
    const code = try a.dupeZ(u8, x.code);
    const p = try gpa.create(Proc);
    errdefer gpa.destroy(p);
    p.* = .{ .gpa = gpa, .name = try gpa.dupe(u8, x.manifest.name), .stamp = x.stamp, .chip = chip, .log = log };
    const pid = c.gtty_ext_spawn(args[0].?, @ptrCast(args.ptr), @ptrCast(env.items.ptr), code.ptr, &p.sock, &p.out_fd, &p.err_fd);
    if (pid < 0) {
        gpa.free(p.name);
        return error.SpawnFailed;
    }
    p.pid = pid;
    return p;
}

/// A connection on the developer socket: it names itself in its first
/// message (`Host.procLine` → `attached`).
pub fn accept(gpa: std.mem.Allocator, sock: c_int, peer_pid: c_int, log: ?*ExtLog) !*Proc {
    const p = try gpa.create(Proc);
    errdefer gpa.destroy(p);
    p.* = .{
        .gpa = gpa,
        .name = try gpa.dupe(u8, "dev"),
        .stamp = 0,
        .chip = std.math.maxInt(usize),
        .sock = sock,
        .state = .attaching,
        .dev = true,
        .peer_pid = peer_pid,
        .start_ms = c.SDL_GetTicks(),
        .log = log,
    };
    return p;
}

/// The attaching connection said who it is.
pub fn attached(p: *Proc, name: []const u8, chip: usize) !void {
    const n = try p.gpa.dupe(u8, name);
    p.gpa.free(p.name);
    p.name = n;
    p.chip = chip;
    p.state = .running;
}

/// The pid to show: its own, or the debugged one's.
pub fn shownPid(p: *const Proc) c_int {
    return if (p.dev) p.peer_pid else p.pid;
}

/// Refuse an attaching connection: `refused` with why, then it closes.
pub fn refuse(p: *Proc, why: []const u8) void {
    var o: Out = undefined;
    p.begin(&o, "refused");
    o.field("reason", why);
    o.endAlways();
    p.flush();
    p.finish("refused");
}

pub fn destroy(p: *Proc) void {
    p.closeFds();
    p.inbuf.deinit(p.gpa);
    p.outbuf.deinit(p.gpa);
    p.out_line.deinit(p.gpa);
    p.err_line.deinit(p.gpa);
    p.masks.deinit(p.gpa);
    p.gpa.free(p.name);
    p.gpa.destroy(p);
}

fn closeFds(p: *Proc) void {
    inline for (.{ "sock", "out_fd", "err_fd" }) |f| if (@field(p, f) >= 0) {
        _ = c.close(@field(p, f));
        @field(p, f) = -1;
    };
}

fn say(p: *Proc, level: sdk.LogLevel, msg: []const u8) void {
    if (p.log) |l| l.write(level, p.name, 0, msg);
}

// ---- sending ----

pub const Out = struct {
    p: *Proc,
    w: std.Io.Writer.Allocating,
    s: sdk.wire.Stringify,

    pub fn field(o: *Out, key: []const u8, v: anytype) void {
        o.s.objectField(key) catch {};
        sdk.wire.encode(&o.s, v) catch {};
    }

    /// Queue it. `droppable`: an event, which may go when the extension
    /// doesn't read.
    pub fn end(o: *Out, droppable: bool) void {
        defer o.w.deinit();
        o.s.endObject() catch return;
        o.w.writer.writeByte('\n') catch return;
        const bytes = o.w.written();
        if (o.p.state != .running) return;
        if (droppable and o.p.outbuf.items.len + bytes.len > @as(usize, if (o.p.dev) dev_max_out else max_out)) {
            o.p.dropped += 1;
            return;
        }
        o.p.outbuf.appendSlice(o.p.gpa, bytes) catch {};
    }

    /// Queue it whatever the state (`refuse`).
    pub fn endAlways(o: *Out) void {
        defer o.w.deinit();
        o.s.endObject() catch return;
        o.w.writer.writeByte('\n') catch return;
        o.p.outbuf.appendSlice(o.p.gpa, o.w.written()) catch {};
    }
};

/// Start a message in `o` (in place: its writer points into it).
pub fn begin(p: *Proc, o: *Out, t: []const u8) void {
    o.* = .{ .p = p, .w = .init(p.gpa), .s = undefined };
    o.s = .{ .writer = &o.w.writer };
    o.s.beginObject() catch {};
    o.field("t", t);
}

pub fn sendSimple(p: *Proc, t: []const u8, win: ?u32) void {
    var o: Out = undefined;
    p.begin(&o, t);
    if (win) |w| o.field("win", w);
    o.end(false);
}

pub fn sendEvent(p: *Proc, win: u32, ev: sdk.Event, user: bool) void {
    if (user and (ev.kind == .button_click or ev.kind == .key)) {
        p.user_clicks[p.user_at % p.user_clicks.len] = .{ .id = ev.eventId, .ms = c.SDL_GetTicks() };
        p.user_at += 1;
    }
    var o: Out = undefined;
    p.begin(&o, "event");
    o.field("win", win);
    o.field("event", ev);
    // Clicks are never dropped; keys and the rest may be.
    o.end(ev.kind != .button_click);
}

pub fn sendReply(p: *Proc, id: u32, value: anytype) void {
    var o: Out = undefined;
    p.begin(&o, "reply");
    o.field("id", id);
    o.field("value", value);
    o.end(false);
}

pub fn sendError(p: *Proc, id: u32, err: anyerror) void {
    var o: Out = undefined;
    p.begin(&o, "reply");
    o.field("id", id);
    o.field("error", @errorName(err));
    o.end(false);
}

/// Was event `ev` one of the user's clicks, lately?
pub fn fromUser(p: *const Proc, ev: u32) bool {
    if (ev == 0) return false;
    const now = c.SDL_GetTicks();
    const within: u64 = if (p.dev) dev_user_click_ms else user_click_ms;
    for (p.user_clicks) |u| if (u.id == ev and now -| u.ms <= within) return true;
    return false;
}

pub fn listens(p: *const Proc, uid: u32, bit: u32) bool {
    return (p.masks.get(uid) orelse 0) & bit != 0;
}

// ---- stopping ----

/// Ask it to end: `gttyClose`, then the socket closes once written.
pub fn stop(p: *Proc) void {
    if (p.state == .attaching) return p.finish("closed before it attached");
    if (p.state != .running) return;
    p.sendSimple("gttyClose", null);
    p.flush();
    c.gtty_ext_shutdown_write(p.sock);
    p.state = .stopping;
    p.stop_ms = c.SDL_GetTicks();
}

// ---- once a frame ----

/// Write, read, reap. `handle` gets each complete line.
pub fn pump(p: *Proc, ctx: anytype, comptime handle: fn (@TypeOf(ctx), *Proc, []const u8) void) void {
    if (p.state == .ended) return;
    p.flush();
    p.readSocket(ctx, handle);
    p.readOutput(p.out_fd, &p.out_line, .info);
    p.readOutput(p.err_fd, &p.err_line, .err);
    p.reap();
}

fn flush(p: *Proc) void {
    while (p.outbuf.items.len > 0 and p.sock >= 0) {
        const n = c.write(p.sock, p.outbuf.items.ptr, p.outbuf.items.len);
        if (n <= 0) return; // full (EAGAIN) or gone (the read sees EOF)
        const k: usize = @intCast(n);
        std.mem.copyForwards(u8, p.outbuf.items[0 .. p.outbuf.items.len - k], p.outbuf.items[k..]);
        p.outbuf.shrinkRetainingCapacity(p.outbuf.items.len - k);
    }
}

fn readSocket(p: *Proc, ctx: anytype, comptime handle: fn (@TypeOf(ctx), *Proc, []const u8) void) void {
    if (p.sock < 0) return;
    var buf: [65536]u8 = undefined;
    var reads: usize = 0;
    while (reads < 64) : (reads += 1) {
        const n = c.read(p.sock, &buf, buf.len);
        if (n == 0) {
            _ = c.close(p.sock);
            p.sock = -1;
            break;
        }
        if (n < 0) break;
        p.inbuf.appendSlice(p.gpa, buf[0..@intCast(n)]) catch break;
    }
    var lines: usize = 0;
    var at: usize = 0;
    while (lines < lines_per_pump) : (lines += 1) {
        const end = std.mem.indexOfScalarPos(u8, p.inbuf.items, at, '\n') orelse break;
        const line = p.inbuf.items[at..end];
        at = end + 1;
        if (p.skipping) {
            p.skipping = false;
            continue;
        }
        if (line.len > 0) handle(ctx, p, line);
        if (p.state == .ended) return;
    }
    const rest = p.inbuf.items.len - at;
    std.mem.copyForwards(u8, p.inbuf.items[0..rest], p.inbuf.items[at..]);
    p.inbuf.shrinkRetainingCapacity(rest);
    if (p.inbuf.items.len > max_line and std.mem.indexOfScalar(u8, p.inbuf.items, '\n') == null) {
        p.say(.err, "a message over 8 MB: dropped");
        p.inbuf.clearRetainingCapacity();
        p.skipping = true;
    }
}

fn readOutput(p: *Proc, fd: c_int, line: *std.ArrayList(u8), level: sdk.LogLevel) void {
    if (fd < 0) return;
    var buf: [8192]u8 = undefined;
    for (0..16) |_| {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |b| {
            if (b == '\n' or line.items.len >= 2000) {
                p.say(level, line.items);
                line.clearRetainingCapacity();
                if (b == '\n') continue;
            }
            line.append(p.gpa, b) catch {};
        }
    }
}

/// Ended, its fds closed; `why` to the log.
fn finish(p: *Proc, why: []const u8) void {
    p.state = .ended;
    p.closeFds();
    p.say(.info, why);
}

fn reap(p: *Proc) void {
    if (p.dev) {
        if (p.state == .ended) return;
        const t = c.SDL_GetTicks();
        if (p.sock < 0) return p.finish("disconnected");
        if (p.state == .attaching and t -| p.start_ms >= attach_ms) return p.finish("didn't attach: closed");
        if (p.state == .stopping and t -| p.stop_ms >= kill_ms) return p.finish("didn't close its connection: closed");
        return;
    }
    var status: c_int = 0;
    if (p.pid > 0 and c.gtty_ext_reap(p.pid, &status) != 0) {
        // Its last words first.
        p.readOutput(p.out_fd, &p.out_line, .info);
        p.readOutput(p.err_fd, &p.err_line, .err);
        if (p.out_line.items.len > 0) p.say(.info, p.out_line.items);
        if (p.err_line.items.len > 0) p.say(.err, p.err_line.items);
        p.exit_code = status;
        p.pid = 0;
        p.state = .ended;
        p.closeFds();
        var buf: [64]u8 = undefined;
        p.say(if (status == 0) .info else .err, std.fmt.bufPrint(&buf, "ended with exit code {d}", .{status}) catch "ended");
        return;
    }
    if (p.state == .stopping and p.pid > 0) {
        const t = c.SDL_GetTicks() -| p.stop_ms;
        if (t >= kill_ms) c.gtty_ext_signal(p.pid, c.SIGKILL) else if (t >= term_ms) c.gtty_ext_signal(p.pid, c.SIGTERM);
    }
}

/// Read and drop what the socket holds; notes its end (`sock` -1).
fn discardInput(p: *Proc) void {
    if (p.sock < 0) return;
    var buf: [65536]u8 = undefined;
    for (0..64) |_| {
        const n = c.read(p.sock, &buf, buf.len);
        if (n == 0) {
            _ = c.close(p.sock);
            p.sock = -1;
            return;
        }
        if (n < 0) return;
    }
}

/// gtty is closing: wait up to `kill_ms` in all for `procs` to end.
pub fn endAll(procs: []const *Proc) void {
    for (procs) |p| p.stop();
    const t0 = c.SDL_GetTicks();
    while (true) {
        var left = false;
        for (procs) |p| {
            if (p.state == .ended) continue;
            p.flush();
            if (p.dev) p.discardInput();
            p.reap();
            if (p.state != .ended) left = true;
        }
        if (!left) return;
        const t = c.SDL_GetTicks() - t0;
        for (procs) |p| if (p.pid > 0) {
            if (t >= kill_ms) c.gtty_ext_signal(p.pid, c.SIGKILL) else if (t >= term_ms) c.gtty_ext_signal(p.pid, c.SIGTERM);
        };
        if (t > kill_ms + 500) return;
        c.SDL_Delay(10);
    }
}
