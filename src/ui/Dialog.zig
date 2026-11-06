// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A chip's dialog (docs/extensions.md, "Dialogs"): centered in its job
//! window and modal to it. The chip describes it (`apply`), this draws it
//! and runs it: layout (`place`), keys, clicks and the controls' state are
//! all here, so it works whatever the chip does.
//!
//!   * Layouts: `form` (one field per line, labels in a column), `grid`
//!     (label: value one after the other, wrapping, a gap after each
//!     control), `table` (`columns` × `rows` cells, filled in order).
//!   * Widgets: text box (a LineEdit), check box, drop box (optional
//!     filter), plain text.
//!   * Buttons (`ok`, `okcancel`, `yesno`) only report: the chip closes
//!     the dialog. After a press they wait (`locked`) for its answer.
//!   * The × in the frame is a kill, and so is the timeout: `key` / `click`
//!     / `expired` say so, App closes it without asking the chip. The
//!     frame always shows whose dialog it is (`owner`).
//!
//! JobWindow owns its dialogs; App routes keys and the mouse here.

const std = @import("std");
const text_mod = @import("text.zig");
const sdk = @import("gtty");
const Gfx = @import("../render/Gfx.zig");
const color = @import("../core/color.zig");
const c = @import("../c.zig").c;
const LineEdit = @import("LineEdit.zig");
const Modal = @import("Modal.zig");

const Dialog = @This();
const Rect = Gfx.Rect;
const Theme = color.Theme;

pub const default_timeout_s = 30;
pub const max_timeout_s = 600;
const list_rows = 8;
const control_cols = 28;

pub const Button = enum {
    ok,
    cancel,
    yes,
    no,

    pub fn label(b: Button) []const u8 {
        return switch (b) {
            .ok => "OK",
            .cancel => "Cancel",
            .yes => "Yes",
            .no => "No",
        };
    }
};

/// What an input did.
pub const Outcome = union(enum) {
    /// Not the dialog's (the key goes on).
    none,
    handled,
    press: Button,
    kill,
};

const Widget = struct {
    id: []const u8,
    kind: sdk.WidgetType = .text,
    /// As plain text (the layout measures it) and as set.
    label: []const u8 = "",
    label_text: sdk.Text = .{},
    edit: LineEdit = .{},
    on: bool = false,
    /// A drop box's value.
    value: []const u8 = "",
    options: []const []const u8 = &.{},
    filter: bool = false,
    label_r: Rect = .{},
    ctl_r: Rect = .{},
};

/// An open drop box's list.
const List = struct {
    widget: usize,
    edit: LineEdit = .{},
    /// The selected row and the first shown, among the matching options.
    hi: usize = 0,
    top: usize = 0,
};

/// What `place` needs of the fonts (both monospaced).
pub const Metrics = struct {
    cell_w: f32,
    cell_h: f32,
    small_w: f32,
    small_h: f32,
    ui: f32,
};

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
owner: []const u8,
title: []const u8 = "",
title_text: sdk.Text = .{},
layout: sdk.Layout = .form,
columns: u16 = 2,
rows: u16 = 0,
widgets: std.ArrayList(Widget) = .empty,
buttons: sdk.ButtonSet = .ok,
onclick: ?[]const u8 = null,
timeout_s: u32 = default_timeout_s,
err: []const u8 = "",
/// A widget, then the buttons.
focus: usize = 0,
/// Has the keyboard. Only after the user acted on it: a dialog opening by
/// itself never catches what is being typed in the shell.
keyboard: bool = false,
/// A button was pressed and the chip hasn't answered yet.
locked: bool = false,
/// When it opened, or the user last touched it (the countdown's start).
touched_ms: u64 = 0,
list: ?List = null,
scroll: f32 = 0,
mouse: ?[2]f32 = null,
// From `place`.
box: Rect = .{},
close_r: Rect = .{},
body_r: Rect = .{},
list_r: Rect = .{},
content_h: f32 = 0,
btn_r: [2]Rect = .{ .{}, .{} },

pub fn create(gpa: std.mem.Allocator, owner: []const u8) !*Dialog {
    const d = try gpa.create(Dialog);
    d.* = .{ .gpa = gpa, .arena = .init(gpa), .owner = owner };
    return d;
}

pub fn destroy(d: *Dialog) void {
    d.widgets.deinit(d.gpa);
    d.arena.deinit();
    d.gpa.destroy(d);
}

fn dupe(d: *Dialog, s: []const u8) []const u8 {
    return d.arena.allocator().dupe(u8, s) catch "";
}

/// A copy of `t`, and its strings joined in `plain`.
fn dupeText(d: *Dialog, t: sdk.Text, plain: *[]const u8) sdk.Text {
    var out = t;
    var all: std.ArrayList(u8) = .empty;
    const a = d.arena.allocator();
    for (out.parts[0..out.len]) |*p| {
        p.string = d.dupe(p.string);
        all.appendSlice(a, p.string) catch {};
    }
    plain.* = all.items;
    return out;
}

/// The chip's description, or a change to it. It also ends the wait after
/// a button.
pub fn apply(d: *Dialog, u: sdk.DialogUpdate) void {
    if (u.title) |s| d.title_text = d.dupeText(s, &d.title);
    if (u.layout) |v| d.layout = v;
    if (u.columns) |v| d.columns = @max(v, 1);
    if (u.rows) |v| d.rows = v;
    if (u.buttons) |v| d.buttons = v;
    if (u.onclick) |s| d.onclick = d.dupe(s);
    if (u.timeout) |v| d.timeout_s = std.math.clamp(v, 1, max_timeout_s);
    if (u.err) |e| d.err = switch (e) {
        .set => |s| d.dupe(s),
        .clear => "",
    };
    for (u.fields) |f| d.applyField(f);
    d.locked = false;
}

fn applyField(d: *Dialog, f: sdk.Widget) void {
    const w = for (d.widgets.items) |*x| {
        if (std.mem.eql(u8, x.id, f.id)) break x;
    } else blk: {
        d.widgets.append(d.gpa, .{ .id = d.dupe(f.id) }) catch return;
        break :blk &d.widgets.items[d.widgets.items.len - 1];
    };
    if (f.type) |k| w.kind = k;
    if (f.label) |s| w.label_text = d.dupeText(s, &w.label);
    if (f.filter) |v| w.filter = v;
    if (f.options) |opts| {
        const a = d.arena.allocator();
        const copy = a.alloc([]const u8, opts.len) catch return;
        for (opts, copy) |o, *dst| dst.* = d.dupe(o);
        w.options = copy;
    }
    if (f.value) |v| switch (v) {
        .on => |b| w.on = b,
        .text => |s| {
            w.edit = LineEdit.init(s);
            w.value = d.dupe(s);
        },
    };
}

/// It opens: the first control has the focus, a text box's text selected.
pub fn show(d: *Dialog, now: u64, keyboard: bool) void {
    d.keyboard = keyboard;
    d.touched_ms = now;
    d.focus = d.widgets.items.len + d.buttonList().len - 1; // no control: the primary button
    for (d.widgets.items, 0..) |*w, i| if (w.kind != .label) {
        d.focus = i;
        if (w.kind == .text) w.edit.selectAll();
        break;
    };
}

fn buttonList(d: *const Dialog) []const Button {
    return switch (d.buttons) {
        .ok => &.{.ok},
        .okcancel => &.{ .cancel, .ok },
        .yesno => &.{ .no, .yes },
    };
}

/// What Enter presses.
fn primary(d: *const Dialog) Button {
    const b = d.buttonList();
    return b[b.len - 1];
}

/// What Esc presses (with `ok` alone, `ok`).
fn safe(d: *const Dialog) Button {
    return d.buttonList()[0];
}

pub fn expired(d: *const Dialog, now: u64) bool {
    return now -| d.touched_ms >= @as(u64, d.timeout_s) * 1000;
}

fn touch(d: *Dialog, now: u64) void {
    d.touched_ms = now;
    d.err = "";
}

fn press(d: *Dialog, b: Button) Outcome {
    if (d.locked) return .handled;
    d.locked = true;
    return .{ .press = b };
}

fn focusedWidget(d: *Dialog) ?*Widget {
    return if (d.focus < d.widgets.items.len) &d.widgets.items[d.focus] else null;
}

fn step(d: *Dialog, back: bool) void {
    const n = d.widgets.items.len + d.buttonList().len;
    var i = d.focus;
    for (0..n) |_| {
        i = if (back) (i + n - 1) % n else (i + 1) % n;
        if (i >= d.widgets.items.len or d.widgets.items[i].kind != .label) break;
    }
    d.focus = i;
    if (d.focusedWidget()) |w| if (w.kind == .text) w.edit.selectAll();
}

/// A key. `.none`: not the dialog's.
pub fn key(d: *Dialog, k: c.SDL_Keycode, mod: c.SDL_Keymod, now: u64) Outcome {
    if (d.list != null) return d.listKey(k, mod, now);
    const shift = mod & c.SDL_KMOD_SHIFT != 0;
    switch (k) {
        c.SDLK_ESCAPE => return d.press(d.safe()),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => {
            const n = d.widgets.items.len;
            return d.press(if (d.focus >= n) d.buttonList()[d.focus - n] else d.primary());
        },
        c.SDLK_TAB => {
            d.step(shift);
            d.touch(now);
            return .handled;
        },
        else => {},
    }
    const w = d.focusedWidget() orelse {
        switch (k) {
            c.SDLK_LEFT, c.SDLK_RIGHT => d.step(k == c.SDLK_LEFT),
            c.SDLK_SPACE => return d.press(d.buttonList()[d.focus - d.widgets.items.len]),
            else => return .none,
        }
        d.touch(now);
        return .handled;
    };
    switch (w.kind) {
        .text => if (!Modal.editKey(&w.edit, k, mod)) return .none,
        .checkbox => {
            if (k != c.SDLK_SPACE) return .none;
            w.on = !w.on;
        },
        .dropdown => {
            if (k != c.SDLK_SPACE and k != c.SDLK_DOWN) return .none;
            d.openList(d.focus);
        },
        .label => return .none,
    }
    d.touch(now);
    return .handled;
}

fn listKey(d: *Dialog, k: c.SDL_Keycode, mod: c.SDL_Keymod, now: u64) Outcome {
    const l = &d.list.?;
    d.touch(now);
    switch (k) {
        c.SDLK_ESCAPE => d.list = null,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => d.pickRow(l.hi),
        c.SDLK_UP => d.moveRow(-1),
        c.SDLK_DOWN => d.moveRow(1),
        else => {
            if (d.widgets.items[l.widget].filter and Modal.editKey(&l.edit, k, mod)) {
                l.hi = 0;
                l.top = 0;
            }
        },
    }
    return .handled;
}

fn openList(d: *Dialog, i: usize) void {
    d.list = .{ .widget = i };
    const w = &d.widgets.items[i];
    for (w.options, 0..) |o, n| if (std.mem.eql(u8, o, w.value)) {
        d.list.?.hi = n;
        d.list.?.top = n -| (list_rows - 1);
    };
}

/// The filter's text, in `buf`.
fn filterText(l: *const List, buf: []u8) []const u8 {
    return l.edit.text(buf);
}

fn matches(o: []const u8, f: []const u8) bool {
    return f.len == 0 or std.ascii.indexOfIgnoreCase(o, f) != null;
}

/// The options the filter leaves.
fn matchCount(d: *const Dialog, l: *const List) usize {
    var fbuf: [1024]u8 = undefined;
    const f = filterText(l, &fbuf);
    var n: usize = 0;
    for (d.widgets.items[l.widget].options) |o| n += @intFromBool(matches(o, f));
    return n;
}

/// The `row`-th option the filter leaves.
fn matchAt(d: *const Dialog, l: *const List, row: usize) ?[]const u8 {
    var fbuf: [1024]u8 = undefined;
    const f = filterText(l, &fbuf);
    var n: usize = 0;
    for (d.widgets.items[l.widget].options) |o| if (matches(o, f)) {
        if (n == row) return o;
        n += 1;
    };
    return null;
}

fn moveRow(d: *Dialog, delta: i32) void {
    const l = &d.list.?;
    const n = d.matchCount(l);
    if (n == 0) return;
    const to: i64 = std.math.clamp(@as(i64, @intCast(l.hi)) + delta, 0, @as(i64, @intCast(n - 1)));
    l.hi = @intCast(to);
    if (l.hi < l.top) l.top = l.hi;
    if (l.hi >= l.top + list_rows) l.top = l.hi + 1 - list_rows;
}

fn pickRow(d: *Dialog, row: usize) void {
    const l = &d.list.?;
    if (d.matchAt(l, row)) |o| d.widgets.items[l.widget].value = o;
    d.list = null;
}

/// Typed or pasted text.
pub fn typed(d: *Dialog, s: []const u8, now: u64) void {
    if (d.list) |*l| {
        if (!d.widgets.items[l.widget].filter) return;
        l.edit.insert(s);
        l.hi = 0;
        l.top = 0;
        d.touch(now);
        return;
    }
    const w = d.focusedWidget() orelse return;
    if (w.kind != .text) return;
    w.edit.insert(s);
    d.touch(now);
}

/// The selected text of the focused text box, in `buf`.
pub fn selectedText(d: *Dialog, buf: []u8) []const u8 {
    const w = d.focusedWidget() orelse return "";
    return if (w.kind == .text) w.edit.selectedText(buf) else "";
}

pub fn contains(d: *const Dialog, x: f32, y: f32) bool {
    return d.box.contains(x, y) or (d.list != null and d.list_r.contains(x, y));
}

/// A left click on the dialog.
pub fn click(d: *Dialog, x: f32, y: f32, m: Metrics, now: u64) Outcome {
    d.keyboard = true;
    d.touch(now);
    if (d.close_r.contains(x, y)) return .kill;
    if (d.list) |*l| {
        if (d.list_r.contains(x, y)) {
            const line = @round(m.cell_h * 1.4);
            const row = (y - d.list_r.y - listHead(&d.widgets.items[l.widget], m.cell_h)) / line;
            if (row >= 0) d.pickRow(l.top + @as(usize, @intFromFloat(row)));
            return .handled;
        }
        d.list = null;
    }
    const n = d.widgets.items.len;
    for (d.buttonList(), 0..) |b, i| if (d.btn_r[i].contains(x, y)) {
        d.focus = n + i;
        return d.press(b);
    };
    if (!d.body_r.contains(x, y)) return .handled;
    for (d.widgets.items, 0..) |*w, i| {
        if (w.kind == .label) continue;
        if (!w.ctl_r.contains(x, y) and !w.label_r.contains(x, y)) continue;
        d.focus = i;
        switch (w.kind) {
            .text => {
                const inner = w.ctl_r.inset(@round(6 * m.ui));
                const fit: usize = @intFromFloat(@max(@floor(inner.w / m.cell_w), 1));
                const at = @max(@round((x - inner.x) / m.cell_w), 0);
                const pos = Modal.fieldFirst(&w.edit, fit) + @as(usize, @intFromFloat(at));
                w.edit.select(pos, pos);
            },
            .checkbox => w.on = !w.on,
            .dropdown => d.openList(i),
            .label => {},
        }
        break;
    }
    return .handled;
}

pub fn wheel(d: *Dialog, dy: f32, m: Metrics) void {
    if (d.list != null) return d.moveRow(if (dy > 0) -1 else 1);
    const most = @max(d.content_h - d.body_r.h, 0);
    d.scroll = std.math.clamp(d.scroll - dy * m.cell_h * 2, 0, most);
}

/// The values, for a button's click (strings in `a`).
pub fn values(d: *const Dialog, a: std.mem.Allocator) []const sdk.FieldValue {
    var out: std.ArrayList(sdk.FieldValue) = .empty;
    for (d.widgets.items) |*w| {
        const v: sdk.Value = switch (w.kind) {
            .label => continue,
            .checkbox => .{ .on = w.on },
            .dropdown => .{ .text = w.value },
            .text => blk: {
                const buf = a.alloc(u8, LineEdit.max * 4) catch continue;
                break :blk .{ .text = w.edit.text(buf) };
            },
        };
        out.append(a, .{ .id = w.id, .value = v }) catch {};
    }
    return out.items;
}

fn cols(s: []const u8) f32 {
    const n = std.unicode.utf8CountCodepoints(s) catch s.len;
    return @floatFromInt(n);
}

fn controlW(w: *const Widget, m: Metrics, room: f32) f32 {
    return switch (w.kind) {
        .checkbox => @round(m.cell_h * 1.2),
        else => @min(control_cols * m.cell_w, room),
    };
}

fn labelH(w: *const Widget, line_h: f32) f32 {
    return @as(f32, @floatFromInt(std.mem.count(u8, w.label, "\n") + 1)) * line_h;
}

/// Where everything goes, centered in `area`.
pub fn place(d: *Dialog, area: Rect, m: Metrics) void {
    const pad = @round(14 * m.ui);
    const gap = @round(10 * m.ui);
    const row_h = @round(m.cell_h * 1.7);
    const row_gap = @round(6 * m.ui);
    const line_h = @round(m.cell_h * 1.3);
    const title_h = @round(m.small_h * 1.8);
    const btn_h = @round(m.cell_h * 1.6);
    const bar_h = @max(@round(3 * m.ui), 2);
    const room = @max(area.w - 2 * gap - 2 * pad, 8 * m.cell_w);
    const ws = d.widgets.items;

    // Everything relative to the body's top left.
    var content_w: f32 = 0;
    var content_h: f32 = 0;
    switch (d.layout) {
        .form => {
            var lw: f32 = 0;
            for (ws) |*w| if (w.kind != .label) {
                lw = @max(lw, cols(w.label) * m.cell_w);
            };
            var y: f32 = 0;
            for (ws) |*w| {
                if (w.kind == .label) {
                    const h = labelH(w, line_h);
                    w.label_r = .{ .x = 0, .y = y, .w = room, .h = h };
                    w.ctl_r = .{};
                    content_w = @max(content_w, @min(cols(w.label) * m.cell_w, room));
                    y += h + row_gap;
                    continue;
                }
                const cw = controlW(w, m, room - lw - gap);
                w.label_r = .{ .x = 0, .y = y, .w = lw, .h = row_h };
                w.ctl_r = .{ .x = lw + gap, .y = y, .w = cw, .h = row_h };
                content_w = @max(content_w, lw + gap + cw);
                y += row_h + row_gap;
            }
            content_h = y - row_gap;
        },
        .grid => {
            var x: f32 = 0;
            var y: f32 = 0;
            for (ws) |*w| {
                const lw = cols(w.label) * m.cell_w + (if (w.kind == .label) 0 else m.cell_w);
                const cw = if (w.kind == .label) 0 else controlW(w, m, room - lw - gap);
                const item = lw + (if (cw > 0) gap + cw else 0);
                if (x > 0 and x + item > room) {
                    x = 0;
                    y += row_h + row_gap;
                }
                w.label_r = .{ .x = x, .y = y, .w = lw, .h = row_h };
                w.ctl_r = if (cw > 0) .{ .x = x + lw + gap, .y = y, .w = cw, .h = row_h } else .{};
                content_w = @max(content_w, x + item);
                x += item + 2 * pad; // the space after the control
            }
            content_h = y + row_h;
        },
        .table => {
            const n_cols: usize = d.columns;
            const shown = if (d.rows > 0) @min(ws.len, n_cols * d.rows) else ws.len;
            const col_room = (room - gap * @as(f32, @floatFromInt(n_cols - 1))) / @as(f32, @floatFromInt(n_cols));
            var x: f32 = 0;
            for (0..n_cols) |col| {
                var lw: f32 = 0;
                var i = col;
                while (i < shown) : (i += n_cols) lw = @max(lw, cols(ws[i].label) * m.cell_w);
                lw = @min(lw, col_room / 2);
                var cw: f32 = 0;
                i = col;
                while (i < shown) : (i += n_cols) if (ws[i].kind != .label) {
                    cw = @max(cw, controlW(&ws[i], m, col_room - lw - gap));
                };
                i = col;
                while (i < shown) : (i += n_cols) {
                    const y = @as(f32, @floatFromInt(i / n_cols)) * (row_h + row_gap);
                    ws[i].label_r = .{ .x = x, .y = y, .w = lw, .h = row_h };
                    ws[i].ctl_r = if (ws[i].kind == .label) .{} else .{ .x = x + lw + gap, .y = y, .w = controlW(&ws[i], m, col_room - lw - gap), .h = row_h };
                }
                x += lw + gap + cw + 2 * pad;
            }
            for (ws[shown..]) |*w| {
                w.label_r = .{};
                w.ctl_r = .{};
            }
            content_w = x - 2 * pad;
            const n_rows = (shown + n_cols - 1) / n_cols;
            content_h = @as(f32, @floatFromInt(n_rows)) * (row_h + row_gap) - row_gap;
        },
    }
    content_h = @max(content_h, 0);
    d.content_h = content_h;

    var btns_w: f32 = 0;
    for (d.buttonList()) |b| btns_w += cols(b.label()) * m.cell_w + 2 * pad + pad / 2;
    const foot_w = btns_w + 16 * m.small_w;
    const head_w = (cols(d.title) + cols(d.owner) + 6) * m.small_w;
    const err_h = if (d.err.len > 0) line_h else 0;
    const err_w = cols(d.err) * m.cell_w;
    const bw = @round(@min(@max(@max(@max(content_w, foot_w), @max(head_w, err_w)) + 2 * pad, @round(360 * m.ui)), area.w - 2 * gap));
    const fixed = title_h + pad + err_h + pad + btn_h + pad + bar_h;
    const body_h = @round(@max(@min(content_h, area.h - 2 * gap - fixed), row_h));
    const bh = body_h + fixed;
    const box: Rect = .{
        .x = @round(area.x + (area.w - bw) / 2),
        .y = @round(area.y + @max((area.h - bh) / 2, 0)),
        .w = bw,
        .h = bh,
    };
    d.box = box;
    const cs = @round(title_h * 0.7);
    d.close_r = .{ .x = box.x + box.w - cs - @round(4 * m.ui), .y = box.y + @round((title_h - cs) / 2), .w = cs, .h = cs };
    d.body_r = .{ .x = box.x + pad, .y = box.y + title_h + pad, .w = box.w - 2 * pad, .h = body_h };
    d.scroll = std.math.clamp(d.scroll, 0, @max(content_h - body_h, 0));
    for (ws) |*w| {
        w.label_r.x += d.body_r.x;
        w.label_r.y += d.body_r.y - d.scroll;
        if (w.ctl_r.w > 0) {
            w.ctl_r.x += d.body_r.x;
            w.ctl_r.y += d.body_r.y - d.scroll;
        }
    }
    // Buttons, right-aligned in order.
    const by = d.body_r.y + body_h + err_h + pad;
    var bx = box.x + box.w - pad;
    const list = d.buttonList();
    var i = list.len;
    while (i > 0) {
        i -= 1;
        const w = cols(list[i].label()) * m.cell_w + 2 * pad;
        bx -= w;
        d.btn_r[i] = .{ .x = bx, .y = by, .w = w, .h = btn_h };
        bx -= pad / 2;
    }
    if (d.list) |*l| d.placeList(l, area, m);
}

/// The filter's row on top of a drop box's list.
fn listHead(w: *const Widget, cell_h: f32) f32 {
    return if (w.filter) @round(cell_h * 1.7) else 0;
}

fn placeList(d: *Dialog, l: *const List, area: Rect, m: Metrics) void {
    const w = &d.widgets.items[l.widget];
    const line = @round(m.cell_h * 1.4);
    const rows = @max(@min(d.matchCount(l), list_rows), 1);
    const h = listHead(w, m.cell_h) + @as(f32, @floatFromInt(rows)) * line;
    const below = w.ctl_r.y + w.ctl_r.h;
    const y = if (below + h <= area.y + area.h) below else @max(w.ctl_r.y - h, area.y);
    d.list_r = .{ .x = w.ctl_r.x, .y = y, .w = w.ctl_r.w, .h = h };
}

fn drawLabel(gfx: *Gfx, f: *Gfx.Face, t: *const Theme, w: *const Widget, line_h: f32) void {
    if (w.kind == .label) {
        var y = w.label_r.y;
        if (std.mem.indexOfScalar(u8, w.label, '\n') == null) {
            _ = text_mod.draw(gfx, f, w.label_r.x, y + @round((line_h - f.cell_h) / 2), &w.label_text, t.dim);
            return;
        }
        var it = std.mem.splitScalar(u8, w.label, '\n');
        while (it.next()) |l| {
            _ = gfx.text(f, w.label_r.x, y + @round((line_h - f.cell_h) / 2), l, t.dim);
            y += line_h;
        }
        return;
    }
    _ = text_mod.draw(gfx, f, w.label_r.x, w.label_r.y + @round((w.label_r.h - f.cell_h) / 2), &w.label_text, t.prompt_fg);
}

/// The window's content dimmed, then the dialog (`font` for the controls,
/// `small` for the frame).
pub fn draw(d: *Dialog, gfx: *Gfx, t: *const Theme, font: *Gfx.Face, small: *Gfx.Face, area: Rect, ui: f32, now: u64) void {
    const m: Metrics = .{ .cell_w = font.cell_w, .cell_h = font.cell_h, .small_w = small.cell_w, .small_h = small.cell_h, .ui = ui };
    d.place(area, m);
    const box = d.box;
    const line = @max(@round(ui), 1);
    const line_h = @round(font.cell_h * 1.3);
    gfx.clip(area);
    defer gfx.clip(null);
    gfx.fillAlpha(area, t.desktop, 150);
    gfx.fill(.{ .x = box.x + @round(3 * ui), .y = box.y + @round(4 * ui), .w = box.w, .h = box.h }, t.desktop); // shadow
    gfx.fill(box, t.bg);
    const title_h = @round(small.cell_h * 1.8);
    gfx.fill(.{ .x = box.x, .y = box.y, .w = box.w, .h = title_h }, t.title_bg);
    gfx.outline(box, if (d.keyboard) t.focus else t.divider, line);
    const pad = @round(14 * ui);
    const ty = box.y + @round((title_h - small.cell_h) / 2);
    _ = text_mod.draw(gfx, small, box.x + pad, ty, &d.title_text, t.title_fg);
    // Whose dialog it is: the frame is gtty's, a chip can't change this.
    const ow = Gfx.textWidth(small, d.owner);
    _ = gfx.text(small, d.close_r.x - pad / 2 - ow, ty, d.owner, t.dim);
    const over_close = if (d.mouse) |p| d.close_r.contains(p[0], p[1]) else false;
    gfx.fill(d.close_r, if (over_close) t.stderr_accent else t.title_bg);
    const ci = d.close_r.inset(@round(d.close_r.w * 0.28));
    gfx.line(ci.x, ci.y, ci.x + ci.w, ci.y + ci.h, t.title_fg, line);
    gfx.line(ci.x + ci.w, ci.y, ci.x, ci.y + ci.h, t.title_fg, line);

    gfx.clip(d.body_r);
    const shown = if (d.layout == .table and d.rows > 0) @min(d.widgets.items.len, @as(usize, d.columns) * d.rows) else d.widgets.items.len;
    for (d.widgets.items[0..shown], 0..) |*w, i| {
        const active = d.keyboard and i == d.focus;
        drawLabel(gfx, font, t, w, line_h);
        switch (w.kind) {
            .label => {},
            .text => Modal.drawField(&w.edit, gfx, t, font, w.ctl_r, ui, d.body_r, active),
            .checkbox => {
                const s = @round(font.cell_h);
                const r: Rect = .{ .x = w.ctl_r.x, .y = w.ctl_r.y + @round((w.ctl_r.h - s) / 2), .w = s, .h = s };
                gfx.fill(r, t.prompt_bg);
                gfx.outline(r, if (active) t.focus else t.divider, line);
                if (w.on) {
                    const th = @max(@round(2 * ui), 1);
                    gfx.line(r.x + s * 0.22, r.y + s * 0.52, r.x + s * 0.42, r.y + s * 0.74, t.focus, th);
                    gfx.line(r.x + s * 0.42, r.y + s * 0.74, r.x + s * 0.8, r.y + s * 0.26, t.focus, th);
                }
            },
            .dropdown => {
                const r = w.ctl_r;
                gfx.fill(r, t.prompt_bg);
                gfx.outline(r, if (active) t.focus else t.divider, line);
                _ = gfx.text(font, r.x + @round(6 * ui), r.y + @round((r.h - font.cell_h) / 2), w.value, t.prompt_fg);
                chevron(gfx, r, t, ui);
            },
        }
    }
    gfx.clip(area);
    if (d.err.len > 0) _ = gfx.text(font, box.x + pad, d.body_r.y + d.body_r.h + @round((line_h - font.cell_h) / 2), d.err, t.stderr_accent);

    const n = d.widgets.items.len;
    const list = d.buttonList();
    for (list, 0..) |b, i| {
        const r = d.btn_r[i];
        const over = if (d.mouse) |p| r.contains(p[0], p[1]) else false;
        const base = if (b == d.primary()) t.title_bg.mix(t.focus, 0.45) else t.title_bg;
        gfx.fill(r, if (d.locked) t.title_bg else if (over) base.mix(t.focus, 0.3) else base);
        gfx.outline(r, if (d.keyboard and d.focus == n + i) t.focus else t.divider, line);
        _ = gfx.text(font, r.x + pad, r.y + @round((r.h - font.cell_h) / 2), b.label(), if (d.locked) t.dim else t.prompt_fg);
    }
    const total = @as(u64, d.timeout_s) * 1000;
    const spent = @min(now -| d.touched_ms, total);
    var cbuf: [32]u8 = undefined;
    const countdown = std.fmt.bufPrint(&cbuf, "closes in {d} s", .{(total - spent + 999) / 1000}) catch "";
    _ = gfx.text(small, box.x + pad, d.btn_r[0].y + @round((d.btn_r[0].h - small.cell_h) / 2), countdown, t.dim);
    const bar_h = @max(@round(3 * ui), 2);
    const left = 1 - @as(f32, @floatFromInt(spent)) / @as(f32, @floatFromInt(total));
    gfx.fill(.{ .x = box.x, .y = box.y + box.h - bar_h, .w = @round(box.w * left), .h = bar_h }, t.focus);

    if (d.list) |*l| d.drawList(l, gfx, t, font, ui, area);
}

fn chevron(gfx: *Gfx, r: Rect, t: *const Theme, ui: f32) void {
    const s = @round(r.h * 0.2);
    const x = r.x + r.w - @round(10 * ui) - s;
    const y = r.y + r.h / 2 - s / 2;
    const th = @max(@round(ui), 1);
    gfx.line(x - s, y, x, y + s, t.dim, th);
    gfx.line(x, y + s, x + s, y, t.dim, th);
}

fn drawList(d: *Dialog, l: *List, gfx: *Gfx, t: *const Theme, font: *Gfx.Face, ui: f32, area: Rect) void {
    const r = d.list_r;
    const w = &d.widgets.items[l.widget];
    const line = @round(font.cell_h * 1.4);
    gfx.fill(r, t.title_bg);
    gfx.outline(r, t.focus, @max(@round(ui), 1));
    gfx.clip(r);
    defer gfx.clip(area);
    var y = r.y;
    if (w.filter) {
        const fr: Rect = .{ .x = r.x, .y = y, .w = r.w, .h = listHead(w, font.cell_h) };
        Modal.drawField(&l.edit, gfx, t, font, fr, ui, r, true);
        if (l.edit.len == 0) _ = gfx.text(font, r.x + @round(8 * ui), y + @round((fr.h - font.cell_h) / 2), "filter", t.dim);
        y += fr.h;
    }
    const total = d.matchCount(l);
    if (total == 0) {
        _ = gfx.text(font, r.x + @round(8 * ui), y + @round((line - font.cell_h) / 2), "no match", t.dim);
        return;
    }
    var row = l.top;
    while (row < total and row < l.top + list_rows) : (row += 1) {
        if (row == l.hi) gfx.fill(.{ .x = r.x, .y = y, .w = r.w, .h = line }, t.title_bg.mix(t.focus, 0.35));
        if (d.matchAt(l, row)) |o| _ = gfx.text(font, r.x + @round(8 * ui), y + @round((line - font.cell_h) / 2), o, t.prompt_fg);
        y += line;
    }
}

const test_m: Metrics = .{ .cell_w = 10, .cell_h = 20, .small_w = 8, .small_h = 16, .ui = 1 };
const test_area: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 600 };

fn testDialog() !*Dialog {
    const d = try create(std.testing.allocator, "test");
    d.apply(.{ .title = sdk.newText("T"), .buttons = .okcancel, .fields = &.{
        .{ .id = "note", .type = .label, .label = sdk.newText("hello") },
        .{ .id = "name", .type = .text, .label = sdk.newText("Name"), .value = .{ .text = "work" } },
        .{ .id = "keep", .type = .checkbox, .label = sdk.newText("Keep") },
        .{ .id = "host", .type = .dropdown, .label = sdk.newText("Host"), .filter = true, .options = &.{ "alpha", "beta", "gamma" }, .value = .{ .text = "alpha" } },
    } });
    d.show(1000, true);
    return d;
}

test "it opens on the first control, its text selected" {
    const d = try testDialog();
    defer d.destroy();
    try std.testing.expectEqual(@as(usize, 1), d.focus);
    d.typed("x", 1000);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("x", d.widgets.items[1].edit.text(&buf));
}

test "with no control, Enter is the primary button" {
    const d = try create(std.testing.allocator, "test");
    defer d.destroy();
    d.apply(.{ .buttons = .yesno, .fields = &.{.{ .id = "q", .type = .label, .label = sdk.newText("Sure?") }} });
    d.show(0, true);
    try std.testing.expectEqual(Outcome{ .press = .yes }, d.key(c.SDLK_RETURN, 0, 0));
}

test "buttons report and then wait for the chip" {
    const d = try testDialog();
    defer d.destroy();
    try std.testing.expectEqual(Outcome{ .press = .ok }, d.key(c.SDLK_RETURN, 0, 1000));
    try std.testing.expectEqual(Outcome.handled, d.key(c.SDLK_RETURN, 0, 1000)); // locked
    d.apply(.{ .err = .{ .set = "no" } });
    try std.testing.expectEqual(Outcome{ .press = .cancel }, d.key(c.SDLK_ESCAPE, 0, 1000));
}

test "Tab skips plain text, wraps over the buttons" {
    const d = try testDialog();
    defer d.destroy();
    _ = d.key(c.SDLK_TAB, 0, 1000);
    try std.testing.expectEqual(@as(usize, 2), d.focus);
    _ = d.key(c.SDLK_SPACE, 0, 1000);
    try std.testing.expect(d.widgets.items[2].on);
    for (0..3) |_| _ = d.key(c.SDLK_TAB, 0, 1000);
    try std.testing.expectEqual(@as(usize, 5), d.focus);
    _ = d.key(c.SDLK_TAB, 0, 1000);
    try std.testing.expectEqual(@as(usize, 1), d.focus);
}

test "the drop box: filter, pick, Esc closes only the list" {
    const d = try testDialog();
    defer d.destroy();
    d.focus = 3;
    _ = d.key(c.SDLK_SPACE, 0, 1000);
    try std.testing.expect(d.list != null);
    d.typed("GA", 1000);
    try std.testing.expectEqual(@as(usize, 1), d.matchCount(&d.list.?));
    _ = d.key(c.SDLK_RETURN, 0, 1000);
    try std.testing.expectEqualStrings("gamma", d.widgets.items[3].value);
    try std.testing.expect(d.list == null);
    _ = d.key(c.SDLK_SPACE, 0, 1000);
    try std.testing.expectEqual(Outcome.handled, d.key(c.SDLK_ESCAPE, 0, 1000));
    try std.testing.expect(d.list == null);
}

test "values: every control, not plain text" {
    const d = try testDialog();
    defer d.destroy();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = d.values(arena.allocator());
    try std.testing.expectEqual(@as(usize, 3), v.len);
    try std.testing.expectEqualStrings("work", v[0].value.text);
    try std.testing.expect(!v[1].value.on);
    try std.testing.expectEqualStrings("alpha", v[2].value.text);
}

test "the timeout: starts over on input, clamped" {
    const d = try testDialog();
    defer d.destroy();
    try std.testing.expect(!d.expired(1000 + 29_000));
    d.typed("a", 20_000);
    try std.testing.expect(!d.expired(45_000));
    try std.testing.expect(d.expired(51_000));
    d.apply(.{ .timeout = 100_000 });
    try std.testing.expectEqual(@as(u32, max_timeout_s), d.timeout_s);
}

test "layouts: centered, one field per line / flowing / in cells" {
    const d = try testDialog();
    defer d.destroy();
    d.place(test_area, test_m);
    const ws = d.widgets.items;
    try std.testing.expectEqual(ws[1].ctl_r.x, ws[3].ctl_r.x); // form: a column
    try std.testing.expect(ws[2].ctl_r.y > ws[1].ctl_r.y);
    try std.testing.expectApproxEqAbs(@as(f32, 500), d.box.x + d.box.w / 2, 1);
    d.apply(.{ .layout = .grid });
    d.place(test_area, test_m);
    try std.testing.expectEqual(ws[1].ctl_r.y, ws[2].ctl_r.y); // grid: side by side
    try std.testing.expect(ws[2].label_r.x >= ws[1].ctl_r.x + ws[1].ctl_r.w + 14); // the gap
    d.apply(.{ .layout = .table, .columns = 2, .rows = 2 });
    d.place(test_area, test_m);
    try std.testing.expectEqual(ws[0].label_r.y, ws[1].label_r.y); // row 1
    try std.testing.expect(ws[2].label_r.y > ws[0].label_r.y); // row 2
    try std.testing.expectEqual(ws[0].label_r.x, ws[2].label_r.x); // same column
}

test "a click: × kills, buttons press, a check box toggles" {
    const d = try testDialog();
    defer d.destroy();
    d.place(test_area, test_m);
    const k = d.widgets.items[2].ctl_r;
    try std.testing.expectEqual(Outcome.handled, d.click(k.x + 2, k.y + 2, test_m, 1000));
    try std.testing.expect(d.widgets.items[2].on);
    const b = d.btn_r[1];
    try std.testing.expectEqual(Outcome{ .press = .ok }, d.click(b.x + 2, b.y + 2, test_m, 1000));
    try std.testing.expectEqual(Outcome.kill, d.click(d.close_r.x + 1, d.close_r.y + 1, test_m, 1000));
}
