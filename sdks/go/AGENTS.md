# gtty extensions in Go: guide for AI assistants

Read all of this before writing an extension. It lists only what exists in
this SDK. `gtty.go` is the truth; `examples/hosts` is a complete, working
extension, so start from a copy of it and its `manifest.json`.

**Requires** Go 1.21 or later, standard library only. Import
`gtty "github.com/Tesselix/gtty/sdks/go"`. From a release's SDK archive,
point at it with `go mod edit -replace github.com/Tesselix/gtty/sdks/go=../gtty-sdk-go-<version>`.

## Status: tell the user this

- An extension is its **own program**: `main` calls `gtty.Run(ext)`. gtty
  starts it as its child process (with a socket on fd 3) and stops it when
  gtty closes. Started by hand or by your
  IDE's debugger while gtty runs, it connects to that gtty instead: see
  "Debug".
- One process serves every window of one gtty: `OnWindowStart` runs once
  per window, `win.ID` tells them apart.
- Installed with `gtty ext install <folder | .zip | .tar.gz>` or the
  extension manager (gtty ▸ Extensions…); see "Package and run".
- Not in this SDK, don't call them: window text, labels, chip icons, icon
  files, objects, selection events, mouse events.

## Rules

1. Extensions never draw. They describe; gtty draws.
2. Return quickly from callbacks. They run one at a time on `Run`'s
   goroutine; while one runs your extension gets nothing else, and gtty
   drops events it can't send you (logged). For slow work (network, big
   files) start a goroutine and keep its results for the next event.
3. Call `win.UI`, `win.Events`, storage and `win.Shell()` only from a
   callback, not from another goroutine. `Log` works anywhere.
4. Don't invent events, keys or values. If it isn't here, it doesn't exist.
   Say so to the user. A wrong key is a line in `gtty ext logs`, not an
   error.
5. In text the user reads, write "window", never "job window".

## Shape of an extension

A value with any of these methods; all are optional.

```go
type myExt struct{ /* state, by window id */ }

func (e *myExt) OnGttyStart(ext *gtty.Ext) error                  { return nil } // once
func (e *myExt) OnWindowStart(win *gtty.Window) error             { return nil } // each window
func (e *myExt) OnWindowClose(win *gtty.Window) error             { return nil } // notice: win calls fail
func (e *myExt) OnGttyClose(ext *gtty.Ext) error                  { return nil } // notice: nobody waits
func (e *myExt) OnEvent(win *gtty.Window, ev *gtty.Event) error   { return nil }

func main() {
	if err := gtty.Run(&myExt{}); err != nil { // says why on stderr
		os.Exit(1)
	}
}
```

- Keep state by `win.ID`, drop it in `OnWindowClose`.
- Never rely on the close methods to save data. Save as you go.
- A returned error goes to `gtty ext logs`; the extension keeps running.

## UI

Set it up in `OnWindowStart`, or have none. **A UI needs a chip**; peek
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

Hover opens nothing by itself: call `SetDisplayMode` from `onhover`.

```go
win.UI.SetDisplayMode("peek")   // or "epeek"
win.UI.SetDisplayMode("chip")   // closes your peek or epeek
```

gtty only reports clicks, so close the list yourself after a pick. Only one
is open at a time. If you open yours while not handling the user's click or
hover, it won't replace another one and gets no keyboard.

### `win.UI.Set`

Updates are `gtty.M` (`map[string]any`), exactly the protocol's JSON: one
of `chip`, `peek`, `epeek`, `dialog` per call. **A key left out stays as
it is, `nil` clears it.** Keys are camelCase, exactly as here.

```go
win.UI.Set(gtty.M{"chip": gtty.M{"text": "main", "dimmed": false, "onclick": "a", "onhover": "b", "data": "x"}})
win.UI.Set(gtty.M{"chip": gtty.M{"text": nil}})   // no text: not shown
win.UI.Set(gtty.M{"peek": gtty.M{"expand": true, "hoverExpand": false, "onexpand": "load",
	"text": "full text", "onclick": "a", "onhover": "b", "data": "x",
	"prefixButton": gtty.M{"icon": "copy", "onclick": "copy"},
	"postButton":   gtty.M{"dots": "horizontal", "onclick": "more"}}})
win.UI.Set(gtty.M{"peek": nil})                    // removes it
win.UI.Set(gtty.M{"epeek": gtty.M{
	"frame": gtty.M{"text": "hosts", "filter": gtty.M{"hint": "filter", "onclick": "filter"},
		"right": []gtty.M{{"icon": "save", "text": "add", "onclick": "add"}}},
	"lines":    []gtty.M{{"id": "a", "text": "alpha", "onclick": "pick", "data": "alpha"}},
	"selected": 0, "empty": "nothing here",
}})
```

**An empty list must be `[]gtty.M{}`, not a nil slice** (nil is JSON
`null`, which clears).

| Map | Keys |
|---|---|
| button | `id`, `icon`, `text`, `onclick`, `data`, `dots`, `items` |
| item | `id`, `text`, `data` |
| line | `id`, `prefixButton`, `text`, `postButton`, `onclick`, `onhover`, `data` |
| peek | `expand`, `hoverExpand`, `onexpand`, then as a line without `id` |
| frame | `left`, `right` (2 buttons each at most), `text`, `onclick`, `onhover`, `data`, `filter` |
| filter | `text`, `hint`, `options` (`[]string`), `onclick` |
| epeek | `frame`, `lines`, `selected`, `empty`, `footer`, `state`, `message` |

- **Button:** with no `onclick` and no `dots`, it's only an icon. Icons:
  `copy`, `save`, `list`, `dot`. An unknown name draws nothing.
- **Dots** (`postButton` only): `"vertical"` shows `items` in a popup, and a
  pick is a click with that item's `id`, `text`, `data` and the button's
  `onclick`. `"horizontal"` is a plain click.
- **Frame:** gtty adds the × after `right`. No frame: a plain list, with no
  filter; Esc or a click outside closes it.
- **Filter:** gtty doesn't filter. Every change is a click with ID `filter`
  and the box's text in `b.Text`; answer with new `lines`. Closing with
  text in the box sends one more, with empty text. `options` are offered
  under the box, and Tab takes the first.
- **State:** `"idle"`, `"busy"`, `"ok"`, `"err"`, with `message` (texts, one
  row each). `"ok"` closes the epeek after a second.
- After `lines` change, `selected` applies again, so send it with them.

### Text

A text is a string, or up to 8 parts, each with its own look:

```go
"main"
gtty.Text(gtty.Part{String: "main", Bold: true})
gtty.Text(gtty.Part{String: "feature/"}, gtty.Part{String: "login", Fg: gtty.RGB(0x202020), Bk: gtty.RGB(0xe0b040)})
```

`Part`: `String`, `Fg`, `Bk` (`"#rrggbb"`; `gtty.RGB(0xrrggbb)` makes one),
`Size` (percent, 50-200), `Bold`, `Stroke` (a line through the text). Left
out: gtty's default.

## Events

```go
win.Events.Register("window_changed")
win.Events.Unregister("window_changed")
```

| `ev.Kind` | When | Fields |
|---|---|---|
| `"window_changed"` | At the start, then when something changed | `Folder`, `Branch`, `Remote` |
| `"command_started"` | A command starts in the window's shell | `Command`, `Folder`, `Remote` |
| `"key"` | A key pressed while the window has the keyboard | `Key`, `Text`, `Ctrl`, `Shift`, `Alt`, `Cmd` |
| `"button_click"` | Your click, hover or filter; never register it | `Button` |

Also `ev.EventID`. `Branch` is empty outside a repo. With `Remote` true,
`Folder` is the local one.

### Keys

```go
win.Events.Register("key")
```

```go
case "key":
	if ev.Key == "f6" && !(ev.Ctrl || ev.Shift || ev.Alt || ev.Cmd) {
		return win.UI.SetDisplayMode("epeek")
	}
```

- `Key`: the key's name. The character on it, unshifted (`a`, `1`,
  `/`), or `enter`, `escape`, `tab`, `backspace`, `delete`, `space`,
  `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`,
  `insert`, `f1` to `f24`; another key: the system's name, lowercase,
  no blanks. Empty for text from an input method, with no key.
- `Text`: what the key typed (`A` with Shift, `é`); empty for keys that
  type nothing (arrows, Ctrl+C).
- `Ctrl`, `Shift`, `Alt`, `Cmd`: the modifier keys held. `Cmd` is ⌘ on macOS,
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

```go
func (e *myExt) actions() map[string]gtty.Action {
	return map[string]gtty.Action{
		"saveIt": func(win *gtty.Window, b *gtty.ButtonClick) error { return nil },
	}
}

func (e *myExt) OnEvent(win *gtty.Window, ev *gtty.Event) error {
	if ev.Kind == "button_click" {
		return gtty.Dispatch(e.actions(), win, ev)
	}
	return nil
}
```

- `Dispatch` returns an error for a name with no function (logged).
- `b`: `ID`, `Text` (plain), `Data`, `Function`, `Command` (⌘, Linux Ctrl),
  `Fields`, `b.Field("id")` (value, ok), `b.Checked("id")`.
- Put what the handler needs in `data`, so it needs no lookup.
- A hover fires once after a 0.5 s rest, never on leaving. A hover on chip
  text needs `onhover`, and the same for lines.

## Dialogs

```go
win.UI.Set(gtty.M{"dialog": gtty.M{
	"title":   "Add a host",
	"layout":  "form",     // "form", "grid", "table" (+ "columns", "rows")
	"timeout": 30,         // seconds, at most 600
	"buttons": "okcancel", // "ok", "okcancel", "yesno"
	"onclick": "addHost",
	"fields": []gtty.M{
		{"id": "host", "type": "text", "label": "Host", "value": ""},
		{"id": "pin", "type": "checkbox", "label": "Pin", "value": false},
		{"id": "kind", "type": "dropdown", "label": "Kind", "value": "ssh", "options": []string{"ssh", "mosh"}, "filter": true},
		{"id": "hint", "type": "label", "label": "Plain text"},
	},
}})
win.UI.ShowDialog()
```

- One dialog at a time per window, and the rest wait. It's modal to its
  window only.
- **Buttons only report. You must call `win.UI.CloseDialog()`**, for cancel
  and no too, or it stays until its timeout.
- To reject input, keep it open: `win.UI.Set(gtty.M{"dialog": gtty.M{"error": "enter a host"}})`.

| `b.ID` | From | Values | Closed by |
|---|---|---|---|
| `ok`, `yes` | Button, Enter | yes | You |
| `cancel`, `no` | Button, Esc | yes | You |
| `kill` | ×, the window closing | no | gtty, already |
| `timeout` | The timer | no | gtty, already |

Never call `CloseDialog` after `kill` or `timeout`, and don't treat them as
a cancel the user chose. An open epeek stays open under a dialog: to avoid
two things looking active, call `SetDisplayMode("chip")` first.

## Storage

`win.Ephemeral`: this instance's files, deleted when its window closes.
`win.Stateful`: the extension's files, shared by all instances in all gttys.

```go
f, err := win.Stateful.OpenWrite("hosts.json", 500) // waits up to 500 ms
if err != nil { return err }
if err := f.Write(data); err != nil { f.Close(); return err }
if err := f.Close(); err != nil { return err }

r, err := win.Stateful.OpenRead("hosts.json", 500)
if errors.Is(err, gtty.ErrNoFile) { /* nothing saved yet */ }
if err == nil { data, err = r.ReadAll(); r.Close() }  // r.Read(n) for parts

err = win.Stateful.Delete("old.json", 500)
names, err := win.Stateful.List()
```

- **`OpenWrite` replaces the whole file, at `Close`.** To add to it, read it
  first and write it all back. No append, no seek. Without `Close` the
  write is lost.
- While a file is open for writing nobody else can use it. Several can read.
  **Always close quickly**: gtty closes a file after 30 s and drops its
  write; the next call returns `ErrFileClosed`.
- A timeout of 0 tries once; with a timeout the call waits up to that long,
  then returns `ErrFileInUse`. Keep timeouts short.
- Names are plain file names: no `/`, no `..`, no leading `.`. No subfolders.
- A storage holds 100 MB by default (the user's setting): `ErrStorageFull`.
- Uninstalling deletes stateful data. If users may want theirs, offer an
  export from your peek or a dialog.

## Shell

```go
name, err := win.Shell() // "bash" inside zsh; not a shell in front: the window's own
```

## Logs

```go
win.Log("info", "host "+name+" added") // with this window's id
ext.Log("warn", "no config")           // in OnGttyStart, OnGttyClose
```

Levels: `debug`, `info`, `warn`, `err`; 4096 bytes at most. Safe from any
goroutine and in `OnWindowClose`. Don't log passwords or file contents.
Anything written to stdout or stderr reaches the log too, as info and err
lines.

```sh
gtty ext logs -f yourname   # follow one extension, until gtty closes
gtty ext logs               # what is there now, every extension
```

A line reads `time level extension window message`. gtty adds its own:
`OnEvent returned …` and mistakes in what you sent (`set: NoChip`). When
something doesn't work, read these first.

## Errors

`gtty.ErrWindowClosed`, `ErrNoChip`, `ErrBadName`, `ErrNoFile`,
`ErrFileInUse`, `ErrFileClosed`, `ErrStorageFull`, `ErrStorageFailed`;
compare with `errors.Is`.

- `win.UI.*` and `win.Events.*` don't wait for gtty: a mistake gtty finds is
  a line in `gtty ext logs`. A wrong argument here (`SetDisplayMode("x")`)
  returns an error.
- Storage and `win.Shell()` wait for gtty's answer and return its error.

## Package and run

A package is a folder (or a `.zip` / `.tar.gz` of one) with
`manifest.json` at its top and the built programs:

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

```sh
GOOS=darwin GOARCH=arm64 go build -o pkg/bin/hosts-macos-aarch64 .
GOOS=linux GOARCH=amd64 go build -o pkg/bin/hosts-linux-x86_64 .
```

- `name`: lowercase letters, digits, `-`, `_`, starting with a letter, 32 at
  most; not `folder`, `git`, `focus`, `session`, `test`, `gtty`,
  `extensions`. It names the storage and the log lines.
- `main`: relative to the package; one string, or one per platform.
- No links, no files outside the package: gtty refuses such a package.

```sh
gtty ext install ./pkg         # install, or update (data kept)
gtty ext list                  # name, version, on / off
gtty ext logs -f hosts         # its log, while gtty runs
gtty ext disable hosts         # enable hosts, uninstall hosts (data too)
```

Every running gtty starts it within a second, and restarts it when it is
installed again: the loop is build, `gtty ext install`, read the logs.

## Debug

Run the extension from your IDE's debugger (or `go run .`) while gtty
runs: breakpoints, stepping and variables work as in any program. With no
`GTTY_EXT_FD` (gtty didn't start it) the SDK connects to the newest gtty and
says which extension it is: `GTTY_EXT_NAME`, else the `name` in the
`manifest.json` of the folder it runs in (so run it there). Then:

- Its chip shows in every window of that gtty, as if installed. An installed
  copy of the same name stops while it runs and starts again when it ends.
- stdout and stderr go to the IDE's console; `Log(...)` lines still go to
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
      "type": "go",
      "request": "launch",
      "mode": "debug",
      "program": "${workspaceFolder}",
      "cwd": "${workspaceFolder}"
    }
  ]
}
```

That is VS Code with the Go extension (Delve). GoLand: a Go Build configuration, working directory = the package folder. Or `dlv debug`.

To debug the installed copy instead, attach to its pid (the extension
manager and `gtty ext logs` show it); its start has already run by then.

## Check your work

```sh
go vet ./... && go build -o /tmp/hosts ./examples/hosts
python3 conformance/fake_gtty.py -- /tmp/hosts
```

`conformance/fake_gtty.py` is a stand-in for gtty that runs the hosts
example through one conversation: adapt its checks to your extension, or
run it with `--verbose` to see every message. Make sure every name in
`onclick`, `onhover` and `onexpand` has a function in your actions map.
