// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! "Env & Aliases": a modal over gtty's screen listing a shell window's
//! environment variables and aliases as its startup files define them
//! (EnvTrace.zig), with where each one was set.
//!
//!   * A filter field on top: typing filters by name or value (any case,
//!     every value a name had, not only the last one: a match in an older
//!     value opens that row).
//!   * A table: key, value, source file — the full path and line where
//!     the value now was set (`/Users/me/.zshrc:12`); `?` = under a test
//!     gtty couldn't answer, `×N` = set N times. ▸ (when set more than
//!     once) opens the key's history under it: each earlier value with
//!     the full path of the file that set it, newest first, down to the
//!     file that set it first.
//!     Sections: environment, aliases, and the lines gtty couldn't follow
//!     (they run a program: `eval "$(brew shellenv)"`).
//!   * The bottom pane: the selected value in full, its file and line.
//!   * Keys: typing / ← → / Backspace edit the filter; ↑ ↓ PgUp PgDn move;
//!     Enter or Tab opens / closes the row; ⌘C (Linux Ctrl+Shift+C) copies
//!     the selected value; Esc clears the filter, then closes. Mouse: a
//!     click selects (on ▸ opens), double click opens, the wheel scrolls,
//!     × or a click outside closes.
//!
//! App owns it (`App.env_view`) and the trace it shows (`App.env_cache`,
//! `res`; null while it is being read).

const std = @import("std");
const builtin = @import("builtin");
const Gfx = @import("../render/Gfx.zig");
const color = @import("../core/color.zig");
const EnvTrace = @import("../core/EnvTrace.zig");
const LineEdit = @import("LineEdit.zig");
const Modal = @import("Modal.zig");
const JobWindow = @import("JobWindow.zig");
const ids = @import("ids.zig");

const EnvView = @This();
const Rect = Gfx.Rect;
const Theme = color.Theme;

pub const Row = struct {
    kind: enum { header, entry, def },
    /// Index into `res.entries` (a header: its kind's first entry).
    entry: u32 = 0,
    /// A def row: index into the entry's `defs`.
    def: u32 = 0,
    header: EnvTrace.Kind = .env,
    count: u32 = 0,
};

gpa: std.mem.Allocator,
/// The window it is about.
uid: ids.Id,
/// "#3 zsh".
title_buf: [64]u8 = undefined,
title_len: usize = 0,
res: ?*const EnvTrace.Result = null,
filter: LineEdit = .init(""),
/// Entries opened by the user (▸).
open: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// Entries open because the filter matched an older value.
auto_open: std.AutoHashMapUnmanaged(u32, void) = .empty,
/// Entries the user closed (the filter doesn't open them again).
shut: std.AutoHashMapUnmanaged(u32, void) = .empty,
rows: std.ArrayList(Row) = .empty,
sel: usize = 0,
top: usize = 0,
home: []const u8 = "",

// Layout (pixels), from `layout`.
r: Rect = .{},
bar_r: Rect = .{},
close_r: Rect = .{},
field_r: Rect = .{},
list_r: Rect = .{},
detail_r: Rect = .{},
row_h: f32 = 1,
cell_w: f32 = 1,
over_close: bool = false,
/// The row under the mouse.
hover: ?usize = null,

pub fn init(gpa: std.mem.Allocator, uid: ids.Id, title: []const u8) EnvView {
    var v: EnvView = .{ .gpa = gpa, .uid = uid };
    const n = @min(title.len, v.title_buf.len);
    @memcpy(v.title_buf[0..n], title[0..n]);
    v.title_len = n;
    if (std.c.getenv("HOME")) |h| v.home = std.mem.span(h);
    return v;
}

pub fn deinit(v: *EnvView) void {
    v.open.deinit(v.gpa);
    v.auto_open.deinit(v.gpa);
    v.shut.deinit(v.gpa);
    v.rows.deinit(v.gpa);
}

/// A new trace to show (or null: being read).
pub fn setResult(v: *EnvView, res: ?*const EnvTrace.Result) void {
    if (v.res == res) return;
    v.res = res;
    v.open.clearRetainingCapacity();
    v.rebuild();
}

fn filterText(v: *const EnvView, buf: []u8) []const u8 {
    return v.filter.text(buf);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// The rows for the filter and the open entries; the selection stays on
/// the same entry when it can.
pub fn rebuild(v: *EnvView) void {
    const keep: ?Row = if (v.sel < v.rows.items.len) v.rows.items[v.sel] else null;
    v.rows.clearRetainingCapacity();
    v.auto_open.clearRetainingCapacity();
    const res = v.res orelse return;
    var fbuf: [LineEdit.max * 4]u8 = undefined;
    const q = v.filterText(&fbuf);
    var last_kind: ?EnvTrace.Kind = null;
    var header_at: usize = 0;
    for (res.entries, 0..) |e, i| {
        const idx: u32 = @intCast(i);
        var hit = q.len == 0 or contains(e.name, q) or contains(e.last().value, q);
        if (!hit) for (e.defs) |d| if (contains(d.value, q)) {
            hit = true;
            if (!v.shut.contains(idx)) v.auto_open.put(v.gpa, idx, {}) catch {};
            break;
        };
        if (!hit) continue;
        if (last_kind != e.kind) {
            last_kind = e.kind;
            header_at = v.rows.items.len;
            v.rows.append(v.gpa, .{ .kind = .header, .entry = idx, .header = e.kind }) catch return;
        }
        v.rows.items[header_at].count += 1;
        v.rows.append(v.gpa, .{ .kind = .entry, .entry = idx }) catch return;
        if (e.defs.len > 1 and v.isOpen(idx)) {
            var k = e.defs.len - 1;
            while (k > 0) {
                k -= 1;
                v.rows.append(v.gpa, .{ .kind = .def, .entry = idx, .def = @intCast(k) }) catch return;
            }
        }
    }
    v.sel = v.firstSelectable(0, 1) orelse 0;
    if (keep == null) v.top = 0;
    if (keep) |kr| for (v.rows.items, 0..) |row, i| {
        if (row.kind == kr.kind and row.entry == kr.entry and row.def == kr.def and row.kind != .header) {
            v.sel = i;
            break;
        }
    };
    v.reveal();
}

fn isOpen(v: *const EnvView, idx: u32) bool {
    return v.open.contains(idx) or v.auto_open.contains(idx);
}

fn firstSelectable(v: *const EnvView, from: usize, dir: isize) ?usize {
    var i: isize = @intCast(from);
    while (i >= 0 and i < v.rows.items.len) : (i += dir) {
        if (v.rows.items[@intCast(i)].kind != .header) return @intCast(i);
    }
    return null;
}

fn visibleRows(v: *const EnvView) usize {
    return @max(@as(usize, @intFromFloat(@floor(v.list_r.h / v.row_h))), 1);
}

fn reveal(v: *EnvView) void {
    if (v.list_r.h <= 0) return; // not laid out yet
    const vis = v.visibleRows();
    // Keep a section's header in view with its first row.
    const want_top = if (v.sel > 0 and v.rows.items.len > 0 and v.rows.items[v.sel - 1].kind == .header) v.sel - 1 else v.sel;
    if (want_top < v.top) v.top = want_top;
    if (v.sel >= v.top + vis) v.top = v.sel + 1 - vis;
    v.clampTop();
}

fn clampTop(v: *EnvView) void {
    if (v.list_r.h <= 0) return;
    v.top = @min(v.top, v.rows.items.len -| v.visibleRows());
}

fn moveSel(v: *EnvView, d: isize) void {
    if (v.rows.items.len == 0) return;
    const n: isize = @intCast(v.rows.items.len);
    const target = std.math.clamp(@as(isize, @intCast(v.sel)) + d, 0, n - 1);
    v.sel = v.firstSelectable(@intCast(target), if (d < 0) -1 else 1) orelse v.firstSelectable(@intCast(target), if (d < 0) 1 else -1) orelse v.sel;
    v.reveal();
}

/// Open or close row `i`'s earlier values (a def row: its entry's).
fn toggle(v: *EnvView, i: usize) void {
    if (i >= v.rows.items.len) return;
    const row = v.rows.items[i];
    if (row.kind == .header) return;
    const res = v.res orelse return;
    if (res.entries[row.entry].defs.len < 2) return;
    if (v.isOpen(row.entry)) {
        _ = v.open.remove(row.entry);
        v.shut.put(v.gpa, row.entry, {}) catch {};
    } else {
        v.open.put(v.gpa, row.entry, {}) catch return;
        _ = v.shut.remove(row.entry);
    }
    v.sel = i;
    v.rebuild();
    for (v.rows.items, 0..) |r, k| if (r.kind == .entry and r.entry == row.entry) {
        v.sel = k;
        break;
    };
    v.reveal();
}

/// The filter changed: rows the user closed may open again for it.
fn filterChanged(v: *EnvView) void {
    v.shut.clearRetainingCapacity();
    v.top = 0;
    v.rebuild();
}

pub const Action = union(enum) { none, close, copy: []const u8 };

pub const Key = enum { up, down, page_up, page_down, home, end, enter, tab, escape, left, right, backspace, delete, word_left, word_right, line_home, line_end, select_all };

pub fn key(v: *EnvView, k: Key) Action {
    switch (k) {
        .up => v.moveSel(-1),
        .down => v.moveSel(1),
        .page_up => v.moveSel(-@as(isize, @intCast(v.visibleRows() -| 1))),
        .page_down => v.moveSel(@as(isize, @intCast(v.visibleRows() -| 1))),
        .home => v.moveSel(-@as(isize, @intCast(v.rows.items.len))),
        .end => v.moveSel(@as(isize, @intCast(v.rows.items.len))),
        .enter, .tab => v.toggle(v.sel),
        .escape => {
            if (v.filter.len == 0) return .close;
            v.filter = .init("");
            v.filterChanged();
        },
        .left => v.filter.move(.left, false),
        .right => v.filter.move(.right, false),
        .word_left => v.filter.move(.word_left, false),
        .word_right => v.filter.move(.word_right, false),
        .line_home => v.filter.move(.home, false),
        .line_end => v.filter.move(.end, false),
        .select_all => v.filter.selectAll(),
        .backspace => {
            v.filter.backspace(false);
            v.filterChanged();
        },
        .delete => {
            v.filter.delete(false);
            v.filterChanged();
        },
    }
    return .none;
}

pub fn typed(v: *EnvView, s: []const u8) void {
    v.filter.insert(s);
    v.filterChanged();
}

/// The selected value (to copy).
pub fn selectedValue(v: *const EnvView) ?[]const u8 {
    const d = v.selectedDef() orelse return null;
    return if (d.unset) null else d.value;
}

fn selectedDef(v: *const EnvView) ?*const EnvTrace.Def {
    if (v.sel >= v.rows.items.len) return null;
    const res = v.res orelse return null;
    const row = v.rows.items[v.sel];
    if (row.kind == .header) return null;
    const e = &res.entries[row.entry];
    return if (row.kind == .def) &e.defs[row.def] else e.last();
}

pub fn wheel(v: *EnvView, dy: f32) void {
    const n: isize = @intFromFloat(@round(-dy * 3));
    const t: isize = @as(isize, @intCast(v.top)) + n;
    v.top = @intCast(@max(t, 0));
    v.clampTop();
}

pub fn containsPoint(v: *const EnvView, x: f32, y: f32) bool {
    return v.r.contains(x, y);
}

fn rowAt(v: *const EnvView, x: f32, y: f32) ?usize {
    if (!v.list_r.contains(x, y)) return null;
    const i = v.top + @as(usize, @intFromFloat(@floor((y - v.list_r.y) / v.row_h)));
    return if (i < v.rows.items.len) i else null;
}

/// Mouse moved: hover row and close button. True when something changed.
pub fn motion(v: *EnvView, x: f32, y: f32) bool {
    const over = v.close_r.contains(x, y);
    const h = v.rowAt(x, y);
    const changed = over != v.over_close or !std.meta.eql(h, v.hover);
    v.over_close = over;
    v.hover = h;
    return changed;
}

pub fn click(v: *EnvView, x: f32, y: f32, clicks: u8) Action {
    if (!v.r.contains(x, y) or v.close_r.contains(x, y)) return .close;
    if (v.rowAt(x, y)) |i| {
        if (v.rows.items[i].kind == .header) return .none;
        const on_arrow = x < v.list_r.x + v.cell_w * 2.5;
        if (on_arrow or clicks == 2) {
            v.toggle(i);
        } else {
            v.sel = i;
        }
    }
    return .none;
}

// ------------------------------------------------------------ drawing

/// Place it in the middle of `screen`.
pub fn layout(v: *EnvView, f: *const Gfx.Face, small: *const Gfx.Face, ui: f32, screen: Rect) void {
    const pad = @round(14 * ui);
    const w = @min(@round(1040 * ui), screen.w - 2 * pad);
    const h = @min(@round(screen.h * 0.84), screen.h - 2 * pad);
    v.r = .{ .x = screen.x + @round((screen.w - w) / 2), .y = screen.y + @round((screen.h - h) / 2), .w = w, .h = h };
    const bar_h = @round(small.cell_h * 1.8);
    v.bar_r = .{ .x = v.r.x, .y = v.r.y, .w = w, .h = bar_h };
    const cs = @round(bar_h * 0.7);
    v.close_r = .{ .x = v.r.x + w - cs - @round((bar_h - cs) / 2), .y = v.r.y + @round((bar_h - cs) / 2), .w = cs, .h = cs };
    const field_h = @round(f.cell_h * 1.7);
    v.field_r = .{ .x = v.r.x + pad, .y = v.r.y + bar_h + pad * 0.7, .w = w - 2 * pad, .h = field_h };
    const detail_h = @round(small.cell_h * 1.35) * 5 + pad;
    v.detail_r = .{ .x = v.r.x, .y = v.r.y + h - detail_h, .w = w, .h = detail_h };
    v.row_h = @round(f.cell_h * 1.3);
    // A row's height for the column titles over the list.
    const ly = v.field_r.y + field_h + pad * 0.5 + v.row_h;
    v.list_r = .{ .x = v.r.x + pad, .y = ly, .w = w - 2 * pad - @round(6 * ui), .h = @max(v.detail_r.y - ly - pad * 0.4, f.cell_h) };
    v.row_h = @round(f.cell_h * 1.3);
    v.cell_w = f.cell_w;
    v.clampTop();
}

/// `s` in at most `cols` cells (cut with "…"); control characters and
/// bytes that aren't UTF-8 shown as "·", line feeds as "⏎".
fn fit(buf: []u8, s: []const u8, cols: usize) []const u8 {
    if (cols == 0) return "";
    var n: usize = 0;
    var cells: usize = 0;
    var cut_at: usize = 0; // bytes written when `cols - 1` cells were
    var i: usize = 0;
    while (i < s.len) {
        if (cells == cols) {
            const ell = "…";
            @memcpy(buf[cut_at..][0..ell.len], ell);
            return buf[0 .. cut_at + ell.len];
        }
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        const ok = len > 0 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + len]);
        const cs = if (ok) s[i .. i + len] else s[i .. i + 1];
        i += cs.len;
        const show: []const u8 = if (!ok) "·" else if (cs[0] == '\n') "⏎" else if (cs[0] == '\t') " " else if (cs.len == 1 and (cs[0] < 0x20 or cs[0] == 0x7f)) "·" else cs;
        if (n + show.len + 3 > buf.len) break;
        if (cells == cols - 1) cut_at = n;
        @memcpy(buf[n..][0..show.len], show);
        n += show.len;
        cells += 1;
    }
    return buf[0..n];
}

/// `s` in at most `cols` cells, cut on the left ("…/zsh/.zshrc:12": the
/// end of a path is what tells files apart).
fn fitLeft(buf: []u8, s: []const u8, cols: usize) []const u8 {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) cells += 1;
    }
    if (cells <= cols) return fit(buf, s, cols);
    if (cols < 2) return "";
    // Skip the first `cells - (cols - 1)` characters.
    var skip = cells - (cols - 1);
    i = 0;
    while (i < s.len and skip > 0) {
        i += 1;
        while (i < s.len and s[i] & 0xC0 == 0x80) i += 1;
        skip -= 1;
    }
    const ell = "…";
    @memcpy(buf[0..ell.len], ell);
    const rest = fit(buf[ell.len..], s[i..], cols - 1);
    return buf[0 .. ell.len + rest.len];
}

/// The file's full path and line (`/Users/me/.zshrc:12`; the inherited
/// environment: "inherited environment").
fn source(v: *const EnvView, buf: []u8, res: *const EnvTrace.Result, d: *const EnvTrace.Def, full: bool) []const u8 {
    _ = v;
    if (d.file == 0) return if (full) "inherited: in the environment the shell started with" else "inherited environment";
    const path = res.files[d.file];
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ path, d.line }) catch path;
}

fn headerLabel(kind: EnvTrace.Kind) []const u8 {
    return switch (kind) {
        .env => "environment",
        .alias => "aliases",
        .untraced => "not traced: these lines run a program",
    };
}

pub fn draw(v: *EnvView, gfx: *Gfx, t: *const Theme, f: *Gfx.Face, small: *Gfx.Face, ui: f32, screen: Rect) void {
    v.layout(f, small, ui, screen);
    const t1 = @max(@round(ui), 1);
    gfx.fillAlpha(screen, t.desktop, 150);
    gfx.fill(v.r, t.bg);
    gfx.fill(v.bar_r, t.title_bg);
    var tb: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&tb, "Env & Aliases — {s}", .{v.title_buf[0..v.title_len]}) catch "Env & Aliases";
    const ty = v.bar_r.y + @round((v.bar_r.h - small.cell_h) / 2);
    var x = gfx.text(small, v.bar_r.x + @round(12 * ui), ty, title, t.title_fg);
    if (v.res) |res| {
        var sb: [160]u8 = undefined;
        const n_files = res.files.len -| 1;
        const sub = std.fmt.bufPrint(&sb, "   {s}{s} · {d} file{s} read", .{
            @tagName(res.shell),            if (res.login) ", login" else "",
            n_files,                        if (n_files == 1) "" else "s",
        }) catch "";
        x = gfx.text(small, x, ty, sub, t.dim);
    }
    if (v.over_close) JobWindow.closeIcon(gfx, v.close_r, t, ui) else {
        const m = @round(v.close_r.w * 0.3);
        const lt = @max(@round(1.5 * ui), 1);
        const r = v.close_r;
        gfx.line(r.x + m, r.y + m, r.x + r.w - m, r.y + r.h - m, t.title_fg, lt);
        gfx.line(r.x + r.w - m, r.y + m, r.x + m, r.y + r.h - m, t.title_fg, lt);
    }

    // The filter.
    Modal.drawField(&v.filter, gfx, t, f, v.field_r, ui, screen, true);
    if (v.filter.len == 0) {
        _ = gfx.text(f, v.field_r.x + @round(6 * ui) + f.cell_w, v.field_r.y + @round((v.field_r.h - f.cell_h) / 2), "filter by name or value", t.dim);
    }

    const res = v.res orelse {
        _ = gfx.text(f, v.list_r.x, v.list_r.y + v.row_h, "reading the shell's startup files…", t.dim);
        gfx.outline(v.r, t.focus.mix(t.bg, 0.4), t1);
        return;
    };
    if (v.rows.items.len == 0) {
        _ = gfx.text(f, v.list_r.x, v.list_r.y + v.row_h, if (v.filter.len > 0) "nothing matches" else "nothing defined", t.dim);
    }

    // Columns: key, value, source file. The source column is as wide as
    // its longest full path (small text); the value takes the rest.
    const total: usize = @intFromFloat(@max(@floor(v.list_r.w / f.cell_w), 20));
    var name_w: usize = 8;
    var src_cells: usize = 18;
    for (v.rows.items) |row| {
        if (row.kind == .header) continue;
        const e = &res.entries[row.entry];
        if (row.kind == .entry and e.kind != .untraced) name_w = @max(name_w, e.name.len);
        var pb: [1024]u8 = undefined;
        const d = if (row.kind == .def) &e.defs[row.def] else e.last();
        src_cells = @max(src_cells, v.source(&pb, res, d, false).len + 6);
    }
    name_w = @min(name_w, @max(total / 4, 12)) + 2;
    // The full path first: the value gives up room down to `min_value`
    // cells (the bottom pane shows it all).
    const min_value: usize = 24;
    const room_px = @as(f32, @floatFromInt(total -| (2 + name_w + min_value + 2))) * f.cell_w;
    const src_px = @min(@as(f32, @floatFromInt(src_cells)) * small.cell_w, @max(room_px, 10 * small.cell_w));
    const src_w: usize = @intFromFloat(@ceil(src_px / f.cell_w));
    const src_cols: usize = @intFromFloat(@max(@floor(src_px / small.cell_w), 4));
    const arrow_w: usize = 2;
    const val_w: usize = total -| (arrow_w + name_w + src_w + 2);
    // The column titles.
    {
        const hy = v.list_r.y - v.row_h + @round((v.row_h - small.cell_h) / 2);
        const colx = v.list_r.x + @as(f32, @floatFromInt(total - src_w)) * f.cell_w;
        _ = gfx.text(small, v.list_r.x + @as(f32, @floatFromInt(arrow_w)) * f.cell_w, hy, "key", t.dim);
        _ = gfx.text(small, v.list_r.x + @as(f32, @floatFromInt(arrow_w + name_w)) * f.cell_w, hy, "value", t.dim);
        _ = gfx.text(small, colx, hy, "source file", t.dim);
    }
    const cx = struct {
        fn at(r: Rect, cw: f32, col: usize) f32 {
            return r.x + @as(f32, @floatFromInt(col)) * cw;
        }
    }.at;

    gfx.clip(v.list_r);
    const vis = v.visibleRows();
    var i = v.top;
    while (i < v.rows.items.len and i < v.top + vis + 1) : (i += 1) {
        const row = v.rows.items[i];
        const y = v.list_r.y + @as(f32, @floatFromInt(i - v.top)) * v.row_h;
        const yt = y + @round((v.row_h - f.cell_h) / 2);
        const rr: Rect = .{ .x = v.list_r.x, .y = y, .w = v.list_r.w, .h = v.row_h };
        var buf: [1024]u8 = undefined;
        var sbuf: [512]u8 = undefined;
        switch (row.kind) {
            .header => {
                var hb: [96]u8 = undefined;
                const label = std.fmt.bufPrint(&hb, "{s} · {d}", .{ headerLabel(row.header), row.count }) catch "";
                _ = gfx.text(small, rr.x, y + rr.h - small.cell_h - @round(2 * ui), label, t.focus);
                gfx.fill(.{ .x = rr.x, .y = y + rr.h - t1, .w = rr.w, .h = t1 }, t.divider);
                continue;
            },
            else => {},
        }
        if (i == v.sel) gfx.fill(rr, t.selection) else if (v.hover != null and v.hover.? == i) gfx.fill(rr, t.title_bg);
        const e = &res.entries[row.entry];
        if (row.kind == .entry) {
            if (e.defs.len > 1) {
                const open = v.isOpen(row.entry);
                arrowIcon(gfx, cx(rr, f.cell_w, 0) + f.cell_w * 0.2, yt, f.cell_h, f.cell_w * 1.1, open, t.dim, ui);
            }
            if (e.kind == .untraced) {
                const d = e.last();
                _ = gfx.text(f, cx(rr, f.cell_w, arrow_w), yt, fit(&buf, e.name, total -| (arrow_w + src_w + 2)), t.dim);
                _ = gfx.text(small, cx(rr, f.cell_w, total - src_w), yt + (f.cell_h - small.cell_h), fitLeft(&buf, v.source(&sbuf, res, d, false), src_cols), t.dim);
                continue;
            }
            const name_col = if (e.kind == .alias) t.mark_ai else t.fg;
            _ = gfx.text(f, cx(rr, f.cell_w, arrow_w), yt, fit(&buf, e.name, name_w - 1), name_col);
            const d = e.last();
            v.drawValue(gfx, t, f, cx(rr, f.cell_w, arrow_w + name_w), yt, d, val_w, false);
            v.drawWhere(gfx, t, f, small, res, d, e.defs.len, cx(rr, f.cell_w, total - src_w), yt, src_cols);
        } else {
            const d = &e.defs[row.def];
            // The history: each earlier value and the file that set it,
            // newest first; the last one is where the key was first set.
            const label = if (row.def == 0) "first set" else "before";
            _ = gfx.text(small, cx(rr, f.cell_w, arrow_w + 1), yt + (f.cell_h - small.cell_h), label, t.dim);
            v.drawValue(gfx, t, f, cx(rr, f.cell_w, arrow_w + name_w), yt, d, val_w, true);
            v.drawWhere(gfx, t, f, small, res, d, 0, cx(rr, f.cell_w, total - src_w), yt, src_cols);
        }
    }
    gfx.clip(null);

    // A scroll bar when the rows don't fit.
    const n = v.rows.items.len;
    if (n > vis) {
        const track = v.list_r;
        const th = @max(track.h * @as(f32, @floatFromInt(vis)) / @as(f32, @floatFromInt(n)), 12 * ui);
        const top_frac = @as(f32, @floatFromInt(v.top)) / @as(f32, @floatFromInt(n - vis));
        gfx.fill(.{ .x = v.r.x + v.r.w - @round(9 * ui), .y = track.y + (track.h - th) * @min(top_frac, 1), .w = @round(3 * ui), .h = th }, t.divider);
    }

    v.drawDetail(gfx, t, small, ui, res);
    gfx.outline(v.r, t.focus.mix(t.bg, 0.4), t1);
}

fn drawValue(v: *const EnvView, gfx: *Gfx, t: *const Theme, f: *Gfx.Face, x: f32, y: f32, d: *const EnvTrace.Def, cols: usize, older: bool) void {
    _ = v;
    var buf: [1024]u8 = undefined;
    if (d.unset) {
        _ = gfx.text(f, x, y, "(unset)", t.dim);
        return;
    }
    const col = if (older) t.dim else if (d.dynamic) t.prompt_fg.mix(t.dim, 0.5) else t.prompt_fg;
    _ = gfx.text(f, x, y, fit(&buf, d.value, cols), col);
}

/// Where the value was set; `?` when conditional, `×N` for the times set.
fn drawWhere(v: *const EnvView, gfx: *Gfx, t: *const Theme, f: *Gfx.Face, small: *Gfx.Face, res: *const EnvTrace.Result, d: *const EnvTrace.Def, times: usize, x: f32, y: f32, cols: usize) void {
    var sbuf: [512]u8 = undefined;
    var fb: [512]u8 = undefined;
    var nb: [16]u8 = undefined;
    const tag = if (times > 1) std.fmt.bufPrint(&nb, " ×{d}", .{times}) catch "" else "";
    const mark: []const u8 = if (d.cond) "? " else "";
    const room = cols -| (tag.len + mark.len);
    const sy = y + (f.cell_h - small.cell_h);
    var cx = x;
    if (mark.len > 0) cx = gfx.text(small, cx, sy, mark, t.update);
    cx = gfx.text(small, cx, sy, fitLeft(&fb, v.source(&sbuf, res, d, false), room), t.dim);
    if (tag.len > 0) _ = gfx.text(small, cx, sy, tag, t.focus);
}

/// The selected value in full, its file and line, the line itself.
fn drawDetail(v: *const EnvView, gfx: *Gfx, t: *const Theme, small: *Gfx.Face, ui: f32, res: *const EnvTrace.Result) void {
    const r = v.detail_r;
    gfx.fill(r, t.title_bg.mix(t.bg, 0.5));
    gfx.fill(.{ .x = r.x, .y = r.y, .w = r.w, .h = @max(@round(ui), 1) }, t.divider);
    const pad = @round(14 * ui);
    const lh = @round(small.cell_h * 1.35);
    var y = r.y + @round(pad * 0.5);
    const cols: usize = @intFromFloat(@max(@floor((r.w - 2 * pad) / small.cell_w), 10));
    const d = v.selectedDef() orelse {
        const keys = if (builtin.os.tag == .macos) "↑↓ select · Enter: earlier values · ⌘C copy the value · Esc close" else "↑↓ select · Enter: earlier values · Ctrl+Shift+C copy the value · Esc close";
        _ = gfx.text(small, r.x + pad, y, keys, t.dim);
        return;
    };
    var sbuf: [1024]u8 = undefined;
    var fb: [1024]u8 = undefined;
    var x = gfx.text(small, r.x + pad, y, fitLeft(&fb, v.source(&sbuf, res, d, true), cols), t.focus);
    var notes: [3][]const u8 = undefined;
    var nn: usize = 0;
    if (d.cond) {
        notes[nn] = "  · under a test gtty couldn't answer: may not run";
        nn += 1;
    }
    const untraced = v.res != null and v.sel < v.rows.items.len and res.entries[v.rows.items[v.sel].entry].kind == .untraced;
    if (untraced) {
        notes[nn] = "  · not followed: gtty would have to run a program to know what it sets";
        nn += 1;
    } else if (d.dynamic and !d.unset) {
        notes[nn] = "  · part of it is a program's output, shown as written";
        nn += 1;
    }
    for (notes[0..nn]) |s| x = gfx.text(small, x, y, s, t.update);
    y += lh;
    if (d.text.len > 0) {
        _ = gfx.text(small, r.x + pad, y, fit(&fb, d.text, cols), t.dim);
        y += lh;
    }
    if (d.unset) {
        _ = gfx.text(small, r.x + pad, y, "unset here", t.prompt_fg);
        return;
    }
    // The value, wrapped over the lines left.
    var rest = d.value;
    var lines: usize = 0;
    while (rest.len > 0 and y + small.cell_h <= r.y + r.h - @round(4 * ui)) : (lines += 1) {
        var n: usize = 0;
        var cells: usize = 0;
        while (n < rest.len and cells < cols) {
            n += std.unicode.utf8ByteSequenceLength(rest[n]) catch 1;
            cells += 1;
        }
        n = @min(n, rest.len);
        const last_line = y + lh + small.cell_h > r.y + r.h - @round(4 * ui);
        const piece = if (last_line and n < rest.len) fit(&fb, rest, cols) else fit(&fb, rest[0..n], cols + 1);
        _ = gfx.text(small, r.x + pad, y, piece, t.prompt_fg);
        rest = rest[n..];
        y += lh;
    }
}

/// ▸ / ▾ drawn with lines (the font may lack them).
fn arrowIcon(gfx: *Gfx, x: f32, y: f32, h: f32, w: f32, open: bool, col: color.Rgb, ui: f32) void {
    const lt = @max(@round(1.5 * ui), 1);
    const cy = y + h / 2;
    const s = @round(@min(w, h) * 0.32);
    const cx = x + w / 2;
    if (open) {
        gfx.line(cx - s, cy - s / 2, cx, cy + s / 2, col, lt);
        gfx.line(cx, cy + s / 2, cx + s, cy - s / 2, col, lt);
    } else {
        gfx.line(cx - s / 2, cy - s, cx + s / 2, cy, col, lt);
        gfx.line(cx + s / 2, cy, cx - s / 2, cy + s, col, lt);
    }
}

test "fit cuts with an ellipsis and shows control characters" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("abc", fit(&buf, "abc", 5));
    try std.testing.expectEqualStrings("abcd…", fit(&buf, "abcdefgh", 5));
    try std.testing.expectEqualStrings("a⏎b", fit(&buf, "a\nb", 5));
    try std.testing.expectEqualStrings("a·b", fit(&buf, "a\xffb", 5));
    try std.testing.expectEqualStrings("…zshrc:6", fitLeft(&buf, "/etc/zshrc:6", 8));
}
