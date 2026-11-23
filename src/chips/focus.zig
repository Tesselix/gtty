// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The focus chip: counts the commands that use a folder
//! (`FocusFolders.countsAsUse`), not in a remote session, where the chip
//! isn't shown either. A click opens its epeek: the folders under home
//! used lately, the newest at the bottom by the chip, the current one
//! marked; a pick cds there. The list and its file, shared by every gtty
//! (`FocusFolders.sync`), are the chip's own: read at start, synced at
//! most every 10 s after a use, on opening the list and when gtty closes.
//! A test script run keeps them in memory unless `GTTY_FOCUS` says where.

const std = @import("std");
const sdk = @import("gtty");
const c = @import("../c.zig").c;
const FocusFolders = @import("../core/FocusFolders.zig");
const inproc = @import("inproc.zig");
const list = @import("list.zig");
const folder_chip = @import("folder.zig");

const focus_label = "focus";

var folders: ?FocusFolders = null;
/// The file is read and written (`inproc.keep_files` or `GTTY_FOCUS`).
var file_on = false;
var synced_ms: u64 = 0;
const sync_every_ms = 10_000;

pub fn onGttyStart(_: *sdk.Extension) !void {
    folders = .init(inproc.gpa);
    file_on = inproc.keep_files or c.getenv("GTTY_FOCUS") != null;
    if (file_on) sync();
}

pub fn onGttyClose(_: *sdk.Extension) !void {
    if (folders) |*f| {
        if (file_on and f.dirty) f.sync();
        f.deinit();
    }
    folders = null;
}

fn sync() void {
    const f = if (folders) |*x| x else return;
    f.sync();
    synced_ms = c.SDL_GetTicks();
}

const State = struct {
    dir: list.Owned = .{},
    filter: list.Owned = .{},
    sent: bool = false,

    pub fn deinit(s: *State) void {
        s.dir.deinit();
        s.filter.deinit();
    }
};

var windows: list.PerWindow(State) = .{};

pub fn onWindowStart(win: *sdk.Window) !void {
    try win.events.registerEvent(.window_changed);
    try win.events.registerEvent(.command_started);
}

pub fn onWindowClose(win: *sdk.Window) !void {
    windows.drop(win.id);
}

fn homeDir() []const u8 {
    return if (c.getenv("HOME")) |h| std.mem.span(h) else "";
}

/// How a folder shows and is filtered: under home without it (after a
/// `~`), so home's own name doesn't match every row.
fn homeRel(name: []const u8, home_in: []const u8) ?[]const u8 {
    const home = std.mem.trimEnd(u8, home_in, "/");
    if (home.len == 0 or !std.mem.startsWith(u8, name, home) or name.len <= home.len or name[home.len] != '/') return null;
    return name[home.len..];
}

fn setList(win: *sdk.Window, s: *const State) !void {
    const f = if (folders) |*x| x else return;
    var arena: std.heap.ArenaAllocator = .init(inproc.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = homeDir();
    var buf: [FocusFolders.shown_max][]const u8 = undefined;
    const all = f.top(home, &buf);
    const cur = s.dir.s;
    var rows: std.ArrayList(sdk.Line) = .empty;
    var last_other: usize = 0;
    for (all) |d| {
        const rel = homeRel(d, home);
        if (!list.matches(rel orelse d, s.filter.s)) continue;
        const shown = if (rel) |r| try std.fmt.allocPrint(a, "~{s}", .{r}) else d;
        var l: sdk.Line = .{ .text = sdk.newText(shown), .onclick = "pick", .data = d };
        if (std.mem.eql(u8, d, cur)) list.currentLine(&l, shown) else last_other = rows.items.len;
        try rows.append(a, l);
    }
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{
        .frame = .{ .set = .{
            .text = sdk.newText("focus folders"),
            .filter = .{ .hint = sdk.newText("filter folders"), .onclick = "filter" },
        } },
        .lines = .{ .set = rows.items },
        // The newest one that isn't the current folder.
        .selected = .{ .set = last_other },
        .empty = .{ .set = sdk.newText(if (all.len == 0) "no focus folders yet" else "no folder matches") },
    } });
}

pub fn onEvent(win: *sdk.Window, ev: *const sdk.Event) !void {
    switch (ev.kind) {
        .window_changed => {
            const s = try windows.of(win.id);
            if (ev.remote) {
                try win.ui.setDisplayMode(.chip);
                try win.ui.set(.{ .epeek = null });
                try win.ui.set(.{ .chip = .{ .text = null } });
            } else {
                try win.ui.set(.{ .chip = .{ .text = focus_label, .onclick = "open" } });
            }
            if (!std.mem.eql(u8, s.dir.s, ev.folder)) {
                if (!s.sent) try win.ui.setDisplayMode(.chip);
                s.sent = false;
                s.dir.set(ev.folder);
            }
        },
        .command_started => {
            if (ev.remote or ev.folder.len == 0 or !FocusFolders.countsAsUse(ev.command)) return;
            const f = if (folders) |*x| x else return;
            f.use(ev.folder, homeDir());
            if (file_on and c.SDL_GetTicks() -| synced_ms > sync_every_ms) sync();
        },
        .key => {},
        .button_click => try sdk.dispatch(Actions, win, ev),
    }
}

pub const Actions = struct {
    /// Set right before opening: other gttys' uses come in with the sync.
    pub fn open(win: *sdk.Window, _: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        // A quick look first: folders removed since are forgotten (`sync`
        // takes them out of the file too).
        if (file_on) sync() else if (folders) |*f| _ = f.dropMissing();
        try setList(win, s);
        try win.ui.setDisplayMode(.epeek);
    }

    pub fn filter(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        s.filter.set(b.text);
        try setList(win, s);
    }

    pub fn pick(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        if (std.mem.eql(u8, b.data, s.dir.s)) {
            var row: [1]sdk.Text = undefined;
            return win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .ok }, .message = .{ .set = list.oneRow(&row, "already here") } } });
        }
        try folder_chip.sendCd(win, b.data, &s.sent);
    }
};

test "under home: shown without it" {
    const t = std.testing;
    try t.expectEqualStrings("/src/gtty", homeRel("/Users/me/src/gtty", "/Users/me/").?);
    try t.expect(homeRel("/Users/me", "/Users/me") == null);
    try t.expect(homeRel("/Users/meow/x", "/Users/me") == null);
}
