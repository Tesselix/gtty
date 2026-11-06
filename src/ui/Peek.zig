// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The open peek or epeek of a chip: draws what the chip's extension
//! described (`ChipUi`, docs/extensions.md) and reports what the user does
//! as `Action`s. It knows nothing about folders or branches: the chips do
//! (src/chips/).
//!
//!   * **Peek** (`mode` peek): one line over the chip, in the normal text
//!     size: [prefixButton] [expand]  text  [postButton] [×]. A click on
//!     the text: its `onclick`, else it expands.
//!   * **Epeek** (`mode` epeek): the same box grown upward, hiding the
//!     peek or chip: the frame (when there is one) as the peek's row, the
//!     filter in a row of its own, the lines, a dim footer, the message.
//!     gtty doesn't filter: every change of the box is an `Action.filter`.
//!   * **Result:** `state` colors the border; `ok` closes it after 1 s.
//!   * **Dismissal:** the mouse leaving starts a 5 s countdown, shown by
//!     the thicker bottom border emptying right to left; coming back stops
//!     it. A click anywhere else or Esc closes it at once.
//!
//! App owns at most one Peek, routes the mouse and (while `wantsKeys`) the
//! keyboard to it, and acts on what it returns.

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Rgb = color.Rgb;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const ids = @import("ids.zig");
const JobWindow = @import("JobWindow.zig");
const ChipUi = @import("ChipUi.zig");
const text_mod = @import("text.zig");

const Peek = @This();

pub const Mode = enum { peek, epeek };

gpa: std.mem.Allocator,
/// The job window whose chip opened it, and which chip.
uid: ids.Id,
chip: usize,
/// What is shown; the window's, it lives as long as the window.
ui: *ChipUi,
/// The chip on screen (the peek covers it and grows up from it).
anchor: Rect,
mode: Mode = .peek,
/// The filter box and the list take the keyboard (a user's action opened
/// it, or a click inside).
keys: bool = false,

filter: std.ArrayList(u8) = .empty,
/// Selected line (keyboard), first visible row, row under the mouse.
sel: usize = 0,
top: usize = 0,
hover_row: ?usize = null,
over: Part = .none,
/// The `ChipUi.lines_seq` the selection was set for.
lines_seen: u32 = 0,
/// The state last seen, and when it became `ok`.
state_seen: sdk.State = .idle,
state_ms: u64 = 0,
/// When something was copied (it flashes); 0 = not flashing.
flash_ms: u64 = 0,
/// The list row that flashes instead of the top row's text.
flash_row: ?usize = null,
/// When the mouse left the peek (the countdown runs); 0 while it is over it.
leave_ms: u64 = 0,
/// `hoverExpand`: since when the mouse rests on it, folded (each move
/// starts over); 0 = not on it. `hold`: a click copied or folded it, no
/// hover expand until the mouse leaves.
hover_ms: u64 = 0,
hold: bool = false,
/// The text the mouse rests on (`onhover` fires once, after `expand_hover_ms`).
rest: ?Rest = null,
rest_ms: u64 = 0,
/// `Fire.text` of the last action.
text_buf: [512]u8 = undefined,
/// The mouse came onto the expand button of a `hoverExpand` peek.
over_expand: bool = false,

// Layout (pixels), from `layout`.
box: Rect = .{},
expand_r: Rect = .{},
close_r: Rect = .{},
left_r: [2]Rect = @splat(.{}),
right_r: [2]Rect = @splat(.{}),
text_r: Rect = .{},
filter_r: Rect = .{},
list_r: Rect = .{},
foot_r: Rect = .{},
msg_r: Rect = .{},
row_h: f32 = 1,
rows: usize = 0,
bar_h: f32 = 3,
icon_s: f32 = 1,
/// Two cells: where a row's text starts.
cell2: f32 = 0,

pub const Rest = union(enum) { head, row: usize };

pub const Part = union(enum) { none, close, expand, left: usize, right: usize, prefix: usize, post: usize, option: usize };

/// A click for the extension; the strings live until the next change.
pub const Fire = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    data: []const u8 = "",
    function: []const u8 = "",
};

/// What App should do after an event.
pub const Action = union(enum) {
    none,
    redraw,
    close,
    fire: Fire,
    /// The filter's text changed.
    filter,
    /// The epeek opened from the peek.
    expanded,
    /// A ⋮ button: its popup list.
    items: struct { button: *const sdk.Button, at: [2]f32 },
};

/// Mouse away this long: the peek closes (the countdown bar). A setting.
pub var dismiss_ms: u64 = 5000;
/// The mouse resting this long: `hoverExpand`, `onhover` (App sets it to
/// the chip hover time).
pub var expand_hover_ms: u64 = 500;
/// `ok`: green border this long, then closed.
const ok_ms = 1000;
/// How long the copied text flashes (as a job window's name flash).
const flash_len_ms = 350;
/// Most rows in the list before it scrolls.
const max_rows = 10;
/// Most options offered under the filter.
const max_options = 5;

pub fn open(gpa: std.mem.Allocator, uid: ids.Id, chip: usize, ui: *ChipUi, anchor: Rect, mode: Mode, keys: bool) Peek {
    ui.clearResult();
    var p: Peek = .{ .gpa = gpa, .uid = uid, .chip = chip, .ui = ui, .anchor = anchor, .mode = mode, .keys = keys };
    p.startList();
    return p;
}

pub fn deinit(p: *Peek) void {
    p.filter.deinit(p.gpa);
}

fn lines(p: *const Peek) []const sdk.Line {
    return if (p.ui.epeek) |e| e.lines else &.{};
}

fn frame(p: *const Peek) ?*const sdk.Frame {
    if (p.mode != .epeek) return null;
    if (p.ui.epeek) |*e| if (e.frame) |*f| return f;
    return null;
}

pub fn filterDesc(p: *const Peek) ?*const sdk.Filter {
    if (p.mode != .epeek) return null;
    if (p.frame()) |f| if (f.filter) |*x| return x;
    return null;
}

fn state(p: *const Peek) sdk.State {
    return if (p.mode == .epeek) (if (p.ui.epeek) |e| e.state else .idle) else .idle;
}

fn message(p: *const Peek) []const sdk.Text {
    return if (p.mode == .epeek) (if (p.ui.epeek) |e| e.message else &.{}) else &.{};
}

/// A top row is shown: always on a peek, on an epeek only with a frame.
fn hasHead(p: *const Peek) bool {
    return p.mode == .peek or p.frame() != null;
}

fn headText(p: *const Peek) *const sdk.Text {
    if (p.frame()) |f| return &f.text;
    if (p.ui.peek) |*k| return &k.text;
    return &blank_text;
}
const blank_text: sdk.Text = .{};

fn leftButton(p: *const Peek, i: usize) ?*const sdk.Button {
    if (p.frame()) |f| return if (f.left[i]) |*b| b else null;
    if (p.mode == .peek and i == 0) if (p.ui.peek) |*k| if (k.prefixButton) |*b| return b;
    return null;
}

fn rightButton(p: *const Peek, i: usize) ?*const sdk.Button {
    if (p.frame()) |f| return if (f.right[i]) |*b| b else null;
    if (p.mode == .peek and i == 0) if (p.ui.peek) |*k| if (k.postButton) |*b| return b;
    return null;
}

/// The expand button: on a peek that has an epeek to show; on an epeek
/// that has a peek to go back to.
fn hasExpand(p: *const Peek) bool {
    return switch (p.mode) {
        .peek => if (p.ui.peek) |k| k.expand and p.ui.epeek != null else false,
        .epeek => p.frame() != null and p.ui.peek != null,
    };
}

pub fn wantsKeys(p: *const Peek) bool {
    return p.mode == .epeek and p.keys;
}

pub fn contains(p: *const Peek, x: f32, y: f32) bool {
    return p.box.contains(x, y);
}

/// The window's description changed: follow it.
pub fn refresh(p: *Peek, now: u64) void {
    if (p.ui.lines_seq != p.lines_seen) p.startList();
    if (p.sel >= p.lines().len) p.sel = p.lines().len -| 1;
    const st = p.state();
    if (st != p.state_seen) {
        p.state_seen = st;
        p.state_ms = now;
    }
    if (p.mode == .peek and p.ui.peek == null and p.ui.epeek != null) p.mode = .epeek;
}

/// New lines: back on the extension's choice, and in view.
fn startList(p: *Peek) void {
    p.lines_seen = p.ui.lines_seq;
    p.sel = if (p.ui.epeek) |e| @min(e.selected, e.lines.len -| 1) else 0;
    p.top = 0;
    p.keepSelVisible();
}

/// Show the peek or the epeek (`setDisplayMode`, a chip shortcut).
pub fn setMode(p: *Peek, mode: Mode, keys: bool) void {
    p.mode = mode;
    p.keys = keys or p.keys;
    p.hold = true;
    p.hover_ms = 0;
    p.startList();
    if (mode == .epeek and p.filter.items.len == 0) if (p.filterDesc()) |f| p.filter.appendSlice(p.gpa, f.text) catch {};
}

/// Something was copied: the top row's text, or the selected row, flashes.
pub fn flashText(p: *Peek, row: bool) void {
    p.flash_ms = @max(c.SDL_GetTicks(), 1);
    p.flash_row = if (row) p.sel else null;
}

fn toggleExpand(p: *Peek) Action {
    p.hold = true;
    p.hover_ms = 0;
    if (p.mode == .epeek) {
        p.mode = .peek;
        return .redraw;
    }
    p.setMode(.epeek, true);
    return .expanded;
}

fn fireLine(p: *Peek, l: *const sdk.Line) Action {
    if (l.onclick.len == 0) return .none;
    return .{ .fire = .{ .id = l.id, .text = l.text.plain(&p.text_buf), .data = l.data, .function = l.onclick } };
}

fn press(p: *Peek, b: *const sdk.Button, r: Rect) Action {
    if (b.dots == .vertical) return .{ .items = .{ .button = b, .at = .{ r.x, r.y + r.h } } };
    if (b.onclick.len == 0) return .none;
    return .{ .fire = .{ .id = b.id, .text = b.text.plain(&p.text_buf), .data = b.data, .function = b.onclick } };
}

/// The selected line's `onclick` (Enter).
fn pick(p: *Peek) Action {
    if (p.state() == .busy or p.sel >= p.lines().len) return .none;
    return p.fireLine(&p.lines()[p.sel]);
}

fn keepSelVisible(p: *Peek) void {
    const rows = @max(p.visibleRows(), 1);
    if (p.sel < p.top) p.top = p.sel;
    if (p.sel >= p.top + rows) p.top = p.sel + 1 - rows;
}

fn visibleRows(p: *const Peek) usize {
    return @min(p.lines().len, max_rows);
}

fn moveSel(p: *Peek, delta: isize) void {
    if (p.lines().len == 0) return;
    const last: isize = @intCast(p.lines().len - 1);
    p.sel = @intCast(std.math.clamp(@as(isize, @intCast(p.sel)) + delta, 0, last));
    p.keepSelVisible();
}

/// The options that fit what is typed (not the text itself).
fn optionMatches(p: *const Peek, out: *[max_options][]const u8) [][]const u8 {
    const f = p.filterDesc() orelse return out[0..0];
    if (p.filter.items.len == 0) return out[0..0];
    var n: usize = 0;
    for (f.options) |o| {
        if (n == max_options) break;
        if (std.ascii.eqlIgnoreCase(o, p.filter.items)) continue;
        if (std.ascii.indexOfIgnoreCase(o, p.filter.items) == null) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

fn takeOption(p: *Peek, o: []const u8) Action {
    p.filter.clearRetainingCapacity();
    p.filter.appendSlice(p.gpa, o) catch {};
    return .filter;
}

// ------------------------------------------------------------ events

/// Once a frame: the timers.
pub fn tick(p: *Peek, now: u64) Action {
    if (p.state() == .ok and now -| p.state_ms >= ok_ms) return .close;
    if (p.mode == .peek and p.hover_ms != 0 and now -| p.hover_ms >= expand_hover_ms) {
        p.hover_ms = 0;
        if (p.ui.peek) |k| if (k.hoverExpand and p.hasExpand()) return p.toggleExpand();
    }
    if (p.rest_ms != 0 and now -| p.rest_ms >= expand_hover_ms) {
        p.rest_ms = 0;
        if (p.rest) |r| if (p.restFire(r)) |a| return a;
    }
    if (p.leave_ms != 0 and p.state() != .busy) {
        if (now -| p.leave_ms >= dismiss_ms) return .close;
        return .redraw; // the countdown bar moves
    }
    if (p.flash_ms != 0) {
        if (now -| p.flash_ms >= flash_len_ms) {
            p.flash_ms = 0;
            p.flash_row = null;
        }
        return .redraw;
    }
    return .none;
}

fn restFire(p: *Peek, r: Rest) ?Action {
    switch (r) {
        .head => {
            if (p.frame()) |f| if (f.onhover.len > 0) return .{ .fire = .{ .text = f.text.plain(&p.text_buf), .data = f.data, .function = f.onhover } };
            if (p.mode == .peek) if (p.ui.peek) |*k| if (k.onhover.len > 0) return .{ .fire = .{ .text = k.text.plain(&p.text_buf), .data = k.data, .function = k.onhover } };
        },
        .row => |i| if (i < p.lines().len) {
            const l = &p.lines()[i];
            if (l.onhover.len > 0) return .{ .fire = .{ .id = l.id, .text = l.text.plain(&p.text_buf), .data = l.data, .function = l.onhover } };
        },
    }
    return null;
}

fn partAt(p: *const Peek, x: f32, y: f32) Part {
    if (p.close_r.contains(x, y)) return .close;
    if (p.expand_r.contains(x, y)) return .expand;
    for (p.left_r, 0..) |r, i| if (r.contains(x, y)) return .{ .left = i };
    for (p.right_r, 0..) |r, i| if (r.contains(x, y)) return .{ .right = i };
    var buf: [max_options][]const u8 = undefined;
    const opts = p.optionMatches(&buf);
    for (opts, 0..) |_, i| if (p.optionRect(i).contains(x, y)) return .{ .option = i };
    if (p.rowAt(x, y)) |k| {
        const l = &p.lines()[k];
        if (l.prefixButton != null and p.prefixRect(k).contains(x, y)) return .{ .prefix = k };
        if (l.postButton != null and p.postRect(k).contains(x, y)) return .{ .post = k };
    }
    return .none;
}

/// The mouse moved (anywhere): track the row and button under it, and
/// start / stop the countdown.
pub fn motion(p: *Peek, x: f32, y: f32, now: u64) bool {
    const inside = p.contains(x, y);
    const was = .{ p.leave_ms != 0, p.hover_row, p.over };
    if (inside) p.leave_ms = 0 else if (p.leave_ms == 0) p.leave_ms = now;
    if (!inside) {
        p.hover_ms = 0;
        p.hold = false;
    } else if (!p.hold) p.hover_ms = @max(now, 1); // rests from now
    p.over = if (inside) p.partAt(x, y) else .none;
    p.hover_row = p.rowAt(x, y);
    const rest: ?Rest = if (p.hover_row) |k| .{ .row = k } else if (p.text_r.contains(x, y)) .head else null;
    if (!std.meta.eql(rest, p.rest)) {
        p.rest = rest;
        p.rest_ms = if (rest != null) @max(now, 1) else 0;
    }
    if (p.over == .expand and !std.meta.eql(was[2], p.over) and p.mode == .peek) {
        if (p.ui.peek) |k| if (k.hoverExpand) {
            p.over_expand = true;
        };
    }
    return was[0] != (p.leave_ms != 0) or !std.meta.eql(was[1], p.hover_row) or !std.meta.eql(was[2], p.over);
}

/// What `motion` asked for: App acts on it as on a click.
pub fn takeMotion(p: *Peek) Action {
    if (!p.over_expand) return .none;
    p.over_expand = false;
    p.mode = .epeek;
    p.keys = true;
    p.startList();
    return .expanded;
}

fn rowAt(p: *const Peek, x: f32, y: f32) ?usize {
    if (p.mode != .epeek or !p.list_r.contains(x, y)) return null;
    const k = p.top + @as(usize, @intFromFloat(@floor((y - p.list_r.y) / p.row_h)));
    return if (k < p.lines().len) k else null;
}

/// A left click inside the peek.
pub fn click(p: *Peek, x: f32, y: f32) Action {
    if (p.mode == .epeek) p.keys = true;
    switch (p.partAt(x, y)) {
        .close => return .close,
        .expand => return p.toggleExpand(),
        .left => |i| if (p.leftButton(i)) |b| return p.press(b, p.left_r[i]),
        .right => |i| if (p.rightButton(i)) |b| return p.press(b, p.right_r[i]),
        .prefix => |k| return p.press(&p.lines()[k].prefixButton.?, p.prefixRect(k)),
        .post => |k| return p.press(&p.lines()[k].postButton.?, p.postRect(k)),
        .option => |i| {
            var buf: [max_options][]const u8 = undefined;
            return p.takeOption(p.optionMatches(&buf)[i]);
        },
        .none => {},
    }
    if (p.rowAt(x, y)) |k| {
        p.sel = k;
        return p.pick();
    }
    if (p.text_r.contains(x, y)) {
        p.hold = true;
        p.hover_ms = 0;
        if (p.frame()) |f| {
            if (f.onclick.len > 0) return .{ .fire = .{ .text = f.text.plain(&p.text_buf), .data = f.data, .function = f.onclick } };
            return .none;
        }
        if (p.ui.peek) |*k| {
            if (k.onclick.len > 0) return .{ .fire = .{ .text = k.text.plain(&p.text_buf), .data = k.data, .function = k.onclick } };
            if (p.hasExpand()) return p.toggleExpand();
        }
    }
    return .none;
}

pub fn wheel(p: *Peek, dy: f32) void {
    if (p.mode != .epeek) return;
    const rows = p.visibleRows();
    const max_top = p.lines().len -| rows;
    const n: isize = @intFromFloat(@round(-dy * 2));
    p.top = @intCast(std.math.clamp(@as(isize, @intCast(p.top)) + n, 0, @as(isize, @intCast(max_top))));
}

/// A key while it has the keyboard: arrows move through the list, Enter
/// picks, Esc closes, Tab takes the first option, Backspace edits the
/// filter. Typing keeps it open (the countdown starts over).
pub fn key(p: *Peek, k: c.SDL_Keycode) Action {
    if (p.leave_ms != 0) p.leave_ms = c.SDL_GetTicks();
    switch (k) {
        c.SDLK_ESCAPE => return .close,
        c.SDLK_UP => p.moveSel(-1),
        c.SDLK_DOWN => p.moveSel(1),
        c.SDLK_PAGEUP => p.moveSel(-max_rows),
        c.SDLK_PAGEDOWN => p.moveSel(max_rows),
        c.SDLK_HOME => p.moveSel(-@as(isize, @intCast(p.lines().len))),
        c.SDLK_END => p.moveSel(@intCast(p.lines().len)),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => return p.pick(),
        c.SDLK_TAB => {
            var buf: [max_options][]const u8 = undefined;
            const opts = p.optionMatches(&buf);
            if (opts.len > 0) return p.takeOption(opts[0]);
        },
        c.SDLK_BACKSPACE => if (p.filter.items.len > 0) {
            // Drop the last code point.
            var i = p.filter.items.len - 1;
            while (i > 0 and p.filter.items[i] & 0xc0 == 0x80) i -= 1;
            p.filter.shrinkRetainingCapacity(i);
            return .filter;
        },
        else => return .none,
    }
    return .redraw;
}

/// Typed text goes into the filter.
pub fn text(p: *Peek, s: []const u8) Action {
    if (p.leave_ms != 0) p.leave_ms = c.SDL_GetTicks();
    if (p.filterDesc() == null) return .none;
    for (s) |ch| if (ch >= ' ' or ch >= 0x80) p.filter.append(p.gpa, ch) catch return .redraw;
    return .filter;
}

// ------------------------------------------------------------ layout & draw

fn prefixRect(p: *const Peek, k: usize) Rect {
    const y = p.list_r.y + @as(f32, @floatFromInt(k -| p.top)) * p.row_h;
    return .{ .x = p.list_r.x, .y = y, .w = p.textX() - p.list_r.x, .h = p.row_h };
}

fn postRect(p: *const Peek, k: usize) Rect {
    const y = p.list_r.y + @as(f32, @floatFromInt(k -| p.top)) * p.row_h;
    const s = p.row_h;
    return .{ .x = p.list_r.x + p.list_r.w - s - @round(p.bar_h), .y = y, .w = s, .h = s };
}

fn textX(p: *const Peek) f32 {
    return p.list_r.x + p.cell2;
}

fn optionRect(p: *const Peek, i: usize) Rect {
    return .{ .x = p.filter_r.x, .y = p.filter_r.y + p.filter_r.h + @as(f32, @floatFromInt(i)) * p.row_h, .w = p.filter_r.w, .h = p.row_h };
}

/// A head button's width: an icon alone is square, a word adds to it.
fn buttonW(gfx: *Gfx, f: *Gfx.Face, b: *const sdk.Button, icon: f32, gap: f32) f32 {
    if (b.text.isEmpty() or b.dots != null) return icon;
    return @round((if (b.icon.len > 0) icon else gap) + 2 * gap + text_mod.width(gfx, f, &b.text));
}

/// Size and place the box over the chip, growing up from it; kept on the
/// screen (`bounds`). `f` is the normal text size, `sf` the small one.
pub fn layout(p: *Peek, gfx: *Gfx, f: *Gfx.Face, sf: *Gfx.Face, ui: f32, bounds: Rect) void {
    const pad = @round(6 * ui);
    const gap = @round(5 * ui);
    const icon = @round(f.cell_h * 0.95);
    const head_h = if (p.hasHead()) @round(f.cell_h + 10 * ui) else pad;
    p.icon_s = icon;
    p.bar_h = @max(@round(3 * ui), 2);
    p.row_h = @round(f.cell_h + 4 * ui);
    p.cell2 = f.cell_w * 2;

    var lw: [2]f32 = @splat(0);
    var rw: [2]f32 = @splat(0);
    var buttons_w: f32 = 0;
    for (0..2) |i| {
        if (p.leftButton(i)) |b| lw[i] = buttonW(gfx, f, b, icon, gap);
        if (p.rightButton(i)) |b| rw[i] = buttonW(gfx, f, b, icon, gap);
        if (lw[i] > 0) buttons_w += lw[i] + gap;
        if (rw[i] > 0) buttons_w += rw[i] + gap;
    }
    const expand_w = if (p.hasExpand()) icon + gap else 0;
    var w = pad + buttons_w + expand_w + gap + text_mod.width(gfx, f, p.headText()) + 2 * gap + icon + pad;
    var h = head_h + p.bar_h;
    const msg = p.message();
    const foot = if (p.mode == .epeek) (if (p.ui.epeek) |*e| &e.footer else &blank_text) else &blank_text;
    const has_foot = !foot.isEmpty() and p.lines().len > 0;
    const filter = p.filterDesc();
    var obuf: [max_options][]const u8 = undefined;
    const n_opts = p.optionMatches(&obuf).len;
    if (p.mode == .epeek) {
        var longest: f32 = if (filter) |x| text_mod.width(gfx, f, &x.hint) else 0;
        for (p.lines()) |*l| longest = @max(longest, text_mod.width(gfx, f, &l.text) + (if (l.postButton != null) p.row_h else 0));
        if (p.ui.epeek) |*e| longest = @max(longest, text_mod.width(gfx, f, &e.empty));
        w = @max(w, @max(longest + 2 * f.cell_w + 2 * pad, f.cell_w * 30));
        p.rows = @max(p.visibleRows(), 1);
        if (filter != null) h += f.cell_h + @round(10 * ui);
        h += @as(f32, @floatFromInt(p.rows + n_opts)) * p.row_h + pad;
        if (has_foot) {
            w = @max(w, text_mod.width(gfx, sf, foot) + 2 * pad);
            h += sf.cell_h + pad;
        }
    }
    if (msg.len > 0) {
        var longest: f32 = 0;
        for (msg) |*l| longest = @max(longest, text_mod.width(gfx, sf, l));
        w = @max(w, @min(longest + 2 * pad, f.cell_w * 80));
        h += @as(f32, @floatFromInt(msg.len)) * sf.cell_h + pad;
    }
    w = @min(w, bounds.w - 2 * gap);
    h = @min(h, bounds.h - 2 * gap);

    const x = std.math.clamp(p.anchor.x - pad, bounds.x + gap, bounds.x + bounds.w - gap - w);
    const y = std.math.clamp(p.anchor.y + p.anchor.h - h, bounds.y + gap, bounds.y + bounds.h - h);
    p.box = .{ .x = x, .y = y, .w = w, .h = h };

    p.left_r = @splat(.{});
    p.right_r = @splat(.{});
    p.expand_r = .{};
    p.close_r = .{};
    p.text_r = .{};
    if (p.hasHead()) {
        const iy = y + @round((head_h - icon) / 2);
        var lx = x + pad;
        for (0..2) |i| if (lw[i] > 0) {
            p.left_r[i] = .{ .x = lx, .y = iy, .w = lw[i], .h = icon };
            lx += lw[i] + gap;
        };
        if (p.hasExpand()) {
            p.expand_r = .{ .x = lx, .y = iy, .w = icon, .h = icon };
            lx += icon + gap;
        }
        p.close_r = .{ .x = x + w - pad - icon, .y = iy, .w = icon, .h = icon };
        var rx = p.close_r.x;
        // `right` reads left to right, the × last.
        var i: usize = 2;
        while (i > 0) {
            i -= 1;
            if (rw[i] == 0) continue;
            rx -= gap + rw[i];
            p.right_r[i] = .{ .x = rx, .y = iy, .w = rw[i], .h = icon };
        }
        const tx = lx + gap;
        p.text_r = .{ .x = tx, .y = y, .w = @max(rx - 2 * gap - tx, 0), .h = head_h };
    }

    var cy = y + head_h;
    p.filter_r = .{};
    p.list_r = .{};
    p.foot_r = .{};
    if (p.mode == .epeek) {
        if (filter != null) {
            p.filter_r = .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = f.cell_h + @round(6 * ui) };
            cy += p.filter_r.h + @as(f32, @floatFromInt(n_opts)) * p.row_h + @round(4 * ui);
        }
        p.list_r = .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = @as(f32, @floatFromInt(p.rows)) * p.row_h };
        cy += p.list_r.h + pad;
        if (has_foot) {
            p.foot_r = .{ .x = x + pad, .y = cy - @round(2 * ui), .w = w - 2 * pad, .h = sf.cell_h };
            cy += sf.cell_h + pad;
        }
    }
    p.msg_r = if (msg.len > 0) .{ .x = x + pad, .y = cy, .w = w - 2 * pad, .h = @as(f32, @floatFromInt(msg.len)) * sf.cell_h } else .{};
}

pub fn draw(p: *const Peek, gfx: *Gfx, theme: *const Theme, f: *Gfx.Face, sf: *Gfx.Face, ui: f32, now: u64) void {
    const b = p.box;
    const t = @max(@round(ui), 1);
    gfx.fill(b, theme.title_bg);

    if (p.hasHead()) {
        for (0..2) |i| {
            if (p.leftButton(i)) |x| drawButton(gfx, f, x, p.left_r[i], theme, ui, std.meta.eql(p.over, Part{ .left = i }));
            if (p.rightButton(i)) |x| drawButton(gfx, f, x, p.right_r[i], theme, ui, std.meta.eql(p.over, Part{ .right = i }));
        }
        if (p.expand_r.w > 0) expandIcon(gfx, p.expand_r, theme, ui, p.mode == .epeek, p.over == .expand);
        JobWindow.closeIcon(gfx, p.close_r, theme, ui);
        gfx.clip(p.text_r);
        const hy = p.text_r.y + @round((p.text_r.h - f.cell_h) / 2);
        const title = p.ui.peek == null;
        const tend = text_mod.draw(gfx, f, p.text_r.x, hy, p.headText(), if (title) theme.title_fg else theme.prompt_fg);
        if (p.flash_ms != 0 and p.flash_row == null) {
            const ft = now -| p.flash_ms;
            if (ft < flash_len_ms) {
                const left = 1 - @as(f32, @floatFromInt(ft)) / @as(f32, flash_len_ms);
                const pad = @round(3 * ui);
                gfx.fillAlpha(.{ .x = p.text_r.x - pad, .y = hy - pad, .w = tend - p.text_r.x + 2 * pad, .h = f.cell_h + 2 * pad }, .{ .r = 255, .g = 255, .b = 255 }, @intFromFloat(@round(170 * left)));
            }
        }
        gfx.clip(null);
    }

    if (p.mode == .epeek) {
        // The list.
        const lr = p.list_r;
        gfx.clip(lr);
        const all = p.lines();
        if (all.len == 0) if (p.ui.epeek) |*e| {
            _ = text_mod.draw(gfx, f, lr.x + f.cell_w * 2, lr.y + @round((p.row_h - f.cell_h) / 2), &e.empty, theme.dim);
        };
        var k = p.top;
        while (k < all.len and k < p.top + p.rows) : (k += 1) {
            const l = &all[k];
            const ry = lr.y + @as(f32, @floatFromInt(k - p.top)) * p.row_h;
            const row: Rect = .{ .x = lr.x, .y = ry, .w = lr.w, .h = p.row_h };
            if (k == p.sel) gfx.fill(row, theme.selection) else if (p.hover_row == k) gfx.fill(row, theme.title_bg.mix(theme.fg, 0.08));
            const ty = ry + @round((p.row_h - f.cell_h) / 2);
            if (l.prefixButton) |*x| {
                if (std.mem.eql(u8, x.icon, "dot")) {
                    const d = @round(f.cell_h * 0.32);
                    gfx.disc(lr.x + f.cell_w * 0.9, ry + p.row_h / 2, d / 2, theme.ok);
                } else drawButton(gfx, f, x, iconIn(p.prefixRect(k), p.icon_s), theme, ui, std.meta.eql(p.over, Part{ .prefix = k }));
            }
            _ = text_mod.draw(gfx, f, lr.x + f.cell_w * 2, ty, &l.text, theme.prompt_fg);
            if (l.postButton) |*x| drawButton(gfx, f, x, iconIn(p.postRect(k), p.icon_s), theme, ui, std.meta.eql(p.over, Part{ .post = k }));
            if (p.flash_ms != 0 and p.flash_row == k) {
                const ft = now -| p.flash_ms;
                if (ft < flash_len_ms) {
                    const left = 1 - @as(f32, @floatFromInt(ft)) / @as(f32, flash_len_ms);
                    gfx.fillAlpha(row, .{ .r = 255, .g = 255, .b = 255 }, @intFromFloat(@round(170 * left)));
                }
            }
        }
        gfx.clip(null);
        // More rows than fit: a thin scroll mark on the right.
        if (all.len > p.rows) {
            const n: f32 = @floatFromInt(all.len);
            const th = @max(lr.h * @as(f32, @floatFromInt(p.rows)) / n, 8 * ui);
            const ty = lr.y + (lr.h - th) * @as(f32, @floatFromInt(p.top)) / @max(n - @as(f32, @floatFromInt(p.rows)), 1);
            gfx.fill(.{ .x = lr.x + lr.w - @round(3 * ui), .y = ty, .w = @round(3 * ui), .h = th }, theme.dim);
        }

        // The filter box: the typed text and a caret, or the hint while
        // empty; the caret only with the keyboard.
        if (p.filterDesc()) |desc| {
            const fr = p.filter_r;
            gfx.fill(fr, theme.bg);
            gfx.outline(fr, if (p.keys) theme.focus else theme.dim, t);
            const fy = fr.y + @round((fr.h - f.cell_h) / 2);
            const fx = fr.x + @round(5 * ui);
            gfx.clip(fr);
            const end = if (p.filter.items.len == 0) blk: {
                _ = text_mod.draw(gfx, f, fx, fy, &desc.hint, theme.dim);
                break :blk fx;
            } else gfx.text(f, fx, fy, p.filter.items, theme.prompt_fg);
            if (p.keys) gfx.fill(.{ .x = end, .y = fy, .w = @max(@round(f.cell_w * 0.12), 2), .h = f.cell_h }, theme.cursor);
            gfx.clip(null);
            // The help list, in rows of its own under the box.
            var obuf: [max_options][]const u8 = undefined;
            for (p.optionMatches(&obuf), 0..) |o, i| {
                const r = p.optionRect(i);
                gfx.fill(r, if (std.meta.eql(p.over, Part{ .option = i })) theme.selection else theme.bg.mix(theme.title_bg, 0.5));
                _ = gfx.text(f, r.x + @round(5 * ui), r.y + @round((r.h - f.cell_h) / 2), o, if (i == 0) theme.prompt_fg else theme.dim);
            }
        }
    }

    if (p.foot_r.h > 0) if (p.ui.epeek) |*e| {
        gfx.clip(p.foot_r);
        _ = text_mod.draw(gfx, sf, p.foot_r.x, p.foot_r.y, &e.footer, theme.dim);
        gfx.clip(null);
    };

    // How the action is going.
    const st = p.state();
    const edge: Rgb = switch (st) {
        .idle => theme.title_fg.mix(theme.title_bg, 0.45),
        .busy => theme.focus,
        .ok => theme.ok,
        .err => theme.stderr_accent,
    };
    if (p.msg_r.h > 0) {
        gfx.clip(p.msg_r);
        var y = p.msg_r.y;
        for (p.message()) |*l| {
            _ = text_mod.draw(gfx, sf, p.msg_r.x, y, l, if (st == .idle) theme.dim else edge);
            y += sf.cell_h;
        }
        gfx.clip(null);
    }

    // Border: thin, colored by the action's result; the bottom one thicker,
    // doubling as the countdown bar (empties right to left).
    const thick = if (st == .idle) t else 2 * t;
    gfx.outline(b, edge, thick);
    const bar: Rect = .{ .x = b.x, .y = b.y + b.h - p.bar_h, .w = b.w, .h = p.bar_h };
    gfx.fill(bar, edge);
    if (p.leave_ms != 0 and st != .busy) {
        const left = 1 - @min(@as(f32, @floatFromInt(now -| p.leave_ms)) / @as(f32, @floatFromInt(@max(dismiss_ms, 1))), 1);
        gfx.fill(bar, theme.title_bg.mix(edge, 0.3));
        gfx.fill(.{ .x = bar.x, .y = bar.y, .w = @round(bar.w * left), .h = bar.h }, theme.focus);
    }
}

/// An icon's square in the middle of `r`.
fn iconIn(r: Rect, s: f32) Rect {
    return .{ .x = r.x + @round((r.w - s) / 2), .y = r.y + @round((r.h - s) / 2), .w = s, .h = s };
}

/// A button: only what it has. With a word: on a light face (as the title
/// bar's actions), lighter with a frame under the mouse. An icon with no
/// `onclick` is only an icon.
fn drawButton(gfx: *Gfx, f: *Gfx.Face, b: *const sdk.Button, r: Rect, theme: *const Theme, ui: f32, hot: bool) void {
    const t = @max(@round(ui), 1);
    const live = b.onclick.len > 0 or b.dots != null;
    if (b.dots) |d| {
        if (hot) gfx.fill(r, theme.title_bg.mix(theme.fg, 0.16));
        const cx = r.x + r.w / 2;
        const cy = r.y + r.h / 2;
        const rad = @max(r.h * 0.07, 1);
        const step = r.h * 0.26;
        for ([_]f32{ -1, 0, 1 }) |k| {
            if (d == .vertical) gfx.disc(cx, cy + k * step, rad, theme.title_fg) else gfx.disc(cx + k * step, cy, rad, theme.title_fg);
        }
        return;
    }
    if (!b.text.isEmpty()) {
        gfx.fill(r, theme.title_bg.mix(theme.fg, if (hot) 0.22 else 0.12));
        if (hot) gfx.outline(r, theme.title_fg, t);
        const x = if (b.icon.len > 0) blk: {
            const s = @round(r.h * 0.62);
            drawIcon(gfx, b.icon, .{ .x = r.x + @round((r.h - s) / 2), .y = r.y + @round((r.h - s) / 2), .w = s, .h = s }, theme, ui);
            break :blk r.x + r.h;
        } else r.x + @round(5 * ui);
        _ = text_mod.draw(gfx, f, x, r.y + @round((r.h - f.cell_h) / 2), &b.text, theme.title_fg);
        return;
    }
    if (std.mem.eql(u8, b.icon, "copy")) {
        JobWindow.copyIcon(gfx, r, theme, ui);
    } else drawIcon(gfx, b.icon, iconIn(r, @round(r.h * 0.62)), theme, ui);
    if (hot and live) gfx.outline(r, theme.title_fg, t);
}

/// The standard icons drawn here; an unknown name draws nothing.
fn drawIcon(gfx: *Gfx, name: []const u8, d: Rect, theme: *const Theme, ui: f32) void {
    const t = @max(@round(ui), 1);
    const s = d.w;
    // The disk: a square, the shutter on top, the label below.
    if (std.mem.eql(u8, name, "save")) {
        gfx.outline(d, theme.title_fg, t);
        gfx.fill(.{ .x = d.x + @round(s * 0.25), .y = d.y, .w = @round(s * 0.45), .h = @round(s * 0.3) }, theme.title_fg);
        gfx.outline(.{ .x = d.x + @round(s * 0.18), .y = d.y + @round(s * 0.55), .w = s - 2 * @round(s * 0.18), .h = s - @round(s * 0.55) }, theme.title_fg, t);
    } else if (std.mem.eql(u8, name, "list")) {
        // Three rows, each a dot and a line.
        for (0..3) |k| {
            const y = d.y + @round(@as(f32, @floatFromInt(k)) * (s - t) / 2);
            gfx.fill(.{ .x = d.x, .y = y, .w = t * 2, .h = t }, theme.title_fg);
            gfx.fill(.{ .x = d.x + t * 3, .y = y, .w = s - t * 3, .h = t }, theme.title_fg);
        }
    } else if (std.mem.eql(u8, name, "dot")) {
        gfx.disc(d.x + s / 2, d.y + s / 2, s * 0.25, theme.ok);
    }
}

/// A chevron: up (grow into the list) on a peek, down on an epeek.
fn expandIcon(gfx: *Gfx, r: Rect, theme: *const Theme, ui: f32, expanded: bool, hot: bool) void {
    gfx.fill(r, theme.title_bg.mix(theme.fg, if (hot) 0.16 else 0.07));
    const t = @max(@round(1.5 * ui), 1);
    const mx = r.x + r.w / 2;
    const dx = r.w * 0.28;
    const dy = r.h * 0.16;
    const cy = r.y + r.h / 2;
    const tip_y = if (expanded) cy + dy else cy - dy;
    const arm_y = if (expanded) cy - dy else cy + dy;
    gfx.line(mx - dx, arm_y, mx, tip_y, theme.title_fg, t);
    gfx.line(mx, tip_y, mx + dx, arm_y, theme.title_fg, t);
}

fn testUi(u: *ChipUi) !void {
    const rows = [_]sdk.Line{
        .{ .id = "a", .text = sdk.newText("alpha"), .onclick = "pick", .data = "A" },
        .{ .id = "b", .text = sdk.newText("beta"), .onclick = "pick", .data = "B", .postButton = .{ .dots = .vertical, .onclick = "more", .items = &.{.{ .id = "x", .text = sdk.newText("X") }} } },
    };
    try u.setPeek(.{ .expand = .{ .set = true }, .text = .{ .set = sdk.newText("title") }, .onexpand = .{ .set = "load" } });
    try u.setEpeek(.{ .lines = .{ .set = &rows }, .selected = .{ .set = 1 }, .frame = .{ .set = .{ .filter = .{ .onclick = "filter", .options = &.{ "feature/", "fix/" } } } } });
}

test "a pick fires the line's onclick; Enter the selected one" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try testUi(&u);
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .epeek, true);
    defer p.deinit();
    try t.expectEqual(@as(usize, 1), p.sel);
    try t.expect(p.wantsKeys());
    const a = p.key(c.SDLK_RETURN);
    try t.expectEqualStrings("B", a.fire.data);
    try t.expectEqualStrings("pick", a.fire.function);
    try t.expectEqualStrings("beta", a.fire.text);
    _ = p.key(c.SDLK_UP);
    try t.expectEqualStrings("A", p.key(c.SDLK_RETURN).fire.data);
}

test "the filter only reports: the list stays until the extension answers" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try testUi(&u);
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .epeek, true);
    defer p.deinit();
    try t.expect(p.text("fe") == .filter);
    try t.expectEqual(@as(usize, 2), p.lines().len);
    try t.expect(p.key(c.SDLK_TAB) == .filter);
    try t.expectEqualStrings("feature/", p.filter.items);
    try t.expect(p.key(c.SDLK_BACKSPACE) == .filter);
    try t.expectEqualStrings("feature", p.filter.items);
}

test "with no filter typing does nothing; no keyboard unless given" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try u.setEpeek(.{ .lines = .{ .set = &.{.{ .text = sdk.newText("x") }} } });
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .epeek, false);
    defer p.deinit();
    try t.expect(!p.wantsKeys());
    try t.expect(p.text("a") == .none);
    try t.expect(!p.hasHead());
}

test "expand: only with an epeek; the peek's text expands with no onclick" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try u.setPeek(.{ .expand = .{ .set = true }, .text = .{ .set = sdk.newText("x") } });
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .peek, true);
    defer p.deinit();
    try t.expect(!p.hasExpand());
    try testUi(&u);
    try t.expect(p.hasExpand());
    p.box = .{ .w = 100, .h = 20 };
    p.text_r = .{ .x = 40, .w = 40, .h = 20 };
    try t.expect(p.click(50, 5) == .expanded);
    try t.expectEqual(Mode.epeek, p.mode);
    try t.expect(p.wantsKeys());
}

test "hoverExpand: resting on the peek expands, a click on the text holds it off" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try testUi(&u);
    try u.setPeek(.{ .hoverExpand = .{ .set = true }, .onclick = .{ .set = "copy" } });
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .peek, true);
    defer p.deinit();
    p.box = .{ .w = 100, .h = 20 };
    p.text_r = .{ .x = 40, .w = 40, .h = 20 };
    _ = p.motion(50, 5, 1);
    try t.expectEqualStrings("copy", p.click(50, 5).fire.function);
    try t.expect(p.tick(1 + expand_hover_ms) != .expanded);
    _ = p.motion(200, 5, 600);
    _ = p.motion(50, 5, 700);
    try t.expect(p.tick(700 + expand_hover_ms - 1) != .expanded);
    try t.expect(p.tick(700 + expand_hover_ms) == .expanded);
}

test "ok closes after a second; a change of lines starts the selection over" {
    const t = std.testing;
    var u: ChipUi = .{ .gpa = t.allocator };
    defer u.deinit();
    try testUi(&u);
    var p = Peek.open(t.allocator, 1, 0, &u, .{}, .epeek, true);
    defer p.deinit();
    _ = p.key(c.SDLK_UP);
    try u.setEpeek(.{ .state = .{ .set = .ok } });
    p.refresh(100);
    try t.expectEqual(@as(usize, 0), p.sel);
    try t.expect(p.tick(100 + ok_ms - 1) != .close);
    try t.expect(p.tick(100 + ok_ms) == .close);
    try u.setEpeek(.{ .lines = .{ .set = &.{.{ .text = sdk.newText("only") }} }, .selected = .{ .set = 0 } });
    p.refresh(5000);
    try t.expectEqual(@as(usize, 0), p.sel);
    try t.expectEqual(@as(usize, 1), p.lines().len);
}
