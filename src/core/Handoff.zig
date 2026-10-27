// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Moving a job window to another gtty process (a window dragged onto
//! another gtty, or onto the desktop: a new gtty takes it).
//!
//! Every gtty listens on `<its temp folder>/ctl.sock` (sys/gtty_ctl.c).
//! Two ways a window travels:
//!   * push (`op move`): the gtty it was dragged out of connects to the
//!     gtty it was dropped on and sends it;
//!   * pull (`op take`): a gtty asks for a window by its id (a new gtty
//!     started for a drop on the desktop, or one a window was dropped on
//!     under Wayland), and gets the `move` back on the same connection.
//! The receiver answers `ok` (it has the window: the sender lets go of it,
//! without hanging up the job) or `no` with a reason (the sender keeps it).
//!
//! A `move` carries the window as text lines `key value` (values escaped,
//! see `put`), and as file descriptors: the job's PTY, its keeper's
//! status pipe (how it ends, core/Process.zig) and its output file (the
//! receiver replays it into its screen). This file: the message text
//! (pure, unit-tested) and the socket calls around it.

const std = @import("std");
const c = @import("../c.zig").c;

/// Changes when a message changes meaning; both gttys must agree.
pub const version = "1";
pub const max_len = 64 * 1024;
pub const max_fds = 3;

/// A message being written: `key value` lines.
pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.gpa);
    }

    /// One line; in the value `\` and line breaks are escaped (`\\`, `\n`)
    /// so any text fits on it.
    pub fn put(w: *Writer, key: []const u8, value: []const u8) void {
        w.buf.appendSlice(w.gpa, key) catch return;
        w.buf.append(w.gpa, ' ') catch return;
        for (value) |ch| switch (ch) {
            '\\' => w.buf.appendSlice(w.gpa, "\\\\") catch return,
            '\n' => w.buf.appendSlice(w.gpa, "\\n") catch return,
            else => w.buf.append(w.gpa, ch) catch return,
        };
        w.buf.append(w.gpa, '\n') catch return;
    }

    pub fn putInt(w: *Writer, key: []const u8, v: anytype) void {
        var b: [32]u8 = undefined;
        w.put(key, std.fmt.bufPrint(&b, "{d}", .{v}) catch return);
    }

    pub fn putBool(w: *Writer, key: []const u8, v: bool) void {
        w.put(key, if (v) "1" else "0");
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf.items;
    }
};

/// A message read: its lines, values unescaped on demand.
pub const Reader = struct {
    text: []const u8,

    /// The first value of `key` (unescaped into `out`), or null.
    pub fn get(r: Reader, key: []const u8, out: []u8) ?[]const u8 {
        var it = r.iterator(key);
        return it.next(out);
    }

    pub fn int(r: Reader, comptime T: type, key: []const u8) ?T {
        var b: [32]u8 = undefined;
        return std.fmt.parseInt(T, r.get(key, &b) orelse return null, 10) catch null;
    }

    pub fn boolean(r: Reader, key: []const u8) bool {
        var b: [4]u8 = undefined;
        const v = r.get(key, &b) orelse return false;
        return std.mem.eql(u8, v, "1");
    }

    /// Every value of `key`, in order (a key given more than once).
    pub fn iterator(r: Reader, key: []const u8) Iterator {
        return .{ .lines = std.mem.splitScalar(u8, r.text, '\n'), .key = key };
    }

    pub const Iterator = struct {
        lines: std.mem.SplitIterator(u8, .scalar),
        key: []const u8,

        pub fn next(it: *Iterator, out: []u8) ?[]const u8 {
            while (it.lines.next()) |line| {
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
                if (!std.mem.eql(u8, line[0..sp], it.key)) continue;
                return unescape(line[sp + 1 ..], out);
            }
            return null;
        }
    };
};

fn unescape(v: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len and n < out.len) : (i += 1) {
        var ch = v[i];
        if (ch == '\\' and i + 1 < v.len) {
            i += 1;
            ch = if (v[i] == 'n') '\n' else v[i];
        }
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

/// Where another gtty listens: `<temp base>/gtty-<pid>/ctl.sock` (the
/// same base as this gtty's own folder, core/Tee.zig).
pub fn socketPath(buf: []u8, pid: c_int) ?[:0]const u8 {
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/gtty-{d}/ctl.sock", .{ std.mem.trimEnd(u8, tmp, "/"), pid }) catch null;
}

/// A message that came in, and the descriptors with it (closed by
/// `deinit` unless taken: set to -1).
pub const Incoming = struct {
    buf: [max_len]u8 = undefined,
    len: usize = 0,
    fds: [max_fds]c_int = .{ -1, -1, -1 },
    n_fds: usize = 0,

    pub fn reader(m: *const Incoming) Reader {
        return .{ .text = m.buf[0..m.len] };
    }

    pub fn op(m: *const Incoming, out: []u8) []const u8 {
        return m.reader().get("op", out) orelse "";
    }

    pub fn deinit(m: *Incoming) void {
        for (m.fds[0..m.n_fds]) |fd| c.gtty_close(fd);
        m.n_fds = 0;
    }
};

pub fn send(fd: c_int, msg: []const u8, fds: []const c_int) bool {
    return c.gtty_ctl_send(fd, msg.ptr, msg.len, fds.ptr, @intCast(fds.len)) == 0;
}

/// One message from `fd` into `m`; false: none (closed, timed out, bad).
pub fn recv(fd: c_int, m: *Incoming) bool {
    var n: c_int = 0;
    const len = c.gtty_ctl_recv(fd, &m.buf, m.buf.len, &m.fds, max_fds, &n);
    m.n_fds = @intCast(@max(n, 0));
    if (len < 0) return false;
    m.len = @intCast(len);
    return true;
}

/// A short message: `op` and, for `no`, why.
pub fn reply(gpa: std.mem.Allocator, fd: c_int, op: []const u8, why: ?[]const u8) void {
    var w = Writer.init(gpa);
    defer w.deinit();
    w.put("v", version);
    w.put("op", op);
    if (why) |y| w.put("why", y);
    _ = send(fd, w.bytes(), &.{});
}

test "values with line breaks and backslashes come back as they were" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    w.put("title", "a\\b\nc d");
    w.putInt("pid", @as(i32, -42));
    w.putBool("colors", true);
    w.put("dir", "/x");
    w.put("dir", "/y z");
    const r: Reader = .{ .text = w.bytes() };
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a\\b\nc d", r.get("title", &b).?);
    try std.testing.expectEqual(@as(?i32, -42), r.int(i32, "pid"));
    try std.testing.expect(r.boolean("colors"));
    try std.testing.expect(!r.boolean("missing"));
    try std.testing.expect(r.get("missing", &b) == null);
    var it = r.iterator("dir");
    try std.testing.expectEqualStrings("/x", it.next(&b).?);
    try std.testing.expectEqualStrings("/y z", it.next(&b).?);
    try std.testing.expect(it.next(&b) == null);
}

test "a key is a whole word" {
    const r: Reader = .{ .text = "dirs 1\ndir 2\n" };
    var b: [8]u8 = undefined;
    try std.testing.expectEqualStrings("2", r.get("dir", &b).?);
}

test "a value cut to the buffer" {
    const r: Reader = .{ .text = "k abcdef\n" };
    var b: [3]u8 = undefined;
    try std.testing.expectEqualStrings("abc", r.get("k", &b).?);
}
