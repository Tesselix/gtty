// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The entries of an extension's package, read from memory: zip (stored or
//! deflated), tar, or gzip-compressed tar. Only plain files and folders:
//! a link, a device, an absolute name or one with `..` refuses the whole
//! package, so nothing can be written outside the folder it is unpacked in
//! (std.tar's own extract would create links). Unit-tested.

const std = @import("std");

pub const Error = error{ BadArchive, Unsafe, TooBig, OutOfMemory };

/// The limits of one package.
pub const max_total = 256 * 1024 * 1024;
pub const max_entries = 20000;

pub const Entry = struct {
    /// A relative path with `/`, no `.` or `..` parts.
    name: []const u8,
    kind: enum { file, folder },
    /// Executable (any x bit).
    exec: bool = false,
    data: []const u8 = "",
};

/// The entries, allocated in `a` (an arena); `bytes` must outlive them.
pub fn read(a: std.mem.Allocator, bytes: []const u8) Error![]Entry {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "PK\x03\x04")) return readZip(a, bytes);
    if (bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b) {
        var in: std.Io.Reader = .fixed(bytes);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var d: std.compress.flate.Decompress = .init(&in, .gzip, &window);
        const tar = d.reader.allocRemaining(a, .limited(max_total)) catch |e| return switch (e) {
            error.StreamTooLong => error.TooBig,
            error.OutOfMemory => error.OutOfMemory,
            else => error.BadArchive,
        };
        return readTar(a, tar);
    }
    return readTar(a, bytes);
}

/// A safe relative name, `/`-separated, trailing `/` dropped; null: unsafe.
pub fn cleanName(name: []const u8) ?[]const u8 {
    var n = std.mem.trimEnd(u8, name, "/");
    while (std.mem.startsWith(u8, n, "./")) n = n[2..];
    if (n.len == 0 or n[0] == '/' or std.mem.indexOfScalar(u8, n, '\\') != null or std.mem.indexOfScalar(u8, n, 0) != null) return null;
    var it = std.mem.splitScalar(u8, n, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
    return n;
}

fn add(a: std.mem.Allocator, list: *std.ArrayList(Entry), total: *usize, e: Entry) Error!void {
    if (list.items.len >= max_entries) return error.TooBig;
    total.* += e.data.len;
    if (total.* > max_total) return error.TooBig;
    try list.append(a, e);
}

fn readTar(a: std.mem.Allocator, bytes: []const u8) Error![]Entry {
    var in: std.Io.Reader = .fixed(bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var list: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    while (it.next() catch return error.BadArchive) |f| {
        // A tar's top folder ("./") is fine; skip it.
        if (std.mem.eql(u8, std.mem.trimEnd(u8, f.name, "/"), ".")) continue;
        const name = cleanName(f.name) orelse return error.Unsafe;
        switch (f.kind) {
            .sym_link => return error.Unsafe,
            .directory => try add(a, &list, &total, .{ .name = try a.dupe(u8, name), .kind = .folder }),
            .file => {
                if (f.size > max_total) return error.TooBig;
                const data = in.take(@intCast(f.size)) catch return error.BadArchive;
                it.unread_file_bytes = 0;
                try add(a, &list, &total, .{ .name = try a.dupe(u8, name), .kind = .file, .exec = f.mode & 0o111 != 0, .data = data });
            },
        }
    }
    return list.items;
}

fn le16(b: []const u8, at: usize) Error!u16 {
    if (at + 2 > b.len) return error.BadArchive;
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) Error!u32 {
    if (at + 4 > b.len) return error.BadArchive;
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn readZip(a: std.mem.Allocator, b: []const u8) Error![]Entry {
    // The end record: the last "PK\x05\x06" (a comment may follow it).
    if (b.len < 22) return error.BadArchive;
    var eocd: usize = b.len - 22;
    while (true) {
        if (std.mem.eql(u8, b[eocd..][0..4], "PK\x05\x06")) break;
        if (eocd == 0 or b.len - eocd > 22 + 65535) return error.BadArchive;
        eocd -= 1;
    }
    const count = try le16(b, eocd + 10);
    var at: usize = try le32(b, eocd + 16);
    if (count == 0xffff or at == 0xffffffff) return error.BadArchive; // zip64
    var list: std.ArrayList(Entry) = .empty;
    var total: usize = 0;
    for (0..count) |_| {
        if (try le32(b, at) != 0x02014b50) return error.BadArchive;
        const method = try le16(b, at + 10);
        const csize = try le32(b, at + 20);
        const usize_ = try le32(b, at + 24);
        const nlen = try le16(b, at + 28);
        const xlen = try le16(b, at + 30);
        const clen = try le16(b, at + 32);
        const attrs = try le32(b, at + 38);
        const local = try le32(b, at + 42);
        if (at + 46 + nlen > b.len) return error.BadArchive;
        const raw_name = b[at + 46 ..][0..nlen];
        at += 46 + @as(usize, nlen) + xlen + clen;
        const mode: u32 = attrs >> 16;
        const ftype = mode & 0o170000;
        if (ftype != 0 and ftype != 0o100000 and ftype != 0o040000) return error.Unsafe; // links, devices
        if (std.mem.eql(u8, std.mem.trimEnd(u8, raw_name, "/"), ".")) continue;
        const name = cleanName(raw_name) orelse return error.Unsafe;
        const is_dir = raw_name[raw_name.len - 1] == '/' or ftype == 0o040000;
        if (is_dir) {
            try add(a, &list, &total, .{ .name = try a.dupe(u8, name), .kind = .folder });
            continue;
        }
        if (usize_ > max_total) return error.TooBig;
        if (try le32(b, local) != 0x04034b50) return error.BadArchive;
        const start = local + 30 + @as(usize, try le16(b, local + 26)) + try le16(b, local + 28);
        if (start + csize > b.len) return error.BadArchive;
        const comp = b[start..][0..csize];
        const data = switch (method) {
            0 => comp,
            8 => blk: {
                var in: std.Io.Reader = .fixed(comp);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&in, .raw, &window);
                const out = d.reader.allocRemaining(a, .limited(@as(usize, usize_) + 1)) catch return error.BadArchive;
                if (out.len != usize_) return error.BadArchive;
                break :blk out;
            },
            else => return error.BadArchive,
        };
        try add(a, &list, &total, .{ .name = try a.dupe(u8, name), .kind = .file, .exec = mode & 0o111 != 0, .data = data });
    }
    return list.items;
}

test "names: plain ones pass, escapes don't" {
    try std.testing.expectEqualStrings("a/b.py", cleanName("./a/b.py").?);
    try std.testing.expectEqualStrings("bin", cleanName("bin/").?);
    for ([_][]const u8{ "", "/etc/passwd", "../x", "a/../../x", "a//b", "a/./b", "a\\b" }) |n| try std.testing.expect(cleanName(n) == null);
}

test "a tar and a tar.gz from the system's tar, and a zip" {
    const c = @import("../c.zig").c;
    var tmpl = "/tmp/gtty-arc-XXXXXX".*;
    const dir = std.mem.span(c.mkdtemp(&tmpl) orelse return error.SkipZigTest);
    defer @import("Tee.zig").Dir.removeTree(tmpl[0..dir.len :0]);
    var cmd: [1024]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(&cmd,
        \\cd {s} && mkdir -p ext/bin && printf '{{"name":"x"}}' > ext/manifest.json && printf 'run' > ext/bin/run && chmod 755 ext/bin/run &&
        \\(cd ext && tar -cf ../x.tar . && tar -czf ../x.tgz . && (command -v zip >/dev/null && zip -qr ../x.zip . || true)) &&
        \\ln -s /etc/passwd ext/evil && (cd ext && tar -cf ../evil.tar .)
    , .{dir}, 0);
    if (c.system(script.ptr) != 0) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "x.tar", "x.tgz", "x.zip" }) |name| {
        var pbuf: [512]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&pbuf, "{s}/{s}", .{ dir, name }, 0);
        const bytes = readFile(a, path) orelse continue; // no zip tool
        const entries = try read(a, bytes);
        var saw_run = false;
        var saw_manifest = false;
        for (entries) |e| {
            if (std.mem.eql(u8, e.name, "bin/run")) {
                saw_run = true;
                try std.testing.expect(e.exec);
                try std.testing.expectEqualStrings("run", e.data);
            }
            if (std.mem.eql(u8, e.name, "manifest.json")) {
                saw_manifest = true;
                try std.testing.expect(!e.exec);
            }
        }
        try std.testing.expect(saw_run and saw_manifest);
    }
    var pbuf: [512]u8 = undefined;
    const evil = try std.fmt.bufPrintSentinel(&pbuf, "{s}/evil.tar", .{dir}, 0);
    try std.testing.expectError(error.Unsafe, read(a, readFile(a, evil).?));
}

fn readFile(a: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const c = @import("../c.zig").c;
    const f = c.fopen(path.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch return null;
    }
    return out.items;
}
