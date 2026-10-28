// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The folders the user worked in lately (the focus chip): a folder
//! under home (not home itself) counts a use each time a command that
//! does something is run there (`countsAsUse`: not cd, ls, find, pwd, …).
//! Kept: what was used within `keep_s` (90 days) of the newest use, so
//! time away doesn't empty it. Shown: the history window, the span back
//! from the newest use that holds `shown_max` folders (a busy day: a few
//! hours; a quiet month: weeks), oldest first, so the newest sit at the
//! bottom of the list, next to the chip. A person picks quickly among
//! about 4 items, each one more costs some half a second: 7 at most.
//!
//! The file, shared by every gtty process (New Window is another one):
//! `$GTTY_FOCUS`, else `$XDG_STATE_HOME/gtty/focus-folders`, else
//! `~/.local/state/gtty/focus-folders` (an older `recent-folders` next
//! to it is moved there); one line per folder, tab-separated `<uses>
//! <last, unix s> <path>`. Each process counts its own new uses
//! (`added`) and `sync` merges them into what is on disk.

const std = @import("std");
const c = @import("../c.zig").c;

const FocusFolders = @This();

/// Uses older than this before the newest one are forgotten.
pub const keep_s: i64 = 90 * 24 * 3600;
/// Folders on the chip's list.
pub const shown_max = 7;
/// Folders kept at most (the least recently used go).
const keep_max = 200;

pub const Entry = struct {
    path: []u8,
    uses: u32,
    last: i64,
    /// Uses this process added since its last `sync`.
    added: u32 = 0,
};

gpa: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
/// Changed since the last `sync`.
dirty: bool = false,

pub fn init(gpa: std.mem.Allocator) FocusFolders {
    return .{ .gpa = gpa };
}

pub fn deinit(r: *FocusFolders) void {
    for (r.entries.items) |e| r.gpa.free(e.path);
    r.entries.deinit(r.gpa);
}

fn now() i64 {
    return @intCast(c.time(null));
}

/// A command was run in `dir`: count a use, when `dir` is a folder under
/// `home` (home itself is easy to get to).
pub fn use(r: *FocusFolders, dir: []const u8, home: []const u8) void {
    if (!underHome(dir, home)) return;
    r.useAt(dir, now());
}

pub fn useAt(r: *FocusFolders, dir: []const u8, at: i64) void {
    r.dirty = true;
    defer r.prune();
    for (r.entries.items) |*e| if (std.mem.eql(u8, e.path, dir)) {
        e.uses +|= 1;
        e.added +|= 1;
        e.last = @max(e.last, at);
        return;
    };
    const copy = r.gpa.dupe(u8, dir) catch return;
    r.entries.append(r.gpa, .{ .path = copy, .uses = 1, .last = at, .added = 1 }) catch r.gpa.free(copy);
}

/// Strictly inside `home` (`/Users/me/src`, not `/Users/me` or `/Users/meg`).
pub fn underHome(dir: []const u8, home: []const u8) bool {
    const h = std.mem.trimEnd(u8, home, "/");
    if (h.len == 0) return false;
    return dir.len > h.len + 1 and std.mem.startsWith(u8, dir, h) and dir[h.len] == '/';
}

/// Forget what was last used more than `keep_s` before the newest use,
/// then the least recently used beyond `keep_max`.
fn prune(r: *FocusFolders) void {
    var newest: i64 = 0;
    for (r.entries.items) |e| newest = @max(newest, e.last);
    var i: usize = 0;
    while (i < r.entries.items.len) {
        if (r.entries.items[i].last < newest - keep_s) {
            r.gpa.free(r.entries.swapRemove(i).path);
        } else i += 1;
    }
    if (r.entries.items.len > keep_max) {
        std.mem.sort(Entry, r.entries.items, {}, better);
        for (r.entries.items[keep_max..]) |e| r.gpa.free(e.path);
        r.entries.shrinkRetainingCapacity(keep_max);
    }
}

/// More recent first; ties: the more used.
fn better(_: void, a: Entry, b: Entry) bool {
    if (a.last != b.last) return a.last > b.last;
    return a.uses > b.uses;
}

/// The chip's list, the history window: the `out.len` folders used last
/// that still exist and are under `home`, oldest first (the newest
/// last). The slices point into the entries (valid until the next
/// change).
pub fn top(r: *FocusFolders, home: []const u8, out: [][]const u8) []const []const u8 {
    std.mem.sort(Entry, r.entries.items, {}, better);
    var n: usize = 0;
    for (r.entries.items) |e| {
        if (n == out.len) break;
        if (!underHome(e.path, home) or !isDir(r.gpa, e.path)) continue;
        out[n] = e.path;
        n += 1;
    }
    std.mem.reverse([]const u8, out[0..n]);
    return out[0..n];
}

/// Forget the folders that are gone (removed, renamed, or no longer a
/// folder); one that can't be looked at (no permission) stays. Returns
/// how many went.
pub fn dropMissing(r: *FocusFolders) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < r.entries.items.len) {
        if (isGone(r.gpa, r.entries.items[i].path)) {
            r.gpa.free(r.entries.swapRemove(i).path);
            n += 1;
        } else i += 1;
    }
    return n;
}

fn isGone(gpa: std.mem.Allocator, p: []const u8) bool {
    const z = gpa.dupeZ(u8, p) catch return false;
    defer gpa.free(z);
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) == 0) return (st.st_mode & c.S_IFMT) != c.S_IFDIR;
    const e = std.c._errno().*;
    return e == @intFromEnum(std.c.E.NOENT) or e == @intFromEnum(std.c.E.NOTDIR);
}

fn isDir(gpa: std.mem.Allocator, p: []const u8) bool {
    const z = gpa.dupeZ(u8, p) catch return false;
    defer gpa.free(z);
    var st: c.struct_stat = undefined;
    return c.stat(z.ptr, &st) == 0 and (st.st_mode & c.S_IFMT) == c.S_IFDIR;
}

// ------------------------------------------------------------ commands

/// A command line that does something in its folder (a use): its first
/// word (after `VAR=value`s) is not a folder look-up, a report on the
/// file system or shell bookkeeping (cd, ls, find, pwd, df, file, echo,
/// …), nor the read-only form of a tool that can also change things
/// (`diskutil list`, `xattr -l`). Empty lines don't count.
pub fn countsAsUse(cmd: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    const first = while (it.next()) |w| {
        if (std.mem.indexOfScalar(u8, w, '=')) |eq| if (eq > 0) continue;
        break w;
    } else return false;
    // `\ls`, `command ls`: the word itself.
    const name = std.mem.trimStart(u8, first, "\\");
    for (lookups) |l| if (std.mem.eql(u8, name, l)) return false;
    const rest = it.rest();
    for (lookup_forms) |form| {
        var fw = std.mem.tokenizeScalar(u8, form, ' ');
        if (!std.mem.eql(u8, name, fw.next().?)) continue;
        var args = std.mem.tokenizeAny(u8, rest, " \t");
        const match = while (fw.next()) |want| {
            if (!std.mem.eql(u8, args.next() orelse break false, want)) break false;
        } else true;
        if (match) return false;
    }
    // xattr only prints unless told to write, delete or clear.
    if (std.mem.eql(u8, name, "xattr")) {
        var args = std.mem.tokenizeAny(u8, rest, " \t");
        while (args.next()) |a| {
            if (a.len > 1 and a[0] == '-' and std.mem.indexOfAny(u8, a[1..], "wdc") != null) return true;
        }
        return false;
    }
    return true;
}

/// Tools that can change things too: these forms (the first words) only
/// report (macOS disks, disk images, Spotlight, Time Machine).
const lookup_forms = [_][]const u8{
    "diskutil list",
    "diskutil info",
    "diskutil activity",
    "diskutil apfs list",
    "diskutil cs list",
    "diskutil ar list",
    "hdiutil info",
    "hdiutil imageinfo",
    "mdutil -s",
    "tmutil listbackups",
    "tmutil latestbackup",
    "tmutil destinationinfo",
    "tmutil machinedirectory",
    "tmutil isexcluded",
    "tmutil listlocalsnapshots",
    "tmutil listlocalsnapshotdates",
    "tmutil compare",
    "tmutil calculatedrift",
    "tmutil uniquesize",
};

const lookups = [_][]const u8{
    // moving around
    "cd",       "pushd",  "popd",   "dirs",    "z",           "zi",      "j",        "autojump",        "zoxide",   "..",       "...",       "-",
    // listing / finding / asking about the folder
    "ls",       "ll",     "la",     "l",       "lsd",         "exa",     "eza",      "tree",            "dir",      "vdir",     "gls",       "find",
    "fd",       "fdfind", "locate", "pwd",     "du",          "df",      "stat",     "file",            "realpath", "readlink", "basename",  "dirname",
    "which",    "whence", "where",  "type",    "hash",        "whereis", "plocate",  "mlocate",         "gfind",    "gstat",    "grealpath", "greadlink",
    // disk use and disks: sizes, free space, mounts (reports only)
    "ncdu",     "gdu",    "dust",   "dua",     "duf",         "gdf",     "lsblk",    "findmnt",         "blkid",
    // what a file is: attributes, permissions, metadata
       "namei",    "lsattr",    "getfacl",
    "getfattr", "mdls",   "mdfind", "lsof",
    // macOS: Finder info, file systems, storage, file activity
       "GetFileInfo", "lsvfs",   "fs_usage", "system_profiler", "quota",
    // shell bookkeeping
       "echo",     "printf",    "clear",
    "reset",    "exit",   "logout", "history", "fc",          "alias",   "unalias",  "export",          "unset",    "set",      "setopt",    "unsetopt",
    "source",   ".",      "true",   "false",   ":",           "jobs",    "fg",       "bg",              "wait",     "read",     "let",       "declare",
    "typeset",  "local",  "rehash",
};

// ------------------------------------------------------------ file

/// Where the file is; null: no home.
pub fn path(buf: []u8) ?[:0]const u8 {
    if (c.getenv("GTTY_FOCUS")) |p| return std.fmt.bufPrintSentinel(buf, "{s}", .{std.mem.span(p)}, 0) catch null;
    return stateFile(buf, "focus-folders");
}

/// `name` in gtty's state folder; null: no home.
fn stateFile(buf: []u8, name: []const u8) ?[:0]const u8 {
    if (c.getenv("XDG_STATE_HOME")) |x| if (x[0] != 0)
        return std.fmt.bufPrintSentinel(buf, "{s}/gtty/{s}", .{ std.mem.span(x), name }, 0) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintSentinel(buf, "{s}/.local/state/gtty/{s}", .{ std.mem.span(home), name }, 0) catch null;
}

/// The file from before the chip was named focus (`recent-folders`)
/// becomes the new one while there is none yet (not with `$GTTY_FOCUS`).
fn migrate(p: [:0]const u8) void {
    if (c.getenv("GTTY_FOCUS") != null or c.access(p.ptr, c.F_OK) == 0) return;
    var obuf: [4096]u8 = undefined;
    const old = stateFile(&obuf, "recent-folders") orelse return;
    _ = c.rename(old.ptr, p.ptr);
}

/// Read the file again and fold in this process's new uses, minus the
/// folders that are gone (`dropMissing`); write it back when anything
/// changed. The list is then the file's (other gtty processes' uses
/// included).
pub fn sync(r: *FocusFolders) void {
    var pbuf: [4096]u8 = undefined;
    const p = path(&pbuf) orelse return;
    migrate(p);
    var disk = FocusFolders.init(r.gpa);
    defer disk.deinit();
    disk.load(p);
    r.mergeInto(&disk);
    const write = disk.dropMissing() > 0 or r.dirty;
    std.mem.swap(std.ArrayList(Entry), &r.entries, &disk.entries);
    r.dirty = false;
    if (write) r.save(p);
}

/// Add this process's new uses to `disk` (theirs stay).
fn mergeInto(r: *FocusFolders, disk: *FocusFolders) void {
    for (r.entries.items) |*e| {
        if (e.added == 0) continue;
        const found = for (disk.entries.items) |*d| {
            if (std.mem.eql(u8, d.path, e.path)) break d;
        } else null;
        if (found) |d| {
            d.uses +|= e.added;
            d.last = @max(d.last, e.last);
        } else {
            const copy = r.gpa.dupe(u8, e.path) catch continue;
            disk.entries.append(r.gpa, .{ .path = copy, .uses = e.added, .last = e.last }) catch r.gpa.free(copy);
        }
        e.added = 0;
    }
    disk.prune();
}

fn load(r: *FocusFolders, p: [:0]const u8) void {
    const fp = c.fopen(p.ptr, "r") orelse return;
    defer _ = c.fclose(fp);
    var buf: [4200]u8 = undefined;
    while (c.fgets(&buf, buf.len, fp) != null) r.parseLine(std.mem.trimEnd(u8, std.mem.sliceTo(&buf, 0), "\r\n"));
}

pub fn parseLine(r: *FocusFolders, line: []const u8) void {
    if (line.len == 0 or line[0] == '#') return;
    var it = std.mem.splitScalar(u8, line, '\t');
    const uses = std.fmt.parseInt(u32, it.next() orelse return, 10) catch return;
    const last = std.fmt.parseInt(i64, it.next() orelse return, 10) catch return;
    const dir = it.rest();
    if (dir.len == 0 or dir[0] != '/') return;
    const copy = r.gpa.dupe(u8, dir) catch return;
    r.entries.append(r.gpa, .{ .path = copy, .uses = uses, .last = last }) catch r.gpa.free(copy);
}

pub fn format(r: *const FocusFolders, w: *std.Io.Writer) !void {
    try w.writeAll("# gtty focus folders (the focus chip): uses, last use (unix s), folder\n");
    for (r.entries.items) |e| try w.print("{d}\t{d}\t{s}\n", .{ e.uses, e.last, e.path });
}

/// Temp file + rename, private.
fn save(r: *const FocusFolders, p: [:0]const u8) void {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| mkdirs(p[0..slash]);
    var aw: std.Io.Writer.Allocating = .init(r.gpa);
    defer aw.deinit();
    r.format(&aw.writer) catch return;
    var tbuf: [4200]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.{d}.tmp", .{ p, c.getpid() }, 0) catch return;
    const fp = c.fopen(tmp.ptr, "w") orelse return;
    _ = c.chmod(tmp.ptr, 0o600);
    const data = aw.written();
    const ok = c.fwrite(data.ptr, 1, data.len, fp) == data.len;
    if (c.fclose(fp) != 0 or !ok) {
        _ = c.unlink(tmp.ptr);
        return;
    }
    _ = c.rename(tmp.ptr, p.ptr);
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

test "commands that count as a use" {
    const t = std.testing;
    try t.expect(countsAsUse("make"));
    try t.expect(countsAsUse("git status"));
    try t.expect(countsAsUse("CC=clang make -j8"));
    try t.expect(countsAsUse("vim x.c"));
    try t.expect(!countsAsUse("ls -la"));
    try t.expect(!countsAsUse("\\ls"));
    try t.expect(!countsAsUse("cd src"));
    try t.expect(!countsAsUse("find . -name x"));
    try t.expect(!countsAsUse("pwd"));
    try t.expect(!countsAsUse("df -h"));
    try t.expect(!countsAsUse("du -sh *"));
    try t.expect(!countsAsUse("file notes.md"));
    try t.expect(!countsAsUse("ncdu"));
    try t.expect(!countsAsUse("mdls x.pdf"));
    try t.expect(!countsAsUse("GetFileInfo x.pdf"));
    try t.expect(!countsAsUse("system_profiler SPStorageDataType"));
    try t.expect(!countsAsUse("diskutil list"));
    try t.expect(!countsAsUse("diskutil apfs list"));
    try t.expect(countsAsUse("diskutil eraseDisk APFS x disk4"));
    try t.expect(countsAsUse("diskutil apfs deleteVolume disk3s5"));
    try t.expect(!countsAsUse("hdiutil imageinfo x.dmg"));
    try t.expect(countsAsUse("hdiutil create -size 1g x.dmg"));
    try t.expect(!countsAsUse("tmutil listbackups"));
    try t.expect(countsAsUse("tmutil startbackup"));
    try t.expect(!countsAsUse("mdutil -s /"));
    try t.expect(countsAsUse("mdutil -i off /"));
    try t.expect(!countsAsUse("xattr x.pdf"));
    try t.expect(!countsAsUse("xattr -l -r ."));
    try t.expect(!countsAsUse("xattr -p com.apple.quarantine x.pdf"));
    try t.expect(countsAsUse("xattr -d com.apple.quarantine x.pdf"));
    try t.expect(countsAsUse("xattr -rc ."));
    try t.expect(!countsAsUse("FOO=1"));
    try t.expect(!countsAsUse("   "));
}

test "under home only, not home itself" {
    const t = std.testing;
    try t.expect(underHome("/Users/me/src", "/Users/me"));
    try t.expect(underHome("/Users/me/src", "/Users/me/"));
    try t.expect(!underHome("/Users/me", "/Users/me"));
    try t.expect(!underHome("/Users/me/", "/Users/me"));
    try t.expect(!underHome("/Users/meg/src", "/Users/me"));
    try t.expect(!underHome("/tmp/x", "/Users/me"));
    try t.expect(!underHome("/Users/me/src", ""));
}

test "kept: 90 days before the newest use" {
    const t = std.testing;
    var r = FocusFolders.init(t.allocator);
    defer r.deinit();
    const day = 24 * 3600;
    r.useAt("/h/old", 1000);
    r.useAt("/h/a", 9 * day);
    r.useAt("/h/b", 10 * day + 5);
    // 100 days: /h/a (91 days before) goes, /h/b (90 days less 5 s)
    // stays; /h/old went already.
    r.useAt("/h/c", 100 * day);
    try t.expectEqual(@as(usize, 2), r.entries.items.len);
    std.mem.sort(Entry, r.entries.items, {}, better);
    try t.expectEqualStrings("/h/c", r.entries.items[0].path);
    try t.expectEqualStrings("/h/b", r.entries.items[1].path);
}

test "the list: the folders used last, oldest first" {
    const t = std.testing;
    var r = FocusFolders.init(t.allocator);
    defer r.deinit();
    // Real folders (`top` skips missing ones), home = /usr.
    r.useAt("/usr/bin", 300);
    r.useAt("/usr/lib", 100);
    r.useAt("/usr/lib", 110);
    r.useAt("/usr/lib", 120); // used most, but not lately
    r.useAt("/usr/share", 200);
    r.useAt("/usr/no-such-folder-gtty-test", 400);
    var buf: [2][]const u8 = undefined;
    const list = r.top("/usr", &buf);
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("/usr/share", list[0]);
    try t.expectEqualStrings("/usr/bin", list[1]);
}

test "folders that are gone are dropped" {
    const t = std.testing;
    var r = FocusFolders.init(t.allocator);
    defer r.deinit();
    r.useAt("/", 100);
    r.useAt("/no/such/folder/gtty-test", 100);
    r.useAt("/dev/null", 100); // not a folder
    try t.expectEqual(@as(usize, 2), r.dropMissing());
    try t.expectEqual(@as(usize, 1), r.entries.items.len);
    try t.expectEqualStrings("/", r.entries.items[0].path);
}

test "merge adds only this process's new uses" {
    const t = std.testing;
    var mine = FocusFolders.init(t.allocator);
    defer mine.deinit();
    var disk = FocusFolders.init(t.allocator);
    defer disk.deinit();
    disk.parseLine("5\t100\t/h/a");
    disk.parseLine("2\t90\t/h/b");
    mine.parseLine("5\t100\t/h/a"); // loaded earlier
    mine.useAt("/h/a", 120);
    mine.useAt("/h/c", 130);
    mine.mergeInto(&disk);
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try disk.format(&aw.writer);
    try t.expect(std.mem.indexOf(u8, aw.written(), "6\t120\t/h/a\n") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "2\t90\t/h/b\n") != null);
    try t.expect(std.mem.indexOf(u8, aw.written(), "1\t130\t/h/c\n") != null);
    // Merged once: a second merge adds nothing.
    mine.mergeInto(&disk);
    try t.expectEqual(@as(u32, 6), disk.entries.items[0].uses);
}
