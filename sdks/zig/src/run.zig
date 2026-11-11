// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! An extension as its own program: `pub fn main() !void { try
//! gtty.run(@This()); }`. gtty starts it with a socket on fd 3
//! (docs/protocol.md); this reads gtty's messages, calls the extension's
//! functions and sends its calls back. Needs libc (`link_libc`).
//!
//! Callbacks run one at a time on the main thread. `log` may be called
//! from other threads; nothing else may.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("gtty.zig");
const wire = @import("wire.zig");

const gpa = std.heap.c_allocator;

const Win = struct {
    win: sdk.Window,
    closed: bool = false,
};

const Rt = struct {
    fd: c_int = -1,
    def: sdk.Definition = .{ .name = "" },
    name: []const u8 = "",
    inbuf: std.ArrayList(u8) = .empty,
    /// Messages read while waiting for a reply, handed out after it.
    pending: std.ArrayList([]u8) = .empty,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    next_id: u32 = 0,
    /// The event being handled.
    current_ev: u32 = 0,
    write_lock: std.atomic.Mutex = .unlocked,
};

var rt: Rt = .{};

/// Run extension `M` (its `onGttyStart`, `onWindowStart`, `onWindowClose`,
/// `onGttyClose`, `onEvent`) until gtty closes. Returns when gtty closes
/// the connection.
pub fn run(comptime M: type) !void {
    rt.def = sdk.Definition.of(M, "");
    rt.name = if (std.c.getenv("GTTY_EXT_NAME")) |n| std.mem.span(n) else "extension";
    const conn = try connect();
    rt.fd = conn.fd;
    if (conn.debugging) {
        // Started by an IDE: say which extension this is.
        var cwd: [4096]u8 = undefined;
        const dir = if (std.c.getcwd(&cwd, cwd.len)) |p| std.mem.span(@as([*:0]u8, @ptrCast(p))) else "";
        var m: Msg = undefined;
        try m.begin("attach", 0);
        try m.field("api", sdk.api_version);
        try m.field("name", if (std.c.getenv("GTTY_EXT_NAME")) |n| std.mem.span(n) else "");
        try m.field("dir", dir);
        try m.send();
    }
    while (true) {
        const line = (try nextLine()) orelse return;
        defer gpa.free(line);
        if (!handle(line)) return;
    }
}

/// gtty's socket on GTTY_EXT_FD, or the developer socket when an IDE
/// started it (`debugging`).
fn connect() !struct { fd: c_int, debugging: bool } {
    if (std.c.getenv("GTTY_EXT_FD")) |s| return .{ .fd = std.fmt.parseInt(c_int, std.mem.span(s), 10) catch return error.NoGtty, .debugging = false };
    var buf: [4096]u8 = undefined;
    if (devSocket(&buf)) |path| {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd >= 0) {
            var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
            if (path.len < addr.path.len) {
                @memcpy(addr.path[0..path.len], path);
                if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) == 0) return .{ .fd = fd, .debugging = true };
            }
            _ = std.c.close(fd);
        }
    }
    std.debug.print("No gtty to connect to: start gtty first (or set GTTY_EXT_SOCKET, see `gtty ext socket`).\n", .{});
    return error.NoGtty;
}

/// Where an extension gtty didn't start connects: GTTY_EXT_SOCKET, else
/// the newest gtty's shared address (only when the folder is this user's
/// alone).
fn devSocket(buf: []u8) ?[]const u8 {
    if (std.c.getenv("GTTY_EXT_SOCKET")) |p| return std.mem.span(p);
    const tmp = if (std.c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    var fbuf: [4096]u8 = undefined;
    const folder = std.fmt.bufPrintSentinel(&fbuf, "{s}/gtty-dev-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), std.c.getuid() }, 0) catch return null;
    if (!ownFolder(folder)) return null;
    return std.fmt.bufPrint(buf, "{s}/ext.sock", .{folder}) catch null;
}

fn ownFolder(path: [:0]const u8) bool {
    var uid: u32 = 0;
    var mode: u32 = 0;
    if (builtin.os.tag == .linux) {
        var sx: std.os.linux.Statx = undefined;
        if (std.c.statx(std.c.AT.FDCWD, path.ptr, std.c.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &sx) != 0) return false;
        uid = sx.uid;
        mode = sx.mode;
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, path.ptr, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return false;
        uid = st.uid;
        mode = st.mode;
    }
    return uid == std.c.getuid() and mode & std.c.S.IFMT == std.c.S.IFDIR and mode & 0o077 == 0;
}

/// The next message: a pending one first. Null: gtty is gone.
fn nextLine() !?[]u8 {
    if (rt.pending.items.len > 0) return rt.pending.orderedRemove(0);
    return readLine();
}

fn readLine() !?[]u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, rt.inbuf.items, '\n')) |end| {
            const line = try gpa.dupe(u8, rt.inbuf.items[0..end]);
            const rest = rt.inbuf.items.len - end - 1;
            std.mem.copyForwards(u8, rt.inbuf.items[0..rest], rt.inbuf.items[end + 1 ..]);
            rt.inbuf.shrinkRetainingCapacity(rest);
            return line;
        }
        var buf: [65536]u8 = undefined;
        const n = std.c.read(rt.fd, &buf, buf.len);
        if (n <= 0) {
            if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return null;
        }
        try rt.inbuf.appendSlice(gpa, buf[0..@intCast(n)]);
    }
}

/// One message from gtty; false: stop.
fn handle(line: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(wire.Value, a, line, .{}) catch return true;
    const o = switch (v) {
        .object => |o| o,
        else => return true,
    };
    const t = str(o.get("t")) orelse return true;
    const id = num(o.get("win"));
    if (eql(t, "refused")) {
        std.debug.print("gtty refused the connection: {s}\n", .{str(o.get("reason")) orelse ""});
        std.process.exit(1);
    }
    if (eql(t, "hello")) {
        if (num(o.get("api")) != sdk.api_version) {
            std.debug.print("gtty speaks extension API {d}, this SDK {d}\n", .{ num(o.get("api")), sdk.api_version });
            return false;
        }
        if (str(o.get("name"))) |n| rt.name = gpa.dupe(u8, n) catch rt.name;
    } else if (eql(t, "gttyStart")) {
        if (rt.def.onGttyStart) |f| {
            var ext = extension();
            f(&ext) catch |e| report(0, "onGttyStart", e);
        }
    } else if (eql(t, "gttyClose")) {
        if (rt.def.onGttyClose) |f| {
            var ext = extension();
            f(&ext) catch |e| report(0, "onGttyClose", e);
        }
        return false;
    } else if (eql(t, "windowStart")) {
        const w = gpa.create(Win) catch return true;
        w.* = .{ .win = window(w, id) };
        rt.windows.put(gpa, id, w) catch {
            gpa.destroy(w);
            return true;
        };
        if (rt.def.onWindowStart) |f| f(&w.win) catch |e| report(id, "onWindowStart", e);
    } else if (eql(t, "windowClose")) {
        const kv = rt.windows.fetchRemove(id) orelse return true;
        kv.value.closed = true;
        if (rt.def.onWindowClose) |f| f(&kv.value.win) catch |e| report(id, "onWindowClose", e);
        gpa.destroy(kv.value);
    } else if (eql(t, "event")) {
        const w = rt.windows.get(id) orelse return true;
        const ev = wire.decode(sdk.Event, a, o.get("event") orelse return true) catch return true;
        rt.current_ev = ev.eventId;
        defer rt.current_ev = 0;
        if (rt.def.onEvent) |f| f(&w.win, &ev) catch |e| report(id, "onEvent", e);
    }
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn str(v: ?wire.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn num(v: ?wire.Value) u32 {
    return switch (v orelse return 0) {
        .integer => |n| std.math.cast(u32, n) orelse 0,
        else => 0,
    };
}

fn report(win: u32, callback: []const u8, e: anyerror) void {
    if (e == error.WindowClosed) return;
    var buf: [128]u8 = undefined;
    sendLog(win, .err, std.fmt.bufPrint(&buf, "{s} returned {s}", .{ callback, @errorName(e) }) catch callback);
}

fn extension() sdk.Extension {
    return .{ .name = rt.name, .logger = .{ .ctx = @ptrFromInt(1), .write = extLog } };
}

fn window(w: *Win, id: u32) sdk.Window {
    return .{
        .id = id,
        .ui = .{ .ctx = w, .conn = &connection },
        .events = .{ .ctx = w, .conn = &connection },
        .ephemeral = .{ .ctx = w, .conn = &connection, .kind = .ephemeral },
        .stateful = .{ .ctx = w, .conn = &connection, .kind = .stateful },
        .logger = .{ .ctx = w, .write = winLog },
    };
}

fn winOf(ctx: *anyopaque) *Win {
    return @ptrCast(@alignCast(ctx));
}

// ---- sending ----

const Msg = struct {
    out: std.Io.Writer.Allocating,
    s: wire.Stringify,

    fn begin(m: *Msg, t: []const u8, win: u32) !void {
        m.out = .init(gpa);
        m.s = .{ .writer = &m.out.writer };
        try m.s.beginObject();
        try m.field("t", t);
        try m.field("win", win);
    }

    fn field(m: *Msg, key: []const u8, v: anytype) !void {
        try m.s.objectField(key);
        try wire.encode(&m.s, v);
    }

    /// Ends and sends it.
    fn send(m: *Msg) !void {
        defer m.out.deinit();
        try m.s.endObject();
        try m.out.writer.writeByte('\n');
        writeAll(m.out.written());
    }
};

fn writeAll(bytes: []const u8) void {
    while (!rt.write_lock.tryLock()) std.atomic.spinLoopHint();
    defer rt.write_lock.unlock();
    var left = bytes;
    while (left.len > 0) {
        const n = std.c.write(rt.fd, left.ptr, left.len);
        if (n <= 0) {
            if (n < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return; // gtty is gone: the read loop ends
        }
        left = left[@intCast(n)..];
    }
}

fn sendLog(win: u32, level: sdk.LogLevel, message: []const u8) void {
    var m: Msg = undefined;
    m.begin("log", win) catch return;
    m.field("level", level) catch return m.out.deinit();
    m.field("message", message) catch return m.out.deinit();
    m.send() catch {};
}

fn extLog(_: *anyopaque, level: sdk.LogLevel, message: []const u8) void {
    sendLog(0, level, message);
}

fn winLog(ctx: *anyopaque, level: sdk.LogLevel, message: []const u8) void {
    sendLog(winOf(ctx).win.id, level, message);
}

fn post(ctx: *anyopaque, t: []const u8, key: ?[]const u8, v: anytype) sdk.Error!void {
    const w = winOf(ctx);
    if (w.closed) return error.WindowClosed;
    var m: Msg = undefined;
    m.begin(t, w.win.id) catch return error.StorageFailed;
    if (key) |k| m.field(k, v) catch {
        m.out.deinit();
        return error.StorageFailed;
    };
    if (eql(t, "mode") or eql(t, "showDialog")) m.field("ev", rt.current_ev) catch {};
    m.send() catch return error.StorageFailed;
}

fn setChip(ctx: *anyopaque, u: sdk.ChipUpdate) sdk.Error!void {
    return post(ctx, "set", "chip", u);
}
fn setPeek(ctx: *anyopaque, u: ?sdk.PeekUpdate) sdk.Error!void {
    return post(ctx, "set", "peek", u);
}
fn setEpeek(ctx: *anyopaque, u: ?sdk.EpeekUpdate) sdk.Error!void {
    return post(ctx, "set", "epeek", u);
}
fn setDialog(ctx: *anyopaque, u: sdk.DialogUpdate) sdk.Error!void {
    return post(ctx, "set", "dialog", u);
}
fn setMode(ctx: *anyopaque, mode: sdk.DisplayMode) sdk.Error!void {
    return post(ctx, "mode", "mode", mode);
}
fn showDialog(ctx: *anyopaque) sdk.Error!void {
    return post(ctx, "showDialog", null, null);
}
fn closeDialog(ctx: *anyopaque) sdk.Error!void {
    return post(ctx, "closeDialog", null, null);
}
fn registerEvent(ctx: *anyopaque, kind: sdk.EventKind) sdk.Error!void {
    if (kind == .button_click) return;
    return post(ctx, "register", "event", kind);
}
fn unregisterEvent(ctx: *anyopaque, kind: sdk.EventKind) sdk.Error!void {
    if (kind == .button_click) return;
    return post(ctx, "unregister", "event", kind);
}

// ---- calls ----

const Reply = struct {
    arena: std.heap.ArenaAllocator,
    value: wire.Value,

    fn deinit(r: *Reply) void {
        r.arena.deinit();
    }
};

/// Send a call with `fields` (a struct), wait for its reply.
fn call(ctx: *anyopaque, op: []const u8, fields: anytype) sdk.Error!Reply {
    const w = winOf(ctx);
    if (w.closed) return error.WindowClosed;
    rt.next_id +%= 1;
    const id = rt.next_id;
    var m: Msg = undefined;
    m.begin("call", w.win.id) catch return error.StorageFailed;
    m.field("id", id) catch {};
    m.field("op", op) catch {};
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |f| m.field(f.name, @field(fields, f.name)) catch {};
    m.send() catch return error.StorageFailed;
    while (true) {
        const line = (readLine() catch return error.StorageFailed) orelse return error.WindowClosed;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        const v = std.json.parseFromSliceLeaky(wire.Value, arena.allocator(), line, .{}) catch {
            arena.deinit();
            gpa.free(line);
            continue;
        };
        const o = switch (v) {
            .object => |o| o,
            else => {
                arena.deinit();
                gpa.free(line);
                continue;
            },
        };
        if (!eql(str(o.get("t")) orelse "", "reply") or num(o.get("id")) != id) {
            arena.deinit();
            rt.pending.append(gpa, line) catch gpa.free(line);
            continue;
        }
        gpa.free(line);
        if (str(o.get("error"))) |e| {
            const err = errorOf(e); // before the arena holding `e` goes
            arena.deinit();
            return err;
        }
        return .{ .arena = arena, .value = o.get("value") orelse .null };
    }
}

fn errorOf(name: []const u8) sdk.Error {
    inline for (@typeInfo(sdk.Error).error_set.?) |e| if (eql(name, e.name)) return @field(sdk.Error, e.name);
    return error.StorageFailed;
}

fn shell(ctx: *anyopaque, buf: []u8) sdk.Error![]const u8 {
    var r = try call(ctx, "shell", .{});
    defer r.deinit();
    const s = str(r.value) orelse "";
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn stOpen(ctx: *anyopaque, kind: sdk.StorageKind, name: []const u8, mode: sdk.OpenMode, timeout_ms: u32) sdk.Error!u32 {
    var r = try call(ctx, "open", .{ .storage = kind, .name = name, .mode = mode, .timeout = timeout_ms });
    defer r.deinit();
    return num(r.value);
}

fn stRead(ctx: *anyopaque, handle_: u32, buf: []u8) sdk.Error!usize {
    var r = try call(ctx, "read", .{ .handle = handle_, .max = @min(buf.len, 1 << 20) });
    defer r.deinit();
    const s = str(r.value) orelse "";
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return error.StorageFailed;
    if (n > buf.len) return error.StorageFailed;
    dec.decode(buf[0..n], s) catch return error.StorageFailed;
    return n;
}

fn stWrite(ctx: *anyopaque, handle_: u32, bytes: []const u8) sdk.Error!void {
    var at: usize = 0;
    while (true) {
        const part = bytes[at..@min(bytes.len, at + (1 << 20))];
        const enc = std.base64.standard.Encoder;
        const b64 = gpa.alloc(u8, enc.calcSize(part.len)) catch return error.StorageFailed;
        defer gpa.free(b64);
        var r = try call(ctx, "write", .{ .handle = handle_, .data = enc.encode(b64, part) });
        r.deinit();
        at += part.len;
        if (at >= bytes.len) return;
    }
}

fn stClose(ctx: *anyopaque, handle_: u32) sdk.Error!void {
    var r = try call(ctx, "close", .{ .handle = handle_ });
    r.deinit();
}

fn stDelete(ctx: *anyopaque, kind: sdk.StorageKind, name: []const u8, timeout_ms: u32) sdk.Error!void {
    var r = try call(ctx, "delete", .{ .storage = kind, .name = name, .timeout = timeout_ms });
    r.deinit();
}

fn stList(ctx: *anyopaque, kind: sdk.StorageKind, out: []u8) sdk.Error!usize {
    var r = try call(ctx, "list", .{ .storage = kind });
    defer r.deinit();
    var n: usize = 0;
    const items = switch (r.value) {
        .array => |x| x.items,
        else => return 0,
    };
    for (items) |it| {
        const s = str(it) orelse continue;
        if (n + s.len + 1 > out.len) break;
        @memcpy(out[n..][0..s.len], s);
        out[n + s.len] = '\n';
        n += s.len + 1;
    }
    return n;
}

const connection: sdk.Connection = .{ .setChip = setChip, .setPeek = setPeek, .setEpeek = setEpeek, .setDisplayMode = setMode, .registerEvent = registerEvent, .unregisterEvent = unregisterEvent, .setDialog = setDialog, .showDialog = showDialog, .closeDialog = closeDialog, .shell = shell, .storageOpen = stOpen, .storageRead = stRead, .storageWrite = stWrite, .storageClose = stClose, .storageDelete = stDelete, .storageList = stList };
