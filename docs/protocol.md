# gtty extension protocol

How gtty and an extension running as its own program talk. The SDKs
(`sdks/<language>/`) implement it, so extension authors never see it. Read
it to write or fix an SDK.

**Version 1.** gtty sends it in `hello`; an SDK that speaks another version
exits with a message on stderr.

## Transport

- gtty starts the extension as a **child process**, in its install folder,
  with a connected Unix stream socket on file descriptor 3 and the
  environment variables `GTTY_EXT_FD=3`, `GTTY_EXT_NAME` (its name) and
  `GTTY_EXT_DIR` (its folder). Its stdout and stderr go to `gtty ext logs`
  (info and err lines).
- No `GTTY_EXT_FD`: the extension was started by hand or by an IDE's
  debugger. It connects to gtty's developer socket and says `attach` first
  (see "Development").
- Messages are **JSON objects, one per line** (UTF-8, `\n` after each, no
  line breaks inside). The key `t` names the message.
- When the socket closes (gtty quit or crashed), the extension must exit.
  The SDKs do.
- gtty never waits for an extension. It reads and writes without blocking,
  once a frame. If the extension stops reading, events for it are dropped
  (logged).

## gtty → extension

| `t` | Fields | SDK calls |
|---|---|---|
| `hello` | `api` (1), `name` | (checks the version) |
| `gttyStart` | | `onGttyStart(ext)` |
| `windowStart` | `win` | `onWindowStart(win)`: a new window connection |
| `windowClose` | `win` | `onWindowClose(win)`, then the connection is gone |
| `event` | `win`, `event` | `onEvent(win, event)` |
| `reply` | `id`, `value` or `error` | the answer to a `call` |
| `gttyClose` | | `onGttyClose(ext)`, then exit |

`win` is the window's id (a number). `event` is an Event:

```json
{"eventId": 7, "kind": "window_changed", "folder": "/src/app", "branch": "main", "remote": false}
{"eventId": 8, "kind": "command_started", "folder": "/src/app", "command": "make test"}
{"eventId": 10, "kind": "key", "key": "a", "text": "A", "shift": true}
{"eventId": 9, "kind": "button_click", "button": {"id": "ok", "text": "OK", "data": "row-2",
  "function": "add", "fields": [{"id": "name", "value": "alpha"}, {"id": "keep", "value": true}],
  "command": false}}
```

Fields at their default (`""`, `false`, `[]`) are left out.

## Extension → gtty

Messages that change something get no answer. gtty logs an error in one
(a peek with no chip, a bad field) under the extension's name.

| `t` | Fields |
|---|---|
| `set` | `win`, and one of `chip`, `peek`, `epeek`, `dialog` (an update; `peek` / `epeek` `null` removes it) |
| `mode` | `win`, `mode`: `chip`, `peek` or `epeek`; `ev` |
| `showDialog` | `win`, `ev` |
| `closeDialog` | `win` |
| `register` / `unregister` | `win`, `event`: `window_changed`, `command_started` or `key` |
| `log` | `win` (0: no window), `level`: `debug`, `info`, `warn`, `err`; `message` |
| `call` | `id` (a number the extension picks), `win`, `op`, and the op's fields |

`ev` is the `eventId` of the event being handled, or 0. A peek, epeek or
dialog opened while handling the user's click gets the keyboard; gtty
knows which clicks were the user's, so send the id of the event you are
handling.

### Calls

Each `call` gets one `reply` with the same `id`: `value`, or `error` (one
of the SDK's error names: `WindowClosed`, `NoChip`, `BadName`, `NoFile`,
`FileInUse`, `FileClosed`, `StorageFull`, `StorageFailed`). Events can
arrive before the reply; the SDK keeps them and hands them out after the
call returns.

| `op` | Fields | `value` |
|---|---|---|
| `shell` | | the shell's name |
| `open` | `storage` (`ephemeral` / `stateful`), `name`, `mode` (`read` / `write`), `timeout` (ms) | a handle (number) |
| `read` | `handle`, `max` (bytes) | base64 of up to `max` bytes; `""` at the end |
| `write` | `handle`, `data` (base64) | `true` |
| `close` | `handle` | `true` |
| `delete` | `storage`, `name`, `timeout` | `true` |
| `list` | `storage` | a list of names |

gtty answers a waiting `open` or `delete` when the file is free or the
timeout passed (`FileInUse`); it never blocks for it.

## Updates

The updates are the SDK's `ChipUpdate`, `PeekUpdate`, `EpeekUpdate` and
`DialogUpdate` in JSON (`sdks/zig/src/wire.zig` is the reference):

- A field left out stays as it is; `null` clears it.
- A text is a string, or a list of parts: `{"string": "main", "fg":
  "#e0b040", "bk": "#202020", "size": 120, "bold": true, "stroke": true}`
  (8 parts at most; size in percent, 50-200).
- Enums are their names (`"vertical"`, `"busy"`, `"okcancel"`).
- A frame's `left` and `right` are lists of at most 2 buttons.
- A dialog widget's `value` is a string or a bool; the dialog's error line
  is `"error"`.

```json
{"t": "set", "win": 3, "chip": {"text": "hosts", "onhover": "open"}}
{"t": "set", "win": 3, "peek": {"expand": true, "text": [{"string": "3 hosts", "bold": true}]}}
{"t": "set", "win": 3, "epeek": {"frame": {"text": "hosts", "filter": {"hint": "filter", "onclick": "filter"}},
  "lines": [{"id": "a", "text": "alpha", "onclick": "pick", "data": "alpha"}]}}
{"t": "set", "win": 3, "dialog": {"title": "Add a host", "layout": "form", "buttons": "okcancel",
  "fields": [{"id": "name", "type": "text", "label": "Name"}], "onclick": "add", "timeout": 60}}
{"t": "mode", "win": 3, "mode": "epeek", "ev": 9}
{"t": "call", "id": 1, "win": 3, "op": "open", "storage": "stateful", "name": "hosts", "mode": "read", "timeout": 200}
```

## Order

1. gtty: `hello`, `gttyStart`, then `windowStart` for every open window.
2. Then events, replies and new windows as they come.
3. On quitting: `gttyClose`, then gtty closes the socket. An extension still
   running a second later is ended (SIGTERM, then SIGKILL).

## Development

An extension an IDE started (no `GTTY_EXT_FD`) connects to a Unix socket
gtty listens on:

- `GTTY_EXT_SOCKET=<path>` when set, else the newest gtty's shared address
  `$TMPDIR/gtty-dev-<uid>/ext.sock` (`$TMPDIR` unset: `/tmp`; its trailing
  `/` dropped). The SDK uses that one only when the folder is a folder of
  this user with no group or other permissions.
- Each gtty listens on `<its temp folder>/ext.sock`; the newest gtty points
  the shared address (a link) at its own, and another one running takes it
  back once a second after that gtty closes. A gtty run with `--script`
  doesn't take it. `gtty ext socket [--pid N]` prints a gtty's own path.
- gtty accepts only this user's processes (peer credentials).

The extension's first message:

```json
{"t": "attach", "api": 1, "name": "hosts", "dir": "/src/hosts"}
```

`name` may be empty: gtty reads it from `dir`'s `manifest.json` (the
SDKs send `GTTY_EXT_NAME` and the folder they run in). gtty answers with
`hello` and the conversation goes on as for a child process, or with
`{"t": "refused", "reason": "…"}` and closes: the SDK prints the reason on
stderr and exits with 1. Refused: no `attach` within 10 s, another `api`,
a name not valid or reserved, the same extension already attached, no free
chip.

Attached, it is the extension of that name in this gtty: a running
installed copy stops (`gttyClose`) and starts again once the attached one's
socket closes. Its storage is the installed one's. Being under a debugger,
its limits are wider: 64 MB of events wait for it (4 MB otherwise), a
click counts as the user's for `mode` / `showDialog` for 10 minutes (5 s),
its files stay open up to 30 minutes (30 s). gtty never signals it: at
`gttyClose` it waits up to 3 s for the socket to close, then closes it.
