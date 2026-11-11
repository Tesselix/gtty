// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The developer socket (docs/protocol.md "Development"): an extension an
//! IDE started under its debugger connects here instead of being gtty's
//! child.
//!
//! Each gtty listens on `<its temp folder>/ext.sock`. The newest gtty also
//! takes the shared address, `$TMPDIR/gtty-dev-<uid>/ext.sock` (a link to
//! its own socket; the folder 0700 and this user's), which the SDKs use
//! when started with nothing set. When that gtty closes, another one
//! running takes it back (`tick`, once a second). Only this user's
//! processes get in (`gtty_ext_accept`).

const std = @import("std");
const c = @import("../c.zig").c;

const DevSocket = @This();

fd: c_int,
/// Our own socket's path.
path: [:0]u8,
/// The shared link, when we could make its folder.
link: ?[:0]u8,

/// Listen on `<tmp>/ext.sock`; `shared`: take the shared address too.
pub fn open(gpa: std.mem.Allocator, tmp: []const u8, shared: bool) !DevSocket {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/ext.sock", .{tmp}, 0);
    errdefer gpa.free(path);
    const fd = c.gtty_ext_listen(path.ptr);
    if (fd < 0) return error.Listen;
    var d: DevSocket = .{ .fd = fd, .path = path, .link = null };
    var buf: [4096]u8 = undefined;
    if (!shared) return d;
    if (sharedPath(&buf)) |l| {
        d.link = gpa.dupeZ(u8, l) catch null;
        d.take();
    }
    return d;
}

pub fn close(d: *DevSocket, gpa: std.mem.Allocator) void {
    _ = c.close(d.fd);
    _ = c.unlink(d.path.ptr);
    if (d.link) |l| {
        if (d.ours()) _ = c.unlink(l.ptr);
        gpa.free(l);
    }
    gpa.free(d.path);
}

/// The shared address: `$TMPDIR` (else /tmp) `/gtty-dev-<uid>/ext.sock`.
/// Makes the folder; null when it is someone else's or open to others.
pub fn sharedPath(buf: []u8) ?[:0]const u8 {
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const base = std.mem.trimEnd(u8, tmp, "/");
    var dbuf: [4096]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dbuf, "{s}/gtty-dev-{d}", .{ base, c.getuid() }, 0) catch return null;
    _ = c.mkdir(dir.ptr, 0o700);
    var st: c.struct_stat = undefined;
    if (c.lstat(dir.ptr, &st) != 0) return null;
    if (st.st_mode & c.S_IFMT != c.S_IFDIR or st.st_uid != c.getuid() or st.st_mode & 0o077 != 0) return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/ext.sock", .{dir}, 0) catch null;
}

/// Point the shared link at our socket (made aside, then renamed over).
fn take(d: *DevSocket) void {
    const l = d.link orelse return;
    var buf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&buf, "{s}.{d}", .{ l, c.getpid() }, 0) catch return;
    _ = c.unlink(tmp.ptr);
    if (c.symlink(d.path.ptr, tmp.ptr) != 0) return;
    if (c.rename(tmp.ptr, l.ptr) != 0) _ = c.unlink(tmp.ptr);
}

/// Does the shared link point at us?
fn ours(d: *const DevSocket) bool {
    const l = d.link orelse return false;
    var buf: [4096]u8 = undefined;
    const n = c.readlink(l.ptr, &buf, buf.len);
    return n > 0 and std.mem.eql(u8, buf[0..@intCast(n)], d.path);
}

/// The pid of the gtty the link points at, if it still runs.
fn holder(d: *const DevSocket) ?c.pid_t {
    const l = d.link orelse return null;
    var buf: [4096]u8 = undefined;
    const n = c.readlink(l.ptr, &buf, buf.len);
    if (n <= 0) return null;
    const dir = std.fs.path.dirname(buf[0..@intCast(n)]) orelse return null;
    const base = std.fs.path.basename(dir);
    if (!std.mem.startsWith(u8, base, "gtty-")) return null;
    const pid = std.fmt.parseInt(c.pid_t, base[5..], 10) catch return null;
    if (c.kill(pid, 0) != 0 and std.c._errno().* == @intFromEnum(std.c.E.SRCH)) return null;
    return pid;
}

/// Once a second: the gtty holding the shared address closed (or none
/// did): take it.
pub fn tick(d: *DevSocket) void {
    if (d.link == null or d.ours()) return;
    if (d.holder() == null) d.take();
}

/// One waiting connection: its fd and the peer's pid.
pub fn accept(d: *DevSocket) ?struct { fd: c_int, pid: c_int } {
    var pid: c_int = 0;
    const fd = c.gtty_ext_accept(d.fd, &pid);
    if (fd < 0) return null;
    return .{ .fd = fd, .pid = pid };
}
