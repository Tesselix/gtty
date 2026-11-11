// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! history: a chip that keeps the commands worth running again (with a
//! flag, no cd / ls / find). A click on one copies it. See ../README.md.

const std = @import("std");
const builtin = @import("builtin");
const gtty = @import("gtty");
const rules = @import("rules.zig");

const file = "history.tsv";
const shown = 200; // lines in the list at most
const wait_ms = 300; // storage timeout
const gpa = std.heap.c_allocator;

/// `onWindowStart` runs once per window: the filter's text by `win.id`.
var filters: std.AutoHashMapUnmanaged(u32, []u8) = .empty;

pub fn main() !void {
    try gtty.run(@This());
}

pub fn onWindowStart(win: *gtty.Window) !void {
    try filters.put(gpa, win.id, &.{});
    try win.events.registerEvent(.command_started);
    // A click and the mouse resting on the chip both open the list.
    try win.ui.set(.{ .chip = .{ .text = "history", .onclick = "open", .onhover = "open" } });
    try reload(win);
}

pub fn onWindowClose(win: *gtty.Window) !void {
    if (filters.fetchRemove(win.id)) |kv| gpa.free(kv.value);
}

pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {
    switch (ev.kind) {
        .button_click => try gtty.dispatch(Actions, win, ev),
        .command_started => if (rules.worth(ev.command)) {
            var list = try load(win);
            defer rules.free(gpa, &list);
            try rules.record(gpa, &list, std.mem.trim(u8, ev.command, " \t\r\n"), now());
            save(win, list.items) catch |e| switch (e) {
                error.FileInUse => win.log(.warn, "history busy: a command not kept", .{}),
                else => return e,
            };
        },
        else => {},
    }
}

extern "c" fn time(t: ?*i64) i64;

fn now() i64 {
    return time(null);
}

// ---- storage ----

fn load(win: *gtty.Window) !rules.List {
    const f = win.stateful.openRead(file, wait_ms) catch |e| switch (e) {
        error.NoFile => return .empty,
        else => return e,
    };
    defer f.close() catch {};
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try text.appendSlice(gpa, buf[0..n]);
    }
    return rules.parse(gpa, text.items);
}

fn save(win: *gtty.Window, list: []const rules.Entry) !void {
    const text = try rules.format(gpa, list);
    defer gpa.free(text);
    const f = try win.stateful.openWrite(file, wait_ms);
    errdefer f.close() catch {};
    try f.write(text);
    try f.close(); // the write takes the old file's place here
}

// ---- the clipboard: the SDK can't type into a window ----

const FILE = opaque {};
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn pclose(f: *FILE) c_int;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fwrite(p: [*]const u8, size: usize, n: usize, f: *FILE) usize;

const tools: []const [*:0]const u8 = if (builtin.os.tag == .macos)
    &.{"pbcopy 2>/dev/null"}
else
    &.{ "wl-copy 2>/dev/null", "xclip -selection clipboard 2>/dev/null", "xsel --clipboard --input 2>/dev/null" };

/// null when copied, else why not.
fn copy(text: []const u8) ?[]const u8 {
    if (std.c.getenv("HISTORY_CLIP_FILE")) |path| { // the tests: no real clipboard
        const f = fopen(path, "w") orelse return "can't write HISTORY_CLIP_FILE";
        _ = fwrite(text.ptr, 1, text.len, f);
        _ = fclose(f);
        return null;
    }
    for (tools) |cmd| {
        if (std.mem.startsWith(u8, std.mem.span(cmd), "wl-copy") and std.c.getenv("WAYLAND_DISPLAY") == null) continue;
        const p = popen(cmd, "w") orelse continue;
        const wrote = fwrite(text.ptr, 1, text.len, p) == text.len;
        if (pclose(p) == 0 and wrote) return null;
    }
    return "no clipboard tool (pbcopy, wl-copy, xclip, xsel)";
}

const paste = if (builtin.os.tag == .macos) "⌘V" else "Ctrl+Shift+V";

// ---- the list ----

fn reload(win: *gtty.Window) !void {
    var list = try load(win); // other windows may have added commands
    defer rules.free(gpa, &list);
    try setList(win, list.items);
}

/// Everything `set` sends is copied, so an arena for this call is enough.
fn setList(win: *gtty.Window, list: []const rules.Entry) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const filter = filters.get(win.id) orelse &.{};

    var rows: std.ArrayList(gtty.Line) = .empty;
    for (list) |e| {
        // One row: line breaks as ⏎, tabs as blanks.
        const one = try std.mem.replaceOwned(u8, arena, e.cmd, "\n", " ⏎ ");
        std.mem.replaceScalar(u8, one, '\t', ' ');
        std.mem.replaceScalar(u8, one, '\r', ' ');
        const at = if (filter.len == 0) 0 else std.ascii.indexOfIgnoreCase(one, filter) orelse continue;
        var parts: std.ArrayList(gtty.TextPart) = .empty;
        if (filter.len == 0) {
            try parts.append(arena, .{ .string = one });
        } else {
            // Mark the letters that match.
            try parts.appendSlice(arena, &.{
                .{ .string = one[0..at] },
                .{ .string = one[at..][0..filter.len], .attr = .{ .fg = 0x202020, .bk = 0xe0b040 } },
                .{ .string = one[at + filter.len ..] },
            });
        }
        if (e.count > 1) try parts.append(arena, .{
            .string = try std.fmt.allocPrint(arena, "  ×{d}", .{e.count}),
            .attr = .{ .fg = 0x8a8a8a },
        });
        const items = try arena.dupe(gtty.Item, &.{
            .{ .id = "copy", .text = gtty.newText("Copy"), .data = e.cmd },
            .{ .id = "forget", .text = gtty.newText("Forget"), .data = e.cmd },
        });
        try rows.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{d}", .{rows.items.len}),
            .text = gtty.newText(@as([]const gtty.TextPart, parts.items)),
            .onclick = "pick",
            .data = e.cmd,
            .postButton = .{ .dots = .vertical, .onclick = "rowMenu", .items = items },
        });
    }
    const lines = rows.items[rows.items.len -| shown..];
    const frame: gtty.Frame = .{
        .text = gtty.newText("history"),
        .filter = .{ .hint = gtty.newText("filter commands"), .onclick = "filter" },
    };
    try win.ui.set(.{ .epeek = gtty.EpeekUpdate{
        .frame = .{ .set = frame },
        .lines = .{ .set = lines },
        .selected = .{ .set = lines.len -| 1 }, // the newest, next to the chip
        .empty = .{ .set = gtty.newText(if (filter.len > 0) "no commands match" else "no commands yet: run one with a flag") },
        .footer = .{ .set = gtty.newText("a click copies it, " ++ paste ++ " pastes it") },
        .state = .{ .set = .idle },
        .message = .{ .set = &.{} },
    } });
}

fn copyIt(win: *gtty.Window, cmd: []const u8) !void {
    if (copy(cmd)) |why| {
        win.log(.warn, "{s}", .{why});
        const msg = [_]gtty.Text{gtty.newText(why)};
        try win.ui.set(.{ .epeek = gtty.EpeekUpdate{ .state = .{ .set = .err }, .message = .{ .set = &msg } } });
    } else {
        const msg = [_]gtty.Text{gtty.newText("copied: " ++ paste ++ " pastes it")};
        try win.ui.set(.{ .epeek = gtty.EpeekUpdate{ .state = .{ .set = .ok }, .message = .{ .set = &msg } } });
    }
}

/// Every `onclick` / `onhover` name is a `pub fn` here.
const Actions = struct {
    pub fn open(win: *gtty.Window, _: gtty.ButtonClick) !void {
        try reload(win);
        try win.ui.setDisplayMode(.epeek);
    }

    pub fn filter(win: *gtty.Window, b: gtty.ButtonClick) !void {
        const slot = filters.getPtr(win.id) orelse return;
        const text = try gpa.dupe(u8, b.text);
        gpa.free(slot.*);
        slot.* = text;
        try reload(win);
    }

    pub fn pick(win: *gtty.Window, b: gtty.ButtonClick) !void {
        try copyIt(win, b.data);
    }

    /// A ⋮ pick: `b.id` and `b.data` are the item's.
    pub fn rowMenu(win: *gtty.Window, b: gtty.ButtonClick) !void {
        if (b.is("copy")) return copyIt(win, b.data);
        if (!b.is("forget")) return;
        var list = try load(win);
        defer rules.free(gpa, &list);
        rules.forget(gpa, &list, b.data);
        try save(win, list.items);
        try setList(win, list.items);
    }
};

test {
    _ = rules;
    const d = gtty.Definition.of(@This(), "history");
    try std.testing.expect(d.onEvent != null);
}
