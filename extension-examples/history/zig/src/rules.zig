// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Which commands are kept, and the file (pure, tested below with
//! ../cases.tsv). See ../README.md.

const std = @import("std");

/// Commands kept, the ones used last.
pub const keep = 500;

/// Never kept: the look-arounds, in any part of the line.
const excluded = [_][]const u8{ "cd", "pushd", "popd", "ls", "ll", "la", "l", "lsd", "exa", "eza", "gls", "dir", "vdir", "find" };
/// Skipped in front of the command, with their own options.
const wrappers = [_][]const u8{ "sudo", "doas", "env", "time", "nohup", "nice", "command", "builtin", "exec" };
const separators = "|&;\n()";

fn oneOf(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

/// Wrapper options that take the next word.
fn takesArg(wrapper: []const u8, opt: []const u8) bool {
    if (std.mem.eql(u8, wrapper, "sudo")) return oneOf(opt, &.{ "-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U" });
    if (std.mem.eql(u8, wrapper, "doas")) return oneOf(opt, &.{ "-u", "-C" });
    if (std.mem.eql(u8, wrapper, "env")) return oneOf(opt, &.{ "-u", "-C", "-S", "-P" });
    if (std.mem.eql(u8, wrapper, "nice")) return oneOf(opt, &.{"-n"});
    return false;
}

fn isFlag(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '-' and !std.mem.eql(u8, raw, "--");
}

fn isAssignment(raw: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return false;
    if (eq == 0 or std.ascii.isDigit(raw[0])) return false;
    for (raw[0..eq]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn baseName(s: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| s[i + 1 ..] else s;
}

/// Follows one line's words, part by part.
const Judge = struct {
    found: bool = false, // the part's command seen
    wrapper: ?[]const u8 = null, // its options are being skipped
    skip: bool = false, // the word after such an option
    flagged: bool = false,
    dropped: bool = false,

    /// `raw` as typed; `val` without quotes and backslashes.
    fn word(j: *Judge, raw: []const u8, val: []const u8) void {
        if (j.found) {
            if (isFlag(raw)) j.flagged = true;
            return;
        }
        if (j.skip) {
            j.skip = false;
            return;
        }
        if (j.wrapper) |w| if (isFlag(raw)) {
            j.skip = takesArg(w, raw);
            return;
        };
        j.wrapper = null;
        if (isAssignment(raw)) return;
        const name = baseName(val);
        for (wrappers) |w| if (std.mem.eql(u8, name, w)) {
            j.wrapper = w;
            return;
        };
        j.found = true;
        if (oneOf(name, &excluded)) j.dropped = true;
    }

    fn part(j: *Judge) void {
        j.found = false;
        j.wrapper = null;
        j.skip = false;
    }
};

/// Is this command line worth keeping?
pub fn worth(line: []const u8) bool {
    if (std.mem.trim(u8, line, " \t\r\n").len == 0 or line[0] == ' ' or line[0] == '\t') return false;
    var j: Judge = .{};
    var val: [4096]u8 = undefined; // only its name is compared: a longer word is cut
    var vn: usize = 0;
    var start: usize = 0;
    var in_word = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        var add: ?u8 = null;
        if (quote != 0) {
            if (ch == quote) {
                quote = 0;
            } else if (ch == '\\' and quote == '"' and i + 1 < line.len) {
                i += 1;
                add = line[i];
            } else add = ch;
        } else if (ch == '\'' or ch == '"') {
            if (!in_word) start = i;
            quote = ch;
            in_word = true;
        } else if (ch == '\\' and i + 1 < line.len) {
            if (!in_word) start = i;
            i += 1;
            if (line[i] != '\n') add = line[i];
            in_word = true;
        } else if (ch == ' ' or ch == '\t' or std.mem.indexOfScalar(u8, separators, ch) != null) {
            if (in_word) {
                j.word(line[start..i], val[0..vn]);
                vn = 0;
                in_word = false;
            }
            if (std.mem.indexOfScalar(u8, separators, ch) != null) j.part();
            if (j.dropped) return false;
            continue;
        } else {
            if (!in_word) start = i;
            add = ch;
            in_word = true;
        }
        if (add) |a| if (vn < val.len) {
            val[vn] = a;
            vn += 1;
        };
    }
    if (in_word) j.word(line[start..], val[0..vn]);
    return !j.dropped and j.flagged;
}

/// One kept command; `cmd` is owned by the list.
pub const Entry = struct { count: u32, last: i64, cmd: []u8 };
pub const List = std.ArrayList(Entry);

fn byUse(_: void, a: Entry, b: Entry) bool {
    return if (a.last != b.last) a.last < b.last else a.count < b.count;
}

pub fn free(gpa: std.mem.Allocator, list: *List) void {
    for (list.items) |e| gpa.free(e.cmd);
    list.deinit(gpa);
}

/// The file's lines `count<TAB>last<TAB>command`, oldest use first.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !List {
    var list: List = .empty;
    errdefer free(gpa, &list);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const n = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
        const last = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue;
        if (last < 0 or f.index == null) continue; // no third field
        const cmd = try unescape(gpa, f.rest());
        errdefer gpa.free(cmd);
        try list.append(gpa, .{ .count = n, .last = last, .cmd = cmd });
    }
    std.mem.sort(Entry, list.items, {}, byUse);
    return list;
}

fn unescape(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, s.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var ch = s[i];
        if (ch == '\\' and i + 1 < s.len) {
            i += 1;
            ch = switch (s[i]) {
                't' => '\t',
                'n' => '\n',
                'r' => '\r',
                else => s[i],
            };
        }
        out[n] = ch;
        n += 1;
    }
    return gpa.realloc(out, n);
}

pub fn format(gpa: std.mem.Allocator, list: []const Entry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (list) |e| {
        try out.print(gpa, "{d}\t{d}\t", .{ e.count, e.last });
        for (e.cmd) |ch| switch (ch) {
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            else => try out.append(gpa, ch),
        };
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// One more use of `cmd`; keeps the `keep` used last.
pub fn record(gpa: std.mem.Allocator, list: *List, cmd: []const u8, now: i64) !void {
    for (list.items) |*e| {
        if (!std.mem.eql(u8, e.cmd, cmd)) continue;
        e.count += 1;
        e.last = @max(e.last, now);
        break;
    } else {
        const own = try gpa.dupe(u8, cmd);
        errdefer gpa.free(own);
        try list.append(gpa, .{ .count = 1, .last = now, .cmd = own });
    }
    std.mem.sort(Entry, list.items, {}, byUse);
    if (list.items.len > keep) {
        const drop = list.items.len - keep;
        for (list.items[0..drop]) |e| gpa.free(e.cmd);
        std.mem.copyForwards(Entry, list.items, list.items[drop..]);
        list.shrinkRetainingCapacity(keep);
    }
}

/// Drops `cmd` from the list.
pub fn forget(gpa: std.mem.Allocator, list: *List, cmd: []const u8) void {
    for (list.items, 0..) |e, i| if (std.mem.eql(u8, e.cmd, cmd)) {
        gpa.free(e.cmd);
        _ = list.orderedRemove(i);
        return;
    };
}

const t = std.testing;

test "the cases" {
    const cases = @embedFile("cases");
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, cases, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t').?;
        // \n, \t and \s: a line break, a tab, a blank.
        const a = try std.mem.replaceOwned(u8, t.allocator, line[tab + 1 ..], "\\n", "\n");
        defer t.allocator.free(a);
        const b = try std.mem.replaceOwned(u8, t.allocator, a, "\\t", "\t");
        defer t.allocator.free(b);
        const cmd = try std.mem.replaceOwned(u8, t.allocator, b, "\\s", " ");
        defer t.allocator.free(cmd);
        const want = std.mem.eql(u8, line[0..tab], "keep");
        if (worth(cmd) != want) {
            std.debug.print("worth(\"{s}\") should be {}\n", .{ cmd, want });
            return error.TestUnexpectedResult;
        }
        n += 1;
    }
    try t.expect(n > 30);
}

test "the file round trip" {
    var a = try parse(t.allocator, "1\t10\ta -x\n3\t20\tprintf -v x 'a\\tb\\\\n'\\necho -n done\n");
    defer free(t.allocator, &a);
    try t.expectEqual(2, a.items.len);
    try t.expectEqualStrings("printf -v x 'a\tb\\n'\necho -n done", a.items[1].cmd);
    const text = try format(t.allocator, a.items);
    defer t.allocator.free(text);
    try t.expectEqualStrings("1\t10\ta -x\n3\t20\tprintf -v x 'a\\tb\\\\n'\\necho -n done\n", text);
}

test "bad lines skipped" {
    var a = try parse(t.allocator, "x\t1\ta\n2\t5\tb -c\n\n");
    defer free(t.allocator, &a);
    try t.expectEqual(1, a.items.len);
    try t.expectEqualStrings("b -c", a.items[0].cmd);
}

test "record" {
    var a: List = .empty;
    defer free(t.allocator, &a);
    try record(t.allocator, &a, "a -x", 10);
    try record(t.allocator, &a, "b -y", 11);
    try record(t.allocator, &a, "a -x", 12);
    try t.expectEqual(2, a.items.len);
    try t.expectEqualStrings("b -y", a.items[0].cmd);
    try t.expectEqual(2, a.items[1].count);
    try t.expectEqual(12, a.items[1].last);
}

test "keeps the used last" {
    var a: List = .empty;
    defer free(t.allocator, &a);
    var buf: [16]u8 = undefined;
    for (0..keep + 5) |i| try record(t.allocator, &a, try std.fmt.bufPrint(&buf, "c -{d}", .{i}), @intCast(i));
    try t.expectEqual(keep, a.items.len);
    try t.expectEqualStrings("c -5", a.items[0].cmd);
}
