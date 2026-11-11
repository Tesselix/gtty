// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gtty ext ...`, the command line for extensions, for IDE tasks and AI
//! tools. It runs without a window. `logs` reads ExtLog's file of a
//! running gtty, the one logged to last, or `--pid`'s (only folders of
//! this user count). `install`, `uninstall`, `enable`, `disable` and
//! `list` change the extensions folder; every running gtty notices within
//! a second.

const std = @import("std");
const c = @import("../c.zig").c;
const ExtLog = @import("ExtLog.zig");
const Extensions = @import("Extensions.zig");

const usage =
    \\usage: gtty ext install <folder | file.zip | file.tar.gz>
    \\       gtty ext uninstall <name>     (its data too)
    \\       gtty ext enable | disable <name>
    \\       gtty ext list
    \\       gtty ext logs [-f] [--pid N] [extension]
    \\       gtty ext socket [--pid N]     (where an extension you debug connects)
    \\  install again to update; running gttys restart it within a second
    \\  -f, --follow   keep printing new lines until gtty closes
    \\  --pid N        the gtty with this process id (default: the one
    \\                 logged to last; for socket, the newest)
    \\
;

const poll_ms = 100;

const Options = struct {
    follow: bool = false,
    pid: ?c.pid_t = null,
    name: ?[]const u8 = null,
};

/// `args`: what follows `ext`. Null: not understood.
fn parse(args: []const []const u8) ?Options {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "logs")) return null;
    var o: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--follow")) {
            o.follow = true;
        } else if (std.mem.eql(u8, a, "--pid")) {
            i += 1;
            if (i == args.len) return null;
            o.pid = std.fmt.parseInt(c.pid_t, args[i], 10) catch return null;
        } else if (a.len > 0 and a[0] != '-' and o.name == null) {
            o.name = a;
        } else return null;
    }
    return o;
}

/// The exit code.
pub fn run(args: []const []const u8) u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "socket")) return socket(args[1..]);
    if (args.len > 0 and !std.mem.eql(u8, args[0], "logs")) return manage(args);
    const o = parse(args) orelse {
        say(usage);
        return 2;
    };
    var buf: [4096]u8 = undefined;
    const found = find(&buf, o.pid, ExtLog.file_name, c.S_IFREG) orelse {
        if (o.pid) |p| {
            var m: [80]u8 = undefined;
            say(std.fmt.bufPrint(&m, "no gtty with pid {d}\n", .{p}) catch "no such gtty\n");
        } else say("no gtty is running\n");
        return 1;
    };
    return show(found.path, found.pid, o);
}

/// `gtty ext socket [--pid N]`: the developer socket's path, for
/// `GTTY_EXT_SOCKET` (docs/protocol.md "Development").
fn socket(args: []const []const u8) u8 {
    var pid: ?c.pid_t = null;
    if (args.len == 2 and std.mem.eql(u8, args[0], "--pid")) {
        pid = std.fmt.parseInt(c.pid_t, args[1], 10) catch null;
        if (pid == null) {
            say(usage);
            return 2;
        }
    } else if (args.len != 0) {
        say(usage);
        return 2;
    }
    var buf: [4096]u8 = undefined;
    const found = find(&buf, pid, "ext.sock", c.S_IFSOCK) orelse {
        say(if (pid != null) "no gtty with that pid\n" else "no gtty is running\n");
        return 1;
    };
    out(found.path);
    out("\n");
    return 0;
}

fn manage(args: []const []const u8) u8 {
    var rbuf: [4096]u8 = undefined;
    const root = Extensions.defaultRoot(&rbuf) orelse {
        say("no home folder\n");
        return 1;
    };
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = args[0];
    var m: [512]u8 = undefined;
    if (std.mem.eql(u8, cmd, "list") and args.len == 1) {
        const list = Extensions.scan(a, root) catch &.{};
        if (list.len == 0) say("no extensions installed\n");
        for (list) |x| print(&m, "{s}\t{s}\t{s}\t{s}\n", .{ x.manifest.name, if (x.manifest.version.len > 0) x.manifest.version else "-", if (x.enabled) "on" else "off", x.manifest.description });
        return 0;
    }
    if (args.len != 2) {
        say(usage);
        return 2;
    }
    if (std.mem.eql(u8, cmd, "install")) {
        const name = Extensions.install(a, root, args[1]) catch |e| {
            print(&m, "not installed: {s}\n", .{Extensions.explain(e)});
            return 1;
        };
        print(&m, "installed {s} in {s}/{s}\n", .{ name, root, name });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "uninstall")) {
        if (!(Extensions.uninstall(a, root, args[1]) catch false)) {
            print(&m, "{s} isn't installed\n", .{args[1]});
            return 1;
        }
        print(&m, "uninstalled {s}, and its data\n", .{args[1]});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "enable") or std.mem.eql(u8, cmd, "disable")) {
        const list = Extensions.scan(a, root) catch &.{};
        for (list) |x| if (std.mem.eql(u8, x.manifest.name, args[1])) {
            Extensions.setEnabled(a, root, args[1], cmd[0] == 'e') catch return 1;
            return 0;
        };
        print(&m, "{s} isn't installed\n", .{args[1]});
        return 1;
    }
    say(usage);
    return 2;
}

fn print(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    out(std.fmt.bufPrint(buf, fmt, args) catch return);
}

const Found = struct { path: [:0]const u8, pid: c.pid_t };

/// The newest live gtty folder of this user holding `file` (of type
/// `kind`), or `want`'s.
fn find(buf: []u8, want: ?c.pid_t, file_name: []const u8, kind: c_uint) ?Found {
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.span(t) else "/tmp";
    const base = std.mem.trimEnd(u8, tmp, "/");
    var base_buf: [4096]u8 = undefined;
    const base_z = std.fmt.bufPrintSentinel(&base_buf, "{s}", .{base}, 0) catch return null;
    const d = c.opendir(base_z.ptr) orelse return null;
    defer _ = c.closedir(d);
    var best: ?Found = null;
    var best_time: i64 = 0;
    while (c.readdir(d)) |e| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        if (!std.mem.startsWith(u8, name, "gtty-")) continue;
        const pid = std.fmt.parseInt(c.pid_t, name[5..], 10) catch continue;
        if (want) |w| if (w != pid) continue;
        if (c.kill(pid, 0) != 0) continue;
        var dir_buf: [4096]u8 = undefined;
        const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/{s}", .{ base, name }, 0) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(dir.ptr, &st) != 0 or st.st_uid != c.getuid() or st.st_mode & c.S_IFMT != c.S_IFDIR) continue;
        var file_buf: [4096]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&file_buf, "{s}/{s}", .{ dir, file_name }, 0) catch continue;
        if (c.lstat(file.ptr, &st) != 0 or st.st_uid != c.getuid() or st.st_mode & c.S_IFMT != kind) continue;
        const t = modified(&st);
        if (best != null and t < best_time) continue;
        best_time = t;
        best = .{ .path = std.fmt.bufPrintSentinel(buf, "{s}", .{file}, 0) catch continue, .pid = pid };
    }
    return best;
}

fn modified(st: *const c.struct_stat) i64 {
    return if (@hasField(c.struct_stat, "st_mtimespec")) st.st_mtimespec.tv_sec else st.st_mtim.tv_sec;
}

fn show(path: [:0]const u8, pid: c.pid_t, o: Options) u8 {
    var lines: Lines = .{ .name = o.name };
    var fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) {
        say("gtty closed\n");
        return 1;
    }
    defer _ = c.close(fd);
    while (true) {
        lines.drain(fd);
        if (!o.follow) return 0;
        // The file moved aside: what was left in it, then the new one.
        var now: c.struct_stat = undefined;
        var open: c.struct_stat = undefined;
        const moved = c.fstat(fd, &open) == 0 and c.stat(path.ptr, &now) == 0 and now.st_ino != open.st_ino;
        if (moved) {
            lines.drain(fd);
            const next = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
            if (next >= 0) {
                _ = c.close(fd);
                fd = next;
            }
            continue;
        }
        if (c.kill(pid, 0) != 0) {
            lines.drain(fd);
            say("gtty closed\n");
            return 0;
        }
        const nap: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = poll_ms * 1_000_000 };
        _ = c.nanosleep(&nap, null);
    }
}

/// Whole lines to stdout, those of one extension when `name` is set.
const Lines = struct {
    name: ?[]const u8,
    held: [8192]u8 = undefined,
    len: usize = 0,

    fn drain(l: *Lines, fd: c_int) void {
        while (true) {
            const n = c.read(fd, l.held[l.len..].ptr, l.held.len - l.len);
            if (n <= 0) return;
            l.len += @intCast(n);
            var at: usize = 0;
            while (std.mem.indexOfScalarPos(u8, l.held[0..l.len], at, '\n')) |end| {
                const line = l.held[at .. end + 1];
                if (l.name == null or nameOf(line).len > 0 and std.mem.eql(u8, nameOf(line), l.name.?)) out(line);
                at = end + 1;
            }
            std.mem.copyForwards(u8, l.held[0 .. l.len - at], l.held[at..l.len]);
            l.len -= at;
        }
    }
};

/// The extension of a log line: its third field.
fn nameOf(line: []const u8) []const u8 {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return "";
    _ = it.next() orelse return "";
    return it.next() orelse "";
}

fn out(s: []const u8) void {
    var left = s;
    while (left.len > 0) {
        const n = c.write(1, left.ptr, left.len);
        if (n <= 0) c.exit(0); // nobody reads any more
        left = left[@intCast(n)..];
    }
}

fn say(s: []const u8) void {
    _ = c.write(2, s.ptr, s.len);
}

test "arguments" {
    const o = parse(&.{ "logs", "-f", "--pid", "12", "git" }).?;
    try std.testing.expect(o.follow);
    try std.testing.expectEqual(@as(c.pid_t, 12), o.pid.?);
    try std.testing.expectEqualStrings("git", o.name.?);
    try std.testing.expect(parse(&.{"logs"}) != null);
    try std.testing.expect(parse(&.{}) == null);
    try std.testing.expect(parse(&.{"load"}) == null);
    try std.testing.expect(parse(&.{ "logs", "--pid" }) == null);
    try std.testing.expect(parse(&.{ "logs", "--pid", "x" }) == null);
    try std.testing.expect(parse(&.{ "logs", "a", "b" }) == null);
    try std.testing.expect(parse(&.{ "logs", "-x" }) == null);
}

test "the extension of a line" {
    try std.testing.expectEqualStrings("git", nameOf("09:05:07.042 info  git 0000002a switched\n"));
    try std.testing.expectEqualStrings("", nameOf("09:05:07.042\n"));
}
