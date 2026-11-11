# gtty extensions: reference for AI assistants

Read this before changing the extension system. It covers the whole
design, built or not. **To write an extension, use the SDK's own guide, which lists only what
exists, and its example: [Zig](../sdks/zig/AGENTS.md),
[Python](../sdks/python/AGENTS.md), [JavaScript](../sdks/javascript/AGENTS.md),
[Go](../sdks/go/AGENTS.md).** The wire format is [protocol.md](protocol.md). The
guide for people is [extensions.md](extensions.md).

**Status: partly built.** Working today: `sdks/zig/src/gtty.zig`, the
standard chips in `src/chips/`, the four lifecycle functions, `onEvent`,
`registerEvent`, `unregisterEvent`, `dispatch`, `newText`, `win.ui.set` for
chips, peeks, epeeks and dialogs, `setDisplayMode`, `showDialog`,
`closeDialog`, `win.shell()`, `win.ephemeral`, `win.stateful`, `win.log`,
`ext.log`, installed extensions as child processes (`src/chips/Proc.zig`,
`src/core/Extensions.zig`), the four SDKs, `gtty ext`, the extension
manager (`src/ui/ExtensionsWindow.zig`), and the
events `window_changed`, `command_started`, `key` and `button_click`. Everything
else here (icon files, `windowText`, labels) is design
only: don't tell a user it works, and check
the code before relying on a name. `test/dialog.gt` and `test/peek.gt` with
`src/chips/dialog_test.zig` exercise every layout, widget and button. Items marked `[proposed]` are not decided: use
them, but say so, and don't present them as settled.

## Rules

1. Extensions never draw. They send descriptions; gtty draws.
2. Nothing may block gtty. gtty never waits for an extension, and never
   asks one before closing its dialog.
3. Keep events few. Send final results, never progress (no drag events).
   Before adding an event, check whether a field on an existing one
   covers it.
4. Standard chips (extensions, folder, git, focus, session) use the Zig
   SDK, with no private access to `App`, but run inside the gtty process.
   They can't be disabled. They are the first test of registration and
   event handling.
5. The prompt fires no events.
6. Add no Zig packages to gtty for this. Use the standard library and
   existing dependencies; `.github/deps.toml` must stay unchanged.
7. In user-facing text, write "window", not "job window".

## Lifecycle

```zig
pub fn onGttyStart(ext: *gtty.Extension) !void {}   // once, extension starts
pub fn onWindowStart(win: *gtty.Window) !void {}    // each window: open ones, then new
pub fn onWindowClose(win: *gtty.Window) !void {}    // text already gone
pub fn onGttyClose(ext: *gtty.Extension) !void {}   // notice only, gtty doesn't wait
pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {} // registered events, clicks
```

- All are optional. `onWindowStart` runs many times in one process: key
  per-window state by `win.id`, and free it in `onWindowClose`.
- `onGttyStart` means the extension is starting. gtty may already be
  running, with windows open.
- `onWindowClose` and `onGttyClose` are notices: gtty and the window don't
  wait for them, and gtty may already be gone. Never rely on them to save
  data; save as you go.
- Callbacks run one at a time. Return quickly; do long work on your own
  thread, or events are dropped.
- Zig SDK first. After it works: JavaScript, Python 3, C, Rust, on the same
  messages.

## Connectors

`[proposed names]` `win` is the connection to one window: its calls apply
to that window, and its events come only from it. There is no window id
in the event. `ext` has only `ui`, covering all windows.

- `ui`: `set`, `setDisplayMode`, `showDialog`, `closeDialog`
- `events`: `registerEvent`, `unregisterEvent`

## Events

Register at any time with `win.events.registerEvent(...)`; events aren't in
the manifest. The only events are `window_changed`, `command_started`,
`key` and `button_click` (`EventKind`; clicks need no registering).
`key` (2026-11-11, the user asked for keyboard events): every key pressed
while a window has the keyboard (`App.keyPressed` in `onKey`, after the
modal / dialog / menu checks, not for an epeek filter or the find box;
text joined by `textTyped`, `key_wait`, `flushKey` once a frame), fields
`key` (`App.keyName`), `text`, `ctrl` / `shift` / `alt` / `cmd`. A notice
only, never held back. Not while the PTY is in line mode with echo off
(`gtty_pty_secret`: a password prompt; raw mode, zle / vim / ssh, can't be
told). Counts as the user's, like a click (`Host.pump`'s `from_user`,
`Proc.sendEvent`). **Don't invent event names**; add one only when a chip needs
it and no existing event can carry the case.

```
event {
  header: eventId, element[proposed], windowText, labels
  then the parameters of the element that fired it
}
```

- `eventId`: 32-bit id, 8 hex digits.
- `windowText` and `labels` are handles, not copies: a window can hold
  50 MB. Never put text in the wire message. Read with
  `ev.windowText.read(start, length)`; `ev.windowText.encoding` is
  `"utf-8"`. Offsets are bytes.
- The text is as of the event. It's kept 15 s after the last listener was
  told, and a window's latest event is always kept. After that a read
  returns an error: handle it, and don't treat it as empty text.

## Commands

| Call | Effect |
|---|---|
| `win.ui.set(.{ .chip = … })` | Update this window's chip |
| `win.ui.set(.{ .peek = … })` | Update this window's peek |
| `win.ui.set(.{ .epeek = … })` | Update this window's epeek |
| `win.ui.setDisplayMode(.chip)` | Show the chip, peek or epeek (`.chip`, `.peek`, `.epeek`); `.chip` closes the peek or epeek |
| `win.ui.set(.{ .dialog = … })` | Set the dialog, or update it while open |
| `win.ui.showDialog()` | Show the dialog |
| `win.ui.closeDialog()` | Close the dialog |
| `ext.ui.set(…)` `[proposed]` | Same as `win.ui.set`, in every window |

The wire form is JSON with the element as the top key:
`{"chip": {"text": "main"}}`. YAML is undecided; emit JSON.

Updates are partial: sent field changes, omitted field stays, `null`
clears. `lines`, `buttons` and `options` are replaced whole.

## UI shape

An extension sets up its UI in `onWindowStart`, or has none. A UI must
have a chip; peek and epeek are optional. "Epeek" is the word for the
expanded peek: the list that opens from a peek.

Chip alone: a click opens nothing. Chip + peek: the peek. Chip + epeek: the
epeek. All three: the peek, and its expand opens the epeek. A peek or epeek
with no chip is refused (`error.NoChip`). Hover opens nothing by itself:
call `setDisplayMode` in `onhover`, or in `onclick` to fill it right before
it opens. One is open at a time: an extension opening its own, not from a
user's click or hover, doesn't replace another's and gets no keyboard.

gtty only reports a click on an epeek item. The extension closes the list
with `setDisplayMode(.chip)`. There is no `closePeek`.

## Schemas

Use these exact keys, including the camelCase ones (`prefixButton`,
`postButton`, `epeek`).

```
text   [ part ]            every text an extension sets is this list:
                           chips, peeks, epeeks, buttons, dialog titles
                           and labels. Typed values stay plain strings.
       helper: gtty.newText("main")
               gtty.newText(.{ "main", .{ .bold = true } })
               gtty.newText(.{ .{ "a", .{} }, .{ "b", .{ .bold = true } } })
part   { string, fg?, bk?, size?, bold?, stroke? }
       stroke bool = a line through the text
       gtty's text draw function goes over the parts and draws each with
       its own attributes; extensions never draw. An attribute left out
       comes from gtty's default for that text.
       At most 8 parts. Colors "#rrggbb" (Zig 0xrrggbb); size in percent of
       the normal size, kept to 50-200. Text coming back in events is the
       plain string. [proposed] in JSON a plain string is one part.

chip   { text, icon?[proposed], dimmed?,
         onclick?, onhover?, data? }

button { id?, icon?, text?, onclick?, data? }
       no onclick = a plain icon, not clickable

action button (postButton only; drawn as three dots, no icon)
       { dots: "vertical", onclick, items: [{ id, text, data }] }
           popup list of the texts; a pick = button click with the
           item's id, text, data and this onclick
       { dots: "horizontal", id?, onclick, data? }
           plain click; the extension decides, usually a dialog

line   { id?, prefixButton?: button|null, text,
         postButton?: button|action button|null,
         onclick?, onhover?, data? }

peek   = line + expand?: bool, hoverExpand?: bool, onexpand?
       order: prefixButton, expand, text, postButton, ×
       expand shows the expand button; gtty handles it and opens
       epeek. gtty always draws × at the far right. Lines in an
       epeek have neither.

epeek { frame?: frame|null, lines: [line], selected?, empty?, footer?,
        state?: "idle"|"busy"|"ok"|"err", message?: [text] }
       opens over the peek or chip and hides it, as peeks do today; lines
       required

frame  { left?: [button], filter?: filter|null, right?: [button],
         text?, onclick?, onhover?, data? }
       filter sits in its own row under the frame
       left and right hold at most 2 buttons each; gtty adds its close
       button after right. No frame: Esc or a click outside closes.

filter { text?, hint?, options?: [string], onclick }
       options = the help list of possible strings, in rows under the box;
       Tab takes the first, up / down always move in the list

`state`: busy, then ok or err with `message`. ok closes after a second.

dialog { title, layout, columns?, rows?, fields: [widget], buttons,
         onclick?, timeout?, error?[proposed] }
       layout:  "form" | "grid" | "table" (columns and rows only for table)
       buttons: "ok" | "okcancel" | "yesno"

widget { id, type, label, value?, options?, filter? }
       type "text":     value string
       type "checkbox": value bool
       type "dropdown": value string, options [string], filter bool
       type "label":    no value [proposed]
```

**Icon** = a standard icon name, or a plain file name in the root of the
extension's folder. Refuse `/` and `..`. PNG only `[proposed]`. Standard
names so far: `copy`, `save`, `list`, `dot`. Icon files aren't built. Don't
invent names.

## Clicks

A button with `onclick`, and any dialog button, reaches `onEvent` as one
event, only in the extension that owns it. It needs no registration.

```
ev.button { id, text, data, function, fields, command }
read with b.field("name"), b.checked("keep"), b.is("ok")
```

- A pick in a ⋮ popup and a ⋯ click are button clicks too. In Zig `items`
  is a slice: `.items = &[_]gtty.Item{ … }` or a named array.
- Clicking or hovering over a chip's text, the peek's text or an epeek
  item's text sends an event when `onclick` / `onhover` names a function.
  Both are button clicks (`function` tells them apart); a hover fires once
  after a 0.5 s rest, never while moving, and nothing fires on leaving.
- A filter change is also a button click: `id` `filter`, `text` the box's
  text, `function` the filter's `onclick`. It fires on every change, and
  changes waiting in the queue merge into the latest. Closing with text in
  the box fires one more, with empty text.
- gtty doesn't filter `lines`: the extension decides. It can drop items,
  draw the matching items differently, change `options`, or do nothing.
- `function` is the `onclick` string. gtty never runs it; the extension's
  central on-click calls it.
- Put what the handler needs in `data`, so it needs no lookup.
- In Zig call `gtty.dispatch(Actions, win, ev)` in `onEvent`, when
  `ev.kind == .button_click`, with one `pub fn`
  per `onclick` name in `Actions`.

## Dialog behavior

- Centered in its window, one at a time (others wait), modal to that window
  only. It takes the keyboard only while handling a user's click; otherwise
  it opens without it until clicked.
- Buttons only report: `ok`, `cancel`, `yes`, `no` send a button click
  and the dialog stays open.
- **The extension must call `win.ui.closeDialog()`**, for `cancel` and `no`
  too. Forgetting this leaves the dialog open until its timeout.
- To reject input, don't close: update it with `error`.
- Values arrive only in `fields` on a button click. Typing sends nothing.
- × is a kill, and so is the window closing. A timeout kills too. All
  three close the dialog at once and discard its values.

| `id` | From | `fields` | Closed by |
|---|---|---|---|
| `ok`, `yes` | Button, Enter | yes | Extension |
| `cancel`, `no` | Button, Esc | yes | Extension |
| `kill` | ×, window closing | no | gtty, already done |
| `timeout` | Timer | no | gtty, already done |

Never call `closeDialog` after `kill` or `timeout`, and never treat
either as a cancel the user chose.

## Template

[sdks/zig/examples/hosts.zig](../sdks/zig/examples/hosts.zig), compiled by the
SDK's `zig build test`.

## Processes and developer tools

Third-party extensions run as separate programs (decided, built). At run
time each is a **child process of gtty**, so it ends when that gtty closes
(the SDKs exit when the socket closes; Linux also PR_SET_PDEATHSIG). In
development the IDE starts it under its debugger and it connects to gtty;
it isn't gtty's child then (built 2026-11-11, docs/protocol.md
"Development").

- gtty side: `Extensions.scan` (once a second, `App.tickExtensions`) →
  `Host.syncInstalled` → `Proc.start` (`gtty_ext_spawn`: socket on fd 3,
  stdout / stderr to the log). `Host.procLine` turns messages into the same
  `Sink` calls the standard chips make; `sdk.wire` decodes them, the Zig SDK
  encodes with it. One chip slot per running extension (`Host.max_chips`).
- Calls that answer (`shell`, storage) are request / reply; waiting
  opens retry each frame until their timeout (`Host.waiting`), gtty never
  blocks. `from_user` for a mode / dialog comes from the `ev` it cites
  (`Proc.fromUser`, a user's click in the last 5 s).
- `gtty ext install | uninstall | enable | disable | list | logs`
  (`src/core/ExtCli.zig`); `logs` reads `<tmp>/ext.log`.
- Developer socket (`src/chips/DevSocket.zig`; `gtty_ext_listen` /
  `gtty_ext_accept` in `src/sys/gtty_ext.c`, this user's processes only):
  each gtty on `<tmp>/ext.sock`, the newest also at the shared
  `$TMPDIR/gtty-dev-<uid>/ext.sock` (a link; not in `--script` runs; taken
  back by another gtty once a second, `Host.tickDev`). `Host.acceptDev` →
  `Proc.accept` (state `attaching`, `dev`) → the first line `attach`
  (`Host.attach` / `attachAs`: name or the manifest in `dir`, else
  `refused`) → `greet`. The installed copy stops (`Proc.replaced`) and
  starts again when the debugged one ends (`Host.rescan` → App runs
  `syncInstalled`). Never signalled or reaped (`Proc.reap`'s dev branch).
  Wider limits: `Proc.dev_max_out`, `dev_user_click_ms`,
  `ExtStorage.dev_hold_ms` (`setDev`). `gtty ext socket [--pid N]`.
  The SDKs: no `GTTY_EXT_FD` → `GTTY_EXT_SOCKET` or the shared address
  (folder checked: this user's, 0700), send `attach`, exit 1 on `refused`;
  the conformance check covers it (`dev_check`).
- A new language: implement docs/protocol.md with its standard library,
  port `examples/hosts`, pass `sdks/conformance/fake_gtty.py`, add it to
  `ci.yml`'s `sdks` job and `release.yml`'s list.

## Packaging

A folder, zip, tar or tar.gz with `manifest.json`: `name`, `main` (a
string or a map by platform), `runtime` (`python3` / `node`), `version`,
`description`. gtty unpacks it into `<extensions>/<name>/code/` (no links,
nothing outside); the manager asks before installing. See
docs/extensions.md "Packaging" and "Installing".

## Not decided

Don't settle these on your own; ask the user. The proposal is what
`docs/extensions.md` shows.

- YAML as well as JSON
- Chip icons from the package
- The event list, and how `labels` are read
- Ending an extension left running after gtty closed
