// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What one extension described for one job window: its peek and epeek
//! (the window owns one per chip). An update merges into what is there
//! and everything is copied, so the extension's strings can go at once.

const std = @import("std");
const sdk = @import("gtty");

const ChipUi = @This();

gpa: std.mem.Allocator,
peek: ?sdk.Peek = null,
epeek: ?sdk.Epeek = null,
peek_mem: ?*std.heap.ArenaAllocator = null,
epeek_mem: ?*std.heap.ArenaAllocator = null,
/// Bumped when `lines` are replaced (the selection starts over).
lines_seq: u32 = 0,
/// The chip's own click and hover functions, and its linked text.
onclick: []u8 = &.{},
onhover: []u8 = &.{},
data: []u8 = &.{},

pub fn deinit(u: *ChipUi) void {
    free(u.gpa, u.peek_mem);
    free(u.gpa, u.epeek_mem);
    u.gpa.free(u.onclick);
    u.gpa.free(u.onhover);
    u.gpa.free(u.data);
    u.* = .{ .gpa = u.gpa };
}

pub fn setChipFns(u: *ChipUi, update: sdk.ChipUpdate) !void {
    try u.replace(&u.onclick, update.onclick);
    try u.replace(&u.onhover, update.onhover);
    try u.replace(&u.data, update.data);
}

fn replace(u: *ChipUi, field: *[]u8, v: sdk.Field([]const u8)) !void {
    switch (v) {
        .keep => {},
        .clear => {
            u.gpa.free(field.*);
            field.* = &.{};
        },
        .set => |s| {
            const copy = try u.gpa.dupe(u8, s);
            u.gpa.free(field.*);
            field.* = copy;
        },
    }
}

fn free(gpa: std.mem.Allocator, mem: ?*std.heap.ArenaAllocator) void {
    const m = mem orelse return;
    m.deinit();
    gpa.destroy(m);
}

pub fn setPeek(u: *ChipUi, update: ?sdk.PeekUpdate) !void {
    const up = update orelse {
        free(u.gpa, u.peek_mem);
        u.peek_mem = null;
        u.peek = null;
        return;
    };
    const mem = try newArena(u.gpa);
    errdefer free(u.gpa, mem);
    const next = try deep(mem.allocator(), sdk.Peek, merge(sdk.Peek, u.peek orelse .{}, up));
    free(u.gpa, u.peek_mem);
    u.peek_mem = mem;
    u.peek = next;
}

pub fn setEpeek(u: *ChipUi, update: ?sdk.EpeekUpdate) !void {
    const up = update orelse {
        free(u.gpa, u.epeek_mem);
        u.epeek_mem = null;
        u.epeek = null;
        return;
    };
    const mem = try newArena(u.gpa);
    errdefer free(u.gpa, mem);
    const next = try deep(mem.allocator(), sdk.Epeek, merge(sdk.Epeek, u.epeek orelse .{}, up));
    free(u.gpa, u.epeek_mem);
    u.epeek_mem = mem;
    u.epeek = next;
    if (up.lines != .keep) u.lines_seq +%= 1;
}

/// A closed epeek's result doesn't show the next time.
pub fn clearResult(u: *ChipUi) void {
    if (u.epeek) |*e| {
        e.state = .idle;
        e.message = &.{};
    }
}

fn newArena(gpa: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const m = try gpa.create(std.heap.ArenaAllocator);
    m.* = .init(gpa);
    return m;
}

fn merge(comptime D: type, old: D, update: anytype) D {
    var d = old;
    const blank: D = .{};
    inline for (@typeInfo(@TypeOf(update)).@"struct".fields) |f| {
        switch (@field(update, f.name)) {
            .keep => {},
            .clear => @field(d, f.name) = @field(blank, f.name),
            .set => |v| @field(d, f.name) = v,
        }
    }
    return d;
}

/// `v` with every string and list copied into `a`.
fn deep(a: std.mem.Allocator, comptime T: type, v: T) !T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return v;
            const out = try a.alloc(p.child, v.len);
            for (v, out) |x, *o| o.* = try deep(a, p.child, x);
            return out;
        },
        .optional => |o| return if (v) |x| try deep(a, o.child, x) else null,
        .@"struct" => |s| {
            var out = v;
            inline for (s.fields) |f| @field(out, f.name) = try deep(a, f.type, @field(v, f.name));
            return out;
        },
        .array => |r| {
            var out = v;
            for (v, &out) |x, *o| o.* = try deep(a, r.child, x);
            return out;
        },
        else => return v,
    }
}

test "an update merges and copies; null clears" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    var name = "main".*;
    try u.setPeek(.{ .text = .{ .set = sdk.newText(@as([]const u8, &name)) }, .expand = .{ .set = true } });
    name[0] = 'X';
    try t.expectEqualStrings("main", u.peek.?.text.parts[0].string);
    try u.setPeek(.{ .onclick = .{ .set = "copy" } });
    try t.expectEqualStrings("main", u.peek.?.text.parts[0].string);
    try t.expect(u.peek.?.expand);
    try u.setPeek(.{ .onclick = .clear });
    try t.expectEqual(@as(usize, 0), u.peek.?.onclick.len);
    try u.setPeek(null);
    try t.expect(u.peek == null);
}

test "new lines start the selection over, other changes don't" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    const rows = [_]sdk.Line{.{ .text = sdk.newText("a"), .postButton = .{ .dots = .vertical, .items = &.{.{ .id = "x", .text = sdk.newText("X") }} } }};
    try u.setEpeek(.{ .lines = .{ .set = &rows } });
    try t.expectEqual(@as(u32, 1), u.lines_seq);
    try t.expectEqualStrings("x", u.epeek.?.lines[0].postButton.?.items[0].id);
    try u.setEpeek(.{ .state = .{ .set = .busy } });
    try t.expectEqual(@as(u32, 1), u.lines_seq);
    try t.expectEqual(@as(usize, 1), u.epeek.?.lines.len);
    u.clearResult();
    try t.expectEqual(sdk.State.idle, u.epeek.?.state);
}
