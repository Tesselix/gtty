// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The git chip: the branch, in a remote session the remote one; outside
//! a repo dimmed, with the label `git`. Its peek is the full branch name
//! with a copy button; its epeek the local branches, read when it opens:
//! a pick runs `git switch` in the background. The two git runs are polled
//! by `tick`, from App, once a frame: a chip inside gtty can't block it.

const std = @import("std");
const sdk = @import("gtty");
const core_git = @import("../core/git.zig");
const hooks = @import("hooks.zig");
const list = @import("list.zig");

const no_git_label = "git";

const State = struct {
    /// The connection, for what `tick` finds; gone with the window.
    win: ?*sdk.Window = null,
    dir: list.Owned = .{},
    branch: list.Owned = .{},
    target: list.Owned = .{},
    filter: list.Owned = .{},
    branches: std.ArrayList([]u8) = .empty,
    list_run: ?core_git.Run = null,
    switch_run: ?core_git.Run = null,

    fn clearBranches(s: *State) void {
        for (s.branches.items) |b| hooks.gpa.free(b);
        s.branches.clearRetainingCapacity();
    }

    pub fn deinit(s: *State) void {
        s.clearBranches();
        s.branches.deinit(hooks.gpa);
        if (hooks.reaper) |r| {
            if (s.list_run) |*x| x.deinit(hooks.gpa, r);
            if (s.switch_run) |*x| x.deinit(hooks.gpa, r);
        }
        s.dir.deinit();
        s.branch.deinit();
        s.target.deinit();
        s.filter.deinit();
    }
};

var windows: list.PerWindow(State) = .{};

pub fn onWindowStart(win: *sdk.Window) !void {
    try win.events.registerEvent(.window_changed);
    (try windows.of(win.id)).win = win;
}

pub fn onWindowClose(win: *sdk.Window) !void {
    windows.drop(win.id);
}

pub fn onEvent(win: *sdk.Window, ev: *const sdk.Event) !void {
    if (ev.kind == .button_click) return sdk.dispatch(Actions, win, ev);
    if (ev.kind != .window_changed) return;
    const s = try windows.of(win.id);
    const in_repo = ev.branch.len > 0;
    if (!in_repo) {
        try win.ui.setDisplayMode(.chip);
        try win.ui.set(.{ .peek = null });
        try win.ui.set(.{ .epeek = null });
        return win.ui.set(.{ .chip = .{ .text = no_git_label, .dimmed = true, .onclick = null, .onhover = null } });
    }
    s.dir.set(ev.folder);
    s.branch.set(ev.branch);
    // The branch of a remote folder: switching would run git here, in the
    // wrong folder.
    if (ev.remote) {
        try win.ui.setDisplayMode(.chip);
        try win.ui.set(.{ .peek = null });
        try win.ui.set(.{ .epeek = null });
        return win.ui.set(.{ .chip = .{ .text = ev.branch, .dimmed = false, .onclick = "remoteNote", .onhover = "remoteNote", .data = ev.branch } });
    }
    try win.ui.set(.{ .chip = .{ .text = ev.branch, .dimmed = false, .onclick = null, .onhover = "open" } });
    try win.ui.set(.{ .peek = .{
        .expand = true,
        .onexpand = "load",
        .text = ev.branch,
        .prefixButton = .{ .icon = "copy", .onclick = "copy", .data = ev.branch },
    } });
    try setList(win, s);
}

fn setList(win: *sdk.Window, s: *const State) !void {
    var arena: std.heap.ArenaAllocator = .init(hooks.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(sdk.Line) = .empty;
    var selected: usize = 0;
    for (s.branches.items) |b| {
        if (!list.matches(b, s.filter.s)) continue;
        var l: sdk.Line = .{ .text = sdk.newText(b), .onclick = "pick", .data = b };
        if (std.mem.eql(u8, b, s.branch.s)) {
            list.currentLine(&l, b);
            if (s.filter.s.len == 0) selected = rows.items.len;
        } else if (s.switch_run != null and std.mem.eql(u8, b, s.target.s)) {
            l.text = sdk.newText(.{ b, .{ .fg = list.blue } });
        }
        try rows.append(a, l);
    }
    var frame: sdk.Frame = .{
        .text = sdk.newText(s.branch.s),
        .filter = .{ .hint = sdk.newText("filter branches"), .onclick = "filter" },
    };
    frame.left[0] = .{ .icon = "copy", .onclick = "copy", .data = s.branch.s };
    try win.ui.set(.{ .epeek = sdk.EpeekUpdate{
        .frame = .{ .set = frame },
        .lines = .{ .set = rows.items },
        .selected = .{ .set = selected },
        .empty = .{ .set = sdk.newText(if (s.list_run != null) "loading branches…" else if (s.branches.items.len == 0) "no local branches" else "no branch matches") },
    } });
}

pub const Actions = struct {
    pub fn open(win: *sdk.Window, _: sdk.ButtonClick) !void {
        try win.ui.setDisplayMode(.peek);
    }

    pub fn remoteNote(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const host = if (hooks.remoteDest) |f| f(hooks.ctx, win.id) else "";
        var buf: [300]u8 = undefined;
        hooks.say(std.fmt.bufPrint(&buf, "{s} on {s} (switching branches there: not yet)", .{ b.data, host }) catch "not yet");
    }

    pub fn copy(_: *sdk.Window, b: sdk.ButtonClick) !void {
        if (hooks.copy) |f| f(hooks.ctx, b.data, false);
    }

    /// The epeek opened: read the branches.
    pub fn load(win: *sdk.Window, _: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        if (s.list_run != null) return;
        s.clearBranches();
        s.list_run = startGit(s, &core_git.list_branches);
        try setList(win, s);
    }

    pub fn filter(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        s.filter.set(b.text);
        try setList(win, s);
    }

    pub fn pick(win: *sdk.Window, b: sdk.ButtonClick) !void {
        const s = try windows.of(win.id);
        if (s.switch_run != null) return;
        var row: [1]sdk.Text = undefined;
        if (std.mem.eql(u8, b.data, s.branch.s)) {
            return win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .ok }, .message = .{ .set = list.oneRow(&row, "already on this branch") } } });
        }
        s.target.set(b.data);
        const args = [_][]const u8{ "switch", b.data };
        s.switch_run = startGit(s, &args);
        if (s.switch_run == null) {
            return win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .err }, .message = .{ .set = list.oneRow(&row, "could not run git") } } });
        }
        try setList(win, s);
        try win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .busy }, .message = .{ .set = list.oneRow(&row, "switching…") } } });
    }
};

fn startGit(s: *State, args: []const []const u8) ?core_git.Run {
    const z = hooks.gpa.dupeZ(u8, s.dir.s) catch return null;
    defer hooks.gpa.free(z);
    return core_git.Run.start(hooks.gpa, z, args) catch null;
}

/// Once a frame: collect the git runs.
pub fn tick() void {
    const reaper = hooks.reaper orelse return;
    var it = windows.map.valueIterator();
    while (it.next()) |sp| {
        const s = sp.*;
        const win = s.win orelse continue;
        if (s.list_run) |*r| if (r.tick(hooks.gpa, reaper)) {
            listDone(win, s, r);
            r.deinit(hooks.gpa, reaper);
            s.list_run = null;
            setList(win, s) catch {};
        };
        if (s.switch_run) |*r| if (r.tick(hooks.gpa, reaper)) {
            const ok = r.code == 0;
            var buf: [600]u8 = undefined;
            if (ok) switched(win, s, &buf) else failed(win, s, r.out.items, &buf);
            r.deinit(hooks.gpa, reaper);
            s.switch_run = null;
            setList(win, s) catch {};
        };
    }
}

fn listDone(win: *sdk.Window, s: *State, r: *const core_git.Run) void {
    if (r.code == 0) {
        const S = struct {
            fn add(st: *State, l: []const u8) void {
                const b = hooks.gpa.dupe(u8, l) catch return;
                st.branches.append(hooks.gpa, b) catch hooks.gpa.free(b);
            }
        };
        core_git.lines(r.out.items, s, S.add);
    } else {
        _ = showError(win, r.out.items);
    }
}

fn switched(win: *sdk.Window, s: *State, buf: []u8) void {
    var row: [1]sdk.Text = undefined;
    win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .ok }, .message = .{ .set = list.oneRow(&row, "switched") } } }) catch {};
    // Show the new branch on the chip at once.
    if (hooks.branchChanged) |f| f(hooks.ctx, win.id);
    const n = if (hooks.serial) |f| f(hooks.ctx, win.id) else 0;
    hooks.sayAs(std.fmt.bufPrint(buf, "#{d}: switched to {s}", .{ n, s.target.s }) catch "switched", .ok);
}

fn failed(win: *sdk.Window, s: *State, out: []const u8, buf: []u8) void {
    _ = s;
    const first = showError(win, out);
    if (hooks.beep) |f| f(hooks.ctx);
    const n = if (hooks.serial) |f| f(hooks.ctx, win.id) else 0;
    hooks.sayAs(std.fmt.bufPrint(buf, "#{d}: git: {s}", .{ n, first }) catch "git failed", .err);
}

/// The last lines of git's output, in red. The first of them.
fn showError(win: *sdk.Window, out: []const u8) []const u8 {
    var rows: [4]sdk.Text = undefined;
    const shown = lastLines(out, &rows);
    win.ui.set(.{ .epeek = sdk.EpeekUpdate{ .state = .{ .set = .err }, .message = .{ .set = shown } } }) catch {};
    return shown[0].parts[0].string;
}

fn lastLines(out: []const u8, rows: *[4]sdk.Text) []const sdk.Text {
    var all: [8][]const u8 = undefined;
    var n: usize = 0;
    const S = struct {
        fn add(ctx: struct { *[8][]const u8, *usize }, l: []const u8) void {
            const arr, const k = ctx;
            if (k.* == arr.len) {
                std.mem.copyForwards([]const u8, arr[0 .. arr.len - 1], arr[1..]);
                k.* -= 1;
            }
            arr[k.*] = l;
            k.* += 1;
        }
    };
    core_git.lines(out, .{ &all, &n }, S.add);
    const keep = @min(n, rows.len);
    if (keep == 0) {
        rows[0] = sdk.newText("git failed");
        return rows[0..1];
    }
    for (all[n - keep .. n], 0..) |l, i| rows[i] = sdk.newText(l);
    return rows[0..keep];
}

test "git's error: its last lines" {
    const t = std.testing;
    var rows: [4]sdk.Text = undefined;
    const r = lastLines("a\nb\nc\nd\ne\nf\n", &rows);
    try t.expectEqual(@as(usize, 4), r.len);
    try t.expectEqualStrings("c", r[0].parts[0].string);
    try t.expectEqualStrings("git failed", lastLines("", &rows)[0].parts[0].string);
}
