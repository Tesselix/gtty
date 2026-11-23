// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The session chip: always there, also with no session saved. Hovering
//! or clicking opens its epeek: the sessions used last, the last used at
//! the bottom by the chip; a pick restores it here, with ⌘ (Linux Ctrl) in
//! a new gtty. Its save button asks for a name in a dialog, the name gtty
//! suggests filled in. It listens for no event: the sessions file is
//! gtty's (`win.sessions`), shared by every gtty.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("gtty");
const list = @import("list.zig");

const shown_max = 7;

/// Under the list: as VS Code's recent list.
const new_window_hint = if (builtin.os.tag == .macos)
    "⌘-click / ⌘Enter: open in a new window"
else
    "Ctrl+click / Ctrl+Enter: open in a new window";

const State = struct {
    filter: list.Owned = .{},

    pub fn deinit(s: *State) void {
        s.filter.deinit();
    }
};

var windows: list.PerWindow(State) = .{};

pub fn onWindowStart(win: *sdk.Window) !void {
    try win.ui.set(.{ .chip = .{ .text = "session", .onclick = "open", .onhover = "open" } });
}

pub fn onWindowClose(win: *sdk.Window) !void {
    windows.drop(win.id);
}

pub fn onEvent(win: *sdk.Window, ev: *const sdk.Event) !void {
    if (ev.kind == .button_click) try sdk.dispatch(Actions, win, ev);
}

fn setList(win: *sdk.Window, s: *const State) !void {
    var all: [shown_max]sdk.Session = undefined;
    var buf: [shown_max * 320]u8 = undefined;
    const got = try win.sessions.list(&buf, &all);
    const n = got.len;
    var rows: [shown_max]sdk.Line = undefined;
    var k: usize = 0;
    for (all[0..n]) |x| {
        if (!list.matches(x.name, s.filter.s)) continue;
        rows[k] = .{ .text = sdk.newText(x.name), .onclick = "pick", .data = x.id };
        k += 1;
    }
    var frame: sdk.Frame = .{
        .text = sdk.newText("sessions"),
        .filter = .{ .hint = sdk.newText("filter sessions"), .onclick = "filter" },
    };
    frame.right = .{
        .{ .icon = "list", .text = sdk.newText("manage"), .onclick = "manage" },
        .{ .icon = "save", .text = sdk.newText("save"), .onclick = "save" },
    };
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{
        .frame = .{ .set = frame },
        .lines = .{ .set = rows[0..k] },
        .selected = .{ .set = k -| 1 },
        .empty = .{ .set = sdk.newText(if (n == 0) "no saved sessions" else "no session matches") },
        .footer = .{ .set = sdk.newText(if (n > 0) new_window_hint else "") },
    } });
}

pub const Actions = struct {
    pub fn open(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try setList(win, try windows.of(win.id));
        try win.ui.setDisplayMode(.epeek);
    }

    pub fn filter(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        s.filter.set(b.text);
        try setList(win, s);
    }

    pub fn pick(win: *sdk.Window, b: sdk.ButtonClick) !void {
        try win.sessions.restore(b.data, b.command);
    }

    pub fn manage(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.sessions.manage();
    }

    /// Asks for a name, gtty's suggestion filled in.
    pub fn save(win: *sdk.Window, _: sdk.ButtonClick) !void {
        var buf: [200]u8 = undefined;
        const name = win.sessions.suggestName(&buf) catch |e| {
            if (e != error.NothingToSave) return e;
            try win.beep();
            return win.notice("snapshot: no shell window to save", .err);
        };
        try win.ui.setDisplayMode(.chip);
        try win.ui.set(.{ .dialog = .{
            .title = "Save the current session",
            .layout = "form",
            .timeout = 30,
            .buttons = "okcancel",
            .onclick = "saveSession",
            .fields = .{
                .{ .id = "hint", .type = "label", .label = "Type a name, or keep this one · Esc leaves it unsaved" },
                .{ .id = "name", .type = "text", .label = "Name", .value = name },
            },
        } });
        try win.ui.showDialog();
    }

    pub fn saveSession(win: *sdk.Window, b: sdk.ButtonClick) !void {
        if (b.is("kill") or b.is("timeout")) return win.notice(if (b.is("timeout")) "no answer: session not saved" else "session not saved", .plain);
        if (b.is("ok")) {
            const name = std.mem.trim(u8, b.field("name") orelse "", " \t");
            if (name.len == 0) return win.ui.set(.{ .dialog = .{ .@"error" = "a session needs a name" } });
            try win.sessions.save(name);
        } else try win.notice("session not saved", .plain);
        try win.ui.closeDialog();
    }
};
