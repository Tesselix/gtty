# gtty extensions in Go: guide for AI assistants

`CLAUDE.md` next to this file says what gtty is and how its users see
it: read it first. Then this file: every rule, then every function
("Function reference").

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
3. Call `win.UI`, `win.Events`, storage, `win.Shell()` and the requests
   (`win.Notice`, `Copy`, `Cd`, …, `win.Sessions`) only from a callback,
   not from another goroutine. `Log` works anywhere.
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
| `"window_changed"` | At the start, then when something changed | `Folder`, `Branch`, `Remote`, `Host` (the ssh / mosh destination) |
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

## Asking gtty

gtty is the core: it runs the windows and their shells. Besides your own
UI and files you can ask it for a few things; each waits for gtty's answer
(call them from a callback). Those marked **user** work only while you
handle the user's click or key (an event they caused, still recent);
otherwise they fail with `NotFromUser`, and that is on purpose: an
extension must not change the clipboard, type in the shell or replace the
user's windows by itself.

```go
err := win.Notice("3 hosts found", "ok") // "plain", "ok" (green), "err" (red)
err = win.Beep()
err = win.Copy(b.Data) // user
if err := win.Cd(folder); errors.Is(err, gtty.ErrShellBusy) { // user
	_ = win.Notice("the shell is busy", "err")
}
err = win.Refresh() // folder and branch looked at now
n := win.Number     // the #3 the user sees

recent, err := win.Sessions.List(7)    // []gtty.Session{ID, Name}, the last used last
name, err := win.Sessions.SuggestName() // gtty.ErrNothingToSave
err = win.Sessions.Save(name)
err = win.Sessions.Restore(recent[0].ID, false) // user; true: a new gtty
err = win.Sessions.Manage()                     // user
```

- `cd` is the only thing an extension can make the shell do, and only at its
  prompt with nothing typed; it can't type anything else, nor read the
  window's text.
- `copy` flashes what was clicked in your open peek (the row picked, else
  the top text) and says "copied …" in the status bar: don't add your own
  notice for it.
- Sessions are gtty's saved screens (shell windows and where they were),
  shared by every gtty. `restore` here replaces this gtty's windows (gtty
  asks first when some still work); with `new_window` a new gtty opens.

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
`ErrFileInUse`, `ErrFileClosed`, `ErrStorageFull`, `ErrStorageFailed`,
`ErrShellBusy` (`Cd`: the shell isn't at its prompt), `ErrNotFromUser` (a
**user** request outside the user's click or key), `ErrNothingToSave`
(`Sessions.SuggestName`); compare with `errors.Is`.

- `win.UI.*` and `win.Events.*` don't wait for gtty: a mistake gtty finds is
  a line in `gtty ext logs`. A wrong argument here (`SetDisplayMode("x")`)
  returns an error.
- Storage, `win.Shell()` and the requests wait for gtty's answer and
  return its error.

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

## Function reference

Every function of the SDK, one by one: what it does, when you may call it,
what it returns, and the mistakes to avoid. "Callback" means one of your
`On…` methods or a click handler, running on `Run`'s goroutine.

### Starting

**`gtty.Run(ext any) error`** — in `main`. Connects to gtty (the socket
gtty gave it, else the running gtty, see "Debug"), calls your methods as
messages come, and returns `nil` when gtty closes; an error (already
printed on stderr) when it can't connect, is refused, or speaks another
API version: exit non-zero then. `ext` is a pointer to your type with the
`On…` methods. Don't call anything else before it.

**`gtty.APIVersion`** — the protocol version this SDK speaks (1). gtty
checks it at connect; you don't need it.

### Your methods (all optional)

**`OnGttyStart(ext *gtty.Ext) error`** — once, before any window. Read your
settings, log a start line. There is no window yet: only `ext.Log` and
`ext.Name`.

**`OnWindowStart(win *gtty.Window) error`** — once per window: first for
the windows already open, then for each new one. Set up your UI here
(`win.UI.Set` the chip first), register events, read saved state. Keep
per-window state in a map keyed by `win.ID`.

**`OnEvent(win *gtty.Window, ev *gtty.Event) error`** — every registered
event and every click on your UI. Switch on `ev.Kind`; for
`"button_click"` call `gtty.Dispatch`. Return fast.

**`OnWindowClose(win *gtty.Window) error`** — the window is gone. Every
`win` call now returns `gtty.ErrWindowClosed`; only drop your state for
`win.ID`. `win.Log` still works.

**`OnGttyClose(ext *gtty.Ext) error`** — gtty is closing; nobody waits for
you. Don't save here (save as you go).

An error you return becomes a line in `gtty ext logs`
(`ErrWindowClosed` isn't logged); the extension keeps running and the
user sees nothing. A panic ends the program: recover in your own
goroutines.

### `win` and `ext`

**`win.Number uint32`** — the number the user sees on the window (`#3`),
for text the user reads.

**`win.Notice(text, kind string) error`** — a short notice in the status
bar; `kind` `"plain"`, `"ok"` (green), `"err"` (red).

**`win.Beep() error`** — gtty's error beep.

**`win.Copy(text string) error`** — **user**. The clipboard and gtty's
paste history; "copied …" in the status bar; what was clicked in your open
peek flashes. `ErrNotFromUser` outside the user's click or key.

**`win.Cd(folder string) error`** — **user**. `cd -- '<folder>'` typed and
run in the window's shell; `ErrShellBusy` when it isn't waiting at its
prompt with nothing typed.

**`win.Refresh() error`** — gtty looks at the folder and branch now;
`window_changed` follows if they changed (after your own `git switch`).

**`win.Sessions.List(max int) ([]gtty.Session, error)`** — `ID`, `Name`,
the last used last. **`SuggestName() (string, error)`** — the name gtty
gives a session now; `ErrNothingToSave` when no window would be kept.
**`Save(name string) error`**. **`Restore(id string, newWindow bool)
error`** — **user**; here (gtty may ask first) or in a new gtty.
**`Manage() error`** — **user**; opens the Session Manager.

**`win.ID uint32`** — the window's id, the same in every call for that
window and unique in this gtty. Key your state by it.

**`win.Log(level, message string)`** / **`ext.Log(level, message string)`**
— a line in `gtty ext logs`; level `"debug"`, `"info"`, `"warn"` or
`"err"` (another: `"info"`). Cut at 4096 bytes, safe from any goroutine
and in `OnWindowClose`. `ext.Log` writes `-` for the window.

**`ext.Name string`** — your extension's name, as gtty knows it.

**`win.Shell() (string, error)`** — asks gtty which shell is in front in
the window (`"zsh"`, `"bash"` inside zsh, …); with a program such as vim
in front, the window's own shell. Waits for gtty's answer (a callback
only).

### UI: `win.UI`

**`win.UI.Set(gtty.M{"chip": gtty.M{…}}) error`** — exactly one of
`"chip"`, `"peek"`, `"epeek"`, `"dialog"` per call (else an error). Keys
left out stay as they were, `nil` clears one, `gtty.M{"peek": nil}` /
`gtty.M{"epeek": nil}` removes the whole thing. Doesn't wait for gtty: an
update gtty rejects (a peek with no chip, an unknown key) is a line in
`gtty ext logs`; the error returned is only `ErrWindowClosed` or a bad
top-level key. Order matters: chip first, then peek / epeek. Callback
only.

**`win.UI.SetDisplayMode("chip" | "peek" | "epeek") error`** — opens your
peek or epeek over your chip, or with `"chip"` closes it. Call it from a
click or hover handler: then it opens even over another one and gets the
keyboard. Called at another time it won't replace a peek that is open,
and it gets no keyboard. Close your epeek yourself after a pick.

**`win.UI.ShowDialog() error`** — shows the dialog last set with
`win.UI.Set(gtty.M{"dialog": …})` (none set: a `NoDialog` line in the
logs). From the user's click or key it gets the keyboard; otherwise only
once the user clicks it. One dialog per window at a time; others wait.

**`win.UI.CloseDialog() error`** — closes it. Buttons only report, so call
this after every `ok`, `cancel`, `yes` and `no` you handle, unless you
keep it open to show an error (`gtty.M{"dialog": gtty.M{"error": "…"}}`).
Not after `kill` or `timeout`: gtty already closed it (the call does
nothing then).

### Events: `win.Events`

**`win.Events.Register(kind string) error`** — start getting
`"window_changed"`, `"command_started"` or `"key"` for this window
(another name: an error). Register only what you use: every event costs
time. `"window_changed"` arrives once right away with the current folder
and branch. Clicks need no registering.

**`win.Events.Unregister(kind string) error`** — stop getting it (for
example `"key"` while your list is closed).

### Clicks

**`gtty.Dispatch(actions map[string]gtty.Action, win, ev) error`** — calls
`actions[ev.Button.Function](win, b)`, the handler named by the `onclick`,
`onhover` or `onexpand` string you set (`gtty.Action` is `func(win
*gtty.Window, b *gtty.ButtonClick) error`). No such name: an error
(logged). `nil` for events that aren't clicks.

**`b.Field("host") (string, bool)`** — a dialog text box's or drop box's
value; `false` when there is no such field (always for `kill` /
`timeout`, which carry no fields).

**`b.Checked("pin") bool`** — a dialog check box's value; `false` when
missing.

`ButtonClick` fields: `ID` (the line's, button's or item's `id`, the
dialog button, or `"filter"`), `Text` (plain), `Data` (what you put in
`data`: store what the handler needs there), `Function`, `Fields`,
`Command` (⌘ held, Linux Ctrl).

`Event` fields: `EventID`, `Kind`, `Folder`, `Branch`, `Remote`,
`Command`, `Key`, `Text`, `Ctrl`, `Shift`, `Alt`, `Cmd`, `Button`.

### Text

**`gtty.Text(parts ...gtty.Part) []gtty.Part`** — a text of up to 8 parts
(the rest dropped). `Part{String, Fg, Bk, Size, Bold, Stroke}`; empty
fields take gtty's default. A plain string works wherever a text goes.

**`gtty.RGB(0xe0b040) string`** — a color as gtty takes it (`"#e0b040"`),
for `Fg` / `Bk`.

**`gtty.M`** — `map[string]any`, the shape of every update.

### Storage: `win.Ephemeral` and `win.Stateful`

All wait for gtty's answer: callbacks only, and keep `timeoutMs` short.

**`OpenWrite(name string, timeoutMs int) (*gtty.File, error)`** — opens
`name` for writing; the new content replaces the file at `Close`. Waits
up to `timeoutMs` while another instance or gtty uses it
(`gtty.ErrFileInUse` after; 0 tries once). While you hold it nobody else
can open it: write and close in the same callback.

**`OpenRead(name string, timeoutMs int) (*gtty.File, error)`** — opens for
reading; several readers at once are fine. `gtty.ErrNoFile` when it
doesn't exist (normal on the first run).

**`f.Read(max int) ([]byte, error)`** — up to `max` bytes (at most 1 MB);
empty at the end. **`f.ReadAll() ([]byte, error)`** — the rest of the
file.

**`f.Write(data []byte) error`** — added to what this open will write (not
to the old file).

**`f.Close() error`** — ends the open; for a write, the file now holds
exactly what you wrote. Forgetting it loses the write; gtty closes any
file after 30 s and the next call returns `gtty.ErrFileClosed`. A second
`Close` does nothing.

**`Delete(name string, timeoutMs int) error`** — removes the file
(`gtty.ErrNoFile` if there is none).

**`List() ([]string, error)`** — the file names.

`win.Ephemeral` is this window's own, deleted when it closes (scratch,
caches); `win.Stateful` is shared by every window in every gtty, kept
until uninstall (settings, lists the user built). Two windows may write
the same stateful file: read, change, write in one callback, and handle
`gtty.ErrFileInUse`. Compare errors with `errors.Is`.

## Check your work

```sh
go vet ./... && go build -o /tmp/hosts ./examples/hosts
python3 conformance/fake_gtty.py -- /tmp/hosts
```

`conformance/fake_gtty.py` is a stand-in for gtty that runs the hosts
example through one conversation: adapt its checks to your extension, or
run it with `--verbose` to see every message. Make sure every name in
`onclick`, `onhover` and `onexpand` has a function in your actions map.
