// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Installed extensions (docs/extensions.md "Packaging"). Each has a folder
//! `<root>/<name>/` (root as for storage: `$GTTY_EXTENSIONS`, …): `code/`
//! (the unpacked package, replaced on update), `data/` (its stateful
//! storage, kept on update) and `disabled` (a file, when turned off).
//! Every gtty reads the folder (`scan`), so an install by one, or by
//! `gtty ext install`, reaches all.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const Archive = @import("Archive.zig");
const Tee = @import("Tee.zig");
const ExtStorage = @import("ExtStorage.zig");

/// Names gtty's own chips have.
pub const reserved = [_][]const u8{ "folder", "git", "focus", "session", "test", "gtty", "extensions" };
pub const max_name = 32;

/// This machine, as manifests name it: "macos-aarch64", "linux-x86_64".
pub const platform = (if (builtin.os.tag == .macos) "macos" else @tagName(builtin.os.tag)) ++ "-" ++ @tagName(builtin.cpu.arch);

pub const Manifest = struct {
    name: []const u8,
    version: []const u8 = "",
    description: []const u8 = "",
    /// The program, relative to `code/`, for this machine.
    main: []const u8,
    /// "python3", "node", or empty: `main` runs by itself.
    runtime: []const u8 = "",
};

pub const Installed = struct {
    manifest: Manifest,
    /// `<root>/<name>`, and its `code/`.
    dir: []const u8,
    code: []const u8,
    enabled: bool,
    /// The manifest's mtime: a reinstall changes it.
    stamp: i64,
};

/// The folder extensions are installed in (the same as their storage's):
/// `$GTTY_EXTENSIONS`, else `$XDG_DATA_HOME/gtty/extensions`, else
/// `~/.local/share/gtty/extensions`.
pub fn defaultRoot(buf: []u8) ?[]const u8 {
    if (c.getenv("GTTY_EXTENSIONS")) |p| return std.fmt.bufPrint(buf, "{s}", .{std.mem.span(p)}) catch null;
    if (c.getenv("XDG_DATA_HOME")) |p| if (p[0] == '/') return std.fmt.bufPrint(buf, "{s}/gtty/extensions", .{std.mem.span(p)}) catch null;
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/gtty/extensions", .{std.mem.span(home)}) catch null;
}

pub const Error = error{ BadManifest, NoManifest, BadName, Reserved, NotForThisMachine, BadMain, OutOfMemory };

/// Lowercase letters, digits, `-` and `_`, starting with a letter.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or n.len > max_name or !std.ascii.isLower(n[0])) return false;
    for (n) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// `main`: a string, or an object by platform. Allocated in `a`.
pub fn parseManifest(a: std.mem.Allocator, json: []const u8, plat: []const u8) Error!Manifest {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return error.BadManifest;
    const o = switch (v) {
        .object => |o| o,
        else => return error.BadManifest,
    };
    const name = str(o.get("name")) orelse return error.BadManifest;
    if (!validName(name)) return error.BadName;
    for (reserved) |r| if (std.mem.eql(u8, r, name)) return error.Reserved;
    const main = switch (o.get("main") orelse return error.BadManifest) {
        .string => |s| s,
        .object => |m| str(m.get(plat)) orelse return error.NotForThisMachine,
        else => return error.BadManifest,
    };
    if (Archive.cleanName(main) == null) return error.BadMain;
    const runtime = str(o.get("runtime")) orelse "";
    if (runtime.len > 0 and !std.mem.eql(u8, runtime, "python3") and !std.mem.eql(u8, runtime, "node")) return error.BadManifest;
    return .{ .name = name, .version = str(o.get("version")) orelse "", .description = str(o.get("description")) orelse "", .main = main, .runtime = runtime };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Every installed extension, sorted by name, allocated in `a`.
pub fn scan(a: std.mem.Allocator, root: []const u8) ![]Installed {
    var list: std.ArrayList(Installed) = .empty;
    const root_z = try a.dupeZ(u8, root);
    const d = c.opendir(root_z.ptr) orelse return list.items;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |e| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        if (!validName(name)) continue;
        const item = load(a, root, name) catch continue;
        try list.append(a, item);
    }
    std.mem.sort(Installed, list.items, {}, struct {
        fn lt(_: void, x: Installed, y: Installed) bool {
            return std.mem.lessThan(u8, x.manifest.name, y.manifest.name);
        }
    }.lt);
    return list.items;
}

fn load(a: std.mem.Allocator, root: []const u8, name: []const u8) !Installed {
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
    const code = try std.fmt.allocPrint(a, "{s}/code", .{dir});
    const mpath = try std.fmt.allocPrintSentinel(a, "{s}/manifest.json", .{code}, 0);
    var st: c.struct_stat = undefined;
    if (c.stat(mpath.ptr, &st) != 0) return error.NoManifest;
    const json = readSmall(a, mpath, 64 * 1024) orelse return error.NoManifest;
    const m = try parseManifest(a, json, platform);
    if (!std.mem.eql(u8, m.name, name)) return error.BadManifest;
    const off = try std.fmt.allocPrintSentinel(a, "{s}/disabled", .{dir}, 0);
    return .{ .manifest = m, .dir = dir, .code = code, .enabled = c.access(off.ptr, c.F_OK) != 0, .stamp = mtime(&st) };
}

pub fn mtime(st: *const c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_mtimespec")) st.st_mtimespec else st.st_mtim;
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn readSmall(a: std.mem.Allocator, path: [:0]const u8, limit: usize) ?[]u8 {
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (out.items.len <= limit) {
        const n = c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return if (out.items.len > limit) null else out.items;
}

/// The program and its arguments for `x`: the runtime (found on PATH)
/// with `main`, or `main` itself. Null: the runtime isn't installed.
pub fn command(a: std.mem.Allocator, x: Installed) !?[]const []const u8 {
    const main = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ x.code, x.manifest.main }, 0);
    if (x.manifest.runtime.len == 0) return try a.dupe([]const u8, &.{main});
    const rt = (try findProgram(a, x.manifest.runtime)) orelse return null;
    return try a.dupe([]const u8, &.{ rt, main });
}

fn findProgram(a: std.mem.Allocator, name: []const u8) !?[:0]u8 {
    const path = if (c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    // Finder / the Dock start gtty with a short PATH: Homebrew's too.
    const extra = ":/opt/homebrew/bin:/usr/local/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    var more = std.mem.splitScalar(u8, extra[1..], ':');
    while (it.next() orelse more.next()) |dir| {
        if (dir.len == 0) continue;
        const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
        if (c.access(p.ptr, c.X_OK) == 0) return p;
    }
    return null;
}

// ---- changing what is installed ----

pub const InstallError = error{ NotFound, Unsafe, TooBig, BadArchive, WriteFailed, Exists } || Error;

/// An install error in words.
pub fn explain(e: anyerror) []const u8 {
    return switch (e) {
        error.NotFound => "no such file or folder",
        error.NoManifest => "no manifest.json at its top",
        error.BadManifest => "manifest.json needs \"name\" and \"main\" (and \"runtime\" only python3 or node)",
        error.BadName => "the name must be lowercase letters, digits, - or _, starting with a letter, 32 at most",
        error.Reserved => "that name is gtty's own",
        error.NotForThisMachine => "its \"main\" has nothing for " ++ platform,
        error.BadMain => "its \"main\" isn't a file in the package",
        error.Unsafe => "it holds a link, a device or a name outside its folder",
        error.TooBig => "over 256 MB or 20000 files",
        error.BadArchive => "not a zip, tar or tar.gz gtty can read",
        else => @errorName(e),
    };
}

/// A package read and checked, not installed yet: what to ask the user.
pub const Package = struct {
    manifest: Manifest,
    entries: []Archive.Entry,
};

/// Install (or update) from a folder or a package file (zip, tar, tar.gz)
/// at `src`. Returns the name, allocated in `a`.
pub fn install(a: std.mem.Allocator, root: []const u8, src: []const u8) InstallError![]const u8 {
    return installPackage(a, root, try readPackage(a, src));
}

/// Read and check the package at `src`.
pub fn readPackage(a: std.mem.Allocator, src: []const u8) InstallError!Package {
    const src_z = try a.dupeZ(u8, src);
    var st: c.struct_stat = undefined;
    if (c.stat(src_z.ptr, &st) != 0) return error.NotFound;
    var entries: []Archive.Entry = undefined;
    if (st.st_mode & c.S_IFMT == c.S_IFDIR) {
        var list: std.ArrayList(Archive.Entry) = .empty;
        var total: usize = 0;
        try readFolder(a, src, "", &list, &total, 0);
        entries = list.items;
    } else {
        const bytes = readSmall(a, src_z, Archive.max_total) orelse return error.TooBig;
        entries = Archive.read(a, bytes) catch |e| return switch (e) {
            error.Unsafe => error.Unsafe,
            error.TooBig => error.TooBig,
            error.OutOfMemory => error.OutOfMemory,
            error.BadArchive => error.BadArchive,
        };
    }
    entries = stripTop(entries);
    const mjson = for (entries) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, "manifest.json")) break e.data;
    } else return error.NoManifest;
    const m = try parseManifest(a, mjson, platform);
    const has_main = for (entries) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, m.main)) break true;
    } else false;
    if (!has_main) return error.BadMain;
    return .{ .manifest = m, .entries = entries };
}

/// Write a package read by `readPackage`. Returns the name.
pub fn installPackage(a: std.mem.Allocator, root: []const u8, pkg: Package) InstallError![]const u8 {
    const m = pkg.manifest;
    const entries = pkg.entries;
    // A first install: the folders above may not be there yet
    // (~/.local/share/gtty on a new machine).
    const dir = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, m.name }, 0);
    if (!ExtStorage.mkdirs(dir)) return error.WriteFailed;
    // Unpack beside it, then swap: a running copy never sees half of it.
    const stage = try std.fmt.allocPrintSentinel(a, "{s}/.code-{d}", .{ dir, c.getpid() }, 0);
    Tee.Dir.removeTree(stage);
    if (c.mkdir(stage.ptr, 0o700) != 0) return error.WriteFailed;
    errdefer Tee.Dir.removeTree(stage);
    for (entries) |e| {
        const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ stage, e.name }, 0);
        try makeParents(p, stage.len);
        switch (e.kind) {
            .folder => if (c.mkdir(p.ptr, 0o755) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.WriteFailed,
            .file => try writeFile(p, e.data, if (e.exec) 0o755 else 0o644),
        }
    }
    const code = try std.fmt.allocPrintSentinel(a, "{s}/code", .{dir}, 0);
    const old = try std.fmt.allocPrintSentinel(a, "{s}/.old-{d}", .{ dir, c.getpid() }, 0);
    _ = c.rename(code.ptr, old.ptr);
    if (c.rename(stage.ptr, code.ptr) != 0) {
        _ = c.rename(old.ptr, code.ptr);
        return error.WriteFailed;
    }
    Tee.Dir.removeTree(old);
    return m.name;
}

/// A package whose files all sit in one top folder: that folder's inside.
fn stripTop(entries: []Archive.Entry) []Archive.Entry {
    if (entries.len == 0) return entries;
    for (entries) |e| if (std.mem.eql(u8, e.name, "manifest.json")) return entries;
    const first = entries[0].name;
    const top = first[0 .. std.mem.indexOfScalar(u8, first, '/') orelse first.len];
    for (entries) |e| {
        if (!std.mem.startsWith(u8, e.name, top)) return entries;
        if (e.name.len > top.len and e.name[top.len] != '/') return entries;
    }
    var n: usize = 0;
    for (entries) |e| {
        if (e.name.len <= top.len + 1) continue;
        entries[n] = e;
        entries[n].name = e.name[top.len + 1 ..];
        n += 1;
    }
    return entries[0..n];
}

fn readFolder(a: std.mem.Allocator, base: []const u8, rel: []const u8, list: *std.ArrayList(Archive.Entry), total: *usize, depth: u8) InstallError!void {
    if (depth > 16) return error.TooBig;
    const path = try std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{ base, if (rel.len > 0) "/" else "", rel }, 0);
    const d = c.opendir(path.ptr) orelse return error.NotFound;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |e| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // Build output and caches aren't part of an extension.
        if (rel.len == 0 and (std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "__pycache__"))) continue;
        const r = if (rel.len > 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ rel, name }) else try a.dupe(u8, name);
        const full = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ base, r }, 0);
        var st: c.struct_stat = undefined;
        if (c.lstat(full.ptr, &st) != 0) continue;
        switch (st.st_mode & c.S_IFMT) {
            c.S_IFDIR => {
                if (list.items.len >= Archive.max_entries) return error.TooBig;
                try list.append(a, .{ .name = r, .kind = .folder });
                try readFolder(a, base, r, list, total, depth + 1);
            },
            c.S_IFREG => {
                const data = readSmall(a, full, Archive.max_total - total.*) orelse return error.TooBig;
                total.* += data.len;
                if (list.items.len >= Archive.max_entries) return error.TooBig;
                try list.append(a, .{ .name = r, .kind = .file, .exec = st.st_mode & 0o111 != 0, .data = data });
            },
            else => return error.Unsafe, // a link or a device
        }
    }
}

fn makeParents(p: [:0]u8, keep: usize) InstallError!void {
    var i = keep + 1;
    while (std.mem.indexOfScalarPos(u8, p, i, '/')) |slash| : (i = slash + 1) {
        p[slash] = 0;
        defer p[slash] = '/';
        if (c.mkdir(p.ptr, 0o755) != 0 and std.c._errno().* != @intFromEnum(std.c.E.EXIST)) return error.WriteFailed;
    }
}

fn writeFile(p: [:0]const u8, data: []const u8, mode: c_uint) InstallError!void {
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC | c.O_NOFOLLOW, mode);
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    var left = data;
    while (left.len > 0) {
        const n = c.write(fd, left.ptr, left.len);
        if (n <= 0) return error.WriteFailed;
        left = left[@intCast(n)..];
    }
}

/// Remove an extension and its data. False: not installed.
pub fn uninstall(a: std.mem.Allocator, root: []const u8, name: []const u8) !bool {
    if (!validName(name)) return false;
    const dir = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, name }, 0);
    if (c.access(dir.ptr, c.F_OK) != 0) return false;
    // Away from its name first: a gtty scanning sees it gone at once.
    const gone = try std.fmt.allocPrintSentinel(a, "{s}/.gone-{s}-{d}", .{ root, name, c.getpid() }, 0);
    if (c.rename(dir.ptr, gone.ptr) != 0) return false;
    removeAll(gone, 24);
    return true;
}

fn removeAll(dir: [:0]const u8, depth: u8) void {
    if (c.opendir(dir.ptr)) |d| {
        defer _ = c.closedir(d);
        while (c.readdir(d)) |e| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            var buf: [4096]u8 = undefined;
            const f = std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch continue;
            var st: c.struct_stat = undefined;
            if (c.lstat(f.ptr, &st) == 0 and st.st_mode & c.S_IFMT == c.S_IFDIR and depth > 0) removeAll(f, depth - 1) else _ = c.unlink(f.ptr);
        }
    }
    _ = c.rmdir(dir.ptr);
}

/// Turn an extension on or off for every gtty.
pub fn setEnabled(a: std.mem.Allocator, root: []const u8, name: []const u8, on: bool) !void {
    const p = try std.fmt.allocPrintSentinel(a, "{s}/{s}/disabled", .{ root, name }, 0);
    if (on) {
        _ = c.unlink(p.ptr);
    } else {
        const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd >= 0) _ = c.close(fd);
    }
}

/// The root's mtime and the newest manifest's: a change means scan again.
pub fn stampOf(root: []const u8) i64 {
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{root}, 0) catch return 0;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return 0;
    var stamp = mtime(&st);
    const d = c.opendir(z.ptr) orelse return stamp;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |e| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&e.*.d_name)));
        if (!validName(name)) continue;
        var pb: [4096]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&pb, "{s}/{s}", .{ root, name }, 0)) |p| {
            if (c.stat(p.ptr, &st) == 0) stamp = @max(stamp, mtime(&st));
        } else |_| {}
        if (std.fmt.bufPrintSentinel(&pb, "{s}/{s}/code/manifest.json", .{ root, name }, 0)) |p| {
            if (c.stat(p.ptr, &st) == 0) stamp = @max(stamp, mtime(&st));
        } else |_| {}
    }
    return stamp;
}

test "manifest: names, main by platform, runtimes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try parseManifest(a, "{\"name\":\"hosts\",\"version\":\"1.0\",\"main\":\"main.py\",\"runtime\":\"python3\"}", "macos-aarch64");
    try std.testing.expectEqualStrings("main.py", m.main);
    try std.testing.expectEqualStrings("python3", m.runtime);
    const p = try parseManifest(a, "{\"name\":\"h\",\"main\":{\"macos-aarch64\":\"bin/m\",\"linux-x86_64\":\"bin/l\"}}", "linux-x86_64");
    try std.testing.expectEqualStrings("bin/l", p.main);
    try std.testing.expectError(error.NotForThisMachine, parseManifest(a, "{\"name\":\"h\",\"main\":{\"linux-x86_64\":\"l\"}}", "macos-aarch64"));
    try std.testing.expectError(error.BadName, parseManifest(a, "{\"name\":\"Hosts\",\"main\":\"m\"}", "x"));
    try std.testing.expectError(error.Reserved, parseManifest(a, "{\"name\":\"git\",\"main\":\"m\"}", "x"));
    try std.testing.expectError(error.BadMain, parseManifest(a, "{\"name\":\"h\",\"main\":\"../m\"}", "x"));
    try std.testing.expectError(error.BadManifest, parseManifest(a, "{\"name\":\"h\",\"main\":\"m\",\"runtime\":\"ruby\"}", "x"));
}

test "install from a folder, update, disable, uninstall" {
    var tmpl = "/tmp/gtty-exts-XXXXXX".*;
    const base = std.mem.span(c.mkdtemp(&tmpl) orelse return error.SkipZigTest);
    defer Tee.Dir.removeTree(tmpl[0..base.len :0]);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cmd: [1024]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&cmd,
        \\cd {s} && mkdir -p src/lib && printf '{{"name":"demo","version":"1","main":"run.sh"}}' > src/manifest.json &&
        \\printf '#!/bin/sh\n' > src/run.sh && chmod 755 src/run.sh && printf x > src/lib/a.txt
    , .{base}, 0);
    if (c.system(script.ptr) != 0) return error.SkipZigTest;
    // Not there yet, nor its parents: a first install on a new machine.
    const root = try std.fmt.allocPrint(a, "{s}/share/gtty/extensions", .{base});
    const src = try std.fmt.allocPrint(a, "{s}/src", .{base});
    try std.testing.expectEqualStrings("demo", try install(a, root, src));
    var list = try scan(a, root);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expect(list[0].enabled);
    try std.testing.expectEqualStrings("1", list[0].manifest.version);
    const run = try std.fmt.allocPrintSentinel(a, "{s}/run.sh", .{list[0].code}, 0);
    try std.testing.expect(c.access(run.ptr, c.X_OK) == 0);
    // Data stays through an update.
    const data = try std.fmt.allocPrintSentinel(a, "{s}/demo/data", .{root}, 0);
    _ = c.mkdir(data.ptr, 0o700);
    const s2 = try std.fmt.bufPrintSentinel(&cmd, "printf '{{\"name\":\"demo\",\"version\":\"2\",\"main\":\"run.sh\"}}' > {s}/src/manifest.json", .{base}, 0);
    _ = c.system(s2.ptr);
    _ = try install(a, root, src);
    list = try scan(a, root);
    try std.testing.expectEqualStrings("2", list[0].manifest.version);
    try std.testing.expect(c.access(data.ptr, c.F_OK) == 0);
    try setEnabled(a, root, "demo", false);
    try std.testing.expect(!(try scan(a, root))[0].enabled);
    try std.testing.expect(try uninstall(a, root, "demo"));
    try std.testing.expectEqual(@as(usize, 0), (try scan(a, root)).len);
    try std.testing.expect(!try uninstall(a, root, "demo"));
}

test "a package with one top folder" {
    var entries = [_]Archive.Entry{
        .{ .name = "hosts", .kind = .folder },
        .{ .name = "hosts/manifest.json", .kind = .file },
        .{ .name = "hosts/bin/x", .kind = .file },
    };
    const out = stripTop(&entries);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("manifest.json", out[0].name);
    try std.testing.expectEqualStrings("bin/x", out[1].name);
}
