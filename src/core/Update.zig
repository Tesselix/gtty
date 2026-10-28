// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Is there a newer gtty? One question to GitHub's API (the latest
//! stable release: odd-MINOR releases are pre-releases, so never
//! "latest"), with `curl` in the background on pipes, polled each frame.
//! Nothing about the user is sent (only curl's own User-Agent).
//!
//! Tests: `GTTY_UPDATE_REPLY=file` (the file's text is the answer, no
//! network), `GTTY_UPDATE_VERSION` (pretend to be that version).

const std = @import("std");
const c = @import("../c.zig").c;

pub const repo = "gttyterm/gtty";
pub const api_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";
pub const download_url = "https://github.com/" ++ repo ++ "/releases/download/";

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// `X.Y.Z` or `vX.Y.Z`; anything else (`dev`, `1.2`, `1.2.3-rc1`): null.
    pub fn parse(s: []const u8) ?Version {
        const t = if (s.len > 0 and s[0] == 'v') s[1..] else s;
        var it = std.mem.splitScalar(u8, t, '.');
        var v: [3]u32 = undefined;
        for (&v) |*n| {
            const part = it.next() orelse return null;
            if (part.len == 0) return null;
            n.* = std.fmt.parseInt(u32, part, 10) catch return null;
        }
        if (it.next() != null) return null;
        return .{ .major = v[0], .minor = v[1], .patch = v[2] };
    }

    pub fn newerThan(a: Version, b: Version) bool {
        if (a.major != b.major) return a.major > b.major;
        if (a.minor != b.minor) return a.minor > b.minor;
        return a.patch > b.patch;
    }
};

/// The latest release, as GitHub tells it.
pub const Release = struct {
    version: Version,
    tag_buf: [32]u8 = undefined,
    tag_len: usize = 0,
    url_buf: [256]u8 = undefined,
    url_len: usize = 0,

    pub fn tag(r: *const Release) []const u8 {
        return r.tag_buf[0..r.tag_len];
    }
    /// The release's page.
    pub fn url(r: *const Release) []const u8 {
        return r.url_buf[0..r.url_len];
    }
    /// The version without the tag's `v`.
    pub fn number(r: *const Release) []const u8 {
        const t = r.tag();
        return if (t.len > 0 and t[0] == 'v') t[1..] else t;
    }
};

pub const Result = union(enum) {
    release: Release,
    err: []const u8,
};

/// The API's answer (a release's JSON) → the release.
pub fn parseRelease(gpa: std.mem.Allocator, body: []const u8) Result {
    const J = struct { tag_name: []const u8 = "", html_url: []const u8 = "" };
    const p = std.json.parseFromSlice(J, gpa, body, .{ .ignore_unknown_fields = true }) catch
        return .{ .err = "could not read GitHub's answer" };
    defer p.deinit();
    const v = Version.parse(p.value.tag_name) orelse return .{ .err = "the latest release has no version number" };
    var r: Release = .{ .version = v };
    if (p.value.tag_name.len > r.tag_buf.len) return .{ .err = "the latest release has no version number" };
    @memcpy(r.tag_buf[0..p.value.tag_name.len], p.value.tag_name);
    r.tag_len = p.value.tag_name.len;
    // Only GitHub's own pages are opened.
    const page = p.value.html_url;
    const ok = std.mem.startsWith(u8, page, "https://github.com/") and page.len <= r.url_buf.len;
    const u = if (ok) page else "https://github.com/" ++ repo ++ "/releases/latest";
    @memcpy(r.url_buf[0..u.len], u);
    r.url_len = u.len;
    return .{ .release = r };
}

/// curl's output (body + "\n" + HTTP status) → the release, or an error.
pub fn parseResponse(gpa: std.mem.Allocator, out: []const u8) Result {
    if (out.len == 0) return .{ .err = "no answer (no network, curl missing, or it timed out)" };
    const nl = std.mem.lastIndexOfScalar(u8, out, '\n') orelse return .{ .err = "could not read GitHub's answer" };
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, out[nl + 1 ..], " \r\n"), 10) catch 0;
    return switch (status) {
        200 => parseRelease(gpa, out[0..nl]),
        404 => .{ .err = "no release published yet" },
        403, 429 => .{ .err = "GitHub is limiting requests, try again later" },
        else => .{ .err = "GitHub did not answer" },
    };
}

/// How this gtty was installed on Linux: what updates it.
pub const Installer = enum {
    apt,
    dnf,
    yum,
    zypper,
    rpm,
    /// Not from a package (tar.gz, source): no command.
    none,

    pub fn fromName(s: []const u8) Installer {
        return std.meta.stringToEnum(Installer, s) orelse .none;
    }
};

/// The shell command that installs `r` (x86_64 packages), with sudo;
/// null for `.none`.
pub fn installCommand(buf: []u8, inst: Installer, r: *const Release) ?[]const u8 {
    const v = r.number();
    const t = r.tag();
    return switch (inst) {
        .none => null,
        .apt => std.fmt.bufPrint(buf, "curl -fL -o /tmp/gtty_{0s}_amd64.deb " ++ download_url ++ "{1s}/gtty_{0s}_amd64.deb && sudo apt install /tmp/gtty_{0s}_amd64.deb", .{ v, t }) catch null,
        .dnf, .yum, .zypper => std.fmt.bufPrint(buf, "sudo {s} install " ++ download_url ++ "{s}/gtty-{s}-1.x86_64.rpm", .{ @tagName(inst), t, v }) catch null,
        .rpm => std.fmt.bufPrint(buf, "sudo rpm -U " ++ download_url ++ "{s}/gtty-{s}-1.x86_64.rpm", .{ t, v }) catch null,
    };
}

/// One check in flight: curl on pipes.
pub const Check = struct {
    gpa: std.mem.Allocator,
    pid: c_int,
    out_fd: c_int,
    out: std.ArrayList(u8) = .empty,
    started_ms: u64,
    done: bool = false,

    const timeout_ms = 30_000;
    const max_out = 1 << 20;

    pub fn start(gpa: std.mem.Allocator, now_ms: u64) !*Check {
        const argv = [_:null]?[*:0]const u8{
            "curl", "-sSL",           "--max-time", "25", "-H", "Accept: application/vnd.github+json",
            "-w",   "\n%{http_code}", api_url,      null,
        };
        var in_fd: c_int = -1;
        var out_fd: c_int = -1;
        var pid: c_int = -1;
        if (c.gtty_spawn_pipes(@ptrCast(&argv), null, "", &in_fd, &out_fd, &pid) != 0) return error.Spawn;
        c.gtty_close(in_fd);
        const k = try gpa.create(Check);
        k.* = .{ .gpa = gpa, .pid = pid, .out_fd = out_fd, .started_ms = now_ms };
        return k;
    }

    /// Read what came; true once curl is done (or timed out).
    pub fn poll(k: *Check, now_ms: u64) bool {
        if (k.done) return true;
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = c.gtty_read(k.out_fd, &buf, buf.len);
            if (n == c.GTTY_AGAIN) break;
            if (n <= 0) {
                k.finish();
                return true;
            }
            if (k.out.items.len + @as(usize, @intCast(n)) <= max_out) k.out.appendSlice(k.gpa, buf[0..@intCast(n)]) catch {};
        }
        if (now_ms -| k.started_ms > timeout_ms) {
            k.finish();
            k.out.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    fn finish(k: *Check) void {
        k.done = true;
        c.gtty_kill(k.pid);
        var code: c_int = 0;
        var tries: usize = 0;
        while (tries < 50 and c.gtty_poll_exit(k.pid, &code) == 0) : (tries += 1) _ = c.usleep(1000);
    }

    pub fn result(k: *Check) Result {
        return parseResponse(k.gpa, k.out.items);
    }

    pub fn destroy(k: *Check) void {
        if (!k.done) k.finish();
        c.gtty_close(k.out_fd);
        k.out.deinit(k.gpa);
        k.gpa.destroy(k);
    }
};

test "versions" {
    const t = std.testing;
    const a = Version.parse("v0.4.0").?;
    try t.expectEqual(@as(u32, 4), a.minor);
    try t.expect(Version.parse("dev") == null);
    try t.expect(Version.parse("1.2") == null);
    try t.expect(Version.parse("1.2.3.4") == null);
    try t.expect(Version.parse("1.2.3-rc1") == null);
    try t.expect(Version.parse("0.10.0").?.newerThan(Version.parse("0.9.9").?));
    try t.expect(!Version.parse("1.0.0").?.newerThan(Version.parse("1.0.0").?));
    try t.expect(Version.parse("1.0.1").?.newerThan(Version.parse("1.0.0").?));
}

test "release answer" {
    const t = std.testing;
    const ok = parseResponse(t.allocator, "{\"tag_name\":\"v0.4.0\",\"html_url\":\"https://github.com/gttyterm/gtty/releases/tag/v0.4.0\",\"assets\":[]}\n200");
    try t.expectEqualStrings("0.4.0", ok.release.number());
    try t.expectEqualStrings("https://github.com/gttyterm/gtty/releases/tag/v0.4.0", ok.release.url());
    // A page elsewhere: the releases page instead.
    const odd = parseResponse(t.allocator, "{\"tag_name\":\"v0.4.0\",\"html_url\":\"https://evil.example/\"}\n200");
    try t.expectEqualStrings("https://github.com/gttyterm/gtty/releases/latest", odd.release.url());
    try t.expect(parseResponse(t.allocator, "{\"message\":\"Not Found\"}\n404") == .err);
    try t.expect(parseResponse(t.allocator, "") == .err);
    try t.expect(parseResponse(t.allocator, "{\"tag_name\":\"nightly\"}\n200") == .err);
}

test "install commands" {
    const t = std.testing;
    const r = parseResponse(t.allocator, "{\"tag_name\":\"v0.4.0\"}\n200").release;
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("curl -fL -o /tmp/gtty_0.4.0_amd64.deb https://github.com/gttyterm/gtty/releases/download/v0.4.0/gtty_0.4.0_amd64.deb && sudo apt install /tmp/gtty_0.4.0_amd64.deb", installCommand(&buf, .apt, &r).?);
    try t.expectEqualStrings("sudo dnf install https://github.com/gttyterm/gtty/releases/download/v0.4.0/gtty-0.4.0-1.x86_64.rpm", installCommand(&buf, .dnf, &r).?);
    try t.expectEqualStrings("sudo rpm -U https://github.com/gttyterm/gtty/releases/download/v0.4.0/gtty-0.4.0-1.x86_64.rpm", installCommand(&buf, .rpm, &r).?);
    try t.expect(installCommand(&buf, .none, &r) == null);
    try t.expectEqual(Installer.zypper, Installer.fromName("zypper"));
    try t.expectEqual(Installer.none, Installer.fromName("pacman"));
}
