// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The folder chip: the name of the folder the job is in. Not in a
//! remote session, where the local folder means nothing. Its peek is the
//! full path (a click copies it, resting on it expands); its epeek the
//! folders above, `/` on top and the current one last, by the chip: a pick
//! cds there, the current one copies its path.

const std = @import("std");
const sdk = @import("gtty");
const hooks = @import("hooks.zig");
const list = @import("list.zig");

const State = struct {
    dir: list.Owned = .{},
    filter: list.Owned = .{},
    /// This chip sent the cd: the list stays open to show it.
    sent: bool = false,

    pub fn deinit(s: *State) void {
        s.dir.deinit();
        s.filter.deinit();
    }
};

var windows: list.PerWindow(State) = .{};

pub fn onWindowStart(win: *sdk.Window) !void {
    try win.events.registerEvent(.window_changed);
}

pub fn onWindowClose(win: *sdk.Window) !void {
    windows.drop(win.id);
}

pub fn onEvent(win: *sdk.Window, ev: *const sdk.Event) !void {
    if (ev.kind == .button_click) return sdk.dispatch(Actions, win, ev);
    if (ev.kind != .window_changed) return;
    const s = try windows.of(win.id);
    if (ev.remote or ev.folder.len == 0) {
        try win.ui.setDisplayMode(.chip);
        try win.ui.set(.{ .peek = null });
        try win.ui.set(.{ .epeek = null });
        return win.ui.set(.{ .chip = .{ .text = null } });
    }
    const moved = !std.mem.eql(u8, s.dir.s, ev.folder);
    // The shell went elsewhere (not from this list): it is stale.
    if (moved and !s.sent) try win.ui.setDisplayMode(.chip);
    if (!moved) return;
    s.sent = false;
        s.dir.set(ev.folder);
    const base = std.fs.path.basename(ev.folder);
    try win.ui.set(.{ .chip = .{ .text = if (base.len == 0) "/" else base, .onhover = "open" } });
    try win.ui.set(.{ .peek = .{ .expand = true, .hoverExpand = true, .text = ev.folder, .onclick = "copyPath", .data = ev.folder } });
    try setList(win, s);
}

/// The folders above `dir` and `dir` itself, `/` first.
fn fillFolders(dir: []const u8, out: *std.ArrayList([]const u8), a: std.mem.Allocator) !void {
    try out.append(a, dir);
    var end = dir.len;
    while (end > 1) {
        const parent = std.fs.path.dirname(dir[0..end]) orelse break;
        try out.insert(a, 0, parent);
        end = parent.len;
    }
}

fn setList(win: *sdk.Window, s: *const State) !void {
    var arena: std.heap.ArenaAllocator = .init(hooks.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var all: std.ArrayList([]const u8) = .empty;
    try fillFolders(s.dir.s, &all, a);
    var rows: std.ArrayList(sdk.Line) = .empty;
    for (all.items) |d| {
        if (!list.matches(d, s.filter.s)) continue;
        var l: sdk.Line = .{ .text = sdk.newText(d), .onclick = "pick", .data = d };
        if (std.mem.eql(u8, d, s.dir.s)) list.currentLine(&l, d);
        try rows.append(a, l);
    }
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{
        .frame = .{ .set = .{
            .text = sdk.newText(s.dir.s),
            .onclick = "copyPath",
            .data = s.dir.s,
            .filter = .{ .hint = sdk.newText("filter folders"), .onclick = "filter" },
        } },
        .lines = .{ .set = rows.items },
        // The parent, above the current folder by the chip.
        .selected = .{ .set = if (s.filter.s.len == 0) rows.items.len -| 2 else 0 },
        .empty = .{ .set = sdk.newText(if (all.items.len == 0) "no folder above" else "no folder matches") },
    } });
}

pub const Actions = struct {
    pub fn open(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.setDisplayMode(.peek);
    }

    pub fn copyPath(_: *sdk.Window, b: sdk.ButtonClick) !void {
        if (hooks.copy) |f| f(hooks.ctx, b.data, false);
    }

    pub fn filter(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        s.filter.set(b.text);
        try setList(win, s);
    }

    pub fn pick(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        // The current one: its path is copied, as a click on a name in
        // the text does; its row flashes.
        if (std.mem.eql(u8, b.data, s.dir.s)) {
            if (hooks.copy) |f| f(hooks.ctx, b.data, true);
            return;
        }
        try sendCd(win, b.data, &s.sent);
    }
};

/// `cd` to `dir`: green and closed after a second, or a red message and
/// the list stays.
pub fn sendCd(win: *sdk.Window, dir: []const u8, sent: *bool) !void {
    var row: [1]sdk.Text = undefined;
    const ok = if (hooks.cd) |f| f(hooks.ctx, win.id, dir) else false;
    if (ok) {
        sent.* = true;
        return win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .ok }, .message = .{ .set = list.oneRow(&row, "cd sent") } } });
    }
    if (hooks.beep) |f| f(hooks.ctx);
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .err }, .message = .{ .set = list.oneRow(&row, "the shell is busy: cd only at its prompt") } } });
}

test "the folders above, / first, the current last" {
    const t = std.testing;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(t.allocator);
    try fillFolders("/Users/me/src", &out, t.allocator);
    try t.expectEqual(@as(usize, 4), out.items.len);
    try t.expectEqualStrings("/", out.items[0]);
    try t.expectEqualStrings("/Users", out.items[1]);
    try t.expectEqualStrings("/Users/me/src", out.items[3]);
    out.clearRetainingCapacity();
    try fillFolders("/", &out, t.allocator);
    try t.expectEqual(@as(usize, 1), out.items.len);
}
