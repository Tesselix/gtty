// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! gtty-sessions: snapshots of a gtty screen's job windows (the Session
//! menu, the session chip, the Session Manager). A snapshot keeps, per
//! window, only what brings it back: its shell, the folder, the user it
//! runs as, and for an ssh / mosh session the command line, the host and
//! the folder over there; nothing about the jobs running in it. Where
//! each window was (the windows area's tiles, the job grid) is kept for
//! the manager's picture and for the restore.
//!
//! The file, shared by every gtty process on the machine: `$GTTY_SESSIONS`,
//! else `$XDG_STATE_HOME/gtty/sessions`, else `~/.local/state/gtty/sessions`
//! (0600). Every change reads it again first (`reload`), changes it and
//! writes it back (temp file + rename), so gttys don't lose each other's
//! sessions. Lines, tab-separated, values escaped (`\\`, `\t`, `\n`):
//!   S <id> <created, unix s> <last used, unix s> <aspect> <name>
//!   W <place> <x> <y> <w> <h> <kind> <shell> <uid> <user> <folder> <host> <remote folder> <command>
//! A `W` line belongs to the `S` line above it.

const std = @import("std");
const c = @import("../c.zig").c;

const Sessions = @This();

/// Sessions on the menu and the chip's list.
pub const shown_max = 7;
/// Sessions kept at most (the least recently used go).
const keep_max = 100;

/// Where a window was: the current one, another one in the windows area,
/// or the job grid.
pub const Place = enum { main, shown, grid };
pub const Kind = enum { local, ssh, mosh };

pub const Win = struct {
    place: Place,
    /// Its tile, as fractions of the windows area (`main` / `shown`).
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    kind: Kind = .local,
    /// The shell's name ("zsh"); a session window: the local shell it ran in.
    shell: []u8,
    uid: u32,
    /// The user's name (`uid`), "" when unknown.
    user: []u8,
    /// The local folder (a session: where ssh was started).
    folder: []u8,
    /// A session: its destination ("me@box") and the folder there ("" when
    /// gtty didn't know it), and the command line that opened it.
    host: []u8,
    rfolder: []u8,
    cmd: []u8,

    fn free(w: Win, gpa: std.mem.Allocator) void {
        for ([_][]u8{ w.shell, w.user, w.folder, w.host, w.rfolder, w.cmd }) |s| gpa.free(s);
    }

    /// The command its tile shows: the shell, or ssh / mosh.
    pub fn command(w: *const Win) []const u8 {
        return switch (w.kind) {
            .local => w.shell,
            .ssh => "ssh",
            .mosh => "mosh",
        };
    }
};

/// What `add` takes: the same fields, borrowed.
pub const WinSpec = struct {
    place: Place,
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
    kind: Kind = .local,
    shell: []const u8,
    uid: u32,
    user: []const u8 = "",
    folder: []const u8,
    host: []const u8 = "",
    rfolder: []const u8 = "",
    cmd: []const u8 = "",
};

pub const Session = struct {
    id: []u8,
    name: []u8,
    created: i64,
    used: i64,
    /// The windows area's width / height when it was taken.
    aspect: f32,
    wins: std.ArrayList(Win) = .empty,

    fn free(s: *Session, gpa: std.mem.Allocator) void {
        for (s.wins.items) |w| w.free(gpa);
        s.wins.deinit(gpa);
        gpa.free(s.id);
        gpa.free(s.name);
    }

    /// It had windows in the job grid (the picture shows the grid column).
    pub fn hasGrid(s: *const Session) bool {
        for (s.wins.items) |w| if (w.place == .grid) return true;
        return false;
    }
};

gpa: std.mem.Allocator,
list: std.ArrayList(Session) = .empty,
/// The file as last read (`refresh` reads it again when it changed).
stamp: [2]i64 = .{ -1, -1 },
/// The file to use; null: none (a test script without `GTTY_SESSIONS`).
file: ?[:0]u8 = null,
/// Ids made by this process (`newId`).
made: u32 = 0,

pub fn init(gpa: std.mem.Allocator) Sessions {
    return .{ .gpa = gpa };
}

pub fn deinit(s: *Sessions) void {
    s.clear();
    s.list.deinit(s.gpa);
    if (s.file) |f| s.gpa.free(f);
}

fn clear(s: *Sessions) void {
    for (s.list.items) |*x| x.free(s.gpa);
    s.list.clearRetainingCapacity();
}

pub fn now() i64 {
    return @intCast(c.time(null));
}

/// The session with id `id`.
pub fn find(s: *Sessions, id: []const u8) ?*Session {
    for (s.list.items) |*x| if (std.mem.eql(u8, x.id, id)) return x;
    return null;
}

/// Last used first; ties: the newer.
fn moreRecent(_: void, a: Session, b: Session) bool {
    if (a.used != b.used) return a.used > b.used;
    return a.created > b.created;
}

/// Sort the list: the last used first (the menu's and the manager's order).
pub fn sort(s: *Sessions) void {
    std.mem.sort(Session, s.list.items, {}, moreRecent);
}

/// The `out.len` sessions used last, the last used first (pointers into
/// the list: valid until the next change).
pub fn recent(s: *Sessions, out: []*Session) []*Session {
    s.sort();
    const n = @min(out.len, s.list.items.len);
    for (out[0..n], s.list.items[0..n]) |*o, *x| o.* = x;
    return out[0..n];
}

/// A new id: unique on this machine (time, process, a count).
pub fn newId(s: *Sessions, buf: []u8) []const u8 {
    s.made += 1;
    return std.fmt.bufPrint(buf, "{x}-{x}-{x}", .{ now(), c.getpid(), s.made }) catch "0";
}

/// Add a session (made now, used now); `wins` are copied.
pub fn add(s: *Sessions, id: []const u8, name: []const u8, aspect: f32, wins: []const WinSpec) !*Session {
    return s.addAt(id, name, now(), aspect, wins);
}

pub fn addAt(s: *Sessions, id: []const u8, name: []const u8, at: i64, aspect: f32, wins: []const WinSpec) !*Session {
    var x: Session = .{ .id = try s.gpa.dupe(u8, id), .name = &.{}, .created = at, .used = at, .aspect = aspect };
    errdefer x.free(s.gpa);
    x.name = try s.gpa.dupe(u8, name);
    for (wins) |w| try x.wins.append(s.gpa, try s.copyWin(w));
    try s.list.append(s.gpa, x);
    s.prune();
    return s.find(id) orelse error.OutOfMemory;
}

fn copyWin(s: *Sessions, w: WinSpec) !Win {
    const g = s.gpa;
    var out: Win = .{ .place = w.place, .x = w.x, .y = w.y, .w = w.w, .h = w.h, .kind = w.kind, .uid = w.uid, .shell = &.{}, .user = &.{}, .folder = &.{}, .host = &.{}, .rfolder = &.{}, .cmd = &.{} };
    errdefer out.free(g);
    out.shell = try g.dupe(u8, w.shell);
    out.user = try g.dupe(u8, w.user);
    out.folder = try g.dupe(u8, w.folder);
    out.host = try g.dupe(u8, w.host);
    out.rfolder = try g.dupe(u8, w.rfolder);
    out.cmd = try g.dupe(u8, w.cmd);
    return out;
}

/// The least recently used beyond `keep_max` go.
fn prune(s: *Sessions) void {
    if (s.list.items.len <= keep_max) return;
    s.sort();
    for (s.list.items[keep_max..]) |*x| x.free(s.gpa);
    s.list.shrinkRetainingCapacity(keep_max);
}

/// Used now (restored).
pub fn touch(s: *Sessions, id: []const u8) bool {
    const x = s.find(id) orelse return false;
    x.used = @max(now(), x.used + 1);
    return true;
}

pub fn rename(s: *Sessions, id: []const u8, name: []const u8) bool {
    const x = s.find(id) orelse return false;
    const copy = s.gpa.dupe(u8, name) catch return false;
    s.gpa.free(x.name);
    x.name = copy;
    return true;
}

pub fn remove(s: *Sessions, id: []const u8) bool {
    for (s.list.items, 0..) |*x, i| if (std.mem.eql(u8, x.id, id)) {
        x.free(s.gpa);
        _ = s.list.orderedRemove(i);
        return true;
    };
    return false;
}

// ------------------------------------------------------------ names

const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// The name a snapshot gets: when it was taken, "Oct 28 14:05".
pub fn autoName(buf: []u8, at: i64) []const u8 {
    var t: c.time_t = @intCast(at);
    var tm: c.struct_tm = undefined;
    var w: std.Io.Writer = .fixed(buf);
    if (c.localtime_r(&t, &tm) != null) {
        w.print("{s} {d} {d:0>2}:{d:0>2}", .{ months[@intCast(@mod(tm.tm_mon, 12))], tm.tm_mday, @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch {};
    }
    return w.buffered();
}

// ------------------------------------------------------------ file

/// Where the file is; null: no home.
pub fn path(buf: []u8) ?[:0]const u8 {
    if (c.getenv("GTTY_SESSIONS")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    if (c.getenv("XDG_STATE_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrintSentinel(buf, "{s}/gtty/sessions", .{std.mem.span(x)}, 0) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/gtty/sessions", .{std.mem.span(home)}, 0) catch null;
}

/// Use the file at `p` (read now).
pub fn open(s: *Sessions, p: []const u8) void {
    if (s.file) |f| s.gpa.free(f);
    s.file = s.gpa.dupeZ(u8, p) catch null;
    s.reload();
}

/// The file's modification time and size, or -1s when it isn't there.
fn fileStamp(p: [:0]const u8) [2]i64 {
    var st: c.struct_stat = undefined;
    if (c.stat(p.ptr, &st) != 0) return .{ -1, -1 };
    const mt = if (@hasField(c.struct_stat, "st_mtimespec")) st.st_mtimespec else st.st_mtim;
    return .{ @as(i64, @intCast(mt.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(mt.tv_nsec)), @intCast(st.st_size) };
}

/// Read the file again when another gtty changed it. True when the list
/// changed.
pub fn refresh(s: *Sessions) bool {
    const p = s.file orelse return false;
    if (std.meta.eql(fileStamp(p), s.stamp)) return false;
    s.reload();
    return true;
}

/// Read the file (what is in it now: other gttys' changes too).
pub fn reload(s: *Sessions) void {
    const p = s.file orelse return;
    s.stamp = fileStamp(p);
    s.clear();
    const fp = c.fopen(p.ptr, "r") orelse return;
    defer _ = c.fclose(fp);
    var buf: [32 * 1024]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) s.parseLine(std.mem.trimEnd(u8, std.mem.sliceTo(&buf, 0), "\r\n"));
}

/// Write the list to the file. False: it couldn't be written.
pub fn save(s: *Sessions) bool {
    const p = s.file orelse return true;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirs(p[0..slash]);
    var aw: std.Io.Writer.Allocating = .init(s.gpa);
    defer aw.deinit();
    s.format(&aw.writer) catch return false;
    var tbuf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.{d}.tmp", .{ p, c.getpid() }, 0) catch return false;
    const fp = c.fopen(tmp.ptr, "w") orelse return false;
    _ = c.chmod(tmp.ptr, 0o600);
    const data = aw.written();
    const ok = c.fwrite(data.ptr, 1, data.len, fp) == data.len;
    if (c.fclose(fp) != 0 or !ok or c.rename(tmp.ptr, p.ptr) != 0) {
        _ = c.unlink(tmp.ptr);
        return false;
    }
    s.stamp = fileStamp(p);
    return true;
}

fn mkdirs(dir: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (dir.len == 0 or dir.len >= buf.len) return;
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or dir[i] == '/') {
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{dir[0..i]}, 0) catch return;
            _ = c.mkdir(z.ptr, 0o700);
        }
    }
}

pub fn format(s: *const Sessions, w: *std.Io.Writer) !void {
    try w.writeAll("# gtty sessions (Session menu): S id created used aspect name / W place x y w h kind shell uid user folder host remote-folder command\n");
    for (s.list.items) |*x| {
        try w.print("S\t{s}\t{d}\t{d}\t{d:.4}\t", .{ x.id, x.created, x.used, x.aspect });
        try escape(w, x.name);
        try w.writeByte('\n');
        for (x.wins.items) |*win| {
            try w.print("W\t{s}\t{d:.4}\t{d:.4}\t{d:.4}\t{d:.4}\t{s}", .{ @tagName(win.place), win.x, win.y, win.w, win.h, @tagName(win.kind) });
            for ([_][]const u8{ win.shell, "", win.user, win.folder, win.host, win.rfolder, win.cmd }, 0..) |v, k| {
                try w.writeByte('\t');
                if (k == 1) try w.print("{d}", .{win.uid}) else try escape(w, v);
            }
            try w.writeByte('\n');
        }
    }
}

fn escape(w: *std.Io.Writer, v: []const u8) !void {
    for (v) |ch| switch (ch) {
        '\\' => try w.writeAll("\\\\"),
        '\t' => try w.writeAll("\\t"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(ch),
    };
}

/// `v` with the escapes undone (into `buf`, cut when it doesn't fit).
fn unescape(buf: []u8, v: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < v.len and n < buf.len) : (i += 1) {
        var ch = v[i];
        if (ch == '\\' and i + 1 < v.len) {
            i += 1;
            ch = switch (v[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                else => v[i],
            };
        }
        buf[n] = ch;
        n += 1;
    }
    return buf[0..n];
}

pub fn parseLine(s: *Sessions, line: []const u8) void {
    if (line.len < 2 or line[0] == '#') return;
    var it = std.mem.splitScalar(u8, line, '\t');
    const tag = it.next() orelse return;
    var ubuf: [8192]u8 = undefined;
    if (std.mem.eql(u8, tag, "S")) {
        const id = it.next() orelse return;
        const created = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
        const used = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
        const aspect = std.fmt.parseFloat(f32, it.next() orelse return) catch return;
        const name = unescape(&ubuf, it.rest());
        if (id.len == 0 or s.find(id) != null) return;
        _ = s.addAt(id, name, created, if (aspect > 0.05 and aspect < 20) aspect else 1.6, &.{}) catch return;
        s.find(id).?.used = used;
        return;
    }
    if (!std.mem.eql(u8, tag, "W") or s.list.items.len == 0) return;
    const place = std.meta.stringToEnum(Place, it.next() orelse return) orelse return;
    var r: [4]f32 = undefined;
    for (&r) |*v| v.* = std.math.clamp(std.fmt.parseFloat(f32, it.next() orelse return) catch return, 0, 1);
    const kind = std.meta.stringToEnum(Kind, it.next() orelse return) orelse return;
    var vals: [7][]u8 = undefined;
    var n: usize = 0;
    defer for (vals[0..n]) |v| s.gpa.free(v);
    while (n < vals.len) : (n += 1) {
        const raw = it.next() orelse if (n == vals.len - 1) "" else return;
        vals[n] = s.gpa.dupe(u8, unescape(&ubuf, raw)) catch return;
    }
    const uid = std.fmt.parseInt(u32, vals[1], 10) catch return;
    const x = &s.list.items[s.list.items.len - 1];
    const win = s.copyWin(.{ .place = place, .x = r[0], .y = r[1], .w = r[2], .h = r[3], .kind = kind, .shell = vals[0], .uid = uid, .user = vals[2], .folder = vals[3], .host = vals[4], .rfolder = vals[5], .cmd = vals[6] }) catch return;
    x.wins.append(s.gpa, win) catch win.free(s.gpa);
}

// ------------------------------------------------------------ tests

test "file: written and read back the same" {
    const t = std.testing;
    var a = Sessions.init(t.allocator);
    defer a.deinit();
    _ = try a.addAt("1-a", "Oct 28 · tab\there", 100, 1.5, &.{
        .{ .place = .main, .x = 0, .y = 0, .w = 0.5, .h = 1, .shell = "zsh", .uid = 501, .user = "me", .folder = "/Users/me/src/gtty" },
        .{ .place = .shown, .x = 0.5, .y = 0, .w = 0.5, .h = 1, .kind = .ssh, .shell = "zsh", .uid = 501, .user = "me", .folder = "/Users/me", .host = "me@box", .rfolder = "/srv/app", .cmd = "ssh -p 2222 me@box" },
        .{ .place = .grid, .shell = "bash", .uid = 0, .user = "root", .folder = "/etc" },
    });
    _ = try a.addAt("2-b", "second", 200, 1.6, &.{});
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try a.format(&aw.writer);

    var b = Sessions.init(t.allocator);
    defer b.deinit();
    var lines = std.mem.splitScalar(u8, aw.written(), '\n');
    while (lines.next()) |l| b.parseLine(l);
    try t.expectEqual(@as(usize, 2), b.list.items.len);
    const x = b.find("1-a").?;
    try t.expectEqualStrings("Oct 28 · tab\there", x.name);
    try t.expectEqual(@as(usize, 3), x.wins.items.len);
    const ssh = x.wins.items[1];
    try t.expectEqual(Kind.ssh, ssh.kind);
    try t.expectEqualStrings("ssh -p 2222 me@box", ssh.cmd);
    try t.expectEqualStrings("/srv/app", ssh.rfolder);
    try t.expectEqualStrings("ssh", ssh.command());
    try t.expectEqual(@as(u32, 0), x.wins.items[2].uid);
    try t.expectEqual(Place.grid, x.wins.items[2].place);
    try t.expect(x.hasGrid());
    try t.expect(!b.find("2-b").?.hasGrid());
}

test "recent: the last used first; touch moves one up" {
    const t = std.testing;
    var s = Sessions.init(t.allocator);
    defer s.deinit();
    _ = try s.addAt("a", "a", 100, 1, &.{});
    _ = try s.addAt("b", "b", 300, 1, &.{});
    _ = try s.addAt("c", "c", 200, 1, &.{});
    var buf: [2]*Session = undefined;
    var r = s.recent(&buf);
    try t.expectEqual(@as(usize, 2), r.len);
    try t.expectEqualStrings("b", r[0].id);
    try t.expectEqualStrings("c", r[1].id);
    try t.expect(s.touch("a"));
    r = s.recent(&buf);
    try t.expectEqualStrings("a", r[0].id);
    try t.expect(s.rename("a", "renamed"));
    try t.expectEqualStrings("renamed", s.find("a").?.name);
    try t.expect(s.remove("b"));
    try t.expect(s.find("b") == null);
}

test "names: the time only" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const name = autoName(&buf, 0);
    try t.expect(name.len > 0);
    try t.expect(std.mem.indexOf(u8, name, " · ") == null);
    try t.expect(std.mem.indexOfScalar(u8, name, ':') != null);
}
