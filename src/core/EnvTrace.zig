// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! Where a shell's environment variables and aliases come from: gtty reads
//! the startup files a zsh or bash runs, in the order the shell runs them,
//! and records every place a variable or alias is set, changed or unset
//! (file and line), down to the first one. The job window's "Env &
//! Aliases" view (EnvView.zig) shows the result.
//!
//! Nothing is run: the files are read and interpreted statically
//! (ShParse.zig parses them). What can be known without running a program
//! is followed — `source` / `.` (paths built from variables, globs such as
//! `/etc/profile.d/*.sh`), `if` / `case` / `&&` on tests gtty can answer
//! (`[ -r file ]`, `[ -n "$PS1" ]`, `$-`, `command -v name` through
//! `$PATH`), functions called later (Fedora's `pathmunge`), `local`,
//! `set -a`, zsh's `path` array tied to `PATH`, `$(dirname …)` and a few
//! other pure commands, and macOS's `eval $(/usr/libexec/path_helper -s)`
//! (/etc/paths, /etc/paths.d). A test gtty can't answer runs both
//! branches, their definitions marked conditional (`Def.cond`). A value
//! that needs a program's output keeps that part as written (`$(…)`,
//! `Def.dynamic`); `eval "$(…)"` and `source <(…)` are listed as not
//! traced. Files that can't be read are skipped.
//!
//! The chain (`startup`):
//!   * The inherited environment (what gtty gave the shell it started)
//!     is the base; on Linux /etc/environment (pam_env) comes first, so a value
//!     that came from there is shown as defined there.
//!   * zsh: zshenv, zprofile (login), zshrc, zlogin (login) — each the
//!     global file, then `${ZDOTDIR:-$HOME}/.<name>` — with GLOBAL_RCS /
//!     RCS honoured. The global folder is the one compiled into the zsh
//!     binary (`/etc/zsh` on Debian, Ubuntu, Arch, Gentoo; `/etc` on
//!     macOS, Fedora, RHEL, openSUSE), found by looking for the path in
//!     the binary, else from the distro (`/etc/os-release`).
//!   * bash login: /etc/profile, then the first of ~/.bash_profile,
//!     ~/.bash_login, ~/.profile. Interactive: the system bashrc compiled
//!     in (SYS_BASHRC: /etc/bash.bashrc on Debian, Ubuntu, Arch, openSUSE;
//!     /etc/bash/bashrc on Gentoo; /etc/bashrc on NixOS; none on macOS,
//!     Fedora, RHEL, whose ~/.bashrc sources /etc/bashrc itself), then
//!     ~/.bashrc. gtty's own bash (`--rcfile`, shell_hooks.zig) reads the
//!     system bashrc, then the login files or ~/.bashrc.
//!
//! The work runs on a thread (`Job`); a `Result` remembers what it read
//! (`stamps`) so App can keep it until a file changes (`fresh`).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const sh = @import("ShParse.zig");

pub const Shell = enum { zsh, bash };
pub const Os = enum { macos, linux, other };

pub const native_os: Os = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    else => .other,
};

pub const Kind = enum { env, alias, untraced };

/// One place a name was set (or unset).
pub const Def = struct {
    /// Index into `Result.files`; 0 = the inherited environment.
    file: u32,
    line: u32,
    /// The value after this line ran (an append: the whole new value).
    value: []const u8,
    unset: bool = false,
    /// Inside a test gtty couldn't answer: it may not have run.
    cond: bool = false,
    /// Part of the value needs a program's output (kept as written).
    dynamic: bool = false,
    /// The source line, trimmed.
    text: []const u8 = "",
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// First → last; the last one is the value now.
    defs: []const Def,

    pub fn last(e: *const Entry) *const Def {
        return &e.defs[e.defs.len - 1];
    }
};

pub const Stat = struct {
    dir: bool = false,
    size: u64 = 0,
    mtime: i64 = 0,
    mtime_ns: i64 = 0,

    fn same(a: ?Stat, b: ?Stat) bool {
        if (a == null or b == null) return a == null and b == null;
        const x = a.?;
        const y = b.?;
        return x.dir == y.dir and x.size == y.size and x.mtime == y.mtime and x.mtime_ns == y.mtime_ns;
    }
};

pub const Stamp = struct { path: []const u8, st: ?Stat };

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    shell: Shell,
    login: bool,
    /// Environment variables, then aliases (each by name), then the lines
    /// not traced (in the order met).
    entries: []const Entry,
    /// The files read, by `Def.file`; [0] = "" (the inherited environment).
    files: []const []const u8,
    stamps: []const Stamp,
    /// Statements the parser couldn't read (skipped).
    errors: u32,

    pub fn deinit(r: *Result) void {
        r.arena.deinit();
    }

    /// Nothing gtty read (or looked for) changed since.
    pub fn fresh(r: *const Result, fs: Fs) bool {
        for (r.stamps) |s| if (!Stat.same(s.st, fs.stat(fs.ctx, s.path))) return false;
        return true;
    }

    pub fn count(r: *const Result, kind: Kind) usize {
        var n: usize = 0;
        for (r.entries) |e| {
            if (e.kind == kind) n += 1;
        }
        return n;
    }
};

// ------------------------------------------------------------ file system

pub const Access = enum { read, exec };

/// The files, through functions (the tests use a made-up tree).
pub const Fs = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (?*anyopaque, std.mem.Allocator, []const u8, usize) ?[]u8,
    stat: *const fn (?*anyopaque, []const u8) ?Stat,
    /// Names in a folder (no . / ..), any order.
    list: *const fn (?*anyopaque, std.mem.Allocator, []const u8) ?[]const []const u8,
    access: *const fn (?*anyopaque, []const u8, Access) bool,
};

pub const real_fs: Fs = .{ .read = realRead, .stat = realStat, .list = realList, .access = realAccess };

fn zpath(buf: []u8, path: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}", .{path}, 0) catch null;
}

fn realRead(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8, max: usize) ?[]u8 {
    var pb: [4096]u8 = undefined;
    const z = zpath(&pb, path) orelse return null;
    const f = c.fopen(z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        if (out.items.len + n > max) return null;
        out.appendSlice(a, buf[0..n]) catch return null;
    }
    if (c.ferror(f) != 0) return null;
    return out.toOwnedSlice(a) catch null;
}

fn realStat(_: ?*anyopaque, path: []const u8) ?Stat {
    var pb: [4096]u8 = undefined;
    const z = zpath(&pb, path) orelse return null;
    var st: c.struct_stat = undefined;
    if (c.stat(z.ptr, &st) != 0) return null;
    const ts = if (@hasField(c.struct_stat, "st_mtimespec")) st.st_mtimespec else st.st_mtim;
    return .{
        .dir = (st.st_mode & c.S_IFMT) == c.S_IFDIR,
        .size = @intCast(@max(st.st_size, 0)),
        .mtime = @intCast(ts.tv_sec),
        .mtime_ns = @intCast(ts.tv_nsec),
    };
}

fn realList(_: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
    var pb: [4096]u8 = undefined;
    const z = zpath(&pb, path) orelse return null;
    const d = c.opendir(z.ptr) orelse return null;
    defer _ = c.closedir(d);
    var out: std.ArrayList([]const u8) = .empty;
    while (c.readdir(d)) |e| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&e.*.d_name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (out.items.len >= 4096) break;
        out.append(a, a.dupe(u8, name) catch return null) catch return null;
    }
    return out.toOwnedSlice(a) catch null;
}

fn realAccess(_: ?*anyopaque, path: []const u8, how: Access) bool {
    var pb: [4096]u8 = undefined;
    const z = zpath(&pb, path) orelse return false;
    return c.access(z.ptr, if (how == .read) c.R_OK else c.X_OK) == 0;
}

// ------------------------------------------------------------ input

/// What to trace: the shell and how it started, and its environment.
pub const Input = struct {
    shell: Shell,
    /// The shell's program (to find what it was compiled with).
    shell_path: []const u8,
    login: bool,
    /// bash started by gtty with its `--rcfile` (shell_hooks.zig).
    rcfile: bool = false,
    /// "NAME=value", as the shell got it (gtty's own settings taken out).
    env: []const []const u8,
    /// The shell's folder at start (relative `source` paths).
    cwd: []const u8 = "",
    os: Os = native_os,

    /// Same input, same answer (App's cache).
    pub fn key(in: *const Input) u64 {
        var h = std.hash.Wyhash.init(0x67747479);
        h.update(@tagName(in.shell));
        h.update(in.shell_path);
        h.update(&.{ @intFromBool(in.login), @intFromBool(in.rcfile) });
        h.update(in.cwd);
        for (in.env) |e| {
            h.update(e);
            h.update("\x00");
        }
        return h.final();
    }
};

/// The shell `pid` runs, as gtty started it: its arguments and folder
/// from the process, its environment `env` (what gtty gave it when it
/// started it; `hook_dir`: gtty's folder of shell hooks, the ZDOTDIR it
/// gave zsh). Null when it isn't zsh or bash. Allocations in `a`.
pub fn fromProcess(a: std.mem.Allocator, pid: c_int, hook_dir: []const u8, env: []const []const u8) ?Input {
    var abuf: [16384]u8 = undefined;
    const na = c.gtty_proc_args(pid, &abuf, abuf.len);
    if (na <= 0) return null;
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, abuf[0..@intCast(na)], 0);
    while (it.next()) |s| if (s.len > 0) args.append(a, a.dupe(u8, s) catch return null) catch return null;
    if (args.items.len == 0) return null;
    var cbuf: [4096]u8 = undefined;
    const nc = c.gtty_proc_cwd(pid, &cbuf, cbuf.len);
    const cwd = if (nc > 0) a.dupe(u8, cbuf[0..@intCast(nc)]) catch "" else "";
    return fromArgs(a, args.items, env, cwd, hook_dir);
}

/// `fromProcess` without the process (unit-tested).
pub fn fromArgs(a: std.mem.Allocator, args: []const []const u8, env_in: []const []const u8, cwd: []const u8, hook_dir: []const u8) ?Input {
    const arg0 = args[0];
    const dash = arg0.len > 0 and arg0[0] == '-';
    const name = std.fs.path.basename(if (dash) arg0[1..] else arg0);
    const shell: Shell = if (std.mem.eql(u8, name, "zsh")) .zsh else if (std.mem.eql(u8, name, "bash")) .bash else return null;
    var login = dash;
    var rcfile = false;
    for (args[1..]) |s| {
        if (std.mem.eql(u8, s, "--login")) login = true;
        if (std.mem.eql(u8, s, "--rcfile") or std.mem.eql(u8, s, "--init-file")) rcfile = true;
        if (s.len >= 2 and s[0] == '-' and s[1] != '-' and std.mem.indexOfScalar(u8, s, 'l') != null) login = true;
        if (std.mem.eql(u8, s, "-c")) return null; // not an interactive shell
    }
    var env: std.ArrayList([]const u8) = .empty;
    var user_zdotdir: ?[]const u8 = null;
    var path_env: []const u8 = "";
    for (env_in) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
        const k = e[0..eq];
        const v = e[eq + 1 ..];
        if (std.mem.eql(u8, k, "GTTY_ZDOTDIR")) {
            user_zdotdir = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GTTY_BASH_LOGIN")) {
            login = true;
            continue;
        }
        if (std.mem.eql(u8, k, "ZDOTDIR") and hook_dir.len > 0 and std.mem.eql(u8, v, hook_dir)) continue;
        if (std.mem.eql(u8, k, "_")) continue;
        if (std.mem.eql(u8, k, "PATH")) path_env = v;
        env.append(a, e) catch return null;
    }
    if (user_zdotdir) |z| env.append(a, std.fmt.allocPrint(a, "ZDOTDIR={s}", .{z}) catch return null) catch return null;
    return .{
        .shell = shell,
        .shell_path = programPath(a, if (dash) arg0[1..] else arg0, path_env),
        .login = login,
        .rcfile = rcfile and shell == .bash,
        .env = env.items,
        .cwd = cwd,
    };
}

/// A program name as a path (through `$PATH` when it has no slash).
fn programPath(a: std.mem.Allocator, prog: []const u8, path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, prog, '/') != null) return prog;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        if (d.len == 0) continue;
        const p = std.fmt.allocPrint(a, "{s}/{s}", .{ d, prog }) catch continue;
        if (realAccess(null, p, .exec)) return p;
    }
    return prog;
}

// ------------------------------------------------------------ the job

/// A trace on its own thread. `start` copies the input; `done` turns true
/// once the result is there; `finish` takes it (and frees the job).
pub const Job = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    input: Input,
    key: u64,
    fs: Fs,
    done: std.atomic.Value(bool) = .init(false),
    result: ?Result = null,
    thread: std.Thread = undefined,

    pub fn start(gpa: std.mem.Allocator, input: Input, fs: Fs) !*Job {
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        j.* = .{ .gpa = gpa, .arena = .init(gpa), .input = undefined, .key = input.key(), .fs = fs };
        errdefer j.arena.deinit();
        const a = j.arena.allocator();
        var env = try a.alloc([]const u8, input.env.len);
        for (input.env, 0..) |e, i| env[i] = try a.dupe(u8, e);
        j.input = input;
        j.input.env = env;
        j.input.shell_path = try a.dupe(u8, input.shell_path);
        j.input.cwd = try a.dupe(u8, input.cwd);
        j.thread = try std.Thread.spawn(.{}, run, .{j});
        return j;
    }

    fn run(j: *Job) void {
        j.result = trace(j.gpa, j.input, j.fs) catch null;
        j.done.store(true, .release);
    }

    pub fn isDone(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    /// Wait for the thread, take the result (null: out of memory).
    pub fn finish(j: *Job) ?Result {
        j.thread.join();
        const r = j.result;
        j.arena.deinit();
        j.gpa.destroy(j);
        return r;
    }
};

// ------------------------------------------------------------ tracing

/// Trace the startup files for `in`. The result owns its memory.
pub fn trace(gpa: std.mem.Allocator, in_: Input, fs: Fs) Err!Result {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // The result's names and values point into its own copy of the input.
    var in = in_;
    const env = try a.alloc([]const u8, in_.env.len);
    for (in_.env, 0..) |e, i| env[i] = try a.dupe(u8, e);
    in.env = env;
    in.shell_path = try a.dupe(u8, in_.shell_path);
    in.cwd = try a.dupe(u8, in_.cwd);
    var t: Tracer = .{ .a = a, .fs = fs, .in = in };
    try t.files.append(t.a, "");
    try t.srcs.append(t.a, "");
    try t.startup();
    const entries = try t.entries();
    return .{
        .arena = arena,
        .shell = in.shell,
        .login = in.login,
        .entries = entries,
        .files = t.files.items,
        .stamps = t.stamps.items,
        .errors = t.errors,
    };
}

const St = enum { t, f, u };
const Err = error{OutOfMemory};

fn not(s: St) St {
    return switch (s) {
        .t => .f,
        .f => .t,
        .u => .u,
    };
}

const Var = struct {
    value: []const u8,
    exported: bool = false,
    dynamic: bool = false,
};

/// An expanded word: its text, and (for globbing and `case`) the same with
/// quoted pattern characters escaped.
const Exp = struct {
    text: []const u8,
    dynamic: bool = false,
    pat: []const u8 = "",
    glob: bool = false,
};

const Flow = enum { normal, ret, brk, cont };

/// zsh's arrays tied to a colon-separated variable.
const ties = [_][2][]const u8{
    .{ "path", "PATH" },     .{ "fpath", "FPATH" },       .{ "cdpath", "CDPATH" },
    .{ "manpath", "MANPATH" }, .{ "mailpath", "MAILPATH" }, .{ "module_path", "MODULE_PATH" },
    .{ "infopath", "INFOPATH" },
};

/// Shell builtins and commands that don't change what is traced.
const harmless = [_][]const u8{
    "echo",     "print",   "printf",  "umask",   "bindkey", "zstyle",  "shopt", "bind",    "complete",
    "compdef",  "autoload", "zmodload", "ulimit", "trap",    "stty",    "emulate", "compinit", "zle",
    "history",  "fc",      "disown",  "wait",    "hash",    "enable",  "noglob", "limit",   "chpwd",
    "add-zsh-hook", "compctl", "zcompile", "rehash", "setterm", "tabs", "mesg", "ssh-add",
};

const builtins = [_][]const u8{
    "source", ".", "export", "alias", "unalias", "unset", "set", "setopt", "unsetopt", "typeset", "declare",
    "local", "readonly", "eval", "exec", "cd", "pwd", "test", "[", "[[", "true", "false", ":", "command",
    "builtin", "type", "which", "whence", "shift", "return", "exit", "read", "let", "printf", "echo", "print",
};

fn isIn(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

const max_files = 300;
const max_source_depth = 24;
const max_call_depth = 32;
const max_loop = 256;
const max_file_size = 4 << 20;
const max_steps = 200_000;

const Frame = std.StringHashMapUnmanaged(?Var);

const Tracer = struct {
    a: std.mem.Allocator,
    fs: Fs,
    in: Input,
    vars: std.StringHashMapUnmanaged(Var) = .empty,
    /// Every definition of each variable, in order.
    hist: std.StringArrayHashMapUnmanaged(std.ArrayList(Def)) = .empty,
    /// Names exported at some point (an exported one may be unset later).
    ever_exported: std.StringHashMapUnmanaged(void) = .empty,
    pending_export: std.StringHashMapUnmanaged(void) = .empty,
    ahist: std.StringArrayHashMapUnmanaged(std.ArrayList(Def)) = .empty,
    untraced: std.ArrayList(Entry) = .empty,
    funcs: std.StringHashMapUnmanaged(*const sh.Cmd) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    /// Each file's text (for the line shown), parallel to `files`.
    srcs: std.ArrayList([]const u8) = .empty,
    stamps: std.ArrayList(Stamp) = .empty,
    stamped: std.StringHashMapUnmanaged(void) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    pos: []const []const u8 = &.{},
    arg0: []const u8 = "",
    cwd: []const u8 = "",
    file: u32 = 0,
    /// `eval`: every definition at this line.
    line_fix: ?u32 = null,
    cond: u32 = 0,
    /// A `return` under a test gtty couldn't answer: the rest of the
    /// file / function may not run.
    scope_cond: bool = false,
    flow: Flow = .normal,
    call_depth: u32 = 0,
    source_depth: u32 = 0,
    allexport: bool = false,
    global_rcs: bool = true,
    rcs: bool = true,
    errors: u32 = 0,
    steps: u32 = 0,

    fn isCond(t: *const Tracer) bool {
        return t.cond > 0 or t.scope_cond;
    }

    // -------------------------------------------------------- startup

    fn startup(t: *Tracer) Err!void {
        const in = t.in;
        t.cwd = in.cwd;
        // /etc/environment (pam_env) first, then the environment the
        // shell got; a value equal to /etc/environment's isn't repeated.
        if (in.os == .linux) try t.etcEnvironment("/etc/environment");
        for (in.env) |e| {
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse continue;
            const name = e[0..eq];
            const value = e[eq + 1 ..];
            if (!validName(name)) continue;
            if (t.vars.get(name)) |v| if (std.mem.eql(u8, v.value, value)) continue;
            try t.vars.put(t.a, name, .{ .value = value, .exported = true });
            try t.ever_exported.put(t.a, name, {});
            try t.record(name, .{ .file = 0, .line = 0, .value = value });
        }
        if (t.cwd.len == 0) t.cwd = t.get("HOME").value;
        // What the shell sets itself (not shown as definitions).
        const home = t.get("HOME").value;
        try t.quiet("-", switch (in.shell) {
            .zsh => if (in.login) "569XZilms" else "569XZims",
            .bash => if (in.login) "himBHl" else "himBH",
        });
        try t.quiet("PS1", if (in.shell == .zsh) "%m%# " else "\\s-\\v\\$ ");
        try t.quiet("OSTYPE", switch (in.os) {
            .macos => "darwin",
            .linux => "linux-gnu",
            .other => "unknown",
        });
        var hb: [256]u8 = undefined;
        const host = if (c.gethostname(&hb, hb.len) == 0) std.mem.sliceTo(&hb, 0) else "";
        try t.quiet(if (in.shell == .zsh) "HOST" else "HOSTNAME", try t.a.dupe(u8, host));
        try t.quiet("UID", try std.fmt.allocPrint(t.a, "{d}", .{c.getuid()}));
        try t.quiet("EUID", try std.fmt.allocPrint(t.a, "{d}", .{c.geteuid()}));
        switch (in.shell) {
            .zsh => {
                try t.quiet("ZSH_NAME", "zsh");
                try t.quiet("ZSH_VERSION", "5");
                t.arg0 = if (in.login) "-zsh" else "zsh";
                const g = t.zshGlobal();
                try t.startFile(try t.join(g, "zshenv"));
                if (t.rcs) try t.startFile(try t.zdot(".zshenv"));
                const names = [_]struct { []const u8, bool }{ .{ "zprofile", true }, .{ "zshrc", false }, .{ "zlogin", true } };
                for (names) |n| {
                    if (n[1] and !in.login) continue;
                    if (!t.rcs) break;
                    if (t.global_rcs) try t.startFile(try t.join(g, n[0]));
                    if (t.rcs) try t.startFile(try t.zdot(try std.fmt.allocPrint(t.a, ".{s}", .{n[0]})));
                }
            },
            .bash => {
                try t.quiet("BASH", in.shell_path);
                try t.quiet("BASH_VERSION", "5");
                t.arg0 = if (in.login and !in.rcfile) "-bash" else "bash";
                const sys = t.sysBashrc();
                if (!in.login or in.rcfile) if (sys) |s| try t.startFile(s);
                if (in.login) {
                    try t.startFile("/etc/profile");
                    for ([_][]const u8{ ".bash_profile", ".bash_login", ".profile" }) |n| {
                        const p = try t.join(home, n);
                        if (t.fs.access(t.fs.ctx, p, .read)) {
                            try t.startFile(p);
                            break;
                        }
                        try t.stamp(p);
                    }
                } else try t.startFile(try t.join(home, ".bashrc"));
            },
        }
    }

    /// `${ZDOTDIR:-$HOME}/name`, as it is at that point.
    fn zdot(t: *Tracer, name: []const u8) Err![]const u8 {
        const z = t.get("ZDOTDIR");
        const dir = if (z.value.len > 0) z.value else t.get("HOME").value;
        return t.join(dir, name);
    }

    fn join(t: *Tracer, dir: []const u8, name: []const u8) Err![]const u8 {
        if (dir.len > 0 and dir[dir.len - 1] == '/') return std.fmt.allocPrint(t.a, "{s}{s}", .{ dir, name });
        return std.fmt.allocPrint(t.a, "{s}/{s}", .{ dir, name });
    }

    fn startFile(t: *Tracer, path: []const u8) Err!void {
        _ = try t.sourceFile(path, null, 0);
    }

    /// The shell's binary, to see which paths were compiled into it.
    fn shellBinary(t: *Tracer) ?[]const u8 {
        return t.fs.read(t.fs.ctx, t.a, t.in.shell_path, 64 << 20);
    }

    /// zsh's folder of global startup files.
    fn zshGlobal(t: *Tracer) []const u8 {
        if (t.shellBinary()) |bin| {
            if (std.mem.indexOf(u8, bin, "/etc/zsh/zshenv") != null or std.mem.indexOf(u8, bin, "/etc/zsh/zshrc") != null) return "/etc/zsh";
            if (std.mem.indexOf(u8, bin, "/etc/zshenv") != null or std.mem.indexOf(u8, bin, "/etc/zshrc") != null) return "/etc";
        }
        return switch (t.in.os) {
            .linux => switch (t.distro()) {
                .debian, .arch, .gentoo => "/etc/zsh",
                .fedora, .suse, .nixos, .unknown => if (t.fs.stat(t.fs.ctx, "/etc/zsh/zshrc") != null) "/etc/zsh" else "/etc",
            },
            else => "/etc",
        };
    }

    /// bash's SYS_BASHRC, when it was built with one.
    fn sysBashrc(t: *Tracer) ?[]const u8 {
        const cands = [_][]const u8{ "/etc/bash.bashrc", "/etc/bash/bashrc" };
        if (t.shellBinary()) |bin| {
            for (cands) |p| if (std.mem.indexOf(u8, bin, p) != null) return p;
            if (t.in.os == .linux and t.distro() == .nixos and std.mem.indexOf(u8, bin, "/etc/bashrc") != null) return "/etc/bashrc";
            return null;
        }
        if (t.in.os != .linux) return null;
        return switch (t.distro()) {
            .debian, .arch, .suse => "/etc/bash.bashrc",
            .gentoo => "/etc/bash/bashrc",
            .nixos => "/etc/bashrc",
            .fedora, .unknown => null,
        };
    }

    const Distro = enum { debian, arch, gentoo, fedora, suse, nixos, unknown };

    /// The Linux family, from /etc/os-release (ID, then ID_LIKE).
    fn distro(t: *Tracer) Distro {
        const text = t.fs.read(t.fs.ctx, t.a, "/etc/os-release", 64 << 10) orelse return .unknown;
        var id: []const u8 = "";
        var like: []const u8 = "";
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "ID=")) id = std.mem.trim(u8, line[3..], "\"'");
            if (std.mem.startsWith(u8, line, "ID_LIKE=")) like = std.mem.trim(u8, line[8..], "\"'");
        }
        const table = [_]struct { []const u8, Distro }{
            .{ "debian", .debian },   .{ "ubuntu", .debian }, .{ "linuxmint", .debian }, .{ "pop", .debian },
            .{ "raspbian", .debian }, .{ "kali", .debian },   .{ "arch", .arch },        .{ "manjaro", .arch },
            .{ "endeavouros", .arch }, .{ "gentoo", .gentoo }, .{ "fedora", .fedora },    .{ "rhel", .fedora },
            .{ "centos", .fedora },   .{ "rocky", .fedora },  .{ "almalinux", .fedora }, .{ "amzn", .fedora },
            .{ "opensuse", .suse },   .{ "suse", .suse },     .{ "sles", .suse },        .{ "nixos", .nixos },
        };
        for ([_][]const u8{ id, like }) |field| {
            var words = std.mem.tokenizeScalar(u8, field, ' ');
            while (words.next()) |w| for (table) |row| if (std.mem.startsWith(u8, w, row[0])) return row[1];
        }
        return .unknown;
    }

    /// pam_env's /etc/environment: `NAME=value` lines (quotes taken off).
    fn etcEnvironment(t: *Tracer, path: []const u8) Err!void {
        try t.stamp(path);
        const text = t.fs.read(t.fs.ctx, t.a, path, 1 << 20) orelse return;
        const file = try t.addFile(path, text);
        var it = std.mem.splitScalar(u8, text, '\n');
        var line: u32 = 0;
        while (it.next()) |raw| {
            line += 1;
            var l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            if (std.mem.startsWith(u8, l, "export ")) l = std.mem.trimStart(u8, l[7..], " \t");
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
            const name = l[0..eq];
            if (!validName(name)) continue;
            var value = l[eq + 1 ..];
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) value = value[1 .. value.len - 1];
            try t.vars.put(t.a, name, .{ .value = value, .exported = true });
            try t.ever_exported.put(t.a, name, {});
            try t.record(name, .{ .file = file, .line = line, .value = value, .text = l });
        }
    }

    fn quiet(t: *Tracer, name: []const u8, value: []const u8) Err!void {
        if (t.vars.contains(name)) return;
        try t.vars.put(t.a, name, .{ .value = value });
    }

    fn addFile(t: *Tracer, path: []const u8, text: []const u8) Err!u32 {
        try t.files.append(t.a, path);
        try t.srcs.append(t.a, text);
        return @intCast(t.files.items.len - 1);
    }

    /// Remember a path's state (read, looked for, listed), once.
    fn stamp(t: *Tracer, path: []const u8) Err!void {
        if (t.stamps.items.len >= 2000 or t.stamped.contains(path)) return;
        const p = try t.a.dupe(u8, path);
        try t.stamped.put(t.a, p, {});
        try t.stamps.append(t.a, .{ .path = p, .st = t.fs.stat(t.fs.ctx, p) });
    }

    // -------------------------------------------------------- results

    fn entries(t: *Tracer) Err![]const Entry {
        var out: std.ArrayList(Entry) = .empty;
        var envs: std.ArrayList(Entry) = .empty;
        var it = t.hist.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            if (!t.ever_exported.contains(name)) continue;
            const defs = kv.value_ptr.items;
            if (defs.len == 0) continue;
            try envs.append(t.a, .{ .name = name, .kind = .env, .defs = defs });
        }
        // Exported names whose only definitions came before the export
        // (`X=1; export X`) are in `hist` too; nothing else to add.
        std.mem.sort(Entry, envs.items, {}, byName);
        try out.appendSlice(t.a, envs.items);
        var aliases: std.ArrayList(Entry) = .empty;
        var ait = t.ahist.iterator();
        while (ait.next()) |kv| try aliases.append(t.a, .{ .name = kv.key_ptr.*, .kind = .alias, .defs = kv.value_ptr.items });
        std.mem.sort(Entry, aliases.items, {}, byName);
        try out.appendSlice(t.a, aliases.items);
        try out.appendSlice(t.a, t.untraced.items);
        return out.toOwnedSlice(t.a);
    }

    fn byName(_: void, x: Entry, y: Entry) bool {
        return std.mem.lessThan(u8, x.name, y.name);
    }

    fn lineText(t: *const Tracer, line: u32) []const u8 {
        const src = t.srcs.items[t.file];
        if (line == 0) return "";
        var n: u32 = 1;
        var i: usize = 0;
        while (n < line) : (n += 1) {
            i = (std.mem.indexOfScalarPos(u8, src, i, '\n') orelse return "") + 1;
        }
        const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
        const s = std.mem.trim(u8, src[i..end], " \t\r");
        return s[0..@min(s.len, 400)];
    }

    fn mkDef(t: *const Tracer, line: u32, value: []const u8) Def {
        const l = t.line_fix orelse line;
        return .{ .file = t.file, .line = l, .value = value, .cond = t.isCond(), .text = t.lineText(l) };
    }

    fn record(t: *Tracer, name: []const u8, d: Def) Err!void {
        const gop = try t.hist.getOrPut(t.a, name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(t.a, d);
    }

    fn recordAlias(t: *Tracer, name: []const u8, d: Def) Err!void {
        const gop = try t.ahist.getOrPut(t.a, try t.a.dupe(u8, name));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(t.a, d);
    }

    fn untracedLine(t: *Tracer, line: u32, what: []const u8) Err!void {
        if (t.untraced.items.len >= 200) return;
        var d = t.mkDef(line, "");
        d.dynamic = true;
        const defs = try t.a.alloc(Def, 1);
        defs[0] = d;
        const name = if (d.text.len > 0) d.text else what;
        try t.untraced.append(t.a, .{ .name = name, .kind = .untraced, .defs = defs });
    }

    // -------------------------------------------------------- variables

    const Got = struct { value: []const u8, set: bool, dynamic: bool = false };

    fn tieOf(t: *const Tracer, name: []const u8) ?[]const u8 {
        if (t.in.shell != .zsh) return null;
        for (ties) |p| if (std.mem.eql(u8, p[0], name)) return p[1];
        return null;
    }

    fn get(t: *const Tracer, name0: []const u8) Got {
        const name = t.tieOf(name0) orelse name0;
        if (name.len == 1 and std.ascii.isDigit(name[0])) {
            const n = name[0] - '0';
            if (n == 0) return .{ .value = t.arg0, .set = true };
            return if (n <= t.pos.len) .{ .value = t.pos[n - 1], .set = true } else .{ .value = "", .set = false };
        }
        if (std.mem.eql(u8, name, "BASH_SOURCE") and t.in.shell == .bash) return .{ .value = t.files.items[t.file], .set = true };
        if (std.mem.eql(u8, name, "?")) return .{ .value = "0", .set = true };
        if (std.mem.eql(u8, name, "$") or std.mem.eql(u8, name, "!") or std.mem.eql(u8, name, "RANDOM") or std.mem.eql(u8, name, "LINENO") or std.mem.eql(u8, name, "SECONDS"))
            return .{ .value = "", .set = true, .dynamic = true };
        const v = t.vars.get(name) orelse return .{ .value = "", .set = false };
        return .{ .value = v.value, .set = true, .dynamic = v.dynamic };
    }

    fn isLocal(t: *const Tracer, name: []const u8) bool {
        for (t.frames.items) |f| if (f.contains(name)) return true;
        return false;
    }

    fn declareLocal(t: *Tracer, name: []const u8) Err!void {
        if (t.frames.items.len == 0) return;
        const f = &t.frames.items[t.frames.items.len - 1];
        if (f.contains(name)) return;
        try f.put(t.a, name, t.vars.get(name));
    }

    fn setVar(t: *Tracer, name0: []const u8, e: Exp, line: u32, exported: ?bool) Err!void {
        const name = t.tieOf(name0) orelse name0;
        if (!validName(name)) return;
        var v = t.vars.get(name) orelse Var{ .value = "" };
        v.value = e.text;
        v.dynamic = e.dynamic;
        if (t.pending_export.fetchRemove(name) != null) v.exported = true;
        if (exported) |x| v.exported = x;
        if (t.allexport) v.exported = true;
        try t.vars.put(t.a, name, v);
        if (t.isLocal(name)) return;
        if (v.exported) try t.ever_exported.put(t.a, name, {});
        var d = t.mkDef(line, e.text);
        d.dynamic = e.dynamic;
        try t.record(name, d);
    }

    fn markExport(t: *Tracer, name0: []const u8, on: bool) Err!void {
        const name = t.tieOf(name0) orelse name0;
        if (!validName(name)) return;
        if (t.vars.getPtr(name)) |v| {
            v.exported = on;
        } else if (on) {
            // `export X` before X has a value: exported once it gets one.
            try t.pending_export.put(t.a, name, {});
        } else _ = t.pending_export.remove(name);
        if (on and !t.isLocal(name)) try t.ever_exported.put(t.a, name, {});
    }

    fn unsetVar(t: *Tracer, name0: []const u8, line: u32) Err!void {
        const name = t.tieOf(name0) orelse name0;
        if (!t.vars.contains(name)) return;
        _ = t.vars.remove(name);
        if (t.isLocal(name) or !t.hist.contains(name)) return;
        var d = t.mkDef(line, "");
        d.unset = true;
        try t.record(name, d);
    }

    // -------------------------------------------------------- expansion

    const Mode = struct {
        /// An assignment's value: `~` after `:` too.
        assign: bool = false,
    };

    const Buf = struct {
        text: std.ArrayList(u8) = .empty,
        pat: std.ArrayList(u8) = .empty,
        dynamic: bool = false,
        glob: bool = false,

        fn lit(b: *Buf, a: std.mem.Allocator, s: []const u8, quoted: bool) Err!void {
            try b.text.appendSlice(a, s);
            for (s) |ch| {
                if (quoted and (ch == '*' or ch == '?' or ch == '[' or ch == ']' or ch == '\\')) try b.pat.append(a, '\\');
                try b.pat.append(a, ch);
            }
        }

        fn add(b: *Buf, a: std.mem.Allocator, e: Exp) Err!void {
            try b.lit(a, e.text, true);
            if (e.dynamic) b.dynamic = true;
        }

        fn done(b: *Buf) Exp {
            return .{ .text = b.text.items, .dynamic = b.dynamic, .pat = b.pat.items, .glob = b.glob };
        }
    };

    /// One word, expanded (no field splitting, no globbing: see `fields`).
    fn expand(t: *Tracer, raw: []const u8, mode: Mode) Err!Exp {
        var b: Buf = .{};
        try t.expandInto(&b, raw, false, mode);
        return b.done();
    }

    fn expandInto(t: *Tracer, b: *Buf, raw: []const u8, dq: bool, mode: Mode) Err!void {
        t.steps += 1;
        var i: usize = 0;
        while (i < raw.len) {
            const ch = raw[i];
            switch (ch) {
                '\'' => if (dq) {
                    try b.lit(t.a, "'", true);
                    i += 1;
                } else {
                    const end = sh.spanEnd(raw, i);
                    const close = if (end > i + 1 and raw[end - 1] == '\'') end - 1 else end;
                    try b.lit(t.a, raw[i + 1 .. close], true);
                    i = end;
                },
                '"' => if (dq) {
                    i += 1;
                } else {
                    const end = sh.spanEnd(raw, i);
                    const close = if (end > i + 1 and raw[end - 1] == '"') end - 1 else end;
                    var inner: Buf = .{};
                    try t.expandInto(&inner, raw[i + 1 .. close], true, .{});
                    try b.add(t.a, inner.done());
                    i = end;
                },
                '\\' => {
                    if (i + 1 >= raw.len) {
                        try b.lit(t.a, "\\", true);
                        i += 1;
                    } else if (raw[i + 1] == '\n') {
                        i += 2;
                    } else if (dq and std.mem.indexOfScalar(u8, "$`\"\\", raw[i + 1]) == null) {
                        try b.lit(t.a, raw[i .. i + 2], true);
                        i += 2;
                    } else {
                        try b.lit(t.a, raw[i + 1 .. i + 2], true);
                        i += 2;
                    }
                },
                '`' => {
                    const end = sh.spanEnd(raw, i);
                    const close = if (end > i + 1 and raw[end - 1] == '`') end - 1 else end;
                    try b.add(t.a, try t.cmdSubst(raw[i + 1 .. close], raw[i..end]));
                    i = end;
                },
                '$' => i = try t.dollar(b, raw, i, dq),
                '~' => if (!dq and (i == 0 or (mode.assign and raw[i - 1] == ':'))) {
                    var j = i + 1;
                    while (j < raw.len and raw[j] != '/' and raw[j] != ':') j += 1;
                    const user = raw[i + 1 .. j];
                    if (user.len == 0 or std.mem.eql(u8, user, t.get("USER").value)) {
                        try b.lit(t.a, t.get("HOME").value, true);
                    } else try b.lit(t.a, raw[i..j], true);
                    i = j;
                } else {
                    try b.lit(t.a, "~", dq);
                    i += 1;
                },
                '*', '?', '[' => {
                    if (!dq) b.glob = true;
                    try b.lit(t.a, raw[i .. i + 1], dq);
                    i += 1;
                },
                else => {
                    try b.lit(t.a, raw[i .. i + 1], dq);
                    i += 1;
                },
            }
        }
    }

    /// At `$` in `raw`: expand it into `b`, return where the text goes on.
    fn dollar(t: *Tracer, b: *Buf, raw: []const u8, i: usize, dq: bool) Err!usize {
        if (i + 1 >= raw.len) {
            try b.lit(t.a, "$", true);
            return i + 1;
        }
        const n = raw[i + 1];
        switch (n) {
            '(' => {
                const end = sh.spanEnd(raw, i);
                if (i + 2 < raw.len and raw[i + 2] == '(') {
                    try b.add(t.a, .{ .text = raw[i..end], .dynamic = true });
                } else {
                    const close = if (end > i + 2 and raw[end - 1] == ')') end - 1 else end;
                    try b.add(t.a, try t.cmdSubst(raw[i + 2 .. close], raw[i..end]));
                }
                return end;
            },
            '{' => {
                const end = sh.spanEnd(raw, i);
                const close = if (end > i + 2 and raw[end - 1] == '}') end - 1 else end;
                try b.add(t.a, try t.param(raw[i + 2 .. close], raw[i..end]));
                return end;
            },
            '\'' => {
                if (dq) {
                    try b.lit(t.a, "$", true);
                    return i + 1;
                }
                const end = sh.spanEnd(raw, i);
                const close = if (end > i + 2 and raw[end - 1] == '\'') end - 1 else end;
                try b.lit(t.a, try ansiC(t.a, raw[i + 2 .. close]), true);
                return end;
            },
            else => {},
        }
        var j = i + 1;
        if (std.ascii.isAlphabetic(n) or n == '_') {
            while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) j += 1;
        } else if (std.ascii.isDigit(n) or std.mem.indexOfScalar(u8, "@*#?$!-", n) != null) {
            j += 1;
        } else {
            try b.lit(t.a, "$", true);
            return i + 1;
        }
        const name = raw[i + 1 .. j];
        var e = t.special(name) orelse blk: {
            const g = t.get(name);
            break :blk Exp{ .text = g.value, .dynamic = g.dynamic };
        };
        // zsh: `$0:h`, `$file:t:r`.
        if (t.in.shell == .zsh and !dq) {
            while (j + 1 < raw.len and raw[j] == ':' and std.mem.indexOfScalar(u8, "AahtrelPu", raw[j + 1]) != null) {
                e.text = try t.modifier(e.text, raw[j + 1]);
                j += 2;
            }
        }
        try b.add(t.a, e);
        return j;
    }

    /// `$#`, `$@`, `$*`, `$-`.
    fn special(t: *Tracer, name: []const u8) ?Exp {
        if (std.mem.eql(u8, name, "#")) return .{ .text = std.fmt.allocPrint(t.a, "{d}", .{t.pos.len}) catch "0" };
        if (std.mem.eql(u8, name, "@") or std.mem.eql(u8, name, "*")) return .{ .text = std.mem.join(t.a, " ", t.pos) catch "" };
        return null;
    }

    /// zsh's history modifiers on a value.
    fn modifier(t: *Tracer, s: []const u8, m: u8) Err![]const u8 {
        return switch (m) {
            'h' => std.fs.path.dirname(s) orelse ".",
            't' => std.fs.path.basename(s),
            'r' => blk: {
                const base = std.fs.path.basename(s);
                const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse break :blk s;
                break :blk s[0 .. s.len - base.len + dot];
            },
            'e' => blk: {
                const base = std.fs.path.basename(s);
                const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse break :blk "";
                break :blk base[dot + 1 ..];
            },
            'a', 'A', 'P' => if (std.fs.path.isAbsolute(s)) s else try std.fs.path.resolve(t.a, &.{ t.cwd, s }),
            'l' => try std.ascii.allocLowerString(t.a, s),
            'u' => try std.ascii.allocUpperString(t.a, s),
            else => s,
        };
    }

    /// `${…}`: `inner` is what is between the braces, `whole` all of it.
    fn param(t: *Tracer, inner: []const u8, whole: []const u8) Err!Exp {
        const dyn: Exp = .{ .text = whole, .dynamic = true };
        if (inner.len == 0) return dyn;
        var s = inner;
        // zsh flags: `${(%):-%x}` is the file being read.
        if (s[0] == '(') {
            const close = std.mem.indexOfScalar(u8, s, ')') orelse return dyn;
            const flags = s[1..close];
            const rest = s[close + 1 ..];
            if (std.mem.eql(u8, flags, "%") and (std.mem.eql(u8, rest, ":-%x") or std.mem.eql(u8, rest, ":-%N"))) return .{ .text = t.files.items[t.file] };
            return dyn;
        }
        if (s[0] == '#' and s.len > 1) {
            const g = t.get(s[1..]);
            if (g.dynamic) return dyn;
            return .{ .text = try std.fmt.allocPrint(t.a, "{d}", .{g.value.len}) };
        }
        if (s[0] == '!') return dyn;
        if (s[0] == '+' and t.in.shell == .zsh) return .{ .text = if (t.get(s[1..]).set) "1" else "0" };
        var j: usize = 0;
        if (std.ascii.isAlphabetic(s[0]) or s[0] == '_') {
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) j += 1;
        } else if (std.ascii.isDigit(s[0])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        } else if (std.mem.indexOfScalar(u8, "@*#?$!-", s[0]) != null) {
            j = 1;
        } else return dyn;
        const name = s[0..j];
        s = s[j..];
        // `[@]`, `[*]`, `[0]` (BASH_SOURCE[0]): the value; other subscripts: unknown.
        if (s.len > 0 and s[0] == '[') {
            const close = std.mem.indexOfScalar(u8, s, ']') orelse return dyn;
            const sub = s[1..close];
            if (!(std.mem.eql(u8, sub, "@") or std.mem.eql(u8, sub, "*") or std.mem.eql(u8, sub, "0") or (t.in.shell == .zsh and std.mem.eql(u8, sub, "1")))) return dyn;
            s = s[close + 1 ..];
        }
        var g = t.get(name);
        if (t.special(name)) |e| g = .{ .value = e.text, .set = true };
        const val: Exp = .{ .text = g.value, .dynamic = g.dynamic };
        if (s.len == 0) return val;
        const colon = s[0] == ':';
        const ops = if (colon) s[1..] else s;
        if (ops.len > 0 and std.mem.indexOfScalar(u8, "-=+?", ops[0]) != null) {
            const word = ops[1..];
            const empty = !g.set or (colon and g.value.len == 0);
            switch (ops[0]) {
                '-', '=' => if (empty) {
                    const w = try t.expand(word, .{});
                    if (ops[0] == '=') try t.setVar(name, w, 0, null);
                    return .{ .text = w.text, .dynamic = w.dynamic };
                } else return val,
                '+' => if (empty) return .{ .text = "" } else {
                    const w = try t.expand(word, .{});
                    return .{ .text = w.text, .dynamic = w.dynamic or g.dynamic };
                },
                else => return val,
            }
        }
        if (colon and t.in.shell == .zsh and ops.len > 0 and std.ascii.isAlphabetic(ops[0])) {
            var text = g.value;
            var k: usize = 0;
            while (k < s.len and s[k] == ':' and k + 1 < s.len) : (k += 2) text = try t.modifier(text, s[k + 1]);
            return .{ .text = text, .dynamic = g.dynamic };
        }
        if (s[0] == '%' or s[0] == '#') {
            if (g.dynamic) return dyn;
            const long = s.len > 1 and s[1] == s[0];
            const p = try t.expand(s[if (long) 2 else 1..], .{});
            if (p.dynamic) return dyn;
            return .{ .text = trimPattern(g.value, p.pat, s[0] == '#', long) };
        }
        return dyn;
    }

    /// `$(…)` / `` `…` ``: a few commands whose output gtty knows without
    /// running them; anything else stays as written.
    fn cmdSubst(t: *Tracer, inner: []const u8, whole: []const u8) Err!Exp {
        const dyn: Exp = .{ .text = whole, .dynamic = true };
        const prog = sh.parse(t.a, inner) catch return dyn;
        if (prog.list.len != 1 or prog.list[0].rest.len != 0 or prog.list[0].first.cmds.len != 1) return dyn;
        const one = prog.list[0].first.cmds[0];
        if (one != .simple or one.simple.words.len == 0) return dyn;
        var args: std.ArrayList([]const u8) = .empty;
        for (one.simple.words) |w| {
            const e = try t.expand(w, .{});
            if (e.dynamic) return dyn;
            try args.append(t.a, e.text);
        }
        const a = args.items;
        const name = a[0];
        if (std.mem.eql(u8, name, "dirname") and a.len == 2) return .{ .text = std.fs.path.dirname(a[1]) orelse "." };
        if (std.mem.eql(u8, name, "basename") and (a.len == 2 or a.len == 3)) {
            const base = std.fs.path.basename(a[1]);
            return .{ .text = if (a.len == 3 and std.mem.endsWith(u8, base, a[2]) and base.len > a[2].len) base[0 .. base.len - a[2].len] else base };
        }
        if (std.mem.eql(u8, name, "uname") and (a.len == 1 or (a.len == 2 and std.mem.eql(u8, a[1], "-s"))))
            return .{ .text = switch (t.in.os) {
                .macos => "Darwin",
                .linux => "Linux",
                .other => return dyn,
            } };
        if (std.mem.eql(u8, name, "echo")) {
            const rest = if (a.len > 1 and std.mem.eql(u8, a[1], "-n")) a[2..] else a[1..];
            return .{ .text = try std.mem.join(t.a, " ", rest) };
        }
        if (std.mem.eql(u8, name, "whoami") and a.len == 1) return .{ .text = t.get("USER").value, .dynamic = !t.get("USER").set };
        if (std.mem.eql(u8, name, "id") and a.len == 2 and std.mem.eql(u8, a[1], "-u")) return .{ .text = t.get("UID").value };
        if (std.mem.eql(u8, name, "pwd") and a.len == 1) return .{ .text = t.cwd };
        return dyn;
    }

    /// A word's fields: globbing (unquoted `*?[`), `"$@"`.
    fn fields(t: *Tracer, raw: []const u8, out: *std.ArrayList(Exp)) Err!void {
        if (std.mem.eql(u8, raw, "\"$@\"") or std.mem.eql(u8, raw, "$@") or std.mem.eql(u8, raw, "$*") or std.mem.eql(u8, raw, "${@}")) {
            for (t.pos) |p| try out.append(t.a, .{ .text = p });
            return;
        }
        // zsh: `$path` / `$fpath` in a list are the array's elements.
        if (t.in.shell == .zsh and raw.len > 1 and raw[0] == '$') {
            if (t.tieOf(std.mem.trim(u8, raw[1..], "{}"))) |big| {
                const g = t.get(big);
                var it = std.mem.splitScalar(u8, g.value, ':');
                while (it.next()) |p| if (p.len > 0) try out.append(t.a, .{ .text = p, .dynamic = g.dynamic });
                return;
            }
        }
        var e = try t.expand(raw, .{});
        if (!e.glob or e.dynamic) {
            // bash splits an unquoted `$var` on blanks.
            if (t.in.shell == .bash and raw.len > 1 and raw[0] == '$' and std.mem.indexOfAny(u8, raw, "\"'") == null) {
                var it = std.mem.tokenizeAny(u8, e.text, " \t\n");
                while (it.next()) |p| try out.append(t.a, .{ .text = p, .dynamic = e.dynamic });
                return;
            }
            try out.append(t.a, e);
            return;
        }
        var pat = e.pat;
        // zsh glob qualifiers: `*(N)`, `*(.N)`.
        if (t.in.shell == .zsh and pat.len > 0 and pat[pat.len - 1] == ')') {
            if (std.mem.lastIndexOfScalar(u8, pat, '(')) |open| pat = pat[0..open];
        }
        const n0 = out.items.len;
        try t.glob(pat, out);
        // No match: bash keeps the word; zsh drops it (`(N)`, or the
        // command fails).
        if (out.items.len == n0 and t.in.shell == .bash) {
            e.glob = false;
            try out.append(t.a, e);
        }
    }

    /// Glob in the last path part only (`/etc/profile.d/*.sh`).
    fn glob(t: *Tracer, pat: []const u8, out: *std.ArrayList(Exp)) Err!void {
        const slash = std.mem.lastIndexOfScalar(u8, pat, '/');
        const dir_pat = if (slash) |s| (if (s == 0) "/" else pat[0..s]) else ".";
        const base = if (slash) |s| pat[s + 1 ..] else pat;
        if (hasGlob(dir_pat)) return;
        const dir = try unescape(t.a, dir_pat);
        const full_dir = if (std.fs.path.isAbsolute(dir)) dir else try t.join(t.cwd, dir);
        try t.stamp(full_dir);
        const names = t.fs.list(t.fs.ctx, t.a, full_dir) orelse return;
        var hits: std.ArrayList([]const u8) = .empty;
        for (names) |name| {
            if (name.len > 0 and name[0] == '.' and !(base.len > 0 and base[0] == '.')) continue;
            if (globMatch(base, name)) try hits.append(t.a, name);
        }
        std.mem.sort([]const u8, hits.items, {}, lessStr);
        for (hits.items) |h| {
            const p = if (slash == null) h else try t.join(dir, h);
            try out.append(t.a, .{ .text = p });
        }
    }

    // -------------------------------------------------------- running

    fn sourceFile(t: *Tracer, path: []const u8, args: ?[]const []const u8, line: u32) Err!St {
        _ = line;
        try t.stamp(path);
        if (t.source_depth >= max_source_depth or t.files.items.len >= max_files) return .u;
        const st = t.fs.stat(t.fs.ctx, path) orelse return .f;
        if (st.dir) return .f;
        const text = t.fs.read(t.fs.ctx, t.a, path, max_file_size) orelse return .f; // can't read: ignored
        const prog = try sh.parse(t.a, text);
        t.errors += prog.errors;
        const file = try t.addFile(path, text);
        const saved = .{ t.file, t.line_fix, t.pos, t.scope_cond, t.arg0 };
        t.file = file;
        t.line_fix = null;
        if (args) |a| if (a.len > 0) {
            t.pos = a;
        };
        if (t.in.shell == .zsh) t.arg0 = path;
        t.source_depth += 1;
        _ = try t.list(prog.list);
        t.source_depth -= 1;
        if (t.flow == .ret) t.flow = .normal;
        t.file, t.line_fix, t.pos, t.scope_cond, t.arg0 = saved;
        return .t;
    }

    fn list(t: *Tracer, l: sh.List) Err!St {
        var st: St = .t;
        for (l) |ao| {
            if (t.flow != .normal) break;
            st = try t.andOr(ao);
        }
        return st;
    }

    fn andOr(t: *Tracer, ao: sh.AndOr) Err!St {
        var st = try t.pipeline(ao.first);
        for (ao.rest) |link| {
            if (t.flow != .normal) break;
            const go: St = switch (link.op) {
                .and_ => st,
                .or_ => not(st),
            };
            switch (go) {
                .f => {},
                .t => st = try t.pipeline(link.p),
                .u => {
                    t.cond += 1;
                    const s2 = try t.pipeline(link.p);
                    t.cond -= 1;
                    st = switch (link.op) {
                        .and_ => if (s2 == .f) .f else .u,
                        .or_ => if (s2 == .t) .t else .u,
                    };
                },
            }
        }
        return st;
    }

    fn pipeline(t: *Tracer, p: sh.Pipeline) Err!St {
        // A pipeline's parts run in subshells: nothing they set stays.
        if (p.cmds.len != 1) return .u;
        const st = try t.cmd(p.cmds[0]);
        return if (p.bang) not(st) else st;
    }

    fn cmd(t: *Tracer, cm: sh.Cmd) Err!St {
        t.steps += 1;
        if (t.steps > max_steps) {
            t.flow = .ret;
            return .u;
        }
        switch (cm) {
            .simple => |s| return t.simple(s),
            .group => |l| return t.list(l),
            .subshell => return .u,
            .func => |f| {
                try t.funcs.put(t.a, f.name, f.body);
                return .t;
            },
            .anon => |l| return t.call(&sh.Cmd{ .group = l }, &.{}),
            .loop => return .t,
            .if_ => |x| {
                var unsure = false;
                for (x.conds, x.bodies) |cond_l, body| {
                    if (unsure) t.cond += 1;
                    const st = try t.list(cond_l);
                    if (unsure) t.cond -= 1;
                    if (t.flow != .normal) return .u;
                    switch (st) {
                        .f => continue,
                        .t => {
                            if (!unsure) return t.list(body);
                            t.cond += 1;
                            _ = try t.list(body);
                            t.cond -= 1;
                            return .u;
                        },
                        .u => {
                            unsure = true;
                            t.cond += 1;
                            _ = try t.list(body);
                            t.cond -= 1;
                        },
                    }
                }
                if (x.else_) |e| {
                    if (!unsure) return t.list(e);
                    t.cond += 1;
                    _ = try t.list(e);
                    t.cond -= 1;
                }
                return if (unsure) .u else .t;
            },
            .for_ => |x| {
                var vals: std.ArrayList(Exp) = .empty;
                if (x.words) |ws| {
                    for (ws) |w| try t.fields(w, &vals);
                } else for (t.pos) |p| try vals.append(t.a, .{ .text = p });
                var dynamic = false;
                for (vals.items) |v| if (v.dynamic) {
                    dynamic = true;
                };
                if (dynamic) {
                    t.cond += 1;
                    try t.vars.put(t.a, x.name, .{ .value = "", .dynamic = true });
                    _ = try t.list(x.body);
                    t.cond -= 1;
                    if (t.flow == .brk or t.flow == .cont) t.flow = .normal;
                    return .u;
                }
                for (vals.items[0..@min(vals.items.len, max_loop)]) |v| {
                    const old = t.vars.get(x.name);
                    try t.vars.put(t.a, x.name, .{ .value = v.text, .exported = if (old) |o| o.exported else false });
                    _ = try t.list(x.body);
                    if (t.flow == .cont) t.flow = .normal;
                    if (t.flow == .brk) {
                        t.flow = .normal;
                        break;
                    }
                    if (t.flow != .normal) break;
                }
                return .t;
            },
            .case_ => |x| {
                const w = try t.expand(x.word, .{});
                if (w.dynamic) {
                    t.cond += 1;
                    for (x.items) |it| _ = try t.list(it.body);
                    t.cond -= 1;
                    return .u;
                }
                for (x.items) |it| {
                    for (it.pats) |p| {
                        const pe = try t.expand(p, .{});
                        if (pe.dynamic) {
                            t.cond += 1;
                            _ = try t.list(it.body);
                            t.cond -= 1;
                            break;
                        }
                        if (globMatch(pe.pat, w.text)) return t.list(it.body);
                    }
                }
                return .t;
            },
        }
    }

    fn call(t: *Tracer, body: *const sh.Cmd, args: []const []const u8) Err!St {
        if (t.call_depth >= max_call_depth) return .u;
        const saved = .{ t.pos, t.scope_cond };
        t.pos = args;
        t.call_depth += 1;
        try t.frames.append(t.a, .empty);
        const st = try t.cmd(body.*);
        var frame = t.frames.pop().?;
        var it = frame.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*) |v| try t.vars.put(t.a, kv.key_ptr.*, v) else _ = t.vars.remove(kv.key_ptr.*);
        }
        t.call_depth -= 1;
        if (t.flow == .ret) t.flow = .normal;
        t.pos, t.scope_cond = saved;
        return st;
    }

    fn simple(t: *Tracer, s: sh.Simple) Err!St {
        const ws = s.words;
        var k: usize = 0;
        while (k < ws.len and splitAssign(ws[k]) != null) k += 1;
        if (k == ws.len) {
            for (ws) |w| try t.assign(w, null, false, s.line);
            return .t;
        }
        // `VAR=x cmd`: VAR only for that command.
        return t.run(ws[k..], s.line);
    }

    /// Run a command: `words[0]` (raw) and its arguments (raw).
    fn run(t: *Tracer, words: []const []const u8, line: u32) Err!St {
        const ne = try t.expand(words[0], .{});
        if (ne.dynamic) return .u;
        const name = ne.text;
        const args = words[1..];
        const eq = std.mem.eql;
        if (eq(u8, name, "export") or eq(u8, name, "declare") or eq(u8, name, "typeset") or eq(u8, name, "local") or
            eq(u8, name, "readonly") or eq(u8, name, "integer") or eq(u8, name, "float"))
            return t.declare(name, args, line);
        if (eq(u8, name, "unset")) {
            for (args) |a| {
                const e = try t.expand(a, .{});
                if (eq(u8, e.text, "-f")) return .t;
                if (e.text.len > 0 and e.text[0] == '-') continue;
                try t.unsetVar(e.text, line);
            }
            return .t;
        }
        if (eq(u8, name, "alias")) {
            for (args) |a| {
                const e = try t.expand(a, .{});
                if (e.text.len > 0 and (e.text[0] == '-' or e.text[0] == '+')) continue;
                const at = std.mem.indexOfScalar(u8, e.text, '=') orelse continue;
                if (at == 0) continue;
                var d = t.mkDef(line, e.text[at + 1 ..]);
                d.dynamic = e.dynamic;
                try t.recordAlias(e.text[0..at], d);
            }
            return .t;
        }
        if (eq(u8, name, "unalias")) {
            for (args) |a| {
                const e = try t.expand(a, .{});
                if (eq(u8, e.text, "-a")) {
                    for (t.ahist.keys()) |n| try t.unalias(n, line);
                    continue;
                }
                if (e.text.len > 0 and e.text[0] == '-') continue;
                try t.unalias(e.text, line);
            }
            return .t;
        }
        if (eq(u8, name, "source") or eq(u8, name, ".")) {
            if (args.len == 0) return .f;
            if (args[0].len > 1 and (args[0][0] == '<' or args[0][0] == '>')) {
                try t.untracedLine(line, "source <(…)");
                return .u;
            }
            const p = try t.expand(args[0], .{});
            if (p.dynamic) {
                try t.untracedLine(line, "source");
                return .u;
            }
            const path = try t.resolveSource(p.text) orelse return .f;
            var rest: std.ArrayList([]const u8) = .empty;
            for (args[1..]) |a| try rest.append(t.a, (try t.expand(a, .{})).text);
            return t.sourceFile(path, rest.items, line);
        }
        if (eq(u8, name, "eval")) {
            var parts: std.ArrayList([]const u8) = .empty;
            var dynamic = false;
            for (args) |a| {
                const e = try t.expand(a, .{});
                dynamic = dynamic or e.dynamic;
                try parts.append(t.a, e.text);
            }
            const text = try std.mem.join(t.a, " ", parts.items);
            if (std.mem.indexOf(u8, text, "path_helper") != null and t.in.os == .macos) return t.pathHelper(line);
            if (dynamic) {
                try t.untracedLine(line, "eval");
                return .u;
            }
            const prog = sh.parse(t.a, text) catch return .u;
            const saved = t.line_fix;
            t.line_fix = t.line_fix orelse line;
            const st = try t.list(prog.list);
            t.line_fix = saved;
            return st;
        }
        if (eq(u8, name, "set")) {
            var i: usize = 0;
            while (i < args.len) : (i += 1) {
                const e = (try t.expand(args[i], .{})).text;
                if (eq(u8, e, "--")) {
                    t.pos = try t.expandAll(args[i + 1 ..]);
                    break;
                }
                if (e.len > 1 and (e[0] == '-' or e[0] == '+')) {
                    const on = e[0] == '-';
                    if (eq(u8, e[1..], "o") and i + 1 < args.len) {
                        i += 1;
                        try t.option((try t.expand(args[i], .{})).text, on);
                    } else if (std.mem.indexOfScalar(u8, e[1..], 'a') != null) t.allexport = on;
                    continue;
                }
                t.pos = try t.expandAll(args[i..]);
                break;
            }
            return .t;
        }
        if (eq(u8, name, "setopt") or eq(u8, name, "unsetopt")) {
            for (args) |a| try t.option((try t.expand(a, .{})).text, name[0] == 's');
            return .t;
        }
        if (eq(u8, name, "shift")) {
            const n: usize = if (args.len > 0) std.fmt.parseInt(usize, (try t.expand(args[0], .{})).text, 10) catch 1 else 1;
            t.pos = t.pos[@min(n, t.pos.len)..];
            return .t;
        }
        if (eq(u8, name, "return") or eq(u8, name, "exit")) {
            if (t.isCond()) {
                t.scope_cond = true;
                return .u;
            }
            t.flow = .ret;
            return .t;
        }
        if (eq(u8, name, "break")) {
            if (!t.isCond()) t.flow = .brk;
            return .t;
        }
        if (eq(u8, name, "continue")) {
            if (!t.isCond()) t.flow = .cont;
            return .t;
        }
        if (eq(u8, name, "true") or eq(u8, name, ":")) return .t;
        if (eq(u8, name, "false")) return .f;
        if (eq(u8, name, "[") or eq(u8, name, "test") or eq(u8, name, "[[")) {
            var es: std.ArrayList(Exp) = .empty;
            for (args) |a| try es.append(t.a, try t.expand(a, .{}));
            var items = es.items;
            if (items.len > 0 and (eq(u8, items[items.len - 1].text, "]") or eq(u8, items[items.len - 1].text, "]]"))) items = items[0 .. items.len - 1];
            return t.testExpr(items, eq(u8, name, "[["));
        }
        if (eq(u8, name, "builtin") or eq(u8, name, "noglob") or eq(u8, name, "exec")) {
            if (args.len == 0) return .t;
            return t.run(args, line);
        }
        if (eq(u8, name, "command") or eq(u8, name, "type") or eq(u8, name, "which") or eq(u8, name, "whence") or (eq(u8, name, "hash") and args.len > 0)) {
            var look: ?[]const u8 = null;
            var run_rest = eq(u8, name, "command");
            for (args, 0..) |a, i| {
                const e = try t.expand(a, .{});
                if (e.dynamic) return .u;
                if (e.text.len > 0 and e.text[0] == '-') {
                    if (std.mem.indexOfAny(u8, e.text, "vVp") != null) run_rest = false;
                    continue;
                }
                if (run_rest) return t.run(args[i..], line);
                look = e.text;
            }
            return if (look) |l| t.lookup(l) else .t;
        }
        if (eq(u8, name, "cd")) {
            if (args.len > 0) {
                const e = try t.expand(args[0], .{});
                if (!e.dynamic) t.cwd = if (std.fs.path.isAbsolute(e.text)) e.text else try t.join(t.cwd, e.text);
            } else t.cwd = t.get("HOME").value;
            return .t;
        }
        if (t.funcs.get(name)) |body| return t.call(body, try t.expandAll(args));
        if (isIn(&harmless, name)) return .t;
        return .u;
    }

    fn expandAll(t: *Tracer, raw: []const []const u8) Err![]const []const u8 {
        var out: std.ArrayList(Exp) = .empty;
        for (raw) |w| try t.fields(w, &out);
        const r = try t.a.alloc([]const u8, out.items.len);
        for (out.items, 0..) |e, i| r[i] = e.text;
        return r;
    }

    fn unalias(t: *Tracer, name: []const u8, line: u32) Err!void {
        const h = t.ahist.getPtr(name) orelse return;
        if (h.items.len > 0 and h.items[h.items.len - 1].unset) return;
        var d = t.mkDef(line, "");
        d.unset = true;
        try h.append(t.a, d);
    }

    /// `set -o x` / `setopt x` (zsh: any case, `_` ignored, `no` turns off).
    fn option(t: *Tracer, raw: []const u8, on_in: bool) Err!void {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (raw) |ch| {
            if (ch == '_' or n == buf.len) continue;
            buf[n] = std.ascii.toLower(ch);
            n += 1;
        }
        var o = buf[0..n];
        var on = on_in;
        if (std.mem.startsWith(u8, o, "no") and !std.mem.eql(u8, o, "notify") and !std.mem.eql(u8, o, "nomatch")) {
            on = !on;
            o = o[2..];
        }
        if (std.mem.eql(u8, o, "allexport")) t.allexport = on;
        if (std.mem.eql(u8, o, "globalrcs")) t.global_rcs = on;
        if (std.mem.eql(u8, o, "rcs")) t.rcs = on;
    }

    /// `export`, `declare`, `typeset`, `local`, `readonly`.
    fn declare(t: *Tracer, name: []const u8, args: []const []const u8, line: u32) Err!St {
        const eq = std.mem.eql;
        var exported: ?bool = if (eq(u8, name, "export")) true else null;
        var local = eq(u8, name, "local") or ((eq(u8, name, "typeset") or eq(u8, name, "declare") or eq(u8, name, "integer") or eq(u8, name, "float")) and t.frames.items.len > 0);
        for (args) |a| {
            if (splitAssign(a) != null) continue;
            const e = try t.expand(a, .{});
            if (e.text.len < 2 or (e.text[0] != '-' and e.text[0] != '+')) continue;
            const on = e.text[0] == '-';
            for (e.text[1..]) |f| switch (f) {
                'x' => exported = on,
                'n' => if (eq(u8, name, "export")) {
                    exported = false;
                },
                'g' => local = false,
                'f', 'F', 'p' => return .t,
                else => {},
            };
        }
        for (args) |a| {
            if (splitAssign(a) != null) {
                try t.assign(a, exported, local, line);
                continue;
            }
            const e = try t.expand(a, .{});
            if (e.text.len == 0 or e.text[0] == '-' or e.text[0] == '+') continue;
            if (local) try t.declareLocal(e.text);
            if (exported) |x| try t.markExport(e.text, x);
        }
        return .t;
    }

    /// `NAME=value`, `NAME+=value`, `NAME=(…)`.
    fn assign(t: *Tracer, word: []const u8, exported: ?bool, local: bool, line: u32) Err!void {
        const p = splitAssign(word) orelse return;
        if (p.subscript) return; // an array element
        if (local) try t.declareLocal(p.name);
        const tied = t.tieOf(p.name) != null;
        var e: Exp = undefined;
        if (p.value.len >= 2 and p.value[0] == '(' and p.value[p.value.len - 1] == ')') {
            const toks = sh.lex(t.a, p.value[1 .. p.value.len - 1]) catch return;
            var parts: std.ArrayList([]const u8) = .empty;
            var dyn = false;
            for (toks) |tk| {
                if (tk.kind != .word) continue;
                var fs_: std.ArrayList(Exp) = .empty;
                try t.fields(tk.text, &fs_);
                for (fs_.items) |f| {
                    dyn = dyn or f.dynamic;
                    if (f.text.len > 0) try parts.append(t.a, f.text);
                }
            }
            e = .{ .text = try std.mem.join(t.a, if (tied) ":" else " ", parts.items), .dynamic = dyn };
        } else e = try t.expand(p.value, .{ .assign = true });
        if (p.append) {
            const old = t.get(p.name);
            const sep: []const u8 = if (tied and old.value.len > 0 and e.text.len > 0 and p.value.len > 0 and p.value[0] == '(') ":" else "";
            e = .{ .text = try std.mem.concat(t.a, u8, &.{ old.value, sep, e.text }), .dynamic = e.dynamic or old.dynamic };
        }
        try t.setVar(p.name, e, line, exported);
    }

    /// Where `source name` reads from: a path; a bare name through
    /// `$PATH`, then the current folder.
    fn resolveSource(t: *Tracer, p: []const u8) Err!?[]const u8 {
        if (p.len == 0) return null;
        if (std.mem.indexOfScalar(u8, p, '/') != null) {
            return if (std.fs.path.isAbsolute(p)) p else try t.join(t.cwd, p);
        }
        const path = t.get("PATH").value;
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |d| {
            if (d.len == 0) continue;
            const full = try t.join(d, p);
            if (t.fs.stat(t.fs.ctx, full)) |st| if (!st.dir) return full;
        }
        return try t.join(t.cwd, p);
    }

    /// `command -v name`: an alias, function, builtin or program on `$PATH`.
    fn lookup(t: *Tracer, name: []const u8) St {
        if (name.len == 0) return .f;
        if (std.mem.indexOfScalar(u8, name, '/') != null) return if (t.fs.access(t.fs.ctx, name, .exec)) .t else .f;
        if (t.funcs.contains(name) or isIn(&builtins, name) or isIn(&harmless, name)) return .t;
        if (t.ahist.get(name)) |h| if (h.items.len > 0 and !h.items[h.items.len - 1].unset) return .t;
        const g = t.get("PATH");
        var it = std.mem.splitScalar(u8, g.value, ':');
        while (it.next()) |d| {
            if (d.len == 0 or std.mem.indexOfScalar(u8, d, '$') != null) continue;
            const full = t.join(d, name) catch return .u;
            if (t.fs.access(t.fs.ctx, full, .exec)) return .t;
        }
        return if (g.dynamic) .u else .f;
    }

    /// macOS `eval $(/usr/libexec/path_helper -s)`: PATH = /etc/paths,
    /// then /etc/paths.d/* (by name), then what PATH had that isn't
    /// there yet. MANPATH the same way, when it is set.
    fn pathHelper(t: *Tracer, line: u32) Err!St {
        const Pair = struct { []const u8, []const u8, []const u8 };
        for ([_]Pair{ .{ "PATH", "/etc/paths", "/etc/paths.d" }, .{ "MANPATH", "/etc/manpaths", "/etc/manpaths.d" } }) |pr| {
            const old = t.get(pr[0]);
            if (std.mem.eql(u8, pr[0], "MANPATH") and !old.set) continue;
            var parts: std.ArrayList([]const u8) = .empty;
            try t.stamp(pr[1]);
            if (t.fs.read(t.fs.ctx, t.a, pr[1], 1 << 20)) |text| try addLines(t.a, &parts, text);
            try t.stamp(pr[2]);
            if (t.fs.list(t.fs.ctx, t.a, pr[2])) |names| {
                const sorted = try t.a.dupe([]const u8, names);
                std.mem.sort([]const u8, sorted, {}, lessStr);
                for (sorted) |n| {
                    const p = try t.join(pr[2], n);
                    try t.stamp(p);
                    if (t.fs.read(t.fs.ctx, t.a, p, 1 << 20)) |text| try addLines(t.a, &parts, text);
                }
            }
            var it = std.mem.splitScalar(u8, old.value, ':');
            while (it.next()) |p| if (p.len > 0 and !isIn(parts.items, p)) try parts.append(t.a, p);
            try t.setVar(pr[0], .{ .text = try std.mem.join(t.a, ":", parts.items), .dynamic = old.dynamic }, line, true);
        }
        return .t;
    }

    // -------------------------------------------------------- tests

    fn testExpr(t: *Tracer, args: []const Exp, dbl: bool) St {
        for (args) |a| if (a.dynamic) return .u;
        // `&&` / `||` ([[ ]]) and `-a` / `-o` ([ ]), left to right.
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const s = args[i].text;
            const is_and = (dbl and std.mem.eql(u8, s, "&&")) or (!dbl and std.mem.eql(u8, s, "-a") and i > 0 and i + 1 < args.len and !unaryOp(args[i - 1].text));
            const is_or = (dbl and std.mem.eql(u8, s, "||")) or (!dbl and std.mem.eql(u8, s, "-o") and i > 0 and i + 1 < args.len and !unaryOp(args[i - 1].text));
            if (!is_and and !is_or) continue;
            const l = t.testExpr(args[0..i], dbl);
            const r = t.testExpr(args[i + 1 ..], dbl);
            if (is_and) return if (l == .f or r == .f) .f else if (l == .t and r == .t) .t else .u;
            return if (l == .t or r == .t) .t else if (l == .f and r == .f) .f else .u;
        }
        if (args.len > 0 and std.mem.eql(u8, args[0].text, "!")) return not(t.testExpr(args[1..], dbl));
        if (args.len >= 2 and std.mem.eql(u8, args[0].text, "(") and std.mem.eql(u8, args[args.len - 1].text, ")")) return t.testExpr(args[1 .. args.len - 1], dbl);
        switch (args.len) {
            0 => return .f,
            1 => return if (args[0].text.len > 0) .t else .f,
            2 => return t.unary(args[0].text, args[1].text),
            3 => return binary(args[0], args[1].text, args[2], dbl),
            else => return .u,
        }
    }

    fn unary(t: *Tracer, op: []const u8, x: []const u8) St {
        if (op.len != 2 or op[0] != '-') return .u;
        const b = struct {
            fn of(v: bool) St {
                return if (v) .t else .f;
            }
        }.of;
        switch (op[1]) {
            'n' => return b(x.len > 0),
            'z' => return b(x.len == 0),
            'f', 'd', 'e', 'r', 's', 'x', 'L', 'h', 'a' => {
                const path = if (x.len == 0 or std.fs.path.isAbsolute(x)) x else t.join(t.cwd, x) catch return .u;
                t.stamp(path) catch {};
                const st = t.fs.stat(t.fs.ctx, path);
                return switch (op[1]) {
                    'e', 'a' => b(st != null),
                    'f' => b(st != null and !st.?.dir),
                    'd' => b(st != null and st.?.dir),
                    's' => b(st != null and st.?.size > 0),
                    'r' => b(st != null and t.fs.access(t.fs.ctx, path, .read)),
                    'x' => b(st != null and t.fs.access(t.fs.ctx, path, .exec)),
                    else => .u, // -L / -h: links
                };
            },
            'o' => {
                if (std.mem.eql(u8, x, "interactive")) return .t;
                if (std.mem.eql(u8, x, "login")) return b(t.in.login);
                return .u;
            },
            'v' => return b(t.get(x).set),
            else => return .u,
        }
    }

    fn binary(l: Exp, op: []const u8, r: Exp, dbl: bool) St {
        const eq = std.mem.eql;
        const b = struct {
            fn of(v: bool) St {
                return if (v) .t else .f;
            }
        }.of;
        if (eq(u8, op, "=") or eq(u8, op, "==")) return b(if (dbl) globMatch(r.pat, l.text) else eq(u8, l.text, r.text));
        if (eq(u8, op, "!=")) return b(!(if (dbl) globMatch(r.pat, l.text) else eq(u8, l.text, r.text)));
        const ints = [_][]const u8{ "-eq", "-ne", "-lt", "-gt", "-le", "-ge" };
        for (ints, 0..) |o, k| if (eq(u8, op, o)) {
            const x = std.fmt.parseInt(i64, std.mem.trim(u8, l.text, " "), 10) catch return .u;
            const y = std.fmt.parseInt(i64, std.mem.trim(u8, r.text, " "), 10) catch return .u;
            return b(switch (k) {
                0 => x == y,
                1 => x != y,
                2 => x < y,
                3 => x > y,
                4 => x <= y,
                else => x >= y,
            });
        };
        return .u;
    }
};

fn unaryOp(s: []const u8) bool {
    return s.len == 2 and s[0] == '-' and std.mem.indexOfScalar(u8, "nzfderwsxLhaov", s[1]) != null;
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

const AssignParts = struct { name: []const u8, value: []const u8, append: bool, subscript: bool };

/// `NAME=…`, `NAME+=…`, `NAME[k]=…`; null when the word isn't one.
fn splitAssign(w: []const u8) ?AssignParts {
    var i: usize = 0;
    while (i < w.len and (std.ascii.isAlphanumeric(w[i]) or w[i] == '_')) i += 1;
    if (i == 0 or std.ascii.isDigit(w[0])) return null;
    const name = w[0..i];
    var sub = false;
    if (i < w.len and w[i] == '[') {
        const close = std.mem.indexOfScalarPos(u8, w, i, ']') orelse return null;
        i = close + 1;
        sub = true;
    }
    var append = false;
    if (i + 1 < w.len and w[i] == '+' and w[i + 1] == '=') {
        append = true;
        i += 1;
    }
    if (i >= w.len or w[i] != '=') return null;
    return .{ .name = name, .value = w[i + 1 ..], .append = append, .subscript = sub };
}

fn hasGlob(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '*' or s[i] == '?' or s[i] == '[') return true;
    }
    return false;
}

fn unescape(a: std.mem.Allocator, s: []const u8) Err![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) i += 1;
        try out.append(a, s[i]);
    }
    return out.items;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn addLines(a: std.mem.Allocator, out: *std.ArrayList([]const u8), text: []const u8) Err!void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#' or isIn(out.items, l)) continue;
        try out.append(a, l);
    }
}

/// `$'…'`: the common escapes.
fn ansiC(a: std.mem.Allocator, s: []const u8) Err![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        try out.append(a, switch (s[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'e', 'E' => 0x1b,
            'a' => 7,
            '0' => 0,
            else => s[i],
        });
    }
    return out.items;
}

/// Shell pattern match: `*`, `?`, `[…]` (`!` / `^` negate, ranges), `\x`.
pub fn globMatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star_p: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pat.len) {
            switch (pat[p]) {
                '*' => {
                    star_p = p;
                    star_i = i;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    i += 1;
                    continue;
                },
                '[' => if (classMatch(pat, p, s[i])) |next| {
                    if (next.hit) {
                        p = next.end;
                        i += 1;
                        continue;
                    }
                } else if (s[i] == '[') {
                    p += 1;
                    i += 1;
                    continue;
                },
                '\\' => if (p + 1 < pat.len and pat[p + 1] == s[i]) {
                    p += 2;
                    i += 1;
                    continue;
                },
                else => |ch| if (ch == s[i]) {
                    p += 1;
                    i += 1;
                    continue;
                },
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_i += 1;
            i = star_i;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

const ClassHit = struct { hit: bool, end: usize };

/// `[…]` at `pat[p]` against `ch`; null when it isn't a class.
fn classMatch(pat: []const u8, p: usize, ch: u8) ?ClassHit {
    var k = p + 1;
    var neg = false;
    if (k < pat.len and (pat[k] == '!' or pat[k] == '^')) {
        neg = true;
        k += 1;
    }
    var hit = false;
    var first = true;
    while (k < pat.len and (first or pat[k] != ']')) : (first = false) {
        var lo = pat[k];
        if (lo == '\\' and k + 1 < pat.len) {
            k += 1;
            lo = pat[k];
        }
        if (k + 2 < pat.len and pat[k + 1] == '-' and pat[k + 2] != ']') {
            if (ch >= lo and ch <= pat[k + 2]) hit = true;
            k += 3;
        } else {
            if (ch == lo) hit = true;
            k += 1;
        }
    }
    if (k >= pat.len) return null;
    return .{ .hit = hit != neg, .end = k + 1 };
}

/// `${v%pat}` / `${v%%pat}` (suffix) and `${v#pat}` / `${v##pat}` (prefix).
fn trimPattern(v: []const u8, pat: []const u8, prefix: bool, long: bool) []const u8 {
    if (prefix) {
        var n: usize = 0;
        var best: ?usize = null;
        while (n <= v.len) : (n += 1) {
            if (globMatch(pat, v[0..n])) {
                best = n;
                if (!long) break;
            }
        }
        return if (best) |b| v[b..] else v;
    }
    var n: usize = v.len + 1;
    var best: ?usize = null;
    while (n > 0) {
        n -= 1;
        if (globMatch(pat, v[n..])) {
            best = n;
            if (!long) break;
        }
    }
    return if (best) |b| v[0..b] else v;
}

// ------------------------------------------------------------ tests

/// A made-up file tree for the tests: path → text ("/" ending = folder).
const MemFs = struct {
    files: []const [2][]const u8,

    fn fs(m: *const MemFs) Fs {
        return .{ .ctx = @constCast(m), .read = read, .stat = stat, .list = list, .access = access };
    }

    fn find(ctx: ?*anyopaque, path: []const u8) ?[]const u8 {
        const m: *const MemFs = @ptrCast(@alignCast(ctx.?));
        for (m.files) |f| if (std.mem.eql(u8, f[0], path)) return f[1];
        return null;
    }

    fn isDir(ctx: ?*anyopaque, path: []const u8) bool {
        const m: *const MemFs = @ptrCast(@alignCast(ctx.?));
        for (m.files) |f| if (f[0].len > path.len and std.mem.startsWith(u8, f[0], path) and f[0][path.len] == '/') return true;
        return false;
    }

    fn read(ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8, _: usize) ?[]u8 {
        const text = find(ctx, path) orelse return null;
        if (std.mem.startsWith(u8, text, "!unreadable")) return null;
        return a.dupe(u8, text) catch null;
    }

    fn stat(ctx: ?*anyopaque, path: []const u8) ?Stat {
        if (find(ctx, path)) |text| return .{ .size = text.len };
        if (isDir(ctx, path)) return .{ .dir = true };
        return null;
    }

    fn list(ctx: ?*anyopaque, a: std.mem.Allocator, path: []const u8) ?[]const []const u8 {
        const m: *const MemFs = @ptrCast(@alignCast(ctx.?));
        var out: std.ArrayList([]const u8) = .empty;
        for (m.files) |f| {
            if (f[0].len <= path.len + 1 or !std.mem.startsWith(u8, f[0], path) or f[0][path.len] != '/') continue;
            const rest = f[0][path.len + 1 ..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            out.append(a, rest) catch return null;
        }
        return out.items;
    }

    fn access(ctx: ?*anyopaque, path: []const u8, how: Access) bool {
        const text = find(ctx, path) orelse return isDir(ctx, path);
        if (how == .exec) return std.mem.startsWith(u8, text, "#!");
        return !std.mem.startsWith(u8, text, "!unreadable");
    }
};

fn testTrace(files: []const [2][]const u8, in: Input) Err!Result {
    const m: MemFs = .{ .files = files };
    return trace(std.testing.allocator, in, m.fs());
}

fn findEntry(r: *const Result, kind: Kind, name: []const u8) ?*const Entry {
    for (r.entries) |*e| if (e.kind == kind and std.mem.eql(u8, e.name, name)) return e;
    return null;
}

test "zsh: chain order, ZDOTDIR, path array, overrides" {
    const t = std.testing;
    var r = try testTrace(&.{
        .{ "/bin/zsh", "...../etc/zshenv..." },
        .{ "/etc/zshenv", "export EDITOR=vi\n" },
        .{ "/etc/zprofile", "eval `/usr/libexec/path_helper -s`\n" },
        .{ "/etc/paths", "/usr/local/bin\n/usr/bin\n/bin\n" },
        .{ "/etc/paths.d/10-go", "/usr/local/go/bin\n" },
        .{ "/home/u/.zshenv", "ZDOTDIR=$HOME/.config/zsh\n" },
        .{ "/home/u/.config/zsh/.zprofile", "export EDITOR=nvim\n" },
        .{ "/home/u/.config/zsh/.zshrc",
        \\path=($HOME/bin $path)
        \\alias ll='ls -l'
        \\[[ -f ~/.aliases ]] && source ~/.aliases
        \\[[ -f ~/.missing ]] && source ~/.missing
        \\export GOPATH="${GOPATH:-$HOME/go}"
        \\if command -v brew >/dev/null; then export HAS_BREW=1; fi
        \\if some_tool --check; then export MAYBE=1; else export MAYBE=0; fi
        \\eval "$(starship init zsh)"
        \\
        },
        .{ "/home/u/.aliases", "alias ll='ls -la'\nalias gs=\"git status\"\n" },
    }, .{
        .shell = .zsh,
        .shell_path = "/bin/zsh",
        .login = true,
        .env = &.{ "HOME=/home/u", "PATH=/usr/bin:/bin", "USER=u" },
        .os = .macos,
    });
    defer r.deinit();
    const editor = findEntry(&r, .env, "EDITOR").?;
    try t.expectEqual(@as(usize, 2), editor.defs.len);
    try t.expectEqualStrings("vi", editor.defs[0].value);
    try t.expectEqualStrings("nvim", editor.last().value);
    try t.expectEqualStrings("/home/u/.config/zsh/.zprofile", r.files[editor.last().file]);
    const path = findEntry(&r, .env, "PATH").?;
    try t.expectEqualStrings("/usr/bin:/bin", path.defs[0].value); // inherited
    try t.expectEqual(@as(u32, 0), path.defs[0].file);
    try t.expectEqualStrings("/usr/local/bin:/usr/bin:/bin:/usr/local/go/bin", path.defs[1].value);
    try t.expectEqualStrings("/home/u/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/go/bin", path.last().value);
    const ll = findEntry(&r, .alias, "ll").?;
    try t.expectEqual(@as(usize, 2), ll.defs.len);
    try t.expectEqualStrings("ls -la", ll.last().value);
    try t.expectEqual(@as(u32, 1), ll.last().line);
    try t.expectEqualStrings("git status", findEntry(&r, .alias, "gs").?.last().value);
    try t.expectEqualStrings("/home/u/go", findEntry(&r, .env, "GOPATH").?.last().value);
    try t.expect(findEntry(&r, .env, "HAS_BREW") == null); // no brew on PATH
    const maybe = findEntry(&r, .env, "MAYBE").?;
    try t.expectEqual(@as(usize, 2), maybe.defs.len);
    try t.expect(maybe.defs[0].cond and maybe.defs[1].cond);
    try t.expectEqual(@as(usize, 1), r.count(.untraced));
    // ZDOTDIR was set in .zshenv but never exported: not listed.
    try t.expect(findEntry(&r, .env, "ZDOTDIR") == null);
}

test "bash login: /etc/profile.d loop, pathmunge, first profile file, return" {
    const t = std.testing;
    var r = try testTrace(&.{
        .{ "/bin/bash", "no system bashrc here" },
        .{ "/etc/profile",
        \\pathmunge () {
        \\    case ":${PATH}:" in
        \\        *:"$1":*) ;;
        \\        *) if [ "$2" = "after" ] ; then PATH=$PATH:$1 ; else PATH=$1:$PATH ; fi
        \\    esac
        \\}
        \\pathmunge /usr/sbin
        \\pathmunge /usr/bin
        \\pathmunge /opt/x after
        \\for i in /etc/profile.d/*.sh ; do
        \\    if [ -r "$i" ]; then
        \\        . "$i"
        \\    fi
        \\done
        \\unset i
        \\unset -f pathmunge
        \\
        },
        .{ "/etc/profile.d/a.sh", "export LANG=C.UTF-8\n" },
        .{ "/etc/profile.d/b.sh", "!unreadable" },
        .{ "/etc/profile.d/c.txt", "export NOPE=1\n" },
        .{ "/h/.bash_profile", "[ -f ~/.bashrc ] && . ~/.bashrc\n" },
        .{ "/h/.profile", "export NOT_READ=1\n" },
        .{ "/h/.bashrc",
        \\case $- in *i*) ;; *) return;; esac
        \\export LANG=en_US.UTF-8
        \\alias ls='ls --color=auto'
        \\[ -z "$PS1" ] && return
        \\export AFTER=1
        \\
        },
    }, .{
        .shell = .bash,
        .shell_path = "/bin/bash",
        .login = true,
        .env = &.{ "HOME=/h", "PATH=/usr/bin:/bin" },
        .os = .linux,
    });
    defer r.deinit();
    try t.expectEqualStrings("/usr/sbin:/usr/bin:/bin:/opt/x", findEntry(&r, .env, "PATH").?.last().value);
    const lang = findEntry(&r, .env, "LANG").?;
    try t.expectEqual(@as(usize, 2), lang.defs.len);
    try t.expectEqualStrings("/etc/profile.d/a.sh", r.files[lang.defs[0].file]);
    try t.expectEqualStrings("en_US.UTF-8", lang.last().value);
    try t.expect(findEntry(&r, .env, "NOPE") == null);
    try t.expect(findEntry(&r, .env, "NOT_READ") == null);
    try t.expect(findEntry(&r, .env, "AFTER") != null);
    try t.expect(!findEntry(&r, .env, "AFTER").?.last().cond);
    try t.expectEqualStrings("ls --color=auto", findEntry(&r, .alias, "ls").?.last().value);
}

test "bash in gtty: system bashrc compiled in, then ~/.bashrc; unset; /etc/environment" {
    const t = std.testing;
    var r = try testTrace(&.{
        .{ "/usr/bin/bash", "xx/etc/bash.bashrcxx" },
        .{ "/etc/environment", "PATH=\"/usr/local/bin:/usr/bin:/bin\"\nLANG=C\n" },
        .{ "/etc/bash.bashrc", "[ -z \"$PS1\" ] && return\nexport SYSWIDE=1\n" },
        .{ "/h/.bashrc", "unset SYSWIDE\nexport JAVA_HOME=$(dirname $(dirname /usr/lib/jvm/x/bin/java))\nexport X=$(brew --prefix)\nsource <(kubectl completion bash)\n" },
    }, .{
        .shell = .bash,
        .shell_path = "/usr/bin/bash",
        .login = false,
        .rcfile = true,
        .env = &.{ "HOME=/h", "PATH=/usr/local/bin:/usr/bin:/bin", "LANG=en_US.UTF-8" },
        .os = .linux,
    });
    defer r.deinit();
    const sys = findEntry(&r, .env, "SYSWIDE").?;
    try t.expectEqual(@as(usize, 2), sys.defs.len);
    try t.expect(sys.last().unset);
    const path = findEntry(&r, .env, "PATH").?;
    try t.expectEqual(@as(usize, 1), path.defs.len); // same as /etc/environment
    try t.expectEqualStrings("/etc/environment", r.files[path.defs[0].file]);
    const lang = findEntry(&r, .env, "LANG").?;
    try t.expectEqual(@as(usize, 2), lang.defs.len); // /etc/environment, then inherited
    try t.expectEqual(@as(u32, 0), lang.last().file);
    try t.expectEqualStrings("/usr/lib/jvm/x", findEntry(&r, .env, "JAVA_HOME").?.last().value);
    const x = findEntry(&r, .env, "X").?;
    try t.expect(x.last().dynamic);
    try t.expectEqualStrings("$(brew --prefix)", x.last().value);
    try t.expectEqual(@as(usize, 1), r.count(.untraced));
}

test "fromArgs: gtty's zsh and bash" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = fromArgs(a, &.{ "/bin/zsh", "-l" }, &.{ "ZDOTDIR=/tmp/gtty-1", "GTTY_ZDOTDIR=/home/u/.config/zsh", "HOME=/home/u" }, "/home/u", "/tmp/gtty-1").?;
    try t.expectEqual(Shell.zsh, z.shell);
    try t.expect(z.login);
    try t.expectEqual(@as(usize, 2), z.env.len);
    try t.expectEqualStrings("ZDOTDIR=/home/u/.config/zsh", z.env[1]);
    const b = fromArgs(a, &.{ "/bin/bash", "--rcfile", "/tmp/gtty-1/bash-rc", "-i" }, &.{"GTTY_BASH_LOGIN=1"}, "", "/tmp/gtty-1").?;
    try t.expect(b.login and b.rcfile);
    try t.expect(fromArgs(a, &.{ "/bin/zsh", "-c", "ls" }, &.{}, "", "") == null);
    try t.expect(fromArgs(a, &.{"fish"}, &.{}, "", "") == null);
}

test "glob and pattern trimming" {
    const t = std.testing;
    try t.expect(globMatch("*.sh", "a.sh"));
    try t.expect(!globMatch("*.sh", "a.txt"));
    try t.expect(globMatch("*i*", "himBH"));
    try t.expect(globMatch("darwin*", "darwin"));
    try t.expect(globMatch("[a-c]x", "bx"));
    try t.expect(!globMatch("[!a-c]x", "bx"));
    try t.expect(globMatch("*:/usr/bin:*", ":/bin:/usr/bin:/x:"));
    try t.expect(globMatch("\\*", "*"));
    try t.expectEqualStrings("/a/b", trimPattern("/a/b/c.sh", "/*", false, false));
    try t.expectEqualStrings("c.sh", trimPattern("/a/b/c.sh", "*/", true, true));
}
