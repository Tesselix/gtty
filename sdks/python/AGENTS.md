# gtty extensions in Python: guide for AI assistants

Read all of this before writing an extension. It lists only what exists in
this SDK. `gtty.py` is the truth; `examples/hosts.py` is a complete,
working extension, so start from a copy of it, `gtty.py` and
`examples/manifest.json`.

**Requires** Python 3.8 or later, standard library only. No pip packages:
copy `gtty.py` into your extension's folder.

## Status: tell the user this

- An extension is its **own program**. gtty starts it as its child process
  (with a socket on fd 3) and stops it when gtty closes. Started by hand or by your
  IDE's debugger while gtty runs, it connects to that gtty instead: see
  "Debug".
- One process serves every window of one gtty: `on_window_start` runs once
  per window, `win.id` tells them apart.
- Installed with `gtty ext install <folder | .zip | .tar.gz>` or the
  extension manager (gtty ▸ Extensions…); see "Package and run".
- Not in this SDK, don't call them: window text, labels, chip icons, icon
  files, objects, selection events, mouse events.

## Rules

1. Extensions never draw. They describe; gtty draws.
2. Return quickly from callbacks. They run one at a time; while one runs
   your extension gets nothing else, and gtty drops events it can't send
   you (logged). For slow work (network, big files) use a thread and keep
   its results for the next event.
3. Call `win.ui`, `win.events`, storage and `win.shell()` only from a
   callback, not from your own thread. `log` works anywhere.
4. Don't invent events, keys or values. If it isn't here, it doesn't exist.
   Say so to the user. A wrong key is a line in `gtty ext logs`, not an
   exception.
5. In text the user reads, write "window", never "job window".

## Shape of an extension

```python
import gtty

def on_gtty_start(ext): ...       # once
def on_window_start(win): ...     # each window: the open ones, then new ones
def on_window_close(win): ...     # a notice: win calls raise WindowClosed
def on_gtty_close(ext): ...       # a notice: nobody waits
def on_event(win, ev): ...        # registered events and clicks

if __name__ == "__main__":
    gtty.run(globals())
```

- All are optional. Keep state by `win.id`, drop it in `on_window_close`.
- Never rely on the close functions to save data. Save as you go.
- An exception in a callback goes to `gtty ext logs`; the extension keeps
  running.

## UI

Set it up in `on_window_start`, or have none. **A UI needs a chip**; peek
and epeek are optional. Set the chip first (a peek without one is refused:
`set: NoChip` in the log).

| Set | A click on the chip |
|---|---|
| chip | Opens nothing |
| chip, peek | Opens the peek |
| chip, epeek | Opens the epeek |
| chip, peek, epeek | Opens the peek; its expand button opens the epeek |

- **Chip:** the short text in the window's footer.
- **Peek:** one line over the chip: `[prefixButton] [expand] text [postButton] [×]`.
- **Epeek:** the list that opens over the peek or chip, hiding it.

Hover opens nothing by itself: call `set_display_mode` from `onhover`.

```python
win.ui.set_display_mode("peek")   # or "epeek"
win.ui.set_display_mode("chip")   # closes your peek or epeek
```

gtty only reports clicks, so close the list yourself after a pick. Only one
is open at a time. If you open yours while not handling the user's click or
hover, it won't replace another one and gets no keyboard.

### `win.ui.set`

One of `chip=`, `peek=`, `epeek=`, `dialog=` per call, a dict. **A key left
out stays as it is, `None` clears it.** Keys are camelCase, exactly as here.

```python
win.ui.set(chip={"text": "main", "dimmed": False, "onclick": "a", "onhover": "b", "data": "x"})
win.ui.set(chip={"text": None})                  # no text: not shown
win.ui.set(peek={"expand": True, "hoverExpand": False, "onexpand": "load",
                 "text": "full text", "onclick": "a", "onhover": "b", "data": "x",
                 "prefixButton": {"icon": "copy", "onclick": "copy"},
                 "postButton": {"dots": "horizontal", "onclick": "more"}})
win.ui.set(peek=None)                            # removes it
win.ui.set(epeek={
    "frame": {"text": "hosts", "filter": {"hint": "filter", "onclick": "filter"},
              "left": [], "right": [{"icon": "save", "text": "add", "onclick": "add"}]},
    "lines": [{"id": "a", "text": "alpha", "onclick": "pick", "data": "alpha"}],
    "selected": 0, "empty": "nothing here",
})
```

| Dict | Keys |
|---|---|
| button | `id`, `icon`, `text`, `onclick`, `data`, `dots`, `items` |
| item | `id`, `text`, `data` |
| line | `id`, `prefixButton`, `text`, `postButton`, `onclick`, `onhover`, `data` |
| peek | `expand`, `hoverExpand`, `onexpand`, then as a line without `id` |
| frame | `left`, `right` (lists, 2 buttons each at most), `text`, `onclick`, `onhover`, `data`, `filter` |
| filter | `text`, `hint`, `options` (list of strings), `onclick` |
| epeek | `frame`, `lines`, `selected`, `empty`, `footer`, `state`, `message` |

- **Button:** with no `onclick` and no `dots`, it's only an icon. Icons:
  `copy`, `save`, `list`, `dot`. An unknown name draws nothing.
- **Dots** (`postButton` only): `"vertical"` shows `items` in a popup, and a
  pick is a click with that item's `id`, `text`, `data` and the button's
  `onclick`. `"horizontal"` is a plain click.
- **Frame:** gtty adds the × after `right`. No frame: a plain list, with no
  filter; Esc or a click outside closes it.
- **Filter:** gtty doesn't filter. Every change is a click with id `filter`
  and the box's text in `b.text`; answer with new `lines`. Closing with
  text in the box sends one more, with empty text. `options` are offered
  under the box, and Tab takes the first.
- **State:** `"idle"`, `"busy"`, `"ok"`, `"err"`, with `message` (a list of
  texts, one row each). `"ok"` closes the epeek after a second.
- After `lines` change, `selected` applies again, so send it with them.

### Text

A text is a string, or a list of up to 8 parts, each with its own look:

```python
"main"
gtty.new_text("main", bold=True)
gtty.new_text(("feature/", {}), ("login", {"fg": 0x202020, "bk": 0xE0B040}))
```

Attributes: `fg`, `bk` (`0xrrggbb` or `"#rrggbb"`), `size` (percent, 50-200),
`bold`, `stroke` (a line through the text). Left out: gtty's default. In a
dict you write yourself, colors must be `"#rrggbb"` strings; `new_text`
converts numbers.

## Events

```python
win.events.register("window_changed")
win.events.unregister("window_changed")
```

| `ev.kind` | When | Fields |
|---|---|---|
| `"window_changed"` | At the start, then when something changed | `folder`, `branch`, `remote` |
| `"command_started"` | A command starts in the window's shell | `command`, `folder`, `remote` |
| `"key"` | A key pressed while the window has the keyboard | `key`, `text`, `ctrl`, `shift`, `alt`, `cmd` |
| `"button_click"` | Your click, hover or filter; never register it | `button` |

Also `ev.event_id`. `branch` is empty outside a repo. With `remote` true,
`folder` is the local one.

### Keys

```python
win.events.register("key")
```

```python
def on_event(win, ev):
    if ev.kind == "key" and ev.key == "f6" and not (ev.ctrl or ev.shift or ev.alt or ev.cmd):
        win.ui.set_display_mode("epeek")
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

Every `onclick`, `onhover` and `onexpand` is a function name. They all
arrive as `"button_click"`:

```python
class Actions:
    @staticmethod
    def saveIt(win, b): ...

def on_event(win, ev):
    if ev.kind == "button_click":
        gtty.dispatch(Actions, win, ev)   # a class, an object or a dict
```

- `dispatch` raises `LookupError` for a name with no function (logged).
- `b`: `id`, `text` (plain), `data`, `function`, `command` (⌘, Linux Ctrl),
  `fields`, `b.field("id")` (a string or None), `b.checked("id")`.
- Put what the handler needs in `data`, so it needs no lookup.
- A hover fires once after a 0.5 s rest, never on leaving. A hover on chip
  text needs `onhover`, and the same for lines.

## Dialogs

```python
win.ui.set(dialog={
    "title": "Add a host",
    "layout": "form",          # "form", "grid", "table" (+ "columns", "rows")
    "timeout": 30,             # seconds, at most 600
    "buttons": "okcancel",     # "ok", "okcancel", "yesno"
    "onclick": "addHost",
    "fields": [
        {"id": "host", "type": "text", "label": "Host", "value": ""},
        {"id": "pin", "type": "checkbox", "label": "Pin", "value": False},
        {"id": "kind", "type": "dropdown", "label": "Kind", "value": "ssh", "options": ["ssh", "mosh"], "filter": True},
        {"id": "hint", "type": "label", "label": "Plain text"},
    ],
})
win.ui.show_dialog()
```

- One dialog at a time per window, and the rest wait. It's modal to its
  window only.
- **Buttons only report. You must call `win.ui.close_dialog()`**, for
  cancel and no too, or it stays until its timeout.
- To reject input, keep it open: `win.ui.set(dialog={"error": "enter a host"})`.

| `b.id` | From | Values | Closed by |
|---|---|---|---|
| `ok`, `yes` | Button, Enter | yes | You |
| `cancel`, `no` | Button, Esc | yes | You |
| `kill` | ×, the window closing | no | gtty, already |
| `timeout` | The timer | no | gtty, already |

Never call `close_dialog` after `kill` or `timeout`, and don't treat them as
a cancel the user chose. An open epeek stays open under a dialog: to avoid
two things looking active, call `set_display_mode("chip")` first.

## Storage

`win.ephemeral`: this instance's files, deleted when its window closes.
`win.stateful`: the extension's files, shared by all instances in all gttys.

```python
with win.stateful.open_write("hosts.json", 500) as f:   # waits up to 500 ms
    f.write(text)                                        # str or bytes

try:
    with win.stateful.open_read("hosts.json", 500) as f:
        data = f.read_all()                              # bytes; f.read(n) for parts
except gtty.NoFile:
    data = b""                                           # nothing saved yet

win.stateful.delete("old.json", 500)
names = win.stateful.list()
```

- **`open_write` replaces the whole file, at `close`** (the `with` block's
  end). To add to it, read it first and write it all back. No append, no
  seek. Without `close` the write is lost.
- While a file is open for writing nobody else can use it. Several can read.
  **Always close quickly**: gtty closes a file after 30 s and drops its
  write; the next call raises `FileClosed`.
- A timeout of 0 tries once; with a timeout the call waits up to that long,
  then raises `FileInUse`. Keep timeouts short: the callback waits meanwhile.
- Names are plain file names: no `/`, no `..`, no leading `.`. No subfolders.
- A storage holds 100 MB by default (the user's setting): `StorageFull`.
- Uninstalling deletes stateful data. If users may want theirs, offer an
  export from your peek or a dialog.

## Shell

```python
name = win.shell()   # "bash" inside zsh; what's in front isn't a shell: the window's own
```

## Logs

```python
win.log("info", "host %s added" % name)   # with this window's id
ext.log("warn", "no config")              # in on_gtty_start, on_gtty_close
```

Levels: `debug`, `info`, `warn`, `err`; 4096 characters at most. It works
from any thread and in `on_window_close`. Don't log passwords or file
contents. `print()` and stderr reach the log too, as info and err lines.

```sh
gtty ext logs -f yourname   # follow one extension, until gtty closes
gtty ext logs               # what is there now, every extension
```

A line reads `time level extension window message`. gtty adds its own:
`on_event raised …` and mistakes in what you sent (`set: NoChip`). When
something doesn't work, read these first.

## Errors

`gtty.GttyError` and its subclasses `WindowClosed`, `NoChip`, `BadName`,
`NoFile`, `FileInUse`, `FileClosed`, `StorageFull`, `StorageFailed`
(`e.name` is the name).

- `win.ui.*` and `win.events.*` don't wait for gtty: a mistake gtty finds is
  a line in `gtty ext logs`. A wrong argument here (`set_display_mode("x")`)
  raises `ValueError` / `TypeError`.
- Storage and `win.shell()` wait for gtty's answer and raise its error.

## Package and run

A package is a folder (or a `.zip` / `.tar.gz` of one) with
`manifest.json` at its top, your program and `gtty.py`:

```json
{
  "name": "hosts",
  "version": "1.0.0",
  "description": "A chip that keeps a list of hosts",
  "main": "hosts.py",
  "runtime": "python3"
}
```

- `name`: lowercase letters, digits, `-`, `_`, starting with a letter, 32 at
  most; not `folder`, `git`, `focus`, `session`, `test`, `gtty`,
  `extensions`. It names the storage and the log lines.
- `main`: relative to the package. `runtime: "python3"` makes gtty run
  `python3 main` (found on PATH), in the package folder.
- No links, no files outside the package: gtty refuses such a package.

```sh
gtty ext install ./hosts-pkg   # install, or update (data kept)
gtty ext list                  # name, version, on / off
gtty ext logs -f hosts         # its log, while gtty runs
gtty ext disable hosts         # enable hosts, uninstall hosts (data too)
```

Every running gtty starts it within a second, and restarts it when it is
installed again: the loop is edit, `gtty ext install`, read the logs.

## Debug

Run the extension from your IDE's debugger (or `python3 hosts.py`) while gtty
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
      "type": "debugpy",
      "request": "launch",
      "program": "${workspaceFolder}/hosts.py",
      "cwd": "${workspaceFolder}",
      "console": "integratedTerminal"
    }
  ]
}
```

That is VS Code with the Python extension (debugpy). PyCharm: a Run / Debug configuration of the script, working directory = the package folder.

To debug the installed copy instead, attach to its pid (the extension
manager and `gtty ext logs` show it); its start has already run by then.

## Check your work

```sh
python3 conformance/fake_gtty.py -- python3 examples/hosts.py
```

`conformance/fake_gtty.py` is a stand-in for gtty that runs the hosts
example through one conversation: adapt its checks to your extension, or
run it with `--verbose` to see every message. Make sure every name in
`onclick`, `onhover` and `onexpand` has a function in your actions.
