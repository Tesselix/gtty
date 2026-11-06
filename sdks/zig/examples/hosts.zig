// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! A complete extension: a chip that keeps a list of hosts. It shows every
//! part of the SDK in use and is compiled by `zig build test`, so it can't
//! fall behind. Start a new extension from a copy of this file.

const std = @import("std");
const gtty = @import("gtty");

const file = "hosts.txt";

/// `onWindowStart` runs once per window, so state goes by `win.id`.
const State = struct { filter: [64]u8 = undefined, filter_len: usize = 0 };
var windows: std.AutoHashMapUnmanaged(u32, State) = .empty;
const gpa = std.heap.c_allocator;

pub fn onWindowStart(win: *gtty.Window) !void {
    try windows.put(gpa, win.id, .{});
    try win.events.registerEvent(.window_changed);
    // A UI needs a chip. Hover opens nothing by itself: `onhover` does.
    try win.ui.set(.{ .chip = .{ .text = "hosts", .onhover = "open" } });
    try win.ui.set(.{ .peek = .{
        .expand = true,
        .onexpand = "refresh",
        .text = gtty.newText(.{ "hosts", .{ .bold = true } }),
        .postButton = .{ .dots = "horizontal", .onclick = "about" },
    } });
    try setList(win);
}

pub fn onWindowClose(win: *gtty.Window) !void {
    _ = windows.remove(win.id);
}

pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {
    switch (ev.kind) {
        .button_click => try gtty.dispatch(Actions, win, ev),
        // Registered above: only the folder is of interest here.
        .window_changed => try win.ui.set(.{ .chip = .{ .dimmed = ev.remote } }),
        .command_started => {},
    }
}

/// Reads the hosts file into `buf`. No file yet: an empty list.
fn readHosts(win: *gtty.Window, buf: []u8) ![]const u8 {
    const f = win.stateful.openRead(file, 200) catch |e| switch (e) {
        error.NoFile => return "",
        else => return e,
    };
    defer f.close() catch {};
    var n: usize = 0;
    while (n < buf.len) {
        const k = try f.read(buf[n..]);
        if (k == 0) break;
        n += k;
    }
    return buf[0..n];
}

const row_menu = [_]gtty.Item{
    .{ .id = "connect", .text = gtty.newText("Connect") },
    .{ .id = "remove", .text = gtty.newText("Remove") },
};

/// Everything in `lines` is copied by `set`, so local buffers are fine.
fn setList(win: *gtty.Window) !void {
    const st = windows.getPtr(win.id) orelse return;
    const filter = st.filter[0..st.filter_len];
    var buf: [4096]u8 = undefined;
    const text = try readHosts(win, &buf);
    var rows: [64]gtty.Line = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |host| {
        if (n == rows.len) break;
        // gtty doesn't filter: the extension decides what the text means.
        const at = if (filter.len == 0) 0 else std.ascii.indexOfIgnoreCase(host, filter) orelse continue;
        var line: gtty.Line = .{ .id = host, .text = gtty.newText(host), .onclick = "pick", .data = host };
        if (filter.len > 0) {
            // Mark the letters that match. A typed `Line` needs `newText`.
            const parts = [_]gtty.TextPart{
                .{ .string = host[0..at] },
                .{ .string = host[at..][0..filter.len], .attr = .{ .fg = 0x202020, .bk = 0xe0b040 } },
                .{ .string = host[at + filter.len ..] },
            };
            line.text = gtty.newText(@as([]const gtty.TextPart, &parts));
        }
        line.postButton = .{ .dots = .vertical, .onclick = "rowMenu", .items = &row_menu };
        rows[n] = line;
        n += 1;
    }
    var frame: gtty.Frame = .{
        .text = gtty.newText("hosts"),
        .filter = .{ .hint = gtty.newText("filter hosts"), .onclick = "filter" },
    };
    frame.right[0] = .{ .icon = "save", .text = gtty.newText("add"), .onclick = "askHost" };
    try win.ui.set(.{ .epeek = gtty.EpeekUpdate{
        .frame = .{ .set = frame },
        .lines = .{ .set = rows[0..n] },
        .selected = .{ .set = 0 },
        .empty = .{ .set = gtty.newText("no hosts") },
    } });
}

/// Every `onclick` / `onhover` / `onexpand` name is a `pub fn` here.
const Actions = struct {
    pub fn open(win: *gtty.Window, _: gtty.ButtonClick) !void {
        win.log(.debug, "opening the peek", .{});
        try win.ui.setDisplayMode(.peek);
    }

    /// Other windows may have added hosts.
    pub fn refresh(win: *gtty.Window, _: gtty.ButtonClick) !void {
        try setList(win);
    }

    pub fn filter(win: *gtty.Window, b: gtty.ButtonClick) !void {
        const st = windows.getPtr(win.id) orelse return;
        st.filter_len = @min(b.text.len, st.filter.len);
        @memcpy(st.filter[0..st.filter_len], b.text[0..st.filter_len]);
        try setList(win);
    }

    pub fn pick(win: *gtty.Window, b: gtty.ButtonClick) !void {
        try win.ui.set(.{ .chip = .{ .text = b.data } });
        try win.ui.setDisplayMode(.chip); // gtty only reports: close it here
    }

    /// A ⋮ pick: `b.id` is the item's, `b.data` the item's.
    pub fn rowMenu(win: *gtty.Window, b: gtty.ButtonClick) !void {
        if (b.is("connect")) try win.ui.setDisplayMode(.chip);
    }

    pub fn about(win: *gtty.Window, _: gtty.ButtonClick) !void {
        var buf: [80]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "running under {s}", .{try win.shell()});
        try win.ui.set(.{ .dialog = .{
            .title = "About hosts",
            .layout = "form",
            .timeout = 20,
            .buttons = "ok",
            .onclick = "closeIt",
            .fields = .{.{ .id = "info", .type = "label", .label = line }},
        } });
        try win.ui.showDialog();
    }

    pub fn closeIt(win: *gtty.Window, b: gtty.ButtonClick) !void {
        // After `kill` and `timeout` the dialog is already gone.
        if (!b.is("kill") and !b.is("timeout")) try win.ui.closeDialog();
    }

    pub fn askHost(win: *gtty.Window, _: gtty.ButtonClick) !void {
        try win.ui.set(.{ .dialog = .{
            .title = "Add a host",
            .layout = "form",
            .timeout = 30,
            .buttons = "okcancel",
            .onclick = "addHost",
            .fields = .{
                .{ .id = "host", .type = "text", .label = "Host", .value = "" },
                .{ .id = "pin", .type = "checkbox", .label = "Show on the chip", .value = false },
                .{ .id = "kind", .type = "dropdown", .label = "Kind", .value = "ssh", .options = &[_][]const u8{ "ssh", "mosh" }, .filter = false },
            },
        } });
        try win.ui.showDialog();
    }

    pub fn addHost(win: *gtty.Window, b: gtty.ButtonClick) !void {
        if (b.is("kill") or b.is("timeout")) return;
        if (b.is("ok")) {
            const host = b.field("host") orelse "";
            // To reject input, update the dialog and leave it open.
            if (host.len == 0) return win.ui.set(.{ .dialog = .{ .@"error" = "enter a host" } });
            var buf: [4096]u8 = undefined;
            const old = try readHosts(win, &buf);
            // A write replaces the whole file, at `close`.
            const f = try win.stateful.openWrite(file, 200);
            errdefer f.close() catch {};
            try f.write(old);
            try f.write(host);
            try f.write("\n");
            try f.close();
            if (b.checked("pin")) try win.ui.set(.{ .chip = .{ .text = host } });
            try setList(win);
        }
        try win.ui.closeDialog(); // the buttons only report
    }
};

test "the extension compiles against the SDK" {
    const d = gtty.Definition.of(@This(), "hosts");
    try std.testing.expect(d.onEvent != null);
    try std.testing.expect(d.onWindowStart != null);
}
