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
const Extensions = @import("../core/Extensions.zig");
const Proc = @import("Proc.zig");
const DevSocket = @import("DevSocket.zig");

const Host = @This();

pub const max_queued = 256;
pub const pump_max = 64;
/// Chips in a window: the standard ones, then installed extensions'
/// (JobWindow.max_chips).
pub const max_chips = 16;

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
/// Installed extensions running as child processes (Proc.zig); stopping
/// and ended ones stay until `syncInstalled` drops them.
procs: std.ArrayList(*Proc) = .empty,
/// The windows open now, oldest first: a starting extension hears of each.
windows: std.ArrayList(u32) = .empty,
/// Storage calls of extensions waiting for a file.
waiting: std.ArrayList(Waiting) = .empty,
/// The developer socket (`listen`): extensions an IDE started.
dev: ?DevSocket = null,
/// A debugged extension came or went: App runs `syncInstalled` again
/// (the installed copy stops or starts).
rescan: bool = false,
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
    Proc.endAll(h.procs.items);
    if (h.dev) |*d| d.close(h.gpa);
    h.dev = null;
    for (h.procs.items) |p| p.destroy();
    h.procs.deinit(h.gpa);
    for (h.waiting.items) |wt| h.gpa.free(wt.name);
    h.waiting.deinit(h.gpa);
    h.windows.deinit(h.gpa);
    if (h.storage) |st| st.closeAll();
    if (trace.on()) trace.line("chips: {d} events, {d} handler calls, {d} dropped, {d} us in handlers, slowest {d} us", .{ h.fired, h.calls, h.dropped, h.busy_ns / 1000, h.slowest_ns / 1000 });
    for (h.conns.items) |k| h.gpa.destroy(k);
    h.conns.deinit(h.gpa);
    h.queue.deinit(h.gpa);
}

/// A job window started: a connection for each chip, and its
/// `onWindowStart`, where it registers.
pub fn windowStarted(h: *Host, uid: u32) void {
    h.windows.append(h.gpa, uid) catch {};
    for (h.procs.items) |p| if (p.state == .running) p.sendSimple("windowStart", uid);
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
    if (std.mem.indexOfScalar(u32, h.windows.items, uid)) |i| _ = h.windows.orderedRemove(i);
    for (h.procs.items) |p| {
        _ = p.masks.remove(uid);
        if (p.state == .running) p.sendSimple("windowClose", uid);
    }
    h.queue.append(h.gpa, .{ .window_close = uid }) catch {};
}

/// Does any chip listen for `kind` on this window?
pub fn listens(h: *const Host, uid: u32, kind: sdk.EventKind) bool {
    const bit = bitOf(kind);
    for (h.conns.items) |k| if (k.win.id == uid and k.mask & bit != 0) return true;
    for (h.procs.items) |p| if (p.state == .running and p.listens(uid, bit)) return true;
    return false;
}

/// Queue an event of window `uid`; its strings are copied.
pub fn fire(h: *Host, uid: u32, ev: sdk.Event) void {
    if (!h.listens(uid, ev.kind)) return;
    if (h.queue.items.len - h.head >= max_queued) {
        h.dropped += 1;
        return;
    }
    const text = h.gpa.alloc(u8, ev.folder.len + ev.branch.len + ev.command.len + ev.key.len + ev.text.len) catch return;
    var e = ev;
    h.next_id +%= 1;
    e.eventId = h.next_id;
    var at: usize = 0;
    inline for (.{ "folder", "branch", "command", "key", "text" }) |name| {
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
    h.pumpProcs();
    var n: usize = 0;
    while (h.head < h.queue.items.len and n < pump_max) : (n += 1) {
        const item = h.queue.items[h.head];
        h.head += 1;
        switch (item) {
            .event => |q| {
                defer h.gpa.free(q.text);
                // A key is the user's, as a click: a peek or dialog opened
                // for it may take the keyboard.
                const user = q.ev.kind == .key;
                h.from_user = user;
                defer h.from_user = false;
                // By index: a handler can open windows (a session restored).
                var i: usize = 0;
                while (i < h.conns.items.len) : (i += 1) {
                    const k = h.conns.items[i];
                    if (k.win.id != q.uid or k.closed or k.mask & bitOf(q.ev.kind) == 0) continue;
                    const d = h.defs[k.chip];
                    if (d.onEvent) |f| h.timed(d.name, f, &k.win, &q.ev);
                }
                for (h.procs.items) |p| if (p.state == .running and p.listens(q.uid, bitOf(q.ev.kind))) p.sendEvent(q.uid, q.ev, user);
            },
            .click => |q| {
                defer {
                    q.arena.deinit();
                    h.gpa.destroy(q.arena);
                }
                if (h.procOf(q.chip)) |p| {
                    p.sendEvent(q.uid, q.ev, q.user);
                    continue;
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
        var n = @min(h.defs.len, names.len);
        for (h.defs[0..n], names[0..n]) |d, *o| o.* = d.name;
        for (h.procs.items) |p| if (n < names.len) {
            names[n] = p.name;
            n += 1;
        };
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

// ---- installed extensions (child processes) ----

const Waiting = struct {
    p: *Proc,
    uid: u32,
    id: u32,
    op: enum { open, delete },
    kind: sdk.StorageKind,
    mode: sdk.OpenMode,
    name: []u8,
    until_ms: u64,
};

/// Listen for extensions an IDE starts (DevSocket.zig). `tmp`: gtty's
/// own temp folder.
/// `shared`: also take the per-user address the SDKs use by default.
pub fn listen(h: *Host, tmp: []const u8, shared: bool) void {
    h.dev = DevSocket.open(h.gpa, tmp, shared) catch |e| {
        var buf: [96]u8 = undefined;
        h.say(.warn, "gtty", 0, std.fmt.bufPrint(&buf, "no developer socket: {s}", .{@errorName(e)}) catch "no developer socket");
        return;
    };
}

/// The developer socket's own path (`gtty ext socket`).
pub fn devPath(h: *const Host) ?[]const u8 {
    return if (h.dev) |d| d.path else null;
}

/// Once a second (App): take back the shared developer address when the
/// gtty holding it closed.
pub fn tickDev(h: *Host) void {
    if (h.dev) |*d| d.tick();
}

/// The extension of chip `chip`: a standard one's name, or an installed
/// one's.
pub fn nameOf(h: *const Host, chip: usize) []const u8 {
    if (chip < h.defs.len) return h.defs[chip].name;
    for (h.procs.items) |p| if (p.chip == chip and p.state != .ended) return p.name;
    return "extension";
}

fn procOf(h: *const Host, chip: usize) ?*Proc {
    if (chip < h.defs.len) return null;
    for (h.procs.items) |p| if (p.chip == chip and p.state == .running) return p;
    return null;
}

/// What the manager shows of an extension.
pub const ProcStatus = struct { state: Proc.State, pid: c_int, exit_code: c_int, dev: bool };

/// A debugged run wins over the installed one.
pub fn procStatus(h: *const Host, name: []const u8) ?ProcStatus {
    var best: ?ProcStatus = null;
    for (h.procs.items) |p| if (p.state != .attaching and std.mem.eql(u8, p.name, name)) {
        const st: ProcStatus = .{ .state = p.state, .pid = p.shownPid(), .exit_code = p.exit_code, .dev = p.dev };
        if (p.dev and p.state == .running) return st;
        if (best == null or best.?.state != .running) best = st;
    };
    return best;
}

/// Run what is installed and enabled (`list`, from `Extensions.scan`):
/// start the new ones, restart the reinstalled ones, stop the rest. An
/// ended one starts again only when reinstalled or `restart`ed.
pub fn syncInstalled(h: *Host, list: []const Extensions.Installed) void {
    for (h.procs.items) |p| {
        if (p.state != .running or p.dev) continue;
        const keep = for (list) |x| {
            if (std.mem.eql(u8, x.manifest.name, p.name)) break x.enabled and x.stamp == p.stamp;
        } else false;
        if (!keep) h.stopProc(p);
    }
    for (list) |x| {
        if (!x.enabled) continue;
        const known = for (h.procs.items) |p| {
            if (std.mem.eql(u8, p.name, x.manifest.name) and (p.state == .running or (p.stamp == x.stamp and !p.replaced))) break true;
        } else false;
        if (!known) h.startProc(x);
    }
    h.dropEnded(list);
}

/// Start `x` again (the manager's Restart).
pub fn restart(h: *Host, x: Extensions.Installed) void {
    if (h.debugged(x.manifest.name) != null) return h.say(.warn, x.manifest.name, 0, "not restarted: it is being debugged");
    for (h.procs.items) |p| if (std.mem.eql(u8, p.name, x.manifest.name) and p.state == .running) h.stopProc(p);
    h.forget(x.manifest.name);
    h.startProc(x);
}

/// Ended extensions not installed any more, and older runs of one
/// installed again, leave the list.
fn dropEnded(h: *Host, list: []const Extensions.Installed) void {
    var i: usize = 0;
    while (i < h.procs.items.len) {
        const p = h.procs.items[i];
        const installed = for (list) |x| {
            if (std.mem.eql(u8, x.manifest.name, p.name)) break x.enabled and x.stamp == p.stamp;
        } else false;
        const newer = for (h.procs.items) |q| {
            if (q != p and q.state == .running and std.mem.eql(u8, q.name, p.name)) break true;
        } else false;
        if (p.state == .ended and (!installed or newer)) {
            _ = h.procs.orderedRemove(i);
            p.destroy();
        } else i += 1;
    }
}

fn forget(h: *Host, name: []const u8) void {
    var i: usize = 0;
    while (i < h.procs.items.len) {
        const p = h.procs.items[i];
        if (p.state == .ended and std.mem.eql(u8, p.name, name)) {
            _ = h.procs.orderedRemove(i);
            p.destroy();
        } else i += 1;
    }
}

/// The debugged run of `name`, if one is connected.
fn debugged(h: *const Host, name: []const u8) ?*Proc {
    for (h.procs.items) |p| if (p.dev and (p.state == .running or p.state == .stopping) and std.mem.eql(u8, p.name, name)) return p;
    return null;
}

fn freeChip(h: *const Host) ?usize {
    var chip = h.defs.len;
    while (chip < max_chips) : (chip += 1) {
        const used = for (h.procs.items) |p| {
            if (p.chip == chip and p.state != .ended) break true;
        } else false;
        if (!used) return chip;
    }
    return null;
}

fn startProc(h: *Host, x: Extensions.Installed) void {
    const chip = h.freeChip() orelse return h.say(.err, x.manifest.name, 0, "not started: no room for another chip");
    const p = Proc.start(h.gpa, x, chip, h.log) catch |e| {
        var buf: [160]u8 = undefined;
        const m = if (e == error.NoRuntime)
            std.fmt.bufPrint(&buf, "not started: {s} isn't installed", .{x.manifest.runtime}) catch "not started"
        else
            std.fmt.bufPrint(&buf, "not started: {s}", .{@errorName(e)}) catch "not started";
        return h.say(.err, x.manifest.name, 0, m);
    };
    h.procs.append(h.gpa, p) catch {
        p.stop();
        p.destroy();
        return;
    };
    // Its own ended runs: it has the chip now.
    var i: usize = 0;
    while (i < h.procs.items.len) {
        const q = h.procs.items[i];
        if (q != p and q.state == .ended and std.mem.eql(u8, q.name, p.name)) {
            _ = h.procs.orderedRemove(i);
            q.destroy();
        } else i += 1;
    }
    h.greet(p);
    var buf: [64]u8 = undefined;
    h.say(.info, p.name, 0, std.fmt.bufPrint(&buf, "started, pid {d}", .{p.pid}) catch "started");
}

/// `hello`, `gttyStart` and a `windowStart` for each open window.
fn greet(h: *Host, p: *Proc) void {
    var o: Proc.Out = undefined;
    p.begin(&o, "hello");
    o.field("api", sdk.api_version);
    o.field("name", p.name);
    o.end(false);
    p.sendSimple("gttyStart", null);
    for (h.windows.items) |uid| p.sendSimple("windowStart", uid);
}

/// New connections on the developer socket.
fn acceptDev(h: *Host) void {
    const d = if (h.dev) |*x| x else return;
    for (0..4) |_| {
        const conn = d.accept() orelse return;
        const p = Proc.accept(h.gpa, conn.fd, conn.pid, h.log) catch {
            _ = c.close(conn.fd);
            return;
        };
        h.procs.append(h.gpa, p) catch {
            p.destroy();
            return;
        };
    }
}

/// The first message of a developer connection: `attach`, naming the
/// extension (`name`, else the `manifest.json` in `dir`).
fn attach(h: *Host, p: *Proc, line: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(sdk.wire.Value, a, line, .{}) catch return p.refuse("the first message isn't JSON");
    const o = switch (v) {
        .object => |o| o,
        else => return p.refuse("the first message isn't an object"),
    };
    if (!eql(str(o.get("t")) orelse "", "attach")) return p.refuse("the first message must be attach");
    if (num(o.get("api")) != sdk.api_version) return p.refuse("this gtty speaks protocol version 1");
    var name = str(o.get("name")) orelse "";
    if (name.len == 0) {
        const dir = str(o.get("dir")) orelse return p.refuse("no name: set GTTY_EXT_NAME or start it in the folder of its manifest.json");
        const file = std.fmt.allocPrint(a, "{s}/manifest.json", .{dir}) catch return p.refuse("out of memory");
        const json = readSmall(a, file) orelse return p.refuse("no name: set GTTY_EXT_NAME or start it in the folder of its manifest.json");
        // Only the name is needed: a `main` for another machine is fine.
        const mv = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return p.refuse("its manifest.json isn't JSON");
        const m = if (mv == .object) str(mv.object.get("name")) else null;
        name = m orelse return p.refuse("its manifest.json has no name");
    }
    h.attachAs(p, name);
}

fn attachAs(h: *Host, p: *Proc, name: []const u8) void {
    if (!Extensions.validName(name)) return p.refuse("not a valid extension name (lowercase letters, digits, - and _)");
    for (Extensions.reserved) |r| if (eql(r, name)) return p.refuse("that name is gtty's own");
    if (h.debugged(name) != null) return p.refuse("that extension is already being debugged in this gtty");
    // The installed copy makes room for it.
    for (h.procs.items) |q| if (!q.dev and q.state == .running and eql(q.name, name)) {
        q.replaced = true;
        h.stopProc(q);
    };
    const chip = h.freeChip() orelse return p.refuse("no room for another chip");
    p.attached(name, chip) catch return p.refuse("out of memory");
    if (h.storage) |st| st.setDev(name, true);
    h.rescan = true;
    h.greet(p);
    var buf: [64]u8 = undefined;
    h.say(.info, p.name, 0, std.fmt.bufPrint(&buf, "debugging, pid {d}", .{p.peer_pid}) catch "debugging");
}

fn readSmall(a: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = a.dupeZ(u8, path) catch return null;
    const fd = c.open(z.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    var chunk: [4096]u8 = undefined;
    while (buf.items.len < 1 << 20) {
        const n = c.read(fd, &chunk, chunk.len);
        if (n <= 0) break;
        buf.appendSlice(a, chunk[0..@intCast(n)]) catch return null;
    }
    return buf.items;
}


fn stopProc(h: *Host, p: *Proc) void {
    p.stop();
    h.clearUi(p);
}

/// Its chips, peeks, epeeks and dialogs go, and its open files.
fn clearUi(h: *Host, p: *Proc) void {
    const s = h.sink orelse return;
    for (h.windows.items) |uid| {
        s.setChip(s.ctx, uid, p.chip, .{ .text = .clear });
        s.setPeek(s.ctx, uid, p.chip, null) catch {};
        s.setEpeek(s.ctx, uid, p.chip, null) catch {};
        s.closeDialog(s.ctx, uid, p.chip) catch {};
        if (h.storage) |st| st.closeWindow(uid, &.{p.name});
    }
    var i: usize = 0;
    while (i < h.waiting.items.len) {
        if (h.waiting.items[i].p == p) {
            h.gpa.free(h.waiting.items[i].name);
            _ = h.waiting.orderedRemove(i);
        } else i += 1;
    }
}

fn pumpProcs(h: *Host) void {
    h.acceptDev();
    var i: usize = 0;
    while (i < h.procs.items.len) : (i += 1) {
        const p = h.procs.items[i];
        const was = p.state;
        p.pump(h, procLine);
        if (p.dropped > 0) {
            var buf: [80]u8 = undefined;
            h.say(.warn, p.name, 0, std.fmt.bufPrint(&buf, "{d} events dropped: it doesn't read", .{p.dropped}) catch "events dropped");
            p.dropped = 0;
        }
        if (was == .running and p.state == .ended) h.clearUi(p);
        if (p.dev and was != .ended and was != .attaching and p.state == .ended) {
            if (h.storage) |st| st.setDev(p.name, false);
            h.rescan = true;
        }
        // The socket closed but the process lives on: end it.
        if (p.state == .running and p.sock < 0) p.stop();
    }
    h.retryWaiting();
}

fn hasWindow(h: *const Host, uid: u32) bool {
    return std.mem.indexOfScalar(u32, h.windows.items, uid) != null;
}

fn num(v: ?sdk.wire.Value) u32 {
    return switch (v orelse return 0) {
        .integer => |n| std.math.cast(u32, n) orelse 0,
        else => 0,
    };
}

fn str(v: ?sdk.wire.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |x| x,
        else => null,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn procLine(h: *Host, p: *Proc, line: []const u8) void {
    if (p.state == .attaching) return h.attach(p, line);
    if (p.state != .running) return;
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(sdk.wire.Value, a, line, .{}) catch return h.say(.err, p.name, 0, "a message that isn't JSON: dropped");
    const o = switch (v) {
        .object => |o| o,
        else => return h.say(.err, p.name, 0, "a message that isn't an object: dropped"),
    };
    const t = str(o.get("t")) orelse return h.say(.err, p.name, 0, "a message with no \"t\": dropped");
    const uid = num(o.get("win"));
    if (eql(t, "log")) {
        const level = sdk.wire.decode(sdk.LogLevel, a, o.get("level") orelse .null) catch .info;
        return h.say(level, p.name, uid, str(o.get("message")) orelse "");
    }
    if (!h.hasWindow(uid)) {
        if (eql(t, "call")) p.sendError(num(o.get("id")), error.WindowClosed);
        return;
    }
    if (eql(t, "call")) return h.procCall(p, uid, o, a);
    const s = h.sink orelse return;
    const result: anyerror!void = blk: {
        if (eql(t, "set")) {
            if (o.get("chip")) |x| break :blk s.setChip(s.ctx, uid, p.chip, sdk.wire.decode(sdk.ChipUpdate, a, x) catch |e| break :blk e);
            if (o.get("peek")) |x| break :blk s.setPeek(s.ctx, uid, p.chip, if (x == .null) null else sdk.wire.decode(sdk.PeekUpdate, a, x) catch |e| break :blk e);
            if (o.get("epeek")) |x| break :blk s.setEpeek(s.ctx, uid, p.chip, if (x == .null) null else sdk.wire.decode(sdk.EpeekUpdate, a, x) catch |e| break :blk e);
            if (o.get("dialog")) |x| break :blk s.setDialog(s.ctx, uid, p.chip, sdk.wire.decode(sdk.DialogUpdate, a, x) catch |e| break :blk e);
            break :blk error.BadMessage;
        }
        if (eql(t, "mode")) {
            const mode = sdk.wire.decode(sdk.DisplayMode, a, o.get("mode") orelse .null) catch |e| break :blk e;
            break :blk s.setDisplayMode(s.ctx, uid, p.chip, mode, p.fromUser(num(o.get("ev"))));
        }
        if (eql(t, "showDialog")) break :blk s.showDialog(s.ctx, uid, p.chip, p.fromUser(num(o.get("ev"))));
        if (eql(t, "closeDialog")) break :blk s.closeDialog(s.ctx, uid, p.chip);
        if (eql(t, "register") or eql(t, "unregister")) {
            const kind = sdk.wire.decode(sdk.EventKind, a, o.get("event") orelse .null) catch |e| break :blk e;
            const m = p.masks.getOrPut(h.gpa, uid) catch break :blk;
            if (!m.found_existing) m.value_ptr.* = 0;
            if (eql(t, "register")) m.value_ptr.* |= bitOf(kind) else m.value_ptr.* &= ~bitOf(kind);
            break :blk;
        }
        break :blk error.UnknownMessage;
    };
    result catch |e| {
        if (e == error.WindowClosed) return;
        var buf: [96]u8 = undefined;
        h.say(.err, p.name, uid, std.fmt.bufPrint(&buf, "{s}: {s}", .{ t, @errorName(e) }) catch t);
    };
}

fn procCall(h: *Host, p: *Proc, uid: u32, o: std.json.ObjectMap, a: std.mem.Allocator) void {
    const id = num(o.get("id"));
    const op = str(o.get("op")) orelse return p.sendError(id, error.BadMessage);
    if (eql(op, "shell")) {
        const s = h.sink orelse return p.sendError(id, error.WindowClosed);
        var buf: [64]u8 = undefined;
        const name = s.shell(s.ctx, uid, &buf) catch |e| return p.sendError(id, e);
        return p.sendReply(id, name);
    }
    const st = h.storage orelse return p.sendError(id, error.StorageFailed);
    const kind = sdk.wire.decode(sdk.StorageKind, a, o.get("storage") orelse .null) catch .stateful;
    if (eql(op, "open") or eql(op, "delete")) {
        const name = str(o.get("name")) orelse return p.sendError(id, error.BadName);
        const mode = sdk.wire.decode(sdk.OpenMode, a, o.get("mode") orelse .null) catch .read;
        const wt: Waiting = .{ .p = p, .uid = uid, .id = id, .op = if (eql(op, "open")) .open else .delete, .kind = kind, .mode = mode, .name = @constCast(name), .until_ms = c.SDL_GetTicks() + num(o.get("timeout")) };
        if (h.tryWaiting(st, wt)) return;
        var kept = wt;
        kept.name = h.gpa.dupe(u8, name) catch return p.sendError(id, error.StorageFailed);
        h.waiting.append(h.gpa, kept) catch {
            h.gpa.free(kept.name);
            p.sendError(id, error.FileInUse);
        };
        return;
    }
    const handle = num(o.get("handle"));
    if (eql(op, "read")) {
        const max = @max(1, @min(num(o.get("max")), 1 << 20));
        const buf = a.alloc(u8, max) catch return p.sendError(id, error.StorageFailed);
        const n = st.read(uid, handle, buf) catch |e| return p.sendError(id, e);
        const enc = std.base64.standard.Encoder;
        const b64 = a.alloc(u8, enc.calcSize(n)) catch return p.sendError(id, error.StorageFailed);
        return p.sendReply(id, enc.encode(b64, buf[0..n]));
    }
    if (eql(op, "write")) {
        const data = str(o.get("data")) orelse "";
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(data) catch return p.sendError(id, error.BadMessage);
        const bytes = a.alloc(u8, n) catch return p.sendError(id, error.StorageFailed);
        dec.decode(bytes, data) catch return p.sendError(id, error.BadMessage);
        st.write(uid, handle, bytes) catch |e| return p.sendError(id, e);
        return p.sendReply(id, true);
    }
    if (eql(op, "close")) {
        st.close(uid, handle) catch |e| return p.sendError(id, e);
        return p.sendReply(id, true);
    }
    if (eql(op, "list")) {
        const out = a.alloc(u8, 64 * 1024) catch return p.sendError(id, error.StorageFailed);
        const n = st.list(p.name, uid, kind, out) catch |e| return p.sendError(id, e);
        var names: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, out[0..n], '\n');
        while (it.next()) |x| names.append(a, x) catch break;
        return p.sendReply(id, names.items);
    }
    p.sendError(id, error.UnknownCall);
}

/// One try at a waiting open / delete; true: answered.
fn tryWaiting(h: *Host, st: *ExtStorage, wt: Waiting) bool {
    _ = h;
    const r: ExtStorage.Error!u32 = switch (wt.op) {
        .open => st.open(wt.p.name, wt.uid, wt.kind, wt.name, wt.mode, 0),
        .delete => if (st.delete(wt.p.name, wt.uid, wt.kind, wt.name, 0)) 1 else |e| e,
    };
    const v = r catch |e| {
        if (e == error.FileInUse and c.SDL_GetTicks() < wt.until_ms) return false;
        wt.p.sendError(wt.id, e);
        return true;
    };
    if (wt.op == .open) wt.p.sendReply(wt.id, v) else wt.p.sendReply(wt.id, true);
    return true;
}

fn retryWaiting(h: *Host) void {
    const st = h.storage orelse return;
    var i: usize = 0;
    while (i < h.waiting.items.len) {
        const wt = h.waiting.items[i];
        if (wt.p.state == .running and h.hasWindow(wt.uid) and !h.tryWaiting(st, wt)) {
            i += 1;
            continue;
        }
        if (wt.p.state == .running and !h.hasWindow(wt.uid)) wt.p.sendError(wt.id, error.WindowClosed);
        h.gpa.free(wt.name);
        _ = h.waiting.orderedRemove(i);
    }
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
