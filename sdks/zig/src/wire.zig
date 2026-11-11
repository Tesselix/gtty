// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The JSON form of the SDK's types, for the protocol between gtty and an
//! extension running as its own program (docs/protocol.md). gtty reads
//! with `decode`, the Zig SDK writes with `encode`, so the two can't
//! disagree. Every other language's SDK writes the same JSON by hand.
//!
//! Rules, the same for every type:
//! - An update's `Field` left as `.keep` is left out, `.clear` is `null`.
//! - Other fields at their default are left out; left out = the default.
//! - A text is a string (one part, no attributes) or a list of parts
//!   `{"string", "fg": "#rrggbb", "bk", "size", "bold", "stroke"}`.
//! - A dialog widget's value is a string or a bool; `DialogUpdate.err` is
//!   the key `"error"` (a string, or null to clear it).
//! - Enums are their names.

const std = @import("std");
const sdk = @import("gtty.zig");

pub const Stringify = std.json.Stringify;
pub const Value = std.json.Value;

pub const DecodeError = error{ BadMessage, OutOfMemory };

fn isField(comptime T: type) bool {
    return @typeInfo(T) == .@"union" and @hasDecl(T, "Inner") and @hasField(T, "keep");
}

fn isDefault(comptime T: type, v: T, comptime default: ?*const anyopaque) bool {
    const d: *const T = @ptrCast(@alignCast(default orelse return false));
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => v == d.*,
        .optional => v == null and d.* == null,
        .pointer => |p| p.size == .slice and v.len == 0 and d.len == 0,
        .array => for (v) |x| {
            if (x != null) break false;
        } else true,
        else => if (T == sdk.Text) v.isEmpty() and d.isEmpty() else false,
    };
}

fn isNull(v: anytype) bool {
    return if (@typeInfo(@TypeOf(v)) == .optional) v == null else false;
}

/// `v` (any SDK type) as JSON.
pub fn encode(s: *Stringify, v: anytype) Stringify.Error!void {
    const T = @TypeOf(v);
    if (T == sdk.Text) return encodeText(s, v);
    if (T == sdk.Value) return switch (v) {
        .text => |t| s.write(t),
        .on => |b| s.write(b),
    };
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            try s.beginObject();
            inline for (st.fields) |f| {
                const fv = @field(v, f.name);
                const key = if (T == sdk.DialogUpdate and comptime std.mem.eql(u8, f.name, "err")) "error" else f.name;
                if (comptime isField(f.type)) {
                    switch (fv) {
                        .keep => {},
                        .clear => {
                            try s.objectField(key);
                            try s.write(null);
                        },
                        .set => |x| {
                            try s.objectField(key);
                            try encode(s, x);
                        },
                    }
                } else if (T == sdk.DialogUpdate and comptime std.mem.eql(u8, f.name, "err")) {
                    if (fv) |e| {
                        try s.objectField(key);
                        switch (e) {
                            .set => |m| try s.write(m),
                            .clear => try s.write(null),
                        }
                    }
                } else if (!isDefault(f.type, fv, f.default_value_ptr) and !isNull(fv)) {
                    try s.objectField(key);
                    try encode(s, fv);
                }
            }
            try s.endObject();
        },
        .optional => if (v) |x| try encode(s, x) else try s.write(null),
        .array => {
            try s.beginArray();
            for (v) |x| if (x) |b| try encode(s, b);
            try s.endArray();
        },
        .pointer => |p| {
            if (p.child == u8) return s.write(v);
            try s.beginArray();
            for (v) |x| try encode(s, x);
            try s.endArray();
        },
        .@"enum" => try s.write(@tagName(v)),
        else => try s.write(v),
    }
}

fn encodeText(s: *Stringify, t: sdk.Text) Stringify.Error!void {
    if (t.len == 1 and std.meta.eql(t.parts[0].attr, sdk.TextAttr{})) return s.write(t.parts[0].string);
    try s.beginArray();
    for (t.slice()) |p| {
        try s.beginObject();
        try s.objectField("string");
        try s.write(p.string);
        inline for (.{ "fg", "bk" }) |k| if (@field(p.attr, k)) |col| {
            try s.objectField(k);
            var buf: [7]u8 = undefined;
            try s.write(std.fmt.bufPrint(&buf, "#{x:0>6}", .{col}) catch unreachable);
        };
        if (p.attr.size) |n| {
            try s.objectField("size");
            try s.write(n);
        }
        if (p.attr.bold) {
            try s.objectField("bold");
            try s.write(true);
        }
        if (p.attr.stroke) {
            try s.objectField("stroke");
            try s.write(true);
        }
        try s.endObject();
    }
    try s.endArray();
}

/// A `T` from JSON; strings and lists are allocated in `a` (an arena).
pub fn decode(comptime T: type, a: std.mem.Allocator, v: Value) DecodeError!T {
    if (T == sdk.Text) return decodeText(a, v);
    if (T == sdk.Value) return switch (v) {
        .string => |t| .{ .text = t },
        .bool => |b| .{ .on = b },
        else => error.BadMessage,
    };
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            const obj = switch (v) {
                .object => |o| o,
                else => return error.BadMessage,
            };
            var out: T = undefined;
            inline for (st.fields) |f| {
                const key = if (T == sdk.DialogUpdate and comptime std.mem.eql(u8, f.name, "err")) "error" else f.name;
                const got = obj.get(key);
                if (comptime isField(f.type)) {
                    @field(out, f.name) = if (got) |x| switch (x) {
                        .null => .clear,
                        else => .{ .set = try decode(f.type.Inner, a, x) },
                    } else .keep;
                } else if (T == sdk.DialogUpdate and comptime std.mem.eql(u8, f.name, "err")) {
                    @field(out, f.name) = if (got) |x| switch (x) {
                        .null => .clear,
                        .string => |m| .{ .set = m },
                        else => return error.BadMessage,
                    } else null;
                } else if (got) |x| {
                    @field(out, f.name) = try decode(f.type, a, x);
                } else if (f.default_value_ptr) |d| {
                    @field(out, f.name) = @as(*const f.type, @ptrCast(@alignCast(d))).*;
                } else return error.BadMessage;
            }
            return out;
        },
        .optional => |o| return if (v == .null) null else try decode(o.child, a, v),
        .array => |ar| {
            var out: T = @splat(null);
            const items = switch (v) {
                .array => |x| x.items,
                else => return error.BadMessage,
            };
            for (items[0..@min(items.len, ar.len)], 0..) |x, i| out[i] = try decode(@typeInfo(ar.child).optional.child, a, x);
            return out;
        },
        .pointer => |p| {
            if (p.child == u8) return switch (v) {
                .string => |s| s,
                else => error.BadMessage,
            };
            const items = switch (v) {
                .array => |x| x.items,
                else => return error.BadMessage,
            };
            const out = try a.alloc(p.child, items.len);
            for (items, out) |x, *o| o.* = try decode(p.child, a, x);
            return out;
        },
        .@"enum" => return switch (v) {
            .string => |s| std.meta.stringToEnum(T, s) orelse error.BadMessage,
            else => error.BadMessage,
        },
        .bool => return switch (v) {
            .bool => |b| b,
            else => error.BadMessage,
        },
        .int => return switch (v) {
            .integer => |n| std.math.cast(T, n) orelse error.BadMessage,
            else => error.BadMessage,
        },
        else => @compileError("wire.decode: " ++ @typeName(T)),
    }
}

fn decodeText(a: std.mem.Allocator, v: Value) DecodeError!sdk.Text {
    _ = a;
    var t: sdk.Text = .{};
    switch (v) {
        .string => |s| {
            t.parts[0] = .{ .string = s };
            t.len = 1;
        },
        .array => |arr| for (arr.items) |x| {
            if (t.len == sdk.max_parts) break;
            const o = switch (x) {
                .object => |o| o,
                .string => |s| {
                    t.parts[t.len] = .{ .string = s };
                    t.len += 1;
                    continue;
                },
                else => return error.BadMessage,
            };
            var p: sdk.TextPart = .{};
            if (o.get("string")) |s| p.string = switch (s) {
                .string => |str| str,
                else => return error.BadMessage,
            };
            inline for (.{ "fg", "bk" }) |k| if (o.get(k)) |col| {
                @field(p.attr, k) = try color(col);
            };
            if (o.get("size")) |n| p.attr.size = switch (n) {
                .integer => |i| std.math.cast(u16, i) orelse return error.BadMessage,
                .null => null,
                else => return error.BadMessage,
            };
            inline for (.{ "bold", "stroke" }) |k| if (o.get(k)) |b| {
                @field(p.attr, k) = switch (b) {
                    .bool => |on| on,
                    else => return error.BadMessage,
                };
            };
            t.parts[t.len] = p;
            t.len += 1;
        },
        .null => {},
        else => return error.BadMessage,
    }
    return t;
}

/// "#rrggbb", or a number.
fn color(v: Value) DecodeError!?u24 {
    return switch (v) {
        .null => null,
        .integer => |n| std.math.cast(u24, n) orelse error.BadMessage,
        .string => |s| if (s.len == 7 and s[0] == '#') std.fmt.parseInt(u24, s[1..], 16) catch error.BadMessage else error.BadMessage,
        else => error.BadMessage,
    };
}

/// `v` encoded, into `buf`'s allocator.
pub fn toJson(gpa: std.mem.Allocator, v: anytype) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var s: Stringify = .{ .writer = &w.writer };
    try encode(&s, v);
    return w.toOwnedSlice();
}

fn roundTrip(comptime T: type, v: T) !T {
    const a = std.testing.allocator;
    const json = try toJson(a, v);
    defer a.free(json);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), json, .{});
    const back = try decode(T, arena.allocator(), parsed);
    // Encoded again it must read the same.
    const again = try toJson(a, back);
    defer a.free(again);
    try std.testing.expectEqualStrings(json, again);
    return v;
}

test "a chip update: kept fields left out, cleared ones null" {
    const a = std.testing.allocator;
    const u: sdk.ChipUpdate = .{ .text = .{ .set = sdk.newText("main") }, .data = .clear };
    const json = try toJson(a, u);
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"text\":\"main\",\"data\":null}", json);
    _ = try roundTrip(sdk.ChipUpdate, u);
}

test "a text with attributes" {
    const a = std.testing.allocator;
    const t = sdk.newText(.{ .{ "a", .{} }, .{ "b", .{ .fg = 0xe0b040, .bold = true, .size = 120 } } });
    const json = try toJson(a, t);
    defer a.free(json);
    try std.testing.expectEqualStrings("[{\"string\":\"a\"},{\"string\":\"b\",\"fg\":\"#e0b040\",\"size\":120,\"bold\":true}]", json);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const back = try decode(sdk.Text, arena.allocator(), try std.json.parseFromSliceLeaky(Value, arena.allocator(), json, .{}));
    try std.testing.expectEqual(@as(?u24, 0xe0b040), back.parts[1].attr.fg);
    try std.testing.expect(back.parts[1].attr.bold);
}

test "an epeek with a frame, lines and buttons" {
    var frame: sdk.Frame = .{ .text = sdk.newText("hosts"), .filter = .{ .hint = sdk.newText("filter"), .options = &.{ "a", "b" }, .onclick = "f" } };
    frame.right[0] = .{ .icon = "save", .onclick = "save" };
    const items = [_]sdk.Item{.{ .id = "x", .text = sdk.newText("X"), .data = "d" }};
    const lines = [_]sdk.Line{
        .{ .id = "1", .text = sdk.newText("one"), .postButton = .{ .dots = .vertical, .onclick = "m", .items = &items } },
        .{ .id = "2", .text = sdk.newText("two"), .onclick = "pick" },
    };
    _ = try roundTrip(sdk.EpeekUpdate, .{ .frame = .{ .set = frame }, .lines = .{ .set = &lines }, .state = .{ .set = .busy }, .message = .clear });
}

test "a dialog and a click with fields" {
    const ws = [_]sdk.Widget{
        .{ .id = "name", .type = .text, .label = sdk.newText("Name"), .value = .{ .text = "x" } },
        .{ .id = "keep", .type = .checkbox, .value = .{ .on = true } },
    };
    _ = try roundTrip(sdk.DialogUpdate, .{ .title = sdk.newText("Add"), .layout = .form, .fields = &ws, .buttons = .okcancel, .timeout = 30, .err = .{ .set = "taken" } });
    const fields = [_]sdk.FieldValue{ .{ .id = "name", .value = .{ .text = "a" } }, .{ .id = "keep", .value = .{ .on = false } } };
    _ = try roundTrip(sdk.Event, .{ .eventId = 3, .kind = .button_click, .button = .{ .id = "ok", .function = "add", .fields = &fields, .command = true } });
}

test "bad input is an error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{\"text\":5}", "{\"dimmed\":\"yes\"}", "[1]", "{\"text\":[{\"string\":\"a\",\"fg\":\"red\"}]}" }) |j| {
        const v = try std.json.parseFromSliceLeaky(Value, a, j, .{});
        try std.testing.expectError(error.BadMessage, decode(sdk.ChipUpdate, a, v));
    }
    const v = try std.json.parseFromSliceLeaky(Value, a, "{\"state\":\"sleepy\"}", .{});
    try std.testing.expectError(error.BadMessage, decode(sdk.EpeekUpdate, a, v));
}
