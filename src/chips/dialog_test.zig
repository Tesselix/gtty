// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! An invisible extension for test scripts (`/dialog form|grid|table|yesno
//! |unasked`, test/dialog.gt): every layout and control through the SDK,
//! as an installed extension would use them. What was answered goes to
//! the status bar.

const std = @import("std");
const sdk = @import("gtty");
const hooks = @import("hooks.zig");

const hosts: []const []const u8 = &.{ "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa" };

const menu_items = [_]sdk.Item{
    .{ .id = "rename", .text = sdk.newText("Rename"), .data = "row" },
    .{ .id = "delete", .text = sdk.newText("Delete"), .data = "row" },
};

/// The matching letters marked, as a chip with a filter may do.
fn setTestList(win: *sdk.Window, filter: []const u8) !void {
    var rows: [hosts.len]sdk.Line = undefined;
    var n: usize = 0;
    for (hosts) |h| {
        var l: sdk.Line = .{ .id = h, .text = sdk.newText(h), .onclick = "said", .onhover = "said", .data = h };
        if (filter.len > 0) {
            const at = std.ascii.indexOfIgnoreCase(h, filter) orelse continue;
            const end = at + filter.len;
            var parts: [3]sdk.TextPart = .{ .{ .string = h[0..at] }, .{ .string = h[at..end], .attr = .{ .fg = 0x202020, .bk = 0xe0b040, .bold = true } }, .{ .string = h[end..] } };
            l.text = sdk.newText(@as([]const sdk.TextPart, &parts));
        }
        if (n == 0) l.prefixButton = .{ .icon = "save", .onclick = "said", .data = "prefix" };
        if (n == 1) l.postButton = .{ .dots = .vertical, .onclick = "said", .items = &menu_items };
        if (n == 2) l.postButton = .{ .dots = .horizontal, .onclick = "said", .data = "dots" };
        if (n == 3) l.postButton = .{ .icon = "save", .onclick = "said", .data = "post" };
        rows[n] = l;
        n += 1;
    }
    var frame: sdk.Frame = .{ .text = sdk.newText("hosts"), .filter = .{
        .hint = sdk.newText("filter hosts"),
        .options = &.{ "alpha", "alpine", "beta" },
        .onclick = "filterHosts",
    } };
    frame.left[0] = .{ .text = sdk.newText("add"), .onclick = "said", .data = "left" };
    frame.right[0] = .{ .icon = "save", .text = sdk.newText("save"), .onclick = "said", .data = "right" };
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .frame = .{ .set = frame }, .lines = .{ .set = rows[0..n] }, .empty = .{ .set = sdk.newText("no host") } } });
}

pub fn onGttyStart(ext: *sdk.Extension) !void {
    ext.log(.info, "started", .{});
}

pub fn onEvent(win: *sdk.Window, ev: *const sdk.Event) !void {
    if (ev.kind == .button_click) try sdk.dispatch(Actions, win, ev);
}

pub const Actions = struct {
    /// Every level, and a message that tries to break out of its line.
    pub fn logLine(win: *sdk.Window, _: sdk.ButtonClick) !void {
        win.log(.debug, "a debug line {d}", .{1});
        win.log(.info, "an info line", .{});
        win.log(.warn, "two\nlines \x1b[31mred", .{});
        win.log(.err, "an error line", .{});
    }
    /// A handler that fails.
    pub fn logFail(_: *sdk.Window, _: sdk.ButtonClick) !void {
        return error.BrokenOnPurpose;
    }
    /// A chip with a peek and an epeek that use everything standard chips
    /// don't: styled text, both dots, a post button, the filter's options.
    pub fn peek(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .chip = .{ .text = sdk.newText(.{ .{ "ext ", .{ .bold = true } }, .{ "chip", .{ .fg = 0xe0b040 } } }), .onclick = "said", .onhover = "said", .data = "chip" } });
        try win.ui.set(.{ .peek = .{
            .expand = true,
            .text = sdk.newText(.{ .{ "peek ", .{} }, .{ "line", .{ .stroke = true } } }),
            .onhover = "said",
            .data = "peek text",
            .postButton = .{ .dots = "horizontal", .id = "info", .onclick = "said", .data = "horizontal" },
        } });
        try setTestList(win, "");
    }

    pub fn shellName(win: *sdk.Window, _: sdk.ButtonClick) !void {
        var buf: [100]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&buf, "shell: {s}", .{try win.shell()}) catch "shell");
    }

    /// Writes `note` and reads it back, in both storages.
    pub fn storageWrite(win: *sdk.Window, _: sdk.ButtonClick) !void {
        const name = "note";
        inline for (.{ win.stateful, win.ephemeral }) |st| {
            const f = try st.openWrite(name, 0);
            try f.write("hello from a window");
            try f.close();
        }
        var buf: [64]u8 = undefined;
        const r = try win.stateful.openRead(name, 0);
        const n = try r.read(&buf);
        try r.close();
        var out: [200]u8 = undefined;
        var names: [64]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&out, "storage: read '{s}', files: {s}", .{ buf[0..n], std.mem.trim(u8, try win.stateful.list(&names), "\n") }) catch "storage");
    }

    /// Reads what another window wrote; ephemeral is this window's own.
    pub fn storageRead(win: *sdk.Window, _: sdk.ButtonClick) !void {
        var buf: [64]u8 = undefined;
        const r = try win.stateful.openRead("note", 0);
        const n = try r.read(&buf);
        try r.close();
        const own = if (win.ephemeral.openRead("note", 0)) |f| blk: {
            try f.close();
            break :blk "yes";
        } else |_| "no";
        var out: [200]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&out, "stateful: '{s}', ephemeral here: {s}", .{ buf[0..n], own }) catch "storage");
    }

    /// Opens a file and leaves it open: others get "in use".
    pub fn storageHold(win: *sdk.Window, _: sdk.ButtonClick) !void {
        _ = try win.stateful.openWrite("held", 0);
        hooks.say("storage: held open");
    }

    pub fn storageTry(win: *sdk.Window, _: sdk.ButtonClick) !void {
        if (win.stateful.openRead("held", 0)) |f| {
            try f.close();
            hooks.say("storage: free");
        } else |e| {
            var out: [100]u8 = undefined;
            hooks.say(std.fmt.bufPrint(&out, "storage: {s}", .{@errorName(e)}) catch "storage");
        }
    }

    /// What reached the extension, in the status bar.
    pub fn said(_: *sdk.Window, b: sdk.ButtonClick) !void {
        var buf: [200]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&buf, "said: id={s} text={s} data={s} command={}", .{ b.id, b.text, b.data, b.command }) catch "said");
    }

    pub fn filterHosts(win: *sdk.Window, b: sdk.ButtonClick) !void {
        try setTestList(win, b.text);
    }

    /// Opened on its own, not by the user.
    pub fn peekOpen(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.setDisplayMode(.epeek);
    }

    pub fn peekClose(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.setDisplayMode(.chip);
    }

    pub fn form(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Form layout",
            .layout = "form",
            .timeout = 60,
            .buttons = "okcancel",
            .onclick = "report",
            .fields = .{
                .{ .id = "hint", .type = "label", .label = "One field per line" },
                .{ .id = "name", .type = "text", .label = "Name", .value = "work" },
                .{ .id = "keep", .type = "checkbox", .label = "Keep open", .value = true },
                .{ .id = "host", .type = "dropdown", .label = "Host", .value = "alpha", .filter = true, .options = hosts },
            },
        } });
        try win.ui.showDialog();
    }

    pub fn grid(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Grid layout",
            .layout = "grid",
            .timeout = 60,
            .buttons = "ok",
            .onclick = "report",
            .fields = .{
                .{ .id = "name", .type = "text", .label = "Name", .value = "work" },
                .{ .id = "port", .type = "text", .label = "Port", .value = "22" },
                .{ .id = "keep", .type = "checkbox", .label = "Keep" },
                .{ .id = "host", .type = "dropdown", .label = "Host", .value = "beta", .options = hosts },
            },
        } });
        try win.ui.showDialog();
    }

    pub fn table(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Table layout",
            .layout = "table",
            .columns = 2,
            .rows = 2,
            .timeout = 60,
            .buttons = "okcancel",
            .onclick = "report",
            .fields = .{
                .{ .id = "name", .type = "text", .label = "Name", .value = "work" },
                .{ .id = "host", .type = "dropdown", .label = "Host", .value = "gamma", .options = hosts },
                .{ .id = "keep", .type = "checkbox", .label = "Keep" },
                .{ .id = "port", .type = "text", .label = "Port", .value = "22" },
            },
        } });
        try win.ui.showDialog();
    }

    pub fn yesno(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Yes or no",
            .layout = "form",
            .timeout = 3,
            .buttons = "yesno",
            .onclick = "report",
            .fields = .{.{ .id = "q", .type = "label", .label = "Closes by itself in 3 s" }},
        } });
        try win.ui.showDialog();
    }

    /// A dialog that didn't come from the user: no keyboard.
    pub fn unasked(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Not asked for",
            .layout = "form",
            .buttons = "ok",
            .onclick = "report",
            .fields = .{.{ .id = "name", .type = "text", .label = "Name", .value = "x" }},
        } });
        try win.ui.showDialog();
    }

    pub fn report(win: *sdk.Window, b: sdk.ButtonClick) !void {
        var buf: [200]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&buf, "dialog: {s} name={s} port={s} keep={} host={s}", .{ b.id, b.field("name") orelse "-", b.field("port") orelse "-", b.checked("keep"), b.field("host") orelse "-" }) catch "dialog");
        // A name of "bad": rejected, the dialog stays.
        if (b.is("ok") and std.mem.eql(u8, b.field("name") orelse "", "bad")) {
            return win.ui.set(.{ .dialog = .{ .@"error" = "that name is not allowed" } });
        }
        if (!b.is("kill") and !b.is("timeout")) try win.ui.closeDialog();
    }
};
