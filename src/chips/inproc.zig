// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! What running inside the gtty process gives the standard chips, set by
//! App before the first window starts: an allocator, the reaper for the
//! processes they run (git), and whether their own files are kept. No
//! calls into App: everything a chip asks of gtty goes through the SDK
//! (`win.copy`, `win.cd`, `win.sessions`, …), as an installed
//! extension's requests do.

const std = @import("std");
const Process = @import("../core/Process.zig");

pub var gpa: std.mem.Allocator = std.heap.c_allocator;
pub var reaper: ?*Process.Reaper = null;
/// Off in a test script run (`--script`): a chip's own files are kept
/// only when its environment variable says where (`GTTY_FOCUS`).
pub var keep_files: bool = true;
