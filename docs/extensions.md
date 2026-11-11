# Writing gtty extensions

> **Status: partly built.** Built: the events below, text, chips, peeks,
> epeeks, dialogs and their clicks, storage, logs, `win.shell()`, installed
> extensions as their own programs, SDKs for Zig, Python, JavaScript and Go
> (`sdks/`), `gtty ext`, the extension manager and debugging from an IDE. Icon files, `windowText`
> and labels are the agreed design, not code yet, so names can still change.
> Items marked *(proposed)* are not decided; they are listed in
> [Not decided yet](#not-decided-yet).

## The idea

An extension adds something to gtty's windows: it can watch what happens
in a window, and show its own information and controls there.

**Every chip is an extension.** The folder, git, focus and session chips
use the same Zig SDK yours will. They are the *standard* chips: they run
inside the gtty process and can't be turned off. *Installed* extensions come
after them in each window's footer:

```
[extensions] [folder] [git] [focus] [session] | [your chips…]
```

The first chip lists everything installed.

**An extension is visible or invisible.** An invisible one only watches
and reacts. A visible one has a chip, and the chip opens up in steps,
each showing more:

| Element | What it is | Use it for |
|---|---|---|
| **Chip** | A short text in the window's footer | The one fact worth seeing at a glance |
| **Peek** | One line that opens over the chip | The full value, with its actions |
| **Epeek** | The expanded peek: a list that opens over the peek or the chip, with an optional top frame | Choosing from many items |
| **Dialog** | A form centered in the window | Asking the user for several values |

**You describe, gtty draws.** An extension never draws anything. It
sends a description of what it wants, and gtty does the layout, colors,
hovering and keyboard. You can change the description at any time.

**gtty never waits for you.** Your extension can't hold up the terminal.
When something happens you get an event, and when you want something
changed you send a description. If your extension is slow or hangs, the
terminal keeps working, and gtty can close your dialog without asking.

## How an extension starts

The SDK connects to gtty and calls four functions, all optional:

| Function | Called |
|---|---|
| `onGttyStart(ext)` | Once, when your extension starts |
| `onWindowStart(win)` | For each window: those already open, then each new one |
| `onWindowClose(win)` | When a window closes; its text is already gone |
| `onGttyClose(ext)` | Once, when gtty closes |

```zig
const gtty = @import("gtty");

pub fn onGttyStart(ext: *gtty.Extension) !void {
    _ = ext;
}

pub fn onWindowStart(win: *gtty.Window) !void {
    try win.ui.set(.{ .chip = .{ .text = "kube" } });
}

pub fn onWindowClose(win: *gtty.Window) !void {
    forget(win.id);
}

pub fn onGttyClose(ext: *gtty.Extension) !void {
    _ = ext;
}
```

**The close functions are notices.** gtty and the window send them and
carry on, without waiting for you. By the time `onGttyClose` runs, gtty
may be gone, so save what matters as you go, not at the end.

`onWindowStart` runs many times inside one running extension, not once
per process. `onGttyStart` means *your extension* is starting: if it's
installed or restarted while gtty runs, windows are already open, and
each gets `onWindowStart` right after.

Zig comes first. Once it works, SDKs for other languages follow on the
same messages: JavaScript, Python 3, C and Rust are planned.

### Getting the SDK

Each release carries the SDK as its own file. For the latest stable
release:

```sh
zig fetch --save=gtty https://github.com/Tesselix/gtty/releases/latest/download/gtty-sdk-zig.tar.gz
```

For an edge release, or to pin a version, name it:

```sh
zig fetch --save=gtty https://github.com/Tesselix/gtty/releases/download/v0.5.2/gtty-sdk-zig-0.5.2.tar.gz
```

Then add it in your `build.zig`:

```zig
const sdk = b.dependency("gtty", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gtty", sdk.module("gtty"));
```

### Connectors

The objects passed to you hold the SDK's connectors, each for one job
*(proposed names)*:

| Connector | Does |
|---|---|
| `ui` | Sets the chip, peek, epeek and dialog; shows and closes dialogs |
| `events` | Registers the events you want |

`win` is your connection to one window: what you do through it applies
to that window, and its events come only from that window. `ext` has only
`ui`, which covers all windows.

## Events

Report what you want to hear with `registerEvent`, at any time. Everything
you registered then arrives in one callback, `onEvent`:

```zig
pub fn onWindowStart(win: *gtty.Window) !void {
    try win.events.registerEvent(some_event);
}

pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {
    // win is the window it came from
    // look at ev.element, read what you need
}
```

`unregisterEvent` stops listening. The events so far:

| Event | Fires | Carries |
|---|---|---|
| `window_changed` | When the window starts, then only when something changed | `folder`, `branch`, `remote` |
| `command_started` | When a command starts in the window's shell | `command`, `folder`, `remote` |
| `key` | When a key is pressed while the window has the keyboard | `key`, `text`, `ctrl`, `shift`, `alt`, `cmd` |
| `button_click` | When one of your buttons is pressed; no need to register | `button` |

More will come as chips need them, and few on purpose.

**Keys.** `key` is the key's name: the character on it, unshifted (`a`,
`1`, `/`), or `enter`, `escape`, `tab`, `backspace`, `delete`, `space`,
`left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`,
`insert`, `f1` to `f24`, else the system's name in lowercase. `text` is
what it typed (`A` with Shift), empty for keys that type nothing. `cmd` is
⌘ on macOS, the Super key on Linux; modifier keys alone send nothing. A key
event is a notice: the key still reaches the program (or gtty's shortcut)
and can't be held back. A peek or dialog opened for a key gets the
keyboard, as for a click. gtty sends none while the terminal hides what is
typed (a password prompt), nor while one of its dialogs, menus, an epeek's
filter or the find box has the keyboard. A password asked on a remote host
looks like any other typing, so an extension must never keep or send what
it receives.

**Every event starts with the same header.** After it come the parameters of the element that fired it.

| Header field | Meaning |
|---|---|
| `eventId` | The event's id, 8 hex digits |
| `element` | What fired it, such as a button *(proposed)* |
| `windowText` | The window's text, as it was at this event |
| `labels` | The labels on that text, such as commands and their output |

`windowText` and `labels` look like plain fields, but the SDK reads them
from gtty only when you use them, because a window can hold 50 MB of text.
An event that you ignore costs almost nothing:

```zig
const part = try ev.windowText.read(start, length);
const encoding = ev.windowText.encoding; // "utf-8"
```

Offsets are bytes. gtty keeps the text of an event for 15 seconds after
the last listener was told, and always keeps a window's latest event.
After that a read returns an error, and you can move on to a newer event.

Your callbacks run one at a time, so return quickly and do long work on
your own thread. Otherwise, events queue up and gtty starts dropping them.

## Changing what's on screen

One function changes everything. The object you pass names the element:

| Call | Changes |
|---|---|
| `win.ui.set(.{ .chip = … })` | The chip in this window |
| `win.ui.set(.{ .peek = … })` | The peek in this window |
| `win.ui.set(.{ .epeek = … })` | The epeek in this window |
| `win.ui.setDisplayMode(.chip)` | Shows your chip, peek or epeek: `.chip`, `.peek`, `.epeek` |
| `win.ui.set(.{ .dialog = … })` | The dialog of this window |
| `ext.ui.set(…)` | The same, in every window *(proposed)* |

On the connection these are JSON objects of the same shape:

```json
{"chip": {"text": "main"}}
```

**Every update is partial:**

- A field you send changes.
- A field you leave out stays as it was.
- A field set to `null` is cleared.

A list (`lines`, `buttons`, `options`) is replaced as a whole.

## What an extension shows

An extension sets up its UI when it starts, in `onWindowStart`, or has no
UI at all. **A UI needs a chip.** The peek and the epeek are optional, so
there are four shapes:

| Set | A click on the chip |
|---|---|
| Chip | Nothing opens |
| Chip, peek | Opens the peek |
| Chip, epeek | Opens the epeek, as the focus and session chips do |
| Chip, peek, epeek | Opens the peek, and its expand button opens the epeek |

A peek or epeek with no chip is refused. You can change all of them
later, at any time. A click on the chip opens what you set; hovering opens
nothing by itself, so a chip that opens on hover calls `setDisplayMode` in
its `onhover`. To fill it right before it opens, do the same in `onclick`.

`setDisplayMode` moves between them. gtty only reports a click on an item:
to close the list afterwards, the extension sets the mode back.

```zig
try win.ui.setDisplayMode(.chip); // closes your peek or epeek
```

Only one peek or epeek is open in gtty at a time. Your extension can open
its own without the user doing anything, but then it doesn't replace one
that is already open. A mode set while handling a user's click or hover
takes the keyboard for the filter; otherwise it doesn't, as with dialogs.

## Text

Everywhere an extension sets a text, it's a **list of parts**: chips,
peeks, epeeks, buttons, and dialog titles and labels. Each part is a
string with its own colors and font, and gtty draws the parts one after
the other. What the user types, such as a text box's value, stays a plain
string.

In JSON, a plain string is short for one part with only `string` set
*(proposed)*. A text has at most 8 parts.

```json
{"text": [
  {"string": "feature/"},
  {"string": "login", "fg": "#202020", "bk": "#e0b040", "bold": true}
]}
```

| Field | Type | Meaning |
|---|---|---|
| `string` | string | This part's text |
| `fg` | string | Text color, `#rrggbb` (in Zig `0xrrggbb`) |
| `bk` | string | Background color, `#rrggbb` (in Zig `0xrrggbb`) |
| `size` | number | Font size, percent of the normal size, kept to 50–200 |
| `bold` | bool | Bold |
| `stroke` | bool | A line through the text |

Leave a field out and gtty uses its default for that text. This is how a
filter can mark just the letters that match.

The SDK has a helper, so a simple text stays simple:

```zig
gtty.newText("main")
gtty.newText(.{ "main", .{ .bold = true } })
gtty.newText(.{ .{ "feature/", .{} }, .{ "login", .{ .bold = true } } })
```

Each language writes these in its own way: `newText('main')`,
`newText('main', attr)`, `newText([{...}, {...}])`.

## Chip

```json
{"chip": {"text": "prod-cluster"}}
```

| Field | Type | Meaning |
|---|---|---|
| `text` | text | The chip's text |
| `icon` | string | Icon before the text *(proposed)* |
| `dimmed` | bool | Drawn dim, for "nothing to show" |
| `onclick` | string | Function to call when the text is clicked |
| `onhover` | string | Function to call when the mouse rests on the text |
| `data` | string | Text linked to the chip, returned with the event |

See [Text events](#text-events).

For information about all of gtty rather than one window, show the same
text in every footer with `ext.ui.set`. The session chip works this way.

## Line

The peek and the epeek are built from one thing, the **line**:

```
[prefixButton]  [expand]  text  [postButton]  [×]
```

Everything but the text is optional. `expand` and × exist only in the
peek, and gtty draws them.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Your name for the line |
| `prefixButton` | button or `null` | Left of the text |
| `text` | text | The line's text |
| `postButton` | button or `null` | Right of the text: a plain button or an action button |
| `onclick` | string | Function to call when the text is clicked |
| `onhover` | string | Function to call when the mouse rests on the text |
| `data` | string | Text linked to the line, returned with the event |

## Button

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Your name for the button |
| `icon` | string | See [Icons](#icons) |
| `text` | string | The button's text; on an icon, its tooltip |
| `onclick` | string | Name of the function to call |
| `data` | string | Text linked to the button, returned with the click |

**`onclick` is what makes it a button.** Without it, the icon is only an
icon: no hover, no hand pointer, nothing to click. A green dot marking
the current branch is an icon with no `onclick`.

### Action buttons

A line's `postButton` can also be an **action button**, drawn as three
dots instead of an icon:

| Dots | Set with | A click |
|---|---|---|
| ⋮ vertical | `"dots": "vertical"` and `items` | gtty opens a popup list of the items' texts. Picking one sends you that item |
| ⋯ horizontal | `"dots": "horizontal"` | Sends you a click, and what happens next is yours, usually a dialog with more information |

```json
{"postButton": {
  "dots": "vertical",
  "onclick": "branchAction",
  "items": [
    {"id": "rename", "text": "Rename", "data": "dev"},
    {"id": "delete", "text": "Delete", "data": "dev"}
  ]
}}
```

Each item is `{id, text, data}`. A pick arrives as a button click with
the item's `id`, `text` and `data`, and the `onclick` of the button.
Closing the popup without a pick sends nothing.

## Peek

A peek is one line. Set `expand` to show the expand button, right after
`prefixButton`; it shows once you have set an epeek, and gtty handles it
itself. gtty always adds the close button at the far right:

```json
{"peek": {
  "expand": true,
  "prefixButton": null,
  "text": "feature/login",
  "postButton": {"icon": "save", "onclick": "saveBranch", "data": "feature/login"}
}}
```

A peek also takes these:

| Field | Type | Meaning |
|---|---|---|
| `expand` | bool | Show the expand button |
| `hoverExpand` | bool | The mouse resting on the peek opens the epeek too |
| `onexpand` | string | Function to call when the epeek opens from the peek, for reading its lines only then |

A click on the peek's text calls its `onclick`. With none, it opens the
epeek.

## Epeek

A list that opens over the peek or the chip and hides it, growing upward
from the footer. The list is required, and the top frame is optional:

```
┌─────────────────────────────────────────┐
│ [b] [b]                     [b] [b] [×] │  frame, optional
│ [ filter                              ] │  filter, its own row
├─────────────────────────────────────────┤
│ [icon]  text  [icon]                    │
│ [icon]  text  [⋮]                       │
└─────────────────────────────────────────┘
```

Each item is a line, as in the peek but with no expand button.

```json
{"epeek": {
  "frame": {
    "left": [{"icon": "save", "text": "save", "onclick": "saveAll"}],
    "filter": {"text": "", "options": ["feature/", "fix/"], "onclick": "filterBranches"},
    "right": []
  },
  "lines": [
    {"id": "main", "prefixButton": {"icon": "dot"}, "text": "main"},
    {"id": "dev", "text": "dev",
     "postButton": {"icon": "trash", "onclick": "deleteBranch", "data": "dev"}}
  ]
}}
```

| Field | Type | Meaning |
|---|---|---|
| `frame` | object or `null` | The top frame; leave it out for a plain list |
| `frame.left` | up to 2 buttons | Action buttons on the left |
| `frame.right` | up to 2 buttons | Action buttons on the right |
| `frame.text` | text | The title, between the buttons |
| `frame.onclick`, `onhover`, `data` | string | As on a line, for the title |
| `frame.filter` | filter or `null` | The filter box, in its own row under the frame |
| `lines` | list of lines | The list, required |
| `selected` | number | The line selected at first, and after new `lines` |
| `empty` | text | Shown when `lines` is empty |
| `footer` | text | A dim line under the list |
| `state` | string | `idle`, `busy`, `ok` or `err`: colors the border |
| `message` | list of texts | Under the list, one row each, in the state's color |

`state` shows how an action is going: set `busy`, then `ok` or `err` with a
`message`. `ok` closes the epeek after a second; for `err` it stays.

gtty adds the scrolling and the keyboard. A frame always ends in gtty's
close button at the far right, after your `right` buttons; you can't
remove it. With no frame, Esc or a click outside closes the list.

### Filter

| Field | Type | Meaning |
|---|---|---|
| `text` | string | The text in the box |
| `hint` | text | Shown while the box is empty |
| `options` | list of strings | Possible strings, offered in rows under the box while typing; Tab takes the first |
| `onclick` | string | Function to call when the text changes |

Every change of the text sends you an event. **gtty doesn't filter the
list itself.** You decide what the filter means: send a shorter `lines`
to drop items, or the same `lines` with the matching items' text drawn
differently, new `options` to change the help list, or nothing.

The change arrives as a button click with `id` `filter` and the box's
current text in `text`, so it adds no new event. If you fall behind,
changes waiting for you merge into the latest one. When the epeek closes
with text in the box, one more change comes with an empty text, so you can
put the list back.

↑ and ↓ always move in the list, Enter picks the selected line, Esc closes.

## Icons

An icon string is one of:

- **A name from gtty's standard icons**: `copy`, `save`, `list` and `dot`
  so far. More will come.
- **A file name** in the root of your extension's folder, such as
  `kube.png` *(not built yet)*.

A path is refused: no `/`, no `..`, and nothing outside your extension's
folder. Files are PNG only, at most 256 KB and 128×128 *(proposed)*.

## Handling clicks

Name a function in `onclick`, and a click on that button reaches
`onEvent` as a **button click**, with no need to register it. After the
header, it carries:

| Field | Meaning |
|---|---|
| `id` | The button's id |
| `text` | The button's text |
| `data` | The text you linked to the button |
| `function` | The name you gave in `onclick` |
| `command` | ⌘ (Linux Ctrl) was held; in Zig `ev.command` |
| `fields` | A dialog's values, read with `ev.field("name")` and `ev.checked("keep")` |

The event carries all you need, so you don't have to remember what each
row meant. Your extension has one central on-click function, which calls
the function named in the event and passes it the event's parameters. In
Zig the SDK provides it, and you write only the functions:

```zig
const Actions = struct {
    pub fn saveBranch(win: *gtty.Window, ev: gtty.ButtonClick) !void {
        // ev.data is "feature/login"
    }
};

pub fn onEvent(win: *gtty.Window, ev: *const gtty.Event) !void {
    if (ev.kind == .button_click) try gtty.dispatch(Actions, win, ev); // the central on-click
}
```

### Text events

Clicking or hovering over a text sends an event too: the chip's text, the
peek's text or the text of an epeek item. Name a function in `onclick` or
`onhover`; with no name, nothing is sent.

Both arrive as a button click, with the text in `text`, your `data`, and
the name you gave in `function`, so they add no new event.
A hover fires once, when the mouse has rested on the text for half a
second, never while it moves, and nothing is sent when it
leaves.

## Dialogs

A dialog asks the user for values. It appears in the center of the
window, and only one is open at a time. It's modal: while it's open, the
window takes no typing, though its job keeps running. Other windows and
the prompt still work. A dialog asked for while another is open waits for
it to close.

A dialog takes the keyboard only if the user just acted on your extension,
such as clicking its button. Otherwise it opens with a gray frame and
without the keyboard, so typing in the shell can't land in it, until the
user clicks it. Its frame always shows your extension's name.

### Functions

| Function | Does |
|---|---|
| `win.ui.set(.{ .dialog = … })` | Sets the dialog's content, or updates it while open |
| `win.ui.showDialog()` | Shows it |
| `win.ui.closeDialog()` | Closes it; your extension's way to finish |

### Layouts

Choose one with `layout`. The list of fields is the same for all three.

**`form`**: one field per line, label then value.

```
Name   [ work          ]
Host   [ alpha        ▾]
Keep   [x]
```

**`grid`**: `label: value` one after the other, wrapping when a line is
full. gtty adds a space after each control to separate the fields.

```
Name: [ work   ]   Host: [ alpha ▾]
Keep: [x]
```

**`table`**: a set number of columns and rows, with a label and a value
control in each cell, filled in order.

```
Name  [ work ]   Host  [ alpha ▾]
Keep  [x]        Port  [ 22     ]
```

### Dialog fields

| Field | Type | Meaning |
|---|---|---|
| `title` | string | Text in the top frame |
| `layout` | string | `form`, `grid` or `table` |
| `columns`, `rows` | number | For `table` |
| `fields` | list of widgets | The content |
| `buttons` | string | `ok`, `okcancel` or `yesno` |
| `onclick` | string | Function called for every button |
| `timeout` | number | Seconds until gtty closes it |
| `error` | string | A red line, to reject the input |

### Widgets

Every widget has an `id`, a `type` and a `label`.

| `type` | Widget | More fields | Value |
|---|---|---|---|
| `text` | Text box | `value` | string |
| `checkbox` | Check box | `value` | bool |
| `dropdown` | Drop box | `value`, `options`, `filter` | string |
| `label` | Plain text, no control | | none |

`options` is a list of strings. `filter: true` lets the user type to
narrow the list.

Keys: Tab and Shift+Tab move between controls and buttons, Space toggles a
check box or opens a drop box, ↑ and ↓ choose in its list. Text boxes have
the usual editing keys, and ⌘C, ⌘X and ⌘V (Linux Ctrl+Shift+C, X, V).

Typing in a widget sends you nothing. You get all the values at once, in
`fields`, when a button is pressed.

### Closing a dialog

**The buttons only report.** `ok`, `cancel`, `yes` and `no` send you a
button click, and the dialog stays open. **Your extension closes it**
with `win.ui.closeDialog()`. To reject the input, don't close it: update it
with an `error` instead. After a press the buttons wait for your update
or close, so a double click sends one event. If you set no `onclick`,
nobody is there to close it, so gtty closes it on any button.

**gtty can close any dialog at any time**, without asking:

- **The × in the top frame is a kill.** Every dialog has one.
- **Every dialog has a timeout**, in seconds, with a countdown shown. It
  starts again on any input. Default 30, at most 600.
- **The window closing** also kills its dialog.

After a kill, the values are gone. If you set `onclick`, you get a button
click with `id` set to `kill` or `timeout`, and no `fields`.

| `id` | Comes from | `fields` | Who closes |
|---|---|---|---|
| `ok`, `yes` | The button, or Enter | Yes | Your extension |
| `cancel`, `no` | The button, or Esc | Yes | Your extension |
| `kill` | ×, or the window closing | No | gtty, already closed |
| `timeout` | Time ran out | No | gtty, already closed |

### A complete dialog

```zig
const Actions = struct {
    pub fn saveSession(win: *gtty.Window, ev: gtty.ButtonClick) !void {
        if (ev.is("ok")) {
            const name = ev.field("name") orelse "";
            if (name.len == 0) {
                return win.ui.set(.{ .dialog = .{ .@"error" = "Name can't be empty" } });
            }
            try save(name);
        }
        if (ev.is("ok") or ev.is("cancel")) try win.ui.closeDialog();
    }
};

pub fn askName(win: *gtty.Window) !void {
    try win.ui.set(.{ .dialog = .{
        .title = "Save session",
        .layout = "form",
        .timeout = 30,
        .buttons = "okcancel",
        .onclick = "saveSession",
        .fields = .{
            .{ .id = "name", .type = "text", .label = "Name", .value = "work" },
        },
    } });
    try win.ui.showDialog();
}
```

## The window's shell

`win.shell()` returns the name of the shell in front in the window you are
connected to: `bash`, `sh`, `zsh` or any other shell the system lists. If
what is in front isn't a shell, such as `vim`, you get the shell the window
itself runs.

## Storage

Your extension gets two places to keep files, `win.ephemeral` and
`win.stateful`, with the same functions:

```zig
const f = try win.stateful.openWrite("hosts.json", 500); // waits up to 500 ms
try f.write(text);
try f.close();

const r = try win.stateful.openRead("hosts.json", 500);
const n = try r.read(&buf); // 0 at the end
try r.close();

try win.stateful.delete("old.json", 500);
const names = try win.stateful.list(&buf); // one per line
```

Opening for writing replaces the whole file. The new text takes the old
one's place at `close`, so nobody sees it half written; if gtty has to
close the file first, the old one stays.

| Storage | Lives | Use it for |
|---|---|---|
| **Ephemeral** | Like a temp folder, until the instance ends | Caches, work in progress |
| **Stateful** | On the drive, under your extension's folder | Settings, history, anything to keep |

An **instance** is one running copy of your extension in a window.

**Ephemeral** storage belongs to one instance. When the instance ends,
with its window closing, all its files are deleted.

**Stateful** storage sits in the `data` folder under your extension's
folder, and all instances use the same folder. Updating your extension
leaves it alone. **Uninstalling deletes it**, for a clean slate: if your
users may want their data, offer them a way to export it. gtty guards it, so instances can't get in each
other's way:

- Opening a file for writing or for reading takes a timeout in
  milliseconds. If the file isn't available, the request waits until it is.
- While a file is open for writing, no other instance can use it, even to
  read it.
- Several instances can read a file at once. A write waits until they are
  done.
- A timeout of 0 tries once and doesn't wait.
- First come, first served: once a write is waiting, new readers queue
  behind it.
- If the timeout passes first, the open returns an error saying someone
  else is using the file.
- This holds across every gtty on the machine: gtty keeps lock files in a
  folder of its own, and the extension manager, a window like the Session
  Manager *(not built yet)*, can remove a stuck lock.
- A file held open for 30 seconds is closed by gtty, and the next call on
  it returns an error. gtty also closes an instance's files when it ends.

Handle that error: try again later, or tell the user. You can create and
delete files in both storages.

**The interface is safe.** A file is named relative to its storage, and a
name that leaves it is refused: no `/`, no `..`, no leading `.`.

Each storage holds at most 100 MB, set in Settings → General. A write past
that returns `StorageFull`. The errors are `FileInUse`, `FileClosed` (gtty
closed it), `NoFile`, `BadName`, `StorageFull` and `StorageFailed`.

Extensions inside gtty can't wait: on gtty's own thread every timeout
counts as 0.

## Logs

Write to the log from any callback or from your own thread:

```zig
win.log(.info, "host {s} added", .{name});
ext.log(.warn, "no config", .{}); // in onGttyStart and onGttyClose
```

The levels are `.debug`, `.info`, `.warn` and `.err`. A message over 1024
bytes is cut, and logging never fails.

Read the log from any terminal or IDE task while gtty runs:

```sh
gtty ext logs -f hosts   # follow one extension until gtty closes
gtty ext logs            # print what is there now, for every extension
gtty ext logs --pid 4242 # choose a gtty (default: the one logged to last)
```

```
08:02:57.261 info  hosts e311667c host alpha added
08:02:58.165 err   hosts e311667c onEvent returned FileInUse
```

Each line has the time, level, extension, window id and message; `-` means
no window. gtty also logs an error returned from a callback, under your
extension's name, and dropped events, under `gtty`.

The log lives in gtty's private temp folder, readable only by you, and goes
when gtty closes. At 8 MB it moves to `ext.log.1` and a new one starts, so
gtty keeps at most about 16 MB.

## Languages

An installed extension is **its own program**, in any language with an
SDK. gtty starts it as its child process when gtty starts (or when it is
installed), and stops it when gtty closes; they talk over a socket, in
JSON lines ([protocol.md](protocol.md)). gtty never waits for it, so a
slow or stuck extension can't freeze the terminal, and a crash only ends
the extension (its chip goes; the log says why).

| SDK | Language | Calls that answer (`shell`, storage) |
|---|---|---|
| `sdks/zig` | Zig 0.16 | return at once with the answer |
| `sdks/python` | Python 3.8+ | return the answer |
| `sdks/javascript` | Node.js 18+ | return promises: `await` them |
| `sdks/go` | Go 1.21+ | return `(value, error)` |

Every SDK has the same functions and the same example (`hosts`), and
`sdks/conformance/fake_gtty.py`, a stand-in for gtty, checks each example
through one conversation. One process serves every window of one gtty.

The standard chips use the Zig SDK too, but inside gtty's process: there
`win.ui` errors come back from the call; in a separate program they are
lines in `gtty ext logs`.

## Packaging

A package is a folder, or a `.zip`, `.tar` or `.tar.gz` of one, with
`manifest.json` at its top (or in its single top folder):

```json
{
  "name": "kube",
  "version": "1.2.0",
  "description": "The cluster this window talks to",
  "main": {"macos-aarch64": "bin/kube-macos", "linux-x86_64": "bin/kube-linux"}
}
```

| Key | |
|---|---|
| `name` | Required. Lowercase letters, digits, `-` and `_`, starting with a letter, 32 at most. Not `folder`, `git`, `focus`, `session`, `test`, `gtty`, `extensions`. It names the storage and the log lines, and an install with the same name is an update. |
| `main` | Required. The program, relative to the package: a string, or one per platform (`macos-aarch64`, `linux-x86_64`). |
| `runtime` | `python3` or `node`: gtty runs `python3 main` / `node main`, found on PATH. Left out: `main` runs by itself. |
| `version`, `description` | Shown in the manager and `gtty ext list`. |

gtty refuses a package with a link, a device or a name outside its folder,
over 256 MB or 20000 files. It unpacks into `<extensions>/<name>/code/`
(the folder of `extension-storage`: `$GTTY_EXTENSIONS`, else
`~/.local/share/gtty/extensions`), beside `data/` (its stateful storage,
kept on update). It starts with gtty's environment, in its own folder,
with `GTTY_EXT_NAME` and `GTTY_EXT_DIR` set.

## Installing

- **The extension manager** (gtty ▸ Extensions…, or `extensions` at the
  prompt): the installed extensions, whether each runs (with its pid, or
  its exit code when it failed), and a ⋮ menu per row: Turn Off / Turn On,
  Restart, Unlock Files, Uninstall (asks first: its data goes too).
  **Install…** opens a file dialog, and a package or folder dropped on the
  window works too; either way the manager first shows the manifest and
  that an extension runs as the user, with Install / Cancel.
- **The command line**, for scripts, IDE tasks and AI tools:

```sh
gtty ext install <folder | file.zip | file.tar.gz>   # or update
gtty ext list
gtty ext enable | disable <name>
gtty ext uninstall <name>                            # its data too
gtty ext logs [-f] [--pid N] [extension]
gtty ext socket [--pid N]                            # where a debugged one connects
```

Every running gtty looks at the folder once a second: it starts what was
installed or turned on, restarts what was installed again, and stops what
was turned off or removed. So the development loop is: build,
`gtty ext install`, `gtty ext logs -f`. Or skip installing and debug it:

## Debugging

Start the extension from the IDE's debugger (VS Code, PyCharm, GoLand,
lldb, …) while gtty runs. gtty didn't start it, so the SDK connects to the
newest gtty on its own, and gtty treats it as the extension of that name:

- The name comes from `GTTY_EXT_NAME`, else from the `manifest.json` in
  the folder it runs in.
- Its chip shows in every window. An installed copy of the same name stops
  while it runs, and starts again when it ends.
- Breakpoints stop only the extension; gtty keeps working. Its limits are
  wider meanwhile: 64 MB of events wait for it, a dialog it opens within 10
  minutes of the user's click still gets the keyboard, its files stay open
  up to 30 minutes.
- Its stdout and stderr stay in the IDE's console; its log lines go to
  `gtty ext logs` as usual. The extension manager shows "debugging" and its
  pid.
- Only your own processes get in. `GTTY_EXT_SOCKET=<path>` picks a gtty
  other than the newest (`gtty ext socket --pid N` prints its path).

Every SDK's `AGENTS.md` has a VS Code `launch.json` for its language under
"Debug". The details are in [protocol.md](protocol.md), "Development".

## Not decided yet

| Point | Current proposal |
|---|---|
| An extension still running after gtty closed | The SDKs end the program when the connection closes (built); on Linux it also gets SIGTERM when gtty dies |
| A window moved to another gtty | `onWindowClose` here, `onWindowStart` there |
| YAML as well as JSON | JSON only for now: Zig's standard library has no YAML parser, and gtty adds no new packages lightly |
| An icon for the chip | A PNG in the package, named in the manifest |
| Limits | `data` 4 KB |
