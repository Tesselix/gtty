// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Drawing helpers on top of SDL_Renderer: filled/outlined rects in pixel
//! coordinates and a monospace glyph cache per font size.
//!
//! Characters gtty's own font (JetBrains Mono) lacks come from the
//! system's fonts (`fallback_fonts`, opened the first time one is needed):
//! symbol fonts first, the color emoji font last. Emoji (wide characters,
//! or any with the emoji selector U+FE0F) try the emoji font first and
//! are drawn as color images, fitted into their cells.
//!
//! Everything is in physical pixels, so window borders and chrome are not
//! tied to the character grid. Text cells are placed on the grid of the
//! pane that draws them.
//!
//! SDL picks the GPU backend itself: Metal on macOS, OpenGL/Vulkan on Linux.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const Rgb = @import("../core/color.zig").Rgb;
const wcwidth = @import("../core/wcwidth.zig");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn contains(r: Rect, px: f32, py: f32) bool {
        return px >= r.x and py >= r.y and px < r.x + r.w and py < r.y + r.h;
    }
    pub fn inset(r: Rect, d: f32) Rect {
        return .{ .x = r.x + d, .y = r.y + d, .w = @max(r.w - 2 * d, 0), .h = @max(r.h - 2 * d, 0) };
    }
    fn sdl(r: Rect) c.SDL_FRect {
        return .{ .x = @round(r.x), .y = @round(r.y), .w = @round(r.w), .h = @round(r.h) };
    }
};

const font_data = @embedFile("../assets/JetBrainsMono-Regular.ttf");
/// The other faces of gtty's font, by `Style` - 1: bold, italic, bold
/// italic (opened per size when first needed).
const style_data = [3][]const u8{
    @embedFile("../assets/JetBrainsMono-Bold.ttf"),
    @embedFile("../assets/JetBrainsMono-Italic.ttf"),
    @embedFile("../assets/JetBrainsMono-BoldItalic.ttf"),
};

/// A text style: bit 0 bold, bit 1 italic (0 = regular).
pub const Style = u2;

pub fn style(bold: bool, italic: bool) Style {
    return @as(Style, @intFromBool(bold)) | (@as(Style, @intFromBool(italic)) << 1);
}

pub const Glyph = struct {
    tex: *c.SDL_Texture,
    w: f32,
    h: f32,
    /// A color image (emoji): drawn as it is, not in the text color.
    color: bool = false,
    /// From a fallback font: centered in its cells (its metrics differ).
    fallback: bool = false,
    /// The part of the texture drawn (a color glyph is cut to its visible
    /// pixels, so every emoji fills its cells alike); null = all of it.
    src: ?c.SDL_FRect = null,
};

/// A system font for characters gtty's own font lacks: the first of
/// `paths` that exists.
const FallbackFont = struct { paths: []const [:0]const u8, color: bool = false };

const fallback_fonts: []const FallbackFont = switch (builtin.os.tag) {
    .macos => &.{
        .{ .paths = &.{"/System/Library/Fonts/Menlo.ttc"} },
        .{ .paths = &.{"/System/Library/Fonts/Apple Symbols.ttf"} },
        .{ .paths = &.{"/System/Library/Fonts/Supplemental/Arial Unicode.ttf"} },
        .{ .paths = &.{"/System/Library/Fonts/Apple Color Emoji.ttc"}, .color = true },
    },
    // Debian / Ubuntu, Fedora, Arch paths; fontconfig (fc-match) when none.
    else => &.{
        .{ .paths = &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf", "/usr/share/fonts/TTF/DejaVuSansMono.ttf", "/usr/share/fonts/dejavu/DejaVuSansMono.ttf" } },
        .{ .paths = &.{ "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf" } },
        .{ .paths = &.{ "/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf", "/usr/share/fonts/google-noto/NotoSansSymbols2-Regular.ttf", "/usr/share/fonts/noto/NotoSansSymbols2-Regular.ttf" } },
        .{ .paths = &.{ "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc" } },
        .{ .paths = &.{ "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf", "/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf", "/usr/share/fonts/noto/NotoColorEmoji.ttf", "/usr/share/fonts/noto-emoji/NotoColorEmoji.ttf", "/usr/share/fonts/TTF/NotoColorEmoji.ttf" }, .color = true },
    },
};

/// fontconfig patterns asked (Linux) when none of a kind was found.
const fc_patterns = [_]struct { pattern: [:0]const u8, color: bool }{
    .{ .pattern = "monospace", .color = false },
    .{ .pattern = "emoji:color=true", .color = true },
};

const max_fallbacks = 8;

/// A fallback font found on this system.
const Fallback = struct { path: [:0]u8, color: bool };

pub const Face = struct {
    font: *c.TTF_Font,
    px: u16,
    cell_w: f32,
    cell_h: f32,
    /// Key: code point, plus 1 << 21 when an emoji glyph was asked for.
    glyphs: std.AutoHashMapUnmanaged(u32, ?Glyph) = .empty,
    /// The fallback fonts at this size, opened when first needed.
    fallback: [max_fallbacks]?*c.TTF_Font = @splat(null),
    tried: [max_fallbacks]bool = @splat(false),
    /// gtty's bold / italic / bold italic faces at this size (`style_data`).
    styled: [3]?*c.TTF_Font = @splat(null),
    styled_tried: [3]bool = @splat(false),
};

const Gfx = @This();

gpa: std.mem.Allocator,
renderer: *c.SDL_Renderer,
faces: std.AutoHashMapUnmanaged(u16, *Face) = .empty,
fallbacks: std.ArrayList(Fallback) = .empty,

pub fn init(gpa: std.mem.Allocator, renderer: *c.SDL_Renderer) !Gfx {
    if (!c.TTF_Init()) return error.TtfInit;
    var g: Gfx = .{ .gpa = gpa, .renderer = renderer };
    g.findFallbacks();
    return g;
}

/// Which fallback fonts this system has (paths only; nothing is opened).
fn findFallbacks(g: *Gfx) void {
    var have_color = false;
    for (fallback_fonts) |ff| for (ff.paths) |path| {
        if (c.access(path.ptr, c.R_OK) != 0) continue;
        g.addFallback(path, ff.color);
        have_color = have_color or ff.color;
        break;
    };
    if (builtin.os.tag == .macos) return;
    for (fc_patterns) |fp| {
        if (fp.color and have_color) continue;
        var buf: [1024]u8 = undefined;
        if (fcMatch(fp.pattern, &buf)) |path| g.addFallback(path, fp.color);
    }
}

fn addFallback(g: *Gfx, path: []const u8, is_color: bool) void {
    if (g.fallbacks.items.len == max_fallbacks) return;
    for (g.fallbacks.items) |f| if (std.mem.eql(u8, f.path, path)) return;
    const z = g.gpa.dupeZ(u8, path) catch return;
    g.fallbacks.append(g.gpa, .{ .path = z, .color = is_color }) catch g.gpa.free(z);
}

/// The font file fontconfig picks for `pattern` (`fc-match`), if any.
fn fcMatch(pattern: [:0]const u8, buf: []u8) ?[]const u8 {
    var cmd: [256]u8 = undefined;
    const sh = std.fmt.bufPrintSentinel(&cmd, "fc-match -f '%{{file}}' '{s}' 2>/dev/null", .{pattern}, 0) catch return null;
    const p = c.popen(sh.ptr, "r") orelse return null;
    const n = c.fread(buf.ptr, 1, buf.len, p);
    _ = c.pclose(p);
    const path = std.mem.trim(u8, buf[0..n], " \n");
    if (path.len == 0 or path[0] != '/') return null;
    return path;
}

pub fn deinit(g: *Gfx) void {
    var it = g.faces.valueIterator();
    while (it.next()) |fp| {
        const f = fp.*;
        var git = f.glyphs.valueIterator();
        while (git.next()) |gl| if (gl.*) |gly| c.SDL_DestroyTexture(gly.tex);
        f.glyphs.deinit(g.gpa);
        for (f.fallback) |fb| if (fb) |font| c.TTF_CloseFont(font);
        for (f.styled) |sf| if (sf) |font| c.TTF_CloseFont(font);
        c.TTF_CloseFont(f.font);
        g.gpa.destroy(f);
    }
    g.faces.deinit(g.gpa);
    for (g.fallbacks.items) |f| g.gpa.free(f.path);
    g.fallbacks.deinit(g.gpa);
    c.TTF_Quit();
}

/// Font face at a pixel size (cached). Window zoom and HiDPI scale both
/// end up here as a different pixel size, so text is always rasterized
/// sharp instead of being stretched.
pub fn face(g: *Gfx, px_in: u16) !*Face {
    const px = std.math.clamp(px_in, 6, 96);
    if (g.faces.get(px)) |f| return f;
    const io = c.SDL_IOFromConstMem(font_data.ptr, font_data.len) orelse return error.FontIo;
    const font = c.TTF_OpenFontIO(io, true, @floatFromInt(px)) orelse return error.FontOpen;
    c.TTF_SetFontHinting(font, c.TTF_HINTING_LIGHT);
    var adv: c_int = 0;
    _ = c.TTF_GetGlyphMetrics(font, 'M', null, null, null, null, &adv);
    const f = try g.gpa.create(Face);
    f.* = .{
        .font = font,
        .px = px,
        .cell_w = @floatFromInt(@max(adv, 1)),
        .cell_h = @floatFromInt(@max(c.TTF_GetFontHeight(font), 1)),
    };
    try g.faces.put(g.gpa, px, f);
    return f;
}

/// gtty's font in `st` at `f`'s size (null: regular, or it can't open).
fn styledFont(f: *Face, st: Style) ?*c.TTF_Font {
    if (st == 0) return null;
    const i = st - 1;
    if (!f.styled_tried[i]) {
        f.styled_tried[i] = true;
        const data = style_data[i];
        if (c.SDL_IOFromConstMem(data.ptr, data.len)) |io| {
            f.styled[i] = c.TTF_OpenFontIO(io, true, @floatFromInt(f.px));
            if (f.styled[i]) |font| c.TTF_SetFontHinting(font, c.TTF_HINTING_LIGHT);
        }
    }
    return f.styled[i];
}

/// The glyph for `cp` (cached): from gtty's font (in style `st` when it
/// has the character), else the first fallback font that has it, else a
/// '?'. `emoji`: the color emoji font first (no style).
fn glyph(g: *Gfx, f: *Face, cp: u21, emoji: bool, st: Style) ?Glyph {
    const s: Style = if (emoji) 0 else st;
    const key: u32 = @as(u32, cp) | (@as(u32, @intFromBool(emoji)) << 21) | (@as(u32, s) << 22);
    if (f.glyphs.get(key)) |gl| return gl;
    var result: ?Glyph = null;
    if (emoji) result = g.fromFallbacks(f, cp, true);
    if (result == null) if (styledFont(f, s)) |font| {
        if (c.TTF_FontHasGlyph(font, cp)) result = g.render(font, cp, false, false);
    };
    if (result == null and c.TTF_FontHasGlyph(f.font, cp)) result = g.render(f.font, cp, false, false);
    if (result == null) result = g.fromFallbacks(f, cp, false);
    if (result == null) result = g.render(f.font, '?', false, false);
    f.glyphs.put(g.gpa, key, result) catch {};
    return result;
}

/// `cp` from the fallback fonts, in order (`color_only`: just the emoji
/// font).
fn fromFallbacks(g: *Gfx, f: *Face, cp: u21, color_only: bool) ?Glyph {
    for (g.fallbacks.items, 0..) |fb, i| {
        if (color_only and !fb.color) continue;
        if (!f.tried[i]) {
            f.tried[i] = true;
            f.fallback[i] = c.TTF_OpenFont(fb.path.ptr, @floatFromInt(f.px));
            if (f.fallback[i]) |font| c.TTF_SetFontHinting(font, c.TTF_HINTING_LIGHT);
        }
        const font = f.fallback[i] orelse continue;
        if (!c.TTF_FontHasGlyph(font, cp)) continue;
        // A color font can still fail to draw (no PNG support): next one.
        if (g.render(font, cp, fb.color, true)) |gl| return gl;
    }
    return null;
}

fn render(g: *Gfx, font: *c.TTF_Font, cp: u21, is_color: bool, fallback: bool) ?Glyph {
    const white: c.SDL_Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const surf = c.TTF_RenderGlyph_Blended(font, cp, white) orelse return null;
    defer c.SDL_DestroySurface(surf);
    if (surf.*.w <= 0 or surf.*.h <= 0) return null;
    const src = if (is_color) visibleBox(surf) orelse return null else null;
    const tex = c.SDL_CreateTextureFromSurface(g.renderer, surf) orelse return null;
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND);
    if (is_color) _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    const w: f32 = if (src) |r| r.w else @floatFromInt(surf.*.w);
    const h: f32 = if (src) |r| r.h else @floatFromInt(surf.*.h);
    return .{ .tex = tex, .w = w, .h = h, .color = is_color, .fallback = fallback, .src = src };
}

/// The box around a rendered glyph's visible pixels; null when there are
/// none (the font couldn't draw it).
fn visibleBox(surf: *c.SDL_Surface) ?c.SDL_FRect {
    if (surf.*.format != c.SDL_PIXELFORMAT_ARGB8888) return .{ .w = @floatFromInt(surf.*.w), .h = @floatFromInt(surf.*.h) };
    const w: usize = @intCast(surf.*.w);
    const h: usize = @intCast(surf.*.h);
    const pitch: usize = @intCast(surf.*.pitch);
    const px: [*]const u8 = @ptrCast(surf.*.pixels orelse return null);
    var x0 = w;
    var y0 = h;
    var x1: usize = 0;
    var y1: usize = 0;
    for (0..h) |y| {
        const row: [*]align(1) const u32 = @ptrCast(px + y * pitch);
        for (0..w) |x| if (row[x] >> 24 > 8) {
            x0 = @min(x0, x);
            x1 = @max(x1, x + 1);
            y0 = @min(y0, y);
            y1 = @max(y1, y + 1);
        };
    }
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = @floatFromInt(x0), .y = @floatFromInt(y0), .w = @floatFromInt(x1 - x0), .h = @floatFromInt(y1 - y0) };
}

/// A `px`×`px` picture from premultiplied RGBA bytes (an app's icon).
/// Null: failed. The caller destroys it (SDL_DestroyTexture).
pub fn imageRgba(g: *Gfx, rgba: []const u8, px: u32) ?*c.SDL_Texture {
    const n: c_int = @intCast(px);
    const tex = c.SDL_CreateTexture(g.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, n, n) orelse return null;
    if (!c.SDL_UpdateTexture(tex, null, rgba.ptr, n * 4)) {
        c.SDL_DestroyTexture(tex);
        return null;
    }
    _ = c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    return tex;
}

/// Draw picture `tex` into `r`.
pub fn image(g: *Gfx, tex: *c.SDL_Texture, r: Rect) void {
    const sr = r.sdl();
    _ = c.SDL_RenderTexture(g.renderer, tex, null, &sr);
}

pub fn color(g: *Gfx, col: Rgb) void {
    _ = c.SDL_SetRenderDrawColor(g.renderer, col.r, col.g, col.b, 255);
}

pub fn fill(g: *Gfx, r: Rect, col: Rgb) void {
    g.color(col);
    const sr = r.sdl();
    _ = c.SDL_RenderFillRect(g.renderer, &sr);
}

/// `r` filled with `col` at opacity `alpha` (0 clear … 255 solid), blended
/// over what is drawn there.
pub fn fillAlpha(g: *Gfx, r: Rect, col: Rgb, alpha: u8) void {
    _ = c.SDL_SetRenderDrawBlendMode(g.renderer, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(g.renderer, col.r, col.g, col.b, alpha);
    const sr = r.sdl();
    _ = c.SDL_RenderFillRect(g.renderer, &sr);
    _ = c.SDL_SetRenderDrawBlendMode(g.renderer, c.SDL_BLENDMODE_NONE);
}

/// Outline of `thickness` pixels drawn inside `r`.
pub fn outline(g: *Gfx, r: Rect, col: Rgb, thickness: f32) void {
    const t = @max(@round(thickness), 1);
    g.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = t }, col);
    g.fill(.{ .x = r.x, .y = r.y + r.h - t, .w = r.w, .h = t }, col);
    g.fill(.{ .x = r.x, .y = r.y, .w = t, .h = r.h }, col);
    g.fill(.{ .x = r.x + r.w - t, .y = r.y, .w = t, .h = r.h }, col);
}

/// Dashed outline drawn inside `r`: dashes of `dash` pixels with gaps
/// as long.
pub fn dashedOutline(g: *Gfx, r: Rect, col: Rgb, thickness: f32, dash: f32) void {
    const t = @max(@round(thickness), 1);
    const d = @max(@round(dash), 1);
    var x = r.x;
    while (x < r.x + r.w) : (x += 2 * d) {
        const w = @min(d, r.x + r.w - x);
        g.fill(.{ .x = x, .y = r.y, .w = w, .h = t }, col);
        g.fill(.{ .x = x, .y = r.y + r.h - t, .w = w, .h = t }, col);
    }
    var y = r.y;
    while (y < r.y + r.h) : (y += 2 * d) {
        const h = @min(d, r.y + r.h - y);
        g.fill(.{ .x = r.x, .y = y, .w = t, .h = h }, col);
        g.fill(.{ .x = r.x + r.w - t, .y = y, .w = t, .h = h }, col);
    }
}

/// Straight line `thickness` pixels wide (made of 1-px lines shifted
/// across the stroke; good enough for small diagonal icons).
pub fn line(g: *Gfx, x1: f32, y1: f32, x2: f32, y2: f32, col: Rgb, thickness: f32) void {
    g.color(col);
    const t: usize = @intFromFloat(@max(@round(thickness), 1));
    const steep = @abs(y2 - y1) > @abs(x2 - x1);
    for (0..t) |i| {
        const d = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(t - 1)) / 2;
        const dx: f32 = if (steep) d else 0;
        const dy: f32 = if (steep) 0 else d;
        _ = c.SDL_RenderLine(g.renderer, x1 + dx, y1 + dy, x2 + dx, y2 + dy);
    }
}

/// Filled circle, drawn as one horizontal span per pixel row.
pub fn disc(g: *Gfx, cx: f32, cy: f32, r: f32, col: Rgb) void {
    g.color(col);
    var dy: f32 = -r + 0.5;
    while (dy < r) : (dy += 1) {
        const half = @sqrt(@max(r * r - dy * dy, 0));
        const sr: c.SDL_FRect = .{ .x = @round(cx - half), .y = @floor(cy + dy), .w = @max(@round(half * 2), 1), .h = 1 };
        _ = c.SDL_RenderFillRect(g.renderer, &sr);
    }
}

pub fn glyphAt(g: *Gfx, f: *Face, x: f32, y: f32, cp: u21, col: Rgb) void {
    g.glyphCells(f, x, y, cp, 0, 1, col);
}

/// Character `cp` in `cells` cells (2 for a wide one) at (x, y); `extra`
/// is the zero-width character that came with it (U+FE0F asks for the
/// emoji, U+FE0E for text). A color glyph, or one too big for its cells,
/// is scaled to fit and centered.
pub fn glyphCells(g: *Gfx, f: *Face, x: f32, y: f32, cp: u21, extra: u21, cells: u2, col: Rgb) void {
    g.glyphCellsStyled(f, x, y, cp, extra, cells, col, 0);
}

/// `glyphCells` in a style (bold / italic, `style`).
pub fn glyphCellsStyled(g: *Gfx, f: *Face, x: f32, y: f32, cp: u21, extra: u21, cells: u2, col: Rgb, st: Style) void {
    if (cp == ' ' or cp == 0) return;
    if (boxLines(cp)) |arms| return g.drawBox(f, x, y, arms, col);
    const emoji = (cells == 2 or extra == 0xfe0f) and extra != 0xfe0e;
    const gl = g.glyph(f, cp, emoji, st) orelse return;
    const box_w = f.cell_w * @as(f32, @floatFromInt(@max(cells, 1)));
    var w = gl.w;
    var h = gl.h;
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (gl.color or gl.fallback) {
        // An emoji fills its cells with a small margin.
        const k = if (gl.color) @min(box_w / w, f.cell_h / h) * 0.9 else @min(box_w / w, f.cell_h / h, 1);
        w *= k;
        h *= k;
        dx = (box_w - w) / 2;
        dy = (f.cell_h - h) / 2;
    }
    if (gl.color) {
        _ = c.SDL_SetTextureColorMod(gl.tex, 255, 255, 255);
    } else {
        _ = c.SDL_SetTextureColorMod(gl.tex, col.r, col.g, col.b);
    }
    const dst: c.SDL_FRect = .{ .x = @round(x + dx), .y = @round(y + dy), .w = w, .h = h };
    _ = c.SDL_RenderTexture(g.renderer, gl.tex, if (gl.src) |*r| r else null, &dst);
}

/// Box-drawing lines (U+2500…): the arms from the cell's center, left,
/// up, right, down; 0 none, 1 light, 2 heavy. Drawn as rectangles that
/// reach the cell's edges, so boxes join across rows and columns (the
/// font's glyphs are shorter than a cell with line spacing: gaps). Dashed
/// lines are drawn solid; double lines (═ ║ ╔ …) are left to the font.
fn boxLines(cp: u21) ?[4]u2 {
    // 4 digits per character: left, up, right, down.
    const main =
        "101020200101020210102020010102021010202001010202" ++
        "0011002100120022100120011002200201100120021002201100210012002200" ++
        "0111012102110112021202210122022211012101120111021202220121022202" ++
        "1011201110212021101220121022202211102110112021201210221012202220" ++
        "1111211111212121121111121212221112212112112222212122221212222222" ++
        "1010202001010202";
    const misc = [_]struct { cp: u21, arms: *const [4]u8 }{
        .{ .cp = 0x256D, .arms = "0011" }, .{ .cp = 0x256E, .arms = "1001" },
        .{ .cp = 0x256F, .arms = "1100" }, .{ .cp = 0x2570, .arms = "0110" },
        .{ .cp = 0x2574, .arms = "1000" }, .{ .cp = 0x2575, .arms = "0100" },
        .{ .cp = 0x2576, .arms = "0010" }, .{ .cp = 0x2577, .arms = "0001" },
        .{ .cp = 0x2578, .arms = "2000" }, .{ .cp = 0x2579, .arms = "0200" },
        .{ .cp = 0x257A, .arms = "0020" }, .{ .cp = 0x257B, .arms = "0002" },
        .{ .cp = 0x257C, .arms = "1020" }, .{ .cp = 0x257D, .arms = "0102" },
        .{ .cp = 0x257E, .arms = "2010" }, .{ .cp = 0x257F, .arms = "0201" },
    };
    const digits: *const [4]u8 = if (cp >= 0x2500 and cp <= 0x254F)
        main[(cp - 0x2500) * 4 ..][0..4]
    else for (misc) |m| {
        if (m.cp == cp) break m.arms;
    } else return null;
    var arms: [4]u2 = undefined;
    for (digits, 0..) |d, i| arms[i] = @intCast(d - '0');
    return arms;
}

/// The arms of `boxLines` in the cell at (x, y).
fn drawBox(g: *Gfx, f: *const Face, x: f32, y: f32, arms: [4]u2, col: Rgb) void {
    const light = @max(1, @round(f.cell_w / 9));
    const thick = [3]f32{ 0, light, light * 2 };
    const x0 = @round(x);
    const x1 = @round(x + f.cell_w);
    const y0 = @round(y);
    const y1 = @round(y + f.cell_h);
    const xm = @round(x + f.cell_w / 2);
    const ym = @round(y + f.cell_h / 2);
    // A line of thickness t covers [m - floor(t/2), m - floor(t/2) + t).
    // A horizontal arm reaches to the far edge of the vertical line it
    // meets (none: the center), so corners and joints close exactly.
    const hv = @max(thick[arms[1]], thick[arms[3]]); // vertical lines
    const hh = @max(thick[arms[0]], thick[arms[2]]); // horizontal lines
    const v_lo = xm - @floor(hv / 2);
    const h_lo = ym - @floor(hh / 2);
    if (arms[0] != 0) {
        const t = thick[arms[0]];
        g.fill(.{ .x = x0, .y = ym - @floor(t / 2), .w = v_lo + hv - x0, .h = t }, col);
    }
    if (arms[2] != 0) {
        const t = thick[arms[2]];
        g.fill(.{ .x = v_lo, .y = ym - @floor(t / 2), .w = x1 - v_lo, .h = t }, col);
    }
    if (arms[1] != 0) {
        const t = thick[arms[1]];
        g.fill(.{ .x = xm - @floor(t / 2), .y = y0, .w = t, .h = h_lo + hh - y0 }, col);
    }
    if (arms[3] != 0) {
        const t = thick[arms[3]];
        g.fill(.{ .x = xm - @floor(t / 2), .y = h_lo, .w = t, .h = y1 - h_lo }, col);
    }
}

test "box drawing arms" {
    try std.testing.expectEqual([4]u2{ 1, 0, 1, 0 }, boxLines(0x2500).?); // ─
    try std.testing.expectEqual([4]u2{ 0, 0, 1, 1 }, boxLines(0x250C).?); // ┌
    try std.testing.expectEqual([4]u2{ 1, 1, 0, 0 }, boxLines(0x2518).?); // ┘
    try std.testing.expectEqual([4]u2{ 1, 1, 1, 1 }, boxLines(0x253C).?); // ┼
    try std.testing.expectEqual([4]u2{ 2, 2, 2, 2 }, boxLines(0x254B).?); // ╋
    try std.testing.expectEqual([4]u2{ 2, 1, 2, 0 }, boxLines(0x2537).?); // ┷
    try std.testing.expectEqual([4]u2{ 0, 2, 0, 2 }, boxLines(0x254F).?); // ╏
    try std.testing.expectEqual([4]u2{ 0, 1, 1, 0 }, boxLines(0x2570).?); // ╰
    try std.testing.expect(boxLines(0x2550) == null); // ═: the font's
    try std.testing.expect(boxLines('q') == null);
}

/// Draw a UTF-8 string on the monospace grid starting at (x, y): a wide
/// character takes two cells, a zero-width one none. Returns the x after
/// the last character.
pub fn text(g: *Gfx, f: *Face, x: f32, y: f32, s: []const u8, col: Rgb) f32 {
    var cx = x;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        const w = wcwidth.width(cp);
        if (w == 0) continue;
        g.glyphCells(f, cx, y, cp, 0, w, col);
        cx += f.cell_w * @as(f32, @floatFromInt(w));
    }
    return cx;
}

pub fn textWidth(f: *const Face, s: []const u8) f32 {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| n += wcwidth.width(cp);
    return @as(f32, @floatFromInt(n)) * f.cell_w;
}

pub fn clip(g: *Gfx, r: ?Rect) void {
    if (r) |rr| {
        const ir: c.SDL_Rect = .{
            .x = @intFromFloat(@round(rr.x)),
            .y = @intFromFloat(@round(rr.y)),
            .w = @intFromFloat(@round(rr.w)),
            .h = @intFromFloat(@round(rr.h)),
        };
        _ = c.SDL_SetRenderClipRect(g.renderer, &ir);
    } else {
        _ = c.SDL_SetRenderClipRect(g.renderer, null);
    }
}
