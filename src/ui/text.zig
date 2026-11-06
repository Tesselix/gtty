// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Draws the texts extensions set (`sdk.Text`): goes over the parts and
//! draws each string with its attributes; an attribute left out comes from
//! what the caller passes (the default for that text). Bold is struck
//! twice, a pixel apart: gtty embeds one face.

const std = @import("std");
const sdk = @import("gtty");
const Rgb = @import("../core/color.zig").Rgb;
const Gfx = @import("../render/Gfx.zig");

/// `size` is kept to this range (percent): rows have fixed heights.
const min_size = 50;
const max_size = 200;

fn faceOf(gfx: *Gfx, f: *Gfx.Face, a: sdk.TextAttr) *Gfx.Face {
    const size = a.size orelse return f;
    if (size == 100) return f;
    const px = @as(u32, f.px) * std.math.clamp(size, min_size, max_size) / 100;
    return gfx.face(@intCast(@max(px, 1))) catch f;
}

fn rgb(v: u24) Rgb {
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

pub fn width(gfx: *Gfx, f: *Gfx.Face, t: *const sdk.Text) f32 {
    var w: f32 = 0;
    for (t.slice()) |p| w += Gfx.textWidth(faceOf(gfx, f, p.attr), p.string);
    return w;
}

/// At `x`, in the row of face `f` starting at `y`; a smaller or larger
/// part stands on the same line. The x after the text.
pub fn draw(gfx: *Gfx, f: *Gfx.Face, x0: f32, y: f32, t: *const sdk.Text, fg: Rgb) f32 {
    var x = x0;
    for (t.slice()) |p| {
        const pf = faceOf(gfx, f, p.attr);
        const w = Gfx.textWidth(pf, p.string);
        const py = y + f.cell_h - pf.cell_h;
        if (p.attr.bk) |bk| gfx.fill(.{ .x = x, .y = py, .w = w, .h = pf.cell_h }, rgb(bk));
        const col = if (p.attr.fg) |v| rgb(v) else fg;
        _ = gfx.text(pf, x, py, p.string, col);
        if (p.attr.bold) _ = gfx.text(pf, x + 1, py, p.string, col);
        if (p.attr.stroke) gfx.fill(.{ .x = x, .y = py + @round(pf.cell_h * 0.52), .w = w, .h = @max(@round(pf.cell_h / 14), 1) }, col);
        x += w;
    }
    return x;
}

/// The first `n` bytes of `t` (a chip's text cut short).
pub fn cut(t: *const sdk.Text, n: usize) sdk.Text {
    var out: sdk.Text = .{};
    var left = n;
    for (t.slice()) |p| {
        if (left == 0) break;
        const k = @min(p.string.len, left);
        out.parts[out.len] = .{ .string = p.string[0..k], .attr = p.attr };
        out.len += 1;
        left -= k;
    }
    return out;
}

test "cut keeps the parts up to n bytes" {
    const t = sdk.newText(.{ .{ "ab", .{} }, .{ "cde", .{ .bold = true } } });
    const c = cut(&t, 3);
    try std.testing.expectEqual(@as(u8, 2), c.len);
    try std.testing.expectEqualStrings("c", c.parts[1].string);
    try std.testing.expect(c.parts[1].attr.bold);
    try std.testing.expectEqual(@as(u8, 1), cut(&t, 2).len);
}
