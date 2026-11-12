// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The extension manager: its own OS window, like the Session Manager
//! (gtty ▸ Extensions…, the `extensions` command). On the left the
//! installed extensions (name; version and whether it runs), each row with
//! a ⋮ menu: Turn Off / Turn On, Restart, Unlock Files, Uninstall (asks
//! first: the data goes too). On the right the selected one: description,
//! status, folder, program, data. Install: the header's Install… button
//! (a file dialog: zip, tar, tar.gz) or a package / folder dropped on the
//! window; a banner asks first, naming what it is. Changes to the folder
//! go through core/Extensions.zig, so every gtty (Host.syncInstalled) and
//! this list follow; what needs gtty's own state (restart, unlocking,
//! uninstalling) is asked of App (`want`).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const color = @import("../core/color.zig");
const Theme = color.Theme;
const Rgb = color.Rgb;
const Gfx = @import("../render/Gfx.zig");
const Rect = Gfx.Rect;
const Extensions = @import("../core/Extensions.zig");
const Host = @import("../chips/Host.zig");

const ExtensionsWindow = @This();

const font_pt = 13;
const confirm_ms = 3000;
const max_ctls = 256;

const Item = enum { toggle, restart, unlock, uninstall };
const Ctl = union(enum) { row: usize, more: usize, item: Item, install, confirm, cancel };

/// What App does for the manager.
pub const Want = union(enum) { restart: []const u8, unlock: []const u8, uninstall: []const u8 };

gpa: std.mem.Allocator,
window: *c.SDL_Window,
renderer: *c.SDL_Renderer,
gfx: Gfx,
id: c.SDL_WindowID,
root: []const u8,
host: *const Host,
arena: std.heap.ArenaAllocator,
list: []Extensions.Installed = &.{},
stamp: i64 = -1,
sel_buf: [Extensions.max_name]u8 = undefined,
sel_len: usize = 0,
top: usize = 0,
/// A package dropped or picked, waiting for Install / Cancel.
pending: ?struct { arena: std.heap.ArenaAllocator, pkg: Extensions.Package, update: bool } = null,
/// From the file dialog's thread.
picked_lock: std.atomic.Mutex = .unlocked,
picked: ?[:0]u8 = null,
dialog_open: bool = false,
want: ?Want = null,
want_buf: [Extensions.max_name]u8 = undefined,
confirm_at: u64 = 0,
note: []const u8 = "",
note_buf: [200]u8 = undefined,
note_err: bool = false,
want_close: bool = false,
shot_path: ?[:0]u8 = null,
shot_ok: ?bool = null,
dirty: bool = true,
density: f32 = 1,
ui: f32 = 1,
over: ?usize = null,
ctls: [max_ctls]struct { r: Rect, what: Ctl } = undefined,
n_ctls: usize = 0,
list_rows: usize = 1,
menu: ?struct { row: usize, dots: Rect = .{}, hi: usize = 0 } = null,
/// Status shown last (redraw when it changes).
last_status: u64 = 0,

pub fn open(gpa: std.mem.Allocator, root: []const u8, host: *const Host) !*ExtensionsWindow {
    const window = c.SDL_CreateWindow("gtty Extensions", 900, 540, c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse
        return error.SdlWindow;
    errdefer c.SDL_DestroyWindow(window);
    _ = c.SDL_SetWindowMinimumSize(window, 600, 360);
    const renderer = c.SDL_CreateRenderer(window, null) orelse return error.SdlRenderer;
    errdefer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderVSync(renderer, 1);
    const s = try gpa.create(ExtensionsWindow);
    s.* = .{
        .gpa = gpa,
        .window = window,
        .renderer = renderer,
        .gfx = try Gfx.init(gpa, renderer),
        .id = c.SDL_GetWindowID(window),
        .root = try gpa.dupe(u8, root),
        .host = host,
        .arena = .init(gpa),
    };
    s.updateScale();
    s.reload();
    if (s.list.len > 0) s.select(0);
    return s;
}

pub fn close(s: *ExtensionsWindow) void {
    if (s.shot_path) |p| s.gpa.free(p);
    s.dropPending();
    while (!s.picked_lock.tryLock()) std.atomic.spinLoopHint();
    if (s.picked) |p| s.gpa.free(p);
    s.picked = null;
    s.picked_lock.unlock();
    s.arena.deinit();
    s.gpa.free(s.root);
    s.gfx.deinit();
    c.SDL_DestroyRenderer(s.renderer);
    c.SDL_DestroyWindow(s.window);
    // A file dialog still open answers into a closed window: leak the
    // struct then rather than free it under the callback.
    if (!s.dialog_open) s.gpa.destroy(s);
}

pub fn raise(s: *ExtensionsWindow) void {
    _ = c.SDL_RaiseWindow(s.window);
}

fn updateScale(s: *ExtensionsWindow) void {
    s.density = c.SDL_GetWindowPixelDensity(s.window);
    if (s.density <= 0) s.density = 1;
    s.ui = c.SDL_GetWindowDisplayScale(s.window);
    if (s.ui <= 0) s.ui = s.density;
    s.dirty = true;
}

/// Read the folder again when it changed (App calls this each frame).
pub fn tick(s: *ExtensionsWindow) void {
    const stamp = Extensions.stampOf(s.root);
    if (stamp != s.stamp) s.reload();
    // A file picked in the dialog (its own thread).
    while (!s.picked_lock.tryLock()) std.atomic.spinLoopHint();
    const p = s.picked;
    s.picked = null;
    s.picked_lock.unlock();
    if (p) |path| {
        defer s.gpa.free(path);
        s.offer(path);
    }
    // The running state comes from Host: redraw when it changed.
    var h: u64 = 0;
    for (s.list) |x| if (s.host.procStatus(x.manifest.name)) |st| {
        h = h *% 31 +% @intFromEnum(st.state) +% @as(u64, @intCast(@max(st.pid, 0))) *% 7;
    };
    if (h != s.last_status) {
        s.last_status = h;
        s.dirty = true;
    }
    if (s.confirm_at != 0 and c.SDL_GetTicks() -| s.confirm_at > confirm_ms) {
        s.confirm_at = 0;
        s.dirty = true;
    }
}

fn reload(s: *ExtensionsWindow) void {
    s.stamp = Extensions.stampOf(s.root);
    _ = s.arena.reset(.retain_capacity);
    s.list = Extensions.scan(s.arena.allocator(), s.root) catch &.{};
    if (s.selIndex() == null) {
        s.menu = null;
        if (s.list.len > 0) s.select(@min(s.top, s.list.len - 1)) else s.sel_len = 0;
    }
    s.dirty = true;
}

fn selIndex(s: *const ExtensionsWindow) ?usize {
    for (s.list, 0..) |x, i| if (std.mem.eql(u8, x.manifest.name, s.sel_buf[0..s.sel_len])) return i;
    return null;
}

fn select(s: *ExtensionsWindow, i: usize) void {
    if (i >= s.list.len) return;
    const n = s.list[i].manifest.name;
    @memcpy(s.sel_buf[0..n.len], n);
    s.sel_len = n.len;
    s.confirm_at = 0;
    if (i < s.top) s.top = i;
    if (i >= s.top + s.list_rows) s.top = i + 1 - s.list_rows;
    s.dirty = true;
}

fn moveSel(s: *ExtensionsWindow, delta: isize) void {
    if (s.list.len == 0) return;
    const at: isize = if (s.selIndex()) |i| @intCast(i) else 0;
    s.select(@intCast(std.math.clamp(at + delta, 0, @as(isize, @intCast(s.list.len - 1)))));
}

fn say(s: *ExtensionsWindow, comptime fmt: []const u8, args: anytype, err: bool) void {
    s.note = std.fmt.bufPrint(&s.note_buf, fmt, args) catch "";
    s.note_err = err;
    s.dirty = true;
}

fn ask(s: *ExtensionsWindow, w: std.meta.Tag(Want), name: []const u8) void {
    const n = @min(name.len, s.want_buf.len);
    @memcpy(s.want_buf[0..n], name[0..n]);
    const k = s.want_buf[0..n];
    s.want = switch (w) {
        .restart => .{ .restart = k },
        .unlock => .{ .unlock = k },
        .uninstall => .{ .uninstall = k },
    };
}

/// Take what App should do (valid until the next call into the window).
pub fn takeWant(s: *ExtensionsWindow) ?Want {
    const w = s.want;
    s.want = null;
    return w;
}

/// App did it: say so.
pub fn done(s: *ExtensionsWindow, w: Want) void {
    switch (w) {
        .restart => |n| s.say("restarting {s}", .{n}, false),
        .unlock => |n| s.say("{s}: its files are unlocked", .{n}, false),
        .uninstall => |n| s.say("uninstalled {s}, and its data", .{n}, false),
    }
    s.reload();
}

// ---- installing ----

fn dropPending(s: *ExtensionsWindow) void {
    if (s.pending) |*p| p.arena.deinit();
    s.pending = null;
}

/// A package or folder to install: read it, then ask.
pub fn offer(s: *ExtensionsWindow, path: []const u8) void {
    s.dropPending();
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    const pkg = Extensions.readPackage(arena.allocator(), path) catch |e| {
        arena.deinit();
        s.say("not installed: {s}", .{Extensions.explain(e)}, true);
        return;
    };
    const update = for (s.list) |x| {
        if (std.mem.eql(u8, x.manifest.name, pkg.manifest.name)) break true;
    } else false;
    s.pending = .{ .arena = arena, .pkg = pkg, .update = update };
    s.note = "";
    s.dirty = true;
    s.raise();
}

fn confirmInstall(s: *ExtensionsWindow) void {
    const p = s.pending orelse return;
    var a = p.arena;
    const name = Extensions.installPackage(a.allocator(), s.root, p.pkg) catch |e| {
        s.say("not installed: {s}", .{Extensions.explain(e)}, true);
        s.dropPending();
        return;
    };
    s.say("{s} {s}: it starts in every gtty within a second", .{ name, if (p.update) "updated" else "installed" }, false);
    var nb: [Extensions.max_name]u8 = undefined;
    @memcpy(nb[0..name.len], name);
    s.dropPending();
    s.reload();
    for (s.list, 0..) |x, i| if (std.mem.eql(u8, x.manifest.name, nb[0..name.len])) s.select(i);
}

fn chooseFile(s: *ExtensionsWindow) void {
    if (s.dialog_open) return;
    const filters = [_]c.SDL_DialogFileFilter{
        .{ .name = "gtty extension (zip, tar, tar.gz)", .pattern = "zip;tar;gz;tgz" },
    };
    s.dialog_open = true;
    c.SDL_ShowOpenFileDialog(onPicked, s, s.window, &filters, filters.len, null, false);
}

fn onPicked(ud: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    const s: *ExtensionsWindow = @ptrCast(@alignCast(ud orelse return));
    s.dialog_open = false;
    if (files == null or files[0] == null) return;
    const path = s.gpa.dupeZ(u8, std.mem.span(files[0])) catch return;
    while (!s.picked_lock.tryLock()) std.atomic.spinLoopHint();
    defer s.picked_lock.unlock();
    if (s.picked) |old| s.gpa.free(old);
    s.picked = path;
}

// ---- the ⋮ menu ----

fn toggle(s: *ExtensionsWindow, i: usize) void {
    const x = s.list[i];
    var a: std.heap.ArenaAllocator = .init(s.gpa);
    defer a.deinit();
    Extensions.setEnabled(a.allocator(), s.root, x.manifest.name, !x.enabled) catch return;
    s.say("{s} turned {s}", .{ x.manifest.name, if (x.enabled) "off: it stops in every gtty" else "on" }, false);
    s.reload();
}

fn pickItem(s: *ExtensionsWindow, it: Item) void {
    const i = s.selIndex() orelse return;
    const name = s.list[i].manifest.name;
    s.dirty = true;
    switch (it) {
        .toggle => {
            s.menu = null;
            s.toggle(i);
        },
        .restart => {
            s.menu = null;
            if (!s.list[i].enabled) return s.say("{s} is off: turn it on first", .{name}, true);
            s.ask(.restart, name);
        },
        .unlock => {
            s.menu = null;
            s.ask(.unlock, name);
        },
        .uninstall => {
            if (s.confirm_at != 0 and c.SDL_GetTicks() -| s.confirm_at <= confirm_ms) {
                s.confirm_at = 0;
                s.menu = null;
                s.ask(.uninstall, name);
            } else {
                s.confirm_at = c.SDL_GetTicks();
                if (s.menu) |*m| m.hi = @intFromEnum(Item.uninstall);
            }
        },
    }
}

// ---- input ----

pub fn handle(s: *ExtensionsWindow, ev: *const c.SDL_Event) void {
    switch (ev.type) {
        c.SDL_EVENT_WINDOW_RESIZED,
        c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
        c.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
        => s.updateScale(),
        c.SDL_EVENT_WINDOW_EXPOSED => s.dirty = true,
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => s.want_close = true,
        c.SDL_EVENT_KEY_DOWN => s.onKey(ev.key.key, ev.key.mod),
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT)
            s.onClick(ev.button.x * s.density, ev.button.y * s.density, ev.button.clicks),
        c.SDL_EVENT_MOUSE_MOTION => s.onMotion(ev.motion.x * s.density, ev.motion.y * s.density),
        c.SDL_EVENT_MOUSE_WHEEL => s.onWheel(ev.wheel.y),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => s.onMotion(-1, -1),
        c.SDL_EVENT_DROP_FILE => if (ev.drop.data) |d| s.offer(std.mem.span(d)),
        else => {},
    }
}

pub fn onKey(s: *ExtensionsWindow, key: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    const cmd = if (builtin.os.tag == .macos) mod & c.SDL_KMOD_GUI != 0 else mod & c.SDL_KMOD_CTRL != 0;
    s.dirty = true;
    if (s.pending != null) {
        switch (key) {
            c.SDLK_RETURN, c.SDLK_KP_ENTER => s.confirmInstall(),
            c.SDLK_ESCAPE => {
                s.dropPending();
                s.say("not installed", .{}, false);
            },
            else => {},
        }
        return;
    }
    if (s.menu) |*m| {
        switch (key) {
            c.SDLK_ESCAPE => {
                s.menu = null;
                s.confirm_at = 0;
            },
            c.SDLK_UP => m.hi -|= 1,
            c.SDLK_DOWN => m.hi = @min(m.hi + 1, @typeInfo(Item).@"enum".fields.len - 1),
            c.SDLK_RETURN, c.SDLK_KP_ENTER => s.pickItem(@enumFromInt(m.hi)),
            c.SDLK_DELETE, c.SDLK_BACKSPACE => s.pickItem(.uninstall),
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
        c.SDLK_HOME => s.moveSel(-@as(isize, @intCast(s.list.len))),
        c.SDLK_END => s.moveSel(@intCast(s.list.len)),
        c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_SPACE => if (s.selIndex()) |i| {
            s.menu = .{ .row = i };
        },
        c.SDLK_DELETE, c.SDLK_BACKSPACE => if (s.selIndex()) |i| {
            s.menu = .{ .row = i, .hi = @intFromEnum(Item.uninstall) };
            s.pickItem(.uninstall);
        },
        else => {},
    }
}

fn onMotion(s: *ExtensionsWindow, x: f32, y: f32) void {
    const now = s.ctlAt(x, y);
    if (now != s.over) s.dirty = true;
    s.over = now;
    if (now) |i| if (s.ctls[i].what == .item) if (s.menu) |*m| {
        m.hi = @intFromEnum(s.ctls[i].what.item);
    };
}

fn onWheel(s: *ExtensionsWindow, dy: f32) void {
    const max_top = s.list.len -| s.list_rows;
    const lines: isize = @intFromFloat(@round(-dy * 2));
    s.top = @intCast(std.math.clamp(@as(isize, @intCast(s.top)) + lines, 0, @as(isize, @intCast(max_top))));
    s.dirty = true;
}

fn ctlAt(s: *const ExtensionsWindow, x: f32, y: f32) ?usize {
    var i = s.n_ctls;
    while (i > 0) {
        i -= 1;
        if (s.ctls[i].r.contains(x, y)) return i;
    }
    return null;
}

pub fn onClick(s: *ExtensionsWindow, x: f32, y: f32, clicks: u8) void {
    const hit: ?Ctl = if (s.ctlAt(x, y)) |i| s.ctls[i].what else null;
    s.dirty = true;
    if (s.menu != null) {
        if (hit) |h| if (h == .item) return s.pickItem(h.item);
        s.menu = null;
        s.confirm_at = 0;
        return;
    }
    const h = hit orelse return;
    if (s.pending != null) switch (h) {
        .confirm => return s.confirmInstall(),
        .cancel => {
            s.dropPending();
            return s.say("not installed", .{}, false);
        },
        else => return,
    };
    switch (h) {
        .row => |i| {
            s.select(i);
            if (clicks >= 2) s.menu = .{ .row = i };
        },
        .more => |i| {
            s.select(i);
            s.menu = .{ .row = i };
        },
        .install => s.chooseFile(),
        .item, .confirm, .cancel => {},
    }
}

fn addCtl(s: *ExtensionsWindow, r: Rect, what: Ctl) void {
    if (s.n_ctls == max_ctls) return;
    s.ctls[s.n_ctls] = .{ .r = r, .what = what };
    s.n_ctls += 1;
}

fn isOver(s: *const ExtensionsWindow, what: Ctl) bool {
    const i = s.over orelse return false;
    return i < s.n_ctls and std.meta.eql(s.ctls[i].what, what);
}

// ---- drawing ----

const Status = struct { text: []const u8, col: Rgb };

fn statusOf(s: *const ExtensionsWindow, x: Extensions.Installed, theme: *const Theme, buf: []u8) Status {
    const got = s.host.procStatus(x.manifest.name);
    if (got) |st| if (st.dev and st.state == .running)
        return .{ .text = std.fmt.bufPrint(buf, "debugging, pid {d}", .{st.pid}) catch "debugging", .col = theme.focus };
    if (!x.enabled) return .{ .text = "off", .col = theme.dim };
    const st = got orelse return .{ .text = "not started (see gtty ext logs)", .col = theme.stderr_accent };
    return switch (st.state) {
        .attaching => .{ .text = "starting", .col = theme.dim },
        .running => .{ .text = std.fmt.bufPrint(buf, "running, pid {d}", .{st.pid}) catch "running", .col = theme.ok },
        .stopping => .{ .text = "stopping", .col = theme.dim },
        .ended => if (st.exit_code == 0)
            .{ .text = "ended", .col = theme.dim }
        else
            .{ .text = std.fmt.bufPrint(buf, "failed, exit code {d}", .{st.exit_code}) catch "failed", .col = theme.stderr_accent },
    };
}

fn button(s: *ExtensionsWindow, f: *Gfx.Face, theme: *const Theme, x: f32, y: f32, label: []const u8, what: Ctl, primary: bool) f32 {
    const g = &s.gfx;
    const ui = s.ui;
    const w = Gfx.textWidth(f, label) + @round(20 * ui);
    const h = @round(f.cell_h * 1.6);
    const r: Rect = .{ .x = x, .y = y, .w = w, .h = h };
    const base = if (primary) theme.focus.mix(theme.title_bg, 0.35) else theme.title_bg.mix(theme.fg, 0.08);
    g.fill(r, if (s.isOver(what)) base.mix(theme.fg, 0.12) else base);
    _ = g.text(f, x + @round(10 * ui), y + @round((h - f.cell_h) / 2), label, theme.title_fg);
    s.addCtl(r, what);
    return w;
}

pub fn render(s: *ExtensionsWindow, theme: *const Theme) void {
    if (!s.dirty) return;
    s.dirty = false;
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
    const list_w = @round(@max(@min(W * 0.32, 340 * ui), 200 * ui));
    const head_h = @round(f.cell_h * 2.4);
    g.fill(.{ .w = W, .h = head_h }, theme.title_bg);
    _ = g.text(f, pad, @round((head_h - f.cell_h) / 2), "Extensions", theme.title_fg);
    var cbuf: [32]u8 = undefined;
    const count = std.fmt.bufPrint(&cbuf, "{d} installed", .{s.list.len}) catch "";
    _ = g.text(small, list_w - pad - Gfx.textWidth(small, count), @round((head_h - small.cell_h) / 2), count, theme.dim);
    const iw = Gfx.textWidth(f, "Install…") + @round(20 * ui);
    _ = s.button(f, theme, W - pad - iw, @round((head_h - f.cell_h * 1.6) / 2), "Install…", .install, false);

    // The list.
    const list_r: Rect = .{ .x = 0, .y = head_h, .w = list_w, .h = @max(H - head_h, 1) };
    g.fill(list_r, theme.prompt_bg);
    const row_h = @round(f.cell_h + small.cell_h + 12 * ui);
    s.list_rows = @max(@as(usize, @intFromFloat(@floor(list_r.h / row_h))), 1);
    const sel = s.selIndex();
    const dots_w = @round(f.cell_h * 1.1);
    const dots_x = list_w - @round(8 * ui) - dots_w;
    if (s.menu) |m| if (m.row >= s.list.len) {
        s.menu = null;
    };
    if (s.list.len == 0) {
        _ = g.text(f, pad, list_r.y + pad, "No extensions installed", theme.dim);
        _ = g.text(small, pad, list_r.y + pad + f.cell_h + @round(4 * ui), "Install… or drop a package here", theme.dim);
    }
    g.clip(list_r);
    var k = s.top;
    while (k < s.list.len and k < s.top + s.list_rows) : (k += 1) {
        const x = s.list[k];
        const r: Rect = .{ .x = 0, .y = list_r.y + @as(f32, @floatFromInt(k - s.top)) * row_h, .w = list_w, .h = row_h };
        if (sel == k) g.fill(r, theme.selection) else if (s.isOver(.{ .row = k })) g.fill(r, theme.prompt_bg.mix(theme.fg, 0.06));
        const ty = r.y + @round(5 * ui);
        g.clip(.{ .x = r.x, .y = r.y, .w = @max(dots_x - @round(4 * ui), 1), .h = r.h });
        _ = g.text(f, pad, ty, x.manifest.name, if (x.enabled) theme.prompt_fg else theme.dim);
        var sbuf: [64]u8 = undefined;
        const st = s.statusOf(x, theme, &sbuf);
        var ibuf: [96]u8 = undefined;
        const ver = if (x.manifest.version.len > 0) x.manifest.version else "-";
        const info = std.fmt.bufPrint(&ibuf, "{s} · ", .{ver}) catch "";
        const ix = g.text(small, pad, ty + f.cell_h + @round(2 * ui), info, theme.dim);
        _ = g.text(small, ix, ty + f.cell_h + @round(2 * ui), st.text, st.col);
        g.clip(list_r);
        s.addCtl(r, .{ .row = k });
        const dots: Rect = .{ .x = dots_x, .y = r.y + @round((r.h - dots_w * 1.4) / 2), .w = dots_w, .h = @round(dots_w * 1.4) };
        const menu_open = if (s.menu) |m| m.row == k else false;
        const hot = menu_open or s.isOver(.{ .more = k });
        if (hot) g.fill(dots, theme.title_bg.mix(theme.fg, 0.12));
        const lit = hot or sel == k or s.isOver(.{ .row = k });
        _ = g.text(f, dots.x + @round((dots.w - Gfx.textWidth(f, "⋮")) / 2), dots.y + @round((dots.h - f.cell_h) / 2), "⋮", if (lit) theme.title_fg else theme.dim.mix(theme.prompt_bg, 0.3));
        s.addCtl(dots, .{ .more = k });
        if (menu_open) s.menu.?.dots = dots;
    }
    g.clip(null);
    g.fill(.{ .x = list_w, .y = 0, .w = @max(@round(ui), 1), .h = H }, theme.divider);

    // The right side: an install to confirm, else the selected extension.
    const ax = list_w + pad;
    var y = head_h + pad;
    const aw = W - ax - pad;
    g.clip(.{ .x = ax, .y = head_h, .w = @max(aw, 1), .h = @max(H - head_h, 1) });
    if (s.pending) |p| {
        const m = p.pkg.manifest;
        var tb: [160]u8 = undefined;
        _ = g.text(f, ax, y, std.fmt.bufPrint(&tb, "{s} {s} {s}?", .{ if (p.update) "Update" else "Install", m.name, m.version }) catch "Install?", theme.prompt_fg);
        y += f.cell_h * 1.8;
        if (m.description.len > 0) {
            _ = g.text(small, ax, y, m.description, theme.prompt_fg);
            y += small.cell_h * 1.6;
        }
        var rb: [160]u8 = undefined;
        _ = g.text(small, ax, y, std.fmt.bufPrint(&rb, "runs {s}{s}{s}", .{ m.main, if (m.runtime.len > 0) " with " else "", m.runtime }) catch "", theme.dim);
        y += small.cell_h * 1.4;
        // NOTE: in yellow, struck twice (bold); the rest in plain text.
        _ = g.text(small, ax + @max(1, @round(ui)), y, "NOTE:", theme.update);
        const nx = g.text(small, ax, y, "NOTE: ", theme.update);
        _ = g.text(small, nx, y, "An extension runs as you: it can read and change your files.", theme.prompt_fg);
        y += small.cell_h * 1.3;
        _ = g.text(small, nx, y, "Install only what you trust.", theme.prompt_fg);
        y += small.cell_h * 2.2;
        const bw = s.button(f, theme, ax, y, if (p.update) "Update" else "Install", .confirm, true);
        _ = s.button(f, theme, ax + bw + @round(10 * ui), y, "Cancel", .cancel, false);
        y += f.cell_h * 2.4;
        _ = g.text(small, ax, y, "Enter: install · Esc: cancel", theme.dim);
    } else if (sel) |i| {
        const x = s.list[i];
        var tb: [96]u8 = undefined;
        _ = g.text(f, ax, y, std.fmt.bufPrint(&tb, "{s} {s}", .{ x.manifest.name, x.manifest.version }) catch x.manifest.name, theme.prompt_fg);
        y += f.cell_h * 1.8;
        if (x.manifest.description.len > 0) {
            _ = g.text(small, ax, y, x.manifest.description, theme.prompt_fg);
            y += small.cell_h * 1.8;
        }
        var sbuf: [64]u8 = undefined;
        const st = s.statusOf(x, theme, &sbuf);
        var hb: [512]u8 = undefined;
        var db: [512]u8 = undefined;
        var pb: [512]u8 = undefined;
        var lb: [96]u8 = undefined;
        var fb: [512]u8 = undefined;
        const rows = [_][2][]const u8{
            .{ "status", st.text },
            .{ "folder", homeShort(&hb, x.code) },
            .{ "program", std.fmt.bufPrint(&pb, "{s}{s}{s}", .{ x.manifest.main, if (x.manifest.runtime.len > 0) " with " else "", x.manifest.runtime }) catch "" },
            .{ "data", homeShort(&db, std.fmt.bufPrint(&fb, "{s}/data", .{x.dir}) catch "") },
            .{ "logs", std.fmt.bufPrint(&lb, "gtty ext logs -f {s}", .{x.manifest.name}) catch "" },
        };
        const label_w = Gfx.textWidth(small, "program") + @round(14 * ui);
        for (rows, 0..) |row, ri| {
            _ = g.text(small, ax, y, row[0], theme.dim);
            _ = g.text(small, ax + label_w, y, row[1], if (ri == 0) st.col else theme.prompt_fg);
            y += small.cell_h * 1.5;
        }
        y += small.cell_h;
        const hint = if (s.confirm_at != 0) "Uninstall again to remove it and its data (Esc: keep it)" else "⋮: turn off, restart, unlock, uninstall · drop a package to install";
        _ = g.text(small, ax, y, hint, if (s.confirm_at != 0) theme.stderr_accent else theme.dim);
    }
    if (s.note.len > 0) _ = g.text(small, ax, H - pad - small.cell_h, s.note, if (s.note_err) theme.stderr_accent else theme.ok);
    g.clip(null);

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

fn drawMenu(s: *ExtensionsWindow, f: *Gfx.Face, theme: *const Theme, dots: Rect, hi: usize, W: f32, H: f32) void {
    const g = &s.gfx;
    const ui = s.ui;
    const armed = s.confirm_at != 0;
    const on = if (s.selIndex()) |i| s.list[i].enabled else true;
    const labels = [_][]const u8{ if (on) "Turn Off" else "Turn On", "Restart", "Unlock Files", if (armed) "Sure? Uninstall" else "Uninstall" };
    const p = @round(10 * ui);
    const row_h = @round(f.cell_h * 1.7);
    var lw: f32 = 0;
    for (labels) |l| lw = @max(lw, Gfx.textWidth(f, l));
    const mw = p + lw + p;
    const mh = @as(f32, @floatFromInt(labels.len)) * row_h + @round(8 * ui);
    var x = @max(dots.x + dots.w - mw, 0);
    x = @min(x, @max(W - mw, 0));
    var y = dots.y + dots.h + @round(2 * ui);
    if (y + mh > H) y = @max(dots.y - mh - @round(2 * ui), 0);
    const box: Rect = .{ .x = x, .y = y, .w = mw, .h = mh };
    g.fill(box, theme.title_bg);
    g.outline(box, theme.title_fg.mix(theme.title_bg, 0.45), @max(@round(ui), 1));
    for (labels, 0..) |l, i| {
        const it: Item = @enumFromInt(i);
        const r: Rect = .{ .x = box.x + @round(4 * ui), .y = box.y + @round(4 * ui) + @as(f32, @floatFromInt(i)) * row_h, .w = box.w - @round(8 * ui), .h = row_h };
        if (hi == i) g.fill(r, theme.selection);
        _ = g.text(f, box.x + p, r.y + @round((row_h - f.cell_h) / 2), l, if (it == .uninstall and armed) theme.stderr_accent else theme.prompt_fg);
        s.addCtl(r, .{ .item = it });
    }
}

fn homeShort(buf: []u8, p: []const u8) []const u8 {
    const home = std.mem.trimEnd(u8, std.mem.span(c.getenv("HOME") orelse return p), "/");
    if (home.len == 0 or !std.mem.startsWith(u8, p, home)) return p;
    if (p.len == home.len) return "~";
    if (p[home.len] != '/') return p;
    return std.fmt.bufPrint(buf, "~{s}", .{p[home.len..]}) catch p;
}

/// Script hook: save a screenshot to `path` on the next draw.
pub fn takeShot(s: *ExtensionsWindow, path: []const u8) void {
    if (s.shot_path) |p| s.gpa.free(p);
    s.shot_path = s.gpa.dupeZ(u8, path) catch null;
    s.dirty = true;
}
