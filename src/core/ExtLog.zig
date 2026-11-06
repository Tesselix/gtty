// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What extensions log (`win.log`, `ext.log`) and what gtty says about
//! them, for `gtty ext logs` (ExtCli.zig): one file per gtty,
//! `<tmp>/ext.log`, in its private temp folder, gone when gtty closes.
//!
//! One entry is one line, "time level extension window message"; control
//! characters in a message are escaped, so an extension can't fake lines
//! or send escape codes to the terminal reading them. At `max_bytes` the
//! file moves to `ext.log.1` and a new one starts. Extensions may log
//! from their own threads.

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;

const ExtLog = @This();

pub const file_name = "ext.log";
pub const max_bytes = 8 * 1024 * 1024;
/// A longer entry is cut.
const line_max = 4096;

fd: c_int,
path: [:0]u8,
old_path: [:0]u8,
size: usize = 0,
lock: std.atomic.Mutex = .unlocked,

pub fn init(gpa: std.mem.Allocator, dir: []const u8) !ExtLog {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/" ++ file_name, .{dir}, 0);
    errdefer gpa.free(path);
    const old_path = try std.fmt.allocPrintSentinel(gpa, "{s}/" ++ file_name ++ ".1", .{dir}, 0);
    errdefer gpa.free(old_path);
    const fd = openFile(path);
    if (fd < 0) return error.LogFile;
    return .{ .fd = fd, .path = path, .old_path = old_path };
}

pub fn deinit(l: *ExtLog, gpa: std.mem.Allocator) void {
    if (l.fd >= 0) _ = c.close(l.fd);
    gpa.free(l.path);
    gpa.free(l.old_path);
}

fn openFile(path: [:0]const u8) c_int {
    return c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c_uint, 0o600));
}

/// One entry. `uid` 0: not about a window.
pub fn write(l: *ExtLog, level: sdk.LogLevel, name: []const u8, uid: u32, msg: []const u8) void {
    var buf: [line_max]u8 = undefined;
    const now = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    const when: Clock = .{ .h = @intCast(tm.tm_hour), .m = @intCast(tm.tm_min), .s = @intCast(tm.tm_sec), .ms = @intCast(@divTrunc(ts.tv_nsec, 1_000_000)) };
    const line = format(&buf, when, level, name, uid, msg);

    while (!l.lock.tryLock()) std.atomic.spinLoopHint();
    defer l.lock.unlock();
    if (l.fd < 0) return;
    if (l.size + line.len > max_bytes) l.rotate();
    if (l.fd < 0) return;
    if (c.write(l.fd, line.ptr, line.len) > 0) l.size += line.len;
}

fn rotate(l: *ExtLog) void {
    _ = c.close(l.fd);
    _ = c.rename(l.path.ptr, l.old_path.ptr);
    l.fd = openFile(l.path);
    l.size = 0;
}

const Clock = struct { h: u8, m: u8, s: u8, ms: u16 };

/// The line, with its line feed; always fits `buf`.
fn format(buf: []u8, t: Clock, level: sdk.LogLevel, name: []const u8, uid: u32, msg: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf[0 .. buf.len - 1]);
    w.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s:<5} {s} ", .{ t.h, t.m, t.s, t.ms, @tagName(level), name }) catch {};
    if (uid == 0) w.writeAll("- ") catch {} else w.print("{x:0>8} ", .{uid}) catch {};
    for (msg) |b| {
        const done = switch (b) {
            '\n' => w.writeAll("\\n"),
            '\r' => w.writeAll("\\r"),
            '\t' => w.writeByte(b),
            '\\' => w.writeAll("\\\\"),
            0...8, 11, 12, 14...0x1f, 0x7f => w.print("\\x{x:0>2}", .{b}),
            else => w.writeByte(b),
        };
        done catch break;
    }
    const n = w.buffered().len;
    buf[n] = '\n';
    return buf[0 .. n + 1];
}

test "a line: fields, and a message that can't break out of it" {
    var buf: [200]u8 = undefined;
    const t: Clock = .{ .h = 9, .m = 5, .s = 7, .ms = 42 };
    try std.testing.expectEqualStrings("09:05:07.042 info  git 0000002a switched\n", format(&buf, t, .info, "git", 42, "switched"));
    try std.testing.expectEqualStrings("09:05:07.042 err   hosts - a\\nb\\x1b[31m\\\\\n", format(&buf, t, .err, "hosts", 0, "a\nb\x1b[31m\\"));
}

test "a long message is cut and still ends the line" {
    var buf: [40]u8 = undefined;
    const line = format(&buf, .{ .h = 0, .m = 0, .s = 0, .ms = 0 }, .warn, "x", 0, "a" ** 100);
    try std.testing.expectEqual(@as(usize, 40), line.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[39]);
}

test "the file moves aside at its limit" {
    var tmpl = "/tmp/gtty-log-XXXXXX".*;
    const dir = std.mem.span(c.mkdtemp(&tmpl) orelse return error.TestDir);
    defer @import("Tee.zig").Dir.removeTree(tmpl[0..dir.len :0]);
    var l = try init(std.testing.allocator, dir);
    defer l.deinit(std.testing.allocator);
    l.write(.info, "a", 0, "first");
    l.size = max_bytes;
    l.write(.info, "a", 0, "second");
    try std.testing.expect(c.access(l.old_path.ptr, c.F_OK) == 0);
    try std.testing.expect(l.size < 100);
}
