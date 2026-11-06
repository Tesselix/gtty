// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Runs the standard chips (src/chips/): extensions on the SDK
//! (sdks/zig) that live inside the gtty process. Each chip gets a
//! connection per job window (`windowStarted`) and registers on it what
//! it wants to hear.
//!
//! Nothing fired runs at once: `fire` queues the event (nothing at all
//! when no chip listens; dropped, and counted, when `max_queued` wait)
//! and `pump`, once a frame, hands out at most `pump_max`, so a burst
//! can't hold up a frame. `onWindowClose` is a notice like any event:
//! the connection is already closed when it runs. A button click
//! (`click`) goes only to its owner, needs no registering and is never
//! dropped.

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;
const trace = @import("../core/trace.zig");
const ExtStorage = @import("../core/ExtStorage.zig");
const ExtLog = @import("../core/ExtLog.zig");

const Host = @This();

pub const max_queued = 256;
pub const pump_max = 64;

/// What chips ask of the windows: `chip` is the index in `defs`.
/// `from_user`: while handling something the user did (a dialog may take
/// the keyboard then).
pub const Sink = struct {
    ctx: *anyopaque,
    setChip: *const fn (ctx: *anyopaque, uid: u32, chip: usize, update: sdk.ChipUpdate) void,
    setDialog: *const fn (ctx: *anyopaque, uid: u32, chip: usize, update: sdk.DialogUpdate) sdk.Error!void,
    showDialog: *const fn (ctx: *anyopaque, uid: u32, chip: usize, from_user: bool) sdk.Error!void,
    closeDialog: *const fn (ctx: *anyopaque, uid: u32, chip: usize) sdk.Error!void,
    setPeek: *const fn (ctx: *anyopaque, uid: u32, chip: usize, update: ?sdk.PeekUpdate) sdk.Error!void,
    setEpeek: *const fn (ctx: *anyopaque, uid: u32, chip: usize, update: ?sdk.EpeekUpdate) sdk.Error!void,
    setDisplayMode: *const fn (ctx: *anyopaque, uid: u32, chip: usize, mode: sdk.DisplayMode, from_user: bool) sdk.Error!void,
    shell: *const fn (ctx: *anyopaque, uid: u32, buf: []u8) sdk.Error![]const u8,
};

const Conn = struct {
    host: *Host,
    chip: usize,
    win: sdk.Window,
    /// The events it registered, one bit each.
    mask: u32 = 0,
    closed: bool = false,
};

const Item = union(enum) {
    event: struct { uid: u32, ev: sdk.Event, text: []u8 },
    click: struct { uid: u32, chip: usize, user: bool, ev: sdk.Event, arena: *std.heap.ArenaAllocator },
    window_close: u32,
};

gpa: std.mem.Allocator,
defs: []const sdk.Definition,
sink: ?Sink = null,
/// The extensions' files (App's).
storage: ?*ExtStorage = null,
/// `gtty ext logs` (App's).
log: ?*ExtLog = null,
/// gtty's own thread: a chip there can't wait for a file.
main_thread: std.Thread.Id = 0,
/// Handing out a click the user made.
from_user: bool = false,
conns: std.ArrayList(*Conn) = .empty,
queue: std.ArrayList(Item) = .empty,
head: usize = 0,
next_id: u32 = 0,
/// For GTTY_TRACE: what the event system did this run.
fired: u64 = 0,
calls: u64 = 0,
dropped: u64 = 0,
/// `dropped` when the log last heard of it.
dropped_said: u64 = 0,
busy_ns: u64 = 0,
slowest_ns: u64 = 0,

pub fn init(gpa: std.mem.Allocator, defs: []const sdk.Definition) Host {
    return .{ .gpa = gpa, .defs = defs, .main_thread = std.Thread.getCurrentId() };
}

pub fn setSink(h: *Host, sink: Sink) void {
    h.sink = sink;
}

/// gtty started: each chip's `onGttyStart`.
pub fn start(h: *Host) void {
    for (h.defs, 0..) |d, i| if (d.onGttyStart) |f| {
        var who: ExtRef = .{ .host = h, .chip = i };
        var ext: sdk.Extension = .{ .name = d.name, .logger = .{ .ctx = &who, .write = extLog } };
        f(&ext) catch |e| h.report(d.name, 0, "onGttyStart", e);
    };
}

/// gtty is closing: what is queued, then each chip's `onGttyClose`.
pub fn stop(h: *Host) void {
    while (h.head < h.queue.items.len) h.pump();
    for (h.defs, 0..) |d, i| if (d.onGttyClose) |f| {
        var who: ExtRef = .{ .host = h, .chip = i };
        var ext: sdk.Extension = .{ .name = d.name, .logger = .{ .ctx = &who, .write = extLog } };
        f(&ext) catch |e| h.report(d.name, 0, "onGttyClose", e);
    };
    // After they all heard it: whatever they left open.
    if (h.storage) |st| st.closeAll();
    if (trace.on()) trace.line("chips: {d} events, {d} handler calls, {d} dropped, {d} us in handlers, slowest {d} us", .{ h.fired, h.calls, h.dropped, h.busy_ns / 1000, h.slowest_ns / 1000 });
    for (h.conns.items) |k| h.gpa.destroy(k);
    h.conns.deinit(h.gpa);
    h.queue.deinit(h.gpa);
}

/// A job window started: a connection for each chip, and its
/// `onWindowStart`, where it registers.
pub fn windowStarted(h: *Host, uid: u32) void {
    for (h.defs, 0..) |d, i| {
        const k = h.gpa.create(Conn) catch continue;
        k.* = .{ .host = h, .chip = i, .win = .{
            .id = uid,
            .ui = .{ .ctx = k, .conn = &connection },
            .events = .{ .ctx = k, .conn = &connection },
            .ephemeral = .{ .ctx = k, .conn = &connection, .kind = .ephemeral },
            .stateful = .{ .ctx = k, .conn = &connection, .kind = .stateful },
            .logger = .{ .ctx = k, .write = winLog },
        } };
        h.conns.append(h.gpa, k) catch {
            h.gpa.destroy(k);
            continue;
        };
        if (d.onWindowStart) |f| f(&k.win) catch |e| h.report(d.name, uid, "onWindowStart", e);
    }
}

/// A job window closed: its connections close now, `onWindowClose` comes
/// with the next `pump`.
pub fn windowClosed(h: *Host, uid: u32) void {
    for (h.conns.items) |k| if (k.win.id == uid) {
        k.closed = true;
    };
    h.queue.append(h.gpa, .{ .window_close = uid }) catch {};
}

/// Does any chip listen for `kind` on this window?
pub fn listens(h: *const Host, uid: u32, kind: sdk.EventKind) bool {
    const bit = bitOf(kind);
    for (h.conns.items) |k| if (k.win.id == uid and k.mask & bit != 0) return true;
    return false;
}

/// Queue an event of window `uid`; its strings are copied.
pub fn fire(h: *Host, uid: u32, ev: sdk.Event) void {
    if (!h.listens(uid, ev.kind)) return;
    if (h.queue.items.len - h.head >= max_queued) {
        h.dropped += 1;
        return;
    }
    const text = h.gpa.alloc(u8, ev.folder.len + ev.branch.len + ev.command.len) catch return;
    var e = ev;
    h.next_id +%= 1;
    e.eventId = h.next_id;
    var at: usize = 0;
    inline for (.{ "folder", "branch", "command" }) |name| {
        const s = @field(ev, name);
        @memcpy(text[at..][0..s.len], s);
        @field(e, name) = text[at..][0..s.len];
        at += s.len;
    }
    h.queue.append(h.gpa, .{ .event = .{ .uid = uid, .ev = e, .text = text } }) catch {
        h.gpa.free(text);
        return;
    };
    h.fired += 1;
}

/// A button of chip `chip` was pressed (`user`: by the user, not a
/// timeout); its strings are copied.
pub fn click(h: *Host, uid: u32, chip: usize, b: sdk.ButtonClick, user: bool) void {
    const arena = h.gpa.create(std.heap.ArenaAllocator) catch return;
    arena.* = .init(h.gpa);
    const a = arena.allocator();
    const copy = copyClick(a, b) catch {
        arena.deinit();
        h.gpa.destroy(arena);
        return;
    };
    h.next_id +%= 1;
    h.queue.append(h.gpa, .{ .click = .{ .uid = uid, .chip = chip, .user = user, .arena = arena, .ev = .{ .eventId = h.next_id, .kind = .button_click, .button = copy } } }) catch {
        arena.deinit();
        h.gpa.destroy(arena);
        return;
    };
    h.fired += 1;
}

/// The filter of chip `chip` changed: a click with `id` `filter`, and one
/// still waiting takes the new text, so a chip that falls behind gets only
/// the latest.
pub fn filterChanged(h: *Host, uid: u32, chip: usize, b: sdk.ButtonClick) void {
    for (h.queue.items[h.head..]) |*it| switch (it.*) {
        .click => |*q| if (q.uid == uid and q.chip == chip and q.ev.button.?.is("filter")) {
            q.ev.button.?.text = q.arena.allocator().dupe(u8, b.text) catch return;
            return;
        },
        else => {},
    };
    h.click(uid, chip, b, true);
}

fn copyClick(a: std.mem.Allocator, b: sdk.ButtonClick) !sdk.ButtonClick {
    const fields = try a.alloc(sdk.FieldValue, b.fields.len);
    for (b.fields, fields) |f, *o| o.* = .{ .id = try a.dupe(u8, f.id), .value = switch (f.value) {
        .text => |s| .{ .text = try a.dupe(u8, s) },
        .on => f.value,
    } };
    return .{ .id = try a.dupe(u8, b.id), .text = try a.dupe(u8, b.text), .data = try a.dupe(u8, b.data), .function = try a.dupe(u8, b.function), .fields = fields, .command = b.command };
}

/// Once a frame: hand out what is queued.
pub fn pump(h: *Host) void {
    var n: usize = 0;
    while (h.head < h.queue.items.len and n < pump_max) : (n += 1) {
        const item = h.queue.items[h.head];
        h.head += 1;
        switch (item) {
            .event => |q| {
                defer h.gpa.free(q.text);
                // By index: a handler can open windows (a session restored).
                var i: usize = 0;
                while (i < h.conns.items.len) : (i += 1) {
                    const k = h.conns.items[i];
                    if (k.win.id != q.uid or k.closed or k.mask & bitOf(q.ev.kind) == 0) continue;
                    const d = h.defs[k.chip];
                    if (d.onEvent) |f| h.timed(d.name, f, &k.win, &q.ev);
                }
            },
            .click => |q| {
                defer {
                    q.arena.deinit();
                    h.gpa.destroy(q.arena);
                }
                h.from_user = q.user;
                defer h.from_user = false;
                var i: usize = 0;
                while (i < h.conns.items.len) : (i += 1) {
                    const k = h.conns.items[i];
                    if (k.win.id != q.uid or k.chip != q.chip) continue;
                    const d = h.defs[k.chip];
                    if (d.onEvent) |f| h.timed(d.name, f, &k.win, &q.ev);
                }
            },
            .window_close => |uid| h.close(uid),
        }
    }
    if (h.head == h.queue.items.len) {
        h.queue.clearRetainingCapacity();
        h.head = 0;
    }
    if (h.dropped != h.dropped_said) {
        var buf: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "{d} events dropped: the queue was full", .{h.dropped - h.dropped_said}) catch "events dropped";
        h.say(.warn, "gtty", 0, m);
        h.dropped_said = h.dropped;
    }
}

fn close(h: *Host, uid: u32) void {
    var i: usize = 0;
    while (i < h.conns.items.len) {
        const k = h.conns.items[i];
        if (k.win.id != uid) {
            i += 1;
            continue;
        }
        const d = h.defs[k.chip];
        if (d.onWindowClose) |f| f(&k.win) catch |e| h.report(d.name, uid, "onWindowClose", e);
        _ = h.conns.orderedRemove(i);
        h.gpa.destroy(k);
    }
    // The instances ended: their ephemeral files go.
    if (h.storage) |st| {
        var names: [32][]const u8 = undefined;
        const n = @min(h.defs.len, names.len);
        for (h.defs[0..n], names[0..n]) |d, *o| o.* = d.name;
        st.closeWindow(uid, names[0..n]);
    }
}

fn timed(h: *Host, name: []const u8, f: anytype, win: *sdk.Window, ev: *const sdk.Event) void {
    const t0 = if (trace.on()) c.SDL_GetTicksNS() else 0;
    f(win, ev) catch |e| h.report(name, win.id, "onEvent", e);
    h.calls += 1;
    if (t0 != 0) {
        const ns = c.SDL_GetTicksNS() - t0;
        h.busy_ns += ns;
        h.slowest_ns = @max(h.slowest_ns, ns);
    }
}

fn report(h: *Host, name: []const u8, uid: u32, callback: []const u8, e: anyerror) void {
    if (e == error.WindowClosed) return;
    if (trace.on()) trace.line("chip {s}: {s}", .{ name, @errorName(e) });
    var buf: [128]u8 = undefined;
    const m = std.fmt.bufPrint(&buf, "{s} returned {s}", .{ callback, @errorName(e) }) catch callback;
    h.say(.err, name, uid, m);
}

fn say(h: *Host, level: sdk.LogLevel, name: []const u8, uid: u32, msg: []const u8) void {
    if (h.log) |l| l.write(level, name, uid, msg);
}

/// Who logs in `onGttyStart` and `onGttyClose`.
const ExtRef = struct { host: *Host, chip: usize };

fn extLog(ctx: *anyopaque, level: sdk.LogLevel, msg: []const u8) void {
    const r: *ExtRef = @ptrCast(@alignCast(ctx));
    r.host.say(level, r.host.defs[r.chip].name, 0, msg);
}

fn winLog(ctx: *anyopaque, level: sdk.LogLevel, msg: []const u8) void {
    const k = connOf(ctx);
    k.host.say(level, k.host.defs[k.chip].name, k.win.id, msg);
}

fn bitOf(kind: sdk.EventKind) u32 {
    return @as(u32, 1) << @intFromEnum(kind);
}

fn connOf(ctx: *anyopaque) *Conn {
    return @ptrCast(@alignCast(ctx));
}

const connection: sdk.Connection = .{ .setChip = setChip, .setPeek = setPeek, .setEpeek = setEpeek, .setDisplayMode = setDisplayMode, .registerEvent = registerEvent, .unregisterEvent = unregisterEvent, .setDialog = setDialog, .showDialog = showDialog, .closeDialog = closeDialog, .shell = shell, .storageOpen = storageOpen, .storageRead = storageRead, .storageWrite = storageWrite, .storageClose = storageClose, .storageDelete = storageDelete, .storageList = storageList };

fn shell(ctx: *anyopaque, buf: []u8) sdk.Error![]const u8 {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    const s = k.host.sink orelse return error.WindowClosed;
    return s.shell(s.ctx, k.win.id, buf);
}

fn storageOf(k: *Conn) sdk.Error!*ExtStorage {
    if (k.closed) return error.WindowClosed;
    return k.host.storage orelse error.StorageFailed;
}

/// A wait on gtty's own thread would freeze it: try once there.
fn waitMs(k: *const Conn, timeout_ms: u32) u32 {
    return if (std.Thread.getCurrentId() == k.host.main_thread) 0 else timeout_ms;
}

fn storageOpen(ctx: *anyopaque, kind: sdk.StorageKind, name: []const u8, mode: sdk.OpenMode, timeout_ms: u32) sdk.Error!u32 {
    const k = connOf(ctx);
    return (try storageOf(k)).open(k.host.defs[k.chip].name, k.win.id, kind, name, mode, waitMs(k, timeout_ms));
}

fn storageRead(ctx: *anyopaque, handle: u32, buf: []u8) sdk.Error!usize {
    const k = connOf(ctx);
    return (try storageOf(k)).read(k.win.id, handle, buf);
}

fn storageWrite(ctx: *anyopaque, handle: u32, bytes: []const u8) sdk.Error!void {
    const k = connOf(ctx);
    return (try storageOf(k)).write(k.win.id, handle, bytes);
}

fn storageClose(ctx: *anyopaque, handle: u32) sdk.Error!void {
    const k = connOf(ctx);
    return (try storageOf(k)).close(k.win.id, handle);
}

fn storageDelete(ctx: *anyopaque, kind: sdk.StorageKind, name: []const u8, timeout_ms: u32) sdk.Error!void {
    const k = connOf(ctx);
    return (try storageOf(k)).delete(k.host.defs[k.chip].name, k.win.id, kind, name, waitMs(k, timeout_ms));
}

fn storageList(ctx: *anyopaque, kind: sdk.StorageKind, out: []u8) sdk.Error!usize {
    const k = connOf(ctx);
    return (try storageOf(k)).list(k.host.defs[k.chip].name, k.win.id, kind, out);
}

fn setChip(ctx: *anyopaque, update: sdk.ChipUpdate) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| s.setChip(s.ctx, k.win.id, k.chip, update);
}

fn setPeek(ctx: *anyopaque, update: ?sdk.PeekUpdate) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.setPeek(s.ctx, k.win.id, k.chip, update);
}

fn setEpeek(ctx: *anyopaque, update: ?sdk.EpeekUpdate) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.setEpeek(s.ctx, k.win.id, k.chip, update);
}

fn setDisplayMode(ctx: *anyopaque, mode: sdk.DisplayMode) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.setDisplayMode(s.ctx, k.win.id, k.chip, mode, k.host.from_user);
}

fn setDialog(ctx: *anyopaque, update: sdk.DialogUpdate) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.setDialog(s.ctx, k.win.id, k.chip, update);
}

fn showDialog(ctx: *anyopaque) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.showDialog(s.ctx, k.win.id, k.chip, k.host.from_user);
}

fn closeDialog(ctx: *anyopaque) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    if (k.host.sink) |s| try s.closeDialog(s.ctx, k.win.id, k.chip);
}

fn registerEvent(ctx: *anyopaque, kind: sdk.EventKind) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    k.mask |= bitOf(kind);
}

fn unregisterEvent(ctx: *anyopaque, kind: sdk.EventKind) sdk.Error!void {
    const k = connOf(ctx);
    if (k.closed) return error.WindowClosed;
    k.mask &= ~bitOf(kind);
}

const Probe = struct {
    var events: u32 = 0;
    var closes: u32 = 0;
    var last_id: u32 = 0;
    var folder: [32]u8 = undefined;
    var folder_len: usize = 0;

    pub fn onWindowStart(win: *sdk.Window) anyerror!void {
        try win.events.registerEvent(.window_changed);
    }
    pub fn onWindowClose(win: *sdk.Window) anyerror!void {
        closes += 1;
        if (win.ui.set(.{ .chip = .{ .text = "late" } })) |_| return error.TestUnexpected else |_| {}
    }
    pub fn onEvent(_: *sdk.Window, ev: *const sdk.Event) anyerror!void {
        events += 1;
        last_id = ev.eventId;
        if (ev.button) |b| {
            @memcpy(folder[0..b.data.len], b.data);
            folder_len = b.data.len;
            return;
        }
        @memcpy(folder[0..ev.folder.len], ev.folder);
        folder_len = ev.folder.len;
    }
    fn reset() void {
        events = 0;
        closes = 0;
        last_id = 0;
    }
};

const probe_defs = [_]sdk.Definition{sdk.Definition.of(Probe, "probe")};

test "an event reaches only what registered for it, at the pump" {
    Probe.reset();
    var h = Host.init(std.testing.allocator, &probe_defs);
    defer h.stop();
    h.windowStarted(7);
    h.fire(7, .{ .kind = .command_started });
    try std.testing.expectEqual(@as(usize, 0), h.queue.items.len); // nobody listens
    h.fire(8, .{ .kind = .window_changed }); // another window
    try std.testing.expectEqual(@as(usize, 0), h.queue.items.len);
    var dir = "/tmp/a".*;
    h.fire(7, .{ .kind = .window_changed, .folder = &dir });
    dir[1] = 'X'; // the event has its own copy
    try std.testing.expectEqual(@as(u32, 0), Probe.events);
    h.pump();
    try std.testing.expectEqual(@as(u32, 1), Probe.events);
    try std.testing.expectEqual(@as(u32, 1), Probe.last_id);
    try std.testing.expectEqualStrings("/tmp/a", Probe.folder[0..Probe.folder_len]);
}

test "a burst is dropped past the limit and spread over frames" {
    Probe.reset();
    var h = Host.init(std.testing.allocator, &probe_defs);
    defer h.stop();
    h.windowStarted(1);
    for (0..max_queued + 10) |_| h.fire(1, .{ .kind = .window_changed });
    try std.testing.expectEqual(@as(u64, 10), h.dropped);
    h.pump();
    try std.testing.expectEqual(@as(u32, pump_max), Probe.events);
    while (h.head < h.queue.items.len) h.pump();
    try std.testing.expectEqual(@as(u32, max_queued), Probe.events);
}

test "a closed window: closed at once, notice at the pump, no more events" {
    Probe.reset();
    var h = Host.init(std.testing.allocator, &probe_defs);
    defer h.stop();
    h.windowStarted(3);
    h.fire(3, .{ .kind = .window_changed });
    h.windowClosed(3);
    try std.testing.expectEqual(@as(u32, 0), Probe.closes);
    h.pump();
    try std.testing.expectEqual(@as(u32, 1), Probe.closes);
    try std.testing.expectEqual(@as(u32, 0), Probe.events);
    try std.testing.expectEqual(@as(usize, 0), h.conns.items.len);
}

const Opener = struct {
    var host: *Host = undefined;
    var opened: u32 = 0;
    pub fn onEvent(_: *sdk.Window, _: *const sdk.Event) anyerror!void {
        // Enough windows that the list of connections moves.
        for (0..64) |i| host.windowStarted(100 + @as(u32, @intCast(i)));
        opened += 1;
    }
};
const opener_defs = [_]sdk.Definition{sdk.Definition.of(Opener, "opener")};

test "a handler can open windows while its click is handed out" {
    var h = Host.init(std.testing.allocator, &opener_defs);
    defer h.stop();
    Opener.host = &h;
    Opener.opened = 0;
    h.windowStarted(1);
    h.click(1, 0, .{}, true);
    h.pump();
    try std.testing.expectEqual(@as(u32, 1), Opener.opened);
    try std.testing.expectEqual(@as(usize, 65), h.conns.items.len);
}

test "filter changes still waiting merge into the latest" {
    Probe.reset();
    var h = Host.init(std.testing.allocator, &probe_defs);
    defer h.stop();
    h.windowStarted(9);
    h.filterChanged(9, 0, .{ .id = "filter", .text = "a", .data = "a" });
    h.filterChanged(9, 0, .{ .id = "filter", .text = "ab" });
    try std.testing.expectEqual(@as(usize, 1), h.queue.items.len);
    try std.testing.expectEqualStrings("ab", h.queue.items[0].click.ev.button.?.text);
    h.pump();
    try std.testing.expectEqual(@as(u32, 1), Probe.events);
    h.filterChanged(9, 0, .{ .id = "filter", .text = "abc" });
    try std.testing.expectEqual(@as(usize, 1), h.queue.items.len);
    h.pump();
}

test "a click reaches its owner without registering, even after its window closed" {
    Probe.reset();
    var h = Host.init(std.testing.allocator, &probe_defs);
    defer h.stop();
    h.windowStarted(5);
    var data = "abc".*;
    h.click(5, 0, .{ .data = &data }, false);
    h.windowClosed(5);
    data[0] = 'X'; // it has its own copy
    h.pump();
    try std.testing.expectEqual(@as(u32, 1), Probe.events);
    try std.testing.expectEqualStrings("abc", Probe.folder[0..Probe.folder_len]);
}
