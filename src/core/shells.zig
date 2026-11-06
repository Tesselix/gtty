// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Is a program a shell? Whatever the system lists (/etc/shells), and the
//! common ones it may not.

const std = @import("std");

const known = [_][]const u8{ "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "mksh", "pdksh", "csh", "tcsh", "nu", "elvish", "xonsh", "pwsh", "yash", "oil", "osh", "ion", "rc", "es" };

/// The name a program runs under: no folder, and no login `-`.
pub fn baseName(arg0: []const u8) []const u8 {
    const b = std.fs.path.basename(arg0);
    return if (b.len > 1 and b[0] == '-') b[1..] else b;
}

/// `etc_shells`: the text of /etc/shells.
pub fn isShell(name: []const u8, etc_shells: []const u8) bool {
    for (known) |k| if (std.mem.eql(u8, k, name)) return true;
    var it = std.mem.splitScalar(u8, etc_shells, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        if (std.mem.eql(u8, std.fs.path.basename(l), name)) return true;
    }
    return false;
}

test "shells: any the system lists, the usual ones, not programs" {
    const t = std.testing;
    try t.expect(isShell("zsh", ""));
    try t.expect(isShell("sh", ""));
    try t.expect(isShell("myshell", "# comment\n/bin/bash\n/opt/x/myshell\n"));
    try t.expect(!isShell("vim", "/bin/bash\n"));
    try t.expect(!isShell("ssh", "/bin/bash\n"));
    try t.expectEqualStrings("zsh", baseName("-zsh"));
    try t.expectEqualStrings("bash", baseName("/bin/bash"));
}
