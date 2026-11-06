// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

//! The gtty SDK for Zig: what an extension imports (docs/extensions.md).
//! gtty's standard chips use it too (src/chips/), running inside gtty.
//! AI assistants: read AGENTS.md first; examples/hosts.zig is a complete
//! extension.
//!
//! An extension is a set of optional functions, found by name
//! (`Definition.of`): `onGttyStart`, `onWindowStart`, `onWindowClose`,
//! `onGttyClose`, `onEvent`. `Window` is its connection to one job
//! window: its connectors act on that window, and the window's events
//! arrive with it.

const std = @import("std");

/// The version of the extension API this SDK speaks.
pub const api_version: u32 = 1;

pub const Error = error{
    /// The window this connection was for has closed.
    WindowClosed,
    /// `showDialog` with no dialog set.
    NoDialog,
    /// A dialog's `layout`, `buttons` or widget `type` isn't known.
    BadDialog,
    /// A peek or epeek with no chip, or `setDisplayMode` to one not set.
    NoChip,
    /// A file name that isn't a plain name (no `/`, no `..`, no leading `.`).
    BadName,
    /// No such file.
    NoFile,
    /// Someone else has the file: the timeout passed.
    FileInUse,
    /// gtty closed this file (held too long, or its window ended).
    FileClosed,
    /// The storage's size limit.
    StorageFull,
    StorageFailed,
};

/// How many parts a text can have; more are left out.
pub const max_parts = 8;

/// How a part of a text looks. Left out: gtty's default for that text.
pub const TextAttr = struct {
    /// Colors, 0xrrggbb.
    fg: ?u24 = null,
    bk: ?u24 = null,
    /// Percent of the normal size.
    size: ?u16 = null,
    bold: bool = false,
    /// A line through the text.
    stroke: bool = false,
};

pub const TextPart = struct {
    string: []const u8 = "",
    attr: TextAttr = .{},
};

/// A text: parts drawn one after the other, each with its own look.
/// Build one with `newText`.
pub const Text = struct {
    parts: [max_parts]TextPart = @splat(.{}),
    len: u8 = 0,

    pub fn slice(t: *const Text) []const TextPart {
        return t.parts[0..t.len];
    }

    pub fn isEmpty(t: *const Text) bool {
        for (t.slice()) |p| if (p.string.len > 0) return false;
        return true;
    }

    /// The strings joined, cut to `buf`.
    pub fn plain(t: *const Text, buf: []u8) []const u8 {
        if (t.len == 1) return t.parts[0].string;
        var n: usize = 0;
        for (t.slice()) |p| {
            const k = @min(p.string.len, buf.len - n);
            @memcpy(buf[n..][0..k], p.string[0..k]);
            n += k;
        }
        return buf[0..n];
    }
};

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn attrOf(a: anytype) TextAttr {
    if (@TypeOf(a) == TextAttr) return a;
    var out: TextAttr = .{};
    inline for (@typeInfo(@TypeOf(a)).@"struct".fields) |f| {
        if (comptime !f.is_comptime or !std.mem.eql(u8, f.name, "0")) @field(out, f.name) = @field(a, f.name);
    }
    return out;
}

/// A text, from a string, a string and its attributes, or a list of both:
///
///     newText("main")
///     newText(.{ "main", .{ .bold = true } })
///     newText(.{ .{ "feature/", .{} }, .{ "login", .{ .bold = true } } })
///
/// A `[]const TextPart` works too. The strings aren't copied.
pub fn newText(v: anytype) Text {
    const V = @TypeOf(v);
    if (V == Text) return v;
    var t: Text = .{};
    if (comptime isString(V)) {
        t.parts[0] = .{ .string = v };
        t.len = 1;
        return t;
    }
    if (V == []const TextPart or V == []TextPart) {
        const n = @min(v.len, max_parts);
        @memcpy(t.parts[0..n], v[0..n]);
        t.len = @intCast(n);
        return t;
    }
    const fields = @typeInfo(V).@"struct".fields;
    if (fields.len > 0 and comptime isString(fields[0].type)) {
        t.parts[0] = .{ .string = v[0], .attr = if (fields.len > 1) attrOf(v[1]) else .{} };
        t.len = 1;
        return t;
    }
    if (fields.len > max_parts) @compileError("newText: more than max_parts parts");
    inline for (fields, 0..) |_, i| {
        t.parts[i] = .{ .string = v[i][0], .attr = if (@typeInfo(@TypeOf(v[i])).@"struct".fields.len > 1) attrOf(v[i][1]) else .{} };
    }
    t.len = fields.len;
    return t;
}

/// What an extension can register for. Few on purpose.
pub const EventKind = enum(u5) {
    /// The window's folder, branch or remote session changed. Sent once
    /// when the window starts, then only on a change.
    window_changed,
    /// A command started in the window's shell.
    command_started,
    /// A button of this extension was pressed (`Event.button`); comes
    /// without registering, and only to the extension that owns it.
    button_click,
};

/// What fired an event.
pub const Element = enum { window };

/// The header (`eventId`, `element`), then the fields of the element
/// that fired it. The slices last until the handler returns.
pub const Event = struct {
    eventId: u32 = 0,
    element: Element = .window,
    kind: EventKind,
    /// `window_changed`: the folder of the window's process;
    /// `command_started`: the folder the command runs in.
    folder: []const u8 = "",
    /// The branch shown for that folder, empty outside a repo.
    branch: []const u8 = "",
    /// In an ssh / mosh session: `folder` is the local one.
    remote: bool = false,
    /// `command_started`: the command line.
    command: []const u8 = "",
    /// `button_click`.
    button: ?ButtonClick = null,
};

/// A dialog widget's value, in `ButtonClick.fields`.
pub const FieldValue = struct {
    id: []const u8,
    value: Value,
};

pub const Value = union(enum) { text: []const u8, on: bool };

/// A button pressed. For a dialog `id` is `ok`, `cancel`, `yes`, `no`, or
/// `kill` / `timeout` (the dialog is already closed, no `fields`).
pub const ButtonClick = struct {
    id: []const u8 = "",
    text: []const u8 = "",
    /// What the extension linked to the button.
    data: []const u8 = "",
    /// The name given in `onclick`.
    function: []const u8 = "",
    fields: []const FieldValue = &.{},
    /// ⌘ (Linux Ctrl) was held.
    command: bool = false,

    /// A text box's or drop box's value.
    pub fn field(b: ButtonClick, id: []const u8) ?[]const u8 {
        for (b.fields) |f| if (std.mem.eql(u8, f.id, id)) switch (f.value) {
            .text => |s| return s,
            .on => return null,
        };
        return null;
    }

    /// A check box's value.
    pub fn checked(b: ButtonClick, id: []const u8) bool {
        for (b.fields) |f| if (std.mem.eql(u8, f.id, id)) switch (f.value) {
            .on => |v| return v,
            .text => return false,
        };
        return false;
    }

    pub fn is(b: ButtonClick, id: []const u8) bool {
        return std.mem.eql(u8, b.id, id);
    }
};

/// The central on-click: calls the `pub fn` of `Actions` that the event
/// names, with the window and the click.
pub fn dispatch(comptime Actions: type, win: *Window, ev: *const Event) anyerror!void {
    const b = ev.button orelse return;
    inline for (@typeInfo(Actions).@"struct".decls) |d| {
        if (@typeInfo(@TypeOf(@field(Actions, d.name))) == .@"fn" and std.mem.eql(u8, d.name, b.function)) {
            return @field(Actions, d.name)(win, b);
        }
    }
    return error.NoSuchFunction;
}

pub const Layout = enum { form, grid, table };
pub const ButtonSet = enum { ok, okcancel, yesno };
pub const WidgetType = enum { text, checkbox, dropdown, label };

/// A widget in a dialog; null fields stay as they are.
pub const Widget = struct {
    id: []const u8,
    type: ?WidgetType = null,
    label: ?Text = null,
    value: ?Value = null,
    options: ?[]const []const u8 = null,
    filter: ?bool = null,
};

/// A change to a dialog: null fields stay as they are. `fields` are
/// matched by id; a new id is added.
pub const DialogUpdate = struct {
    title: ?Text = null,
    layout: ?Layout = null,
    columns: ?u16 = null,
    rows: ?u16 = null,
    fields: []const Widget = &.{},
    buttons: ?ButtonSet = null,
    onclick: ?[]const u8 = null,
    /// Seconds.
    timeout: ?u32 = null,
    err: ?union(enum) { set: []const u8, clear } = null,
};

/// A field of an update: left out it stays, null clears it.
pub fn Field(comptime T: type) type {
    return union(enum) {
        keep,
        clear,
        set: T,
        pub const Inner = T;
    };
}

/// A change to a chip.
pub const ChipUpdate = struct {
    text: Field(Text) = .keep,
    dimmed: Field(bool) = .keep,
    onclick: Field([]const u8) = .keep,
    onhover: Field([]const u8) = .keep,
    data: Field([]const u8) = .keep,
};

/// Three dots instead of an icon, on a line's `postButton`.
pub const Dots = enum {
    /// ⋮ `items` in a popup list; a pick is a click with that item's fields.
    vertical,
    /// ⋯ a plain click: what happens is the extension's.
    horizontal,
};

/// A row of a ⋮ popup list.
pub const Item = struct {
    id: []const u8 = "",
    text: Text = .{},
    data: []const u8 = "",
};

/// No `onclick` (and no `dots`): only an icon, nothing to click.
pub const Button = struct {
    id: []const u8 = "",
    icon: []const u8 = "",
    text: Text = .{},
    onclick: []const u8 = "",
    data: []const u8 = "",
    dots: ?Dots = null,
    items: []const Item = &.{},
};

/// A row of an epeek.
pub const Line = struct {
    id: []const u8 = "",
    prefixButton: ?Button = null,
    text: Text = .{},
    postButton: ?Button = null,
    onclick: []const u8 = "",
    onhover: []const u8 = "",
    data: []const u8 = "",
};

/// The peek: one line. gtty adds the expand button and the ×.
pub const Peek = struct {
    expand: bool = false,
    /// The mouse resting on the peek opens the epeek too.
    hoverExpand: bool = false,
    /// Called when the expand button opens the epeek.
    onexpand: []const u8 = "",
    prefixButton: ?Button = null,
    text: Text = .{},
    postButton: ?Button = null,
    onclick: []const u8 = "",
    onhover: []const u8 = "",
    data: []const u8 = "",
};

pub const PeekUpdate = struct {
    expand: Field(bool) = .keep,
    hoverExpand: Field(bool) = .keep,
    onexpand: Field([]const u8) = .keep,
    prefixButton: Field(Button) = .keep,
    text: Field(Text) = .keep,
    postButton: Field(Button) = .keep,
    onclick: Field([]const u8) = .keep,
    onhover: Field([]const u8) = .keep,
    data: Field([]const u8) = .keep,
};

/// The filter box. Every change of its text is a click with `id`
/// `filter`, the text in `text` and `onclick` in `function`; gtty doesn't
/// filter the list.
pub const Filter = struct {
    /// The text to start with.
    text: []const u8 = "",
    /// Shown while the box is empty.
    hint: Text = .{},
    /// Possible strings, offered while typing; Tab takes the first.
    options: []const []const u8 = &.{},
    onclick: []const u8 = "",
};

/// The epeek's top frame; gtty adds the × after `right`.
pub const Frame = struct {
    left: [2]?Button = @splat(null),
    right: [2]?Button = @splat(null),
    text: Text = .{},
    onclick: []const u8 = "",
    onhover: []const u8 = "",
    data: []const u8 = "",
    /// In a row of its own under the frame.
    filter: ?Filter = null,
};

/// How an action shown in an epeek is going. `ok` closes it after a
/// second.
pub const State = enum { idle, busy, ok, err };

/// The epeek: the list that opens over the peek or the chip.
pub const Epeek = struct {
    frame: ?Frame = null,
    lines: []const Line = &.{},
    /// The line selected at first (and after new `lines`).
    selected: usize = 0,
    /// Shown when `lines` is empty.
    empty: Text = .{},
    /// A dim line under the list.
    footer: Text = .{},
    state: State = .idle,
    /// Under the list, one row each, in the state's color.
    message: []const Text = &.{},
};

pub const EpeekUpdate = struct {
    frame: Field(Frame) = .keep,
    lines: Field([]const Line) = .keep,
    selected: Field(usize) = .keep,
    empty: Field(Text) = .keep,
    footer: Field(Text) = .keep,
    state: Field(State) = .keep,
    message: Field([]const Text) = .keep,
};

/// What `setDisplayMode` shows.
pub const DisplayMode = enum { chip, peek, epeek };

pub const LogLevel = enum { debug, info, warn, err };

/// Where `log` goes: `gtty ext logs`.
pub const Logger = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, level: LogLevel, message: []const u8) void,

    /// A message over 1024 bytes is cut. Never fails.
    pub fn log(l: Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print(fmt, args) catch {};
        l.write(l.ctx, level, w.buffered());
    }
};

/// How a connection reaches gtty.
pub const Connection = struct {
    setChip: *const fn (ctx: *anyopaque, update: ChipUpdate) Error!void,
    setPeek: *const fn (ctx: *anyopaque, update: ?PeekUpdate) Error!void,
    setEpeek: *const fn (ctx: *anyopaque, update: ?EpeekUpdate) Error!void,
    setDisplayMode: *const fn (ctx: *anyopaque, mode: DisplayMode) Error!void,
    registerEvent: *const fn (ctx: *anyopaque, kind: EventKind) Error!void,
    unregisterEvent: *const fn (ctx: *anyopaque, kind: EventKind) Error!void,
    setDialog: *const fn (ctx: *anyopaque, update: DialogUpdate) Error!void,
    showDialog: *const fn (ctx: *anyopaque) Error!void,
    closeDialog: *const fn (ctx: *anyopaque) Error!void,
    shell: *const fn (ctx: *anyopaque, buf: []u8) Error![]const u8,
    storageOpen: *const fn (ctx: *anyopaque, kind: StorageKind, name: []const u8, mode: OpenMode, timeout_ms: u32) Error!u32,
    storageRead: *const fn (ctx: *anyopaque, handle: u32, buf: []u8) Error!usize,
    storageWrite: *const fn (ctx: *anyopaque, handle: u32, bytes: []const u8) Error!void,
    storageClose: *const fn (ctx: *anyopaque, handle: u32) Error!void,
    storageDelete: *const fn (ctx: *anyopaque, kind: StorageKind, name: []const u8, timeout_ms: u32) Error!void,
    storageList: *const fn (ctx: *anyopaque, kind: StorageKind, out: []u8) Error!usize,
};

pub const StorageKind = enum { ephemeral, stateful };
pub const OpenMode = enum { read, write };

/// A file open in a storage.
pub const File = struct {
    ctx: *anyopaque,
    conn: *const Connection,
    handle: u32,

    /// Bytes read into `buf`; 0 at the end.
    pub fn read(f: File, buf: []u8) Error!usize {
        return f.conn.storageRead(f.ctx, f.handle, buf);
    }

    pub fn write(f: File, bytes: []const u8) Error!void {
        return f.conn.storageWrite(f.ctx, f.handle, bytes);
    }

    /// A file opened for writing takes the old one's place here.
    pub fn close(f: File) Error!void {
        return f.conn.storageClose(f.ctx, f.handle);
    }
};

/// `win.ephemeral` or `win.stateful`. Names are plain file names.
pub const Storage = struct {
    ctx: *anyopaque,
    conn: *const Connection,
    kind: StorageKind,

    /// Waits up to `timeout_ms` for the file (0: tries once). Writing
    /// replaces the whole file, at `close`; until then nobody else can use it.
    pub fn openWrite(s: Storage, name: []const u8, timeout_ms: u32) Error!File {
        return .{ .ctx = s.ctx, .conn = s.conn, .handle = try s.conn.storageOpen(s.ctx, s.kind, name, .write, timeout_ms) };
    }

    /// Waits up to `timeout_ms` while someone writes it (0: tries once).
    pub fn openRead(s: Storage, name: []const u8, timeout_ms: u32) Error!File {
        return .{ .ctx = s.ctx, .conn = s.conn, .handle = try s.conn.storageOpen(s.ctx, s.kind, name, .read, timeout_ms) };
    }

    pub fn delete(s: Storage, name: []const u8, timeout_ms: u32) Error!void {
        return s.conn.storageDelete(s.ctx, s.kind, name, timeout_ms);
    }

    /// The file names, one per line, into `out`; what doesn't fit is left out.
    pub fn list(s: Storage, out: []u8) Error![]const u8 {
        return out[0..try s.conn.storageList(s.ctx, s.kind, out)];
    }
};

/// `v` as a `T`: anonymous structs become `T`'s, strings become texts,
/// enums come from their names.
fn conv(comptime T: type, v: anytype) T {
    const V = @TypeOf(v);
    if (V == T) return v;
    if (T == Text) return newText(v);
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (V == @TypeOf(null)) return null;
            return conv(o.child, v);
        },
        .@"enum" => {
            if (comptime isString(V)) return std.meta.stringToEnum(T, v) orelse @panic("gtty: unknown name");
            return v;
        },
        .@"struct" => {
            var out: T = .{};
            inline for (@typeInfo(V).@"struct".fields) |f| {
                @field(out, f.name) = conv(@TypeOf(@field(out, f.name)), @field(v, f.name));
            }
            return out;
        },
        .array => |a| {
            var out: T = @splat(null);
            inline for (@typeInfo(V).@"struct".fields, 0..) |_, i| out[i] = conv(a.child, v[i]);
            return out;
        },
        else => return v,
    }
}

/// An update from an anonymous struct: fields left out stay, null clears.
fn updateOf(comptime U: type, v: anytype) U {
    if (@TypeOf(v) == U) return v;
    var out: U = .{};
    inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |f| {
        const F = @TypeOf(@field(out, f.name));
        @field(out, f.name) = if (comptime f.type == @TypeOf(null)) .clear else .{ .set = conv(F.Inner, @field(v, f.name)) };
    }
    return out;
}

/// The UI connector: `win.ui.set(.{ .chip = .{ .text = "main" } })`,
/// `win.ui.set(.{ .dialog = … })`. A field left out stays, a field set to
/// null is cleared (a chip with no text isn't shown).
pub const Ui = struct {
    ctx: *anyopaque,
    conn: *const Connection,

    pub fn set(ui: Ui, update: anytype) Error!void {
        const U = @TypeOf(update);
        if (@hasField(U, "dialog")) return ui.setDialog(update.dialog);
        if (@hasField(U, "peek")) {
            if (comptime @TypeOf(update.peek) == @TypeOf(null)) return ui.conn.setPeek(ui.ctx, null);
            return ui.conn.setPeek(ui.ctx, updateOf(PeekUpdate, update.peek));
        }
        if (@hasField(U, "epeek")) {
            if (comptime @TypeOf(update.epeek) == @TypeOf(null)) return ui.conn.setEpeek(ui.ctx, null);
            return ui.setEpeek(update.epeek);
        }
        if (!@hasField(U, "chip")) @compileError("win.ui.set: .chip, .peek, .epeek or .dialog");
        return ui.conn.setChip(ui.ctx, updateOf(ChipUpdate, update.chip));
    }

    /// A list of lines written in place becomes a slice here.
    fn setEpeek(ui: Ui, e: anytype) Error!void {
        const E = @TypeOf(e);
        if (comptime E != EpeekUpdate and @hasField(E, "lines") and @typeInfo(@TypeOf(e.lines)) == .@"struct") {
            var lines: [e.lines.len]Line = undefined;
            inline for (e.lines, 0..) |l, i| lines[i] = conv(Line, l);
            var u: EpeekUpdate = .{};
            inline for (@typeInfo(E).@"struct".fields) |f| {
                if (comptime std.mem.eql(u8, f.name, "lines")) continue;
                const F = @TypeOf(@field(u, f.name));
                @field(u, f.name) = if (comptime f.type == @TypeOf(null)) .clear else .{ .set = conv(F.Inner, @field(e, f.name)) };
            }
            u.lines = .{ .set = &lines };
            return ui.conn.setEpeek(ui.ctx, u);
        }
        return ui.conn.setEpeek(ui.ctx, updateOf(EpeekUpdate, e));
    }

    /// Show the chip (closing this extension's peek or epeek), the peek or
    /// the epeek. Only one is open at a time: unless handling the user's
    /// click, a peek of another extension stays and this one doesn't open.
    pub fn setDisplayMode(ui: Ui, mode: DisplayMode) Error!void {
        return ui.conn.setDisplayMode(ui.ctx, mode);
    }

    fn setDialog(ui: Ui, d: anytype) Error!void {
        const D = @TypeOf(d);
        var change: DialogUpdate = .{};
        if (@hasField(D, "title")) change.title = newText(d.title);
        if (@hasField(D, "columns")) change.columns = d.columns;
        if (@hasField(D, "rows")) change.rows = d.rows;
        if (@hasField(D, "onclick")) change.onclick = d.onclick;
        if (@hasField(D, "timeout")) change.timeout = d.timeout;
        if (@hasField(D, "layout")) change.layout = std.meta.stringToEnum(Layout, d.layout) orelse return error.BadDialog;
        if (@hasField(D, "buttons")) change.buttons = std.meta.stringToEnum(ButtonSet, d.buttons) orelse return error.BadDialog;
        if (@hasField(D, "error")) {
            change.err = if (comptime @TypeOf(d.@"error") == @TypeOf(null)) .clear else .{ .set = d.@"error" };
        }
        if (!@hasField(D, "fields")) return ui.conn.setDialog(ui.ctx, change);
        if (comptime @TypeOf(d.fields) == []const Widget) {
            change.fields = d.fields;
            return ui.conn.setDialog(ui.ctx, change);
        }
        var ws: [d.fields.len]Widget = undefined;
        inline for (d.fields, 0..) |f, i| ws[i] = try widget(f);
        change.fields = &ws;
        return ui.conn.setDialog(ui.ctx, change);
    }

    fn widget(f: anytype) Error!Widget {
        const F = @TypeOf(f);
        var w: Widget = .{ .id = f.id };
        if (@hasField(F, "type")) w.type = std.meta.stringToEnum(WidgetType, f.type) orelse return error.BadDialog;
        if (@hasField(F, "label")) w.label = newText(f.label);
        if (@hasField(F, "options")) w.options = f.options;
        if (@hasField(F, "filter")) w.filter = f.filter;
        if (@hasField(F, "value")) {
            w.value = if (comptime @TypeOf(f.value) == bool) .{ .on = f.value } else .{ .text = f.value };
        }
        return w;
    }

    /// Show the dialog set with `set`.
    pub fn showDialog(ui: Ui) Error!void {
        return ui.conn.showDialog(ui.ctx);
    }

    /// Close it: the buttons only report, the extension closes.
    pub fn closeDialog(ui: Ui) Error!void {
        return ui.conn.closeDialog(ui.ctx);
    }
};

/// The events connector.
pub const Events = struct {
    ctx: *anyopaque,
    conn: *const Connection,

    pub fn registerEvent(e: Events, kind: EventKind) Error!void {
        return e.conn.registerEvent(e.ctx, kind);
    }

    pub fn unregisterEvent(e: Events, kind: EventKind) Error!void {
        return e.conn.unregisterEvent(e.ctx, kind);
    }
};

/// The connection to one job window.
pub const Window = struct {
    id: u32,
    ui: Ui,
    events: Events,
    /// Files of this instance, deleted when it ends.
    ephemeral: Storage,
    /// Files of the extension, common to all its instances.
    stateful: Storage,
    logger: Logger,
    shell_buf: [64]u8 = undefined,

    /// A line in `gtty ext logs`, with this window's id. Works in
    /// `onWindowClose` too.
    pub fn log(w: *Window, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        w.logger.log(level, fmt, args);
    }

    /// The name of the shell in front in this window; if what is in front
    /// isn't a shell, the shell running under the window. Valid until the
    /// next call.
    pub fn shell(w: *Window) Error![]const u8 {
        return w.ui.conn.shell(w.ui.ctx, &w.shell_buf);
    }
};

/// The extension itself, for `onGttyStart` and `onGttyClose`.
pub const Extension = struct {
    name: []const u8,
    logger: Logger,

    /// A line in `gtty ext logs`, about no window.
    pub fn log(e: *Extension, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        e.logger.log(level, fmt, args);
    }
};

/// An extension's functions.
pub const Definition = struct {
    name: []const u8,
    onGttyStart: ?*const fn (ext: *Extension) anyerror!void = null,
    onWindowStart: ?*const fn (win: *Window) anyerror!void = null,
    onWindowClose: ?*const fn (win: *Window) anyerror!void = null,
    onGttyClose: ?*const fn (ext: *Extension) anyerror!void = null,
    onEvent: ?*const fn (win: *Window, ev: *const Event) anyerror!void = null,

    /// The definition of module `M`: the functions it has.
    pub fn of(comptime M: type, comptime name: []const u8) Definition {
        return .{
            .name = name,
            .onGttyStart = if (@hasDecl(M, "onGttyStart")) M.onGttyStart else null,
            .onWindowStart = if (@hasDecl(M, "onWindowStart")) M.onWindowStart else null,
            .onWindowClose = if (@hasDecl(M, "onWindowClose")) M.onWindowClose else null,
            .onGttyClose = if (@hasDecl(M, "onGttyClose")) M.onGttyClose else null,
            .onEvent = if (@hasDecl(M, "onEvent")) M.onEvent else null,
        };
    }
};

const Fake = struct {
    last: ChipUpdate = .{},
    fields: usize = 0,
    layout: ?Layout = null,
    second: []const u8 = "",
    on: bool = false,
    peek: ?PeekUpdate = null,
    epeek: ?EpeekUpdate = null,
    lines: usize = 0,
    first_line: []const u8 = "",
    mode: DisplayMode = .chip,

    fn setChip(ctx: *anyopaque, update: ChipUpdate) Error!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.last = update;
    }
    fn setPeek(ctx: *anyopaque, update: ?PeekUpdate) Error!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.peek = update;
    }
    fn setEpeek(ctx: *anyopaque, update: ?EpeekUpdate) Error!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.lines = if (update) |u| switch (u.lines) {
            .set => |l| l.len,
            else => 0,
        } else 0;
        f.first_line = if (update) |u| switch (u.lines) {
            .set => |l| if (l.len > 0) l[0].text.parts[0].string else "",
            else => "",
        } else "";
        f.epeek = update;
    }
    fn setMode(ctx: *anyopaque, m: DisplayMode) Error!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.mode = m;
    }
    fn none(_: *anyopaque, _: EventKind) Error!void {}
    fn setDialog(ctx: *anyopaque, u: DialogUpdate) Error!void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.fields = u.fields.len;
        f.layout = u.layout;
        if (u.fields.len > 1) {
            f.second = u.fields[0].value.?.text;
            f.on = u.fields[1].value.?.on;
        }
    }
    fn noop(_: *anyopaque) Error!void {}
    fn shell(_: *anyopaque, buf: []u8) Error![]const u8 {
        @memcpy(buf[0..3], "zsh");
        return buf[0..3];
    }
    fn stOpen(_: *anyopaque, kind: StorageKind, _: []const u8, mode: OpenMode, timeout_ms: u32) Error!u32 {
        return @as(u32, @intFromEnum(kind)) * 100000 + @as(u32, @intFromEnum(mode)) * 10000 + timeout_ms;
    }
    fn stRead(_: *anyopaque, _: u32, _: []u8) Error!usize {
        return 0;
    }
    fn stWrite(_: *anyopaque, _: u32, _: []const u8) Error!void {}
    fn stClose(_: *anyopaque, _: u32) Error!void {}
    fn stDelete(_: *anyopaque, _: StorageKind, _: []const u8, _: u32) Error!void {}
    fn logLine(_: *anyopaque, _: LogLevel, _: []const u8) void {}
    fn stList(_: *anyopaque, _: StorageKind, out: []u8) Error!usize {
        @memcpy(out[0..2], "a\n");
        return 2;
    }
    const conn: Connection = .{ .setChip = setChip, .setPeek = setPeek, .setEpeek = setEpeek, .setDisplayMode = setMode, .registerEvent = none, .unregisterEvent = none, .setDialog = setDialog, .showDialog = noop, .closeDialog = noop, .shell = shell, .storageOpen = stOpen, .storageRead = stRead, .storageWrite = stWrite, .storageClose = stClose, .storageDelete = stDelete, .storageList = stList };
};

test "log: formats, and a long message is cut" {
    const Sink = struct {
        var level: LogLevel = .debug;
        var len: usize = 0;
        var first: [16]u8 = undefined;
        fn write(_: *anyopaque, l: LogLevel, m: []const u8) void {
            level = l;
            len = m.len;
            const n = @min(m.len, first.len);
            @memcpy(first[0..n], m[0..n]);
        }
    };
    var ctx: u8 = 0;
    const l: Logger = .{ .ctx = &ctx, .write = Sink.write };
    l.log(.warn, "host {s}: {d}", .{ "a", 7 });
    try std.testing.expectEqual(LogLevel.warn, Sink.level);
    try std.testing.expectEqualStrings("host a: 7", Sink.first[0..Sink.len]);
    l.log(.info, "{s}", .{"x" ** 2000});
    try std.testing.expectEqual(@as(usize, 1024), Sink.len);
}

test "a field left out stays, null clears" {
    var f: Fake = .{};
    const ui: Ui = .{ .ctx = &f, .conn = &Fake.conn };
    try ui.set(.{ .chip = .{ .text = "main" } });
    try std.testing.expectEqualStrings("main", f.last.text.set.parts[0].string);
    try std.testing.expect(f.last.dimmed == .keep);
    try ui.set(.{ .chip = .{ .text = null, .dimmed = true } });
    try std.testing.expect(f.last.text == .clear);
    try std.testing.expect(f.last.dimmed.set);
    try ui.set(.{ .chip = .{ .dimmed = false } });
    try std.testing.expect(f.last.text == .keep);
}

test "newText: a string, a string and attributes, a list of both" {
    const one = newText("main");
    try std.testing.expectEqual(@as(u8, 1), one.len);
    try std.testing.expectEqualStrings("main", one.parts[0].string);
    const name: []const u8 = "dev";
    const styled = newText(.{ name, .{ .bold = true, .fg = 0x40c060 } });
    try std.testing.expect(styled.parts[0].attr.bold);
    try std.testing.expectEqual(@as(?u24, 0x40c060), styled.parts[0].attr.fg);
    const two = newText(.{ .{ "feature/", .{} }, .{ "login", .{ .stroke = true } } });
    try std.testing.expectEqual(@as(u8, 2), two.len);
    try std.testing.expect(two.parts[1].attr.stroke);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("feature/login", two.plain(&buf));
}

test "peek and epeek: left out stays, null clears, lines in place work" {
    var f: Fake = .{};
    const ui: Ui = .{ .ctx = &f, .conn = &Fake.conn };
    try ui.set(.{ .peek = .{ .expand = true, .text = "main", .prefixButton = .{ .icon = "copy", .onclick = "copy" }, .postButton = null } });
    try std.testing.expect(f.peek.?.expand.set);
    try std.testing.expectEqualStrings("copy", f.peek.?.prefixButton.set.icon);
    try std.testing.expect(f.peek.?.postButton == .clear);
    try std.testing.expect(f.peek.?.onclick == .keep);
    try ui.set(.{ .epeek = .{ .frame = .{ .left = .{.{ .text = "add", .onclick = "add" }} }, .lines = .{
        .{ .text = "alpha", .onclick = "pick" },
        .{ .text = "beta" },
    } } });
    try std.testing.expectEqual(@as(usize, 2), f.lines);
    try std.testing.expectEqualStrings("alpha", f.first_line);
    try std.testing.expectEqualStrings("add", f.epeek.?.frame.set.left[0].?.text.parts[0].string);
    const rows = [_]Line{.{ .text = newText("x") }};
    try ui.set(.{ .epeek = .{ .lines = @as([]const Line, &rows), .state = "busy" } });
    try std.testing.expectEqual(@as(usize, 1), f.lines);
    try std.testing.expectEqual(State.busy, f.epeek.?.state.set);
    try ui.set(.{ .peek = null });
    try std.testing.expect(f.peek == null);
    try ui.setDisplayMode(.epeek);
    try std.testing.expectEqual(DisplayMode.epeek, f.mode);
}

test "a definition has the functions its module has" {
    const M = struct {
        pub fn onWindowStart(_: *Window) anyerror!void {}
    };
    const d = Definition.of(M, "m");
    try std.testing.expect(d.onWindowStart != null);
    try std.testing.expect(d.onEvent == null);
}

test "a dialog: strings become enums, values keep their kind" {
    var f: Fake = .{};
    const ui: Ui = .{ .ctx = &f, .conn = &Fake.conn };
    try ui.set(.{ .dialog = .{ .layout = "grid", .fields = .{
        .{ .id = "a", .type = "text", .value = "x" },
        .{ .id = "b", .type = "checkbox", .value = true },
    } } });
    try std.testing.expectEqual(@as(?Layout, .grid), f.layout);
    try std.testing.expectEqual(@as(usize, 2), f.fields);
    try std.testing.expectEqualStrings("x", f.second);
    try std.testing.expect(f.on);
    try std.testing.expectError(error.BadDialog, ui.set(.{ .dialog = .{ .layout = "circle" } }));
}

fn fakeWindow(f: *Fake) Window {
    return .{
        .id = 1,
        .ui = .{ .ctx = f, .conn = &Fake.conn },
        .events = .{ .ctx = f, .conn = &Fake.conn },
        .ephemeral = .{ .ctx = f, .conn = &Fake.conn, .kind = .ephemeral },
        .stateful = .{ .ctx = f, .conn = &Fake.conn, .kind = .stateful },
        .logger = .{ .ctx = f, .write = Fake.logLine },
    };
}

test "the shell and the two storages" {
    var f: Fake = .{};
    var win = fakeWindow(&f);
    try std.testing.expectEqualStrings("zsh", try win.shell());
    try std.testing.expectEqual(@as(u32, 110500), (try win.stateful.openWrite("a", 500)).handle);
    try std.testing.expectEqual(@as(u32, 7), (try win.ephemeral.openRead("a", 7)).handle);
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("a\n", try win.stateful.list(&out));
}

test "dispatch calls the function the click names" {
    const A = struct {
        var hits: u32 = 0;
        pub fn one(_: *Window, b: ButtonClick) anyerror!void {
            hits += @intFromBool(b.checked("k") and std.mem.eql(u8, b.field("n").?, "v"));
        }
    };
    var f: Fake = .{};
    var win = fakeWindow(&f);
    const fields = [_]FieldValue{ .{ .id = "n", .value = .{ .text = "v" } }, .{ .id = "k", .value = .{ .on = true } } };
    const ev: Event = .{ .kind = .button_click, .button = .{ .function = "one", .fields = &fields } };
    try dispatch(A, &win, &ev);
    try std.testing.expectEqual(@as(u32, 1), A.hits);
    const bad: Event = .{ .kind = .button_click, .button = .{ .function = "two" } };
    try std.testing.expectError(error.NoSuchFunction, dispatch(A, &win, &bad));
}
