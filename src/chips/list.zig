// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What the standard chips share: their state per window, and the look of
//! their lists.

const std = @import("std");
const sdk = @import("gtty");
const hooks = @import("hooks.zig");

/// The theme's green and blue, for what a list marks.
pub const green: u24 = 0x98c379;
pub const blue: u24 = 0x5aa9ff;

/// `S` per window, made at first use, gone with `drop`. `S.deinit` frees it.
pub fn PerWindow(comptime S: type) type {
    return struct {
        map: std.AutoHashMapUnmanaged(u32, *S) = .empty,

        const Self = @This();

        pub fn of(m: *Self, uid: u32) !*S {
            const gpa = hooks.gpa;
            if (m.map.get(uid)) |s| return s;
            const s = try gpa.create(S);
            errdefer gpa.destroy(s);
            s.* = .{};
            try m.map.put(gpa, uid, s);
            return s;
        }

        pub fn drop(m: *Self, uid: u32) void {
            const kv = m.map.fetchRemove(uid) orelse return;
            kv.value.deinit();
            hooks.gpa.destroy(kv.value);
        }
    };
}

/// A string kept by a chip.
pub const Owned = struct {
    s: []u8 = &.{},

    pub fn set(o: *Owned, v: []const u8) void {
        const copy = hooks.gpa.dupe(u8, v) catch return;
        hooks.gpa.free(o.s);
        o.s = copy;
    }
    pub fn deinit(o: *Owned) void {
        hooks.gpa.free(o.s);
        o.* = .{};
    }
};

/// Does `name` fit what is typed in the filter? Any case.
pub fn matches(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.ascii.indexOfIgnoreCase(name, filter) != null;
}

/// The current one of a list: a green dot, green text.
pub fn currentLine(line: *sdk.Line, text: []const u8) void {
    line.prefixButton = .{ .icon = "dot" };
    line.text = sdk.newText(.{ text, .{ .fg = green } });
}

/// One row, for a `message`.
pub fn oneRow(buf: *[1]sdk.Text, text: []const u8) []const sdk.Text {
    buf[0] = sdk.newText(text);
    return buf;
}

test "matches: any case, anywhere" {
    try std.testing.expect(matches("feature/Login", "LOG"));
    try std.testing.expect(matches("x", ""));
    try std.testing.expect(!matches("main", "dev"));
}
