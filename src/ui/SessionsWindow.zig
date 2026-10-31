// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The Session Manager (Session ▸ Session Manager…): an OS window of its
//! own, like the settings window. On the left the saved gtty-sessions
//! (core/Sessions.zig), the last used first; on the right a picture of
//! the selected one's gtty screen as it was: the windows area's tiles
//! where they were and the job grid as a column on the right. Each tile
//! says its command (zsh, bash, ssh), then for a session its host, then
//! the folder, wrapped and cut at the tile's edge; hovering a tile shows
//! all it knows, a line each, unwrapped.
//!
//! Each row ends in ⋮ (`more`): a click opens its menu, Restore / Rename
//! / Delete (`menu`; ↑ / ↓ / Enter, Esc closes; a click elsewhere only
//! closes it). Restore (also Enter, a double click) asks App to open it
//! (a new gtty, or this one while untouched); Rename (also F2) edits the
//! name in the list; Delete (also Delete / Backspace) asks once more
//! ("Sure?") before it goes.
//! Changes are written to the shared file at once (other gttys see them).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const color = @import("../core/color.zig");
const Rgb = color.Rgb;
const Theme = color.Theme;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const Sessions = @import("../core/Sessions.zig");

const SessionsWindow = @This();

const font_pt = 13;
/// Delete asks again this long ("click again to delete").
const confirm_ms = 3000;
const max_name = 200;

/// What a click on a spot does: a row, its ⋮, a row of the ⋮ menu, a
/// tile of the picture.
const Ctl = union(enum) { row: usize, more: usize, item: Item, tile: usize };
/// The ⋮ menu's rows, in order.
const Item = enum { restore, rename, delete };
const max_ctls = 256;

gpa: std.mem.Allocator,
window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
gfx: Gfx,
id: c.SDL_WindowID,
store: *Sessions,
/// The selected session's id ("" when none).
sel_buf: [64]u8 = undefined,
sel_len: usize = 0,
/// The first row shown (the list scrolls).
top: usize = 0,
/// Renaming the selected session: the name being typed.
edit: ?struct { buf: [max_name]u8 = undefined, len: usize = 0 } = null,
/// Delete was asked (the button / key) at this time: asked again until
/// `confirm_ms` later.
confirm_at: u64 = 0,
/// Restore asked: App opens this session (an id), then clears it.
want_restore: ?[]u8 = null,
/// The list was changed here (rename, delete): App looks again.
changed: bool = false,
want_close: bool = false,
/// A notice under the buttons (save failed, …).
note: []const u8 = "",
shot_path: ?[:0]u8 = null,
shot_ok: ?bool = null,
dirty: bool = true,
density: f32 = 1,
ui: f32 = 1,
mouse: [2]f32 = .{ -1, -1 },
over: ?usize = null,
last_click_ms: u64 = 0,
last_click_row: ?usize = null,
ctls: [max_ctls]struct { r: Rect, what: Ctl } = undefined,
n_ctls: usize = 0,
/// Rows that fit in the list (last draw).
list_rows: usize = 1,
/// The ⋮ menu, open for list row `row` (the selected one); `dots`: its
/// ⋮ on screen (last draw), `hi`: the row the keys are on.
menu: ?struct { row: usize, dots: Rect = .{}, hi: usize = 0 } = null,

pub fn open(gpa: std.mem.Allocator, store: *Sessions) !*SessionsWindow {
    const window = c.SDL_CreateWindow("gtty Sessions", 940, 580, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse
        return error.SdlWindow;
    errdefer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, 620, 380);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer;
    errdefer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderVSync(renderer, 1);
    _ = c.SDL_StartTextInput(window);
    const s = try gpa.create(SessionsWindow);
    s.* = .{
        .gpa = gpa,
        .window = window,
        .renderer = renderer,
        .gfx = try Gfx.init(gpa, renderer),
        .id = c.SDL_GetWindowID(window),
        .store = store,
    };
    s.updateScale();
    s.store.sort();
    if (s.store.list.items.len > 0) s.select(0);
    return s;
}

pub fn close(s: *SessionsWindow) void {
    if (s.shot_path) |p| s.gpa.free(p);
    if (s.want_restore) |r| s.gpa.free(r);
    s.gfx.deinit();
    c.SDL_DestroyRenderer(s.renderer);
    c.SDL_DestroyWindow(s.window);
    s.gpa.destroy(s);
}

pub fn raise(s: *SessionsWindow) void {
    _ = c.SDL_RaiseWindow(s.window);
}

fn updateScale(s: *SessionsWindow) void {
    s.density = c.SDL_GetWindowPixelDensity(s.window);
    if (s.density <= 0) s.density = 1;
    s.ui = c.SDL_GetWindowDisplayScale(s.window);
    if (s.ui <= 0) s.ui = s.density;
    s.dirty = true;
}

/// The list changed (another gtty, a snapshot): keep the selection when
/// it is still there.
pub fn listChanged(s: *SessionsWindow) void {
    s.store.sort();
    if (s.selIndex() == null) {
        s.edit = null;
        if (s.store.list.items.len > 0) s.select(@min(s.top, s.store.list.items.len - 1)) else s.sel_len = 0;
    }
    s.dirty = true;
}

/// Take the restore asked for (App frees it).
pub fn takeRestore(s: *SessionsWindow) ?[]u8 {
    const r = s.want_restore;
    s.want_restore = null;
    return r;
}

fn selIndex(s: *const SessionsWindow) ?usize {
    if (s.sel_len == 0) return null;
    for (s.store.list.items, 0..) |x, i| if (std.mem.eql(u8, x.id, s.sel_buf[0..s.sel_len])) return i;
    return null;
}

fn selected(s: *const SessionsWindow) ?*Sessions.Session {
    const i = s.selIndex() orelse return null;
    return &s.store.list.items[i];
}

fn select(s: *SessionsWindow, i: usize) void {
    const id = s.store.list.items[i].id;
    const n = @min(id.len, s.sel_buf.len);
    @memcpy(s.sel_buf[0..n], id[0..n]);
    s.sel_len = n;
    s.confirm_at = 0;
    if (i < s.top) s.top = i;
    if (i >= s.top + s.list_rows) s.top = i + 1 - s.list_rows;
    s.dirty = true;
}

fn moveSel(s: *SessionsWindow, delta: isize) void {
    const n = s.store.list.items.len;
    if (n == 0) return;
    const cur: isize = @intCast(s.selIndex() orelse 0);
    s.select(@intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(n - 1)))));
}

// ------------------------------------------------------------ actions

fn restore(s: *SessionsWindow) void {
    const x = s.selected() orelse return;
    if (s.want_restore) |r| s.gpa.free(r);
    s.want_restore = s.gpa.dupe(u8, x.id) catch null;
}

fn startRename(s: *SessionsWindow) void {
    const x = s.selected() orelse return;
    s.edit = .{};
    const n = @min(x.name.len, max_name);
    @memcpy(s.edit.?.buf[0..n], x.name[0..n]);
    s.edit.?.len = n;
    s.confirm_at = 0;
    s.dirty = true;
}

fn commitRename(s: *SessionsWindow) void {
    const e = s.edit orelse return;
    s.edit = null;
    s.dirty = true;
    const name = std.mem.trim(u8, e.buf[0..e.len], " \t");
    if (name.len == 0) return;
    const id = s.sel_buf[0..s.sel_len];
    // What other gttys changed meanwhile stays.
    s.store.reload();
    if (!s.store.rename(id, name)) return;
    s.saved();
}

/// Delete: the first ask arms the button, the second (within
/// `confirm_ms`) deletes.
fn delete(s: *SessionsWindow) void {
    if (s.selIndex() == null) return;
    const now = c.SDL_GetTicks();
    s.dirty = true;
    if (s.confirm_at == 0 or now -| s.confirm_at > confirm_ms) {
        s.confirm_at = now;
        return;
    }
    s.confirm_at = 0;
    const at = s.selIndex().?;
    var idbuf: [64]u8 = undefined;
    const id = idbuf[0..s.sel_len];
    @memcpy(id, s.sel_buf[0..s.sel_len]);
    s.store.reload();
    if (!s.store.remove(id)) return s.listChanged();
    s.saved();
    s.store.sort();
    s.sel_len = 0;
    if (s.store.list.items.len > 0) s.select(@min(at, s.store.list.items.len - 1));
}

fn saved(s: *SessionsWindow) void {
    s.note = if (s.store.save()) "" else "could not save the sessions file";
    s.changed = true;
    s.store.sort();
    s.dirty = true;
}

// ------------------------------------------------------------ events

pub fn handle(s: *SessionsWindow, ev: *const c.SDL_Event) void {
    switch (ev.type) {
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        => s.updateScale(),
        c.SDL_EVENT_WINDOW_EXPOSED => s.dirty = true,
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => s.want_close = true,
        c.SDL_EVENT_TEXT_INPUT => s.onText(std.mem.span(ev.text.text)),
        c.SDL_EVENT_KEY_DOWN => s.onKey(ev.key.key, ev.key.mod),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT)
            s.onClick(ev.button.x * s.density, ev.button.y * s.density, ev.button.clicks),
        c.SDL_EVENT_MOUSE_MOTION => s.onMotion(ev.motion.x * s.density, ev.motion.y * s.density),
        c.SDL_EVENT_MOUSE_WHEEL => s.onWheel(ev.wheel.y),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => s.onMotion(-1, -1),
        else => {},
    }
}

pub fn onText(s: *SessionsWindow, text: []const u8) void {
    const e = if (s.edit) |*e| e else return;
    const n = @min(e.buf.len - e.len, text.len);
    @memcpy(e.buf[e.len..][0..n], text[0..n]);
    e.len += n;
    s.dirty = true;
}

pub fn onKey(s: *SessionsWindow, key: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    const cmd = if (builtin.os.tag == .macos) mod & c.SDL_KMOD_GUI != 0 else mod & c.SDL_KMOD_CTRL != 0;
    s.dirty = true;
    if (s.edit) |*e| {
        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_TAB => s.commitRename(),
            c.SDLK_ESCAPE => s.edit = null,
            c.SDLK_BACKSPACE => while (e.len > 0) {
                e.len -= 1;
                if (e.buf[e.len] & 0xC0 != 0x80) break;
            },
            c.SDLK_V => if (cmd) {
                if (c.SDL_GetClipboardText()) |t| {
                    defer c.SDL_free(t);
                    const line = std.mem.sliceTo(t, 0);
                    s.onText(line[0 .. std.mem.indexOfAny(u8, line, "\r\n") orelse line.len]);
                }
            },
            else => {},
        }
        return;
    }
    if (s.menu) |*m| {
        switch (key) {
            c.SDLK_ESCAPE => s.closeMenu(),
            c.SDLK_UP => m.hi -|= 1,
            c.SDLK_DOWN => m.hi = @min(m.hi + 1, @typeInfo(Item).@"enum".fields.len - 1),
            c.SDLK_RETURN, c.SDLK_KP_ENTER => s.pickItem(@enumFromInt(m.hi)),
            else => {},
        }
        return;
    }
    switch (key) {
        c.SDLK_ESCAPE => if (s.confirm_at != 0) {
            s.confirm_at = 0;
        } else {
            s.want_close = true;
        },
        c.SDLK_W => if (cmd) {
            s.want_close = true;
        },
        c.SDLK_UP => s.moveSel(-1),
        c.SDLK_DOWN => s.moveSel(1),
        c.SDLK_PAGEUP => s.moveSel(-@as(isize, @intCast(s.list_rows))),
        c.SDLK_PAGEDOWN => s.moveSel(@intCast(s.list_rows)),
        c.SDLK_HOME => s.moveSel(-@as(isize, @intCast(s.store.list.items.len))),
        c.SDLK_END => s.moveSel(@intCast(s.store.list.items.len)),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => s.restore(),
        c.SDLK_F2 => s.startRename(),
        c.SDLK_DELETE, c.SDLK_BACKSPACE => s.delete(),
        else => {},
    }
}

fn onMotion(s: *SessionsWindow, x: f32, y: f32) void {
    s.mouse = .{ x, y };
    const now = s.ctlAt(x, y);
    // A tile's details follow the mouse: redraw while over one.
    if (now != s.over or (now != null and s.ctls[now.?].what == .tile)) s.dirty = true;
    s.over = now;
    // The ⋮ menu's row under the mouse is the one the keys are on.
    if (now) |i| if (s.ctls[i].what == .item) if (s.menu) |*m| {
        m.hi = @intFromEnum(s.ctls[i].what.item);
    };
}

fn onWheel(s: *SessionsWindow, dy: f32) void {
    const n = s.store.list.items.len;
    const max_top = n -| s.list_rows;
    const lines: isize = @intFromFloat(@round(-dy * 2));
    s.top = @intCast(std.math.clamp(@as(isize, @intCast(s.top)) + lines, 0, @as(isize, @intCast(max_top))));
    s.dirty = true;
}

fn ctlAt(s: *const SessionsWindow, x: f32, y: f32) ?usize {
    // The last added is drawn on top (tiles over the picture's frame).
    var i = s.n_ctls;
    while (i > 0) {
        i -= 1;
        if (s.ctls[i].r.contains(x, y)) return i;
    }
    return null;
}

pub fn onClick(s: *SessionsWindow, x: f32, y: f32, clicks: u8) void {
    const hit: ?Ctl = if (s.ctlAt(x, y)) |i| s.ctls[i].what else null;
    s.dirty = true;
    if (s.edit != null) {
        if (hit) |h| if (h == .row and h.row == s.selIndex()) return;
        s.commitRename();
    }
    // The menu open: a click on one of its rows picks it; anywhere else
    // it only closes the menu.
    if (s.menu != null) {
        if (hit) |h| if (h == .item) return s.pickItem(h.item);
        return s.closeMenu();
    }
    const h = hit orelse return;
    s.confirm_at = 0;
    switch (h) {
        .row => |i| {
            s.select(i);
            if (clicks >= 2) s.restore();
        },
        .more => |i| {
            s.select(i);
            s.menu = .{ .row = i };
        },
        .item, .tile => {},
    }
}

fn closeMenu(s: *SessionsWindow) void {
    s.menu = null;
    s.confirm_at = 0;
    s.dirty = true;
}

/// A row of the ⋮ menu: Delete asks first ("Sure?", the menu stays open).
fn pickItem(s: *SessionsWindow, it: Item) void {
    s.dirty = true;
    switch (it) {
        .restore => {
            s.menu = null;
            s.restore();
        },
        .rename => {
            s.menu = null;
            s.startRename();
        },
        .delete => {
            const asked = s.confirm_at != 0 and c.SDL_GetTicks() -| s.confirm_at <= confirm_ms;
            s.delete();
            if (asked) s.menu = null else if (s.menu) |*m| m.hi = @intFromEnum(Item.delete);
        },
    }
}

fn addCtl(s: *SessionsWindow, r: Rect, what: Ctl) void {
    if (s.n_ctls == max_ctls) return;
    s.ctls[s.n_ctls] = .{ .r = r, .what = what };
    s.n_ctls += 1;
}

fn isOver(s: *const SessionsWindow, what: Ctl) bool {
    const i = s.over orelse return false;
    return i < s.n_ctls and std.meta.eql(s.ctls[i].what, what);
}

// ------------------------------------------------------------ draw

pub fn render(s: *SessionsWindow, theme: *const Theme) void {
    if (!s.dirty) return;
    s.dirty = false;
    // An armed Delete runs out: redraw then.
    if (s.confirm_at != 0 and c.SDL_GetTicks() -| s.confirm_at > confirm_ms) s.confirm_at = 0;
    var wp: c_int = 0;
    var hp: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(s.window, &wp, &hp);
    const W: f32 = @floatFromInt(wp);
    const H: f32 = @floatFromInt(hp);
    const ui = s.ui;
    const f = s.gfx.face(@intFromFloat(@round(font_pt * ui))) catch return;
    const small = s.gfx.face(@intFromFloat(@round(font_pt * 0.85 * ui))) catch return;
    const g = &s.gfx;
    s.n_ctls = 0;
    g.fill(.{ .w = W, .h = H }, theme.desktop);

    const pad = @round(14 * ui);
    const list_w = @round(@max(@min(W * 0.32, 360 * ui), 200 * ui));

    // The list: name, then when it was used and how many windows.
    const head_h = @round(f.cell_h * 2.2);
    g.fill(.{ .w = W, .h = head_h }, theme.title_bg);
    _ = g.text(f, pad, @round((head_h - f.cell_h) / 2), "Sessions", theme.title_fg);
    const n = s.store.list.items.len;
    var cbuf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&cbuf, "{d} saved", .{n}) catch "";
    _ = g.text(small, list_w - pad - Gfx.textWidth(small, count), @round((head_h - small.cell_h) / 2), count, theme.dim);

    const foot_h = if (s.note.len > 0) small.cell_h + 2 * pad else 0;
    const list_r: Rect = .{ .x = 0, .y = head_h, .w = list_w, .h = @max(H - head_h - foot_h, 1) };
    g.fill(list_r, theme.prompt_bg);
    const row_h = @round(f.cell_h + small.cell_h + 12 * ui);
    s.list_rows = @max(@as(usize, @intFromFloat(@floor(list_r.h / row_h))), 1);
    const sel = s.selIndex();
    const dots_w = @round(f.cell_h * 1.1);
    const dots_x = list_w - @round(8 * ui) - dots_w;
    if (s.menu) |m| if (m.row >= n) {
        s.menu = null;
    };
    if (n == 0) {
        _ = g.text(f, pad, list_r.y + pad, "No saved sessions", theme.dim);
        _ = g.text(small, pad, list_r.y + pad + f.cell_h + @round(4 * ui), "Session ▸ Take Snapshot saves one", theme.dim);
    }
    g.clip(list_r);
    var k = s.top;
    while (k < n and k < s.top + s.list_rows) : (k += 1) {
        const x = &s.store.list.items[k];
        const r: Rect = .{ .x = 0, .y = list_r.y + @as(f32, @floatFromInt(k - s.top)) * row_h, .w = list_w, .h = row_h };
        if (sel == k) g.fill(r, theme.selection) else if (s.isOver(.{ .row = k })) g.fill(r, theme.prompt_bg.mix(theme.fg, 0.06));
        const ty = r.y + @round(5 * ui);
        if (sel == k and s.edit != null) {
            const e = &s.edit.?;
            const box: Rect = .{ .x = pad - @round(4 * ui), .y = ty - @round(2 * ui), .w = list_w - 2 * pad + @round(8 * ui), .h = f.cell_h + @round(4 * ui) };
            g.fill(box, theme.bg);
            g.outline(box, theme.focus, @max(@round(ui), 1));
            g.clip(box);
            const tw = Gfx.textWidth(f, e.buf[0..e.len]);
            const x0 = @min(pad, box.x + box.w - @round(4 * ui) - f.cell_w - tw);
            const end = g.text(f, x0, ty, e.buf[0..e.len], theme.prompt_fg);
            g.fill(.{ .x = end, .y = ty, .w = @max(@round(2 * ui), 1), .h = f.cell_h }, theme.cursor);
            g.clip(list_r);
        } else {
            g.clip(.{ .x = r.x, .y = r.y, .w = @max(dots_x - @round(4 * ui), 1), .h = r.h });
            _ = g.text(f, pad, ty, x.name, theme.prompt_fg);
            g.clip(list_r);
        }
        var ibuf: [96]u8 = undefined;
        var tbuf: [40]u8 = undefined;
        const info = std.fmt.bufPrint(&ibuf, "{d} window{s} · used {s}", .{ x.wins.items.len, if (x.wins.items.len == 1) "" else "s", when(&tbuf, x.used) }) catch "";
        _ = g.text(small, pad, ty + f.cell_h + @round(2 * ui), info, theme.dim);
        s.addCtl(r, .{ .row = k });
        // ⋮: this row's menu (bright on the row under the mouse, the
        // selected one, the one whose menu is open).
        if (!(sel == k and s.edit != null)) {
            const dots: Rect = .{ .x = dots_x, .y = r.y + @round((r.h - dots_w * 1.4) / 2), .w = dots_w, .h = @round(dots_w * 1.4) };
            const menu_open = if (s.menu) |m| m.row == k else false;
            const hot = menu_open or s.isOver(.{ .more = k });
            if (hot) g.fill(dots, theme.title_bg.mix(theme.fg, 0.12));
            const lit = hot or sel == k or s.isOver(.{ .row = k });
            const dc = if (lit) theme.title_fg else theme.dim.mix(theme.prompt_bg, 0.3);
            _ = g.text(f, dots.x + @round((dots.w - Gfx.textWidth(f, "⋮")) / 2), dots.y + @round((dots.h - f.cell_h) / 2), "⋮", dc);
            s.addCtl(dots, .{ .more = k });
            if (menu_open) s.menu.?.dots = dots;
        }
    }
    g.clip(null);
    // More rows than fit: a scroll mark.
    if (n > s.list_rows) {
        const nf: f32 = @floatFromInt(n);
        const rows: f32 = @floatFromInt(s.list_rows);
        const th = @max(list_r.h * rows / nf, 8 * ui);
        const ty = list_r.y + (list_r.h - th) * @as(f32, @floatFromInt(s.top)) / @max(nf - rows, 1);
        g.fill(.{ .x = list_w - @round(3 * ui), .y = ty, .w = @round(3 * ui), .h = th }, theme.dim);
    }
    g.fill(.{ .x = list_w, .y = 0, .w = @max(@round(ui), 1), .h = H }, theme.divider);

    // A notice under the list.
    const armed = s.confirm_at != 0;
    if (s.note.len > 0) _ = g.text(small, pad, H - foot_h + pad, s.note, theme.stderr_accent);

    // The picture of the selected session, its name over it.
    if (s.selected()) |x| {
        g.clip(.{ .x = list_w + pad, .y = 0, .w = @max(W - list_w - 2 * pad, 1), .h = head_h });
        _ = g.text(f, list_w + pad, @round((head_h - f.cell_h) / 2), x.name, theme.prompt_fg);
        g.clip(null);
    }
    const area: Rect = .{ .x = list_w + pad, .y = head_h + pad, .w = W - list_w - 2 * pad, .h = H - head_h - 2 * pad - small.cell_h - @round(6 * ui) };
    if (s.selected()) |x| {
        var tbuf: [40]u8 = undefined;
        var hbuf: [160]u8 = undefined;
        const hint = if (armed)
            "Delete again to delete it (Esc: keep it)"
        else
            std.fmt.bufPrint(&hbuf, "taken {s} · Enter or double-click: restore in a new gtty · ⋮ rename, delete", .{when(&tbuf, x.created)}) catch "";
        _ = g.text(small, area.x, area.y + area.h + @round(6 * ui), hint, if (armed) theme.stderr_accent else theme.dim);
        s.drawPicture(f, small, theme, x, area);
    } else if (n > 0) {
        _ = g.text(f, area.x, area.y, "Select a session", theme.dim);
    }

    if (s.menu) |m| s.drawMenu(f, theme, m.dots, m.hi, W, H);

    if (s.shot_path) |p| {
        s.shot_path = null;
        defer s.gpa.free(p);
        s.shot_ok = false;
        if (c.SDL_RenderReadPixels(s.renderer, null)) |surf| {
            defer c.SDL_DestroySurface(surf);
            s.shot_ok = c.SDL_SaveBMP(surf, p.ptr);
        }
    }
    _ = c.SDL_RenderPresent(s.renderer);
}

/// The session's gtty screen, fitted into `area`: the windows area with
/// its tiles (the current window's frame blue), the job grid's windows in
/// a column on the right (a ninth of the width, as in gtty).
fn drawPicture(s: *SessionsWindow, f: *Gfx.Face, small: *Gfx.Face, theme: *const Theme, x: *const Sessions.Session, area: Rect) void {
    const g = &s.gfx;
    const ui = s.ui;
    const grid = x.hasGrid();
    // Screen = windows area (aspect) + the grid column (1/8 of its width).
    const screen_aspect = x.aspect * @as(f32, if (grid) 9.0 / 8.0 else 1.0);
    var sw = area.w;
    var sh = sw / screen_aspect;
    if (sh > area.h) {
        sh = area.h;
        sw = sh * screen_aspect;
    }
    const screen: Rect = .{ .x = area.x + @round((area.w - sw) / 2), .y = area.y + @round((area.h - sh) / 2), .w = @round(sw), .h = @round(sh) };
    g.fill(screen, theme.bg.mix(theme.desktop, 0.5));
    g.outline(screen, theme.divider, @max(@round(ui), 1));
    const main_w = if (grid) @round(screen.w * 8 / 9) else screen.w;
    const main: Rect = .{ .x = screen.x, .y = screen.y, .w = main_w, .h = screen.h };
    const gap = @max(@round(3 * ui), 2);

    var hovered: ?usize = null;
    // Grid cells: as wide as the column, stacked; as many as fit.
    var grid_n: usize = 0;
    for (x.wins.items) |w| {
        if (w.place == .grid) grid_n += 1;
    }
    const col: Rect = .{ .x = main.x + main.w, .y = screen.y, .w = screen.w - main.w, .h = screen.h };
    const cell_h = if (grid_n > 0) @min(@round(col.w * 0.75), (col.h - gap) / @as(f32, @floatFromInt(grid_n)) - gap) else 0;
    if (grid) g.fill(.{ .x = col.x, .y = col.y, .w = @max(@round(ui), 1), .h = col.h }, theme.divider);
    var gi: usize = 0;
    for (x.wins.items, 0..) |*w, i| {
        const r: Rect = switch (w.place) {
            .grid => blk: {
                const y = col.y + gap + @as(f32, @floatFromInt(gi)) * (cell_h + gap);
                gi += 1;
                break :blk .{ .x = col.x + gap, .y = y, .w = col.w - 2 * gap, .h = @max(cell_h, 4) };
            },
            else => .{
                .x = main.x + @round(w.x * main.w) + gap,
                .y = main.y + @round(w.y * main.h) + gap,
                .w = @max(@round(w.w * main.w) - 2 * gap, 4),
                .h = @max(@round(w.h * main.h) - 2 * gap, 4),
            },
        };
        s.drawTile(if (w.place == .grid) small else f, small, theme, w, r);
        s.addCtl(r, .{ .tile = i });
        if (r.contains(s.mouse[0], s.mouse[1])) hovered = i;
    }
    // Not over the ⋮ menu.
    if (hovered) |i| if (s.menu == null) s.drawDetails(f, theme, &x.wins.items[i]);
}

/// A tile: its frame (blue: the current window), then the command, for a
/// session the host, and the folder, wrapped to the tile's width and cut
/// at its bottom.
fn drawTile(s: *SessionsWindow, f: *Gfx.Face, small: *Gfx.Face, theme: *const Theme, w: *const Sessions.Win, r: Rect) void {
    _ = small;
    const g = &s.gfx;
    const ui = s.ui;
    g.fill(r, theme.bg);
    const t = @max(@round(ui), 1);
    g.outline(r, if (w.place == .main) theme.focus else theme.divider, if (w.place == .main) 2 * t else t);
    const p = @round(5 * ui);
    const inner: Rect = .{ .x = r.x + p, .y = r.y + p, .w = r.w - 2 * p, .h = r.h - 2 * p };
    if (inner.w < f.cell_w or inner.h < f.cell_h * 0.6) return;
    g.clip(inner);
    defer g.clip(null);
    var y = inner.y;
    var cbuf: [160]u8 = undefined;
    const me = c.getuid();
    const head = if (w.kind == .local and w.uid != me)
        std.fmt.bufPrint(&cbuf, "{s} · {s}", .{ w.command(), if (w.user.len > 0) w.user else "?" }) catch w.command()
    else
        w.command();
    y = s.wrapped(f, inner, y, head, theme.title_fg);
    if (w.kind != .local) y = s.wrapped(f, inner, y, w.host, theme.focus);
    var hbuf: [4200]u8 = undefined;
    const dir = if (w.kind != .local) (if (w.rfolder.len > 0) w.rfolder else "(folder unknown)") else homeShort(&hbuf, w.folder);
    _ = s.wrapped(f, inner, y, dir, theme.dim);
}

/// `text` from `y` down, broken at the tile's width (any character; the
/// font is monospaced); returns the y under it.
fn wrapped(s: *SessionsWindow, f: *Gfx.Face, r: Rect, y_in: f32, text: []const u8, col: Rgb) f32 {
    const per: usize = @max(@as(usize, @intFromFloat(@floor(r.w / f.cell_w))), 1);
    var y = y_in;
    var i: usize = 0;
    while (i < text.len and y < r.y + r.h) {
        var j = i;
        var k: usize = 0;
        while (j < text.len and k < per) : (k += 1) j += std.unicode.utf8ByteSequenceLength(text[j]) catch 1;
        j = @min(j, text.len);
        _ = s.gfx.text(f, r.x, y, text[i..j], col);
        y += f.cell_h;
        i = j;
    }
    if (text.len == 0) y += f.cell_h;
    return y;
}

/// All a tile knows, one line each (not wrapped), in a box by the mouse,
/// kept in the window.
fn drawDetails(s: *SessionsWindow, f: *Gfx.Face, theme: *const Theme, w: *const Sessions.Win) void {
    const g = &s.gfx;
    const ui = s.ui;
    var bufs: [8][4300]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    var n: usize = 0;
    const Add = struct {
        fn add(b: *[8][4300]u8, l: *[8][]const u8, k: *usize, comptime fmt: []const u8, args: anytype) void {
            l[k.*] = std.fmt.bufPrint(&b[k.*], fmt, args) catch return;
            k.* += 1;
        }
    }.add;
    Add(&bufs, &lines, &n, "{s}{s}", .{ w.command(), switch (w.place) {
        .main => "  (the current window)",
        .shown => "  (windows area)",
        .grid => "  (job grid)",
    } });
    if (w.kind != .local) {
        Add(&bufs, &lines, &n, "host: {s}", .{w.host});
        Add(&bufs, &lines, &n, "remote folder: {s}", .{if (w.rfolder.len > 0) w.rfolder else "(unknown)"});
        Add(&bufs, &lines, &n, "command: {s}", .{w.cmd});
        Add(&bufs, &lines, &n, "local shell: {s}", .{w.shell});
        Add(&bufs, &lines, &n, "local folder: {s}", .{w.folder});
    } else {
        Add(&bufs, &lines, &n, "folder: {s}", .{w.folder});
    }
    Add(&bufs, &lines, &n, "user: {s} (uid {d}){s}", .{ if (w.user.len > 0) w.user else "?", w.uid, if (w.kind == .local and w.uid != c.getuid()) ": restored with sudo typed, not run" else "" });

    const p = @round(8 * ui);
    var bw: f32 = 0;
    for (lines[0..n]) |l| bw = @max(bw, Gfx.textWidth(f, l));
    bw += 2 * p;
    const bh = @as(f32, @floatFromInt(n)) * f.cell_h + 2 * p;
    var wp: c_int = 0;
    var hp: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(s.window, &wp, &hp);
    const W: f32 = @floatFromInt(wp);
    const H: f32 = @floatFromInt(hp);
    // Right of and under the mouse; flipped when it doesn't fit.
    var x = s.mouse[0] + @round(14 * ui);
    var y = s.mouse[1] + @round(18 * ui);
    if (x + bw > W) x = @max(s.mouse[0] - @round(8 * ui) - bw, 0);
    if (y + bh > H) y = @max(s.mouse[1] - @round(8 * ui) - bh, 0);
    const box: Rect = .{ .x = x, .y = y, .w = @min(bw, W - x), .h = @min(bh, H - y) };
    g.fill(box, theme.title_bg);
    g.outline(box, theme.title_fg.mix(theme.title_bg, 0.45), @max(@round(ui), 1));
    g.clip(box);
    defer g.clip(null);
    for (lines[0..n], 0..) |l, k| _ = g.text(f, box.x + p, box.y + p + @as(f32, @floatFromInt(k)) * f.cell_h, l, if (k == 0) theme.prompt_fg else theme.title_fg);
}

/// The ⋮ menu under its dots (over them when it doesn't fit), kept in
/// the window: Restore, Rename, Delete with their keys; an asked Delete
/// reads "Sure? Delete" in red.
fn drawMenu(s: *SessionsWindow, f: *Gfx.Face, theme: *const Theme, dots: Rect, hi: usize, W: f32, H: f32) void {
    const g = &s.gfx;
    const ui = s.ui;
    const armed = s.confirm_at != 0;
    const labels = [_][]const u8{ "Restore", "Rename", if (armed) "Sure? Delete" else "Delete" };
    const keys = [_][]const u8{ "Enter", "F2", "Del" };
    const p = @round(10 * ui);
    const row_h = @round(f.cell_h * 1.7);
    var lw: f32 = 0;
    var kw: f32 = 0;
    for (labels, keys) |l, k| {
        lw = @max(lw, Gfx.textWidth(f, l));
        kw = @max(kw, Gfx.textWidth(f, k));
    }
    const mw = p + lw + 3 * p + kw + p;
    const mh = @as(f32, @floatFromInt(labels.len)) * row_h + @round(8 * ui);
    var x = @max(dots.x + dots.w - mw, 0);
    x = @min(x, @max(W - mw, 0));
    var y = dots.y + dots.h + @round(2 * ui);
    if (y + mh > H) y = @max(dots.y - mh - @round(2 * ui), 0);
    const box: Rect = .{ .x = x, .y = y, .w = mw, .h = mh };
    g.fill(box, theme.title_bg);
    g.outline(box, theme.title_fg.mix(theme.title_bg, 0.45), @max(@round(ui), 1));
    for (labels, keys, 0..) |l, k, i| {
        const it: Item = @enumFromInt(i);
        const r: Rect = .{ .x = box.x + @round(4 * ui), .y = box.y + @round(4 * ui) + @as(f32, @floatFromInt(i)) * row_h, .w = box.w - @round(8 * ui), .h = row_h };
        if (hi == i) g.fill(r, theme.selection);
        const ty = r.y + @round((row_h - f.cell_h) / 2);
        const danger = it == .delete and armed;
        _ = g.text(f, box.x + p, ty, l, if (danger) theme.stderr_accent else theme.prompt_fg);
        _ = g.text(f, box.x + box.w - p - Gfx.textWidth(f, k), ty, k, theme.dim);
        s.addCtl(r, .{ .item = it });
    }
}

/// `p` with the home folder as `~`.
fn homeShort(buf: []u8, p: []const u8) []const u8 {
    const home = std.mem.trimEnd(u8, std.mem.span(c.getenv("HOME") orelse return p), "/");
    if (home.len == 0 or !std.mem.startsWith(u8, p, home)) return p;
    if (p.len == home.len) return "~";
    if (p[home.len] != '/') return p;
    return std.fmt.bufPrint(buf, "~{s}", .{p[home.len..]}) catch p;
}

/// A time as "Oct 28 14:05" (local).
fn when(buf: []u8, at: i64) []const u8 {
    var t: c.time_t = @intCast(at);
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return "?";
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s} {d} {d:0>2}:{d:0>2}", .{ months[@intCast(@mod(tm.tm_mon, 12))], tm.tm_mday, @as(u32, @intCast(tm.tm_hour)), @as(u32, @intCast(tm.tm_min)) }) catch "?";
}

/// Script hook: save a screenshot to `path` on the next draw.
pub fn takeShot(s: *SessionsWindow, path: []const u8) void {
    if (s.shot_path) |p| s.gpa.free(p);
    s.shot_path = s.gpa.dupeZ(u8, path) catch null;
    s.dirty = true;
}
