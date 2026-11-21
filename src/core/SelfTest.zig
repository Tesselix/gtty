// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! `gtty --self-test [options]`: the check suite embedded in pre-release
//! builds (build.zig `selfTestModule`: scripts/linux-check.sh and
//! test/linux/) is written to a temporary folder, laid out as in the
//! repo, and run with bash against this very executable. The results
//! (a folder and a .tar.gz to send back) land in the current folder; the
//! options go to the runner (`--only NAME`, `--no-manual`, `--out DIR`).

const std = @import("std");
const c = @import("../c.zig").c;
const suite = @import("selftest");

pub const available = suite.files.len > 0;

/// Runs the suite; the exit status to leave with.
pub fn run(args: []const [:0]const u8) u8 {
    if (!available) {
        std.debug.print(
            \\this gtty has no self test (only pre-releases and builds from
            \\source carry it); from a checkout: scripts/linux-check.sh
            \\
        , .{});
        return 2;
    }
    var self_buf: [4096]u8 = undefined;
    if (c.gtty_self_path(&self_buf, self_buf.len) != 0) {
        std.debug.print("gtty --self-test: can't find gtty's own executable\n", .{});
        return 2;
    }
    const self: [*:0]const u8 = @ptrCast(&self_buf);

    const tmp = std.mem.span(c.getenv("TMPDIR") orelse @as([*c]const u8, "/tmp"));
    var dir_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dir_buf, "{s}/gtty-selftest-{d}", .{ std.mem.trimEnd(u8, tmp, "/"), c.getpid() }, 0) catch return 2;
    defer removeTree(dir);
    for (suite.files) |f| writeFile(dir, f.path, f.data) catch {
        std.debug.print("gtty --self-test: can't write {s}/{s}\n", .{ dir, f.path });
        return 2;
    };

    var path_buf: [1100]u8 = undefined;
    const runner = std.fmt.bufPrintSentinel(&path_buf, "{s}/scripts/linux-check.sh", .{dir}, 0) catch return 2;
    var argv: [40]?[*:0]const u8 = @splat(null);
    argv[0] = "bash";
    argv[1] = runner.ptr;
    argv[2] = "--gtty";
    argv[3] = self;
    var n: usize = 4;
    for (args) |a| {
        if (n + 1 >= argv.len) break;
        argv[n] = a.ptr;
        n += 1;
    }
    return spawnWait(&argv);
}

fn writeFile(dir: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [1200]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, rel }, 0);
    // Every folder on the way, dir itself first.
    buf[dir.len] = 0;
    _ = c.mkdir(&buf, 0o700);
    buf[dir.len] = '/';
    var i: usize = dir.len;
    while (std.mem.indexOfScalarPos(u8, path, i + 1, '/')) |slash| : (i = slash) {
        buf[slash] = 0;
        _ = c.mkdir(&buf, 0o700);
        buf[slash] = '/';
    }
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, if (std.mem.endsWith(u8, rel, ".sh")) 0o755 else 0o644));
    if (fd < 0) return error.Open;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const w = c.write(fd, data.ptr + off, data.len - off);
        if (w <= 0) return error.Write;
        off += @intCast(w);
    }
}

/// The child's exit status (1 when it died by a signal or couldn't start).
fn spawnWait(argv: [*]const ?[*:0]const u8) u8 {
    const pid = c.fork();
    if (pid < 0) return 1;
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(argv));
        std.debug.print("gtty --self-test: needs bash\n", .{});
        c._exit(127);
    }
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0) {}
    const s: u32 = @bitCast(status);
    return if (s & 0x7f == 0) @truncate((s >> 8) & 0xff) else 1;
}

fn removeTree(dir: [:0]const u8) void {
    var argv = [_]?[*:0]const u8{ "rm", "-rf", dir.ptr, null };
    _ = spawnWait(&argv);
}
