# gtty extensions in Zig: guide for AI assistants

Read all of this before writing an extension. It lists only what exists in
this SDK. `src/gtty.zig` is the truth; `examples/hosts.zig` is a complete,
compiling extension, so start from a copy of it (and of
`examples/manifest.json`).

**Requires** Zig 0.16. Std APIs changed a lot in 0.15 / 0.16: don't trust
older examples.

## Status: tell the user this

- An extension is its **own program**: `main` calls `gtty.run(@This())`.
  gtty starts it as its child process when it starts (and stops it when
  gtty closes), with a socket on fd 3. Started by hand or by your
  IDE's debugger while gtty runs, it connects to that gtty instead: see
  "Debug".
- It needs libc (`.link_libc = true`), as the example's build does.
- One process serves every window of one gtty: `onWindowStart` runs once
  per window, `win.id` tells them apart.
- Installed with `gtty ext install <folder | .zip | .tar.gz>` or the
  extension manager (gtty ▸ Extensions…); see "Package and run".
- Not in this SDK, don't call them: `ev.windowText`, labels, `ext.ui`,
  chip `icon`, icon files, objects, selection events, mouse events.

## Rules

1. Extensions never draw. They describe; gtty draws.
2. Return quickly from callbacks. They run one at a time; while one runs
   your extension gets nothing else, and gtty drops events it can't send
   you (logged). gtty itself never waits for you. For slow work (network,
   big files) use your own thread and keep its results for the next event.
3. Call `win.ui`, `win.events`, storage and `win.shell()` only from a
   callback, not from your own thread. `log` works anywhere.
4. Don't invent events or fields. If it isn't here, it doesn't exist. Say
   so to the user.
5. In text the user reads, write "window", never "job window".

## Shape of an extension

A Zig file with any of these `pub fn`s. All are optional.

```zig
pub fn onGttyStart(ext: *gtty.Extension) !void {}  // once
pub fn onWindowStart(win: *gtty.Window) !void {}   // each window
pub fn onWindowClose(win: *gtty.Window) !void {}   // notice, see below
pub fn onGttyClose(ext: *gtty.Extension) !void {}  // notice, nobody waits
pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {}
```

- `onWindowStart` runs once per window in the same process: keep state by
  `win.id`, free it in `onWindowClose`.
- An **instance** is your extension in one window. `win` is that connection.
- In `onWindowClose` the connection is already closed: every `win` call
  returns `error.WindowClosed`. Only free your own memory there.
- Never rely on the close functions to save data. Save as you go.

## UI

Set it up in `onWindowStart`, or have none. **A UI needs a chip**; peek and
epeek are optional. A peek or epeek with no chip returns `error.NoChip`, so
set the chip first.

| Set | A click on the chip |
|---|---|
| chip | Opens nothing |
| chip, peek | Opens the peek |
| chip, epeek | Opens the epeek |
| chip, peek, epeek | Opens the peek; its expand button opens the epeek |

- **Chip:** the short text in the window's footer.
- **Peek:** one line over the chip: `[prefixButton] [expand] text [postButton] [×]`.
- **Epeek:** the list that opens over the peek or chip, hiding it.

Hover opens nothing by itself: call `setDisplayMode` from `onhover`.

```zig
try win.ui.setDisplayMode(.peek);  // or .epeek
try win.ui.setDisplayMode(.chip);  // closes your peek or epeek
```

gtty only reports clicks, so close the list yourself after a pick. Only one
is open at a time. If you open yours while not handling the user's click or
hover, it won't replace another one and gets no keyboard.

### `win.ui.set`

A field left out stays, `null` clears it, and everything is copied, so your
buffers can go right after the call.

```zig
try win.ui.set(.{ .chip = .{ .text = "main", .dimmed = false, .onclick = "a", .onhover = "b", .data = "x" } });
try win.ui.set(.{ .chip = .{ .text = null } }); // no text: not shown
try win.ui.set(.{ .peek = .{ .expand = true, .hoverExpand = false, .onexpand = "load",
    .text = "full text", .onclick = "a", .onhover = "b", .data = "x",
    .prefixButton = .{ .icon = "copy", .onclick = "copy" },
    .postButton = .{ .dots = "horizontal", .onclick = "more" } } });
try win.ui.set(.{ .peek = null }); // removes it
try win.ui.set(.{ .epeek = .{ .lines = .{ .{ .text = "one" }, .{ .text = "two" } } } });
```

For a list built at run time use the typed form, as in the example:

```zig
try win.ui.set(.{ .epeek = gtty.EpeekUpdate{
    .frame = .{ .set = frame },       // gtty.Frame
    .lines = .{ .set = rows[0..n] },  // []const gtty.Line
    .selected = .{ .set = 0 },
    .empty = .{ .set = gtty.newText("nothing here") },
} });
```

`gtty.Field(T)` is `.keep`, `.clear` or `.set`.

| Type | Fields |
|---|---|
| `Button` | `id`, `icon`, `text`, `onclick`, `data`, `dots`, `items` |
| `Item` | `id`, `text`, `data` |
| `Line` | `id`, `prefixButton`, `text`, `postButton`, `onclick`, `onhover`, `data` |
| `Peek` | `expand`, `hoverExpand`, `onexpand`, then as `Line` without `id` |
| `Frame` | `left`, `right` (`[2]?Button` each), `text`, `onclick`, `onhover`, `data`, `filter` |
| `Filter` | `text`, `hint`, `options`, `onclick` |
| `Epeek` | `frame`, `lines`, `selected`, `empty`, `footer`, `state`, `message` |

- **Button:** with no `onclick` and no `dots`, it's only an icon. Icons:
  `copy`, `save`, `list`, `dot`. An unknown name draws nothing.
- **Dots** (`postButton` only): `.vertical` shows `items` in a popup, and a
  pick is a click with that item's `id`, `text`, `data` and the button's
  `onclick`. `.horizontal` is a plain click. `items` must be a slice
  (`&row_menu`), not a tuple.
- **Frame:** gtty adds the × after `right`. No frame: a plain list, with no
  filter; Esc or a click outside closes it.
- **Filter:** gtty doesn't filter. Every change is a click with `id`
  `filter` and the box's text in `text`; answer with new `lines`. Closing
  with text in the box sends one more, with empty text: keep your own
  filter state from these. `options` are offered under the box, and Tab
  takes the first.
- **State:** `.idle`, `.busy`, `.ok`, `.err`, with `message` (`[]const Text`,
  one row each). `.ok` closes the epeek after a second.
- After `lines` change, `selected` applies again, so send it with them.

### Text

Every text you set is a list of up to 8 parts, each with its own look.

```zig
gtty.newText("main")
gtty.newText(.{ "main", .{ .bold = true } })
gtty.newText(.{ .{ "feature/", .{} }, .{ "login", .{ .fg = 0x202020, .bk = 0xe0b040 } } })
gtty.newText(parts_slice) // []const gtty.TextPart, built at run time
```

Attributes: `fg`, `bk` (`0xrrggbb`), `size` (percent, kept to 50-200),
`bold`, `stroke` (a line through the text). Left out: gtty's default.

A plain string works in the anonymous form of `win.ui.set` and in dialogs.
**A typed `gtty.Line`, `Button` or `Frame` needs `newText`**. `newText`
doesn't copy strings, so they must live until `set` is called.

## Events

```zig
try win.events.registerEvent(.window_changed);
try win.events.unregisterEvent(.window_changed);
```

| `ev.kind` | When | Fields |
|---|---|---|
| `.window_changed` | At the start, then when something changed | `folder`, `branch`, `remote` |
| `.command_started` | A command starts in the window's shell | `command`, `folder`, `remote` |
| `.key` | A key pressed while the window has the keyboard | `key`, `text`, `ctrl`, `shift`, `alt`, `cmd` |
| `.button_click` | Your click, hover or filter; never register it | `button` |

Also `ev.eventId`. Strings last until the handler returns: copy what you
keep. `branch` is empty outside a repo. With `remote` true, `folder` is the
local one.

### Keys

```zig
try win.events.registerEvent(.key);
```

```zig
.key => if (std.mem.eql(u8, ev.key, "f6") and !(ev.ctrl or ev.shift or ev.alt or ev.cmd))
    try win.ui.setDisplayMode(.epeek),
```

- `key`: the key's name. The character on it, unshifted (`a`, `1`,
  `/`), or `enter`, `escape`, `tab`, `backspace`, `delete`, `space`,
  `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`,
  `insert`, `f1` to `f24`; another key: the system's name, lowercase,
  no blanks. Empty for text from an input method, with no key.
- `text`: what the key typed (`A` with Shift, `é`); empty for keys that
  type nothing (arrows, Ctrl+C).
- `ctrl`, `shift`, `alt`, `cmd`: the modifier keys held. `cmd` is ⌘ on macOS,
  the Super (Windows) key on Linux. Modifier keys alone send nothing.
- A notice only: the key still goes where it went (the program, or gtty's
  own shortcut, ⌘C for example). You can't hold it back.
- Not sent while the terminal hides what is typed (a password prompt),
  nor while a gtty dialog, menu, epeek filter or the find box has the
  keyboard. A password asked on a remote host (ssh) can't be told apart:
  never keep or send what you get.
- A key counts as the user's, like a click: a peek or dialog you open for
  it gets the keyboard.
- Keys come fast: do little per key. Events wait in a queue; when you fall
  behind, gtty drops some (logged).

## Clicks

Every `onclick`, `onhover` and `onexpand` is a function name. They all arrive
as `.button_click`:

```zig
const Actions = struct {
    pub fn saveIt(win: *gtty.Window, b: gtty.ButtonClick) !void {}
};

pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {
    if (ev.kind == .button_click) try gtty.dispatch(Actions, win, ev);
}
```

- `dispatch` needs a `pub fn` for every name you used, or it returns
  `error.NoSuchFunction`.
- `ButtonClick`: `id`, `text` (plain), `data`, `function`, `command` (⌘, Linux
  Ctrl), `field("id")`, `checked("id")`, `is("id")`.
- Put what the handler needs in `data`, so it needs no lookup.
- A hover fires once after a 0.5 s rest, never on leaving. A hover on chip
  text needs `.onhover`, and the same for lines.

## Dialogs

```zig
try win.ui.set(.{ .dialog = .{
    .title = "Add a host",
    .layout = "form",        // "form", "grid", "table" (+ .columns, .rows)
    .timeout = 30,           // seconds, at most 600
    .buttons = "okcancel",   // "ok", "okcancel", "yesno"
    .onclick = "addHost",
    .fields = .{
        .{ .id = "host", .type = "text", .label = "Host", .value = "" },
        .{ .id = "pin", .type = "checkbox", .label = "Pin", .value = false },
        .{ .id = "kind", .type = "dropdown", .label = "Kind", .value = "ssh", .options = kinds, .filter = true },
        .{ .id = "hint", .type = "label", .label = "Plain text" },
    },
} });
try win.ui.showDialog();
```

- A wrong `layout`, `buttons` or `type` name returns `error.BadDialog`.
- One dialog at a time per window, and the rest wait. It's modal to its
  window only.
- **Buttons only report. You must call `win.ui.closeDialog()`**, for cancel
  and no too, or it stays until its timeout.
- To reject input, keep it open:
  `win.ui.set(.{ .dialog = .{ .@"error" = "enter a host" } })`.

| `b.id` | From | Values | Closed by |
|---|---|---|---|
| `ok`, `yes` | Button, Enter | yes | You |
| `cancel`, `no` | Button, Esc | yes | You |
| `kill` | ×, the window closing | no | gtty, already |
| `timeout` | The timer | no | gtty, already |

Never call `closeDialog` after `kill` or `timeout`, and don't treat them as a
cancel the user chose. An open epeek stays open under a dialog: to avoid two
things looking active, call `setDisplayMode(.chip)` first.

## Storage

`win.ephemeral`: this instance's files, deleted when its window closes.
`win.stateful`: the extension's files, shared by all instances in all gttys.

```zig
const f = try win.stateful.openWrite("hosts.json", 500); // waits up to 500 ms
errdefer f.close() catch {};
try f.write(text);
try f.close();

const r = win.stateful.openRead("hosts.json", 500) catch |e| switch (e) {
    error.NoFile => return, // nothing saved yet: normal the first time
    else => return e,
};
defer r.close() catch {};
const n = try r.read(&buf); // 0 at the end; loop for big files

try win.stateful.delete("old.json", 500);
const names = try win.stateful.list(&buf); // one name per line
```

- **`openWrite` replaces the whole file, at `close`.** To add to it, read it
  first and write it all back. There's no append and no seek.
- Without `close` the write is lost: the old file stays.
- While a file is open for writing nobody else can use it. Several can read.
  **Always close quickly**: gtty closes a file after 30 s and drops its
  write, and the next call returns `error.FileClosed`.
- A timeout of 0 tries once; with a timeout the call waits up to that long
  while another instance (or another gtty) has the file, then returns
  `error.FileInUse`. Keep timeouts short (a few hundred ms): the callback
  waits meanwhile. Handle `error.FileInUse`: try later, or tell the user.
- Names are plain file names: no `/`, no `..`, no leading `.`. No subfolders.
- A storage holds 100 MB by default (the user's setting). Past it:
  `error.StorageFull`.
- Uninstalling deletes stateful data. If users may want theirs, offer an
  export from your peek or a dialog.

## Shell

```zig
const name = try win.shell(); // valid until the next call
```

The name of the shell in front, such as `bash` inside `zsh`, or any shell the
system lists. If something else is in front, such as `vim`, it's the window's
own shell.

## Logs

```zig
win.log(.info, "host {s} added", .{name});  // with this window's id
ext.log(.warn, "no config", .{});           // in onGttyStart, onGttyClose
```

Levels: `.debug`, `.info`, `.warn`, `.err`. `log` never fails, a message over
1024 bytes is cut, and it works from your own threads and in `onWindowClose`.
Don't log passwords or file contents: the lines stay in a file until gtty
closes.

Read them while gtty runs:

```sh
gtty ext logs -f yourname   # follow one extension, until gtty closes
gtty ext logs               # what is there now, every extension
gtty ext logs --pid 4242    # another gtty (default: the one logged to last)
```

A line reads `time level extension window message`, with `-` for no window.
gtty adds its own: `onEvent returned SomeError` under your extension's name,
and `N events dropped` under `gtty`. When something doesn't work, read these
first. Line breaks and control characters in a message are shown escaped
(`\n`, `\x1b`).

## Errors

`gtty.Error`: `WindowClosed`, `NoDialog`, `BadDialog`, `NoChip`, `BadName`,
`NoFile`, `FileInUse`, `FileClosed`, `StorageFull`, `StorageFailed`.

- `win.ui.*` and `win.events.*` don't wait for gtty: a mistake gtty finds
  (a peek with no chip: `set: NoChip`) is a line in `gtty ext logs`, not an
  error here. `BadDialog` for a wrong name is still returned.
- Storage and `win.shell()` wait for gtty's answer and return its error.
- An error returned from a callback goes to `gtty ext logs`, and the user
  sees nothing: report what matters in the UI.

## Package and run

A package is a folder (or a `.zip` / `.tar.gz` of one) with
`manifest.json` at its top:

```json
{
  "name": "hosts",
  "version": "1.0.0",
  "description": "A chip that keeps a list of hosts",
  "main": {
    "macos-aarch64": "bin/hosts-macos-aarch64",
    "linux-x86_64": "bin/hosts-linux-x86_64"
  }
}
```

- `name`: lowercase letters, digits, `-`, `_`, starting with a letter, 32 at
  most; not `folder`, `git`, `focus`, `session`, `test`, `gtty`,
  `extensions`. It names the storage and the log lines.
- `main`: the program, relative to the package; one string, or one per
  platform (`macos-aarch64`, `linux-x86_64`). Build each with
  `zig build -Dtarget=aarch64-macos` / `-Dtarget=x86_64-linux-gnu`.
- No links, no files outside the package: gtty refuses such a package.

```sh
gtty ext install ./hosts-pkg   # install, or update (data kept)
gtty ext list                  # name, version, on / off
gtty ext logs -f hosts         # its log, while gtty runs
gtty ext disable hosts         # enable hosts, uninstall hosts (data too)
```

Every running gtty starts it within a second, and restarts it when it is
installed again: the loop is build, `gtty ext install`, read the logs.

## Debug

Run the extension from your IDE's debugger (or `zig build && ./zig-out/bin/hosts`) while gtty
runs: breakpoints, stepping and variables work as in any program. With no
`GTTY_EXT_FD` (gtty didn't start it) the SDK connects to the newest gtty and
says which extension it is: `GTTY_EXT_NAME`, else the `name` in the
`manifest.json` of the folder it runs in (so run it there). Then:

- Its chip shows in every window of that gtty, as if installed. An installed
  copy of the same name stops while it runs and starts again when it ends.
- stdout and stderr go to the IDE's console; `log(...)` lines still go to
  `gtty ext logs`.
- A breakpoint stops only the extension; gtty goes on. While it is stopped
  gtty keeps up to 64 MB of events for it, a dialog it opens within 10
  minutes of the user's click still gets the keyboard, and its files stay
  open up to 30 minutes.
- Stopping the debugger ends the program: its chip goes.
- gtty refuses it (the reason on stderr, exit code 1) when the name is not
  valid or is gtty's own, or that extension is already being debugged in
  that gtty. No gtty running: a message and a non-zero exit code.
- Another gtty: `GTTY_EXT_SOCKET=$(gtty ext socket --pid N)`; `gtty ext
  socket` prints the newest one's address.

VS Code, `.vscode/launch.json` in the package folder:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "gtty extension",
      "type": "lldb",
      "request": "launch",
      "program": "${workspaceFolder}/zig-out/bin/hosts",
      "cwd": "${workspaceFolder}",
      "preLaunchTask": "zig build"
    }
  ]
}
```

That is VS Code with CodeLLDB; `preLaunchTask` names a shell task that runs `zig build`. Without an IDE: `lldb zig-out/bin/hosts`, `breakpoint set -f hosts.zig -l 26`, `run`. Build in Debug mode (the default), so lines and variables are known.

To debug the installed copy instead, attach to its pid (the extension
manager and `gtty ext logs` show it); its start has already run by then.

## Check your work

```sh
zig build test                                  # your tests, the SDK's
zig build && python3 conformance/fake_gtty.py -- zig-out/bin/hosts
```

`conformance/fake_gtty.py` is a stand-in for gtty that runs the hosts
example through one conversation: adapt its checks to your extension, or
run it with `--verbose` to see every message. Add `test` blocks for your
own logic, and make sure every name in `onclick`, `onhover` and `onexpand`
has a `pub fn` in `Actions`: the compiler can't check strings.
