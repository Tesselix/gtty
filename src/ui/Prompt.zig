// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The fixed command area at the bottom of the gtty screen:
//! a two-line input editor, with the status bar line underneath it
//! (drawn by StatusBar into `status_r`). On its top border, right: a pin
//! and a ▾ that hides it; hidden (`collapsed`) it is one thin strip,
//! "▴ prompt" on the left (a click opens it), the status bar's notices
//! and the pin. Unpinned, App hides it when the keyboard leaves it or the
//! AI is done with a request.

const std = @import("std");
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;

const Prompt = @This();

gpa: std.mem.Allocator,
text: std.ArrayList(u21) = .empty,
cursor: usize = 0,
/// The selection's other end (`cursor` is its head); null: none.
anchor: ?usize = null,
/// Where the text was drawn last (`draw`), for the mouse (`posAt`).
lay: struct { lx: f32 = 0, start: usize = 0, first: usize = 1, next: usize = 1, cell_w: f32 = 1, cell_h: f32 = 1 } = .{},
/// A double / triple click's word / line: dragging extends by it.
drag_unit: enum { char, word, all } = .char,
drag_from: [2]usize = .{ 0, 0 },
history: std.ArrayList([]u8) = .empty,
/// Index into history while browsing with Up/Down; null when editing a new line.
hist_pos: ?usize = null,
/// Line being edited before history browsing started.
stash: std.ArrayList(u21) = .empty,

rect: Rect = .{},
input_r: Rect = .{},
status_r: Rect = .{},
/// Hidden: only the thin strip (`open_r` opens it).
collapsed: bool = false,
/// Always open (the default; config `prompt-pinned`).
pinned: bool = true,
/// The buttons on its top border: hide (▾; open: nothing), pin.
hide_r: Rect = .{},
pin_r: Rect = .{},
/// Collapsed: "▴ prompt", a click opens it.
open_r: Rect = .{},

pub fn init(gpa: std.mem.Allocator) Prompt {
    return .{ .gpa = gpa };
}

pub fn deinit(p: *Prompt) void {
    p.text.deinit(p.gpa);
    p.stash.deinit(p.gpa);
    for (p.history.items) |h| p.gpa.free(h);
    p.history.deinit(p.gpa);
}

// ------------------------------------------------------------ editing

/// Typed or pasted text replaces the selection (line ends dropped).
pub fn insertUtf8(p: *Prompt, s: []const u8) void {
    _ = p.deleteSel();
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp == '\n' or cp == '\r') continue;
        p.text.insert(p.gpa, p.cursor, cp) catch return;
        p.cursor += 1;
    }
    p.hist_pos = null;
}

/// The selection [lo, hi), or null when there is none.
pub fn selection(p: *const Prompt) ?[2]usize {
    const a = p.anchor orelse return null;
    if (a == p.cursor) return null;
    return .{ @min(a, p.cursor), @max(a, p.cursor) };
}

/// The selected text as UTF-8 (caller frees); null when none.
pub fn selectedText(p: *const Prompt) ?[]u8 {
    const sel = p.selection() orelse return null;
    return encode(p.gpa, p.text.items[sel[0]..sel[1]]) catch null;
}

pub fn selectAll(p: *Prompt) void {
    p.anchor = 0;
    p.cursor = p.text.items.len;
}

fn deleteSel(p: *Prompt) bool {
    const sel = p.selection() orelse {
        p.anchor = null;
        return false;
    };
    p.text.replaceRange(p.gpa, sel[0], sel[1] - sel[0], &.{}) catch return false;
    p.cursor = sel[0];
    p.anchor = null;
    return true;
}

/// Backspace (`word`: the word before the cursor, ⌥ / Ctrl; `line`: all
/// before it, ⌘): the selection, else what is before the cursor.
pub fn backspace(p: *Prompt, word: bool, line: bool) void {
    if (p.deleteSel()) return;
    p.anchor = if (line) 0 else if (word) p.wordLeftOf(p.cursor) else p.cursor -| 1;
    _ = p.deleteSel();
}

/// Delete (`word`: the word after the cursor): the selection, else what
/// is after the cursor.
pub fn delete(p: *Prompt, word: bool) void {
    if (p.deleteSel()) return;
    p.anchor = if (word) p.wordRightOf(p.cursor) else @min(p.cursor + 1, p.text.items.len);
    _ = p.deleteSel();
}

pub const Move = enum { left, right, word_left, word_right, home, end };

/// Move the cursor; `extend` (Shift) keeps the selection's other end,
/// else a plain ← / → on a selection goes to its edge.
pub fn move(p: *Prompt, m: Move, extend: bool) void {
    const sel = p.selection();
    const to: usize = switch (m) {
        .left => if (!extend and sel != null) sel.?[0] else p.cursor -| 1,
        .right => if (!extend and sel != null) sel.?[1] else @min(p.cursor + 1, p.text.items.len),
        .word_left => p.wordLeftOf(p.cursor),
        .word_right => p.wordRightOf(p.cursor),
        .home => 0,
        .end => p.text.items.len,
    };
    if (extend) {
        if (p.anchor == null) p.anchor = p.cursor;
    } else p.anchor = null;
    p.cursor = to;
}

fn isWord(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '/', '.', '-', '_', ',', ';', ':', '|', '&', '=', '(', ')', '[', ']', '{', '}', '<', '>', '\'', '"' => false,
        else => true,
    };
}

fn wordLeftOf(p: *const Prompt, from: usize) usize {
    var i = from;
    while (i > 0 and !isWord(p.text.items[i - 1])) i -= 1;
    while (i > 0 and isWord(p.text.items[i - 1])) i -= 1;
    return i;
}

fn wordRightOf(p: *const Prompt, from: usize) usize {
    const n = p.text.items.len;
    var i = from;
    while (i < n and !isWord(p.text.items[i])) i += 1;
    while (i < n and isWord(p.text.items[i])) i += 1;
    return i;
}

/// The word (or run of other characters) around position `i`.
fn wordAt(p: *const Prompt, i: usize) [2]usize {
    const n = p.text.items.len;
    if (n == 0) return .{ 0, 0 };
    const at = @min(i, n - 1);
    const kind = isWord(p.text.items[at]);
    var lo = at;
    while (lo > 0 and isWord(p.text.items[lo - 1]) == kind) lo -= 1;
    var hi = at + 1;
    while (hi < n and isWord(p.text.items[hi]) == kind) hi += 1;
    return .{ lo, hi };
}

// ------------------------------------------------------------ mouse

/// The text position at (x, y) in the input lines, as last drawn.
pub fn posAt(p: *const Prompt, x: f32, y: f32) usize {
    const l = p.lay;
    const line: usize = if (y < p.input_r.y + l.cell_h) 0 else 1;
    const x0 = if (line == 0) l.lx else p.input_r.x;
    const col: usize = @intFromFloat(@max(@round((x - x0) / l.cell_w), 0));
    const i = if (line == 0) l.start + @min(col, l.first) else l.start + l.first + @min(col, l.next);
    return @min(i, p.text.items.len);
}

/// A press in the input: 1 click puts the cursor there (Shift: extends
/// the selection to it), 2 select the word, 3 the whole line.
pub fn press(p: *Prompt, x: f32, y: f32, clicks: u8, shift: bool) void {
    const i = p.posAt(x, y);
    p.drag_unit = switch (clicks) {
        0, 1 => .char,
        2 => .word,
        else => .all,
    };
    switch (p.drag_unit) {
        .char => {
            if (shift) {
                if (p.anchor == null) p.anchor = p.cursor;
            } else p.anchor = i;
            p.cursor = i;
            p.drag_from = .{ p.anchor.?, p.anchor.? };
        },
        .word => {
            const w = p.wordAt(i);
            p.anchor = w[0];
            p.cursor = w[1];
            p.drag_from = w;
        },
        .all => {
            p.selectAll();
            p.drag_from = .{ 0, p.text.items.len };
        },
    }
}

/// The mouse dragged (button held since `press`): the selection follows,
/// by words after a double click.
pub fn dragTo(p: *Prompt, x: f32, y: f32) void {
    const i = p.posAt(x, y);
    switch (p.drag_unit) {
        .char => p.cursor = i,
        .word => {
            const w = p.wordAt(i);
            if (i < p.drag_from[0]) {
                p.anchor = p.drag_from[1];
                p.cursor = w[0];
            } else {
                p.anchor = p.drag_from[0];
                p.cursor = @max(w[1], p.drag_from[1]);
            }
        },
        .all => {},
    }
}

pub fn clear(p: *Prompt) void {
    p.text.clearRetainingCapacity();
    p.cursor = 0;
    p.anchor = null;
    p.hist_pos = null;
}

pub fn isEmpty(p: *const Prompt) bool {
    return p.text.items.len == 0;
}

/// Take the current line as UTF-8 (caller frees), add it to history and clear.
pub fn take(p: *Prompt) ![]u8 {
    const line = try encode(p.gpa, p.text.items);
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len > 0) {
        const last = if (p.history.items.len > 0) p.history.items[p.history.items.len - 1] else "";
        if (!std.mem.eql(u8, last, line)) p.history.append(p.gpa, try p.gpa.dupe(u8, line)) catch {};
    }
    p.clear();
    return line;
}

pub fn historyPrev(p: *Prompt) void {
    if (p.history.items.len == 0) return;
    if (p.hist_pos) |i| {
        if (i == 0) return;
        p.hist_pos = i - 1;
    } else {
        p.stash.clearRetainingCapacity();
        p.stash.appendSlice(p.gpa, p.text.items) catch {};
        p.hist_pos = p.history.items.len - 1;
    }
    p.load(p.history.items[p.hist_pos.?]);
}

pub fn historyNext(p: *Prompt) void {
    const i = p.hist_pos orelse return;
    if (i + 1 < p.history.items.len) {
        p.hist_pos = i + 1;
        p.load(p.history.items[i + 1]);
    } else {
        p.hist_pos = null;
        p.text.clearRetainingCapacity();
        p.text.appendSlice(p.gpa, p.stash.items) catch {};
        p.cursor = p.text.items.len;
        p.anchor = null;
    }
}

fn load(p: *Prompt, s: []const u8) void {
    const keep = p.hist_pos;
    p.clear();
    p.insertUtf8(s);
    p.hist_pos = keep;
}

fn encode(gpa: std.mem.Allocator, cps: []const u21) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4]u8 = undefined;
    for (cps) |cp| {
        const n = std.unicode.utf8Encode(cp, &buf) catch continue;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------ layout & draw

/// Height of the dock for a given face (2 input lines + status bar);
/// collapsed: one status line.
pub fn height(p: *const Prompt, f: *const Gfx.Face, status: *const Gfx.Face, ui: f32) f32 {
    if (p.collapsed) return @round(status.cell_h + 12 * ui);
    return @round(f.cell_h * 2 + status.cell_h + 30 * ui);
}

pub const collapsed_label = "prompt";

pub fn layout(p: *Prompt, r: Rect, f: *const Gfx.Face, status: *const Gfx.Face, ui: f32) void {
    p.rect = r;
    const pad = @round(10 * ui);
    const btn = @round(status.cell_h * 1.25);
    const gap = @round(6 * ui);
    const top = r.y + @round(@max(2 * ui, 2) + (if (p.collapsed) (r.h - btn) / 2 - ui else 4 * ui));
    p.pin_r = .{ .x = r.x + r.w - pad - btn, .y = top, .w = btn, .h = btn };
    p.hide_r = if (p.collapsed) .{} else .{ .x = p.pin_r.x - gap - btn, .y = top, .w = btn, .h = btn };
    if (p.collapsed) {
        p.input_r = .{};
        p.open_r = .{ .x = r.x + pad, .y = top, .w = btn + gap + Gfx.textWidth(status, collapsed_label) + gap, .h = btn };
        const sx = p.open_r.x + p.open_r.w + pad;
        p.status_r = .{ .x = sx, .y = r.y + (r.h - status.cell_h) / 2 + ui, .w = p.pin_r.x - gap - sx, .h = status.cell_h };
        return;
    }
    p.open_r = .{};
    p.input_r = .{ .x = r.x + pad, .y = r.y + @round(8 * ui), .w = p.hide_r.x - gap - r.x - pad, .h = f.cell_h * 2 };
    const sy = p.input_r.y + p.input_r.h + @round(4 * ui);
    p.status_r = .{ .x = r.x + pad, .y = sy, .w = r.w - 2 * pad, .h = r.y + r.h - sy - @round(3 * ui) };
}

pub const Button = enum { hide, pin, open };

/// The border button (or the collapsed strip's "▴ prompt") at x, y.
pub fn buttonAt(p: *const Prompt, x: f32, y: f32) ?Button {
    if (p.pin_r.contains(x, y)) return .pin;
    if (p.hide_r.contains(x, y)) return .hide;
    if (p.open_r.contains(x, y)) return .open;
    return null;
}

/// ▾ / ▴ (`up`) in the box `r`.
fn chevron(gfx: *Gfx, r: Rect, up: bool, col: color.Rgb, ui: f32) void {
    const cx = r.x + r.w / 2;
    const hw = r.w * 0.3;
    const hh = r.w * 0.16;
    const cy = r.y + r.h / 2;
    const tip = if (up) cy - hh else cy + hh;
    const base = if (up) cy + hh else cy - hh;
    const th = @max(1.5 * ui, 1.5);
    gfx.line(cx - hw, base, cx, tip, col, th);
    gfx.line(cx, tip, cx + hw, base, col, th);
}

/// A push pin in the box `r`: upright while pinned, lying over 45° when
/// not. Cap, flange across, needle.
fn pin(gfx: *Gfx, r: Rect, pinned: bool, col: color.Rgb, ui: f32) void {
    const th = @max(1.5 * ui, 1.5);
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const k: f32 = if (pinned) 0 else std.math.sqrt1_2; // sin 45°
    const cs: f32 = if (pinned) 1 else std.math.sqrt1_2;
    const P = struct {
        fn at(x0: f32, y0: f32, s_: f32, c_: f32, u: f32, v: f32, size: f32) [2]f32 {
            // (u, v): across / along the pin, -0.5 … 0.5 of the box.
            return .{ x0 + (u * c_ - v * s_) * size, y0 + (u * s_ + v * c_) * size };
        }
    };
    const sz = r.w;
    const cap0 = P.at(cx, cy, k, cs, 0, -0.42, sz);
    const cap1 = P.at(cx, cy, k, cs, 0, -0.12, sz);
    const fl0 = P.at(cx, cy, k, cs, -0.3, -0.06, sz);
    const fl1 = P.at(cx, cy, k, cs, 0.3, -0.06, sz);
    const nd1 = P.at(cx, cy, k, cs, 0, 0.45, sz);
    gfx.line(cap0[0], cap0[1], cap1[0], cap1[1], col, @round(sz * 0.32));
    gfx.line(fl0[0], fl0[1], fl1[0], fl1[1], col, th * 1.3);
    gfx.line(cap1[0], cap1[1], nd1[0], nd1[1], col, th * 0.8);
}

pub const DrawInfo = struct {
    /// Shown before the input, e.g. "gtty ›" or "#2 zsh ›".
    label: []const u8,
    label_color: color.Rgb,
    cursor_visible: bool,
    /// Override for the typed text (red while a rejected line flashes).
    text_color: ?color.Rgb = null,
    /// Dim text shown in place of an empty line (what can be typed).
    hint: ?[]const u8 = null,
    /// The button under the mouse (drawn brighter).
    hover: ?Button = null,
    /// For the collapsed strip's label.
    status_face: *Gfx.Face,
};

pub fn draw(p: *Prompt, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, ui: f32, info: DrawInfo) void {
    gfx.fill(p.rect, theme.prompt_bg);
    // Divider between the windows area and the dock (2 px at 1x).
    gfx.fill(.{ .x = p.rect.x, .y = p.rect.y, .w = p.rect.w, .h = @max(@round(2 * ui), 2) }, theme.divider);
    const hot = theme.prompt_fg;
    for ([_]Button{ .hide, .pin, .open }) |b| {
        const br = switch (b) {
            .hide => p.hide_r,
            .pin => p.pin_r,
            .open => p.open_r,
        };
        if (br.w == 0) continue;
        if (info.hover == b) gfx.fill(br, theme.focus.mix(theme.prompt_bg, 0.75));
        const col = if (info.hover == b) hot else theme.dim;
        switch (b) {
            .hide => chevron(gfx, br, false, col, ui),
            .pin => pin(gfx, br, p.pinned, if (p.pinned) theme.focus else col, ui),
            .open => {
                const sf = info.status_face;
                chevron(gfx, .{ .x = br.x, .y = br.y, .w = br.h, .h = br.h }, true, col, ui);
                _ = gfx.text(sf, br.x + br.h + @round(6 * ui), br.y + (br.h - sf.cell_h) / 2, collapsed_label, col);
            },
        }
    }
    if (p.collapsed) return;

    // Label, then the text wrapped over two lines.
    const r = p.input_r;
    const lx = gfx.text(f, r.x, r.y, info.label, info.label_color) + f.cell_w;
    const first_cols: usize = @intFromFloat(@max(@floor((r.x + r.w - lx) / f.cell_w), 1));
    const next_cols: usize = @intFromFloat(@max(@floor(r.w / f.cell_w), 1));

    // Scroll so the cursor is always visible within the two lines.
    const cap = first_cols + next_cols;
    const start: usize = if (p.cursor + 1 > cap) p.cursor + 1 - cap else 0;
    p.lay = .{ .lx = lx, .start = start, .first = first_cols, .next = next_cols, .cell_w = f.cell_w, .cell_h = f.cell_h };
    // The selection only while the prompt has the keyboard.
    const sel = if (info.cursor_visible) p.selection() else null;

    var line: usize = 0;
    var col: usize = 0;
    var i = start;
    var cur_x: f32 = lx;
    var cur_y: f32 = r.y;
    while (i <= p.text.items.len) : (i += 1) {
        const width = if (line == 0) first_cols else next_cols;
        if (col >= width) {
            line += 1;
            col = 0;
            if (line >= 2) break;
        }
        const x0 = if (line == 0) lx else r.x;
        const x = x0 + @as(f32, @floatFromInt(col)) * f.cell_w;
        const y = r.y + @as(f32, @floatFromInt(line)) * f.cell_h;
        if (i == p.cursor) {
            cur_x = x;
            cur_y = y;
        }
        if (i == p.text.items.len) break;
        if (sel) |sl| if (i >= sl[0] and i < sl[1]) gfx.fill(.{ .x = x, .y = y, .w = f.cell_w, .h = f.cell_h }, theme.selection);
        gfx.glyphAt(f, x, y, p.text.items[i], info.text_color orelse theme.prompt_fg);
        col += 1;
    }
    if (p.text.items.len == 0) if (info.hint) |h| {
        gfx.clip(.{ .x = lx, .y = r.y, .w = r.x + r.w - lx, .h = f.cell_h });
        _ = gfx.text(f, lx + f.cell_w, r.y, h, theme.dim);
        gfx.clip(null);
    };
    if (info.cursor_visible) {
        gfx.fill(.{ .x = cur_x, .y = cur_y, .w = @max(@round(f.cell_w * 0.12), 2), .h = f.cell_h }, theme.cursor);
    }
}

test "prompt editing: selection, words, mouse" {
    const t = std.testing;
    var p = Prompt.init(t.allocator);
    defer p.deinit();
    p.insertUtf8("git commit -m fix");
    p.move(.word_left, true);
    try t.expectEqual([2]usize{ 14, 17 }, p.selection().?);
    p.insertUtf8("done");
    const s1 = try encode(t.allocator, p.text.items);
    defer t.allocator.free(s1);
    try t.expectEqualStrings("git commit -m done", s1);
    p.move(.left, false);
    p.move(.home, true);
    p.backspace(false, false);
    try t.expectEqual(@as(usize, 1), p.text.items.len);
    p.clear();
    p.insertUtf8("ls -la /tmp");
    p.backspace(true, false);
    try t.expectEqual(@as(usize, 8), p.text.items.len); // "ls -la /"
    // The mouse: as drawn with the label 4 cells wide, 10 + 20 columns.
    p.input_r = .{ .x = 0, .y = 0, .w = 200, .h = 20 };
    p.lay = .{ .lx = 40, .start = 0, .first = 10, .next = 20, .cell_w = 10, .cell_h = 10 };
    try t.expectEqual(@as(usize, 2), p.posAt(60, 5));
    try t.expectEqual(@as(usize, 0), p.posAt(5, 5));
    p.press(80, 5, 2, false); // a double click on "la"
    try t.expectEqual([2]usize{ 4, 6 }, p.selection().?);
    p.press(40, 5, 1, false);
    p.dragTo(70, 5);
    try t.expectEqual([2]usize{ 0, 3 }, p.selection().?);
}
