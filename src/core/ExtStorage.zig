// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The extensions' files (docs/extensions.md, "Storage"). Two storages:
//!
//!   * **Ephemeral:** a folder per instance (an extension in a job window)
//!     under gtty's temp folder, deleted when the instance ends.
//!   * **Stateful:** `<root>/<extension>/data`, one folder for all
//!     instances, in every gtty on the machine. A file open for writing
//!     keeps everyone else out; several can read. Opens wait up to a
//!     timeout (`acquire`). A write goes to a temp file and replaces the
//!     real one at `close`, so nobody ever sees it half written.
//!
//! The locks are `flock`s on files in `locks` (`<extension>/<name>.lock`),
//! which work between gtty processes. Each has a `.gate`: a waiting write
//! holds it, and readers pass through it, so they queue behind the write.
//! `forceUnlock` removes lock files: a stuck holder keeps a lock on a file
//! nobody opens any more. Every gtty holds a shared lock on `locks/running`:
//! the last one out, or the first one in after a crash, empties the folder.

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;

const ExtStorage = @This();

/// How long a file can stay open before gtty closes it.
pub const hold_ms: u64 = 30_000;
/// The same for an extension being debugged (`setDev`): it may sit at a
/// breakpoint with the file open.
pub const dev_hold_ms: u64 = 30 * 60 * 1000;
const poll_us = 2000;
const name_max = 200;

pub const Error = error{ BadName, NoFile, FileInUse, FileClosed, StorageFull, StorageFailed };

const Open = struct {
    id: u32,
    uid: u32,
    kind: sdk.StorageKind,
    mode: sdk.OpenMode,
    fd: c_int,
    /// The stateful file's lock; -1 for ephemeral.
    lock_fd: c_int,
    /// The real file, and the temp file a write goes to.
    path: [:0]u8,
    tmp: ?[:0]u8,
    opened_ms: u64,
    hold: u64 = hold_ms,
    /// What the folder holds without this file, and what was written.
    used: u64 = 0,
    written: u64 = 0,
};

gpa: std.mem.Allocator,
root: [:0]u8,
locks: [:0]u8,
tmp: [:0]u8,
/// Most bytes in one storage folder.
limit: u64,
files: std.ArrayList(Open) = .empty,
next_id: u32 = 0,
/// Extensions may call from their own threads; held only for a moment.
busy: std.atomic.Value(bool) = .init(false),
running_fd: c_int = -1,
/// Extensions being debugged (`setDev`): their files may stay open longer.
dev: [8]?[64]u8 = @splat(null),

pub fn init(gpa: std.mem.Allocator, root: []const u8, locks: []const u8, tmp: []const u8, limit_mb: u64) !ExtStorage {
    const r = try gpa.dupeZ(u8, root);
    errdefer gpa.free(r);
    const l = try gpa.dupeZ(u8, locks);
    errdefer gpa.free(l);
    return .{ .gpa = gpa, .root = r, .locks = l, .tmp = try gpa.dupeZ(u8, tmp), .limit = limit_mb * 1024 * 1024 };
}

pub fn deinit(s: *ExtStorage) void {
    s.closeAll();
    s.files.deinit(s.gpa);
    s.gpa.free(s.root);
    s.gpa.free(s.locks);
    s.gpa.free(s.tmp);
}

/// `ext` is being debugged (on) or not any more.
pub fn setDev(s: *ExtStorage, ext: []const u8, on: bool) void {
    if (ext.len > 63) return;
    s.lock();
    defer s.unlock();
    for (&s.dev) |*d| if (d.*) |n| if (std.mem.eql(u8, std.mem.sliceTo(&n, 0), ext)) {
        if (!on) d.* = null;
        return;
    };
    if (!on) return;
    for (&s.dev) |*d| if (d.* == null) {
        var n: [64]u8 = @splat(0);
        @memcpy(n[0..ext.len], ext);
        d.* = n;
        return;
    };
}

fn isDev(s: *const ExtStorage, ext: []const u8) bool {
    for (s.dev) |d| if (d) |n| if (std.mem.eql(u8, std.mem.sliceTo(&n, 0), ext)) return true;
    return false;
}

pub fn setLimit(s: *ExtStorage, limit_mb: u64) void {
    s.limit = limit_mb * 1024 * 1024;
}

fn lock(s: *ExtStorage) void {
    while (s.busy.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn unlock(s: *ExtStorage) void {
    s.busy.store(false, .release);
}

fn nowMs() u64 {
    var t: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return @as(u64, @intCast(t.tv_sec)) * 1000 + @as(u64, @intCast(t.tv_nsec)) / 1_000_000;
}

/// A plain file name: nothing that leaves the storage or hides in it.
pub fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max or name[0] == '.') return false;
    for (name) |ch| if (ch == '/' or ch == '\\' or ch == 0) return false;
    return true;
}

/// Makes `path` and every missing folder above it (0700); true when it
/// is a folder after.
pub fn mkdirs(path: []const u8) bool {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i < path.len and buf[i] != '/') continue;
        const keep = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o700);
        buf[i] = keep;
    }
    var st: c.struct_stat = undefined;
    return c.stat(@ptrCast(&buf), &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFDIR;
}

/// `buf` holds the storage's folder, made if needed.
fn folder(s: *const ExtStorage, ext: []const u8, uid: u32, kind: sdk.StorageKind, buf: []u8) Error![:0]const u8 {
    const p = switch (kind) {
        .stateful => std.fmt.bufPrintZ(buf, "{s}/{s}/data", .{ s.root, ext }),
        .ephemeral => std.fmt.bufPrintZ(buf, "{s}/ext/{s}-{x:0>8}", .{ s.tmp, ext, uid }),
    } catch return error.StorageFailed;
    if (!mkdirs(p)) return error.StorageFailed;
    return p;
}

/// A shared or exclusive lock on `path`, waiting until `deadline`.
fn lockFile(path: [:0]const u8, op: c_int, deadline: u64) Error!c_int {
    while (true) {
        const fd = c.open(path.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return error.StorageFailed;
        while (true) {
            if (c.flock(fd, op | c.LOCK_NB) == 0) break;
            if (nowMs() >= deadline) {
                _ = c.close(fd);
                return error.FileInUse;
            }
            _ = c.usleep(poll_us);
        }
        // Removed meanwhile (`forceUnlock`, the last gtty): this file is
        // no one's lock any more.
        var a: c.struct_stat = undefined;
        var b: c.struct_stat = undefined;
        if (c.fstat(fd, &a) == 0 and c.stat(path.ptr, &b) == 0 and a.st_ino == b.st_ino) return fd;
        _ = c.close(fd);
    }
}

fn lockPath(s: *const ExtStorage, ext: []const u8, name: []const u8, suffix: []const u8, buf: []u8) Error![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}/{s}{s}", .{ s.locks, ext, name, suffix }) catch error.StorageFailed;
}

/// Wait for the file: first come, first served through its gate.
fn acquire(s: *const ExtStorage, ext: []const u8, name: []const u8, mode: sdk.OpenMode, timeout_ms: u32) Error!c_int {
    var dbuf: [4096]u8 = undefined;
    const dir = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ s.locks, ext }) catch return error.StorageFailed;
    if (!mkdirs(dir)) return error.StorageFailed;
    var gbuf: [4400]u8 = undefined;
    var lbuf: [4400]u8 = undefined;
    const gate_path = try s.lockPath(ext, name, ".gate", &gbuf);
    const lock_path = try s.lockPath(ext, name, ".lock", &lbuf);
    const deadline = nowMs() + timeout_ms;
    const op: c_int = if (mode == .write) c.LOCK_EX else c.LOCK_SH;
    const gate = try lockFile(gate_path, op, deadline);
    defer _ = c.close(gate);
    return lockFile(lock_path, op, deadline);
}

fn dirSize(dir: [:0]const u8) u64 {
    const d = c.opendir(dir.ptr) orelse return 0;
    defer _ = c.closedir(d);
    var total: u64 = 0;
    while (c.readdir(d)) |e| {
        const n = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
        if (n[0] == '.') continue;
        var buf: [4400]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, n }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(p.ptr, &st) == 0) total += @intCast(st.st_size);
    }
    return total;
}

/// Open `name`. A write replaces the whole file at `close`. The result is
/// the handle. Ephemeral files are the instance's own: no waiting.
pub fn open(s: *ExtStorage, ext: []const u8, uid: u32, kind: sdk.StorageKind, name: []const u8, mode: sdk.OpenMode, timeout_ms: u32) Error!u32 {
    if (!nameOk(name)) return error.BadName;
    var dbuf: [4096]u8 = undefined;
    const dir = try s.folder(ext, uid, kind, &dbuf);
    const lock_fd: c_int = if (kind == .stateful) try s.acquire(ext, name, mode, timeout_ms) else -1;
    errdefer if (lock_fd >= 0) {
        _ = c.close(lock_fd);
    };
    const path = std.fmt.allocPrintSentinel(s.gpa, "{s}/{s}", .{ dir, name }, 0) catch return error.StorageFailed;
    errdefer s.gpa.free(path);

    s.lock();
    s.next_id +%= 1;
    const id = s.next_id;
    const hold = if (s.isDev(ext)) dev_hold_ms else hold_ms;
    s.unlock();

    var f: Open = .{ .id = id, .uid = uid, .kind = kind, .mode = mode, .fd = -1, .lock_fd = lock_fd, .path = path, .tmp = null, .opened_ms = nowMs(), .hold = hold };
    if (mode == .read) {
        f.fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
        if (f.fd < 0) return error.NoFile;
    } else {
        const t = std.fmt.allocPrintSentinel(s.gpa, "{s}/.w-{d}-{d}", .{ dir, c.getpid(), id }, 0) catch return error.StorageFailed;
        errdefer s.gpa.free(t);
        f.fd = c.open(t.ptr, c.O_CREAT | c.O_EXCL | c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (f.fd < 0) return error.StorageFailed;
        f.tmp = t;
        var st: c.struct_stat = undefined;
        const old: u64 = if (c.lstat(path.ptr, &st) == 0) @intCast(st.st_size) else 0;
        f.used = dirSize(dir) -| old;
    }
    s.lock();
    defer s.unlock();
    s.files.append(s.gpa, f) catch {
        _ = c.close(f.fd);
        if (f.tmp) |t| {
            _ = c.unlink(t.ptr);
            s.gpa.free(t);
        }
        return error.StorageFailed;
    };
    return id;
}

fn find(s: *ExtStorage, id: u32, uid: u32) ?usize {
    for (s.files.items, 0..) |f, i| if (f.id == id and f.uid == uid) return i;
    return null;
}

pub fn read(s: *ExtStorage, uid: u32, id: u32, buf: []u8) Error!usize {
    s.lock();
    defer s.unlock();
    const i = s.find(id, uid) orelse return error.FileClosed;
    const f = &s.files.items[i];
    if (f.mode != .read) return error.StorageFailed;
    const n = c.read(f.fd, buf.ptr, buf.len);
    return if (n < 0) error.StorageFailed else @intCast(n);
}

pub fn write(s: *ExtStorage, uid: u32, id: u32, bytes: []const u8) Error!void {
    s.lock();
    defer s.unlock();
    const i = s.find(id, uid) orelse return error.FileClosed;
    const f = &s.files.items[i];
    if (f.mode != .write) return error.StorageFailed;
    if (f.used + f.written + bytes.len > s.limit) return error.StorageFull;
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(f.fd, bytes.ptr + at, bytes.len - at);
        if (n <= 0) return error.StorageFailed;
        at += @intCast(n);
    }
    f.written += bytes.len;
}

/// Close it: a write takes the file's place; `keep` false drops it.
fn finish(s: *ExtStorage, f: Open, keep: bool) bool {
    _ = c.close(f.fd);
    var ok = true;
    if (f.tmp) |t| {
        if (keep) ok = c.rename(t.ptr, f.path.ptr) == 0 else _ = c.unlink(t.ptr);
        if (keep and !ok) _ = c.unlink(t.ptr);
        s.gpa.free(t);
    }
    if (f.lock_fd >= 0) _ = c.close(f.lock_fd);
    s.gpa.free(f.path);
    return ok;
}

pub fn close(s: *ExtStorage, uid: u32, id: u32) Error!void {
    s.lock();
    defer s.unlock();
    const i = s.find(id, uid) orelse return error.FileClosed;
    if (!s.finish(s.files.swapRemove(i), true)) return error.StorageFailed;
}

pub fn delete(s: *ExtStorage, ext: []const u8, uid: u32, kind: sdk.StorageKind, name: []const u8, timeout_ms: u32) Error!void {
    if (!nameOk(name)) return error.BadName;
    var dbuf: [4096]u8 = undefined;
    const dir = try s.folder(ext, uid, kind, &dbuf);
    const lock_fd: c_int = if (kind == .stateful) try s.acquire(ext, name, .write, timeout_ms) else -1;
    defer if (lock_fd >= 0) {
        _ = c.close(lock_fd);
    };
    var pbuf: [4400]u8 = undefined;
    const p = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ dir, name }) catch return error.StorageFailed;
    if (c.unlink(p.ptr) != 0) return error.NoFile;
}

/// The file names, one per line, into `out`; what doesn't fit is left out.
pub fn list(s: *ExtStorage, ext: []const u8, uid: u32, kind: sdk.StorageKind, out: []u8) Error!usize {
    var dbuf: [4096]u8 = undefined;
    const dir = try s.folder(ext, uid, kind, &dbuf);
    const d = c.opendir(dir.ptr) orelse return error.StorageFailed;
    defer _ = c.closedir(d);
    var n: usize = 0;
    while (c.readdir(d)) |e| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
        if (name[0] == '.') continue;
        if (n + name.len + 1 > out.len) break;
        @memcpy(out[n..][0..name.len], name);
        out[n + name.len] = '\n';
        n += name.len + 1;
    }
    return n;
}

/// Once in a while: files held too long are closed; a write not closed
/// is dropped, so the file stays as it was.
pub fn tick(s: *ExtStorage) void {
    s.expire(nowMs());
}

fn expire(s: *ExtStorage, now: u64) void {
    s.lock();
    defer s.unlock();
    var i: usize = 0;
    while (i < s.files.items.len) {
        if (now -| s.files.items[i].opened_ms >= s.files.items[i].hold) {
            _ = s.finish(s.files.swapRemove(i), false);
        } else i += 1;
    }
}

/// The instances of window `uid` ended (`ext`: each one's name): what
/// they left open is closed, their ephemeral folders are deleted.
pub fn closeWindow(s: *ExtStorage, uid: u32, exts: []const []const u8) void {
    s.lock();
    var i: usize = 0;
    while (i < s.files.items.len) {
        if (s.files.items[i].uid == uid) _ = s.finish(s.files.swapRemove(i), false) else i += 1;
    }
    s.unlock();
    for (exts) |e| {
        var buf: [4400]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/ext/{s}-{x:0>8}", .{ s.tmp, e, uid }) catch continue;
        removeFolder(p);
    }
}

/// gtty is closing, after the extensions heard it: every file open.
pub fn closeAll(s: *ExtStorage) void {
    s.lock();
    defer s.unlock();
    while (s.files.items.len > 0) _ = s.finish(s.files.pop().?, false);
}

fn removeFolder(path: [:0]const u8) void {
    if (c.opendir(path.ptr)) |d| {
        defer _ = c.closedir(d);
        while (c.readdir(d)) |e| {
            const n = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
            if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
            var buf: [4400]u8 = undefined;
            const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ path, n }) catch continue;
            var st: c.struct_stat = undefined;
            if (c.lstat(p.ptr, &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFDIR) removeFolder(p) else _ = c.unlink(p.ptr);
        }
    }
    _ = c.rmdir(path.ptr);
}

fn runningPath(s: *const ExtStorage, buf: []u8) Error![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/running", .{s.locks}) catch error.StorageFailed;
}

/// Empty the locks folder, but for `running` (held by whoever calls).
fn cleanLocks(s: *const ExtStorage) void {
    const d = c.opendir(s.locks.ptr) orelse return;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |e| {
        const n = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
        if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..") or std.mem.eql(u8, n, "running")) continue;
        var buf: [4400]u8 = undefined;
        const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ s.locks, n }) catch continue;
        removeFolder(p);
    }
}

/// gtty started: alone (none other running, a crash may have left locks),
/// the folder is cleaned; then it counts as running.
pub fn start(s: *ExtStorage) void {
    if (!mkdirs(s.locks)) return;
    var buf: [4400]u8 = undefined;
    const p = s.runningPath(&buf) catch return;
    const alone = lockFile(p, c.LOCK_EX, nowMs()) catch -1;
    if (alone >= 0) {
        s.cleanLocks();
        s.running_fd = alone;
        _ = c.flock(alone, c.LOCK_SH);
        return;
    }
    s.running_fd = lockFile(p, c.LOCK_SH, nowMs() + 2000) catch -1;
}

/// gtty is closing: the last one out cleans the folder.
pub fn stop(s: *ExtStorage) void {
    if (s.running_fd < 0) return;
    const fd = s.running_fd;
    s.running_fd = -1;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) == 0) {
        s.cleanLocks();
        var buf: [4400]u8 = undefined;
        if (s.runningPath(&buf)) |p| {
            _ = c.unlink(p.ptr);
        } else |_| {}
    }
    _ = c.close(fd);
}

/// The extension manager's way out of a stuck lock: `name`'s lock files,
/// or (null) all of `ext`'s. A holder keeps writing to its temp file, but
/// nobody waits for it any more.
pub fn forceUnlock(s: *ExtStorage, ext: []const u8, name: ?[]const u8) void {
    var buf: [4400]u8 = undefined;
    if (name) |n| {
        for ([_][]const u8{ ".lock", ".gate" }) |suffix| {
            const p = s.lockPath(ext, n, suffix, &buf) catch continue;
            _ = c.unlink(p.ptr);
        }
        return;
    }
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ s.locks, ext }) catch return;
    removeFolder(p);
}

// ------------------------------------------------------------ tests

const T = struct {
    dir: [:0]u8,
    s: ExtStorage,

    fn make(limit_mb: u64) !T {
        const t = std.testing;
        var tmpl = "/tmp/gtty-st-XXXXXX".*;
        const d = c.mkdtemp(&tmpl) orelse return error.NoTemp;
        const dir = try t.allocator.dupeZ(u8, std.mem.span(d));
        var b1: [200]u8 = undefined;
        var b2: [200]u8 = undefined;
        return .{ .dir = dir, .s = try ExtStorage.init(t.allocator, try std.fmt.bufPrint(&b1, "{s}/ext", .{dir}), try std.fmt.bufPrint(&b2, "{s}/locks", .{dir}), dir, limit_mb) };
    }

    fn done(x: *T) void {
        x.s.deinit();
        removeFolder(x.dir);
        std.testing.allocator.free(x.dir);
    }

    fn put(x: *T, uid: u32, name: []const u8, text: []const u8) !void {
        const f = try x.s.open("e", uid, .stateful, name, .write, 0);
        try x.s.write(uid, f, text);
        try x.s.close(uid, f);
    }
};

test "names: nothing leaves the storage" {
    const t = std.testing;
    try t.expect(nameOk("hosts.json"));
    for ([_][]const u8{ "", "..", ".hidden", "../x", "a/b", "/etc/passwd", "a\\b" }) |n| try t.expect(!nameOk(n));
    var x = try T.make(1);
    defer x.done();
    try t.expectError(error.BadName, x.s.open("e", 1, .stateful, "../../x", .write, 0));
    try t.expectError(error.BadName, x.s.delete("e", 1, .stateful, "../x", 0));
}

test "a write shows only at close; other windows read it" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    try x.put(1, "a", "one");
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    try x.s.write(1, w, "two");
    try t.expectError(error.FileClosed, x.s.write(2, w, "not yours"));
    try x.s.close(1, w);
    const r = try x.s.open("e", 2, .stateful, "a", .read, 0);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("two", buf[0..try x.s.read(2, r, &buf)]);
    try x.s.close(2, r);
    try t.expectError(error.NoFile, x.s.open("e", 2, .stateful, "gone", .read, 0));
    var names: [64]u8 = undefined;
    try t.expectEqualStrings("a\n", names[0..try x.s.list("e", 1, .stateful, &names)]);
}

test "writing keeps everyone out; reading keeps writers out, not readers" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    try x.put(1, "a", "x");
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    try t.expectError(error.FileInUse, x.s.open("e", 2, .stateful, "a", .read, 0));
    try t.expectError(error.FileInUse, x.s.open("e", 2, .stateful, "a", .write, 0));
    try x.s.close(1, w);
    const r1 = try x.s.open("e", 1, .stateful, "a", .read, 0);
    const r2 = try x.s.open("e", 2, .stateful, "a", .read, 0);
    try t.expectError(error.FileInUse, x.s.open("e", 3, .stateful, "a", .write, 0));
    try t.expectError(error.FileInUse, x.s.delete("e", 3, .stateful, "a", 0));
    try x.s.close(1, r1);
    try x.s.close(2, r2);
    try x.s.delete("e", 3, .stateful, "a", 0);
}

test "a timeout waits that long, then says the file is in use" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    const t0 = nowMs();
    try t.expectError(error.FileInUse, x.s.open("e", 2, .stateful, "a", .read, 60));
    try t.expect(nowMs() - t0 >= 55);
    try x.s.close(1, w);
}

test "a wait ends as soon as the file is free" {
    var x = try T.make(1);
    defer x.done();
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    const S = struct {
        fn free(st: *ExtStorage, id: u32) void {
            _ = c.usleep(30_000);
            st.close(1, id) catch {};
        }
    };
    const th = try std.Thread.spawn(.{}, S.free, .{ &x.s, w });
    const r = try x.s.open("e", 2, .stateful, "a", .read, 2000);
    th.join();
    try x.s.close(2, r);
}

test "new readers queue behind a waiting write" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    try x.put(1, "a", "x");
    const r = try x.s.open("e", 1, .stateful, "a", .read, 0);
    const S = struct {
        fn wait(st: *ExtStorage, out: *?u32) void {
            out.* = st.open("e", 2, .stateful, "a", .write, 1000) catch null;
        }
    };
    var w: ?u32 = null;
    const th = try std.Thread.spawn(.{}, S.wait, .{ &x.s, &w });
    _ = c.usleep(50_000);
    try t.expectError(error.FileInUse, x.s.open("e", 3, .stateful, "a", .read, 0));
    try x.s.close(1, r);
    th.join();
    try x.s.close(2, w.?);
}

test "a file held too long is closed, its write dropped" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    try x.put(1, "a", "old");
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    try x.s.write(1, w, "new");
    x.s.expire(nowMs() + hold_ms);
    try t.expectError(error.FileClosed, x.s.write(1, w, "more"));
    const r = try x.s.open("e", 2, .stateful, "a", .read, 0);
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("old", buf[0..try x.s.read(2, r, &buf)]);
    try x.s.close(2, r);
}

test "the size limit counts the whole folder, not the file replaced" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    const mb = 1024 * 1024;
    const big = try t.allocator.alloc(u8, mb - 10);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try x.put(1, "a", big);
    try x.put(1, "a", big); // replaced: still fits
    const w = try x.s.open("e", 1, .stateful, "b", .write, 0);
    try t.expectError(error.StorageFull, x.s.write(1, w, "more than the ten bytes left"));
    try x.s.close(1, w);
}

test "ephemeral: one folder per instance, gone with its window" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    const f = try x.s.open("e", 1, .ephemeral, "a", .write, 0);
    try x.s.write(1, f, "x");
    try x.s.close(1, f);
    try t.expectError(error.NoFile, x.s.open("e", 2, .ephemeral, "a", .read, 0));
    const open_one = try x.s.open("e", 1, .stateful, "s", .write, 0);
    x.s.closeWindow(1, &.{"e"});
    try t.expectError(error.NoFile, x.s.open("e", 1, .ephemeral, "a", .read, 0));
    // What it left open is closed: nothing blocks the next one.
    try t.expectError(error.FileClosed, x.s.close(1, open_one));
    try x.put(2, "s", "ok");
}

test "a stuck lock: force removed, the file opens again" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    const w = try x.s.open("e", 1, .stateful, "a", .write, 0);
    try t.expectError(error.FileInUse, x.s.open("e", 2, .stateful, "a", .write, 0));
    x.s.forceUnlock("e", "a");
    const w2 = try x.s.open("e", 2, .stateful, "a", .write, 0);
    try x.s.close(2, w2);
    try x.s.close(1, w);
}

test "the last gtty out empties the locks folder; another one still running: not" {
    const t = std.testing;
    var x = try T.make(1);
    defer x.done();
    var b1: [200]u8 = undefined;
    var b2: [200]u8 = undefined;
    var other = try ExtStorage.init(t.allocator, try std.fmt.bufPrint(&b1, "{s}/ext", .{x.dir}), try std.fmt.bufPrint(&b2, "{s}/locks", .{x.dir}), x.dir, 1);
    defer other.deinit();
    x.s.start();
    other.start();
    try x.put(1, "a", "x");
    var pbuf: [300]u8 = undefined;
    const p = try std.fmt.bufPrintZ(&pbuf, "{s}/locks/e/a.lock", .{x.dir});
    try t.expect(c.access(p.ptr, c.F_OK) == 0);
    other.stop();
    try t.expect(c.access(p.ptr, c.F_OK) == 0);
    x.s.stop();
    try t.expect(c.access(p.ptr, c.F_OK) != 0);
    // A crash left a lock: the first one in cleans it.
    try x.put(1, "a", "x");
    try t.expect(c.access(p.ptr, c.F_OK) == 0);
    x.s.start();
    try t.expect(c.access(p.ptr, c.F_OK) != 0);
    x.s.stop();
}
