// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The standard chips, in `JobWindow.Chip`'s order, then the test
//! extension (no chip).

const sdk = @import("gtty");

pub const folder = @import("folder.zig");
pub const git = @import("git.zig");
pub const focus = @import("focus.zig");
pub const session = @import("session.zig");
pub const dialog_test = @import("dialog_test.zig");
pub const hooks = @import("hooks.zig");

pub const all = [_]sdk.Definition{
    sdk.Definition.of(folder, "folder"),
    sdk.Definition.of(git, "git"),
    sdk.Definition.of(focus, "focus"),
    sdk.Definition.of(session, "session"),
    sdk.Definition.of(dialog_test, "test"),
};

/// The index of the test extension.
pub const test_index = all.len - 1;
