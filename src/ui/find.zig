// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Find in a job window (⌘F): which cells of a screen row are part of a
//! match of the text typed in the find box. Any case; a match may run over
//! rows that wrapped at the edge. Only from `min_len` characters on (one
//! letter would light up half the screen).

const std = @import("std");
const Screen = @import("../core/Screen.zig");

pub const min_len = 2;

/// Rows of a wrapped line looked at on each side of the row (longer
/// matches across more rows are not found).
const wrap_rows = 4;
const max_chars = 8192;

/// The same letter in any case (ASCII, Latin-1, Greek, Cyrillic).
pub fn fold(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z', 0xc0...0xd6, 0xd8...0xde, 0x391...0x3a9, 0x410...0x42f => cp + 0x20,
        0x400...0x40f => cp + 0x50,
        else => cp,
    };
}

/// Every match of `query` in `chars` (folded already): `hit[i]` set for
/// each character inside one (overlapping ones too). The number of
/// matches.
pub fn mark(chars: []const u21, query: []const u21, hit: []bool) usize {
    @memset(hit[0..chars.len], false);
    if (query.len < min_len or query.len > chars.len) return 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i + query.len <= chars.len) : (i += 1) {
        for (query, 0..) |q, k| {
            if (fold(chars[i + k]) != fold(q)) break;
        } else {
            @memset(hit[i..][0..query.len], true);
            n += 1;
        }
    }
    return n;
}

/// The cells of `row` inside a match of `query`: `cols[col]` set (cells
/// past `cols.len` are left out). The number of matches that start on the
/// row.
pub fn rowHits(s: *const Screen, row: usize, query: []const u21, cols: []bool) usize {
    @memset(cols, false);
    if (query.len < min_len or row >= s.lines.items.len) return 0;
    // The row's line: the rows before that wrapped into it, and the rows
    // it wraps onto.
    var first = row;
    while (first > 0 and row - first < wrap_rows and s.isWrapped(first - 1)) first -= 1;
    var last = row;
    while (last + 1 < s.lines.items.len and last - row < wrap_rows and s.isWrapped(last)) last += 1;

    var chars: [max_chars]u21 = undefined;
    var at: [max_chars]struct { row: u32, col: u16, wide: bool } = undefined;
    var hit: [max_chars]bool = undefined;
    var n: usize = 0;
    var r = first;
    while (r <= last) : (r += 1) {
        for (s.lines.items[r].items, 0..) |cell, col| {
            // A wide character's spacer and a pad are not characters.
            if (cell.cp == 0) continue;
            if (n == max_chars) break;
            chars[n] = cell.cp;
            at[n] = .{ .row = @intCast(r), .col = @intCast(@min(col, std.math.maxInt(u16))), .wide = cell.attrs.wide };
            n += 1;
        }
    }
    _ = mark(chars[0..n], query, &hit);
    var starts: usize = 0;
    for (0..n) |i| {
        if (!hit[i] or at[i].row != row) continue;
        if (startsAt(chars[0..n], i, query)) starts += 1;
        const c0: usize = at[i].col;
        const c1 = c0 + @as(usize, if (at[i].wide) 2 else 1);
        var col = c0;
        while (col < c1 and col < cols.len) : (col += 1) cols[col] = true;
    }
    return starts;
}

fn startsAt(chars: []const u21, i: usize, query: []const u21) bool {
    if (i + query.len > chars.len) return false;
    for (query, 0..) |q, k| if (fold(chars[i + k]) != fold(q)) return false;
    return true;
}

test "find marks every match, any case" {
    const t = std.testing;
    const text = [_]u21{ 'a', 'B', 'c', ' ', 'A', 'b', 'C', 'a', 'b' };
    var hit: [text.len]bool = undefined;
    const q = [_]u21{ 'a', 'b' };
    try t.expectEqual(@as(usize, 3), mark(&text, &q, &hit));
    try t.expectEqualSlices(bool, &.{ true, true, false, false, true, true, false, true, true }, &hit);
    // One letter: nothing yet.
    try t.expectEqual(@as(usize, 0), mark(&text, q[0..1], &hit));
    try t.expect(std.mem.indexOfScalar(bool, &hit, true) == null);
    // Overlapping matches.
    const aaa = [_]u21{ 'a', 'a', 'a' };
    var h3: [3]bool = undefined;
    try t.expectEqual(@as(usize, 2), mark(&aaa, &.{ 'A', 'A' }, &h3));
    try t.expectEqualSlices(bool, &.{ true, true, true }, &h3);
    try t.expectEqual(@as(u21, 0xe9), fold(0xc9)); // É → é
    try t.expectEqual(@as(u21, 0x431), fold(0x411)); // Б → б
}
