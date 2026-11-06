// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What the standard chips ask of gtty beyond the SDK, set by App before
//! the first window starts: they live inside it, and work on its folders,
//! clipboard and sessions.

const std = @import("std");
const Process = @import("../core/Process.zig");

pub var ctx: *anyopaque = undefined;
/// A short notice in the status bar.
pub var notice: ?*const fn (ctx: *anyopaque, text: []const u8, kind: Notice) void = null;
pub const Notice = enum { plain, ok, err };
/// Save this gtty's windows as session `name`.
pub var saveSession: ?*const fn (ctx: *anyopaque, name: []const u8) void = null;

pub var gpa: std.mem.Allocator = std.heap.c_allocator;
pub var reaper: ?*Process.Reaper = null;
/// `cd` in window `uid`; false: its shell isn't at its prompt.
pub var cd: ?*const fn (ctx: *anyopaque, uid: u32, dir: []const u8) bool = null;
pub var cwd: ?*const fn (ctx: *anyopaque, uid: u32) []const u8 = null;
/// The host of window `uid`'s ssh / mosh session.
pub var remoteDest: ?*const fn (ctx: *anyopaque, uid: u32) []const u8 = null;
/// On the clipboard and the paste history; the peek's top text, or
/// `row`: its selected row, flashes.
pub var copy: ?*const fn (ctx: *anyopaque, text: []const u8, row: bool) void = null;
pub var beep: ?*const fn (ctx: *anyopaque) void = null;
/// The branch of window `uid` changed: show it now.
pub var branchChanged: ?*const fn (ctx: *anyopaque, uid: u32) void = null;
/// The number the user sees on window `uid`.
pub var serial: ?*const fn (ctx: *anyopaque, uid: u32) u32 = null;
pub var restore: ?*const fn (ctx: *anyopaque, id: []const u8, new_window: bool) void = null;
pub var manage: ?*const fn (ctx: *anyopaque) void = null;
/// The session chip's save: asks for a name.
pub var askSave: ?*const fn (ctx: *anyopaque, uid: u32) void = null;
pub var syncFocus: ?*const fn (ctx: *anyopaque) void = null;
/// The sessions used last into `out`, the last used last; how many.
pub var recentSessions: ?*const fn (ctx: *anyopaque, out: []SessionRow) usize = null;

pub const SessionRow = struct { name: []const u8, id: []const u8 };

pub fn say(text: []const u8) void {
    sayAs(text, .plain);
}

pub fn sayAs(text: []const u8, kind: Notice) void {
    if (notice) |f| f(ctx, text, kind);
}
